//! Native array runtime for `arrayop`, `makearray`, `index`, `reshape`,
//! `transpose`, `concat`, and `broadcast` expression nodes (gt-oxr).
//!
//! This module sits alongside [`crate::simulate`] and handles the subset of
//! ESM models that use array-shaped state variables and the array-op AST
//! nodes introduced in gt-t5c. It is invoked from [`crate::simulate`] when
//! the top-level dispatcher detects array-op nodes in the file; pure-scalar
//! models continue to go through the existing scalar interpreter.
//!
//! ## Approach
//!
//! The flat state vector that diffsol consumes is a contiguous
//! concatenation of per-variable blocks. Each array variable occupies a
//! column-major-ordered block sized by its inferred shape; scalar
//! variables occupy a single slot. Shape inference walks every `index`
//! call and every `arrayop` `ranges` dict to compute per-variable, per-
//! dimension bounds.
//!
//! At RHS evaluation time the interpreter wraps the flat state slice into
//! [`ndarray::ArrayD`] views (one per variable), binds `arrayop` loop
//! indices into a context, and evaluates each equation's body expression
//! into a [`Value`] — either `Scalar(f64)` or `Array(ArrayD<f64>)`. For
//! array-producing operators (`reshape`, `transpose`, `concat`,
//! `broadcast`, `makearray`) the whole array is materialised as an
//! intermediate so downstream `index` extractions can select any element.
//!
//! Column-major ordering is the convention used by the Julia sibling and
//! reflected in the cross-language conformance fixtures (e.g.
//! `arrayop_11_reshape_roundtrip.esm`).
//!
//! ## Subsystems
//!
//! The runtime is split along its subsystem seams:
//!
//! * [`compile`] — the build path: array-op/spatial file detection, subsystem
//!   mounting (esm-spec §4.6), ragged keyed-factor scoping, the staged
//!   `from_model` lowering, and shape-inference / LHS-parsing helpers.
//! * [`eval`] — the per-cell oracle interpreter (the correctness reference),
//!   including the geometry leaf ops and standalone [`eval_expression`].
//! * [`vectorized`] — the vectorized whole-array stencil overlay (ess-bdm):
//!   shifted-slice `index` gathers, broadcast kernels, einsum folds.
//! * [`rhs`] — per-call RHS evaluation: the zero-allocation scratch/buffer
//!   pool (ess-mro), observed-rule materialization, and the rule driver.
//! * [`driver`] — diffsol solver plumbing (`solve`/`solve_inspect`,
//!   `debug_*` entry points) and the external refreshable forcing channel
//!   (PR-1, ess-14f.7) exposed via `forcing_handle`.
//! * [`layout`] — column-major flat↔multi index/array conversion helpers.
//!
//! This file keeps the shared data model: [`Value`], the per-variable
//! [`VarShape`] table, the compiled rule types ([`RhsRule`],
//! [`AlgebraicRule`], [`ContractDim`]), the compiled model [`ArrayCompiled`],
//! the kernel buffer [`Pool`], and the evaluation context [`EvalCtx`].

// This runtime is compiled for wasm too (EarthSciAST-akz): it reaches
// s2geometry only through the already-wasm-safe `crate::geometry` API (planar
// clips work; spherical/geodesic returns a runtime `GeometryError` stub on
// wasm), and its solver is the same diffsol/Faer path the scalar solver
// export already runs client-side — so no native-only dependency remains, and
// planar / geometry-free PDEs run in the browser via `crate::simulate::simulate`.
#![allow(
    clippy::type_complexity,
    clippy::collapsible_if,
    clippy::needless_range_loop
)]

mod compile;
mod cse;
mod driver;
mod eval;
mod layout;
mod rhs;
pub mod tape;
mod vectorized;

// Only `area_faq` / `pde_inline_tests` consume this re-export, and both stay
// native-only, so gate it to avoid an unused-import warning on wasm.
#[cfg(not(target_arch = "wasm32"))]
pub(crate) use compile::eval_buildtime_field;
pub use compile::{file_has_array_ops, file_has_spatial_model, run_value_invention};
// The ONE free-variable gate (CONFORMANCE_SPEC §5.23), shared with the build
// pipeline: `crate::prepare` runs the same check the compile path runs, so the
// two routes cannot disagree about which names a document declares.
#[cfg(not(target_arch = "wasm32"))]
pub(crate) use compile::check_free_variables;
pub(crate) use eval::eval_observed_recurrence;
pub use eval::{
    eval_expression, eval_expression_with_extents, eval_expression_with_extents_and_consts,
    take_const_array_oob,
};
// The scalar-op leaf kernel is defined once here (backs the per-cell oracle and
// the vectorized overlay); re-exported crate-wide so the scalar interpreter
// `crate::simulate::eval_op` routes through the SAME definition instead of
// re-implementing the arithmetic/comparison/logical algebra (knot #3a).
pub(crate) use eval::{
    apply_binary, apply_unary, eval_expression_with_extents_and_consts_shared, fold_scalar,
};
pub use rhs::RhsScratch;

use compile::*;
use cse::*;
use eval::*;
use layout::*;
use rhs::*;
use vectorized::*;

use crate::aggregate::{ReduceKind, empty_derived_extents};
use crate::types::{Expr, IndexSet, RangeSpec};
use crate::value_invention::BoundaryKind;
use indexmap::IndexMap;
use ndarray::{ArrayD, IxDyn};
use rustc_hash::FxBuildHasher;
use smallvec::SmallVec;
use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::rc::Rc;

/// Stack-inlined index vectors for per-axis kernel bookkeeping. Grid rank stays
/// ≤ 4 in practice, so these never touch the heap — a precondition for the
/// zero-allocation steady-state RHS (ess-mro).
type DimI = SmallVec<[i64; 4]>;
type DimU = SmallVec<[usize; 4]>;

