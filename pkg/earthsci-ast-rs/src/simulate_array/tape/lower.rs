//! Lowering: compile the post-CSE expression graph of a model's observed +
//! RHS rules into a flat [`TapeProgram`].
//!
//! The load-bearing principle: **compile the shared axis analyses, don't
//! invent new semantics.** Every classification this pass performs is one of
//! the `pub(super)` classifiers in `vectorized.rs` (`classify_axis_role`,
//! `parse_wrap_axis_any`, `lhs_constant_shifts`, `subblock_dest`,
//! `vec_op_code`, …), which the range programs use too, and every construct
//! they cannot classify becomes a *declined rule* carrying the reason. A
//! model with a declined rule gets no program at all ([`DeclinedTape`]): the
//! instruction set cannot hand a rule to the per-cell oracle.
//!
//! Every arm is pinned against the per-cell oracle. A rank-0 `faq` — every
//! index contracted, scalar result — is lowered as a boxed body plus one
//! [`Instr::Reduce`] ([`TapeBuilder::lower_scalar_reduction`]), whose
//! ROW-MAJOR visiting order IS the oracle's `CartesianTuples` odometer.
//!
//! ## Value numbering
//!
//! Shared subexpressions are numbered per `(scope, structural class)`, with a
//! fresh scope per output box (each faq entry, each contraction tuple, each
//! makearray region), and box-pure subtrees are hoisted into a persistent
//! store keyed by `(box signature, class)`:
//!
//! * scope-local numbering keyed by the interned node's `Arc` pointer
//!   (structural identity IS pointer identity for interned subtrees; the few
//!   address-unique nodes — `output`/`join` carriers, which the
//!   interner refuses — merely under-share, which recomputes the same value),
//!   consulted in the INNERMOST open scope only, mirroring the runtime memo's
//!   current-scope stamp;
//! * a cross-rule hoist map keyed by `(owned box key, node pointer)` for
//!   values whose operand cadence is ≤ SEGMENT — the structural analogue of
//!   the ess-lih persistent store (same box + same subtree + constant-tier
//!   leaves ⇒ same value for the whole solve/segment).
//!
//! Both reuse paths substitute a slot for a recomputation of the *identical*
//! value, so availability differences from the runtime memo (which is
//! dynamic) cannot change `dy`. Values defined inside a [`Instr::JmpIfZero`]
//! branch never escape it (the branch may not execute), enforced with an
//! insertion journal rolled back at branch exit.

use super::super::driver::{
    dependency_cone, expr_blocks_output_pruning, observed_rule_is_array_valued,
};
use super::super::*;
use super::ir::*;
use crate::precision::Precision;
use crate::simulate_array::eval::const_oob_message;
use crate::types::ExpressionNode;
use crate::value_invention::BoundaryKind;
use rustc_hash::FxHashMap;
use std::collections::HashSet;
use std::sync::Arc;

// ---------------------------------------------------------------------------
// Bail plumbing.
// ---------------------------------------------------------------------------

macro_rules! bail_tape {
    ($($t:tt)*) => {
        return Err(Bail::new(format!($($t)*)))
    };
}

/// The IR index of entry `n` of one of the program's operand tables (state
/// variables, observed reads, parameters). The IR stores these as `u32`; a
/// table that outgrows that refuses the rule by name rather than wrapping onto
/// another entry.
fn tape_index(n: usize, table: &str) -> LResult<u32> {
    u32::try_from(n).map_err(|_| {
        Bail::new(format!(
            "tape index overflow: the program has more than {} {table}",
            u32::MAX
        ))
    })
}

type LResult<T> = Result<T, Bail>;

/// The parts of a counted bracket ([`detect_indicator_count`]).
struct IndicatorCount<'e> {
    rel: CountRel,
    /// The array the comparison reads at the contracted index: a variable
    /// or an inline `const`.
    axis: &'e Expr,
    x: &'e Expr,
    lo: i64,
    hi: i64,
    /// The body is `ifelse(cond, 0, 1)`: the entries that FAIL the
    /// comparison are counted, `(hi - lo + 1) - count`.
    complement: bool,
}

/// The rank-0 `faq` `sum_{k=lo..hi} ifelse(axis[k] REL x, 1, 0)`, REL one of
/// `<= < >= >` with the indexed axis on either side, or its complement
/// `ifelse(axis[k] REL x, 0, 1)`; otherwise `None`.
///
/// The guard is the algebraic shape and nothing else: one statically ranged
/// contracted index, a `+` reduction, no `filter` or `join`, a body that is
/// exactly the indicator (the literals 1 and 0, in either order), an axis read
/// `index(A, k)` whose base `A` is a variable or an inline `const` and does
/// not mention `k`, and a query that does not mention `k`. Every other shape
/// is the general reduction's.
fn detect_indicator_count<'e>(spec: &ArrayOpSpec<'e>) -> Option<IndicatorCount<'e>> {
    use super::super::vectorized::expr_mentions;
    if spec.reduce != ReduceKind::Sum
        || spec.filter.is_some()
        || spec.join.is_some_and(|j| !j.is_empty())
        || !spec.idx_names.is_empty()
        || !spec.ranges.is_empty()
        || spec.contract_names.len() != 1
    {
        return None;
    }
    let ContractDim::Static(lo, hi) = spec.contract_dims[0] else {
        return None;
    };
    let k = spec.contract_names[0].as_str();
    let Expr::Operator(ite) = spec.body else {
        return None;
    };
    if ite.op != "ifelse" || ite.args.len() != 3 {
        return None;
    }
    let lit = |e: &Expr, want: f64| match e {
        Expr::Number(v) => *v == want,
        Expr::Integer(v) => *v as f64 == want,
        _ => false,
    };
    let complement = if lit(&ite.args[1], 1.0) && lit(&ite.args[2], 0.0) {
        false
    } else if lit(&ite.args[1], 0.0) && lit(&ite.args[2], 1.0) {
        true
    } else {
        return None;
    };
    let Expr::Operator(cmp) = &ite.args[0] else {
        return None;
    };
    let rel = CountRel::from_op(&cmp.op)?;
    if cmp.args.len() != 2 {
        return None;
    }
    // The axis read `index(A, k)`, on either side of the comparison.
    let axis_read = |e: &'e Expr| -> Option<&'e Expr> {
        let Expr::Operator(ix) = e else {
            return None;
        };
        if ix.op != "index" || ix.args.len() != 2 {
            return None;
        }
        if !matches!(&ix.args[1], Expr::Variable(v) if v == k) {
            return None;
        }
        let base = &ix.args[0];
        let ok = match base {
            Expr::Variable(v) => v != k,
            Expr::Operator(c) => c.op == "const" && !expr_mentions(base, k),
            _ => false,
        };
        ok.then_some(base)
    };
    let (axis, x, rel) = match (axis_read(&cmp.args[0]), axis_read(&cmp.args[1])) {
        (Some(a), None) => (a, &cmp.args[1], rel),
        (None, Some(a)) => (a, &cmp.args[0], rel.mirror()),
        _ => return None,
    };
    if expr_mentions(x, k) {
        return None;
    }
    Some(IndicatorCount {
        rel,
        axis,
        x,
        lo,
        hi,
        complement,
    })
}

mod contraction;
mod index;
mod rules;
mod scatter;
mod standalone;
mod tuples;
mod wholesale;

#[cfg(test)]
pub(super) use tuples::{set_tuple_list_budget, take_chunk_inputs_held, take_tuple_walks};

pub(crate) use standalone::StandaloneError;
pub(in crate::simulate_array) use standalone::{collect_variable_names, eval_standalone_rule};

/// What a build knows about the forcing buffer: the box a read of each name
/// it can serve compiles against, and which of them a provider refreshes
/// between segments (see `ArrayCompiled::forcing_inputs`).
pub(super) struct ForcingInputs<'a> {
    pub shapes: FxHashMap<String, DimU>,
    /// Externally refreshed parameters with no box to compile against: the
    /// buffer does not hold them and their declared shape does not size.
    pub unsized_: HashSet<String>,
    pub discrete: &'a HashSet<String>,
}

/// Highest rank a contraction is promoted to. The executor's per-axis tables
/// hold four axes inline and spill past that, so a box of rank five or more
/// costs an allocation per instruction per call; past this rank the
/// contraction is unrolled instead.
const MAX_RANK: usize = 8;

/// Largest box a contraction is promoted to (`window × output` elements, one
/// term each): beyond it the contraction stays unrolled rather than
/// materialize its terms.
const MAX_PROMOTED_ELEMS: usize = 1 << 27;

/// The parts of a contraction (`faq`) every lowering form reads: the output
/// index names, the body, the contracted names and their ranges, the
/// reduction and the filter. The output box and a join, which only some
/// forms take, are passed beside it.
#[derive(Clone, Copy)]
pub(super) struct Contraction<'a> {
    pub(super) idx_names: &'a [String],
    pub(super) body: &'a Expr,
    pub(super) contract_names: &'a [String],
    pub(super) contract_dims: &'a [ContractDim],
    pub(super) reduce: ReduceKind,
    pub(super) filter: Option<&'a Expr>,
}

impl<'a> Contraction<'a> {
    fn of(spec: &'a ArrayOpSpec<'a>) -> Self {
        Contraction {
            idx_names: spec.idx_names,
            body: spec.body,
            contract_names: &spec.contract_names,
            contract_dims: &spec.contract_dims,
            reduce: spec.reduce,
            filter: spec.filter,
        }
    }

    /// An elementwise map over the output box: nothing contracted, no
    /// filter.
    fn map(idx_names: &'a [String], body: &'a Expr) -> Self {
        Contraction {
            idx_names,
            body,
            contract_names: &[],
            contract_dims: &[],
            reduce: ReduceKind::Sum,
            filter: None,
        }
    }
}

/// An `index` read whose subscripts are classified against the box it is
/// read over ([`TapeBuilder::lower_index`]): the source's box, per output
/// axis the source axis its symbol subscripts (and how), every constant
/// subscript as `(source dim, 1-based index)`, and the one source axis whose
/// subscript is data, if any.
#[derive(Clone, Copy)]
struct IndexRead<'r> {
    src_shape: &'r [usize],
    src_origin: &'r [i64],
    mapped: &'r [Option<(usize, AxisIndex)>],
    fixed_raw: &'r [(usize, i64)],
    data_axis: Option<usize>,
}

impl IndexRead<'_> {
    /// The constant subscripts as 0-based source positions (0 where out of
    /// range), and whether any is out of range.
    fn fixed_positions(&self) -> (SmallVec<[(usize, i64); 4]>, bool) {
        let mut fixed: SmallVec<[(usize, i64); 4]> = SmallVec::new();
        let mut any_oob = false;
        for &(d, idx1) in self.fixed_raw {
            let i0 = idx1 - self.src_origin[d];
            if i0 < 0 || i0 >= self.src_shape[d] as i64 {
                any_oob = true;
                fixed.push((d, 0));
            } else {
                fixed.push((d, i0));
            }
        }
        (fixed, any_oob)
    }
}

/// A static contraction window: the contracted names and their inclusive
/// bounds, in `contract_names` order.
struct ContractWindow<'a> {
    names: &'a [String],
    lo: &'a [i64],
    hi: &'a [i64],
}

/// Which entry point a contraction's promoted box serves
/// ([`PromotedPlan`]). The forms differ in where the contracted axes go,
/// which box the result lives on, and in what order the per-cell oracle
/// visits the box's cells.
#[derive(Clone, Copy, PartialEq, Eq)]
enum PromotedKind {
    /// A rank-0 reduction nested in a box whose every axis its body reads
    /// ([`TapeBuilder::lower_nested_scalar_reduction`]): the box's axes,
    /// then the contracted ones; one result per cell of the box.
    PerCell,
    /// A contraction over an output box
    /// ([`TapeBuilder::lower_contracted_box`]): the contracted axes lead, or
    /// trail in a program stored axis-reversed; one result per output cell.
    Output,
    /// A standalone rank-0 reduction
    /// ([`TapeBuilder::lower_scalar_reduction`]): the contraction box alone,
    /// one scalar result.
    Scalar,
}

/// The box one contraction's term is lowered over, and how it folds away:
/// the one shape [`TapeBuilder::lower_promoted`] lowers for every form.
struct PromotedPlan {
    kind: PromotedKind,
    syms: Vec<String>,
    lo: DimI,
    shape: DimU,
    /// The contracted axes [`Instr::Reduce`] folds, ascending.
    axes: SmallVec<[u8; 4]>,
    /// The oracle's visiting order ([`LBox::visit`]).
    visit: SmallVec<[u8; 4]>,
    /// The result's box (`shape`, `lo`); `None` for one scalar.
    out: Option<(DimU, DimI)>,
    /// How a refusal names the construct.
    what: &'static str,
}

impl PromotedPlan {
    /// The promoted box of the window `names` (`wlo`, `wshape`) for `kind`:
    /// `out_syms` over `out_lo`/`out_shape` is the enclosing or output box
    /// (empty for [`PromotedKind::Scalar`]), `out_visit` its visiting order,
    /// and `trailing` puts an output box's contracted axes last.
    #[allow(clippy::too_many_arguments)]
    fn new(
        kind: PromotedKind,
        out_syms: &[String],
        out_lo: &DimI,
        out_shape: &DimU,
        out_visit: impl Iterator<Item = u8>,
        names: &[String],
        wlo: &[i64],
        wshape: &[usize],
        trailing: bool,
    ) -> Self {
        let (nb, nc) = (out_shape.len(), names.len());
        // Contracted axes after the box's, or before them.
        let after = kind != PromotedKind::Output || trailing;
        let cat = |a: &[String], b: &[String]| a.iter().chain(b).cloned().collect::<Vec<_>>();
        let (syms, lo, shape, out_axes, axes): (
            Vec<String>,
            DimI,
            DimU,
            Vec<u8>,
            SmallVec<[u8; 4]>,
        ) = if after {
            (
                cat(out_syms, names),
                out_lo.iter().chain(wlo).copied().collect(),
                out_shape.iter().chain(wshape).copied().collect(),
                out_visit.collect(),
                (nb as u8..(nb + nc) as u8).collect(),
            )
        } else {
            (
                cat(names, out_syms),
                wlo.iter().chain(out_lo.iter()).copied().collect(),
                wshape.iter().chain(out_shape.iter()).copied().collect(),
                out_visit.map(|a| a + nc as u8).collect(),
                (0..nc as u8).collect(),
            )
        };
        // The oracle walks the box's cells, then each cell's tuples; a
        // standalone reduction's box is its tuples, row-major.
        let visit = match kind {
            PromotedKind::Scalar => SmallVec::new(),
            _ => out_axes.iter().chain(axes.iter()).copied().collect(),
        };
        let (out, what) = match kind {
            PromotedKind::PerCell => (
                Some((out_shape.clone(), out_lo.clone())),
                "aggregate: a rank-0 output's",
            ),
            PromotedKind::Output => (Some((out_shape.clone(), out_lo.clone())), "contracted:"),
            PromotedKind::Scalar => (None, "reduction:"),
        };
        PromotedPlan {
            kind,
            syms,
            lo,
            shape,
            axes,
            visit,
            out,
            what,
        }
    }

    /// Refuse a box the program cannot hold: its rank (an output box needs
    /// an axis of its own), then its element count.
    fn check(&self) -> LResult<()> {
        let what = self.what;
        let no_out_axis = matches!(&self.out, Some((s, _)) if s.is_empty());
        if no_out_axis || self.shape.len() > MAX_RANK {
            bail_tape!("{what} promoted box rank out of range");
        }
        let elems = self
            .shape
            .iter()
            .try_fold(1usize, |acc, &n| acc.checked_mul(n))
            .filter(|&n| n <= MAX_PROMOTED_ELEMS);
        if elems.is_none() {
            bail_tape!("{what} promoted box is too large");
        }
        Ok(())
    }
}

/// One run of output positions along an axis of a const-array gather, with
/// the read its boundary policy resolves it to ([`TapeBuilder::lower_const_gather`]).
#[derive(Clone, Debug)]
enum ConstRun {
    /// Copy segments `(out_off, len, src_off)`, relative to the run's start.
    Copy(SmallVec<[(usize, usize, usize); 2]>),
    /// One source position (a clamped edge, 0-based), read by every cell.
    Edge(usize),
    /// An output axis no source dim maps to (a broadcast axis).
    Bcast,
    /// Out of range with no policy: `NaN`, and a fault.
    Oob,
}

/// `index_into`'s resolution of the 1-based subscript `raw` into a dim of
/// extent `n` under `policy`: the 0-based position, or `None` for the fault.
fn resolve_const_index(policy: BoundaryKind, raw: i64, n: i64) -> Option<usize> {
    if (1..=n).contains(&raw) {
        return Some((raw - 1) as usize);
    }
    match policy {
        BoundaryKind::Periodic if n >= 1 => {
            Some(crate::simulate_array::eval::periodic_offset(raw, n))
        }
        BoundaryKind::Clamp if n >= 1 => Some((raw.clamp(1, n) - 1) as usize),
        _ => None,
    }
}

/// The copy segments of a periodic wrap axis read from a source dim of
/// `src_len` cells at `src_origin`: each run of [`wrap_pieces`] clipped to the
/// source exactly as an affine shift is, so a subscript the wrap leaves
/// outside the source reads the zero ghost. Over one full period of the
/// source this is the two-segment roll. Empty when no subscript lands inside.
fn wrap_segs(
    src_origin: i64,
    src_len: i64,
    out_lo: i64,
    out_len: usize,
    (k, lo, period): (i64, i64, i64),
) -> SmallVec<[(usize, usize, usize); 2]> {
    let mut segs = SmallVec::new();
    for (start, len, shift) in wrap_pieces(out_lo, out_len, k, lo, period) {
        // Position `p` reads the 0-based source cell `out_lo + p + shift − src_origin`.
        let lo_p = (start as i64).max(src_origin - out_lo - shift);
        let hi_p = ((start + len) as i64).min(src_origin + src_len - out_lo - shift);
        if lo_p < hi_p {
            segs.push((
                lo_p as usize,
                (hi_p - lo_p) as usize,
                (out_lo + lo_p + shift - src_origin) as usize,
            ));
        }
    }
    segs
}

/// The 1-based subscript a periodic wrap axis reads at output position `p`.
fn wrap_subscript(out_lo: i64, p: i64, (k, lo, period): (i64, i64, i64)) -> i64 {
    let inner = out_lo + p + k;
    if inner < lo {
        inner + period
    } else if inner > lo + period - 1 {
        inner - period
    } else {
        inner
    }
}

/// The runs of one output axis of a const-array gather whose 1-based
/// subscript is `base + p` at position `p`, over `n_a` positions of a source
/// dim of `n_d` cells, resolved by the dim's boundary `policy`.
fn affine_const_runs(
    base: i64,
    n_a: usize,
    n_d: i64,
    policy: BoundaryKind,
) -> SmallVec<[(usize, usize, ConstRun); 3]> {
    let mut rs: SmallVec<[(usize, usize, ConstRun); 3]> = SmallVec::new();
    let na = n_a as i64;
    let below = (1 - base).clamp(0, na) as usize;
    let above = (n_d + 1 - base).clamp(0, na) as usize;
    match policy {
        BoundaryKind::Periodic if n_d > 1 => {
            let mut segs: SmallVec<[(usize, usize, usize); 2]> = SmallVec::new();
            let mut p = 0i64;
            while p < na {
                let s = (base + p - 1).rem_euclid(n_d);
                let len = (n_d - s).min(na - p);
                segs.push((p as usize, len as usize, s as usize));
                p += len;
            }
            rs.push((0, n_a, ConstRun::Copy(segs)));
        }
        // A period of one reads its one element everywhere.
        BoundaryKind::Periodic => rs.push((0, n_a, ConstRun::Edge(0))),
        kind => {
            let (lo_run, hi_run) = match kind {
                BoundaryKind::Clamp => (ConstRun::Edge(0), ConstRun::Edge(n_d as usize - 1)),
                _ => (ConstRun::Oob, ConstRun::Oob),
            };
            if below > 0 {
                rs.push((0, below, lo_run));
            }
            if above > below {
                let mut segs = SmallVec::new();
                segs.push((0, above - below, (base + below as i64 - 1) as usize));
                rs.push((below, above - below, ConstRun::Copy(segs)));
            }
            if n_a > above.max(below) {
                let from = above.max(below);
                rs.push((from, n_a - from, hi_run));
            }
        }
    }
    rs
}

