//! A segmented reduction split across the pool together with the
//! elementwise work around it, in one dispatch (native targets only).
//!
//! A tuple-list contraction ([`Instr::SegReduce`]) is usually a short run of
//! instructions over its tuples (the gather of a state at each tuple's
//! source, the product with a weight) followed by the reduction into its
//! output cells and a fused group over those cells. Each is a few thousand
//! elements at most, far below the per-instruction split floor, and splitting
//! each on its own would pay one fork-join per instruction. So the run is
//! split once, by output cell: worker `w` takes the cells `[c0, c1)`, runs
//! every tuple instruction over the tuples those cells fold (`rows[c0] ..
//! rows[c1]`), folds its cells, and runs the fused group over the same
//! cells. Nothing a worker reads was written by another worker, every
//! element sees the same kernel as on the serial path, and every cell is
//! folded whole in its own order, so a split call is bit-identical to the
//! serial one. A serial call runs the chain as one share, which lets a
//! gather-product-sum run as a single pass (see `SumOfProducts`).

use super::fused::{
    FusedScratch, Group, Window, dispatch_bin_kernel, dispatch_un_kernel, fill_whole,
    resolve_fused, run_fused_window,
};
use super::interp::Cx;
use super::kernels::{ew1, ew2, seg_reduce, table_gather};
use super::par::FusedWorkers;
use super::resolve::{Rv, Slab, SrcView};
use super::*;

/// Element-operations each worker of a split chain must get.
const MIN_CHAIN_WORK_PER_WORKER: usize = 1 << 10;

/// Element-operations the calling thread runs before the pool's workers
/// start theirs.
const CHAIN_LEAD_WORK: usize = 1 << 13;

pub(super) use crate::simulate_array::tape::prepared::chains::SegChain;

/// A tuple instruction's operand, resolved for one call.
#[derive(Clone, Copy)]
enum Arg {
    S(f64),
    /// The operand's tuple box, contiguous.
    P(*const f64),
}

/// A tuple instruction, resolved for one call.
#[derive(Clone, Copy)]
enum Op {
    Table {
        dst: *mut f64,
        src: *const f64,
        pos: *const u32,
    },
    Bin {
        op: BinCode,
        dst: *mut f64,
        a: Arg,
        b: Arg,
    },
    Un {
        op: UnCode,
        dst: *mut f64,
        a: Arg,
    },
    Neg {
        dst: *mut f64,
        a: Arg,
    },
}

/// A chain whose tuple instructions are a gather `t1 = src[pos]` and a
/// product `t2 = t1 * w` (either operand order) summed by the reduction:
/// the sparse product a tuple-list contraction usually is. Run as one pass
/// per output cell, each tuple gathered, multiplied, stored to `t1` and `t2`
/// and added in turn: the same operations on the same operands in the same
/// order as the three passes, without two of the round trips through
/// memory.
#[derive(Clone, Copy)]
struct SumOfProducts {
    src: *const f64,
    pos: *const u32,
    t1: *mut f64,
    t2: *mut f64,
    /// The product's other operand.
    w: Arg,
    /// Whether the gathered value is the product's left operand.
    gather_first: bool,
    /// Whether the sum is seeded with `+0.0`.
    zero_seed: bool,
    /// Whether `t1` and `t2` are stored (they are not when nothing else
    /// reads them).
    store: bool,
}

impl SumOfProducts {
    fn of(
        ops: &[Op],
        seg_op: BinCode,
        init: f64,
        seg_src: *const f64,
        mask: Option<*const f64>,
        private: bool,
    ) -> Option<Self> {
        if seg_op != BinCode::Add || crate::precision::is_f32() {
            return None;
        }
        let [
            Op::Table { dst: t1, src, pos },
            Op::Bin {
                op: BinCode::Mul,
                dst: t2,
                a,
                b,
            },
        ] = *ops
        else {
            return None;
        };
        let is_t1 = |x: Arg| matches!(x, Arg::P(p) if std::ptr::eq(p, t1));
        if !std::ptr::eq(t2, seg_src) || !(is_t1(a) || is_t1(b)) {
            return None;
        }
        let gather_first = is_t1(a);
        let w = if gather_first { b } else { a };
        // An operand read back from `t1` or `t2` needs them stored.
        let reads_back = |p: *const f64| std::ptr::eq(p, t1) || std::ptr::eq(p, t2);
        let read_back = matches!(w, Arg::P(p) if reads_back(p)) || mask.is_some_and(reads_back);
        Some(SumOfProducts {
            src,
            pos,
            t1,
            t2,
            w,
            gather_first,
            zero_seed: init.to_bits() == 0,
            store: !private || read_back,
        })
    }

