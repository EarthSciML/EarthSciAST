# Trait-generic ghost-cell gathering (esm-dlz).
#
# Resolves ghost cells purely through `neighbor_indices(grid, axis, ±g)`, with
# no struct-field access and no per-family branching — boundary-crossing
# connectivity is entirely the grid impl's responsibility. The output layout
# is flat-first: for
# a D-axis grid with halo width `Ng` the extended tensor has shape
# `(N_cells, 2Ng+1, …, 2Ng+1)` with one trailing `(2Ng+1,)` dimension per axis,
# so `ext[c, g1+Ng+1, …, gD+Ng+1]` is the value at the cell reached by stepping
# `g1` cells along `axes[1]`, `g2` along `axes[2]`, … from cell `c`.
#
# Corner cells (e.g. `(gi, gj) = (+Ng, +Ng)` on a grid where two boundary
# crossings compose) are resolved via composition of `neighbor_indices` calls —
# axes are applied one at a time, so a corner fill emerges from the grid impl's
# `neighbor_indices(..., axis, ±g)` returning a valid flat index after each
# crossing. No extra trait method is required for scalar ghosts.
#
# The vector-field variant (`extend_with_ghosts_vector`) applies a rotation to
# each `(u1, u2)` pair before storing; the rotation tensor is supplied by the
# caller because ESS does not (yet) own a trait method for ghost-face rotation
# matrices. Adding `ghost_rotation(grid, Ng)` as a Tier-M extension is tracked
# as a follow-up RFC addendum (see module docstring in `abstract_grid.jl`).

"""
    extend_with_ghosts(u, grid::AbstractGrid; Ng::Int=1, axes=axis_names(grid))
        -> Array

Gather ghost values of the flat scalar field `u` (length `n_cells(grid)`) into
an extended tensor shaped `(N_cells, 2Ng+1, …, 2Ng+1)` with one trailing
`(2Ng+1,)` dimension per element of `axes`. `ext[c, g_1+Ng+1, …, g_D+Ng+1]` is
the value of `u` at the cell reached by stepping `g_1` cells along `axes[1]`,
`g_2` along `axes[2]`, … from cell `c`. The center column
`(g_1, …, g_D) = (0, …, 0)` equals `u[c]`.

Boundary-crossing connectivity (periodic wrap, unstructured neighbor tables,
etc.) is resolved inside the grid's `neighbor_indices`; ESS merely composes
them. `neighbor_indices` sentinels (`0`) are resolved by clamping to the source
cell, producing a well-defined extended tensor even at open boundaries.

Uses only the Tier-C method [`neighbor_indices`](@ref); no new trait method
required.
"""
function extend_with_ghosts(u::AbstractVector, grid::AbstractGrid;
        Ng::Int = 1, axes = axis_names(grid))
    Ng >= 0 || throw(ArgumentError("extend_with_ghosts: Ng must be non-negative, got $Ng"))
    N = n_cells(grid)
    length(u) == N || throw(DimensionMismatch(
        "extend_with_ghosts: length(u) = $(length(u)) != n_cells(grid) = $N"))
    D = length(axes)
    shape = (N, ntuple(_ -> 2Ng + 1, D)...)
    ext = Array{eltype(u), D + 1}(undef, shape)
    fill_ghost_cells!(ext, u, grid; Ng = Ng, axes = axes)
    return ext
end

"""
    fill_ghost_cells!(ext, u, grid::AbstractGrid; Ng::Int=1, axes=axis_names(grid))
        -> ext

In-place version of [`extend_with_ghosts`](@ref). `ext` must have shape
`(n_cells(grid), 2Ng+1, …, 2Ng+1)` with one trailing `(2Ng+1,)` dimension per
axis; its contents are overwritten. Returns `ext`.
"""
function fill_ghost_cells!(ext::AbstractArray, u::AbstractVector, grid::AbstractGrid;
        Ng::Int = 1, axes = axis_names(grid))
    Ng >= 0 || throw(ArgumentError("fill_ghost_cells!: Ng must be non-negative, got $Ng"))
    N = n_cells(grid)
    length(u) == N || throw(DimensionMismatch(
        "fill_ghost_cells!: length(u) = $(length(u)) != n_cells(grid) = $N"))
    D = length(axes)
    ndims(ext) == D + 1 || throw(DimensionMismatch(
        "fill_ghost_cells!: ext has $(ndims(ext)) dims but axes has length $D (expected $(D+1))"))
    size(ext, 1) == N || throw(DimensionMismatch(
        "fill_ghost_cells!: size(ext, 1) = $(size(ext, 1)) != n_cells(grid) = $N"))
    for k in 1:D
        size(ext, k + 1) == 2Ng + 1 || throw(DimensionMismatch(
            "fill_ghost_cells!: size(ext, $(k+1)) = $(size(ext, k+1)) != 2Ng+1 = $(2Ng+1)"))
    end

    # Iterate every ghost-position multi-offset (g_1, …, g_D) ∈ (-Ng:Ng)^D.
    offset_ranges = ntuple(_ -> -Ng:Ng, D)
    for offsets in Iterators.product(offset_ranges...)
        idx = _compose_neighbor_indices(grid, axes, offsets, N)
        # Column position in `ext`: offset g maps to index g + Ng + 1.
        col_idx = ntuple(k -> offsets[k] + Ng + 1, D)
        col = view(ext, :, col_idx...)
        @inbounds for c in 1:N
            src = idx[c]
            col[c] = u[src == 0 ? c : src]
        end
    end
    return ext
