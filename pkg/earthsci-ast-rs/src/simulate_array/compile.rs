//! Compile path: model → [`ArrayCompiled`]. Array-op / spatial-model file
//! detection, subsystem mounting (esm-spec §4.6), ragged keyed-factor scope
//! resolution (RFC §5.4), the staged [`ArrayCompiled::from_model`] build, the
//! build-time field evaluators, and the shape-inference / LHS-parsing
//! lowering helpers.

use super::*;
use crate::aggregate::{
    effective_reduce_kind, is_aggregate_op, resolve_aggregate_ranges, validate_oplus_spellings,
};
use crate::flatten::FlattenedSystem;
use crate::op_registry::{OpError, is_builtin_function_name};
use crate::simulate::{CompileError, SimulateError};
use crate::types::{
    EsmFile, ExpressionNode, JoinClause, Model, ModelVariable, OverlapClause, VariableType,
};
use crate::value_invention::{
    ValueInventionResult, materialize_value_invention, rewrite_derived_index_sets,
};
use indexmap::IndexMap;
use serde_json::Value as JsonValue;
use std::collections::HashSet;

// ============================================================================
// Detection: does the file contain array-op expressions anywhere?
// ============================================================================

/// Names of the array-op sidecar operators introduced in gt-t5c. `aggregate`
/// and `makearray` are the composition primitives; the rest are shape /
/// extraction helpers that are only meaningful when operating on array
/// intermediates.
pub(super) const ARRAY_OP_NAMES: &[&str] = &[
    "aggregate", // unified Functional Aggregate Query op (RFC semiring-faq-unified-ir §5.6)
    "makearray",
    "reshape",
    "transpose",
    "concat",
    "broadcast",
];

/// Return true if any expression in the file uses a gt-t5c array op.
pub fn file_has_array_ops(file: &EsmFile) -> bool {
    let Some(models) = &file.models else {
        return false;
    };
    for model in models.values() {
        if model_has_array_ops(model) {
            return true;
        }
    }
    false
}

/// Return true if the file has spatial structure: any model with array-shaped
/// state variables (`shape` field non-empty).
///
/// Used by [`crate::simulate::simulate`] to route discretized-PDE files to the
/// ArrayOp runtime even when the equations do not yet contain explicit
/// `aggregate`/`index` nodes (e.g. a spatial model whose equations were rewritten
/// using indexed-scalar D(u[i])=... form rather than the `aggregate` wrapper).
pub fn file_has_spatial_model(file: &EsmFile) -> bool {
    let Some(models) = &file.models else {
        return false;
    };
    for model in models.values() {
        for var in model.variables.values() {
            if let Some(shape) = &var.shape {
                if !shape.is_empty() {
                    return true;
                }
            }
        }
    }
    false
}

pub(super) fn model_has_array_ops(model: &Model) -> bool {
    for eq in &model.equations {
        if expr_has_array_op(&eq.lhs) || expr_has_array_op(&eq.rhs) {
            return true;
        }
    }
    // Also detect by the presence of bracketed initial conditions in the
    // variable definitions — not strictly an AST signal but a strong hint.
    for name in model.variables.keys() {
        if name.contains('[') {
            return true;
        }
    }
    false
}

pub(super) fn expr_has_array_op(expr: &Expr) -> bool {
    match expr {
        Expr::Number(_) | Expr::Integer(_) | Expr::Variable(_) => false,
        Expr::Operator(node) => {
            if ARRAY_OP_NAMES.contains(&node.op.as_str()) {
                return true;
            }
            if node.op == "index" {
                // `index` is only meaningful when there is an array to index
                // into — always recognise it as an array-op signal.
                return true;
            }
            node.any_child(&mut expr_has_array_op)
        }
    }
}

/// Walk an expression and reject every operator node that may not reach an
/// evaluator (esm-spec §4.2 / §9.6.8).
///
/// This is the crate's single compile-time operator gate. It used to check only
/// for unlowered *spatial* ops — which meant a malformed-but-schema-valid node
/// (`atan2` with one argument, `min` with one, a ragged `makearray`, a typo'd
/// `"expp"`) sailed straight into the evaluators. There it either **panicked**
/// on an out-of-bounds `args[1]`, or, more insidiously, was quietly assigned two
/// *different* values by the per-cell oracle and the vectorized overlay
/// depending on whether the enclosing body happened to vectorize.
///
/// Delegating to [`crate::op_registry`] closes all of that at once: past this
/// gate, every surviving node is an evaluable-core op with a legal arity, so the
/// evaluators only ever have to agree on nodes that are *legal* — and for those
/// they agree by construction.
///
/// The walk uses `for_each_child`, so it descends into sidecar expression fields
/// (`aggregate.expr`, `makearray.values`, `filter`, `key`, …), not just `args`.
///
/// # Errors
///
/// [`CompileError::UnloweredOperatorError`] for a rewrite-target op (sugar, a
/// spatial `D`, a user op, or a misspelling); [`CompileError::InvalidOperatorArity`]
/// for a core op with the wrong argument count;
/// [`CompileError::MakearrayRegionInvalid`] for a ragged or inverted `makearray`;
/// [`CompileError::InvalidBroadcastFn`] for a `broadcast` whose `fn` is absent
/// or names no scalar operator.
pub(super) fn check_no_spatial_ops(expr: &Expr) -> Result<(), CompileError> {
    crate::op_registry::check_expr(expr).map_err(|e| match e {
        OpError::Unlowered { op } => CompileError::UnloweredOperatorError { op },
        OpError::Arity { op, got, expected } => {
            CompileError::InvalidOperatorArity { op, got, expected }
        }
        OpError::MakearrayRegion { reason } => CompileError::MakearrayRegionInvalid { reason },
        OpError::BroadcastFn { reason, .. } => CompileError::InvalidBroadcastFn { reason },
    })
}

// ============================================================================
// Subsystem mounting (esm-spec §4.6 dot notation).
// ============================================================================

/// Coerce one resolved `subsystems` entry into a typed [`Model`] plus the
/// document `index_sets` registry it ships (empty for a bare model fragment).
/// The loader ([`crate::ref_loading::resolve_subsystem_refs_raw`]) inlines each
/// `{ "ref": … }` as the referenced file's full JSON, so the common shape is a
/// whole ESM document carrying exactly one model (the MPAS mesh contract:
/// `grids/mpas/mesh/level0.esm`); a bare `{ "variables": …, "equations": … }`
/// fragment is also accepted. An unresolved `{ "ref": … }` — a document built
/// programmatically without the loader — is a hard error, never a silent drop.
pub(super) fn parse_subsystem_model(
    sub_name: &str,
    value: &serde_json::Value,
) -> Result<(Model, HashMap<String, IndexSet>), CompileError> {
    let obj = value.as_object().ok_or_else(|| {
        CompileError::build_err(format!("subsystem '{sub_name}' is not a JSON object"))
    })?;
    if obj.contains_key("models") {
        let file: EsmFile = serde_json::from_value(value.clone()).map_err(|e| {
            CompileError::build_err(format!(
                "subsystem '{sub_name}' does not parse as an ESM file: {e}"
            ))
        })?;
        let models = file.models.unwrap_or_default();
        if models.len() != 1 {
            return Err(CompileError::build_err(format!(
                "subsystem '{sub_name}' resolves to a file with {} models; exactly one is \
                     required to mount it",
                models.len()
            )));
        }
        let model = models.into_values().next().expect("len checked above");
        Ok((
            model,
            file.index_sets.unwrap_or_default().into_iter().collect(),
        ))
    } else if obj.contains_key("variables") || obj.contains_key("equations") {
        let model: Model = serde_json::from_value(value.clone()).map_err(|e| {
            CompileError::build_err(format!(
                "subsystem '{sub_name}' does not parse as a model: {e}"
            ))
        })?;
        Ok((model, HashMap::new()))
    } else if obj.contains_key("ref") {
        Err(CompileError::build_err(format!(
            "subsystem '{sub_name}' is an unresolved {{\"ref\": …}}; load the document \
                 through the official loader (crate::parse::load_path) so \
                 resolve_subsystem_refs_raw inlines it first"
        )))
    } else {
        Err(CompileError::build_err(format!(
            "subsystem '{sub_name}' has neither 'models' nor 'variables'/'equations'"
        )))
    }
}

/// Mount every subsystem of `model` into the model's own registries under
/// dot-prefixed names (esm-spec §4.6): each subsystem variable `x` becomes
/// `"<sub>.x"` (with sibling references inside its expression renamed to the
/// mounted names), each subsystem equation is appended with its references
/// renamed the same way, and the subsystem file's `index_sets` merge into the
/// document registry (the parent's declaration wins on a name collision).
/// Recursive, so a nested subsystem mounts as `"<sub>.<subsub>.x"`. This is the
/// array-runtime analogue of the Julia flatten's subsystem namespacing — it is
/// what makes the MPAS keyed-factor wiring contract (`nEdgesOnCell :=
/// mesh.nEdgesOnCell`, a bare-name observed alias of a mounted const factor)
/// resolvable. A model without subsystems is untouched (byte-identical build).
pub(super) fn mount_subsystems(
    model: &mut Model,
    index_sets: &mut HashMap<String, IndexSet>,
) -> Result<(), CompileError> {
    let Some(subs) = model.subsystems.take() else {
        return Ok(());
    };
    let mut names: Vec<String> = subs.keys().cloned().collect();
    names.sort();
    for sub_name in names {
        let (mut sub_model, mut sub_sets) = parse_subsystem_model(&sub_name, &subs[&sub_name])?;
        // Grandchildren first, so their variables are already dot-prefixed
        // within `sub_model` when this level's prefix is applied.
        mount_subsystems(&mut sub_model, &mut sub_sets)?;
        for (k, v) in sub_sets {
            index_sets.entry(k).or_insert(v);
        }
        let siblings: Vec<String> = {
            let mut s: Vec<String> = sub_model.variables.keys().cloned().collect();
            s.sort();
            s
        };
        let rename_all = |expr: &Expr| -> Expr {
            let mut out = expr.clone();
            for s in &siblings {
                out = rename_free_symbol(&out, s, &format!("{sub_name}.{s}"));
            }
            out
        };
        for (vname, var) in &sub_model.variables {
            let mounted = format!("{sub_name}.{vname}");
            if model.variables.contains_key(&mounted) {
                return Err(CompileError::build_err(format!(
                    "mounting subsystem '{sub_name}' would overwrite existing variable \
                         '{mounted}'"
                )));
            }
            let mut var = var.clone();
            // A parameter `update`'s Expressions are the only ones a variable
            // still carries (esm 1.0.0); an unknown's definition is an equation,
            // renamed with the rest below.
            var.for_each_expression_mut(&mut |expr| *expr = rename_all(expr));
            model.variables.insert(mounted, var);
        }
        for eq in &sub_model.equations {
            model.equations.push(crate::types::Equation {
                lhs: rename_all(&eq.lhs),
                rhs: rename_all(&eq.rhs),
                comment: eq.comment.clone(),
            });
        }
    }
    Ok(())
}

// ============================================================================
// Ragged keyed-factor scope resolution (esm-spec §4.3.1 / RFC §5.4).
// ============================================================================

/// Resolve each ragged index set's `offsets`/`values` keyed factors against the
/// model scope, rewriting the registry copy in place. A keyed factor binds by
/// BARE name (the document-scoped registry keeps the authored name), but
/// flattening/mounting prefixes every variable with its owning component path
/// (`nEdgesOnCell` → `Divergence.nEdgesOnCell` alias and
/// `Divergence.mesh.nEdgesOnCell` const). Resolution rule (mirror of the Julia
/// tree_walk `_factor_scope`): an exact-name variable wins; otherwise the
/// dot-suffix match at the SHALLOWEST namespace depth (the model's own
/// re-exposed alias, not the mounted subsystem's original). Multiple matches at
/// that depth are a hard error — never a silent empty contraction. A factor
/// with no in-scope match is left bare (it may be supplied by the caller's
/// runtime channels), preserving existing behavior. No-op (byte-identical) for
/// documents without ragged index sets.
pub(super) fn apply_ragged_factor_scope(
    index_sets: &mut HashMap<String, IndexSet>,
    variables: &IndexMap<String, ModelVariable>,
) -> Result<(), CompileError> {
    let scope_one = |fname: &str, set_name: &str| -> Result<Option<String>, CompileError> {
        if variables.contains_key(fname) {
            return Ok(None); // exact name is in scope; keep as authored
        }
        let suffix = format!(".{fname}");
        let cands: Vec<&String> = variables.keys().filter(|n| n.ends_with(&suffix)).collect();
        if cands.is_empty() {
            return Ok(None); // leave bare; a genuinely unbound read surfaces later
        }
        let mindepth = cands
            .iter()
            .map(|c| c.matches('.').count())
            .min()
            .expect("non-empty");
        let best: Vec<&&String> = cands
            .iter()
            .filter(|c| c.matches('.').count() == mindepth)
            .collect();
        if best.len() > 1 {
            let mut names: Vec<String> = best.iter().map(|s| (**s).clone()).collect();
            names.sort();
            return Err(CompileError::build_err(format!(
                "ragged index set '{set_name}': keyed factor '{fname}' is ambiguous in the \
                     model scope — {} candidates at namespace depth {mindepth}: {}",
                names.len(),
                names.join(", ")
            )));
        }
        Ok(Some((*best[0]).clone()))
    };
    let set_names: Vec<String> = index_sets
        .iter()
        .filter(|(_, s)| s.kind == "ragged")
        .map(|(n, _)| n.clone())
        .collect();
    for name in set_names {
        let (off, vals) = {
            let s = &index_sets[&name];
            (s.offsets.clone(), s.values.clone())
        };
        if let Some(f) = off
            && let Some(scoped) = scope_one(&f, &name)?
        {
            index_sets.get_mut(&name).expect("present").offsets = Some(scoped);
        }
        if let Some(f) = vals
            && let Some(scoped) = scope_one(&f, &name)?
        {
            index_sets.get_mut(&name).expect("present").values = Some(scoped);
        }
    }
    Ok(())
}

// ============================================================================
// Compile path: model → ArrayCompiled.
// ============================================================================

impl ArrayCompiled {
    pub fn from_file(file: &EsmFile) -> Result<Self, CompileError> {
        let Some(models) = &file.models else {
            return Err(CompileError::build_err("File has no models to simulate"));
        };
        if models.len() != 1 {
            return Err(CompileError::build_err(
                "Array-op path currently only supports a single model file (no coupling)",
            ));
        }
        let (model_name, model) = models.iter().next().unwrap();
        // v0.8.0: `index_sets` is document-scoped (one registry shared by all
        // models), so source it from the file rather than the model.
        let index_sets: HashMap<String, IndexSet> = file
            .index_sets
            .clone()
            .unwrap_or_default()
            .into_iter()
            .collect();
        let mut compiled = Self::from_model(model, &index_sets)?;
        // Record the model's namespace so overrides may be keyed `Model.param`
        // (the scalar/flatten/Julia convention) as well as the raw `param` this
        // single-model path builds (WS3 override-naming parity).
        compiled.namespace = Some(model_name.clone());
        Ok(compiled)
    }

    /// [`Self::from_file`], consuming the file. The peak-memory-lean build for
    /// a large expanded discretization: the single model is MOVED out of the
    /// file (nothing is cloned), the rest of the document is dropped here, and
    /// [`Self::from_model_owned`] then moves each observed body into its
    /// compiled rule instead of deep-copying it. For `simpleclimate.esm` at
    /// the production grid the borrowed `from_file` holds three ~1 GiB copies
    /// live at once (the caller's file, the compile's private model clone, the
    /// compiled rules); this path holds ~one. Same build stages, same result.
    pub fn from_file_owned(file: EsmFile) -> Result<Self, CompileError> {
        let Some(models) = file.models else {
            return Err(CompileError::build_err("File has no models to simulate"));
        };
        if models.len() != 1 {
            return Err(CompileError::build_err(
                "Array-op path currently only supports a single model file (no coupling)",
            ));
        }
        let index_sets: HashMap<String, IndexSet> =
            file.index_sets.unwrap_or_default().into_iter().collect();
        let (model_name, model) = models.into_iter().next().unwrap();
        let mut compiled = Self::from_model_owned(model, &index_sets)?;
        compiled.namespace = Some(model_name);
        Ok(compiled)
    }

    /// Build from a [`FlattenedSystem`] — the array-runtime analogue of the
    /// scalar [`crate::simulate::Compiled::from_flattened`].
    ///
    /// [`crate::flatten::flatten`] already merges a coupled, multi-component
    /// file into a single dot-namespaced system (coupling rules applied, every
    /// variable reference namespaced). The array path historically only had
    /// [`Self::from_file`], which rejects `models.len() != 1` outright because
    /// it operates on a raw [`Model`] and has no coupling machinery of its own.
    /// This constructor closes that seam: it consumes the already-coupled
    /// flatten output directly, so a discretized **coupled** spatial model
    /// compiles + evaluates through the vectorized array runtime, reusing
    /// `flatten.rs`'s coupling verbatim (no new coupling logic here). The raw
    /// single-model `from_file` guard is intentionally left intact — the real
    /// pipeline flattens first and reaches the array runtime through here
    /// (ess-14f.8).
    ///
    /// The flattened system splits variables into typed maps; [`Self::from_model`]
    /// expects a single registry discriminated by [`ModelVariable::var_type`].
    /// We merge them back into one synthetic [`Model`] (each variable already
    /// carries its `var_type`) and delegate, so every downstream stage — shape
    /// inference, arrayop lowering, the diffsol RHS build — is shared bit-for-bit
    /// with the single-model path.
    pub fn from_flattened(flat: &FlattenedSystem) -> Result<Self, CompileError> {
        // Reject hybrid dimensionality and model events, mirroring the scalar
        // `Compiled::from_flattened`. The data-loader refresh path that drives
        // this seam is event-free by design (a driver-level segmented solve,
        // not an in-solver event), so rejecting here loses no in-scope
        // capability while preventing a model that *does* declare events from
        // compiling with its events silently dropped.
        if flat.independent_variables != ["t"] {
            // A spatial independent variable means a rewrite-target operator was
            // never discretized. Report THAT, with the uniform
            // `unlowered_operator` code esm-spec §4.2 / §9.6.8 specifies for
            // an op reaching evaluation unlowered; the dimensionality error
            // is the fallback for a spatial axis with no such op behind it.
            if let Some(op) = crate::flatten::first_unlowered_operator(flat) {
                return Err(CompileError::UnloweredOperatorError { op });
            }
            return Err(CompileError::UnsupportedDimensionalityError {
                independent_variables: flat.independent_variables.clone(),
            });
        }
        if !flat.continuous_events.is_empty() {
            return Err(CompileError::UnsupportedFeatureError {
                feature: "continuous_events".to_string(),
                message: "array-op path does not support continuous (root-finding) events. \
                          Track the future Rust events bead for support."
                    .to_string(),
            });
        }
        if !flat.discrete_events.is_empty() {
            return Err(CompileError::UnsupportedFeatureError {
                feature: "discrete_events".to_string(),
                message: "array-op path does not support discrete events. \
                          Track the future Rust events bead for support."
                    .to_string(),
            });
        }

        // Re-merge the typed variable maps into one registry. The maps are
        // disjoint by construction (a variable has exactly one `var_type`), so
        // no key collides. `parameters` is the WHOLE parameter set of every
        // cadence (esm-libraries-spec §4.7.5 step 4: the wiener / discrete
        // subsets partition it rather than sitting beside it), so a Brownian
        // parameter still reaches `from_model` and gets its explicit "no SDE"
        // rejection, and a `data`-kind discrete parameter still reaches the
        // provider forcing seam `classify_variables` routes.
        let mut variables: IndexMap<String, ModelVariable> = IndexMap::new();
        for (name, var) in &flat.state_variables {
            variables.insert(name.clone(), var.clone());
        }
        for (name, var) in &flat.parameters {
            variables.insert(name.clone(), var.clone());
        }
        for (name, var) in &flat.observed_variables {
            variables.insert(name.clone(), var.clone());
        }

        // `index_sets` is not carried through flatten today, so coupled models
        // that address `arrayop`/`aggregate` ranges via `{ "from": <set> }`
        // are not yet resolvable on this path (tracked as follow-up). Dense
        // `[lo, hi]` ranges — what discretized stencils emit — need no
        // registry and work here.
        let model = Model {
            variables,
            equations: flat.equations.clone(),
            ..Default::default()
        };
        // The document `index_sets` registry is carried through flatten
        // (`FlattenedSystem::index_sets`), so a coupled array system can resolve
        // `aggregate`/`arrayop` `ranges` `{ "from": <set> }`, `join.on` gates, and
        // derived-set references exactly as the single-model `from_file` path
        // does against `file.index_sets`. Empty for a file with no index sets, so
        // dense `[lo, hi]`-range discretized stencils are unaffected.
        let index_sets: HashMap<String, IndexSet> = flat
            .index_sets
            .iter()
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect();
        let mut compiled = Self::from_model(&model, &index_sets)?;
        // Carry the classified scoped-reference `ic` equations through so `u0` is
        // folded from the provider-served loaded initial fields at build time.
        compiled.field_ics = flat.field_ics.clone();
        Ok(compiled)
    }

    /// Build from a single [`Model`] and the document-scoped `index_sets`
    /// registry (RFC semiring-faq-unified-ir §5.2, v0.8.0). The registry lives
    /// on the top-level document and is shared by all models, so it is passed in
    /// explicitly; pass an empty map for a model with no `{ "from": <set> }`
    /// range references.
    pub fn from_model(
        model: &Model,
        index_sets: &HashMap<String, IndexSet>,
    ) -> Result<Self, CompileError> {
        Self::from_model_with_arrays(model, index_sets, None)
    }

    /// [`from_model`](Self::from_model) with a caller-supplied factor-array
    /// channel for the build-time value-invention engine.
    ///
    /// `vi_arrays` is overlaid on the `const`-literal factors the document
    /// carries (caller wins on a name collision — see `vi_factor_arrays`) and
    /// handed to the relational engine. Supply it whenever a producer's factors
    /// arrive from OUTSIDE the document: ISRM's overlap gate reads its envelopes
    /// from `type: "parameter"` variables that data loaders fill through
    /// `coupling` `param_to_var` edges, which the `const` scan cannot see, so
    /// without this channel the gate has no envelopes to build and the producer
    /// invents nothing.
    ///
    /// `None` is exactly [`from_model`](Self::from_model) — every existing
    /// caller is unaffected.
    pub fn from_model_with_arrays(
        model: &Model,
        index_sets: &HashMap<String, IndexSet>,
        vi_arrays: Option<&HashMap<String, ArrayD<f64>>>,
    ) -> Result<Self, CompileError> {
        // The rewrite passes below need an owned model; clone so the caller's
        // model — and its serialized form — is untouched. A caller that can
        // give up its model avoids this copy via [`Self::from_model_owned`]
        // (reached through [`Self::from_file_owned`] / `compile_array`).
        Self::from_model_owned_with_arrays(model.clone(), index_sets, vi_arrays)
    }

