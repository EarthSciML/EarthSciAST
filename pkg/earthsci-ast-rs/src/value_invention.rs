//! Build-time value-invention front-door (Rust binding).
//!
//! **Value invention**, in plain language: some aggregates do not reduce
//! data to numbers — they *mint new entities* from it (unique edge IDs from a
//! mesh, dense ranks from a categorical column, bin keys from coordinates).
//! This pass materialises those invented values once at setup, so the dense
//! array runtime never has to run the relational machinery per step.
//!
//! Port of the Julia reference `value_invention.jl` (bead ess-3lj.1 → ess-3lj.2);
//! RFC `semiring-faq-unified-ir` §6.1 (cadence-partition) / §5.5 (determinism) /
//! §7.3 (edge enumeration); `CONFORMANCE_SPEC.md` §5.5 / §5.7.
//!
//! A `kind:"derived"` index set whose `from_faq` names a value-invention
//! aggregate (an `aggregate` with `distinct:true`, or whose body / `key` is
//! `skolem` / `rank`) is materialised here, ONCE at setup, off the per-step hot
//! path — the §6.1 CONST/DISCRETE materialisation point. The aggregate's keys
//! are evaluated over the build-time const-array factors and run through the
//! [`crate::relational`] engine (skolem / distinct, §5.5 determinism); the
//! distinct set's cardinality is handed to the index-set resolver as the dense
//! extent `[1, n]`. Concretely, [`apply_value_invention`] rewrites the typed
//! model's `kind:"derived"` set into `kind:"interval"` with `size = n`, so
//! [`crate::aggregate::resolve_aggregate_ranges`] resolves it via the existing
//! interval arm (a derived **output** index — e.g. the `rank` dense-id buffer —
//! is otherwise rejected, since a data-dependent extent cannot size an output
//! array). The value-invention outputs are dropped from the ODE.
//!
//! The pass runs on the **raw `serde_json::Value`** model document, not the
//! typed `Model`: the typed `ExpressionNode` drops the aggregate `key` /
//! `distinct` fields (mirroring [`crate::cadence`], which walks raw JSON for the
//! same reason). The materialised members are **byte-identical** across the
//! Julia / Rust / Python bindings (the M3 determinism goldens) because every
//! emitted key is the canonical Skolem tuple in §5.5.1 sorted total order.

use std::collections::{HashMap, HashSet};

use ndarray::{ArrayD, IxDyn};
use serde_json::{Map, Value};

use crate::aggregate::{ReduceKind, effective_reduce_kind};
use crate::cadence::{self, Cadence};
use crate::relational::{self, Key, Num, SemiringOp, group_aggregate};
use crate::types::{Expr, IndexSet, Model};

/// A value-invention build-time materialisation error (the Rust analog of
/// Julia's `TreeWalkError` value-invention codes).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ValueInventionError(pub String);

impl std::fmt::Display for ValueInventionError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "ValueInventionError: {}", self.0)
    }
}

impl std::error::Error for ValueInventionError {}

fn err<T>(msg: impl Into<String>) -> Result<T, ValueInventionError> {
    Err(ValueInventionError(msg.into()))
}

/// The relational body ops that mark a value-invention output (excluded from the
/// ODE): mirrors Julia `_VI_BODY_OPS`.
const VI_BODY_OPS: [&str; 3] = ["skolem", "rank", "distinct"];

/// Arg-witness reducer ops (RFC §5.7 rule 6): a build-time reduction over a
/// contracted candidate range that emits the ARG — the witnessing index — rather
/// than the reduced value (the nearest-generator INDEX). NET-NEW: the closed
/// semiring registry returns values and value-invention (distinct/skolem/rank)
/// returns sets; neither returns the arg. Materialised as an integer per-element
/// buffer at CONST cadence, like the `:map` skolem bin buffers. Mirrors Julia
/// `_VI_ARGWITNESS_OPS`.
const VI_ARGWITNESS_OPS: [&str; 2] = ["argmin", "argmax"];

/// True iff a value-invention `:map` node's body is an arg-witness reducer
/// (`argmin` / `argmax`) — i.e. it emits the witnessing INDEX rather than a
/// value. Checks the raw `expr.op` against [`VI_ARGWITNESS_OPS`].
fn is_argwitness(node: &Value) -> bool {
    node.get("expr")
        .and_then(|b| b.get("op"))
        .and_then(|v| v.as_str())
        .map(|o| VI_ARGWITNESS_OPS.contains(&o))
        .unwrap_or(false)
}

/// Per-dimension boundary policy for an out-of-range const-array stencil gather
/// (bead ess-gj4). Mirrors the Julia `_CONST_BOUNDARY_KINDS` (`:periodic` /
/// `:clamp` / `:error`): a gather at a 1-based index outside `1..=n` resolves
/// declaratively per the dimension's policy instead of panicking.
///
/// - [`BoundaryKind::Periodic`] — wrap into `1..=n` via 1-based mod (`mod1`);
///   correct for a periodic axis (a lon-periodic metric factor).
/// - [`BoundaryKind::Clamp`] — edge-extend (clamp to `1..=n`); the correct finite
///   policy for a metric / geometry factor at a non-periodic boundary (NOT a
///   zero-ghost, which is physically wrong for a metric).
/// - [`BoundaryKind::Error`] — return a structured [`ValueInventionError`] (also
///   the default for any dimension WITHOUT a declared policy), so genuine
///   out-of-bounds bugs in connectivity / stencil-weight factors stay caught.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BoundaryKind {
    Periodic,
    Clamp,
    Error,
}

/// Result of [`materialize_value_invention`].
///
/// - `extents` — `from_faq` producer id → derived index-set cardinality (the
///   dense extent `[1, n]` the resolver consumes).
/// - `members` — `from_faq` producer id → the distinct member keys in §5.5.1
///   sorted order (for byte-identity assertions).
/// - `assignments` — arg-witness map var → the integer nearest-generator INDEX
///   buffer, dense in output-index order (the SCVT assignment; §5.7 rule 6,
///   byte-identical across bindings).
/// - `groups` — the downstream GROUPED / DERIVED buffers keyed on an arg-witness
///   assignment, dense in output-index order: a grouped semiring reduction
///   (`num[g] = Σ_{p:assign=g} rho_p·x_p`, run through [`group_aggregate`], §5.5
///   rule 5) and an elementwise derived buffer (`centroid[g] = num[g]/den[g]`) —
///   the SCVT centroid-update step.
/// - `vi_var_names` — value-invention LHS vars to drop from the ODE.
#[derive(Debug, Clone, Default)]
pub struct ValueInventionResult {
    pub extents: HashMap<String, i64>,
    pub members: HashMap<String, Vec<Key>>,
    pub assignments: HashMap<String, Vec<i64>>,
    pub groups: HashMap<String, Vec<f64>>,
    pub vi_var_names: HashSet<String>,
}

// --------------------------------------------------------------------------- //
// Intermediate build-time value
// --------------------------------------------------------------------------- //

/// A build-time value produced by [`vi_eval`]: an int / float / bool / relation
/// tag / canonical Skolem key, depending on the op.
#[derive(Debug, Clone, PartialEq)]
enum Val {
    Bool(bool),
    Int(i64),
    Float(f64),
    Str(String),
    Key(Key),
}

impl Val {
    fn as_f64(&self) -> Result<f64, ValueInventionError> {
        match self {
            Val::Int(i) => Ok(*i as f64),
            Val::Float(f) => Ok(*f),
            Val::Bool(b) => Ok(if *b { 1.0 } else { 0.0 }),
            other => err(format!("value {other:?} is not numeric")),
        }
    }

    /// Coerce to an exact integer relational key component (§5.5.1 rule 1: no
    /// floats in keys). A non-integral float is a misuse — fail loudly.
    fn key_int(&self) -> Result<i64, ValueInventionError> {
        match self {
            Val::Int(i) => Ok(*i),
            Val::Bool(b) => Ok(*b as i64),
            Val::Float(f) => {
                if f.fract() == 0.0 && f.is_finite() {
                    Ok(*f as i64)
                } else {
                    err(format!(
                        "value-invention key component {f} is not integer-valued; relational \
                         keys must be integer / categorical IDs (CONFORMANCE_SPEC.md §5.5.1 rule 1)"
                    ))
                }
            }
            other => err(format!("non-numeric key component {other:?}")),
        }
    }
}

// --------------------------------------------------------------------------- //
// Raw-node accessors
// --------------------------------------------------------------------------- //

fn obj(v: &Value) -> Option<&Map<String, Value>> {
    v.as_object()
}

fn node_op(node: &Value) -> Option<&str> {
    node.get("op").and_then(|v| v.as_str())
}

fn node_args(node: &Value) -> &[Value] {
    node.get("args")
        .and_then(|v| v.as_array())
        .map(|a| a.as_slice())
        .unwrap_or(&[])
}

// --------------------------------------------------------------------------- //
// Detection — classify raw aggregate nodes (mirror of _vi_node_kind / _vi_detect)
// --------------------------------------------------------------------------- //

#[derive(Debug, Clone, Copy, PartialEq)]
enum NodeKind {
    Producer,
    Map,
    Exclude,
    None,
}

fn vi_node_kind(node: &Value) -> NodeKind {
    let Some(map) = obj(node) else {
        return NodeKind::None;
    };
    if map.get("op").and_then(|v| v.as_str()) != Some("aggregate") {
        return NodeKind::None;
    }
    if map.get("distinct").and_then(|v| v.as_bool()) == Some(true) {
        return NodeKind::Producer;
    }
    if let Some(bop) = map
        .get("expr")
        .and_then(|b| b.get("op"))
        .and_then(|v| v.as_str())
    {
        if bop == "skolem" || VI_ARGWITNESS_OPS.contains(&bop) {
            return NodeKind::Map;
        }
        if VI_BODY_OPS.contains(&bop) {
            return NodeKind::Exclude;
        }
    }
    if map
        .get("key")
        .and_then(|k| k.get("op"))
        .and_then(|v| v.as_str())
        == Some("skolem")
    {
        return NodeKind::Map;
    }
    NodeKind::None
}

/// Base variable name written by a raw LHS node: `name`,
/// `{op:index,args:[name,…]}` or `{op:D,args:[name,…]}`. `None` if unrecognised.
fn lhs_base_raw(lhs: &Value) -> Option<String> {
    if let Some(s) = lhs.as_str() {
        return Some(s.to_string());
    }
    let op = node_op(lhs)?;
    if op == "index" || op == "D" {
        return node_args(lhs).first().and_then(lhs_base_raw);
    }
    None
}

/// Base variable name of a typed LHS `Expr` (`Variable` / `index` / `D`), used to
/// drop value-invention equations from the ODE.
fn lhs_base_typed(expr: &Expr) -> Option<String> {
    match expr {
        Expr::Variable(name) => Some(name.clone()),
        Expr::Operator(node) if node.op == "index" || node.op == "D" => {
            node.args.first().and_then(lhs_base_typed)
        }
        _ => None,
    }
}

/// A downstream build-time buffer keyed on / derived from an arg-witness
/// assignment — the SCVT centroid step (mirror of Julia's `chain` kinds).
#[derive(Debug, Clone, Copy, PartialEq)]
enum ChainKind {
    /// A grouped semiring reduction keyed on a VI buffer (`num[g]`/`den[g]`).
    Grouped,
    /// An elementwise buffer over upstream VI buffers (`centroid[g]`).
    Derived,
}

struct Detection {
    has_vi: bool,
    vi_var_names: HashSet<String>,
    maps: Vec<(String, Value)>,
    producers: Vec<(String, Value)>,
    /// Plain numeric aggregates — grouped/derived candidates resolved by fixpoint.
    candidates: Vec<(String, Value)>,
    /// The grouped/derived chain in materialisation (fixpoint discovery) order.
    chain: Vec<(String, Value, ChainKind)>,
}

/// Every `index` target name (the array a value reads from) reachable in a
/// subtree: `{op:"index", args:[NAME, …]}` → NAME.
fn vi_index_targets(node: &Value, out: &mut HashSet<String>) {
    match node {
        Value::Object(map) => {
            if node_op(node) == Some("index")
                && let Some(name) = node_args(node).first().and_then(|v| v.as_str())
            {
                out.insert(name.to_string());
            }
            for v in map.values() {
                vi_index_targets(v, out);
            }
        }
        Value::Array(items) => {
            for v in items {
                vi_index_targets(v, out);
            }
        }
        _ => {}
    }
}

/// Scan a `join` array's `on` pairs for the pair that binds `gsym` to a partner
/// name accepted by `is_known`, returning that partner (the non-`gsym` element of
/// the pair). Shared by [`vi_grouped_key`] (partner ∈ VI var names) and
/// [`vi_materialize_grouped`] (partner ∈ materialised buffers). Returns the FIRST
/// such partner in join / pair order.
fn vi_join_partner(
    join: &[Value],
    gsym: &str,
    mut is_known: impl FnMut(&str) -> bool,
) -> Option<String> {
    for clause in join {
        let Some(pairs) = clause.get("on").and_then(|v| v.as_array()) else {
            continue;
        };
        for pair in pairs {
            let Some(p) = pair.as_array() else { continue };
            if p.len() != 2 {
                continue;
            }
            let (Some(a), Some(b)) = (p[0].as_str(), p[1].as_str()) else {
                continue;
            };
            if a == gsym && is_known(b) {
                return Some(b.to_string());
            }
            if b == gsym && is_known(a) {
                return Some(a.to_string());
            }
        }
    }
    None
}

