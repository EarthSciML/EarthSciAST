//! Reads of a scan `makearray` that the scan itself answers.
//!
//! A column integral (EarthSciDiscretizations' `integral_lev_nodes_*`) is a
//! `makearray` placing a prefix scan `S` of a term `t` on rows `[d, d + R)`
//! of its scanned axis and one more value on row `d + R`, and its consumer
//! reads it at two neighbouring rows (`F[l + 1] - F[l]`). Lowered as
//! written, each read is a gather of the assembled array, so the assembly
//! and both reads are passes of their own between the scan and the
//! consumer. Two of those reads are the scan's own values, bit for bit:
//!
//! * rows `[d, d + R)` are `S` itself;
//! * rows `[d + 1, d + R]` are the scan of `t` with the other inclusivity,
//!   when the last row holds the value that scan ends on. A forward
//!   EXCLUSIVE scan's row `k + 1` is `fold(t[..=k])`, the forward inclusive
//!   scan's row `k`; its last row is then the column total, which a `Reduce`
//!   of the same term over the same axis computes by the same ascending
//!   fold. A reverse INCLUSIVE scan's row `k + 1` is `fold(t[k + 1..])`, the
//!   reverse exclusive scan's row `k`, and that ends on the fold's identity:
//!   the last row must be a literal with the identity's bits.
//!
//! Both folds visit the same terms in the same order from the same `init`,
//! so each rewritten read is the value the gather read. The rewrite turns
//! the read into a [`Instr::Copy`] of `S` or a second [`Instr::Scan`] of
//! `t`; the assembly then has no reader on the derivative path, and the
//! scan, its sibling and the consumer share one box and fuse into one pass.

use super::ir::*;
use crate::simulate_array::BinCode;
use smallvec::SmallVec;

/// Rewrite every read the scan answers (module docs).
pub(super) fn rewrite_scan_makearray_reads(prog: &mut TapeProgram) {
    let defs = single_defs(prog);
    for i in 0..prog.instrs.len() {
        let Instr::Gather {
            src: SrcRef::Slot(a),
            plan,
            out,
        } = prog.instrs[i]
        else {
            continue;
        };
        if let Some(new) = answer(prog, &defs, a, plan, out) {
            prog.instrs[i] = new;
        }
    }
}

/// The defining instruction of every slot defined exactly once.
fn single_defs(prog: &TapeProgram) -> Vec<Option<usize>> {
    let mut defs: Vec<Option<usize>> = vec![None; prog.slots.len()];
    let mut seen = vec![0u8; prog.slots.len()];
    for (i, ins) in prog.instrs.iter().enumerate() {
        if let Some(o) = ins.out() {
            let o = o as usize;
            seen[o] = seen[o].saturating_add(1);
            defs[o] = Some(i);
        }
    }
    for (d, &n) in defs.iter_mut().zip(&seen) {
        if n != 1 {
            *d = None;
        }
    }
    defs
}

