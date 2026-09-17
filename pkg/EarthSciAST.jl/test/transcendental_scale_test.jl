# esm-spec §4.8.3 and issue #409: a unit's SCALE reaches the trig and
# transcendental rules.
#
# Two halves that want OPPOSITE fixes, and one file so they stay in view of each
# other:
#
#   * ANGLES CONVERT. `deg` is a registry unit at scale π/180, so
#     `sin(theta [deg])` is a CONFORMING document — and `flatten` used to hand
#     the stored number straight to `sin`, so `sin(90 [deg])` evaluated
#     0.8939966636005579, which is `sin(90 radians)`, with no diagnostic. The
#     conversion is exact and has exactly one reading.
#   * SCALED DIMENSIONLESS REFUSES. `ppm` is dimensionless at 1e-6, so
#     `log(c [ppm])` satisfied every dimension-only test. The log of the ppm
#     NUMBER and the log of the mole fraction differ by `ln(1e-6) = 13.8155…`,
#     and nothing in the document says which was meant, so the checker refuses
#     and names the repair rather than picking one.
#
# Everything asserted here is asserted off SHARED fixtures, so the same facts are
# checked by the other four bindings.
#
# THE ONE BINDING DIFFERENCE, on purpose. Unitful models `rad` as `NoDims`, so
# this binding cannot tell an angle from a pure number by DIMENSION and reads the
# unit's own symbol instead (`EarthSciAST._is_plane_angle`). The consequence is
# `sr`: the other four carry `rad` as an axis and see `rad^2`, which no
# conversion turns into a plane angle, so they REFUSE `sin(x [sr])`; here `sr` is
# `NoDims` at scale 1 and is accepted as a pure number. That divergence predates
# #409 and is not changed by it.

using Test
using EarthSciAST
using Unitful

include("testutils.jl")

# The ops whose argument esm-spec §4.8.3 requires to be dimensionless — the ten
# strict transcendentals and the three inverse circular functions.
const _STRICT_ARGUMENT_OPS = ("ln", "log", "log10", "exp",
                              "sinh", "cosh", "tanh", "asinh", "acosh", "atanh",
                              "asin", "acos", "atan")

# The findings raised for `op(x)` with `x` declared in `unit`.
function _arg_findings(op::AbstractString, unit::AbstractString)
    findings = String[]
    EarthSciAST._expr_dimensions!(findings,
        EarthSciAST.OpExpr(op, EarthSciAST.ASTExpr[EarthSciAST.VarExpr("x")]),
        Dict("x" => unit))
    return findings
end

@testset "Transcendental and trig argument SCALE (§4.8.3, #409)" begin

    @testset "a strict transcendental argument must be dimensionless at scale 1" begin
        for op in _STRICT_ARGUMENT_OPS
            found = _arg_findings(op, "ppm")
            @test length(found) == 1
            @test occursin("dimensionless at scale 1", found[1])
            @test occursin("(ppm)", found[1])
            # The diagnostic names the REPAIR, not only the refusal.
            @test occursin("divide by 1 ppm", found[1])
            # A PURE NUMBER stays accepted.
            @test isempty(_arg_findings(op, "1"))
        end
        @test occursin("divide by 1 percent", _arg_findings("exp", "percent")[1])
    end

    @testset "a circular function takes an angle at any scale" begin
        for op in ("sin", "cos", "tan")
            for ok in ("rad", "deg", "1")
                @test isempty(_arg_findings(op, ok))
            end
            # Dimensionless at a scale other than 1 leaves the reading unstated,
            # exactly as it does for `log`.
            @test length(_arg_findings(op, "percent")) == 1
        end
    end

    @testset "the angle normalization factor" begin
        for spelling in ("rad", "1", "ppm", "m")
            @test EarthSciAST.angle_normalization_factor(
                EarthSciAST.parse_units(spelling)) === nothing
        end
        factor = EarthSciAST.angle_normalization_factor(EarthSciAST.parse_units("deg"))
        @test factor == pi / 180
        # 90 deg is exactly a quarter turn under this factor.
        @test sin(90 * factor) == 1.0
    end

    @testset "flatten converts a degree argument and leaves radians alone" begin
        path = joinpath(TESTUTILS_REPO_ROOT, "tests", "simulation", "angle_units_degrees.esm")
        if _require_fixture(path)
            flat = EarthSciAST.flatten(EarthSciAST.load_path(path))
            found = Tuple{String, Any}[]
            collect_trig(e) = begin
                e isa EarthSciAST.OpExpr || return
                e.op in ("sin", "cos", "tan") && length(e.args) == 1 &&
                    push!(found, (e.op, e.args[1]))
                foreach(collect_trig, e.args)
            end
            for eq in flat.equations
                collect_trig(eq.rhs)
            end
            @test length(found) == 4

            converted, untouched = 0, 0
            for (op, arg) in found
                if arg isa EarthSciAST.OpExpr
                    @test arg.op == "*"
                    # The factor is the declared scale, applied ONCE.
                    @test arg.args[2] isa EarthSciAST.NumExpr && arg.args[2].value == pi / 180
                    converted += 1
                else
                    @test arg isa EarthSciAST.VarExpr && endswith(arg.name, "theta_rad")
                    untouched += 1
                end
            end
            @test (converted, untouched) == (3, 1)
        end
    end

    @testset "the shared fixtures" begin
        bad = joinpath(TESTUTILS_REPO_ROOT, "tests", "invalid",
                       "units_discriminator_transcendental_scaled_argument.esm")
        if _require_fixture(bad)
            result = EarthSciAST.validate(EarthSciAST.load_path(bad))
            @test !result.is_valid
            @test any(occursin("divide by 1 ppm", e.message) for e in result.structural_errors)
        end

        good = joinpath(TESTUTILS_REPO_ROOT, "tests", "valid",
                        "units_transcendental_scaled_argument_repair.esm")
        if _require_fixture(good)
            result = EarthSciAST.validate(EarthSciAST.load_path(good))
            @test result.is_valid
        end
    end
end
