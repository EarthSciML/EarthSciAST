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

use super::fused::{
    IndexTable, PAD_BYTES, RunCursor, Window, fill_whole, n_scans, n_shifted, run_fused_window,
    seeds_itself,
};
use super::pool;
use super::resolve::{Rv, rm_strides};
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

/// Elements per cache line: window boundaries fall on cache-line boundaries
/// of the output they are cut for (see [`share_at`]), so two workers never
/// write the same line of it.
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

/// Lanes each worker of a split lane program must get.
const MIN_LANES_PER_WORKER: usize = 32;

/// The workers a lane program of `lanes` lanes, each `cost` operations,
/// splits across under call width `ways`: all of them when every worker gets
/// enough lanes and enough work, else none. A lane is a whole scalar
/// program, so a few hundred lanes are already a large split.
pub(super) fn lane_ways(lanes: usize, cost: usize, ways: usize) -> usize {
    #[cfg(test)]
    if FORCE.with(std::cell::Cell::get).is_some() {
        return ways.min(lanes).max(1);
    }
    if ways > 1
        && lanes >= ways * MIN_LANES_PER_WORKER
        && lanes.saturating_mul(cost) >= ways * MIN_WORK_PER_WORKER
    {
        ways
    } else {
        1
    }
}

/// The operations of one lane of `ls`: its micro-ops, input gathers and
/// writes.
pub(super) fn lane_cost(ls: &LaneSpec) -> usize {
    ls.micro.len() + ls.inputs.len() + ls.writes.len()
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
                (ls.lanes as usize).saturating_mul(lane_cost(ls) + 1)
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
    if ways <= 1 {
        return 1;
    }
    let n: usize = fs.shape.iter().product();
    let by_work = |n: usize| fused_ways(n, || fused_cost(fs), ways);
    match (&fs.reduce, scan_row(fs)) {
        (Some(_), Some(_)) => 1,
        // Every worker folds whole cells, so the split needs only enough
        // cells per worker to own whole cache lines, while the work is all
        // of the group's elements.
        (Some(r), None) if r.n_inner >= ways * reduce_cells_floor() => by_work(n),
        (Some(_), None) => 1,
        (None, Some(row)) if n / row < ways => 1,
        (None, _) => by_work(n),
    }
}

/// Elements each worker of a split fused group must get: a few chunks'
/// worth of cache lines, so the window cuts stay small against the windows.
const MIN_FUSED_ELEMS_PER_WORKER: usize = 64;

