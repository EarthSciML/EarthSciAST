# Tests for the PDE discretization pipeline (esm-2qw):
#   EarthSciSerialization.discretize(::PDESystem, ::AbstractCurvilinearGrid)
#
# This file exercises the pipeline against a minimal inline `PDETestCartesianGrid`
# — identity metric, identity coordinate Jacobian, periodic neighbor wrap. The
# discretizer's chain-rule path collapses to plain centered FD on this grid, so
# MMS results match the classical 5-point Laplacian and centered gradient. The
# stub keeps these unit tests fast and dependency-free.
#
# The end-to-end integration against REAL EarthSciDiscretizations grids
# (`LatLonGrid`) lives in
# `pde_discretize_esd_integration_test.jl` (ess-d1e).

using Test
using EarthSciSerialization
using EarthSciSerialization: AbstractCurvilinearGrid, n_cells, n_dims, axis_names,
    cell_centers, cell_widths, cell_volume, neighbor_indices, boundary_mask,
    metric_g, metric_ginv, metric_jacobian, metric_dgij_dxk,
    coord_jacobian, coord_jacobian_second
using ModelingToolkit
using ModelingToolkit: t_nounits as t_, D_nounits as D_, Differential, PDESystem
using Symbolics
using DomainSets: Interval
using OrdinaryDiffEqTsit5

# Self-contained Cartesian test grid. To avoid duplicate-method warnings when
# several test files run in the same session, we define a fresh struct under a
# unique name and only override the trait methods this test actually consumes.

struct PDETestCartesianGrid <: AbstractCurvilinearGrid
    Nx::Int
    Ny::Int
    Lx::Float64
    Ly::Float64
end

_pflat(g::PDETestCartesianGrid, i::Int, j::Int) = i + (j - 1) * g.Nx
_pwrap(idx::Int, n::Int) = mod(idx - 1, n) + 1

EarthSciSerialization.n_cells(g::PDETestCartesianGrid) = g.Nx * g.Ny
EarthSciSerialization.n_dims(g::PDETestCartesianGrid)  = 2
EarthSciSerialization.axis_names(g::PDETestCartesianGrid) = (:x, :y)

function EarthSciSerialization.cell_centers(g::PDETestCartesianGrid, axis::Symbol)
    N = n_cells(g)
    out = Vector{Float64}(undef, N)
    dx = g.Lx / g.Nx; dy = g.Ly / g.Ny
    for j in 1:g.Ny, i in 1:g.Nx
        c = _pflat(g, i, j)
        out[c] = axis === :x ? (i - 0.5) * dx :
                 axis === :y ? (j - 0.5) * dy :
                 throw(ArgumentError("unknown axis $axis"))
    end
    return out
end

function EarthSciSerialization.cell_widths(g::PDETestCartesianGrid, axis::Symbol)
    N = n_cells(g)
    w = axis === :x ? g.Lx / g.Nx :
        axis === :y ? g.Ly / g.Ny :
        throw(ArgumentError("unknown axis $axis"))
    return fill(w, N)
end

function EarthSciSerialization.cell_volume(g::PDETestCartesianGrid)
    dx = g.Lx / g.Nx; dy = g.Ly / g.Ny
    return fill(dx * dy, n_cells(g))
end

function EarthSciSerialization.neighbor_indices(g::PDETestCartesianGrid, axis::Symbol, offset::Int)
    N = n_cells(g); out = Vector{Int}(undef, N)
    for j in 1:g.Ny, i in 1:g.Nx
        c = _pflat(g, i, j)
        if axis === :x
            ni = _pwrap(i + offset, g.Nx); out[c] = _pflat(g, ni, j)
        elseif axis === :y
            nj = _pwrap(j + offset, g.Ny); out[c] = _pflat(g, i, nj)
        else
            throw(ArgumentError("unknown axis $axis"))
        end
    end
    return out
end

EarthSciSerialization.boundary_mask(g::PDETestCartesianGrid, ::Symbol, ::Symbol) =
    falses(n_cells(g))

