# Differential oracle for the expression-template expansion memo (perf plan A4,
# src/lower_expression_templates.jl `_expand_expr_refs`): build the SAME
# template-reference model with the memo ON (the default) and OFF
# (ESS_EXPAND_MEMO_DISABLE=1, byte-for-byte the per-site re-expansion) and
# require identical state maps / initial states and BIT-identical du.
#
# The memo makes two structurally-identical `apply_expression_template` sites
# reuse ONE expanded subtree instead of re-running serialize → substitute →
# re-parse → recurse. Returning a shared object turns the expanded equation set
# into the same DAG A1 interning collapses it to, so the tier that consumes the
# `sites` recording (`haskey` boundary checks) and the lockstep site translator
# (DAG-safe `seen` guard) are unaffected. This pins that byte-for-byte on the
# compile-once fixture (which carries the surviving refs the memo acts on),
# under the per-cell reference (ESS_STENCIL_DISABLE=1), and the :oop emitter,
# and cross-checks against the Expand-at-load path (ESS_TEMPLATE_REF_DISABLE=1),
# which never builds the memo at all.

using Test
using EarthSciAST
using EarthSciAST: load, flatten, build_evaluator

include("testutils.jl")
const ESM = EarthSciAST

@testset "expansion memo differential oracle (A4)" begin
    bench(parts...) = joinpath(TESTUTILS_REPO_ROOT, "tests", "bench", parts...)
    probe_states(n) = (
        Float64[sin(0.1 * i) + 1.5 for i in 1:n],
        Float64[0.5 + 0.01 * i + cos(0.3 * i)^2 for i in 1:n],
        Float64[1.5 + 0.25 * sin(0.7 * i) * cos(0.05 * i) for i in 1:n],
    )

    # Build `fix` under an env overlay (wrapping LOAD too, so the load-time
    # Expand-at-load hatch takes effect) and return (du probes, u0, var_map).
    function build_and_probe(fix::AbstractString; env=(), form::Symbol=:inplace)
        withenv(env...) do
            flat = flatten(load(fix))
            f, u0, p, _, vmap = build_evaluator(flat; form=form)
            dus = Vector{Float64}[]
            for (ti, u) in zip((0.0, 0.7, 3.25), probe_states(length(u0)))
                if form === :oop
                    push!(dus, Vector{Float64}(f(u, p, ti)))
                else
                    du = similar(u0)
                    f(du, u, p, ti)
                    push!(dus, copy(du))
                end
            end
            (dus, u0, vmap)
        end
    end

    function memo_oracle(fix; form=:inplace, nstates=nothing)
        on  = build_and_probe(fix; env=(("ESS_EXPAND_MEMO_DISABLE" => nothing),), form=form)
        off = build_and_probe(fix; env=(("ESS_EXPAND_MEMO_DISABLE" => "1"),),  form=form)
        @test on[3] == off[3]                       # identical state map
        @test on[2] == off[2]                       # identical u0 (bitwise Float64 ==)
        for k in eachindex(on[1])
            @test on[1][k] == off[1][k]             # BIT-identical du
        end
        @test any(du -> sum(abs, du) > 0, on[1])    # and not trivially zero
        nstates === nothing || @test length(on[2]) == nstates
        return on
    end

    @testset "compile-once fixture: memo ON ≡ OFF (inplace / per-cell / oop)" begin
        FIX = bench("transport_3axis_7cubed_fullrank.esm")
        on = memo_oracle(FIX)                                     # default affine path
        memo_oracle(FIX; form=:oop)                              # out-of-place emitter
        # Per-cell reference: the memo runs at the same expansion boundary,
        # before any tier choice, so ESS_STENCIL_DISABLE composes with it.
        onpc  = build_and_probe(FIX; env=(("ESS_STENCIL_DISABLE" => "1"),))
        for k in 1:3
            @test on[1][k] == onpc[1][k]
        end
        @test length(on[2]) == 343
    end

    @testset "one-sided-face fixture: memo ON ≡ OFF" begin
        memo_oracle(bench("transport_3axis_7cubed.esm"))
    end

    @testset "memo ≡ Expand-at-load (ESS_TEMPLATE_REF_DISABLE, which skips the memo)" begin
        FIX = bench("transport_3axis_7cubed_fullrank.esm")
        fast   = build_and_probe(FIX)                                                  # memo path
        atload = build_and_probe(FIX; env=(("ESS_TEMPLATE_REF_DISABLE" => "1"),))     # no memo at all
        for k in 1:3
            @test fast[1][k] == atload[1][k]
        end
    end
end
