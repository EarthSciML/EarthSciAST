//! Vectorized (whole-array) stencil evaluator (ess-bdm).
//!
//! Evaluates a discretized spatial arrayop RHS as whole-array kernels instead
//! of a per-cell scalar loop, mirroring the Python `numpy_interpreter`
//! vectorized path (ESS PR #25, `_materialize_map` + shifted-slice
//! `_eval_index` + region-materialized makearray). The state stays the
//! gridded array; the RHS is computed by:
//!
//!   * shifted array slices for stencil neighbours `index(u, sym±k)`,
//!   * Julia-left-aligned broadcast arithmetic for coefficients (reusing the
//!     existing `combine`/`broadcast_binary`),
//!   * boundary makearrays materialized region-by-region as array sub-range
//!     writes (last region wins),
//!
//! producing the whole output array in a single AST walk. The number of
//! kernel ops is therefore independent of the grid size N — the
//! no-scalarization property ess-bdm requires.
//!
//! This is a *fast path*: any construct it does not handle (general semiring
//! contraction, periodic-wrap / non-affine indexing, reshape/transpose, …)
//! returns `None`, and the caller falls back to the per-cell oracle, which
//! remains the correctness reference.

use super::*;
use crate::types::ExpressionNode;
use ndarray::{ArrayViewD, Slice};

// ---------------------------------------------------------------------------
// Bail-out tracing (diagnostics only; off unless `ESS_VEC_DEBUG` is set).
//
// The vectorized overlay returns `None` from dozens of scattered sites and the
// caller silently falls back to the per-cell oracle, so a model that never
// vectorizes gives no clue *which* construct is responsible. With
// `ESS_VEC_DEBUG=1` every bail records a short tag; because the AST walk
// unwinds innermost-first, the FIRST entry in the log is the deepest — the
// actual unsupported construct — and the rest are the enclosing nodes that
// propagated the `None`.
// ---------------------------------------------------------------------------

thread_local! {
    static VEC_BAIL_LOG: std::cell::RefCell<Vec<String>> =
        const { std::cell::RefCell::new(Vec::new()) };
}

/// Whether bail tracing is enabled (`ESS_VEC_DEBUG` set to anything non-empty).
pub(super) fn vec_trace_on() -> bool {
    static ON: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *ON.get_or_init(|| {
        std::env::var("ESS_VEC_DEBUG")
            .map(|v| !v.is_empty() && v != "0")
            .unwrap_or(false)
    })
}

/// Kill-switch for the whole vectorized overlay (`ESS_VEC_DISABLE=1`).
///
/// `RhsStats`'s `force_scalar` flag only gates the two *compiled-rule* call
/// sites; an array observed whose body is a standalone `aggregate` reaches the
/// overlay through `eval_arrayop`, which has no such flag. This switch turns the
/// overlay off everywhere at once, so a run with it set is the pure per-cell
/// oracle — the reference a bit-identity check needs.
pub(super) fn vec_disabled() -> bool {
    static OFF: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *OFF.get_or_init(|| {
        std::env::var("ESS_VEC_DISABLE")
            .map(|v| !v.is_empty() && v != "0")
            .unwrap_or(false)
    })
}

/// Record one bail site (no-op unless tracing is on).
pub(super) fn note_bail(site: impl FnOnce() -> String) {
    if vec_trace_on() {
        VEC_BAIL_LOG.with(|l| l.borrow_mut().push(site()));
    }
}

thread_local! {
    static VEC_OPS: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
}

/// Count one vectorized AST-node visit (tracing only).
fn note_op() {
    VEC_OPS.with(|c| c.set(c.get() + 1));
}

/// Read and reset the visited-node counter (tracing only).
pub(super) fn take_op_count() -> usize {
    VEC_OPS.with(|c| c.replace(0))
}

/// Drain the recorded bail sites (deepest first).
pub(super) fn take_bail_log() -> Vec<String> {
    VEC_BAIL_LOG.with(|l| l.borrow_mut().drain(..).collect())
}

/// A one-line description of an AST node, for the bail log.
fn describe_expr(e: &Expr) -> String {
    match e {
        Expr::Number(n) => format!("Number({n})"),
        Expr::Integer(n) => format!("Integer({n})"),
        Expr::Variable(v) => format!("Variable({v})"),
        Expr::Operator(n) => {
            let bf = n
                .broadcast_fn
                .as_deref()
                .map(|f| format!("[fn={f}]"))
                .unwrap_or_default();
            format!("op {}{}/{}", n.op, bf, n.args.len())
        }
    }
}

/// `return None`, recording `$site` in the bail log first.
macro_rules! bail_vec {
    ($site:literal) => {{
        note_bail(|| $site.to_string());
        return None;
    }};
    ($site:literal, $fmt:expr) => {{
        note_bail(|| format!(concat!($site, ": {}"), $fmt));
        return None;
    }};
}

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
pub(super) enum VecValue<'a> {
    Scalar(f64),
    View { data: &'a ArrayD<f64>, origin: DimI },
    Owned { data: ArrayD<f64>, origin: DimI },
}

impl<'a> VecValue<'a> {
    /// The per-axis origin of an array value (`None` for a scalar).
    pub(super) fn origin(&self) -> Option<&[i64]> {
        match self {
            VecValue::Scalar(_) => None,
            VecValue::View { origin, .. } | VecValue::Owned { origin, .. } => Some(origin),
        }
    }

    /// The shape of an array value (`None` for a scalar).
    pub(super) fn shape(&self) -> Option<&[usize]> {
        match self {
            VecValue::Scalar(_) => None,
            VecValue::View { data, .. } => Some(data.shape()),
            VecValue::Owned { data, .. } => Some(data.shape()),
        }
    }

    /// A read-only view of an array value (`None` for a scalar).
    pub(super) fn view(&self) -> Option<ArrayViewD<'_, f64>> {
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
                // `assign` writes every element of the box, so the checkout
                // does not need to be zero-filled.
                let mut buf = pool.take_array_uninit(data.shape());
                buf.assign(data);
                (buf, origin)
            }
            VecValue::Scalar(_) => unreachable!("into_owned called on a scalar"),
        }
    }

    /// Release a consumed value's pooled buffer (no-op for `View`/`Scalar`).
    pub(super) fn release(self, pool: &mut Pool) {
        if let VecValue::Owned { data, .. } = self {
            pool.give_array(data);
        }
    }
}

