# The codegen tier's threaded cell axis (codegen_kernel.jl, "Threaded cell
# axis for the codegen tier"; partition + opt-in semantics shared with the
# tape's axis in access_kernel.jl).
#
# Pinned here:
#   1. PARTITION — `_chunk_ordinals` tiles `[0, n)` exactly (in order, sizes
#      differing by at most one), including the empty-chunk edge (`nchunks > n`).
#   2. CHUNK-INSTANCE DECOMPOSITION — the generated function's `(c, nchunks)`
#      instances, run sequentially in THIS process, reproduce the serial
#      `(1, 1)` du bitwise (`===`, so NaN/-0.0 count) for every cell-set kind
#      the emitter chunks: outs/contig, rank-1, rank-2, and rank-3 boxes.
#      This pins the chunked loop-bound arithmetic (the row clamps of the
#      rank-2/3 nests) with no threads involved — under Polyester the chunks
#      only ever run concurrently, which cannot change per-cell values when
#      the out-slots are disjoint (the build-time check below).
#   3. DISJOINTNESS — `_cellset_outs_disjoint!` catches duplicates within an
#      outs set AND across cell sets (contiguous ranges included, unlike the
#      tape's per-kernel `_plan_output_disjoint`); real builds carry
#      `outs_disjoint == true` into the section caches, and a poisoned cache
#      yields the permanent `:cg_serial_shared_outs` verdict.
#   4. THREADED EXECUTION (subprocess, `julia -t 4` + Polyester, mirroring the
#      in-process env-toggle discipline of the other codegen tests — there is
#      no in-suite precedent for a threaded run, since the tape's own threaded
#      tier predates any threaded test): du bit-identity threaded vs the
#      ESS_CG_THREADS_DISABLE=1 serial oracle (same build, same routing) and
#      vs an ESS_CODEGEN_DISABLE=1 build; `:cg_threaded` in `_THREAD_TALLY`;
#      the min-cells threshold (`:cg_serial_small` at the 512-cell default on
#      a small section); ESS_THREADS_DISABLE=1 keeping the section unexamined;
#      and the budget-0 OVERFLOW function threading the same way (the routing
#      that used to defer to the tape whenever threading was active).
# The subprocess block is skipped (with a warning) when Polyester is not
# available in the active environment — it is a weakdep and not a test target
# dependency, exactly like the tape's threaded tier itself.
using Test
using EarthSciAST
include("testutils.jl")
const ESM = EarthSciAST

# ---- shared fixtures ---------------------------------------------------------

# Two-variable 1-D elementwise model: a contig cell set (first state block)
# plus a base-offset rank-1 box (second block). Tape-class (lane plans exist),
# so the budget-0 build exercises the overflow function too.
function _cgt_1d_model(N)
    ubody = _op("+",
        _op("ifelse", _op(">", _idx("u", _v("i")), _n(2.0)),
            _op("log", _idx("u", _v("i"))),
            _op("sin", _idx("u", _v("i")))),
        _op("*", _n(-0.5), _idx("v", _v("i"))))
    vbody = _op("*",
        _op("exp", _op("*", _n(-0.3), _idx("v", _v("i")))),
        _op("+", _n(1.0), _op("*", _n(0.25), _op("cos", _idx("u", _v("i"))))))
    eq(x, body) = ESM.Equation(_ao1(_Didx(x, _v("i")), "i", 1, N),
                               _ao1(body, "i", 1, N))
    vars = Dict{String,ESM.ModelVariable}(
        n => ESM.ModelVariable(ESM.StateVariable) for n in ("u", "v"))
    ESM.Model(vars, [eq("u", ubody), eq("v", vbody)])
end
_cgt_1d_ics(N) = Dict("$x[$k]" => 2.0 + sin(0.3k + 0.1j)
                      for (j, x) in enumerate(("u", "v")), k in 1:N)