end

"""
    _compose_neighbor_indices(grid, axes, offsets, N) -> Vector{Int}

Compose `neighbor_indices(grid, axes[k], offsets[k])` one axis at a time,
propagating the boundary sentinel (`0`) through the composition. Returns an
`(N,)` vector of flat indices; entries may be `0` where the composed walk fell
off the grid at any stage.

Axes with `offsets[k] == 0` are skipped (they contribute the identity step).
"""
function _compose_neighbor_indices(grid::AbstractGrid, axes, offsets::NTuple{D,Int}, N::Int) where {D}
    # Start at identity (each cell is "at" itself).
    out = collect(1:N)
    for k in 1:D
        g = offsets[k]
        g == 0 && continue
        step = neighbor_indices(grid, axes[k], g)::AbstractVector{<:Integer}
        length(step) == N || throw(DimensionMismatch(
            "neighbor_indices($(axes[k]), $g) returned length $(length(step)), expected $N"))
        new = Vector{Int}(undef, N)
        @inbounds for c in 1:N
            s = out[c]
            new[c] = (s == 0) ? 0 : step[s]
        end
        out = new
    end
    return out
end

"""
    extend_with_ghosts_vector(u1, u2, grid::AbstractGrid;
                              rotation::AbstractArray{<:Real,4},
                              Ng::Int=1, axes=axis_names(grid))
        -> (ext1, ext2)

Vector-field variant of [`extend_with_ghosts`](@ref) for a 2-component field
`(u1, u2)` on a 2D grid (`length(axes) == 2`). Each ghost value is rotated by
the provided per-position 2×2 matrix so the stored components are expressed in
the *query cell's* local basis — necessary for curvilinear grids where the
local basis changes from cell to cell.

The `rotation` argument has shape `(N_cells, 2Ng+1, 2Ng+1, 4)`, where
`rotation[c, g_ξ+Ng+1, g_η+Ng+1, :]` holds `(M11, M12, M21, M22)` — the rotation
that converts `(u1, u2)` at the source cell into the basis of cell `c` at the
ghost position `(g_ξ, g_η)`. The caller precomputes this tensor from the
grid impl; ESS applies it.

The center position `(g_ξ, g_η) = (0, 0)` should be identity (`M11=M22=1`,
`M12=M21=0`); we do not enforce this so that callers can also use this routine
to apply an arbitrary per-cell tensor transform to a ghost extension.

Adding a trait method `ghost_rotation(grid, Ng)` that returns this tensor is a
planned Tier-M extension (follow-up RFC addendum); see the bead description
of `esm-dlz`.
"""
function extend_with_ghosts_vector(u1::AbstractVector, u2::AbstractVector,
        grid::AbstractGrid;
        rotation::AbstractArray{<:Real, 4},
        Ng::Int = 1, axes = axis_names(grid))
    Ng >= 0 || throw(ArgumentError("extend_with_ghosts_vector: Ng must be non-negative, got $Ng"))
    length(axes) == 2 || throw(ArgumentError(
        "extend_with_ghosts_vector: vector variant requires 2D (length(axes) == 2), got $(length(axes))"))
    N = n_cells(grid)
    length(u1) == length(u2) == N || throw(DimensionMismatch(
        "extend_with_ghosts_vector: u1/u2 must have length n_cells(grid) = $N"))
    size(rotation) == (N, 2Ng + 1, 2Ng + 1, 4) || throw(DimensionMismatch(
        "extend_with_ghosts_vector: rotation shape $(size(rotation)) != (N=$N, $(2Ng+1), $(2Ng+1), 4)"))

    ext1 = extend_with_ghosts(u1, grid; Ng = Ng, axes = axes)
    ext2 = extend_with_ghosts(u2, grid; Ng = Ng, axes = axes)
    T = promote_type(eltype(ext1), eltype(ext2), eltype(rotation))
    out1 = Array{T, 3}(undef, N, 2Ng + 1, 2Ng + 1)
    out2 = Array{T, 3}(undef, N, 2Ng + 1, 2Ng + 1)
    @inbounds for gj in 1:(2Ng + 1), gi in 1:(2Ng + 1), c in 1:N
        M11 = rotation[c, gi, gj, 1]
        M12 = rotation[c, gi, gj, 2]
        M21 = rotation[c, gi, gj, 3]
        M22 = rotation[c, gi, gj, 4]
        v1 = ext1[c, gi, gj]
        v2 = ext2[c, gi, gj]
        out1[c, gi, gj] = M11 * v1 + M12 * v2
        out2[c, gi, gj] = M21 * v1 + M22 * v2
    end
    return (out1, out2)
end
