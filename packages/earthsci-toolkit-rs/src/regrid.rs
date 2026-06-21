//! Conservative-regridding **assembly** — the end-to-end first-order
//! (area-weighted) regridder built from the `intersect_polygon` leaf and the
//! `polygon_area` FAQ (RFC `semiring-faq-unified-ir` §A.8 / §8.1;
//! CONFORMANCE_SPEC.md §5.8).
//!
//! The operation, verified piece-by-piece against `ConservativeRegridding.jl`
//! (§A.8), is
//!
//! ```text
//! F_tgt[j] = (1/A_j)·Σ_i A_ij·F_src[i],   A_ij = area(src_i ∩ tgt_j),   A_j = Σ_i A_ij
//! ```
//!
//! and decomposes into the five A.8 pieces, in realization order:
//!
//! 1. **Overlap pairs** `{(i, j) : A_ij > 0}` — the spatial (θ-) join. Its broad
//!    phase is expressed as a **bin-Skolem equi-join on integer spatial-bin keys**
//!    ([`ConservativeRegridder::build_binned`]): each cell's bbox is quantized to
//!    integer lat-lon bins via `floor`, and two cells are candidates iff their
//!    integer bin ranges overlap. Integer keys keep the **candidate set
//!    byte-identical** across bindings (§5.8.5) — no floating-point coordinate
//!    comparison enters the broad phase. STR-tree acceleration is an explicit perf
//!    follow-on (a physical-operator concern), out of scope here; the exhaustive
//!    [`ConservativeRegridder::build`] is the correctness baseline.
//! 2. **`A_ij`** — the [`crate::geometry::intersect_polygon`] kernel leaf + the
//!    [`crate::geometry::polygon_area`] `sum_product` FAQ (the narrow phase): one
//!    clip per candidate pair fills each entry of the build-once sparse
//!    overlap-area matrix (`ConservativeRegridding.jl`'s `intersections` of **raw**
//!    areas). A candidate that clips to a **sub-`atol` sliver** is treated as
//!    equal-to-zero (§5.8.2) and dropped — this is the §5.8.5
//!    *candidate set ≠ surviving-overlap set* boundary made explicit.
//! 3. **`A_j = Σ_i A_ij`** — the group-by-`j` row-sums (`dst_areas`).
//! 4. **apply `Σ_i A_ij·F_src[i]`** — the sparse mat-vec (`mul!(dst, …, src)`).
//! 5. **normalize `/A_j`** — elementwise (`dst ./= dst_areas`).
//!
//! Because the **same** computed areas feed both the apply numerator and the
//! `A_j` denominator, **partition-of-unity** `Σ_i W_ij = 1` (`W_ij = A_ij/A_j`)
//! holds **by construction** regardless of edge-model error (§5.8.3) — the
//! physically meaningful conformance gate, alongside global mass conservation
//! `Σ_j A_j·F_tgt[j] = Σ_i A_i·F_src[i]`.
//!
//! Cross-binding conformance for the areas / weights is **tolerance-based**
//! (FP clipping is not bit-identical) via [`crate::geometry::area_tolerance_ok`];
//! the invariants above are the exact anchors (§5.8).

use std::collections::HashMap;

use crate::geometry::{self, GeometryError, Manifold, sliver_atol};

/// A single **surviving** overlap of the regridder's sparse intersection matrix:
/// source cell `src`, target cell `tgt`, and the raw overlap area `A_ij`
/// (`area > atol`; sub-`atol` slivers are filtered out, §5.8.2). Areas are in the
/// manifold's unit — square degrees (planar) or steradians × `radius²` (spherical).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Overlap {
    /// Source cell index `i`.
    pub src: usize,
    /// Target cell index `j`.
    pub tgt: usize,
    /// Raw overlap area `A_ij = area(src_i ∩ tgt_j)`.
    pub area: f64,
}

/// A first-order conservative (area-weighted) regridder: the build-once sparse
/// overlap-area matrix `A_ij` and the per-target row-sums `A_j`, applied to a
/// source field as `F_tgt[j] = (1/A_j)·Σ_i A_ij·F_src[i]` (§A.8).
///
/// Build once with [`ConservativeRegridder::build`] (or
/// [`ConservativeRegridder::build_binned`] with the integer-bin broad phase), then
/// [`apply`](ConservativeRegridder::apply) many times — the static/dynamic
/// partition the package mirrors (§6.1).
#[derive(Debug, Clone)]
pub struct ConservativeRegridder {
    n_src: usize,
    n_tgt: usize,
    manifold: Manifold,
    radius: f64,
    /// Surviving overlaps, sorted by `(src, tgt)` for a deterministic layout.
    overlaps: Vec<Overlap>,
    /// `A_j = Σ_i A_ij` per target cell (`dst_areas`).
    tgt_areas: Vec<f64>,
}

