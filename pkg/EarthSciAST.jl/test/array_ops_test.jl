# Native Julia tests for the array-op runtime implementation (gt-vt3).
# Each testset builds an ESM `Model` that uses the new array-op nodes
# (arrayop / makearray / index / broadcast / reshape / transpose / concat),
# pipes it through `ModelingToolkit.System(model)`, compiles and solves
# the resulting ODE, and checks against analytical or reference solutions.
using Test
using EarthSciAST
using OrderedCollections: OrderedDict
import ModelingToolkit
import Symbolics
import OrdinaryDiffEqTsit5

const ESM2 = EarthSciAST
const MTK2 = ModelingToolkit

# ------------------------------------------------------------
# AST-building helpers — reduce boilerplate in the testsets.
# ------------------------------------------------------------

# Shorthand constructors for the expression AST.
_var(name::AbstractString) = ESM2.VarExpr(String(name))
_num(x) = ESM2.NumExpr(Float64(x))
_op(op::AbstractString, args...; kwargs...) =
    ESM2.OpExpr(String(op), ESM2.ASTExpr[args...]; kwargs...)

# Build an `index(u, idxs...)` node.
_idx(arr::AbstractString, idxs...) =
    _op("index", _var(arr), (i isa Integer ? _num(i) : i for i in idxs)...)

# Build a 1-D `arrayop` node with a single range declaration `i in lo:hi`.
function _arrayop1d(body::ESM2.ASTExpr, idx_name::AbstractString, lo::Int, hi::Int)
    return ESM2.OpExpr("arrayop", ESM2.ASTExpr[];
        output_idx=Any[String(idx_name)],
        expr_body=body,
        ranges=Dict{String,Vector{Int}}(String(idx_name) => [lo, hi]))
end

# Build a 2-D `arrayop` node with ranges `i in 1:M, j in 1:N` — output shape
# is `(M, N)` when both indices appear in `output_idx`.
function _arrayop2d(body::ESM2.ASTExpr,
                    i_name::AbstractString, ilo::Int, ihi::Int,
                    j_name::AbstractString, jlo::Int, jhi::Int)
    return ESM2.OpExpr("arrayop", ESM2.ASTExpr[];
        output_idx=Any[String(i_name), String(j_name)],
        expr_body=body,
        ranges=Dict{String,Vector{Int}}(
            String(i_name) => [ilo, ihi],
            String(j_name) => [jlo, jhi]))
end

# Build a `D(u[i], t)` node for use inside an `arrayop` body.
_d_index(arr::AbstractString, idxs...) =
    _op("D", _idx(arr, idxs...); wrt="t")

# Build a scalar state variable with an initial value.
_state(default) = ESM2.ModelVariable(ESM2.UnknownVariable; default=default)

# Solve an ESM Model and return (sol, compiled_system).
function _build_and_solve(model::ESM2.Model, name::Symbol,
                          u0_map::AbstractVector, tspan::Tuple{Float64,Float64})
    sys = MTK2.System(model; name=name)
    simp = MTK2.mtkcompile(sys)
    prob = MTK2.ODEProblem(simp, u0_map, tspan)
    sol = OrdinaryDiffEqTsit5.solve(prob, OrdinaryDiffEqTsit5.Tsit5(); reltol=1e-8, abstol=1e-10)
    return sol, simp
end

# Find a symbolic array handle on a compiled system by the flatten-time
# prefixed name. `flatten(model; name="Foo")` produces variable names of
# the form `"Foo.u"`, which the MTKExt `_san` helper rewrites to the
# Julia symbol `:Foo_u`. We fetch that symbolic array handle here.
_arr(simp, model_name::Symbol, local_name::AbstractString) =
    MTK2.getproperty(simp, Symbol(String(model_name) * "_" * String(local_name)))

# ================================================================
# Fixture runner helpers (used by the "Schema fixture runner"
# testset — must be defined BEFORE the @testset that references them
# because the @testset body is compiled at parse time).
# ================================================================

