using Test
using EarthSciAST
using OrderedCollections: OrderedDict
import ModelingToolkit
import Symbolics
import OrdinaryDiffEqTsit5
import OrdinaryDiffEqRosenbrock

const ESM = EarthSciAST
const MTK = ModelingToolkit

# Resolve a completed MTK system's unknown by its sanitized name suffix
# (e.g. `"x"` matches `Decay_x` or `ExponentialDecay_N`). Returns the
# symbolic handle suitable for `sol[handle]` indexing.
function _find_unknown(sys, suffix::AbstractString)
    for u in MTK.unknowns(sys)
        nm = string(MTK.getname(u))
        if endswith(nm, "_" * suffix) || nm == suffix
            return u
        end
    end
    error("No unknown with suffix $(suffix) in $(MTK.unknowns(sys))")
end

function _solve_ode(model::ESM.Model, name::Symbol, tspan::Tuple{Float64,Float64};
                    solver=OrdinaryDiffEqTsit5.Tsit5(),
                    reltol=1e-8, abstol=1e-10, kwargs...)
    sys = MTK.System(model; name=name)
    simp = MTK.mtkcompile(sys)
    prob = MTK.ODEProblem(simp, Dict{Any,Any}(), tspan)
    sol = OrdinaryDiffEqTsit5.solve(prob, solver; reltol=reltol, abstol=abstol, kwargs...)
    return sol, simp
end

