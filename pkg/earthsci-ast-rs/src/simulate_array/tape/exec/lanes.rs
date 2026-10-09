//! Lane-program execution ([`Instr::Lanes`]).
//!
//! The lanes are strip-mined into chunks of [`LCHUNK`]. Per chunk each input
//! is gathered from its lanes' sources into a chunk register (a unit-step
//! state or parameter input is read where it lies), the micro-program runs
//! over the chunk through the same chunk kernels and kernel dispatch the
//! fused executor uses, and each write scatters its chunk into `dy` (or, for
//! a unit-step write, the micro-op computing it stores there directly).
//! Every lane applies exactly the kernels its scalar instructions applied,
//! in their order; the lanes are independent and write distinct `dy`
//! positions, so chunking cannot change a bit.
//!
//! In `f64` a program of at least [`STRIP`] lanes runs in its folded form
//! (`lane_fold.rs`) instead, strip by strip: the whole program over
//! [`STRIP`] lanes at a time, its registers one strip long, so they stay in
//! the first-level cache whatever the program's size, and its inputs and
//! derivative runs are each read or written once per strip, in order.

use super::fused::{MSrc, dispatch_bin_kernel, dispatch_un_kernel, fch_sel, fch1, fch2};
use super::lane_fold::{
    B_DY, B_PARAM, B_REG, B_SPLAT, B_STATE, LOp, LaneCode, N_BASES, OTHER, SSTRIDE, STRIP,
    strip_fold,
};
use super::resolve::resolve_scalar;
use super::*;
use crate::simulate_array::tape::fuse::micro_out;

/// Lanes per chunk: long enough to amortize each micro-op's dispatch, short
/// enough that a mechanism-sized program's registers stay cache-resident.
pub(super) const LCHUNK: usize = 256;

/// The per-executor buffers of the lane programs, sized for the largest
/// program so a call never allocates.
pub(super) struct LaneScratch {
    /// Per lane program, its folded form (`None` for a one-lane block or a
    /// program too large to decode).
    codes: Vec<Option<LaneCode>>,
    /// The calling thread's register file.
    own: LaneWorker,
    svals: Vec<f64>,
    /// Per folded program, each scalar operand repeated over a strip, and
    /// the values they were filled with (refilled only when one changes).
    splats: Vec<(Vec<f64>, Vec<f64>)>,
    /// The workers a split lane program runs on (native targets only),
    /// grown the first time a call splits wider.
    #[cfg(not(target_arch = "wasm32"))]
    workers: Vec<LaneWorker>,
}

/// One thread's register file for a lane program's chunks or strips.
struct LaneWorker {
    regs: Vec<f64>,
}

impl LaneScratch {
    pub(super) fn for_program(prog: &TapeProgram) -> Self {
        let codes: Vec<Option<LaneCode>> = prog
            .lanes
            .iter()
            .map(|ls| {
                (ls.lanes > 1 || !ls.inputs.is_empty())
                    .then(|| super::lane_fold::decode(ls))
                    .flatten()
            })
            .collect();
        let regs = prog
            .lanes
            .iter()
            .zip(&codes)
            .map(|(ls, c)| {
                let chunked = (ls.n_regs as usize + ls.inputs.len()) * LCHUNK;
                chunked.max(c.as_ref().map_or(0, |c| c.strips.reg_elems))
            })
            .max()
            .unwrap_or(0);
        let svals = prog
            .lanes
            .iter()
            .map(|ls| ls.scalars.len())
            .max()
            .unwrap_or(0);
        let splats = prog
            .lanes
            .iter()
            .zip(&codes)
            .map(|(ls, c)| match c {
                Some(_) => (
                    vec![0.0; ls.scalars.len() * STRIP],
                    Vec::with_capacity(ls.scalars.len()),
                ),
                None => (Vec::new(), Vec::new()),
            })
            .collect();
        LaneScratch {
            codes,
            own: LaneWorker {
                regs: vec![0.0; regs],
            },
            svals: Vec::with_capacity(svals),
            splats,
            #[cfg(not(target_arch = "wasm32"))]
            workers: Vec::new(),
        }
    }
}

