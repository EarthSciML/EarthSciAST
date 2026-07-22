# wall2 Phase D — OPTIONAL BLAS accelerator for the linear mat-vec observed.
#
# Layered on top of the Phase C compile-once evaluator, `evaluate_cellwise(…;
# blas_accel=true)` recognises the special linear sum-product shape
# `conc[out…] = Σ_c A[c,out…]·E[c]` (⊕=+, ⊗=·, A/E const arrays) and evaluates the
# WHOLE field with one BLAS `mul!` (`conc = A' · E`), reshaping A to (N_c × ∏out)
# for rank-≥2 output. It FALLS BACK to Phase C (the bit-identical-to-oracle
# baseline) for every other shape, and is off by default.
#
# These tests pin:
#   (1) AGREEMENT — for random A/E at rank-1 and rank-2 output over several bounded
#       shapes, the BLAS path agrees with the Phase C path to rtol 1e-10 (BLAS sums
#       in a different order ⇒ NOT bit-identical; the measured max rel-diff is
#       reported), plus the same for the elementwise-wrapped form f(conc);
#   (2) FALLBACK — a non-linear observed (max-semiring / non-affine body / runtime
#       filter) declines the BLAS path and is evaluated by Phase C, BIT-IDENTICAL;
#   (3) DEFAULT-OFF — with the flag off, output is byte-identical to the per-cell
#       baseline (BLAS, which differs in ULPs, is NOT silently engaged); and
#   (4) SPEED (bounded, informational) — BLAS vs Phase C at N_src=1520, N_rcv=2000.
#
# MEMORY SAFETY: bounded scale ONLY (N_src ≤ 1520, N_rcv ≤ 2000). The old
# per-cell path (`_eval_cellwise` per cell) is run ONLY at small N (≤ 128×60) as
# the bit-identity anchor; the Phase C comparison at scale uses the compile-once
# `evaluate_cellwise(…; blas_accel=false)`, which is bounded-memory.

using Test
using Random
using EarthSciAST

const ESM = EarthSciAST

# ---- hand-built aggregate AST (faithful to the ISRM ObservedVariable field) ----
_v(n) = VarExpr(String(n))
_num(x) = NumExpr(Float64(x))
_op(op, args...; kw...) = OpExpr(String(op), ESM.ASTExpr[args...]; kw...)
_idxv(var, ix...) = _op("index", _v(var), [_v(String(s)) for s in ix]...)

# conc[rcv] = Σ_c A[c,rcv]·E[c]
make_conc(N_src) = _op("aggregate"; output_idx = Any["rcv"], semiring = "sum_product",
    expr_body = _op("*", _idxv("A", "c", "rcv"), _idxv("E", "c")),
    ranges = Dict{String,Any}("c" => Any[1, N_src]))

# conc2[i,j] = Σ_c A3[c,i,j]·E[c]   (rank-2 output)
make_conc2(N_src) = _op("aggregate"; output_idx = Any["i", "j"], semiring = "sum_product",
    expr_body = _op("*", _idxv("A", "c", "i", "j"), _idxv("E", "c")),
    ranges = Dict{String,Any}("c" => Any[1, N_src]))

# deaths[rcv] = exp(k·conc[rcv]) − 1   (elementwise wrapper over the nested aggregate)
make_deaths(N_src; k = 1e-3) =
    _op("-", _op("exp", _op("*", _num(k), make_conc(N_src))), _num(1.0))

# ---- evaluation helpers -----------------------------------------------------
# Phase C (the correctness baseline): compile-once path, BLAS accelerator OFF.
_phaseC(expr, cells; ca, params = Dict{String,Float64}()) =
    ESM.evaluate_cellwise(expr, cells; const_arrays = ca, params = params, blas_accel = false)
# The BLAS accelerator path.
_blas(expr, cells; ca, params = Dict{String,Float64}()) =
    ESM.evaluate_cellwise(expr, cells; const_arrays = ca, params = params, blas_accel = true)
# The pre-Phase-C per-cell reference (SMALL N only — allocation-heavy at scale).
_percell(expr, cells; ca, params = Dict{String,Float64}()) =
    Float64[ESM._eval_cellwise(expr, collect(Int, c); const_arrays = ca, params = params)
            for c in cells]
