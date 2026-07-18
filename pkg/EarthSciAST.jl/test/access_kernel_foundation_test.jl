# Foundation test for the unified access-kernel IR (ess-affine): hand-build a
# structured (affine, periodic) and an unstructured (indirect, variable-valence)
# kernel and check the evaluator is BIT-IDENTICAL to a per-cell reference.
# Exercises _eval_acc / _run_acc_kernel! and every access descriptor + bound kind.
using Test
using EarthSciAST
const E = EarthSciAST

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

        # LANE TAPE (de-scalarized runner): every structured kernel must plan,
        # and the planned run must be bit-identical to the scalar walk — with a
        # deliberately tiny tile so several tile flushes cover one box.
        du_t = zeros(ncell)
        for K in kernels
            P = E._build_acc_plan(K; tile=8)
            @test P !== nothing
            E._run_acc_plan!(du_t, u, nothing, 0.0, K, P)
        end
        @test du_t == ref                      # bit-identical, tiled
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

        # Lane tape over the 3-D boxes (const-box addressing through the tile's
        # multi-index buffers), small tile → many flushes per box.
        du_t = zeros(ncell)
        for K in kernels
            P = E._build_acc_plan(K; tile=16)
            @test P !== nothing
            E._run_acc_plan!(du_t, u, nothing, 0.0, K, P)
        end
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

        # No strided formulation exists for a variable-valence indirect kernel:
        # the lane tape must DECLINE (scalar runner keeps it), never mis-plan.
        @test E._build_acc_plan(K) === nothing
    end
end
