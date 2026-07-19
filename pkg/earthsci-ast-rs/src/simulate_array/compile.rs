//! Compile path: model → [`ArrayCompiled`]. Array-op / spatial-model file
//! detection, subsystem mounting (esm-spec §4.6), ragged keyed-factor scope
//! resolution (RFC §5.4), the staged [`ArrayCompiled::from_model`] build, the
//! build-time field evaluators, and the shape-inference / LHS-parsing
//! lowering helpers.

use super::*;
use crate::aggregate::{effective_reduce_kind, is_aggregate_op, resolve_aggregate_ranges};
use crate::flatten::FlattenedSystem;
use crate::op_registry::OpError;
use crate::simulate::{CompileError, SimulateError};
use crate::types::{EsmFile, ExpressionNode, Model, ModelVariable, VariableType};
use crate::value_invention::{materialize_value_invention, rewrite_derived_index_sets};
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
/// [`CompileError::MakearrayRegionInvalid`] for a ragged or inverted `makearray`.
pub(super) fn check_no_spatial_ops(expr: &Expr) -> Result<(), CompileError> {
    crate::op_registry::check_expr(expr).map_err(|e| match e {
        OpError::Unlowered { op } => CompileError::UnloweredOperatorError { op },
        OpError::Arity { op, got, expected } => {
            CompileError::InvalidOperatorArity { op, got, expected }
        }
        OpError::MakearrayRegion { reason } => CompileError::MakearrayRegionInvalid { reason },
    })
}

// ============================================================================
// Subsystem mounting (esm-spec §4.6 dot notation).
// ============================================================================