/// The absolute `dy` position of every cell of a derivative rule's output
/// box, in ROW-MAJOR order, for a left-hand side that is not a constant shift
/// of the output indices — the per-cell oracle's placement of each cell
/// (`eval_simple_index` of every subscript, then `multi_to_flat_col_major`),
/// computed once. Each subscript must be an integer sum or difference of
/// output indices and integer literals, which is the grammar the oracle
/// reads, and every position must lie inside the variable: the oracle's
/// placement of anything else is not a cell of it.
fn lhs_scatter_positions(
    vs: &VarShape,
    names: &[String],
    ranges: &[(i64, i64)],
    lhs: &[Expr],
) -> LResult<Vec<usize>> {
    /// `e` as `c0 + Σ coeff[j]·names[j]`, or `None` outside the grammar.
    fn affine(e: &Expr, names: &[String], coeff: &mut [i64], sign: i64) -> Option<i64> {
        match e {
            Expr::Integer(n) => n.checked_mul(sign),
            Expr::Number(n) if n.fract() == 0.0 && n.abs() < 9.0e15 => {
                (*n as i64).checked_mul(sign)
            }
            Expr::Variable(v) => {
                let j = names.iter().position(|n| n == v)?;
                coeff[j] = coeff[j].checked_add(sign)?;
                Some(0)
            }
            Expr::Operator(node) if (node.op == "+" || node.op == "-") && node.args.len() == 2 => {
                let a = affine(&node.args[0], names, coeff, sign)?;
                let s2 = if node.op == "+" { sign } else { -sign };
                let b = affine(&node.args[1], names, coeff, s2)?;
                a.checked_add(b)
            }
            _ => None,
        }
    }
    let nd = vs.shape.len();
    if lhs.len() != nd || ranges.len() != names.len() || names.is_empty() {
        bail_tape!("rule: LHS rank does not match its variable");
    }
    let mut forms: Vec<(i64, Vec<i64>)> = Vec::with_capacity(nd);
    for e in lhs {
        let mut coeff = vec![0i64; names.len()];
        let Some(c0) = affine(e, names, &mut coeff, 1) else {
            bail_tape!("rule: LHS subscript is not an integer sum of output indices");
        };
        forms.push((c0, coeff));
    }
    let extents: Vec<i64> = ranges.iter().map(|(lo, hi)| (hi - lo + 1).max(0)).collect();
    let total = extents
        .iter()
        .try_fold(1usize, |acc, &n| acc.checked_mul(n as usize));
    let Some(total) = total else {
        bail_tape!("rule: output box too large");
    };
    let cm = {
        let mut st = Vec::with_capacity(nd);
        let mut acc = 1usize;
        for &n in &vs.shape {
            st.push(acc);
            acc *= n;
        }
        st
    };
    let mut pos = Vec::with_capacity(total);
    let mut cell: Vec<i64> = ranges.iter().map(|(lo, _)| *lo).collect();
    for _ in 0..total {
        let mut flat = vs.flat_offset;
        for (d, (c0, coeff)) in forms.iter().enumerate() {
            let sub = c0 + coeff.iter().zip(&cell).map(|(c, x)| c * x).sum::<i64>();
            let off = sub - vs.origin[d];
            if off < 0 || off >= vs.shape[d] as i64 {
                bail_tape!("rule: LHS addresses a cell outside its variable");
            }
            flat += off as usize * cm[d];
        }
        pos.push(flat);
        // Row-major odometer: the last output index fastest.
        let mut d = cell.len();
        while d > 0 {
            d -= 1;
            cell[d] += 1;
            if cell[d] <= ranges[d].1 {
                break;
            }
            cell[d] = ranges[d].0;
        }
    }
    Ok(pos)
}

// ---------------------------------------------------------------------------
// Lowering-time values.
// ---------------------------------------------------------------------------

/// A lowering-time value: a scalar or a whole array the program will hold at
/// run time, made symbolic. Scalar kinds are `Lit`/`Param`/`Time`/`Scalar` (a scalar slot)
/// plus a 0-d `StateView`; array kinds carry a box (shape + origin).
#[derive(Clone, Debug)]
enum LV {
    Lit(f64),
    Param(u32),
    Time,
    /// A scalar slot.
    Scalar(SlotId),
    /// An array slot (box in the slot desc).
    Arr(SlotId),
    /// Whole persistent state array `state_vars[ix]` (origin all-1s; 0-d ⇒
    /// scalar semantics), read in place without a copy.
    State(u32),
}

/// The lowering-time output box (the `VecBox` analogue with owned lo/shape).
struct LBox<'a> {
    syms: &'a [String],
    lo: DimI,
    shape: DimU,
    cnames: &'a [String],
    cvals: SmallVec<[i64; 4]>,
    /// Nonzero for a TUPLE-LIST box (see `tuples`): the 1-D box of a
    /// contraction's admitted tuples, whose loop symbols are build-time
    /// columns in the builder's frame with this id rather than axes.
    tuple: u32,
    /// The box's axes in the order the per-cell oracle visits their cells,
    /// slowest first; empty means row-major (axis 0 slowest). Only the
    /// promoted contraction box differs: its contracted axes lead, but the
    /// oracle walks the output cells first and the contraction tuples within
    /// each. Consulted only to place a fail-closed fault ([`FaultKey`]).
    visit: SmallVec<[u8; 4]>,
}

impl<'a> LBox<'a> {
    /// A plain box: `syms` over `lo` and `shape`, nothing contracted or bound
    /// to a tuple list, visited row-major.
    fn new(syms: &'a [String], lo: DimI, shape: DimU) -> Self {
        LBox {
            syms,
            lo,
            shape,
            cnames: &[],
            cvals: SmallVec::new(),
            tuple: 0,
            visit: SmallVec::new(),
        }
    }

    /// Axis `k` of the visiting order (see [`LBox::visit`]).
    fn visit_axis(&self, k: usize) -> usize {
        if self.visit.is_empty() {
            k
        } else {
            self.visit[k] as usize
        }
    }

    fn as_vecbox(&self) -> VecBox<'_> {
        VecBox {
            syms: self.syms,
            cnames: self.cnames,
            cvals: &self.cvals,
        }
    }

    fn cbind(&self, name: &str) -> Option<i64> {
        self.cnames
            .iter()
            .position(|n| n == name)
            .map(|i| self.cvals[i])
    }
}

/// [`TapeBuilder::sub_box_axes`]'s mark of a term that is itself an
/// operation (not a leaf or a read), above every axis bit.
const SUB_BOX_OP: u32 = 1 << 31;

/// The fewest distinct operations a term moved to a sub-box carries
/// ([`TapeBuilder::lower_on_sub_box`]).
const SUB_BOX_MIN_OPS: usize = 4;

/// The integer bounds of `e` over every cell of `bx`, when its structure
/// proves them: integer literals, the box's loop symbols (a symbol's bounds
/// narrowed by `refine`, innermost last), `+`, `-`, `min`, `max`, and an
/// `ifelse` whose condition compares a loop symbol with a constant, each arm
/// bounded under the condition that selects it — so the cyclic successor
/// `ifelse(k < n, k + 1, 1)` over `k in [1, n]` is bounded by `[1, n]`.
/// Endpoints are kept below 2^24, where they are exact at either working
/// precision.
fn int_range(e: &Expr, bx: &LBox, refine: &[(&str, (f64, f64))]) -> Option<(f64, f64)> {
    let exact = |r: (f64, f64)| {
        (r.0.fract() == 0.0
            && r.1.fract() == 0.0
            && r.0.abs() < 16_777_216.0
            && r.1.abs() < 16_777_216.0)
            .then_some(r)
    };
    match e {
        Expr::Integer(n) => exact((*n as f64, *n as f64)),
        Expr::Number(v) => exact((*v, *v)),
        Expr::Variable(name) => {
            if let Some((_, r)) = refine.iter().rev().find(|(n, _)| *n == name.as_str()) {
                return Some(*r);
            }
            if bx.tuple != 0 {
                return None;
            }
            if let Some(a) = bx.syms.iter().position(|s| s == name) {
                let n = bx.shape[a];
                return (n > 0)
                    .then(|| exact((bx.lo[a] as f64, (bx.lo[a] + n as i64 - 1) as f64)))
                    .flatten();
            }
            bx.cbind(name).and_then(|v| exact((v as f64, v as f64)))
        }
        Expr::Operator(node) => {
            let arg = |i: usize| int_range(&node.args[i], bx, refine);
            match (node.op.as_str(), node.args.len()) {
                ("+", n) if n >= 1 => {
                    let mut acc = (0.0, 0.0);
                    for i in 0..n {
                        let r = arg(i)?;
                        acc = exact((acc.0 + r.0, acc.1 + r.1))?;
                    }
                    Some(acc)
                }
                ("-", 1) => arg(0).map(|r| (-r.1, -r.0)),
                ("-", 2) => {
                    let (a, b) = (arg(0)?, arg(1)?);
                    exact((a.0 - b.1, a.1 - b.0))
                }
                ("min" | "max", n) if n >= 1 => {
                    let mut acc = arg(0)?;
                    for i in 1..n {
                        let r = arg(i)?;
                        acc = if node.op == "min" {
                            (acc.0.min(r.0), acc.1.min(r.1))
                        } else {
                            (acc.0.max(r.0), acc.1.max(r.1))
                        };
                    }
                    Some(acc)
                }
                // A read of an inline literal table lies between its least
                // and greatest entry, wherever it is read.
                ("index", n) if n >= 2 => match &node.args[0] {
                    Expr::Operator(c) if c.op == "const" => {
                        fn walk(v: &serde_json::Value, acc: &mut Option<(f64, f64)>) -> bool {
                            match v {
                                serde_json::Value::Array(a) => a.iter().all(|x| walk(x, acc)),
                                serde_json::Value::Number(x) => {
                                    let Some(x) = x.as_f64() else { return false };
                                    *acc = Some(acc.map_or((x, x), |(l, h)| (l.min(x), h.max(x))));
                                    true
                                }
                                _ => false,
                            }
                        }
                        let mut acc = None;
                        let v = c.value.as_ref()?;
                        let whole = match v.as_dense() {
                            Some(d) => d.iter().all(|&x| {
                                acc = Some(
                                    acc.map_or((x, x), |(l, h): (f64, f64)| (l.min(x), h.max(x))),
                                );
                                true
                            }),
                            None => walk(&v.to_json(), &mut acc),
                        };
                        whole.then_some(acc).flatten().and_then(exact)
                    }
                    _ => None,
                },
                ("ifelse", 3) => {
                    let arm = |i: usize, extra: Option<(&str, (f64, f64))>| {
                        let mut r: SmallVec<[(&str, (f64, f64)); 4]> =
                            refine.iter().copied().collect();
                        if let Some((n, (lo, hi))) = extra {
                            if lo > hi {
                                return Some(None); // this arm is never taken
                            }
                            r.push((n, (lo, hi)));
                        }
                        int_range(&node.args[i], bx, &r).map(Some)
                    };
                    let (then_r, else_r) = match condition_refinement(&node.args[0], bx, refine) {
                        Some((name, t, f)) => (arm(1, Some((name, t)))?, arm(2, Some((name, f)))?),
                        None => (arm(1, None)?, arm(2, None)?),
                    };
                    match (then_r, else_r) {
                        (Some(a), Some(b)) => Some((a.0.min(b.0), a.1.max(b.1))),
                        (Some(a), None) | (None, Some(a)) => Some(a),
                        (None, None) => None,
                    }
                }
                _ => None,
            }
        }
    }
}

/// For a condition `k <op> c` (either way round) with `k` a loop symbol of
/// `bx` and `c` a constant, `k`'s bounds where it holds and where it fails.
fn condition_refinement<'e>(
    cond: &'e Expr,
    bx: &LBox,
    refine: &[(&str, (f64, f64))],
) -> Option<(&'e str, (f64, f64), (f64, f64))> {
    let Expr::Operator(c) = cond else {
        return None;
    };
    if c.args.len() != 2 {
        return None;
    }
    let constant = |e: &Expr| int_range(e, bx, refine).filter(|r| r.0 == r.1).map(|r| r.0);
    let sym = |e: &'e Expr| match e {
        Expr::Variable(n)
            if bx.syms.contains(n) || refine.iter().any(|(r, _)| *r == n.as_str()) =>
        {
            Some(n.as_str())
        }
        _ => None,
    };
    // Normalize to `k <op> v`.
    let (name, op, v) = match (sym(&c.args[0]), sym(&c.args[1])) {
        (Some(n), _) if constant(&c.args[1]).is_some() => (n, c.op.as_str(), constant(&c.args[1])?),
        (_, Some(n)) if constant(&c.args[0]).is_some() => {
            let mirrored = match c.op.as_str() {
                "<" => ">",
                "<=" => ">=",
                ">" => "<",
                ">=" => "<=",
                other => other,
            };
            (n, mirrored, constant(&c.args[0])?)
        }
        _ => return None,
    };
    let (lo, hi) = int_range(&Expr::Variable(name.to_string()), bx, refine)?;
    let (t, f) = match op {
        "<" => ((lo, hi.min(v - 1.0)), (lo.max(v), hi)),
        "<=" => ((lo, hi.min(v)), (lo.max(v + 1.0), hi)),
        ">" => ((lo.max(v + 1.0), hi), (lo, hi.min(v))),
        ">=" => ((lo.max(v), hi), (lo, hi.min(v - 1.0))),
        "==" => ((lo.max(v), hi.min(v)), (lo, hi)),
        _ => return None,
    };
    Some((name, t, f))
}

/// Owned hoist key: everything a box-pure value can read from its box — the
/// structural analogue of the runtime `box_sig` + binder-set check.
#[derive(Hash, PartialEq, Eq, Clone)]
struct BoxKey {
    syms: Vec<String>,
    lo: Vec<i64>,
    shape: Vec<usize>,
    cnames: Vec<String>,
    cvals: Vec<i64>,
    /// Two tuple-list boxes of one length are different boxes.
    tuple: u32,
}

impl BoxKey {
    /// Whether this is `bx`'s key, without building one.
    fn is_of(&self, bx: &LBox) -> bool {
        self.tuple == bx.tuple
            && self.syms[..] == *bx.syms
            && self.lo[..] == bx.lo[..]
            && self.shape[..] == bx.shape[..]
            && self.cnames[..] == *bx.cnames
            && self.cvals[..] == bx.cvals[..]
    }

    fn of(bx: &LBox) -> BoxKey {
        BoxKey {
            syms: bx.syms.to_vec(),
            lo: bx.lo.to_vec(),
            shape: bx.shape.to_vec(),
            cnames: bx.cnames.to_vec(),
            cvals: bx.cvals.to_vec(),
            tuple: bx.tuple,
        }
    }
}

/// Scope-local value-numbering key.
#[derive(Hash, PartialEq, Eq, Clone, Copy)]
enum VnKey {
    /// Interned operator node address (`Arc::as_ptr`).
    Node(usize),
    /// Coordinate ramp along this output axis.
    Ramp(usize),
    /// An inline array `const` read whole (interned node address): the
    /// materialized literal, whatever box it is read in.
    ConstLit(usize),
}

#[derive(Default)]
struct ScopeFrame {
    map: FxHashMap<VnKey, LV>,
    /// Insertions made while inside a conditional branch, for rollback.
    journal: Vec<(VnKey, Option<LV>)>,
    /// The frame of a whole-body (`eval` mirror) lowering
    /// ([`TapeBuilder::lower_wholesale_rule`]): consulted only by the
    /// wholesale path, never by a box's numbering — one node's whole value
    /// and its value over a box are different values under the same key. A
    /// box lowered from a whole-body rule opens its own frame above it.
    wholesale: bool,
    /// The frames of this box's sub-boxes ([`TapeBuilder::lower_on_sub_box`]),
    /// by sub-box and branch depth, so terms moved to the same sub-box share
    /// their reads and subterms as they would in the box. A frame opened
    /// inside a branch is dropped when the branch closes.
    subs: FxHashMap<(BoxKey, usize), ScopeFrame>,
}

impl ScopeFrame {
    /// Forget every value naming a slot at or past `n_slots`, here and in
    /// the sub-box frames.
    fn retain_live(&mut self, n_slots: SlotId) {
        let dead = |lv: &LV| matches!(lv, LV::Scalar(s) | LV::Arr(s) if *s >= n_slots);
        self.map.retain(|_, lv| !dead(lv));
        self.journal
            .retain(|(_, prev)| !prev.as_ref().is_some_and(dead));
        for f in self.subs.values_mut() {
            f.retain_live(n_slots);
        }
    }
}

/// What a (taped or declined) observed rule left behind for later readers.
#[derive(Clone, Debug)]
enum ObsVal {
    /// Taped: the produced value, origin-normalized to all-1s.
    Taped(LV),
    /// Produced by a declined rule: the build already has no program, and a
    /// rule that reads it declines too, at the read.
    Declined,
}

/// Where, in the per-cell oracle's evaluation of one rule, a fail-closed
/// fault first fires: compared lexicographically, the smallest is the fault
/// the oracle latches first. It is the path of nested boxes down to the fault
/// site, each level contributing its first faulting cell in visiting order
/// (and the bound contraction tuple of an unrolled term), then a sequence
/// number in lowering order, which is the oracle's expression order within
/// one cell.
type FaultKey = SmallVec<[i64; 12]>;

// ---------------------------------------------------------------------------
// Builder.
// ---------------------------------------------------------------------------

/// An instruction and the precision its kernels run at: the one in force
/// while it was lowered (esm-spec §11.3.1).
type Tagged = (Instr, Precision);

struct Chunk {
    rule: u32,
    instrs: Vec<Tagged>,
}

pub(crate) struct TapeBuilder<'m> {
    var_shapes: &'m IndexMap<String, VarShape>,
    param_names: &'m [String],
    /// Position in `param_names` of each name's first occurrence.
    param_ix: FxHashMap<&'m str, usize>,
    /// Per-name observed cadence tier (from the driver's classifiers).
    obs_tier: FxHashMap<String, Cadence>,
    /// The model's CONST-ARRAY registry (CONFORMANCE_SPEC §5.5.5). A gather on
    /// one of these may not compile to this module's ghost-0 fill: an
    /// out-of-range const-array index resolves by the factor's declared
    /// boundary policy, and with no declared policy it is
    /// `E_TREEWALK_CONSTARRAY_OOB`. Each out-of-range arm therefore declines
    /// the rule when the base is one; an in-range gather
    /// compiles exactly as before.
    const_arrays: &'m ConstArrayScope,
    /// The program's observed rules, so a CONST-cadence observed the build
    /// must know (a join key column) can be folded from its own rule
    /// ([`TapeBuilder::fold_const_observed`]). Empty for a standalone rule.
    observed_rules: &'m [AlgebraicRule],
    /// Lower an array-valued `bool_and_or` reduction as one crisp scalar
    /// reduction per output cell, as the build pipeline's reference
    /// evaluator walks it ([`Self::array_combine_op`]). Set only for a
    /// pipeline observed on a standalone tape; everywhere else the compile
    /// path rejects the construct (CONFORMANCE_SPEC §5.6.1) before a tape is
    /// built, and the tape declines it too.
    array_bool_reductions: bool,
    /// Define every CONST payload ([`TapeBuilder::emit_const_data`]) as a
    /// [`Known::Deferred`] slot instead of with an [`Instr::ConstArray`], and
    /// resolve a gather of known data at build into its gathered values. Set
    /// only on the standalone tape of one tuple-list chunk
    /// ([`TapeBuilder::walk_tuple_contraction`]), which runs once and whose
    /// every input is build-time data: there the program would copy each
    /// whole input into its slab only to gather a chunk's worth of it.
    defer_consts: bool,
    /// The scalar parameters a join key column or an overlap envelope factor
    /// reads, with the values the build baked them at
    /// (`crate::join::join_key_cone`): build-time data to
    /// [`TapeBuilder::fold_const_observed`], since a substitution of one is
    /// refused (CONFORMANCE_SPEC §5.5.6, §5.5.8). Empty for a standalone
    /// rule.
    baked_params: FxHashMap<String, f64>,
    /// [`TapeBuilder::fold_const_observed`]'s memo.
    folded: std::cell::RefCell<FxHashMap<String, Option<(DimU, Arc<Vec<f64>>)>>>,

    // Program under construction -------------------------------------------
    tables: ProgramTables,
    /// Slots whose VALUES the build knows: array literals, and what the
    /// tuple-list lowering derives from them (`tuples`). Read only to resolve
    /// build-time data — a gather's subscripts, a join's key columns, a
    /// ragged bound — never to fold a value the program computes.
    known: FxHashMap<SlotId, Known>,
    /// Whether the counted bracket is recognised
    /// ([`Self::try_lower_indicator_count`]): the model's
    /// [`crate::problem::CompilerRewrites::count_fold`].
    count_fold: bool,
    /// Slots every element of which is known to lie in `[lo, hi]` (never
    /// NaN): a count, and what clamps and integer shifts make of one. Read
    /// only to prove a const-array gather's subscripts in range
    /// ([`Self::emit_data_gather`]), never to change a value.
    ranges: FxHashMap<SlotId, (f64, f64)>,
    /// Slots an instruction has defined: a second definition (a branch
    /// join's phi) drops the slot from `ranges` for good.
    range_defs: HashSet<SlotId>,
    /// The id the next tuple-list box gets (0 means "not a tuple box").
    next_tuple: u32,
    /// The enclosing list and repeat count of the next tuple-list box, when
    /// it is a nested reduction's list (`tuples::lower_nested_scalar_in_tuples`).
    next_tuple_parent: Option<(u32, usize)>,
    /// Tuples this program's tuple lists hold so far, against
    /// `tuples::tuple_list_budget`.
    tuples_held: u64,
    state_vars: Vec<StateRef>,
    /// Position in `state_vars`; narrowed to the IR's `u32` by [`tape_index`]
    /// where it is emitted.
    state_ix: FxHashMap<&'m str, usize>,
    /// Every name the forcing buffer can serve, with the box a read of it
    /// compiles against ([`ForcingInputs`]).
    forcing_shapes: FxHashMap<String, DimU>,
    forcing_unsized: HashSet<String>,
    /// The forcing names a provider refreshes between segments; their loads
    /// go in the SEGMENT section, every other forcing load in CONST.
    discrete_forcing: &'m HashSet<String>,
    forcings: Vec<ForcingRef>,
    forcing_ix: FxHashMap<String, u32>,
    /// The slot an UNCONDITIONAL load of `forcings[i]` defined, so every later
    /// read shares it; `forcing_journal` records the insertions of the current
    /// rule for rollback.
    forcing_loaded: FxHashMap<u32, LV>,
    forcing_journal: Vec<u32>,
    rules: Vec<RuleInfo>,
    /// Parallel to `rules`: the deepest decline reason of each rule that did
    /// not lower. Any `Some` means the build yields no program.
    declined: Vec<Option<Bail>>,
    /// Per-section chunk streams (index = Cadence as usize).
    streams: [Vec<Chunk>; 3],
    /// Home-stream chunk index per rule ordinal (for export insertion).
    rule_home_chunk: Vec<Option<usize>>,

    // Lowering state ---------------------------------------------------------
    /// What one rule's lowering holds open, reset when the rule rolls back.
    rule: RuleState,
    /// Where each fail-closed fault falls in the oracle's evaluation order.
    fault: FaultTrack,
    cur_rule: u32,
    home: Cadence,
    hoist: FxHashMap<(BoxKey, VnKey), LV>,
    /// Expressions the builder synthesized and lowered (the equality
    /// scatter's rewritten bodies and filters). Value numbering keys a node by
    /// its address, so each is held as long as the builder is: a freed node's
    /// address reused by another would otherwise hit its stale entry.
    held_exprs: Vec<Expr>,
    /// Hoist insertions of the CURRENT rule (rollback on bail).
    hoist_journal: Vec<(BoxKey, VnKey)>,
    /// Observed values defined so far, in rule order.
    obs_defined: FxHashMap<String, ObsVal>,
    /// [`TapeBuilder::sub_box_axes`]'s memo for the current rule, one per
    /// box: a node's axis mask over a box is scanned once, however many of
    /// the terms above it ask.
    sub_box_memo: Vec<(BoxKey, FxHashMap<usize, Option<u32>>)>,

    // Range restriction (API_SPEC §5.8) ----------------------------------------
    /// Set for a tile build: the domain of every state axis and the need box
    /// of every observed the tile keeps. `None` for every whole-domain build,
    /// which this field then leaves byte-identical.
    tile: Option<&'m TileLowering>,
    /// The observed slots a tile build materialized over their need box, with
    /// each axis's global extent: a read inside the extent but outside the
    /// slot is a build error, never the zero ghost.
    tile_slots: FxHashMap<SlotId, Vec<TileAxisDom>>,
    /// The slot and extent of the observed being lowered, committed to
    /// `tile_slots` when its rule lowers.
    tile_pending: Option<(SlotId, Vec<TileAxisDom>)>,
    /// Set while a classified tile read emits its instruction.
    tile_read_ok: bool,
    /// The first read of a range-restricted source through a path that does
    /// not classify its positions: the rule declines with it.
    tile_violation: Option<String>,

    // Diagnostics ------------------------------------------------------------
    vn_scope_hits: usize,
    vn_hoist_hits: usize,
}