/// Execute one lane program; under call split width `ways` (see `par`) its
/// lanes are divided between workers, each lane whole on one of them.
#[allow(clippy::too_many_arguments)]
pub(super) unsafe fn exec_lanes(
    spec: usize,
    ls: &LaneSpec,
    env: &Env,
    slab_ptr: *mut f64,
    slot_off: &[usize],
    obs: &ArrMap,
    scratch: &mut LaneScratch,
    dy: &mut [f64],
    simd: SimdLevel,
    ways: usize,
) {
    #[cfg(target_arch = "wasm32")]
    let _ = ways;
    let LaneScratch {
        codes,
        own,
        svals,
        splats,
        #[cfg(not(target_arch = "wasm32"))]
        workers,
    } = scratch;
    svals.clear();
    for op in &ls.scalars {
        svals.push(resolve_scalar(op, env, slab_ptr, slot_off, obs));
    }
    if ls.lanes == 1 && ls.inputs.is_empty() {
        exec_block(ls, svals, &mut own.regs, slab_ptr, slot_off, dy);
        return;
    }
    // The folds are the `f64` kernels; Float32 runs the micro-ops.
    let code = codes[spec].as_ref().filter(|_| !crate::precision::is_f32());
    let (splat, filled) = &mut splats[spec];
    // Compared by bits: a scalar going from 0.0 to -0.0 must be refilled.
    let same = filled.len() == svals.len()
        && filled
            .iter()
            .zip(svals.iter())
            .all(|(a, b)| a.to_bits() == b.to_bits());
    if code.is_some() && !same {
        filled.clear();
        filled.extend_from_slice(svals);
        for (strip, &v) in splat.chunks_exact_mut(STRIP).zip(svals.iter()) {
            strip.fill(v);
        }
    }
    let prog = Prog {
        ls,
        code,
        svals,
        splat,
    };
    let src = Sources {
        state: env.state,
        params: env.params,
        slab: slab_ptr,
        slot_off,
    };
    let out = Out {
        ptr: dy.as_mut_ptr(),
        len: dy.len(),
    };
    let lanes = ls.lanes as usize;
    #[cfg(not(target_arch = "wasm32"))]
    {
        let ways = super::par::lane_ways(lanes, super::par::lane_cost(ls), ways);
        if ways > 1 {
            while workers.len() < ways {
                workers.push(LaneWorker {
                    regs: super::par::padded(own.regs.len()),
                });
            }
            let sh = SplitLanes {
                prog: &prog,
                src: &src,
                out,
                workers: workers.as_mut_ptr(),
                simd,
                precision: crate::precision::active(),
            };
            super::pool::run(ways, &move |w| {
                let sh = &sh;
                let (lo, hi) = (cut(lanes, w, ways), cut(lanes, w + 1, ways));
                if lo >= hi {
                    return;
                }
                // The caller's precision is thread-local; carry it over.
                let _p = crate::precision::enter(sh.precision);
                // SAFETY: share `w` runs once per dispatch, so each worker's
                // buffers have one user; lanes write distinct `dy` positions.
                let wk = unsafe { &mut *sh.workers.add(w) };
                unsafe { run_lanes(sh.simd, sh.prog, sh.src, wk, sh.out, lo, hi) };
            });
            return;
        }
    }
    unsafe { run_lanes(simd, &prog, &src, own, out, 0, lanes) }
}

/// Where share `w` of `ways` starts: on the nearest multiple of [`STRIP`] lanes (so
/// each share's folds run whole strips and two shares' unit-step `dy` runs
/// seldom meet inside a cache line), the last share ending at `lanes`.
#[cfg(not(target_arch = "wasm32"))]
fn cut(lanes: usize, w: usize, ways: usize) -> usize {
    if w >= ways {
        return lanes;
    }
    ((lanes * w / ways + STRIP / 2) / STRIP * STRIP).min(lanes)
}

