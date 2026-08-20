//! Automatic projection-pushdown desugar — the Rust port of the Julia
//! reference (`pkg/EarthSciAST.jl/src/pushdown_rewrite.jl`) and its Python
//! mirror (`earthsci_ast/pushdown_rewrite.py`), current as of the Phase-1
//! clean consolidation (idempotency guard + record/gate helpers) and the
//! Phase-3 deterministic `applies_to`.
//!
//! A pre-build model-transform pass that recognises the ISRM-shaped
//! `+`-semiring "apply a provider-backed full-domain array to a sparsely
//! supported binned factor" pattern in a CLEAN model and AUTO-GENERATES the
//! four hand-authored constructs (derived IndexSet + `distinct` producer +
//! `member_factor` + `gated_select` record) so the existing value-invention /
//! gated-provider pipeline runs unchanged. The author writes NO derived set,
//! NO producer, and NO gated_select — only the natural math.
//!
//! This is a NARROW desugarer (a pattern recogniser), NOT a general optimizer.
//! It fires ONLY when the reduction's semiring is the additive `(+, 0)`
//! monoid; a `max_product` / `min_sum` / etc. aggregate of the SAME shape is
//! left untouched (the soundness guard).
//!
//! DESIGN DECISION (raw-document path): like the Python port, this pass both
//! detects and emits on the RAW `serde_json::Value` document. The rewrite runs
//! BEFORE `parse::load` (the typed parse) — the [`crate::prepare`] entry point
//! keeps the rewritten raw document in hand so every record consumer
//! ([`pushdown_record`], [`pushdown_provider_gates`]) reads the raw side; the
//! typed pipeline downstream only ever sees the generated *constructs* (index
//! set, producer equation, member variables), which the parser preserves.
//! `serde_json`'s `preserve_order` feature is on, so object iteration order
//! matches the Python `dict` order and detection is deterministic across the
//! bindings.
//!
//! Output parity with Julia/Python is pinned by the shared conformance corpus
//! (`tests/conformance/pushdown/`): for each committed input the rewritten
//! document must deep-equal the Julia-emitted golden as parsed JSON (numbers
//! by value, key order free — see the corpus README).

use std::borrow::Cow;
use std::collections::HashMap;
use std::fmt;

use serde_json::{Map, Value, json};

/// A malformed gate/record encountered while deriving provider gates (mirrors
/// the Julia `RefreshError` sites in pushdown_rewrite.jl and the Python
/// `PushdownRewriteError`).
#[derive(Debug, Clone)]
pub struct PushdownRewriteError(pub String);

impl fmt::Display for PushdownRewriteError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "PushdownRewriteError: {}", self.0)
    }
}

impl std::error::Error for PushdownRewriteError {}

// --------------------------------------------------------------------------- //
// Record / model-selection helpers
// --------------------------------------------------------------------------- //

/// The rewrite's provenance record `metadata.x_esd.pushdown` (written by
/// [`desugar_pushdown`]), or `None` when `doc` carries none. This is the
/// record the engine reads BACK to derive provider gates.
pub fn pushdown_record(doc: &Value) -> Option<&Map<String, Value>> {
    doc.get("metadata")?
        .get("x_esd")?
        .get("pushdown")?
        .as_object()
}

fn pd_model_name(doc: &Value, model_name: Option<&str>) -> Option<String> {
    if let Some(m) = model_name {
        return Some(m.to_string());
    }
    let models = doc.get("models")?.as_object()?;
    if models.len() == 1 {
        models.keys().next().cloned()
    } else {
        None
    }
}

// --------------------------------------------------------------------------- //
// Raw-AST leaf helpers (the Julia typed-IR helpers, on raw JSON)
// --------------------------------------------------------------------------- //

fn pd_varname(e: &Value) -> Option<&str> {
    e.as_str()
}

fn op_of(e: &Value) -> Option<&str> {
    e.get("op")?.as_str()
}

/// `index(F, sym)` with EXACTLY one index → `(F, sym)`; else `None`.
fn pd_index_split(e: &Value) -> Option<(&str, &str)> {
    if op_of(e)? != "index" {
        return None;
    }
    let a = e.get("args")?.as_array()?;
    if a.len() != 2 {
        return None;
    }
    Some((pd_varname(&a[0])?, pd_varname(&a[1])?))
}

/// `index(F, sym…)` with ≥1 index → `(F, [syms…])`; else `None`.
fn pd_index_syms(e: &Value) -> Option<(&str, Vec<&str>)> {
    if op_of(e)? != "index" {
        return None;
    }
    let a = e.get("args")?.as_array()?;
    if a.len() < 2 {
        return None;
    }
    let f = pd_varname(&a[0])?;
    let mut syms = Vec::with_capacity(a.len() - 1);
    for x in &a[1..] {
        syms.push(pd_varname(x)?);
    }
    Some((f, syms))
}

/// Classify an aggregate BODY `A[c, out…] · E[c]` — a two-factor `⊗=·`
/// product of a rank-(1+|out|) array factor `A` subscripted `[c, out…]` and a
/// rank-1 factor `E` subscripted `[c]` — into `(Aname, Ename)`, or `None`
/// when `body` is not that exact shape. PURE STRUCTURAL check on index
/// symbols (the caller applies the semiring guard).
fn pd_matvec_factors(body: &Value, c_sym: &str, out_syms: &[&str]) -> Option<(String, String)> {
    if op_of(body)? != "*" {
        return None;
    }
    let args = body.get("args")?.as_array()?;
    if args.len() != 2 || out_syms.is_empty() {
        return None;
    }
    let mut a_syms: Vec<&str> = vec![c_sym];
    a_syms.extend_from_slice(out_syms);
    let e_syms: Vec<&str> = vec![c_sym];
    let mut aname: Option<&str> = None;
    let mut ename: Option<&str> = None;
    for arg in args {
        let (f, syms) = pd_index_syms(arg)?;
        if syms == a_syms {
            aname = Some(f);
        } else if syms == e_syms {
            ename = Some(f);
        }
    }
    Some((aname?.to_string(), ename?.to_string()))
}

/// (⊕ spelling, 0̄) — mirrors the Julia `_aggregate_oplus_identity` used by
/// the semiring guard; only the `("+", 0.0)` comparison matters to this pass.
fn semiring_oplus(semiring: &str) -> Option<(&'static str, f64)> {
    match semiring {
        "sum_product" => Some(("+", 0.0)),
        "max_product" => Some(("max", f64::NEG_INFINITY)),
        "min_sum" => Some(("min", f64::INFINITY)),
        "max_sum" => Some(("max", f64::NEG_INFINITY)),
        "bool_and_or" => Some(("or", 0.0)),
        _ => None,
    }
}

fn oplus_identity(reduce: &str) -> Option<f64> {
    match reduce {
        "+" => Some(0.0),
        "max" => Some(f64::NEG_INFINITY),
        "min" => Some(f64::INFINITY),
        "*" => Some(1.0),
        "or" => Some(0.0),
        _ => None,
    }
}

fn pd_oplus(agg: &Value) -> Option<(String, f64)> {
    if let Some(semiring) = agg.get("semiring") {
        let s = value_to_display_string(semiring);
        return semiring_oplus(&s).map(|(o, i)| (o.to_string(), i));
    }
    let r = match agg.get("reduce") {
        None | Some(Value::Null) => "+".to_string(),
        Some(v) => value_to_display_string(v),
    };
    let id = oplus_identity(&r)?;
    Some((r, id))
}

/// The Python `str(v)` coercion the reference applies to record fields.
fn value_to_display_string(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        other => other.to_string(),
    }
}

fn is_aggregate_op(op: Option<&str>) -> bool {
    matches!(op, Some("aggregate") | Some("arrayop"))
}

fn pd_flip(op: &str) -> &'static str {
    match op {
        "<" => ">",
        "<=" => ">=",
        ">" => "<",
        _ => "<=",
    }
}

/// Condition of the first `ifelse(cond, then, else)` in a raw subtree.
/// Object-value iteration is insertion-ordered (`preserve_order`), matching
/// the Python `dict.values()` walk exactly.
fn pd_find_ifelse_cond(e: &Value) -> Option<&Value> {
    match e {
        Value::Object(m) => {
            if m.get("op").and_then(Value::as_str) == Some("ifelse")
                && let Some(a) = m.get("args").and_then(Value::as_array)
                && a.len() == 3
            {
                return Some(&a[0]);
            }
            for v in m.values() {
                if let Some(r) = pd_find_ifelse_cond(v) {
                    return Some(r);
                }
            }
            None
        }
        Value::Array(xs) => {
            for x in xs {
                if let Some(r) = pd_find_ifelse_cond(x) {
                    return Some(r);
                }
            }
            None
        }
        _ => None,
    }
}

/// The overlap-gate envelopes of a rectangle-containment predicate.
struct Containment {
    src_env: [String; 2],
    tgt_env: [String; 4],
}

