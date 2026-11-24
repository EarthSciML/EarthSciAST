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
//! The pass runs on the typed [`Model`] and its expressions, through one
//! build-time evaluator that compiles each key, filter and join column once
//! before enumerating it. [`materialize_value_invention`], the raw-JSON entry
//! point, reads its model as a typed one and calls the same core. The
//! materialised members are **byte-identical** across the Julia / Rust /
//! Python bindings (the M3 determinism goldens) because the members are
//! emitted in §5.5.1 sorted total order.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::rc::Rc;
use std::sync::Arc;

use indexmap::IndexMap;
use ndarray::{ArrayD, IxDyn};
use serde_json::{Map, Value};

use crate::broad_phase::OverlapIndex;
use crate::cadence;
use crate::relational::{self, Key};
use crate::types::{
    Expr, ExpressionNode, IndexSet, JoinClause, Model, ModelVariable, RangeSpec, VariableType,
};

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

impl ValueInventionResult {
    /// Producer id → member ids: what a derived set feeds back as its
    /// `member_factor` and what a gated fetch selects. The engine makes every
    /// key a scalar integer (`key_of`).
    pub(crate) fn member_ids(&self) -> HashMap<String, Vec<i64>> {
        self.members
            .iter()
            .map(|(faq, keys)| {
                let ids = keys
                    .iter()
                    .map(|k| match k {
                        Key::Int(i) => *i,
                        other => unreachable!("value-invention keys are scalar: {other:?}"),
                    })
                    .collect();
                (faq.clone(), ids)
            })
            .collect()
    }
}

// --------------------------------------------------------------------------- //
// Intermediate build-time value
// --------------------------------------------------------------------------- //

/// A build-time value the evaluator ([`Node`]) produces: an int / float / bool / name,
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
// Detection — classify the aggregate nodes (mirror of _vi_node_kind / _vi_detect)
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
/// True for every node [`is_value_invention_expr`] recognises — a `distinct`
/// producer and a `distinct` body — because both leave the ODE and are
/// materialized by this engine, never by the array evaluator. This is the
/// raw-JSON spelling of that test, for a caller holding a JSON node.
pub fn is_value_invention_assignment(rhs: &Value) -> bool {
    let Some(map) = rhs.as_object() else {
        return false;
    };
    map.get("op").and_then(Value::as_str) == Some("faq")
        && (map.get("distinct").and_then(Value::as_bool) == Some(true)
            || map
                .get("expr")
                .and_then(|b| b.get("op"))
                .and_then(Value::as_str)
                == Some("distinct"))
}

/// [`is_value_invention_assignment`] on a typed expression. Read by the build
/// pipeline, which wasm32 does not have.
#[cfg_attr(target_arch = "wasm32", allow(dead_code))]
pub(crate) fn is_value_invention_expr(rhs: &Expr) -> bool {
    vi_node_kind(rhs) != NodeKind::None
}

fn vi_node_kind(e: &Expr) -> NodeKind {
    let Expr::Operator(node) = e else {
        return NodeKind::None;
    };
    if node.op != "faq" {
        return NodeKind::None;
    }
    if node.distinct == Some(true) {
        return NodeKind::Producer;
    }
    if matches!(node.expr.as_deref(), Some(Expr::Operator(b)) if b.op == "distinct") {
        return NodeKind::Exclude;
    }
    NodeKind::None
}

/// Base variable name written by an LHS `Expr` (`Variable` / `index` / `D`).
fn lhs_base(expr: &Expr) -> Option<&str> {
    match expr {
        Expr::Variable(name) => Some(name),
        Expr::Operator(node) if node.op == "index" || node.op == "D" => {
            node.args.first().and_then(lhs_base)
        }
        _ => None,
    }
}

struct Detection<'m> {
    vi_var_names: HashSet<String>,
    /// Each producer's assignment right-hand side, and its node.
    producers: Vec<(&'m Expr, &'m ExpressionNode)>,
    /// Plain per-element columns a value-invention `join` reads (an integer bin
    /// column such as `src_bx[i] = floor(lon[i] / dx)`): materialised for the
    /// join, but NOT value-invention outputs — they stay ordinary observeds.
    columns: Vec<(&'m str, &'m ExpressionNode)>,
}

/// Scan a model's equations for value-invention assignments (the LHS base
/// resolved from the node). `vi_var_names` is the set of LHS variables
/// produced by `distinct`, all excluded from the ODE.
fn vi_detect(model: &Model) -> Detection<'_> {
    let mut det = Detection {
        vi_var_names: HashSet::new(),
        producers: Vec::new(),
        columns: Vec::new(),
    };
    // Plain numeric aggregates — `join` column candidates.
    let mut candidates: Vec<(&str, &ExpressionNode)> = Vec::new();
    for eq in &model.equations {
        let Some(base) = lhs_base(&eq.lhs) else {
            continue;
        };
        let Expr::Operator(node) = &eq.rhs else {
            continue;
        };
        match vi_node_kind(&eq.rhs) {
            NodeKind::None => {
                if node.op == "faq" {
                    candidates.push((base, node));
                }
            }
            kind => {
                // Every value-invention output leaves the ODE.
                det.vi_var_names.insert(base.to_string());
                if kind == NodeKind::Producer {
                    det.producers.push((&eq.rhs, node));
                }
            }
        }
    }
    // The `join.on` key columns a producer reads: plain per-element aggregates
    // over constant factors.
    let join_names: HashSet<&str> = det
        .producers
        .iter()
        .flat_map(|(_, n)| n.join.iter().flatten())
        .flat_map(|clause| clause.on.iter().flatten())
        .map(String::as_str)
        .collect();
    det.columns = candidates
        .into_iter()
        .filter(|(base, node)| {
            join_names.contains(base) && node.output_idx.as_ref().is_some_and(|oi| oi.len() == 1)
        })
        .collect();
    det
}

// --------------------------------------------------------------------------- //
// Build-time evaluation context (mirror of _ViCtx)
// --------------------------------------------------------------------------- //

/// A map of build-time arrays by name.
pub(crate) trait FactorLookup {
    fn factor(&self, name: &str) -> Option<&ArrayD<f64>>;
}

impl<S: std::hash::BuildHasher> FactorLookup for HashMap<String, ArrayD<f64>, S> {
    fn factor(&self, name: &str) -> Option<&ArrayD<f64>> {
        self.get(name)
    }
}

/// The build-time factor arrays value invention reads, by name: an array the
/// caller supplied, else one of `own`. A lookup, never a merged copy, so a
/// caller's namespace of provider slabs is not cloned to be read.
pub(crate) struct Factors<'a> {
    caller: Option<&'a dyn FactorLookup>,
    own: &'a HashMap<String, ArrayD<f64>>,
}

impl<'a> Factors<'a> {
    /// `own` alone.
    pub(crate) fn of(own: &'a HashMap<String, ArrayD<f64>>) -> Self {
        Factors { caller: None, own }
    }

    /// `own`, overlaid by `caller`'s arrays (the caller's wins on a name both
    /// hold).
    pub(crate) fn overlaid(
        own: &'a HashMap<String, ArrayD<f64>>,
        caller: &'a dyn FactorLookup,
    ) -> Self {
        Factors {
            caller: Some(caller),
            own,
        }
    }

    fn get(&self, name: &str) -> Option<&'a ArrayD<f64>> {
        self.caller
            .and_then(|c| c.factor(name))
            .or_else(|| self.own.get(name))
    }

    fn contains_key(&self, name: &str) -> bool {
        self.get(name).is_some()
    }
}

