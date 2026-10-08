//! The strided array kernels the unfused instructions execute: elementwise
//! maps, the `vec_select` pick, block copy, fill, and the precompiled
//! gather plans.
//!
//! Nothing here takes an `Env` or reads the program — the boundary keeps
//! instruction decoding (`interp`) and operand resolution (`resolve`) out
//! of the innermost loops, so a kernel body is exactly its arithmetic.

use super::resolve::{Rv, SrcView, rm_strides};
use super::*;

// ---------------------------------------------------------------------------
// Strided kernels. All pointers derive from live borrows held by the caller;
// shapes/strides come from the validated program, with the load-bearing
// invariants (equal boxes, in-bounds storages) established at lowering time
// and re-checked here as debug assertions (plus hard asserts on the runtime-
// shaped observed inputs).
// ---------------------------------------------------------------------------

/// `true` when `strides` is exactly the row-major layout of `shape`
/// (singleton axes are stride-agnostic).
fn is_contig(strides: &[i64], shape: &[usize]) -> bool {
    let mut acc = 1i64;
    for d in (0..shape.len()).rev() {
        if shape[d] != 1 && strides[d] != acc {
            return false;
        }
        acc *= shape[d] as i64;
    }
    true
}

fn total(shape: &[usize]) -> usize {
    shape.iter().product::<usize>().max(1)
}

/// `dst[k] = f(a[k])` — dst contiguous row-major over `shape`.
#[inline(never)]
pub(super) unsafe fn ew1(dst: *mut f64, shape: &[usize], a: &Rv, f: impl Fn(f64) -> f64 + Copy) {
    let za: f64;
    let zero;
    let (ap, astr): (*const f64, &[i64]) = match a {
        Rv::S(v) => {
            za = *v;
            zero = DimI::from_elem(0, shape.len());
            (&za as *const f64, &zero[..])
        }
        Rv::V { ptr, strides } => (*ptr, &strides[..]),
    };
    let n = total(shape);
    // Slab/state/observed buffers either coincide EXACTLY (an alias-safe
    // in-place reuse at the same storage offset) or are disjoint, so the
    // contiguous fast paths can be expressed through slices — which is what
    // lets LLVM prove no partial aliasing and vectorize the loops.
    unsafe {
        if is_contig(astr, shape) {
            let d = std::slice::from_raw_parts_mut(dst, n);
            if std::ptr::eq(ap, dst as *const f64) {
                for x in d.iter_mut() {
                    *x = f(*x);
                }
            } else {
                let a = std::slice::from_raw_parts(ap, n);
                for (x, &v) in d.iter_mut().zip(a) {
                    *x = f(v);
                }
            }
        } else if astr.iter().all(|&s| s == 0) {
            let v = f(*ap);
            let d = std::slice::from_raw_parts_mut(dst, n);
            for x in d.iter_mut() {
                *x = v;
            }
        } else {
            zip_loop2(dst, shape, ap, astr, ap, astr, |x, _| f(x));
        }
    }
}

