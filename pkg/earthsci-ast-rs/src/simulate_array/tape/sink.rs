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
//! readers renamed to the second; a gather whose output-only readers cannot
//! be renamed stays where it is. Only a gather every reader of which is in
//! the CONTINUOUS section moves, and never into or out of a conditional
//! region or a recurrence body, whose instruction counts are fixed. The
//! values are the same; only where the gather runs changes.

use super::ir::*;

/// How much larger the broadcast box must be than its source to move.
const MIN_BROADCAST_RATIO: usize = 4;

/// Move every CONST or SEGMENT broadcast gather only the CONTINUOUS section
/// reads to just before its first reader, one copy for the derivative path
/// and one for the output-only work (module docs). Runs after
/// [`super::prune::split_output_only`], whose split it keeps.
pub(super) fn sink_const_broadcasts(prog: &mut TapeProgram) {
    let cont = prog.section_range(Cadence::Continuous);
    if cont.is_empty() || cont.start == 0 {
        return;
    }
    let bound = cont.start + prog.n_rhs as usize;
    let n = prog.instrs.len();
    let tables = prog.tables();
    let guarded = prog.guarded_positions();
    let mut readers: Vec<Vec<usize>> = vec![Vec::new(); prog.slots.len()];
    for (i, ins) in prog.instrs.iter().enumerate() {
        ins.for_each_read(&tables, |s| {
            let r = &mut readers[s as usize];
            if r.last() != Some(&i) {
                r.push(i);
            }
        });
    }
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
            || rs.iter().any(|&r| r < cont.start || guarded[r])
            || exported.contains(&out)
            || p.mapped.iter().all(|&m| m)
            || prog.slots[o].elems() < MIN_BROADCAST_RATIO * prog.slots[s].elems()
        {
            continue;
        }
        let (head, tail): (Vec<usize>, Vec<usize>) = rs.iter().partition(|&&r| r < bound);
        if !head.is_empty() && !tail.iter().all(|&r| renamable(&prog.instrs[r])) {
            continue;
        }
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
    for (r, from, to) in renames {
        rename_reads(&mut prog.instrs[r], from, to);
    }
    let mut instrs = Vec::with_capacity(n);
    let mut prov = Vec::with_capacity(n);
    let keep_prec = !prog.precision.is_empty();
    let mut prec = Vec::with_capacity(if keep_prec { n } else { 0 });
    let (mut n_const, mut n_segment, mut n_rhs) = (prog.n_const, prog.n_segment, prog.n_rhs);
    for k in 0..n {
        for &(i, out) in &place[k] {
            let mut g = prog.instrs[i].clone();
            if let Instr::Gather { out: o, .. } = &mut g {
                *o = out;
            }
            instrs.push(g);
            prov.push(prog.provenance[i]);
            if keep_prec {
                prec.push(prog.precision[i]);
            }
            prog.slots[out as usize].cadence = Cadence::Continuous;
            if k < bound {
                n_rhs += 1;
            }
        }
        if moved[k] {
            match prog.section_of(k) {
                Cadence::Const => n_const -= 1,
                Cadence::Segment => n_segment -= 1,
                Cadence::Continuous => {}
            }
            continue;
        }
        instrs.push(prog.instrs[k].clone());
        prov.push(prog.provenance[k]);
        if keep_prec {
            prec.push(prog.precision[k]);
        }
    }
    prog.instrs = instrs;
    prog.provenance = prov;
    if keep_prec {
        prog.precision = prec;
    }
    prog.n_const = n_const;
    prog.n_segment = n_segment;
    prog.n_rhs = n_rhs;
}

/// Whether [`rename_reads`] can rename every slot `ins` reads.
fn renamable(ins: &Instr) -> bool {
    matches!(
        ins,
        Instr::Bin { .. } | Instr::Un { .. } | Instr::Neg { .. } | Instr::Copy { .. }
    )
}

/// Make `ins` read `to` wherever it reads `from` (an instruction
/// [`renamable`] admits).
fn rename_reads(ins: &mut Instr, from: SlotId, to: SlotId) {
    let swap = |op: &mut Operand| {
        if *op == Operand::Slot(from) {
            *op = Operand::Slot(to);
        }
    };
    match ins {
        Instr::Bin { a, b, .. } => {
            swap(a);
            swap(b);
        }
        Instr::Un { a, .. } | Instr::Neg { a, .. } | Instr::Copy { a, .. } => swap(a),
        _ => unreachable!("only renamable instructions are renamed"),
    }
}
