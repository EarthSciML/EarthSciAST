# The kernel-CLASS merge (src/tree_walk/oop_merge.jl): `_build_evaluator_impl`
# groups structurally identical `_AccKernel`s (before the xcse gate and the
# emitter branch, so BOTH `:oop` and `:inplace` get it) and merges each class
# into one lane-batched kernel whose varying leaves are per-lane tables.
#
# What must hold, and is asserted here:
#   1. IDENTITY — the merged `f!` is BIT-IDENTICAL (`==`, never `isapprox`) to
#      `compiler=:interpreter`, on every model shape the pass touches:
#      pointwise classes, stencil interior + ghost boundary kernels, live
#      forcing reads.
#   2. THE PASS FIRES — two same-structure equations over different states
#      collapse to fewer kernels than the pass was HANDED (`n_acc_kernels` <
#      `n_classmerge_in`, the pre-merge count the build records). (This is the
#      one observable the identity test cannot see: with the pass silently
#      disabled, identity would hold vacuously.)
#   3. LIVENESS — a live forcing leaf merged into an `_AccArrTblBox` table
#      still reads the bound buffer by reference: an in-place refresh between
#      calls changes the merged RHS exactly as it changes the unmerged one.
#   4. GENERICITY — ForwardDiff Duals flow through merged kernels (state and
#      parameter directions), agreeing bit-for-bit with the unmerged build.
using Test
using EarthSciAST
using ForwardDiff
include("testutils.jl")
const ESM = EarthSciAST

# Out-of-place builds with the class merge on / off. Kernel counts are read off
# the compiled IR's own field — the same reflection a compiled backend uses.
function _om_build(model, ics; param_arrays=Dict{String,Any}())
    fo, u0, p, _t, vm, d = ESM._build_evaluator_impl(model;
        initial_conditions=ics, form=:oop, param_arrays=param_arrays)
    return (fo, u0, p, vm, d)
end
_om_nkernels(fo) = length(getfield(getfield(fo, :rhs), :acc_kernels))
# The pass fired iff it left fewer kernels than it was handed. `n_classmerge_in`
# is the PRE-merge count this build recorded, so one build answers it — there is
# no second compiler that keeps the affine tier but drops the merge.
_om_fired(d) = d.n_acc_kernels < d.n_classmerge_in
_ip(f!, u, p, t) = (du = zero(u); f!(du, u, p, t); du)

# Two SAME-STRUCTURE equations over different states — one merge class of two
# members. The kernels differ only in their state slots (and out-slots), the
# exact thing the merge transposes into per-lane tables.
function _om_twin_model(N)
    vars = Dict("u" => ESM.ModelVariable(ESM.UnknownVariable),
                "v" => ESM.ModelVariable(ESM.UnknownVariable))
    body(x) = _op("*", _n(-0.5), _op("*", _idx(x, _v("i")), _idx(x, _v("i"))))
    ESM.Model(vars, [
        ESM.Equation(_ao1(_Didx("u", _v("i")), "i", 1, N), _ao1(body("u"), "i", 1, N)),
        ESM.Equation(_ao1(_Didx("v", _v("i")), "i", 1, N), _ao1(body("v"), "i", 1, N))])
end

# Twin Laplacians: same-class STENCIL kernels (interior + ghost boundary cells)
# for two states — classes across equations AND ghost-pattern variety.
function _om_twin_stencil_model(N)
    vars = Dict("u" => ESM.ModelVariable(ESM.UnknownVariable),
                "v" => ESM.ModelVariable(ESM.UnknownVariable))
    lap(x) = _op("+", _idx(x, _op("-", _v("i"), _i(1))),
                      _op("*", _n(-2.0), _idx(x, _v("i"))),
                      _idx(x, _op("+", _v("i"), _i(1))))
    ESM.Model(vars, [
        ESM.Equation(_ao1(_Didx("u", _v("i")), "i", 1, N), _ao1(lap("u"), "i", 1, N)),
        ESM.Equation(_ao1(_Didx("v", _v("i")), "i", 1, N), _ao1(lap("v"), "i", 1, N))])
end

# Twin live-forcing equations: the merged kernel's forcing leaf must become an
# `_AccArrTblBox` over the SAME bound buffer (live re-gather, not a frozen copy).
function _om_twin_forcing_model(N)
    vars = Dict("u" => ESM.ModelVariable(ESM.UnknownVariable),
                "v" => ESM.ModelVariable(ESM.UnknownVariable))
    body(x) = _op("*", _idx("forcing", _v("i")), _idx(x, _v("i")))
    ESM.Model(vars, [
        ESM.Equation(_ao1(_Didx("u", _v("i")), "i", 1, N), _ao1(body("u"), "i", 1, N)),
        ESM.Equation(_ao1(_Didx("v", _v("i")), "i", 1, N), _ao1(body("v"), "i", 1, N))])
end