/// What replaces the gather `out = a[plan]`, when the scan answers it.
fn answer(
    prog: &TapeProgram,
    defs: &[Option<usize>],
    a: SlotId,
    plan: u32,
    out: SlotId,
) -> Option<Instr> {
    let Instr::Assemble { table, .. } = prog.instrs[defs[a as usize]?] else {
        return None;
    };
    let p = &prog.plans[plan as usize];
    let nd = p.shape.len();
    // A window of the assembled box, axis for axis.
    if !p.fixed_desc.is_empty()
        || p.mapped.iter().any(|&m| !m)
        || p.perm.iter().enumerate().any(|(k, &d)| k != d)
        || p.src_shape[..] != prog.slots[a as usize].shape[..]
        || p.segs.len() != nd
    {
        return None;
    }
    let mut win: SmallVec<[(usize, usize); 4]> = SmallVec::new();
    for (d, segs) in p.segs.iter().enumerate() {
        let [(0, len, from)] = segs[..] else {
            return None;
        };
        if len != p.shape[d] {
            return None;
        }
        win.push((from, len));
    }
    let parts = &prog.assemblies[table as usize].parts;
    for (k, &(op, region)) in parts.iter().enumerate() {
        let Operand::Slot(s) = op else {
            continue;
        };
        let Instr::Scan {
            op: sop,
            init,
            src,
            axis,
            inclusive,
            reverse,
            ref src_shape,
            ..
        } = prog.instrs[defs[s as usize]?]
        else {
            continue;
        };
        let r = &prog.regions[region as usize];
        let ax = axis as usize;
        if r.shape[..] != src_shape[..] || r.shape.len() != nd {
            continue;
        }
        // Same window as the scan's region off the scanned axis.
        if (0..nd).any(|d| d != ax && win[d] != (r.dest_lo[d], r.shape[d])) {
            continue;
        }
        let (d0, rows) = (r.dest_lo[ax], r.shape[ax]);
        if win[ax] == (d0, rows) {
            // A later part may overwrite part of the scan's region.
            if overwritten_after(prog, parts, k, r) {
                return None;
            }
            return Some(Instr::Copy {
                a: Operand::Slot(s),
                out,
            });
        }
        if win[ax] != (d0 + 1, rows) || overwritten_after(prog, parts, k, r) {
            continue;
        }
        // The row past the scan: the part that writes it last.
        let (last, lr) = *parts.iter().rev().find(|&&(_, q)| {
            let q = &prog.regions[q as usize];
            q.dest_lo[ax] <= d0 + rows && d0 + rows < q.dest_lo[ax] + q.shape[ax]
        })?;
        let lr = &prog.regions[lr as usize];
        if lr.shape[ax] != 1
            || lr.dest_lo[ax] != d0 + rows
            || (0..nd).any(|d| d != ax && (lr.dest_lo[d], lr.shape[d]) != win[d])
        {
            return None;
        }
        let ends_on = match (reverse, inclusive) {
            (false, false) => is_total(prog, defs, last, sop, init, src, ax),
            (true, true) => matches!(last, Operand::Lit(x) if x.to_bits() == init.to_bits()),
            _ => false,
        };
        if !ends_on {
            return None;
        }
        return Some(Instr::Scan {
            op: sop,
            init,
            src,
            axis,
            inclusive: !inclusive,
            reverse,
            src_shape: src_shape.clone(),
            out,
        });
    }
    None
}

/// Whether a part after `parts[k]` writes into region `r`.
fn overwritten_after(
    prog: &TapeProgram,
    parts: &[(Operand, u32)],
    k: usize,
    r: &RegionSpec,
) -> bool {
    parts[k + 1..].iter().any(|&(_, q)| {
        let q = &prog.regions[q as usize];
        (0..r.shape.len()).all(|d| {
            q.dest_lo[d] < r.dest_lo[d] + r.shape[d] && r.dest_lo[d] < q.dest_lo[d] + q.shape[d]
        })
    })
}

/// Whether `v` is the column total of `src` along `ax`: a `Reduce` of a term
/// with `src`'s value over that one axis, ascending, with the scan's kernel
/// and identity — a scalar for a one-axis box, else read through the gather
/// that places the lower-rank total on its one-row region.
fn is_total(
    prog: &TapeProgram,
    defs: &[Option<usize>],
    v: Operand,
    op: BinCode,
    init: f64,
    src: SrcRef,
    ax: usize,
) -> bool {
    let Operand::Slot(g) = v else {
        return false;
    };
    let Some(gi) = defs[g as usize] else {
        return false;
    };
    let t = match prog.instrs[gi] {
        Instr::Gather {
            src: SrcRef::Slot(t),
            plan,
            ..
        } => {
            let p = &prog.plans[plan as usize];
            // The total's axes in order, the singleton scanned axis broadcast.
            let placed = p.fixed_desc.is_empty()
                && p.mapped.len() == p.shape.len()
                && p.mapped.iter().enumerate().all(|(d, &m)| m == (d != ax))
                && p.perm.iter().enumerate().all(|(k, &d)| k == d)
                && p.segs
                    .iter()
                    .enumerate()
                    .all(|(d, s)| matches!(s[..], [(0, len, 0)] if len == p.shape[d]))
                && p.src_shape.len() + 1 == p.shape.len();
            if !placed {
                return false;
            }
            t
        }
        Instr::Reduce { .. } if prog.slots[g as usize].scalar => g,
        _ => return false,
    };
    let Some(ti) = defs[t as usize] else {
        return false;
    };
    let Instr::Reduce {
        op: rop,
        init: rinit,
        src: rsrc,
        ref axes,
        reverse: false,
        ..
    } = prog.instrs[ti]
    else {
        return false;
    };
    rop == op
        && rinit.to_bits() == init.to_bits()
        && axes[..] == [ax as u8]
        && same_src(prog, defs, rsrc, src, 8)
}

