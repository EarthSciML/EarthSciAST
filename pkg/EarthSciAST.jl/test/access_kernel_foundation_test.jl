# Foundation test for the access-kernel IR: hand-build structured (affine,
# periodic, const-box, slot-table) kernels and check the evaluator is
# BIT-IDENTICAL to a per-cell reference. Exercises _eval_acc / _run_acc_kernel!
# and the access descriptor kinds, plus the codegen tier (the compiled runner)
# on the same hand-built kernels.
using Test
using EarthSciAST
const E = EarthSciAST

# Compile hand-built kernels through the codegen tier and run the generated
# function's serial (1, 1) instance. Asserts every kernel was emitted (no
# silent decline making the comparison trivial).
function _akf_cg_run!(du, u, p, t, kernels::Vector{E._AccKernel})
    cg = E._build_codegen_rhs(kernels)
    @test cg !== nothing
    @test all(cg.covered)
    cg.f(du, u, p, t, cg.tabs, 1, 1)
    return du
end

@testset "access-kernel IR foundation" begin

    # ---------- STRUCTURED: 3-wide periodic stencil D(q[i,j,k]) = (qW - 2qC) + qE ----------
    @testset "structured affine periodic ≡ per-cell (N=$N1×$N2×$N3)" for (N1, N2, N3) in ((7, 7, 7), (16, 5, 3), (32, 8, 4))
        ncell = N1 * N2 * N3
        lin(i, j, k) = (i - 1) + (j - 1) * N1 + (k - 1) * N1 * N2 + 1
        u = Float64[sin(0.1x) + 0.3cos(0.02x^2) for x in 1:ncell]

        # reference: per-cell, periodic wrap in dim 1, same op grouping (qW - 2qC) + qE
        wrap(i) = i < 1 ? i + N1 : i > N1 ? i - N1 : i
        ref = zeros(ncell)
        for k in 1:N3, j in 1:N2, i in 1:N1
            qW = u[lin(wrap(i - 1), j, k)]; qC = u[lin(i, j, k)]; qE = u[lin(wrap(i + 1), j, k)]
            ref[lin(i, j, k)] = (qW - 2.0 * qC) + qE
        end

        # build one kernel per structural group (interior + 2 wrap boxes), by hand.
        # spine shape is shared; only the two wrapping deltas differ per group.
        strides = [1, N1, N1 * N2]
        cbase = -(N1 + N1 * N2)                     # oln = cbase + i + j*N1 + k*N1*N2 == lin(i,j,k)
        mkspine(dW, dC, dE) = begin
            acc = E._AccDesc[E._AccStateAffine(dW), E._AccStateAffine(dC), E._AccStateAffine(dE)]
            sp = E._aop(:+, E._aop(:-, E._acc(1), E._aop(:*, E._alit(2.0), E._acc(2))), E._acc(3))
            sp, acc
        end
        box(ir) = E._CellSet(strides, UnitRange{Int}[ir, 1:N2, 1:N3], cbase)
        kernels = E._AccKernel[]
        # interior box i∈2:N1-1, j,k full : deltas -1, 0, +1
        if N1 >= 3
            sp, acc = mkspine(-1, 0, +1)
            push!(kernels, E._AccKernel(box(2:(N1 - 1)), sp, acc))
        end
        # left box {i=1}: qW wraps -> delta -1 + N1
        let (sp, acc) = mkspine(-1 + N1, 0, +1)
            push!(kernels, E._AccKernel(box(1:1), sp, acc))
        end
        # right box {i=N1}: qE wraps -> delta +1 - N1
        let (sp, acc) = mkspine(-1, 0, +1 - N1)
            push!(kernels, E._AccKernel(box(N1:N1), sp, acc))
        end

        du = zeros(ncell)
        for K in kernels
            E._run_acc_kernel!(du, u, nothing, 0.0, K)
        end
        @test du == ref                        # bit-identical
        # free-stream: constant field -> (c - 2c) + c == 0 exactly
        du0 = zeros(ncell)
        for K in kernels
            E._run_acc_kernel!(du0, fill(2.71828, ncell), nothing, 0.0, K)
        end
        @test maximum(abs, du0) == 0.0

        # CODEGEN tier (compiled loop nests): every structured kernel must
        # emit, and the compiled run must be bit-identical to the scalar walk.
        du_t = zeros(ncell)
        _akf_cg_run!(du_t, u, nothing, 0.0, kernels)
        @test du_t == ref                      # bit-identical, compiled
    end

    # ---------- STRUCTURED + reduced-rank const: D(q[i,j,k]) = Kz[k]*(qU - 2qC + qD) ----------
    # Exercises _AccConstBox: a vertical profile Kz[k] broadcast over the horizontal,
    # addressed by the cell's multi-index (strides (0,0,1)), with vertical no-flux
    # boundaries (k=1 drops qD, k=N3 drops qU) — three k-boxes spanning full i,j.
    @testset "structured const-box vertical ≡ per-cell (N=$N1×$N2×$N3)" for (N1, N2, N3) in ((7, 7, 7), (5, 4, 9))
        ncell = N1 * N2 * N3
        lin(i, j, k) = (i - 1) + (j - 1) * N1 + (k - 1) * N1 * N2 + 1
        u = Float64[sin(0.1x) + 0.3cos(0.02x^2) for x in 1:ncell]
        Kz = Float64[0.5 + 0.2 * sin(0.3k) for k in 1:N3]

        # reference: per-cell, one-sided at the vertical boundaries, same op grouping
        ref = zeros(ncell)
        for k in 1:N3, j in 1:N2, i in 1:N1
            qC = u[lin(i, j, k)]
            qU = k < N3 ? u[lin(i, j, k + 1)] : qC
            qD = k > 1 ? u[lin(i, j, k - 1)] : qC
            ref[lin(i, j, k)] = Kz[k] * ((qU - 2.0 * qC) + qD)
        end

        strides = [1, N1, N1 * N2]
        cbase = -(N1 + N1 * N2)
        dU = N1 * N2; dD = -N1 * N2
        # spine: Kz[k] * ((qU - 2 qC) + qD); acc 1=qU 2=qC 3=qD 4=Kz[k]
        mkspine(du_, dd_) = begin
            acc = E._AccDesc[
                E._AccStateAffine(du_), E._AccStateAffine(0),
                E._AccStateAffine(dd_), E._AccConstBox(Kz, 0, 0, 1, 1),
            ]
            body = E._aop(:+, E._aop(:-, E._acc(1), E._aop(:*, E._alit(2.0), E._acc(2))), E._acc(3))
            E._aop(:*, E._acc(4), body), acc
        end
        kbox(kr) = E._CellSet(strides, UnitRange{Int}[1:N1, 1:N2, kr], cbase)
        kernels = E._AccKernel[]
        # bottom k=1: qD collapses to self (delta 0)
        let (sp, acc) = mkspine(dU, 0)
            push!(kernels, E._AccKernel(kbox(1:1), sp, acc))
        end
        # interior 2:N3-1
        if N3 >= 3
            sp, acc = mkspine(dU, dD)
            push!(kernels, E._AccKernel(kbox(2:(N3 - 1)), sp, acc))
        end
        # top k=N3: qU collapses to self (delta 0)
        let (sp, acc) = mkspine(0, dD)
            push!(kernels, E._AccKernel(kbox(N3:N3), sp, acc))
        end

        du = zeros(ncell)
        for K in kernels
            E._run_acc_kernel!(du, u, nothing, 0.0, K)
        end
        @test du == ref                        # bit-identical, _AccConstBox addressing

        # Codegen tier over the 3-D boxes (const-box addressing baked into the
        # emitted loop nest as literal strides/offsets).
        du_t = zeros(ncell)
        _akf_cg_run!(du_t, u, nothing, 0.0, kernels)
        @test du_t == ref
    end

    # ---------- UNSTRUCTURED slot-table gather (_AK_STATE_TBL_BOX, stage 2) ----------
    # A per-box slot table addressed by the cell multi-index — the lowering the
    # box processor emits for a gather whose slot is NOT affine in the loop
    # indices (indirect through a connectivity const). Ghost slot 0 fetches 0.0.
    @testset "state slot-table gather ≡ per-cell (N=$N)" for N in (24, 257)
        u = Float64[cos(0.2x) + 0.01x for x in 1:N]
        perm = Int[mod1(5x + 2, N) for x in 1:N]
        perm[2] = 0                                   # one ghost entry
        # D(y[i]) = u[perm[i]] - 0.5*u[i]  over a 1-D box with unit stride.
        acc = E._AccDesc[
            E._AccStateTblBox(copy(perm), 1, 0, 0, 1),
            E._AccStateAffine(0),
        ]
        sp = E._aop(:-, E._acc(1), E._aop(:*, E._alit(0.5), E._acc(2)))
        K = E._AccKernel(
            E._CellSet([1], UnitRange{Int}[1:N], 0), sp, acc
        )
        ref = Float64[(perm[i] == 0 ? 0.0 : u[perm[i]]) - 0.5 * u[i] for i in 1:N]
        du = zeros(N)
        E._run_acc_kernel!(du, u, nothing, 0.0, K)
        @test du == ref                               # scalar runner, bit-identical
        du2 = zeros(N)                        # codegen must EMIT this kind
        _akf_cg_run!(du2, u, nothing, 0.0, E._AccKernel[K])
        @test du2 == ref                              # compiled run, bit-identical
    end

    # ---------- END-TO-END: the BUILD emits the slot table (stage 2) ----------
    # Past the Δ-cut cap (an unstructured permutation at large N), the default
    # build must land ONE access kernel carrying the slot table — never O(N)
    # boxes, never the symbolic/per-cell fallback — bit-identical to the forced
    # per-cell reference, zero-alloc in place, and vectorized out of place.
    @testset "build emits slot-table kernel for unstructured gather" begin
        include("testutils.jl")
        N = 64
        perm = Int[mod1(7i + 3, N) for i in 1:N]
        conn = Float64.(perm)
        vars = Dict(
            "y" => ModelVariable(UnknownVariable),
            "u" => ModelVariable(UnknownVariable)
        )
        lhs = _faq1d(_D_idx("y", _v("i")), "i", 1, N)
        rhs = _faq1d(_idx("u", _idx("conn", _v("i"))), "i", 1, N)
        model = E.Model(vars, [E.Equation(lhs, rhs)])
        ics = Dict{String, Float64}()
        for k in 1:N
            ics["M.y[$k]"] = 0.0; ics["M.u[$k]"] = 1.0k
        end
        ca = Dict("conn" => conn)

        f!, u0, p, _, vmap, rep = E.Internal.build(
            model;
            initial_conditions = ics, const_arrays = ca
        )
        @test rep.stats.n_acc_kernels == 1                    # ONE kernel, not O(N) boxes
        du = fill(-1.0, length(u0)); f!(du, u0, p, 0.0)
        for i in 1:N
            @test du[vmap["M.y[$i]"]] == u0[vmap["M.u[$(perm[i])]"]]
        end

        # forced per-cell reference: bit-identical on every written slot
        fr!, u0r, pr, _, _ = EarthSciAST.Internal.build(
            model; initial_conditions = ics,
            const_arrays = ca,
            compiler = :interpreter
        )
        dur = fill(-1.0, length(u0r)); fr!(dur, u0r, pr, 0.0)
        @test du == dur

        # zero-alloc in place (the codegen tier hosts the table gather)
        f!(du, u0, p, 0.0)
        @test (@allocated f!(du, u0, p, 0.0)) == 0
    end

    # ---------- GUARDED SINGULARITIES on the codegen tier ----------
    # The codegen tier emits `ifelse`/`and`/`or` with the interpreter's LAZY
    # semantics (ternaries / `&&`/`||` chains), so a throwing op under an
    # unentered guard cannot raise. Every guarded kernel must (a) emit, and
    # (b) match the scalar lazy reference bit for bit — while an UNguarded
    # domain violation still raises on the compiled tier.
    @testset "guarded singularity: codegen ≡ lazy scalar" begin
        N = 64
        # alternating sign so ~half the cells are OUT of every guarded domain
        u = Float64[(-1.0)^i * (0.05 + 0.03i) for i in 1:N]
        @test any(<(0), u) && any(>(0), u)
        cells = E._CellSet([1], UnitRange{Int}[1:N], 0)     # a 1-D box over 1:N
        mkK(spine) = E._AccKernel(
            cells, spine,
            E._AccDesc[E._AccStateAffine(0)]
        )

        # each spine reads u[oln] through _acc(1); guards protect a singular op
        specs = Dict(
            # ifelse guarding log (base 1.0 safe): negative cells take the else arm
            "ifelse-log" => E._aop(
                :ifelse, E._aop(:>, E._acc(1), E._alit(0.0)),
                E._aop(:log, E._acc(1)), E._alit(-9.0)
            ),
            # ifelse guarding sqrt
            "ifelse-sqrt" => E._aop(
                :ifelse, E._aop(:>=, E._acc(1), E._alit(0.0)),
                E._aop(:sqrt, E._acc(1)), E._alit(0.0)
            ),
            # ifelse guarding ^ with a real (fractional) exponent: base sanitized
            "ifelse-pow" => E._aop(
                :ifelse, E._aop(:>, E._acc(1), E._alit(0.0)),
                E._aop(:^, E._acc(1), E._alit(0.5)), E._alit(0.0)
            ),
            # acosh (safe 1.0): guard x>1
            "ifelse-acosh" => E._aop(
                :ifelse, E._aop(:>, E._acc(1), E._alit(1.0)),
                E._aop(:acosh, E._acc(1)), E._alit(0.0)
            ),
            # asin (safe 0.0): guard |x|<=1 via and(x>=-1, x<=1)
            "and-asin" => E._aop(
                :ifelse,
                E._aop(
                    :and, E._aop(:>=, E._acc(1), E._alit(-1.0)),
                    E._aop(:<=, E._acc(1), E._alit(1.0))
                ),
                E._aop(:asin, E._acc(1)), E._alit(0.0)
            ),
            # `and` short-circuit: second conjunct is a singular op; when the first
            # conjunct is false the scalar walk skips it, eager must not throw.
            "and-guards-sqrt" => E._aop(
                :and, E._aop(:>, E._acc(1), E._alit(0.0)),
                E._aop(:>, E._aop(:sqrt, E._acc(1)), E._alit(0.1))
            ),
            # `or` short-circuit: second disjunct singular; skipped when first true.
            "or-guards-log" => E._aop(
                :or, E._aop(:<, E._acc(1), E._alit(0.0)),
                E._aop(:>, E._aop(:log, E._acc(1)), E._alit(-1.0))
            ),
            # nested guards compose by mask conjunction
            "nested" => E._aop(
                :ifelse, E._aop(:>, E._acc(1), E._alit(0.0)),
                E._aop(
                    :ifelse, E._aop(:<, E._acc(1), E._alit(1.0)),
                    E._aop(:log, E._acc(1)), E._alit(2.0)
                ),
                E._alit(-3.0)
            ),
        )
        for (name, spine) in specs
            K = mkK(spine)
            ref = zeros(N)
            E._run_acc_kernel!(ref, u, nothing, 0.0, K)     # scalar LAZY reference
            @test all(isfinite, ref)                        # reference itself is total
            cgv = zeros(N)
            _akf_cg_run!(cgv, u, nothing, 0.0, E._AccKernel[K])   # (a) emits
            @test cgv == ref                                # (b) bit-identical
        end

        # An UNGUARDED domain violation still throws on the compiled tier
        # (contract intact — lazy emission does not swallow real throws).
        Kbad = mkK(E._aop(:log, E._acc(1)))
        cgbad = E._build_codegen_rhs(E._AccKernel[Kbad])
        @test cgbad !== nothing
        @test all(cgbad.covered)
        @test_throws DomainError cgbad.f(zeros(N), u, nothing, 0.0, cgbad.tabs, 1, 1)
        Kbad2 = mkK(E._aop(:sqrt, E._acc(1)))
        cgbad2 = E._build_codegen_rhs(E._AccKernel[Kbad2])
        @test cgbad2 !== nothing
        @test all(cgbad2.covered)
        @test_throws DomainError cgbad2.f(zeros(N), u, nothing, 0.0, cgbad2.tabs, 1, 1)
    end
end
