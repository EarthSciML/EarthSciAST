//! The executor half of [`Instr::PolyArea`]: one `polygon_intersection_area`
//! per element of a box, with the planar broad phase that keeps a
//! source × target overlap box from clipping every pair.
//!
//! Shared by the slab executor and the XLA emitter's build-time fold, so both
//! run the same candidate enumeration. The test-only reference executor does
//! NOT use it: it clips every element densely, which is the definition the
//! broad phase is pinned against.
//!
//! Every value comes from `clip_area_value`, the function the interpreter's
//! `eval_polygon_intersection_area` calls, on the same rings read in the same
//! vertex order, so an element is the interpreter's value by shared code.

use super::super::eval::clip_area_value;
use super::ir::*;
use crate::broad_phase::{Envelope, broad_phase_candidates};
use crate::geometry::{Manifold, planar_ring_bbox};
use smallvec::SmallVec;

/// A ring table as the instruction reads it: its first element and its own
/// strides (elements) over its own box.
pub(super) struct RingTable<'a> {
    pub ptr: *const f64,
    pub shape: &'a [usize],
    pub strides: &'a [i64],
}

/// Read the ring `r` selects for the output position `pos` into `buf`, as
/// `(lon, lat)` pairs in vertex order — `arrayd_to_lonlat` of the sub-array
/// the interpreter's partial `index(table, …)` returns.
///
/// # Safety
/// `t` must describe a live buffer of at least its box, and every position the
/// selectors reach must be inside it (the lowering checks both).
unsafe fn read_ring(t: &RingTable, r: &RingRef, pos: &[usize], buf: &mut Vec<(f64, f64)>) {
    let lead = r.sel.len();
    let mut base = 0i64;
    for (d, s) in r.sel.iter().enumerate() {
        let i = match *s {
            RingSel::Fixed(i) => i as i64,
            RingSel::Axis { axis, off } => pos[axis as usize] as i64 + off,
        };
        base += t.strides[d] * i;
    }
    let nv = t.shape[lead];
    let (sv, sc) = (t.strides[lead], t.strides[lead + 1]);
    buf.clear();
    for v in 0..nv as i64 {
        let p = base + sv * v;
        unsafe {
            buf.push((*t.ptr.offset(p as isize), *t.ptr.offset((p + sc) as isize)));
        }
    }
}

/// Row-major strides (elements) of `shape` — the slab slot layout.
fn rm_strides(shape: &[usize]) -> SmallVec<[i64; 4]> {
    let mut st: SmallVec<[i64; 4]> = SmallVec::from_elem(0, shape.len());
    let mut acc = 1i64;
    for d in (0..shape.len()).rev() {
        st[d] = acc;
        acc *= shape[d] as i64;
    }
    st
}

/// The rings' bounding boxes, split into the ones the R*-tree takes (finite,
/// as `(xmin, ymin, xmax, ymax)` envelopes with their ring's position), the
/// ones it should not see (a non-finite bound), and every non-empty ring.
#[allow(clippy::type_complexity)]
fn classify_rings(
    flat: &[(f64, f64)],
    nv: usize,
    n: usize,
) -> (Vec<(usize, Envelope)>, Vec<usize>, Vec<usize>) {
    let mut finite: Vec<(usize, Envelope)> = Vec::new();
    let mut wild: Vec<usize> = Vec::new();
    let mut nonempty: Vec<usize> = Vec::new();
    for i in 0..n {
        let Some(bb) = planar_ring_bbox(&flat[i * nv..(i + 1) * nv]) else {
            continue;
        };
        nonempty.push(i);
        if bb.iter().all(|v| v.is_finite()) {
            finite.push((i, [bb[0], bb[2], bb[1], bb[3]]));
        } else {
            wild.push(i);
        }
    }
    (finite, wild, nonempty)
}

/// Advance a row-major odometer over `shape`; `false` once it wraps.
fn step(pos: &mut [usize], shape: &[usize]) -> bool {
    let mut d = shape.len();
    while d > 0 {
        d -= 1;
        pos[d] += 1;
        if pos[d] < shape[d] {
            return true;
        }
        pos[d] = 0;
    }
    false
}