# Does the BLAS recogniser engage on this shape?
_engages(expr, cells, ca; params = Dict{String,Float64}()) =
    ESM._evaluate_cellwise_blas(expr, cells, ca, Dict{String,Function}(), params) !== nothing

# max |a-b| / |b| over the field (atol=0 relative agreement; A/E>0 ⇒ b≠0).
_maxreldiff(a, b) = maximum(abs.(a .- b) ./ abs.(b))

_free_gib() = Sys.free_memory() / 2^30
# macOS `ps -o rss=` reports the resident set in KiB (1024-B units) ⇒ ÷2^10 = MiB.
_rss_mib() = parse(Int, split(read(`ps -o rss= -p $(getpid())`, String))[1]) / 2^10

@testset "wall2 Phase D — BLAS linear mat-vec accelerator" begin
    @info "Phase D start" free_GiB = round(_free_gib(); digits = 2) rss_MiB = round(_rss_mib(); digits = 1)

    global_maxrd = 0.0

    @testset "agreement vs Phase C — conc (rank 1)" begin
        for (N_src, N_rcv) in ((1, 1), (3, 7), (16, 4), (128, 60), (512, 300), (1520, 2000))
            cells = [[r] for r in 1:N_rcv]
            for seed in (0x11, 0x22)
                Random.seed!(seed)
                A = rand(N_src, N_rcv)
                E = rand(N_src)
                ca = Dict{String,Any}("A" => A, "E" => E)
                conc = make_conc(N_src)

                @test _engages(conc, cells, ca)          # BLAS path is what is under test
                bl = _blas(conc, cells; ca = ca)
                pc = _phaseC(conc, cells; ca = ca)
                @test isapprox(bl, pc; rtol = 1e-10, atol = 0.0)
                global_maxrd = max(global_maxrd, _maxreldiff(bl, pc))
            end
        end
    end

    @testset "agreement vs Phase C — conc2 (rank 2)" begin
        for (N_src, N_i, N_j) in ((4, 3, 2), (30, 6, 7), (200, 20, 25), (1520, 30, 40))
            cells = vec([[i, j] for i in 1:N_i, j in 1:N_j])
            for seed in (0xA1, 0xB2)
                Random.seed!(seed)
                A3 = rand(N_src, N_i, N_j)
                E = rand(N_src)
                ca = Dict{String,Any}("A" => A3, "E" => E)
                conc2 = make_conc2(N_src)

                @test _engages(conc2, cells, ca)
                bl = _blas(conc2, cells; ca = ca)
                pc = _phaseC(conc2, cells; ca = ca)
                @test isapprox(bl, pc; rtol = 1e-10, atol = 0.0)
                global_maxrd = max(global_maxrd, _maxreldiff(bl, pc))
            end
        end
    end

    @testset "agreement vs Phase C — elementwise-wrapped f(conc)" begin
        for (N_src, N_rcv) in ((16, 8), (300, 150), (1520, 2000))
            cells = [[r] for r in 1:N_rcv]
            Random.seed!(0xC3)
            A = rand(N_src, N_rcv)
            E = rand(N_src)
            ca = Dict{String,Any}("A" => A, "E" => E)
            # literal-k and parameter-k wrappers.
            deaths = make_deaths(N_src; k = 1e-3)
            deaths_p = _op("-", _op("exp", _op("*", _v("k"), make_conc(N_src))), _num(1.0))
            params = Dict{String,Float64}("k" => 2.5e-3)

            @test _engages(deaths, cells, ca)
            @test _engages(deaths_p, cells, ca; params = params)
            for (expr, ps) in ((deaths, Dict{String,Float64}()), (deaths_p, params))
                bl = _blas(expr, cells; ca = ca, params = ps)
                pc = _phaseC(expr, cells; ca = ca, params = ps)
                @test isapprox(bl, pc; rtol = 1e-10, atol = 0.0)
                global_maxrd = max(global_maxrd, _maxreldiff(bl, pc))
            end
        end
    end

    @info "measured max relative difference BLAS-vs-PhaseC" maxreldiff = global_maxrd tolerance_used = 1e-10
    @test global_maxrd < 1e-10

    @testset "fallback — non-linear observeds decline BLAS, stay bit-identical" begin
        N_src, N_rcv = 128, 60           # small enough to also anchor against _percell
        cells = [[r] for r in 1:N_rcv]
        Random.seed!(0xE5)
        A = rand(N_src, N_rcv)
        E = rand(N_src)
        ca = Dict{String,Any}("A" => A, "E" => E)

        # (a) max-semiring aggregate of the SAME shape — the soundness guard.
        maxagg = _op("aggregate"; output_idx = Any["rcv"], semiring = "max_product",
            expr_body = _op("*", _idxv("A", "c", "rcv"), _idxv("E", "c")),
            ranges = Dict{String,Any}("c" => Any[1, N_src]))
        # (b) non-affine body A[c,rcv]^2 · E[c] — not a plain product of index reads.
        sqagg = _op("aggregate"; output_idx = Any["rcv"], semiring = "sum_product",
            expr_body = _op("*", _op("^", _idxv("A", "c", "rcv"), _num(2.0)), _idxv("E", "c")),
            ranges = Dict{String,Any}("c" => Any[1, N_src]))
        # (c) runtime filter aggregate — restricts contributing terms.
        filtagg = _op("aggregate"; output_idx = Any["rcv"], semiring = "sum_product",
            expr_body = _op("*", _idxv("A", "c", "rcv"), _idxv("E", "c")),
            ranges = Dict{String,Any}("c" => Any[1, N_src]),
            filter = _op("<", _v("c"), _num(40.0)))

        for expr in (maxagg, sqagg, filtagg)
            @test !_engages(expr, cells, ca)                 # BLAS path DECLINES
            # …and evaluate_cellwise(blas on) falls back to Phase C, bit-for-bit.
            @test _blas(expr, cells; ca = ca) == _phaseC(expr, cells; ca = ca)
            # …which is itself the bit-identical per-cell baseline.
            @test _phaseC(expr, cells; ca = ca) == _percell(expr, cells; ca = ca)
        end
    end

    @testset "default off — byte-identical to the per-cell baseline" begin
        N_src, N_rcv = 128, 60
        cells = [[r] for r in 1:N_rcv]
        Random.seed!(0xD4)
        A = rand(N_src, N_rcv)
        E = rand(N_src)
        ca = Dict{String,Any}("A" => A, "E" => E)

        for expr in (make_conc(N_src), make_deaths(N_src; k = 1e-3))
            # No kwarg (default) == explicit blas_accel=false == the per-cell oracle.
            default = ESM.evaluate_cellwise(expr, cells; const_arrays = ca)
            @test default == _phaseC(expr, cells; ca = ca)
            @test default == _percell(expr, cells; ca = ca)
        end
    end

    @testset "speed (bounded, informational) — BLAS vs Phase C" begin
        N_src, N_rcv = 1520, 2000
        @info "speed bench pre-alloc" free_GiB = round(_free_gib(); digits = 2) rss_MiB = round(_rss_mib(); digits = 1)
        Random.seed!(0xF6)
        A = rand(N_src, N_rcv)           # 1520×2000×8 B ≈ 24 MiB
        E = rand(N_src)
        ca = Dict{String,Any}("A" => A, "E" => E)
        cells = [[r] for r in 1:N_rcv]
        conc = make_conc(N_src)

        # correctness at bench scale, then timing.
        bl = _blas(conc, cells; ca = ca)
        pc = _phaseC(conc, cells; ca = ca)
        @test isapprox(bl, pc; rtol = 1e-10, atol = 0.0)

        bench(f) = (f(); minimum(@elapsed(f()) for _ in 1:5))
        t_blas = bench(() -> _blas(conc, cells; ca = ca))
        t_pc = bench(() -> _phaseC(conc, cells; ca = ca))
        @info "speed" N_src N_rcv blas_s = t_blas phaseC_s = t_pc speedup = round(t_pc / t_blas; digits = 1) rss_MiB = round(_rss_mib(); digits = 1)
        @test t_blas < t_pc               # BLAS is faster at this scale
    end

    @info "Phase D done" free_GiB = round(_free_gib(); digits = 2) rss_MiB = round(_rss_mib(); digits = 1)
end