/// Fast, fixed-seed loop-index binding map for the hot per-cell interpreter.
/// `EvalCtx::loop_binds` holds the current output/contraction index values and
/// is probed FIRST on every variable reference during the per-cell tree walk
/// ([`lookup_variable`]), so it is the highest-frequency hash in the evaluator —
/// a coupled level-set solve spent ~19% of its samples in std's SipHash. The
/// keys are trusted internal index names (`i`, `j`, `k`, …), so SipHash's DoS
/// resistance is unused cost; `FxBuildHasher` is a fixed seed (so *more*
/// deterministic than the randomized `RandomState` it replaces). `loop_binds` is
/// only ever built inline at each `EvalCtx` construction and probed/inserted/
/// removed by key — never iterated in an order-affecting way — so switching the
/// hasher is byte-identical. (The borrowed `state_arrays`/`observed_arrays` name
/// maps still use std `HashMap`; swapping their hasher too is a natural
/// follow-up but crosses the public `eval_expression`/`forcing_handle` boundary.)
type IdxMap = HashMap<String, i64, FxBuildHasher>;

/// Fast, fixed-seed name→array map for the hot per-cell interpreter's variable
/// resolution ([`lookup_variable`] probes `state_arrays` then `observed_arrays`
/// on every non-index reference). Same rationale as [`IdxMap`]: trusted internal
/// variable names, no order-affecting iteration, byte-identical results. The
/// public boundary ([`eval_expression`]'s `inputs`, `forcing_handle`,
/// `BuildInspection::setup_arrays`) stays on std `HashMap`; conversion happens
/// there (a shallow clone of the small FAQ/coordinate input maps).
pub(crate) type ArrMap = HashMap<String, ArrayD<f64>, FxBuildHasher>;

/// Stack-inlined operand buffer for the per-node scalar evaluator. An operator's
/// arity is ≤ 4 in practice (most are binary), so evaluating `node.args` into
/// this never touches the heap — removing the per-node `Vec<Value>` temporary
/// that dominated allocation in the per-cell interpreter profile.
type ValVec = SmallVec<[Value; 4]>;

// ============================================================================
// Value type: scalar or dynamic-rank ndarray.
// ============================================================================

/// A runtime value carried through the array-aware interpreter.
///
/// Scalars and whole arrays are first-class so operators like `reshape`,
/// `transpose`, `concat`, and `broadcast` can produce array-typed
/// intermediates that later `index` calls sample from.
#[derive(Debug, Clone)]
pub enum Value {
    Scalar(f64),
    /// Boxed so the whole-array payload lives on the heap and `Value` stays
    /// ~16 bytes: the per-cell oracle moves a `Value` at every AST node of
    /// every grid cell, and the vast majority are `Scalar`s — an unboxed
    /// `ArrayD` (~64 B) would make every one of those scalar moves a large
    /// memcpy (knot #6). Constructing an `Array` now heap-allocates, but the
    /// hot zero-allocation RHS paths (scalar ODE, vectorized whole-array) do
    /// not construct per-cell `Array` values, so they are unaffected.
    Array(Box<ArrayD<f64>>),
}

impl Value {
    fn as_scalar(&self) -> Option<f64> {
        match self {
            Value::Scalar(v) => Some(*v),
            Value::Array(a) if a.ndim() == 0 => Some(a[IxDyn(&[])]),
            _ => None,
        }
    }
}

// ============================================================================
// Array model: shape information per variable + compiled RHS rules.
// ============================================================================

/// Per-variable shape/origin description.
#[derive(Debug, Clone)]
pub struct VarShape {
    /// Dimension extents. Empty vec means scalar.
    pub shape: Vec<usize>,
    /// Per-dimension origin (1-based indices per schema convention).
    pub origin: Vec<i64>,
    /// Flat offset in the state vector.
    pub flat_offset: usize,
}

/// One contracted (reduction) index's loop bound in an `aggregate`/`arrayop`
/// einsum. Either a static inclusive interval, or a **ragged** bound whose
/// upper limit `offsets[of…]` is gathered per output tuple at eval time
/// (RFC `semiring-faq-unified-ir` §5.2 — variable-valence / unstructured-mesh
/// reductions). The lower bound of a ragged dim is implicitly `1`.
#[derive(Debug, Clone)]
enum ContractDim {
    /// Static inclusive `[lo, hi]` (interval / categorical index sets).
    Static(i64, i64),
    /// Ragged `[1, offsets[of…]]` — `offsets` names the per-parent length
    /// factor; `of` names the parent index variables that address it.
    Ragged { offsets: String, of: Vec<String> },
    /// Derived `[1, n]` — `from_faq` names the FAQ producer node whose
    /// materialized output sizes this contraction, resolved at eval time by
    /// [`derived_extent`]: the value-invention engine's distinct-set cardinality
    /// (RFC §6.1 / §5.5) if it materialized this producer, else the
    /// `intersect_polygon` clip ring's distinct-vertex count (RFC §8.1).
    Derived { from_faq: String },
}

impl ContractDim {
    /// Build a contracted dim from a resolved range spec: a [`RangeSpec::RaggedDyn`]
    /// becomes [`ContractDim::Ragged`], a [`RangeSpec::DerivedDyn`] becomes
    /// [`ContractDim::Derived`]; anything else falls back to its static
    /// `[lo, hi]` bounds (`[0, 0]` — an empty reduction — if unresolved).
    fn from_range(spec: &RangeSpec) -> Self {
        if let Some((offsets, of)) = spec.ragged() {
            return ContractDim::Ragged {
                offsets: offsets.to_string(),
                of: of.to_vec(),
            };
        }
        if let Some(from_faq) = spec.derived() {
            return ContractDim::Derived {
                from_faq: from_faq.to_string(),
            };
        }
        let r = spec.bounds().unwrap_or([0, 0]);
        ContractDim::Static(r[0], r[1])
    }

