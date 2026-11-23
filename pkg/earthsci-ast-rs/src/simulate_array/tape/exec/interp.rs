//! The instruction loop: decode one `Instr` at a time, resolve its operands
//! through `resolve`, and apply the loops in `kernels` / `fused`.
//!
//! This is the only module that knows the instruction encoding, which is
//! why the boundary sits here: the kernels it drives know pointers and
//! strides and nothing about the program.

use super::fused::{dispatch_bin_kernel, dispatch_un_kernel, exec_fused};
#[cfg(not(target_arch = "wasm32"))]
use super::kernels::scan_leading_cols;
use super::kernels::{
    copy_strided, count_bisects, count_many, count_one, data_gather, data_gather_sub, ew_select,
    ew1, ew2, exec_gather, fill_strided, index_gather, reduce_axis, reduce_rows, scan_axis,
    seg_reduce, table_gather,
};
use super::resolve::{Rv, Slab, resolve_rv, resolve_scalar, resolve_src, rm_strides, src_base};
use super::*;
use crate::simulate_array::eval::{latch_gather_fault, latch_ordered_fault};
use rustc_hash::{FxHashMap, FxHashSet};

/// Write a recurrence sweep's current (0-based) cell into its coordinate
/// slots, 1-based, as the interpreter binds the frame symbols.
///
/// # Safety
/// No other thread may be touching the coordinate slots.
unsafe fn write_coords(sw: &SweepSpec, cell: &[usize], slab: Slab) {
    for (&slot, &c) in sw.coords.iter().zip(cell) {
        // SAFETY: the caller's contract.
        unsafe { slab.write(slot, (c + 1) as f64) };
    }
}

// ---------------------------------------------------------------------------
// The interpreter loop.
// ---------------------------------------------------------------------------

/// Execute the instruction range `[range.start, range.end)` (one or more
/// whole sections). `JmpIfZero` regions never straddle a section boundary.
pub(super) fn run_range(
    env: &Env,
    range: std::ops::Range<usize>,
    exec: &mut TapeExec,
    dy: &mut [f64],
) {
    // The call's split width (see `par`), for the copies and lanes below.
    let call_split = call_ways(exec);
    let TapeExec {
        slab: slab_vec,
        slot_off,
        obs,
        parked,
        pending,
        scalar,
        layout,
        scratch,
        idx_tables,
        lscratch,
        exports_active,
        simd,
        #[cfg(not(target_arch = "wasm32"))]
        chain_scratch,
        funcs,
        ..
    } = exec;
    let exports_active = *exports_active;
    let dy_home: &[usize] = if exports_active {
        &env.prep.dy.home
    } else {
        &env.prep.dy.home_quiet
    };
    #[cfg(not(target_arch = "wasm32"))]
    let seg_chains = &env.prep.seg_chains;
    let simd = *simd;
    let prog = env.prog;
    let slot_off: &[usize] = slot_off;
    let slab = Slab::new(slab_vec, slot_off, &prog.tables.slots);
    pending.clear();

    // The open recurrence sweep, if any: the `Sweep` instruction's position
    // and the 0-based frame cell its body is evaluating.
    let mut sweep: Option<(usize, SmallVec<[usize; 4]>)> = None;
    scalar.ensure(prog, slot_off, *layout);
    let mut pc = range.start;
    // The next segmented-reduction chain that may split (see `chain`).
    #[cfg(not(target_arch = "wasm32"))]
    let mut next_chain = seg_chains.partition_point(|c| c.start < range.start);
    // An open sweep keeps the loop going at `range.end`: a range may end
    // exactly at a recurrence body's end (a call plan hands the loop a sweep
    // as its own step), and the body's end is where the cell is published and
    // the next cell starts.
    while pc < range.end || sweep.is_some() {
        while let Some(&(pos, skip)) = pending.last() {
            if pc == pos as usize {
                pending.pop();
                pc += skip as usize;
            } else {
                break;
            }
        }
        // The end of a recurrence body: publish the cell, then run the body
        // for the next cell in sweep order, or leave the sweep after the last.
        let mut sweep_done = false;
        if let Some((spc, cell)) = &mut sweep {
            let Instr::Sweep { spec } = &prog.instrs[*spc] else {
                unreachable!("an open sweep starts at a Sweep")
            };
            let sw = &prog.tables.sweeps[*spec as usize];
            let body = *spc + 1;
            if pc == body + sw.body_len as usize {
                let v = resolve_scalar(&sw.result, env, slab);
                let prec = prog
                    .precision
                    .get(*spc)
                    .copied()
                    .unwrap_or_else(crate::precision::active);
                let out = slab.slot(sw.out);
                unsafe { *out.add(sw.flat(cell)) = prec.round(v) };
                if sw.advance(cell) {
                    unsafe { write_coords(sw, cell, slab) };
                    pc = body;
                    continue;
                }
                sweep_done = true;
            }
        }
        if sweep_done {
            sweep = None;
        }
        if pc >= range.end {
            break;
        }
        // The decoded scalar code (see `ScalarCode`), up to the range's end
        // or, inside a recurrence body, the body's end, where the step above
        // publishes the cell.
        let limit = match &sweep {
            Some((spc, _)) => {
                let Instr::Sweep { spec } = &prog.instrs[*spc] else {
                    unreachable!("an open sweep starts at a Sweep")
                };
                spc + 1 + prog.tables.sweeps[*spec as usize].body_len as usize
            }
            None => range.end,
        };
        let start = pc;
        loop {
            // The end of a taken true region skips its false region, as at
            // the top of the step.
            if let Some(&(pos, skip)) = pending.last()
                && pos as usize == pc
            {
                pending.pop();
                pc += skip as usize;
                continue;
            }
            if pc >= limit {
                break;
            }
            match scalar.at[pc] {
                Entry::Block(b) => {
                    let b = scalar.blocks[b as usize];
                    if b.end > limit {
                        break;
                    }
                    // SAFETY: decoded against this call's layout (`ensure`
                    // above), every instruction before it has run, and the
                    // instruction loop runs on the calling thread alone.
                    match unsafe { b.run(scalar, env, slab, dy) } {
                        Some(end) => pc = end,
                        // A gather faulted: the general path latches it.
                        None => break,
                    }
                }
                Entry::Jmp {
                    cond,
                    n_true,
                    n_false,
                } => {
                    // `Instr::JmpIfZero`'s arm below.
                    // SAFETY: as for the block above.
                    if unsafe { scalar_get(&cond, env, slab) } != 0.0 {
                        pending.push(((pc + 1 + n_true as usize) as u32, n_false));
                    } else {
                        pc += n_true as usize;
                    }
                    pc += 1;
                }
                Entry::None => break,
            }
        }
        if pc != start {
            continue;
        }
        #[cfg(not(target_arch = "wasm32"))]
        if next_chain < seg_chains.len() {
            while seg_chains.get(next_chain).is_some_and(|c| c.start < pc) {
                next_chain += 1;
            }
            if let Some(ch) = seg_chains
                .get(next_chain)
                .filter(|c| c.start == pc && c.end <= range.end)
            {
                next_chain += 1;
                let cx = Cx {
                    env,
                    slab,
                    idx_tables,
                    simd,
                    dy_home,
                    dy: dy.as_mut_ptr(),
                    dy_len: dy.len(),
                };
                let split = unsafe {
                    super::chain::run_chain(ch, &cx, chain_scratch, &mut scratch.fscratch)
                };
                if split {
                    pc = ch.end;
                    continue;
                }
            }
        }
        // The instruction's own precision, armed for it alone (esm-spec
        // §11.3.1); a program without per-instruction precision skips this.
        let _precision = prog
            .precision
            .get(pc)
            .filter(|&&p| p != crate::precision::active())
            .map(|&p| crate::precision::enter(p));
        match &prog.instrs[pc] {
            Instr::LoadForcing { forcing, out } => {
                let fr = &prog.forcings[*forcing as usize];
                let off = slab.off(*out);
                let dst = unsafe { std::slice::from_raw_parts_mut(slab.at(off), forcing_len(fr)) };
                match env.forcing {
                    super::ForcingView::Map(buffer) => {
                        load_forcing(fr, buffer, env.declared, prog.col_major, dst)
                    }
                    super::ForcingView::Slots { bufs, slot_of } => {
                        let src = &bufs[slot_of[*forcing as usize] as usize];
                        super::load_forcing_slot(fr, src, prog.col_major, dst)
                    }
                }
            }
            Instr::Fault { fault } => {
                let (rule, key) = &prog.tables.fault_order[*fault as usize];
                latch_ordered_fault(*rule, key, || prog.tables.faults[*fault as usize].clone());
            }
            Instr::FaultScan { spec } => {
                let scan = &prog.tables.fault_scans[*spec as usize];
                let first = scan.first(&prog.tables.faults, |op, cell| match (op, cell) {
                    (Operand::Slot(s), Some((shape, c))) => unsafe {
                        *slab.at(slab.off(*s) + slab_flat(shape, c, prog.col_major))
                    },
                    _ => resolve_scalar(op, env, slab),
                });
                if let Some((key, msg)) = first {
                    latch_ordered_fault(scan.rule, &key, || msg);
                }
            }
            Instr::Sweep { spec } => {
                let sw = &prog.tables.sweeps[*spec as usize];
                debug_assert!(sweep.is_none(), "recurrence sweeps do not nest");
                if sw.n_cells() == 0 {
                    pc += 1 + sw.body_len as usize;
                    continue;
                }
                let cell: SmallVec<[usize; 4]> = SmallVec::from_elem(0, sw.shape.len());
                unsafe { write_coords(sw, &cell, slab) };
                sweep = Some((pc, cell));
            }
            Instr::ScalarRead { src, spec, out } => {
                let sp = &prog.tables.scalar_reads[*spec as usize];
                let sv = resolve_src(src, env, slab);
                let raw: SmallVec<[i64; 4]> = sp
                    .subs
                    .iter()
                    .map(|o| subscript_of(resolve_scalar(o, env, slab)))
                    .collect();
                let cur = sweep.as_ref().map_or(&[][..], |(_, c)| &c[..]);
                let v = match sp.resolve(&raw, &sv.shape, &prog.tables.sweeps, cur) {
                    ScalarReadAt::Elem(ix) => {
                        let off: i64 = ix
                            .iter()
                            .zip(sv.strides.iter())
                            .map(|(&i, &st)| i as i64 * st)
                            .sum();
                        let x = unsafe { *sv.ptr.offset(off as isize) };
                        if matches!(sp.kind, ScalarReadKind::SelfRead { .. }) {
                            crate::precision::active().round(x)
                        } else {
                            x
                        }
                    }
                    ScalarReadAt::Ghost => 0.0,
                    ScalarReadAt::Fault(msg) => {
                        latch_gather_fault(msg);
                        f64::NAN
                    }
                };
                unsafe { *slab.slot(*out) = v };
            }
            Instr::JmpIfZero {
                cond,
                n_true,
                n_false,
            } => {
                let c = resolve_scalar(cond, env, slab);
                if c != 0.0 {
                    // Execute the true region, then skip the false one.
                    pending.push(((pc + 1 + *n_true as usize) as u32, *n_false));
                } else {
                    pc += *n_true as usize; // skip straight to the false region
                }
            }
            Instr::Call { call, out } => {
                let spec = &prog.tables.calls[*call as usize];
                let arrays: SmallVec<[*const f64; 8]> = spec
                    .arrays
                    .iter()
                    .map(|s| src_base(s, env, slab).0)
                    .collect();
                let scalars: SmallVec<[f64; 8]> = spec
                    .scalars
                    .iter()
                    .map(|o| resolve_scalar(o, env, slab))
                    .collect();
                let fctx = funcs[spec.func as usize].get_or_insert_with(|| {
                    let mut c =
                        super::TapeCtx::new(std::sync::Arc::clone(&prog.funcs[spec.func as usize]));
                    c.set_serial();
                    Box::new(c)
                });
                let res =
                    super::run_function(fctx, &arrays, &scalars, env.t, env.forcing, env.declared);
                let n = prog.tables.slots[*out as usize].elems().max(1);
                // SAFETY: the result is the function's slot of the same box,
                // in its own slab; `out` is this program's slot, written by
                // this instruction alone.
                unsafe { std::ptr::copy_nonoverlapping(res, slab.slot(*out), n) };
            }
            Instr::Export { slot, export } => {
                // Step 4 export demotion: no explicit request ⇒ nothing can
                // read the published array — skip the publish memcpy.
                if !exports_active {
                    pc += 1;
                    continue;
                }
                let e = *export as usize;
                if let Some((name, arr)) = parked[e].take() {
                    obs.insert(name, arr);
                }
                let a = obs
                    .get_mut(&prog.exports[e].0)
                    .expect("export array published");
                let desc = &prog.tables.slots[*slot as usize];
                let off = slab.off(*slot);
                if desc.scalar {
                    a[IxDyn(&[])] = unsafe { *slab.at(off) };
                } else {
                    // `a.len()`, not `desc.elems()`: an empty box keeps a
                    // one-element storage but publishes an empty array.
                    debug_assert_eq!(a.len(), desc.shape.iter().product::<usize>());
                    let n = a.len();
                    let src = unsafe { std::slice::from_raw_parts(slab.at(off), n) };
                    if prog.col_major && !super::super::layout::order_free(&desc.shape) {
                        // The slot is the logical array axis-reversed; the
                        // reversed view of the export walks in slot order.
                        for (d, &v) in a.view_mut().reversed_axes().iter_mut().zip(src) {
                            *d = v;
                        }
                    } else {
                        a.as_slice_mut()
                            .expect("export arrays are standard layout")
                            .copy_from_slice(src);
                    }
                }
            }
            ins => {
                let cx = Cx {
                    env,
                    slab,
                    idx_tables,
                    simd,
                    dy_home,
                    dy: dy.as_mut_ptr(),
                    dy_len: dy.len(),
                };
                match ins {
                    Instr::Lanes { spec } => unsafe {
                        super::lanes::exec_lanes(*spec as usize, &cx, lscratch, call_split)
                    },
                    _ => unsafe { exec_straight(&cx, ins, scratch, call_split) },
                }
            }
        }
        pc += 1;
    }
}