    /// Cells `rows.len() - 1` from `dst`, their tuples `rows[0] ..
    /// rows[last]`.
    ///
    /// # Safety
    /// As for the three instructions it replaces.
    unsafe fn run(&self, rows: &[u32], mask: Option<*const f64>, init: f64, dst: *mut f64) {
        let w = |k: usize| match self.w {
            Arg::S(v) => v,
            Arg::P(p) => unsafe { *p.add(k) },
        };
        for c in 0..rows.len() - 1 {
            let mut acc = init;
            for k in rows[c] as usize..rows[c + 1] as usize {
                unsafe {
                    let p = *self.pos.add(k);
                    let g = if p == GATHER_GHOST {
                        0.0
                    } else {
                        *self.src.add(p as usize)
                    };
                    if self.store {
                        *self.t1.add(k) = g;
                    }
                    // The operand order is kept: a product of two NaNs takes the first's
                    // payload.
                    #[allow(clippy::if_same_then_else)]
                    let v = if self.gather_first {
                        g * w(k)
                    } else {
                        w(k) * g
                    };
                    if self.store {
                        *self.t2.add(k) = v;
                    }
                    match mask {
                        // A masked term adds `+0.0`, which leaves `acc` as
                        // it is: a sum seeded with `+0.0` is never `-0.0`
                        // (round-to-nearest gives `-0.0` only for two
                        // `-0.0` operands), and every other value plus
                        // `+0.0` is itself. So the select stays off the
                        // accumulator's dependency chain.
                        Some(m) if self.zero_seed => {
                            acc += if *m.add(k) != 0.0 { v } else { 0.0 };
                        }
                        Some(m) => {
                            if *m.add(k) != 0.0 {
                                acc += v;
                            }
                        }
                        None => acc += v,
                    }
                }
            }
            unsafe { *dst.add(c) = acc };
        }
    }
}

/// The resolved tuple instructions of the chain being run, kept across
/// calls so steady calls do not allocate.
#[derive(Default)]
pub(in crate::simulate_array::tape) struct ChainScratch {
    ops: Vec<Op>,
    /// The tuple slots a private chain keeps in `tmp` (see [`Job::bufs`]).
    bufs: Vec<(*const f64, usize)>,
    /// Every worker's block buffers, `Job::tmp_stride` apart.
    tmp: Vec<f64>,
    /// Per chain, its admitted tuples (see [`CompactPlan`]), or `None`.
    compact: Vec<Option<Compacted>>,
}

// SAFETY: `ops` and `bufs` hold addresses into the slab of the call that
// resolved them. Each chain run clears and rebuilds them before it reads one,
// and nothing reads them after the call returns, so moving the scratch to
// another thread between calls cannot carry a live borrow with it.
unsafe impl Send for ChainScratch {}

/// A chain's tuples the mask admits, as of the last prime: per output cell
/// `rows[c] .. rows[c + 1]`, each with its gather position and, when the
/// product's other operand is a tuple slot, its weight.
#[derive(Default)]
struct Compacted {
    rows: Vec<u32>,
    pos: Vec<u32>,
    w: Vec<f64>,
}