/// `dst[k] = f(a[k], b[k])` — dst contiguous row-major over `shape`.
#[inline(never)]
pub(super) unsafe fn ew2(
    dst: *mut f64,
    shape: &[usize],
    a: &Rv,
    b: &Rv,
    f: impl Fn(f64, f64) -> f64 + Copy,
) {
    let za: f64;
    let zb: f64;
    let zeroa;
    let zerob;
    let (ap, astr): (*const f64, &[i64]) = match a {
        Rv::S(v) => {
            za = *v;
            zeroa = DimI::from_elem(0, shape.len());
            (&za as *const f64, &zeroa[..])
        }
        Rv::V { ptr, strides } => (*ptr, &strides[..]),
    };
    let (bp, bstr): (*const f64, &[i64]) = match b {
        Rv::S(v) => {
            zb = *v;
            zerob = DimI::from_elem(0, shape.len());
            (&zb as *const f64, &zerob[..])
        }
        Rv::V { ptr, strides } => (*ptr, &strides[..]),
    };
    let n = total(shape);
    let ac = is_contig(astr, shape);
    let bc = is_contig(bstr, shape);
    let az = astr.iter().all(|&s| s == 0);
    let bz = bstr.iter().all(|&s| s == 0);
    // See `ew1`: contiguous operands either coincide exactly with `dst` or
    // are disjoint from it, so slice-based loops are sound and vectorizable.
    unsafe {
        if ac && bc {
            let d = std::slice::from_raw_parts_mut(dst, n);
            let a_al = std::ptr::eq(ap, dst as *const f64);
            let b_al = std::ptr::eq(bp, dst as *const f64);
            match (a_al, b_al) {
                (true, true) => {
                    for x in d.iter_mut() {
                        *x = f(*x, *x);
                    }
                }
                (true, false) => {
                    let b = std::slice::from_raw_parts(bp, n);
                    for (x, &y) in d.iter_mut().zip(b) {
                        *x = f(*x, y);
                    }
                }
                (false, true) => {
                    let a = std::slice::from_raw_parts(ap, n);
                    for (x, &v) in d.iter_mut().zip(a) {
                        *x = f(v, *x);
                    }
                }
                (false, false) => {
                    let a = std::slice::from_raw_parts(ap, n);
                    let b = std::slice::from_raw_parts(bp, n);
                    for k in 0..n {
                        *d.get_unchecked_mut(k) = f(*a.get_unchecked(k), *b.get_unchecked(k));
                    }
                }
            }
        } else if ac && bz {
            let y = *bp;
            let d = std::slice::from_raw_parts_mut(dst, n);
            if std::ptr::eq(ap, dst as *const f64) {
                for x in d.iter_mut() {
                    *x = f(*x, y);
                }
            } else {
                let a = std::slice::from_raw_parts(ap, n);
                for (x, &v) in d.iter_mut().zip(a) {
                    *x = f(v, y);
                }
            }
        } else if az && bc {
            let x0 = *ap;
            let d = std::slice::from_raw_parts_mut(dst, n);
            if std::ptr::eq(bp, dst as *const f64) {
                for x in d.iter_mut() {
                    *x = f(x0, *x);
                }
            } else {
                let b = std::slice::from_raw_parts(bp, n);
                for (x, &y) in d.iter_mut().zip(b) {
                    *x = f(x0, y);
                }
            }
        } else {
            zip_loop2(dst, shape, ap, astr, bp, bstr, f);
        }
    }
}

/// General two-source odometer loop; dst contiguous row-major over `shape`.
unsafe fn zip_loop2(
    dst: *mut f64,
    shape: &[usize],
    a: *const f64,
    astr: &[i64],
    b: *const f64,
    bstr: &[i64],
    f: impl Fn(f64, f64) -> f64,
) {
    let n = shape.len();
    unsafe {
        if n == 0 {
            *dst = f(*a, *b);
            return;
        }
        let inner = shape[n - 1];
        let (ai, bi) = (astr[n - 1], bstr[n - 1]);
        let tot = total(shape);
        if tot == 0 || inner == 0 {
            return;
        }
        let outer = tot / inner;
        let mut idx = DimU::from_elem(0, n);
        let (mut aoff, mut boff) = (0i64, 0i64);
        let mut dp = dst;
        for _ in 0..outer {
            let mut ap = a.offset(aoff as isize);
            let mut bp = b.offset(boff as isize);
            for k in 0..inner {
                *dp.add(k) = f(*ap, *bp);
                ap = ap.offset(ai as isize);
                bp = bp.offset(bi as isize);
            }
            dp = dp.add(inner);
            let mut d = n - 1;
            while d > 0 {
                d -= 1;
                idx[d] += 1;
                aoff += astr[d];
                boff += bstr[d];
                if idx[d] < shape[d] {
                    break;
                }
                aoff -= astr[d] * shape[d] as i64;
                boff -= bstr[d] * shape[d] as i64;
                idx[d] = 0;
            }
        }
    }
}