/// A scalar operand, decoded: a slot at its slab offset (decoded against the
/// call's slot layout, see [`ScalarCode`]), a literal, a parameter, `t`, or
/// a 0-d state at its flat offset.
#[derive(Clone, Copy)]
pub(super) enum ScalarSrc {
    Slot(usize),
    Lit(f64),
    Param(u32),
    Time,
    State(usize),
}

/// Where a decoded load, gather or count reads its source: the slab at a
/// slot's offset, or a state variable (through
/// [`state_ptr`](super::resolve::state_ptr), which picks the row-major
/// mirror when there is one).
#[derive(Clone, Copy)]
pub(super) enum ScalarBase {
    Slab(usize),
    State(u32),
}

/// A decoded binary kernel other than `+ - * /` (which [`BlockOp`] holds as
/// variants of their own): the comparisons and NaN-propagating `min`/`max`
/// written out as `dispatch_bin_kernel` writes them, so they inline; every
/// other kernel (and every kernel under Float32) through
/// [`binary_kernel_of`]'s function.
#[derive(Clone, Copy)]
pub(super) enum ScalarBin {
    Lt,
    Le,
    Gt,
    Ge,
    Eq,
    Ne,
    Min,
    Max,
    Fn(fn(f64, f64) -> f64),
}

impl ScalarBin {
    /// [`binary_kernel_of`]'s binary64 arm, for the written-out kernels.
    #[inline(always)]
    fn apply(self, x: f64, y: f64) -> f64 {
        match self {
            ScalarBin::Lt => (x < y) as i32 as f64,
            ScalarBin::Le => (x <= y) as i32 as f64,
            ScalarBin::Gt => (x > y) as i32 as f64,
            ScalarBin::Ge => (x >= y) as i32 as f64,
            ScalarBin::Eq => (x == y) as i32 as f64,
            ScalarBin::Ne => (x != y) as i32 as f64,
            ScalarBin::Min => crate::faq::nan_min(x, y),
            ScalarBin::Max => crate::faq::nan_max(x, y),
            ScalarBin::Fn(f) => f(x, y),
        }
    }
}

/// One operation of a [`Block`], on its register file: the scalar branch of
/// the instruction's [`exec_straight`] arm, with the kernel and the operand
/// registers decoded.
#[derive(Clone, Copy)]
enum BlockOp {
    Add(u16, u16, u16),
    Sub(u16, u16, u16),
    Mul(u16, u16, u16),
    Div(u16, u16, u16),
    Bin(ScalarBin, u16, u16, u16),
    Un(fn(f64) -> f64, u16, u16),
    Neg(u16, u16),
    Select(u16, u16, u16, u16),
    /// [`Instr::LoadElem`]: the source's element at row-major offset `at`.
    Load(ScalarBase, usize, u16),
    /// [`Instr::DataGather`] of a rank-1 source of extent `n` at one
    /// subscript; `spec` resolves a subscript outside `1..=n`.
    Gather1 {
        src: ScalarBase,
        x: u16,
        n: usize,
        spec: u32,
        out: u16,
    },
    /// [`Instr::DataGather`] of a rank-2 source at two subscripts: whole
    /// numbers inside the source read their element directly, anything else
    /// resolves through `spec`.
    Gather2 {
        src: ScalarBase,
        a: u16,
        b: u16,
        n0: u32,
        n1: u32,
        spec: u32,
        out: u16,
    },
    /// [`Instr::DataGather`] at one element, any rank up to four
    /// subscripts: its spec, the subscripts in `subs`'s first `n` registers.
    Gather {
        src: ScalarBase,
        subs: [u16; 4],
        n: u8,
        spec: u32,
        out: u16,
    },
    /// [`Instr::Count`] at one query; its window lies in the axis's box.
    Count {
        rel: CountRel,
        axis: ScalarBase,
        lo: u32,
        n: u32,
        sorted: bool,
        x: u16,
        out: u16,
    },
}

/// Where a [`Block`] puts a value at its end.
#[derive(Clone, Copy)]
enum BlockOut {
    Slab(usize),
    Dy(usize),
}

