# wall2 Phase C — correctness + performance pins for the compile-once cellwise
# evaluator (THE Wall #2 fix).
#
# `evaluate_cellwise` now resolves+compiles a contracting observed body ONCE with
# the output indices bound as PARAMETERS, then evaluates each output cell by
# rebinding only those params (a const read carrying an output index lowers to a
# runtime `_NK_CONST_GATHER`; every contracted index still unrolls to the SAME
# concrete value in the SAME order). These tests pin the two properties the fix
# rests on:
#
#   (1) BIT-IDENTITY — for the aggregate `conc[rcv] = Σ_c A[c,rcv]·E[c]` AND the
#       nested downstream `deaths[rcv] = exp(k·conc[rcv]) − 1` wrapping it, the
#       compile-once result is `==` (bit-exact Float64) to the per-cell path
#       (`_eval_cellwise`, one cell at a time — the pre-Phase-C reference), over
#       many random A/E and several N_rcv × N_src, at rank 1 AND rank 2;
#   (2) the per-cell closure is TYPE-STABLE (`@inferred` → Float64) and its hot
#       call is ALLOCATION-FREE (`@allocated == 0` after warmup); and
#   (3) the fast path ENGAGES for these shapes (so (1)/(2) test compile-once, not
#       the fallback), while a join/filter aggregate correctly FALLS BACK and is
#       still bit-identical via the per-cell loop.

using Test
using Random
using InteractiveUtils
using EarthSciAST

const ESM = EarthSciAST

# ---- hand-built aggregate AST (faithful to the ISRM ObservedVariable field) ----
_v(n) = VarExpr(String(n))
_num(x) = NumExpr(Float64(x))
_op(op, args...; kw...) = OpExpr(String(op), ESM.ASTExpr[args...]; kw...)
_idxv(var, ix...) = _op("index", _v(var), [_v(String(s)) for s in ix]...)

# conc[rcv] = Σ_c A[c,rcv]·E[c]   (contracting aggregate over const arrays)
make_conc(N_src) = _op("aggregate"; output_idx = Any["rcv"], semiring = "sum_product",
    expr_body = _op("*", _idxv("A", "c", "rcv"), _idxv("E", "c")),
    ranges = Dict{String,Any}("c" => Any[1, N_src]))

# deaths[rcv] = exp(k·conc[rcv]) − 1   (elementwise wrapper over the nested aggregate)
make_deaths(N_src; k = 1e-3) =
    _op("-", _op("exp", _op("*", _num(k), make_conc(N_src))), _num(1.0))

# conc2[i,j] = Σ_c A3[c,i,j]·E[c]   (rank-2 output; two symbolic output indices)
make_conc2(N_src) = _op("aggregate"; output_idx = Any["i", "j"], semiring = "sum_product",
    expr_body = _op("*", _idxv("A", "c", "i", "j"), _idxv("E", "c")),
    ranges = Dict{String,Any}("c" => Any[1, N_src]))

# The exact per-cell reference (pre-Phase-C path): resolve+compile+eval one cell.
_percell(expr, cells; ca, params = Dict{String,Float64}()) =
    Float64[ESM._eval_cellwise(expr, collect(Int, c); const_arrays = ca, params = params)
            for c in cells]

