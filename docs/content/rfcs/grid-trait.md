# Grid trait — cross-binding contract for grid accessors (esm-a3z)

This RFC defines the **abstract Grid trait** that EarthSciSerialization (ESS)
will own and that EarthSciDiscretizations (ESD) will implement per grid
family. ESS hosts the trait (and, downstream of esm-xom, the assembly logic
that consumes it: covariant Laplacian, FV stencil precompute, cross-metric
stencil composition); ESD hosts the per-family implementations and their
declarative rule JSON. The point of fixing the contract first is to let the
ESS-side and ESD-side implementation beads run in parallel against a stable
surface.

This document is **normative for implementers** (every binding listed in §3
MUST expose the trait with the named methods and the documented array
shapes) and informative for callers.

## 1. Method enumeration

Methods are grouped by tier (§4); a grid declares which tiers it implements.
The signatures below are language-agnostic; per-binding spellings are in §3.

### Tier C — Core (every grid)

| Method | Returns | Shape |
|---|---|---|
| `cell_centers(grid, axis)` | physical-coordinate values | `(N_cells,)` per axis (one call per axis) |
| `cell_volume(grid)` | cell measure (volume in 3D, area in 2D, length in 1D) | `(N_cells,)` |
| `cell_widths(grid, axis)` | per-axis width of each cell | `(N_cells,)` |
| `neighbor_indices(grid, axis, offset)` | flat index of the neighbor `offset` cells along `axis` (negative for "before") | `(N_cells,)` of integers; sentinel value (binding-specific, see §3) for boundary |
| `boundary_mask(grid, axis, side)` | `true` where the cell sits on the named boundary | `(N_cells,)` of bool |
| `n_cells(grid)` | total cell count | scalar |
| `n_dims(grid)` | spatial dimensionality (1, 2, or 3) | scalar |
| `axis_names(grid)` | symbolic names of axes (e.g. `(:x,:y,:z)`, `(:lon,:lat)`, `(:ξ,:η)`) | tuple of length `n_dims` |

### Tier M — Curvilinear metric (grids with non-trivial metric tensor)

| Method | Returns | Shape |
|---|---|---|
| `metric_g(grid)` | covariant metric tensor `g_ij` per cell | `(N_cells, n_dims, n_dims)` |
| `metric_ginv(grid)` | contravariant metric tensor `g^ij` per cell | `(N_cells, n_dims, n_dims)` |
| `metric_jacobian(grid)` | `J = sqrt(det g)` per cell | `(N_cells,)` |
| `metric_dgij_dxk(grid)` | `∂g_ij/∂x^k` per cell (Christoffel inputs and cross-metric stencils) | `(N_cells, n_dims, n_dims, n_dims)` |
| `coord_jacobian(grid, target)` | `∂(comp_axis)/∂(target_axis)` for `target ∈ {:lon,:lat, …}` | `(N_cells, n_dims, target_dims)` |
| `coord_jacobian_second(grid, target)` | `∂²(comp)/∂(target)∂(target)` (curvilinear chain-rule) | `(N_cells, n_dims, target_dims, target_dims)` |

### Tier S — Staggered / face-centered (Arakawa, MPAS, duo)

| Method | Returns | Shape |
|---|---|---|
| `face_area(grid, location)` | area of a face at the named stagger location | `(N_faces_at_loc,)` |
| `face_normal(grid, location)` | outward unit normal | `(N_faces_at_loc, n_dims)` |
| `face_to_cell_indices(grid, location)` | `(left, right)` cell indices for each face | `(N_faces_at_loc, 2)` |
| `dual_cell_centers(grid, location)` | physical coords of dual cells | `(N_dual,)` per axis |

### Tier V — Vertical (`VerticalGrid`, terrain-following layers)

| Method | Returns | Shape |
|---|---|---|
| `half_levels(grid)` | layer interface values | `(N_cells+1,)` |
| `layer_thickness(grid)` | layer thickness | `(N_cells,)` |
| `pressure_coefficients(grid)` | `(ak, bk)` for hybrid sigma-pressure | two arrays of `(N_cells+1,)` |