/// The output box currently being materialized: the positional output index
/// symbols and, per axis, the 1-based low index and extent.
pub(super) struct VecBox<'a> {
    pub(super) syms: &'a [String],
    pub(super) lo: &'a [i64],
    pub(super) shape: &'a [usize],
    /// Bound contracted-index names (empty for a pure-map stencil). When an
    /// einsum body is evaluated once per contraction tuple, the current tuple's
    /// values live in `cvals` (parallel to `cnames`). A bare `cnames` symbol
    /// then resolves to its `cvals` entry as a scalar (so `ifelse(k==0,…)` folds
    /// per `k`), and an index offset `i + k` folds `k` into the affine shift —
    /// making `sum_k 25·ifelse(k==0,-2,1)·u[i+k]` a small fold of shifted
    /// whole-array slices instead of a per-cell semiring walk.
    pub(super) cnames: &'a [String],
    pub(super) cvals: &'a [i64],
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
pub(super) fn lhs_constant_shifts(
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
pub(super) fn subblock_dest(
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
pub(super) fn try_eval_arrayop_vectorized<'a>(
    output_idx_names: &[String],
    output_ranges: &[(i64, i64)],
    body: &Expr,
    contract_names: &[String],
    contract_dims: &[ContractDim],
    reduce: ReduceKind,
    filter: Option<&Expr>,
    ctx: &EvalCtx<'a>,
    pool: &mut Pool,
) -> Option<(VecValue<'a>, usize)> {
    if vec_disabled() {
        return None;
    }
    let lo: DimI = output_ranges.iter().map(|(l, _)| *l).collect();
    let shape: DimU = output_ranges
        .iter()
        .map(|(l, h)| (h - l + 1) as usize)
        .collect();
    if shape.contains(&0) {
        bail_vec!("arrayop: empty output box");
    }
    // ess-cse: this box is one CSE scope. Analysing the body is idempotent (it
    // runs once per distinct body root per scratch); the scope guard closes on
    // every path, including the `?`/`bail_vec!` early returns below. At the
    // OUTERMOST entry the guard also recycles the previous evaluation's memo
    // arrays into `pool` — safe there because no `VecValue` from the previous
    // top-level evaluation can still be alive (each caller consumes its result
    // before returning). A nested aggregate re-enters here and gets its own
    // scope, so a subtree under a different box never shares a memo entry.
    if let Some(rt) = ctx.cse {
        rt.analyse(body, output_idx_names, contract_names);
    }
    let _cse_scope = ctx.cse.map(|rt| rt.scope(pool));
    let mut ops = 0usize;
    let v = if contract_names.is_empty() {
        let bx = VecBox {
            syms: output_idx_names,
            lo: &lo[..],
            shape: &shape[..],
            cnames: &[],
            cvals: &[],
        };
        let body_v = eval_vec(body, &bx, ctx, pool, &mut ops)?;
        // Pure-map §5.3 filter: an excluded output cell contributes the reduction
        // identity 0̄ (`out = filter ? body : identity`), matching the oracle's
        // per-cell `filter_excludes` on a non-contracting aggregate.
        match filter {
            None => body_v,
            Some(f) => match eval_vec(f, &bx, ctx, pool, &mut ops) {
                None => {
                    body_v.release(pool);
                    return None;
                }
                Some(VecValue::Scalar(c)) => {
                    if c != 0.0 {
                        body_v
                    } else {
                        body_v.release(pool);
                        let mut ident = pool.take_array(&shape);
                        let idv = reduce.identity();
                        if idv != 0.0 {
                            ident.fill(idv);
                        }
                        VecValue::Owned {
                            data: ident,
                            origin: lo.clone(),
                        }
                    }
                }
                Some(mask) => {
                    vec_select(mask, body_v, VecValue::Scalar(reduce.identity()), pool)?
                }
            },
        }
    } else {
        eval_vec_contracted(
            output_idx_names,
            &lo,
            &shape,
            body,
            contract_names,
            contract_dims,
            reduce,
            filter,
            ctx,
            pool,
            &mut ops,
        )?
    };
    // A top-level array *View* means the body reduced to a bare whole-array
    // variable read (`out[i] = w`, an `ifelse`/`broadcast` returning a bare array
    // operand, …): every mapped `index(...)`, arithmetic, or `makearray` construct
    // yields an `Owned` buffer or a `Scalar`, so only a bare variable reaches here
    // as a `View`. The per-cell oracle scalarizes the pure-map body via
    // `eval(body, ctx).as_scalar()`, which is `NaN` for an array (eval.rs
    // `reduce_contraction`), so returning the whole array here would DIVERGE from
    // the oracle. Bail to the per-cell oracle — the correctness reference — which
    // rejects such a body uniformly (esm audit #3). The `contract_names`-empty
    // fold never produces a `View` (its accumulator is always `Owned`), so this
    // only fires on the pure-map path it targets.
    if matches!(v, VecValue::View { .. }) {
        v.release(pool);
        bail_vec!("arrayop: body reduced to a bare whole-array view (oracle scalarizes it)");
    }
    // The top-level result must already cover the output box exactly. A bare
    // scalar is broadcast over the box.
    let matches_box = match v.shape() {
        None => true,
        Some(s) => s == &shape[..] && v.origin().map(|o| o == &lo[..]).unwrap_or(false),
    };
    if !matches_box {
        v.release(pool);
        bail_vec!("arrayop: result box does not match the output box");
    }
    let out = match v {
        VecValue::Scalar(s) => {
            // `fill` writes every element, so no zero-fill on checkout.
            let mut buf = pool.take_array_uninit(&shape);
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
pub(super) fn reduce_combine_op(reduce: ReduceKind) -> Option<BinCode> {
    match reduce {
        ReduceKind::Sum => Some(BinCode::Add),
        ReduceKind::Product => Some(BinCode::Mul),
        ReduceKind::Max => Some(BinCode::Max),
        ReduceKind::Min => Some(BinCode::Min),
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
pub(super) fn eval_vec_contracted<'a>(
    output_idx_names: &[String],
    lo: &[i64],
    shape: &[usize],
    body: &Expr,
    contract_names: &[String],
    contract_dims: &[ContractDim],
    reduce: ReduceKind,
    filter: Option<&Expr>,
    ctx: &EvalCtx<'a>,
    pool: &mut Pool,
    ops: &mut usize,
) -> Option<VecValue<'a>> {
    let combine_op = match reduce_combine_op(reduce) {
        Some(op) => op,
        None => bail_vec!("contracted: boolean reduction (or/and) not vectorized"),
    };
    // Resolve each contracted dim to a static (lo, hi). A non-static dim
    // (ragged/derived — per-output-tuple extent) can't be a uniform whole-array
    // window, so bail to the oracle.
    const MAXC: usize = 4;
    let nc = contract_names.len();
    if nc == 0 || nc > MAXC {
        bail_vec!("contracted: contraction rank out of range", nc);
    }
    let mut clo = [0i64; MAXC];
    let mut chi = [0i64; MAXC];
    for (i, d) in contract_dims.iter().enumerate() {
        match d {
            ContractDim::Static(l, h) => {
                clo[i] = *l;
                chi[i] = *h;
            }
            other => {
                bail_vec!(
                    "contracted: non-static contraction dim (ragged/derived)",
                    format!("{other:?}")
                )
            }
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
        // ess-cse: each contraction tuple binds `cvals` differently, so it is a
        // DISTINCT box and therefore a distinct CSE scope — a subtree memoized
        // at tuple k must not be served at tuple k+1.
        let _cse_scope = ctx.cse.map(|rt| rt.scope(pool));
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
        // §5.3 filter: a combination for which the predicate is false contributes
        // the additive identity 0̄ (acc ⊕ 0̄ = acc). Gate the term with the filter
        // mask — `vec_select(mask, term, identity)` — reusing the identical
        // predicate the oracle's `filter_excludes` applies per cell. A SCALAR-false
        // mask replaces the whole term with the identity; a SCALAR-true keeps it.
        let term = match filter {
            None => term,
            Some(f) => match eval_vec(f, &bx, ctx, pool, ops) {
                None => {
                    term.release(pool);
                    acc.release(pool);
                    return None;
                }
                Some(VecValue::Scalar(c)) => {
                    if c != 0.0 {
                        term
                    } else {
                        term.release(pool);
                        let mut ident = pool.take_array(shape);
                        if identity != 0.0 {
                            ident.fill(identity);
                        }
                        VecValue::Owned {
                            data: ident,
                            origin: lo.iter().copied().collect(),
                        }
                    }
                }
                Some(mask) => match vec_select(mask, term, VecValue::Scalar(identity), pool) {
                    Some(t) => t,
                    None => {
                        acc.release(pool);
                        return None;
                    }
                },
            },
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
pub(super) fn eval_vec<'a>(
    expr: &Expr,
    bx: &VecBox,
    ctx: &EvalCtx<'a>,
    pool: &mut Pool,
    ops: &mut usize,
) -> Option<VecValue<'a>> {
    *ops += 1;
    if vec_trace_on() {
        note_op();
    }
    // ---- CSE (ess-cse) -----------------------------------------------------
    // A discretization template is expanded at every reference site, so one
    // lowered tendency body evaluates the SAME subtree dozens of times under the
    // same box (482,961 operator-node evaluations collapse to 14,208 distinct
    // ones for simpleclimate.esm). `class_of` yields a class id only for a node
    // whose class repeats inside its own scope, and the memo is keyed by
    // (scope, class) — a fresh scope per `VecBox` — so a hit is the value this
    // node WOULD have computed, not merely a syntactic twin. See `cse.rs` for
    // the scoping argument.
    //
    // A class id carrying `PURE_BIT` marks a BOX-PURE subtree (ess-lih): one
    // built only from this box's index symbols and CONST-tier names, so its
    // value is fixed for the whole solve. `get`/`put` route those to the
    // PERSISTENT store keyed by the box SIGNATURE instead of the per-evaluation
    // memo, so a model's grid geometry — coordinate ramps, `sin`/`cos` of a
    // latitude, metric factors read off an already-hoisted static observed — is
    // computed once rather than once per RHS call. See `cse.rs` (§ess-lih).
    let cse_class = ctx.cse.and_then(|c| c.class_of(expr));
    if let (Some(rt), Some(class)) = (ctx.cse, cse_class)
        && let Some(hit) = rt.get(class, bx)
    {
        return Some(hit);
    }
    let r = match expr {
        Expr::Number(n) => Some(VecValue::Scalar(*n)),
        Expr::Integer(n) => Some(VecValue::Scalar(*n as f64)),
        Expr::Variable(name) => eval_vec_variable(name, bx, ctx, pool),
        Expr::Operator(node) => eval_vec_op(node, bx, ctx, pool, ops),
    };
    let r = match (ctx.cse, cse_class, r) {
        (Some(rt), Some(class), Some(v)) => Some(rt.put(class, v, bx)),
        (_, _, r) => r,
    };
    if r.is_none() {
        note_bail(|| format!("  in {}", describe_expr(expr)));
    }
    r
}

pub(super) fn eval_vec_variable<'a>(
    name: &str,
    bx: &VecBox,
    ctx: &EvalCtx<'a>,
    pool: &mut Pool,
) -> Option<VecValue<'a>> {
    if name == "t" {
        return Some(VecValue::Scalar(ctx.t));
    }
    // A bound contracted index (einsum fold) is a constant scalar for the whole
    // output box on this tuple — so `k` in `ifelse(k==0,…)` folds per tuple.
    if let Some(v) = bx.cbind(name) {
        return Some(VecValue::Scalar(v as f64));
    }
    // A bare output index symbol as a *value* (rather than inside `index(...)`
    // addressing) is the coordinate-ramp idiom every geometry observed uses:
    // `phi = -90 + (j - 1)·dlat`, `sigma_c = (k - 0.5)/NZ`. The per-cell oracle
    // resolves it to the bound integer for the cell, so the whole-array analogue
    // is a RAMP over that axis: element `p` along output axis `a` holds
    // `bx.lo[a] + p` as an `f64`, and every other axis is constant. That is
    // exactly the value the oracle produces in each cell, so downstream
    // arithmetic stays bit-identical.
    if let Some(a) = bx.syms.iter().position(|s| s == name) {
        // The ramp writes every element of the box below, so no zero-fill.
        let mut ramp = pool.take_array_uninit(bx.shape);
        let lo = bx.lo[a];
        ramp.indexed_iter_mut()
            .for_each(|(idx, v)| *v = (lo + idx[a] as i64) as f64);
        return Some(VecValue::Owned {
            data: ramp,
            origin: bx.lo.iter().copied().collect(),
        });
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
    note_bail(|| format!("variable: unresolved symbol (forcing/loop-bind?): {name}"));
    None
}

/// An operator resolved to the [`eval_vec_op`] arm that handles it, plus (for
/// the kernel families) the element kernel's code.
///
/// `eval_vec_op` used to select its arm with `match node.op.as_str()` — a chain
/// of string comparisons run on EVERY node visit, and the enclosed kernel
/// families then re-matched the same name one to three more times
/// (`vec_combine`, `binary_kernel`, `scalar_compare`). A perf profile of the
/// solve put ~2.5% in that chain (`__memcmp_evex_movbe` 1.14% self, plus the
/// inlined `str PartialEq::eq` under `eval_vec_op`). Commit 857c2768 removed the
/// per-ELEMENT case; this removes the per-NODE case.
///
/// The mapping is pinned to the arm structure it replaces by
/// `vec_op_code_matches_the_dispatch_arms`, and each kernel code is pinned to
/// the per-cell oracle's `apply_binary`/`apply_unary` by the equivalence tests
/// in [`super::eval`].
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(super) enum VecOp {
    /// `+ - * / ^ min max atan2 and or` — n-ary left fold through [`vec_combine`].
    Arith(BinCode),
    /// `== != < <= > >=` — strictly binary, same [`vec_combine`] kernel.
    Cmp(BinCode),
    /// The 21 unary transcendental/rounding maps plus `not`.
    Unary(UnCode),
    Neg,
    Index,
    Aggregate,
    Makearray,
    Const,
    Ifelse,
    Broadcast,
    /// Everything the overlay does not vectorize (→ per-cell oracle).
    Unsupported,
}

/// Resolve an operator name to its [`eval_vec_op`] arm. ONE string match per AST
/// node; every dispatch below it is on the returned code.
pub(super) fn vec_op_code(op: &str) -> VecOp {
    match op {
        "+" => VecOp::Arith(BinCode::Add),
        "-" => VecOp::Arith(BinCode::Sub),
        "*" => VecOp::Arith(BinCode::Mul),
        "/" => VecOp::Arith(BinCode::Div),
        "^" => VecOp::Arith(BinCode::Pow),
        "min" => VecOp::Arith(BinCode::Min),
        "max" => VecOp::Arith(BinCode::Max),
        "atan2" => VecOp::Arith(BinCode::Atan2),
        "and" => VecOp::Arith(BinCode::And),
        "or" => VecOp::Arith(BinCode::Or),
        "==" => VecOp::Cmp(BinCode::Eq),
        "!=" => VecOp::Cmp(BinCode::Ne),
        "<" => VecOp::Cmp(BinCode::Lt),
        "<=" => VecOp::Cmp(BinCode::Le),
        ">" => VecOp::Cmp(BinCode::Gt),
        ">=" => VecOp::Cmp(BinCode::Ge),
        "exp" => VecOp::Unary(UnCode::Exp),
        "log" | "ln" => VecOp::Unary(UnCode::Ln),
        "log10" => VecOp::Unary(UnCode::Log10),
        "sqrt" => VecOp::Unary(UnCode::Sqrt),
        "abs" => VecOp::Unary(UnCode::Abs),
        "sign" => VecOp::Unary(UnCode::Sign),
        "floor" => VecOp::Unary(UnCode::Floor),
        "ceil" => VecOp::Unary(UnCode::Ceil),
        "sin" => VecOp::Unary(UnCode::Sin),
        "cos" => VecOp::Unary(UnCode::Cos),
        "tan" => VecOp::Unary(UnCode::Tan),
        "asin" => VecOp::Unary(UnCode::Asin),
        "acos" => VecOp::Unary(UnCode::Acos),
        "atan" => VecOp::Unary(UnCode::Atan),
        "sinh" => VecOp::Unary(UnCode::Sinh),
        "cosh" => VecOp::Unary(UnCode::Cosh),
        "tanh" => VecOp::Unary(UnCode::Tanh),
        "asinh" => VecOp::Unary(UnCode::Asinh),
        "acosh" => VecOp::Unary(UnCode::Acosh),
        "atanh" => VecOp::Unary(UnCode::Atanh),
        "not" => VecOp::Unary(UnCode::Not),
        "neg" => VecOp::Neg,
        "index" => VecOp::Index,
        "aggregate" => VecOp::Aggregate,
        "makearray" => VecOp::Makearray,
        "const" => VecOp::Const,
        "ifelse" => VecOp::Ifelse,
        "broadcast" => VecOp::Broadcast,
        _ => VecOp::Unsupported,
    }
}

pub(super) fn eval_vec_op<'a>(
    node: &ExpressionNode,
    bx: &VecBox,
    ctx: &EvalCtx<'a>,
    pool: &mut Pool,
    ops: &mut usize,
) -> Option<VecValue<'a>> {
    match vec_op_code(&node.op) {
        // Elementwise / n-ary arithmetic, plus `atan2` (binary) and the logical
        // connectives `and`/`or` (n-ary). All fold left-to-right through
        // `vec_combine` → `apply_binary` — the SAME kernel and order the per-cell
        // oracle uses (`eval_arith`/`eval_binary` → `combine` → `apply_binary`),
        // so the whole-array result is bit-identical. Routing these here (rather
        // than bailing to the oracle) is what lets a behaviour-stack observed
        // whose body mixes arithmetic with a wind/slope `atan2` or an
        // `and(code>=1, code<=13)` fuel gate stay on the vectorized path.
        VecOp::Arith(code) => {
            // `args[0]` was indexed with no emptiness guard, so an aggregate body
            // containing e.g. `{"op":"+","args":[]}` PANICKED here while the
            // oracle tolerated it — the two paths did not even agree on whether
            // the node was evaluable. The registry now rejects every such node
            // before evaluation; bailing to the oracle (`None`) keeps this path
            // panic-free for the `eval_expression` bypass, which is not gated.
            let (first, rest) = node.args.split_first()?;
            if code == BinCode::Sub && rest.is_empty() {
                return Some(vec_negate(eval_vec(first, bx, ctx, pool, ops)?, pool));
            }
            let mut acc = eval_vec(first, bx, ctx, pool, ops)?;
            for a in rest {
                let v = eval_vec(a, bx, ctx, pool, ops)?;
                acc = vec_combine(code, acc, v, pool)?;
            }
            Some(acc)
        }
        VecOp::Neg => Some(vec_negate(
            eval_vec(node.args.first()?, bx, ctx, pool, ops)?,
            pool,
        )),
        VecOp::Index => eval_vec_index(node, bx, ctx, pool, ops),
        // A nested `aggregate` used as an array-valued sub-expression — the
        // shape every discretized primitive-equation tendency lowers to:
        // `D(u[i,j,k]) = index(aggregate[i,j,k](…), i, j, k)`. Materialize it
        // ONCE as a whole array over its own box (recursively through this same
        // overlay) and let the enclosing `index(...)` align it. Without this arm
        // the whole rule bailed at its outermost node and the per-cell oracle
        // then re-materialized the ENTIRE nested array once per output cell —
        // an O(N²) walk that dominated the RHS. See [`eval_vec_nested_aggregate`]
        // for the binding-independence precondition that makes hoisting sound.
        VecOp::Aggregate => eval_vec_nested_aggregate(node, bx, ctx, pool, ops),
        VecOp::Makearray => eval_vec_makearray(node, bx, ctx, pool, ops),
        VecOp::Const => match eval_const(node) {
            Value::Scalar(s) => Some(VecValue::Scalar(s)),
            // Array-valued constants are not part of the stencil fast path.
            Value::Array(_) => {
                note_bail(|| "op: array-valued `const`".to_string());
                None
            }
        },
        // Scalar comparisons and `ifelse` over *scalar* operands — the einsum
        // weight idiom `ifelse(k==0,-2,1)` folds to a constant per contraction
        // tuple. Bit-identical to the oracle's `eval_op` (same exact-equality
        // `scalar_compare` and `c != 0.0` branch test). An *array* operand (a
        // per-cell-varying condition) is not on the fast path and bails to the oracle.
        VecOp::Cmp(code) => {
            if node.args.len() != 2 {
                return None;
            }
            // Route through `vec_combine` → `apply_binary`, whose comparison arm
            // IS `scalar_compare` (eval.rs) — so a SCALAR result (the einsum weight
            // idiom `ifelse(k==0,…)`) and a whole-array 0/1 MASK (a per-cell fuel
            // gate `code >= 1`, a regrid `overlap > 0` filter) are both produced
            // bit-identically to the oracle, from the same kernel.
            let a = eval_vec(&node.args[0], bx, ctx, pool, ops)?;
            let b = eval_vec(&node.args[1], bx, ctx, pool, ops)?;
            vec_combine(code, a, b, pool)
        }
        VecOp::Ifelse => {
            if node.args.len() != 3 {
                return None;
            }
            let cond = eval_vec(&node.args[0], bx, ctx, pool, ops)?;
            match cond {
                // Scalar condition: short-circuit to the taken branch, exactly like
                // the oracle (the untaken branch — possibly a NaN-producing lookup —
                // is never evaluated).
                VecValue::Scalar(c) => {
                    if c != 0.0 {
                        eval_vec(&node.args[1], bx, ctx, pool, ops)
                    } else {
                        eval_vec(&node.args[2], bx, ctx, pool, ops)
                    }
                }
                // Array condition (a per-cell mask): evaluate BOTH branches and
                // select elementwise — the whole-array analogue of the oracle's
                // `eval_ifelse` array path. A true select keeps a NaN in the
                // UNCHOSEN branch (an out-of-table lookup) from contaminating the
                // result, matching the oracle.
                cond_arr => {
                    let a = eval_vec(&node.args[1], bx, ctx, pool, ops)?;
                    let b = eval_vec(&node.args[2], bx, ctx, pool, ops)?;
                    vec_select(cond_arr, a, b, pool)
                }
            }
        }
        // Unary transcendentals / rounding + the logical `not` over the whole box
        // — bit-identical to the oracle's `eval_unary` (same `apply_unary` kernel,
        // which handles `not`). Keeping these on the fast path is what lets a
        // level-set / upwind stencil whose speed uses `sqrt`/`abs` (Godunov
        // `|∇φ|`) — or a mask that negates a per-cell predicate — avoid scalarizing.
        VecOp::Unary(code) => {
            if node.args.len() != 1 {
                return None;
            }
            let v = eval_vec(&node.args[0], bx, ctx, pool, ops)?;
            Some(vec_unary(code, v, pool))
        }
        // Elementwise `broadcast(fn; a, b, …)` — the whole-array analogue of
        // `eval_broadcast`, folding operands with the SAME `apply_binary` kernel
        // (via `vec_combine`) in the SAME left-to-right order, so it is
        // bit-identical to the oracle. `vec_combine` returns `None` for a
        // `broadcast_fn` it does not vectorize (e.g. `atan2`), bailing safely.
        VecOp::Broadcast => {
            let code = BinCode::of(node.broadcast_fn.as_deref().unwrap_or("+"));
            let mut it = node.args.iter();
            let first = it.next()?;
            let mut acc = eval_vec(first, bx, ctx, pool, ops)?;
            for a in it {
                let v = eval_vec(a, bx, ctx, pool, ops)?;
                acc = vec_combine(code, acc, v, pool)?;
            }
            Some(acc)
        }
        // Everything else (array-valued ifelse, aggregate, reshape, transpose,
        // concat, `fn` closed-registry calls, atan2, D, …) falls back.
        VecOp::Unsupported => {
            note_bail(|| format!("op: unsupported operator `{}`/{}", node.op, node.args.len()));
            None
        }
    }
}


/// Whether `expr` mentions the variable `name` anywhere (including in an
/// `index` axis position, a nested aggregate body, or a `makearray` region
/// value). Used as a *conservative* dependence test: a false positive only
/// costs the fast path, never correctness.
pub(super) fn expr_mentions(expr: &Expr, name: &str) -> bool {
    match expr {
        Expr::Variable(v) => v == name,
        Expr::Number(_) | Expr::Integer(_) => false,
        Expr::Operator(n) => {
            n.args.iter().any(|a| expr_mentions(a, name))
                || n.expr.as_deref().is_some_and(|e| expr_mentions(e, name))
                || n.filter.as_deref().is_some_and(|e| expr_mentions(e, name))
                || n.lower.as_deref().is_some_and(|e| expr_mentions(e, name))
                || n.upper.as_deref().is_some_and(|e| expr_mentions(e, name))
                || n.values
                    .as_ref()
                    .is_some_and(|vs| vs.iter().any(|e| expr_mentions(e, name)))
        }
    }
}

/// The enclosing binding, if any, that a nested `aggregate` genuinely depends
/// on — the precondition for hoisting it out of the enclosing per-cell loop
/// (see [`eval_vec_nested_aggregate`]). `None` means the hoist is sound.
///
/// An enclosing name that the nested aggregate REBINDS with one of its own
/// binders (its `output_idx` symbols or its contracted indices) is *shadowed*:
/// inside the body and the filter that name denotes the nested aggregate's own
/// index, never the enclosing one, so evaluating the node exactly once over its
/// own box computes precisely what the per-cell oracle computes. The oracle
/// agrees by construction — [`eval_arrayop`] saves and rebinds exactly
/// `idx_names ∪ contract_names` around its body walk (`saved_binds`) — and both
/// whole-array resolvers ([`eval_vec_variable`] and the tape's `resolve_var`)
/// consult the aggregate's own box symbols / contraction binds BEFORE any
/// state, observed or parameter of the same name.
///
/// Every NON-shadowed name still disqualifies the hoist, and that half is
/// load-bearing: the nested box drops the enclosing symbols entirely, so such a
/// name would fall through the resolver ladder and silently rebind to a
/// same-named state/observed/parameter instead of the enclosing index.
///
/// The mention test itself stays syntactic and conservative — a false positive
/// only costs the fast path, never correctness.
pub(super) fn nested_aggregate_capture<'n>(
    spec: &ArrayOpSpec<'_>,
    enclosing: impl Iterator<Item = &'n String>,
) -> Option<&'n String> {
    for name in enclosing {
        // Cheap shadow test first (rank ≤ 4): it also SKIPS the full body walk,
        // which is the dominant cost of this scan on wide stencil templates.
        if spec.idx_names.iter().any(|n| n == name) || spec.contract_names.iter().any(|n| n == name)
        {
            continue;
        }
        if expr_mentions(spec.body, name) || spec.filter.is_some_and(|f| expr_mentions(f, name)) {
            return Some(name);
        }
    }
    None
}

/// Vectorized nested `aggregate`: materialize the sub-array once over the
/// aggregate's OWN index box, through the same [`try_eval_arrayop_vectorized`]
/// entry the per-cell oracle's [`eval_arrayop`] tries first. Because both paths
/// call that one function with parameters derived from the shared
/// [`arrayop_spec`], a success here returns the byte-identical array the oracle
/// would have produced — and a failure returns `None`, leaving the oracle in
/// charge exactly as before.
///
/// PRECONDITION (why hoisting out of the enclosing loop is sound): the oracle
/// re-evaluates this node once per enclosing output tuple, with the enclosing
/// output symbols and contracted indices bound in `ctx.loop_binds`. Evaluating
/// it ONCE is therefore only equivalent when the nested node does not depend on
/// any of those bindings — which is what [`nested_aggregate_capture`] decides,
/// over the enclosing index symbols, the bound contraction names, and every
/// name already in `ctx.loop_binds` (a scalar `eval` walk that reached this
/// overlay from inside a per-cell loop).
fn eval_vec_nested_aggregate<'a>(
    node: &ExpressionNode,
    bx: &VecBox,
    ctx: &EvalCtx<'a>,
    pool: &mut Pool,
    ops: &mut usize,
) -> Option<VecValue<'a>> {
    let spec = match arrayop_spec(node) {
        Some(s) => s,
        None => bail_vec!("aggregate: node carries no `expr` body"),
    };
    if spec.ranges.is_empty() {
        bail_vec!("aggregate: rank-0 output (scalar reduction)");
    }
    if let Some(name) = nested_aggregate_capture(
        &spec,
        bx.syms
            .iter()
            .chain(bx.cnames.iter())
            .chain(ctx.loop_binds.keys()),
    ) {
        bail_vec!(
            "aggregate: nested body depends on an enclosing bound index",
            name
        );
    }
    let (v, sub_ops) = try_eval_arrayop_vectorized(
        spec.idx_names,
        &spec.ranges,
        spec.body,
        &spec.contract_names,
        &spec.contract_dims,
        spec.reduce,
        spec.filter,
        ctx,
        pool,
    )?;
    *ops += sub_ops;
    Some(v)
}