    /// Resolve to a concrete inclusive `(lo, hi)` range under the current loop
    /// binds. A ragged dim gathers its parent index value(s) from `ctx` and
    /// reads `offsets[parent…]`; a derived dim reads the materialized ring's
    /// vertex count from the runtime registry; an empty bound (`lo > hi`, e.g.
    /// an isolated cell with zero neighbours, or a disjoint clip) yields no
    /// contraction tuples, so the reduction returns the additive identity 0̄.
    fn concrete(&self, ctx: &EvalCtx) -> (i64, i64) {
        match self {
            ContractDim::Static(lo, hi) => (*lo, *hi),
            ContractDim::Ragged { offsets, of } => (1, ragged_upper_bound(offsets, of, ctx)),
            ContractDim::Derived { from_faq } => (1, derived_extent(from_faq, ctx)),
        }
    }

    /// The cell-independent `(lo, hi)` of a static dim, or `None` for a
    /// ragged/derived dim (whose bound varies per output tuple and so must be
    /// resolved via [`Self::concrete`] each cell). Lets the caller hoist the
    /// range derivation out of the per-cell reduction loop when all dims are
    /// static.
    fn static_bound(&self) -> Option<(i64, i64)> {
        match self {
            ContractDim::Static(lo, hi) => Some((*lo, *hi)),
            ContractDim::Ragged { .. } | ContractDim::Derived { .. } => None,
        }
    }
}

/// An equation rule compiled for runtime RHS evaluation.
#[derive(Debug, Clone)]
enum RhsRule {
    /// Scalar derivative `D(var) = body` — `var` is a 0-D state variable.
    Scalar { slot: usize, body: Box<Expr> },
    /// Indexed scalar derivative `D(var[i1, i2, ...]) = body` with all
    /// indices concrete. Writes to a single flat slot.
    IndexedScalar { slot: usize, body: Box<Expr> },
    /// Array-op derivative. The body expression is evaluated once per tuple
    /// of `output_idx` values (the tuple drawn from `output_ranges`) and the
    /// resulting scalar is written into `var_name[idx...]`.
    /// If `contract_names` is non-empty the body also contains contracted
    /// (reduction) indices that are unrolled at eval time and combined via the
    /// semiring's ⊕ (`reduce`), resolved once at build time.
    ArrayLoop {
        var_name: String,
        output_idx_names: Vec<String>,
        output_ranges: Vec<(i64, i64)>,
        lhs_idx_exprs: Vec<Expr>,
        body: Box<Expr>,
        contract_names: Vec<String>,
        /// Per-contracted-index loop bounds. A [`ContractDim::Ragged`] dim is
        /// expanded to its dynamic `[1, offsets[of…]]` extent per output tuple.
        contract_dims: Vec<ContractDim>,
        reduce: ReduceKind,
        /// Optional `filter` predicate (§5.3): combinations for which it is
        /// false contribute the additive identity 0̄. `None` ⇒ no gating.
        filter: Option<Box<Expr>>,
    },
}

/// Instrumentation for one `evaluate_rhs` call: how the spatial array-op
/// derivatives were evaluated. The load-bearing field for the
/// no-scalarization contract (ess-bdm) is [`RhsStats::kernel_ops`] — the
/// number of AST-node evaluations performed by the **vectorized** whole-array
/// path. It is a function of the discretized RHS *expression* only, so it is
/// **independent of the grid size N**: the same stencil evaluated on a 4-cell
/// and an 8-cell grid visits the same number of array kernels (one shifted
/// slice per neighbour, one broadcast per arithmetic node — not `O(N)` scalar
/// sub-expressions). The per-cell oracle, by contrast, re-walks the body once
/// per grid cell, so its `kernel_ops` scales with N. A test asserts the
/// vectorized count is N-independent (criterion 3 of ess-bdm).
#[derive(Debug, Clone, Default)]
pub struct RhsStats {
    /// AST-node evaluations performed by the vectorized (whole-array) path.
    /// N-independent for a fixed discretized RHS.
    pub kernel_ops: usize,
    /// Number of array-op derivative rules evaluated vectorized (shifted-slice
    /// stencils + region-materialized boundary makearrays, no per-cell loop).
    pub vectorized_rules: usize,
    /// Number of array-op derivative rules that fell back to the per-cell
    /// oracle (general semiring contraction, non-affine indexing, periodic
    /// wrap, …). The vectorized path is a verified-equivalent overlay; the
    /// per-cell path remains the correctness reference.
    pub scalar_rules: usize,
    /// Number of array-shaped *observed* (algebraic) rules materialized via the
    /// vectorized whole-array overlay rather than the per-cell oracle. For a
    /// coupled model with a time/space-varying behaviour stack this is the
    /// dominant per-step cost, so keeping it vectorized (not `obs_scalar_rules`)
    /// is what makes the observed materialization N-independent.
    pub obs_vectorized_rules: usize,
    /// Number of array-shaped observed rules that fell back to the per-cell
    /// oracle (a body op the vectorizer does not yet cover, a non-unit origin,
    /// or a forced-scalar reference run).
    pub obs_scalar_rules: usize,
    /// Step 3b: number of rules (observed + RHS) executed through the compiled
    /// tape's fast executor on this call. Mirrors the
    /// `vectorized_rules`/`scalar_rules` split for the tape path; zero on the
    /// legacy interpreter path.
    pub taped_rules: usize,
    /// Step 3b: number of rules the tape delegated to the interpreter
    /// (`Instr::Fallback`) on this call.
    pub fallback_rules: usize,
}

