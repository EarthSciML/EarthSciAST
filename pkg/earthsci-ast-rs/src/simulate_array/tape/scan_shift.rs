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
//! the read into a [`Instr::Copy`] of `S`, the exclusive scan combined with
//! the term (`fold(t[..=k])` is `fold(t[..k]) ⊕ t[k]`, the kernel the scan
//! itself applies), or, for the reverse inclusive scan, a copy of the
//! reverse exclusive scan, the inclusive one then being split into that scan
//! and its combine with the term. Either way one scan remains; the assembly
//! has no reader on the derivative path, and the scan and the consumer
//! share one box and fuse into one pass.

use super::ir::*;
use crate::simulate_array::BinCode;
use smallvec::SmallVec;

/// Rewrite every read the scan answers (module docs).
pub(super) fn rewrite_scan_makearray_reads(prog: &mut TapeProgram) {
    // A per-variable element type rounds each kernel at its own precision;
    // keep those programs as written.
    if !prog.precision.is_empty() {
        return;
    }
    let defs = single_defs(prog);
    let guarded = guarded_positions(prog);
    // Reverse inclusive scans to split into the exclusive scan and the
    // combine with the term: scan position -> the exclusive scan's slot.
    let mut splits: std::collections::BTreeMap<usize, SlotId> = Default::default();
    for i in 0..prog.instrs.len() {
        let Instr::Gather {
            src: SrcRef::Slot(a),
            plan,
            out,
        } = prog.instrs[i]
        else {
            continue;
        };
        match answer(prog, &defs, a, plan, out) {
            Some(Answer::Read(new)) => prog.instrs[i] = new,
            Some(Answer::ReverseExclusive(pc)) if !guarded[pc] => {
                let e = match splits.get(&pc) {
                    Some(&e) => e,
                    None => {
                        let out = prog.instrs[pc].out().expect("a scan defines its slot");
                        let desc = prog.slots[out as usize].clone();
                        let e = prog.slots.len() as SlotId;
                        prog.slots.push(desc);
                        splits.insert(pc, e);
                        e
                    }
                };
                prog.instrs[i] = Instr::Copy {
                    a: Operand::Slot(e),
                    out,
                };
            }
            _ => {}
        }
    }
    if !splits.is_empty() {
        split_reverse_inclusive(prog, &splits);
    }
}

/// What a read the scan answers becomes.
enum Answer {
    /// This instruction in the gather's place.
    Read(Instr),
    /// A copy of the reverse EXCLUSIVE scan of the reverse inclusive scan
    /// at this position, which is split to define it.
    ReverseExclusive(usize),
}

/// Positions inside a conditional region or a recurrence body.
fn guarded_positions(prog: &TapeProgram) -> Vec<bool> {
    let mut guarded = vec![false; prog.instrs.len()];
    for (i, ins) in prog.instrs.iter().enumerate() {
        let len = match ins {
            Instr::JmpIfZero {
                n_true, n_false, ..
            } => (*n_true + *n_false) as usize,
            Instr::Sweep { spec } => prog.sweeps[*spec as usize].body_len as usize,
            _ => 0,
        };
        for g in guarded.iter_mut().skip(i + 1).take(len) {
            *g = true;
        }
    }
    guarded
}

/// Split each reverse inclusive scan in `splits` into the reverse exclusive
/// scan (into its new slot) and the combine of that with the term (into the
/// scan's own slot): the inclusive scan's row `k` is the exclusive one's row
/// `k` combined with `t[k]`, the kernel the scan applies after writing it.
fn split_reverse_inclusive(
    prog: &mut TapeProgram,
    splits: &std::collections::BTreeMap<usize, SlotId>,
) {
    let n = prog.instrs.len();
    let mut instrs = Vec::with_capacity(n + splits.len());
    let mut prov = Vec::with_capacity(n + splits.len());
    let (mut n_const, mut n_segment) = (prog.n_const, prog.n_segment);
    for k in 0..n {
        let Some(&e) = splits.get(&k) else {
            instrs.push(prog.instrs[k].clone());
            prov.push(prog.provenance[k]);
            continue;
        };
        let Instr::Scan {
            op,
            init,
            src,
            axis,
            reverse,
            ref src_shape,
            out,
            ..
        } = prog.instrs[k]
        else {
            unreachable!("a split position holds a scan");
        };
        let term = match src {
            SrcRef::Slot(t) => Operand::Slot(t),
            SrcRef::State(x) => Operand::State(x),
        };
        instrs.push(Instr::Scan {
            op,
            init,
            src,
            axis,
            inclusive: false,
            reverse,
            src_shape: src_shape.clone(),
            out: e,
        });
        instrs.push(Instr::Bin {
            op,
            a: Operand::Slot(e),
            b: term,
            out,
        });
        prov.extend([prog.provenance[k]; 2]);
        match prog.section_of(k) {
            Cadence::Const => n_const += 1,
            Cadence::Segment => n_segment += 1,
            Cadence::Continuous => {}
        }
    }
    prog.instrs = instrs;
    prog.provenance = prov;
    prog.n_const = n_const;
    prog.n_segment = n_segment;
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
) -> Option<Answer> {
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
            return Some(Answer::Read(Instr::Copy {
                a: Operand::Slot(s),
                out,
            }));
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
        // The forward inclusive scan's row `k` is the exclusive one's row
        // `k` combined with the term: the kernel the scan applies after
        // writing it.
        if !reverse {
            let term = match src {
                SrcRef::Slot(t) => Operand::Slot(t),
                SrcRef::State(x) => Operand::State(x),
            };
            return Some(Answer::Read(Instr::Bin {
                op: sop,
                a: Operand::Slot(s),
                b: term,
                out,
            }));
        }
        return defs[s as usize].map(Answer::ReverseExclusive);
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
