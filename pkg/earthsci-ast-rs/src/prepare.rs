//! `prepare` — the build-time public surface of the Rust binding, mirroring
//! the Julia `prepare`/`observed_field` (simulate.jl) and the Python
//! `earthsci_ast.prepare` (Phase 4 of the clean consolidation).
//!
//! Runs everything deterministic-per-document ONCE — pushdown rewrite → typed
//! load → provider materialization → build-time coordinate evaluation →
//! value-invention → member-factor feedback → gated pre-sliced fetch →
//! dependency-ordered observed-graph evaluation — and returns a [`Prepared`]
//! whose [`Prepared::observed_field`] reads the build-time fields back. This
//! is the entry point the isrm.esm runner drives; it never integrates.
//!
//! `pushdown_rewrite: true` opts into the automatic projection-pushdown
//! desugar ([`crate::pushdown_rewrite::desugar_pushdown`]) at this public
//! entry point, exactly as in Julia/Python:
//!
//! * the rewrite runs on the RAW authored document BEFORE the typed parse
//!   (the raw-JSON design note in [`crate::pushdown_rewrite`]). NOTE the
//!   name-rewriting trap the Julia binding had (its flattener rewrites
//!   coupling-fed references in equations but not in variable `expression`
//!   fields, so the pattern no longer matches post-flatten) does NOT apply
//!   here: this Rust path never flattens — it selects the single authored
//!   model and resolves the coupling `variable_map` by ALIASING the provider
//!   arrays under the model-local names, so the pattern is always detected on
//!   the authored spelling;
//! * the engine derives every provider gate from the rewrite's OWN record
//!   (`metadata.x_esd.pushdown.gated_select`) + the document coupling — the
//!   caller hand-authors NO gate and implements no selection plumbing;
//! * a `providers` entry the coupling routes onto a rewritten array is
//!   DEFERRED and fetched pre-sliced to the invented support set after
//!   value-invention has materialised the set's members (pushdown hook 2);
//! * the derived set's `member_factor` parameter is filled with the
//!   materialised member ids (pushdown hook 1), so the generated
//!   `pd_cell__*[c] = index(F, index(member_factor, c))` gathers resolve;
//! * VI skolem/overlap factor observeds that are themselves join-free
//!   observed expressions (the in-model LCC projections `X`/`Y` over raw
//!   `emis_lon`/`emis_lat`) are evaluated through the FULL expression
//!   evaluator ahead of value-invention — the Rust analogue of Julia's
//!   `_derive_binning_coords` general-eval seeding and Python's
//!   `_binning_coord_arrays(producer_seed_nodes=…)`. The deliberately tiny
//!   `_vi_eval` op set is untouched.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::fmt;
use std::path::PathBuf;

use ndarray::{ArrayD, Axis, IxDyn};
use serde_json::Value as JsonValue;

use crate::aggregate::resolve_expr_ranges_with_extents;
use crate::parse::LoadOptions;
use crate::pushdown_rewrite::{
    GateAxis, ProviderGate, desugar_pushdown, pushdown_coupling_pairs, pushdown_provider_gates,
};
use crate::simulate_array::{Value as EvalValue, eval_expression_with_extents, run_value_invention};
use crate::types::{Expr, IndexSet, Model, VariableType};

/// A build-time preparation failure.
#[derive(Debug, Clone)]
pub struct PrepareError(pub String);

impl fmt::Display for PrepareError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "PrepareError: {}", self.0)
    }
}

impl std::error::Error for PrepareError {}

fn err(msg: impl Into<String>) -> PrepareError {
    PrepareError(msg.into())
}

/// One axis of the NEUTRAL per-axis selection handed to a gated provider —
/// the Rust spelling of the Python engine's `"all" | [0-based indices]` form.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AxisSel {
    /// The full native axis.
    All,
    /// The listed 0-based native indices, in order.
    Indices(Vec<usize>),
}

/// The CONST data-provider contract [`prepare`] consumes: one provider feeds
/// ONE field (the `providers["<Loader>.<var>"]` convention shared with the
/// Julia/Python bindings). A gated provider may additionally honour a pushed-
/// down per-axis selection; one that cannot is fetched whole and sliced
/// engine-side (the fallback matches the pushdown result exactly).
pub trait PrepareProvider {
    /// CONST whole-field sample.
    fn sample(&mut self) -> Result<ArrayD<f64>, PrepareError>;