/// Parse a rectangle-containment predicate — an `and`/`*` of comparisons,
/// each between a CELL-indexed rect factor and a RECORD-indexed point factor
/// — into the overlap-gate envelopes `(src_env=[Px,Py],
/// tgt_env=[xmin,ymin,xmax,ymax])`; `None` unless exactly two point
/// coordinates each carry BOTH a min and a max cell bound.
fn pd_parse_containment(pred: &Value, c_sym: &str, r_sym: &str) -> Option<Containment> {
    if !pred.is_object() {
        return None;
    }
    let single = [pred.clone()];
    let comps: &[Value] = if matches!(op_of(pred), Some("and") | Some("*")) {
        pred.get("args")?.as_array()?.as_slice()
    } else {
        &single
    };
    // point factor -> {"min": rect, "max": rect}, in first-seen point order.
    let mut bounds: HashMap<String, HashMap<&'static str, String>> = HashMap::new();
    let mut point_order: Vec<String> = Vec::new();
    for cmp in comps {
        let opn0 = op_of(cmp)?;
        if !matches!(opn0, "<" | "<=" | ">" | ">=") {
            return None;
        }
        let args = cmp.get("args")?.as_array()?;
        if args.len() != 2 {
            return None;
        }
        let (f1, sym1) = pd_index_split(&args[0])?;
        let (f2, sym2) = pd_index_split(&args[1])?;
        let (fc, fp, cell_on_left) = if sym1 == c_sym && sym2 == r_sym {
            (f1, f2, true)
        } else if sym1 == r_sym && sym2 == c_sym {
            (f2, f1, false)
        } else {
            return None;
        };
        let opn = if cell_on_left { opn0 } else { pd_flip(opn0) };
        let kind = if matches!(opn, "<" | "<=") { "min" } else { "max" };
        let entry = bounds.entry(fp.to_string()).or_insert_with(|| {
            point_order.push(fp.to_string());
            HashMap::new()
        });
        entry.insert(kind, fc.to_string());
    }
    if point_order.len() != 2 {
        return None;
    }
    let (px, py) = (point_order[0].clone(), point_order[1].clone());
    for p in [&px, &py] {
        let b = &bounds[p.as_str()];
        if !b.contains_key("min") || !b.contains_key("max") {
            return None;
        }
    }
    Some(Containment {
        tgt_env: [
            bounds[&px]["min"].clone(),
            bounds[&py]["min"].clone(),
            bounds[&px]["max"].clone(),
            bounds[&py]["max"].clone(),
        ],
        src_env: [px, py],
    })
}

fn ranges_of(agg: &Value) -> Option<&Map<String, Value>> {
    agg.get("ranges")?.as_object()
}

fn range_from(v: Option<&Value>) -> Option<&str> {
    v?.get("from")?.as_str()
}

/// A matched binning aggregate — a `+`-semiring reduction over TWO 1-D index
/// sets whose body carries a rectangle-containment predicate between a
/// CELL-indexed rect factor and a RECORD-indexed point factor. BOTH
/// orientations are recognised (CONFORMANCE_SPEC.md §5.5.7):
///
/// ```text
/// FORWARD  E[c] = Σ_r [contains(cell_c, pt_r)] · …   (the cell axis is output)
/// MIRROR   P[r] = Σ_c [contains(cell_c, pt_r)] · …   (the record axis is output)
/// ```
struct Binning {
    /// The loop symbol carrying the CELL side (the four rect bounds).
    c_sym: String,
    /// The loop symbol carrying the RECORD side (the two point coordinates).
    r_sym: String,
    /// The index set `c_sym` ranges over.
    c_set: String,
    /// The index set `r_sym` ranges over.
    r_set: String,
    /// `true` when the aggregate's own output axis is the CELL one (FORWARD).
    out_is_cell: bool,
    src_env: [String; 2],
    tgt_env: [String; 4],
}

/// The RHS of the equation whose LHS is the bare variable `name` — the esm
/// 1.0.0 home of the 0.x `variables[name].expression` (esm-spec §6.3.1). An
/// unknown defined by a bare-variable LHS IS the observed this pass matches on,
/// so "has a definition here" and "is observed" are the same question.
fn pd_def<'a>(model: &'a Value, name: &str) -> Option<&'a Value> {
    model
        .get("equations")?
        .as_array()?
        .iter()
        .find(|eq| eq.get("lhs").and_then(Value::as_str) == Some(name))?
        .get("rhs")
}

/// Mutable counterpart of [`pd_def`].
fn pd_def_mut<'a>(model: &'a mut Value, name: &str) -> Option<&'a mut Value> {
    model
        .get_mut("equations")?
        .as_array_mut()?
        .iter_mut()
        .find(|eq| eq.get("lhs").and_then(Value::as_str) == Some(name))?
        .get_mut("rhs")
}

/// Give `name` a defining equation with RHS `rhs`, replacing any existing one.
fn pd_set_def(model: &mut Value, name: &str, rhs: Value) {
    if let Some(existing) = pd_def_mut(model, name) {
        *existing = rhs;
        return;
    }
    let eqs = model
        .as_object_mut()
        .expect("model is an object")
        .entry("equations")
        .or_insert_with(|| Value::Array(Vec::new()));
    if !eqs.is_array() {
        *eqs = Value::Array(Vec::new());
    }
    if let Some(list) = eqs.as_array_mut() {
        list.push(json!({"lhs": name, "rhs": rhs}));
    }
}

/// Is `v` a declared UNKNOWN (esm-spec §6.3)?
fn pd_is_unknown(v: &Value) -> bool {
    v.get("type").and_then(Value::as_str) == Some("unknown")
}

/// Is `ev` a binning aggregate whose OUTPUT axis is `out_set`? Returns the
/// binding, or `None`.
///
/// The gate is IDENTICAL either way — the enumeration driver binds its two
/// symbols from the join clause's declared envelopes and knows nothing about
/// cells vs records, and the aggregate's own `output_idx` decides the result's
/// orientation. So the guards here are on the aggregate's SHAPE, not on which
/// axis is which: `out_set` is the index set the observed is shaped on, the
/// single other range supplies the opposite side, and the CONTAINMENT PREDICATE
/// itself says which symbol is the cell (it carries the four rect BOUND
/// factors) and which is the record (the two point coordinates).
fn pd_detect_binning(ev: &Value, agg: &Value, out_set: &str) -> Option<Binning> {
    if !pd_is_unknown(ev) {
        return None;
    }
    let shape = ev.get("shape")?.as_array()?;
    if shape.len() != 1 || shape[0].as_str()? != out_set {
        return None;
    }
    if !is_aggregate_op(op_of(agg)) {
        return None;
    }
    let (oplus, ident) = pd_oplus(agg)?;
    if !(oplus == "+" && ident == 0.0) {
        return None; // SEMIRING GUARD
    }
    let oi = agg.get("output_idx")?.as_array()?;
    if oi.len() != 1 {
        return None;
    }
    let out_sym = oi[0].as_str()?;
    let ranges = ranges_of(agg)?;
    if ranges.len() != 2 || range_from(ranges.get(out_sym)) != Some(out_set) {
        return None;
    }
    let in_sym = ranges.keys().find(|k| k.as_str() != out_sym)?.clone();
    let in_set = range_from(ranges.get(&in_sym))?.to_string();
    let body = agg.get("expr")?;
    if !body.is_object() {
        return None;
    }
    let pred = pd_find_ifelse_cond(body)?;
    // Exactly one of the two assignments parses: `pd_parse_containment` demands
    // each comparison put the cell symbol on one side and the record symbol on
    // the other, and that the record side yield exactly two coordinates each
    // with a min AND a max cell bound.
    if let Some(env) = pd_parse_containment(pred, out_sym, &in_sym) {
        return Some(Binning {
            c_sym: out_sym.to_string(),
            r_sym: in_sym,
            c_set: out_set.to_string(),
            r_set: in_set,
            out_is_cell: true,
            src_env: env.src_env,
            tgt_env: env.tgt_env,
        });
    }
    let env = pd_parse_containment(pred, &in_sym, out_sym)?;
    Some(Binning {
        c_sym: in_sym,
        r_sym: out_sym.to_string(),
        c_set: in_set,
        r_set: out_set.to_string(),
        out_is_cell: false,
        src_env: env.src_env,
        tgt_env: env.tgt_env,
    })
}

// --------------------------------------------------------------------------- //
// Detection-time template-reference expansion (esm-spec §9.6.4 rule 2).
//
// Under Option B (§9.6.4) `load` PRESERVES `apply_expression_template`
// references: they ride to the build boundary, where they are expanded ONCE with
// site recording (the ~50x node-lowering win). `prepare` therefore hands
// `desugar_pushdown` a document whose binning body may be a surviving reference
// rather than the containment `ifelse` the recogniser looks for.
//
// §9.6.4 rule 4 ("patterns do not see through surviving references") governs the
// §9.6.3 REWRITE-RULE ENGINE. This desugar is a different consumer and rule 2
// governs it: a reference DENOTES its expansion. So whether the pushdown fires
// MUST NOT depend on whether the author factored the body through a template —
// detection runs on the EXPANDED view.
//
// EMISSION does not: `pd_apply` edits the call site's `bindings` (and the
// aggregate's own `ranges` / `args` / `shape` / `join`), never the shared
// template body, so the body stays shared and singly-lowered and Option B
// survives the rewrite. `pd_assert_rects_rebound` is the post-condition.
// --------------------------------------------------------------------------- //

