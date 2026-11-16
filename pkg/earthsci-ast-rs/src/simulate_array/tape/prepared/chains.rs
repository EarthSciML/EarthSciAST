//! Segmented-reduction chains: the runs of the continuous section that
//! split by the output cells of one tuple-list contraction
//! ([`Instr::SegReduce`]), found once per program. The executor
//! (`exec/chain.rs`) runs each chain split across the pool in one dispatch.

use super::super::super::BinCode;
use super::super::ir::*;

/// A run of instructions `[start, end)` of the continuous section that
/// splits by the output cells of the segmented reduction at `seg`: the
/// tuple instructions `[start, seg)`, the reduction, and optionally the
/// fused group right after it.
pub(in crate::simulate_array::tape) struct SegChain {
    pub(in crate::simulate_array::tape) start: usize,
    pub(in crate::simulate_array::tape) end: usize,
    pub(in crate::simulate_array::tape) seg: usize,
    /// The fused group at `seg + 1`, run over the same cells.
    pub(in crate::simulate_array::tape) fused: Option<u32>,
    /// Output cells of the reduction.
    pub(in crate::simulate_array::tape) n_out: usize,
    /// The most tuples one output cell folds.
    pub(in crate::simulate_array::tape) max_row: usize,
    /// Estimated element-operations of the whole chain.
    pub(in crate::simulate_array::tape) work: usize,
    /// Whether nothing outside the chain reads the tuple slots its tuple
    /// instructions define, so a pass that folds them as it goes need not
    /// store them.
    pub(in crate::simulate_array::tape) private: bool,
    /// The chain's position in [`seg_chains`]' list.
    pub(in crate::simulate_array::tape) id: usize,
    /// How the chain's tuples drop to the unmasked ones, when it can.
    pub(in crate::simulate_array::tape) compact: Option<CompactPlan>,
}

/// A chain that is a gather `t1 = src[pos]` and a product `t2 = t1 * w`
/// summed under a mask the CONST or SEGMENT section defines, with `w` a
/// scalar or a tuple slot those sections define too. Which tuples the mask
/// admits, and their weights, change only when those sections re-run, so the
/// admitted tuples' positions and weights are gathered into a table of their
/// own then (see [`refill_compact`]) and every call folds only those.
#[derive(Clone, Copy, Debug)]
pub(in crate::simulate_array::tape) struct CompactPlan {
    pub(in crate::simulate_array::tape) mask: SlotId,
    /// The gather's position table.
    pub(in crate::simulate_array::tape) table: u32,
    /// The product's other operand, when it is a tuple slot.
    pub(in crate::simulate_array::tape) w: Option<SlotId>,
}

/// How a slot is addressed by the chain's workers.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Class {
    /// At the tuple positions of the worker's own cells.
    Tuple,
    /// At the worker's own output cells.
    Cell,
    /// At positions no worker owns (a gather source, a scalar).
    Any,
}

/// Every slab range the chain touches: `(slot, class, written)`.
type Touches = Vec<(SlotId, Class, bool)>;

/// The chains of `prog`'s continuous section, in program order. A
/// segmented reduction whose surroundings do not meet the conditions below
/// has none and runs instruction by instruction.
///
/// `slot_off` is the program's own slot layout and `guarded` its
/// [`TapeProgram::guarded_positions`]: a chain never spans a branch or a
/// recurrence body (the loop may skip or repeat them).
pub(in crate::simulate_array::tape) fn seg_chains(
    prog: &TapeProgram,
    slot_off: &[usize],
    guarded: &[bool],
) -> Vec<SegChain> {
    let cont = (prog.n_const + prog.n_segment) as usize;
    // Slots the continuous section writes: a compacted table may only copy
    // values that hold for every call between two primes.
    let tables = prog.slot_tables();
    let mut per_call = vec![false; prog.tables.slots.len()];
    for ins in &prog.instrs[cont..] {
        ins.for_each_def(&tables, |s| per_call[s as usize] = true);
    }
    // Per slot, how many reads every instruction makes of it, and whether it
    // is exported: what decides, per chain, whether anything outside it
    // reads the tuple slots it defines.
    let mut reads = vec![0u32; prog.tables.slots.len()];
    for ins in &prog.instrs {
        ins.for_each_read(&tables, |s| reads[s as usize] += 1);
    }
    let mut exported = vec![false; prog.tables.slots.len()];
    for (_, s) in &prog.exports {
        exported[*s as usize] = true;
    }
    let readers = Readers {
        reads: &reads,
        exported: &exported,
    };
    let mut out = Vec::new();
    for seg in cont..prog.instrs.len() {
        if let Some(mut ch) = plan_one(prog, slot_off, cont, seg, guarded, &readers) {
            ch.id = out.len();
            ch.compact = compact_plan(prog, &ch, &per_call);
            out.push(ch);
        }
    }
    out
}