/// The shared scalar-comparison kernel: the per-cell oracle (`apply_binary`,
/// eval.rs) and this vectorized overlay both route through it, so the two paths
/// are bit-identical by construction. `==`/`!=` test EXACT equality with the
/// native `f64` relops (`a == b` / `a != b`) — the pinned cross-binding semantic
/// (Python `np.equal` / `np.not_equal`), including `inf == inf ⇒ true`. The
/// orderings use the native relops too. Result is `1.0` (true) / `0.0` (false).
pub(super) fn scalar_compare(op: &str, a: f64, b: f64) -> f64 {
    let t = match op {
        "==" => a == b,
        "!=" => a != b,
        "<" => a < b,
        "<=" => a <= b,
        ">" => a > b,
        ">=" => a >= b,
        _ => return f64::NAN,
    };
    if t { 1.0 } else { 0.0 }
}

pub(super) fn vec_negate<'a>(v: VecValue<'a>, pool: &mut Pool) -> VecValue<'a> {
    match v {
        VecValue::Scalar(s) => VecValue::Scalar(-s),
        VecValue::Owned { mut data, origin } => {
            data.mapv_inplace(|x| -x);
            VecValue::Owned { data, origin }
        }
        VecValue::View { data, origin } => {
            // The `Zip` writes every element, so no zero-fill on checkout.
            let mut buf = pool.take_array_uninit(data.shape());
            ndarray::Zip::from(&mut buf)
                .and(data)
                .for_each(|o, &x| *o = -x);
            VecValue::Owned { data: buf, origin }
        }
    }
}