    /// Whether [`PrepareProvider::sample_with_selection`] pushes the selection
    /// down to the reader (fetching only what intersects it).
    fn supports_selection(&self) -> bool {
        false
    }

    /// Sample with a per-axis selection pushed down. EVERY requested axis is
    /// present in the result (a fixed axis comes back length-1 and is dropped
    /// by the engine).
    fn sample_with_selection(&mut self, _selection: &[AxisSel]) -> Result<ArrayD<f64>, PrepareError> {
        Err(err("provider does not support selection pushdown"))
    }

    /// `false` for a DISCRETE provider (non-empty refresh times) — rejected by
    /// [`prepare`], which is build-time-only.
    fn is_const(&self) -> bool {
        true
    }

    /// A provider-declared gate (the fallback protocol mirroring Julia's
    /// `provider_gate_spec`); the record-derived gate takes precedence.
    fn gate_spec(&self) -> Option<ProviderGate> {
        None
    }
}

/// Build-time options for [`prepare`].
#[derive(Debug, Clone, Default)]
pub struct PrepareOptions {
    /// Select one model when the document holds several.
    pub model_name: Option<String>,
    /// Metaparameter bindings closed at load (esm-spec §9.7.6 site 4).
    pub metaparameters: BTreeMap<String, i64>,
    /// Base path anchoring relative `{ref}`s.
    pub base_path: Option<PathBuf>,
    /// Opt in to the automatic projection-pushdown desugar.
    pub pushdown_rewrite: bool,
    /// Scalar parameter overrides (exact or bare names), baked into the build.
    pub parameters: HashMap<String, f64>,
    /// Per-step progress lines on stdout.
    pub verbose: bool,
}

/// The product of [`prepare`]: every build-time-evaluable observed of the
/// prepared document, materialized through the document's own graph, plus the
/// value-invention products the contract record reports.
pub struct Prepared {
    /// The (possibly rewritten) raw document.
    pub doc: JsonValue,
    /// The prepared model's name.
    pub model_name: String,
    /// Observed name → build-time field (dependency-complete).
    pub fields: HashMap<String, ArrayD<f64>>,
    /// Value-invention producer id (`from_faq`) → sorted-distinct member ids.
    pub members: HashMap<String, Vec<i64>>,
    /// Value-invention producer id → derived index-set extent.
    pub extents: HashMap<String, i64>,
    /// Provider keys that were deferred + fetched pre-sliced (sorted).
    pub gated_provider_keys: Vec<String>,
}

impl Prepared {
    /// The build-time field of observed `name` (exact, else the unique
    /// dotted-name tail match), or an error when `name` was not evaluated.
    pub fn observed_field(&self, name: &str) -> Result<&ArrayD<f64>, PrepareError> {
        if let Some(a) = self.fields.get(name) {
            return Ok(a);
        }
        if !name.contains('.') {
            let mut matches: Vec<&String> = self
                .fields
                .keys()
                .filter(|k| k.contains('.') && k.rsplit('.').next() == Some(name))
                .collect();
            matches.sort();
            if let Some(k) = matches.first() {
                return Ok(&self.fields[*k]);
            }
        }
        Err(err(format!(
            "observed_field: '{name}' is not a build-time-evaluable observed of the \
             prepared document"
        )))
    }
}

// --------------------------------------------------------------------------- //
// Dependency order over the observeds (shared with the pushdown-era runner).
// --------------------------------------------------------------------------- //

/// The factor names an expression declares it reads (`aggregate.args` plus
/// every gather / bare reference), gathered recursively. The dependency edges
/// come from the MODEL, not from a re-derivation here.
fn declared_args(expr: &Expr, out: &mut HashSet<String>) {
    match expr {
        Expr::Variable(name) => {
            out.insert(name.clone());
        }
        Expr::Operator(node) => {
            for a in &node.args {
                declared_args(a, out);
            }
            node.for_each_child(&mut |c| declared_args(c, out));
        }
        _ => {}
    }
}

