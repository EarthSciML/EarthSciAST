# Foundation test for the unified access-kernel IR (ess-affine): hand-build a
# structured (affine, periodic) and an unstructured (indirect, variable-valence)
# kernel and check the evaluator is BIT-IDENTICAL to a per-cell reference.
# Exercises _eval_acc / _run_acc_kernel! and every access descriptor + bound
# kind, plus the codegen tier (the compiled runner that replaced the retired
# Float64 lane tape) on the same hand-built kernels.
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

@testset "access-kernel IR foundation (ess-affine)" begin

    # ---------- STRUCTURED: 3-wide periodic stencil D(q[i,j,k]) = (qW - 2qC) + qE ----------
    @testset "structured affine periodic ≡ per-cell (N=$N1×$N2×$N3)" for (N1,N2,N3) in ((7,7,7),(16,5,3),(32,8,4))
        ncell = N1*N2*N3
        lin(i,j,k) = (i-1) + (j-1)*N1 + (k-1)*N1*N2 + 1
        u = Float64[sin(0.1x) + 0.3cos(0.02x^2) for x in 1:ncell]

        # reference: per-cell, periodic wrap in dim 1, same op grouping (qW - 2qC) + qE
        wrap(i) = i < 1 ? i + N1 : i > N1 ? i - N1 : i
        ref = zeros(ncell)
        for k in 1:N3, j in 1:N2, i in 1:N1
            qW = u[lin(wrap(i-1),j,k)]; qC = u[lin(i,j,k)]; qE = u[lin(wrap(i+1),j,k)]
            ref[lin(i,j,k)] = (qW - 2.0*qC) + qE
        end

        # build one kernel per structural group (interior + 2 wrap boxes), by hand.
        # spine shape is shared; only the two wrapping deltas differ per group.
        strides = [1, N1, N1*N2]
        cbase = -(N1 + N1*N2)                     # oln = cbase + i + j*N1 + k*N1*N2 == lin(i,j,k)
        mkspine(dW, dC, dE) = begin
            acc = E._AccDesc[E._AccStateAffine(dW), E._AccStateAffine(dC), E._AccStateAffine(dE)]
            sp  = E._aop(:+, E._aop(:-, E._acc(1), E._aop(:*, E._alit(2.0), E._acc(2))), E._acc(3))
            sp, acc
        end
        box(ir) = E._CellSet(strides, UnitRange{Int}[ir, 1:N2, 1:N3], cbase)
        kernels = E._AccKernel[]
        # interior box i∈2:N1-1, j,k full : deltas -1, 0, +1
        if N1 >= 3
            sp,acc = mkspine(-1, 0, +1)
            push!(kernels, E._AccKernel(box(2:N1-1), sp, acc, E._FixedBound(0), 0.0))
        end
        # left box {i=1}: qW wraps -> delta -1 + N1
        let (sp,acc) = mkspine(-1 + N1, 0, +1)
            push!(kernels, E._AccKernel(box(1:1), sp, acc, E._FixedBound(0), 0.0))
        end
        # right box {i=N1}: qE wraps -> delta +1 - N1
        let (sp,acc) = mkspine(-1, 0, +1 - N1)
            push!(kernels, E._AccKernel(box(N1:N1), sp, acc, E._FixedBound(0), 0.0))
        end

        du = zeros(ncell)
        for K in kernels; E._run_acc_kernel!(du, u, nothing, 0.0, K); end
        @test du == ref                        # bit-identical
        # free-stream: constant field -> (c - 2c) + c == 0 exactly
        du0 = zeros(ncell)
        for K in kernels; E._run_acc_kernel!(du0, fill(2.71828, ncell), nothing, 0.0, K); end
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
    @testset "structured const-box vertical ≡ per-cell (N=$N1×$N2×$N3)" for (N1,N2,N3) in ((7,7,7),(5,4,9))
        ncell = N1*N2*N3
        lin(i,j,k) = (i-1) + (j-1)*N1 + (k-1)*N1*N2 + 1
        u  = Float64[sin(0.1x) + 0.3cos(0.02x^2) for x in 1:ncell]
        Kz = Float64[0.5 + 0.2*sin(0.3k) for k in 1:N3]

        # reference: per-cell, one-sided at the vertical boundaries, same op grouping
        ref = zeros(ncell)
        for k in 1:N3, j in 1:N2, i in 1:N1
            qC = u[lin(i,j,k)]
            qU = k < N3 ? u[lin(i,j,k+1)] : qC
            qD = k > 1  ? u[lin(i,j,k-1)] : qC
            ref[lin(i,j,k)] = Kz[k]*((qU - 2.0*qC) + qD)
        end

        strides = [1, N1, N1*N2]
        cbase = -(N1 + N1*N2)
        dU = N1*N2; dD = -N1*N2
        # spine: Kz[k] * ((qU - 2 qC) + qD); acc 1=qU 2=qC 3=qD 4=Kz[k]
        mkspine(du_, dd_) = begin
            acc = E._AccDesc[E._AccStateAffine(du_), E._AccStateAffine(0),
                            E._AccStateAffine(dd_), E._AccConstBox(Kz, 0, 0, 1, 1)]
            body = E._aop(:+, E._aop(:-, E._acc(1), E._aop(:*, E._alit(2.0), E._acc(2))), E._acc(3))
            E._aop(:*, E._acc(4), body), acc
        end
        kbox(kr) = E._CellSet(strides, UnitRange{Int}[1:N1, 1:N2, kr], cbase)
        kernels = E._AccKernel[]
        # bottom k=1: qD collapses to self (delta 0)
        let (sp,acc) = mkspine(dU, 0)
            push!(kernels, E._AccKernel(kbox(1:1), sp, acc, E._FixedBound(0), 0.0))
        end
        # interior 2:N3-1
        if N3 >= 3
            sp,acc = mkspine(dU, dD)
            push!(kernels, E._AccKernel(kbox(2:N3-1), sp, acc, E._FixedBound(0), 0.0))
        end
        # top k=N3: qU collapses to self (delta 0)
        let (sp,acc) = mkspine(0, dD)
            push!(kernels, E._AccKernel(kbox(N3:N3), sp, acc, E._FixedBound(0), 0.0))
        end

        du = zeros(ncell)
        for K in kernels; E._run_acc_kernel!(du, u, nothing, 0.0, K); end
        @test du == ref                        # bit-identical, _AccConstBox addressing

        # Codegen tier over the 3-D boxes (const-box addressing baked into the
        # emitted loop nest as literal strides/offsets).
        du_t = zeros(ncell)
        _akf_cg_run!(du_t, u, nothing, 0.0, kernels)
        @test du_t == ref
    end

    # ---------- UNSTRUCTURED: variable-valence FV divergence ----------
    #   D(q[c]) = ( Σ_{n=1}^{val[c]} efl[c,n]*0.5*(q[c]+q[noc[c,n]]) ) / area[c]
    @testset "unstructured variable-valence indirect ≡ per-cell (ncell=$Nc)" for Nc in (343, 5000)
        maxval = 8
        rng = 987654321
        nextr() = (rng = (1103515245*rng + 12345) & 0x7fffffff; rng)
        val = Vector{Int}(undef, Nc); noc = zeros(Int, Nc*maxval); efl = zeros(Nc*maxval)
        for c in 1:Nc
            v = 3 + nextr() % (maxval-2); val[c] = v
            for n in 1:v
                noc[(c-1)*maxval+n] = 1 + nextr() % Nc
                efl[(c-1)*maxval+n] = 0.5 + (nextr() % 100)/100
            end
        end
        area = Float64[1.0 + (c % 7)/3 for c in 1:Nc]
        u = Float64[sin(0.11c) + 0.2cos(0.007c^2) for c in 1:Nc]

        # reference
        ref = zeros(Nc)
        for c in 1:Nc
            s = 0.0
            for n in 1:val[c]
                s += efl[(c-1)*maxval+n] * 0.5 * (u[c] + u[noc[(c-1)*maxval+n]])
            end
            ref[c] = s / area[c]
        end

        # ONE kernel, VarBound valence, indirect neighbour gather. Build is O(1).
        # descriptors: 1=q[c] (self, affine Δ0), 2=q[noc[c,n]] (indirect),
        #              3=efl[c,n] (edge const), 4=area[c] (cell const)
        acc = E._AccDesc[
            E._AccStateAffine(0),                # q[c]  (self; oln==c for contiguous)
            E._AccStateIndirect(noc, maxval),    # q[noc[c,n]]
            E._AccConstEdge(efl, maxval),        # efl[c,n]
            E._AccConstCell(area),               # area[c]
        ]
        qc = E._acc(1); qn = E._acc(2); e = E._acc(3); ar = E._acc(4)
        body = E._aop(:*, E._aop(:*, e, E._alit(0.5)), E._aop(:+, qc, qn))  # (efl*0.5)*(qc+qn)
        spine = E._aop(:/, E._areduce(body), ar)                            # Σ / area
        K = E._AccKernel(E._contig_cells(Nc), spine, acc, E._VarBound(val), 0.0)

        du = zeros(Nc)
        E._run_acc_kernel!(du, u, nothing, 0.0, K)
        @test du == ref                        # bit-identical

        # The codegen tier compiles variable-valence indirect kernels too
        # (the emitted reduce loop reads the valence table per cell) and must
        # match the scalar walk bit for bit.
        du_c = zeros(Nc)
        _akf_cg_run!(du_c, u, nothing, 0.0, E._AccKernel[K])
        @test du_c == ref
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
        acc = E._AccDesc[E._AccStateTblBox(copy(perm), 1, 0, 0, 1),
                         E._AccStateAffine(0)]
        sp = E._aop(:-, E._acc(1), E._aop(:*, E._alit(0.5), E._acc(2)))
        K = E._AccKernel(E._CellSet([1], UnitRange{Int}[1:N], 0), sp, acc,
                         E._FixedBound(0), 0.0)
        ref = Float64[(perm[i] == 0 ? 0.0 : u[perm[i]]) - 0.5*u[i] for i in 1:N]
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
        vars = Dict("y" => ModelVariable(UnknownVariable),
                    "u" => ModelVariable(UnknownVariable))
        lhs = _arrayop1d(_D_idx("y", _v("i")), "i", 1, N)
        rhs = _arrayop1d(_idx("u", _idx("conn", _v("i"))), "i", 1, N)
        model = E.Model(vars, [E.Equation(lhs, rhs)])
        ics = Dict{String,Float64}()
        for k in 1:N; ics["y[$k]"] = 0.0; ics["u[$k]"] = 1.0k; end
        ca = Dict("conn" => conn)

        f!, u0, p, _, vmap, d = E._build_evaluator_impl(model;
            initial_conditions=ics, const_arrays=ca)
        @test d.n_acc_kernels == 1                    # ONE kernel, not O(N) boxes
        @test d.n_vec_kernels == 0
        du = fill(-1.0, length(u0)); f!(du, u0, p, 0.0)
        for i in 1:N
            @test du[vmap["y[$i]"]] == u0[vmap["u[$(perm[i])]"]]
        end

        # forced per-cell reference: bit-identical on every written slot
        fr!, u0r, pr, _, _ = withenv("ESS_STENCIL_DISABLE" => "1") do
            build_evaluator(model; initial_conditions=ics, const_arrays=ca)
        end
        dur = fill(-1.0, length(u0r)); fr!(dur, u0r, pr, 0.0)
        @test du == dur

        # zero-alloc in place (the codegen tier hosts the table gather)
        f!(du, u0, p, 0.0)
        @test (@allocated f!(du, u0, p, 0.0)) == 0

        # oop: gather-of-gather resolved host-side, bit-identical
        fo, u0o, po, _, _ = build_evaluator(model; initial_conditions=ics,
            const_arrays=ca, form=:oop)
        duo = fo(u0o, po, 0.0)
        for i in 1:N
            @test duo[vmap["y[$i]"]] == du[vmap["y[$i]"]]
        end
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
        cells = E._CellSet([1], UnitRange{Int}[1:N], 0)     # contiguous 1:N
        mkK(spine) = E._AccKernel(cells, spine,
                                  E._AccDesc[E._AccStateAffine(0)], E._FixedBound(0), 0.0)

        # each spine reads u[oln] through _acc(1); guards protect a singular op
        specs = Dict(
            # ifelse guarding log (base 1.0 safe): negative cells take the else arm
            "ifelse-log" => E._aop(:ifelse, E._aop(:>, E._acc(1), E._alit(0.0)),
                                   E._aop(:log, E._acc(1)), E._alit(-9.0)),
            # ifelse guarding sqrt
            "ifelse-sqrt" => E._aop(:ifelse, E._aop(:>=, E._acc(1), E._alit(0.0)),
                                    E._aop(:sqrt, E._acc(1)), E._alit(0.0)),
            # ifelse guarding ^ with a real (fractional) exponent: base sanitized
            "ifelse-pow" => E._aop(:ifelse, E._aop(:>, E._acc(1), E._alit(0.0)),
                                   E._aop(:^, E._acc(1), E._alit(0.5)), E._alit(0.0)),
            # acosh (safe 1.0): guard x>1
            "ifelse-acosh" => E._aop(:ifelse, E._aop(:>, E._acc(1), E._alit(1.0)),
                                     E._aop(:acosh, E._acc(1)), E._alit(0.0)),
            # asin (safe 0.0): guard |x|<=1 via and(x>=-1, x<=1)
            "and-asin" => E._aop(:ifelse,
                                 E._aop(:and, E._aop(:>=, E._acc(1), E._alit(-1.0)),
                                        E._aop(:<=, E._acc(1), E._alit(1.0))),
                                 E._aop(:asin, E._acc(1)), E._alit(0.0)),
            # `and` short-circuit: second conjunct is a singular op; when the first
            # conjunct is false the scalar walk skips it, eager must not throw.
            "and-guards-sqrt" => E._aop(:and, E._aop(:>, E._acc(1), E._alit(0.0)),
                                        E._aop(:>, E._aop(:sqrt, E._acc(1)), E._alit(0.1))),
            # `or` short-circuit: second disjunct singular; skipped when first true.
            "or-guards-log" => E._aop(:or, E._aop(:<, E._acc(1), E._alit(0.0)),
                                      E._aop(:>, E._aop(:log, E._acc(1)), E._alit(-1.0))),
            # nested guards compose by mask conjunction
            "nested" => E._aop(:ifelse, E._aop(:>, E._acc(1), E._alit(0.0)),
                               E._aop(:ifelse, E._aop(:<, E._acc(1), E._alit(1.0)),
                                      E._aop(:log, E._acc(1)), E._alit(2.0)),
                               E._alit(-3.0)),
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

    # ---------- BOXED CLOSED `fn` UNDER A GUARD (codegen tier) ----------
    # A boxed closed fn (`(name, nothing)` payload) compiles on the codegen
    # tier: the emitted body calls the interpreter's own `_eval_closed_fn`,
    # under the interpreter's lazy guard semantics. Must (a) emit (not
    # decline), (b) match the scalar reference bit for bit, on both invariant
    # and lane-varying args.
    @testset "boxed closed fn under guard: codegen ≡ scalar" begin
        N = 48
        u = Float64[(-1.0)^k * (0.05 + 0.03k) for k in 1:N]     # alternating sign
        tval = 1.5e9                                            # a finite unix time
        cells = E._CellSet([1], UnitRange{Int}[1:N], 0)
        tnode() = E._mknode(kind=E._NK_TIME)
        fn(name, kids...) = E._mknode(kind=E._NK_OP, op=:fn,
                                      children=E._Node[kids...], payload=(name, nothing))
        mkK(spine) = E._AccKernel(cells, spine,
                                  E._AccDesc[E._AccStateAffine(0)], E._FixedBound(0), 0.0)

        # invariant fn arg (t) — evaluated ONCE per tile, broadcast
        s_inv = E._aop(:ifelse, E._aop(:>, E._acc(1), E._alit(0.0)),
                       E._aop(:+, E._aop(:*, fn("datetime.julian_day", tnode()),
                                         E._alit(1e-4)), E._acc(1)),
                       E._alit(-1.0))
        # lane-varying fn arg (t + u[i]·Δ, always finite) — per-lane fn loop, and a
        # NESTED guard so composition is exercised on the fn arm
        s_var = E._aop(:ifelse, E._aop(:>, E._acc(1), E._alit(0.0)),
                       E._aop(:ifelse, E._aop(:<, E._acc(1), E._alit(10.0)),
                              fn("datetime.day_of_year",
                                 E._aop(:+, tnode(), E._aop(:*, E._acc(1), E._alit(3600.0)))),
                              E._alit(1.0)),
                       E._alit(-2.0))
        for (name, spine) in (("invariant-arg", s_inv), ("lane-varying-arg", s_var))
            K = mkK(spine)
            ref = zeros(N); E._run_acc_kernel!(ref, u, nothing, tval, K)
            cgv = zeros(N)
            _akf_cg_run!(cgv, u, nothing, tval, E._AccKernel[K])  # (a) emitted
            @test all(isfinite, cgv)
            @test cgv == ref                            # (b) bit-identical
        end

        # An UNguarded boxed fn also compiles and matches the scalar walk.
        Kun = mkK(E._aop(:*, fn("datetime.julian_day", tnode()), E._acc(1)))
        refu = zeros(N); E._run_acc_kernel!(refu, u, nothing, tval, Kun)
        cgu = zeros(N)
        _akf_cg_run!(cgu, u, nothing, tval, E._AccKernel[Kun])
        @test cgu == refu
    end
end