/// `dst[k] = cond[k] != 0 ? a[k] : b[k]` — the `vec_select` kernel.
#[inline(never)]
pub(super) unsafe fn ew_select(dst: *mut f64, shape: &[usize], cond: &Rv, a: &Rv, b: &Rv) {
    // A scalar condition is the filter-gate broadcast: whole-array pick.
    if let Rv::S(c) = cond {
        let pick = if *c != 0.0 { a } else { b };
        unsafe { ew1(dst, shape, pick, |x| x) };
        return;
    }
    let za: f64;
    let zb: f64;
    let zeroa;
    let zerob;
    let (cp, cstr): (*const f64, &[i64]) = match cond {
        Rv::V { ptr, strides } => (*ptr, &strides[..]),
        Rv::S(_) => unreachable!(),
    };
    let (ap, astr): (*const f64, &[i64]) = match a {
        Rv::S(v) => {
            za = *v;
            zeroa = DimI::from_elem(0, shape.len());
            (&za as *const f64, &zeroa[..])
        }
        Rv::V { ptr, strides } => (*ptr, &strides[..]),
    };
    let (bp, bstr): (*const f64, &[i64]) = match b {
        Rv::S(v) => {
            zb = *v;
            zerob = DimI::from_elem(0, shape.len());
            (&zb as *const f64, &zerob[..])
        }
        Rv::V { ptr, strides } => (*ptr, &strides[..]),
    };
    let n = shape.len();
    // Contiguous fast path (see `ew1`/`ew2` on why slices + exact-alias
    // branches are sound): the mask select is the hot limiter idiom, so it
    // deserves a vectorizable loop. Exact aliasing of `dst` with any operand
    // is handled by reading through `dst` itself.
    let tot = total(shape);
    if is_contig(cstr, shape) && is_contig(astr, shape) && is_contig(bstr, shape) {
        unsafe {
            let d = std::slice::from_raw_parts_mut(dst, tot);
            let dc = dst as *const f64;
            let anyal = std::ptr::eq(cp, dc) || std::ptr::eq(ap, dc) || std::ptr::eq(bp, dc);
            if anyal {
                for k in 0..tot {
                    let c = *cp.add(k);
                    let v = if c != 0.0 { *ap.add(k) } else { *bp.add(k) };
                    *d.get_unchecked_mut(k) = v;
                }
            } else {
                let c = std::slice::from_raw_parts(cp, tot);
                let a = std::slice::from_raw_parts(ap, tot);
                let b = std::slice::from_raw_parts(bp, tot);
                for k in 0..tot {
                    *d.get_unchecked_mut(k) = if *c.get_unchecked(k) != 0.0 {
                        *a.get_unchecked(k)
                    } else {
                        *b.get_unchecked(k)
                    };
                }
            }
        }
        return;
    }
    unsafe {
        if n == 0 {
            *dst = if *cp != 0.0 { *ap } else { *bp };
            return;
        }
        let inner = shape[n - 1];
        if tot == 0 || inner == 0 {
            return;
        }
        let (ci, ai, bi) = (cstr[n - 1], astr[n - 1], bstr[n - 1]);
        let outer = tot / inner;
        let mut idx = DimU::from_elem(0, n);
        let (mut coff, mut aoff, mut boff) = (0i64, 0i64, 0i64);
        let mut dp = dst;
        for _ in 0..outer {
            let mut cpp = cp.offset(coff as isize);
            let mut app = ap.offset(aoff as isize);
            let mut bpp = bp.offset(boff as isize);
            for k in 0..inner {
                *dp.add(k) = if *cpp != 0.0 { *app } else { *bpp };
                cpp = cpp.offset(ci as isize);
                app = app.offset(ai as isize);
                bpp = bpp.offset(bi as isize);
            }
            dp = dp.add(inner);
            let mut d = n - 1;
            while d > 0 {
                d -= 1;
                idx[d] += 1;
                coff += cstr[d];
                aoff += astr[d];
                boff += bstr[d];
                if idx[d] < shape[d] {
                    break;
                }
                coff -= cstr[d] * shape[d] as i64;
                aoff -= astr[d] * shape[d] as i64;
                boff -= bstr[d] * shape[d] as i64;
                idx[d] = 0;
            }
        }
    }
}

/// The row length from which a per-row `memmove`/`memset` call beats the
/// inline element loop; shorter rows pay the call more than they save.
const ROW_CALL_MIN: usize = 64;

