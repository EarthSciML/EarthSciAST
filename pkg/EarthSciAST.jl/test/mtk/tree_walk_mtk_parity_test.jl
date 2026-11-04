# The tree-walk evaluator against ModelingToolkit's code generation, sample by
# sample: the same 1-D heat model built both ways must give the same
# right-hand side at random states. Split out of tree_walk_test.jl so the
# regular suite never loads ModelingToolkit; this file runs in the
# ModelingToolkit suite (test/mtk/runtests.jl).
using Test
using EarthSciAST
import ModelingToolkit

include("../testutils.jl")  # _n/_v/_op/_D builders

const ESM = EarthSciAST
const MTK = ModelingToolkit

# ========================================================
# MTK parity — 1D heat (10 cells) compared to MTK-codegen
# ========================================================
@testset "MTK parity — random f! samples match" begin
    N = 10
    dx = 1.0 / (N + 1)
    α = 0.75
    vars = Dict{String, ModelVariable}()
    eqs = ESM.Equation[]
    for i in 1:N
        vars["u_$i"] = ModelVariable(UnknownVariable; default = sinpi(i * dx))
    end
    vars["alpha"] = ModelVariable(ParameterVariable; default = α)
    for i in 1:N
        here = _v("u_$i")
        left = i == 1 ? _n(0.0) : _v("u_$(i - 1)")
        right = i == N ? _n(0.0) : _v("u_$(i + 1)")
        rhs = _op(
            "*",
            _v("alpha"),
            _op(
                "/",
                _op("+", _op("-", left, here), _op("-", right, here)),
                _n(dx^2)
            )
        )
        push!(eqs, ESM.Equation(_D("u_$i"), rhs))
    end
    model = ESM.Model(vars, eqs)

    # Tree-walk path
    f_tw!, u0_tw, p_tw, _tspan, var_map = EarthSciAST._build_evaluator(model)

    # MTK path
    sys = MTK.System(model; name = :HeatParity)
    simp = MTK.mtkcompile(sys)
    prob_mtk = MTK.ODEProblem(simp, Dict{Any, Any}(), (0.0, 1.0))
    f_mtk = prob_mtk.f
    u0_mtk = prob_mtk.u0
    p_mtk = prob_mtk.p

    # The two paths may order states differently. Build a
    # permutation mapping tree-walk index → MTK index by matching
    # variable names (simp's unknown ending in "_u_i" matches our
    # "u_i" in var_map).
    mtk_unknowns = MTK.unknowns(simp)
    mtk_name_to_idx = Dict{String, Int}()
    for (j, u) in enumerate(mtk_unknowns)
        nm = string(MTK.getname(u))
        # MTK sanitizes names as `HeatParity₊u_i` or similar; match suffix
        for (vname, _) in var_map
            if nm == vname || endswith(nm, "_" * vname) ||
                    endswith(nm, "₊" * vname)
                mtk_name_to_idx[vname] = j
            end
        end
    end

    # Sample 5 random u-vectors; compare RHS values.
    for trial in 1:5
        u_tw = rand(N) .+ 0.1
        u_mtk = similar(u0_mtk)
        for (vname, idx_tw) in var_map
            idx_mtk = mtk_name_to_idx[vname]
            u_mtk[idx_mtk] = u_tw[idx_tw]
        end
        du_tw = similar(u_tw)
        f_tw!(du_tw, u_tw, p_tw, 0.0)

        du_mtk = similar(u_mtk)
        f_mtk(du_mtk, u_mtk, p_mtk, 0.0)

        for (vname, idx_tw) in var_map
            idx_mtk = mtk_name_to_idx[vname]
            @test isapprox(du_tw[idx_tw], du_mtk[idx_mtk]; rtol = 1.0e-12)
        end
    end
end