/// Rebuild every compacted chain's admitted tuples from the mask and weights
/// the CONST and SEGMENT sections just wrote. Allocates only the first time.
///
/// # Safety
/// The CONST and SEGMENT sections of this program must have run, and
/// nothing may be writing the slab.
pub(super) unsafe fn refill_compact(
    chains: &[SegChain],
    scratch: &mut ChainScratch,
    prog: &TapeProgram,
    slab: Slab,
) {
    if scratch.compact.len() != chains.len() {
        scratch.compact.clear();
        scratch.compact.resize_with(chains.len(), || None);
    }
    for ch in chains {
        let Some(plan) = ch.compact else { continue };
        let Instr::SegReduce { table, .. } = &prog.instrs[ch.seg] else {
            unreachable!("a chain's reduction is a SegReduce")
        };
        let rows = &prog.tables.seg_tables[*table as usize].rows;
        let n_pairs = *rows.last().expect("a planned chain has cells") as usize;
        let read = |s: SlotId| unsafe { std::slice::from_raw_parts(slab.slot(s), n_pairs) };
        let mask = read(plan.mask);
        let w = plan.w.map(read);
        let pos = &prog.tables.gather_tables[plan.table as usize].pos;
        let c = scratch.compact[ch.id].get_or_insert_with(|| Compacted {
            rows: Vec::with_capacity(rows.len()),
            pos: Vec::with_capacity(n_pairs),
            w: Vec::with_capacity(if w.is_some() { n_pairs } else { 0 }),
        });
        c.rows.clear();
        c.pos.clear();
        c.w.clear();
        c.rows.push(0);
        for r in rows.windows(2) {
            for k in r[0] as usize..r[1] as usize {
                // The predicate the masked fold applies.
                if mask[k] != 0.0 {
                    c.pos.push(pos[k]);
                    if let Some(w) = w {
                        c.w.push(w[k]);
                    }
                }
            }
            c.rows.push(c.pos.len() as u32);
        }
    }
}

/// The workers' view of one call's chain.
struct Job<'a> {
    ops: &'a [Op],
    rows: &'a [u32],
    seg_op: BinCode,
    init: f64,
    seg_src: *const f64,
    seg_mask: Option<*const f64>,
    seg_dst: *mut f64,
    n_out: usize,
    ways: usize,
    /// The cell group over the chain's output cells, resolved.
    fused: Option<Group<'a>>,
    /// The tuple instructions and the reduction as one pass, when they are
    /// a gather, a product and a sum.
    sop: Option<SumOfProducts>,
    /// The most tuples a block of cells holds.
    cap: usize,
    /// The cells share 0 takes beyond the others' (see [`cell_share`]).
    lead: usize,
    /// When nothing outside the chain reads its tuple slots: each slot the
    /// tuple instructions write, at tuple 0, with the first instruction
    /// that writes it. A worker keeps the slot's block in its own buffer
    /// `i` (`cap` long, at `tmp + w * tmp_stride + i * cap`) from that
    /// instruction on, so a block's tuple values never leave the cache.
    bufs: &'a [(*const f64, usize)],
    tmp: *mut f64,
    tmp_stride: usize,
    precision: crate::precision::Precision,
}

// SAFETY: the pointers address the slab, the state and `dy`, which outlive
// the fork-join; each worker writes only its own cells and their tuples
// (`disjoint` checked that those are nobody else's).
unsafe impl Sync for Job<'_> {}

/// A tuple instruction's operand for this call, as
/// [`resolve_rv`](super::resolve::resolve_rv) resolves
/// it against the tuple box (`seg_chains` admitted no other kind): a scalar,
/// or the start of a contiguous tuple-box array.
fn tuple_arg(o: &Operand, env: &Env, slab: Slab) -> Option<Arg> {
    Some(match o {
        Operand::Lit(v) => Arg::S(*v),
        Operand::Param(p) => Arg::S(env.params[*p as usize]),
        Operand::Time => Arg::S(env.t),
        Operand::Slot(s) => {
            let p = slab.slot(*s);
            if env.prog.tables.slots[*s as usize].scalar {
                // SAFETY: a tuple instruction's operand is not written while
                // the chain runs.
                Arg::S(unsafe { *p })
            } else {
                Arg::P(p)
            }
        }
        Operand::State(ix) => {
            let sv = &env.prog.state_vars[*ix as usize];
            if sv.shape.is_empty() {
                Arg::S(env.state[sv.flat_offset])
            } else {
                Arg::P(super::resolve::state_ptr(env, *ix))
            }
        }
    })
}

fn rv(a: Arg, lo: usize) -> Rv {
    match a {
        Arg::S(v) => Rv::S(v),
        Arg::P(p) => Rv::V {
            ptr: unsafe { p.add(lo) },
            strides: smallvec::smallvec![1],
        },
    }
}