/// Strided-to-strided block copy (pure data movement).
pub(super) unsafe fn copy_strided(
    dst: *mut f64,
    dstr: &[i64],
    src: *const f64,
    sstr: &[i64],
    shape: &[usize],
) {
    let n = shape.len();
    unsafe {
        if n == 0 {
            *dst = *src;
            return;
        }
        let tot = total(shape);
        if tot == 0 {
            return;
        }
        if is_contig(dstr, shape) && is_contig(sstr, shape) {
            if !std::ptr::eq(dst as *const f64, src) {
                std::ptr::copy_nonoverlapping(src, dst, tot);
            }
            return;
        }
        // Fold trailing axes that are contiguous on BOTH sides into the
        // innermost one, so a sub-box of whole rows copies in long runs.
        let (di, si) = (dstr[n - 1], sstr[n - 1]);
        let mut n = n;
        let mut inner = shape[n - 1];
        while n > 1
            && dstr[n - 2] == dstr[n - 1] * shape[n - 1] as i64
            && sstr[n - 2] == sstr[n - 1] * shape[n - 1] as i64
        {
            n -= 1;
            inner *= shape[n - 1];
        }
        if inner == 0 {
            return;
        }
        let outer = tot / inner;
        let mut idx = DimU::from_elem(0, n);
        let (mut doff, mut soff) = (0i64, 0i64);
        for _ in 0..outer {
            let mut dp = dst.offset(doff as isize);
            let mut sp = src.offset(soff as isize);
            if di == 1 && si == 1 && inner >= ROW_CALL_MIN {
                std::ptr::copy(sp, dp, inner);
            } else {
                for _ in 0..inner {
                    *dp = *sp;
                    dp = dp.offset(di as isize);
                    sp = sp.offset(si as isize);
                }
            }
            let mut d = n - 1;
            while d > 0 {
                d -= 1;
                idx[d] += 1;
                doff += dstr[d];
                soff += sstr[d];
                if idx[d] < shape[d] {
                    break;
                }
                doff -= dstr[d] * shape[d] as i64;
                soff -= sstr[d] * shape[d] as i64;
                idx[d] = 0;
            }
        }
    }
}

/// Whether position `p` along output axis `d` lies in one of the plan's
/// copy segments for that axis.
#[inline]
fn seg_covers(plan: &GatherPlan, d: usize, p: usize) -> bool {
    plan.segs[d].iter().any(|&(o, l, _)| p >= o && p < o + l)
}

/// Zero the elements of `out` (contiguous row-major over the plan's box)
/// that no segment block writes; with rows shorter than [`ROW_CALL_MIN`] the
/// whole box, which the blocks then overwrite. The blocks are the Cartesian products
/// of one segment per axis, so an element is covered iff every one of its
/// coordinates lies in a segment of its axis: a row whose outer coordinates
/// are not all covered is zeroed whole, any other row only in the gaps
/// between its last axis' segments.
///
/// # Safety
/// `out` must hold the plan box's elements.
unsafe fn zero_uncovered(plan: &GatherPlan, out: *mut f64) {
    let nd = plan.shape.len();
    let tot = total(&plan.shape);
    if nd == 0 || tot == 0 {
        if nd == 0 {
            unsafe { *out = 0.0 };
        }
        return;
    }
    let inner = plan.shape[nd - 1];
    if inner < ROW_CALL_MIN {
        // Short rows: one fill of the whole box is cheaper than the walk.
        unsafe { std::slice::from_raw_parts_mut(out, tot).fill(0.0) };
        return;
    }
    let mut gaps: SmallVec<[(usize, usize); 4]> = SmallVec::new();
    let mut segs: SmallVec<[(usize, usize); 4]> = plan.segs[nd - 1]
        .iter()
        .map(|&(o, l, _)| (o, o + l))
        .collect();
    segs.sort_unstable();
    let mut next = 0usize;
    for (a, b) in segs {
        if a > next {
            gaps.push((next, a));
        }
        next = next.max(b);
    }
    if next < inner {
        gaps.push((next, inner));
    }
    let mut idx = DimU::from_elem(0, nd);
    for row in 0..tot / inner {
        let p = unsafe { out.add(row * inner) };
        if (0..nd - 1).all(|d| seg_covers(plan, d, idx[d])) {
            for &(a, b) in &gaps {
                unsafe { std::slice::from_raw_parts_mut(p.add(a), b - a).fill(0.0) };
            }
        } else {
            unsafe { std::slice::from_raw_parts_mut(p, inner).fill(0.0) };
        }
        let mut d = nd - 1;
        while d > 0 {
            d -= 1;
            idx[d] += 1;
            if idx[d] < plan.shape[d] {
                break;
            }
            idx[d] = 0;
        }
    }
}

