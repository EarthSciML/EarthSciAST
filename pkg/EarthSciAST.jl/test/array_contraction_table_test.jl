# The whole-array contraction nest's general form (array_contraction.jl,
# `_ACTable`; build.jl `_try_compile_array_contraction`): the contractions that
# otherwise took the per-cell build — one resolve and compile per output cell.
#
#   * a JOIN-GATED contraction and a RAGGED (per-cell bound) one compile to ONE
#     symbolic term plus data: each output cell's admitted contracted tuples, in
#     the per-cell expansion's order, as a table the emitted fold walks;
#   * a FILTER is the expansion's `ifelse(filter, term, 0̄)` guard, kept symbolic;
#   * a join-gated producer behind a materialized observed (a regrid's apply
#     step) is unwrapped onto that path too.
#
# Each is BIT-IDENTICAL (`===`) to `compiler=:interpreter`, which turns the nest
# off and expands every cell, and none of them reaches the per-cell build.

using Test
using ForwardDiff
using JSON3
include("testutils.jl")

const _ACT = EarthSciAST
const _ACT_REPO = normpath(joinpath(@__DIR__, "..", "..", ".."))

function _act_problem(path, compiler)
    _ACT._reset_cascade_tally!()
    prob = _ACT.esm_problem(path, (0.0, 1.0); compiler=compiler)
    return prob, copy(_ACT._CASCADE_TALLY)
end

function _act_du(prob, u)
    du = similar(u)
    fill!(du, NaN)
    prob.f!(du, u, prob.p, 0.3)
    du
end

# du under native and the interpreter, at a state perturbed off the initial one
# (no exact zeros), matched by state name.
function _act_agree(path)
    pn, tally = _act_problem(path, :native)
    pi_, _ = _act_problem(path, :interpreter)
    u = Float64[pn.u0[i] + 0.41 + 0.017 * sin(1.3i) for i in eachindex(pn.u0)]
    ui = similar(pi_.u0)
    for (k, j) in pi_.var_map
        ui[j] = u[pn.var_map[k]]
    end
    dn = _act_du(pn, u)
    di = _act_du(pi_, ui)
    same = all(dn[pn.var_map[k]] === di[j] for (k, j) in pi_.var_map)
    tiers = Dict(_ACT.tier_histogram(_ACT.compiler_report(pn)))
    return same, tally, tiers, (pn, u), (pi_, ui)
end

_act_fixture(rel) = joinpath(_ACT_REPO, rel)

# Expression nodes of every distinct generated function reachable from `root`
# (the scaling tier's code-size measure, less the walked trees).
function _act_emitted(root)
    RGF = _ACT.RuntimeGeneratedFunctions
    sz(e) = e isa Expr ? 1 + sum(sz, e.args; init=0) : 1
    seen = IdDict{Any,Nothing}(); ids = Set{Any}(); total = 0
    stack = Any[root]
    while !isempty(stack)
        x = pop!(stack)
        T = typeof(x)
        (isbitstype(T) || x isa AbstractString || x isa Symbol || x isa Module) && continue
        if ismutable(x)
            haskey(seen, x) && continue
            seen[x] = nothing
        end
        if x isa RGF.RuntimeGeneratedFunction
            id = T.parameters[4]
            id in ids || (push!(ids, id); total += sz(RGF.get_expression(x)))
            continue
        end
        if x isa Array
            eltype(x) <: Number && continue
            for i in eachindex(x); isassigned(x, i) && push!(stack, x[i]); end
        elseif x isa AbstractDict
            continue
        else
            for i in 1:nfields(x); isdefined(x, i) && push!(stack, getfield(x, i)); end
        end
    end
    return total
end

