# Tests for esm-dlz: trait-generic ghost-cell gathering.
#
# We exercise the extend_with_ghosts / fill_ghost_cells! / vector-variant
# routines against (a) a periodic 2D Cartesian grid with trivial identity
# metric, and (b) a minimal two-block test grid that swaps axes on crossing
# so that the corner ghost (two edge crossings) composes to a non-trivial
# flat index. That second grid is a synthetic stand-in for any grid family
# whose boundary crossings re-map the local axes, exercising the generic
# `neighbor_indices`-composed corner-fill path.

using Test
using EarthSciSerialization
using EarthSciSerialization: AbstractCurvilinearGrid, AbstractGrid,
    cell_centers, cell_widths, neighbor_indices, boundary_mask,
    n_cells, n_dims, axis_names,
    extend_with_ghosts, fill_ghost_cells!, extend_with_ghosts_vector

# ---------------------------------------------------------------------------
# Test grid 1: periodic 2D Cartesian (reused pattern from grid_assembly_test).
# Column-major flat: c = i + (j-1)*Nx,  i ∈ 1:Nx, j ∈ 1:Ny.  Periodic wrap.
# ---------------------------------------------------------------------------

struct GhostCartesianGrid <: AbstractGrid
    Nx::Int
    Ny::Int
end
_ghost_flat(g::GhostCartesianGrid, i::Int, j::Int) = i + (j - 1) * g.Nx
_ghost_wrap(idx::Int, n::Int) = mod(idx - 1, n) + 1

EarthSciSerialization.n_cells(g::GhostCartesianGrid) = g.Nx * g.Ny
EarthSciSerialization.n_dims(g::GhostCartesianGrid) = 2
EarthSciSerialization.axis_names(g::GhostCartesianGrid) = (:x, :y)

function EarthSciSerialization.neighbor_indices(g::GhostCartesianGrid, axis::Symbol, offset::Int)
    N = n_cells(g)
    out = Vector{Int}(undef, N)
    for j in 1:g.Ny, i in 1:g.Nx
        c = _ghost_flat(g, i, j)
        if axis === :x
            ni = _ghost_wrap(i + offset, g.Nx)
            out[c] = _ghost_flat(g, ni, j)
        elseif axis === :y
            nj = _ghost_wrap(j + offset, g.Ny)
            out[c] = _ghost_flat(g, i, nj)
        else
            throw(ArgumentError("unknown axis $axis"))
        end
    end
    return out
end

# ---------------------------------------------------------------------------
# Test grid 2: a minimal two-panel non-Cartesian grid that swaps axes on
# crossing the east boundary. Cells are 3×3 per panel, 2 panels, flat order
#   p=1: c = i + (j-1)*3,         i,j ∈ 1:3      → c ∈ 1:9
#   p=2: c = 9 + i + (j-1)*3,     i,j ∈ 1:3      → c ∈ 10:18
# Panel 1 east (i=Nx+g) → panel 2 at (j, g)   ← axis swap
# Panel 2 east (i=Nx+g) → panel 1 at (j, g)   ← round-trip
# Y-axis is periodic within each panel (so corner-fill composes with a panel
# crossing). The axis-swap on :x, +g means that stepping "+g east, +k north"
# from a panel-1 cell reaches a different flat index than "+k north, +g east",
# which exercises corner composition via neighbor_indices.
# ---------------------------------------------------------------------------

struct SwappingPanelGrid <: AbstractGrid
    Nc::Int        # per-panel size (Nx = Ny = Nc)
end
_sp_flat(g::SwappingPanelGrid, p::Int, i::Int, j::Int) =
    (p - 1) * g.Nc * g.Nc + i + (j - 1) * g.Nc
_sp_panel(g::SwappingPanelGrid, c::Int) = ((c - 1) ÷ (g.Nc * g.Nc)) + 1
_sp_local(g::SwappingPanelGrid, c::Int) =
    let cl = mod1(c, g.Nc * g.Nc)
        ((cl - 1) % g.Nc + 1, (cl - 1) ÷ g.Nc + 1)
    end