/// Coerce one resolved `subsystems` entry into a typed [`Model`] plus the
/// document `index_sets` registry it ships (empty for a bare model fragment).
/// The loader ([`crate::ref_loading::resolve_subsystem_refs`]) inlines each
/// `{ "ref": … }` as the referenced file's full JSON, so the common shape is a
/// whole ESM document carrying exactly one model (the MPAS mesh contract:
/// `grids/mpas/mesh/level0.esm`); a bare `{ "variables": …, "equations": … }`
/// fragment is also accepted. An unresolved `{ "ref": … }` — a document built
/// programmatically without the loader — is a hard error, never a silent drop.
pub(super) fn parse_subsystem_model(
    sub_name: &str,
    value: &serde_json::Value,
) -> Result<(Model, HashMap<String, IndexSet>), CompileError> {
    let obj = value
        .as_object()
        .ok_or_else(|| CompileError::InterpreterBuildError {
            details: format!("subsystem '{sub_name}' is not a JSON object"),
        })?;
    if obj.contains_key("models") {
        let file: EsmFile = serde_json::from_value(value.clone()).map_err(|e| {
            CompileError::InterpreterBuildError {
                details: format!("subsystem '{sub_name}' does not parse as an ESM file: {e}"),
            }
        })?;
        let models = file.models.unwrap_or_default();
        if models.len() != 1 {
            return Err(CompileError::InterpreterBuildError {
                details: format!(
                    "subsystem '{sub_name}' resolves to a file with {} models; exactly one is \
                     required to mount it",
                    models.len()
                ),
            });
        }
        let model = models.into_values().next().expect("len checked above");
        Ok((model, file.index_sets.unwrap_or_default()))
    } else if obj.contains_key("variables") || obj.contains_key("equations") {
        let model: Model = serde_json::from_value(value.clone()).map_err(|e| {
            CompileError::InterpreterBuildError {
                details: format!("subsystem '{sub_name}' does not parse as a model: {e}"),
            }
        })?;
        Ok((model, HashMap::new()))
    } else if obj.contains_key("ref") {
        Err(CompileError::InterpreterBuildError {
            details: format!(
                "subsystem '{sub_name}' is an unresolved {{\"ref\": …}}; load the document \
                 through the official loader (crate::parse::load_path) so \
                 resolve_subsystem_refs inlines it first"
            ),
        })
    } else {
        Err(CompileError::InterpreterBuildError {
            details: format!(
                "subsystem '{sub_name}' has neither 'models' nor 'variables'/'equations'"
            ),
        })
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
                return Err(CompileError::InterpreterBuildError {
                    details: format!(
                        "mounting subsystem '{sub_name}' would overwrite existing variable \
                         '{mounted}'"
                    ),
                });
            }
            let mut var = var.clone();
            if let Some(expr) = &var.expression {
                var.expression = Some(rename_all(expr));
            }
            model.variables.insert(mounted, var);
        }
        for eq in &sub_model.equations {
            model.equations.push(crate::types::Equation {
                lhs: rename_all(&eq.lhs),
                rhs: rename_all(&eq.rhs),
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
    variables: &HashMap<String, ModelVariable>,
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
            return Err(CompileError::InterpreterBuildError {
                details: format!(
                    "ragged index set '{set_name}': keyed factor '{fname}' is ambiguous in the \
                     model scope — {} candidates at namespace depth {mindepth}: {}",
                    names.len(),
                    names.join(", ")
                ),
            });
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
            return Err(CompileError::InterpreterBuildError {
                details: "File has no models to simulate".to_string(),
            });
        };
        if models.len() != 1 {
            return Err(CompileError::InterpreterBuildError {
                details: "Array-op path currently only supports a single model file (no coupling)"
                    .to_string(),
            });
        }
        let (model_name, model) = models.iter().next().unwrap();
        // v0.8.0: `index_sets` is document-scoped (one registry shared by all
        // models), so source it from the file rather than the model.
        let index_sets = file.index_sets.clone().unwrap_or_default();
        let mut compiled = Self::from_model(model, &index_sets)?;
        // Record the model's namespace so overrides may be keyed `Model.param`
        // (the scalar/flatten/Julia convention) as well as the raw `param` this
        // single-model path builds (WS3 override-naming parity).
        compiled.namespace = Some(model_name.clone());
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
        // no key collides; brownian variables are included so `from_model`
        // surfaces its explicit "no SDE" rejection rather than dropping them.
        let mut variables: HashMap<String, ModelVariable> = HashMap::new();
        for (name, var) in &flat.state_variables {
            variables.insert(name.clone(), var.clone());
        }
        for (name, var) in &flat.parameters {
            variables.insert(name.clone(), var.clone());
        }
        for (name, var) in &flat.observed_variables {
            variables.insert(name.clone(), var.clone());
        }
        for (name, var) in &flat.brownian_variables {
            variables.insert(name.clone(), var.clone());
        }

        // `index_sets` is not carried through flatten today, so coupled models
        // that address `arrayop`/`aggregate` ranges via `{ "from": <set> }`
        // are not yet resolvable on this path (tracked as follow-up). Dense
        // `[lo, hi]` ranges — what discretized stencils emit — need no
        // registry and work here.
        let model = Model {
            name: None,
            reference: None,
            variables,
            equations: flat.equations.clone(),
            discrete_events: None,
            continuous_events: None,
            subsystems: None,
            description: None,
            tolerance: None,
            tests: None,
            initialization_equations: None,
            guesses: None,
            system_kind: None,
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
        // Resolve `{ "from": <index set> }` range references (RFC
        // semiring-faq-unified-ir §5.2) into concrete `[lo, hi]` intervals
        // before any shape inference or rule building. Operates on an owned
        // clone so the caller's model — and its serialized form — is untouched;
        // every downstream consumer then sees only dense interval ranges.
        let mut model_owned = model.clone();
        // Mount subsystems under dot-prefixed names (esm-spec §4.6) and resolve
        // each ragged index set's keyed factors against the resulting model
        // scope (RFC §5.4; the Julia `_factor_scope` mirror). Both are no-ops —
        // and the registry copy is byte-identical — for models without
        // subsystems / ragged sets.
        let mut index_sets_owned = index_sets.clone();
        mount_subsystems(&mut model_owned, &mut index_sets_owned)?;
        apply_ragged_factor_scope(&mut index_sets_owned, &model_owned.variables)?;
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
        materialize_vi_outputs_to_data(&mut model_owned, &mut index_sets_owned)?;
        let index_sets = &index_sets_owned;
        // Drop value-invention (relational) scaffolding — skolem-id bin maps and
        // membership sets over `kind: "derived"` index sets — plus the broad-phase
        // `join.on` gates keyed on them, BEFORE join/range resolution. The dense
        // runtime evaluates the geometric narrow phase densely; the elided gate is
        // numerically inert there (see `strip_value_invention`). A no-op unless a
        // `skolem` op or a derived-set-shaped variable is present.
        strip_value_invention(&mut model_owned, index_sets)?;
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

        // (6)+(6b) Build the dependency-ordered observed algebraic rules.
        let observed_rules = build_observed_rules(model, &observed_vars, &eliminated);

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
        })
    }
}

// ============================================================================
// `from_model` build stages. Each function is one numbered stage of the
// compile pipeline (its number matches the stage comment in
// [`ArrayCompiled::from_model`], which composes them in order); the bodies are
// extracted verbatim from the former inline implementation.
// ============================================================================

