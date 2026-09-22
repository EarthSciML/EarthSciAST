# Differential oracle for the expression-template expansion memo (perf plan A4,
# src/lower_expression_templates.jl `_expand_expr_refs`): build the SAME
# template-reference model three ways and require identical state maps /
# initial states and BIT-identical du.
#
# The memo makes two structurally-identical `apply_expression_template` sites
# reuse ONE expanded subtree instead of re-running serialize → substitute →
# re-parse → recurse. Returning a shared object turns the expanded equation set
# into the same DAG A1 interning collapses it to, so the tier that consumes the
# `sites` recording (`haskey` boundary checks) and the lockstep site translator
# (DAG-safe `seen` guard) are unaffected.
#
# The memo is memoization, not a choice of evaluator, so it has no `compiler`
# value and no environment switch: what it is compared against are the two
# other routes to the same program, both ordinary API calls —
# `expand_flattened_refs(flat)` (the Option-A image, expanded before the build
# sees it) and `expand_flattened_refs(flat; memo = nothing)` (the same image
# built by per-site re-expansion, no sharing anywhere). The three must agree bit
# for bit, under `:native` and under `:interpreter`.

using Test
using EarthSciAST
using EarthSciAST: load_path, flatten, build_evaluator, expand_flattened_refs

include("testutils.jl")
const ESM = EarthSciAST

@testset "expansion memo differential oracle (A4)" begin
    bench(parts...) = joinpath(TESTUTILS_REPO_ROOT, "tests", "bench", parts...)
    probe_states(n) = (
        Float64[sin(0.1 * i) + 1.5 for i in 1:n],
        Float64[0.5 + 0.01 * i + cos(0.3 * i)^2 for i in 1:n],
        Float64[1.5 + 0.25 * sin(0.7 * i) * cos(0.05 * i) for i in 1:n],
    )

    # Build a flattened system and return (du probes, u0, var_map).
    function probe(flat; compiler = :native)
        f, u0, p, _, vmap = EarthSciAST._build_evaluator(flat; compiler = compiler)
        dus = Vector{Float64}[]
        for (ti, u) in zip((0.0, 0.7, 3.25), probe_states(length(u0)))
            du = similar(u0)
            f(du, u, p, ti)
            push!(dus, copy(du))
        end
        return (dus, u0, vmap)
    end

    # The three routes to one program: references surviving into the build (the
    # memo runs there, with site recording), the Option-A image expanded up
    # front, and that image built by per-site re-expansion.
    function memo_oracle(fix; nstates = nothing, compiler = :native)
        flat = flatten(load_path(fix))
        on     = probe(flat; compiler = compiler)
        atload = probe(expand_flattened_refs(flat); compiler = compiler)
        nomemo = probe(expand_flattened_refs(flat; memo = nothing);
                       compiler = compiler)
        for other in (atload, nomemo)
            @test on[3] == other[3]                 # identical state map
            @test on[2] == other[2]                 # identical u0 (bitwise Float64 ==)
            for k in eachindex(on[1])
                @test on[1][k] == other[1][k]       # BIT-identical du
            end
        end
        @test any(du -> sum(abs, du) > 0, on[1])    # and not trivially zero
        nstates === nothing || @test length(on[2]) == nstates
        return on
    end

    @testset "compile-once fixture: the three routes agree" begin
        FIX = bench("transport_3axis_7cubed_fullrank.esm")
        on = memo_oracle(FIX)                                # default affine path
        # The memo runs at the expansion boundary, before any tier choice, so
        # the comparison holds under the interpreter too — and the interpreter's
        # own du must match the compiled one.
        onpc = memo_oracle(FIX; compiler = :interpreter)
        for k in 1:3
            @test on[1][k] == onpc[1][k]
        end
        @test length(on[2]) == 343
    end

    @testset "one-sided-face fixture: the three routes agree" begin
        memo_oracle(bench("transport_3axis_7cubed.esm"))
    end
end
