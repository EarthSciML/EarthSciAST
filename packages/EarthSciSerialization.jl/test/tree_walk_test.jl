using Test
using EarthSciSerialization
import OrdinaryDiffEqTsit5
import ModelingToolkit

const ESM = EarthSciSerialization
const MTK = ModelingToolkit

# ============================================================
# Small builder helpers — keep the fixtures readable.
# ============================================================
_n(x) = NumExpr(Float64(x))
_i(x) = IntExpr(Int64(x))
_v(n) = VarExpr(n)
_op(op, args...; kw...) = OpExpr(op, ESM.Expr[args...]; kw...)
_D(varname) = _op("D", _v(varname); wrt="t")

# Evaluate an expression via a throw-away build_evaluator call so the
# unit tests exercise the same code path as real ODE solves.
function _eval1(expr::ESM.Expr; u_vals=Dict{String,Float64}(),
                p_vals=Dict{String,Float64}(), t=0.0,
                registered_functions=Dict{String,Function}())
    vars = Dict{String,ModelVariable}()
    # Include all free variables (except "t") either as states or
    # parameters. Free variable names that appear in u_vals → state;
    # those in p_vals → parameter.
    fv = ESM.free_variables(expr)
    for name in fv
        name == "t" && continue
        if haskey(u_vals, name)
            vars[name] = ModelVariable(StateVariable; default=u_vals[name])
        elseif haskey(p_vals, name)
            vars[name] = ModelVariable(ParameterVariable; default=p_vals[name])
        else
            # Default parameter 0.0 (harmless for eval — tests supplying
            # every needed binding won't hit this branch).
            vars[name] = ModelVariable(ParameterVariable; default=0.0)
        end
    end
    # Anchor with a dummy state "_probe" whose derivative = expr so we
    # can read the result out of du[1].
    # Qualify ESM.Equation explicitly: the test suite earlier loads
    # ModelingToolkit (pde_discretize_test), whose `Equation` export shadows
    # ESM's at the Main namespace level under MTK 11.
    vars["_probe"] = ModelVariable(StateVariable; default=0.0)
    eq = ESM.Equation(_D("_probe"), expr)
    model = ESM.Model(vars, [eq])
    f!, u0, p, _tspan, var_map = build_evaluator(model;
        registered_functions=registered_functions)
    # Override state values from u_vals
    for (k, v) in u_vals
        if haskey(var_map, k)
            u0[var_map[k]] = v
        end
    end
    du = similar(u0)
    f!(du, u0, p, t)
    return du[var_map["_probe"]]
end