### Tier U — Unstructured connectivity (MPAS, duo)

| Method | Returns | Shape |
|---|---|---|
| `cell_neighbor_table(grid)` | variable-arity neighbor list, padded | `(N_cells, max_valence)` of integers |
| `cell_valence(grid)` | number of real (non-padded) neighbors per cell | `(N_cells,)` |
| `edge_length(grid)` | length of each edge | `(N_edges,)` |
| `cell_distance(grid)` | center-to-center distance across each edge | `(N_edges,)` |

This enumerates **24 methods across 5 tiers**, well above the 15-method
acceptance bar.

## 2. Bulk-array form (mandatory)

**The trait contract is whole-grid arrays, never scalar-per-cell.** The audit
of `EarthSciDiscretizations/refinery/rig/src/grids/` shows the existing API
is mixed: `cell_volume(grid, i, j, k)` returns a scalar, `metric_eval(grid,
:g, i, j, k)` returns a tuple, while curvilinear families already store
metrics as bulk arrays (`grid.J`, `grid.ginv_ξξ`, …) that assembly logic
indexes directly. The trait standardizes on the bulk form.

**Why bulk arrays:**

1. *Scaling.* A 1000-cell grid means 1000 dispatches and 1000 small
   allocations for any per-cell call. The curvilinear FV stencil
   precompute already loops over cells and reads precomputed bulk
   arrays; the Cartesian/lat-lon paths pay an avoidable overhead to
   reconstruct the same.
2. *SIMD / GPU.* Bulk arrays are the only form that compiles to vectorized
   kernels in Rust (`ndarray` + `rayon`), Python (NumPy), and Julia
   (broadcast). Scalar-per-cell APIs preclude this.
3. *Differentiability.* Forward-mode AD (the default in the Julia binding)
   sees array-valued operations as a single dual-number op; per-cell calls
   trigger one dispatch per element.
4. *Cross-binding parity.* Five languages must agree on shape signatures; a
   "scalar plus index list" signature is harder to specify than
   `(N_cells,...)`.

Scalar-per-cell convenience methods MAY exist on top of the trait
(see §7) but are not part of the contract — a binding that does not
implement them is still conformant.

## 3. Per-binding signatures

### Julia (`EarthSciSerialization.jl`)

```julia
abstract type AbstractGrid end

# Tier C
cell_centers(grid::AbstractGrid, axis::Symbol)::AbstractVector{Float64}
cell_volume(grid::AbstractGrid)::AbstractVector{Float64}
cell_widths(grid::AbstractGrid, axis::Symbol)::AbstractVector{Float64}
neighbor_indices(grid::AbstractGrid, axis::Symbol, offset::Int)::AbstractVector{Int}
boundary_mask(grid::AbstractGrid, axis::Symbol, side::Symbol)::AbstractVector{Bool}
n_cells(grid::AbstractGrid)::Int
n_dims(grid::AbstractGrid)::Int
axis_names(grid::AbstractGrid)::NTuple{N,Symbol} where N

# Tier M (Holy-trait gated; AbstractCurvilinearGrid <: AbstractGrid)
metric_g(grid::AbstractCurvilinearGrid)::AbstractArray{Float64,3}
metric_ginv(grid::AbstractCurvilinearGrid)::AbstractArray{Float64,3}
metric_jacobian(grid::AbstractCurvilinearGrid)::AbstractVector{Float64}
metric_dgij_dxk(grid::AbstractCurvilinearGrid)::AbstractArray{Float64,4}
coord_jacobian(grid::AbstractCurvilinearGrid, target::Symbol)::AbstractArray{Float64,3}
coord_jacobian_second(grid::AbstractCurvilinearGrid, target::Symbol)::AbstractArray{Float64,4}
```

