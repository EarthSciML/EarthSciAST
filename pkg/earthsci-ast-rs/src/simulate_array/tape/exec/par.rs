//! Threading inside one right-hand-side call (native targets only; the wasm
//! build compiles none of this and runs every instruction serially).
//!
//! A call borrows the immutable program and its own executor state, so it can
//! fork-join across the threads of [`super::pool`] and return before anything
//! it borrowed goes away. Nothing crosses calls: the solve's closures stay on
//! one thread.
//!
//! What splits is chosen so that a threaded call is bit-identical to the
//! serial one. Every split divides INDEPENDENT output elements between
//! workers, and each element is computed by the same kernels in the same
//! order as on the serial path; no fold (an absorbed reduction's per-cell
//! fold, a scan, a `Reduce`) is ever divided. Work below a floor stays on the
//! calling thread, so a small call pays nothing for the threading.
//!
//! The thread budget is the caller's rayon thread count
//! (`rayon::current_num_threads`: the global pool's size, which
//! `RAYON_NUM_THREADS` sets, or the size of the pool the caller runs in), so
//! a caller already running inside a one-thread pool, or setting
//! `RAYON_NUM_THREADS=1`, gets the serial executor.

use super::fused::{IndexTable, RunCursor, Window, n_scans, n_shifted, run_fused_window};
use super::pool;
use super::resolve::rm_strides;
use super::*;

/// Estimated element-operations per worker a call's continuous section must
/// have before the call splits.
const MIN_WORK_PER_WORKER: usize = 1 << 14;

/// Elements each worker must get for one instruction to split.
const MIN_ELEMS_PER_WORKER: usize = 1024;

/// Accumulator cells each worker of a split reduction must own at least.
const REDUCE_CELLS_PER_WORKER: usize = 64;

/// [`REDUCE_CELLS_PER_WORKER`], or 1 while a test forces splits.
fn reduce_cells_floor() -> usize {
    #[cfg(test)]
    if FORCE.with(std::cell::Cell::get).is_some() {
        return 1;
    }
    REDUCE_CELLS_PER_WORKER
}

/// Window boundaries are rounded to this many elements, so two workers never
/// write the same cache line of an output.
const ALIGN: usize = 8;

/// The split width of one call: how many workers every large instruction of
/// the call is divided between (1 = the call runs serially). One width per
/// call, not per instruction, so instructions over the same box cut it at the
/// same places and each worker keeps re-reading the part of it that it wrote
/// (already in its own cache) instead of pulling lines from another core.
pub(super) fn call_ways(call_work: usize) -> usize {
    #[cfg(test)]
    if let Some(w) = FORCE.with(std::cell::Cell::get) {
        return w;
    }
    let threads = rayon::current_num_threads();
    if threads <= 1 {
        return 1;
    }
    threads.min(call_work / MIN_WORK_PER_WORKER).max(1)
}

/// The workers an instruction over `n` independent elements splits across
/// under call width `ways`: all of them, or none when `n` is too small to
/// give each its share.
pub(super) fn ways_for(n: usize, ways: usize) -> usize {
    #[cfg(test)]
    if FORCE.with(std::cell::Cell::get).is_some() {
        return ways.min(n).max(1);
    }
    if ways > 1 && n >= ways * MIN_ELEMS_PER_WORKER {
        ways
    } else {
        1
    }
}

/// The estimated element-operations of one call's continuous section, the
/// part every steady call runs (see [`call_ways`]).
pub(super) fn program_work(prog: &TapeProgram) -> usize {
    let start = (prog.n_const + prog.n_segment) as usize;
    let mut work: usize = prog
        .state_vars
        .iter()
        .map(|sv| sv.shape.iter().product::<usize>())
        .sum();
    for ins in &prog.instrs[start..] {
        work = work.saturating_add(match ins {
            Instr::Fused { spec } => {
                let fs = &prog.fused[*spec as usize];
                fs.shape
                    .iter()
                    .product::<usize>()
                    .saturating_mul(fused_cost(fs))
            }
            Instr::DyWrite { write } => {
                prog.slots[prog.dy_writes[*write as usize].slot as usize].elems()
            }
            Instr::Bin { out, .. }
            | Instr::Un { out, .. }
            | Instr::Neg { out, .. }
            | Instr::Select { out, .. }
            | Instr::Gather { out, .. }
            | Instr::Copy { out, .. }
            | Instr::IndexGather { out, .. }
            | Instr::TableGather { out, .. }
            | Instr::Scan { out, .. } => prog.slots[*out as usize].elems(),
            Instr::Lanes { spec } => {
                let ls = &prog.lanes[*spec as usize];
                (ls.lanes as usize).saturating_mul(ls.micro.len() + ls.inputs.len() + 1)
            }
            _ => 0,
        });
    }
    work
}

/// Operations per element of a fused group: its micro-ops, strided loads and
/// stores.
fn fused_cost(fs: &FusedSpec) -> usize {
    let loads = fs
        .inputs
        .iter()
        .filter(|i| i.load_reg != GroupIx::MAX)
        .count();
    fs.micro.len() + fs.outputs.len() + loads + 1
}