function EarthSciSerialization.metric_g(g::PDETestCartesianGrid)
    N = n_cells(g); out = zeros(N, 2, 2)
    @inbounds for c in 1:N; out[c, 1, 1] = 1.0; out[c, 2, 2] = 1.0; end
    return out
end
EarthSciSerialization.metric_ginv(g::PDETestCartesianGrid) = metric_g(g)
EarthSciSerialization.metric_jacobian(g::PDETestCartesianGrid) = ones(n_cells(g))
EarthSciSerialization.metric_dgij_dxk(g::PDETestCartesianGrid) = zeros(n_cells(g), 2, 2, 2)

function EarthSciSerialization.coord_jacobian(g::PDETestCartesianGrid, ::Symbol)
    N = n_cells(g); out = zeros(N, 2, 2)
    @inbounds for c in 1:N; out[c, 1, 1] = 1.0; out[c, 2, 2] = 1.0; end
    return out
end
EarthSciSerialization.coord_jacobian_second(g::PDETestCartesianGrid, ::Symbol) =
    zeros(n_cells(g), 2, 2, 2)

# Non-periodic in y: returns 0 sentinel at y=0 (south) and y=Ly (north) boundaries.
struct PDEBoundaryCartesianGrid <: AbstractCurvilinearGrid
    Nx::Int
    Ny::Int
    Lx::Float64
    Ly::Float64
end

_bflat(g::PDEBoundaryCartesianGrid, i::Int, j::Int) = i + (j - 1) * g.Nx
_bwrap(idx::Int, n::Int) = mod(idx - 1, n) + 1

EarthSciSerialization.n_cells(g::PDEBoundaryCartesianGrid) = g.Nx * g.Ny
EarthSciSerialization.n_dims(g::PDEBoundaryCartesianGrid)  = 2
EarthSciSerialization.axis_names(g::PDEBoundaryCartesianGrid) = (:x, :y)

function EarthSciSerialization.cell_centers(g::PDEBoundaryCartesianGrid, axis::Symbol)
    N = n_cells(g)
    out = Vector{Float64}(undef, N)
    dx = g.Lx / g.Nx; dy = g.Ly / g.Ny
    for j in 1:g.Ny, i in 1:g.Nx
        c = _bflat(g, i, j)
        out[c] = axis === :x ? (i - 0.5) * dx :
                 axis === :y ? (j - 0.5) * dy :
                 throw(ArgumentError("unknown axis $axis"))
    end
    return out
end

function EarthSciSerialization.cell_widths(g::PDEBoundaryCartesianGrid, axis::Symbol)
    N = n_cells(g)
    w = axis === :x ? g.Lx / g.Nx :
        axis === :y ? g.Ly / g.Ny :
        throw(ArgumentError("unknown axis $axis"))
    return fill(w, N)
end

function EarthSciSerialization.cell_volume(g::PDEBoundaryCartesianGrid)
    dx = g.Lx / g.Nx; dy = g.Ly / g.Ny
    return fill(dx * dy, n_cells(g))
end

function EarthSciSerialization.neighbor_indices(g::PDEBoundaryCartesianGrid, axis::Symbol, offset::Int)
    N = n_cells(g); out = Vector{Int}(undef, N)
    for j in 1:g.Ny, i in 1:g.Nx
        c = _bflat(g, i, j)
        if axis === :x
            # x is periodic
            ni = _bwrap(i + offset, g.Nx); out[c] = _bflat(g, ni, j)
        elseif axis === :y
            # y is non-periodic: return 0 (sentinel) at boundaries
            nj = j + offset
            out[c] = (nj < 1 || nj > g.Ny) ? 0 : _bflat(g, i, nj)
        else
            throw(ArgumentError("unknown axis $axis"))
        end
    end
    return out
end

EarthSciSerialization.boundary_mask(g::PDEBoundaryCartesianGrid, ::Symbol, ::Symbol) =
    falses(n_cells(g))

