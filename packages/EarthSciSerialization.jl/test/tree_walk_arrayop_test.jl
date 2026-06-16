# Tests for arrayop evaluation in tree_walk (ess-evm).
#
# Verifies that build_evaluator handles:
#   1. D(index(var, k)) — indexed scalar derivative
#   2. arrayop(D(index(var, i+off))) — array-loop derivative, 1D
#   3. arrayop(D(index(var, i, j))) — array-loop derivative, 2D
#   4. Ghost cells — out-of-bounds index returns 0.0
#   5. Discretized fixture 15 (1D heat, Dirichlet BCs)
#   6. Discretized fixture 16 (2D heat, ghost cells)
#   7. Discretized fixture 17 (lat-lon heat, periodic wrapping via ifelse)

using Test
using EarthSciSerialization
import OrdinaryDiffEqTsit5

const ESM = EarthSciSerialization
const _REPO_ROOT = normpath(joinpath(@__DIR__, "..", "..", ".."))

# ---- builder helpers ----
_n(x)   = NumExpr(Float64(x))
_i(x)   = IntExpr(Int64(x))
_v(n)   = VarExpr(String(n))
_op(op, args...; kw...) = OpExpr(String(op), ESM.Expr[args...]; kw...)
_idx(var, idx_exprs...)  = _op("index", _v(var), idx_exprs...)
_D_idx(var, idx_exprs...) = _op("D", _idx(var, idx_exprs...); wrt="t")
_arrayop1d(body, idx, lo, hi) = OpExpr("arrayop", ESM.Expr[];
    output_idx=Any[idx], expr_body=body,
    ranges=Dict(idx => [lo, hi]))
_arrayop2d(body, i, ilo, ihi, j, jlo, jhi) = OpExpr("arrayop", ESM.Expr[];
    output_idx=Any[i, j], expr_body=body,
    ranges=Dict(i => [ilo, ihi], j => [jlo, jhi]))