EarthSciSerialization.n_cells(g::SwappingPanelGrid) = 2 * g.Nc * g.Nc
EarthSciSerialization.n_dims(g::SwappingPanelGrid) = 2
EarthSciSerialization.axis_names(g::SwappingPanelGrid) = (:xi, :eta)

function EarthSciSerialization.neighbor_indices(g::SwappingPanelGrid, axis::Symbol, offset::Int)
    N = n_cells(g); Nc = g.Nc
    out = Vector{Int}(undef, N)
    for c in 1:N
        p = _sp_panel(g, c); i, j = _sp_local(g, c)
        if axis === :xi
            k = i + offset
            if 1 <= k <= Nc
                out[c] = _sp_flat(g, p, k, j)
            elseif k > Nc
                # east → swap to other panel with i' = j, j' = k - Nc
                p2 = (p == 1 ? 2 : 1)
                i2 = j; j2 = k - Nc
                if 1 <= j2 <= Nc && 1 <= i2 <= Nc
                    out[c] = _sp_flat(g, p2, i2, j2)
                else
                    out[c] = 0  # fell off the second panel too — sentinel
                end
            else  # k < 1, west boundary: open (no wrap)
                out[c] = 0
            end
        elseif axis === :eta
            k = j + offset
            # y-periodic within each panel
            k_w = _ghost_wrap(k, Nc)
            out[c] = _sp_flat(g, p, i, k_w)
        else
            throw(ArgumentError("unknown axis $axis"))
        end
    end
    return out
