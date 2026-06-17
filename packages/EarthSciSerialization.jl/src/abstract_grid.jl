# Grid trait per RFC docs/rfcs/grid-trait.md (esm-a3z).
#
# ESS owns the trait; concrete per-family implementations (CartesianGrid,
# LatLonGrid, …) live in EarthSciDiscretizations and register
# themselves via the existing GridAccessor hook. The trait here is the
# bulk-array contract: every Tier-C/M/S/V/U method returns whole-grid arrays
# shaped per RFC §1, never scalar-per-cell.
#
# Julia-specific choices (RFC §3):
#   - abstract type `AbstractGrid`              (Tier C)
#   - abstract subtype `AbstractCurvilinearGrid <: AbstractGrid`  (Tier M)
#   - abstract subtype `AbstractStaggeredGrid   <: AbstractGrid`  (Tier S)
#   - abstract subtype `AbstractVerticalGrid    <: AbstractGrid`  (Tier V)
#   - abstract subtype `AbstractUnstructuredGrid <: AbstractGrid` (Tier U)
#   - boundary sentinel for neighbor_indices: `0` (Julia is 1-indexed)
#
# A family that spans multiple tiers (e.g. MPAS: C+M+S+U) is expressed by
# declaring supertypes + Holy traits; the full matrix is out of scope for
# this file and will land as each family's impl registers in ESD.

"""
    AbstractGrid

Root of the Grid trait hierarchy (RFC §1 Tier C). Every concrete grid MUST
provide the Tier-C methods:

- [`cell_centers`](@ref)`(grid, axis) -> AbstractVector`
- [`cell_volume`](@ref)`(grid) -> AbstractVector`
- [`cell_widths`](@ref)`(grid, axis) -> AbstractVector`
- [`neighbor_indices`](@ref)`(grid, axis, offset) -> AbstractVector{Int}`
- [`boundary_mask`](@ref)`(grid, axis, side) -> AbstractVector{Bool}`
- [`n_cells`](@ref)`(grid) -> Int`
- [`n_dims`](@ref)`(grid) -> Int`
- [`axis_names`](@ref)`(grid) -> NTuple{N,Symbol}`

All array-valued methods return bulk whole-grid arrays (shape `(N_cells,)`
for vector fields; the Tier-M tensor methods promote to higher rank).
Scalar-per-cell access is NOT part of the trait contract.

Boundary sentinel (Julia): `neighbor_indices` returns `0` for cells whose
neighbor sits outside the grid. Implementations that wrap (periodic,
MPAS ragged connectivity) hide the wrap inside the returned array so
consumers never see the sentinel.
"""
abstract type AbstractGrid end

"""
    AbstractCurvilinearGrid <: AbstractGrid

Grids with a non-trivial metric tensor (RFC §1 Tier M). In addition to
Tier C, must provide:

- [`metric_g`](@ref)`(grid) -> AbstractArray{<:Real,3}`       — `(N, D, D)`, g_ij
- [`metric_ginv`](@ref)`(grid) -> AbstractArray{<:Real,3}`    — `(N, D, D)`, g^ij
- [`metric_jacobian`](@ref)`(grid) -> AbstractVector{<:Real}` — `(N,)`, J = sqrt(det g)
- [`metric_dgij_dxk`](@ref)`(grid) -> AbstractArray{<:Real,4}` — `(N, D, D, D)`, ∂g_ij/∂x^k
- [`coord_jacobian`](@ref)`(grid, target) -> AbstractArray{<:Real,3}` — `(N, D, T)`, ∂(comp)/∂(target)
- [`coord_jacobian_second`](@ref)`(grid, target) -> AbstractArray{<:Real,4}` — `(N, D, T, T)`

Cartesian grids (trivial metric) MAY subtype `AbstractCurvilinearGrid`
and return identity tensors, OR stay in Tier C; assemblers that need the
metric should type-check explicitly and fall back to Cartesian form.
"""
abstract type AbstractCurvilinearGrid <: AbstractGrid end

"""
    AbstractStaggeredGrid <: AbstractGrid

Grids with face-centered accessors (RFC §1 Tier S). Arakawa, MPAS, duo.
Must provide `face_area`, `face_normal`, `face_to_cell_indices`,
`dual_cell_centers`.
"""
abstract type AbstractStaggeredGrid <: AbstractGrid end

"""
    AbstractVerticalGrid <: AbstractGrid

Grids with vertical-layer accessors (RFC §1 Tier V). Terrain-following,
hybrid sigma-pressure. Must provide `half_levels`, `layer_thickness`,
`pressure_coefficients`.
"""
abstract type AbstractVerticalGrid <: AbstractGrid end

"""
    AbstractUnstructuredGrid <: AbstractGrid

Grids with variable-arity connectivity (RFC §1 Tier U). MPAS, duo. Must
provide `cell_neighbor_table`, `cell_valence`, `edge_length`,
`cell_distance`.
"""
abstract type AbstractUnstructuredGrid <: AbstractGrid end

"""
    GridTraitError(message)

Thrown by trait stubs when a concrete grid has not implemented the method.
"""
struct GridTraitError <: Exception
    message::String
end
Base.showerror(io::IO, e::GridTraitError) = print(io, "GridTraitError: ", e.message)

# ---------------------------------------------------------------------------
# Tier C — Core (every grid)
# ---------------------------------------------------------------------------

"""
    cell_centers(grid::AbstractGrid, axis::Symbol) -> AbstractVector

Physical-coordinate values of cell centers along `axis`. One call per axis.
Shape: `(n_cells(grid),)`. Values have units matching the axis (radians
for `:lon`/`:lat`, meters for `:x`/`:y`/`:z`/`:xi`/`:eta`, etc.).
"""
function cell_centers end

