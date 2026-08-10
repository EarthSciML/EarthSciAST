# Differential oracle for the SUBTREE-TABLE RESCUE (subterm-granular fallback;
# `_try_exprtbl_lane` / `LANE_EXPRTBL`, tree_walk/stencil.jl).
#
# BEFORE-SHAPE (reproduced on the pre-rescue build, N=8): one nested scalar
# reduction Σ_{k=1..3} W[i,k]·k inside an otherwise-affine stencil body threw
#     _StencilFallback("unsupported loop-var-dependent op 'aggregate'")
# out of `_stencilize_op_core`'s catch-all, and the WHOLE equation landed on
# the per-cell scalarize fallback — `_CASCADE_TALLY[:percell_acc] == 1`,
# O(#cells) IR (the failure mode behind the GEOS-FP incident where one
# declined equation was ~910k of ~935k `_compile` calls). `aggregate` is
# deliberately outside `_STENCIL_ELEMENTWISE_OPS` (op_registry.jl carries no
# `stencil=true` on the aggregate row), so the decline is the registry-pinned
# behavior, not a missing flag.
#
# AFTER-SHAPE: the subtree is BUILD-TIME EVALUABLE (free references: loop
# index `i`, binder `k`, const array `W` — no state, no `t`, no params), so it
# becomes a `LANE_EXPRTBL` lane materialized per box as a dense value table
# (`_materialize_const_box`), the equation lands `:affine`, and the rescue
# tally `:affine_subtree_tbl` fires once (one rescued subtree lane, one branch
# template).
#
# Three-way oracle per model, everything bit-identical:
#   :tbl — the default build (subtree-table rescue);  cascade must land :affine
#   :off — ESS_SUBTREE_TBL_DISABLE=1, the pre-rescue whole-equation per-cell
#          fallback byte-for-byte (the before-shape, asserted in-test)
#   :ref — ESS_STENCIL_DISABLE=1, the maximally independent per-cell reference
# plus a ForwardDiff state-Jacobian equality (Dual numerics), a grid-structure
# pin (kernel count grid-independent, table length scales with the box — the
# grid_invariance_test idiom), and a NEGATIVE control (state reference inside
# the offending subtree still declines to per-cell and still matches the
# oracle).
using Test
using EarthSciAST
using ForwardDiff
include("testutils.jl")
const ESM = EarthSciAST

# D(u[i]) = Δ²u[i] + Σ_{k=1..3} W[i,k]·k        (W a const array, N×3)
# The aggregate is NESTED inside the elementwise `+` (a top-level contraction
# would be unrolled by `_compile_arrayop_equation!` and never reach the
# stencilizer's catch-all). `state_in_agg=true` swaps the `·k` factor for
# `·u[i]` — a STATE reference inside the offending subtree, the negative
# control (`_exprtbl_evaluable` must reject it; "u" is neither a loop index
# nor a const array).
function _stt_model(N; state_in_agg::Bool=false)
    vars = Dict("u" => ESM.ModelVariable(ESM.StateVariable))
    lap = _op("+", _idx("u", _op("-", _v("i"), _i(1))),
                   _op("*", _n(-2.0), _idx("u", _v("i"))),
                   _idx("u", _op("+", _v("i"), _i(1))))
    term = state_in_agg ?
        _op("*", _idx("W", _v("i"), _v("k")), _idx("u", _v("i"))) :
        _op("*", _idx("W", _v("i"), _v("k")), _v("k"))
    agg = ESM.OpExpr("aggregate", ESM.ASTExpr[]; expr_body=term,
        ranges=Dict{String,Any}("k" => Any[1, 3]), reduce="+")
    ESM.Model(vars, [ESM.Equation(_ao1(_Didx("u", _v("i")), "i", 1, N),
                                  _ao1(_op("+", lap, agg), "i", 1, N))])
end

# Row sums genuinely vary per cell (sin data), so the interior box's table can
# NOT collapse through the exhaustive all-equal fold — the `_AccConstBox`
# table lane is really exercised, not folded away.
_stt_W(N) = Float64[sin(1.7i * k) + 0.05i for i in 1:N, k in 1:3]
_stt_ics(N) = Dict("u[$k]" => sin(0.3k) + 0.1k for k in 1:N)

# Build `model` under the three env modes; tag → (f!, u0, p, tally, diag).
function _stt_build3(model, ics, W)
    out = Dict{Symbol,Any}()
    for (tag, envs) in (
            (:tbl, ("ESS_SUBTREE_TBL_DISABLE" => nothing, "ESS_STENCIL_DISABLE" => nothing)),
            (:off, ("ESS_SUBTREE_TBL_DISABLE" => "1", "ESS_STENCIL_DISABLE" => nothing)),
            (:ref, ("ESS_SUBTREE_TBL_DISABLE" => nothing, "ESS_STENCIL_DISABLE" => "1")))
        withenv(envs...) do
            ESM._reset_cascade_tally!()
            f!, u0, p, _t, _vm, diag = ESM._build_evaluator_impl(model;
                initial_conditions=ics, const_arrays=Dict("W" => W))
            out[tag] = (f!, u0, p, copy(ESM._CASCADE_TALLY), diag)
        end
    end
    out
