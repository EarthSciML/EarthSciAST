# esm-spec §4.2: on a `D` node an ABSENT `wrt` MEANS `t`.
#
# Regression for EarthSciAST#407. `classification.jl` had always applied the
# default (`_is_time_derivative` accepts `wrt === nothing`), but the tree-walk
# runner's own LHS predicates in `tree_walk/resolve.jl` spelled the test
# `lhs.wrt == "t"` and therefore did not. So `ode_states` reported `z` as a
# state of the document while `run_inline_tests` refused the very same document
# with `E_TREEWALK_UNSUPPORTED_EQUATION` — the binding disagreeing with itself
# about one node.
#
# Both the SCALAR and the SHAPED spelling are exercised, each against its
# explicitly-spelled twin, so the two forms cannot drift apart again. Julia's
# miss was uniform across both shapes; Rust's was scalar-only, which is what
# made the defect read as a shape problem rather than a `wrt` problem.

using Test
using EarthSciAST
import OrdinaryDiffEqTsit5

include("testutils.jl")

# The scalar and shaped halves live in separate shared fixtures because the
# `tests/simulation/` corpus's generic runner drives a SCALAR backend with no
# `faq` evaluator; the shaped pair is registered in the `simulate_faq`
# conformance manifest instead.
const _WRT_SCALAR = joinpath(TESTUTILS_REPO_ROOT, "tests", "simulation",
                             "wrt_default_omitted.esm")
# The shaped pair is two FILES, not two models of one file: every runner binds
# the per-cell initial conditions by bare name, which is ambiguous when two
# models in one document both declare `x`.
const _WRT_SHAPED_OMITTED = joinpath(TESTUTILS_REPO_ROOT, "tests", "fixtures", "faq",
                                     "28_wrt_default_omitted_shaped.esm")
const _WRT_SHAPED_EXPLICIT = joinpath(TESTUTILS_REPO_ROOT, "tests", "fixtures", "faq",
                                      "29_wrt_default_explicit_shaped.esm")

# Every assertion of one model as (variable, time, actual), demanding PASS.
function _wrt_run(fixture::AbstractString, model::AbstractString)
    results = run_inline_tests(fixture; model_name=model, alg=OrdinaryDiffEqTsit5.Tsit5(),
                               reltol=1e-12, abstol=1e-14)
    @test !isempty(results)
    for r in results
        @test r.status === PASS
        r.status === PASS || @info "failing assertion" model r.test_id r.message
    end
    return [(r.variable, r.time, r.actual) for r in results]
end

# The two spellings must agree sample for sample, not merely both land close
# enough to the closed form.
function _wrt_agree(fa::AbstractString, omitted::AbstractString,
                    explicit::AbstractString; fb::AbstractString=fa)
    a = _wrt_run(fa, omitted)
    b = _wrt_run(fb, explicit)
    @test length(a) == length(b)
    for ((va, ta, xa), (vb, tb, xb)) in zip(a, b)
        @test (va, ta) == (vb, tb)
        @test xa !== nothing && xb !== nothing
        @test isapprox(xa, xb; rtol=1e-9, atol=1e-12)
    end
end

@testset "`wrt` omitted on D means t (esm-spec §4.2)" begin
    @testset "classification already agreed" begin
        doc = load_path(joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance",
                                 "classification", "fixtures",
                                 "wrt_default_omitted.esm"))
        @test ode_states(doc.models["ScalarWrtOmitted"]) == ["z"]
        @test ode_states(doc.models["ScalarWrtExplicit"]) == ["z"]
        @test ode_states(doc.models["ShapedWrtOmitted"]) == ["x"]
        @test ode_states(doc.models["ShapedWrtExplicit"]) == ["x"]
        # The complement: a SPATIAL `wrt` is still not a time derivative, so an
        # over-broad fix that treated every `D` as structural is caught here.
        @test isempty(ode_states(doc.models["SpatialControl"]))
        @test system_kind(doc.models["SpatialControl"]) == "pde"
    end

    @testset "scalar state" begin
        _wrt_agree(_WRT_SCALAR, "ScalarWrtOmitted", "ScalarWrtExplicit")
    end

    @testset "shaped state" begin
        _wrt_agree(_WRT_SHAPED_OMITTED, "ShapedWrtOmitted", "ShapedWrtExplicit";
                   fb=_WRT_SHAPED_EXPLICIT)
    end

    @testset "display applies the same default" begin
        omitted = OpExpr("D", ASTExpr[VarExpr("x")])
        explicit = OpExpr("D", ASTExpr[VarExpr("x")]; wrt="t")
        @test to_unicode(omitted) == "∂x/∂t"
        @test to_unicode(omitted) == to_unicode(explicit)
        @test to_latex(omitted) == to_latex(explicit)
        @test to_ascii(omitted) == to_ascii(explicit)
    end
end