impl ConservativeRegridder {
    /// Build the regridder from `src_cells` and `tgt_cells` (each a lon-lat vertex
    /// ring, implicitly closed) under `manifold`, on the unit sphere
    /// (`radius = 1`). **Exhaustive** narrow phase: every `(i, j)` pair is clipped
    /// — the correctness baseline. Use [`build_binned`](Self::build_binned) for the
    /// integer-bin broad phase.
    ///
    /// Returns the first [`GeometryError`] from a degenerate cell / failed clip.
    pub fn build(
        src_cells: &[Vec<(f64, f64)>],
        tgt_cells: &[Vec<(f64, f64)>],
        manifold: Manifold,
    ) -> Result<Self, GeometryError> {
        Self::build_with_radius(src_cells, tgt_cells, manifold, 1.0)
    }

    /// [`build`](Self::build) with an explicit sphere radius / characteristic
    /// length, which scales the §5.8.2 sliver floor `atol = 1e-15·radius²`. Areas
    /// remain in the manifold's native unit (the radius does not rescale them); it
    /// governs only the sliver threshold.
    pub fn build_with_radius(
        src_cells: &[Vec<(f64, f64)>],
        tgt_cells: &[Vec<(f64, f64)>],
        manifold: Manifold,
        radius: f64,
    ) -> Result<Self, GeometryError> {
        let n_src = src_cells.len();
        let n_tgt = tgt_cells.len();
        let candidates = (0..n_src).flat_map(|i| (0..n_tgt).map(move |j| (i, j)));
        Self::assemble(src_cells, tgt_cells, manifold, radius, candidates)
    }

    /// Build with the **bin-Skolem broad phase** (§A.8 step 1 / §5.8.5): each cell
    /// is quantized to the integer lat-lon bins its bbox spans (`floor(lon/dx)`,
    /// `floor(lat/dy)`), and only candidate pairs whose integer bin ranges overlap
    /// are clipped. The candidate set is keyed on **integers** (no FP coordinate
    /// comparison), so it is order-independent and byte-identical across bindings;
    /// it is a *superset* of the truly-overlapping pairs (non-overlapping
    /// candidates clip to empty and drop out), so the surviving set — and every
    /// weight — is **identical** to [`build`](Self::build). `dx` / `dy` are the bin
    /// size in degrees (`> 0`).
    pub fn build_binned(
        src_cells: &[Vec<(f64, f64)>],
        tgt_cells: &[Vec<(f64, f64)>],
        manifold: Manifold,
        dx: f64,
        dy: f64,
    ) -> Result<Self, GeometryError> {
        if !dx.is_finite() || !dy.is_finite() || dx <= 0.0 || dy <= 0.0 {
            return Err(GeometryError::new(format!(
                "bin sizes must be finite and positive, got dx={dx}, dy={dy}"
            )));
        }
        let candidates = candidate_pairs_binned(src_cells, tgt_cells, dx, dy);
        Self::assemble(src_cells, tgt_cells, manifold, 1.0, candidates.into_iter())
    }

    /// Narrow phase shared by the build entry points: clip each candidate pair,
    /// keep the overlap iff its area clears the sliver floor (§5.8.2), and
    /// row-sum to `A_j`. The surviving overlaps are sorted by `(src, tgt)`.
    fn assemble(
        src_cells: &[Vec<(f64, f64)>],
        tgt_cells: &[Vec<(f64, f64)>],
        manifold: Manifold,
        radius: f64,
        candidates: impl Iterator<Item = (usize, usize)>,
    ) -> Result<Self, GeometryError> {
        let n_src = src_cells.len();
        let n_tgt = tgt_cells.len();
        let atol = sliver_atol(radius);
        let mut overlaps: Vec<Overlap> = Vec::new();
        let mut tgt_areas = vec![0.0_f64; n_tgt];
        for (i, j) in candidates {
            let ring = geometry::intersect_polygon(&src_cells[i], &tgt_cells[j], manifold)?;
            if ring.len() < 3 {
                continue; // disjoint / edge-touching: empty clip, no contribution
            }
            let area = geometry::polygon_area(&ring, manifold)?;
            // §5.8.2 sliver floor: a sub-`atol` overlap is treated as
            // equal-to-zero — the candidate→surviving boundary (§5.8.5).
            if area <= atol {
                continue;
            }
            overlaps.push(Overlap {
                src: i,
                tgt: j,
                area,
            });
            tgt_areas[j] += area;
        }
        overlaps.sort_by_key(|ov| (ov.src, ov.tgt));
        Ok(Self {
            n_src,
            n_tgt,
            manifold,
            radius,
            overlaps,
            tgt_areas,
        })
    }

