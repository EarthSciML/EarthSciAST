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
# NO BINDING DIFFERENCE. Unitful models every angle as `NoDims`, so this binding
# cannot tell an angle from a pure number by DIMENSION and reads the unit's own
# symbol instead (`EarthSciAST._is_plane_angle` for the two plane angles,
# `EarthSciAST._is_angle_bearing` for the whole axis). Reading only the plane
# angles left `sr`, `rad^2` and a bare `rad` under a strict transcendental
# looking dimensionless, so this binding ACCEPTED `sin(x [sr])`, `log(x [rad])`
# and `asin(x [rad])` where the other four -- which carry `rad` as a real axis
# and see `rad^2` -- refuse all three. That was the one place where one binding
# said VALID and the other four said INVALID, and it is closed here; the
# `an angle-bearing unit is not dimensionless` testset below is what holds it
# closed.

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

    # esm-spec §4.8.3: the ANGLE AXIS, which Unitful does not have.
    #
    # `rad` is one of the eight axes (§4.8.1) and `sr` is that axis SQUARED, so
    # in the four bindings that carry a dimension vector NONE of the arguments
    # below is dimensionless and all of them are refused. Unitful models every
    # angle as `NoDims`, so this binding used to accept them — the one place
    # where it, alone of the five, said VALID where the other four said INVALID.
    # `EarthSciAST._is_angle_bearing` reads the unit's symbol to stand in for
    # the missing axis. Delete that call from any of the three rules and the
    # matching case here goes red.
    @testset "an angle-bearing unit is not dimensionless" begin
        # A circular function admits a PLANE angle at any scale and CONVERTS it,
        # so `rad`/`deg` stay accepted above. Everything else on the axis is a
        # dimensional mismatch: no conversion turns a solid angle into a plane
        # one, and multiplying by `scale` where `scale^2` was meant is silently
        # wrong.
        for op in ("sin", "cos", "tan")
            for bad in ("sr", "rad^2", "rad*deg")
                found = _arg_findings(op, bad)
                @test length(found) == 1
                @test occursin("Circular function argument must be an angle or " *
                               "dimensionless", found[1])
            end
        end
        # A strict transcendental takes a PURE NUMBER. An angle is not one —
        # `log(x [rad])` is a dimensional mismatch, not a scale question.
        for op in ("ln", "log", "log10", "exp", "sinh", "cosh", "tanh")
            for bad in ("rad", "deg", "sr", "rad^2")
                found = _arg_findings(op, bad)
                @test length(found) == 1
                @test occursin("argument must be dimensionless", found[1])
            end
        end
        # An inverse circular function RETURNS an angle; it does not take one.
        for op in ("asin", "acos", "atan")
            for bad in ("rad", "deg", "sr", "rad^2")
                found = _arg_findings(op, bad)
                @test length(found) == 1
                @test occursin("Inverse circular function argument must be " *
                               "dimensionless", found[1])
            end
        end
        # The predicate must not catch a unit that only LOOKS dimensionless:
        # a pure number and the mixing ratios are not on the angle axis.
        @test !EarthSciAST._is_angle_bearing(EarthSciAST.parse_units("1"))
        @test !EarthSciAST._is_angle_bearing(EarthSciAST.parse_units("ppm"))
        @test !EarthSciAST._is_angle_bearing(EarthSciAST.parse_units("m"))
        # Every angle spelling the §4.8.1 registry defines and this binding
        # parses. (`mrad` is deliberately absent: Julia's registry carries no
        # prefixed-radian entry at all, which is a separate registry question
        # and not something this rule can see.)
        for spelling in ("rad", "deg", "degree", "degrees", "sr", "rad^2", "rad*deg")
            @test EarthSciAST._is_angle_bearing(EarthSciAST.parse_units(spelling))
        end
        # ...and `sr` still PARSES and stays commensurate with itself, because a
        # spherical-mesh cell area declares it (esm-spec §4.8.1). Refusing it as
        # a trig argument must not make the declaration unusable.
        @test EarthSciAST.parse_units("sr") !== nothing
        @test isempty(_arg_findings("abs", "sr"))
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

    # An array element carries its array's unit on the evaluation path, so
    # `cos(index(lat, i))` with `lat` in `deg` converts like `cos(lat)` does.
    # The checker has no rule for `index` or `faq` (§4.8.4), and this rewrite
    # used to read the argument with the checker's rules, so it left every
    # array element unconverted and evaluated cos(60 radians) = -0.952.
    @testset "flatten converts a degree ARRAY ELEMENT" begin
        path = joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance",
                        "scalar_operator_semantics", "fixtures", "angle_array_element.esm")
        if _require_fixture(path)
            file = EarthSciAST.load_path(path)
            flat = EarthSciAST.flatten(file)
            found = Dict{String, Any}()
            function collect_trig(name, e)
                e isa EarthSciAST.OpExpr || return
                e.op in ("sin", "cos", "tan") && length(e.args) == 1 &&
                    (found[name] = e.args[1])
                foreach(c -> collect_trig(name, c), EarthSciAST.child_exprs(e))
            end
            for eq in flat.equations
                eq.lhs isa EarthSciAST.VarExpr && collect_trig(eq.lhs.name, eq.rhs)
            end
            args = Dict(last(split(k, '.')) => v for (k, v) in found)
            @test sort(collect(keys(args))) ==
                  ["cos_lat", "cos_lat_rad", "sin_colat", "sin_scalar", "sin_sum"]
            for name in ("cos_lat", "sin_colat", "sin_sum")
                arg = args[name]
                # `index(A, …) * (π/180)`: the element, then the declared scale, once.
                @test arg isa EarthSciAST.OpExpr && arg.op == "*"
                @test arg.args[1] isa EarthSciAST.OpExpr && arg.args[1].op == "index"
                @test arg.args[2] isa EarthSciAST.NumExpr && arg.args[2].value == pi / 180
            end
            @test args["sin_scalar"] isa EarthSciAST.OpExpr && args["sin_scalar"].op == "*"
            # The `rad` control is never touched.
            @test args["cos_lat_rad"] isa EarthSciAST.OpExpr && args["cos_lat_rad"].op == "index"
            # The checker still reads the authored spelling and still accepts it.
            @test EarthSciAST.validate(file).is_valid
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
