# The optional BLAS accelerator of `evaluate_cellwise(…; blas_accel = true)`
# (src/inline_tests.jl).
#
# It recognises the linear sum-product shape `conc[out…] = Σ_c A[c,out…]·E[c]`
# (⊕ = +, ⊗ = ·, A and E const arrays) and evaluates the whole field with one
# BLAS `mul!` (`conc = A' · E`), reshaping A to (N_c × ∏out) for rank-≥2 output.
# It falls back to the compile-once path (bit-identical to the per-cell oracle)
# for every other shape, and is off by default. Pinned here:
#   (1) agreement with the compile-once path to rtol 1e-10 at rank-1 and rank-2
#       output and for an elementwise-wrapped f(conc) (BLAS sums in a different
#       order, so not bit-identical);
#   (2) fallback: a non-linear observed (max semiring, non-affine body, runtime
#       filter) declines the BLAS path and stays bit-identical;
#   (3) default off: without the keyword the output is byte-identical to the
#       per-cell baseline.
module EvaluateCellwiseBlasAccelTest

using Test
using Random
using EarthSciAST

const ESM = EarthSciAST

# ---- hand-built aggregate AST (faithful to the ISRM observed-unknown field) ----
_v(n) = VarExpr(String(n))
_num(x) = NumExpr(Float64(x))
_op(op, args...; kw...) = OpExpr(String(op), ESM.ASTExpr[args...]; kw...)
_idxv(var, ix...) = _op("index", _v(var), [_v(String(s)) for s in ix]...)

# conc[rcv] = Σ_c A[c,rcv]·E[c]
make_conc(N_src) = _op(
    "faq"; output_idx = Any["rcv"], semiring = "sum_product",
    expr_body = _op("*", _idxv("A", "c", "rcv"), _idxv("E", "c")),
    ranges = Dict{String, Any}("c" => Any[1, N_src])
)

# conc2[i,j] = Σ_c A3[c,i,j]·E[c]   (rank-2 output)
make_conc2(N_src) = _op(
    "faq"; output_idx = Any["i", "j"], semiring = "sum_product",
    expr_body = _op("*", _idxv("A", "c", "i", "j"), _idxv("E", "c")),
    ranges = Dict{String, Any}("c" => Any[1, N_src])
)

# deaths[rcv] = exp(k·conc[rcv]) − 1   (elementwise wrapper over the nested aggregate)
make_deaths(N_src; k = 1.0e-3) =
    _op("-", _op("exp", _op("*", _num(k), make_conc(N_src))), _num(1.0))

# ---- evaluation helpers -----------------------------------------------------
# The correctness baseline: the compile-once path, BLAS accelerator OFF.
_compile_once(expr, cells; ca, params = Dict{String, Float64}()) =
    ESM.evaluate_cellwise(expr, cells; const_arrays = ca, params = params, blas_accel = false)
# The BLAS accelerator path.
_blas(expr, cells; ca, params = Dict{String, Float64}()) =
    ESM.evaluate_cellwise(expr, cells; const_arrays = ca, params = params, blas_accel = true)
# The per-cell reference (SMALL N only — allocation-heavy at scale).
_percell(expr, cells; ca, params = Dict{String, Float64}()) =
    Float64[
    ESM._eval_cellwise(ESM._PerCellLicense(), expr, collect(Int, c); const_arrays = ca, params = params)
        for c in cells
]
# Does the BLAS recogniser engage on this shape?
_engages(expr, cells, ca; params = Dict{String, Float64}()) =
    ESM._evaluate_cellwise_blas(expr, cells, ca, params) !== nothing

# max |a-b| / |b| over the field (atol=0 relative agreement; A/E>0 ⇒ b≠0).
_maxreldiff(a, b) = maximum(abs.(a .- b) ./ abs.(b))

