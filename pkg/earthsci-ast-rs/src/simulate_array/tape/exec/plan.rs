//! One fork-join per phase of a threaded call (native targets only).
//!
//! A steady threaded call that ran its instructions one by one entered the
//! pool once for every instruction large enough to split, and ran every
//! smaller instruction on the calling thread while the workers waited. A
//! call plan groups the call's instructions into phases instead: the
//! instructions of one phase depend on nothing another instruction of the
//! same phase writes, so the phase runs as ONE fork-join, each thread taking
//! its share of every instruction that splits and a whole instruction of
//! those that do not. The fork-join's join is the barrier between phases.
//!
//! An instruction's phase is one more than the latest phase of an earlier
//! instruction it conflicts with: one that writes storage it reads or
//! writes, or reads storage it writes (the slab's storages are recycled
//! between slots, so a write can also be the end of another slot's life).
//! Moving an instruction to an earlier phase than its program position
//! changes no value: it reads exactly what it read in program order, and
//! each element is still computed by the same kernels in the same order
//! (each share of a split instruction is the window the pool's worker
//! computes on the existing path). So a planned call is bit-identical to the
//! serial one.
//!
//! What the plan cannot place, it runs as before, on the calling thread
//! through the instruction loop, between phases: control flow (a branch, a
//! recurrence sweep), a segmented-reduction chain (which already splits in
//! one dispatch), a lane program, an instruction with its own precision, and
//! any instruction that would split but cannot run share by share.

use super::interp::{Cx, exec_share, exec_straight, is_straight, shares};
use super::resolve::rm_strides;
use super::*;

/// Estimated element-operations a phase must have before it forks: below
/// it, the phase's instructions run on the calling thread, which costs less
/// than waking the workers and waiting for the slowest.
const PHASE_MIN_WORK: usize = 1 << 12;

/// [`PHASE_MIN_WORK`], or 0 while a test forces splits.
fn phase_min_work() -> usize {
    if super::par::forced() {
        0
    } else {
        PHASE_MIN_WORK
    }
}

/// The largest slot (in elements) the plan gives storage of its own. A
/// recycled storage is still in cache when the next slot takes it; a slot
/// moved out of it is not, and past this size the cache misses cost more
/// than the fork-joins the move saves.
const MOVE_MAX_ELEMS: usize = 1 << 15;

/// The most instructions a plan places; a longer section runs as before.
const MAX_PLANNED: usize = 1 << 13;

/// One instruction of a phase.
#[derive(Clone, Copy, Debug)]
struct Task {
    pc: u32,
    /// The width it splits across (every thread below it runs one share),
    /// or 0 when one thread runs it whole.
    ways: u16,
    /// The thread that runs it whole.
    thread: u16,
}

#[derive(Debug)]
enum Step {
    /// Instructions the calling thread runs through the instruction loop.
    Loop(std::ops::Range<usize>),
    /// Independent instructions `tasks[range]`, run in one fork-join across
    /// `threads` threads (1: on the calling thread alone).
    Fork {
        tasks: std::ops::Range<usize>,
        threads: usize,
    },
}

/// The phases of one call's continuous instructions at one split width.
pub(in crate::simulate_array::tape) struct CallPlan {
    /// The split width it was built for.
    ways: usize,
    /// The instruction range it covers.
    range: std::ops::Range<usize>,
    steps: Vec<Step>,
    tasks: Vec<Task>,
    /// Per slot, its slab offset under this plan: the program's, except
    /// for the slots the plan moved to storage of their own (see
    /// [`CallPlan::build`]).
    pub(super) slot_off: Vec<usize>,
    /// The slab length that layout needs.
    pub(super) slab_len: usize,
}