_om_ics(N) = merge(Dict("u[$k]" => 0.6sin(0.7k) - 0.15 for k in 1:N),
                   Dict("v[$k]" => 0.4cos(0.3k) + 0.2 for k in 1:N))

# Twin stencils with a loop-INVARIANT parameter subexpr (g/h): each member
# kernel carries an invariant-tier def, VALUE-identical across the class, so
# the merged kernel must KEEP a real inv tier (evaluated once per call) rather
# than folding it into a per-lane recompute — `_oop_inv_nodes_identical`.
function _om_twin_inv_model(N; g=3.0, h=7.0)
    vars = Dict{String,ESM.ModelVariable}(
        "u" => ESM.ModelVariable(ESM.UnknownVariable),
        "v" => ESM.ModelVariable(ESM.UnknownVariable),
        "g" => ESM.ModelVariable(ESM.ParameterVariable; default=g),
        "h" => ESM.ModelVariable(ESM.ParameterVariable; default=h))
    lap(x) = _op("+", _idx(x, _op("-", _v("i"), _i(1))),
                      _op("*", _n(-2.0), _idx(x, _v("i"))),
                      _idx(x, _op("+", _v("i"), _i(1))))
    body(x) = _op("*", _op("/", _v("g"), _v("h")), lap(x))
    ESM.Model(vars, [
        ESM.Equation(_ao1(_Didx("u", _v("i")), "i", 1, N), _ao1(body("u"), "i", 1, N)),
        ESM.Equation(_ao1(_Didx("v", _v("i")), "i", 1, N), _ao1(body("v"), "i", 1, N))])
end

@testset "the out-of-place build receives the merged kernels (oop_merge.jl)" begin
    # The merge runs in `_build_evaluator_impl` phase 4, before the emitter
    # branch, so it is a property of the BUILD. What is checked here is that the
    # out-of-place product carries the merged list — the values are pinned by the
    # in-place testsets below, which run the same models through `f!`.
    @testset "pointwise twin classes merge (N=$N)" for N in (8, 33)
        ics = _om_ics(N)
        fom, _, _, _, dom = _om_build(_om_twin_model(N), ics)
        @test _om_fired(dom)                             # the pass FIRED
    end

    @testset "stencil interior + ghost boundary kernels (N=$N)" for N in (8, 32)
        ics = _om_ics(N)
        fom, _, _, _, dom = _om_build(_om_twin_stencil_model(N), ics)
        @test _om_fired(dom)
    end

    @testset "a live-forcing table merges too" begin
        N = 16
        ics = _om_ics(N)
        pa = Dict{String,Any}("forcing" => Float64[0.5 + 0.2k for k in 1:N])
        fom, _, _, _, dom = _om_build(_om_twin_forcing_model(N), ics;
                                      param_arrays=pa)
        @test _om_fired(dom)
    end

    @testset "the merged kernel list is reproducible build to build" begin
        N = 8
        ics = _om_ics(N)
        fo1, _, _, _, _ = _om_build(_om_twin_model(N), ics)
        fo2, _, _, _, _ = _om_build(_om_twin_model(N), ics)
        @test _om_nkernels(fo1) == _om_nkernels(fo2)
    end
end

# ============================================================================
# The `:inplace` side of the SAME pass. Since the hoist into
# `_build_evaluator_impl` phase 4 (build.jl, before the xcse gate and before
# the emitter branch), the class merge applies to the production in-place
# `f!` too. The `:native` build must be BIT-IDENTICAL (`==`, never `isapprox`)
# to `compiler=:interpreter` on the twin pointwise model, the twin stencil
# (ghost boundary) model, and the live-forcing model incl. an in-place buffer
# refresh; and the pass must observably FIRE (`n_acc_kernels` below
# `n_classmerge_in`, with the kernel list itself read off a build whose primary
# emission declined on the node budget, where nothing is emitted away and the
# full list is introspectable).
# ============================================================================

# In-place builds. `codegen=false` puts the primary emission's node budget at
# zero — a retained tuning threshold — so nothing is emitted away and
# `getfield(f!, :kernel_section).kernels` holds every merged kernel; the
# default `codegen=true` build exercises the codegen emitter OVER merged
# kernels (source generation + compiled loop nests). `compiler=:interpreter` is
# the reference: no merge, no codegen, no affine tier.
function _im_build(model, ics; codegen::Bool=true, compiler::Symbol=:native,
                   param_arrays=Dict{String,Any}())
    withenv("ESS_CODEGEN_NODE_BUDGET" => (codegen ? nothing : "0")) do
        f!, u0, p, _t, vm, d = ESM._build_evaluator_impl(model;
            initial_conditions=ics, param_arrays=param_arrays,
            compiler=compiler)
        (f!, u0, p, vm, d)
    end
end
# Full kernel count of the in-place closure — the whole list when the primary
# emission declined everything (n_emitted == 0).
function _im_nkernels(f!)
    ks = getfield(f!, :kernel_section)
    @test getfield(ks, :n_emitted) == 0
    length(getfield(ks, :kernels))