/// Eliminated algebraic-variable definition. Evaluated once per RHS call
/// into a transient ndarray (or scalar) that the `observed_values` map
/// exposes to downstream expressions.
///
/// The body is an `Rc<Expr>`, not a `Box<Expr>`: the driver derives several
/// cadence-filtered rule lists from `observed_rules` (CONST / DISCRETE /
/// CONTINUOUS subsets, the per-closure RHS/Jacobian captures, the
/// output-pass dependency cones), and the expanded discretization bodies are
/// by far the model's largest allocation (~1 GiB for `simpleclimate.esm` at
/// the production grid). Cloning a rule now shares the immutable body
/// instead of deep-copying it, collapsing what used to be five simultaneous
/// full copies at solve time into one. Sharing also keeps every `Expr` node
/// address stable for the whole run, which the address-keyed CSE overlay
/// ([`CseRt`] / `AddrClasses`) relies on; bodies are never mutated after
/// compile, so no copy-on-write can move them mid-solve.
#[derive(Debug, Clone)]
enum AlgebraicRule {
    /// `var := body` — pure scalar algebraic.
    Scalar { var: String, body: Rc<Expr> },
    /// `var[i...] := body` — array algebraic defined via an arrayop over
    /// the full shape of `var`.
    ArrayLoop {
        var: String,
        output_idx_names: Vec<String>,
        output_ranges: Vec<(i64, i64)>,
        body: Rc<Expr>,
    },
    /// `var[i…] := body`, where `body` reads `var` itself at a strictly earlier
    /// position along axis `axis` — a CAUSAL SELF-REFERENCE (esm-spec §4.3.1.1,
    /// `docs/content/rfcs/causal-self-reference-recurrence.md`).
    ///
    /// Structurally an [`AlgebraicRule::ArrayLoop`] plus the recurrence axis,
    /// but a SEPARATE variant on purpose: its cells are not independent, so it
    /// must never reach the whole-array overlay, the tape, or any other path
    /// that evaluates cells out of order or in a batch (CONFORMANCE_SPEC
    /// §5.19.2). Being a distinct variant means every `match` over the rule
    /// kinds has to say what it does with a recurrence instead of silently
    /// inheriting a reordering path.
    Recurrence {
        var: String,
        output_idx_names: Vec<String>,
        output_ranges: Vec<(i64, i64)>,
        body: Rc<Expr>,
        /// Position within `output_idx_names` of the axis the recurrence folds
        /// along. Swept ascending as the OUTERMOST loop.
        axis: usize,
        /// Largest lag any self-read takes along `axis`, derived from the reads
        /// themselves and never declared (RFC §2.1). Reported for
        /// observability; no evaluation rule depends on it.
        max_lag: i64,
        /// Whether every self-read was proved strictly earlier statically.
        /// See [`RecurrenceInfo::lag_proven`].
        lag_proven: bool,
    },
}

/// The partially materialized array of an [`AlgebraicRule::Recurrence`], in
/// scope for the body's causal self-reads while the sweep is in progress.
///
/// Interior-mutable for the same reason [`EvalCtx::derived_rings`] is: the
/// driver publishes cell `i` while the evaluation context that reads it at cell
/// `i + c` holds a shared borrow of the scope.
///
/// `written` is not redundant with the axis bounds. A read is admitted only when
/// the cell it names has ALREADY been published, which the bounds alone cannot
/// decide (a body may compute an index from a contracted symbol). An unwritten
/// or out-of-range read is fail-closed (CONFORMANCE_SPEC §5.19.4) — never the
/// §5.5.5 zero ghost, and never a bare NaN that a `max(x, 0)` in the body would
/// launder back into a plausible number.
pub(super) struct RecurScope<'a> {
    /// The variable being defined; an `index` gather on this name resolves here.
    pub(super) name: &'a str,
    /// Extents of the cell frame.
    pub(super) shape: DimU,
    /// Lower bound of each axis of the cell frame.
    pub(super) origin: DimI,
    /// Cell values, column-major over `shape`.
    cells: RefCell<Vec<f64>>,
    /// Which cells have been published.
    written: RefCell<Vec<bool>>,
}

impl<'a> RecurScope<'a> {
    pub(super) fn new(name: &'a str, shape: DimU, origin: DimI) -> Self {
        let total = shape.iter().copied().product::<usize>().max(1);
        Self {
            name,
            shape,
            origin,
            cells: RefCell::new(vec![0.0; total]),
            written: RefCell::new(vec![false; total]),
        }
    }

    /// Publish one cell (its 1-based multi-index) so later cells may read it.
    ///
    /// Rounded to the ACTIVE working precision (esm-spec §11.3.1) before it is
    /// stored, not only when it is read back. The recurrence's carried state is
    /// a cell of the variable being defined, so it carries that variable's
    /// `element_type` — and for a `Float32` document that has to hold at every
    /// step of the fold, exactly as it does in a `real*4` reference
    /// implementation. Storing a binary64 partial and rounding only on the way
    /// out would run the fold at a precision the document did not declare and
    /// silently beat the reference it is being checked against.
    pub(super) fn publish(&self, tuple: &[i64], v: f64) {
        let flat = layout::multi_to_flat_col_major(tuple, &self.shape, &self.origin);
        let mut cells = self.cells.borrow_mut();
        if flat < cells.len() {
            cells[flat] = crate::precision::active().round(v);
            self.written.borrow_mut()[flat] = true;
        }
    }

    /// Read one published cell, or `None` when the position is outside the cell
    /// frame or has not been published yet.
    pub(super) fn read(&self, raw: &[i64]) -> Option<f64> {
        if raw.len() != self.shape.len() {
            return None;
        }
        for (d, &one_based) in raw.iter().enumerate() {
            let lo = self.origin[d];
            let hi = lo + self.shape[d] as i64 - 1;
            if one_based < lo || one_based > hi {
                return None;
            }
        }
        let flat = layout::multi_to_flat_col_major(raw, &self.shape, &self.origin);
        if !*self.written.borrow().get(flat)? {
            return None;
        }
        self.cells.borrow().get(flat).copied()
    }

    /// The finished array, as an owned ndarray in the evaluator's layout.
    pub(super) fn finish(&self) -> ArrayD<f64> {
        layout::col_major_to_arrayd(&self.cells.borrow(), &self.shape)
    }
}