/// The state one rule's lowering holds open: empty between rules, and reset
/// to empty when a rule's lowering rolls back ([`TapeBuilder::rollback`]).
#[derive(Default)]
struct RuleState {
    /// Value-numbering scopes, innermost last.
    scope_frames: Vec<ScopeFrame>,
    /// Nested conditional-branch buffers (top = innermost).
    branch_bufs: Vec<Vec<Tagged>>,
    /// Per open branch, the latest section any instruction buffered in it
    /// asked for: the earliest section the whole block could run in.
    branch_secs: Vec<Cadence>,
    /// The recurrence whose cell body is being lowered, if any.
    sweep: Option<SweepCtx>,
    /// Open tuple-list boxes, innermost last (`tuples`).
    tuple_frames: Vec<tuples::TupleFrame>,
}

/// Where each fail-closed fault the lowering meets falls in the per-cell
/// oracle's evaluation order, and which of them the program latches
/// ([`TapeBuilder::note_fault`], [`TapeBuilder::flush_rule_fault`]).
struct FaultTrack {
    /// The current rule's first fail-closed fault in the oracle's evaluation
    /// order, with its message: emitted as one [`Instr::Fault`] when the rule
    /// lowers ([`TapeBuilder::flush_rule_fault`]).
    first: Option<(FaultKey, String)>,
    /// Sequence number for the next fault site or nested box (lowering order).
    seq: i64,
    /// The [`FaultKey`] prefix of the box being lowered: one entry per
    /// enclosing box the oracle evaluates whole at each cell of its parent.
    prefix: FaultKey,
    /// Depth of positions the oracle evaluates for only SOME cells or tuples:
    /// the arms of an elementwise `ifelse`, a filtered term. A fault there
    /// may not fire where the tape would place it, so it goes to the rule's
    /// [`Instr::FaultScan`] ([`TapeBuilder::note_fault`]).
    lazy_depth: u32,
    /// Faults noted so far ([`TapeBuilder::note_fault`]), lazily evaluated ones
    /// included: a lowering that cannot place a fault compares it.
    notes: u32,
    /// The conditions that lead the oracle to the position being lowered,
    /// outermost first: one per lazily evaluated position the lowering
    /// can describe (an elementwise `ifelse` arm, a filtered term, a
    /// runtime-scalar branch), with the polarity that admits it.
    reach: Vec<(LV, bool)>,
    /// The current rule's faults at lazily evaluated positions, each with
    /// the key of the first cell it can fault at: one [`Instr::FaultScan`]
    /// decides at run time which (if any) the oracle meets first
    /// ([`TapeBuilder::flush_rule_fault`]).
    lazy: Vec<(FaultKey, FaultCand)>,
    /// Lazy faults noted so far: a value lowered while one was noted is not
    /// value-numbered, so a read the oracle evaluates everywhere cannot
    /// reuse it and lose its own fault.
    lazy_notes: u32,
    /// The latest section an earlier rule latches a fault in at run time
    /// (its [`Instr::FaultScan`], a faulting [`Instr::DataGather`]). Across
    /// rules the first latched fault stays, so a later rule's faults run no
    /// earlier than this: the oracle walks the rules in order, and a later
    /// rule's fault in an earlier section would latch ahead of it.
    floor: Cadence,
    /// The current rule's contribution to [`FaultTrack::floor`], committed
    /// when the rule lowers ([`TapeBuilder::flush_rule_fault`]).
    rule_sec: Cadence,
}

impl Default for FaultTrack {
    fn default() -> Self {
        FaultTrack {
            first: None,
            seq: 0,
            prefix: FaultKey::new(),
            lazy_depth: 0,
            notes: 0,
            reach: Vec::new(),
            lazy: Vec::new(),
            lazy_notes: 0,
            floor: Cadence::Const,
            rule_sec: Cadence::Const,
        }
    }
}

impl FaultTrack {
    /// Forget what the current rule's lowering noted (its rollback).
    fn reset_rule(&mut self) {
        self.first = None;
        self.prefix.clear();
        self.lazy_depth = 0;
        self.reach.clear();
        self.lazy.clear();
        self.rule_sec = Cadence::Const;
    }
}

/// What a tile build knows beyond the compiled rules (API_SPEC §5.8): each
/// state variable's per-axis domain, in `var_shapes` order (its slot box is
/// its storage box), and how each kept array observed is computed.
pub(crate) struct TileLowering {
    pub(crate) states: Vec<Vec<TileAxisDom>>,
    pub(crate) observed: FxHashMap<String, TileObserved>,
}

/// An array observed of a tile build, materialized over its need: a slot
/// over `lo..=hi` per axis, filled piece by piece (zero elsewhere). Along an
/// axis whose need crosses a periodic seam the slot is unwrapped: it runs
/// past the period, and the cells past it hold the cells after the seam.
pub(crate) struct TileObserved {
    pub(crate) lo: DimI,
    pub(crate) hi: DimI,
    /// Per axis, the period a read wraps by to reach the slot's unwrapped
    /// cells (`None` where the slot is not unwrapped).
    pub(crate) period: SmallVec<[Option<i64>; 4]>,
    pub(crate) pieces: Vec<TilePiece>,
}

/// One box of an observed's own cells: the global `ranges` it computes, with
/// `body` (the rule's body restricted to them), placed at the 0-based
/// `dest_lo` of the slot.
pub(crate) struct TilePiece {
    pub(crate) ranges: Vec<(i64, i64)>,
    pub(crate) dest_lo: Vec<usize>,
    pub(crate) body: std::rc::Rc<Expr>,
}

/// One axis of a range-restricted source: the global domain `lo..=hi` its
/// reads are classified against, the period of a periodic axis, and the
/// index-set name a diagnostic reports.
#[derive(Clone, Debug)]
pub(crate) struct TileAxisDom {
    pub(crate) lo: i64,
    pub(crate) hi: i64,
    pub(crate) period: Option<i64>,
    pub(crate) set: String,
}

/// Where one tile read resolves (RFC U3 §4 rule 2).
enum TileHit {
    /// Outside the global domain: the zero ghost, as the whole-domain program.
    Ghost,
    /// The 0-based position in the source's slot box.
    At(i64),
}

/// A slot's build-time value (see `TapeBuilder::known`).
#[derive(Clone, Debug)]
enum Known {
    /// The payload of the `ConstArray` that defines it.
    Data(u32),
    /// Values the build computed itself, row-major.
    Vals(Arc<Vec<f64>>),
    /// Values the build knows for a CONST slot no instruction defines yet:
    /// under [`TapeBuilder::defer_consts`], the slot's [`Instr::ConstArray`]
    /// is emitted at the head of the program only if an instruction ends up
    /// reading it ([`TapeBuilder::materialize_deferred`]), tagged with the
    /// rule and precision in force where the payload was bound.
    Deferred {
        vals: Arc<Vec<f64>>,
        rule: u32,
        prec: Precision,
    },
}

/// The recurrence whose cell body is being lowered
/// ([`TapeBuilder::lower_recurrence`]).
///
/// The body is lowered ONCE, with each frame symbol bound to a coordinate
/// slot the [`Instr::Sweep`] rewrites before every pass. An instruction that
/// reads a value depending on the cell — a coordinate, the array being built,
/// or anything computed from them — belongs to the body and runs per cell;
/// every other instruction is the same at every cell and is emitted ahead of
/// the sweep instead, once (see [`TapeBuilder::emit_tagged`]).
struct SweepCtx {
    /// Index of the sweep's entry in `sweeps`.
    spec: u32,
    /// The variable being defined.
    var: String,
    /// The array being built.
    out: SlotId,
    /// Each frame symbol and the coordinate slot it reads.
    binds: SmallVec<[(String, SlotId); 4]>,
    /// Slots defined inside the body (plus the coordinates and the array):
    /// a reader of one of these runs per cell too.
    body_slots: rustc_hash::FxHashSet<SlotId>,
    /// The body, in program order.
    body: Vec<Tagged>,
}

/// `r`, the result of the form tried after an earlier attempt declined
/// with `first`: a decline of both is the more informative one
/// ([`Bail::or_later`]).
fn after_decline<T>(first: Option<Bail>, r: LResult<T>) -> LResult<T> {
    match (first, r) {
        (Some(first), Err(later)) => Err(first.or_later(later)),
        (_, r) => r,
    }
}

/// Snapshot for transactional per-rule lowering.
struct RuleTxn {
    tables: TablesMark,
    stream_lens: [usize; 3],
    hoist_journal: usize,
    forcing_journal: usize,
    /// [`TapeBuilder::tuples_held`]: a rolled-back rule's lists are not held.
    tuples_held: u64,
}

/// Snapshot for undoing a failed ATTEMPT inside one rule (a looped form that
/// bails and hands over to its unrolled equivalent), as opposed to
/// [`RuleTxn`], which undoes a whole rule. The attempt keeps its own
/// value-numbering scopes balanced, so only emitted state is recorded: the
/// tables, and how far each stream (or the open branch buffer) had grown.
struct SubTxn {
    tables: TablesMark,
    /// Per stream: `(chunk count, instructions in the last chunk)`.
    streams: [(usize, usize); 3],
    branch_len: Option<usize>,
    /// Length of the open recurrence body, if any.
    sweep_body: Option<usize>,
    hoist_journal: usize,
    forcing_journal: usize,
    fault_first: Option<(FaultKey, String)>,
    fault_seq: i64,
    lazy_faults: usize,
    /// [`TapeBuilder::tuples_held`]: a list charged by a failed attempt is
    /// not held.
    tuples_held: u64,
}

impl<'m> TapeBuilder<'m> {
    fn new(
        var_shapes: &'m IndexMap<String, VarShape>,
        param_names: &'m [String],
        obs_tier: FxHashMap<String, Cadence>,
        const_arrays: &'m ConstArrayScope,
        forcing: &ForcingInputs<'m>,
    ) -> Self {
        let mut state_vars = Vec::with_capacity(var_shapes.len());
        let mut state_ix = FxHashMap::default();
        for (name, vs) in var_shapes {
            state_ix.insert(name.as_str(), state_vars.len());
            state_vars.push(StateRef {
                name: name.clone(),
                shape: vs.shape.iter().copied().collect(),
                origin: vs.origin.iter().copied().collect(),
                flat_offset: vs.flat_offset,
            });
        }
        let mut param_ix = FxHashMap::default();
        for (i, name) in param_names.iter().enumerate() {
            param_ix.entry(name.as_str()).or_insert(i);
        }
        TapeBuilder {
            var_shapes,
            param_names,
            param_ix,
            obs_tier,
            const_arrays,
            observed_rules: &[],
            baked_params: FxHashMap::default(),
            array_bool_reductions: false,
            defer_consts: false,
            folded: std::cell::RefCell::new(FxHashMap::default()),
            tables: ProgramTables::default(),
            rule: RuleState::default(),
            fault: FaultTrack::default(),
            known: FxHashMap::default(),
            count_fold: true,
            ranges: FxHashMap::default(),
            range_defs: HashSet::new(),
            next_tuple: 1,
            next_tuple_parent: None,
            tuples_held: 0,
            state_vars,
            state_ix,
            forcing_shapes: forcing.shapes.clone(),
            forcing_unsized: forcing.unsized_.clone(),
            discrete_forcing: forcing.discrete,
            forcings: Vec::new(),
            forcing_ix: FxHashMap::default(),
            forcing_loaded: FxHashMap::default(),
            forcing_journal: Vec::new(),
            rules: Vec::new(),
            declined: Vec::new(),
            streams: [Vec::new(), Vec::new(), Vec::new()],
            rule_home_chunk: Vec::new(),
            cur_rule: 0,
            home: Cadence::Continuous,
            hoist: FxHashMap::default(),
            held_exprs: Vec::new(),
            hoist_journal: Vec::new(),
            obs_defined: FxHashMap::default(),
            sub_box_memo: Vec::new(),
            tile: None,
            tile_slots: FxHashMap::default(),
            tile_pending: None,
            tile_read_ok: false,
            tile_violation: None,
            vn_scope_hits: 0,
            vn_hoist_hits: 0,
        }
    }

    // -- emission ------------------------------------------------------------

    fn in_branch(&self) -> bool {
        !self.rule.branch_bufs.is_empty()
    }

    /// Section an instruction with operand cadence `want` lands in.
    ///
    /// Inside a conditional branch the instruction is buffered with its
    /// block, and the block's section is settled when it closes
    /// ([`Self::lower_branchy`]); the cadence returned here is provisional
    /// and the block raises every slot it defines to the section it lands in.
    fn placement(&self, want: Cadence) -> Cadence {
        if self.in_branch() {
            if self.rule.sweep.is_some() {
                self.home
            } else {
                want.min(self.home)
            }
        } else {
            debug_assert!(
                want <= self.home,
                "instruction cadence {want:?} exceeds rule home {:?}",
                self.home
            );
            want.min(self.home)
        }
    }

    fn emit(&mut self, instr: Instr, section: Cadence) {
        self.emit_tagged(instr, crate::precision::active(), section);
    }

    /// [`Self::emit`] at a stated precision (a branch's buffered
    /// instructions keep the precision they were lowered at).
    ///
    /// Inside a recurrence body ([`SweepCtx`]) this is where an instruction
    /// is placed: in the body, to run once per cell, when it reads a value
    /// that depends on the cell, or when it sits in a conditional branch and
    /// could fault or has an effect; otherwise ahead of the sweep, once. The
    /// second case is what keeps a literal table, a parameter expression or a
    /// whole-array reduction the body merely reads from being recomputed at
    /// every cell. A value the body only reads in some cells (an untaken
    /// branch) may then be computed once ahead of it — which only ever costs
    /// work, since what is hoisted is a pure map that cannot fault.
    fn emit_tagged(&mut self, instr: Instr, prec: Precision, section: Cadence) {
        self.track_known(&instr);
        self.track_range(&instr);
        if self.rule.sweep.is_some() {
            if self.reads_body(&instr) || (self.in_branch() && !Self::hoistable(&instr)) {
                self.mark_body_defs(&instr);
                self.push_body(instr, prec);
            } else {
                self.push_stream(instr, prec, section);
            }
            return;
        }
        if self.in_branch() {
            // A pure instruction that cannot fault and whose operands are
            // available in an earlier section runs there, unconditionally:
            // computing it where the branch is not taken only costs work.
            if section < self.home && Self::hoistable(&instr) {
                self.push_stream(instr, prec, section);
                return;
            }
            // Anything else runs with its block, at the block's section,
            // which is the rule's home unless the whole block moves
            // ([`Self::lower_branchy`]).
            let mut defs: SmallVec<[SlotId; 2]> = SmallVec::new();
            instr.for_each_def(&self.slot_tables(), |s| defs.push(s));
            for s in defs {
                self.tables.slots[s as usize].cadence = self.home;
            }
            if let Some(m) = self.rule.branch_secs.last_mut() {
                *m = (*m).max(section.min(self.home));
            }
            if let Some(buf) = self.rule.branch_bufs.last_mut() {
                buf.push((instr, prec));
            }
            return;
        }
        self.push_stream(instr, prec, section);
    }

    /// Record the build-time value an instruction defines (see `known`).
    fn track_known(&mut self, instr: &Instr) {
        match instr {
            Instr::ConstArray { data, out } => {
                self.known.insert(*out, Known::Data(*data));
            }
            Instr::Copy {
                a: Operand::Slot(a),
                out,
            } if !self.tables.slots[*out as usize].scalar => {
                if let Some(k) = self.known.get(a).cloned() {
                    // The copy has an instruction of its own: only its
                    // source's may still be deferred.
                    let k = match k {
                        Known::Deferred { vals, .. } => Known::Vals(vals),
                        k => k,
                    };
                    self.known.insert(*out, k);
                }
            }
            _ => {}
        }
    }

    /// Record the bounds an instruction's value is known to lie in (see
    /// `ranges`). Interval arithmetic on `+` and `-` is kept to integer
    /// endpoints below 2^24, where every endpoint is exact at either working
    /// precision and rounding, being monotone, keeps each element inside.
    fn track_range(&mut self, instr: &Instr) {
        let Some(out) = instr.out() else {
            return;
        };
        if !self.range_defs.insert(out) {
            self.ranges.remove(&out);
            return;
        }
        let exact = |v: f64| v.fract() == 0.0 && v.abs() < 16_777_216.0;
        let r = match instr {
            Instr::Count { n, .. } => Some((0.0, *n as f64)),
            Instr::Copy { a, .. } | Instr::Fill { v: a, .. } => self.operand_range(a),
            Instr::Bin { op, a, b, .. } => match (self.operand_range(a), self.operand_range(b)) {
                (Some(x), Some(y)) => match op {
                    BinCode::Max => Some((x.0.max(y.0), x.1.max(y.1))),
                    BinCode::Min => Some((x.0.min(y.0), x.1.min(y.1))),
                    BinCode::Add if [x.0, x.1, y.0, y.1].into_iter().all(exact) => {
                        Some((x.0 + y.0, x.1 + y.1)).filter(|r| exact(r.0) && exact(r.1))
                    }
                    BinCode::Sub if [x.0, x.1, y.0, y.1].into_iter().all(exact) => {
                        Some((x.0 - y.1, x.1 - y.0)).filter(|r| exact(r.0) && exact(r.1))
                    }
                    _ => None,
                },
                _ => None,
            },
            // A gather that covers its whole box reads only source elements
            // (no zero ghost).
            Instr::Gather {
                src: SrcRef::Slot(s),
                plan,
                ..
            } => {
                let p = &self.tables.plans[*plan as usize];
                let covered = p
                    .segs
                    .iter()
                    .zip(&p.shape)
                    .all(|(segs, &n)| segs.iter().map(|&(_, len, _)| len).sum::<usize>() == n);
                if covered {
                    self.ranges.get(s).copied()
                } else {
                    None
                }
            }
            _ => None,
        };
        if let Some(r) = r {
            self.ranges.insert(out, r);
        }
    }

