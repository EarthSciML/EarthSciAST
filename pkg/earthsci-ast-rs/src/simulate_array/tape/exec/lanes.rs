//! Lane-program execution ([`Instr::Lanes`]).
//!
//! The lanes are strip-mined into chunks of [`LCHUNK`]. Per chunk each input
//! is gathered from its lanes' sources into a chunk register, the
//! micro-program runs over the chunk through the same chunk kernels and
//! kernel dispatch the fused executor uses, and each write scatters its
//! chunk into `dy`. Every lane applies exactly the kernels its scalar
//! instructions applied, in their order; the lanes are independent and
//! write distinct `dy` positions, so chunking cannot change a bit.

use super::fused::{MSrc, dispatch_bin_kernel, dispatch_un_kernel, fch_sel, fch1, fch2};
use super::resolve::resolve_scalar;
use super::*;

/// Lanes per chunk: long enough to amortize each micro-op's dispatch, short
/// enough that a mechanism-sized program's registers stay cache-resident.
pub(super) const LCHUNK: usize = 256;

/// The per-executor buffers of the lane programs, sized for the largest
/// program so a call never allocates.
pub(super) struct LaneScratch {
    regs: Vec<f64>,
    svals: Vec<f64>,
}

impl LaneScratch {
    pub(super) fn for_program(prog: &TapeProgram) -> Self {
        let regs = prog
            .lanes
            .iter()
            .map(|ls| ls.n_regs as usize + ls.inputs.len())
            .max()
            .unwrap_or(0);
        let svals = prog
            .lanes
            .iter()
            .map(|ls| ls.scalars.len())
            .max()
            .unwrap_or(0);
        LaneScratch {
            regs: vec![0.0; regs * LCHUNK],
            svals: Vec::with_capacity(svals),
        }
    }
}

/// Execute one lane program.
#[allow(clippy::too_many_arguments)]
pub(super) unsafe fn exec_lanes(
    ls: &LaneSpec,
    env: &Env,
    slab_ptr: *mut f64,
    slot_off: &[usize],
    obs: &ArrMap,
    scratch: &mut LaneScratch,
    dy: &mut [f64],
    simd: SimdLevel,
) {
    let LaneScratch { regs, svals } = scratch;
    svals.clear();
    for op in &ls.scalars {
        svals.push(resolve_scalar(op, env, slab_ptr, slot_off, obs));
    }
    if ls.lanes == 1 && ls.inputs.is_empty() {
        exec_block(ls, svals, regs, slab_ptr, slot_off, dy);
        return;
    }
    let src = Sources {
        state: env.state,
        params: env.params,
        slab: slab_ptr,
        slot_off,
    };
    match simd {
        SimdLevel::Generic => unsafe { exec_lanes_generic(ls, &src, svals, regs, dy) },
        #[cfg(target_arch = "x86_64")]
        SimdLevel::Avx2 => unsafe { exec_lanes_avx2(ls, &src, svals, regs, dy) },
        #[cfg(target_arch = "x86_64")]
        SimdLevel::Avx512 => unsafe { exec_lanes_avx512(ls, &src, svals, regs, dy) },
    }
}

