//! State-layout alignment: store a program's boxes axis-reversed.
//!
//! The flat state vector holds each array variable column-major (axis 0
//! fastest), while every tape slot is row-major (last axis fastest). Run as
//! lowered, each call must transpose the state into a row-major mirror before
//! the first read and transpose every derivative back on its way into `dy`:
//! two strided passes over the whole state that cost more than the stencil
//! arithmetic between them.
//!
//! A column-major array over `[n0, n1, …, nk]` is, element for element, the
//! row-major array over `[nk, …, n1, n0]`. This pass rewrites a program into
//! those reversed coordinates — every slot box, state box, gather plan,
//! region, axis field and table position — so the slab and the state vector
//! agree: a state block is read in place and a whole-box derivative is one
//! contiguous copy into `dy`. Only where values cross to a logical array (a
//! forcing load, an export) does the executor transpose, and those run once
//! per segment or only for an explicit reader.
//!
//! Nothing about any element's arithmetic changes. Elementwise instructions
//! are order-free; a gather, region or table read moves the same element to
//! the same logical cell; a single-axis reduction or scan folds each output
//! cell along its own axis in ascending order whichever way the other axes
//! are stored. The constructs whose ORDER is a logical row-major walk — a
//! multi-axis reduction, a reshape, a compressed-row reduction's output
//! cells, a recurrence sweep, a scatter that writes one position twice — keep
//! the program as lowered, as does anything that exchanges arrays with the
//! interpreter (a fallback rule, an observed read through the runtime map).

use super::ir::*;
use smallvec::SmallVec;

/// Rewrite `prog` axis-reversed and set [`TapeProgram::col_major`], when the
/// state layout gains from it and every instruction keeps its meaning;
/// otherwise leave it untouched. Runs before fusion and slab coloring, which
/// then see an ordinary program.
pub(super) fn align_state_layout(prog: &mut TapeProgram) {
    if !prog.state_vars.iter().any(|sv| !order_free(&sv.shape)) || !reversible(prog) {
        return;
    }
    reverse(prog);
    prog.col_major = true;
}

/// Whether a box's row-major order is the same walk as its reversed box's:
/// true when at most one axis has more than one element.
pub(crate) fn order_free(shape: &[usize]) -> bool {
    shape.iter().filter(|&&n| n > 1).count() <= 1
}

fn rev<T: Copy, A: smallvec::Array<Item = T>>(v: &SmallVec<A>) -> SmallVec<A> {
    v.iter().rev().copied().collect()
}

/// The row-major flat offset, in the REVERSED box, of the element at
/// row-major flat offset `k` of `shape` (its column-major offset).
fn reversed_flat(mut k: usize, shape: &[usize]) -> usize {
    let mut out = 0usize;
    let mut stride = 1usize;
    // Peel row-major digits last-axis first; they weigh in column-major.
    let mut st: SmallVec<[usize; 4]> = SmallVec::from_elem(0, shape.len());
    for d in 0..shape.len() {
        st[d] = stride;
        stride *= shape[d];
    }
    for d in (0..shape.len()).rev() {
        let n = shape[d].max(1);
        out += (k % n) * st[d];
        k /= n;
    }
    out
}

/// `values` (row-major over `shape`) re-laid row-major over the reversed box.
fn transpose_values(values: &[f64], shape: &[usize]) -> Vec<f64> {
    if order_free(shape) {
        return values.to_vec();
    }
    let mut out = vec![0.0f64; values.len()];
    for (k, &v) in values.iter().enumerate() {
        out[reversed_flat(k, shape)] = v;
    }
    out
}

fn op_ok(op: &Operand) -> bool {
    !matches!(op, Operand::Obs(_))
}

fn src_ok(src: &SrcRef) -> bool {
    !matches!(src, SrcRef::Obs(_))
}

fn src_shape<'a>(prog: &'a TapeProgram, src: &SrcRef) -> &'a [usize] {
    match src {
        SrcRef::Slot(s) => &prog.slots[*s as usize].shape,
        SrcRef::State(ix) => &prog.state_vars[*ix as usize].shape,
        SrcRef::Obs(_) => &[],
    }
}

