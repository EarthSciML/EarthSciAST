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

#![cfg(not(target_arch = "wasm32"))]
#![allow(
    clippy::too_many_arguments,
    clippy::type_complexity,
    clippy::collapsible_if,
    clippy::needless_range_loop,
    clippy::large_enum_variant
)]

use crate::aggregate::{
    ReduceKind, effective_reduce_kind, is_aggregate_op, resolve_aggregate_ranges,
};
use crate::flatten::FlattenedSystem;
use crate::simulate::{CompileError, SimulateError, SimulateOptions, SolutionMetadata};
use crate::simulate::{SimulateOptions as _SimOpts, Solution, SolverChoice};
use crate::types::{
    EsmFile, Expr, ExpressionNode, IndexSet, Model, ModelVariable, RangeSpec, VariableType,
};
use indexmap::IndexMap;
use ndarray::{ArrayD, ArrayViewD, IxDyn, Slice};
use smallvec::SmallVec;
use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::rc::Rc;

/// Stack-inlined index vectors for per-axis kernel bookkeeping. Grid rank stays
/// ≤ 4 in practice, so these never touch the heap — a precondition for the
/// zero-allocation steady-state RHS (ess-mro).
type DimI = SmallVec<[i64; 4]>;
type DimU = SmallVec<[usize; 4]>;

use diffsol::{
    Bdf, FaerLU, FaerMat, NewtonNonlinearSolver, OdeBuilder, OdeSolverMethod, Sdirk, VectorHost,
};

// `SimulateOptions` re-export alias silences unused-import warnings from the
// alternate import path above while keeping a single source of truth for the
// public option type.
#[allow(dead_code)]
type _OptsAlias = _SimOpts;

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
    Array(ArrayD<f64>),
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
    /// Derived `[1, |ring(from_faq)|]` — `from_faq` names the FAQ producer node
    /// (the `intersect_polygon` clip) whose materialized overlap ring sizes this
    /// contraction. The upper bound is the ring's distinct-vertex count, read at
    /// eval time from the runtime ring registry (RFC §8.1).
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
            ContractDim::Derived { from_faq } => (1, derived_ring_extent(from_faq, ctx)),
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
}

/// Eliminated algebraic-variable definition. Evaluated once per RHS call
/// into a transient ndarray (or scalar) that the `observed_values` map
/// exposes to downstream expressions.
#[derive(Debug, Clone)]
enum AlgebraicRule {
    /// `var := body` — pure scalar algebraic.
    Scalar { var: String, body: Box<Expr> },
    /// `var[i...] := body` — array algebraic defined via an arrayop over
    /// the full shape of `var`.
    ArrayLoop {
        var: String,
        output_idx_names: Vec<String>,
        output_ranges: Vec<(i64, i64)>,
        body: Box<Expr>,
    },
}

/// Build/run observability record — the Rust mirror of the Julia binding's
/// `BuildInspection` (`build_evaluator(…; inspect=BuildInspection())`). Pass
/// one to [`crate::simulate::simulate_with_inspection`] (or
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
    /// Observed-variable shapes (matches key set of observed_rules).
    observed_shapes: HashMap<String, VarShape>,
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
    /// The single-model namespace (the top-level `models` map key), set by
    /// [`Self::from_file`]. The raw single-model path keys params/states by their
    /// BARE variable names (`R_0`, `psi[i,j]`), but the scalar backend, the
    /// `flatten` path, and the Julia toolkit all namespace them (`Model.R_0`).
    /// So a caller's `parameters` / `initial_conditions` override key is accepted
    /// in EITHER form: a `<namespace>.` prefix is stripped before lookup (WS3
    /// cross-toolkit override-naming parity). `None` on the `from_flattened`
    /// path, whose names are already fully namespaced.
    namespace: Option<String>,
}

// ============================================================================
// Zero-allocation RHS scratch (ess-mro).
//
// The vectorized stencil evaluator used to allocate `O(#AST-nodes)` arrays per
// RHS call (one owned `ArrayD` per `index`/combine/`makearray` node, a fresh
// per-variable state map, and a column-major scatter `Vec`). diffsol's RHS is
// in-place (`call_inplace` writes the solver-owned `dy`), so there is no
// allocation floor. `RhsScratch` carries the reusable buffers across diffsol
// steps so the steady-state vectorized RHS performs **zero** heap allocations:
//   * `state_arrays` — one persistent logical array per variable, refilled in
//     place from the flat state each call;
//   * `observed_arrays` — reused container for algebraic observeds;
//   * `pool` — a free-list of `f64` buffers recycling kernel intermediates.
// ============================================================================

/// A reuse pool of `f64` backing buffers for vectorized kernel intermediates.
/// `take`/`give` recycle buffers by capacity; after a warm-up call the pool
/// holds enough output-box-sized buffers that no further allocation occurs.
#[derive(Default)]
struct Pool {
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

    /// Check out a zero-filled owned `ArrayD` of the given row-major `shape`,
    /// backed by a pooled buffer.
    fn take_array(&mut self, shape: &[usize]) -> ArrayD<f64> {
        let len = shape.iter().copied().product::<usize>().max(1);
        let buf = self.take(len);
        ArrayD::from_shape_vec(IxDyn(shape), buf).expect("pool buffer length matches shape")
    }

    /// Return an owned `ArrayD`'s backing buffer to the pool, preserving its
    /// capacity. The array must be standard (contiguous, row-major) layout —
    /// every buffer this module hands out is, and the in-place kernels keep it.
    fn give_array(&mut self, arr: ArrayD<f64>) {
        let (buf, _offset) = arr.into_raw_vec_and_offset();
        self.free.push(buf);
    }
}

/// Persistent per-call scratch for [`evaluate_rhs_with_scratch`] (ess-mro). One
/// is owned per RHS closure (the FD Jacobian closure carries its own), guarded
/// by a `RefCell` because diffsol's RHS is an `Fn`, not `FnMut`.
pub struct RhsScratch {
    /// Per-variable state arrays, logical row-major over each variable's shape,
    /// refilled in place from the flat state slice each call.
    state_arrays: HashMap<String, ArrayD<f64>>,
    /// Observed (algebraic) arrays; the container is reused across calls.
    observed_arrays: HashMap<String, ArrayD<f64>>,
    /// Recycled `f64` buffers for vectorized kernel intermediates.
    pool: Pool,
}

impl RhsScratch {
    /// Build a scratch sized to a model's variable shapes. State arrays are
    /// allocated once here (zero-filled); subsequent RHS calls only overwrite
    /// their contents. Observed value arrays are materialized lazily.
    fn new(var_shapes: &IndexMap<String, VarShape>) -> Self {
        let mut state_arrays = HashMap::with_capacity(var_shapes.len());
        for (name, vs) in var_shapes {
            state_arrays.insert(name.clone(), ArrayD::<f64>::zeros(IxDyn(&vs.shape)));
        }
        RhsScratch {
            state_arrays,
            observed_arrays: HashMap::new(),
            pool: Pool::default(),
        }
    }
}

/// Overwrite each persistent state array with the current flat state, reading
/// each variable's column-major block into its logical array in place. The
/// per-element address is computed explicitly, so no per-call allocation and no
/// reliance on ndarray iteration order is needed.
fn refill_state_arrays(
    state_arrays: &mut HashMap<String, ArrayD<f64>>,
    var_shapes: &IndexMap<String, VarShape>,
    state: &[f64],
) {
    for (name, vs) in var_shapes {
        let total = vs.shape.iter().copied().product::<usize>().max(1);
        let block = &state[vs.flat_offset..vs.flat_offset + total];
        let arr = state_arrays
            .get_mut(name)
            .expect("scratch has a state array for every variable");
        if vs.shape.is_empty() {
            arr[IxDyn(&[])] = block[0];
            continue;
        }
        let n = vs.shape.len();
        let mut multi = DimU::from_elem(0usize, n);
        for _ in 0..total {
            let mut cm = 0usize;
            let mut stride = 1usize;
            for d in 0..n {
                cm += multi[d] * stride;
                stride *= vs.shape[d];
            }
            arr[IxDyn(&multi)] = block[cm];
            for d in (0..n).rev() {
                multi[d] += 1;
                if multi[d] < vs.shape[d] {
                    break;
                }
                multi[d] = 0;
            }
        }
    }
}

/// Scatter a logical array's values into the flat `dy` block at `offset`, in
/// column-major order (the state-vector convention), in place — replacing the
/// old `arrayd_to_col_major` + `copy_from_slice` (which allocated a `Vec` per
/// rule). Addresses elements explicitly, so it is layout-agnostic.
/// Scatter a logical array into a *sub-block* of a variable's flat `dy` block,
/// in column-major order (the state-vector layout). `dest_lo[d]` is the 0-based
/// start of the sub-block along axis `d` within the variable's box (extent
/// `vs.shape`); the array's own extent must fit (`dest_lo[d] + arr.shape()[d] ≤
/// vs.shape[d]`, guaranteed by [`subblock_dest`]). This is the placement for an
/// affine-shifted LHS `D(u[i+c]) = …`; the bare-index method-of-lines case is
/// `dest_lo = 0…` with `arr` spanning the whole variable box.
fn scatter_col_major_offset(
    arr: ArrayViewD<f64>,
    dy: &mut [f64],
    vs: &VarShape,
    dest_lo: &[usize],
) {
    let n = arr.ndim();
    if n == 0 {
        dy[vs.flat_offset] = arr[IxDyn(&[])];
        return;
    }
    let total: usize = arr.shape().iter().product();
    let mut multi = DimU::from_elem(0usize, n);
    for _ in 0..total {
        // Column-major flat index of (dest_lo + multi) within the variable box.
        let mut cm = 0usize;
        let mut stride = 1usize;
        for d in 0..n {
            cm += (dest_lo[d] + multi[d]) * stride;
            stride *= vs.shape[d];
        }
        dy[vs.flat_offset + cm] = arr[IxDyn(&multi)];
        for d in (0..n).rev() {
            multi[d] += 1;
            if multi[d] < arr.shape()[d] {
                break;
            }
            multi[d] = 0;
        }
    }
}

// ============================================================================
// Detection: does the file contain array-op expressions anywhere?
// ============================================================================

/// Names of the array-op sidecar operators introduced in gt-t5c. `aggregate`
/// and `makearray` are the composition primitives; the rest are shape /
/// extraction helpers that are only meaningful when operating on array
/// intermediates.
const ARRAY_OP_NAMES: &[&str] = &[
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

fn model_has_array_ops(model: &Model) -> bool {
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

fn expr_has_array_op(expr: &Expr) -> bool {
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
            if let Some(inner) = &node.expr
                && expr_has_array_op(inner)
            {
                return true;
            }
            if let Some(vals) = &node.values {
                for v in vals {
                    if expr_has_array_op(v) {
                        return true;
                    }
                }
            }
            for a in &node.args {
                if expr_has_array_op(a) {
                    return true;
                }
            }
            false
        }
    }
}