/// Execute one [`Instr::PolyArea`] into `out` (row-major over `spec.shape`;
/// one element for a scalar slot).
///
/// # Safety
/// `a` and `b` must be live tables of the boxes the spec was lowered against,
/// `out` must hold `spec.shape`'s element count, and `out` must not alias
/// either table (the slab coloring treats the instruction as alias-unsafe).
pub(super) unsafe fn run_poly_area(spec: &GeomSpec, a: &RingTable, b: &RingTable, out: *mut f64) {
    debug_assert_eq!(a.shape, &spec.a.src_shape[..], "PolyArea ring table a");
    debug_assert_eq!(b.shape, &spec.b.src_shape[..], "PolyArea ring table b");
    let shape = &spec.shape[..];
    let n: usize = shape.iter().product::<usize>().max(1);
    let out = unsafe { std::slice::from_raw_parts_mut(out, n) };
    let mut ra: Vec<(f64, f64)> = Vec::new();
    let mut rb: Vec<(f64, f64)> = Vec::new();
    if let Some((axis_a, axis_b)) = spec.pairs {
        unsafe { run_pairs(spec, a, b, axis_a as usize, axis_b as usize, out) };
        return;
    }
    let mut pos: SmallVec<[usize; 4]> = SmallVec::from_elem(0, shape.len());
    for slot in out.iter_mut() {
        unsafe {
            read_ring(a, &spec.a, &pos, &mut ra);
            read_ring(b, &spec.b, &pos, &mut rb);
        }
        *slot = clip_area_value(&ra, &rb, spec.manifold);
        step(&mut pos, shape);
    }
}

/// The broad-phase path: ring `a` varies along `axis_a` only, ring `b` along
/// `axis_b` only, and the manifold is planar.
///
/// Candidates are the pairs whose bounding boxes are NOT strictly disjoint —
/// the complement of the kernel's own reject — found by an R*-tree over the
/// `b` boxes (`broad_phase_candidates` at `eps = 0`, whose closed-box test is
/// that complement exactly). A box with a non-finite bound is paired with
/// every non-empty ring on the other side, since neither the tree nor a
/// shortcut should be trusted to order it; an empty ring is disjoint from
/// everything. Every non-candidate element holds what the kernel returns for a
/// disjoint pair, computed through the kernel rather than written as a
/// constant.
unsafe fn run_pairs(
    spec: &GeomSpec,
    a: &RingTable,
    b: &RingTable,
    axis_a: usize,
    axis_b: usize,
    out: &mut [f64],
) {
    debug_assert_eq!(spec.manifold, Manifold::Planar);
    let shape = &spec.shape[..];
    let rings = |t: &RingTable, r: &RingRef, axis: usize| -> (Vec<(f64, f64)>, usize) {
        let nv = t.shape[r.sel.len()];
        let mut flat: Vec<(f64, f64)> = Vec::with_capacity(shape[axis] * nv);
        let mut buf: Vec<(f64, f64)> = Vec::with_capacity(nv);
        let mut pos: SmallVec<[usize; 4]> = SmallVec::from_elem(0, shape.len());
        for p in 0..shape[axis] {
            pos[axis] = p;
            unsafe { read_ring(t, r, &pos, &mut buf) };
            flat.extend_from_slice(&buf);
        }
        (flat, nv)
    };
    let (flat_a, nva) = rings(a, &spec.a, axis_a);
    let (flat_b, nvb) = rings(b, &spec.b, axis_b);
    let ring_a = |i: usize| &flat_a[i * nva..(i + 1) * nva];
    let ring_b = |j: usize| &flat_b[j * nvb..(j + 1) * nvb];
    let (na, nb) = (shape[axis_a], shape[axis_b]);

    let (fa, wa, nea) = classify_rings(&flat_a, nva, na);
    let (fb, wb, neb) = classify_rings(&flat_b, nvb, nb);
    let envs_a: Vec<Envelope> = fa.iter().map(|(_, e)| *e).collect();
    let envs_b: Vec<Envelope> = fb.iter().map(|(_, e)| *e).collect();
    let mut cand: Vec<(usize, usize)> = broad_phase_candidates(&envs_a, &envs_b, 0.0)
        .into_iter()
        .map(|(qi, cj)| (fa[qi].0, fb[cj].0))
        .collect();
    for &i in &wa {
        cand.extend(neb.iter().map(|&j| (i, j)));
    }
    for &j in &wb {
        cand.extend(nea.iter().map(|&i| (i, j)));
    }
    cand.sort_unstable();
    cand.dedup();

    let disjoint = clip_area_value(&[], &[], Manifold::Planar);
    out.fill(disjoint);

    // Every output position of the pair `(i, j)`: the two pair axes pinned,
    // the others (along which neither ring varies) walked row-major.
    let strides = rm_strides(shape);
    let rest: SmallVec<[usize; 4]> = (0..shape.len())
        .filter(|&d| d != axis_a && d != axis_b)
        .collect();
    let rest_shape: SmallVec<[usize; 4]> = rest.iter().map(|&d| shape[d]).collect();
    let mut rpos: SmallVec<[usize; 4]> = SmallVec::from_elem(0, rest.len());
    for (i, j) in cand {
        let v = clip_area_value(ring_a(i), ring_b(j), Manifold::Planar);
        let base = strides[axis_a] * i as i64 + strides[axis_b] * j as i64;
        rpos.iter_mut().for_each(|p| *p = 0);
        loop {
            let mut off = base;
            for (k, &d) in rest.iter().enumerate() {
                off += strides[d] * rpos[k] as i64;
            }
            out[off as usize] = v;
            if !step(&mut rpos, &rest_shape) {
                break;
            }
        }
    }
}