/// What every chunk of one lane program call reads.
struct Prog<'a> {
    ls: &'a LaneSpec,
    code: Option<&'a LaneCode>,
    svals: &'a [f64],
    splat: &'a [f64],
}

/// The derivative a lane program scatters into.
#[derive(Clone, Copy)]
struct Out {
    ptr: *mut f64,
    len: usize,
}

/// One split lane program, shared read-only by its workers.
#[cfg(not(target_arch = "wasm32"))]
struct SplitLanes<'a> {
    prog: &'a Prog<'a>,
    src: &'a Sources<'a>,
    out: Out,
    workers: *mut LaneWorker,
    simd: SimdLevel,
    precision: crate::precision::Precision,
}

// SAFETY: workers read the sources and the slab, and write only the `dy`
// positions of their own lanes and their own buffers.
#[cfg(not(target_arch = "wasm32"))]
unsafe impl Sync for SplitLanes<'_> {}

/// Lanes `[lo, hi)` through the SIMD clone `simd`.
#[allow(clippy::too_many_arguments)]
#[inline(always)]
unsafe fn run_lanes(
    simd: SimdLevel,
    prog: &Prog,
    src: &Sources,
    wk: &mut LaneWorker,
    out: Out,
    lo: usize,
    hi: usize,
) {
    match simd {
        SimdLevel::Generic => unsafe { exec_lanes_generic(prog, src, wk, out, lo, hi) },
        #[cfg(target_arch = "x86_64")]
        SimdLevel::Avx2 => unsafe { exec_lanes_avx2(prog, src, wk, out, lo, hi) },
        #[cfg(target_arch = "x86_64")]
        SimdLevel::Avx512 => unsafe { exec_lanes_avx512(prog, src, wk, out, lo, hi) },
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
            MicroOp::Bin2 { .. } | MicroOp::Bin3 { .. } | MicroOp::Scan { .. } => {
                unreachable!("a lane program holds no superops or scans")
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
    /// Where lanes `l0 ..` of `inp` already lie contiguously (a unit-step
    /// state or parameter input), so the chunk reads them in place; checks
    /// that its `c` lanes are in bounds.
    #[inline(always)]
    fn in_place(&self, inp: &LaneTable, l0: usize, c: usize) -> Option<*const f64> {
        let (LaneKind::State | LaneKind::Param, LaneIx::Affine { base, step: 1 }) =
            (inp.kind, &inp.ix)
        else {
            return None;
        };
        let v = if inp.kind == LaneKind::State {
            self.state
        } else {
            self.params
        };
        Some(v[*base as usize + l0..*base as usize + l0 + c].as_ptr())
    }

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
fn scatter(dy: Out, pos: &LaneIx, l0: usize, c: usize, val: impl Fn(usize) -> f64) {
    match pos {
        LaneIx::Affine { base, step } => {
            let (base, step) = (*base as usize, *step as usize);
            let first = base + l0 * step;
            assert!(first + (c - 1) * step < dy.len, "lane write out of dy");
            for k in 0..c {
                unsafe { *dy.ptr.add(first + k * step) = val(k) };
            }
        }
        LaneIx::Table(t) => {
            for (k, &p) in t[l0..l0 + c].iter().enumerate() {
                assert!((p as usize) < dy.len, "lane write out of dy");
                unsafe { *dy.ptr.add(p as usize) = val(k) };
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
    dy: Out,
    lo: usize,
    hi: usize,
) {
    let rp = regs.as_mut_ptr();
    let n_regs = ls.n_regs as usize;
    let reg = |r: usize| unsafe { rp.add(r * LCHUNK) };
    let mut l0 = lo;
    while l0 < hi {
        let c = (hi - l0).min(LCHUNK);
        for (i, inp) in ls.inputs.iter().enumerate() {
            if src.in_place(inp, l0, c).is_none() {
                unsafe { src.gather(inp, l0, c, reg(n_regs + i)) };
            }
        }
        let msrc = |m: &MRef| -> MSrc {
            match m {
                MRef::Reg(r) => MSrc::P(reg(*r as usize)),
                MRef::In(i) => {
                    let inp = &ls.inputs[*i as usize];
                    MSrc::P(
                        src.in_place(inp, l0, c)
                            .unwrap_or_else(|| reg(n_regs + *i as usize)),
                    )
                }
                MRef::Scal(i) => MSrc::C(svals[*i as usize]),
            }
        };
        // Where micro-op `mi` writes: its register, or the `dy` run of the
        // write it feeds directly (`LaneSpec::direct`).
        let dst_of = |mi: usize, out: GroupIx| -> *mut f64 {
            for &(m, k) in &ls.direct {
                if m as usize == mi {
                    let LaneDst::Dy(LaneIx::Affine { base, .. }) = &ls.writes[k as usize].dst
                    else {
                        unreachable!("a direct write is a unit-step dy run")
                    };
                    let first = *base as usize + l0;
                    assert!(first + c <= dy.len, "lane write out of dy");
                    return unsafe { dy.ptr.add(first) };
                }
            }
            reg(out as usize)
        };
        for (mi, op) in ls.micro.iter().enumerate() {
            unsafe { micro_chunk(op, &msrc, dst_of(mi, micro_out(op)), c) };
        }
        for (k, w) in ls.writes.iter().enumerate() {
            if ls.direct.iter().any(|&(_, d)| d as usize == k) {
                continue;
            }
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

/// One micro-op over a chunk of `c` lanes into `dst`.
#[inline(always)]
unsafe fn micro_chunk(op: &MicroOp, msrc: &impl Fn(&MRef) -> MSrc, dst: *mut f64, c: usize) {
    match op {
        MicroOp::Bin { op, a, b, .. } => {
            let (a, b) = (msrc(a), msrc(b));
            macro_rules! chunk {
                ($f:expr) => {
                    unsafe { fch2(dst, c, a, b, $f) }
                };
            }
            dispatch_bin_kernel!(op, chunk);
        }
        MicroOp::Un { op, a, .. } => {
            let a = msrc(a);
            macro_rules! chunk {
                ($f:expr) => {
                    unsafe { fch1(dst, c, a, $f) }
                };
            }
            dispatch_un_kernel!(op, chunk);
        }
        MicroOp::Neg { a, .. } => unsafe { fch1(dst, c, msrc(a), |x| -x) },
        MicroOp::Select { cond, a, b, .. } => unsafe {
            fch_sel(dst, c, msrc(cond), msrc(a), msrc(b))
        },
        MicroOp::Mov { a, .. } => unsafe { fch1(dst, c, msrc(a), |x| x) },
        MicroOp::Bin2 { .. } | MicroOp::Bin3 { .. } | MicroOp::Scan { .. } => {
            unreachable!("a lane program holds no superops or scans")
        }
    }
}

/// The strip loop of a folded lane program (see `lane_fold.rs` and the
/// module docs) over lanes `[lo, hi)`. The last strip ends at `hi`,
/// overlapping the one before it when the lanes are not a whole number of
/// strips: a lane computed twice gets the same bits both times, and it is
/// a lane of this call's own range. Fewer lanes than a strip run through
/// the chunk loop.
#[inline(always)]
unsafe fn exec_folded_strips(
    prog: &Prog,
    code: &LaneCode,
    src: &Sources,
    wk: &mut LaneWorker,
    dy: Out,
    lo: usize,
    hi: usize,
) {
    let ls = prog.ls;
    let len = hi - lo;
    if len < STRIP {
        unsafe { exec_lanes_chunks(ls, src, prog.svals, &mut wk.regs, dy, lo, hi) };
        return;
    }
    let st = &code.strips;
    // Every strip the loop reads or stores lies within lanes `[0, lanes)`
    // of its run, and each run within its vector.
    let lens = [src.state.len(), src.params.len(), 0, 0, dy.len];
    for b in [B_STATE, B_PARAM, B_DY] {
        assert!(st.ends[b] <= lens[b], "a lane run leaves its vector");
    }
    assert!(hi <= ls.lanes as usize && wk.regs.len() >= st.reg_elems);
    let mut bases = [std::ptr::null_mut::<f64>(); N_BASES];
    bases[B_STATE] = src.state.as_ptr().wrapping_add(lo) as *mut f64;
    bases[B_PARAM] = src.params.as_ptr().wrapping_add(lo) as *mut f64;
    bases[B_REG] = wk.regs.as_mut_ptr();
    bases[B_SPLAT] = prog.splat.as_ptr() as *mut f64;
    bases[B_DY] = dy.ptr.wrapping_add(lo);
    let b = &bases;
    let mut off = 0;
    loop {
        for &i in &st.gathered {
            let dst = st.inputs[i as usize].ptr(b, off) as *mut f64;
            unsafe { src.gather(&ls.inputs[i as usize], lo + off, STRIP, dst) };
        }
        let msrc = |m: &MRef| -> MSrc {
            match m {
                MRef::Reg(r) => MSrc::P(b[B_REG].wrapping_add(*r as usize * SSTRIDE)),
                MRef::In(i) => MSrc::P(st.inputs[*i as usize].ptr(b, off)),
                MRef::Scal(i) => MSrc::C(prog.svals[*i as usize]),
            }
        };
        for so in &st.sops {
            if so.kind == OTHER {
                let LOp::Other(m) = &code.ops[so.n as usize] else {
                    unreachable!("an OTHER entry is a micro-op")
                };
                unsafe { micro_chunk(m, &msrc, so.dst(b, off), STRIP) };
            } else {
                unsafe { strip_fold(so, &st.tptr, b, off, so.dst(b, off)) };
            }
        }
        for (w, src) in ls.writes.iter().zip(&code.writes) {
            let Some(src) = src else { continue };
            let LaneDst::Dy(pos) = &w.dst else {
                unreachable!("only a one-lane program writes a slot")
            };
            match msrc(src) {
                MSrc::P(p) => scatter(dy, pos, lo + off, STRIP, |k| unsafe { *p.add(k) }),
                MSrc::C(v) => scatter(dy, pos, lo + off, STRIP, |_| v),
            }
        }
        if off + STRIP == len {
            break;
        }
        off = (off + STRIP).min(len - STRIP);
    }
}

#[inline(never)]
unsafe fn exec_lanes_generic(
    prog: &Prog,
    src: &Sources,
    wk: &mut LaneWorker,
    dy: Out,
    lo: usize,
    hi: usize,
) {
    unsafe {
        match prog.code {
            Some(code) => exec_folded_strips(prog, code, src, wk, dy, lo, hi),
            None => exec_lanes_chunks(prog.ls, src, prog.svals, &mut wk.regs, dy, lo, hi),
        }
    }
}

/// AVX2 clone (no `fma`: a contracted multiply-add would change bits).
#[cfg(target_arch = "x86_64")]
#[target_feature(enable = "avx2")]
unsafe fn exec_lanes_avx2(
    prog: &Prog,
    src: &Sources,
    wk: &mut LaneWorker,
    dy: Out,
    lo: usize,
    hi: usize,
) {
    unsafe {
        match prog.code {
            Some(code) => exec_folded_strips(prog, code, src, wk, dy, lo, hi),
            None => exec_lanes_chunks(prog.ls, src, prog.svals, &mut wk.regs, dy, lo, hi),
        }
    }
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
    prog: &Prog,
    src: &Sources,
    wk: &mut LaneWorker,
    dy: Out,
    lo: usize,
    hi: usize,
) {
    unsafe {
        match prog.code {
            Some(code) => exec_folded_strips(prog, code, src, wk, dy, lo, hi),
            None => exec_lanes_chunks(prog.ls, src, prog.svals, &mut wk.regs, dy, lo, hi),
        }
    }
}
