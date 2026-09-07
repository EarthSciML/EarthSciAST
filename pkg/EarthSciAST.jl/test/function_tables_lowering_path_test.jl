# The esm-spec §9.5.3 `table_lookup` lowering ON THE PATH THAT EVALUATES A
# DOCUMENT — the property `function_tables_lowering_test.jl` structurally
# cannot see, because that harness performs the lowering itself.
#
# Every binding had a §9.5.3 lowering in its test harness and none had one on
# the evaluation path (issue #188), so a real `.esm` whose observed is a
# `table_lookup` validated, flattened and round-tripped cleanly and then failed
# every inline-test assertion that read it — while the SAME lookup spelled out
# by hand in the lowered `interp.linear` form passed. That is the shape of a
# transformation that is verified but never applied.
#
# Four properties are pinned here:
#   1. `load` does NOT lower — the authored `function_tables` / `table_lookup`
#      forms still round-trip (esm-spec §9.5.4).
#   2. The lowering produces exactly the §9.5.3 tree, and is idempotent.
#   3. Both build front doors apply it: the MTK inline-test runner
#      (`run_esm_tests`, over the shared `inline_test` fixture, which asserts a
#      `table_lookup` observed, its hand-lowered twin, and a clamped lookup all
#      answer the same numbers) and the tree-walk `esm_problem`.
#   4. A table declaring the unimplemented `out_of_bounds: "error"` mode is
#      REFUSED by name (§9.5.3a) rather than silently answered with clamping
#      semantics.

using Test
using EarthSciAST
using JSON3
import ModelingToolkit             # activates the MTK ext `run_esm_tests` compiles through
import SciMLBase: solve
import OrdinaryDiffEqTsit5: Tsit5

const _FTP = EarthSciAST

const FT_PATH_FIXTURES_ROOT = abspath(joinpath(@__DIR__, "..", "..", "..",
    "tests", "conformance", "function_tables"))

_ft_path_fixture(name) = joinpath(FT_PATH_FIXTURES_ROOT, name, "fixture.esm")

