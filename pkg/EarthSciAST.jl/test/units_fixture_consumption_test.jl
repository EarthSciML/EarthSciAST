# Units fixtures consumption runner (gt-dt0o).
#
# The three units_*.esm files in tests/valid/ carry inline `tests` blocks
# (id / parameter_overrides / initial_conditions / time_span / assertions)
# added in gt-p3v. Schema parse coverage is already asserted elsewhere
# (units_test.jl's Cross-binding units fixtures suite). This file closes
# the schema-vs-execution gap: every assertion's target (all of which are
# observed variables at t = 0) is actually evaluated under the test's
# bindings and compared against the expected value within the resolved
# tolerance (assertion → test → model, falling back to rtol = 1e-6).
#
# Corrupting an expected value in any fixture — or reverting the
# pressure_drop fix from gt-p3v — must cause this suite to fail.
using Test
using EarthSciAST

const _ESM_UF = EarthSciAST

function _resolve_tol_uf(model_tol, test_tol, assertion_tol)
    for cand in (assertion_tol, test_tol, model_tol)
        cand === nothing && continue
        r = cand.rel === nothing ? 0.0 : cand.rel
        a = cand.abs === nothing ? 0.0 : cand.abs
        return (r, a)
    end
    return (1.0e-6, 0.0)
end

# Resolve every observed variable to a Float64 by iterated substitution.
# The bindings dict starts with parameters and states; each pass tries to
# evaluate any observed whose expression no longer has unbound leaves.
# `UnboundVariableError` is the signal "dependencies not yet resolved" and
# is swallowed; any other error propagates. Cycle-free fixtures converge
# in at most one pass per observed variable. Evaluation is routed through
# the official tree-walk evaluator (`evaluate_expr`), so this fixture
# consumer shares the production runner's dispatch table and lives on the
# `.esm → AST → official runner` simulation pathway.
function _resolve_observed!(model, bindings::Dict{String,Float64})
    for _ in 1:(length(model.variables) + 1)
        progress = false
        for (vname, var) in model.variables
            var.type == _ESM_UF.ObservedVariable || continue
            haskey(bindings, vname) && continue
            var.expression === nothing && continue
            try
                bindings[vname] = _ESM_UF.evaluate_expr(var.expression, bindings)
                progress = true
            catch err
                err isa _ESM_UF.UnboundVariableError || rethrow(err)
            end
        end
        progress || break
    end
end

function _run_units_test(mname::AbstractString, model, t::_ESM_UF.Test)
    bindings = Dict{String,Float64}()
    for (vname, var) in model.variables
        (var.type == _ESM_UF.ParameterVariable ||
         var.type == _ESM_UF.StateVariable) || continue
        var.default === nothing && continue
        bindings[vname] = Float64(var.default)
    end
    for (name, val) in t.initial_conditions
        bindings[name] = Float64(val)
    end
    for (name, val) in t.parameter_overrides
        bindings[name] = Float64(val)
    end

    _resolve_observed!(model, bindings)

    for a in t.assertions
        rel, abs_ = _resolve_tol_uf(model.tolerance, t.tolerance, a.tolerance)
        @test haskey(bindings, a.variable)
        actual = bindings[a.variable]
        if abs_ > 0 && iszero(a.expected)
            @test isapprox(actual, a.expected; atol=abs_)
        elseif rel > 0
            @test isapprox(actual, a.expected; rtol=rel, atol=abs_)
        else
            @test isapprox(actual, a.expected; atol=abs_)
        end
    end
end

@testset "Units fixtures inline tests execution (gt-dt0o)" begin
    fixtures_root = joinpath(@__DIR__, "..", "..", "..", "tests", "valid")
    fixtures = ["units_conversions.esm",
                "units_dimensional_analysis.esm",
                "units_propagation.esm"]

    any_tests_across_fixtures = false
    for fname in fixtures
        @testset "$fname" begin
            fpath = joinpath(fixtures_root, fname)
            @test isfile(fpath)
            file = _ESM_UF.load(fpath)
            @test file.models !== nothing

            any_model_tests = false
            for (mname, model) in file.models
                isempty(model.tests) && continue
                any_model_tests = true
                for t in model.tests
                    @testset "$mname/$(t.id)" begin
                        _run_units_test(string(mname), model, t)
                    end
                end
            end
            @test any_model_tests
            any_tests_across_fixtures |= any_model_tests
        end
    end
    @test any_tests_across_fixtures
end
