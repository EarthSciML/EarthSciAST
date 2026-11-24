//! Liveness and greedy interval slab coloring: the pass that gives every
//! slot of a finished program its storage.

use super::ir::*;
use rustc_hash::FxHashMap;
use smallvec::SmallVec;

/// Assign each slot a storage bucket. Cross-section-live slots (a CONST ramp
/// read by the CONTINUOUS section every call) get dedicated storages; slots
/// whose whole lifetime sits inside one section recycle storage greedily by
/// element count (linear-scan last-use over the straight-line program —
/// conservative and sound under the structured `JmpIfZero` skips, which only
/// ever shorten execution).
///
/// A `Sweep` body is the one region that runs more than once, so its last
/// pass is not the only one that matters: a slot defined AHEAD of the body
/// and read in it (a hoisted value, the coordinates, the array being built)
/// is read again by the next pass, and so stays live to the body's end — as
/// does the result the sweep stores after each pass. A slot the body itself
/// defines is written before it is read in every pass, so its straight-line
/// interval is exact.
pub(super) fn color_slab(prog: &mut TapeProgram) {
    let n_slots = prog.tables.slots.len();
    let du = DefUse::of(prog);
    let def = &du.first_def;
    // A RE-definition (the phi slot's second branch `Copy`) keeps the
    // storage reserved through it, so it counts as a use.
    let mut last_use: Vec<usize> = (0..n_slots)
        .map(|s| {
            let read = du.last_read(s as SlotId).unwrap_or(0);
            if du.n_defs[s] > 1 {
                read.max(du.last_def[s])
            } else {
                read
            }
        })
        .collect();
    let tables = prog.slot_tables();
    for (pc, instr) in prog.instrs.iter().enumerate() {
        let Instr::Sweep { spec } = instr else {
            continue;
        };
        let sw = &prog.tables.sweeps[*spec as usize];
        let body = pc + 1..pc + 1 + sw.body_len as usize;
        let last = body.end - 1;
        let mut keep: SmallVec<[SlotId; 8]> = SmallVec::new();
        keep.push(sw.out);
        keep.extend(sw.coords.iter().copied());
        if let Operand::Slot(r) = sw.result {
            keep.push(r);
        }
        for j in body.clone() {
            prog.instrs[j].for_each_read(&tables, |s| {
                if def[s as usize] < body.start {
                    keep.push(s);
                }
            });
        }
        for s in keep {
            last_use[s as usize] = last_use[s as usize].max(last);
        }
    }

    // A batch of calls runs as one execution (`super::batch`): every
    // call's arguments stay live until the last call of the batch, so no
    // call's result takes the storage of an argument another call of the
    // batch still reads.
    for (pc, &n) in prog.call_batches.iter().enumerate() {
        if n < 2 {
            continue;
        }
        let last = pc + n as usize - 1;
        for j in pc..=last {
            prog.instrs[j].for_each_read(&tables, |s| {
                last_use[s as usize] = last_use[s as usize].max(last);
            });
        }
    }

    // Persistence: read from a later section than the defining one.
    let mut dedicated: Vec<bool> = vec![false; n_slots];
    for s in 0..n_slots {
        if def[s] == usize::MAX {
            continue; // never defined (unused slot — possible after rollbacks)
        }
        let def_sec = prog.section_of(def[s]);
        let use_sec = prog.section_of(last_use[s].max(def[s]));
        if use_sec > def_sec {
            dedicated[s] = true;
        }
    }

    // Storage assignment.
    let mut storages: Vec<StorageDesc> = Vec::new();
    // Free storages per element count (recycled class only).
    let mut free: FxHashMap<usize, Vec<u32>> = FxHashMap::default();
    // Slots whose storage frees after instruction i: (i → slots).
    let mut dying_at: Vec<Vec<u32>> = vec![Vec::new(); prog.instrs.len() + 1];
    for s in 0..n_slots {
        if def[s] != usize::MAX && !dedicated[s] {
            dying_at[last_use[s].max(def[s])].push(s as u32);
        }
    }

    for i in 0..prog.instrs.len() {
        // Aliasing hazard: a Gather/Region reads its source through shifted
        // offsets while writing out — and a Fused group's outputs are written
        // run-by-run while inputs may still be read at shifted offsets by
        // later runs — so out must not reuse a source buffer freed by this
        // very instruction. Release dying operands BEFORE allocating out only
        // for alias-safe (index-aligned elementwise) instructions.
        let alias_safe = prog.instrs[i].may_overwrite_source();
        let mut defs_here: SmallVec<[SlotId; 2]> = SmallVec::new();
        prog.instrs[i].for_each_def(&prog.slot_tables(), |o| {
            if def[o as usize] == i {
                defs_here.push(o);
            }
        });
        if alias_safe {
            for &s in &dying_at[i] {
                let st = prog.tables.slots[s as usize].storage;
                if st != u32::MAX {
                    free.entry(storages[st as usize].elems)
                        .or_default()
                        .push(st);
                }
            }
        }
        for &o in &defs_here {
            let desc = &prog.tables.slots[o as usize];
            let elems = desc.elems();
            let storage = if dedicated[o as usize] {
                storages.push(StorageDesc {
                    elems,
                    offset: 0,
                    cadence: desc.cadence,
                    dedicated: true,
                });
                (storages.len() - 1) as u32
            } else if let Some(st) = free.get_mut(&elems).and_then(|v| v.pop()) {
                st
            } else {
                storages.push(StorageDesc {
                    elems,
                    offset: 0,
                    cadence: desc.cadence,
                    dedicated: false,
                });
                (storages.len() - 1) as u32
            };
            prog.tables.slots[o as usize].storage = storage;
        }
        if !alias_safe {
            for &s in &dying_at[i] {
                let st = prog.tables.slots[s as usize].storage;
                if st != u32::MAX {
                    free.entry(storages[st as usize].elems)
                        .or_default()
                        .push(st);
                }
            }
        }
    }

    // Flat offsets + summary.
    let mut offset = 0usize;
    let mut const_elems = 0usize;
    let mut segment_elems = 0usize;
    let mut recycled_elems = 0usize;
    for st in &mut storages {
        st.offset = offset;
        offset += st.elems;
        if st.dedicated {
            match st.cadence {
                Cadence::Const => const_elems += st.elems,
                Cadence::Segment => segment_elems += st.elems,
                Cadence::Continuous => recycled_elems += st.elems,
            }
        } else {
            recycled_elems += st.elems;
        }
    }
    prog.slab = SlabLayout {
        storages,
        total_elems: offset,
        const_elems,
        segment_elems,
        recycled_elems,
    };
}