    /// [`Self::from_model`], consuming the model: the compile pipeline's
    /// rewrite passes mutate it in place (no private clone), and the observed
    /// bodies — the dominant allocation of a large expanded discretization —
    /// are MOVED into the compiled rules rather than deep-copied
    /// (`build_observed_rules` takes each `var.expression`). Behaviourally
    /// identical to `from_model`: every stage runs in the same order on the
    /// same values.
    fn from_model_owned(
        model_owned: Model,
        index_sets: &HashMap<String, IndexSet>,
    ) -> Result<Self, CompileError> {
        Self::from_model_owned_with_arrays(model_owned, index_sets, None)
    }

    /// The compile pipeline itself: [`Self::from_model_owned`] with the
    /// caller-supplied factor-array channel of
    /// [`Self::from_model_with_arrays`]. Every public entry point above
    /// delegates here.
    fn from_model_owned_with_arrays(
        mut model_owned: Model,
        index_sets: &HashMap<String, IndexSet>,
        vi_arrays: Option<&HashMap<String, ArrayD<f64>>>,
    ) -> Result<Self, CompileError> {
        // Resolve `{ "from": <index set> }` range references (RFC
        // semiring-faq-unified-ir §5.2) into concrete `[lo, hi]` intervals
        // before any shape inference or rule building; every downstream
        // consumer then sees only dense interval ranges.
        //
        // Mount subsystems under dot-prefixed names (esm-spec §4.6) and resolve
        // each ragged index set's keyed factors against the resulting model
        // scope (RFC §5.4; the Julia `_factor_scope` mirror). Both are no-ops —
        // and the registry copy is byte-identical — for models without
        // subsystems / ragged sets.
        let mut index_sets_owned = index_sets.clone();
        mount_subsystems(&mut model_owned, &mut index_sets_owned)?;
        apply_ragged_factor_scope(&mut index_sets_owned, &model_owned.variables)?;
        // Under `element_type: "Float32"`, reject an index set whose subscripts
        // binary32 cannot address exactly. Index expressions share the value
        // kernels — there is no integer type in the expression language — so
        // `i + 1` above 2^24 would round, and a gather would silently read the
        // wrong cell. A no-op under Float64, and for every realistic extent.
        if crate::precision::is_f32() {
            let mut names: Vec<&String> = index_sets_owned.keys().collect();
            names.sort();
            for name in names {
                if let Some(size) = index_sets_owned[name].size {
                    crate::precision::check_index_set_extent(name, size)?;
                }
            }
        }
        // Materialize genuine relational OUTPUTS — the arg-witness reducer
        // (`argmin`/`argmax`, RFC §5.7 rule 6) and the grouped/derived SCVT chain
        // (`group_aggregate`) — to CONSTANT DATA at build setup, then rewrite each
        // output's defining equation to a `const` literal the per-cell oracle
        // already evaluates. This runs the byte-conformant [`crate::value_invention`]
        // engine (the previously-unwired front door) and mirrors the Julia
        // reference's "materialize to data" and the live Python interpreter, so
        // `argmin` / `group_aggregate` now SIMULATE end-to-end instead of raising
        // [`CompileError::UnevaluableOperatorError`]. Runs BEFORE
        // [`strip_value_invention`] so a bin-skolem `join` feeding an argmin is still
        // intact when the buffer is computed. A NO-OP (byte-identical) for every
        // model without an arg-witness op — the conservative-regrid skolem/distinct
        // path is left entirely to `strip_value_invention` below.
        materialize_vi_outputs_to_data(&mut model_owned, &mut index_sets_owned, vi_arrays)?;
        let index_sets = &index_sets_owned;
        // Drop value-invention (relational) scaffolding — skolem-id bin maps and
        // membership sets over `kind: "derived"` index sets — plus the broad-phase
        // `join.on` gates keyed on them, BEFORE join/range resolution. The dense
        // runtime evaluates the geometric narrow phase densely; the elided gate is
        // numerically inert there (see `strip_value_invention`). A no-op unless a
        // `skolem` op or a derived-set-shaped variable is present.
        strip_value_invention(&mut model_owned, index_sets)?;
        // The model's CONST-ARRAY registry (CONFORMANCE_SPEC §5.5.5): the
        // `const`-literal factor variables — Fornberg weights, mesh
        // connectivity, a geometry table — that [`collect_const_factor_arrays`]
        // already identifies as the Rust analogue of the Julia reference's
        // `const_arrays`. Captured HERE, before stage (6) MOVES each observed
        // body out of the variable registry. A gather on one of these resolves
        // an out-of-range index by its declared boundary policy instead of the
        // state gather's zero ghost, which §5.5.5 says is never a const array's.
        let const_scope = Rc::new(ConstArrayScope::from_names(
            observed_bodies(&model_owned)
                .into_iter()
                .filter(|(_, body)| matches!(body, Expr::Operator(n) if n.op == "const"))
                .map(|(n, _)| n),
        ));
        // Resolve `join.on` value-equality clauses (RFC §5.3) FIRST, while each
        // aggregate range still carries its `{ "from": <index set> }` linkage so
        // the join key columns' member values can be read. A join whose key
        // columns resolve to the same loop symbol is the degenerate positional
        // no-op (byte-identical to the no-join form); a join over two distinct
        // loop symbols is the data-derived value-equality case and is lowered
        // into a member-equality `filter` over the contraction; a join over a
        // genuine (non-loop) data column is rejected rather than mis-combined.
        crate::join::resolve_aggregate_joins(&mut model_owned, index_sets)?;
        // Then rewrite every `{ "from": <index set> }` range reference (§5.2)
        // into a concrete `[lo, hi]` interval before shape inference / rule
        // building, so every downstream consumer sees only dense intervals.
        resolve_aggregate_ranges(&mut model_owned, index_sets)?;
        // Reject any aggregate whose ⊕ is spelled outside the schema's closed
        // `reduce` / `semiring` enums. The gate lives here, at the one funnel
        // every array-runtime build passes through, because the seams that
        // actually resolve ⊕ (`extract_derivative_arrayop`, `arrayop_spec`)
        // return `Option` and so could only decline silently.
        validate_oplus_spellings(&model_owned)?;

        // Stages (0)-(5) read the model immutably; only OWNED products leave
        // this block, so stage (6) below can borrow the model mutably (it
        // moves each observed body out of the variable registry).
        let (
            observed_names,
            eliminated,
            held_at_ic,
            slots,
            param_names,
            param_index,
            param_defaults,
        ) = {
            let model = &model_owned;

            // (0) Reject spatial differential operators anywhere in the model's
            // equations or observed-variable expressions (esm-i7b).
            reject_unlowered_spatial_ops(model)?;

            // (0b) Reject a reference to a variable bound in NONE of the model's
            // binding categories — the array-path analogue of the scalar
            // interpreter's `resolve_expr` "Unknown variable" gate. Without it a
            // typo'd/undeclared bare name falls through `lookup_variable`'s final
            // arm to a silent `NaN`, poisoning the trajectory.
            check_free_variables(model, index_sets)?;

            // (1) Collect state / parameter / observed variables.
            let (state_vars, param_vars, observed_vars) = classify_variables(model)?;

            // (2)+(2b) Infer state shapes from every equation usage, seeding
            // declared array shapes where the index-usage inference left an
            // array state scalar.
            let shape_map = infer_state_shapes(model, &state_vars, index_sets)?;

            // (3) Partition state variables into integrated / eliminated /
            // held-at-ic.
            let (final_states, eliminated, held_at_ic) = partition_states(model, &state_vars);

            // (4) Build flat offsets and scalar-slot names per state variable.
            let slots = build_slot_tables(model, &final_states, &shape_map);

            // (5) Build the param tables.
            let (param_names, param_index, param_defaults) = build_param_tables(model, &param_vars);

            // Stage (6) consumes the observed bodies by NAME (sorted order,
            // exactly the order `classify_variables` produced them in).
            let observed_names: Vec<String> =
                observed_vars.iter().map(|(n, _)| (*n).clone()).collect();
            (
                observed_names,
                eliminated,
                held_at_ic,
                slots,
                param_names,
                param_index,
                param_defaults,
            )
        };

        // (6)+(6b) Build the dependency-ordered observed algebraic rules,
        // MOVING each declared observed's body expression out of the model.
        let observed_rules =
            build_observed_rules(&mut model_owned, &observed_names, &eliminated, index_sets)?;

        let model = &model_owned;

        // Classify scoped-reference / array `ic` equations (esm-spec §11.4.1)
        // out of the rule builder into `field_ics` (see [`classify_field_ics`]).
        let field_ics = classify_field_ics(model);

        // (7)+(7b)+(8) Build the RHS rules, cover held-at-ic slots, and
        // validate that every state slot has a defining equation.
        let rhs_rules = build_rhs_rules(model, &slots, &held_at_ic)?;

        let SlotTables {
            var_shapes,
            scalar_state_names,
            scalar_state_index,
            state_defaults,
            n_states,
        } = slots;
        Ok(ArrayCompiled {
            var_shapes,
            scalar_state_names,
            scalar_state_index,
            state_defaults,
            param_names,
            param_index,
            param_defaults,
            observed_rules,
            rhs_rules,
            n_states,
            forcing: Rc::new(RefCell::new(HashMap::new())),
            field_ics,
            index_sets: index_sets.clone(),
            namespace: None,
            const_scope,
            precision: crate::precision::Env::capture(),
        })
    }
}

// ============================================================================
// `from_model` build stages. Each function is one numbered stage of the
// compile pipeline (its number matches the stage comment in
// [`ArrayCompiled::from_model`], which composes them in order); the bodies are
// extracted verbatim from the former inline implementation.
// ============================================================================

/// (0) Reject, at BUILD, every operator this runtime cannot evaluate — the
/// open rewrite-target tier (`grad`/`div`/`laplacian`, a spatial `D`, a user op,
/// a typo), which the canonical pipeline requires ESD discretization to have
/// rewritten before the simulator sees it (esm-i7b), AND the evaluable-core ops
/// that have no rule in this evaluator because an earlier stage was supposed to
/// eliminate them (`skolem`, `rank`, `distinct`, `argmin`, `argmax`, `ic`,
/// `enum`, `table_lookup`, `apply_expression_template`).
///
/// The second half is [`check_evaluable`]'s `is_evaluable_op` gate, and it is
/// here because [`eval_op`]'s backstop for an ungated op is `unreachable!` — a
/// PANIC, which is what an author got (exit 101, no diagnostic) from a document
/// that `esm validate` had just passed. The public `eval_expression` gated;
/// this path did not, and `hoist_static_observeds` walked straight into the
/// backstop. Gating the whole model once, at the single funnel every
/// array-runtime build passes through, closes the class rather than the one op
/// that was reported: any of the nine now raises `unevaluable_operator` naming
/// itself.
///
/// Ordering matters and is already right: `materialize_vi_outputs_to_data` and
/// `strip_value_invention` run BEFORE the staged build, so a legitimate
/// relational producer has become `const` data by the time this sees the model
/// — what remains is genuinely unevaluable.
fn reject_unlowered_spatial_ops(model: &Model) -> Result<(), CompileError> {
    for eq in &model.equations {
        check_evaluable_side(&eq.lhs)?;
        check_evaluable_side(&eq.rhs)?;
    }
    for var in model.variables.values() {
        let mut failure = None;
        var.for_each_expression(&mut |expr| {
            if failure.is_none()
                && let Err(e) = check_evaluable(expr)
            {
                failure = Some(e);
            }
        });
        if let Some(e) = failure {
            return Err(e);
        }
    }
    Ok(())
}

/// [`check_evaluable`] over one side of an equation, with the ONE structural
/// wrapper the array path consumes rather than evaluates unwrapped first: an
/// `ic` LHS (esm-spec §11.4). `ic` is evaluable-core and has no `eval_op` arm —
/// correctly, since initial-condition assembly reads the equation and the
/// evaluator never sees the node — so gating it as an ordinary expression would
/// reject every document that states an initial condition. Its OPERAND is
/// checked, so nothing inside it escapes the gate.
fn check_evaluable_side(expr: &Expr) -> Result<(), CompileError> {
    if let Expr::Operator(node) = expr
        && node.op == "ic"
    {
        for arg in &node.args {
            check_evaluable(arg)?;
        }
        return Ok(());
    }
    check_evaluable(expr)
}

/// (0b) Reject a reference to a variable that is bound in NONE of the model's
/// binding categories — the array-path analogue of the scalar interpreter's
/// [`crate::simulate`] `resolve_expr` "Unknown variable" gate. Without it a
/// typo'd or undeclared bare name falls through [`lookup_variable`]'s final arm
/// to a silent `NaN` sentinel, poisoning the whole trajectory instead of failing
/// loudly at build time. The error variant and message match the scalar path
/// (`InterpreterBuildError` / `Unknown variable '{name}' referenced in
/// expression`).
///
/// The bound set MIRRORS [`lookup_variable`]'s runtime resolution scope so a
/// legitimately runtime-bound name is never rejected — a false positive here
/// would reject a valid model, which is strictly worse than the silent-NaN it
/// closes:
///
///  * `t` — the independent variable (the array path only supports `t`);
///  * every declared model variable — state / parameter / observed, the keys of
///    `model.variables` (a discrete variable is rejected earlier, but its key is
///    still credited);
///  * every equation LHS-defined target (a name defined by an equation even if
///    not carried in `variables`);
///  * `_var` (§6.4 operator placeholder) and the document `index_sets` axis
///    names;
///  * spatial-coordinate symbols — the free symbols of every `ic` RHS (§11.4
///    defines these to BE coordinate expressions) and every spatial-op `dim`;
///  * loop / index binders introduced anywhere in the equation — `aggregate` /
///    `makearray` `output_idx` & `ranges`, bare `index(array, i…)` subscript
///    positions, an `integral` `int_var`, an argmin/argmax `arg`, and
///    `apply_expression_template` `bindings` keys. Collected over the WHOLE
///    equation (both sides unioned) so a stencil offset `index(u, i+1)` sees the
///    `i` bound as a bare position elsewhere in the same equation, and so a
///    symbol bound on the LHS is in scope on the RHS.
///
/// DELIBERATELY CONSERVATIVE SKIPS — a construct here is treated as BOUND, never
/// rejected, because a genuine typo in it is not provably distinguishable at
/// build time from a legitimate runtime-bound name:
///
///  * a DOTTED name (`A.b`) — a qualified cross-namespace reference or, on the
///    coupled/flatten path, an external *forcing* channel name (`M.src`,
///    `Box.scale`) that is UNDECLARED by design and resolved at runtime through
///    the forcing buffer (see [`lookup_variable`]'s final `forcing` arm and the
///    `segmented_refresh_solve` / `refresh_conformance` fixtures, which strip the
///    loader-fed `discrete` declarations precisely so these resolve as bare —
///    but post-flatten DOTTED — forcing names). A dotted typo is genuinely
///    indistinguishable from a dotted forcing name, so it is skipped;
///  * any name used as the HEAD of an `index(name, …)` op ANYWHERE in the model
///    — an array-valued leaf. On a single-model (`from_file`) path a loader-fed
///    forcing FIELD stays BARE and undeclared (the `observed_cadence_tier`
///    fixture's `f`), and a forcing field is always array-valued and read via
///    `index` (a SCALAR forcing goes through `params`/`set_params`, not the
///    buffer). Crediting every `index` head therefore keeps a bare forcing field
///    in scope; the residual conservative cost is that a typo appearing *only* as
///    an `index` head is not caught (reported as a deliberate skip);
///  * an `ic` equation — its RHS is a coordinate expression resolved at `u0`
///    build time by the field evaluator against grid geometry, not by the
///    per-cell RHS oracle; its free symbols are already credited as coordinates
///    above;
///  * a builtin function name spelled as a bare leaf (`exp`, `min`, …).
fn check_free_variables(
    model: &Model,
    index_sets: &HashMap<String, IndexSet>,
) -> Result<(), CompileError> {
    // ---- Build the bound set. ------------------------------------------------
    let mut bound: HashSet<String> = HashSet::new();
    bound.insert("t".to_string());
    bound.insert("_var".to_string());
    bound.extend(model.variables.keys().cloned());
    bound.extend(index_sets.keys().cloned());
    for eq in &model.equations {
        if let Some(v) = equation_defined_var(&eq.lhs) {
            bound.insert(v);
        }
        // §11.4: an `ic` RHS's free symbols name spatial coordinates that are
        // implicitly in scope (e.g. the ignition front `psi(x)` over the bare
        // coordinate `x`). Spatial-op `dim`s name the same axes.
        if is_ic_lhs(&eq.lhs) {
            collect_free_bare_symbols(&eq.rhs, &mut bound);
        }
        collect_dim_symbols(&eq.lhs, &mut bound);
        collect_dim_symbols(&eq.rhs, &mut bound);
        // Array-valued leaves (potential bare forcing FIELDS) — see the doc note.
        collect_index_head_names(&eq.lhs, &mut bound);
        collect_index_head_names(&eq.rhs, &mut bound);
    }
    for var in model.variables.values() {
        var.for_each_expression(&mut |expr| {
            collect_dim_symbols(expr, &mut bound);
            collect_index_head_names(expr, &mut bound);
        });
    }

    // ---- Check every equation (skipping `ic`) and observed expression. -------
    for eq in &model.equations {
        if is_ic_lhs(&eq.lhs) {
            continue;
        }
        let mut scope = bound.clone();
        collect_binders(&eq.lhs, &mut scope);
        collect_binders(&eq.rhs, &mut scope);
        check_expr_free_vars(&eq.lhs, &scope)?;
        check_expr_free_vars(&eq.rhs, &scope)?;
    }
    for var in model.variables.values() {
        let mut failure = None;
        var.for_each_expression(&mut |expr| {
            let mut scope = bound.clone();
            collect_binders(expr, &mut scope);
            if failure.is_none()
                && let Err(e) = check_expr_free_vars(expr, &scope)
            {
                failure = Some(e);
            }
        });
        if let Some(e) = failure {
            return Err(e);
        }
    }
    Ok(())
}

/// Is this LHS an initial-condition marker (`{"op": "ic", …}`)?
fn is_ic_lhs(lhs: &Expr) -> bool {
    matches!(lhs, Expr::Operator(op) if op.op == "ic")
}

/// The index / integration symbols a single node BINDS for its body (mirrors
/// `structural.rs` `bound_index_symbols`): `output_idx` / `ranges` keys, an
/// `integral` `int_var`, an argmin/argmax `arg`, the BARE subscript positions of
/// an `index(array, i…)` node, and `apply_expression_template` `bindings` keys.
fn node_binders(node: &ExpressionNode, out: &mut HashSet<String>) {
    if let Some(idx) = &node.output_idx {
        out.extend(idx.iter().cloned());
    }
    if let Some(ranges) = &node.ranges {
        out.extend(ranges.keys().cloned());
    }
    if let Some(v) = &node.int_var {
        out.insert(v.clone());
    }
    if let Some(a) = &node.arg {
        out.insert(a.clone());
    }
    if node.op == "index" {
        // Only a BARE position (`index(u, i)`) is a binder; an index EXPRESSION
        // (`index(u, i+1)`) is a USE of a symbol bound elsewhere and is checked.
        for arg in node.args.iter().skip(1) {
            if let Expr::Variable(name) = arg {
                out.insert(name.clone());
            }
        }
    }
    if let Some(bindings) = &node.bindings {
        out.extend(bindings.keys().cloned());
    }
}

/// Union every binder introduced anywhere in the subtree (whole-tree, like
/// `structural.rs` `collect_bound_symbols`). Widening the bound set only ever
/// prevents a false positive, which is the cardinal requirement here.
fn collect_binders(expr: &Expr, out: &mut HashSet<String>) {
    if let Expr::Operator(node) = expr {
        node_binders(node, out);
        node.for_each_child(&mut |child| collect_binders(child, out));
    }
}

/// Collect every free BARE (non-dotted, non-builtin) symbol in the subtree —
/// used to credit an `ic` RHS's coordinate symbols into the bound set.
fn collect_free_bare_symbols(expr: &Expr, out: &mut HashSet<String>) {
    match expr {
        Expr::Variable(name) if !name.contains('.') && !is_builtin_function_name(name) => {
            out.insert(name.clone());
        }
        Expr::Operator(node) => {
            node.for_each_child(&mut |child| collect_free_bare_symbols(child, out));
        }
        _ => {}
    }
}

/// Collect the bare name at the HEAD (first arg) of every `index(name, …)` op in
/// the subtree — an array-valued leaf (a declared state/observed, or a bare,
/// undeclared, loader-fed forcing FIELD read at runtime through the forcing
/// buffer). Crediting these keeps a legitimate bare forcing field in scope.
fn collect_index_head_names(expr: &Expr, out: &mut HashSet<String>) {
    if let Expr::Operator(node) = expr {
        if node.op == "index"
            && let Some(Expr::Variable(name)) = node.args.first()
            && !name.contains('.')
        {
            out.insert(name.clone());
        }
        node.for_each_child(&mut |child| collect_index_head_names(child, out));
    }
}

/// Collect the `dim` axis of every node that carries one, regardless of `op`
/// (esm-spec §4.9.1 (ii), as revised): a coordinate axis is resolved
/// STRUCTURALLY by the presence of a `dim` field, not by a hardcoded
/// spatial-operator name list (the sugar ops carry no privileged status).
/// Defensive: the array path rejects unlowered spatial ops earlier, but a
/// coordinate an `ic` RHS shares with a node's `dim` stays creditable.
fn collect_dim_symbols(expr: &Expr, out: &mut HashSet<String>) {
    if let Expr::Operator(node) = expr {
        if let Some(dim) = &node.dim {
            out.insert(dim.clone());
        }
        node.for_each_child(&mut |child| collect_dim_symbols(child, out));
    }
}