end
function _stt_du(t)
    f!, u0, p, _, _ = t
    du = zero(u0); f!(du, u0, p, 0.0); du
end
_stt_jac(t) = ForwardDiff.jacobian(
    uu -> (d = similar(uu); fill!(d, 0); t[1](d, uu, t[3], 0.0); d), t[2])

# Structural introspection build (grid pin): ESS_CODEGEN_DISABLE=1 keeps the
# complete kernel list in `kernel_section.kernels` (the grid_invariance_test
# idiom — n_emitted == 0 asserted at the use site).
function _stt_kernels(N)
    withenv("ESS_CODEGEN_DISABLE" => "1") do
        ESM._reset_cascade_tally!()
        f, u0, p, _t, _vm, _diag = ESM._build_evaluator_impl(_stt_model(N);
            initial_conditions=_stt_ics(N), const_arrays=Dict("W" => _stt_W(N)))
        ks = getfield(getfield(f, :kernel_section), :kernels)
        (kernels=ks, tally=copy(ESM._CASCADE_TALLY),
         n_emitted=getfield(getfield(f, :kernel_section), :n_emitted))
    end
end
# Total materialized const-box table length across kernels. In this fixture W
# is read ONLY through the rescued lane, so every `_AK_CONST_BOX` descriptor
# IS a per-box subtree table (single-cell edge boxes fold to literals via the
# exhaustive all-equal fold — vals has one entry — leaving the interior box).
_stt_tbl_len(kernels) = sum(sum(Int[length(d.arr) for d in K.acc
                                    if d.kind == ESM._AK_CONST_BOX])
                            for K in kernels; init=0)

@testset "subtree-table rescue ≡ per-cell (subterm-granular fallback)" begin

    @testset "nested const reduction in a stencil (N=$N)" for N in (8, 32)
        b = _stt_build3(_stt_model(N), _stt_ics(N), _stt_W(N))
        # AFTER-shape: the rescue keeps the equation on the affine path…
        @test get(b[:tbl][4], :affine, 0) == 1
        @test get(b[:tbl][4], :percell_acc, 0) == 0
        @test get(b[:tbl][4], :affine_subtree_tbl, 0) == 1
        # …and the BEFORE-shape is reproduced by the kill switch: the whole
        # equation declines to per-cell, exactly the pre-rescue build.
        @test get(b[:off][4], :percell_acc, 0) == 1
        @test get(b[:off][4], :affine, 0) == 0
        @test get(b[:off][4], :affine_subtree_tbl, 0) == 0
        # Numerics: BIT-identical across all three paths, and nontrivial.
        du = Dict(tag => _stt_du(b[tag]) for tag in (:tbl, :off, :ref))
        @test du[:tbl] == du[:ref]
        @test du[:off] == du[:ref]
        @test any(!iszero, du[:ref])
        # ForwardDiff Dual: the state Jacobian is bit-identical too (the
        # table entries are Float64 → zero partials, same as the per-cell
        # path's const subtree).
        @test _stt_jac(b[:tbl]) == _stt_jac(b[:ref])
    end

    @testset "kernel count grid-independent; table scales with the box" begin
        N1, N2 = 8, 24
        A = _stt_kernels(N1)
        B = _stt_kernels(N2)
        @test A.n_emitted == 0 && B.n_emitted == 0     # lists are complete
        @test A.tally == B.tally                        # incl. :affine_subtree_tbl
        @test get(A.tally, :affine_subtree_tbl, 0) == 1
        @test length(A.kernels) == length(B.kernels)    # structure is O(1) in N
        # Only the per-lane DATA grows: the interior box [2, N-1] carries the
        # dense subtree table (edge single-cell boxes folded to literals).
        @test _stt_tbl_len(A.kernels) == N1 - 2
        @test _stt_tbl_len(B.kernels) == N2 - 2
    end

    @testset "NEGATIVE control: state inside the subtree still declines (N=$N)" for N in (8,)
        b = _stt_build3(_stt_model(N; state_in_agg=true), _stt_ics(N), _stt_W(N))
        # `_exprtbl_evaluable` rejects the state reference BEFORE any recipe
        # or tally: the equation takes today's whole-equation per-cell path.
        @test get(b[:tbl][4], :percell_acc, 0) == 1
        @test get(b[:tbl][4], :affine, 0) == 0
        @test get(b[:tbl][4], :affine_subtree_tbl, 0) == 0
        du = Dict(tag => _stt_du(b[tag]) for tag in (:tbl, :off, :ref))
        @test du[:tbl] == du[:ref]
        @test du[:off] == du[:ref]
        @test any(!iszero, du[:ref])
        # And the state factor is LIVE through the fallback (Jacobian picks up
        # the Σ_k W[i,k] diagonal contribution identically on both paths).
        @test _stt_jac(b[:tbl]) == _stt_jac(b[:ref])
    end
end