    /// Number of source cells.
    pub fn n_src(&self) -> usize {
        self.n_src
    }

    /// Number of target cells.
    pub fn n_tgt(&self) -> usize {
        self.n_tgt
    }

    /// The declared manifold (compare two regridders only same-manifold, §5.8.4).
    pub fn manifold(&self) -> Manifold {
        self.manifold
    }

    /// The sphere radius / characteristic length governing the sliver floor.
    pub fn radius(&self) -> f64 {
        self.radius
    }

    /// The surviving sparse overlaps `A_ij` (sorted by `(src, tgt)`).
    pub fn overlaps(&self) -> &[Overlap] {
        &self.overlaps
    }

    /// `A_j = Σ_i A_ij` per target cell (`ConservativeRegridding.jl`'s `dst_areas`).
    pub fn target_areas(&self) -> &[f64] {
        &self.tgt_areas
    }

    /// `A_i = Σ_j A_ij` per source cell — the source area actually covered by the
    /// target mesh. Equals the true source-cell area when the target mesh fully
    /// tiles the source (the condition under which first-order conservation is
    /// exact, §5.8.3).
    pub fn source_areas(&self) -> Vec<f64> {
        let mut a = vec![0.0_f64; self.n_src];
        for ov in &self.overlaps {
            a[ov.src] += ov.area;
        }
        a
    }

    /// The conservative weight `W_ij = A_ij / A_j` (`0` if `(i, j)` is not a
    /// surviving overlap or target `j` has no overlaps).
    pub fn weight(&self, i: usize, j: usize) -> f64 {
        let aj = self.tgt_areas.get(j).copied().unwrap_or(0.0);
        if aj <= 0.0 {
            return 0.0;
        }
        self.overlaps
            .iter()
            .find(|ov| ov.src == i && ov.tgt == j)
            .map(|ov| ov.area / aj)
            .unwrap_or(0.0)
    }

    /// Apply the regridder to a source field: `F_tgt[j] = Σ_i W_ij·F_src[i]`
    /// (the sparse mat-vec `mul!(dst, intersections, src)` followed by the
    /// `dst ./= dst_areas` normalize). A target with no overlaps maps to `0`.
    ///
    /// # Panics
    /// If `f_src.len() != n_src`.
    pub fn apply(&self, f_src: &[f64]) -> Vec<f64> {
        assert_eq!(
            f_src.len(),
            self.n_src,
            "source field length {} != n_src {}",
            f_src.len(),
            self.n_src
        );
        let mut numer = vec![0.0_f64; self.n_tgt];
        for ov in &self.overlaps {
            numer[ov.tgt] += ov.area * f_src[ov.src];
        }
        numer
            .iter()
            .zip(&self.tgt_areas)
            .map(|(&num, &aj)| if aj > 0.0 { num / aj } else { 0.0 })
            .collect()
    }

    /// Partition-of-unity per target: `Σ_i W_ij` from the **weights** (`= 1` for
    /// every target with overlaps, exact by construction, §5.8.3). A target with no
    /// overlaps yields `0`. Computing it from `weight()` rather than reusing
    /// `A_j` validates the construction rather than asserting a tautology.
    pub fn partition_of_unity(&self) -> Vec<f64> {
        let mut row = vec![0.0_f64; self.n_tgt];
        for ov in &self.overlaps {
            row[ov.tgt] += self.weight(ov.src, ov.tgt);
        }
        row
    }