    /// The bounds of an operand's value, when known: a finite literal, or a
    /// slot in `ranges`.
    fn operand_range(&self, o: &Operand) -> Option<(f64, f64)> {
        match o {
            Operand::Lit(v) if v.is_finite() => Some((*v, *v)),
            Operand::Slot(s) => self.ranges.get(s).copied(),
            _ => None,
        }
    }

    /// Append to the current rule's chunk of `section`'s stream.
    fn push_stream(&mut self, instr: Instr, prec: Precision, section: Cadence) {
        let stream = &mut self.streams[section as usize];
        match stream.last_mut() {
            Some(c) if c.rule == self.cur_rule => c.instrs.push((instr, prec)),
            _ => stream.push(Chunk {
                rule: self.cur_rule,
                instrs: vec![(instr, prec)],
            }),
        }
    }

    fn new_slot(
        &mut self,
        shape: &[usize],
        origin: &[i64],
        scalar: bool,
        cadence: Cadence,
    ) -> SlotId {
        let id = self.tables.slots.len() as SlotId;
        self.tables.slots.push(SlotDesc {
            shape: shape.iter().copied().collect(),
            origin: origin.iter().copied().collect(),
            scalar,
            cadence,
            storage: u32::MAX,
        });
        id
    }

    // -- recurrence bodies ----------------------------------------------------