struct ViCtx<'a> {
    const_arrays: &'a Factors<'a>,
    params: &'a HashMap<String, f64>,
    index_sets: &'a HashMap<String, IndexSet>,
    variables: &'a IndexMap<String, ModelVariable>,
    /// Per-const-array, per-dimension out-of-range boundary policy (ess-gj4). A
    /// `(name, d)` absent from this map (or beyond the declared vec) defaults to
    /// [`BoundaryKind::Error`] — the throw-on-OOB behavior that catches genuine
    /// connectivity / stencil-weight bugs.
    const_array_boundaries: &'a HashMap<String, Vec<BoundaryKind>>,
    /// materialised map var → {output-index value → key value}
    maps: HashMap<String, ViBuf>,
    /// The operator instances the producers' and columns' references name.
    ops: &'a crate::operator_refs::Instances,
    /// Every instance they reach, held for as long as the compiled bodies.
    held: Vec<Arc<crate::operator_refs::CallInstance>>,
}

impl ViCtx<'_> {
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
        if let Some(d) = self.variables.get(name).and_then(|v| v.default_scalar()) {
            return Ok(d);
        }
        err(format!(
            "value-invention scalar parameter {name:?} has no override or default"
        ))
    }

    fn is_parameter(&self, name: &str) -> bool {
        self.variables
            .get(name)
            .is_some_and(|v| v.var_type == VariableType::Parameter)
    }
}

/// The range symbols bound at one point. Looked up per node evaluated, so
/// the hasher is the fast one; never iterated in its own order.
type Bindings = rustc_hash::FxHashMap<String, i64>;

/// A materialised buffer: output index → value. Read by key and by sorted
/// key only, never iterated in its own order, so the hasher is the fast one.
type ViBuf = rustc_hash::FxHashMap<i64, Val>;

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
/// lib/relational.esm key template, a bare `index`, `floor(...)`). A NaN
/// value — a key template's out-of-range, non-integral or NaN component — is
/// `value_invention_key_out_of_range` naming `column` and the loop indices
/// (esm-spec §9.6.6).
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

/// A node's ranges, by symbol in name order.
type Ranges<'n> = BTreeMap<&'n str, &'n RangeSpec>;

fn ranges_of(node: &ExpressionNode) -> Ranges<'_> {
    node.ranges
        .iter()
        .flatten()
        .map(|(s, r)| (s.as_str(), r))
        .collect()
}

/// The `of` parents a range names (empty for any range but a ragged one).
fn range_of(spec: &RangeSpec) -> &[String] {
    match spec {
        RangeSpec::IndexSetRef { of: Some(of), .. } => of,
        _ => &[],
    }
}

/// Order range symbols so a ragged range's `of` parents precede it (a stable
/// topological order over the per-symbol `of` dependency, from name order).
fn vi_order_syms<'n>(ranges: &Ranges<'n>) -> Result<Vec<&'n str>, ValueInventionError> {
    let mut ordered: Vec<&str> = Vec::new();
    let mut remaining: Vec<&str> = ranges.keys().copied().collect();
    while !remaining.is_empty() {
        let mut progressed = false;
        let mut i = 0;
        while i < remaining.len() {
            let ready = range_of(ranges[remaining[i]])
                .iter()
                .all(|p| ordered.contains(&p.as_str()) || !ranges.contains_key(p.as_str()));
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
    spec: &RangeSpec,
    ctx: &ViCtx,
    bindings: &Bindings,
) -> Result<Vec<i64>, ValueInventionError> {
    let RangeSpec::IndexSetRef { from, of } = spec else {
        return err("value-invention range spec is missing `from`");
    };
    let Some(iset) = ctx.index_sets.get(from) else {
        return err(format!(
            "value-invention range references undeclared index set {from:?}"
        ));
    };
    match iset.kind.as_str() {
        "interval" => Ok((1..=iset.size.unwrap_or(0)).collect()),
        "categorical" => Ok((1..=iset.members.as_ref().map_or(0, Vec::len) as i64).collect()),
        "ragged" => {
            let Some(parent_sym) = of.as_ref().and_then(|of| of.first()) else {
                return err(format!(
                    "ragged value-invention range {from:?} needs an `of` parent"
                ));
            };
            let parent = *bindings.get(parent_sym).ok_or_else(|| {
                ValueInventionError::new(format!("ragged parent {parent_sym:?} is not bound"))
            })?;
            let offsets_name = iset.offsets.as_deref().unwrap_or("");
            let values_name = iset.values.as_deref().unwrap_or("");
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
            "value-invention range over index set kind {:?} is unsupported",
            Some(other)
        )),
    }
}

/// Enumerate every full binding of an aggregate's `ranges`, calling `visit` at
/// each leaf binding.
fn vi_enumerate<F>(ranges: &Ranges, ctx: &ViCtx, mut visit: F) -> Result<(), ValueInventionError>
where
    F: FnMut(&Bindings) -> Result<(), ValueInventionError>,
{
    let syms = vi_order_syms(ranges)?;
    let mut bindings = Bindings::default();
    vi_enumerate_rec(&syms, 0, ranges, ctx, &mut bindings, &mut visit)
}

