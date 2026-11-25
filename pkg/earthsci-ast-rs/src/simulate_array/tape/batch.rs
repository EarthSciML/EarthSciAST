//! Calls of one function that run as one batched execution.
//!
//! A program often calls one compiled definition several times with
//! different arguments: the same stencil for every tracer, the same
//! interpolation for every field. Each [`Instr::Call`] runs the whole
//! function program for its one set of arguments, so the per-call work that
//! does not depend on the box (the call's setup, each instruction's
//! dispatch and operand resolution) is paid once per call.
//!
//! This pass finds calls of the same function that are independent of each
//! other and places them next to each other, at the position of the first:
//! each later one moves up past instructions it does not depend on (its
//! inputs are all defined before that position, and nothing reads its
//! result before its own position, since a call's result slot is defined
//! by the call alone). [`TapeProgram::call_batches`] then records, at the
//! first call of each such run, how many calls it holds. The executor runs
//! them as ONE execution of the function over all of them: each argument is
//! a view of its call's source with an extra "which call" axis (no copy),
//! every instruction of the function body runs once for every call before
//! the next instruction, and a call inside the body is itself one batched
//! execution over every call of the batch. The function is compiled once; no
//! instruction is copied into the caller.
//!
//! Moving a call earlier changes no value: it reads exactly the values it
//! read at its own position (its inputs are defined once, before the new
//! position), computes them with the same kernels in the same order, and
//! nothing between the two positions reads what it writes. Nor does it
//! change which fault latches first: a call that can fault moves above no
//! other instruction that can. A call stays put when an input or its result
//! is defined more than once, or when it sits in a branch region or a
//! recurrence body.

use super::ir::*;

/// Group the independent calls of each function into batches (see the
/// module docs), filling [`TapeProgram::call_batches`]. Runs on a finished
/// instruction stream, before slab coloring; `funcs_fault` says per function
/// the program calls whether it can latch a fault ([`funcs_can_fault`]).
pub(super) fn batch_calls(prog: &mut TapeProgram, funcs_fault: &[bool]) {
    prog.call_batches.clear();
    if prog.tables.calls.is_empty() {
        return;
    }
    let n = prog.instrs.len();
    let du = DefUse::of(prog);
    let tables = prog.slot_tables();
    // Instructions inside a branch region or a recurrence body.
    let mut covered = vec![false; n];
    for pc in 0..n {
        let len = prog.instrs[pc].region_len(&tables);
        for c in covered.iter_mut().take((pc + len + 1).min(n)).skip(pc + 1) {
            *c = true;
        }
    }
    let cont = (prog.n_const + prog.n_segment) as usize;
    let parts = [
        0..prog.n_const as usize,
        prog.n_const as usize..cont,
        cont..cont + prog.n_rhs as usize,
        cont + prog.n_rhs as usize..n,
    ];
    // Per part: each batch's members (positions, ascending), keyed by its
    // first member's position.
    let mut edits: Vec<(
        std::ops::Range<usize>,
        Vec<(Instr, usize)>,
        Vec<(usize, usize)>,
    )> = Vec::new();
    for part in parts {
        if part.len() < 2 {
            continue;
        }
        // The open batch of each function: its first member's position and
        // its members.
        let mut open: rustc_hash::FxHashMap<(u32, Option<crate::precision::Precision>), usize> =
            Default::default();
        let mut batches: Vec<Vec<usize>> = Vec::new();
        // The last position, in the order the part runs in once batched,
        // of an instruction that can latch a fault.
        let mut last_fault: Option<usize> = None;
        for pc in part.clone() {
            let can_fault = prog.instrs[pc].can_fault(&prog.tables.calls, funcs_fault);
            let Instr::Call { call, out } = prog.instrs[pc] else {
                if can_fault {
                    last_fault = Some(pc);
                }
                continue;
            };
            if covered[pc] || du.n_defs[out as usize] != 1 {
                if can_fault {
                    last_fault = Some(pc);
                }
                continue;
            }
            // The earliest position the call can run at: after every
            // definition of what it reads.
            let mut earliest = part.start;
            let mut movable = true;
            prog.instrs[pc].for_each_read(&tables, |s| {
                if du.n_defs[s as usize] > 1 {
                    movable = false;
                }
                let d = du.first_def[s as usize];
                if d != DefUse::NONE {
                    if d >= pc {
                        movable = false;
                    }
                    if d >= part.start {
                        earliest = earliest.max(d + 1);
                    }
                }
            });
            // Calls of one batch run under one precision.
            let key = (
                prog.tables.calls[call as usize].func,
                prog.precision.get(pc).copied(),
            );
            // A call that can fault does not move above another instruction
            // that can, so the first fault latched is the one latched
            // without batching. The earlier calls of its batch, all at the
            // batch's position, run before it either way.
            if can_fault && let Some(f) = last_fault {
                earliest = earliest.max(f);
            }
            match open.get(&key) {
                Some(&b) if movable && earliest <= batches[b][0] => batches[b].push(pc),
                _ => {
                    // A call that cannot move starts a batch the later calls
                    // may join (they move up to it); it never moves itself.
                    open.insert(key, batches.len());
                    batches.push(vec![pc]);
                    if can_fault {
                        last_fault = Some(pc);
                    }
                }
            }
        }
        batches.retain(|b| b.len() > 1);
        if batches.is_empty() {
            continue;
        }
        let mut at: rustc_hash::FxHashMap<usize, usize> = Default::default();
        let mut moved = vec![false; part.len()];
        for (b, members) in batches.iter().enumerate() {
            at.insert(members[0], b);
            for &m in &members[1..] {
                moved[m - part.start] = true;
            }
        }
        let mut body: Vec<(Instr, usize)> = Vec::with_capacity(part.len());
        let mut runs: Vec<(usize, usize)> = Vec::new();
        for pc in part.clone() {
            if moved[pc - part.start] {
                continue;
            }
            if let Some(&b) = at.get(&pc) {
                runs.push((part.start + body.len(), batches[b].len()));
                for &m in &batches[b] {
                    body.push((prog.instrs[m].clone(), m));
                }
            } else {
                body.push((prog.instrs[pc].clone(), pc));
            }
        }
        debug_assert_eq!(body.len(), part.len());
        edits.push((part, body, runs));
    }
    if edits.is_empty() {
        return;
    }
    let mut lens = vec![0u16; n];
    for (_, _, runs) in &edits {
        for &(start, len) in runs {
            // A batch longer than the table holds is split.
            let mut s = start;
            let mut left = len;
            while left > 1 {
                let k = left.min(u16::MAX as usize);
                lens[s] = k as u16;
                s += k;
                left -= k;
            }
        }
    }
    prog.splice(edits.into_iter().map(|(r, b, _)| (r, b)));
    prog.call_batches = lens;
}