    /// The tables [`Instr::for_each_read`] and [`Instr::for_each_def`] consult,
    /// as far as the program under construction has them.
    fn slot_tables(&self) -> SlotTables<'_> {
        SlotTables {
            dy_writes: &self.tables.dy_writes,
            fused: &[],
            assemblies: &self.tables.assemblies,
            sweeps: &self.tables.sweeps,
            scalar_reads: &self.tables.scalar_reads,
            data_gathers: &self.tables.data_gathers,
            lanes: &[],
            fault_scans: &self.tables.fault_scans,
        }
    }

    /// Does `instr` read a value defined in the open recurrence body?
    fn reads_body(&self, instr: &Instr) -> bool {
        let Some(sw) = &self.rule.sweep else {
            return false;
        };
        let mut hit = false;
        instr.for_each_read(&self.slot_tables(), |s| hit |= sw.body_slots.contains(&s));
        hit
    }

    /// Record the slots `instr` defines as body slots, at the rule's cadence.
    fn mark_body_defs(&mut self, instr: &Instr) {
        let mut defs: SmallVec<[SlotId; 2]> = SmallVec::new();
        instr.for_each_def(&self.slot_tables(), |s| defs.push(s));
        let home = self.home;
        for s in defs {
            self.tables.slots[s as usize].cadence = home;
            if let Some(sw) = self.rule.sweep.as_mut() {
                sw.body_slots.insert(s);
            }
        }
    }

    /// Append to the open branch, or else to the open recurrence body.
    fn push_body(&mut self, instr: Instr, prec: Precision) {
        if let Some(buf) = self.rule.branch_bufs.last_mut() {
            buf.push((instr, prec));
        } else if let Some(sw) = self.rule.sweep.as_mut() {
            sw.body.push((instr, prec));
        }
    }

    /// An instruction that computes a pure map of its operands and can
    /// neither fault nor touch anything outside its own slot, so it may run
    /// where its operands are available rather than where it was lowered.
    fn hoistable(instr: &Instr) -> bool {
        instr.effect() == Effect::Pure
    }

    // -- LV helpers -----------------------------------------------------------

    /// The array box of an LV, or `None` for a scalar kind.
    fn lv_box(&self, lv: &LV) -> Option<(DimU, DimI)> {
        match lv {
            LV::Lit(_) | LV::Param(_) | LV::Time | LV::Scalar(_) => None,
            LV::Arr(s) => {
                let d = &self.tables.slots[*s as usize];
                Some((d.shape.clone(), d.origin.clone()))
            }
            LV::State(ix) => {
                let sv = &self.state_vars[*ix as usize];
                if sv.shape.is_empty() {
                    None
                } else if self.tile.is_some() {
                    // A tile's state is its storage box, at its global origin.
                    Some((sv.shape.clone(), sv.origin.clone()))
                } else {
                    Some((sv.shape.clone(), DimI::from_elem(1, sv.shape.len())))
                }
            }
        }
    }

    fn lv_cadence(&self, lv: &LV) -> Cadence {
        match lv {
            LV::Lit(_) | LV::Param(_) => Cadence::Const,
            LV::Time | LV::State(_) => Cadence::Continuous,
            LV::Scalar(s) | LV::Arr(s) => self.tables.slots[*s as usize].cadence,
        }
    }

    fn op_of(&self, lv: &LV) -> Operand {
        match lv {
            LV::Lit(v) => Operand::Lit(*v),
            LV::Param(p) => Operand::Param(*p),
            LV::Time => Operand::Time,
            LV::Scalar(s) | LV::Arr(s) => Operand::Slot(*s),
            LV::State(ix) => Operand::State(*ix),
        }
    }

    fn src_of(&mut self, lv: &LV) -> SrcRef {
        if self.tile.is_some()
            && !self.tile_read_ok
            && self.tile_violation.is_none()
            && let Some((name, _)) = self.tile_source(lv)
        {
            self.tile_violation = Some(format!(
                "tile restriction: `{name}` is read whole or through a computed subscript, \
                 which a range-restricted program cannot classify against its storage box"
            ));
        }
        match lv {
            LV::Arr(s) => SrcRef::Slot(*s),
            LV::State(ix) => SrcRef::State(*ix),
            _ => unreachable!("src_of called on a scalar LV"),
        }
    }

    /// The name and per-axis domain of a range-restricted source: a state of
    /// a tile build, or an observed it materialized over its need box. `None`
    /// for every other value, and always outside a tile build.
    fn tile_source(&self, lv: &LV) -> Option<(String, Vec<TileAxisDom>)> {
        let tile = self.tile?;
        match lv {
            LV::State(ix) => {
                let axes = tile.states.get(*ix as usize)?;
                (!axes.is_empty())
                    .then(|| (self.state_vars[*ix as usize].name.clone(), axes.clone()))
            }
            LV::Arr(slot) => {
                let axes = self.tile_slots.get(slot)?;
                let name = self
                    .obs_defined
                    .iter()
                    .find(|(_, v)| matches!(v, ObsVal::Taped(LV::Arr(s)) if s == slot))
                    .map(|(n, _)| n.clone())
                    .unwrap_or_else(|| format!("slot {slot}"));
                Some((name, axes.clone()))
            }
            _ => None,
        }
    }

    /// Resolve one read of a range-restricted source at global subscript `g`
    /// along an axis whose slot box starts at `box_lo` and spans `box_len`
    /// cells (RFC U3 §4 rule 2): outside the global domain it is the zero
    /// ghost the whole-domain program reads there; inside the slot box it is
    /// that cell; on a periodic axis `g ± N` inside the slot box is that
    /// cell. `None` when the cell is in the domain and nowhere in the box.
    fn tile_resolve(dom: &TileAxisDom, box_lo: i64, box_len: i64, g: i64) -> Option<TileHit> {
        if g < dom.lo || g > dom.hi {
            return Some(TileHit::Ghost);
        }
        let inside = |x: i64| x >= box_lo && x < box_lo + box_len;
        if inside(g) {
            return Some(TileHit::At(g - box_lo));
        }
        if let Some(n) = dom.period {
            for x in [g - n, g + n] {
                if inside(x) {
                    return Some(TileHit::At(x - box_lo));
                }
            }
        }
        None
    }

    /// The `range_halo_insufficient` refusal of a read of `name` along `dom`
    /// at the in-domain cells `missing`, which the box `box_lo..box_lo+len`
    /// does not hold.
    fn tile_halo_bail<T>(
        &self,
        name: &str,
        dom: &TileAxisDom,
        missing: &[i64],
        box_lo: i64,
        box_len: i64,
    ) -> LResult<T> {
        let lo = missing.iter().copied().min().unwrap_or(0);
        let hi = missing.iter().copied().max().unwrap_or(0);
        let rule = self
            .rules
            .get(self.cur_rule as usize)
            .map(|r| r.name.as_str())
            .unwrap_or("?");
        Err(Bail::coded(
            crate::diagnostic::codes::RANGE_HALO_INSUFFICIENT,
            format!(
                "rule `{rule}` reads `{name}` along `{}` at cells {lo}..{hi}, which its \
                 storage box {box_lo}..{} does not hold",
                dom.set,
                box_lo + box_len - 1
            ),
        ))
    }

    /// `index(src, …)` of a range-restricted source with every subscript an
    /// affine map of one output axis, a periodic wrap of one, or a constant:
    /// each position is resolved by [`Self::tile_resolve`] and the runs that
    /// read consecutive source cells become the gather's copy segments.
    fn lower_tile_gather(
        &mut self,
        bx: &LBox,
        arg0: &LV,
        name: &str,
        axes: &[TileAxisDom],
        read: &IndexRead,
    ) -> LResult<LV> {
        let IndexRead {
            src_shape,
            src_origin,
            mapped,
            fixed_raw,
            ..
        } = *read;
        let out_ndim = bx.shape.len();
        let mut fixed: SmallVec<[(usize, i64); 4]> = SmallVec::new();
        let mut any_ghost = false;
        for &(d, g) in fixed_raw {
            match Self::tile_resolve(&axes[d], src_origin[d], src_shape[d] as i64, g) {
                Some(TileHit::Ghost) => {
                    any_ghost = true;
                    fixed.push((d, 0));
                }
                Some(TileHit::At(i0)) => fixed.push((d, i0)),
                None => {
                    return self.tile_halo_bail(
                        name,
                        &axes[d],
                        &[g],
                        src_origin[d],
                        src_shape[d] as i64,
                    );
                }
            }
        }
        let n_mapped = mapped.iter().filter(|m| m.is_some()).count();
        let mut axis_segs: SmallVec<[SmallVec<[(usize, usize, usize); 2]>; 4]> = SmallVec::new();
        for a in 0..out_ndim {
            let Some((d, ax)) = &mapped[a] else {
                let mut segs = SmallVec::new();
                segs.push((0usize, bx.shape[a], 0usize));
                axis_segs.push(segs);
                continue;
            };
            let d = *d;
            let mut segs: SmallVec<[(usize, usize, usize); 2]> = SmallVec::new();
            let mut missing: Vec<i64> = Vec::new();
            let mut run: Option<(usize, usize, i64)> = None; // (out start, len, src start)
            for p in 0..bx.shape[a] {
                let g = match ax {
                    AxisIndex::Affine(k) => bx.lo[a] + p as i64 + k,
                    AxisIndex::Wrap { k, period, lo } => {
                        wrap_subscript(bx.lo[a], p as i64, (*k, *lo, *period))
                    }
                };
                match Self::tile_resolve(&axes[d], src_origin[d], src_shape[d] as i64, g) {
                    Some(TileHit::At(sp)) => match &mut run {
                        Some((o, len, s0)) if *s0 + *len as i64 == sp && *o + *len == p => {
                            *len += 1;
                        }
                        _ => {
                            if let Some((o, len, s0)) = run.take() {
                                segs.push((o, len, s0 as usize));
                            }
                            run = Some((p, 1, sp));
                        }
                    },
                    Some(TileHit::Ghost) => {
                        if let Some((o, len, s0)) = run.take() {
                            segs.push((o, len, s0 as usize));
                        }
                    }
                    None => missing.push(g),
                }
            }
            if let Some((o, len, s0)) = run.take() {
                segs.push((o, len, s0 as usize));
            }
            if !missing.is_empty() {
                return self.tile_halo_bail(
                    name,
                    &axes[d],
                    &missing,
                    src_origin[d],
                    src_shape[d] as i64,
                );
            }
            if segs.is_empty() {
                any_ghost = true;
            }
            axis_segs.push(segs);
        }
        if any_ghost {
            return Ok(if n_mapped == 0 {
                LV::Lit(0.0)
            } else {
                self.emit_zero_array(&bx.shape, &bx.lo)
            });
        }
        self.tile_read_ok = true;
        let v = if n_mapped == 0 {
            self.emit_load_elem(arg0, &fixed)
        } else {
            let fixed_desc: SmallVec<[(usize, usize); 4]> =
                fixed.iter().map(|&(d, i0)| (d, i0 as usize)).collect();
            let mapped_flags: SmallVec<[bool; 4]> = mapped.iter().map(|m| m.is_some()).collect();
            let mapped_src: SmallVec<[usize; 4]> = mapped
                .iter()
                .filter_map(|m| m.as_ref().map(|(d, _)| *d))
                .collect();
            self.emit_gather(
                arg0,
                fixed_desc,
                &mapped_src,
                mapped_flags,
                axis_segs,
                &bx.shape,
                &bx.lo,
            )
        };
        self.tile_read_ok = false;
        Ok(v)
    }

    /// `index(src, …)` of a range-restricted source whose subscript along
    /// source axis `data_d` is data (`u[i, nbr[i, k]]`). The read is exact
    /// only when the slot holds that axis whole, exactly its global domain
    /// (an axis the decomposition does not cut), so the data subscript means
    /// what it means to the whole-domain program; along a cut axis it is
    /// `range_global_locality`. Every other subscript is classified as
    /// [`Self::lower_tile_gather`] classifies it, and must read one run of
    /// stored cells.
    fn lower_tile_index_gather(
        &mut self,
        node: &Arc<ExpressionNode>,
        bx: &LBox,
        arg0: &LV,
        name: &str,
        axes: &[TileAxisDom],
        read: &IndexRead,
    ) -> LResult<LV> {
        let IndexRead {
            src_shape,
            src_origin,
            mapped,
            fixed_raw,
            ..
        } = *read;
        let data_d = read.data_axis.expect("a read with a computed subscript");
        let dom = &axes[data_d];
        let whole = src_origin[data_d] == dom.lo && src_shape[data_d] as i64 == dom.hi - dom.lo + 1;
        if !whole {
            return Err(Bail::coded(
                crate::diagnostic::codes::RANGE_GLOBAL_LOCALITY,
                format!(
                    "`{name}` is read at a computed subscript along the decomposed axis `{}`",
                    dom.set
                ),
            ));
        }
        if dom.lo != 1 {
            bail_tape!(
                "tile restriction: `{name}` is read at a computed subscript along `{}`, \
                 whose domain does not start at 1",
                dom.set
            );
        }
        let mut gaxes: SmallVec<[GatherAxis; 4]> =
            SmallVec::from_elem(GatherAxis::Fixed(0), src_shape.len());
        gaxes[data_d] = GatherAxis::Data;
        for &(d, g) in fixed_raw {
            match Self::tile_resolve(&axes[d], src_origin[d], src_shape[d] as i64, g) {
                // Out of the global domain: every element of the read is the
                // zero ghost, as in the whole-domain program.
                Some(TileHit::Ghost) => return Ok(self.emit_zero_array(&bx.shape, &bx.lo)),
                Some(TileHit::At(i0)) => gaxes[d] = GatherAxis::Fixed(i0 as usize),
                None => {
                    return self.tile_halo_bail(
                        name,
                        &axes[d],
                        &[g],
                        src_origin[d],
                        src_shape[d] as i64,
                    );
                }
            }
        }
        for (a, m) in mapped.iter().enumerate() {
            let Some((d, ax)) = m else { continue };
            let d = *d;
            let AxisIndex::Affine(k) = ax else {
                bail_tape!(
                    "tile restriction: `{name}` is read at a computed subscript together with a \
                     periodic wrap along `{}`",
                    axes[d].set
                );
            };
            let mut off: Option<i64> = None;
            let mut missing: Vec<i64> = Vec::new();
            for p in 0..bx.shape[a] as i64 {
                let g = bx.lo[a] + p + k;
                match Self::tile_resolve(&axes[d], src_origin[d], src_shape[d] as i64, g) {
                    Some(TileHit::At(sp)) => match off {
                        None => off = Some(sp - p),
                        Some(o) if o + p == sp => {}
                        Some(_) => bail_tape!(
                            "tile restriction: `{name}` is read at a computed subscript and \
                             across a periodic seam along `{}`",
                            axes[d].set
                        ),
                    },
                    Some(TileHit::Ghost) => bail_tape!(
                        "tile restriction: `{name}` is read at a computed subscript and past the \
                         edge of the domain along `{}`",
                        axes[d].set
                    ),
                    None => missing.push(g),
                }
            }
            if !missing.is_empty() {
                return self.tile_halo_bail(
                    name,
                    &axes[d],
                    &missing,
                    src_origin[d],
                    src_shape[d] as i64,
                );
            }
            gaxes[d] = GatherAxis::Affine {
                axis: a as u8,
                off: off.unwrap_or(0),
            };
        }
        match self.emit_index_gather(node, bx, arg0, data_d, gaxes, src_shape.into())? {
            Some(v) => Ok(v),
            None => bail_tape!(
                "tile restriction: `{name}`'s computed subscript is not evaluated over the \
                 read's own box"
            ),
        }
    }

    /// A read of `name` served by the forcing buffer: `lookup_variable`'s last
    /// arm, reached only after `t`, the state, the observeds and the
    /// parameters, exactly as there. `None` when the buffer cannot serve the
    /// name.
    ///
    /// One [`Instr::LoadForcing`] per forcing, in the section its cadence
    /// allows, shared by every later read. A load made inside a conditional
    /// branch is not shared, since the branch may not run.
    fn forcing_read(&mut self, name: &str) -> LResult<Option<LV>> {
        let Some(shape) = self.forcing_shapes.get(name).cloned() else {
            if self.forcing_unsized.contains(name) {
                bail_tape!(
                    "forcing `{name}`: its declared shape names an index set the registry \
                     cannot size, and the forcing buffer held no entry for it when the tape \
                     was built, so there is no box to compile its read against"
                );
            }
            return Ok(None);
        };
        let ix = match self.forcing_ix.get(name) {
            Some(&ix) => ix,
            None => {
                let ix = tape_index(self.forcings.len(), "forcing reads")?;
                self.forcings.push(ForcingRef {
                    name: name.to_string(),
                    shape: shape.clone(),
                });
                self.forcing_ix.insert(name.to_string(), ix);
                ix
            }
        };
        if let Some(lv) = self.forcing_loaded.get(&ix) {
            return Ok(Some(lv.clone()));
        }
        let cadence = if self.discrete_forcing.contains(name) {
            Cadence::Segment
        } else {
            Cadence::Const
        };
        let sec = self.placement(cadence);
        let scalar = shape.is_empty();
        let out = self.new_slot(&shape, &DimI::from_elem(1, shape.len()), scalar, sec);
        self.emit(Instr::LoadForcing { forcing: ix, out }, sec);
        let lv = if scalar {
            LV::Scalar(out)
        } else {
            LV::Arr(out)
        };
        if !self.in_branch() {
            self.forcing_loaded.insert(ix, lv.clone());
            self.forcing_journal.push(ix);
        }
        Ok(Some(lv))
    }

    // -- scopes / VN ----------------------------------------------------------

    fn push_scope(&mut self) {
        self.rule.scope_frames.push(ScopeFrame::default());
    }

    fn pop_scope(&mut self) {
        self.rule.scope_frames.pop();
    }

    fn vn_get(&mut self, key: VnKey, bx: &LBox) -> Option<LV> {
        // A box lowering opens its own frame (`push_scope`); reaching one
        // with the whole-body frame innermost would number nothing.
        debug_assert!(
            !self.rule.scope_frames.last().is_some_and(|f| f.wholesale),
            "box value numbering under a whole-body frame: the box lowering did not open a scope"
        );
        if let Some(frame) = self.rule.scope_frames.last().filter(|f| !f.wholesale) {
            if let Some(lv) = frame.map.get(&key) {
                self.vn_scope_hits += 1;
                return Some(lv.clone());
            }
        }
        if let Some(lv) = self.hoist.get(&(BoxKey::of(bx), key)) {
            self.vn_hoist_hits += 1;
            return Some(lv.clone());
        }
        None
    }

    fn vn_put(&mut self, key: VnKey, lv: &LV, bx: &LBox) {
        if !self.rule.scope_frames.last().is_some_and(|f| f.wholesale) {
            self.frame_put(key, lv);
        }
        let in_branch = self.in_branch();
        // The cross-rule hoist (ess-lih analogue): only for values whose
        // cadence is ≤ SEGMENT — pure functions of (box, structure, constant
        // tier) — and only when computed UNCONDITIONALLY.
        let in_body = match (lv, &self.rule.sweep) {
            (LV::Scalar(s) | LV::Arr(s), Some(sw)) => sw.body_slots.contains(s),
            _ => false,
        };
        if !in_branch && !in_body && self.lv_cadence(lv) <= Cadence::Segment {
            let hk = (BoxKey::of(bx), key);
            if self.hoist.insert(hk.clone(), lv.clone()).is_none() {
                self.hoist_journal.push(hk);
            }
        }
    }

    /// Record `key -> lv` in the innermost frame, journaled when inside a
    /// conditional branch so the value does not escape it.
    fn frame_put(&mut self, key: VnKey, lv: &LV) {
        let in_branch = self.in_branch();
        if let Some(frame) = self.rule.scope_frames.last_mut() {
            let prev = frame.map.insert(key, lv.clone());
            if in_branch {
                frame.journal.push((key, prev));
            }
        }
    }

    /// A whole-body lowering (`lower`, over [`Self::lower_wholesale`] and
    /// friends) under its own value-numbering frame: a subtree the body
    /// repeats — the same interned node — is lowered once, the way a box's
    /// numbering shares it ([`Self::lower_expr`]). Every operator node is a
    /// pure function of the solve state, so the shared slot holds the value
    /// a recomputation would; a value defined inside a branch stays inside
    /// it (the frame's journal).
    fn lower_wholesale_rule<T>(
        &mut self,
        lower: impl FnOnce(&mut Self) -> LResult<T>,
    ) -> LResult<T> {
        self.rule.scope_frames.push(ScopeFrame {
            wholesale: true,
            ..ScopeFrame::default()
        });
        let out = lower(self);
        self.rule.scope_frames.pop();
        out
    }

    /// An inline array `const` read whole, materialized once per frame (and
    /// once per box through the hoist): its value does not depend on where
    /// it is read, so a hit in any open frame serves.
    fn const_literal_array(
        &mut self,
        lit: &Arc<ExpressionNode>,
        a: &ndarray::ArrayD<f64>,
        bx: Option<&LBox>,
    ) -> LResult<LV> {
        let key = VnKey::ConstLit(Arc::as_ptr(lit) as usize);
        if let Some(lv) = self
            .rule
            .scope_frames
            .iter()
            .rev()
            .find_map(|f| f.map.get(&key).cloned())
        {
            self.vn_scope_hits += 1;
            return Ok(lv);
        }
        if let Some(bx) = bx
            && let Some(lv) = self.hoist.get(&(BoxKey::of(bx), key)).cloned()
        {
            self.vn_hoist_hits += 1;
            return Ok(lv);
        }
        let lv = self.emit_const_array(a)?;
        match bx {
            Some(bx) if !self.rule.scope_frames.last().is_some_and(|f| f.wholesale) => {
                self.vn_put(key, &lv, bx)
            }
            _ => self.frame_put(key, &lv),
        }
        Ok(lv)
    }

    // -- conditional branches -------------------------------------------------

    fn push_branch(&mut self) -> usize {
        self.rule.branch_bufs.push(Vec::new());
        self.rule.branch_secs.push(Cadence::Const);
        self.rule
            .scope_frames
            .last()
            .map(|f| f.journal.len())
            .unwrap_or(0)
    }

    /// Close the innermost branch: roll back VN insertions made inside it and
    /// return its instruction buffer.
    fn pop_branch(&mut self, journal_mark: usize) -> (Vec<Tagged>, Cadence) {
        let buf = self.rule.branch_bufs.pop().expect("branch buffer open");
        let sec = self.rule.branch_secs.pop().expect("branch section open");
        let depth = self.rule.branch_bufs.len();
        if let Some(frame) = self.rule.scope_frames.last_mut() {
            frame.subs.retain(|(_, d), _| *d <= depth);
            while frame.journal.len() > journal_mark {
                let (key, prev) = frame.journal.pop().expect("journal entry");
                match prev {
                    Some(v) => {
                        frame.map.insert(key, v);
                    }
                    None => {
                        frame.map.remove(&key);
                    }
                }
            }
        }
        (buf, sec)
    }

    // -- fail-closed faults -------------------------------------------------
    //
    // The per-cell oracle has no error channel: a fault (an out-of-range read
    // of a const array with no boundary policy, a subscript on a 0-D
    // parameter) latches a message, the read yields `NaN`, and the caller
    // drains the FIRST latched message. The tape reproduces both halves: the
    // `NaN` in ordinary instructions at the faulting positions, and one
    // `Instr::Fault` per rule carrying the message of the rule's first fault
    // in the oracle's order (see [`FaultKey`]).

    /// The [`FaultKey`] entries of `cell` of `bx`: the cell's absolute
    /// coordinates in visiting order, then the bound contraction tuple. A box
    /// with no symbols is evaluated once, not per cell, and adds nothing.
    fn fault_cell_key(bx: &LBox, cell: &[i64]) -> FaultKey {
        let mut key = FaultKey::new();
        if !bx.syms.is_empty() {
            for k in 0..bx.shape.len() {
                let a = bx.visit_axis(k);
                key.push(bx.lo[a] + cell[a]);
            }
        }
        key.extend(bx.cvals.iter().copied());
        key
    }

    /// Record a fault the oracle latches at `cell` (0-based) of `bx` — or,
    /// with `None`, at the point of a single evaluation — keeping the rule's
    /// first. `cell` is the first cell in the oracle's visiting order at
    /// which the read faults; `what` says at which cells it faults and with
    /// what message (`None`: at every cell, with `msg`).
    ///
    /// A fault that may not fire (in a branch, or a lazily evaluated
    /// position) is dropped when an earlier certain fault makes it
    /// unobservable, and otherwise becomes a candidate of the rule's
    /// [`Instr::FaultScan`]: the run decides whether the oracle reaches a
    /// faulting cell, from the conditions on the way to it ([`FaultTrack::reach`]).
    fn note_fault(
        &mut self,
        at: Option<(&LBox, &[i64])>,
        msg: String,
        what: Option<FaultWhat>,
    ) -> LResult<()> {
        if self.rule.sweep.is_some() {
            // The order of a build-time fault is placed by the box it sits in;
            // inside a recurrence body the cells come from the sweep instead,
            // which that ordering does not model.
            let head: String = msg.chars().take_while(|c| *c != ':').collect();
            bail_tape!("fault: `{head}` inside a recurrence body");
        }
        self.fault.notes += 1;
        let mut key = self.fault.prefix.clone();
        if let Some((bx, cell)) = at {
            key.extend(Self::fault_cell_key(bx, cell));
        }
        key.push(self.fault.seq);
        self.fault.seq += 1;
        let preceded = self.fault.first.as_ref().is_some_and(|(k, _)| *k < key);
        if self.in_branch() || self.fault.lazy_depth > 0 {
            self.fault.lazy_notes += 1;
            if preceded {
                return Ok(());
            }
            let Some(cand) = self.lazy_fault_cand(at.map(|(b, _)| b), &key, msg.clone(), what)
            else {
                let head: String = msg.chars().take_while(|c| *c != ':').collect();
                bail_tape!(
                    "fault: `{head}` where the oracle evaluates only some cells (a conditional \
                     branch or a filtered term), behind a condition the run-time fault scan \
                     cannot read at the faulting cells"
                );
            };
            self.fault.lazy.push((key, cand));
            return Ok(());
        }
        if !preceded {
            self.fault.first = Some((key, msg));
        }
        Ok(())
    }

    /// The [`FaultScan`](Instr::FaultScan) candidate for a fault at a lazily
    /// evaluated position over `bx` (`None`: a single evaluation) whose first
    /// possible key is `key`: `None` when some lazily evaluated position on
    /// the way to it has no condition in [`FaultTrack::reach`] (a tuple-list
    /// body), or a condition over a box other than the read's own, which
    /// the scan cannot read cell by cell.
    fn lazy_fault_cand(
        &mut self,
        bx: Option<&LBox>,
        key: &FaultKey,
        msg: String,
        what: Option<FaultWhat>,
    ) -> Option<FaultCand> {
        if bx.is_some_and(|b| b.tuple != 0)
            || self.fault.reach.len()
                != self.fault.lazy_depth as usize + self.rule.branch_bufs.len()
        {
            return None;
        }
        let mut path = Vec::with_capacity(self.fault.reach.len());
        for (lv, want) in &self.fault.reach {
            let array = match self.lv_box(lv) {
                None => false,
                Some((s, o)) => {
                    let b = bx.filter(|b| !b.syms.is_empty())?;
                    if !matches!(lv, LV::Arr(_)) || s != b.shape || o != b.lo {
                        return None;
                    }
                    true
                }
            };
            path.push(PathCond {
                op: self.op_of(lv),
                want: *want,
                array,
            });
        }
        let what = match what {
            Some(w) => w,
            None => {
                let m = tape_index(self.tables.faults.len(), "faults").ok()?;
                self.tables.faults.push(msg);
                // `fault_order` stays parallel to `faults`: a later
                // `Instr::Fault` reads both at its own index.
                self.tables.fault_order.push((self.cur_rule, key.clone()));
                FaultWhat::Every(m)
            }
        };
        let cells = bx.is_some_and(|b| !b.syms.is_empty());
        let (shape, lo, visit, cvals) = match bx {
            Some(b) => (
                if cells { b.shape.clone() } else { DimU::new() },
                if cells { b.lo.clone() } else { DimI::new() },
                if cells {
                    (0..b.shape.len()).map(|k| b.visit_axis(k) as u8).collect()
                } else {
                    SmallVec::new()
                },
                b.cvals.clone(),
            ),
            None => (DimU::new(), DimI::new(), SmallVec::new(), SmallVec::new()),
        };
        Some(FaultCand {
            prefix: self.fault.prefix.iter().copied().collect(),
            cells,
            shape,
            lo,
            visit,
            cvals,
            seq: *key
                .last()
                .expect("a fault key ends with its sequence number"),
            path,
            what,
        })
    }

    /// Lower `f` at a lazily evaluated position the oracle reaches where
    /// `cond` is nonzero (`want`) or zero (`!want`).
    fn reached_where<T>(
        &mut self,
        cond: &LV,
        want: bool,
        f: impl FnOnce(&mut Self) -> LResult<T>,
    ) -> LResult<T> {
        self.fault.reach.push((cond.clone(), want));
        let r = f(self);
        self.fault.reach.pop();
        r
    }

    /// Enter a box the oracle evaluates whole at each cell of `parent` (a
    /// nested aggregate; with `None`, an aggregate on the wholesale path):
    /// its faults sort at the parent's first cell, in expression order.
    /// Returns the prefix [`Self::leave_fault_level`] restores.
    fn enter_fault_level(&mut self, parent: Option<&LBox>) -> FaultKey {
        let saved = self.fault.prefix.clone();
        if let Some(p) = parent {
            let first: SmallVec<[i64; 4]> = SmallVec::from_elem(0, p.shape.len());
            let k = Self::fault_cell_key(p, &first);
            self.fault.prefix.extend(k);
        }
        self.fault.prefix.push(self.fault.seq);
        self.fault.seq += 1;
        saved
    }

    fn leave_fault_level(&mut self, saved: FaultKey) {
        self.fault.prefix = saved;
    }

    // -- expression lowering ---------------------------------------------------

    fn lower_expr(&mut self, e: &Expr, bx: &LBox) -> LResult<LV> {
        match e {
            // Literals round on ingress, exactly as the oracle's `eval` arm
            // does (`crate::precision`) — a tape literal and an interpreted
            // literal must be the same number under Float32.
            Expr::Number(n) => Ok(LV::Lit(crate::precision::round(*n))),
            Expr::Integer(n) => Ok(LV::Lit(crate::precision::round(*n as f64))),
            Expr::Variable(name) => self.resolve_var(name, bx),
            Expr::Operator(node) => {
                let key = VnKey::Node(Arc::as_ptr(node) as usize);
                if let Some(hit) = self.vn_get(key, bx) {
                    return Ok(hit);
                }
                if let Some(lv) = self.lower_on_sub_box(node, bx)? {
                    self.vn_put(key, &lv, bx);
                    return Ok(lv);
                }
                let lazy_notes = self.fault.lazy_notes;
                let lv = self.lower_op(node, bx)?;
                if self.fault.lazy_notes == lazy_notes {
                    self.vn_put(key, &lv, bx);
                }
                Ok(lv)
            }
        }
    }

    /// Resolve a variable over the box, in this order: `t`, bound
    /// contraction index, output box symbol (ramp), state, observed, param,
    /// bail (forcing / unknown loop bind).
    fn resolve_var(&mut self, name: &str, bx: &LBox) -> LResult<LV> {
        if name == "t" {
            return Ok(LV::Time);
        }
        if let Some(v) = bx.cbind(name) {
            return Ok(LV::Lit(v as f64));
        }
        if bx.tuple != 0 {
            if let Some(col) = self.tuple_column(bx.tuple, name)? {
                return Ok(col);
            }
            // Anything else a tuple-list body reads is one value for every
            // tuple; a whole array there is not an element of the list.
            let plain = LBox::new(&[], DimI::new(), DimU::new());
            let v = self.resolve_var(name, &plain)?;
            if self.lv_box(&v).is_some() {
                bail_tape!("variable: whole array `{name}` read inside a tuple-list body");
            }
            return Ok(v);
        }
        if let Some(a) = bx.syms.iter().position(|s| s == name) {
            let key = VnKey::Ramp(a);
            if let Some(hit) = self.vn_get(key, bx) {
                return Ok(hit);
            }
            let sec = self.placement(Cadence::Const);
            let out = self.new_slot(&bx.shape, &bx.lo, false, sec);
            self.emit(
                Instr::Ramp {
                    axis: a as u8,
                    lo: bx.lo[a],
                    out,
                },
                sec,
            );
            let lv = LV::Arr(out);
            self.vn_put(key, &lv, bx);
            return Ok(lv);
        }
        // A recurrence frame symbol is a loop bind of the cell being
        // evaluated, read from the coordinate slot the sweep writes.
        if let Some(sw) = &self.rule.sweep {
            if let Some((_, slot)) = sw.binds.iter().find(|(n, _)| n == name) {
                return Ok(LV::Scalar(*slot));
            }
            if name == sw.var {
                bail_tape!(
                    "variable: `{name}` read bare inside its own recurrence definition \
                     (esm-spec §4.3.1.1)"
                );
            }
        }
        if let Some(&ix) = self.state_ix.get(name) {
            return Ok(LV::State(tape_index(ix, "state variables")?));
        }
        if let Some(ov) = self.obs_defined.get(name).cloned() {
            return match ov {
                ObsVal::Taped(lv) => Ok(lv),
                ObsVal::Declined => {
                    bail_tape!("variable: observed `{name}` is produced by a declined rule")
                }
            };
        }
        if let Some(&i) = self.param_ix.get(name) {
            return Ok(LV::Param(tape_index(i, "parameters")?));
        }
        if let Some(lv) = self.forcing_read(name)? {
            return Ok(lv);
        }
        bail_tape!("variable: unresolved symbol (forcing/loop-bind?): {name}")
    }

    /// Lower an operator node, dispatching on its [`VecOp`] ([`vec_op_code`]).
    fn lower_op(&mut self, node: &Arc<ExpressionNode>, bx: &LBox) -> LResult<LV> {
        self.lower_op_code(vec_op_code(&node.op), node, bx)
    }

    /// [`Self::lower_op`] with the operator already resolved to a [`VecOp`], so
    /// the `Broadcast` arm can re-enter with the code of its `fn` against the
    /// SAME node, as the oracle's `eval_op_named` does.
    fn lower_op_code(&mut self, code: VecOp, node: &Arc<ExpressionNode>, bx: &LBox) -> LResult<LV> {
        match code {
            // The precision-boundary marker (`crate::precision_infer`): the
            // operand is lowered under the precision it names
            // ([`Self::marker_operand`]), and every instruction emitted there
            // records that precision for its kernels to run at. Reachable only
            // in a document that declares a per-variable `element_type`.
            VecOp::Precision => {
                let (arg, _precision) = self.marker_operand(node)?;
                self.lower_expr(arg, bx)
            }
            VecOp::Arith(code) => {
                let Some((first, rest)) = node.args.split_first() else {
                    bail_tape!("op: `{}` with no arguments", node.op);
                };
                if code == BinCode::Sub && rest.is_empty() {
                    let v = self.lower_expr(first, bx)?;
                    return self.emit_neg(v);
                }
                let mut acc = self.lower_expr(first, bx)?;
                for a in rest {
                    let v = self.lower_expr(a, bx)?;
                    acc = self.emit_bin(code, acc, v)?;
                }
                Ok(acc)
            }
            VecOp::Neg => {
                let Some(first) = node.args.first() else {
                    bail_tape!("op: `neg` with no arguments");
                };
                let v = self.lower_expr(first, bx)?;
                self.emit_neg(v)
            }
            VecOp::Index => self.lower_index(node, bx),
            VecOp::Aggregate => self.lower_nested_aggregate(node, bx),
            VecOp::Makearray => self.lower_makearray(node, bx),
            VecOp::Const => match eval_const(node) {
                Value::Scalar(s) => Ok(LV::Lit(s)),
                Value::Array(_) => bail_tape!("op: array-valued `const`"),
            },
            VecOp::BoolLit(b) => Ok(LV::Lit(if b { 1.0 } else { 0.0 })),
            VecOp::Cmp(code) => {
                if node.args.len() != 2 {
                    bail_tape!(
                        "op: comparison `{}` with arity {}",
                        node.op,
                        node.args.len()
                    );
                }
                let a = self.lower_expr(&node.args[0], bx)?;
                let b = self.lower_expr(&node.args[1], bx)?;
                self.emit_bin(code, a, b)
            }
            VecOp::Ifelse => self.lower_ifelse(node, bx),
            VecOp::Unary(code) => {
                if node.args.len() != 1 {
                    bail_tape!("op: unary `{}` with arity {}", node.op, node.args.len());
                }
                let v = self.lower_expr(&node.args[0], bx)?;
                Ok(self.emit_un(code, v))
            }
            // esm-spec §4.3.4: apply the scalar operator named in `fn`
            // element-wise. Lower it as the bare `{"op": fn, "args": args}` node
            // would be lowered, so the tape computes what the oracle evaluates
            // — a one-operand `broadcast` applies its unary `fn`.
            VecOp::Broadcast => {
                let Some(fn_name) = node.broadcast_fn.as_deref() else {
                    bail_tape!("op: `broadcast` with no `fn`");
                };
                if !crate::op_registry::is_scalar_operator(fn_name) {
                    bail_tape!("op: broadcast fn `{fn_name}` is not a scalar operator");
                }
                self.lower_op_code(vec_op_code(fn_name), node, bx)
            }
            VecOp::Unsupported => {
                bail_tape!("op: unsupported operator `{}`/{}", node.op, node.args.len())
            }
        }
    }

    /// An elementwise binary op: fold literals with the SAME kernel table,
    /// require array operands to share one box, broadcast scalars.
    fn emit_bin(&mut self, code: BinCode, a: LV, b: LV) -> LResult<LV> {
        if let (LV::Lit(x), LV::Lit(y)) = (&a, &b) {
            return Ok(LV::Lit(binary_kernel_of(code)(*x, *y)));
        }
        let ba = self.lv_box(&a);
        let bb = self.lv_box(&b);
        let (shape, origin, scalar) = match (&ba, &bb) {
            (None, None) => (DimU::new(), DimI::new(), true),
            (Some((s, o)), None) | (None, Some((s, o))) => (s.clone(), o.clone(), false),
            (Some((sa, oa)), Some((sb, ob))) => {
                if sa != sb || oa != ob {
                    bail_tape!(
                        "combine: array operand boxes differ ({sa:?}@{oa:?} vs {sb:?}@{ob:?})"
                    );
                }
                (sa.clone(), oa.clone(), false)
            }
        };
        let want = self.lv_cadence(&a).max(self.lv_cadence(&b));
        let sec = self.placement(want);
        let out = self.new_slot(&shape, &origin, scalar, sec);
        let instr = Instr::Bin {
            op: code,
            a: self.op_of(&a),
            b: self.op_of(&b),
            out,
        };
        self.emit(instr, sec);
        Ok(if scalar {
            LV::Scalar(out)
        } else {
            LV::Arr(out)
        })
    }

    fn emit_un(&mut self, code: UnCode, a: LV) -> LV {
        if let LV::Lit(x) = &a {
            return LV::Lit(unary_kernel_of(code)(*x));
        }
        let (shape, origin, scalar) = match self.lv_box(&a) {
            None => (DimU::new(), DimI::new(), true),
            Some((s, o)) => (s, o, false),
        };
        let sec = self.placement(self.lv_cadence(&a));
        let out = self.new_slot(&shape, &origin, scalar, sec);
        let instr = Instr::Un {
            op: code,
            a: self.op_of(&a),
            out,
        };
        self.emit(instr, sec);
        if scalar {
            LV::Scalar(out)
        } else {
            LV::Arr(out)
        }
    }

    fn emit_neg(&mut self, a: LV) -> LResult<LV> {
        if let LV::Lit(x) = &a {
            return Ok(LV::Lit(-x));
        }
        let (shape, origin, scalar) = match self.lv_box(&a) {
            None => (DimU::new(), DimI::new(), true),
            Some((s, o)) => (s, o, false),
        };
        let sec = self.placement(self.lv_cadence(&a));
        let out = self.new_slot(&shape, &origin, scalar, sec);
        let instr = Instr::Neg {
            a: self.op_of(&a),
            out,
        };
        self.emit(instr, sec);
        Ok(if scalar {
            LV::Scalar(out)
        } else {
            LV::Arr(out)
        })
    }

    /// A zero-filled array over `box` (the ghost-only gather results).
    fn emit_zero_array(&mut self, shape: &[usize], origin: &[i64]) -> LV {
        let sec = self.placement(Cadence::Const);
        let out = self.new_slot(shape, origin, false, sec);
        self.emit(
            Instr::Fill {
                v: Operand::Lit(0.0),
                out,
            },
            sec,
        );
        LV::Arr(out)
    }

    /// Materialize an inline array literal as a CONST-section slot
    /// ([`Instr::ConstArray`]): one instruction and one slab store per solve,
    /// whatever the literal's size. The box is the literal's own shape at the
    /// all-1s origin — the convention under which a wholesale-evaluated array
    /// is read (`lookup_variable` serves stored arrays origin-blind).
    fn emit_const_array(&mut self, a: &ndarray::ArrayD<f64>) -> LResult<LV> {
        let shape: DimU = a.shape().iter().copied().collect();
        if shape.is_empty() {
            // `eval_const` never produces one (a rank-0 literal arrives as
            // `Value::Scalar`), and a 0-d array slot would need scalar, not
            // array, operand semantics.
            bail_tape!("wholesale: rank-0 array-valued `const`");
        }
        if shape.contains(&0) {
            bail_tape!("wholesale: empty array-valued `const`");
        }
        // `iter()` is the LOGICAL row-major walk, which is the slab layout.
        let values: Vec<f64> = a.iter().copied().collect();
        let origin = DimI::from_elem(1, shape.len());
        let out = self.emit_const_data(&shape, &origin, Arc::new(values), false)?;
        Ok(LV::Arr(out))
    }

    /// A CONST slot over `shape` at `origin` holding `values` (row-major):
    /// one [`Instr::ConstArray`], the one way a payload the build holds
    /// becomes a slot. `hoist` defines it ahead of any open conditional
    /// branch, for a slot every later read shares.
    ///
    /// Under [`Self::defer_consts`] no instruction is emitted here: the slot
    /// is [`Known::Deferred`], and `finish_standalone` emits its
    /// `ConstArray` only if an instruction reads it.
    fn emit_const_data(
        &mut self,
        shape: &[usize],
        origin: &[i64],
        values: Arc<Vec<f64>>,
        hoist: bool,
    ) -> LResult<SlotId> {
        debug_assert_eq!(shape.iter().product::<usize>(), values.len());
        // A payload read inside a conditional branch is the same on every
        // call and cannot fault: it is materialized once, in the CONST
        // section, instead of on each call that takes the branch.
        let direct = self.in_branch() && self.rule.sweep.is_none() && !self.defer_consts;
        let sec = if direct {
            Cadence::Const
        } else {
            self.placement(Cadence::Const)
        };
        let out = self.new_slot(shape, origin, false, sec);
        if self.defer_consts {
            let k = Known::Deferred {
                vals: values,
                rule: self.cur_rule,
                prec: crate::precision::active(),
            };
            self.known.insert(out, k);
            return Ok(out);
        }
        let data = tape_index(self.tables.const_data.len(), "array constants")?;
        self.tables.const_data.push(ConstArrayData {
            shape: shape.iter().copied().collect(),
            values,
        });
        let instr = Instr::ConstArray { data, out };
        if direct {
            self.track_known(&instr);
            self.track_range(&instr);
            self.push_stream(instr, crate::precision::active(), Cadence::Const);
        } else if hoist {
            let branches = std::mem::take(&mut self.rule.branch_bufs);
            self.emit(instr, sec);
            self.rule.branch_bufs = branches;
        } else {
            self.emit(instr, sec);
        }
        Ok(out)
    }

    /// Fill an array slot over `box` with a scalar LV (`Fill` broadcast).
    fn emit_fill(&mut self, v: &LV, shape: &[usize], origin: &[i64], cad_floor: Cadence) -> LV {
        let want = self.lv_cadence(v).max(cad_floor);
        let sec = self.placement(want);
        let out = self.new_slot(shape, origin, false, sec);
        self.emit(
            Instr::Fill {
                v: self.op_of(v),
                out,
            },
            sec,
        );
        LV::Arr(out)
    }

    // -- ifelse ---------------------------------------------------------------

    /// The operand of a precision-boundary marker (`crate::precision_infer`)
    /// and the precision it names, which the operand is lowered under: every
    /// instruction it emits is tagged with that precision and runs at it.
    fn marker_operand<'n>(
        &self,
        node: &'n Arc<ExpressionNode>,
    ) -> LResult<(&'n Expr, Option<crate::precision::PrecisionGuard>)> {
        let [arg] = &node.args[..] else {
            bail_tape!("op: `{}` with arity {}", node.op, node.args.len());
        };
        Ok((
            arg,
            crate::precision_infer::marker_precision(node).map(crate::precision::enter),
        ))
    }

    fn lower_ifelse(&mut self, node: &Arc<ExpressionNode>, bx: &LBox) -> LResult<LV> {
        if node.args.len() != 3 {
            bail_tape!("op: `ifelse` with arity {}", node.args.len());
        }
        let cond = self.lower_expr(&node.args[0], bx)?;
        // Compile-time-known scalar condition: lower ONLY the taken branch —
        // exactly what the oracle evaluates (the untaken branch is never
        // visited, so an unsupported construct there must not bail the rule).
        if let LV::Lit(c) = &cond {
            let c = *c;
            return if c != 0.0 {
                self.lower_expr(&node.args[1], bx)
            } else {
                self.lower_expr(&node.args[2], bx)
            };
        }
        match self.lv_box(&cond) {
            // Runtime SCALAR condition: short-circuit via JmpIfZero — the
            // untaken branch's instructions are never executed.
            None => self.lower_branchy_ifelse(cond, &node.args[1], &node.args[2], true, |s, e| {
                s.lower_expr(e, bx)
            }),
            // ARRAY condition: evaluate BOTH branches and select elementwise
            // ([`Instr::Select`]). The oracle, walking the box cell by cell, takes
            // one arm per cell, so each arm is a lazily evaluated position.
            Some(_) => {
                let lazy = !bx.syms.is_empty();
                let arm = |s: &mut Self, e: &Expr, want: bool| {
                    if lazy {
                        s.fault.lazy_depth += 1;
                        let v = s.reached_where(&cond, want, |s| s.lower_expr(e, bx));
                        s.fault.lazy_depth -= 1;
                        v
                    } else {
                        s.lower_expr(e, bx)
                    }
                };
                let a = arm(self, &node.args[1], true)?;
                let b = arm(self, &node.args[2], false)?;
                self.emit_select(cond, a, b)
            }
        }
    }

    /// Give the lowered value `v` of the subscript `e` the bounds its
    /// structure proves over `bx` ([`int_range`]) when its instructions did
    /// not: a loop symbol's own slot carries none, and an `ifelse` arm's
    /// bounds hold only under its condition, so the cyclic successor
    /// `ifelse(k < n, k + 1, 1)` and the clamp `min(k + 1, n)` are known to
    /// stay inside `[1, n]` and a gather at them cannot fault.
    fn note_int_range(&mut self, v: &LV, e: &Expr, bx: &LBox) {
        if let LV::Arr(s) | LV::Scalar(s) = v
            && !self.ranges.contains_key(s)
            && let Some(r) = int_range(e, bx, &[])
        {
            self.ranges.insert(*s, r);
        }
    }

    /// An elementwise select: `cond`'s box is the output box; `a`/`b` are
    /// scalars (broadcast) or arrays over the same box. A scalar `cond` is the
    /// filter-gate shape (whole-term keep/replace — elementwise identical).
    fn emit_select(&mut self, cond: LV, a: LV, b: LV) -> LResult<LV> {
        let cb = self.lv_box(&cond);
        let (shape, origin, scalar) = match &cb {
            Some((s, o)) => (s.clone(), o.clone(), false),
            None => {
                // Scalar condition gate (§5.3 runtime filter): output box is
                // the term's own box (or scalar if both are).
                let ab = self.lv_box(&a);
                let bb = self.lv_box(&b);
                match (&ab, &bb) {
                    (None, None) => (DimU::new(), DimI::new(), true),
                    (Some((s, o)), None) | (None, Some((s, o))) => (s.clone(), o.clone(), false),
                    (Some((sa, oa)), Some((sb, ob))) => {
                        if sa != sb || oa != ob {
                            bail_tape!("select: branch boxes differ");
                        }
                        (sa.clone(), oa.clone(), false)
                    }
                }
            }
        };
        if cb.is_some() {
            let box_ok = |v: Option<(DimU, DimI)>| match v {
                None => true,
                Some((s, o)) => s == shape && o == origin,
            };
            if !box_ok(self.lv_box(&a)) || !box_ok(self.lv_box(&b)) {
                bail_tape!("select: operand box does not match the condition box");
            }
        }
        let want = self
            .lv_cadence(&cond)
            .max(self.lv_cadence(&a))
            .max(self.lv_cadence(&b));
        let sec = self.placement(want);
        let out = self.new_slot(&shape, &origin, scalar, sec);
        let instr = Instr::Select {
            cond: self.op_of(&cond),
            a: self.op_of(&a),
            b: self.op_of(&b),
            out,
        };
        self.emit(instr, sec);
        Ok(if scalar {
            LV::Scalar(out)
        } else {
            LV::Arr(out)
        })
    }

    /// A `faq` term under an optional §5.3 `filter`, over one box: the
    /// filter first, then the body, which the oracle evaluates only where
    /// the filter keeps the cell or tuple (a lazily evaluated position); an
    /// excluded term reads `excluded`. `None` when the filter is the literal
    /// false — no term is kept and the body is never evaluated.
    fn lower_filtered(
        &mut self,
        body: &Expr,
        filter: Option<&Expr>,
        bx: &LBox,
        excluded: LV,
    ) -> LResult<Option<LV>> {
        let keep = match filter {
            None => return self.lower_expr(body, bx).map(Some),
            Some(f) => self.lower_expr(f, bx)?,
        };
        match keep {
            LV::Lit(0.0) => Ok(None),
            LV::Lit(_) => self.lower_expr(body, bx).map(Some),
            keep => {
                self.fault.lazy_depth += 1;
                let term = self.reached_where(&keep, true, |s| s.lower_expr(body, bx));
                self.fault.lazy_depth -= 1;
                self.emit_select(keep, term?, excluded).map(Some)
            }
        }
    }

    // -- geometry -------------------------------------------------------------

    /// Whether a contracted dimension has one extent for every output cell: a
    /// static interval.
    fn dim_is_fixed(&self, d: &ContractDim) -> bool {
        matches!(d, ContractDim::Static(..))
    }

    /// The indexed-gather arm of [`Self::lower_index`]: source axis `data_d`
    /// is subscripted by a value (`u[nbr[i, k]]` on an unstructured mesh), so
    /// the read position is data, not a shift. One [`Instr::IndexGather`]
    /// over the box, whatever its size.
    ///
    /// The oracle's rule is `eval_index` → `index_into` with a state or
    /// observed base: the subscript is `round()`ed to an integer and a
    /// position outside the source reads the zero ghost. The other axes stay
    /// what the segment gather supports, in range for every cell (a shifted
    /// read that leaves the source, or a periodic wrap, is refused here rather
    /// than mixed with a data subscript). A const-array base never reaches
    /// here: its out-of-range rule is the factor's boundary policy, which
    /// needs the subscript values to decide.
    fn lower_index_gather(
        &mut self,
        node: &Arc<ExpressionNode>,
        bx: &LBox,
        base: &LV,
        read: &IndexRead,
    ) -> LResult<Option<LV>> {
        let data_d = read.data_axis.expect("a read with a computed subscript");
        let mapped = read.mapped;
        let (fixed, any_fixed_oob) = read.fixed_positions();
        let fixed = &fixed[..];
        let (src_shape, src_origin) = self.lv_box(base).expect("an array base");
        if src_origin.iter().any(|&o| o != 1) {
            bail_tape!("index: data subscript into a base that is not origin-1");
        }
        if any_fixed_oob {
            return Ok(None);
        }
        let mut axes: SmallVec<[GatherAxis; 4]> =
            SmallVec::from_elem(GatherAxis::Fixed(0), src_shape.len());
        axes[data_d] = GatherAxis::Data;
        for &(d, i0) in fixed {
            axes[d] = GatherAxis::Fixed(i0 as usize);
        }
        for (a, m) in mapped.iter().enumerate() {
            let Some((d, ax)) = m else { continue };
            let AxisIndex::Affine(k) = ax else {
                return Ok(None);
            };
            // 0-based source position `p + off` at output position p.
            let off = bx.lo[a] + k - src_origin[*d];
            let last = off + bx.shape[a] as i64 - 1;
            if off < 0 || last >= src_shape[*d] as i64 {
                return Ok(None);
            }
            axes[*d] = GatherAxis::Affine { axis: a as u8, off };
        }
        self.emit_index_gather(node, bx, base, data_d, axes, src_shape)
    }

    /// The [`Instr::IndexGather`] of `base` (of extents `src_shape`) with the
    /// per-axis plan `axes`, whose data axis `data_d` reads the subscript
    /// `node.args[1 + data_d]` lowered over `bx`. `None` when that subscript's
    /// box is not the output box.
    fn emit_index_gather(
        &mut self,
        node: &Arc<ExpressionNode>,
        bx: &LBox,
        base: &LV,
        data_d: usize,
        axes: SmallVec<[GatherAxis; 4]>,
        src_shape: DimU,
    ) -> LResult<Option<LV>> {
        let sub = self.lower_expr(&node.args[1 + data_d], bx)?;
        if let Some((s, o)) = self.lv_box(&sub)
            && (s != bx.shape || o != bx.lo)
        {
            return Ok(None);
        }
        let cad = self.lv_cadence(base).max(self.lv_cadence(&sub));
        let sec = self.placement(cad);
        let spec = self.tables.index_gathers.len() as u32;
        self.tables.index_gathers.push(IndexGatherSpec {
            axes,
            src_shape,
            shape: bx.shape.clone(),
        });
        let out = self.new_slot(&bx.shape, &bx.lo, false, sec);
        // A tile build reaches here only through `lower_tile_index_gather`,
        // which has classified every position of the read.
        let tile_ok = std::mem::replace(&mut self.tile_read_ok, self.tile.is_some());
        let src = self.src_of(base);
        self.tile_read_ok = tile_ok;
        let instr = Instr::IndexGather {
            src,
            idx: self.op_of(&sub),
            spec,
            out,
        };
        self.emit(instr, sec);
        Ok(Some(LV::Arr(out)))
    }

    /// The first cell (0-based, in `bx`) at which an out-of-range const gather
    /// faults in the oracle's visiting order, and the message it latches
    /// there: `index_into` checks the source dims in order and reports the
    /// first one out of range with no policy.
    fn const_oob_first(
        &self,
        bx: &LBox,
        name: &str,
        read: &IndexRead,
        fixed_oob: bool,
        runs: &[SmallVec<[(usize, usize, ConstRun); 3]>],
    ) -> (SmallVec<[i64; 4]>, String) {
        let IndexRead {
            src_shape,
            mapped,
            fixed_raw,
            ..
        } = *read;
        let nd = bx.shape.len();
        // Every out-of-range cell set is a union of axis-aligned slabs, so its
        // first cell in any visiting order is one slab's corner: the origin
        // (a fixed dim out of range), or the first position of an
        // out-of-range run along one axis with every other axis at 0.
        let mut candidates: Vec<SmallVec<[i64; 4]>> = Vec::new();
        let origin: SmallVec<[i64; 4]> = SmallVec::from_elem(0, nd);
        if fixed_oob {
            candidates.push(origin.clone());
        }
        for (a, rs) in runs.iter().enumerate() {
            if let Some((start, _, _)) = rs.iter().find(|(_, _, r)| matches!(r, ConstRun::Oob)) {
                let mut c = origin.clone();
                c[a] = *start as i64;
                candidates.push(c);
            }
        }
        let visit_key = |c: &SmallVec<[i64; 4]>| -> SmallVec<[i64; 4]> {
            (0..nd).map(|k| c[bx.visit_axis(k)]).collect()
        };
        let cell = candidates
            .into_iter()
            .min_by_key(|c| visit_key(c))
            .expect("an out-of-range gather has an out-of-range cell");
        // The subscript of every source dim at that cell, in dim order.
        let mut raw_at: SmallVec<[i64; 4]> = SmallVec::from_elem(0, src_shape.len());
        for &(d, raw) in fixed_raw {
            raw_at[d] = raw;
        }
        for (a, m) in mapped.iter().enumerate() {
            if let Some((d, ax)) = m {
                raw_at[*d] = match ax {
                    AxisIndex::Affine(k) => bx.lo[a] + cell[a] + k,
                    AxisIndex::Wrap { k, period, lo } => {
                        wrap_subscript(bx.lo[a], cell[a], (*k, *lo, *period))
                    }
                };
            }
        }
        for (d, &raw) in raw_at.iter().enumerate() {
            let n_d = src_shape[d] as i64;
            let policy = if n_d == 0 {
                BoundaryKind::Error
            } else {
                self.const_arrays.boundary(name, d)
            };
            if (raw < 1 || raw > n_d) && matches!(policy, BoundaryKind::Error) {
                return (cell, const_oob_message(name, raw, n_d, d));
            }
        }
        unreachable!("the first out-of-range cell has an out-of-range dim")
    }

    // -- makearray ------------------------------------------------------------

    /// `index(makearray(regions, values), s₁, …, sₙ)` in a box. The oracle
    /// evaluates the makearray afresh at every cell of the box, cells
    /// outermost in its visiting order: EVERY region's value, in region
    /// order, whether or not the subscripts reach the region, then the
    /// subscripted element of the array that assembles — 1-based over the
    /// bounding box (the zero ghost outside it), the value of the LAST region
    /// containing it (§4.3.2's overlap rule), else the zero fill. The
    /// makearray's own rank, not the box's, decides how it lowers:
    ///
    /// - region values that read none of the box's symbols make the same
    ///   array at every cell. It is built once, at its own rank, and the
    ///   general route gathers it at the subscripts: `None` is returned and
    ///   the general route lowers the base with
    ///   [`Self::lower_makearray_once`];
    /// - otherwise each cell reads one number of its own array, which is an
    ///   assembly over the box ([`Self::assemble_index_of_makearray`]), taken
    ///   when every subscript is a unit shift of a box axis or a constant
    ///   and every region value is one number per cell
    ///   ([`Self::cell_scalar`]).
    ///
    /// A per-cell makearray this cannot assemble bails rather than taking
    /// the general route, which lowers a makearray over the box positionally:
    /// it reads the box's symbols at the makearray's coordinates, not at the
    /// cell. The one exception is where the two coincide — the same rank,
    /// subscript `d` the box axis `d`, a bounding box starting at 1 — and a
    /// region value is a whole array, which only the positional route
    /// places.
    ///
    /// A makearray under elementwise operations goes through
    /// [`Self::lower_index_through_elementwise`].
    fn lower_index_of_makearray(
        &mut self,
        node: &Arc<ExpressionNode>,
        bx: &LBox,
    ) -> LResult<Option<LV>> {
        let Some(Expr::Operator(base)) = node.args.first() else {
            return Ok(None);
        };
        if !self.per_cell_makearray_box(bx) {
            return Ok(None);
        }
        if base.op != "makearray" {
            return self.lower_index_through_elementwise(node, bx);
        }
        let (Some(regions), Some(values)) = (base.regions.as_ref(), base.values.as_ref()) else {
            return Ok(None);
        };
        if values.len() != regions.len() || !makearray_reads_box(base, bx) {
            return Ok(None);
        }
        let bounds = match MakearrayBounds::of(regions) {
            Ok(b) => b,
            Err(why) => bail_tape!("makearray: {why}"),
        };
        let ndim = bounds.lo.len();
        let n = node.args.len() - 1;
        if n != ndim {
            bail_tape!("index: arg count != source rank ({n} args vs rank {ndim})");
        }
        let subs = self.makearray_subs(node, bx);
        let cell_scalar = values.iter().all(|v| self.cell_scalar(v, bx));
        match subs {
            Some(subs) if cell_scalar => {
                let txn = self.sub_txn();
                let guard = self.sub_box_guard();
                match self.assemble_index_of_makearray(&bounds, values, &subs, bx) {
                    Ok(v) => Ok(Some(v)),
                    Err(e) => {
                        self.sub_box_undo(txn, guard);
                        Err(e)
                    }
                }
            }
            Some(subs)
                if ndim == bx.shape.len()
                    && bounds.lo.iter().all(|&l| l == 1)
                    && subs
                        .iter()
                        .enumerate()
                        .all(|(d, s)| matches!(*s, MaSub::Axis(a, 0) if a == d)) =>
            {
                Ok(None)
            }
            Some(_) => bail_tape!(
                "index: a makearray read per cell whose region value is not one number per cell"
            ),
            None => bail_tape!(
                "index: a makearray read per cell at a subscript that is not a unit shift of a \
                 box axis or a constant"
            ),
        }
    }

    /// Whether [`Self::lower_index_of_makearray`] applies in `bx`: a box of
    /// cells, outside a tuple-list body and a recurrence sweep, in a
    /// whole-domain build. A tile build keeps the positional route: its
    /// rules were rewritten for it, with every makearray's regions clipped
    /// to what the tile reads in the makearray's own coordinates.
    fn per_cell_makearray_box(&self, bx: &LBox) -> bool {
        bx.tuple == 0 && !bx.shape.is_empty() && self.rule.sweep.is_none() && self.tile.is_none()
    }

    /// How each subscript of `index(base, s…)` reads the box: a unit shift
    /// of a box axis, or a constant. `None` when one is neither.
    fn makearray_subs(&self, node: &ExpressionNode, bx: &LBox) -> Option<SmallVec<[MaSub; 4]>> {
        let vb = bx.as_vecbox();
        node.args[1..]
            .iter()
            .map(|e| match classify_axis_role(e, &vb)? {
                AxisRole::Map {
                    out_axis,
                    ax: AxisIndex::Affine(k),
                } => Some(MaSub::Axis(out_axis, k)),
                AxisRole::Const(c) => Some(MaSub::Const(c)),
                _ => None,
            })
            .collect()
    }

    /// The per-cell assembly of [`Self::lower_index_of_makearray`]. Each
    /// region, pulled back through the subscripts, is a sub-box of `bx`: the
    /// cells that read it. Its value is lowered over the WHOLE box, where the
    /// oracle evaluates it, so every fault it raises keeps its cell and its
    /// place among the other regions' at that cell; only a value that reads
    /// no const array, and notes no fault over the sub-box, is lowered over
    /// the sub-box alone. A region no cell reads is
    /// still lowered for its faults, and dropped when it has none. Later
    /// regions overwrite earlier ones; cells no region covers keep the zero
    /// fill.
    fn assemble_index_of_makearray(
        &mut self,
        bounds: &MakearrayBounds,
        values: &[Expr],
        subs: &[MaSub],
        bx: &LBox,
    ) -> LResult<LV> {
        let n = bx.shape.len();
        let mut parts: Vec<(LV, u32)> = Vec::with_capacity(values.len());
        for (region, value) in bounds.regions.iter().zip(values.iter()) {
            let mut s_lo = bx.lo.clone();
            let mut s_hi: DimI = (0..n).map(|a| bx.lo[a] + bx.shape[a] as i64 - 1).collect();
            let mut empty = false;
            for (d, &[r_lo, r_hi]) in region.iter().enumerate() {
                // The region's 1-based positions in the bounding box.
                let (p_lo, p_hi) = (r_lo - bounds.lo[d] + 1, r_hi - bounds.lo[d] + 1);
                match subs[d] {
                    MaSub::Const(c) => empty |= c < p_lo || c > p_hi,
                    MaSub::Axis(a, k) => {
                        s_lo[a] = s_lo[a].max(p_lo - k);
                        s_hi[a] = s_hi[a].min(p_hi - k);
                    }
                }
            }
            if empty || (0..n).any(|a| s_hi[a] < s_lo[a]) {
                let txn = self.sub_txn();
                let guard = self.sub_box_guard();
                self.lower_expr(value, bx)?;
                if self.sub_box_clean(guard) {
                    self.sub_box_undo(txn, guard);
                }
                continue;
            }
            let s_shape: DimU = (0..n).map(|a| (s_hi[a] - s_lo[a] + 1) as usize).collect();
            let v = self.lower_region_value_on(value, bx, &s_lo, &s_shape)?;
            let region_ix = tape_index(self.tables.regions.len(), "makearray regions")?;
            self.tables.regions.push(RegionSpec {
                dest_lo: (0..n).map(|a| (s_lo[a] - bx.lo[a]) as usize).collect(),
                shape: s_shape,
            });
            parts.push((v, region_ix));
        }
        if parts.is_empty() {
            return Ok(self.emit_zero_array(&bx.shape, &bx.lo));
        }
        let want = parts
            .iter()
            .map(|(v, _)| self.lv_cadence(v))
            .max()
            .unwrap_or(Cadence::Const);
        let sec = self.placement(want);
        let table = tape_index(self.tables.assemblies.len(), "makearray assemblies")?;
        self.tables.assemblies.push(AssembleSpec {
            parts: parts.iter().map(|(v, r)| (self.op_of(v), *r)).collect(),
        });
        let out = self.new_slot(&bx.shape, &bx.lo, false, sec);
        self.emit(Instr::Assemble { table, out }, sec);
        Ok(LV::Arr(out))
    }

    /// A region value of [`Self::assemble_index_of_makearray`] at the cells
    /// of the sub-box `s_lo`/`s_shape` of `bx`: a scalar, or an array over
    /// the sub-box.
    fn lower_region_value_on(
        &mut self,
        value: &Expr,
        bx: &LBox,
        s_lo: &DimI,
        s_shape: &DimU,
    ) -> LResult<LV> {
        let full = *s_lo == bx.lo && *s_shape == bx.shape;
        // Without a const-array read nothing in it faults at one cell and
        // not at another, so a sub-box lowering that notes no fault stands
        // for every cell.
        if !full && self.const_free(value) {
            let sbx = LBox {
                syms: bx.syms,
                lo: s_lo.clone(),
                shape: s_shape.clone(),
                cnames: bx.cnames,
                cvals: bx.cvals.clone(),
                tuple: 0,
                visit: bx.visit.clone(),
            };
            // Its own value-numbering scope, as in `lower_index_on_sub_box`.
            let txn = self.sub_txn();
            let guard = self.sub_box_guard();
            let fkey = self.enter_sub_frame(&sbx);
            let v = self.lower_expr(value, &sbx);
            self.leave_sub_frame(fkey);
            match v {
                Ok(v)
                    if self.sub_box_clean(guard)
                        && self
                            .lv_box(&v)
                            .is_none_or(|(s, o)| s == sbx.shape && o == sbx.lo) =>
                {
                    return Ok(v);
                }
                _ => self.sub_box_undo(txn, guard),
            }
        }
        let v = self.lower_expr(value, bx)?;
        match self.lv_box(&v) {
            None => Ok(v),
            Some((s, o)) if s == bx.shape && o == bx.lo => {
                if full {
                    return Ok(v);
                }
                let n = bx.shape.len();
                let segs = (0..n)
                    .map(|a| {
                        let mut one = SmallVec::new();
                        one.push((0usize, s_shape[a], (s_lo[a] - bx.lo[a]) as usize));
                        one
                    })
                    .collect();
                let mapped_src: SmallVec<[usize; 4]> = (0..n).collect();
                Ok(self.emit_gather(
                    &v,
                    SmallVec::new(),
                    &mapped_src,
                    SmallVec::from_elem(true, n),
                    segs,
                    s_shape,
                    s_lo,
                ))
            }
            Some(_) => {
                bail_tape!("index: a makearray region value read per cell is not over the box")
            }
        }
    }

    /// Whether nothing in `e`, at any depth, reads a const array: the one
    /// read whose fault depends on the cell (out of its range at some cells
    /// only).
    fn const_free(&self, e: &Expr) -> bool {
        match e {
            Expr::Number(_) | Expr::Integer(_) => true,
            Expr::Variable(v) => !self.const_arrays.is_const(v),
            Expr::Operator(n) => {
                if n.op == "const" && !n.value.as_ref().is_some_and(crate::ConstValue::is_number) {
                    return false;
                }
                if n.op == "index"
                    && n.args
                        .first()
                        .is_some_and(|b| self.const_arrays.is_const_base(b))
                {
                    return false;
                }
                n.args.iter().all(|a| self.const_free(a))
                    && [&n.expr, &n.filter, &n.lower, &n.upper]
                        .into_iter()
                        .all(|x| x.as_deref().is_none_or(|x| self.const_free(x)))
                    && n.values
                        .as_ref()
                        .is_none_or(|vs| vs.iter().all(|x| self.const_free(x)))
            }
        }
    }

    /// Whether `e` is one number at each cell of `bx` as the oracle
    /// evaluates it: a leaf that is a scalar there, a full-rank `index`
    /// read, a rank-0 `faq`, or an elementwise operation of those. A whole
    /// array (a bare shaped name, an array literal, a builder) is not, and
    /// neither is anything this does not look into.
    fn cell_scalar(&self, e: &Expr, bx: &LBox) -> bool {
        match e {
            Expr::Number(_) | Expr::Integer(_) => true,
            Expr::Variable(v) => bx.syms.iter().any(|s| s == v) || self.scalar_name(v, bx),
            Expr::Operator(n) => match vec_op_code(&n.op) {
                VecOp::Arith(_) | VecOp::Cmp(_) | VecOp::Unary(_) | VecOp::Neg | VecOp::Ifelse => {
                    n.args.iter().all(|a| self.cell_scalar(a, bx))
                }
                VecOp::Precision => n.args.first().is_some_and(|a| self.cell_scalar(a, bx)),
                VecOp::Const => matches!(eval_const(n), Value::Scalar(_)),
                VecOp::BoolLit(_) => true,
                // The oracle's gather is one element unless it has fewer
                // subscripts than its base has axes.
                VecOp::Index => {
                    let Some((base, subs)) = n.args.split_first() else {
                        return false;
                    };
                    subs.iter().all(|a| self.cell_scalar(a, bx))
                        && self.rank_of(base).is_some_and(|r| subs.len() >= r)
                }
                VecOp::Aggregate => faq_spec(n).is_some_and(|s| s.ranges.is_empty()),
                _ => false,
            },
        }
    }

    /// The rank of the array `e` names or spells, where that is known
    /// without lowering it.
    fn rank_of(&self, e: &Expr) -> Option<usize> {
        match e {
            Expr::Variable(v) => match self.obs_defined.get(v) {
                Some(ObsVal::Taped(lv)) => Some(self.lv_box(lv).map_or(0, |(s, _)| s.len())),
                Some(ObsVal::Declined) => None,
                None if self.param_ix.contains_key(v.as_str()) => Some(0),
                None => self.var_shapes.get(v).map(|s| s.shape.len()),
            },
            Expr::Operator(n) if n.op == "makearray" => n.regions.as_ref()?.first().map(Vec::len),
            Expr::Operator(n) if n.op == "const" => match eval_const(n) {
                Value::Scalar(_) => Some(0),
                Value::Array(a) => Some(a.ndim()),
            },
            _ => None,
        }
    }

    /// A name that reads as one number everywhere in `bx` (its own symbols
    /// aside): the time, a bound contraction index, a parameter, or a 0-D
    /// observed or state.
    fn scalar_name(&self, v: &str, bx: &LBox) -> bool {
        v == "t"
            || bx.cbind(v).is_some()
            || self.param_ix.contains_key(v)
            || match self.obs_defined.get(v) {
                Some(ObsVal::Taped(lv)) => self.lv_box(lv).is_none(),
                Some(ObsVal::Declined) => false,
                None => self.var_shapes.get(v).is_some_and(|s| s.shape.is_empty()),
            }
    }

    /// `index(w, s…)` where `w` combines one or more makearrays elementwise
    /// (`2 * makearray(…)`, an `ifelse` choosing between two): at each cell
    /// the oracle combines the per-cell arrays, then reads one element,
    /// which is the same combination of each array's element there —
    /// evaluated in the same order, the scalar operands once per cell, and
    /// under a scalar condition only the arm it takes. So the read is pushed
    /// through to each makearray ([`Self::push_index`]) and the rewritten
    /// expression lowered. The combined array is read 1-based over the
    /// makearrays' common bounding box, and outside it is the zero ghost, not
    /// the combination of the zero fills, so every subscript must stay
    /// inside it. `None` when the base is not such a combination.
    fn lower_index_through_elementwise(
        &mut self,
        node: &Arc<ExpressionNode>,
        bx: &LBox,
    ) -> LResult<Option<LV>> {
        let base = &node.args[0];
        if !reaches_makearray(base) {
            return Ok(None);
        }
        let Pushed::Array(rewritten, shape) = self.push_index(base, &node.args[1..], node, bx)
        else {
            return Ok(None);
        };
        let Some(subs) = self.makearray_subs(node, bx) else {
            return Ok(None);
        };
        let inside = subs.iter().enumerate().all(|(d, s)| {
            let n = shape[d] as i64;
            match *s {
                MaSub::Const(c) => (1..=n).contains(&c),
                MaSub::Axis(a, k) => {
                    bx.lo[a] + k >= 1 && bx.lo[a] + k + bx.shape[a] as i64 - 1 <= n
                }
            }
        });
        if !inside {
            return Ok(None);
        }
        self.held_exprs.push(rewritten.clone());
        self.lower_expr(&rewritten, bx).map(Some)
    }

    /// `e` with the read `index(·, subs…)` pushed through its elementwise
    /// operations to each makearray it combines (`proto` is the `index`
    /// node whose shape the rewritten reads take). The arrays combined must
    /// share one bounding-box shape — the oracle's broadcast of two that do
    /// not is not an element-by-element read — and every other operand be
    /// one number per cell.
    fn push_index(
        &self,
        e: &Expr,
        subs: &[Expr],
        proto: &Arc<ExpressionNode>,
        bx: &LBox,
    ) -> Pushed {
        let scalar_or_no = |s: &Self| {
            if s.cell_scalar(e, bx) {
                Pushed::Scalar
            } else {
                Pushed::No
            }
        };
        let Expr::Operator(n) = e else {
            return scalar_or_no(self);
        };
        let rebuild = |args: Vec<Expr>| {
            let mut m = (**n).clone();
            m.args = args;
            Expr::Operator(Arc::new(m))
        };
        match vec_op_code(&n.op) {
            VecOp::Makearray => {
                let Some(Ok(bounds)) = n.regions.as_ref().map(|r| MakearrayBounds::of(r)) else {
                    return Pushed::No;
                };
                let shape = bounds.shape();
                if shape.contains(&0) || shape.len() != subs.len() {
                    return Pushed::No;
                }
                let mut ix = (**proto).clone();
                ix.args = std::iter::once(e.clone())
                    .chain(subs.iter().cloned())
                    .collect();
                Pushed::Array(Expr::Operator(Arc::new(ix)), shape)
            }
            VecOp::Arith(_) | VecOp::Cmp(_) | VecOp::Unary(_) | VecOp::Neg => {
                let mut args = Vec::with_capacity(n.args.len());
                let mut shape: Option<DimU> = None;
                for a in &n.args {
                    match self.push_index(a, subs, proto, bx) {
                        Pushed::Array(x, s) => {
                            if shape.as_ref().is_some_and(|t| *t != s) {
                                return Pushed::No;
                            }
                            shape = Some(s);
                            args.push(x);
                        }
                        Pushed::Scalar => args.push(a.clone()),
                        Pushed::No => return Pushed::No,
                    }
                }
                match shape {
                    None => Pushed::Scalar,
                    Some(s) => Pushed::Array(rebuild(args), s),
                }
            }
            VecOp::Ifelse if n.args.len() == 3 => {
                if !self.cell_scalar(&n.args[0], bx) {
                    return Pushed::No;
                }
                match (
                    self.push_index(&n.args[1], subs, proto, bx),
                    self.push_index(&n.args[2], subs, proto, bx),
                ) {
                    (Pushed::Scalar, Pushed::Scalar) => Pushed::Scalar,
                    (Pushed::Array(a, s), Pushed::Array(b, t)) if s == t => {
                        Pushed::Array(rebuild(vec![n.args[0].clone(), a, b]), s)
                    }
                    _ => Pushed::No,
                }
            }
            _ => scalar_or_no(self),
        }
    }

    /// A makearray whose region values read none of the box's symbols, as
    /// the base of a gather in `bx`: the same array at every cell, built
    /// once at its own rank, re-origined to 1 as the oracle reads it. Its
    /// faults sort at the box's first cell, where the oracle meets them
    /// first, in expression order.
    fn lower_makearray_once(&mut self, node: &Arc<ExpressionNode>, bx: &LBox) -> LResult<LV> {
        let Some(regions) = node.regions.as_ref() else {
            bail_tape!("makearray: no `regions`");
        };
        let bounds = match MakearrayBounds::of(regions) {
            Ok(b) => b,
            Err(why) => bail_tape!("makearray: {why}"),
        };
        let shape = bounds.shape();
        let mbx = LBox {
            syms: &[],
            lo: bounds.lo,
            shape,
            cnames: bx.cnames,
            cvals: bx.cvals.clone(),
            tuple: 0,
            visit: SmallVec::new(),
        };
        let level = self.enter_fault_level(Some(bx));
        let v = self.lower_makearray(node, &mbx);
        self.leave_fault_level(level);
        Ok(self.reorigin_to_one(v?))
    }

    fn lower_makearray(&mut self, node: &Arc<ExpressionNode>, bx: &LBox) -> LResult<LV> {
        if bx.tuple != 0 {
            bail_tape!("makearray: inside a tuple-list contraction body");
        }
        let Some(regions) = node.regions.as_ref() else {
            bail_tape!("makearray: no `regions`");
        };
        let Some(values) = node.values.as_ref() else {
            bail_tape!("makearray: no `values`");
        };
        if values.len() != regions.len() {
            bail_tape!("makearray: empty or mismatched regions/values");
        }
        let bounds = match MakearrayBounds::of(regions) {
            Ok(b) => b,
            Err(why) => bail_tape!("makearray: {why}"),
        };
        let ndim = bounds.lo.len();
        if ndim != bx.shape.len() {
            bail_tape!("makearray: region rank != output box rank");
        }
        let (lo_bb, bb_shape) = (&bounds.lo, bounds.shape());
        if bb_shape.contains(&0) {
            bail_tape!("makearray: empty bounding box");
        }

        // Every region value first, then ONE instruction assembling them: a
        // makearray whose values are all literals is a constant array, built
        // here; any other is an `Instr::Assemble`.
        let mut parts: Vec<(LV, u32)> = Vec::with_capacity(regions.len());
        for (region, value_expr) in bounds.regions.iter().zip(values.iter()) {
            let r_lo: DimI = region.iter().map(|r| r[0]).collect();
            let r_shape: DimU = region.iter().map(|r| (r[1] - r[0] + 1) as usize).collect();
            // A region is its own box (and CSE scope): a ramp / shifted gather
            // means something different inside it.
            let rbx = LBox {
                syms: bx.syms,
                lo: r_lo.clone(),
                shape: r_shape.clone(),
                cnames: bx.cnames,
                cvals: bx.cvals.clone(),
                tuple: bx.tuple,
                visit: SmallVec::new(),
            };
            // The legal EMPTY spelling (`stop == start - 1`, §4.3.2) covers no
            // cell, but the oracle still evaluates its value, and an array
            // value that does not fit poisons the whole makearray with `NaN`.
            // Its instructions are dropped; a fault it raises is kept.
            if r_shape.contains(&0) {
                let txn = self.sub_txn();
                self.push_scope();
                let v = self.lower_expr(value_expr, &rbx);
                self.pop_scope();
                let v = v?;
                let fits = match self.lv_box(&v) {
                    None => true,
                    Some((s, _)) => s.is_empty() || region_value_axes(&s, &r_shape).is_some(),
                };
                let fault = (self.fault.first.take(), self.fault.seq);
                self.sub_rollback(txn);
                (self.fault.first, self.fault.seq) = fault;
                if !fits {
                    bail_tape!("makearray: an empty region's array value does not fit it");
                }
                continue;
            }
            self.push_scope();
            let v = self.lower_expr(value_expr, &rbx);
            self.pop_scope();
            let v = v?;
            // An array region value must fit the region, excluding its
            // singleton axes (esm-spec §4.3.2). It is placed by shape: the
            // oracle's arrays carry no origin. A lower-rank value — a face
            // region's aggregate over its one free axis — is broadcast over
            // the singleton axes it does not name.
            let v = match self.lv_box(&v) {
                None => v,
                Some((s, _)) => match region_value_axes(&s, &r_shape) {
                    Some(covered) if covered.iter().all(|&c| c) => v,
                    Some(covered) => {
                        let src_axes: SmallVec<[usize; 4]> = (0..s.len()).collect();
                        let segs = r_shape
                            .iter()
                            .map(|&n| {
                                let mut one = SmallVec::new();
                                one.push((0usize, n, 0usize));
                                one
                            })
                            .collect();
                        self.emit_gather(
                            &v,
                            SmallVec::new(),
                            &src_axes,
                            covered,
                            segs,
                            &r_shape,
                            &r_lo,
                        )
                    }
                    None => bail_tape!("makearray: region value box does not match the region"),
                },
            };
            let region_ix = tape_index(self.tables.regions.len(), "makearray regions")?;
            self.tables.regions.push(RegionSpec {
                dest_lo: (0..ndim).map(|d| (r_lo[d] - lo_bb[d]) as usize).collect(),
                shape: r_shape,
            });
            parts.push((v, region_ix));
        }

        if parts.iter().all(|(v, _)| matches!(v, LV::Lit(_))) {
            let mut values = ndarray::ArrayD::<f64>::zeros(ndarray::IxDyn(&bb_shape));
            for (v, region_ix) in &parts {
                let LV::Lit(x) = v else { unreachable!() };
                let spec = &self.tables.regions[*region_ix as usize];
                let mut view = values.view_mut();
                for d in 0..ndim {
                    view.slice_axis_inplace(
                        ndarray::Axis(d),
                        ndarray::Slice::from(spec.dest_lo[d]..spec.dest_lo[d] + spec.shape[d]),
                    );
                }
                view.fill(*x);
            }
            let values = Arc::new(values.iter().copied().collect());
            let out = self.emit_const_data(&bb_shape, lo_bb, values, false)?;
            return Ok(LV::Arr(out));
        }

        let want = parts
            .iter()
            .map(|(v, _)| self.lv_cadence(v))
            .max()
            .unwrap_or(Cadence::Const);
        let sec = self.placement(want);
        let table = tape_index(self.tables.assemblies.len(), "makearray assemblies")?;
        let spec = AssembleSpec {
            parts: parts.iter().map(|(v, r)| (self.op_of(v), *r)).collect(),
        };
        self.tables.assemblies.push(spec);
        let out = self.new_slot(&bb_shape, lo_bb, false, sec);
        self.emit(Instr::Assemble { table, out }, sec);
        Ok(LV::Arr(out))
    }

    // -- recurrence (the `sweep_recurrence` mirror) ----------------------------

    /// A causal self-reference (esm-spec §4.3.1.1): one [`Instr::Sweep`] whose
    /// body is `body` lowered ONCE for one cell of the frame, the frame
    /// symbols read from coordinate slots the sweep rewrites before each pass.
    /// The program's size does not depend on the frame's.
    ///
    /// The body mirrors the per-cell oracle: every value in
    /// it is one scalar, a runtime scalar `ifelse` or `filter` short-circuits
    /// (so a guarded self-read at the first cell is never evaluated), a
    /// contraction is folded term by term in the oracle's order
    /// ([`Self::lower_cell_contraction`]), and a self-read is fail-closed.
    fn lower_recurrence(
        &mut self,
        var: &str,
        idx_names: &[String],
        ranges: &[(i64, i64)],
        body: &Expr,
        axis: usize,
    ) -> LResult<ObsVal> {
        if self.rule.sweep.is_some() {
            bail_tape!("observed: recurrence nested in another recurrence body");
        }
        // The interpreter publishes the frame `[lo, hi]` while every other
        // observed path, and so every reader here, sees the padded `[1, hi]`
        // box: the same guard `ArrayLoop` takes.
        if ranges.iter().any(|(lo, _)| *lo != 1) {
            bail_tape!("observed: recurrence over non-unit-origin output ranges");
        }
        let shape: DimU = ranges.iter().map(|(_, hi)| (*hi).max(0) as usize).collect();
        let ones = DimI::from_elem(1, shape.len());
        if shape.contains(&0) {
            // No cell, so no body evaluation: the empty array.
            return Ok(ObsVal::Taped(self.emit_zero_array(&shape, &ones)));
        }
        let home = self.home;
        let out = self.new_slot(&shape, &ones, false, home);
        let coords: SmallVec<[SlotId; 4]> = (0..shape.len())
            .map(|_| self.new_slot(&[], &[], true, home))
            .collect();
        let spec = tape_index(self.tables.sweeps.len(), "recurrence sweeps")?;
        self.tables.sweeps.push(SweepSpec {
            var: var.to_string(),
            out,
            coords: coords.clone(),
            shape,
            axis: u8::try_from(axis)
                .map_err(|_| Bail::new(format!("observed: recurrence axis {axis} out of range")))?,
            body_len: 0,
            result: Operand::Lit(f64::NAN),
        });
        let mut body_slots = rustc_hash::FxHashSet::default();
        body_slots.insert(out);
        body_slots.extend(coords.iter().copied());
        self.rule.sweep = Some(SweepCtx {
            spec,
            var: var.to_string(),
            out,
            binds: idx_names
                .iter()
                .cloned()
                .zip(coords.iter().copied())
                .collect(),
            body_slots,
            body: Vec::new(),
        });
        let cell = LBox::new(&[], DimI::new(), DimU::new());
        self.push_scope();
        let v = self.lower_expr(body, &cell);
        self.pop_scope();
        let sw = self.rule.sweep.take().expect("recurrence body open");
        let v = v?;
        if self.lv_box(&v).is_some() {
            // The oracle reads an array-valued cell as `NaN`.
            bail_tape!("observed: recurrence cell body of `{var}` is array-valued");
        }
        let result = self.op_of(&v);
        let body_len = tape_index(sw.body.len(), "instructions in one recurrence body")?;
        let entry = &mut self.tables.sweeps[spec as usize];
        entry.body_len = body_len;
        entry.result = result;
        self.push_stream(Instr::Sweep { spec }, crate::precision::active(), home);
        for (i, p) in sw.body {
            self.push_stream(i, p, home);
        }
        Ok(ObsVal::Taped(LV::Arr(out)))
    }

    /// A rank-0 aggregate at one recurrence cell: `reduce_contraction` term
    /// by term. Each contraction tuple, in the oracle's `CartesianTuples`
    /// order (the last contracted name fastest), is a box of its own with the
    /// tuple bound as constants; a tuple the `filter` excludes is SKIPPED —
    /// its term is never evaluated and nothing is combined, the oracle's
    /// `continue` — and a runtime filter short-circuits. The program grows
    /// with the contraction window (a body property), not with the frame.
    fn lower_cell_contraction(&mut self, spec: &ArrayOpSpec, bx: &LBox) -> LResult<LV> {
        // A reduction at one cell is a scalar one, `bool_and_or` included.
        let combine = scalar_combine_op(spec.reduce);
        let identity = spec.reduce.identity();
        let nc = spec.contract_names.len();
        if nc == 0 {
            // The pointwise case: the body itself (the identity when the
            // filter excludes it), never `identity ⊕ body`.
            return self.lower_cell_term(spec.body, spec.filter, bx, None, identity, combine);
        }
        let mut clo: SmallVec<[i64; 4]> = SmallVec::from_elem(0, nc);
        let mut chi: SmallVec<[i64; 4]> = SmallVec::from_elem(0, nc);
        for (i, d) in spec.contract_dims.iter().enumerate() {
            match d {
                ContractDim::Static(l, h) => {
                    clo[i] = *l;
                    chi[i] = *h;
                }
                other => bail_tape!("contracted: non-static contraction dim ({other:?})"),
            }
        }
        if (0..nc).any(|i| clo[i] > chi[i]) {
            return Ok(LV::Lit(identity));
        }
        // The tuple's own names shadow an enclosing contraction's.
        let mut names: Vec<String> = spec.contract_names.clone();
        names.extend(bx.cnames.iter().cloned());
        let mut acc = LV::Lit(identity);
        let mut cvals = clo.clone();
        loop {
            let mut vals: SmallVec<[i64; 4]> = SmallVec::from_slice(&cvals[..nc]);
            vals.extend(bx.cvals.iter().copied());
            let tbx = LBox {
                syms: &[],
                lo: DimI::new(),
                shape: DimU::new(),
                cnames: &names,
                cvals: vals,
                tuple: 0,
                visit: SmallVec::new(),
            };
            self.push_scope();
            let r =
                self.lower_cell_term(spec.body, spec.filter, &tbx, Some(acc), identity, combine);
            self.pop_scope();
            acc = r?;
            let mut d = nc;
            let mut done = true;
            while d > 0 {
                d -= 1;
                cvals[d] += 1;
                if cvals[d] <= chi[d] {
                    done = false;
                    break;
                }
                cvals[d] = clo[d];
            }
            if done {
                break;
            }
        }
        Ok(acc)
    }

    /// One term of [`Self::lower_cell_contraction`]: `acc ⊕ body` when the
    /// filter keeps the tuple and `acc` unchanged when it does not; with no
    /// `acc`, the pointwise value (`body`, or `identity` when excluded).
    /// `filter_excludes` is `value == 0.0`, which is the complement of the
    /// branch's `cond != 0` — a NaN filter keeps the term.
    fn lower_cell_term(
        &mut self,
        body: &Expr,
        filter: Option<&Expr>,
        bx: &LBox,
        acc: Option<LV>,
        identity: f64,
        combine: BinCode,
    ) -> LResult<LV> {
        let skip = acc.clone().unwrap_or(LV::Lit(identity));
        let term = |s: &mut Self| -> LResult<LV> {
            let t = s.lower_expr(body, bx)?;
            if s.lv_box(&t).is_some() {
                bail_tape!("contracted: array-valued term inside a recurrence body");
            }
            match &acc {
                Some(a) => s.emit_bin(combine, a.clone(), t),
                None => Ok(t),
            }
        };
        let Some(f) = filter else {
            return term(self);
        };
        match self.lower_expr(f, bx)? {
            // `-0.0` matches too: `filter_excludes` is `value == 0.0`.
            LV::Lit(0.0) => Ok(skip),
            LV::Lit(_) => term(self),
            keep if self.lv_box(&keep).is_none() => {
                let mut term = Some(term);
                self.lower_branchy(keep, false, |s, taken| {
                    if taken {
                        (term.take().expect("the kept arm is lowered once"))(s)
                    } else {
                        Ok(skip.clone())
                    }
                })
            }
            _ => bail_tape!("contracted: array-valued filter inside a recurrence body"),
        }
    }
}