/// Vectorized unary transcendental/rounding op — the whole-array analogue of
/// [`eval_unary`], applying the SAME per-element [`apply_unary`] kernel so the
/// result is bit-identical to the per-cell oracle (element-wise maps are
/// order-independent). A `Scalar` stays scalar; an `Owned` buffer is mapped in
/// place (no allocation, ess-mro); a `View` is mapped into a fresh pooled buffer.
/// Lets a stencil whose speed/flux uses `sqrt`/`abs`/`exp`/… (e.g. the level-set
/// Godunov `|∇φ|`) stay on the whole-array fast path instead of scalarizing.
pub(super) fn vec_unary<'a>(op: UnCode, v: VecValue<'a>, pool: &mut Pool) -> VecValue<'a> {
    // The operator name was resolved to `op` once, at the top of `eval_vec_op`;
    // the element loop below runs over the whole output box, and
    // `apply_unary(op, x)` re-matched the name string on every one of those
    // elements. `unary_kernel_of` is pinned bit-identical to `apply_unary`
    // (`unary_kernels_match_apply_unary`), so this is a pure dispatch hoist.
    let f = unary_kernel_of(op);
    match v {
        VecValue::Scalar(s) => VecValue::Scalar(f(s)),
        VecValue::Owned { mut data, origin } => {
            data.mapv_inplace(f);
            VecValue::Owned { data, origin }
        }
        VecValue::View { data, origin } => {
            // The `Zip` writes every element, so no zero-fill on checkout.
            let mut buf = pool.take_array_uninit(data.shape());
            ndarray::Zip::from(&mut buf)
                .and(data)
                .for_each(|o, &x| *o = f(x));
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
pub(super) fn vec_combine<'a>(
    op: BinCode,
    a: VecValue<'a>,
    b: VecValue<'a>,
    pool: &mut Pool,
) -> Option<VecValue<'a>> {
    // The operator NAME was resolved to `op` once per AST node (`vec_op_code`);
    // what is left here is an `f64`-only element loop. `apply_binary(op, …)` was
    // originally called inside the whole-array `Zip`s below, so every element of
    // every kernel node re-matched the name string — `apply_binary` +
    // `__memcmp_evex` were 14% of a vectorized RHS profile, and the string
    // compare also kept the loop scalar.
    //
    // The ops that dominate a stencil get a monomorphized, inlinable closure;
    // everything else uses the shared [`binary_kernel_of`] function pointer
    // (still one dispatch per node rather than per element). Both are pinned
    // bit-identical to `apply_binary` (`binary_kernels_match_apply_binary`), and
    // the element order/association is unchanged, so this is a pure dispatch
    // hoist.
    //
    // `min`/`max` were NOT on the monomorphized list and should have been: they
    // are the hot operators of a monotone PPM limiter, which is most of what
    // simpleclimate's RHS is, and every element went through an indirect `fn`
    // call. Giving them their own arms is measurably the WHOLE win of this
    // change. Retired instructions, `--days 0.05 --samples 2` (878 RHS calls,
    // 27360 state slots), each config built and run identically:
    //
    //     main                               332.93e9   (mean of 4)
    //     op-code dispatch, no `min`/`max`    332.91e9   (neutral)
    //     `min`/`max` monomorphized only      329.60e9   (-1.0%)
    //     both (this commit)                  329.53e9   (-1.0%)
    //
    // `^` is monomorphized on the same principle — through the function-pointer
    // arm every element paid an indirect call before reaching libm's `pow`
    // (`vec_combine_with::{{closure}} -> Fn::call -> pow` in the profile), and
    // `x.powf(y)` is the identical libm entry point, so it is exact — but here
    // it measures NEUTRAL (329.61e9 / 329.52e9 with the arm removed). This
    // model has few `^` NODES even though they cover many elements, so the
    // per-node call overhead it removes is not where the time goes. Kept for
    // the models where `^` is a hot operator, not because it pays on this one.
    match op {
        BinCode::Add => vec_combine_with(|x, y| x + y, a, b, pool),
        BinCode::Sub => vec_combine_with(|x, y| x - y, a, b, pool),
        BinCode::Mul => vec_combine_with(|x, y| x * y, a, b, pool),
        BinCode::Div => vec_combine_with(|x, y| x / y, a, b, pool),
        BinCode::Pow => vec_combine_with(|x: f64, y: f64| x.powf(y), a, b, pool),
        BinCode::Min => vec_combine_with(|x: f64, y: f64| x.min(y), a, b, pool),
        BinCode::Max => vec_combine_with(|x: f64, y: f64| x.max(y), a, b, pool),
        other => vec_combine_with(binary_kernel_of(other), a, b, pool),
    }
}

