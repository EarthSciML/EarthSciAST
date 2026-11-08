//! The instruction loop: decode one `Instr` at a time, resolve its operands
//! through `resolve`, and apply the loops in `kernels` / `fused`.
//!
//! This is the only module that knows the instruction encoding, which is
//! why the boundary sits here: the kernels it drives know pointers and
//! strides and nothing about the program.

use super::super::geom::{RingTable, run_poly_area};
use super::fused::{dispatch_bin_kernel, dispatch_un_kernel, exec_fused};
#[cfg(not(target_arch = "wasm32"))]
use super::kernels::scan_leading_cols;
use super::kernels::{
    copy_strided, count_bisects, count_many, count_one, data_gather, data_gather_sub, ew_select,
    ew1, ew2, exec_gather, fill_strided, index_gather, reduce_axis, reduce_rows, scan_axis,
    seg_reduce, table_gather,
};
use super::resolve::{Rv, SrcView, resolve_rv, resolve_scalar, resolve_src, rm_strides, src_base};
use super::*;
use crate::simulate_array::eval::{latch_gather_fault, latch_ordered_fault};

/// A resolved source viewed as a ring table.
fn ring_table(v: &SrcView) -> RingTable<'_> {
    RingTable {
        ptr: v.ptr,
        shape: &v.shape,
        strides: &v.strides,
    }
}