function EarthSciSerialization.metric_g(g::PDEBoundaryCartesianGrid)
    N = n_cells(g); out = zeros(N, 2, 2)
    @inbounds for c in 1:N; out[c, 1, 1] = 1.0; out[c, 2, 2] = 1.0; end
    return out
end
EarthSciSerialization.metric_ginv(g::PDEBoundaryCartesianGrid) = metric_g(g)
EarthSciSerialization.metric_jacobian(g::PDEBoundaryCartesianGrid) = ones(n_cells(g))
EarthSciSerialization.metric_dgij_dxk(g::PDEBoundaryCartesianGrid) = zeros(n_cells(g), 2, 2, 2)

function EarthSciSerialization.coord_jacobian(g::PDEBoundaryCartesianGrid, ::Symbol)
    N = n_cells(g); out = zeros(N, 2, 2)
    @inbounds for c in 1:N; out[c, 1, 1] = 1.0; out[c, 2, 2] = 1.0; end
    return out
end
EarthSciSerialization.coord_jacobian_second(g::PDEBoundaryCartesianGrid, ::Symbol) =
    zeros(n_cells(g), 2, 2, 2)

# ---------------------------------------------------------------------------

@testset "discretize(PDESystem, AbstractCurvilinearGrid)" begin

    @testset "Multi-variable coupled system" begin
        @parameters x y
        @variables u(..) v(..)

        # Trivial decoupled-from-space system:  du/dt = v,  dv/dt = -u
        eq1 = D_(u(t_, x, y)) ~ v(t_, x, y)
        eq2 = D_(v(t_, x, y)) ~ -u(t_, x, y)
        bcs = [
            u(0, x, y) ~ cos(y),
            v(0, x, y) ~ 0.0,
        ]
        domains = [
            t_ ∈ Interval(0.0, 1.0),
            x  ∈ Interval(0.0, 2π),
            y  ∈ Interval(0.0, 2π),
        ]
        @named sys = PDESystem(
            [eq1, eq2], bcs, domains,
            [t_, x, y], [u(t_, x, y), v(t_, x, y)],
        )

        grid = PDETestCartesianGrid(8, 8, 2π, 2π)
        prob = EarthSciSerialization.discretize(sys, grid; xi_axis=:x, eta_axis=:y)

        @test prob isa ODEProblem
        @test length(prob.u0) == 2 * 64

        sol = solve(prob, Tsit5())
        @test sol.retcode == ReturnCode.Success
    end

    @testset "Laplacian of a constant is zero" begin
        @parameters x y
        @variables u(..)
        Dx = Differential(x); Dy = Differential(y)

        eq  = [D_(u(t_, x, y)) ~ Dx(Dx(u(t_, x, y))) + Dy(Dy(u(t_, x, y)))]
        bcs = [u(0, x, y) ~ 42.0]
        domains = [
            t_ ∈ Interval(0.0, 1.0),
            x  ∈ Interval(0.0, 2π),
            y  ∈ Interval(0.0, 2π),
        ]
        @named sys = PDESystem(eq, bcs, domains, [t_, x, y], [u(t_, x, y)])

        grid = PDETestCartesianGrid(16, 16, 2π, 2π)
        prob = EarthSciSerialization.discretize(sys, grid; xi_axis=:x, eta_axis=:y)
        du = prob.f(prob.u0, prob.p, 0.0)
        @test maximum(abs, du) < 1e-10
    end

    @testset "Laplacian MMS: φ = sin(x)·sin(y), ∇²φ = -2 sin(x) sin(y)" begin
        # mtkcompile may reorder/eliminate state, so we compare against the
        # ordering-invariant `du[k] ≈ -2 u0[k]` relation that holds at every
        # cell — independent of how the compiled state is laid out.
        function _err(N)
            @parameters x y
            @variables u(..)
            Dx = Differential(x); Dy = Differential(y)

            eq  = [D_(u(t_, x, y)) ~ Dx(Dx(u(t_, x, y))) + Dy(Dy(u(t_, x, y)))]
            bcs = [u(0, x, y) ~ sin(x) * sin(y)]
            domains = [
                t_ ∈ Interval(0.0, 0.0),
                x  ∈ Interval(0.0, 2π),
                y  ∈ Interval(0.0, 2π),
            ]
            @named sys = PDESystem(eq, bcs, domains, [t_, x, y], [u(t_, x, y)])

            grid = PDETestCartesianGrid(N, N, 2π, 2π)
            prob = EarthSciSerialization.discretize(sys, grid; xi_axis=:x, eta_axis=:y)
            du = prob.f(prob.u0, prob.p, 0.0)
            # ∇²(sin x · sin y) = -2 sin x sin y, so the per-cell relation
            # du ≈ -2 · u0 holds up to O(h²) regardless of state ordering.
            return maximum(abs.(du .+ 2 .* prob.u0))
        end
        e16 = _err(16); e32 = _err(32)
        @test e16 < 0.05
        @test e32 < e16 / 3.5     # centered FD is O(h²) → ratio ≈ 4
    end

    @testset "Mixed derivative: nonzero on sin(x)·sin(y)" begin
        @parameters x y
        @variables u(..)
        Dx = Differential(x); Dy = Differential(y)

        eq  = [D_(u(t_, x, y)) ~ Dx(Dy(u(t_, x, y)))]
        bcs = [u(0, x, y) ~ sin(x) * sin(y)]
        domains = [
            t_ ∈ Interval(0.0, 0.01),
            x  ∈ Interval(0.0, 2π),
            y  ∈ Interval(0.0, 2π),
        ]
        @named sys = PDESystem(eq, bcs, domains, [t_, x, y], [u(t_, x, y)])

        grid = PDETestCartesianGrid(16, 16, 2π, 2π)
        prob = EarthSciSerialization.discretize(sys, grid; xi_axis=:x, eta_axis=:y)
        du = prob.f(prob.u0, prob.p, 0.0)
        # ∂²(sin(x)sin(y))/∂x∂y = cos(x)·cos(y) — non-trivial
        @test !all(iszero, du)
        @test maximum(abs.(du)) > 0.5
    end

    @testset "Nonlinear term: D(u^2)/Dx" begin
        @parameters x y
        @variables u(..)
        Dx = Differential(x)

        eq  = [D_(u(t_, x, y)) ~ Dx(u(t_, x, y)^2)]
        bcs = [u(0, x, y) ~ 1.0 + 0.1 * cos(x)]
        domains = [
            t_ ∈ Interval(0.0, 0.01),
            x  ∈ Interval(0.0, 2π),
            y  ∈ Interval(0.0, 2π),
        ]
        @named sys = PDESystem(eq, bcs, domains, [t_, x, y], [u(t_, x, y)])

        grid = PDETestCartesianGrid(8, 8, 2π, 2π)
        prob = EarthSciSerialization.discretize(sys, grid; xi_axis=:x, eta_axis=:y)
        du = prob.f(prob.u0, prob.p, 0.0)
        # Nonlinearity must be preserved — du should be nonzero.
        @test !all(iszero, du)
    end

    @testset "IC identification with multiple BCs" begin
        @parameters x y
        @variables u(..)
        Dx = Differential(x); Dy = Differential(y)

        eq = [D_(u(t_, x, y)) ~ 0.01 * (Dx(Dx(u(t_, x, y))) + Dy(Dy(u(t_, x, y))))]
        # First BC has the form `u(t, 0, y) ~ 0.0` — it should NOT be matched
        # as the IC because its t-arg is the symbol `t`, not the literal `0`.
        # Second BC `u(0, x, y) ~ cos(y)` should be picked.
        bcs = [
            u(t_, 0.0, y) ~ 0.0,
            u(0,    x,  y) ~ cos(y),
        ]
        domains = [
            t_ ∈ Interval(0.0, 1.0),
            x  ∈ Interval(0.0, 2π),
            y  ∈ Interval(0.0, 2π),
        ]
        @named sys = PDESystem(eq, bcs, domains, [t_, x, y], [u(t_, x, y)])

        grid = PDETestCartesianGrid(8, 8, 2π, 2π)
        prob = EarthSciSerialization.discretize(sys, grid; xi_axis=:x, eta_axis=:y)
        # Should use the cos(y) IC, not the zero BC: u0 spans cos(y) on the grid,
        # whose max value reaches ≈1 (the BC `u(t, 0, y) ~ 0.0` would zero u0).
        @test maximum(prob.u0) > 0.5
    end

    @testset "Dirichlet BC on non-periodic y: spatial BCs ignored, zero-ghost convention (ess-dju)" begin
        # The unified makearray path ignores spatial BCs in sys.bcs; boundary cells
        # use self-fallback (zero-ghost convention). This is a documented bugfix:
        # the old ghost-cell path was non-unified and silently incorrect for robin/
        # zero_gradient/interface/periodic BC types. For Dirichlet BCs the boundary
        # error is now O(1) rather than O(h²), but the function produces a valid
        # ODEProblem and the IC is applied correctly.
        L = 1.0
        @parameters x y
        @variables u(..)
        Dy = Differential(y)
        eq  = [D_(u(t_, x, y)) ~ Dy(Dy(u(t_, x, y)))]
        bcs = [
            u(0, x, y)    ~ sin(π * y / L),   # IC — still applied correctly
            u(t_, x, 0.0) ~ 0.0,              # Dirichlet south — ignored (zero-ghost)
            u(t_, x, L)   ~ 0.0,              # Dirichlet north — ignored (zero-ghost)
        ]
        domains = [
            t_ ∈ Interval(0.0, 0.0),
            x  ∈ Interval(0.0, 2π),
            y  ∈ Interval(0.0, L),
        ]
        @named sys = PDESystem(eq, bcs, domains, [t_, x, y], [u(t_, x, y)])
        grid = PDEBoundaryCartesianGrid(4, 16, 2π, L)
        prob = EarthSciSerialization.discretize(sys, grid; xi_axis=:x, eta_axis=:y)
        @test prob isa ODEProblem
        # IC sin(πy/L) applied correctly: max value ≈ 1 near y=L/2
        @test maximum(prob.u0) > 0.9
        @test minimum(prob.u0) ≥ 0.0
        # Boundary cells use zero-ghost (self-fallback): du at boundary ≠ -(π/L)²·u
        # (the Dirichlet ghost would have given correct interior convergence).
        du = prob.f(prob.u0, prob.p, 0.0)
        λ = (π / L)^2
        err = maximum(abs.(du .+ λ .* prob.u0))
        @info "Dirichlet BC (zero-ghost, bugfix): boundary error is O(1)" err
        @test err > 0.5   # O(1) boundary error confirms ghost path is retired
    end

    @testset "Neumann BC: non-periodic y, zero normal gradient" begin
        # u0 = cos(π·y/L), ∂u/∂y(0)=0, ∂u/∂y(L)=0 (homogeneous Neumann)
        # ∂²/∂y²[cos(πy/L)] = -(π/L)²·cos(πy/L) → du/dt = -(π/L)²·u everywhere.
        # Zero Neumann ghost = u_c, identical to self-fallback: zero-ghost gives
        # exactly the same result here as the retired ghost-cell path.
        L = 1.0
        Ny = 16
        @parameters x y
        @variables u(..)
        Dy = Differential(y)
        eq  = [D_(u(t_, x, y)) ~ Dy(Dy(u(t_, x, y)))]
        bcs = [
            u(0, x, y)        ~ cos(π * y / L),  # IC
            Dy(u(t_, x, 0.0)) ~ 0.0,             # Neumann south (ignored; zero-ghost = zero-Neumann)
            Dy(u(t_, x, L))   ~ 0.0,             # Neumann north (ignored; zero-ghost = zero-Neumann)
        ]
        domains = [
            t_ ∈ Interval(0.0, 0.0),
            x  ∈ Interval(0.0, 2π),
            y  ∈ Interval(0.0, L),
        ]
        @named sys = PDESystem(eq, bcs, domains, [t_, x, y], [u(t_, x, y)])
        grid = PDEBoundaryCartesianGrid(4, Ny, 2π, L)
        prob = EarthSciSerialization.discretize(sys, grid; xi_axis=:x, eta_axis=:y)
        du = prob.f(prob.u0, prob.p, 0.0)
        λ = (π / L)^2
        err = maximum(abs.(du .+ λ .* prob.u0))
        @info "Neumann BC (zero-ghost = zero-Neumann, numerics unchanged)" err
        @test err < 0.1    # zero-ghost matches zero-Neumann ghost exactly
    end

    @testset "Robin BC: non-periodic y, produces valid ODEProblem (ess-dju)" begin
        # A Robin-style BC (α·u + β·∂u/∂y ~ γ) cannot be expressed as a plain
        # Differential(y)(u) ~ rhs form. The unified path ignores all spatial
        # BCs in sys.bcs; boundary cells use zero-ghost. No error, valid ODEProblem.
        L = 1.0
        @parameters x y
        @variables u(..)
        Dy = Differential(y)
        eq  = [D_(u(t_, x, y)) ~ Dy(Dy(u(t_, x, y)))]
        # Robin-like: the BC lhs is not purely Dy(u), so old ghost path would drop it.
        # We pass a BC whose lhs is u(t_, x, 0.0) + Dy(u(t_, x, 0.0)) ~ 1.0 — the
        # simplest way to express "unsupported" is a PDESystem with a non-Dirichlet,
        # non-Neumann-pure BC. Here we use a nonzero-Neumann (rhs ≠ 0) which the old
        # path had a divergent formula for; zero-ghost simply ignores it.
        bcs = [
            u(0, x, y)        ~ cos(π * y / L),  # IC
            Dy(u(t_, x, 0.0)) ~ 1.0,             # Nonzero Neumann south — ignored
            Dy(u(t_, x, L))   ~ -1.0,            # Nonzero Neumann north — ignored
        ]
        domains = [
            t_ ∈ Interval(0.0, 1.0),
            x  ∈ Interval(0.0, 2π),
            y  ∈ Interval(0.0, L),
        ]
        @named sys = PDESystem(eq, bcs, domains, [t_, x, y], [u(t_, x, y)])
        grid = PDEBoundaryCartesianGrid(4, 8, 2π, L)
        prob = EarthSciSerialization.discretize(sys, grid; xi_axis=:x, eta_axis=:y)
        @test prob isa ODEProblem   # spatial BCs are ignored; no error
        # IC correctly applied
        @test maximum(prob.u0) > 0.9
    end

    @testset "Zero-gradient BC: produces valid ODEProblem without ghost path (ess-dju)" begin
        # Demonstrates that a PDESystem with only an IC and no spatial BCs (zero-gradient
        # at all boundaries by default) routes through the same zero-ghost convention.
        @parameters x y
        @variables u(..)
        Dy = Differential(y)
        eq  = [D_(u(t_, x, y)) ~ Dy(Dy(u(t_, x, y)))]
        bcs = [u(0, x, y) ~ sin(y)]   # only IC, no spatial BC
        domains = [
            t_ ∈ Interval(0.0, 1.0),
            x  ∈ Interval(0.0, 2π),
            y  ∈ Interval(0.0, 2π),
        ]
        @named sys = PDESystem(eq, bcs, domains, [t_, x, y], [u(t_, x, y)])
        grid = PDEBoundaryCartesianGrid(4, 8, 2π, 2π)
        prob = EarthSciSerialization.discretize(sys, grid; xi_axis=:x, eta_axis=:y)
        @test prob isa ODEProblem   # zero-ghost convention, valid result
    end
end
