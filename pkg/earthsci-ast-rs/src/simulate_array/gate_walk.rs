//! The gate-driven walk over a cell's contracted dims, shared by the
//! interpreter (`eval::reduce_contraction_gated`) and the tape builder
//! (`tape::lower::tuples::visit_tuples`), so the two enumerate the SAME tuples
//! in the SAME order (CONFORMANCE_SPEC.md §5.24.1(b), §5.24.2).
//!
//! The gates that pair two CONTRACTED dims (§5.5.8's fourth shape) are carried
//! here as [`Link`]s. Two things use them:
//!
//! 1. **Semi-join propagation** ([`propagate_links`]), before the walk. A dim
//!    that Phase 1 restricted (through a gate to a bound output index) narrows
//!    every dim it is linked to, to the union of its admitted values' partners;
//!    and so on to a fixpoint. This is what lets a pin on one contracted dim
//!    reach the dims a chain of contracted–contracted gates hangs off it.
//! 2. **Multi-link restriction** ([`walk_linked`]), during the walk. At depth
//!    `d` the dim enumerates the INTERSECTION of the partner lists of every
//!    link from `d` to an earlier (already bound) dim, not one of them. This is
//!    what closes a star join over a contracted hub.
//!
//! Both only ever replace a dim's ascending source by an ascending,
//! duplicate-free SUBSEQUENCE of it, and the walk stays the odometer (first dim
//! outermost, last fastest). Every tuple dropped fails some gate, and every
//! gate is also decided by the node's `filter` (an `on` gate's equality is
//! lowered into it; an overlap gate is a superset of the author's narrow
//! phase), so the admitted terms — and the order they fold in — are exactly
//! those of the full product.

use std::borrow::Cow;

use smallvec::SmallVec;

use crate::broad_phase::{OverlapIndex, Side};

/// One contracted dimension's enumeration source: its own ascending interval,
/// or the explicit ascending value list the gates restricted it to.
pub(super) enum DimSrc<'a> {
    Range(i64, i64),
    List(&'a [i64]),
}

impl DimSrc<'_> {
    #[inline]
    pub(super) fn len(&self) -> usize {
        match self {
            DimSrc::Range(lo, hi) => (hi - lo + 1).max(0) as usize,
            DimSrc::List(v) => v.len(),
        }
    }
    #[inline]
    pub(super) fn at(&self, i: usize) -> i64 {
        match self {
            DimSrc::Range(lo, _) => lo + i as i64,
            DimSrc::List(v) => v[i],
        }
    }
}

/// One contracted dim's admitted value list, accumulated across gates:
/// ascending and duplicate-free. Borrowed when it is one gate's partner slice
/// (the common case, no allocation), owned once two lists were intersected.
pub(super) type Restriction<'a> = Cow<'a, [i64]>;

/// The ascending intersection of two ascending, duplicate-free lists.
pub(super) fn intersect_sorted(a: &[i64], b: &[i64]) -> Vec<i64> {
    let mut out: Vec<i64> = Vec::with_capacity(a.len().min(b.len()));
    let (mut i, mut j) = (0usize, 0usize);
    while i < a.len() && j < b.len() {
        match a[i].cmp(&b[j]) {
            std::cmp::Ordering::Less => i += 1,
            std::cmp::Ordering::Greater => j += 1,
            std::cmp::Ordering::Equal => {
                out.push(a[i]);
                i += 1;
                j += 1;
            }
        }
    }
    out
}

/// Intersect `slot` with one more ascending list.
///
/// Returns `false` when the result is EMPTY — no leaf is admitted for this
/// output cell at all, which is §5.5.6's identity fill and not a hole.
pub(super) fn intersect_restriction<'a>(
    slot: &mut Option<Restriction<'a>>,
    parts: Restriction<'a>,
) -> bool {
    let next = match slot.take() {
        None => parts,
        Some(cur) => Cow::Owned(intersect_sorted(&cur, &parts)),
    };
    let ok = !next.is_empty();
    *slot = Some(next);
    ok
}