/// A straight run of scalar instructions run as one program over a register
/// file: each operand the run reads from before it is read into a register,
/// every value it computes stays in one, and at the end each slab offset it
/// wrote gets its last value and each `dy` position its value, in program
/// order. Within the run nothing reads a value it stores (a scalar run writes
/// only scalar slots and `dy`; the arrays it reads were written before it),
/// so deferring the stores changes no read, and each operation is its
/// instruction's scalar kernel on the same operand values. A one-lane lane
/// program is inlined, its micro-ops on the same registers.
///
/// Because every store waits for the end, a gather that faults stops the
/// block having written nothing, and the instruction loop runs the run's
/// instructions one by one instead, where the fault is latched.
///
/// A block's inputs, operations and outputs lie in [`ScalarCode`]'s shared
/// arrays, `[lo, hi)` each, so the blocks of a program sit together in
/// program order.
#[derive(Clone, Copy)]
struct Block {
    /// One past its last instruction.
    end: usize,
    inputs: (u32, u32),
    ops: (u32, u32),
    outs: (u32, u32),
}

/// A block as [`Block::build`] decodes it, before it joins the shared
/// arrays.
struct Built {
    end: usize,
    inputs: Vec<(ScalarSrc, u16)>,
    ops: Vec<BlockOp>,
    outs: Vec<(u16, BlockOut)>,
    n_regs: usize,
}

/// What the instruction loop does at one position (see [`ScalarCode`]).
#[derive(Clone, Copy)]
enum Entry {
    /// No decoded form: the general dispatch.
    None,
    /// The [`Block`] starting here.
    Block(u32),
    /// [`Instr::JmpIfZero`] with a scalar condition.
    Jmp {
        cond: ScalarSrc,
        n_true: u32,
        n_false: u32,
    },
}

/// The decoded form of a program's scalar instructions, for one slot layout
/// and one active precision (`key`): per instruction what the loop does
/// there, and the blocks. A scalar right-hand side (a template's lookup at
/// one query) is mostly scalar instructions of a few flops each, so a
/// dispatch per instruction would be most of its cost.
#[derive(Default)]
pub(super) struct ScalarCode {
    /// The slot-layout generation and the precision it was decoded under;
    /// `None` before the first decode.
    key: Option<(u64, crate::precision::Precision)>,
    at: Vec<Entry>,
    blocks: Vec<Block>,
    inputs: Vec<(ScalarSrc, u16)>,
    ops: Vec<BlockOp>,
    outs: Vec<(u16, BlockOut)>,
    /// The blocks' register file.
    regs: Vec<f64>,
}

impl ScalarCode {
    /// Decode `prog` against the slot layout `slot_off` (generation
    /// `layout`) unless it already is, under the active precision.
    fn ensure(&mut self, prog: &TapeProgram, slot_off: &[usize], layout: u64) {
        let key = (layout, crate::precision::active());
        if self.key == Some(key) {
            return;
        }
        self.key = Some(key);
        self.at.clear();
        self.at.resize(prog.instrs.len(), Entry::None);
        self.blocks.clear();
        self.inputs.clear();
        self.ops.clear();
        self.outs.clear();
        let mut n_regs = 0;
        let cuts = &prog.prepared().block_cuts;
        let mut pc = 0;
        while pc < prog.instrs.len() {
            if let Instr::JmpIfZero {
                cond,
                n_true,
                n_false,
            } = &prog.instrs[pc]
            {
                if let Some(cond) = scalar_src(prog, cond, slot_off) {
                    self.at[pc] = Entry::Jmp {
                        cond,
                        n_true: *n_true,
                        n_false: *n_false,
                    };
                }
                pc += 1;
                continue;
            }
            match Block::build(prog, slot_off, cuts, pc) {
                Some(b) => {
                    self.at[pc] = Entry::Block(self.blocks.len() as u32);
                    pc = b.end;
                    n_regs = n_regs.max(b.n_regs);
                    let span = |lo: usize, hi: usize| (lo as u32, hi as u32);
                    let (i, o, u) = (self.inputs.len(), self.ops.len(), self.outs.len());
                    self.inputs.extend(b.inputs);
                    self.ops.extend(b.ops);
                    self.outs.extend(b.outs);
                    self.blocks.push(Block {
                        end: b.end,
                        inputs: span(i, self.inputs.len()),
                        ops: span(o, self.ops.len()),
                        outs: span(u, self.outs.len()),
                    });
                }
                None => pc += 1,
            }
        }
        if self.regs.len() < n_regs {
            self.regs.resize(n_regs, 0.0);
        }
    }
}

/// `o` as a decoded scalar operand, or `None` for an array operand.
fn scalar_src(prog: &TapeProgram, o: &Operand, slot_off: &[usize]) -> Option<ScalarSrc> {
    Some(match o {
        Operand::Slot(s) if prog.tables.slots[*s as usize].scalar => {
            ScalarSrc::Slot(slot_off[*s as usize])
        }
        Operand::Lit(v) => ScalarSrc::Lit(*v),
        Operand::Param(p) => ScalarSrc::Param(*p),
        Operand::Time => ScalarSrc::Time,
        Operand::State(ix) => {
            let sv = &prog.state_vars[*ix as usize];
            if !sv.shape.is_empty() {
                return None;
            }
            ScalarSrc::State(sv.flat_offset)
        }
        _ => return None,
    })
}

/// The value of a decoded scalar operand.
///
/// # Safety
/// A [`ScalarSrc::Slot`] offset must be one of `slab`'s layout, and no other
/// thread may be writing it.
#[inline(always)]
unsafe fn scalar_get(s: &ScalarSrc, env: &Env, slab: Slab) -> f64 {
    match *s {
        // SAFETY: the caller's contract.
        ScalarSrc::Slot(o) => unsafe { *slab.at(o) },
        ScalarSrc::Lit(v) => v,
        ScalarSrc::Param(p) => env.params[p as usize],
        ScalarSrc::Time => env.t,
        ScalarSrc::State(off) => env.state[off],
    }
}

/// The element a one-element [`Instr::DataGather`] reads at subscript values
/// `v` from the source at `base`: its element, `+0.0` for a ghost, or `None`
/// where the read faults.
///
/// # Safety
/// `base` must address the gather's whole source box.
#[inline]
unsafe fn gather_one(sp: &DataGatherSpec, base: *const f64, v: &[f64]) -> Option<f64> {
    match sp.at(|d| v[d]) {
        // SAFETY: the spec resolves only positions inside its source box.
        DataAt::Elem(p) => Some(unsafe { *base.add(p) }),
        DataAt::Ghost => Some(0.0),
        DataAt::Fault { .. } => None,
    }
}

/// `op(a, b)` into `o` as a block operation, under the active precision: the
/// written-out kernels in binary64, [`binary_kernel_of`]'s function
/// otherwise (the binary32 kernel under Float32).
fn bin_op(op: BinCode, a: u16, b: u16, o: u16) -> BlockOp {
    if crate::precision::is_f32() {
        return BlockOp::Bin(ScalarBin::Fn(binary_kernel_of(op)), a, b, o);
    }
    let k = match op {
        BinCode::Add => return BlockOp::Add(a, b, o),
        BinCode::Sub => return BlockOp::Sub(a, b, o),
        BinCode::Mul => return BlockOp::Mul(a, b, o),
        BinCode::Div => return BlockOp::Div(a, b, o),
        BinCode::Lt => ScalarBin::Lt,
        BinCode::Le => ScalarBin::Le,
        BinCode::Gt => ScalarBin::Gt,
        BinCode::Ge => ScalarBin::Ge,
        BinCode::Eq => ScalarBin::Eq,
        BinCode::Ne => ScalarBin::Ne,
        BinCode::Min => ScalarBin::Min,
        BinCode::Max => ScalarBin::Max,
        _ => ScalarBin::Fn(binary_kernel_of(op)),
    };
    BlockOp::Bin(k, a, b, o)
}

impl Block {
    /// The block starting at `start`: instructions `start..` up to the
    /// first that has no scalar form or the next cut (a section start, a
    /// boundary of a conditional region or a recurrence body, a chain's
    /// start; see `Prepared::block_cuts`), or `None` when `start` itself has
    /// none. Each instruction is decoded under its own precision. A gather
    /// that may fault is a block of its own, so a fault stops a block before
    /// any other instruction of it.
    fn build(prog: &TapeProgram, slot_off: &[usize], cuts: &[bool], start: usize) -> Option<Built> {
        let mut b = Builder::default();
        let mut pc = start;
        while pc < prog.instrs.len() && !(pc > start && cuts[pc]) {
            let ins = &prog.instrs[pc];
            let may_fault = matches!(ins, Instr::DataGather { faults: true, .. });
            if may_fault && pc > start {
                break;
            }
            let ok = {
                let _precision = prog
                    .precision
                    .get(pc)
                    .filter(|&&p| p != crate::precision::active())
                    .map(|&p| crate::precision::enter(p));
                b.decode(prog, ins, slot_off)
            };
            if !ok {
                break;
            }
            pc += 1;
            if may_fault || b.regs > u16::MAX as usize - 64 {
                break;
            }
        }
        if pc == start {
            return None;
        }
        let mut outs: Vec<(u16, BlockOut)> = b
            .written
            .iter()
            .map(|&off| (b.at[&off], BlockOut::Slab(off)))
            .collect();
        outs.extend(b.dy.iter().map(|&(r, p)| (r, BlockOut::Dy(p))));
        Some(Built {
            end: pc,
            inputs: b.inputs,
            ops: b.ops,
            outs,
            n_regs: b.regs,
        })
    }