/// The group KEY of a GROUPED reduction, or `None`. The SCVT group-by signature
/// is precise (mirror of Julia `_vi_grouped_key`): a single-output-index
/// `aggregate` whose `join.on` pairs the OUTPUT index symbol with a known VI
/// buffer. Deliberately narrower than "any join touching a VI buffer" so a
/// bin-to-bin gather (the conservative regridder's `A_j`) is left on the
/// simulate path.
fn vi_grouped_key(node: &Value, vi_var_names: &HashSet<String>) -> Option<String> {
    if node_op(node) != Some("aggregate") {
        return None;
    }
    let oi = node.get("output_idx").and_then(|v| v.as_array())?;
    if oi.len() != 1 {
        return None;
    }
    let gsym = oi[0].as_str()?;
    let join = node.get("join").and_then(|v| v.as_array())?;
    vi_join_partner(join, gsym, |n| vi_var_names.contains(n))
}

/// True iff `node` is an elementwise DERIVED buffer over known VI buffers
/// (mirror of Julia `_vi_is_derived`): a single-output-index `aggregate` with NO
/// join and NO contraction whose body reads an upstream VI buffer.
fn vi_is_derived(node: &Value, vi_var_names: &HashSet<String>) -> bool {
    if node_op(node) != Some("aggregate") {
        return false;
    }
    let Some(oi) = node.get("output_idx").and_then(|v| v.as_array()) else {
        return false;
    };
    if oi.len() != 1 {
        return false;
    }
    let Some(gsym) = oi[0].as_str() else {
        return false;
    };
    if node.get("join").map(|v| !v.is_null()).unwrap_or(false) {
        return false;
    }
    if let Some(ranges) = node.get("ranges").and_then(|v| v.as_object())
        && !ranges.keys().all(|k| k == gsym)
    {
        return false;
    }
    let mut refs = HashSet::new();
    if let Some(expr) = node.get("expr") {
        vi_index_targets(expr, &mut refs);
    }
    refs.iter().any(|r| vi_var_names.contains(r))
}

/// Scan a raw model for value-invention assignments: the equation list (LHS base
/// resolved from the node) plus the `expression` of each observed variable (the
/// base is the variable name). `vi_var_names` is the set of LHS variables
/// produced by skolem/distinct/rank/argmin (and the downstream grouped chain),
/// all excluded from the ODE as the geometry clip-ring vars are; `maps` /
/// `producers` are `(base, node)` pairs; `chain` is the grouped/derived buffers.
fn vi_detect(model_json: &Value) -> Detection {
    let mut det = Detection {
        has_vi: false,
        vi_var_names: HashSet::new(),
        maps: Vec::new(),
        producers: Vec::new(),
        candidates: Vec::new(),
        chain: Vec::new(),
    };
    if let Some(eqs) = model_json.get("equations").and_then(|v| v.as_array()) {
        for eq in eqs {
            let (Some(lhs), Some(rhs)) = (eq.get("lhs"), eq.get("rhs")) else {
                continue;
            };
            if let Some(base) = lhs_base_raw(lhs) {
                classify_assignment(&base, rhs, &mut det);
            }
        }
    }
    if let Some(vars) = model_json.get("variables").and_then(|v| v.as_object()) {
        for (vname, v) in vars {
            if let Some(expr) = v.get("expression") {
                classify_assignment(vname, expr, &mut det);
            }
        }
    }
    // Fixpoint over the data-dependency DAG: a candidate that depends on a known
    // VI buffer in the SCVT centroid shape is itself a build-time buffer. The
    // signatures are narrow (see the helpers) so ordinary model aggregates —
    // including the regridder's bin-to-bin gather — are left on the simulate path.
    let mut candidates = std::mem::take(&mut det.candidates);
    let mut changed = true;
    while changed {
        changed = false;
        let mut rest = Vec::new();
        for (base, node) in candidates.drain(..) {
            if vi_grouped_key(&node, &det.vi_var_names).is_some() {
                det.vi_var_names.insert(base.clone());
                det.chain.push((base, node, ChainKind::Grouped));
                changed = true;
            } else if vi_is_derived(&node, &det.vi_var_names) {
                det.vi_var_names.insert(base.clone());
                det.chain.push((base, node, ChainKind::Derived));
                changed = true;
            } else {
                rest.push((base, node));
            }
        }
        candidates = rest;
    }
    det.has_vi = !det.maps.is_empty() || !det.producers.is_empty() || !det.chain.is_empty();
    det
}

fn classify_assignment(base: &str, rhs: &Value, det: &mut Detection) {
    let kind = vi_node_kind(rhs);
    if kind == NodeKind::None {
        // A plain numeric aggregate is a grouped/derived candidate (resolved later).
        if node_op(rhs) == Some("aggregate") {
            det.candidates.push((base.to_string(), rhs.clone()));
        }
        return;
    }
    det.vi_var_names.insert(base.to_string()); // every value-invention output leaves the ODE
    match kind {
        NodeKind::Producer => det.producers.push((base.to_string(), rhs.clone())),
        NodeKind::Map => det.maps.push((base.to_string(), rhs.clone())),
        _ => {}
    }
}

// --------------------------------------------------------------------------- //
// Build-time evaluation context (mirror of _ViCtx)
// --------------------------------------------------------------------------- //

struct ViCtx<'a> {
    const_arrays: &'a HashMap<String, ArrayD<f64>>,
    params: &'a HashMap<String, f64>,
    index_sets: &'a Map<String, Value>,
    variables: &'a Map<String, Value>,
    /// Per-const-array, per-dimension out-of-range boundary policy (ess-gj4). A
    /// `(name, d)` absent from this map (or beyond the declared vec) defaults to
    /// [`BoundaryKind::Error`] — the throw-on-OOB behavior that catches genuine
    /// connectivity / stencil-weight bugs.
    const_array_boundaries: &'a HashMap<String, Vec<BoundaryKind>>,
    /// materialised map var → {output-index value → key value}
    maps: HashMap<String, HashMap<i64, Val>>,
}

impl<'a> ViCtx<'a> {
    /// The declared boundary policy for dimension `d` of const array `name`,
    /// defaulting to [`BoundaryKind::Error`] when no policy is declared.
    fn boundary(&self, name: &str, d: usize) -> BoundaryKind {
        self.const_array_boundaries
            .get(name)
            .and_then(|dims| dims.get(d))
            .copied()
            .unwrap_or(BoundaryKind::Error)
    }

    fn param(&self, name: &str) -> Result<f64, ValueInventionError> {
        if let Some(v) = self.params.get(name) {
            return Ok(*v);
        }
        if let Some(d) = self
            .variables
            .get(name)
            .and_then(|v| v.get("default"))
            .and_then(|v| v.as_f64())
        {
            return Ok(d);
        }
        err(format!(
            "value-invention scalar parameter {name:?} has no override or default"
        ))
    }
}

type Bindings = HashMap<String, i64>;

fn vi_eval(node: &Value, ctx: &ViCtx, bindings: &Bindings) -> Result<Val, ValueInventionError> {
    match node {
        Value::Bool(b) => Ok(Val::Bool(*b)),
        Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                Ok(Val::Int(i))
            } else {
                Ok(Val::Float(n.as_f64().unwrap()))
            }
        }
        Value::String(s) => {
            if let Some(v) = bindings.get(s) {
                return Ok(Val::Int(*v)); // bound range symbol
            }
            if ctx.const_arrays.contains_key(s) {
                return Ok(Val::Str(s.clone())); // bare factor name (used by index)
            }
            if ctx
                .variables
                .get(s)
                .and_then(|v| v.get("type"))
                .and_then(|v| v.as_str())
                == Some("parameter")
            {
                return Ok(Val::Float(ctx.param(s)?)); // scalar parameter
            }
            Ok(Val::Str(s.clone())) // relation tag ("edge"/"bin"/"pair")
        }
        Value::Object(_) => vi_eval_op(node, ctx, bindings),
        other => err(format!("unevaluable value-invention node {other}")),
    }
}

fn vi_eval_op(node: &Value, ctx: &ViCtx, bindings: &Bindings) -> Result<Val, ValueInventionError> {
    let op = node_op(node)
        .ok_or_else(|| ValueInventionError("value-invention node has no `op`".into()))?;
    let args = node_args(node);
    // Arity guard: `args` comes straight from user JSON (schema-valid files
    // may still carry too few operands), so a missing operand must surface
    // as a diagnostic, never a slice-index panic.
    let arg = |i: usize| -> Result<&Value, ValueInventionError> {
        args.get(i).ok_or_else(|| {
            ValueInventionError(format!(
                "op {op:?} expects at least {} operand(s), found {}",
                i + 1,
                args.len()
            ))
        })
    };
    match op {
        "index" => vi_index(node, ctx, bindings),
        "skolem" => Ok(Val::Key(vi_skolem(node, ctx, bindings)?)),
        "true" => Ok(Val::Bool(true)),
        "false" => Ok(Val::Bool(false)),
        "floor" => Ok(Val::Int(
            vi_eval(arg(0)?, ctx, bindings)?.as_f64()?.floor() as i64
        )),
        "ceil" => Ok(Val::Int(
            vi_eval(arg(0)?, ctx, bindings)?.as_f64()?.ceil() as i64
        )),
        "/" => Ok(Val::Float(
            vi_eval(arg(0)?, ctx, bindings)?.as_f64()?
                / vi_eval(arg(1)?, ctx, bindings)?.as_f64()?,
        )),
        "*" => {
            let mut acc = 1.0;
            for a in args {
                acc *= vi_eval(a, ctx, bindings)?.as_f64()?;
            }
            Ok(Val::Float(acc))
        }
        "+" => {
            let mut acc = 0.0;
            for a in args {
                acc += vi_eval(a, ctx, bindings)?.as_f64()?;
            }
            Ok(Val::Float(acc))
        }
        "-" => {
            if args.len() == 1 {
                Ok(Val::Float(-vi_eval(arg(0)?, ctx, bindings)?.as_f64()?))
            } else {
                Ok(Val::Float(
                    vi_eval(arg(0)?, ctx, bindings)?.as_f64()?
                        - vi_eval(arg(1)?, ctx, bindings)?.as_f64()?,
                ))
            }
        }
        "<" | ">" | "<=" | ">=" | "==" | "!=" => {
            let a = vi_eval(arg(0)?, ctx, bindings)?.as_f64()?;
            let b = vi_eval(arg(1)?, ctx, bindings)?.as_f64()?;
            Ok(Val::Bool(match op {
                "<" => a < b,
                ">" => a > b,
                "<=" => a <= b,
                ">=" => a >= b,
                "==" => a == b,
                _ => a != b,
            }))
        }
        other => err(format!(
            "value-invention build-time evaluator does not support op {other:?}"
        )),
    }
}

/// `index(factor, i, …)`: gather from a const-array factor (1-based). The factor
/// is build-time data supplied in `const_arrays`.
///
/// An out-of-range 1-based index resolves per the dimension's declared boundary
/// policy (ess-gj4) rather than panicking: [`BoundaryKind::Periodic`] wraps via
/// 1-based mod, [`BoundaryKind::Clamp`] edge-extends, and an undeclared policy /
/// [`BoundaryKind::Error`] returns a structured [`ValueInventionError`]. In-range
/// indices are byte-identical to the prior `arr[(i-1)]` gather.
fn vi_index(node: &Value, ctx: &ViCtx, bindings: &Bindings) -> Result<Val, ValueInventionError> {
    let args = node_args(node);
    let name = args.first().and_then(|v| v.as_str());
    let Some(name) = name else {
        return err("value-invention index target must be a const-array factor name");
    };
    // A name that resolves to an already-materialised value-invention buffer (an
    // arg-witness assignment or an upstream grouped/derived buffer) is read from
    // that buffer — this is what lets `centroid[g] = num[g]/den[g]` read its inputs.
    if let Some(buf) = ctx.maps.get(name) {
        if args.len() != 2 {
            return err(format!(
                "materialised value-invention buffer {name:?} is a 1-D buffer; expected one index, \
                 got {}",
                args.len() - 1
            ));
        }
        let idx = vi_eval(&args[1], ctx, bindings)?.key_int()?;
        return buf.get(&idx).cloned().ok_or_else(|| {
            ValueInventionError(format!(
                "materialised value-invention buffer {name:?} has no entry at index {idx}"
            ))
        });
    }
    let Some(arr) = ctx.const_arrays.get(name) else {
        return err(format!(
            "value-invention index target {name:?} must be a const-array factor \
             or an already-materialised value-invention buffer"
        ));
    };
    let shape = arr.shape();
    let mut idx = Vec::with_capacity(args.len() - 1);
    for (d, a) in args[1..].iter().enumerate() {
        let one_based = vi_eval(a, ctx, bindings)?.key_int()?;
        let n = shape.get(d).copied().unwrap_or(0) as i64;
        let resolved = resolve_const_index(ctx, name, d, one_based, n)?;
        idx.push((resolved - 1) as usize);
    }
    // Rank guard: `arr[IxDyn(&idx)]` panics unless the number of supplied indices
    // equals the array rank. Too-MANY indices already error inside the loop above
    // (an extra dim has extent 0 → `resolve_const_index` fails), but too FEW would
    // reach ndarray and panic — surface it as a diagnostic instead.
    if idx.len() != arr.ndim() {
        return err(format!(
            "value-invention index target {name:?} has rank {}, but {} index(es) were supplied",
            arr.ndim(),
            idx.len()
        ));
    }
    Ok(Val::Float(arr[IxDyn(&idx)]))
}

/// Resolve a possibly-out-of-range 1-based index `one_based` in dimension `d`
/// (extent `n`) of const array `name` against its declared boundary policy
/// (ess-gj4). In-range indices (`1..=n`) pass through unchanged. Mirrors the Julia
/// reference `_resolve_const_index`. Returns a 1-based resolved index.
fn resolve_const_index(
    ctx: &ViCtx,
    name: &str,
    d: usize,
    one_based: i64,
    n: i64,
) -> Result<i64, ValueInventionError> {
    if (1..=n).contains(&one_based) {
        return Ok(one_based);
    }
    // An empty dimension (n == 0) can never be wrapped or clamped into a valid
    // 1-based index — always an error, regardless of declared policy.
    if n >= 1 {
        match ctx.boundary(name, d) {
            // 1-based periodic wrap == Julia `mod1(i, n)`.
            BoundaryKind::Periodic => return Ok((one_based - 1).rem_euclid(n) + 1),
            BoundaryKind::Clamp => return Ok(one_based.clamp(1, n)),
            BoundaryKind::Error => {}
        }
    }
    err(format!(
        "const array '{name}' index {one_based} out of range 1..{n} in dim {d}"
    ))
}

