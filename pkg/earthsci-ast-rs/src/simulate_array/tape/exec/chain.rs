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
    FusedScratch, IndexTable, Window, dispatch_bin_kernel, dispatch_un_kernel, fill_whole,
    resolve_fused, run_fused_window,
};
use super::kernels::{ew1, ew2, seg_reduce, table_gather};
use super::par::FusedWorkers;
use super::resolve::{Rv, SrcView};
use super::*;

/// Element-operations each worker of a split chain must get.
const MIN_CHAIN_WORK_PER_WORKER: usize = 1 << 10;

/// A run of instructions `[start, end)` of the continuous section that
/// splits by the output cells of the segmented reduction at `seg`: the
/// tuple instructions `[start, seg)`, the reduction, and optionally the
/// fused group right after it.
pub(in crate::simulate_array::tape) struct SegChain {
    pub(super) start: usize,
    pub(super) end: usize,
    pub(super) seg: usize,
    /// The fused group at `seg + 1`, run over the same cells.
    pub(super) fused: Option<u32>,
    /// Output cells of the reduction.
    n_out: usize,
    /// Estimated element-operations of the whole chain.
    work: usize,
    /// Whether nothing outside the chain reads the tuple slots its tuple
    /// instructions define, so a pass that folds them as it goes need not
    /// store them.
    private: bool,
    /// The chain's position in [`seg_chains`]' list.
    id: usize,
    /// How the chain's tuples drop to the unmasked ones, when it can.
    pub(super) compact: Option<CompactPlan>,
}

/// A chain that is a gather `t1 = src[pos]` and a product `t2 = t1 * w`
/// summed under a mask the CONST or SEGMENT section defines, with `w` a
/// scalar or a tuple slot those sections define too. Which tuples the mask
/// admits, and their weights, change only when those sections re-run, so the
/// admitted tuples' positions and weights are gathered into a table of their
/// own then (see [`refill_compact`]) and every call folds only those.
#[derive(Clone, Copy, Debug)]
pub(super) struct CompactPlan {
    mask: SlotId,
    /// The gather's position table.
    table: u32,
    /// The product's other operand, when it is a tuple slot.
    pub(super) w: Option<SlotId>,
}

/// How a slot is addressed by the chain's workers.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Class {
    /// At the tuple positions of the worker's own cells.
    Tuple,
    /// At the worker's own output cells.
    Cell,
    /// At positions no worker owns (a gather source, a scalar).
    Any,
}

/// Every slab range the chain touches: `(slot, class, written)`.
type Touches = Vec<(SlotId, Class, bool)>;

/// The chains of `prog`'s continuous section, in program order. A
/// segmented reduction whose surroundings do not meet the conditions below
/// has none and runs instruction by instruction as before.
pub(super) fn seg_chains(prog: &TapeProgram, slot_off: &[usize]) -> Vec<SegChain> {
    let cont = (prog.n_const + prog.n_segment) as usize;
    // Instruction positions inside a branch or a recurrence body: a chain
    // never spans one (the loop may skip or repeat them).
    let mut guarded = vec![false; prog.instrs.len()];
    for (pc, ins) in prog.instrs.iter().enumerate() {
        let body = match ins {
            Instr::JmpIfZero {
                n_true, n_false, ..
            } => (*n_true + *n_false) as usize,
            Instr::Sweep { spec } => prog.sweeps[*spec as usize].body_len as usize,
            _ => 0,
        };
        let hi = (pc + 1 + body).min(guarded.len());
        guarded[pc + 1..hi].fill(true);
    }
    // Slots the continuous section writes: a compacted table may only copy
    // values that hold for every call between two primes.
    let tables = prog.tables();
    let mut per_call = vec![false; prog.slots.len()];
    for ins in &prog.instrs[cont..] {
        ins.for_each_def(&tables, |s| per_call[s as usize] = true);
    }
    let mut out = Vec::new();
    for seg in cont..prog.instrs.len() {
        if let Some(mut ch) = plan_one(prog, slot_off, cont, seg, &guarded) {
            ch.id = out.len();
            ch.compact = compact_plan(prog, &ch, &per_call);
            out.push(ch);
        }
    }
    out
}

