# The affine tier's run-time contraction fold (`_AffineReduce` /
# `_NK_AREDUCE`, stencil_affine.jl + access_kernel.jl + codegen_kernel.jl).
#
# A constant-bound contraction the affine tier used to UNROLL — one term per
# contracted index in every kernel body, so the emitted code and its first-call
# compile grew with the contraction length — is compiled with its contracted
# indices kept symbolic as extra loop dims of the box, and the kernel folds the
# body over them at run time. This pins:
#
#   * BIT-IDENTITY, `===` per element, against `compiler=:interpreter` (which
#     turns the affine tier off and unrolls each output cell's reduction), over
#     data with no exact zeros and no integers, so a fold-order difference shows
#     in the last bit: the four ⊕, a filter, two contracted indices (the first
#     varies fastest), and a contraction whose output is rank 3 (so the fold
#     binds a fourth loop dim);
#   * the emitted code is the same size at every contraction length;
#   * ForwardDiff through the fold;
#   * the unroll is still what a contraction the loop form declines gets (a
#     ghost along the contracted axis cuts it).

using Test
using ForwardDiff
include("testutils.jl")

const _AR = EarthSciAST

_ar_lhs(v, idxs, ranges) = Dict("op" => "faq", "args" => Any[], "output_idx" => Any[idxs...],
    "ranges" => Dict(k => Any[r...] for (k, r) in ranges),
    "expr" => Dict("op" => "D", "args" => Any[
        Dict("op" => "index", "args" => Any[v, idxs...])], "wrt" => "t"))
_ar_idx(v, a...) = Dict("op" => "index", "args" => Any[v, a...])
_ar_op(o, a...) = Dict("op" => o, "args" => Any[a...])

# D(y[i…]) = ⊕_{k…} body, with the source `e` a state decaying at a unit rate.
function _ar_doc(out_idx, out_ranges, cnames, cranges, body; red="+", filter=nothing,
                 evars=Dict{String,Any}())
    agg = Dict{String,Any}("op" => "faq", "args" => Any[], "output_idx" => Any[out_idx...],
        "ranges" => merge(Dict(k => Any[r...] for (k, r) in zip(out_idx, out_ranges)),
                          Dict(k => Any[r...] for (k, r) in zip(cnames, cranges))),
        "reduce" => red, "expr" => body)
    filter === nothing || (agg["filter"] = filter)
    vars = Dict{String,Any}("y" => Dict("type" => "unknown", "shape" => Any[out_idx...]))
    merge!(vars, evars)
    eqs = Any[Dict("lhs" => _ar_lhs("y", out_idx, zip(out_idx, out_ranges)), "rhs" => agg)]
    Dict{String,Any}("esm" => "1.1.0", "metadata" => Dict("name" => "ar"),
        "models" => Dict("R" => Dict{String,Any}("variables" => vars, "equations" => eqs)))
end

function _ar_build(doc, ics; compiler=:native)
    _AR._reset_cascade_tally!()
    f!, u0, p, _, vm = _AR._build_evaluator(doc; initial_conditions=ics, compiler=compiler)
    return f!, u0, p, vm, copy(_AR._CASCADE_TALLY)
end

# A perturbed state with no exact zeros and no integers.
_ar_u(u0) = Float64[u0[i] + 0.37 + 0.013 * sin(1.7i) for i in eachindex(u0)]

function _ar_du(f!, u, p)
    du = similar(u)
    fill!(du, NaN)
    f!(du, u, p, 0.25)
    du
end

# du under native and the interpreter, matched by state name.
function _ar_agree(doc, ics)
    fn, un, pn, vn, tally = _ar_build(doc, ics)
    fi, ui, pi_, vi, _ = _ar_build(doc, ics; compiler=:interpreter)
    u = _ar_u(un)
    ui2 = similar(ui)
    for (k, j) in vi
        ui2[j] = u[vn[k]]
    end
    dn = _ar_du(fn, u, pn)
    di = _ar_du(fi, ui2, pi_)
    same = all(dn[vn[k]] === di[j] for (k, j) in vi)
    return same, tally, (fn, u, pn, vn), (fi, ui2, pi_, vi)