/// Strided fill with a scalar.
pub(super) unsafe fn fill_strided(dst: *mut f64, dstr: &[i64], shape: &[usize], v: f64) {
    let n = shape.len();
    unsafe {
        if n == 0 {
            *dst = v;
            return;
        }
        let tot = total(shape);
        if tot == 0 {
            return;
        }
        if is_contig(dstr, shape) {
            for k in 0..tot {
                *dst.add(k) = v;
            }
            return;
        }
        let inner = shape[n - 1];
        if inner == 0 {
            return;
        }
        let di = dstr[n - 1];
        let outer = tot / inner;
        let mut idx = DimU::from_elem(0, n);
        let mut doff = 0i64;
        for _ in 0..outer {
            let mut dp = dst.offset(doff as isize);
            for _ in 0..inner {
                *dp = v;
                dp = dp.offset(di as isize);
            }
            let mut d = n - 1;
            while d > 0 {
                d -= 1;
                idx[d] += 1;
                doff += dstr[d];
                if idx[d] < shape[d] {
                    break;
                }
                doff -= dstr[d] * shape[d] as i64;
                idx[d] = 0;
            }
        }
    }
}

/// Execute one precompiled gather plan into a contiguous row-major `out` —
/// the raw-strides transliteration of `eval_vec_index`'s copy phase (and of
/// the reference executor's `exec_gather`).
#[inline(never)]
pub(super) unsafe fn exec_gather(
    plan: &GatherPlan,
    src: &SrcView,
    out: *mut f64,
    full_cover: bool,
    ways: usize,
) {
    assert_eq!(
        &src.shape[..],
        &plan.src_shape[..],
        "gather source shape mismatch"
    );
    let out_ndim = plan.shape.len();
    // 1. Reduce fixed axes: advance the base pointer, keep the rest ascending
    //    (fixed_desc is sorted descending, but we rebuild by skipping).
    let mut base = src.ptr;
    let mut fixed_mask = [false; 16];
    for &(d, i0) in &plan.fixed_desc {
        fixed_mask[d] = true;
        base = unsafe { base.offset((src.strides[d] * i0 as i64) as isize) };
    }
    let reduced: DimI = (0..src.shape.len())
        .filter(|d| !fixed_mask[*d])
        .map(|d| src.strides[d])
        .collect();
    // 2. Permute the mapped source axes into output order; broadcast axes get
    //    stride 0 (`insert_axis` + `broadcast`).
    let mut eff = DimI::from_elem(0, out_ndim);
    let mut mpos = 0usize;
    for a in 0..out_ndim {
        if plan.mapped[a] {
            eff[a] = reduced[plan.perm[mpos]];
            mpos += 1;
        }
    }
    // 3. Ghost fill: `+0.0` (ArrayD::zeros semantics) on every element the
    //    segment schedule leaves uncovered — skipped when it provably
    //    overwrites every element.
    if !full_cover {
        unsafe { zero_uncovered(plan, out) };
    }
    // 4. Segment-copy schedule (mixed-radix over per-axis segment picks,
    //    axis 0 fastest — disjoint blocks, so order is immaterial).
    let out_rm = rm_strides(&plan.shape);
    let mut pick = DimU::from_elem(0, out_ndim);
    let mut bshape = DimU::from_elem(0, out_ndim);
    loop {
        let mut dbase = 0i64;
        let mut sbase = 0i64;
        for d in 0..out_ndim {
            let (o, l, s) = plan.segs[d][pick[d]];
            dbase += out_rm[d] * o as i64;
            sbase += eff[d] * s as i64;
            bshape[d] = l;
        }
        // A large segment splits under the call's width (see `par`).
        unsafe {
            super::copy_strided_maybe_split(
                ways,
                out.offset(dbase as isize),
                &out_rm,
                base.offset(sbase as isize),
                &eff,
                &bshape,
            );
        }
        let mut d = 0;
        let mut done = false;
        loop {
            if d == out_ndim {
                done = true;
                break;
            }
            pick[d] += 1;
            if pick[d] < plan.segs[d].len() {
                break;
            }
            pick[d] = 0;
            d += 1;
        }
        if done {
            break;
        }
    }
}

