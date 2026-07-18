# Compile-once template tier (RFC out-of-line-expression-templates §5/§7.7
# "compile references natively", esm-spec §9.6.4 Option B): the affine stencil
# build compiles each surviving `apply_expression_template` body once per
# (use site, region class) and calls it as a runtime sub-kernel, instead of
# fusing the expanded body into every branch spine. Gate 3 (§12): the result
# MUST be bit-identical to the fused expanded build; `ESS_TEMPLATE_REF_DISABLE`
# (expand at load) and `ESS_TEMPLATE_COMPILE_ONCE_DISABLE` (expand at the build
# boundary) are the escape hatches, `ESS_STENCIL_DISABLE` forces the per-cell
# reference. Drives tests/bench/transport_3axis_7cubed_fullrank.esm (the
# 5×5×5-cross-product fixture the tier collapses to 5+5+5) plus inline
# mini-fixtures for nested references and the missing-registry guard.

using Test
using JSON3
using EarthSciAST
using EarthSciAST: load, flatten, build_evaluator, coerce_esm_file, TreeWalkError,
    _BENCH_ON, _BENCH_BODY_VARIANTS, _BENCH_BRANCH_TEMPLATES, _BENCH_COMPILE_CALLS,
    _bench_reset!

include("testutils.jl")  # TESTUTILS_REPO_ROOT (also lets this file run standalone)