/// (0) Reject spatial differential operators anywhere in the model's
/// equations or observed-variable expressions — the canonical pipeline
/// contract requires `grad`/`div`/`laplacian` to be rewritten by ESD
/// discretization before reaching the simulator (esm-i7b).
fn reject_unlowered_spatial_ops(model: &Model) -> Result<(), CompileError> {
    for eq in &model.equations {
        check_no_spatial_ops(&eq.lhs)?;
        check_no_spatial_ops(&eq.rhs)?;
    }
    for var in model.variables.values() {
        if let Some(expr) = &var.expression {
            check_no_spatial_ops(expr)?;
        }
    }
    Ok(())
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
        if let Some(expr) = &var.expression {
            collect_dim_symbols(expr, &mut bound);
            collect_index_head_names(expr, &mut bound);
        }
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
        if let Some(expr) = &var.expression {
            let mut scope = bound.clone();
            collect_binders(expr, &mut scope);
            check_expr_free_vars(expr, &scope)?;
        }
    }
    Ok(())
}

/// Is this LHS an initial-condition marker (`{"op": "ic", …}`)?
fn is_ic_lhs(lhs: &Expr) -> bool {
    matches!(lhs, Expr::Operator(op) if op.op == "ic")
}

/// Elementary math / reduction names that are always valid as a bare leaf even
/// though they are not declared variables. Mirrors `structural.rs`
/// `is_builtin_function` so the same names are excused across the two Rust
/// gates.
fn is_builtin_fn_name(name: &str) -> bool {
    matches!(
        name,
        "exp" | "log"
            | "log10"
            | "sqrt"
            | "abs"
            | "sign"
            | "sin"
            | "cos"
            | "tan"
            | "asin"
            | "acos"
            | "atan"
            | "atan2"
            | "sinh"
            | "cosh"
            | "tanh"
            | "asinh"
            | "acosh"
            | "atanh"
            | "min"
            | "max"
            | "floor"
            | "ceil"
            | "ifelse"
            | "Pre"
    )
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
        Expr::Variable(name) => {
            if !name.contains('.') && !is_builtin_fn_name(name) {
                out.insert(name.clone());
            }
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

/// Collect the `dim` axis of every spatial differential operator in the subtree
/// (defensive: the array path rejects unlowered spatial ops earlier, but a
/// coordinate an `ic` RHS shares with a `grad` `dim` stays creditable).
fn collect_dim_symbols(expr: &Expr, out: &mut HashSet<String>) {
    if let Expr::Operator(node) = expr {
        if matches!(node.op.as_str(), "grad" | "div" | "curl" | "laplacian")
            && let Some(dim) = &node.dim
        {
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
            if name.contains('.') || is_builtin_fn_name(name) || name.starts_with("d(") {
                return Ok(());
            }
            if scope.contains(name) {
                return Ok(());
            }
            Err(CompileError::InterpreterBuildError {
                details: format!("Unknown variable '{name}' referenced in expression"),
            })
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
/// deterministic build). A brownian variable is an explicit
/// unsupported-feature error, never a silent drop.
fn classify_variables(
    model: &Model,
) -> Result<(Vec<&String>, Vec<&String>, Vec<(&String, &ModelVariable)>), CompileError> {
    let mut state_vars: Vec<&String> = Vec::new();
    let mut param_vars: Vec<&String> = Vec::new();
    let mut observed_vars: Vec<(&String, &ModelVariable)> = Vec::new();

    let mut var_keys: Vec<&String> = model.variables.keys().collect();
    var_keys.sort();
    for name in var_keys {
        let var = &model.variables[name];
        match var.var_type {
            VariableType::State => state_vars.push(name),
            VariableType::Parameter => param_vars.push(name),
            VariableType::Observed => observed_vars.push((name, var)),
            VariableType::Discrete => {
                // A discrete variable is piecewise-constant and refreshed by an
                // event / cadence / loader. The array backend has no refresh
                // machinery, so binning it as a state (integrated) or a
                // parameter (frozen) would both be WRONG — and silently so. Fail
                // loudly instead; the document still VALIDATES, it just cannot be
                // simulated by this backend yet.
                return Err(CompileError::UnsupportedFeatureError {
                    feature: "discrete".to_string(),
                    message: format!(
                        "Rust array simulation backend does not yet support discrete (piecewise-constant) variables; variable '{name}' is discrete"
                    ),
                });
            }
            VariableType::Brownian => {
                return Err(CompileError::UnsupportedFeatureError {
                    feature: "brownian".to_string(),
                    message: format!(
                        "Rust simulation backend does not support SDE (brownian) models; variable '{name}' is brownian"
                    ),
                });
            }
        }
    }
    Ok((state_vars, param_vars, observed_vars))
}

/// (2) Infer shapes for state variables from all equation usages, then (2b)
/// seed declared array shapes for states the index-usage inference left
/// scalar. A whole-array `D(state)` (bare LHS, no per-cell `index`) or an
/// `ic`-only array state has no indexed reference to infer from, so its
/// declared `shape` (index-set names resolved to sizes via the document
/// registry) is authoritative.
fn infer_state_shapes(
    model: &Model,
    state_vars: &[&String],
    index_sets: &HashMap<String, IndexSet>,
) -> Result<HashMap<String, Vec<usize>>, CompileError> {
    let mut shape_map = infer_shapes(state_vars, &model.equations)?;

    // (2b) Seed declared array shapes for states the index-usage inference
    //      left scalar. A whole-array `D(state)` (bare LHS, no per-cell
    //      `index`) or an `ic`-only array state has no indexed reference to
    //      infer from, so its declared `shape` (index-set names resolved to
    //      sizes via the document registry) is authoritative.
    for name in state_vars {
        let empty = shape_map.get(*name).map(|s| s.is_empty()).unwrap_or(true);
        if !empty {
            continue;
        }
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
    model: &Model,
    observed_vars: &[(&String, &ModelVariable)],
    eliminated: &HashSet<String>,
) -> Vec<AlgebraicRule> {
    let mut observed_rules: Vec<AlgebraicRule> = Vec::new();

    // Declared observed variables with an `expression` field. An array-shaped
    // observed — a discretization-agnostic PDE leaf's `psi_x`, `grad_mag`,
    // `U_n`, `S_n`, a `const`-op field, a keyed-factor alias — is evaluated
    // WHOLESALE here: `eval` looks each array-valued observed reference up in
    // the observed-array map and broadcasts the elementwise ops over it, so a
    // readable intermediate decomposition (WS4) already runs as authored. The
    // rules are dependency-ordered below, so `grad_mag` materializes before
    // `U_n`/`S_n` read it.
    for (name, var) in observed_vars {
        if let Some(expr) = &var.expression {
            observed_rules.push(AlgebraicRule::Scalar {
                var: (*name).clone(),
                body: Box::new(expr.clone()),
            });
        }
    }

    // Algebraic arrayop equations for eliminated state variables.
    for eq in &model.equations {
        if let Some((var, idx_names, ranges, body)) = extract_algebraic_arrayop(&eq.lhs, &eq.rhs)
            && eliminated.contains(&var)
        {
            observed_rules.push(AlgebraicRule::ArrayLoop {
                var,
                output_idx_names: idx_names,
                output_ranges: ranges,
                body: Box::new(body),
            });
            continue;
        }
        // Also handle scalar algebraic: `var = rhs` (plain Variable LHS).
        if let Expr::Variable(name) = &eq.lhs
            && eliminated.contains(name)
        {
            observed_rules.push(AlgebraicRule::Scalar {
                var: name.clone(),
                body: Box::new(eq.rhs.clone()),
            });
        }
    }
    dependency_order_observed(observed_rules)
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
/// loop. Then (7b) held-at-ic states (no `D`, no algebraic definition) carry
/// every cell at its ic with zero derivative — their slots are marked covered
/// without emitting a rule (the RHS zero-initializes `dy` each call and never
/// writes them) — and (8) every state slot must end up with a defining
/// equation.
fn build_rhs_rules(
    model: &Model,
    slots: &SlotTables,
    held_at_ic: &HashSet<String>,
) -> Result<Vec<RhsRule>, CompileError> {
    let var_shapes = &slots.var_shapes;
    let mut rhs_rules: Vec<RhsRule> = Vec::new();
    let mut covered_slots: HashSet<usize> = HashSet::new();

    // Declared rank of every array-shaped variable (state / parameter /
    // observed), used to lower a whole-array `D(state)` RHS into per-cell
    // gathers.
    let array_ranks: HashMap<String, usize> = model
        .variables
        .iter()
        .filter_map(|(k, v)| {
            v.shape
                .as_ref()
                .filter(|s| !s.is_empty())
                .map(|s| (k.clone(), s.len()))
        })
        .collect();

    for eq in &model.equations {
        if let Some(DerivArrayop {
            var,
            idx_names,
            ranges,
            lhs_idx_exprs,
            body,
            contract_names,
            contract_dims,
            reduce,
            filter,
        }) = extract_derivative_arrayop(&eq.lhs, &eq.rhs)
        {
            // Array-op derivative over (idx_names, ranges).
            if !var_shapes.contains_key(&var) {
                return Err(CompileError::InterpreterBuildError {
                    details: format!("Array-op derivative targets unknown state variable '{var}'"),
                });
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
            continue;
        }
        // Scalar D(var, t) = rhs.
        if let Some((var, idx_opt)) = extract_derivative_scalar(&eq.lhs) {
            if let Some(indices) = idx_opt {
                // Indexed: find slot.
                let shape =
                    var_shapes
                        .get(&var)
                        .ok_or_else(|| CompileError::InterpreterBuildError {
                            details: format!(
                                "Scalar derivative targets unknown state variable '{var}'"
                            ),
                        })?;
                let flat = multi_to_flat_col_major(&indices, &shape.shape, &shape.origin);
                let slot = shape.flat_offset + flat;
                covered_slots.insert(slot);
                rhs_rules.push(RhsRule::IndexedScalar {
                    slot,
                    body: Box::new(eq.rhs.clone()),
                });
                continue;
            } else {
                let shape = var_shapes
                    .get(&var)
                    .ok_or_else(|| CompileError::InterpreterBuildError {
                        details: format!(
                            "Scalar derivative targets unknown state variable '{var}'"
                        ),
                    })?
                    .clone();
                if shape.shape.is_empty() {
                    // Plain scalar D(var, t) = rhs.
                    let slot = shape.flat_offset;
                    covered_slots.insert(slot);
                    rhs_rules.push(RhsRule::Scalar {
                        slot,
                        body: Box::new(eq.rhs.clone()),
                    });
                } else if rhs_has_array_producer(&eq.rhs) {
                    // Whole-array `D(var) = <rhs containing a lowered stencil>`
                    // (an array-PRODUCING `makearray`/`aggregate` in elementwise
                    // position, the form a §9.6.3 discretization rewrite emits):
                    // lift to the per-cell `arrayop` (ArrayLoop) form the
                    // derivative partition consumes — output loops over the full
                    // declared shape, each array leaf and array producer gathered
                    // per cell via `index(node, loops…)`. This is the loop-form
                    // analog of the Julia `_lift_wholearray_deriv_equations`
                    // (shape_promotion.jl) and keeps the rule eligible for the
                    // vectorized whole-array fast path (ess-bdm).
                    let ndim = shape.shape.len();
                    let loops: Vec<String> = (0..ndim).map(|d| format!("_lp{d}_{var}")).collect();
                    let output_ranges: Vec<(i64, i64)> = shape
                        .shape
                        .iter()
                        .zip(shape.origin.iter())
                        .map(|(sz, o)| (*o, *o + *sz as i64 - 1))
                        .collect();
                    let lhs_idx_exprs: Vec<Expr> =
                        loops.iter().map(|l| Expr::Variable(l.clone())).collect();
                    let body = index_array_leaves_by_loops(&eq.rhs, &array_ranks, &loops);
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
                        reduce: effective_reduce_kind(None, None),
                        filter: None,
                    });
                } else {
                    // Whole-array `D(var) = <array-valued rhs>` over a declared
                    // array shape: enumerate cells and emit one per-cell scalar
                    // rule, indexing each array-shaped RHS leaf by that cell
                    // (elementwise semantics). This is the array-runtime analog
                    // of the Julia `_lift_wholearray_deriv_equations` lift.
                    let total = shape.shape.iter().copied().product::<usize>().max(1);
                    for flat in 0..total {
                        let multi0 = flat_to_multi_col_major(flat, &shape.shape);
                        let cell: Vec<i64> = multi0
                            .iter()
                            .zip(shape.origin.iter())
                            .map(|(m, o)| *m as i64 + *o)
                            .collect();
                        let body = index_array_leaves(&eq.rhs, &array_ranks, &cell);
                        let slot = shape.flat_offset + flat;
                        covered_slots.insert(slot);
                        rhs_rules.push(RhsRule::IndexedScalar {
                            slot,
                            body: Box::new(body),
                        });
                    }
                }
                continue;
            }
        }
        // Otherwise: algebraic equation (or something we don't support).
        // If the LHS is algebraic for an eliminated variable it was
        // already consumed above; ignore here.
    }

    // (7b) Held-at-ic states (no `D`, no algebraic definition) carry every
    //      cell at its ic with zero derivative: mark their slots covered
    //      without emitting a rule. The RHS zero-initializes `dy` each call
    //      and never writes these slots, so they stay constant (a state that
    //      feeds an observed — e.g. `phi` into `heat_release` — must not
    //      drift).
    for name in held_at_ic {
        if let Some(vs) = var_shapes.get(name) {
            let total = vs.shape.iter().copied().product::<usize>().max(1);
            for k in 0..total {
                covered_slots.insert(vs.flat_offset + k);
            }
        }
    }

    // (8) Every state slot must have a defining equation.
    for (i, name) in slots.scalar_state_names.iter().enumerate() {
        if !covered_slots.contains(&i) {
            return Err(CompileError::InterpreterBuildError {
                details: format!("State slot '{name}' has no defining derivative equation."),
            });
        }
    }

    Ok(rhs_rules)
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
    let Expr::Operator(node) = expr else {
        return;
    };
    if let Some(joins) = &mut node.join {
        for clause in joins.iter_mut() {
            clause
                .on
                .retain(|pair| !pair.iter().any(|c| vi_cols.contains(c)));
        }
        joins.retain(|clause| !clause.on.is_empty());
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
    for var in model.variables.values() {
        if let Some(expr) = &var.expression {
            collect_geometry_producer_ids(expr, &mut geom_ids);
        }
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
        if let Some(expr) = &mut var.expression {
            strip_vi_joins(expr, &vi_cols);
        }
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
            node.op == "argmin" || node.op == "argmax" || node.any_child(&mut expr_contains_arg_witness)
        }
    }
}

fn model_contains_arg_witness(model: &Model) -> bool {
    model
        .equations
        .iter()
        .any(|eq| expr_contains_arg_witness(&eq.lhs) || expr_contains_arg_witness(&eq.rhs))
        || model
            .variables
            .values()
            .any(|v| v.expression.as_ref().is_some_and(expr_contains_arg_witness))
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
    for (name, var) in &model.variables {
        let Some(expr) = var.expression.as_ref() else {
            continue;
        };
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
    let const_node = Expr::Operator(ExpressionNode {
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
    if !replaced && let Some(var) = model.variables.get_mut(name) {
        var.expression = Some(const_node);
    }
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
fn materialize_vi_outputs_to_data(
    model: &mut Model,
    index_sets: &mut HashMap<String, IndexSet>,
) -> Result<(), CompileError> {
    if !model_contains_arg_witness(model) {
        return Ok(());
    }
    let const_arrays = collect_const_factor_arrays(model);
    let params = collect_scalar_param_defaults(model);

    // The engine walks the RAW `serde_json::Value` document (it preserves the
    // aggregate `key`/`distinct`/`arg` fields), with the document-scoped
    // `index_sets` registry merged down as a sibling — mirroring the engine's own
    // `model_json` fixture helper and `crate::cadence`.
    let mut model_json = serde_json::to_value(&*model).map_err(|e| {
        CompileError::InterpreterBuildError {
            details: format!("value-invention: could not serialize model: {e}"),
        }
    })?;
    if let JsonValue::Object(m) = &mut model_json {
        let is_json =
            serde_json::to_value(&*index_sets).map_err(|e| CompileError::InterpreterBuildError {
                details: format!("value-invention: could not serialize index_sets: {e}"),
            })?;
        m.insert("index_sets".to_string(), is_json);
    }

    let result = materialize_value_invention(&model_json, &const_arrays, &params, &HashMap::new())
        .map_err(|e| CompileError::InterpreterBuildError {
            details: format!("value-invention materialize failed: {}", e.0),
        })?;

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
            Expr::Operator(node.map_children(&mut |a| rename_free_symbol(a, from, to)))
        }
        _ => expr.clone(),
    }
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
                    match ranges.get(sym).and_then(|r| r.bounds()) {
                        Some(b) if b == region[d] => {}
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

/// Rewrite a whole-array `D(state)` RHS into its per-cell body over the given
/// LOOP SYMBOLS (the loop-name dual of [`index_array_leaves`], mirroring the
/// Julia `_index_array_leaves` in shape_promotion.jl): each bare array-shaped
/// `Variable` leaf and each array-PRODUCING node (a `makearray` — whose
/// aggregate region values are first inlined via [`inline_region_aggregates`]
/// — or an `aggregate`/`arrayop` with output axes) is wrapped in
/// `index(node, loops…)`; `index` gathers and scalar reductions stay
/// untouched; other operators recurse elementwise.
pub(super) fn index_array_leaves_by_loops(
    expr: &Expr,
    array_ranks: &HashMap<String, usize>,
    loops: &[String],
) -> Expr {
    let wrap = |target: Expr| {
        let mut args = vec![target];
        for l in loops {
            args.push(Expr::Variable(l.clone()));
        }
        Expr::Operator(ExpressionNode {
            op: "index".to_string(),
            args,
            ..Default::default()
        })
    };
    match expr {
        Expr::Variable(v) if array_ranks.contains_key(v) => wrap(expr.clone()),
        Expr::Operator(node) => {
            if is_array_producer(node) {
                let target = if node.op == "makearray" {
                    Expr::Operator(inline_region_aggregates(node, loops))
                } else {
                    expr.clone()
                };
                return wrap(target);
            }
            if node.op == "index" || is_aggregate_op(&node.op) {
                return expr.clone();
            }
            let mut out = node.clone();
            out.args = node
                .args
                .iter()
                .map(|a| index_array_leaves_by_loops(a, array_ranks, loops))
                .collect();
            Expr::Operator(out)
        }
        _ => expr.clone(),
    }
}

/// Rewrite each bare array-shaped `Variable` leaf of a whole-array `D(state)` RHS
/// into an `index(var, cell…)` gather at the given 1-based cell, so the
/// elementwise array equation compiles to one per-cell scalar rule. The array
/// target of an existing `index` node is left untouched (it is already a gather).
pub(super) fn index_array_leaves(
    expr: &Expr,
    array_ranks: &HashMap<String, usize>,
    cell: &[i64],
) -> Expr {
    match expr {
        Expr::Variable(v) => {
            if let Some(&rank) = array_ranks.get(v) {
                let n = rank.min(cell.len());
                let mut args = vec![Expr::Variable(v.clone())];
                for &c in &cell[..n] {
                    args.push(Expr::Integer(c));
                }
                Expr::Operator(ExpressionNode {
                    op: "index".to_string(),
                    args,
                    ..Default::default()
                })
            } else {
                expr.clone()
            }
        }
        Expr::Operator(node) => {
            let mut out = node.map_children(&mut |a| index_array_leaves(a, array_ranks, cell));
            if node.op == "index"
                && let Some(first) = node.args.first()
            {
                // Keep the (already array-valued) target; only the index
                // argument expressions are rewritten.
                out.args[0] = first.clone();
            }
            Expr::Operator(out)
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
            let rop = effective_reduce_kind(rnode.semiring.as_deref(), rnode.reduce.as_deref());
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

/// Extract an algebraic `arrayop(expr=index(var, idx...)) = arrayop(...)`
/// definition. Matches fixtures 02 and 04 where an algebraic variable is
/// defined through an arrayop whose body is just `index(v, i...)`.
pub(super) fn extract_algebraic_arrayop(
    lhs: &Expr,
    rhs: &Expr,
) -> Option<(String, Vec<String>, Vec<(i64, i64)>, Expr)> {
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
    Some((var_name, idx_names, ranges, rhs_body))
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
            return Err(CompileError::InterpreterBuildError {
                details: format!("Inconsistent index rank for variable '{name_s}'"),
            });
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
    use crate::simulate::{SimulateOptions, SolverChoice, simulate, simulate_with_inspection};
    use serde_json::json;

    /// Typed load for inline test documents. The esm-schema pins `subsystems`
    /// entries to `{ "ref": … }` on disk (the official loader inlines the
    /// referenced file AFTER validation), so an inline-subsystem test document
    /// deserializes through serde directly — exactly the post-resolution shape
    /// the loader hands the simulator.
    fn typed(doc: serde_json::Value) -> EsmFile {
        serde_json::from_value(doc).expect("test document deserializes")
    }

    fn erk_opts() -> SimulateOptions {
        SimulateOptions {
            solver: SolverChoice::Erk,
            reltol: 1e-10,
            abstol: 1e-12,
            output_times: Some(vec![1.0]),
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
            "esm": "0.8.0",
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
                    "esm": "0.8.0",
                    "metadata": {"name": "mini_mesh"},
                    "models": {"MiniMesh": {
                        "variables": {
                            "nEdgesOnCell": {"type": "observed", "shape": ["cells"],
                                "expression": {"op": "const", "value": [2, 3], "args": []}},
                            "edgesOnCell": {"type": "observed", "shape": ["cells", "maxEdges"],
                                "expression": {"op": "const", "value": [[1, 2, 0], [1, 2, 3]], "args": []}},
                            "w": {"type": "observed", "shape": ["edges"],
                                "expression": {"op": "const", "value": [10.0, 20.0, 30.0], "args": []}}
                        },
                        "equations": []
                    }}
                }},
                "variables": {
                    "u": {"type": "state", "units": "1", "shape": ["cells"]},
                    "nEdgesOnCell": {"type": "observed", "shape": ["cells"],
                        "expression": "mesh.nEdgesOnCell"},
                    "edgesOnCell": {"type": "observed", "shape": ["cells", "maxEdges"],
                        "expression": "mesh.edgesOnCell"},
                    "s": {"type": "observed", "shape": ["cells"], "expression": {
                        "op": "aggregate", "args": ["edgesOnCell", "mesh.w"],
                        "output_idx": ["i"], "semiring": "sum_product",
                        "ranges": {"i": {"from": "cells"},
                                    "k": {"from": "edges_of_cell", "of": ["i"]}},
                        "expr": {"op": "index", "args": ["mesh.w",
                                 {"op": "index", "args": ["edgesOnCell", "i", "k"]}]}
                    }}
                },
                "equations": [
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
        let mut insp = BuildInspection::default();
        let sol = simulate_with_inspection(
            &file,
            (0.0, 1.0),
            &HashMap::new(),
            &HashMap::new(),
            &erk_opts(),
            &mut insp,
        )
        .expect("simulates");
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
        let plain = simulate(
            &file,
            (0.0, 1.0),
            &HashMap::new(),
            &HashMap::new(),
            &erk_opts(),
        )
        .expect("simulates");
        let mut insp = BuildInspection::default();
        let inspected = simulate_with_inspection(
            &file,
            (0.0, 1.0),
            &HashMap::new(),
            &HashMap::new(),
            &erk_opts(),
            &mut insp,
        )
        .expect("simulates");
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
                of: Some(vec!["cells".to_string()]),
                offsets: Some(offsets.to_string()),
                values: Some(values.to_string()),
            },
        )])
    }

    fn obs_var() -> ModelVariable {
        serde_json::from_value(json!({"type": "observed"})).expect("variable parses")
    }

    /// `_factor_scope` semantics: an exact-name variable wins (registry
    /// untouched); with no exact name, the unique dot-suffix match at the
    /// SHALLOWEST namespace depth is substituted — for BOTH the offsets and
    /// values factors.
    #[test]
    fn factor_scope_exact_name_wins_and_shallowest_suffix_resolves() {
        // Exact name in scope: keep as authored.
        let mut reg = ragged_registry("nEdgesOnCell", "edgesOnCell");
        let vars: HashMap<String, ModelVariable> = [
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
        let vars: HashMap<String, ModelVariable> = [
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
        let vars: HashMap<String, ModelVariable> = [("Div.edgesOnCell", obs_var())]
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
        let vars: HashMap<String, ModelVariable> = [
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
            "esm": "0.8.0",
            "metadata": {"name": "inspect_overlap"},
            "index_sets": {
                "src_cells": {"kind": "interval", "size": 2},
                "tgt_cells": {"kind": "interval", "size": 1}
            },
            "models": {"R": {
                "variables": {
                    "q": {"type": "state", "units": "1", "shape": ["tgt_cells"],
                          "default": 0.0},
                    "atol": {"type": "parameter", "units": "1", "default": 1e-12},
                    "src_poly": {"type": "observed",
                        "expression": {"op": "const", "args": [], "value": [
                            [[0.0, 0.0], [1.0, 0.0], [1.0, 1.0], [0.0, 1.0]],
                            [[1.0, 0.0], [2.0, 0.0], [2.0, 1.0], [1.0, 1.0]]]}},
                    "tgt_poly": {"type": "observed",
                        "expression": {"op": "const", "args": [], "value": [
                            [[0.0, 0.0], [2.0, 0.0], [2.0, 1.0], [0.0, 1.0]]]}},
                    "A_ij": {"type": "observed", "expression": {
                        "op": "aggregate", "args": ["src_poly", "tgt_poly"],
                        "output_idx": ["i", "j"], "semiring": "sum_product",
                        "ranges": {"i": {"from": "src_cells"}, "j": {"from": "tgt_cells"}},
                        "expr": {"op": "polygon_intersection_area", "manifold": "planar",
                                 "args": [{"op": "index", "args": ["src_poly", "i"]},
                                          {"op": "index", "args": ["tgt_poly", "j"]}]}}},
                    "A_j": {"type": "observed", "expression": {
                        "op": "aggregate", "args": ["A_ij"],
                        "output_idx": ["j"], "semiring": "sum_product",
                        "ranges": {"i": {"from": "src_cells"}, "j": {"from": "tgt_cells"}},
                        "filter": {"op": ">", "args": [
                            {"op": "index", "args": ["A_ij", "i", "j"]}, "atol"]},
                        "expr": {"op": "index", "args": ["A_ij", "i", "j"]}}},
                    "W_ij": {"type": "observed", "expression": {
                        "op": "aggregate", "args": ["A_ij", "A_j"],
                        "output_idx": ["i", "j"], "semiring": "sum_product",
                        "ranges": {"i": {"from": "src_cells"}, "j": {"from": "tgt_cells"}},
                        "filter": {"op": ">", "args": [
                            {"op": "index", "args": ["A_ij", "i", "j"]}, "atol"]},
                        "expr": {"op": "/", "args": [
                            {"op": "index", "args": ["A_ij", "i", "j"]},
                            {"op": "index", "args": ["A_j", "j"]}]}}}
                },
                "equations": [
                    {"lhs": {"op": "D", "args": ["q"], "wrt": "t"}, "rhs": 0.0}
                ]
            }}
        });
        let file = typed(doc);
        let mut insp = BuildInspection::default();
        simulate_with_inspection(
            &file,
            (0.0, 1.0),
            &HashMap::new(),
            &HashMap::new(),
            &erk_opts(),
            &mut insp,
        )
        .expect("simulates");
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
