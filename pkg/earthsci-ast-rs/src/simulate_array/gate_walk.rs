//! The gate-driven walk over a cell's contracted dims, shared by the
//! interpreter (`eval::reduce_contraction_gated`) and the tape builder
//! (`tape::lower::tuples::visit_tuples`), so the two enumerate the SAME tuples
//! in the SAME order (CONFORMANCE_SPEC.md §5.24.1(b), §5.24.2).
//!
//! Everything the two callers do per output cell lives here, in one
//! [`GatePlan`] built once per node: the conjunction of the gates with a bound
//! side ([`GatePlan::restrict_cell`]), the empty-range guard, the propagation
//! below, and the walk ([`GatePlan::walk_cell`]). A caller only supplies the
//! cell's bounds, its bound output values, and a [`TupleSink`].
//!
//! The gates that pair two CONTRACTED dims (§5.5.8's fourth shape) are carried
//! as [`Link`]s. Two things use them:
//!
//! 1. **Semi-join propagation** ([`propagate_links`]), before the walk. A dim
//!    that a gate to a bound output index restricted narrows every dim it is
//!    linked to, to the union of its admitted values' partners, in both
//!    directions, to a true fixpoint over any gate graph, cyclic or not. This
//!    is what lets a pin on one contracted dim reach the dims a chain of
//!    contracted–contracted gates hangs off it.
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

use super::eval::GateAxis;
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

// ---- Sorted-list primitives ------------------------------------------------
//
// Every list here is ascending and duplicate-free. The one merge step is
// `seek`; intersection, in-place intersection and the subset test are all
// built on it, so there is a single merge loop to get right.

/// Advance `j` along ascending `b` to the first element `>= x`; is it `x`?
#[inline]
fn seek(b: &[i64], j: &mut usize, x: i64) -> bool {
    while *j < b.len() && b[*j] < x {
        *j += 1;
    }
    *j < b.len() && b[*j] == x
}

/// Keep only the elements of `buf` that also occur in `keep`, in place.
fn retain_sorted_in(buf: &mut Vec<i64>, keep: &[i64]) {
    let mut j = 0usize;
    buf.retain(|&x| seek(keep, &mut j, x));
}

/// Append the intersection of `a` and `b` to `out` (which is cleared first).
fn intersect_into(out: &mut Vec<i64>, a: &[i64], b: &[i64]) {
    let (short, long) = if a.len() <= b.len() { (a, b) } else { (b, a) };
    out.clear();
    out.extend_from_slice(short);
    retain_sorted_in(out, long);
}

/// The ascending intersection of two ascending, duplicate-free lists.
pub(super) fn intersect_sorted(a: &[i64], b: &[i64]) -> Vec<i64> {
    let mut out = Vec::new();
    intersect_into(&mut out, a, b);
    out
}

/// Is every element of `a` also in `b`?
fn is_subset_sorted(a: &[i64], b: &[i64]) -> bool {
    let mut j = 0usize;
    a.iter().all(|&x| seek(b, &mut j, x))
}

/// Intersect `slot` with one more ascending list.
///
/// Returns `false` when the result is EMPTY — no leaf is admitted for this
/// output cell at all, which is §5.5.6's identity fill and not a hole.
pub(super) fn intersect_restriction<'a>(
    slot: &mut Option<Restriction<'a>>,
    parts: Restriction<'a>,
) -> bool {
    narrow(slot, parts) != Narrowed::Empty
}

/// What [`narrow`] did to a dim's admitted set.
#[derive(PartialEq, Eq)]
enum Narrowed {
    /// It was already within the new list: no change, nothing allocated.
    Same,
    /// It shrank (or was unrestricted and is now restricted).
    Changed,
    /// Nothing is left: the cell admits no leaf.
    Empty,
}