    /// Global remapped mass `Σ_j A_j·F_tgt[j]` — the LHS of the conservation
    /// invariant (§5.8.3).
    ///
    /// # Panics
    /// If `f_tgt.len() != n_tgt`.
    pub fn target_mass(&self, f_tgt: &[f64]) -> f64 {
        assert_eq!(f_tgt.len(), self.n_tgt, "target field length != n_tgt");
        self.tgt_areas
            .iter()
            .zip(f_tgt)
            .map(|(&aj, &f)| aj * f)
            .sum()
    }

    /// Global source mass `Σ_i A_i·F_src[i]` using the **covered** source areas
    /// `A_i = Σ_j A_ij` — the RHS of the conservation invariant (§5.8.3). Equals
    /// [`target_mass`](Self::target_mass) of `apply(f_src)` by construction.
    ///
    /// # Panics
    /// If `f_src.len() != n_src`.
    pub fn source_mass(&self, f_src: &[f64]) -> f64 {
        assert_eq!(f_src.len(), self.n_src, "source field length != n_src");
        self.source_areas()
            .iter()
            .zip(f_src)
            .map(|(&ai, &f)| ai * f)
            .sum()
    }
}

/// The bbox of a lon-lat ring as `(min_lon, min_lat, max_lon, max_lat)`.
fn bbox(cell: &[(f64, f64)]) -> (f64, f64, f64, f64) {
    let mut min_lon = f64::INFINITY;
    let mut min_lat = f64::INFINITY;
    let mut max_lon = f64::NEG_INFINITY;
    let mut max_lat = f64::NEG_INFINITY;
    for &(lon, lat) in cell {
        min_lon = min_lon.min(lon);
        max_lon = max_lon.max(lon);
        min_lat = min_lat.min(lat);
        max_lat = max_lat.max(lat);
    }
    (min_lon, min_lat, max_lon, max_lat)
}

/// The inclusive integer bin range `[floor(lo/step), floor(hi/step)]` an interval
/// `[lo, hi]` spans. **Integer** keys (the §5.8.5 quantization): the only place
/// floating-point coordinates touch the broad phase is this `floor`, never a raw
/// coordinate comparison.
fn bin_span(lo: f64, hi: f64, step: f64) -> (i64, i64) {
    let b0 = (lo / step).floor() as i64;
    let b1 = (hi / step).floor() as i64;
    (b0.min(b1), b0.max(b1))
}

/// Candidate `(src, tgt)` pairs whose integer bin ranges overlap — the bin-Skolem
/// equi-join broad phase (§A.8 / §5.8.5). A *superset* of the truly-overlapping
/// pairs (bbox-overlapping cells always share ≥1 bin); the returned pairs are
/// sorted by `(src, tgt)` so the candidate set is order-independent.
fn candidate_pairs_binned(
    src_cells: &[Vec<(f64, f64)>],
    tgt_cells: &[Vec<(f64, f64)>],
    dx: f64,
    dy: f64,
) -> Vec<(usize, usize)> {
    // Bucket each target into every integer bin its bbox spans.
    let mut bins: HashMap<(i64, i64), Vec<usize>> = HashMap::new();
    for (j, cell) in tgt_cells.iter().enumerate() {
        let (lo_x, lo_y, hi_x, hi_y) = bbox(cell);
        let (bx0, bx1) = bin_span(lo_x, hi_x, dx);
        let (by0, by1) = bin_span(lo_y, hi_y, dy);
        for bx in bx0..=bx1 {
            for by in by0..=by1 {
                bins.entry((bx, by)).or_default().push(j);
            }
        }
    }
    // For each source, gather targets sharing any bin it spans.
    let mut pairs: Vec<(usize, usize)> = Vec::new();
    for (i, cell) in src_cells.iter().enumerate() {
        let (lo_x, lo_y, hi_x, hi_y) = bbox(cell);
        let (bx0, bx1) = bin_span(lo_x, hi_x, dx);
        let (by0, by1) = bin_span(lo_y, hi_y, dy);
        for bx in bx0..=bx1 {
            for by in by0..=by1 {
                if let Some(targets) = bins.get(&(bx, by)) {
                    for &j in targets {
                        pairs.push((i, j));
                    }
                }
            }
        }
    }
    pairs.sort_unstable();
    pairs.dedup();
    pairs
}

#[cfg(all(test, not(target_arch = "wasm32")))]
mod tests {
    use super::*;
    use ndarray::{ArrayD, IxDyn};
    use serde_json::json;