@testset "evaluate_cellwise(…; blas_accel = true)" begin
    global_maxrd = 0.0

    @testset "agreement with the compile-once path — conc (rank 1)" begin
        for (N_src, N_rcv) in ((1, 1), (3, 7), (16, 4), (128, 60), (512, 300), (1520, 2000))
            cells = [[r] for r in 1:N_rcv]
            for seed in (0x11, 0x22)
                Random.seed!(seed)
                A = rand(N_src, N_rcv)
                E = rand(N_src)
                ca = Dict{String, Any}("A" => A, "E" => E)
                conc = make_conc(N_src)

                @test _engages(conc, cells, ca)          # BLAS path is what is under test
                bl = _blas(conc, cells; ca = ca)
                pc = _compile_once(conc, cells; ca = ca)
                @test isapprox(bl, pc; rtol = 1.0e-10, atol = 0.0)
                global_maxrd = max(global_maxrd, _maxreldiff(bl, pc))
            end
        end
    end

    @testset "agreement with the compile-once path — conc2 (rank 2)" begin
        for (N_src, N_i, N_j) in ((4, 3, 2), (30, 6, 7), (200, 20, 25), (1520, 30, 40))
            cells = vec([[i, j] for i in 1:N_i, j in 1:N_j])
            for seed in (0xA1, 0xB2)
                Random.seed!(seed)
                A3 = rand(N_src, N_i, N_j)
                E = rand(N_src)
                ca = Dict{String, Any}("A" => A3, "E" => E)
                conc2 = make_conc2(N_src)

                @test _engages(conc2, cells, ca)
                bl = _blas(conc2, cells; ca = ca)
                pc = _compile_once(conc2, cells; ca = ca)
                @test isapprox(bl, pc; rtol = 1.0e-10, atol = 0.0)
                global_maxrd = max(global_maxrd, _maxreldiff(bl, pc))
            end
        end
    end

    @testset "agreement with the compile-once path — elementwise-wrapped f(conc)" begin
        for (N_src, N_rcv) in ((16, 8), (300, 150), (1520, 2000))
            cells = [[r] for r in 1:N_rcv]
            Random.seed!(0xC3)
            A = rand(N_src, N_rcv)
            E = rand(N_src)
            ca = Dict{String, Any}("A" => A, "E" => E)
            # literal-k and parameter-k wrappers.
            deaths = make_deaths(N_src; k = 1.0e-3)
            deaths_p = _op("-", _op("exp", _op("*", _v("k"), make_conc(N_src))), _num(1.0))
            params = Dict{String, Float64}("k" => 2.5e-3)

            @test _engages(deaths, cells, ca)
            @test _engages(deaths_p, cells, ca; params = params)
            for (expr, ps) in ((deaths, Dict{String, Float64}()), (deaths_p, params))
                bl = _blas(expr, cells; ca = ca, params = ps)
                pc = _compile_once(expr, cells; ca = ca, params = ps)
                @test isapprox(bl, pc; rtol = 1.0e-10, atol = 0.0)
                global_maxrd = max(global_maxrd, _maxreldiff(bl, pc))
            end
        end
    end

    @info "measured max relative difference, BLAS vs compile-once" maxreldiff = global_maxrd tolerance_used = 1.0e-10
    @test global_maxrd < 1.0e-10

    @testset "fallback — non-linear observeds decline BLAS, stay bit-identical" begin
        N_src, N_rcv = 128, 60           # small enough to also anchor against _percell
        cells = [[r] for r in 1:N_rcv]
        Random.seed!(0xE5)
        A = rand(N_src, N_rcv)
        E = rand(N_src)
        ca = Dict{String, Any}("A" => A, "E" => E)

        # (a) max-semiring aggregate of the SAME shape — the soundness guard.
        maxagg = _op(
            "faq"; output_idx = Any["rcv"], semiring = "max_product",
            expr_body = _op("*", _idxv("A", "c", "rcv"), _idxv("E", "c")),
            ranges = Dict{String, Any}("c" => Any[1, N_src])
        )
        # (b) non-affine body A[c,rcv]^2 · E[c] — not a plain product of index reads.
        sqagg = _op(
            "faq"; output_idx = Any["rcv"], semiring = "sum_product",
            expr_body = _op("*", _op("^", _idxv("A", "c", "rcv"), _num(2.0)), _idxv("E", "c")),
            ranges = Dict{String, Any}("c" => Any[1, N_src])
        )
        # (c) runtime filter aggregate — restricts contributing terms.
        filtagg = _op(
            "faq"; output_idx = Any["rcv"], semiring = "sum_product",
            expr_body = _op("*", _idxv("A", "c", "rcv"), _idxv("E", "c")),
            ranges = Dict{String, Any}("c" => Any[1, N_src]),
            filter = _op("<", _v("c"), _num(40.0))
        )

        for expr in (maxagg, sqagg, filtagg)
            @test !_engages(expr, cells, ca)                 # BLAS path DECLINES
            # …and evaluate_cellwise(blas on) falls back to the compile-once path, bit-for-bit.
            @test _blas(expr, cells; ca = ca) == _compile_once(expr, cells; ca = ca)
            # …which is itself the bit-identical per-cell baseline.
            @test _compile_once(expr, cells; ca = ca) == _percell(expr, cells; ca = ca)
        end
    end

    @testset "default off — byte-identical to the per-cell baseline" begin
        N_src, N_rcv = 128, 60
        cells = [[r] for r in 1:N_rcv]
        Random.seed!(0xD4)
        A = rand(N_src, N_rcv)
        E = rand(N_src)
        ca = Dict{String, Any}("A" => A, "E" => E)

        for expr in (make_conc(N_src), make_deaths(N_src; k = 1.0e-3))
            # No kwarg (default) == explicit blas_accel=false == the per-cell oracle.
            default = ESM.evaluate_cellwise(expr, cells; const_arrays = ca)
            @test default == _compile_once(expr, cells; ca = ca)
            @test default == _percell(expr, cells; ca = ca)
        end
    end
end

end # module
