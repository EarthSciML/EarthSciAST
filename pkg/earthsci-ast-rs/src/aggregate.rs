//! Semiring registry and index-set range resolution for `aggregate` /
//! `arrayop` nodes — the M1 core of RFC `semiring-faq-unified-ir`.
//!
//! This module is the strict-superset refactor of the existing reducer:
//!
//! - **§5.1 Semiring.** [`Semiring`] is the closed, exhaustive registry of the
//!   five named `(⊕, ⊗)` pairs with their **normative** identities `(0̄, 1̄)`.
//!   The `reduce` field names ⊕ only; ⊗ and both identities come from the
//!   registry table here, never from the file. [`effective_reduce_kind`] is the
//!   single entry point the evaluator uses to pick the ⊕ reducer for a node:
//!   the semiring wins when present, otherwise the `reduce` string drives it.
//!   Both fields are closed enums, and a spelling outside either one is an
//!   error, not a silent fold to `Sum` — [`validate_oplus_spellings`] is the
//!   fail-fast gate that raises it before any rule is built.
//! - **§5.2 Index sets.** [`resolve_aggregate_ranges`] rewrites every
//!   `{ "from": <name> }` range reference against the model `index_sets`
//!   registry, **erroring on an undeclared name** (no implicit interval
//!   inference). `interval` and `categorical` sets resolve to dense static
//!   `[lo, hi]` intervals; a `ragged` set (a contracted/inner index only)
//!   resolves to a self-describing [`RangeSpec::RaggedDyn`] carrying its
//!   `offsets` backing-factor name, which the evaluator expands to the dynamic
//!   per-parent bound `[1, offsets[of…]]` per output tuple (the gather through
//!   the `values` factor is authored in the node body). `derived`
//!   (FAQ-materialized) sets are sized by the build-time relational layer, not
//!   the per-timestep evaluator (mirroring the Julia reference): pass its
//!   materialized extents to [`resolve_aggregate_ranges_with_extents`] and a
//!   derived reference resolves to the dense `[1, n]` on either an output or a
//!   contracted axis. Without them a derived set is still only admissible as a
//!   contracted axis, whose bound the geometry clip-ring registry supplies at
//!   eval time (RFC §8.1); a derived *output* axis errors clearly.
//! - **§5.6 Op tag.** [`is_aggregate_op`] accepts the canonical `"aggregate"`
//!   tag. (The legacy `"arrayop"` alias was removed in ESM v0.8.0.)

use std::collections::HashMap;

use thiserror::Error;

use crate::compile_error::CompileError;
use crate::types::{Expr, IndexSet, Model, RangeSpec};

/// The ⊕/⊗ operators the evaluator can fold with, each carrying its normative
/// identity (RFC §5.1). A single enum serves both the aggregation side (⊕) and
/// the product side (⊗) so the empty-reduction identity 0̄ and empty-product
/// identity 1̄ are pinned from one place.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReduceKind {
    Sum,
    Product,
    Max,
    Min,
    Or,
    And,
}

impl ReduceKind {
    /// The identity element — the value an empty fold returns. As a ⊕ this is
    /// 0̄ (empty reduction); as a ⊗ this is 1̄ (empty product).
    pub fn identity(self) -> f64 {
        match self {
            ReduceKind::Sum => 0.0,
            ReduceKind::Product => 1.0,
            ReduceKind::Max => f64::NEG_INFINITY,
            ReduceKind::Min => f64::INFINITY,
            ReduceKind::Or => 0.0,  // false
            ReduceKind::And => 1.0, // true
        }
    }

    /// Fold one term into the accumulator. The Boolean ops treat any non-zero
    /// value as true and return a crisp `0.0`/`1.0`.
    ///
    /// **Precision.** This is a reduction's ⊕ and is therefore one of the
    /// evaluator's operations: under `element_type: "Float32"` it rounds like
    /// any other, so an N-term sum accumulates in binary32 with N roundings
    /// rather than in binary64 with one. That is the whole point of the mode —
    /// a binary64 accumulator would silently make long sums *more* accurate
    /// than the binary32 reference they are meant to reproduce. The identities
    /// (`0`, `1`, `±inf`) are exact in binary32, so [`Self::identity`] needs no
    /// rounding.
    pub fn combine(self, acc: f64, term: f64) -> f64 {
        if crate::precision::is_f32() {
            return self.combine_f32(acc, term);
        }
        match self {
            ReduceKind::Sum => acc + term,
            ReduceKind::Product => acc * term,
            ReduceKind::Max => f64::max(acc, term),
            ReduceKind::Min => f64::min(acc, term),
            ReduceKind::Or => {
                if acc != 0.0 || term != 0.0 {
                    1.0
                } else {
                    0.0
                }
            }
            ReduceKind::And => {
                if acc != 0.0 && term != 0.0 {
                    1.0
                } else {
                    0.0
                }
            }
        }
    }

    /// [`Self::combine`] in binary32 — the arms of `combine`, narrowed.
    ///
    /// The arithmetic arms mirror the `Sum`/`Product`/`Max`/`Min` entries of
    /// `simulate_array::eval::binary_kernel_f32_of`
    /// (`Add`/`Mul`/`Max`/`Min`), which is what
    /// `vectorized::reduce_combine_op` maps them to on the whole-array path;
    /// `reduce_combine_f32_matches_binary_kernels` pins the two together so the
    /// per-cell fold and the vectorized fold cannot disagree.
    fn combine_f32(self, acc: f64, term: f64) -> f64 {
        let (a, t) = (acc as f32, term as f32);
        match self {
            ReduceKind::Sum => (a + t) as f64,
            ReduceKind::Product => (a * t) as f64,
            ReduceKind::Max => f32::max(a, t) as f64,
            ReduceKind::Min => f32::min(a, t) as f64,
            ReduceKind::Or => {
                if a != 0.0 || t != 0.0 {
                    1.0
                } else {
                    0.0
                }
            }
            ReduceKind::And => {
                if a != 0.0 && t != 0.0 {
                    1.0
                } else {
                    0.0
                }
            }
        }
    }
}