/// How many workers a fused group splits across under call width `ways`:
/// over its elements, or over its absorbed reduction's inner positions (each
/// folded whole by one worker, so every fold keeps its order).
///
/// A group with an absorbed scan carries the scan's running value along each
/// row, so it splits only at row starts (where the scan restarts), and not
/// at all when it also folds a reduction.
pub(super) fn split_ways(fs: &FusedSpec, ways: usize) -> usize {
    let n: usize = fs.shape.iter().product();
    match (&fs.reduce, scan_row(fs)) {
        (Some(_), Some(_)) => 1,
        // Every worker folds whole cells, so the split needs only enough
        // cells per worker to own whole cache lines, while the work is all
        // of the group's elements.
        (Some(r), None) if r.n_inner >= ways * reduce_cells_floor() => ways_for(n, ways),
        (Some(_), None) => 1,
        (None, Some(row)) if n / row < ways => 1,
        (None, _) => ways_for(n, ways),
    }
}

/// The flat period a group's absorbed scans restart at, `row * post` (every
/// lane at its first step; the least common multiple when several differ),
/// or `None` without a scan.
fn scan_row(fs: &FusedSpec) -> Option<usize> {
    fn gcd(a: usize, b: usize) -> usize {
        if b == 0 { a } else { gcd(b, a % b) }
    }
    fs.micro
        .iter()
        .filter_map(|m| match m {
            MicroOp::Scan { row, post, .. } => Some((*row as usize * *post as usize).max(1)),
            _ => None,
        })
        .reduce(|a, b| a / gcd(a, b) * b)
}

/// [`super::kernels::copy_strided`], split across the pool under call width
/// `call` when the box is large (pure data movement, so any split is exact).
/// It splits the axis with the largest destination stride, so each worker
/// writes whole cache lines of its own and none are shared.
///
/// # Safety
/// As for `copy_strided`.
pub(super) unsafe fn copy_strided(
    call: usize,
    dst: *mut f64,
    dstr: &[i64],
    src: *const f64,
    sstr: &[i64],
    shape: &[usize],
) {
    let tot: usize = shape.iter().product();
    let axis = (0..shape.len())
        .filter(|&d| shape[d] > 1)
        .max_by_key(|&d| dstr[d].unsigned_abs());
    let ways = match axis {
        Some(d) => ways_for(tot, call).min(shape[d]),
        None => 1,
    };
    let Some(d) = axis.filter(|_| ways > 1) else {
        unsafe { super::kernels::copy_strided(dst, dstr, src, sstr, shape) };
        return;
    };
    let (dp, sp) = (SendPtr(dst), SendPtr(src as *mut f64));
    let rm = rm_strides(shape);
    if dstr[..] == rm[..] && sstr[..] == rm[..] {
        // A contiguous copy is cut where a fused group over the same box is
        // (`share`), so each worker copies what it computed.
        pool::run(ways, &move |w| {
            let (dp, sp) = (dp, sp);
            let (a, b) = share(tot, w, ways);
            if a < b {
                unsafe { std::ptr::copy_nonoverlapping(sp.0.add(a), dp.0.add(a), b - a) };
            }
        });
        return;
    }
    let rows = shape[d];
    pool::run(ways, &move |w| {
        let (dp, sp) = (dp, sp);
        let (a, b) = (rows * w / ways, rows * (w + 1) / ways);
        if a >= b {
            return;
        }
        let mut part: DimU = shape.iter().copied().collect();
        part[d] = b - a;
        unsafe {
            super::kernels::copy_strided(
                dp.0.offset(a as isize * dstr[d] as isize),
                dstr,
                sp.0.offset(a as isize * sstr[d] as isize) as *const f64,
                sstr,
                &part,
            )
        };
    });
}

/// A raw pointer a split hands its workers.
#[derive(Clone, Copy)]
struct SendPtr(*mut f64);

// SAFETY: every split divides the addressed box between workers, so no two
// workers touch the same element, and the box outlives the fork-join.
unsafe impl Send for SendPtr {}
unsafe impl Sync for SendPtr {}

/// The `[lo, hi)` share of `n` elements worker `w` of `ways` takes.
pub(super) fn share(n: usize, w: usize, ways: usize) -> (usize, usize) {
    share_aligned(n, w, ways, ALIGN)
}

/// [`share`] with the cuts rounded down to multiples of `align`.
fn share_aligned(n: usize, w: usize, ways: usize, align: usize) -> (usize, usize) {
    let cut = |k: usize| {
        if k == ways {
            n
        } else {
            ((n as u128 * k as u128 / ways as u128) as usize / align * align).min(n)
        }
    };
    (cut(w), cut(w + 1))
}

/// One worker's private state for a split fused group.
struct FusedWorker {
    fregs: Vec<f64>,
    cursor: RunCursor,
}