Tiers S/V/U use additional abstract supertypes
(`AbstractStaggeredGrid`, `AbstractVerticalGrid`, `AbstractUnstructuredGrid`)
combined with `AbstractCurvilinearGrid` as needed via union-like multi-trait
dispatch (Holy traits where multiple-inheritance is required).

Sentinel for boundary: `0` (Julia is 1-indexed; `0` is unambiguous).

### Rust (`earthsci-toolkit-rs`)

```rust
pub trait Grid {
    type Array1: AsRef<[f64]>;          // ndarray::Array1<f64> by default
    type Array1I: AsRef<[i64]>;
    type Array1B: AsRef<[bool]>;

    fn cell_centers(&self, axis: Axis) -> Self::Array1;
    fn cell_volume(&self) -> Self::Array1;
    fn cell_widths(&self, axis: Axis) -> Self::Array1;
    fn neighbor_indices(&self, axis: Axis, offset: i32) -> Self::Array1I;
    fn boundary_mask(&self, axis: Axis, side: Side) -> Self::Array1B;
    fn n_cells(&self) -> usize;
    fn n_dims(&self) -> usize;
    fn axis_names(&self) -> &[Axis];
}

pub trait CurvilinearGrid: Grid {
    type ArrayD: ndarray::Dimension;    // ndarray::ArrayD<f64>
    fn metric_g(&self) -> ndarray::Array3<f64>;
    fn metric_ginv(&self) -> ndarray::Array3<f64>;
    fn metric_jacobian(&self) -> ndarray::Array1<f64>;
    fn metric_dgij_dxk(&self) -> ndarray::Array4<f64>;
    fn coord_jacobian(&self, target: Axis) -> ndarray::Array3<f64>;
    fn coord_jacobian_second(&self, target: Axis) -> ndarray::Array4<f64>;
}
```

`StaggeredGrid: Grid`, `VerticalGrid: Grid`, `UnstructuredGrid: Grid` are
analogous supertraits; a grid family composes them (`impl Grid + Curvilinear
+ Staggered for ArakawaGrid`). Sentinel: `i64::MIN`.

### Python (`earthsci_toolkit`)

```python
from typing import Protocol, Tuple, Literal
import numpy as np

Axis = Literal["x", "y", "z", "lon", "lat", "lev", "xi", "eta"]
Side = Literal["lower", "upper"]

class Grid(Protocol):
    def cell_centers(self, axis: Axis) -> np.ndarray: ...   # float64, (N,)
    def cell_volume(self) -> np.ndarray: ...                # float64, (N,)
    def cell_widths(self, axis: Axis) -> np.ndarray: ...    # float64, (N,)
    def neighbor_indices(
        self, axis: Axis, offset: int
    ) -> np.ndarray: ...                                    # int64, (N,)
    def boundary_mask(self, axis: Axis, side: Side) -> np.ndarray: ...  # bool, (N,)
    def n_cells(self) -> int: ...
    def n_dims(self) -> int: ...
    def axis_names(self) -> Tuple[Axis, ...]: ...

class CurvilinearGrid(Grid, Protocol):
    def metric_g(self) -> np.ndarray: ...                   # (N, D, D)
    def metric_ginv(self) -> np.ndarray: ...                # (N, D, D)
    def metric_jacobian(self) -> np.ndarray: ...            # (N,)
    def metric_dgij_dxk(self) -> np.ndarray: ...            # (N, D, D, D)
    def coord_jacobian(self, target: Axis) -> np.ndarray: ...  # (N, D, T)
    def coord_jacobian_second(self, target: Axis) -> np.ndarray: ...  # (N, D, T, T)
```

Sentinel: `-1` (NumPy int64); Python uses `Protocol` (structural typing) so
implementers do not have to inherit explicitly.

### TypeScript (`earthsci-toolkit`)