end

_ar_emitted_nodes(f!) = begin
    ks = getfield(f!, :kernel_section)
    cgf = getfield(ks, :cgf)
    ex = _AR.RuntimeGeneratedFunctions.get_expression(cgf)
    sz(e) = e isa Expr ? 1 + sum(sz, e.args; init=0) : 1
    sz(ex)
end

# A dense, non-uniform, non-integer coefficient of the loop indices, written
# into the document (the scaling tier's source-receptor K is the same kind of
# thing): the kernel evaluates it from the loop indices at every term, so its
# reduction-dim reads are the loop-index leaf of the fold's bound dims.
_ar_w(i, k) = _ar_op("+",
    _ar_op("*", 0.001, _ar_op("+", 1, _ar_op("sin",
        _ar_op("+", _ar_op("*", 0.7, i, k), 0.3)))),
    _ar_op("/", 0.25, _ar_op("+", i, k)))

# The dense source-receptor shape: y[i] = Σ_k W(i,k)·e[k].
function _ar_sr_doc(n, m; red="+", filter=nothing, body=nothing)
    b = body === nothing ? _ar_op("*", _ar_w("i", "k"), _ar_idx("e", "k")) : body
    doc = _ar_doc(["i"], [(1, n)], ["k"], [(1, m)], b; red=red, filter=filter,
                  evars=Dict("e" => Dict("type" => "unknown", "shape" => Any["k"])))
    push!(doc["models"]["R"]["equations"], Dict(
        "lhs" => _ar_lhs("e", ["k"], [("k", (1, m))]),
        "rhs" => Dict("op" => "faq", "args" => Any[], "output_idx" => Any["k"],
                      "ranges" => Dict("k" => Any[1, m]),
                      "expr" => _ar_op("-", _ar_idx("e", "k")))))
    doc
end
_ar_sr_ics(n, m) = merge(Dict{String,Any}("y[$i]" => 0.1 * i for i in 1:n),
                         Dict{String,Any}("e[$k]" => 1.0 + 0.01 * k for k in 1:m))

