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
                let mut buf = pool.take_array(data.shape());
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
        return None;
    }
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
pub(super) fn reduce_combine_op(reduce: ReduceKind) -> Option<&'static str> {
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
    match expr {
        Expr::Number(n) => Some(VecValue::Scalar(*n)),
        Expr::Integer(n) => Some(VecValue::Scalar(*n as f64)),
        Expr::Variable(name) => eval_vec_variable(name, bx, ctx),
        Expr::Operator(node) => eval_vec_op(node, bx, ctx, pool, ops),
    }
}

pub(super) fn eval_vec_variable<'a>(
    name: &str,
    bx: &VecBox,
    ctx: &EvalCtx<'a>,
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

pub(super) fn eval_vec_op<'a>(
    node: &ExpressionNode,
    bx: &VecBox,
    ctx: &EvalCtx<'a>,
    pool: &mut Pool,
    ops: &mut usize,
) -> Option<VecValue<'a>> {
    match node.op.as_str() {
        // Elementwise / n-ary arithmetic, plus `atan2` (binary) and the logical
        // connectives `and`/`or` (n-ary). All fold left-to-right through
        // `vec_combine` → `apply_binary` — the SAME kernel and order the per-cell
        // oracle uses (`eval_arith`/`eval_binary` → `combine` → `apply_binary`),
        // so the whole-array result is bit-identical. Routing these here (rather
        // than bailing to the oracle) is what lets a behaviour-stack observed
        // whose body mixes arithmetic with a wind/slope `atan2` or an
        // `and(code>=1, code<=13)` fuel gate stay on the vectorized path.
        "+" | "-" | "*" | "/" | "^" | "min" | "max" | "atan2" | "and" | "or" => {
            // `args[0]` was indexed with no emptiness guard, so an aggregate body
            // containing e.g. `{"op":"+","args":[]}` PANICKED here while the
            // oracle tolerated it — the two paths did not even agree on whether
            // the node was evaluable. The registry now rejects every such node
            // before evaluation; bailing to the oracle (`None`) keeps this path
            // panic-free for the `eval_expression` bypass, which is not gated.
            let (first, rest) = node.args.split_first()?;
            if node.op == "-" && rest.is_empty() {
                return Some(vec_negate(eval_vec(first, bx, ctx, pool, ops)?, pool));
            }
            let mut acc = eval_vec(first, bx, ctx, pool, ops)?;
            for a in rest {
                let v = eval_vec(a, bx, ctx, pool, ops)?;
                acc = vec_combine(&node.op, acc, v, pool)?;
            }
            Some(acc)
        }
        "neg" => Some(vec_negate(
            eval_vec(node.args.first()?, bx, ctx, pool, ops)?,
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
        // tuple. Bit-identical to the oracle's `eval_op` (same exact-equality
        // `scalar_compare` and `c != 0.0` branch test). An *array* operand (a
        // per-cell-varying condition) is not on the fast path and bails to the oracle.
        "==" | "!=" | "<" | "<=" | ">" | ">=" => {
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
            vec_combine(&node.op, a, b, pool)
        }
        "ifelse" => {
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
        "exp" | "log" | "ln" | "log10" | "sqrt" | "abs" | "sign" | "floor" | "ceil" | "sin"
        | "cos" | "tan" | "asin" | "acos" | "atan" | "sinh" | "cosh" | "tanh" | "asinh"
        | "acosh" | "atanh" | "not" => {
            if node.args.len() != 1 {
                return None;
            }
            let v = eval_vec(&node.args[0], bx, ctx, pool, ops)?;
            Some(vec_unary(&node.op, v, pool))
        }
        // Elementwise `broadcast(fn; a, b, …)` — the whole-array analogue of
        // `eval_broadcast`, folding operands with the SAME `apply_binary` kernel
        // (via `vec_combine`) in the SAME left-to-right order, so it is
        // bit-identical to the oracle. `vec_combine` returns `None` for a
        // `broadcast_fn` it does not vectorize (e.g. `atan2`), bailing safely.
        "broadcast" => {
            let fn_name = node.broadcast_fn.as_deref().unwrap_or("+");
            let mut it = node.args.iter();
            let first = it.next()?;
            let mut acc = eval_vec(first, bx, ctx, pool, ops)?;
            for a in it {
                let v = eval_vec(a, bx, ctx, pool, ops)?;
                acc = vec_combine(fn_name, acc, v, pool)?;
            }
            Some(acc)
        }
        // Everything else (array-valued ifelse, aggregate, reshape, transpose,
        // concat, `fn` closed-registry calls, atan2, D, …) falls back.
        _ => None,
    }
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
            let mut buf = pool.take_array(data.shape());
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
pub(super) fn vec_unary<'a>(op: &str, v: VecValue<'a>, pool: &mut Pool) -> VecValue<'a> {
    match v {
        VecValue::Scalar(s) => VecValue::Scalar(apply_unary(op, s)),
        VecValue::Owned { mut data, origin } => {
            data.mapv_inplace(|x| apply_unary(op, x));
            VecValue::Owned { data, origin }
        }
        VecValue::View { data, origin } => {
            let mut buf = pool.take_array(data.shape());
            ndarray::Zip::from(&mut buf)
                .and(data)
                .for_each(|o, &x| *o = apply_unary(op, x));
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
                let mut buf = pool.take_array(&shp);
                buf.fill(s);
                buf
            }
            other => other.into_owned(pool).0,
        }
    };
    let a_arr = fill(a, pool);
    let b_arr = fill(b, pool);
    let mut out = pool.take_array(&shp);
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
    if n != src_ndim {
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
    let out_ndim = bx.shape.len();

    // Classify each source axis. `mapped[a] = (src_axis, AxisIndex)` fills output
    // axis `a` (in order); `fixed = (src_axis, 0-based index)` is a consumed
    // slice. A mapped axis is tried against the NEXT unfilled output symbol; a
    // non-affine, non-wrap axis must be a constant fixed index or the gather bails.
    let mut mapped: SmallVec<[(usize, AxisIndex); 4]> = SmallVec::new();
    let mut fixed: SmallVec<[(usize, i64); 4]> = SmallVec::new();
    let mut any_fixed_oob = false;
    for d in 0..n {
        let e = &node.args[1 + d];
        if mapped.len() < out_ndim {
            if let Some(ax) = classify_axis_index(e, &bx.syms[mapped.len()], bx) {
                mapped.push((d, ax));
                continue;
            }
        }
        match const_index_value(e, bx) {
            Some(idx1) => {
                let i0 = idx1 - src_origin[d];
                if i0 < 0 || i0 >= src_shape[d] as i64 {
                    any_fixed_oob = true;
                    fixed.push((d, 0));
                } else {
                    fixed.push((d, i0));
                }
            }
            None => {
                arg0.release(pool);
                return None;
            }
        }
    }
    // The result rank is the mapped-axis count: a scalar (all fixed, broadcast) or
    // a full output-box array. A partial rank cannot broadcast — bail.
    if !mapped.is_empty() && mapped.len() != out_ndim {
        arg0.release(pool);
        return None;
    }

    // A fixed axis out of bounds ⇒ every read is the Dirichlet ghost 0.
    if any_fixed_oob {
        arg0.release(pool);
        return Some(if mapped.is_empty() {
            VecValue::Scalar(0.0)
        } else {
            VecValue::Owned {
                data: pool.take_array(bx.shape),
                origin: bx.lo.iter().copied().collect(),
            }
        });
    }

    // All-fixed ⇒ a single source element, broadcast as a scalar.
    if mapped.is_empty() {
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
        let (orig_d, ax) = &mapped[a];
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
        }
    }

    // Reduce the source to just the mapped axes: select each fixed axis at its
    // index (descending axis order so the lower axis indices stay valid). `rv`
    // then has `out_ndim` axes, in mapped order = output-axis order.
    let mut fixed_desc: SmallVec<[(usize, usize); 4]> =
        fixed.iter().map(|&(d, i0)| (d, i0 as usize)).collect();
    fixed_desc.sort_by(|a, b| b.0.cmp(&a.0));
    let mut rv = arg0.view().expect("array");
    for (d, i0) in fixed_desc {
        rv = rv.index_axis_move(ndarray::Axis(d), i0);
    }

    // Copy every cartesian combination of per-axis segments from the reduced
    // source `rv` into the zero-filled pooled buffer (ghost positions keep 0).
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
                let src_sub = rv.slice_each_axis(|ax| {
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
pub(super) enum AxisIndex {
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
