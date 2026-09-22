//! PLANAR spatial-index broad phase — conservative candidate generation.
//!
//! Phase 3a of projection-pushdown, ported from the Julia reference
//! `pkg/EarthSciAST.jl/src/broad_phase.jl`. A reusable, deterministic
//! broad-phase seam returning a CONSERVATIVE SUPERSET of the `(query × cell)`
//! index pairs whose 2-D bounding boxes (envelopes) intersect. The overlap
//! join-gate (`crate::value_invention`) consumes it to replace a uniform-grid
//! bin-equality gate with envelope candidacy.
//!
//! Two layers, so there is a reference oracle:
//!
//!   1. CORE — [`broad_phase_candidates_bruteforce`]: the dependency-free
//!      `O(nq·nc)` reference method AND the conformance oracle. Walks every pair
//!      and tests envelope intersection.
//!   2. FAST — [`broad_phase_candidates`]: an `rstar` R*-tree over the cell
//!      envelopes, queried by the (eps-inflated) query envelopes. `rstar` is
//!      pure Rust (WASM-clean), and its `AABB` intersection predicate is CLOSED
//!      (`<=`/`>=`, edge-touching admitted) — identical to the brute-force test
//!      — so the fast path returns a vector byte-identical to the core for the
//!      same `eps`. [`broad_phase_candidates_bruteforce`] is retained as the
//!      self-conformance oracle (see the `rstar == brute-force` tests).
//!
//! ENVELOPE CONVENTION. A feature envelope is `(xmin, ymin, xmax, ymax)` — an
//! [`Envelope`] = `[f64; 4]`. (Note this ORDER differs from `geometry.rs`'s
//! internal ring bbox `(xmin, xmax, ymin, ymax)`; the 1-name ring arm below
//! remaps.) The intersection predicate is CLOSED (edge-touching boxes are
//! candidates), matching the negation of a planar bbox-disjoint reject: at
//! `eps=0` this candidate set is exactly the set of pairs a closed AABB overlap
//! does not reject.
//!
//! `eps` SEMANTICS. Both envelopes of a pair are inflated OUTWARD by `eps`
//! before testing: `xmin -= eps, ymin -= eps, xmax += eps, ymax += eps`.
//! `eps >= 0` grows the candidate set (monotone): `candidates(eps=δ) ⊇
//! candidates(eps=0)`. `eps` is a slack knob to keep near-touching /
//! float-fuzzy pairs conservative.

use std::collections::HashMap;

use ndarray::ArrayD;
use rstar::{AABB, RTree, RTreeObject};
use rustc_hash::FxHashMap;

/// A feature envelope `(xmin, ymin, xmax, ymax)`.
pub type Envelope = [f64; 4];

/// Inflate an envelope outward by `eps` on every side.
#[inline]
fn inflate(e: &Envelope, eps: f64) -> Envelope {
    [e[0] - eps, e[1] - eps, e[2] + eps, e[3] + eps]
}

/// Closed-interval AABB intersection per axis (edge-touching admitted). This is
/// bit-for-bit the predicate `rstar`'s `AABB::intersects` applies, so the
/// brute-force core and the R*-tree fast path agree.
#[inline]
fn envelopes_intersect(a: &Envelope, b: &Envelope) -> bool {
    a[0] <= b[2] && b[0] <= a[2] && a[1] <= b[3] && b[1] <= a[3]
}

/// CORE brute-force reference: every `(qi, cj)` — 0-based positions in
/// `query_envs` / `cell_envs` — whose 2-D envelopes intersect after inflating
/// BOTH outward by `eps`. The result is sorted ascending by `(qi, cj)` for
/// determinism.
///
/// This is a CONSERVATIVE SUPERSET of true geometric overlaps: any pair of
/// features whose geometries actually overlap has intersecting envelopes and so
/// appears here (with `eps >= 0`). Missing a true overlap is impossible by
/// construction — the envelope of a geometry contains it. It is BOTH the
/// dependency-free fallback AND the conformance oracle for [`broad_phase_candidates`].
pub fn broad_phase_candidates_bruteforce(
    query_envs: &[Envelope],
    cell_envs: &[Envelope],
    eps: f64,
) -> Vec<(usize, usize)> {
    let mut out: Vec<(usize, usize)> = Vec::new();
    if query_envs.is_empty() || cell_envs.is_empty() {
        return out;
    }
    for (qi, q) in query_envs.iter().enumerate() {
        let qi_env = inflate(q, eps);
        for (cj, c) in cell_envs.iter().enumerate() {
            let cj_env = inflate(c, eps);
            if envelopes_intersect(&qi_env, &cj_env) {
                out.push((qi, cj));
            }
        }
    }
    // Emitted in (qi, cj) ascending order already; sort pins the determinism
    // contract independent of loop structure.
    out.sort_unstable();
    out
}

/// A cell envelope wrapped as an `rstar` tree object carrying its 0-based
/// position. The AABB is pre-inflated by `eps` at build time so the tree query
/// mirrors the brute-force per-pair symmetric inflation exactly.
struct CellEnv {
    idx: usize,
    aabb: AABB<[f64; 2]>,
}

impl RTreeObject for CellEnv {
    type Envelope = AABB<[f64; 2]>;
    fn envelope(&self) -> Self::Envelope {
        self.aabb
    }
}

/// FAST PATH: an `rstar` R*-tree over the (eps-inflated) `cell_envs`, queried by
/// each (eps-inflated) query envelope. Returns every envelope-intersecting
/// `(qi, cj)` 0-based pair, SORTED ascending by `(qi, cj)` — byte-identical to
/// [`broad_phase_candidates_bruteforce`] for the same `eps` (the tree's `AABB`
/// intersection is CLOSED, matching the core).
pub fn broad_phase_candidates(
    query_envs: &[Envelope],
    cell_envs: &[Envelope],
    eps: f64,
) -> Vec<(usize, usize)> {
    let mut out: Vec<(usize, usize)> = Vec::new();
    if query_envs.is_empty() || cell_envs.is_empty() {
        return out;
    }
    // Bulk-load the tree over the eps-inflated cell AABBs.
    let objects: Vec<CellEnv> = cell_envs
        .iter()
        .enumerate()
        .map(|(idx, c)| {
            let e = inflate(c, eps);
            CellEnv {
                idx,
                aabb: AABB::from_corners([e[0], e[1]], [e[2], e[3]]),
            }
        })
        .collect();
    let tree = RTree::bulk_load(objects);
    for (qi, q) in query_envs.iter().enumerate() {
        let e = inflate(q, eps);
        let query_aabb = AABB::from_corners([e[0], e[1]], [e[2], e[3]]);
        for hit in tree.locate_in_envelope_intersecting(query_aabb) {
            out.push((qi, hit.idx));
        }
    }
    out.sort_unstable();
    out
}

