//! The instruction loop: decode one `Instr` at a time, resolve its operands
//! through `resolve`, and apply the loops in `kernels` / `fused`.
//!
//! This is the only module that knows the instruction encoding, which is
//! why the boundary sits here: the kernels it drives know pointers and
//! strides and nothing about the program.

use super::fused::{dispatch_bin_kernel, dispatch_un_kernel, exec_fused};
use super::kernels::{copy_strided, ew_select, ew1, ew2, exec_gather, fill_strided};
use super::oracle::run_rhs_oracle;
use super::resolve::{Rv, cm_strides, resolve_rv, resolve_scalar, resolve_src, rm_strides};
use super::*;

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
    let TapeExec {
        slab,
        slot_off,
        obs,
        pending,
        plan_full,
        fregs,
        exports_active,
        simd,
        ..
    } = exec;
    let exports_active = *exports_active;
    let simd = *simd;
    let prog = env.prog;
    let slab_ptr = slab.as_mut_ptr();
    let slot_off: &[usize] = slot_off;
    pending.clear();

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
        if pc >= range.end {
            break;
        }
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
                unsafe { exec_gather(plan, &sv, slab_ptr.add(off), full) };
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
                            copy_strided(
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
                let name = &prog.exports[*export as usize].0;
                let a = obs.get_mut(name).expect("export array preallocated");
                let desc = &prog.slots[*slot as usize];
                let off = slot_off[*slot as usize];
                if desc.scalar {
                    a[IxDyn(&[])] = unsafe { *slab_ptr.add(off) };
                } else {
                    let dst = a.as_slice_mut().expect("export arrays are standard layout");
                    unsafe {
                        std::ptr::copy_nonoverlapping(
                            slab_ptr.add(off) as *const f64,
                            dst.as_mut_ptr(),
                            desc.elems(),
                        );
                    }
                }
            }
            Instr::Fused { spec } => {
                let fs = &prog.fused[*spec as usize];
                unsafe { exec_fused(fs, env, slab_ptr, slot_off, obs, fregs, simd) };
            }
            Instr::DyWrite { write } => {
                let w = &prog.dy_writes[*write as usize];
                let desc = &prog.slots[w.slot as usize];
                let off = slot_off[w.slot as usize];
                match w.scalar_flat {
                    Some(flat) => {
                        debug_assert!(desc.scalar);
                        dy[flat] = unsafe { *slab_ptr.add(off) };
                    }
                    None => {
                        let sv = &prog.state_vars[w.var as usize];
                        let cm = cm_strides(&sv.shape);
                        let mut dbase = sv.flat_offset as i64;
                        for d in 0..sv.shape.len() {
                            dbase += w.dest_lo[d] as i64 * cm[d];
                        }
                        debug_assert!(
                            sv.flat_offset + sv.shape.iter().product::<usize>().max(1) <= dy.len()
                        );
                        unsafe {
                            copy_strided(
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
        }
        pc += 1;
    }
}