/// Build/run observability record — the Rust mirror of the Julia binding's
/// `BuildInspection` (`build_evaluator(…; inspect=BuildInspection())`). Pass
/// one to a EsmProblem built with [`crate::problem::ProblemOptions::inspect`] (or
/// [`ArrayCompiled::simulate_inspect`]) and the run fills it with named
/// build-time products that are otherwise internal to the runtime:
///
/// * `setup_arrays` — the STATE-FREE observed arrays, materialized once at the
///   initial state through the official observed machinery
///   ([`materialize_observeds`]): the per-pair regrid geometry (`A_ij`, its
///   row-sums `A_j`, the normalized weights `W_ij` — RFC §8.1 / esm-spec
///   §8.6.1), const-op mesh factors and their bare-name aliases, and every
///   other build-once array observed whose transitive references reach no
///   state, no `t`, and no external forcing channel. This is the official
///   inspection surface for conformance runners that gate per-pair regridding
///   values (CONFORMANCE_SPEC §5.8) and for §6.6.5 assertions that target a
///   state-free array observed directly (the MPAS `div_flux` max/min). A
///   state- or time-dependent observed is deliberately ABSENT (its build-time
///   snapshot would be wrong at any later time), so a reader errors rather
///   than consuming a stale field.
/// * `observed_exprs` — every observed rule's resolved body expression (post
///   subsystem mounting, range resolution, and keyed-factor scoping), exactly
///   as the runtime evaluates it.
///
/// Filling the record never changes the run: the returned
/// [`crate::simulate::Solution`] is identical with or without a sink (the
/// capture is one extra read-only [`materialize_observeds`] pass at `t0`).
#[derive(Debug, Clone, Default)]
pub struct BuildInspection {
    /// State-free observed arrays materialized at the initial state, keyed by
    /// (possibly flattening-namespaced) observed name.
    pub setup_arrays: HashMap<String, ArrayD<f64>>,
    /// Resolved observed body expressions, keyed like `setup_arrays`.
    pub observed_exprs: HashMap<String, Expr>,
    /// Resolved SCALAR parameter values (model defaults with any overrides
    /// applied), keyed by (flattened) parameter name. Load-time constants, so a
    /// build-time cellwise evaluation (a §6.6.5 analytic `reference`,
    /// coordinate-expression `ic` seeding) may bind them into scope — STATE
    /// stays out. The observed-assertion form already binds them (a state-free
    /// observed is materialized into `setup_arrays` with these values); `params`
    /// exposes the same map for the reference / `ic` positions.
    pub params: HashMap<String, f64>,
    /// One entry per recognized CAUSAL SELF-REFERENCE (esm-spec §4.3.1.1), so
    /// the interpretation a document's self-read was given is auditable without
    /// being authored twice. This is what stands in for a declared `recur`
    /// annotation (RFC §2.1): the recurrence, its axis and its derived maximum
    /// lag are reported, not required.
    pub recurrences: Vec<RecurrenceInfo>,
}

/// A recognized causal self-reference, as reported to a [`BuildInspection`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RecurrenceInfo {
    /// The variable the recurrence defines.
    pub var: String,
    /// The output index symbol the sweep folds along, ascending.
    pub axis: String,
    /// Largest lag any self-read takes along `axis`, DERIVED from the reads.
    pub max_lag: i64,
    /// Whether every self-read was proved strictly earlier statically. When
    /// `false` at least one read's lag depends on a symbol whose range admits
    /// `0` or less, so the runtime's fail-closed read (never a value for an
    /// unpublished cell) is what rules those cells out — typically because a
    /// guard in the body means they are never evaluated.
    pub lag_proven: bool,
}