/// The op name of a surviving expression-template reference.
const APPLY_OP: &str = "apply_expression_template";

/// The component template registry of `model`, or `None`.
///
/// Only the component-level `expression_templates` block is consulted, which is
/// what the Julia reference reads (`coerce_esm_file` fills `component_templates`
/// from exactly these blocks) — a top-level authored registry is a DECLARATION
/// that load materialises into the components, so on the `prepare` input form
/// the per-component block is the registry.
fn pd_templates(model: &Value) -> Option<&Map<String, Value>> {
    model
        .get("expression_templates")
        .and_then(Value::as_object)
        .filter(|m| !m.is_empty())
}

/// Does `node` carry a surviving `apply_expression_template` reference?
/// Descends every object value, `bindings` included.
fn pd_has_apply(node: &Value) -> bool {
    match node {
        Value::Object(m) => {
            m.get("op").and_then(Value::as_str) == Some(APPLY_OP)
                || m.values().any(pd_has_apply)
        }
        Value::Array(xs) => xs.iter().any(pd_has_apply),
        _ => false,
    }
}

/// The `name` of the first surviving reference in `node` (pre-order), for the
/// residual diagnostic; `None` when it carries none.
fn pd_first_apply_name(node: &Value) -> Option<String> {
    match node {
        Value::Object(m) => {
            if m.get("op").and_then(Value::as_str) == Some(APPLY_OP) {
                return m.get("name").and_then(Value::as_str).map(str::to_string);
            }
            m.values().find_map(pd_first_apply_name)
        }
        Value::Array(xs) => xs.iter().find_map(pd_first_apply_name),
        _ => None,
    }
}

/// `Expand(node)` against `templates` — DETECTION ONLY; nothing of the result is
/// emitted. Returns `None` when there is nothing to expand, and `None` when
/// expansion FAILS: the pass's contract is to leave a document it cannot
/// recognise alone, and an unexpandable reference is then reported by
/// [`pd_binning_refusal`] if the variable is join-shaped.
fn pd_expand_for_detection(node: &Value, templates: Option<&Map<String, Value>>) -> Option<Value> {
    let templates = templates?;
    if !pd_has_apply(node) {
        return None;
    }
    crate::lower_expression_templates::expand_against_registry(node, templates, "pushdown_rewrite")
        .ok()
}

/// The definitions ([`pd_def`]) that carried a surviving
/// `apply_expression_template` reference, EXPANDED — the `Expand(tree)` view the
/// pattern matcher must see (§9.6.4 rule 2). From esm 1.0.0 an observed
/// unknown's body is its defining EQUATION's right-hand side, so this — not the
/// variable table — is what the detector matches against.
///
/// Only the expanded definitions are returned, as OVERRIDES for [`pd_def_view`]
/// to consult: a template-free document builds an empty map, allocates no
/// `Value`, and takes the byte-identical pre-existing path.
///
/// DETECTION ONLY. The emission side reads [`pd_def`] / [`pd_def_mut`] so it
/// edits the AUTHORED body (and, for a template-factored one, the call site's
/// `bindings`) rather than a detached expansion.
fn pd_detection_defs(model: &Value) -> Map<String, Value> {
    let mut out = Map::new();
    let templates = pd_templates(model);
    if templates.is_none() {
        return out;
    }
    let Some(eqs) = model.get("equations").and_then(Value::as_array) else {
        return out;
    };
    for eq in eqs {
        let Some(lhs) = eq.get("lhs").and_then(Value::as_str) else {
            continue;
        };
        let Some(rhs) = eq.get("rhs") else {
            continue;
        };
        // FIRST definition wins, matching `pd_def`.
        if out.contains_key(lhs) {
            continue;
        }
        if let Some(expanded) = pd_expand_for_detection(rhs, templates) {
            out.insert(lhs.to_string(), expanded);
        }
    }
    out
}

/// [`pd_def`] through the detection view: the EXPANDED body when
/// [`pd_detection_defs`] produced one for `name`, else the authored body.
fn pd_def_view<'a>(
    model: &'a Value,
    defs: &'a Map<String, Value>,
    name: &str,
) -> Option<&'a Value> {
    defs.get(name).or_else(|| pd_def(model, name))
}

// --------------------------------------------------------------------------- //
// Residual diagnostics.
//
// A pattern recogniser that declines SILENTLY is indistinguishable from one that
// fired — until, hours later, an ungated provider fetch runs the machine out of
// memory. These keep the two cases apart:
//
//   NOT A JOIN           — a `+`-aggregate with no containment predicate is a
//                          legitimately dense factor. Nothing to gate, no
//                          diagnostic.
//   A JOIN I CANNOT READ — the aggregate bins records into cells of the SAME set
//                          that indexes a provider-backed rank-2 array it feeds,
//                          but the containment could not be recovered. Reported.
//
// WARNING, not error: the pass's contract (CONFORMANCE_SPEC §5.5.7) is that an
// unrecognised document comes back unchanged, and the residue is a PERFORMANCE
// defect — the numbers stay right, the fetch gets big. The one hard error in
// this pass is `pd_assert_rects_rebound`, where the rewrite HAS fired and a rect
// factor could not be re-pointed: wrong numbers, not slow ones.
// --------------------------------------------------------------------------- //

/// The fixed, cross-binding `consequence` string of a residual diagnostic.
pub const PD_UNGATED_CONSEQUENCE: &str =
    "the provider-backed array is fetched WHOLESALE — no derived support set \
is produced and no gate is emitted";

/// Why [`pd_detect_binning`] refused `ev`, for a caller that has ALREADY
/// established `ev` sits in the join position. `agg` is `ev`'s defining
/// equation RHS from the detection view, exactly as [`pd_detect_binning`]
/// received it.
///
/// `None` ⇒ `ev` is simply not join-shaped (no diagnostic warranted). Otherwise
/// `(reason, template)`: `("surviving_template_reference", Some(name))` when the
/// body carries a reference that could not be expanded for matching,
/// `("predicate_unparsed", None)` when a containment `ifelse` was found but did
/// not read as a rectangle containment in either orientation.
fn pd_binning_refusal(
    ev: &Value,
    agg: &Value,
    out_set: &str,
) -> Option<(&'static str, Option<String>)> {
    let shape = ev.get("shape")?.as_array()?;
    if shape.len() != 1 || shape[0].as_str() != Some(out_set) {
        return None;
    }
    if !is_aggregate_op(op_of(agg)) {
        return None;
    }
    let (oplus, ident) = pd_oplus(agg)?;
    if !(oplus == "+" && ident == 0.0) {
        return None;
    }
    let oi = agg.get("output_idx")?.as_array()?;
    if oi.len() != 1 {
        return None;
    }
    let out_sym = oi[0].as_str()?;
    let ranges = ranges_of(agg)?;
    if ranges.len() != 2 || range_from(ranges.get(out_sym)) != Some(out_set) {
        return None;
    }
    let in_sym = ranges.keys().find(|k| k.as_str() != out_sym)?;
    range_from(ranges.get(in_sym))?;
    let body = agg.get("expr")?;
    if !body.is_object() {
        return None;
    }
    if pd_find_ifelse_cond(body).is_none() {
        // No predicate at all ⇒ genuinely dense, unless a surviving reference
        // is hiding one.
        let tname = pd_first_apply_name(body)?;
        return Some(("surviving_template_reference", Some(tname)));
    }
    Some(("predicate_unparsed", None))
}

/// The human-readable rendering of one diagnostic record: what was recognised,
/// what could not be read, and what it costs.
pub fn pd_diagnostic_message(d: &Value) -> String {
    let g = |k: &str| d.get(k).and_then(Value::as_str).unwrap_or("");
    let why = if g("reason") == "surviving_template_reference" {
        let tpl = d.get("template").and_then(Value::as_str);
        format!(
            "its body carries a surviving `apply_expression_template` reference{} \
that could not be expanded for matching",
            match tpl {
                Some(t) => format!(" to '{t}'"),
                None => String::new(),
            }
        )
    } else {
        "its containment predicate did not read as a rectangle containment between \
four cell-indexed rect bounds and two record-indexed point coordinates"
            .to_string()
    };
    format!(
        "projection-pushdown desugar: '{}' is join-shaped — it bins records into the \
cells of index set '{}' and feeds the provider-backed array '{}' through '{}' — but \
{}, so the rewrite does NOT fire for it and {}. Bind the containment's factors \
through the template's params, or write the predicate longhand.",
        g("variable"),
        g("index_set"),
        g("array"),
        g("consumer"),
        why,
        PD_UNGATED_CONSEQUENCE
    )
}