/// A one-lane program: the micro-ops one after another over scalar
/// registers, each through the same kernel definitions the chunk loops
/// expand (`dispatch_bin_kernel` / `dispatch_un_kernel`).
fn exec_block(
    ls: &LaneSpec,
    svals: &[f64],
    regs: &mut [f64],
    slab_ptr: *mut f64,
    slot_off: &[usize],
    dy: &mut [f64],
) {
    let regs = &mut regs[..ls.n_regs as usize];
    let get = |m: &MRef, regs: &[f64]| match m {
        MRef::Reg(r) => regs[*r as usize],
        MRef::Scal(i) => svals[*i as usize],
        MRef::In(_) => unreachable!("a one-lane block reads scalars only"),
    };
    for op in &ls.micro {
        match op {
            MicroOp::Bin { op, a, b, out } => {
                let (x, y) = (get(a, regs), get(b, regs));
                macro_rules! one {
                    ($f:expr) => {
                        regs[*out as usize] = ($f)(x, y)
                    };
                }
                dispatch_bin_kernel!(op, one);
            }
            MicroOp::Un { op, a, out } => {
                let x = get(a, regs);
                macro_rules! one {
                    ($f:expr) => {
                        regs[*out as usize] = ($f)(x)
                    };
                }
                dispatch_un_kernel!(op, one);
            }
            MicroOp::Neg { a, out } => regs[*out as usize] = -get(a, regs),
            MicroOp::Select { cond, a, b, out } => {
                let (c, x, y) = (get(cond, regs), get(a, regs), get(b, regs));
                regs[*out as usize] = if c != 0.0 { x } else { y };
            }
            MicroOp::Mov { a, out } => regs[*out as usize] = get(a, regs),
            MicroOp::Bin2 { .. } | MicroOp::Bin3 { .. } => {
                unreachable!("a lane program holds no superops")
            }
        }
    }
    for w in &ls.writes {
        let v = get(&w.src, regs);
        match &w.dst {
            LaneDst::Dy(pos) => dy[pos.at(0) as usize] = v,
            LaneDst::Slot(s) => unsafe { *slab_ptr.add(slot_off[*s as usize]) = v },
        }
    }
}

/// Where a lane input's entries point.
struct Sources<'a> {
    state: &'a [f64],
    params: &'a [f64],
    slab: *const f64,
    slot_off: &'a [usize],
}

impl Sources<'_> {
    /// Gather lanes `l0 .. l0 + c` of `inp` into `dst`.
    #[inline(always)]
    unsafe fn gather(&self, inp: &LaneTable, l0: usize, c: usize, dst: *mut f64) {
        let d = unsafe { std::slice::from_raw_parts_mut(dst, c) };
        match (inp.kind, &inp.ix) {
            // Evenly spaced lanes of a slice: one bounds check per chunk.
            (LaneKind::State | LaneKind::Param, LaneIx::Affine { base, step }) => {
                let v = if inp.kind == LaneKind::State {
                    self.state
                } else {
                    self.params
                };
                let (base, step) = (*base as usize, *step as usize);
                let first = base + l0 * step;
                if step == 1 {
                    d.copy_from_slice(&v[first..first + c]);
                } else {
                    let v = &v[first..first + (c - 1) * step + 1];
                    for (k, x) in d.iter_mut().enumerate() {
                        *x = unsafe { *v.get_unchecked(k * step) };
                    }
                }
            }
            (kind, ix) => {
                for (k, x) in d.iter_mut().enumerate() {
                    let i = ix.at(l0 + k) as usize;
                    *x = match kind {
                        LaneKind::State => self.state[i],
                        LaneKind::Param => self.params[i],
                        LaneKind::Slot => unsafe { *self.slab.add(self.slot_off[i]) },
                    };
                }
            }
        }
    }
}

/// Scatter `c` values (`val(k)` for lane `l0 + k`) to their `dy` positions.
#[inline(always)]
fn scatter(dy: &mut [f64], pos: &LaneIx, l0: usize, c: usize, val: impl Fn(usize) -> f64) {
    match pos {
        LaneIx::Affine { base, step } => {
            let (base, step) = (*base as usize, *step as usize);
            let first = base + l0 * step;
            let d = &mut dy[first..first + (c - 1) * step + 1];
            for k in 0..c {
                unsafe { *d.get_unchecked_mut(k * step) = val(k) };
            }
        }
        LaneIx::Table(t) => {
            for (k, &p) in t[l0..l0 + c].iter().enumerate() {
                dy[p as usize] = val(k);
            }
        }
    }
}

