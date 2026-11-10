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
//! region), each defining a slot nothing else defines; a repeat is dropped
//! only when every instruction that reads it can be renamed.

use super::ir::*;
use rustc_hash::FxHashMap;
use std::fmt::Write;

/// An operand, literals by their bits, slots after renaming.
fn opk(k: &mut String, o: &Operand, canon: &[SlotId]) {
    match o {
        Operand::Lit(v) => {
            let _ = write!(k, "L{:x},", v.to_bits());
        }
        Operand::Slot(s) => {
            let _ = write!(k, "S{},", canon[*s as usize]);
        }
        other => {
            let _ = write!(k, "{other:?},");
        }
    }
}

fn srck(k: &mut String, s: &SrcRef, canon: &[SlotId]) {
    match s {
        SrcRef::Slot(s) => {
            let _ = write!(k, "S{},", canon[*s as usize]);
        }
        other => {
            let _ = write!(k, "{other:?},");
        }
    }
}

/// The identity of `ins` at `pc`, or `None` for an instruction that does not
/// take part.
pub(super) fn key(prog: &TapeProgram, pc: usize, ins: &Instr, canon: &[SlotId]) -> Option<String> {
    let out = ins.out()?;
    let d = &prog.slots[out as usize];
    let mut k = format!(
        "{:?}|{:?}|{}|{:?}|",
        &d.shape[..],
        &d.origin[..],
        d.scalar,
        prog.precision.get(pc)
    );
    match ins {
        Instr::Bin { op, a, b, .. } => {
            let _ = write!(k, "Bin{op:?}:");
            opk(&mut k, a, canon);
            opk(&mut k, b, canon);
        }
        Instr::Un { op, a, .. } => {
            let _ = write!(k, "Un{op:?}:");
            opk(&mut k, a, canon);
        }
        Instr::Neg { a, .. } => {
            k.push_str("Neg:");
            opk(&mut k, a, canon);
        }
        Instr::Select { cond, a, b, .. } => {
            k.push_str("Sel:");
            opk(&mut k, cond, canon);
            opk(&mut k, a, canon);
            opk(&mut k, b, canon);
        }
        Instr::Fill { v, .. } => {
            k.push_str("Fill:");
            opk(&mut k, v, canon);
        }
        Instr::Ramp { axis, lo, .. } => {
            let _ = write!(k, "Ramp{axis},{lo}");
        }
        Instr::LoadElem { src, idx, .. } => {
            let _ = write!(k, "Load{idx:?}:");
            srck(&mut k, src, canon);
        }
        Instr::Gather { src, plan, .. } => {
            let _ = write!(k, "Gather{:?}:", prog.plans[*plan as usize]);
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
            opk(&mut k, x, canon);
        }
        Instr::DataGather {
            src,
            spec,
            faults: false,
            ..
        } => {
            let sp = &prog.data_gathers[*spec as usize];
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
                opk(&mut k, s, canon);
            }
        }
        _ => return None,
    }
    Some(k)
}

/// Rename `ins`'s reads through `canon`; `false` (and nothing changed) for an
/// instruction whose reads this pass cannot rename.
fn rename(
    ins: &mut Instr,
    dg: &mut [DataGatherSpec],
    dyw: &mut [DyWrite],
    canon: &[SlotId],
) -> bool {
    let op = |o: &mut Operand| {
        if let Operand::Slot(s) = o {
            *s = canon[*s as usize];
        }
    };
    let src = |s: &mut SrcRef| {
        if let SrcRef::Slot(x) = s {
            *x = canon[*x as usize];
        }
    };
    match ins {
        Instr::Bin { a, b, .. } => {
            op(a);
            op(b);
        }
        Instr::Un { a, .. }
        | Instr::Neg { a, .. }
        | Instr::Calendar { a, .. }
        | Instr::Copy { a, .. }
        | Instr::Fill { v: a, .. }
        | Instr::JmpIfZero { cond: a, .. } => op(a),
        Instr::Select { cond, a, b, .. } => {
            op(cond);
            op(a);
            op(b);
        }
        Instr::Gather { src: s, .. }
        | Instr::LoadElem { src: s, .. }
        | Instr::Reduce { src: s, .. }
        | Instr::Scan { src: s, .. }
        | Instr::TableGather { src: s, .. }
        | Instr::Reshape { src: s, .. } => src(s),
        Instr::PolyArea { a, b, .. } => {
            src(a);
            src(b);
        }
        Instr::IndexGather { src: s, idx, .. } => {
            src(s);
            op(idx);
        }
        Instr::Count { axis, x, .. } => {
            src(axis);
            op(x);
        }
        Instr::Interp { x, y, .. } => {
            op(x);
            if let Some(y) = y {
                op(y);
            }
        }
        Instr::Region { base, src: s, .. } => {
            *base = canon[*base as usize];
            op(s);
        }
        Instr::DataGather { src: s, spec, .. } => {
            src(s);
            for o in dg[*spec as usize].subs.iter_mut() {
                op(o);
            }
        }
        Instr::Export { slot, .. } => *slot = canon[*slot as usize],
        Instr::DyWrite { write } => {
            let w = &mut dyw[*write as usize];
            w.slot = canon[w.slot as usize];
        }
        Instr::Ramp { .. }
        | Instr::ConstArray { .. }
        | Instr::LoadForcing { .. }
        | Instr::Fault { .. } => {}
        _ => return false,
    }
    true
}

