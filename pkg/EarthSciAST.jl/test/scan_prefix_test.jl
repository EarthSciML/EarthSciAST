# Differential + behavioural test for CUMULATIVE (prefix) reductions on the
# O(N) scan path (ess-scan, tree_walk/scan.jl).
#
# A prefix reduction is an ordinary `aggregate` whose `filter` admits the
# monotone window `j <= i` (esm-spec §4.3.1). The build recognizes the FORWARD
# variants and splits them into a term pass (an ordinary affine/elementwise
# body with the contracted symbol renamed to the output symbol) plus an O(N)
# accumulation over `du`, instead of the O(N²) guarded fold
# `_unrolled_contraction_body` would emit.
#
# What is pinned here:
#   * BIT-IDENTITY against the per-cell reference (ESS_STENCIL_DISABLE=1), which
#     never sees the rewrite, and against the affine-interpreted tier
#     (ESS_CODEGEN_DISABLE=1). Inputs are catastrophic-cancellation magnitudes
#     with sign flips, so a re-association would show as a mismatch rather than
#     a last-ulp rounding difference.
#   * The rewrite actually FIRED (`n_scan_folds`, cascade `:scan`) — otherwise a
#     silent decline would make every comparison pass trivially.
#   * The decline conditions: reverse scans, and bodies that reference the
#     scanned output symbol, must keep the triangular path AND stay correct.
#   * `:oop` ≡ `:inplace`, the property the in-place tests lean on elsewhere.
using Test
using EarthSciAST
include("testutils.jl")
const ESM = EarthSciAST

# Catastrophic magnitudes with sign flips (1e-8 … 1e8): a fold evaluated in a
# different association order does not reproduce these bit-for-bit.
_sc_val(k) = (1.0 - 2.0 * (k % 2)) * 10.0^(((k * 7) % 17) - 8)

_bits(v::AbstractVector{Float64}) = reinterpret(UInt64, v)

# D(c[i]) = ⊕_{j ⋚ i} body(j), with `u` a state so the RHS reads real values.
# `u` is held fixed (D(u)=0) so the equation under test owns `c` alone.
function _scan_model(n::Int; filt="<=", reduce="+", body=nothing)
    vars = Dict("u" => ESM.ModelVariable(ESM.StateVariable),
                "c" => ESM.ModelVariable(ESM.StateVariable))
    b = body === nothing ? _idx("u", _v("j")) : body
    rhs = ESM.OpExpr("arrayop", ESM.ASTExpr[]; output_idx=Any["i"], expr_body=b,
        ranges=Dict("i" => [1, n], "j" => [1, n]), reduce=reduce,
        filter=_op(filt, _v("j"), _v("i")))
    ESM.Model(vars, [
        ESM.Equation(_ao1(_Didx("c", _v("i")), "i", 1, n), rhs),
        ESM.Equation(_ao1(_Didx("u", _v("i")), "i", 1, n), _ao1(_n(0.0), "i", 1, n)),
    ])
end

# Build and evaluate one RHS at the catastrophic state vector.
# `tier` selects which evaluation path produces `du`:
#   :scan     — the default build (the rewrite fires)
#   :percell  — ESS_STENCIL_DISABLE=1, the maximally independent reference
#   :interp   — ESS_CODEGEN_DISABLE=1, affine but interpreted
#   :oop      — the out-of-place emitter
function _scan_du(model; tier=:scan)
    envs = tier === :percell ? ("ESS_STENCIL_DISABLE" => "1", "ESS_CODEGEN_DISABLE" => nothing) :
           tier === :interp  ? ("ESS_STENCIL_DISABLE" => nothing, "ESS_CODEGEN_DISABLE" => "1") :
                               ("ESS_STENCIL_DISABLE" => nothing, "ESS_CODEGEN_DISABLE" => nothing)
    withenv(envs...) do
        ESM._reset_cascade_tally!()
        f!, u0, p, _t, vm, diag = ESM._build_evaluator_impl(model;
            form = tier === :oop ? :oop : :inplace)
        u = Float64[_sc_val(k) for k in 1:length(u0)]
        du = if tier === :oop
            collect(f!(u, p, 0.0))
        else
            buf = zero(u0); f!(buf, u, p, 0.0); buf
        end
        (du=du, vm=vm, diag=diag, tally=copy(ESM._CASCADE_TALLY))
    end
end

