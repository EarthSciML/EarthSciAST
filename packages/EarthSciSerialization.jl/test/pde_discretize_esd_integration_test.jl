# End-to-end integration test for the PDE discretization pipeline (ess-d1e):
#   EarthSciSerialization.discretize(::PDESystem, ::AbstractCurvilinearGrid)
# exercised against a REAL EarthSciDiscretizations (ESD) curvilinear grid —
# a `LatLonGrid` — rather than the inline Cartesian stub used by
# `pde_discretize_test.jl`.
#
# VERDICT (2026-05-17): the real-grid PDE path works as-is for the
# `LatLonGrid`. Method-of-manufactured-solutions (MMS) convergence is a
# clean O(h²) on the periodic longitude axis and, for interior rows, on the
# latitude axis; an end-to-end `solve` reproduces the analytic exponential
# decay of a heat equation. One ESS-side seam was found and fixed:
# `discretize` eagerly called `coord_jacobian(grid, target)` even when no
# derivative needs the chain-rule transform, which made the natural
# `target = :auto` default error on a `(xi, eta)` PDE (the auto-derived
# `:xi_eta` is not a target ESD's `coord_jacobian` accepts).
# `discretize` now fetches `coord_jacobian` lazily. One pre-existing
# limitation is documented, not fixed (out of scope — it has a follow-up
# bead):
#   * ess-gp3 — the discretizer has no boundary-condition handling for
#     NON-periodic axes, so the `LatLonGrid` pole rows (pole_policy=:none →
#     sentinel 0 → self-fallback) carry an O(1) stencil error; interior
#     convergence is unaffected and is what this test asserts.
#
# ESD is a DOWNSTREAM consumer of ESS's Grid trait and is deliberately not a
# hard dependency of ESS (that would be a circular dependency). This file
# therefore loads ESD opportunistically: when the ESD package is reachable
# on disk it is `Pkg.develop`-ed into the active test environment and the
# integration runs for real; when it is not reachable (a standalone ESS
# clone, or CI without the ESD repo checked out) the test set logs an
# informative skip and passes. Set EARTHSCISERIALIZATION_ESD_PATH to point
# at the ESD repo explicitly.

using Test
using EarthSciSerialization
using ModelingToolkit
using ModelingToolkit: t_nounits as t_, D_nounits as D_, Differential, PDESystem
using Symbolics
using DomainSets: Interval
using OrdinaryDiffEqTsit5
import Pkg

# ---------------------------------------------------------------------------
# Locate and load EarthSciDiscretizations (optional).
# ---------------------------------------------------------------------------

const _ESD_UUID = "09f49f9f-7beb-4663-9a88-8eb45422cf8c"

function _find_esd_path()
    # 1. explicit override
    env = get(ENV, "EARTHSCISERIALIZATION_ESD_PATH", "")
    if !isempty(env)
        if isfile(joinpath(env, "Project.toml"))
            return abspath(env)
        end
        @warn "EARTHSCISERIALIZATION_ESD_PATH set but holds no Project.toml" env
    end
    # 2. walk up the directory tree looking for a sibling EarthSciDiscretizations
    dir = @__DIR__
    while true
        proj = joinpath(dir, "EarthSciDiscretizations", "Project.toml")
        if isfile(proj)
            txt = read(proj, String)
            if occursin("EarthSciDiscretizations", txt) && occursin(_ESD_UUID, txt)
                return abspath(joinpath(dir, "EarthSciDiscretizations"))
            end
        end
        parent = dirname(dir)
        parent == dir && break
        dir = parent
    end
    return nothing
end

ESD_PATH = _find_esd_path()
# A `Ref` (not a plain `Bool`): this file runs at `include` top level, where
# assigning to a global from inside the `try` block lands in soft scope and
# would silently create a local. Mutating a `Ref` sidesteps that entirely.
const ESD_LOADED = Ref(false)

# `Pkg.develop` mutates the *active* project. Under `Pkg.test()` that is a
# throwaway sandbox — safe to mutate. Refuse to run if the active project is
# ESS's own `Project.toml`, so a direct `julia --project=<pkg> test/<this>`
# invocation cannot dirty the committed package manifest.
_ess_project = abspath(joinpath(dirname(@__DIR__), "Project.toml"))
_active = Base.active_project()
_safe_to_develop = _active === nothing || abspath(_active) != _ess_project