/// Build per-position `(xmin, ymin, xmax, ymax)` envelopes from named
/// const-array envelope factors, mirroring the Julia
/// `_envelope_vectors_from_cols`. `env_names` is 1, 2, or 4 factor names; each
/// is looked up in `arrays`:
///   * 4 names → rectangles `[xmin, ymin, xmax, ymax]` (e.g. ISRM cells `[W,S,E,N]`),
///   * 2 names → points `[x, y]` → degenerate envelope `(x, y, x, y)`,
///   * 1 name  → a `[pos, verts, coord]` 3-D ring factor → AABB over the ring
///     vertices, remapped from `(xmin, xmax, ymin, ymax)` to
///     `(xmin, ymin, xmax, ymax)`.
pub fn envelope_vectors(
    env_names: &[String],
    arrays: &HashMap<String, ArrayD<f64>>,
) -> Result<Vec<Envelope>, String> {
    let k = env_names.len();
    let col = |name: &str| -> Result<&ArrayD<f64>, String> {
        arrays
            .get(name)
            .ok_or_else(|| format!("overlap-join env factor {name:?} not supplied in const arrays"))
    };
    match k {
        4 => {
            let (a, b, c, d) = (
                col(&env_names[0])?,
                col(&env_names[1])?,
                col(&env_names[2])?,
                col(&env_names[3])?,
            );
            let n = a.len();
            if b.len() != n || c.len() != n || d.len() != n {
                return Err(format!(
                    "overlap-join 4-factor rect envelope factors must share a length; got \
                     {}, {}, {}, {}",
                    a.len(),
                    b.len(),
                    c.len(),
                    d.len()
                ));
            }
            let (av, bv, cv, dv) = (flat(a), flat(b), flat(c), flat(d));
            Ok((0..n).map(|p| [av[p], bv[p], cv[p], dv[p]]).collect())
        }
        2 => {
            let (x, y) = (col(&env_names[0])?, col(&env_names[1])?);
            let n = x.len();
            if y.len() != n {
                return Err(format!(
                    "overlap-join 2-factor point envelope factors must share a length; got {}, {}",
                    x.len(),
                    y.len()
                ));
            }
            let (xv, yv) = (flat(x), flat(y));
            Ok((0..n).map(|p| [xv[p], yv[p], xv[p], yv[p]]).collect())
        }
        1 => ring_envelopes(col(&env_names[0])?),
        other => Err(format!(
            "overlap-join env must name 1 (rings), 2 (point [x,y]), or 4 \
             (rect [xmin,ymin,xmax,ymax]) const-array factors; got {other}"
        )),
    }
}

/// A contiguous view of an ndarray's elements in row-major order (all envelope
/// factors here are dense 1-D columns, so this is the column itself).
fn flat(a: &ArrayD<f64>) -> Vec<f64> {
    a.iter().copied().collect()
}

/// A `[pos, verts, coord]` ring factor → one AABB envelope per position,
/// remapping the ring bbox `(xmin, xmax, ymin, ymax)` to
/// `(xmin, ymin, xmax, ymax)` (mirrors `_ring_envelopes` / `_ring_xybbox`).
fn ring_envelopes(rings: &ArrayD<f64>) -> Result<Vec<Envelope>, String> {
    let shape = rings.shape();
    if shape.len() != 3 {
        return Err(format!(
            "overlap-join single-factor env expects a [pos, verts, coord] 3-D ring array; \
             got a {}-D factor",
            shape.len()
        ));
    }
    let (npos, nverts, ncoord) = (shape[0], shape[1], shape[2]);
    if ncoord < 2 || nverts == 0 {
        return Err(format!(
            "overlap-join ring factor must be [pos, verts>=1, coord>=2]; got shape {shape:?}"
        ));
    }
    let mut out: Vec<Envelope> = Vec::with_capacity(npos);
    for p in 0..npos {
        let mut xmin = rings[ndarray::IxDyn(&[p, 0, 0])];
        let mut xmax = xmin;
        let mut ymin = rings[ndarray::IxDyn(&[p, 0, 1])];
        let mut ymax = ymin;
        for v in 1..nverts {
            let x = rings[ndarray::IxDyn(&[p, v, 0])];
            let y = rings[ndarray::IxDyn(&[p, v, 1])];
            if x < xmin {
                xmin = x;
            }
            if x > xmax {
                xmax = x;
            }
            if y < ymin {
                ymin = y;
            }
            if y > ymax {
                ymax = y;
            }
        }
        out.push([xmin, ymin, xmax, ymax]);
    }
    Ok(out)
}

// =========================================================================== //
// CANDIDATE-DRIVEN ENUMERATION (projection-pushdown Wall #1) — the SHARED
// driver policy behind BOTH overlap-gated enumeration paths.
//
// An overlap gate resolves its ENTIRE admissible pair set once. Enumerating the
// full cartesian product and membership-testing each tuple therefore does
// `O(∏ranges)` work to reach `O(|candidates|)` surviving tuples. Driving from
// the candidate set instead collapses the cost to `O(|candidates|·∏ungated)`.
//
// The two consumers differ ONLY in loop shape, never in policy:
//
//   * the value-invention producer ([`crate::value_invention`]) enumerates
//     ranges LAZILY (a ragged `of` bound depends on its parent binding), so it
//     recurses; BOTH gated symbols are contracted there.
//   * the dense aggregate expansion (`simulate_array::eval::eval_faq`)
//     unrolls the cartesian product over PRE-EXPANDED contraction bounds once
//     per output cell, and the output cell has usually already bound one of the
//     two gated symbols.
//
// [`overlap_drive_plan`] is the one implementation of the decision both make:
// which symbol(s) the gate drives, and with which values. Everything a caller
// then does is bind those values and recurse / product as it always did.
//
// The driver is a PURE OPTIMISATION. Both callers still run the full membership
// test (the narrow `filter`, and the gate itself) on every leaf, so a shape the
// planner declines to drive ([`DrivePlan::Full`]) falls back to the untouched
// full product and the admitted leaf SET is identical either way. This mirrors
// the Julia `_overlap_drive_plan` in `pkg/EarthSciAST.jl/src/broad_phase.jl`.
// =========================================================================== //

use std::cell::Cell;
use std::sync::OnceLock;

thread_local! {
    /// Instrumentation: number of leaf bindings an OVERLAP-GATED dense
    /// expansion VISITED (a product tuple its unroll entered). Reset by
    /// callers/tests; proves that an overlap-gated walk visits
    /// `O(|candidates|·∏ungated)` tuples, NOT the full `O(∏ranges)` product
    /// (projection-pushdown Wall #1).
    ///
    /// Counted ONLY when an overlap gate is present, so every ungated /
    /// bin-equality expansion (the overwhelming majority, and the engine's
    /// hottest loop) keeps its exact current instruction stream.
    static ENUM_VISITS: Cell<u64> = const { Cell::new(0) };
}

/// Add `n` to this thread's overlap-gated visit counter.
#[inline]
pub(crate) fn bump_overlap_enum_visits(n: u64) {
    ENUM_VISITS.with(|c| c.set(c.get().wrapping_add(n)));
}

/// This thread's overlap-gated leaf-visit count (see [`reset_overlap_enum_visits`]).
pub fn overlap_enum_visits() -> u64 {
    ENUM_VISITS.with(Cell::get)
}

/// Zero this thread's overlap-gated leaf-visit counter.
pub fn reset_overlap_enum_visits() {
    ENUM_VISITS.with(|c| c.set(0));
}

thread_local! {
    /// Instrumentation: number of join-gate indices this thread BUILT rather
    /// than served from cache — a broad-phase envelope set or an `on` match
    /// set, counted on the cache-miss path whether or not the build then
    /// declines.
    ///
    /// The leaf-visit counter above says what a gate DROVE; this one says what
    /// the memoization cost, and it is the only direct evidence that a repeated
    /// evaluation reuses an index instead of rebuilding it. That distinction is
    /// invisible in a document's answers — a rebuilt index is the same pure
    /// function of the same key columns — so without it a test of the cache
    /// budget cannot tell a hit from a miss.
    static GATE_INDEX_BUILDS: Cell<u64> = const { Cell::new(0) };
}

/// Count one join-gate index build on this thread.
#[inline]
pub(crate) fn bump_gate_index_builds() {
    GATE_INDEX_BUILDS.with(|c| c.set(c.get().wrapping_add(1)));
}

/// This thread's join-gate index BUILD count (see [`reset_gate_index_builds`]).
pub fn gate_index_builds() -> u64 {
    GATE_INDEX_BUILDS.with(Cell::get)
}

/// Zero this thread's join-gate index build counter.
pub fn reset_gate_index_builds() {
    GATE_INDEX_BUILDS.with(|c| c.set(0));
}

thread_local! {
    /// How many gates the planner has declined as uneconomic on this thread.
    static PLAN_DECLINES: Cell<u64> = const { Cell::new(0) };
}

/// Record that the planner declined a gate.
#[inline]
pub(crate) fn bump_gate_plan_declines() {
    PLAN_DECLINES.with(|c| c.set(c.get().wrapping_add(1)));
}