/// A gate whose two symbols are both contracted, on two DIFFERENT dims.
#[derive(Clone, Copy)]
pub(super) struct Link<'a> {
    /// The earlier dim in `contract_names` order (bound first by the walk).
    pub(super) early: usize,
    /// The later dim.
    pub(super) late: usize,
    pub(super) index: &'a OverlapIndex,
    /// Is `early` the gate's `src` symbol (so `late` is its `tgt`)?
    pub(super) early_is_src: bool,
}

impl<'a> Link<'a> {
    /// The link for a gate whose `src` symbol is contracted dim `src_dim` and
    /// whose `tgt` symbol is contracted dim `tgt_dim` (`src_dim != tgt_dim`).
    pub(super) fn new(src_dim: usize, tgt_dim: usize, index: &'a OverlapIndex) -> Self {
        if src_dim < tgt_dim {
            Link {
                early: src_dim,
                late: tgt_dim,
                index,
                early_is_src: true,
            }
        } else {
            Link {
                early: tgt_dim,
                late: src_dim,
                index,
                early_is_src: false,
            }
        }
    }

    /// The side a value of the early dim lives on.
    #[inline]
    pub(super) fn early_side(&self) -> Side {
        if self.early_is_src {
            Side::Src
        } else {
            Side::Tgt
        }
    }

    /// The side a value of the late dim lives on.
    #[inline]
    fn late_side(&self) -> Side {
        if self.early_is_src {
            Side::Tgt
        } else {
            Side::Src
        }
    }
}

/// The ascending, duplicate-free union of the partners (within `[lo, hi]`) of
/// every value in `from`, which lives on `side` of `index`. A single value's
/// partner slice is borrowed as is.
fn partner_union<'a>(
    index: &'a OverlapIndex,
    side: Side,
    from: &[i64],
    lo: i64,
    hi: i64,
) -> Restriction<'a> {
    if let [v] = from {
        return Cow::Borrowed(index.partners_in(side, *v, lo, hi));
    }
    let mut out: Vec<i64> = Vec::new();
    for &v in from {
        out.extend_from_slice(index.partners_in(side, v, lo, hi));
    }
    out.sort_unstable();
    out.dedup();
    Cow::Owned(out)
}

/// Semi-join propagation across contracted–contracted gates (module docs,
/// item 1): for each link whose one end is restricted, restrict the other end
/// to the union of the restricted values' partners, in both directions,
/// repeating until nothing narrows (at most one pass per link plus the one
/// that sees no change; stopping earlier would still be sound, since every
/// restriction here only drops tuples some gate rejects).
///
/// `ranges` is the cell's contraction bounds. Returns `false` when some dim's
/// admitted set becomes empty: the cell is the identity.
///
/// The cost is bounded by the walk it replaces: the union over a restricted
/// end touches each of its pairs once, and the pre-propagation walk visited
/// at least those pairs (driving the link) or the full product (filtering it).
pub(super) fn propagate_links<'a>(
    links: &[Link<'a>],
    ranges: &[(i64, i64)],
    restrict: &mut [Option<Restriction<'a>>],
) -> bool {
    for _ in 0..=links.len() {
        let mut changed = false;
        for l in links {
            for (from, to, side) in [
                (l.early, l.late, l.early_side()),
                (l.late, l.early, l.late_side()),
            ] {
                let Some(have) = restrict[from].as_deref() else {
                    continue;
                };
                let (lo, hi) = ranges[to];
                let reach = partner_union(l.index, side, have, lo, hi);
                let before = restrict[to].as_ref().map(|r| r.len());
                if !intersect_restriction(&mut restrict[to], reach) {
                    return false;
                }
                if before != restrict[to].as_ref().map(|r| r.len()) {
                    changed = true;
                }
            }
        }
        if !changed {
            break;
        }
    }
    true
}

/// For each dim `d`, the links whose LATE end is `d`: `(early dim, index, side
/// the early value lives on)`. What [`walk_linked`] intersects at depth `d`.
pub(super) type LinksInto<'a> = SmallVec<[SmallVec<[(usize, &'a OverlapIndex, Side); 2]>; 4]>;

