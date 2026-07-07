//! Column-major layout helpers: flat↔multi index conversion, ndarray
//! materialization of column-major blocks, and Cartesian index enumeration.

use super::*;

pub(super) fn multi_to_flat_col_major(multi: &[i64], shape: &[usize], origin: &[i64]) -> usize {
    if shape.is_empty() {
        return 0;
    }
    let mut flat: usize = 0;
    let mut stride: usize = 1;
    for d in 0..shape.len() {
        let off = (multi[d] - origin[d]).max(0) as usize;
        flat += off * stride;
        stride *= shape[d];
    }
    flat
}

pub(super) fn flat_to_multi_col_major(flat: usize, shape: &[usize]) -> Vec<usize> {
    let mut out = vec![0usize; shape.len()];
    let mut rem = flat;
    for d in 0..shape.len() {
        out[d] = rem % shape[d];
        rem /= shape[d];
    }
    out
}

/// Build a column-major ndarray from a flat slice. ndarray uses row-major
/// strides natively, so we construct via `from_shape_vec` with a reversed
/// shape and then `permuted_axes` to get the column-major view.
pub(super) fn col_major_to_arrayd(flat: &[f64], shape: &[usize]) -> ArrayD<f64> {
    if shape.is_empty() {
        return ArrayD::from_elem(IxDyn(&[]), flat[0]);
    }
    // Build row-major array with reversed shape, then reverse axes. The
    // element order in `flat` is column-major, which equals row-major of
    // the reversed-shape array.
    let rev_shape: Vec<usize> = shape.iter().rev().copied().collect();
    let arr = ArrayD::from_shape_vec(IxDyn(&rev_shape), flat.to_vec())
        .expect("col_major_to_arrayd shape mismatch");
    let perm: Vec<usize> = (0..shape.len()).rev().collect();
    arr.permuted_axes(perm).as_standard_layout().into_owned()
}

/// Flatten an ndarray into column-major order.
pub(super) fn arrayd_to_col_major(arr: &ArrayD<f64>) -> Vec<f64> {
    if arr.ndim() == 0 {
        return vec![arr[IxDyn(&[])]];
    }
    let shape: Vec<usize> = arr.shape().to_vec();
    let total: usize = shape.iter().product();
    let mut out = vec![0.0f64; total];
    for flat in 0..total {
        let multi = flat_to_multi_col_major(flat, &shape);
        out[flat] = arr[IxDyn(&multi)];
    }
    out
}

/// Generate every index tuple in the Cartesian product of the given
/// (lo, hi) inclusive ranges. Ordering is lexicographic on dim0 outermost.
pub(super) fn cartesian_range(ranges: &[(i64, i64)]) -> Vec<Vec<i64>> {
    let mut out = vec![Vec::new()];
    for &(lo, hi) in ranges {
        let mut next: Vec<Vec<i64>> = Vec::new();
        for partial in &out {
            for v in lo..=hi {
                let mut p = partial.clone();
                p.push(v);
                next.push(p);
            }
        }
        out = next;
    }
    out
}

/// Streaming, allocation-free enumerator over the Cartesian product of inclusive
/// `(lo, hi)` ranges — semantically identical to [`cartesian_range`] (same
/// lexicographic order with dim0 outermost/slowest and the last dim fastest, the
/// same empty-product rules: no ranges ⇒ one empty tuple, any `lo > hi` dim ⇒
/// zero tuples), but it yields `&[i64]` slices out of a single reused stack
/// buffer instead of materializing a `Vec<Vec<i64>>`.
///
/// The per-cell reduction kernel ([`reduce_contraction`]) rebuilt the *whole*
/// contraction product on every output cell, so the throw-away per-tuple
/// `Vec<i64>` dominated the array-simulate profile (~23% of samples were just
/// `drop_in_place::<Vec<i64>>`). This enumerator allocates nothing per tuple.
///
/// Because each yielded slice borrows the shared buffer, this is a *lending*
/// iterator: it exposes an inherent [`CartesianTuples::next`] for use in a
/// `while let Some(tuple) = it.next()` loop rather than implementing [`Iterator`].
pub(super) struct CartesianTuples<'a> {
    ranges: &'a [(i64, i64)],
    cur: SmallVec<[i64; 4]>,
    started: bool,
    done: bool,
}

impl<'a> CartesianTuples<'a> {
    #[inline]
    pub(super) fn new(ranges: &'a [(i64, i64)]) -> Self {
        // Any empty dim (lo > hi) makes the whole product empty (zero tuples),
        // matching `cartesian_range`'s `lo..=hi` producing no values there.
        let done = ranges.iter().any(|&(lo, hi)| lo > hi);
        let cur: SmallVec<[i64; 4]> = ranges.iter().map(|&(lo, _)| lo).collect();
        CartesianTuples {
            ranges,
            cur,
            started: false,
            done,
        }
    }

    /// Advance to the next tuple, returning it as a slice into the reused buffer,
    /// or `None` once the product is exhausted.
    #[inline]
    pub(super) fn next(&mut self) -> Option<&[i64]> {
        if self.done {
            return None;
        }
        if !self.started {
            // First tuple: every dim at its lower bound (an empty product of no
            // ranges yields exactly one empty tuple, like `vec![vec![]]`).
            self.started = true;
            return Some(&self.cur[..]);
        }
        // Odometer increment: advance the last (fastest-varying) dim, carrying
        // left into slower dims — reproduces the lexicographic order.
        let mut d = self.ranges.len();
        while d > 0 {
            d -= 1;
            if self.cur[d] < self.ranges[d].1 {
                self.cur[d] += 1;
                return Some(&self.cur[..]);
            }
            self.cur[d] = self.ranges[d].0;
        }
        self.done = true;
        None
    }
}