@testset "table_lookup lowering on the evaluation path (esm-spec §9.5.3, #188)" begin

    @testset "load leaves the authored form alone (§9.5.4)" begin
        file = _FTP.load_path(_ft_path_fixture("roundtrip"))
        eqs = file.models["M"].equations
        # Neither demoted (the lookup lowered at load) nor promoted (the
        # hand-written inline-const lookup folded into a table).
        @test (eqs[1].rhs::OpExpr).op == "table_lookup"
        @test (eqs[2].rhs::OpExpr).op == "fn"

        json = JSON3.read(_FTP.to_json(file))
        @test haskey(json, :function_tables)
        @test json.function_tables.sigma_O3.data == [1.1, 1.0, 0.95, 0.87]
        @test json.models.M.equations[1].rhs.op == "table_lookup"
        @test json.models.M.equations[1].rhs.table == "sigma_O3"
        @test json.models.M.equations[2].rhs.name == "interp.linear"

        # The pure form copies: a build that lowers cannot reach back and
        # rewrite the image `save` re-serializes.
        lowered = _FTP.lower_table_lookups(file)
        @test (lowered.models["M"].equations[1].rhs::OpExpr).name == "interp.linear"
        @test (file.models["M"].equations[1].rhs::OpExpr).op == "table_lookup"
        @test JSON3.read(_FTP.to_json(file)) == json
    end

    @testset "the §9.5.3 tree" begin
        file = _FTP.load_path(_ft_path_fixture("linear"))
        tables = file.function_tables
        node = file.models["M"].equations[1].rhs::OpExpr
        lowered = _FTP._lower_expr_table_lookups(node, tables)::OpExpr
        @test lowered.op == "fn"
        @test lowered.name == "interp.linear"
        @test lowered.args[1].value ==
              [1.10e-17, 1.00e-17, 9.50e-18, 8.70e-18, 7.90e-18, 7.00e-18, 6.10e-18, 5.20e-18]
        @test lowered.args[2].value == Float64[1, 2, 3, 4, 5, 6, 7, 8]
        @test (lowered.args[3]::VarExpr).name == "lambda"
        # Idempotent, and identity-preserving: a tree with no `table_lookup`
        # left is returned as itself, not rebuilt.
        @test _FTP._lower_expr_table_lookups(lowered, tables) === lowered

        # The axis `const`s go in the table's DECLARED order (the order of
        # `data`'s inner dimensions), and `output` selects the row of `data`'s
        # LEADING dimension whether spelled as a name or as a 0-based index.
        bil = _FTP.load_path(_ft_path_fixture("bilinear"))
        btables = bil.function_tables
        by_name = _FTP._lower_expr_table_lookups(
            bil.models["M"].equations[1].rhs, btables)::OpExpr
        @test by_name.name == "interp.bilinear"
        @test by_name.args[1].value == [[1.0, 1.5, 2.0], [1.1, 1.6, 2.1], [1.2, 1.7, 2.2]]
        @test by_name.args[2].value == [10.0, 100.0, 1000.0]
        @test by_name.args[3].value == [0.1, 0.5, 1.0]
        @test (by_name.args[4]::VarExpr).name == "P_atm"
        @test (by_name.args[5]::VarExpr).name == "cos_sza"
        by_index = _FTP._lower_expr_table_lookups(
            bil.models["M"].equations[2].rhs, btables)::OpExpr
        @test by_index.args[1].value == [[2.0, 2.5, 3.0], [2.1, 2.6, 3.1], [2.2, 2.7, 3.2]]
    end

    @testset "malformed lookups raise their §9.5.5 code" begin
        tables = _FTP.load_path(_ft_path_fixture("linear")).function_tables
        lookup(; kwargs...) = OpExpr("table_lookup", EarthSciAST.ASTExpr[]; kwargs...)
        axes_ok = Dict{String,EarthSciAST.ASTExpr}("lambda_idx" => VarExpr("lambda"))
        code(e::OpExpr) = try
            _FTP._lower_expr_table_lookups(e, tables)
            ""
        catch err
            err isa _FTP.TableLookupError || rethrow()
            err.code
        end

        @test code(lookup(table="nope", table_axes=axes_ok)) ==
              ERROR_CODES.TABLE_LOOKUP_UNKNOWN_TABLE
        @test code(lookup(table="sigma_O3_298",
                          table_axes=Dict{String,EarthSciAST.ASTExpr}(
                              "wrong" => VarExpr("lambda")))) ==
              ERROR_CODES.TABLE_LOOKUP_AXIS_NAME_MISMATCH
        @test code(lookup(table="sigma_O3_298", table_axes=axes_ok, output=3)) ==
              ERROR_CODES.TABLE_LOOKUP_OUTPUT_OUT_OF_RANGE
        @test code(lookup(table="sigma_O3_298", table_axes=axes_ok, output="NO2")) ==
              ERROR_CODES.TABLE_LOOKUP_OUTPUT_OUT_OF_RANGE
    end

    # ---- The regression itself: the shared end-to-end fixture, run through the
    #      inline-test runner (§6.6, Julia's `esm test`). `y` is a table_lookup,
    #      `z` its hand-lowered twin, `w` a lookup above the last knot that the
    #      default `out_of_bounds: "clamp"` holds at the last table value.
    #      Before the fix `y` and `w` could not even compile ("Unsupported
    #      operator: table_lookup") while `z` answered 25.
    @testset "inline_test fixture: all three assertions pass (#188)" begin
        dir = joinpath(FT_PATH_FIXTURES_ROOT, "inline_test")
        results, exit_code = _FTP.run_esm_tests([dir]; root=dir, verbose=false)
        @test length(results) == 3
        by = Dict(r.variable => r for r in results)
        for (name, expected) in ("y" => 25.0, "z" => 25.0, "w" => 40.0)
            r = get(by, name, nothing)
            @test r !== nothing
            r === nothing && continue
            @test r.status == _FTP.PASS
            @test r.actual ≈ expected rtol = 1e-12
        end
        # §9.5's central promise: the lowered lookup and the hand-written
        # inline-const one are the SAME computation, not merely close.
        @test by["y"].actual == by["z"].actual
        @test exit_code == 0
    end

    @testset "the tree-walk build evaluates a lowered lookup" begin
        # `linear`: D(k_O3) ~ table_lookup(sigma_O3_298, lambda_idx = lambda),
        # lambda = 4.5 ⇒ the midpoint of the [4, 5] knots. A constant tendency,
        # so k_O3(1) is that value exactly.
        expected = 8.70e-18 + 0.5 * (7.90e-18 - 8.70e-18)
        path = _ft_path_fixture("linear")
        prob = _FTP.esm_problem(path, (0.0, 1.0))
        sol = solve(prob, Tsit5(); reltol=1e-12, abstol=1e-20)
        @test sol.u[end][prob.var_map["M.k_O3"]] ≈ expected rtol = 1e-9

        # The same hook, reached by the OTHER carrier: a caller who flattened
        # for themselves hands `esm_problem` a `FlattenedSystem`, which carries
        # `function_tables` for exactly this reason.
        flat = _FTP.flatten(_FTP.load_path(path))
        fprob = _FTP.esm_problem(flat, (0.0, 1.0))
        fsol = solve(fprob, Tsit5(); reltol=1e-12, abstol=1e-20)
        @test fsol.u[end][fprob.var_map["M.k_O3"]] ≈ expected rtol = 1e-9
    end

    @testset "out_of_bounds: \"error\" is refused by name (§9.5.3a)" begin
        path = _ft_path_fixture("out_of_bounds_error")
        # It LOADS, and it round-trips: §9.5.5 lists no load-time diagnostic for
        # the mode, and refusing at load would take the document's authored form
        # with it.
        file = _FTP.load_path(path)
        @test file.function_tables["strict_tab"].out_of_bounds == "error"
        json = JSON3.read(_FTP.to_json(file))
        @test json.models.M.equations[1].rhs.op == "table_lookup"
        @test json.function_tables.strict_tab.out_of_bounds == "error"

        # What it does not do is EVALUATE — at the point it would otherwise
        # lower, on either build front door.
        refusal(f) = try
            f()
            nothing
        catch err
            err
        end
        e1 = refusal(() -> _FTP.lower_table_lookups(file))
        @test e1 isa _FTP.TableLookupError
        @test e1 isa EarthSciASTError
        @test e1.code == ERROR_CODES.TABLE_OUT_OF_BOUNDS_UNSUPPORTED
        e2 = refusal(() -> _FTP.esm_problem(path, (0.0, 1.0)))
        @test e2 isa _FTP.TableLookupError
        @test e2.code == ERROR_CODES.TABLE_OUT_OF_BOUNDS_UNSUPPORTED
    end
end
