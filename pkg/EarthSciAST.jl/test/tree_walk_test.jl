using Test
using EarthSciAST
import OrdinaryDiffEqTsit5

include("testutils.jl")  # _n/_i/_v/_op/_idx builder quartet + repo root

const ESM = EarthSciAST

# Evaluate an expression via a throw-away build so the unit tests exercise
# the same code path as real ODE solves.
function _eval1(
        expr::ESM.ASTExpr; u_vals = Dict{String, Float64}(),
        p_vals = Dict{String, Float64}(), t = 0.0
    )
    vars = Dict{String, ModelVariable}()
    # Include all free variables (except "t") either as states or
    # parameters. Free variable names that appear in u_vals → state;
    # those in p_vals → parameter.
    fv = ESM.free_variables(expr)
    for name in fv
        name == "t" && continue
        if haskey(u_vals, name)
            vars[name] = ModelVariable(UnknownVariable; default = u_vals[name])
        elseif haskey(p_vals, name)
            vars[name] = ModelVariable(ParameterVariable; default = p_vals[name])
        else
            # Default parameter 0.0 (harmless for eval — tests supplying
            # every needed binding won't hit this branch).
            vars[name] = ModelVariable(ParameterVariable; default = 0.0)
        end
    end
    # Anchor with a dummy state "_probe" whose derivative = expr so we
    # can read the result out of du[1].
    # Qualify ESM.Equation explicitly: in a session that also has
    # ModelingToolkit loaded (the ModelingToolkit suite in test/mtk/), its
    # `Equation` export shadows ESM's at the Main namespace level under MTK 11.
    vars["_probe"] = ModelVariable(UnknownVariable; default = 0.0)
    eq = ESM.Equation(_D("_probe"), expr)
    model = ESM.Model(vars, [eq])
    f!, u0, p, _tspan, var_map = EarthSciAST.Internal.build(
        model
    )
    # Override state values from u_vals
    for (k, v) in u_vals
        if haskey(var_map, "M.$k")
            u0[var_map["M.$k"]] = v
        end
    end
    du = similar(u0)
    f!(du, u0, p, t)
    return du[var_map["M._probe"]]
end