/// Compiled, parameter-sweep-ready ODE model for array-op models.
pub struct ArrayCompiled {
    var_shapes: IndexMap<String, VarShape>,
    /// Names of every scalar slot (`"u[1]"`, `"u[2,3]"`, `"s"`, etc.),
    /// parallel to the flat state vector.
    scalar_state_names: Vec<String>,
    /// Name → flat slot lookup.
    scalar_state_index: HashMap<String, usize>,
    /// Per-slot default value (from variable.default or None).
    state_defaults: Vec<Option<f64>>,
    param_names: Vec<String>,
    param_index: HashMap<String, usize>,
    param_defaults: Vec<Option<f64>>,
    /// Algebraic variables eliminated from the state vector. Stored as
    /// observed definitions evaluated at each RHS call in order (no cross-
    /// dependency support for v1 — fixtures don't need it).
    observed_rules: Vec<AlgebraicRule>,
    /// Per-state RHS rules.
    rhs_rules: Vec<RhsRule>,
    /// Number of flat state slots.
    n_states: usize,
    /// External refreshable forcing-array channel (PR-1, ess-14f.7): the live
    /// runtime input a discrete-cadence loader's regridded field lands in, read
    /// by the RHS each step. Keyed by variable name; a forcing-fed variable
    /// resolves here (see [`lookup_variable`]) when it is bound in no other
    /// channel. `Rc<RefCell<…>>` for the same reason [`RhsScratch`] is a
    /// `RefCell` — diffsol's RHS is `Fn`, so the buffer needs interior
    /// mutability — *plus* an `Rc` so a segmented driver (the future R-3
    /// example-harness) can hold a clone and refresh entries *between* segments
    /// while the captured closure reads the same buffer. Empty for every model
    /// with no loader forcing, so the scalar-`p` path is byte-identical.
    ///
    /// Feasibility-gate verdict (the bead's declarative-or-fail opener): no
    /// existing runtime channel suffices for a *refreshable external
    /// forcing-array*. diffsol's `p` slice (`p.as_slice()`) is scalar-typed and
    /// shape-less — fine for scalar forcings (which keep going through
    /// `p`/`set_params`), awkward for fields; `state_arrays` is the integrator
    /// state `y` (refilled from the solver, not a free input); `observed_arrays`
    /// is a pure function of state, cleared and recomputed each call;
    /// `derived_rings` is interior-mutable but built *fresh per RHS call*
    /// (intra-evaluation FAQ-geometry scratch, wrong lifetime and overwritten by
    /// `intersect_polygon` producers). The gap is real, so the channel is added
    /// — as a runtime *binding*, not a new engine primitive (no arrayop, no
    /// scalarizer arm, no `Discrete` `VariableType`). The optional typed
    /// `ModelVariable.refresh` field (plan PR-2) is deferred: forcing resolves
    /// by name at runtime and does not need it.
    forcing: Rc<RefCell<HashMap<String, ArrayD<f64>>>>,
    /// Deferred scoped-reference / array `ic` equations (esm-spec §11.4.1),
    /// classified out of the equation list by [`Self::from_model`] (single-model
    /// path) or carried from [`crate::flatten::FlattenedSystem::field_ics`]
    /// (coupled path). Each entry is `(target_state, rhs)`: at `u0` build time
    /// [`Self::simulate`] resolves the target's grid cells and folds the initial
    /// field — a provider-served loaded field, a broadcast constant, or a
    /// coordinate expression over grid-geometry aggregates — into the flat state
    /// vector cell-by-cell (DESIGN pde_simulation_pipeline §2 R2).
    field_ics: Vec<(String, Expr)>,
    /// Document-scoped index-set registry, kept so `ic` RHS coordinate
    /// expressions (whose `aggregate` ranges may still carry `{ "from": <set> }`
    /// references on the flattened path) resolve at `u0` build time exactly as
    /// equation expressions do at compile time.
    index_sets: HashMap<String, IndexSet>,
    /// The model's CONST-ARRAY registry (CONFORMANCE_SPEC §5.5.5): the
    /// pre-computed factor arrays — the document's `const`-op variables plus
    /// any caller-supplied factor arrays — whose gathers resolve an
    /// out-of-range index by a declared boundary policy (default
    /// `E_TREEWALK_CONSTARRAY_OOB`) rather than by the state gather's zero
    /// ghost. `Rc` so the per-call scratch can hold the same registry without
    /// cloning the name set every step. Empty for a model with no const
    /// factors, which reads byte-identically to the pre-§5.5.5 evaluator.
    const_scope: Rc<ConstArrayScope>,
    /// The single-model namespace (the top-level `models` map key), set by
    /// [`Self::from_file`]. The raw single-model path keys params/states by their
    /// BARE variable names (`R_0`, `psi[i,j]`), but the scalar backend, the
    /// `flatten` path, and the Julia toolkit all namespace them (`Model.R_0`).
    /// So a caller's `parameters` / `initial_conditions` override key is accepted
    /// in EITHER form: a `<namespace>.` prefix is stripped before lookup (WS3
    /// cross-toolkit override-naming parity). `None` on the `from_flattened`
    /// path, whose names are already fully namespaced.
    namespace: Option<String>,
    /// The working precision this model was COMPILED under
    /// (`crate::precision`), captured so evaluation reproduces it even when the
    /// caller reaches an `ArrayCompiled` directly (`compile_array`, the
    /// `debug_*` entry points) rather than through an `EsmProblem`. Build-time
    /// folding and run-time evaluation must round identically, and the
    /// artifact carrying its own precision is what makes that true by
    /// construction rather than by the caller remembering.
    precision: crate::precision::Env,
}

/// A reuse pool of `f64` backing buffers for vectorized kernel intermediates.
/// `take_array*`/`give_array` recycle buffers; after a warm-up call the pool
/// holds enough output-box-sized buffers that no further allocation occurs.
///
/// Recycling is **shape-bucketed**: [`Pool::give_array`] parks the whole
/// [`ArrayD`] (buffer *plus* its already-built `IxDyn` dim and strides) in the
/// bucket for its exact shape, and [`Pool::take_array_uninit`] pops it straight
/// back out. In a steady-state RHS the same handful of output-box shapes repeat
/// on every call, so the common checkout is a hash lookup and a `Vec::pop` —
/// neither the `memset` that a `Vec::resize`-based refill costs nor the
/// `IxDyn(shape)` / `from_shape_vec` shape+stride reconstruction that a
/// buffer-only pool has to redo per checkout (both were measurable shares of
/// the solve: ~9.5% and ~8.3% respectively on the simpleclimate PPM core).
///
/// `free` is the spill list for the cases the buckets cannot serve: a
/// first-of-its-shape checkout, and a returned array that is not in standard
/// layout (so its buffer, but not its shape, is reusable).
#[derive(Default)]
struct Pool {
    /// Whole recycled arrays, bucketed by exact shape. Keyed by [`DimU`], which
    /// hashes and compares as a `[usize]` slice, so the hot lookup borrows the
    /// caller's `&[usize]` with no key materialization.
    shaped: HashMap<DimU, Vec<ArrayD<f64>>, FxBuildHasher>,
    /// Bare buffers with no usable shape attached.
    free: Vec<Vec<f64>>,
}

impl Pool {
    /// Check out a zero-filled buffer of `len` elements, reusing a free buffer
    /// whose capacity already covers `len` (no reallocation in steady state).
    fn take(&mut self, len: usize) -> Vec<f64> {
        if let Some(pos) = self.free.iter().position(|b| b.capacity() >= len) {
            let mut b = self.free.swap_remove(pos);
            b.clear();
            b.resize(len, 0.0);
            b
        } else if let Some(mut b) = self.free.pop() {
            // A free buffer exists but is too small; grow it (warm-up only).
            b.clear();
            b.resize(len, 0.0);
            b
        } else {
            vec![0.0; len]
        }
    }