    /// Run the block (its parts in `code`'s arrays) and return the position
    /// after it, or `None`, having stored nothing, when its gather faults.
    ///
    /// # Safety
    /// The block was decoded against `slab`'s slot layout, every
    /// instruction before it has run, and no other thread touches the slab
    /// slots it reads or writes.
    #[inline(never)]
    unsafe fn run(
        &self,
        code: &mut ScalarCode,
        env: &Env,
        slab: Slab,
        dy: &mut [f64],
    ) -> Option<usize> {
        let span = |(lo, hi): (u32, u32)| lo as usize..hi as usize;
        let inputs = &code.inputs[span(self.inputs)];
        let ops = &code.ops[span(self.ops)];
        let outs = &code.outs[span(self.outs)];
        let r = code.regs.as_mut_ptr();
        let base_ptr = |b: &ScalarBase| -> *const f64 {
            match *b {
                ScalarBase::Slab(o) => slab.at(o),
                ScalarBase::State(ix) => super::resolve::state_ptr(env, ix),
            }
        };
        let gathers = &env.prog.tables.data_gathers;
        // SAFETY (every register access below): the builder numbered the
        // registers below its `n_regs`, which `regs` holds (`ensure`); the slab offsets and
        // sources were decoded against this call's layout (the caller's
        // contract), and a decoded window or position lies in its source.
        unsafe {
            for &(s, i) in inputs {
                *r.add(i as usize) = scalar_get(&s, env, slab);
            }
            let g = |i: u16| *r.add(i as usize);
            let put = |i: u16, v: f64| *r.add(i as usize) = v;
            for op in ops {
                match *op {
                    BlockOp::Add(a, b, o) => put(o, g(a) + g(b)),
                    BlockOp::Sub(a, b, o) => put(o, g(a) - g(b)),
                    BlockOp::Mul(a, b, o) => put(o, g(a) * g(b)),
                    BlockOp::Div(a, b, o) => put(o, g(a) / g(b)),
                    BlockOp::Bin(k, a, b, o) => put(o, k.apply(g(a), g(b))),
                    BlockOp::Un(f, a, o) => put(o, f(g(a))),
                    BlockOp::Neg(a, o) => put(o, -g(a)),
                    BlockOp::Select(c, a, b, o) => {
                        let (c, x, y) = (g(c), g(a), g(b));
                        put(o, if c != 0.0 { x } else { y });
                    }
                    BlockOp::Load(b, at, o) => put(o, *base_ptr(&b).add(at)),
                    BlockOp::Gather1 {
                        src,
                        x,
                        n,
                        spec,
                        out,
                    } => {
                        let v = g(x);
                        let k = subscript_of(v);
                        let base = base_ptr(&src);
                        let y = if k >= 1 && k <= n as i64 {
                            *base.add((k - 1) as usize)
                        } else {
                            gather_one(&gathers[spec as usize], base, &[v])?
                        };
                        put(out, y);
                    }
                    BlockOp::Gather2 {
                        src,
                        a,
                        b,
                        n0,
                        n1,
                        spec,
                        out,
                    } => {
                        let v = [g(a), g(b)];
                        let base = base_ptr(&src);
                        let y = match DataGatherSpec::direct_offset(&[n0 as usize, n1 as usize], &v)
                        {
                            Some(p) => *base.add(p),
                            None => gather_one(&gathers[spec as usize], base, &v)?,
                        };
                        put(out, y);
                    }
                    BlockOp::Gather {
                        src,
                        subs,
                        n,
                        spec,
                        out,
                    } => {
                        let mut v = [0.0f64; 4];
                        for d in 0..n as usize {
                            v[d] = g(subs[d]);
                        }
                        let base = base_ptr(&src);
                        put(
                            out,
                            gather_one(&gathers[spec as usize], base, &v[..n as usize])?,
                        );
                    }
                    BlockOp::Count {
                        rel,
                        axis,
                        lo,
                        n,
                        sorted,
                        x,
                        out,
                    } => {
                        let win = std::slice::from_raw_parts(
                            base_ptr(&axis).add(lo as usize),
                            n as usize,
                        );
                        let bisect = count_bisects(win, sorted);
                        put(out, count_one(rel, win, bisect, g(x)));
                    }
                }
            }
            for &(i, o) in outs {
                match o {
                    BlockOut::Slab(off) => *slab.at(off) = g(i),
                    BlockOut::Dy(p) => dy[p] = g(i),
                }
            }
        }
        Some(self.end)
    }
}

/// [`Block::build`]'s register assignment.
#[derive(Default)]
struct Builder {
    regs: usize,
    inputs: Vec<(ScalarSrc, u16)>,
    ops: Vec<BlockOp>,
    /// Slab offset -> the register holding its current value.
    at: FxHashMap<usize, u16>,
    /// Slab offsets written, in first-write order.
    written: Vec<usize>,
    seen: FxHashSet<usize>,
    dy: Vec<(u16, usize)>,
}

impl Builder {
    fn fresh(&mut self) -> u16 {
        self.regs += 1;
        (self.regs - 1) as u16
    }

    /// The register an operand is read from: a slab offset written earlier
    /// in the block is its register, anything else an input read at entry.
    fn src(&mut self, s: ScalarSrc) -> u16 {
        if let ScalarSrc::Slot(off) = s
            && let Some(&r) = self.at.get(&off)
        {
            return r;
        }
        let r = self.fresh();
        self.inputs.push((s, r));
        if let ScalarSrc::Slot(off) = s {
            self.at.insert(off, r);
        }
        r
    }

    /// A fresh register for a write to slab offset `off`.
    fn def(&mut self, off: usize) -> u16 {
        let r = self.fresh();
        self.bind(off, r);
        r
    }

    /// Slab offset `off` holds register `r` from here on.
    fn bind(&mut self, off: usize, r: u16) {
        self.at.insert(off, r);
        if self.seen.insert(off) {
            self.written.push(off);
        }
    }

    /// Append `ins`'s scalar form, or return `false` (having appended
    /// nothing) when it has none: what its [`exec_straight`] arm does for a
    /// scalar `out` (and [`exec_lanes`] for a one-lane program), operation
    /// for operation.
    ///
    /// [`exec_lanes`]: super::lanes::exec_lanes
    fn decode(&mut self, prog: &TapeProgram, ins: &Instr, slot_off: &[usize]) -> bool {
        let src = |o: &Operand| scalar_src(prog, o, slot_off);
        let scalar = |out: &SlotId| prog.tables.slots[*out as usize].scalar;
        let off = |out: &SlotId| slot_off[*out as usize];
        let base = |s: &SrcRef| match s {
            SrcRef::Slot(k) => ScalarBase::Slab(slot_off[*k as usize]),
            SrcRef::State(ix) => ScalarBase::State(*ix),
        };
        let src_shape = |s: &SrcRef| -> &[usize] {
            match s {
                SrcRef::Slot(k) => &prog.tables.slots[*k as usize].shape[..],
                SrcRef::State(ix) => &prog.state_vars[*ix as usize].shape[..],
            }
        };
        match ins {
            Instr::Bin { op, a, b, out } if scalar(out) => {
                let (Some(a), Some(b)) = (src(a), src(b)) else {
                    return false;
                };
                let (x, y) = (self.src(a), self.src(b));
                let o = self.def(off(out));
                self.ops.push(bin_op(*op, x, y, o));
            }
            Instr::Un { op, a, out } if scalar(out) => {
                let Some(a) = src(a) else { return false };
                let x = self.src(a);
                let o = self.def(off(out));
                self.ops.push(BlockOp::Un(unary_kernel_of(*op), x, o));
            }
            Instr::Neg { a, out } if scalar(out) => {
                let Some(a) = src(a) else { return false };
                let x = self.src(a);
                let o = self.def(off(out));
                self.ops.push(BlockOp::Neg(x, o));
            }
            Instr::Copy { a, out } if scalar(out) => {
                // A copy is its source's value under a new offset.
                let Some(a) = src(a) else { return false };
                let x = self.src(a);
                self.bind(off(out), x);
            }
            Instr::Select { cond, a, b, out } if scalar(out) => {
                let (Some(c), Some(a), Some(b)) = (src(cond), src(a), src(b)) else {
                    return false;
                };
                let (c, x, y) = (self.src(c), self.src(a), self.src(b));
                let o = self.def(off(out));
                self.ops.push(BlockOp::Select(c, x, y, o));
            }
            Instr::LoadElem { src: s, idx, out } if scalar(out) => {
                let shape = src_shape(s);
                if idx.len() != shape.len() {
                    return false;
                }
                let mut at = 0usize;
                let mut stride = 1usize;
                for d in (0..idx.len()).rev() {
                    at += idx[d] * stride;
                    stride *= shape[d];
                }
                let o = self.def(off(out));
                self.ops.push(BlockOp::Load(base(s), at, o));
            }
            Instr::DataGather {
                src: s, spec, out, ..
            } if scalar(out) => {
                let sp = &prog.tables.data_gathers[*spec as usize];
                if !sp.shape.is_empty() || sp.subs.len() > 4 {
                    return false;
                }
                let Some(subs) = sp
                    .subs
                    .iter()
                    .map(src)
                    .collect::<Option<SmallVec<[_; 4]>>>()
                else {
                    return false;
                };
                let regs: SmallVec<[u16; 4]> = subs.iter().map(|&s| self.src(s)).collect();
                let o = self.def(off(out));
                let dims = (
                    sp.subs.len(),
                    sp.src_shape.len(),
                    sp.src_shape.first().and_then(|&n| u32::try_from(n).ok()),
                    sp.src_shape.get(1).and_then(|&n| u32::try_from(n).ok()),
                );
                let op = match dims {
                    (1, 1, _, _) => BlockOp::Gather1 {
                        src: base(s),
                        x: regs[0],
                        n: sp.src_shape[0],
                        spec: *spec,
                        out: o,
                    },
                    (2, 2, Some(n0), Some(n1)) => BlockOp::Gather2 {
                        src: base(s),
                        a: regs[0],
                        b: regs[1],
                        n0,
                        n1,
                        spec: *spec,
                        out: o,
                    },
                    _ => {
                        let mut r = [0u16; 4];
                        r[..regs.len()].copy_from_slice(&regs);
                        BlockOp::Gather {
                            src: base(s),
                            subs: r,
                            n: regs.len() as u8,
                            spec: *spec,
                            out: o,
                        }
                    }
                };
                self.ops.push(op);
            }
            Instr::Count {
                rel,
                axis,
                lo,
                n,
                sorted,
                x,
                out,
            } if scalar(out) => {
                // A window outside the axis's box is left to the general
                // path, which refuses it.
                let ashape = src_shape(axis);
                if ashape.len() != 1 || *lo as usize + *n as usize > ashape[0] {
                    return false;
                }
                let Some(x) = src(x) else { return false };
                let x = self.src(x);
                let o = self.def(off(out));
                self.ops.push(BlockOp::Count {
                    rel: *rel,
                    axis: base(axis),
                    lo: *lo,
                    n: *n,
                    sorted: *sorted,
                    x,
                    out: o,
                });
            }
            Instr::Lanes { spec } => return self.lane(prog, &prog.lanes[*spec as usize], slot_off),
            _ => return false,
        }
        true
    }

