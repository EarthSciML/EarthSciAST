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

# A first-order decay `species → ∅` at rate `k`, as a raw reaction.
_dl_decay(id, species, k) = Dict{String, Any}(
    "id" => id, "rate" => k, "products" => nothing,
    "substrates" => Any[Dict{String, Any}("species" => species, "stoichiometry" => 1)])

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

    @testset "a failing pass is an analysis warning, never a throw" begin
        file = EarthSciAST.load_path(joinpath(TESTUTILS_REPO_ROOT, _DL_FIXTURE))
        baseline = EarthSciAST.validate(file)
        @test baseline.is_valid
        warnings = EarthSciAST.UnitWarning[]
        EarthSciAST._push_dimensionless_literal_warnings!(
            warnings, EarthSciAST._UnitsInputs(file), _ -> error("forced failure"))
        @test length(warnings) == 1
        @test only(warnings).code == EarthSciAST.ERROR_CODES.ANALYSIS
        @test occursin("forced failure", only(warnings).message)
        # The downgraded warning leaves validity to the current rule alone.
        result = EarthSciAST.ValidationResult(baseline.schema_errors,
                                              baseline.structural_errors,
                                              unit_warnings=warnings)
        @test result.is_valid
    end

    @testset "a nested reaction system's constraint equation is typed through its template" begin
        doc = Dict{String, Any}(
            "esm" => "1.2.0",
            "metadata" => Dict{String, Any}("name" => "nested_constraint_template"),
            "reaction_systems" => Dict{String, Any}(
                "Chem" => Dict{String, Any}(
                    "species" => Dict{String, Any}("A" => Dict{String, Any}("units" => "mol/m^3")),
                    "parameters" => Dict{String, Any}(
                        "kA" => Dict{String, Any}("units" => "1/s", "default" => 1.0)),
                    "expression_templates" => Dict{String, Any}(
                        "celsius" => Dict{String, Any}(
                            "params" => Any["x"],
                            "body" => Dict{String, Any}("op" => "-", "args" => Any["x", 273.15]))),
                    "reactions" => Any[_dl_decay("R1", "A", "kA")],
                    "subsystems" => Dict{String, Any}(
                        "Inner" => Dict{String, Any}(
                            "species" => Dict{String, Any}(
                                "B" => Dict{String, Any}("units" => "mol/m^3")),
                            "parameters" => Dict{String, Any}(
                                "T" => Dict{String, Any}("units" => "K", "default" => 300.0),
                                "Tc" => Dict{String, Any}("units" => "K", "default" => 26.85),
                                "kB" => Dict{String, Any}("units" => "1/s", "default" => 1.0)),
                            "reactions" => Any[_dl_decay("R2", "B", "kB")],
                            "constraint_equations" => Any[Dict{String, Any}(
                                "lhs" => "Tc",
                                "rhs" => Dict{String, Any}(
                                    "op" => "apply_expression_template", "args" => Any[],
                                    "name" => "celsius",
                                    "bindings" => Dict{String, Any}("x" => "T")))])))))
        file = EarthSciAST.load_document(doc)
        result = EarthSciAST.validate(file)
        @test result.is_valid
        @test [w.path for w in _dl_warnings(result)] ==
              ["/reaction_systems/Chem/subsystems/Inner/constraint_equations/0"]
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

    @testset "ic carries its operand's unit; an undeclared t is in seconds" begin
        icq = EarthSciAST.OpExpr("ic", EarthSciAST.ASTExpr[EarthSciAST.VarExpr("q")])
        for on in (false, true)
            @test EarthSciAST.get_expression_dimensions(icq, Dict("q" => "km");
                                                        dimensionless_literals=on) == u"km"
        end
        @test EarthSciAST.get_expression_dimensions(EarthSciAST.VarExpr("t"),
                                                    Dict{String, String}()) == u"s"
        # A declared t keeps its declared unit.
        @test EarthSciAST.get_expression_dimensions(EarthSciAST.VarExpr("t"),
                                                    Dict("t" => "hr")) == u"hr"
        # D with respect to an undeclared t stays undeterminable.
        dq = EarthSciAST.OpExpr("D", EarthSciAST.ASTExpr[EarthSciAST.VarExpr("q")]; wrt="t")
        @test EarthSciAST.get_expression_dimensions(dq, Dict("q" => "kg")) === nothing
    end
end