@testset "wall2 Phase C — compile-once cellwise evaluator" begin

    @testset "bit-identity vs per-cell — conc & deaths (rank 1)" begin
        for (N_src, N_rcv) in ((1, 1), (3, 7), (16, 4), (40, 25), (128, 60))
            cells = [[r] for r in 1:N_rcv]
            for seed in (0x11, 0x22, 0x33)
                Random.seed!(seed)
                A = rand(N_src, N_rcv)
                E = rand(N_src)
                ca = Dict{String,Any}("A" => A, "E" => E)

                conc = make_conc(N_src)
                deaths = make_deaths(N_src; k = 1e-3)

                # `evaluate_cellwise` drives the compile-once fast path…
                conc_fast = ESM.evaluate_cellwise(conc, cells; const_arrays = ca)
                deaths_fast = ESM.evaluate_cellwise(deaths, cells; const_arrays = ca)
                # …compared bit-for-bit against the per-cell reference.
                @test conc_fast == _percell(conc, cells; ca = ca)
                @test deaths_fast == _percell(deaths, cells; ca = ca)

                # The fast path must actually be the thing under test here.
                @test ESM._cellwise_compile_once(conc, 1, ca,
                    Dict{String,Function}(), Dict{String,Float64}()) !== nothing
                @test ESM._cellwise_compile_once(deaths, 1, ca,
                    Dict{String,Function}(), Dict{String,Float64}()) !== nothing
            end
        end
    end

    @testset "bit-identity vs per-cell — rank-2 aggregate" begin
        for (N_src, N_i, N_j) in ((4, 3, 2), (12, 5, 4), (30, 6, 7))
            cells = vec([[i, j] for i in 1:N_i, j in 1:N_j])
            for seed in (0xA1, 0xB2)
                Random.seed!(seed)
                A3 = rand(N_src, N_i, N_j)
                E = rand(N_src)
                ca = Dict{String,Any}("A" => A3, "E" => E)
                conc2 = make_conc2(N_src)

                fast = ESM.evaluate_cellwise(conc2, cells; const_arrays = ca)
                @test fast == _percell(conc2, cells; ca = ca)
                @test ESM._cellwise_compile_once(conc2, 2, ca,
                    Dict{String,Function}(), Dict{String,Float64}()) !== nothing
            end
        end
    end

    @testset "bit-identity vs per-cell — parameter-dependent wrapper" begin
        # k as a MODEL PARAMETER (load-time constant) rather than a literal.
        N_src, N_rcv = 24, 18
        Random.seed!(0xC3)
        A = rand(N_src, N_rcv)
        E = rand(N_src)
        ca = Dict{String,Any}("A" => A, "E" => E)
        cells = [[r] for r in 1:N_rcv]
        deaths_p = _op("-", _op("exp", _op("*", _v("k"), make_conc(N_src))), _num(1.0))
        params = Dict{String,Float64}("k" => 2.5e-3)

        fast = ESM.evaluate_cellwise(deaths_p, cells; const_arrays = ca, params = params)
        @test fast == _percell(deaths_p, cells; ca = ca, params = params)
        @test ESM._cellwise_compile_once(deaths_p, 1, ca,
            Dict{String,Function}(), params) !== nothing
    end

    @testset "per-cell closure — type-stable + allocation-free" begin
        N_src, N_rcv = 64, 30
        Random.seed!(0xD4)
        A = rand(N_src, N_rcv)
        E = rand(N_src)
        ca = Dict{String,Any}("A" => A, "E" => E)
        cell = [7]                    # pre-allocated OUTSIDE any measurement

        for expr in (make_conc(N_src), make_deaths(N_src; k = 1e-3))
            ce = ESM._cellwise_compile_once(expr, 1, ca,
                Dict{String,Function}(), Dict{String,Float64}())
            @test ce !== nothing
            ce(cell)                  # warmup / JIT
            @test (@inferred ce(cell)) isa Float64
            @test (@allocated ce(cell)) == 0
        end

        # Parameter-dependent closure is zero-alloc too (params captured once).
        deaths_p = _op("-", _op("exp", _op("*", _v("k"), make_conc(N_src))), _num(1.0))
        cep = ESM._cellwise_compile_once(deaths_p, 1, ca,
            Dict{String,Function}(), Dict{String,Float64}("k" => 1e-3))
        @test cep !== nothing
        cep(cell)
        @test (@inferred cep(cell)) isa Float64
        @test (@allocated cep(cell)) == 0
    end

    @testset "unsupported constructs fall back — still bit-identical" begin
        N_src, N_rcv = 20, 15
        Random.seed!(0xE5)
        A = rand(N_src, N_rcv)
        E = rand(N_src)
        ca = Dict{String,Any}("A" => A, "E" => E)
        cells = [[r] for r in 1:N_rcv]

        # A runtime `filter` on the aggregate is NOT handled on the symbolic path.
        aggf = _op("aggregate"; output_idx = Any["rcv"], semiring = "sum_product",
            expr_body = _op("*", _idxv("A", "c", "rcv"), _idxv("E", "c")),
            ranges = Dict{String,Any}("c" => Any[1, N_src]),
            filter = _op("<", _v("c"), _num(10.0)))
        # It must DECLINE the fast path…
        @test ESM._cellwise_compile_once(aggf, 1, ca,
            Dict{String,Function}(), Dict{String,Float64}()) === nothing
        # …and `evaluate_cellwise` must fall back to the per-cell path, bit-exactly.
        @test ESM.evaluate_cellwise(aggf, cells; const_arrays = ca) ==
              _percell(aggf, cells; ca = ca)
    end
end
