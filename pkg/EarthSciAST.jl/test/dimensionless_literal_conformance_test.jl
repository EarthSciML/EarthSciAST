# Cross-binding conformance for the esm-spec §4.8.6 warning stage: a bare
# numeric literal read as DIMENSIONLESS at scale 1 (the literal zero excepted).
#
# Drives the shared golden at `tests/conformance/dimensionless_literal/`: every
# file it lists is VALID and carries exactly the pinned
# `units_dimensionless_literal_mismatch` warnings, at the pinned JSON Pointers.

using Test
using EarthSciAST
using JSON3
using Unitful

include("testutils.jl")  # TESTUTILS_REPO_ROOT

const _DL_DIR = joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance", "dimensionless_literal")
const _DL_GOLDEN = JSON3.read(read(joinpath(_DL_DIR, "golden", "expected_warnings.json"), String))
const _DL_FIXTURE = "tests/conformance/dimensionless_literal/fixtures/dimensionless_literal.esm"

_dl_warnings(result) = [w for w in result.unit_warnings
                        if w.code == EarthSciAST.UNIT_FINDING_DIMENSIONLESS_LITERAL]

@testset "dimensionless-literal warning (esm-spec §4.8.6)" begin
    @testset "the golden names the registered code" begin
        @test _DL_GOLDEN["code"] == EarthSciAST.UNIT_FINDING_DIMENSIONLESS_LITERAL
        @test EarthSciAST.UNIT_FINDING_DIMENSIONLESS_LITERAL in EarthSciAST.error_code_names()
    end

    @testset "$rel" for rel in sort!([String(k) for k in keys(_DL_GOLDEN["files"])])
        result = EarthSciAST.validate_path(joinpath(TESTUTILS_REPO_ROOT, rel))
        @test result.is_valid
        result.is_valid || @info "structural errors" rel [(e.error_type, e.path) for e in result.structural_errors]
        got = sort!([w.path for w in _dl_warnings(result)])
        @test got == [String(p) for p in _DL_GOLDEN["files"][rel]]
    end

    @testset "the warning names the literal and the repair" begin
        result = EarthSciAST.validate_path(joinpath(TESTUTILS_REPO_ROOT, _DL_FIXTURE))
        by_path = Dict(w.path => w.message for w in _dl_warnings(result))
        message = by_path["/models/Literals/equations/0"]
        @test occursin("/models/Literals/equations/0", message)
        @test occursin("273.15", message)
        @test occursin("K", message)
        @test occursin("const(", message)
        # The warning is never a structural error at this stage.
        @test !any(e -> e.error_type == EarthSciAST.UNIT_FINDING_DIMENSIONLESS_LITERAL,
                   result.structural_errors)
    end

    @testset "zero stays neutral, every other literal is dimensionless" begin
        env = Dict{String, String}()
        for (expr, expected) in (
                (EarthSciAST.IntExpr(0), nothing),
                (EarthSciAST.NumExpr(0.0), nothing),
                (EarthSciAST.NumExpr(-0.0), nothing),
                (EarthSciAST.OpExpr("-", EarthSciAST.ASTExpr[EarthSciAST.NumExpr(0.0)]), nothing),
                (EarthSciAST.OpExpr("const", EarthSciAST.ASTExpr[]; value=0), nothing),
                (EarthSciAST.IntExpr(2), Unitful.NoUnits),
                (EarthSciAST.NumExpr(-1.5), Unitful.NoUnits),
                (EarthSciAST.OpExpr("const", EarthSciAST.ASTExpr[]; value=273.15), Unitful.NoUnits))
            # The current rule: every literal is undeterminable.
            @test EarthSciAST.get_expression_dimensions(expr, env) === nothing
            got = EarthSciAST.get_expression_dimensions(expr, env; dimensionless_literals=true)
            @test got == expected
        end
        # A unit-bearing const is unchanged by the switch.
        kconst = EarthSciAST.OpExpr("const", EarthSciAST.ASTExpr[]; value=273.15, units="K")
        @test EarthSciAST.get_expression_dimensions(kconst, env; dimensionless_literals=true) ==
              u"K"
        # The switch is what makes `T - 273.15` a mismatch; without it the
        # literal adopts T's unit.
        diff = EarthSciAST.OpExpr("-", EarthSciAST.ASTExpr[EarthSciAST.VarExpr("T"),
                                                          EarthSciAST.NumExpr(273.15)])
        @test isempty(EarthSciAST.expression_unit_findings(diff, Dict("T" => "K")))
        @test !isempty(EarthSciAST.expression_unit_findings(diff, Dict("T" => "K");
                                                            dimensionless_literals=true))
        # `max(x, 0)`: zero stays neutral under the switch too.
        mx = EarthSciAST.OpExpr("max", EarthSciAST.ASTExpr[EarthSciAST.VarExpr("x"),
                                                          EarthSciAST.IntExpr(0)])
        @test isempty(EarthSciAST.expression_unit_findings(mx, Dict("x" => "m");
                                                          dimensionless_literals=true))
    end
end
