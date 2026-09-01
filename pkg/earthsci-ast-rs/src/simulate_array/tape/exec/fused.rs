//! Fused-group execution: the per-chunk kernels, the monomorphized kernel
//! dispatch tables, and the strip-mined executor that runs one `FusedSpec`
//! (plus its `#[target_feature]` SIMD clones and the per-element
//! measurement arm).
//!
//! The dispatch macros live beside the chunk kernels rather than in
//! `interp` because BOTH executors expand them — the chunked loops here and
//! the unfused instruction arms in `interp` — and a single definition is
//! what makes an op monomorphized in one path impossible to miss in the
//! other.

use super::resolve::resolve_scalar;
use super::*;

// ---------------------------------------------------------------------------
// Step 4: fused-group execution.
// ---------------------------------------------------------------------------

/// Chunk length of the strip-mined fused executor: intermediates live in a
/// small register file (`n_regs × FCHUNK` doubles, L1-resident) instead of
/// round-tripping ~55 KB slab arrays between every op.
pub(super) const FCHUNK: usize = 1024;

/// `ESS_TAPE_FUSE_MODE=elem`: run fused groups through the per-element
/// micro-op interpreter instead of the chunked one (measurement arm for the
/// Step 4 interpreter-design comparison; bit-identical either way).
fn fuse_elem_mode() -> bool {
    use std::sync::OnceLock;
    static ELEM: OnceLock<bool> = OnceLock::new();
    *ELEM.get_or_init(|| {
        std::env::var("ESS_TAPE_FUSE_MODE")
            .map(|v| v.eq_ignore_ascii_case("elem"))
            .unwrap_or(false)
    })
}

/// A micro-op operand resolved for one chunk: a pointer to `c` contiguous
/// values, or a constant broadcast over the chunk.
#[derive(Clone, Copy)]
enum MSrc {
    P(*const f64),
    C(f64),
}

/// `dst[k] = f(a[k])` over one chunk. `dst` is a register region; a `P`
/// operand is either a DIFFERENT register region (the allocator never assigns
/// an op's out register to one of its operands) or a slab/state/observed
/// buffer (disjoint from the register file), so slice-based loops are sound —
/// and vectorizable.
#[inline(always)]
unsafe fn fch1(dst: *mut f64, c: usize, a: MSrc, f: impl Fn(f64) -> f64 + Copy) {
    unsafe {
        let d = std::slice::from_raw_parts_mut(dst, c);
        match a {
            MSrc::P(pa) => {
                let a = std::slice::from_raw_parts(pa, c);
                for (x, &v) in d.iter_mut().zip(a) {
                    *x = f(v);
                }
            }
            MSrc::C(v) => {
                let y = f(v);
                for x in d.iter_mut() {
                    *x = y;
                }
            }
        }
    }
}

/// `dst[k] = f(a[k], b[k])` over one chunk (see `fch1` for the aliasing
/// argument; the two operands may alias EACH OTHER, which shared slices
/// permit).
#[inline(always)]
unsafe fn fch2(dst: *mut f64, c: usize, a: MSrc, b: MSrc, f: impl Fn(f64, f64) -> f64 + Copy) {
    unsafe {
        let d = std::slice::from_raw_parts_mut(dst, c);
        match (a, b) {
            (MSrc::P(pa), MSrc::P(pb)) => {
                let a = std::slice::from_raw_parts(pa, c);
                let b = std::slice::from_raw_parts(pb, c);
                for k in 0..c {
                    *d.get_unchecked_mut(k) = f(*a.get_unchecked(k), *b.get_unchecked(k));
                }
            }
            (MSrc::P(pa), MSrc::C(y)) => {
                let a = std::slice::from_raw_parts(pa, c);
                for (x, &v) in d.iter_mut().zip(a) {
                    *x = f(v, y);
                }
            }
            (MSrc::C(x0), MSrc::P(pb)) => {
                let b = std::slice::from_raw_parts(pb, c);
                for (x, &y) in d.iter_mut().zip(b) {
                    *x = f(x0, y);
                }
            }
            (MSrc::C(x0), MSrc::C(y0)) => {
                let v = f(x0, y0);
                for x in d.iter_mut() {
                    *x = v;
                }
            }
        }
    }
}