@testset "tree_walk.jl evaluator" begin

    # ========================================================
    # Scalar op coverage
    # ========================================================
    #
    # The op-by-op VALUE tests — arithmetic, integer vs float literals,
    # comparisons and logic, `ifelse`/`sign`/`min`/`max`, and the elementary
    # functions — live in the cross-binding
    # `tests/conformance/scalar_operator_semantics/` tier (CONFORMANCE_SPEC
    # §5.45.4), which pins every one of them at EXACT tolerance and which
    # `scripts/test-conformance.sh` runs for julia, rust and python under both
    # `interpreter` and `native`.
    #
    # Private per-binding op tables with no cross-binding gate let bindings
    # disagree unnoticed. The known gaps — Julia has an evaluation rule for the
    # `true` literal op and NONE for `false`; Rust refuses `pow` and `false`
    # outright and cannot lower `true` under `native` — are recorded as named
    # exclusions in that tier.
    #
    # What stays below is everything a document cannot state: the closed-function
    # registry, the unsupported-op diagnostics, observed inlining and cycle
    # detection, and the solves. The ModelingToolkit parity sampling is
    # test/mtk/tree_walk_mtk_parity_test.jl, in the separate ModelingToolkit suite.

    @testset "Time variable and Pre" begin
        @test _eval1(_v("t"); t = 3.5) == 3.5
        @test _eval1(_op("Pre", _v("x")); u_vals = Dict("x" => 2.0)) == 2.0
    end

    @testset "removed `call` op is refused" begin
        # A load refuses it by name; a tree built in memory reaches the build,
        # whose operator gate refuses it.
        err = try
            _eval1(_op("call", _n(1.0)))
            nothing
        catch e
            e
        end
        @test err isa ESM.TreeWalkError && err.code == "unlowered_operator" &&
            occursin("'call'", sprint(showerror, err))
    end

    @testset "Graceful errors on unsupported ops" begin
        # `wibble` is an unregistered open-tier op: it now surfaces as
        # `unlowered_operator` (asserted precisely in the gate testset below),
        # NOT `unevaluable_operator` — both are `TreeWalkError`. `faq`
        # is a registered non-scalar CORE form and reports
        # `unevaluable_operator` (esm-spec §9.6.6).
        @test_throws ESM.TreeWalkError _eval1(_op("wibble", _n(1.0)))
        @test_throws ESM.TreeWalkError _eval1(_op("faq", _n(1.0)))
        @test_throws ESM.TreeWalkError _eval1(
            _op(
                "D", _v("x");
                wrt = "x"
            );
            u_vals = Dict("x" => 1.0)
        )
        # D in RHS is an error (LHS-only marker).
        @test_throws ESM.TreeWalkError _eval1(
            _op(
                "*", _n(1.0),
                _op("D", _v("x"); wrt = "t")
            );
            u_vals = Dict("x" => 1.0)
        )
    end

    @testset "unlowered rewrite-target op surfaced before evaluation" begin
        # A spatial `D` is a rewrite target (esm-spec §4.2 / §9.6.8), NOT an
        # evaluable-core op. One that reaches the compiler unlowered (no
        # discretization rule matched) must be rejected with the uniform
        # `unlowered_operator` code — never silently evaluated to zero (the
        # historical stub-to-zero pattern in other bindings). The gate fires
        # before evaluation. Supersedes the old E_TREEWALK_UNREACHABLE_SPATIAL_OP.
        for wrt in ("x", "y")
            err = try
                _eval1(
                    _op("D", _v("x"); wrt = wrt);
                    u_vals = Dict("x" => 1.0)
                )
                nothing
            catch e
                e
            end
            @test err isa ESM.TreeWalkError
            @test err.code == "unlowered_operator"
            @test occursin("wrt=$(wrt)", err.detail)
            @test occursin("unlowered", err.detail)
        end
        # The gate is GENERIC, not an op-name list: an arbitrary
        # OPEN-TIER user op (no evaluable-core registry entry) reaching the
        # compiler is the SAME violation and gets the SAME `unlowered_operator`
        # code — NOT `unevaluable_operator` (esm-spec §4.2 / §9.6.6 uniform
        # rule; mirrors the other bindings). Decided by the `_op_in_T` tier
        # predicate.
        # (`integral` is also in T but carries its OWN earlier
        # structural handling in resolve.jl, so they never reach this gate.)
        for opname in ("godunov_hamiltonian", "my_custom_flux")
            err = try
                _eval1(_op(opname, _v("x")); u_vals = Dict("x" => 1.0))
                nothing
            catch e
                e
            end
            @test err isa ESM.TreeWalkError
            @test err.code == "unlowered_operator"
            @test err.code != "unevaluable_operator"
            @test occursin(opname, err.detail)
        end
    end

    # ========================================================
    # Observed variable inlining
    # ========================================================
    @testset "Observed variable inlining" begin
        vars = Dict{String, ModelVariable}(
            "x" => ModelVariable(UnknownVariable; default = 1.0),
            "k" => ModelVariable(ParameterVariable; default = 0.5),
            "y" => ModelVariable(UnknownVariable),
        )
        # y = 2*k; D(x) = -y*x
        eqs = [
            ESM.Equation(_v("y"), _op("*", _n(2.0), _v("k"))),
            ESM.Equation(_D("x"), _op("-", _op("*", _v("y"), _v("x")))),
        ]
        model = ESM.Model(vars, eqs)
        f!, u0, p, _tspan, var_map = EarthSciAST.Internal.build(model)
        du = similar(u0)
        f!(du, u0, p, 0.0)
        # D(x) = -(2 * 0.5 * 1.0) = -1.0
        @test du[var_map["M.x"]] == -1.0
    end

    # ========================================================
    # Observed-into-observed chains resolve to a fixed point in dependency
    # (topological) order, and a CYCLE is a clean build error — never an
    # infinite substitution loop or a silently-truncated body. `_resolve_observed`
    # caps the fixed-point iteration at the longest possible acyclic chain, so
    # exceeding it can only mean a cycle.
    # ========================================================
    @testset "Observed dependency chains and cycle detection" begin
        # Acyclic chain c → b → a: `_resolve_observed` must fully collapse it,
        # regardless of the order the equations are declared in (the Dict/loop
        # order is not the dependency order).
        vars = Dict{String, ModelVariable}(
            "x" => ModelVariable(UnknownVariable; default = 1.0),
            "k" => ModelVariable(ParameterVariable; default = 2.0),
            "a" => ModelVariable(UnknownVariable),
            "b" => ModelVariable(UnknownVariable),
            "c" => ModelVariable(UnknownVariable),
        )
        # c = b + 1; b = a * a; a = k;  D(x) = c * x  →  (2*2 + 1) * 1 = 5
        eqs = [
            ESM.Equation(_v("c"), _op("+", _v("b"), _n(1.0))),
            ESM.Equation(_v("b"), _op("*", _v("a"), _v("a"))),
            ESM.Equation(_v("a"), _v("k")),
            ESM.Equation(_D("x"), _op("*", _v("c"), _v("x"))),
        ]
        f!, u0, p, _tspan, var_map = EarthSciAST.Internal.build(ESM.Model(vars, eqs))
        du = similar(u0)
        f!(du, u0, p, 0.0)
        @test du[var_map["M.x"]] === (2.0 * 2.0 + 1.0) * 1.0

        # Cyclic: a = b + 1; b = a + 1. Must throw, not hang.
        cyc_vars = Dict{String, ModelVariable}(
            "x" => ModelVariable(UnknownVariable; default = 1.0),
            "a" => ModelVariable(UnknownVariable),
            "b" => ModelVariable(UnknownVariable),
        )
        cyc_eqs = [
            ESM.Equation(_v("a"), _op("+", _v("b"), _n(1.0))),
            ESM.Equation(_v("b"), _op("+", _v("a"), _n(1.0))),
            ESM.Equation(_D("x"), _v("a")),
        ]
        err = try
            EarthSciAST.Internal.build(ESM.Model(cyc_vars, cyc_eqs))
            nothing
        catch e
            e
        end
        @test err isa ESM.TreeWalkError
        @test err.code == "E_TREEWALK_OBSERVED_CYCLE"
    end

    # ========================================================
    # Full solve: exponential decay
    # ========================================================
    @testset "Exponential decay solve" begin
        vars = Dict{String, ModelVariable}(
            "x" => ModelVariable(UnknownVariable; default = 1.0),
            "k" => ModelVariable(ParameterVariable; default = 0.1),
        )
        eq = ESM.Equation(_D("x"), _op("*", _op("-", _v("k")), _v("x")))
        model = ESM.Model(vars, [eq])
        f!, u0, p, _tspan, var_map = EarthSciAST.Internal.build(model)
        prob = OrdinaryDiffEqTsit5.ODEProblem(f!, u0, (0.0, 10.0), p)
        sol = OrdinaryDiffEqTsit5.solve(
            prob, OrdinaryDiffEqTsit5.Tsit5();
            reltol = 1.0e-8, abstol = 1.0e-10
        )
        @test isapprox(sol.u[end][var_map["M.x"]], exp(-1.0); rtol = 1.0e-6)
    end

    # ========================================================
    # Default tspan from inline tests block
    # ========================================================
    @testset "an inline test's time span is not the build's default" begin
        vars = Dict{String, ModelVariable}(
            "x" => ModelVariable(UnknownVariable; default = 1.0),
            "k" => ModelVariable(ParameterVariable; default = 0.1),
        )
        eq = ESM.Equation(_D("x"), _op("*", _op("-", _v("k")), _v("x")))
        tests = [
            ESM.InlineTest(
                "default_span",
                ESM.TimeSpan(0.0, 25.0),
                ESM.Assertion[]; description = "default"
            ),
        ]
        model = ESM.Model(vars, [eq]; tests = tests)
        _, _, _, tspan_default, _ = EarthSciAST.Internal.build(model)
        # A build's default span is (0.0, 1.0); an inline test passes its own.
        @test tspan_default == (0.0, 1.0)
    end

    # ========================================================
    # 1D heat (20 cells, Dirichlet BC 0/0) — converges to zero
    # ========================================================
    @testset "1D heat (Dirichlet, 20 cells) → steady state" begin
        N = 20
        dx = 1.0 / (N + 1)
        α = 0.5
        vars = Dict{String, ModelVariable}()
        eqs = ESM.Equation[]
        for i in 1:N
            name = "u_$i"
            # Initial: sin(π x_i). Interior i=1..N, x_i = i*dx.
            u0_i = sinpi(i * dx)
            vars[name] = ModelVariable(UnknownVariable; default = u0_i)
        end
        vars["alpha"] = ModelVariable(ParameterVariable; default = α)
        # Build centered-difference RHS equations. Left/right neighbours
        # inlined as 0.0 at the Dirichlet boundary.
        for i in 1:N
            here = _v("u_$i")
            left = i == 1 ? _n(0.0) : _v("u_$(i - 1)")
            right = i == N ? _n(0.0) : _v("u_$(i + 1)")
            lap_num = _op(
                "+",
                _op("-", left, here),      # left - here
                _op("-", right, here)
            )     # + right - here
            # α * (left - 2*here + right) / dx^2
            rhs = _op(
                "*",
                _v("alpha"),
                _op("/", lap_num, _n(dx^2))
            )
            push!(eqs, ESM.Equation(_D("u_$i"), rhs))
        end
        model = ESM.Model(vars, eqs)
        f!, u0, p, _tspan, var_map = EarthSciAST.Internal.build(model)
        # Diffusion time ~ L² / α = 1 / 0.5 = 2. Integrate to t = 5.
        prob = OrdinaryDiffEqTsit5.ODEProblem(f!, u0, (0.0, 5.0), p)
        sol = OrdinaryDiffEqTsit5.solve(
            prob, OrdinaryDiffEqTsit5.Tsit5();
            reltol = 1.0e-8, abstol = 1.0e-10
        )
        # Analytical: u(x,t) = sin(π x) exp(-α π² t). At t=5:
        #   exp(-0.5 * π² * 5) ≈ 1.6e-11 → essentially zero.
        for i in 1:N
            @test abs(sol.u[end][var_map["M.u_$i"]]) < 1.0e-6
        end
    end

    # ========================================================
    # Dict entry point — full simple decay from an in-memory dict
    # ========================================================
    @testset "Dict entry point (simple_ode style)" begin
        esm = Dict(
            "esm" => "2.0.0",
            "metadata" => Dict("name" => "DecayDict"),
            "models" => Dict(
                "Decay" => Dict(
                    "variables" => Dict(
                        "N" => Dict("type" => "unknown", "default" => 100.0),
                        "lambda" => Dict("type" => "parameter", "default" => 0.1),
                    ),
                    "equations" => [
                        Dict(
                            "lhs" => Dict("op" => "D", "args" => ["N"], "wrt" => "t"),
                            "rhs" => Dict(
                                "op" => "*",
                                "args" => [
                                    Dict("op" => "-", "args" => ["lambda"]),
                                    "N",
                                ]
                            ),
                        ),
                    ],
                ),
            ),
        )
        f!, u0, p, _tspan, var_map = EarthSciAST.Internal.build(esm)
        prob = OrdinaryDiffEqTsit5.ODEProblem(f!, u0, (0.0, 10.0), p)
        sol = OrdinaryDiffEqTsit5.solve(
            prob, OrdinaryDiffEqTsit5.Tsit5();
            reltol = 1.0e-8, abstol = 1.0e-10
        )
        @test isapprox(sol.u[end][var_map["Decay.N"]], 100.0 * exp(-1.0); rtol = 1.0e-6)
    end

    # ========================================================
    # 2D advection 64×64 = 4096 scalar equations
    # Periodic BC, constant velocity, upwind first-order.
    # ========================================================
    @testset "Large 2D advection (64×64, periodic BC) — build size and mass conservation" begin
        Nx, Ny = 64, 64
        dx = 1.0 / Nx
        dy = 1.0 / Ny
        vx, vy = 1.0, 0.5
        vars = Dict{String, ModelVariable}()
        eqs = ESM.Equation[]
        # Initial condition: a single bump at (0.5, 0.5).
        for i in 1:Nx, j in 1:Ny
            x = (i - 0.5) * dx
            y = (j - 0.5) * dy
            u0 = exp(-((x - 0.5)^2 + (y - 0.5)^2) / 0.02)
            vars["u_$(i)_$(j)"] = ModelVariable(UnknownVariable; default = u0)
        end
        vars["vx"] = ModelVariable(ParameterVariable; default = vx)
        vars["vy"] = ModelVariable(ParameterVariable; default = vy)
        # Wrap indices (periodic BC).
        wrap(k, N) = k < 1 ? N : (k > N ? 1 : k)
        for i in 1:Nx, j in 1:Ny
            here = _v("u_$(i)_$(j)")
            # Upwind: velocities > 0 so use left/below neighbours.
            left = _v("u_$(wrap(i - 1, Nx))_$(j)")
            below = _v("u_$(i)_$(wrap(j - 1, Ny))")
            flux_x = _op(
                "*", _v("vx"),
                _op("/", _op("-", here, left), _n(dx))
            )
            flux_y = _op(
                "*", _v("vy"),
                _op("/", _op("-", here, below), _n(dy))
            )
            # D(u_ij)/dt = -(flux_x + flux_y)  (continuity form)
            rhs = _op("-", _op("+", flux_x, flux_y))
            push!(eqs, ESM.Equation(_D("u_$(i)_$(j)"), rhs))
        end
        model = ESM.Model(vars, eqs)
        # One scalar equation per cell: the build's size is the model's.
        f!, u0, p, _tspan, var_map, rep = EarthSciAST.Internal.build(model)
        @test rep.stats.n_scalar_entries == Nx * Ny
        @test length(u0) == Nx * Ny

        # Step the integrator 100 times and time that specifically
        # (avoids Tsit5's auto-step-size from inflating or shrinking
        # the "100 steps" count).
        tspan_adv = (0.0, 100 * min(dx / vx, dy / vy))
        prob = OrdinaryDiffEqTsit5.ODEProblem(f!, u0, tspan_adv, p)
        integrator = OrdinaryDiffEqTsit5.init(
            prob, OrdinaryDiffEqTsit5.Tsit5();
            reltol = 1.0e-4, abstol = 1.0e-6, save_everystep = false
        )
        t_solve = @elapsed for _ in 1:100
            OrdinaryDiffEqTsit5.step!(integrator)
        end
        # A hang guard, not a performance bound.
        @test t_solve < 30.0
        # Mass should be ~conserved under periodic BC. First-order
        # upwind introduces numerical diffusion but the total mass
        # telescopes exactly in the continuous scheme — the integrator
        # error is what loosens the bound.
        @test isapprox(sum(integrator.u), sum(u0); rtol = 5.0e-3)
    end

    # ========================================================
    # 1024 diagonal states: one right-hand-side entry each
    # ========================================================
    @testset "Large diagonal system (1024 states) — build + evaluate" begin
        N = 1024
        vars = Dict{String, ModelVariable}()
        eqs = ESM.Equation[]
        for i in 1:N
            vars["u_$i"] = ModelVariable(UnknownVariable; default = 0.1)
        end
        vars["alpha"] = ModelVariable(ParameterVariable; default = 1.0)
        for i in 1:N
            push!(
                eqs, ESM.Equation(
                    _D("u_$i"),
                    _op("-", _op("*", _v("alpha"), _v("u_$i")))
                )
            )
        end
        model = ESM.Model(vars, eqs)
        f!, u0, p, _tspan, var_map, rep = EarthSciAST.Internal.build(model)
        @test rep.stats.n_scalar_entries == N
        du = similar(u0)
        f!(du, u0, p, 0.0)
        @test all(du .≈ -0.1)
    end