/// The chunk loop, monomorphized per SIMD level through the wrappers below.
#[inline(always)]
unsafe fn exec_lanes_chunks(
    ls: &LaneSpec,
    src: &Sources,
    svals: &[f64],
    regs: &mut [f64],
    dy: &mut [f64],
) {
    let rp = regs.as_mut_ptr();
    let n_regs = ls.n_regs as usize;
    let lanes = ls.lanes as usize;
    let reg = |r: usize| unsafe { rp.add(r * LCHUNK) };
    let mut l0 = 0usize;
    while l0 < lanes {
        let c = (lanes - l0).min(LCHUNK);
        for (i, inp) in ls.inputs.iter().enumerate() {
            unsafe { src.gather(inp, l0, c, reg(n_regs + i)) };
        }
        let msrc = |m: &MRef| -> MSrc {
            match m {
                MRef::Reg(r) => MSrc::P(reg(*r as usize)),
                MRef::In(i) => MSrc::P(reg(n_regs + *i as usize)),
                MRef::Scal(i) => MSrc::C(svals[*i as usize]),
            }
        };
        for op in &ls.micro {
            match op {
                MicroOp::Bin { op, a, b, out } => {
                    let (a, b) = (msrc(a), msrc(b));
                    let dst = reg(*out as usize);
                    macro_rules! chunk {
                        ($f:expr) => {
                            unsafe { fch2(dst, c, a, b, $f) }
                        };
                    }
                    dispatch_bin_kernel!(op, chunk);
                }
                MicroOp::Un { op, a, out } => {
                    let a = msrc(a);
                    let dst = reg(*out as usize);
                    macro_rules! chunk {
                        ($f:expr) => {
                            unsafe { fch1(dst, c, a, $f) }
                        };
                    }
                    dispatch_un_kernel!(op, chunk);
                }
                MicroOp::Neg { a, out } => unsafe { fch1(reg(*out as usize), c, msrc(a), |x| -x) },
                MicroOp::Select { cond, a, b, out } => unsafe {
                    fch_sel(reg(*out as usize), c, msrc(cond), msrc(a), msrc(b))
                },
                MicroOp::Mov { a, out } => unsafe { fch1(reg(*out as usize), c, msrc(a), |x| x) },
                MicroOp::Bin2 { .. } | MicroOp::Bin3 { .. } => {
                    unreachable!("a lane program holds no superops")
                }
            }
        }
        for w in &ls.writes {
            let LaneDst::Dy(pos) = &w.dst else {
                unreachable!("only a one-lane program writes a slot")
            };
            match msrc(&w.src) {
                MSrc::P(p) => scatter(dy, pos, l0, c, |k| unsafe { *p.add(k) }),
                MSrc::C(v) => scatter(dy, pos, l0, c, |_| v),
            }
        }
        l0 += c;
    }
}

#[inline(never)]
unsafe fn exec_lanes_generic(
    ls: &LaneSpec,
    src: &Sources,
    svals: &[f64],
    regs: &mut [f64],
    dy: &mut [f64],
) {
    unsafe { exec_lanes_chunks(ls, src, svals, regs, dy) }
}

/// AVX2 clone (no `fma`: a contracted multiply-add would change bits).
#[cfg(target_arch = "x86_64")]
#[target_feature(enable = "avx2")]
unsafe fn exec_lanes_avx2(
    ls: &LaneSpec,
    src: &Sources,
    svals: &[f64],
    regs: &mut [f64],
    dy: &mut [f64],
) {
    unsafe { exec_lanes_chunks(ls, src, svals, regs, dy) }
}

/// AVX-512 clone (f+vl+dq+bw, all runtime-checked).
#[cfg(target_arch = "x86_64")]
#[target_feature(
    enable = "avx512f",
    enable = "avx512vl",
    enable = "avx512dq",
    enable = "avx512bw"
)]
unsafe fn exec_lanes_avx512(
    ls: &LaneSpec,
    src: &Sources,
    svals: &[f64],
    regs: &mut [f64],
    dy: &mut [f64],
) {
    unsafe { exec_lanes_chunks(ls, src, svals, regs, dy) }
}