"""
    cell_volume(grid::AbstractGrid) -> AbstractVector

Per-cell measure: volume (3D), area (2D), or length (1D). Shape: `(N,)`.
For curvilinear grids this is `J · dξ · dη · …` in computational space.
"""
function cell_volume end

"""
    cell_widths(grid::AbstractGrid, axis::Symbol) -> AbstractVector

Per-axis width of each cell. Shape: `(N,)`. On a uniform grid every
entry is the same constant `dξ` (or `dη`, …); on a stretched grid the
array captures the per-cell width.
"""
function cell_widths end

"""
    neighbor_indices(grid::AbstractGrid, axis::Symbol, offset::Int) -> AbstractVector{Int}

Flat cell index of the neighbor `offset` cells along `axis`. Shape: `(N,)`.
Negative `offset` is "before"; positive is "after". Boundary sentinel is
`0` (Julia is 1-indexed, so `0` is unambiguous). Cross-boundary / periodic
topology is resolved inside the implementation — consumers should receive
a valid flat index for every interior cell.
"""
function neighbor_indices end

"""
    boundary_mask(grid::AbstractGrid, axis::Symbol, side::Symbol) -> AbstractVector{Bool}

`true` where the cell sits on the named boundary. `side ∈ (:lower, :upper)`.
Shape: `(N,)`.
"""
function boundary_mask end

"""
    n_cells(grid::AbstractGrid) -> Int

Total cell count (product of per-axis extents for structured grids, the
cell-list length for unstructured).
"""
function n_cells end

"""
    n_dims(grid::AbstractGrid) -> Int

Spatial dimensionality (`1`, `2`, or `3`).
"""
function n_dims end

"""
    axis_names(grid::AbstractGrid) -> NTuple{N,Symbol}

Symbolic names of axes (e.g. `(:x, :y, :z)`, `(:lon, :lat)`,
`(:xi, :eta)`). Length equals `n_dims(grid)`.
"""
function axis_names end

# ---------------------------------------------------------------------------
# Tier M — Curvilinear metric (RFC §1 Tier M)
# ---------------------------------------------------------------------------

"""
    metric_g(grid::AbstractCurvilinearGrid) -> AbstractArray{<:Real,3}

Covariant metric tensor `g_ij` per cell. Shape: `(N, D, D)` with `D = n_dims(grid)`.
"""
function metric_g end

"""
    metric_ginv(grid::AbstractCurvilinearGrid) -> AbstractArray{<:Real,3}

Contravariant metric tensor `g^ij` per cell. Shape: `(N, D, D)`.
"""
function metric_ginv end

"""
    metric_jacobian(grid::AbstractCurvilinearGrid) -> AbstractVector{<:Real}

`J = sqrt(det g)` per cell. Shape: `(N,)`.
"""
function metric_jacobian end

"""
    metric_dgij_dxk(grid::AbstractCurvilinearGrid) -> AbstractArray{<:Real,4}

`∂g_ij/∂x^k` per cell (Christoffel inputs and cross-metric corrections).
Shape: `(N, D, D, D)`.
"""
function metric_dgij_dxk end

"""
    coord_jacobian(grid::AbstractCurvilinearGrid, target::Symbol) -> AbstractArray{<:Real,3}

`∂(computational axis)/∂(target axis)` per cell. Shape: `(N, D, T)`, where
`T` is the dimensionality of the target coordinate system (e.g. 2 for
`(:lon, :lat)`).
"""
function coord_jacobian end

"""
    coord_jacobian_second(grid::AbstractCurvilinearGrid, target::Symbol) -> AbstractArray{<:Real,4}

Second derivatives `∂²(comp)/∂(target)∂(target)`. Shape: `(N, D, T, T)`.
"""
function coord_jacobian_second end

# ---------------------------------------------------------------------------
# Default unimplemented stubs. Concrete subtypes override these; the
# fallbacks produce a clean GridTraitError naming the offending method +
# concrete type, instead of a bare MethodError.
# ---------------------------------------------------------------------------

_trait_err(m, g) = throw(GridTraitError("$(m) not implemented for $(typeof(g))"))

cell_centers(g::AbstractGrid, ::Symbol)          = _trait_err("cell_centers", g)
cell_volume(g::AbstractGrid)                     = _trait_err("cell_volume", g)
cell_widths(g::AbstractGrid, ::Symbol)           = _trait_err("cell_widths", g)
neighbor_indices(g::AbstractGrid, ::Symbol, ::Int) = _trait_err("neighbor_indices", g)
boundary_mask(g::AbstractGrid, ::Symbol, ::Symbol) = _trait_err("boundary_mask", g)
n_cells(g::AbstractGrid)                         = _trait_err("n_cells", g)
n_dims(g::AbstractGrid)                          = _trait_err("n_dims", g)
axis_names(g::AbstractGrid)                      = _trait_err("axis_names", g)

metric_g(g::AbstractCurvilinearGrid)                       = _trait_err("metric_g", g)
metric_ginv(g::AbstractCurvilinearGrid)                    = _trait_err("metric_ginv", g)
metric_jacobian(g::AbstractCurvilinearGrid)                = _trait_err("metric_jacobian", g)
metric_dgij_dxk(g::AbstractCurvilinearGrid)                = _trait_err("metric_dgij_dxk", g)
coord_jacobian(g::AbstractCurvilinearGrid, ::Symbol)       = _trait_err("coord_jacobian", g)
coord_jacobian_second(g::AbstractCurvilinearGrid, ::Symbol) = _trait_err("coord_jacobian_second", g)