/// Whether every instruction means the same thing in reversed coordinates
/// (see the module docs for what declines).
fn reversible(prog: &TapeProgram) -> bool {
    let slot_free = |s: SlotId| order_free(&prog.slots[s as usize].shape);
    prog.instrs.iter().all(|i| match i {
        Instr::Bin { a, b, .. } => op_ok(a) && op_ok(b),
        Instr::Un { a, .. }
        | Instr::Neg { a, .. }
        | Instr::Copy { a, .. }
        | Instr::Calendar { a, .. } => op_ok(a),
        Instr::Fill { v, .. } => op_ok(v),
        Instr::Select { cond, a, b, .. } => op_ok(cond) && op_ok(a) && op_ok(b),
        Instr::Interp { x, y, .. } => op_ok(x) && y.as_ref().is_none_or(op_ok),
        Instr::Region { src, .. } => op_ok(src),
        Instr::Assemble { table, .. } => prog.assemblies[*table as usize]
            .parts
            .iter()
            .all(|(op, _)| op_ok(op)),
        Instr::Gather { src, .. } | Instr::LoadElem { src, .. } | Instr::TableGather { src, .. } => {
            src_ok(src)
        }
        Instr::IndexGather { src, idx, .. } => src_ok(src) && op_ok(idx),
        Instr::Ramp { .. }
        | Instr::ConstArray { .. }
        | Instr::LoadForcing { .. }
        | Instr::Fault { .. }
        | Instr::JmpIfZero { .. }
        | Instr::Export { .. } => true,
        Instr::Reduce { src, axes, .. } => src_ok(src) && axes.len() <= 1,
        Instr::Scan { src, .. } => src_ok(src),
        Instr::SegReduce { out, .. } => slot_free(*out),
        Instr::Reshape { src, out } => {
            src_ok(src) && order_free(src_shape(prog, src)) && slot_free(*out)
        }
        Instr::ScalarRead { src, .. } => src_ok(src) && order_free(src_shape(prog, src)),
        Instr::DyWrite { write } => match &prog.dy_writes[*write as usize].scatter {
            Some(pos) => {
                let mut seen = pos.clone();
                seen.sort_unstable();
                seen.windows(2).all(|w| w[0] != w[1])
            }
            None => true,
        },
        Instr::PolyArea { .. } | Instr::Sweep { .. } | Instr::Fallback { .. } => false,
        // The pass runs ahead of fusion.
        Instr::Fused { .. } => false,
    })
}

