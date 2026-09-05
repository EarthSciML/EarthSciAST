# Closed function registry — Julia conformance harness adapter (esm-tzp / esm-4aw).
#
# Drives the cross-binding fixtures under `tests/closed_functions/<module>/<name>/`
# from the Julia binding: parse `canonical.esm` (validates the parser's `fn`-op
# handling), then walk the scenarios in `expected.json` and assert that
# `evaluate_closed_function` agrees with the reference output within the
# declared tolerance. The same fixture set runs from each binding's harness;
# any binding that disagrees with the spec-pinned values fails CI (esm-spec §9.4).

using Test
using JSON3
using EarthSciAST

include("testutils.jl")  # TESTUTILS_REPO_ROOT

const _CF_REPO_ROOT = TESTUTILS_REPO_ROOT
const _CF_FIX_ROOT   = joinpath(_CF_REPO_ROOT, "tests", "closed_functions")

# Convert a JSON3-decoded scenario input to the value the closed function
# expects. Strings used as numeric placeholders (e.g. "NaN") are decoded;
# arrays recurse element-wise so `xs` arrays land as `Vector{Float64}`.
function _decode_input(v)
    if v isa String
        v == "NaN"  && return NaN
        v == "Inf"  && return Inf
        v == "-Inf" && return -Inf
        throw(ArgumentError("unrecognized string input: $(v)"))
    elseif v isa AbstractVector || v isa JSON3.Array
        return [_decode_input(x) for x in v]
    elseif v isa Bool
        throw(ArgumentError("boolean inputs not allowed"))
    elseif v isa Real
        return Float64(v)
    end
    throw(ArgumentError("unsupported input type: $(typeof(v))"))
end

# Tolerance comparison per esm-spec §9.2: pass if either |actual − expected|
# ≤ abs OR |actual − expected| ≤ rel·max(1, |expected|). The "max(1, ...)"
# guard avoids zero-relative tolerance when expected is zero.
function _within_tol(actual, expected, abs_tol, rel_tol)
    abs_tol = Float64(abs_tol); rel_tol = Float64(rel_tol)
    a = Float64(actual); e = Float64(expected)
    if isnan(a) && isnan(e)
        return true
    end
    diff = abs(a - e)
    return diff <= abs_tol || diff <= rel_tol * max(1.0, abs(e))
end

