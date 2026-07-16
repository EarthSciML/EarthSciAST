# Differential test for CONSTANT-bound contractions (aggregate reductions) on the
# affine access-kernel path (ess-affine). A contraction used to be gated out of the
# affine path entirely (`isempty(contract_names)`), forcing the per-cell reduce.
# It is now UNROLLED into a plain ⊕-fold of affine-gather terms
# (`_unrolled_contraction_body`) and lowered by the existing box processor — no
# runtime reduce, no per-cell loop. The unroll reuses `_foreach_aggregate_term`
# (term order, filter `ifelse`-guard) and seeds the fold with the 0̄ identity first,
# so it is bit-identical to `_eval_contraction`. Only constant-bound, no-join
# contractions unroll; variable-valence / join-gated ones stay on the per-cell path.
#
# Each model: affine (ESS_AFFINE=1) ≡ per-cell (ESS_STENCIL_DISABLE=1) BIT-IDENTITY,
# affine FIRED (n_acc ≥ 1) and OWNED the equation (n_vec == 0).
using Test
using EarthSciAST
include("testutils.jl")
const ESM = EarthSciAST

function _ct_build(model, ics; affine::Bool, const_arrays=Dict())
    envs = affine ? ("ESS_AFFINE" => "1", "ESS_STENCIL_DISABLE" => nothing) :
                    ("ESS_AFFINE" => nothing, "ESS_STENCIL_DISABLE" => "1")
    withenv(envs...) do
        f!, u0, p, _t, vm, diag = ESM._build_evaluator_impl(model;
            initial_conditions=ics, const_arrays=const_arrays)
        du = zero(u0); f!(du, u0, p, 0.0)
        (du, u0, vm, diag)
    end
end

# D(y[i]) = ⊕_{k=lo:hi} body, output i in 1:ni. `reduce` names ⊕; `filt` optional.
function _reduce_model(statevars, ybody, ni, klo, khi; reduce="+", filt=nothing)
    vars = Dict(v => ESM.ModelVariable(ESM.StateVariable) for v in statevars)
    rhs = ESM.OpExpr("arrayop", ESM.ASTExpr[]; output_idx=Any["i"], expr_body=ybody,
        ranges=Dict("i" => [1, ni], "k" => [klo, khi]), reduce=reduce, filter=filt)
    ESM.Model(vars, [ESM.Equation(_ao1(_Didx(statevars[1], _v("i")), "i", 1, ni), rhs)])
end