/// The MIRRORED-orientation binning aggregates of a model: per-RECORD observeds
/// `P[r] = Σ_{c∈C} [contains(cell_c, pt_r)] · …` over the plan's cell set
/// `c_set` and record set `r_set`. Returned as `(name, src_env, tgt_env)`
/// triples, SORTED by name so the emitted document is identical across
/// bindings and hash seeds.
///
/// A mirror needs NOTHING but the gate (CONFORMANCE_SPEC.md §5.5.7, "MIRRORED
/// arm"). Its cell axis stays the FULL `c_set`, so its envelope factors are the
/// document's own const-array rects, unrewritten.
fn pd_mirror_specs(
    model: &Value,
    defs: &Map<String, Value>,
    c_set: &str,
    r_set: &str,
    forward_names: &[String],
) -> Vec<(String, [String; 2], [String; 4])> {
    let mut out: Vec<(String, [String; 2], [String; 4])> = Vec::new();
    let Some(variables) = model.get("variables").and_then(Value::as_object) else {
        return out;
    };
    for (name, v) in variables {
        if forward_names.iter().any(|f| f == name) {
            continue;
        }
        let Some(agg) = pd_def_view(model, defs, name) else {
            continue;
        };
        let Some(bind) = pd_detect_binning(v, agg, r_set) else {
            continue;
        };
        if bind.out_is_cell || bind.c_set != c_set || bind.r_set != r_set {
            continue;
        }
        // Never stack a second gate on an aggregate that already declares a join.
        if agg.get("join").is_some() {
            continue;
        }
        out.push((name.clone(), bind.src_env, bind.tgt_env));
    }
    out.sort_by(|a, b| a.0.cmp(&b.0));
    out
}

/// The detected pushdown plan (the Julia/Python plan dict, typed).
struct Plan {
    c_set: String,
    rcv_set: String,
    r_set: String,
    /// `(conc name, contracted symbol)` per matched reduction.
    conc_specs: Vec<(String, String)>,
    /// Provider-backed array factors to gate, SORTED (deterministic
    /// `applies_to` — the one collection-order-dependent list that leaks into
    /// the emitted document; mirrors the Julia `sort!(A_names)`).
    a_names: Vec<String>,
    /// `(E name, cell symbol, gate src_env, gate tgt_env)` per matched
    /// FORWARD binning observed. The envelopes are the ones
    /// [`pd_parse_containment`] read out of THIS aggregate's own containment
    /// predicate — the gate emitted onto the rewritten `E` is derived, not
    /// authored.
    e_specs: Vec<(String, String, [String; 2], [String; 4])>,
    /// `(P name, gate src_env, gate tgt_env)` per MIRRORED binning observed,
    /// sorted by name. These receive ONLY the gate (§5.5.7 "MIRRORED arm").
    mirror_specs: Vec<(String, [String; 2], [String; 4])>,
    src_env: [String; 2],
    tgt_env: [String; 4],
    rep_ename: String,
    rep_csym: String,
    rep_rsym: String,
}

/// Detect the pushdown pattern across a model's observeds.
///
/// `defs` is the DETECTION view ([`pd_detection_defs`]): the observed
/// definitions with surviving template references expanded, so a binning body
/// factored through a template matches exactly as its expansion would. `model`
/// supplies the declarations beside them — shapes and types, which no expansion
/// touches.
///
/// Returns `(plan, diagnostics)` — `plan` `None` when nothing matches / the
/// semiring guard fails, `diagnostics` the residual "a join I could not read"
/// records (see [`pd_binning_refusal`]).
fn pd_detect(model: &Value, defs: &Map<String, Value>) -> (Option<Plan>, Vec<Value>) {
    let Some(variables) = model.get("variables").and_then(Value::as_object) else {
        return (None, Vec::new());
    };
    let mut diags: Vec<Value> = Vec::new();
    let mut conc_specs: Vec<(String, String)> = Vec::new();
    let mut a_names: Vec<String> = Vec::new();
    let mut e_specs: Vec<(String, String, [String; 2], [String; 4])> = Vec::new();
    let mut plan: Option<Plan> = None;

    for (cname, cv) in variables {
        if !pd_is_unknown(cv) {
            continue;
        }
        // An OBSERVED unknown is one with a bare-variable-LHS defining
        // equation (esm-spec §6.3.1); one without is a state or algebraic
        // unknown and matches nothing here.
        let Some(agg) = pd_def_view(model, defs, cname) else {
            continue;
        };
        if !is_aggregate_op(op_of(agg)) {
            continue;
        }
        let Some((oplus, ident)) = pd_oplus(agg) else {
            continue;
        };
        if !(oplus == "+" && ident == 0.0) {
            continue; // SEMIRING GUARD
        }
        let Some(oi) = agg.get("output_idx").and_then(Value::as_array) else {
            continue;
        };
        if oi.len() != 1 {
            continue;
        }
        let Some(rcv_sym) = oi[0].as_str() else {
            continue;
        };
        let Some(ranges) = ranges_of(agg) else {
            continue;
        };
        if ranges.len() != 2 || !ranges.contains_key(rcv_sym) {
            continue;
        }
        let Some(s_sym) = ranges.keys().find(|k| k.as_str() != rcv_sym) else {
            continue;
        };
        let Some(c_set) = range_from(ranges.get(s_sym)) else {
            continue;
        };
        let Some(r_set) = range_from(ranges.get(rcv_sym)) else {
            continue;
        };
        let Some(body) = agg.get("expr") else {
            continue;
        };
        let Some((aname, ename)) = pd_matvec_factors(body, s_sym, &[rcv_sym]) else {
            continue;
        };
        // A must be a declared rank-2 parameter [c_set, r_set].
        let Some(av) = variables.get(&aname) else {
            continue;
        };
        let a_ok = av.get("type").and_then(Value::as_str) == Some("parameter")
            && av
                .get("shape")
                .and_then(Value::as_array)
                .map(|s| {
                    s.len() == 2
                        && s[0].as_str() == Some(c_set)
                        && s[1].as_str() == Some(r_set)
                })
                .unwrap_or(false);
        if !a_ok {
            continue;
        }
        let Some(ev) = variables.get(&ename) else {
            continue;
        };
        let Some(eagg) = pd_def_view(model, defs, &ename) else {
            continue;
        };
        let Some(bind) = pd_detect_binning(ev, eagg, c_set) else {
            // `ev` is the rank-1 factor of a `+`-mat-vec against a
            // provider-backed `[c_set, r_set]` array: the join position. If it
            // is ALSO binning-shaped but unreadable, say so — silence here is
            // the ungated whole-array fetch that surfaces hours later.
            if let Some((reason, template)) = pd_binning_refusal(ev, eagg, c_set) {
                diags.push(json!({
                    "code": "pushdown_join_unrecognised",
                    "variable": ename,
                    "consumer": cname,
                    "array": aname,
                    "index_set": c_set,
                    "reason": reason,
                    "template": match template {
                        Some(t) => Value::String(t),
                        None => Value::Null,
                    },
                    "consequence": PD_UNGATED_CONSEQUENCE,
                }));
            }
            continue;
        };
        if !bind.out_is_cell {
            continue; // FORWARD arm only
        }

        match &plan {
            None => {
                plan = Some(Plan {
                    c_set: c_set.to_string(),
                    rcv_set: r_set.to_string(),
                    r_set: bind.r_set.clone(),
                    conc_specs: Vec::new(),
                    a_names: Vec::new(),
                    e_specs: Vec::new(),
                    mirror_specs: Vec::new(),
                    src_env: bind.src_env.clone(),
                    tgt_env: bind.tgt_env.clone(),
                    rep_ename: ename.clone(),
                    rep_csym: bind.c_sym.clone(),
                    rep_rsym: bind.r_sym.clone(),
                });
            }
            Some(p) if !(c_set == p.c_set && r_set == p.rcv_set) => {
                continue; // narrow: one cell set
            }
            Some(_) => {}
        }
        conc_specs.push((cname.clone(), s_sym.clone()));
        if !a_names.contains(&aname) {
            a_names.push(aname);
        }
        if !e_specs.iter().any(|(e, ..)| e == &ename) {
            e_specs.push((ename, bind.c_sym, bind.src_env, bind.tgt_env));
        }
    }
    // Deterministic, deduplicated diagnostic order: `variables` is a
    // key-ordered map but the same E can be reached from several `conc`
    // consumers.
    diags.sort_by(|a, b| {
        let k = |v: &Value| {
            (
                v["variable"].as_str().unwrap_or("").to_string(),
                v["consumer"].as_str().unwrap_or("").to_string(),
                v["array"].as_str().unwrap_or("").to_string(),
            )
        };
        k(a).cmp(&k(b))
    });
    diags.dedup_by(|a, b| {
        a["variable"] == b["variable"] && a["consumer"] == b["consumer"] && a["array"] == b["array"]
    });
    let Some(mut plan) = plan else {
        return (None, diags);
    };
    if conc_specs.is_empty() {
        return (None, diags);
    }
    // Deterministic plan order (mirrors the Julia `sort!(A_names)`).
    a_names.sort();
    // MIRRORED-orientation binning aggregates (`P[r] = Σ_c […]`) over the SAME
    // cell/record sets. They are collected only once the forward pattern has
    // fixed `c_set`/`r_set`: the mirror is a RIDER on the rewrite, never its
    // trigger, so a document holding only mirrored binning aggregates is not
    // rewritten at all (§5.5.7).
    let forward_names: Vec<String> = e_specs.iter().map(|(e, ..)| e.clone()).collect();
    plan.mirror_specs =
        pd_mirror_specs(model, defs, &plan.c_set, &plan.r_set, &forward_names);
    plan.conc_specs = conc_specs;
    plan.a_names = a_names;
    plan.e_specs = e_specs;
    (Some(plan), diags)
}