/// Rewrite every axis-bearing part of `prog` into reversed coordinates.
/// Reads only ORIGINAL shapes until the slot and state tables are reversed
/// last.
fn reverse(prog: &mut TapeProgram) {
    // Instructions: the axis fields that live inline.
    for idx in 0..prog.instrs.len() {
        let instr = &prog.instrs[idx];
        let rewritten = match instr {
            Instr::Ramp { axis, lo, out } => {
                let n = prog.slots[*out as usize].shape.len() as u8;
                Some(Instr::Ramp {
                    axis: n - 1 - *axis,
                    lo: *lo,
                    out: *out,
                })
            }
            Instr::LoadElem { src, idx, out } => Some(Instr::LoadElem {
                src: *src,
                idx: rev(idx),
                out: *out,
            }),
            Instr::Reduce {
                op,
                init,
                src,
                axes,
                src_shape,
                out,
            } => {
                let n = src_shape.len() as u8;
                Some(Instr::Reduce {
                    op: *op,
                    init: *init,
                    src: *src,
                    axes: axes.iter().map(|&a| n - 1 - a).collect(),
                    src_shape: rev(src_shape),
                    out: *out,
                })
            }
            Instr::Scan {
                op,
                init,
                src,
                axis,
                inclusive,
                src_shape,
                out,
            } => {
                let n = src_shape.len() as u8;
                Some(Instr::Scan {
                    op: *op,
                    init: *init,
                    src: *src,
                    axis: n - 1 - *axis,
                    inclusive: *inclusive,
                    src_shape: rev(src_shape),
                    out: *out,
                })
            }
            _ => None,
        };
        if let Some(r) = rewritten {
            prog.instrs[idx] = r;
        }
    }

    for plan in &mut prog.plans {
        reverse_plan(plan);
    }
    for r in &mut prog.regions {
        r.dest_lo = rev(&r.dest_lo);
        r.shape = rev(&r.shape);
    }
    for d in &mut prog.const_data {
        d.values = transpose_values(&d.values, &d.shape);
        d.shape = rev(&d.shape);
    }
    for g in &mut prog.index_gathers {
        let n_out = g.shape.len() as u8;
        g.axes = g
            .axes
            .iter()
            .rev()
            .map(|a| match *a {
                GatherAxis::Affine { axis, off } => GatherAxis::Affine {
                    axis: n_out - 1 - axis,
                    off,
                },
                other => other,
            })
            .collect();
        g.src_shape = rev(&g.src_shape);
        g.shape = rev(&g.shape);
    }
    for t in &mut prog.gather_tables {
        if !order_free(&t.src_shape) {
            for p in t.pos.iter_mut().filter(|p| **p != GATHER_GHOST) {
                *p = reversed_flat(*p as usize, &t.src_shape) as u32;
            }
        }
        t.src_shape = rev(&t.src_shape);
    }
    for w in &mut prog.dy_writes {
        w.dest_lo = rev(&w.dest_lo);
        if let Some(pos) = &mut w.scatter {
            let shape = &prog.slots[w.slot as usize].shape;
            if !order_free(shape) {
                let mut out = vec![0usize; pos.len()];
                for (k, &p) in pos.iter().enumerate() {
                    out[reversed_flat(k, shape)] = p;
                }
                *pos = out;
            }
        }
    }

    for s in &mut prog.slots {
        s.shape = rev(&s.shape);
        s.origin = rev(&s.origin);
    }
    for sv in &mut prog.state_vars {
        sv.shape = rev(&sv.shape);
        sv.origin = rev(&sv.origin);
    }
}

/// A gather plan in reversed coordinates: source axis `d` of `m` becomes
/// `m - 1 - d`, output axis `a` of `n` becomes `n - 1 - a`, and the mapped
/// axes keep pairing with the same source axes.
fn reverse_plan(plan: &mut GatherPlan) {
    let m = plan.src_shape.len();
    let mut fixed: SmallVec<[(usize, usize); 4]> =
        plan.fixed_desc.iter().map(|&(d, i)| (m - 1 - d, i)).collect();
    fixed.sort_unstable_by(|x, y| y.0.cmp(&x.0));
    let r = plan.perm.len();
    debug_assert_eq!(r, plan.mapped.iter().filter(|&&b| b).count());
    let perm: SmallVec<[usize; 4]> = (0..r).map(|q| r - 1 - plan.perm[r - 1 - q]).collect();
    plan.fixed_desc = fixed;
    plan.perm = perm;
    plan.mapped = rev(&plan.mapped);
    plan.segs = plan.segs.iter().rev().cloned().collect();
    plan.shape = rev(&plan.shape);
    plan.origin = rev(&plan.origin);
    plan.src_shape = rev(&plan.src_shape);
    plan.src_origin = rev(&plan.src_origin);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reversed_flat_is_the_column_major_offset() {
        let shape = [2usize, 3, 4];
        // Row-major offset of (i, j, k) is 12i + 4j + k; column-major is
        // i + 2j + 6k.
        for i in 0..2 {
            for j in 0..3 {
                for k in 0..4 {
                    assert_eq!(reversed_flat(12 * i + 4 * j + k, &shape), i + 2 * j + 6 * k);
                }
            }
        }
    }

    #[test]
    fn order_free_boxes() {
        assert!(order_free(&[]));
        assert!(order_free(&[7]));
        assert!(order_free(&[1, 7, 1]));
        assert!(!order_free(&[2, 7]));
    }
}