fn vi_enumerate_rec<F>(
    syms: &[&str],
    k: usize,
    ranges: &Ranges,
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
    let s = syms[k];
    for v in vi_range_values(ranges[s], ctx, bindings)? {
        match bindings.get_mut(s) {
            Some(slot) => *slot = v,
            None => {
                bindings.insert(s.to_string(), v);
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
/// the first producer range, in name order, whose `from` equals the variable's
/// (1-D) shape index set.
fn vi_join_index_sym(
    vname: &str,
    producer_ranges: &Ranges,
    ctx: &ViCtx,
) -> Result<String, ValueInventionError> {
    let v = ctx.variables.get(vname).ok_or_else(|| {
        ValueInventionError::new(format!("join references unknown variable {vname:?}"))
    })?;
    let shape: &[String] = v.shape.as_deref().unwrap_or(&[]);
    if shape.len() != 1 {
        return err(format!(
            "value-invention join key {vname:?} must be a 1-D buffer; shape={shape:?}"
        ));
    }
    let target = &shape[0];
    for (sym, spec) in producer_ranges {
        if matches!(spec, RangeSpec::IndexSetRef { from, .. } if from == target) {
            return Ok(sym.to_string());
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
    // The envelope factors only, borrowed into the map the broad phase reads.
    let envelopes: HashMap<String, ArrayD<f64>> = src_env
        .iter()
        .chain(tgt_env)
        .filter_map(|n| Some((n.clone(), ctx.const_arrays.get(n)?.clone())))
        .collect();
    let src_envs = crate::broad_phase::envelope_vectors(src_env, &envelopes)
        .map_err(ValueInventionError::new)?;
    let tgt_envs = crate::broad_phase::envelope_vectors(tgt_env, &envelopes)
        .map_err(ValueInventionError::new)?;
    let pairs = crate::broad_phase::broad_phase_candidates(&src_envs, &tgt_envs, eps);
    // Broad-phase pairs are 0-based positions; the enumeration bindings are
    // 1-based (`vi_range_values` binds interval/categorical position p to p), so
    // the index shifts them to 1-based to match.
    Ok(OverlapIndex::from_zero_based(&pairs))
}

/// Structural arity check on an overlap-clause env-factor list (1 rings /
/// 2 points / 4 rectangle bounds), mirroring Julia's `_valid_env_arity`.
fn overlap_env_names<'c>(
    names: &'c [String],
    field: &str,
) -> Result<&'c [String], ValueInventionError> {
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
    join: &[JoinClause],
    producer_ranges: &Ranges,
    ctx: &ViCtx,
) -> Result<Vec<ViJoinGate>, ValueInventionError> {
    let mut gates: Vec<ViJoinGate> = Vec::new();
    for clause in join {
        if let Some(ov) = &clause.overlap {
            let src_env = overlap_env_names(&ov.src_env, "src_env")?;
            let tgt_env = overlap_env_names(&ov.tgt_env, "tgt_env")?;
            let eps = ov.eps.unwrap_or(0.0);
            // `src_env`/`tgt_env` name const-array envelope FACTORS; each factor's
            // 1-D shape index set names one join range (like an `on` key column).
            // All factors of one side share that index set, so the first names it.
            let sym_l = vi_join_index_sym(&src_env[0], producer_ranges, ctx)?;
            let sym_r = vi_join_index_sym(&tgt_env[0], producer_ranges, ctx)?;
            let index = overlap_candidate_set(src_env, tgt_env, ctx, eps)?;
            gates.push(ViJoinGate::Overlap {
                sym_l,
                sym_r,
                index,
            });
        } else {
            for [lname, rname] in &clause.on {
                let sym_l = vi_join_index_sym(lname, producer_ranges, ctx)?;
                let sym_r = vi_join_index_sym(rname, producer_ranges, ctx)?;
                gates.push(ViJoinGate::Equality {
                    sym_l,
                    sym_r,
                    lname: lname.clone(),
                    rname: rname.clone(),
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
    // `join.on` names and index symbols come from the document, so a missing
    // map buffer or unbound symbol is a diagnostic, not a panicking lookup.
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
/// `distinct` canonicalises order) is identical to the full-product path.
/// Mirrors Julia's `_vi_enumerate_join`.
fn vi_enumerate_join<F>(
    ranges: &Ranges,
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
        return vi_enumerate(ranges, ctx, visit);
    };
    // Every producer range symbol is FREE here (a producer binds nothing up
    // front), so the SHARED policy — the same
    // [`crate::broad_phase::overlap_drive_plan`] the dense aggregate expansion
    // applies, differing only in loop shape because a value-invention range may
    // be ragged and is therefore resolved lazily — plans the PAIR drive. A gate
    // whose symbols are not this node's range symbols cannot be driven at all
    // and falls back to the untouched full product.
    let syms = vi_order_syms(ranges)?;
    let free = |s: &String| syms.contains(&s.as_str());
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
    let rest: Vec<&str> = syms
        .into_iter()
        .filter(|s| *s != sym_l.as_str() && *s != sym_r.as_str())
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
    node: &ExpressionNode,
) -> Result<(), ValueInventionError> {
    let sym = node
        .output_idx
        .as_ref()
        .and_then(|oi| oi.first())
        .cloned()
        .unwrap_or_default();
    let body = node.expr.as_deref().ok_or_else(|| {
        ValueInventionError::new(format!("join column {vname:?} has no `expr` body"))
    })?;
    let ranges = ranges_of(node);
    let column = format!("join column '{vname}'");
    let mut out = ViBuf::default();
    {
        let ctx_ref = &*ctx;
        let body = Compiled::new(body, ctx_ref, &ranges);
        vi_enumerate(&ranges, ctx_ref, |bindings| {
            let Key::Int(i) = key_of(body.eval(ctx_ref, bindings)?, bindings, &column)? else {
                unreachable!("a join column value is a scalar key");
            };
            let at = *bindings.get(&sym).ok_or_else(|| {
                ValueInventionError::new(format!("join column {vname:?} output index is unbound"))
            })?;
            out.insert(at, Val::Int(i));
            Ok(())
        })?;
    }
    ctx.maps.insert(vname.to_string(), out);
    Ok(())
}

// --------------------------------------------------------------------------- //
// The build-time evaluator
// --------------------------------------------------------------------------- //

/// A key, filter or join-column body compiled once before its enumeration:
/// every name resolves when the node is compiled — the node's own range
/// symbols, scalar parameters, const-array factors and materialised buffers —
/// so evaluation per point neither walks the document nor looks a name up.
/// What the evaluator cannot evaluate compiles to [`Node::Fail`], which raises
/// its diagnostic only if evaluation reaches it, so an operand never reached
/// (an `ifelse` branch not taken) costs nothing, as it would interpreted.
enum Node<'a> {
    Bool(bool),
    Int(i64),
    /// A literal, rounded on ingress at evaluation.
    Float(f64),
    /// A range symbol of the node.
    Bound(&'a str),
    /// A scalar parameter's value, rounded on ingress at evaluation.
    Param(f64),
    /// A bare name that is not a number: a const-array factor or a relation
    /// tag (`"edge"`, `"bin"`).
    Name(&'a str),
    /// `index(factor, i, …)`: a 1-based gather from a const-array factor.
    Index {
        name: &'a str,
        arr: &'a ArrayD<f64>,
        subs: Vec<Node<'a>>,
    },
    /// `index(buffer, i)`: a read of a materialised value-invention buffer
    /// (an arg-witness or upstream grouped buffer).
    Buffer {
        name: &'a str,
        buf: &'a ViBuf,
        sub: Box<Node<'a>>,
    },
    Floor(Box<Node<'a>>),
    Ceil(Box<Node<'a>>),
    Div(Box<Node<'a>>, Box<Node<'a>>),
    Mul(Vec<Node<'a>>),
    Add(Vec<Node<'a>>),
    Neg(Box<Node<'a>>),
    Sub(Box<Node<'a>>, Box<Node<'a>>),
    Ifelse(Box<[Node<'a>; 3]>),
    /// `and` (`false`) or `or` (`true`): short-circuits on the first operand
    /// whose truth is the payload.
    AndOr(bool, Vec<Node<'a>>),
    Not(Box<Node<'a>>),
    /// `min` (`false`) or `max` (`true`).
    MinMax(bool, Vec<Node<'a>>),
    Cmp(CmpOp, Box<Node<'a>>, Box<Node<'a>>),
    /// The precision-boundary marker inserted by `crate::precision_infer`:
    /// the operand evaluated at the element type it names.
    AtPrecision(Option<crate::precision::Precision>, Box<Node<'a>>),
    /// A sub-expression written more than once in the node: [`Compiled`]'s
    /// `shared[i]`, evaluated at most once per point.
    Shared(usize),
    /// What evaluation cannot do, and the diagnostic it raises when reached.
    Fail(String),
    /// An operator reference (esm-spec §9.6.4): the body of the instance it
    /// names, compiled once per instance, called with the reference's
    /// bindings, compiled in the caller's scope, in the order of the
    /// definition's parameters.
    Call {
        body: Rc<Node<'a>>,
        args: Vec<Node<'a>>,
    },
    /// Parameter `i` of the body being compiled: the call's argument `i`.
    Arg(usize),
    /// `index(base, i, …)` whose base is a body parameter: the factor or
    /// buffer the argument names, looked up when the gather is evaluated.
    IndexDyn {
        base: Box<Node<'a>>,
        subs: Vec<Node<'a>>,
    },
}

/// The call in progress while a [`Node::Call`] body is evaluated: its
/// arguments (the reference's bindings, compiled in the caller's scope) and
/// the caller's own frame. A body parameter ([`Node::Arg`]) is its argument,
/// evaluated in the caller's frame when the body reads it (call by name,
/// esm-spec §9.6.4).
struct Frame<'f, 'a> {
    args: &'f [Node<'a>],
    parent: Fr<'f, 'a>,
}

/// The innermost call in progress, `None` outside every call.
type Fr<'f, 'a> = Option<&'f Frame<'f, 'a>>;

/// A comparison [`Node`] evaluates.
#[derive(Clone, Copy)]
enum CmpOp {
    Lt,
    Gt,
    Le,
    Ge,
    Eq,
    Ne,
}

/// A compiled body ([`Node`]) with its shared sub-expressions. A template
/// expansion repeats its arguments (`edge_key` reads `min(u, v)` five times);
/// each repeat is evaluated once per point and reused, which is the same
/// value, since evaluation reads only the point's bindings and build-time
/// data. A shared sub-expression is evaluated where it is first needed, so a
/// branch not taken still evaluates nothing. A body with a precision marker
/// shares nothing: one sub-expression may be evaluated at two precisions.
struct Compiled<'a> {
    root: Node<'a>,
    shared: Vec<Node<'a>>,
    /// This point's value of each shared sub-expression, once evaluated.
    memo: std::cell::RefCell<Vec<Option<Val>>>,
}

impl<'a> Compiled<'a> {
    fn new(e: &'a Expr, ctx: &'a ViCtx<'_>, ranges: &Ranges) -> Self {
        let mut ids = TreeIds::default();
        ids.id(e);
        let mut count = std::mem::take(&mut ids.count);
        count.retain(|_, n| *n > 1 && !ids.marked);
        let mut cse = Cse {
            of: ids.of,
            repeated: count,
            slot: HashMap::new(),
            shared: Vec::new(),
            params: None,
            bodies: Rc::default(),
        };
        let root = Node::compile(e, ctx, ranges, &mut cse);
        let n = cse.shared.len();
        Compiled {
            root,
            shared: cse.shared,
            memo: std::cell::RefCell::new(vec![None; n]),
        }
    }

    fn eval(&self, ctx: &ViCtx, bindings: &Bindings) -> Result<Val, ValueInventionError> {
        self.memo.borrow_mut().fill(None);
        self.root.eval(self, ctx, bindings, None)
    }
}

/// [`Compiled::new`]'s shared sub-expressions: each operator sub-tree's
/// structural id, the ids written more than once, the slot each has been
/// given, and the slots' compiled nodes.
struct Cse<'a> {
    of: HashMap<*const ExpressionNode, usize>,
    repeated: HashMap<usize, usize>,
    slot: HashMap<usize, usize>,
    shared: Vec<Node<'a>>,
    /// The parameters of the definition whose body is being compiled.
    params: Option<&'a [String]>,
    /// Each instance body compiled so far, by instance address.
    bodies: Rc<std::cell::RefCell<HashMap<usize, Rc<Node<'a>>>>>,
}

/// One part of a [`TreeIds`] key: an operand that is an operator sub-tree, by
/// its id, or a leaf, by its kind and spelling.
#[derive(PartialEq, Eq, Hash)]
enum TreePart {
    Tree(usize),
    Int(i64),
    Float(u64),
    Name(String),
}

/// Structural ids of the operator sub-trees of an expression, numbered
/// bottom-up: two sub-trees share an id exactly when they evaluate alike —
/// the same op, the same `const` value and the same operands. A sub-tree
/// shared in memory is numbered once.
#[derive(Default)]
struct TreeIds {
    /// Each operator sub-tree visited, by address, and its id.
    of: HashMap<*const ExpressionNode, usize>,
    by_key: HashMap<(String, String, Vec<TreePart>), usize>,
    /// How many times each id is written.
    count: HashMap<usize, usize>,
    /// Whether the expression holds a precision marker.
    marked: bool,
}

impl TreeIds {
    fn id(&mut self, e: &Expr) -> TreePart {
        let node = match e {
            Expr::Integer(i) => return TreePart::Int(*i),
            Expr::Number(x) => return TreePart::Float(x.to_bits()),
            Expr::Variable(v) => return TreePart::Name(v.clone()),
            Expr::Operator(node) => node,
        };
        let ptr = &**node as *const ExpressionNode;
        if let Some(&id) = self.of.get(&ptr) {
            *self.count.entry(id).or_default() += 1;
            return TreePart::Tree(id);
        }
        self.marked |= node.op == crate::precision_infer::MARKER_OP;
        let mut parts: Vec<TreePart> = node.args.iter().map(|a| self.id(a)).collect();
        let mut value = node
            .value
            .as_ref()
            .map(|v| v.to_json().to_string())
            .unwrap_or_default();
        // A reference is identified by the definition it names and what it
        // binds, which are not `args`.
        if let Some(r) = crate::operator_refs::reference_node(node) {
            let mut keys: Vec<&String> = r.bindings.keys().collect();
            keys.sort();
            value = format!("{}{:?}", r.name, keys);
            parts.extend(keys.into_iter().map(|k| self.id(&r.bindings[k])));
        }
        let n = self.by_key.len();
        let id = *self
            .by_key
            .entry((node.op.clone(), value, parts))
            .or_insert(n);
        self.of.insert(ptr, id);
        *self.count.entry(id).or_default() += 1;
        TreePart::Tree(id)
    }
}

/// The diagnostic for operand `i` of `op` missing from `n` operands.
fn missing_operand(op: &str, i: usize, n: usize) -> String {
    format!("op {op:?} expects at least {} operand(s), found {n}", i + 1)
}

impl<'a> Node<'a> {
    fn compile(e: &'a Expr, ctx: &'a ViCtx<'_>, ranges: &Ranges, cse: &mut Cse<'a>) -> Self {
        let node = match e {
            Expr::Integer(i) => return Node::Int(*i),
            // A float literal that is integral is the integer the document
            // spells it as (§5.5.3.1).
            Expr::Number(x) => {
                return match crate::types::canonical_i64(*x) {
                    Some(i) => Node::Int(i),
                    None => Node::Float(*x),
                };
            }
            Expr::Variable(s) => {
                if let Some(i) = cse.params.and_then(|ps| ps.iter().position(|p| p == s)) {
                    return Node::Arg(i);
                }
                return Self::name(s, ctx, ranges);
            }
            Expr::Operator(node) => node,
        };
        if !cse.repeated.is_empty()
            && let Some(&id) = cse.of.get(&(&**node as *const ExpressionNode))
        {
            if let Some(&i) = cse.slot.get(&id) {
                return Node::Shared(i);
            }
            if cse.repeated.remove(&id).is_some() {
                let f = Self::operator(node, ctx, ranges, cse);
                cse.shared.push(f);
                let i = cse.shared.len() - 1;
                cse.slot.insert(id, i);
                return Node::Shared(i);
            }
        }
        Self::operator(node, ctx, ranges, cse)
    }

    /// A bare name: a bound range symbol, a const-array factor, a scalar
    /// parameter, or a relation tag.
    fn name(s: &'a str, ctx: &'a ViCtx<'_>, ranges: &Ranges) -> Self {
        if ranges.contains_key(s) {
            Node::Bound(s)
        } else if ctx.const_arrays.contains_key(s) {
            Node::Name(s)
        } else if ctx.is_parameter(s) {
            match ctx.param(s) {
                Ok(v) => Node::Param(v),
                Err(e) => Node::Fail(e.message),
            }
        } else {
            Node::Name(s)
        }
    }

    fn operator(
        node: &'a ExpressionNode,
        ctx: &'a ViCtx<'_>,
        ranges: &Ranges,
        cse: &mut Cse<'a>,
    ) -> Self {
        let op = node.op.as_str();
        let args = &node.args;
        // An operand the node does not have is a diagnostic when reached,
        // never a slice-index panic.
        let arg = |i: usize, cse: &mut Cse<'a>| match args.get(i) {
            Some(a) => Self::compile(a, ctx, ranges, cse),
            None => Node::Fail(missing_operand(op, i, args.len())),
        };
        let all = |cse: &mut Cse<'a>| -> Vec<Self> {
            args.iter()
                .map(|a| Self::compile(a, ctx, ranges, cse))
                .collect()
        };
        match op {
            crate::operator_refs::APPLY_OP => Self::call(node, ctx, ranges, cse),
            crate::precision_infer::MARKER_OP => {
                let p = crate::precision_infer::marker_precision(node);
                Node::AtPrecision(p, Box::new(arg(0, cse)))
            }
            "index" => Self::index(node, ctx, ranges, cse),
            "true" => Node::Bool(true),
            "false" => Node::Bool(false),
            "floor" => Node::Floor(Box::new(arg(0, cse))),
            "ceil" => Node::Ceil(Box::new(arg(0, cse))),
            "const" => match node.value.as_ref().map(|v| v.to_json()) {
                Some(v) => match &*v {
                    Value::Number(n) => match n.as_i64() {
                        Some(i) => Node::Int(i),
                        None => Node::Float(n.as_f64().unwrap_or(f64::NAN)),
                    },
                    Value::Bool(b) => Node::Bool(*b),
                    _ => Node::Fail(
                        "only a scalar `const` is a value-invention build-time value".into(),
                    ),
                },
                None => {
                    Node::Fail("only a scalar `const` is a value-invention build-time value".into())
                }
            },
            "ifelse" => {
                let c = arg(0, cse);
                let t = arg(1, cse);
                let f = arg(2, cse);
                Node::Ifelse(Box::new([c, t, f]))
            }
            "and" | "or" => Node::AndOr(op == "or", all(cse)),
            "not" => Node::Not(Box::new(arg(0, cse))),
            "min" | "max" if args.is_empty() => Node::Fail(missing_operand(op, 0, 0)),
            "min" | "max" => Node::MinMax(op == "max", all(cse)),
            "/" => {
                let a = arg(0, cse);
                Node::Div(Box::new(a), Box::new(arg(1, cse)))
            }
            "*" => Node::Mul(all(cse)),
            "+" => Node::Add(all(cse)),
            "-" if args.len() == 1 => Node::Neg(Box::new(arg(0, cse))),
            "-" => {
                let a = arg(0, cse);
                Node::Sub(Box::new(a), Box::new(arg(1, cse)))
            }
            "<" | ">" | "<=" | ">=" | "==" | "!=" => {
                let c = match op {
                    "<" => CmpOp::Lt,
                    ">" => CmpOp::Gt,
                    "<=" => CmpOp::Le,
                    ">=" => CmpOp::Ge,
                    "==" => CmpOp::Eq,
                    _ => CmpOp::Ne,
                };
                let a = arg(0, cse);
                Node::Cmp(c, Box::new(a), Box::new(arg(1, cse)))
            }
            other => Node::Fail(format!(
                "value-invention build-time evaluator does not support op {other:?}"
            )),
        }
    }

    /// An operator reference: a call of its instance's body, compiled once
    /// per instance, with the reference's bindings compiled here.
    fn call(
        node: &'a ExpressionNode,
        ctx: &'a ViCtx<'_>,
        ranges: &Ranges,
        cse: &mut Cse<'a>,
    ) -> Self {
        let Some(r) = crate::operator_refs::reference_node(node) else {
            return Node::Fail("an operator reference names no definition".into());
        };
        let inst = match ctx.ops.instance(&r) {
            Ok(i) => i,
            Err(e) => return Node::Fail(e.to_string()),
        };
        // The instance as the context holds it, so the body outlives the
        // compiled node.
        let Some(inst) = ctx.held.iter().find(|h| Arc::ptr_eq(h, &inst)) else {
            return Node::Fail(format!("operator reference `{}` was not reached", r.name));
        };
        let key = Arc::as_ptr(inst) as usize;
        let cached = cse.bodies.borrow().get(&key).cloned();
        let body = match cached {
            Some(b) => b,
            None => {
                let mut inner = Cse {
                    of: HashMap::new(),
                    repeated: HashMap::new(),
                    slot: HashMap::new(),
                    shared: Vec::new(),
                    params: Some(&inst.definition.params),
                    bodies: Rc::clone(&cse.bodies),
                };
                let b = Rc::new(Self::compile(&inst.body, ctx, ranges, &mut inner));
                cse.bodies.borrow_mut().insert(key, Rc::clone(&b));
                b
            }
        };
        let args = inst
            .definition
            .params
            .iter()
            .map(|p| match r.bindings.get(p) {
                Some(b) => Self::compile(b, ctx, ranges, cse),
                None => Node::Fail(format!(
                    "operator reference `{}` binds nothing to parameter `{p}`",
                    r.name
                )),
            })
            .collect();
        Node::Call { body, args }
    }

    /// `index(factor, i, …)`: gather from a const-array factor (1-based) — the
    /// build-time data supplied as const arrays — or read a materialised
    /// value-invention buffer, which is what lets `centroid[g] = num[g]/den[g]`
    /// read its inputs.
    fn index(
        node: &'a ExpressionNode,
        ctx: &'a ViCtx<'_>,
        ranges: &Ranges,
        cse: &mut Cse<'a>,
    ) -> Self {
        let args = &node.args;
        if let Some(Expr::Variable(p)) = args.first()
            && cse.params.is_some_and(|ps| ps.contains(p))
        {
            return Node::IndexDyn {
                base: Box::new(Self::compile(&args[0], ctx, ranges, cse)),
                subs: args[1..]
                    .iter()
                    .map(|a| Self::compile(a, ctx, ranges, cse))
                    .collect(),
            };
        }
        let Some(Expr::Variable(name)) = args.first() else {
            return Node::Fail(
                "value-invention index target must be a const-array factor name".into(),
            );
        };
        if let Some(buf) = ctx.maps.get(name) {
            if args.len() != 2 {
                return Node::Fail(format!(
                    "materialised value-invention buffer {name:?} is a 1-D buffer; expected one \
                     index, got {}",
                    args.len() - 1
                ));
            }
            return Node::Buffer {
                name,
                buf,
                sub: Box::new(Self::compile(&args[1], ctx, ranges, cse)),
            };
        }
        let Some(arr) = ctx.const_arrays.get(name) else {
            return Node::Fail(format!(
                "value-invention index target {name:?} must be a const-array factor \
                 or an already-materialised value-invention buffer"
            ));
        };
        Node::Index {
            name,
            arr,
            subs: args[1..]
                .iter()
                .map(|a| Self::compile(a, ctx, ranges, cse))
                .collect(),
        }
    }

    fn eval(
        &self,
        env: &Compiled<'a>,
        ctx: &ViCtx,
        bindings: &Bindings,
        fr: Fr<'_, 'a>,
    ) -> Result<Val, ValueInventionError> {
        Ok(match self {
            Node::Bool(b) => Val::Bool(*b),
            Node::Int(i) => Val::Int(*i),
            Node::Bound(s) => Val::Int(Self::bound(s, bindings)?),
            Node::Name(s) => Val::Str((*s).to_string()),
            Node::Floor(e) => rounded_int(e.num(env, ctx, bindings, fr)?.floor()),
            Node::Ceil(e) => rounded_int(e.num(env, ctx, bindings, fr)?.ceil()),
            Node::Ifelse(cte) => {
                let [c, t, e] = &**cte;
                if c.truth(env, ctx, bindings, fr)? {
                    t.eval(env, ctx, bindings, fr)?
                } else {
                    e.eval(env, ctx, bindings, fr)?
                }
            }
            Node::Buffer { name, buf, sub } => {
                let idx = sub.key_int(env, ctx, bindings, fr)?;
                buf.get(&idx).cloned().ok_or_else(|| {
                    ValueInventionError::new(format!(
                        "materialised value-invention buffer {name:?} has no entry at index {idx}"
                    ))
                })?
            }
            Node::AtPrecision(p, e) => {
                let _guard = p.map(crate::precision::enter);
                e.eval(env, ctx, bindings, fr)?
            }
            Node::Shared(i) => {
                if let Some(v) = &env.memo.borrow()[*i] {
                    return Ok(v.clone());
                }
                let v = env.shared[*i].eval(env, ctx, bindings, fr)?;
                env.memo.borrow_mut()[*i] = Some(v.clone());
                v
            }
            Node::Fail(msg) => return err(msg.clone()),
            Node::Call { body, args } => {
                body.eval(env, ctx, bindings, Some(&Frame { args, parent: fr }))?
            }
            Node::Arg(i) => {
                let Some(f) = fr else {
                    return err("a body parameter read outside its call");
                };
                f.args[*i].eval(env, ctx, bindings, f.parent)?
            }
            Node::IndexDyn { base, subs } => {
                let Val::Str(name) = base.eval(env, ctx, bindings, fr)? else {
                    return err("value-invention index target must be a const-array factor name");
                };
                if let Some(buf) = ctx.maps.get(&name) {
                    let [sub] = subs.as_slice() else {
                        return err(format!(
                            "materialised value-invention buffer {name:?} is a 1-D buffer; \
                             expected one index, got {}",
                            subs.len()
                        ));
                    };
                    let idx = sub.key_int(env, ctx, bindings, fr)?;
                    return buf.get(&idx).cloned().ok_or_else(|| {
                        ValueInventionError::new(format!(
                            "materialised value-invention buffer {name:?} has no entry at index {idx}"
                        ))
                    });
                }
                let Some(arr) = ctx.const_arrays.get(&name) else {
                    return err(format!(
                        "value-invention index target {name:?} must be a const-array factor \
                         or an already-materialised value-invention buffer"
                    ));
                };
                Val::Float(gather(&name, arr, subs, env, ctx, bindings, fr)?)
            }
            Node::AndOr(..) | Node::Not(_) | Node::Cmp(..) => {
                Val::Bool(self.truth(env, ctx, bindings, fr)?)
            }
            Node::Float(_)
            | Node::Param(_)
            | Node::Index { .. }
            | Node::Div(..)
            | Node::Mul(_)
            | Node::Add(_)
            | Node::Neg(_)
            | Node::Sub(..)
            | Node::MinMax(..) => Val::Float(self.num(env, ctx, bindings, fr)?),
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
        env: &Compiled<'a>,
        ctx: &ViCtx,
        bindings: &Bindings,
        fr: Fr<'_, 'a>,
    ) -> Result<i64, ValueInventionError> {
        match self {
            Node::Bound(s) => Self::bound(s, bindings),
            _ => self.eval(env, ctx, bindings, fr)?.key_int(),
        }
    }

    /// `self.eval(..)?.as_f64()`, computed without building a [`Val`] where
    /// the node is numeric or boolean.
    ///
    /// Arithmetic rounds to the active precision (`crate::precision`). This
    /// evaluator is the RELATIONAL half of the pipeline: what it computes
    /// decides which tuples a distinct set, an arg-witness or a grouped
    /// aggregate contains — which rows the model has at all. Leaving it in
    /// binary64 while the value evaluator rounded would let a comparison here
    /// pick a different witness than the same comparison picks downstream.
    /// `prec.round(a op b)` for `+ - * /` on binary32 operands IS the binary32
    /// operation (binary64 carries 53 bits >= 2*24+2, so the double rounding
    /// is innocuous), and it is the identity under Float64.
    fn num(
        &self,
        env: &Compiled<'a>,
        ctx: &ViCtx,
        bindings: &Bindings,
        fr: Fr<'_, 'a>,
    ) -> Result<f64, ValueInventionError> {
        let f = |e: &Self| e.num(env, ctx, bindings, fr);
        let prec = || crate::precision::active();
        Ok(match self {
            Node::Bool(b) => f64::from(u8::from(*b)),
            Node::Int(i) => *i as f64,
            Node::Float(x) | Node::Param(x) => crate::precision::round(*x),
            Node::Bound(s) => Self::bound(s, bindings)? as f64,
            Node::Index { name, arr, subs } => gather(name, arr, subs, env, ctx, bindings, fr)?,
            Node::Div(a, b) => {
                let a = f(a)?;
                let b = f(b)?;
                prec().round(a / b)
            }
            Node::Mul(args) => {
                let mut acc = 1.0;
                for e in args {
                    acc = prec().round(acc * f(e)?);
                }
                acc
            }
            Node::Add(args) => {
                let mut acc = 0.0;
                for e in args {
                    acc = prec().round(acc + f(e)?);
                }
                acc
            }
            // A sign flip is exact in every binary format.
            Node::Neg(e) => -f(e)?,
            Node::Sub(a, b) => {
                let a = f(a)?;
                let b = f(b)?;
                prec().round(a - b)
            }
            Node::MinMax(max, args) => {
                let mut acc = f(&args[0])?;
                for e in &args[1..] {
                    let x = f(e)?;
                    // NaN propagates (esm-spec §4.2), unlike `f64::min` / `f64::max`.
                    let better = if *max { x > acc } else { x < acc };
                    if x.is_nan() || better {
                        acc = x;
                    }
                }
                acc
            }
            Node::Ifelse(cte) => {
                let [c, t, e] = &**cte;
                if c.truth(env, ctx, bindings, fr)? {
                    f(t)?
                } else {
                    f(e)?
                }
            }
            Node::AndOr(..) | Node::Not(_) | Node::Cmp(..) => {
                f64::from(u8::from(self.truth(env, ctx, bindings, fr)?))
            }
            Node::Name(_)
            | Node::Buffer { .. }
            | Node::Floor(_)
            | Node::Ceil(_)
            | Node::AtPrecision(..)
            | Node::Shared(_)
            | Node::Call { .. }
            | Node::Arg(_)
            | Node::IndexDyn { .. }
            | Node::Fail(_) => self.eval(env, ctx, bindings, fr)?.as_f64()?,
        })
    }

    /// `truthy(&self.eval(..)?)`, computed without building a [`Val`].
    fn truth(
        &self,
        env: &Compiled<'a>,
        ctx: &ViCtx,
        bindings: &Bindings,
        fr: Fr<'_, 'a>,
    ) -> Result<bool, ValueInventionError> {
        Ok(match self {
            Node::Bool(b) => *b,
            // Short-circuit, as the value evaluator's boolean reductions do.
            Node::AndOr(want, args) => {
                for e in args {
                    if e.truth(env, ctx, bindings, fr)? == *want {
                        return Ok(*want);
                    }
                }
                !*want
            }
            Node::Not(e) => !e.truth(env, ctx, bindings, fr)?,
            Node::Cmp(c, a, b) => {
                // Compare at the WORKING precision: two values that round to
                // the same binary32 number must compare equal, exactly as the
                // value evaluator's comparison kernels do.
                let prec = crate::precision::active();
                let a = prec.round(a.num(env, ctx, bindings, fr)?);
                let b = prec.round(b.num(env, ctx, bindings, fr)?);
                match c {
                    CmpOp::Lt => a < b,
                    CmpOp::Gt => a > b,
                    CmpOp::Le => a <= b,
                    CmpOp::Ge => a >= b,
                    CmpOp::Eq => a == b,
                    CmpOp::Ne => a != b,
                }
            }
            Node::Ifelse(cte) => {
                let [c, t, e] = &**cte;
                if c.truth(env, ctx, bindings, fr)? {
                    t.truth(env, ctx, bindings, fr)?
                } else {
                    e.truth(env, ctx, bindings, fr)?
                }
            }
            _ => truthy(&self.eval(env, ctx, bindings, fr)?)?,
        })
    }
}

/// A 1-based gather of `arr` (the const-array factor `name`) at `subs`.
fn gather<'a>(
    name: &str,
    arr: &ArrayD<f64>,
    subs: &[Node<'a>],
    env: &Compiled<'a>,
    ctx: &ViCtx,
    bindings: &Bindings,
    fr: Fr<'_, 'a>,
) -> Result<f64, ValueInventionError> {
    let shape = arr.shape();
    let mut idx: smallvec::SmallVec<[usize; 4]> = smallvec::SmallVec::new();
    for (d, e) in subs.iter().enumerate() {
        let one_based = e.key_int(env, ctx, bindings, fr)?;
        let n = shape.get(d).copied().unwrap_or(0) as i64;
        idx.push((resolve_const_index(ctx, name, d, one_based, n)? - 1) as usize);
    }
    // Too FEW indices would reach ndarray and panic; too many
    // fail above, on an extent of 0.
    if idx.len() != arr.ndim() {
        return err(format!(
            "value-invention index target {name:?} has rank {}, but {} index(es) \
             were supplied",
            arr.ndim(),
            idx.len()
        ));
    }
    // A const-array factor is build-time data the evaluator did
    // not produce, so it rounds on read.
    Ok(crate::precision::round(arr[IxDyn(&idx)]))
}

/// Materialise an index-set-producing aggregate → the distinct member set (§5.5
/// sorted total order, via the relational engine). Returns the member list.
fn vi_materialize_producer(
    ctx: &ViCtx,
    node: &ExpressionNode,
) -> Result<Vec<Key>, ValueInventionError> {
    let key = node.key.as_deref().ok_or_else(|| {
        ValueInventionError::new("value-invention producer aggregate requires a `key` (§5.5)")
    })?;
    let ranges = ranges_of(node);
    let join = node.join.as_deref().unwrap_or(&[]);
    // Resolve join gates ONCE (a `join.overlap` broad-phase candidate set is built
    // a single time here). An OVERLAP gate then DRIVES enumeration from its
    // candidate pairs (`vi_enumerate_join`, Wall #1) — O(|candidates|) rather than
    // O(∏ranges) with a per-tuple membership test; other gate kinds enumerate the
    // full product.
    let gates = if join.is_empty() {
        Vec::new()
    } else {
        vi_resolve_join(join, &ranges, ctx)?
    };
    let column = format!(
        "the `key` of producer '{}'",
        node.id.as_deref().unwrap_or("")
    );
    let filter = node
        .filter
        .as_deref()
        .map(|f| Compiled::new(f, ctx, &ranges));
    let key = Compiled::new(key, ctx, &ranges);
    let mut members: Vec<Key> = Vec::new();
    vi_enumerate_join(&ranges, &gates, ctx, |bindings| {
        if let Some(f) = &filter {
            let pass = match f.eval(ctx, bindings)? {
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
        members.push(key_of(key.eval(ctx, bindings)?, bindings, &column)?);
        Ok(())
    })?;
    Ok(relational::distinct(&members))
}

// --------------------------------------------------------------------------- //
// Entry points
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

/// Run the build-time value-invention engine over a typed model and the
/// document's `index_sets` registry — the core every entry point calls.
///
/// `const_arrays` are the build-time factors the keys are computed from,
/// `params` the scalar parameter values a key reads (a parameter absent from
/// it reads its declared `default`), and `const_array_boundaries` the
/// out-of-range gather policy (see [`materialize_value_invention`]).
pub(crate) fn invent_values(
    model: &Model,
    index_sets: &HashMap<String, IndexSet>,
    const_arrays: &Factors<'_>,
    params: &HashMap<String, f64>,
    const_array_boundaries: &HashMap<String, Vec<BoundaryKind>>,
    ops: &crate::operator_refs::Instances,
) -> Result<ValueInventionResult, ValueInventionError> {
    let det = vi_detect(model);
    let mut result = ValueInventionResult {
        vi_var_names: det.vi_var_names.clone(),
        ..Default::default()
    };
    if det.producers.is_empty() {
        return Ok(result);
    }
    // Every operator instance a producer or a join column reaches, each body
    // compiled once per enumeration (esm-spec §9.6.4).
    let mut roots: Vec<Expr> = Vec::new();
    for (_, node) in &det.columns {
        roots.push(Expr::Operator(Arc::new((*node).clone())));
    }
    for &(_, node) in &det.producers {
        roots.push(Expr::Operator(Arc::new(node.clone())));
    }
    let held = ops
        .reachable(roots.iter())
        .map_err(|e| ValueInventionError::new(e.to_string()))?;
    let mut ctx = ViCtx {
        const_arrays,
        params,
        index_sets,
        variables: &model.variables,
        const_array_boundaries,
        maps: HashMap::new(),
        ops,
        held,
    };

    // Join columns (a producer's join may reference them). Each is
    // materialized at the element type of the variable it fills (esm-spec
    // §11.3.1). `None` unless the document declares a per-variable
    // `element_type`.
    for (vname, node) in &det.columns {
        let _prec = vi_variable_precision(vname);
        vi_materialize_column(&mut ctx, vname, node)?;
    }

    // The producers a derived set names (`from_faq`); no other is materialised.
    let named: HashSet<&str> = index_sets
        .values()
        .filter(|is| is.kind == "derived")
        .filter_map(|is| is.from_faq.as_deref())
        .collect();

    for &(rhs, node) in &det.producers {
        let node_id = node.id.as_deref().ok_or_else(|| {
            ValueInventionError::new(
                "value-invention producer aggregate requires an `id` naming it for `from_faq`",
            )
        })?;
        if !named.contains(node_id) {
            continue;
        }
        // §5.7 guard 2: a relational node may not run on the hot path.
        let continuous = cadence::is_continuous(rhs, model)
            .map_err(|e| ValueInventionError::new(format!("cadence classify failed: {e}")))?;
        if continuous {
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

/// Give every operator node of `v` that has no `args` an empty one: a raw
/// aggregate node (`{"op": "faq", "ranges": …}`) is commonly written without
/// it, and the typed node requires it.
fn with_operand_lists(v: &mut Value) {
    match v {
        Value::Object(m) => {
            if m.get("op").is_some_and(Value::is_string) && !m.contains_key("args") {
                m.insert("args".into(), Value::Array(Vec::new()));
            }
            m.values_mut().for_each(with_operand_lists);
        }
        Value::Array(a) => a.iter_mut().for_each(with_operand_lists),
        _ => {}
    }
}

/// Run the build-time value-invention engine over a raw model document.
///
/// Value invention mints new entities from data, once at setup: unique edge
/// IDs from a mesh, dense ranks from a categorical column, bin keys from
/// coordinates. This evaluates every value-invention aggregate in
/// `model_json` (a `faq` with `distinct: true`) and returns what it
/// materialized as a [`ValueInventionResult`]. Pass that result to
/// [`apply_value_invention`] to rewrite the model so the array runtime can
/// compile it. A caller holding a typed model calls
/// [`crate::simulate_array::run_value_invention`] instead.
///
/// - `model_json` is a model object, with the document's `index_sets`
///   registry beside its `variables` and `equations`. It is read as a typed
///   model; one with no `equations` has no producer.
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
/// Returns a [`ValueInventionError`] when the model or its index sets do not
/// read as typed ones, when a producer classifies as continuous (its entities
/// would change every step, `CONFORMANCE_SPEC.md` §5.7 guard 2), when a key
/// cannot be evaluated from the build-time data, or on an out-of-range gather
/// with no boundary policy.
pub fn materialize_value_invention(
    model_json: &Value,
    const_arrays: &HashMap<String, ArrayD<f64>>,
    params: &HashMap<String, f64>,
    const_array_boundaries: &HashMap<String, Vec<BoundaryKind>>,
) -> Result<ValueInventionResult, ValueInventionError> {
    let mut model_json = model_json.clone();
    let index_sets: HashMap<String, IndexSet> = match model_json
        .as_object_mut()
        .and_then(|m| m.remove("index_sets"))
    {
        Some(v) => serde_json::from_value(v).map_err(|e| {
            ValueInventionError::new(format!("value-invention: the index sets do not read: {e}"))
        })?,
        None => HashMap::new(),
    };
    if let Some(m) = model_json.as_object_mut() {
        m.entry("variables")
            .or_insert_with(|| Value::Object(Map::new()));
        m.entry("equations")
            .or_insert_with(|| Value::Array(Vec::new()));
    }
    with_operand_lists(&mut model_json);
    let model: Model = serde_json::from_value(model_json).map_err(|e| {
        ValueInventionError::new(format!("value-invention: the model does not read: {e}"))
    })?;
    invent_values(
        &model,
        &index_sets,
        &Factors::of(const_arrays),
        params,
        const_array_boundaries,
        crate::operator_refs::Instances::empty(),
    )
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
    model.equations.retain(|eq| match lhs_base(&eq.lhs) {
        Some(base) => !vi_var_names.contains(base),
        None => true,
    });
    if let Some(init) = &mut model.initialization_equations {
        init.retain(|eq| match lhs_base(&eq.lhs) {
            Some(base) => !vi_var_names.contains(base),
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

    /// Evaluate `e` as a body over `ranges` against `const_arrays`, scalar
    /// `params`, `variables` and `bnds`, at `bindings`.
    fn eval_in(
        e: &Expr,
        const_arrays: &HashMap<String, ArrayD<f64>>,
        params: &HashMap<String, f64>,
        variables: &IndexMap<String, ModelVariable>,
        bnds: &HashMap<String, Vec<BoundaryKind>>,
        bindings: &Bindings,
    ) -> Result<Val, ValueInventionError> {
        let factors = Factors::of(const_arrays);
        let index_sets = HashMap::new();
        let ctx = ViCtx {
            const_arrays: &factors,
            params,
            index_sets: &index_sets,
            variables,
            const_array_boundaries: bnds,
            maps: HashMap::new(),
            ops: crate::operator_refs::Instances::empty(),
            held: Vec::new(),
        };
        let ranges: Ranges = Ranges::new();
        Compiled::new(e, &ctx, &ranges).eval(&ctx, bindings)
    }

    #[test]
    fn a_nan_key_carries_the_out_of_range_code() {
        let params: HashMap<String, f64> = [("p".to_string(), f64::NAN)].into_iter().collect();
        let vars: IndexMap<String, ModelVariable> =
            serde_json::from_value(serde_json::json!({"p": {"type": "parameter"}})).unwrap();
        let bindings: Bindings = [("a".to_string(), 1)].into_iter().collect();
        let v = eval_in(
            &Expr::Variable("p".into()),
            &HashMap::new(),
            &params,
            &vars,
            &no_bounds(),
            &bindings,
        )
        .unwrap();
        let e = key_of(v, &bindings, "bin_col").unwrap_err();
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

    /// `index(name, subs…)` as an expression.
    fn gather_expr(name: &str, subs: &[i64]) -> Expr {
        let mut args = vec![Expr::Variable(name.into())];
        args.extend(subs.iter().map(|&i| Expr::Integer(i)));
        Expr::operator(ExpressionNode {
            op: "index".into(),
            args,
            ..Default::default()
        })
    }

    /// Gather `index(name, one_based)` against a 1-D const array under `bnds`.
    fn gather_1d(
        name: &str,
        data: &ArrayD<f64>,
        one_based: i64,
        bnds: &HashMap<String, Vec<BoundaryKind>>,
    ) -> Result<f64, ValueInventionError> {
        let const_arrays = ca(vec![(name, data.clone())]);
        match eval_in(
            &gather_expr(name, &[one_based]),
            &const_arrays,
            &HashMap::new(),
            &IndexMap::new(),
            bnds,
            &Bindings::default(),
        )? {
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
        let gather = |i: i64, j: i64| -> Result<f64, ValueInventionError> {
            match eval_in(
                &gather_expr("M", &[i, j]),
                &const_arrays,
                &HashMap::new(),
                &IndexMap::new(),
                &mixed,
                &Bindings::default(),
            )? {
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

    /// Two operator sub-trees share a structural id exactly when they are the
    /// same op over the same operands: an operand's kind or spelling, or the
    /// op, apart gives a new id; a field the evaluator does not read does not.
    #[test]
    fn tree_ids_match_equal_operands() {
        let tree: Expr = serde_json::from_value(serde_json::json!({"op": "+", "args": [
            {"op": "min", "args": ["u", "v"]},
            {"op": "min", "args": ["u", "v"]},
            {"op": "min", "args": ["v", "u"]},
            {"op": "min", "args": ["u", 1]},
            {"op": "min", "args": ["u", 1.5]},
            {"op": "min", "args": ["u", "v"], "wrt": "t"},
            {"op": "max", "args": ["u", "v"]},
            {"op": "*", "args": [{"op": "min", "args": ["u", "v"]}, 2]},
            {"op": "*", "args": [{"op": "min", "args": ["u", "v"]}, 2]}
        ]}))
        .unwrap();
        let mut ids = TreeIds::default();
        ids.id(&tree);
        let Expr::Operator(root) = &tree else {
            unreachable!()
        };
        let id = |e: &Expr| match e {
            Expr::Operator(n) => ids.of[&(&**n as *const ExpressionNode)],
            _ => unreachable!(),
        };
        let a = &root.args;
        // Operands of one class share an id.
        let class = [0, 0, 1, 2, 3, 0, 4, 5, 5];
        for i in 0..a.len() {
            for j in 0..a.len() {
                let want = class[i] == class[j];
                assert_eq!(id(&a[i]) == id(&a[j]), want, "{i} vs {j}");
            }
        }
        let Expr::Operator(prod) = &a[7] else {
            unreachable!()
        };
        assert_eq!(id(&a[0]), id(&prod.args[0]));
        assert_eq!(ids.count[&id(&a[0])], 5);
    }
}