// --------------------------------------------------------------------------- //
// Emission
// --------------------------------------------------------------------------- //

/// In-place: rewrite every `index(F, …)` whose factor `F` is a key of
/// `rectmap` to `index(rectmap[F], …)` throughout a raw AST subtree.
///
/// This walk descends EVERY object value, `bindings` included, so a rect factor
/// that reaches the binning body through an `apply_expression_template` call
/// site is reached AT THE CALL SITE — which is exactly where the rewrite must
/// land, so the shared template body stays untouched and singly-lowered
/// (esm-spec §9.6.4 Option B). Two binding spellings carry a rect factor and
/// both are handled: a subscripted binding (`{"F": index(src_W, "c")}`) by the
/// `index` arm, and a BARE FACTOR-NAME binding (`{"F": "src_W"}`, substituted
/// into the body's own `index(F, c)`) by the `bindings` arm. A bare string is
/// rewritten ONLY inside `bindings` — elsewhere a string is an `output_idx`
/// entry, a range key, a scalar field or a template `name`, none of which are
/// variable references.
fn pd_rewrite_rects(node: &mut Value, rectmap: &HashMap<String, String>) {
    match node {
        Value::Object(m) => {
            if m.get("op").and_then(Value::as_str) == Some("index")
                && let Some(a) = m.get_mut("args").and_then(Value::as_array_mut)
                && let Some(first) = a.first_mut()
                && let Some(f) = first.as_str()
                && let Some(g) = rectmap.get(f)
            {
                *first = Value::String(g.clone());
            }
            if m.get("op").and_then(Value::as_str) == Some(APPLY_OP)
                && let Some(b) = m.get_mut("bindings").and_then(Value::as_object_mut)
            {
                for v in b.values_mut() {
                    if let Some(g) = v.as_str().and_then(|sv| rectmap.get(sv)) {
                        *v = Value::String(g.clone());
                    }
                }
            }
            for v in m.values_mut() {
                pd_rewrite_rects(v, rectmap);
            }
        }
        Value::Array(xs) => {
            for x in xs {
                pd_rewrite_rects(x, rectmap);
            }
        }
        _ => {}
    }
}

fn pd_ix(f: impl Into<Value>, idx: impl Into<Value>) -> Value {
    json!({"op": "index", "args": [f.into(), idx.into()]})
}

/// One dict-form `join.overlap` clause (CONFORMANCE_SPEC.md §5.5.6 wire form).
/// `eps` is always `0.0`: the rewrite derives the envelopes from an EXACT
/// rectangle-containment predicate that stays on as the narrow `filter`, so no
/// FP slack is wanted.
fn pd_overlap_clause(src_env: &[String], tgt_env: &[String]) -> Value {
    json!({
        "overlap": {
            "src_env": src_env.to_vec(),
            "tgt_env": tgt_env.to_vec(),
            "eps": 0.0,
        }
    })
}

/// Collect every factor name in `rectmap` that still appears in an
/// `index(F, …)` position — every occurrence [`pd_rewrite_rects`] targets but
/// did not reach.
fn pd_collect_stale_rects(
    node: &Value,
    rectmap: &HashMap<String, String>,
    out: &mut std::collections::BTreeSet<String>,
) {
    match node {
        Value::Object(m) => {
            if m.get("op").and_then(Value::as_str) == Some("index")
                && let Some(f) = m.get("args").and_then(Value::as_array).and_then(|a| a.first()).and_then(Value::as_str)
                && rectmap.contains_key(f)
            {
                out.insert(f.to_string());
            }
            for v in m.values() {
                pd_collect_stale_rects(v, rectmap, out);
            }
        }
        Value::Array(xs) => {
            for x in xs {
                pd_collect_stale_rects(x, rectmap, out);
            }
        }
        _ => {}
    }
}

/// POST-CONDITION of the forward arm's rect re-pointing, discharged on the
/// EXPANDED form of the rewritten aggregate (esm-spec §9.6.4 rule 2: what the
/// evaluator sees is `Expand(tree)`).
///
/// `E`'s reduction axis now ranges over the COMPACT derived support set, so
/// every rect reference in its body must have become the corresponding
/// `pd_cell__*` gather. The rewrite achieves that by editing the CALL SITE,
/// which is what keeps the shared template body untouched. A rect factor named
/// FREE inside a template body is therefore unreachable: rewriting it would mean
/// rewriting the shared body, corrupting every other call site (the generated
/// producer `filter` among them, which must keep full-grid references). Left
/// alone it would index a compact per-support gather with full-grid positions —
/// WRONG NUMBERS, silently. Hence a hard error, whose remedy is the one the
/// template machinery already prescribes: bind the value through the params.
fn pd_assert_rects_rebound(
    expr: &Value,
    ename: &str,
    rectmap: &HashMap<String, String>,
    templates: Option<&Map<String, Value>>,
) -> Result<(), PushdownRewriteError> {
    if rectmap.is_empty() {
        return Ok(());
    }
    let expanded = pd_expand_for_detection(expr, templates);
    let view = expanded.as_ref().unwrap_or(expr);
    let mut stale = std::collections::BTreeSet::new();
    pd_collect_stale_rects(view, rectmap, &mut stale);
    if stale.is_empty() {
        return Ok(());
    }
    let names: Vec<&str> = stale.iter().map(String::as_str).collect();
    Err(PushdownRewriteError(format!(
        "[template_body_references_pushdown_rewritten_variable] projection-pushdown desugar: the binning aggregate '{ename}' still reads '{}' after its reduction axis was re-pointed onto the generated derived support set. Those references live in an expression-template BODY, not in the call site's `bindings`, so the rewrite — which edits call sites only, to keep the template body shared and singly-lowered (esm-spec §9.6.4 Option B) — cannot re-point them, and they would index the compact per-support cell gathers with full-grid positions. Bind the value through the template's params, or write the binning body longhand.",
        names.join("', '")
    )))
}

/// Put a rewritten model's `equations` into the §5.5.7 canonical order:
///
/// 1. every equation whose LHS is **not** a bare variable — the derivative
///    equations and the generated `distinct` producer — each keeping its
///    relative input order;
/// 2. every **definition** (bare-variable LHS), sorted by the defined name,
///    lexicographically by UTF-8 code point.
///
/// This is NORMATIVE, not cosmetic, and it applies even though Rust's own
/// emission order is deterministic. The rewrite generates the member buffers
/// and the per-rect cell gathers while walking the model's variable collection,
/// which is a hash map in this binding and a `Dict` in the Julia reference —
/// so without canonicalizing, the emitted document varies with the hash seed
/// from run to run, and the `tests/conformance/pushdown/` goldens could not be
/// compared as ordered arrays at all. Appending in a fixed order would be
/// deterministic HERE while still disagreeing with the other bindings, which is
/// why the spec asks for the ordering rather than for stable iteration.
///
/// Sorting only the definitions is what keeps this safe for an authored
/// document: a definition is identified by the name it defines, so reordering
/// two of them cannot change the system (the evaluator dependency-orders
/// observeds itself), while a derivative equation's position among its peers is
/// left exactly as the author wrote it.
fn pd_canonicalize_equations(model: &mut Value) {
    let Some(eqs) = model.get_mut("equations").and_then(Value::as_array_mut) else {
        return;
    };
    // A stable partition, so group (1) keeps its relative input order.
    let (mut structural, mut definitions): (Vec<Value>, Vec<Value>) = std::mem::take(eqs)
        .into_iter()
        .partition(|eq| !eq.get("lhs").is_some_and(Value::is_string));
    definitions.sort_by(|a, b| {
        let key = |e: &Value| {
            e.get("lhs")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string()
        };
        key(a).cmp(&key(b))
    });
    structural.append(&mut definitions);
    *eqs = structural;
}