@testset "End-to-end simulation (solve) tests" begin

    # ====================================================================
    # 1. Exponential decay  — Model → System → solve
    # ====================================================================
    @testset "Exponential decay: D(x,t) = -k*x" begin
        k_val = 0.1
        x0 = 1.0
        vars = Dict{String,ModelVariable}(
            "x" => ModelVariable(StateVariable; default=x0),
            "k" => ModelVariable(ParameterVariable; default=k_val),
        )
        eq = Equation(
            OpExpr("D", ESM.ASTExpr[VarExpr("x")], wrt="t"),
            OpExpr("*", ESM.ASTExpr[
                OpExpr("-", ESM.ASTExpr[VarExpr("k")]),
                VarExpr("x"),
            ]),
        )
        model = Model(vars, [eq])

        sol, simp = _solve_ode(model, :Decay, (0.0, 10.0))
        x_sym = _find_unknown(simp, "x")
        x_end = sol[x_sym][end]
        expected = x0 * exp(-k_val * 10.0)
        @test isapprox(x_end, expected; rtol=1e-6)

        # Sample several intermediate points against the analytical curve.
        for t in (1.0, 2.5, 5.0, 7.5)
            @test isapprox(sol(t, idxs=x_sym), x0 * exp(-k_val * t); rtol=1e-6)
        end
    end

    # ====================================================================
    # 2. Reversible first-order reaction A ⇌ B
    # ====================================================================
    @testset "Reversible first-order reaction A ⇌ B → steady state" begin
        k1, k2 = 1.0, 0.5
        A0, B0 = 1.0, 0.0
        # Model directly as ODEs so we fully control the equations
        # (the test's purpose is solve correctness, not reaction-to-ODE
        # derivation — that path is covered by test case 3 below).
        vars = Dict{String,ModelVariable}(
            "A" => ModelVariable(StateVariable; default=A0),
            "B" => ModelVariable(StateVariable; default=B0),
            "k1" => ModelVariable(ParameterVariable; default=k1),
            "k2" => ModelVariable(ParameterVariable; default=k2),
        )
        # dA/dt = -k1*A + k2*B
        eqA = Equation(
            OpExpr("D", ESM.ASTExpr[VarExpr("A")], wrt="t"),
            OpExpr("+", ESM.ASTExpr[
                OpExpr("-", ESM.ASTExpr[
                    OpExpr("*", ESM.ASTExpr[VarExpr("k1"), VarExpr("A")]),
                ]),
                OpExpr("*", ESM.ASTExpr[VarExpr("k2"), VarExpr("B")]),
            ]),
        )
        # dB/dt =  k1*A - k2*B
        eqB = Equation(
            OpExpr("D", ESM.ASTExpr[VarExpr("B")], wrt="t"),
            OpExpr("-", ESM.ASTExpr[
                OpExpr("*", ESM.ASTExpr[VarExpr("k1"), VarExpr("A")]),
                OpExpr("*", ESM.ASTExpr[VarExpr("k2"), VarExpr("B")]),
            ]),
        )
        model = Model(vars, [eqA, eqB])

        # Integrate to "steady state". Characteristic time is 1/(k1+k2) = 2/3;
        # t = 50 is ~33 characteristic times, more than enough to settle.
        sol, simp = _solve_ode(model, :AB, (0.0, 50.0))
        Asym = _find_unknown(simp, "A")
        Bsym = _find_unknown(simp, "B")

        A_eq = sol[Asym][end]
        B_eq = sol[Bsym][end]

        # Equilibrium: k1*A = k2*B and A + B = A0 + B0 = 1
        total = A0 + B0
        A_expected = k2 * total / (k1 + k2)  # 1/3
        B_expected = k1 * total / (k1 + k2)  # 2/3

        @test isapprox(A_eq, A_expected; rtol=1e-6)
        @test isapprox(B_eq, B_expected; rtol=1e-6)
        @test isapprox(A_eq + B_eq, total; rtol=1e-10)
    end

    # ====================================================================
    # 3. Autocatalytic reaction A + B → 2B, mass conservation
    # ====================================================================
    @testset "Autocatalytic A + B → 2B: total mass conserved" begin
        k = 2.0
        A0, B0 = 1.0, 0.01
        # Build as an ESM ReactionSystem → flatten → System path so we
        # exercise the reaction-to-ODE derivation plus the solve loop.
        # NOTE: `mass_action_rate` multiplies the user-supplied rate by the
        # substrate species automatically, so the `rate` below is the rate
        # constant only. Effective rate: k * A * B.
        rxn = ESM.Reaction("auto",
            [ESM.StoichiometryEntry("A", 1), ESM.StoichiometryEntry("B", 1)],
            [ESM.StoichiometryEntry("B", 2)],
            VarExpr("k"))
        rsys = ESM.ReactionSystem(
            [ESM.Species("A"; default=A0), ESM.Species("B"; default=B0)],
            [rxn];
            parameters=[ESM.Parameter("k", k)],
        )
        flat = flatten(rsys; name="Auto")
        sys = MTK.System(flat; name=:Auto)
        simp = MTK.mtkcompile(sys)
        # Logistic time scale: 1/(k * total) = 1/(2 * 1.01) ≈ 0.495. Half-life
        # from x(0)=0.01 takes ~ln((M-x0)/x0)/(k*M) = ln(99)/2.02 ≈ 2.27.
        # Integrate to t = 10 (≈ 20 half-times) — A should be ~0.
        prob = MTK.ODEProblem(simp, Dict{Any,Any}(), (0.0, 10.0))
        sol = OrdinaryDiffEqTsit5.solve(prob, OrdinaryDiffEqTsit5.Tsit5();
            reltol=1e-10, abstol=1e-12, saveat=0.25)

        Asym = _find_unknown(simp, "A")
        Bsym = _find_unknown(simp, "B")

        total0 = A0 + B0
        As = sol[Asym]
        Bs = sol[Bsym]
        @test length(As) == length(Bs)

        # Mass conservation at every stored time step
        totals = As .+ Bs
        @test maximum(abs.(totals .- total0)) < 1e-8

        # Sanity: autocatalysis should drive A → 0, B → total.
        @test As[end] < 1e-6
        @test isapprox(Bs[end], total0; rtol=1e-6)

        # Also verify the logistic solution along the trajectory at
        # several intermediate points.
        for t in (1.0, 2.0, 3.0, 5.0)
            x = total0 / (1 + (total0/B0 - 1) * exp(-k * total0 * t))  # B(t)
            @test isapprox(sol(t, idxs=Bsym), x; rtol=1e-5)
            @test isapprox(sol(t, idxs=Asym), total0 - x; rtol=1e-5)
        end
    end

    # ====================================================================
    # 4. Robertson stiff benchmark — requires Rosenbrock23
    # ====================================================================
    @testset "Robertson stiff benchmark — reference values to reltol 1e-4" begin
        A0, B0, C0 = 1.0, 0.0, 0.0
        vars = Dict{String,ModelVariable}(
            "A" => ModelVariable(StateVariable; default=A0),
            "B" => ModelVariable(StateVariable; default=B0),
            "C" => ModelVariable(StateVariable; default=C0),
        )
        _n(x) = NumExpr(x)
        _v(n) = VarExpr(n)
        _op(op, args...; kw...) = OpExpr(op, ESM.ASTExpr[args...]; kw...)

        # dA/dt = -0.04*A + 1e4*B*C
        eqA = Equation(
            _op("D", _v("A"); wrt="t"),
            _op("+", _op("*", _n(-0.04), _v("A")),
                     _op("*", _n(1.0e4), _v("B"), _v("C"))),
        )
        # dB/dt =  0.04*A - 1e4*B*C - 3e7*B*B
        eqB = Equation(
            _op("D", _v("B"); wrt="t"),
            _op("-",
                _op("-",
                    _op("*", _n(0.04), _v("A")),
                    _op("*", _n(1.0e4), _v("B"), _v("C"))),
                _op("*", _n(3.0e7), _v("B"), _v("B"))),
        )
        # dC/dt =  3e7*B*B
        eqC = Equation(
            _op("D", _v("C"); wrt="t"),
            _op("*", _n(3.0e7), _v("B"), _v("B")),
        )
        model = Model(vars, [eqA, eqB, eqC])

        sys = MTK.System(model; name=:Robertson)
        simp = MTK.mtkcompile(sys)
        prob = MTK.ODEProblem(simp, Dict{Any,Any}(), (0.0, 4.0e10))
        sol = OrdinaryDiffEqRosenbrock.solve(prob, OrdinaryDiffEqRosenbrock.Rodas5P();
            reltol=1e-10, abstol=1e-14)

        Asym = _find_unknown(simp, "A")
        Bsym = _find_unknown(simp, "B")
        Csym = _find_unknown(simp, "C")

        # Reference values from Hairer & Wanner, "Solving ODEs II",
        # Table 1.4, p.3 (Robertson problem). Six significant digits.
        refs = [
            (0.4,     0.98517,     3.3864e-5,   0.014796),
            (4.0,     0.90551,     2.2405e-5,   0.094464),
            (40.0,    0.71583,     9.1856e-6,   0.28416),
            (400.0,   0.45053,     3.2229e-6,   0.54946),
            (4000.0,  0.18320,     8.9416e-7,   0.81680),
            (40000.0, 0.038996,    1.6225e-7,   0.96100),
        ]

        for (t, A_ref, B_ref, C_ref) in refs
            A_val = sol(t, idxs=Asym)
            B_val = sol(t, idxs=Bsym)
            C_val = sol(t, idxs=Csym)
            # Hairer & Wanner reference values are 5 significant digits.
            # Allow rtol = 5e-4 so a numerical solution matching H&W's
            # tabulated digits exactly still passes.
            @test isapprox(A_val, A_ref; rtol=5e-4)
            @test isapprox(B_val, B_ref; rtol=5e-3)  # B is tiny; looser rtol
            @test isapprox(C_val, C_ref; rtol=5e-4)
            # Mass conservation: A + B + C = 1 always
            @test isapprox(A_val + B_val + C_val, 1.0; atol=1e-6)
        end

        # Final state at t = 4e10: A → 0, B → 0, C → 1
        A_final = sol[Asym][end]
        B_final = sol[Bsym][end]
        C_final = sol[Csym][end]
        @test A_final < 1e-6
        @test B_final < 1e-12
        @test isapprox(C_final, 1.0; rtol=1e-4)
        @test isapprox(A_final + B_final + C_final, 1.0; atol=1e-6)
    end

    # Case 5 (fixture simple_ode.esm vs SciPy reference) removed in gt-l5b:
    # `simple_ode.esm` now carries an inline `tests` block with the same
    # analytical references, and `tests_blocks_execution_test.jl` walks
    # `tests/simulation/*.esm` to execute it — avoiding duplicate coverage.
end