end

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@testset "ghost_cells: trait-generic (esm-dlz)" begin

    @testset "scalar: periodic Cartesian, Ng=1" begin
        g = GhostCartesianGrid(4, 3)
        N = n_cells(g)
        u = Float64[100 * mod1(c, 4) + (c - 1) ÷ 4 for c in 1:N]  # unique values

        ext = extend_with_ghosts(u, g; Ng = 1)
        @test size(ext) == (N, 3, 3)

        # Center column (g_x = g_y = 0) must match u.
        @test all(ext[:, 2, 2] .== u)

        # (+1, 0) must equal neighbor_indices(:x, +1) gather.
        idx_E = neighbor_indices(g, :x, +1)
        @test ext[:, 3, 2] == u[idx_E]
        # (0, +1) must equal neighbor_indices(:y, +1) gather.
        idx_N = neighbor_indices(g, :y, +1)
        @test ext[:, 2, 3] == u[idx_N]
        # Corner (+1, +1) must equal the composition: step x+1 first, then y+1.
        @test ext[:, 3, 3] == u[neighbor_indices(g, :y, +1)[idx_E]]
        # Periodic wrap commutes → composition order doesn't matter here.
        @test ext[:, 3, 3] == u[neighbor_indices(g, :x, +1)[idx_N]]
    end

    @testset "scalar: periodic Cartesian, Ng=2 exercises ±2 shells" begin
        g = GhostCartesianGrid(6, 5)
        N = n_cells(g)
        u = collect(Float64, 1:N)

        ext = extend_with_ghosts(u, g; Ng = 2)
        @test size(ext) == (N, 5, 5)
        # Center
        @test all(ext[:, 3, 3] .== u)
        # (+2, 0): should equal neighbor_indices(:x, +2) gather.
        idx_EE = neighbor_indices(g, :x, +2)
        @test ext[:, 5, 3] == u[idx_EE]
        # (-2, 0)
        idx_WW = neighbor_indices(g, :x, -2)
        @test ext[:, 1, 3] == u[idx_WW]
        # (+2, +2) diag
        @test ext[:, 5, 5] == u[neighbor_indices(g, :y, +2)[idx_EE]]
    end

    @testset "scalar: fill_ghost_cells! validates shapes" begin
        g = GhostCartesianGrid(3, 3)
        u = rand(n_cells(g))
        bad = Array{Float64, 3}(undef, n_cells(g), 4, 4)   # wrong (2Ng+1) dim
        @test_throws DimensionMismatch fill_ghost_cells!(bad, u, g; Ng = 1)

        bad2 = Array{Float64, 3}(undef, n_cells(g) + 1, 3, 3)
        @test_throws DimensionMismatch fill_ghost_cells!(bad2, u, g; Ng = 1)

        @test_throws DimensionMismatch fill_ghost_cells!(
            Array{Float64, 2}(undef, n_cells(g), 3), u, g; Ng = 1)

        @test_throws ArgumentError extend_with_ghosts(u, g; Ng = -1)
    end

    @testset "scalar: Ng=0 collapses to the center column" begin
        g = GhostCartesianGrid(3, 4)
        u = rand(n_cells(g))
        ext = extend_with_ghosts(u, g; Ng = 0)
        @test size(ext) == (n_cells(g), 1, 1)
        @test ext[:, 1, 1] == u
    end

    @testset "scalar: corner fill via two crossings (swapping-panel grid)" begin
        # The swapping-panel grid makes y-first vs x-first composition yield
        # different flat indices at corners crossing the panel edge, so the
        # corner-fill semantics (which axis we step first) is observable.
        g = SwappingPanelGrid(3)
        N = n_cells(g)           # 18
        u = collect(Float64, 1:N)
        ext = extend_with_ghosts(u, g; Ng = 2)
        @test size(ext) == (N, 5, 5)
        @test ext[:, 3, 3] == u  # center

        # Pick a panel-1 cell close to the east boundary: (i,j) = (3, 1), c = 3.
        # Corner step (+1, +1) = step xi=+1 (east → crosses to panel 2 at (j=1, g=1))
        # then step eta=+1 on that cell (periodic within panel 2).
        c = 3  # panel 1, (i=3, j=1)
        step_xi_p1 = neighbor_indices(g, :xi, +1)
        after_xi = step_xi_p1[c]
        step_eta_p1 = neighbor_indices(g, :eta, +1)
        corner_expected = step_eta_p1[after_xi]
        @test ext[c, 4, 4] == u[corner_expected]

        # The opposite axis order (eta first, then xi) gives a different
        # neighbor for this cell, because eta-first keeps us on panel 1 at
        # (3, 2) and xi-stepping from there goes to panel 2 at (i=2, j=1),
        # whereas xi-first lands on panel 2 at (1, 1) then eta-step to
        # (1, 2). We verify the *implementation order* (xi first, then eta).
        step_eta_first = step_eta_p1[c]
        alt = step_xi_p1[step_eta_first]
        @test alt != corner_expected  # grid is non-commutative at this corner
    end

    @testset "scalar: sentinel resolution clamps to source cell" begin
        # Use the swapping-panel grid: west-step off panel 1 returns sentinel 0.
        # extend_with_ghosts must fall back to u[c] rather than throwing.
        g = SwappingPanelGrid(3)
        N = n_cells(g)
        u = fill(-1.0, N)
        u[1] = 7.0  # panel 1, (i=1, j=1) — its west neighbor is sentinel
        ext = extend_with_ghosts(u, g; Ng = 1)
        # (g_xi = -1, g_eta = 0) for cell 1 should clamp to u[1] since
        # neighbor_indices returned 0.
        @test ext[1, 1, 2] == 7.0
    end

    @testset "vector: identity rotation reduces to scalar extension" begin
        g = GhostCartesianGrid(4, 4)
        N = n_cells(g); Ng = 1
        u1 = collect(Float64, 1:N); u2 = u1 .+ 100.0
        # Identity rotation at every ghost position
        R = zeros(N, 2Ng + 1, 2Ng + 1, 4)
        R[:, :, :, 1] .= 1.0; R[:, :, :, 4] .= 1.0

        e1, e2 = extend_with_ghosts_vector(u1, u2, g; rotation = R, Ng = Ng)
        @test e1 == extend_with_ghosts(u1, g; Ng = Ng)
        @test e2 == extend_with_ghosts(u2, g; Ng = Ng)
    end

    @testset "vector: non-identity rotation applied per-position" begin
        g = GhostCartesianGrid(3, 3)
        N = n_cells(g); Ng = 1
        # u1 = 1, u2 = 0 everywhere → after 90° rotation (M = [[0,-1],[1,0]])
        # at one ghost position, that position's (u1', u2') = (0, 1).
        u1 = ones(N); u2 = zeros(N)
        R = zeros(N, 3, 3, 4)
        R[:, :, :, 1] .= 1.0; R[:, :, :, 4] .= 1.0  # identity baseline
        # Apply 90° rotation at the (+1, 0) ghost position for every cell.
        R[:, 3, 2, 1] .= 0.0
        R[:, 3, 2, 2] .= -1.0
        R[:, 3, 2, 3] .= 1.0
        R[:, 3, 2, 4] .= 0.0

        e1, e2 = extend_with_ghosts_vector(u1, u2, g; rotation = R, Ng = Ng)
        @test all(e1[:, 3, 2] .== 0.0)  # u1' = 0*1 + (-1)*0 = 0
        @test all(e2[:, 3, 2] .== 1.0)  # u2' = 1*1 +   0 *0 = 1
        # Center unchanged (identity)
        @test e1[:, 2, 2] == u1
        @test e2[:, 2, 2] == u2
    end

    @testset "vector: input validation" begin
        g = GhostCartesianGrid(3, 3)
        N = n_cells(g)
        u1 = zeros(N); u2 = zeros(N)
        bad_R = zeros(N, 3, 3, 3)  # wrong last dim
        @test_throws DimensionMismatch extend_with_ghosts_vector(
            u1, u2, g; rotation = bad_R, Ng = 1)

        # Length mismatch
        @test_throws DimensionMismatch extend_with_ghosts_vector(
            u1[1:end - 1], u2, g; rotation = zeros(N, 3, 3, 4), Ng = 1)

        # 3D axes (not allowed by the vector variant).
        @test_throws ArgumentError extend_with_ghosts_vector(
            u1, u2, g; rotation = zeros(N, 3, 3, 4), Ng = 1, axes = (:x, :y, :z))

        # Negative Ng
        @test_throws ArgumentError extend_with_ghosts_vector(
            u1, u2, g; rotation = zeros(N, 3, 3, 4), Ng = -1)
    end

    @testset "composed neighbor_indices is used for corner fills" begin
        # Ground-truth check: extend_with_ghosts must produce the same values
        # as manually composing neighbor_indices calls for every (g_ξ, g_η).
        g = SwappingPanelGrid(4)
        N = n_cells(g)
        u = Float64.(1:N) .* 0.25
        Ng = 2
        ext = extend_with_ghosts(u, g; Ng = Ng)

        axes = axis_names(g)
        for gj in -Ng:Ng, gi in -Ng:Ng
            # Manual composition: xi first, then eta. Sentinel propagates.
            step_xi = gi == 0 ? collect(1:N) : neighbor_indices(g, axes[1], gi)
            step_eta = gj == 0 ? collect(1:N) : neighbor_indices(g, axes[2], gj)
            expected = Vector{Float64}(undef, N)
            @inbounds for c in 1:N
                s1 = step_xi[c]
                if s1 == 0
                    expected[c] = u[c]  # clamped to source
                else
                    s2 = gj == 0 ? s1 : step_eta[s1]
                    expected[c] = u[s2 == 0 ? c : s2]
                end
            end
            @test ext[:, gi + Ng + 1, gj + Ng + 1] == expected
        end
    end
end