/// What an instruction does to `dy`: the `[lo, hi)` positions it may write.
fn dy_written(prog: &TapeProgram, ins: &Instr, dy_home: &[usize]) -> Option<(usize, usize)> {
    match ins {
        Instr::DyWrite { write } => {
            let w = &prog.dy_writes[*write as usize];
            if dy_home[w.slot as usize] != usize::MAX {
                return None;
            }
            if let Some(pos) = &w.scatter {
                let lo = pos.iter().copied().min()?;
                let hi = pos.iter().copied().max()? + 1;
                return Some((lo, hi));
            }
            if let Some(flat) = w.scalar_flat {
                return Some((flat, flat + 1));
            }
            let sv = &prog.state_vars[w.var as usize];
            Some((
                sv.flat_offset,
                sv.flat_offset + sv.shape.iter().product::<usize>().max(1),
            ))
        }
        _ => None,
    }
}

/// Whether fused group output `s` is written to the slab (not homed in
/// `dy` or unstored), and the `dy` range it is written to when homed.
fn fused_out(prog: &TapeProgram, s: SlotId, dy_home: &[usize]) -> (bool, Option<(usize, usize)>) {
    match dy_home.get(s as usize) {
        Some(&UNSTORED) => (false, None),
        Some(&off) if off != usize::MAX => (
            false,
            Some((off, off + prog.slots[s as usize].elems().max(1))),
        ),
        _ => (true, None),
    }
}

/// How the plan places one instruction at split width `ways`.
enum Place {
    /// A task, split this wide (0: whole).
    Task(u16),
    /// Run by the instruction loop, `n` instructions from here.
    Loop(usize),
}

fn place(
    prog: &TapeProgram,
    pc: usize,
    end: usize,
    ways: usize,
    chains: &[super::chain::SegChain],
) -> Place {
    if let Some(ch) = chains.iter().find(|c| c.start == pc && c.end <= end) {
        return Place::Loop(ch.end - pc);
    }
    let ins = &prog.instrs[pc];
    match ins {
        Instr::JmpIfZero {
            n_true, n_false, ..
        } => return Place::Loop(1 + (*n_true + *n_false) as usize),
        Instr::Sweep { spec } => {
            return Place::Loop(1 + prog.sweeps[*spec as usize].body_len as usize);
        }
        _ => {}
    }
    if !is_straight(ins) || prog.precision.get(pc).is_some() {
        return Place::Loop(1);
    }
    let split = match ins {
        Instr::Fused { spec } => super::par::split_ways(&prog.fused[*spec as usize], ways),
        Instr::Assemble { out, .. } => {
            let d = &prog.slots[*out as usize];
            if d.shape.is_empty() {
                1
            } else {
                super::par::ways_for(d.elems(), ways)
            }
        }
        // A scan along the leading axis splits by its lanes.
        Instr::Scan {
            axis: 0, src_shape, ..
        } => {
            let lanes: usize = src_shape.iter().skip(1).product();
            if src_shape.len() < 2 {
                1
            } else {
                super::par::lane_split_ways(lanes, src_shape.iter().product(), ways)
            }
        }
        Instr::Gather { out, .. } | Instr::Reduce { out, .. } => {
            let d = &prog.slots[*out as usize];
            if d.scalar {
                1
            } else {
                super::par::ways_for(d.elems(), ways)
            }
        }
        // A copy's split is fixed here, on the calling thread: a worker
        // must not choose it again (a test's forced width is the calling
        // thread's alone).
        Instr::Copy { out, .. } => {
            let d = &prog.slots[*out as usize];
            if d.scalar {
                1
            } else {
                super::par::copy_ways(ways, &rm_strides(&d.shape), &d.shape)
            }
        }
        Instr::DyWrite { write } => {
            let w = &prog.dy_writes[*write as usize];
            if w.scatter.is_some() || w.scalar_flat.is_some() {
                1
            } else {
                let sv = &prog.state_vars[w.var as usize];
                let shape = &prog.slots[w.slot as usize].shape;
                let st = dy_strides(prog, &sv.shape);
                super::par::copy_ways(ways, &st, shape)
            }
        }
        _ => 1,
    };
    if split <= 1 {
        Place::Task(0)
    } else if shares(prog, ins) {
        Place::Task(split as u16)
    } else {
        Place::Loop(1)
    }
}