/// Reject the first bare (non-dotted) variable reference bound in none of the
/// categories in `scope`. Mirrors the scalar path's `resolve_expr` "Unknown
/// variable" error in both variant and message. The full expression-bearing
/// child set is descended via [`ExpressionNode::for_each_child`] (args plus the
/// sidecar fields), so a reference hidden in an aggregate body, filter, integral
/// bound, table axis, aggregate key, or template binding is not missed. A `fn`
/// op's callee lives in `node.name` (not a child), so it is never mistaken for a
/// variable.
fn check_expr_free_vars(expr: &Expr, scope: &HashSet<String>) -> Result<(), CompileError> {
    match expr {
        Expr::Variable(name) => {
            // A dotted name is a qualified / forcing reference resolved at
            // runtime; builtins and derivative markers are always valid.
            if name.contains('.') || is_builtin_function_name(name) || name.starts_with("d(") {
                return Ok(());
            }
            if scope.contains(name) {
                return Ok(());
            }
            Err(CompileError::build_err(format!(
                "Unknown variable '{name}' referenced in expression"
            )))
        }
        Expr::Operator(node) => {
            let mut first_err: Option<CompileError> = None;
            node.for_each_child(&mut |child| {
                if first_err.is_none()
                    && let Err(e) = check_expr_free_vars(child, scope)
                {
                    first_err = Some(e);
                }
            });
            match first_err {
                Some(e) => Err(e),
                None => Ok(()),
            }
        }
        _ => Ok(()),
    }
}

/// (1) Collect state / parameter / observed variables (sorted by name for a
/// deterministic build).
///
/// Every category is DERIVED (esm-spec §6.3.1), never read off a declared type:
/// an unknown is an ODE state or an observed according to the equation that
/// defines it, and a parameter is Brownian or discrete according to its
/// `update`. A Brownian parameter is an explicit unsupported-feature error,
/// never a silent drop, and so is a discrete one.
fn classify_variables(
    model: &Model,
) -> Result<(Vec<&String>, Vec<&String>, Vec<(&String, &ModelVariable)>), CompileError> {
    let mut state_vars: Vec<&String> = Vec::new();
    let mut param_vars: Vec<&String> = Vec::new();
    let mut observed_vars: Vec<(&String, &ModelVariable)> = Vec::new();

    let class = crate::classification::Classification::of(model);

    let mut var_keys: Vec<&String> = model.variables.keys().collect();
    var_keys.sort();
    for name in var_keys {
        let var = &model.variables[name];
        match var.var_type {
            // An ALGEBRAIC unknown joins the states: it is solved for rather
            // than eliminated, exactly as it was before 1.0.0 when it was
            // declared `state` and pinned by an expression-LHS equation.
            VariableType::Unknown => {
                if class.is_observed(name) {
                    observed_vars.push((name, var));
                } else {
                    state_vars.push(name);
                }
            }
            VariableType::Parameter => {
                if class.is_brownian(name) {
                    return Err(CompileError::UnsupportedFeatureError {
                        feature: "brownian".to_string(),
                        message: format!(
                            "Rust simulation backend does not support SDE models; parameter '{name}' carries a wiener update"
                        ),
                    });
                }
                if class.is_discrete_parameter(name) {
                    // A parameter refreshed from OUTSIDE the model — a `from`
                    // binding to a data source, or a registered `handler` — IS
                    // the forcing seam: its value is written into the forcing
                    // buffer between segments (by `crate::provider`'s refresh
                    // executor, or by the host through `forcing_handle`) and
                    // read back at the RHS. That is exactly the slot an
                    // observed with no defining rule occupies, so it goes
                    // there: `build_observed_rules` lowers only observeds that
                    // HAVE a definition, and `lookup_variable`'s forcing arm
                    // resolves the name at evaluation time.
                    if externally_refreshed(var) {
                        observed_vars.push((name, var));
                        continue;
                    }
                    // What is left is a parameter that recomputes itself from a
                    // symbolic `expression` at each refresh, which needs event
                    // machinery this backend does not have. Binning it as a
                    // state (integrated) or a plain parameter (frozen) would
                    // both be WRONG — and silently so. Fail loudly instead; the
                    // document still VALIDATES, it just cannot be simulated by
                    // this backend yet.
                    return Err(CompileError::UnsupportedFeatureError {
                        feature: "discrete".to_string(),
                        message: format!(
                            "Rust array simulation backend does not yet support a discrete parameter that recomputes itself symbolically; parameter '{name}' carries an `expression` update"
                        ),
                    });
                }
                param_vars.push(name);
            }
        }
    }
    Ok((state_vars, param_vars, observed_vars))
}

/// (2) Infer shapes for state variables from all equation usages, then (2b)
/// overwrite with each state's declared array `shape` where one is declared
/// and resolves. The declared shape (index-set names resolved to sizes via
/// the document registry) is AUTHORITATIVE over usage inference (esm-spec
/// §11), matching the Python binding: a whole-array `D(state)` never
/// index-uses the state, so inference alone collapses it to a scalar; and an
/// observed's halo gather (`index(q, clamp(i±k))` inside an extended-grid
/// aggregate, e.g. the duo grid's `duo_extend`) index-uses the state at
/// offsets past its true extent, so inference alone WIDENS it past the grid.
/// Usage inference remains the fallback for states with no (resolvable)
/// declared shape.
fn infer_state_shapes(
    model: &Model,
    state_vars: &[&String],
    index_sets: &HashMap<String, IndexSet>,
) -> Result<HashMap<String, Vec<usize>>, CompileError> {
    let mut shape_map = infer_shapes(state_vars, &model.equations)?;

    // (2b) Declared shapes are authoritative wherever they resolve.
    for name in state_vars {
        if let Some(decl) = model.variables.get(*name).and_then(|v| v.shape.as_ref()) {
            if !decl.is_empty() {
                if let Some(resolved) = resolve_declared_shape(decl, index_sets) {
                    shape_map.insert((*name).clone(), resolved);
                }
            }
        }
    }
    Ok(shape_map)
}

/// (3) Partition state variables into `(final_states, eliminated, held_at_ic)`.
/// A state with a `D` equation is integrated; one defined by an algebraic
/// equation (but no `D`) is eliminated to an observed; one with neither (an
/// `ic`-only field) is carried at its ic with zero derivative — kept as a
/// state so its cells are enumerated and held constant.
fn partition_states(
    model: &Model,
    state_vars: &[&String],
) -> (Vec<String>, HashSet<String>, HashSet<String>) {
    let derivative_targets = collect_derivative_targets(&model.equations);
    let algebraic_defined = collect_algebraic_defined(&model.equations);

    let mut final_states: Vec<String> = Vec::new();
    let mut eliminated: HashSet<String> = HashSet::new();
    let mut held_at_ic: HashSet<String> = HashSet::new();
    for name in state_vars {
        if derivative_targets.contains(*name) {
            final_states.push((*name).clone());
        } else if algebraic_defined.contains(*name) {
            // No D equation, but an algebraic equation defines it.
            eliminated.insert((*name).clone());
        } else {
            // No D and no algebraic definition: hold at ic (zero derivative).
            final_states.push((*name).clone());
            held_at_ic.insert((*name).clone());
        }
    }
    (final_states, eliminated, held_at_ic)
}

/// Flat state-vector tables built by [`build_slot_tables`] (stage 4),
/// mirroring the corresponding [`ArrayCompiled`] fields: per-variable
/// shape/offset descriptions plus the per-slot name / index / default tables.
struct SlotTables {
    var_shapes: IndexMap<String, VarShape>,
    scalar_state_names: Vec<String>,
    scalar_state_index: HashMap<String, usize>,
    state_defaults: Vec<Option<f64>>,
    n_states: usize,
}

/// (4) Build the flat offset and scalar-slot names per state variable
/// (column-major slot enumeration).
fn build_slot_tables(
    model: &Model,
    final_states: &[String],
    shape_map: &HashMap<String, Vec<usize>>,
) -> SlotTables {
    let mut var_shapes: IndexMap<String, VarShape> = IndexMap::new();
    let mut scalar_state_names: Vec<String> = Vec::new();
    let mut scalar_state_index: HashMap<String, usize> = HashMap::new();
    let mut state_defaults: Vec<Option<f64>> = Vec::new();
    let mut flat_offset: usize = 0;

    for name in final_states {
        let shape = shape_map.get(name).cloned().unwrap_or_default();
        let origin: Vec<i64> = if shape.is_empty() {
            Vec::new()
        } else {
            vec![1i64; shape.len()]
        };
        let default = model.variables.get(name).and_then(|v| v.default);
        let total = shape.iter().copied().product::<usize>().max(1);
        if shape.is_empty() {
            scalar_state_names.push(name.clone());
            scalar_state_index.insert(name.clone(), flat_offset);
            state_defaults.push(default);
        } else {
            // Generate per-element names in column-major order.
            for flat in 0..total {
                let multi = flat_to_multi_col_major(flat, &shape);
                let idx_str = multi
                    .iter()
                    .zip(origin.iter())
                    .map(|(v, o)| (v + *o as usize).to_string())
                    .collect::<Vec<_>>()
                    .join(",");
                let slot_name = format!("{name}[{idx_str}]");
                scalar_state_names.push(slot_name.clone());
                scalar_state_index.insert(slot_name, flat_offset + flat);
                state_defaults.push(default);
            }
        }
        var_shapes.insert(
            name.clone(),
            VarShape {
                shape,
                origin,
                flat_offset,
            },
        );
        flat_offset += total;
    }

    SlotTables {
        var_shapes,
        scalar_state_names,
        scalar_state_index,
        state_defaults,
        n_states: flat_offset,
    }
}

/// (5) Build the param tables: positional names, name → position index, and
/// per-position defaults.
fn build_param_tables(
    model: &Model,
    param_vars: &[&String],
) -> (Vec<String>, HashMap<String, usize>, Vec<Option<f64>>) {
    let param_names: Vec<String> = param_vars.iter().map(|s| (*s).clone()).collect();
    let param_index: HashMap<String, usize> = param_names
        .iter()
        .enumerate()
        .map(|(i, n)| (n.clone(), i))
        .collect();
    let param_defaults: Vec<Option<f64>> = param_vars
        .iter()
        .map(|n| model.variables.get(*n).and_then(|v| v.default))
        .collect();
    (param_names, param_index, param_defaults)
}

// ============================================================================
// Causal self-reference (recurrence) along one index axis — esm-spec §4.3.1.1
// ============================================================================
//
// An equation defining an array-shaped unknown `V` whose RHS reads
// `index(V, …)` at a strictly earlier position along one of the defining
// aggregate's output axes is a RECURRENCE DEFINITION of `V`. Detection is
// structural and costs a document that has no such read one walk of each
// algebraic RHS at build time; everything below is skipped when
// `collect_self_reads` finds nothing, which is the overwhelmingly common case.
//
// Rationale, alternatives, and the reason the lag is DERIVED rather than
// declared: `docs/content/rfcs/causal-self-reference-recurrence.md`.

/// One causal self-read found in a variable's own defining RHS.
struct SelfRead {
    /// The read's index arguments (`args[1..]` of the `index` node).
    args: Vec<Expr>,
    /// Bounds of every index symbol bound by an enclosing `aggregate` at the
    /// point the read was found — the scope a symbol-valued lag is proved in.
    /// Innermost binding wins, matching the evaluator's `loop_binds` shadowing.
    env: HashMap<String, (i64, i64)>,
}

/// A recurrence definition, lowered to the frame + per-cell body the sweep
/// runs (see [`AlgebraicRule::Recurrence`]).
struct RecurLowering {
    idx_names: Vec<String>,
    ranges: Vec<(i64, i64)>,
    body: Expr,
    axis: usize,
    max_lag: i64,
    lag_proven: bool,
}

fn recur_err(code: &str, detail: String) -> CompileError {
    CompileError::InterpreterBuildError {
        details: format!("{code}: {detail}"),
    }
}

/// The affine form of an index expression with respect to the frame symbol
/// `sym`: the coefficient of `sym`, plus the integer bounds of the symbol-free
/// part — `None` when those bounds cannot be proved.
///
/// The two halves carry different weight. The **coefficient** must be provable:
/// unless the expression carries `sym` exactly once with coefficient 1 it does
/// not name a position relative to the cell being written, and there is nothing
/// to interpret. The **constant part** need not be: an unprovable offset is a
/// lag whose sign is unknown, which esm-spec §4.3.1.1 admits and leaves to the
/// runtime's fail-closed read — a cell the sweep has not published cannot be
/// read, so an unprovable lag cannot produce a wrong number, only a fault.
///
/// Treating an unresolvable symbol as fatal instead would make the VALIDATOR
/// reject documents the evaluator accepts (it resolves ranges against the
/// registry first and so proves more), which is the one disagreement between
/// the two that is never defensible.
struct Affine {
    coef: i64,
    konst: Option<(i64, i64)>,
}

fn affine_in_sym(e: &Expr, sym: &str, env: &HashMap<String, (i64, i64)>) -> Option<Affine> {
    let konst = |lo: i64, hi: i64| {
        Some(Affine {
            coef: 0,
            konst: Some((lo, hi)),
        })
    };
    match e {
        Expr::Integer(n) => konst(*n, *n),
        Expr::Number(f) if f.fract() == 0.0 && f.is_finite() => {
            let n = *f as i64;
            konst(n, n)
        }
        Expr::Variable(v) if v == sym => Some(Affine {
            coef: 1,
            konst: Some((0, 0)),
        }),
        Expr::Variable(v) => Some(Affine {
            coef: 0,
            konst: env.get(v).copied(),
        }),
        Expr::Operator(node) if node.args.len() == 2 => {
            let a = affine_in_sym(&node.args[0], sym, env)?;
            let b = affine_in_sym(&node.args[1], sym, env)?;
            let both = a.konst.zip(b.konst);
            match node.op.as_str() {
                "+" => Some(Affine {
                    coef: a.coef + b.coef,
                    konst: both.map(|((la, ha), (lb, hb))| (la + lb, ha + hb)),
                }),
                "-" => Some(Affine {
                    coef: a.coef - b.coef,
                    konst: both.map(|((la, ha), (lb, hb))| (la - hb, ha - lb)),
                }),
                // Scaling only by a symbol-free integer whose value is PINNED
                // (`lo == hi`): otherwise the product is not affine with a known
                // coefficient, and the coefficient is the half that must be
                // provable.
                "*" => {
                    let (k, other) = match (a.coef, a.konst, b.coef, b.konst) {
                        (0, Some((lo, hi)), _, _) if lo == hi => (lo, &b),
                        (_, _, 0, Some((lo, hi))) if lo == hi => (lo, &a),
                        _ => return None,
                    };
                    Some(Affine {
                        coef: other.coef * k,
                        konst: other.konst.map(|(lo, hi)| {
                            let (p, q) = (lo * k, hi * k);
                            (p.min(q), p.max(q))
                        }),
                    })
                }
                _ => None,
            }
        }
        _ => None,
    }
}

/// How one index argument of a causal self-read relates to the frame symbol at
/// that axis. Written in terms of the LAG `sym - <index expression>`, so a
/// positive lag is an earlier position.
enum SelfIdx {
    /// The lag is exactly zero: the read stays on this axis's own cell, so this
    /// axis is not the one the recurrence folds along.
    Identity,
    /// A lag that is not provably zero-or-forward, so this axis IS the
    /// recurrence axis. `proven` records whether every value of the lag was
    /// shown `>= 1` statically; when it is false the read may name the cell
    /// being written or a later one for some values of a contracted symbol, and
    /// the runtime's fail-closed read is what rules those out (esm-spec
    /// §4.3.1.1 point 5) — a cell that has not been published cannot be read,
    /// whether the sweep will publish it later or never.
    Offset { proven: bool, max_lag: i64 },
    /// A lag that is provably `<= 0` for every value: a same-cell or forward
    /// read, which no sweep order can satisfy.
    Forward,
    /// Not affine in the frame symbol at all.
    Bad,
}

fn classify_self_index(arg: &Expr, sym: &str, env: &HashMap<String, (i64, i64)>) -> SelfIdx {
    // lag = sym - arg. `arg` must carry `sym` with coefficient exactly 1, or
    // "the previous position along this axis" is not what it names.
    let Some(Affine { coef, konst }) = affine_in_sym(arg, sym, env) else {
        return SelfIdx::Bad;
    };
    if coef != 1 {
        return SelfIdx::Bad;
    }
    let Some((clo, chi)) = konst else {
        // A lag whose sign could not be proved. Admitted as the recurrence
        // axis: it is not provably wrong, and the cells where it would be
        // ill-founded cannot be read (they are not published), so the runtime
        // faults there instead of returning a number.
        return SelfIdx::Offset {
            proven: false,
            max_lag: 0,
        };
    };
    let (lag_lo, lag_hi) = (-chi, -clo);
    if lag_lo == 0 && lag_hi == 0 {
        return SelfIdx::Identity;
    }
    if lag_hi <= 0 {
        return SelfIdx::Forward;
    }
    SelfIdx::Offset {
        proven: lag_lo >= 1,
        max_lag: lag_hi,
    }
}

/// Bounds every `aggregate` range in `node` contributes to the symbol scope.
fn aggregate_range_env(node: &ExpressionNode) -> Vec<(String, (i64, i64))> {
    node.ranges
        .as_ref()
        .map(|m| {
            m.iter()
                .filter_map(|(k, spec)| spec.bounds().map(|b| (k.clone(), (b[0], b[1]))))
                .collect()
        })
        .unwrap_or_default()
}

/// Walk `e` collecting every `index(var, …)` read, and note whether `var` is
/// ever read BARE (which is never a causal read — esm-spec §4.3.1.1 rejection
/// 4 — because the whole array does not exist during the sweep).
fn collect_self_reads(
    e: &Expr,
    var: &str,
    env: &mut Vec<(String, (i64, i64))>,
    out: &mut Vec<SelfRead>,
    bare: &mut bool,
) {
    match e {
        Expr::Integer(_) | Expr::Number(_) => {}
        Expr::Variable(v) => {
            if v == var {
                *bare = true;
            }
        }
        Expr::Operator(node) => {
            let pushed = if crate::aggregate::is_aggregate_op(&node.op) {
                let add = aggregate_range_env(node);
                let n = add.len();
                env.extend(add);
                n
            } else {
                0
            };
            let is_self_index = node.op == "index"
                && matches!(node.args.first(), Some(Expr::Variable(v)) if v == var);
            if is_self_index {
                // Innermost binding wins: later entries overwrite earlier ones.
                let mut snapshot: HashMap<String, (i64, i64)> = HashMap::new();
                for (k, v) in env.iter() {
                    snapshot.insert(k.clone(), *v);
                }
                out.push(SelfRead {
                    args: node.args[1..].to_vec(),
                    env: snapshot,
                });
            }
            // `args[0]` of a self-read is the name itself, not a bare read of
            // the array; every other operand is walked normally (an index
            // expression may itself contain a self-read).
            let skip = usize::from(is_self_index);
            for a in node.args.iter().skip(skip) {
                collect_self_reads(a, var, env, out, bare);
            }
            for side in [
                node.expr.as_deref(),
                node.filter.as_deref(),
                node.key.as_deref(),
                node.lower.as_deref(),
                node.upper.as_deref(),
            ]
            .into_iter()
            .flatten()
            {
                collect_self_reads(side, var, env, out, bare);
            }
            if let Some(vs) = node.values.as_ref() {
                for v in vs {
                    collect_self_reads(v, var, env, out, bare);
                }
            }
            env.truncate(env.len() - pushed);
        }
    }
}

/// Is `e` an `index(var, sym…)` whose indices are exactly `idx_names` in order
/// — the §4.3 indexed-aggregate LHS form?
fn lhs_identity_gather(e: &Expr, var: &str, idx_names: &[String]) -> bool {
    let Expr::Operator(node) = e else {
        return false;
    };
    if node.op != "index" || node.args.len() != idx_names.len() + 1 {
        return false;
    }
    if !matches!(node.args.first(), Some(Expr::Variable(v)) if v == var) {
        return false;
    }
    node.args[1..]
        .iter()
        .zip(idx_names)
        .all(|(a, want)| matches!(a, Expr::Variable(v) if v == want))
}

/// Cell-restrict an `aggregate` that produces the whole frame: move its output
/// indices out to the enclosing sweep, keeping its contraction, `filter`,
/// `reduce`, `join` and `key` intact so the body evaluates at one cell exactly
/// as §4.3.1 specifies for a non-recurrent aggregate.
///
/// When there is nothing left to contract or gate, the restriction IS the body,
/// so the wrapper is dropped — the common shape (`s[k] = f(s[k-1])`) then walks
/// one expression per cell rather than re-deriving an empty contraction.
fn cell_restrict_aggregate(node: &ExpressionNode, idx_names: &[String]) -> Expr {
    let body = node
        .expr
        .as_deref()
        .cloned()
        .unwrap_or(Expr::Number(f64::NAN));
    let remaining: HashMap<String, crate::types::RangeSpec> = node
        .ranges
        .as_ref()
        .map(|m| {
            m.iter()
                .filter(|(k, _)| !idx_names.iter().any(|n| n == *k))
                .map(|(k, v)| (k.clone(), v.clone()))
                .collect()
        })
        .unwrap_or_default();
    let gated = node.filter.is_some()
        || node.join.is_some()
        || node.key.is_some()
        || node.distinct == Some(true);
    if remaining.is_empty() && !gated {
        return body;
    }
    let mut restricted = node.clone();
    restricted.output_idx = Some(Vec::new());
    restricted.ranges = Some(remaining);
    Expr::operator(restricted)
}