    use crate::simulate_array::{Value, eval_expression};
    use crate::types::Expr;

    const TIGHT: f64 = 1e-12;

    /// Two unit cells on `[0,1]` and `[1,2]` (lat `[0,1]`).
    fn src_two_cells() -> Vec<Vec<(f64, f64)>> {
        vec![
            vec![(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)],
            vec![(1.0, 0.0), (2.0, 0.0), (2.0, 1.0), (1.0, 1.0)],
        ]
    }

    /// Targets `[0,1.5]` and `[1.5,2]` (lat `[0,1]`): they tile the same domain as
    /// `src_two_cells`, so overlaps are A=[1.0, 0.5] into T0 and 0.5 into T1.
    fn tgt_split_cells() -> Vec<Vec<(f64, f64)>> {
        vec![
            vec![(0.0, 0.0), (1.5, 0.0), (1.5, 1.0), (0.0, 1.0)],
            vec![(1.5, 0.0), (2.0, 0.0), (2.0, 1.0), (1.5, 1.0)],
        ]
    }

    #[test]
    fn planar_overlap_areas_are_exact() {
        let r =
            ConservativeRegridder::build(&src_two_cells(), &tgt_split_cells(), Manifold::Planar)
                .unwrap();
        // A_00 = 1 (all of S0), A_10 = 0.5, A_11 = 0.5; A_01 = 0 (filtered).
        assert_eq!(r.overlaps().len(), 3);
        assert!((r.weight(0, 0) - 1.0 / 1.5).abs() < TIGHT);
        assert!((r.weight(1, 0) - 0.5 / 1.5).abs() < TIGHT);
        assert!((r.weight(1, 1) - 1.0).abs() < TIGHT);
        assert_eq!(r.weight(0, 1), 0.0);
        // A_j = [1.5, 0.5].
        assert!((r.target_areas()[0] - 1.5).abs() < TIGHT);
        assert!((r.target_areas()[1] - 0.5).abs() < TIGHT);
    }

    #[test]
    fn partition_of_unity_holds_by_construction() {
        let r =
            ConservativeRegridder::build(&src_two_cells(), &tgt_split_cells(), Manifold::Planar)
                .unwrap();
        for (j, &pou) in r.partition_of_unity().iter().enumerate() {
            assert!(
                (pou - 1.0).abs() < TIGHT,
                "target {j} partition-of-unity {pou}"
            );
        }
    }

    #[test]
    fn apply_and_mass_conservation() {
        let r =
            ConservativeRegridder::build(&src_two_cells(), &tgt_split_cells(), Manifold::Planar)
                .unwrap();
        let f_src = [3.0, 7.0];
        let f_tgt = r.apply(&f_src);
        // F_tgt[0] = (1·3 + 0.5·7)/1.5 = 6.5/1.5; F_tgt[1] = 7.
        assert!((f_tgt[0] - (3.0 + 0.5 * 7.0) / 1.5).abs() < TIGHT);
        assert!((f_tgt[1] - 7.0).abs() < TIGHT);
        // Conservation: Σ_j A_j F_tgt = Σ_i A_i F_src (both = 3 + 7 = 10 here,
        // since the meshes tile the same domain so A_i = 1 each).
        assert!((r.target_mass(&f_tgt) - r.source_mass(&f_src)).abs() < TIGHT);
        assert!((r.source_mass(&f_src) - 10.0).abs() < TIGHT);
    }

    #[test]
    fn binned_broad_phase_matches_exhaustive() {
        let src = src_two_cells();
        let tgt = tgt_split_cells();
        let dense = ConservativeRegridder::build(&src, &tgt, Manifold::Planar).unwrap();
        // Bin at the grid spacing; candidate set is a superset, surviving set equal.
        let binned =
            ConservativeRegridder::build_binned(&src, &tgt, Manifold::Planar, 1.0, 1.0).unwrap();
        assert_eq!(dense.overlaps(), binned.overlaps());
        assert_eq!(dense.target_areas(), binned.target_areas());
    }