/// `dst[k] = g(a[k], b[k], c[k])` over one chunk (the Bin2 superop; see
/// `fch1` for the aliasing argument).
#[inline(always)]
unsafe fn fch3(
    dst: *mut f64,
    n: usize,
    a: MSrc,
    b: MSrc,
    cc: MSrc,
    g: impl Fn(f64, f64, f64) -> f64 + Copy,
) {
    unsafe {
        let d = std::slice::from_raw_parts_mut(dst, n);
        macro_rules! lp {
            ($ax:expr, $bx:expr, $cx:expr) => {
                for k in 0..n {
                    *d.get_unchecked_mut(k) = g($ax(k), $bx(k), $cx(k));
                }
            };
        }
        match (a, b, cc) {
            (MSrc::P(pa), MSrc::P(pb), MSrc::P(pc)) => {
                let (a, b, c) = (
                    std::slice::from_raw_parts(pa, n),
                    std::slice::from_raw_parts(pb, n),
                    std::slice::from_raw_parts(pc, n),
                );
                lp!(
                    |k: usize| *a.get_unchecked(k),
                    |k: usize| *b.get_unchecked(k),
                    |k: usize| *c.get_unchecked(k)
                );
            }
            (MSrc::P(pa), MSrc::P(pb), MSrc::C(z)) => {
                let (a, b) = (
                    std::slice::from_raw_parts(pa, n),
                    std::slice::from_raw_parts(pb, n),
                );
                lp!(
                    |k: usize| *a.get_unchecked(k),
                    |k: usize| *b.get_unchecked(k),
                    |_k: usize| z
                );
            }
            (MSrc::P(pa), MSrc::C(y), MSrc::P(pc)) => {
                let (a, c) = (
                    std::slice::from_raw_parts(pa, n),
                    std::slice::from_raw_parts(pc, n),
                );
                lp!(|k: usize| *a.get_unchecked(k), |_k: usize| y, |k: usize| *c
                    .get_unchecked(k));
            }
            (MSrc::P(pa), MSrc::C(y), MSrc::C(z)) => {
                let a = std::slice::from_raw_parts(pa, n);
                lp!(|k: usize| *a.get_unchecked(k), |_k: usize| y, |_k: usize| z);
            }
            (MSrc::C(x), MSrc::P(pb), MSrc::P(pc)) => {
                let (b, c) = (
                    std::slice::from_raw_parts(pb, n),
                    std::slice::from_raw_parts(pc, n),
                );
                lp!(|_k: usize| x, |k: usize| *b.get_unchecked(k), |k: usize| *c
                    .get_unchecked(k));
            }
            (MSrc::C(x), MSrc::P(pb), MSrc::C(z)) => {
                let b = std::slice::from_raw_parts(pb, n);
                lp!(|_k: usize| x, |k: usize| *b.get_unchecked(k), |_k: usize| z);
            }
            (MSrc::C(x), MSrc::C(y), MSrc::P(pc)) => {
                let c = std::slice::from_raw_parts(pc, n);
                lp!(|_k: usize| x, |_k: usize| y, |k: usize| *c.get_unchecked(k));
            }
            (MSrc::C(x), MSrc::C(y), MSrc::C(z)) => {
                let v = g(x, y, z);
                for w in d.iter_mut() {
                    *w = v;
                }
            }
        }
    }
}

/// `dst[k] = g(a[k], b[k], c[k], d[k])` over one chunk, all operands
/// pointers (the Bin3 superop; scalar/ghost operands were resolved to splat
/// registers by the caller). See `fch1` for the aliasing argument; operands
/// may alias each other, which shared slices permit.
#[inline(always)]
unsafe fn fch4(
    dst: *mut f64,
    n: usize,
    pa: *const f64,
    pb: *const f64,
    pc: *const f64,
    pd: *const f64,
    g: impl Fn(f64, f64, f64, f64) -> f64 + Copy,
) {
    unsafe {
        let o = std::slice::from_raw_parts_mut(dst, n);
        let a = std::slice::from_raw_parts(pa, n);
        let b = std::slice::from_raw_parts(pb, n);
        let c = std::slice::from_raw_parts(pc, n);
        let d = std::slice::from_raw_parts(pd, n);
        for k in 0..n {
            *o.get_unchecked_mut(k) = g(
                *a.get_unchecked(k),
                *b.get_unchecked(k),
                *c.get_unchecked(k),
                *d.get_unchecked(k),
            );
        }
    }
}