@testset "tree_walk arrayop (ess-evm)" begin

    # ------------------------------------------------------------------
    # 1. D(index(u, k)) — indexed scalar derivatives
    # ------------------------------------------------------------------
    @testset "1. Indexed scalar derivative D(index(u,k))" begin
        vars = Dict("u" => ModelVariable(StateVariable))
        eqs = [
            ESM.Equation(_D_idx("u", _i(1)), _op("-", _idx("u", _i(1)))),
            ESM.Equation(_D_idx("u", _i(2)), _op("*", _n(-2.0), _idx("u", _i(2)))),
            ESM.Equation(_D_idx("u", _i(3)), _op("*", _n(-3.0), _idx("u", _i(3)))),
        ]
        model = ESM.Model(vars, eqs)
        ics = Dict("u[1]" => 1.0, "u[2]" => 2.0, "u[3]" => 3.0)
        f!, u0, p, _, vmap = build_evaluator(model; initial_conditions=ics)
        du = similar(u0); f!(du, u0, p, 0.0)
        @test isapprox(du[vmap["u[1]"]], -1.0; rtol=1e-12)
        @test isapprox(du[vmap["u[2]"]], -4.0; rtol=1e-12)
        @test isapprox(du[vmap["u[3]"]], -9.0; rtol=1e-12)
    end

    # ------------------------------------------------------------------
    # 2. arrayop D(u[i]) = -u[i] — simple 1D loop
    # ------------------------------------------------------------------
    @testset "2. Arrayop 1D decay D(u[i])=-u[i]" begin
        N = 5
        vars = Dict("u" => ModelVariable(StateVariable))
        lhs = _arrayop1d(_D_idx("u", _v("i")), "i", 1, N)
        rhs = _arrayop1d(_op("-", _idx("u", _v("i"))), "i", 1, N)
        model = ESM.Model(vars, [ESM.Equation(lhs, rhs)])
        ics = Dict("u[$k]" => Float64(k) for k in 1:N)
        f!, u0, p, _, vmap = build_evaluator(model; initial_conditions=ics)
        du = similar(u0); f!(du, u0, p, 0.0)
        for k in 1:N
            @test isapprox(du[vmap["u[$k]"]], -Float64(k); rtol=1e-12)
        end
    end

    # ------------------------------------------------------------------
    # 3. arrayop D(u[i,j]) = -u[i,j] — 2D loop
    # ------------------------------------------------------------------
    @testset "3. Arrayop 2D decay D(u[i,j])=-u[i,j]" begin
        M, N = 3, 4
        vars = Dict("u" => ModelVariable(StateVariable))
        lhs = _arrayop2d(_D_idx("u", _v("i"), _v("j")), "i", 1, M, "j", 1, N)
        rhs = _arrayop2d(_op("-", _idx("u", _v("i"), _v("j"))), "i", 1, M, "j", 1, N)
        model = ESM.Model(vars, [ESM.Equation(lhs, rhs)])
        ics = Dict("u[$i,$j]" => Float64(i + j) for i in 1:M for j in 1:N)
        f!, u0, p, _, vmap = build_evaluator(model; initial_conditions=ics)
        du = similar(u0); f!(du, u0, p, 0.0)
        for i in 1:M, j in 1:N
            @test isapprox(du[vmap["u[$i,$j]"]], -Float64(i+j); rtol=1e-12)
        end
    end

    # ------------------------------------------------------------------
    # 4. Ghost cells — index(u, 0) returns 0.0
    # ------------------------------------------------------------------
    @testset "4. Ghost cell (out-of-bounds → 0)" begin
        vars = Dict("u" => ModelVariable(StateVariable))
        # D(u[1]) = u[0] - 2*u[1] + u[2]; u[0] is ghost → 0
        rhs = _op("+",
            _idx("u", _i(0)),               # ghost → 0
            _op("*", _n(-2.0), _idx("u", _i(1))),
            _idx("u", _i(2)))
        eqs = [
            ESM.Equation(_D_idx("u", _i(1)), rhs),
            ESM.Equation(_D_idx("u", _i(2)), _n(0.0)),
        ]
        model = ESM.Model(vars, eqs)
        ics = Dict("u[1]" => 1.0, "u[2]" => 2.0)
        f!, u0, p, _, vmap = build_evaluator(model; initial_conditions=ics)
        du = similar(u0); f!(du, u0, p, 0.0)
        # 0 - 2*1 + 2 = 0
        @test isapprox(du[vmap["u[1]"]], 0.0; atol=1e-14)
    end

    # ------------------------------------------------------------------
    # 5. Arrayop stencil with offset index D(u[i+1]) = stencil body
    # ------------------------------------------------------------------
    @testset "5. 1D diffusion stencil (offset index)" begin
        N = 10
        vars = Dict("u" => ModelVariable(StateVariable))
        body = _op("+",
            _idx("u", _v("i")),
            _op("*", _n(-2.0), _idx("u", _op("+", _v("i"), _i(1)))),
            _idx("u", _op("+", _v("i"), _i(2))))
        lhs_int = _arrayop1d(_D_idx("u", _op("+", _v("i"), _i(1))), "i", 1, N-2)
        rhs_int = _arrayop1d(body, "i", 1, N-2)
        bc1 = ESM.Equation(_D_idx("u", _i(1)),
            _op("-", _idx("u", _i(2)), _idx("u", _i(1))))
        bcN = ESM.Equation(_D_idx("u", _i(N)),
            _op("-", _idx("u", _i(N-1)), _idx("u", _i(N))))
        model = ESM.Model(vars, [ESM.Equation(lhs_int, rhs_int), bc1, bcN])
        # Delta spike at u[5]
        ics = Dict("u[$k]" => (k == 5 ? 1.0 : 0.0) for k in 1:N)
        f!, u0, p, _, vmap = build_evaluator(model; initial_conditions=ics)
        du = similar(u0); f!(du, u0, p, 0.0)
        @test isapprox(du[vmap["u[5]"]], -2.0; rtol=1e-12)
        @test isapprox(du[vmap["u[4]"]],  1.0; rtol=1e-12)
        @test isapprox(du[vmap["u[6]"]],  1.0; rtol=1e-12)
        @test isapprox(du[vmap["u[1]"]], 0.0;  atol=1e-14)
    end

    # ------------------------------------------------------------------
    # 6. Fixture 15 — 1D heat (discretized, Dirichlet BCs)
    # ------------------------------------------------------------------
    @testset "6. Fixture 15: 1D heat (discretized)" begin
        path = joinpath(_REPO_ROOT, "tests", "fixtures", "arrayop",
                        "15_discretized_1d_heat.esm")
        @test isfile(path)
        file = load(path)
        model = file.models["Heat1D"]
        t = model.tests[1]
        ics = Dict(String(k) => Float64(v) for (k, v) in t.initial_conditions)
        f!, u0, p, _, vmap = build_evaluator(model; initial_conditions=ics)
        ts = (Float64(t.time_span.start), Float64(t.time_span.stop))
        prob = OrdinaryDiffEqTsit5.ODEProblem(f!, u0, ts, p)
        sol = OrdinaryDiffEqTsit5.solve(prob, OrdinaryDiffEqTsit5.Tsit5();
                                        reltol=1e-6, abstol=1e-8)
        rtol = model.tolerance !== nothing ? model.tolerance.rel : 1e-3
        for ass in t.assertions
            var = String(ass.variable)
            actual = sol(Float64(ass.time))[vmap[var]]
            @test isapprox(actual, Float64(ass.expected); rtol=rtol)
        end
    end

    # ------------------------------------------------------------------
    # 7. Fixture 16 — 2D heat (3x3 interior, ghost cells)
    # ------------------------------------------------------------------
    @testset "7. Fixture 16: 2D heat (discretized)" begin
        path = joinpath(_REPO_ROOT, "tests", "fixtures", "arrayop",
                        "16_discretized_2d_heat.esm")
        @test isfile(path)
        file = load(path)
        model = file.models["Heat2D"]
        t = model.tests[1]
        ics = Dict(String(k) => Float64(v) for (k, v) in t.initial_conditions)
        f!, u0, p, _, vmap = build_evaluator(model; initial_conditions=ics)
        ts = (Float64(t.time_span.start), Float64(t.time_span.stop))
        prob = OrdinaryDiffEqTsit5.ODEProblem(f!, u0, ts, p)
        sol = OrdinaryDiffEqTsit5.solve(prob, OrdinaryDiffEqTsit5.Tsit5();
                                        reltol=1e-4, abstol=1e-6)
        rtol = model.tolerance !== nothing ? model.tolerance.rel : 1e-3
        for ass in t.assertions
            var = String(ass.variable)
            actual = sol(Float64(ass.time))[vmap[var]]
            @test isapprox(actual, Float64(ass.expected); rtol=rtol)
        end
    end

    # ------------------------------------------------------------------
    # 8. Fixture 17 — lat-lon heat (periodic wrapping via ifelse)
    # ------------------------------------------------------------------
    @testset "8. Fixture 17: lat-lon heat (periodic)" begin
        path = joinpath(_REPO_ROOT, "tests", "fixtures", "arrayop",
                        "17_discretized_latlon_heat.esm")
        @test isfile(path)
        file = load(path)
        model = file.models["HeatLatLon"]
        t = model.tests[1]
        ics = Dict(String(k) => Float64(v) for (k, v) in t.initial_conditions)
        f!, u0, p, _, vmap = build_evaluator(model; initial_conditions=ics)
        ts = (Float64(t.time_span.start), Float64(t.time_span.stop))
        prob = OrdinaryDiffEqTsit5.ODEProblem(f!, u0, ts, p)
        sol = OrdinaryDiffEqTsit5.solve(prob, OrdinaryDiffEqTsit5.Tsit5();
                                        reltol=1e-4, abstol=1e-6)
        rtol = model.tolerance !== nothing ? model.tolerance.rel : 1e-3
        for ass in t.assertions
            var = String(ass.variable)
            actual = sol(Float64(ass.time))[vmap[var]]
            @test isapprox(actual, Float64(ass.expected); rtol=rtol)
        end
    end

    # ------------------------------------------------------------------
    # 9. Fixture 18 — two-domain interface BC (ess-x76)
    # ------------------------------------------------------------------
    @testset "9. Fixture 18: two-domain interface BC" begin
        path = joinpath(_REPO_ROOT, "tests", "fixtures", "arrayop",
                        "18_interface_bc_2domain.esm")
        @test isfile(path)
        file = load(path)
        model = file.models["TwoDomainHeat"]
        t = model.tests[1]
        ics = Dict(String(k) => Float64(v) for (k, v) in t.initial_conditions)
        f!, u0, p, _, vmap = build_evaluator(model; initial_conditions=ics)
        ts = (Float64(t.time_span.start), Float64(t.time_span.stop))
        prob = OrdinaryDiffEqTsit5.ODEProblem(f!, u0, ts, p)
        sol = OrdinaryDiffEqTsit5.solve(prob, OrdinaryDiffEqTsit5.Tsit5();
                                        reltol=1e-6, abstol=1e-8)
        rtol = model.tolerance !== nothing ? model.tolerance.rel : 1e-3
        for ass in t.assertions
            var = String(ass.variable)
            actual = sol(Float64(ass.time))[vmap[var]]
            @test isapprox(actual, Float64(ass.expected); rtol=rtol)
        end
    end

    # ------------------------------------------------------------------
    # 10. Fixture 19 — generalized einsum: contracted stencil index (ess-trq)
    # ------------------------------------------------------------------
    @testset "10. Fixture 19: einsum 1D stencil (contracted index)" begin
        path = joinpath(_REPO_ROOT, "tests", "fixtures", "arrayop",
                        "19_einsum_1d_stencil.esm")
        @test isfile(path)
        file = load(path)
        model = file.models["Heat1DEinsum"]
        t = model.tests[1]
        ics = Dict(String(k) => Float64(v) for (k, v) in t.initial_conditions)
        f!, u0, p, _, vmap = build_evaluator(model; initial_conditions=ics)
        ts = (Float64(t.time_span.start), Float64(t.time_span.stop))
        prob = OrdinaryDiffEqTsit5.ODEProblem(f!, u0, ts, p)
        sol = OrdinaryDiffEqTsit5.solve(prob, OrdinaryDiffEqTsit5.Tsit5();
                                        reltol=1e-6, abstol=1e-8)
        rtol = model.tolerance !== nothing ? model.tolerance.rel : 1e-3
        for ass in t.assertions
            var = String(ass.variable)
            actual = sol(Float64(ass.time))[vmap[var]]
            @test isapprox(actual, Float64(ass.expected); rtol=rtol)
        end
    end

    # ------------------------------------------------------------------
    # 11. Fixture 20 — embedded arrayop contraction (ess-n0w)
    #     Scalar arrayop (empty output_idx) as scalar equation RHS,
    #     plus index(arrayop(...), k) for a 1D output arrayop with
    #     contracted index.
    # ------------------------------------------------------------------
    @testset "11. Fixture 20: embedded arrayop contraction" begin
        path = joinpath(_REPO_ROOT, "tests", "fixtures", "arrayop",
                        "20_arrayop_contraction_embedded.esm")
        @test isfile(path)
        file = load(path)
        model = file.models["ContractionEmbedded"]
        t = model.tests[1]
        ics = Dict(String(k) => Float64(v) for (k, v) in t.initial_conditions)
        f!, u0, p, _, vmap = build_evaluator(model; initial_conditions=ics)
        du = similar(u0); f!(du, u0, p, 0.0)
        # D(z) = sum_{j=1}^{3} j^2 = 1+4+9 = 14
        @test isapprox(du[vmap["z"]],  14.0; rtol=1e-12)
        # D(w) = max_{j=1}^{4} j = 4
        @test isapprox(du[vmap["w"]],   4.0; rtol=1e-12)
        # D(z3) = index(arrayop[i]{sum_j j*(i+j), j in 1:2}, 1)
        #        = sum_{j=1}^{2} j*(1+j) = 1*2 + 2*3 = 2+6 = 8
        @test isapprox(du[vmap["z3"]],  8.0; rtol=1e-12)
    end

    # ------------------------------------------------------------------
    # 12. Fixture 09 — makearray block assembly (ess-n0w)
    #     index(makearray(regions, values), i, j) resolved at build time.
    # ------------------------------------------------------------------
    @testset "12. Fixture 09: makearray block assembly" begin
        path = joinpath(_REPO_ROOT, "tests", "fixtures", "arrayop",
                        "09_makearray_block_assembly.esm")
        @test isfile(path)
        file = load(path)
        model = file.models["MakeArrayBlocks"]
        t = model.tests[1]
        ics = Dict(String(k) => Float64(v) for (k, v) in t.initial_conditions)
        f!, u0, p, _, vmap = build_evaluator(model; initial_conditions=ics)
        ts = (Float64(t.time_span.start), Float64(t.time_span.stop))
        prob = OrdinaryDiffEqTsit5.ODEProblem(f!, u0, ts, p)
        sol  = OrdinaryDiffEqTsit5.solve(prob, OrdinaryDiffEqTsit5.Tsit5();
                                         reltol=1e-6, abstol=1e-8)
        rtol = model.tolerance !== nothing ? model.tolerance.rel : 1e-3
        for ass in t.assertions
            var = String(ass.variable)
            actual = sol(Float64(ass.time))[vmap[var]]
            @test isapprox(actual, Float64(ass.expected); rtol=rtol)
        end
    end

    # ------------------------------------------------------------------
    # 13. Scalar arrayop over state variables — runner numeric test (ess-n0w)
    #     D(z) = sum_{j=1}^{3} x[j]  via contracted arrayop (reduce="+")
    #     D(w) = max_{j=1}^{3} x[j]  via contracted arrayop (reduce="max")
    #     x[j] are state variables (constant D=0).
    # ------------------------------------------------------------------
    @testset "13. Scalar arrayop over state variables (reduce +/max)" begin
        vars = Dict("z" => ModelVariable(StateVariable),
                    "w" => ModelVariable(StateVariable),
                    "x" => ModelVariable(StateVariable))
        N = 3
        # arrayop(index(x, j), output_idx=[], ranges={j:[1,N]}, reduce=op)
        _idx_x_j = _op("index", _v("x"), _v("j"))
        _ao_plus = OpExpr("arrayop", ESM.Expr[];
            output_idx=Any[], expr_body=_idx_x_j, reduce="+",
            ranges=Dict("j" => [1, N]))
        _ao_max  = OpExpr("arrayop", ESM.Expr[];
            output_idx=Any[], expr_body=_idx_x_j, reduce="max",
            ranges=Dict("j" => [1, N]))
        eqs = [
            ESM.Equation(_op("D", _v("z"); wrt="t"), _ao_plus),
            ESM.Equation(_op("D", _v("w"); wrt="t"), _ao_max),
            ESM.Equation(_D_idx("x", _i(1)), _n(0.0)),
            ESM.Equation(_D_idx("x", _i(2)), _n(0.0)),
            ESM.Equation(_D_idx("x", _i(3)), _n(0.0)),
        ]
        model = ESM.Model(vars, eqs)
        ics = Dict("z" => 0.0, "w" => 0.0, "x[1]" => 2.0, "x[2]" => 5.0, "x[3]" => 3.0)
        f!, u0, p, _, vmap = build_evaluator(model; initial_conditions=ics)
        du = similar(u0); f!(du, u0, p, 0.0)
        # D(z) = sum(x) = 2+5+3 = 10
        @test isapprox(du[vmap["z"]], 10.0; rtol=1e-12)
        # D(w) = max(x) = 5
        @test isapprox(du[vmap["w"]],  5.0; rtol=1e-12)
    end

    # ------------------------------------------------------------------
    # 14. Scalar arrayop max/min reducers (ess-n0w)
    #     D(z_max) = max_{j=1}^{5} j = 5
    #     D(z_min) = min_{j=1}^{5} j = 1
    # ------------------------------------------------------------------
    @testset "14. Scalar arrayop max/min reducers" begin
        vars = Dict("z_max" => ModelVariable(StateVariable),
                    "z_min" => ModelVariable(StateVariable))
        _ao(body, idx, lo, hi, reduce_op) = OpExpr("arrayop", ESM.Expr[];
            output_idx=Any[], expr_body=body, reduce=reduce_op,
            ranges=Dict(idx => [lo, hi]))
        eqs = [
            ESM.Equation(_op("D", _v("z_max"); wrt="t"),
                         _ao(_v("j"), "j", 1, 5, "max")),
            ESM.Equation(_op("D", _v("z_min"); wrt="t"),
                         _ao(_v("j"), "j", 1, 5, "min")),
        ]
        model = ESM.Model(vars, eqs)
        ics = Dict("z_max" => 0.0, "z_min" => 0.0)
        f!, u0, p, _, vmap = build_evaluator(model; initial_conditions=ics)
        du = similar(u0); f!(du, u0, p, 0.0)
        @test isapprox(du[vmap["z_max"]], 5.0; rtol=1e-12)
        @test isapprox(du[vmap["z_min"]], 1.0; rtol=1e-12)
    end

    # ------------------------------------------------------------------
    # 15. makearray interior+boundary regions (later-overwrite, ess-n0w)
    #     A 1D 5-cell domain where:
    #       region 1 [1,5] = 1.0  (border default)
    #       region 2 [2,4] = 2.0  (interior overwrites)
    #     D(u[k]) = C[k] where C[k] = index(makearray(regions, values), k)
    # ------------------------------------------------------------------
    @testset "15. makearray interior+boundary (later-overwrite)" begin
        N = 5
        vars = Dict("u" => ModelVariable(StateVariable))
        # makearray: region1=[1:5]=1.0, region2=[2:4]=2.0
        makearray_node = OpExpr("makearray", ESM.Expr[];
            regions = [[[1,5]], [[2,4]]],
            values  = ESM.Expr[_n(1.0), _n(2.0)])
        eqs = ESM.Equation[]
        for k in 1:N
            rhs = _op("index", makearray_node, _i(k))
            push!(eqs, ESM.Equation(_D_idx("u", _i(k)), rhs))
        end
        model = ESM.Model(vars, eqs)
        ics = Dict("u[$k]" => 0.0 for k in 1:N)
        f!, u0, p, _, vmap = build_evaluator(model; initial_conditions=ics)
        du = similar(u0); f!(du, u0, p, 0.0)
        # Boundary cells (1,5) → 1.0; interior (2,3,4) → 2.0
        @test isapprox(du[vmap["u[1]"]], 1.0; rtol=1e-12)
        @test isapprox(du[vmap["u[2]"]], 2.0; rtol=1e-12)
        @test isapprox(du[vmap["u[3]"]], 2.0; rtol=1e-12)
        @test isapprox(du[vmap["u[4]"]], 2.0; rtol=1e-12)
        @test isapprox(du[vmap["u[5]"]], 1.0; rtol=1e-12)
    end

end