    /// Check out an owned `ArrayD` of the given row-major `shape` whose element
    /// contents are **unspecified** — whatever the previous holder of the
    /// recycled buffer left there.
    ///
    /// For kernels that write every element of the box before anything reads it
    /// (an elementwise `Zip`, a `fill`, a coordinate ramp, an `assign` of a
    /// same-shape source). A caller that writes only PART of the box — a
    /// Dirichlet-ghost gather, a reduction accumulator seeded with the identity,
    /// a region-tiled `makearray` — must use [`Pool::take_array`] instead, or it
    /// will read the previous kernel's data.
    fn take_array_uninit(&mut self, shape: &[usize]) -> ArrayD<f64> {
        if let Some(bucket) = self.shaped.get_mut(shape) {
            if let Some(arr) = bucket.pop() {
                // Recycled whole: right shape, right strides, right length —
                // nothing to rebuild and nothing to refill.
                return arr;
            }
        }
        let len = shape.iter().copied().product::<usize>().max(1);
        let buf = self.take(len);
        ArrayD::from_shape_vec(IxDyn(shape), buf).expect("pool buffer length matches shape")
    }

    /// Check out a zero-filled owned `ArrayD` of the given row-major `shape`,
    /// backed by a pooled buffer.
    fn take_array(&mut self, shape: &[usize]) -> ArrayD<f64> {
        let mut arr = self.take_array_uninit(shape);
        arr.fill(0.0);
        arr
    }

    /// Return an owned `ArrayD` to the pool, preserving its buffer capacity and
    /// — when it is in standard (contiguous, row-major) layout, as every buffer
    /// this module hands out is and the in-place kernels keep it — its built
    /// shape and strides too, so the next same-shape checkout rebuilds nothing.
    fn give_array(&mut self, arr: ArrayD<f64>) {
        if arr.is_standard_layout() {
            if let Some(bucket) = self.shaped.get_mut(arr.shape()) {
                bucket.push(arr);
                return;
            }
            let shape: DimU = arr.shape().iter().copied().collect();
            self.shaped.insert(shape, vec![arr]);
            return;
        }
        let (buf, _offset) = arr.into_raw_vec_and_offset();
        self.free.push(buf);
    }
}

/// The rule-invariant slice of an evaluation environment: everything an
/// [`EvalCtx`] carries EXCEPT the observed-array map (whose borrow must be
/// re-taken after each observed rule writes its output) and the per-loop
/// index binds. Built once per RHS call / materialization pass from the
/// natural source objects; the `EvalCtx` literal itself is then written
/// exactly once — in [`EvalEnv::ctx`] — instead of being hand-assembled at
/// every evaluation site. Field semantics are documented on [`EvalCtx`].
#[derive(Clone, Copy)]
struct EvalEnv<'a> {
    state_arrays: &'a ArrMap,
    params: &'a [f64],
    param_names: &'a [String],
    t: f64,
    /// See [`EvalCtx::derived_rings`].
    derived_rings: &'a RefCell<HashMap<String, ArrayD<f64>>>,
    /// See [`EvalCtx::derived_extents`]. The compiled-RHS paths pass
    /// [`empty_derived_extents`] (their derived sets were densified to
    /// intervals at build time); the standalone expression entry point
    /// carries real extents.
    derived_extents: &'a HashMap<String, i64>,
    /// See [`EvalCtx::forcing`].
    forcing: &'a RefCell<HashMap<String, ArrayD<f64>>>,
    /// See [`EvalCtx::cse`].
    cse: Option<&'a CseRt>,
    /// See [`EvalCtx::const_arrays`].
    const_arrays: &'a ConstArrayScope,
}