# 2-D 5-point Laplacian over full ranges: the stencil pass decomposes it into
# an interior rank-2 box plus boundary regions — the rank-2 chunked nest.
function _cgt_2d_model(N)
    vars = Dict("u" => ESM.ModelVariable(ESM.StateVariable; shape=["i", "j"]))
    body = _op("+",
        _idx("u", _op("-", _v("i"), _i(1)), _v("j")),
        _op("*", _n(-4.0), _idx("u", _v("i"), _v("j"))),
        _idx("u", _op("+", _v("i"), _i(1)), _v("j")),
        _idx("u", _v("i"), _op("-", _v("j"), _i(1))),
        _idx("u", _v("i"), _op("+", _v("j"), _i(1))))
    lhs = ESM.OpExpr("arrayop", ESM.ASTExpr[]; output_idx=Any["i", "j"],
        expr_body=_Didx("u", _v("i"), _v("j")),
        ranges=Dict("i" => [1, N], "j" => [1, N]))
    rhs = ESM.OpExpr("arrayop", ESM.ASTExpr[]; output_idx=Any["i", "j"],
        expr_body=body, ranges=Dict("i" => [1, N], "j" => [1, N]))
    ESM.Model(vars, [ESM.Equation(lhs, rhs)])
end
_cgt_2d_ics(N) = Dict("u[$i,$j]" => sin(0.3i) * cos(0.2j) + 0.05i
                      for i in 1:N, j in 1:N)

# 3-D 7-point Laplacian, same construction — the rank-3 chunked nest.
function _cgt_3d_model(Ni, Nj, Nk)
    vars = Dict("u" => ESM.ModelVariable(ESM.StateVariable; shape=["i", "j", "k"]))
    u(i, j, k) = _idx("u", i, j, k)
    I = _v("i"); J = _v("j"); K = _v("k")
    body = _op("+",
        u(_op("-", I, _i(1)), J, K), u(_op("+", I, _i(1)), J, K),
        u(I, _op("-", J, _i(1)), K), u(I, _op("+", J, _i(1)), K),
        u(I, J, _op("-", K, _i(1))), u(I, J, _op("+", K, _i(1))),
        _op("*", _n(-6.0), u(I, J, K)))
    rng = Dict("i" => [1, Ni], "j" => [1, Nj], "k" => [1, Nk])
    lhs = ESM.OpExpr("arrayop", ESM.ASTExpr[]; output_idx=Any["i", "j", "k"],
        expr_body=_Didx("u", I, J, K), ranges=rng)
    rhs = ESM.OpExpr("arrayop", ESM.ASTExpr[]; output_idx=Any["i", "j", "k"],
        expr_body=body, ranges=rng)
    ESM.Model(vars, [ESM.Equation(lhs, rhs)])
end
_cgt_3d_ics(Ni, Nj, Nk) = Dict("u[$i,$j,$k]" => sin(0.3i) * cos(0.2j) + 0.07k
                               for i in 1:Ni, j in 1:Nj, k in 1:Nk)

function _cgt_build(model, ics; env...)
    withenv((String(k) => v for (k, v) in pairs(env))...) do
        ESM._reset_cascade_tally!()
        f!, u0, p, _t, vm, diag = ESM._build_evaluator_impl(model;
            initial_conditions=ics)
        (f!, u0, p, copy(ESM._CASCADE_TALLY))
    end
end

_cgt_du(f!, u, p, t) = (d = similar(u); fill!(d, 0.0); f!(d, u, p, t); d)
_cgt_bitsame(a, b) = size(a) == size(b) && all(a .=== b)

# The section's box-kernel ranks, read off an ESS_CODEGEN_DISABLE=1 build
# (where `kernels` holds EVERY kernel — the grid_invariance idiom; the kernel
# IR under the runners is build-invariant, so the ranks apply to the emitting
# build too).
function _cgt_ranks(model, ics)
    f!, _, _, _ = _cgt_build(model, ics; ESS_CODEGEN_DISABLE="1")
    ks = getfield(f!, :kernel_section)
    [length(K.cells.strides) for K in getfield(ks, :kernels)]
end