/// The compaction of chain `ch`, if it is a masked sum of gathered products
/// whose mask and weights only the CONST and SEGMENT sections write.
fn compact_plan(prog: &TapeProgram, ch: &SegChain, per_call: &[bool]) -> Option<CompactPlan> {
    let Instr::SegReduce {
        op: BinCode::Add,
        src,
        mask: Some(mask),
        ..
    } = &prog.instrs[ch.seg]
    else {
        return None;
    };
    let [
        Instr::TableGather { table, out: t1, .. },
        Instr::Bin {
            op: BinCode::Mul,
            a,
            b,
            out: t2,
        },
    ] = &prog.instrs[ch.start..ch.seg]
    else {
        return None;
    };
    if !ch.private || t2 != src || per_call[*mask as usize] {
        return None;
    }
    let is_t1 = |o: &Operand| matches!(o, Operand::Slot(s) if s == t1);
    let w = match (is_t1(a), is_t1(b)) {
        (true, false) => b,
        (false, true) => a,
        _ => return None,
    };
    let w = match w {
        Operand::Lit(_) | Operand::Param(_) | Operand::Time => None,
        Operand::Slot(s) if prog.tables.slots[*s as usize].scalar => None,
        Operand::Slot(s) if !per_call[*s as usize] => Some(*s),
        _ => return None,
    };
    Some(CompactPlan {
        mask: *mask,
        table: *table,
        w,
    })
}

/// Per slot, the reads the whole program makes of it and whether it is
/// exported (see [`seg_chains`]).
struct Readers<'a> {
    reads: &'a [u32],
    exported: &'a [bool],
}

fn plan_one(
    prog: &TapeProgram,
    slot_off: &[usize],
    cont: usize,
    seg: usize,
    guarded: &[bool],
    readers: &Readers,
) -> Option<SegChain> {
    let Instr::SegReduce {
        src,
        mask,
        table,
        out,
        ..
    } = &prog.instrs[seg]
    else {
        return None;
    };
    let rows = &prog.tables.seg_tables[*table as usize].rows;
    let n_out = rows.len().checked_sub(1)?;
    let n_pairs = *rows.last()? as usize;
    let odesc = &prog.tables.slots[*out as usize];
    if n_out < 2 || odesc.scalar || odesc.elems() != n_out {
        return None;
    }
    let tuple_slot = |s: SlotId| tuple_box(prog, s, n_pairs);
    let mut touches: Touches = vec![(*src, Class::Tuple, false), (*out, Class::Cell, true)];
    if !tuple_slot(*src) {
        return None;
    }
    if let Some(m) = mask {
        if !tuple_slot(*m) {
            return None;
        }
        touches.push((*m, Class::Tuple, false));
    }
    // The tuple instructions right before the reduction.
    let mut start = seg;
    while start > cont && !guarded[start - 1] {
        let mut t = Vec::new();
        if !tuple_instr(prog, &prog.instrs[start - 1], n_pairs, &mut t) {
            break;
        }
        touches.extend(t);
        start -= 1;
    }
    let mut work = n_pairs * (seg - start + 1);
    // The fused group right after it, over the same cells.
    let mut fused = None;
    if let Some(Instr::Fused { spec }) = prog.instrs.get(seg + 1)
        && !guarded[seg + 1]
    {
        let mut t = Vec::new();
        let fs = &prog.fused[*spec as usize];
        if cell_group(fs, n_out, &mut t) {
            touches.extend(t);
            fused = Some(*spec);
            work += n_out * (fs.micro.len() + fs.inputs.len() + fs.outputs.len() + 1);
        }
    }
    let end = seg + 1 + usize::from(fused.is_some());
    if guarded[start..end].iter().any(|&g| g)
        || (start..end).any(|pc| prog.precision.get(pc).is_some())
        || !disjoint(prog, slot_off, &touches)
    {
        return None;
    }
    // The tuple slots the chain defines, and whether anything but the chain
    // reads them.
    // They are private when every read of them is one the chain's own
    // instructions `[start, seg]` make.
    let tables = prog.slot_tables();
    let mut defs: Vec<SlotId> = Vec::new();
    for ins in &prog.instrs[start..seg] {
        ins.for_each_def(&tables, |s| defs.push(s));
    }
    let mut inside: Vec<(SlotId, u32)> = defs.iter().map(|&s| (s, 0)).collect();
    for ins in &prog.instrs[start..=seg] {
        ins.for_each_read(&tables, |s| {
            for (d, n) in inside.iter_mut() {
                if *d == s {
                    *n += 1;
                }
            }
        });
    }
    let private = inside
        .iter()
        .all(|&(s, n)| !readers.exported[s as usize] && readers.reads[s as usize] == n);
    let max_row = rows.windows(2).map(|r| (r[1] - r[0]) as usize).max();
    Some(SegChain {
        start,
        end,
        seg,
        fused,
        n_out,
        max_row: max_row.unwrap_or(0),
        work,
        private,
        id: 0,
        compact: None,
    })
}