```typescript
type Axis = "x" | "y" | "z" | "lon" | "lat" | "lev" | "xi" | "eta";
type Side = "lower" | "upper";

export interface Grid {
  cellCenters(axis: Axis): Float64Array;          // length N
  cellVolume(): Float64Array;                     // length N
  cellWidths(axis: Axis): Float64Array;           // length N
  neighborIndices(axis: Axis, offset: number): Int32Array;  // length N
  boundaryMask(axis: Axis, side: Side): Uint8Array;         // 0/1, length N
  nCells(): number;
  nDims(): number;
  axisNames(): readonly Axis[];
}

export interface CurvilinearGrid extends Grid {
  metricG(): Float64Array;            // flat row-major (N*D*D)
  metricGinv(): Float64Array;         // flat (N*D*D)
  metricJacobian(): Float64Array;     // (N,)
  metricDgijDxk(): Float64Array;      // flat (N*D*D*D)
  coordJacobian(target: Axis): Float64Array;        // flat (N*D*T)
  coordJacobianSecond(target: Axis): Float64Array;  // flat (N*D*T*T)
}
```

Tensor methods return flat typed arrays plus a documented row-major stride
order; bindings MAY also expose a wrapper returning a shape descriptor.
Sentinel: `-1` (Int32Array).

### Go (`esm-format-go`)

```go
type Axis string
type Side string

type Grid interface {
    CellCenters(axis Axis) []float64
    CellVolume() []float64
    CellWidths(axis Axis) []float64
    NeighborIndices(axis Axis, offset int) []int64
    BoundaryMask(axis Axis, side Side) []bool
    NCells() int
    NDims() int
    AxisNames() []Axis
}

type CurvilinearGrid interface {
    Grid
    MetricG() (data []float64, shape []int)         // shape = [N, D, D]
    MetricGinv() (data []float64, shape []int)
    MetricJacobian() []float64
    MetricDgijDxk() (data []float64, shape []int)   // shape = [N, D, D, D]
    CoordJacobian(target Axis) (data []float64, shape []int)
    CoordJacobianSecond(target Axis) (data []float64, shape []int)
}
```

Go has no generics over numeric tensor rank, so multi-dimensional accessors
return `(data, shape)` pairs in row-major layout. Sentinel: `-1`.

## 4. Optional method tiers

A grid declares its capability set by implementing the corresponding tier
interface(s). The mapping below is normative for ESD's six existing
families:

| Grid family | C | M | S | V | U |
|---|---|---|---|---|---|
| `CartesianGrid` | ✓ | – | – | – | – |
| `LatLonGrid` | ✓ | ✓ | – | – | – |
| `ArakawaGrid` | ✓ | – | ✓ | – | – |
| `MpasGrid` | ✓ | ✓ | ✓ | – | ✓ |
| `DuoGrid` | ✓ | – | ✓ | – | ✓ |
| `VerticalGrid` | ✓ | – | – | ✓ | – |

A consumer (e.g. the covariant Laplacian assembler) requires a specific
tier and rejects grids that do not declare it; the binding's type system
catches the mismatch at compile time (Rust, Go), at dispatch time (Julia),
or at type-check time (Python with `TypeGuard` / TypeScript).

## 5. Performance contract

- **Construction is O(1) and lazy.** Building a grid object materializes
  topology only; metric arrays are computed on first access.
- **First materialization is O(N_cells)** for Tier C and O(N_cells · D²)
  or O(N_cells · D³) for Tier M tensors / metric derivatives.
- **Subsequent access is O(1) plus a pointer return.** Bindings MUST
  cache materialized arrays on the grid instance. Bindings MAY use
  copy-on-write or Arc/Rc-style sharing; mutation of returned arrays is
  undefined behavior.
- **Grids are immutable once constructed.** No method mutates `grid`. A
  grid that needs different parameters must be reconstructed.
- **No allocation on the hot path.** Once arrays are cached, tensor
  accessors return views/slices, not copies. (TypeScript is the
  exception: `Float64Array` views into a backing buffer are allowed.)
- **Thread safety.** Grids MUST be safe to read concurrently after
  construction (`Send + Sync` in Rust; documented as such for other
  bindings).