// ---------------------------------------------------------------------------
// Rule-level driving, exports, liveness/coloring, report — in build().
// ---------------------------------------------------------------------------

/// Result of building the tape for one compiled model (the rules, tables and
/// const-array registry are read straight off `compiled`). Returns the
/// program — or, when any rule declined, the [`DeclinedTape`] in its place —
/// and the `(scope, hoist)` value-numbering hit counts.
/// The scalar parameters a join key column or an overlap envelope factor of
/// `compiled` reads, directly or through observeds
/// ([`crate::join::join_key_cone`]), at their baked values (their defaults,
/// which the build set from the caller's `p`).
fn baked_join_key_params(compiled: &ArrayCompiled) -> FxHashMap<String, f64> {
    let bodies: FxHashMap<&str, &Expr> = compiled
        .observed_rules
        .iter()
        .map(|r| (observed_rule_var(r).as_str(), observed_rule_body(r)))
        .collect();
    fn rhs_body(r: &RhsRule) -> &Expr {
        match r {
            RhsRule::Scalar { body, .. }
            | RhsRule::IndexedScalar { body, .. }
            | RhsRule::ArrayLoop { body, .. } => body,
        }
    }
    let roots = compiled
        .observed_rules
        .iter()
        .map(observed_rule_body)
        .chain(compiled.rhs_rules.iter().map(rhs_body));
    let cone = crate::join::join_key_cone(roots, |n| bodies.get(n).copied());
    compiled
        .param_names
        .iter()
        .zip(&compiled.param_defaults)
        .filter(|(n, _)| cone.contains(n.as_str()))
        .filter_map(|(n, d)| d.map(|v| (n.clone(), v)))
        .collect()
}