/// Dependency order over observed definitions: an observed follows every
/// observed it names. A cycle is a malformed model and is a hard error.
fn observed_order(defs: &HashMap<String, Expr>) -> Result<Vec<String>, PrepareError> {
    let deps: HashMap<String, HashSet<String>> = defs
        .iter()
        .map(|(n, e)| {
            let mut a = HashSet::new();
            declared_args(e, &mut a);
            a.retain(|x| defs.contains_key(x) && x != n);
            (n.clone(), a)
        })
        .collect();

    let mut ordered = Vec::new();
    let mut done: HashSet<String> = HashSet::new();
    let mut pending: HashSet<String> = defs.keys().cloned().collect();
    while !pending.is_empty() {
        let mut ready: Vec<String> = pending
            .iter()
            .filter(|n| deps[*n].iter().all(|d| done.contains(d)))
            .cloned()
            .collect();
        if ready.is_empty() {
            let mut rest: Vec<_> = pending.into_iter().collect();
            rest.sort();
            return Err(err(format!("cyclic observed dependency among {rest:?}")));
        }
        ready.sort(); // deterministic tie-break
        for n in ready {
            ordered.push(n.clone());
            done.insert(n.clone());
            pending.remove(&n);
        }
    }
    Ok(ordered)
}

/// name → defining expression, for every `observed` variable of `model`.
fn observed_defs(model: &Model) -> HashMap<String, Expr> {
    model
        .variables
        .iter()
        .filter(|(_, v)| v.var_type == VariableType::Observed && v.expression.is_some())
        .map(|(k, v)| (k.clone(), v.expression.clone().unwrap()))
        .collect()
}

/// Every declared 0-D parameter's default (overridden by `overrides`, exact or
/// bare key) — the scalar evaluation scope, sorted by name.
fn scalar_params(model: &Model, overrides: &HashMap<String, f64>) -> (Vec<f64>, Vec<String>) {
    let mut names: Vec<String> = model
        .variables
        .iter()
        .filter(|(_, v)| {
            v.var_type == VariableType::Parameter
                && v.shape.as_ref().map(|s| s.is_empty()).unwrap_or(true)
                && v.default.is_some()
        })
        .map(|(k, _)| k.clone())
        .collect();
    names.sort();
    let vals = names
        .iter()
        .map(|n| {
            overrides
                .get(n)
                .or_else(|| overrides.get(n.rsplit('.').next().unwrap_or(n)))
                .copied()
                .unwrap_or_else(|| model.variables[n].default.unwrap_or(0.0))
        })
        .collect();
    (vals, names)
}

// --------------------------------------------------------------------------- //
// Pushdown-path name aliasing (the Python `_inject_pushdown_aliases`, adapted
// to the UN-flattened Rust model scope: the coupling routes loader keys onto
// namespaced model names, and every dotted key additionally surfaces under its
// unique shallowest bare tail — the spelling the authored expressions use).
// --------------------------------------------------------------------------- //
fn inject_aliases(arrays: &mut HashMap<String, ArrayD<f64>>, coupling: &[(String, String)]) {
    // The coupling routing is AUTHORITATIVE: a `variable_map` explicitly binds
    // the loader field to the model variable, so surface the array under both
    // the namespaced target and its model-local tail (the authored spelling
    // the un-flattened expressions use). This also disambiguates a tail that
    // several dotted keys would otherwise tie on (`MockSR.TotalPop` vs
    // `ISRM.TotalPop`), which the generic pass below refuses to guess at.
    for (frm, to) in coupling {
        if !arrays.contains_key(frm) {
            continue;
        }
        if !arrays.contains_key(to) {
            let a = arrays[frm].clone();
            arrays.insert(to.clone(), a);
        }
        let tail = to.rsplit('.').next().unwrap_or(to);
        if !arrays.contains_key(tail) {
            let a = arrays[frm].clone();
            arrays.insert(tail.to_string(), a);
        }
    }
    // dotted key → unique shallowest bare tail (existing keys never overwritten).
    let mut tails: HashMap<String, Vec<String>> = HashMap::new();
    for k in arrays.keys() {
        if let Some((_, tail)) = k.rsplit_once('.') {
            tails.entry(tail.to_string()).or_default().push(k.clone());
        }
    }
    for (tail, mut keys) in tails {
        if arrays.contains_key(&tail) {
            continue;
        }
        let mindepth = keys
            .iter()
            .map(|k| k.matches('.').count())
            .min()
            .unwrap_or(0);
        keys.retain(|k| k.matches('.').count() == mindepth);
        keys.sort();
        if keys.len() == 1 {
            let a = arrays[&keys[0]].clone();
            arrays.insert(tail, a);
        }
    }
}