if get(ENV, "ESS_CGT_CHILD", "") == "1"
    # =========================================================================
    # CHILD: threaded end-to-end (spawned below with `-t 4` and a Polyester-
    # capable project; everything here may assume Polyester loads).
    # =========================================================================
    using Polyester

    @testset "codegen threaded cell axis (child, $(Threads.nthreads()) threads)" begin
        @test Threads.nthreads() >= 2
        @test ESM._polyester_loaded()
        @test ESM._threads_available()

        N = 512                       # 1024 cells: 2 chunks at the 512 default
        model = _cgt_1d_model(N)
        ics = _cgt_1d_ics(N)
        probes = [(u, t) for u in (nothing, :probe) for t in (0.0, 0.7)]

        @testset "primary RGF: threaded ≡ ESS_CG_THREADS_DISABLE oracle ≡ no-codegen" begin
            ESM._reset_thread_tally!()
            fA, uA, pA, tallyA = _cgt_build(model, ics)
            fR, uR, pR, _ = _cgt_build(model, ics; ESS_CODEGEN_DISABLE="1")
            @test get(tallyA, :codegen_kernel, 0) >= 1
            ksA = getfield(fA, :kernel_section)
            @test getfield(ksA, :tcache).disjoint      # build-time global check
            for k in 1:4, t in (0.0, 0.7, 3.25)
                u = k == 1 ? copy(uA) :
                    Float64[2.0 + 1.3 * sin(1.3i + 0.7k) * cos(0.31i * k) + 0.01i
                            for i in 1:length(uA)]
                du_thr = _cgt_du(fA, u, pA, t)
                du_ser = withenv("ESS_CG_THREADS_DISABLE" => "1") do
                    _cgt_du(fA, u, pA, t)      # same build, serial (1,1) route
                end
                du_ref = _cgt_du(fR, u, pR, t)
                @test _cgt_bitsame(du_thr, du_ser)
                @test _cgt_bitsame(du_thr, du_ref)
            end
            # The threaded route really engaged (verdict cached + tallied).
            @test getfield(ksA, :tcache).state == 1
            @test getfield(ksA, :tcache).nchunks >= 2
            @test get(ESM._THREAD_TALLY, :cg_threaded, 0) >= 1
        end

        @testset "min-cells threshold: small section stays serial" begin
            ESM._reset_thread_tally!()
            fS, uS, pS, _ = _cgt_build(_cgt_1d_model(48), _cgt_1d_ics(48))
            du = _cgt_du(fS, uS, pS, 0.3)     # 96 cells < 512 ⇒ serial verdict
            @test getfield(getfield(fS, :kernel_section), :tcache).state == -1
            @test get(ESM._THREAD_TALLY, :cg_serial_small, 0) >= 1
            @test get(ESM._THREAD_TALLY, :cg_threaded, 0) == 0
            @test any(x -> x !== 0.0, du)
            # ... and a lowered threshold flips the SAME model to threaded.
            ESM._reset_thread_tally!()
            fT, uT, pT, _ = _cgt_build(_cgt_1d_model(48), _cgt_1d_ics(48))
            duT = withenv("ESS_THREADS_MIN_CELLS" => "8") do
                _cgt_du(fT, uT, pT, 0.3)
            end
            @test getfield(getfield(fT, :kernel_section), :tcache).state == 1
            @test get(ESM._THREAD_TALLY, :cg_threaded, 0) >= 1
            @test _cgt_bitsame(duT, du)
        end

        @testset "ESS_THREADS_DISABLE=1 leaves the section unexamined" begin
            fK, uK, pK, _ = _cgt_build(model, ics)
            withenv("ESS_THREADS_DISABLE" => "1") do
                _cgt_du(fK, uK, pK, 0.0)
            end
            @test getfield(getfield(fK, :kernel_section), :tcache).state == 0
        end

        @testset "shared-outs verdict is reachable and permanent" begin
            # No real build produces globally shared out-slots (asserted by the
            # disjoint == true pins above), so poison a cache directly: the
            # verdict must be the dedicated `:cg_serial_shared_outs`, not
            # `:cg_serial_small`.
            ESM._reset_thread_tally!()
            tc = ESM._SecTCache(1_000_000, false)
            @test ESM._sec_prep_threads!(tc).state == -2
            @test get(ESM._THREAD_TALLY, :cg_serial_shared_outs, 0) == 1
            ESM._sec_prep_threads!(tc)             # sticky: tallied once
            @test get(ESM._THREAD_TALLY, :cg_serial_shared_outs, 0) == 1
            tc2 = ESM._SecTCache(1_000_000, true)
            @test ESM._sec_prep_threads!(tc2).state == 1
            @test tc2.nchunks == min(Threads.nthreads(), 1_000_000 ÷ 512)
        end

        @testset "overflow RGF (budget 0): threaded ≡ serial oracle ≡ tape" begin
            ESM._reset_thread_tally!()
            fO, uO, pO, tallyO = _cgt_build(model, ics; ESS_CODEGEN_NODE_BUDGET="0")
            fB, uB, pB, _ = _cgt_build(model, ics; ESS_CODEGEN_NODE_BUDGET="0",
                                       ESS_F64_OVERFLOW_CODEGEN="0")
            @test get(tallyO, :dual_codegen_kernel, 0) >= 1
            @test get(tallyO, :f64_overflow_armed, 0) == 1
            ksO = getfield(fO, :kernel_section)
            @test getfield(ksO, :dualf) !== nothing
            @test getfield(ksO, :dual_tcache).disjoint
            for k in 1:3, t in (0.0, 0.7)
                u = Float64[2.0 + 1.3 * sin(1.3i + 0.7k) * cos(0.31i * k) + 0.01i
                            for i in 1:length(uO)]
                du_thr = _cgt_du(fO, u, pO, t)
                du_ser = withenv("ESS_CG_THREADS_DISABLE" => "1") do
                    _cgt_du(fO, u, pO, t)
                end
                du_tape = _cgt_du(fB, u, pB, t)    # threaded-tape routing
                @test _cgt_bitsame(du_thr, du_ser)
                @test _cgt_bitsame(du_thr, du_tape)
            end
            @test getfield(ksO, :dual_tcache).state == 1
            @test get(ESM._THREAD_TALLY, :cg_threaded, 0) >= 1
        end

        @testset "2-D boxes under real threading" begin
            N2 = 40                    # 1600 cells ≥ 2 chunks at the default
            f2, u2, p2, _ = _cgt_build(_cgt_2d_model(N2), _cgt_2d_ics(N2))
            du_thr = _cgt_du(f2, u2, p2, 0.4)
            du_ser = withenv("ESS_CG_THREADS_DISABLE" => "1") do
                _cgt_du(f2, u2, p2, 0.4)
            end
            @test getfield(getfield(f2, :kernel_section), :tcache).state == 1
            @test _cgt_bitsame(du_thr, du_ser)
        end
    end