@testset "tree_walk.jl evaluator (gt-e8yw)" begin

    # ========================================================
    # Scalar op coverage
    # ========================================================
    @testset "Arithmetic ops" begin
        @test _eval1(_op("+", _n(1.0), _n(2.0), _n(3.0))) == 6.0
        @test _eval1(_op("-", _n(5.0), _n(2.0))) == 3.0
        @test _eval1(_op("-", _n(4.0))) == -4.0
        # `neg` is the canonical-form unary negation emitted by
        # `canonicalize` (esm-qrj). `discretize` rewrites `-x` to `neg(x)`.
        @test _eval1(_op("neg", _n(4.0))) == -4.0
        @test _eval1(_op("*", _n(2.0), _n(3.0), _n(4.0))) == 24.0
        @test _eval1(_op("/", _n(10.0), _n(4.0))) == 2.5
        @test _eval1(_op("^", _n(2.0), _n(3.0))) == 8.0
        @test _eval1(_op("pow", _n(2.0), _n(3.0))) == 8.0
    end

    @testset "Integer vs float literals" begin
        @test _eval1(_i(7)) == 7.0
        @test _eval1(_op("+", _i(1), _i(2))) == 3.0
        @test _eval1(_op("*", _i(3), _n(1.5))) == 4.5
    end

    @testset "Comparisons and logical" begin
        @test _eval1(_op("<", _n(1.0), _n(2.0))) == 1.0
        @test _eval1(_op("<=", _n(2.0), _n(2.0))) == 1.0
        @test _eval1(_op(">", _n(1.0), _n(2.0))) == 0.0
        @test _eval1(_op(">=", _n(2.0), _n(1.0))) == 1.0
        @test _eval1(_op("==", _n(1.0), _n(1.0))) == 1.0
        @test _eval1(_op("!=", _n(1.0), _n(2.0))) == 1.0
        @test _eval1(_op("and", _op("<", _n(1.0), _n(2.0)),
                                _op("<", _n(2.0), _n(3.0)))) == 1.0
        @test _eval1(_op("or", _op(">", _n(1.0), _n(2.0)),
                               _op("<", _n(2.0), _n(3.0)))) == 1.0
        @test _eval1(_op("not", _op(">", _n(1.0), _n(2.0)))) == 1.0
    end

    @testset "ifelse, sign, min, max" begin
        @test _eval1(_op("ifelse", _op("<", _n(1.0), _n(2.0)),
                                   _n(10.0), _n(20.0))) == 10.0
        @test _eval1(_op("ifelse", _op(">", _n(1.0), _n(2.0)),
                                   _n(10.0), _n(20.0))) == 20.0
        @test _eval1(_op("sign", _n(-3.0))) == -1.0
        @test _eval1(_op("sign", _n(0.0))) == 0.0
        @test _eval1(_op("sign", _n(42.0))) == 1.0
        @test _eval1(_op("min", _n(3.0), _n(1.0), _n(2.0))) == 1.0
        @test _eval1(_op("max", _n(3.0), _n(5.0), _n(2.0))) == 5.0
    end

    @testset "Elementary functions" begin
        @test _eval1(_op("sin", _n(0.0))) == 0.0
        @test _eval1(_op("cos", _n(0.0))) == 1.0
        @test _eval1(_op("exp", _n(0.0))) == 1.0
        @test _eval1(_op("log", _n(1.0))) == 0.0
        @test _eval1(_op("log10", _n(100.0))) ≈ 2.0
        @test _eval1(_op("sqrt", _n(9.0))) == 3.0
        @test _eval1(_op("abs", _n(-7.5))) == 7.5
        @test _eval1(_op("floor", _n(1.7))) == 1.0
        @test _eval1(_op("ceil", _n(1.3))) == 2.0
        @test _eval1(_op("atan2", _n(1.0), _n(1.0))) ≈ π / 4
    end

    @testset "Time variable and Pre" begin
        @test _eval1(_v("t"); t=3.5) == 3.5
        @test _eval1(_op("Pre", _v("x")); u_vals=Dict("x" => 2.0)) == 2.0
    end

    @testset "Closed function registry (fn op)" begin
        # esm-spec §9.2: `fn` op invokes a name from the closed registry.
        # `datetime.year` returns the proleptic-Gregorian year (Int32, lifted
        # to Float64 by tree_walk).
        # 2026-01-01T00:00:00Z = 1767225600 seconds since epoch.
        expr_year = _op("fn", _n(1767225600.0); name="datetime.year")
        @test _eval1(expr_year) == 2026.0

        # `interp.searchsorted` with const-array second arg.
        const_xs = OpExpr("const", ESM.Expr[]; value=[1.0, 2.0, 3.0, 4.0, 5.0])
        expr_ss = _op("fn", _n(2.5), const_xs; name="interp.searchsorted")
        @test _eval1(expr_ss) == 3.0  # smallest 1-based i with xs[i] >= 2.5

        # Unknown closed-function name → TreeWalkError.
        bad = _op("fn", _n(1.0); name="datetime.century")
        @test_throws ESM.TreeWalkError _eval1(bad)

        # Removed `call` op fails compile.
        @test_throws ESM.TreeWalkError _eval1(_op("call", _n(1.0); handler_id="x"))
    end

    @testset "Graceful errors on unsupported ops" begin
        @test_throws ESM.TreeWalkError _eval1(_op("wibble", _n(1.0)))
        @test_throws ESM.TreeWalkError _eval1(_op("arrayop", _n(1.0)))
        @test_throws ESM.TreeWalkError _eval1(_op("grad", _v("x");
                                                  dim="x");
                                               u_vals=Dict("x" => 1.0))
        # D in RHS is an error (LHS-only marker).
        @test_throws ESM.TreeWalkError _eval1(_op("*", _n(1.0),
                                                 _op("D", _v("x"); wrt="t"));
                                              u_vals=Dict("x" => 1.0))
    end

    @testset "unlowered rewrite-target op surfaced before evaluation" begin
        # grad/div/laplacian are rewrite-target sugar (esm-spec §4.2 / §9.6.8),
        # NOT evaluable-core ops. One that reaches the compiler unlowered (no
        # discretization rule matched) must be rejected with the uniform
        # `unlowered_operator` code — never silently evaluated to zero (the
        # historical stub-to-zero pattern in other bindings). The gate fires
        # before evaluation. Supersedes the old E_TREEWALK_UNREACHABLE_SPATIAL_OP.
        for opname in ("grad", "div", "laplacian")
            err = try
                _eval1(_op(opname, _v("x"); dim="x");
                       u_vals=Dict("x" => 1.0))
                nothing
            catch e
                e
            end
            @test err isa ESM.TreeWalkError
            @test err.code == "unlowered_operator"
            @test occursin(opname, err.detail)
            @test occursin("unlowered", err.detail)
        end
    end

    # ========================================================
    # Observed variable inlining
    # ========================================================
    @testset "Observed variable inlining" begin
        vars = Dict{String,ModelVariable}(
            "x" => ModelVariable(StateVariable; default=1.0),
            "k" => ModelVariable(ParameterVariable; default=0.5),
            "y" => ModelVariable(ObservedVariable),
        )
        # y = 2*k; D(x) = -y*x
        eqs = [
            ESM.Equation(_v("y"), _op("*", _n(2.0), _v("k"))),
            ESM.Equation(_D("x"), _op("-", _op("*", _v("y"), _v("x")))),
        ]
        model = ESM.Model(vars, eqs)
        f!, u0, p, _tspan, var_map = build_evaluator(model)
        du = similar(u0)
        f!(du, u0, p, 0.0)
        # D(x) = -(2 * 0.5 * 1.0) = -1.0
        @test du[var_map["x"]] == -1.0
    end

    # ========================================================
    # Full solve: exponential decay
    # ========================================================
    @testset "Exponential decay solve" begin
        vars = Dict{String,ModelVariable}(
            "x" => ModelVariable(StateVariable; default=1.0),
            "k" => ModelVariable(ParameterVariable; default=0.1),
        )
        eq = ESM.Equation(_D("x"), _op("*", _op("-", _v("k")), _v("x")))
        model = ESM.Model(vars, [eq])
        f!, u0, p, _tspan, var_map = build_evaluator(model)
        prob = OrdinaryDiffEqTsit5.ODEProblem(f!, u0, (0.0, 10.0), p)
        sol = OrdinaryDiffEqTsit5.solve(prob, OrdinaryDiffEqTsit5.Tsit5();
                                        reltol=1e-8, abstol=1e-10)
        @test isapprox(sol.u[end][var_map["x"]], exp(-1.0); rtol=1e-6)
    end

    # ========================================================
    # Default tspan from inline tests block
    # ========================================================
    @testset "tspan picked from tests block" begin
        vars = Dict{String,ModelVariable}(
            "x" => ModelVariable(StateVariable; default=1.0),
            "k" => ModelVariable(ParameterVariable; default=0.1),
        )
        eq = ESM.Equation(_D("x"), _op("*", _op("-", _v("k")), _v("x")))
        tests = [ESM.Test("default_span",
                       ESM.TimeSpan(0.0, 25.0),
                       ESM.Assertion[]; description="default")]
        model = ESM.Model(vars, [eq]; tests=tests)
        _, _, _, tspan_default, _ = build_evaluator(model)
        @test tspan_default == (0.0, 25.0)
    end

    # ========================================================
    # 1D heat (20 cells, Dirichlet BC 0/0) — converges to zero
    # ========================================================
    @testset "1D heat (Dirichlet, 20 cells) → steady state" begin
        N = 20
        dx = 1.0 / (N + 1)
        α = 0.5
        vars = Dict{String,ModelVariable}()
        eqs = ESM.Equation[]
        for i in 1:N
            name = "u_$i"
            # Initial: sin(π x_i). Interior i=1..N, x_i = i*dx.
            u0_i = sinpi(i * dx)
            vars[name] = ModelVariable(StateVariable; default=u0_i)
        end
        vars["alpha"] = ModelVariable(ParameterVariable; default=α)
        # Build centered-difference RHS equations. Left/right neighbours
        # inlined as 0.0 at the Dirichlet boundary.
        for i in 1:N
            here = _v("u_$i")
            left = i == 1 ? _n(0.0) : _v("u_$(i-1)")
            right = i == N ? _n(0.0) : _v("u_$(i+1)")
            lap_num = _op("+",
                _op("-", left, here),      # left - here
                _op("-", right, here))     # + right - here
            # α * (left - 2*here + right) / dx^2
            rhs = _op("*",
                _v("alpha"),
                _op("/", lap_num, _n(dx^2)))
            push!(eqs, ESM.Equation(_D("u_$i"), rhs))
        end
        model = ESM.Model(vars, eqs)
        f!, u0, p, _tspan, var_map = build_evaluator(model)
        # Diffusion time ~ L² / α = 1 / 0.5 = 2. Integrate to t = 5.
        prob = OrdinaryDiffEqTsit5.ODEProblem(f!, u0, (0.0, 5.0), p)
        sol = OrdinaryDiffEqTsit5.solve(prob, OrdinaryDiffEqTsit5.Tsit5();
                                        reltol=1e-8, abstol=1e-10)
        # Analytical: u(x,t) = sin(π x) exp(-α π² t). At t=5:
        #   exp(-0.5 * π² * 5) ≈ 1.6e-11 → essentially zero.
        for i in 1:N
            @test abs(sol.u[end][var_map["u_$i"]]) < 1e-6
        end
    end

    # ========================================================
    # MTK parity — 1D heat (10 cells) compared to MTK-codegen
    # ========================================================
    @testset "MTK parity — random f! samples match" begin
        N = 10
        dx = 1.0 / (N + 1)
        α = 0.75
        vars = Dict{String,ModelVariable}()
        eqs = ESM.Equation[]
        for i in 1:N
            vars["u_$i"] = ModelVariable(StateVariable; default=sinpi(i * dx))
        end
        vars["alpha"] = ModelVariable(ParameterVariable; default=α)
        for i in 1:N
            here = _v("u_$i")
            left = i == 1 ? _n(0.0) : _v("u_$(i-1)")
            right = i == N ? _n(0.0) : _v("u_$(i+1)")
            rhs = _op("*",
                _v("alpha"),
                _op("/",
                    _op("+", _op("-", left, here), _op("-", right, here)),
                    _n(dx^2)))
            push!(eqs, ESM.Equation(_D("u_$i"), rhs))
        end
        model = ESM.Model(vars, eqs)

        # Tree-walk path
        f_tw!, u0_tw, p_tw, _tspan, var_map = build_evaluator(model)

        # MTK path
        sys = MTK.System(model; name=:HeatParity)
        simp = MTK.mtkcompile(sys)
        prob_mtk = MTK.ODEProblem(simp, Dict{Any,Any}(), (0.0, 1.0))
        f_mtk = prob_mtk.f
        u0_mtk = prob_mtk.u0
        p_mtk = prob_mtk.p

        # The two paths may order states differently. Build a
        # permutation mapping tree-walk index → MTK index by matching
        # variable names (simp's unknown ending in "_u_i" matches our
        # "u_i" in var_map).
        mtk_unknowns = MTK.unknowns(simp)
        mtk_name_to_idx = Dict{String,Int}()
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
                @test isapprox(du_tw[idx_tw], du_mtk[idx_mtk]; rtol=1e-12)
            end
        end
    end

    # ========================================================
    # Dict entry point — full simple decay from an in-memory dict
    # ========================================================
    @testset "Dict entry point (simple_ode style)" begin
        esm = Dict(
            "esm" => "0.2.0",
            "metadata" => Dict("name" => "DecayDict"),
            "models" => Dict(
                "Decay" => Dict(
                    "variables" => Dict(
                        "N" => Dict("type" => "state", "default" => 100.0),
                        "lambda" => Dict("type" => "parameter", "default" => 0.1),
                    ),
                    "equations" => [Dict(
                        "lhs" => Dict("op" => "D", "args" => ["N"], "wrt" => "t"),
                        "rhs" => Dict("op" => "*",
                                      "args" => [Dict("op" => "-", "args" => ["lambda"]),
                                                 "N"]),
                    )],
                ),
            ),
        )
        f!, u0, p, _tspan, var_map = build_evaluator(esm)
        prob = OrdinaryDiffEqTsit5.ODEProblem(f!, u0, (0.0, 10.0), p)
        sol = OrdinaryDiffEqTsit5.solve(prob, OrdinaryDiffEqTsit5.Tsit5();
                                        reltol=1e-8, abstol=1e-10)
        @test isapprox(sol.u[end][var_map["N"]], 100.0 * exp(-1.0); rtol=1e-6)
    end

    # ========================================================
    # 2D advection 64×64 = 4096 scalar eqs (bead acceptance #2)
    # Periodic BC, constant velocity, upwind first-order.
    # ========================================================
    @testset "Large 2D advection (64×64, periodic BC) — build+solve time" begin
        Nx, Ny = 64, 64
        dx = 1.0 / Nx
        dy = 1.0 / Ny
        vx, vy = 1.0, 0.5
        vars = Dict{String,ModelVariable}()
        eqs = ESM.Equation[]
        # Initial condition: a single bump at (0.5, 0.5).
        for i in 1:Nx, j in 1:Ny
            x = (i - 0.5) * dx
            y = (j - 0.5) * dy
            u0 = exp(-((x - 0.5)^2 + (y - 0.5)^2) / 0.02)
            vars["u_$(i)_$(j)"] = ModelVariable(StateVariable; default=u0)
        end
        vars["vx"] = ModelVariable(ParameterVariable; default=vx)
        vars["vy"] = ModelVariable(ParameterVariable; default=vy)
        # Wrap indices (periodic BC).
        wrap(k, N) = k < 1 ? N : (k > N ? 1 : k)
        for i in 1:Nx, j in 1:Ny
            here = _v("u_$(i)_$(j)")
            # Upwind: velocities > 0 so use left/below neighbours.
            left = _v("u_$(wrap(i - 1, Nx))_$(j)")
            below = _v("u_$(i)_$(wrap(j - 1, Ny))")
            flux_x = _op("*", _v("vx"),
                         _op("/", _op("-", here, left), _n(dx)))
            flux_y = _op("*", _v("vy"),
                         _op("/", _op("-", here, below), _n(dy)))
            # D(u_ij)/dt = -(flux_x + flux_y)  (continuity form)
            rhs = _op("-", _op("+", flux_x, flux_y))
            push!(eqs, ESM.Equation(_D("u_$(i)_$(j)"), rhs))
        end
        model = ESM.Model(vars, eqs)
        # Build acceptance: < 5 s wall-clock.
        t_build = @elapsed begin
            f!, u0, p, _tspan, var_map = build_evaluator(model)
        end
        @test t_build < 5.0
        @test length(u0) == Nx * Ny

        # Step the integrator 100 times and time that specifically
        # (avoids Tsit5's auto-step-size from inflating or shrinking
        # the "100 steps" count).
        tspan_adv = (0.0, 100 * min(dx / vx, dy / vy))
        prob = OrdinaryDiffEqTsit5.ODEProblem(f!, u0, tspan_adv, p)
        integrator = OrdinaryDiffEqTsit5.init(prob, OrdinaryDiffEqTsit5.Tsit5();
            reltol=1e-4, abstol=1e-6, save_everystep=false)
        t_solve = @elapsed for _ in 1:100
            OrdinaryDiffEqTsit5.step!(integrator)
        end
        # Acceptance target is 10 s on commodity hardware. CI runners
        # can be 2–3× slower than a laptop, so the ceiling is padded.
        # The underlying contract is that scale is independent of
        # compile time — build was already asserted < 5 s above.
        @test t_solve < 30.0
        # Mass should be ~conserved under periodic BC. First-order
        # upwind introduces numerical diffusion but the total mass
        # telescopes exactly in the continuous scheme — the integrator
        # error is what loosens the bound.
        @test isapprox(sum(integrator.u), sum(u0); rtol=5e-3)
    end

    # ========================================================
    # Performance proxy — 1024 diagonal states build quickly
    # ========================================================
    @testset "Large diagonal system (1024 states) — build + evaluate" begin
        N = 1024
        vars = Dict{String,ModelVariable}()
        eqs = ESM.Equation[]
        for i in 1:N
            vars["u_$i"] = ModelVariable(StateVariable; default=0.1)
        end
        vars["alpha"] = ModelVariable(ParameterVariable; default=1.0)
        for i in 1:N
            push!(eqs, ESM.Equation(_D("u_$i"),
                _op("-", _op("*", _v("alpha"), _v("u_$i")))))
        end
        model = ESM.Model(vars, eqs)
        t_build = @elapsed begin
            f!, u0, p, _tspan, var_map = build_evaluator(model)
        end
        @test t_build < 5.0
        du = similar(u0)
        f!(du, u0, p, 0.0)
        @test all(du .≈ -0.1)
    end
end