/// The estimated cost of one task, for balancing whole tasks.
fn task_cost(prog: &TapeProgram, ins: &Instr) -> usize {
    let elems = ins.out().map_or(1, |o| prog.slots[o as usize].elems());
    super::par::instr_work(prog, ins).max(elems).max(1)
}

impl CallPlan {
    /// The plan of `range` at split width `ways`, or `None` when the range
    /// is too long to place or reads observeds published at run time.
    pub(super) fn build(
        prog: &TapeProgram,
        range: std::ops::Range<usize>,
        ways: usize,
        chains: &[super::chain::SegChain],
        dy_home: &[usize],
        base_off: &[usize],
    ) -> Option<CallPlan> {
        if ways < 2 || range.len() > MAX_PLANNED {
            return None;
        }
        let tables = prog.tables();
        let n_store = prog.slab.storages.len();
        // Slots defined exactly once, inside the range: the ones the plan
        // may move to storage of their own.
        let mut defs = vec![0u32; prog.slots.len()];
        let mut def_in = vec![false; prog.slots.len()];
        for (pc, ins) in prog.instrs.iter().enumerate() {
            ins.for_each_def(&tables, |s| {
                defs[s as usize] += 1;
                def_in[s as usize] = range.contains(&pc);
            });
        }
        let movable = |s: SlotId| defs[s as usize] == 1 && def_in[s as usize];
        // Per slot, the storage the plan gives it (`u32::MAX`: the
        // program's); a moved slot's storage is numbered past the program's.
        let mut moved = vec![u32::MAX; prog.slots.len()];
        let mut slot_off = base_off.to_vec();
        let mut slab_len = prog.slab.total_elems;
        let budget = prog.slab.total_elems;
        let mut n_moved = 0usize;
        let store_of = |moved: &[u32], s: SlotId| -> Option<u32> {
            match moved[s as usize] {
                u32::MAX => {
                    let st = prog.slots[s as usize].storage;
                    (st != u32::MAX).then_some(st)
                }
                m => Some(m),
            }
        };
        let mut steps: Vec<Step> = Vec::new();
        let mut tasks: Vec<Task> = Vec::new();
        // The tasks since the last loop step, with their phases.
        let mut seg: Vec<(Task, usize, usize)> = Vec::new();
        // Per storage: the phase of its last writer and the latest phase
        // that read it since, both offset by one (0 = none in this segment).
        let mut last_write = vec![0usize; n_store];
        let mut last_read = vec![0usize; n_store];
        let mut wslots: Vec<SlotId> = Vec::new();
        let mut dy_writes: Vec<(usize, usize, usize)> = Vec::new();
        let mut reads: Vec<u32> = Vec::new();
        let mut writes: Vec<u32> = Vec::new();
        let mut dys: Vec<(usize, usize)> = Vec::new();
        let flush =
            |seg: &mut Vec<(Task, usize, usize)>, steps: &mut Vec<Step>, tasks: &mut Vec<Task>| {
                let phases = seg.iter().map(|t| t.1).max().map_or(0, |m| m + 1);
                for ph in 0..phases {
                    let start = tasks.len();
                    let mut work = 0usize;
                    let mut split = false;
                    let mut wholes: Vec<(usize, usize)> = Vec::new();
                    for &(t, p, cost) in seg.iter() {
                        if p != ph {
                            continue;
                        }
                        work = work.saturating_add(cost);
                        split |= t.ways > 0;
                        if t.ways == 0 {
                            wholes.push((tasks.len(), cost));
                        }
                        tasks.push(t);
                    }
                    // Whole tasks to the least loaded thread, largest first;
                    // every thread carries the same share of the split ones.
                    wholes.sort_by_key(|&(i, c)| (std::cmp::Reverse(c), i));
                    let mut load = vec![0usize; ways];
                    let mut used = 1usize;
                    for (i, c) in wholes {
                        let t = (0..ways).min_by_key(|&t| (load[t], t)).unwrap_or(0);
                        load[t] += c;
                        tasks[i].thread = t as u16;
                        used = used.max(t + 1);
                    }
                    let threads = if work < phase_min_work() {
                        1
                    } else if split {
                        ways
                    } else {
                        used
                    };
                    if threads == 1 {
                        for t in &mut tasks[start..] {
                            t.thread = 0;
                        }
                    }
                    steps.push(Step::Fork {
                        tasks: start..tasks.len(),
                        threads,
                    });
                }
                seg.clear();
            };
        let mut pc = range.start;
        while pc < range.end {
            let split = match place(prog, pc, range.end, ways, chains) {
                Place::Loop(n) => {
                    let hi = (pc + n).min(range.end);
                    flush(&mut seg, &mut steps, &mut tasks);
                    last_write.fill(0);
                    last_read.fill(0);
                    dy_writes.clear();
                    match steps.last_mut() {
                        Some(Step::Loop(r)) if r.end == pc => r.end = hi,
                        _ => steps.push(Step::Loop(pc..hi)),
                    }
                    pc = hi;
                    continue;
                }
                Place::Task(w) => w,
            };
            let ins = &prog.instrs[pc];
            // A `DyWrite` whose group stored the slot into `dy` does nothing.
            if matches!(ins, Instr::DyWrite { write }
                if dy_home[prog.dy_writes[*write as usize].slot as usize] != usize::MAX)
            {
                pc += 1;
                continue;
            }
            reads.clear();
            writes.clear();
            wslots.clear();
            dys.clear();
            ins.for_each_read(&tables, |s| reads.extend(store_of(&moved, s)));
            match ins {
                Instr::Fused { spec } => {
                    let fs = &prog.fused[*spec as usize];
                    let outs = fs.outputs.iter().map(|&(_, s)| s);
                    for s in outs.chain(fs.reduce.as_ref().map(|r| r.out)) {
                        let (slab, dy) = fused_out(prog, s, dy_home);
                        if slab {
                            wslots.push(s);
                        }
                        dys.extend(dy);
                    }
                }
                _ => ins.for_each_def(&tables, |s| wslots.push(s)),
            }
            dys.extend(dy_written(prog, ins, dy_home));
            let mut phase = 0usize;
            for &b in &reads {
                phase = phase.max(last_write[b as usize]);
            }
            for &(lo, hi) in &dys {
                for &(a, b, p) in &dy_writes {
                    if lo < b && a < hi {
                        phase = phase.max(p);
                    }
                }
            }
            // A slot whose storage an earlier task of this segment still
            // reads or writes would wait for it, though it needs nothing
            // that task computes (the storage is recycled between slots):
            // give it storage of its own instead, while the extra slab
            // stays within the program's own size.
            for &s in &wslots {
                let Some(b) = store_of(&moved, s) else {
                    continue;
                };
                let wait = last_write[b as usize].max(last_read[b as usize]);
                let elems = prog.slots[s as usize].elems().max(1);
                if wait > phase
                    && movable(s)
                    && elems <= MOVE_MAX_ELEMS
                    && n_moved + elems <= budget
                {
                    // Cache-line aligned, as a split cuts its box.
                    slab_len = slab_len.div_ceil(8) * 8;
                    slot_off[s as usize] = slab_len;
                    slab_len += elems;
                    n_moved += elems;
                    moved[s as usize] = (last_write.len()) as u32;
                    last_write.push(0);
                    last_read.push(0);
                }
                writes.extend(store_of(&moved, s));
            }
            for &b in &writes {
                phase = phase.max(last_write[b as usize]).max(last_read[b as usize]);
            }
            // `phase` is the latest conflicting phase plus one: this task's
            // own (0-based) phase.
            for &b in &reads {
                let r = &mut last_read[b as usize];
                *r = (*r).max(phase + 1);
            }
            for &b in &writes {
                last_write[b as usize] = phase + 1;
                last_read[b as usize] = 0;
            }
            for &(lo, hi) in &dys {
                dy_writes.push((lo, hi, phase + 1));
            }
            seg.push((
                Task {
                    pc: pc as u32,
                    ways: split,
                    thread: 0,
                },
                phase,
                task_cost(prog, ins),
            ));
            pc += 1;
        }
        flush(&mut seg, &mut steps, &mut tasks);
        Some(CallPlan {
            ways,
            range,
            steps,
            tasks,
            slot_off,
            slab_len,
        })
    }