impl<'a> EvalEnv<'a> {
    /// A fresh evaluation context (empty loop binds) over this environment,
    /// reading observed values from `observed_arrays`.
    fn ctx(&self, observed_arrays: &'a ArrMap) -> EvalCtx<'a> {
        EvalCtx {
            state_arrays: self.state_arrays,
            observed_arrays,
            params: self.params,
            param_names: self.param_names,
            loop_binds: IdxMap::default(),
            t: self.t,
            derived_rings: self.derived_rings,
            derived_extents: self.derived_extents,
            forcing: self.forcing,
            cse: self.cse,
            const_arrays: self.const_arrays,
            recur: None,
        }
    }

    /// Like [`Self::ctx`] but with no CSE memo — the per-cell oracle loops
    /// evaluate without one.
    fn oracle_ctx(&self, observed_arrays: &'a ArrMap) -> EvalCtx<'a> {
        EvalCtx {
            cse: None,
            ..self.ctx(observed_arrays)
        }
    }
}

struct EvalCtx<'a> {
    state_arrays: &'a ArrMap,
    observed_arrays: &'a ArrMap,
    params: &'a [f64],
    param_names: &'a [String],
    loop_binds: IdxMap,
    t: f64,
    /// Runtime registry of FAQ-materialized derived rings (RFC §8.1): an
    /// `intersect_polygon` clip self-registers its closed overlap ring here
    /// under its node `id`, so a downstream `aggregate` over a `kind:"derived"`
    /// index set (`from_faq: <id>`) resolves its extent (the distinct-vertex
    /// count) via [`derived_extent`]. Interior-mutable so the producer can
    /// register while the same borrow chain reads it; empty for models with no
    /// derived sets (byte-identical to the pre-geometry path).
    derived_rings: &'a RefCell<HashMap<String, ArrayD<f64>>>,
    /// Build-time value-invention derived-index-set extents (RFC §6.1 / §5.5),
    /// keyed by the PRODUCING aggregate's `id` — the same key a
    /// `kind:"derived"` index set names in its `from_faq`, and the same keying
    /// the Python `EvalContext.derived_extents` and the Julia
    /// `_declared_shape_extents` use.
    ///
    /// This is the relational counterpart of `derived_rings`. A clip ring is
    /// materialized *during* evaluation (the producer node runs, then the
    /// consumer reads its ring); the value-invention engine instead runs ONCE at
    /// setup, off the per-step hot path, and hands its distinct-set cardinality
    /// here. A derived range consults this first ([`derived_extent`]) and falls
    /// back to the ring, so the two producers coexist in one model.
    ///
    /// NOT interior-mutable, unlike `derived_rings`: nothing produces into it
    /// during evaluation. Empty on the compiled-RHS path, where
    /// [`crate::value_invention::rewrite_derived_index_sets`] has already
    /// densified every materialized derived set to an `interval` *before* ranges
    /// were resolved — those axes therefore arrive as plain static bounds and
    /// this map is never consulted. It carries the weight on the standalone
    /// [`eval_expression_with_extents`] entry point, where a runner evaluates an
    /// expression that still holds a [`RangeSpec::DerivedDyn`] bound.
    derived_extents: &'a HashMap<String, i64>,
    /// External refreshable forcing-array channel (PR-1, ess-14f.7). Unlike
    /// `derived_rings` (rebuilt fresh every RHS call), this borrows the
    /// model-lifetime [`ArrayCompiled::forcing`] buffer a driver refreshes
    /// between cadence segments; a forcing-fed variable name resolves to its
    /// entry here (see [`lookup_variable`]). Empty for models with no loader
    /// forcing, so the scalar-`p` path reads identically.
    forcing: &'a RefCell<HashMap<String, ArrayD<f64>>>,
    /// Common-subexpression memo for the vectorized overlay (ess-cse). `None`
    /// on the entry points that evaluate a one-off expression (`eval_expression`,
    /// the build-time observed materialization), where there is nothing to amortize
    /// a structural analysis over; the overlay then behaves exactly as it did
    /// before. See [`cse`] for the scoping rule that makes sharing sound.
    cse: Option<&'a CseRt>,
    /// The CONST-ARRAY provenance of this evaluation (CONFORMANCE_SPEC §5.5.5).
    ///
    /// A gather whose target is named here is a **const-array gather** — a
    /// pre-computed factor (Fornberg weights, mesh connectivity, a per-cell
    /// metric / geometry array) — and its out-of-range resolution follows the
    /// factor's declared per-dimension boundary policy, defaulting to
    /// `E_TREEWALK_CONSTARRAY_OOB`. Every other gather is a state / observed
    /// gather and keeps the homogeneous-Dirichlet zero-ghost convention, which
    /// §5.5.5 says is **never** applied to a const-array gather.
    ///
    /// [`ConstArrayScope::empty`] on every path with no const-array registry,
    /// which reads byte-identically to the pre-§5.5.5 evaluator.
    const_arrays: &'a ConstArrayScope,
    /// The partially materialized array of the [`AlgebraicRule::Recurrence`]
    /// currently sweeping, if any (esm-spec §4.3.1.1). An `index` gather whose
    /// operand names [`RecurScope::name`] resolves HERE — before state,
    /// observed, parameters and forcing — because during the sweep the array
    /// exists nowhere else; and it resolves fail-closed, unlike every other
    /// gather channel.
    ///
    /// `None` on every path in the runtime except the recurrence sweep itself,
    /// which is what makes the feature cost nothing for a document that does
    /// not use it: one `Option` test on the `index` fast path and one on each
    /// vectorized-overlay entry gate.
    recur: Option<&'a RecurScope<'a>>,
}

/// Which arrays in an evaluation are CONST-ARRAY factors, and each one's
/// declared per-dimension out-of-range boundary policy
/// (CONFORMANCE_SPEC §5.5.5 / ess-gj4).
///
/// This is the dense evaluator's counterpart of the Julia reference's
/// `const_arrays` registry (whose `BoundedConstArray` wrapper carries the same
/// per-dimension policy tuple) and of [`crate::value_invention`]'s
/// `const_array_boundaries` input — the two engines must agree byte-for-byte on
/// a resolved gather, so they resolve it by the same table.
#[derive(Debug, Clone, Default)]
pub struct ConstArrayScope {
    /// Names that are const-array factors.
    names: HashSet<String>,
    /// Per-name, per-dimension policy. A name absent here (or a dimension
    /// beyond the declared vec) is [`BoundaryKind::Error`] — the default that
    /// keeps genuine connectivity / stencil-weight bugs caught.
    boundaries: HashMap<String, Vec<BoundaryKind>>,
}

impl ConstArrayScope {
    /// The shared empty scope: nothing is a const array, so every gather keeps
    /// the zero-ghost convention exactly as before.
    pub fn empty() -> &'static ConstArrayScope {
        static EMPTY: std::sync::OnceLock<ConstArrayScope> = std::sync::OnceLock::new();
        EMPTY.get_or_init(ConstArrayScope::default)
    }

    /// A scope over `names`, with no declared boundary policies (so every one
    /// of them resolves an out-of-range gather as `E_TREEWALK_CONSTARRAY_OOB`).
    pub fn from_names<I: IntoIterator<Item = String>>(names: I) -> ConstArrayScope {
        ConstArrayScope {
            names: names.into_iter().collect(),
            boundaries: HashMap::new(),
        }
    }

    /// Declare `name`'s per-dimension boundary policy (and mark it const).
    pub fn with_boundary(mut self, name: impl Into<String>, dims: Vec<BoundaryKind>) -> Self {
        let name = name.into();
        self.names.insert(name.clone());
        self.boundaries.insert(name, dims);
        self
    }

    /// Is this scope empty (nothing is a const array)?
    pub fn is_empty(&self) -> bool {
        self.names.is_empty()
    }

    /// Is `name` a const-array factor here?
    pub fn is_const(&self, name: &str) -> bool {
        self.names.contains(name)
    }

    /// `name`'s declared policy for dimension `d`, defaulting to
    /// [`BoundaryKind::Error`].
    pub fn boundary(&self, name: &str, d: usize) -> BoundaryKind {
        self.boundaries
            .get(name)
            .and_then(|dims| dims.get(d))
            .copied()
            .unwrap_or(BoundaryKind::Error)
    }
}
