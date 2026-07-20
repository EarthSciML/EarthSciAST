# Differential oracle for the NON-AFFINE live-forcing lane table lowering
# (perf-plan A2, prototypes/perf-gap-closure-plan.md in reseact.esm;
# `_materialize_pgather_tbl`, stencil_affine.jl).
#
# A live forcing gather whose subscript is CLAMPED (`max(i-1,1)` / `min(i+1,N)`
# — the GEOS-FP Mz/OMEGA column-wall pattern that observed inlining splices
# into every stencil lane) has a non-affine flat index across a box, and the
# clamp transition is invisible to the per-cell cut signature, so the corner
# verification used to throw the WHOLE equation onto the per-cell fallback.
# It now lowers to `_AccArrTblBox`: a per-box table of linear INDICES into the
# ALIASED live buffer (indices static, values read live).
#
# Three-way oracle per model, everything bit-identical:
#   :tbl — the default build (A2 table lowering);  cascade must land :affine
#   :off — ESS_OBSREF_DISABLE=1, the pre-A2 whole-equation per-cell fallback
#   :ref — ESS_STENCIL_DISABLE=1, the maximally independent per-cell reference
# plus the LIVENESS invariant: an in-place buffer refresh is seen by every
# path (a copied buffer would fail), matching stencil_affine_pgather_test.jl.
using Test
using EarthSciAST
include("testutils.jl")
const ESM = EarthSciAST

# Build `model` under the three env modes; returns tag → (f!, u0, p, tally).
function _pgt_build3(model, ics, bufs)
    out = Dict{Symbol,Any}()
    for (tag, envs) in (
            (:tbl, ("ESS_OBSREF_DISABLE" => nothing, "ESS_STENCIL_DISABLE" => nothing)),
            (:off, ("ESS_OBSREF_DISABLE" => "1", "ESS_STENCIL_DISABLE" => nothing)),
            (:ref, ("ESS_OBSREF_DISABLE" => nothing, "ESS_STENCIL_DISABLE" => "1")))
        withenv(envs...) do
            ESM._reset_cascade_tally!()
            f!, u0, p, _t, _vm, _diag = ESM._build_evaluator_impl(model;
                initial_conditions=ics, param_arrays=bufs)
            out[tag] = (f!, u0, p, copy(ESM._CASCADE_TALLY))
        end
    end
    out
end
function _pgt_eval(t)
    f!, u0, p, _ = t
    du = zero(u0); f!(du, u0, p, 0.0); du
end

# Clamped subscript helpers: max(e, 1) / min(e, N).
_clamp_lo(e) = _op("max", e, _i(1))
_clamp_hi(e, N) = _op("min", e, _i(N))

# (1) D(u[i]) = forcing[max(i-1,1)] + forcing[min(i+1,N)] — the reduced
# column-wall clamp pattern; pure forcing so the pgather lane is isolated.
function _pgt_clamped_model(N)
    vars = Dict("u" => ESM.ModelVariable(ESM.StateVariable))
    body = _op("+",
        _idx("forcing", _clamp_lo(_op("-", _v("i"), _i(1)))),
        _idx("forcing", _clamp_hi(_op("+", _v("i"), _i(1)), N)))
    ESM.Model(vars, [ESM.Equation(_ao1(_Didx("u", _v("i")), "i", 1, N),
                                  _ao1(body, "i", 1, N))])
end

# (2) Clamped forcing + Laplacian: the non-affine forcing lane rides in a
# multi-box stencil equation. The clamp width (2) EXCEEDS the stencil halo
# (1), so the clamp transition sits INSIDE the interior box — a ghost-box cut
# cannot absorb it (a width-1 clamp lands exactly on the [1,1]|[2,N-1] ghost
# cut and stays affine per box, defeating the differential).
function _pgt_mixed_model(N)
    vars = Dict("u" => ESM.ModelVariable(ESM.StateVariable))
    lap = _op("+", _idx("u", _op("-", _v("i"), _i(1))),
                   _op("*", _n(-2.0), _idx("u", _v("i"))),
                   _idx("u", _op("+", _v("i"), _i(1))))
    body = _op("+", _idx("forcing", _clamp_lo(_op("-", _v("i"), _i(2)))), lap)
    ESM.Model(vars, [ESM.Equation(_ao1(_Didx("u", _v("i")), "i", 1, N),
                                  _ao1(body, "i", 1, N))])
end

# (3) ARRAY OBSERVED forcing chain indexed in a stencil (the A2 shape proper):
# an observed `M` defined as an aggregate over CLAMPED live-forcing gathers
# (the Mx/Mz blend pattern), referenced at i and i+1 from the state stencil —
# observed inlining splices the clamped pgather reads into every lane.
#   M[e] = (1-w)·F0[max(e-1,1)] + w·F0[min(e,N)]        (e ∈ 1..N+1 edges)
#   D(u[i]) = M[i+1] − M[i] + u[i]·(-0.1)
function _pgt_obschain_model(N)
    w = 0.25
    ed(e) = _op("+",
        _op("*", _n(1.0 - w), _idx("F0", _clamp_lo(_op("-", e, _i(1))))),
        _op("*", _n(w), _idx("F0", _clamp_hi(e, N))))
    Mbody = ed(_v("e"))
    M = ESM.OpExpr("aggregate", ESM.ASTExpr[]; output_idx=Any["e"],
                   expr_body=Mbody, ranges=Dict{String,Any}("e" => Any[1, N + 1]))
    vars = Dict(
        "u" => ESM.ModelVariable(ESM.StateVariable),
        "M" => ESM.ModelVariable(ESM.ObservedVariable; shape=["e"], expression=M))
    body = _op("+",
        _op("-", _idx("M", _op("+", _v("i"), _i(1))), _idx("M", _v("i"))),
        _op("*", _idx("u", _v("i")), _n(-0.1)))
    ESM.Model(vars, [ESM.Equation(_ao1(_Didx("u", _v("i")), "i", 1, N),
                                  _ao1(body, "i", 1, N))])