/// How many gates this thread's planner has declined as uneconomic.
///
/// Test-only: nothing in a release build reads it.
///
/// A decline is invisible in an answer -- that is the point -- so without a
/// counter the only evidence that the planner did anything is peak memory,
/// which a test cannot assert on portably.
#[cfg(test)]
pub(crate) fn gate_plan_declines() -> u64 {
    PLAN_DECLINES.with(Cell::get)
}

/// Zero this thread's declined-gate counter. Test-only, like its reader.
#[cfg(test)]
pub(crate) fn reset_gate_plan_declines() {
    PLAN_DECLINES.with(|c| c.set(0));
}

thread_local! {
    static GATE_ENABLED: Cell<bool> = const { Cell::new(true) };
}

/// Is the join-gate DRIVER on for this thread? On unless
/// [`set_join_gate_enabled`] turned it off.
///
/// With it off, an aggregate carrying either kind of gate — a `join.overlap`
/// broad phase (§5.5.6) or a value-equality `join.on` match set (§5.5.8) — walks
/// the untouched full product and lets the `filter` decide, which is exactly the
/// pre-driver path. That is what makes the driver's central claim DIRECTLY
/// testable rather than by analogy: the same document, same build, gate on vs
/// gate off, must give bit-identical numbers. It is also how the before/after
/// benchmark measures a "before" that is the real engine on the real document
/// rather than a hand-written stand-in.
///
/// Thread-local rather than process-wide, so one test process can measure both
/// arms — and an ARGUMENT rather than an environment switch, because a switch
/// that selects an evaluation strategy is the thing `esm-libraries-spec.md`
/// §2.5.10 refuses to keep beside `compiler`.
pub fn join_gate_enabled() -> bool {
    GATE_ENABLED.with(Cell::get)
}

/// Turn the join-gate driver on/off for THIS thread, returning the previous
/// setting so a caller can restore it.
pub fn set_join_gate_enabled(on: bool) -> bool {
    GATE_ENABLED.with(|c| c.replace(on))
}

/// How many candidate PAIRS the join-gate index caches may keep resident
/// (`ESS_GATE_CACHE_PAIRS`, default [`DEFAULT_GATE_CACHE_PAIRS`]), across both
/// the spatial-overlap cache and the value-equality one.
///
/// Counted in PAIR-EQUIVALENTS of [`GATE_PAIR_BYTES`], not in rows of the match
/// set: an index also owns its run table and, once a `Side::Tgt` walk has
/// touched it, its `tgt` adjacency, and a budget that ignored those would bound
/// a number rather than the memory. See [`OverlapIndex::resident_pairs`].
///
/// A gate index is memoized so that a node resolved once per evaluation is not
/// rebuilt per cell. Retaining every index a run ever built is a different
/// thing, and it made peak memory track the sum of every match set rather than
/// the largest one (issue #418). The budget bounds that; the cache evicts
/// least-recently-used, evicts BEFORE it builds the replacement, and trims to
/// the budget at every PROBE — so a gate that only ever HITS, the steady state
/// of an RHS in a time loop, is bounded too.
///
/// Denominated in pairs rather than entries because entries differ by orders of
/// magnitude: a six-cell regrid geometry and a fifty-million-pair star join are
/// both one entry.
///
/// Like [`join_gate_enabled`], this can only change a document's COST. A gate
/// is a pure optimisation — the driver may decline one outright and the lowered
/// `filter` then computes the same answer over the full product — and a rebuilt
/// index is the same pure function of the same key columns.
///
/// Thread-local (seeded from the environment once) rather than a process-wide
/// `OnceLock`, so one test process can measure both arms.
pub fn gate_cache_pair_budget() -> usize {
    GATE_CACHE_PAIRS.with(|c| match c.get() {
        Some(v) => v,
        None => {
            let v = gate_cache_budget_env();
            c.set(Some(v));
            v
        }
    })
}

/// What ONE candidate pair costs in an [`OverlapIndex`]'s two columns, and so
/// the unit the gate-cache budget is denominated in. Everything else an index
/// owns is priced against it by [`OverlapIndex::resident_pairs`].
pub const GATE_PAIR_BYTES: usize = 2 * size_of::<i64>();

/// The default resident-pair budget: 64 MB of [`OverlapIndex`] per cache,
/// comfortably above every gate in the corpus and far below the multi-gigabyte
/// match sets a relational port resolves.
pub const DEFAULT_GATE_CACHE_PAIRS: usize = 4_000_000;

/// The budget as the environment sets it (`ESS_GATE_CACHE_PAIRS`). A TUNING
/// THRESHOLD, not a strategy switch: under `native` it is a refusal boundary
/// rather than a fallback trigger (`esm-libraries-spec.md` §2.5.10), and
/// moving it changes what a document costs, never what it answers.
fn gate_cache_budget_env() -> usize {
    static N: std::sync::OnceLock<usize> = std::sync::OnceLock::new();
    *N.get_or_init(|| {
        std::env::var("ESS_GATE_CACHE_PAIRS")
            .ok()
            .and_then(|v| v.trim().parse::<usize>().ok())
            .unwrap_or(DEFAULT_GATE_CACHE_PAIRS)
    })
}

thread_local! {
    static GATE_CACHE_PAIRS: Cell<Option<usize>> = const { Cell::new(None) };
}

/// How far a gate is allowed to overshoot the pair-space it could narrow
/// before the planner declines to build it (`ESS_GATE_PLAN_RATIO`, default
/// [`DEFAULT_GATE_PLAN_RATIO`]).
///
/// A TUNING THRESHOLD, and under `native` a refusal boundary rather than a
/// fallback trigger (`esm-libraries-spec.md` §2.5.10): moving it changes which
/// documents build and what they cost, never what they answer.
///
/// A gate's cost is its match count; its value is the product of the two
/// symbols' ranges, as narrowed by the gates already resolved. When a clause
/// would materialise far more pairs than the space it is pruning, it cannot
/// pay for itself: an equality on a SIX-VALUED key against a 1.4-million-row
/// table matches 167 million pairs while a sibling clause has already cut that
/// table to seven rows, so the gate spends gigabytes to narrow 4,592 tuples.
///
/// Declining is safe for the same reason [`join_gate_enabled`] is: `crate::join`
/// also lowers every `on` clause into the node's `filter`, so the equality is
/// applied either way and only the enumeration order changes.
pub(crate) fn gate_plan_ratio() -> u128 {
    GATE_PLAN_RATIO.with(|c| match c.get() {
        Some(v) => v,
        None => {
            let v = *gate_plan_ratio_env();
            c.set(Some(v));
            v
        }
    })
}

/// The ratio as the environment sets it, read once for the process — the
/// caching every other threshold uses, so a thread that reaches the knob first
/// cannot see a different value from one that reaches it later.
fn gate_plan_ratio_env() -> &'static u128 {
    static RATIO: std::sync::OnceLock<u128> = std::sync::OnceLock::new();
    RATIO.get_or_init(|| env_u128("ESS_GATE_PLAN_RATIO", DEFAULT_GATE_PLAN_RATIO))
}

/// A gate smaller than this is never declined, whatever the ratio says
/// (`ESS_GATE_PLAN_FLOOR`, default [`DEFAULT_GATE_PLAN_FLOOR`]).
///
/// A TUNING THRESHOLD on the same footing as [`gate_plan_ratio`], and a
/// refusal boundary under `native` for the same reason.
///
/// The planner's estimate of what a gate narrows is an UPPER BOUND computed
/// from sibling gates, not from the walk that will actually run, so it can be
/// pessimistic. The floor keeps that pessimism away from small gates, where
/// being wrong costs a slow full-product walk and being right saves a few
/// megabytes. Only a gate that is both uneconomic AND large is declined.
pub(crate) fn gate_plan_floor() -> usize {
    GATE_PLAN_FLOOR.with(|c| match c.get() {
        Some(v) => v,
        None => {
            let v = *gate_plan_floor_env();
            c.set(Some(v));
            v
        }
    })
}