// --------------------------------------------------------------------------- //
// Build-time coordinate path (work item 2): evaluate the join-free observeds
// an overlap-gated `distinct` producer transitively reads, through the FULL
// evaluator, ahead of value-invention.
// --------------------------------------------------------------------------- //

/// The names of the join-free observeds the producer seed nodes transitively
/// reference, i.e. the build-time coordinate closure.
fn producer_seed_closure(
    seeds: &[&Expr],
    defs: &HashMap<String, Expr>,
    join_free: &HashSet<String>,
) -> HashSet<String> {
    let mut needed: HashSet<String> = HashSet::new();
    let mut frontier: Vec<String> = Vec::new();
    let mut refs = HashSet::new();
    for s in seeds {
        declared_args(s, &mut refs);
    }
    for r in refs {
        if join_free.contains(&r) && needed.insert(r.clone()) {
            frontier.push(r);
        }
    }
    while let Some(cur) = frontier.pop() {
        let mut refs = HashSet::new();
        declared_args(&defs[&cur], &mut refs);
        for r in refs {
            if join_free.contains(&r) && needed.insert(r.clone()) {
                frontier.push(r);
            }
        }
    }
    needed
}

/// Evaluate one observed through the full evaluator; returns the dense field.
fn eval_observed(
    name: &str,
    def: &Expr,
    arrays: &HashMap<String, ArrayD<f64>>,
    param_vals: &[f64],
    param_names: &[String],
    index_sets: &HashMap<String, IndexSet>,
    extents: &HashMap<String, i64>,
) -> Result<ArrayD<f64>, PrepareError> {
    let mut expr = def.clone();
    resolve_expr_ranges_with_extents(&mut expr, index_sets, extents)
        .map_err(|e| err(format!("resolve ranges for {name}: {e}")))?;
    let val = eval_expression_with_extents(&expr, arrays, param_vals, param_names, 0.0, extents)
        .map_err(|e| err(format!("evaluate {name}: {e}")))?;
    Ok(match val {
        EvalValue::Array(a) => *a,
        EvalValue::Scalar(s) => ArrayD::from_elem(IxDyn(&[1]), s),
    })
}

// --------------------------------------------------------------------------- //
// Pushdown hook 2: the gated pre-sliced fetch.
// --------------------------------------------------------------------------- //

struct GatedFetchPlan {
    selection: Vec<AxisSel>,
    drop_axes: Vec<usize>,
    gated_pos_out: usize,
    gated_extent: usize,
}

/// Resolve a gate's per-axis `selection` from the materialised value-invention
/// members (0-based native indices for the reader).
fn gated_fetch_plan(
    key: &str,
    gate: &ProviderGate,
    index_sets: &HashMap<String, IndexSet>,
    members: &HashMap<String, Vec<i64>>,
    extents: &HashMap<String, i64>,
) -> Result<GatedFetchPlan, PrepareError> {
    let mut selection: Vec<AxisSel> = Vec::with_capacity(gate.axes.len());
    let mut drop_axes: Vec<usize> = Vec::new();
    let mut gated_pos: Option<usize> = None;
    let mut gated_extent = 0usize;
    for (ax_i, ax) in gate.axes.iter().enumerate() {
        match ax {
            GateAxis::All => selection.push(AxisSel::All),
            GateAxis::Fixed(fi) => {
                selection.push(AxisSel::Indices(vec![*fi]));
                drop_axes.push(ax_i);
            }
            GateAxis::GatedBy(sname) => {
                let faq = index_sets
                    .get(sname)
                    .and_then(|is| (is.kind == "derived").then(|| is.from_faq.clone()))
                    .flatten()
                    .ok_or_else(|| {
                        err(format!(
                            "gated provider '{key}' gates on '{sname}' which is not a \
                             derived index set with a from_faq"
                        ))
                    })?;
                let mem = members.get(&faq).ok_or_else(|| {
                    err(format!(
                        "gated provider '{key}' gates on '{sname}' (faq '{faq}') but its \
                         value-invention members were not materialised"
                    ))
                })?;
                let mem0: Vec<usize> = mem
                    .iter()
                    .map(|&m| {
                        usize::try_from(m - 1).map_err(|_| {
                            err(format!(
                                "gated provider '{key}': member id {m} is not a 1-based \
                                 cell id"
                            ))
                        })
                    })
                    .collect::<Result<_, _>>()?;
                gated_extent = extents
                    .get(&faq)
                    .map(|&e| e as usize)
                    .unwrap_or(mem0.len());
                selection.push(AxisSel::Indices(mem0));
                gated_pos = Some(ax_i);
            }
        }
    }
    let gated_pos =
        gated_pos.ok_or_else(|| err(format!("gated provider '{key}' declares no gated_by axis")))?;
    let gated_pos_out = gated_pos - drop_axes.iter().filter(|&&d| d < gated_pos).count();
    Ok(GatedFetchPlan {
        selection,
        drop_axes,
        gated_pos_out,
        gated_extent,
    })
}