# Parse a variable spec like `"u[1]"` or `"u[1,2]"` into
# `(base_name::String, indices::Vector{Int})`. Scalar variables (no
# brackets) return an empty `indices` vector.
function _parse_varspec(spec::AbstractString)
    lb = findfirst('[', spec)
    if lb === nothing
        return String(spec), Int[]
    end
    rb = findfirst(']', spec)
    rb === nothing && error("unterminated index in '$spec'")
    base = String(spec[1:(lb - 1)])
    body = spec[(lb + 1):(rb - 1)]
    idxs = [parse(Int, strip(t)) for t in split(body, ',')]
    return base, idxs
end

# Resolve a variable spec against the compiled MTK system and return
# the symbolic handle suitable for both u0 map entries and
# `sol[handle]` lookups.
function _resolve_on_simp(simp, model_name::Symbol, spec::AbstractString)
    base, idxs = _parse_varspec(spec)
    arr = _arr(simp, model_name, base)
    return isempty(idxs) ? arr : arr[idxs...]
end

# Combine test / model tolerance with an assertion-level override.
# Assertion-level wins, then test-level, then model-level. Default is
# `rtol=1e-6`.
function _effective_tolerance(model_tol, test_tol, assertion_tol)
    for candidate in (assertion_tol, test_tol, model_tol)
        candidate === nothing && continue
        rel = candidate.rel === nothing ? 0.0 : candidate.rel
        abs_ = candidate.abs === nothing ? 0.0 : candidate.abs
        return (rel, abs_)
    end
    return (1.0e-6, 0.0)
end

# Execute a single schema-level Test against a compiled MTK system.
function _run_fixture_test(simp, model_name::Symbol,
                           model_tolerance, t)
    # Build a Dict keyed by symbolic handles — MTK11 accepts this form
    # uniformly, whereas a Vector{Any} of Pair{Num,Float64} gets copied
    # into Memory{Real} and fails at the element-conversion step.
    u0_map = Dict{Any,Float64}()
    for (spec, val) in t.initial_conditions
        handle = _resolve_on_simp(simp, model_name, spec)
        u0_map[handle] = Float64(val)
    end
    tspan = (t.time_span.start, t.time_span.stop)
    prob = MTK2.ODEProblem(simp, u0_map, tspan)
    sol = OrdinaryDiffEqTsit5.solve(prob, OrdinaryDiffEqTsit5.Tsit5(); reltol=1e-10, abstol=1e-12)
    @test sol.retcode == ModelingToolkit.SciMLBase.ReturnCode.Success
    for a in t.assertions
        handle = _resolve_on_simp(simp, model_name, a.variable)
        rel, abs_ = _effective_tolerance(model_tolerance, t.tolerance, a.tolerance)
        actual = sol(a.time, idxs=handle)
        if abs_ > 0 && iszero(a.expected)
            @test isapprox(actual, a.expected; atol=abs_)
        elseif rel > 0
            @test isapprox(actual, a.expected; rtol=rel, atol=abs_)
        else
            @test isapprox(actual, a.expected; atol=abs_)
        end
    end
end

# Build the MTK system for ONE model of a fixture file.
#
# Not `MTK2.System(model)`: that convenience method wraps the bare `Model` in a
# synthetic `EsmFile` with an EMPTY index-set registry (src/flatten.jl
# `flatten(::Model)`), so an aggregate range spelled as an index-set reference
# — `"ranges": {"i": {"from": "x"}}` — has no extent to resolve against. The
# registry is document-scoped, so re-wrap the model in a single-model file that
# CARRIES the real one. Namespacing is unchanged (`<model name>.<var>`), so
# every `_arr` lookup below resolves exactly as before.
function _fixture_system(file, mname::AbstractString, model)
    one_model = EarthSciAST.EsmFile(file.esm, file.metadata;
        models=Dict{String,EarthSciAST.Model}(String(mname) => model),
        index_sets=file.index_sets,
        function_tables=file.function_tables)
    return MTK2.System(EarthSciAST.flatten(one_model); name=Symbol(mname))
end