    /// Inline a lane program of one lane and no lane inputs: its scalars
    /// read as operands, its micro-ops on fresh registers (a move is its
    /// source's register), its writes bound at the end. `false` (having
    /// appended nothing) for any other lane program.
    fn lane(&mut self, prog: &TapeProgram, ls: &LaneSpec, slot_off: &[usize]) -> bool {
        let plain = ls.micro.iter().all(|m| {
            matches!(
                m,
                MicroOp::Bin { .. }
                    | MicroOp::Un { .. }
                    | MicroOp::Neg { .. }
                    | MicroOp::Select { .. }
                    | MicroOp::Mov { .. }
            )
        });
        if ls.lanes != 1 || !ls.inputs.is_empty() || !plain {
            return false;
        }
        let Some(scalars) = ls
            .scalars
            .iter()
            .map(|o| scalar_src(prog, o, slot_off))
            .collect::<Option<SmallVec<[_; 8]>>>()
        else {
            return false;
        };
        let sc: SmallVec<[u16; 8]> = scalars.iter().map(|&s| self.src(s)).collect();
        let mut lr: SmallVec<[Option<u16>; 16]> = SmallVec::from_elem(None, ls.n_regs as usize);
        let rd = |b: &mut Builder, m: &MRef, lr: &mut SmallVec<[Option<u16>; 16]>| match *m {
            MRef::Reg(x) => *lr[x as usize].get_or_insert_with(|| {
                // The lowering writes every register before it reads it.
                debug_assert!(false, "a one-lane program reads register {x} unwritten");
                b.fresh()
            }),
            MRef::Scal(i) => sc[i as usize],
            MRef::In(_) => unreachable!("a one-lane block has no lane inputs"),
        };
        for op in &ls.micro {
            match op {
                MicroOp::Bin { op, a, b, out } => {
                    let (x, y) = (rd(self, a, &mut lr), rd(self, b, &mut lr));
                    let o = self.fresh();
                    self.ops.push(bin_op(*op, x, y, o));
                    lr[*out as usize] = Some(o);
                }
                MicroOp::Un { op, a, out } => {
                    let x = rd(self, a, &mut lr);
                    let o = self.fresh();
                    self.ops.push(BlockOp::Un(unary_kernel_of(*op), x, o));
                    lr[*out as usize] = Some(o);
                }
                MicroOp::Neg { a, out } => {
                    let x = rd(self, a, &mut lr);
                    let o = self.fresh();
                    self.ops.push(BlockOp::Neg(x, o));
                    lr[*out as usize] = Some(o);
                }
                MicroOp::Select { cond, a, b, out } => {
                    let c = rd(self, cond, &mut lr);
                    let (x, y) = (rd(self, a, &mut lr), rd(self, b, &mut lr));
                    let o = self.fresh();
                    self.ops.push(BlockOp::Select(c, x, y, o));
                    lr[*out as usize] = Some(o);
                }
                MicroOp::Mov { a, out } => {
                    let x = rd(self, a, &mut lr);
                    lr[*out as usize] = Some(x);
                }
                _ => unreachable!("checked above"),
            }
        }
        for w in &ls.writes {
            let r = rd(self, &w.src, &mut lr);
            match &w.dst {
                LaneDst::Dy(pos) => self.dy.push((r, pos.at(0) as usize)),
                LaneDst::Slot(k) => self.bind(slot_off[*k as usize], r),
            }
        }
        true
    }
}

/// Everything a straight-line instruction reads besides its own scratch:
/// the call's environment, the slab and the per-call tables.
#[derive(Clone, Copy)]
pub(super) struct Cx<'a> {
    pub(super) env: &'a Env<'a>,
    pub(super) slab: Slab<'a>,
    pub(super) idx_tables: &'a [Vec<Option<super::fused::IndexTable>>],
    pub(super) simd: SimdLevel,
    pub(super) dy_home: &'a [usize],
    pub(super) dy: *mut f64,
    pub(super) dy_len: usize,
}