/// Drop the (length-1) fixed axes of a fetched slab.
fn drop_fixed_axes(
    key: &str,
    arr: ArrayD<f64>,
    drop_axes: &[usize],
) -> Result<ArrayD<f64>, PrepareError> {
    if drop_axes.is_empty() {
        return Ok(arr);
    }
    let shape = arr.shape().to_vec();
    for &d in drop_axes {
        if shape.get(d).copied() != Some(1) {
            return Err(err(format!(
                "gated provider '{key}': fixed axis {d} came back with length \
                 {:?} (expected 1) in shape {shape:?}",
                shape.get(d)
            )));
        }
    }
    let out: Vec<usize> = shape
        .iter()
        .enumerate()
        .filter(|(i, _)| !drop_axes.contains(i))
        .map(|(_, &s)| s)
        .collect();
    arr.into_shape_with_order(IxDyn(&out))
        .map_err(|e| err(format!("gated provider '{key}': reshape after fixed-axis drop: {e}")))
}

/// FALLBACK slice for a provider that cannot push a selection down: fetch
/// whole, then take the selected indices axis by axis (identical result).
fn slice_whole(full: ArrayD<f64>, selection: &[AxisSel]) -> ArrayD<f64> {
    let mut arr = full;
    for (i, ax) in selection.iter().enumerate() {
        if let AxisSel::Indices(idx) = ax {
            arr = arr.select(Axis(i), idx);
        }
    }
    arr
}

// --------------------------------------------------------------------------- //
// The entry point.
// --------------------------------------------------------------------------- //