@testset "compile-once template tier" begin
    bench(parts...) = joinpath(TESTUTILS_REPO_ROOT, "tests", "bench", parts...)

    # Deterministic non-trivial state + a couple of (u, t) probes.
    probe_states(n) = (
        Float64[sin(0.1 * i) + 1.5 for i in 1:n],
        Float64[0.5 + 0.01 * i + cos(0.3 * i)^2 for i in 1:n],
        Float64[1.5 + 0.25 * sin(0.7 * i) * cos(0.05 * i) for i in 1:n],
    )

    # Build under an env overlay and return (du values at the probes, u0, counters).
    function build_and_probe(fix::AbstractString; env=(), expand_at_flatten::Bool=false,
                             form::Symbol=:inplace)
        withenv(env...) do
            flat = flatten(load(fix); expand_refs=expand_at_flatten)
            _BENCH_ON[] = true
            _bench_reset!()
            f, u0, p, _, _ = build_evaluator(flat; form=form)
            counters = (branches=_BENCH_BRANCH_TEMPLATES[],
                        variants=_BENCH_BODY_VARIANTS[],
                        compiles=_BENCH_COMPILE_CALLS[])
            _BENCH_ON[] = false
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
            (dus, u0, counters)
        end
    end

    @testset "gate 3: bit-identity on the full-rank cross-product fixture" begin
        FIX = bench("transport_3axis_7cubed_fullrank.esm")

        fast, u0, cfast = build_and_probe(FIX)
        fused, _, cfused = build_and_probe(FIX; expand_at_flatten=true)
        boundary, _, _ = build_and_probe(FIX; env=(("ESS_TEMPLATE_COMPILE_ONCE_DISABLE" => "1"),))
        atload, _, _ = build_and_probe(FIX; env=(("ESS_TEMPLATE_REF_DISABLE" => "1"),))
        percell, _, _ = build_and_probe(FIX; env=(("ESS_STENCIL_DISABLE" => "1"),))
        oop, _, _ = build_and_probe(FIX; form=:oop)

        @test length(u0) == 343
        for k in 1:3
            # The fast path vs the fused affine build, the boundary-expanded
            # build, the Expand-at-load build, the per-cell reference, and the
            # out-of-place emitter: all EXACTLY equal (Float64 ==, no tolerance).
            @test fast[k] == fused[k]
            @test fast[k] == boundary[k]
            @test fast[k] == atload[k]
            @test fast[k] == percell[k]
            @test fast[k] == oop[k]
            @test sum(abs, fast[k]) > 0     # and not trivially zero
        end

        # 5+5+5 replaces 5×5×5: fifteen compiled body variants, and the total
        # node-lowering count collapses (parents are tiny sub-call spines).
        @test cfast.variants == 15
        @test cfused.variants == 0
        @test cfast.compiles < cfused.compiles ÷ 4
    end

    @testset "reduced-rank fixture: per-cell fallback stays bit-identical" begin
        # transport_3axis_7cubed.esm's one-sided faces are RANK-2 aggregates in a
        # 3-D makearray — the affine and symbolic paths decline it (pre-existing
        # "reduced-rank region value" fallback), so this pins the retry chain:
        # ref-aware attempt → fused retry → symbolic → per-cell, all sound.
        FIX = bench("transport_3axis_7cubed.esm")
        fast, u0, _ = build_and_probe(FIX)
        fused, _, _ = build_and_probe(FIX; expand_at_flatten=true)
        for k in 1:3
            @test fast[k] == fused[k]
            @test sum(abs, fast[k]) > 0
        end
        @test length(u0) == 343
    end

    @testset "nested reference + invariant subtree" begin
        # A 1-D transport whose interior body carries (a) a scalar-position
        # NESTED reference (pair_diff — compiled FUSED into its enclosing
        # variant: boundaries are the OUTERMOST expansion roots only, the RFC's
        # granularity) and (b) an all-literal invariant subtree exp(neg(0.3))
        # (exercises the sub-kernel invariant CSE tier filled by the runner
        # prologue).
        idx(f, off) = off == 0 ? Dict("op" => "index", "args" => [f, "i"]) :
            Dict("op" => "index", "args" => [f,
                Dict("op" => (off > 0 ? "+" : "-"), "args" => ["i", abs(off)])])
        pin(f, at) = Dict("op" => "index", "args" => [f, at])
        doc = Dict(
            "esm" => "0.9.0",
            "metadata" => Dict("name" => "nested_1d"),
            "index_sets" => Dict("x" => Dict("kind" => "interval", "size" => 8)),
            "models" => Dict("T" => Dict(
                "expression_templates" => Dict(
                    "pair_diff" => Dict(
                        "params" => ["f", "w"],
                        "body" => Dict("op" => "*", "args" => ["w",
                            Dict("op" => "-", "args" => [idx("f", 1), idx("f", -1)])]),
                    ),
                    "flux_int" => Dict(
                        "params" => ["f"],
                        "body" => Dict("op" => "aggregate", "output_idx" => ["i"],
                            "args" => ["f"], "ranges" => Dict("i" => [2, 7]),
                            "expr" => Dict("op" => "*", "args" => [
                                Dict("op" => "exp", "args" => [
                                    Dict("op" => "neg", "args" => [0.3])]),
                                Dict("op" => "apply_expression_template", "args" => [],
                                     "name" => "pair_diff",
                                     "bindings" => Dict("f" => "f", "w" => 0.25))])),
                    ),
                    "flux_lo" => Dict(
                        "params" => ["f"],
                        "body" => Dict("op" => "aggregate", "output_idx" => ["i"],
                            "args" => ["f"], "ranges" => Dict("i" => [1, 1]),
                            "expr" => Dict("op" => "-", "args" => [pin("f", 2), pin("f", 1)])),
                    ),
                    "flux_hi" => Dict(
                        "params" => ["f"],
                        "body" => Dict("op" => "aggregate", "output_idx" => ["i"],
                            "args" => ["f"], "ranges" => Dict("i" => [8, 8]),
                            "expr" => Dict("op" => "-", "args" => [pin("f", 8), pin("f", 7)])),
                    ),
                    "Dx1" => Dict(
                        "params" => ["f"],
                        "match" => Dict("op" => "D", "args" => ["f"], "wrt" => "x"),
                        "body" => Dict("op" => "makearray", "args" => [],
                            "regions" => [[[2, 7]], [[1, 1]], [[8, 8]]],
                            "values" => [
                                Dict("op" => "apply_expression_template", "args" => [],
                                     "name" => "flux_int", "bindings" => Dict("f" => "f")),
                                Dict("op" => "apply_expression_template", "args" => [],
                                     "name" => "flux_lo", "bindings" => Dict("f" => "f")),
                                Dict("op" => "apply_expression_template", "args" => [],
                                     "name" => "flux_hi", "bindings" => Dict("f" => "f")),
                            ]),
                    ),
                ),
                "variables" => Dict(
                    "q" => Dict("type" => "state", "units" => "1",
                                "shape" => ["x"], "default" => 1.5)),
                "equations" => [Dict(
                    "lhs" => Dict("op" => "D", "args" => ["q"], "wrt" => "t"),
                    "rhs" => Dict("op" => "-", "args" => [
                        Dict("op" => "D", "args" => ["q"], "wrt" => "x")]))],
            )),
        )
        mktempdir() do dir
            fix = joinpath(dir, "nested_1d.esm")
            open(fix, "w") do io
                JSON3.write(io, doc)
            end
            fast, u0, cfast = build_and_probe(fix)
            fused, _, _ = build_and_probe(fix; expand_at_flatten=true)
            @test length(u0) == 8
            for k in 1:3
                @test fast[k] == fused[k]
                @test sum(abs, fast[k]) > 0
            end
            # ONE variant: flux_int, with the nested pair_diff fused into it
            # (outermost-boundary granularity — per-nested-root variants
            # exploded 8,297 tiny bodies on the ESD PPM stack). flux_lo /
            # flux_hi bodies gather only PINNED cells (no loop index), so they
            # are loop-invariant subtrees — hoisted whole into the parent spine
            # (strictly better than a sub-kernel), exactly as the fused walk
            # treats them.
            @test cfast.variants == 1
        end
    end

    @testset "surviving reference with no registry fails at build time" begin
        # A model carrying an apply node whose document has NO
        # expression_templates block: the guard must fail the BUILD with a clear
        # code, not poison a kernel that only fails at RHS evaluation time.
        doc = Dict(
            "esm" => "0.9.0",
            "metadata" => Dict("name" => "orphan_ref"),
            "models" => Dict("T" => Dict(
                "variables" => Dict(
                    "a" => Dict("type" => "state", "units" => "1", "default" => 1.5)),
                "equations" => [Dict(
                    "lhs" => Dict("op" => "D", "args" => ["a"], "wrt" => "t"),
                    "rhs" => Dict("op" => "apply_expression_template", "args" => [],
                                  "name" => "ghost", "bindings" => Dict()))],
            )),
        )
        file = coerce_esm_file(JSON3.read(JSON3.write(doc)))
        err = try
            build_evaluator(file)
            nothing
        catch e
            e
        end
        @test err isa TreeWalkError
        @test err.code == "E_TREEWALK_UNRESOLVED_TEMPLATE_REF"
    end

    @testset "reaction-rate template + param_to_var (regression: unbound P/T)" begin
        # A reaction-system rate written as an `apply_expression_template` whose
        # body references the system's OWN scalar parameter (`T`), with that param
        # driven by a `param_to_var` coupling from another component's observed.
        # This is exactly the SuperFast + gridded-Tc/Pc shape that broke the 3-D
        # chemistry build (`E_TREEWALK_UNBOUND_VARIABLE: P`): under the
        # reference-preserving path the coupling substituted `Chem.T` in the
        # equations while the template body's `T` was still hidden in the registry,
        # and a later expansion surfaced a bare, unbound `T`. Reaction-system rate
        # templates are now expanded EAGERLY during reaction lowering (before
        # namespacing), so `T -> Chem.T -> Src.Tsrc` like a bare-in-rate param.
        # (probe7 missed this because its toy rate used a BARE param, not a
        # templated one.)
        doc = Dict(
            "esm" => "0.9.0",
            "metadata" => Dict("name" => "rtmpl_param_to_var"),
            "reaction_systems" => Dict("Chem" => Dict(
                "parameters" => Dict(
                    "k" => Dict("units" => "1/s", "default" => 1.0),
                    "T" => Dict("units" => "K", "default" => 300.0)),
                "species" => Dict(
                    "A" => Dict("units" => "1", "default" => 1.0),
                    "B" => Dict("units" => "1", "default" => 0.0)),
                "expression_templates" => Dict("krate" => Dict(
                    "params" => ["kk"],
                    # kk * (T / 300): kk is the template param (bound to Chem.k),
                    # T is the reaction system's own free scalar param.
                    "body" => Dict("op" => "*", "args" => ["kk",
                        Dict("op" => "/", "args" => ["T", 300.0])]))),
                "reactions" => [Dict(
                    "id" => "R1",
                    "substrates" => [Dict("stoichiometry" => 1, "species" => "A")],
                    "products" => [Dict("stoichiometry" => 1, "species" => "B")],
                    "rate" => Dict("op" => "apply_expression_template", "args" => [],
                                   "name" => "krate", "bindings" => Dict("kk" => "k")))],
            )),
            "models" => Dict("Src" => Dict(
                "variables" => Dict("Tsrc" => Dict(
                    "type" => "observed", "units" => "K",
                    "expression" => Dict("op" => "+", "args" => [290.0, 10.0]))),
                "equations" => Any[])),
            "coupling" => [Dict("type" => "variable_map",
                                "from" => "Src.Tsrc", "to" => "Chem.T",
                                "transform" => "param_to_var")],
        )
        mktempdir() do dir
            fix = joinpath(dir, "rtmpl_param_to_var.esm")
            open(fix, "w") do io
                JSON3.write(io, doc)
            end
            # The reference-preserving build (default) and the expand-at-load build
            # must BOTH succeed and agree bit-for-bit. Before the fix the default
            # build threw E_TREEWALK_UNBOUND_VARIABLE: T.
            refbuild, u0, _ = build_and_probe(fix)
            atload, _, _ = build_and_probe(fix; env=(("ESS_TEMPLATE_REF_DISABLE" => "1"),))
            @test length(u0) == 2                       # Chem.A, Chem.B (0-D)
            for k in 1:3
                @test refbuild[k] == atload[k]
                @test all(isfinite, refbuild[k])
            end
        end
    end
end