/// The split width of `ch` for a call with `threads` threads.
fn chain_ways(ch: &SegChain, threads: usize) -> usize {
    if super::par::forced() {
        return threads.min(ch.n_out).max(1);
    }
    threads
        .min(ch.work / MIN_CHAIN_WORK_PER_WORKER)
        .min(ch.n_out / 8)
        .max(1)
}

/// Run chain `ch`, split across the pool when the call is wide enough, or
/// return `false` (having run nothing) when an operand cannot be resolved
/// as the chain needs it, so the instructions run one by one instead.
///
/// # Safety
/// `cx` must describe the current call, and every instruction before
/// `ch.start` of this
/// call already run.
pub(super) unsafe fn run_chain(
    ch: &SegChain,
    cx: &Cx,
    scratch: &mut ChainScratch,
    fscratch: &mut FusedScratch,
) -> bool {
    let Cx { env, slab, .. } = *cx;
    // A serial call runs the chain too (its one share on this thread): the
    // single pass below is quicker than the instructions one by one.
    let ways = chain_ways(ch, fscratch.workers.threads);
    let prog = env.prog;
    let Instr::SegReduce {
        op,
        init,
        src,
        mask,
        table,
        out,
    } = &prog.instrs[ch.seg]
    else {
        unreachable!("a chain's reduction is a SegReduce")
    };
    let rows = &prog.tables.seg_tables[*table as usize].rows[..];
    scratch.ops.clear();
    for ins in &prog.instrs[ch.start..ch.seg] {
        let at = |o: SlotId| slab.slot(o);
        let rvs = |o: &Operand| tuple_arg(o, env, slab);
        let op = match ins {
            Instr::TableGather { src, table, out } => Op::Table {
                dst: at(*out),
                src: match src {
                    SrcRef::Slot(s) => at(*s),
                    SrcRef::State(ix) => super::resolve::state_ptr(env, *ix),
                },
                pos: prog.tables.gather_tables[*table as usize].pos.as_ptr(),
            },
            Instr::Bin { op, a, b, out } => match (rvs(a), rvs(b)) {
                (Some(a), Some(b)) => Op::Bin {
                    op: *op,
                    dst: at(*out),
                    a,
                    b,
                },
                _ => return false,
            },
            Instr::Un { op, a, out } => match rvs(a) {
                Some(a) => Op::Un {
                    op: *op,
                    dst: at(*out),
                    a,
                },
                None => return false,
            },
            Instr::Neg { a, out } => match rvs(a) {
                Some(a) => Op::Neg { dst: at(*out), a },
                None => return false,
            },
            _ => unreachable!("chain tuple instructions are planned"),
        };
        scratch.ops.push(op);
    }
    let seg_src = slab.slot(*src) as *const f64;
    let seg_mask = mask.map(|m| slab.slot(m) as *const f64);
    let seg_dst = slab.slot(*out);
    let (group, workers) = match ch.fused {
        Some(spec) => {
            let (g, _cursor, w) = unsafe { resolve_fused(spec as usize, cx, fscratch) };
            (Some(g), w)
        }
        None => (None, &mut fscratch.workers),
    };
    let mut sop = SumOfProducts::of(&scratch.ops, *op, *init, seg_src, seg_mask, ch.private);
    let cap = ch.max_row.max(CHAIN_BLOCK);
    scratch.bufs.clear();
    if ch.private && sop.is_none() {
        for (j, op) in scratch.ops.iter().enumerate() {
            let dst = op.dst() as *const f64;
            if !scratch.bufs.iter().any(|&(p, _)| std::ptr::eq(p, dst)) {
                scratch.bufs.push((dst, j));
            }
        }
    }
    let tmp_stride = scratch.bufs.len() * cap;
    if scratch.tmp.len() < ways * tmp_stride {
        scratch.tmp.resize(ways * tmp_stride, 0.0);
    }
    let tmp = scratch.tmp.as_mut_ptr();
    let (mut rows, mut seg_mask) = (rows, seg_mask);
    // Fold only the admitted tuples. Dropping a masked term is exact: the
    // masked fold leaves the accumulator as it is for each (see
    // `SumOfProducts::run`), and the admitted ones keep their order.
    if let (Some(sp), Some(Some(c))) = (&mut sop, scratch.compact.get(ch.id))
        && !sp.store
    {
        sp.pos = c.pos.as_ptr();
        if ch.compact.is_some_and(|p| p.w.is_some()) {
            sp.w = Arg::P(c.w.as_ptr());
        }
        rows = &c.rows;
        seg_mask = None;
    }
    let job = Job {
        ops: &scratch.ops,
        rows,
        seg_op: *op,
        init: *init,
        seg_src,
        seg_mask,
        seg_dst,
        n_out: ch.n_out,
        ways,
        sop,
        cap,
        // A quarter of a share more, at most the cells of the work the
        // calling thread gets through while the workers wake.
        lead: (ch.n_out / (4 * ways + 1)).min(CHAIN_LEAD_WORK * ch.n_out / ch.work.max(1)),
        bufs: &scratch.bufs,
        tmp,
        tmp_stride,
        fused: group,
        precision: crate::precision::active(),
    };
    unsafe { run_job(workers, &job) };
    true
}

