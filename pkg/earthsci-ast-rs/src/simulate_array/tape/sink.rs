//! A broadcast of a build-time value moves to where the call reads it.
//!
//! A CONST value read over a larger box (a layer thickness `dz[l]` over
//! every column of `[l, c]`) is lowered as a gather that broadcasts it, and
//! the gather, reading only CONST data, is placed in the CONST section: the
//! broadcast box is materialized once and every call then streams it, an
//! array the size of the state, from memory. Moved next to its first reader
//! in the CONTINUOUS section, the gather folds into the reader's fused group
//! as an input that reads the small source directly (stride 0 along the
//! broadcast axes), so the call reads the source and not the box.
//!
//! The derivative path and the output-only work after it (`prune`) fuse
//! apart, so a broadcast both read gets a copy in each, the output-only
//! readers renamed to the second. Only a gather every reader of which is in
//! the CONTINUOUS section moves, and never into or out of a conditional
//! region or a recurrence body, whose instruction counts are fixed. Every
//! reader must also be arithmetic over the broadcast box, whose group then
//! takes the gather in: a reader that reads the box whole (a `DyWrite`, a
//! reduction, a scan, a table read) would have the gather write the box on
//! every call instead of once. The values are the same; only where the
//! gather runs changes.

use super::ir::*;

/// How much larger the broadcast box must be than its source to move.
const MIN_BROADCAST_RATIO: usize = 4;

/// Move every CONST or SEGMENT broadcast gather only the CONTINUOUS section
/// reads, and only by readers whose fused group takes it in, to just before
/// its first reader, one copy for the derivative path
/// and one for the output-only work (module docs). Runs after
/// [`super::prune::split_output_only`], whose split it keeps.
pub(super) fn sink_const_broadcasts(prog: &mut TapeProgram) {
    let cont = prog.section_range(Cadence::Continuous);
    if cont.is_empty() || cont.start == 0 {
        return;
    }
    let bound = cont.start + prog.n_rhs as usize;
    let n = prog.instrs.len();
    let guarded = prog.guarded_positions();
    let chained = super::fuse::chained_tuple_instrs(prog);
    let du = DefUse::of(prog);
    let readers = &du.readers;
    let exported: std::collections::HashSet<SlotId> =
        prog.exports.iter().map(|(_, s)| *s).collect();
    // `place[k]`: the gathers to place just before instruction `k`, each
    // with the slot it defines there.
    let mut place: Vec<Vec<(usize, SlotId)>> = vec![Vec::new(); n];
    let mut moved = vec![false; n];
    let mut renames: Vec<(usize, SlotId, SlotId)> = Vec::new();
    for i in 0..cont.start {
        let Instr::Gather {
            src: SrcRef::Slot(src),
            plan,
            out,
        } = prog.instrs[i]
        else {
            continue;
        };
        let p = &prog.plans[plan as usize];
        let (o, s) = (out as usize, src as usize);
        let rs = &readers[o];
        if rs.is_empty()
            || guarded[i]
            || rs
                .iter()
                .any(|&r| (r as usize) < cont.start || guarded[r as usize])
            || exported.contains(&out)
            || p.mapped.iter().all(|&m| m)
            || prog.slots[o].elems() < MIN_BROADCAST_RATIO * prog.slots[s].elems()
            || !super::fuse::sunk_gather_fuses(prog, &chained, i, rs)
        {
            continue;
        }
        let (head, tail): (Vec<usize>, Vec<usize>) =
            rs.iter().map(|&r| r as usize).partition(|&r| r < bound);
        moved[i] = true;
        match (head.first(), tail.first()) {
            (Some(&h), Some(&t)) => {
                place[h].push((i, out));
                let o2 = prog.slots.len() as SlotId;
                prog.slots.push(prog.slots[o].clone());
                place[t].push((i, o2));
                renames.extend(tail.iter().map(|&r| (r, out, o2)));
            }
            (Some(&h), None) => place[h].push((i, out)),
            (None, Some(&t)) => place[t].push((i, out)),
            (None, None) => unreachable!("a moved gather has a reader"),
        }
    }
    if !moved.iter().any(|&m| m) {
        return;
    }
    {
        let (instrs, mut tables) = prog.instrs_and_tables_mut();
        for (r, from, to) in renames {
            instrs[r].for_each_read_mut(&mut tables, |s| {
                if *s == from {
                    *s = to;
                }
            });
        }
    }
    let mut edits: Vec<(std::ops::Range<usize>, Vec<(Instr, usize)>)> = Vec::new();
    for k in 0..n {
        if place[k].is_empty() && !moved[k] {
            continue;
        }
        let mut body = Vec::with_capacity(place[k].len() + 1);
        for &(i, out) in &place[k] {
            let mut g = prog.instrs[i].clone();
            if let Instr::Gather { out: o, .. } = &mut g {
                *o = out;
            }
            body.push((g, i));
            prog.slots[out as usize].cadence = Cadence::Continuous;
        }
        if !moved[k] {
            body.push((prog.instrs[k].clone(), k));
        }
        edits.push((k..k + 1, body));
    }
    prog.splice(edits);
}