pub(super) fn build_tape_program(
    compiled: &ArrayCompiled,
    const_names: &HashSet<String>,
    seg_invariant_names: &HashSet<String>,
    forcing: &ForcingInputs<'_>,
    // Step 4: run the kernel-fusion post-pass with the given superop
    // configuration (`None` = the unfused program, bitwise-identical
    // results — the arm `build_tape_opts` gives the fused-vs-unfused tests).
    fuse: Option<super::fuse::SuperopCfg>,
    // Store the program axis-reversed where the state layout gains from it
    // (`super::layout`); off for the XLA emitter, which reads logical boxes.
    align_layout: bool,
    // A tile build's state domains and observed need boxes (API_SPEC §5.8);
    // `None` for the whole-domain program.
    tile: Option<&TileLowering>,
) -> (Result<TapeProgram, DeclinedTape>, (usize, usize)) {
    let rhs_rules: &[RhsRule] = &compiled.rhs_rules;
    let observed_rules: &[AlgebraicRule] = &compiled.observed_rules;
    let var_shapes = &compiled.var_shapes;
    let param_names: &[String] = &compiled.param_names;
    let const_arrays: &ConstArrayScope = &compiled.const_scope;
    let mut obs_tier: FxHashMap<String, Cadence> = FxHashMap::default();
    for r in observed_rules {
        let name = observed_rule_var(r);
        let tier = if const_names.contains(name) {
            Cadence::Const
        } else if seg_invariant_names.contains(name) {
            Cadence::Segment
        } else {
            Cadence::Continuous
        };
        obs_tier.insert(name.clone(), tier);
    }

    let mut b = TapeBuilder::new(var_shapes, param_names, obs_tier, const_arrays, forcing);
    b.observed_rules = observed_rules;
    b.tile = tile;
    b.baked_params = baked_join_key_params(compiled);
    b.count_fold = compiled.rewrites.count_fold;

    // ---- observed rules, in dependency order -------------------------------
    for (i, rule) in observed_rules.iter().enumerate() {
        let name = observed_rule_var(rule).clone();
        let tier = *b.obs_tier.get(&name).expect("tier classified");
        b.begin_rule(RuleInfo {
            name: name.clone(),
            kind: RuleKind::Observed(i),
            cadence: tier,
        });
        let txn = b.txn();
        // The rule's own working precision, as `materialize_observeds_pass`
        // arms it: every instruction it emits is tagged with it.
        let _rule_precision = crate::precision::has_variable_overrides()
            .then(|| crate::precision::enter(crate::precision::of_variable(&name)));
        let lowered = b
            .lower_observed_rule(rule)
            .and_then(|v| b.flush_rule_fault().map(|()| v))
            .and_then(|v| b.take_tile_violation().map(|()| v));
        let pending = b.tile_pending.take();
        match lowered {
            Ok(obs_val) => {
                if let Some((slot, axes)) = pending {
                    b.tile_slots.insert(slot, axes);
                }
                b.obs_defined.insert(name, obs_val);
            }
            Err(bail) => {
                b.rollback(txn);
                b.declined[b.cur_rule as usize] = Some(bail);
                b.obs_defined.insert(name, ObsVal::Declined);
            }
        }
        b.end_rule();
    }

    // ---- RHS rules ---------------------------------------------------------
    for (i, rule) in rhs_rules.iter().enumerate() {
        // The state's NAME, not its slot index. A refusal has to name the
        // rule an author can find (esm-libraries-spec §2.5.10: "naming the
        // compiler, the rule — an equation or an observed,
        // component-qualified — and the reason"), and `D(slot 0)` names
        // nothing: the flat slot order is an implementation detail that
        // coupling reorders.
        let name = match rule {
            RhsRule::Scalar { slot, .. } | RhsRule::IndexedScalar { slot, .. } => {
                match super::super::layout::slot_name(&compiled.var_shapes, *slot) {
                    Some(var) => format!("D({var})"),
                    None => format!("D(slot {slot})"),
                }
            }
            RhsRule::ArrayLoop { var_name, .. } => format!("D({var_name})"),
        };
        b.begin_rule(RuleInfo {
            name,
            kind: RuleKind::Rhs(i),
            cadence: Cadence::Continuous,
        });
        let txn = b.txn();
        match b
            .lower_rhs_rule(rule)
            .and_then(|()| b.flush_rule_fault())
            .and_then(|()| b.take_tile_violation())
        {
            Ok(()) => {}
            Err(bail) => {
                b.rollback(txn);
                b.declined[b.cur_rule as usize] = Some(bail);
            }
        }
        b.end_rule();
    }

    // ---- a declined rule leaves no program ---------------------------------
    let vn_hits = b.vn_hits();
    if b.declined.iter().any(Option::is_some) {
        let declined = DeclinedTape {
            rules: std::mem::take(&mut b.rules),
            reasons: std::mem::take(&mut b.declined),
        };
        return (Err(declined), vn_hits);
    }

    // ---- exports -----------------------------------------------------------
    let exports = b.compute_exports(observed_rules, compiled.tape_serves_passes());

    // ---- flatten + fusion + liveness + coloring ----------------------------
    (Ok(b.finish(exports, fuse, align_layout)), vn_hits)
}

