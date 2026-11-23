//! The axis analyses the tape lowering and the range-restricted programs
//! share: how an `index(...)` axis expression maps onto an output box (an
//! affine shift of one output symbol, a periodic wrap, a constant slice), the
//! constant shifts of a left-hand side, a sub-block destination, a region
//! value's covered axes, and the binary kernel a reduction combines with.
//!
//! The evaluation happens elsewhere: the tape (`tape`) evaluates whole
//! arrays, and the per-cell oracle (`eval`) is the correctness reference.

use super::*;
use crate::types::ExpressionNode;

/// The output box an `index` axis expression is classified against: the
/// positional output index symbols.
pub(super) struct VecBox<'a> {
    pub(super) syms: &'a [String],
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

/// The binary kernel that folds a SCALAR (rank-0) reduction: [`reduce_combine_op`],
/// plus the boolean `or` (`bool_and_or`'s ⊕), which a scalar reduction runs and
/// an array-valued one may not (CONFORMANCE_SPEC §5.6.1). `BinCode::Or` returns
/// [`ReduceKind::combine`]'s crisp `0.0`/`1.0` for every operand pair at either
/// precision, a `NaN` operand (which is not `0`) reading as true in both.
pub(super) fn scalar_combine_op(reduce: ReduceKind) -> BinCode {
    match reduce {
        ReduceKind::Or => BinCode::Or,
        ReduceKind::And => BinCode::And,
        other => reduce_combine_op(other).expect("a numeric ⊕ has a kernel"),
    }
}

/// An operator resolved to the whole-array family that handles it, plus (for
/// the kernel families) the element kernel's code. The tape lowering
/// (`TapeBuilder::lower_op`) and the oracle's `nested_faq_box` dispatch on
/// this code, so an operator name is matched once per AST node.
///
/// The mapping is pinned operator by operator by
/// `vec_op_code_matches_the_dispatch_arms`, and each kernel code is pinned to
/// the per-cell oracle's `apply_binary`/`apply_unary` by the equivalence tests
/// in [`super::eval`].
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(super) enum VecOp {
    /// `+ - * / ^ min max atan2 and or` — n-ary left fold of the binary kernel.
    Arith(BinCode),
    /// `== != < <= > >=` — strictly binary, through the same binary kernels.
    Cmp(BinCode),
    /// The 21 unary transcendental/rounding maps plus `not`.
    Unary(UnCode),
    Neg,
    Index,
    Aggregate,
    Makearray,
    Const,
    /// The nullary boolean literals `true` / `false` (1.0 / 0.0).
    BoolLit(bool),
    Ifelse,
    Broadcast,
    /// The precision-boundary marker (`crate::precision_infer::MARKER_OP`).
    Precision,
    /// Everything with no whole-array family here: the tape declines it, and
    /// the per-cell oracle evaluates it.
    Unsupported,
}

/// Resolve an operator name to its [`VecOp`]. ONE string match per AST node;
/// every dispatch below it is on the returned code.
pub(super) fn vec_op_code(op: &str) -> VecOp {
    use crate::op_registry::{CoreOp, OtherOp as O};
    let Some(core) = CoreOp::from_name(op) else {
        return VecOp::Unsupported;
    };
    match core {
        CoreOp::Unary(f) => VecOp::Unary(UnCode::from_unary(f)),
        CoreOp::Compare(_) => VecOp::Cmp(BinCode::from_core(core)),
        CoreOp::Other(o) => match o {
            O::Add
            | O::Sub
            | O::Mul
            | O::Div
            | O::Pow
            | O::PowWord
            | O::Min
            | O::Max
            | O::Atan2
            | O::And
            | O::Or => VecOp::Arith(BinCode::from_core(core)),
            O::Not => VecOp::Unary(UnCode::Not),
            O::Precision => VecOp::Precision,
            O::Neg => VecOp::Neg,
            O::Index => VecOp::Index,
            O::Faq => VecOp::Aggregate,
            O::Makearray => VecOp::Makearray,
            O::Const => VecOp::Const,
            O::True => VecOp::BoolLit(true),
            O::False => VecOp::BoolLit(false),
            O::Ifelse => VecOp::Ifelse,
            O::Broadcast => VecOp::Broadcast,
            O::D
            | O::Ic
            | O::Pre
            | O::Enum
            | O::ApplyExpressionTemplate
            | O::Reshape
            | O::Transpose
            | O::Concat
            | O::Distinct => VecOp::Unsupported,
        },
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
                // An operator reference reads what its bindings read (a
                // flattened body is closed over everything else).
                || n.bindings
                    .as_ref()
                    .is_some_and(|bs| bs.values().any(|e| expr_mentions(e, name)))
        }
    }
}

