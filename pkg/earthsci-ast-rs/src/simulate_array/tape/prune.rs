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
//! moved ones keep their relative order.

use super::ir::*;

/// Reorder the CONTINUOUS section (see the module docs) and set
/// [`TapeProgram::n_rhs`].
pub(super) fn split_output_only(prog: &mut TapeProgram) {
    let sec = prog.section_range(Cadence::Continuous);
    prog.n_rhs = sec.len() as u32;
    let tables = prog.tables();

    // Units: a region header with its body, or one instruction.
    let mut units: Vec<std::ops::Range<usize>> = Vec::new();
    let mut pc = sec.start;
    while pc < sec.end {
        let len = 1 + prog.instrs[pc].region_len(&tables);
        let end = (pc + len).min(sec.end);
        units.push(pc..end);
        pc = end;
    }

    // Backward closure over the units, from the roots.
    let du = DefUse::of(prog);
    let mut unit_of: Vec<u32> = vec![0; sec.len()];
    for (u, r) in units.iter().enumerate() {
        unit_of[r.start - sec.start..r.end - sec.start].fill(u as u32);
    }
    // The unit defining `s` last, when it is in this section.
    let def_unit = |s: SlotId| {
        let d = du.last_def[s as usize];
        (d != DefUse::NONE && sec.contains(&d)).then(|| unit_of[d - sec.start] as usize)
    };
    // A root has an effect beyond its slots that a call must keep: a
    // fault, a `dy` write, or a recurrence sweep.
    let root = |ins: &Instr| match ins.effect() {
        Effect::Faults | Effect::WritesDy | Effect::Recurrence => true,
        Effect::Lanes => match ins {
            Instr::Lanes { spec } => tables.lanes[*spec as usize].writes_dy(),
            _ => unreachable!("only `Lanes` runs a lane program"),
        },
        Effect::Pure | Effect::Branch | Effect::Publishes => false,
    };
    let mut needed = vec![false; units.len()];
    for u in (0..units.len()).rev() {
        if !needed[u] && !prog.instrs[units[u].clone()].iter().any(root) {
            continue;
        }
        needed[u] = true;
        for ins in &prog.instrs[units[u].clone()] {
            ins.for_each_read(&tables, |s| {
                // Defined in this section by an earlier unit (a unit's own
                // definitions are inside it already).
                if let Some(d) = def_unit(s)
                    && d < u
                {
                    needed[d] = true;
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

    let body: Vec<(Instr, usize)> = units
        .iter()
        .zip(&needed)
        .filter(|(_, n)| **n)
        .chain(units.iter().zip(&needed).filter(|(_, n)| !**n))
        .flat_map(|(r, _)| r.clone())
        .map(|i| (prog.instrs[i].clone(), i))
        .collect();
    // The whole section is the derivative part while it is rewritten.
    prog.splice([(sec, body)]);
    prog.n_rhs = n_needed as u32;
}