/// Execute one straight-line instruction (see [`Instr::may_run_on_worker`]) with this
/// thread's `scratch`, splitting it under width `call_split`.
///
/// # Safety
/// `cx` must describe the current call, and every instruction this one
/// depends on must have run.
pub(super) unsafe fn exec_straight(cx: &Cx, ins: &Instr, scratch: &mut Scratch, call_split: usize) {
    // SAFETY (every slab, state and `dy` access below): each pointer comes
    // from the call's slab handle, its state or its `dy` at a slot,
    // variable or position the program defines over the box the access
    // walks; `out` never shares storage with an operand the slab coloring
    // keeps live; and nothing another thread runs meanwhile touches what
    // this instruction writes (the caller's contract).
    let Cx {
        env,
        slab,
        dy_home,
        dy,
        dy_len,
        ..
    } = *cx;
    let prog = env.prog;
    // An instruction that splits under this call's width runs as one
    // fork-join over its share function, as a call plan's task would.
    #[cfg(not(target_arch = "wasm32"))]
    if call_split > 1 && !matches!(ins, Instr::Fused { .. }) && shares(prog, ins) {
        let ways = super::par::split_width(prog, ins, call_split);
        if ways > 1
            && let Some(op) = unsafe { resolve_split(cx, ins, &mut scratch.asm_parts) }
        {
            let precision = crate::precision::active();
            super::pool::run(ways, &|w| {
                // The caller's precision is thread-local; carry it over.
                let _p = crate::precision::enter(precision);
                // SAFETY: the shares of one split write disjoint parts of
                // its output, and read only what instructions before it
                // wrote.
                unsafe { run_split_share(&op, w, ways) }
            });
            return;
        }
    }
    let Scratch {
        fregs, fscratch, ..
    } = scratch;
    #[cfg(target_arch = "wasm32")]
    let _ = call_split;
    match ins {
        Instr::Bin { op, a, b, out } => {
            let desc = &prog.tables.slots[*out as usize];
            let off = slab.off(*out);
            if desc.scalar {
                let f = binary_kernel_of(*op);
                let x = resolve_scalar(a, env, slab);
                let y = resolve_scalar(b, env, slab);
                unsafe { *slab.at(off) = f(x, y) };
            } else {
                let av = resolve_rv(a, &desc.shape, env, slab);
                let bv = resolve_rv(b, &desc.shape, env, slab);
                let dst = slab.at(off);
                let sh = &desc.shape;
                // Monomorphized over the shared table
                // (`dispatch_bin_kernel`) — one indirect call per NODE
                // becomes an inlined, vectorizable element loop.
                macro_rules! strided {
                    ($f:expr) => {
                        unsafe { ew2(dst, sh, &av, &bv, $f) }
                    };
                }
                dispatch_bin_kernel!(op, strided);
            }
        }
        Instr::Un { op, a, out } => {
            let desc = &prog.tables.slots[*out as usize];
            let off = slab.off(*out);
            if desc.scalar {
                let f = unary_kernel_of(*op);
                let x = resolve_scalar(a, env, slab);
                unsafe { *slab.at(off) = f(x) };
            } else {
                let av = resolve_rv(a, &desc.shape, env, slab);
                let dst = slab.at(off);
                let sh = &desc.shape;
                // Step 4: monomorphized arms for the common unaries via
                // the shared table (`dispatch_un_kernel`) — one
                // fn-pointer call per ELEMENT becomes an inlined loop.
                macro_rules! strided {
                    ($f:expr) => {
                        unsafe { ew1(dst, sh, &av, $f) }
                    };
                }
                dispatch_un_kernel!(op, strided);
            }
        }
        Instr::Neg { a, out } => {
            let desc = &prog.tables.slots[*out as usize];
            let off = slab.off(*out);
            if desc.scalar {
                let x = resolve_scalar(a, env, slab);
                unsafe { *slab.at(off) = -x };
            } else {
                let av = resolve_rv(a, &desc.shape, env, slab);
                unsafe { ew1(slab.at(off), &desc.shape, &av, |x| -x) };
            }
        }
        Instr::Select { cond, a, b, out } => {
            let desc = &prog.tables.slots[*out as usize];
            let off = slab.off(*out);
            if desc.scalar {
                let c = resolve_scalar(cond, env, slab);
                let x = resolve_scalar(a, env, slab);
                let y = resolve_scalar(b, env, slab);
                unsafe { *slab.at(off) = if c != 0.0 { x } else { y } };
            } else {
                let cv = resolve_rv(cond, &desc.shape, env, slab);
                let av = resolve_rv(a, &desc.shape, env, slab);
                let bv = resolve_rv(b, &desc.shape, env, slab);
                unsafe { ew_select(slab.at(off), &desc.shape, &cv, &av, &bv) };
            }
        }
        Instr::Gather { src, plan, out } => {
            let full = env.prep.plan_full[*plan as usize];
            let plan = &prog.tables.plans[*plan as usize];
            let sv = resolve_src(src, env, slab);
            let off = slab.off(*out);
            unsafe { exec_gather(plan, &sv, slab.at(off), full) };
        }
        Instr::LoadElem { src, idx, out } => {
            let sv = resolve_src(src, env, slab);
            debug_assert_eq!(idx.len(), sv.shape.len());
            let mut soff = 0i64;
            for (d, &i0) in idx.iter().enumerate() {
                debug_assert!(i0 < sv.shape[d], "LoadElem index out of bounds");
                soff += sv.strides[d] * i0 as i64;
            }
            let off = slab.off(*out);
            unsafe { *slab.at(off) = *sv.ptr.offset(soff as isize) };
        }
        Instr::Ramp { axis, lo, out } => {
            let desc = &prog.tables.slots[*out as usize];
            let off = slab.off(*out);
            let a = *axis as usize;
            let pre: usize = desc.shape[..a].iter().product();
            let ax = desc.shape[a];
            let post: usize = desc.shape[a + 1..].iter().product();
            let mut p = slab.at(off);
            for _ in 0..pre.max(1) {
                for q in 0..ax {
                    let v = (*lo + q as i64) as f64;
                    unsafe {
                        for _ in 0..post.max(1) {
                            *p = v;
                            p = p.add(1);
                        }
                    }
                }
            }
        }
        Instr::Fill { v, out } => {
            let desc = &prog.tables.slots[*out as usize];
            let off = slab.off(*out);
            let s = resolve_scalar(v, env, slab);
            if desc.scalar {
                unsafe { *slab.at(off) = s };
            } else {
                let n = desc.elems();
                unsafe {
                    let p = slab.at(off);
                    for k in 0..n {
                        *p.add(k) = s;
                    }
                }
            }
        }
        Instr::Copy { a, out } => {
            let desc = &prog.tables.slots[*out as usize];
            let off = slab.off(*out);
            if desc.scalar {
                let x = resolve_scalar(a, env, slab);
                unsafe { *slab.at(off) = x };
            } else {
                let av = resolve_rv(a, &desc.shape, env, slab);
                match av {
                    Rv::S(_) => panic!("array Copy from a scalar operand"),
                    Rv::V { ptr, strides } => unsafe {
                        copy_strided(
                            slab.at(off),
                            &rm_strides(&desc.shape),
                            ptr,
                            &strides,
                            &desc.shape,
                        );
                    },
                }
            }
        }
        Instr::Region {
            base,
            src,
            region,
            out,
        } => {
            let spec = &prog.tables.regions[*region as usize];
            let desc = &prog.tables.slots[*out as usize];
            let off = slab.off(*out);
            let base_off = slab.off(*base);
            let n = desc.elems();
            unsafe {
                // `out = base` (skip when the coloring aliased them, which
                // it can only do at identical offsets).
                if base_off != off {
                    std::ptr::copy_nonoverlapping(slab.at(base_off) as *const f64, slab.at(off), n);
                }
            }
            // Overwrite the region sub-block.
            let out_rm = rm_strides(&desc.shape);
            let mut dbase = 0i64;
            for d in 0..desc.shape.len() {
                dbase += out_rm[d] * spec.dest_lo[d] as i64;
            }
            let sub_dst = unsafe { slab.at(off).offset(dbase as isize) };
            let sv = resolve_rv(src, &spec.shape, env, slab);
            match sv {
                Rv::S(v) => unsafe { fill_strided(sub_dst, &out_rm, &spec.shape, v) },
                Rv::V { ptr, strides } => unsafe {
                    copy_strided(sub_dst, &out_rm, ptr, &strides, &spec.shape);
                },
            }
        }
        Instr::Assemble { table, out } => {
            let desc = &prog.tables.slots[*out as usize];
            let off = slab.off(*out);
            let dst = slab.at(off);
            let parts = &prog.tables.assemblies[*table as usize].parts;
            let covered = env.prep.asm_covered[*table as usize];
            let out_rm = rm_strides(&desc.shape);
            if !covered {
                unsafe { std::slice::from_raw_parts_mut(dst, desc.elems()).fill(0.0) };
            }
            for (src, region) in parts {
                let spec = &prog.tables.regions[*region as usize];
                let mut dbase = 0i64;
                for d in 0..desc.shape.len() {
                    dbase += out_rm[d] * spec.dest_lo[d] as i64;
                }
                let sub_dst = unsafe { dst.offset(dbase as isize) };
                match resolve_rv(src, &spec.shape, env, slab) {
                    Rv::S(v) => unsafe { fill_strided(sub_dst, &out_rm, &spec.shape, v) },
                    Rv::V { ptr, strides } => unsafe {
                        copy_strided(sub_dst, &out_rm, ptr, &strides, &spec.shape);
                    },
                }
            }
        }
        Instr::Count {
            rel,
            axis,
            lo,
            n,
            sorted,
            x,
            out,
        } => {
            let (aptr, ashape) = src_base(axis, env, slab);
            // The window is read unchecked below, so it is checked here, once
            // per execution, in every build: an axis whose run-time box no
            // longer holds the window the lowering saw is refused, as the
            // reference executor and the XLA emitter refuse it.
            assert!(
                ashape.len() == 1 && *lo as usize + *n as usize <= ashape[0],
                "Count axis has shape {:?}, which does not hold the window {}..{}",
                ashape,
                lo,
                *lo as usize + *n as usize
            );
            // Rank 1, row-major: the window is contiguous. `out` never shares
            // storage with the axis (the slab coloring keeps them apart).
            let win = unsafe { std::slice::from_raw_parts(aptr.add(*lo as usize), *n as usize) };
            let desc = &prog.tables.slots[*out as usize];
            let off = slab.off(*out);
            if desc.scalar {
                let xv = resolve_scalar(x, env, slab);
                let bisect = count_bisects(win, *sorted);
                unsafe { *slab.at(off) = count_one(*rel, win, bisect, xv) };
            } else {
                let xv = resolve_rv(x, &desc.shape, env, slab);
                let dst = slab.at(off);
                unsafe { count_many(dst, &desc.shape, &xv, *rel, win, *sorted) };
            }
        }
        Instr::ConstArray { data, out } => {
            let d = &prog.tables.const_data[*data as usize];
            let off = slab.off(*out);
            debug_assert_eq!(d.values.len(), prog.tables.slots[*out as usize].elems());
            unsafe {
                std::ptr::copy_nonoverlapping(d.values.as_ptr(), slab.at(off), d.values.len());
            }
        }
        Instr::Reduce {
            op,
            init,
            src,
            axes,
            reverse,
            src_shape,
            out,
        } => {
            let f = binary_kernel_of(*op);
            let sv = resolve_src(src, env, slab);
            debug_assert_eq!(&sv.shape[..], &src_shape[..], "Reduce source box");
            let desc = &prog.tables.slots[*out as usize];
            let ooff = slab.off(*out);
            let dst = slab.at(ooff);
            // Seed every output position with the identity, then fold.
            let n_out = desc.elems();
            unsafe {
                for k in 0..n_out {
                    *dst.add(k) = *init;
                }
            }
            // Folding the LEADING axes of a row-major source (the promoted
            // contraction box) is one contiguous row per leading position,
            // in the same row-major visiting order.
            let nd = sv.shape.len();
            if axes.iter().enumerate().all(|(k, &a)| a as usize == k)
                && sv.strides[..] == rm_strides(&sv.shape)[..]
            {
                let src = sv.ptr;
                let rows: usize = sv.shape[..axes.len()].iter().product();
                macro_rules! fold_rows {
                    ($f:expr) => {
                        if *reverse {
                            // One leading axis, its rows from the last.
                            for r in (0..rows).rev() {
                                unsafe { reduce_rows(dst, n_out, src.add(r * n_out), 1, $f) }
                            }
                        } else {
                            unsafe { reduce_rows(dst, n_out, src, rows, $f) }
                        }
                    };
                }
                dispatch_bin_kernel!(op, fold_rows);
                return;
            }
            // One folded axis anywhere in a contiguous source: each output
            // cell folds its own run in axis order.
            if !*reverse && axes.len() == 1 && sv.strides[..] == rm_strides(&sv.shape)[..] {
                let a = axes[0] as usize;
                let pre: usize = sv.shape[..a].iter().product();
                let post: usize = sv.shape[a + 1..].iter().product();
                let (src, len) = (sv.ptr, sv.shape[a]);
                macro_rules! fold_axis {
                    ($f:expr) => {
                        unsafe { reduce_axis(dst, src, pre, len, post, $f) }
                    };
                }
                dispatch_bin_kernel!(op, fold_axis);
                return;
            }
            // Kept (un-reduced) source axes, in order; their row-major
            // strides in the OUTPUT box line up positionally.
            let keep: SmallVec<[usize; 4]> =
                (0..nd).filter(|d| !axes.contains(&(*d as u8))).collect();
            let out_rm = rm_strides(&desc.shape);
            // Row-major (LAST axis fastest) walk of the source box — the
            // oracle's odometer; see the `Instr::Reduce` docs.
            let mut idx: SmallVec<[usize; 4]> = SmallVec::from_elem(0usize, nd);
            let total: usize = sv.shape.iter().product();
            for _ in 0..total {
                let mut soff = 0i64;
                let mut doff = 0i64;
                for d in 0..nd {
                    // A reverse fold walks its one folded axis from the end.
                    let at = if *reverse && axes[0] as usize == d {
                        sv.shape[d] - 1 - idx[d]
                    } else {
                        idx[d]
                    };
                    soff += sv.strides[d] * at as i64;
                }
                for (j, &d) in keep.iter().enumerate() {
                    doff += out_rm[j] * idx[d] as i64;
                }
                unsafe {
                    let p = dst.offset(doff as isize);
                    *p = f(*p, *sv.ptr.offset(soff as isize));
                }
                let mut d = nd;
                while d > 0 {
                    d -= 1;
                    idx[d] += 1;
                    if idx[d] < sv.shape[d] {
                        break;
                    }
                    idx[d] = 0;
                }
            }
        }
        Instr::Scan {
            op,
            init,
            src,
            axis,
            inclusive,
            reverse,
            src_shape,
            out,
        } => {
            let sv = resolve_src(src, env, slab);
            debug_assert_eq!(&sv.shape[..], &src_shape[..], "Scan source box");
            let dst = slab.slot(*out);
            let (a, init, inclusive, reverse) = (*axis as usize, *init, *inclusive, *reverse);
            macro_rules! scan {
                ($f:expr) => {
                    unsafe { scan_axis(dst, &sv, a, init, inclusive, reverse, $f) }
                };
            }
            dispatch_bin_kernel!(op, scan);
        }
        Instr::IndexGather {
            src,
            idx,
            spec,
            out,
        } => {
            let spec = &prog.tables.index_gathers[*spec as usize];
            let sv = resolve_src(src, env, slab);
            let iv = resolve_rv(idx, &spec.shape, env, slab);
            let dst = slab.slot(*out);
            unsafe { index_gather(dst, spec, &sv, &iv) };
        }
        Instr::DataGather {
            src,
            spec,
            out,
            faults,
        } => {
            let spec = &prog.tables.data_gathers[*spec as usize];
            // One element read at scalar subscripts: the position straight
            // from the subscripts' values, no source view, no subscript
            // views. A read that faults takes the general path below, which
            // latches it.
            if spec.shape.is_empty() && spec.subs.len() <= 4 {
                let mut v = [0.0f64; 4];
                for (d, o) in spec.subs.iter().enumerate() {
                    v[d] = resolve_scalar(o, env, slab);
                }
                let (base, _) = src_base(src, env, slab);
                // SAFETY: `base` addresses the gather's source box.
                if let Some(x) = unsafe { gather_one(spec, base, &v[..spec.subs.len()]) } {
                    unsafe { *slab.slot(*out) = x };
                    return;
                }
            }
            let sv = resolve_src(src, env, slab);
            let subs: SmallVec<[Rv; 4]> = spec
                .subs
                .iter()
                .map(|o| resolve_rv(o, &spec.shape, env, slab))
                .collect();
            let dst = slab.slot(*out);
            let faulted = unsafe { data_gather(dst, spec, &sv, &subs) };
            // A gather in a lazily evaluated position reads `NaN` at a fault
            // and leaves the latching to its rule's `FaultScan`.
            if faulted && *faults {
                let first =
                    spec.first_fault(|d, k| unsafe { data_gather_sub(&subs[d], &spec.shape, k) });
                if let (Some((key, msg)), Some(order)) = (first, &spec.order) {
                    latch_ordered_fault(order.rule, &key, || msg);
                }
            }
        }
        Instr::TableGather { src, table, out } => {
            let sv = resolve_src(src, env, slab);
            let tbl = &prog.tables.gather_tables[*table as usize];
            debug_assert_eq!(&sv.shape[..], &tbl.src_shape[..], "TableGather source box");
            let dst = slab.slot(*out);
            unsafe { table_gather(dst, &sv, &tbl.pos) };
        }
        Instr::SegReduce {
            op,
            init,
            src,
            mask,
            table,
            out,
        } => {
            let rows = &prog.tables.seg_tables[*table as usize].rows;
            let src = slab.slot(*src) as *const f64;
            let mask = mask.map(|m| slab.slot(m) as *const f64);
            let dst = slab.slot(*out);
            let init = *init;
            macro_rules! fold {
                ($f:expr) => {
                    unsafe { seg_reduce(dst, src, mask, rows, 0, init, $f) }
                };
            }
            dispatch_bin_kernel!(op, fold);
        }
        Instr::Reshape { src, out } => {
            let sv = resolve_src(src, env, slab);
            debug_assert_eq!(
                sv.shape.iter().product::<usize>(),
                prog.tables.slots[*out as usize]
                    .shape
                    .iter()
                    .product::<usize>(),
                "Reshape element count"
            );
            // The source walked in its own row-major order, written
            // contiguously: `out`'s row-major layout over its own box.
            let dst = slab.slot(*out);
            unsafe { copy_strided(dst, &rm_strides(&sv.shape), sv.ptr, &sv.strides, &sv.shape) };
        }
        Instr::Fused { spec } => unsafe { exec_fused(*spec as usize, cx, fregs, fscratch) },
        Instr::DyWrite { write } => {
            let w = &prog.tables.dy_writes[*write as usize];
            // Its fused group already stored the slot into `dy`.
            if dy_home[w.slot as usize] != usize::MAX {
                return;
            }
            let desc = &prog.tables.slots[w.slot as usize];
            let off = slab.off(w.slot);
            if let Some(pos) = &w.scatter {
                // The slot is contiguous row-major, the order `pos` lists.
                debug_assert_eq!(pos.len(), desc.elems());
                for (k, &p) in pos.iter().enumerate() {
                    unsafe { *dy.add(p) = *slab.at(off + k) };
                }
                return;
            }
            match w.scalar_flat {
                Some(flat) => {
                    debug_assert!(desc.scalar);
                    unsafe { *dy.add(flat) = *slab.at(off) };
                }
                None => {
                    // A column-major program's slot has the state block's
                    // own layout, so a whole-box write is one copy.
                    let sv = &prog.state_vars[w.var as usize];
                    let cm = dy_strides(prog, &sv.shape);
                    let mut dbase = sv.flat_offset as i64;
                    for d in 0..sv.shape.len() {
                        dbase += w.dest_lo[d] as i64 * cm[d];
                    }
                    debug_assert!(
                        sv.flat_offset + sv.shape.iter().product::<usize>().max(1) <= dy_len
                    );
                    unsafe {
                        copy_strided(
                            dy.offset(dbase as isize),
                            &cm,
                            slab.at(off) as *const f64,
                            &rm_strides(&desc.shape),
                            &desc.shape,
                        );
                    }
                }
            }
        }
        _ => unreachable!("not a straight-line instruction: {}", ins.opcode()),
    }
}