/// Prepare `doc` (a raw parsed `.esm` document) once: run the pushdown rewrite
/// (when opted in), materialize CONST providers, evaluate the build-time
/// coordinates, run value-invention, feed the member factor back, fetch the
/// gated providers pre-sliced, and evaluate the whole observed graph in
/// dependency order. Returns the [`Prepared`] artifact.
///
/// `providers` maps `"<Loader>.<var>"` to a CONST [`PrepareProvider`]; an
/// entry the rewrite record's coupling routes onto a gated array is DEFERRED
/// and fetched pre-sliced after value-invention. `const_arrays` are the
/// caller-supplied build-time factor arrays (keyed by model-local or
/// `Loader.var` names — the coupling aliasing surfaces both spellings).
pub fn prepare(
    doc: &JsonValue,
    const_arrays: HashMap<String, ArrayD<f64>>,
    providers: Vec<(String, Box<dyn PrepareProvider>)>,
    opts: &PrepareOptions,
) -> Result<Prepared, PrepareError> {
    let log = |msg: &str| {
        if opts.verbose {
            println!("{msg}");
        }
    };

    // ---- Phase-1 semantics: pushdown prepass BEFORE the typed parse ---------
    let rewritten = if opts.pushdown_rewrite {
        desugar_pushdown(doc, opts.model_name.as_deref()).map_err(|e| err(e.0))?
    } else {
        std::borrow::Cow::Borrowed(doc)
    };
    let rewrite_fired = matches!(rewritten, std::borrow::Cow::Owned(_));
    let provider_keys: Vec<String> = providers.iter().map(|(k, _)| k.clone()).collect();
    let pd_gates: HashMap<String, ProviderGate> = if rewrite_fired {
        pushdown_provider_gates(&rewritten, &provider_keys).map_err(|e| err(e.0))?
    } else {
        HashMap::new()
    };
    let pd_coupling = pushdown_coupling_pairs(&rewritten);

    // ---- typed load (metaparameters closed at the loader API) ---------------
    let text = serde_json::to_string(rewritten.as_ref())
        .map_err(|e| err(format!("serialize rewritten document: {e}")))?;
    let load_opts = LoadOptions {
        base_path: opts.base_path.clone(),
        metaparameters: opts.metaparameters.clone(),
    };
    let file = crate::parse::load_with_options(&text, &load_opts)
        .map_err(|e| err(format!("load rewritten document: {e}")))?;
    let index_sets: HashMap<String, IndexSet> = file.index_sets.clone().unwrap_or_default();
    let models = file
        .models
        .as_ref()
        .ok_or_else(|| err("document has no models"))?;
    let model_name = match &opts.model_name {
        Some(n) => n.clone(),
        None if models.len() == 1 => models.keys().next().unwrap().clone(),
        None => return Err(err("document holds several models; pass model_name")),
    };
    let model = models
        .get(&model_name)
        .ok_or_else(|| err(format!("model '{model_name}' not found in the document")))?
        .clone();

    let (param_vals, param_names) = scalar_params(&model, &opts.parameters);

    // ---- provider injection: eager CONST materialization; gated deferral ----
    let mut arrays: HashMap<String, ArrayD<f64>> = const_arrays;
    let mut gated: Vec<(String, Box<dyn PrepareProvider>, ProviderGate)> = Vec::new();
    for (k, mut prov) in providers {
        if let Some(gate) = pd_gates.get(&k) {
            // Record-derived gate (the rewrite's own metadata.x_esd.pushdown):
            // defer — value-invention must derive the gating set's members
            // before the rows to fetch are known.
            gated.push((k, prov, gate.clone()));
        } else if let Some(gate) = prov.gate_spec() {
            // Provider-declared gate (the fallback protocol) — also deferred.
            gated.push((k, prov, gate));
        } else if !prov.is_const() {
            return Err(err(format!(
                "prepare: provider '{k}' is DISCRETE (non-empty refresh times); \
                 prepare() is build-time-only"
            )));
        } else {
            let a = prov
                .sample()
                .map_err(|e| err(format!("materialize const provider '{k}': {}", e.0)))?;
            arrays.insert(k, a);
        }
    }
    let mut gated_keys: Vec<String> = gated.iter().map(|(k, _, _)| k.clone()).collect();
    gated_keys.sort();

    // ---- pushdown-path name aliasing ----------------------------------------
    if opts.pushdown_rewrite {
        inject_aliases(&mut arrays, &pd_coupling);
    }

    // ---- observed definitions + the join-free partition ---------------------
    let defs = observed_defs(&model);
    let join_free: HashSet<String> = defs
        .iter()
        .filter(|(_, e)| match e {
            Expr::Operator(node) => node.join.as_ref().map(|j| j.is_empty()).unwrap_or(true),
            _ => true,
        })
        .map(|(n, _)| n.clone())
        .collect();
    let order = observed_order(&defs)?;

    // ---- build-time coordinate path: producer-seeded join-free closure ------
    // (the Rust analogue of Julia's `_derive_binning_coords` general-eval
    // seeding; tolerant — an unresolved coordinate degrades to the engine's
    // own fail-closed contract downstream, exactly as in Python.)
    let seeds: Vec<&Expr> = model
        .equations
        .iter()
        .filter_map(|eq| match &eq.rhs {
            Expr::Operator(node)
                if matches!(node.op.as_str(), "aggregate" | "arrayop")
                    && node.distinct == Some(true)
                    && node.join.as_ref().map(|j| !j.is_empty()).unwrap_or(false) =>
            {
                Some(&eq.rhs)
            }
            _ => None,
        })
        .collect();
    let mut fields: HashMap<String, ArrayD<f64>> = HashMap::new();
    if !seeds.is_empty() {
        let needed = producer_seed_closure(&seeds, &defs, &join_free);
        let no_extents: HashMap<String, i64> = HashMap::new();
        for name in order.iter().filter(|n| needed.contains(*n)) {
            match eval_observed(
                name,
                &defs[name],
                &arrays,
                &param_vals,
                &param_names,
                &index_sets,
                &no_extents,
            ) {
                Ok(a) => {
                    log(&format!(
                        "  [prepare] build-time coordinate {name} -> {:?}",
                        a.shape()
                    ));
                    arrays.insert(name.clone(), a.clone());
                    fields.insert(name.clone(), a);
                }
                Err(e) => {
                    // Tolerant (mirrors Python's skip_unresolved=True): the
                    // producer then fails with ITS diagnostic if it truly
                    // needed this coordinate.
                    log(&format!(
                        "  [prepare] build-time coordinate {name} skipped ({})",
                        e.0
                    ));
                }
            }
        }
    }

    // ---- VALUE INVENTION: the graph derives its own support set -------------
    let vi = run_value_invention(&model, &index_sets, Some(&arrays))
        .map_err(|e| err(format!("value invention: {e}")))?;
    let mut members: HashMap<String, Vec<i64>> = HashMap::new();
    for (faq, mem) in &vi.members {
        let ids: Vec<i64> = mem
            .iter()
            .map(|k| match k {
                crate::relational::Key::Int(i) => Ok(*i),
                other => Err(err(format!(
                    "faq '{faq}': expected scalar integer member keys, got {other:?}"
                ))),
            })
            .collect::<Result<_, _>>()?;
        members.insert(faq.clone(), ids);
    }
    let extents = vi.extents.clone();

    // ---- Hook 1: derived-set member ids fed back as the member_factor -------
    for (sname, is) in &index_sets {
        if is.kind != "derived" {
            continue;
        }
        let (Some(mf), Some(faq)) = (&is.member_factor, &is.from_faq) else {
            continue;
        };
        let Some(mem) = members.get(faq) else {
            continue;
        };
        let v: Vec<f64> = mem.iter().map(|&m| m as f64).collect();
        log(&format!(
            "  [prepare] member_factor {mf} <- |{sname}| = {}",
            v.len()
        ));
        let arr = ArrayD::from_shape_vec(IxDyn(&[v.len()]), v)
            .map_err(|e| err(format!("member factor '{mf}': {e}")))?;
        arrays.insert(mf.clone(), arr);
    }

    // ---- Hook 2: gated-provider deferral → post-VI pre-sliced fetch ---------
    for (key, mut prov, gate) in gated {
        if gate.applies_to.len() != 1 {
            return Err(err(format!(
                "gated provider '{key}': applies_to lists {} variables; bind one \
                 provider per variable (providers[\"Loader.var\"]) so each gated \
                 fetch is a single field",
                gate.applies_to.len()
            )));
        }
        let plan = gated_fetch_plan(&key, &gate, &index_sets, &members, &extents)?;
        let arr = if prov.supports_selection() {
            let a = prov
                .sample_with_selection(&plan.selection)
                .map_err(|e| err(format!("gated fetch '{key}': {}", e.0)))?;
            drop_fixed_axes(&key, a, &plan.drop_axes)?
        } else {
            let full = prov
                .sample()
                .map_err(|e| err(format!("gated fetch '{key}' (whole): {}", e.0)))?;
            drop_fixed_axes(&key, slice_whole(full, &plan.selection), &plan.drop_axes)?
        };
        if arr.shape().get(plan.gated_pos_out).copied() != Some(plan.gated_extent) {
            return Err(err(format!(
                "gated provider '{key}': fetched compact axis is {:?} but the gating \
                 set extent is {}",
                arr.shape().get(plan.gated_pos_out),
                plan.gated_extent
            )));
        }
        // Surface the compact slab under the MODEL variable the coupling routes
        // this provider onto (its local tail — the authored spelling), falling
        // back to the gate's loader-variable tail. ONE registry entry per slab:
        // the SR slabs are hundreds of MB and aliasing would deep-copy.
        let target = pd_coupling
            .iter()
            .find(|(frm, _)| frm == &key)
            .map(|(_, to)| to.rsplit('.').next().unwrap_or(to).to_string())
            .unwrap_or_else(|| gate.applies_to[0].clone());
        log(&format!(
            "  [prepare] gated fetch {key} -> {target} {:?}",
            arr.shape()
        ));
        arrays.insert(target, arr);
    }

    // ---- evaluate the whole observed graph in dependency order --------------
    for name in &order {
        if fields.contains_key(name) {
            continue; // already materialized by the coordinate pre-pass
        }
        let t = std::time::Instant::now();
        let a = eval_observed(
            name,
            &defs[name],
            &arrays,
            &param_vals,
            &param_names,
            &index_sets,
            &extents,
        )?;
        log(&format!(
            "  [prepare] {name:<24} shape={:?}  {:>7.1} s",
            a.shape(),
            t.elapsed().as_secs_f64()
        ));
        arrays.insert(name.clone(), a.clone());
        fields.insert(name.clone(), a);
    }

    Ok(Prepared {
        doc: rewritten.into_owned(),
        model_name,
        fields,
        members,
        extents,
        gated_provider_keys: gated_keys,
    })
}