/// Recognize and lower a recurrence definition of `var`.
///
/// `Ok(None)` — no causal self-read, so this equation is compiled exactly as it
/// was before this feature existed. `Err(…)` — a self-read that is not a
/// well-founded causal read, reported with the esm-spec §4.3.1.1 code. Never a
/// silent fallback: the pre-feature behaviour for every rejected shape here was
/// a plausible wrong number.
fn lower_recurrence(
    var: &str,
    lhs: &Expr,
    rhs: &Expr,
) -> Result<Option<RecurLowering>, CompileError> {
    let mut env: Vec<(String, (i64, i64))> = Vec::new();
    let mut reads: Vec<SelfRead> = Vec::new();
    let mut bare = false;
    collect_self_reads(rhs, var, &mut env, &mut reads, &mut bare);
    if reads.is_empty() {
        return Ok(None);
    }
    if bare {
        return Err(recur_err(
            "recurrence_not_wellfounded",
            format!(
                "'{var}' is read BARE in its own defining equation as well as through `index`. \
                 A bare read names the whole array, which does not exist while the recurrence \
                 sweeps it; read every self-reference through `index` at a strictly earlier \
                 position (esm-spec §4.3.1.1)."
            ),
        ));
    }

    // ---- the cell frame ----------------------------------------------------
    // Either the indexed-aggregate LHS form (`aggregate{expr: V[k…]} ~ …`) or a
    // bare LHS whose RHS is an aggregate over V's axes. Anything else has no
    // frame to sweep.
    let frame_node: &ExpressionNode = match (lhs, rhs) {
        (Expr::Operator(l), _) if crate::aggregate::is_aggregate_op(&l.op) => l.as_ref(),
        (Expr::Variable(v), Expr::Operator(r))
            if v == var && crate::aggregate::is_aggregate_op(&r.op) =>
        {
            r.as_ref()
        }
        _ => {
            return Err(recur_err(
                "recurrence_unsupported_form",
                format!(
                    "the definition of '{var}' reads '{var}' at an earlier position, but its \
                     shape gives the runtime no cell frame to sweep. Write the recurrence as one \
                     `aggregate` over the variable's axes — either `{var} ~ aggregate{{…}}` or \
                     `aggregate{{expr: index({var}, k…)}} ~ …` — with the base case as an \
                     `ifelse` guard in the body (esm-spec §4.3.1.1)."
                ),
            ));
        }
    };
    let idx_names: Vec<String> = frame_node.output_idx.clone().unwrap_or_default();
    if idx_names.is_empty() || idx_names.iter().any(|n| n.parse::<i64>().is_ok()) {
        return Err(recur_err(
            "recurrence_unsupported_form",
            format!(
                "the recurrence definition of '{var}' has no symbolic output index to fold \
                 along (`output_idx` is {idx_names:?}). A literal singleton dimension cannot be \
                 a recurrence axis (esm-spec §4.3.1.1)."
            ),
        ));
    }
    let ranges_map = frame_node.ranges.clone().unwrap_or_default();
    let mut ranges: Vec<(i64, i64)> = Vec::with_capacity(idx_names.len());
    for n in &idx_names {
        match ranges_map.get(n) {
            // `Interval` specifically: a `Strided` axis has no unambiguous
            // "previous position", and a ragged / derived / unresolved axis has
            // no static total order to fold along at all.
            Some(crate::types::RangeSpec::Interval([lo, hi])) => ranges.push((*lo, *hi)),
            other => {
                return Err(recur_err(
                    "recurrence_not_wellfounded",
                    format!(
                        "axis '{n}' of the recurrence definition of '{var}' is not a static \
                         unit-step ascending interval (range: {other:?}). A ragged, derived, \
                         strided or unresolved axis carries no total order to fold along \
                         (esm-spec §4.3.1.1)."
                    ),
                ));
            }
        }
    }

    // ---- the axis and the derived lag bound --------------------------------
    let frame_env: HashMap<String, (i64, i64)> = idx_names
        .iter()
        .cloned()
        .zip(ranges.iter().copied())
        .collect();
    let mut axis: Option<usize> = None;
    let mut max_lag: i64 = 0;
    let mut lag_proven = true;
    for read in &reads {
        if read.args.len() != idx_names.len() {
            return Err(recur_err(
                "recurrence_not_wellfounded",
                format!(
                    "a self-read of '{var}' supplies {} indices but its frame has {} axes \
                     ({idx_names:?}). Every causal self-read indexes every axis (esm-spec \
                     §4.3.1.1).",
                    read.args.len(),
                    idx_names.len()
                ),
            ));
        }
        let mut env = frame_env.clone();
        for (k, v) in &read.env {
            env.insert(k.clone(), *v);
        }
        let mut lagged: Option<(usize, i64)> = None;
        for (d, arg) in read.args.iter().enumerate() {
            match classify_self_index(arg, &idx_names[d], &env) {
                SelfIdx::Identity => {}
                SelfIdx::Forward => {
                    return Err(recur_err(
                        "recurrence_not_wellfounded",
                        format!(
                            "index {d} of a self-read of '{var}' names the cell being written, \
                             or a LATER one, on axis '{}'. A causal self-reference reads \
                             strictly EARLIER positions; no sweep order can satisfy a forward \
                             or same-cell read (esm-spec §4.3.1.1).",
                            idx_names[d]
                        ),
                    ));
                }
                SelfIdx::Offset { proven, max_lag: hi } => {
                    lag_proven &= proven;
                    if lagged.is_some() {
                        return Err(recur_err(
                            "recurrence_not_wellfounded",
                            format!(
                                "a self-read of '{var}' is offset on more than one axis. A \
                                 causal self-reference folds along exactly ONE axis; every \
                                 other index must be the bare frame symbol (esm-spec §4.3.1.1)."
                            ),
                        ));
                    }
                    lagged = Some((d, hi));
                }
                SelfIdx::Bad => {
                    return Err(recur_err(
                        "recurrence_not_wellfounded",
                        format!(
                            "index {d} of a self-read of '{var}' is not an offset of the frame \
                             symbol '{}'. A causal self-read names a position RELATIVE to the \
                             cell being written — `{} - c`, `{} - a`, `{} - a - c` — so that \
                             which axis the recurrence folds along, and in which direction, is \
                             decidable. An index that does not carry '{}' with coefficient 1 \
                             (a bare constant, `2*{}`, another axis's symbol) is rejected \
                             rather than guessed at (esm-spec §4.3.1.1).",
                            idx_names[d],
                            idx_names[d],
                            idx_names[d],
                            idx_names[d],
                            idx_names[d],
                            idx_names[d]
                        ),
                    ));
                }
            }
        }
        let Some((d, hi)) = lagged else {
            return Err(recur_err(
                "recurrence_not_wellfounded",
                format!(
                    "a self-read of '{var}' is at the SAME cell on every axis, so it defines \
                     '{var}' in terms of itself rather than of an earlier position. A causal \
                     self-reference must be strictly earlier along one axis (esm-spec §4.3.1.1)."
                ),
            ));
        };
        match axis {
            None => axis = Some(d),
            Some(prev) if prev == d => {}
            Some(prev) => {
                return Err(recur_err(
                    "recurrence_not_wellfounded",
                    format!(
                        "the self-reads of '{var}' disagree on the recurrence axis: one folds \
                         along '{}' and another along '{}'. A definition folds along exactly one \
                         axis (esm-spec §4.3.1.1).",
                        idx_names[prev], idx_names[d]
                    ),
                ));
            }
        }
        max_lag = max_lag.max(hi);
    }
    let axis = axis.expect("at least one self-read, each of which set the axis");

    // ---- the per-cell body -------------------------------------------------
    let body = match rhs {
        Expr::Operator(r)
            if crate::aggregate::is_aggregate_op(&r.op)
                && r.output_idx.as_deref() == Some(idx_names.as_slice()) =>
        {
            cell_restrict_aggregate(r, &idx_names)
        }
        // The indexed-aggregate LHS form whose RHS is already a cell body, or an
        // RHS aggregate over a DIFFERENT frame (which cannot be restricted onto
        // this one).
        other => {
            if lhs_identity_gather(
                frame_node.expr.as_deref().unwrap_or(&Expr::Integer(0)),
                var,
                &idx_names,
            ) {
                other.clone()
            } else {
                return Err(recur_err(
                    "recurrence_unsupported_form",
                    format!(
                        "the recurrence definition of '{var}' cannot be restricted to one cell: \
                         its RHS is not an `aggregate` over the frame {idx_names:?}, and its LHS \
                         is not the identity gather `index({var}, {})`. A self-read reached only \
                         through a `makearray` region, a `reshape`/`transpose`/`concat` operand, \
                         or an aggregate over a different frame cannot be sequenced cell by cell \
                         — the region order of a `makearray` fixes which write WINS, not the \
                         order cells are EVALUATED in (esm-spec §4.3.1.1, §4.3.2).",
                        idx_names.join(", ")
                    ),
                ));
            }
        }
    };

    Ok(Some(RecurLowering {
        idx_names,
        ranges,
        body,
        axis,
        max_lag,
        lag_proven,
    }))
}

/// (6) Build observed algebraic rules from eliminated state variables AND
/// from declared observed variables that define an expression, then (6b)
/// dependency-order them so each rule is evaluated only after the observeds it
/// reads (RFC §8.1): the geometry chain `const` polygons → `clip =
/// intersect_polygon` → `area = FAQ(clip)` must materialize the ring before
/// the FAQ over it. The rules are collected in sorted/equation order, which is
/// NOT dependency order; the stable Kahn sweep ([`dependency_order_observed`])
/// preserves declaration order among independent observeds (mirrors Python
/// `simulation._order_observed_equations`).
fn build_observed_rules(
    model: &mut Model,
    observed_names: &[String],
    eliminated: &HashSet<String>,
    index_sets: &HashMap<String, IndexSet>,
) -> Result<Vec<AlgebraicRule>, CompileError> {
    let mut observed_rules: Vec<AlgebraicRule> = Vec::new();
    let array_axes = declared_axis_names(model);

    // Declared observed variables with an `expression` field. An array-shaped
    // observed — a discretization-agnostic PDE leaf's `psi_x`, `grad_mag`,
    // `U_n`, `S_n`, a `const`-op field, a keyed-factor alias — is evaluated
    // WHOLESALE here: `eval` looks each array-valued observed reference up in
    // the observed-array map and broadcasts the elementwise ops over it, so a
    // readable intermediate decomposition (WS4) already runs as authored. The
    // rules are dependency-ordered below, so `grad_mag` materializes before
    // `U_n`/`S_n` read it.
    //
    // The definition is the EQUATION whose LHS names the unknown — esm 1.0.0
    // states an unknown's behaviour in `equations` and nowhere else, so this
    // reads the equation rather than the removed `variables[..].expression`
    // field. `observed_names` preserves the sorted order `classify_variables`
    // produced, so the rule order — and the stable dependency ordering below —
    // is unchanged.
    //
    // WHICH rule form it lowers to is decided by the LHS, and both forms matter:
    //
    // * an `aggregate` LHS (`aggregate{expr: w[i]} ~ aggregate{…}`) is a PER-CELL
    //   definition and lowers to [`AlgebraicRule::ArrayLoop`], the form the
    //   whole-array overlay vectorizes. Lowering it as a wholesale body instead
    //   silently drops a varying array observed onto the per-cell oracle — the
    //   dominant per-step cost for a coupled behaviour stack;
    // * a bare-variable LHS lowers WHOLESALE through [`lower_algebraic_body`]:
    //   `eval` materializes the body's arrays and broadcasts the elementwise ops
    //   over them, so a readable intermediate decomposition runs as authored.
    let mut def_eq: HashMap<String, &crate::types::Equation> = HashMap::new();
    for eq in &model.equations {
        if let crate::classification::LhsForm::Bare(name) = crate::classification::lhs_form(&eq.lhs)
        {
            def_eq.entry(name).or_insert(eq);
        }
    }
    for name in observed_names {
        let Some(eq) = def_eq.get(name.as_str()) else {
            continue;
        };
        // A CAUSAL SELF-REFERENCE (esm-spec §4.3.1.1) is recognized before
        // either ordinary lowering, because both of them would compile the
        // self-read as a gather on a variable that is not bound anywhere — the
        // pre-feature behaviour, which validated and then produced nothing.
        // `None` here means the RHS contains no self-read at all, so every
        // existing document takes exactly the paths below, unchanged.
        if let Some(r) = lower_recurrence(name, &eq.lhs, &eq.rhs)? {
            observed_rules.push(AlgebraicRule::Recurrence {
                var: name.clone(),
                output_idx_names: r.idx_names,
                output_ranges: r.ranges,
                body: Rc::new(r.body),
                axis: r.axis,
                max_lag: r.max_lag,
                lag_proven: r.lag_proven,
            });
            continue;
        }
        if let Some(a) = extract_algebraic_arrayop(&eq.lhs, &eq.rhs) {
            observed_rules.push(AlgebraicRule::ArrayLoop {
                var: a.var,
                output_idx_names: a.idx_names,
                output_ranges: a.ranges,
                body: Rc::new(a.body),
            });
        } else {
            observed_rules.push(lower_algebraic_body(
                name,
                eq.rhs.clone(),
                &array_axes,
                index_sets,
            )?);
        }
    }

    // Algebraic arrayop equations for ELIMINATED state variables — the same two
    // forms, for a name the DAE pass removed from the state vector rather than
    // one the classification calls observed. An observed's own defining equation
    // was lowered above, so it is skipped here rather than emitted twice.
    for eq in &model.equations {
        if let Some(a) = extract_algebraic_arrayop(&eq.lhs, &eq.rhs) {
            if eliminated.contains(&a.var) && !observed_names.contains(&a.var) {
                if let Some(r) = lower_recurrence(&a.var, &eq.lhs, &eq.rhs)? {
                    observed_rules.push(AlgebraicRule::Recurrence {
                        var: a.var.clone(),
                        output_idx_names: r.idx_names,
                        output_ranges: r.ranges,
                        body: Rc::new(r.body),
                        axis: r.axis,
                        max_lag: r.max_lag,
                        lag_proven: r.lag_proven,
                    });
                    continue;
                }
                observed_rules.push(AlgebraicRule::ArrayLoop {
                    var: a.var,
                    output_idx_names: a.idx_names,
                    output_ranges: a.ranges,
                    body: Rc::new(a.body),
                });
            }
            continue;
        }
        if let Expr::Variable(name) = &eq.lhs
            && eliminated.contains(name)
            && !observed_names.iter().any(|n| n == name)
        {
            observed_rules.push(lower_algebraic_body(
                name,
                eq.rhs.clone(),
                &array_axes,
                index_sets,
            )?);
        }
    }
    Ok(dependency_order_observed(observed_rules))
}

/// Wrap one algebraic body — a declared observed's `expression`, or the RHS of
/// a bare-`Variable`-LHS equation — in the rule form that evaluates it
/// correctly.
///
/// The default, and what every already-correct model keeps byte for byte, is
/// the WHOLESALE [`AlgebraicRule::Scalar`]: `eval` materializes the body's
/// arrays and broadcasts the elementwise ops over them. That broadcast is
/// POSITIONAL, so it is only right when the operands already sit on the
/// result's axes in the result's order.
///
/// When the target declares a `shape` and an operand does not carry all of it
/// (`p3: [lon,lat,lev] = w2 * z1` with `w2: [lon,lat]` and `z1: [lev]`),
/// positional broadcasting cannot express what the index-set names mean — each
/// operand must replicate along the axes it does NOT carry (esm-spec §4.3.4).
/// Such a body is lowered to the per-cell [`AlgebraicRule::ArrayLoop`] form
/// instead, which gathers each operand at its own axes exactly as the
/// equivalent `aggregate` spelling would. An operand carrying an index set the
/// result does not have is rejected by [`build_gather_plan`].
fn lower_algebraic_body(
    name: &str,
    body: Expr,
    array_axes: &HashMap<String, Vec<String>>,
    index_sets: &HashMap<String, IndexSet>,
) -> Result<AlgebraicRule, CompileError> {
    let scalar_rule = |body: Expr| AlgebraicRule::Scalar {
        var: name.to_string(),
        body: Rc::new(body),
    };
    let Some(target_axes) = array_axes.get(name) else {
        return Ok(scalar_rule(body));
    };
    let plan = build_gather_plan(&body, array_axes, name, Some(target_axes.as_slice()), false)?;
    if plan_is_identity(&plan, target_axes.len()) {
        return Ok(scalar_rule(body));
    }
    // Name alignment IS needed, but the declared axes cannot be densely sized
    // (a derived / ragged index set): keep the wholesale rule rather than
    // fabricate loop bounds.
    let Some(extents) = resolve_declared_shape(target_axes, index_sets) else {
        return Ok(scalar_rule(body));
    };
    let loops: Vec<String> = (0..extents.len())
        .map(|d| format!("_lp{d}_{name}"))
        .collect();
    let output_ranges: Vec<(i64, i64)> = extents.iter().map(|n| (1i64, *n as i64)).collect();
    let looped = index_array_leaves_by_loops(&body, array_axes, Some(&plan), &loops);
    Ok(AlgebraicRule::ArrayLoop {
        var: name.to_string(),
        output_idx_names: loops,
        output_ranges,
        body: Rc::new(looped),
    })
}

/// Classify scoped-reference / array `ic` equations (esm-spec §11.4.1) out of
/// the rule builder into `field_ics`, mirroring the flatten-path
/// classification — a single-model (`from_file`) build must fold
/// coordinate-expression / broadcast-constant ics into `u0` exactly as the
/// coupled path does. The RHS collected here has already been range-resolved
/// against the document registry by [`ArrayCompiled::from_model`].
fn classify_field_ics(model: &Model) -> Vec<(String, Expr)> {
    let mut field_ics: Vec<(String, Expr)> = Vec::new();
    for eq in &model.equations {
        if let Some(target) = crate::flatten::extract_ic_target(&eq.lhs) {
            field_ics.push((target, eq.rhs.clone()));
        }
    }
    field_ics
}

/// (7) Build the RHS rules. Each equation with a derivative LHS produces
/// either a scalar slot write, an indexed scalar slot write, or an array
/// loop — one lowering function per form below. Then (7b) held-at-ic states
/// (no `D`, no algebraic definition) carry every cell at its ic with zero
/// derivative — their slots are marked covered without emitting a rule (the
/// RHS zero-initializes `dy` each call and never writes them) — and (8) every
/// state slot must end up with a defining equation.
fn build_rhs_rules(
    model: &Model,
    slots: &SlotTables,
    held_at_ic: &HashSet<String>,
) -> Result<Vec<RhsRule>, CompileError> {
    let var_shapes = &slots.var_shapes;
    let mut rhs_rules: Vec<RhsRule> = Vec::new();
    let mut covered_slots: HashSet<usize> = HashSet::new();

    // Declared index-set axis NAMES of every array-shaped variable (state /
    // parameter / observed), used to lower a whole-array `D(state)` RHS into
    // per-cell gathers that align each operand BY NAME (esm-spec §4.3.4).
    let array_axes = declared_axis_names(model);

    for eq in &model.equations {
        if let Some(d) = extract_derivative_arrayop(&eq.lhs, &eq.rhs) {
            lower_arrayop_derivative(d, var_shapes, &mut covered_slots, &mut rhs_rules)?;
            continue;
        }
        // Scalar D(var, t) = rhs.
        if let Some((var, idx_opt)) = extract_derivative_scalar(&eq.lhs) {
            match idx_opt {
                Some(indices) => lower_indexed_derivative(
                    var,
                    &indices,
                    &eq.rhs,
                    var_shapes,
                    &mut covered_slots,
                    &mut rhs_rules,
                )?,
                None => lower_bare_derivative(
                    var,
                    &eq.rhs,
                    model,
                    &array_axes,
                    var_shapes,
                    &mut covered_slots,
                    &mut rhs_rules,
                )?,
            }
            continue;
        }
        // Otherwise: algebraic equation (or something we don't support).
        // If the LHS is algebraic for an eliminated variable it was
        // already consumed above; ignore here.
    }

    cover_held_at_ic_slots(held_at_ic, var_shapes, &mut covered_slots);
    check_state_slots_covered(slots, &covered_slots)?;

    Ok(rhs_rules)
}

/// Lower an array-op derivative over `(idx_names, ranges)` to one
/// [`RhsRule::ArrayLoop`], marking the covered slots.
fn lower_arrayop_derivative(
    d: DerivArrayop,
    var_shapes: &IndexMap<String, VarShape>,
    covered_slots: &mut HashSet<usize>,
    rhs_rules: &mut Vec<RhsRule>,
) -> Result<(), CompileError> {
    let DerivArrayop {
        var,
        idx_names,
        ranges,
        lhs_idx_exprs,
        body,
        contract_names,
        contract_dims,
        reduce,
        filter,
    } = d;
    if !var_shapes.contains_key(&var) {
        return Err(CompileError::build_err(format!(
            "Array-op derivative targets unknown state variable '{var}'"
        )));
    }
    // Mark the covered slots.
    let shape = &var_shapes[&var];
    for tuple in cartesian_range(&ranges) {
        // Map to column-major flat offset using actual LHS index expressions.
        let binds: HashMap<String, i64> = idx_names
            .iter()
            .zip(tuple.iter())
            .map(|(n, v)| (n.clone(), *v))
            .collect();
        let actual_multi: Vec<i64> = lhs_idx_exprs
            .iter()
            .map(|e| eval_simple_index(e, &binds))
            .collect();
        let flat = multi_to_flat_col_major(&actual_multi, &shape.shape, &shape.origin);
        covered_slots.insert(shape.flat_offset + flat);
    }
    rhs_rules.push(RhsRule::ArrayLoop {
        var_name: var,
        output_idx_names: idx_names,
        output_ranges: ranges,
        lhs_idx_exprs,
        body: Box::new(body),
        contract_names,
        contract_dims,
        reduce,
        filter,
    });
    Ok(())
}

/// Lower an indexed scalar derivative `D(var[i,…], t) = rhs` to one
/// [`RhsRule::IndexedScalar`] at the resolved slot.
fn lower_indexed_derivative(
    var: String,
    indices: &[i64],
    rhs: &Expr,
    var_shapes: &IndexMap<String, VarShape>,
    covered_slots: &mut HashSet<usize>,
    rhs_rules: &mut Vec<RhsRule>,
) -> Result<(), CompileError> {
    // Indexed: find slot.
    let shape = var_shapes.get(&var).ok_or_else(|| {
        CompileError::build_err(format!(
            "Scalar derivative targets unknown state variable '{var}'"
        ))
    })?;
    let flat = multi_to_flat_col_major(indices, &shape.shape, &shape.origin);
    let slot = shape.flat_offset + flat;
    covered_slots.insert(slot);
    rhs_rules.push(RhsRule::IndexedScalar {
        slot,
        body: Box::new(rhs.clone()),
    });
    Ok(())
}

/// Lower a bare-variable derivative `D(var, t) = rhs`: a plain scalar slot
/// write when the state is 0-D, otherwise one of the two whole-array lifts
/// ([`lower_wholearray_producer_lift`] / [`lower_wholearray_percell`]).
fn lower_bare_derivative(
    var: String,
    rhs: &Expr,
    model: &Model,
    array_axes: &HashMap<String, Vec<String>>,
    var_shapes: &IndexMap<String, VarShape>,
    covered_slots: &mut HashSet<usize>,
    rhs_rules: &mut Vec<RhsRule>,
) -> Result<(), CompileError> {
    let shape = var_shapes
        .get(&var)
        .ok_or_else(|| {
            CompileError::build_err(format!(
                "Scalar derivative targets unknown state variable '{var}'"
            ))
        })?
        .clone();
    // The result's declared index-set axis names, when they line up
    // with the shape actually compiled for it. This is what makes
    // the bare RHS's operands alignable BY NAME below; a state
    // whose shape was inferred from index usage rather than
    // declared (or declared at a different rank) has no usable
    // names and keeps the positional lowering.
    let target_axes: Option<&[String]> = model
        .variables
        .get(&var)
        .and_then(|v| v.shape.as_deref())
        .filter(|d| d.len() == shape.shape.len());
    if shape.shape.is_empty() {
        // Plain scalar D(var, t) = rhs.
        let slot = shape.flat_offset;
        covered_slots.insert(slot);
        rhs_rules.push(RhsRule::Scalar {
            slot,
            body: Box::new(rhs.clone()),
        });
    } else if rhs_has_array_producer(rhs) {
        lower_wholearray_producer_lift(
            var,
            rhs,
            &shape,
            target_axes,
            array_axes,
            covered_slots,
            rhs_rules,
        )?;
    } else {
        lower_wholearray_percell(
            var,
            rhs,
            &shape,
            target_axes,
            array_axes,
            covered_slots,
            rhs_rules,
        )?;
    }
    Ok(())
}

