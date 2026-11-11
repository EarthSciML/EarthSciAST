# Enum lowering (esm-spec §9.3; src/enum_lowering.jl): the pure and mutating
# forms, the `EnumLoweringError` codes, and enum members of any integer value.

using Test
using JSON3
using EarthSciAST

include("testutils.jl")  # TESTUTILS_REPO_ROOT

const _ENUM_REPO_ROOT = TESTUTILS_REPO_ROOT


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
        model = Model(
            Dict("x" => ModelVariable(EarthSciAST.UnknownVariable)),
            [
                Equation(
                    OpExpr("D", EarthSciAST.ASTExpr[VarExpr("x")]; wrt = "t"),
                    enum_expr()
                ),
            ]
        )
        return EsmFile("2.0.0", Metadata("Enums"); models = Dict("M" => model), enums = enums)
    end

    @testset "the pure form leaves its argument alone" begin
        file = _file(enums = Dict("Phase" => Dict("SOLID" => 0, "LIQUID" => 1)))
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
            lower_enums(_file(enums = Dict("Other" => Dict("A" => 0))))
            nothing
        catch e
            e
        end
        @test undeclared isa EnumLoweringError
        @test !(undeclared isa ParseError)
        @test undeclared.code == "unknown_enum"

        no_symbol = try
            lower_enums(_file(enums = Dict("Phase" => Dict("SOLID" => 0))))
            nothing
        catch e
            e
        end
        @test no_symbol isa EnumLoweringError
        @test no_symbol.code == "unknown_enum_symbol"

        malformed_model = Model(
            Dict("x" => ModelVariable(EarthSciAST.UnknownVariable)),
            [
                Equation(
                    OpExpr("D", EarthSciAST.ASTExpr[VarExpr("x")]; wrt = "t"),
                    OpExpr("enum", EarthSciAST.ASTExpr[VarExpr("Phase")])
                ),
            ]
        )
        malformed = try
            lower_enums(
                EsmFile(
                    "2.0.0", Metadata("Enums");
                    models = Dict("M" => malformed_model),
                    enums = Dict("Phase" => Dict("LIQUID" => 1))
                )
            )
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
# (esm-spec §9.3; CONFORMANCE_SPEC, "An `enums` Member Is a Code, Not a Position").
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
    fixture = joinpath(_ENUM_REPO_ROOT, "tests", "valid", "enums_zero_and_negative.esm")
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
    @test evaluate_expr(rhs.values[1], Dict{String, Float64}()) == 0.0
    @test evaluate_expr(rhs.values[2], Dict{String, Float64}()) == -1.0
    @test evaluate_expr(rhs.values[3], Dict{String, Float64}()) == 9.0

    # Uniqueness is unchanged by the widened domain: `0` is a value like any
    # other. Written as its own case beside the positive duplicate because a
    # "seen set" using 0 as its own sentinel would pass the positive case and
    # let this one through.
    _doc(enums) = """{"esm":"2.0.0","metadata":{"name":"T","description":"d","authors":["a"]},"enums":$enums,"models":{"M":{"variables":{"x":{"type":"unknown","units":"1"}},"equations":[{"lhs":"x","rhs":{"op":"enum","args":["m","A"]}}]}}}"""
    dup_code(f) = try
        f(); ""
    catch e
        e isa EnumLoweringError || rethrow()
        e.code
    end
    @test dup_code(() -> load_string(_doc("""{"m":{"A":0,"B":0}}"""))) == "enum_duplicate_value"
    @test dup_code(() -> load_string(_doc("""{"m":{"A":3,"B":3}}"""))) == "enum_duplicate_value"
    # Whether or not any `enum` op names the duplicated symbols.
    @test dup_code(() -> load_string(_doc("""{"m":{"A":1,"B":2,"C":2}}"""))) ==
        "enum_duplicate_value"
    # Values MAY coincide across enums.
    @test dup_code(() -> load_string(_doc("""{"m":{"A":1},"n":{"A":1}}"""))) == ""
    # A file built in memory (no coercer) is checked by the lowering.
    mem = EsmFile("2.0.0", Metadata("E"); enums = Dict("m" => Dict("A" => 0, "B" => 0)))
    @test dup_code(() -> lower_enums(mem)) == "enum_duplicate_value"
    ok = load_string(_doc("""{"m":{"A":0,"B":-1}}"""))
    @test ok.enums["m"]["A"] == 0
    @test ok.enums["m"]["B"] == -1

    # The two tests/invalid fixtures (resolver_only, pinned code).
    for f in ("enum_duplicate_value.esm", "enum_duplicate_zero_value.esm")
        @test dup_code(() -> load_path(joinpath(_ENUM_REPO_ROOT, "tests", "invalid", f))) ==
            "enum_duplicate_value"
    end
end
