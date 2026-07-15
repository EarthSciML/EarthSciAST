# Unit test for the affine-build lowering (ess-affine): `_lower_to_access` turns a
# compiled sentinel spine template (the SAME kind `_stencilize`+`_compile` produce
# — `_NK_STATE(idx=-k)` lane leaves, invariant fixed-slot leaves, params, literals)
# into an access spine + descriptor table, and the resulting `_AccKernel` must be
# BIT-IDENTICAL to a per-cell reference. Exercises: lane→access vs lane→literal
# (ghost), fixed-slot state (`_NK_STATE idx≥0` → `_AccStateFixed`), param + literal
# passthrough, op reconstruction, and descriptor-table traversal-order indexing.
using Test
using EarthSciAST
const E = EarthSciAST

@testset "affine lowering: _lower_to_access ≡ per-cell" begin
    N1, N2, N3 = 8, 4, 3
    ncell = N1*N2*N3
    lin(i,j,k) = (i-1) + (j-1)*N1 + (k-1)*N1*N2 + 1
    u = Float64[sin(0.2x) + 0.1x for x in 1:ncell]
    p = (pc = 1.7,)
    fixslot = lin(3, 2, 2)

    # reference: du = pc*((qW - 2 qC) + qE) + u[fixslot]; qW ghost(=0) at i=1, qE ghost at i=N1
    ref = zeros(ncell)
    for k in 1:N3, j in 1:N2, i in 1:N1
        qC = u[lin(i,j,k)]
        qW = i > 1  ? u[lin(i-1,j,k)] : 0.0
        qE = i < N1 ? u[lin(i+1,j,k)] : 0.0
        ref[lin(i,j,k)] = p.pc*((qW - 2.0*qC) + qE) + u[fixslot]
    end

    # hand-built compiled sentinel template (what _stencilize + _compile would yield):
    #   lanes 1=qW(-1) 2=qC(0) 3=qE(+1); an invariant fixed-slot state; param :pc.
    st(k)       = E._mknode(kind=E._NK_STATE, idx=k)
    prm         = E._mknode(kind=E._NK_PARAM, sym=:pc)
    lit(v)      = E._mknode(kind=E._NK_LITERAL, literal=Float64(v))
    op(o, ch...) = E._mknode(kind=E._NK_OP, op=o, children=E._Node[ch...])
    stencil = op(:+, op(:-, st(-1), op(:*, lit(2.0), st(-2))), st(-3))
    tmpl    = op(:+, op(:*, prm, stencil), st(fixslot))

    strides = [1, N1, N1*N2]
    cbase = -(N1 + N1*N2)
    box(ir) = E._CellSet(strides, UnitRange{Int}[ir, 1:N2, 1:N3], cbase)
    SA(d)   = E._AccStateAffine(d)
    Acc     = E._AccRepl
    Lit0    = E._LitRepl(0.0)

    function mkkernel(l1, l2, l3, ir)
        acc = E._AccDesc[]
        spine = E._lower_to_access(tmpl, E._LaneRepl[l1, l2, l3], acc)
        E._AccKernel(box(ir), spine, acc, E._FixedBound(0), 0.0)
    end

    kernels = E._AccKernel[]
    push!(kernels, mkkernel(Acc(SA(-1)), Acc(SA(0)), Acc(SA(+1)), 2:N1-1))  # interior
    push!(kernels, mkkernel(Lit0,        Acc(SA(0)), Acc(SA(+1)), 1:1))     # left: qW ghost
    push!(kernels, mkkernel(Acc(SA(-1)), Acc(SA(0)), Lit0,        N1:N1))   # right: qE ghost

    # the lowered spine's descriptor table is built in traversal order:
    # [qW, qC, qE, fixed-state] — 4 entries for a fully-in-bounds box.
    let acc = E._AccDesc[]
        E._lower_to_access(tmpl, E._LaneRepl[Acc(SA(-1)), Acc(SA(0)), Acc(SA(+1))], acc)
        @test length(acc) == 4
        @test acc[4].kind === E._AK_STATE_FIXED && acc[4].idx == fixslot
    end

    du = zeros(ncell)
    for K in kernels; E._run_acc_kernel!(du, u, p, 0.0, K); end
    @test du == ref                      # bit-identical through the lowering

    # a ghost lane lowers to a literal, not an access → one fewer descriptor.
    let acc = E._AccDesc[]
        E._lower_to_access(tmpl, E._LaneRepl[Lit0, Acc(SA(0)), Acc(SA(+1))], acc)
        @test length(acc) == 3           # qW dropped to literal; qC, qE, fixed remain
    end

    # an interp `:fn` node forces a fallback (not yet modelled by the affine path).
    let fn = E._mknode(kind=E._NK_OP, op=:fn, children=E._Node[st(-1)], payload=("f", nothing))
        @test_throws E._StencilFallback E._lower_to_access(fn, E._LaneRepl[Acc(SA(0))], E._AccDesc[])
    end
end