@testset "Closed function registry conformance (esm-tzp / esm-4aw)" begin
    @test isdir(_CF_FIX_ROOT)

    # Walk every <module>/<name> directory and run the scenarios it pins.
    for module_dir in sort(readdir(_CF_FIX_ROOT))
        full_module = joinpath(_CF_FIX_ROOT, module_dir)
        isdir(full_module) || continue
        @testset "$(module_dir)/*" begin
            for fname_dir in sort(readdir(full_module))
                fixture_dir = joinpath(full_module, fname_dir)
                isdir(fixture_dir) || continue
                canonical = joinpath(fixture_dir, "canonical.esm")
                expected  = joinpath(fixture_dir, "expected.json")
                @testset "$(fname_dir)" begin
                    @test isfile(canonical)
                    @test isfile(expected)

                    # Parser must accept the fixture (i.e. the `fn` op AST is
                    # valid under the current schema). The shared corpus tracks
                    # the format version, so pin it against the constant rather
                    # than a frozen string.
                    file = EarthSciAST.load_path(canonical)
                    @test file.esm == EarthSciAST.SCHEMA_VERSION

                    spec = JSON3.read(read(expected, String))
                    fn_name = String(spec.function)
                    if !(fn_name in closed_function_names())
                        # Spec-first phased rollout (esm-94w and similar): a
                        # new closed-function fixture lands in the spec PR
                        # before this binding's implementation. Skip rather
                        # than fail; the per-language [Impl] bead adds the
                        # function to the registry, at which point the
                        # fixture starts running automatically.
                        @info "skipping fixture $(fixture_dir): function $(fn_name) not yet implemented in this binding"
                        continue
                    end
                    abs_tol = haskey(spec, :tolerance) ? Float64(spec.tolerance.abs) : 0.0
                    rel_tol = haskey(spec, :tolerance) ? Float64(spec.tolerance.rel) : 0.0

                    for scenario in spec.scenarios
                        sname = String(scenario.name)
                        inputs_decoded = [_decode_input(v) for v in scenario.inputs]
                        actual = evaluate_closed_function(fn_name, inputs_decoded)
                        # Expected may also be a NaN/Inf string sentinel
                        # (esm-94w fixtures use this for nan-x / nan-y cases).
                        expected_val = _decode_input(scenario.expected)
                        @testset "$(sname)" begin
                            @test _within_tol(actual, expected_val, abs_tol, rel_tol)
                        end
                    end

                    # `error_scenarios` (when present) pin load-time / call-
                    # time error cases; the binding MUST raise a
                    # `ClosedFunctionError` whose `.code` field equals
                    # `expected_error_code`.
                    if haskey(spec, :error_scenarios)
                        for err in spec.error_scenarios
                            ename = String(err.name)
                            inputs_decoded = [_decode_input(v) for v in err.inputs]
                            expected_code = String(err.expected_error_code)
                            @testset "error: $(ename)" begin
                                err_caught = try
                                    evaluate_closed_function(fn_name, inputs_decoded)
                                    nothing
                                catch e
                                    e
                                end
                                @test err_caught isa ClosedFunctionError
                                if err_caught isa ClosedFunctionError
                                    @test err_caught.code == expected_code
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    # Sanity: closed_function_names() returns the v0.3.0 set verbatim.
    @testset "closed_function_names() matches the v0.3.0 set" begin
        names = closed_function_names()
        @test "datetime.year" in names
        @test "datetime.month" in names
        @test "datetime.day" in names
        @test "datetime.hour" in names
        @test "datetime.minute" in names
        @test "datetime.second" in names
        @test "datetime.day_of_year" in names
        @test "datetime.julian_day" in names
        @test "datetime.is_leap_year" in names
        @test "interp.searchsorted" in names
        @test "interp.linear" in names
        @test "interp.bilinear" in names
        @test length(names) == 12
    end

    # Unknown name → diagnostic `unknown_closed_function`.
    @testset "Unknown name rejects with stable diagnostic code" begin
        err = try
            evaluate_closed_function("datetime.century", [0.0])
            nothing
        catch e
            e
        end
        @test err isa ClosedFunctionError
        @test (err::ClosedFunctionError).code == "unknown_closed_function"
    end
end

# ---------------------------------------------------------------------------
# Enum lowering — esm-spec §9.3, API_SPEC.md §8 item 15.
#
# Two things this pins: the canonical name is the PURE form (`lower_enums`),
# with the mutating twin under Julia's `!` (§2.2); and every rejection is an
# `EnumLoweringError`, which is what TypeScript, Python and Rust raise. Julia
# raised `ParseError` here, so a caller's `catch e; e isa ParseError` was the
# only portable handler for a failure that is not a parse failure at all.
# ---------------------------------------------------------------------------
@testset "enum lowering (esm-spec §9.3)" begin
    enum_expr() = OpExpr("enum", EarthSciAST.ASTExpr[VarExpr("Phase"), VarExpr("LIQUID")])

    function _file(; enums)
        model = Model(Dict("x" => ModelVariable(EarthSciAST.UnknownVariable)),
                      [Equation(OpExpr("D", EarthSciAST.ASTExpr[VarExpr("x")]; wrt="t"),
                                enum_expr())])
        return EsmFile("1.0.0", Metadata("Enums"); models=Dict("M" => model), enums=enums)
    end

    @testset "the pure form leaves its argument alone" begin
        file = _file(enums=Dict("Phase" => Dict("SOLID" => 0, "LIQUID" => 1)))
        lowered = lower_enums(file)

        rhs_of(f) = f.models["M"].equations[1].rhs
        # The copy is lowered ...
        @test rhs_of(lowered) isa OpExpr
        @test rhs_of(lowered).op == "const"
        @test rhs_of(lowered).value == 1
        # ... and the input is untouched, which is the whole point of the
        # pure form.
        @test rhs_of(file).op == "enum"
        @test lowered !== file

        # The mutating twin agrees on the result and rewrites in place.
        mutated = lower_enums!(file)
        @test mutated === file
        @test rhs_of(file).op == "const"
        @test rhs_of(file).value == 1
    end

    @testset "every rejection is an EnumLoweringError, not a ParseError" begin
        undeclared = try
            lower_enums(_file(enums=Dict("Other" => Dict("A" => 0))))
            nothing
        catch e
            e
        end
        @test undeclared isa EnumLoweringError
        @test !(undeclared isa ParseError)
        @test undeclared.code == "unknown_enum"

        no_symbol = try
            lower_enums(_file(enums=Dict("Phase" => Dict("SOLID" => 0))))
            nothing
        catch e
            e
        end
        @test no_symbol isa EnumLoweringError
        @test no_symbol.code == "unknown_enum_symbol"

        malformed_model = Model(Dict("x" => ModelVariable(EarthSciAST.UnknownVariable)),
            [Equation(OpExpr("D", EarthSciAST.ASTExpr[VarExpr("x")]; wrt="t"),
                      OpExpr("enum", EarthSciAST.ASTExpr[VarExpr("Phase")]))])
        malformed = try
            lower_enums(EsmFile("1.0.0", Metadata("Enums");
                                models=Dict("M" => malformed_model),
                                enums=Dict("Phase" => Dict("LIQUID" => 1))))
            nothing
        catch e
            e
        end
        @test malformed isa EnumLoweringError
        @test malformed.code == "enum_op_malformed"

        # It is still catchable through the package's error root (H-1).
        @test undeclared isa EarthSciAST.EarthSciASTError
    end