/// The floor as the environment sets it, read once for the process — see
/// [`gate_plan_ratio_env`].
fn gate_plan_floor_env() -> &'static usize {
    static FLOOR: std::sync::OnceLock<usize> = std::sync::OnceLock::new();
    FLOOR.get_or_init(|| {
        usize::try_from(env_u128(
            "ESS_GATE_PLAN_FLOOR",
            DEFAULT_GATE_PLAN_FLOOR as u128,
        ))
        .unwrap_or(usize::MAX)
    })
}

/// Four: a gate may cost up to four times the tuples it prunes.
pub(crate) const DEFAULT_GATE_PLAN_RATIO: u128 = 4;

/// One million pairs — about 16 MB of index, below which declining is not
/// worth the risk of a slower walk.
pub(crate) const DEFAULT_GATE_PLAN_FLOOR: usize = 1_000_000;

fn env_u128(name: &str, default: u128) -> u128 {
    std::env::var(name)
        .ok()
        .and_then(|v| v.trim().parse::<u128>().ok())
        .unwrap_or(default)
}

thread_local! {
    static GATE_PLAN_RATIO: Cell<Option<u128>> = const { Cell::new(None) };
    static GATE_PLAN_FLOOR: Cell<Option<usize>> = const { Cell::new(None) };
}

/// Set the planner's overshoot ratio and floor for THIS thread, returning the
/// previous pair so a caller can restore them. Test-only: a release build
/// configures the planner through `ESS_GATE_PLAN_RATIO` /
/// `ESS_GATE_PLAN_FLOOR`. A floor of 0 with a ratio of 0
/// declines every gate a sibling has already made redundant, which is the arm
/// a differential test runs to show that planning changes cost and not answers.
#[cfg(test)]
pub(crate) fn set_gate_plan(ratio: u128, floor: usize) -> (u128, usize) {
    let prev = (gate_plan_ratio(), gate_plan_floor());
    GATE_PLAN_RATIO.with(|c| c.set(Some(ratio)));
    GATE_PLAN_FLOOR.with(|c| c.set(Some(floor)));
    prev
}

/// Set the resident-pair budget for THIS thread, returning the previous
/// setting so a caller can restore it. `0` retains nothing beyond the indices
/// a live gate is holding — every evaluation rebuilds — which is the arm a
/// differential test runs to show that eviction changes cost and not answers.
/// [`gate_index_builds`] is how that test reads the cost it changed.
pub fn set_gate_cache_pair_budget(pairs: usize) -> usize {
    let prev = gate_cache_pair_budget();
    GATE_CACHE_PAIRS.with(|c| c.set(Some(pairs)));
    prev
}

/// Which side of an overlap gate a position lives on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Side {
    /// The `src_env` (QUERY) side.
    Src,
    /// The `tgt_env` (INDEXED / cell) side.
    Tgt,
}

/// The candidate pair set of a join GATE — the broad-phase set of an OVERLAP
/// gate (§5.5.6) or the match set of a value-equality `on` gate (§5.5.8) —
/// together with the DERIVED views the candidate-driven enumerator reads:
///
///   * the raw `(pos_src, pos_tgt)` membership set (the `in` test);
///   * the same pairs ASCENDING — the pair drive order;
///   * one side's position ⇒ its SORTED partner positions on the other side,
///     the drive order used when the aggregate has already bound one gated axis
///     (a per-output-cell dense aggregate).
///
/// Positions are **1-based**, matching the enumeration bindings (an index-set
/// range resolves to `[1, N]`, and `vi_range_values` binds position `p` to `p`).
///
/// # What it costs, and why that is the shape it is (issue #418)
///
/// A gate index is RESIDENT for as long as its cache entry is, and a star-join
/// aggregate's match set is orders of magnitude larger than either the arrays
/// the document declares or the answer it produces — a 105,449-row fact table
/// joined 1:many against a 1,000-row output relation is millions of candidate
/// pairs. The three derived views above are therefore stored as ONE pair
/// sequence plus at most one lazily-built adjacency, never as four independent
/// copies of the pair set:
///
///   * The pairs live as two PARALLEL COLUMNS (`src`, `tgt`), ascending by
///     `(src, tgt)` and duplicate-free — 16 B/pair, the irreducible content.
///   * The `src` adjacency is FREE. Pairs sharing a left position are a
///     CONTIGUOUS RUN of `src`, so that position's ascending partners are the
///     matching subslice of `tgt` — the `&[i64]` [`Self::partners`] hands back
///     with nothing stored for it.
///   * Membership is a lookup of that run followed by one binary search inside
///     it, not a probe into a `HashSet` of the pairs. A hash set is another
///     ~16 B/pair of payload plus its load-factor slack; [`SrcRuns`], which
///     finds the run in O(1), is 4 B per POSITION — for the star joins this is
///     about, orders of magnitude less, since a position carries many pairs.
///   * The `tgt` adjacency is the one direction that is NOT a subslice of
///     anything (pairs sharing a right position are scattered through the
///     `(src, tgt)` order), so it is materialised as a compressed [`Csr`] — and
///     LAZILY, on the first `Side::Tgt` query. Which direction a walk uses is
///     fixed by the aggregate's binding order, so the overwhelmingly common
///     case builds one direction and pays nothing for the other. It cannot be
///     chosen statically instead: an index is memoized across nodes, and a
///     later node may drive the other way.
///
/// Measured on issue #418's `join-aggregate-scaling.esm`, that is ~16 B/pair
/// resident where the four-copy form was ~80.
///
/// The derived views are built at most ONCE per index, never per cell. A gate
/// is resolved once per node but consulted once per output cell, so rebuilding
/// an adjacency per cell would reinstate exactly the `O(N_tgt·N_src)` cost the
/// driver removes.
#[derive(Debug, Clone, Default)]
pub struct OverlapIndex {
    /// Left positions, ascending by `(src, tgt)` with `tgt` and duplicate-free.
    src: Vec<i64>,
    /// Right positions, parallel to `src`.
    tgt: Vec<i64>,
    /// O(1) run lookup into `src`, when its position span admits one.
    src_runs: Option<SrcRuns>,
    /// The `tgt`⇒`src` adjacency, built on first use. [`std::sync::OnceLock`]
    /// rather than a `Cell` so the index keeps its auto traits: it is public
    /// API, and `Send`/`Sync` are not ours to withdraw.
    by_tgt: OnceLock<Csr>,
}

/// Run boundaries for the `src` column: which slice of the two columns holds
/// the pairs of a given left position.
///
/// Why this exists rather than a binary search over `src`: finding the run is
/// the whole of [`OverlapIndex::contains`], which the "both gated symbols
/// already bound" arm of [`overlap_drive_plan`] takes ONCE PER OUTPUT CELL. On
/// a 3000×3000 output over a 30,000-pair gate — nine million membership tests —
/// a `partition_point` over `src` is ~15 dependent L2 loads each and measured
/// 38% slower end to end than the hash set this representation removed, where
/// a lookup in constant time brings it back to a couple of loads and the change
/// is in the noise.
///
/// Both variants are that constant-time lookup; they differ only in which is
/// cheaper to STORE, and the choice is made per index from the shape of its
/// `src` column. Both are bounded at about what the pairs themselves cost —
/// the dense one by its span factor, the hashed one by the distinct-position
/// count — so the accelerator never dominates what it accelerates.
#[derive(Debug, Clone)]
enum SrcRuns {
    /// Direct-addressed by position: `starts[k]` is the number of pairs whose
    /// left position is below `lo + k`, so position `p`'s pairs are
    /// `starts[p - lo] .. starts[p - lo + 1]`.
    ///
    /// 4 B per POSITION IN THE SPAN, not per pair, which for a join whose point
    /// is that positions carry many pairs is the cheap direction to pay in.
    Dense { lo: i64, starts: Vec<u32> },
    /// Hashed by position, for a span too sparse to address directly — `lo`
    /// and `hi` far apart with few positions between, which is the normal shape
    /// of a SELECTIVE gate over a wide fact table (ten million pairs scattered
    /// over fifty million positions declines the dense table).
    ///
    /// The alternative for that shape is the binary search this type exists to
    /// avoid, and a selective gate over a wide table is precisely where the
    /// membership test runs most often. So it is stored instead as one entry
    /// per DISTINCT left position: ~17 B each, bounded by the PAIR count rather
    /// than by the span, which is about what [`SrcRuns::Dense`] is already
    /// allowed to spend and strictly less than the set this representation
    /// removed — that one held an entry per PAIR.
    Sparse(FxHashMap<i64, (u32, u32)>),
}