/// The `vec_select` pick over one chunk.
#[inline(always)]
unsafe fn fch_sel(dst: *mut f64, c: usize, cond: MSrc, a: MSrc, b: MSrc) {
    // A constant condition is the filter-gate broadcast: whole-chunk pick.
    if let MSrc::C(cv) = cond {
        let pick = if cv != 0.0 { a } else { b };
        unsafe { fch1(dst, c, pick, |x| x) };
        return;
    }
    let MSrc::P(cp) = cond else { unreachable!() };
    unsafe {
        let d = std::slice::from_raw_parts_mut(dst, c);
        let cs = std::slice::from_raw_parts(cp, c);
        // Monomorphized over the operand kinds so each arm is a branch-free
        // (blendable) loop rather than a per-element kind dispatch.
        match (a, b) {
            (MSrc::P(pa), MSrc::P(pb)) => {
                let a = std::slice::from_raw_parts(pa, c);
                let b = std::slice::from_raw_parts(pb, c);
                for k in 0..c {
                    // Load both, then select VALUES (evaluate-both semantics;
                    // a value select vectorizes to a blend, where a pointer
                    // select stays a scalar cmov+load).
                    let av = *a.get_unchecked(k);
                    let bv = *b.get_unchecked(k);
                    *d.get_unchecked_mut(k) = if *cs.get_unchecked(k) != 0.0 { av } else { bv };
                }
            }
            (MSrc::P(pa), MSrc::C(y)) => {
                let a = std::slice::from_raw_parts(pa, c);
                for k in 0..c {
                    let av = *a.get_unchecked(k);
                    *d.get_unchecked_mut(k) = if *cs.get_unchecked(k) != 0.0 { av } else { y };
                }
            }
            (MSrc::C(x), MSrc::P(pb)) => {
                let b = std::slice::from_raw_parts(pb, c);
                for k in 0..c {
                    let bv = *b.get_unchecked(k);
                    *d.get_unchecked_mut(k) = if *cs.get_unchecked(k) != 0.0 { x } else { bv };
                }
            }
            (MSrc::C(x), MSrc::C(y)) => {
                for k in 0..c {
                    *d.get_unchecked_mut(k) = if *cs.get_unchecked(k) != 0.0 { x } else { y };
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Monomorphized kernel dispatch tables — expanded ONCE, used by BOTH the
// unfused executor (`run_range`, through the strided `ew1`/`ew2` loops) and
// the fused chunk executor (`exec_fused_runs`, through `fch1`/`fch2`), so an
// op given a monomorphized arm in one cannot be missed in the other.
// ---------------------------------------------------------------------------

/// Dispatch a [`BinCode`] to `$apply!(kernel)` with a monomorphized closure
/// for each hot op. Each closure body is the IDENTICAL expression to
/// `binary_kernel_of`'s arm for that op, so this is a pure dispatch hoist —
/// one indirect kernel call per node (unfused) or per chunk (fused) becomes
/// an inlined, vectorizable element loop. The arms mirror `vec_combine`'s,
/// plus the comparison relops feeding `Select` masks; any remaining op falls
/// through to the shared fn-pointer table itself, so semantics have a single
/// source either way.
macro_rules! dispatch_bin_kernel {
    ($op:expr, $apply:ident) => {
        // Under `element_type: "Float32"` the monomorphized closures below are
        // a SECOND, hand-copied definition of the arithmetic that never sees
        // the precision — the archetypal fast path that quietly stays f64. So
        // in that mode dispatch through the shared table instead, which returns
        // the binary32 kernel. The element loop then makes one indirect call
        // per element as it did before the monomorphization; correctness over
        // throughput is the only defensible trade when the answer differs.
        if $crate::precision::is_f32() {
            $apply!(binary_kernel_of(*$op))
        } else {
            match $op {
            BinCode::Add => $apply!(|x, y| x + y),
            BinCode::Sub => $apply!(|x, y| x - y),
            BinCode::Mul => $apply!(|x, y| x * y),
            BinCode::Div => $apply!(|x, y| x / y),
            BinCode::Pow => $apply!(|x: f64, y: f64| x.powf(y)),
            BinCode::Min => $apply!(|x: f64, y: f64| x.min(y)),
            BinCode::Max => $apply!(|x: f64, y: f64| x.max(y)),
            BinCode::Eq => $apply!(|x, y| (x == y) as i32 as f64),
            BinCode::Ne => $apply!(|x, y| (x != y) as i32 as f64),
            BinCode::Lt => $apply!(|x, y| (x < y) as i32 as f64),
            BinCode::Le => $apply!(|x, y| (x <= y) as i32 as f64),
            BinCode::Gt => $apply!(|x, y| (x > y) as i32 as f64),
            BinCode::Ge => $apply!(|x, y| (x >= y) as i32 as f64),
            other => $apply!(binary_kernel_of(*other)),
            }
        }
    };
}
pub(super) use dispatch_bin_kernel;

/// Dispatch a [`UnCode`] to `$apply!(kernel)` with a monomorphized closure
/// for each hot op — the unary counterpart of [`dispatch_bin_kernel`]: each
/// closure body is the IDENTICAL expression to `unary_kernel_of`'s arm, and
/// the remaining ops fall through to the fn-pointer table.
macro_rules! dispatch_un_kernel {
    ($op:expr, $apply:ident) => {
        // See `dispatch_bin_kernel`: the monomorphized arms are f64-only, so
        // Float32 routes through the shared (precision-aware) table.
        if $crate::precision::is_f32() {
            $apply!(unary_kernel_of(*$op))
        } else {
            match $op {
            UnCode::Abs => $apply!(|x: f64| x.abs()),
            UnCode::Sqrt => $apply!(|x: f64| x.sqrt()),
            UnCode::Exp => $apply!(|x: f64| x.exp()),
            UnCode::Ln => $apply!(|x: f64| x.ln()),
            UnCode::Log10 => $apply!(|x: f64| x.log10()),
            UnCode::Sin => $apply!(|x: f64| x.sin()),
            UnCode::Cos => $apply!(|x: f64| x.cos()),
            UnCode::Tanh => $apply!(|x: f64| x.tanh()),
            UnCode::Floor => $apply!(|x: f64| x.floor()),
            UnCode::Ceil => $apply!(|x: f64| x.ceil()),
            UnCode::Sign => $apply!(|x: f64| {
                if x > 0.0 {
                    1.0
                } else if x < 0.0 {
                    -1.0
                } else {
                    0.0
                }
            }),
            other => $apply!(unary_kernel_of(*other)),
            }
        }
    };
}
pub(super) use dispatch_un_kernel;

/// Execute one fused group. Iterates the precompiled run schedule; each run
/// is strip-mined into `FCHUNK`-element chunks whose micro-ops execute over
/// the register file, then live-out registers store to the slab. Per element
/// this applies exactly the same scalar kernels in the same order as the
/// unfused instructions (elementwise maps — chunking cannot change a bit).
#[inline(never)]
pub(super) unsafe fn exec_fused(
    fs: &FusedSpec,
    env: &Env,
    slab_ptr: *mut f64,
    slot_off: &[usize],
    obs: &ArrMap,
    fregs: &mut [f64],
    simd: SimdLevel,
) {
    // Resolve scalar inputs once.
    let mut svals: SmallVec<[f64; 8]> = SmallVec::new();
    for op in &fs.scalars {
        svals.push(resolve_scalar(op, env, slab_ptr, slot_off, obs));
    }
    // Resolve array input base pointers once.
    let mut bases: SmallVec<[*const f64; 8]> = SmallVec::new();
    for inp in &fs.inputs {
        let p: *const f64 = match &inp.src {
            SrcRef::Slot(s) => {
                debug_assert_eq!(&env.prog.slots[*s as usize].shape, &inp.src_shape);
                unsafe { slab_ptr.add(slot_off[*s as usize]) as *const f64 }
            }
            SrcRef::State(ix) => {
                let sv = &env.prog.state_vars[*ix as usize];
                debug_assert_eq!(&sv.shape, &inp.src_shape);
                unsafe { env.state_rm.as_ptr().add(sv.flat_offset) }
            }
            SrcRef::Obs(ix) => {
                let name = &env.prog.obs_reads[*ix as usize];
                let a = obs
                    .get(name)
                    .unwrap_or_else(|| panic!("observed `{name}` not materialized before read"));
                assert_eq!(
                    a.shape(),
                    &inp.src_shape[..],
                    "fused input `{name}` box mismatch"
                );
                assert!(a.is_standard_layout());
                a.as_ptr()
            }
        };
        bases.push(p);
    }
    // Output slab pointers.
    let mut outs: SmallVec<[(u16, *mut f64); 2]> = SmallVec::new();
    for &(reg, slot) in &fs.outputs {
        outs.push((reg, unsafe { slab_ptr.add(slot_off[slot as usize]) }));
    }

    if fuse_elem_mode() {
        unsafe { exec_fused_elem(fs, &svals, &bases, &outs) };
        return;
    }

    // Step 4b: run the chunked micro-program through the SIMD clone selected
    // at executor construction. Same source, same scalar semantics — the
    // `#[target_feature]` wrappers only widen the auto-vectorized lanes.
    match simd {
        SimdLevel::Generic => unsafe { exec_fused_runs_generic(fs, &svals, &bases, &outs, fregs) },
        #[cfg(target_arch = "x86_64")]
        SimdLevel::Avx2 => unsafe { exec_fused_runs_avx2(fs, &svals, &bases, &outs, fregs) },
        #[cfg(target_arch = "x86_64")]
        SimdLevel::Avx512 => unsafe { exec_fused_runs_avx512(fs, &svals, &bases, &outs, fregs) },
    }
}

/// The strip-mined chunk loop of [`exec_fused`], monomorphized per SIMD
/// level through the `#[target_feature]` wrappers below (`#[inline(always)]`
/// so each wrapper compiles the WHOLE loop nest — micro-op dispatch, chunk
/// kernels and stores — under its feature set).
#[inline(always)]
unsafe fn exec_fused_runs(
    fs: &FusedSpec,
    svals: &[f64],
    bases: &[*const f64],
    outs: &[(u16, *mut f64)],
    fregs: &mut [f64],
) {
    let rp = fregs.as_mut_ptr();
    // Bin3 splat registers: one FCHUNK broadcast per scalar plus a zero
    // register (the ghost read), filled once per call. The values are the
    // EXACT scalars / the exact `+0.0` ghost, so an all-pointer superop
    // reads identical bits to the `MSrc::C` broadcast it replaces.
    let splat_base = fs.n_regs as usize + fs.n_load_regs as usize;
    let zero_ix = splat_base + svals.len();
    if fs.n_splat_regs > 0 {
        debug_assert_eq!(fs.n_splat_regs as usize, svals.len() + 1);
        unsafe {
            for (i, &v) in svals.iter().enumerate() {
                let p = rp.add((splat_base + i) * FCHUNK);
                for k in 0..FCHUNK {
                    *p.add(k) = v;
                }
            }
            let z = rp.add(zero_ix * FCHUNK);
            for k in 0..FCHUNK {
                *z.add(k) = 0.0;
            }
        }
    }
    for run in &fs.runs {
        let mut done = 0usize;
        let len = run.len as usize;
        while done < len {
            let c = (len - done).min(FCHUNK);
            let at = run.out_off as usize + done;
            // Pre-load strided shifted inputs into their dedicated chunk
            // registers (a ghost run needs no load — reads resolve to 0.0).
            for (i, inp) in fs.inputs.iter().enumerate() {
                if inp.load_reg == u16::MAX {
                    continue;
                }
                let sx = inp.shifted_ix.expect("load_reg implies shifted");
                let o = run.in_off[sx as usize];
                if o == GHOST_OFF {
                    continue;
                }
                unsafe {
                    let dst = rp.add(inp.load_reg as usize * FCHUNK);
                    let base =
                        bases[i].offset(o as isize + done as isize * inp.elem_stride as isize);
                    for k in 0..c {
                        *dst.add(k) = *base.offset(k as isize * inp.elem_stride as isize);
                    }
                }
            }
            let msrc = |m: &MRef| -> MSrc {
                match m {
                    MRef::Reg(r) => MSrc::P(unsafe { rp.add(*r as usize * FCHUNK) as *const f64 }),
                    MRef::Scal(i) => MSrc::C(svals[*i as usize]),
                    MRef::In(i) => {
                        let inp = &fs.inputs[*i as usize];
                        match inp.shifted_ix {
                            None => MSrc::P(unsafe { bases[*i as usize].add(at) }),
                            Some(s) => {
                                let o = run.in_off[s as usize];
                                if o == GHOST_OFF {
                                    MSrc::C(0.0)
                                } else if inp.load_reg != u16::MAX {
                                    MSrc::P(unsafe {
                                        rp.add(inp.load_reg as usize * FCHUNK) as *const f64
                                    })
                                } else {
                                    MSrc::P(unsafe {
                                        bases[*i as usize].offset(o as isize + done as isize)
                                    })
                                }
                            }
                        }
                    }
                }
            };
            // All-pointer operand resolution for the Bin3 superop: scalar
            // operands point at their splat registers, ghost reads at the
            // zero register — same values, so same bits, with ONE loop shape
            // per (op1, op2, op3) instead of 2^4 operand-kind arms.
            let msrc_p = |m: &MRef| -> *const f64 {
                match msrc(m) {
                    MSrc::P(p) => p,
                    MSrc::C(v) => {
                        if v == 0.0 && v.is_sign_positive() {
                            unsafe { rp.add(zero_ix * FCHUNK) as *const f64 }
                        } else {
                            match m {
                                MRef::Scal(i) => unsafe {
                                    rp.add((splat_base + *i as usize) * FCHUNK) as *const f64
                                },
                                _ => unreachable!("non-scalar constant operand"),
                            }
                        }
                    }
                }
            };
            for op in &fs.micro {
                match op {
                    MicroOp::Bin { op, a, b, out } => {
                        let (a, b) = (msrc(a), msrc(b));
                        let dst = unsafe { rp.add(*out as usize * FCHUNK) };
                        // Monomorphized over the shared table — the same
                        // kernel bodies as the unfused `Instr::Bin` arm.
                        macro_rules! chunk {
                            ($f:expr) => {
                                unsafe { fch2(dst, c, a, b, $f) }
                            };
                        }
                        dispatch_bin_kernel!(op, chunk);
                    }
                    MicroOp::Un { op, a, out } => {
                        let a = msrc(a);
                        let dst = unsafe { rp.add(*out as usize * FCHUNK) };
                        macro_rules! chunk {
                            ($f:expr) => {
                                unsafe { fch1(dst, c, a, $f) }
                            };
                        }
                        dispatch_un_kernel!(op, chunk);
                    }
                    MicroOp::Neg { a, out } => {
                        let a = msrc(a);
                        unsafe { fch1(rp.add(*out as usize * FCHUNK), c, a, |x| -x) };
                    }
                    MicroOp::Select { cond, a, b, out } => {
                        let (cv, av, bv) = (msrc(cond), msrc(a), msrc(b));
                        unsafe { fch_sel(rp.add(*out as usize * FCHUNK), c, cv, av, bv) };
                    }
                    MicroOp::Mov { a, out } => {
                        let a = msrc(a);
                        unsafe { fch1(rp.add(*out as usize * FCHUNK), c, a, |x| x) };
                    }
                    MicroOp::Bin2 {
                        op1,
                        a,
                        b,
                        op2,
                        c: c3,
                        swap,
                        out,
                    } => {
                        let (av, bv, cv) = (msrc(a), msrc(b), msrc(c3));
                        let dst = unsafe { rp.add(*out as usize * FCHUNK) };
                        use BinCode::{Add, Div, Ge, Gt, Le, Lt, Max, Min, Mul, Sub};
                        // Monomorphized composition of the same two kernel
                        // bodies, applied in the same order (t = op1(a, b);
                        // out = swap ? op2(c, t) : op2(t, c)).
                        macro_rules! b2 {
                            ($f1:expr, $f2:expr) => {
                                if *swap {
                                    unsafe { fch3(dst, c, av, bv, cv, |x, y, z| $f2(z, $f1(x, y))) }
                                } else {
                                    unsafe { fch3(dst, c, av, bv, cv, |x, y, z| $f2($f1(x, y), z)) }
                                }
                            };
                        }
                        let add = |x: f64, y: f64| x + y;
                        let sub = |x: f64, y: f64| x - y;
                        let mul = |x: f64, y: f64| x * y;
                        let div = |x: f64, y: f64| x / y;
                        let min = |x: f64, y: f64| x.min(y);
                        let max = |x: f64, y: f64| x.max(y);
                        let gt = |x: f64, y: f64| (x > y) as i32 as f64;
                        let ge = |x: f64, y: f64| (x >= y) as i32 as f64;
                        let lt = |x: f64, y: f64| (x < y) as i32 as f64;
                        let le = |x: f64, y: f64| (x <= y) as i32 as f64;
                        match (op1, op2) {
                            (Add, Add) => b2!(add, add),
                            (Add, Sub) => b2!(add, sub),
                            (Add, Mul) => b2!(add, mul),
                            (Add, Div) => b2!(add, div),
                            (Sub, Add) => b2!(sub, add),
                            (Sub, Sub) => b2!(sub, sub),
                            (Sub, Mul) => b2!(sub, mul),
                            (Sub, Div) => b2!(sub, div),
                            (Mul, Add) => b2!(mul, add),
                            (Mul, Sub) => b2!(mul, sub),
                            (Mul, Mul) => b2!(mul, mul),
                            (Mul, Div) => b2!(mul, div),
                            (Div, Add) => b2!(div, add),
                            (Div, Sub) => b2!(div, sub),
                            (Div, Mul) => b2!(div, mul),
                            (Div, Div) => b2!(div, div),
                            // Step 4b extended pairs (`bin2_pair_ok`): the
                            // multiply-into-mask and min/max clamp idioms the
                            // adjacency histogram showed material.
                            (Mul, Gt) => b2!(mul, gt),
                            (Mul, Ge) => b2!(mul, ge),
                            (Mul, Lt) => b2!(mul, lt),
                            (Mul, Le) => b2!(mul, le),
                            (Min, Max) => b2!(min, max),
                            (Max, Min) => b2!(max, min),
                            (Mul, Min) => b2!(mul, min),
                            (Min, Mul) => b2!(min, mul),
                            (Mul, Max) => b2!(mul, max),
                            (Max, Mul) => b2!(max, mul),
                            other => unreachable!("Bin2 pair not monomorphized ({other:?})"),
                        }
                    }
                    MicroOp::Bin3 {
                        op1,
                        a,
                        b,
                        op2,
                        c: c3,
                        swap2,
                        op3,
                        d: d4,
                        swap3,
                        out,
                    } => {
                        let (pa, pb, pc, pd) = (msrc_p(a), msrc_p(b), msrc_p(c3), msrc_p(d4));
                        let dst = unsafe { rp.add(*out as usize * FCHUNK) };
                        use BinCode::{Add, Div, Mul, Sub};
                        // Monomorphized composition of the same three kernel
                        // bodies applied in order:
                        // t1 = op1(a, b); t2 = swap2 ? op2(c, t1) : op2(t1, c);
                        // out = swap3 ? op3(d, t2) : op3(t2, d).
                        macro_rules! b3 {
                            ($f1:expr, $f2:expr, $f3:expr) => {
                                match (*swap2, *swap3) {
                                    (false, false) => unsafe {
                                        fch4(dst, c, pa, pb, pc, pd, |x, y, z, w| {
                                            $f3($f2($f1(x, y), z), w)
                                        })
                                    },
                                    (true, false) => unsafe {
                                        fch4(dst, c, pa, pb, pc, pd, |x, y, z, w| {
                                            $f3($f2(z, $f1(x, y)), w)
                                        })
                                    },
                                    (false, true) => unsafe {
                                        fch4(dst, c, pa, pb, pc, pd, |x, y, z, w| {
                                            $f3(w, $f2($f1(x, y), z))
                                        })
                                    },
                                    (true, true) => unsafe {
                                        fch4(dst, c, pa, pb, pc, pd, |x, y, z, w| {
                                            $f3(w, $f2(z, $f1(x, y)))
                                        })
                                    },
                                }
                            };
                        }
                        let add = |x: f64, y: f64| x + y;
                        let sub = |x: f64, y: f64| x - y;
                        let mul = |x: f64, y: f64| x * y;
                        let div = |x: f64, y: f64| x / y;
                        macro_rules! b3_op12 {
                            ($f3:expr) => {
                                match (op1, op2) {
                                    (Add, Add) => b3!(add, add, $f3),
                                    (Add, Sub) => b3!(add, sub, $f3),
                                    (Add, Mul) => b3!(add, mul, $f3),
                                    (Add, Div) => b3!(add, div, $f3),
                                    (Sub, Add) => b3!(sub, add, $f3),
                                    (Sub, Sub) => b3!(sub, sub, $f3),
                                    (Sub, Mul) => b3!(sub, mul, $f3),
                                    (Sub, Div) => b3!(sub, div, $f3),
                                    (Mul, Add) => b3!(mul, add, $f3),
                                    (Mul, Sub) => b3!(mul, sub, $f3),
                                    (Mul, Mul) => b3!(mul, mul, $f3),
                                    (Mul, Div) => b3!(mul, div, $f3),
                                    (Div, Add) => b3!(div, add, $f3),
                                    (Div, Sub) => b3!(div, sub, $f3),
                                    (Div, Mul) => b3!(div, mul, $f3),
                                    (Div, Div) => b3!(div, div, $f3),
                                    other => {
                                        unreachable!("Bin3 restricted to + - * / ({other:?})")
                                    }
                                }
                            };
                        }
                        match op3 {
                            Add => b3_op12!(add),
                            Sub => b3_op12!(sub),
                            Mul => b3_op12!(mul),
                            Div => b3_op12!(div),
                            other => unreachable!("Bin3 restricted to + - * / ({other:?})"),
                        }
                    }
                }
            }
            for &(reg, optr) in outs {
                unsafe {
                    std::ptr::copy_nonoverlapping(
                        rp.add(reg as usize * FCHUNK) as *const f64,
                        optr.add(at),
                        c,
                    );
                }
            }
            done += c;
        }
    }
}

/// Baseline-codegen instantiation of the fused chunk loop.
#[inline(never)]
pub(super) unsafe fn exec_fused_runs_generic(
    fs: &FusedSpec,
    svals: &[f64],
    bases: &[*const f64],
    outs: &[(u16, *mut f64)],
    fregs: &mut [f64],
) {
    unsafe { exec_fused_runs(fs, svals, bases, outs, fregs) }
}

/// AVX2 clone: identical Rust source compiled under `avx2` (+`fma` is NOT
/// enabled — LLVM must not contract mul+add into fused multiply-add, which
/// would change bits). Reached only when `is_x86_feature_detected!` proved
/// support, so the `unsafe` target-feature contract holds.
#[cfg(target_arch = "x86_64")]
#[target_feature(enable = "avx2")]
pub(super) unsafe fn exec_fused_runs_avx2(
    fs: &FusedSpec,
    svals: &[f64],
    bases: &[*const f64],
    outs: &[(u16, *mut f64)],
    fregs: &mut [f64],
) {
    unsafe { exec_fused_runs(fs, svals, bases, outs, fregs) }
}

/// AVX-512 clone (f+vl+dq+bw, all runtime-checked). Note LLVM keeps its
/// preferred vector width at 256 bits for these targets unless told
/// otherwise, so this may codegen close to the AVX2 clone.
#[cfg(target_arch = "x86_64")]
#[target_feature(
    enable = "avx512f",
    enable = "avx512vl",
    enable = "avx512dq",
    enable = "avx512bw"
)]
pub(super) unsafe fn exec_fused_runs_avx512(
    fs: &FusedSpec,
    svals: &[f64],
    bases: &[*const f64],
    outs: &[(u16, *mut f64)],
    fregs: &mut [f64],
) {
    unsafe { exec_fused_runs(fs, svals, bases, outs, fregs) }
}

/// The SINGLE definition of micro-op scalar semantics: one element of one
/// [`MicroOp`], evaluated over a scalar register file. Both cold per-element
/// interpreters — the test-only reference executor (`refexec`) and the
/// `ESS_TAPE_FUSE_MODE=elem` measurement arm ([`exec_fused_elem`]) — dispatch
/// through this function, so they cannot drift from each other. The hot
/// chunked executor ([`exec_fused_runs`]) applies the SAME kernels in the
/// same per-element order through its monomorphized chunk loops (a structure
/// a scalar evaluator cannot back without disturbing it); the A/B tests and
/// `simd_clone_bit_identity` pin it bit-identical to this definition.
///
/// Semantics (see [`MicroOp`] for the full contract):
/// * `Bin`/`Un` apply [`binary_kernel_of`] / [`unary_kernel_of`] — the same
///   fn-pointer tables the unfused instructions dispatch through.
/// * `Neg` is `x → -x`, NOT `0 - x` (which differs on signed zero).
/// * `Bin2`/`Bin3` operand orientation: the fused intermediate always feeds
///   the NEXT kernel, and `swap*` records which SIDE it enters on —
///   `t = op1(a, b); out = swap ? op2(c, t) : op2(t, c)` (likewise `swap2`
///   then `swap3` for `Bin3`). The constituent kernels are applied strictly
///   in order — never contracted into a hardware FMA, which would change
///   bits.
/// * `get` resolves an [`MRef`] operand (register / broadcast scalar / array
///   input at the current element, including the [`GHOST_OFF`] `+0.0` read).
///   Operand reads are pure, so `Select` reading only the taken operand is
///   value-identical to the chunked executor's load-both blend.
#[inline(always)]
pub(in crate::simulate_array::tape) fn eval_micro_op(
    op: &MicroOp,
    regs: &mut [f64],
    get: impl Fn(&MRef, &[f64]) -> f64,
) {
    match op {
        MicroOp::Bin { op, a, b, out } => {
            regs[*out as usize] = binary_kernel_of(*op)(get(a, regs), get(b, regs));
        }
        MicroOp::Un { op, a, out } => {
            regs[*out as usize] = unary_kernel_of(*op)(get(a, regs));
        }
        MicroOp::Neg { a, out } => {
            regs[*out as usize] = -get(a, regs);
        }
        MicroOp::Select { cond, a, b, out } => {
            regs[*out as usize] = if get(cond, regs) != 0.0 {
                get(a, regs)
            } else {
                get(b, regs)
            };
        }
        MicroOp::Mov { a, out } => {
            regs[*out as usize] = get(a, regs);
        }
        MicroOp::Bin2 {
            op1,
            a,
            b,
            op2,
            c,
            swap,
            out,
        } => {
            let t = binary_kernel_of(*op1)(get(a, regs), get(b, regs));
            let cv = get(c, regs);
            regs[*out as usize] = if *swap {
                binary_kernel_of(*op2)(cv, t)
            } else {
                binary_kernel_of(*op2)(t, cv)
            };
        }
        MicroOp::Bin3 {
            op1,
            a,
            b,
            op2,
            c,
            swap2,
            op3,
            d,
            swap3,
            out,
        } => {
            let t1 = binary_kernel_of(*op1)(get(a, regs), get(b, regs));
            let cv = get(c, regs);
            let t2 = if *swap2 {
                binary_kernel_of(*op2)(cv, t1)
            } else {
                binary_kernel_of(*op2)(t1, cv)
            };
            let dv = get(d, regs);
            regs[*out as usize] = if *swap3 {
                binary_kernel_of(*op3)(dv, t2)
            } else {
                binary_kernel_of(*op3)(t2, dv)
            };
        }
    }
}

/// The per-element measurement arm (`ESS_TAPE_FUSE_MODE=elem`): one scalar
/// register file, micro-ops dispatched per element through [`eval_micro_op`]
/// (the single definition of micro-op scalar semantics). Bit-identical to
/// the chunked executor (same kernels, same order).
#[inline(never)]
unsafe fn exec_fused_elem(
    fs: &FusedSpec,
    svals: &[f64],
    bases: &[*const f64],
    outs: &[(u16, *mut f64)],
) {
    let mut regs: SmallVec<[f64; 32]> = SmallVec::from_elem(0.0f64, fs.n_regs as usize);
    for run in &fs.runs {
        for k in 0..run.len as usize {
            let at = run.out_off as usize + k;
            let get = |m: &MRef, regs: &[f64]| -> f64 {
                match m {
                    MRef::Reg(r) => regs[*r as usize],
                    MRef::Scal(i) => svals[*i as usize],
                    MRef::In(i) => {
                        let inp = &fs.inputs[*i as usize];
                        match inp.shifted_ix {
                            None => unsafe { *bases[*i as usize].add(at) },
                            Some(s) => {
                                let o = run.in_off[s as usize];
                                if o == GHOST_OFF {
                                    0.0
                                } else {
                                    unsafe {
                                        *bases[*i as usize].offset(
                                            o as isize + k as isize * inp.elem_stride as isize,
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            };
            for op in &fs.micro {
                eval_micro_op(op, &mut regs, get);
            }
            for &(reg, optr) in outs {
                unsafe { *optr.add(at) = regs[reg as usize] };
            }
        }
    }
}