/// Write a recurrence sweep's current (0-based) cell into its coordinate
/// slots, 1-based, as the interpreter binds the frame symbols.
///
/// # Safety
/// `slab_ptr` must be the slab `slot_off` lays out.
unsafe fn write_coords(sw: &SweepSpec, cell: &[usize], slab_ptr: *mut f64, slot_off: &[usize]) {
    for (&slot, &c) in sw.coords.iter().zip(cell) {
        unsafe { *slab_ptr.add(slot_off[slot as usize]) = (c + 1) as f64 };
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
        slab,
        slot_off,
        obs,
        parked,
        pending,
        scode,
        slanes,
        plan_full,
        asm_covered,
        scratch,
        idx_tables,
        lscratch,
        exports_active,
        simd,
        dy_home,
        dy_home_quiet,
        #[cfg(not(target_arch = "wasm32"))]
        seg_chains,
        #[cfg(not(target_arch = "wasm32"))]
        chain_scratch,
        ..
    } = exec;
    let exports_active = *exports_active;
    let dy_home: &[usize] = if exports_active {
        dy_home
    } else {
        dy_home_quiet
    };
    let simd = *simd;
    let prog = env.prog;
    let slab_ptr = slab.as_mut_ptr();
    let slot_off: &[usize] = slot_off;
    pending.clear();

    // The open recurrence sweep, if any: the `Sweep` instruction's position
    // and the 0-based frame cell its body is evaluating.
    let mut sweep: Option<(usize, SmallVec<[usize; 4]>)> = None;
    if scode.len() != prog.instrs.len() {
        slanes.clear();
        *scode = prog
            .instrs
            .iter()
            .map(|i| ScalarOp::decode(prog, i, slot_off, slanes))
            .collect();
        // A segmented-reduction chain starts through its own path below.
        #[cfg(not(target_arch = "wasm32"))]
        for ch in seg_chains.iter() {
            scode[ch.start] = ScalarOp::None;
        }
    }
    // Runs of scalar elementwise ops execute in the loop at the top of each
    // step (see `ScalarOp`); a per-instruction precision keeps the general
    // path, which arms it.
    let scalar_runs = prog.precision.is_empty();
    let mut pc = range.start;
    // The next segmented-reduction chain that may split (see `chain`).
    #[cfg(not(target_arch = "wasm32"))]
    let mut next_chain = seg_chains.partition_point(|c| c.start < range.start);
    while pc < range.end {
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
            let sw = &prog.sweeps[*spec as usize];
            let body = *spc + 1;
            if pc == body + sw.body_len as usize {
                let v = resolve_scalar(&sw.result, env, slab_ptr, slot_off);
                let prec = prog
                    .precision
                    .get(*spc)
                    .copied()
                    .unwrap_or_else(crate::precision::active);
                let out = unsafe { slab_ptr.add(slot_off[sw.out as usize]) };
                unsafe { *out.add(sw.flat(cell)) = prec.round(v) };
                if sw.advance(cell) {
                    unsafe { write_coords(sw, cell, slab_ptr, slot_off) };
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
        if scalar_runs && sweep.is_none() {
            let start = pc;
            loop {
                // The end of a taken true region skips its false region, as
                // at the top of the step.
                if let Some(&(pos, skip)) = pending.last() {
                    if pos as usize == pc {
                        pending.pop();
                        pc += skip as usize;
                        continue;
                    }
                }
                if pc >= range.end {
                    break;
                }
                let op = &scode[pc];
                if let ScalarOp::Jmp {
                    cond,
                    n_true,
                    n_false,
                } = *op
                {
                    // `Instr::JmpIfZero`'s arm below.
                    if unsafe { scalar_get(&cond, env, slab_ptr) } != 0.0 {
                        pending.push(((pc + 1 + n_true as usize) as u32, n_false));
                    } else {
                        pc += n_true as usize;
                    }
                } else if !unsafe { op.run(env, slab_ptr, slot_off, lscratch, slanes, dy) } {
                    break;
                }
                pc += 1;
            }
            if pc != start {
                continue;
            }
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
                let split = unsafe {
                    super::chain::run_chain(
                        ch,
                        env,
                        slab_ptr,
                        slot_off,
                        chain_scratch,
                        &mut scratch.fscratch,
                        idx_tables,
                        simd,
                        dy_home,
                        dy.as_mut_ptr(),
                    )
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
        // A scalar instruction runs here, in a few lines, instead of through
        // the general dispatch below: a scalar right-hand side (a template's
        // lookup at one query) is mostly such instructions, each a few
        // flops, so their dispatch was most of its cost.
        if unsafe { exec_scalar(&prog.instrs[pc], env, slab_ptr, slot_off) } {
            pc += 1;
            continue;
        }
        match &prog.instrs[pc] {
            Instr::LoadForcing { forcing, out } => {
                let fr = &prog.forcings[*forcing as usize];
                let off = slot_off[*out as usize];
                let dst =
                    unsafe { std::slice::from_raw_parts_mut(slab_ptr.add(off), forcing_len(fr)) };
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
                let (rule, key) = &prog.fault_order[*fault as usize];
                latch_ordered_fault(*rule, key, || prog.faults[*fault as usize].clone());
            }
            Instr::FaultScan { spec } => {
                let scan = &prog.fault_scans[*spec as usize];
                let first = scan.first(&prog.faults, |op, cell| match (op, cell) {
                    (Operand::Slot(s), Some((shape, c))) => unsafe {
                        *slab_ptr.add(slot_off[*s as usize] + slab_flat(shape, c, prog.col_major))
                    },
                    _ => resolve_scalar(op, env, slab_ptr, slot_off),
                });
                if let Some((key, msg)) = first {
                    latch_ordered_fault(scan.rule, &key, || msg);
                }
            }
            Instr::Sweep { spec } => {
                let sw = &prog.sweeps[*spec as usize];
                debug_assert!(sweep.is_none(), "recurrence sweeps do not nest");
                if sw.n_cells() == 0 {
                    pc += 1 + sw.body_len as usize;
                    continue;
                }
                let cell: SmallVec<[usize; 4]> = SmallVec::from_elem(0, sw.shape.len());
                unsafe { write_coords(sw, &cell, slab_ptr, slot_off) };
                sweep = Some((pc, cell));
            }
            Instr::ScalarRead { src, spec, out } => {
                let sp = &prog.scalar_reads[*spec as usize];
                let sv = resolve_src(src, env, slab_ptr, slot_off);
                let raw: SmallVec<[i64; 4]> = sp
                    .subs
                    .iter()
                    .map(|o| subscript_of(resolve_scalar(o, env, slab_ptr, slot_off)))
                    .collect();
                let cur = sweep.as_ref().map_or(&[][..], |(_, c)| &c[..]);
                let v = match sp.resolve(&raw, &sv.shape, &prog.sweeps, cur) {
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
                unsafe { *slab_ptr.add(slot_off[*out as usize]) = v };
            }
            Instr::JmpIfZero {
                cond,
                n_true,
                n_false,
            } => {
                let c = resolve_scalar(cond, env, slab_ptr, slot_off);
                if c != 0.0 {
                    // Execute the true region, then skip the false one.
                    pending.push(((pc + 1 + *n_true as usize) as u32, *n_false));
                } else {
                    pc += *n_true as usize; // skip straight to the false region
                }
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
                let desc = &prog.slots[*slot as usize];
                let off = slot_off[*slot as usize];
                if desc.scalar {
                    a[IxDyn(&[])] = unsafe { *slab_ptr.add(off) };
                } else {
                    // `a.len()`, not `desc.elems()`: an empty box keeps a
                    // one-element storage but publishes an empty array.
                    debug_assert_eq!(a.len(), desc.shape.iter().product::<usize>());
                    let n = a.len();
                    let src = unsafe { std::slice::from_raw_parts(slab_ptr.add(off), n) };
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
            Instr::Lanes { spec } => unsafe {
                super::lanes::exec_lanes(
                    *spec as usize,
                    &prog.lanes[*spec as usize],
                    env,
                    slab_ptr,
                    slot_off,
                    lscratch,
                    dy,
                    simd,
                    call_split,
                )
            },
            _ => {
                let cx = Cx {
                    env,
                    slab_ptr,
                    slot_off,
                    plan_full,
                    asm_covered,
                    idx_tables,
                    simd,
                    dy_home,
                    dy: dy.as_mut_ptr(),
                    dy_len: dy.len(),
                };
                unsafe { exec_straight(&cx, &prog.instrs[pc], scratch, call_split) };
            }
        }
        pc += 1;
    }
}

/// A scalar operand, decoded: a slot at its slab offset (decoded against the
/// call's slot layout, see [`TapeExec`]'s `scode`), a literal, a parameter,
/// `t`, or a 0-d state at its flat offset.
#[derive(Clone, Copy)]
pub(super) enum ScalarSrc {
    Slot(usize),
    Lit(f64),
    Param(u32),
    Time,
    State(usize),
}

/// Where a decoded load, gather or count reads its source: the slab at a
/// slot's offset, or a state variable (through [`src_base`], which picks the
/// row-major mirror when there is one).
#[derive(Clone, Copy)]
pub(super) enum ScalarBase {
    Slab(usize),
    State(u32),
}

/// A decoded binary kernel: the arithmetic, comparisons and NaN-propagating
/// `min`/`max` written out as `dispatch_bin_kernel` writes them, so they
/// inline; every other kernel (and every kernel under Float32) through
/// [`binary_kernel_of`]'s function.
#[derive(Clone, Copy)]
pub(super) enum ScalarBin {
    Add,
    Sub,
    Mul,
    Div,
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
    fn of(op: BinCode) -> ScalarBin {
        if crate::precision::is_f32() {
            return ScalarBin::Fn(binary_kernel_of(op));
        }
        match op {
            BinCode::Add => ScalarBin::Add,
            BinCode::Sub => ScalarBin::Sub,
            BinCode::Mul => ScalarBin::Mul,
            BinCode::Div => ScalarBin::Div,
            BinCode::Lt => ScalarBin::Lt,
            BinCode::Le => ScalarBin::Le,
            BinCode::Gt => ScalarBin::Gt,
            BinCode::Ge => ScalarBin::Ge,
            BinCode::Eq => ScalarBin::Eq,
            BinCode::Ne => ScalarBin::Ne,
            BinCode::Min => ScalarBin::Min,
            BinCode::Max => ScalarBin::Max,
            _ => ScalarBin::Fn(binary_kernel_of(op)),
        }
    }

    /// [`binary_kernel_of`]'s binary64 arm, for the written-out kernels.
    #[inline(always)]
    fn apply(self, x: f64, y: f64) -> f64 {
        match self {
            ScalarBin::Add => x + y,
            ScalarBin::Sub => x - y,
            ScalarBin::Mul => x * y,
            ScalarBin::Div => x / y,
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

/// One instruction's scalar form: what its [`exec_straight`] (or
/// [`run_range`]) arm does for a scalar `out`, with the kernel, the operands
/// and the slab offsets decoded once instead of matched on every call. A
/// scalar right-hand side (a template's lookup at one query) is mostly such
/// instructions, a few flops each, so their dispatch was most of its cost;
/// consecutive ones run in one loop.
///
/// The loads, gathers and counts a scalar lookup is built from, the `ifelse`
/// short circuit between them, and a one-lane lane program run in the same
/// loop: a one-element load at its offset, a one-element gather (one that
/// faults leaves the loop, so the general path latches it), a count at one
/// query, the jump (see [`run_range`]), and the lane block [`exec_lanes`]
/// would run.
///
/// [`exec_lanes`]: super::lanes::exec_lanes
#[derive(Clone, Copy)]
pub(super) enum ScalarOp {
    None,
    Bin(ScalarBin, ScalarSrc, ScalarSrc, usize),
    Un(fn(f64) -> f64, ScalarSrc, usize),
    Neg(ScalarSrc, usize),
    Copy(ScalarSrc, usize),
    Select(ScalarSrc, ScalarSrc, ScalarSrc, usize),
    /// [`Instr::LoadElem`]: the source's element at row-major offset `off`.
    Load(ScalarBase, usize, usize),
    /// [`Instr::DataGather`] of a rank-1 source of extent `n` at one
    /// subscript; `spec` resolves a subscript outside `1..=n`.
    Gather1 {
        src: ScalarBase,
        sub: ScalarSrc,
        n: usize,
        spec: u32,
        out: usize,
    },
    /// [`Instr::DataGather`] at one element, any rank: its spec.
    Gather {
        src: ScalarBase,
        spec: u32,
        out: usize,
    },
    /// [`Instr::Count`] at one query; its window lies in the axis's box.
    Count {
        rel: CountRel,
        axis: ScalarBase,
        lo: u32,
        n: u32,
        sorted: bool,
        x: ScalarSrc,
        out: usize,
    },
    /// [`Instr::JmpIfZero`].
    Jmp {
        cond: ScalarSrc,
        n_true: u32,
        n_false: u32,
    },
    /// [`Instr::Lanes`] of one lane and no lane inputs, decoded:
    /// `TapeExec`'s `slanes[i]`.
    Lane(u32),
    /// [`Instr::Lanes`] of one lane and no lane inputs, as [`exec_lanes`]
    /// runs it: its spec.
    ///
    /// [`exec_lanes`]: super::lanes::exec_lanes
    Lanes(u32),
}

/// A lane program's register or scalar operand, decoded.
#[derive(Clone, Copy)]
pub(super) enum LaneRef {
    Reg(u8),
    Scal(u8),
}

/// One micro-op of a decoded one-lane program.
#[derive(Clone, Copy)]
pub(super) enum LaneOp {
    Bin(ScalarBin, LaneRef, LaneRef, u8),
    Un(fn(f64) -> f64, LaneRef, u8),
    Neg(LaneRef, u8),
    Select(LaneRef, LaneRef, LaneRef, u8),
    Mov(LaneRef, u8),
}

/// Where a decoded one-lane program writes: `dy` at a flat position, or the
/// slab at a slot's offset.
#[derive(Clone, Copy)]
pub(super) enum LaneOut {
    Dy(usize),
    Slab(usize),
}

/// The most registers or scalars a decoded one-lane program holds.
const LANE_MAX: usize = 16;

/// A one-lane lane program with no lane inputs decoded as [`ScalarOp`]s are:
/// what `exec_block` computes from the same micro-ops, in the same order,
/// with the scalars read straight into a register file of its own (every
/// register is written before it is read, so no value carries over from a
/// previous call).
pub(super) struct ScalarLane {
    scalars: SmallVec<[ScalarSrc; 8]>,
    micro: SmallVec<[LaneOp; 8]>,
    writes: SmallVec<[(LaneRef, LaneOut); 4]>,
}

impl ScalarLane {
    /// Decode `ls` against `slot_off`, or `None` for a program outside the
    /// decoded form (Float32 kernels, more than [`LANE_MAX`] registers or
    /// scalars, an array scalar operand, a superop, a register read before
    /// it is written).
    fn decode(
        ls: &LaneSpec,
        slot_off: &[usize],
        src: impl Fn(&Operand) -> Option<ScalarSrc>,
    ) -> Option<ScalarLane> {
        if crate::precision::is_f32()
            || ls.lanes != 1
            || !ls.inputs.is_empty()
            || ls.n_regs as usize > LANE_MAX
            || ls.scalars.len() > LANE_MAX
        {
            return None;
        }
        let scalars = ls.scalars.iter().map(&src).collect::<Option<_>>()?;
        let mut written = [false; LANE_MAX];
        let rd = |m: &MRef, written: &[bool; LANE_MAX]| -> Option<LaneRef> {
            match *m {
                MRef::Reg(r) if (r as usize) < LANE_MAX && written[r as usize] => {
                    Some(LaneRef::Reg(r as u8))
                }
                MRef::Scal(i) if (i as usize) < ls.scalars.len() => Some(LaneRef::Scal(i as u8)),
                _ => None,
            }
        };
        let mut micro = SmallVec::new();
        for op in &ls.micro {
            let (dop, out) = match op {
                MicroOp::Bin { op, a, b, out } => (
                    LaneOp::Bin(
                        ScalarBin::of(*op),
                        rd(a, &written)?,
                        rd(b, &written)?,
                        *out as u8,
                    ),
                    *out,
                ),
                MicroOp::Un { op, a, out } => (
                    LaneOp::Un(unary_kernel_of(*op), rd(a, &written)?, *out as u8),
                    *out,
                ),
                MicroOp::Neg { a, out } => (LaneOp::Neg(rd(a, &written)?, *out as u8), *out),
                MicroOp::Select { cond, a, b, out } => (
                    LaneOp::Select(
                        rd(cond, &written)?,
                        rd(a, &written)?,
                        rd(b, &written)?,
                        *out as u8,
                    ),
                    *out,
                ),
                MicroOp::Mov { a, out } => (LaneOp::Mov(rd(a, &written)?, *out as u8), *out),
                _ => return None,
            };
            if out as usize >= ls.n_regs as usize {
                return None;
            }
            written[out as usize] = true;
            micro.push(dop);
        }
        let mut writes = SmallVec::new();
        for w in &ls.writes {
            let dst = match &w.dst {
                LaneDst::Dy(pos) => LaneOut::Dy(pos.at(0) as usize),
                LaneDst::Slot(k) => LaneOut::Slab(slot_off[*k as usize]),
            };
            writes.push((rd(&w.src, &written)?, dst));
        }
        Some(ScalarLane {
            scalars,
            micro,
            writes,
        })
    }

    /// Run the program.
    ///
    /// # Safety
    /// As [`ScalarOp::run`].
    #[inline]
    unsafe fn run(&self, env: &Env, slab_ptr: *mut f64, dy: &mut [f64]) {
        let mut sv = [0.0f64; LANE_MAX];
        for (v, s) in sv.iter_mut().zip(&self.scalars) {
            *v = unsafe { scalar_get(s, env, slab_ptr) };
        }
        let mut regs = [0.0f64; LANE_MAX];
        let get = |m: LaneRef, regs: &[f64; LANE_MAX]| match m {
            LaneRef::Reg(r) => regs[r as usize],
            LaneRef::Scal(i) => sv[i as usize],
        };
        for op in &self.micro {
            match *op {
                LaneOp::Bin(k, a, b, out) => {
                    let (x, y) = (get(a, &regs), get(b, &regs));
                    regs[out as usize] = k.apply(x, y);
                }
                LaneOp::Un(f, a, out) => regs[out as usize] = f(get(a, &regs)),
                LaneOp::Neg(a, out) => regs[out as usize] = -get(a, &regs),
                LaneOp::Select(c, a, b, out) => {
                    let (c, x, y) = (get(c, &regs), get(a, &regs), get(b, &regs));
                    regs[out as usize] = if c != 0.0 { x } else { y };
                }
                LaneOp::Mov(a, out) => regs[out as usize] = get(a, &regs),
            }
        }
        for &(src, dst) in &self.writes {
            let v = get(src, &regs);
            match dst {
                LaneOut::Dy(p) => dy[p] = v,
                LaneOut::Slab(o) => unsafe { *slab_ptr.add(o) = v },
            }
        }
    }
}

impl ScalarOp {
    /// Decode `ins` against the slot layout `slot_off`, adding a decoded
    /// lane program to `slanes`.
    pub(super) fn decode(
        prog: &TapeProgram,
        ins: &Instr,
        slot_off: &[usize],
        slanes: &mut Vec<ScalarLane>,
    ) -> ScalarOp {
        let src = |o: &Operand| -> Option<ScalarSrc> {
            Some(match o {
                Operand::Slot(s) if prog.slots[*s as usize].scalar => {
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
        };
        let scalar = |out: &SlotId| prog.slots[*out as usize].scalar;
        let off = |out: &SlotId| slot_off[*out as usize];
        let base = |s: &SrcRef| match s {
            SrcRef::Slot(k) => ScalarBase::Slab(slot_off[*k as usize]),
            SrcRef::State(ix) => ScalarBase::State(*ix),
        };
        let src_shape = |s: &SrcRef| -> &[usize] {
            match s {
                SrcRef::Slot(k) => &prog.slots[*k as usize].shape[..],
                SrcRef::State(ix) => &prog.state_vars[*ix as usize].shape[..],
            }
        };
        let op = match ins {
            Instr::Bin { op, a, b, out } if scalar(out) => (|| {
                Some(ScalarOp::Bin(
                    ScalarBin::of(*op),
                    src(a)?,
                    src(b)?,
                    off(out),
                ))
            })(),
            Instr::Un { op, a, out } if scalar(out) => {
                (|| Some(ScalarOp::Un(unary_kernel_of(*op), src(a)?, off(out))))()
            }
            Instr::Neg { a, out } if scalar(out) => (|| Some(ScalarOp::Neg(src(a)?, off(out))))(),
            Instr::Copy { a, out } if scalar(out) => (|| Some(ScalarOp::Copy(src(a)?, off(out))))(),
            Instr::Select { cond, a, b, out } if scalar(out) => {
                (|| Some(ScalarOp::Select(src(cond)?, src(a)?, src(b)?, off(out))))()
            }
            Instr::LoadElem { src: s, idx, out } if scalar(out) => {
                let shape = src_shape(s);
                (idx.len() == shape.len()).then(|| {
                    let mut at = 0usize;
                    let mut stride = 1usize;
                    for d in (0..idx.len()).rev() {
                        at += idx[d] * stride;
                        stride *= shape[d];
                    }
                    ScalarOp::Load(base(s), at, off(out))
                })
            }
            Instr::DataGather {
                src: s, spec, out, ..
            } if scalar(out) => {
                let sp = &prog.data_gathers[*spec as usize];
                if !sp.shape.is_empty() || sp.subs.len() > 4 {
                    None
                } else if sp.subs.len() == 1 && sp.src_shape.len() == 1 {
                    src(&sp.subs[0]).map(|sub| ScalarOp::Gather1 {
                        src: base(s),
                        sub,
                        n: sp.src_shape[0],
                        spec: *spec,
                        out: off(out),
                    })
                } else {
                    Some(ScalarOp::Gather {
                        src: base(s),
                        spec: *spec,
                        out: off(out),
                    })
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
            } if scalar(out) => {
                // A window outside the axis's box is left to the general
                // path, which refuses it.
                let ashape = src_shape(axis);
                (ashape.len() == 1 && *lo as usize + *n as usize <= ashape[0])
                    .then(|| {
                        Some(ScalarOp::Count {
                            rel: *rel,
                            axis: base(axis),
                            lo: *lo,
                            n: *n,
                            sorted: *sorted,
                            x: src(x)?,
                            out: off(out),
                        })
                    })
                    .flatten()
            }
            Instr::JmpIfZero {
                cond,
                n_true,
                n_false,
            } => src(cond).map(|cond| ScalarOp::Jmp {
                cond,
                n_true: *n_true,
                n_false: *n_false,
            }),
            Instr::Lanes { spec } => {
                let ls = &prog.lanes[*spec as usize];
                if let Some(lane) = ScalarLane::decode(ls, slot_off, src) {
                    slanes.push(lane);
                    Some(ScalarOp::Lane(slanes.len() as u32 - 1))
                } else {
                    (ls.lanes == 1 && ls.inputs.is_empty()).then_some(ScalarOp::Lanes(*spec))
                }
            }
            _ => None,
        };
        op.unwrap_or(ScalarOp::None)
    }

    /// Run the op, or return `false` for [`ScalarOp::None`], for a gather
    /// that faults (having written nothing) and for [`ScalarOp::Jmp`], which
    /// the loop in [`run_range`] takes.
    ///
    /// # Safety
    /// As [`exec_straight`], with `self` decoded against `slab_ptr`'s slot
    /// layout.
    #[inline(always)]
    pub(super) unsafe fn run(
        &self,
        env: &Env,
        slab_ptr: *mut f64,
        slot_off: &[usize],
        lscratch: &mut super::lanes::LaneScratch,
        slanes: &[ScalarLane],
        dy: &mut [f64],
    ) -> bool {
        let get = |s: &ScalarSrc| unsafe { scalar_get(s, env, slab_ptr) };
        let put = |out: usize, v: f64| unsafe { *slab_ptr.add(out) = v };
        let base_ptr = |b: &ScalarBase| -> *const f64 {
            match *b {
                ScalarBase::Slab(o) => unsafe { slab_ptr.add(o) },
                ScalarBase::State(ix) => super::resolve::state_ptr(env, ix),
            }
        };
        match self {
            ScalarOp::None => return false,
            ScalarOp::Bin(k, a, b, out) => put(*out, k.apply(get(a), get(b))),
            ScalarOp::Un(f, a, out) => put(*out, f(get(a))),
            ScalarOp::Neg(a, out) => put(*out, -get(a)),
            ScalarOp::Copy(a, out) => put(*out, get(a)),
            ScalarOp::Select(c, a, b, out) => {
                let c = get(c);
                let x = get(a);
                let y = get(b);
                put(*out, if c != 0.0 { x } else { y });
            }
            ScalarOp::Load(b, at, out) => put(*out, unsafe { *base_ptr(b).add(*at) }),
            ScalarOp::Gather1 {
                src,
                sub,
                n,
                spec,
                out,
            } => {
                let v = get(sub);
                let r = subscript_of(v);
                let base = base_ptr(src);
                if r >= 1 && r <= *n as i64 {
                    put(*out, unsafe { *base.add((r - 1) as usize) });
                } else {
                    match env.prog.data_gathers[*spec as usize].at(|_| v) {
                        DataAt::Elem(p) => put(*out, unsafe { *base.add(p) }),
                        DataAt::Ghost => put(*out, 0.0),
                        DataAt::Fault { .. } => return false,
                    }
                }
            }
            ScalarOp::Gather { src, spec, out } => {
                let sp = &env.prog.data_gathers[*spec as usize];
                let mut v = [0.0f64; 4];
                for (d, o) in sp.subs.iter().enumerate() {
                    v[d] = resolve_scalar(o, env, slab_ptr, slot_off);
                }
                let base = base_ptr(src);
                match sp.at(|d| v[d]) {
                    DataAt::Elem(p) => put(*out, unsafe { *base.add(p) }),
                    DataAt::Ghost => put(*out, 0.0),
                    DataAt::Fault { .. } => return false,
                }
            }
            ScalarOp::Count {
                rel,
                axis,
                lo,
                n,
                sorted,
                x,
                out,
            } => {
                // The decode checked the window against the axis's box.
                let win = unsafe {
                    std::slice::from_raw_parts(base_ptr(axis).add(*lo as usize), *n as usize)
                };
                let bisect = count_bisects(win, *sorted);
                put(*out, count_one(*rel, win, bisect, get(x)));
            }
            ScalarOp::Jmp { .. } => return false,
            ScalarOp::Lane(i) => unsafe { slanes[*i as usize].run(env, slab_ptr, dy) },
            ScalarOp::Lanes(spec) => unsafe {
                super::lanes::exec_one_lane(
                    &env.prog.lanes[*spec as usize],
                    env,
                    slab_ptr,
                    slot_off,
                    lscratch,
                    dy,
                )
            },
        }
        true
    }
}

/// The value of a decoded scalar operand.
///
/// # Safety
/// A [`ScalarSrc::Slot`] offset must lie in the slab.
#[inline(always)]
unsafe fn scalar_get(s: &ScalarSrc, env: &Env, slab_ptr: *const f64) -> f64 {
    match *s {
        ScalarSrc::Slot(o) => unsafe { *slab_ptr.add(o) },
        ScalarSrc::Lit(v) => v,
        ScalarSrc::Param(p) => env.params[p as usize],
        ScalarSrc::Time => env.t,
        ScalarSrc::State(off) => env.state[off],
    }
}

/// Run `ins` if it is a scalar instruction with a scalar form here, and say
/// whether it ran. Each arm is the scalar branch of its [`exec_straight`]
/// arm, operation for operation: an elementwise op on scalar slots, a
/// one-element load, a one-element gather that does not fault (a faulting
/// one is left to the general path, which latches it), a count at one query.
///
/// # Safety
/// As [`exec_straight`].
#[inline]
unsafe fn exec_scalar(ins: &Instr, env: &Env, slab_ptr: *mut f64, slot_off: &[usize]) -> bool {
    let prog = env.prog;
    let scalar_out = |out: &SlotId| prog.slots[*out as usize].scalar;
    let put = |out: &SlotId, v: f64| unsafe { *slab_ptr.add(slot_off[*out as usize]) = v };
    let get = |o: &Operand| resolve_scalar(o, env, slab_ptr, slot_off);
    match ins {
        Instr::Bin { op, a, b, out } if scalar_out(out) => {
            put(out, binary_kernel_of(*op)(get(a), get(b)));
        }
        Instr::Un { op, a, out } if scalar_out(out) => put(out, unary_kernel_of(*op)(get(a))),
        Instr::Neg { a, out } if scalar_out(out) => put(out, -get(a)),
        Instr::Copy { a, out } if scalar_out(out) => put(out, get(a)),
        Instr::Select { cond, a, b, out } if scalar_out(out) => {
            let c = get(cond);
            let x = get(a);
            let y = get(b);
            put(out, if c != 0.0 { x } else { y });
        }
        Instr::LoadElem { src, idx, out } => {
            let (base, shape) = src_base(src, env, slab_ptr, slot_off);
            let mut soff = 0usize;
            let mut stride = 1usize;
            for d in (0..idx.len()).rev() {
                soff += idx[d] * stride;
                stride *= shape[d];
            }
            put(out, unsafe { *base.add(soff) });
        }
        Instr::DataGather { src, spec, out, .. } => {
            let spec = &prog.data_gathers[*spec as usize];
            if !spec.shape.is_empty() || spec.subs.len() > 4 {
                return false;
            }
            let mut v = [0.0f64; 4];
            for (d, o) in spec.subs.iter().enumerate() {
                v[d] = get(o);
            }
            let (base, _) = src_base(src, env, slab_ptr, slot_off);
            match spec.at(|d| v[d]) {
                DataAt::Elem(p) => put(out, unsafe { *base.add(p) }),
                DataAt::Ghost => put(out, 0.0),
                DataAt::Fault { .. } => return false,
            }
        }
        _ => return false,
    }
    true
}

/// Everything a straight-line instruction reads besides its own scratch:
/// the call's environment, the slab and the per-call tables.
#[derive(Clone, Copy)]
pub(super) struct Cx<'a> {
    pub(super) env: &'a Env<'a>,
    pub(super) slab_ptr: *mut f64,
    pub(super) slot_off: &'a [usize],
    pub(super) plan_full: &'a [bool],
    pub(super) asm_covered: &'a [bool],
    pub(super) idx_tables: &'a [Vec<Option<super::fused::IndexTable>>],
    pub(super) simd: SimdLevel,
    pub(super) dy_home: &'a [usize],
    pub(super) dy: *mut f64,
    pub(super) dy_len: usize,
}

/// Whether `ins` is straight-line: it reads and writes only slab slots, the
/// state, the parameters, `t` and `dy`, moves no control and publishes
/// nothing, so [`exec_straight`] runs it on any thread.
#[cfg(not(target_arch = "wasm32"))]
pub(super) fn is_straight(ins: &Instr) -> bool {
    !matches!(
        ins,
        Instr::LoadForcing { .. }
            | Instr::Fault { .. }
            | Instr::FaultScan { .. }
            | Instr::Sweep { .. }
            | Instr::ScalarRead { .. }
            | Instr::DataGather { faults: true, .. }
            | Instr::JmpIfZero { .. }
            | Instr::Export { .. }
            | Instr::Lanes { .. }
    )
}

/// Execute one straight-line instruction (see [`is_straight`]) with this
/// thread's `scratch`, splitting it under width `call_split`.
///
/// # Safety
/// `cx` must describe the current call, and every instruction this one
/// depends on must have run.
pub(super) unsafe fn exec_straight(cx: &Cx, ins: &Instr, scratch: &mut Scratch, call_split: usize) {
    let Cx {
        env,
        slab_ptr,
        slot_off,
        plan_full,
        asm_covered,
        idx_tables,
        simd,
        dy_home,
        dy,
        dy_len,
    } = *cx;
    let prog = env.prog;
    let Scratch {
        fregs,
        fscratch,
        #[cfg(not(target_arch = "wasm32"))]
        asm_parts,
    } = scratch;
    #[cfg(target_arch = "wasm32")]
    let _ = call_split;
    match ins {
        Instr::Bin { op, a, b, out } => {
            let desc = &prog.slots[*out as usize];
            let off = slot_off[*out as usize];
            if desc.scalar {
                let f = binary_kernel_of(*op);
                let x = resolve_scalar(a, env, slab_ptr, slot_off);
                let y = resolve_scalar(b, env, slab_ptr, slot_off);
                unsafe { *slab_ptr.add(off) = f(x, y) };
            } else {
                let av = resolve_rv(a, &desc.shape, env, slab_ptr, slot_off);
                let bv = resolve_rv(b, &desc.shape, env, slab_ptr, slot_off);
                let dst = unsafe { slab_ptr.add(off) };
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
            let desc = &prog.slots[*out as usize];
            let off = slot_off[*out as usize];
            if desc.scalar {
                let f = unary_kernel_of(*op);
                let x = resolve_scalar(a, env, slab_ptr, slot_off);
                unsafe { *slab_ptr.add(off) = f(x) };
            } else {
                let av = resolve_rv(a, &desc.shape, env, slab_ptr, slot_off);
                let dst = unsafe { slab_ptr.add(off) };
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
            let desc = &prog.slots[*out as usize];
            let off = slot_off[*out as usize];
            if desc.scalar {
                let x = resolve_scalar(a, env, slab_ptr, slot_off);
                unsafe { *slab_ptr.add(off) = -x };
            } else {
                let av = resolve_rv(a, &desc.shape, env, slab_ptr, slot_off);
                unsafe { ew1(slab_ptr.add(off), &desc.shape, &av, |x| -x) };
            }
        }
        Instr::Select { cond, a, b, out } => {
            let desc = &prog.slots[*out as usize];
            let off = slot_off[*out as usize];
            if desc.scalar {
                let c = resolve_scalar(cond, env, slab_ptr, slot_off);
                let x = resolve_scalar(a, env, slab_ptr, slot_off);
                let y = resolve_scalar(b, env, slab_ptr, slot_off);
                unsafe { *slab_ptr.add(off) = if c != 0.0 { x } else { y } };
            } else {
                let cv = resolve_rv(cond, &desc.shape, env, slab_ptr, slot_off);
                let av = resolve_rv(a, &desc.shape, env, slab_ptr, slot_off);
                let bv = resolve_rv(b, &desc.shape, env, slab_ptr, slot_off);
                unsafe { ew_select(slab_ptr.add(off), &desc.shape, &cv, &av, &bv) };
            }
        }
        Instr::Gather { src, plan, out } => {
            let full = plan_full[*plan as usize];
            let plan = &prog.plans[*plan as usize];
            let sv = resolve_src(src, env, slab_ptr, slot_off);
            let off = slot_off[*out as usize];
            unsafe { exec_gather(plan, &sv, slab_ptr.add(off), full, call_split) };
        }
        Instr::LoadElem { src, idx, out } => {
            let sv = resolve_src(src, env, slab_ptr, slot_off);
            debug_assert_eq!(idx.len(), sv.shape.len());
            let mut soff = 0i64;
            for (d, &i0) in idx.iter().enumerate() {
                debug_assert!(i0 < sv.shape[d], "LoadElem index out of bounds");
                soff += sv.strides[d] * i0 as i64;
            }
            let off = slot_off[*out as usize];
            unsafe { *slab_ptr.add(off) = *sv.ptr.offset(soff as isize) };
        }
        Instr::Ramp { axis, lo, out } => {
            let desc = &prog.slots[*out as usize];
            let off = slot_off[*out as usize];
            let a = *axis as usize;
            let pre: usize = desc.shape[..a].iter().product();
            let ax = desc.shape[a];
            let post: usize = desc.shape[a + 1..].iter().product();
            let mut p = unsafe { slab_ptr.add(off) };
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
            let desc = &prog.slots[*out as usize];
            let off = slot_off[*out as usize];
            let s = resolve_scalar(v, env, slab_ptr, slot_off);
            if desc.scalar {
                unsafe { *slab_ptr.add(off) = s };
            } else {
                let n = desc.elems();
                unsafe {
                    let p = slab_ptr.add(off);
                    for k in 0..n {
                        *p.add(k) = s;
                    }
                }
            }
        }
        Instr::Copy { a, out } => {
            let desc = &prog.slots[*out as usize];
            let off = slot_off[*out as usize];
            if desc.scalar {
                let x = resolve_scalar(a, env, slab_ptr, slot_off);
                unsafe { *slab_ptr.add(off) = x };
            } else {
                let av = resolve_rv(a, &desc.shape, env, slab_ptr, slot_off);
                match av {
                    Rv::S(_) => panic!("array Copy from a scalar operand"),
                    Rv::V { ptr, strides } => unsafe {
                        copy_strided_maybe_split(
                            call_split,
                            slab_ptr.add(off),
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
            let spec = &prog.regions[*region as usize];
            let desc = &prog.slots[*out as usize];
            let off = slot_off[*out as usize];
            let base_off = slot_off[*base as usize];
            let n = desc.elems();
            unsafe {
                // `out = base` (skip when the coloring aliased them, which
                // it can only do at identical offsets).
                if base_off != off {
                    std::ptr::copy_nonoverlapping(
                        slab_ptr.add(base_off) as *const f64,
                        slab_ptr.add(off),
                        n,
                    );
                }
            }
            // Overwrite the region sub-block.
            let out_rm = rm_strides(&desc.shape);
            let mut dbase = 0i64;
            for d in 0..desc.shape.len() {
                dbase += out_rm[d] * spec.dest_lo[d] as i64;
            }
            let sub_dst = unsafe { slab_ptr.add(off).offset(dbase as isize) };
            let sv = resolve_rv(src, &spec.shape, env, slab_ptr, slot_off);
            match sv {
                Rv::S(v) => unsafe { fill_strided(sub_dst, &out_rm, &spec.shape, v) },
                Rv::V { ptr, strides } => unsafe {
                    copy_strided(sub_dst, &out_rm, ptr, &strides, &spec.shape);
                },
            }
        }
        Instr::Assemble { table, out } => {
            let desc = &prog.slots[*out as usize];
            let off = slot_off[*out as usize];
            let dst = unsafe { slab_ptr.add(off) };
            let parts = &prog.assemblies[*table as usize].parts;
            let covered = asm_covered[*table as usize];
            let out_rm = rm_strides(&desc.shape);
            // A large assembly splits across the call's workers, each
            // assembling its own share of the box (see `par`).
            #[cfg(not(target_arch = "wasm32"))]
            let split = super::par::ways_for(desc.elems(), call_split);
            #[cfg(target_arch = "wasm32")]
            let split = 1;
            if split > 1 && !desc.shape.is_empty() {
                #[cfg(not(target_arch = "wasm32"))]
                {
                    asm_parts.clear();
                    for (src, region) in parts {
                        let spec = &prog.regions[*region as usize];
                        let mut dbase = 0i64;
                        for d in 0..desc.shape.len() {
                            dbase += out_rm[d] * spec.dest_lo[d] as i64;
                        }
                        let rv = resolve_rv(src, &spec.shape, env, slab_ptr, slot_off);
                        asm_parts.push(super::par::AsmPart::new(*region, dbase, rv));
                    }
                    unsafe {
                        super::par::assemble(
                            split,
                            dst,
                            &desc.shape,
                            &prog.regions,
                            asm_parts,
                            covered,
                        )
                    };
                }
            } else {
                if !covered {
                    unsafe { std::slice::from_raw_parts_mut(dst, desc.elems()).fill(0.0) };
                }
                for (src, region) in parts {
                    let spec = &prog.regions[*region as usize];
                    let mut dbase = 0i64;
                    for d in 0..desc.shape.len() {
                        dbase += out_rm[d] * spec.dest_lo[d] as i64;
                    }
                    let sub_dst = unsafe { dst.offset(dbase as isize) };
                    match resolve_rv(src, &spec.shape, env, slab_ptr, slot_off) {
                        Rv::S(v) => unsafe { fill_strided(sub_dst, &out_rm, &spec.shape, v) },
                        Rv::V { ptr, strides } => unsafe {
                            copy_strided(sub_dst, &out_rm, ptr, &strides, &spec.shape);
                        },
                    }
                }
            }
        }
        Instr::Interp { table, x, y, out } => {
            let tbl = &prog.interp_tables[*table as usize];
            let desc = &prog.slots[*out as usize];
            let off = slot_off[*out as usize];
            if desc.scalar {
                let xv = resolve_scalar(x, env, slab_ptr, slot_off);
                let yv = y.map_or(f64::NAN, |y| resolve_scalar(&y, env, slab_ptr, slot_off));
                unsafe { *slab_ptr.add(off) = tbl.at(xv, yv) };
            } else {
                let xv = resolve_rv(x, &desc.shape, env, slab_ptr, slot_off);
                let dst = unsafe { slab_ptr.add(off) };
                let sh = &desc.shape;
                match y {
                    // `y` is read only by `interp.bilinear`; the other two
                    // entries never look at it.
                    None => unsafe { ew1(dst, sh, &xv, |a| tbl.at(a, f64::NAN)) },
                    Some(y) => {
                        let yv = resolve_rv(y, &desc.shape, env, slab_ptr, slot_off);
                        unsafe { ew2(dst, sh, &xv, &yv, |a, b| tbl.at(a, b)) }
                    }
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
            let (aptr, ashape) = src_base(axis, env, slab_ptr, slot_off);
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
            let desc = &prog.slots[*out as usize];
            let off = slot_off[*out as usize];
            if desc.scalar {
                let xv = resolve_scalar(x, env, slab_ptr, slot_off);
                let bisect = count_bisects(win, *sorted);
                unsafe { *slab_ptr.add(off) = count_one(*rel, win, bisect, xv) };
            } else {
                let xv = resolve_rv(x, &desc.shape, env, slab_ptr, slot_off);
                let dst = unsafe { slab_ptr.add(off) };
                unsafe { count_many(dst, &desc.shape, &xv, *rel, win, *sorted) };
            }
        }
        Instr::Calendar { func, a, out } => {
            let desc = &prog.slots[*out as usize];
            let off = slot_off[*out as usize];
            if desc.scalar {
                let av = resolve_scalar(a, env, slab_ptr, slot_off);
                unsafe { *slab_ptr.add(off) = calendar_at(*func, av) };
            } else {
                let av = resolve_rv(a, &desc.shape, env, slab_ptr, slot_off);
                let dst = unsafe { slab_ptr.add(off) };
                unsafe { ew1(dst, &desc.shape, &av, |x| calendar_at(*func, x)) };
            }
        }
        Instr::ConstArray { data, out } => {
            let d = &prog.const_data[*data as usize];
            let off = slot_off[*out as usize];
            debug_assert_eq!(d.values.len(), prog.slots[*out as usize].elems());
            unsafe {
                std::ptr::copy_nonoverlapping(d.values.as_ptr(), slab_ptr.add(off), d.values.len());
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
            let sv = resolve_src(src, env, slab_ptr, slot_off);
            debug_assert_eq!(&sv.shape[..], &src_shape[..], "Reduce source box");
            let desc = &prog.slots[*out as usize];
            let ooff = slot_off[*out as usize];
            let dst = unsafe { slab_ptr.add(ooff) };
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
            let sv = resolve_src(src, env, slab_ptr, slot_off);
            debug_assert_eq!(&sv.shape[..], &src_shape[..], "Scan source box");
            let dst = unsafe { slab_ptr.add(slot_off[*out as usize]) };
            let (a, init, inclusive, reverse) = (*axis as usize, *init, *inclusive, *reverse);
            macro_rules! scan {
                ($f:expr) => {
                    unsafe { scan_axis(dst, &sv, a, init, inclusive, reverse, $f) }
                };
            }
            dispatch_bin_kernel!(op, scan);
        }
        Instr::PolyArea { a, b, geom, out } => {
            let spec = &prog.geoms[*geom as usize];
            let av = resolve_src(a, env, slab_ptr, slot_off);
            let bv = resolve_src(b, env, slab_ptr, slot_off);
            let (ta, tb) = (ring_table(&av), ring_table(&bv));
            let dst = unsafe { slab_ptr.add(slot_off[*out as usize]) };
            unsafe { run_poly_area(spec, &ta, &tb, dst) };
        }
        Instr::IndexGather {
            src,
            idx,
            spec,
            out,
        } => {
            let spec = &prog.index_gathers[*spec as usize];
            let sv = resolve_src(src, env, slab_ptr, slot_off);
            let iv = resolve_rv(idx, &spec.shape, env, slab_ptr, slot_off);
            let dst = unsafe { slab_ptr.add(slot_off[*out as usize]) };
            unsafe { index_gather(dst, spec, &sv, &iv) };
        }
        Instr::DataGather {
            src,
            spec,
            out,
            faults,
        } => {
            let spec = &prog.data_gathers[*spec as usize];
            // One element read at scalar subscripts: the position straight
            // from the subscripts' values, no source view, no subscript
            // views. A read that faults takes the general path below, which
            // latches it.
            if spec.shape.is_empty() && spec.subs.len() <= 4 {
                let mut v = [0.0f64; 4];
                for (d, o) in spec.subs.iter().enumerate() {
                    v[d] = resolve_scalar(o, env, slab_ptr, slot_off);
                }
                let (base, _) = src_base(src, env, slab_ptr, slot_off);
                let x = match spec.at(|d| v[d]) {
                    DataAt::Elem(p) => Some(unsafe { *base.add(p) }),
                    DataAt::Ghost => Some(0.0),
                    DataAt::Fault { .. } => None,
                };
                if let Some(x) = x {
                    unsafe { *slab_ptr.add(slot_off[*out as usize]) = x };
                    return;
                }
            }
            let sv = resolve_src(src, env, slab_ptr, slot_off);
            let subs: SmallVec<[Rv; 4]> = spec
                .subs
                .iter()
                .map(|o| resolve_rv(o, &spec.shape, env, slab_ptr, slot_off))
                .collect();
            let dst = unsafe { slab_ptr.add(slot_off[*out as usize]) };
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
            let sv = resolve_src(src, env, slab_ptr, slot_off);
            let tbl = &prog.gather_tables[*table as usize];
            debug_assert_eq!(&sv.shape[..], &tbl.src_shape[..], "TableGather source box");
            let dst = unsafe { slab_ptr.add(slot_off[*out as usize]) };
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
            let rows = &prog.seg_tables[*table as usize].rows;
            let src = unsafe { slab_ptr.add(slot_off[*src as usize]) as *const f64 };
            let mask = mask.map(|m| unsafe { slab_ptr.add(slot_off[m as usize]) as *const f64 });
            let dst = unsafe { slab_ptr.add(slot_off[*out as usize]) };
            let init = *init;
            macro_rules! fold {
                ($f:expr) => {
                    unsafe { seg_reduce(dst, src, mask, rows, 0, init, $f) }
                };
            }
            dispatch_bin_kernel!(op, fold);
        }
        Instr::Reshape { src, out } => {
            let sv = resolve_src(src, env, slab_ptr, slot_off);
            debug_assert_eq!(
                sv.shape.iter().product::<usize>(),
                prog.slots[*out as usize].shape.iter().product::<usize>(),
                "Reshape element count"
            );
            // The source walked in its own row-major order, written
            // contiguously: `out`'s row-major layout over its own box.
            let dst = unsafe { slab_ptr.add(slot_off[*out as usize]) };
            unsafe { copy_strided(dst, &rm_strides(&sv.shape), sv.ptr, &sv.strides, &sv.shape) };
        }
        Instr::Fused { spec } => {
            let idx = &idx_tables[*spec as usize];
            unsafe {
                exec_fused(
                    *spec as usize,
                    env,
                    slab_ptr,
                    slot_off,
                    fregs,
                    fscratch,
                    idx,
                    simd,
                    dy_home,
                    dy,
                )
            };
        }
        Instr::DyWrite { write } => {
            let w = &prog.dy_writes[*write as usize];
            // Its fused group already stored the slot into `dy`.
            if dy_home[w.slot as usize] != usize::MAX {
                return;
            }
            let desc = &prog.slots[w.slot as usize];
            let off = slot_off[w.slot as usize];
            if let Some(pos) = &w.scatter {
                // The slot is contiguous row-major, the order `pos` lists.
                debug_assert_eq!(pos.len(), desc.elems());
                for (k, &p) in pos.iter().enumerate() {
                    unsafe { *dy.add(p) = *slab_ptr.add(off + k) };
                }
                return;
            }
            match w.scalar_flat {
                Some(flat) => {
                    debug_assert!(desc.scalar);
                    unsafe { *dy.add(flat) = *slab_ptr.add(off) };
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
                        copy_strided_maybe_split(
                            call_split,
                            dy.offset(dbase as isize),
                            &cm,
                            slab_ptr.add(off) as *const f64,
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

/// Whether [`exec_share`] can run `ins` share by share, and so whether a
/// split of it can be one task of a call plan (see `plan`).
#[cfg(not(target_arch = "wasm32"))]
pub(super) fn shares(prog: &TapeProgram, ins: &Instr) -> bool {
    match ins {
        Instr::Fused { .. } | Instr::Assemble { .. } => true,
        Instr::Copy { out, .. } => !prog.slots[*out as usize].scalar,
        Instr::Reduce { axes, out, .. } => {
            !prog.slots[*out as usize].scalar
                && axes.iter().enumerate().all(|(k, &a)| a as usize == k)
        }
        Instr::DyWrite { write } => {
            let w = &prog.dy_writes[*write as usize];
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
    let Cx {
        env,
        slab_ptr,
        slot_off,
        asm_covered,
        idx_tables,
        simd,
        dy_home,
        dy,
        ..
    } = *cx;
    let prog = env.prog;
    match ins {
        Instr::Fused { spec } => unsafe {
            super::fused::exec_fused_share(
                *spec as usize,
                env,
                slab_ptr,
                slot_off,
                &mut scratch.fscratch,
                &idx_tables[*spec as usize],
                simd,
                dy_home,
                dy,
                w,
                ways,
            )
        },
        Instr::Assemble { table, out } => {
            let desc = &prog.slots[*out as usize];
            let dst = unsafe { slab_ptr.add(slot_off[*out as usize]) };
            let out_rm = rm_strides(&desc.shape);
            let parts = &mut scratch.asm_parts;
            parts.clear();
            for (src, region) in &prog.assemblies[*table as usize].parts {
                let spec = &prog.regions[*region as usize];
                let mut dbase = 0i64;
                for d in 0..desc.shape.len() {
                    dbase += out_rm[d] * spec.dest_lo[d] as i64;
                }
                let rv = resolve_rv(src, &spec.shape, env, slab_ptr, slot_off);
                parts.push(super::par::AsmPart::new(*region, dbase, rv));
            }
            unsafe {
                super::par::assemble_share(
                    w,
                    ways,
                    dst,
                    &desc.shape,
                    &prog.regions,
                    parts,
                    asm_covered[*table as usize],
                )
            };
        }
        // The leading axes folded out of a contiguous source: worker `w`
        // owns a run of output cells and folds each of them whole, row by
        // row in the serial order.
        Instr::Reduce {
            op,
            init,
            src,
            axes,
            reverse,
            out,
            ..
        } => {
            let sv = resolve_src(src, env, slab_ptr, slot_off);
            let n_out = prog.slots[*out as usize].elems();
            let dst = unsafe { slab_ptr.add(slot_off[*out as usize]) };
            if sv.strides[..] != rm_strides(&sv.shape)[..] {
                // Not the contiguous layout the split assumes: one worker
                // runs it whole.
                if w == 0 {
                    unsafe { exec_straight(cx, ins, scratch, 1) };
                }
                return;
            }
            let (lo, hi) = super::par::share_at(n_out, w, ways, dst);
            let rows: usize = sv.shape[..axes.len()].iter().product();
            unsafe {
                for k in lo..hi {
                    *dst.add(k) = *init;
                }
            }
            let src = sv.ptr;
            macro_rules! fold_rows {
                ($f:expr) => {
                    for k in 0..rows {
                        // A reverse fold takes its rows from the last.
                        let r = if *reverse { rows - 1 - k } else { k };
                        unsafe { reduce_rows(dst.add(lo), hi - lo, src.add(r * n_out + lo), 1, $f) }
                    }
                };
            }
            dispatch_bin_kernel!(op, fold_rows);
        }
        // A scan along the leading axis: worker `w` sweeps the inner
        // positions (lanes) of its own share, every one whole and in order.
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
            let sv = resolve_src(src, env, slab_ptr, slot_off);
            let dst = unsafe { slab_ptr.add(slot_off[*out as usize]) };
            if sv.strides[..] != rm_strides(&sv.shape)[..] || src_shape.is_empty() {
                if w == 0 {
                    unsafe { exec_straight(cx, ins, scratch, 1) };
                }
                return;
            }
            let len = src_shape[0];
            let post: usize = src_shape[1..].iter().product();
            let (lo, hi) = super::par::share_at(post, w, ways, dst);
            let (init, inclusive, reverse, src) = (*init, *inclusive, *reverse, sv.ptr);
            macro_rules! scan {
                ($f:expr) => {
                    unsafe {
                        scan_leading_cols(dst, src, len, post, init, inclusive, reverse, lo, hi, $f)
                    }
                };
            }
            dispatch_bin_kernel!(op, scan);
        }
        Instr::Copy { a, out } => {
            let desc = &prog.slots[*out as usize];
            match resolve_rv(a, &desc.shape, env, slab_ptr, slot_off) {
                Rv::S(_) => panic!("array Copy from a scalar operand"),
                Rv::V { ptr, strides } => unsafe {
                    super::par::copy_strided_share(
                        ways,
                        w,
                        slab_ptr.add(slot_off[*out as usize]),
                        &rm_strides(&desc.shape),
                        ptr,
                        &strides,
                        &desc.shape,
                    )
                },
            }
        }
        Instr::DyWrite { write } => {
            let wr = &prog.dy_writes[*write as usize];
            // Its fused group already stored the slot into `dy`.
            if dy_home[wr.slot as usize] != usize::MAX {
                return;
            }
            let desc = &prog.slots[wr.slot as usize];
            let sv = &prog.state_vars[wr.var as usize];
            let cm = dy_strides(prog, &sv.shape);
            let mut dbase = sv.flat_offset as i64;
            for d in 0..sv.shape.len() {
                dbase += wr.dest_lo[d] as i64 * cm[d];
            }
            unsafe {
                super::par::copy_strided_share(
                    ways,
                    w,
                    dy.offset(dbase as isize),
                    &cm,
                    slab_ptr.add(slot_off[wr.slot as usize]) as *const f64,
                    &rm_strides(&desc.shape),
                    &desc.shape,
                )
            };
        }
        _ => unreachable!("not a shared instruction: {}", ins.opcode()),
    }
}