/// A compressed adjacency list: `keys` ascending and duplicate-free, and the
/// partners of `keys[k]` are `partners[offsets[k]..offsets[k + 1]]`, themselves
/// ascending.
///
/// The `HashMap<i64, Vec<i64>>` this replaces cost a 24-byte `Vec` header, the
/// map's own bucket slack and a separate heap allocation PER DISTINCT KEY, plus
/// push-doubling slack on every one of those little vectors. Over a dense
/// position space that is a CSR list in disguise; written as one, it is
/// 8 B/pair with the keys' 12 B/key on top and one allocation for the lot.
#[derive(Debug, Clone)]
struct Csr {
    keys: Vec<i64>,
    offsets: Vec<usize>,
    partners: Vec<i64>,
}

const NO_PARTNERS: &[i64] = &[];

impl SrcRuns {
    /// How many times larger than the pair count a position span may be before
    /// a dense run table stops being worth its memory. Generous, because the
    /// table is 4 B where a pair is 16: a span four times the pair count still
    /// costs less than the pairs do.
    const MAX_SPAN_FACTOR: usize = 4;

    /// Run boundaries for an ascending `src` column, dense where the span
    /// admits it and hashed where it does not.
    ///
    /// `None` only when there is nothing to index, or when the pair count
    /// exceeds what a `u32` boundary can address — four billion pairs, which
    /// is 64 GB of columns before this table is considered at all. That case
    /// alone leaves [`OverlapIndex::src_run`] on its binary search.
    fn build(src: &[i64]) -> Option<SrcRuns> {
        let (&lo, &hi) = (src.first()?, src.last()?);
        if src.len() > u32::MAX as usize {
            return None;
        }
        let span = hi
            .checked_sub(lo)
            .and_then(|d| d.checked_add(1))
            .and_then(|s| usize::try_from(s).ok());
        match span {
            Some(span) if span <= Self::MAX_SPAN_FACTOR * src.len() + 1024 => {
                let mut starts = vec![0u32; span + 1];
                for &p in src {
                    starts[(p - lo) as usize + 1] += 1;
                }
                for k in 0..span {
                    starts[k + 1] += starts[k];
                }
                Some(SrcRuns::Dense { lo, starts })
            }
            // One entry per distinct position, found by walking the runs the
            // ascending column already lays out contiguously.
            _ => {
                let mut runs: FxHashMap<i64, (u32, u32)> = FxHashMap::default();
                let mut i = 0usize;
                while i < src.len() {
                    let p = src[i];
                    let mut j = i + 1;
                    while j < src.len() && src[j] == p {
                        j += 1;
                    }
                    runs.insert(p, (i as u32, j as u32));
                    i = j;
                }
                runs.shrink_to_fit();
                Some(SrcRuns::Sparse(runs))
            }
        }
    }

    /// The half-open pair range of left position `pos`; empty when it has none.
    #[inline]
    fn run(&self, pos: i64) -> (usize, usize) {
        match self {
            SrcRuns::Dense { lo, starts } => {
                let Some(k) = pos.checked_sub(*lo) else {
                    return (0, 0);
                };
                if k < 0 || k as usize + 1 >= starts.len() {
                    return (0, 0);
                }
                let k = k as usize;
                (starts[k] as usize, starts[k + 1] as usize)
            }
            SrcRuns::Sparse(runs) => runs
                .get(&pos)
                .map_or((0, 0), |&(a, b)| (a as usize, b as usize)),
        }
    }

    /// Bytes this table holds resident. The hashed variant's entry is its key
    /// and value plus hashbrown's one control byte, counted over the ALLOCATED
    /// capacity rather than the live entry count.
    fn resident_bytes(&self) -> usize {
        match self {
            SrcRuns::Dense { starts, .. } => starts.capacity() * size_of::<u32>(),
            SrcRuns::Sparse(runs) => runs.capacity() * (size_of::<(i64, (u32, u32))>() + 1),
        }
    }
}

impl Csr {
    /// Bytes this adjacency holds resident.
    fn resident_bytes(&self) -> usize {
        self.keys.capacity() * size_of::<i64>()
            + self.offsets.capacity() * size_of::<usize>()
            + self.partners.capacity() * size_of::<i64>()
    }

    /// The ascending partners of `key`, empty when it has none.
    #[inline]
    fn partners_of(&self, key: i64) -> &[i64] {
        match self.keys.binary_search(&key) {
            Ok(k) => &self.partners[self.offsets[k]..self.offsets[k + 1]],
            Err(_) => NO_PARTNERS,
        }
    }
}

impl OverlapIndex {
    /// Build the index from 0-based broad-phase pairs (as
    /// [`broad_phase_candidates`] returns them), shifting to the 1-based range
    /// positions the enumeration bindings use.
    pub fn from_zero_based(pairs: &[(usize, usize)]) -> Self {
        Self::from_owned_pairs(
            pairs
                .iter()
                .map(|&(q, c)| (q as i64 + 1, c as i64 + 1))
                .collect(),
        )
    }

    /// Build the index from pairs that are ALREADY range positions — the
    /// value-equality (`join.on`) gate's shape, whose match set is expressed in
    /// the loop symbols' own values rather than in 0-based envelope offsets
    /// (CONFORMANCE_SPEC.md §5.5.8). An `on` key column over an interval range
    /// `[lo, hi]` is keyed by the symbol VALUE, not by an offset, which is why
    /// this constructor takes the positions verbatim.
    ///
    /// The two constructors produce the identical structure; only the position
    /// convention of the input differs.
    pub fn from_pairs(pairs: &[(i64, i64)]) -> Self {
        Self::from_owned_pairs(pairs.to_vec())
    }

    /// [`Self::from_pairs`] taking OWNERSHIP of the match set.
    ///
    /// The caller has just materialised one `(i64, i64)` per pair and has no
    /// further use for it; sorting that vector in place and moving its contents
    /// into the two columns is one 16 B/pair copy where `from_pairs(&v)` is two
    /// (the caller's, plus this one), which on a multi-million-pair join is the
    /// difference between a transient that fits and one that does not.
    pub fn from_owned_pairs(mut pairs: Vec<(i64, i64)>) -> Self {
        pairs.sort_unstable();
        pairs.dedup();
        let mut src = Vec::with_capacity(pairs.len());
        let mut tgt = Vec::with_capacity(pairs.len());
        for (l, r) in pairs {
            src.push(l);
            tgt.push(r);
        }
        let src_runs = SrcRuns::build(&src);
        OverlapIndex {
            src,
            tgt,
            src_runs,
            by_tgt: OnceLock::new(),
        }
    }

    /// The half-open index range of the pairs whose LEFT position is `pos` —
    /// a contiguous run, because the columns ascend by `(src, tgt)`. Read off
    /// [`SrcRuns`] in O(1), which every index has one of but for the empty one
    /// and the one with more pairs than a `u32` can address; those alone take
    /// the binary search.
    #[inline]
    fn src_run(&self, pos: i64) -> (usize, usize) {
        if let Some(r) = &self.src_runs {
            return r.run(pos);
        }
        let start = self.src.partition_point(|&p| p < pos);
        let end = self.src[start..].partition_point(|&p| p == pos) + start;
        (start, end)
    }