/// `skolem(c1, c2, …)` → the canonical key tuple. EVERY arg is a pure key
/// component: an exact integer ID (§5.5.1 rule 4). The relation tag (the
/// "sort"/relation name, e.g. `"edge"`/`"bin"`/`"pair"`) lives in the node's
/// dedicated `label` field — documentary only, never part of the emitted key —
/// which keeps the materialised set byte-identical to the M3 determinism golden
/// (edges `[[1,2],…]`, candidate pairs `(i,j)`, which carry no tag) while
/// ensuring a mistyped key component can no longer silently masquerade as a tag
/// (it now fails closed via `key_int`). A single component degrades to a scalar
/// key.
fn vi_skolem(node: &Value, ctx: &ViCtx, bindings: &Bindings) -> Result<Key, ValueInventionError> {
    let args = node_args(node);
    let mut key_comps: Vec<Key> = Vec::with_capacity(args.len());
    for a in args {
        // Every arg is a key component; a non-key value fails closed via `key_int`
        // (as it already did for non-leading positions). The `label` field, if
        // present, is a documentary relation tag and is intentionally ignored.
        key_comps.push(Key::Int(vi_eval(a, ctx, bindings)?.key_int()?));
    }
    if key_comps.len() == 1 {
        Ok(key_comps.into_iter().next().unwrap())
    } else {
        Ok(Key::Tuple(key_comps))
    }
}

// --------------------------------------------------------------------------- //
// Range resolution (mirror of _vi_order_syms / _vi_range_values / _vi_enumerate)
// --------------------------------------------------------------------------- //

/// Order range symbols so a ragged range's `of` parents precede it (a stable
/// topological order over the per-symbol `of` dependency).
fn vi_order_syms(ranges: &Map<String, Value>) -> Result<Vec<String>, ValueInventionError> {
    let syms: Vec<String> = ranges.keys().cloned().collect();
    let mut ordered: Vec<String> = Vec::new();
    let mut remaining = syms.clone();
    while !remaining.is_empty() {
        let mut progressed = false;
        let mut i = 0;
        while i < remaining.len() {
            let s = &remaining[i];
            let of: Vec<String> = ranges[s]
                .get("of")
                .and_then(|v| v.as_array())
                .map(|a| {
                    a.iter()
                        .filter_map(|x| x.as_str().map(String::from))
                        .collect()
                })
                .unwrap_or_default();
            let ready = of.iter().all(|p| ordered.contains(p) || !syms.contains(p));
            if ready {
                ordered.push(remaining.remove(i));
                progressed = true;
            } else {
                i += 1;
            }
        }
        if !progressed {
            return err(format!(
                "value-invention ranges have a cyclic `of` dependency: {remaining:?}"
            ));
        }
    }
    Ok(ordered)
}

/// The element values a range symbol binds to. interval/categorical → 1-based
/// positions; ragged → the MEMBER values gathered from the set's `values` factor
/// sliced by its `offsets` factor (so a range symbol over `face_vertices` binds
/// to the vertex IDs of the parent face, §5.2).
fn vi_range_values(
    spec: &Value,
    ctx: &ViCtx,
    bindings: &Bindings,
) -> Result<Vec<i64>, ValueInventionError> {
    let from = spec.get("from").and_then(|v| v.as_str());
    let Some(from) = from else {
        return err("value-invention range spec is missing `from`");
    };
    let Some(iset) = ctx.index_sets.get(from) else {
        return err(format!(
            "value-invention range references undeclared index set {from:?}"
        ));
    };
    let kind = iset.get("kind").and_then(|v| v.as_str());
    match kind {
        Some("interval") => {
            let size = iset.get("size").and_then(|v| v.as_i64()).unwrap_or(0);
            Ok((1..=size).collect())
        }
        Some("categorical") => {
            let n = iset
                .get("members")
                .and_then(|v| v.as_array())
                .map(|a| a.len())
                .unwrap_or(0) as i64;
            Ok((1..=n).collect())
        }
        Some("ragged") => {
            let of: Vec<String> = spec
                .get("of")
                .and_then(|v| v.as_array())
                .map(|a| {
                    a.iter()
                        .filter_map(|x| x.as_str().map(String::from))
                        .collect()
                })
                .unwrap_or_default();
            let Some(parent_sym) = of.first() else {
                return err(format!(
                    "ragged value-invention range {from:?} needs an `of` parent"
                ));
            };
            let parent = *bindings.get(parent_sym).ok_or_else(|| {
                ValueInventionError(format!("ragged parent {parent_sym:?} is not bound"))
            })?;
            let offsets_name = iset.get("offsets").and_then(|v| v.as_str()).unwrap_or("");
            let values_name = iset.get("values").and_then(|v| v.as_str()).unwrap_or("");
            let offs = ctx.const_arrays.get(offsets_name).ok_or_else(|| {
                ValueInventionError(format!(
                    "ragged offsets factor {offsets_name:?} not supplied"
                ))
            })?;
            let vals = ctx.const_arrays.get(values_name).ok_or_else(|| {
                ValueInventionError(format!("ragged values factor {values_name:?} not supplied"))
            })?;
            // `offs` / `vals` are caller-supplied ndarray factors and `parent`
            // comes from the enumeration binding, so every index into them must be
            // bounds-checked before use: an out-of-shape parent, a `values` factor
            // narrower than the member count, or a negative/zero parent (which
            // would wrap `(parent-1) as usize`) must surface as a diagnostic, never
            // a slice-index panic (see the boundary-policy note above).
            if parent < 1 {
                return err(format!(
                    "ragged value-invention range {from:?}: parent index {parent} is out of \
                     range (1-based parent must be >= 1)"
                ));
            }
            let prow = (parent - 1) as usize;
            let offs_len = offs.shape().first().copied().unwrap_or(0);
            if offs.ndim() != 1 || prow >= offs_len {
                return err(format!(
                    "ragged value-invention range {from:?}: parent {parent} is outside offsets \
                     factor {offsets_name:?} (shape {:?})",
                    offs.shape()
                ));
            }
            let nmem = offs[IxDyn(&[prow])] as i64;
            if nmem < 0 {
                return err(format!(
                    "ragged value-invention range {from:?}: offsets factor {offsets_name:?} gives \
                     a negative member count {nmem} for parent {parent}"
                ));
            }
            let vshape = vals.shape();
            if vals.ndim() != 2 || prow >= vshape[0] || nmem as usize > vshape[1] {
                return err(format!(
                    "ragged value-invention range {from:?}: values factor {values_name:?} (shape \
                     {vshape:?}) is too small for parent {parent} member count {nmem}"
                ));
            }
            let mut out = Vec::with_capacity(nmem as usize);
            for l in 1..=nmem {
                let v = vals[IxDyn(&[prow, (l - 1) as usize])];
                out.push(Val::Float(v).key_int()?);
            }
            Ok(out)
        }
        other => err(format!(
            "value-invention range over index set kind {other:?} is unsupported"
        )),
    }
}

/// Enumerate every full binding of an aggregate's `ranges`, calling `visit` at
/// each leaf binding.
fn vi_enumerate<F>(
    ranges: &Map<String, Value>,
    ctx: &ViCtx,
    mut visit: F,
) -> Result<(), ValueInventionError>
where
    F: FnMut(&Bindings) -> Result<(), ValueInventionError>,
{
    let syms = vi_order_syms(ranges)?;
    let mut bindings: Bindings = HashMap::new();
    vi_enumerate_rec(&syms, 0, ranges, ctx, &mut bindings, &mut visit)
}

fn vi_enumerate_rec<F>(
    syms: &[String],
    k: usize,
    ranges: &Map<String, Value>,
    ctx: &ViCtx,
    bindings: &mut Bindings,
    visit: &mut F,
) -> Result<(), ValueInventionError>
where
    F: FnMut(&Bindings) -> Result<(), ValueInventionError>,
{
    if k >= syms.len() {
        return visit(bindings);
    }
    let s = &syms[k];
    for v in vi_range_values(&ranges[s], ctx, bindings)? {
        bindings.insert(s.clone(), v);
        vi_enumerate_rec(syms, k + 1, ranges, ctx, bindings, visit)?;
    }
    bindings.remove(s);
    Ok(())
}

// --------------------------------------------------------------------------- //
// Materialisation (mirror of _vi_join_* / _vi_materialize_*)
// --------------------------------------------------------------------------- //

/// The index range symbol of a join-key variable within the producer's ranges:
/// the producer range whose `from` equals the variable's (1-D) shape index set.
fn vi_join_index_sym(
    vname: &str,
    producer_ranges: &Map<String, Value>,
    ctx: &ViCtx,
) -> Result<String, ValueInventionError> {
    let v = ctx.variables.get(vname).ok_or_else(|| {
        ValueInventionError(format!("join references unknown variable {vname:?}"))
    })?;
    let shape: Vec<String> = v
        .get("shape")
        .and_then(|s| s.as_array())
        .map(|a| {
            a.iter()
                .filter_map(|x| x.as_str().map(String::from))
                .collect()
        })
        .unwrap_or_default();
    if shape.len() != 1 {
        return err(format!(
            "value-invention join key {vname:?} must be a 1-D buffer; shape={shape:?}"
        ));
    }
    let target = &shape[0];
    for (sym, spec) in producer_ranges {
        if spec.get("from").and_then(|v| v.as_str()) == Some(target.as_str()) {
            return Ok(sym.clone());
        }
    }
    err(format!(
        "no producer range binds the index set {target:?} of join key {vname:?}"
    ))
}

/// A join clause resolved ONCE against a node's ranges (the candidate set /
/// buffer bindings are shared across every contracted tuple), mirroring Julia's
/// `_ViJoinGate` (`value_invention.jl`). Consulted per binding by [`vi_join_ok`];
/// an [`ViJoinGate::Overlap`] gate additionally DRIVES enumeration from its
/// prebuilt candidate pairs ([`vi_enumerate_join`]).
enum ViJoinGate {
    /// A `join.on` value-equality gate (§5.3): admit `(sym_l, sym_r)` iff the two
    /// materialised map buffers agree — `maps[lname][bindings[sym_l]] ==
    /// maps[rname][bindings[sym_r]]`.
    Equality {
        sym_l: String,
        sym_r: String,
        lname: String,
        rname: String,
    },
    /// A `join.overlap` spatial broad-phase gate (Phase 2a): admit `(sym_l,
    /// sym_r)` iff the `(pos_l, pos_r)` range positions (1-based, matching the
    /// enumeration bindings) are in the prebuilt broad-phase candidate set — the
    /// envelope candidacy computed ONCE from the const-array envelope factors via
    /// [`crate::broad_phase`].
    Overlap {
        sym_l: String,
        sym_r: String,
        candidates: HashSet<(i64, i64)>,
    },
}

/// The OVERLAP join-gate candidate set: every `(pos_l, pos_r)` — 1-based range
/// positions keyed so `src_env` is the query side and `tgt_env` the indexed cell
/// side — whose eps-inflated envelopes intersect. Built ONCE from the const-array
/// envelope factors through the Phase-3a broad-phase primitive (rstar fast path,
/// byte-identical to the brute-force oracle). Mirrors Julia's
/// `_overlap_candidate_set`.
fn overlap_candidate_set(
    src_env: &[String],
    tgt_env: &[String],
    ctx: &ViCtx,
    eps: f64,
) -> Result<HashSet<(i64, i64)>, ValueInventionError> {
    let src_envs =
        crate::broad_phase::envelope_vectors(src_env, ctx.const_arrays).map_err(ValueInventionError)?;
    let tgt_envs =
        crate::broad_phase::envelope_vectors(tgt_env, ctx.const_arrays).map_err(ValueInventionError)?;
    let pairs = crate::broad_phase::broad_phase_candidates(&src_envs, &tgt_envs, eps);
    // Broad-phase pairs are 0-based positions; the enumeration bindings are
    // 1-based (`vi_range_values` binds interval/categorical position p to p), so
    // shift to 1-based to match.
    Ok(pairs
        .into_iter()
        .map(|(q, c)| ((q as i64) + 1, (c as i64) + 1))
        .collect())
}

/// Structural arity check on an overlap-clause env-factor list (1 rings /
/// 2 points / 4 rectangle bounds), mirroring Julia's `_valid_env_arity`.
fn overlap_env_names(ov: &Value, field: &str) -> Result<Vec<String>, ValueInventionError> {
    let raw = ov.get(field).and_then(|v| v.as_array()).ok_or_else(|| {
        ValueInventionError(format!(
            "join `overlap` clause requires both `src_env` and `tgt_env` arrays of envelope \
             factor names (Phase 2a spatial overlap gate); missing/invalid `{field}`"
        ))
    })?;
    let names: Vec<String> = raw
        .iter()
        .map(|x| x.as_str().map(String::from).unwrap_or_default())
        .collect();
    if !matches!(names.len(), 1 | 2 | 4) {
        return err(format!(
            "join `overlap` `{field}` must name 1 (rings), 2 (point [x,y]), or 4 \
             (rect [xmin,ymin,xmax,ymax]) factors; got {}",
            names.len()
        ));
    }
    Ok(names)
}

