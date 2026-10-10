//! Output-only observeds leave the right-hand side.
//!
//! A `native` build exports every observed, because the same program serves
//! the observed and output passes (`TapeProgram::exports`). An observed that
//! no derivative reads is then still computed on every right-hand-side
//! call, Jacobian columns included, only to be thrown away: its `Export` is
//! skipped while nothing reads the published map.
//!
//! This pass moves the CONTINUOUS instructions a call needs to the front of
//! the section and the rest after them, and records where the needed part
//! ends ([`TapeProgram::n_rhs`]). A call with its exports off runs the
//! needed part only; a call that publishes (the observed and output passes)
//! runs the whole section, so every observed is still available to them.
//!
//! What a call needs: every `dy` write (a lane program's included), every
//! instruction that can latch a fail-closed fault (the interpreter
//! evaluates every observed on every call, so a fault an output-only
//! observed raises must still be raised),
//! and whatever those read. A conditional region or a recurrence body moves
//! as one unit, so its skip counts and cell order stay as they are. Needed
//! instructions only read values defined before them by needed
//! instructions, so moving the others after them changes no value; the
//! moved ones keep their relative order. A program with a fallback rule or
//! a by-name observed read in the section is left as it is: those read the
//! published map, which the `Export` instructions fill in program order.

use super::ir::*;

/// Reorder the CONTINUOUS section (see the module docs) and set
/// [`TapeProgram::n_rhs`].
pub(super) fn split_output_only(prog: &mut TapeProgram) {
    let sec = prog.section_range(Cadence::Continuous);
    prog.n_rhs = sec.len() as u32;
    let by_name = |o: &Operand| matches!(o, Operand::Obs(_));
    let tables = prog.tables();
    for ins in &prog.instrs[sec.clone()] {
        let mut obs = false;
        match ins {
            Instr::Fallback { .. } => return,
            Instr::Gather { src, .. }
            | Instr::LoadElem { src, .. }
            | Instr::Reduce { src, .. }
            | Instr::Scan { src, .. }
            | Instr::TableGather { src, .. }
            | Instr::Reshape { src, .. }
            | Instr::IndexGather { src, .. }
            | Instr::ScalarRead { src, .. } => obs |= matches!(src, SrcRef::Obs(_)),
            Instr::PolyArea { a, b, .. } => {
                obs |= matches!(a, SrcRef::Obs(_)) || matches!(b, SrcRef::Obs(_))
            }
            _ => {}
        }
        obs |= operands_of(ins, &tables).iter().any(by_name);
        if obs {
            return;
        }
    }

    // Units: a region header with its body, or one instruction.
    let mut units: Vec<std::ops::Range<usize>> = Vec::new();
    let mut pc = sec.start;
    while pc < sec.end {
        let len = match &prog.instrs[pc] {
            Instr::JmpIfZero {
                n_true, n_false, ..
            } => 1 + (*n_true + *n_false) as usize,
            Instr::Sweep { spec } => 1 + prog.sweeps[*spec as usize].body_len as usize,
            _ => 1,
        };
        let end = (pc + len).min(sec.end);
        units.push(pc..end);
        pc = end;
    }

    // Backward closure over the units, from the roots.
    let mut def_unit: Vec<u32> = vec![u32::MAX; prog.slots.len()];
    for (u, r) in units.iter().enumerate() {
        for ins in &prog.instrs[r.clone()] {
            ins.for_each_def(&tables, |s| def_unit[s as usize] = u as u32);
        }
    }
    let root = |ins: &Instr| {
        if let Instr::Lanes { spec } = ins {
            return tables.lanes[*spec as usize]
                .writes
                .iter()
                .any(|w| matches!(w.dst, LaneDst::Dy(_)));
        }
        matches!(
            ins,
            Instr::DyWrite { .. }
                | Instr::Fault { .. }
                | Instr::ScalarRead { .. }
                | Instr::Interp { .. }
                | Instr::LoadForcing { .. }
                | Instr::Sweep { .. }
        )
    };
    let mut needed = vec![false; units.len()];
    for u in (0..units.len()).rev() {
        if !needed[u] && !prog.instrs[units[u].clone()].iter().any(root) {
            continue;
        }
        needed[u] = true;
        for ins in &prog.instrs[units[u].clone()] {
            ins.for_each_read(&tables, |s| {
                let d = def_unit[s as usize];
                // Defined in this section by an earlier unit (a unit's own
                // definitions are inside it already).
                if d != u32::MAX && (d as usize) < u {
                    needed[d as usize] = true;
                }
            });
        }
    }
    let n_needed: usize = units
        .iter()
        .zip(&needed)
        .filter(|(_, n)| **n)
        .map(|(r, _)| r.len())
        .sum();
    if n_needed == sec.len() {
        return;
    }

    let order: Vec<usize> = units
        .iter()
        .zip(&needed)
        .filter(|(_, n)| **n)
        .chain(units.iter().zip(&needed).filter(|(_, n)| !**n))
        .flat_map(|(r, _)| r.clone())
        .collect();
    let tagged = !prog.precision.is_empty();
    let instrs: Vec<Instr> = order.iter().map(|&i| prog.instrs[i].clone()).collect();
    let prov: Vec<u32> = order.iter().map(|&i| prog.provenance[i]).collect();
    let prec: Vec<_> = if tagged {
        order.iter().map(|&i| prog.precision[i]).collect()
    } else {
        Vec::new()
    };
    prog.instrs.splice(sec.clone(), instrs);
    prog.provenance.splice(sec.clone(), prov);
    if tagged {
        prog.precision.splice(sec, prec);
    }
    prog.n_rhs = n_needed as u32;
}

/// The plain operands of `ins` (its slot, state, parameter, time and literal
/// reads), for the by-name check.
fn operands_of(ins: &Instr, t: &SlotTables) -> Vec<Operand> {
    let mut v = Vec::new();
    match ins {
        Instr::Bin { a, b, .. } => v.extend([*a, *b]),
        Instr::Un { a, .. }
        | Instr::Neg { a, .. }
        | Instr::Calendar { a, .. }
        | Instr::Copy { a, .. }
        | Instr::Fill { v: a, .. } => v.push(*a),
        Instr::Select { cond, a, b, .. } => v.extend([*cond, *a, *b]),
        Instr::Interp { x, y, .. } => {
            v.push(*x);
            v.extend(*y);
        }
        Instr::Region { src, .. } => v.push(*src),
        Instr::IndexGather { idx, .. } => v.push(*idx),
        Instr::JmpIfZero { cond, .. } => v.push(*cond),
        Instr::Assemble { table, .. } => {
            v.extend(t.assemblies[*table as usize].parts.iter().map(|(o, _)| *o))
        }
        Instr::ScalarRead { spec, .. } => v.extend(t.scalar_reads[*spec as usize].subs.iter()),
        Instr::Sweep { spec } => v.push(t.sweeps[*spec as usize].result),
        Instr::Fused { spec } => {
            let fs = &t.fused[*spec as usize];
            v.extend(fs.scalars.iter().copied());
            v.extend(fs.inputs.iter().filter_map(|i| match i.src {
                SrcRef::Obs(ix) => Some(Operand::Obs(ix)),
                _ => None,
            }));
        }
        Instr::Lanes { spec } => v.extend(t.lanes[*spec as usize].scalars.iter().copied()),
        _ => {}
    }
    v
}