    #[test]
    fn candidate_set_is_input_order_independent() {
        // Permuting target order must not change the binned candidate-bin keys
        // (integer keys, §5.8.5): the surviving overlaps map back identically.
        let src = src_two_cells();
        let tgt = tgt_split_cells();
        let mut tgt_rev = tgt.clone();
        tgt_rev.reverse();
        let a =
            ConservativeRegridder::build_binned(&src, &tgt, Manifold::Planar, 1.0, 1.0).unwrap();
        let b = ConservativeRegridder::build_binned(&src, &tgt_rev, Manifold::Planar, 1.0, 1.0)
            .unwrap();
        // Map b's overlaps (reversed target indices) back to the original order.
        let n = tgt.len();
        let mut b_mapped: Vec<Overlap> = b
            .overlaps()
            .iter()
            .map(|ov| Overlap {
                src: ov.src,
                tgt: n - 1 - ov.tgt,
                area: ov.area,
            })
            .collect();
        b_mapped.sort_by_key(|x| (x.src, x.tgt));
        assert_eq!(a.overlaps(), b_mapped.as_slice());
    }

    #[test]
    fn empty_target_has_zero_weight_and_field() {
        // A target far from every source has no overlaps: weight 0, field 0,
        // partition-of-unity 0 (no source mass mapped there).
        let src = vec![vec![(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)]];
        let tgt = vec![
            vec![(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)],
            vec![(50.0, 50.0), (51.0, 50.0), (51.0, 51.0), (50.0, 51.0)],
        ];
        let r = ConservativeRegridder::build(&src, &tgt, Manifold::Planar).unwrap();
        assert_eq!(r.target_areas()[1], 0.0);
        let f_tgt = r.apply(&[5.0]);
        assert_eq!(f_tgt[1], 0.0);
        assert_eq!(r.partition_of_unity()[1], 0.0);
        assert!((f_tgt[0] - 5.0).abs() < TIGHT);
    }

    /// `polygon_area` as the actual `sum_product` FAQ over a clipped ring, through
    /// the real array evaluator — the planar shoelace integrand
    /// `½·(xᵥ·yᵥ₊₁ − xᵥ₊₁·yᵥ)`. Proves the regridder's `A_ij` (computed via the
    /// `geometry::polygon_area` oracle) equals the IR FAQ value (RFC §8.1).
    fn shoelace_area_faq(ring: &[(f64, f64)]) -> f64 {
        let n = ring.len();
        let next: Vec<(f64, f64)> = (0..n).map(|i| ring[(i + 1) % n]).collect();
        let to_arr = |r: &[(f64, f64)]| {
            let flat: Vec<f64> = r.iter().flat_map(|&(x, y)| [x, y]).collect();
            ArrayD::from_shape_vec(IxDyn(&[r.len(), 2]), flat).unwrap()
        };
        let mut inputs = HashMap::new();
        inputs.insert("clip".to_string(), to_arr(ring));
        inputs.insert("clip_next".to_string(), to_arr(&next));
        let agg: Expr = serde_json::from_value(json!({
            "op": "aggregate", "args": [], "semiring": "sum_product", "output_idx": [],
            "ranges": { "v": [1, n] },
            "expr": { "op": "*", "args": [0.5, { "op": "-", "args": [
                { "op": "*", "args": [
                    { "op": "index", "args": ["clip", "v", 1] },
                    { "op": "index", "args": ["clip_next", "v", 2] } ]},
                { "op": "*", "args": [
                    { "op": "index", "args": ["clip_next", "v", 1] },
                    { "op": "index", "args": ["clip", "v", 2] } ]} ]} ]}
        }))
        .unwrap();
        match eval_expression(&agg, &inputs, &[], &[], 0.0) {
            Value::Scalar(s) => s.abs(),
            Value::Array(_) => panic!("scalar polygon_area FAQ expected"),
        }
    }

    #[test]
    fn regridder_areas_equal_polygon_area_faq() {
        // Each surviving A_ij must equal `polygon_area` evaluated as a sum_product
        // FAQ over the same clipped ring (the IR's narrow phase, §8.1).
        let src = src_two_cells();
        let tgt = tgt_split_cells();
        let r = ConservativeRegridder::build(&src, &tgt, Manifold::Planar).unwrap();
        for ov in r.overlaps() {
            let ring =
                geometry::intersect_polygon(&src[ov.src], &tgt[ov.tgt], Manifold::Planar).unwrap();
            let faq = shoelace_area_faq(&ring);
            assert!(
                (ov.area - faq).abs() < TIGHT,
                "A_{}{} oracle {} vs FAQ {faq}",
                ov.src,
                ov.tgt,
                ov.area
            );
        }
    }
}