/// Whole-array `D(var) = <rhs containing a lowered stencil>`
/// (an array-PRODUCING `makearray`/`aggregate` in elementwise
/// position, the form a §9.6.3 discretization rewrite emits):
/// lift to the per-cell `arrayop` (ArrayLoop) form the
/// derivative partition consumes — output loops over the full
/// declared shape, each array leaf and array producer gathered
/// per cell via `index(node, loops…)`. This is the loop-form
/// analog of the Julia `_lift_wholearray_deriv_equations`
/// (shape_promotion.jl) and keeps the rule eligible for the
/// vectorized whole-array fast path (ess-bdm).
fn lower_wholearray_producer_lift(
    var: String,
    rhs: &Expr,
    shape: &VarShape,
    target_axes: Option<&[String]>,
    array_axes: &HashMap<String, Vec<String>>,
    covered_slots: &mut HashSet<usize>,
    rhs_rules: &mut Vec<RhsRule>,
) -> Result<(), CompileError> {
    let ndim = shape.shape.len();
    let loops: Vec<String> = (0..ndim).map(|d| format!("_lp{d}_{var}")).collect();
    let output_ranges: Vec<(i64, i64)> = shape
        .shape
        .iter()
        .zip(shape.origin.iter())
        .map(|(sz, o)| (*o, *o + *sz as i64 - 1))
        .collect();
    let lhs_idx_exprs: Vec<Expr> = loops.iter().map(|l| Expr::Variable(l.clone())).collect();
    let plan = build_gather_plan(rhs, array_axes, &var, target_axes, false)?;
    let body = index_array_leaves_by_loops(rhs, array_axes, Some(&plan), &loops);
    let total = shape.shape.iter().copied().product::<usize>().max(1);
    for flat in 0..total {
        covered_slots.insert(shape.flat_offset + flat);
    }
    rhs_rules.push(RhsRule::ArrayLoop {
        var_name: var.clone(),
        output_idx_names: loops,
        output_ranges,
        lhs_idx_exprs,
        body: Box::new(body),
        contract_names: Vec::new(),
        contract_dims: Vec::new(),
        // No contracted index, so ⊕ never folds anything; carry the schema's
        // stated default. (This used to be spelled `effective_reduce_kind(None,
        // None)`, which only obscured that there is no node to read it off.)
        reduce: ReduceKind::Sum,
        filter: None,
    });
    Ok(())
}

/// Whole-array `D(var) = <array-valued rhs>` over a declared
/// array shape: enumerate cells and emit one per-cell scalar
/// rule, indexing each array-shaped RHS leaf by that cell
/// (elementwise semantics). This is the array-runtime analog
/// of the Julia `_lift_wholearray_deriv_equations` lift.
fn lower_wholearray_percell(
    var: String,
    rhs: &Expr,
    shape: &VarShape,
    target_axes: Option<&[String]>,
    array_axes: &HashMap<String, Vec<String>>,
    covered_slots: &mut HashSet<usize>,
    rhs_rules: &mut Vec<RhsRule>,
) -> Result<(), CompileError> {
    let plan = build_gather_plan(rhs, array_axes, &var, target_axes, true)?;
    let total = shape.shape.iter().copied().product::<usize>().max(1);
    for flat in 0..total {
        let multi0 = flat_to_multi_col_major(flat, &shape.shape);
        let cell: Vec<i64> = multi0
            .iter()
            .zip(shape.origin.iter())
            .map(|(m, o)| *m as i64 + *o)
            .collect();
        let body = index_array_leaves(rhs, array_axes, Some(&plan), &cell);
        let slot = shape.flat_offset + flat;
        covered_slots.insert(slot);
        rhs_rules.push(RhsRule::IndexedScalar {
            slot,
            body: Box::new(body),
        });
    }
    Ok(())
}

/// (7b) Held-at-ic states (no `D`, no algebraic definition) carry every
///      cell at its ic with zero derivative: mark their slots covered
///      without emitting a rule. The RHS zero-initializes `dy` each call
///      and never writes these slots, so they stay constant (a state that
///      feeds an observed — e.g. `phi` into `heat_release` — must not
///      drift).
fn cover_held_at_ic_slots(
    held_at_ic: &HashSet<String>,
    var_shapes: &IndexMap<String, VarShape>,
    covered_slots: &mut HashSet<usize>,
) {
    for name in held_at_ic {
        if let Some(vs) = var_shapes.get(name) {
            let total = vs.shape.iter().copied().product::<usize>().max(1);
            for k in 0..total {
                covered_slots.insert(vs.flat_offset + k);
            }
        }
    }
}

/// (8) Every state slot must have a defining equation.
fn check_state_slots_covered(
    slots: &SlotTables,
    covered_slots: &HashSet<usize>,
) -> Result<(), CompileError> {
    for (i, name) in slots.scalar_state_names.iter().enumerate() {
        if !covered_slots.contains(&i) {
            return Err(CompileError::build_err(format!(
                "State slot '{name}' has no defining derivative equation."
            )));
        }
    }
    Ok(())
}

/// Evaluate a state-free build-time expression (grid geometry, §11.4.1
/// coordinate-expression `ic` RHSs, §6.6.5 analytic `reference`s) through the
/// official array evaluator. Array-producing `aggregate`/`makearray` nodes
/// yield arrays; elementwise ops broadcast over them. Any `{ "from": <set> }`
/// range references are resolved against `index_sets` first, so a raw
/// (pre-compile) expression evaluates exactly as an equation expression does
/// after [`crate::aggregate::resolve_aggregate_ranges`].
///
/// STATE references are not in scope — the context carries no states. Model
/// PARAMETERS (load-time constants) ARE in scope when supplied via `params`
/// (name → value): a parameter-dependent coordinate expression / reference then
/// resolves (esm-spec §6.6.5). Mirrors the Python `_eval_buildtime_field` /
/// Julia `_eval_cellwise` machinery.
pub(crate) fn eval_buildtime_field(
    expr: &Expr,
    index_sets: &HashMap<String, IndexSet>,
    params: &HashMap<String, f64>,
) -> Result<Value, CompileError> {
    let mut resolved = expr.clone();
    crate::aggregate::resolve_expr_ranges(&mut resolved, index_sets)?;
    let param_names: Vec<String> = params.keys().cloned().collect();
    let param_vec: Vec<f64> = param_names.iter().map(|n| params[n]).collect();
    eval_expression(&resolved, &HashMap::new(), &param_vec, &param_names, 0.0)
}

/// Resolve one grid cell's initial value for a scoped-reference / array `ic`
/// equation (esm-spec §11.4.1). `cell` is the 0-based multi-index of the element
/// within the target's grid shape. Supported RHS forms, in order:
///
/// 1. A LOADED FIELD — a bare reference to a provider-served forcing entry that
///    supplies the initial field over the lifted grid. The cell is read directly
///    when the field's rank matches the target grid; a single-element field is
///    broadcast.
/// 2. A BROADCAST CONSTANT — an RHS that const-folds to a finite scalar.
/// 3. A COORDINATE EXPRESSION — an elementwise expression over array-producing
///    `aggregate`/`makearray` nodes (e.g. `cos(pi * x_coord)` where `x_coord`
///    is a grid-geometry aggregate expanded from a §9.7 template import),
///    evaluated through the official array evaluator ([`eval_buildtime_field`])
///    in a state-free context and indexed at this cell.
///
/// Anything else is a hard error, so a scoped-reference ic that cannot be resolved
/// is never silently dropped. Mirrors tree_walk.jl `_resolve_field_ic` and the
/// Python `_resolve_field_ic`.
pub(super) fn resolve_field_ic_cell(
    target: &str,
    rhs: &Expr,
    cell: &[usize],
    forcing: &HashMap<String, ArrayD<f64>>,
    index_sets: &HashMap<String, IndexSet>,
    params: &HashMap<String, f64>,
    // Per-target memo of the case-(3) whole-field evaluation (cell-independent),
    // so the coordinate expression is evaluated once per target rather than once
    // per cell. `None` on entry for the first cell; filled on first use.
    cached_field: &mut Option<Value>,
) -> Result<f64, SimulateError> {
    // (1) Loaded field served through the provider forcing buffer.
    if let Expr::Variable(name) = rhs
        && let Some(arr) = forcing.get(name)
    {
        if arr.ndim() == cell.len() {
            return Ok(arr[IxDyn(cell)]);
        } else if arr.len() == 1 {
            return Ok(arr.iter().copied().next().unwrap());
        }
        return Err(SimulateError::InvalidFieldInitialCondition {
            name: target.to_string(),
            details: format!(
                "loaded field '{name}' has ndim={} which does not match the {}-D lifted target grid",
                arr.ndim(),
                cell.len()
            ),
        });
    }
    // (2) Broadcast constant. Finite-only: `fold_constant_expr` renders any op
    // outside the scalar interpreter (an `aggregate` grid-geometry node) as
    // NaN rather than erroring, and a NaN must fall through to the
    // coordinate-expression path — never silently seed the state vector.
    if let Ok(c) = crate::simulate::fold_constant_expr(rhs, params)
        && c.is_finite()
    {
        return Ok(c);
    }
    // (3) Coordinate expression over grid-geometry aggregates (model
    // parameters — e.g. a free-name geometry `x0`/`dx` — bind via `params`).
    // The whole-field evaluation is memoized in `cached_field` (see caller): it
    // is cell-independent, so it runs once per target instead of once per cell.
    if let Expr::Operator(_) = rhs {
        if cached_field.is_none() {
            // On a `CompileError` the memo stays empty and we fall through to
            // the case-(4) hard error below (byte-identical to the old
            // `match … { _ => {} }` arm, which likewise dropped the error).
            if let Ok(v) = eval_buildtime_field(rhs, index_sets, params) {
                *cached_field = Some(v);
            }
        }
        match cached_field.as_ref() {
            Some(Value::Scalar(s)) if s.is_finite() => return Ok(*s),
            Some(Value::Array(arr)) => {
                if arr.ndim() != cell.len() {
                    return Err(SimulateError::InvalidFieldInitialCondition {
                        name: target.to_string(),
                        details: format!(
                            "coordinate expression evaluates to ndim={}, which does not match the {}-D lifted target grid",
                            arr.ndim(),
                            cell.len()
                        ),
                    });
                }
                let v = arr[IxDyn(cell)];
                if v.is_finite() {
                    return Ok(v);
                }
            }
            _ => {}
        }
    }
    // (4) Unsupported RHS — a clear error, never a silent drop.
    let hint = match rhs {
        Expr::Variable(name) => format!(" (no provider field named '{name}')"),
        _ => String::new(),
    };
    Err(SimulateError::InvalidFieldInitialCondition {
        name: target.to_string(),
        details: format!(
            "RHS is neither a provider-served loaded field, a constant, nor a per-cell coordinate expression{hint}"
        ),
    })
}

// ============================================================================
// Shape inference + LHS parsing helpers.
// ============================================================================

/// The variable a top-level equation defines, if any: `v = …`, `index(v, …) = …`,
/// `D(v) = …` / `D(index(v, …)) = …`, `ic(v) = …`, or an `arrayop`/`aggregate`
/// whose body is `D(index(v, …))` / `index(v, …)`. Used to prune value-invention
/// equations and to classify algebraic definitions.
pub(super) fn equation_defined_var(lhs: &Expr) -> Option<String> {
    match lhs {
        Expr::Variable(v) => Some(v.clone()),
        Expr::Operator(node) => match node.op.as_str() {
            "index" => match node.args.first() {
                Some(Expr::Variable(v)) => Some(v.clone()),
                _ => None,
            },
            "D" | "ic" => match node.args.first() {
                Some(Expr::Variable(v)) => Some(v.clone()),
                Some(inner) => equation_defined_var(inner),
                None => None,
            },
            op if is_aggregate_op(op) => node.expr.as_ref().and_then(|b| equation_defined_var(b)),
            _ => None,
        },
        _ => None,
    }
}

/// The state variable an *algebraic* (non-`D`, non-`ic`) equation defines, if any.
/// A state so-defined is eliminated to an observed rather than integrated.
pub(super) fn algebraic_defined_var(lhs: &Expr) -> Option<String> {
    match lhs {
        Expr::Variable(v) => Some(v.clone()),
        Expr::Operator(node) => match node.op.as_str() {
            "index" => match node.args.first() {
                Some(Expr::Variable(v)) => Some(v.clone()),
                _ => None,
            },
            op if is_aggregate_op(op) => {
                // `arrayop(expr = index(v, …))` — but NOT `expr = D(index(v, …))`,
                // which is a derivative, not an algebraic definition.
                let body = node.expr.as_ref()?;
                if let Expr::Operator(b) = body.as_ref() {
                    if b.op == "D" {
                        return None;
                    }
                }
                equation_defined_var(body)
            }
            _ => None,
        },
        _ => None,
    }
}

/// Every state variable defined by an algebraic equation (see
/// [`algebraic_defined_var`]).
pub(super) fn collect_algebraic_defined(equations: &[crate::types::Equation]) -> HashSet<String> {
    let mut out = HashSet::new();
    for eq in equations {
        if let Some(v) = algebraic_defined_var(&eq.lhs) {
            out.insert(v);
        }
    }
    out
}

/// True if `expr` (or any subexpression) uses a `skolem` op — the marker of a
/// value-invention (relational) producer whose integer-id buffer the dense
/// array evaluator does not materialize.
pub(super) fn expr_contains_skolem(expr: &Expr) -> bool {
    match expr {
        Expr::Number(_) | Expr::Integer(_) | Expr::Variable(_) => false,
        Expr::Operator(node) => node.op == "skolem" || node.any_child(&mut expr_contains_skolem),
    }
}

/// Collect the `id`s of every geometry ring producer (`intersect_polygon` /
/// `polygon_intersection_area`) reachable from `expr`. A `kind: "derived"` index
/// set whose `from_faq` names one of these is the materialized clip ring (kept),
/// distinguishing it from a relational membership set (dropped).
pub(super) fn collect_geometry_producer_ids(expr: &Expr, out: &mut HashSet<String>) {
    let Expr::Operator(node) = expr else {
        return;
    };
    if matches!(
        node.op.as_str(),
        "intersect_polygon" | "polygon_intersection_area"
    ) {
        if let Some(id) = &node.id {
            out.insert(id.clone());
        }
    }
    node.for_each_child(&mut |child| collect_geometry_producer_ids(child, out));
}

/// Strip every `join.on` key-pair that references a dropped value-invention
/// variable, dropping a clause whose pairs all vanish and clearing an empty
/// `join`. A bin-skolem broad-phase gate keyed on such a column cannot be
/// evaluated by the dense array runtime (the integer-id buffer is not
/// materialized); eliding it degrades the aggregate to the dense contraction
/// over all index combinations — the pruned combinations contribute the
/// additive identity, which for a geometric narrow phase (`polygon_intersection_area`,
/// zero on non-overlapping pairs) they already do, so the result is unchanged.
pub(super) fn strip_vi_joins(expr: &mut Expr, vi_cols: &HashSet<String>) {
    // Sharing-aware gate: after load-time interning (`crate::intern`)
    // operator payloads are shared `Arc`s, and a mutable descent
    // copy-on-write splits every node it touches. Only branches actually
    // carrying a `join` clause are descended; a join-free subtree (every
    // subtree of a §9.7-expanded discretization) is left fully shared.
    fn contains_join(e: &Expr) -> bool {
        match e {
            Expr::Operator(node) => node.join.is_some() || node.any_child(&mut contains_join),
            _ => false,
        }
    }
    if !contains_join(expr) {
        return;
    }
    let Some(node) = expr.node_mut() else {
        return;
    };
    if let Some(joins) = &mut node.join {
        for clause in joins.iter_mut() {
            clause
                .on
                .retain(|pair| !pair.iter().any(|c| vi_cols.contains(c)));
        }
        // An OVERLAP clause carries no `on` pairs at all and is kept: it names
        // const-array envelope FACTORS, not value-invention id columns, and it
        // DRIVES the dense enumeration (CONFORMANCE_SPEC §5.5.6). Only a
        // bin-equality clause whose every pair referenced a dropped column is
        // now empty and inert.
        joins.retain(|clause| !clause.on.is_empty() || clause.overlap.is_some());
        if joins.is_empty() {
            node.join = None;
        }
    }
    node.for_each_child_mut(&mut |child| strip_vi_joins(child, vi_cols));
}

/// Drop value-invention (relational) variables and their defining equations, and
/// strip broad-phase `join.on` gates that reference them, BEFORE join / range
/// resolution and shape inference.
///
/// The dense Rust array runtime evaluates FAQ aggregates and the fused geometry
/// leaf, but does NOT materialize value-invention buffers — skolem-id maps
/// (`skolem`/`rank`) or a membership set over a `kind: "derived"` (FAQ-produced)
/// index set. A variable that is one of these, and the `join.on` gate keyed on
/// it, are relational scaffolding around a densely-evaluable narrow phase. For a
/// conservative regrid the narrow phase is `polygon_intersection_area`, which is
/// zero on exactly the pairs the bin-skolem gate would prune, so the dense
/// contraction is numerically identical (see [`strip_vi_joins`]). This keeps the
/// coupled regrid runnable without porting the build-time relational engine,
/// while leaving genuine (loop-symbol) joins and non-VI models byte-identical:
/// the pass is a no-op unless a `skolem` op or a derived-set-shaped variable is
/// present.
pub(super) fn strip_value_invention(
    model: &mut Model,
    index_sets: &HashMap<String, IndexSet>,
) -> Result<(), CompileError> {
    let mut vi_vars: HashSet<String> = HashSet::new();
    // Ids of geometry ring producers (`intersect_polygon` / `polygon_intersection_area`).
    // A `kind: "derived"` index set whose `from_faq` names one of these IS
    // materialized by the dense runtime (the clipped overlap ring), so a variable
    // shaped over it — e.g. a geometry `clip` — must be KEPT.
    let mut geom_ids: HashSet<String> = HashSet::new();
    for eq in &model.equations {
        collect_geometry_producer_ids(&eq.rhs, &mut geom_ids);
    }
    // An observed unknown's defining body is one of those equation RHSs from
    // esm 1.0.0, so the loop above already covers it; what is left on a
    // variable is a parameter `update`'s expressions.
    for var in model.variables.values() {
        var.for_each_expression(&mut |expr| collect_geometry_producer_ids(expr, &mut geom_ids));
    }
    // (a) A variable shaped over a `kind: "derived"` index set whose FAQ producer
    //     is NOT a geometry ring producer — a relational membership / candidate
    //     set the dense runtime does not enumerate.
    for (name, var) in &model.variables {
        if let Some(shape) = &var.shape {
            if shape.iter().any(|s| {
                index_sets
                    .get(s)
                    .filter(|is| is.kind == "derived")
                    .map(|is| {
                        !is.from_faq
                            .as_deref()
                            .map(|f| geom_ids.contains(f))
                            .unwrap_or(false)
                    })
                    .unwrap_or(false)
            }) {
                vi_vars.insert(name.clone());
            }
        }
    }
    // (b) A variable defined by an equation whose RHS produces a skolem id.
    for eq in &model.equations {
        if expr_contains_skolem(&eq.rhs) {
            if let Some(v) = equation_defined_var(&eq.lhs) {
                vi_vars.insert(v);
            }
        }
    }
    if vi_vars.is_empty() {
        return Ok(());
    }
    model.variables.retain(|k, _| !vi_vars.contains(k));
    model.equations.retain(|eq| {
        equation_defined_var(&eq.lhs)
            .map(|v| !vi_vars.contains(&v))
            .unwrap_or(true)
    });
    // `join.on` columns are NOT namespaced by flatten (they are bare strings, not
    // expressions), while the dropped variable keys ARE model-prefixed. Match a
    // join column against both the qualified VI name and its unqualified suffix so
    // a coupled `join.on [[rg_src_bin, rg_tgt_bin]]` gate is stripped even though
    // its columns stayed unqualified.
    let mut vi_cols: HashSet<String> = vi_vars.clone();
    for v in &vi_vars {
        if let Some(pos) = v.rfind('.') {
            vi_cols.insert(v[pos + 1..].to_string());
        }
    }
    for eq in &mut model.equations {
        strip_vi_joins(&mut eq.lhs, &vi_cols);
        strip_vi_joins(&mut eq.rhs, &vi_cols);
    }
    for var in model.variables.values_mut() {
        var.for_each_expression_mut(&mut |expr| strip_vi_joins(expr, &vi_cols));
    }
    Ok(())
}

// ===========================================================================
// Value-invention OUTPUT front-door — materialize the arg-witness / grouped
// relational outputs to constant data (the previously-unwired engine).
// ===========================================================================

/// True iff any equation or observed expression in `model` contains an
/// arg-witness reducer (`argmin` / `argmax`). Mirrors [`expr_contains_skolem`]:
/// its presence is the marker of a genuine relational OUTPUT — a per-element
/// nearest-witness INDEX buffer (RFC §5.7 rule 6) — that the dense evaluator
/// cannot run and [`strip_value_invention`] does not remove (it is neither a
/// derived-set-shaped var nor a skolem producer). This gates the build-time
/// materialize pass so every model WITHOUT one stays byte-identical.
fn expr_contains_arg_witness(expr: &Expr) -> bool {
    match expr {
        Expr::Number(_) | Expr::Integer(_) | Expr::Variable(_) => false,
        Expr::Operator(node) => {
            node.op == "argmin"
                || node.op == "argmax"
                || node.any_child(&mut expr_contains_arg_witness)
        }
    }
}

fn model_contains_arg_witness(model: &Model) -> bool {
    model
        .equations
        .iter()
        .any(|eq| expr_contains_arg_witness(&eq.lhs) || expr_contains_arg_witness(&eq.rhs))
        || model.variables.values().any(|v| {
            let mut found = false;
            v.for_each_expression(&mut |e| found |= expr_contains_arg_witness(e));
            found
        })
}