@testset "cumulative (prefix) reductions — O(N) scan (ess-scan)" begin

    @testset "forward scan ≡ per-cell reference, bitwise" begin
        for n in (1, 2, 3, 8, 33, 64), filt in ("<=", "<"),
            red in ("+", "*", "max", "min")
            m = _scan_model(n; filt=filt, reduce=red)
            a = _scan_du(m)
            @test a.diag.n_scan_folds == 1            # the rewrite FIRED
            @test get(a.tally, :scan, 0) == 1
            @test _bits(a.du) == _bits(_scan_du(m; tier=:percell).du)
            @test _bits(a.du) == _bits(_scan_du(m; tier=:interp).du)
        end
    end

    @testset "running totals are the expected values" begin
        # u[i] = i via an explicit IC, so the prefix sums are the triangular
        # numbers and the strict variant is shifted by one.
        n = 6
        for (filt, expected) in (("<=", cumsum(1.0:n)),
                                 ("<",  [0.0; cumsum(1.0:n-1)]))
            m = _scan_model(n; filt=filt)
            ics = Dict("u[$i]" => Float64(i) for i in 1:n)
            f!, u0, p, _t, vm, diag = ESM._build_evaluator_impl(m; initial_conditions=ics)
            du = zero(u0); f!(du, u0, p, 0.0)
            @test diag.n_scan_folds == 1
            @test [du[vm["c[$i]"]] for i in 1:n] == collect(expected)
        end
    end

    @testset "empty window takes the semiring identity, not zero" begin
        # Strict `j < i` at cell 1 reduces over the EMPTY set (esm-spec §4.3.1).
        # Under `max` that is -Inf, which is exactly the case a hardcoded 0.0
        # identity gets wrong (and did, in the Python port, until this pattern
        # was fixtured).
        m = _scan_model(4; filt="<", reduce="max")
        a = _scan_du(m)
        @test a.diag.n_scan_folds == 1
        @test a.du[a.vm["c[1]"]] == -Inf
        @test _bits(a.du) == _bits(_scan_du(m; tier=:percell).du)
    end

    @testset "mirrored spelling `i >= j` is the same forward scan" begin
        n = 16
        m = _scan_model(n)                                   # j <= i
        vars = Dict("u" => ESM.ModelVariable(ESM.StateVariable),
                    "c" => ESM.ModelVariable(ESM.StateVariable))
        rhs = ESM.OpExpr("arrayop", ESM.ASTExpr[]; output_idx=Any["i"],
            expr_body=_idx("u", _v("j")), ranges=Dict("i" => [1, n], "j" => [1, n]),
            reduce="+", filter=_op(">=", _v("i"), _v("j")))   # i >= j
        mirror = ESM.Model(vars, [
            ESM.Equation(_ao1(_Didx("c", _v("i")), "i", 1, n), rhs),
            ESM.Equation(_ao1(_Didx("u", _v("i")), "i", 1, n), _ao1(_n(0.0), "i", 1, n)),
        ])
        b = _scan_du(mirror)
        @test b.diag.n_scan_folds == 1
        @test _bits(_scan_du(m).du) == _bits(b.du)
    end

    @testset "reverse scan declines the rewrite and stays correct" begin
        # `j >= i` is a genuine reverse scan: the spec fixes ascending-j
        # accumulation for every variant, so consecutive reverse cells share no
        # partial result and the triangular path is the only correct one.
        for filt in (">=", ">")
            m = _scan_model(8; filt=filt)
            a = _scan_du(m)
            @test a.diag.n_scan_folds == 0
            @test get(a.tally, :scan, 0) == 0
            @test _bits(a.du) == _bits(_scan_du(m; tier=:percell).du)
        end
    end

    @testset "body referencing the scanned symbol declines" begin
        # term = u[j] * u[i] depends on the output cell, so cells share nothing.
        # This is the condition that makes the rewrite sound rather than fast.
        m = _scan_model(8; body=_op("*", _idx("u", _v("j")), _idx("u", _v("i"))))
        a = _scan_du(m)
        @test a.diag.n_scan_folds == 0
        @test _bits(a.du) == _bits(_scan_du(m; tier=:percell).du)
    end

    @testset "measure-weighted term (a cumulative integral)" begin
        # u[j]*dx[j] — a body with real arithmetic in it, not a bare gather.
        n = 12
        m = _scan_model(n; body=_op("*", _idx("u", _v("j")), _n(0.25)))
        a = _scan_du(m)
        @test a.diag.n_scan_folds == 1
        @test _bits(a.du) == _bits(_scan_du(m; tier=:percell).du)
    end

    @testset ":oop emitter agrees with :inplace bitwise" begin
        for filt in ("<=", "<"), red in ("+", "max")
            m = _scan_model(12; filt=filt, reduce=red)
            @test _bits(_scan_du(m).du) == _bits(_scan_du(m; tier=:oop).du)
        end
    end

    @testset "a model with no prefix reduction carries no folds" begin
        n = 8
        vars = Dict("u" => ESM.ModelVariable(ESM.StateVariable))
        plain = ESM.Model(vars, [ESM.Equation(_ao1(_Didx("u", _v("i")), "i", 1, n),
                                              _ao1(_op("-", _idx("u", _v("i"))), "i", 1, n))])
        _f, _u0, _p, _t, _vm, diag = ESM._build_evaluator_impl(plain)
        @test diag.n_scan_folds == 0
    end
end