/// The compaction of chain `ch`, if it is a masked sum of gathered products
/// whose mask and weights only the CONST and SEGMENT sections write.
fn compact_plan(prog: &TapeProgram, ch: &SegChain, per_call: &[bool]) -> Option<CompactPlan> {
    let Instr::SegReduce {
        op: BinCode::Add,
        src,
        mask: Some(mask),
        ..
    } = &prog.instrs[ch.seg]
    else {
        return None;
    };
    let [
        Instr::TableGather { table, out: t1, .. },
        Instr::Bin {
            op: BinCode::Mul,
            a,
            b,
            out: t2,
        },
    ] = &prog.instrs[ch.start..ch.seg]
    else {
        return None;
    };
    if !ch.private || t2 != src || per_call[*mask as usize] {
        return None;
    }
    let is_t1 = |o: &Operand| matches!(o, Operand::Slot(s) if s == t1);
    let w = match (is_t1(a), is_t1(b)) {
        (true, false) => b,
        (false, true) => a,
        _ => return None,
    };
    let w = match w {
        Operand::Lit(_) | Operand::Param(_) | Operand::Time => None,
        Operand::Slot(s) if prog.slots[*s as usize].scalar => None,
        Operand::Slot(s) if !per_call[*s as usize] => Some(*s),
        _ => return None,
    };
    Some(CompactPlan {
        mask: *mask,
        table: *table,
        w,
    })
}

fn plan_one(
    prog: &TapeProgram,
    slot_off: &[usize],
    cont: usize,
    seg: usize,
    guarded: &[bool],
) -> Option<SegChain> {
    let Instr::SegReduce {
        src,
        mask,
        table,
        out,
        ..
    } = &prog.instrs[seg]
    else {
        return None;
    };
    let rows = &prog.seg_tables[*table as usize].rows;
    let n_out = rows.len().checked_sub(1)?;
    let n_pairs = *rows.last()? as usize;
    let odesc = &prog.slots[*out as usize];
    if n_out < 2 || odesc.scalar || odesc.elems() != n_out {
        return None;
    }
    let tuple_slot = |s: SlotId| tuple_box(prog, s, n_pairs);
    let mut touches: Touches = vec![(*src, Class::Tuple, false), (*out, Class::Cell, true)];
    if !tuple_slot(*src) {
        return None;
    }
    if let Some(m) = mask {
        if !tuple_slot(*m) {
            return None;
        }
        touches.push((*m, Class::Tuple, false));
    }
    // The tuple instructions right before the reduction.
    let mut start = seg;
    while start > cont && !guarded[start - 1] {
        let mut t = Vec::new();
        if !tuple_instr(prog, &prog.instrs[start - 1], n_pairs, &mut t) {
            break;
        }
        touches.extend(t);
        start -= 1;
    }
    let mut work = n_pairs * (seg - start + 1);
    // The fused group right after it, over the same cells.
    let mut fused = None;
    if let Some(Instr::Fused { spec }) = prog.instrs.get(seg + 1)
        && !guarded[seg + 1]
    {
        let mut t = Vec::new();
        let fs = &prog.fused[*spec as usize];
        if cell_group(fs, n_out, &mut t) {
            touches.extend(t);
            fused = Some(*spec);
            work += n_out * (fs.micro.len() + fs.inputs.len() + fs.outputs.len() + 1);
        }
    }
    let end = seg + 1 + usize::from(fused.is_some());
    if guarded[start..end].iter().any(|&g| g)
        || (start..end).any(|pc| prog.precision.get(pc).is_some())
        || !disjoint(prog, slot_off, &touches)
    {
        return None;
    }
    // The tuple slots the chain defines, and whether anything but the chain
    // reads them.
    let tables = prog.tables();
    let mut defs: Vec<SlotId> = Vec::new();
    for ins in &prog.instrs[start..seg] {
        ins.for_each_def(&tables, |s| defs.push(s));
    }
    let mut private = prog.exports.iter().all(|(_, s)| !defs.contains(s));
    for (pc, ins) in prog.instrs.iter().enumerate() {
        if !(start..=seg).contains(&pc) {
            ins.for_each_read(&tables, |s| private &= !defs.contains(&s));
        }
    }
    Some(SegChain {
        start,
        end,
        seg,
        fused,
        n_out,
        work,
        private,
        id: 0,
        compact: None,
    })
}