# Run every inline test inside every model found in the given .esm file.
function _run_fixture(path::AbstractString)
    file = EarthSciAST.load(path)
    models_dict = file.models
    @assert models_dict !== nothing "Fixture $path has no models"
    for (mname, model) in models_dict
        sys = _fixture_system(file, String(mname), model)
        simp = MTK2.mtkcompile(sys)
        for t in model.tests
            @testset "$(mname)/$(t.id)" begin
                _run_fixture_test(simp, Symbol(mname), model.tolerance, t)
            end
        end
    end
end

@testset "Array-op runtime (gt-vt3 Phases 1-4)" begin

    # ================================================================
    # Case 1 — Pure ODE on u[i], N=5, analytical u_i(t) = i * exp(-t).
    #   lhs = arrayop (i,) D(u[i]) i in 1:5
    #   rhs = arrayop (i,) -u[i] i in 1:5
    # ================================================================
    @testset "1. Pure ODE N=5 analytical" begin
        N = 5
        vars = Dict{String,ESM2.ModelVariable}(
            "u" => ESM2.ModelVariable(ESM2.UnknownVariable),
        )
        lhs = _arrayop1d(_d_index("u", _var("i")), "i", 1, N)
        rhs = _arrayop1d(_op("-", _idx("u", _var("i"))), "i", 1, N)
        eq = ESM2.Equation(lhs, rhs)
        model = ESM2.Model(vars, ESM2.Equation[eq])

        sys = MTK2.System(model; name=:PureODE)
        simp = MTK2.mtkcompile(sys)
        @test length(MTK2.unknowns(simp)) == N

        u_handle = _arr(simp, :PureODE, "u")
        u0 = [u_handle[i] => Float64(i) for i in 1:N]
        prob = MTK2.ODEProblem(simp, u0, (0.0, 1.0))
        sol = OrdinaryDiffEqTsit5.solve(prob, OrdinaryDiffEqTsit5.Tsit5(); reltol=1e-8, abstol=1e-10)
        for i in 1:N
            @test sol[u_handle[i]][end] ≈ Float64(i) * exp(-1.0) rtol=1e-6
        end
    end

    # ================================================================
    # Case 2 — Mixed ODE + algebraic on v[i] ~ -u[i], N=5.
    # ================================================================
    @testset "2. Mixed ODE + algebraic (v eliminated)" begin
        N = 5
        vars = Dict{String,ESM2.ModelVariable}(
            "u" => ESM2.ModelVariable(ESM2.UnknownVariable),
            "v" => ESM2.ModelVariable(ESM2.UnknownVariable),
        )
        # D(u[i]) = v[i]
        eq_ode = ESM2.Equation(
            _arrayop1d(_d_index("u", _var("i")), "i", 1, N),
            _arrayop1d(_idx("v", _var("i")), "i", 1, N))
        # v[i] = -u[i]
        eq_alg = ESM2.Equation(
            _arrayop1d(_idx("v", _var("i")), "i", 1, N),
            _arrayop1d(_op("-", _idx("u", _var("i"))), "i", 1, N))
        model = ESM2.Model(vars, ESM2.Equation[eq_ode, eq_alg])

        sys = MTK2.System(model; name=:MixedODEAlg)
        simp = MTK2.mtkcompile(sys)
        @test length(MTK2.unknowns(simp)) == N  # v eliminated

        u_handle = _arr(simp, :MixedODEAlg, "u")
        u0 = [u_handle[i] => Float64(i) for i in 1:N]
        prob = MTK2.ODEProblem(simp, u0, (0.0, 1.0))
        sol = OrdinaryDiffEqTsit5.solve(prob, OrdinaryDiffEqTsit5.Tsit5(); reltol=1e-8, abstol=1e-10)
        for i in 1:N
            @test sol[u_handle[i]][end] ≈ Float64(i) * exp(-1.0) rtol=1e-6
        end
    end

    # ================================================================
    # Case 3 — 1-D diffusion stencil N=10 with Dirichlet BCs.
    #   interior: D(u[i]) = u[i-1] - 2u[i] + u[i+1]  for i in 2:9
    #   BC1:      D(u[1]) = u[2] - u[1]
    #   BC2:      D(u[10]) = u[9] - u[10]
    # Compared against a scalar-equation reference.
    # ================================================================
    @testset "3. 1D diffusion stencil N=10 vs scalar ref" begin
        N = 10
        vars = Dict{String,ESM2.ModelVariable}(
            "u" => ESM2.ModelVariable(ESM2.UnknownVariable),
        )
        # interior arrayop (1-based output range, offsets baked into body)
        body = _op("+",
            _idx("u", _var("i")),
            _op("*", _num(-2), _idx("u", _op("+", _var("i"), _num(1)))),
            _idx("u", _op("+", _var("i"), _num(2))))
        lint = _arrayop1d(_d_index("u", _op("+", _var("i"), _num(1))), "i", 1, N-2)
        rint = _arrayop1d(body, "i", 1, N-2)
        eq_int = ESM2.Equation(lint, rint)

        # Scalar BCs
        eq_bc1 = ESM2.Equation(
            _op("D", _idx("u", 1); wrt="t"),
            _op("-", _idx("u", 2), _idx("u", 1)))
        eq_bcN = ESM2.Equation(
            _op("D", _idx("u", N); wrt="t"),
            _op("-", _idx("u", N-1), _idx("u", N)))

        model = ESM2.Model(vars, ESM2.Equation[eq_int, eq_bc1, eq_bcN])

        sys = MTK2.System(model; name=:Diff1D)
        simp = MTK2.mtkcompile(sys)
        @test length(MTK2.unknowns(simp)) == N

        u_handle = _arr(simp, :Diff1D, "u")
        u0 = [u_handle[i] => (i == 5 ? 1.0 : 0.0) for i in 1:N]
        prob = MTK2.ODEProblem(simp, u0, (0.0, 0.5))
        sol = OrdinaryDiffEqTsit5.solve(prob, OrdinaryDiffEqTsit5.Tsit5(); reltol=1e-8, abstol=1e-10)
        @test sol.retcode == ModelingToolkit.SciMLBase.ReturnCode.Success

        # Mass conservation sanity: diffusion preserves the total.
        total_start = sum(sol[u_handle[i]][1] for i in 1:N)
        total_end = sum(sol[u_handle[i]][end] for i in 1:N)
        @test total_end ≈ total_start rtol=1e-6
    end

    # ================================================================
    # Case 6 — Rearranged algebraic equation form.
    #   (-1 - 0.5 * sin(u[i]) + v[i]) ~ (v[i] - v[i])
    # This tests that v is still substituted away when the algebraic
    # equation isn't in clean `v[i] ~ ...` form.
    # ================================================================
    @testset "6. Rearranged algebraic (v buried in LHS sum)" begin
        N = 5
        vars = Dict{String,ESM2.ModelVariable}(
            "u" => ESM2.ModelVariable(ESM2.UnknownVariable),
            "v" => ESM2.ModelVariable(ESM2.UnknownVariable),
        )
        # D(u[i]) = v[i]
        eq_ode = ESM2.Equation(
            _arrayop1d(_d_index("u", _var("i")), "i", 1, N),
            _arrayop1d(_idx("v", _var("i")), "i", 1, N))

        # Algebraic: (-1 - 0.5*sin(u[i]) + v[i]) ~ (v[i] - v[i])
        lhs_alg_body = _op("+",
            _num(-1.0),
            _op("*", _num(-0.5), _op("sin", _idx("u", _var("i")))),
            _idx("v", _var("i")))
        rhs_alg_body = _op("-", _idx("v", _var("i")), _idx("v", _var("i")))
        eq_alg = ESM2.Equation(
            _arrayop1d(lhs_alg_body, "i", 1, N),
            _arrayop1d(rhs_alg_body, "i", 1, N))

        model = ESM2.Model(vars, ESM2.Equation[eq_ode, eq_alg])
        sys = MTK2.System(model; name=:Rearranged)
        simp = MTK2.mtkcompile(sys)
        @test length(MTK2.unknowns(simp)) == N  # v eliminated

        u_handle = _arr(simp, :Rearranged, "u")
        u0 = [u_handle[i] => Float64(i) for i in 1:N]
        prob = MTK2.ODEProblem(simp, u0, (0.0, 1.0))
        sol = OrdinaryDiffEqTsit5.solve(prob, OrdinaryDiffEqTsit5.Tsit5(); reltol=1e-8, abstol=1e-10)
        @test sol.retcode == ModelingToolkit.SciMLBase.ReturnCode.Success
    end

    # ================================================================
    # Case 8 — 2-D ArrayOp on u[i,j], (M,N)=(4,3).
    # D(u[i,j]) = -u[i,j], analytical u_ij(t) = (i+j)*exp(-t).
    # ================================================================
    @testset "8. 2D ArrayOp (M,N)=(4,3) analytical" begin
        M, Nd = 4, 3
        vars = Dict{String,ESM2.ModelVariable}(
            "u" => ESM2.ModelVariable(ESM2.UnknownVariable),
        )
        lhs = _arrayop2d(_op("D", _idx("u", _var("i"), _var("j")); wrt="t"),
                         "i", 1, M, "j", 1, Nd)
        rhs = _arrayop2d(_op("-", _idx("u", _var("i"), _var("j"))),
                         "i", 1, M, "j", 1, Nd)
        eq = ESM2.Equation(lhs, rhs)
        model = ESM2.Model(vars, ESM2.Equation[eq])

        sys = MTK2.System(model; name=:ODE2D)
        simp = MTK2.mtkcompile(sys)
        @test length(MTK2.unknowns(simp)) == M * Nd

        u_handle = _arr(simp, :ODE2D, "u")
        u0 = [u_handle[i, j] => Float64(i + j) for i in 1:M for j in 1:Nd]
        prob = MTK2.ODEProblem(simp, u0, (0.0, 1.0))
        sol = OrdinaryDiffEqTsit5.solve(prob, OrdinaryDiffEqTsit5.Tsit5(); reltol=1e-8, abstol=1e-10)
        for i in 1:M, j in 1:Nd
            @test sol[u_handle[i, j]][end] ≈ Float64(i + j) * exp(-1.0) rtol=1e-6
        end
    end

    # ================================================================
    # Parse/serialize round trip smoke test for each array-op node.
    # ================================================================
    @testset "Parse/serialize round trip for all 7 array ops" begin
        # arrayop
        node1 = ESM2.OpExpr("arrayop", ESM2.ASTExpr[_var("A"), _var("B")];
            output_idx=Any["i", "j"],
            expr_body=_op("*",
                _op("index", _var("A"), _var("i"), _var("k")),
                _op("index", _var("B"), _var("k"), _var("j"))),
            reduce="+")
        j1 = ESM2.serialize_expression(node1)
        @test j1["op"] == "arrayop"
        @test j1["output_idx"] == Any["i", "j"]
        @test j1["reduce"] == "+"
        rt1 = ESM2.parse_expression(j1)
        @test rt1 isa ESM2.OpExpr
        @test rt1.output_idx == Any["i", "j"]
        @test rt1.reduce == "+"
        @test rt1.expr_body isa ESM2.OpExpr

        # makearray
        node2 = ESM2.OpExpr("makearray", ESM2.ASTExpr[];
            regions=[[[1, 2]], [[3, 3]]],
            values=ESM2.ASTExpr[_var("x"), _num(0)])
        j2 = ESM2.serialize_expression(node2)
        rt2 = ESM2.parse_expression(j2)
        @test rt2.regions == [[[1, 2]], [[3, 3]]]
        @test length(rt2.values) == 2

        # index
        node3 = ESM2.OpExpr("index", ESM2.ASTExpr[_var("u"), _num(1), _num(2)])
        j3 = ESM2.serialize_expression(node3)
        rt3 = ESM2.parse_expression(j3)
        @test rt3.op == "index"
        @test length(rt3.args) == 3

        # broadcast
        node4 = ESM2.OpExpr("broadcast", ESM2.ASTExpr[_var("A"), _var("B")]; fn="+")
        rt4 = ESM2.parse_expression(ESM2.serialize_expression(node4))
        @test rt4.fn == "+"

        # reshape
        node5 = ESM2.OpExpr("reshape", ESM2.ASTExpr[_var("A")]; shape=Any[1, 9])
        rt5 = ESM2.parse_expression(ESM2.serialize_expression(node5))
        @test rt5.shape == Any[1, 9]

        # transpose
        node6 = ESM2.OpExpr("transpose", ESM2.ASTExpr[_var("T")]; perm=[2, 0, 1])
        rt6 = ESM2.parse_expression(ESM2.serialize_expression(node6))
        @test rt6.perm == [2, 0, 1]

        # concat
        node7 = ESM2.OpExpr("concat", ESM2.ASTExpr[_var("A"), _var("B")]; axis=1)
        rt7 = ESM2.parse_expression(ESM2.serialize_expression(node7))
        @test rt7.axis == 1
    end

    # ================================================================
    # Shape inference sanity tests — scalar-only vs array cases.
    # ================================================================
    @testset "infer_array_shapes" begin
        # Scalar-only: empty dict.
        eq_scalar = ESM2.Equation(
            _op("D", _var("x"); wrt="t"),
            _op("-", _var("x")))
        @test isempty(infer_array_shapes([eq_scalar]))

        # 1D: u[i] over i in 1:5 → u has shape [1:5].
        eq_arr = ESM2.Equation(
            _arrayop1d(_d_index("u", _var("i")), "i", 1, 5),
            _arrayop1d(_op("-", _idx("u", _var("i"))), "i", 1, 5))
        shapes = infer_array_shapes([eq_arr])
        @test haskey(shapes, "u")
        @test shapes["u"] == [1:5]

        # 1D with offset: u[i] + u[i+2] where i in 1:8 → u has shape [1:10].
        body = _op("+",
            _idx("u", _var("i")),
            _idx("u", _op("+", _var("i"), _num(2))))
        eq_off = ESM2.Equation(
            _arrayop1d(_d_index("u", _op("+", _var("i"), _num(1))), "i", 1, 8),
            _arrayop1d(body, "i", 1, 8))
        shapes_off = infer_array_shapes([eq_off])
        @test shapes_off["u"] == [1:10]

        # 2D: u[i,j] over i in 1:4, j in 1:3 → shape [1:4, 1:3].
        eq_2d = ESM2.Equation(
            _arrayop2d(_op("D", _idx("u", _var("i"), _var("j")); wrt="t"),
                       "i", 1, 4, "j", 1, 3),
            _arrayop2d(_op("-", _idx("u", _var("i"), _var("j"))),
                       "i", 1, 4, "j", 1, 3))
        shapes_2d = infer_array_shapes([eq_2d])
        @test shapes_2d["u"] == [1:4, 1:3]
    end

    # ================================================================
    # Schema-driven fixture runner (Phase 5, gt-cc1 integration).
    # ================================================================
    #
    # Loads `.esm` files from `tests/fixtures/arrayop/` (repo root), builds the MTK
    # system via the full parse → flatten → System path, then executes
    # every inline `test` against the compiled system.
    @testset "Schema fixture runner" begin
        fixtures_dir = joinpath(@__DIR__, "..", "..", "..", "tests", "fixtures", "arrayop")
        fixture_files = sort(filter(f -> endswith(f, ".esm"), readdir(fixtures_dir)))
        @test !isempty(fixture_files)

        # Fixtures that require the tree-walk evaluator (build_evaluator) and cannot
        # be lowered through the MTK symbolic path. The MTK array indexing system
        # requires each subscript to be a function of a single symbolic variable;
        # generalized-einsum fixtures whose stencil body mixes output and contracted
        # indices in one subscript (e.g. u[i+1+k]) violate that constraint.
        mtk_skip = Set([
            "19_einsum_1d_stencil.esm",  # stencil index i+1+k has two symbolics
        ])

        for fname in fixture_files
            if fname in mtk_skip
                @testset "$(fname) [MTK_SKIP: einsum multi-index not supported]" begin
                    @test_skip false
                end
            else
                @testset "$(fname)" begin
                    _run_fixture(joinpath(fixtures_dir, fname))
                end
            end
        end
    end

    # ================================================================
    # Cumulative (prefix) reductions through the MTK path (esm-spec §4.3.1).
    #
    # These fixtures are why `_range_bounds_int` grew an `IndexSetRef` method.
    # Three things are pinned, because each failing silently is worse than the
    # `MethodError` this replaced:
    #
    #   1. DIAGNOSTICS — a range the MTK path cannot resolve must raise a
    #      descriptive `ArgumentError`. `System(::Model)` in particular cannot
    #      see the document-scoped index-set registry (`flatten(::Model)`
    #      synthesizes an EsmFile with an empty one), so it must decline
    #      loudly rather than MethodError or guess a bound.
    #   2. THE ADMITTED WINDOW — the MTK RHS must match the tree-walk
    #      evaluator, the reference implementation for these fixtures, cell by
    #      cell. An aggregate `filter` dropped on the floor would contract the
    #      FULL range (every fwd_inc cell = 15 instead of 1/3/7/15) and be
    #      caught here even if the fixture's own assertions were loosened.
    #   3. THE ORDER LIMITATION, honestly — §4.3.1 also makes the ascending-`j`
    #      LEFT FOLD normative, and this path does NOT honor it: SymbolicUtils
    #      emits the gated terms in its own canonical order. The bit-identity
    #      asserted in (2) holds only because those fixtures' summands are
    #      exactly representable and do not cancel. The cancellation case below
    #      is `@test_broken` so the suite records the gap instead of implying a
    #      guarantee this path cannot deliver — and flips to a failure the day
    #      someone makes the lowering order-preserving.
    # ================================================================
    @testset "Cumulative prefix reductions (MTK lowering)" begin
        MTKExt = Base.get_extension(EarthSciAST, :EarthSciASTMTKExt)
        @test MTKExt !== nothing

        # ---- 1. diagnostics: ArgumentError, never MethodError ----
        ref = EarthSciAST.IndexSetRef("x")
        @test MTKExt._range_bounds_int(ref, Dict("x" => 4)) == (1, 4)
        # Unresolvable set, ragged (`of`-parented) set, and a form that is
        # neither a dense array nor an index-set reference.
        @test_throws ArgumentError MTKExt._range_bounds_int(ref, Dict{String,Int}())
        @test_throws ArgumentError MTKExt._range_bounds_int(
            EarthSciAST.IndexSetRef("x"; of=["p"]), Dict("x" => 4))
        @test_throws ArgumentError MTKExt._range_bounds_int(:not_a_range)

        mname = "CumulativePrefixReduction"
        path = joinpath(@__DIR__, "..", "..", "..", "tests", "fixtures",
                        "arrayop", "25_cumulative_prefix_reduction.esm")
        file = EarthSciAST.load(path)
        model = file.models[mname]

        # No registry reachable from a bare `Model` ⇒ ArgumentError, not MethodError.
        @test_throws ArgumentError MTK2.System(model; name=Symbol(mname))

        # ---- 2. admitted window: MTK RHS ≡ tree-walk RHS, cell by cell ----
        # Exactly-representable summands (powers of two), no cancellation, so
        # the canonical term order cannot change the result: bit-identity here
        # is a real property of THIS fixture, not a general guarantee.
        f!, u0, p, _tspan, vm = EarthSciAST.build_evaluator(file)
        fill!(u0, 0.0)
        du_tw = zeros(length(u0))
        f!(du_tw, u0, p, 0.0)

        simp = MTK2.mtkcompile(_fixture_system(file, mname, model))
        unk = MTK2.unknowns(simp)
        prob = MTK2.ODEProblem(simp, Dict(u => 0.0 for u in unk), (0.0, 1.0))
        du_mtk = similar(prob.u0)
        prob.f(du_mtk, prob.u0, prob.p, 0.0)
        @test length(unk) == length(du_tw)
        for (k, u) in enumerate(unk)
            name = replace(string(u), "(t)" => "", "$(mname)_" => "",
                           "(" => "", ")" => "")
            @test haskey(vm, name)
            @test du_mtk[k] == du_tw[vm[name]]   # bit-identical, not approx
        end

        # ---- 3. accumulation order: the limitation, pinned as broken ----
        # Same prefix sum over u = [1e16, 1, -1e16, 1]. The §4.3.1 ascending-`j`
        # left fold gives [1e16, 1e16, 0, 1] — what the tree-walk produces. The
        # MTK path re-associates and gives [1e16, 1e16, 1, 2]: an O(1) error,
        # not a last-ulp one. Cells 1-2 agree (nothing has cancelled yet).
        # esm 1.0.0 §6.3: `u` is an `unknown` DEFINED by the bare-variable-LHS
        # equation `u ~ makearray(...)` — no variable-level `expression`.
        cancel = EarthSciAST.Model(
            Dict("u" => EarthSciAST.ModelVariable(EarthSciAST.UnknownVariable;
                     shape=["x"]),
                 "c" => EarthSciAST.ModelVariable(EarthSciAST.UnknownVariable;
                     shape=["x"], default=0.0)),
            [EarthSciAST.Equation(_var("u"),
                _op("makearray";
                    regions=[[[1, 1]], [[2, 2]], [[3, 3]], [[4, 4]]],
                    values=EarthSciAST.ASTExpr[_num(1e16), _num(1.0),
                                               _num(-1e16), _num(1.0)])),
             EarthSciAST.Equation(
                _op("aggregate"; output_idx=Any["i"],
                    expr_body=_op("D", _idx("c", _var("i")); wrt="t"),
                    ranges=Dict("i" => EarthSciAST.IndexSetRef("x"))),
                _op("aggregate", _var("u"); output_idx=Any["i"], reduce="+",
                    ranges=Dict("i" => EarthSciAST.IndexSetRef("x"),
                                "j" => EarthSciAST.IndexSetRef("x")),
                    filter=_op("<=", _var("j"), _var("i")),
                    expr_body=_idx("u", _var("j"))))])
        cfile = EarthSciAST.EsmFile(file.esm, file.metadata;
            models=Dict{String,EarthSciAST.Model}("Cancel" => cancel),
            index_sets=Dict("x" => EarthSciAST.IndexSet("interval"; size=4)))

        cf!, cu0, cp, _cts, cvm = EarthSciAST.build_evaluator(cfile)
        fill!(cu0, 0.0)
        cdu_tw = zeros(length(cu0))
        cf!(cdu_tw, cu0, cp, 0.0)
        # The tree-walk IS the normative left fold — assert that outright.
        @test cdu_tw[cvm["c[3]"]] == 0.0
        @test cdu_tw[cvm["c[4]"]] == 1.0

        csimp = MTK2.mtkcompile(_fixture_system(cfile, "Cancel", cancel))
        cunk = MTK2.unknowns(csimp)
        cprob = MTK2.ODEProblem(csimp, Dict(u => 0.0 for u in cunk), (0.0, 1.0))
        cdu_mtk = similar(cprob.u0)
        cprob.f(cdu_mtk, cprob.u0, cprob.p, 0.0)
        cell = Dict(replace(string(u), "(t)" => "", "Cancel_" => "",
                            "(" => "", ")" => "") => k
                    for (k, u) in enumerate(cunk))
        # Cells 1-2: nothing has cancelled, so the orders still coincide.
        @test cdu_mtk[cell["c[1]"]] == cdu_tw[cvm["c[1]"]]
        @test cdu_mtk[cell["c[2]"]] == cdu_tw[cvm["c[2]"]]
        # Cells 3-4: the re-association bites. SHOULD hold per §4.3.1; does not.
        @test_broken cdu_mtk[cell["c[3]"]] == cdu_tw[cvm["c[3]"]]
        @test_broken cdu_mtk[cell["c[4]"]] == cdu_tw[cvm["c[4]"]]
    end
end
