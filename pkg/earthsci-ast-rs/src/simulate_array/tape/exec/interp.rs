//! The instruction loop: decode one `Instr` at a time, resolve its operands
//! through `resolve`, and apply the loops in `kernels` / `fused`.
//!
//! This is the only module that knows the instruction encoding, which is
//! why the boundary sits here: the kernels it drives know pointers and
//! strides and nothing about the program.

use super::super::geom::{RingTable, run_poly_area};
use super::fused::{dispatch_bin_kernel, dispatch_un_kernel, exec_fused};
use super::kernels::{
    copy_strided, ew_select, ew1, ew2, exec_gather, fill_strided, index_gather, reduce_axis,
    reduce_rows, scan_axis, seg_reduce, table_gather,
};
use super::oracle::run_rhs_oracle;
use super::resolve::{Rv, SrcView, resolve_rv, resolve_scalar, resolve_src, rm_strides};
use super::*;
use crate::simulate_array::eval::latch_gather_fault;

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
    stats: &mut RhsStats,
) {
    // The call's split width (see `par`), for the copies and lanes below.
    let call_split = call_ways(exec);
    let TapeExec {
        slab,
        slot_off,
        obs,
        parked,
        export_sites,
        pending,
        plan_full,
        asm_covered,
        #[cfg(not(target_arch = "wasm32"))]
        asm_parts,
        fregs,
        fscratch,
        idx_tables,
        lscratch,
        exports_active,
        simd,
        dy_home,
        ..
    } = exec;
    let dy_home: &[usize] = dy_home;
    let exports_active = *exports_active;
    let simd = *simd;
    let prog = env.prog;
    let slab_ptr = slab.as_mut_ptr();
    let slot_off: &[usize] = slot_off;
    pending.clear();
    // Withdraw every export this range is about to publish again, so a read
    // that runs before its `Export` finds no entry and the resolver faults
    // naming it (CONFORMANCE_SPEC §5.23.1(2)). Exports of sections this call
    // does not re-run stay published.
    for &(pc, e) in export_sites.iter() {
        let e = e as usize;
        if range.contains(&pc) && parked[e].is_none() {
            parked[e] = obs.remove_entry(&prog.exports[e].0);
        }
    }

    // The open recurrence sweep, if any: the `Sweep` instruction's position
    // and the 0-based frame cell its body is evaluating.
    let mut sweep: Option<(usize, SmallVec<[usize; 4]>)> = None;
    let mut pc = range.start;
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
                let v = resolve_scalar(&sw.result, env, slab_ptr, slot_off, obs);
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
        // The instruction's own precision, armed for it alone (esm-spec
        // §11.3.1); a program without per-instruction precision skips this.
        let _precision = prog
            .precision
            .get(pc)
            .filter(|&&p| p != crate::precision::active())
            .map(|&p| crate::precision::enter(p));
        match &prog.instrs[pc] {
            Instr::Bin { op, a, b, out } => {
                let desc = &prog.slots[*out as usize];
                let off = slot_off[*out as usize];
                if desc.scalar {
                    let f = binary_kernel_of(*op);
                    let x = resolve_scalar(a, env, slab_ptr, slot_off, obs);
                    let y = resolve_scalar(b, env, slab_ptr, slot_off, obs);
                    unsafe { *slab_ptr.add(off) = f(x, y) };
                } else {
                    let av = resolve_rv(a, &desc.shape, env, slab_ptr, slot_off, obs);
                    let bv = resolve_rv(b, &desc.shape, env, slab_ptr, slot_off, obs);
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
                    let x = resolve_scalar(a, env, slab_ptr, slot_off, obs);
                    unsafe { *slab_ptr.add(off) = f(x) };
                } else {
                    let av = resolve_rv(a, &desc.shape, env, slab_ptr, slot_off, obs);
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
                    let x = resolve_scalar(a, env, slab_ptr, slot_off, obs);
                    unsafe { *slab_ptr.add(off) = -x };
                } else {
                    let av = resolve_rv(a, &desc.shape, env, slab_ptr, slot_off, obs);
                    unsafe { ew1(slab_ptr.add(off), &desc.shape, &av, |x| -x) };
                }
            }
            Instr::Select { cond, a, b, out } => {
                let desc = &prog.slots[*out as usize];
                let off = slot_off[*out as usize];
                if desc.scalar {
                    let c = resolve_scalar(cond, env, slab_ptr, slot_off, obs);
                    let x = resolve_scalar(a, env, slab_ptr, slot_off, obs);
                    let y = resolve_scalar(b, env, slab_ptr, slot_off, obs);
                    unsafe { *slab_ptr.add(off) = if c != 0.0 { x } else { y } };
                } else {
                    let cv = resolve_rv(cond, &desc.shape, env, slab_ptr, slot_off, obs);
                    let av = resolve_rv(a, &desc.shape, env, slab_ptr, slot_off, obs);
                    let bv = resolve_rv(b, &desc.shape, env, slab_ptr, slot_off, obs);
                    unsafe { ew_select(slab_ptr.add(off), &desc.shape, &cv, &av, &bv) };
                }
            }
            Instr::Gather { src, plan, out } => {
                let full = plan_full[*plan as usize];
                let plan = &prog.plans[*plan as usize];
                let sv = resolve_src(src, env, slab_ptr, slot_off, obs);
                let off = slot_off[*out as usize];
                unsafe { exec_gather(plan, &sv, slab_ptr.add(off), full, call_split) };
            }
            Instr::LoadElem { src, idx, out } => {
                let sv = resolve_src(src, env, slab_ptr, slot_off, obs);
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
                let s = resolve_scalar(v, env, slab_ptr, slot_off, obs);
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
                    let x = resolve_scalar(a, env, slab_ptr, slot_off, obs);
                    unsafe { *slab_ptr.add(off) = x };
                } else {
                    let av = resolve_rv(a, &desc.shape, env, slab_ptr, slot_off, obs);
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
                let sv = resolve_rv(src, &spec.shape, env, slab_ptr, slot_off, obs);
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
                            let rv = resolve_rv(src, &spec.shape, env, slab_ptr, slot_off, obs);
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
                        match resolve_rv(src, &spec.shape, env, slab_ptr, slot_off, obs) {
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
                    let xv = resolve_scalar(x, env, slab_ptr, slot_off, obs);
                    let yv = y.map_or(f64::NAN, |y| {
                        resolve_scalar(&y, env, slab_ptr, slot_off, obs)
                    });
                    unsafe { *slab_ptr.add(off) = tbl.at(xv, yv) };
                } else {
                    let xv = resolve_rv(x, &desc.shape, env, slab_ptr, slot_off, obs);
                    let dst = unsafe { slab_ptr.add(off) };
                    let sh = &desc.shape;
                    match y {
                        // `y` is read only by `interp.bilinear`; the other two
                        // entries never look at it.
                        None => unsafe { ew1(dst, sh, &xv, |a| tbl.at(a, f64::NAN)) },
                        Some(y) => {
                            let yv = resolve_rv(y, &desc.shape, env, slab_ptr, slot_off, obs);
                            unsafe { ew2(dst, sh, &xv, &yv, |a, b| tbl.at(a, b)) }
                        }
                    }
                }
            }
            Instr::Calendar { func, a, out } => {
                let desc = &prog.slots[*out as usize];
                let off = slot_off[*out as usize];
                if desc.scalar {
                    let av = resolve_scalar(a, env, slab_ptr, slot_off, obs);
                    unsafe { *slab_ptr.add(off) = calendar_at(*func, av) };
                } else {
                    let av = resolve_rv(a, &desc.shape, env, slab_ptr, slot_off, obs);
                    let dst = unsafe { slab_ptr.add(off) };
                    unsafe { ew1(dst, &desc.shape, &av, |x| calendar_at(*func, x)) };
                }
            }
            Instr::ConstArray { data, out } => {
                let d = &prog.const_data[*data as usize];
                let off = slot_off[*out as usize];
                debug_assert_eq!(d.values.len(), prog.slots[*out as usize].elems());
                unsafe {
                    std::ptr::copy_nonoverlapping(
                        d.values.as_ptr(),
                        slab_ptr.add(off),
                        d.values.len(),
                    );
                }
            }
            Instr::LoadForcing { forcing, out } => {
                let fr = &prog.forcings[*forcing as usize];
                let off = slot_off[*out as usize];
                let dst =
                    unsafe { std::slice::from_raw_parts_mut(slab_ptr.add(off), forcing_len(fr)) };
                load_forcing(fr, &env.forcing.borrow(), env.declared, prog.col_major, dst);
            }
            Instr::Reduce {
                op,
                init,
                src,
                axes,
                src_shape,
                out,
            } => {
                let f = binary_kernel_of(*op);
                let sv = resolve_src(src, env, slab_ptr, slot_off, obs);
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
                            unsafe { reduce_rows(dst, n_out, src, rows, $f) }
                        };
                    }
                    dispatch_bin_kernel!(op, fold_rows);
                    pc += 1;
                    continue;
                }
                // One folded axis anywhere in a contiguous source: each output
                // cell folds its own run in axis order.
                if axes.len() == 1 && sv.strides[..] == rm_strides(&sv.shape)[..] {
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
                    pc += 1;
                    continue;
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
                        soff += sv.strides[d] * idx[d] as i64;
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
                src_shape,
                out,
            } => {
                let sv = resolve_src(src, env, slab_ptr, slot_off, obs);
                debug_assert_eq!(&sv.shape[..], &src_shape[..], "Scan source box");
                let dst = unsafe { slab_ptr.add(slot_off[*out as usize]) };
                let (a, init, inclusive) = (*axis as usize, *init, *inclusive);
                macro_rules! scan {
                    ($f:expr) => {
                        unsafe { scan_axis(dst, &sv, a, init, inclusive, $f) }
                    };
                }
                dispatch_bin_kernel!(op, scan);
            }
            Instr::PolyArea { a, b, geom, out } => {
                let spec = &prog.geoms[*geom as usize];
                let av = resolve_src(a, env, slab_ptr, slot_off, obs);
                let bv = resolve_src(b, env, slab_ptr, slot_off, obs);
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
                let sv = resolve_src(src, env, slab_ptr, slot_off, obs);
                let iv = resolve_rv(idx, &spec.shape, env, slab_ptr, slot_off, obs);
                let dst = unsafe { slab_ptr.add(slot_off[*out as usize]) };
                unsafe { index_gather(dst, spec, &sv, &iv) };
            }
            Instr::TableGather { src, table, out } => {
                let sv = resolve_src(src, env, slab_ptr, slot_off, obs);
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
                let mask =
                    mask.map(|m| unsafe { slab_ptr.add(slot_off[m as usize]) as *const f64 });
                let dst = unsafe { slab_ptr.add(slot_off[*out as usize]) };
                let init = *init;
                macro_rules! fold {
                    ($f:expr) => {
                        unsafe { seg_reduce(dst, src, mask, rows, init, $f) }
                    };
                }
                dispatch_bin_kernel!(op, fold);
            }
            Instr::Reshape { src, out } => {
                let sv = resolve_src(src, env, slab_ptr, slot_off, obs);
                debug_assert_eq!(
                    sv.shape.iter().product::<usize>(),
                    prog.slots[*out as usize].shape.iter().product::<usize>(),
                    "Reshape element count"
                );
                // The source walked in its own row-major order, written
                // contiguously: `out`'s row-major layout over its own box.
                let dst = unsafe { slab_ptr.add(slot_off[*out as usize]) };
                unsafe {
                    copy_strided(dst, &rm_strides(&sv.shape), sv.ptr, &sv.strides, &sv.shape)
                };
            }
            Instr::Fault { fault } => {
                latch_gather_fault(prog.faults[*fault as usize].clone());
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
                let sv = resolve_src(src, env, slab_ptr, slot_off, obs);
                let raw: SmallVec<[i64; 4]> = sp
                    .subs
                    .iter()
                    .map(|o| subscript_of(resolve_scalar(o, env, slab_ptr, slot_off, obs)))
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
                let c = resolve_scalar(cond, env, slab_ptr, slot_off, obs);
                if c != 0.0 {
                    // Execute the true region, then skip the false one.
                    pending.push(((pc + 1 + *n_true as usize) as u32, *n_false));
                } else {
                    pc += *n_true as usize; // skip straight to the false region
                }
            }
            Instr::Fallback { rule } => {
                let info = &prog.rules[*rule as usize];
                match info.kind {
                    RuleKind::Observed(i) => {
                        materialize_observeds_pass(
                            obs,
                            std::slice::from_ref(&env.observed_rules[i]),
                            &ObsPass {
                                env: env.eval_env(),
                                force_scalar: false,
                            },
                            stats,
                        );
                    }
                    RuleKind::Rhs(i) => {
                        run_rhs_oracle(&env.rhs_rules[i], env.var_shapes, &env.eval_env(), obs, dy);
                    }
                }
            }
            Instr::Export { slot, export } => {
                // Step 4 export demotion: no fallback rules, no check mode,
                // no explicit request ⇒ nothing can read the published
                // array — skip the publish memcpy.
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
            Instr::Fused { spec } => {
                let idx = &idx_tables[*spec as usize];
                let dy_ptr = dy.as_mut_ptr();
                unsafe {
                    exec_fused(
                        *spec as usize,
                        env,
                        slab_ptr,
                        slot_off,
                        obs,
                        fregs,
                        fscratch,
                        idx,
                        simd,
                        dy_home,
                        dy_ptr,
                    )
                };
            }
            Instr::DyWrite { write } => {
                let w = &prog.dy_writes[*write as usize];
                // Its fused group already stored the slot into `dy`.
                if dy_home[w.slot as usize] != usize::MAX {
                    pc += 1;
                    continue;
                }
                let desc = &prog.slots[w.slot as usize];
                let off = slot_off[w.slot as usize];
                if let Some(pos) = &w.scatter {
                    // The slot is contiguous row-major, the order `pos` lists.
                    debug_assert_eq!(pos.len(), desc.elems());
                    for (k, &p) in pos.iter().enumerate() {
                        dy[p] = unsafe { *slab_ptr.add(off + k) };
                    }
                    pc += 1;
                    continue;
                }
                match w.scalar_flat {
                    Some(flat) => {
                        debug_assert!(desc.scalar);
                        dy[flat] = unsafe { *slab_ptr.add(off) };
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
                            sv.flat_offset + sv.shape.iter().product::<usize>().max(1) <= dy.len()
                        );
                        unsafe {
                            copy_strided_maybe_split(
                                call_split,
                                dy.as_mut_ptr().offset(dbase as isize),
                                &cm,
                                slab_ptr.add(off) as *const f64,
                                &rm_strides(&desc.shape),
                                &desc.shape,
                            );
                        }
                    }
                }
            }
            Instr::Lanes { spec } => unsafe {
                super::lanes::exec_lanes(
                    &prog.lanes[*spec as usize],
                    env,
                    slab_ptr,
                    slot_off,
                    obs,
                    lscratch,
                    dy,
                    simd,
                    call_split,
                )
            },
        }
        pc += 1;
    }
}