/// Drop every repeated pure CONST instruction (module docs). Runs on the
/// program as lowered, before any pass that reorders or fuses it.
pub(super) fn dedup_const(prog: &mut TapeProgram) {
    let nc = prog.n_const as usize;
    if nc < 2 {
        return;
    }
    let n_slots = prog.slots.len();
    let guarded = prog.guarded_positions();
    // Slots defined more than once (a branch join) never take part.
    let mut defs = vec![0u8; n_slots];
    {
        let t = prog.tables();
        for ins in &prog.instrs {
            ins.for_each_def(&t, |s| {
                defs[s as usize] = defs[s as usize].saturating_add(1)
            });
        }
    }
    let mut canon: Vec<SlotId> = (0..n_slots as SlotId).collect();
    let mut seen: FxHashMap<String, SlotId> = FxHashMap::default();
    let mut repeat = vec![false; nc];
    for pc in 0..nc {
        if guarded[pc] {
            continue;
        }
        let ins = &prog.instrs[pc];
        let Some(out) = ins.out() else { continue };
        if defs[out as usize] != 1 {
            continue;
        }
        let Some(k) = key(prog, pc, ins, &canon) else {
            continue;
        };
        match seen.get(&k) {
            Some(&first) => {
                canon[out as usize] = first;
                repeat[pc] = true;
            }
            None => {
                seen.insert(k, out);
            }
        }
    }
    if !repeat.iter().any(|&r| r) {
        return;
    }
    // A repeat read by an instruction that cannot be renamed is kept (it
    // holds the same value as its first); every other read is renamed.
    let mut kept: Vec<bool> = vec![false; n_slots];
    let mut renamable = vec![true; prog.instrs.len()];
    {
        let t = prog.tables();
        let mut dg = prog.data_gathers.clone();
        let mut dyw = prog.dy_writes.clone();
        for (pc, ins) in prog.instrs.iter().enumerate() {
            let mut probe = ins.clone();
            if !rename(&mut probe, &mut dg, &mut dyw, &canon) {
                renamable[pc] = false;
                ins.for_each_read(&t, |s| {
                    if canon[s as usize] != s {
                        kept[s as usize] = true;
                    }
                });
            }
        }
    }
    let TapeProgram {
        instrs,
        data_gathers,
        dy_writes,
        exports,
        ..
    } = prog;
    for (pc, ins) in instrs.iter_mut().enumerate() {
        if renamable[pc] {
            rename(ins, data_gathers, dy_writes, &canon);
        }
    }
    for (_, s) in exports.iter_mut() {
        *s = canon[*s as usize];
    }
    let mut keep = vec![true; prog.instrs.len()];
    for pc in 0..nc {
        if repeat[pc] {
            let out = prog.instrs[pc].out().expect("a repeat defines a slot");
            keep[pc] = kept[out as usize];
        }
    }
    let dropped = keep.iter().filter(|&&k| !k).count();
    if dropped == 0 {
        return;
    }
    let mut it = keep.iter();
    prog.instrs.retain(|_| *it.next().unwrap());
    if !prog.precision.is_empty() {
        let mut it = keep.iter();
        prog.precision.retain(|_| *it.next().unwrap());
    }
    let mut it = keep.iter();
    prog.provenance.retain(|_| *it.next().unwrap());
    prog.n_const -= dropped as u32;
}