/// The closed, exhaustive semiring registry (RFC §5.1). A semiring is fully
/// specified by its two operators **and** their identities; adding one is a
/// spec change, not a per-file extension.
///
/// | `semiring` | ⊕ (`reduce`) | 0̄ | ⊗ | 1̄ |
/// |---|---|---|---|---|
/// | `sum_product` *(default)* | `+` | `0` | `×` | `1` |
/// | `max_product` | `max` | `-∞` | `×` | `1` |
/// | `min_sum` | `min` | `+∞` | `+` | `0` |
/// | `max_sum` | `max` | `-∞` | `+` | `0` |
/// | `bool_and_or` | `∨` | `false` | `∧` | `true` |
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Semiring {
    SumProduct,
    MaxProduct,
    MinSum,
    MaxSum,
    BoolAndOr,
}

impl Semiring {
    /// Parse a registry name; `None` for an unregistered name (the schema's
    /// closed enum normally rejects these before the evaluator is reached).
    pub fn from_name(name: &str) -> Option<Self> {
        Some(match name {
            "sum_product" => Semiring::SumProduct,
            "max_product" => Semiring::MaxProduct,
            "min_sum" => Semiring::MinSum,
            "max_sum" => Semiring::MaxSum,
            "bool_and_or" => Semiring::BoolAndOr,
            _ => return None,
        })
    }

    /// ⊕ — the aggregation operator named by `reduce`.
    pub fn oplus(self) -> ReduceKind {
        match self {
            Semiring::SumProduct => ReduceKind::Sum,
            Semiring::MaxProduct => ReduceKind::Max,
            Semiring::MinSum => ReduceKind::Min,
            Semiring::MaxSum => ReduceKind::Max,
            Semiring::BoolAndOr => ReduceKind::Or,
        }
    }

    /// ⊗ — the product operator. Applied in the node body for M1; defined here
    /// so the normative empty-product identity 1̄ (`otimes().identity()`) is
    /// pinned per §5.1 and asserted by conformance.
    pub fn otimes(self) -> ReduceKind {
        match self {
            Semiring::SumProduct => ReduceKind::Product,
            Semiring::MaxProduct => ReduceKind::Product,
            Semiring::MinSum => ReduceKind::Sum,
            Semiring::MaxSum => ReduceKind::Sum,
            Semiring::BoolAndOr => ReduceKind::And,
        }
    }
}

/// Why ⊕ could not be named: the node carries a spelling outside one of the
/// two closed schema enums.
///
/// [`effective_reduce_kind`] is consulted from three different error domains —
/// [`CompileError`], `value_invention::ValueInventionError`, and the
/// infallible array evaluator — so it reports the defect as this small
/// self-describing value and lets each caller render it into the error type it
/// owns rather than forcing one of those types on the others.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum BadOplus {
    /// `semiring` is not one of the five §5.1 registry names.
    #[error(
        "aggregate `semiring` is '{0}', which is not in the closed RFC §5.1 registry \
         (sum_product, max_product, min_sum, max_sum, bool_and_or)"
    )]
    Semiring(String),
    /// `reduce` is not one of the four spellings the schema's closed enum allows.
    #[error(
        "aggregate `reduce` is '{0}', which is not in the schema's closed enum \
         (+, *, max, min); a ⊕ outside it — the boolean `or` included — is named by \
         setting `semiring`, not by inventing a `reduce` spelling"
    )]
    Reduce(String),
}

/// Resolve the effective ⊕ reducer for an `aggregate` node.
///
/// Per RFC §5.1, when `semiring` is present it is authoritative: ⊕ and its
/// identity come from the registry, never the file. When absent, the `reduce`
/// string names ⊕ directly.
///
/// Both fields are CLOSED enums in `esm-schema.json`, and this function holds
/// that line rather than papering over a violation. It used to be total, with
/// two distinct fallbacks, and both were silent:
///
/// - An unregistered `semiring` fell through to the `reduce` string. That looks
///   conservative, but a node naming a semiring normally omits `reduce`
///   entirely (the semiring supersedes it) — so the fall-through's *common*
///   case landed on the `reduce` default and returned `Sum`, which is exactly
///   the silent mis-aggregation it was meant to avoid. It is now
///   [`BadOplus::Semiring`]: the presence of the key is authoritative even when
///   its value is unreadable. Julia's `_aggregate_oplus_identity` and Python's
///   `_resolve_semiring` both raise here, and this module's own
///   [`crate::pushdown_rewrite`] already refused rather than falling through,
///   so the fall-through made this function the sole outlier.
/// - An unrecognized `reduce` folded to `Sum`, so a typo (`"sum"`, `"mean"`)
///   mis-aggregated in silence. It is now [`BadOplus::Reduce`].
///
/// `reduce: None` and `reduce: Some("+")` both still mean `Sum` — that is the
/// schema's stated default, not a fallback.
///
/// Callers that cannot carry an error (a pattern matcher returning `Option`,
/// the evaluator) rely on [`validate_oplus_spellings`] having rejected the file
/// up front, and merely decline.
pub fn effective_reduce_kind(
    semiring: Option<&str>,
    reduce: Option<&str>,
) -> Result<ReduceKind, BadOplus> {
    if let Some(name) = semiring {
        return Semiring::from_name(name)
            .map(Semiring::oplus)
            .ok_or_else(|| BadOplus::Semiring(name.to_string()));
    }
    match reduce {
        None | Some("+") => Ok(ReduceKind::Sum),
        Some("*") => Ok(ReduceKind::Product),
        Some("max") => Ok(ReduceKind::Max),
        Some("min") => Ok(ReduceKind::Min),
        Some(other) => Err(BadOplus::Reduce(other.to_string())),
    }
}