@testset "whole-array contraction nest: gated, ragged and filtered" begin

    @testset "$(basename(rel))" for rel in (
            "tests/valid/faq/join_moves_running_exhaust.esm",   # join gate
            "tests/valid/faq/ragged_member_gather.esm",         # ragged bound
            "tests/valid/geometry/conservative_regrid_assembly.esm")  # join + filter
        same, tally, tiers, _, _ = _act_agree(_act_fixture(rel))
        @test same
        @test get(tally, :array_contraction_codegen, 0) >= 1
        @test get(tally, :percell_acc, 0) == 0
        @test !haskey(tiers, :percell_build)
    end

    @testset "a materialized observed over a join-gated producer" begin
        # The scaling tier's regrid: F_rg[j] = Σ_i W[i,j]·F_src[i] over the
        # bin-join candidates, with F_src a state, read by D(F_tgt).
        path = _act_fixture("tests/conformance/scaling/fixtures/regrid/regrid_N100.esm")
        same, tally, tiers, (pn, u), (pi_, ui) = _act_agree(path)
        @test same
        @test get(tally, :percell_acc, 0) == 0
        @test !haskey(tiers, :percell_build)
        du = similar(u)
        pn.f!(du, u, pn.p, 0.0)
        @test (@allocated pn.f!(du, u, pn.p, 0.0)) == 0
        seed = Float64[0.2 + 0.01 * cos(i) for i in eachindex(u)]
        seedi = similar(seed)
        for (k, j) in pi_.var_map
            seedi[j] = seed[pn.var_map[k]]
        end
        gn = ForwardDiff.derivative(s -> _act_du(pn, u .+ s .* seed), 0.0)
        gi = ForwardDiff.derivative(s -> _act_du(pi_, ui .+ s .* seedi), 0.0)
        @test all(gn[pn.var_map[k]] == gi[j] for (k, j) in pi_.var_map)
    end

    @testset "two contracted indices fold into one accumulator" begin
        # Non-integer data, so the association of the fold shows in the last
        # bit: the expansion's fold is ((0̄ ⊕ t₁₁) ⊕ t₂₁) ⊕ …, one accumulator
        # over the whole (k, l) product, never a sum of per-l partial folds.
        # The inline `const` keeps the affine tier out, so the nest takes it.
        n, m1, m2 = 5, 7, 6
        w(i, k, l) = (0.001 * (1 + sin(0.7i * k + 0.3)) + 0.25 / (i + k)) * (1 + 0.1l)
        W = [[[w(i, k, l) for l in 1:m2] for k in 1:m1] for i in 1:n]
        idx(v, a...) = Dict("op" => "index", "args" => Any[v, a...])
        op(o, a...) = Dict("op" => o, "args" => Any[a...])
        body = op("*", idx(Dict("op" => "const", "args" => Any[], "value" => W), "i", "k", "l"),
                  op("+", idx("e", "k"), op("*", 0.5, idx("g", "l"))))
        dlhs(v, i, n) = Dict("op" => "faq", "args" => Any[], "output_idx" => Any[i],
            "ranges" => Dict(i => Any[1, n]),
            "expr" => Dict("op" => "D", "args" => Any[idx(v, i)], "wrt" => "t"))
        decay(v, i, n) = Dict("op" => "faq", "args" => Any[], "output_idx" => Any[i],
            "ranges" => Dict(i => Any[1, n]), "expr" => op("*", -0.2, idx(v, i)))
        doc = Dict{String,Any}("esm" => "1.1.0", "metadata" => Dict("name" => "act_two"),
            "models" => Dict("M" => Dict{String,Any}(
                "variables" => Dict(
                    "y" => Dict("type" => "unknown", "shape" => Any["i"]),
                    "e" => Dict("type" => "unknown", "shape" => Any["k"]),
                    "g" => Dict("type" => "unknown", "shape" => Any["l"])),
                "equations" => Any[
                    Dict("lhs" => dlhs("e", "k", m1), "rhs" => decay("e", "k", m1)),
                    Dict("lhs" => dlhs("g", "l", m2), "rhs" => decay("g", "l", m2)),
                    Dict("lhs" => dlhs("y", "i", n),
                         "rhs" => Dict("op" => "faq", "args" => Any[], "reduce" => "+",
                             "output_idx" => Any["i"],
                             "ranges" => Dict("i" => Any[1, n], "k" => Any[1, m1],
                                              "l" => Any[1, m2]),
                             "expr" => body))])))
        path = joinpath(mktempdir(), "act_two.esm")
        open(io -> JSON3.write(io, doc), path, "w")
        same, tally, tiers, _, _ = _act_agree(path)
        @test same
        @test get(tally, :array_contraction_codegen, 0) == 1
        @test !haskey(tiers, :percell_build)
    end

    @testset "the table holds the admitted tuples, not code" begin
        # The same ragged document at two member counts: the emitted nest is
        # the same size, and each cell's entries are its own members, in order.
        mk(sizes) = begin
            n = length(sizes)
            mx = maximum(sizes)
            members = [vcat(collect(sum(sizes[1:i-1]; init=0) .+ (1:sizes[i])),
                            zeros(Int, mx - sizes[i])) for i in 1:n]
            flat = [10.0 + 0.5k + 0.01k^2 for k in 1:sum(sizes)]
            Dict{String,Any}("esm" => "1.1.0", "metadata" => Dict("name" => "act_ragged"),
                "index_sets" => Dict(
                    "parents" => Dict("kind" => "interval", "size" => n),
                    "maxm" => Dict("kind" => "interval", "size" => mx),
                    "flat" => Dict("kind" => "interval", "size" => sum(sizes)),
                    "mop" => Dict("kind" => "ragged", "of" => Any["parents"],
                                  "offsets" => "cnt", "values" => "mem")),
                "models" => Dict("M" => Dict{String,Any}(
                    "variables" => Dict(
                        "cnt" => Dict("type" => "unknown", "shape" => Any["parents"]),
                        "mem" => Dict("type" => "unknown", "shape" => Any["parents", "maxm"]),
                        "x" => Dict("type" => "unknown", "shape" => Any["flat"]),
                        "tot" => Dict("type" => "unknown", "shape" => Any["parents"])),
                    "equations" => Any[
                        Dict("lhs" => "cnt", "rhs" => Dict("op" => "const", "args" => Any[],
                                                            "value" => sizes)),
                        Dict("lhs" => "mem", "rhs" => Dict("op" => "const", "args" => Any[],
                                                            "value" => members)),
                        Dict("lhs" => Dict("op" => "faq", "args" => Any[],
                                 "output_idx" => Any["k"], "ranges" => Dict("k" => Dict("from" => "flat")),
                                 "expr" => Dict("op" => "D", "args" => Any[
                                     Dict("op" => "index", "args" => Any["x", "k"])], "wrt" => "t")),
                             "rhs" => Dict("op" => "faq", "args" => Any[],
                                 "output_idx" => Any["k"], "ranges" => Dict("k" => Dict("from" => "flat")),
                                 "expr" => Dict("op" => "*", "args" => Any[-0.1,
                                     Dict("op" => "index", "args" => Any["x", "k"])]))),
                        Dict("lhs" => Dict("op" => "faq", "args" => Any[],
                                 "output_idx" => Any["i"], "ranges" => Dict("i" => Dict("from" => "parents")),
                                 "expr" => Dict("op" => "D", "args" => Any[
                                     Dict("op" => "index", "args" => Any["tot", "i"])], "wrt" => "t")),
                             "rhs" => Dict("op" => "faq", "args" => Any[], "semiring" => "sum_product",
                                 "output_idx" => Any["i"],
                                 "ranges" => Dict("i" => Dict("from" => "parents"),
                                                  "j" => Dict("from" => "mop", "of" => Any["i"])),
                                 "expr" => Dict("op" => "*", "args" => Any[
                                     Dict("op" => "index", "args" => Any["x",
                                         Dict("op" => "index", "args" => Any["mem", "i", "j"])]),
                                     Dict("op" => "+", "args" => Any["j", 0.5])])))])))
        end
        nodes = Int[]
        for sizes in ([1, 3, 2, 0, 4], [2, 1, 5, 3, 0, 1, 6, 2])
            doc = mk(sizes)
            path = joinpath(mktempdir(), "act_ragged.esm")
            open(io -> JSON3.write(io, doc), path, "w")
            same, tally, tiers, (pn, _), _ = _act_agree(path)
            @test same
            @test get(tally, :array_contraction_codegen, 0) == 1
            @test !haskey(tiers, :percell_build)
            push!(nodes, _act_emitted(pn.f!))
        end
        @test allequal(nodes)
    end
end