/// The workers a fused group of `n` elements, `cost` operations each, splits
/// across under call width `ways`: all of them when [`ways_for`] splits its
/// elements, or when every worker still gets [`MIN_FUSED_ELEMS_PER_WORKER`]
/// elements and [`MIN_WORK_PER_WORKER`] operations; else none. So a cheap
/// group over many elements splits as before (every large pass of a call cut
/// the same way, see [`call_ways`]), and an expensive group over fewer
/// elements, a mechanism over a thousand cells, splits too.
fn fused_ways(n: usize, cost: impl Fn() -> usize, ways: usize) -> usize {
    #[cfg(test)]
    if FORCE.with(std::cell::Cell::get).is_some() {
        return ways.min(n).max(1);
    }
    if ways_for(n, ways) > 1
        || ways > 1
            && n >= ways * MIN_FUSED_ELEMS_PER_WORKER
            && n.saturating_mul(cost()) >= ways * MIN_WORK_PER_WORKER
    {
        ways
    } else {
        1
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
            let (a, b) = share_at(tot, w, ways, dp.0);
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

/// One resolved part of a split `makearray` assembly: its region (an index
/// into `TapeProgram::regions`), the flat offset of the region's first
/// element in the output box, and its source.
pub(in crate::simulate_array::tape) struct AsmPart {
    region: u32,
    dbase: i64,
    src: Rv,
}

impl AsmPart {
    pub(super) fn new(region: u32, dbase: i64, src: Rv) -> Self {
        AsmPart { region, dbase, src }
    }
}

/// `Instr::Assemble` split across the pool under width `ways`: worker `w`
/// writes the flat positions [`share`]`(n, w, ways)` of the row-major output
/// box -- zeroed unless `covered`, then each part's elements that fall there,
/// in part order, so a later region still overwrites an earlier one. Pure
/// data movement, so the result is the serial assembly's, bit for bit.
///
/// # Safety
/// `dst` must address the whole output box `shape`, and every part's source
/// must be valid over its region.
pub(super) unsafe fn assemble(
    ways: usize,
    dst: *mut f64,
    shape: &[usize],
    regions: &[RegionSpec],
    parts: &[AsmPart],
    covered: bool,
) {
    let n: usize = shape.iter().product();
    let out_rm = rm_strides(shape);
    let sh = AsmShared {
        dst: SendPtr(dst),
        regions,
        parts,
        out_rm: &out_rm,
        n,
        covered,
    };
    pool::run(ways, &move |w| {
        let sh = &sh;
        let (lo, hi) = share_at(sh.n, w, ways, sh.dst.0);
        if lo < hi {
            unsafe { assemble_window(sh, lo, hi) };
        }
    });
}

/// A split assembly, shared read-only by its workers.
struct AsmShared<'a> {
    dst: SendPtr,
    regions: &'a [RegionSpec],
    parts: &'a [AsmPart],
    out_rm: &'a [i64],
    n: usize,
    covered: bool,
}

// SAFETY: the sources are only read, and each worker writes only the output
// positions of its own share.
unsafe impl Sync for AsmShared<'_> {}

/// The output positions `[lo, hi)` of a split assembly.
unsafe fn assemble_window(sh: &AsmShared, lo: usize, hi: usize) {
    let dst = sh.dst.0;
    if !sh.covered {
        unsafe { std::slice::from_raw_parts_mut(dst.add(lo), hi - lo).fill(0.0) };
    }
    for part in sh.parts {
        let rsh = &sh.regions[part.region as usize].shape;
        if rsh.contains(&0) {
            continue;
        }
        let sstr: &[i64] = match &part.src {
            Rv::V { strides, .. } => strides,
            Rv::S(_) => &[],
        };
        // The region's axes longer than 1: the last is walked as rows (one
        // output stride apart), the others as an odometer over rows. Unit
        // axes are fixed in `dbase`.
        let axes: DimU = (0..rsh.len()).filter(|&d| rsh[d] > 1).collect();
        let db = part.dbase as usize;
        let (row_ax, lead) = match axes.split_last() {
            Some((&r, lead)) => (Some(r), lead),
            None => (None, &[][..]),
        };
        let (len, ds, ss) = match row_ax {
            Some(r) => (
                rsh[r],
                sh.out_rm[r] as usize,
                sstr.get(r).copied().unwrap_or(0) as isize,
            ),
            None => (1, 1, 0),
        };
        // Positions with first-walked index `i` lie in `[db + i s, db +
        // (i + 1) s)` (`s` the output stride of that axis, every axis before
        // it fixed), so only the indices in `[i0, i1)` reach the share.
        let (i0, i1) = match lead.first() {
            None => (0, 1),
            Some(&a0) => {
                let s0 = sh.out_rm[a0] as usize;
                let i1 = if hi > db { (hi - db).div_ceil(s0) } else { 0 };
                (lo.saturating_sub(db) / s0, i1.min(rsh[a0]))
            }
        };
        if i0 >= i1 {
            continue;
        }
        let mut idx: DimU = SmallVec::from_elem(0, lead.len());
        if let Some(i) = idx.first_mut() {
            *i = i0;
        }
        loop {
            let mut f = db;
            let mut soff = 0isize;
            for (k, &a) in lead.iter().enumerate() {
                f += idx[k] * sh.out_rm[a] as usize;
                soff += sstr.get(a).copied().unwrap_or(0) as isize * idx[k] as isize;
            }
            // The row's elements `k` with `f + k ds` in `[lo, hi)`.
            let k0 = if f >= lo { 0 } else { (lo - f).div_ceil(ds) };
            let k1 = if hi > f {
                (hi - f).div_ceil(ds).min(len)
            } else {
                0
            };
            if k0 < k1 {
                let out = unsafe { dst.add(f + k0 * ds) };
                let n = k1 - k0;
                match &part.src {
                    Rv::S(v) => {
                        for k in 0..n {
                            unsafe { *out.add(k * ds) = *v };
                        }
                    }
                    Rv::V { ptr, .. } => {
                        let p = unsafe { ptr.offset(soff + k0 as isize * ss) };
                        if ds == 1 && ss == 1 {
                            unsafe { std::ptr::copy_nonoverlapping(p, out, n) };
                        } else {
                            for k in 0..n {
                                unsafe { *out.add(k * ds) = *p.offset(k as isize * ss) };
                            }
                        }
                    }
                }
            }
            // Next row: the inner walked axes fastest, the first bounded by
            // `i1`.
            let mut k = lead.len();
            let more = loop {
                if k == 0 {
                    break false;
                }
                k -= 1;
                idx[k] += 1;
                let end = if k == 0 { i1 } else { rsh[lead[k]] };
                if idx[k] < end {
                    break true;
                }
                if k == 0 {
                    break false;
                }
                idx[k] = 0;
            };
            if !more {
                break;
            }
        }
    }
}

/// A raw pointer a split hands its workers.
#[derive(Clone, Copy)]
struct SendPtr(*mut f64);

// SAFETY: every split divides the addressed box between workers, so no two
// workers touch the same element, and the box outlives the fork-join.
unsafe impl Send for SendPtr {}
unsafe impl Sync for SendPtr {}

/// The `[lo, hi)` share of the `n` elements at `at` that worker `w` of `ways`
/// takes: cut where `at + cut` starts a cache line, so workers that write
/// their shares never write a common line. That matters most for an
/// absorbed reduction, whose workers write their accumulator cells once per
/// leading position: a line two of them shared would move between their
/// cores every time.
pub(super) fn share_at(n: usize, w: usize, ways: usize, at: *const f64) -> (usize, usize) {
    let phase = (at as usize / std::mem::size_of::<f64>()) % ALIGN;
    let cut = |k: usize| {
        if k == ways {
            n
        } else {
            let c = (n as u128 * k as u128 / ways as u128) as usize;
            ((c + phase) / ALIGN * ALIGN).saturating_sub(phase).min(n)
        }
    };
    (cut(w), cut(w + 1))
}

/// The share of worker `w` with every cut a multiple of `align` (a scan's
/// restart period).
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

/// One worker's private state for a split fused group, on cache lines of its
/// own (the cursor's lengths change as the worker walks).
#[repr(align(128))]
struct FusedWorker {
    fregs: Vec<f64>,
    cursor: RunCursor,
    /// The worker's own accumulator cells of a split reduction, copied to
    /// the shared accumulator when its window is done.
    acc: Vec<f64>,
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
    whole_src: &'a [*const f64],
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
    /// resolved operands, valid for its whole box; `whole_src` as for
    /// [`fill_whole`] (each worker reads its own window of them).
    #[allow(clippy::too_many_arguments)]
    pub(super) unsafe fn run_split(
        &mut self,
        fs: &FusedSpec,
        svals: &[f64],
        bases: &[*const f64],
        whole_src: &[*const f64],
        outs: &[(GroupIx, *mut f64)],
        red: *mut f64,
        idx: &[Option<IndexTable>],
        node_elems: &[usize],
        simd: SimdLevel,
        ways: usize,
    ) {
        while self.workers.len() < ways {
            self.workers.push(FusedWorker {
                fregs: padded(self.fregs_len),
                cursor: RunCursor::for_worker(self.depth, self.shifted, self.scans),
                acc: Vec::new(),
            });
        }
        // A reduction splits its inner positions: worker `w` takes the same
        // `[lo, hi)` of them at every leading position, so the accumulator
        // cells each worker folds into are its own.
        let (n, period) = match &fs.reduce {
            Some(r) => (r.n_inner, r.n_inner),
            None => (fs.shape.iter().product(), 0),
        };
        // Row starts, for a group with an absorbed scan (see `split_ways`);
        // else cache lines of the accumulator or the first output.
        let row = scan_row(fs);
        let anchor = match outs.first() {
            _ if !red.is_null() => red as usize,
            Some(&(_, p)) => p as usize,
            None => 0,
        };
        let cut = |w: usize| match row {
            Some(row) => share_aligned(n, w, ways, row),
            None => share_at(n, w, ways, anchor as *const f64),
        };
        // Each worker of a split reduction folds into cells of its own, in
        // memory no other worker writes: folding into adjacent ranges of
        // the shared accumulator lets the hardware prefetchers pull a
        // neighbour's lines away from it every leading position.
        let init = fs.reduce.as_ref().map(|r| r.init);
        let seeded = seeds_itself(fs);
        if init.is_some() {
            for (w, wk) in self.workers[..ways].iter_mut().enumerate() {
                let (lo, hi) = cut(w);
                if wk.acc.len() < hi.saturating_sub(lo) {
                    wk.acc = padded(hi - lo);
                }
            }
        }
        let sh = Shared {
            fs,
            svals,
            bases,
            whole_src,
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
            let (lo, hi) = cut(w);
            if lo >= hi {
                return;
            }
            // SAFETY: share `w` runs exactly once per dispatch, so each
            // worker state has one user.
            let wk = unsafe { &mut *ws.0.add(w) };
            // The caller's precision is thread-local; carry it over.
            let _p = crate::precision::enter(sh.precision);
            // A reduction's cells `[lo, hi)` live in the worker's own buffer,
            // addressed as if it started at cell 0.
            let red = match init {
                Some(init) => {
                    let acc = &mut wk.acc[..hi - lo];
                    if !seeded {
                        acc.fill(init);
                    }
                    acc.as_mut_ptr().wrapping_sub(lo)
                }
                None => sh.red,
            };
            unsafe {
                fill_whole(sh.fs, sh.bases, sh.whole_src, lo, hi, period);
                run_fused_window(
                    sh.simd,
                    sh.fs,
                    sh.svals,
                    sh.bases,
                    sh.outs,
                    red,
                    sh.idx,
                    &mut wk.fregs,
                    &mut wk.cursor,
                    Window {
                        lo,
                        hi,
                        period,
                        node_elems: sh.node_elems,
                    },
                );
                if init.is_some() {
                    std::ptr::copy_nonoverlapping(wk.acc.as_ptr(), sh.red.add(lo), hi - lo);
                }
            }
        });
    }
}

/// A zeroed register file of `len` for one worker, with [`PAD_BYTES`] of
/// unused room past its end (see [`RunCursor::for_worker`]).
pub(super) fn padded(len: usize) -> Vec<f64> {
    let mut v = Vec::with_capacity(len + PAD_BYTES / std::mem::size_of::<f64>());
    v.resize(len, 0.0);
    v
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