/// The output cells `[c0, c1)` of share `w` of `ways`, cut where `at + cut`
/// starts a cache line (as [`share_at`](super::par::share_at) cuts). Share 0
/// runs on the calling thread, which starts it as it publishes the job,
/// before any worker has seen it, so it takes `lead` more cells than each of
/// the others and all finish together.
fn cell_share(n: usize, lead: usize, w: usize, ways: usize, at: *const f64) -> (usize, usize) {
    const ALIGN: usize = 8;
    let phase = (at as usize / std::mem::size_of::<f64>()) % ALIGN;
    let cut = |k: usize| {
        if k == 0 {
            0
        } else if k == ways {
            n
        } else {
            let c = lead + (n - lead) * k / ways;
            ((c + phase) / ALIGN * ALIGN).saturating_sub(phase).min(n)
        }
    };
    (cut(w), cut(w + 1))
}

/// Run every share of `job` on the pool.
unsafe fn run_job(workers: &mut FusedWorkers, job: &Job) {
    workers.run_with_workers(job.ways, &|w, fregs, cursor| {
        let (c0, c1) = cell_share(job.n_out, job.lead, w, job.ways, job.seg_dst);
        if c0 >= c1 {
            return;
        }
        let _p = crate::precision::enter(job.precision);
        let dst = unsafe { job.seg_dst.add(c0) };
        let rows = &job.rows[c0..=c1];
        let (mask, init) = (job.seg_mask, job.init);
        if let Some(sp) = &job.sop {
            unsafe { sp.run(rows, mask, init, dst) };
            if let Some(g) = &job.fused {
                unsafe { cell_window(g, fregs, cursor, c0, c1) };
            }
            return;
        }
        // Block by block of cells: each block's tuples through every tuple
        // instruction, its cells folded, then the cell group over them, so a
        // block's values are still in cache when the next step reads them.
        // Every tuple and every cell sees the same kernels in the same order.
        let tmp = unsafe { job.tmp.add(w * job.tmp_stride) };
        let mut b0 = c0;
        while b0 < c1 {
            let q0 = job.rows[b0] as usize;
            let mut b1 = b0 + 1;
            while b1 < c1 && job.rows[b1 + 1] as usize - q0 <= job.cap {
                b1 += 1;
            }
            let len = job.rows[b1] as usize - q0;
            for (j, op) in job.ops.iter().enumerate() {
                unsafe { run_op(job.block_op(*op, j, q0, tmp), 0, len) };
            }
            let src = job.place(job.seg_src, job.ops.len(), q0, tmp);
            let mask = mask.map(|m| job.place(m, job.ops.len(), q0, tmp) as *const f64);
            let rows = &job.rows[b0..=b1];
            let dst = unsafe { job.seg_dst.add(b0) };
            macro_rules! fold {
                ($f:expr) => {
                    unsafe { seg_reduce(dst, src, mask, rows, q0, init, $f) }
                };
            }
            dispatch_bin_kernel!(&job.seg_op, fold);
            if let Some(g) = &job.fused {
                unsafe { cell_window(g, fregs, cursor, b0, b1) };
            }
            b0 = b1;
        }
    });
}