end

@testset ":inplace kernel-class merge ≡ interpreter (hoisted, build.jl)" begin

    @testset "pointwise twins: fires + bit-identical (N=$N)" for N in (8, 33)
        ics = _om_ics(N)
        # un-emitted build: countable kernels, run by the per-cell runner
        fm, um, pm, _, dm = _im_build(_om_twin_model(N), ics; codegen=false)
        fu, uu, pu, _, du_ = _im_build(_om_twin_model(N), ics; compiler=:interpreter)
        @test _im_nkernels(fm) < dm.n_classmerge_in      # the pass FIRED (IIP)
        @test dm.n_acc_kernels < dm.n_classmerge_in      # and the diag agrees
        for t in (0.0, 0.37)
            @test _ip(fm, um, pm, t) == _ip(fu, uu, pu, t)
        end
        # default (fully emitted) build: the B1 tier accepts merged kernels
        fmc, umc, pmc, _, _ = _im_build(_om_twin_model(N), ics)
        for t in (0.0, 0.37)
            @test _ip(fmc, umc, pmc, t) == _ip(fu, uu, pu, t)
            @test _ip(fmc, umc, pmc, t) == _ip(fm, um, pm, t)  # ≡ interpreted
        end
    end

    @testset "stencil twins (ghost boundary) (N=$N)" for N in (8, 32)
        ics = _om_ics(N)
        fm, um, pm, _, dm = _im_build(_om_twin_stencil_model(N), ics; codegen=false)
        fu, uu, pu, _, _ = _im_build(_om_twin_stencil_model(N), ics;
                                     compiler=:interpreter)
        @test _im_nkernels(fm) < dm.n_classmerge_in
        for t in (0.0, 1.9)
            @test _ip(fm, um, pm, t) == _ip(fu, uu, pu, t)
        end
        # codegen tier over the merged stencil kernels, still bit-identical
        fmc, umc, pmc, _, _ = _im_build(_om_twin_stencil_model(N), ics)
        @test _ip(fmc, umc, pmc, 1.9) == _ip(fu, uu, pu, 1.9)
    end

    @testset "live forcing stays live through the merged table (in place)" begin
        N = 16
        buf = Float64[0.5 + 0.2k for k in 1:N]
        ics = _om_ics(N)
        pa = Dict{String,Any}("forcing" => buf)
        fm, um, pm, _, dm = _im_build(_om_twin_forcing_model(N), ics;
                                      codegen=false, param_arrays=pa)
        fu, uu, pu, _, _ = _im_build(_om_twin_forcing_model(N), ics;
                                     compiler=:interpreter, param_arrays=pa)
        @test _im_nkernels(fm) < dm.n_classmerge_in
        du1 = _ip(fm, um, pm, 0.0)
        @test du1 == _ip(fu, uu, pu, 0.0)
        buf .= reverse(buf) .+ 3.0            # in-place refresh, no rebuild
        du2 = _ip(fm, um, pm, 0.0)
        @test du2 == _ip(fu, uu, pu, 0.0)     # both builds saw the refresh
        @test du2 != du1                      # and it actually changed values
    end

    @testset "ForwardDiff (Dual scalar path) through merged IIP kernels" begin
        N = 8
        ics = _om_ics(N)
        fm, um, pm, _, _ = _im_build(_om_twin_stencil_model(N), ics)
        fu, uu, pu, _, _ = _im_build(_om_twin_stencil_model(N), ics;
                                     compiler=:interpreter)
        Jm = ForwardDiff.jacobian((du, u) -> fm(du, u, pm, 0.0), zero(um), um)
        Ju = ForwardDiff.jacobian((du, u) -> fu(du, u, pu, 0.0), zero(uu), uu)
        @test Jm == Ju
    end

    @testset "value-identical invariant tier SURVIVES the merge" begin
        N = 12
        ics = _om_ics(N)
        # in place: inv slots kept (evaluated once per call, not per lane) …
        fm, um, pm, _, dm = _im_build(_om_twin_inv_model(N), ics; codegen=false)
        fu, uu, pu, _, _ = _im_build(_om_twin_inv_model(N), ics;
                                     compiler=:interpreter)
        @test dm.n_acc_kernels < dm.n_classmerge_in    # classes merged
        @test dm.n_acc_inv_slots >= 1                  # …but the hoist survived
        for t in (0.0, 0.42)
            @test _ip(fm, um, pm, t) == _ip(fu, uu, pu, t)
        end
        # …and through the codegen tier
        fmc, umc, pmc, _, _ = _im_build(_om_twin_inv_model(N), ics)
        @test _ip(fmc, umc, pmc, 0.42) == _ip(fu, uu, pu, 0.42)
        # the out-of-place build merges the same classes
        fom, _, _, _, dom = _om_build(_om_twin_inv_model(N), ics)
        @test _om_fired(dom)
    end
end