/// [`vec_combine`] with the elementwise kernel already resolved.
fn vec_combine_with<'a, F: Fn(f64, f64) -> f64>(
    f: F,
    a: VecValue<'a>,
    b: VecValue<'a>,
    pool: &mut Pool,
) -> Option<VecValue<'a>> {
    match (a, b) {
        (VecValue::Scalar(x), VecValue::Scalar(y)) => Some(VecValue::Scalar(f(x, y))),
        // scalar ∘ array
        (VecValue::Scalar(x), barr) => {
            let (mut data, origin) = barr.into_owned(pool);
            data.mapv_inplace(|y| f(x, y));
            Some(VecValue::Owned { data, origin })
        }
        // array ∘ scalar
        (aarr, VecValue::Scalar(y)) => {
            let (mut data, origin) = aarr.into_owned(pool);
            data.mapv_inplace(|x| f(x, y));
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
                            .for_each(|x, &y| *x = f(*x, y));
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
                        .for_each(|bslot, &aval| *bslot = f(aval, *bslot));
                    Some(VecValue::Owned { data, origin })
                }
                // both Views: a fresh pooled buffer.
                (a2, b2) => {
                    let origin: DimI = a2.origin().expect("array origin").iter().copied().collect();
                    let av = a2.view().expect("array operand has a view");
                    let bv = b2.view().expect("array operand has a view");
                    // The `Zip` writes every element, so no zero-fill.
                    let mut buf = pool.take_array_uninit(av.shape());
                    ndarray::Zip::from(&mut buf)
                        .and(&av)
                        .and(&bv)
                        .for_each(|o, &x, &y| *o = f(x, y));
                    Some(VecValue::Owned { data: buf, origin })
                }
            }
        }
    }
}

/// Whole-array `ifelse(cond, a, b)` for an ARRAY condition: `out[k] = cond[k] !=
/// 0 ? a[k] : b[k]`, reusing the SAME `c != 0.0` test as the oracle's
/// `eval_ifelse` array path (bit-identical). `a`/`b` are scalars (broadcast) or
/// arrays over `cond`'s box; a box mismatch releases every operand and bails to
/// the oracle. Also the term-gate for a §5.3 `filter` (`vec_select(mask, term,
/// identity)`), so an excluded combination contributes the reduction identity.
pub(super) fn vec_select<'a>(
    cond: VecValue<'a>,
    a: VecValue<'a>,
    b: VecValue<'a>,
    pool: &mut Pool,
) -> Option<VecValue<'a>> {
    let (cond_data, origin) = cond.into_owned(pool);
    let shp: DimU = cond_data.shape().iter().copied().collect();
    let box_ok = |v: &VecValue| match v.shape() {
        None => true,
        Some(s) => s == &shp[..] && v.origin() == Some(&origin[..]),
    };
    if !box_ok(&a) || !box_ok(&b) {
        pool.give_array(cond_data);
        a.release(pool);
        b.release(pool);
        return None;
    }
    // Materialize scalar branches into box-filled buffers so the select is a
    // single 4-array `Zip` (this runs off the per-step hot path — the once-per-
    // segment regrid / per-cell fuel gate — so the extra fill is not on the
    // steady-state RHS).
    let fill = |v: VecValue<'a>, pool: &mut Pool| -> ArrayD<f64> {
        match v {
            VecValue::Scalar(s) => {
                let mut buf = pool.take_array_uninit(&shp);
                buf.fill(s);
                buf
            }
            other => other.into_owned(pool).0,
        }
    };
    let a_arr = fill(a, pool);
    let b_arr = fill(b, pool);
    // The 4-array `Zip` writes every element of `out`, so no zero-fill.
    let mut out = pool.take_array_uninit(&shp);
    ndarray::Zip::from(&mut out)
        .and(&cond_data)
        .and(&a_arr)
        .and(&b_arr)
        .for_each(|o, &c, &av, &bv| *o = if c != 0.0 { av } else { bv });
    pool.give_array(cond_data);
    pool.give_array(a_arr);
    pool.give_array(b_arr);
    Some(VecValue::Owned { data: out, origin })
}

/// A constant (output-index-independent) `index(...)` axis value: a bound
/// contraction index or an integer literal (or an affine combination of them),
/// which SELECTS a fixed source slice rather than mapping to an output axis. The
/// sentinel `sym` cannot name a real index, so `affine_terms` treats every
/// variable as a contraction bind (constant, coeff 0) or bails — a coeff-0 result
/// is the fixed 1-based index; anything referencing an output symbol is not
/// constant. This is what a conservative-regrid gather `index(A_ij, i, j)` uses
/// for its source-cell axis `i`.
///
/// SUPERSEDED on the hot path by [`classify_axis_role`], which resolves the role
/// and the symbol in one walk; retained as the reference the equivalence test
/// [`axis_classifier_equivalence`] checks the single-walk classifier against.
#[cfg(test)]
fn const_index_value(e: &Expr, bx: &VecBox) -> Option<i64> {
    match affine_terms(e, "\u{0}", bx) {
        Some((0, k)) => Some(k),
        _ => None,
    }
}

