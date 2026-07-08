# MTK-extension smoke tests for `interp.linear` and `interp.bilinear`
# (esm-94w / esm-q7a).
#
# Two contracts:
# 1. The MTK ext lowers an ESM model whose RHS contains an `interp.*` `fn`
#    call into a System whose `mtkcompile` produces a working ODEProblem
#    (correctness path).
# 2. Each call appears as a single opaque registered-symbolic operator —
#    NOT alias-eliminated into ~10 intermediates — so a system with many
#    calls compiles in seconds, not minutes (perf path; this is the whole
#    reason the named primitives exist; see esm-spec §9.2 + hq-wisp-y6g6).
#
# We don't simulate the ODE here — solver tolerances aren't part of the
# spec contract for these primitives. The conformance fixtures in
# `closed_functions_test.jl` already pin numerical agreement.

using Test
using EarthSciAST
using OrderedCollections: OrderedDict
import ModelingToolkit
import Symbolics

const ESM3 = EarthSciAST
const MTK3 = ModelingToolkit

@testset "MTK ext — interp.linear / interp.bilinear (esm-94w)" begin

    # ---------- Helpers ----------
    _v(name) = ESM3.VarExpr(String(name))
    _n(x)    = ESM3.NumExpr(Float64(x))
    _const(v) = ESM3.OpExpr("const", ESM3.Expr[]; value=v)
    _fn(name, args...) =
        ESM3.OpExpr("fn", ESM3.Expr[args...]; name=String(name))

    # Build a Model whose state derivative is `interp.linear(table, axis, x_var)`.
    function _linear_model(table::Vector{Float64}, axis::Vector{Float64};
                            x_default::Float64=0.0)
        vars = OrderedDict{String,ESM3.ModelVariable}(
            "x" => ESM3.ModelVariable(ESM3.ParameterVariable; default=x_default),
            "y" => ESM3.ModelVariable(ESM3.StateVariable;     default=0.0),
        )
        rhs = _fn("interp.linear", _const(table), _const(axis), _v("x"))
        eqs = ESM3.Equation[
            ESM3.Equation(_op_D("y"), rhs),
        ]
        return ESM3.Model(vars, eqs)
    end

    function _bilinear_model(table::Vector{Vector{Float64}},
                              axis_x::Vector{Float64}, axis_y::Vector{Float64};
                              x_default=0.0, y_default=0.0)
        vars = OrderedDict{String,ESM3.ModelVariable}(
            "x" => ESM3.ModelVariable(ESM3.ParameterVariable; default=x_default),
            "y" => ESM3.ModelVariable(ESM3.ParameterVariable; default=y_default),
            "z" => ESM3.ModelVariable(ESM3.StateVariable;     default=0.0),
        )
        rhs = _fn("interp.bilinear", _const(table), _const(axis_x), _const(axis_y),
                  _v("x"), _v("y"))
        eqs = ESM3.Equation[
            ESM3.Equation(_op_D("z"), rhs),
        ]
        return ESM3.Model(vars, eqs)
    end

    _op_D(name) = ESM3.OpExpr("D", ESM3.Expr[_v(name)]; wrt="t")

    # --------------------------------------------------------------
    # 1. interp.linear lowers + compiles; the registered op appears
    # in the lowered equation as a single symbolic call (opaque).
    # --------------------------------------------------------------
    @testset "interp.linear lowers + mtkcompile" begin
        table = Float64[10, 20, 40, 80, 160]
        axis  = Float64[0, 1, 2, 3, 4]
        model = _linear_model(table, axis; x_default=2.5)
        sys   = MTK3.System(model; name=:LinearSmoke)
        @test sys isa MTK3.AbstractSystem
        simp = MTK3.mtkcompile(sys)
        @test simp isa MTK3.AbstractSystem
        # Exactly one state (`y`); structural_simplify did not blow it up
        # into helper observed variables.
        @test length(MTK3.unknowns(simp)) == 1
    end

    # --------------------------------------------------------------
    # 2. interp.bilinear lowers + compiles.
    # --------------------------------------------------------------
    @testset "interp.bilinear lowers + mtkcompile" begin
        table  = [Float64[0, 1, 2], Float64[10, 11, 12], Float64[20, 21, 22]]
        axis_x = Float64[0, 1, 2]
        axis_y = Float64[0, 10, 20]
        model = _bilinear_model(table, axis_x, axis_y; x_default=0.5, y_default=5.0)
        sys   = MTK3.System(model; name=:BilinearSmoke)
        @test sys isa MTK3.AbstractSystem
        simp = MTK3.mtkcompile(sys)
        @test simp isa MTK3.AbstractSystem
        @test length(MTK3.unknowns(simp)) == 1
    end

    # --------------------------------------------------------------
    # 3. Performance: a system with 100+ interp.bilinear calls in
    # the same equation must structural_simplify in ≪ 5s. Without
    # @register_symbolic, each call alias-eliminates into ~10
    # intermediates, and structural_simplify blows up at this scale.
    # --------------------------------------------------------------
    @testset "interp.bilinear opaque under structural_simplify (≥100 calls)" begin
        # 3x3 table per call; 100 distinct calls summed into one RHS.
        N_CALLS = 100
        axis_x = Float64[0, 1, 2]
        axis_y = Float64[0, 10, 20]
        # Each call gets a slightly different table so MTK can't trivially CSE
        # them; the registered op identity-by-(table, axis_x, axis_y, x, y)
        # would fold identical calls otherwise.
        tables = [[[Float64(k), Float64(k + 1), Float64(k + 2)],
                   [Float64(k + 10), Float64(k + 11), Float64(k + 12)],
                   [Float64(k + 20), Float64(k + 21), Float64(k + 22)]]
                  for k in 1:N_CALLS]

        vars = OrderedDict{String,ESM3.ModelVariable}(
            "x" => ESM3.ModelVariable(ESM3.ParameterVariable; default=0.5),
            "y" => ESM3.ModelVariable(ESM3.ParameterVariable; default=5.0),
            "z" => ESM3.ModelVariable(ESM3.StateVariable;     default=0.0),
        )
        # Sum 100 interp.bilinear calls.
        sum_args = ESM3.Expr[]
        for k in 1:N_CALLS
            push!(sum_args, _fn("interp.bilinear",
                _const(tables[k]),
                _const(axis_x), _const(axis_y),
                _v("x"), _v("y")))
        end
        rhs = ESM3.OpExpr("+", sum_args)
        eqs = ESM3.Equation[ESM3.Equation(_op_D("z"), rhs)]
        model = ESM3.Model(vars, eqs)

        sys  = MTK3.System(model; name=:BilinearPerf)
        # Warm-up call to remove first-time MTK compilation costs from the
        # measurement (precompile @register_symbolic dispatch tables, etc.).
        let warm = ESM3.OpExpr("+", ESM3.Expr[
                _fn("interp.bilinear", _const(tables[1]), _const(axis_x),
                    _const(axis_y), _v("x"), _v("y"))])
            wmodel = ESM3.Model(vars,
                ESM3.Equation[ESM3.Equation(_op_D("z"), warm)])
            wsys = MTK3.System(wmodel; name=:BilinearWarm)
            MTK3.mtkcompile(wsys)
        end
        elapsed = @elapsed simp = MTK3.mtkcompile(sys)
        @info "structural_simplify($(N_CALLS) interp.bilinear calls): $(round(elapsed, digits=2))s"
        @test simp isa MTK3.AbstractSystem
        @test length(MTK3.unknowns(simp)) == 1
        # Generous 5s budget per the bead's acceptance criterion. On dev
        # machines this typically completes in well under 1 s.
        @test elapsed < 5.0
    end

end
