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
//! aggregate (a `faq` with `distinct:true`) is materialised here, ONCE at
//! setup, off the per-step hot path — the §6.1 CONST/DISCRETE materialisation
//! point. The aggregate's scalar integer keys (a `lib/relational.esm` key
//! template, a bare `index`, `floor(...)`) are evaluated over the build-time
//! const-array factors and run through the [`crate::relational`] engine
//! (`distinct`, §5.5 determinism); the
//! distinct set's cardinality is handed to the index-set resolver as the dense
//! extent `[1, n]`. Concretely, [`apply_value_invention`] rewrites the typed
//! model's `kind:"derived"` set into `kind:"interval"` with `size = n`, so
//! [`crate::faq::resolve_aggregate_ranges`] resolves it via the existing
//! interval arm (a derived **output** index is otherwise rejected, since a data-dependent extent cannot size an output
//! array). The value-invention outputs are dropped from the ODE.
//!
//! The pass runs on the **raw `serde_json::Value`** model document, not the
//! typed `Model`: the typed `ExpressionNode` drops the aggregate `key` /
//! `distinct` fields (mirroring [`crate::cadence`], which walks raw JSON for the
//! same reason). The materialised members are **byte-identical** across the
//! Julia / Rust / Python bindings (the M3 determinism goldens) because the
//! members are emitted in §5.5.1 sorted total order.

use std::collections::{HashMap, HashSet};

use ndarray::{ArrayD, IxDyn};
use serde_json::{Map, Value};

use crate::broad_phase::OverlapIndex;
use crate::cadence::{self, Cadence};
use crate::relational::{self, Key};
use crate::types::{Expr, IndexSet, Model};

/// A value-invention build-time materialisation error (the Rust analog of
/// Julia's `TreeWalkError` value-invention codes).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ValueInventionError {
    /// What went wrong.
    pub message: String,
    /// The diagnostic code, when the error carries one
    /// (`value_invention_key_out_of_range`).
    pub code: Option<&'static str>,
}

impl ValueInventionError {
    /// An error with no diagnostic code of its own.
    pub fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
            code: None,
        }
    }

    /// An error carrying the diagnostic `code`.
    pub fn with_code(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
            code: Some(code),
        }
    }
}

impl std::fmt::Display for ValueInventionError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self.code {
            Some(code) => write!(f, "ValueInventionError: {code}: {}", self.message),
            None => write!(f, "ValueInventionError: {}", self.message),
        }
    }
}

impl std::error::Error for ValueInventionError {}

fn err<T>(msg: impl Into<String>) -> Result<T, ValueInventionError> {
    Err(ValueInventionError::new(msg))
}

/// Per-dimension boundary policy for an out-of-range const-array stencil gather
/// Mirrors the Julia `_CONST_BOUNDARY_KINDS` (`:periodic` /
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
/// - `vi_var_names` — value-invention LHS vars to drop from the ODE.
#[derive(Debug, Clone, Default)]
pub struct ValueInventionResult {
    pub extents: HashMap<String, i64>,
    pub members: HashMap<String, Vec<Key>>,
    pub vi_var_names: HashSet<String>,
}

// --------------------------------------------------------------------------- //
// Intermediate build-time value
// --------------------------------------------------------------------------- //

/// A build-time value produced by [`vi_eval`]: an int / float / bool / name,
/// depending on the op.
#[derive(Debug, Clone, PartialEq)]
enum Val {
    Bool(bool),
    Int(i64),
    Float(f64),
    Str(String),
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
    Exclude,
    None,
}

/// Is this assignment a VALUE-INVENTION output rather than an ordinary
/// observed definition?
///
/// True for every node [`vi_node_kind`] recognises — a `distinct` producer and
/// a `distinct` body — because both leave the ODE and are materialized by this
/// engine, never by the array evaluator.
///
/// Public because esm 1.0.0 made the question reachable from outside. Before
/// it, a producer lived in `equations` while an ordinary observed definition
/// lived in `variables[..].expression`, so the two were told apart by WHICH
/// FIELD they sat in. Now both are equations with a bare-variable LHS and the
/// node is the only thing that distinguishes them, so the test has to be
/// shared rather than re-guessed by each consumer (`crate::prepare`'s
/// `observed_defs` is the first).
pub fn is_value_invention_assignment(rhs: &Value) -> bool {
    vi_node_kind(rhs) != NodeKind::None
}