/// Whether `ins` is elementwise over the tuple box of `n_pairs` (writing a
/// tuple slot from tuple slots, scalars and a gathered source), recording
/// what it touches.
fn tuple_instr(prog: &TapeProgram, ins: &Instr, n_pairs: usize, t: &mut Touches) -> bool {
    let tuple_slot = |s: SlotId| tuple_box(prog, s, n_pairs);
    let operand = |op: &Operand, t: &mut Touches| match op {
        Operand::Lit(_) | Operand::Param(_) | Operand::Time => true,
        Operand::State(ix) => {
            let sh = &prog.state_vars[*ix as usize].shape;
            sh.is_empty() || sh[..] == [n_pairs]
        }
        Operand::Slot(s) if prog.slots[*s as usize].scalar => {
            t.push((*s, Class::Any, false));
            true
        }
        Operand::Slot(s) if tuple_slot(*s) => {
            t.push((*s, Class::Tuple, false));
            true
        }
        _ => false,
    };
    let out = match ins {
        Instr::TableGather { src, out, .. } => {
            match src {
                SrcRef::Slot(s) => t.push((*s, Class::Any, false)),
                SrcRef::State(_) => {}
            }
            *out
        }
        Instr::Bin { a, b, out, .. } => {
            if !(operand(a, t) && operand(b, t)) {
                return false;
            }
            *out
        }
        Instr::Un { a, out, .. } | Instr::Neg { a, out } => {
            if !operand(a, t) {
                return false;
            }
            *out
        }
        _ => return false,
    };
    if !tuple_slot(out) {
        return false;
    }
    t.push((out, Class::Tuple, true));
    true
}

/// Whether slot `s` is an array over the tuple box of `n_pairs`.
fn tuple_box(prog: &TapeProgram, s: SlotId, n_pairs: usize) -> bool {
    let d = &prog.slots[s as usize];
    !d.scalar && d.shape[..] == [n_pairs]
}

/// Whether fused group `fs` runs over the reduction's `n_out` cells with
/// every read of a cell-box slot at the cell itself, recording what it
/// touches.
fn cell_group(fs: &FusedSpec, n_out: usize, t: &mut Touches) -> bool {
    if fs.n_elems() != n_out
        || fs.reduce.is_some()
        || fs.pre.is_some()
        || fs.interleave.is_some()
        || !fs.scan_fuse.is_empty()
        || fs.micro.iter().any(|m| matches!(m, MicroOp::Scan { .. }))
    {
        return false;
    }
    let mut aligned = vec![true; fs.inputs.len()];
    for (i, inp) in fs.inputs.iter().enumerate() {
        aligned[i] = inp.gather.is_none() && inp.index.is_none() && inp.src_shape == fs.shape;
        if let Some(s) = inp.shifted_ix {
            aligned[i] &= inp.elem_stride == 1;
            let s = s as usize;
            fs.schedule.for_each_run(|r| {
                aligned[i] &= r.in_off.get(s).is_some_and(|&o| o == r.out_off as i64);
            });
        }
    }
    for (inp, al) in fs.inputs.iter().zip(aligned) {
        if let SrcRef::Slot(s) = inp.src {
            t.push((s, if al { Class::Cell } else { Class::Any }, false));
        }
    }
    for &(_, s) in &fs.outputs {
        t.push((s, Class::Cell, true));
    }
    true
}