/// Whether two sources hold the same values: the same source, or slots
/// defined by the same elementwise kernels over sources that are.
fn same_src(prog: &TapeProgram, defs: &[Option<usize>], a: SrcRef, b: SrcRef, depth: u32) -> bool {
    match (a, b) {
        (SrcRef::State(x), SrcRef::State(y)) => x == y,
        (SrcRef::Slot(x), SrcRef::Slot(y)) => same_slot(prog, defs, x, y, depth),
        _ => false,
    }
}

fn same_slot(prog: &TapeProgram, defs: &[Option<usize>], x: SlotId, y: SlotId, depth: u32) -> bool {
    if x == y {
        return true;
    }
    let (sx, sy) = (&prog.slots[x as usize], &prog.slots[y as usize]);
    if depth == 0 || sx.shape != sy.shape || sx.scalar != sy.scalar {
        return false;
    }
    let (Some(ix), Some(iy)) = (defs[x as usize], defs[y as usize]) else {
        return false;
    };
    if prog.precision.get(ix) != prog.precision.get(iy) {
        return false;
    }
    let same_op = |a: Operand, b: Operand| match (a, b) {
        (Operand::Slot(p), Operand::Slot(q)) => same_slot(prog, defs, p, q, depth - 1),
        (Operand::Lit(p), Operand::Lit(q)) => p.to_bits() == q.to_bits(),
        (Operand::Param(p), Operand::Param(q)) => p == q,
        (Operand::State(p), Operand::State(q)) => p == q,
        (Operand::Time, Operand::Time) => true,
        _ => false,
    };
    match (&prog.instrs[ix], &prog.instrs[iy]) {
        (
            Instr::Bin {
                op: o1,
                a: a1,
                b: b1,
                ..
            },
            Instr::Bin {
                op: o2,
                a: a2,
                b: b2,
                ..
            },
        ) => o1 == o2 && same_op(*a1, *a2) && same_op(*b1, *b2),
        (Instr::Un { op: o1, a: a1, .. }, Instr::Un { op: o2, a: a2, .. }) => {
            o1 == o2 && same_op(*a1, *a2)
        }
        (Instr::Neg { a: a1, .. }, Instr::Neg { a: a2, .. }) => same_op(*a1, *a2),
        (
            Instr::Gather {
                src: s1, plan: p1, ..
            },
            Instr::Gather {
                src: s2, plan: p2, ..
            },
        ) => {
            let (p1, p2) = (&prog.plans[*p1 as usize], &prog.plans[*p2 as usize]);
            same_plan(p1, p2) && same_src(prog, defs, *s1, *s2, depth - 1)
        }
        _ => false,
    }
}

fn same_plan(a: &GatherPlan, b: &GatherPlan) -> bool {
    a.fixed_desc == b.fixed_desc
        && a.perm == b.perm
        && a.mapped == b.mapped
        && a.segs == b.segs
        && a.shape == b.shape
        && a.origin == b.origin
        && a.src_shape == b.src_shape
        && a.src_origin == b.src_origin
}
