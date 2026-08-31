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
        let inner = shape[n - 1];
        if inner == 0 {
            return;
        }
        let (di, si) = (dstr[n - 1], sstr[n - 1]);
        let outer = tot / inner;
        let mut idx = DimU::from_elem(0, n);
        let (mut doff, mut soff) = (0i64, 0i64);
        for _ in 0..outer {
            let mut dp = dst.offset(doff as isize);
            let mut sp = src.offset(soff as isize);
            for _ in 0..inner {
                *dp = *sp;
                dp = dp.offset(di as isize);
                sp = sp.offset(si as isize);
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
    // 3. Ghost fill: `+0.0` everywhere (ArrayD::zeros semantics) — skipped
    //    when the segment schedule provably overwrites every element.
    if !full_cover {
        let out_len = total(&plan.shape);
        unsafe {
            for k in 0..out_len {
                *out.add(k) = 0.0;
            }
        }
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
        unsafe {
            copy_strided(
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