/// Whether no worker can write slab storage another worker reads or writes:
/// two slots the chain touches that share storage, one of them written,
/// must be the same range addressed the same way (an in-place reuse), and
/// a slot written by the chain is never read at positions no worker owns.
fn disjoint(prog: &TapeProgram, slot_off: &[usize], touches: &Touches) -> bool {
    let range = |s: SlotId| {
        let off = slot_off[s as usize];
        (off != usize::MAX).then(|| (off, off + prog.slots[s as usize].elems().max(1)))
    };
    for (i, &(s, cs, ws)) in touches.iter().enumerate() {
        let Some((a0, a1)) = range(s) else { continue };
        for &(r, cr, wr) in &touches[i + 1..] {
            if !(ws || wr) {
                continue;
            }
            let Some((b0, b1)) = range(r) else { continue };
            if a0 >= b1 || b0 >= a1 {
                continue;
            }
            if (a0, a1) != (b0, b1) || cs != cr || cs == Class::Any {
                return false;
            }
        }
    }
    true
}

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
    /// Per chain, its admitted tuples (see [`CompactPlan`]), or `None`.
    compact: Vec<Option<Compacted>>,
}

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
/// `slab_ptr` must be the slab `slot_off` lays out, with the CONST and
/// SEGMENT sections of this program run.
pub(super) unsafe fn refill_compact(
    chains: &[SegChain],
    scratch: &mut ChainScratch,
    prog: &TapeProgram,
    slab_ptr: *const f64,
    slot_off: &[usize],
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
        let rows = &prog.seg_tables[*table as usize].rows;
        let n_pairs = *rows.last().expect("a planned chain has cells") as usize;
        let read = |s: SlotId| unsafe {
            std::slice::from_raw_parts(slab_ptr.add(slot_off[s as usize]), n_pairs)
        };
        let mask = read(plan.mask);
        let w = plan.w.map(read);
        let pos = &prog.gather_tables[plan.table as usize].pos;
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
    fused: Option<(&'a FusedSpec, super::fused::Resolved<'a>)>,
    /// The tuple instructions and the reduction as one pass, when they are
    /// a gather, a product and a sum.
    sop: Option<SumOfProducts>,
    idx: &'a [Option<IndexTable>],
    simd: SimdLevel,
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
fn tuple_arg(o: &Operand, env: &Env, slab_ptr: *mut f64, slot_off: &[usize]) -> Option<Arg> {
    Some(match o {
        Operand::Lit(v) => Arg::S(*v),
        Operand::Param(p) => Arg::S(env.params[*p as usize]),
        Operand::Time => Arg::S(env.t),
        Operand::Slot(s) => {
            let p = unsafe { slab_ptr.add(slot_off[*s as usize]) };
            if env.prog.slots[*s as usize].scalar {
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
/// `slab_ptr` must be the slab `slot_off` lays out, `dy` the call's `dy`
/// with `dy_home` its homes, and every instruction before `ch.start` of this
/// call already run.
#[allow(clippy::too_many_arguments)]
pub(super) unsafe fn run_chain(
    ch: &SegChain,
    env: &Env,
    slab_ptr: *mut f64,
    slot_off: &[usize],
    scratch: &mut ChainScratch,
    fscratch: &mut FusedScratch,
    idx_tables: &[Vec<Option<IndexTable>>],
    simd: SimdLevel,
    dy_home: &[usize],
    dy: *mut f64,
) -> bool {
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
    let rows = &prog.seg_tables[*table as usize].rows[..];
    scratch.ops.clear();
    for ins in &prog.instrs[ch.start..ch.seg] {
        let at = |o: SlotId| unsafe { slab_ptr.add(slot_off[o as usize]) };
        let rvs = |o: &Operand| tuple_arg(o, env, slab_ptr, slot_off);
        let op = match ins {
            Instr::TableGather { src, table, out } => Op::Table {
                dst: at(*out),
                src: match src {
                    SrcRef::Slot(s) => at(*s),
                    SrcRef::State(ix) => super::resolve::state_ptr(env, *ix),
                },
                pos: prog.gather_tables[*table as usize].pos.as_ptr(),
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
    let seg_src = unsafe { slab_ptr.add(slot_off[*src as usize]) as *const f64 };
    let seg_mask = mask.map(|m| unsafe { slab_ptr.add(slot_off[m as usize]) as *const f64 });
    let seg_dst = unsafe { slab_ptr.add(slot_off[*out as usize]) };
    let (resolved, workers) = match ch.fused {
        Some(spec) => {
            let (r, w) = unsafe {
                resolve_fused(
                    spec as usize,
                    env,
                    slab_ptr,
                    slot_off,
                    fscratch,
                    dy_home,
                    dy,
                )
            };
            (Some((&prog.fused[spec as usize], r)), w)
        }
        None => (None, &mut fscratch.workers),
    };
    let mut sop = SumOfProducts::of(&scratch.ops, *op, *init, seg_src, seg_mask, ch.private);
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
        idx: ch.fused.map_or(&[][..], |s| &idx_tables[s as usize][..]),
        sop,
        fused: resolved,
        simd,
        precision: crate::precision::active(),
    };
    unsafe { run_job(workers, &job) };
    true
}

/// The output cells `[c0, c1)` of share `w` of `ways`, cut where `at + cut`
/// starts a cache line (as [`share_at`](super::par::share_at) cuts). Share 0
/// runs on the calling thread, which starts it as it publishes the job,
/// before any worker has seen it, so it takes a quarter more cells than each
/// of the others and all finish together.
fn cell_share(n: usize, w: usize, ways: usize, at: *const f64) -> (usize, usize) {
    const ALIGN: usize = 8;
    let phase = (at as usize / std::mem::size_of::<f64>()) % ALIGN;
    let cut = |k: usize| {
        if k == 0 {
            0
        } else if k == ways {
            n
        } else {
            let c = n * (4 * k + 1) / (4 * ways + 1);
            ((c + phase) / ALIGN * ALIGN).saturating_sub(phase).min(n)
        }
    };
    (cut(w), cut(w + 1))
}

/// Run every share of `job` on the pool.
unsafe fn run_job(workers: &mut FusedWorkers, job: &Job) {
    workers.run_with_workers(job.ways, &|w, fregs, cursor| {
        let (c0, c1) = cell_share(job.n_out, w, job.ways, job.seg_dst);
        if c0 >= c1 {
            return;
        }
        let _p = crate::precision::enter(job.precision);
        let (p0, p1) = (job.rows[c0] as usize, job.rows[c1] as usize);
        let len = p1 - p0;
        let dst = unsafe { job.seg_dst.add(c0) };
        let rows = &job.rows[c0..=c1];
        let (src, mask, init) = (job.seg_src, job.seg_mask, job.init);
        if let Some(sp) = &job.sop {
            unsafe { sp.run(rows, mask, init, dst) };
        } else {
            for op in job.ops {
                unsafe { run_op(*op, p0, len) };
            }
            macro_rules! fold {
                ($f:expr) => {
                    unsafe { seg_reduce(dst, src, mask, rows, init, $f) }
                };
            }
            dispatch_bin_kernel!(&job.seg_op, fold);
        }
        if let Some((fs, r)) = &job.fused {
            unsafe {
                fill_whole(fs, r.bases, r.whole_src, c0, c1, 0);
                run_fused_window(
                    job.simd,
                    fs,
                    r.svals,
                    r.bases,
                    r.outs,
                    std::ptr::null_mut(),
                    job.idx,
                    fregs,
                    cursor,
                    Window {
                        lo: c0,
                        hi: c1,
                        period: 0,
                        node_elems: r.node_elems,
                    },
                );
            }
        }
    });
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