/// Reject every `aggregate` node in `model` whose `semiring` / `reduce` lies
/// outside the closed schema enums, naming the offending spelling.
///
/// The fail-fast gate for the array runtime. [`effective_reduce_kind`] is
/// reached from seams with no error channel of their own — an
/// `Option`-returning pattern matcher (`extract_derivative_arrayop`) and the
/// infallible evaluator (`arrayop_spec`, whose `None` is a NaN sentinel) — so
/// folding the defect into their `None` would only trade one silent fallback
/// for another. The diagnostic is raised HERE instead: once, over the whole
/// model, before any rule is built. Called from `ArrayCompiled::from_model`
/// alongside the other §5.2 / §5.3 pre-passes, which leaves those seams with
/// nothing to do but decline on an input that can no longer reach them.
///
/// Read-only and unconditional, unlike [`resolve_aggregate_ranges`]: that pass
/// may skip a subtree because rewriting one would copy-on-write split shared
/// `Arc` payloads, whereas this one rewrites nothing and so must not skip.
pub fn validate_oplus_spellings(model: &Model) -> Result<(), CompileError> {
    for eq in &model.equations {
        check_expr_oplus(&eq.lhs)?;
        check_expr_oplus(&eq.rhs)?;
    }
    if let Some(init_eqs) = &model.initialization_equations {
        for eq in init_eqs {
            check_expr_oplus(&eq.lhs)?;
            check_expr_oplus(&eq.rhs)?;
        }
    }
    // As in `resolve_aggregate_ranges_with_extents`: what a variable still
    // carries is a parameter's `update`, whose expressions may embed an
    // aggregate too.
    let mut failure = None;
    for var in model.variables.values() {
        var.for_each_expression(&mut |expr| {
            if failure.is_none()
                && let Err(e) = check_expr_oplus(expr)
            {
                failure = Some(e);
            }
        });
    }
    match failure {
        Some(e) => Err(e),
        None => Ok(()),
    }
}

/// [`validate_oplus_spellings`] for one expression subtree.
fn check_expr_oplus(expr: &Expr) -> Result<(), CompileError> {
    let Expr::Operator(node) = expr else {
        return Ok(());
    };
    if is_aggregate_op(&node.op)
        && let Err(bad) = effective_reduce_kind(node.semiring.as_deref(), node.reduce.as_deref())
    {
        return Err(CompileError::build_err(bad.to_string()));
    }
    let mut failure = None;
    node.for_each_child(&mut |child| {
        if failure.is_none()
            && let Err(e) = check_expr_oplus(child)
        {
            failure = Some(e);
        }
    });
    match failure {
        Some(e) => Err(e),
        None => Ok(()),
    }
}

/// Whether `op` is the aggregate node tag. `"aggregate"` is the canonical tag
/// (RFC §5.6). The legacy `"arrayop"` alias was removed in ESM v0.8.0.
pub fn is_aggregate_op(op: &str) -> bool {
    op == "aggregate"
}

/// Rewrite every `{ "from": <name> }` range reference in `model` against the
/// document-scoped `index_sets` registry (RFC §5.2). Since v0.8.0 the registry
/// lives on the top-level document (one registry shared by all models), so it
/// is threaded in explicitly rather than read off the `Model`. Operates in
/// place; call once on an owned model before shape inference and rule building
/// so every downstream consumer sees only resolved [`RangeSpec::Interval`] /
/// [`RangeSpec::RaggedDyn`] forms (never an `IndexSetRef`).
///
/// Interval/categorical sets resolve to static intervals; a `ragged` contracted
/// index resolves to a [`RangeSpec::RaggedDyn`] dynamic bound. Errors on an
/// undeclared `from` name (no implicit interval inference), a `ragged` set used
/// as an output index or referenced without an `of` parent, and a `derived`
/// set (resolved by the build-time relational layer, not the evaluator).
///
/// An empty registry is fine: any `{from}` reference then errors as undeclared
/// (correct), and pure-interval files resolve as no-ops.
pub fn resolve_aggregate_ranges(
    model: &mut Model,
    index_sets: &HashMap<String, IndexSet>,
) -> Result<(), CompileError> {
    resolve_aggregate_ranges_with_extents(model, index_sets, empty_derived_extents())
}

/// The shared empty value-invention extent map.
///
/// Handed to every resolver / evaluator seam that has no extents to offer, so
/// the no-value-invention path allocates nothing and reads *byte-identically*
/// to the pre-extent code: an empty map's `get` always misses, so every arm
/// falls straight through to the behaviour it had before.
pub(crate) fn empty_derived_extents() -> &'static HashMap<String, i64> {
    static EMPTY: std::sync::OnceLock<HashMap<String, i64>> = std::sync::OnceLock::new();
    EMPTY.get_or_init(HashMap::new)
}