/// Group `links` by their late end, over `n` contracted dims.
pub(super) fn links_into<'a>(links: &[Link<'a>], n: usize) -> LinksInto<'a> {
    let mut by: LinksInto<'a> = (0..n).map(|_| SmallVec::new()).collect();
    for l in links {
        by[l.late].push((l.early, l.index, l.early_side()));
    }
    by
}

/// What a [`walk_linked`] visit does with each binding and each tuple.
pub(super) trait TupleSink {
    /// Dim `d` is now bound to `v` (the walk also records it in `cur`).
    fn bind(&mut self, d: usize, v: i64);
    /// Every dim is bound (`cur`); `false` stops the walk.
    fn leaf(&mut self, cur: &[i64]) -> bool;
}

/// The odometer over `srcs` (first dim outermost, last fastest), where dim `d`
/// enumerates only the values every link in `into[d]` admits for the current
/// binding of its early end (module docs, item 2). `scratch` holds one reusable
/// buffer per dim. `false` once the sink asks to stop.
pub(super) fn walk_linked(
    srcs: &[DimSrc],
    into: &LinksInto<'_>,
    d: usize,
    cur: &mut [i64],
    scratch: &mut [Vec<i64>],
    sink: &mut impl TupleSink,
) -> bool {
    if d == srcs.len() {
        return sink.leaf(cur);
    }
    let links = &into[d];
    if links.is_empty() {
        let s = &srcs[d];
        for i in 0..s.len() {
            let v = s.at(i);
            cur[d] = v;
            sink.bind(d, v);
            if !walk_linked(srcs, into, d + 1, cur, scratch, sink) {
                return false;
            }
        }
        return true;
    }
    // One link over an unrestricted dim: its partner slice IS the source, so
    // borrow it rather than copy it (the pre-multi-link path exactly).
    if let ([(e, index, side)], DimSrc::Range(lo, hi)) = (&links[..], &srcs[d]) {
        let parts = index.partners_in(*side, cur[*e], *lo, *hi);
        for &v in parts {
            cur[d] = v;
            sink.bind(d, v);
            if !walk_linked(srcs, into, d + 1, cur, scratch, sink) {
                return false;
            }
        }
        return true;
    }
    // Otherwise intersect the source with every link's partner list, in a
    // buffer reused across visits of this depth.
    let mut buf = std::mem::take(&mut scratch[d]);
    buf.clear();
    {
        let (e0, ix0, side0) = links[0];
        match &srcs[d] {
            DimSrc::Range(lo, hi) => {
                buf.extend_from_slice(ix0.partners_in(side0, cur[e0], *lo, *hi));
            }
            DimSrc::List(vals) => {
                let parts = ix0.partners(side0, cur[e0]);
                let (mut i, mut j) = (0usize, 0usize);
                while i < vals.len() && j < parts.len() {
                    match vals[i].cmp(&parts[j]) {
                        std::cmp::Ordering::Less => i += 1,
                        std::cmp::Ordering::Greater => j += 1,
                        std::cmp::Ordering::Equal => {
                            buf.push(vals[i]);
                            i += 1;
                            j += 1;
                        }
                    }
                }
            }
        }
        for &(e, ix, side) in &links[1..] {
            if buf.is_empty() {
                break;
            }
            let parts = ix.partners(side, cur[e]);
            // In-place ascending intersection: `w` trails `i`.
            let (mut i, mut j, mut w) = (0usize, 0usize, 0usize);
            while i < buf.len() && j < parts.len() {
                match buf[i].cmp(&parts[j]) {
                    std::cmp::Ordering::Less => i += 1,
                    std::cmp::Ordering::Greater => j += 1,
                    std::cmp::Ordering::Equal => {
                        buf[w] = buf[i];
                        w += 1;
                        i += 1;
                        j += 1;
                    }
                }
            }
            buf.truncate(w);
        }
    }
    let mut ok = true;
    for &v in &buf {
        cur[d] = v;
        sink.bind(d, v);
        if !walk_linked(srcs, into, d + 1, cur, scratch, sink) {
            ok = false;
            break;
        }
    }
    scratch[d] = buf;
    ok
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Collect(Vec<Vec<i64>>);
    impl TupleSink for Collect {
        fn bind(&mut self, _: usize, _: i64) {}
        fn leaf(&mut self, cur: &[i64]) -> bool {
            self.0.push(cur.to_vec());
            true
        }
    }

    /// The linked walk is the full product's odometer order filtered by every
    /// link: same tuples, same order.
    #[test]
    fn the_linked_walk_is_the_filtered_odometer() {
        // Three dims; links 0~2 and 1~2 (a star into dim 2), plus 0~1 the
        // other way round (tgt is the early dim), with many-to-many partners.
        let a = OverlapIndex::from_pairs(&[(1, 2), (1, 3), (2, 3), (3, 1), (3, 3)]);
        let b = OverlapIndex::from_pairs(&[(1, 3), (2, 2), (2, 3), (3, 3)]);
        let c = OverlapIndex::from_pairs(&[(2, 1), (3, 1), (3, 2), (1, 3), (2, 3)]);
        let links = [
            Link::new(0, 2, &a),
            Link::new(1, 2, &b),
            Link::new(1, 0, &c),
        ];
        let ranges = [(1, 3), (1, 3), (1, 3)];
        let admits =
            |t: &[i64]| a.contains(t[0], t[2]) && b.contains(t[1], t[2]) && c.contains(t[1], t[0]);
        let mut want = Vec::new();
        for x in 1..=3 {
            for y in 1..=3 {
                for z in 1..=3 {
                    if admits(&[x, y, z]) {
                        want.push(vec![x, y, z]);
                    }
                }
            }
        }
        assert!(want.len() > 1);
        let srcs: Vec<DimSrc> = ranges.iter().map(|&(l, h)| DimSrc::Range(l, h)).collect();
        let into = links_into(&links, 3);
        let mut sink = Collect(Vec::new());
        let mut cur = vec![0; 3];
        let mut scratch = vec![Vec::new(); 3];
        assert!(walk_linked(
            &srcs,
            &into,
            0,
            &mut cur,
            &mut scratch,
            &mut sink
        ));
        assert_eq!(sink.0, want);
    }

    /// A pin on one end of a chain reaches the far end, and the propagated
    /// lists are ascending and duplicate-free.
    #[test]
    fn propagation_carries_a_pin_down_a_chain() {
        // dim0 ~ dim1 ~ dim2; dim0 pinned to {2}.
        let a = OverlapIndex::from_pairs(&[(1, 1), (2, 3), (2, 1), (3, 2)]);
        let b = OverlapIndex::from_pairs(&[(1, 4), (1, 2), (2, 1), (3, 4), (3, 5)]);
        let links = [Link::new(0, 1, &a), Link::new(1, 2, &b)];
        let ranges = [(1, 3), (1, 3), (1, 5)];
        let pin = [2i64];
        let mut restrict: Vec<Option<Restriction>> =
            vec![Some(Cow::Borrowed(&pin[..])), None, None];
        assert!(propagate_links(&links, &ranges, &mut restrict));
        assert_eq!(restrict[1].as_deref(), Some(&[1i64, 3][..]));
        assert_eq!(restrict[2].as_deref(), Some(&[2i64, 4, 5][..]));
        assert_eq!(restrict[0].as_deref(), Some(&[2i64][..]));
        // A pin with no partner empties the cell.
        let none = [9i64];
        let mut restrict: Vec<Option<Restriction>> =
            vec![None, None, Some(Cow::Borrowed(&none[..]))];
        assert!(!propagate_links(&links, &ranges, &mut restrict));
    }
}