/// The workers a program's split fused groups run on, sized for its largest
/// group. Grown (the only allocation) the first time a call splits wider than
/// before, so steady calls allocate nothing.
pub(in crate::simulate_array::tape) struct FusedWorkers {
    /// The current call's split width ([`call_ways`]), set at its start.
    pub(super) call_ways: usize,
    workers: Vec<FusedWorker>,
    fregs_len: usize,
    depth: usize,
    shifted: usize,
    scans: usize,
}

/// The resolved operands of one group, shared read-only by its workers.
#[derive(Clone, Copy)]
struct Shared<'a> {
    fs: &'a FusedSpec,
    svals: &'a [f64],
    bases: &'a [*const f64],
    outs: &'a [(GroupIx, *mut f64)],
    red: *mut f64,
    idx: &'a [Option<IndexTable>],
    node_elems: &'a [usize],
    simd: SimdLevel,
    precision: crate::precision::Precision,
}

// SAFETY: the pointers address the slab, the state and the observed arrays,
// which outlive the fork-join that uses them. Workers only read through
// `bases`, and write through `outs` and `red` only at the positions of their
// own window, which no other worker's window contains.
unsafe impl Send for Shared<'_> {}
unsafe impl Sync for Shared<'_> {}

impl FusedWorkers {
    pub(super) fn for_program(prog: &TapeProgram) -> Self {
        let most = |f: fn(&FusedSpec) -> usize| prog.fused.iter().map(f).max().unwrap_or(0);
        FusedWorkers {
            call_ways: 1,
            workers: Vec::new(),
            fregs_len: most(|f| {
                f.n_regs as usize + f.n_load_regs as usize + f.n_splat_regs as usize
            }) * super::fused::FCHUNK,
            depth: most(|f| f.schedule.depth),
            shifted: most(n_shifted),
            scans: most(n_scans),
        }
    }

    /// Run fused group `fs` split into `ways` windows, one per worker.
    ///
    /// # Safety
    /// As for [`run_fused_window`]: `bases` and `outs` must be the group's
    /// resolved operands, valid for its whole box.
    #[allow(clippy::too_many_arguments)]
    pub(super) unsafe fn run_split(
        &mut self,
        fs: &FusedSpec,
        svals: &[f64],
        bases: &[*const f64],
        outs: &[(GroupIx, *mut f64)],
        red: *mut f64,
        idx: &[Option<IndexTable>],
        node_elems: &[usize],
        simd: SimdLevel,
        ways: usize,
    ) {
        while self.workers.len() < ways {
            self.workers.push(FusedWorker {
                fregs: vec![0.0f64; self.fregs_len],
                cursor: RunCursor::with_room(self.depth, self.shifted, self.scans),
            });
        }
        // A reduction splits its inner positions: worker `w` takes the same
        // `[lo, hi)` of them at every leading position, so the accumulator
        // cells each worker folds into are its own.
        let (n, period) = match &fs.reduce {
            Some(r) => (r.n_inner, r.n_inner),
            None => (fs.shape.iter().product(), 0),
        };
        // Row starts, for a group with an absorbed scan (see `split_ways`).
        let align = scan_row(fs).map_or(ALIGN, |row| row);
        let sh = Shared {
            fs,
            svals,
            bases,
            outs,
            red,
            idx,
            node_elems,
            simd,
            precision: crate::precision::active(),
        };
        let ws = WorkersPtr(self.workers.as_mut_ptr());
        pool::run(ways, &move |w| {
            let (sh, ws) = (sh, ws);
            let (lo, hi) = share_aligned(n, w, ways, align);
            if lo >= hi {
                return;
            }
            // SAFETY: share `w` runs exactly once per dispatch, so each
            // worker state has one user.
            let wk = unsafe { &mut *ws.0.add(w) };
            // The caller's precision is thread-local; carry it over.
            let _p = crate::precision::enter(sh.precision);
            unsafe {
                run_fused_window(
                    sh.simd,
                    sh.fs,
                    sh.svals,
                    sh.bases,
                    sh.outs,
                    sh.red,
                    sh.idx,
                    &mut wk.fregs,
                    &mut wk.cursor,
                    Window {
                        lo,
                        hi,
                        period,
                        node_elems: sh.node_elems,
                    },
                )
            }
        });
    }
}

/// The worker states of a split, indexed by share.
#[derive(Clone, Copy)]
struct WorkersPtr(*mut FusedWorker);

// SAFETY: see the use in `run_split`.
unsafe impl Send for WorkersPtr {}
unsafe impl Sync for WorkersPtr {}

#[cfg(test)]
thread_local! {
    /// Test hook: split every call this wide, whatever its size.
    static FORCE: std::cell::Cell<Option<usize>> = const { std::cell::Cell::new(None) };
}

/// Test hook: make this thread's calls split `ways` wide regardless of size
/// and thread budget (`None` restores the measured choice).
#[cfg(test)]
pub(crate) fn force_split(ways: Option<usize>) {
    FORCE.with(|c| c.set(ways));
}