/// `Instr::Scan`: `dst` (contiguous row-major over `src.shape`) receives the
/// running fold of `src` along `axis`, from `init`, independently for every
/// position of the other axes — inclusive (`dst[k] = f(dst[k-1], src[k])`,
/// `dst[0] = f(init, src[0])`) or exclusive (`dst[0] = init`, `dst[k] =
/// f(dst[k-1], src[k-1])`). Every position folds its window ascending, one
/// combine per step, in `run_prefix_scan`'s association; walking the scanned
/// axis outermost lets each step be one contiguous row of the other axes.
/// `dst` never aliases `src` (a scan is not alias-safe in the slab coloring).
pub(super) unsafe fn scan_axis(
    dst: *mut f64,
    src: &SrcView,
    axis: usize,
    init: f64,
    inclusive: bool,
    f: impl Fn(f64, f64) -> f64 + Copy,
) {
    let shape = &src.shape;
    let pre: usize = shape[..axis].iter().product();
    let len = shape[axis];
    let post: usize = shape[axis + 1..].iter().product();
    // Source offset of row-major flat position `k`, through the source's own
    // strides (every tape source is row-major, but an observed need not be).
    let contig = is_contig(&src.strides, shape);
    let src_at = |k: usize| -> *const f64 {
        if contig {
            return unsafe { src.ptr.add(k) };
        }
        let mut rest = k;
        let mut off = 0i64;
        for d in (0..shape.len()).rev() {
            off += (rest % shape[d]) as i64 * src.strides[d];
            rest /= shape[d];
        }
        unsafe { src.ptr.offset(off as isize) }
    };
    unsafe {
        if contig && post == 1 {
            // A scan along the innermost axis: one running accumulator per
            // lane, the same fold as the row form below.
            for p in 0..pre {
                let (s, d) = (src.ptr.add(p * len), dst.add(p * len));
                let mut acc = init;
                for k in 0..len {
                    let x = *s.add(k);
                    if inclusive {
                        acc = f(acc, x);
                        *d.add(k) = acc;
                    } else {
                        *d.add(k) = acc;
                        acc = f(acc, x);
                    }
                }
            }
            return;
        }
        for p in 0..pre {
            let base = p * len * post;
            for k in 0..len {
                let row = base + k * post;
                match (inclusive, k) {
                    (true, 0) => {
                        for q in 0..post {
                            *dst.add(row + q) = f(init, *src_at(row + q));
                        }
                    }
                    (true, _) => {
                        for q in 0..post {
                            *dst.add(row + q) = f(*dst.add(row - post + q), *src_at(row + q));
                        }
                    }
                    (false, 0) => {
                        for q in 0..post {
                            *dst.add(row + q) = init;
                        }
                    }
                    (false, _) => {
                        for q in 0..post {
                            *dst.add(row + q) =
                                f(*dst.add(row - post + q), *src_at(row - post + q));
                        }
                    }
                }
            }
        }
    }
}

/// `Instr::Reduce` over the LEADING axes of a contiguous row-major source:
/// `acc[o] = f(acc[o], src[r * n + o])` for every row `r` in order — the
/// row-major visiting order, one contiguous row at a time. `acc` holds `n`
/// elements, already seeded with the identity, and never aliases `src`.
pub(super) unsafe fn reduce_rows(
    acc: *mut f64,
    n: usize,
    src: *const f64,
    rows: usize,
    f: impl Fn(f64, f64) -> f64 + Copy,
) {
    unsafe {
        let a = std::slice::from_raw_parts_mut(acc, n);
        for r in 0..rows {
            let row = std::slice::from_raw_parts(src.add(r * n), n);
            for (y, &x) in a.iter_mut().zip(row) {
                *y = f(*y, x);
            }
        }
    }
}

/// One axis of extent `len` folded out of a contiguous row-major source
/// viewed as `[pre, len, post]`: `acc[p * post + q] = f(acc[..], src[(p *
/// len + j) * post + q])` for `j` ascending — each output cell's terms in its
/// own axis order, which is the row-major visiting order restricted to that
/// cell. `acc` holds `pre * post` elements, already seeded with the
/// identity, and never aliases `src`.
pub(super) unsafe fn reduce_axis(
    acc: *mut f64,
    src: *const f64,
    pre: usize,
    len: usize,
    post: usize,
    f: impl Fn(f64, f64) -> f64 + Copy,
) {
    unsafe {
        if post == 1 {
            for p in 0..pre {
                let row = std::slice::from_raw_parts(src.add(p * len), len);
                let mut y = *acc.add(p);
                for &x in row {
                    y = f(y, x);
                }
                *acc.add(p) = y;
            }
            return;
        }
        for p in 0..pre {
            reduce_rows(acc.add(p * post), post, src.add(p * len * post), len, f);
        }
    }
}