@testset "affine constant-bound contraction ≡ per-cell (differential, ess-affine)" begin
    @testset "matvec sum_product D(y[i])=Σ A[i,k]·x[k]" begin
        A = [1.0 2.0 3.0; 4.0 5.0 6.0]
        body = _op("*", _idx("A", _v("i"), _v("k")), _idx("x", _v("k")))
        m = _reduce_model(["y", "x"], body, 2, 1, 3)
        ics = Dict("y[1]"=>0.0, "y[2]"=>0.0, "x[1]"=>1.0, "x[2]"=>1.0, "x[3]"=>1.0)
        du_a, _, vm, d = _ct_build(m, ics; affine=true, const_arrays=Dict("A"=>A))
        du_r, _, _, _ = _ct_build(m, ics; affine=false, const_arrays=Dict("A"=>A))
        @test d.n_acc_kernels >= 1
        @test d.n_vec_kernels == 0
        @test du_a == du_r
        @test du_a[vm["y[1]"]] == 6.0 && du_a[vm["y[2]"]] == 15.0
    end

    @testset "min_sum D(d[i])=min_k (u[i]+k) (N=$ni)" for ni in (3, 8, 32)
        body = _op("+", _idx("u", _v("i")), _v("k"))
        m = _reduce_model(["d", "u"], body, ni, 1, 3; reduce="min")
        ics = Dict{String,Float64}()
        for k in 1:ni; ics["d[$k]"]=0.0; ics["u[$k]"]=0.3k - 1.0; end
        du_a, _, _, d = _ct_build(m, ics; affine=true)
        du_r, _, _, _ = _ct_build(m, ics; affine=false)
        @test d.n_acc_kernels >= 1
        @test d.n_vec_kernels == 0
        @test du_a == du_r
    end

    @testset "max_product D(b[i])=max_k (u[i]·k)" begin
        body = _op("*", _idx("u", _v("i")), _v("k"))
        m = _reduce_model(["b", "u"], body, 4, 1, 3; reduce="max")
        ics = Dict{String,Float64}()
        for k in 1:4; ics["b[$k]"]=0.0; ics["u[$k]"]=0.5k - 1.0; end
        du_a, _, _, d = _ct_build(m, ics; affine=true)
        du_r, _, _, _ = _ct_build(m, ics; affine=false)
        @test d.n_acc_kernels >= 1
        @test d.n_vec_kernels == 0
        @test du_a == du_r
    end

    @testset "empty reduction Σ_{k∈∅} → 0̄" begin
        body = _op("+", _idx("u", _v("i")), _v("k"))
        m = _reduce_model(["z", "u"], body, 3, 1, 0; reduce="+")   # k in [1,0] empty
        ics = Dict{String,Float64}()
        for k in 1:3; ics["z[$k]"]=0.0; ics["u[$k]"]=0.5k; end
        du_a, _, _, d = _ct_build(m, ics; affine=true)
        du_r, _, _, _ = _ct_build(m, ics; affine=false)
        @test d.n_acc_kernels >= 1
        @test du_a == du_r
        @test all(du_a .== 0.0)
    end

    @testset "filtered reduction D(w[i])=Σ_{k=1:4, k≤2} u[i]·k" begin
        body = _op("*", _idx("u", _v("i")), _v("k"))
        filt = _op("<=", _v("k"), _i(2))
        m = _reduce_model(["w", "u"], body, 3, 1, 4; reduce="+", filt=filt)
        ics = Dict{String,Float64}()
        for k in 1:3; ics["w[$k]"]=0.0; ics["u[$k]"]=1.0; end
        du_a, _, vm, d = _ct_build(m, ics; affine=true)
        du_r, _, _, _ = _ct_build(m, ics; affine=false)
        @test d.n_acc_kernels >= 1
        @test d.n_vec_kernels == 0
        @test du_a == du_r
        @test du_a[vm["w[1]"]] == 3.0     # 1·1 + 1·2 (k=3,4 filtered out)
    end

    @testset "contraction kernel count N-independent" begin
        body = _op("+", _idx("u", _v("i")), _v("k"))
        counts = map((3, 8, 64)) do ni
            m = _reduce_model(["d", "u"], body, ni, 1, 3; reduce="min")
            ics = Dict{String,Float64}()
            for k in 1:ni; ics["d[$k]"]=0.0; ics["u[$k]"]=0.1k; end
            _ct_build(m, ics; affine=true)[4].n_acc_kernels
        end
        @test all(==(counts[1]), counts)
    end

    @testset "2-D output contraction D(w[i,j])=Σ_{k=1:3} u[i,j]·k" begin
        N = 4
        vars = Dict("w" => ESM.ModelVariable(ESM.StateVariable; shape=["i", "j"]),
                    "u" => ESM.ModelVariable(ESM.StateVariable; shape=["i", "j"]))
        body = _op("*", _idx("u", _v("i"), _v("j")), _v("k"))
        lhs = ESM.OpExpr("arrayop", ESM.ASTExpr[]; output_idx=Any["i", "j"],
            expr_body=_Didx("w", _v("i"), _v("j")), ranges=Dict("i"=>[1,N], "j"=>[1,N]))
        rhs = ESM.OpExpr("arrayop", ESM.ASTExpr[]; output_idx=Any["i", "j"], expr_body=body,
            ranges=Dict("i"=>[1,N], "j"=>[1,N], "k"=>[1,3]), reduce="+")
        m = ESM.Model(vars, [ESM.Equation(lhs, rhs)])
        ics = Dict("$v[$i,$j]" => (v=="u" ? sin(0.2i)+0.1j : 0.0)
                   for v in ("w","u"), i in 1:N, j in 1:N)
        du_a, _, _, d = _ct_build(m, ics; affine=true)
        du_r, _, _, _ = _ct_build(m, ics; affine=false)
        @test d.n_acc_kernels >= 1
        @test d.n_vec_kernels == 0
        @test du_a == du_r
    end
end
