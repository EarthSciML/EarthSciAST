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
fn pd_detect_binning(ev: &Value, out_set: &str) -> Option<Binning> {
    if ev.get("type")?.as_str()? != "observed" {
        return None;
    }
    let shape = ev.get("shape")?.as_array()?;
    if shape.len() != 1 || shape[0].as_str()? != out_set {
        return None;
    }
    let agg = ev.get("expression")?;
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
    variables: &Map<String, Value>,
    c_set: &str,
    r_set: &str,
    forward_names: &[String],
) -> Vec<(String, [String; 2], [String; 4])> {
    let mut out: Vec<(String, [String; 2], [String; 4])> = Vec::new();
    for (name, v) in variables {
        if forward_names.iter().any(|f| f == name) {
            continue;
        }
        let Some(bind) = pd_detect_binning(v, r_set) else {
            continue;
        };
        if bind.out_is_cell || bind.c_set != c_set || bind.r_set != r_set {
            continue;
        }
        // Never stack a second gate on an aggregate that already declares a join.
        if v.get("expression").and_then(|e| e.get("join")).is_some() {
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

/// Detect the pushdown pattern across a model's observeds. Returns the plan,
/// or `None` when nothing matches / the semiring guard fails.
fn pd_detect(model: &Value) -> Option<Plan> {
    let variables = model.get("variables")?.as_object()?;
    let mut conc_specs: Vec<(String, String)> = Vec::new();
    let mut a_names: Vec<String> = Vec::new();
    let mut e_specs: Vec<(String, String, [String; 2], [String; 4])> = Vec::new();
    let mut plan: Option<Plan> = None;

    for (cname, cv) in variables {
        if cv.get("type").and_then(Value::as_str) != Some("observed") {
            continue;
        }
        let Some(agg) = cv.get("expression") else {
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
        let Some(bind) = pd_detect_binning(ev, c_set) else {
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
    let mut plan = plan?;
    if conc_specs.is_empty() {
        return None;
    }
    // Deterministic plan order (mirrors the Julia `sort!(A_names)`).
    a_names.sort();
    // MIRRORED-orientation binning aggregates (`P[r] = Σ_c […]`) over the SAME
    // cell/record sets. They are collected only once the forward pattern has
    // fixed `c_set`/`r_set`: the mirror is a RIDER on the rewrite, never its
    // trigger, so a document holding only mirrored binning aggregates is not
    // rewritten at all (§5.5.7).
    let forward_names: Vec<String> = e_specs.iter().map(|(e, ..)| e.clone()).collect();
    plan.mirror_specs = pd_mirror_specs(variables, &plan.c_set, &plan.r_set, &forward_names);
    plan.conc_specs = conc_specs;
    plan.a_names = a_names;
    plan.e_specs = e_specs;
    Some(plan)
}

// --------------------------------------------------------------------------- //
// Emission
// --------------------------------------------------------------------------- //

/// In-place: rewrite every `index(F, …)` whose factor `F` is a key of
/// `rectmap` to `index(rectmap[F], …)` throughout a raw AST subtree.
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

fn pd_apply(esm: &Value, mname: &str, plan: &Plan) -> Result<Value, PushdownRewriteError> {
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
        .and_then(Value::as_object_mut)
        .ok_or_else(|| PushdownRewriteError(format!("model '{mname}' is not an object")))?;
    let mv = model
        .get_mut("variables")
        .and_then(Value::as_object_mut)
        .ok_or_else(|| PushdownRewriteError("model variables is not an object".into()))?;

    // --- producer filter comparisons, deep-copied from the representative E
    //     BEFORE E is rewritten (they must keep full-grid rect factor refs) ---
    let repexpr = mv
        .get(&plan.rep_ename)
        .and_then(|v| v.get("expression"))
        .ok_or_else(|| PushdownRewriteError("representative E lost its expression".into()))?;
    let ifcond = repexpr
        .get("expr")
        .and_then(pd_find_ifelse_cond)
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

    // --- member state var + member_factor param ---
    mv.insert(
        memvar.clone(),
        json!({"type": "state", "shape": [setname.clone()]}),
    );
    mv.insert(
        mfactor.clone(),
        json!({"type": "parameter", "default": 0.0, "shape": [setname.clone()]}),
    );

    // --- per-rect cell-gather observeds ---
    for f in &rects {
        mv.insert(
            cellgath(f),
            json!({
                "type": "observed",
                "shape": [setname.clone()],
                "expression": {
                    "op": "aggregate",
                    "output_idx": ["c"],
                    "ranges": {"c": {"from": setname.clone()}},
                    "args": [f.clone(), mfactor.clone()],
                    "expr": pd_ix(f.clone(), pd_ix(mfactor.clone(), "c")),
                },
            }),
        );
    }

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
        let expr = mv
            .get_mut(ename)
            .and_then(|v| v.get_mut("expression"))
            .ok_or_else(|| PushdownRewriteError(format!("E '{ename}' lost its expression")))?;
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
        if let Some(evo) = mv.get_mut(ename).and_then(Value::as_object_mut) {
            evo.insert("shape".to_string(), json!([setname.clone()]));
        }
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
        let Some(pexpr) = mv.get_mut(pname).and_then(|v| v.get_mut("expression")) else {
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
        if let Some(from) = mv
            .get_mut(cname)
            .and_then(|v| v.get_mut("expression"))
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
        .entry("equations")
        .or_insert_with(|| Value::Array(Vec::new()));
    match eqs.as_array_mut() {
        Some(list) => list.push(producer),
        None => {
            *eqs = Value::Array(vec![producer]);
        }
    }

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
    let Some(plan) = pd_detect(model) else {
        return Ok(Cow::Borrowed(esm));
    };
    pd_apply(esm, &mname, &plan).map(Cow::Owned)
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

/// The coupling `variable_map` (from, to) pairs of a raw document.
pub fn pushdown_coupling_pairs(doc: &Value) -> Vec<(String, String)> {
    let mut out = Vec::new();
    let Some(cp) = doc.get("coupling").and_then(Value::as_array) else {
        return out;
    };
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
        .get("data_loaders")
        .and_then(|d| d.get(loader))
        .and_then(|l| l.get("metadata"))
        .and_then(|m| m.get("x_esd"))
        .and_then(|x| x.get("gated_select"))
        .and_then(|g| g.get("axes"))
        .and_then(Value::as_array);
    if let Some(tpl) = tpl {
        let axes = parse_select_axes(
            &format!("data_loaders.{loader} gated_select template"),
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
                "data_loaders.{loader} gated_select template puts the gated axis at \
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
/// A provider is GATED when its key names a `data_loaders` variable
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