/// Resolve an aggregate's `join` clauses into [`ViJoinGate`]s ONCE against
/// `producer_ranges`. A `{on: [...]}` clause resolves to one [`ViJoinGate::Equality`]
/// per key pair; a `{overlap: {src_env, tgt_env, eps}}` clause resolves to a
/// single [`ViJoinGate::Overlap`] whose broad-phase candidate set is built here.
/// Mirrors Julia's `_vi_resolve_join`.
fn vi_resolve_join(
    join: &[Value],
    producer_ranges: &Map<String, Value>,
    ctx: &ViCtx,
) -> Result<Vec<ViJoinGate>, ValueInventionError> {
    let mut gates: Vec<ViJoinGate> = Vec::new();
    for clause in join {
        if let Some(ov) = clause.get("overlap") {
            let src_env = overlap_env_names(ov, "src_env")?;
            let tgt_env = overlap_env_names(ov, "tgt_env")?;
            let eps = ov.get("eps").and_then(|v| v.as_f64()).unwrap_or(0.0);
            // `src_env`/`tgt_env` name const-array envelope FACTORS; each factor's
            // 1-D shape index set names one join range (like an `on` key column).
            // All factors of one side share that index set, so the first names it.
            let sym_l = vi_join_index_sym(&src_env[0], producer_ranges, ctx)?;
            let sym_r = vi_join_index_sym(&tgt_env[0], producer_ranges, ctx)?;
            let candidates = overlap_candidate_set(&src_env, &tgt_env, ctx, eps)?;
            gates.push(ViJoinGate::Overlap {
                sym_l,
                sym_r,
                candidates,
            });
        } else if let Some(on) = clause.get("on").and_then(|v| v.as_array()) {
            for pair in on {
                let cols = pair.as_array().filter(|c| c.len() == 2).ok_or_else(|| {
                    ValueInventionError("join.on entry must be a [left, right] pair".into())
                })?;
                let lname = cols[0].as_str().unwrap_or_default().to_string();
                let rname = cols[1].as_str().unwrap_or_default().to_string();
                let sym_l = vi_join_index_sym(&lname, producer_ranges, ctx)?;
                let sym_r = vi_join_index_sym(&rname, producer_ranges, ctx)?;
                gates.push(ViJoinGate::Equality {
                    sym_l,
                    sym_r,
                    lname,
                    rname,
                });
            }
        }
    }
    Ok(gates)
}

/// True iff every resolved join gate admits this binding (§5.3 / Phase 2a): a
/// value-equality gate compares materialised buffer values; an overlap gate tests
/// membership of the `(pos_l, pos_r)` range positions in the broad-phase set.
/// Mirrors Julia's `_vi_join_ok`.
fn vi_join_ok(
    gates: &[ViJoinGate],
    ctx: &ViCtx,
    bindings: &Bindings,
) -> Result<bool, ValueInventionError> {
    // `join.on` names and index symbols come from user JSON, so a missing map
    // buffer or unbound symbol is a diagnostic, not a panicking `Index` lookup.
    let unbound = |sym: &str| ValueInventionError(format!("join index symbol {sym:?} is not bound"));
    for g in gates {
        match g {
            ViJoinGate::Equality {
                sym_l,
                sym_r,
                lname,
                rname,
            } => {
                let missing_map = |name: &str| {
                    ValueInventionError(format!("join key {name:?} has no materialised map buffer"))
                };
                let lmap = ctx.maps.get(lname).ok_or_else(|| missing_map(lname))?;
                let rmap = ctx.maps.get(rname).ok_or_else(|| missing_map(rname))?;
                let lbind = bindings.get(sym_l).ok_or_else(|| unbound(sym_l))?;
                let rbind = bindings.get(sym_r).ok_or_else(|| unbound(sym_r))?;
                if lmap.get(lbind) != rmap.get(rbind) {
                    return Ok(false);
                }
            }
            ViJoinGate::Overlap {
                sym_l,
                sym_r,
                candidates,
            } => {
                let l = *bindings.get(sym_l).ok_or_else(|| unbound(sym_l))?;
                let r = *bindings.get(sym_r).ok_or_else(|| unbound(sym_r))?;
                if !candidates.contains(&(l, r)) {
                    return Ok(false);
                }
            }
        }
    }
    Ok(true)
}

/// Enumerate an aggregate's `ranges`, DRIVING from an OVERLAP gate's prebuilt
/// candidate pairs when one is present (projection-pushdown Wall #1). Instead of
/// building the full product over every range and membership-testing each tuple —
/// O(∏ranges), e.g. O(N_query·N_cell) — iterate ONLY the gate's `(pos_l, pos_r)`
/// candidate pairs (sorted for determinism), bind the two gated range symbols
/// from each pair, and take the cartesian product with any OTHER (ungated) ranges.
/// Cost drops to O(|candidates|·∏ungated).
///
/// With NO overlap gate this is EXACTLY [`vi_enumerate`] — byte-for-byte identical
/// enumeration order and leaf set. The callback STILL applies the narrow `filter`
/// and the full [`vi_join_ok`] re-check downstream, so the overlap-gated leaf set
/// differs from the full product only by provably-non-candidate tuples the
/// membership test would have rejected anyway — the materialised member SET (after
/// `distinct` canonicalises order) is identical to the old full-product path.
/// Mirrors Julia's `_vi_enumerate_join`.
fn vi_enumerate_join<F>(
    ranges: &Map<String, Value>,
    gates: &[ViJoinGate],
    ctx: &ViCtx,
    mut visit: F,
) -> Result<(), ValueInventionError>
where
    F: FnMut(&Bindings) -> Result<(), ValueInventionError>,
{
    // The first overlap gate drives; other gate kinds enumerate the full product.
    let driver = gates.iter().find_map(|g| match g {
        ViJoinGate::Overlap {
            sym_l,
            sym_r,
            candidates,
        } => Some((sym_l, sym_r, candidates)),
        _ => None,
    });
    let Some((sym_l, sym_r, candidates)) = driver else {
        return vi_enumerate(ranges, ctx, visit); // full product — unchanged behaviour
    };
    // DETERMINISTIC (pos_l, pos_r)-ascending drive order (member set is
    // canonicalised downstream, but a sorted drive keeps any order-sensitive
    // reduction stable).
    let mut pairs: Vec<(i64, i64)> = candidates.iter().copied().collect();
    pairs.sort_unstable();
    // The remaining ungated symbols, in the topological order the full product
    // visits them, minus the two driven symbols.
    let rest: Vec<String> = vi_order_syms(ranges)?
        .into_iter()
        .filter(|s| s != sym_l && s != sym_r)
        .collect();
    let mut bindings: Bindings = HashMap::new();
    for (pl, pr) in pairs {
        // A candidate pair holds 1-based range POSITIONS; for an interval /
        // categorical range `vi_range_values` binds position p to the value p, so
        // binding the gated symbols directly reproduces exactly the tuple the full
        // product would have bound (and which `vi_join_ok` admits).
        bindings.insert(sym_l.clone(), pl);
        bindings.insert(sym_r.clone(), pr);
        vi_enumerate_rec(&rest, 0, ranges, ctx, &mut bindings, &mut visit)?;
    }
    Ok(())
}

/// Arg-witness reducer (RFC §5.7 rule 6). Over the inner contracted `ranges`
/// (which EXTEND the outer map binding so `expr` may read both the point and the
/// candidate), evaluate the scalar `expr` body at each candidate and return the
/// `arg` index symbol's value at the optimum — `argmin` keeps the least value,
/// `argmax` the greatest. The NORMATIVE tie-break is the SMALLEST arg (the
/// smallest generator id): equal values resolve to the lower candidate index, so
/// the emitted integer buffer is byte-identical across bindings irrespective of
/// enumeration order. Optional `join` (a bin-Skolem prune, §5.3) / `filter`
/// restrict the candidate set; an empty candidate set is an error.
fn vi_argreduce(
    node: &Value,
    ctx: &ViCtx,
    outer_bindings: &Bindings,
    outer_ranges: &Map<String, Value>,
) -> Result<i64, ValueInventionError> {
    let op = node_op(node).unwrap_or("");
    let empty = Map::new();
    let inner_ranges = node
        .get("ranges")
        .and_then(|v| v.as_object())
        .unwrap_or(&empty);
    let arg_sym = node.get("arg").and_then(|v| v.as_str()).ok_or_else(|| {
        ValueInventionError(format!(
            "arg-witness op {op:?} requires an `arg` naming the witnessing index symbol"
        ))
    })?;
    let value_expr = node.get("expr").ok_or_else(|| {
        ValueInventionError(format!(
            "arg-witness op {op:?} requires an `expr` body (the scalar to optimise)"
        ))
    })?;
    if !inner_ranges.contains_key(arg_sym) {
        return err(format!(
            "arg-witness `arg`={arg_sym:?} must name one of the contracted `ranges` symbols"
        ));
    }
    if outer_bindings.contains_key(arg_sym) {
        return err(format!(
            "arg-witness `arg`={arg_sym:?} shadows an outer index symbol"
        ));
    }
    let filt = node.get("filter");
    let join: Vec<Value> = node
        .get("join")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();
    // Combined ranges so a `join` column over an OUTER-indexed map buffer (the
    // point's bin) resolves alongside the inner candidate's bin (§5.3 equi-join).
    let mut combined: Map<String, Value> = outer_ranges.clone();
    for (k, v) in inner_ranges {
        combined.insert(k.clone(), v.clone());
    }
    // Resolve the join gates ONCE (broad-phase candidate set / buffer bindings are
    // shared across every candidate tuple), not per `rec` leaf.
    let gates = if join.is_empty() {
        Vec::new()
    } else {
        vi_resolve_join(&join, &combined, ctx)?
    };
    let syms = vi_order_syms(inner_ranges)?;
    let mut bindings = outer_bindings.clone();
    let mut best: Option<(f64, i64)> = None;
    vi_enumerate_rec(&syms, 0, inner_ranges, ctx, &mut bindings, &mut |b| {
        if let Some(f) = filt {
            let pass = match vi_eval(f, ctx, b)? {
                Val::Bool(x) => x,
                Val::Int(i) => i > 0,
                Val::Float(x) => x > 0.0,
                _ => false,
            };
            if !pass {
                return Ok(());
            }
        }
        if !gates.is_empty() && !vi_join_ok(&gates, ctx, b)? {
            return Ok(());
        }
        let v = vi_eval(value_expr, ctx, b)?.as_f64()?;
        let a = b[arg_sym];
        best = match best {
            None => Some((v, a)),
            Some((bv, ba)) => {
                let better = if op == "argmax" { v > bv } else { v < bv };
                // Strict improvement OR an exact tie resolved to the smaller arg.
                if better || (v == bv && a < ba) {
                    Some((v, a))
                } else {
                    Some((bv, ba))
                }
            }
        };
        Ok(())
    })?;
    match best {
        Some((_, a)) => Ok(a),
        None => err(format!(
            "arg-witness op {op:?} has an empty candidate set; no index witnesses the \
             optimum (a point with no candidate generator is undefined)"
        )),
    }
}

/// Materialise a per-element value-invention map var → {output-index → value}.
fn vi_materialize_map(
    ctx: &mut ViCtx,
    vname: &str,
    node: &Value,
) -> Result<(), ValueInventionError> {
    let output_idx: Vec<String> = node
        .get("output_idx")
        .and_then(|v| v.as_array())
        .map(|a| {
            a.iter()
                .filter_map(|x| x.as_str().map(String::from))
                .collect()
        })
        .unwrap_or_default();
    if output_idx.len() != 1 {
        return err(format!(
            "value-invention map {vname:?} must have a single output index; got {output_idx:?}"
        ));
    }
    let body = node.get("expr").ok_or_else(|| {
        ValueInventionError(format!("value-invention map {vname:?} has no `expr` body"))
    })?;
    let empty = Map::new();
    let ranges = node
        .get("ranges")
        .and_then(|v| v.as_object())
        .unwrap_or(&empty);
    let sym = output_idx[0].clone();
    let is_arg = is_argwitness(node);
    let mut out: HashMap<i64, Val> = HashMap::new();
    // Borrow the body / ranges via a const reference inside the closure; collect
    // into `out`, then store it on the context after enumeration completes.
    {
        let ctx_ref = &*ctx;
        vi_enumerate(ranges, ctx_ref, |bindings| {
            // An arg-witness body runs the inner reduction (with the outer point
            // bound) and emits the witnessing INDEX; an ordinary body (skolem)
            // emits its value.
            let value = if is_arg {
                Val::Int(vi_argreduce(body, ctx_ref, bindings, ranges)?)
            } else {
                vi_eval(body, ctx_ref, bindings)?
            };
            out.insert(bindings[&sym], value);
            Ok(())
        })?;
    }
    ctx.maps.insert(vname.to_string(), out);
    Ok(())
}

/// Materialise an index-set-producing aggregate → the distinct member set (§5.5
/// sorted total order, via the relational engine). Returns the member list.
fn vi_materialize_producer(ctx: &ViCtx, node: &Value) -> Result<Vec<Key>, ValueInventionError> {
    let key = node.get("key").ok_or_else(|| {
        ValueInventionError("value-invention producer aggregate requires a `key` (§5.5)".into())
    })?;
    let empty = Map::new();
    let ranges = node
        .get("ranges")
        .and_then(|v| v.as_object())
        .unwrap_or(&empty);
    let filt = node.get("filter");
    let join: Vec<Value> = node
        .get("join")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();
    // Resolve join gates ONCE (a `join.overlap` broad-phase candidate set is built
    // a single time here). An OVERLAP gate then DRIVES enumeration from its
    // candidate pairs (`vi_enumerate_join`, Wall #1) — O(|candidates|) rather than
    // O(∏ranges) with a per-tuple membership test; other gate kinds enumerate the
    // full product exactly as before.
    let gates = if join.is_empty() {
        Vec::new()
    } else {
        vi_resolve_join(&join, ranges, ctx)?
    };
    let mut members: Vec<Key> = Vec::new();
    vi_enumerate_join(ranges, &gates, ctx, |bindings| {
        if let Some(f) = filt {
            let fv = vi_eval(f, ctx, bindings)?;
            let pass = match fv {
                Val::Bool(b) => b,
                Val::Int(i) => i > 0,
                Val::Float(x) => x > 0.0,
                _ => false,
            };
            if !pass {
                return Ok(());
            }
        }
        if !gates.is_empty() && !vi_join_ok(&gates, ctx, bindings)? {
            return Ok(());
        }
        members.push(vi_skolem(key, ctx, bindings)?);
        Ok(())
    })?;
    Ok(relational::distinct(&members))
}