/// Is this parameter refreshed from OUTSIDE the model — every update rule
/// reading either a data source (`from`) or a registered handler?
///
/// Both are the FORCING seam: the value arrives from the runtime between
/// segments rather than being computed by the model, which is what lets this
/// backend serve it out of the forcing buffer with no event machinery of its
/// own (CONFORMANCE_SPEC §5.10.1, §5.13.2). A rule with an `expression` value
/// form is the opposite case — the model computes it, and something has to run
/// that computation on each refresh.
fn externally_refreshed(var: &ModelVariable) -> bool {
    let Some(spec) = &var.update else {
        return false;
    };
    spec.rules().iter().all(|rule| {
        rule.value()
            .is_some_and(|v| v.from.is_some() || v.handler.is_some())
    })
}

/// name → defining RHS for every OBSERVED unknown of `model`
/// (esm-spec §6.3.1).
///
/// The one place this pipeline asks "what defines this observed?" — from esm
/// 1.0.0 the answer is the equation whose LHS is the bare variable, never a
/// `variables[v].expression` field. Sorted by name (a `BTreeMap`), so every
/// consumer iterates deterministically.
fn observed_bodies(model: &Model) -> std::collections::BTreeMap<String, Expr> {
    crate::classification::Classification::from_parts(&model.variables, &model.equations)
        .observed_definitions
}

/// Gather the build-time-CONSTANT factor arrays the value-invention engine reads
/// (`index(gx, g)` etc.): every variable whose `expression` is a `const` op (the
/// established self-contained build-time array channel — see the geometry
/// `src_poly`/`tgt_poly` fixtures). Each is evaluated once, with no state /
/// params / `t` (a `const` literal needs none), into its dense `ArrayD`. This is
/// the Rust analogue of the Julia reference's `const_arrays` registry and the
/// Python interpreter's join-free const-observed pre-materialization.
fn collect_const_factor_arrays(model: &Model) -> HashMap<String, ArrayD<f64>> {
    let mut out: HashMap<String, ArrayD<f64>> = HashMap::new();
    for (name, body) in observed_bodies(model) {
        let expr = &body;
        let Expr::Operator(node) = expr else { continue };
        if node.op != "const" {
            continue;
        }
        match eval_expression(expr, &HashMap::new(), &[], &[], 0.0) {
            Ok(Value::Array(a)) => {
                out.insert(name.clone(), *a);
            }
            Ok(Value::Scalar(s)) => {
                out.insert(name.clone(), ArrayD::from_elem(IxDyn(&[]), s));
            }
            Err(_) => {}
        }
    }
    out
}

/// The value-invention engine's factor arrays for `model`: the `const`-literal
/// variables [`collect_const_factor_arrays`] finds, OVERLAID with the caller's
/// arrays (caller wins on a name collision).
///
/// The overlay exists because a real model's factors do not live in the
/// document. In ISRM the overlap gate's envelope factors — `X`/`Y` (emission
/// points) and `W`/`S`/`E`/`N` (cell rectangles) — are declared
/// `type: "parameter"` and filled by data loaders through `coupling`
/// `param_to_var` edges. They carry no `const` expression, so the scan finds
/// nothing for them, the gate cannot build an envelope, and the producer
/// invents no members. Only the caller holds those arrays, and before this
/// there was no way to hand them over on the in-tree build path.
///
/// Caller-wins (rather than const-wins) is the deliberate direction: a caller
/// that supplies an array is asserting the value it loaded, and a document
/// `const` — typically a small placeholder or a default — must not silently
/// override real data. It also makes the channel usable for OVERRIDES, matching
/// the Julia reference's `const_arrays=` kwarg.
fn vi_factor_arrays<S: std::hash::BuildHasher>(
    model: &Model,
    caller_arrays: Option<&HashMap<String, ArrayD<f64>, S>>,
) -> HashMap<String, ArrayD<f64>> {
    let mut arrays = collect_const_factor_arrays(model);
    if let Some(extra) = caller_arrays {
        for (name, arr) in extra {
            arrays.insert(name.clone(), arr.clone());
        }
    }
    arrays
}

/// Scalar parameter defaults, the value-invention engine's scalar `params` map
/// (e.g. the bin width of a broad-phase skolem quantization). Only 0-D
/// parameters with a `default` contribute — an array parameter carries no inline
/// data and is supplied (if at all) through [`collect_const_factor_arrays`].
fn collect_scalar_param_defaults(model: &Model) -> HashMap<String, f64> {
    let mut out: HashMap<String, f64> = HashMap::new();
    for (name, var) in &model.variables {
        if var.var_type == VariableType::Parameter
            && var.shape.as_ref().map(|s| s.is_empty()).unwrap_or(true)
            && let Some(d) = var.default
        {
            out.insert(name.clone(), d);
        }
    }
    out
}

/// Rewrite the equation (or observed `expression`) that DEFINES `name` into a
/// whole-array `const` literal carrying the materialized dense `buf` — the
/// "materialize to data" step. The relational op (`argmin` / `group_aggregate`)
/// that produced `name` is thereby replaced by data the existing oracle
/// evaluates, so it never reaches the run path as an
/// [`CompileError::UnevaluableOperatorError`]. The LHS collapses to the bare
/// variable (a whole-array assignment); the eliminated-state machinery then
/// materializes it as an ordinary constant observed.
fn rewrite_equation_to_const(model: &mut Model, name: &str, buf: &[f64]) {
    let value = JsonValue::Array(
        buf.iter()
            .map(|&v| {
                serde_json::Number::from_f64(v)
                    .map(JsonValue::Number)
                    .unwrap_or(JsonValue::Null)
            })
            .collect(),
    );
    let const_node = Expr::operator(ExpressionNode {
        op: "const".to_string(),
        value: Some(value),
        ..Default::default()
    });
    let mut replaced = false;
    for eq in &mut model.equations {
        if equation_defined_var(&eq.lhs).as_deref() == Some(name) {
            eq.lhs = Expr::Variable(name.to_string());
            eq.rhs = const_node.clone();
            replaced = true;
        }
    }
    // No equation defines `name` yet: esm 1.0.0 states an unknown's behaviour
    // in `equations`, so the folded const becomes a new bare-LHS equation
    // rather than a `variables[name].expression` field.
    if !replaced && model.variables.contains_key(name) {
        model.equations.push(crate::types::Equation {
            lhs: Expr::Variable(name.to_string()),
            rhs: const_node,
            comment: None,
        });
    }
}

/// Run the build-time value-invention engine over a TYPED [`Model`] plus the
/// document-scoped `index_sets` registry, with a caller-supplied factor-array
/// channel — the front door a Rust runner needs, and the one the in-tree build
/// path (`materialize_vi_outputs_to_data`) uses internally.
///
/// [`materialize_value_invention`] itself takes a raw `serde_json::Value` and a
/// finished array map, which leaves a caller holding a typed model with two
/// chores it has no library support for: assembling the JSON view the engine
/// expects (model + registry merged as a sibling), and gathering the factor
/// arrays. This does both. Concretely it is what turns an ISRM document plus
/// loaded `X`/`Y`/`W`/`S`/`E`/`N` into
/// [`ValueInventionResult::extents`](crate::ValueInventionResult::extents) — the
/// map that then sizes every `emis_src_cells` axis through
/// [`crate::aggregate::resolve_aggregate_ranges_with_extents`] and
/// [`crate::simulate_array::eval_expression_with_extents`].
///
/// `caller_arrays` overlays the document's `const` factors (caller wins; see
/// `vi_factor_arrays`). Scalar `params` come from the model's own 0-D
/// parameter defaults.
///
/// A model with no `skolem`/`distinct`/`rank` producer yields an empty result
/// rather than an error — the engine's own no-op contract.
///
/// # Errors
///
/// [`CompileError::InterpreterBuildError`] if the model or registry cannot be
/// serialized to the engine's JSON view, or if the engine rejects the document
/// (e.g. a producer that classifies CONTINUOUS, §5.7 guard 2).
pub fn run_value_invention<S: std::hash::BuildHasher>(
    model: &Model,
    index_sets: &HashMap<String, IndexSet>,
    caller_arrays: Option<&HashMap<String, ArrayD<f64>, S>>,
) -> Result<ValueInventionResult, CompileError> {
    let const_arrays = vi_factor_arrays(model, caller_arrays);
    let params = collect_scalar_param_defaults(model);

    // The engine walks the RAW `serde_json::Value` document (it preserves the
    // aggregate `key`/`distinct`/`arg` fields), with the document-scoped
    // `index_sets` registry merged down as a sibling — mirroring the engine's own
    // `model_json` fixture helper and `crate::cadence`.
    let mut model_json = serde_json::to_value(model).map_err(|e| {
        CompileError::build_err(format!("value-invention: could not serialize model: {e}"))
    })?;
    if let JsonValue::Object(m) = &mut model_json {
        let is_json = serde_json::to_value(index_sets).map_err(|e| {
            CompileError::build_err(format!(
                "value-invention: could not serialize index_sets: {e}"
            ))
        })?;
        m.insert("index_sets".to_string(), is_json);
    }

    materialize_value_invention(&model_json, &const_arrays, &params, &HashMap::new()).map_err(|e| {
        CompileError::build_err(format!("value-invention materialize failed: {}", e.0))
    })
}

/// Wire the value-invention front door into the array run path: run the
/// byte-conformant [`materialize_value_invention`] engine over the raw-JSON model
/// and rewrite each materialized relational OUTPUT to constant data
/// ([`rewrite_equation_to_const`]), so `argmin` / `argmax` / `group_aggregate`
/// simulate end-to-end. Derived index sets named by a materialized producer are
/// densified to intervals via [`rewrite_derived_index_sets`] (the same handoff
/// [`apply_value_invention`] performs). A NO-OP — and byte-identical — for any
/// model without an arg-witness op (gated by [`model_contains_arg_witness`]), so
/// the conservative-regrid skolem/distinct path handled by
/// [`strip_value_invention`] is untouched.
///
/// `caller_arrays` is the caller-supplied factor-array channel (see
/// [`vi_factor_arrays`]): loader-fed envelope/connectivity factors that are not
/// `const` literals in the document. `None` reproduces the previous behaviour
/// exactly.
fn materialize_vi_outputs_to_data(
    model: &mut Model,
    index_sets: &mut HashMap<String, IndexSet>,
    caller_arrays: Option<&HashMap<String, ArrayD<f64>>>,
) -> Result<(), CompileError> {
    if !model_contains_arg_witness(model) {
        return Ok(());
    }
    let result = run_value_invention(model, index_sets, caller_arrays)?;

    // Densify any derived index set named by a materialized producer (§8.1 handoff).
    rewrite_derived_index_sets(index_sets, &result.extents);

    // Materialize-to-data: the arg-witness assignment (integer nearest-witness
    // index) and the grouped/derived SCVT chain (num / den / centroid) become
    // constant observeds.
    for (name, buf) in &result.assignments {
        let as_f64: Vec<f64> = buf.iter().map(|&i| i as f64).collect();
        rewrite_equation_to_const(model, name, &as_f64);
    }
    for (name, buf) in &result.groups {
        rewrite_equation_to_const(model, name, buf);
    }
    Ok(())
}

/// Resolve a declared `shape` (index-set names) to concrete dense sizes against
/// the document registry: an `interval` set contributes its `size`, a
/// `categorical` set its member count. Returns `None` if any entry is a set the
/// registry cannot densely size (derived / ragged / unknown).
pub(super) fn resolve_declared_shape(
    decl: &[String],
    index_sets: &HashMap<String, IndexSet>,
) -> Option<Vec<usize>> {
    let mut out = Vec::with_capacity(decl.len());
    for s in decl {
        let is = index_sets.get(s)?;
        let sz = match is.kind.as_str() {
            "interval" => is.size? as usize,
            "categorical" => is.members.as_ref()?.len(),
            _ => return None,
        };
        out.push(sz);
    }
    Some(out)
}

/// True iff `expr` is an array-PRODUCING node: a `makearray`, or an
/// `aggregate`/`arrayop` with a non-empty `output_idx` (a scalar reduction has
/// an empty `output_idx` and produces a scalar). Mirrors the Julia
/// `_is_array_producer` (shape_promotion.jl).
pub(super) fn is_array_producer(node: &ExpressionNode) -> bool {
    if node.op == "makearray" {
        return true;
    }
    is_aggregate_op(&node.op)
        && node
            .output_idx
            .as_ref()
            .map(|v| !v.is_empty())
            .unwrap_or(false)
}

/// True iff the RHS of a whole-array `D(state)` equation contains an
/// array-producing node in elementwise position — the signature of a
/// discretization rule's lowered stencil (`alpha * makearray(…)`). Follows the
/// same descent rules as the Julia `_index_array_leaves`: `index` gathers and
/// aggregate-family nodes are already scalar/self-indexed and are not entered.
pub(super) fn rhs_has_array_producer(expr: &Expr) -> bool {
    match expr {
        Expr::Operator(node) => {
            if is_array_producer(node) {
                return true;
            }
            if node.op == "index" || is_aggregate_op(&node.op) {
                return false;
            }
            node.args.iter().any(rhs_has_array_producer)
        }
        _ => false,
    }
}

/// Capture-aware rename of a free loop symbol: every free `Variable(from)`
/// becomes `Variable(to)`; a node that BINDS `from` itself (its `output_idx`
/// or `ranges` declare it) shadows the outer symbol and is left untouched.
///
/// Renames the plain-string names a `join` clause carries as well — see
/// [`rename_join_names`]. That is not an extra: `map_children` is an
/// `Expr`-CHILD walker, and a `join.on` key column or an `overlap` envelope
/// factor is a variable reference that happens to be encoded as a string on the
/// node (CONFORMANCE_SPEC §5.5.6), so a walker that skipped them would rename
/// half of what one node says about the same variable.
pub(super) fn rename_free_symbol(expr: &Expr, from: &str, to: &str) -> Expr {
    match expr {
        Expr::Variable(v) if v == from => Expr::Variable(to.to_string()),
        Expr::Operator(node) => {
            let binds = node
                .output_idx
                .as_ref()
                .map(|ix| ix.iter().any(|s| s == from))
                .unwrap_or(false)
                || node
                    .ranges
                    .as_ref()
                    .map(|r| r.contains_key(from))
                    .unwrap_or(false);
            if binds {
                return expr.clone();
            }
            let mut out = node.map_children(&mut |a| rename_free_symbol(a, from, to));
            // `map_children` preserves `join` verbatim, so this is where the
            // node's string-encoded references catch up with its child ones.
            // The binder test above has already returned for a node that binds
            // `from`, which is the shadowing rule an `on` key column needs: a
            // column naming one of THIS node's own loop symbols resolves against
            // its `ranges` (`join.rs::resolve_side`), never against the variable
            // registry, so renaming it would make it resolve to nothing.
            if let Some(join) = &out.join {
                out.join = Some(rename_join_names(join, from, to));
            }
            Expr::operator(out)
        }
        _ => expr.clone(),
    }
}

/// Rename `from` → `to` in every plain-string VARIABLE REFERENCE a node's
/// `join` clauses carry (CONFORMANCE_SPEC §5.5.6): each `on` key column, each
/// `overlap` envelope factor, and the data-column names of an already-resolved
/// `on_gate`. The array-runtime twin of `flatten.rs::rename_join_names`, which
/// does the same job for a `variable_map` that removes a parameter.
///
/// A clause's LOOP SYMBOLS are left alone — `OverlapClause::sym_src` /
/// `sym_tgt` and the `on_gate`'s two gated symbols are binders of the node, not
/// references into the variable registry. (`map_column_names` renames the gate's
/// COLUMNS only, for exactly that reason.)
fn rename_join_names(join: &[JoinClause], from: &str, to: &str) -> Vec<JoinClause> {
    let ren = |n: &String| -> String {
        if n == from {
            to.to_string()
        } else {
            n.clone()
        }
    };
    join.iter()
        .map(|c| JoinClause {
            on: c.on.iter().map(|[l, r]| [ren(l), ren(r)]).collect(),
            // Binders of the node, not references — renaming leaves them alone.
            syms: c.syms.clone(),
            overlap: c.overlap.as_ref().map(|ov| OverlapClause {
                src_env: ov.src_env.iter().map(&ren).collect(),
                tgt_env: ov.tgt_env.iter().map(&ren).collect(),
                eps: ov.eps,
                sym_src: ov.sym_src.clone(),
                sym_tgt: ov.sym_tgt.clone(),
            }),
            on_gate: c.on_gate.as_ref().map(|g| g.map_column_names(ren)),
        })
        .collect()
}

/// Inline a `makearray`'s ARRAY-VALUED aggregate region values into the
/// enclosing loop symbols: a region value that is a pointwise
/// `aggregate`/`arrayop` whose output ranges equal the region bounds exactly
/// (no contraction, no filter) is replaced by its body with each output
/// symbol renamed to the enclosing loop symbol. This turns the discretized
/// `makearray([interior], [aggregate_i(stencil)])` form a §9.6.3 rewrite rule
/// emits into the scalar-region-value form the vectorized whole-array kernel
/// consumes directly (the build-time `index(arrayop, …)` collapse the Julia
/// reference performs). Values that do not match are left untouched.
pub(super) fn inline_region_aggregates(node: &ExpressionNode, loops: &[String]) -> ExpressionNode {
    let (Some(regions), Some(values)) = (&node.regions, &node.values) else {
        return node.clone();
    };
    if regions.len() != values.len() {
        return node.clone();
    }
    let mut out = node.clone();
    out.values = Some(
        regions
            .iter()
            .zip(values.iter())
            .map(|(region, value)| {
                let Expr::Operator(v) = value else {
                    return value.clone();
                };
                if !is_aggregate_op(&v.op) || v.filter.is_some() {
                    return value.clone();
                }
                let (Some(idx), Some(ranges), Some(body)) = (&v.output_idx, &v.ranges, &v.expr)
                else {
                    return value.clone();
                };
                if idx.len() != region.len()
                    || ranges.len() != idx.len()
                    || loops.len() != idx.len()
                {
                    return value.clone();
                }
                for (d, sym) in idx.iter().enumerate() {
                    let want = crate::types::region_bounds(&region[d]);
                    match (ranges.get(sym).and_then(|r| r.bounds()), want) {
                        (Some(b), Some(w)) if b == w => {}
                        _ => return value.clone(),
                    }
                }
                let mut inlined = body.as_ref().clone();
                for (sym, loop_name) in idx.iter().zip(loops.iter()) {
                    if sym != loop_name {
                        inlined = rename_free_symbol(&inlined, sym, loop_name);
                    }
                }
                inlined
            })
            .collect(),
    );
    out
}

/// Declared index-set axis NAMES of every array-shaped variable — the ordered
/// `shape` list (esm-spec §6.3), which names the index set each axis ranges
/// over. [`resolve_declared_shape`] throws these names away in favour of
/// extents; the whole-array lowering below needs them, because a BARE
/// array-level expression aligns its operands by index-set NAME, not by
/// position (esm-spec §4.3.4).
pub(super) fn declared_axis_names(model: &Model) -> HashMap<String, Vec<String>> {
    model
        .variables
        .iter()
        .filter_map(|(k, v)| {
            v.shape
                .as_ref()
                .filter(|s| !s.is_empty())
                .map(|s| (k.clone(), s.clone()))
        })
        .collect()
}

/// Where each array-shaped operand's axes sit in the RESULT's axis list.
///
/// A bare array-level expression is lowered by enumerating the result's cells
/// and gathering every operand at that cell. WHICH of the cell's coordinates an
/// operand is gathered by is decided by index-set NAME (esm-spec §4.3.4): axis
/// `d` of an operand declared over `["lat"]` is the result's `lat` axis
/// wherever that sits, and every result axis the operand does not declare is
/// one it BROADCASTS along. A name-keyed plan makes `D(dp) = w1` (with
/// `dp: [lon,lat,lev]`, `w1: [lat]`) compute exactly what the `aggregate`
/// spelling `sum_{i,j,k} w1[j]` computes, and makes axis ORDER immaterial — a
/// `[lat,lon]` operand transposes rather than being reinterpreted.
///
/// An entry is present only for a leaf that aligns by name. A leaf ABSENT from
/// the plan keeps the legacy POSITIONAL lowering (leading axes) — the fallback
/// for an operand, or a result, that carries no declared index-set names.
type GatherPlan = HashMap<String, Vec<usize>>;

/// Collect the array-shaped `Variable` leaves that a whole-array lowering will
/// wrap in a NAME-ALIGNED `index(…)` gather: the ones standing in genuinely
/// ELEMENTWISE position (see [`crate::op_registry::is_elementwise_node`]),
/// which is the only place element alignment is defined. That includes a
/// `broadcast` node, whose `fn` IS the scalar operator, so the `broadcast` and
/// bare spellings of one expression align identically. A leaf reached through
/// an op that consumes its operands whole — an `aggregate`, a `makearray`, an
/// `index` target, a shape op, a relational or geometry kernel — is left to
/// that op's own operand contract and keeps the legacy positional lowering.
///
/// The descent otherwise follows the lowering it serves, so the plan covers
/// exactly the leaves that get rewritten: [`index_array_leaves`] rewrites
/// every child (`into_binders = true`), while [`index_array_leaves_by_loops`]
/// stops at an `index` gather, an aggregate node, or an array producer
/// (`into_binders = false`).
fn collect_wrapped_array_leaves(
    expr: &Expr,
    array_axes: &HashMap<String, Vec<String>>,
    into_binders: bool,
    out: &mut Vec<String>,
) {
    match expr {
        Expr::Variable(v) if array_axes.contains_key(v) => {
            out.push(v.clone());
        }
        Expr::Operator(node) => {
            if !crate::op_registry::is_elementwise_node(node) {
                return;
            }
            if !into_binders
                && (is_array_producer(node) || node.op == "index" || is_aggregate_op(&node.op))
            {
                return;
            }
            node.for_each_child(&mut |c| {
                collect_wrapped_array_leaves(c, array_axes, into_binders, out)
            });
        }
        _ => {}
    }
}