    /// Is `(pos_src, pos_tgt)` a candidate pair?
    ///
    /// `pos_src`'s run, then a binary search for `pos_tgt` within that run's
    /// ascending partners — in place of a hash probe against a set that
    /// duplicated the pairs. See [`SrcRuns`] for what makes the first step O(1)
    /// and why it has to be.
    #[inline]
    pub fn contains(&self, src: i64, tgt: i64) -> bool {
        let (a, b) = self.src_run(src);
        self.tgt[a..b].binary_search(&tgt).is_ok()
    }

    /// Number of candidate pairs.
    pub fn len(&self) -> usize {
        self.src.len()
    }

    /// Everything this index holds resident, in PAIR-EQUIVALENTS: bytes over
    /// [`GATE_PAIR_BYTES`], what one pair costs in the two columns.
    ///
    /// [`Self::len`] is the wrong denominator for a memory budget, because the
    /// columns are not all an index owns. A [`SrcRuns::Dense`] table is up to a
    /// further 16 B/pair (its span may reach `4 * pairs + 1024`), and once any
    /// `Side::Tgt` walk touches the index its lazily built adjacency adds
    /// 8 B/pair plus 16 B per distinct right position. An index priced at
    /// `len()` can therefore be ~2.5x the size the budget believes it to be,
    /// which for a knob whose whole purpose is bounding memory is the one error
    /// that matters.
    ///
    /// Read afresh on every cache probe rather than cached, precisely because
    /// the `tgt` adjacency appears LATER than the insert that priced it.
    pub fn resident_pairs(&self) -> usize {
        self.resident_bytes().div_ceil(GATE_PAIR_BYTES)
    }

    fn resident_bytes(&self) -> usize {
        (self.src.capacity() + self.tgt.capacity()) * size_of::<i64>()
            + self.src_runs.as_ref().map_or(0, SrcRuns::resident_bytes)
            + self.by_tgt.get().map_or(0, Csr::resident_bytes)
    }

    /// Is the candidate set empty?
    pub fn is_empty(&self) -> bool {
        self.src.is_empty()
    }

    /// The candidate pairs ascending by `(pos_src, pos_tgt)`.
    ///
    /// An iterator rather than a `&[(i64, i64)]`: the pairs are stored as two
    /// columns, and rebuilding an interleaved copy to hand out a slice would
    /// reinstate the 16 B/pair this representation exists to avoid. Both
    /// callers walk it once.
    pub fn pairs(&self) -> impl ExactSizeIterator<Item = (i64, i64)> + '_ {
        self.src.iter().copied().zip(self.tgt.iter().copied())
    }

    /// Build the `tgt`⇒`src` adjacency. Called at most once per index, from
    /// [`Self::partners`]'s `Side::Tgt` arm.
    fn build_by_tgt(&self) -> Csr {
        let mut keys = self.tgt.clone();
        keys.sort_unstable();
        keys.dedup();
        keys.shrink_to_fit(); // the dedup left the full 8 B/pair allocation
        let mut offsets = vec![0usize; keys.len() + 1];
        for &r in &self.tgt {
            // `binary_search` cannot fail: every `tgt` value is one of `keys`.
            if let Ok(k) = keys.binary_search(&r) {
                offsets[k + 1] += 1;
            }
        }
        for k in 0..keys.len() {
            offsets[k + 1] += offsets[k];
        }
        let mut partners = vec![0i64; self.tgt.len()];
        let mut fill = offsets.clone();
        // Walking the columns in `(src, tgt)` order fills each key's slot run
        // in ascending `src` order, which is the ordering `partners` promises.
        for (l, r) in self.pairs() {
            if let Ok(k) = keys.binary_search(&r) {
                partners[fill[k]] = l;
                fill[k] += 1;
            }
        }
        Csr {
            keys,
            offsets,
            partners,
        }
    }

    /// The SORTED partner positions of `pos` on the side opposite `side`
    /// (`side` names the side `pos` itself lives on). Empty when it has none.
    pub fn partners(&self, side: Side, pos: i64) -> &[i64] {
        match side {
            Side::Src => {
                let (a, b) = self.src_run(pos);
                &self.tgt[a..b]
            }
            Side::Tgt => self
                .by_tgt
                .get_or_init(|| self.build_by_tgt())
                .partners_of(pos),
        }
    }

    /// [`Self::partners`] restricted to the inclusive range `[lo, hi]`, still
    /// ascending — the contiguous subslice a driven inner loop walks in place of
    /// its own range. No copy (see [`restrict_to_range`]).
    pub fn partners_in(&self, side: Side, pos: i64, lo: i64, hi: i64) -> &[i64] {
        restrict_to_range(self.partners(side, pos), lo, hi)
    }

    /// Has the lazy `tgt` adjacency been built? Test-only: the claim that a
    /// `Side::Src` walk pays nothing for the other direction is a property of
    /// this flag, not of a memory measurement.
    #[cfg(test)]
    pub(crate) fn tgt_adjacency_built(&self) -> bool {
        self.by_tgt.get().is_some()
    }
}

/// How an overlap gate drives an enumeration — the shared decision the
/// value-invention producer and the dense aggregate expansion both apply.
#[derive(Debug, Clone, PartialEq)]
pub enum DrivePlan<'a> {
    /// Do not drive; walk the full product (and let the membership test filter).
    Full,
    /// Both gated symbols are already bound and the pair is NOT a candidate:
    /// no leaf is admitted at all. The output position takes the semiring
    /// identity (§5.5.6 "Identity fill").
    Reject,
    /// Both gated symbols are free: bind them from the candidate PAIRS, then
    /// take the cartesian product with any ungated ranges.
    Pairs,
    /// One gated symbol is free and the other is already bound: the free one
    /// enumerates only `vals` — its bound partner's candidates, restricted to
    /// its own range and ASCENDING, i.e. the exact order-preserving
    /// subsequence of the range it would otherwise have walked. Borrowed from
    /// the index: a plan is computed once per OUTPUT CELL, and an owned list
    /// here was a measurable per-cell allocation.
    Restrict {
        /// `true` when the free symbol is the `src_env` side.
        free_is_src: bool,
        /// The admitted values, ascending.
        vals: &'a [i64],
    },
}

/// `parts` restricted to the inclusive integer range `[lo, hi]`, ASCENDING.
///
/// Preserving the SUBSEQUENCE (not merely the set) is what makes the driven
/// walk BIT-IDENTICAL to the filtered full product: the terms it drops are
/// exactly the gate-rejected ones, in the same relative order, and each of
/// those contributes the semiring identity. A dense contraction range is always
/// an ascending contiguous interval (`RangeSpec::bounds` yields `[lo, hi]` and
/// the evaluator walks `lo..=hi`), so unlike the Julia reference — whose
/// `contract_iters` may be arbitrary integer vectors and which therefore has to
/// PROVE 1-stridedness before it may restrict — there is nothing here that can
/// fail to be order-preserving. And because `parts` is itself ascending, the
/// restriction is a CONTIGUOUS subslice — found by binary search, no copy.
fn restrict_to_range(parts: &[i64], lo: i64, hi: i64) -> &[i64] {
    let start = parts.partition_point(|&p| p < lo);
    // `.max(start)` is what makes an EMPTY range (`hi < lo`) admit nothing
    // rather than panic on an inverted slice: the two partition points cross
    // when every value falls in the gap between `hi` and `lo`.
    let end = parts.partition_point(|&p| p <= hi).max(start);
    &parts[start..end]
}