// --------------------------------------------------------------------------- //
// Grouped / derived build-time buffers (the SCVT centroid step)
// --------------------------------------------------------------------------- //

/// The (⊕ combiner, 0̄ identity) for a grouped semiring aggregate. `bool_and_or`
/// (Or/And) is index-set-producing, not a numeric grouped reduction, so only the
/// four numeric ⊕s are accepted (mirrors the array path's §5.5 reject).
fn vi_oplus(node: &Value) -> Result<(SemiringOp, f64), ValueInventionError> {
    let semiring = node.get("semiring").and_then(|v| v.as_str());
    let reduce = node.get("reduce").and_then(|v| v.as_str());
    let rk = effective_reduce_kind(semiring, reduce);
    let op = match rk {
        ReduceKind::Sum => SemiringOp::Sum,
        ReduceKind::Product => SemiringOp::Prod,
        ReduceKind::Max => SemiringOp::Max,
        ReduceKind::Min => SemiringOp::Min,
        ReduceKind::Or | ReduceKind::And => {
            return err(
                "grouped value-invention reduction ⊕ is index-set-producing (bool_and_or); \
                 expected a numeric semiring (+, *, max, min)",
            );
        }
    };
    Ok((op, rk.identity()))
}

/// §5.7 guard 2 for grouped / derived buffers: a build-time reduction may read
/// only build-time data — const-array factors and already-materialised VI
/// buffers. Reading a live ODE `state` variable would make it a per-step
/// quantity, out of scope for v1 (the Lloyd/SCVT outer loop re-invokes the build).
fn vi_assert_buildtime(
    ctx: &ViCtx,
    vname: &str,
    node: &Value,
    vi_var_names: &HashSet<String>,
) -> Result<(), ValueInventionError> {
    let mut refs = HashSet::new();
    vi_index_targets(node, &mut refs);
    for r in &refs {
        if vi_var_names.contains(r) || ctx.const_arrays.contains_key(r) {
            continue;
        }
        let is_state = ctx
            .variables
            .get(r)
            .and_then(|v| v.get("type"))
            .and_then(|v| v.as_str())
            == Some("state");
        if is_state {
            return err(format!(
                "grouped/derived value-invention buffer {vname:?} reads live state {r:?} — a \
                 build-time reduction's inputs must be CONST/DISCRETE factors or materialised \
                 buffers (RFC §5.7 guard 2)"
            ));
        }
    }
    Ok(())
}

/// Materialise a GROUPED semiring aggregate keyed on a value-invention buffer →
/// `{output-index → value}`. For each output `g`, fold (with the semiring ⊕) the
/// body over the contracted points whose group KEY (`assign[p]`) equals `g`. The
/// reduction runs through the determinism-correct [`group_aggregate`] (§5.5
/// rule 5) — the first time the front-door calls it (a library helper only).
/// Empty groups fold to 0̄.
fn vi_materialize_grouped(
    ctx: &mut ViCtx,
    vname: &str,
    node: &Value,
) -> Result<(), ValueInventionError> {
    let oi = node
        .get("output_idx")
        .and_then(|v| v.as_array())
        .filter(|a| a.len() == 1)
        .ok_or_else(|| {
            ValueInventionError(format!(
                "grouped value-invention aggregate {vname:?} must have a single output index"
            ))
        })?;
    let gsym = oi[0]
        .as_str()
        .ok_or_else(|| ValueInventionError("grouped output index must be a string".into()))?
        .to_string();
    let empty = Map::new();
    let ranges = node
        .get("ranges")
        .and_then(|v| v.as_object())
        .unwrap_or(&empty);
    if !ranges.contains_key(&gsym) {
        return err(format!(
            "grouped aggregate {vname:?} output index {gsym:?} is not among its ranges"
        ));
    }
    let body = node.get("expr").ok_or_else(|| {
        ValueInventionError(format!("grouped aggregate {vname:?} has no expr body"))
    })?;
    let join = node.get("join").and_then(|v| v.as_array()).ok_or_else(|| {
        ValueInventionError(format!(
            "grouped aggregate {vname:?} needs a join pairing its group-key buffer with {gsym:?}"
        ))
    })?;
    // The group KEY buffer: the join column paired with the output index that
    // names a materialised VI buffer (`assign`).
    let keyvar = vi_join_partner(join, &gsym, |n| ctx.maps.contains_key(n)).ok_or_else(|| {
        ValueInventionError(format!(
            "grouped aggregate {vname:?} join.on must pair a materialised value-invention buffer \
             with the output index {gsym:?}"
        ))
    })?;
    let keysym = vi_join_index_sym(&keyvar, ranges, ctx)?;
    let (op, zerobar) = vi_oplus(node)?;
    // Contraction ranges: every range symbol except the output index.
    let mut contract = Map::new();
    for (s, spec) in ranges {
        if s != &gsym {
            contract.insert(s.clone(), spec.clone());
        }
    }
    let gspec = ranges[&gsym].clone();
    let (rows, out_vals) = {
        let ctx_imm: &ViCtx = ctx;
        let mut rows: Vec<(Key, Num)> = Vec::new();
        vi_enumerate(&contract, ctx_imm, |bindings| {
            let p = *bindings.get(&keysym).ok_or_else(|| {
                ValueInventionError(format!("grouped key index symbol {keysym:?} is unbound"))
            })?;
            let kval = ctx_imm
                .maps
                .get(&keyvar)
                .and_then(|m| m.get(&p))
                .ok_or_else(|| {
                    ValueInventionError(format!(
                        "grouped key buffer {keyvar:?} has no entry at index {p}"
                    ))
                })?;
            let key = Key::Int(kval.key_int()?);
            let v = vi_eval(body, ctx_imm, bindings)?.as_f64()?;
            rows.push((key, Num::Float(v)));
            Ok(())
        })?;
        let out_vals = vi_range_values(&gspec, ctx_imm, &HashMap::new())?;
        (rows, out_vals)
    };
    let agg = group_aggregate(&rows, op);
    let mut agg_map: HashMap<i64, f64> = HashMap::new();
    for (k, n) in agg {
        if let Key::Int(i) = k {
            agg_map.insert(
                i,
                match n {
                    Num::Float(f) => f,
                    Num::Int(x) => x as f64,
                },
            );
        }
    }
    // Densify over the output index set; a generator with no assigned point is 0̄.
    let mut out: HashMap<i64, Val> = HashMap::new();
    for g in out_vals {
        out.insert(g, Val::Float(*agg_map.get(&g).unwrap_or(&zerobar)));
    }
    ctx.maps.insert(vname.to_string(), out);
    Ok(())
}

/// Materialise a DERIVED elementwise buffer (`centroid[g] = num[g]/den[g]`) →
/// `{output-index → value}`. A per-output map whose body reads upstream
/// materialised buffers (resolved by [`vi_index`] from `ctx.maps`).
fn vi_materialize_derived(
    ctx: &mut ViCtx,
    vname: &str,
    node: &Value,
) -> Result<(), ValueInventionError> {
    let oi = node
        .get("output_idx")
        .and_then(|v| v.as_array())
        .filter(|a| a.len() == 1)
        .ok_or_else(|| {
            ValueInventionError(format!(
                "derived value-invention aggregate {vname:?} must have a single output index"
            ))
        })?;
    let gsym = oi[0]
        .as_str()
        .ok_or_else(|| ValueInventionError("derived output index must be a string".into()))?
        .to_string();
    let empty = Map::new();
    let ranges = node
        .get("ranges")
        .and_then(|v| v.as_object())
        .unwrap_or(&empty);
    let body = node.get("expr").ok_or_else(|| {
        ValueInventionError(format!(
            "derived value-invention aggregate {vname:?} has no expr body"
        ))
    })?;
    let out = {
        let ctx_imm: &ViCtx = ctx;
        let mut out: HashMap<i64, Val> = HashMap::new();
        vi_enumerate(ranges, ctx_imm, |bindings| {
            let g = *bindings.get(&gsym).ok_or_else(|| {
                ValueInventionError(format!("derived output index {gsym:?} is unbound"))
            })?;
            out.insert(g, Val::Float(vi_eval(body, ctx_imm, bindings)?.as_f64()?));
            Ok(())
        })?;
        out
    };
    ctx.maps.insert(vname.to_string(), out);
    Ok(())
}

/// A model copy whose value-invention MAP vars are re-typed to their body's
/// cadence class (`const`→parameter, `discrete`→discrete), so a producer joining
/// on a map buffer classifies by the buffer's true (input-derived) cadence rather
/// than the seed of its declared `state` kind (§6.1). A `continuous` body is left
/// unchanged so the §5.7 guard still rejects state-dependent topology.
fn vi_classification_model(
    model_json: &Value,
    maps: &[(String, Value)],
) -> Result<Value, ValueInventionError> {
    if maps.is_empty() {
        return Ok(model_json.clone());
    }
    let mut out = model_json.clone();
    let variables = out.get_mut("variables").and_then(|v| v.as_object_mut());
    let Some(variables) = variables else {
        return Ok(out);
    };
    // Compute new types first (immutable classify against the original model),
    // then apply, to avoid borrowing `out` mutably and immutably at once.
    let mut retypes: Vec<(String, String)> = Vec::new();
    for (vname, node) in maps {
        if !variables.contains_key(vname) {
            continue;
        }
        let Some(body) = node.get("expr") else {
            continue;
        };
        let bcls = cadence::classify(body, model_json)
            .map_err(|e| ValueInventionError(format!("cadence classify failed: {e}")))?;
        let newtype = match bcls {
            Cadence::Const => "parameter",
            Cadence::Discrete => "discrete",
            Cadence::Continuous => continue,
        };
        retypes.push((vname.clone(), newtype.to_string()));
    }
    for (vname, newtype) in retypes {
        if let Some(v) = variables.get_mut(&vname).and_then(|v| v.as_object_mut()) {
            v.insert("type".to_string(), Value::String(newtype));
        }
    }
    Ok(out)
}

// --------------------------------------------------------------------------- //
// Public entrypoint
// --------------------------------------------------------------------------- //

