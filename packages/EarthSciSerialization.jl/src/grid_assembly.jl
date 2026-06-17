# Finite-volume grid-metric assembly (esm-xom).
#
# Refactored against the esm-a3z Grid trait. Every function here takes an
# `AbstractCurvilinearGrid` (or `AbstractGrid`) and queries it only through
# bulk-array trait methods — no struct-field access. Periodicity and
# cross-boundary topology are resolved inside the grid impl's
# `neighbor_indices`, so assemblers see a flat-index view of the world.
#
# This file ports the **numeric** stencil assembly (precompute weights + apply
# them to a field). The **symbolic** ArrayOp assembly
# (fv_laplacian_extended, fv_gradient_extended, _build_rhs_arrayop,
# discretize_equation) is Symbolics/ModelingToolkit-dependent and must live
# in ext/EarthSciSerializationMTKExt.jl — ESS's src/ is pure Julia and keeps
# Symbolics out of the default load path. See follow-up bead esm-xom-mtk.
#
# Dimensionality: the FV Laplacian and gradient stencils here are **2D**
# (9-point Laplacian, 5-point gradient), matching the lat-lon /
# cartesian-2D usage from ESD. Extension to 3D is follow-up.

# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------

"""
    _gather(arr, idx) -> Vector

Gather the elements of `arr` at the flat indices in `idx`. Boundary sentinels
(`0`) must have been resolved by the grid impl; this helper does NOT handle
sentinels. Callers that may see sentinels should use [`_gather_safe`](@ref).
"""
@inline _gather(arr::AbstractVector, idx::AbstractVector{Int}) = arr[idx]

"""
    _gather_safe(arr, idx, fallback_idx) -> Vector

Gather from `arr` at `idx`, substituting `fallback_idx` at every position
where `idx == 0` (the Tier-C boundary sentinel per RFC §3). Used when an
assembler cannot assume the grid resolves all boundary neighbors.
"""
function _gather_safe(arr::AbstractVector, idx::AbstractVector{Int}, fallback_idx::AbstractVector{Int})
    n = length(idx)
    out = similar(arr, n)
    @inbounds for k in 1:n
        out[k] = arr[idx[k] == 0 ? fallback_idx[k] : idx[k]]
    end
    return out
end

"""
    _uniform_dx(grid, axis) -> Float64

Return the uniform per-cell width on `axis` if `cell_widths(grid, axis)` is
constant; otherwise throw. The current assembly path assumes uniform
computational-space widths (dξ, dη), matching the ESD reference.
Non-uniform computational-space widths are a follow-up.
"""
function _uniform_dx(grid::AbstractGrid, axis::Symbol)
    widths = cell_widths(grid, axis)
    w0 = first(widths)
    all(w -> w ≈ w0, widths) ||
        throw(ArgumentError("grid_assembly currently requires uniform $(axis) widths; got non-uniform cell_widths($axis)"))
    return Float64(w0)
end

function _cell_widths_vec(grid::AbstractGrid, axis::Symbol)::Vector{Float64}
    return Vector{Float64}(cell_widths(grid, axis))
end

# ---------------------------------------------------------------------------
# FV Laplacian stencil (9-point covariant Laplacian, 2D curvilinear)
# ---------------------------------------------------------------------------

"""
    FVLaplacianStencil

Precomputed weights + neighbor indices for the full 2D covariant Laplacian
on an `AbstractCurvilinearGrid`:

    ∇²φ = g^{ξξ} ∂²φ/∂ξ² + 2 g^{ξη} ∂²φ/∂ξ∂η + g^{ηη} ∂²φ/∂η²
        + (1/J) [ ∂(J g^{ξξ})/∂ξ · ∂φ/∂ξ
                + ∂(J g^{ηη})/∂η · ∂φ/∂η
                + ∂(J g^{ξη})/∂η · ∂φ/∂ξ
                + ∂(J g^{ξη})/∂ξ · ∂φ/∂η ]

Stored as a flat 9-point stencil `(N_cells, 9)`:

    1 = center, 2 = E (+ξ), 3 = W (−ξ),
    4 = N (+η), 5 = S (−η),
    6 = NE, 7 = NW, 8 = SE, 9 = SW.

At each cell `c`, `∇²φ[c] = Σ_k weights[c,k] · φ[neighbors[c,k]]`.
"""
struct FVLaplacianStencil
    weights::Matrix{Float64}     # (N, 9)
    neighbors::Matrix{Int}       # (N, 9)