fn pd_apply(
    esm: &Value,
    mname: &str,
    plan: &Plan,
    templates: Option<&Map<String, Value>>,
) -> Result<Value, PushdownRewriteError> {
    let mut d = esm.clone(); // fresh, mutable (input purity)
    let c = &plan.c_set;
    let setname = format!("pd_support__{c}");
    let faqid = format!("pd_faq__{c}");
    let memvar = format!("pd_members__{c}");
    let mfactor = format!("pd_member_factor__{c}");
    let cellgath = |f: &str| format!("pd_cell__{c}__{f}");

    let mut rects: Vec<String> = Vec::new();
    for f in &plan.tgt_env {
        if !rects.contains(f) {
            rects.push(f.clone());
        }
    }
    let rectmap: HashMap<String, String> =
        rects.iter().map(|f| (f.clone(), cellgath(f))).collect();

    let root = d
        .as_object_mut()
        .ok_or_else(|| PushdownRewriteError("document is not an object".into()))?;

    // --- derived index set ---
    let index_sets = root
        .entry("index_sets")
        .or_insert_with(|| Value::Object(Map::new()));
    index_sets
        .as_object_mut()
        .ok_or_else(|| PushdownRewriteError("index_sets is not an object".into()))?
        .insert(
            setname.clone(),
            json!({
                "kind": "derived",
                "from_faq": faqid,
                "member_factor": mfactor,
            }),
        );

    let model = root
        .get_mut("models")
        .and_then(|m| m.get_mut(mname))
        .filter(|m| m.is_object())
        .ok_or_else(|| PushdownRewriteError(format!("model '{mname}' is not an object")))?;
    // --- producer filter comparisons, deep-copied from the representative E
    //     BEFORE E is rewritten (they must keep full-grid rect factor refs).
    //     Read off the DEFINING EQUATION: esm 1.0.0 has no variable
    //     `expression` field. ---
    let repexpr = pd_def(model, &plan.rep_ename)
        .cloned()
        .ok_or_else(|| {
            PushdownRewriteError("representative E lost its defining equation".into())
        })?;
    // When the call site hides the predicate behind a template reference, read it
    // off the EXPANDED body (§9.6.4 rule 2) — the producer wants the FULL-GRID
    // rect references, which is exactly what the pre-rewrite expansion yields.
    // The expansion is a scratch value: nothing of it is emitted except these
    // comparisons, so the document's template block and call sites are untouched.
    // A template-free document never builds one, so its emitted filter is
    // byte-identical to before.
    let rep_expanded = repexpr.get("expr").and_then(|e| pd_expand_for_detection(e, templates));
    let ifcond = repexpr
        .get("expr")
        .and_then(pd_find_ifelse_cond)
        .or_else(|| rep_expanded.as_ref().and_then(pd_find_ifelse_cond))
        .ok_or_else(|| {
            PushdownRewriteError(
                "pushdown desugar: representative E lost its containment ifelse".into(),
            )
        })?;
    let comps: Vec<Value> = if matches!(op_of(ifcond), Some("and") | Some("*")) {
        ifcond
            .get("args")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default()
    } else {
        vec![ifcond.clone()]
    };
    let prod_filter = json!({"op": "*", "args": comps});

    let mv = model
        .get_mut("variables")
        .and_then(Value::as_object_mut)
        .ok_or_else(|| PushdownRewriteError("model variables is not an object".into()))?;

    // --- member state var + member_factor param ---
    mv.insert(
        memvar.clone(),
        json!({"type": "unknown", "shape": [setname.clone()]}),
    );
    mv.insert(
        mfactor.clone(),
        json!({"type": "parameter", "default": 0.0, "shape": [setname.clone()]}),
    );

    // --- per-rect cell-gather observeds ---
    // The DECLARATION is a bare `unknown`; what makes it observed is the
    // bare-variable-LHS equation added below (esm-spec §6.3.1).
    let mut cellgath_defs: Vec<(String, Value)> = Vec::new();
    for f in &rects {
        mv.insert(
            cellgath(f),
            json!({
                "type": "unknown",
                "shape": [setname.clone()],
            }),
        );
        cellgath_defs.push((
            cellgath(f),
            json!({
                "op": "aggregate",
                "output_idx": ["c"],
                "ranges": {"c": {"from": setname.clone()}},
                "args": [f.clone(), mfactor.clone()],
                "expr": pd_ix(f.clone(), pd_ix(mfactor.clone(), "c")),
            }),
        ));
    }

    // The cell-gather DEFINITIONS, now that the `variables` borrow is done.
    for (name, rhs) in cellgath_defs {
        pd_set_def(model, &name, rhs);
    }
    let mv = model
        .get_mut("variables")
        .and_then(Value::as_object_mut)
        .ok_or_else(|| PushdownRewriteError("model variables is not an object".into()))?;

    // --- gate the provider-backed arrays onto the derived axis ---
    for a in &plan.a_names {
        if let Some(av) = mv.get_mut(a).and_then(Value::as_object_mut) {
            av.insert(
                "shape".to_string(),
                json!([setname.clone(), plan.rcv_set.clone()]),
            );
        }
    }

    // --- rewrite E: axis -> derived set, rect factors -> cell gathers, + GATE ---
    // The rewritten `E` still reduces over the FULL record axis, so without a
    // gate it visits |support|*|records| pairs -- 1520*43650 on isrm.esm.
    // Attach the SAME overlap clause the producer carries, re-pointed at the
    // generated cell gathers, and the enumeration driver (§5.5.6) walks one
    // candidate partner list per output cell instead. The clause is derived,
    // not authored: its envelopes are exactly the ones `pd_parse_containment`
    // read out of this aggregate's own containment predicate.
    for (ename, csym, e_src, e_tgt) in &plan.e_specs {
        let expr = pd_def_mut(model, ename).ok_or_else(|| {
            PushdownRewriteError(format!("E '{ename}' lost its defining equation"))
        })?;
        if let Some(from) = expr
            .get_mut("ranges")
            .and_then(|r| r.get_mut(csym))
            .and_then(Value::as_object_mut)
        {
            from.insert("from".to_string(), Value::String(setname.clone()));
        }
        pd_rewrite_rects(expr, &rectmap);
        if let Some(args) = expr.get_mut("args").and_then(Value::as_array_mut) {
            for s in args.iter_mut() {
                if let Some(name) = s.as_str()
                    && let Some(g) = rectmap.get(name)
                {
                    *s = Value::String(g.clone());
                }
            }
        }
        if expr.get("join").is_none()
            && let Some(eo) = expr.as_object_mut()
        {
            let gathered: Vec<String> =
                e_tgt.iter().map(|f| rectmap.get(f).cloned().unwrap_or_else(|| f.clone())).collect();
            eo.insert(
                "join".to_string(),
                Value::Array(vec![pd_overlap_clause(e_src, &gathered)]),
            );
        }
        let expr_snapshot = expr.clone();
        if let Some(evo) = model
            .get_mut("variables")
            .and_then(|v| v.get_mut(ename))
            .and_then(Value::as_object_mut)
        {
            evo.insert("shape".to_string(), json!([setname.clone()]));
        }
        pd_assert_rects_rebound(&expr_snapshot, ename, &rectmap, templates)?;
    }

    // --- MIRRORED orientation: gate only ---
    // A per-record binning aggregate `P[r] = SUM_{c in C} [contains(cell_c, pt_r)]*...`
    // is the same join read the other way round. It gets ONLY the gate -- no
    // derived index set, no `distinct` producer, no `member_factor`, no
    // provider gating -- because it wants the FULL record axis: every record
    // must produce a value, and a record outside the grid must come out as the
    // semiring identity (the driver leaves such a position with no term and the
    // identity fill emits 0). There is nothing to compact, so a mirrored
    // value-invention would derive a support set nobody reads. Its envelopes
    // stay the document's own const-array factors (the cell axis is not
    // re-pointed), so the mirror also needs no rect gathers.
    for (pname, p_src, p_tgt) in &plan.mirror_specs {
        let Some(pexpr) = pd_def_mut(model, pname) else {
            continue;
        };
        if pexpr.get("join").is_none()
            && let Some(po) = pexpr.as_object_mut()
        {
            po.insert(
                "join".to_string(),
                Value::Array(vec![pd_overlap_clause(p_src, p_tgt)]),
            );
        }
    }

    // --- restrict the conc reductions to the derived axis ---
    for (cname, ssym) in &plan.conc_specs {
        if let Some(from) = pd_def_mut(model, cname)
            .and_then(|e| e.get_mut("ranges"))
            .and_then(|r| r.get_mut(ssym))
            .and_then(Value::as_object_mut)
        {
            from.insert("from".to_string(), Value::String(setname.clone()));
        }
    }

    // --- generated `distinct` producer (reuses E's containment + geometry) ---
    let mut prod_args: Vec<String> = Vec::new();
    for s in plan.src_env.iter().chain(plan.tgt_env.iter()) {
        if !prod_args.contains(s) {
            prod_args.push(s.clone());
        }
    }
    let mut prod_ranges = Map::new();
    prod_ranges.insert(plan.rep_rsym.clone(), json!({"from": plan.r_set.clone()}));
    prod_ranges.insert(plan.rep_csym.clone(), json!({"from": c.clone()}));
    let producer = json!({
        "lhs": pd_ix(memvar.clone(), "m"),
        "rhs": {
            "op": "aggregate",
            "output_idx": ["m"],
            "ranges": prod_ranges,
            "expr": {"op": "true", "args": []},
            "distinct": true,
            "semiring": "bool_and_or",
            "id": faqid.clone(),
            "join": [pd_overlap_clause(&plan.src_env, &plan.tgt_env)],
            "filter": prod_filter,
            "key": {"op": "skolem", "label": "cell", "args": [plan.rep_csym.clone()]},
            "args": prod_args,
        },
    });
    let eqs = model
        .as_object_mut()
        .expect("model is an object")
        .entry("equations")
        .or_insert_with(|| Value::Array(Vec::new()));
    match eqs.as_array_mut() {
        Some(list) => list.push(producer),
        None => {
            *eqs = Value::Array(vec![producer]);
        }
    }

    // --- canonical equation order (CONFORMANCE_SPEC.md §5.5.7) ---------------
    pd_canonicalize_equations(model);

    // --- inspectable pushdown provenance / gated_select record ---
    let md = root
        .entry("metadata")
        .or_insert_with(|| Value::Object(Map::new()));
    let md = md
        .as_object_mut()
        .ok_or_else(|| PushdownRewriteError("metadata is not an object".into()))?;
    let xesd = md
        .entry("x_esd")
        .or_insert_with(|| Value::Object(Map::new()));
    xesd.as_object_mut()
        .ok_or_else(|| PushdownRewriteError("metadata.x_esd is not an object".into()))?
        .insert(
            "pushdown".to_string(),
            json!({
                "derived_set": setname,
                "producer_id": faqid,
                "member_factor": mfactor,
                "member_var": memvar,
                "gated_select": {
                    "gated_by": setname,
                    "applies_to": plan.a_names.clone(),
                    "gated_axis": 0,
                },
            }),
        );
    Ok(d)
}

