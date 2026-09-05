# A §6.6.5 assertion may read an observed NO LIVE EQUATION CONSUMES (#176).
#
# The natural target of an inline test is a quantity computed FOR the test — a
# tendency, a flux, a diagnostic — which by construction nothing else reads.
# Such an observed never reaches `BuildInspection.observed_exprs`: the
# elementwise array-observed fold inlines an observed into its readers and drops
# its equation, and a DEAD one has no readers to be inlined into, so it is
# dropped outright. `_observed_field` then found no body and the assertion
# failed with "array state '<name>' has no cells in var_map" — while the same
# quantity, wired into the dynamics so that something reads it, answered fine.
# On Julia an author therefore had to CHANGE THE MODEL to make a test runnable.
#
# `_observed_field` now falls back to the component's own defining equation,
# lowered to the same per-cell form and evaluated in the same scope. Pinned
# here: a dead observed answers, a dead observed reading another dead one
# answers, name-based broadcast alignment (§4.3.4) survives the lift, the
# build's published body still wins for an observed that HAS one, and a name
# the component does not declare is still refused.
#
# Every expectation below is an independent hand-computation from the fixture's
# own constants, so an evaluator bug cannot make this pass by agreeing with
# itself.

using Test
using EarthSciAST
import JSON3
import OrdinaryDiffEqTsit5

const _DOB = EarthSciAST

const _DOB_NX = 4
const _DOB_NY = 3

# base[i] = i          (i = 1…4)
# m[i,j]  = 3(i-1) + j (row-major, 4x3)
_dob_base_values() = Any[Float64(i) for i in 1:_DOB_NX]
_dob_m_values() = Any[Any[Float64(3 * (i - 1) + j) for j in 1:_DOB_NY]
                      for i in 1:_DOB_NX]

_dob_const(value) = Dict{String, Any}("op" => "const", "args" => Any[],
                                      "value" => value)

_dob_var(shape) = Dict{String, Any}("type" => "unknown", "units" => "1",
                                    "shape" => Any[shape...])

# One document carrying every observed shape this fix has to answer for. The
# only state is `u`, integrated with a zero right-hand side so the trajectory is
# constant and each assertion is exact at any time — the fixture is about the
# observed graph, not the integrator.
function _dob_doc(assertions::Vector)
    Dict{String, Any}(
        "esm" => "1.0.0",
        "metadata" => Dict("name" => "pde_inline_dead_observed"),
        "index_sets" => Dict{String, Any}(
            "x" => Dict("kind" => "interval", "size" => _DOB_NX),
            "y" => Dict("kind" => "interval", "size" => _DOB_NY)),
        "models" => Dict{String, Any}("M" => Dict{String, Any}(
            "variables" => Dict{String, Any}(
                "u" => merge(_dob_var(("x",)), Dict("default" => 1.0)),
                "base" => _dob_var(("x",)),
                "m" => _dob_var(("x", "y")),
                # DEAD: nothing below reads any of these seven.
                "diag" => _dob_var(("x",)),
                "chain" => _dob_var(("x",)),
                "left" => _dob_var(("x",)),
                "right" => _dob_var(("x",)),
                "both" => _dob_var(("x",)),
                "grid" => _dob_var(("x", "y")),
                "mix" => _dob_var(("x", "y")),
                # LIVE, and defined by an aggregate the fold leaves alone, so
                # the build publishes its body: the fallback must not shadow it.
                "scaled" => _dob_var(("x",))),
            "equations" => Any[
                # D(u,t) = 0 * scaled — `scaled` is the only observed any
                # equation reads; the seven above it are read by nothing.
                Dict{String, Any}(
                    "lhs" => Dict("op" => "D", "args" => Any["u"], "wrt" => "t"),
                    "rhs" => Dict{String, Any}("op" => "*",
                                               "args" => Any[0.0, "scaled"])),
                Dict{String, Any}("lhs" => "base",
                                  "rhs" => _dob_const(_dob_base_values())),
                Dict{String, Any}("lhs" => "m",
                                  "rhs" => _dob_const(_dob_m_values())),
                Dict{String, Any}("lhs" => "diag",
                                  "rhs" => Dict{String, Any}("op" => "*",
                                      "args" => Any[2.0, "base"])),
                # Reads a DEAD observed, so the fallback has to recurse.
                Dict{String, Any}("lhs" => "chain",
                                  "rhs" => Dict{String, Any}("op" => "+",
                                      "args" => Any["diag", "base"])),
                # A DIAMOND over the dead `diag`: two dead siblings read it and
                # a third reads both. `diag` has to resolve on each branch —
                # a "already visited" guard would leave the second unbound.
                Dict{String, Any}("lhs" => "left",
                                  "rhs" => Dict{String, Any}("op" => "+",
                                      "args" => Any["diag", 1.0])),
                Dict{String, Any}("lhs" => "right",
                                  "rhs" => Dict{String, Any}("op" => "*",
                                      "args" => Any["diag", 2.0])),
                Dict{String, Any}("lhs" => "both",
                                  "rhs" => Dict{String, Any}("op" => "+",
                                      "args" => Any["left", "right"])),
                Dict{String, Any}("lhs" => "grid",
                                  "rhs" => Dict{String, Any}("op" => "*",
                                      "args" => Any[2.0, "m"])),
                # `base` is [x] and the result is [x,y]: §4.3.4 name alignment
                # must replicate it along `y` rather than gather positionally.
                Dict{String, Any}("lhs" => "mix",
                                  "rhs" => Dict{String, Any}("op" => "*",
                                      "args" => Any["base", "m"])),
                Dict{String, Any}("lhs" => "scaled",
                    "rhs" => Dict{String, Any}("op" => "aggregate",
                        "args" => Any["base"], "output_idx" => Any["i"],
                        "ranges" => Dict{String, Any}("i" => Any[1, _DOB_NX]),
                        "expr" => Dict{String, Any}("op" => "*",
                            "args" => Any[10.0,
                                Dict("op" => "index",
                                     "args" => Any["base", "i"])])))],
            "tests" => Any[Dict{String, Any}(
                "id" => "dead_observed",
                "time_span" => Dict("start" => 0.0, "end" => 1.0),
                "assertions" => Any[assertions...])])))