end

"""
    precompute_laplacian_stencil(grid::AbstractCurvilinearGrid;
                                 xi_axis::Symbol=:xi, eta_axis::Symbol=:eta)
                                 -> FVLaplacianStencil

Build the 9-point covariant Laplacian stencil against the Grid trait. The
metric derivatives `∂(J g^{ij})/∂x^k` needed by the first-derivative
correction terms are computed by centered finite-differencing the
`metric_jacobian(grid)` and `metric_ginv(grid)` bulk arrays using
`neighbor_indices(grid, axis, ±1)` — no extra trait method required.

The two computational axes default to `(:xi, :eta)`; pass explicit axis
symbols for grids that use other names (`:x`/`:y`, `:lon`/`:lat`).

Returns an [`FVLaplacianStencil`](@ref) consumed by the symbolic ArrayOp
builder [`fv_laplacian_extended`](@ref) in `ext/grid_assembly_symbolic.jl`.
"""
function precompute_laplacian_stencil(
        grid::AbstractCurvilinearGrid;
        xi_axis::Symbol = :xi,
        eta_axis::Symbol = :eta,
    )
    N = n_cells(grid)
    dξ = _cell_widths_vec(grid, xi_axis)
    dη = _cell_widths_vec(grid, eta_axis)

    # Tier-M bulk arrays.
    g_inv = metric_ginv(grid)                  # (N, 2, 2)
    J     = metric_jacobian(grid)              # (N,)
    size(g_inv) == (N, 2, 2) || throw(ArgumentError(
        "precompute_laplacian_stencil: metric_ginv shape $(size(g_inv)) != (N=$N, 2, 2); 2D curvilinear only"))

    # Extract per-cell metric components as Vectors (bulk form, no per-cell loop).
    gxx = view(g_inv, :, 1, 1)                 # g^{ξξ}
    gyy = view(g_inv, :, 2, 2)                 # g^{ηη}
    gxe = view(g_inv, :, 1, 2)                 # g^{ξη}

    # Neighbor index arrays for the 9-point stencil.
    nb_E = neighbor_indices(grid, xi_axis, +1)
    nb_W = neighbor_indices(grid, xi_axis, -1)
    nb_N = neighbor_indices(grid, eta_axis, +1)
    nb_S = neighbor_indices(grid, eta_axis, -1)
    self = collect(1:N)

    # Safe variants: if the grid returned sentinel 0 at a boundary, fall back
    # to self (produces a zero-weighted contribution there; boundary handling
    # is the caller's responsibility via ghost cells or BCs).
    E = map((n, s) -> n == 0 ? s : n, nb_E, self)
    W = map((n, s) -> n == 0 ? s : n, nb_W, self)
    Np = map((n, s) -> n == 0 ? s : n, nb_N, self)
    Sp = map((n, s) -> n == 0 ? s : n, nb_S, self)

    # Diagonal neighbors by composing axis-aligned steps (ξ first, then η).
    NE = neighbor_indices(grid, eta_axis, +1)[E]
    NW = neighbor_indices(grid, eta_axis, +1)[W]
    SE = neighbor_indices(grid, eta_axis, -1)[E]
    SW = neighbor_indices(grid, eta_axis, -1)[W]
    NE = map((n, s) -> n == 0 ? s : n, NE, self)
    NW = map((n, s) -> n == 0 ? s : n, NW, self)
    SE = map((n, s) -> n == 0 ? s : n, SE, self)
    SW = map((n, s) -> n == 0 ? s : n, SW, self)

    # Bulk-array centered differences of J·g^{ij} in computational space.
    Jgxx = J .* gxx                            # (N,)
    Jgyy = J .* gyy
    Jgxe = J .* gxe
    dJgxx_dξ = (Jgxx[E] .- Jgxx[W]) ./ (2 * dξ)
    dJgyy_dη = (Jgyy[Np] .- Jgyy[Sp]) ./ (2 * dη)
    dJgxe_dξ = (Jgxe[E] .- Jgxe[W]) ./ (2 * dξ)
    dJgxe_dη = (Jgxe[Np] .- Jgxe[Sp]) ./ (2 * dη)

    # Assemble the 9-point weights. Indexing into vectors is element-wise.
    invJ = 1.0 ./ J

    orth_dxi_corr  = invJ .* dJgxx_dξ ./ (2 * dξ)
    orth_deta_corr = invJ .* dJgyy_dη ./ (2 * dη)

    cross_d2   = 2 .* gxe ./ (4 .* dξ .* dη)
    cross_dxi  = invJ .* dJgxe_dη ./ (2 * dξ)
    cross_deta = invJ .* dJgxe_dξ ./ (2 * dη)

    weights = Matrix{Float64}(undef, N, 9)
    @inbounds begin
        @. weights[:, 1] = -2 * gxx / dξ^2 - 2 * gyy / dη^2           # C
        @. weights[:, 2] = gxx / dξ^2 + orth_dxi_corr  + cross_dxi    # E
        @. weights[:, 3] = gxx / dξ^2 - orth_dxi_corr  - cross_dxi    # W
        @. weights[:, 4] = gyy / dη^2 + orth_deta_corr + cross_deta   # N
        @. weights[:, 5] = gyy / dη^2 - orth_deta_corr - cross_deta   # S
        @. weights[:, 6] = +cross_d2                                   # NE
        @. weights[:, 7] = -cross_d2                                   # NW
        @. weights[:, 8] = -cross_d2                                   # SE
        @. weights[:, 9] = +cross_d2                                   # SW
    end

    neighbors = Matrix{Int}(undef, N, 9)
    @inbounds begin
        neighbors[:, 1] .= self
        neighbors[:, 2] .= E
        neighbors[:, 3] .= W
        neighbors[:, 4] .= Np
        neighbors[:, 5] .= Sp
        neighbors[:, 6] .= NE
        neighbors[:, 7] .= NW
        neighbors[:, 8] .= SE
        neighbors[:, 9] .= SW
    end

    return FVLaplacianStencil(weights, neighbors)