else
    # =========================================================================
    # PARENT: partition/disjointness pins + chunk-instance decomposition
    # (single-threaded, no Polyester needed), then the threaded subprocess.
    # =========================================================================
    @testset "codegen threaded cell axis" begin

        @testset "_chunk_ordinals tiles [0, n) exactly" begin
            for n in (0, 1, 5, 7, 512, 1000), nc in (1, 2, 3, 4, 7, 8)
                stops = Int[]
                prev = 0
                sizes = Int[]
                for c in 1:nc
                    a, b = ESM._chunk_ordinals(n, c, nc)
                    @test a == prev            # contiguous, in order
                    @test b >= a
                    push!(sizes, b - a)
                    prev = b
                end
                @test prev == n                # covers everything, exactly once
                @test maximum(sizes) - minimum(sizes) <= 1
            end
        end

        @testset "_cellset_outs_disjoint! (within and across cell sets)" begin
            seen = Set{Int}()
            @test ESM._cellset_outs_disjoint!(seen, ESM._outs_cells([4, 9, 2]))
            @test !ESM._cellset_outs_disjoint!(Set{Int}(),
                                               ESM._outs_cells([4, 9, 4]))
            # contig vs box overlap ACROSS sets (the case the tape's per-kernel
            # check never sees): contig 1:6, then a stride-2 box hitting slot 4.
            @test !ESM._cellset_outs_disjoint!(copy(seen), ESM._contig_cells(6))
            seen2 = Set{Int}()
            @test ESM._cellset_outs_disjoint!(seen2, ESM._contig_cells(6))
            box = ESM._CellSet([2], [UnitRange{Int}(1, 3)], 2)  # slots 4, 6, 8
            @test !ESM._cellset_outs_disjoint!(seen2, box)
            seen3 = Set{Int}()
            @test ESM._cellset_outs_disjoint!(seen3, ESM._contig_cells(3))
            @test ESM._cellset_outs_disjoint!(seen3, box)       # 1..3 vs 4,6,8
        end

        @testset "chunk instances reproduce the serial du ($(name))" for (name, model, ics, wantrank) in (
                    ("1-D contig+box", _cgt_1d_model(37), _cgt_1d_ics(37), 1),
                    ("2-D boxes", _cgt_2d_model(13), _cgt_2d_ics(13), 2),
                    ("3-D boxes", _cgt_3d_model(9, 8, 7), _cgt_3d_ics(9, 8, 7), 3))
            # The fixture really carries a box of the advertised rank (else
            # this case would silently stop exercising that emission arm).
            @test wantrank in _cgt_ranks(model, ics)
            f!, u0, p, tally = _cgt_build(model, ics)
            @test get(tally, :codegen_kernel, 0) >= 1
            ks = getfield(f!, :kernel_section)
            cgf = getfield(ks, :cgf)
            tabs = getfield(ks, :cgtabs)
            @test cgf !== nothing
            @test getfield(ks, :tcache).disjoint       # build-time global check
            @test getfield(ks, :tcache).ncells >= length(u0)
            u = copy(u0)
            for (k, t) in ((2, 0.7), (3, 0.0))
                u .= u0 .* (1.0 .+ 1e-3 .* sin.(k .* (1:length(u0))))
                du1 = fill(0.0, length(u0))
                cgf(du1, u, p, t, tabs, 1, 1)          # the serial entry
                for nc in (2, 3, 5, 8, 64)
                    duN = fill(0.0, length(u0))
                    for c in 1:nc                       # sequential chunk sweep
                        cgf(duN, u, p, t, tabs, c, nc)
                    end
                    @test _cgt_bitsame(duN, du1)
                end
                # ... and the full evaluator (serial route in this process)
                # agrees with the (1,1) instance.
                @test _cgt_bitsame(_cgt_du(f!, u, p, t), du1)
            end
        end

        @testset "overflow RGF chunk instances (budget 0)" begin
            model = _cgt_1d_model(41)
            ics = _cgt_1d_ics(41)
            f!, u0, p, tally = _cgt_build(model, ics; ESS_CODEGEN_NODE_BUDGET="0")
            @test get(tally, :dual_codegen_kernel, 0) >= 1
            ks = getfield(f!, :kernel_section)
            dualf = getfield(ks, :dualf)
            dtabs = getfield(ks, :dualtabs)
            @test dualf !== nothing
            @test getfield(ks, :dual_tcache).disjoint
            du1 = fill(0.0, length(u0))
            dualf(du1, u0, p, 0.7, dtabs, 1, 1)
            for nc in (2, 5)
                duN = fill(0.0, length(u0))
                for c in 1:nc
                    dualf(duN, u0, p, 0.7, dtabs, c, nc)
                end
                @test _cgt_bitsame(duN, du1)
            end
        end

        @testset "serial-process verdicts" begin
            # With one thread, every section is `:cg_serial_small` (nchunks
            # caps at nthreads); the shared-outs poison still short-circuits
            # ahead of nothing — its full verdict ordering runs in the child.
            if Threads.nthreads() == 1
                ESM._reset_thread_tally!()
                tc = ESM._SecTCache(1_000_000, true)
                @test ESM._sec_prep_threads!(tc).state == -1
                @test get(ESM._THREAD_TALLY, :cg_serial_small, 0) == 1
            end
        end

        # ---- the threaded subprocess (skipped without Polyester) ----
        polypath = Base.find_package("Polyester")
        if polypath === nothing
            @warn "Polyester not in the active environment; skipping the " *
                  "threaded codegen-cell-axis subprocess tests"
        else
            @testset "threaded subprocess (julia -t 4)" begin
                env = copy(ENV)
                for k in collect(keys(env))
                    startswith(k, "ESS_") && delete!(env, k)
                end
                env["ESS_CGT_CHILD"] = "1"
                env["JULIA_PROJECT"] = Base.active_project()
                cmd = setenv(`$(Base.julia_cmd()) --startup-file=no -t 4 $(@__FILE__)`, env)
                proc = run(pipeline(ignorestatus(cmd); stdout=stdout, stderr=stderr))
                @test success(proc)
            end
        end
    end
end