/// The enclosing binding, if any, that a nested `faq` genuinely depends
/// on — the precondition for hoisting it out of the enclosing per-cell loop
/// (the tape's `lower_nested_aggregate`). `None` means the hoist is sound.
///
/// An enclosing name that the nested aggregate REBINDS with one of its own
/// binders (its `output_idx` symbols or its contracted indices) is *shadowed*:
/// inside the body and the filter that name denotes the nested aggregate's own
/// index, never the enclosing one, so evaluating the node exactly once over its
/// own box computes precisely what the per-cell oracle computes. The oracle
/// agrees by construction — [`eval_faq`] saves and rebinds exactly
/// `idx_names ∪ contract_names` around its body walk (`saved_binds`) — and
/// the tape's whole-array resolver (`resolve_var`) consults the aggregate's
/// own box symbols / contraction binds BEFORE any state, observed or
/// parameter of the same name.
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

/// Vectorized makearray: materialize each region as a whole-array sub-range
/// write over the region's box (last region wins), reusing the enclosing output
/// symbols. Returns an array spanning the union bounding box.
/// Which axes of a `makearray` region an array value of shape `value` covers,
/// or `None` when it does not fit the region (esm-spec §4.3.2: "an
/// array-valued expression must match the region's shape (excluding
/// singleton dimensions)").
///
/// A value of the region's rank must match it exactly. A value of LOWER rank
/// covers the region's non-singleton axes, in order, and must match their
/// extents — the boundary face `[[1,1],[1,NLAT]]` holding an aggregate over
/// `j` alone, which is how every §9.6.8 discretization writes its faces. That
/// is the Julia reference's rule (`_resolve_index_of_makearray`). The value's
/// elements are placed in row-major order, so the singleton axes are simply
/// inserted.
pub(super) fn region_value_axes(value: &[usize], region: &[usize]) -> Option<SmallVec<[bool; 4]>> {
    if value == region {
        return Some(SmallVec::from_elem(true, region.len()));
    }
    let covered: SmallVec<[bool; 4]> = region.iter().map(|&n| n != 1).collect();
    let extents: SmallVec<[usize; 4]> = region.iter().copied().filter(|&n| n != 1).collect();
    (value.len() < region.len() && value == extents.as_slice()).then_some(covered)
}

/// `value` viewed at the region's rank: the singleton axes
/// [`region_value_axes`] leaves uncovered inserted, in place.
pub(super) fn region_value_view<'v>(
    value: ndarray::ArrayViewD<'v, f64>,
    covered: &[bool],
) -> ndarray::ArrayViewD<'v, f64> {
    let mut v = value;
    for (a, &c) in covered.iter().enumerate() {
        if !c {
            v = v.insert_axis(ndarray::Axis(a));
        }
    }
    v
}

/// How a single `index(...)` axis expression maps output positions to source
/// positions along that axis, for a whole-array gather.
pub(super) enum AxisIndex {
    /// `sym ± k` with unit coefficient and a constant integer offset `k`
    /// (bound contraction indices folded in): a shifted slice. Out-of-extent
    /// positions stay ghost-0 (homogeneous Dirichlet).
    Affine(i64),
    /// Periodic wrap of base offset `k` over the subscripts `[lo, lo + period
    /// - 1]`: `sym + k` folded back into that window once, from either side.
    /// Over a box that is one period of its source starting at `lo` this is
    /// a cyclic roll with no ghost; see [`wrap_pieces`] for the general case
    /// and [`parse_wrap_axis_any`] for the recognized idiom.
    Wrap { k: i64, period: i64, lo: i64 },
}