/// Run the build-time value-invention engine over a raw model document.
///
/// `const_arrays` supplies the build-time factor arrays (the connectivity /
/// coordinates the keys are computed from); `params` supplies scalar parameter
/// overrides. A producer that classifies CONTINUOUS is rejected (§5.7 guard 2).
///
/// `const_array_boundaries` supplies an optional per-const-array, per-dimension
/// out-of-range boundary policy (ess-gj4): a gather at a 1-based index outside
/// `1..=n` resolves via the named dimension's [`BoundaryKind`] (periodic-wrap /
/// edge-extend) instead of erroring. A const array absent from this map (or a
/// dimension beyond its declared vec) keeps the throw-on-OOB default. Pass an
/// empty map for the prior behavior.
///
/// A no-op (empty result) for a model with no skolem/distinct/rank node — the
/// evaluator front-door then behaves byte-identically to before.
pub fn materialize_value_invention(
    model_json: &Value,
    const_arrays: &HashMap<String, ArrayD<f64>>,
    params: &HashMap<String, f64>,
    const_array_boundaries: &HashMap<String, Vec<BoundaryKind>>,
) -> Result<ValueInventionResult, ValueInventionError> {
    let det = vi_detect(model_json);
    let mut result = ValueInventionResult {
        vi_var_names: det.vi_var_names.clone(),
        ..Default::default()
    };
    if !det.has_vi {
        return Ok(result);
    }

    let empty = Map::new();
    let index_sets = model_json
        .get("index_sets")
        .and_then(|v| v.as_object())
        .unwrap_or(&empty);
    let variables = model_json
        .get("variables")
        .and_then(|v| v.as_object())
        .unwrap_or(&empty);
    let mut ctx = ViCtx {
        const_arrays,
        params,
        index_sets,
        variables,
        const_array_boundaries,
        maps: HashMap::new(),
    };

    // Cadence classification model (built before materialisation — it depends only
    // on model structure, not materialized values): re-type each map var to its
    // body's class so the §5.7 guard 2 classifies a producer / arg-witness that
    // joins on it correctly (a CONST-derived bin map passes; a genuinely
    // state-dependent one still classifies CONTINUOUS → reject).
    let cls_model = vi_classification_model(model_json, &det.maps)?;

    // §5.7 guard 2 for arg-witness assignments: a state-dependent nearest-generator
    // buffer (continuous cadence) may not be materialised at build time — its
    // topology would change every step (out of scope for v1, like a continuous
    // `distinct`).
    for (vname, node) in &det.maps {
        let is_arg = is_argwitness(node);
        if !is_arg {
            continue;
        }
        let cls = cadence::classify(node, &cls_model)
            .map_err(|e| ValueInventionError(format!("cadence classify failed: {e}")))?;
        if cls == Cadence::Continuous {
            return err(format!(
                "arg-witness map {vname:?} classifies CONTINUOUS — a build-time assignment \
                 buffer's inputs must be CONST/DISCRETE (RFC §5.7 guard 2)"
            ));
        }
    }

    // Maps first (a producer's join / key — or an arg-witness `join` — may reference them).
    for (vname, node) in &det.maps {
        vi_materialize_map(&mut ctx, vname, node)?;
    }

    // Surface the arg-witness buffers (the integer nearest-generator INDEX
    // assignment), dense in output-index order, for byte-identity assertions and
    // the downstream grouped reduction the SCVT step consumes.
    for (vname, node) in &det.maps {
        let is_arg = is_argwitness(node);
        if !is_arg {
            continue;
        }
        let m = &ctx.maps[vname];
        let mut keys: Vec<i64> = m.keys().copied().collect();
        keys.sort_unstable();
        let buf: Vec<i64> = keys
            .iter()
            .map(|k| match m.get(k) {
                Some(Val::Int(i)) => *i,
                _ => 0,
            })
            .collect();
        result.assignments.insert(vname.clone(), buf);
    }

    // The downstream GROUPED / DERIVED chain — the SCVT centroid step. Each buffer
    // is materialised in dependency (fixpoint discovery) order: a grouped semiring
    // reduction keyed on a now-materialised arg-witness buffer (`num[g]`/`den[g]`,
    // through `group_aggregate` — the front-door's first call of that previously
    // library-only helper) and an elementwise derived buffer reading upstream
    // buffers (`centroid[g] = num[g]/den[g]`). Each reads only build-time data
    // (guard 2). All are surfaced dense in output-index order.
    for (vname, node, kind) in &det.chain {
        vi_assert_buildtime(&ctx, vname, node, &det.vi_var_names)?;
        match kind {
            ChainKind::Grouped => vi_materialize_grouped(&mut ctx, vname, node)?,
            ChainKind::Derived => vi_materialize_derived(&mut ctx, vname, node)?,
        }
        let m = &ctx.maps[vname];
        let mut keys: Vec<i64> = m.keys().copied().collect();
        keys.sort_unstable();
        let buf: Vec<f64> = keys
            .iter()
            .map(|k| match m.get(k) {
                Some(Val::Float(f)) => *f,
                Some(Val::Int(i)) => *i as f64,
                _ => 0.0,
            })
            .collect();
        result.groups.insert(vname.clone(), buf);
    }

    // `from_faq` id → derived index-set name (so we only materialise producers a
    // derived set actually names; geometry producers are handled elsewhere).
    let mut faq_to_set: HashMap<String, String> = HashMap::new();
    for (sname, iset) in index_sets {
        if iset.get("kind").and_then(|v| v.as_str()) != Some("derived") {
            continue;
        }
        if let Some(faq) = iset.get("from_faq").and_then(|v| v.as_str()) {
            faq_to_set.insert(faq.to_string(), sname.clone());
        }
    }

    for (_, node) in &det.producers {
        let node_id = node.get("id").and_then(|v| v.as_str()).ok_or_else(|| {
            ValueInventionError(
                "value-invention producer aggregate requires an `id` naming it for `from_faq`"
                    .into(),
            )
        })?;
        if !faq_to_set.contains_key(node_id) {
            continue; // no derived set names this producer
        }
        // §5.7 guard 2: a relational node may not run on the hot path.
        let cls = cadence::classify(node, &cls_model)
            .map_err(|e| ValueInventionError(format!("cadence classify failed: {e}")))?;
        if cls == Cadence::Continuous {
            return err(format!(
                "value-invention producer {node_id:?} classifies CONTINUOUS — it may not run per \
                 step (RFC §5.7 guard 2); its inputs must be CONST/DISCRETE"
            ));
        }
        let mem = vi_materialize_producer(&ctx, node)?;
        result.extents.insert(node_id.to_string(), mem.len() as i64);
        result.members.insert(node_id.to_string(), mem);
    }

    Ok(result)
}

// --------------------------------------------------------------------------- //
// Evaluator integration: rewrite the typed model so derived sets resolve
// --------------------------------------------------------------------------- //

/// Rewrite each typed `kind:"derived"` index set named by a materialised
/// value-invention producer into `kind:"interval"` with `size = n`, so
/// [`crate::aggregate::resolve_aggregate_ranges`] resolves it via the existing
/// interval arm (handing the resolver the dense extent `[1, n]`). Generalises the
/// geometry clip-ring handoff (§8.1) to the relational engine.
pub fn rewrite_derived_index_sets(
    index_sets: &mut HashMap<String, IndexSet>,
    extents: &HashMap<String, i64>,
) {
    for iset in index_sets.values_mut() {
        if iset.kind != "derived" {
            continue;
        }
        let Some(faq) = &iset.from_faq else { continue };
        if let Some(&n) = extents.get(faq) {
            iset.kind = "interval".to_string();
            iset.size = Some(n);
            iset.from_faq = None;
        }
    }
}

/// Drop the value-invention equations (and their LHS variables) from the typed
/// model: the skolem/distinct/rank outputs are materialised at setup, not
/// integrated, so their defining equations must not reach the numeric pipeline
/// (RFC §6.1). A no-op for an empty `vi_var_names`.
pub fn drop_value_invention_equations(model: &mut Model, vi_var_names: &HashSet<String>) {
    if vi_var_names.is_empty() {
        return;
    }
    model.equations.retain(|eq| match lhs_base_typed(&eq.lhs) {
        Some(base) => !vi_var_names.contains(&base),
        None => true,
    });
    if let Some(init) = &mut model.initialization_equations {
        init.retain(|eq| match lhs_base_typed(&eq.lhs) {
            Some(base) => !vi_var_names.contains(&base),
            None => true,
        });
    }
    for name in vi_var_names {
        model.variables.remove(name);
    }
}

/// The combined front-door applied to a typed model: rewrite the derived index
/// sets to their materialised dense extents and drop the value-invention
/// equations. After this the existing resolver / array compiler handles the
/// model with no value-invention-specific path.
///
/// Since v0.8.0 the `index_sets` registry is document-scoped, so it is threaded
/// in (and mutated in place) alongside the model rather than living on it.
pub fn apply_value_invention(
    model: &mut Model,
    index_sets: &mut HashMap<String, IndexSet>,
    result: &ValueInventionResult,
) {
    rewrite_derived_index_sets(index_sets, &result.extents);
    drop_value_invention_equations(model, &result.vi_var_names);
}

// =========================================================================== //
// Value-invention evaluator front-door — conformance (bead ess-3lj.2, F2).
//
// Port-parity counterpart of the Julia reference test
// `value_invention_frontdoor_test.jl` (F1, ess-3lj.1) and the Python
// `test_value_invention_frontdoor.py`. RFC `semiring-faq-unified-ir` §6.1 / §5.5
// / §7.3; `CONFORMANCE_SPEC.md` §5.5 / §5.7.
//
// Two proof cases, both BYTE-IDENTICAL to the landed M3 goldens — the SAME
// canonical index-set JSON the Julia and Python bindings assert, which is what
// makes the value-invention .esm run end-to-end byte-identical across all three:
//   (1) the §7.3 edge-enumeration .esm — `edges` -> [[1,2],[1,3],[2,3],[2,4],[3,4]];
//   (2) the conservative-regridder overlap-join .esm — `candidate_pairs` ->
//       [[1,1],[2,2],[3,3]] via the bin-Skolem equi-join.
// =========================================================================== //

#[cfg(test)]
mod tests {
    use super::*;
    use crate::relational::canonical_index_set_json;

    // The shared M3 goldens — the byte-for-byte canonical index-set JSON every
    // binding (Julia / Rust / Python) must reproduce (§5.5.3).
    const EDGE_GOLDEN: &str = "[[1,2],[1,3],[2,3],[2,4],[3,4]]";
    const CANDIDATE_GOLDEN: &str = "[[1,1],[2,2],[3,3]]";

    const EDGE_FIXTURE: &str =
        include_str!("../../../tests/valid/aggregate/edge_enumeration_area_eff.esm");
    const REGRID_FIXTURE: &str =
        include_str!("../../../tests/valid/geometry/conservative_regrid_overlap_join.esm");

    fn model_json(fixture: &str, model_name: &str) -> Value {
        let doc: Value = serde_json::from_str(fixture).expect("fixture parses");
        let mut model = doc["models"][model_name].clone();
        // v0.8.0: `index_sets` is document-scoped (a sibling of `models`). The
        // JSON value-invention path expects the model view to carry the sets it
        // references, so merge the document registry down (mirrors
        // `cadence::model_with_loaders`).
        if let (Value::Object(m), Some(is)) = (&mut model, doc.get("index_sets")) {
            m.entry("index_sets".to_string())
                .or_insert_with(|| is.clone());
        }
        model
    }

    fn arr(shape: &[usize], data: Vec<f64>) -> ArrayD<f64> {
        ArrayD::from_shape_vec(IxDyn(shape), data).expect("shape matches data")
    }

    fn ca(pairs: Vec<(&str, ArrayD<f64>)>) -> HashMap<String, ArrayD<f64>> {
        pairs.into_iter().map(|(k, v)| (k.to_string(), v)).collect()
    }

    fn params(pairs: &[(&str, f64)]) -> HashMap<String, f64> {
        pairs.iter().map(|(k, v)| (k.to_string(), *v)).collect()
    }

    /// The default empty per-const-array boundary map (throw-on-OOB everywhere).
    fn no_bounds() -> HashMap<String, Vec<BoundaryKind>> {
        HashMap::new()
    }

    fn bounds(pairs: Vec<(&str, Vec<BoundaryKind>)>) -> HashMap<String, Vec<BoundaryKind>> {
        pairs.into_iter().map(|(k, v)| (k.to_string(), v)).collect()
    }

    fn sorted(set: &HashSet<String>) -> Vec<String> {
        let mut v: Vec<String> = set.iter().cloned().collect();
        v.sort();
        v
    }

    fn k(i: i64, j: i64) -> Key {
        Key::Tuple(vec![Key::Int(i), Key::Int(j)])
    }

    /// A `skolem` node's leading arg used to be overloaded: a leading STRING was
    /// stripped as a relation tag, so a mistyped key component could silently
    /// vanish. The tag now lives in the dedicated `label` field (documentary
    /// only), and EVERY arg is a pure key component — a non-integer arg fails
    /// closed instead of masquerading as a tag.
    #[test]
    fn skolem_label_is_documentary_and_typo_fails_closed() {
        let const_arrays: HashMap<String, ArrayD<f64>> = HashMap::new();
        let params: HashMap<String, f64> = HashMap::new();
        let empty = Map::new();
        let no_bnds = no_bounds();
        let ctx = ViCtx {
            const_arrays: &const_arrays,
            params: &params,
            index_sets: &empty,
            variables: &empty,
            const_array_boundaries: &no_bnds,
            maps: HashMap::new(),
        };
        // `a`, `b` are bound range symbols (integer IDs).
        let bindings: Bindings = [("a".to_string(), 1), ("b".to_string(), 2)]
            .into_iter()
            .collect();

        // A documentary `label:"edge"` is ignored for key construction: the key
        // is exactly the `(a, b)` tuple — byte-identical to the pre-`label`
        // behaviour where the tag was a stripped leading string arg.
        let tagged = serde_json::json!({
            "op": "skolem",
            "label": "edge",
            "args": ["a", "b"],
        });
        assert_eq!(vi_skolem(&tagged, &ctx, &bindings).unwrap(), k(1, 2));

        // A `skolem` with no label produces the same key from the same args.
        let untagged = serde_json::json!({"op": "skolem", "args": ["a", "b"]});
        assert_eq!(vi_skolem(&untagged, &ctx, &bindings).unwrap(), k(1, 2));

        // A mistyped leading arg (`"aa"` instead of the bound `"a"`) is NOT a
        // valid key component. It once masqueraded as a stripped tag; now it
        // fails closed via `key_int`.
        let typo = serde_json::json!({"op": "skolem", "args": ["aa", "b"]});
        let e = vi_skolem(&typo, &ctx, &bindings).unwrap_err();
        assert!(
            e.0.contains("non-numeric key component"),
            "unexpected error message: {}",
            e.0
        );
    }

    #[test]
    fn edge_enumeration_materializes_to_m3_golden() {
        let mj = model_json(EDGE_FIXTURE, "EdgeEnumerationAreaEff");
        // Canonical 2-triangle mesh connectivity (the ragged face_vertices factors).
        let const_arrays = ca(vec![
            ("n_verts_on_face", arr(&[2], vec![3.0, 3.0])),
            (
                "verts_on_face",
                arr(&[2, 3], vec![1.0, 2.0, 3.0, 2.0, 3.0, 4.0]),
            ),
            ("n_edges_on_cell", arr(&[2], vec![3.0, 3.0])),
            (
                "edges_on_cell",
                arr(&[2, 3], vec![1.0, 2.0, 3.0, 3.0, 4.0, 5.0]),
            ),
            ("dc", arr(&[5], vec![2.0, 3.0, 5.0, 7.0, 11.0])),
            ("dv", arr(&[5], vec![13.0, 17.0, 19.0, 23.0, 29.0])),
        ]);
        let vi =
            materialize_value_invention(&mj, &const_arrays, &HashMap::new(), &no_bounds()).unwrap();

        // The derived `edges` set materializes via the relational engine,
        // BYTE-IDENTICAL to the M3 determinism golden.
        assert_eq!(vi.extents["edge_set"], 5);
        let edges = &vi.members["edge_set"];
        assert_eq!(*edges, vec![k(1, 2), k(1, 3), k(2, 3), k(2, 4), k(3, 4)]);
        assert_eq!(canonical_index_set_json(edges), EDGE_GOLDEN);
        // the skolem/rank LHS vars are dropped from the ODE (materialized at setup).
        assert_eq!(
            sorted(&vi.vi_var_names),
            vec!["edge_dense_id", "edge_exists"]
        );
    }