if ESD_PATH === nothing
    @info "ess-d1e integration: EarthSciDiscretizations not found — skipping " *
          "(set EARTHSCISERIALIZATION_ESD_PATH to run it)."
elseif !_safe_to_develop
    @info "ess-d1e integration: active project is the ESS package itself — " *
          "skipping (run via `Pkg.test()` so ESD lands in a sandbox env)."
else
    try
        # `preserve = PRESERVE_ALL` keeps every already-resolved (and possibly
        # already-loaded) package version pinned; ESD only adds itself plus
        # any genuinely new transitive deps. ESD's own `EarthSciSerialization`
        # dependency resolves to the ESS under test (same UUID, dev-installed
        # by `Pkg.test`).
        Pkg.develop(Pkg.PackageSpec(path = ESD_PATH);
                    preserve = Pkg.PRESERVE_ALL, io = devnull)
        @eval import EarthSciDiscretizations
        ESD_LOADED[] = true
        @info "ess-d1e integration: loaded EarthSciDiscretizations" ESD_PATH
    catch err
        @warn "ess-d1e integration: EarthSciDiscretizations found but could " *
              "not be loaded — skipping." exception = (err, catch_backtrace())
    end
end

# ---------------------------------------------------------------------------

@testset "discretize(PDESystem) — real ESD curvilinear grids (ess-d1e)" begin

    if !ESD_LOADED[]
        @info "ESD grid integration skipped (EarthSciDiscretizations unavailable)."
        @test_skip false
    else

        @testset "LatLonGrid — longitude-diffusion MMS (O(h²))" begin
            # u0 = sin(2·lon);  ∂²u/∂lon² = -4·u  exactly. Longitude is
            # periodic on the LatLonGrid, so the centered stencil wraps
            # cleanly at every cell — the per-cell relation du ≈ -4·u0
            # holds for the whole field, independent of compiled-state
            # ordering.
            function lon_mms_err(nlon)
                @parameters lon lat
                @variables u(..)
                Dlon = Differential(lon)
                eq  = [D_(u(t_, lon, lat)) ~ Dlon(Dlon(u(t_, lon, lat)))]
                bcs = [u(0, lon, lat) ~ sin(2 * lon)]
                domains = [
                    t_  ∈ Interval(0.0, 0.0),
                    lon ∈ Interval(-π, π),
                    lat ∈ Interval(-π / 2, π / 2),
                ]
                @named sys = PDESystem(eq, bcs, domains,
                                       [t_, lon, lat], [u(t_, lon, lat)])
                grid = EarthSciDiscretizations.grids.lat_lon(;
                    nlon = nlon, nlat = nlon ÷ 2, R = 1.0)
                prob = EarthSciSerialization.discretize(
                    sys, grid; xi_axis = :lon, eta_axis = :lat)
                du = prob.f(prob.u0, prob.p, 0.0)
                return maximum(abs.(du .+ 4 .* prob.u0))
            end

            e16 = lon_mms_err(16)
            e32 = lon_mms_err(32)
            order = log2(e16 / e32)
            @info "LatLonGrid lon-diffusion MMS" e16 e32 order
            @test e16 < 0.3            # coarse-grid accuracy
            @test e32 < e16            # refinement reduces the error
            @test order > 1.7         # O(h²): order ≈ 2 (rules out O(h))
        end

        @testset "LatLonGrid — constant field, zero coordinate Laplacian" begin
            @parameters lon lat
            @variables u(..)
            Dlon = Differential(lon)
            Dlat = Differential(lat)
            eq  = [D_(u(t_, lon, lat)) ~
                   Dlon(Dlon(u(t_, lon, lat))) + Dlat(Dlat(u(t_, lon, lat)))]
            bcs = [u(0, lon, lat) ~ 5.0]
            domains = [
                t_  ∈ Interval(0.0, 1.0),
                lon ∈ Interval(-π, π),
                lat ∈ Interval(-π / 2, π / 2),
            ]
            @named sys = PDESystem(eq, bcs, domains,
                                   [t_, lon, lat], [u(t_, lon, lat)])
            grid = EarthSciDiscretizations.grids.lat_lon(;
                nlon = 16, nlat = 8, R = 1.0)
            prob = EarthSciSerialization.discretize(
                sys, grid; xi_axis = :lon, eta_axis = :lat)
            @test prob isa ODEProblem
            @test length(prob.u0) == EarthSciSerialization.n_cells(grid) == 128
            du = prob.f(prob.u0, prob.p, 0.0)
            # ∇²(const) = 0 at every cell — including the pole rows, where
            # the self-fallback stencil still differences equal values to 0.
            @test maximum(abs, du) < 1e-10
        end

        @testset "LatLonGrid — latitude-diffusion MMS, interior (O(h²))" begin
            # u0 = sin(2·lon)·cos(lat);
            #   ∂²u/∂lon² + ∂²u/∂lat² = -(4 + 1)·u = -5·u.
            # The lat axis is NON-periodic (pole_policy=:none): the two pole
            # rows hit neighbor_indices sentinel 0, where the discretizer's
            # self-fallback yields a degraded stencil. The MMS relation
            # therefore holds only at interior rows. The 2·nlon pole cells
            # are, by construction, the largest residuals, so a sorted-
            # residual split isolates the interior error without needing the
            # (compiler-dependent) state→cell map.
            function lat_mms(nlon, nlat)
                @parameters lon lat
                @variables u(..)
                Dlon = Differential(lon)
                Dlat = Differential(lat)
                eq  = [D_(u(t_, lon, lat)) ~
                       Dlon(Dlon(u(t_, lon, lat))) +
                       Dlat(Dlat(u(t_, lon, lat)))]
                bcs = [u(0, lon, lat) ~ sin(2 * lon) * cos(lat)]
                domains = [
                    t_  ∈ Interval(0.0, 0.0),
                    lon ∈ Interval(-π, π),
                    lat ∈ Interval(-π / 2, π / 2),
                ]
                @named sys = PDESystem(eq, bcs, domains,
                                       [t_, lon, lat], [u(t_, lon, lat)])
                grid = EarthSciDiscretizations.grids.lat_lon(;
                    nlon = nlon, nlat = nlat, R = 1.0)
                prob = EarthSciSerialization.discretize(
                    sys, grid; xi_axis = :lon, eta_axis = :lat)
                du = prob.f(prob.u0, prob.p, 0.0)
                resid = sort(abs.(du .+ 5 .* prob.u0))
                n_interior = nlon * (nlat - 2)   # drop the 2 pole rows
                return (interior = resid[n_interior], pole = resid[end])
            end

            d1 = lat_mms(16, 8)
            d2 = lat_mms(32, 16)
            order = log2(d1.interior / d2.interior)
            @info "LatLonGrid lat-diffusion MMS (interior)" d1 d2 order
            @test d1.interior < 0.3
            @test d2.interior < d1.interior
            @test order > 1.7                  # interior is clean O(h²)
            # Documented limitation: the pole-row residual is O(1) and does
            # NOT converge — asserted so the gap stays visible and guarded.
            @test d1.pole > 10 * d1.interior
        end

        @testset "LatLonGrid — end-to-end solve, analytic exponential decay" begin
            # Heat equation in longitude: ∂u/∂t = a·∂²u/∂lon², u0 = sin(2·lon).
            # Exact solution u(t) = exp(-4·a·t)·u0 — every cell decays by the
            # same factor, so sol(T) ≈ exp(-4·a·T)·u0 holds element-wise,
            # independent of the compiled-state ordering.
            a = 0.25
            T = 1.0
            @parameters lon lat
            @variables u(..)
            Dlon = Differential(lon)
            eq  = [D_(u(t_, lon, lat)) ~ a * Dlon(Dlon(u(t_, lon, lat)))]
            bcs = [u(0, lon, lat) ~ sin(2 * lon)]
            domains = [
                t_  ∈ Interval(0.0, T),
                lon ∈ Interval(-π, π),
                lat ∈ Interval(-π / 2, π / 2),
            ]
            @named sys = PDESystem(eq, bcs, domains,
                                   [t_, lon, lat], [u(t_, lon, lat)])
            grid = EarthSciDiscretizations.grids.lat_lon(;
                nlon = 32, nlat = 16, R = 1.0)
            prob = EarthSciSerialization.discretize(
                sys, grid; xi_axis = :lon, eta_axis = :lat)
            @test prob isa ODEProblem
            @test length(prob.u0) == 512
            sol = solve(prob, Tsit5(); abstol = 1e-10, reltol = 1e-10)
            @test sol.retcode == ReturnCode.Success
            decay = exp(-4 * a * T)
            @test decay < 0.5                  # the field genuinely evolved
            err = maximum(abs.(sol.u[end] .- decay .* prob.u0))
            @info "LatLonGrid heat-equation solve" decay err
            @test err < 0.02                   # matches the analytic decay
        end

    end
end