/// Whether [`exec_share`] can run `ins` share by share: whether it splits
/// at all, from the instruction loop or as one task of a call plan (see
/// `plan`).
#[cfg(not(target_arch = "wasm32"))]
pub(super) fn shares(prog: &TapeProgram, ins: &Instr) -> bool {
    match ins {
        Instr::Fused { .. } | Instr::Assemble { .. } => true,
        Instr::Copy { out, .. } | Instr::Gather { out, .. } => {
            !prog.tables.slots[*out as usize].scalar
        }
        Instr::Reduce { axes, out, .. } => {
            !prog.tables.slots[*out as usize].scalar
                && axes.iter().enumerate().all(|(k, &a)| a as usize == k)
        }
        Instr::DyWrite { write } => {
            let w = &prog.tables.dy_writes[*write as usize];
            w.scatter.is_none() && w.scalar_flat.is_none()
        }
        Instr::Scan { axis: 0, .. } => true,
        _ => false,
    }
}

/// Run share `w` of `ins` split `ways` wide (an instruction [`shares`]
/// admits) on this thread, with this thread's `scratch`: the part of it the
/// pool's worker `w` runs when the calling thread splits it.
///
/// # Safety
/// As for [`exec_straight`].
#[cfg(not(target_arch = "wasm32"))]
pub(super) unsafe fn exec_share(
    cx: &Cx,
    ins: &Instr,
    scratch: &mut Scratch,
    w: usize,
    ways: usize,
) {
    if let Instr::Fused { spec } = ins {
        // SAFETY: the caller's contract.
        unsafe {
            super::fused::exec_fused_share(*spec as usize, cx, &mut scratch.fscratch, w, ways)
        };
        return;
    }
    // SAFETY: the caller's contract.
    match unsafe { resolve_split(cx, ins, &mut scratch.asm_parts) } {
        Some(op) => unsafe { run_split_share(&op, w, ways) },
        // Not the layout a split assumes: one share runs it whole.
        None if w == 0 => unsafe { exec_straight(cx, ins, scratch, 1) },
        None => {}
    }
}