    #[test]
    fn edge_enumeration_adversarial_inputs_collapse_to_golden() {
        // §5.5.4: reversed winding yields the identical canonically-sorted edge set.
        let mj = model_json(EDGE_FIXTURE, "EdgeEnumerationAreaEff");
        let base = ca(vec![
            ("n_verts_on_face", arr(&[2], vec![3.0, 3.0])),
            (
                "verts_on_face",
                arr(&[2, 3], vec![1.0, 2.0, 3.0, 2.0, 3.0, 4.0]),
            ),
        ]);
        let rev = ca(vec![
            ("n_verts_on_face", arr(&[2], vec![3.0, 3.0])),
            (
                "verts_on_face",
                arr(&[2, 3], vec![3.0, 2.0, 1.0, 4.0, 3.0, 2.0]),
            ),
        ]);
        for const_arrays in [base, rev] {
            let vi = materialize_value_invention(&mj, &const_arrays, &HashMap::new(), &no_bounds())
                .unwrap();
            assert_eq!(
                canonical_index_set_json(&vi.members["edge_set"]),
                EDGE_GOLDEN
            );
        }
    }

    #[test]
    fn regridder_candidate_set_bin_skolem_equijoin() {
        let mj = model_json(REGRID_FIXTURE, "ConservativeRegridOverlapJoin");
        let p = params(&[("dx", 1.0), ("dy", 1.0), ("atol", 1e-12)]);

        // Aligned grids: src/tgt cell i share bin (i-1, 0) ⇒ diagonal candidate set.
        let aligned = ca(vec![
            ("src_lon", arr(&[3], vec![0.2, 1.2, 2.2])),
            ("src_lat", arr(&[3], vec![0.0, 0.0, 0.0])),
            ("tgt_lon", arr(&[3], vec![0.2, 1.2, 2.2])),
            ("tgt_lat", arr(&[3], vec![0.0, 0.0, 0.0])),
        ]);
        let vi = materialize_value_invention(&mj, &aligned, &p, &no_bounds()).unwrap();
        assert_eq!(vi.members["candidate_set"], vec![k(1, 1), k(2, 2), k(3, 3)]);
        assert_eq!(vi.extents["candidate_set"], 3);
        assert_eq!(
            canonical_index_set_json(&vi.members["candidate_set"]),
            CANDIDATE_GOLDEN
        );
        assert_eq!(
            sorted(&vi.vi_var_names),
            vec!["pair_exists", "src_bin", "tgt_bin"]
        );

        // Shifted target grid: only the overlapping bins join (broad phase is
        // load-bearing — NOT the full cross product).
        let shifted = ca(vec![
            ("src_lon", arr(&[3], vec![0.2, 1.2, 2.2])),
            ("src_lat", arr(&[3], vec![0.0, 0.0, 0.0])),
            ("tgt_lon", arr(&[3], vec![1.2, 2.2, 9.9])),
            ("tgt_lat", arr(&[3], vec![0.0, 0.0, 0.0])),
        ]);
        let vi2 = materialize_value_invention(&mj, &shifted, &p, &no_bounds()).unwrap();
        assert_eq!(vi2.members["candidate_set"], vec![k(2, 1), k(3, 2)]);
    }

    #[test]
    fn resolver_resolves_derived_set_after_rewrite() {
        // The evaluator integration: WITHOUT the front-door, the resolver rejects
        // the `rank` eq's derived OUTPUT index `e` over `edges`; WITH the rewrite
        // (edges -> interval[1,5]) it resolves cleanly.
        let mj = model_json(EDGE_FIXTURE, "EdgeEnumerationAreaEff");
        let const_arrays = ca(vec![
            ("n_verts_on_face", arr(&[2], vec![3.0, 3.0])),
            (
                "verts_on_face",
                arr(&[2, 3], vec![1.0, 2.0, 3.0, 2.0, 3.0, 4.0]),
            ),
        ]);
        let vi =
            materialize_value_invention(&mj, &const_arrays, &HashMap::new(), &no_bounds()).unwrap();

        let file = crate::parse::load(EDGE_FIXTURE).expect("fixture loads");
        // v0.8.0: the `index_sets` registry is document-scoped, so it is threaded
        // in and rewritten in place rather than living on the model.
        let mut registry = file
            .index_sets
            .clone()
            .expect("fixture declares index_sets");
        let model = file
            .models
            .as_ref()
            .unwrap()
            .get("EdgeEnumerationAreaEff")
            .unwrap();

        // Without the rewrite: the derived output index is rejected.
        assert!(crate::aggregate::resolve_aggregate_ranges(&mut model.clone(), &registry).is_err());

        // With the rewrite: the derived `edges` set resolves to the dense [1, 5].
        rewrite_derived_index_sets(&mut registry, &vi.extents);
        let edges = registry.get("edges").unwrap();
        assert_eq!(edges.kind, "interval");
        assert_eq!(edges.size, Some(5));
        assert!(crate::aggregate::resolve_aggregate_ranges(&mut model.clone(), &registry).is_ok());
    }

    #[test]
    fn continuous_relational_node_is_rejected() {
        // §5.7 guard 2: a distinct producer whose key reads a genuine state
        // variable classifies CONTINUOUS and must be refused.
        let model: Value = serde_json::json!({
            "index_sets": {
                "items": {"kind": "interval", "size": 2},
                "tags": {"kind": "derived", "from_faq": "tag_set"}
            },
            "variables": {
                "u": {"type": "state", "shape": ["items"]},
                "tag": {"type": "state", "shape": ["tags"]}
            },
            "equations": [{
                "lhs": {"op": "index", "args": ["tag", "p"]},
                "rhs": {
                    "op": "aggregate", "id": "tag_set", "semiring": "bool_and_or",
                    "distinct": true, "output_idx": ["p"],
                    "ranges": {"i": {"from": "items"}},
                    "key": {"op": "skolem", "args": ["t", {"op": "index", "args": ["u", "i"]}]},
                    "expr": {"op": "true", "args": []}
                }
            }]
        });
        let const_arrays = ca(vec![("u", arr(&[2], vec![1.0, 2.0]))]);
        assert!(
            materialize_value_invention(&model, &const_arrays, &HashMap::new(), &no_bounds())
                .is_err()
        );
    }

    #[test]
    fn no_op_for_plain_model() {
        let plain: Value = serde_json::json!({
            "variables": {"x": {"type": "state", "shape": []}},
            "equations": [{"lhs": {"op": "D", "args": ["x"], "wrt": "t"}, "rhs": -1.0}]
        });
        let vi =
            materialize_value_invention(&plain, &HashMap::new(), &HashMap::new(), &no_bounds())
                .unwrap();
        assert!(vi.extents.is_empty());
        assert!(vi.vi_var_names.is_empty());
        assert!(vi.assignments.is_empty());
    }

    // ── Arg-witness reducer (bead ess-os1, §5.7 rule 6) ──────────────────────
    // The integer nearest-generator INDEX buffer, byte-identical to the Julia /
    // Python port-parity tests: the SAME coordinate factors → the SAME buffer.

    const ARGMIN_FIXTURE: &str =
        include_str!("../../../tests/valid/aggregate/nearest_generator_argmin.esm");

    #[test]
    fn argmin_nearest_generator_smallest_id_tiebreak() {
        let mj = model_json(ARGMIN_FIXTURE, "NearestGeneratorArgmin");
        // Generators on the x-axis at 0,1,2; point 3 (1.5,0) is EXACTLY 0.25 from
        // generators 2 (1.0) and 3 (2.0) — the deliberate equidistant tie.
        let const_arrays = ca(vec![
            ("gx", arr(&[3], vec![0.0, 1.0, 2.0])),
            ("gy", arr(&[3], vec![0.0, 0.0, 0.0])),
            ("px", arr(&[4], vec![0.0, 1.0, 1.5, 2.0])),
            ("py", arr(&[4], vec![0.0, 0.5, 0.0, 0.0])),
        ]);
        let vi =
            materialize_value_invention(&mj, &const_arrays, &HashMap::new(), &no_bounds()).unwrap();
        // 1-based nearest-generator ids; the tie at point 3 → the SMALLER id (2).
        assert_eq!(vi.assignments["assign"], vec![1, 2, 2, 3]);
        assert_eq!(sorted(&vi.vi_var_names), vec!["assign"]);
        assert!(vi.extents.is_empty());
    }

    #[test]
    fn argmin_binned_same_bin_candidate_join() {
        let mj = model_json(ARGMIN_FIXTURE, "NearestGeneratorBinned");
        let p = params(&[("binw", 1.0)]);
        // binw=1 ⇒ each point's join keeps only its same-bin generator → [1,2,3,2].
        let const_arrays = ca(vec![
            ("gx", arr(&[3], vec![0.0, 1.0, 2.0])),
            ("gy", arr(&[3], vec![0.0, 0.0, 0.0])),
            ("px", arr(&[4], vec![0.1, 1.1, 2.1, 1.9])),
            ("py", arr(&[4], vec![0.0, 0.0, 0.0, 0.0])),
        ]);
        let vi = materialize_value_invention(&mj, &const_arrays, &p, &no_bounds()).unwrap();
        assert_eq!(vi.assignments["assign_binned"], vec![1, 2, 3, 2]);
        assert_eq!(
            sorted(&vi.vi_var_names),
            vec!["assign_binned", "gen_bin", "point_bin"]
        );
    }

    #[test]
    fn argmax_farthest_generator_smallest_id_tiebreak() {
        // Mirror op: argmax keeps the GREATEST distance. Point 2 (1.0) is dist 1
        // from both generator 1 (0.0) and generator 3 (2.0) → tie to the SMALLER id.
        let model: Value = serde_json::json!({
            "index_sets": {
                "points": {"kind": "interval", "size": 2},
                "generators": {"kind": "interval", "size": 3}
            },
            "variables": {
                "gx": {"type": "parameter", "shape": ["generators"]},
                "px": {"type": "parameter", "shape": ["points"]},
                "far": {"type": "state", "shape": ["points"]}
            },
            "equations": [{
                "lhs": {"op": "index", "args": ["far", "i"]},
                "rhs": {"op": "aggregate", "output_idx": ["i"],
                    "ranges": {"i": {"from": "points"}},
                    "expr": {"op": "argmax", "arg": "g",
                        "ranges": {"g": {"from": "generators"}},
                        "expr": {"op": "*", "args": [
                            {"op": "-", "args": [{"op": "index", "args": ["px", "i"]}, {"op": "index", "args": ["gx", "g"]}]},
                            {"op": "-", "args": [{"op": "index", "args": ["px", "i"]}, {"op": "index", "args": ["gx", "g"]}]}
                        ]}
                    }
                }
            }]
        });
        let const_arrays = ca(vec![
            ("gx", arr(&[3], vec![0.0, 1.0, 2.0])),
            ("px", arr(&[2], vec![0.0, 1.0])),
        ]);
        let vi = materialize_value_invention(&model, &const_arrays, &HashMap::new(), &no_bounds())
            .unwrap();
        assert_eq!(vi.assignments["far"], vec![3, 1]);
    }

    #[test]
    fn argmin_empty_candidate_set_is_error() {
        // A filter that excludes every candidate leaves the argmin undefined.
        let model: Value = serde_json::json!({
            "index_sets": {
                "points": {"kind": "interval", "size": 1},
                "generators": {"kind": "interval", "size": 2}
            },
            "variables": {
                "gx": {"type": "parameter", "shape": ["generators"]},
                "px": {"type": "parameter", "shape": ["points"]},
                "assign": {"type": "state", "shape": ["points"]}
            },
            "equations": [{
                "lhs": {"op": "index", "args": ["assign", "i"]},
                "rhs": {"op": "aggregate", "output_idx": ["i"],
                    "ranges": {"i": {"from": "points"}},
                    "expr": {"op": "argmin", "arg": "g",
                        "ranges": {"g": {"from": "generators"}},
                        "filter": {"op": "false", "args": []},
                        "expr": {"op": "*", "args": [
                            {"op": "index", "args": ["gx", "g"]}, {"op": "index", "args": ["gx", "g"]}]}
                    }
                }
            }]
        });
        let const_arrays = ca(vec![
            ("gx", arr(&[2], vec![0.0, 1.0])),
            ("px", arr(&[1], vec![0.5])),
        ]);
        assert!(
            materialize_value_invention(&model, &const_arrays, &HashMap::new(), &no_bounds())
                .is_err()
        );
    }

    #[test]
    fn argmin_continuous_assignment_is_rejected() {
        // §5.7 guard 2: an argmin whose distance reads a genuine `state` coordinate
        // classifies CONTINUOUS — a per-step assignment is out of scope for v1.
        let model: Value = serde_json::json!({
            "index_sets": {
                "points": {"kind": "interval", "size": 1},
                "generators": {"kind": "interval", "size": 2}
            },
            "variables": {
                "gx": {"type": "state", "shape": ["generators"]},
                "px": {"type": "parameter", "shape": ["points"]},
                "assign": {"type": "state", "shape": ["points"]}
            },
            "equations": [{
                "lhs": {"op": "index", "args": ["assign", "i"]},
                "rhs": {"op": "aggregate", "output_idx": ["i"],
                    "ranges": {"i": {"from": "points"}},
                    "expr": {"op": "argmin", "arg": "g",
                        "ranges": {"g": {"from": "generators"}},
                        "expr": {"op": "*", "args": [
                            {"op": "index", "args": ["gx", "g"]}, {"op": "index", "args": ["gx", "g"]}]}
                    }
                }
            }]
        });
        let const_arrays = ca(vec![
            ("gx", arr(&[2], vec![0.0, 1.0])),
            ("px", arr(&[1], vec![0.5])),
        ]);
        assert!(
            materialize_value_invention(&model, &const_arrays, &HashMap::new(), &no_bounds())
                .is_err()
        );
    }

    // ----------------------------------------------------------------------- //
    // Const-array boundary policy (bead ess-gj4) — port-parity counterpart of
    // the Julia `tree_walk_const_array_boundary_test.jl`. A `vi_index` gather at
    // an out-of-range 1-based index resolves declaratively per the dimension's
    // declared `BoundaryKind` instead of panicking; an undeclared policy errors.
    //
    // Numeric reference mirrors the Julia test for M = [10, 20, 30, 40]:
    //   clamp(index 5)  = M[4] = 40   (edge-extend)
    //   periodic(index 5) = M[1] = 10 (mod1(5,4) = 1)
    //   periodic(index 0) = M[4] = 40 (mod1(0,4) = 4)
    // ----------------------------------------------------------------------- //