/// Intersect `slot` with `parts`, reporting whether that narrowed it.
fn narrow<'a>(slot: &mut Option<Restriction<'a>>, parts: Restriction<'a>) -> Narrowed {
    if parts.is_empty() {
        *slot = Some(parts);
        return Narrowed::Empty;
    }
    match slot.take() {
        None => {
            *slot = Some(parts);
            Narrowed::Changed
        }
        Some(cur) if is_subset_sorted(&cur, &parts) => {
            *slot = Some(cur);
            Narrowed::Same
        }
        Some(cur) => {
            let next = intersect_sorted(&cur, &parts);
            let empty = next.is_empty();
            *slot = Some(Cow::Owned(next));
            if empty {
                Narrowed::Empty
            } else {
                Narrowed::Changed
            }
        }
    }
}

// ---- Links and propagation -------------------------------------------------

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

    /// Does the gate admit early value `e` with late value `l`?
    #[inline]
    fn admits(&self, e: i64, l: i64) -> bool {
        if self.early_is_src {
            self.index.contains(e, l)
        } else {
            self.index.contains(l, e)
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
    sort_dedup_within(&mut out, lo, hi);
    Cow::Owned(out)
}

/// Sort `v`, whose every element lies in `[lo, hi]`, ascending and drop its
/// duplicates. When the range is narrow next to the list (as a union of many
/// values' partners within one index set usually is), by marking each value
/// and reading the marks back in order, O(len + width), instead of a
/// comparison sort: the same set in the same order either way.
fn sort_dedup_within(v: &mut Vec<i64>, lo: i64, hi: i64) {
    let width = (hi as i128 - lo as i128 + 1).max(0) as u128;
    if v.len() < 64 || width > 4 * v.len() as u128 {
        v.sort_unstable();
        v.dedup();
        return;
    }
    let mut mark = vec![false; width as usize];
    for &x in v.iter() {
        mark[(x - lo) as usize] = true;
    }
    v.clear();
    v.extend(
        mark.iter()
            .enumerate()
            .filter(|&(_, &m)| m)
            .map(|(k, _)| lo + k as i64),
    );
}

/// Semi-join propagation across contracted–contracted gates (module docs,
/// item 1), to a TRUE fixpoint over any gate graph, cyclic or not.
///
/// A worklist of dims whose admitted set changed: for each such dim `from`,
/// every link touching it restricts its other end to the union of `from`'s
/// admitted values' partners. A dim is queued again only when that narrowed
/// it, so a link is re-examined only from an end that changed since it was
/// last read. It terminates because a dim's set only ever shrinks (or goes
/// from unrestricted to restricted, once), and every queue entry follows a
/// change. A restriction that is already within the partner union is left
/// as is, with nothing allocated.
///
/// `ranges` is the cell's contraction bounds. Returns `false` when some dim's
/// admitted set becomes empty: the cell is the identity.
///
/// The cost is bounded by the walk it replaces: each union over a restricted
/// end touches each of its pairs once per change of that end, and the walk
/// without propagation visited at least those pairs (driving the link) or the
/// full product (filtering it).
pub(super) fn propagate_links<'a>(
    links: &[Link<'a>],
    ranges: &[(i64, i64)],
    restrict: &mut [Option<Restriction<'a>>],
) -> bool {
    let mut queued: SmallVec<[bool; 4]> = restrict.iter().map(Option::is_some).collect();
    let mut work: SmallVec<[usize; 4]> = (0..restrict.len()).filter(|&d| queued[d]).collect();
    while let Some(from) = work.pop() {
        queued[from] = false;
        for l in links {
            let (to, side) = if l.early == from {
                (l.late, l.early_side())
            } else if l.late == from {
                (l.early, l.late_side())
            } else {
                continue;
            };
            let (lo, hi) = ranges[to];
            let reach = {
                let have = restrict[from]
                    .as_deref()
                    .expect("a queued dim is restricted");
                partner_union(l.index, side, have, lo, hi)
            };
            match narrow(&mut restrict[to], reach) {
                Narrowed::Empty => return false,
                Narrowed::Same => {}
                Narrowed::Changed => {
                    if !queued[to] {
                        queued[to] = true;
                        work.push(to);
                    }
                }
            }
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

// ---- The per-node plan -----------------------------------------------------

/// What one gate does for a node, decided once from where its two symbols sit.
#[derive(Clone, Copy)]
enum Place {
    /// Both symbols are bound output indices: a membership test per cell.
    Test,
    /// `src` is contracted dim `d` and `tgt` is bound: `d` enumerates the
    /// bound value's partners.
    PinSrc(usize),
    /// `tgt` is contracted dim `d` and `src` is bound.
    PinTgt(usize),
    /// Both contracted, on different dims: one of the plan's [`Link`]s.
    Linked,
    /// Both on one contracted dim, or a symbol this node does not bind:
    /// nothing a pair list can drive (the lowered `filter` still applies it).
    Inert,
}

/// The cell-independent part of a gated walk over one node: every gate's
/// [`Place`], the links between contracted dims, and the links grouped by
/// their late end. Built once per node by both callers.
pub(super) struct GatePlan<'a> {
    gates: SmallVec<[(&'a OverlapIndex, Place); 4]>,
    links: SmallVec<[Link<'a>; 4]>,
    into: LinksInto<'a>,
    nc: usize,
}

/// The per-cell buffers of a [`GatePlan`] walk, reused across cells.
pub(super) struct CellBufs<'a> {
    restrict: SmallVec<[Option<Restriction<'a>>; 4]>,
    cur: SmallVec<[i64; 4]>,
    scratch: SmallVec<[Vec<i64>; 4]>,
    pairs: Vec<(i64, i64)>,
}

impl<'a> GatePlan<'a> {
    /// The plan for `gates` (each gate's index with where its `src` and `tgt`
    /// symbols sit), in selectivity order, over `nc` contracted dims.
    pub(super) fn new(
        nc: usize,
        gates: impl IntoIterator<Item = (&'a OverlapIndex, GateAxis, GateAxis)>,
    ) -> Self {
        let mut placed: SmallVec<[(&'a OverlapIndex, Place); 4]> = SmallVec::new();
        let mut links: SmallVec<[Link<'a>; 4]> = SmallVec::new();
        for (index, src, tgt) in gates {
            let place = match (src, tgt) {
                (GateAxis::Output, GateAxis::Output) => Place::Test,
                (GateAxis::Contracted(d), GateAxis::Output) => Place::PinSrc(d),
                (GateAxis::Output, GateAxis::Contracted(d)) => Place::PinTgt(d),
                (GateAxis::Contracted(a), GateAxis::Contracted(b)) if a != b => {
                    links.push(Link::new(a, b, index));
                    Place::Linked
                }
                _ => Place::Inert,
            };
            placed.push((index, place));
        }
        let into = links_into(&links, nc);
        GatePlan {
            gates: placed,
            links,
            into,
            nc,
        }
    }

    /// Fresh per-cell buffers for this plan.
    pub(super) fn bufs(&self) -> CellBufs<'a> {
        CellBufs {
            restrict: (0..self.nc).map(|_| None).collect(),
            cur: SmallVec::from_elem(0, self.nc),
            scratch: (0..self.nc).map(|_| Vec::new()).collect(),
            pairs: Vec::new(),
        }
    }

    /// Phase 1 for one output cell: the conjunction of every gate with a bound
    /// side, then the empty-range guard, then the propagation across links.
    /// `bound(g, src)` is the cell's value of gate `g`'s `src` (or `tgt`)
    /// symbol, `None` when the cell does not bind it (the gate is then
    /// skipped). Leaves the per-dim restriction in `bufs`.
    ///
    /// `false` when the cell admits no leaf: it is the semiring identity.
    pub(super) fn restrict_cell(
        &self,
        ranges: &[(i64, i64)],
        bound: impl Fn(usize, bool) -> Option<i64>,
        bufs: &mut CellBufs<'a>,
    ) -> bool {
        let restrict = &mut bufs.restrict;
        restrict.iter_mut().for_each(|r| *r = None);
        for (g, &(index, place)) in self.gates.iter().enumerate() {
            match place {
                Place::Test => {
                    let (Some(l), Some(r)) = (bound(g, true), bound(g, false)) else {
                        continue;
                    };
                    if !index.contains(l, r) {
                        return false;
                    }
                }
                Place::PinSrc(d) => {
                    let (Some(r), Some(&(lo, hi))) = (bound(g, false), ranges.get(d)) else {
                        continue;
                    };
                    let parts = index.partners_in(Side::Tgt, r, lo, hi);
                    if !intersect_restriction(&mut restrict[d], parts.into()) {
                        return false;
                    }
                }
                Place::PinTgt(d) => {
                    let (Some(l), Some(&(lo, hi))) = (bound(g, true), ranges.get(d)) else {
                        continue;
                    };
                    let parts = index.partners_in(Side::Src, l, lo, hi);
                    if !intersect_restriction(&mut restrict[d], parts.into()) {
                        return false;
                    }
                }
                Place::Linked | Place::Inert => {}
            }
        }
        // An empty dim admits nothing, before any propagation work.
        if ranges.iter().any(|&(lo, hi)| hi < lo) {
            return false;
        }
        self.links.is_empty() || propagate_links(&self.links, ranges, restrict)
    }

    /// Walk the cell's admitted tuples into `sink`, after a
    /// [`Self::restrict_cell`] that returned `true`: the odometer over each
    /// dim's restricted (or full) range, each dim enumerating only what every
    /// link to an earlier dim admits. With no contracted dim the sink sees one
    /// empty tuple (the pointwise term). `false` once the sink asks to stop.
    pub(super) fn walk_cell(
        &self,
        ranges: &[(i64, i64)],
        bufs: &mut CellBufs<'a>,
        sink: &mut impl TupleSink,
    ) -> bool {
        let CellBufs {
            restrict,
            cur,
            scratch,
            pairs,
        } = bufs;
        // The PAIRS shape: two contracted dims, both unrestricted, and every
        // link between them. The most selective link's pair list then binds
        // the whole tuple, so the walk goes straight to the matches instead of
        // probing partners per value of dim 0. Same tuples, same order.
        if self.nc == 2 && !self.links.is_empty() && restrict.iter().all(Option::is_none) {
            return walk_pairs(&self.links, ranges, pairs, cur, sink);
        }
        let srcs: SmallVec<[DimSrc<'_>; 4]> = (0..self.nc)
            .map(|d| match &restrict[d] {
                Some(v) => DimSrc::List(v),
                None => DimSrc::Range(ranges[d].0, ranges[d].1),
            })
            .collect();
        walk_linked(&srcs, &self.into, 0, cur, scratch, sink)
    }
}

/// [`GatePlan::walk_cell`]'s PAIRS shape. The odometer varies dim 1 fastest,
/// so the product order over the surviving tuples is the pair list sorted by
/// (dim 0, dim 1).
fn walk_pairs(
    links: &[Link<'_>],
    ranges: &[(i64, i64)],
    pairs: &mut Vec<(i64, i64)>,
    cur: &mut [i64],
    sink: &mut impl TupleSink,
) -> bool {
    let (lead, rest) = links.split_first().expect("a PAIRS walk has a link");
    let (lo0, hi0) = ranges[0];
    let (lo1, hi1) = ranges[1];
    pairs.clear();
    pairs.extend(
        lead.index
            .pairs()
            .map(|(s, t)| if lead.early_is_src { (s, t) } else { (t, s) })
            .filter(|&(a, b)| a >= lo0 && a <= hi0 && b >= lo1 && b <= hi1)
            .filter(|&(a, b)| rest.iter().all(|l| l.admits(a, b))),
    );
    if !lead.early_is_src {
        pairs.sort_unstable();
    }
    for &(a, b) in pairs.iter() {
        cur[0] = a;
        sink.bind(0, a);
        cur[1] = b;
        sink.bind(1, b);
        if !sink.leaf(cur) {
            return false;
        }
    }
    true
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
    // borrow it rather than copy it.
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
    let (e0, ix0, side0) = links[0];
    match &srcs[d] {
        DimSrc::Range(lo, hi) => {
            buf.clear();
            buf.extend_from_slice(ix0.partners_in(side0, cur[e0], *lo, *hi));
        }
        DimSrc::List(vals) => intersect_into(&mut buf, vals, ix0.partners(side0, cur[e0])),
    }
    for &(e, ix, side) in &links[1..] {
        if buf.is_empty() {
            break;
        }
        retain_sorted_in(&mut buf, ix.partners(side, cur[e]));
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

    /// Every value left in a restricted dim has a partner in every restricted
    /// dim it is linked to: the arc-consistency a true fixpoint guarantees.
    fn assert_fixpoint(links: &[Link], restrict: &[Option<Restriction>]) {
        for l in links {
            for (from, to, side) in [
                (l.early, l.late, l.early_side()),
                (l.late, l.early, l.late_side()),
            ] {
                let (Some(have), Some(other)) =
                    (restrict[from].as_deref(), restrict[to].as_deref())
                else {
                    continue;
                };
                for &v in have {
                    let parts = l.index.partners(side, v);
                    assert!(
                        other.iter().any(|o| parts.contains(o)),
                        "dim {from} value {v} has no partner left in dim {to}"
                    );
                }
            }
        }
    }

    /// A CYCLIC gate graph (all three pairwise) narrows to a true fixpoint,
    /// however many passes that takes, and a narrowing that changes nothing
    /// leaves the restriction borrowed.
    #[test]
    fn propagation_reaches_a_fixpoint_on_a_cycle() {
        // A long ladder around the triangle: each step of narrowing removes
        // one value, so a pass-capped loop would stop short.
        let n = 12i64;
        let ab: Vec<(i64, i64)> = (1..=n).map(|v| (v, v)).collect();
        let bc: Vec<(i64, i64)> = (1..=n).map(|v| (v, v)).collect();
        let ca: Vec<(i64, i64)> = (2..=n).map(|v| (v, v - 1)).chain([(1, n)]).collect();
        let (ab, bc, ca) = (
            OverlapIndex::from_pairs(&ab),
            OverlapIndex::from_pairs(&bc),
            OverlapIndex::from_pairs(&ca),
        );
        let links = [
            Link::new(0, 1, &ab),
            Link::new(1, 2, &bc),
            Link::new(2, 0, &ca),
        ];
        let ranges = [(1, n), (1, n), (1, n)];
        // Dim 0 pinned to everything but `n`: the cycle shifts by one each
        // round, so the admitted set erodes one value at a time to nothing.
        let pin: Vec<i64> = (1..n).collect();
        let mut restrict: Vec<Option<Restriction>> =
            vec![Some(Cow::Borrowed(&pin[..])), None, None];
        assert!(!propagate_links(&links, &ranges, &mut restrict));

        // A consistent cycle: the identity on all three links.
        let id = OverlapIndex::from_pairs(&(1..=n).map(|v| (v, v)).collect::<Vec<_>>());
        let links = [
            Link::new(0, 1, &id),
            Link::new(1, 2, &id),
            Link::new(2, 0, &id),
        ];
        let pin = [3i64, 5, 7];
        let mut restrict: Vec<Option<Restriction>> =
            vec![Some(Cow::Borrowed(&pin[..])), None, None];
        assert!(propagate_links(&links, &ranges, &mut restrict));
        for r in &restrict {
            assert_eq!(r.as_deref(), Some(&pin[..]));
        }
        assert!(matches!(restrict[0], Some(Cow::Borrowed(_))));
        assert_fixpoint(&links, &restrict);
    }

    /// Several links between the same two dims take the PAIRS walk, which is
    /// the full product filtered by every link, in odometer order.
    #[test]
    fn the_pairs_walk_takes_every_link_between_two_dims() {
        let a = OverlapIndex::from_pairs(&[(1, 1), (1, 2), (2, 2), (3, 1), (3, 3)]);
        // The same two dims the other way round (src is the late dim).
        let b = OverlapIndex::from_pairs(&[(1, 1), (2, 3), (3, 3), (2, 1)]);
        let plan = GatePlan::new(
            2,
            [
                (&a, GateAxis::Contracted(0), GateAxis::Contracted(1)),
                (&b, GateAxis::Contracted(1), GateAxis::Contracted(0)),
            ],
        );
        let ranges = [(1, 3), (1, 3)];
        let mut bufs = plan.bufs();
        assert!(plan.restrict_cell(&ranges, |_, _| None, &mut bufs));
        let mut sink = Collect(Vec::new());
        assert!(plan.walk_cell(&ranges, &mut bufs, &mut sink));
        let mut want = Vec::new();
        for x in 1..=3 {
            for y in 1..=3 {
                if a.contains(x, y) && b.contains(y, x) {
                    want.push(vec![x, y]);
                }
            }
        }
        assert_eq!(sink.0, want);
        assert_eq!(want, vec![vec![1, 1], vec![1, 2], vec![3, 3]]);
    }

    /// [`sort_dedup_within`] is `sort_unstable` + `dedup` on both of its
    /// paths: short lists, wide ranges, and the marking path over a narrow
    /// range with many duplicates, including negative bounds.
    #[test]
    fn sort_dedup_within_is_sort_then_dedup() {
        let mut x = 12345u64;
        let mut next = move || {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            x
        };
        for (len, lo, hi) in [
            (0usize, 1i64, 1i64),
            (10, 1, 5),
            (63, 1, 3),
            (64, 1, 3),
            (200, -7, 40),
            (500, 1, 100_000),
            (1000, 1, 1000),
            (4000, 100, 120),
        ] {
            let span = (hi - lo + 1) as u64;
            let v: Vec<i64> = (0..len).map(|_| lo + (next() % span) as i64).collect();
            let mut want = v.clone();
            want.sort_unstable();
            want.dedup();
            let mut got = v;
            sort_dedup_within(&mut got, lo, hi);
            assert_eq!(got, want, "len {len} in [{lo}, {hi}]");
        }
    }

    #[test]
    fn sorted_list_primitives() {
        assert_eq!(
            intersect_sorted(&[1, 3, 5, 7], &[2, 3, 4, 7, 9]),
            vec![3, 7]
        );
        assert_eq!(intersect_sorted(&[], &[1]), Vec::<i64>::new());
        let mut buf = vec![1, 2, 4, 8];
        retain_sorted_in(&mut buf, &[2, 3, 8]);
        assert_eq!(buf, vec![2, 8]);
        assert!(is_subset_sorted(&[2, 8], &[1, 2, 4, 8]));
        assert!(!is_subset_sorted(&[2, 9], &[1, 2, 4, 8]));
        let mut slot: Option<Restriction> = Some(Cow::Borrowed(&[2, 4][..]));
        assert!(narrow(&mut slot, Cow::Borrowed(&[1, 2, 4][..])) == Narrowed::Same);
        assert!(matches!(slot, Some(Cow::Borrowed(_))));
        assert!(narrow(&mut slot, Cow::Borrowed(&[4][..])) == Narrowed::Changed);
        assert!(narrow(&mut slot, Cow::Borrowed(&[5][..])) == Narrowed::Empty);
    }
}