end

# ---------------------------------------------------------------------------
# An `enums` member may be ANY integer — negative, zero or positive
# (esm-spec §9.3, CONFORMANCE_SPEC §5.26).
#
# The schema used to carry `minimum: 1` on
# `EnumDeclaration.additionalProperties`, and `coerce_enums` mirrored it with
# an `int_v <= 0` rejection, so a zero-valued identifier could not be named.
# MOVES has load-bearing ones: `operatingmode.opModeID = 0` is Braking (an
# emitting mode with its own rate, not an absence) and
# `opmodepolprocassoc.polProcessID = -1` marks the drive-cycle modes
# associated with no pollutant/process.
#
# Both halves are pinned: the document LOADS, and each member resolves to
# EXACTLY its declared integer. A binding that accepted the document but
# clamped or dropped the sign would still be wrong.
# ---------------------------------------------------------------------------
@testset "zero and negative enum members (esm-spec §9.3)" begin
    fixture = joinpath(_CF_REPO_ROOT, "tests", "valid", "enums_zero_and_negative.esm")
    file = load_string(read(fixture, String))

    @test file.enums["operating_mode"]["Braking"] == 0
    @test file.enums["pol_process"]["Unassociated"] == -1
    @test validate(file).is_valid

    rhs = file.models["EnumsZeroAndNegative"].equations[1].rhs
    @test rhs.op == "makearray"
    # values[1] — the zero-valued member; values[2] — the negative one.
    @test rhs.values[1].op == "const"
    @test rhs.values[1].value == 0
    @test rhs.values[2].op == "const"
    @test rhs.values[2].value == -1
    # values[3] — both read through ARITHMETIC: 0 + 10*1 + (-1) = 9.
    @test evaluate_expr(rhs.values[1], Dict{String,Float64}()) == 0.0
    @test evaluate_expr(rhs.values[2], Dict{String,Float64}()) == -1.0
    @test evaluate_expr(rhs.values[3], Dict{String,Float64}()) == 9.0

    # Uniqueness is unchanged by the widened domain: `0` is a value like any
    # other. Written as its own case beside the positive duplicate because a
    # "seen set" using 0 as its own sentinel would pass the positive case and
    # let this one through.
    _doc(enums) = """{"esm":"1.0.0","metadata":{"name":"T","description":"d","authors":["a"]},"enums":$enums,"models":{"M":{"variables":{"x":{"type":"unknown","units":"1"}},"equations":[{"lhs":"x","rhs":{"op":"enum","args":["m","A"]}}]}}}"""
    @test_throws ParseError load_string(_doc("""{"m":{"A":0,"B":0}}"""))
    @test_throws ParseError load_string(_doc("""{"m":{"A":3,"B":3}}"""))
    ok = load_string(_doc("""{"m":{"A":0,"B":-1}}"""))
    @test ok.enums["m"]["A"] == 0
    @test ok.enums["m"]["B"] == -1
end