end

@testset "derivative-equation compile refuses an equation of another shape" begin
    # Every caller hands only D(x), D(index(x, …)) or a faq over D(index(x, …));
    # anything else is refused, never dropped.
    eq = ESM.Equation(ESM.VarExpr("y"), ESM.NumExpr(1.0))
    err = try
        ESM._compile_derivative_equations(
            ESM.Equation[eq], Dict{String, ESM.ASTExpr}(),
            ESM._CompileScope(
                Dict{String, Tuple{Vector{Int}, Vector{Int}}}(), Dict{String, Int}("y" => 1),
                Dict{String, Any}(), Dict{String, Any}(), Dict{Symbol, Int}()
            ), 1
        )
        nothing
    catch e
        e
    end
    @test err isa ESM.TreeWalkError && err.code == "E_TREEWALK_UNSUPPORTED_LHS"
end

@testset "initial_conditions keys must name a state element" begin
    vars = Dict("x" => ModelVariable(UnknownVariable; default = 1.0))
    model = ESM.Model(vars, [ESM.Equation(_op("D", _v("x"); wrt = "t"), ESM.NumExpr(0.0))])
    err = try
        EarthSciAST.Internal.build(model; initial_conditions = Dict("M.nope" => 2.0))
        nothing
    catch e
        e
    end
    @test err isa ESM.TreeWalkError && err.code == "E_TREEWALK_UNKNOWN_STATE"
    _, u0, _, _, vm = EarthSciAST.Internal.build(model; initial_conditions = Dict("M.x" => 2.0))
    @test u0[vm["M.x"]] == 2.0
end

@testset "a whole-array initial_conditions key sets every cell" begin
    vars = Dict("u" => ModelVariable(UnknownVariable; shape = ["i"]))
    lhs = ESM.OpExpr(
        "faq", ESM.ASTExpr[]; output_idx = Any["i"], ranges = Dict("i" => [1, 3]),
        expr_body = _op("D", _op("index", _v("u"), _v("i")); wrt = "t")
    )
    rhs = ESM.OpExpr(
        "faq", ESM.ASTExpr[]; output_idx = Any["i"], ranges = Dict("i" => [1, 3]),
        expr_body = ESM.NumExpr(0.0)
    )
    model = ESM.Model(vars, [ESM.Equation(lhs, rhs)])
    _, u0, _, _, vm = EarthSciAST.Internal.build(
        model; initial_conditions = Dict("M.u" => 1.5, "M.u[2]" => 4.0)
    )
    @test [u0[vm["M.u[$k]"]] for k in 1:3] == [1.5, 4.0, 1.5]
end