/// Recognise the projection-pushdown pattern in `esm`'s named model and, when
/// it matches, return a NEW document (`Cow::Owned`) with the four constructs
/// desugared in (a `kind:"derived"` index set, a `distinct:true` overlap-gated
/// producer aggregate, a `member_factor` const parameter, and an inspectable
/// `gated_select` record) plus the reduction axis of the matched E / A / conc
/// nodes re-pointed onto the generated derived set. Returns the input
/// UNCHANGED (`Cow::Borrowed`) when no model is selected, the pattern does not
/// match, or the reduction's semiring is not the additive `(+, 0)` monoid
/// (the soundness guard).
///
/// IDEMPOTENT: a document already carrying the provenance record
/// `metadata.x_esd.pushdown` is returned unchanged — the generated constructs
/// would otherwise re-match and stack a second `pd_support__pd_support__…`
/// layer.
pub fn desugar_pushdown<'a>(
    esm: &'a Value,
    model_name: Option<&str>,
) -> Result<Cow<'a, Value>, PushdownRewriteError> {
    if !esm.is_object() || pushdown_record(esm).is_some() {
        return Ok(Cow::Borrowed(esm));
    }
    if esm.get("models").and_then(Value::as_object).is_none() {
        return Ok(Cow::Borrowed(esm));
    }
    let Some(mname) = pd_model_name(esm, model_name) else {
        return Ok(Cow::Borrowed(esm));
    };
    let Some(model) = esm.get("models").and_then(|m| m.get(&mname)) else {
        return Ok(Cow::Borrowed(esm));
    };
    if !model.is_object() {
        return Ok(Cow::Borrowed(esm));
    }
    let Some((plan, diags, templates)) = pd_analyze(model) else {
        return Ok(Cow::Borrowed(esm));
    };
    // RESIDUAL DIAGNOSTICS (CONFORMANCE_SPEC §5.5.7): a join-shaped aggregate the
    // recogniser could NOT read is reported here, not swallowed. See
    // `pd_binning_refusal` for the "not a join" / "a join I could not read"
    // split, and `pushdown_diagnostics` for the inspectable form.
    for d in &diags {
        eprintln!("warning: {}", pd_diagnostic_message(d));
    }
    let Some(plan) = plan else {
        return Ok(Cow::Borrowed(esm));
    };
    pd_apply(esm, &mname, &plan, templates.as_ref()).map(Cow::Owned)
}

/// The residual diagnostics [`desugar_pushdown`] would emit for `esm`.
///
/// One record per aggregate that IS join-shaped (it bins records into the cells
/// of an index set and feeds a provider-backed rank-2 array through a
/// `+`-semiring mat-vec) but whose containment predicate the recogniser could
/// not read, so the rewrite does not fire for it and that array is fetched
/// WHOLESALE.
///
/// Inspectable, side-effect-free counterpart of the warning stream: same
/// records, same order (sorted by `variable`/`consumer`/`array`), stable field
/// set (`code`, `variable`, `consumer`, `array`, `index_set`, `reason`,
/// `template`, `consequence`), pinned across bindings by the
/// `tests/conformance/pushdown/` corpus. Empty for a document that already
/// carries the rewrite record, for one with no model selected, and —
/// deliberately — for one that simply is NOT join-shaped: "no join here" is not
/// a defect.
pub fn pushdown_diagnostics(esm: &Value, model_name: Option<&str>) -> Vec<Value> {
    if !esm.is_object() || pushdown_record(esm).is_some() {
        return Vec::new();
    }
    let Some(mname) = pd_model_name(esm, model_name) else {
        return Vec::new();
    };
    let Some(model) = esm.get("models").and_then(|m| m.get(&mname)) else {
        return Vec::new();
    };
    pd_analyze(model).map(|(_, d, _)| d).unwrap_or_default()
}

/// The ONE detection entry point shared by [`desugar_pushdown`] (which then
/// emits) and [`pushdown_diagnostics`] (which only reports): run the matcher on
/// the EXPANDED view and hand back the plan (`None` ⇒ the pattern did not
/// match), the residual diagnostics, and the component template registry the
/// emission side needs.
#[allow(clippy::type_complexity)]
fn pd_analyze(model: &Value) -> Option<(Option<Plan>, Vec<Value>, Option<Map<String, Value>>)> {
    model.get("variables")?.as_object()?;
    let defs = pd_detection_defs(model);
    let (plan, diags) = pd_detect(model, &defs);
    Some((plan, diags, pd_templates(model).cloned()))
}

// --------------------------------------------------------------------------- //
// RECORD-DERIVED PROVIDER GATING (the Julia Phase-1 helpers, raw-JSON side).
// --------------------------------------------------------------------------- //

/// One native axis of a loader selection — the vocabulary shared by a data
/// loader's declared `select.axes` (esm-spec §8.9) and by the pushdown record's
/// gate template. JSON spellings, in the same order as the variants:
///
/// ```text
/// "all"                                    every index of the axis
/// {"fixed": 0}  /  {"fixed": [0]}          index 0, and the axis is DROPPED
/// {"range": {"start": 0, "stop": 52411}}   a strided prefix/window (step ≥ 1)
/// {"gated_by": "<derived index set>"}      the set's materialised members
/// ```
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GateAxis {
    /// Full native axis.
    All,
    /// Take native index `i` (0-based) and DROP the axis.
    Fixed(usize),
    /// The half-open strided range `[start, stop)` by `step`, as the new axis.
    /// Length `ceil((stop - start) / step)`; the axis is kept.
    Range {
        /// Inclusive first index (0-based).
        start: usize,
        /// Exclusive last index.
        stop: usize,
        /// Stride (>= 1).
        step: usize,
    },
    /// The named derived set's materialised members, in the set's canonical
    /// (sorted) member order, as the new compact axis.
    GatedBy(String),
}

/// Parse one JSON axis selector of the [`GateAxis`] vocabulary.
///
/// `ctx` names the declaring site for the error message. `gated_by_override`,
/// when given, replaces the declared set name — the pushdown path substitutes
/// its GENERATED set name into a loader's authored `{"gated_by": …}` slot.
pub fn parse_select_axis(
    ctx: &str,
    ax: &Value,
    gated_by_override: Option<&str>,
) -> Result<GateAxis, PushdownRewriteError> {
    let bad = |detail: String| PushdownRewriteError(format!("{ctx}: {detail}"));
    if ax.as_str() == Some("all") || ax.is_null() {
        return Ok(GateAxis::All);
    }
    let Some(m) = ax.as_object() else {
        return Err(bad(format!(
            "unrecognised axis selector {ax}; expected \"all\", {{\"fixed\": i}}, \
             {{\"range\": {{\"start\": s, \"stop\": e}}}} or {{\"gated_by\": \"<set>\"}}"
        )));
    };
    if let Some(g) = m.get("gated_by") {
        let name = match gated_by_override {
            Some(o) => o.to_string(),
            None => g
                .as_str()
                .ok_or_else(|| bad("\"gated_by\" must name a derived index set".into()))?
                .to_string(),
        };
        return Ok(GateAxis::GatedBy(name));
    }
    if let Some(fx) = m.get("fixed") {
        let fi = match fx {
            Value::Array(a) => a.first().and_then(Value::as_u64),
            other => other.as_u64(),
        }
        .ok_or_else(|| bad("\"fixed\" must be a non-negative integer index".into()))?;
        return Ok(GateAxis::Fixed(fi as usize));
    }
    if let Some(r) = m.get("range") {
        let obj = r
            .as_object()
            .ok_or_else(|| bad("\"range\" must be an object {start, stop, step?}".into()))?;
        let start = obj.get("start").and_then(Value::as_u64).unwrap_or(0) as usize;
        let stop = obj
            .get("stop")
            .and_then(Value::as_u64)
            .ok_or_else(|| bad("\"range\" needs an integer \"stop\"".into()))?
            as usize;
        let step = obj.get("step").and_then(Value::as_u64).unwrap_or(1) as usize;
        if step == 0 {
            return Err(bad("\"range.step\" must be >= 1".into()));
        }
        if stop < start {
            return Err(bad(format!(
                "\"range\" is empty: stop {stop} precedes start {start}"
            )));
        }
        return Ok(GateAxis::Range { start, stop, step });
    }
    let mut keys: Vec<&str> = m.keys().map(String::as_str).collect();
    keys.sort_unstable();
    Err(bad(format!(
        "unrecognised axis selector keys {keys:?}; expected one of fixed, range, gated_by"
    )))
}