    /// Gather `index(name, one_based)` against a 1-D const array under `bnds`.
    fn gather_1d(
        name: &str,
        data: &ArrayD<f64>,
        one_based: i64,
        bnds: &HashMap<String, Vec<BoundaryKind>>,
    ) -> Result<f64, ValueInventionError> {
        let const_arrays = ca(vec![(name, data.clone())]);
        let params: HashMap<String, f64> = HashMap::new();
        let empty = Map::new();
        let ctx = ViCtx {
            const_arrays: &const_arrays,
            params: &params,
            index_sets: &empty,
            variables: &empty,
            const_array_boundaries: bnds,
            maps: HashMap::new(),
        };
        let node = serde_json::json!({"op": "index", "args": [name, one_based]});
        match vi_index(&node, &ctx, &HashMap::new())? {
            Val::Float(f) => Ok(f),
            other => panic!("expected Float gather, got {other:?}"),
        }
    }

    #[test]
    fn const_array_in_range_gather_unchanged() {
        // In-range gathers are byte-identical to the prior `arr[(i-1)]` behavior,
        // independent of any declared policy.
        let m = arr(&[4], vec![10.0, 20.0, 30.0, 40.0]);
        let clamp = bounds(vec![("M", vec![BoundaryKind::Clamp])]);
        for (i, want) in [(1, 10.0), (2, 20.0), (3, 30.0), (4, 40.0)] {
            assert_eq!(gather_1d("M", &m, i, &no_bounds()).unwrap(), want);
            assert_eq!(gather_1d("M", &m, i, &clamp).unwrap(), want);
        }
    }

    #[test]
    fn const_array_clamp_edge_extends() {
        // clamp: low OOB -> first element, high OOB -> last element.
        let m = arr(&[4], vec![10.0, 20.0, 30.0, 40.0]);
        let clamp = bounds(vec![("M", vec![BoundaryKind::Clamp])]);
        assert_eq!(gather_1d("M", &m, 0, &clamp).unwrap(), 10.0); // clamp(0) -> M[1]
        assert_eq!(gather_1d("M", &m, -3, &clamp).unwrap(), 10.0); // clamp(-3) -> M[1]
        assert_eq!(gather_1d("M", &m, 5, &clamp).unwrap(), 40.0); // clamp(5) -> M[4]
        assert_eq!(gather_1d("M", &m, 99, &clamp).unwrap(), 40.0); // clamp(99) -> M[4]
    }

    #[test]
    fn const_array_periodic_wraps() {
        // periodic: size 4: index 5 -> element 1 (10), index 0 -> element 4 (40).
        let m = arr(&[4], vec![10.0, 20.0, 30.0, 40.0]);
        let per = bounds(vec![("M", vec![BoundaryKind::Periodic])]);
        assert_eq!(gather_1d("M", &m, 5, &per).unwrap(), 10.0); // mod1(5,4) = 1
        assert_eq!(gather_1d("M", &m, 0, &per).unwrap(), 40.0); // mod1(0,4) = 4
        assert_eq!(gather_1d("M", &m, -1, &per).unwrap(), 30.0); // mod1(-1,4) = 3
        assert_eq!(gather_1d("M", &m, 9, &per).unwrap(), 10.0); // mod1(9,4) = 1
    }

    #[test]
    fn const_array_no_policy_errors_not_panics() {
        // No declared policy (and explicit Error) -> structured Err, never a panic.
        let m = arr(&[4], vec![10.0, 20.0, 30.0, 40.0]);
        let err_pol = bounds(vec![("M", vec![BoundaryKind::Error])]);
        for bnds in [&no_bounds(), &err_pol] {
            let e = gather_1d("M", &m, 5, bnds).unwrap_err();
            assert!(
                e.0.contains("const array 'M' index 5 out of range 1..4 in dim 0"),
                "unexpected error message: {}",
                e.0
            );
            assert!(gather_1d("M", &m, 0, bnds).is_err());
        }
    }

    #[test]
    fn const_array_empty_dim_errors_under_any_policy() {
        // An empty dimension (n == 0) can never wrap/clamp into a valid index.
        let m = ArrayD::from_shape_vec(IxDyn(&[0]), Vec::<f64>::new()).unwrap();
        for kind in [
            BoundaryKind::Periodic,
            BoundaryKind::Clamp,
            BoundaryKind::Error,
        ] {
            let bnds = bounds(vec![("M", vec![kind])]);
            assert!(gather_1d("M", &m, 1, &bnds).is_err());
        }
    }

    #[test]
    fn const_array_2d_mixed_policy_resolves_per_dim() {
        // 2D row-major array, shape [2, 3] (dim 0 clamp, dim 1 periodic):
        //   [[1, 2, 3],
        //    [4, 5, 6]]
        let m = arr(&[2, 3], vec![1.0, 2.0, 3.0, 4.0, 5.0, 6.0]);
        let mixed = bounds(vec![(
            "M",
            vec![BoundaryKind::Clamp, BoundaryKind::Periodic],
        )]);
        let const_arrays = ca(vec![("M", m)]);
        let params: HashMap<String, f64> = HashMap::new();
        let empty = Map::new();
        let ctx = ViCtx {
            const_arrays: &const_arrays,
            params: &params,
            index_sets: &empty,
            variables: &empty,
            const_array_boundaries: &mixed,
            maps: HashMap::new(),
        };
        let gather = |i: i64, j: i64| -> Result<f64, ValueInventionError> {
            let node = serde_json::json!({"op": "index", "args": ["M", i, j]});
            match vi_index(&node, &ctx, &HashMap::new())? {
                Val::Float(f) => Ok(f),
                other => panic!("expected Float, got {other:?}"),
            }
        };
        // in range
        assert_eq!(gather(1, 1).unwrap(), 1.0);
        assert_eq!(gather(2, 3).unwrap(), 6.0);
        // dim 0 clamp: row 0 -> row 1, row 3 -> row 2.
        assert_eq!(gather(0, 1).unwrap(), 1.0); // clamp dim0 -> (1,1)
        assert_eq!(gather(5, 2).unwrap(), 5.0); // clamp dim0 -> (2,2)
        // dim 1 periodic: col 4 -> col 1, col 0 -> col 3.
        assert_eq!(gather(1, 4).unwrap(), 1.0); // mod1(4,3) = 1 -> (1,1)
        assert_eq!(gather(2, 0).unwrap(), 6.0); // mod1(0,3) = 3 -> (2,3)
        // both dims out of range, each resolved by its own policy.
        assert_eq!(gather(9, 4).unwrap(), 4.0); // clamp dim0 -> 2, mod1(4,3) -> 1 => (2,1)
    }

    // ── Grouped-aggregate centroid front-door (bead ess-2u5, mpas-scvt) ──────
    // The SCVT centroid-update STEP: grouped `sum_product` reductions whose group
    // KEY is the data-dependent argmin assignment buffer (E1, ess-os1), run
    // through `group_aggregate` (a library helper only — never the front-door —
    // until now). The fixture factors here are IDENTICAL to the Julia / Python
    // port-parity tests; agreement on num / den / centroid IS the conformance proof.
    const CENTROID_FIXTURE: &str =
        include_str!("../../../tests/valid/aggregate/nearest_generator_centroid.esm");

    #[test]
    fn centroid_group_aggregate_over_argmin_key() {
        let mj = model_json(CENTROID_FIXTURE, "NearestGeneratorCentroid");
        // Generators at 0,1,2; points at 0,0.75,1.25,2.0 (exact dyadics, no ties)
        // ⇒ assign = [1,2,2,3]; density rho = [1,1,3,4]. Generator 2 owns points
        // 2,3 ⇒ centroid 4.5/4 = 1.125 (moved from its seed at 1.0).
        let const_arrays = ca(vec![
            ("gx", arr(&[3], vec![0.0, 1.0, 2.0])),
            ("px", arr(&[4], vec![0.0, 0.75, 1.25, 2.0])),
            ("rho", arr(&[4], vec![1.0, 1.0, 3.0, 4.0])),
        ]);
        let vi =
            materialize_value_invention(&mj, &const_arrays, &HashMap::new(), &no_bounds()).unwrap();
        // The argmin group key (E1) — byte-identical integer buffer.
        assert_eq!(vi.assignments["assign"], vec![1, 2, 2, 3]);
        // The grouped sum_product buffers — bit-exact (exact-dyadic inputs).
        assert_eq!(vi.groups["num"], vec![0.0, 4.5, 8.0]);
        assert_eq!(vi.groups["den"], vec![1.0, 4.0, 4.0]);
        // The derived centroid buffer — the next Lloyd / SCVT generator positions.
        assert_eq!(vi.groups["centroid"], vec![0.0, 1.125, 2.0]);
        // assign + the three grouped/derived buffers all leave the ODE.
        assert_eq!(
            sorted(&vi.vi_var_names),
            vec!["assign", "centroid", "den", "num"]
        );
    }

    #[test]
    fn centroid_empty_group_folds_to_zerobar() {
        // Every point next to generator 1 ⇒ assign = [1,1,1,1]; generators 2,3 own
        // no point, so num/den there are the empty-⊕ identity 0 and centroid is NaN.
        let mj = model_json(CENTROID_FIXTURE, "NearestGeneratorCentroid");
        let const_arrays = ca(vec![
            ("gx", arr(&[3], vec![0.0, 1.0, 2.0])),
            ("px", arr(&[4], vec![0.0, 0.1, 0.2, 0.3])),
            ("rho", arr(&[4], vec![2.0, 1.0, 1.0, 1.0])),
        ]);
        let vi =
            materialize_value_invention(&mj, &const_arrays, &HashMap::new(), &no_bounds()).unwrap();
        assert_eq!(vi.assignments["assign"], vec![1, 1, 1, 1]);
        assert_eq!(vi.groups["den"], vec![5.0, 0.0, 0.0]);
        assert_eq!(vi.groups["num"][1], 0.0);
        assert_eq!(vi.groups["num"][2], 0.0);
        assert!(vi.groups["centroid"][1].is_nan());
        assert!(vi.groups["centroid"][2].is_nan());
    }

    #[test]
    fn regridder_aggregates_are_not_grouped_value_invention() {
        // Regression guard (ess-2u5): the conservative regridder's `A_j` joins two
        // bin buffers to EACH OTHER (neither to its output index `j`) and `mass_tgt`
        // is a scalar reduction — neither is the SCVT grouped/derived centroid shape,
        // so the chain must stay empty and they remain on the simulate path.
        let mj = model_json(REGRID_FIXTURE, "ConservativeRegridOverlapJoin");
        let p = params(&[("dx", 1.0), ("dy", 1.0), ("atol", 1e-12)]);
        let aligned = ca(vec![
            ("src_lon", arr(&[3], vec![0.2, 1.2, 2.2])),
            ("src_lat", arr(&[3], vec![0.0, 0.0, 0.0])),
            ("tgt_lon", arr(&[3], vec![0.2, 1.2, 2.2])),
            ("tgt_lat", arr(&[3], vec![0.0, 0.0, 0.0])),
        ]);
        let vi = materialize_value_invention(&mj, &aligned, &p, &no_bounds()).unwrap();
        assert!(
            vi.groups.is_empty(),
            "regridder must mint no grouped buffers"
        );
        assert!(!vi.vi_var_names.contains("A_j"));
        assert!(!vi.vi_var_names.contains("mass_tgt"));
    }

    #[test]
    fn centroid_grouped_reduction_reading_state_is_rejected() {
        // §5.7 guard 2: `rho` retyped to `state` ⇒ the grouped numerator reads a
        // hot-path quantity; a build-time reduction's inputs must be CONST/DISCRETE.
        let model: Value = serde_json::json!({
            "index_sets": {
                "points": {"kind": "interval", "size": 2},
                "generators": {"kind": "interval", "size": 1}
            },
            "variables": {
                "gx": {"type": "parameter", "shape": ["generators"]},
                "px": {"type": "parameter", "shape": ["points"]},
                "rho": {"type": "state", "shape": ["points"]},
                "assign": {"type": "state", "shape": ["points"]},
                "num": {"type": "state", "shape": ["generators"]}
            },
            "equations": [
                {"lhs": {"op": "index", "args": ["assign", "i"]},
                 "rhs": {"op": "aggregate", "output_idx": ["i"], "ranges": {"i": {"from": "points"}},
                    "args": ["px", "gx"],
                    "expr": {"op": "argmin", "args": ["px", "gx"], "arg": "g",
                        "ranges": {"g": {"from": "generators"}},
                        "expr": {"op": "*", "args": [
                            {"op": "-", "args": [{"op": "index", "args": ["px", "i"]}, {"op": "index", "args": ["gx", "g"]}]},
                            {"op": "-", "args": [{"op": "index", "args": ["px", "i"]}, {"op": "index", "args": ["gx", "g"]}]}]}}}},
                {"lhs": {"op": "index", "args": ["num", "g"]},
                 "rhs": {"op": "aggregate", "output_idx": ["g"],
                    "ranges": {"g": {"from": "generators"}, "p": {"from": "points"}},
                    "semiring": "sum_product", "join": [{"on": [["assign", "g"]]}],
                    "args": ["assign", "rho"],
                    "expr": {"op": "index", "args": ["rho", "p"]}}}
            ]
        });
        let const_arrays = ca(vec![
            ("gx", arr(&[1], vec![0.0])),
            ("px", arr(&[2], vec![0.0, 1.0])),
        ]);
        assert!(
            materialize_value_invention(&model, &const_arrays, &HashMap::new(), &no_bounds())
                .is_err()
        );
    }
}
