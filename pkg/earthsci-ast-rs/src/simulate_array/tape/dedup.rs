//! One copy of each repeated pure build-time instruction.
//!
//! Value numbering shares a sub-tree within the scope it is lowered in, so an
//! expression a template reads at several boxes (a polygon's fan area read by
//! the overlap test, by each clip edge and by the sum over vertices) is
//! lowered once per box and its build-time instructions repeat: the same
//! reduction of the same source, the same ramp, the same gather. In the CONST
//! section such a repeat recomputes a value already held, over a box as large
//! as the data. This pass keeps the first of each, renames every read of a
//! repeat's slot to the first's, and drops the repeat.
//!
//! Two instructions are the same when they have the same kind, operation,
//! table contents (gather plan, data-gather spec) and output box, and read the
//! same operands (a literal by its bits), after earlier repeats are renamed.
//! Each is a pure map of its operands that cannot fault, so the first computes
//! the repeat's value bit for bit and the program's values do not change.
//! Only straight-line CONST instructions take part (none inside a conditional
//! region), each defining a slot nothing else defines.

use super::ir::*;
use rustc_hash::FxHashMap;
use std::fmt::Write;

/// An operand's identity, slots after renaming.
fn opk(o: &Operand, canon: &[SlotId]) -> OperandKey {
    match o {
        Operand::Slot(s) => OperandKey::Slot(canon[*s as usize]),
        other => other.key(),
    }
}

fn srck(k: &mut String, s: &SrcRef, canon: &[SlotId]) {
    let _ = write!(k, "{:?},", opk(&Operand::from(*s), canon));
}

/// The identity of `ins` at `pc`, or `None` for an instruction that does not
/// take part.
pub(super) fn key(prog: &TapeProgram, pc: usize, ins: &Instr, canon: &[SlotId]) -> Option<String> {
    let out = ins.out()?;
    let d = &prog.tables.slots[out as usize];
    let mut k = format!(
        "{:?}|{:?}|{}|{:?}|",
        &d.shape[..],
        &d.origin[..],
        d.scalar,
        prog.precision.get(pc)
    );
    if let Some(ew) = ins.as_elementwise() {
        let _ = write!(k, "{:?}", ew.key(|o| opk(o, canon)));
        return Some(k);
    }
    match ins {
        Instr::Ramp { axis, lo, .. } => {
            let _ = write!(k, "Ramp{axis},{lo}");
        }
        Instr::LoadElem { src, idx, .. } => {
            let _ = write!(k, "Load{idx:?}:");
            srck(&mut k, src, canon);
        }
        Instr::Gather { src, plan, .. } => {
            let _ = write!(k, "Gather{:?}:", prog.tables.plans[*plan as usize]);
            srck(&mut k, src, canon);
        }
        Instr::Reduce {
            op,
            init,
            src,
            axes,
            reverse,
            src_shape,
            ..
        } => {
            let _ = write!(
                k,
                "Reduce{op:?},{:x},{axes:?},{reverse},{:?}:",
                init.to_bits(),
                &src_shape[..]
            );
            srck(&mut k, src, canon);
        }
        Instr::Count {
            rel,
            axis,
            lo,
            n,
            sorted,
            x,
            ..
        } => {
            let _ = write!(k, "Count{rel:?},{lo},{n},{sorted}:");
            srck(&mut k, axis, canon);
            let _ = write!(k, "{:?},", opk(x, canon));
        }
        Instr::DataGather {
            src,
            spec,
            faults: false,
            ..
        } => {
            let sp = &prog.tables.data_gathers[*spec as usize];
            let _ = write!(
                k,
                "DataGather{:?},{:?},{:?},{}:",
                sp.kind,
                &sp.src_shape[..],
                &sp.shape[..],
                sp.reversed
            );
            srck(&mut k, src, canon);
            for s in &sp.subs {
                let _ = write!(k, "{:?},", opk(s, canon));
            }
        }
        _ => return None,
    }
    Some(k)
}

/// Drop every repeated pure CONST instruction (module docs). Runs on the
/// program as lowered, before any pass that reorders or fuses it.
pub(super) fn dedup_const(prog: &mut TapeProgram) {
    let nc = prog.n_const as usize;
    if nc < 2 {
        return;
    }
    let n_slots = prog.tables.slots.len();
    let guarded = prog.guarded_positions();
    // Slots defined more than once (a branch join) never take part.
    let n_defs = DefUse::of(prog).n_defs;
    let mut canon: Vec<SlotId> = (0..n_slots as SlotId).collect();
    let mut seen: FxHashMap<String, SlotId> = FxHashMap::default();
    let mut repeats: Vec<(std::ops::Range<usize>, Vec<(Instr, usize)>)> = Vec::new();
    for pc in 0..nc {
        if guarded[pc] {
            continue;
        }
        let ins = &prog.instrs[pc];
        let Some(out) = ins.out() else { continue };
        if n_defs[out as usize] != 1 {
            continue;
        }
        let Some(k) = key(prog, pc, ins, &canon) else {
            continue;
        };
        match seen.get(&k) {
            Some(&first) => {
                canon[out as usize] = first;
                repeats.push((pc..pc + 1, Vec::new()));
            }
            None => {
                seen.insert(k, out);
            }
        }
    }
    if repeats.is_empty() {
        return;
    }
    // Every read of a repeat reads its first instead, which holds the same
    // value; the repeat is then dropped.
    let (instrs, mut tables) = prog.instrs_and_tables_mut();
    for ins in instrs.iter_mut() {
        ins.for_each_read_mut(&mut tables, |s| *s = canon[*s as usize]);
    }
    for (_, s) in prog.exports.iter_mut() {
        *s = canon[*s as usize];
    }
    prog.splice(repeats);
}