/// `Instr::IndexGather`: `dst` (contiguous row-major over `spec.shape`)
/// receives, per output position, the source element the data subscript
/// `idx` selects along the spec's data axis (the zero ghost when
/// [`data_subscript`] says it is out of range), the other source axes being
/// affine in an output axis or fixed.
///
/// # Safety
/// `src` must be a live view of `spec.src_shape`, `idx` a scalar or a live
/// view aligned to `spec.shape`, and `dst` must hold `spec.shape`'s elements
/// without aliasing either (the coloring treats the instruction as
/// alias-unsafe).
pub(super) unsafe fn index_gather(dst: *mut f64, spec: &IndexGatherSpec, src: &SrcView, idx: &Rv) {
    debug_assert_eq!(
        &src.shape[..],
        &spec.src_shape[..],
        "IndexGather source box"
    );
    let shape = &spec.shape[..];
    let nd = shape.len();
    let data_d = spec.data_axis();
    let n_data = src.shape[data_d];
    let s_data = src.strides[data_d];
    // The source offset of every non-data axis, as `base + Σ step[a]·pos[a]`.
    let mut base = 0i64;
    let mut step_out: DimI = DimI::from_elem(0, nd);
    for (d, ax) in spec.axes.iter().enumerate() {
        match *ax {
            GatherAxis::Data => {}
            GatherAxis::Fixed(i) => base += src.strides[d] * i as i64,
            GatherAxis::Affine { axis, off } => {
                base += src.strides[d] * off;
                step_out[axis as usize] += src.strides[d];
            }
        }
    }
    let (ip, istr): (*const f64, DimI) = match idx {
        Rv::S(v) => (v as *const f64, DimI::from_elem(0, nd)),
        Rv::V { ptr, strides } => (*ptr, strides.clone()),
    };
    let n = total(shape);
    let mut pos: DimU = DimU::from_elem(0, nd);
    let (mut soff, mut ioff) = (base, 0i64);
    for k in 0..n {
        let v = unsafe { *ip.offset(ioff as isize) };
        let x = match data_subscript(v, n_data) {
            Some(p) => unsafe { *src.ptr.offset((soff + s_data * p as i64) as isize) },
            None => 0.0,
        };
        unsafe { *dst.add(k) = x };
        // Row-major odometer, carrying both running offsets.
        let mut d = nd;
        while d > 0 {
            d -= 1;
            pos[d] += 1;
            soff += step_out[d];
            ioff += istr[d];
            if pos[d] < shape[d] {
                break;
            }
            soff -= step_out[d] * shape[d] as i64;
            ioff -= istr[d] * shape[d] as i64;
            pos[d] = 0;
        }
    }
}

/// `Instr::TableGather`: `dst[k] = src[pos[k]]`, the zero ghost where
/// `pos[k]` is [`GATHER_GHOST`]. `pos` holds ROW-MAJOR flat positions into
/// `src.shape`, which a source with other strides (a state array read in
/// place, column-major) reaches by unravelling each one.
pub(super) unsafe fn table_gather(dst: *mut f64, src: &SrcView, pos: &[u32]) {
    let rm = rm_strides(&src.shape);
    unsafe {
        if src.strides[..] == rm[..] {
            for (k, &p) in pos.iter().enumerate() {
                *dst.add(k) = if p == GATHER_GHOST {
                    0.0
                } else {
                    *src.ptr.add(p as usize)
                };
            }
            return;
        }
        for (k, &p) in pos.iter().enumerate() {
            *dst.add(k) = if p == GATHER_GHOST {
                0.0
            } else {
                let mut rest = p as i64;
                let mut off = 0i64;
                for d in 0..src.shape.len() {
                    off += (rest / rm[d]) * src.strides[d];
                    rest %= rm[d];
                }
                *src.ptr.offset(off as isize)
            };
        }
    }
}

