# Intra-kernel body split (ess-iip-split, tree_walk/codegen_kernel.jl).
#
# A kernel whose emitted cell body exceeds `_codegen_fn_node_cap` is partitioned
# so no single generated function is oversized — the body is split across
# `@noinline` helper functions threaded by RETURN VALUE — while the kernel STAYS
# FULLY COMPILED and NEVER declines to the per-cell interpreter (runtime speed is
# critical; the duo LMARS momentum kernels are ~1.5e5 nodes and would otherwise
# OOM the Julia compiler as one function). This pins:
#   * a forced-split build (tiny ESS_CODEGEN_FN_NODE_CAP) still CODEGENS the
#     kernel (`:codegen_kernel` fires) and does NOT decline it to the interpreter;
#   * its du is BIT-identical to the un-split build (ESS_CODEGEN_BODY_SPLIT_DISABLE)
#     at Float64 and under ForwardDiff (the split is value-exact, order-preserving);
#   * the pre-split build is byte-restored by ESS_CODEGEN_BODY_SPLIT_DISABLE=1.
using Test
using EarthSciAST
using ForwardDiff
include("testutils.jl")
const ESM = EarthSciAST

# A cell body with enough distinct arithmetic that a small fn-node cap must split
# it into several helper functions (a 2-D 9-point-ish combination over gathers).
function _bs_model(N)
    vars = Dict("u" => ESM.ModelVariable(ESM.UnknownVariable; shape=["i", "j"]))
    g(di, dj) = _idx("u", _op(di < 0 ? "-" : "+", _v("i"), _i(abs(di) == 0 ? 0 : abs(di))),
                          _op(dj < 0 ? "-" : "+", _v("j"), _i(abs(dj) == 0 ? 0 : abs(dj))))
    # nonlinear so the tree is deep and not trivially foldable
    terms = ASTExpr[]
    for di in -1:1, dj in -1:1
        push!(terms, _op("*", g(di, dj), _op("+", g(di, dj), _op("*", _n(0.5), g(0, 0)))))
    end
    body = _op("+", terms...)
    lhs = ESM.OpExpr("arrayop", ESM.ASTExpr[]; output_idx=Any["i", "j"],
        expr_body=_Didx("u", _v("i"), _v("j")), ranges=Dict("i" => [1, N], "j" => [1, N]))
    rhs = ESM.OpExpr("arrayop", ESM.ASTExpr[]; output_idx=Any["i", "j"],
        expr_body=body, ranges=Dict("i" => [1, N], "j" => [1, N]))
    ESM.Model(vars, [ESM.Equation(lhs, rhs)])
end

# Build under an explicit (fn_node_cap, split_disable) env pair; return RHS +
# a tally snapshot.
function _bs_build(model, ics; fncap=nothing, split_off=false)
    withenv("ESS_CODEGEN_FN_NODE_CAP" => (fncap === nothing ? nothing : string(fncap)),
            "ESS_CODEGEN_BODY_SPLIT_DISABLE" => (split_off ? "1" : nothing)) do
        ESM._reset_cascade_tally!()
        f!, u0, p, _t, vm, _diag = ESM._build_evaluator_impl(model; initial_conditions=ics)
        (f!, u0, p, copy(ESM._CASCADE_TALLY))
    end
end

_bs_du(f!, u, p, t) = (d = similar(u); fill!(d, 0.0); f!(d, u, p, t); d)
_bs_probe(n, k) = Float64[1.4 + 0.9 * sin(1.3i + 0.7k) * cos(0.31i * k) + 0.05i for i in 1:n]
_bs_same(a, b) = size(a) == size(b) && all(a .=== b)
_decl(t) = sum(v for (k, v) in t if startswith(String(k), "codegen_decline"); init=0)

@testset "intra-kernel body split" begin
    model = _bs_model(6)
    ics = Dict("u" => 1.0)

    # Reference: split OFF (one function per kernel, the pre-change layout).
    fr, u0, pr, rt = _bs_build(model, ics; split_off=true)
    @test get(rt, :codegen_kernel, 0) >= 1        # kernel codegens (not interpreter)
    @test _decl(rt) == 0                          # nothing declined

    # Forced split: a small fn-node cap makes the body exceed one function, so it
    # is partitioned into helpers — and STILL codegens (no interpreter decline).
    fs, v0, ps, st = _bs_build(model, ics; fncap=40)
    @test get(st, :codegen_kernel, 0) >= 1        # STILL codegen'd (split, not declined)
    @test _decl(st) == 0                          # the split never falls back to the interpreter

    @test u0 == v0

    # Bit-identical du across the split and the reference, Float64 + the AD axis.
    for k in 1:5, t in (0.0, 0.7, 3.25)
        u = k == 1 ? copy(u0) : _bs_probe(length(u0), k)
        @test _bs_same(_bs_du(fs, u, ps, t), _bs_du(fr, u, pr, t))
    end
    Js = ForwardDiff.jacobian(uu -> _bs_du(fs, uu, ps, 0.4), u0)
    Jr = ForwardDiff.jacobian(uu -> _bs_du(fr, uu, pr, 0.4), u0)
    @test _bs_same(Js, Jr)
end
