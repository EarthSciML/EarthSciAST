# Closed function registry — ForwardDiff compatibility.
#
# The tree-walk evaluator is type-stable in its value type, so under ForwardDiff
# EVERY leaf reaching a closed function is lifted to a `Dual` — including `t`,
# which is not a differentiation variable at all. The registry used to coerce its
# queries with `Float64(...)`, which is a `MethodError` on a `Dual`; that made
# every `interp.*`/`datetime.*` model fail under `Rosenbrock23(autodiff=true)`
# with "the user `f` function is not compatible with automatic differentiation".
#
# The contract pinned here:
#   * `interp.linear` / `interp.bilinear` are eltype-generic in the QUERY, and
#     their derivative is the analytic slope of the piecewise-linear surface
#     (flat, i.e. zero, outside the table).
#   * `interp.searchsorted` and the calendar `datetime.*` functions are DISCRETE:
#     they accept a `Dual` and contribute no derivative.
#   * `datetime.julian_day` is the one continuous `datetime.*` function, and its
#     derivative w.r.t. the UTC scalar is 1/86400 — load-bearing for the ∂f/∂t
#     term of a stiff Rosenbrock solve on a solar-geometry-driven model.
#   * The `Float64` path is unchanged, bit-for-bit.
#
# Loading ForwardDiff here is also what exercises `EarthSciASTForwardDiffExt`,
# the weakdep seam supplying `_value` for `Dual` (see ext/).

using Test
using ForwardDiff
using EarthSciAST

@testset "Closed function registry — ForwardDiff compatibility" begin

    # Piecewise-linear table with three cells of DIFFERENT slope, so a wrong
    # derivative cannot coincidentally match: 10.0 on [0,1], 2.0 on [1,2],
    # 4.0 on [2,4].
    axis  = [0.0, 1.0, 2.0, 4.0]
    table = [10.0, 20.0, 22.0, 30.0]
    lin(x) = evaluate_closed_function_ad("interp.linear", Any[table, axis, x])

    @testset "interp.linear: a Dual survives and carries the cell slope" begin
        # Value agrees with the Float64 path.
        @test lin(0.5) ≈ 15.0
        # Derivative is the analytic slope of each cell.
        @test ForwardDiff.derivative(lin, 0.5) ≈ 10.0
        @test ForwardDiff.derivative(lin, 1.5) ≈ 2.0
        @test ForwardDiff.derivative(lin, 3.0) ≈ 4.0
        # Flat extrapolation ⇒ zero slope outside the table (the clamp arms lift
        # the table entry into the dual type with zero partials).
        @test ForwardDiff.derivative(lin, -1.0) == 0.0
        @test ForwardDiff.derivative(lin, 5.0) == 0.0
        # On-knot values still land exactly on the table entries.
        @test lin(ForwardDiff.Dual{Nothing}(2.0, 1.0)) isa ForwardDiff.Dual
        @test ForwardDiff.value(lin(ForwardDiff.Dual{Nothing}(2.0, 1.0))) ≈ 22.0
    end

    @testset "interp.bilinear: both partials survive" begin
        ax = [0.0, 1.0]
        ay = [0.0, 2.0]
        tb = [[1.0, 3.0], [5.0, 11.0]]
        # f(x,y) = (1 + 4x) + (y/2)*(2 + 4x)  ⇒  ∂f/∂x = 4 + 2y, ∂f/∂y = 1 + 2x.
        bil(x, y) = evaluate_closed_function_ad("interp.bilinear", Any[tb, ax, ay, x, y])
        @test bil(0.5, 1.0) ≈ 5.0
        @test ForwardDiff.derivative(x -> bil(x, 1.0), 0.5) ≈ 6.0
        @test ForwardDiff.derivative(y -> bil(0.5, y), 1.0) ≈ 2.0
        # Clamped (flat) outside the table on either axis.
        @test ForwardDiff.derivative(x -> bil(x, 1.0), -3.0) == 0.0
        @test ForwardDiff.derivative(y -> bil(0.5, y), 9.0) == 0.0
    end

    @testset "interp.searchsorted: discrete, accepts a Dual" begin
        xs = [0.0, 1.0, 2.0, 4.0]
        ss(x) = evaluate_closed_function_ad("interp.searchsorted", Any[x, xs])
        # The index search runs on the Dual directly (only `<`/`isnan` are used)
        # and returns a plain Int32 — no derivative to carry.
        @test ss(ForwardDiff.Dual{Nothing}(1.5, 1.0)) === Int32(3)
        @test ss(1.5) === Int32(3)
    end

    @testset "datetime.*: calendar decomposition accepts a Dual" begin
        # THE original end-to-end failure: `datetime.day_of_year` received a
        # zero-partial Dual (lifted `t`) and `Float64(::Dual)` threw.
        t0 = 1462345200.0  # 2016-05-04T07:00:00Z
        d0 = ForwardDiff.Dual{Nothing}(t0, 1.0)
        for name in ("datetime.year", "datetime.month", "datetime.day",
                     "datetime.hour", "datetime.minute", "datetime.second",
                     "datetime.day_of_year", "datetime.is_leap_year")
            # Must not throw, and must agree with the Float64 path exactly —
            # these are piecewise constant, so the primal is the whole answer.
            @test evaluate_closed_function_ad(name, Any[d0]) ===
                  evaluate_closed_function(name, Any[t0])
        end
    end

    @testset "datetime.julian_day: continuous, keeps its derivative" begin
        t0 = 1462345200.0
        jd(x) = evaluate_closed_function_ad("datetime.julian_day", Any[x])
        # Unlike the calendar fields, this one is differentiable in the UTC
        # scalar: one day per 86400 seconds.
        @test ForwardDiff.derivative(jd, t0) ≈ 1 / 86400
        # ...and its value is unchanged from the Float64 path.
        @test ForwardDiff.value(jd(ForwardDiff.Dual{Nothing}(t0, 1.0))) === jd(t0)
    end

    @testset "Float64 path is bit-for-bit unchanged" begin
        # `_value` is the identity on a real, so the generic signatures compile
        # to the same arithmetic the `::Float64`-annotated form did.
        @test lin(0.5) === 15.0
        @test lin(-1.0) === 10.0
        @test lin(5.0) === 30.0
        # The Unix epoch is midnight; JDN counts noon-to-noon, hence the .5.
        @test evaluate_closed_function("datetime.julian_day", Any[0.0]) === 2440587.5
    end
end