/// [`resolve_aggregate_ranges`] with the build-time **value-invention derived
/// extents** in hand.
///
/// `derived_extents` maps a *producing aggregate's* `id` — the thing a
/// `kind:"derived"` index set names in its `from_faq` — to the cardinality of
/// the distinct member set that producer materialized
/// ([`crate::value_invention::ValueInventionResult::extents`]). A derived set
/// whose `from_faq` is present resolves to the dense interval `[1, n]` and is
/// therefore legal as an **output** index too, exactly as in the Julia
/// (`_resolve_one_index_set_ref`) and Python (`_resolve_range_spec`) references:
/// once the relational engine has run, that axis has a statically-known extent
/// like any interval set.
///
/// This is what lets a real ISRM-shaped document evaluate. Its emission factors
/// (`E_VOC`, `E_NOx`, …) are *shaped on* the invented set `emis_src_cells` and
/// its concentration observeds *contract over* it; without the extents both the
/// output-axis and the contracted-axis references dead-end — the output axis on
/// the "derived output index" rejection below, the contracted axis on an
/// unmaterialized runtime ring (extent `0`, i.e. a silently empty reduction).
///
/// Pass an empty map (or use [`resolve_aggregate_ranges`]) for the
/// no-value-invention case; a derived set then keeps its prior treatment — a
/// dynamic [`RangeSpec::DerivedDyn`] contracted bound resolved per-eval from the
/// geometry clip-ring registry (RFC §8.1).
pub fn resolve_aggregate_ranges_with_extents(
    model: &mut Model,
    index_sets: &HashMap<String, IndexSet>,
    derived_extents: &HashMap<String, i64>,
) -> Result<(), CompileError> {
    for eq in &mut model.equations {
        resolve_expr_ranges_with_extents(&mut eq.lhs, index_sets, derived_extents)?;
        resolve_expr_ranges_with_extents(&mut eq.rhs, index_sets, derived_extents)?;
    }
    if let Some(init_eqs) = &mut model.initialization_equations {
        for eq in init_eqs {
            resolve_expr_ranges_with_extents(&mut eq.lhs, index_sets, derived_extents)?;
            resolve_expr_ranges_with_extents(&mut eq.rhs, index_sets, derived_extents)?;
        }
    }
    // An unknown's defining expression is an EQUATION from esm 1.0.0, already
    // walked above. What is still carried ON a variable is a parameter's
    // `update` — its trigger, its value expression, and a `from` binding's
    // unit conversion — so those are resolved here.
    let mut failure = None;
    for var in model.variables.values_mut() {
        var.for_each_expression_mut(&mut |expr| {
            if failure.is_none()
                && let Err(e) = resolve_expr_ranges_with_extents(expr, index_sets, derived_extents)
            {
                failure = Some(e);
            }
        });
    }
    match failure {
        Some(e) => Err(e),
        None => Ok(()),
    }
}

/// Recursively resolve `{from}` range references on a node and all its children.
/// `pub(crate)` so standalone build-time expressions — §6.6.5 analytic
/// `reference`s and coordinate-expression `ic` RHSs, which live outside the
/// model equations [`resolve_aggregate_ranges`] walks — can be resolved
/// against the document registry before evaluation
/// (`crate::simulate_array::eval_buildtime_field`).
pub(crate) fn resolve_expr_ranges(
    expr: &mut Expr,
    index_sets: &HashMap<String, IndexSet>,
) -> Result<(), CompileError> {
    resolve_expr_ranges_with_extents(expr, index_sets, empty_derived_extents())
}

/// `true` iff any node in `e`'s subtree still carries an unresolved
/// `{ "from": <index set> }` range reference. The sharing-aware gate for
/// [`resolve_expr_ranges_with_extents`]: after load-time interning
/// (`crate::intern`) operator payloads are shared `Arc`s, and a mutable
/// descent copy-on-write splits every node it touches — so a subtree whose
/// ranges are all already concrete (every subtree of a discretized stencil,
/// which emits dense `[lo, hi]` intervals) is left fully shared.
fn contains_unresolved_range(e: &Expr) -> bool {
    match e {
        Expr::Operator(node) => {
            node.ranges.as_ref().is_some_and(|r| {
                r.values()
                    .any(|s| matches!(s, RangeSpec::IndexSetRef { .. }))
            }) || node.any_child(&mut contains_unresolved_range)
        }
        _ => false,
    }
}

/// [`resolve_expr_ranges`] with the value-invention derived extents in hand —
/// see [`resolve_aggregate_ranges_with_extents`] for what `derived_extents`
/// means and why an ISRM-shaped document needs it.
///
/// `pub` (not `pub(crate)`) because a Rust *runner* that drives value invention
/// itself — rather than through [`crate::simulate_array::ArrayCompiled`] — holds
/// a bare [`Expr`] and the engine's extents, and has no other way to turn the
/// document's `{ "from": <derived set> }` references into evaluable bounds.
pub fn resolve_expr_ranges_with_extents(
    expr: &mut Expr,
    index_sets: &HashMap<String, IndexSet>,
    derived_extents: &HashMap<String, i64>,
) -> Result<(), CompileError> {
    // Sharing-aware gate: only branches actually containing an unresolved
    // reference are descended (and thereby copy-on-write split).
    if !contains_unresolved_range(expr) {
        return Ok(());
    }
    let Some(node) = expr.node_mut() else {
        return Ok(());
    };

    // Resolve this node's own ranges in place. A ragged inner range carries no
    // static upper bound; it resolves to a self-describing `RaggedDyn` that the
    // evaluator expands per output tuple. Output indices may not be ragged
    // (their extent must be statically known to size the result array), so the
    // output/contracted distinction is passed down to reject that with a clear
    // error. Clone the output names up front to avoid aliasing `node.ranges`.
    let output_names: std::collections::HashSet<String> = node
        .output_idx
        .clone()
        .unwrap_or_default()
        .into_iter()
        .collect();
    if let Some(ranges) = &mut node.ranges {
        for (idx_name, spec) in ranges.iter_mut() {
            let is_output = output_names.contains(idx_name);
            let resolved = match spec {
                // Already-concrete and already-resolved forms are idempotent.
                RangeSpec::Interval(_)
                | RangeSpec::Strided(_)
                | RangeSpec::RaggedDyn { .. }
                | RangeSpec::DerivedDyn { .. } => continue,
                RangeSpec::IndexSetRef { from, of } => resolve_index_set_ref(
                    from,
                    of.as_deref(),
                    idx_name,
                    is_output,
                    index_sets,
                    derived_extents,
                )?,
            };
            *spec = match resolved {
                ResolvedRange::Static(iv) => RangeSpec::Interval(iv),
                ResolvedRange::Ragged { offsets, of } => RangeSpec::RaggedDyn { offsets, of },
                ResolvedRange::Derived { from_faq } => RangeSpec::DerivedDyn { from_faq },
            };
        }
    }

    // Recurse into every expression-bearing child via the canonical walker
    // (args, lower, upper, expr, filter, values, axes, key, bindings) so that
    // ranges nested in a `filter` predicate, a grouping `key`, or a template
    // `bindings` value are resolved too — not just the hand-picked subset this
    // used to enumerate. `for_each_child_mut`'s closure cannot return, so the
    // first resolution error is captured and propagated afterwards.
    let mut err: Option<CompileError> = None;
    node.for_each_child_mut(&mut |child| {
        if err.is_none()
            && let Err(e) = resolve_expr_ranges_with_extents(child, index_sets, derived_extents)
        {
            err = Some(e);
        }
    });
    match err {
        Some(e) => Err(e),
        None => Ok(()),
    }
}