/// Whether `ins` is elementwise over the tuple box of `n_pairs` (writing a
/// tuple slot from tuple slots, scalars and a gathered source), recording
/// what it touches.
fn tuple_instr(prog: &TapeProgram, ins: &Instr, n_pairs: usize, t: &mut Touches) -> bool {
    let tuple_slot = |s: SlotId| tuple_box(prog, s, n_pairs);
    let operand = |op: &Operand, t: &mut Touches| match op {
        Operand::Lit(_) | Operand::Param(_) | Operand::Time => true,
        Operand::State(ix) => {
            let sh = &prog.state_vars[*ix as usize].shape;
            sh.is_empty() || sh[..] == [n_pairs]
        }
        Operand::Slot(s) if prog.tables.slots[*s as usize].scalar => {
            t.push((*s, Class::Any, false));
            true
        }
        Operand::Slot(s) if tuple_slot(*s) => {
            t.push((*s, Class::Tuple, false));
            true
        }
        _ => false,
    };
    let out = match ins {
        Instr::TableGather { src, out, .. } => {
            match src {
                SrcRef::Slot(s) => t.push((*s, Class::Any, false)),
                SrcRef::State(_) => {}
            }
            *out
        }
        Instr::Bin { a, b, out, .. } => {
            if !(operand(a, t) && operand(b, t)) {
                return false;
            }
            *out
        }
        Instr::Un { a, out, .. } | Instr::Neg { a, out } => {
            if !operand(a, t) {
                return false;
            }
            *out
        }
        _ => return false,
    };
    if !tuple_slot(out) {
        return false;
    }
    t.push((out, Class::Tuple, true));
    true
}

/// Whether slot `s` is an array over the tuple box of `n_pairs`.
fn tuple_box(prog: &TapeProgram, s: SlotId, n_pairs: usize) -> bool {
    let d = &prog.tables.slots[s as usize];
    !d.scalar && d.shape[..] == [n_pairs]
}

/// Whether fused group `fs` runs over the reduction's `n_out` cells with
/// every read of a cell-box slot at the cell itself, recording what it
/// touches.
fn cell_group(fs: &FusedSpec, n_out: usize, t: &mut Touches) -> bool {
    if fs.n_elems() != n_out
        || fs.reduce.is_some()
        || fs.pre.is_some()
        || fs.interleave.is_some()
        || !fs.scan_fuse.is_empty()
        || fs.micro.iter().any(|m| matches!(m, MicroOp::Scan { .. }))
    {
        return false;
    }
    let mut aligned = vec![true; fs.inputs.len()];
    for (i, inp) in fs.inputs.iter().enumerate() {
        aligned[i] = inp.gather.is_none() && inp.index.is_none() && inp.src_shape == fs.shape;
        if let Some(s) = inp.shifted_ix {
            aligned[i] &= inp.elem_stride == 1;
            let s = s as usize;
            fs.schedule.for_each_run(|r| {
                aligned[i] &= r.in_off.get(s).is_some_and(|&o| o == r.out_off as i64);
            });
        }
    }
    for (inp, al) in fs.inputs.iter().zip(aligned) {
        if let SrcRef::Slot(s) = inp.src {
            t.push((s, if al { Class::Cell } else { Class::Any }, false));
        }
    }
    for &(_, s) in &fs.outputs {
        t.push((s, Class::Cell, true));
    }
    true
}

/// Whether no worker can write slab storage another worker reads or writes:
/// two slots the chain touches that share storage, one of them written,
/// must be the same range addressed the same way (an in-place reuse), and
/// a slot written by the chain is never read at positions no worker owns.
fn disjoint(prog: &TapeProgram, slot_off: &[usize], touches: &Touches) -> bool {
    let range = |s: SlotId| {
        let off = slot_off[s as usize];
        (off != usize::MAX).then(|| (off, off + prog.tables.slots[s as usize].elems().max(1)))
    };
    for (i, &(s, cs, ws)) in touches.iter().enumerate() {
        let Some((a0, a1)) = range(s) else { continue };
        for &(r, cr, wr) in &touches[i + 1..] {
            if !(ws || wr) {
                continue;
            }
            let Some((b0, b1)) = range(r) else { continue };
            if a0 >= b1 || b0 >= a1 {
                continue;
            }
            if (a0, a1) != (b0, b1) || cs != cr || cs == Class::Any {
                return false;
            }
        }
    }
    true
}