/// A split instruction other than a fused group, resolved for one call:
/// what every share of it reads (see [`run_split_share`]).
#[cfg(not(target_arch = "wasm32"))]
enum SplitOp<'a> {
    /// Nothing to do (a `DyWrite` whose fused group stored into `dy`).
    Skip,
    Assemble {
        dst: *mut f64,
        shape: &'a [usize],
        regions: &'a [RegionSpec],
        parts: &'a [super::par::AsmPart],
        covered: bool,
    },
    /// A block copy (`Copy`, `DyWrite`).
    Copy {
        dst: *mut f64,
        dstr: DimI,
        src: *const f64,
        sstr: DimI,
        shape: &'a [usize],
    },
    /// The leading axes of a contiguous source folded into `n_out` cells.
    Reduce {
        op: BinCode,
        init: f64,
        reverse: bool,
        src: *const f64,
        rows: usize,
        n_out: usize,
        dst: *mut f64,
    },
    /// A scan along the leading axis of a contiguous `[len, post]` box.
    Scan {
        op: BinCode,
        init: f64,
        inclusive: bool,
        reverse: bool,
        src: *const f64,
        len: usize,
        post: usize,
        dst: *mut f64,
    },
    Gather {
        plan: &'a GatherPlan,
        src: super::resolve::SrcView,
        out: *mut f64,
        full: bool,
    },
}

// SAFETY: the pointers address the slab, the state and `dy`, which outlive
// the fork-join that shares the resolved instruction; each share writes only
// its own part of the output (`run_split_share`).
#[cfg(not(target_arch = "wasm32"))]
unsafe impl Sync for SplitOp<'_> {}

/// `ins` (an instruction [`shares`] admits, not a fused group) resolved for
/// this call, or `None` when its operands are not in the layout its split
/// assumes, so it runs whole. An assembly's parts are resolved into
/// `parts`.
///
/// # Safety
/// As for [`exec_straight`].
#[cfg(not(target_arch = "wasm32"))]
unsafe fn resolve_split<'a>(
    cx: &Cx<'a>,
    ins: &'a Instr,
    parts: &'a mut Vec<super::par::AsmPart>,
) -> Option<SplitOp<'a>> {
    let Cx {
        env,
        slab,
        dy_home,
        dy,
        ..
    } = *cx;
    let prog = env.prog;
    let slot = |s: SlotId| slab.slot(s);
    Some(match ins {
        Instr::Assemble { table, out } => {
            let desc = &prog.tables.slots[*out as usize];
            if desc.shape.is_empty() {
                return None;
            }
            let out_rm = rm_strides(&desc.shape);
            parts.clear();
            for (src, region) in &prog.tables.assemblies[*table as usize].parts {
                let spec = &prog.tables.regions[*region as usize];
                let mut dbase = 0i64;
                for d in 0..desc.shape.len() {
                    dbase += out_rm[d] * spec.dest_lo[d] as i64;
                }
                let rv = resolve_rv(src, &spec.shape, env, slab);
                parts.push(super::par::AsmPart::new(*region, dbase, rv));
            }
            SplitOp::Assemble {
                dst: slot(*out),
                shape: &desc.shape,
                regions: &prog.tables.regions,
                parts,
                covered: env.prep.asm_covered[*table as usize],
            }
        }
        Instr::Copy { a, out } => {
            let desc = &prog.tables.slots[*out as usize];
            match resolve_rv(a, &desc.shape, env, slab) {
                Rv::S(_) => panic!("array Copy from a scalar operand"),
                Rv::V { ptr, strides } => SplitOp::Copy {
                    dst: slot(*out),
                    dstr: rm_strides(&desc.shape),
                    src: ptr,
                    sstr: strides,
                    shape: &desc.shape,
                },
            }
        }
        Instr::DyWrite { write } => {
            let wr = &prog.tables.dy_writes[*write as usize];
            // Its fused group already stored the slot into `dy`.
            if dy_home[wr.slot as usize] != usize::MAX {
                return Some(SplitOp::Skip);
            }
            if wr.scatter.is_some() || wr.scalar_flat.is_some() {
                return None;
            }
            let desc = &prog.tables.slots[wr.slot as usize];
            let sv = &prog.state_vars[wr.var as usize];
            let cm = dy_strides(prog, &sv.shape);
            let mut dbase = sv.flat_offset as isize;
            for d in 0..sv.shape.len() {
                dbase += wr.dest_lo[d] as isize * cm[d] as isize;
            }
            SplitOp::Copy {
                dst: dy.wrapping_offset(dbase),
                dstr: cm,
                src: slot(wr.slot),
                sstr: rm_strides(&desc.shape),
                shape: &desc.shape,
            }
        }
        Instr::Reduce {
            op,
            init,
            src,
            axes,
            reverse,
            out,
            ..
        } => {
            let sv = resolve_src(src, env, slab);
            if sv.strides[..] != rm_strides(&sv.shape)[..] {
                return None;
            }
            SplitOp::Reduce {
                op: *op,
                init: *init,
                reverse: *reverse,
                src: sv.ptr,
                rows: sv.shape[..axes.len()].iter().product(),
                n_out: prog.tables.slots[*out as usize].elems(),
                dst: slot(*out),
            }
        }
        Instr::Scan {
            op,
            init,
            src,
            axis: 0,
            inclusive,
            reverse,
            src_shape,
            out,
        } => {
            let sv = resolve_src(src, env, slab);
            if sv.strides[..] != rm_strides(&sv.shape)[..] || src_shape.is_empty() {
                return None;
            }
            SplitOp::Scan {
                op: *op,
                init: *init,
                inclusive: *inclusive,
                reverse: *reverse,
                src: sv.ptr,
                len: src_shape[0],
                post: src_shape[1..].iter().product(),
                dst: slot(*out),
            }
        }
        Instr::Gather { src, plan, out } => SplitOp::Gather {
            plan: &prog.tables.plans[*plan as usize],
            src: resolve_src(src, env, slab),
            out: slot(*out),
            full: env.prep.plan_full[*plan as usize],
        },
        _ => unreachable!("not a split instruction: {}", ins.opcode()),
    })
}

/// Share `w` of a split `ways` wide: the same part of the output whichever
/// thread runs it, and every element computed as the serial arm computes
/// it.
///
/// # Safety
/// `op` was resolved for the current call, every instruction it depends on
/// has run, and no other thread writes what this share reads or touches
/// what it writes.
#[cfg(not(target_arch = "wasm32"))]
unsafe fn run_split_share(op: &SplitOp, w: usize, ways: usize) {
    use super::par::{assemble_share, copy_strided_share, share_at};
    match *op {
        SplitOp::Skip => {}
        SplitOp::Assemble {
            dst,
            shape,
            regions,
            parts,
            covered,
        } => unsafe { assemble_share(w, ways, dst, shape, regions, parts, covered) },
        SplitOp::Copy {
            dst,
            ref dstr,
            src,
            ref sstr,
            shape,
        } => unsafe { copy_strided_share(ways, w, dst, dstr, src, sstr, shape) },
        // Worker `w` owns a run of output cells and folds each of them whole,
        // row by row in the serial order.
        SplitOp::Reduce {
            op,
            init,
            reverse,
            src,
            rows,
            n_out,
            dst,
        } => {
            let (lo, hi) = share_at(n_out, w, ways, dst);
            // SAFETY: cells `[lo, hi)` are this share's; every row holds
            // `n_out` cells.
            unsafe {
                for k in lo..hi {
                    *dst.add(k) = init;
                }
            }
            macro_rules! fold_rows {
                ($f:expr) => {
                    for k in 0..rows {
                        // A reverse fold takes its rows from the last.
                        let r = if reverse { rows - 1 - k } else { k };
                        unsafe { reduce_rows(dst.add(lo), hi - lo, src.add(r * n_out + lo), 1, $f) }
                    }
                };
            }
            dispatch_bin_kernel!(&op, fold_rows);
        }
        // Worker `w` sweeps the inner positions (lanes) of its own share,
        // every one whole and in order.
        SplitOp::Scan {
            op,
            init,
            inclusive,
            reverse,
            src,
            len,
            post,
            dst,
        } => {
            let (lo, hi) = share_at(post, w, ways, dst);
            macro_rules! scan {
                ($f:expr) => {
                    // SAFETY: lanes `[lo, hi)` are this share's.
                    unsafe {
                        scan_leading_cols(dst, src, len, post, init, inclusive, reverse, lo, hi, $f)
                    }
                };
            }
            dispatch_bin_kernel!(&op, scan);
        }
        // Share 0 zeroes exactly the ghosts, which no segment copy writes,
        // and every share copies its part of each segment block.
        SplitOp::Gather {
            plan,
            ref src,
            out,
            full,
        } => unsafe {
            let zero = if !full && w == 0 {
                super::kernels::Zero::Exact
            } else {
                super::kernels::Zero::No
            };
            super::kernels::gather_with(plan, src, out, zero, |d, ds, s, ss, sh| {
                copy_strided_share(ways, w, d, ds, s, ss, sh)
            })
        },
    }
}