/// Build the [`GatherPlan`] for lowering `rhs` onto a result declared over
/// `target_axes`, and REJECT an operand that cannot be aligned.
///
/// An operand whose declared index sets are a SUBSET of the result's aligns by
/// name and broadcasts along the axes it does not carry. An operand carrying an
/// index set the result does NOT have has no axis to align to and no defensible
/// value to take, so it is a hard build error rather than a positional
/// reinterpretation (esm-spec §4.3.4; issue #100). The shapes are fully known
/// statically, so `validate()` reports the same defect as an
/// `array_shape_mismatch` structural error before a build is ever attempted.
///
/// `target_axes` is `None` — and the plan consequently empty, keeping the
/// legacy positional lowering everywhere — when the result carries no usable
/// declared names.
fn build_gather_plan(
    rhs: &Expr,
    array_axes: &HashMap<String, Vec<String>>,
    target: &str,
    target_axes: Option<&[String]>,
    into_binders: bool,
) -> Result<GatherPlan, CompileError> {
    let Some(target_axes) = target_axes else {
        return Ok(GatherPlan::new());
    };
    // A repeated axis name offers no unambiguous position to align to; keep the
    // positional lowering rather than guess which occurrence was meant.
    if (1..target_axes.len()).any(|d| target_axes[..d].contains(&target_axes[d])) {
        return Ok(GatherPlan::new());
    }
    let mut leaves: Vec<String> = Vec::new();
    collect_wrapped_array_leaves(rhs, array_axes, into_binders, &mut leaves);
    let mut plan = GatherPlan::new();
    for leaf in leaves {
        let Some(leaf_axes) = array_axes.get(&leaf) else {
            continue;
        };
        let mut positions = Vec::with_capacity(leaf_axes.len());
        for axis in leaf_axes {
            match target_axes.iter().position(|t| t == axis) {
                Some(p) => positions.push(p),
                None => {
                    return Err(CompileError::UnalignableArrayShape {
                        operand: leaf.clone(),
                        axis: axis.clone(),
                        result: target.to_string(),
                        result_axes: target_axes.to_vec(),
                    });
                }
            }
        }
        plan.insert(leaf, positions);
    }
    Ok(plan)
}

/// True iff every planned operand already sits on exactly the result's axes in
/// the result's order, so the name-aligned lowering and the legacy positional
/// one agree cell for cell and no rewrite is needed.
fn plan_is_identity(plan: &GatherPlan, target_rank: usize) -> bool {
    plan.values()
        .all(|pos| pos.len() == target_rank && pos.iter().enumerate().all(|(d, &p)| d == p))
}

/// Rewrite a whole-array `D(state)` RHS into its per-cell body over the given
/// LOOP SYMBOLS (the loop-name dual of [`index_array_leaves`], mirroring the
/// Julia `_index_array_leaves` in shape_promotion.jl): each bare array-shaped
/// `Variable` leaf and each array-PRODUCING node (a `makearray` — whose
/// aggregate region values are first inlined via [`inline_region_aggregates`]
/// — or an `aggregate`/`arrayop` with output axes) is wrapped in
/// `index(node, loops…)`; `index` gathers and scalar reductions stay
/// untouched; other operators recurse elementwise.
///
/// A declared leaf listed in `plan` is gathered by the loop symbols of ITS OWN
/// axes (esm-spec §4.3.4), so a rank-1 `[lat]` operand under a rank-3
/// `[lon,lat,lev]` result reads `index(w1, <lat loop>)` and replicates along
/// the other two. Handing it all three loops — what this did before — indexed
/// axes it does not have, which `index_into` reads as out of bounds and
/// resolves to the ghost value 0.0 everywhere. An ANONYMOUS operand (no
/// declared names) and every array PRODUCER keep the positional lowering.
pub(super) fn index_array_leaves_by_loops(
    expr: &Expr,
    array_axes: &HashMap<String, Vec<String>>,
    plan: Option<&GatherPlan>,
    loops: &[String],
) -> Expr {
    let wrap = |target: Expr, ix: Vec<&String>| {
        let mut args = vec![target];
        for l in ix {
            args.push(Expr::Variable(l.clone()));
        }
        Expr::operator(ExpressionNode {
            op: "index".to_string(),
            args,
            ..Default::default()
        })
    };
    match expr {
        Expr::Variable(v) if array_axes.contains_key(v) => {
            let ix: Vec<&String> = match plan.and_then(|p| p.get(v)) {
                // `positions` is built against this same result, so every entry
                // indexes `loops`.
                Some(positions) => positions.iter().map(|&p| &loops[p]).collect(),
                None => {
                    let rank = array_axes[v].len().min(loops.len());
                    loops[..rank].iter().collect()
                }
            };
            wrap(expr.clone(), ix)
        }
        Expr::Operator(node) => {
            if is_array_producer(node) {
                let target = if node.op == "makearray" {
                    Expr::operator(inline_region_aggregates(node, loops))
                } else {
                    expr.clone()
                };
                return wrap(target, loops.iter().collect());
            }
            if node.op == "index" || is_aggregate_op(&node.op) {
                return expr.clone();
            }
            // Element alignment is defined only under elementwise nodes (a
            // `broadcast` included — its `fn` IS the scalar op); below anything
            // else the operand contract is that op's own.
            let child_plan = plan.filter(|_| crate::op_registry::is_elementwise_node(node));
            let mut out = ExpressionNode::clone(node);
            out.args = node
                .args
                .iter()
                .map(|a| index_array_leaves_by_loops(a, array_axes, child_plan, loops))
                .collect();
            Expr::operator(out)
        }
        _ => expr.clone(),
    }
}

/// Rewrite each bare array-shaped `Variable` leaf of a whole-array `D(state)` RHS
/// into an `index(var, cell…)` gather at the given 1-based cell, so the
/// elementwise array equation compiles to one per-cell scalar rule. The array
/// target of an existing `index` node is left untouched (it is already a gather).
///
/// A declared leaf listed in `plan` is gathered at the cell coordinates of ITS
/// OWN axes (esm-spec §4.3.4) — a `[lat]` operand under a `[lon,lat,lev]`
/// result takes the cell's `lat` coordinate and replicates along `lon`/`lev`,
/// and a `[lat,lon]` operand transposes. Taking the LEADING coordinates — what
/// this did before — laid the operand's elements along the wrong axes and
/// zero-filled the overhang. An ANONYMOUS operand (no declared names, or a
/// result with none) keeps the leading-axes lowering.
pub(super) fn index_array_leaves(
    expr: &Expr,
    array_axes: &HashMap<String, Vec<String>>,
    plan: Option<&GatherPlan>,
    cell: &[i64],
) -> Expr {
    match expr {
        Expr::Variable(v) => {
            if let Some(axes) = array_axes.get(v) {
                let mut args = vec![Expr::Variable(v.clone())];
                match plan.and_then(|p| p.get(v)) {
                    // `positions` is built against this same result, so every
                    // entry indexes `cell`.
                    Some(positions) => {
                        args.extend(positions.iter().map(|&p| Expr::Integer(cell[p])));
                    }
                    None => {
                        let n = axes.len().min(cell.len());
                        args.extend(cell[..n].iter().map(|&c| Expr::Integer(c)));
                    }
                }
                Expr::operator(ExpressionNode {
                    op: "index".to_string(),
                    args,
                    ..Default::default()
                })
            } else {
                expr.clone()
            }
        }
        Expr::Operator(node) => {
            // Element alignment is defined only under elementwise nodes (a
            // `broadcast` included — its `fn` IS the scalar op); below anything
            // else the operand contract is that op's own.
            let child_plan = plan.filter(|_| crate::op_registry::is_elementwise_node(node));
            let mut out =
                node.map_children(&mut |a| index_array_leaves(a, array_axes, child_plan, cell));
            if node.op == "index"
                && let Some(first) = node.args.first()
            {
                // Keep the (already array-valued) target; only the index
                // argument expressions are rewritten.
                out.args[0] = first.clone();
            }
            Expr::operator(out)
        }
        other => other.clone(),
    }
}

/// Collect every state variable that receives a `D(..., t) = ...` definition
/// somewhere in the equation list.
pub(super) fn collect_derivative_targets(equations: &[crate::types::Equation]) -> HashSet<String> {
    let mut out = HashSet::new();
    for eq in equations {
        if let Some((name, _)) = extract_derivative_scalar(&eq.lhs) {
            out.insert(name);
        }
        if let Some(DerivArrayop { var: name, .. }) = extract_derivative_arrayop(&eq.lhs, &eq.rhs) {
            out.insert(name);
        }
    }
    out
}

/// If `lhs` is `D(var, t)` or `D(index(var, i1, ...), t)`, return
/// `(var_name, Some(indices))` for the indexed form (with all concrete
/// integer indices), `(var_name, None)` for the plain form. `None` result
/// means this LHS is neither.
pub(super) fn extract_derivative_scalar(lhs: &Expr) -> Option<(String, Option<Vec<i64>>)> {
    let Expr::Operator(node) = lhs else {
        return None;
    };
    if node.op != "D" {
        return None;
    }
    if node.args.len() != 1 {
        return None;
    }
    match &node.args[0] {
        Expr::Variable(name) => Some((name.clone(), None)),
        Expr::Operator(inner) if inner.op == "index" => {
            let name = match inner.args.first()? {
                Expr::Variable(v) => v.clone(),
                _ => return None,
            };
            let indices: Vec<i64> = inner
                .args
                .iter()
                .skip(1)
                .map(|a| match a {
                    Expr::Number(n) => Some(*n as i64),
                    Expr::Integer(n) => Some(*n),
                    _ => None,
                })
                .collect::<Option<Vec<_>>>()?;
            Some((name, Some(indices)))
        }
        _ => None,
    }
}

/// If `lhs` is `arrayop(expr=D(index(var, idx...)), ...)`, extract
/// `(var_name, output_idx_names, output_ranges, lhs_idx_exprs, rhs_body,
///  contract_names, contract_ranges, reduce)`.
/// `contract_names`/`contract_ranges` are indices present in the RHS ranges
/// but absent from `output_idx` (generalized-einsum contracted indices).
/// `reduce` is the semiring ⊕ resolved from the RHS node's `semiring`/`reduce`
/// (defaulting to `Sum` per the ESM spec).
/// The parsed pieces of an `aggregate(expr=D(index(var, …))) = aggregate(…)`
/// derivative equation, as extracted by [`extract_derivative_arrayop`]. The
/// fields mirror [`RhsRule::ArrayLoop`]'s.
pub(super) struct DerivArrayop {
    /// Target state variable name.
    var: String,
    /// Output loop index names (LHS aggregate `output_idx`).
    idx_names: Vec<String>,
    /// Concrete `(lo, hi)` bounds per output index, in `idx_names` order.
    ranges: Vec<(i64, i64)>,
    /// LHS `index(var, …)` argument expressions (may offset the loop symbols).
    lhs_idx_exprs: Vec<Expr>,
    /// Scalar RHS body evaluated per output tuple.
    body: Expr,
    /// Contracted (reduction) index names, sorted.
    contract_names: Vec<String>,
    /// Bounds of the contracted indices, parallel to `contract_names`.
    contract_dims: Vec<ContractDim>,
    /// Semiring ⊕ reducer for the contraction.
    reduce: ReduceKind,
    /// Optional §5.3 filter predicate gating the contraction.
    filter: Option<Box<Expr>>,
}

pub(super) fn extract_derivative_arrayop(lhs: &Expr, rhs: &Expr) -> Option<DerivArrayop> {
    let Expr::Operator(node) = lhs else {
        return None;
    };
    if !is_aggregate_op(&node.op) {
        return None;
    }
    let body = node.expr.as_ref()?.as_ref();
    let idx_names = node.output_idx.clone()?;
    let ranges_map = node.ranges.clone()?;
    // Body must be D(index(var, ...)).
    let Expr::Operator(d_node) = body else {
        return None;
    };
    if d_node.op != "D" {
        return None;
    }
    let Expr::Operator(inner) = d_node.args.first()? else {
        return None;
    };
    if inner.op != "index" {
        return None;
    }
    let var_name = match inner.args.first()? {
        Expr::Variable(v) => v.clone(),
        _ => return None,
    };
    let lhs_idx_exprs: Vec<Expr> = inner.args.iter().skip(1).cloned().collect();
    // Map idx_names → ranges in order.
    let ranges: Vec<(i64, i64)> = idx_names
        .iter()
        .map(|n| {
            let r = ranges_map.get(n).and_then(|s| s.bounds()).unwrap_or([0, 0]);
            (r[0], r[1])
        })
        .collect();
    // RHS body: assume rhs is also arrayop with body, or pass through as
    // scalar-valued expr that evaluates at each tuple.
    // Also extract contracted (reduction) indices and the semiring ⊕ reducer.
    let (rhs_body, contract_names, contract_dims, reduce, filter) = match rhs {
        Expr::Operator(rnode) if is_aggregate_op(&rnode.op) => {
            let b = rnode.expr.as_ref().map(|b| b.as_ref().clone())?;
            // Declining (rather than reporting) an out-of-enum ⊕ spelling is
            // safe here only because this is a pattern matcher with no error
            // channel AND `from_model` runs `validate_oplus_spellings` over the
            // whole model first, so such a node cannot reach this point.
            let rop =
                effective_reduce_kind(rnode.semiring.as_deref(), rnode.reduce.as_deref()).ok()?;
            let mut c_names: Vec<String> = Vec::new();
            let mut c_dims: Vec<ContractDim> = Vec::new();
            if let Some(rhs_ranges) = &rnode.ranges {
                let mut sorted_keys: Vec<&String> = rhs_ranges.keys().collect();
                sorted_keys.sort();
                for n in sorted_keys {
                    if !idx_names.contains(n) {
                        // A ragged contracted index keeps its dynamic bound; all
                        // others collapse to a static interval here.
                        c_names.push(n.clone());
                        c_dims.push(ContractDim::from_range(&rhs_ranges[n]));
                    }
                }
            }
            // §5.3 filter rides on the RHS aggregate; carry it into the rule so
            // the contraction gates on it (otherwise it would be silently lost).
            (b, c_names, c_dims, rop, rnode.filter.clone())
        }
        other => (other.clone(), Vec::new(), Vec::new(), ReduceKind::Sum, None),
    };
    Some(DerivArrayop {
        var: var_name,
        idx_names,
        ranges,
        lhs_idx_exprs,
        body: rhs_body,
        contract_names,
        contract_dims,
        reduce,
        filter,
    })
}

/// The parsed pieces of an algebraic `arrayop(expr=index(var, …)) = arrayop(…)`
/// definition, as extracted by [`extract_algebraic_arrayop`]. The counterpart
/// of [`DerivArrayop`] for equations that define a variable's value rather
/// than its derivative.
pub(super) struct AlgebraicArrayop {
    /// Defined (algebraic) variable name.
    pub(super) var: String,
    /// Output loop index names (LHS aggregate `output_idx`).
    pub(super) idx_names: Vec<String>,
    /// Concrete `(lo, hi)` bounds per output index, in `idx_names` order.
    pub(super) ranges: Vec<(i64, i64)>,
    /// Scalar RHS body evaluated per output tuple.
    pub(super) body: Expr,
}

/// Extract an algebraic `arrayop(expr=index(var, idx...)) = arrayop(...)`
/// definition. Matches fixtures 02 and 04 where an algebraic variable is
/// defined through an arrayop whose body is just `index(v, i...)`.
pub(super) fn extract_algebraic_arrayop(lhs: &Expr, rhs: &Expr) -> Option<AlgebraicArrayop> {
    let Expr::Operator(node) = lhs else {
        return None;
    };
    if !is_aggregate_op(&node.op) {
        return None;
    }
    let body = node.expr.as_ref()?.as_ref();
    let idx_names = node.output_idx.clone()?;
    let ranges_map = node.ranges.clone()?;
    // Body must be index(var, idx...) with idx symbols matching idx_names in order.
    let Expr::Operator(inner) = body else {
        return None;
    };
    if inner.op != "index" {
        return None;
    }
    let var_name = match inner.args.first()? {
        Expr::Variable(v) => v.clone(),
        _ => return None,
    };
    // Indices must be exactly the output_idx names in order (v1 constraint).
    let idx_args: Vec<&Expr> = inner.args.iter().skip(1).collect();
    if idx_args.len() != idx_names.len() {
        return None;
    }
    for (a, want) in idx_args.iter().zip(idx_names.iter()) {
        match a {
            Expr::Variable(v) if v == want => {}
            _ => return None,
        }
    }
    let ranges: Vec<(i64, i64)> = idx_names
        .iter()
        .map(|n| {
            let r = ranges_map.get(n).and_then(|s| s.bounds()).unwrap_or([0, 0]);
            (r[0], r[1])
        })
        .collect();
    let rhs_body = match rhs {
        Expr::Operator(rnode) if is_aggregate_op(&rnode.op) => {
            // This elementwise (non-contracting) fast path does not apply a
            // `filter`. Bail rather than silently drop it — a filtered
            // definition must be compiled by a path that honors §5.3.
            if rnode.filter.is_some() {
                return None;
            }
            rnode.expr.as_ref().map(|b| b.as_ref().clone())?
        }
        other => other.clone(),
    };
    Some(AlgebraicArrayop {
        var: var_name,
        idx_names,
        ranges,
        body: rhs_body,
    })
}

/// Shape inference: per state variable, infer its shape from every
/// `index(var, ...)` reference, `D(index(var, ...))` reference, and
/// `arrayop` over its elements. Returns a map var_name → shape (empty Vec
/// means scalar). Origins are assumed 1-based.
///
/// Two-pass design: LHS equations pin the authoritative state extent; RHS
/// index references (which may include stencil offsets like `i-1` or `i+1`)
/// are only used for variables not already shaped by the LHS. This prevents
/// neighbor references in PDE stencils from bloating the inferred shape.
pub(super) fn infer_shapes(
    state_vars: &[&String],
    equations: &[crate::types::Equation],
) -> Result<HashMap<String, Vec<usize>>, CompileError> {
    let state_set: HashSet<&str> = state_vars.iter().map(|s| s.as_str()).collect();

    // Pass 1: LHS only — these are the authoritative (pinned) shapes.
    let mut per_var_min: HashMap<String, Vec<i64>> = HashMap::new();
    let mut per_var_max: HashMap<String, Vec<i64>> = HashMap::new();
    let mut seen_indexed: HashSet<String> = HashSet::new();
    let skip_none: HashSet<String> = HashSet::new();
    let no_loops: HashMap<String, (i64, i64)> = HashMap::new();
    {
        let mut walk = ShapeWalk {
            states: &state_set,
            per_var_min: &mut per_var_min,
            per_var_max: &mut per_var_max,
            seen_indexed: &mut seen_indexed,
            skip_shape_update: &skip_none,
        };
        for eq in equations {
            walk.walk(&eq.lhs, &no_loops);
        }
    }

    // Pass 2: RHS — skip variables already pinned by LHS to prevent stencil
    // offsets (e.g. index(u, i-1)) from expanding the state's extent.
    let lhs_pinned = seen_indexed.clone();
    {
        let mut walk = ShapeWalk {
            states: &state_set,
            per_var_min: &mut per_var_min,
            per_var_max: &mut per_var_max,
            seen_indexed: &mut seen_indexed,
            skip_shape_update: &lhs_pinned,
        };
        for eq in equations {
            walk.walk(&eq.rhs, &no_loops);
        }
    }

    let mut out: HashMap<String, Vec<usize>> = HashMap::new();
    for name in state_vars {
        let name_s = (*name).clone();
        if !seen_indexed.contains(&name_s) {
            out.insert(name_s, Vec::new());
            continue;
        }
        let mins = per_var_min.get(&name_s).cloned().unwrap_or_default();
        let maxes = per_var_max.get(&name_s).cloned().unwrap_or_default();
        if mins.len() != maxes.len() {
            return Err(CompileError::build_err(format!(
                "Inconsistent index rank for variable '{name_s}'"
            )));
        }
        let shape: Vec<usize> = mins
            .iter()
            .zip(maxes.iter())
            .map(|(lo, hi)| (hi - lo + 1).max(1) as usize)
            .collect();
        out.insert(name_s, shape);
    }
    Ok(out)
}

/// Accumulator state for [`infer_shapes`]'s expression walk, so the recursion
/// threads one context reference instead of five parallel parameters.
/// `skip_shape_update` lists variables whose shapes are already pinned (by a
/// prior LHS pass); their bounds are not updated, though they are still
/// marked as seen.
pub(super) struct ShapeWalk<'a> {
    states: &'a HashSet<&'a str>,
    per_var_min: &'a mut HashMap<String, Vec<i64>>,
    per_var_max: &'a mut HashMap<String, Vec<i64>>,
    seen_indexed: &'a mut HashSet<String>,
    skip_shape_update: &'a HashSet<String>,
}

impl ShapeWalk<'_> {
    /// Walk an expression tree collecting per-variable index bounds for shape
    /// inference. `loop_ranges` carries the concrete bounds of the enclosing
    /// aggregate loop symbols.
    fn walk(&mut self, expr: &Expr, loop_ranges: &HashMap<String, (i64, i64)>) {
        let Expr::Operator(node) = expr else {
            return;
        };
        if node.op == "index"
            && let Some(Expr::Variable(var)) = node.args.first()
            && self.states.contains(var.as_str())
        {
            self.seen_indexed.insert(var.clone());
            if !self.skip_shape_update.contains(var) {
                let mut dim_min: Vec<i64> = Vec::new();
                let mut dim_max: Vec<i64> = Vec::new();
                for idx_expr in node.args.iter().skip(1) {
                    let (lo, hi) = evaluate_index_range(idx_expr, loop_ranges);
                    dim_min.push(lo);
                    dim_max.push(hi);
                }
                let cur_min = self.per_var_min.entry(var.clone()).or_default();
                let cur_max = self.per_var_max.entry(var.clone()).or_default();
                if cur_min.len() < dim_min.len() {
                    cur_min.resize(dim_min.len(), i64::MAX);
                }
                if cur_max.len() < dim_max.len() {
                    cur_max.resize(dim_max.len(), i64::MIN);
                }
                for (d, v) in dim_min.iter().enumerate() {
                    cur_min[d] = cur_min[d].min(*v);
                }
                for (d, v) in dim_max.iter().enumerate() {
                    cur_max[d] = cur_max[d].max(*v);
                }
            }
        }
        if is_aggregate_op(&node.op) {
            // Build loop range map from the arrayop's ranges. Ranges have
            // already been resolved to concrete intervals (RFC §5.2) by
            // `resolve_aggregate_ranges` at the top of `from_model`.
            let mut inner = loop_ranges.clone();
            if let Some(ranges) = &node.ranges {
                for (k, v) in ranges {
                    if let Some(b) = v.bounds() {
                        inner.insert(k.clone(), (b[0], b[1]));
                    }
                }
            }
            node.for_each_child(&mut |child| self.walk(child, &inner));
            return;
        }
        node.for_each_child(&mut |child| self.walk(child, loop_ranges));
    }
}

#[cfg(test)]
mod subsystem_ragged_and_inspection_tests {
    //! Subsystem mounting (esm-spec §4.6), ragged keyed-factor scope
    //! resolution (RFC §5.4; the Julia tree_walk `_factor_scope` mirror), and
    //! the [`BuildInspection`] observability surface — the Rust twins of the
    //! Julia `build_inspection_test.jl` cases (exact-rational overlap weights
    //! through the inspection surface; a 2-cell ragged CSR miniature end to
    //! end; build byte-identical with/without a sink).
    use super::*;
    use crate::simulate::{Alg, SolveOptions};
    use serde_json::json;