/// Decide how an overlap gate drives an enumeration.
///
/// `src_bound` / `tgt_bound` give each gated symbol's already-bound position
/// (`None` when the symbol is still FREE, i.e. to be enumerated), and
/// `free_range` gives the free symbol's own inclusive `(lo, hi)` bounds — it is
/// consulted only for the [`DrivePlan::Restrict`] shape.
pub fn overlap_drive_plan(
    index: &OverlapIndex,
    src_bound: Option<i64>,
    tgt_bound: Option<i64>,
    free_range: Option<(i64, i64)>,
) -> DrivePlan<'_> {
    match (src_bound, tgt_bound) {
        // Both free ⇒ drive from the sorted candidate pairs.
        (None, None) => DrivePlan::Pairs,
        // Both bound ⇒ a single membership test.
        (Some(l), Some(r)) => {
            if index.contains(l, r) {
                DrivePlan::Full
            } else {
                DrivePlan::Reject
            }
        }
        // One bound, one free ⇒ the free one walks its partner list.
        (Some(l), None) => match free_range {
            Some((lo, hi)) => DrivePlan::Restrict {
                free_is_src: false,
                vals: restrict_to_range(index.partners(Side::Src, l), lo, hi),
            },
            None => DrivePlan::Full,
        },
        (None, Some(r)) => match free_range {
            Some((lo, hi)) => DrivePlan::Restrict {
                free_is_src: true,
                vals: restrict_to_range(index.partners(Side::Tgt, r), lo, hi),
            },
            None => DrivePlan::Full,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ndarray::IxDyn;
    use std::collections::BTreeMap;

    fn arr(shape: &[usize], data: Vec<f64>) -> ArrayD<f64> {
        ArrayD::from_shape_vec(IxDyn(shape), data).expect("shape matches data")
    }

    fn ca(pairs: Vec<(&str, ArrayD<f64>)>) -> HashMap<String, ArrayD<f64>> {
        pairs.into_iter().map(|(k, v)| (k.to_string(), v)).collect()
    }

    fn names(ns: &[&str]) -> Vec<String> {
        ns.iter().map(|s| s.to_string()).collect()
    }

    /// The point-in-rectangle micro fixture from the Julia
    /// `overlap_gate_conformance_test.jl`: 5 points × 4 cells, whose closed
    /// broad-phase candidate set is exactly `{(0,0),(1,1),(2,0),(2,1),(4,2),(4,3)}`
    /// (0-based here; `{(1,1),(2,2),(3,1),(3,2),(5,3),(5,4)}` 1-based in Julia).
    fn pir_envelopes() -> (Vec<Envelope>, Vec<Envelope>) {
        let arrays = ca(vec![
            ("X", arr(&[5], vec![1.0, 3.0, 2.0, 10.0, 6.0])),
            ("Y", arr(&[5], vec![1.0, 3.0, 2.0, 10.0, 6.0])),
            ("W", arr(&[4], vec![0.0, 2.0, 4.0, 6.0])),
            ("S", arr(&[4], vec![0.0, 2.0, 4.0, 6.0])),
            ("E", arr(&[4], vec![2.0, 4.0, 6.0, 8.0])),
            ("N", arr(&[4], vec![2.0, 4.0, 6.0, 8.0])),
        ]);
        let src = envelope_vectors(&names(&["X", "Y"]), &arrays).unwrap();
        let tgt = envelope_vectors(&names(&["W", "S", "E", "N"]), &arrays).unwrap();
        (src, tgt)
    }

    #[test]
    fn point_in_rect_candidate_set_matches_julia_golden() {
        let (src, tgt) = pir_envelopes();
        let got = broad_phase_candidates(&src, &tgt, 0.0);
        // 0-based analogue of the Julia golden {(1,1),(2,2),(3,1),(3,2),(5,3),(5,4)}.
        assert_eq!(got, vec![(0, 0), (1, 1), (2, 0), (2, 1), (4, 2), (4, 3)]);
    }

    #[test]
    fn rstar_equals_bruteforce_on_pir() {
        let (src, tgt) = pir_envelopes();
        for &eps in &[0.0, 0.5, 1.0, 2.5] {
            assert_eq!(
                broad_phase_candidates(&src, &tgt, eps),
                broad_phase_candidates_bruteforce(&src, &tgt, eps),
                "rstar != brute-force at eps={eps}"
            );
        }
    }

    #[test]
    fn conservativeness_and_monotonicity_in_eps() {
        let (src, tgt) = pir_envelopes();
        let c0 = broad_phase_candidates(&src, &tgt, 0.0);
        let c1 = broad_phase_candidates(&src, &tgt, 1.0);
        // eps grows the candidate set (superset).
        for pair in &c0 {
            assert!(
                c1.contains(pair),
                "eps=1 dropped a eps=0 candidate {pair:?}"
            );
        }
        assert!(c1.len() >= c0.len());
        // The true strict containments (p0∈c0, p1∈c1) are always candidates.
        assert!(c0.contains(&(0, 0)));
        assert!(c0.contains(&(1, 1)));
    }

    #[test]
    fn rstar_equals_bruteforce_random_stress() {
        // A deterministic LCG driving a spread of rectangles; rstar and the
        // brute-force oracle must agree pair-for-pair at several eps.
        let mut state: u64 = 0x9E3779B97F4A7C15;
        let mut next = || {
            state = state
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            ((state >> 33) as f64) / (1u64 << 31) as f64 // in [0, 1)
        };
        let mk = |n: usize, next: &mut dyn FnMut() -> f64| -> Vec<Envelope> {
            (0..n)
                .map(|_| {
                    let x0 = next() * 10.0;
                    let y0 = next() * 10.0;
                    let w = next() * 2.0;
                    let h = next() * 2.0;
                    [x0, y0, x0 + w, y0 + h]
                })
                .collect()
        };
        let query = mk(40, &mut next);
        let cells = mk(60, &mut next);
        for &eps in &[0.0, 0.1, 0.75, 3.0] {
            assert_eq!(
                broad_phase_candidates(&query, &cells, eps),
                broad_phase_candidates_bruteforce(&query, &cells, eps),
                "rstar != brute-force at eps={eps}"
            );
        }
    }

    #[test]
    fn empty_inputs_yield_empty() {
        let some = vec![[0.0, 0.0, 1.0, 1.0]];
        assert!(broad_phase_candidates(&[], &some, 0.0).is_empty());
        assert!(broad_phase_candidates(&some, &[], 0.0).is_empty());
        assert!(broad_phase_candidates_bruteforce(&[], &some, 0.0).is_empty());
    }

    #[test]
    fn ring_envelope_arm_builds_aabb() {
        // Two triangles as [pos, verts, coord]: pos0 spans x∈[0,2] y∈[0,1],
        // pos1 spans x∈[3,5] y∈[2,4].
        let rings = arr(
            &[2, 3, 2],
            vec![
                0.0, 0.0, 2.0, 0.0, 1.0, 1.0, // pos0 verts
                3.0, 2.0, 5.0, 2.0, 4.0, 4.0, // pos1 verts
            ],
        );
        let arrays = ca(vec![("rings", rings)]);
        let envs = envelope_vectors(&names(&["rings"]), &arrays).unwrap();
        assert_eq!(envs, vec![[0.0, 0.0, 2.0, 1.0], [3.0, 2.0, 5.0, 4.0]]);
    }

    // ── OverlapIndex: the derived views (issue #418) ────────────────────────

    /// A deterministic pair multiset with duplicates, out of order, with left
    /// positions carrying many partners and gaps carrying none.
    fn stress_pairs() -> Vec<(i64, i64)> {
        let mut state: u64 = 0x2545_F491_4F6C_DD1D;
        let mut next = move || {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            state
        };
        (0..4000)
            .map(|_| {
                // Left positions are EVEN only, so every odd one is a miss.
                (2 * ((next() % 48) as i64 + 1), (next() % 53) as i64 + 1)
            })
            .collect()
    }

    /// The four-copy structure [`OverlapIndex`] replaced, kept as the oracle:
    /// a membership set and one `HashMap<i64, Vec<i64>>` per direction.
    #[allow(clippy::type_complexity)]
    fn naive(
        pairs: &[(i64, i64)],
    ) -> (
        std::collections::HashSet<(i64, i64)>,
        BTreeMap<i64, Vec<i64>>,
        BTreeMap<i64, Vec<i64>>,
    ) {
        let set: std::collections::HashSet<(i64, i64)> = pairs.iter().copied().collect();
        let mut by_src: BTreeMap<i64, Vec<i64>> = BTreeMap::new();
        let mut by_tgt: BTreeMap<i64, Vec<i64>> = BTreeMap::new();
        let mut sorted: Vec<(i64, i64)> = set.iter().copied().collect();
        sorted.sort_unstable();
        for (l, r) in sorted {
            by_src.entry(l).or_default().push(r);
            by_tgt.entry(r).or_default().push(l);
        }
        (set, by_src, by_tgt)
    }

    #[test]
    fn overlap_index_views_match_the_naive_pair_set() {
        let raw = stress_pairs();
        let (set, by_src, by_tgt) = naive(&raw);
        let ix = OverlapIndex::from_pairs(&raw);

        // The pair sequence is the deduped set, ascending.
        let mut want: Vec<(i64, i64)> = set.iter().copied().collect();
        want.sort_unstable();
        assert_eq!(ix.pairs().collect::<Vec<_>>(), want);
        assert_eq!(ix.len(), want.len());
        assert!(!ix.is_empty());

        // Membership, over hits AND misses (odd left positions are all misses).
        for l in 0..=100 {
            for r in 0..=60 {
                assert_eq!(
                    ix.contains(l, r),
                    set.contains(&(l, r)),
                    "membership disagrees at ({l}, {r})"
                );
            }
        }

        // Both adjacencies, including positions with no partners at all.
        const NONE: &[i64] = &[];
        for l in 0..=100 {
            assert_eq!(
                ix.partners(Side::Src, l),
                by_src.get(&l).map(Vec::as_slice).unwrap_or(NONE),
                "src partners disagree at {l}"
            );
        }
        for r in 0..=60 {
            assert_eq!(
                ix.partners(Side::Tgt, r),
                by_tgt.get(&r).map(Vec::as_slice).unwrap_or(NONE),
                "tgt partners disagree at {r}"
            );
        }
    }

    #[test]
    fn partners_in_is_the_contiguous_restriction_of_partners() {
        let ix = OverlapIndex::from_pairs(&stress_pairs());
        for pos in [2i64, 4, 50, 96] {
            for side in [Side::Src, Side::Tgt] {
                let all = ix.partners(side, pos);
                for (lo, hi) in [(0i64, 100i64), (10, 20), (30, 30), (40, 5)] {
                    let want: Vec<i64> = all
                        .iter()
                        .copied()
                        .filter(|&v| v >= lo && v <= hi)
                        .collect();
                    assert_eq!(ix.partners_in(side, pos, lo, hi), want.as_slice());
                }
            }
        }
    }

    /// The `src` adjacency is a subslice of the pair columns and the `tgt` one
    /// is not, so a walk that only ever binds the `src` side must not pay for
    /// the direction it never reads — the point of building it lazily.
    #[test]
    fn a_src_side_walk_never_builds_the_tgt_adjacency() {
        let ix = OverlapIndex::from_pairs(&stress_pairs());
        assert!(!ix.tgt_adjacency_built(), "built eagerly at construction");
        for l in 0..=100 {
            let _ = ix.partners(Side::Src, l);
            let _ = ix.partners_in(Side::Src, l, 1, 20);
            let _ = ix.contains(l, 3);
        }
        let _ = ix.pairs().count();
        assert!(
            !ix.tgt_adjacency_built(),
            "a src-only walk paid for the tgt direction"
        );
        let _ = ix.partners(Side::Tgt, 3);
        assert!(ix.tgt_adjacency_built());
    }

    #[test]
    fn the_three_constructors_agree() {
        let raw = stress_pairs();
        let from_ref = OverlapIndex::from_pairs(&raw);
        let owned = OverlapIndex::from_owned_pairs(raw.clone());
        assert_eq!(
            from_ref.pairs().collect::<Vec<_>>(),
            owned.pairs().collect::<Vec<_>>()
        );
        // `from_zero_based` shifts 0-based envelope offsets to 1-based positions.
        let zb: Vec<(usize, usize)> = vec![(0, 0), (2, 1), (0, 3)];
        assert_eq!(
            OverlapIndex::from_zero_based(&zb)
                .pairs()
                .collect::<Vec<_>>(),
            vec![(1, 1), (1, 4), (3, 2)]
        );
    }

    #[test]
    fn an_empty_index_has_no_partners_and_admits_nothing() {
        let ix = OverlapIndex::from_pairs(&[]);
        assert!(ix.is_empty());
        assert_eq!(ix.len(), 0);
        assert!(!ix.contains(1, 1));
        assert!(ix.partners(Side::Src, 1).is_empty());
        assert!(ix.partners(Side::Tgt, 1).is_empty());
        assert_eq!(ix.pairs().count(), 0);
    }

    /// A span too sparse for a dense run table is HASHED instead, and must
    /// answer identically: the table is a lookup accelerator and nothing else.
    ///
    /// The representation matters because of WHERE this shape occurs. A
    /// selective gate over a wide fact table — few pairs scattered over many
    /// positions — is the one that declines densification, and it is also the
    /// one whose membership test runs most often, since the "both gated symbols
    /// bound" arm of `overlap_drive_plan` takes it once per output cell.
    /// Leaving it on a binary search would put the 38% this representation was
    /// measured to save straight back on exactly that document.
    #[test]
    fn a_sparse_left_column_is_hashed_and_answers_the_same() {
        let sparse: Vec<(i64, i64)> = vec![(1, 2), (1, 5), (10_000_000, 3), (10_000_000, 5)];
        let ix = OverlapIndex::from_pairs(&sparse);
        assert!(
            matches!(ix.src_runs, Some(SrcRuns::Sparse(_))),
            "a 10-million-wide span over 4 pairs must not be densified, and must not \
             be left without a constant-time run lookup either"
        );
        let dense = OverlapIndex::from_pairs(&[(1, 2), (1, 5), (3, 3), (3, 5)]);
        assert!(
            matches!(dense.src_runs, Some(SrcRuns::Dense { .. })),
            "a tight span should be densified"
        );

        for (ix, hit, miss) in [(&ix, 10_000_000i64, 4_999_999i64), (&dense, 3i64, 2i64)] {
            assert!(ix.contains(1, 2) && ix.contains(hit, 5));
            assert!(!ix.contains(1, 3) && !ix.contains(miss, 5));
            assert!(!ix.contains(0, 2) && !ix.contains(i64::MAX, 2));
            assert_eq!(ix.partners(Side::Src, 1), &[2, 5]);
            assert_eq!(ix.partners(Side::Src, hit), &[3, 5]);
            assert!(ix.partners(Side::Src, miss).is_empty());
            assert_eq!(ix.partners(Side::Tgt, 5), &[1, hit]);
        }
    }

    /// What the hashed table costs is a function of the PAIRS, not of the span
    /// it declined to address — which is the whole reason it can be afforded
    /// where the dense one cannot. One entry per distinct left position, so it
    /// is also strictly smaller than the per-PAIR set this representation
    /// removed.
    #[test]
    fn a_hashed_run_table_costs_by_the_pairs_not_by_the_span() {
        const N: i64 = 1000;
        // 1000 pairs over a span of a billion: densifying would be 4 GB.
        let pairs: Vec<(i64, i64)> = (0..N).map(|i| (i * 1_000_000, i)).collect();
        let ix = OverlapIndex::from_owned_pairs(pairs);
        assert!(matches!(ix.src_runs, Some(SrcRuns::Sparse(_))));
        assert!(
            ix.resident_pairs() <= 4 * N as usize,
            "a sparse index must stay within a small constant of its PAIR count, \
             not of its span; it costs {} pair-equivalents for {N} pairs",
            ix.resident_pairs()
        );
        for i in 0..N {
            assert!(ix.contains(i * 1_000_000, i));
            assert!(!ix.contains(i * 1_000_000 + 1, i));
        }
    }
}