/// The output positions of one axis read through a periodic wrap, split into
/// the runs over which the subscript is affine: `(start, len, shift)`, 0-based
/// and ascending, with the 1-based subscript at position `p` of the run being
/// `out_lo + p + shift`. The idiom folds `sym + k` below `lo` up by `period`,
/// above `lo + period - 1` down by `period`, and leaves it alone between, so
/// there are at most three runs. Whether each subscript lands inside the
/// source is the caller's question, exactly as for an affine shift.
pub(super) fn wrap_pieces(
    out_lo: i64,
    n: usize,
    k: i64,
    lo: i64,
    period: i64,
) -> SmallVec<[(usize, usize, i64); 3]> {
    let n_i = n as i64;
    let hi = lo + period - 1;
    // `sym + k < lo` ⇔ p < lo − k − out_lo; `sym + k > hi` ⇔ p > hi − k − out_lo.
    let below = (lo - k - out_lo).clamp(0, n_i);
    let above = (hi - k - out_lo + 1).clamp(below, n_i);
    let mut pieces = SmallVec::new();
    for (start, end, shift) in [
        (0, below, k + period),
        (below, above, k),
        (above, n_i, k - period),
    ] {
        if end > start {
            pieces.push((start as usize, (end - start) as usize, shift));
        }
    }
    pieces
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
/// `sym` with unit coefficient and an integer constant part. An einsum offset
/// `(i+1)+k` thus folds the bound `k` into the shift.
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
/// Resolving the symbol *from* the expression does one walk regardless of
/// rank, where a per-candidate search — `classify_axis_index` against each
/// not-yet-claimed output symbol, then `const_index_value` — re-walks the
/// expression once per candidate. The two are equivalent, arm for arm, and
/// the `axis_classifier_equivalence` tests pin it:
///   * an expression affine in `syms[a]` with unit coefficient mentions no other
///     output symbol (the per-candidate walk returns `None` the moment it meets
///     an unbound one), so the search can only ever claim `a` — and it stops
///     at the first success, which is that one;
///   * an expression affine in an ALREADY-claimed symbol fails for every other
///     candidate and then fails `const_index_value` too (a bare output symbol
///     is not a bound contraction index), i.e. it bails — as it does here;
///   * a wrap expression is an `ifelse`, for which the affine walk returns
///     `None`, so trying affine first and wrap second is order-independent;
///   * a constant / bound-contraction axis has coefficient 0 in every symbol, so
///     it never classifies as a map under either rule.
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
                        // per-symbol walk folds it to the constant 0 with the
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

/// `parse_wrap_axis` with the symbol resolved from the expression: the wrapped
/// `inner` decides which output axis the roll applies to, and every other branch
/// of the idiom must agree with it. See [`classify_axis_role`] for why deriving
/// the symbol matches the per-candidate search exactly.
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
    Some((
        a,
        AxisIndex::Wrap {
            k,
            period,
            lo: lo_bound,
        },
    ))
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
    Some(AxisIndex::Wrap {
        k,
        period,
        lo: lo_bound,
    })
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

#[cfg(test)]
mod axis_classifier_equivalence {
    //! [`classify_axis_role`] resolves an `index(...)` axis expression's role in
    //! ONE walk, equivalent to trying [`classify_axis_index`] against each
    //! not-yet-claimed output symbol in turn and then [`const_index_value`].
    //! The equivalence rests on an argument (an expression affine in one
    //! output symbol cannot classify against any other), not on the compiler
    //! — so pin it: over a corpus of axis expressions and every subset of
    //! already-claimed output axes, the two classifiers must agree exactly.
    use super::*;
    use serde_json::json;

    fn ex(v: serde_json::Value) -> Expr {
        serde_json::from_value(v).expect("axis expression deserializes")
    }

    /// A comparable rendering of a classification outcome.
    #[derive(Debug, PartialEq, Eq)]
    enum Role {
        Affine(usize, i64),
        Wrap(usize, i64, i64, i64),
        Const(i64),
        Bail,
    }

    fn from_axis(a: usize, ax: &AxisIndex) -> Role {
        match ax {
            AxisIndex::Affine(k) => Role::Affine(a, *k),
            AxisIndex::Wrap { k, period, lo } => Role::Wrap(a, *k, *period, *lo),
        }
    }

    /// The per-candidate search: try each UNCLAIMED output symbol in order
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

    /// The single-walk classifier, read through the gather lowering's
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
        let cvals = [2i64, -1];
        let bx = VecBox {
            syms: &syms,
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
        let bx = VecBox {
            syms: &syms,
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
    //! [`vec_op_code`] resolves an operator name to its [`VecOp`] family. A
    //! dropped operator would not fail loudly — it would merely decline to
    //! the per-cell oracle and make the model slower — so pin the mapping
    //! against literal lists of the operators each family covers.
    use super::*;

    /// The operators of each kernel family.
    #[rustfmt::skip]
    const ARITH: &[&str] = &["+", "-", "*", "/", "^", "min", "max", "atan2", "and", "or"];
    #[rustfmt::skip]
    const CMP: &[&str] = &["==", "!=", "<", "<=", ">", ">="];
    #[rustfmt::skip]
    const UNARY: &[&str] = &[
        "exp", "log", "log10", "sqrt", "abs", "sign", "floor", "ceil", "sin",
        "cos", "tan", "asin", "acos", "atan", "sinh", "cosh", "tanh", "asinh",
        "acosh", "atanh", "not",
    ];

    /// Every listed operator lands in its family, and its kernel code resolves to the same element kernel the per-cell
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
        assert_eq!(vec_op_code("faq"), VecOp::Aggregate);
        assert_eq!(vec_op_code("makearray"), VecOp::Makearray);
        assert_eq!(vec_op_code("const"), VecOp::Const);
        assert_eq!(vec_op_code("true"), VecOp::BoolLit(true));
        assert_eq!(vec_op_code("false"), VecOp::BoolLit(false));
        assert_eq!(vec_op_code("pow"), VecOp::Arith(BinCode::Pow));
        assert_eq!(vec_op_code("ifelse"), VecOp::Ifelse);
        assert_eq!(vec_op_code("broadcast"), VecOp::Broadcast);
    }

    /// The catch-all arm: everything with no whole-array family must stay
    /// `Unsupported`, so the per-cell oracle stays in charge of it. A code accidentally
    /// added here would route an unsupported construct into a kernel arm.
    #[test]
    fn unvectorized_operators_still_bail() {
        #[rustfmt::skip]
        const OTHERS: &[&str] = &[
            "D", "Pre", "arrayop", "reshape", "transpose", "concat", "integral",
            "godunov_hamiltonian", "distinct", "ic", "enum", "apply_operator",
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
}