/// The outcome of resolving one `{ from, of }` reference: either a static dense
/// interval (interval/categorical sets) or a dynamic ragged bound that the
/// evaluator expands per output tuple from the `offsets` backing factor.
#[derive(Debug)]
enum ResolvedRange {
    Static([i64; 2]),
    Ragged {
        offsets: String,
        of: Vec<String>,
    },
    /// A FAQ-materialized derived range (RFC §5.5 / §8.1): its extent is the
    /// vertex count of the ring the `from_faq` producer node materializes at
    /// eval time, so it carries only the producer id (resolved dynamically).
    Derived {
        from_faq: String,
    },
}

/// Resolve one `{ from, of }` reference.
///
/// Interval and categorical sets resolve to a 1-based dense interval
/// ([`ResolvedRange::Static`] `[1, size]` / `[1, |members|]`), matching the
/// existing file-level range convention; any `of` on the reference is ignored
/// for these (their extent is static), mirroring the Julia reference.
///
/// A `ragged` set resolves to a [`ResolvedRange::Ragged`] dynamic bound — but
/// only as a contracted (inner) index: a ragged *output* index is rejected
/// (`is_output`), since the result array's extent must be statically known. The
/// dynamic upper bound `offsets[of…]` needs the parent index variable(s) from
/// the *reference's* `of` (rejected if empty) and the `offsets` backing factor
/// from the set definition; the member gather through `values` is authored in
/// the node body, so it is not consulted here.
///
/// A `derived` (FAQ-materialized) set resolves one of two ways, in this order:
///
/// 1. **Value-invention extent known** — its `from_faq` producer id is a key of
///    `derived_extents`, so the relational engine has already materialized the
///    distinct member set and its cardinality `n` is a build-time constant. The
///    reference resolves to the dense [`ResolvedRange::Static`] `[1, n]`, and is
///    legal as an OUTPUT index as well: the axis is no less statically sized
///    than an `interval` set's. (Julia `_resolve_one_index_set_ref`, Python
///    `_resolve_range_spec`.)
/// 2. **Not materialized** — the geometry clip-ring case (RFC §8.1). It resolves
///    to a [`ResolvedRange::Derived`] dynamic bound carrying its `from_faq`
///    producer id, and, like a ragged set, only as a contracted (inner) index: a
///    derived *output* index is rejected (`is_output`), since the result array's
///    extent must be statically known. The per-eval upper bound is the vertex
///    count of the ring the `from_faq` node materializes at runtime.
fn resolve_index_set_ref(
    from: &str,
    of: Option<&[String]>,
    idx_name: &str,
    is_output: bool,
    index_sets: &HashMap<String, IndexSet>,
    derived_extents: &HashMap<String, i64>,
) -> Result<ResolvedRange, CompileError> {
    let set = index_sets.get(from).ok_or_else(|| {
        CompileError::build_err(format!(
            "aggregate range '{idx_name}' references index set '{from}', which is not declared \
                 in the document `index_sets` registry (no implicit interval inference; RFC \
                 semiring-faq-unified-ir §5.2)"
        ))
    })?;

    match set.kind.as_str() {
        "interval" => {
            let size = set.size.ok_or_else(|| {
                CompileError::build_err(format!(
                    "index set '{from}' has kind \"interval\" but no `size`"
                ))
            })?;
            Ok(ResolvedRange::Static([1, size]))
        }
        "categorical" => {
            let n = set
                .members
                .as_ref()
                .map(|m| m.len() as i64)
                .ok_or_else(|| {
                    CompileError::build_err(format!(
                        "index set '{from}' has kind \"categorical\" but no `members`"
                    ))
                })?;
            Ok(ResolvedRange::Static([1, n]))
        }
        "ragged" => {
            // A ragged set's per-tuple length is a function of its parent
            // index, so it can size a reduction but not the output array.
            if is_output {
                return Err(CompileError::UnsupportedFeatureError {
                    feature: "ragged output index".to_string(),
                    message: format!(
                        "aggregate output index '{idx_name}' references ragged index set '{from}'; \
                         a ragged set's extent is per-parent dynamic and may only be a contracted \
                         (reduction) index, not an output index (RFC semiring-faq-unified-ir §5.2)"
                    ),
                });
            }
            let parents = of.unwrap_or_default();
            if parents.is_empty() {
                return Err(CompileError::build_err(format!(
                    "ragged index set '{from}' (aggregate range '{idx_name}') is referenced \
                     without an `of` parent index; a ragged set's length is a function of its \
                     parent (RFC semiring-faq-unified-ir §5.2)"
                )));
            }
            let offsets = set.offsets.clone().ok_or_else(|| {
                CompileError::build_err(format!(
                    "ragged index set '{from}' (aggregate range '{idx_name}') requires an \
                             `offsets` backing factor giving |set(parent)| per parent tuple"
                ))
            })?;
            Ok(ResolvedRange::Ragged {
                offsets,
                of: parents.to_vec(),
            })
        }
        "derived" => {
            // A FAQ-materialized derived set (RFC §5.5 / §8.1) is sized by the
            // producer named in its `from_faq`. Which producer that is decides
            // *when* the extent is known, and hence which of the two arms below
            // applies — so read the id first, and fail loudly if it is absent
            // (an unnamed producer can be resolved by neither arm).
            let from_faq =
                set.from_faq
                    .clone()
                    .ok_or_else(|| {
                        CompileError::build_err(format!(
                            "derived index set '{from}' (aggregate range '{idx_name}') is missing \
                             `from_faq` naming its producing FAQ node (RFC semiring-faq-unified-ir §5.5)"
                        ))
                    })?;
            // (1) The BUILD-TIME relational producer: the value-invention engine
            //     (skolem/distinct/rank, RFC §6.1) already enumerated the distinct
            //     member set and handed us its cardinality, keyed by the producing
            //     aggregate's `id`. That is a constant by the time any evaluation
            //     happens, so the axis is dense `[1, n]` — and, unlike the runtime
            //     ring below, it is a legal OUTPUT extent: this is what lets an
            //     ISRM emission factor be *shaped on* the invented cell set.
            if let Some(&n) = derived_extents.get(&from_faq) {
                return Ok(ResolvedRange::Static([1, n]));
            }
            // (2) The RUNTIME geometry producer (the `intersect_polygon` clip):
            //     the extent is the registered ring's distinct-vertex count, read
            //     per-eval. Like a ragged set it has no statically-known extent,
            //     so it may size a reduction (contracted index) but not an output
            //     array (`is_output`).
            if is_output {
                return Err(CompileError::UnsupportedFeatureError {
                    feature: "derived output index".to_string(),
                    message: format!(
                        "aggregate output index '{idx_name}' references derived index set '{from}'; \
                         a derived (FAQ-materialized) set's extent is data-dependent and may only \
                         be a contracted (reduction) index, not an output index, unless its \
                         `from_faq` producer '{from_faq}' has a build-time value-invention extent \
                         (RFC semiring-faq-unified-ir §5.5 / §8.1)"
                    ),
                });
            }
            Ok(ResolvedRange::Derived { from_faq })
        }
        other => Err(CompileError::build_err(format!(
            "index set '{from}' has unknown kind '{other}'"
        ))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::{Equation, ExpressionNode};

    fn interval(size: i64) -> IndexSet {
        IndexSet {
            kind: "interval".into(),
            size: Some(size),
            members: None,
            from_faq: None,
            member_factor: None,
            of: None,
            offsets: None,
            values: None,
        }
    }

    fn ragged(offsets: Option<&str>) -> IndexSet {
        IndexSet {
            kind: "ragged".into(),
            size: None,
            members: None,
            from_faq: None,
            member_factor: None,
            of: Some(vec!["cells".into()]),
            offsets: offsets.map(str::to_string),
            values: Some("edgesOnCell".into()),
        }
    }

    /// [`resolve_index_set_ref`] with NO value-invention extents — the shape
    /// every case below but [`derived_set_with_a_value_invention_extent_is_dense`]
    /// exercises, and the one [`resolve_aggregate_ranges`] itself uses.
    fn resolve_ref(
        from: &str,
        of: Option<&[String]>,
        idx_name: &str,
        is_output: bool,
        index_sets: &HashMap<String, IndexSet>,
    ) -> Result<ResolvedRange, CompileError> {
        resolve_index_set_ref(
            from,
            of,
            idx_name,
            is_output,
            index_sets,
            empty_derived_extents(),
        )
    }

    /// Unwrap a [`ResolvedRange::Static`] in tests, panicking otherwise.
    fn static_bounds(r: ResolvedRange) -> [i64; 2] {
        match r {
            ResolvedRange::Static(iv) => iv,
            ResolvedRange::Ragged { .. } => panic!("expected a static range, got ragged"),
            ResolvedRange::Derived { .. } => panic!("expected a static range, got derived"),
        }
    }

    #[test]
    fn semiring_identities_match_rfc_table() {
        // (semiring, 0̄ = ⊕ identity, 1̄ = ⊗ identity) per RFC §5.1.
        let cases = [
            (Semiring::SumProduct, 0.0, 1.0),
            (Semiring::MaxProduct, f64::NEG_INFINITY, 1.0),
            (Semiring::MinSum, f64::INFINITY, 0.0),
            (Semiring::MaxSum, f64::NEG_INFINITY, 0.0),
            (Semiring::BoolAndOr, 0.0, 1.0), // false, true
        ];
        for (sr, zero_bar, one_bar) in cases {
            assert_eq!(sr.oplus().identity(), zero_bar, "{sr:?} 0̄");
            assert_eq!(sr.otimes().identity(), one_bar, "{sr:?} 1̄");
        }
    }

    #[test]
    fn semiring_is_authoritative_over_reduce() {
        // Semiring present → its ⊕ wins regardless of (or absent) `reduce`.
        assert_eq!(
            effective_reduce_kind(Some("min_sum"), None),
            Ok(ReduceKind::Min)
        );
        assert_eq!(
            effective_reduce_kind(Some("max_sum"), Some("+")),
            Ok(ReduceKind::Max)
        );
        assert_eq!(
            effective_reduce_kind(Some("max_product"), None),
            Ok(ReduceKind::Max)
        );
        assert_eq!(
            effective_reduce_kind(Some("bool_and_or"), None),
            Ok(ReduceKind::Or)
        );
        // No semiring → the `reduce` string; absent and "+" are both the
        // schema's stated DEFAULT of Sum, not a fallback.
        assert_eq!(effective_reduce_kind(None, None), Ok(ReduceKind::Sum));
        assert_eq!(effective_reduce_kind(None, Some("+")), Ok(ReduceKind::Sum));
        assert_eq!(
            effective_reduce_kind(None, Some("*")),
            Ok(ReduceKind::Product)
        );
        assert_eq!(
            effective_reduce_kind(None, Some("max")),
            Ok(ReduceKind::Max)
        );
        assert_eq!(
            effective_reduce_kind(None, Some("min")),
            Ok(ReduceKind::Min)
        );
    }

    #[test]
    fn spellings_outside_the_closed_enums_are_rejected() {
        // An unregistered `semiring` no longer falls through to `reduce`: the
        // presence of the key is authoritative even when its value is not
        // readable, matching Julia and Python. (This case previously returned
        // `Min`.)
        assert_eq!(
            effective_reduce_kind(Some("bogus"), Some("min")),
            Err(BadOplus::Semiring("bogus".to_string()))
        );
        // ...and with `reduce` absent — the shape a semiring node normally has
        // — the old fall-through silently produced Sum.
        assert_eq!(
            effective_reduce_kind(Some("bogus"), None),
            Err(BadOplus::Semiring("bogus".to_string()))
        );
        // A `reduce` outside the schema's closed enum is an error, not Sum.
        for bad in ["sum", "prod", "mean", "and", ""] {
            assert_eq!(
                effective_reduce_kind(None, Some(bad)),
                Err(BadOplus::Reduce(bad.to_string())),
                "reduce={bad:?}"
            );
        }
        // `or` names a legitimate ⊕, but only through `bool_and_or`; it is not
        // a `reduce` spelling the schema admits.
        assert_eq!(
            effective_reduce_kind(None, Some("or")),
            Err(BadOplus::Reduce("or".to_string()))
        );
        assert_eq!(
            effective_reduce_kind(Some("bool_and_or"), None),
            Ok(ReduceKind::Or)
        );
    }

    #[test]
    fn validate_oplus_spellings_names_the_offending_spelling() {
        let bad_agg = |semiring: Option<&str>, reduce: Option<&str>| {
            let mut node = ExpressionNode {
                op: "aggregate".to_string(),
                ..Default::default()
            };
            node.semiring = semiring.map(str::to_string);
            node.reduce = reduce.map(str::to_string);
            node.expr = Some(Box::new(Expr::Variable("x".to_string())));
            Expr::Operator(node.into())
        };
        let model_with = |rhs: Expr| {
            let mut m = Model::default();
            m.equations.push(Equation {
                lhs: Expr::Variable("y".to_string()),
                rhs,
                ..Default::default()
            });
            m
        };

        // In-enum spellings pass, including the absent/default form.
        for ok in [
            bad_agg(None, None),
            bad_agg(None, Some("max")),
            bad_agg(Some("bool_and_or"), None),
        ] {
            assert!(validate_oplus_spellings(&model_with(ok)).is_ok());
        }

        let err = validate_oplus_spellings(&model_with(bad_agg(None, Some("mean"))))
            .expect_err("an out-of-enum `reduce` must be rejected");
        assert!(err.to_string().contains("mean"), "{err}");

        let err = validate_oplus_spellings(&model_with(bad_agg(Some("bogus"), None)))
            .expect_err("an unregistered `semiring` must be rejected");
        assert!(err.to_string().contains("bogus"), "{err}");

        // The walk descends into nested subtrees, not just the equation root.
        let nested = Expr::Operator(
            ExpressionNode {
                op: "+".to_string(),
                args: vec![Expr::Variable("z".to_string()), bad_agg(None, Some("mean"))],
                ..Default::default()
            }
            .into(),
        );
        let err = validate_oplus_spellings(&model_with(nested))
            .expect_err("a nested aggregate must be reached");
        assert!(err.to_string().contains("mean"), "{err}");
    }

    #[test]
    fn or_and_reductions_are_crisp_boolean() {
        assert_eq!(ReduceKind::Or.combine(0.0, 0.0), 0.0);
        assert_eq!(ReduceKind::Or.combine(0.0, 3.0), 1.0);
        assert_eq!(ReduceKind::Or.combine(2.0, 0.0), 1.0);
        assert_eq!(ReduceKind::And.combine(1.0, 1.0), 1.0);
        assert_eq!(ReduceKind::And.combine(1.0, 0.0), 0.0);
        assert_eq!(ReduceKind::And.combine(0.0, 0.0), 0.0);
    }

    #[test]
    fn aggregate_op_alias() {
        assert!(is_aggregate_op("aggregate"));
        assert!(!is_aggregate_op("arrayop"));
        assert!(!is_aggregate_op("makearray"));
        assert!(!is_aggregate_op("+"));
    }

    #[test]
    fn resolve_interval_and_categorical_from() {
        let mut index_sets = HashMap::new();
        index_sets.insert("cells".to_string(), interval(5));
        index_sets.insert(
            "county".to_string(),
            IndexSet {
                kind: "categorical".into(),
                size: None,
                members: Some(vec![
                    serde_json::json!("Champaign"),
                    serde_json::json!("Cook"),
                    serde_json::json!("Sangamon"),
                ]),
                from_faq: None,
                member_factor: None,
                of: None,
                offsets: None,
                values: None,
            },
        );
        assert_eq!(
            static_bounds(resolve_ref("cells", None, "i", false, &index_sets).unwrap()),
            [1, 5]
        );
        assert_eq!(
            static_bounds(resolve_ref("county", None, "c", false, &index_sets).unwrap()),
            [1, 3]
        );
        // An `of` on a reference to a *static* set is ignored (its extent is
        // static), mirroring the Julia reference — it no longer errors.
        assert_eq!(
            static_bounds(
                resolve_ref("cells", Some(&["i".into()]), "i", false, &index_sets).unwrap()
            ),
            [1, 5]
        );
    }

    #[test]
    fn undeclared_from_errors_naming_the_set() {
        let index_sets: HashMap<String, IndexSet> = HashMap::new();
        let err = resolve_ref("nonesuch", None, "i", false, &index_sets).unwrap_err();
        let msg = format!("{err:?}");
        assert!(msg.contains("nonesuch"), "error should name the set: {msg}");
    }

    #[test]
    fn ragged_contracted_index_resolves_to_dynamic_bound() {
        // A ragged set used as a *contracted* index (is_output=false) resolves
        // to a RaggedDyn carrying the `offsets` factor and the reference's `of`
        // parents — the per-output-tuple bound `[1, offsets[of…]]`.
        let mut index_sets = HashMap::new();
        index_sets.insert("edges".to_string(), ragged(Some("nEdgesOnCell")));
        let resolved = resolve_ref("edges", Some(&["i".into()]), "k", false, &index_sets).unwrap();
        match resolved {
            ResolvedRange::Ragged { offsets, of } => {
                assert_eq!(offsets, "nEdgesOnCell");
                assert_eq!(of, vec!["i".to_string()]);
            }
            ResolvedRange::Static(iv) => panic!("expected ragged, got static {iv:?}"),
            ResolvedRange::Derived { from_faq } => {
                panic!("expected ragged, got derived {from_faq}")
            }
        }
    }

    #[test]
    fn ragged_as_output_index_is_rejected() {
        // A ragged set may not be an output index: the result array's extent
        // must be statically known.
        let mut index_sets = HashMap::new();
        index_sets.insert("edges".to_string(), ragged(Some("nEdgesOnCell")));
        let err = resolve_ref("edges", Some(&["i".into()]), "k", true, &index_sets).unwrap_err();
        let msg = format!("{err:?}");
        assert!(msg.contains("ragged"), "error should mention ragged: {msg}");
    }

    #[test]
    fn ragged_without_of_parent_is_rejected() {
        // A ragged set's length is a function of its parent, so a reference
        // without an `of` parent index is rejected.
        let mut index_sets = HashMap::new();
        index_sets.insert("edges".to_string(), ragged(Some("nEdgesOnCell")));
        assert!(resolve_ref("edges", None, "k", false, &index_sets).is_err());
        assert!(resolve_ref("edges", Some(&[]), "k", false, &index_sets).is_err());
    }

    #[test]
    fn ragged_missing_offsets_factor_is_rejected() {
        // A ragged set with no `offsets` backing factor cannot produce a bound.
        let mut index_sets = HashMap::new();
        index_sets.insert("edges".to_string(), ragged(None));
        assert!(resolve_ref("edges", Some(&["i".into()]), "k", false, &index_sets).is_err());
    }

    #[test]
    fn derived_index_set_resolves_as_contracted_but_rejects_as_output() {
        // A `derived` (FAQ-materialized) set sizes a reduction from the ring its
        // `from_faq` producer materializes at runtime (RFC §8.1): as a contracted
        // index it resolves to a deferred `Derived` bound; as an output index it
        // is rejected (its extent is not statically known to size the result).
        let mut index_sets = HashMap::new();
        index_sets.insert(
            "clip_ring".to_string(),
            IndexSet {
                kind: "derived".into(),
                size: None,
                members: None,
                from_faq: Some("overlap_clip".into()),
                member_factor: None,
                of: None,
                offsets: None,
                values: None,
            },
        );
        // Contracted (is_output=false): resolves, carrying the producer id.
        match resolve_ref("clip_ring", None, "v", false, &index_sets).unwrap() {
            ResolvedRange::Derived { from_faq } => assert_eq!(from_faq, "overlap_clip"),
            other => panic!("expected Derived, got {other:?}"),
        }
        // Output (is_output=true): rejected.
        let err = resolve_ref("clip_ring", None, "v", true, &index_sets).unwrap_err();
        let msg = format!("{err:?}");
        assert!(
            msg.contains("derived output index"),
            "error should reject a derived output index: {msg}"
        );
    }

    #[test]
    fn derived_set_with_a_value_invention_extent_is_dense() {
        // Once the relational engine has materialized the producer, its distinct-set
        // cardinality makes the axis as statically sized as an `interval` — so it
        // resolves to `[1, n]` and is admissible as an OUTPUT index too (the shape
        // an ISRM emission factor takes over the invented source-cell set).
        let mut index_sets = HashMap::new();
        index_sets.insert(
            "emis_src_cells".to_string(),
            IndexSet {
                kind: "derived".into(),
                size: None,
                members: None,
                from_faq: Some("emis_src_cells_faq".into()),
                member_factor: None,
                of: None,
                offsets: None,
                values: None,
            },
        );
        let extents: HashMap<String, i64> = HashMap::from([("emis_src_cells_faq".to_string(), 4)]);

        for is_output in [false, true] {
            let r = resolve_index_set_ref(
                "emis_src_cells",
                None,
                "s",
                is_output,
                &index_sets,
                &extents,
            )
            .unwrap_or_else(|e| panic!("is_output={is_output} should resolve: {e:?}"));
            assert_eq!(static_bounds(r), [1, 4]);
        }

        // A producer the engine did NOT materialize keeps the runtime-ring
        // treatment: the extents map is consulted by producer id, not by set name.
        let other: HashMap<String, i64> = HashMap::from([("some_other_faq".to_string(), 7)]);
        match resolve_index_set_ref("emis_src_cells", None, "s", false, &index_sets, &other)
            .unwrap()
        {
            ResolvedRange::Derived { from_faq } => assert_eq!(from_faq, "emis_src_cells_faq"),
            other => panic!("expected the deferred Derived bound, got {other:?}"),
        }
    }

    #[test]
    fn derived_index_set_without_from_faq_is_rejected() {
        // A `derived` set must name its producer node via `from_faq`.
        let mut index_sets = HashMap::new();
        index_sets.insert(
            "bad_set".to_string(),
            IndexSet {
                kind: "derived".into(),
                size: None,
                members: None,
                from_faq: None,
                member_factor: None,
                of: None,
                offsets: None,
                values: None,
            },
        );
        let err = resolve_ref("bad_set", None, "e", false, &index_sets).unwrap_err();
        let msg = format!("{err:?}");
        assert!(
            msg.contains("from_faq"),
            "error should mention the missing from_faq: {msg}"
        );
    }
}