    /// Typed load for inline test documents. The esm-schema pins `subsystems`
    /// entries to `{ "ref": … }` on disk (the official loader inlines the
    /// referenced file AFTER validation), so an inline-subsystem test document
    /// deserializes through serde directly — exactly the post-resolution shape
    /// the loader hands the simulator.
    fn typed(doc: serde_json::Value) -> EsmFile {
        serde_json::from_value(doc).expect("test document deserializes")
    }

    /// A EsmProblem with build observability switched on at CONSTRUCTION — the
    /// seam that replaced threading a `&mut BuildInspection` through the run.
    fn inspecting_problem(file: &EsmFile) -> crate::problem::EsmProblem {
        crate::problem::esm_problem(
            file,
            (0.0, 1.0),
            crate::problem::ProblemOptions {
                inspect: true,
                compile: crate::problem::Compile::Always,
                ..Default::default()
            },
        )
        .expect("builds")
    }

    /// One `Model`, from the post-resolution JSON shape the loader hands the
    /// simulator (a `subsystems` entry already inlined).
    fn model(doc: serde_json::Value) -> Model {
        serde_json::from_value(doc).expect("test model deserializes")
    }

    /// The aggregate RHS of the mounted equation defining `lhs`.
    fn agg_defining<'a>(m: &'a Model, lhs: &str) -> &'a ExpressionNode {
        let eq = m
            .equations
            .iter()
            .find(|e| matches!(&e.lhs, Expr::Variable(v) if v == lhs))
            .unwrap_or_else(|| panic!("no equation defines {lhs}"));
        match &eq.rhs {
            Expr::Operator(n) => n,
            other => panic!("{lhs} is not defined by an operator node: {other:?}"),
        }
    }

    /// A leaf with a `join` on two DATA COLUMNS, mounted under `Leaf`.
    /// `join_on` is the clause's `on` list, so a test can shadow a name.
    fn host_mounting_a_join_leaf(join_on: serde_json::Value) -> Model {
        model(json!({
            "variables": { "doubled": { "type": "unknown" } },
            "equations": [
                { "lhs": "doubled", "rhs": { "op": "*", "args": [2.0, "Leaf.matched"] } }
            ],
            "subsystems": { "Leaf": {
                "variables": {
                    "left_key": { "type": "unknown", "shape": ["leaf_left"] },
                    "right_key": { "type": "unknown", "shape": ["leaf_right"] },
                    "matched": { "type": "unknown" }
                },
                "equations": [
                    { "lhs": "left_key", "rhs": { "op": "const", "args": [], "value": [7, 9, 4] } },
                    { "lhs": "right_key", "rhs": { "op": "const", "args": [], "value": [7, 9] } },
                    { "lhs": "matched",
                      "rhs": { "op": "aggregate", "args": [], "semiring": "sum_product",
                               "output_idx": [],
                               "ranges": { "l": { "from": "leaf_left" },
                                           "r": { "from": "leaf_right" } },
                               "join": [ { "on": join_on } ],
                               "expr": 1.0 } }
                ]
            }}
        }))
    }

    /// A `join.on` key column is a variable reference encoded as a STRING on
    /// the aggregate node (CONFORMANCE_SPEC §5.5.6), not an `Expr` child, so
    /// the mount's `map_children` walker never saw it: the leaf's variables
    /// became `Leaf.left_key` / `Leaf.right_key` while the join went on naming
    /// the bare originals, and the build died with "join key column 'left_key'
    /// does not resolve to a loop index of this aggregate". The names a node
    /// spells two ways must agree after the mount.
    #[test]
    fn mounting_carries_a_leafs_join_on_key_columns() {
        let mut m = host_mounting_a_join_leaf(json!([["left_key", "right_key"]]));
        let mut sets: HashMap<String, IndexSet> = HashMap::new();
        mount_subsystems(&mut m, &mut sets).expect("mounts");

        let node = agg_defining(&m, "Leaf.matched");
        let on = &node.join.as_ref().expect("join survives the mount")[0].on;
        assert_eq!(
            on,
            &vec![["Leaf.left_key".to_string(), "Leaf.right_key".to_string()]],
            "both key columns follow the variables they name"
        );
        assert!(
            m.variables.contains_key("Leaf.left_key"),
            "the variables the join now names are the mounted ones"
        );
    }

    /// The binder gate, per NAME. A leaf that declares a variable named like
    /// one of its own loop symbols is legal (esm-spec §4.3.1), and an `on`
    /// column naming that symbol resolves against the node's `ranges`
    /// (`join.rs::resolve_side`) — so prefixing it would make it resolve to
    /// nothing. The shadowed name stays bare while its SIBLING in the same
    /// clause is still rewritten, which is what makes this a per-name rule and
    /// not a per-node one.
    #[test]
    fn mounting_leaves_a_shadowed_loop_symbol_alone() {
        let mut m = host_mounting_a_join_leaf(json!([["l", "right_key"]]));
        m.subsystems.as_mut().expect("subsystems")["Leaf"]["variables"]["l"] =
            json!({ "type": "unknown", "shape": ["leaf_left"] });
        m.subsystems.as_mut().expect("subsystems")["Leaf"]["equations"]
            .as_array_mut()
            .expect("equations")
            .push(json!({ "lhs": "l", "rhs": { "op": "const", "args": [], "value": [1, 2, 3] } }));
        let mut sets: HashMap<String, IndexSet> = HashMap::new();
        mount_subsystems(&mut m, &mut sets).expect("mounts");

        let node = agg_defining(&m, "Leaf.matched");
        let on = &node.join.as_ref().expect("join survives the mount")[0].on;
        assert_eq!(
            on,
            &vec![["l".to_string(), "Leaf.right_key".to_string()]],
            "the shadowed loop symbol stays bare; its sibling still follows the registry"
        );
    }

    /// The same rule for the SPATIAL gate: an `overlap` clause's
    /// `src_env`/`tgt_env` name const-array envelope factors, which the
    /// broad phase resolves against the same registry the mount rewrote
    /// (`broad_phase::envelope_vectors`). Its `sym_src`/`sym_tgt` are range
    /// symbols the node binds and are left alone — they are not references.
    #[test]
    fn mounting_carries_overlap_envelope_factors() {
        let mut m = model(json!({
            "variables": { "out": { "type": "unknown" } },
            "equations": [ { "lhs": "out", "rhs": "Geo.hits" } ],
            "subsystems": { "Geo": {
                "variables": {
                    "X": { "type": "unknown", "shape": ["pts"] },
                    "W": { "type": "unknown", "shape": ["cells"] },
                    "hits": { "type": "unknown" }
                },
                "equations": [
                    { "lhs": "X", "rhs": { "op": "const", "args": [], "value": [1.0, 3.0] } },
                    { "lhs": "W", "rhs": { "op": "const", "args": [], "value": [0.0, 2.0] } },
                    { "lhs": "hits",
                      "rhs": { "op": "aggregate", "args": [], "semiring": "sum_product",
                               "output_idx": [],
                               "ranges": { "p": { "from": "pts" }, "c": { "from": "cells" } },
                               "join": [ { "overlap": { "src_env": ["X"], "tgt_env": ["W"] } } ],
                               "expr": 1.0 } }
                ]
            }}
        }));
        let mut sets: HashMap<String, IndexSet> = HashMap::new();
        mount_subsystems(&mut m, &mut sets).expect("mounts");

        let node = agg_defining(&m, "Geo.hits");
        let ov = node.join.as_ref().expect("join survives")[0]
            .overlap
            .as_ref()
            .expect("overlap survives");
        assert_eq!(ov.src_env, vec!["Geo.X".to_string()]);
        assert_eq!(ov.tgt_env, vec!["Geo.W".to_string()]);
    }

    fn erk_opts() -> SolveOptions {
        SolveOptions {
            alg: Alg::Erk,
            reltol: 1e-10,
            abstol: 1e-12,
            saveat: Some(vec![1.0]),
            ..Default::default()
        }
    }

    /// A 2-cell ragged CSR miniature: a `mesh` subsystem ships the const
    /// factors (per-cell edge counts, the padded edge-membership table, and
    /// per-edge weights), the parent re-exposes the offsets/values factors as
    /// bare-name aliases (the MPAS keyed-factor wiring contract), and an
    /// observed contracts over the ragged `edges_of_cell` set. Expected
    /// per-cell sums are exact small integers, NONZERO — so an empty ragged
    /// contraction (a silently unresolved offsets factor) cannot pass.
    fn ragged_miniature_doc() -> serde_json::Value {
        json!({
            "esm": "1.0.0",
            "metadata": {"name": "ragged_subsystem_miniature"},
            "index_sets": {
                "cells": {"kind": "interval", "size": 2},
                "edges": {"kind": "interval", "size": 3},
                "maxEdges": {"kind": "interval", "size": 3},
                "edges_of_cell": {"kind": "ragged", "of": ["cells"],
                                   "offsets": "nEdgesOnCell",
                                   "values": "edgesOnCell"}
            },
            "models": {"M": {
                "subsystems": {"mesh": {
                    "esm": "1.0.0",
                    "metadata": {"name": "mini_mesh"},
                    "models": {"MiniMesh": {
                        "variables": {
                            "nEdgesOnCell": {"type": "unknown", "shape": ["cells"]},
                            "edgesOnCell": {"type": "unknown", "shape": ["cells", "maxEdges"]},
                            "w": {"type": "unknown", "shape": ["edges"]}
                        },
                        "equations": [
                {"lhs": "nEdgesOnCell", "rhs": {"op": "const", "value": [2, 3], "args": []}},
                {"lhs": "edgesOnCell", "rhs": {"op": "const", "value": [[1, 2, 0], [1, 2, 3]], "args": []}},
                {"lhs": "w", "rhs": {"op": "const", "value": [10.0, 20.0, 30.0], "args": []}}]
                    }}
                }},
                "variables": {
                    "u": {"type": "unknown", "units": "1", "shape": ["cells"]},
                    "nEdgesOnCell": {"type": "unknown", "shape": ["cells"]},
                    "edgesOnCell": {"type": "unknown", "shape": ["cells", "maxEdges"]},
                    "s": {"type": "unknown", "shape": ["cells"]}
                },
                "equations": [
                {"lhs": "nEdgesOnCell", "rhs": "mesh.nEdgesOnCell"},
                {"lhs": "edgesOnCell", "rhs": "mesh.edgesOnCell"},
                {"lhs": "s", "rhs": {
                        "op": "aggregate", "args": ["edgesOnCell", "mesh.w"],
                        "output_idx": ["i"], "semiring": "sum_product",
                        "ranges": {"i": {"from": "cells"},
                                    "k": {"from": "edges_of_cell", "of": ["i"]}},
                        "expr": {"op": "index", "args": ["mesh.w",
                                 {"op": "index", "args": ["edgesOnCell", "i", "k"]}]}
                    }},
                    {"lhs": {"op": "ic", "args": ["u"]}, "rhs": 0.0},
                    {"lhs": {"op": "D", "args": ["u"], "wrt": "t"}, "rhs": "s"}
                ]
            }}
        })
    }

    /// End to end: subsystem consts mount under `mesh.*`, the bare-alias
    /// observeds materialize from them, the ragged offsets factor resolves in
    /// the model scope, and the CSR contraction yields the exact nonzero
    /// per-cell sums s = [10+20, 10+20+30] — both in the integrated state
    /// (u(1) = s from a zero ic) and, exactly, in the inspection's
    /// materialized setup arrays.
    #[test]
    fn ragged_csr_miniature_through_subsystem_and_aliases() {
        let file = typed(ragged_miniature_doc());
        let prob = inspecting_problem(&file);
        let sol = crate::problem::solve(&prob, &erk_opts()).expect("solves");
        let insp = prob.take_inspection();
        let ti = sol.time.len() - 1;
        let cells = crate::pde_inline_tests::state_cells(&sol.state_variable_names, "u", "M");
        assert_eq!(cells.len(), 2);
        let u1: Vec<f64> = cells.iter().map(|(_, row)| sol.state[*row][ti]).collect();
        assert!((u1[0] - 30.0).abs() < 1e-8, "u[1](1) = {} != 30", u1[0]);
        assert!((u1[1] - 60.0).abs() < 1e-8, "u[2](1) = {} != 60", u1[1]);
        // The state-free rule output is captured EXACTLY at build.
        let s = insp.setup_arrays.get("s").expect("s captured");
        assert_eq!(s.shape(), [2]);
        assert_eq!(s[IxDyn(&[0])], 30.0);
        assert_eq!(s[IxDyn(&[1])], 60.0);
        // Mounted const factors and their aliases are captured too.
        for name in [
            "mesh.nEdgesOnCell",
            "mesh.edgesOnCell",
            "mesh.w",
            "nEdgesOnCell",
            "edgesOnCell",
        ] {
            assert!(insp.setup_arrays.contains_key(name), "missing '{name}'");
        }
        assert_eq!(
            insp.setup_arrays["nEdgesOnCell"],
            insp.setup_arrays["mesh.nEdgesOnCell"]
        );
        assert!(insp.observed_exprs.contains_key("s"));
    }

    /// Filling the inspection never changes the run: the trajectory is
    /// bit-identical with and without a sink.
    #[test]
    fn inspection_does_not_change_the_run() {
        let file = typed(ragged_miniature_doc());
        let plain = crate::problem::esm_problem(
            &file,
            (0.0, 1.0),
            crate::problem::ProblemOptions {
                p: HashMap::new().clone(),
                u0: HashMap::new().clone(),
                compile: crate::problem::Compile::Always,
                ..Default::default()
            },
        )
        .and_then(|prob| crate::problem::solve(&prob, &erk_opts()))
        .expect("simulates");
        let prob = inspecting_problem(&file);
        let inspected = crate::problem::solve(&prob, &erk_opts()).expect("solves");
        let insp = prob.take_inspection();
        assert_eq!(plain.time, inspected.time);
        assert_eq!(plain.state, inspected.state);
        assert_eq!(plain.state_variable_names, inspected.state_variable_names);
        assert!(!insp.setup_arrays.is_empty());
    }

    fn ragged_registry(offsets: &str, values: &str) -> HashMap<String, IndexSet> {
        HashMap::from([(
            "edges_of_cell".to_string(),
            IndexSet {
                kind: "ragged".to_string(),
                size: None,
                members: None,
                from_faq: None,
                member_factor: None,
                of: Some(vec!["cells".to_string()]),
                offsets: Some(offsets.to_string()),
                values: Some(values.to_string()),
            },
        )])
    }

    fn obs_var() -> ModelVariable {
        serde_json::from_value(json!({"type": "unknown"})).expect("variable parses")
    }

    /// `_factor_scope` semantics: an exact-name variable wins (registry
    /// untouched); with no exact name, the unique dot-suffix match at the
    /// SHALLOWEST namespace depth is substituted — for BOTH the offsets and
    /// values factors.
    #[test]
    fn factor_scope_exact_name_wins_and_shallowest_suffix_resolves() {
        // Exact name in scope: keep as authored.
        let mut reg = ragged_registry("nEdgesOnCell", "edgesOnCell");
        let vars: IndexMap<String, ModelVariable> = [
            ("nEdgesOnCell", obs_var()),
            ("mesh.nEdgesOnCell", obs_var()),
            ("edgesOnCell", obs_var()),
            ("mesh.edgesOnCell", obs_var()),
        ]
        .into_iter()
        .map(|(k, v)| (k.to_string(), v))
        .collect();
        apply_ragged_factor_scope(&mut reg, &vars).expect("resolves");
        assert_eq!(
            reg["edges_of_cell"].offsets.as_deref(),
            Some("nEdgesOnCell")
        );
        assert_eq!(reg["edges_of_cell"].values.as_deref(), Some("edgesOnCell"));

        // No exact name: the depth-1 alias beats the depth-2 mounted const.
        let mut reg = ragged_registry("nEdgesOnCell", "edgesOnCell");
        let vars: IndexMap<String, ModelVariable> = [
            ("Div.nEdgesOnCell", obs_var()),
            ("Div.mesh.nEdgesOnCell", obs_var()),
            ("Div.edgesOnCell", obs_var()),
            ("Div.mesh.edgesOnCell", obs_var()),
        ]
        .into_iter()
        .map(|(k, v)| (k.to_string(), v))
        .collect();
        apply_ragged_factor_scope(&mut reg, &vars).expect("resolves");
        assert_eq!(
            reg["edges_of_cell"].offsets.as_deref(),
            Some("Div.nEdgesOnCell")
        );
        assert_eq!(
            reg["edges_of_cell"].values.as_deref(),
            Some("Div.edgesOnCell")
        );

        // No candidate at all: left bare (the existing unbound-name behavior
        // surfaces downstream).
        let mut reg = ragged_registry("nowhere", "edgesOnCell");
        let vars: IndexMap<String, ModelVariable> = [("Div.edgesOnCell", obs_var())]
            .into_iter()
            .map(|(k, v)| (k.to_string(), v))
            .collect();
        apply_ragged_factor_scope(&mut reg, &vars).expect("resolves");
        assert_eq!(reg["edges_of_cell"].offsets.as_deref(), Some("nowhere"));
    }

    /// Two dot-suffix candidates at the same (shallowest) depth are a HARD
    /// ERROR — never a silent pick or an empty contraction.
    #[test]
    fn factor_scope_ambiguity_is_a_hard_error() {
        let mut reg = ragged_registry("nEdgesOnCell", "edgesOnCell");
        let vars: IndexMap<String, ModelVariable> = [
            ("A.nEdgesOnCell", obs_var()),
            ("B.nEdgesOnCell", obs_var()),
            ("A.edgesOnCell", obs_var()),
        ]
        .into_iter()
        .map(|(k, v)| (k.to_string(), v))
        .collect();
        let err = apply_ragged_factor_scope(&mut reg, &vars).unwrap_err();
        let msg = err.to_string();
        assert!(msg.contains("ambiguous"), "unexpected error: {msg}");
        assert!(msg.contains("A.nEdgesOnCell") && msg.contains("B.nEdgesOnCell"));
    }

    /// The conservative-overlap exact rationals through the inspection
    /// surface: two unit source squares tiling one 2x1 target rectangle. The
    /// per-pair overlap areas, the filtered row-sum, and the normalized
    /// weights are the library-shaped aggregates of the ESD fixture (narrow
    /// phase `polygon_intersection_area`, sliver filter `> atol`), and every
    /// captured value is BIT-EXACT: A_ij = [1, 1], A_j = [2], W = [1/2, 1/2].
    #[test]
    fn exact_rational_overlap_weights_through_inspection() {
        let doc = json!({
            "esm": "1.0.0",
            "metadata": {"name": "inspect_overlap"},
            "index_sets": {
                "src_cells": {"kind": "interval", "size": 2},
                "tgt_cells": {"kind": "interval", "size": 1}
            },
            "models": {"R": {
                "variables": {
                    "q": {"type": "unknown", "units": "1", "shape": ["tgt_cells"],
                          "default": 0.0},
                    "atol": {"type": "parameter", "units": "1", "default": 1e-12},
                    "src_poly": {"type": "unknown"},
                    "tgt_poly": {"type": "unknown"},
                    "A_ij": {"type": "unknown"},
                    "A_j": {"type": "unknown"},
                    "W_ij": {"type": "unknown"}
                },
                "equations": [
                {"lhs": "src_poly", "rhs": {"op": "const", "args": [], "value": [
                            [[0.0, 0.0], [1.0, 0.0], [1.0, 1.0], [0.0, 1.0]],
                            [[1.0, 0.0], [2.0, 0.0], [2.0, 1.0], [1.0, 1.0]]]}},
                {"lhs": "tgt_poly", "rhs": {"op": "const", "args": [], "value": [
                            [[0.0, 0.0], [2.0, 0.0], [2.0, 1.0], [0.0, 1.0]]]}},
                {"lhs": "A_ij", "rhs": {
                        "op": "aggregate", "args": ["src_poly", "tgt_poly"],
                        "output_idx": ["i", "j"], "semiring": "sum_product",
                        "ranges": {"i": {"from": "src_cells"}, "j": {"from": "tgt_cells"}},
                        "expr": {"op": "polygon_intersection_area", "manifold": "planar",
                                 "args": [{"op": "index", "args": ["src_poly", "i"]},
                                          {"op": "index", "args": ["tgt_poly", "j"]}]}}},
                {"lhs": "A_j", "rhs": {
                        "op": "aggregate", "args": ["A_ij"],
                        "output_idx": ["j"], "semiring": "sum_product",
                        "ranges": {"i": {"from": "src_cells"}, "j": {"from": "tgt_cells"}},
                        "filter": {"op": ">", "args": [
                            {"op": "index", "args": ["A_ij", "i", "j"]}, "atol"]},
                        "expr": {"op": "index", "args": ["A_ij", "i", "j"]}}},
                {"lhs": "W_ij", "rhs": {
                        "op": "aggregate", "args": ["A_ij", "A_j"],
                        "output_idx": ["i", "j"], "semiring": "sum_product",
                        "ranges": {"i": {"from": "src_cells"}, "j": {"from": "tgt_cells"}},
                        "filter": {"op": ">", "args": [
                            {"op": "index", "args": ["A_ij", "i", "j"]}, "atol"]},
                        "expr": {"op": "/", "args": [
                            {"op": "index", "args": ["A_ij", "i", "j"]},
                            {"op": "index", "args": ["A_j", "j"]}]}}},
                    {"lhs": {"op": "D", "args": ["q"], "wrt": "t"}, "rhs": 0.0}
                ]
            }}
        });
        let file = typed(doc);
        let prob = inspecting_problem(&file);
        crate::problem::solve(&prob, &erk_opts()).expect("solves");
        let insp = prob.take_inspection();
        let a_ij = insp.setup_arrays.get("A_ij").expect("A_ij captured");
        assert_eq!(a_ij.shape(), [2, 1]);
        assert_eq!(a_ij[IxDyn(&[0, 0])], 1.0);
        assert_eq!(a_ij[IxDyn(&[1, 0])], 1.0);
        let a_j = insp.setup_arrays.get("A_j").expect("A_j captured");
        assert_eq!(a_j.shape(), [1]);
        assert_eq!(a_j[IxDyn(&[0])], 2.0);
        let w_ij = insp.setup_arrays.get("W_ij").expect("W_ij captured");
        assert_eq!(w_ij.shape(), [2, 1]);
        assert_eq!(w_ij[IxDyn(&[0, 0])], 0.5);
        assert_eq!(w_ij[IxDyn(&[1, 0])], 0.5);
    }
}