/// Parse a whole `axes` array of the [`GateAxis`] vocabulary (see
/// [`parse_select_axis`]).
pub fn parse_select_axes(
    ctx: &str,
    axes: &[Value],
    gated_by_override: Option<&str>,
) -> Result<Vec<GateAxis>, PushdownRewriteError> {
    axes.iter()
        .map(|ax| parse_select_axis(ctx, ax, gated_by_override))
        .collect()
}

/// A provider-key ⇒ engine gate: per-NATIVE-axis selection plus the LOADER
/// variable tails the gate applies to.
#[derive(Debug, Clone)]
pub struct ProviderGate {
    pub axes: Vec<GateAxis>,
    pub applies_to: Vec<String>,
}

/// The `(provider key, model variable)` pairs of a raw document: which external
/// field feeds which declared array.
///
/// The provider key is `"<source>.<file_variable>"`, which is how a runner
/// registers a provider and how [`pushdown_provider_gates`] finds the one to
/// gate.
///
/// esm 1.0.0 moved where this is written. It used to be a `variable_map`
/// coupling edge from a loader COMPONENT to a model parameter; a data source is
/// no longer a component, so the binding is the consuming parameter's own
/// `update: {kind: "data", source, from: {file_variable}}` (esm-spec §5.4,
/// §8.5). Both spellings are read, because a document may still carry the
/// coupling form for a NON-source producer — the pair is "what feeds what", and
/// only the writing side changed.
pub fn pushdown_coupling_pairs(doc: &Value) -> Vec<(String, String)> {
    let mut out = Vec::new();

    // (1) A parameter bound to a data source by its own `update` (1.0.0).
    if let Some(models) = doc.get("models").and_then(Value::as_object) {
        let mut mnames: Vec<&String> = models.keys().collect();
        mnames.sort();
        for mname in mnames {
            let Some(vars) = models[mname].get("variables").and_then(Value::as_object) else {
                continue;
            };
            let mut vnames: Vec<&String> = vars.keys().collect();
            vnames.sort();
            for vname in vnames {
                let Ok(var) =
                    serde_json::from_value::<crate::types::ModelVariable>(vars[vname].clone())
                else {
                    continue;
                };
                for rule in var.update.iter().flat_map(|spec| spec.rules()) {
                    let (Some(source), Some(binding)) =
                        (rule.data_source(), rule.value().and_then(|v| v.from.as_ref()))
                    else {
                        continue;
                    };
                    out.push((
                        format!("{source}.{}", binding.file_variable),
                        format!("{mname}.{vname}"),
                    ));
                }
            }
        }
    }

    // (2) A `variable_map` coupling edge (the 0.x spelling, still admissible
    //     between two ordinary components).
    if let Some(cp) = doc.get("coupling").and_then(Value::as_array) {
        for c in cp {
            if c.get("type").and_then(Value::as_str) != Some("variable_map") {
                continue;
            }
            let frm = c.get("from").and_then(Value::as_str).unwrap_or("");
            let to = c.get("to").and_then(Value::as_str).unwrap_or("");
            if !frm.is_empty() && !to.is_empty() {
                out.push((frm.to_string(), to.to_string()));
            }
        }
    }
    out
}

/// Rank of the (rewritten) gated model arrays — the fallback native rank when
/// a loader declares no axes template (2 for the ISRM shape; read from the
/// document rather than hard-coded).
fn pushdown_gated_rank(doc: &Value, applies: &[String]) -> usize {
    if let Some(models) = doc.get("models").and_then(Value::as_object) {
        for m in models.values() {
            let Some(mv) = m.get("variables").and_then(Value::as_object) else {
                continue;
            };
            for a in applies {
                if let Some(shp) = mv.get(a).and_then(|v| v.get("shape")).and_then(Value::as_array)
                    && !shp.is_empty()
                {
                    return shp.len();
                }
            }
        }
    }
    2
}

/// Per-NATIVE-axis gate `axes` for `loader`: the loader's declared
/// `metadata.x_esd.gated_select.axes` template with the GENERATED set name
/// substituted into its `gated_by` slot (validated against the record's
/// `gated_axis`); else a rank-`mrank` all-axes gate with `gated_by` at
/// `gaxis`.
fn pushdown_gate_axes(
    doc: &Value,
    loader: &str,
    gset: &str,
    gaxis: i64,
    mrank: usize,
) -> Result<Vec<GateAxis>, PushdownRewriteError> {
    let tpl = doc
        .get("data_sources")
        .and_then(|d| d.get(loader))
        .and_then(|l| l.get("metadata"))
        .and_then(|m| m.get("x_esd"))
        .and_then(|x| x.get("gated_select"))
        .and_then(|g| g.get("axes"))
        .and_then(Value::as_array);
    if let Some(tpl) = tpl {
        let axes = parse_select_axes(
            &format!("data_sources.{loader} gated_select template"),
            tpl,
            Some(gset),
        )?;
        // The gated axis's position among the axes the fetch KEEPS (a `fixed`
        // axis is dropped, so it does not shift the model's axis numbering).
        let mut nonfixed: i64 = 0;
        let mut gpos: i64 = -1;
        for ax in &axes {
            match ax {
                GateAxis::Fixed(_) => {}
                GateAxis::GatedBy(_) => {
                    gpos = nonfixed;
                    nonfixed += 1;
                }
                _ => nonfixed += 1,
            }
        }
        if gpos != gaxis {
            return Err(PushdownRewriteError(format!(
                "data_sources.{loader} gated_select template puts the gated axis at \
                 non-fixed position {gpos}, but the rewrite record gates model axis \
                 {gaxis} — the loader template and the rewritten arrays disagree"
            )));
        }
        return Ok(axes);
    }
    if gaxis < 0 || gaxis as usize >= mrank {
        return Err(PushdownRewriteError(format!(
            "rewrite record gated_axis {gaxis} out of range for rank-{mrank} gated arrays"
        )));
    }
    let mut axes = vec![GateAxis::All; mrank];
    axes[gaxis as usize] = GateAxis::GatedBy(gset.to_string());
    Ok(axes)
}

/// Provider-key ⇒ engine gate, derived from `doc`'s rewrite record
/// (`metadata.x_esd.pushdown.gated_select`).
///
/// A provider is GATED when its key names a `data_sources` variable
/// (`"<Loader>"` or `"<Loader>.<var>"`) that a coupling `variable_map` routes
/// onto one of the record's `applies_to` model arrays. The gate's per-NATIVE-
/// axis `axes` come from the loader's own `metadata.x_esd.gated_select.axes`
/// template when it declares one (with the record's GENERATED set name
/// substituted), else from the model array's rank with `gated_by` at the
/// record's `gated_axis`. `applies_to` carries the LOADER-variable tails.
/// Empty when `doc` carries no record or no coupling routes a provider onto a
/// gated array.
pub fn pushdown_provider_gates(
    doc: &Value,
    provider_keys: &[String],
) -> Result<HashMap<String, ProviderGate>, PushdownRewriteError> {
    let mut gates = HashMap::new();
    let Some(rec) = pushdown_record(doc) else {
        return Ok(gates);
    };
    let Some(gs) = rec.get("gated_select").and_then(Value::as_object) else {
        return Ok(gates);
    };
    let applies: Vec<String> = gs
        .get("applies_to")
        .and_then(Value::as_array)
        .map(|a| a.iter().map(value_to_display_string).collect())
        .unwrap_or_default();
    let gset = gs
        .get("gated_by")
        .map(value_to_display_string)
        .unwrap_or_default();
    let gaxis = gs.get("gated_axis").and_then(Value::as_i64).unwrap_or(0);
    if applies.is_empty() || gset.is_empty() {
        return Ok(gates);
    }

    // coupling: "<Loader>.<var>" => the gated model array's LOCAL (tail) name.
    let mut fed: Vec<(String, String)> = Vec::new();
    for (frm, to) in pushdown_coupling_pairs(doc) {
        if !frm.contains('.') {
            continue;
        }
        let tail = to.rsplit('.').next().unwrap_or(&to);
        if applies.iter().any(|a| a == tail) {
            fed.push((frm, to));
        }
    }
    if fed.is_empty() {
        return Ok(gates);
    }

    let mrank = pushdown_gated_rank(doc, &applies);
    for k in provider_keys {
        let (loader, lvars) = if fed.iter().any(|(f, _)| f == k) {
            let (loader, tail) = k
                .split_once('.')
                .expect("fed keys always carry a '.' separator");
            (loader.to_string(), vec![tail.to_string()])
        } else {
            let mut lvars: Vec<String> = fed
                .iter()
                .filter_map(|(f, _)| {
                    let (l, tail) = f.split_once('.')?;
                    (l == k).then(|| tail.to_string())
                })
                .collect();
            if lvars.is_empty() {
                continue;
            }
            lvars.sort();
            (k.clone(), lvars)
        };
        let axes = pushdown_gate_axes(doc, &loader, &gset, gaxis, mrank)?;
        gates.insert(
            k.clone(),
            ProviderGate {
                axes,
                applies_to: lvars,
            },
        );
    }
    Ok(gates)
}