@testset "affine run-time contraction fold" begin

    @testset "source-receptor ⊕=$red" for red in ("+", "*", "max", "min")
        same, tally, _, _ = _ar_agree(_ar_sr_doc(12, 40; red=red), _ar_sr_ics(12, 40))
        @test same
        @test get(tally, :affine_reduce, 0) >= 1
        @test get(tally, :array_contraction_codegen, 0) == 0
    end

    @testset "filter (the unroll's per-term ifelse guard)" begin
        filt = _ar_op(">", _ar_w("i", "k"), 0.02)
        same, tally, _, _ = _ar_agree(_ar_sr_doc(12, 40; filter=filt), _ar_sr_ics(12, 40))
        @test same
        @test get(tally, :affine_reduce, 0) >= 1
    end

    @testset "emitted code is flat in the contraction length" begin
        sizes = Int[]
        for m in (16, 64, 256)
            f!, _, _, _, tally = _ar_build(_ar_sr_doc(12, m), _ar_sr_ics(12, m))
            @test get(tally, :affine_reduce, 0) >= 1
            push!(sizes, _ar_emitted_nodes(f!))
        end
        @test allequal(sizes)
    end

    @testset "two contracted indices, the first fastest" begin
        n, m1, m2 = 5, 7, 6
        body = _ar_op("*", _ar_w("i", "k"), _ar_op("+", 1, _ar_op("*", 0.1, "l")),
                      _ar_op("+", _ar_idx("e", "k"), _ar_op("*", 0.5, _ar_idx("g", "l"))))
        doc = _ar_doc(["i"], [(1, n)], ["k", "l"], [(1, m1), (1, m2)], body;
                      evars=Dict("e" => Dict("type" => "unknown", "shape" => Any["k"]),
                                 "g" => Dict("type" => "unknown", "shape" => Any["l"])))
        ics = merge(Dict{String,Any}("y[$i]" => 0.0 for i in 1:n),
                    Dict{String,Any}("e[$k]" => 1.0 + 0.01k for k in 1:m1),
                    Dict{String,Any}("g[$l]" => 2.0 - 0.03l for l in 1:m2))
        same, tally, _, _ = _ar_agree(doc, ics)
        @test same
        @test get(tally, :affine_reduce, 0) >= 1
    end

    @testset "rank-3 output: the fold binds a fourth loop dim" begin
        ni, nj, nk, m = 3, 4, 2, 9
        body = _ar_op("*", _ar_w(_ar_op("+", "i", "j"), "q"),
                      _ar_op("+", 1, _ar_op("*", 0.1, "k")), _ar_idx("e", "q"))
        doc = _ar_doc(["i", "j", "k"], [(1, ni), (1, nj), (1, nk)], ["q"], [(1, m)], body;
                      evars=Dict("e" => Dict("type" => "unknown", "shape" => Any["q"])))
        ics = merge(Dict{String,Any}("y[$i,$j,$k]" => 0.0
                                     for i in 1:ni, j in 1:nj, k in 1:nk),
                    Dict{String,Any}("e[$q]" => 1.0 + 0.02q for q in 1:m))
        same, tally, _, _ = _ar_agree(doc, ics)
        @test same
        @test get(tally, :affine_reduce, 0) >= 1
    end

    @testset "ForwardDiff through the fold" begin
        same, _, (fn, u, pn, vn), (fi, ui, pi_, vi) =
            _ar_agree(_ar_sr_doc(10, 30), _ar_sr_ics(10, 30))
        @test same
        seed = Float64[0.3 + 0.01 * sin(i) for i in eachindex(u)]
        seedi = similar(seed)
        for (k, j) in vi
            seedi[j] = seed[vn[k]]
        end
        gn = ForwardDiff.derivative(s -> _ar_du(fn, u .+ s .* seed, pn), 0.0)
        gi = ForwardDiff.derivative(s -> _ar_du(fi, ui .+ s .* seedi, pi_), 0.0)
        @test all(gn[vn[k]] == gi[j] for (k, j) in vi)
    end

    @testset "zero allocations per call" begin
        fn, u0, p, _, _ = _ar_build(_ar_sr_doc(12, 64), _ar_sr_ics(12, 64))
        du = similar(u0)
        fn(du, u0, p, 0.0)
        @test (@allocated fn(du, u0, p, 0.0)) == 0
    end

    @testset "a ghost along the contracted axis keeps the unroll" begin
        # y[i] = Σ_k w[k]·e[i+k-2]: the source is a ghost past either end, so the
        # contracted axis is cut and the loop form declines.
        n = 10
        body = _ar_op("*", _ar_op("+", 0.25, _ar_op("*", 0.1, "k")),
                      _ar_idx("e", _ar_op("-", _ar_op("+", "i", "k"), 2)))
        doc = _ar_doc(["i"], [(1, n)], ["k"], [(1, 3)], body;
                      evars=Dict("e" => Dict("type" => "unknown", "shape" => Any["i"])))
        push!(doc["models"]["R"]["equations"], Dict(
            "lhs" => _ar_lhs("e", ["i"], [("i", (1, n))]),
            "rhs" => Dict("op" => "faq", "args" => Any[], "output_idx" => Any["i"],
                          "ranges" => Dict("i" => Any[1, n]),
                          "expr" => _ar_op("-", _ar_idx("e", "i")))))
        ics = merge(Dict{String,Any}("y[$i]" => 0.0 for i in 1:n),
                    Dict{String,Any}("e[$i]" => 1.0 + 0.1i for i in 1:n))
        same, tally, _, _ = _ar_agree(doc, ics)
        @test same
        @test get(tally, :affine_reduce, 0) == 0
        @test get(tally, :affine, 0) >= 1
    end
end