impl Job<'_> {
    /// Where tuple-box array `p` (at tuple 0) is read by tuple instruction
    /// `j` in the block that starts at tuple `q0`: the buffer of a slot an
    /// earlier instruction wrote, or `p` itself at `q0`.
    fn place(&self, p: *const f64, j: usize, q0: usize, tmp: *mut f64) -> *mut f64 {
        for (i, &(s, from)) in self.bufs.iter().enumerate() {
            if std::ptr::eq(s, p) && from < j {
                return unsafe { tmp.add(i * self.cap) };
            }
        }
        unsafe { p.add(q0) as *mut f64 }
    }

    /// Tuple instruction `j` over the block at tuple `q0`, its tuple-box
    /// operands placed as [`Job::place`] places them (its own output as a
    /// read by the next instruction).
    fn block_op(&self, op: Op, j: usize, q0: usize, tmp: *mut f64) -> Op {
        let arg = |a: Arg| match a {
            Arg::S(v) => Arg::S(v),
            Arg::P(p) => Arg::P(self.place(p, j, q0, tmp)),
        };
        let dst = |d: *mut f64| self.place(d, j + 1, q0, tmp);
        match op {
            Op::Table { dst: d, src, pos } => Op::Table {
                dst: dst(d),
                src,
                pos: unsafe { pos.add(q0) },
            },
            Op::Bin { op, dst: d, a, b } => Op::Bin {
                op,
                dst: dst(d),
                a: arg(a),
                b: arg(b),
            },
            Op::Un { op, dst: d, a } => Op::Un {
                op,
                dst: dst(d),
                a: arg(a),
            },
            Op::Neg { dst: d, a } => Op::Neg {
                dst: dst(d),
                a: arg(a),
            },
        }
    }
}

impl Op {
    /// The tuple-box array the instruction writes, at tuple 0.
    fn dst(&self) -> *mut f64 {
        match *self {
            Op::Table { dst, .. }
            | Op::Bin { dst, .. }
            | Op::Un { dst, .. }
            | Op::Neg { dst, .. } => dst,
        }
    }
}

/// Tuples a chain runs through its tuple instructions, reduction and cell
/// group at a time (more when one cell folds more).
const CHAIN_BLOCK: usize = 512;

/// The chain's cell group `g` over cells `[c0, c1)`.
///
/// # Safety
/// As for [`run_fused_window`].
unsafe fn cell_window(
    g: &Group,
    fregs: &mut [f64],
    cursor: &mut super::fused::RunCursor,
    c0: usize,
    c1: usize,
) {
    unsafe {
        fill_whole(g.fs, g.bases, g.whole_src, c0, c1, 0);
        run_fused_window(
            g,
            std::ptr::null_mut(),
            fregs,
            cursor,
            Window {
                lo: c0,
                hi: c1,
                period: 0,
                node_elems: g.node_elems,
            },
        );
    }
}

/// One tuple instruction over the tuples `[lo, lo + len)`.
unsafe fn run_op(op: Op, lo: usize, len: usize) {
    if len == 0 {
        return;
    }
    let sh = [len];
    match op {
        Op::Table { dst, src, pos } => unsafe {
            let v = SrcView {
                ptr: src,
                shape: smallvec::smallvec![usize::MAX],
                strides: smallvec::smallvec![1],
            };
            table_gather(
                dst.add(lo),
                &v,
                std::slice::from_raw_parts(pos.add(lo), len),
            );
        },
        Op::Bin { op, dst, a, b } => {
            let (av, bv) = (rv(a, lo), rv(b, lo));
            let dst = unsafe { dst.add(lo) };
            macro_rules! strided {
                ($f:expr) => {
                    unsafe { ew2(dst, &sh, &av, &bv, $f) }
                };
            }
            dispatch_bin_kernel!(&op, strided);
        }
        Op::Un { op, dst, a } => {
            let av = rv(a, lo);
            let dst = unsafe { dst.add(lo) };
            macro_rules! strided {
                ($f:expr) => {
                    unsafe { ew1(dst, &sh, &av, $f) }
                };
            }
            dispatch_un_kernel!(&op, strided);
        }
        Op::Neg { dst, a } => unsafe { ew1(dst.add(lo), &sh, &rv(a, lo), |x| -x) },
    }
}