## 6. Migration path (all 6 ESD grid families)

| Family | Today | Trait-mapped form | Notes |
|---|---|---|---|
| `CartesianGrid` | `cell_volume(g, i, j, k)`, `metric_eval(g, :dx, …)` | Tier C; `metric_eval` symbols become `cell_widths(:x)`, etc. | Fits cleanly. |
| `LatLonGrid` | `metric_eval(g, :g_lonlon, j, i)` etc. (scalar) | Tier C+M; promote `:g_lonlon`/`:g_latlat`/`:g_lonlat` into the `(N,2,2)` `metric_g` array | Ragged-row helpers (`nlon(g,j)`, `row_offset`) become internal — they were only ever used to *flatten* ragged 2D into 1D, which the trait already requires. |
| `ArakawaGrid` | `u_face(g,i,j)`, `v_face(g,i,j)`, `variable_shape(g,:h)` | Tier C+S; per-stagger accessors become `face_area(g, :u)` / `face_area(g, :v)`; `variable_shape` becomes a separate non-trait helper specific to FV staggering | Cleanly tier-S. |
| `MpasGrid` | per-cell helpers + `MpasMeshData` fields | Tier C+M+S+U; `cell_neighbor_table` exposes the variable-arity adjacency; `edge_length`/`cell_distance` already vector-shaped | Highest tier count; pads variable-valence neighborhoods to `max_valence`. |
| `DuoGrid` | minimal accessors over icosahedron-subdivision fields | Tier C+S+U | Currently sparse public API; trait formalizes what's there. |
| `VerticalGrid` | `cell_centers(g, k)`, `metric_eval(g, :sigma, k)` | Tier C+V; named-symbol `metric_eval` accessors split into `half_levels`, `layer_thickness`, `pressure_coefficients` | The `:pressure`/`:sigma`/`:ak`/`:bk` symbol set collapses into Tier-V methods. |

No family fails to map. The two with the most surface-level rewrite are
**LatLon** (scalar `metric_eval` → bulk `metric_g`) and **Vertical** (named
symbols → tiered methods); both are mechanical conversions whose data
already exists in bulk form on the underlying struct fields. The Cartesian
grid is unaffected in shape terms; only the API spelling changes.

## 7. Open question — fate of scalar-per-cell accessors

The status quo includes scalar accessors like `cell_volume(grid, i, j, k)`
and `metric_eval(grid, :g, i, j, k)` that downstream code (notebooks, ad-hoc
analysis, the in-tree visualization scripts) relies on. The proposal here
makes the bulk-array form the **trait contract**; that does not by itself
delete the scalars. Two viable end states:

**A. Keep scalars as binding-internal convenience methods.** They are not
part of the trait, so an ESS-side assembler cannot rely on them, but ESD's
own grid types continue to expose them. This preserves callers and avoids
churn in unrelated code (notebooks, debug printouts). Cost: a permanent
two-API surface that future grid families must also implement, and a
recurring temptation to write per-cell assembly logic against the
convenience methods.

**B. Fully replace scalars; downstream callers index into the bulk array.**
`grid.cell_volume()[flat_index(i, j, k)]` is the new spelling. This
collapses the API to one form and makes "you cannot call this in a per-cell
loop" lexically obvious (you'd be indexing a giant array repeatedly).
Cost: every notebook and debug script breaks.

**Recommendation: A, with a deprecation marker.** Convenience methods
remain for one minor-version cycle past the trait landing, marked
deprecated in each binding's docstrings; they call into the bulk path
internally so there is no second implementation to maintain. After the
deprecation window, option B is revisited — by then the in-tree callers
will have migrated, and the cost of full removal becomes "rip out a
bridge nobody uses." This sequencing also matches the assembly-logic
migration in esm-xom (which moves to bulk-array consumers regardless of
what happens at the convenience layer).

This open question is flagged for resolution at the esm-xom landing
review; the trait spec itself does not prescribe one over the other.