    /// Whether this plan is the one for `range` at width `ways`.
    pub(super) fn fits(&self, range: &std::ops::Range<usize>, ways: usize) -> bool {
        self.ways == ways && self.range == *range
    }
}

/// The calling thread's view of a phase, shared with the pool's workers.
struct PhaseJob<'a> {
    cx: Cx<'a>,
    prog: &'a TapeProgram,
    tasks: &'a [Task],
    main: *mut Scratch,
    peers: *mut Scratch,
    precision: crate::precision::Precision,
}

// SAFETY: the workers read the call's environment only through the
// straight-line instructions, which touch neither its forcing buffer nor its
// ring registry (the parts that are not `Sync`); each thread uses its own
// scratch (`main` for share 0, `peers[w - 1]` for share `w`), and the plan
// gives no two tasks of a phase storage one writes and the other touches.
unsafe impl Sync for PhaseJob<'_> {}

impl PhaseJob<'_> {
    /// Thread `w`'s part of the phase.
    unsafe fn run(&self, w: usize) {
        let _p = crate::precision::enter(self.precision);
        let scratch = unsafe {
            if w == 0 {
                &mut *self.main
            } else {
                &mut *self.peers.add(w - 1)
            }
        };
        for t in self.tasks {
            let ins = &self.prog.instrs[t.pc as usize];
            if t.ways > 0 {
                if w < t.ways as usize {
                    unsafe { exec_share(&self.cx, ins, scratch, w, t.ways as usize) };
                }
            } else if t.thread as usize == w {
                unsafe { exec_straight(&self.cx, ins, scratch, 1) };
            }
        }
    }
}

