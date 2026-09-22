# Cross-language conformance for a data-fed parameter nothing bound
# (esm-spec §9.6.6 `data_source_unbound`, CONFORMANCE_SPEC §5.46).
#
# Drives the shared manifest at `tests/conformance/data_source_unbound/`.
#
# This binding is the one that produced a NUMBER. The tree-walk build bound a
# data-fed parameter from its `default` and integrated it, so
# `unbound_scalar_forcing.esm` — whose decay rate the document says is read from
# the `Wind` source — reported x(1) = 0.9048374180359661 as a PASSING inline
# assertion, computed from the placeholder 0.1, with nothing in the result
# recording that `Wind` was never opened. The shaped fixture, which has no
# `default` to fall back on, refused instead — but as the Julia-local
# `E_TREEWALK_UNSUPPORTED_SHAPE`, naming no registered code.

using Test
using EarthSciAST
using JSON3
using OrdinaryDiffEqTsit5   # the inline-test surface needs an ODE algorithm

include("testutils.jl")  # TESTUTILS_REPO_ROOT

const _DSU_DIR = joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance",
                          "data_source_unbound")

@assert isfile(joinpath(_DSU_DIR, "manifest.json")) "manifest not found in $(_DSU_DIR)"
const _DSU_MANIFEST = JSON3.read(read(joinpath(_DSU_DIR, "manifest.json"), String))

# The code an exception reports, whatever layer raised it: a build refusal
# carries it on `.code`, and reading the message text instead would let this
# tier pass on a coincidence of wording.
_dsu_code(e) = hasproperty(e, :code) ? String(e.code) : ""

@testset "conformance: data_source_unbound (esm-spec §9.6.6)" begin
    @test _DSU_MANIFEST.code == EarthSciAST.ERROR_CODES.DATA_SOURCE_UNBOUND
    @test "data_source_unbound" in EarthSciAST.error_code_names()
    @test any(c -> c.expect == "run", _DSU_MANIFEST.cases)
    @test any(c -> c.expect == "refuse", _DSU_MANIFEST.cases)

    for case in _DSU_MANIFEST.cases
        path = joinpath(_DSU_DIR, String(case.path))
        @testset "$(case.id)" begin
            if case.expect == "refuse"
                accepts = String.(case.accepts)
                # The heart of the category: the SAME refusal under BOTH
                # compilers. A binding whose two compilers disagree here is
                # reporting a compiler property where the question is about the
                # document.
                for compiler in (:native, :interpreter)
                    err = try
                        esm_problem(path, (0.0, 1.0); compiler=compiler)
                        nothing
                    catch e
                        e
                    end
                    @test err !== nothing
                    @test err !== nothing && _dsu_code(err) in accepts
                    if err !== nothing && _dsu_code(err) == "data_source_unbound"
                        @test occursin(String(case.parameter), err.detail)
                        @test occursin(String(case.source), err.detail)
                    end
                end

                # And an inline test reports the refusal, not a number.
                results = run_inline_tests(path; alg=Tsit5())
                @test !isempty(results)
                for r in results
                    @test r.passed == false
                    @test r.actual === nothing
                    @test any(c -> occursin(c, r.message), accepts)
                end
            else
                # Both controls go through the inline-test runner, which is
                # where the pin control's `parameter_overrides` lives and which
                # is the surface a document author uses.
                results = run_inline_tests(path; alg=Tsit5())
                @test !isempty(results)
                @test all(r -> r.passed, results)
            end
        end
    end

    # A `p` value BINDS the parameter, and the pinned value reaches the
    # right-hand side. The second half is what matters: a build that merely
    # stopped refusing and then integrated the `default` would pass a refusal
    # test and defeat its purpose. 0.5 is the pin, 0.1 the document's default,
    # so exp(-0.5) = 0.6065… and exp(-0.1) = 0.9048… tell them apart outright.
    @testset "a pinned forcing binds the parameter" begin
        path = joinpath(_DSU_DIR, "fixtures", "unbound_scalar_forcing.esm")
        for compiler in (:native, :interpreter)
            prob = esm_problem(path, (0.0, 1.0);
                               compiler=compiler, p=Dict("Forcing.k" => 0.5))
            sol = solve(prob, Tsit5(); saveat=[0.0, 1.0])
            @test isapprox(sol.u[end][1], exp(-0.5); rtol=1e-4)
        end
    end
end