/// `Instr::SegReduce`: output cell `c` folds `src[rows[c] .. rows[c + 1]]`
/// from `init`, in order, skipping every term whose `mask` entry is `0`.
pub(super) unsafe fn seg_reduce(
    dst: *mut f64,
    src: *const f64,
    mask: Option<*const f64>,
    rows: &[u32],
    init: f64,
    f: impl Fn(f64, f64) -> f64 + Copy,
) {
    unsafe {
        for c in 0..rows.len() - 1 {
            let (a, b) = (rows[c] as usize, rows[c + 1] as usize);
            let mut acc = init;
            match mask {
                None => {
                    for k in a..b {
                        acc = f(acc, *src.add(k));
                    }
                }
                Some(m) => {
                    for k in a..b {
                        if *m.add(k) != 0.0 {
                            acc = f(acc, *src.add(k));
                        }
                    }
                }
            }
            *dst.add(c) = acc;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Every element of a `shape` box, as its multi-index, row-major.
    fn cells(shape: &[usize]) -> Vec<Vec<usize>> {
        let mut out = vec![vec![]];
        for &n in shape {
            out = out
                .into_iter()
                .flat_map(|c| {
                    (0..n).map(move |i| {
                        let mut c = c.clone();
                        c.push(i);
                        c
                    })
                })
                .collect();
        }
        out
    }

    fn off(ix: &[usize], st: &[i64]) -> usize {
        ix.iter().zip(st).map(|(&i, &s)| i as i64 * s).sum::<i64>() as usize
    }

    /// The row-folding and row-copy paths move exactly the elements the
    /// per-element walk moves, for sub-boxes of whole rows, partial rows,
    /// transposed and strided views.
    #[test]
    fn copy_strided_matches_the_element_walk() {
        let cases: Vec<(Vec<usize>, Vec<i64>, Vec<i64>)> = vec![
            // A sub-box of whole rows of a [6, 4, 5] box into a dense one.
            (vec![2, 4, 5], vec![20, 5, 1], vec![20, 5, 1]),
            // Partial rows: [3, 2, 3] out of [6, 4, 5].
            (vec![3, 2, 3], vec![20, 5, 1], vec![6, 3, 1]),
            // Transposed source.
            (vec![4, 5], vec![1, 4], vec![5, 1]),
            // Strided inner axis on one side only.
            (vec![3, 4], vec![8, 2], vec![4, 1]),
            // Contiguous inner pair, strided outer.
            (vec![2, 3, 4], vec![40, 4, 1], vec![12, 4, 1]),
            // Rows long enough for the row copy: whole rows, then partial.
            (vec![2, 3, 80], vec![480, 80, 1], vec![240, 80, 1]),
            (vec![2, 3, 70], vec![480, 80, 1], vec![210, 70, 1]),
        ];
        for (shape, sst, dst_st) in cases {
            let span = |st: &[i64]| -> usize {
                shape
                    .iter()
                    .zip(st)
                    .map(|(&n, &s)| (n - 1) as i64 * s)
                    .sum::<i64>() as usize
                    + 1
            };
            let src: Vec<f64> = (0..span(&sst)).map(|k| k as f64 + 0.5).collect();
            let mut got = vec![-1.0f64; span(&dst_st)];
            let mut want = got.clone();
            unsafe { copy_strided(got.as_mut_ptr(), &dst_st, src.as_ptr(), &sst, &shape) };
            for c in cells(&shape) {
                want[off(&c, &dst_st)] = src[off(&c, &sst)];
            }
            assert_eq!(got, want, "shape {shape:?} src {sst:?} dst {dst_st:?}");
        }
    }

    /// `zero_uncovered` zeroes exactly the elements outside every segment
    /// block and leaves the covered ones alone.
    #[test]
    fn zero_uncovered_zeroes_exactly_the_ghosts() {
        let shape: DimU = SmallVec::from_slice(&[4, 3, 70]);
        let segs: SmallVec<[SmallVec<[(usize, usize, usize); 2]>; 4]> = SmallVec::from_vec(vec![
            SmallVec::from_slice(&[(1, 3, 0)]),
            SmallVec::from_slice(&[(0, 1, 0), (2, 1, 0)]),
            SmallVec::from_slice(&[(30, 35, 0), (0, 20, 0)]),
        ]);
        let plan = GatherPlan {
            fixed_desc: SmallVec::new(),
            perm: SmallVec::from_slice(&[0, 1, 2]),
            mapped: SmallVec::from_slice(&[true, true, true]),
            segs,
            shape: shape.clone(),
            origin: SmallVec::from_slice(&[1, 1, 1]),
            src_shape: shape.clone(),
            src_origin: SmallVec::from_slice(&[1, 1, 1]),
        };
        let mut out = vec![7.0f64; 4 * 3 * 70];
        unsafe { zero_uncovered(&plan, out.as_mut_ptr()) };
        for (k, c) in cells(&shape).iter().enumerate() {
            let covered = (0..3).all(|d| seg_covers(&plan, d, c[d]));
            assert_eq!(out[k], if covered { 7.0 } else { 0.0 }, "cell {c:?}");
        }
    }
}
