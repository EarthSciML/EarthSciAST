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
#   4. A table declaring `out_of_bounds: "error"` answers an in-range query with
#      the clamp answer and raises `table_lookup_out_of_bounds` for one outside
#      its axis (§9.5.1), under both tree-walk compilers; `:mtk` refuses it by
#      name (§9.5.3a) rather than clamp.

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
        # `Bool <: Integer` in Julia, so an untyped `true` selector would
        # otherwise resolve to output 1 instead of being refused — the trap the
        # other four bindings guard against explicitly. §9.5.2 admits an
        # integer or an output NAME, and a boolean is neither.
        @test code(lookup(table="sigma_O3_298", table_axes=axes_ok, output=true)) ==
              ERROR_CODES.TABLE_LOOKUP_OUTPUT_OUT_OF_RANGE
        @test code(lookup(table="sigma_O3_298", table_axes=axes_ok, output=false)) ==
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

    @testset "out_of_bounds: \"error\" raises outside the axis (§9.5.1)" begin
        path = _ft_path_fixture("out_of_bounds_error")
        # It LOADS, and it round-trips: §9.5.5 lists no load-time diagnostic for
        # the mode.
        file = _FTP.load_path(path)
        @test file.function_tables["strict_tab"].out_of_bounds == "error"
        json = JSON3.read(_FTP.to_json(file))
        @test json.models.M.equations[1].rhs.op == "table_lookup"
        @test json.function_tables.strict_tab.out_of_bounds == "error"

        # The lowering is the clamp tree, marked with the table id on the node
        # that reads the query.
        lowered = _FTP.lower_table_lookups(file).models["M"].equations[1].rhs::OpExpr
        @test lowered.name == "interp.linear"
        @test lowered.table == "strict_tab"

        raised(f) = try
            f(); nothing
        catch err
            err
        end
        doc = JSON3.read(read(path, String), Dict{String,Any})
        # A state reads the strict table through a scalar lookup and a lookup in
        # an array equation (the array tiers), and a bilinear one on each axis.
        # (`nearest` with a run-time query is an index computed at run time,
        # which this binding's evaluator does not take for any table.)
        doc["function_tables"]["bi_tab"] = Dict{String,Any}(
            "axes" => Any[Dict("name" => "a", "values" => [0.0, 1.0]),
                          Dict("name" => "b", "values" => [0.0, 2.0, 4.0])],
            "interpolation" => "bilinear", "out_of_bounds" => "error",
            "data" => [[1.0, 2.0, 3.0], [4.0, 5.0, 6.0]])
        lk(tab, ax) = Dict{String,Any}("op" => "table_lookup", "table" => tab,
                                       "axes" => ax, "args" => Any[])
        ix(v, i) = Dict{String,Any}("op" => "index", "args" => Any[v, i])
        m = doc["models"]["M"]
        m["variables"]["x"] = Dict{String,Any}("type" => "unknown", "default" => 2.5)
        m["variables"]["z"] = Dict{String,Any}("type" => "unknown", "default" => 2.0)
        m["variables"]["v"] = Dict{String,Any}("type" => "unknown", "shape" => Any["i"])
        m["variables"]["w"] = Dict{String,Any}("type" => "unknown", "shape" => Any["i"])
        doc["index_sets"] = Dict{String,Any}("i" => Dict("kind" => "interval", "size" => 3))
        faq(body) = Dict{String,Any}("op" => "faq", "args" => Any[], "output_idx" => Any["i"],
                                     "ranges" => Dict("i" => Any[1, 3]), "expr" => body)
        dD(x) = Dict{String,Any}("op" => "D", "args" => Any[x], "wrt" => "t")
        append!(m["equations"], Any[
            Dict("lhs" => dD("x"), "rhs" => lk("strict_tab", Dict("p" => "x"))),
            Dict("lhs" => dD("z"), "rhs" => Dict("op" => "+", "args" => Any[
                lk("bi_tab", Dict("a" => 0.5, "b" => "z")),
                lk("bi_tab", Dict("a" => Dict("op" => "*", "args" => Any[0.25, "z"]),
                                  "b" => 1.0))])),
            Dict("lhs" => dD("w"), "rhs" => 0.0),
            Dict("lhs" => faq(dD(ix("v", "i"))),
                 "rhs" => faq(lk("strict_tab", Dict("p" => ix("w", "i")))))])
        du_at(prob, set) = begin
            u = copy(prob.u0)
            for (k, val) in set
                u[prob.var_map[k]] = val
            end
            du = zero(u)
            prob.f!(du, u, prob.p, 0.0)
            du
        end
        inrange = Dict("M.x" => 1.0, "M.z" => 2.0, "M.w[1]" => 1.5, "M.w[2]" => 4.0,
                       "M.w[3]" => 3.25)
        answers = Dict{Symbol,Any}()
        for compiler in (:interpreter, :native)
            # The test drives every state itself (`du_at`), so the starting
            # values the build requires (esm-spec §11.4) are placeholders.
            prob = _FTP.esm_problem(doc, (0.0, 1.0); compiler = compiler,
                                    u0 = Dict("M.w" => 0.0, "M.v" => 0.0))
            du = du_at(prob, inrange)
            # In range (an end knot included) the answer is the clamp answer.
            @test du[prob.var_map["M.x"]] == 10.0
            # bi_tab(0.5, 2) = 3.5 and bi_tab(0.5, 1) = 3.0.
            @test du[prob.var_map["M.z"]] == 3.5 + 3.0
            @test [du[prob.var_map["M.v[$i]"]] for i in 1:3] == [15.0, 40.0, 32.5]
            answers[compiler] = du
            # A NaN query is not out of range: it propagates.
            @test isnan(du_at(prob, merge(inrange, Dict("M.x" => NaN)))[prob.var_map["M.x"]])
            # Strictly outside the axis, every lookup raises by name.
            # z = 4.5 leaves the second axis; z = -1 leaves both, and the first
            # axis (through 0.25 z) is checked first.
            for bad in (Dict("M.x" => 0.5), Dict("M.x" => 4.25), Dict("M.z" => 4.5),
                        Dict("M.z" => -1.0), Dict("M.w[2]" => 4.000001))
                e = raised(() -> du_at(prob, merge(inrange, bad)))
                @test e isa _FTP.TableLookupError
                @test e isa _FTP.TableLookupError &&
                      e.code == ERROR_CODES.TABLE_LOOKUP_OUT_OF_BOUNDS
            end
        end
        @test all(answers[:native] .=== answers[:interpreter])
        # The fixture itself: its in-range query answers 25.0, the clamp value.
        fx = _FTP.esm_problem(path, (0.0, 1.0); compiler = :native)
        @test only(_FTP.observed_field(fx, "M.y")) == 25.0

        # The ModelingToolkit lowering has no raising form, so it refuses the
        # table by name rather than clamp.
        e3 = raised(() -> _FTP.esm_problem(path, (0.0, 1.0); compiler = :mtk))
        @test e3 isa _FTP.TableLookupError
        @test e3 isa _FTP.TableLookupError &&
              e3.code == ERROR_CODES.TABLE_OUT_OF_BOUNDS_UNSUPPORTED
    end
end