/// How a subscript of a makearray read in a box reads it
/// ([`TapeBuilder::makearray_subs`]): box axis `.0` shifted by `.1`, or a
/// constant position.
#[derive(Clone, Copy)]
enum MaSub {
    Axis(usize, i64),
    Const(i64),
}

/// [`TapeBuilder::push_index`]'s answer: the rewritten read and the shape
/// of the array it reads; one number per cell, untouched; or neither.
enum Pushed {
    Array(Expr, DimU),
    Scalar,
    No,
}

/// Whether a makearray sits under `e`'s elementwise operations (or is `e`).
fn reaches_makearray(e: &Expr) -> bool {
    let Expr::Operator(n) = e else {
        return false;
    };
    match vec_op_code(&n.op) {
        VecOp::Makearray => true,
        VecOp::Arith(_) | VecOp::Cmp(_) | VecOp::Unary(_) | VecOp::Neg | VecOp::Ifelse => {
            n.args.iter().any(reaches_makearray)
        }
        _ => false,
    }
}

/// Whether a region value of the makearray `ma` reads one of `bx`'s
/// symbols: if none does, it is the same array at every cell of `bx`.
fn makearray_reads_box(ma: &ExpressionNode, bx: &LBox) -> bool {
    ma.values.as_ref().is_some_and(|vs| {
        vs.iter()
            .any(|v| bx.syms.iter().any(|s| mentions_unshadowed(v, s)))
    })
}

/// [`expr_mentions`] that does not see a name an `faq` inside `e` rebinds
/// as one of its own indices.
fn mentions_unshadowed(e: &Expr, name: &str) -> bool {
    match e {
        Expr::Variable(v) => v == name,
        Expr::Number(_) | Expr::Integer(_) => false,
        Expr::Operator(n) => {
            if n.args.iter().any(|a| mentions_unshadowed(a, name)) {
                return true;
            }
            if let Some(spec) = faq_spec(n)
                && (spec.idx_names.iter().any(|x| x == name)
                    || spec.contract_names.iter().any(|x| x == name))
            {
                return false;
            }
            [&n.expr, &n.filter, &n.lower, &n.upper]
                .into_iter()
                .any(|x| x.as_deref().is_some_and(|x| mentions_unshadowed(x, name)))
                || n.values
                    .as_ref()
                    .is_some_and(|vs| vs.iter().any(|x| mentions_unshadowed(x, name)))
        }
    }
}

/// A `makearray`'s regions as integers: each region's `[lo, hi]` per axis
/// (the legal empty spelling `hi == lo - 1` included) and their bounding box.
struct MakearrayBounds {
    lo: DimI,
    hi: DimI,
    regions: Vec<SmallVec<[[i64; 2]; 4]>>,
}

impl MakearrayBounds {
    /// `Err` names why the regions have no lowering: none at all, a ragged
    /// rank, or a bound not folded to an integer.
    fn of(regions: &[Vec<[crate::types::RegionBound; 2]>]) -> Result<Self, &'static str> {
        let Some(first) = regions.first() else {
            return Err("empty or mismatched regions/values");
        };
        let ndim = first.len();
        let mut lo = DimI::from_elem(i64::MAX, ndim);
        let mut hi = DimI::from_elem(i64::MIN, ndim);
        let mut out = Vec::with_capacity(regions.len());
        for region in regions {
            if region.len() != ndim {
                return Err("ragged region rank");
            }
            let mut b = SmallVec::new();
            for (d, r) in region.iter().enumerate() {
                let Some([r_lo, r_hi]) = crate::types::region_bounds(r) else {
                    return Err("unfolded (symbolic) region bound");
                };
                lo[d] = lo[d].min(r_lo);
                hi[d] = hi[d].max(r_hi);
                b.push([r_lo, r_hi]);
            }
            out.push(b);
        }
        Ok(Self {
            lo,
            hi,
            regions: out,
        })
    }

    /// The bounding box's extent per axis (0 for an all-empty axis).
    fn shape(&self) -> DimU {
        (0..self.lo.len())
            .map(|d| (self.hi[d] - self.lo[d] + 1).max(0) as usize)
            .collect()
    }
}

/// True iff `e` is a `reshape` / `transpose` / `concat`, or an operator one of
/// whose operands (looking through operators) is.
fn mentions_shape_op(e: &Expr) -> bool {
    match e {
        Expr::Operator(n) => {
            matches!(n.op.as_str(), "reshape" | "transpose" | "concat")
                || n.args.iter().any(mentions_shape_op)
        }
        _ => false,
    }
}

/// True iff an `ifelse` sits on `e`'s value path: `e` is one, or an
/// elementwise op one of whose operands has one on its value path. An
/// `ifelse` inside an op that consumes its operand whole (a gather, a
/// reduction, a shape op) or inside another `ifelse`'s condition is not.
fn value_path_has_ifelse(e: &Expr) -> bool {
    let Expr::Operator(n) = e else {
        return false;
    };
    match crate::op_registry::elementwise_op(n) {
        Some("ifelse") => true,
        Some(_) => n.args.iter().any(value_path_has_ifelse),
        None => false,
    }
}