fn vi_node_kind(node: &Value) -> NodeKind {
    let Some(map) = obj(node) else {
        return NodeKind::None;
    };
    if map.get("op").and_then(|v| v.as_str()) != Some("faq") {
        return NodeKind::None;
    }
    if map.get("distinct").and_then(|v| v.as_bool()) == Some(true) {
        return NodeKind::Producer;
    }
    if map
        .get("expr")
        .and_then(|b| b.get("op"))
        .and_then(|v| v.as_str())
        == Some("distinct")
    {
        return NodeKind::Exclude;
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

struct Detection {
    has_vi: bool,
    vi_var_names: HashSet<String>,
    producers: Vec<(String, Value)>,
    /// Plain numeric aggregates — `join` column candidates.
    candidates: Vec<(String, Value)>,
    /// Plain per-element columns a value-invention `join` reads (an integer bin
    /// column such as `src_bx[i] = floor(lon[i] / dx)`): materialised for the
    /// join, but NOT value-invention outputs — they stay ordinary observeds.
    columns: Vec<(String, Value)>,
}

/// Scan a raw model for value-invention assignments: the equation list (LHS base
/// resolved from the node) plus the `expression` of each observed variable (the
/// base is the variable name). `vi_var_names` is the set of LHS variables
/// produced by `distinct`, all excluded from the ODE; `producers` are
/// `(base, node)` pairs.
fn vi_detect(model_json: &Value) -> Detection {
    let mut det = Detection {
        has_vi: false,
        vi_var_names: HashSet::new(),
        producers: Vec::new(),
        candidates: Vec::new(),
        columns: Vec::new(),
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
    let candidates = std::mem::take(&mut det.candidates);
    // The `join.on` key columns a producer reads: plain per-element aggregates
    // over constant factors.
    let mut join_names: HashSet<String> = HashSet::new();
    for (_, node) in &det.producers {
        vi_join_on_names(node.get("join"), &mut join_names);
    }
    det.columns = candidates
        .into_iter()
        .filter(|(base, node)| {
            join_names.contains(base)
                && node
                    .get("output_idx")
                    .and_then(|v| v.as_array())
                    .is_some_and(|oi| oi.len() == 1)
        })
        .collect();
    det.has_vi = !det.producers.is_empty();
    det
}

/// Every key-column name of a `join`'s `on` clauses.
fn vi_join_on_names(join: Option<&Value>, out: &mut HashSet<String>) {
    let Some(join) = join.and_then(|v| v.as_array()) else {
        return;
    };
    for clause in join {
        for pair in clause
            .get("on")
            .and_then(|v| v.as_array())
            .into_iter()
            .flatten()
        {
            for col in pair.as_array().into_iter().flatten() {
                if let Some(c) = col.as_str() {
                    out.insert(c.to_string());
                }
            }
        }
    }
}

fn classify_assignment(base: &str, rhs: &Value, det: &mut Detection) {
    let kind = vi_node_kind(rhs);
    if kind == NodeKind::None {
        // A plain numeric aggregate may be a `join` column (resolved later).
        if node_op(rhs) == Some("faq") {
            det.candidates.push((base.to_string(), rhs.clone()));
        }
        return;
    }
    det.vi_var_names.insert(base.to_string()); // every value-invention output leaves the ODE
    if kind == NodeKind::Producer {
        det.producers.push((base.to_string(), rhs.clone()));
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
    maps: HashMap<String, ViBuf>,
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

/// The range symbols bound at one point. Looked up per node evaluated, so
/// the hasher is the fast one; never iterated in its own order.
type Bindings = rustc_hash::FxHashMap<String, i64>;

/// A materialised buffer: output index → value. Read by key and by sorted
/// key only, never iterated in its own order, so the hasher is the fast one.
type ViBuf = rustc_hash::FxHashMap<i64, Val>;

fn vi_eval(node: &Value, ctx: &ViCtx, bindings: &Bindings) -> Result<Val, ValueInventionError> {
    match node {
        Value::Bool(b) => Ok(Val::Bool(*b)),
        Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                Ok(Val::Int(i))
            } else {
                // Literal ingress rounds to the active precision, as the value
                // evaluator's `Expr::Number` arm does.
                Ok(Val::Float(crate::precision::round(n.as_f64().unwrap())))
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
                // Scalar parameter, rounded on ingress like every other value
                // the evaluator did not itself produce.
                return Ok(Val::Float(crate::precision::round(ctx.param(s)?)));
            }
            Ok(Val::Str(s.clone())) // relation tag ("edge"/"bin"/"pair")
        }
        Value::Object(_) => vi_eval_op(node, ctx, bindings),
        other => err(format!("unevaluable value-invention node {other}")),
    }
}

fn vi_eval_op(node: &Value, ctx: &ViCtx, bindings: &Bindings) -> Result<Val, ValueInventionError> {
    let op = node_op(node)
        .ok_or_else(|| ValueInventionError::new("value-invention node has no `op`"))?;
    let args = node_args(node);
    // Arity guard: `args` comes straight from user JSON (schema-valid files
    // may still carry too few operands), so a missing operand must surface
    // as a diagnostic, never a slice-index panic.
    let arg = |i: usize| -> Result<&Value, ValueInventionError> {
        args.get(i).ok_or_else(|| {
            ValueInventionError::new(format!(
                "op {op:?} expects at least {} operand(s), found {}",
                i + 1,
                args.len()
            ))
        })
    };
    let prec = crate::precision::active();
    match op {
        // The precision-boundary marker inserted by
        // `crate::precision_infer`: evaluate the one operand at the element
        // type it names. `Val::Int` is exact and unaffected;
        // what the guard changes is the float arms below and the ingress
        // rounding of literals, parameters and gathered array cells.
        crate::precision_infer::MARKER_OP => {
            let inner = arg(0)?;
            match crate::precision_infer::marker_precision_json(node) {
                Some(p) => {
                    let _guard = crate::precision::enter(p);
                    vi_eval(inner, ctx, bindings)
                }
                None => vi_eval(inner, ctx, bindings),
            }
        }
        "index" => vi_index(node, ctx, bindings),
        "true" => Ok(Val::Bool(true)),
        "false" => Ok(Val::Bool(false)),
        "floor" => Ok(rounded_int(
            vi_eval(arg(0)?, ctx, bindings)?.as_f64()?.floor(),
        )),
        "ceil" => Ok(rounded_int(
            vi_eval(arg(0)?, ctx, bindings)?.as_f64()?.ceil(),
        )),
        "const" => match node.get("value") {
            Some(Value::Number(n)) => Ok(match n.as_i64() {
                Some(i) => Val::Int(i),
                None => Val::Float(crate::precision::round(n.as_f64().unwrap_or(f64::NAN))),
            }),
            Some(Value::Bool(b)) => Ok(Val::Bool(*b)),
            _ => err("only a scalar `const` is a value-invention build-time value"),
        },
        "ifelse" => {
            let c = vi_eval(arg(0)?, ctx, bindings)?;
            let branch = if truthy(&c)? { arg(1)? } else { arg(2)? };
            vi_eval(branch, ctx, bindings)
        }
        "and" | "or" => {
            // Short-circuit, as the value evaluator's boolean reductions do.
            let want = op == "or";
            for a in args {
                if truthy(&vi_eval(a, ctx, bindings)?)? == want {
                    return Ok(Val::Bool(want));
                }
            }
            Ok(Val::Bool(!want))
        }
        "not" => Ok(Val::Bool(!truthy(&vi_eval(arg(0)?, ctx, bindings)?)?)),
        "min" | "max" => {
            let mut acc = vi_eval(arg(0)?, ctx, bindings)?.as_f64()?;
            for a in &args[1..] {
                let x = vi_eval(a, ctx, bindings)?.as_f64()?;
                // NaN propagates (esm-spec §4.2), unlike `f64::min` / `f64::max`.
                let better = if op == "min" { x < acc } else { x > acc };
                if x.is_nan() || better {
                    acc = x;
                }
            }
            Ok(Val::Float(acc))
        }
        // Arithmetic rounds to the active precision (`crate::precision`).
        //
        // This evaluator is the RELATIONAL half of the pipeline: what it
        // computes decides which tuples a distinct set, an arg-witness or a
        // grouped aggregate contains — which rows the model has at all. Leaving
        // it in binary64 while the value evaluator rounded would let a
        // comparison here pick a different witness than the same comparison
        // picks downstream, which is the worst possible place for a precision
        // seam. `prec.round(a op b)` for `+ - * /` on binary32 operands IS the
        // binary32 operation (binary64 carries 53 bits >= 2*24+2, so the double
        // rounding is innocuous), and it is the identity under Float64, so the
        // default path is bit-unchanged.
        "/" => {
            let a = vi_eval(arg(0)?, ctx, bindings)?.as_f64()?;
            let b = vi_eval(arg(1)?, ctx, bindings)?.as_f64()?;
            Ok(Val::Float(prec.round(a / b)))
        }
        "*" => {
            let mut acc = 1.0;
            for a in args {
                acc = prec.round(acc * vi_eval(a, ctx, bindings)?.as_f64()?);
            }
            Ok(Val::Float(acc))
        }
        "+" => {
            let mut acc = 0.0;
            for a in args {
                acc = prec.round(acc + vi_eval(a, ctx, bindings)?.as_f64()?);
            }
            Ok(Val::Float(acc))
        }
        "-" => {
            if args.len() == 1 {
                // A sign flip is exact in every binary format.
                Ok(Val::Float(-vi_eval(arg(0)?, ctx, bindings)?.as_f64()?))
            } else {
                let a = vi_eval(arg(0)?, ctx, bindings)?.as_f64()?;
                let b = vi_eval(arg(1)?, ctx, bindings)?.as_f64()?;
                Ok(Val::Float(prec.round(a - b)))
            }
        }
        "<" | ">" | "<=" | ">=" | "==" | "!=" => {
            // Compare at the WORKING precision: two values that round to the
            // same binary32 number must compare equal, exactly as the value
            // evaluator's comparison kernels do.
            let a = prec.round(vi_eval(arg(0)?, ctx, bindings)?.as_f64()?);
            let b = prec.round(vi_eval(arg(1)?, ctx, bindings)?.as_f64()?);
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

/// A rounded (`floor` / `ceil`) value: an exact integer, or the non-finite
/// float itself (a NaN component of a key template stays NaN).
fn rounded_int(r: f64) -> Val {
    if r.is_finite() {
        Val::Int(r as i64)
    } else {
        Val::Float(r)
    }
}

/// A build-time condition value: a boolean, or a number > 0 (NaN is false).
fn truthy(v: &Val) -> Result<bool, ValueInventionError> {
    match v {
        Val::Bool(b) => Ok(*b),
        other => Ok(other.as_f64()? > 0.0),
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
            ValueInventionError::new(format!(
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
    // A const-array factor is build-time data the evaluator did not produce,
    // so it rounds on read (`crate::precision`).
    Ok(Val::Float(crate::precision::round(arr[IxDyn(&idx)])))
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

/// A `distinct` key or `join` column value: an expression's exact integer (a
/// lib/relational.esm key template, a bare `index`, `floor(...)`). A NaN value — a key template's out-of-range,
/// non-integral or NaN component — is `value_invention_key_out_of_range`
/// naming `column` and the loop indices (esm-spec §9.6.6).
fn vi_key(
    node: &Value,
    ctx: &ViCtx,
    bindings: &Bindings,
    column: &str,
) -> Result<Key, ValueInventionError> {
    key_of(vi_eval(node, ctx, bindings)?, bindings, column)
}

/// [`vi_key`]'s reading of a key expression's value.
fn key_of(v: Val, bindings: &Bindings, column: &str) -> Result<Key, ValueInventionError> {
    match v {
        Val::Float(f) if f.is_nan() => {
            let mut at: Vec<(&String, &i64)> = bindings.iter().collect();
            at.sort();
            let at: Vec<String> = at.iter().map(|(k, v)| format!("{k}={v}")).collect();
            Err(ValueInventionError::with_code(
                crate::diagnostic::codes::VALUE_INVENTION_KEY_OUT_OF_RANGE,
                format!(
                    "{column} is NaN at ({}); a key component is out of its declared range, \
                     non-integral or NaN",
                    at.join(", ")
                ),
            ))
        }
        v => Ok(Key::Int(v.key_int()?)),
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
                ValueInventionError::new(format!("ragged parent {parent_sym:?} is not bound"))
            })?;
            let offsets_name = iset.get("offsets").and_then(|v| v.as_str()).unwrap_or("");
            let values_name = iset.get("values").and_then(|v| v.as_str()).unwrap_or("");
            let offs = ctx.const_arrays.get(offsets_name).ok_or_else(|| {
                ValueInventionError::new(format!(
                    "ragged offsets factor {offsets_name:?} not supplied"
                ))
            })?;
            let vals = ctx.const_arrays.get(values_name).ok_or_else(|| {
                ValueInventionError::new(format!(
                    "ragged values factor {values_name:?} not supplied"
                ))
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
    let mut bindings = Bindings::default();
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
        match bindings.get_mut(s) {
            Some(slot) => *slot = v,
            None => {
                bindings.insert(s.clone(), v);
            }
        }
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
        ValueInventionError::new(format!("join references unknown variable {vname:?}"))
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
    /// [`crate::broad_phase`]. The same index also DRIVES enumeration
    /// ([`vi_enumerate_join`]), through the policy
    /// [`crate::broad_phase::overlap_drive_plan`] shared with the dense
    /// aggregate expansion.
    Overlap {
        sym_l: String,
        sym_r: String,
        index: OverlapIndex,
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
) -> Result<OverlapIndex, ValueInventionError> {
    let src_envs = crate::broad_phase::envelope_vectors(src_env, ctx.const_arrays)
        .map_err(ValueInventionError::new)?;
    let tgt_envs = crate::broad_phase::envelope_vectors(tgt_env, ctx.const_arrays)
        .map_err(ValueInventionError::new)?;
    let pairs = crate::broad_phase::broad_phase_candidates(&src_envs, &tgt_envs, eps);
    // Broad-phase pairs are 0-based positions; the enumeration bindings are
    // 1-based (`vi_range_values` binds interval/categorical position p to p), so
    // the index shifts them to 1-based to match.
    Ok(OverlapIndex::from_zero_based(&pairs))
}

/// Structural arity check on an overlap-clause env-factor list (1 rings /
/// 2 points / 4 rectangle bounds), mirroring Julia's `_valid_env_arity`.
fn overlap_env_names(ov: &Value, field: &str) -> Result<Vec<String>, ValueInventionError> {
    let raw = ov.get(field).and_then(|v| v.as_array()).ok_or_else(|| {
        ValueInventionError::new(format!(
            "join `overlap` clause requires both `src_env` and `tgt_env` arrays of envelope \
             factor names (Phase 2a spatial overlap gate); missing/invalid `{field}`"
        ))
    })?;
    let names: Vec<String> = raw
        .iter()
        .map(|x| x.as_str().map(String::from).unwrap_or_default())
        .collect();
    if crate::broad_phase::overlap_env_rank(names.len()).is_none() {
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
            let index = overlap_candidate_set(&src_env, &tgt_env, ctx, eps)?;
            gates.push(ViJoinGate::Overlap {
                sym_l,
                sym_r,
                index,
            });
        } else if let Some(on) = clause.get("on").and_then(|v| v.as_array()) {
            for pair in on {
                let cols = pair.as_array().filter(|c| c.len() == 2).ok_or_else(|| {
                    ValueInventionError::new("join.on entry must be a [left, right] pair")
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
    let unbound =
        |sym: &str| ValueInventionError::new(format!("join index symbol {sym:?} is not bound"));
    for g in gates {
        match g {
            ViJoinGate::Equality {
                sym_l,
                sym_r,
                lname,
                rname,
            } => {
                let missing_map = |name: &str| {
                    ValueInventionError::new(format!(
                        "join key {name:?} has no materialised map buffer"
                    ))
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
                index,
            } => {
                let l = *bindings.get(sym_l).ok_or_else(|| unbound(sym_l))?;
                let r = *bindings.get(sym_r).ok_or_else(|| unbound(sym_r))?;
                if !index.contains(l, r) {
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
            index,
        } => Some((sym_l, sym_r, index)),
        _ => None,
    });
    let Some((sym_l, sym_r, index)) = driver else {
        return vi_enumerate(ranges, ctx, visit); // full product — unchanged behaviour
    };
    // Every producer range symbol is FREE here (a producer binds nothing up
    // front), so the SHARED policy — the same
    // [`crate::broad_phase::overlap_drive_plan`] the dense aggregate expansion
    // applies, differing only in loop shape because a value-invention range may
    // be ragged and is therefore resolved lazily — plans the PAIR drive. A gate
    // whose symbols are not this node's range symbols cannot be driven at all
    // and falls back to the untouched full product.
    let syms = vi_order_syms(ranges)?;
    let free = |s: &String| syms.iter().any(|x| x == s);
    if !(free(sym_l) && free(sym_r)) {
        return vi_enumerate(ranges, ctx, visit);
    }
    let plan = crate::broad_phase::overlap_drive_plan(index, None, None, None);
    if !matches!(plan, crate::broad_phase::DrivePlan::Pairs) {
        return vi_enumerate(ranges, ctx, visit);
    }
    // DETERMINISTIC (pos_l, pos_r)-ascending drive order (member set is
    // canonicalised downstream, but a sorted drive keeps any order-sensitive
    // reduction stable).
    let pairs: Vec<(i64, i64)> = index.pairs().collect();
    // The remaining ungated symbols, in the topological order the full product
    // visits them, minus the two driven symbols.
    let rest: Vec<String> = syms
        .into_iter()
        .filter(|s| s != sym_l && s != sym_r)
        .collect();
    let mut bindings = Bindings::default();
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

/// Materialise a plain per-element `join` column (see [`Detection::columns`]):
/// each value an exact integer, a NaN value `value_invention_key_out_of_range`.
fn vi_materialize_column(
    ctx: &mut ViCtx,
    vname: &str,
    node: &Value,
) -> Result<(), ValueInventionError> {
    let sym = node
        .get("output_idx")
        .and_then(|v| v.as_array())
        .and_then(|oi| oi.first())
        .and_then(|v| v.as_str())
        .unwrap_or_default()
        .to_string();
    let body = node.get("expr").ok_or_else(|| {
        ValueInventionError::new(format!("join column {vname:?} has no `expr` body"))
    })?;
    let empty = Map::new();
    let ranges = node
        .get("ranges")
        .and_then(|v| v.as_object())
        .unwrap_or(&empty);
    let column = format!("join column '{vname}'");
    let mut out = ViBuf::default();
    {
        let ctx_ref = &*ctx;
        vi_enumerate(ranges, ctx_ref, |bindings| {
            let Key::Int(i) = vi_key(body, ctx_ref, bindings, &column)? else {
                unreachable!("a join column value is a scalar key");
            };
            let v = Val::Int(i);
            let at = *bindings.get(&sym).ok_or_else(|| {
                ValueInventionError::new(format!("join column {vname:?} output index is unbound"))
            })?;
            out.insert(at, v);
            Ok(())
        })?;
    }
    ctx.maps.insert(vname.to_string(), out);
    Ok(())
}

/// A join column's body, or a producer's `filter` or `key`, compiled once
/// before its enumeration: the part of [`vi_eval`] whose names resolve before
/// any point is bound — the node's own range symbols, scalar parameters and
/// const-array factors — evaluated per point without walking the JSON or
/// looking a name up more than once. Each arm
/// computes exactly what the [`vi_eval`] arm of the same op does. A body
/// with anything else is not compiled, and a point whose evaluation fails
/// is evaluated again by [`vi_eval`] for its diagnostic.
enum Fast<'a> {
    Bool(bool),
    Int(i64),
    /// A literal, rounded on ingress at evaluation.
    Float(f64),
    /// A range symbol of the map.
    Bound(&'a str),
    /// A scalar parameter's value, rounded on ingress at evaluation.
    Param(f64),
    Index {
        name: &'a str,
        arr: &'a ArrayD<f64>,
        subs: Vec<Fast<'a>>,
    },
    Floor(Box<Fast<'a>>),
    Ceil(Box<Fast<'a>>),
    Div(Box<Fast<'a>>, Box<Fast<'a>>),
    Mul(Vec<Fast<'a>>),
    Add(Vec<Fast<'a>>),
    Neg(Box<Fast<'a>>),
    Sub(Box<Fast<'a>>, Box<Fast<'a>>),
    Ifelse(Box<[Fast<'a>; 3]>),
    /// `and` (`false`) or `or` (`true`): short-circuits on the first operand
    /// whose truth is the payload.
    AndOr(bool, Vec<Fast<'a>>),
    Not(Box<Fast<'a>>),
    /// `min` (`false`) or `max` (`true`).
    MinMax(bool, Vec<Fast<'a>>),
    Cmp(CmpOp, Box<Fast<'a>>, Box<Fast<'a>>),
    /// A sub-expression written more than once in the node: [`FastExpr`]'s
    /// `shared[i]`, evaluated at most once per point.
    Shared(usize),
}

/// A compiled node ([`Fast`]) with its shared sub-expressions. A template
/// expansion repeats its arguments (`edge_key` reads `min(u, v)` five times);
/// each repeat is evaluated once per point and reused, which is the same
/// value, since evaluation reads only the point's bindings and build-time
/// data. A shared sub-expression is evaluated where it is first needed, so a
/// branch not taken still evaluates nothing.
struct FastExpr<'a> {
    root: Fast<'a>,
    shared: Vec<Fast<'a>>,
    /// This point's value of each shared sub-expression, once evaluated.
    memo: std::cell::RefCell<Vec<Option<Val>>>,
}

impl<'a> FastExpr<'a> {
    fn compile(node: &'a Value, ctx: &'a ViCtx, ranges: &Map<String, Value>) -> Option<Self> {
        let mut ids = TreeIds::default();
        ids.id(node);
        let mut count: HashMap<usize, usize> = HashMap::new();
        for &id in ids.of.values() {
            *count.entry(id).or_default() += 1;
        }
        count.retain(|_, n| *n > 1);
        let mut cse = FastCse {
            of: ids.of,
            repeated: count,
            slot: HashMap::new(),
            shared: Vec::new(),
        };
        let root = Fast::compile(node, ctx, ranges, &mut cse)?;
        let n = cse.shared.len();
        Some(FastExpr {
            root,
            shared: cse.shared,
            memo: std::cell::RefCell::new(vec![None; n]),
        })
    }

    fn eval(&self, ctx: &ViCtx, bindings: &Bindings) -> Result<Val, ValueInventionError> {
        self.memo.borrow_mut().fill(None);
        self.root.eval(self, ctx, bindings)
    }
}

/// [`FastExpr::compile`]'s shared sub-expressions: each operator sub-tree's
/// structural id, the ids written more than once, the slot each has been
/// given, and the slots' compiled nodes.
struct FastCse<'a> {
    of: HashMap<*const Value, usize>,
    repeated: HashMap<usize, usize>,
    slot: HashMap<usize, usize>,
    shared: Vec<Fast<'a>>,
}

/// One part of a [`TreeIds`] key: an operand that is an operator sub-tree,
/// by its id, or any other value, by its text.
#[derive(PartialEq, Eq, Hash)]
enum TreePart {
    Tree(usize),
    Text(String),
}

/// Structural ids of the operator sub-trees of an expression, numbered
/// bottom-up: two sub-trees share an id exactly when their JSON text is the
/// same. A node's key is its fields other than `args` as text and its
/// operands' parts, so each value is serialized once and the numbering is
/// linear in the tree.
#[derive(Default)]
struct TreeIds {
    /// Each operator sub-tree visited, by address, and its id.
    of: HashMap<*const Value, usize>,
    by_key: HashMap<Vec<TreePart>, usize>,
}

impl TreeIds {
    fn id(&mut self, node: &Value) -> Option<usize> {
        let Value::Object(map) = node else {
            return None;
        };
        let mut key: Vec<TreePart> = Vec::new();
        for (k, v) in map {
            match v {
                Value::Array(args) if k == "args" => {
                    key.push(TreePart::Text("args".into()));
                    for a in args {
                        key.push(match self.id(a) {
                            Some(i) => TreePart::Tree(i),
                            None => TreePart::Text(a.to_string()),
                        });
                    }
                    key.push(TreePart::Text(String::new()));
                }
                _ => key.push(TreePart::Text(format!("{k:?}:{v}"))),
            }
        }
        let n = self.by_key.len();
        let id = *self.by_key.entry(key).or_insert(n);
        self.of.insert(node as *const Value, id);
        Some(id)
    }
}

/// A comparison [`Fast`] evaluates.
#[derive(Clone, Copy)]
enum CmpOp {
    Lt,
    Gt,
    Le,
    Ge,
    Eq,
    Ne,
}

impl<'a> Fast<'a> {
    fn compile(
        node: &'a Value,
        ctx: &'a ViCtx,
        ranges: &Map<String, Value>,
        cse: &mut FastCse<'a>,
    ) -> Option<Self> {
        if let Value::Object(_) = node
            && !cse.repeated.is_empty()
            && let Some(&id) = cse.of.get(&(node as *const Value))
        {
            if let Some(&i) = cse.slot.get(&id) {
                return Some(Fast::Shared(i));
            }
            if cse.repeated.remove(&id).is_some() {
                let f = Self::compile(node, ctx, ranges, cse)?;
                cse.shared.push(f);
                let i = cse.shared.len() - 1;
                cse.slot.insert(id, i);
                return Some(Fast::Shared(i));
            }
        }
        let sub =
            |n: &'a Value, cse: &mut FastCse<'a>| Self::compile(n, ctx, ranges, cse).map(Box::new);
        let all = |ns: &'a [Value], cse: &mut FastCse<'a>| -> Option<Vec<Self>> {
            ns.iter()
                .map(|n| Self::compile(n, ctx, ranges, cse))
                .collect()
        };
        match node {
            Value::Bool(b) => Some(Fast::Bool(*b)),
            Value::Number(n) => Some(match n.as_i64() {
                Some(i) => Fast::Int(i),
                None => Fast::Float(n.as_f64()?),
            }),
            Value::String(s) => {
                if ranges.contains_key(s) {
                    return Some(Fast::Bound(s));
                }
                if ctx.const_arrays.contains_key(s) {
                    return None;
                }
                let is_param = ctx
                    .variables
                    .get(s)
                    .and_then(|v| v.get("type"))
                    .and_then(|v| v.as_str())
                    == Some("parameter");
                if is_param {
                    ctx.param(s).ok().map(Fast::Param)
                } else {
                    None
                }
            }
            Value::Object(_) => {
                let args = node_args(node);
                let a = |i: usize| args.get(i);
                Some(match node_op(node)? {
                    "index" => {
                        let name = args.first()?.as_str()?;
                        if ctx.maps.contains_key(name) {
                            return None;
                        }
                        let arr = ctx.const_arrays.get(name)?;
                        if args.len() - 1 != arr.ndim() {
                            return None;
                        }
                        Fast::Index {
                            name,
                            arr,
                            subs: all(&args[1..], cse)?,
                        }
                    }
                    "true" => Fast::Bool(true),
                    "false" => Fast::Bool(false),
                    "floor" => Fast::Floor(sub(a(0)?, cse)?),
                    "ceil" => Fast::Ceil(sub(a(0)?, cse)?),
                    "/" => Fast::Div(sub(a(0)?, cse)?, sub(a(1)?, cse)?),
                    "*" => Fast::Mul(all(args, cse)?),
                    "+" => Fast::Add(all(args, cse)?),
                    "-" if args.len() == 1 => Fast::Neg(sub(a(0)?, cse)?),
                    "-" => Fast::Sub(sub(a(0)?, cse)?, sub(a(1)?, cse)?),
                    "ifelse" => {
                        let c = Self::compile(a(0)?, ctx, ranges, cse)?;
                        let t = Self::compile(a(1)?, ctx, ranges, cse)?;
                        let e = Self::compile(a(2)?, ctx, ranges, cse)?;
                        Fast::Ifelse(Box::new([c, t, e]))
                    }
                    o @ ("and" | "or") => Fast::AndOr(o == "or", all(args, cse)?),
                    "not" => Fast::Not(sub(a(0)?, cse)?),
                    o @ ("min" | "max") if !args.is_empty() => {
                        Fast::MinMax(o == "max", all(args, cse)?)
                    }
                    o @ ("<" | ">" | "<=" | ">=" | "==" | "!=") => {
                        let c = match o {
                            "<" => CmpOp::Lt,
                            ">" => CmpOp::Gt,
                            "<=" => CmpOp::Le,
                            ">=" => CmpOp::Ge,
                            "==" => CmpOp::Eq,
                            _ => CmpOp::Ne,
                        };
                        Fast::Cmp(c, sub(a(0)?, cse)?, sub(a(1)?, cse)?)
                    }
                    _ => return None,
                })
            }
            _ => None,
        }
    }

    fn eval(
        &self,
        env: &FastExpr<'a>,
        ctx: &ViCtx,
        bindings: &Bindings,
    ) -> Result<Val, ValueInventionError> {
        Ok(match self {
            Fast::Bool(b) => Val::Bool(*b),
            Fast::Int(i) => Val::Int(*i),
            Fast::Bound(s) => Val::Int(Self::bound(s, bindings)?),
            Fast::Floor(e) => rounded_int(e.num(env, ctx, bindings)?.floor()),
            Fast::Ceil(e) => rounded_int(e.num(env, ctx, bindings)?.ceil()),
            Fast::Ifelse(cte) => {
                let [c, t, e] = &**cte;
                if c.truth(env, ctx, bindings)? {
                    t.eval(env, ctx, bindings)?
                } else {
                    e.eval(env, ctx, bindings)?
                }
            }
            Fast::Shared(i) => {
                if let Some(v) = &env.memo.borrow()[*i] {
                    return Ok(v.clone());
                }
                let v = env.shared[*i].eval(env, ctx, bindings)?;
                env.memo.borrow_mut()[*i] = Some(v.clone());
                v
            }
            Fast::AndOr(..) | Fast::Not(_) | Fast::Cmp(..) => {
                Val::Bool(self.truth(env, ctx, bindings)?)
            }
            Fast::Float(_)
            | Fast::Param(_)
            | Fast::Index { .. }
            | Fast::Div(..)
            | Fast::Mul(_)
            | Fast::Add(_)
            | Fast::Neg(_)
            | Fast::Sub(..)
            | Fast::MinMax(..) => Val::Float(self.num(env, ctx, bindings)?),
        })
    }

    fn bound(s: &str, bindings: &Bindings) -> Result<i64, ValueInventionError> {
        match bindings.get(s) {
            Some(v) => Ok(*v),
            None => err(format!("range symbol {s:?} is not bound")),
        }
    }

    /// `self.eval(..)?.key_int()`, without the [`Val`] for a range symbol.
    fn key_int(
        &self,
        env: &FastExpr<'a>,
        ctx: &ViCtx,
        bindings: &Bindings,
    ) -> Result<i64, ValueInventionError> {
        match self {
            Fast::Bound(s) => Self::bound(s, bindings),
            _ => self.eval(env, ctx, bindings)?.key_int(),
        }
    }

    /// `self.eval(..)?.as_f64()`, computed without building a [`Val`] where
    /// the node is numeric or boolean.
    fn num(
        &self,
        env: &FastExpr<'a>,
        ctx: &ViCtx,
        bindings: &Bindings,
    ) -> Result<f64, ValueInventionError> {
        let f = |e: &Self| e.num(env, ctx, bindings);
        let prec = || crate::precision::active();
        Ok(match self {
            Fast::Bool(b) => f64::from(u8::from(*b)),
            Fast::Int(i) => *i as f64,
            Fast::Float(x) | Fast::Param(x) => crate::precision::round(*x),
            Fast::Bound(s) => Self::bound(s, bindings)? as f64,
            Fast::Index { name, arr, subs } => {
                let shape = arr.shape();
                let mut idx: smallvec::SmallVec<[usize; 4]> = smallvec::SmallVec::new();
                for (d, e) in subs.iter().enumerate() {
                    let one_based = e.key_int(env, ctx, bindings)?;
                    let n = shape[d] as i64;
                    idx.push((resolve_const_index(ctx, name, d, one_based, n)? - 1) as usize);
                }
                crate::precision::round(arr[IxDyn(&idx)])
            }
            Fast::Div(a, b) => {
                let a = f(a)?;
                let b = f(b)?;
                prec().round(a / b)
            }
            Fast::Mul(args) => {
                let mut acc = 1.0;
                for e in args {
                    acc = prec().round(acc * f(e)?);
                }
                acc
            }
            Fast::Add(args) => {
                let mut acc = 0.0;
                for e in args {
                    acc = prec().round(acc + f(e)?);
                }
                acc
            }
            Fast::Neg(e) => -f(e)?,
            Fast::Sub(a, b) => {
                let a = f(a)?;
                let b = f(b)?;
                prec().round(a - b)
            }
            Fast::MinMax(max, args) => {
                let mut acc = f(&args[0])?;
                for e in &args[1..] {
                    let x = f(e)?;
                    let better = if *max { x > acc } else { x < acc };
                    if x.is_nan() || better {
                        acc = x;
                    }
                }
                acc
            }
            Fast::Ifelse(cte) => {
                let [c, t, e] = &**cte;
                if c.truth(env, ctx, bindings)? {
                    f(t)?
                } else {
                    f(e)?
                }
            }
            Fast::AndOr(..) | Fast::Not(_) | Fast::Cmp(..) => {
                f64::from(u8::from(self.truth(env, ctx, bindings)?))
            }
            Fast::Floor(_) | Fast::Ceil(_) | Fast::Shared(_) => {
                self.eval(env, ctx, bindings)?.as_f64()?
            }
        })
    }

    /// `truthy(&self.eval(..)?)`, computed without building a [`Val`].
    fn truth(
        &self,
        env: &FastExpr<'a>,
        ctx: &ViCtx,
        bindings: &Bindings,
    ) -> Result<bool, ValueInventionError> {
        Ok(match self {
            Fast::Bool(b) => *b,
            Fast::AndOr(want, args) => {
                for e in args {
                    if e.truth(env, ctx, bindings)? == *want {
                        return Ok(*want);
                    }
                }
                !*want
            }
            Fast::Not(e) => !e.truth(env, ctx, bindings)?,
            Fast::Cmp(c, a, b) => {
                let prec = crate::precision::active();
                let a = prec.round(a.num(env, ctx, bindings)?);
                let b = prec.round(b.num(env, ctx, bindings)?);
                match c {
                    CmpOp::Lt => a < b,
                    CmpOp::Gt => a > b,
                    CmpOp::Le => a <= b,
                    CmpOp::Ge => a >= b,
                    CmpOp::Eq => a == b,
                    CmpOp::Ne => a != b,
                }
            }
            Fast::Ifelse(cte) => {
                let [c, t, e] = &**cte;
                if c.truth(env, ctx, bindings)? {
                    t.truth(env, ctx, bindings)?
                } else {
                    e.truth(env, ctx, bindings)?
                }
            }
            _ => truthy(&self.eval(env, ctx, bindings)?)?,
        })
    }
}

/// Materialise an index-set-producing aggregate → the distinct member set (§5.5
/// sorted total order, via the relational engine). Returns the member list.
fn vi_materialize_producer(ctx: &ViCtx, node: &Value) -> Result<Vec<Key>, ValueInventionError> {
    let key = node.get("key").ok_or_else(|| {
        ValueInventionError::new("value-invention producer aggregate requires a `key` (§5.5)")
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
    let column = format!(
        "the `key` of producer '{}'",
        node.get("id").and_then(|v| v.as_str()).unwrap_or("")
    );
    // The filter and key compiled once. A
    // point whose compiled evaluation fails is evaluated again by `vi_eval` /
    // `vi_key`, which report the failure as they always have.
    let fast_filt = filt.and_then(|f| FastExpr::compile(f, ctx, ranges));
    let fast_key = FastExpr::compile(key, ctx, ranges);
    let mut members: Vec<Key> = Vec::new();
    vi_enumerate_join(ranges, &gates, ctx, |bindings| {
        if let Some(f) = filt {
            let fv = match fast_filt.as_ref().map(|ff| ff.eval(ctx, bindings)) {
                Some(Ok(v)) => v,
                _ => vi_eval(f, ctx, bindings)?,
            };
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
        let k = match fast_key.as_ref().map(|fk| fk.eval(ctx, bindings)) {
            Some(Ok(v)) => key_of(v, bindings, &column)?,
            _ => vi_key(key, ctx, bindings, &column)?,
        };
        members.push(k);
        Ok(())
    })?;
    Ok(relational::distinct(&members))
}

// --------------------------------------------------------------------------- //
// Grouped / derived build-time buffers (the SCVT centroid step)
// --------------------------------------------------------------------------- //

// --------------------------------------------------------------------------- //
// Public entrypoint
// --------------------------------------------------------------------------- //

/// Arm the working precision of the variable a value-invention buffer fills
/// (esm-spec §11.3.1), for as long as the returned guard lives.
///
/// `None` — no guard at all — unless the document declares a per-variable
/// `element_type`.
fn vi_variable_precision(vname: &str) -> Option<crate::precision::PrecisionGuard> {
    if !crate::precision::has_variable_overrides() {
        return None;
    }
    Some(crate::precision::enter(crate::precision::of_variable(
        vname,
    )))
}

/// Run the build-time value-invention engine over a raw model document.
///
/// Value invention mints new entities from data, once at setup: unique edge
/// IDs from a mesh, dense ranks from a categorical column, bin keys from
/// coordinates. This evaluates every value-invention aggregate in
/// `model_json` (a `faq` with `distinct: true`) and returns what it
/// materialized as a [`ValueInventionResult`]. Pass that result to [`apply_value_invention`] to rewrite the model so the array
/// runtime can compile it.
///
/// - `model_json` is the raw model document, not the typed [`Model`]: the
///   typed expression tree does not keep an aggregate's `key` and `distinct`
///   fields.
/// - `const_arrays` supplies the build-time factor arrays (connectivity,
///   coordinates) the keys are computed from.
/// - `params` supplies scalar parameter overrides.
/// - `const_array_boundaries` optionally gives a per-array, per-dimension
///   [`BoundaryKind`] for a gather at a 1-based index outside `1..=n`
///   (periodic wrap or edge clamp). An array absent from the map, or a
///   dimension beyond its listed kinds, errors on an out-of-range index; pass
///   an empty map for that everywhere.
///
/// A model with no `distinct` producer returns an empty result.
///
/// # Errors
///
/// Returns a [`ValueInventionError`] when a producer classifies as
/// continuous (its entities would change every step, `CONFORMANCE_SPEC.md`
/// §5.7 guard 2), when a key cannot be evaluated from the build-time data, or
/// on an out-of-range gather with no boundary policy.
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

    // Join columns (a producer's join may reference them). Each is
    // materialized at the element type of the variable it fills (esm-spec
    // §11.3.1). `None` unless the document declares a per-variable
    // `element_type`.
    for (vname, node) in &det.columns {
        let _prec = vi_variable_precision(vname);
        vi_materialize_column(&mut ctx, vname, node)?;
    }

    // `from_faq` id → derived index-set name (so we only materialise producers a
    // derived set actually names).
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
            ValueInventionError::new(
                "value-invention producer aggregate requires an `id` naming it for `from_faq`",
            )
        })?;
        if !faq_to_set.contains_key(node_id) {
            continue; // no derived set names this producer
        }
        // §5.7 guard 2: a relational node may not run on the hot path.
        let cls = cadence::classify(node, model_json)
            .map_err(|e| ValueInventionError::new(format!("cadence classify failed: {e}")))?;
        if cls == Cadence::Continuous {
            return err(format!(
                "relational_node_in_continuous: value-invention producer {node_id:?} classifies \
                 CONTINUOUS — it may not run per step (RFC §5.7 guard 2); its inputs must be \
                 CONST/DISCRETE"
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
/// [`crate::faq::resolve_aggregate_ranges`] resolves it via the existing
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
/// model: the `distinct` outputs are materialised at setup, not
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
        model.variables.shift_remove(name);
    }
}

/// The combined front-door applied to a typed model: rewrite the derived index
/// sets to their materialised dense extents and drop the value-invention
/// equations. After this the existing resolver / array compiler handles the
/// model with no value-invention-specific path.
///
/// The `index_sets` registry is document-scoped, so it is passed in (and
/// mutated in place) alongside the model.
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
// The template-form fixtures (`tests/conformance/relational_templates/`) run
// end to end through the integration tests; the cases here pin the engine on
// inline models.
// =========================================================================== //

#[cfg(test)]
mod tests {
    use super::*;

    fn arr(shape: &[usize], data: Vec<f64>) -> ArrayD<f64> {
        ArrayD::from_shape_vec(IxDyn(shape), data).expect("shape matches data")
    }

    fn ca(pairs: Vec<(&str, ArrayD<f64>)>) -> HashMap<String, ArrayD<f64>> {
        pairs.into_iter().map(|(k, v)| (k.to_string(), v)).collect()
    }

    /// The default empty per-const-array boundary map (throw-on-OOB everywhere).
    fn no_bounds() -> HashMap<String, Vec<BoundaryKind>> {
        HashMap::new()
    }

    fn bounds(pairs: Vec<(&str, Vec<BoundaryKind>)>) -> HashMap<String, Vec<BoundaryKind>> {
        pairs.into_iter().map(|(k, v)| (k.to_string(), v)).collect()
    }

    #[test]
    fn a_nan_key_carries_the_out_of_range_code() {
        let const_arrays: HashMap<String, ArrayD<f64>> = HashMap::new();
        let params: HashMap<String, f64> = [("p".to_string(), f64::NAN)].into_iter().collect();
        let empty = Map::new();
        let mut vars = Map::new();
        vars.insert("p".to_string(), serde_json::json!({"type": "parameter"}));
        let no_bnds = no_bounds();
        let ctx = ViCtx {
            const_arrays: &const_arrays,
            params: &params,
            index_sets: &empty,
            variables: &vars,
            const_array_boundaries: &no_bnds,
            maps: HashMap::new(),
        };
        let bindings: Bindings = [("a".to_string(), 1)].into_iter().collect();
        let e = vi_key(&serde_json::json!("p"), &ctx, &bindings, "bin_col").unwrap_err();
        assert_eq!(
            e.code,
            Some(crate::diagnostic::codes::VALUE_INVENTION_KEY_OUT_OF_RANGE)
        );
        assert!(
            e.message.starts_with("bin_col is NaN at (a=1)"),
            "{}",
            e.message
        );
        assert!(
            e.to_string()
                .starts_with("ValueInventionError: value_invention_key_out_of_range: bin_col"),
            "{e}"
        );
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
                "u": {"type": "unknown", "shape": ["items"]},
                "tag": {"type": "unknown", "shape": ["tags"]}
            },
            "equations": [{
                "lhs": {"op": "index", "args": ["tag", "p"]},
                "rhs": {
                    "op": "faq", "id": "tag_set", "semiring": "bool_and_or",
                    "distinct": true, "output_idx": ["p"],
                    "ranges": {"i": {"from": "items"}},
                    "key": {"op": "index", "args": ["u", "i"]},
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
            "variables": {"x": {"type": "unknown", "shape": []}},
            "equations": [{"lhs": {"op": "D", "args": ["x"], "wrt": "t"}, "rhs": -1.0}]
        });
        let vi =
            materialize_value_invention(&plain, &HashMap::new(), &HashMap::new(), &no_bounds())
                .unwrap();
        assert!(vi.extents.is_empty());
        assert!(vi.vi_var_names.is_empty());
    }

    /// The §7.3 edge enumeration with a scalar composite key (the
    /// `lib/relational.esm` `edge_key` arithmetic, written out): two triangles
    /// sharing edge (2,3) give five distinct undirected edges, in ascending key
    /// order, whatever the winding.
    #[test]
    fn edge_enumeration_with_a_scalar_key() {
        let side = |name: &str| serde_json::json!({"op": "index", "args": [name, "f", "le"]});
        let key = serde_json::json!({"op": "+", "args": [
            {"op": "*", "args": [{"op": "-", "args": [{"op": "min", "args": [side("lo"), side("hi")]}, 1]}, 4]},
            {"op": "-", "args": [{"op": "max", "args": [side("lo"), side("hi")]}, 1]}
        ]});
        let model: Value = serde_json::json!({
            "index_sets": {
                "faces": {"kind": "interval", "size": 2},
                "local_edges": {"kind": "interval", "size": 3},
                "edges": {"kind": "derived", "from_faq": "edge_set"}
            },
            "variables": {"edge_exists": {"type": "unknown", "shape": ["edges"]}},
            "equations": [{
                "lhs": {"op": "index", "args": ["edge_exists", "e"]},
                "rhs": {
                    "op": "faq", "id": "edge_set", "semiring": "bool_and_or",
                    "distinct": true, "output_idx": ["e"],
                    "ranges": {"f": {"from": "faces"}, "le": {"from": "local_edges"}},
                    "key": key,
                    "expr": {"op": "true", "args": []}
                }
            }]
        });
        let want: Vec<Key> = [1, 2, 6, 7, 11].into_iter().map(Key::Int).collect();
        for (lo, hi) in [
            (
                [1.0, 2.0, 3.0, 2.0, 3.0, 4.0],
                [2.0, 3.0, 1.0, 3.0, 4.0, 2.0],
            ),
            (
                [2.0, 3.0, 1.0, 3.0, 4.0, 2.0],
                [1.0, 2.0, 3.0, 2.0, 3.0, 4.0],
            ),
        ] {
            let const_arrays = ca(vec![
                ("lo", arr(&[2, 3], lo.to_vec())),
                ("hi", arr(&[2, 3], hi.to_vec())),
            ]);
            let vi =
                materialize_value_invention(&model, &const_arrays, &HashMap::new(), &no_bounds())
                    .unwrap();
            assert_eq!(vi.members["edge_set"], want);
            assert_eq!(vi.extents["edge_set"], 5);
            assert!(vi.vi_var_names.contains("edge_exists"));
            let mut sets: HashMap<String, IndexSet> = HashMap::new();
            sets.insert(
                "edges".to_string(),
                serde_json::from_value(
                    serde_json::json!({"kind": "derived", "from_faq": "edge_set"}),
                )
                .unwrap(),
            );
            rewrite_derived_index_sets(&mut sets, &vi.extents);
            assert_eq!(sets["edges"].kind, "interval");
            assert_eq!(sets["edges"].size, Some(5));
        }
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
        match vi_index(&node, &ctx, &Bindings::default())? {
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
                e.message
                    .contains("const array 'M' index 5 out of range 1..4 in dim 0"),
                "unexpected error message: {}",
                e.message
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
            match vi_index(&node, &ctx, &Bindings::default())? {
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

    /// Two operator sub-trees share a structural id exactly when their JSON
    /// text is the same: an operand, a field other than `args`, or the field
    /// order apart gives a new id.
    #[test]
    fn tree_ids_match_equal_json_text() {
        let tree = serde_json::json!({"op": "+", "args": [
            {"op": "min", "args": ["u", "v"]},
            {"op": "min", "args": ["u", "v"]},
            {"op": "min", "args": ["v", "u"]},
            {"op": "min", "args": ["u", 1]},
            {"op": "min", "args": ["u", "1"]},
            {"op": "min", "args": ["u", "v"], "wrt": "t"},
            {"args": ["u", "v"], "op": "min"},
            {"op": "*", "args": [{"op": "min", "args": ["u", "v"]}, 2]},
            {"op": "*", "args": [{"op": "min", "args": ["u", "v"]}, 2]}
        ]});
        let mut ids = TreeIds::default();
        ids.id(&tree);
        let a = node_args(&tree);
        let id = |v: &Value| ids.of[&(v as *const Value)];
        let text: Vec<String> = a.iter().map(Value::to_string).collect();
        for i in 0..a.len() {
            for j in 0..a.len() {
                assert_eq!(
                    id(&a[i]) == id(&a[j]),
                    text[i] == text[j],
                    "{} vs {}",
                    a[i],
                    a[j]
                );
            }
        }
        assert_eq!(id(&a[0]), id(&node_args(&a[7])[0]));
        assert_eq!(ids.of.len(), 12);
    }
}