/// Walk an expression and reject any spatial differential operator
/// (`grad`/`div`/`laplacian`). Per the canonical pipeline contract, ESD
/// discretization rules MUST rewrite these into `arrayop` AST before
/// reaching any binding's simulator. Encountering one here means
/// `discretize` was skipped or did not rewrite the node — silently
/// substituting zeros (the previous behaviour) would mask the broken
/// pipeline. (esm-i7b)
fn check_no_spatial_ops(expr: &Expr) -> Result<(), CompileError> {
    match expr {
        Expr::Number(_) | Expr::Integer(_) | Expr::Variable(_) => Ok(()),
        Expr::Operator(node) => {
            // Reject unlowered rewrite-target ops (esm-spec §4.2 / §9.6.8). This
            // walk sees both the equation LHS and RHS, so it must NOT reject the
            // structural time derivative `D(_, t)` (evaluable-core); only a
            // SPATIAL `D` (`wrt` != "t") is a rewrite-target.
            let unlowered = match node.op.as_str() {
                "grad" | "div" | "laplacian" | "curl" | "∇" => true,
                "D" => node.wrt.as_deref().is_some_and(|w| w != "t"),
                _ => false,
            };
            if unlowered {
                return Err(CompileError::UnloweredOperatorError {
                    op: node.op.clone(),
                });
            }
            if let Some(inner) = &node.expr {
                check_no_spatial_ops(inner)?;
            }
            if let Some(vals) = &node.values {
                for v in vals {
                    check_no_spatial_ops(v)?;
                }
            }
            for a in &node.args {
                check_no_spatial_ops(a)?;
            }
            Ok(())
        }
    }
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
fn parse_subsystem_model(
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
fn mount_subsystems(
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
fn apply_ragged_factor_scope(
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
            coupletype: None,
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
        // equations or observed-variable expressions — the canonical
        // pipeline contract requires `grad`/`div`/`laplacian` to be
        // rewritten by ESD discretization before reaching the simulator
        // (esm-i7b).
        for eq in &model.equations {
            check_no_spatial_ops(&eq.lhs)?;
            check_no_spatial_ops(&eq.rhs)?;
        }
        for var in model.variables.values() {
            if let Some(expr) = &var.expression {
                check_no_spatial_ops(expr)?;
            }
        }

        // (1) Collect state / parameter / observed variables.
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

        // (2) Infer shapes for state variables from all equation usages.
        let mut shape_map = infer_shapes(&state_vars, &model.equations)?;

        // (2b) Seed declared array shapes for states the index-usage inference
        //      left scalar. A whole-array `D(state)` (bare LHS, no per-cell
        //      `index`) or an `ic`-only array state has no indexed reference to
        //      infer from, so its declared `shape` (index-set names resolved to
        //      sizes via the document registry) is authoritative.
        for name in &state_vars {
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

        // (3) Partition state variables. A state with a `D` equation is
        //     integrated; one defined by an algebraic equation (but no `D`) is
        //     eliminated to an observed; one with neither (an `ic`-only field) is
        //     carried at its ic with zero derivative — kept as a state so its
        //     cells are enumerated and held constant.
        let derivative_targets = collect_derivative_targets(&model.equations);
        let algebraic_defined = collect_algebraic_defined(&model.equations);

        let mut final_states: Vec<String> = Vec::new();
        let mut eliminated: HashSet<String> = HashSet::new();
        let mut held_at_ic: HashSet<String> = HashSet::new();
        for name in &state_vars {
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

        // (4) Build flat offset and scalar-slot names per state variable.
        let mut var_shapes: IndexMap<String, VarShape> = IndexMap::new();
        let mut scalar_state_names: Vec<String> = Vec::new();
        let mut scalar_state_index: HashMap<String, usize> = HashMap::new();
        let mut state_defaults: Vec<Option<f64>> = Vec::new();
        let mut flat_offset: usize = 0;

        for name in &final_states {
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

        let n_states = flat_offset;

        // (5) Build the param tables.
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

        // (6) Build observed algebraic rules from eliminated variables AND
        //     from declared observed variables that define an expression.
        let mut observed_rules: Vec<AlgebraicRule> = Vec::new();
        let mut observed_shapes: HashMap<String, VarShape> = HashMap::new();

        // Declared observed variables with an `expression` field. An array-shaped
        // observed — a discretization-agnostic PDE leaf's `psi_x`, `grad_mag`,
        // `U_n`, `S_n`, a `const`-op field, a keyed-factor alias — is evaluated
        // WHOLESALE here: `eval` looks each array-valued observed reference up in
        // the observed-array map and broadcasts the elementwise ops over it, so a
        // readable intermediate decomposition (WS4) already runs as authored. The
        // rules are dependency-ordered below, so `grad_mag` materializes before
        // `U_n`/`S_n` read it.
        for (name, var) in &observed_vars {
            if let Some(expr) = &var.expression {
                observed_rules.push(AlgebraicRule::Scalar {
                    var: (*name).clone(),
                    body: Box::new(expr.clone()),
                });
                observed_shapes.insert(
                    (*name).clone(),
                    VarShape {
                        shape: Vec::new(),
                        origin: Vec::new(),
                        flat_offset: 0,
                    },
                );
            }
        }

        // Algebraic arrayop equations for eliminated state variables.
        for eq in &model.equations {
            if let Some((var, idx_names, ranges, body)) =
                extract_algebraic_arrayop(&eq.lhs, &eq.rhs)
                && eliminated.contains(&var)
            {
                // Infer the shape from ranges.
                let shape: Vec<usize> = ranges
                    .iter()
                    .map(|(lo, hi)| (hi - lo + 1) as usize)
                    .collect();
                let origin: Vec<i64> = ranges.iter().map(|(lo, _)| *lo).collect();
                observed_shapes.insert(
                    var.clone(),
                    VarShape {
                        shape: shape.clone(),
                        origin,
                        flat_offset: 0,
                    },
                );
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
                observed_shapes.insert(
                    name.clone(),
                    VarShape {
                        shape: Vec::new(),
                        origin: Vec::new(),
                        flat_offset: 0,
                    },
                );
            }
        }

        // (6b) Dependency-order the observed rules so each is evaluated only
        //      after the observeds it reads (RFC §8.1): the geometry chain
        //      `const` polygons → `clip = intersect_polygon` → `area = FAQ(clip)`
        //      must materialize the ring before the FAQ over it. Observeds are
        //      collected above in sorted/equation order, which is NOT dependency
        //      order, so the array driver would otherwise evaluate `area` before
        //      `clip` exists. A stable Kahn sweep preserves declaration order
        //      among independent observeds (mirrors Python
        //      `simulation._order_observed_equations`).
        observed_rules = dependency_order_observed(observed_rules);

        // (7) Build RHS rules. Each equation with a derivative LHS produces
        //     either a scalar slot write, an indexed scalar slot write, or
        //     an array loop.
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

        // Classify scoped-reference / array `ic` equations (esm-spec §11.4.1)
        // out of the rule builder into `field_ics`, mirroring the flatten-path
        // classification — a single-model (`from_file`) build must fold
        // coordinate-expression / broadcast-constant ics into `u0` exactly as
        // the coupled path does. The RHS collected here has already been
        // range-resolved against the document registry above.
        let mut field_ics: Vec<(String, Expr)> = Vec::new();
        for eq in &model.equations {
            if let Some(target) = crate::flatten::extract_ic_target(&eq.lhs) {
                field_ics.push((target, eq.rhs.clone()));
            }
        }

        for eq in &model.equations {
            if let Some((
                var,
                idx_names,
                ranges,
                lhs_idx_exprs,
                body,
                contract_names,
                contract_dims,
                reduce,
                filter,
            )) = extract_derivative_arrayop(&eq.lhs, &eq.rhs)
            {
                // Array-op derivative over (idx_names, ranges).
                if !var_shapes.contains_key(&var) {
                    return Err(CompileError::InterpreterBuildError {
                        details: format!(
                            "Array-op derivative targets unknown state variable '{var}'"
                        ),
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
                    let shape = var_shapes.get(&var).ok_or_else(|| {
                        CompileError::InterpreterBuildError {
                            details: format!(
                                "Scalar derivative targets unknown state variable '{var}'"
                            ),
                        }
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
                        let loops: Vec<String> =
                            (0..ndim).map(|d| format!("_lp{d}_{var}")).collect();
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
        for name in &held_at_ic {
            if let Some(vs) = var_shapes.get(name) {
                let total = vs.shape.iter().copied().product::<usize>().max(1);
                for k in 0..total {
                    covered_slots.insert(vs.flat_offset + k);
                }
            }
        }

        // (8) Every state slot must have a defining equation.
        for (i, name) in scalar_state_names.iter().enumerate() {
            if !covered_slots.contains(&i) {
                return Err(CompileError::InterpreterBuildError {
                    details: format!("State slot '{name}' has no defining derivative equation."),
                });
            }
        }

        Ok(ArrayCompiled {
            var_shapes,
            scalar_state_names,
            scalar_state_index,
            state_defaults,
            param_names,
            param_index,
            param_defaults,
            observed_rules,
            observed_shapes,
            rhs_rules,
            n_states,
            forcing: Rc::new(RefCell::new(HashMap::new())),
            field_ics,
            index_sets: index_sets.clone(),
            namespace: None,
        })
    }

    /// A clonable handle to the external forcing buffer (PR-1, ess-14f.7). A
    /// driver that integrates this model in discrete-cadence segments holds the
    /// returned `Rc` and, at each cadence boundary, refreshes a loader-fed
    /// field: `compiled.forcing_handle().borrow_mut().insert(var, regridded)`.
    /// The captured RHS/Jacobian closures read the *same* buffer live on the
    /// next `step()`, so the refresh is reflected without rebuilding the
    /// problem. The buffer is shared (the handle and the closures clone one
    /// `Rc`); mutate it only *between* segments, never inside a solver step, to
    /// keep the RHS pure within a segment.
    pub fn forcing_handle(&self) -> Rc<RefCell<HashMap<String, ArrayD<f64>>>> {
        Rc::clone(&self.forcing)
    }

    pub fn state_variable_names(&self) -> &[String] {
        &self.scalar_state_names
    }
    pub fn parameter_names(&self) -> &[String] {
        &self.param_names
    }

    /// Evaluate the RHS `f(state, t)` once and return `(dy, stats)`. Exposed for
    /// the no-scalarization verification (ess-bdm): callers compare the
    /// vectorized path (`force_scalar = false`) against the per-cell oracle
    /// (`force_scalar = true`) for bit-equivalence, and assert that the
    /// vectorized [`RhsStats::kernel_ops`] is independent of the grid size N.
    #[doc(hidden)]
    pub fn debug_eval_rhs(
        &self,
        state: &[f64],
        t: f64,
        params: &HashMap<String, f64>,
        force_scalar: bool,
    ) -> (Vec<f64>, RhsStats) {
        let mut param_vec = vec![0.0f64; self.param_names.len()];
        for (i, name) in self.param_names.iter().enumerate() {
            if let Some(&v) = params.get(name) {
                param_vec[i] = v;
            } else if let Some(d) = self.param_defaults[i] {
                param_vec[i] = d;
            }
        }
        let mut dy = vec![0.0f64; self.n_states];
        let mut stats = RhsStats::default();
        let mut scratch = RhsScratch::new(&self.var_shapes);
        evaluate_rhs_with_scratch(
            &self.rhs_rules,
            &self.observed_rules,
            &self.observed_shapes,
            &self.var_shapes,
            &self.param_names,
            state,
            &param_vec,
            &self.forcing,
            t,
            &mut dy,
            force_scalar,
            &mut stats,
            &mut scratch,
        );
        (dy, stats)
    }

    /// Build a persistent [`RhsScratch`] sized to this model. Exposed for the
    /// zero-allocation verification (ess-mro): a counting-allocator test drives
    /// [`Self::debug_eval_rhs_into`] with a reused scratch and asserts that the
    /// steady-state vectorized RHS allocates nothing.
    #[doc(hidden)]
    pub fn debug_new_scratch(&self) -> RhsScratch {
        RhsScratch::new(&self.var_shapes)
    }

    /// Resolve a parameter map into the positional parameter vector once, so the
    /// zero-allocation RHS test can pre-build it outside the measured loop.
    #[doc(hidden)]
    pub fn debug_resolve_params(&self, params: &HashMap<String, f64>) -> Vec<f64> {
        let mut param_vec = vec![0.0f64; self.param_names.len()];
        for (i, name) in self.param_names.iter().enumerate() {
            if let Some(&v) = params.get(name) {
                param_vec[i] = v;
            } else if let Some(d) = self.param_defaults[i] {
                param_vec[i] = d;
            }
        }
        param_vec
    }

    /// Evaluate the vectorized RHS into a caller-owned `dy` using a caller-owned
    /// scratch — the allocation-free entry point. With a warmed scratch and a
    /// pre-resolved `param_vec`, this performs no heap allocation (ess-mro
    /// acceptance criterion 1).
    #[doc(hidden)]
    pub fn debug_eval_rhs_into(
        &self,
        state: &[f64],
        t: f64,
        param_vec: &[f64],
        dy: &mut [f64],
        scratch: &mut RhsScratch,
        stats: &mut RhsStats,
    ) {
        for slot in dy.iter_mut() {
            *slot = 0.0;
        }
        evaluate_rhs_with_scratch(
            &self.rhs_rules,
            &self.observed_rules,
            &self.observed_shapes,
            &self.var_shapes,
            &self.param_names,
            state,
            param_vec,
            &self.forcing,
            t,
            dy,
            false,
            stats,
            scratch,
        );
    }

    /// Resolve the deferred scoped-reference / array `ic` equations
    /// (esm-spec §11.4.1) into per-slot initial values keyed by flat state slot.
    /// A loaded-field RHS (`InitialConditions.O3_init`) is read from the
    /// provider-seeded forcing buffer and folded into the lifted grid state's cells
    /// (column-major, matching the slot enumeration in [`Self::from_model`]); a
    /// constant RHS broadcasts to every cell. Empty on the non-`ic` path.
    fn resolve_field_ics(
        &self,
        params: &HashMap<String, f64>,
    ) -> Result<HashMap<usize, f64>, SimulateError> {
        let mut out: HashMap<usize, f64> = HashMap::new();
        if self.field_ics.is_empty() {
            return Ok(out);
        }
        let forcing = self.forcing.borrow();
        for (target, rhs) in &self.field_ics {
            let vs = self.var_shapes.get(target).ok_or_else(|| {
                SimulateError::InvalidInitialCondition {
                    name: format!(
                        "ic({target}): scoped-reference target is not a state variable of the flattened system"
                    ),
                }
            })?;
            let total = vs.shape.iter().copied().product::<usize>().max(1);
            for flat in 0..total {
                let multi = flat_to_multi_col_major(flat, &vs.shape);
                let slot = vs.flat_offset + flat;
                out.insert(
                    slot,
                    resolve_field_ic_cell(
                        target,
                        rhs,
                        &multi,
                        &forcing,
                        &self.index_sets,
                        params,
                    )?,
                );
            }
        }
        Ok(out)
    }

    /// Run the simulation.
    /// Rewrite override-map keys to the BARE names this single-model system uses,
    /// stripping a leading `<namespace>.` when present (WS3 parity). A no-op clone
    /// when `namespace` is `None` (the already-namespaced `from_flattened` path)
    /// or when a key carries no such prefix.
    fn normalize_override_keys(&self, m: &HashMap<String, f64>) -> HashMap<String, f64> {
        let Some(ns) = &self.namespace else {
            return m.clone();
        };
        let prefix = format!("{ns}.");
        m.iter()
            .map(|(k, v)| {
                let key = k.strip_prefix(&prefix).map(str::to_string).unwrap_or_else(|| k.clone());
                (key, *v)
            })
            .collect()
    }

    pub fn simulate(
        &self,
        tspan: (f64, f64),
        params: &HashMap<String, f64>,
        initial_conditions: &HashMap<String, f64>,
        opts: &SimulateOptions,
    ) -> Result<Solution, SimulateError> {
        self.simulate_inspect(tspan, params, initial_conditions, opts, None)
    }

    /// [`Self::simulate`] with an optional build-observability sink (see
    /// [`BuildInspection`]). When `inspect` is `Some`, the sink is filled —
    /// after the initial state vector is assembled and before the solver runs —
    /// with the state-free observed arrays materialized at `u0`/`t0` and every
    /// observed rule's resolved body expression. The integration itself is
    /// byte-identical with or without a sink.
    pub fn simulate_inspect(
        &self,
        tspan: (f64, f64),
        params: &HashMap<String, f64>,
        initial_conditions: &HashMap<String, f64>,
        opts: &SimulateOptions,
        inspect: Option<&mut BuildInspection>,
    ) -> Result<Solution, SimulateError> {
        // WS3 override-naming parity: on the single-model path names are BARE
        // (`R_0`), but callers (and the Julia toolkit) key overrides by the
        // namespaced `Model.R_0`. Strip this model's `<namespace>.` prefix from
        // any override key so both forms resolve; keys without the prefix pass
        // through unchanged. No-op on the already-namespaced `from_flattened` path.
        let params_owned = self.normalize_override_keys(params);
        let ics_owned = self.normalize_override_keys(initial_conditions);
        let params = &params_owned;
        let initial_conditions = &ics_owned;
        let (t0, t_end) = tspan;
        let n_states = self.n_states;
        let n_params = self.param_names.len();

        // Validate param names and build the param vec.
        for key in params.keys() {
            if !self.param_index.contains_key(key) {
                return Err(SimulateError::InvalidParameter { name: key.clone() });
            }
        }
        let mut param_vec = vec![0.0f64; n_params];
        for (i, name) in self.param_names.iter().enumerate() {
            if let Some(&v) = params.get(name) {
                param_vec[i] = v;
            } else if let Some(d) = self.param_defaults[i] {
                param_vec[i] = d;
            } else {
                return Err(SimulateError::InvalidParameter { name: name.clone() });
            }
        }

        // Validate IC names and build the initial state vector.
        for key in initial_conditions.keys() {
            if !self.scalar_state_index.contains_key(key) {
                return Err(SimulateError::InvalidInitialCondition { name: key.clone() });
            }
        }
        // Fold scoped-reference / array `ic` fields (esm-spec §11.4.1) into u0 from
        // the provider-seeded forcing buffer (DESIGN pde_simulation_pipeline §2 R2).
        // Priority per slot: explicit `initial_conditions` override > loaded field
        // ic > variable default.
        // Resolved scalar-parameter scope (load-time constants) for the ic
        // coordinate-expression path — a parameter-dependent grid-geometry
        // template (`x0 + (i − 1/2)·dx`) binds here; STATE is not in scope.
        let resolved_params: HashMap<String, f64> = self
            .param_names
            .iter()
            .cloned()
            .zip(param_vec.iter().copied())
            .collect();
        let field_ic_map = self.resolve_field_ics(&resolved_params)?;
        let mut ic_vec = vec![0.0f64; n_states];
        for (i, name) in self.scalar_state_names.iter().enumerate() {
            if let Some(&v) = initial_conditions.get(name) {
                ic_vec[i] = v;
            } else if let Some(&v) = field_ic_map.get(&i) {
                ic_vec[i] = v;
            } else if let Some(d) = self.state_defaults[i] {
                ic_vec[i] = d;
            } else {
                return Err(SimulateError::InvalidInitialCondition { name: name.clone() });
            }
        }

        // Build observability (see `BuildInspection`): one extra read-only
        // observed materialization at the initial state. Nothing downstream
        // consults the sink, so the integration is unchanged.
        if let Some(insp) = inspect {
            self.fill_inspection(insp, &ic_vec, &param_vec, t0);
        }

        let rhs_rules = self.rhs_rules.clone();
        let observed_rules = self.observed_rules.clone();
        let observed_shapes = self.observed_shapes.clone();
        let var_shapes = self.var_shapes.clone();
        let param_names = self.param_names.clone();

        let rhs_rules_jac = rhs_rules.clone();
        let observed_rules_jac = observed_rules.clone();
        let observed_shapes_jac = observed_shapes.clone();
        let var_shapes_jac = var_shapes.clone();
        let param_names_jac = param_names.clone();

        // Per-closure reusable scratch (ess-mro). `RefCell` gives the interior
        // mutability diffsol's `Fn` RHS requires; the Jacobian closure carries
        // its own so the two never alias.
        let rhs_scratch = RefCell::new(RhsScratch::new(&var_shapes));
        let jac_scratch = RefCell::new(RhsScratch::new(&var_shapes_jac));

        // External forcing channel (PR-1, ess-14f.7): clone the `Rc` handle into
        // each closure so both the RHS and the Jacobian read the *same*
        // model-lifetime buffer the caller mutates via `forcing_handle()`. The
        // closures capture by move; the original `self.forcing` stays owned by
        // the model (used for output-time observed exposure below).
        let forcing_rhs = Rc::clone(&self.forcing);
        let forcing_jac = Rc::clone(&self.forcing);

        let rhs_closure = move |y: &diffsol::FaerVec<f64>,
                                p: &diffsol::FaerVec<f64>,
                                t: f64,
                                dy: &mut diffsol::FaerVec<f64>| {
            let y_s = y.as_slice();
            let p_s = p.as_slice();
            let dy_s = dy.as_mut_slice();
            for slot in dy_s.iter_mut() {
                *slot = 0.0;
            }
            let mut scratch = rhs_scratch.borrow_mut();
            evaluate_rhs_with_scratch(
                &rhs_rules,
                &observed_rules,
                &observed_shapes,
                &var_shapes,
                &param_names,
                y_s,
                p_s,
                &forcing_rhs,
                t,
                dy_s,
                false,
                &mut RhsStats::default(),
                &mut scratch,
            );
        };

        let jac_closure = move |y: &diffsol::FaerVec<f64>,
                                p: &diffsol::FaerVec<f64>,
                                t: f64,
                                v: &diffsol::FaerVec<f64>,
                                jv: &mut diffsol::FaerVec<f64>| {
            let n = y.as_slice().len();
            let v_s = v.as_slice();
            let p_s = p.as_slice();
            let y_s = y.as_slice();
            let mut y_norm = 0.0f64;
            for &yi in y_s {
                y_norm += yi * yi;
            }
            let y_norm = y_norm.sqrt().max(1.0);
            let eps = f64::EPSILON.sqrt() * y_norm;

            let mut y_perturbed = vec![0.0f64; n];
            for i in 0..n {
                y_perturbed[i] = y_s[i] + eps * v_s[i];
            }

            let mut f_y = vec![0.0f64; n];
            let mut f_yp = vec![0.0f64; n];
            let mut scratch = jac_scratch.borrow_mut();
            evaluate_rhs_with_scratch(
                &rhs_rules_jac,
                &observed_rules_jac,
                &observed_shapes_jac,
                &var_shapes_jac,
                &param_names_jac,
                y_s,
                p_s,
                &forcing_jac,
                t,
                &mut f_y,
                false,
                &mut RhsStats::default(),
                &mut scratch,
            );
            evaluate_rhs_with_scratch(
                &rhs_rules_jac,
                &observed_rules_jac,
                &observed_shapes_jac,
                &var_shapes_jac,
                &param_names_jac,
                &y_perturbed,
                p_s,
                &forcing_jac,
                t,
                &mut f_yp,
                false,
                &mut RhsStats::default(),
                &mut scratch,
            );
            let jv_s = jv.as_mut_slice();
            for i in 0..n {
                jv_s[i] = (f_yp[i] - f_y[i]) / eps;
            }
        };

        let abstol = opts.abstol;
        let reltol = opts.reltol;
        let ic_for_init = ic_vec.clone();

        let builder = OdeBuilder::<FaerMat<f64>>::new()
            .t0(t0)
            .rtol(reltol)
            .atol(vec![abstol; n_states])
            .p(param_vec.clone())
            .rhs_implicit(rhs_closure, jac_closure)
            .init(
                move |_p: &diffsol::FaerVec<f64>, _t: f64, y: &mut diffsol::FaerVec<f64>| {
                    let y_s = y.as_mut_slice();
                    for (i, &v) in ic_for_init.iter().enumerate() {
                        y_s[i] = v;
                    }
                },
                n_states,
            );

        let problem = builder.build().map_err(|e| SimulateError::DiffsolError {
            details: e.to_string(),
        })?;

        let solver_name = match opts.solver {
            SolverChoice::Bdf => "Bdf",
            SolverChoice::Sdirk => "Sdirk",
            SolverChoice::Erk => "Erk",
        };

        let (time, mut state) = match opts.solver {
            SolverChoice::Bdf => {
                let mut solver: Bdf<'_, _, NewtonNonlinearSolver<_, FaerLU<f64>, _>> = problem
                    .bdf::<FaerLU<f64>>()
                    .map_err(|e| SimulateError::DiffsolError {
                        details: e.to_string(),
                    })?;
                run_solver(&mut solver, t_end, opts)?
            }
            SolverChoice::Sdirk => {
                let mut solver: Sdirk<'_, _, FaerLU<f64>> = problem
                    .tr_bdf2::<FaerLU<f64>>()
                    .map_err(|e| SimulateError::DiffsolError {
                        details: e.to_string(),
                    })?;
                run_solver(&mut solver, t_end, opts)?
            }
            SolverChoice::Erk => {
                let mut solver = problem.tsit45().map_err(|e| SimulateError::DiffsolError {
                    details: e.to_string(),
                })?;
                run_solver(&mut solver, t_end, opts)?
            }
        };

        // Expose scalar observed trajectories (e.g. an `area` FAQ) alongside the
        // states so inline conformance assertions can read algebraic quantities
        // (RFC §8.1; CONFORMANCE_SPEC.md §5.8). The integrator carries only the
        // state vector, so re-evaluate the (dependency-ordered, derived-ring-aware)
        // observeds from the state trajectory at each output node and append the
        // scalar ones. Array-valued observeds (the clip ring, the const polygons)
        // are not scalar rows and are skipped. Mirrors the Python
        // `_simulate_with_numpy` output-observed exposure.
        let mut state_variable_names = self.scalar_state_names.clone();
        if !self.observed_rules.is_empty() && !time.is_empty() {
            // Which observeds resolve to scalars? Materialize once at the first
            // node, preserving the dependency-ordered rule order.
            let obs_at = |k: usize| -> HashMap<String, ArrayD<f64>> {
                let flat: Vec<f64> = (0..n_states).map(|i| state[i][k]).collect();
                let sa = build_state_arrays(&self.var_shapes, &flat);
                let dr: RefCell<HashMap<String, ArrayD<f64>>> = RefCell::new(HashMap::new());
                materialize_observeds(
                    &self.observed_rules,
                    &sa,
                    &param_vec,
                    &self.param_names,
                    time[k],
                    &dr,
                    &self.forcing,
                )
            };
            let obs0 = obs_at(0);
            let scalar_obs: Vec<String> = self
                .observed_rules
                .iter()
                .map(|r| observed_rule_var(r).clone())
                .filter(|name| obs0.get(name).map(|a| a.ndim() == 0).unwrap_or(false))
                .collect();
            if !scalar_obs.is_empty() {
                let mut rows: Vec<Vec<f64>> =
                    vec![Vec::with_capacity(time.len()); scalar_obs.len()];
                for k in 0..time.len() {
                    let obs = if k == 0 { obs0.clone() } else { obs_at(k) };
                    for (j, name) in scalar_obs.iter().enumerate() {
                        rows[j].push(
                            obs.get(name)
                                .and_then(|a| a.first().copied())
                                .unwrap_or(f64::NAN),
                        );
                    }
                }
                for (name, row) in scalar_obs.into_iter().zip(rows) {
                    state_variable_names.push(name);
                    state.push(row);
                }
            }
        }

        Ok(Solution {
            time,
            state,
            state_variable_names,
            metadata: SolutionMetadata {
                solver: solver_name.to_string(),
                ..Default::default()
            },
        })
    }

    /// Fill a [`BuildInspection`] sink: materialize the (dependency-ordered)
    /// observed rules once at the initial state through the official
    /// [`materialize_observeds`] machinery, record every rule's resolved body
    /// expression, and record the arrays of the STATE-FREE subset — rules whose
    /// transitive references reach no state variable, no `t`, and no external
    /// forcing entry (each reference must be a parameter, a loop index, or an
    /// already-state-free observed). Read-only with respect to the run.
    fn fill_inspection(
        &self,
        insp: &mut BuildInspection,
        ic_vec: &[f64],
        param_vec: &[f64],
        t0: f64,
    ) {
        // Resolved scalar parameters (load-time constants) so the reference /
        // ic positions can bind them into a build-time cellwise evaluation,
        // matching the observed-assertion form (materialized below with the
        // same `param_vec`).
        for (i, name) in self.param_names.iter().enumerate() {
            insp.params.insert(name.clone(), param_vec[i]);
        }
        let sa = build_state_arrays(&self.var_shapes, ic_vec);
        let dr: RefCell<HashMap<String, ArrayD<f64>>> = RefCell::new(HashMap::new());
        let obs = materialize_observeds(
            &self.observed_rules,
            &sa,
            param_vec,
            &self.param_names,
            t0,
            &dr,
            &self.forcing,
        );
        let observed_names: HashSet<&String> =
            self.observed_rules.iter().map(observed_rule_var).collect();
        let forcing_names: HashSet<String> = self.forcing.borrow().keys().cloned().collect();
        let mut state_free: HashSet<String> = HashSet::new();
        // `observed_rules` is dependency-ordered (Kahn sweep at build), so each
        // rule's observed references are classified before the rule itself; a
        // cycle survivor's unplaced reference correctly disqualifies it.
        for rule in &self.observed_rules {
            let name = observed_rule_var(rule);
            let body = observed_rule_body(rule);
            insp.observed_exprs.insert(name.clone(), body.clone());
            let mut refs = HashSet::new();
            collect_expr_var_refs(body, &mut refs);
            let ok = refs.iter().all(|r| {
                r != "t"
                    && !self.var_shapes.contains_key(r)
                    && !forcing_names.contains(r)
                    && (!observed_names.contains(r) || state_free.contains(r))
            });
            if ok {
                state_free.insert(name.clone());
                if let Some(a) = obs.get(name) {
                    insp.setup_arrays.insert(name.clone(), a.clone());
                }
            }
        }
    }
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
    Ok(eval_expression(
        &resolved,
        &HashMap::new(),
        &param_vec,
        &param_names,
        0.0,
    ))
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
fn resolve_field_ic_cell(
    target: &str,
    rhs: &Expr,
    cell: &[usize],
    forcing: &HashMap<String, ArrayD<f64>>,
    index_sets: &HashMap<String, IndexSet>,
    params: &HashMap<String, f64>,
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
        return Err(SimulateError::InvalidInitialCondition {
            name: format!(
                "ic({target}): loaded field '{name}' has ndim={} which does not match the {}-D lifted target grid",
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
    if let Expr::Operator(_) = rhs {
        match eval_buildtime_field(rhs, index_sets, params) {
            Ok(Value::Scalar(s)) if s.is_finite() => return Ok(s),
            Ok(Value::Array(arr)) => {
                if arr.ndim() != cell.len() {
                    return Err(SimulateError::InvalidInitialCondition {
                        name: format!(
                            "ic({target}): coordinate expression evaluates to ndim={}, which does not match the {}-D lifted target grid",
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
    Err(SimulateError::InvalidInitialCondition {
        name: format!(
            "ic({target}): RHS is neither a provider-served loaded field, a constant, nor a per-cell coordinate expression{hint}"
        ),
    })
}

/// The target variable an observed algebraic rule defines.
fn observed_rule_var(rule: &AlgebraicRule) -> &String {
    match rule {
        AlgebraicRule::Scalar { var, .. } | AlgebraicRule::ArrayLoop { var, .. } => var,
    }
}

/// The defining body expression of an observed algebraic rule.
fn observed_rule_body(rule: &AlgebraicRule) -> &Expr {
    match rule {
        AlgebraicRule::Scalar { body, .. } | AlgebraicRule::ArrayLoop { body, .. } => body,
    }
}

/// Collect every variable-reference leaf (`Expr::Variable`) in `expr`, walking
/// `args`, the aggregate `expr` body, makearray `values`, table `axes`, the join
/// `filter`, and the `lower`/`upper` bounds so a dependency edge is never missed.
/// Loop indices and other non-observed names are gathered too; the caller
/// intersects with the observed-name set to keep only the meaningful edges.
fn collect_expr_var_refs(expr: &Expr, out: &mut HashSet<String>) {
    match expr {
        Expr::Variable(name) => {
            out.insert(name.clone());
        }
        Expr::Operator(node) => {
            for a in &node.args {
                collect_expr_var_refs(a, out);
            }
            if let Some(b) = &node.expr {
                collect_expr_var_refs(b, out);
            }
            if let Some(l) = &node.lower {
                collect_expr_var_refs(l, out);
            }
            if let Some(u) = &node.upper {
                collect_expr_var_refs(u, out);
            }
            if let Some(vals) = &node.values {
                for v in vals {
                    collect_expr_var_refs(v, out);
                }
            }
            if let Some(axes) = &node.axes {
                for v in axes.values() {
                    collect_expr_var_refs(v, out);
                }
            }
            if let Some(f) = &node.filter {
                collect_expr_var_refs(f, out);
            }
        }
        Expr::Number(_) | Expr::Integer(_) => {}
    }
}

/// Stable topological sort of observed algebraic rules so each follows every
/// observed its body references (RFC §8.1). Independent observeds keep their
/// original order; any rule left in a dependency cycle is appended in original
/// order so the build still proceeds (the evaluator then surfaces a clear
/// unresolved read rather than the driver hanging). Mirrors the Python
/// `simulation._order_observed_equations`.
fn dependency_order_observed(rules: Vec<AlgebraicRule>) -> Vec<AlgebraicRule> {
    let names: HashSet<String> = rules.iter().map(|r| observed_rule_var(r).clone()).collect();
    // Per-rule dependency set, restricted to *other* observed names.
    let deps: Vec<HashSet<String>> = rules
        .iter()
        .map(|r| {
            let mut refs = HashSet::new();
            collect_expr_var_refs(observed_rule_body(r), &mut refs);
            let self_name = observed_rule_var(r);
            refs.retain(|n| names.contains(n) && n != self_name);
            refs
        })
        .collect();

    let mut placed: HashSet<String> = HashSet::new();
    let mut order: Vec<usize> = Vec::with_capacity(rules.len());
    let mut remaining: Vec<usize> = (0..rules.len()).collect();
    while !remaining.is_empty() {
        let mut progress = false;
        let mut still: Vec<usize> = Vec::new();
        for i in std::mem::take(&mut remaining) {
            if deps[i].iter().all(|d| placed.contains(d)) {
                placed.insert(observed_rule_var(&rules[i]).clone());
                order.push(i);
                progress = true;
            } else {
                still.push(i);
            }
        }
        remaining = still;
        if !progress {
            break; // a cycle — append the rest in original order below
        }
    }
    order.extend(remaining);

    // Reassemble in the computed order, moving each rule out exactly once.
    let mut slots: Vec<Option<AlgebraicRule>> = rules.into_iter().map(Some).collect();
    order
        .into_iter()
        .map(|i| slots[i].take().expect("each index visited once"))
        .collect()
}

// ============================================================================
// Runtime: evaluate one RHS call.
// ============================================================================

/// Build per-variable ndarray views from the flat state vector (owned copies —
/// fast enough at fixture sizes). A scalar variable becomes a 0-D array; an
/// array variable is read column-major over its inferred shape.
fn build_state_arrays(
    var_shapes: &IndexMap<String, VarShape>,
    state: &[f64],
) -> HashMap<String, ArrayD<f64>> {
    let mut state_arrays: HashMap<String, ArrayD<f64>> = HashMap::new();
    for (name, vs) in var_shapes {
        let total = vs.shape.iter().copied().product::<usize>().max(1);
        let block = &state[vs.flat_offset..vs.flat_offset + total];
        if vs.shape.is_empty() {
            state_arrays.insert(name.clone(), ArrayD::from_elem(IxDyn(&[]), block[0]));
        } else {
            // The flat block is column-major over vs.shape.
            state_arrays.insert(name.clone(), col_major_to_arrayd(block, &vs.shape));
        }
    }
    state_arrays
}

/// Evaluate the observed algebraic rules (already dependency-ordered at build
/// time) at the given state/time into a name→array map, registering any
/// FAQ-materialized derived ring under its producer id in `derived_rings`. An
/// observed whose body yields an array (a `const` polygon, the clip ring) is
/// stored as an array so downstream `index(...)` reads address it; a scalar body
/// (an `area` FAQ) is a 0-D array. Shared by the RHS driver ([`evaluate_rhs`])
/// and the output-time observed exposure ([`ArrayCompiled::simulate`]) so both
/// see identical observed values.
fn materialize_observeds(
    observed_rules: &[AlgebraicRule],
    state_arrays: &HashMap<String, ArrayD<f64>>,
    params: &[f64],
    param_names: &[String],
    t: f64,
    derived_rings: &RefCell<HashMap<String, ArrayD<f64>>>,
    forcing: &RefCell<HashMap<String, ArrayD<f64>>>,
) -> HashMap<String, ArrayD<f64>> {
    let mut observed_arrays: HashMap<String, ArrayD<f64>> = HashMap::new();
    for rule in observed_rules {
        match rule {
            AlgebraicRule::Scalar { var, body } => {
                let mut ctx = EvalCtx {
                    state_arrays,
                    observed_arrays: &observed_arrays,
                    params,
                    param_names,
                    loop_binds: HashMap::new(),
                    t,
                    derived_rings,
                    forcing,
                };
                let arr = match eval(body, &mut ctx) {
                    Value::Array(a) => a,
                    Value::Scalar(s) => ArrayD::from_elem(IxDyn(&[]), s),
                };
                observed_arrays.insert(var.clone(), arr);
            }
            AlgebraicRule::ArrayLoop {
                var,
                output_idx_names,
                output_ranges,
                body,
            } => {
                // Size the storage as 1-based (origin 1) with max_index extent
                // per dimension so downstream `index(v, k)` always computes
                // offset `k - 1` regardless of the range's lo. Positions below
                // the defined range are left at 0.
                let padded_shape: Vec<usize> =
                    output_ranges.iter().map(|(_, hi)| *hi as usize).collect();
                let padded_origin: Vec<i64> = vec![1i64; padded_shape.len()];
                let total = padded_shape.iter().copied().product::<usize>().max(1);
                let mut buf = vec![0.0f64; total];
                for tuple in cartesian_range(output_ranges) {
                    let mut ctx = EvalCtx {
                        state_arrays,
                        observed_arrays: &observed_arrays,
                        params,
                        param_names,
                        loop_binds: HashMap::new(),
                        t,
                        derived_rings,
                        forcing,
                    };
                    for (name, val) in output_idx_names.iter().zip(tuple.iter()) {
                        ctx.loop_binds.insert(name.clone(), *val);
                    }
                    let v = eval(body, &mut ctx).as_scalar().unwrap_or(f64::NAN);
                    let flat = multi_to_flat_col_major(&tuple, &padded_shape, &padded_origin);
                    if flat < buf.len() {
                        buf[flat] = v;
                    }
                }
                let arr = col_major_to_arrayd(&buf, &padded_shape);
                observed_arrays.insert(var.clone(), arr);
            }
        }
    }
    observed_arrays
}

/// Like [`materialize_observeds`] but writes into a reused container (ess-mro),
/// so the observed map is not reallocated each RHS call. The container is
/// cleared (capacity retained) then repopulated; for models with no observeds
/// — the vectorized PDE path — it stays empty and nothing is allocated. The
/// observed *value* arrays themselves are still materialized fresh (only models
/// that actually carry algebraic observeds pay that, and they are outside the
/// zero-allocation stencil path being verified).
fn materialize_observeds_into(
    dst: &mut HashMap<String, ArrayD<f64>>,
    observed_rules: &[AlgebraicRule],
    state_arrays: &HashMap<String, ArrayD<f64>>,
    params: &[f64],
    param_names: &[String],
    t: f64,
    derived_rings: &RefCell<HashMap<String, ArrayD<f64>>>,
    forcing: &RefCell<HashMap<String, ArrayD<f64>>>,
) {
    dst.clear();
    for rule in observed_rules {
        match rule {
            AlgebraicRule::Scalar { var, body } => {
                let mut ctx = EvalCtx {
                    state_arrays,
                    observed_arrays: &*dst,
                    params,
                    param_names,
                    loop_binds: HashMap::new(),
                    t,
                    derived_rings,
                    forcing,
                };
                let arr = match eval(body, &mut ctx) {
                    Value::Array(a) => a,
                    Value::Scalar(s) => ArrayD::from_elem(IxDyn(&[]), s),
                };
                dst.insert(var.clone(), arr);
            }
            AlgebraicRule::ArrayLoop {
                var,
                output_idx_names,
                output_ranges,
                body,
            } => {
                let padded_shape: Vec<usize> =
                    output_ranges.iter().map(|(_, hi)| *hi as usize).collect();
                let padded_origin: Vec<i64> = vec![1i64; padded_shape.len()];
                let total = padded_shape.iter().copied().product::<usize>().max(1);
                let mut buf = vec![0.0f64; total];
                for tuple in cartesian_range(output_ranges) {
                    let mut ctx = EvalCtx {
                        state_arrays,
                        observed_arrays: &*dst,
                        params,
                        param_names,
                        loop_binds: HashMap::new(),
                        t,
                        derived_rings,
                        forcing,
                    };
                    for (name, val) in output_idx_names.iter().zip(tuple.iter()) {
                        ctx.loop_binds.insert(name.clone(), *val);
                    }
                    let v = eval(body, &mut ctx).as_scalar().unwrap_or(f64::NAN);
                    let flat = multi_to_flat_col_major(&tuple, &padded_shape, &padded_origin);
                    if flat < buf.len() {
                        buf[flat] = v;
                    }
                }
                let arr = col_major_to_arrayd(&buf, &padded_shape);
                dst.insert(var.clone(), arr);
            }
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn evaluate_rhs_with_scratch(
    rhs_rules: &[RhsRule],
    observed_rules: &[AlgebraicRule],
    observed_shapes: &HashMap<String, VarShape>,
    var_shapes: &IndexMap<String, VarShape>,
    param_names: &[String],
    state: &[f64],
    params: &[f64],
    // External refreshable forcing-array channel (PR-1, ess-14f.7): the
    // model-lifetime buffer a discrete-cadence driver refreshes between
    // segments. Borrowed (not owned by the per-call scratch) so the same buffer
    // is read across every RHS call within a segment. Empty ⇒ no behaviour
    // change vs. the scalar-`p` path.
    forcing: &RefCell<HashMap<String, ArrayD<f64>>>,
    t: f64,
    dy: &mut [f64],
    // When true, skip the vectorized fast path and evaluate every array-op
    // derivative via the per-cell oracle. Production always passes `false`
    // (vectorized); the equivalence test passes `true` to obtain the
    // reference values. See [`RhsStats`].
    force_scalar: bool,
    stats: &mut RhsStats,
    // Reused buffers (ess-mro): persistent per-variable state arrays + observed
    // container + kernel buffer pool, so the steady-state vectorized RHS does
    // not allocate.
    scratch: &mut RhsScratch,
) {
    // (a) Refill the persistent per-variable state arrays in place from the
    //     flat state vector (no per-call allocation).
    refill_state_arrays(&mut scratch.state_arrays, var_shapes, state);

    // FAQ-materialized derived rings (RFC §8.1), keyed by producer node id. An
    // `intersect_polygon` clip self-registers its closed overlap ring here as it
    // evaluates (see `eval_intersect_polygon`); a downstream `aggregate` over a
    // `kind:"derived"` index set then sizes its contraction from the ring's
    // vertex count. Shared (interior-mutable) across the observed materialization
    // and the RHS rules so a ring registered while `clip` materializes is visible
    // both when `area` runs and in any state derivative that reads a derived set.
    // Empty (no allocation) for models without geometry, i.e. the stencil path.
    let derived_rings: RefCell<HashMap<String, ArrayD<f64>>> = RefCell::new(HashMap::new());

    // (b) Materialize observed algebraic rules (dependency-ordered at build time)
    //     into the reused observed container before the state derivatives read
    //     them. For models with no observeds (the vectorized PDE path) this
    //     leaves the container empty and allocates nothing.
    materialize_observeds_into(
        &mut scratch.observed_arrays,
        observed_rules,
        &scratch.state_arrays,
        params,
        param_names,
        t,
        &derived_rings,
        forcing,
    );

    // Emit observed shapes we need for downstream variable lookups.
    let _ = observed_shapes; // kept for future consistency checks

    // Split the scratch into disjoint field borrows: the state/observed arrays
    // are read (shared) while the buffer pool is checked out (exclusive).
    let state_arrays = &scratch.state_arrays;
    let observed_arrays = &scratch.observed_arrays;
    let pool = &mut scratch.pool;

    // (c) Evaluate each RHS rule and write into dy.
    for rule in rhs_rules {
        match rule {
            RhsRule::Scalar { slot, body } => {
                let mut ctx = EvalCtx {
                    state_arrays,
                    observed_arrays,
                    params,
                    param_names,
                    loop_binds: HashMap::new(),
                    t,
                    derived_rings: &derived_rings,
                    forcing,
                };
                let v = eval(body, &mut ctx).as_scalar().unwrap_or(f64::NAN);
                dy[*slot] = v;
            }
            RhsRule::IndexedScalar { slot, body } => {
                let mut ctx = EvalCtx {
                    state_arrays,
                    observed_arrays,
                    params,
                    param_names,
                    loop_binds: HashMap::new(),
                    t,
                    derived_rings: &derived_rings,
                    forcing,
                };
                let v = eval(body, &mut ctx).as_scalar().unwrap_or(f64::NAN);
                dy[*slot] = v;
            }
            RhsRule::ArrayLoop {
                var_name,
                output_idx_names,
                output_ranges,
                lhs_idx_exprs,
                body,
                contract_names,
                contract_dims,
                reduce,
                filter,
            } => {
                let vs = &var_shapes[var_name];
                let filter = filter.as_deref();

                // ---- Vectorized (whole-array) fast path (ess-bdm, ess-p9s) --
                // A discretized spatial derivative whose LHS addresses the state
                // by a constant per-axis shift of the output indices
                // (`D(u[i+c])`, `c` constant; the bare-index method-of-lines
                // case is `c = 0`) is evaluated as whole-array kernels:
                //   * shifted slices for affine-ghost neighbours `index(u,i±k)`,
                //   * cyclic rolls for periodic-wrap neighbours,
                //   * a small static fold over einsum contraction indices,
                //   * region sub-range writes for boundary makearrays,
                //   * broadcast arithmetic for coefficients,
                // then the dy sub-block is scattered in place. No per-element
                // scalar loop walks the body, and (ess-mro) no heap allocation
                // occurs: intermediates come from `pool`. A `filter`
                // (data-dependent FAQ gating) is left to the per-cell oracle.
                let lhs_shifts = lhs_constant_shifts(lhs_idx_exprs, output_idx_names);
                if !force_scalar && filter.is_none() {
                    if let Some(dest_lo) = lhs_shifts
                        .as_ref()
                        .and_then(|shifts| subblock_dest(vs, output_ranges, shifts))
                    {
                        let ctx = EvalCtx {
                            state_arrays,
                            observed_arrays,
                            params,
                            param_names,
                            loop_binds: HashMap::new(),
                            t,
                            derived_rings: &derived_rings,
                            forcing,
                        };
                        if let Some((val, ops)) = try_eval_arrayop_vectorized(
                            output_idx_names,
                            output_ranges,
                            body,
                            contract_names,
                            contract_dims,
                            *reduce,
                            &ctx,
                            pool,
                        ) {
                            let total = vs.shape.iter().copied().product::<usize>().max(1);
                            if vs.flat_offset + total <= dy.len() {
                                if let Some(view) = val.view() {
                                    scatter_col_major_offset(view, dy, vs, &dest_lo);
                                }
                                val.release(pool);
                                stats.kernel_ops += ops;
                                stats.vectorized_rules += 1;
                                continue;
                            }
                            val.release(pool);
                        }
                    }
                }

                // ---- Per-cell oracle (fallback / forced reference) ---------
                stats.scalar_rules += 1;
                for tuple in cartesian_range(output_ranges) {
                    let mut ctx = EvalCtx {
                        state_arrays,
                        observed_arrays,
                        params,
                        param_names,
                        loop_binds: HashMap::new(),
                        t,
                        derived_rings: &derived_rings,
                        forcing,
                    };
                    for (name, val) in output_idx_names.iter().zip(tuple.iter()) {
                        ctx.loop_binds.insert(name.clone(), *val);
                    }
                    // Generalized einsum: contracted indices (incl. ragged
                    // per-cell dynamic bounds) are unrolled and ⊕-combined here.
                    let v = reduce_contraction(
                        contract_names,
                        contract_dims,
                        body,
                        *reduce,
                        filter,
                        &mut ctx,
                    );
                    let actual_multi: Vec<i64> = lhs_idx_exprs
                        .iter()
                        .map(|e| eval_simple_index(e, &ctx.loop_binds))
                        .collect();
                    let flat = multi_to_flat_col_major(&actual_multi, &vs.shape, &vs.origin);
                    dy[vs.flat_offset + flat] = v;
                }
            }
        }
    }
}

// ============================================================================
// Vectorized (whole-array) stencil evaluator (ess-bdm).
//
// Evaluates a discretized spatial arrayop RHS as whole-array kernels instead
// of a per-cell scalar loop, mirroring the Python `numpy_interpreter`
// vectorized path (ESS PR #25, `_materialize_map` + shifted-slice `_eval_index`
// + region-materialized makearray). The state stays the gridded array; the RHS
// is computed by:
//   * shifted array slices for stencil neighbours `index(u, sym±k)`,
//   * Julia-left-aligned broadcast arithmetic for coefficients (reusing the
//     existing `combine`/`broadcast_binary`),
//   * boundary makearrays materialized region-by-region as array sub-range
//     writes (last region wins),
// producing the whole output array in a single AST walk. The number of kernel
// ops is therefore independent of the grid size N — the no-scalarization
// property ess-bdm requires.
//
// This is a *fast path*: any construct it does not handle (general semiring
// contraction, periodic-wrap / non-affine indexing, reshape/transpose, …)
// returns `None`, and the caller falls back to the per-cell oracle, which
// remains the correctness reference.
// ============================================================================

/// A value produced by the vectorized evaluator. Array values carry their
/// per-axis 1-based `origin` (the index value of the first element along each
/// axis) so an enclosing `index(A, sym±k)` can align `A` to the output box with
/// a shifted slice.
///
/// To keep the steady-state RHS allocation-free (ess-mro), an array intermediate
/// is either a borrowed view of a persistent state/observed array
/// ([`VecValue::View`] — never mutated) or a buffer drawn from the [`Pool`]
/// ([`VecValue::Owned`] — mutated in place and returned to the pool when
/// consumed). The previous single owning variant cloned each source array per
/// read and allocated a fresh array per kernel node.
enum VecValue<'a> {
    Scalar(f64),
    View { data: &'a ArrayD<f64>, origin: DimI },
    Owned { data: ArrayD<f64>, origin: DimI },
}

impl<'a> VecValue<'a> {
    /// The per-axis origin of an array value (`None` for a scalar).
    fn origin(&self) -> Option<&[i64]> {
        match self {
            VecValue::Scalar(_) => None,
            VecValue::View { origin, .. } | VecValue::Owned { origin, .. } => Some(origin),
        }
    }

    /// The shape of an array value (`None` for a scalar).
    fn shape(&self) -> Option<&[usize]> {
        match self {
            VecValue::Scalar(_) => None,
            VecValue::View { data, .. } => Some(data.shape()),
            VecValue::Owned { data, .. } => Some(data.shape()),
        }
    }

    /// A read-only view of an array value (`None` for a scalar).
    fn view(&self) -> Option<ArrayViewD<'_, f64>> {
        match self {
            VecValue::Scalar(_) => None,
            VecValue::View { data, .. } => Some(data.view()),
            VecValue::Owned { data, .. } => Some(data.view()),
        }
    }

    /// Consume an array value into an owned, pool-backed buffer: reuse the
    /// buffer when already `Owned`, or copy a `View` into a fresh pooled buffer.
    fn into_owned(self, pool: &mut Pool) -> (ArrayD<f64>, DimI) {
        match self {
            VecValue::Owned { data, origin } => (data, origin),
            VecValue::View { data, origin } => {
                let mut buf = pool.take_array(data.shape());
                buf.assign(data);
                (buf, origin)
            }
            VecValue::Scalar(_) => unreachable!("into_owned called on a scalar"),
        }
    }

    /// Release a consumed value's pooled buffer (no-op for `View`/`Scalar`).
    fn release(self, pool: &mut Pool) {
        if let VecValue::Owned { data, .. } = self {
            pool.give_array(data);
        }
    }
}

/// The output box currently being materialized: the positional output index
/// symbols and, per axis, the 1-based low index and extent.
struct VecBox<'a> {
    syms: &'a [String],
    lo: &'a [i64],
    shape: &'a [usize],
    /// Bound contracted-index names (empty for a pure-map stencil). When an
    /// einsum body is evaluated once per contraction tuple, the current tuple's
    /// values live in `cvals` (parallel to `cnames`). A bare `cnames` symbol
    /// then resolves to its `cvals` entry as a scalar (so `ifelse(k==0,…)` folds
    /// per `k`), and an index offset `i + k` folds `k` into the affine shift —
    /// making `sum_k 25·ifelse(k==0,-2,1)·u[i+k]` a small fold of shifted
    /// whole-array slices instead of a per-cell semiring walk.
    cnames: &'a [String],
    cvals: &'a [i64],
}

impl<'a> VecBox<'a> {
    /// Resolve a bound contracted-index symbol to its current integer value.
    fn cbind(&self, name: &str) -> Option<i64> {
        self.cnames
            .iter()
            .position(|n| n == name)
            .map(|i| self.cvals[i])
    }
}

/// Per-axis constant LHS shift: if every LHS index expression is `sym_d + c_d`
/// (bare `sym_d` ⇒ `c_d = 0`; the only shapes a vectorized box maps directly
/// onto the state block), return the shifts `c_d`. `None` for a permutation or
/// any non-constant-shift LHS (→ oracle). The bare-index method-of-lines stencil
/// yields all-zero shifts; an einsum `D(u[i+1]) = …` yields `[1]`.
fn lhs_constant_shifts(
    lhs_idx_exprs: &[Expr],
    output_idx_names: &[String],
) -> Option<SmallVec<[i64; 4]>> {
    if lhs_idx_exprs.len() != output_idx_names.len() {
        return None;
    }
    // The LHS references only output symbols, never contraction indices.
    let nobind = VecBox {
        syms: &[],
        lo: &[],
        shape: &[],
        cnames: &[],
        cvals: &[],
    };
    let mut shifts = SmallVec::new();
    for (e, sym) in lhs_idx_exprs.iter().zip(output_idx_names.iter()) {
        shifts.push(affine_offset_in(e, sym, &nobind)?);
    }
    Some(shifts)
}

/// Locate the output box within the state variable's flat block: the per-axis
/// 0-based start `dest_lo[d] = output_lo[d] + shift[d] − origin[d]`, validated
/// to fit inside the variable's extent. `None` if the rank disagrees or the
/// shifted box would leave the variable (→ oracle). For the bare-index stencil
/// (`shift = 0`, output box == variable box) every `dest_lo[d]` is 0.
fn subblock_dest(
    vs: &VarShape,
    output_ranges: &[(i64, i64)],
    shifts: &[i64],
) -> Option<SmallVec<[usize; 4]>> {
    if vs.shape.len() != output_ranges.len() || shifts.len() != output_ranges.len() {
        return None;
    }
    let mut dest = SmallVec::new();
    for d in 0..output_ranges.len() {
        let (olo, ohi) = output_ranges[d];
        let extent = ohi - olo + 1;
        if extent <= 0 {
            return None;
        }
        let dlo = olo + shifts[d] - vs.origin[d];
        if dlo < 0 || dlo + extent > vs.shape[d] as i64 {
            return None;
        }
        dest.push(dlo as usize);
    }
    Some(dest)
}

/// Try to evaluate an arrayop body over the output box as whole-array kernels.
/// A pure-map stencil (`contract_names` empty) walks the body once; an einsum
/// stencil folds the body over its contracted indices ([`eval_vec_contracted`]).
/// Returns `Some((array, kernel_ops))` on success — `kernel_ops` is the number
/// of AST nodes visited (N-independent) — or `None` if the body contains a
/// construct the vectorized path does not handle (the caller then uses the
/// per-cell oracle).
fn try_eval_arrayop_vectorized<'a>(
    output_idx_names: &[String],
    output_ranges: &[(i64, i64)],
    body: &Expr,
    contract_names: &[String],
    contract_dims: &[ContractDim],
    reduce: ReduceKind,
    ctx: &EvalCtx<'a>,
    pool: &mut Pool,
) -> Option<(VecValue<'a>, usize)> {
    let lo: DimI = output_ranges.iter().map(|(l, _)| *l).collect();
    let shape: DimU = output_ranges
        .iter()
        .map(|(l, h)| (h - l + 1) as usize)
        .collect();
    if shape.contains(&0) {
        return None;
    }
    let mut ops = 0usize;
    let v = if contract_names.is_empty() {
        let bx = VecBox {
            syms: output_idx_names,
            lo: &lo[..],
            shape: &shape[..],
            cnames: &[],
            cvals: &[],
        };
        eval_vec(body, &bx, ctx, pool, &mut ops)?
    } else {
        eval_vec_contracted(
            output_idx_names,
            &lo,
            &shape,
            body,
            contract_names,
            contract_dims,
            reduce,
            ctx,
            pool,
            &mut ops,
        )?
    };
    // The top-level result must already cover the output box exactly. A bare
    // scalar is broadcast over the box.
    let matches_box = match v.shape() {
        None => true,
        Some(s) => s == &shape[..] && v.origin().map(|o| o == &lo[..]).unwrap_or(false),
    };
    if !matches_box {
        v.release(pool);
        return None;
    }
    let out = match v {
        VecValue::Scalar(s) => {
            let mut buf = pool.take_array(&shape);
            buf.fill(s);
            VecValue::Owned {
                data: buf,
                origin: lo,
            }
        }
        other => other,
    };
    Some((out, ops))
}

/// Map a reduction's ⊕ to the elementwise [`apply_binary`] op used to combine
/// term arrays. `None` for the boolean reductions, which the fast path leaves to
/// the oracle.
fn reduce_combine_op(reduce: ReduceKind) -> Option<&'static str> {
    match reduce {
        ReduceKind::Sum => Some("+"),
        ReduceKind::Product => Some("*"),
        ReduceKind::Max => Some("max"),
        ReduceKind::Min => Some("min"),
        ReduceKind::Or | ReduceKind::And => None,
    }
}

/// Evaluate an einsum arrayop body as a whole-array fold over its contracted
/// indices: for each contraction tuple `k` (a small static window — fixed-width
/// neighbour stencil), bind `k` and evaluate the body once as whole-array
/// kernels, then ⊕-combine into the accumulator. Starting from a buffer filled
/// with the reduction identity and left-folding makes this bit-identical to the
/// per-cell oracle's `acc = reduce.combine(acc, term)` loop (`0+t`, `1·t`,
/// `max(−∞,t)`, `min(+∞,t)` are exact). The number of kernel walks is the
/// contraction-window size — independent of the grid size N.
///
/// Only **static** contraction bounds are vectorized; ragged/derived dims
/// (per-output-tuple extents) and the boolean reductions return `None` so the
/// caller falls back to the per-cell oracle.
#[allow(clippy::too_many_arguments)]
fn eval_vec_contracted<'a>(
    output_idx_names: &[String],
    lo: &[i64],
    shape: &[usize],
    body: &Expr,
    contract_names: &[String],
    contract_dims: &[ContractDim],
    reduce: ReduceKind,
    ctx: &EvalCtx<'a>,
    pool: &mut Pool,
    ops: &mut usize,
) -> Option<VecValue<'a>> {
    let combine_op = reduce_combine_op(reduce)?;
    // Resolve each contracted dim to a static (lo, hi). A non-static dim
    // (ragged/derived — per-output-tuple extent) can't be a uniform whole-array
    // window, so bail to the oracle.
    const MAXC: usize = 4;
    let nc = contract_names.len();
    if nc == 0 || nc > MAXC {
        return None;
    }
    let mut clo = [0i64; MAXC];
    let mut chi = [0i64; MAXC];
    for (i, d) in contract_dims.iter().enumerate() {
        match d {
            ContractDim::Static(l, h) => {
                clo[i] = *l;
                chi[i] = *h;
            }
            _ => return None,
        }
    }

    // Accumulator: a pooled buffer filled with the reduction identity.
    let mut acc_buf = pool.take_array(shape);
    let identity = reduce.identity();
    if identity != 0.0 {
        acc_buf.fill(identity);
    }
    let mut acc = VecValue::Owned {
        data: acc_buf,
        origin: lo.iter().copied().collect(),
    };

    // An empty window (lo > hi on any dim) contributes no terms — the result is
    // the identity, matching the oracle's empty reduction.
    if (0..nc).any(|i| clo[i] > chi[i]) {
        return Some(acc);
    }

    // Iterate the contraction window with a mixed-radix counter (no allocation).
    let mut cvals = [0i64; MAXC];
    cvals[..nc].copy_from_slice(&clo[..nc]);
    loop {
        let bx = VecBox {
            syms: output_idx_names,
            lo,
            shape,
            cnames: contract_names,
            cvals: &cvals[..nc],
        };
        let term = match eval_vec(body, &bx, ctx, pool, ops) {
            Some(t) => t,
            None => {
                acc.release(pool);
                return None;
            }
        };
        // `vec_combine` releases both operands on a shape mismatch before
        // returning `None`, so `?` (bail to the oracle) leaks no pooled buffer.
        acc = vec_combine(combine_op, acc, term, pool)?;

        // Mixed-radix increment over the contraction window.
        let mut d = 0;
        let mut done = false;
        loop {
            if d == nc {
                done = true;
                break;
            }
            cvals[d] += 1;
            if cvals[d] <= chi[d] {
                break;
            }
            cvals[d] = clo[d];
            d += 1;
        }
        if done {
            break;
        }
    }
    Some(acc)
}

/// Vectorized evaluation of `expr` over the output box `bx`. Increments `ops`
/// once per AST node. Returns `None` on any unsupported construct.
fn eval_vec<'a>(
    expr: &Expr,
    bx: &VecBox,
    ctx: &EvalCtx<'a>,
    pool: &mut Pool,
    ops: &mut usize,
) -> Option<VecValue<'a>> {
    *ops += 1;
    match expr {
        Expr::Number(n) => Some(VecValue::Scalar(*n)),
        Expr::Integer(n) => Some(VecValue::Scalar(*n as f64)),
        Expr::Variable(name) => eval_vec_variable(name, bx, ctx),
        Expr::Operator(node) => eval_vec_op(node, bx, ctx, pool, ops),
    }
}

fn eval_vec_variable<'a>(name: &str, bx: &VecBox, ctx: &EvalCtx<'a>) -> Option<VecValue<'a>> {
    if name == "t" {
        return Some(VecValue::Scalar(ctx.t));
    }
    // A bound contracted index (einsum fold) is a constant scalar for the whole
    // output box on this tuple — so `k` in `ifelse(k==0,…)` folds per tuple.
    if let Some(v) = bx.cbind(name) {
        return Some(VecValue::Scalar(v as f64));
    }
    // A bare output index symbol as a *value* (rather than inside `index(...)`
    // addressing) is not part of the stencil fast path — bail to the oracle.
    if bx.syms.iter().any(|s| s == name) {
        return None;
    }
    // State/observed reads return a borrowed view of the persistent array — no
    // clone (ess-mro). The enclosing `index(...)` slices the view directly.
    if let Some(a) = ctx.state_arrays.get(name) {
        return Some(if a.ndim() == 0 {
            VecValue::Scalar(a[IxDyn(&[])])
        } else {
            VecValue::View {
                data: a,
                origin: DimI::from_elem(1, a.ndim()),
            }
        });
    }
    if let Some(a) = ctx.observed_arrays.get(name) {
        return Some(if a.ndim() == 0 {
            VecValue::Scalar(a[IxDyn(&[])])
        } else {
            VecValue::View {
                data: a,
                origin: DimI::from_elem(1, a.ndim()),
            }
        });
    }
    if let Some(i) = ctx.param_names.iter().position(|p| p == name) {
        return Some(VecValue::Scalar(ctx.params[i]));
    }
    // Unknown bare symbol (e.g. an outer-scope loop bind, or an external
    // forcing-fed field — PR-1, ess-14f.7): bail. The per-cell oracle resolves
    // it via [`lookup_variable`], which reads `ctx.forcing`. Forcing is
    // intentionally *not* resolved here: `ctx.forcing` is a `RefCell`, so it
    // cannot hand back a `'a`-lifetime borrowed `VecValue::View` the way the
    // persistent state/observed arrays do — a zero-copy vectorized forcing read
    // would need the buffer restructured. Correctness holds (the oracle reads
    // the live buffer); only the whole-array fast path is forgone for a rule
    // that reads forcing. Optimizing that is a separate, optional follow-up.
    None
}

fn eval_vec_op<'a>(
    node: &ExpressionNode,
    bx: &VecBox,
    ctx: &EvalCtx<'a>,
    pool: &mut Pool,
    ops: &mut usize,
) -> Option<VecValue<'a>> {
    match node.op.as_str() {
        "+" | "-" | "*" | "/" | "^" | "min" | "max" => {
            if node.op == "-" && node.args.len() == 1 {
                return Some(vec_negate(
                    eval_vec(&node.args[0], bx, ctx, pool, ops)?,
                    pool,
                ));
            }
            let mut acc = eval_vec(&node.args[0], bx, ctx, pool, ops)?;
            for a in &node.args[1..] {
                let v = eval_vec(a, bx, ctx, pool, ops)?;
                acc = vec_combine(&node.op, acc, v, pool)?;
            }
            Some(acc)
        }
        "neg" => Some(vec_negate(
            eval_vec(&node.args[0], bx, ctx, pool, ops)?,
            pool,
        )),
        "index" => eval_vec_index(node, bx, ctx, pool, ops),
        "makearray" => eval_vec_makearray(node, bx, ctx, pool, ops),
        "const" => match eval_const(node) {
            Value::Scalar(s) => Some(VecValue::Scalar(s)),
            // Array-valued constants are not part of the stencil fast path.
            Value::Array(_) => None,
        },
        // Scalar comparisons and `ifelse` over *scalar* operands — the einsum
        // weight idiom `ifelse(k==0,-2,1)` folds to a constant per contraction
        // tuple. Bit-identical to the oracle's `eval_op` (same `==`-via-abs and
        // `c != 0.0` branch test). An *array* operand (a per-cell-varying
        // condition) is not on the fast path and bails to the oracle.
        "==" | "!=" | "<" | "<=" | ">" | ">=" => {
            if node.args.len() != 2 {
                return None;
            }
            let a = eval_vec_scalar(&node.args[0], bx, ctx, pool, ops)?;
            let b = eval_vec_scalar(&node.args[1], bx, ctx, pool, ops)?;
            Some(VecValue::Scalar(scalar_compare(&node.op, a, b)))
        }
        "ifelse" => {
            if node.args.len() != 3 {
                return None;
            }
            let c = eval_vec_scalar(&node.args[0], bx, ctx, pool, ops)?;
            if c != 0.0 {
                eval_vec(&node.args[1], bx, ctx, pool, ops)
            } else {
                eval_vec(&node.args[2], bx, ctx, pool, ops)
            }
        }
        // Everything else (array-valued ifelse, aggregate, reshape, transpose,
        // concat, broadcast, transcendentals over arrays, D, …) falls back.
        _ => None,
    }
}

/// Evaluate `expr` over the box and require a scalar result (a per-cell-varying
/// array bails the fast path). Used for `ifelse` conditions / branches and
/// comparison operands, which the einsum weight idiom keeps scalar.
fn eval_vec_scalar(
    expr: &Expr,
    bx: &VecBox,
    ctx: &EvalCtx,
    pool: &mut Pool,
    ops: &mut usize,
) -> Option<f64> {
    match eval_vec(expr, bx, ctx, pool, ops)? {
        VecValue::Scalar(s) => Some(s),
        other => {
            other.release(pool);
            None
        }
    }
}

/// Scalar comparison, bit-identical to the oracle's `eval_op` arm: `==`/`!=`
/// test exact equality via `(a-b).abs()`, the orderings use the native `f64`
/// relops; result is `1.0` (true) / `0.0` (false).
fn scalar_compare(op: &str, a: f64, b: f64) -> f64 {
    let t = match op {
        "==" => (a - b).abs() == 0.0,
        "!=" => (a - b).abs() != 0.0,
        "<" => a < b,
        "<=" => a <= b,
        ">" => a > b,
        ">=" => a >= b,
        _ => return f64::NAN,
    };
    if t { 1.0 } else { 0.0 }
}

fn vec_negate<'a>(v: VecValue<'a>, pool: &mut Pool) -> VecValue<'a> {
    match v {
        VecValue::Scalar(s) => VecValue::Scalar(-s),
        VecValue::Owned { mut data, origin } => {
            data.mapv_inplace(|x| -x);
            VecValue::Owned { data, origin }
        }
        VecValue::View { data, origin } => {
            let mut buf = pool.take_array(data.shape());
            ndarray::Zip::from(&mut buf)
                .and(data)
                .for_each(|o, &x| *o = -x);
            VecValue::Owned { data: buf, origin }
        }
    }
}

/// Combine two vectorized values with a binary arithmetic op, preserving the
/// `(left, right)` argument order (so non-commutative ops stay bit-identical to
/// the per-cell oracle). Array operands must share the same box (origin +
/// shape) — which holds within a stencil body, since every `index(...)` result
/// is produced over the current output box; a mismatch releases both operands
/// and returns `None` (bail to oracle). The result reuses an `Owned` operand's
/// pooled buffer in place when possible, so no array is allocated (ess-mro).
fn vec_combine<'a>(
    op: &str,
    a: VecValue<'a>,
    b: VecValue<'a>,
    pool: &mut Pool,
) -> Option<VecValue<'a>> {
    match (a, b) {
        (VecValue::Scalar(x), VecValue::Scalar(y)) => {
            Some(VecValue::Scalar(apply_binary(op, x, y)))
        }
        // scalar ∘ array
        (VecValue::Scalar(x), barr) => {
            let (mut data, origin) = barr.into_owned(pool);
            data.mapv_inplace(|y| apply_binary(op, x, y));
            Some(VecValue::Owned { data, origin })
        }
        // array ∘ scalar
        (aarr, VecValue::Scalar(y)) => {
            let (mut data, origin) = aarr.into_owned(pool);
            data.mapv_inplace(|x| apply_binary(op, x, y));
            Some(VecValue::Owned { data, origin })
        }
        // array ∘ array
        (aarr, barr) => {
            let same = aarr.origin() == barr.origin() && aarr.shape() == barr.shape();
            if !same {
                aarr.release(pool);
                barr.release(pool);
                return None;
            }
            match (aarr, barr) {
                // Reuse a's buffer: out[k] = op(a[k], b[k]).
                (VecValue::Owned { mut data, origin }, b2) => {
                    {
                        let bv = b2.view().expect("array operand has a view");
                        ndarray::Zip::from(&mut data)
                            .and(&bv)
                            .for_each(|x, &y| *x = apply_binary(op, *x, y));
                    }
                    b2.release(pool);
                    Some(VecValue::Owned { data, origin })
                }
                // a is a View, b is Owned: reuse b's buffer but keep order —
                // out[k] = op(a[k], b[k]) stored into b's slot.
                (a2, VecValue::Owned { mut data, origin }) => {
                    let av = a2.view().expect("array operand has a view");
                    ndarray::Zip::from(&mut data)
                        .and(&av)
                        .for_each(|bslot, &aval| *bslot = apply_binary(op, aval, *bslot));
                    Some(VecValue::Owned { data, origin })
                }
                // both Views: a fresh pooled buffer.
                (a2, b2) => {
                    let origin: DimI = a2.origin().expect("array origin").iter().copied().collect();
                    let av = a2.view().expect("array operand has a view");
                    let bv = b2.view().expect("array operand has a view");
                    let mut buf = pool.take_array(av.shape());
                    ndarray::Zip::from(&mut buf)
                        .and(&av)
                        .and(&bv)
                        .for_each(|o, &x, &y| *o = apply_binary(op, x, y));
                    Some(VecValue::Owned { data: buf, origin })
                }
            }
        }
    }
}

/// Vectorized `index(A, e_0, …, e_{n-1})`: a shifted / rolled array slice. Each
/// index expression is classified per axis ([`classify_axis_index`]) as either
/// an affine shift `sym_d ± k` (a sub-range copy; positions whose source index
/// leaves `A`'s extent stay ghost-0, matching the scalar `eval_index`
/// out-of-bounds → 0 homogeneous-Dirichlet convention) or a periodic wrap (a
/// cyclic roll of the full axis). The result spans the current output box. The
/// gather is `≤ 2^(#wrap-axes)` whole-array block copies — independent of the
/// grid size N. Any axis the classifier does not recognize returns `None`.
fn eval_vec_index<'a>(
    node: &ExpressionNode,
    bx: &VecBox,
    ctx: &EvalCtx<'a>,
    pool: &mut Pool,
    ops: &mut usize,
) -> Option<VecValue<'a>> {
    if node.args.is_empty() {
        return None;
    }
    let arg0 = eval_vec(&node.args[0], bx, ctx, pool, ops)?;
    let n = node.args.len() - 1;
    // `index(scalar)` with a single arg is the identity; a scalar is otherwise
    // not indexable on the fast path.
    if arg0.shape().is_none() {
        return match arg0 {
            VecValue::Scalar(s) if n == 0 => Some(VecValue::Scalar(s)),
            _ => None,
        };
    }
    let src_ndim = arg0.shape().expect("array").len();
    if n != src_ndim || n != bx.shape.len() {
        arg0.release(pool);
        return None;
    }
    let src_origin: DimI = arg0
        .origin()
        .expect("array origin")
        .iter()
        .copied()
        .collect();
    let src_shape: DimU = arg0.shape().expect("array").iter().copied().collect();

    // Per axis, classify the index expression and build its source→output copy
    // segments `(out_off, len, src_off)` (all 0-based). An affine axis yields a
    // single in-bounds segment (ghost positions stay 0); a periodic-wrap axis
    // yields the one or two segments of a cyclic roll (full coverage, no ghost).
    let mut axis_segs: SmallVec<[SmallVec<[(usize, usize, usize); 2]>; 4]> = SmallVec::new();
    for d in 0..n {
        let so = src_origin[d];
        let ssz = src_shape[d] as i64;
        match classify_axis_index(&node.args[1 + d], &bx.syms[d], bx) {
            Some(AxisIndex::Affine(k)) => {
                // output position p (0-based) → symbol bx.lo[d]+p → source 1-based
                // bx.lo[d]+p+k → source 0-based −so; in-bounds when
                // 0 ≤ bx.lo[d]+p+k−so ≤ ssz−1.
                let lo_p = (so - bx.lo[d] - k).max(0);
                let hi_p = (so + ssz - bx.lo[d] - k).min(bx.shape[d] as i64); // exclusive
                if lo_p >= hi_p {
                    // Entirely out of bounds on this axis ⇒ the whole result is
                    // ghost-0 (the zero-filled pooled buffer).
                    arg0.release(pool);
                    return Some(VecValue::Owned {
                        data: pool.take_array(bx.shape),
                        origin: bx.lo.iter().copied().collect(),
                    });
                }
                let mut segs = SmallVec::new();
                segs.push((
                    lo_p as usize,
                    (hi_p - lo_p) as usize,
                    (bx.lo[d] + lo_p + k - so) as usize,
                ));
                axis_segs.push(segs);
            }
            Some(AxisIndex::Wrap { k, period }) => {
                // A roll requires the source axis to be the full period (origin
                // == box low, extent == period == box extent).
                if so != bx.lo[d] || ssz != period || bx.shape[d] as i64 != period {
                    arg0.release(pool);
                    return None;
                }
                let p = period as usize;
                let s = (((k % period) + period) % period) as usize; // shift in [0,period)
                let mut segs = SmallVec::new();
                if s == 0 {
                    segs.push((0usize, p, 0usize));
                } else {
                    // result[q] = src[(q+s) mod period]:
                    //   out[0 .. p−s] ← src[s .. p];  out[p−s .. p] ← src[0 .. s].
                    segs.push((0usize, p - s, s));
                    segs.push((p - s, s, 0usize));
                }
                axis_segs.push(segs);
            }
            None => {
                arg0.release(pool);
                return None;
            }
        }
    }

    // Copy every cartesian combination of per-axis segments into the zero-filled
    // pooled buffer (ghost positions keep the Dirichlet 0).
    let mut result = pool.take_array(bx.shape);
    {
        let src_view = arg0.view().expect("array");
        let mut pick = DimU::from_elem(0usize, n);
        loop {
            {
                let mut out_view = result.slice_each_axis_mut(|ax| {
                    let d = ax.axis.index();
                    let (o, l, _) = axis_segs[d][pick[d]];
                    Slice::from(o..o + l)
                });
                let src_sub = src_view.slice_each_axis(|ax| {
                    let d = ax.axis.index();
                    let (_, l, s) = axis_segs[d][pick[d]];
                    Slice::from(s..s + l)
                });
                out_view.assign(&src_sub);
            }
            // Mixed-radix increment over the per-axis segment counts.
            let mut d = 0;
            let mut done = false;
            loop {
                if d == n {
                    done = true;
                    break;
                }
                pick[d] += 1;
                if pick[d] < axis_segs[d].len() {
                    break;
                }
                pick[d] = 0;
                d += 1;
            }
            if done {
                break;
            }
        }
    }
    arg0.release(pool);
    Some(VecValue::Owned {
        data: result,
        origin: bx.lo.iter().copied().collect(),
    })
}

/// Vectorized makearray: materialize each region as a whole-array sub-range
/// write over the region's box (last region wins), reusing the enclosing output
/// symbols. Returns an array spanning the union bounding box.
fn eval_vec_makearray<'a>(
    node: &ExpressionNode,
    bx: &VecBox,
    ctx: &EvalCtx<'a>,
    pool: &mut Pool,
    ops: &mut usize,
) -> Option<VecValue<'a>> {
    let regions = node.regions.as_ref()?;
    let values = node.values.as_ref()?;
    if regions.is_empty() || values.len() != regions.len() {
        return None;
    }
    let ndim = regions[0].len();
    if ndim != bx.shape.len() {
        return None;
    }
    let mut lo_bb = DimI::from_elem(i64::MAX, ndim);
    let mut hi_bb = DimI::from_elem(i64::MIN, ndim);
    for region in regions {
        if region.len() != ndim {
            return None;
        }
        for (d, r) in region.iter().enumerate() {
            lo_bb[d] = lo_bb[d].min(r[0]);
            hi_bb[d] = hi_bb[d].max(r[1]);
        }
    }
    let bb_shape: DimU = (0..ndim)
        .map(|d| (hi_bb[d] - lo_bb[d] + 1) as usize)
        .collect();
    let mut result = pool.take_array(&bb_shape);
    for (region, value_expr) in regions.iter().zip(values.iter()) {
        let r_lo: DimI = region.iter().map(|r| r[0]).collect();
        let r_shape: DimU = region.iter().map(|r| (r[1] - r[0] + 1) as usize).collect();
        if r_shape.contains(&0) {
            pool.give_array(result);
            return None;
        }
        let rbx = VecBox {
            syms: bx.syms,
            lo: &r_lo[..],
            shape: &r_shape[..],
            cnames: bx.cnames,
            cvals: bx.cvals,
        };
        let v = match eval_vec(value_expr, &rbx, ctx, pool, ops) {
            Some(v) => v,
            None => {
                pool.give_array(result);
                return None;
            }
        };
        // An array region value must match the region box exactly.
        let mismatch = match v.shape() {
            None => false, // scalar fills the region
            Some(s) => v.origin().map(|o| o != &r_lo[..]).unwrap_or(true) || s != &r_shape[..],
        };
        if mismatch {
            v.release(pool);
            pool.give_array(result);
            return None;
        }
        match v {
            VecValue::Scalar(s) => {
                let mut sub = result.slice_each_axis_mut(|ax| {
                    let d = ax.axis.index();
                    let s0 = (r_lo[d] - lo_bb[d]) as usize;
                    Slice::from(s0..s0 + r_shape[d])
                });
                sub.fill(s);
            }
            other => {
                {
                    let vview = other.view().expect("array operand has a view");
                    let mut sub = result.slice_each_axis_mut(|ax| {
                        let d = ax.axis.index();
                        let s0 = (r_lo[d] - lo_bb[d]) as usize;
                        Slice::from(s0..s0 + r_shape[d])
                    });
                    sub.assign(&vview);
                }
                other.release(pool);
            }
        }
    }
    Some(VecValue::Owned {
        data: result,
        origin: lo_bb,
    })
}

/// How a single `index(...)` axis expression maps output positions to source
/// positions along that axis, for the vectorized path.
enum AxisIndex {
    /// `sym ± k` with unit coefficient and a constant integer offset `k`
    /// (bound contraction indices folded in): a shifted slice. Out-of-extent
    /// positions stay ghost-0 (homogeneous Dirichlet).
    Affine(i64),
    /// Periodic wrap of base offset `k` over an axis of period `period`: a
    /// cyclic roll, no ghost. See [`parse_wrap_axis`] for the recognized idiom.
    Wrap { k: i64, period: i64 },
}

/// Classify one `index` axis expression: affine shift first (the common
/// stencil/ghost case), then the periodic-wrap idiom. `None` for anything else,
/// so the caller bails to the per-cell oracle.
fn classify_axis_index(expr: &Expr, sym: &str, bx: &VecBox) -> Option<AxisIndex> {
    if let Some(k) = affine_offset_in(expr, sym, bx) {
        return Some(AxisIndex::Affine(k));
    }
    parse_wrap_axis(expr, sym, bx)
}

/// Parse `expr` as `1·sym + k` and return the integer offset `k`. Sub-terms not
/// mentioning `sym` must fold to integer constants — literals and bound
/// contraction indices ([`VecBox::cbind`]). `None` if `expr` is not affine in
/// `sym` with unit coefficient and an integer constant part. Generalizes the
/// former literal-only `sym ± int` parser so an einsum offset `(i+1)+k` folds
/// the bound `k` into the shift.
fn affine_offset_in(expr: &Expr, sym: &str, bx: &VecBox) -> Option<i64> {
    let (coeff, konst) = affine_terms(expr, sym, bx)?;
    if coeff == 1 { Some(konst) } else { None }
}

/// Reduce `expr` to `(coeff_of_sym, constant)` over the integers, folding bound
/// contraction indices and integer literals. `None` for any non-integer or
/// nonlinear (sym·sym) construct.
fn affine_terms(expr: &Expr, sym: &str, bx: &VecBox) -> Option<(i64, i64)> {
    match expr {
        Expr::Integer(n) => Some((0, *n)),
        Expr::Number(n) if n.fract() == 0.0 => Some((0, *n as i64)),
        Expr::Number(_) => None,
        Expr::Variable(v) if v == sym => Some((1, 0)),
        Expr::Variable(v) => bx.cbind(v).map(|k| (0, k)),
        Expr::Operator(node) => match node.op.as_str() {
            "+" => {
                let mut coeff = 0i64;
                let mut konst = 0i64;
                for a in &node.args {
                    let (c, k) = affine_terms(a, sym, bx)?;
                    coeff = coeff.checked_add(c)?;
                    konst = konst.checked_add(k)?;
                }
                Some((coeff, konst))
            }
            "-" if node.args.len() == 2 => {
                let (c0, k0) = affine_terms(&node.args[0], sym, bx)?;
                let (c1, k1) = affine_terms(&node.args[1], sym, bx)?;
                Some((c0.checked_sub(c1)?, k0.checked_sub(k1)?))
            }
            "-" | "neg" if node.args.len() == 1 => {
                let (c, k) = affine_terms(&node.args[0], sym, bx)?;
                Some((c.checked_neg()?, k.checked_neg()?))
            }
            "*" => {
                // Linear ⇒ at most one factor carries `sym`; the others must be
                // integer constants. `(c·sym + k)·M = (c·M)·sym + (k·M)`.
                let mut sym_factor: Option<(i64, i64)> = None;
                let mut m: i64 = 1;
                for a in &node.args {
                    let (c, k) = affine_terms(a, sym, bx)?;
                    if c != 0 {
                        if sym_factor.is_some() {
                            return None; // sym·sym — nonlinear
                        }
                        sym_factor = Some((c, k));
                    } else {
                        m = m.checked_mul(k)?;
                    }
                }
                match sym_factor {
                    Some((c, k)) => Some((c.checked_mul(m)?, k.checked_mul(m)?)),
                    None => Some((0, m)),
                }
            }
            _ => None,
        },
    }
}

/// Recognize the periodic-wrap index idiom and return its base offset `k` and
/// period `P`:
///   `ifelse(inner < lo, inner + P, ifelse(inner > hi, inner − P, inner))`
/// where `inner = sym + k` is affine, `lo`/`hi` are the integer axis bounds and
/// `P = hi − lo + 1`. Both wrap branches must use the same `P`. This is the
/// shape emitted by the lat-lon (periodic-longitude) discretization.
fn parse_wrap_axis(expr: &Expr, sym: &str, bx: &VecBox) -> Option<AxisIndex> {
    let outer = as_op(expr, "ifelse", 3)?;
    // cond1: inner < lo  →  then1: inner + P
    let (lt_lhs, lo_bound) = as_cmp_const(&outer.args[0], "<")?;
    let k = affine_offset_in(lt_lhs, sym, bx)?;
    let p1 = affine_offset_in(&outer.args[1], sym, bx)?.checked_sub(k)?;
    // else1: ifelse(inner > hi, inner − P, inner)
    let inner_if = as_op(&outer.args[2], "ifelse", 3)?;
    let (gt_lhs, hi_bound) = as_cmp_const(&inner_if.args[0], ">")?;
    if affine_offset_in(gt_lhs, sym, bx)? != k {
        return None;
    }
    let p2 = k.checked_sub(affine_offset_in(&inner_if.args[1], sym, bx)?)?;
    if affine_offset_in(&inner_if.args[2], sym, bx)? != k {
        return None; // the fall-through branch must be the bare `inner`
    }
    let period = hi_bound.checked_sub(lo_bound)?.checked_add(1)?;
    if p1 != period || p2 != period || period <= 0 {
        return None;
    }
    Some(AxisIndex::Wrap { k, period })
}

/// Match `Expr::Operator(op, …)` of the given arity, returning the node.
fn as_op<'e>(expr: &'e Expr, op: &str, arity: usize) -> Option<&'e ExpressionNode> {
    match expr {
        Expr::Operator(node) if node.op == op && node.args.len() == arity => Some(node),
        _ => None,
    }
}

/// Match `inner <op> <int-const>` (the comparison shape used inside the wrap
/// idiom), returning `(&inner, const)`.
fn as_cmp_const<'e>(expr: &'e Expr, op: &str) -> Option<(&'e Expr, i64)> {
    let node = as_op(expr, op, 2)?;
    let c = match &node.args[1] {
        Expr::Integer(n) => *n,
        Expr::Number(n) if n.fract() == 0.0 => *n as i64,
        _ => return None,
    };
    Some((&node.args[0], c))
}

// ============================================================================
// Interpreter.
// ============================================================================

struct EvalCtx<'a> {
    state_arrays: &'a HashMap<String, ArrayD<f64>>,
    observed_arrays: &'a HashMap<String, ArrayD<f64>>,
    params: &'a [f64],
    param_names: &'a [String],
    loop_binds: HashMap<String, i64>,
    t: f64,
    /// Runtime registry of FAQ-materialized derived rings (RFC §8.1): an
    /// `intersect_polygon` clip self-registers its closed overlap ring here
    /// under its node `id`, so a downstream `aggregate` over a `kind:"derived"`
    /// index set (`from_faq: <id>`) resolves its extent (the distinct-vertex
    /// count) via [`derived_ring_extent`]. Interior-mutable so the producer can
    /// register while the same borrow chain reads it; empty for models with no
    /// derived sets (byte-identical to the pre-geometry path).
    derived_rings: &'a RefCell<HashMap<String, ArrayD<f64>>>,
    /// External refreshable forcing-array channel (PR-1, ess-14f.7). Unlike
    /// `derived_rings` (rebuilt fresh every RHS call), this borrows the
    /// model-lifetime [`ArrayCompiled::forcing`] buffer a driver refreshes
    /// between cadence segments; a forcing-fed variable name resolves to its
    /// entry here (see [`lookup_variable`]). Empty for models with no loader
    /// forcing, so the scalar-`p` path reads identically.
    forcing: &'a RefCell<HashMap<String, ArrayD<f64>>>,
}

/// The distinct-vertex extent of the FAQ-materialized ring registered under
/// `from_faq` (RFC §8.1): the producing `intersect_polygon` clip stores the
/// **closed** ring (`n+1` rows, first vertex repeated so the `polygon_area`
/// shoelace can read the wrap edge as an ordinary `index(ring, v+1, …)`), so the
/// number of distinct vertices is `rows − 1`. An unmaterialized producer or an
/// empty (disjoint) clip yields `0` — an empty contraction reducing to the
/// additive identity 0̄, matching the evaluator's ghost-read convention and the
/// Python reference (`numpy_interpreter._resolve_range_spec`).
fn derived_ring_extent(from_faq: &str, ctx: &EvalCtx) -> i64 {
    match ctx.derived_rings.borrow().get(from_faq) {
        Some(ring) if ring.ndim() >= 1 => (ring.shape()[0] as i64 - 1).max(0),
        _ => 0,
    }
}

fn eval(expr: &Expr, ctx: &mut EvalCtx) -> Value {
    match expr {
        Expr::Number(n) => Value::Scalar(*n),
        Expr::Integer(n) => Value::Scalar(*n as f64),
        Expr::Variable(name) => lookup_variable(name, ctx),
        Expr::Operator(node) => eval_op(node, ctx),
    }
}

fn lookup_variable(name: &str, ctx: &EvalCtx) -> Value {
    if name == "t" {
        return Value::Scalar(ctx.t);
    }
    if let Some(v) = ctx.loop_binds.get(name) {
        return Value::Scalar(*v as f64);
    }
    if let Some(a) = ctx.state_arrays.get(name) {
        return if a.ndim() == 0 {
            Value::Scalar(a[IxDyn(&[])])
        } else {
            Value::Array(a.clone())
        };
    }
    if let Some(a) = ctx.observed_arrays.get(name) {
        return if a.ndim() == 0 {
            Value::Scalar(a[IxDyn(&[])])
        } else {
            Value::Array(a.clone())
        };
    }
    if let Some(i) = ctx.param_names.iter().position(|p| p == name) {
        return Value::Scalar(ctx.params[i]);
    }
    // External forcing channel (PR-1, ess-14f.7): a loader-fed field a driver
    // refreshed into the buffer. Checked *last* — after t, loop binds, state,
    // observed, and params — so it can only resolve a name that is otherwise
    // unbound (it would read NaN today). That makes the scalar-`p` path and
    // every existing model byte-identical: forcing only ever fills a gap, never
    // shadows a live binding. (When R-1 wires `cadence.rs` it can carry the set
    // of declared-loader-fed names and, if a name ever legitimately collides
    // with a state, promote this lookup for those names — the seam is here.)
    if let Some(a) = ctx.forcing.borrow().get(name) {
        return if a.ndim() == 0 {
            Value::Scalar(a[IxDyn(&[])])
        } else {
            Value::Array(a.clone())
        };
    }
    Value::Scalar(f64::NAN)
}

fn eval_op(node: &ExpressionNode, ctx: &mut EvalCtx) -> Value {
    match node.op.as_str() {
        // Elementwise / scalar arithmetic. If any operand is an array,
        // return an array (with ndarray broadcasting).
        "+" | "-" | "*" | "/" | "^" => eval_arith(&node.op, &node.args, ctx),

        // Unary / scalar transcendentals.
        "exp" | "log" | "ln" | "log10" | "sqrt" | "abs" | "sign" | "floor" | "ceil" | "sin"
        | "cos" | "tan" | "asin" | "acos" | "atan" | "sinh" | "cosh" | "tanh" | "asinh"
        | "acosh" | "atanh" => eval_unary(&node.op, &node.args, ctx),

        "atan2" => eval_binary(&node.op, &node.args, ctx),

        // n-ary min/max (esm-spec §4.2 — arity ≥ 2). Reuse the n-ary
        // arithmetic combiner so array operands broadcast through the same
        // ndarray path as `+`/`*`.
        "min" | "max" => eval_arith(&node.op, &node.args, ctx),

        // Scalar comparison operators — return 1.0 (true) or 0.0 (false).
        "==" | "!=" | "<" | "<=" | ">" | ">=" => {
            if node.args.len() != 2 {
                return Value::Scalar(f64::NAN);
            }
            let a = eval(&node.args[0], ctx).as_scalar().unwrap_or(f64::NAN);
            let b = eval(&node.args[1], ctx).as_scalar().unwrap_or(f64::NAN);
            Value::Scalar(match node.op.as_str() {
                "==" => {
                    if (a - b).abs() == 0.0 {
                        1.0
                    } else {
                        0.0
                    }
                }
                "!=" => {
                    if (a - b).abs() != 0.0 {
                        1.0
                    } else {
                        0.0
                    }
                }
                "<" => {
                    if a < b {
                        1.0
                    } else {
                        0.0
                    }
                }
                "<=" => {
                    if a <= b {
                        1.0
                    } else {
                        0.0
                    }
                }
                ">" => {
                    if a > b {
                        1.0
                    } else {
                        0.0
                    }
                }
                ">=" => {
                    if a >= b {
                        1.0
                    } else {
                        0.0
                    }
                }
                _ => f64::NAN,
            })
        }

        "ifelse" => {
            let c = eval(&node.args[0], ctx).as_scalar().unwrap_or(0.0);
            if c != 0.0 {
                eval(&node.args[1], ctx)
            } else {
                eval(&node.args[2], ctx)
            }
        }

        // Derivative operator: only meaningful on LHS. On RHS we treat
        // D(anything) = 0 for parity with the scalar interpreter.
        "D" => Value::Scalar(0.0),

        // Rewrite-target sugar ops must be lowered to a stencil by a `match`
        // rewrite rule before reaching the simulator (esm-spec §4.2 / §9.6.8).
        // The compile-time `check_no_spatial_ops` walk in `from_model` catches
        // these with the uniform `unlowered_operator` code; panicking here is
        // defense-in-depth in case the build path is bypassed.
        "grad" | "div" | "laplacian" => panic!(
            "unlowered_operator: rewrite-target operator '{}' reached evaluation without being \
             lowered to a stencil by a rewrite rule (esm-spec §4.2 / §9.6.8).",
            node.op
        ),

        "Pre" => eval(&node.args[0], ctx),

        // Inline literal (esm-spec §4): a number → scalar; a nested numeric
        // array → a row-major array (e.g. a polygon's `[verts, 2]` lon/lat ring
        // held as a constant observed input feeding an `intersect_polygon` clip).
        "const" => eval_const(node),

        // Array ops.
        "index" => eval_index(node, ctx),
        "aggregate" => eval_arrayop(node, ctx),
        // Conservative-regridding geometry kernel (RFC §8.1): clip two lon/lat
        // polygon rings on the node's `manifold`, producing the overlap ring as
        // an `[N, 2]` array. `polygon_area` over it is an ordinary `aggregate`.
        "intersect_polygon" => eval_intersect_polygon(node, ctx),
        // Fused geometry leaf (esm-spec §4.2 / §8.6.1): the SCALAR overlap area of
        // the two polygon operands under the node's `manifold`, defined to equal
        // `polygon_area(intersect_polygon(a, b))` but with NO clip ring exposed.
        "polygon_intersection_area" => eval_polygon_intersection_area(node, ctx),
        "makearray" => eval_makearray(node, ctx),
        "reshape" => eval_reshape(node, ctx),
        "transpose" => eval_transpose(node, ctx),
        "concat" => eval_concat(node, ctx),
        "broadcast" => eval_broadcast(node, ctx),

        _ => Value::Scalar(f64::NAN),
    }
}

fn eval_arith(op: &str, args: &[Expr], ctx: &mut EvalCtx) -> Value {
    let mut values: Vec<Value> = args.iter().map(|a| eval(a, ctx)).collect();

    // Unary minus: 1 arg.
    if op == "-" && values.len() == 1 {
        return negate(values.remove(0));
    }

    // Scalar fast path — if all operands are scalars, compute scalar.
    if values.iter().all(|v| matches!(v, Value::Scalar(_))) {
        let scalars: Vec<f64> = values
            .iter()
            .map(|v| match v {
                Value::Scalar(s) => *s,
                _ => unreachable!(),
            })
            .collect();
        return Value::Scalar(fold_scalar(op, &scalars));
    }

    // Array path: reduce left-to-right with broadcasting.
    let mut acc = values.remove(0);
    for v in values {
        acc = combine(op, acc, v);
    }
    acc
}

fn fold_scalar(op: &str, vs: &[f64]) -> f64 {
    match op {
        "+" => vs.iter().sum(),
        "*" => vs.iter().product(),
        "-" => {
            if vs.len() == 2 {
                vs[0] - vs[1]
            } else {
                f64::NAN
            }
        }
        "/" => {
            if vs.len() == 2 {
                vs[0] / vs[1]
            } else {
                f64::NAN
            }
        }
        "^" => {
            if vs.len() == 2 {
                vs[0].powf(vs[1])
            } else {
                f64::NAN
            }
        }
        "min" => {
            if vs.len() < 2 {
                f64::NAN
            } else {
                vs.iter().copied().fold(f64::INFINITY, f64::min)
            }
        }
        "max" => {
            if vs.len() < 2 {
                f64::NAN
            } else {
                vs.iter().copied().fold(f64::NEG_INFINITY, f64::max)
            }
        }
        _ => f64::NAN,
    }
}

fn negate(v: Value) -> Value {
    match v {
        Value::Scalar(s) => Value::Scalar(-s),
        Value::Array(a) => Value::Array(a.mapv(|x| -x)),
    }
}

fn combine(op: &str, a: Value, b: Value) -> Value {
    match (a, b) {
        (Value::Scalar(x), Value::Scalar(y)) => Value::Scalar(apply_binary(op, x, y)),
        (Value::Scalar(x), Value::Array(ya)) => Value::Array(ya.mapv(|y| apply_binary(op, x, y))),
        (Value::Array(xa), Value::Scalar(y)) => Value::Array(xa.mapv(|x| apply_binary(op, x, y))),
        (Value::Array(xa), Value::Array(ya)) => {
            // Use ndarray broadcasting.
            Value::Array(broadcast_binary(op, &xa, &ya))
        }
    }
}

fn apply_binary(op: &str, x: f64, y: f64) -> f64 {
    match op {
        "+" => x + y,
        "-" => x - y,
        "*" => x * y,
        "/" => x / y,
        "^" => x.powf(y),
        "atan2" => x.atan2(y),
        "min" => x.min(y),
        "max" => x.max(y),
        _ => f64::NAN,
    }
}

fn broadcast_binary(op: &str, a: &ArrayD<f64>, b: &ArrayD<f64>) -> ArrayD<f64> {
    // Julia-style left-align: pad the lower-rank operand with trailing
    // singletons before broadcasting.
    let max_rank = a.ndim().max(b.ndim());
    let a_padded = pad_trailing(a, max_rank);
    let b_padded = pad_trailing(b, max_rank);
    let target_shape = broadcast_shape(a_padded.shape(), b_padded.shape());
    let av = a_padded
        .broadcast(IxDyn(&target_shape))
        .expect("broadcast failed");
    let bv = b_padded
        .broadcast(IxDyn(&target_shape))
        .expect("broadcast failed");
    let mut out = ArrayD::<f64>::zeros(IxDyn(&target_shape));
    ndarray::Zip::from(&mut out)
        .and(&av)
        .and(&bv)
        .for_each(|o, &x, &y| {
            *o = apply_binary(op, x, y);
        });
    out
}

/// Julia-style broadcast shape alignment: pad the lower-rank shape with
/// *trailing* singleton dimensions so `(3,) + (1,3) → (3,3)`. This differs
/// from NumPy's right-alignment convention; the fixtures were authored in
/// Julia and expect this behavior (see
/// `fixtures/arrayop/14_broadcast_elementwise.esm`).
fn broadcast_shape(a: &[usize], b: &[usize]) -> Vec<usize> {
    let n = a.len().max(b.len());
    let mut out = vec![1usize; n];
    for i in 0..n {
        let ai = if i < a.len() { a[i] } else { 1 };
        let bi = if i < b.len() { b[i] } else { 1 };
        let dim = if ai == bi {
            ai
        } else if ai == 1 {
            bi
        } else if bi == 1 {
            ai
        } else {
            0
        };
        out[i] = dim;
    }
    out
}

/// Pad an ndarray with trailing singleton dimensions to reach `target_rank`.
fn pad_trailing(arr: &ArrayD<f64>, target_rank: usize) -> ArrayD<f64> {
    if arr.ndim() >= target_rank {
        return arr.clone();
    }
    let mut shape = arr.shape().to_vec();
    while shape.len() < target_rank {
        shape.push(1);
    }
    arr.clone()
        .into_shape_with_order(IxDyn(&shape))
        .expect("pad_trailing reshape")
}

fn eval_unary(op: &str, args: &[Expr], ctx: &mut EvalCtx) -> Value {
    let v = eval(&args[0], ctx);
    match v {
        Value::Scalar(s) => Value::Scalar(apply_unary(op, s)),
        Value::Array(a) => Value::Array(a.mapv(|x| apply_unary(op, x))),
    }
}

fn apply_unary(op: &str, x: f64) -> f64 {
    match op {
        "exp" => x.exp(),
        "log" | "ln" => x.ln(),
        "log10" => x.log10(),
        "sqrt" => x.sqrt(),
        "abs" => x.abs(),
        "sign" => {
            if x > 0.0 {
                1.0
            } else if x < 0.0 {
                -1.0
            } else {
                0.0
            }
        }
        "floor" => x.floor(),
        "ceil" => x.ceil(),
        "sin" => x.sin(),
        "cos" => x.cos(),
        "tan" => x.tan(),
        "asin" => x.asin(),
        "acos" => x.acos(),
        "atan" => x.atan(),
        "sinh" => x.sinh(),
        "cosh" => x.cosh(),
        "tanh" => x.tanh(),
        "asinh" => x.asinh(),
        "acosh" => x.acosh(),
        "atanh" => x.atanh(),
        _ => f64::NAN,
    }
}

fn eval_binary(op: &str, args: &[Expr], ctx: &mut EvalCtx) -> Value {
    let a = eval(&args[0], ctx);
    let b = eval(&args[1], ctx);
    combine(op, a, b)
}

// --- Array ops ---

fn eval_index(node: &ExpressionNode, ctx: &mut EvalCtx) -> Value {
    // First arg is the array-valued expression; remaining args are indices.
    if node.args.is_empty() {
        return Value::Scalar(f64::NAN);
    }
    let array_val = eval(&node.args[0], ctx);
    let arr = match array_val {
        Value::Array(a) => a,
        Value::Scalar(s) if node.args.len() == 1 => return Value::Scalar(s),
        Value::Scalar(_) => return Value::Scalar(f64::NAN),
    };
    // Evaluate index expressions into integer indices (1-based).
    // Out-of-bounds accesses return 0.0 — this implements homogeneous Dirichlet
    // ghost-cell semantics: a discretized PDE's stencil can reference u[i-1]
    // when i=1 (ghost cell at i=0) and the boundary condition is u=0.
    let mut in_bounds = true;
    let indices: Vec<usize> = node.args[1..]
        .iter()
        .enumerate()
        .map(|(d, a)| {
            let v = eval(a, ctx);
            let one_based = match v.as_scalar() {
                Some(f) => f.round() as i64,
                None => {
                    in_bounds = false;
                    return 0;
                }
            };
            let dim_size = arr.shape().get(d).copied().unwrap_or(0) as i64;
            if one_based < 1 || one_based > dim_size {
                in_bounds = false;
            }
            (one_based - 1).max(0) as usize
        })
        .collect();
    if !in_bounds {
        return Value::Scalar(0.0);
    }
    if indices.len() > arr.ndim() {
        return Value::Scalar(f64::NAN);
    }
    // Partial indexing (fewer indices than the array rank) selects a sub-array:
    // fix the leading `indices.len()` axes and keep the trailing axes free. This
    // is how a per-cell polygon ring is drawn from a `[cells, verts, coord]`
    // geometry table — `index(poly, a)` yields the `a`-th `[verts, coord]` ring
    // that `polygon_intersection_area` / `intersect_polygon` clip. A full index
    // set (`indices.len() == ndim`) yields the scalar element, as before.
    if indices.len() < arr.ndim() {
        let mut view = arr.view();
        for &ix in &indices {
            view = view.index_axis_move(ndarray::Axis(0), ix);
        }
        return Value::Array(view.to_owned());
    }
    let ix = IxDyn(&indices);
    if let Some(v) = arr.get(ix) {
        Value::Scalar(*v)
    } else {
        Value::Scalar(0.0)
    }
}

/// Evaluate a `const` op: the inline literal in the node's `value` field. A JSON
/// number yields a [`Value::Scalar`]; a nested numeric array yields a row-major
/// [`Value::Array`]. A missing, ragged, or non-numeric literal is unevaluable
/// (NaN sentinel), matching the evaluator's convention for malformed nodes.
fn eval_const(node: &ExpressionNode) -> Value {
    node.value
        .as_ref()
        .and_then(json_to_value)
        .unwrap_or(Value::Scalar(f64::NAN))
}

/// Convert an inline JSON literal to a runtime [`Value`]: a number → scalar; a
/// (possibly nested) numeric array → a row-major dynamic-rank array. `None` for
/// a non-numeric leaf or a ragged literal (a row whose length disagrees with its
/// siblings), so a malformed `const` surfaces as the NaN sentinel.
fn json_to_value(v: &serde_json::Value) -> Option<Value> {
    use serde_json::Value as J;
    match v {
        J::Number(n) => Some(Value::Scalar(n.as_f64()?)),
        J::Array(_) => {
            let mut shape: Vec<usize> = Vec::new();
            let mut flat: Vec<f64> = Vec::new();
            collect_json_array(v, 0, &mut shape, &mut flat)?;
            ArrayD::from_shape_vec(IxDyn(&shape), flat)
                .ok()
                .map(Value::Array)
        }
        _ => None,
    }
}

/// Walk a nested JSON numeric array, recording its shape (from the first branch
/// at each depth) and pushing every leaf number in row-major order. `None` on a
/// non-numeric leaf or a sub-array whose length disagrees with the recorded
/// shape at that depth (a ragged literal).
fn collect_json_array(
    v: &serde_json::Value,
    depth: usize,
    shape: &mut Vec<usize>,
    flat: &mut Vec<f64>,
) -> Option<()> {
    use serde_json::Value as J;
    match v {
        J::Array(items) => {
            if depth == shape.len() {
                shape.push(items.len());
            } else if shape[depth] != items.len() {
                return None; // ragged: this row's length disagrees with its siblings
            }
            for item in items {
                collect_json_array(item, depth + 1, shape, flat)?;
            }
            Some(())
        }
        J::Number(n) => {
            flat.push(n.as_f64()?);
            Some(())
        }
        _ => None,
    }
}

/// Evaluate the `intersect_polygon` leaf op (RFC `semiring-faq-unified-ir` §8.1):
/// clip the two polygon operands on the node's declared `manifold` and return
/// the overlap ring as an `[N, 2]` array of `(lon, lat)` rows. `N` is
/// data-dependent; a disjoint / edge-touching clip yields a `[0, 2]` array.
/// Spherical/geodesic clips dispatch to `s2geometry` via [`crate::geometry`];
/// planar clips use a pure-Rust Sutherland–Hodgman intersection.
fn eval_intersect_polygon(node: &ExpressionNode, ctx: &mut EvalCtx) -> Value {
    // Strict binary clip (schema-enforced; defense-in-depth here).
    if node.args.len() != 2 {
        return Value::Scalar(f64::NAN);
    }
    // The `manifold` flag is required and part of the op's contract (§5.8.4);
    // a missing or out-of-enum value is not evaluable.
    let manifold = match node
        .manifold
        .as_deref()
        .and_then(crate::geometry::Manifold::from_flag)
    {
        Some(m) => m,
        None => return Value::Scalar(f64::NAN),
    };
    let poly_a = match eval(&node.args[0], ctx) {
        Value::Array(a) => a,
        _ => return Value::Scalar(f64::NAN),
    };
    let poly_b = match eval(&node.args[1], ctx) {
        Value::Array(a) => a,
        _ => return Value::Scalar(f64::NAN),
    };
    let (va, vb) = match (arrayd_to_lonlat(&poly_a), arrayd_to_lonlat(&poly_b)) {
        (Some(a), Some(b)) => (a, b),
        _ => return Value::Scalar(f64::NAN),
    };
    match crate::geometry::intersect_polygon(&va, &vb, manifold) {
        Ok(ring) => {
            // Return the ring **closed** (first vertex repeated) so the
            // `polygon_area` shoelace FAQ reads the wrap edge n→1 as an ordinary
            // `index(ring, v+1, …)` with no modular arithmetic in the AST —
            // matching the Python reference (`numpy_interpreter._eval_intersect_polygon`
            // → `geometry.close_ring`). The pure kernel `crate::geometry::intersect_polygon`
            // still returns the n distinct vertices; closure is the op's contract.
            let closed = close_ring(&ring);
            let arr = lonlat_to_arrayd(&closed);
            // Self-register the closed ring under the node `id` (RFC §8.1) so a
            // downstream `aggregate` over a `kind:"derived"` index set
            // (`from_faq: <id>`) sizes its contraction from this ring's
            // distinct-vertex count (`rows − 1`); see [`derived_ring_extent`].
            if let Some(id) = &node.id {
                ctx.derived_rings
                    .borrow_mut()
                    .insert(id.clone(), arr.clone());
            }
            Value::Array(arr)
        }
        // A degenerate input ring or unavailable backend surfaces as NaN, the
        // same not-a-value sentinel the evaluator uses for unevaluable nodes.
        Err(_) => Value::Scalar(f64::NAN),
    }
}

/// Evaluate the fused `polygon_intersection_area` leaf op (esm-spec §4.2 /
/// §8.6.1): the **scalar** overlap area of the two polygon operands under the
/// node's declared `manifold`. It is defined to equal
/// `polygon_area(intersect_polygon(a, b))` at the same `manifold` — the FUSED
/// form of the existing clip + shoelace — but exposes **no** clip ring
/// (unlike [`eval_intersect_polygon`], which surfaces the ring as an `[N, 2]`
/// array and self-registers a derived index set). This reuses the same kernels:
/// [`crate::geometry::intersect_polygon`] to clip, then
/// [`crate::geometry::polygon_area`] (planar shoelace / spherical-geodesic S2)
/// to measure, so its value matches the composed form exactly. A disjoint /
/// edge-touching clip yields a `< 3`-vertex ring, whose area is `0.0`.
fn eval_polygon_intersection_area(node: &ExpressionNode, ctx: &mut EvalCtx) -> Value {
    // Strict binary clip (schema-enforced; defense-in-depth here).
    if node.args.len() != 2 {
        return Value::Scalar(f64::NAN);
    }
    // The `manifold` flag is required and part of the op's contract (§5.8.4);
    // a missing or out-of-enum value is not evaluable.
    let manifold = match node
        .manifold
        .as_deref()
        .and_then(crate::geometry::Manifold::from_flag)
    {
        Some(m) => m,
        None => return Value::Scalar(f64::NAN),
    };
    let poly_a = match eval(&node.args[0], ctx) {
        Value::Array(a) => a,
        _ => return Value::Scalar(f64::NAN),
    };
    let poly_b = match eval(&node.args[1], ctx) {
        Value::Array(a) => a,
        _ => return Value::Scalar(f64::NAN),
    };
    let (va, vb) = match (arrayd_to_lonlat(&poly_a), arrayd_to_lonlat(&poly_b)) {
        (Some(a), Some(b)) => (a, b),
        _ => return Value::Scalar(f64::NAN),
    };
    // Clip, then measure — the fused composition. The clip kernel returns the
    // `n` distinct overlap vertices; `polygon_area`'s shoelace / spherical body
    // reads the wrap edge `n→1` itself, so no explicit ring closure is needed
    // here (and no derived ring is registered — the fused leaf exposes none).
    match crate::geometry::intersect_polygon(&va, &vb, manifold)
        .and_then(|ring| crate::geometry::polygon_area(&ring, manifold))
    {
        Ok(area) => Value::Scalar(area),
        // A degenerate input ring or unavailable backend surfaces as NaN, the
        // same not-a-value sentinel the evaluator uses for unevaluable nodes.
        Err(_) => Value::Scalar(f64::NAN),
    }
}

/// Close a ring by repeating its first vertex (RFC §8.1; mirrors Python
/// `geometry.close_ring`) so a `polygon_area` shoelace FAQ reads the wrap edge
/// `n→1` as an ordinary `index(ring, v+1, …)`. An empty (disjoint-clip) ring
/// stays empty, so its derived index set has extent 0 and the FAQ reduces to 0̄.
fn close_ring(ring: &[(f64, f64)]) -> Vec<(f64, f64)> {
    if ring.is_empty() {
        return Vec::new();
    }
    let mut out = Vec::with_capacity(ring.len() + 1);
    out.extend_from_slice(ring);
    out.push(ring[0]);
    out
}

/// Read a `[V, 2]` lon/lat coordinate array into a `Vec<(lon, lat)>`. Returns
/// `None` unless the array is 2-D with a trailing coordinate axis of length 2.
fn arrayd_to_lonlat(arr: &ArrayD<f64>) -> Option<Vec<(f64, f64)>> {
    if arr.ndim() != 2 || arr.shape()[1] != 2 {
        return None;
    }
    let nv = arr.shape()[0];
    let mut out = Vec::with_capacity(nv);
    for v in 0..nv {
        out.push((arr[IxDyn(&[v, 0])], arr[IxDyn(&[v, 1])]));
    }
    Some(out)
}

/// Build a row-major `[N, 2]` lon/lat array from a ring of `(lon, lat)` pairs.
/// An empty ring yields a `[0, 2]` array so downstream `index(clip, v, c)` reads
/// return the 0 ghost value and a `sum_product` FAQ over the empty `clip_ring`
/// range reduces to the additive identity `0̄`.
fn lonlat_to_arrayd(ring: &[(f64, f64)]) -> ArrayD<f64> {
    let n = ring.len();
    let mut flat = Vec::with_capacity(n * 2);
    for &(lon, lat) in ring {
        flat.push(lon);
        flat.push(lat);
    }
    ArrayD::from_shape_vec(IxDyn(&[n, 2]), flat).expect("ring [N,2] shape is consistent")
}

/// Evaluate a standalone expression against a set of named array inputs, reusing
/// the array evaluator — in particular the M1 `aggregate` machinery in
/// [`eval_arrayop`]. This is the entry point for computing a `polygon_area`
/// `sum_product` FAQ over an `intersect_polygon` ring (RFC §8.1): supply the
/// clipped ring (and any companion arrays the integrand references) in `inputs`
/// with the aggregate's `clip_ring` range already resolved to a concrete
/// `[1, N]` interval, and the body is reduced exactly as any other `aggregate`.
///
/// Returns [`Value::Scalar`] for a scalar FAQ output (`output_idx: []`),
/// [`Value::Array`] otherwise.
pub fn eval_expression(
    expr: &Expr,
    inputs: &HashMap<String, ArrayD<f64>>,
    params: &[f64],
    param_names: &[String],
    t: f64,
) -> Value {
    let empty: HashMap<String, ArrayD<f64>> = HashMap::new();
    let derived_rings: RefCell<HashMap<String, ArrayD<f64>>> = RefCell::new(HashMap::new());
    // Standalone expression evaluation (FAQ rings, area integrands) carries no
    // loader forcing — an empty buffer keeps the channel byte-identical here.
    let forcing: RefCell<HashMap<String, ArrayD<f64>>> = RefCell::new(HashMap::new());
    let mut ctx = EvalCtx {
        state_arrays: &empty,
        observed_arrays: inputs,
        params,
        param_names,
        loop_binds: HashMap::new(),
        t,
        derived_rings: &derived_rings,
        forcing: &forcing,
    };
    eval(expr, &mut ctx)
}

/// Evaluate an `aggregate`/`arrayop` `filter` predicate under the current loop
/// binds and report whether the combination is **excluded** (§5.3): excluded
/// iff a filter is present and evaluates to false (a zero scalar). With no
/// filter this is always `false`, so the reduction is byte-identical to the
/// no-filter form.
fn filter_excludes(filter: Option<&Expr>, ctx: &mut EvalCtx) -> bool {
    match filter {
        Some(f) => eval(f, ctx).as_scalar().unwrap_or(0.0) == 0.0,
        None => false,
    }
}

/// Evaluate one output cell's value: the pointwise body when there are no
/// contracted indices, otherwise the semiring ⊕-reduction of the body over the
/// Cartesian product of the contracted dims. Each dim is resolved to its
/// concrete bound *under the current output tuple*, so a [`ContractDim::Ragged`]
/// dim uses this cell's dynamic per-parent extent (an empty extent reduces to
/// the additive identity 0̄). `ctx.loop_binds` must already hold the output-index
/// tuple; the contracted indices are bound here. This is the single contraction
/// kernel shared by the standalone-aggregate ([`eval_arrayop`]) and compiled
/// array-op-derivative ([`RhsRule::ArrayLoop`]) paths, mirroring the Julia
/// `_expand_int_range_dyn` einsum loop and the Python `_expand_ragged` gather.
fn reduce_contraction(
    contract_names: &[String],
    contract_dims: &[ContractDim],
    body: &Expr,
    reduce: ReduceKind,
    filter: Option<&Expr>,
    ctx: &mut EvalCtx,
) -> f64 {
    if contract_names.is_empty() {
        // Pointwise: a filtered-out cell contributes the additive identity 0̄.
        return if filter_excludes(filter, ctx) {
            reduce.identity()
        } else {
            eval(body, ctx).as_scalar().unwrap_or(f64::NAN)
        };
    }
    // Resolve each contracted dim to a concrete (lo, hi) under the current
    // output tuple — ragged dims read their per-parent length here.
    let ranges: Vec<(i64, i64)> = contract_dims.iter().map(|d| d.concrete(ctx)).collect();
    let mut acc: f64 = reduce.identity();
    for k_tuple in cartesian_range(&ranges) {
        for (kn, kv) in contract_names.iter().zip(k_tuple.iter()) {
            ctx.loop_binds.insert(kn.clone(), *kv);
        }
        // A filtered-out combination contributes 0̄ (acc ⊕ 0̄ = acc) (§5.3).
        if filter_excludes(filter, ctx) {
            continue;
        }
        let term = eval(body, ctx).as_scalar().unwrap_or(f64::NAN);
        acc = reduce.combine(acc, term);
    }
    acc
}

/// Gather the ragged per-parent length `offsets[of…]` for the current output
/// tuple: read each parent index variable from `ctx.loop_binds`, address the
/// `offsets` factor array (1-based → 0-based), and round to an integer count.
/// A scalar/0-D `offsets` factor is a constant valence for every parent. A
/// missing/unbound parent, a rank mismatch, or an out-of-bounds gather yields
/// `0` — an empty reduction (the additive identity 0̄), matching the evaluator's
/// homogeneous-ghost convention for out-of-bounds reads.
fn ragged_upper_bound(offsets: &str, of: &[String], ctx: &EvalCtx) -> i64 {
    let arr = match lookup_variable(offsets, ctx) {
        Value::Scalar(s) => return s.round() as i64,
        Value::Array(a) => a,
    };
    if of.len() != arr.ndim() {
        return 0;
    }
    let mut idx = Vec::with_capacity(of.len());
    for p in of {
        match ctx.loop_binds.get(p) {
            Some(pv) if *pv >= 1 => idx.push((*pv - 1) as usize),
            _ => return 0,
        }
    }
    arr.get(IxDyn(&idx)).map(|v| v.round() as i64).unwrap_or(0)
}

fn eval_arrayop(node: &ExpressionNode, ctx: &mut EvalCtx) -> Value {
    // Standalone arrayop (embedded as an expression, not as the top-level
    // of an equation LHS/RHS). Build the output array by iterating
    // ranges, binding loop indices, evaluating the body.
    //
    // Supports generalized einsum: indices present in `ranges` but absent
    // from `output_idx` are contracted (summed/reduced) per `reduce`.
    let idx_names = node.output_idx.clone().unwrap_or_default();
    let ranges_map = node.ranges.clone().unwrap_or_default();
    let body = match &node.expr {
        Some(b) => b.as_ref().clone(),
        None => return Value::Scalar(f64::NAN),
    };
    let ranges: Vec<(i64, i64)> = idx_names
        .iter()
        .map(|n| {
            let r = ranges_map.get(n).and_then(|s| s.bounds()).unwrap_or([0, 0]);
            (r[0], r[1])
        })
        .collect();

    // Contracted indices: in ranges_map but not in output_idx.
    let output_idx_set: std::collections::HashSet<&String> = idx_names.iter().collect();
    let mut sorted_contract_keys: Vec<&String> = ranges_map
        .keys()
        .filter(|k| !output_idx_set.contains(k))
        .collect();
    sorted_contract_keys.sort();
    let contract_names: Vec<String> = sorted_contract_keys.iter().map(|k| (*k).clone()).collect();
    let contract_dims: Vec<ContractDim> = sorted_contract_keys
        .iter()
        .map(|k| ContractDim::from_range(&ranges_map[*k]))
        .collect();
    let reduce = effective_reduce_kind(node.semiring.as_deref(), node.reduce.as_deref());
    // §5.3 filter: a boolean predicate gating which index combinations
    // contribute a ⊗-term. Absent ⇒ every combination contributes (byte-
    // identical to the no-filter form).
    let filter = node.filter.as_deref();

    let shape: Vec<usize> = ranges
        .iter()
        .map(|(lo, hi)| (hi - lo + 1) as usize)
        .collect();
    let origin: Vec<i64> = ranges.iter().map(|(lo, _)| *lo).collect();
    let total = shape.iter().copied().product::<usize>().max(1);
    let mut buf = vec![0.0f64; total];
    let saved_binds: Vec<(String, Option<i64>)> = idx_names
        .iter()
        .chain(contract_names.iter())
        .map(|n| (n.clone(), ctx.loop_binds.get(n).copied()))
        .collect();
    for tuple in cartesian_range(&ranges) {
        for (name, val) in idx_names.iter().zip(tuple.iter()) {
            ctx.loop_binds.insert(name.clone(), *val);
        }
        let v = reduce_contraction(&contract_names, &contract_dims, &body, reduce, filter, ctx);
        let flat = multi_to_flat_col_major(&tuple, &shape, &origin);
        buf[flat] = v;
    }
    for (name, saved) in saved_binds {
        match saved {
            Some(v) => {
                ctx.loop_binds.insert(name, v);
            }
            None => {
                ctx.loop_binds.remove(&name);
            }
        }
    }
    if shape.is_empty() {
        Value::Scalar(buf[0])
    } else {
        Value::Array(col_major_to_arrayd(&buf, &shape))
    }
}

fn eval_makearray(node: &ExpressionNode, ctx: &mut EvalCtx) -> Value {
    let regions = node.regions.clone().unwrap_or_default();
    let values = node.values.clone().unwrap_or_default();
    if regions.is_empty() || values.len() != regions.len() {
        return Value::Scalar(f64::NAN);
    }
    // Compute the bounding box.
    let ndim = regions[0].len();
    let mut lo = vec![i64::MAX; ndim];
    let mut hi = vec![i64::MIN; ndim];
    for region in &regions {
        for (d, r) in region.iter().enumerate() {
            lo[d] = lo[d].min(r[0]);
            hi[d] = hi[d].max(r[1]);
        }
    }
    let shape: Vec<usize> = (0..ndim).map(|d| (hi[d] - lo[d] + 1) as usize).collect();
    let origin = lo.clone();
    let mut arr = ArrayD::<f64>::zeros(IxDyn(&shape));
    for (region, value_expr) in regions.iter().zip(values.iter()) {
        let v = eval(value_expr, ctx);
        // Iterate the region's index tuples.
        let ranges: Vec<(i64, i64)> = region.iter().map(|r| (r[0], r[1])).collect();
        // A region-aligned ARRAY value (e.g. a lowered stencil's interior
        // aggregate) must span the region box exactly; each region cell then
        // reads its aligned element (mirrors the vectorized
        // `eval_vec_makearray` region-assign and the Julia/Python region
        // semantics). A shape mismatch keeps the previous skip behaviour.
        if let Value::Array(a) = &v
            && a.ndim() > 0
        {
            let region_shape: Vec<usize> = ranges
                .iter()
                .map(|(lo, hi)| (hi - lo + 1) as usize)
                .collect();
            if a.shape() == region_shape.as_slice() {
                for tuple in cartesian_range(&ranges) {
                    let out_ix: Vec<usize> = tuple
                        .iter()
                        .enumerate()
                        .map(|(d, x)| (x - origin[d]) as usize)
                        .collect();
                    let src_ix: Vec<usize> = tuple
                        .iter()
                        .enumerate()
                        .map(|(d, x)| (x - ranges[d].0) as usize)
                        .collect();
                    arr[IxDyn(&out_ix)] = a[IxDyn(&src_ix)];
                }
            }
            continue;
        }
        for tuple in cartesian_range(&ranges) {
            let indices: Vec<usize> = tuple
                .iter()
                .enumerate()
                .map(|(d, x)| (x - origin[d]) as usize)
                .collect();
            let ix = IxDyn(&indices);
            let scalar = match &v {
                Value::Scalar(s) => *s,
                Value::Array(a) if a.ndim() == 0 => a[IxDyn(&[])],
                _ => continue,
            };
            arr[ix] = scalar;
        }
    }
    Value::Array(arr)
}

fn eval_reshape(node: &ExpressionNode, ctx: &mut EvalCtx) -> Value {
    let v = eval(&node.args[0], ctx);
    let arr = match v {
        Value::Array(a) => a,
        Value::Scalar(s) => ArrayD::from_elem(IxDyn(&[]), s),
    };
    let target: Vec<usize> = node
        .shape
        .clone()
        .unwrap_or_default()
        .iter()
        .map(|&d| d as usize)
        .collect();
    // Column-major reshape: flatten in column-major order, reinterpret
    // under the new shape in column-major order.
    let flat = arrayd_to_col_major(&arr);
    Value::Array(col_major_to_arrayd(&flat, &target))
}

fn eval_transpose(node: &ExpressionNode, ctx: &mut EvalCtx) -> Value {
    let v = eval(&node.args[0], ctx);
    let arr = match v {
        Value::Array(a) => a,
        Value::Scalar(s) => return Value::Scalar(s),
    };
    let perm: Vec<usize> = if let Some(p) = &node.perm {
        p.iter().map(|&x| x as usize).collect()
    } else {
        // Default: reverse axes.
        (0..arr.ndim()).rev().collect()
    };
    Value::Array(arr.permuted_axes(perm).as_standard_layout().into_owned())
}

fn eval_concat(node: &ExpressionNode, ctx: &mut EvalCtx) -> Value {
    let axis = node.axis.unwrap_or(0) as usize;
    let parts: Vec<ArrayD<f64>> = node
        .args
        .iter()
        .map(|a| match eval(a, ctx) {
            Value::Array(arr) => arr,
            Value::Scalar(s) => ArrayD::from_elem(IxDyn(&[1]), s),
        })
        .collect();
    let views: Vec<_> = parts.iter().map(|a| a.view()).collect();
    let joined = ndarray::concatenate(ndarray::Axis(axis), &views)
        .unwrap_or_else(|_| ArrayD::zeros(IxDyn(&[0])));
    Value::Array(joined)
}

fn eval_broadcast(node: &ExpressionNode, ctx: &mut EvalCtx) -> Value {
    let fn_name = node.broadcast_fn.clone().unwrap_or_else(|| "+".to_string());
    let vs: Vec<Value> = node.args.iter().map(|a| eval(a, ctx)).collect();
    if vs.is_empty() {
        return Value::Scalar(f64::NAN);
    }
    let mut acc = vs.into_iter();
    let first = acc.next().unwrap();
    let mut out = first;
    for next in acc {
        out = combine(&fn_name, out, next);
    }
    out
}

// ============================================================================
// Shape inference + LHS parsing helpers.
// ============================================================================

/// The variable a top-level equation defines, if any: `v = …`, `index(v, …) = …`,
/// `D(v) = …` / `D(index(v, …)) = …`, `ic(v) = …`, or an `arrayop`/`aggregate`
/// whose body is `D(index(v, …))` / `index(v, …)`. Used to prune value-invention
/// equations and to classify algebraic definitions.
fn equation_defined_var(lhs: &Expr) -> Option<String> {
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
fn algebraic_defined_var(lhs: &Expr) -> Option<String> {
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
fn collect_algebraic_defined(equations: &[crate::types::Equation]) -> HashSet<String> {
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
fn expr_contains_skolem(expr: &Expr) -> bool {
    match expr {
        Expr::Number(_) | Expr::Integer(_) | Expr::Variable(_) => false,
        Expr::Operator(node) => {
            if node.op == "skolem" {
                return true;
            }
            node.args.iter().any(expr_contains_skolem)
                || node.expr.as_deref().is_some_and(expr_contains_skolem)
                || node.filter.as_deref().is_some_and(expr_contains_skolem)
                || node.lower.as_deref().is_some_and(expr_contains_skolem)
                || node.upper.as_deref().is_some_and(expr_contains_skolem)
                || node
                    .values
                    .as_ref()
                    .is_some_and(|vs| vs.iter().any(expr_contains_skolem))
                || node
                    .axes
                    .as_ref()
                    .is_some_and(|ax| ax.values().any(expr_contains_skolem))
        }
    }
}

/// Collect the `id`s of every geometry ring producer (`intersect_polygon` /
/// `polygon_intersection_area`) reachable from `expr`. A `kind: "derived"` index
/// set whose `from_faq` names one of these is the materialized clip ring (kept),
/// distinguishing it from a relational membership set (dropped).
fn collect_geometry_producer_ids(expr: &Expr, out: &mut HashSet<String>) {
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
    for a in &node.args {
        collect_geometry_producer_ids(a, out);
    }
    if let Some(b) = &node.expr {
        collect_geometry_producer_ids(b, out);
    }
    if let Some(f) = &node.filter {
        collect_geometry_producer_ids(f, out);
    }
    if let Some(vals) = &node.values {
        for v in vals {
            collect_geometry_producer_ids(v, out);
        }
    }
    if let Some(axes) = &node.axes {
        for v in axes.values() {
            collect_geometry_producer_ids(v, out);
        }
    }
}

/// Strip every `join.on` key-pair that references a dropped value-invention
/// variable, dropping a clause whose pairs all vanish and clearing an empty
/// `join`. A bin-skolem broad-phase gate keyed on such a column cannot be
/// evaluated by the dense array runtime (the integer-id buffer is not
/// materialized); eliding it degrades the aggregate to the dense contraction
/// over all index combinations — the pruned combinations contribute the
/// additive identity, which for a geometric narrow phase (`polygon_intersection_area`,
/// zero on non-overlapping pairs) they already do, so the result is unchanged.
fn strip_vi_joins(expr: &mut Expr, vi_cols: &HashSet<String>) {
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
    for a in &mut node.args {
        strip_vi_joins(a, vi_cols);
    }
    if let Some(b) = &mut node.expr {
        strip_vi_joins(b, vi_cols);
    }
    if let Some(f) = &mut node.filter {
        strip_vi_joins(f, vi_cols);
    }
    if let Some(l) = &mut node.lower {
        strip_vi_joins(l, vi_cols);
    }
    if let Some(u) = &mut node.upper {
        strip_vi_joins(u, vi_cols);
    }
    if let Some(vals) = &mut node.values {
        for v in vals {
            strip_vi_joins(v, vi_cols);
        }
    }
    if let Some(axes) = &mut node.axes {
        for v in axes.values_mut() {
            strip_vi_joins(v, vi_cols);
        }
    }
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
fn strip_value_invention(
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

/// Resolve a declared `shape` (index-set names) to concrete dense sizes against
/// the document registry: an `interval` set contributes its `size`, a
/// `categorical` set its member count. Returns `None` if any entry is a set the
/// registry cannot densely size (derived / ragged / unknown).
fn resolve_declared_shape(
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
fn is_array_producer(node: &ExpressionNode) -> bool {
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
fn rhs_has_array_producer(expr: &Expr) -> bool {
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
fn rename_free_symbol(expr: &Expr, from: &str, to: &str) -> Expr {
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
            let mut out = node.clone();
            out.args = node
                .args
                .iter()
                .map(|a| rename_free_symbol(a, from, to))
                .collect();
            out.expr = node
                .expr
                .as_ref()
                .map(|e| Box::new(rename_free_symbol(e, from, to)));
            out.filter = node
                .filter
                .as_ref()
                .map(|e| Box::new(rename_free_symbol(e, from, to)));
            out.lower = node
                .lower
                .as_ref()
                .map(|e| Box::new(rename_free_symbol(e, from, to)));
            out.upper = node
                .upper
                .as_ref()
                .map(|e| Box::new(rename_free_symbol(e, from, to)));
            out.values = node
                .values
                .as_ref()
                .map(|vs| vs.iter().map(|v| rename_free_symbol(v, from, to)).collect());
            if let Some(axes) = &node.axes {
                out.axes = Some(
                    axes.iter()
                        .map(|(k, v)| (k.clone(), rename_free_symbol(v, from, to)))
                        .collect(),
                );
            }
            Expr::Operator(out)
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
fn inline_region_aggregates(node: &ExpressionNode, loops: &[String]) -> ExpressionNode {
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
fn index_array_leaves_by_loops(
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
fn index_array_leaves(expr: &Expr, array_ranks: &HashMap<String, usize>, cell: &[i64]) -> Expr {
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
            let mut out = node.clone();
            if node.op == "index" {
                // Keep the (already array-valued) target; rewrite only the index
                // argument expressions.
                out.args = node
                    .args
                    .iter()
                    .enumerate()
                    .map(|(i, a)| {
                        if i == 0 {
                            a.clone()
                        } else {
                            index_array_leaves(a, array_ranks, cell)
                        }
                    })
                    .collect();
            } else {
                out.args = node
                    .args
                    .iter()
                    .map(|a| index_array_leaves(a, array_ranks, cell))
                    .collect();
            }
            out.expr = node
                .expr
                .as_ref()
                .map(|e| Box::new(index_array_leaves(e, array_ranks, cell)));
            out.filter = node
                .filter
                .as_ref()
                .map(|e| Box::new(index_array_leaves(e, array_ranks, cell)));
            out.values = node.values.as_ref().map(|vs| {
                vs.iter()
                    .map(|v| index_array_leaves(v, array_ranks, cell))
                    .collect()
            });
            Expr::Operator(out)
        }
        other => other.clone(),
    }
}

/// Collect every state variable that receives a `D(..., t) = ...` definition
/// somewhere in the equation list.
fn collect_derivative_targets(equations: &[crate::types::Equation]) -> HashSet<String> {
    let mut out = HashSet::new();
    for eq in equations {
        if let Some((name, _)) = extract_derivative_scalar(&eq.lhs) {
            out.insert(name);
        }
        if let Some((name, _, _, _, _, _, _, _, _)) = extract_derivative_arrayop(&eq.lhs, &eq.rhs) {
            out.insert(name);
        }
    }
    out
}

/// If `lhs` is `D(var, t)` or `D(index(var, i1, ...), t)`, return
/// `(var_name, Some(indices))` for the indexed form (with all concrete
/// integer indices), `(var_name, None)` for the plain form. `None` result
/// means this LHS is neither.
fn extract_derivative_scalar(lhs: &Expr) -> Option<(String, Option<Vec<i64>>)> {
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
fn extract_derivative_arrayop(
    lhs: &Expr,
    rhs: &Expr,
) -> Option<(
    String,
    Vec<String>,
    Vec<(i64, i64)>,
    Vec<Expr>,
    Expr,
    Vec<String>,
    Vec<ContractDim>,
    ReduceKind,
    Option<Box<Expr>>,
)> {
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
    Some((
        var_name,
        idx_names,
        ranges,
        lhs_idx_exprs,
        rhs_body,
        contract_names,
        contract_dims,
        reduce,
        filter,
    ))
}

/// Extract an algebraic `arrayop(expr=index(var, idx...)) = arrayop(...)`
/// definition. Matches fixtures 02 and 04 where an algebraic variable is
/// defined through an arrayop whose body is just `index(v, i...)`.
fn extract_algebraic_arrayop(
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
fn infer_shapes(
    state_vars: &[&String],
    equations: &[crate::types::Equation],
) -> Result<HashMap<String, Vec<usize>>, CompileError> {
    let state_set: HashSet<&str> = state_vars.iter().map(|s| s.as_str()).collect();

    // Pass 1: LHS only — these are the authoritative (pinned) shapes.
    let mut per_var_min: HashMap<String, Vec<i64>> = HashMap::new();
    let mut per_var_max: HashMap<String, Vec<i64>> = HashMap::new();
    let mut seen_indexed: HashSet<String> = HashSet::new();
    let skip_none: HashSet<String> = HashSet::new();
    for eq in equations {
        walk_for_shapes(
            &eq.lhs,
            &state_set,
            &mut per_var_min,
            &mut per_var_max,
            &mut seen_indexed,
            &HashMap::new(),
            &skip_none,
        );
    }

    // Pass 2: RHS — skip variables already pinned by LHS to prevent stencil
    // offsets (e.g. index(u, i-1)) from expanding the state's extent.
    let lhs_pinned = seen_indexed.clone();
    for eq in equations {
        walk_for_shapes(
            &eq.rhs,
            &state_set,
            &mut per_var_min,
            &mut per_var_max,
            &mut seen_indexed,
            &HashMap::new(),
            &lhs_pinned,
        );
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

/// Walk an expression tree collecting per-variable index bounds for shape
/// inference. `skip_shape_update` lists variables whose shapes are already
/// pinned (by a prior LHS pass); their bounds are not updated here, though
/// they are still marked as seen.
fn walk_for_shapes(
    expr: &Expr,
    states: &HashSet<&str>,
    per_var_min: &mut HashMap<String, Vec<i64>>,
    per_var_max: &mut HashMap<String, Vec<i64>>,
    seen_indexed: &mut HashSet<String>,
    loop_ranges: &HashMap<String, (i64, i64)>,
    skip_shape_update: &HashSet<String>,
) {
    match expr {
        Expr::Number(_) | Expr::Integer(_) | Expr::Variable(_) => {}
        Expr::Operator(node) => {
            if node.op == "index" {
                if let Some(Expr::Variable(var)) = node.args.first()
                    && states.contains(var.as_str())
                {
                    seen_indexed.insert(var.clone());
                    if !skip_shape_update.contains(var) {
                        let mut dim_min: Vec<i64> = Vec::new();
                        let mut dim_max: Vec<i64> = Vec::new();
                        for idx_expr in node.args.iter().skip(1) {
                            let (lo, hi) = evaluate_index_range(idx_expr, loop_ranges);
                            dim_min.push(lo);
                            dim_max.push(hi);
                        }
                        let cur_min = per_var_min.entry(var.clone()).or_default();
                        let cur_max = per_var_max.entry(var.clone()).or_default();
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
                if let Some(inner_expr) = &node.expr {
                    walk_for_shapes(
                        inner_expr,
                        states,
                        per_var_min,
                        per_var_max,
                        seen_indexed,
                        &inner,
                        skip_shape_update,
                    );
                }
                for a in &node.args {
                    walk_for_shapes(
                        a,
                        states,
                        per_var_min,
                        per_var_max,
                        seen_indexed,
                        &inner,
                        skip_shape_update,
                    );
                }
                if let Some(vs) = &node.values {
                    for v in vs {
                        walk_for_shapes(
                            v,
                            states,
                            per_var_min,
                            per_var_max,
                            seen_indexed,
                            &inner,
                            skip_shape_update,
                        );
                    }
                }
                return;
            }
            if let Some(inner) = &node.expr {
                walk_for_shapes(
                    inner,
                    states,
                    per_var_min,
                    per_var_max,
                    seen_indexed,
                    loop_ranges,
                    skip_shape_update,
                );
            }
            if let Some(vs) = &node.values {
                for v in vs {
                    walk_for_shapes(
                        v,
                        states,
                        per_var_min,
                        per_var_max,
                        seen_indexed,
                        loop_ranges,
                        skip_shape_update,
                    );
                }
            }
            for a in &node.args {
                walk_for_shapes(
                    a,
                    states,
                    per_var_min,
                    per_var_max,
                    seen_indexed,
                    loop_ranges,
                    skip_shape_update,
                );
            }
        }
    }
}

/// Evaluate a simple index expression given concrete loop variable bindings.
/// Supports integer literals, bare variable lookups, and `a + b` / `a - b`.
fn eval_simple_index(expr: &Expr, binds: &HashMap<String, i64>) -> i64 {
    match expr {
        Expr::Integer(n) => *n,
        Expr::Number(n) => *n as i64,
        Expr::Variable(name) => binds.get(name).copied().unwrap_or(0),
        Expr::Operator(node) if (node.op == "+" || node.op == "-") && node.args.len() == 2 => {
            let a = eval_simple_index(&node.args[0], binds);
            let b = eval_simple_index(&node.args[1], binds);
            if node.op == "+" { a + b } else { a - b }
        }
        _ => 0,
    }
}

/// Evaluate the integer range of an index expression given the currently
/// active loop variable ranges. Supports: integer literals, a bare symbol
/// bound to a loop, and `(i + k)` / `(i - k)` / `(k + i)` arithmetic.
fn evaluate_index_range(expr: &Expr, loop_ranges: &HashMap<String, (i64, i64)>) -> (i64, i64) {
    match expr {
        Expr::Integer(n) => (*n, *n),
        Expr::Number(n) => {
            let v = *n as i64;
            (v, v)
        }
        Expr::Variable(name) => {
            if let Some((lo, hi)) = loop_ranges.get(name) {
                (*lo, *hi)
            } else {
                (0, 0)
            }
        }
        Expr::Operator(node) => match node.op.as_str() {
            "+" | "-" => {
                if node.args.len() != 2 {
                    return (0, 0);
                }
                let a = evaluate_index_range(&node.args[0], loop_ranges);
                let b = evaluate_index_range(&node.args[1], loop_ranges);
                if node.op == "+" {
                    (a.0 + b.0, a.1 + b.1)
                } else {
                    (a.0 - b.1, a.1 - b.0)
                }
            }
            _ => (0, 0),
        },
    }
}

// ============================================================================
// Layout helpers (column-major).
// ============================================================================

fn multi_to_flat_col_major(multi: &[i64], shape: &[usize], origin: &[i64]) -> usize {
    if shape.is_empty() {
        return 0;
    }
    let mut flat: usize = 0;
    let mut stride: usize = 1;
    for d in 0..shape.len() {
        let off = (multi[d] - origin[d]).max(0) as usize;
        flat += off * stride;
        stride *= shape[d];
    }
    flat
}

fn flat_to_multi_col_major(flat: usize, shape: &[usize]) -> Vec<usize> {
    let mut out = vec![0usize; shape.len()];
    let mut rem = flat;
    for d in 0..shape.len() {
        out[d] = rem % shape[d];
        rem /= shape[d];
    }
    out
}

/// Build a column-major ndarray from a flat slice. ndarray uses row-major
/// strides natively, so we construct via `from_shape_vec` with a reversed
/// shape and then `permuted_axes` to get the column-major view.
fn col_major_to_arrayd(flat: &[f64], shape: &[usize]) -> ArrayD<f64> {
    if shape.is_empty() {
        return ArrayD::from_elem(IxDyn(&[]), flat[0]);
    }
    // Build row-major array with reversed shape, then reverse axes. The
    // element order in `flat` is column-major, which equals row-major of
    // the reversed-shape array.
    let rev_shape: Vec<usize> = shape.iter().rev().copied().collect();
    let arr = ArrayD::from_shape_vec(IxDyn(&rev_shape), flat.to_vec())
        .expect("col_major_to_arrayd shape mismatch");
    let perm: Vec<usize> = (0..shape.len()).rev().collect();
    arr.permuted_axes(perm).as_standard_layout().into_owned()
}

/// Flatten an ndarray into column-major order.
fn arrayd_to_col_major(arr: &ArrayD<f64>) -> Vec<f64> {
    if arr.ndim() == 0 {
        return vec![arr[IxDyn(&[])]];
    }
    let shape: Vec<usize> = arr.shape().to_vec();
    let total: usize = shape.iter().product();
    let mut out = vec![0.0f64; total];
    for flat in 0..total {
        let multi = flat_to_multi_col_major(flat, &shape);
        out[flat] = arr[IxDyn(&multi)];
    }
    out
}

/// Generate every index tuple in the Cartesian product of the given
/// (lo, hi) inclusive ranges. Ordering is lexicographic on dim0 outermost.
fn cartesian_range(ranges: &[(i64, i64)]) -> Vec<Vec<i64>> {
    let mut out = vec![Vec::new()];
    for &(lo, hi) in ranges {
        let mut next: Vec<Vec<i64>> = Vec::new();
        for partial in &out {
            for v in lo..=hi {
                let mut p = partial.clone();
                p.push(v);
                next.push(p);
            }
        }
        out = next;
    }
    out
}

// ============================================================================
// Solver loop (duplicated from simulate.rs — small enough to inline).
// ============================================================================

fn run_solver<'a, S, Eqn>(
    solver: &mut S,
    t_end: f64,
    opts: &SimulateOptions,
) -> Result<(Vec<f64>, Vec<Vec<f64>>), SimulateError>
where
    S: OdeSolverMethod<'a, Eqn>,
    Eqn: diffsol::OdeEquations<T = f64, V = diffsol::FaerVec<f64>>,
    Eqn: 'a,
{
    use diffsol::OdeSolverStopReason;

    let t0 = solver.state().t;
    let n_states = solver.state().y.as_slice().len();
    let initial_state: Vec<f64> = solver.state().y.as_slice().to_vec();

    let mut times: Vec<f64> = Vec::new();
    let mut state_rows: Vec<Vec<f64>> = vec![Vec::new(); n_states];

    let push_state = |times: &mut Vec<f64>, state_rows: &mut [Vec<f64>], t: f64, y: &[f64]| {
        times.push(t);
        for (i, &v) in y.iter().enumerate() {
            state_rows[i].push(v);
        }
    };

    solver
        .set_stop_time(t_end)
        .map_err(|e| SimulateError::DiffsolError {
            details: e.to_string(),
        })?;

    let mut step_count: usize = 0;

    if let Some(t_eval) = &opts.output_times {
        let mut next_idx: usize = 0;
        while next_idx < t_eval.len() && t_eval[next_idx] <= t0 {
            push_state(
                &mut times,
                &mut state_rows,
                t_eval[next_idx],
                &initial_state,
            );
            next_idx += 1;
        }
        let mut t_prev = t0;
        loop {
            if next_idx >= t_eval.len() {
                break;
            }
            if step_count >= opts.max_steps {
                return Err(SimulateError::MaxStepsExceeded {
                    max_steps: opts.max_steps,
                });
            }
            let stop = solver.step().map_err(|e| SimulateError::DiffsolError {
                details: e.to_string(),
            })?;
            step_count += 1;
            let t_curr = solver.state().t;
            while next_idx < t_eval.len() && t_eval[next_idx] <= t_curr {
                let t = t_eval[next_idx];
                let y = solver
                    .interpolate(t)
                    .map_err(|e| SimulateError::DiffsolError {
                        details: e.to_string(),
                    })?;
                let y_s = y.as_slice();
                push_state(&mut times, &mut state_rows, t, y_s);
                next_idx += 1;
            }
            t_prev = t_curr;
            if matches!(stop, OdeSolverStopReason::TstopReached) {
                break;
            }
        }
        while next_idx < t_eval.len() {
            let t = t_eval[next_idx];
            let y = solver
                .interpolate(t)
                .map_err(|e| SimulateError::DiffsolError {
                    details: e.to_string(),
                })?;
            push_state(&mut times, &mut state_rows, t, y.as_slice());
            next_idx += 1;
        }
        let _ = t_prev;
    } else {
        push_state(&mut times, &mut state_rows, t0, &initial_state);
        loop {
            if step_count >= opts.max_steps {
                return Err(SimulateError::MaxStepsExceeded {
                    max_steps: opts.max_steps,
                });
            }
            let stop = solver.step().map_err(|e| SimulateError::DiffsolError {
                details: e.to_string(),
            })?;
            step_count += 1;
            let t_curr = solver.state().t;
            let y_owned: Vec<f64> = solver.state().y.as_slice().to_vec();
            push_state(&mut times, &mut state_rows, t_curr, &y_owned);
            if matches!(stop, OdeSolverStopReason::TstopReached) {
                break;
            }
        }
    }

    Ok((times, state_rows))
}

#[cfg(test)]
mod geometry_eval_tests {
    //! End-to-end evaluation of the M4 geometry kernel through the *real* array
    //! evaluator (bead ess-my4.4.11; RFC `semiring-faq-unified-ir` §8.1): the
    //! `intersect_polygon` leaf is dispatched by [`eval_op`] (spherical →
    //! s2geometry via the `s2bindings` crate, planar → Sutherland–Hodgman), and
    //! `polygon_area` is computed as an ordinary `sum_product` aggregate over the
    //! clipped ring, reduced by the M1 machinery in [`eval_arrayop`]. This is the
    //! Rust binding actually clipping and integrating, not just schema-validating.
    use super::*;
    use serde_json::json;

    /// Build an `[N, 2]` lon/lat array from a ring of `(lon, lat)` pairs.
    fn ring_array(ring: &[(f64, f64)]) -> ArrayD<f64> {
        let mut flat = Vec::with_capacity(ring.len() * 2);
        for &(lon, lat) in ring {
            flat.push(lon);
            flat.push(lat);
        }
        ArrayD::from_shape_vec(IxDyn(&[ring.len(), 2]), flat).unwrap()
    }

    /// Drop a trailing vertex equal to the first — the closed-ring form the
    /// `intersect_polygon` AST op now returns — so an oracle that expects the `n`
    /// distinct vertices (e.g. s2 `spherical_area`, which rejects a degenerate
    /// duplicate-vertex edge) sees the open ring.
    fn distinct_vertices(ring: &[(f64, f64)]) -> Vec<(f64, f64)> {
        match ring.last() {
            Some(last) if ring.len() >= 2 && *last == ring[0] => ring[..ring.len() - 1].to_vec(),
            _ => ring.to_vec(),
        }
    }

    /// Clip two polygons through the public evaluator path — `eval_expression`
    /// → [`eval_op`] → `intersect_polygon` arm — exactly as a model's observed
    /// `clip` variable would be evaluated. Returns the overlap ring vertices.
    fn clip_via_evaluator(
        src: &[(f64, f64)],
        tgt: &[(f64, f64)],
        manifold: &str,
    ) -> Vec<(f64, f64)> {
        let mut inputs = HashMap::new();
        inputs.insert("src_poly".to_string(), ring_array(src));
        inputs.insert("tgt_poly".to_string(), ring_array(tgt));
        let node: Expr = serde_json::from_value(json!({
            "op": "intersect_polygon",
            "id": "overlap_clip",
            "manifold": manifold,
            "args": ["src_poly", "tgt_poly"],
        }))
        .unwrap();
        match eval_expression(&node, &inputs, &[], &[], 0.0) {
            Value::Array(a) => arrayd_to_lonlat(&a).expect("[N,2] ring"),
            Value::Scalar(s) => panic!("intersect_polygon evaluated to scalar {s}"),
        }
    }

    /// `polygon_area` as an ordinary `sum_product` FAQ over a ring (planar
    /// shoelace), evaluated by the M1 aggregate machinery. The integrand is the
    /// signed cross term `½·(xᵥ·yᵥ₊₁ − xᵥ₊₁·yᵥ)` summed over ring edges; the ring
    /// and its one-vertex rotation are supplied as arrays so the contracted `v`
    /// loop needs no wrap-around indexing. Returns the unsigned area.
    fn shoelace_area_faq(ring: &[(f64, f64)]) -> f64 {
        let n = ring.len();
        if n < 3 {
            return 0.0;
        }
        let next: Vec<(f64, f64)> = (0..n).map(|i| ring[(i + 1) % n]).collect();
        let mut inputs = HashMap::new();
        inputs.insert("clip".to_string(), ring_array(ring));
        inputs.insert("clip_next".to_string(), ring_array(&next));
        let agg: Expr = serde_json::from_value(json!({
            "op": "aggregate",
            "args": [],
            "semiring": "sum_product",
            "output_idx": [],
            "ranges": { "v": [1, n] },
            "expr": {
                "op": "*",
                "args": [
                    0.5,
                    { "op": "-", "args": [
                        { "op": "*", "args": [
                            { "op": "index", "args": ["clip", "v", 1] },
                            { "op": "index", "args": ["clip_next", "v", 2] }
                        ]},
                        { "op": "*", "args": [
                            { "op": "index", "args": ["clip_next", "v", 1] },
                            { "op": "index", "args": ["clip", "v", 2] }
                        ]}
                    ]}
                ]
            }
        }))
        .unwrap();
        match eval_expression(&agg, &inputs, &[], &[], 0.0) {
            Value::Scalar(s) => s.abs(),
            Value::Array(_) => panic!("scalar polygon_area FAQ expected"),
        }
    }

    #[test]
    fn planar_clip_then_polygon_area_faq_is_exact() {
        // [0,2]² ∩ [1,3]² = [1,2]², area 1. Clip through the evaluator, then take
        // `polygon_area` as a sum_product FAQ over the clipped ring.
        let src = [(0.0, 0.0), (2.0, 0.0), (2.0, 2.0), (0.0, 2.0)];
        let tgt = [(1.0, 1.0), (3.0, 1.0), (3.0, 3.0), (1.0, 3.0)];
        let ring = clip_via_evaluator(&src, &tgt, "planar");
        assert!(ring.len() >= 3, "expected a non-degenerate overlap ring");
        let area = shoelace_area_faq(&ring);
        assert!(
            (area - 1.0).abs() < 1e-9,
            "polygon_area FAQ = {area}, expected 1"
        );
        // The FAQ agrees with the closed-form shoelace oracle.
        assert!((area - crate::geometry::shoelace_area(&ring)).abs() < 1e-12);
    }

    #[test]
    fn planar_clip_of_offset_triangles_area_faq() {
        // A non-rectangular case so the FAQ is exercised on a general ring.
        let src = [(0.0, 0.0), (4.0, 0.0), (0.0, 4.0)];
        let tgt = [(0.0, 0.0), (4.0, 0.0), (4.0, 4.0)];
        let ring = clip_via_evaluator(&src, &tgt, "planar");
        let area = shoelace_area_faq(&ring);
        // Overlap is the triangle (0,0),(4,0),(2,2): area = ½·base·height = 4.
        assert!(
            (area - 4.0).abs() < 1e-9,
            "polygon_area FAQ = {area}, expected 4"
        );
    }

    #[test]
    fn spherical_clip_via_s2_is_nonempty_with_analytic_area() {
        // Two quarter-hemisphere sectors; the s2 clip overlap is π/4 steradians.
        let src = [(0.0, 0.0), (90.0, 0.0), (0.0, 90.0)];
        let tgt = [(45.0, 0.0), (135.0, 0.0), (45.0, 90.0)];
        let ring = clip_via_evaluator(&src, &tgt, "spherical");
        assert!(ring.len() >= 3, "the s2 spherical clip should be non-empty");
        // The AST op returns the ring CLOSED (first vertex repeated) for the
        // shoelace FAQ's `v+1` wrap; the `spherical_area` oracle wants the `n`
        // distinct vertices (s2 rejects a duplicate-vertex edge), so drop the
        // closing copy before the analytic comparison.
        let area =
            crate::geometry::spherical_area(&distinct_vertices(&ring)).expect("spherical area");
        assert!(
            (area - std::f64::consts::FRAC_PI_4).abs() < 1e-9,
            "spherical overlap area = {area}, expected π/4"
        );
    }

    #[test]
    fn disjoint_clip_is_empty_ring_with_zero_area_faq() {
        let src = [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)];
        let tgt = [(5.0, 5.0), (6.0, 5.0), (6.0, 6.0), (5.0, 6.0)];
        let ring = clip_via_evaluator(&src, &tgt, "planar");
        assert!(ring.is_empty(), "disjoint cells clip to an empty ring");
        // A sum_product FAQ over the empty clip_ring reduces to the additive 0̄.
        assert_eq!(shoelace_area_faq(&ring), 0.0);
    }

    /// Evaluate the fused `polygon_intersection_area` leaf through the public
    /// evaluator path (`eval_expression` → [`eval_op`] → `polygon_intersection_area`
    /// arm), returning the scalar overlap area directly (no clip ring exposed).
    fn fused_area_via_evaluator(src: &[(f64, f64)], tgt: &[(f64, f64)], manifold: &str) -> Value {
        let mut inputs = HashMap::new();
        inputs.insert("src_poly".to_string(), ring_array(src));
        inputs.insert("tgt_poly".to_string(), ring_array(tgt));
        let node: Expr = serde_json::from_value(json!({
            "op": "polygon_intersection_area",
            "manifold": manifold,
            "args": ["src_poly", "tgt_poly"],
        }))
        .unwrap();
        eval_expression(&node, &inputs, &[], &[], 0.0)
    }

    #[test]
    fn polygon_intersection_area_planar_is_fused_clip_area() {
        // [0,2]² ∩ [1,3]² = [1,2]², area 1. The fused leaf returns the SCALAR
        // area directly and equals `polygon_area(intersect_polygon(a, b))`.
        let src = [(0.0, 0.0), (2.0, 0.0), (2.0, 2.0), (0.0, 2.0)];
        let tgt = [(1.0, 1.0), (3.0, 1.0), (3.0, 3.0), (1.0, 3.0)];
        let area = match fused_area_via_evaluator(&src, &tgt, "planar") {
            Value::Scalar(s) => s,
            Value::Array(_) => panic!("fused leaf must return a scalar, not a ring"),
        };
        assert!(
            (area - 1.0).abs() < 1e-9,
            "polygon_intersection_area = {area}, expected 1"
        );
        // Fused value matches the composed clip + shoelace-FAQ form exactly.
        let ring = clip_via_evaluator(&src, &tgt, "planar");
        assert!((area - shoelace_area_faq(&ring)).abs() < 1e-12);
    }

    #[test]
    fn polygon_intersection_area_disjoint_is_zero() {
        // Disjoint cells clip to a < 3-vertex ring, whose area is 0.
        let src = [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)];
        let tgt = [(5.0, 5.0), (6.0, 5.0), (6.0, 6.0), (5.0, 6.0)];
        match fused_area_via_evaluator(&src, &tgt, "planar") {
            Value::Scalar(s) => assert_eq!(s, 0.0, "disjoint overlap area should be 0, got {s}"),
            Value::Array(_) => panic!("fused leaf must return a scalar"),
        }
    }

    #[test]
    fn polygon_intersection_area_without_manifold_is_unevaluable() {
        // `manifold` is required on the fused leaf too; absent, it is NaN.
        let mut inputs = HashMap::new();
        inputs.insert(
            "src_poly".to_string(),
            ring_array(&[(0.0, 0.0), (2.0, 0.0), (2.0, 2.0), (0.0, 2.0)]),
        );
        inputs.insert(
            "tgt_poly".to_string(),
            ring_array(&[(1.0, 1.0), (3.0, 1.0), (3.0, 3.0), (1.0, 3.0)]),
        );
        let node: Expr = serde_json::from_value(json!({
            "op": "polygon_intersection_area",
            "args": ["src_poly", "tgt_poly"],
        }))
        .unwrap();
        match eval_expression(&node, &inputs, &[], &[], 0.0) {
            Value::Scalar(s) => assert!(s.is_nan(), "missing manifold should be NaN, got {s}"),
            Value::Array(_) => panic!("missing manifold must not produce a scalar area"),
        }
    }

    #[test]
    fn intersect_polygon_without_manifold_is_unevaluable() {
        // `manifold` is required; absent, the node is not evaluable (NaN sentinel).
        let mut inputs = HashMap::new();
        inputs.insert(
            "src_poly".to_string(),
            ring_array(&[(0.0, 0.0), (2.0, 0.0), (2.0, 2.0), (0.0, 2.0)]),
        );
        inputs.insert(
            "tgt_poly".to_string(),
            ring_array(&[(1.0, 1.0), (3.0, 1.0), (3.0, 3.0), (1.0, 3.0)]),
        );
        let node: Expr = serde_json::from_value(json!({
            "op": "intersect_polygon",
            "args": ["src_poly", "tgt_poly"],
        }))
        .unwrap();
        match eval_expression(&node, &inputs, &[], &[], 0.0) {
            Value::Scalar(s) => assert!(s.is_nan(), "missing manifold should be NaN, got {s}"),
            Value::Array(_) => panic!("missing manifold must not produce a ring"),
        }
    }
}

#[cfg(test)]
mod ragged_eval_tests {
    //! Dynamic per-parent (ragged) contraction bounds in the array evaluator
    //! (bead ess-787; RFC `semiring-faq-unified-ir` §5.2). A `RangeSpec::RaggedDyn`
    //! contracted index reads its per-parent length `offsets[of…]` from a factor
    //! array at eval time, so each output cell reduces over its own dynamic
    //! extent — mirroring the Julia `_expand_int_range_dyn` einsum loop and the
    //! Python `_expand_ragged` reference (`test_ragged_index_set_dynamic_per_parent_bound`).
    use super::*;
    use serde_json::json;

    /// Build the standalone aggregate `out[i] = ⊕_{k∈edges(i)} k` with `k`'s
    /// range resolved to a ragged bound over the `nedges` factor. A file never
    /// authors a `RaggedDyn` range (the resolver produces it), so we parse the
    /// node and inject the resolved range directly.
    fn ragged_sum_node() -> Expr {
        let mut agg: Expr = serde_json::from_value(json!({
            "op": "aggregate",
            "args": [],
            "semiring": "sum_product",
            "output_idx": ["i"],
            "expr": "k",
            "ranges": { "i": [1, 2], "k": [1, 1] }
        }))
        .unwrap();
        if let Expr::Operator(node) = &mut agg {
            node.ranges.as_mut().unwrap().insert(
                "k".to_string(),
                RangeSpec::RaggedDyn {
                    offsets: "nedges".into(),
                    of: vec!["i".into()],
                },
            );
        }
        agg
    }

    fn nedges(values: &[f64]) -> HashMap<String, ArrayD<f64>> {
        HashMap::from([(
            "nedges".to_string(),
            ArrayD::from_shape_vec(IxDyn(&[values.len()]), values.to_vec()).unwrap(),
        )])
    }

    /// `nedges = [2, 3]` ⇒ `out = [1+2, 1+2+3] = [3, 6]` — the per-parent bound
    /// is read fresh for each output cell.
    #[test]
    fn ragged_contraction_uses_per_parent_dynamic_bound() {
        match eval_expression(&ragged_sum_node(), &nedges(&[2.0, 3.0]), &[], &[], 0.0) {
            Value::Array(a) => {
                assert_eq!(a.shape(), [2]);
                assert_eq!(a[IxDyn(&[0])], 3.0);
                assert_eq!(a[IxDyn(&[1])], 6.0);
            }
            Value::Scalar(s) => panic!("expected a [3, 6] array, got scalar {s}"),
        }
    }

    /// An isolated parent (zero-length ragged segment) reduces to the semiring's
    /// additive identity 0̄: `nedges = [0, 2]` ⇒ `out = [0, 1+2] = [0, 3]`.
    #[test]
    fn ragged_empty_segment_yields_additive_identity() {
        match eval_expression(&ragged_sum_node(), &nedges(&[0.0, 2.0]), &[], &[], 0.0) {
            Value::Array(a) => {
                assert_eq!(a[IxDyn(&[0])], 0.0);
                assert_eq!(a[IxDyn(&[1])], 3.0);
            }
            Value::Scalar(s) => panic!("expected a [0, 3] array, got scalar {s}"),
        }
    }
}

#[cfg(test)]
mod forcing_channel_tests {
    //! PR-1 (ess-14f.7): the external refreshable forcing-array channel into the
    //! diffsol array RHS. These tests are the bead's acceptance evidence:
    //!   1. the RHS reads a forcing array *live* from the buffer,
    //!   2. a buffer mutation (a driver refreshing between cadence segments) is
    //!      reflected in the RHS output, and
    //!   3. the existing scalar-`p` / parameter path is unaffected.
    //!
    //! The forcing buffer is the runtime landing zone for a discrete-cadence
    //! loader's regridded field; here it is driven by hand (no I/O), exactly the
    //! "testable with a hand-built buffer" contract the plan (PR-1) specifies.
    use super::*;
    use crate::parse::load;

    fn arr1(v: &[f64]) -> ArrayD<f64> {
        ArrayD::from_shape_vec(IxDyn(&[v.len()]), v.to_vec()).unwrap()
    }

    /// A model whose state derivative reads an external forcing array `w`
    /// elementwise: `D(u[i]) = w[i]`, i ∈ [1,3]. `w` is declared in no variable
    /// block — it is a loader-fed field that resolves through the forcing buffer
    /// (the new lowest-precedence binding), precisely the channel PR-1 adds.
    fn forced_model() -> ArrayCompiled {
        let json = r#"{
         "esm": "0.1.0",
         "metadata": {"name": "forcing_channel"},
         "models": {
          "Forced": {
           "variables": {"u": {"type": "state", "shape": ["i"], "default": 0.0}},
           "equations": [
            {
             "lhs": {"op": "aggregate", "args": [], "output_idx": ["i"],
                     "expr": {"op": "D", "args": [{"op": "index", "args": ["u", "i"]}], "wrt": "t"},
                     "ranges": {"i": [1, 3]}},
             "rhs": {"op": "aggregate", "args": [], "output_idx": ["i"],
                     "ranges": {"i": [1, 3]},
                     "expr": {"op": "index", "args": ["w", "i"]}}
            }
           ]
          }
         }
        }"#;
        let file = load(json).expect("parse forcing model");
        ArrayCompiled::from_file(&file).expect("compile forcing model")
    }

    #[test]
    fn rhs_reads_forcing_array_and_reflects_mutation() {
        let compiled = forced_model();
        let forcing = compiled.forcing_handle();
        let params = HashMap::new();
        let state = vec![0.0, 0.0, 0.0];

        // Refresh #1 — the RHS reads the forcing array live from the buffer.
        forcing
            .borrow_mut()
            .insert("w".to_string(), arr1(&[10.0, 20.0, 30.0]));
        let (dy1, _) = compiled.debug_eval_rhs(&state, 0.0, &params, false);
        assert_eq!(
            dy1,
            vec![10.0, 20.0, 30.0],
            "RHS must read the forcing array live from the buffer"
        );

        // Refresh #2 — a driver mutating the buffer between segments. The change
        // is reflected in the RHS output: the channel is live, not build-frozen.
        forcing
            .borrow_mut()
            .insert("w".to_string(), arr1(&[1.0, 2.0, 3.0]));
        let (dy2, _) = compiled.debug_eval_rhs(&state, 0.0, &params, false);
        assert_eq!(
            dy2,
            vec![1.0, 2.0, 3.0],
            "a buffer mutation must change the RHS output"
        );
        assert_ne!(
            dy1, dy2,
            "the refreshed forcing must produce a different RHS"
        );

        // The per-cell oracle path (force_scalar = true) reads the same buffer —
        // the production vectorized path bails forcing reads to this oracle.
        let (dy_oracle, _) = compiled.debug_eval_rhs(&state, 0.0, &params, true);
        assert_eq!(
            dy_oracle,
            vec![1.0, 2.0, 3.0],
            "the oracle path resolves forcing identically"
        );
    }

    #[test]
    fn forcing_flows_through_the_production_solve() {
        // The forcing buffer is captured (Rc clone) into the diffsol RHS closure,
        // so a constant forcing `D(u[i]) = w[i]` integrates to `u(t) = u0 + w·t`
        // through the real solver — proving the channel is wired into `simulate`,
        // not only the debug RHS entry point.
        let compiled = forced_model();
        compiled
            .forcing_handle()
            .borrow_mut()
            .insert("w".to_string(), arr1(&[2.0, 4.0, 6.0]));
        let params = HashMap::new();
        let ics = HashMap::new(); // states default to 0
        let opts = SimulateOptions::default();
        let sol = compiled
            .simulate((0.0, 1.0), &params, &ics, &opts)
            .expect("solve with forcing");
        // Final state ≈ u0 + w·1 = [2, 4, 6].
        for (i, want) in [2.0, 4.0, 6.0].iter().enumerate() {
            let got = *sol.state[i].last().expect("trajectory non-empty");
            assert!(
                (got - want).abs() < 1e-6,
                "forcing must drive the solve: state[{i}] got {got}, want {want}"
            );
        }
    }

    #[test]
    fn empty_forcing_leaves_param_path_unaffected() {
        // A parameter+state model `D(u[i]) = k·u[i]` with no forcing reference.
        // With an empty buffer the parameter/state path is byte-identical; and an
        // *unrelated* forcing entry does not perturb it, because forcing is
        // resolved last and only fills otherwise-unbound names.
        let json = r#"{
         "esm": "0.1.0",
         "metadata": {"name": "param_path"},
         "models": {
          "P": {
           "variables": {
             "u": {"type": "state", "shape": ["i"]},
             "k": {"type": "parameter"}
           },
           "equations": [
            {
             "lhs": {"op": "aggregate", "args": [], "output_idx": ["i"],
                     "expr": {"op": "D", "args": [{"op": "index", "args": ["u", "i"]}], "wrt": "t"},
                     "ranges": {"i": [1, 2]}},
             "rhs": {"op": "aggregate", "args": [], "output_idx": ["i"],
                     "ranges": {"i": [1, 2]},
                     "expr": {"op": "*", "args": ["k", {"op": "index", "args": ["u", "i"]}]}}
            }
           ]
          }
         }
        }"#;
        let file = load(json).expect("parse param model");
        let compiled = ArrayCompiled::from_file(&file).expect("compile param model");
        let mut params = HashMap::new();
        params.insert("k".to_string(), 2.0);
        let state = vec![3.0, 5.0];

        let (dy_no_forcing, _) = compiled.debug_eval_rhs(&state, 0.0, &params, false);
        assert_eq!(
            dy_no_forcing,
            vec![6.0, 10.0],
            "empty forcing leaves the parameter path identical (k·u)"
        );

        // An unrelated forcing entry must not leak into the parameter path.
        compiled
            .forcing_handle()
            .borrow_mut()
            .insert("unrelated".to_string(), arr1(&[99.0]));
        let (dy_with_junk, _) = compiled.debug_eval_rhs(&state, 0.0, &params, false);
        assert_eq!(
            dy_with_junk,
            vec![6.0, 10.0],
            "an unrelated forcing entry must not perturb the parameter path"
        );
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
    use crate::simulate::{SolverChoice, simulate, simulate_with_inspection};
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

#[cfg(test)]
mod elementwise_array_observed_tests {
    //! WS4: a discretization-agnostic PDE leaf may be authored with readable
    //! intermediate ARRAY-shaped observeds (a level-set's `grad_mag`, `U_n`,
    //! `S_n`, …) rather than one inlined `D(state)` RHS. The array runtime
    //! evaluates each declared array observed WHOLESALE — `eval` looks every
    //! array-valued observed reference up in the observed-array map and
    //! broadcasts the elementwise ops over it — and `materialize_observeds`
    //! builds them in dependency order, so the decomposition runs as authored
    //! with no special per-cell lift. This is the Rust mirror of the Julia
    //! `_fold_elementwise_array_observeds` pass; the test locks the behaviour so
    //! the same `.esm` keeps running identically in both toolkits.
    use super::*;
    use crate::simulate::{SolverChoice, simulate};
    use serde_json::json;

    fn typed(doc: serde_json::Value) -> EsmFile {
        serde_json::from_value(doc).expect("test document deserializes")
    }
    fn erk() -> SimulateOptions {
        SimulateOptions {
            solver: SolverChoice::Erk,
            reltol: 1e-10,
            abstol: 1e-12,
            output_times: Some(vec![1.0]),
            ..Default::default()
        }
    }

    /// A spatial state psi[c] fed by a chain of ELEMENTWISE array observeds
    /// (`k[c]` const field, `a = psi + k`) with `D(psi,t) = -a`. From psi(0)=0
    /// the solution is psi(1) = -k·(1 - e⁻¹), DISTINCT per cell — so a correct
    /// result proves the observeds are evaluated element-wise (not collapsed to
    /// a scalar) and feed the state per cell.
    #[test]
    fn elementwise_array_observed_chain_drives_state_per_cell() {
        let doc = json!({
            "esm": "0.8.0",
            "metadata": {"name": "ew_obs"},
            "index_sets": {"c": {"kind": "interval", "size": 3}},
            "models": {"M": {
                "variables": {
                    "psi": {"type": "state", "units": "1", "shape": ["c"]},
                    "k": {"type": "observed", "shape": ["c"],
                          "expression": {"op": "const", "value": [1.0, 2.0, 3.0], "args": []}},
                    "a": {"type": "observed", "shape": ["c"],
                          "expression": {"op": "+", "args": ["psi", "k"]}}
                },
                "equations": [
                    {"lhs": {"op": "ic", "args": ["psi"]}, "rhs": 0.0},
                    {"lhs": {"op": "D", "args": ["psi"], "wrt": "t"}, "rhs": {"op": "-", "args": ["a"]}}
                ]
            }}
        });
        let file = typed(doc);
        let sol = simulate(
            &file,
            (0.0, 1.0),
            &HashMap::new(),
            &HashMap::new(),
            &erk(),
        )
        .expect("simulates");
        let ti = sol.time.len() - 1;
        let cells = crate::pde_inline_tests::state_cells(&sol.state_variable_names, "psi", "M");
        assert_eq!(cells.len(), 3);
        let psi: Vec<f64> = cells.iter().map(|(_, row)| sol.state[*row][ti]).collect();
        let one_minus_em1 = 1.0 - (-1.0f64).exp();
        for (i, k) in [1.0f64, 2.0, 3.0].iter().enumerate() {
            let expect = -k * one_minus_em1;
            assert!(
                (psi[i] - expect).abs() < 1e-6,
                "psi[{}](1) = {} != {}",
                i + 1,
                psi[i],
                expect
            );
        }
    }
}