/// Vectorized `index(A, e_0, …, e_{n-1})`. Each source axis is classified as
/// either an **output-mapping** axis — an affine shift `sym ± k` or a periodic
/// wrap of the next output symbol ([`classify_axis_index`]) — or a **fixed
/// select**: a constant / bound-contraction index ([`const_index_value`]) that
/// picks one source slice and is consumed. The result rank is the number of
/// mapped axes: `0` mapped ⇒ a scalar (broadcast), else it spans the output box.
///
/// The mapped axes fill the output box in order (a permutation bails). Fixed
/// axes let a conservative-regrid gather vectorize: `index(A_ij, i, j)` (fixed
/// source cell `i`, output target `j`) becomes a whole-column slice, and
/// `index(F_src, i)` (all-fixed) a broadcast scalar — no per-cell walk. An affine
/// axis stays ghost-0 out of bounds (homogeneous Dirichlet), matching the oracle.
pub(super) fn eval_vec_index<'a>(
    node: &ExpressionNode,
    bx: &VecBox,
    ctx: &EvalCtx<'a>,
    pool: &mut Pool,
    ops: &mut usize,
) -> Option<VecValue<'a>> {
    if node.args.is_empty() {
        bail_vec!("index: no arguments");
    }
    let arg0 = eval_vec(&node.args[0], bx, ctx, pool, ops)?;
    let n = node.args.len() - 1;
    // `index(scalar)` with a single arg is the identity; a scalar is otherwise
    // not indexable on the fast path.
    if arg0.shape().is_none() {
        return match arg0 {
            VecValue::Scalar(s) if n == 0 => Some(VecValue::Scalar(s)),
            _ => {
                note_bail(|| format!("index: base is a scalar but {n} index args given"));
                None
            }
        };
    }
    let src_ndim = arg0.shape().expect("array").len();
    if n != src_ndim {
        arg0.release(pool);
        bail_vec!(
            "index: arg count != source rank",
            format!("{n} args vs rank {src_ndim}")
        );
    }
    let src_origin: DimI = arg0
        .origin()
        .expect("array origin")
        .iter()
        .copied()
        .collect();
    let src_shape: DimU = arg0.shape().expect("array").iter().copied().collect();
    let out_ndim = bx.shape.len();

    // Classify each source axis. `mapped[a] = Some((src_axis, AxisIndex))` says
    // output axis `a` is filled by that source axis; `mapped[a] = None` says the
    // source does not depend on output axis `a` at all and is BROADCAST along it.
    // `fixed = (src_axis, 0-based index)` is a slice selected by a constant /
    // bound-contraction index and consumed.
    //
    // Each source axis is tried against every not-yet-claimed output symbol, not
    // just the next one in order, so `index(coslat, j)` inside an `(i, j, k)` box
    // maps to output axis 1 (and broadcasts over 0 and 2), and `index(A, j, i)`
    // is a transpose rather than a bail. The classification is unambiguous: a
    // constant / bound-contraction axis has affine coefficient 0 in every symbol
    // and so never classifies as a map, and an expression affine in `sym` with
    // coefficient 1 mentions no other output symbol (`affine_terms` returns
    // `None` for an unbound one) — so the search cannot claim the wrong symbol,
    // and for an in-order gather it picks exactly the axes the previous
    // next-symbol-only rule did.
    let mut mapped: SmallVec<[Option<(usize, AxisIndex)>; 4]> =
        (0..out_ndim).map(|_| None).collect();
    let mut n_mapped = 0usize;
    let mut fixed: SmallVec<[(usize, i64); 4]> = SmallVec::new();
    let mut any_fixed_oob = false;
    for d in 0..n {
        let e = &node.args[1 + d];
        // ONE walk of the axis expression resolves both which output symbol it
        // maps (if any) and the shift/wrap — see [`classify_axis_role`] for why
        // that is arm-for-arm the same answer the former per-candidate-symbol
        // search produced.
        match classify_axis_role(e, bx) {
            Some(AxisRole::Map { out_axis, ax }) if mapped[out_axis].is_none() => {
                mapped[out_axis] = Some((d, ax));
                n_mapped += 1;
            }
            Some(AxisRole::Const(idx1)) => {
                let i0 = idx1 - src_origin[d];
                if i0 < 0 || i0 >= src_shape[d] as i64 {
                    any_fixed_oob = true;
                    fixed.push((d, 0));
                } else {
                    fixed.push((d, i0));
                }
            }
            // Either unclassifiable, or affine in an output symbol another
            // source axis already claimed (a repeated index — a diagonal
            // gather, which is not a whole-array slice) → oracle.
            _ => {
                arg0.release(pool);
                bail_vec!(
                    "index: axis expression is neither an affine/wrap map of an unclaimed output symbol nor a constant select",
                    format!(
                        "axis {d} = {} (unclaimed output syms = {:?})",
                        describe_expr(e),
                        (0..out_ndim)
                            .filter(|a| mapped[*a].is_none())
                            // `.get`, not `[a]`: a box with no output-index
                            // symbols at all (a top-level `makearray`, whose
                            // region values are self-contained arrays) is
                            // legal, and a diagnostic must not panic on it.
                            .map(|a| bx.syms.get(a).map(|s| s.as_str()).unwrap_or("<none>"))
                            .collect::<Vec<_>>()
                    )
                );
            }
        }
    }

    // A fixed axis out of bounds ⇒ every read is the Dirichlet ghost 0.
    if any_fixed_oob {
        arg0.release(pool);
        return Some(if n_mapped == 0 {
            VecValue::Scalar(0.0)
        } else {
            VecValue::Owned {
                data: pool.take_array(bx.shape),
                origin: bx.lo.iter().copied().collect(),
            }
        });
    }

    // All-fixed ⇒ a single source element, broadcast as a scalar.
    if n_mapped == 0 {
        let mut idx = DimU::from_elem(0usize, n);
        for &(d, i0) in &fixed {
            idx[d] = i0 as usize;
        }
        let v = arg0.view().expect("array")[IxDyn(&idx[..])];
        arg0.release(pool);
        return Some(VecValue::Scalar(v));
    }

    // Per output axis, build the source→output copy segments `(out_off, len,
    // src_off)` (all 0-based) from the mapped axis's affine shift / periodic wrap.
    // Built before the reduced view `rv` so an out-of-bounds / non-roll bail can
    // release `arg0` without a live borrow.
    let mut axis_segs: SmallVec<[SmallVec<[(usize, usize, usize); 2]>; 4]> = SmallVec::new();
    for a in 0..out_ndim {
        // An output axis the source does not index is broadcast: one full-extent
        // segment reading the same (length-1, stride-0) source position for every
        // output position — exactly what the oracle does when the per-cell
        // `index(...)` simply never mentions that loop symbol.
        let Some((orig_d, ax)) = &mapped[a] else {
            let mut segs = SmallVec::new();
            segs.push((0usize, bx.shape[a], 0usize));
            axis_segs.push(segs);
            continue;
        };
        let so = src_origin[*orig_d];
        let ssz = src_shape[*orig_d] as i64;
        match ax {
            AxisIndex::Affine(k) => {
                let k = *k;
                // output position p (0-based) → symbol bx.lo[a]+p → source 1-based
                // bx.lo[a]+p+k → source 0-based −so; in-bounds when
                // 0 ≤ bx.lo[a]+p+k−so ≤ ssz−1.
                let lo_p = (so - bx.lo[a] - k).max(0);
                let hi_p = (so + ssz - bx.lo[a] - k).min(bx.shape[a] as i64); // exclusive
                if lo_p >= hi_p {
                    // Entirely out of bounds ⇒ the whole result is ghost-0.
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
                    (bx.lo[a] + lo_p + k - so) as usize,
                ));
                axis_segs.push(segs);
            }
            AxisIndex::Wrap { k, period } => {
                let (k, period) = (*k, *period);
                // A roll requires the source axis to be the full period.
                if so != bx.lo[a] || ssz != period || bx.shape[a] as i64 != period {
                    arg0.release(pool);
                    bail_vec!(
                        "index: periodic wrap axis is not a full-period roll",
                        format!(
                            "src_origin={so} src_extent={ssz} period={period}                              out_lo={} out_extent={}",
                            bx.lo[a], bx.shape[a]
                        )
                    );
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
        }
    }

    // Reduce the source to just the mapped axes: select each fixed axis at its
    // index (descending axis order so the lower axis indices stay valid).
    let mut fixed_desc: SmallVec<[(usize, usize); 4]> =
        fixed.iter().map(|&(d, i0)| (d, i0 as usize)).collect();
    fixed_desc.sort_by(|a, b| b.0.cmp(&a.0));
    let mut rv = arg0.view().expect("array");
    for (d, i0) in fixed_desc {
        rv = rv.index_axis_move(ndarray::Axis(d), i0);
    }
    // `rv` now holds the mapped source axes in ascending SOURCE-axis order.
    // Permute them into output-axis order (a transposing gather), then splice in
    // a length-1 axis at each broadcast output axis, so `rv` has `out_ndim` axes
    // aligned with the output box.
    let mut mapped_src: SmallVec<[usize; 4]> = mapped.iter().flatten().map(|(d, _)| *d).collect();
    mapped_src.sort_unstable();
    // A `SmallVec` (and `IxDyn` over its slice, whose repr inlines up to 4 axes),
    // not a `Vec` — this runs once per `index(...)` node of every RHS evaluation
    // and the steady-state RHS must not allocate (ess-mro, `pde_zero_alloc`).
    let perm: SmallVec<[usize; 4]> = (0..out_ndim)
        .filter_map(|a| mapped[a].as_ref())
        .map(|(d, _)| {
            mapped_src
                .iter()
                .position(|s| s == d)
                .expect("mapped source axis is in mapped_src")
        })
        .collect();
    let mut rv = rv.permuted_axes(IxDyn(&perm[..]));
    for a in 0..out_ndim {
        if mapped[a].is_none() {
            rv = rv.insert_axis(ndarray::Axis(a));
        }
    }
    // Stretch the length-1 broadcast axes to the output extent. Every other axis
    // keeps its own extent, so this only ever adds stride-0 axes.
    let bshape: DimU = (0..out_ndim)
        .map(|a| {
            if mapped[a].is_some() {
                rv.shape()[a]
            } else {
                bx.shape[a]
            }
        })
        .collect();
    let rvb = match rv.broadcast(IxDyn(&bshape[..])) {
        Some(v) => v,
        None => {
            drop(rv);
            arg0.release(pool);
            bail_vec!("index: broadcast to the output box failed");
        }
    };

    // Copy every cartesian combination of per-axis segments from the reduced
    // source `rvb` into the zero-filled pooled buffer (ghost positions keep 0).
    let mut result = pool.take_array(bx.shape);
    {
        let mut pick = DimU::from_elem(0usize, out_ndim);
        loop {
            {
                let mut out_view = result.slice_each_axis_mut(|ax| {
                    let d = ax.axis.index();
                    let (o, l, _) = axis_segs[d][pick[d]];
                    Slice::from(o..o + l)
                });
                let src_sub = rvb.slice_each_axis(|ax| {
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
                if d == out_ndim {
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
    drop(rvb);
    drop(rv);
    arg0.release(pool);
    Some(VecValue::Owned {
        data: result,
        origin: bx.lo.iter().copied().collect(),
    })
}

/// Vectorized makearray: materialize each region as a whole-array sub-range
/// write over the region's box (last region wins), reusing the enclosing output
/// symbols. Returns an array spanning the union bounding box.
pub(super) fn eval_vec_makearray<'a>(
    node: &ExpressionNode,
    bx: &VecBox,
    ctx: &EvalCtx<'a>,
    pool: &mut Pool,
    ops: &mut usize,
) -> Option<VecValue<'a>> {
    let regions = match node.regions.as_ref() {
        Some(r) => r,
        None => bail_vec!("makearray: no `regions`"),
    };
    let values = match node.values.as_ref() {
        Some(v) => v,
        None => bail_vec!("makearray: no `values`"),
    };
    if regions.is_empty() || values.len() != regions.len() {
        bail_vec!("makearray: empty or mismatched regions/values");
    }
    let ndim = regions[0].len();
    if ndim != bx.shape.len() {
        bail_vec!(
            "makearray: region rank != output box rank",
            format!("{ndim} vs {}", bx.shape.len())
        );
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
        // ess-cse: a region has its own `lo`/extent, so a coordinate ramp and
        // every shifted gather mean something different in it — a distinct box,
        // and so a distinct CSE scope.
        let _cse_scope = ctx.cse.map(|rt| rt.scope(pool));
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
pub(super) enum AxisIndex {
    /// `sym ± k` with unit coefficient and a constant integer offset `k`
    /// (bound contraction indices folded in): a shifted slice. Out-of-extent
    /// positions stay ghost-0 (homogeneous Dirichlet).
    Affine(i64),
    /// Periodic wrap of base offset `k` over an axis of period `period`: a
    /// cyclic roll, no ghost. See [`parse_wrap_axis_any`] for the recognized
    /// idiom.
    Wrap { k: i64, period: i64 },
}

/// Classify one `index` axis expression AGAINST A GIVEN SYMBOL: affine shift
/// first (the common stencil/ghost case), then the periodic-wrap idiom. `None`
/// for anything else, so the caller bails to the per-cell oracle.
///
/// SUPERSEDED on the hot path by [`classify_axis_role`] (one walk for the whole
/// box instead of one per candidate symbol); retained as the reference the
/// equivalence test [`axis_classifier_equivalence`] checks against.
#[cfg(test)]
pub(super) fn classify_axis_index(expr: &Expr, sym: &str, bx: &VecBox) -> Option<AxisIndex> {
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
pub(super) fn affine_offset_in(expr: &Expr, sym: &str, bx: &VecBox) -> Option<i64> {
    let (coeff, konst) = affine_terms(expr, sym, bx)?;
    if coeff == 1 { Some(konst) } else { None }
}

/// Equality for the short symbol names an index expression is resolved against
/// (`i`, `j`, `k`, `_lp0`, …).
///
/// The generic `str` comparison emits a `memcmp` CALL, and axis classification
/// performs one per variable leaf per candidate symbol — `__memcmp_evex` was
/// 5% of a vectorized RHS profile, over half of it under `affine_terms`. The
/// length test rejects almost every non-match without touching the bytes, and
/// the residual byte loop is inline.
#[inline(always)]
fn sym_eq(a: &str, b: &str) -> bool {
    let (x, y) = (a.as_bytes(), b.as_bytes());
    x.len() == y.len() && x.iter().zip(y).all(|(p, q)| p == q)
}

/// Which role one `index(...)` axis expression plays, resolved in a SINGLE walk
/// of that expression ([`classify_axis_role`]).
pub(super) enum AxisRole {
    /// Maps output axis `out_axis` through `ax` (affine shift or periodic wrap).
    Map { out_axis: usize, ax: AxisIndex },
    /// Output-index-independent: selects the fixed 1-based source index.
    Const(i64),
}

/// Classify one `index(...)` axis expression against the WHOLE output box in a
/// single walk: which output symbol (if any) it is affine in, and with what
/// shift — or that it is a constant select.
///
/// [`eval_vec_index`] used to ask [`classify_axis_index`] once per (source axis
/// × not-yet-claimed output symbol) pair and then [`const_index_value`] once
/// more, so a rank-3 box re-walked the same axis expression up to four times,
/// each walk comparing every variable leaf against one candidate name. That
/// re-derivation was ~9% of a vectorized RHS profile (`affine_terms`), and it is
/// the same answer every RHS call. Resolving the symbol *from* the expression
/// instead of guessing it does one walk regardless of rank.
///
/// Equivalent to the old search, arm for arm:
///   * an expression affine in `syms[a]` with unit coefficient mentions no other
///     output symbol (the old walk returned `None` the moment it met an unbound
///     one), so the old search could only ever have claimed `a` — and it stopped
///     at the first success, which is that one;
///   * an expression affine in an ALREADY-claimed symbol failed for every other
///     candidate and then failed `const_index_value` too (a bare output symbol
///     is not a bound contraction index), i.e. it bailed — as it does here;
///   * a wrap expression is an `ifelse`, for which the affine walk returns
///     `None`, so trying affine first and wrap second is order-independent;
///   * a constant / bound-contraction axis has coefficient 0 in every symbol, so
///     it never classified as a map under either rule.
pub(super) fn classify_axis_role(expr: &Expr, bx: &VecBox) -> Option<AxisRole> {
    if let Some((sym, coeff, konst)) = affine_terms_any(expr, bx) {
        return match (sym, coeff) {
            (Some(out_axis), 1) => Some(AxisRole::Map {
                out_axis,
                ax: AxisIndex::Affine(konst),
            }),
            // No output symbol and no coefficient: a fixed source slice.
            (None, 0) => Some(AxisRole::Const(konst)),
            // Affine in a symbol but not with unit coefficient (`2i`, `i - i`):
            // not a shifted slice and not a constant → oracle.
            _ => None,
        };
    }
    parse_wrap_axis_any(expr, bx).map(|(out_axis, ax)| AxisRole::Map { out_axis, ax })
}

/// [`affine_terms`] with the symbol RESOLVED FROM the expression rather than
/// supplied: reduce `expr` to `(output-symbol axis, coeff, constant)` over the
/// integers, folding bound contraction indices and integer literals. A variable
/// leaf resolves to an output symbol if it names one, else to its bound
/// contraction value, else the whole expression is not affine (`None`).
///
/// `None` also for any non-integer, nonlinear (sym·sym) or MULTI-symbol
/// construct (`i + j`) — the per-symbol walk it replaces likewise returned
/// `None` for every candidate there, because the other symbol was unbound.
pub(super) fn affine_terms_any(expr: &Expr, bx: &VecBox) -> Option<(Option<usize>, i64, i64)> {
    // Merge two sub-results: at most one distinct output symbol may appear.
    #[inline]
    fn join(a: Option<usize>, b: Option<usize>) -> Option<Option<usize>> {
        match (a, b) {
            (None, s) | (s, None) => Some(s),
            (Some(x), Some(y)) if x == y => Some(Some(x)),
            _ => None, // two different output symbols — not affine in one axis
        }
    }
    match expr {
        Expr::Integer(n) => Some((None, 0, *n)),
        Expr::Number(n) if n.fract() == 0.0 => Some((None, 0, *n as i64)),
        Expr::Number(_) => None,
        Expr::Variable(v) => {
            if let Some(a) = bx.syms.iter().position(|s| sym_eq(s, v)) {
                Some((Some(a), 1, 0))
            } else {
                bx.cbind(v).map(|k| (None, 0, k))
            }
        }
        Expr::Operator(node) => match node.op.as_str() {
            "+" => {
                let mut sym = None;
                let mut coeff = 0i64;
                let mut konst = 0i64;
                for a in &node.args {
                    let (s, c, k) = affine_terms_any(a, bx)?;
                    sym = join(sym, s)?;
                    coeff = coeff.checked_add(c)?;
                    konst = konst.checked_add(k)?;
                }
                Some((sym, coeff, konst))
            }
            "-" if node.args.len() == 2 => {
                let (s0, c0, k0) = affine_terms_any(&node.args[0], bx)?;
                let (s1, c1, k1) = affine_terms_any(&node.args[1], bx)?;
                Some((join(s0, s1)?, c0.checked_sub(c1)?, k0.checked_sub(k1)?))
            }
            "-" | "neg" if node.args.len() == 1 => {
                let (s, c, k) = affine_terms_any(&node.args[0], bx)?;
                Some((s, c.checked_neg()?, k.checked_neg()?))
            }
            "*" => {
                // Linear ⇒ at most one factor carries a symbol; the others must
                // be integer constants. `(c·sym + k)·M = (c·M)·sym + (k·M)`.
                let mut sym_factor: Option<(Option<usize>, i64, i64)> = None;
                let mut m: i64 = 1;
                for a in &node.args {
                    let (s, c, k) = affine_terms_any(a, bx)?;
                    if c != 0 {
                        if sym_factor.is_some() {
                            return None; // sym·sym — nonlinear
                        }
                        sym_factor = Some((s, c, k));
                    } else {
                        // A coefficient factor that itself mentions a symbol
                        // (`(i - i)·u`) is not linear in that symbol; the
                        // per-symbol walk folded it to the constant 0 with the
                        // symbol already accounted, so keep the same reading:
                        // only its constant part multiplies.
                        if s.is_some() {
                            return None;
                        }
                        m = m.checked_mul(k)?;
                    }
                }
                match sym_factor {
                    Some((s, c, k)) => Some((s, c.checked_mul(m)?, k.checked_mul(m)?)),
                    None => Some((None, 0, m)),
                }
            }
            _ => None,
        },
    }
}

/// [`parse_wrap_axis`] with the symbol resolved from the expression: the wrapped
/// `inner` decides which output axis the roll applies to, and every other branch
/// of the idiom must agree with it. See [`classify_axis_role`] for why deriving
/// the symbol matches the old per-candidate search exactly.
pub(super) fn parse_wrap_axis_any(expr: &Expr, bx: &VecBox) -> Option<(usize, AxisIndex)> {
    /// `expr` must be `1·syms[a] + k`; returns `k`. Mirrors
    /// [`affine_offset_in`]'s unit-coefficient requirement.
    fn offset_in_axis(expr: &Expr, a: usize, bx: &VecBox) -> Option<i64> {
        match affine_terms_any(expr, bx)? {
            (Some(s), 1, k) if s == a => Some(k),
            _ => None,
        }
    }
    let outer = as_op(expr, "ifelse", 3)?;
    // cond1: inner < lo  →  then1: inner + P
    let (lt_lhs, lo_bound) = as_cmp_const(&outer.args[0], "<")?;
    let (sym, coeff, k) = affine_terms_any(lt_lhs, bx)?;
    let a = sym?;
    if coeff != 1 {
        return None;
    }
    let p1 = offset_in_axis(&outer.args[1], a, bx)?.checked_sub(k)?;
    // else1: ifelse(inner > hi, inner − P, inner)
    let inner_if = as_op(&outer.args[2], "ifelse", 3)?;
    let (gt_lhs, hi_bound) = as_cmp_const(&inner_if.args[0], ">")?;
    if offset_in_axis(gt_lhs, a, bx)? != k {
        return None;
    }
    let p2 = k.checked_sub(offset_in_axis(&inner_if.args[1], a, bx)?)?;
    if offset_in_axis(&inner_if.args[2], a, bx)? != k {
        return None; // the fall-through branch must be the bare `inner`
    }
    let period = hi_bound.checked_sub(lo_bound)?.checked_add(1)?;
    if p1 != period || p2 != period || period <= 0 {
        return None;
    }
    Some((a, AxisIndex::Wrap { k, period }))
}

/// Reduce `expr` to `(coeff_of_sym, constant)` over the integers, folding bound
/// contraction indices and integer literals. `None` for any non-integer or
/// nonlinear (sym·sym) construct.
pub(super) fn affine_terms(expr: &Expr, sym: &str, bx: &VecBox) -> Option<(i64, i64)> {
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
///
/// SUPERSEDED on the hot path by [`parse_wrap_axis_any`]; retained as the
/// reference for [`axis_classifier_equivalence`].
#[cfg(test)]
pub(super) fn parse_wrap_axis(expr: &Expr, sym: &str, bx: &VecBox) -> Option<AxisIndex> {
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
pub(super) fn as_op<'e>(expr: &'e Expr, op: &str, arity: usize) -> Option<&'e ExpressionNode> {
    match expr {
        Expr::Operator(node) if node.op == op && node.args.len() == arity => Some(node),
        _ => None,
    }
}

/// Match `inner <op> <int-const>` (the comparison shape used inside the wrap
/// idiom), returning `(&inner, const)`.
pub(super) fn as_cmp_const<'e>(expr: &'e Expr, op: &str) -> Option<(&'e Expr, i64)> {
    let node = as_op(expr, op, 2)?;
    let c = match &node.args[1] {
        Expr::Integer(n) => *n,
        Expr::Number(n) if n.fract() == 0.0 => *n as i64,
        _ => return None,
    };
    Some((&node.args[0], c))
}

#[cfg(test)]
mod axis_classifier_equivalence {
    //! [`classify_axis_role`] resolves an `index(...)` axis expression's role in
    //! ONE walk, where [`eval_vec_index`] used to try [`classify_axis_index`]
    //! against each not-yet-claimed output symbol in turn and then
    //! [`const_index_value`]. The replacement rests on an argument (an
    //! expression affine in one output symbol cannot classify against any
    //! other), not on the compiler — so pin it: over a corpus of axis
    //! expressions and every subset of already-claimed output axes, the two
    //! classifiers must agree exactly.
    use super::*;
    use serde_json::json;

    fn ex(v: serde_json::Value) -> Expr {
        serde_json::from_value(v).expect("axis expression deserializes")
    }

    /// A comparable rendering of a classification outcome.
    #[derive(Debug, PartialEq, Eq)]
    enum Role {
        Affine(usize, i64),
        Wrap(usize, i64, i64),
        Const(i64),
        Bail,
    }

    fn from_axis(a: usize, ax: &AxisIndex) -> Role {
        match ax {
            AxisIndex::Affine(k) => Role::Affine(a, *k),
            AxisIndex::Wrap { k, period } => Role::Wrap(a, *k, *period),
        }
    }

    /// The superseded search: try each UNCLAIMED output symbol in order
    /// (affine, then wrap), then fall back to a constant select.
    fn old_role(e: &Expr, bx: &VecBox, claimed: &[bool]) -> Role {
        let hit = (0..bx.syms.len()).find_map(|a| {
            if claimed[a] {
                return None;
            }
            classify_axis_index(e, &bx.syms[a], bx).map(|ax| from_axis(a, &ax))
        });
        match hit {
            Some(r) => r,
            None => match const_index_value(e, bx) {
                Some(k) => Role::Const(k),
                None => Role::Bail,
            },
        }
    }

    /// The single-walk classifier, read through [`eval_vec_index`]'s own
    /// acceptance rule (a map onto an already-claimed axis is a bail).
    fn new_role(e: &Expr, bx: &VecBox, claimed: &[bool]) -> Role {
        match classify_axis_role(e, bx) {
            Some(AxisRole::Map { out_axis, ax }) if !claimed[out_axis] => from_axis(out_axis, &ax),
            Some(AxisRole::Const(k)) => Role::Const(k),
            _ => Role::Bail,
        }
    }

    /// `ifelse(inner < lo, inner + P, ifelse(inner > hi, inner - P, inner))`.
    fn wrap(inner: serde_json::Value, lo: i64, hi: i64) -> serde_json::Value {
        let p = hi - lo + 1;
        json!({"op": "ifelse", "args": [
            {"op": "<", "args": [inner, lo]},
            {"op": "+", "args": [inner, p]},
            {"op": "ifelse", "args": [
                {"op": ">", "args": [inner, hi]},
                {"op": "-", "args": [inner, p]},
                inner
            ]}
        ]})
    }

    #[test]
    fn single_walk_classifier_matches_the_per_symbol_search() {
        let syms: Vec<String> = ["i", "j", "k"].iter().map(|s| s.to_string()).collect();
        let cnames: Vec<String> = ["m", "n"].iter().map(|s| s.to_string()).collect();
        let lo = [1i64, 1, 1];
        let shape = [4usize, 5, 6];
        let cvals = [2i64, -1];
        let bx = VecBox {
            syms: &syms,
            lo: &lo,
            shape: &shape,
            cnames: &cnames,
            cvals: &cvals,
        };

        let cases: Vec<serde_json::Value> = vec![
            // Bare output symbols, each axis.
            json!("i"),
            json!("j"),
            json!("k"),
            // Affine shifts, both signs, both spellings of the offset.
            json!({"op": "+", "args": ["i", 1]}),
            json!({"op": "-", "args": ["i", 1]}),
            json!({"op": "+", "args": ["j", 3]}),
            json!({"op": "-", "args": ["k", 2]}),
            json!({"op": "+", "args": ["k", -2]}),
            json!({"op": "+", "args": [{"op": "-", "args": ["j", 1]}, 4]}),
            json!({"op": "neg", "args": [{"op": "neg", "args": ["j"]}]}),
            // Bound contraction indices: constants, and folded into a shift.
            json!("m"),
            json!("n"),
            json!({"op": "+", "args": ["i", "m"]}),
            json!({"op": "+", "args": [{"op": "+", "args": ["k", 1]}, "n"]}),
            json!({"op": "*", "args": ["m", 3]}),
            json!({"op": "-", "args": ["m", "n"]}),
            // Literal selects.
            json!(1),
            json!(7),
            json!(2.0),
            json!({"op": "+", "args": [2, 3]}),
            json!({"op": "*", "args": [2, {"op": "+", "args": [3, 1]}]}),
            // Non-unit coefficient / cancelling / multi-symbol / nonlinear.
            json!({"op": "*", "args": [2, "i"]}),
            json!({"op": "-", "args": ["i", "i"]}),
            json!({"op": "+", "args": ["i", "j"]}),
            json!({"op": "-", "args": ["k", "i"]}),
            json!({"op": "*", "args": ["i", "j"]}),
            json!({"op": "*", "args": ["i", "m"]}),
            // Not integer-affine at all.
            json!(2.5),
            json!("q"),
            json!({"op": "+", "args": ["i", "q"]}),
            json!({"op": "/", "args": ["i", 2]}),
            json!({"op": "sin", "args": ["i"]}),
            // Periodic wrap, on each axis, plus malformed variants.
            wrap(json!({"op": "-", "args": ["i", 1]}), 1, 4),
            wrap(json!({"op": "+", "args": ["i", 1]}), 1, 4),
            wrap(json!("j"), 1, 5),
            wrap(json!({"op": "+", "args": ["k", 2]}), 1, 6),
            wrap(json!({"op": "+", "args": ["i", "m"]}), 1, 4),
            wrap(json!({"op": "*", "args": [2, "i"]}), 1, 4),
            wrap(json!({"op": "+", "args": ["i", "j"]}), 1, 4),
            wrap(json!(3), 1, 4),
            // A wrap whose two branches disagree on the period.
            json!({"op": "ifelse", "args": [
                {"op": "<", "args": ["i", 1]},
                {"op": "+", "args": ["i", 4]},
                {"op": "ifelse", "args": [
                    {"op": ">", "args": ["i", 4]},
                    {"op": "-", "args": ["i", 3]},
                    "i"
                ]}
            ]}),
            // A wrap whose fall-through branch is not the bare inner.
            json!({"op": "ifelse", "args": [
                {"op": "<", "args": ["i", 1]},
                {"op": "+", "args": ["i", 4]},
                {"op": "ifelse", "args": [
                    {"op": ">", "args": ["i", 4]},
                    {"op": "-", "args": ["i", 4]},
                    {"op": "+", "args": ["i", 1]}
                ]}
            ]}),
        ];

        for case in &cases {
            let e = ex(case.clone());
            // Every subset of already-claimed output axes, so the "claimed
            // symbol ⇒ bail" reading is exercised in both directions.
            for mask in 0u32..8 {
                let claimed = [mask & 1 != 0, mask & 2 != 0, mask & 4 != 0];
                let old = old_role(&e, &bx, &claimed);
                let new = new_role(&e, &bx, &claimed);
                assert_eq!(
                    old, new,
                    "axis expression {case} with claimed={claimed:?}: \
                     per-symbol search says {old:?}, single walk says {new:?}"
                );
            }
        }
    }

    /// The same corpus against a rank-1 box with no contraction binds — the
    /// shape the 1-D stencil fixtures use, where the search had only one
    /// candidate symbol and so was already minimal.
    #[test]
    fn single_walk_classifier_matches_on_a_rank_1_box() {
        let syms: Vec<String> = vec!["i".to_string()];
        let lo = [1i64];
        let shape = [8usize];
        let bx = VecBox {
            syms: &syms,
            lo: &lo,
            shape: &shape,
            cnames: &[],
            cvals: &[],
        };
        let cases: Vec<serde_json::Value> = vec![
            json!("i"),
            json!({"op": "+", "args": ["i", 1]}),
            json!({"op": "-", "args": ["i", 1]}),
            json!(3),
            json!("k"),
            json!({"op": "*", "args": [2, "i"]}),
            wrap(json!({"op": "-", "args": ["i", 1]}), 1, 8),
        ];
        for case in &cases {
            let e = ex(case.clone());
            for mask in 0u32..2 {
                let claimed = [mask & 1 != 0];
                assert_eq!(
                    old_role(&e, &bx, &claimed),
                    new_role(&e, &bx, &claimed),
                    "axis expression {case} with claimed={claimed:?}"
                );
            }
        }
    }
}

#[cfg(test)]
mod op_dispatch_equivalence {
    //! [`eval_vec_op`] used to select its arm by matching the operator NAME
    //! against a chain of string patterns; it now resolves the name once with
    //! [`vec_op_code`] and matches on the resulting [`VecOp`]. An
    //! operator-dispatch rework is exactly the kind of change that silently
    //! drops an arm — a dropped operator would not fail loudly, it would merely
    //! bail to the per-cell oracle and make the model slower — so pin the
    //! mapping against a literal transcription of the pattern lists the match
    //! arms used to carry.
    use super::*;

    /// The `match node.op.as_str()` arm lists, verbatim from the pre-refactor
    /// `eval_vec_op` (git 1a96da9a), in arm order.
    #[rustfmt::skip]
    const ARITH: &[&str] = &["+", "-", "*", "/", "^", "min", "max", "atan2", "and", "or"];
    #[rustfmt::skip]
    const CMP: &[&str] = &["==", "!=", "<", "<=", ">", ">="];
    #[rustfmt::skip]
    const UNARY: &[&str] = &[
        "exp", "log", "ln", "log10", "sqrt", "abs", "sign", "floor", "ceil", "sin",
        "cos", "tan", "asin", "acos", "atan", "sinh", "cosh", "tanh", "asinh",
        "acosh", "atanh", "not",
    ];

    /// Every operator the old arm list routed somewhere lands in the same arm
    /// now, and its kernel code resolves to the same element kernel the per-cell
    /// oracle uses (`binary_kernel`/`unary_kernel` delegate to the `*_of`
    /// tables, which `binary_kernels_match_apply_binary` /
    /// `unary_kernels_match_apply_unary` pin to `apply_binary`/`apply_unary`).
    #[test]
    fn vec_op_code_matches_the_dispatch_arms() {
        for op in ARITH {
            assert_eq!(
                vec_op_code(op),
                VecOp::Arith(BinCode::of(op)),
                "arithmetic operator `{op}` lost its arm"
            );
            assert_ne!(BinCode::of(op), BinCode::Unknown, "`{op}` has no kernel");
        }
        for op in CMP {
            assert_eq!(
                vec_op_code(op),
                VecOp::Cmp(BinCode::of(op)),
                "comparison operator `{op}` lost its arm"
            );
            assert_ne!(BinCode::of(op), BinCode::Unknown, "`{op}` has no kernel");
        }
        for op in UNARY {
            assert_eq!(
                vec_op_code(op),
                VecOp::Unary(UnCode::of(op)),
                "unary operator `{op}` lost its arm"
            );
            assert_ne!(UnCode::of(op), UnCode::Unknown, "`{op}` has no kernel");
        }
        assert_eq!(vec_op_code("neg"), VecOp::Neg);
        assert_eq!(vec_op_code("index"), VecOp::Index);
        assert_eq!(vec_op_code("aggregate"), VecOp::Aggregate);
        assert_eq!(vec_op_code("makearray"), VecOp::Makearray);
        assert_eq!(vec_op_code("const"), VecOp::Const);
        assert_eq!(vec_op_code("ifelse"), VecOp::Ifelse);
        assert_eq!(vec_op_code("broadcast"), VecOp::Broadcast);
    }

    /// The catch-all arm: everything the overlay never vectorized must still
    /// bail, so the per-cell oracle stays in charge of it. A code accidentally
    /// added here would route an unsupported construct into a kernel arm.
    #[test]
    fn unvectorized_operators_still_bail() {
        #[rustfmt::skip]
        const OTHERS: &[&str] = &[
            "D", "Pre", "fn", "arrayop", "reshape", "transpose", "concat",
            "intersect_polygon", "polygon_intersection_area", "integral", "grad",
            "skolem", "rank", "ic", "table_lookup", "apply_expression_template",
            "", " ", "PLUS", "Log", "expp",
        ];
        for op in OTHERS {
            assert_eq!(
                vec_op_code(op),
                VecOp::Unsupported,
                "operator `{op}` must fall back to the per-cell oracle"
            );
        }
    }

    /// The CSE classifier's box-transparency allowlist is documented as being
    /// "kept in lockstep with `eval_vec_op`". Make that mechanical: every op it
    /// declares transparent must actually have a dispatch arm here, or the CSE
    /// pass would keep a node's children in the enclosing scope for a node the
    /// evaluator never even descends into.
    #[test]
    fn cse_box_transparent_ops_all_have_a_dispatch_arm() {
        for op in super::super::cse::BOX_TRANSPARENT_OPS {
            assert_ne!(
                vec_op_code(op),
                VecOp::Unsupported,
                "`{op}` is CSE-box-transparent but has no `eval_vec_op` arm"
            );
        }
    }

    /// Both directions: the two ops `eval_vec_op` handles that OPEN a box
    /// (`aggregate`, `makearray`) must stay off the transparency list, and
    /// nothing else with an arm may be missing from it.
    #[test]
    fn every_box_transparent_dispatch_arm_is_listed() {
        let listed = |op: &str| super::super::cse::BOX_TRANSPARENT_OPS.contains(&op);
        for op in ARITH.iter().chain(CMP).chain(UNARY) {
            assert!(listed(op), "`{op}` has a dispatch arm but is not CSE-transparent");
        }
        for op in ["neg", "index", "ifelse", "broadcast"] {
            assert!(listed(op), "`{op}` has a dispatch arm but is not CSE-transparent");
        }
        for op in ["aggregate", "makearray"] {
            assert!(!listed(op), "`{op}` rebinds the box and must not be CSE-transparent");
        }
    }
}