/// Run `plan` for this call: its loop steps through the instruction loop on
/// this thread, its phases as one fork-join each.
pub(super) fn run_plan(plan: &CallPlan, env: &Env, exec: &mut TapeExec, dy: &mut [f64]) {
    let prog = env.prog;
    while exec.peers.len() + 1 < plan.ways {
        exec.peers.push(Scratch {
            fregs: vec![0.0; exec.scratch.fregs.len()],
            fscratch: super::fused::FusedScratch::for_peer(prog),
            asm_parts: Vec::new(),
        });
    }
    for step in &plan.steps {
        let (tasks, threads) = match step {
            Step::Loop(r) => {
                super::interp::run_range(env, r.clone(), exec, dy);
                continue;
            }
            Step::Fork { tasks, threads } => (&plan.tasks[tasks.clone()], *threads),
        };
        let TapeExec {
            slab,
            slot_off,
            plan_full,
            asm_covered,
            idx_tables,
            simd,
            dy_home_quiet,
            scratch,
            peers,
            ..
        } = exec;
        let cx = Cx {
            env,
            slab_ptr: slab.as_mut_ptr(),
            slot_off,
            plan_full,
            asm_covered,
            idx_tables,
            simd: *simd,
            dy_home: dy_home_quiet,
            dy: dy.as_mut_ptr(),
            dy_len: dy.len(),
        };
        if threads <= 1 {
            // Below the fork floor: in program order on this thread, as the
            // instruction loop would run them.
            let call = scratch.fscratch.workers.call_ways;
            for t in tasks {
                unsafe { exec_straight(&cx, &prog.instrs[t.pc as usize], scratch, call) };
            }
            continue;
        }
        let job = PhaseJob {
            cx,
            prog,
            tasks,
            main: scratch,
            peers: peers.as_mut_ptr(),
            precision: crate::precision::active(),
        };
        super::pool::run(threads, &|w| unsafe { job.run(w) });
    }
}