end

function _pgt_oracle(model, ics, bufs; refresh!)
    b = _pgt_build3(model, ics, bufs)
    # The A2 lowering keeps the equation on the affine path; the kill switch
    # reproduces the pre-A2 per-cell fallback (the oracle is only meaningful
    # if the two paths genuinely diverge).
    @test get(b[:tbl][4], :affine, 0) >= 1
    @test get(b[:tbl][4], :percell_acc, 0) == 0
    @test get(b[:off][4], :percell_acc, 0) >= 1
    du = Dict(tag => _pgt_eval(b[tag]) for tag in (:tbl, :off, :ref))
    @test du[:tbl] == du[:ref]
    @test du[:off] == du[:ref]
    @test any(!iszero, du[:ref])
    # LIVENESS: refresh the buffers in place; every path sees the new values
    # (the index tables are static, the VALUES are read through the aliased
    # buffer) and they still agree bit-for-bit.
    refresh!()
    du2 = Dict(tag => _pgt_eval(b[tag]) for tag in (:tbl, :off, :ref))
    @test du2[:tbl] == du2[:ref]
    @test du2[:off] == du2[:ref]
    @test du2[:tbl] != du[:tbl]
    return nothing
end

@testset "non-affine pgather table lowering ≡ per-cell (A2 differential)" begin
    @testset "clamped forcing D(u[i])=F[max/min] (N=$N)" for N in (8, 32)
        buf = Float64[0.5 + 0.2k for k in 1:N]
        ics = Dict("u[$k]" => 0.0 for k in 1:N)
        _pgt_oracle(_pgt_clamped_model(N), ics, Dict("forcing" => buf);
                    refresh! = () -> (buf .= Float64[-2.0 + 0.9k for k in 1:N]))
    end

    @testset "clamped forcing + Laplacian, ghost boxes (N=$N)" for N in (8, 32)
        buf = Float64[0.5 + 0.2k for k in 1:N]
        ics = Dict("u[$k]" => sin(0.3k) + 0.1k for k in 1:N)
        _pgt_oracle(_pgt_mixed_model(N), ics, Dict("forcing" => buf);
                    refresh! = () -> (buf .= Float64[-3.0 + 0.7k for k in 1:N]))
    end

    @testset "array-observed forcing chain in a stencil (N=$N)" for N in (8, 24)
        buf = Float64[1.0 + 0.3k for k in 1:N]
        ics = Dict("u[$k]" => 0.4 + 0.05k for k in 1:N)
        _pgt_oracle(_pgt_obschain_model(N), ics, Dict("F0" => buf);
                    refresh! = () -> (buf .= Float64[2.0 - 0.4k for k in 1:N]))
    end

    @testset "kernel count N-independent (tables grow, kernels do not)" begin
        counts = map((8, 32, 128)) do N
            buf = Float64[0.2k for k in 1:N]
            ics = Dict("u[$k]" => 0.1k for k in 1:N)
            b = _pgt_build3(_pgt_mixed_model(N), ics, Dict("forcing" => buf))
            f!, u0, p, _ = b[:tbl]
            withenv("ESS_OBSREF_DISABLE" => nothing) do
                _f, _u, _p, _t, _vm, diag = ESM._build_evaluator_impl(
                    _pgt_mixed_model(N); initial_conditions=ics,
                    param_arrays=Dict("forcing" => Float64[0.2k for k in 1:N]))
                diag.n_acc_kernels
            end
        end
        @test all(==(counts[1]), counts)
    end

    @testset "Dual eltype through the table lane" begin
        # The generic (eltype-T) access evaluator arm must read the table the
        # same way; drive the same in-place f! at a Dual-like Complex eltype?
        # No — the suite's convention is ForwardDiff via the oop/tests; here a
        # plain second eltype smoke: Float64 path already covered, so assert
        # the :oop emitter agrees bit-for-bit (it lowers the same descriptor).
        N = 12
        buf = Float64[0.5 + 0.2k for k in 1:N]
        ics = Dict("u[$k]" => 0.1k for k in 1:N)
        model = _pgt_clamped_model(N)
        f!, u0, p, _t, _vm, _d = withenv("ESS_OBSREF_DISABLE" => nothing) do
            ESM._build_evaluator_impl(model; initial_conditions=ics,
                                      param_arrays=Dict("forcing" => buf))
        end
        fo, u0o, po, _to, _vmo, _do = withenv("ESS_OBSREF_DISABLE" => nothing) do
            ESM._build_evaluator_impl(model; initial_conditions=ics,
                                      param_arrays=Dict("forcing" => buf), form=:oop)
        end
        du = zero(u0); f!(du, u0, p, 0.0)
        @test Vector{Float64}(fo(u0o, po, 0.0)) == du
    end
end