end

_dob_load(doc) = _DOB.load_string(IOBuffer(JSON3.write(doc)))

_dob_run(file) = run_pde_tests(file; model_name = "M",
                               alg = OrdinaryDiffEqTsit5.Tsit5(),
                               reltol = 1e-12, abstol = 1e-14)

_dob_reduce(var, kind, expected; time = 0.0) =
    Dict{String, Any}("variable" => var, "time" => time, "reduce" => kind,
                      "expected" => expected,
                      "tolerance" => Dict("abs" => 1e-9))

_dob_coords(var, coords, expected; time = 0.0) =
    Dict{String, Any}("variable" => var, "time" => time, "expected" => expected,
                      "tolerance" => Dict("abs" => 1e-9),
                      "coords" => Dict{String, Any}(coords...))

@testset "a DEAD observed is assertable (#176)" begin
    # base = [1,2,3,4]; diag = 2·base = [2,4,6,8]; chain = diag + base = 3·base.
    # m[i,j] = 3(i-1)+j; grid = 2m; mix[i,j] = base[i]·m[i,j] = i·(3(i-1)+j).
    results = _dob_run(_dob_load(_dob_doc(Any[
        _dob_reduce("diag", "max", 8.0),
        _dob_reduce("diag", "min", 2.0),
        _dob_coords("diag", ["x" => 3], 6.0),
        _dob_reduce("chain", "max", 12.0),
        _dob_coords("chain", ["x" => 2], 6.0),
        _dob_reduce("grid", "max", 24.0),
        _dob_reduce("grid", "min", 2.0),
        _dob_coords("grid", ["x" => 2, "y" => 3], 12.0),
        # 4·(3·3 + 3) = 48 is the largest; the [x]-shaped `base` replicates
        # along `y`, so a POSITIONAL gather would read m[i,i] and miss it.
        _dob_reduce("mix", "max", 48.0),
        _dob_coords("mix", ["x" => 3, "y" => 1], 21.0),
        _dob_coords("mix", ["x" => 1, "y" => 3], 3.0),
        # A dead observed answers at a later time too — the trajectory is
        # constant here, so the value is the same one.
        _dob_reduce("diag", "max", 8.0; time = 1.0),
        # diag = [2,4,6,8]; left = diag+1 = [3,5,7,9]; right = 2·diag =
        # [4,8,12,16]; both = left + right = [7,13,19,25].
        _dob_reduce("both", "max", 25.0),
        _dob_coords("both", ["x" => 1], 7.0),
        _dob_coords("both", ["x" => 3], 19.0),
    ])))
    @test length(results) == 15
    for r in results
        @test r.status == EarthSciAST.PASS
        @test r.passed
    end

    # `mix` really is the aligned product, cell for cell — not a positional
    # gather that happens to agree on the reductions above.
    by_idx = Dict(r.assertion_idx => r for r in results)
    @test by_idx[10].actual == 21.0
    @test by_idx[11].actual == 3.0
end

@testset "an observed the build MATERIALIZED is read from its buffer" begin
    # `base` is a document-literal array: the build folds it into the
    # const-array registry and publishes no body for it, so it reached neither
    # observed map either. base = [1,2,3,4].
    results = _dob_run(_dob_load(_dob_doc(Any[
        _dob_reduce("base", "max", 4.0),
        _dob_reduce("base", "min", 1.0),
        _dob_coords("base", ["x" => 3], 3.0),
        _dob_coords("m", ["x" => 4, "y" => 2], 11.0),
    ])))
    @test length(results) == 4
    for r in results
        @test r.status == EarthSciAST.PASS
        @test r.passed
    end
end

@testset "an observed the build DOES publish keeps its published body" begin
    # `scaled` is live and aggregate-defined, so `observed_exprs` carries it;
    # the fallback must not take over. 10·base = [10,20,30,40].
    results = _dob_run(_dob_load(_dob_doc(Any[
        _dob_reduce("scaled", "max", 40.0),
        _dob_coords("scaled", ["x" => 2], 20.0),
    ])))
    @test length(results) == 2
    @test all(r -> r.status == EarthSciAST.PASS, results)
end

@testset "a name the component does not declare is still refused" begin
    results = _dob_run(_dob_load(_dob_doc(Any[
        _dob_reduce("nope", "max", 1.0),
    ])))
    @test length(results) == 1
    @test results[1].status == EarthSciAST.ERROR
    @test results[1].actual === nothing
    @test occursin("has no cells in var_map", results[1].message)
end