end

# ---------------------------------------------------------------------------
# FV Gradient stencil (5-point, 2D curvilinear, chain-rule physical targets)
# ---------------------------------------------------------------------------

"""
    FVGradientStencil

Precomputed 5-point stencil for `∂φ/∂(target_axis_1)` and
`∂φ/∂(target_axis_2)` under the chain-rule transformation from
computational `(ξ, η)` to a physical target coordinate system.

Stencil point order: `1 = C, 2 = E, 3 = W, 4 = N, 5 = S`.
"""
struct FVGradientStencil
    weights_t1::Matrix{Float64}   # (N, 5) — ∂φ/∂(target_axis_1)
    weights_t2::Matrix{Float64}   # (N, 5) — ∂φ/∂(target_axis_2)
    neighbors::Matrix{Int}        # (N, 5)
end

"""
    precompute_gradient_stencil(grid::AbstractCurvilinearGrid, target::Symbol;
                                xi_axis::Symbol=:xi, eta_axis::Symbol=:eta)
                                -> FVGradientStencil

Build stencils for the gradient in the physical `target` coordinate system
(e.g. `:lon_lat`, resolved by the grid's `coord_jacobian(grid, target)`).

The chain rule gives:

    ∂φ/∂t1 = (∂ξ/∂t1) · ∂φ/∂ξ + (∂η/∂t1) · ∂φ/∂η
    ∂φ/∂t2 = (∂ξ/∂t2) · ∂φ/∂ξ + (∂η/∂t2) · ∂φ/∂η

with `∂φ/∂ξ ≈ (φ_E - φ_W) / (2 dξ)` and similarly for η.

`target` is passed through to `coord_jacobian(grid, target)`; the returned
array has shape `(N, 2, 2)` (first computational axis varies along dim 2,
target axis varies along dim 3). The resulting stencils are independent of
the target's axis labels.
"""
function precompute_gradient_stencil(
        grid::AbstractCurvilinearGrid,
        target::Symbol;
        xi_axis::Symbol = :xi,
        eta_axis::Symbol = :eta,
    )
    N = n_cells(grid)
    dξ = _cell_widths_vec(grid, xi_axis)
    dη = _cell_widths_vec(grid, eta_axis)

    cj = coord_jacobian(grid, target)          # (N, 2, 2)  :: ∂(ξ_k)/∂(t_l)
    size(cj) == (N, 2, 2) || throw(ArgumentError(
        "precompute_gradient_stencil: coord_jacobian shape $(size(cj)) != (N=$N, 2, 2); 2D curvilinear only"))

    dξ_dt1 = view(cj, :, 1, 1)
    dη_dt1 = view(cj, :, 2, 1)
    dξ_dt2 = view(cj, :, 1, 2)
    dη_dt2 = view(cj, :, 2, 2)

    self = collect(1:N)
    nb_E = neighbor_indices(grid, xi_axis, +1)
    nb_W = neighbor_indices(grid, xi_axis, -1)
    nb_N = neighbor_indices(grid, eta_axis, +1)
    nb_S = neighbor_indices(grid, eta_axis, -1)
    E = map((n, s) -> n == 0 ? s : n, nb_E, self)
    W = map((n, s) -> n == 0 ? s : n, nb_W, self)
    Np = map((n, s) -> n == 0 ? s : n, nb_N, self)
    Sp = map((n, s) -> n == 0 ? s : n, nb_S, self)

    w1 = zeros(N, 5); w2 = zeros(N, 5)
    @inbounds begin
        @. w1[:, 1] = 0.0
        @. w1[:, 2] =  dξ_dt1 / (2 * dξ)
        @. w1[:, 3] = -dξ_dt1 / (2 * dξ)
        @. w1[:, 4] =  dη_dt1 / (2 * dη)
        @. w1[:, 5] = -dη_dt1 / (2 * dη)

        @. w2[:, 1] = 0.0
        @. w2[:, 2] =  dξ_dt2 / (2 * dξ)
        @. w2[:, 3] = -dξ_dt2 / (2 * dξ)
        @. w2[:, 4] =  dη_dt2 / (2 * dη)
        @. w2[:, 5] = -dη_dt2 / (2 * dη)
    end

    nbs = Matrix{Int}(undef, N, 5)
    nbs[:, 1] .= self
    nbs[:, 2] .= E
    nbs[:, 3] .= W
    nbs[:, 4] .= Np
    nbs[:, 5] .= Sp

    return FVGradientStencil(w1, w2, nbs)
end

# ---------------------------------------------------------------------------
# Symbolic ArrayOp assembly (esm-tet) — MTK-ext stubs
#
# The Symbolics/ModelingToolkit-dependent counterparts of the numeric
# stencils above live in ext/grid_assembly_symbolic.jl and only become
# callable when the MTK extension loads. We declare empty `function` bodies
# here so the symbol exists at parent-module load time and downstream code
# can `import EarthSciSerialization: fv_laplacian_extended` even when the
# extension has not yet been triggered. Calling any of these without
# loading `ModelingToolkit` (which triggers the extension) hits the usual
# Julia "no method matching" — that's the intended diagnostic.
# ---------------------------------------------------------------------------

function fv_laplacian_extended end
function fv_gradient_extended end
function const_wrap end
function get_idx_vars end
function make_arrayop end
function evaluate_arrayop end
function laplacian_neighbor_table end
function gradient_neighbor_table end
function _build_rhs_arrayop end
