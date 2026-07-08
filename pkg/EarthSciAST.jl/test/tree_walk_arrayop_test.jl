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
using EarthSciAST
import OrdinaryDiffEqTsit5

include("testutils.jl")  # _n/_i/_v/_op/_idx builder quartet + repo root

const ESM = EarthSciAST
const _REPO_ROOT = TESTUTILS_REPO_ROOT

# ---- builder helper derived from the testutils.jl quartet ----
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
    # 16. Fixture 24 — makearray region dispatch in arrayop body (ess-e9l)
    #     Pins _resolve_index_of_makearray (tree_walk.jl:1114) through the
    #     LHS-arrayop unrolling path: RHS body contains
    #     index(makearray(regions,values),i,j) where i,j are the loop vars.
    # ------------------------------------------------------------------
    @testset "16. Fixture 24: makearray region dispatch in arrayop body (ess-e9l)" begin
        path = joinpath(_REPO_ROOT, "tests", "fixtures", "arrayop",
                        "24_arrayop_makearray_region_dispatch.esm")
        @test isfile(path)
        file = load(path)
        model = file.models["MakeArrayLoopRegions"]
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

    # ------------------------------------------------------------------
    # 17. Fixture 23 — pure matvec contraction (ess-zmm / ess-6ny)
    #     D(y[i])/dt = sum_{j=1..3} i*j  →  y[1]=6, y[2]=12 at t=1
    #     D(w[i])/dt = max_{j=1..3}(i+j) →  w[1]=4, w[2]=5  at t=1
    #     Flips the ess-zmm tree-walk Julia xfail to pass.
    # ------------------------------------------------------------------
    @testset "17. Fixture 23: pure matvec contraction (ess-zmm)" begin
        path = joinpath(_REPO_ROOT, "tests", "fixtures", "arrayop",
                        "23_arrayop_pure_matvec_contraction.esm")
        @test isfile(path)
        file = load(path)
        model = file.models["PureMatVecContraction"]
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
    # 18. Mesh reduction: 3-cell nn_diffusion with padded connectivity (ess-6ny)
    #     D(u[c]) = sum_k coeff[c,k] * (u[cells_on_cell[c,k]] - u[c])
    #     3-cell fully-connected mesh, coeff=0.5, u=[1,2,3] at t=0.
    #     Expected: du[1]=1.5, du[2]=0.0, du[3]=-1.5
    #     Tests indirect gather (u[cells_on_cell[c,k]]) + 2D const_arrays.
    #     Unblocks EINSUM-5 evaluator gap (esd-agh).
    # ------------------------------------------------------------------
    @testset "18. Mesh reduction: 3-cell nn_diffusion (padded connectivity)" begin
        N_c = 3; max_k = 2
        # cells_on_cell[c,k]: neighbor of cell c at position k (1-indexed)
        cells_on_cell_data = [2.0 3.0;   # cell 1 → neighbors 2, 3
                               1.0 3.0;   # cell 2 → neighbors 1, 3
                               1.0 2.0]   # cell 3 → neighbors 1, 2
        coeff_data = fill(0.5, N_c, max_k)

        vars = Dict("u" => ModelVariable(StateVariable))
        _c  = _v("c"); _k_var = _v("k")
        coeff_idx  = _op("index", _v("coeff"), _c, _k_var)
        nb_expr    = _op("index", _v("cells_on_cell"), _c, _k_var)
        u_nb       = _op("index", _v("u"), nb_expr)
        u_c        = _op("index", _v("u"), _c)
        body       = _op("*", coeff_idx, _op("-", u_nb, u_c))

        lhs = OpExpr("arrayop", ESM.Expr[];
            output_idx=Any["c"],
            expr_body=_D_idx("u", _c),
            ranges=Dict("c" => [1, N_c]))
        rhs = OpExpr("arrayop", ESM.Expr[];
            output_idx=Any["c"],
            reduce="+",
            ranges=Dict("c" => [1, N_c], "k" => [1, max_k]),
            expr_body=body)
        model = ESM.Model(vars, [ESM.Equation(lhs, rhs)])
        ics = Dict("u[$c]" => Float64(c) for c in 1:N_c)
        f!, u0, p, _, vmap = build_evaluator(model;
            initial_conditions=ics,
            const_arrays=Dict("cells_on_cell" => cells_on_cell_data,
                              "coeff"          => coeff_data))
        du = similar(u0); f!(du, u0, p, 0.0)
        @test isapprox(du[vmap["u[1]"]],  1.5; rtol=1e-12)
        @test isapprox(du[vmap["u[2]"]],  0.0; atol=1e-14)
        @test isapprox(du[vmap["u[3]"]], -1.5; rtol=1e-12)
    end

    # ------------------------------------------------------------------
    # 19. Mesh reduction with PER-CELL DYNAMIC bound (variable valence, Route A)
    #     D(u[c]) = sum_{k=1}^{n_edges_on_cell[c]} coeff[c,k]*(u[cells_on_cell[c,k]]-u[c])
    #
    #     The reduction's upper bound is itself an INDEX EXPRESSION over a
    #     connectivity const_array (`index(n_edges_on_cell, c)`), evaluated PER
    #     OUTPUT CELL by the einsum branch — no host-side constant-max-edges
    #     padding (cf. test 18, which pads to a global max_k and zeroes padding
    #     slots).  This pins the variable-valence segment reduction that lets ESD
    #     drop Route B's padding.
    #
    #     Fixture: an OPEN 4-cell strip  1—2—3—4 (path graph, NOT a closed loop).
    #       valence n_edges_on_cell = [1, 2, 2, 1]  (boundary cells 1,4 have one).
    #       all edge metrics = 1 ⇒ every real-slot coeff = 1.
    #     The const_arrays are allocated (n_cells, max_k=2) but each cell's bound
    #     is its TRUE valence, so the trailing padding slot is NEVER read — proven
    #     by POISONING the padding slots so that reading one corrupts the result
    #     by ~1e9: the padding neighbour points at a REAL cell (so the gather is
    #     in-range, not a ghost) and the padding coeff is 1e9.  If the engine
    #     iterated a padding slot, du[boundary] would be ~1e9 instead of O(1).
    #     (Verified: the CONSTANT-bound form below DOES read it — du[1]≈1e9 —
    #     while the dynamic bound stays exact.)
    #
    #     u = [0,1,0,0] ⇒ each cell sums over its REAL neighbours only:
    #       du[1] = (u[2]-u[1])               =  1   (valence-1 boundary cell)
    #       du[2] = (u[1]-u[2]) + (u[3]-u[2]) = -2
    #       du[3] = (u[2]-u[3]) + (u[4]-u[3]) =  1
    #       du[4] = (u[3]-u[4])               =  0   (valence-1 boundary cell)
    # ------------------------------------------------------------------
    @testset "19. Mesh reduction: per-cell dynamic bound (variable valence, no padding)" begin
        N_c = 4; max_k = 2
        POISON_NB = 2.0        # padding neighbour → a REAL cell (in-range gather)
        POISON_W  = 1.0e9      # padding-slot coeff that must never be used
        # cells_on_cell[c,k]: real neighbour at slot k≤valence; poison beyond.
        cells_on_cell_data = [2.0  POISON_NB;    # cell 1: nbr 2          (valence 1)
                              1.0  3.0;          # cell 2: nbrs 1, 3      (valence 2)
                              2.0  4.0;          # cell 3: nbrs 2, 4      (valence 2)
                              3.0  POISON_NB]    # cell 4: nbr 3          (valence 1)
        coeff_data = [1.0  POISON_W;             # cell 1
                      1.0  1.0;                  # cell 2
                      1.0  1.0;                  # cell 3
                      1.0  POISON_W]             # cell 4
        n_edges_on_cell_data = [1.0, 2.0, 2.0, 1.0]   # per-cell valence (the bound)

        vars = Dict("u" => ModelVariable(StateVariable))
        _c  = _v("c"); _k_var = _v("k")
        coeff_idx  = _op("index", _v("coeff"), _c, _k_var)
        nb_expr    = _op("index", _v("cells_on_cell"), _c, _k_var)
        u_nb       = _op("index", _v("u"), nb_expr)
        u_c        = _op("index", _v("u"), _c)
        body       = _op("*", coeff_idx, _op("-", u_nb, u_c))

        # Per-cell DYNAMIC reduction bound: k ∈ [1, index(n_edges_on_cell, c)].
        k_bound = _op("index", _v("n_edges_on_cell"), _c)

        lhs = OpExpr("arrayop", ESM.Expr[];
            output_idx=Any["c"],
            expr_body=_D_idx("u", _c),
            ranges=Dict("c" => [1, N_c]))
        rhs = OpExpr("arrayop", ESM.Expr[];
            output_idx=Any["c"],
            reduce="+",
            ranges=Dict("c" => Any[1, N_c], "k" => Any[1, k_bound]),
            expr_body=body)
        model = ESM.Model(vars, [ESM.Equation(lhs, rhs)])

        ics = Dict("u[$c]" => 0.0 for c in 1:N_c)
        f!, u0, p, _, vmap = build_evaluator(model;
            initial_conditions=ics,
            const_arrays=Dict("cells_on_cell"   => cells_on_cell_data,
                              "coeff"           => coeff_data,
                              "n_edges_on_cell" => n_edges_on_cell_data))

        # u = [0,1,0,0]
        u = copy(u0)
        u[vmap["u[1]"]] = 0.0; u[vmap["u[2]"]] = 1.0
        u[vmap["u[3]"]] = 0.0; u[vmap["u[4]"]] = 0.0
        du = similar(u0); f!(du, u, p, 0.0)
        @test isapprox(du[vmap["u[1]"]],  1.0; atol=1e-12)
        @test isapprox(du[vmap["u[2]"]], -2.0; atol=1e-12)
        @test isapprox(du[vmap["u[3]"]],  1.0; atol=1e-12)
        @test isapprox(du[vmap["u[4]"]],  0.0; atol=1e-12)

        # Uniform field u≡1 ⇒ exact-zero discrete Laplacian everywhere, INCLUDING
        # the valence-1 boundary cells (no spurious term from the dropped slot).
        u1 = copy(u0)
        for c in 1:N_c; u1[vmap["u[$c]"]] = 1.0; end
        du1 = similar(u0); f!(du1, u1, p, 0.0)
        for c in 1:N_c
            @test isapprox(du1[vmap["u[$c]"]], 0.0; atol=1e-12)
        end

        # Backward-compat guard: the CONSTANT-bound padded form (test 18) must
        # still expand once, globally. Reuse the same model with a constant k
        # range [1, max_k] and zeroed-padding coeff/sentinel neighbour table.
        cells_pad = [2.0 0.0; 1.0 3.0; 2.0 4.0; 3.0 0.0]   # 0 sentinel padding
        coeff_pad = [1.0 0.0; 1.0 1.0; 1.0 1.0; 1.0 0.0]   # zeroed padding
        rhs_const = OpExpr("arrayop", ESM.Expr[];
            output_idx=Any["c"], reduce="+",
            ranges=Dict("c" => Any[1, N_c], "k" => Any[1, max_k]),
            expr_body=body)
        model_const = ESM.Model(vars, [ESM.Equation(lhs, rhs_const)])
        f2!, u02, p2, _, vmap2 = build_evaluator(model_const;
            initial_conditions=Dict("u[$c]" => 0.0 for c in 1:N_c),
            const_arrays=Dict("cells_on_cell" => cells_pad, "coeff" => coeff_pad))
        uc = copy(u02)
        uc[vmap2["u[1]"]] = 0.0; uc[vmap2["u[2]"]] = 1.0
        uc[vmap2["u[3]"]] = 0.0; uc[vmap2["u[4]"]] = 0.0
        du2 = similar(u02); f2!(du2, uc, p2, 0.0)
        @test isapprox(du2[vmap2["u[1]"]],  1.0; atol=1e-12)
        @test isapprox(du2[vmap2["u[2]"]], -2.0; atol=1e-12)
        @test isapprox(du2[vmap2["u[3]"]],  1.0; atol=1e-12)
        @test isapprox(du2[vmap2["u[4]"]],  0.0; atol=1e-12)
    end

end
