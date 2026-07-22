# The kernel-CLASS merge (src/tree_walk/oop_merge.jl): `_build_evaluator_impl`
# groups structurally identical `_AccKernel`s (before the xcse gate and the
# emitter branch, so BOTH `:oop` and `:inplace` get it) and merges each class
# into one lane-batched kernel whose varying leaves are per-lane tables.
#
# What must hold, and is asserted here:
#   1. IDENTITY — the merged RHS is BIT-IDENTICAL (`==`, never `isapprox`) to
#      the unmerged :oop build (ESS_OOP_MERGE_DISABLE=1) and to the in-place
#      `f!`, on every model shape the pass touches: pointwise classes, stencil
#      interior + ghost boundary kernels, live forcing reads.
#   2. THE PASS FIRES — two same-structure equations over different states
#      collapse to fewer kernels than the unmerged build carries. (This is the
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

# :oop builds with the class merge on / off. Kernel counts are read off the
# rhs closure's captured vector — the same reflection the tracing tools use.
function _om_build(model, ics; merged::Bool, param_arrays=Dict{String,Any}())
    withenv("ESS_OOP_MERGE_DISABLE" => (merged ? nothing : "1")) do
        fo, u0, p, _t, vm, _d = ESM._build_evaluator_impl(model;
            initial_conditions=ics, form=:oop, param_arrays=param_arrays)
        (fo, u0, p, vm)
    end
end
_om_nkernels(fo) = length(getfield(ESM.rhs_with_buffers(fo), :acc_kernels))
_ip(f!, u, p, t) = (du = zero(u); f!(du, u, p, t); du)

# Two SAME-STRUCTURE equations over different states — one merge class of two
# members. The kernels differ only in their state slots (and out-slots), the
# exact thing the merge transposes into per-lane tables.
function _om_twin_model(N)
    vars = Dict("u" => ESM.ModelVariable(ESM.StateVariable),
                "v" => ESM.ModelVariable(ESM.StateVariable))
    body(x) = _op("*", _n(-0.5), _op("*", _idx(x, _v("i")), _idx(x, _v("i"))))
    ESM.Model(vars, [
        ESM.Equation(_ao1(_Didx("u", _v("i")), "i", 1, N), _ao1(body("u"), "i", 1, N)),
        ESM.Equation(_ao1(_Didx("v", _v("i")), "i", 1, N), _ao1(body("v"), "i", 1, N))])
end

# Twin Laplacians: same-class STENCIL kernels (interior + ghost boundary cells)
# for two states — classes across equations AND ghost-pattern variety.
function _om_twin_stencil_model(N)
    vars = Dict("u" => ESM.ModelVariable(ESM.StateVariable),
                "v" => ESM.ModelVariable(ESM.StateVariable))
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
    vars = Dict("u" => ESM.ModelVariable(ESM.StateVariable),
                "v" => ESM.ModelVariable(ESM.StateVariable))
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
        "u" => ESM.ModelVariable(ESM.StateVariable),
        "v" => ESM.ModelVariable(ESM.StateVariable),
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

@testset ":oop kernel-class merge ≡ unmerged (oop_merge.jl)" begin

    @testset "pointwise twin classes merge and stay bit-identical (N=$N)" for N in (8, 33)
        ics = _om_ics(N)
        fom, u0, p, _ = _om_build(_om_twin_model(N), ics; merged=true)
        fou, _, _, _  = _om_build(_om_twin_model(N), ics; merged=false)
        @test _om_nkernels(fom) < _om_nkernels(fou)      # the pass FIRED
        for t in (0.0, 0.37)
            @test fom(u0, p, t) == fou(u0, p, t)         # bit-for-bit
        end
        # and both agree with the in-place production emitter
        f!, ui, pi_, _t, _vm, _d = ESM._build_evaluator_impl(_om_twin_model(N);
            initial_conditions=ics)
        @test fom(ui, pi_, 0.0) == _ip(f!, ui, pi_, 0.0)
    end

    @testset "stencil interior + ghost boundary kernels (N=$N)" for N in (8, 32)
        ics = _om_ics(N)
        fom, u0, p, _ = _om_build(_om_twin_stencil_model(N), ics; merged=true)
        fou, _, _, _  = _om_build(_om_twin_stencil_model(N), ics; merged=false)
        @test _om_nkernels(fom) < _om_nkernels(fou)
        for t in (0.0, 1.9)
            @test fom(u0, p, t) == fou(u0, p, t)
        end
    end

    @testset "live forcing stays live through the merged table" begin
        N = 16
        buf = Float64[0.5 + 0.2k for k in 1:N]
        ics = _om_ics(N)
        pa = Dict{String,Any}("forcing" => buf)
        fom, u0, p, _ = _om_build(_om_twin_forcing_model(N), ics; merged=true,
                                  param_arrays=pa)
        fou, _, _, _  = _om_build(_om_twin_forcing_model(N), ics; merged=false,
                                  param_arrays=pa)
        @test _om_nkernels(fom) < _om_nkernels(fou)
        du1 = fom(u0, p, 0.0)
        @test du1 == fou(u0, p, 0.0)
        buf .= reverse(buf) .+ 3.0            # in-place refresh, no rebuild
        du2 = fom(u0, p, 0.0)
        @test du2 == fou(u0, p, 0.0)          # still ≡ unmerged after refresh
        @test du2 != du1                      # and the refresh was actually seen
    end

    @testset "ForwardDiff through merged kernels ≡ unmerged" begin
        N = 8
        ics = _om_ics(N)
        fom, u0, p, _ = _om_build(_om_twin_stencil_model(N), ics; merged=true)
        fou, _, _, _  = _om_build(_om_twin_stencil_model(N), ics; merged=false)
        Jm = ForwardDiff.jacobian(u -> fom(u, p, 0.0), u0)
        Ju = ForwardDiff.jacobian(u -> fou(u, p, 0.0), u0)
        @test Jm == Ju
    end

    @testset "ESS_OOP_MERGE_DISABLE=1 restores the unmerged kernel list" begin
        N = 8
        ics = _om_ics(N)
        fou, _, _, _ = _om_build(_om_twin_model(N), ics; merged=false)
        fou2, _, _, _ = _om_build(_om_twin_model(N), ics; merged=false)
        @test _om_nkernels(fou) == _om_nkernels(fou2)
    end
end

# ============================================================================
# The `:inplace` side of the SAME pass. Since the hoist into
# `_build_evaluator_impl` phase 4 (build.jl, before the xcse gate and before
# the emitter branch), the class merge applies to the production in-place
# `f!` too. Mirrors the :oop testsets above: merged vs
# ESS_OOP_MERGE_DISABLE=1 builds must be BIT-IDENTICAL (`==`, never
# `isapprox`) on the twin pointwise model, the twin stencil (ghost boundary)
# model, and the live-forcing model incl. an in-place buffer refresh; and the
# pass must observably FIRE (the closure's kernel list shrinks — read off
# `kernel_section.kernels` under ESS_CODEGEN_DISABLE=1, where nothing is
# emitted and the full list is introspectable).
# ============================================================================

# In-place builds with the class merge on / off. `codegen=false` disables the
# B1 codegen tier so `getfield(f!, :kernel_section).kernels` holds every
# kernel; the default `codegen=true` build exercises the codegen emitter OVER
# merged kernels (source generation + compiled loop nests).
function _im_build(model, ics; merged::Bool, codegen::Bool=true,
                   param_arrays=Dict{String,Any}())
    withenv("ESS_OOP_MERGE_DISABLE" => (merged ? nothing : "1"),
            "ESS_CODEGEN_DISABLE" => (codegen ? nothing : "1")) do
        f!, u0, p, _t, vm, d = ESM._build_evaluator_impl(model;
            initial_conditions=ics, param_arrays=param_arrays)
        (f!, u0, p, vm, d)
    end
end
# Residual (non-codegen) kernel count of the in-place closure — the full
# kernel list when built under ESS_CODEGEN_DISABLE=1 (n_emitted == 0).
function _im_nkernels(f!)
    ks = getfield(f!, :kernel_section)
    @test getfield(ks, :n_emitted) == 0
    length(getfield(ks, :kernels))
end

@testset ":inplace kernel-class merge ≡ unmerged (hoisted, build.jl)" begin

    @testset "pointwise twins: fires + bit-identical (N=$N)" for N in (8, 33)
        ics = _om_ics(N)
        # codegen-disabled pair: countable kernels + the lane-tape/scalar path
        fm, um, pm, _, dm = _im_build(_om_twin_model(N), ics; merged=true, codegen=false)
        fu, uu, pu, _, du_ = _im_build(_om_twin_model(N), ics; merged=false, codegen=false)
        @test _im_nkernels(fm) < _im_nkernels(fu)        # the pass FIRED (IIP)
        @test dm.n_acc_kernels < du_.n_acc_kernels       # and the diag agrees
        @test dm.n_classmerge_in == du_.n_acc_kernels    # pre-merge count kept
        for t in (0.0, 0.37)
            @test _ip(fm, um, pm, t) == _ip(fu, uu, pu, t)
        end
        # default (codegen-enabled) pair: the B1 tier accepts merged kernels
        fmc, umc, pmc, _, _ = _im_build(_om_twin_model(N), ics; merged=true)
        fuc, uuc, puc, _, _ = _im_build(_om_twin_model(N), ics; merged=false)
        for t in (0.0, 0.37)
            @test _ip(fmc, umc, pmc, t) == _ip(fuc, uuc, puc, t)
            @test _ip(fmc, umc, pmc, t) == _ip(fm, um, pm, t)  # ≡ interpreted
        end
    end

    @testset "stencil twins (ghost boundary) (N=$N)" for N in (8, 32)
        ics = _om_ics(N)
        fm, um, pm, _, _ = _im_build(_om_twin_stencil_model(N), ics; merged=true, codegen=false)
        fu, uu, pu, _, _ = _im_build(_om_twin_stencil_model(N), ics; merged=false, codegen=false)
        @test _im_nkernels(fm) < _im_nkernels(fu)
        for t in (0.0, 1.9)
            @test _ip(fm, um, pm, t) == _ip(fu, uu, pu, t)
        end
        # codegen tier over the merged stencil kernels, still bit-identical
        fmc, umc, pmc, _, _ = _im_build(_om_twin_stencil_model(N), ics; merged=true)
        @test _ip(fmc, umc, pmc, 1.9) == _ip(fu, uu, pu, 1.9)
    end

    @testset "live forcing stays live through the merged table (in place)" begin
        N = 16
        buf = Float64[0.5 + 0.2k for k in 1:N]
        ics = _om_ics(N)
        pa = Dict{String,Any}("forcing" => buf)
        fm, um, pm, _, _ = _im_build(_om_twin_forcing_model(N), ics; merged=true,
                                     codegen=false, param_arrays=pa)
        fu, uu, pu, _, _ = _im_build(_om_twin_forcing_model(N), ics; merged=false,
                                     codegen=false, param_arrays=pa)
        @test _im_nkernels(fm) < _im_nkernels(fu)
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
        fm, um, pm, _, _ = _im_build(_om_twin_stencil_model(N), ics; merged=true)
        fu, uu, pu, _, _ = _im_build(_om_twin_stencil_model(N), ics; merged=false)
        Jm = ForwardDiff.jacobian((du, u) -> fm(du, u, pm, 0.0), zero(um), um)
        Ju = ForwardDiff.jacobian((du, u) -> fu(du, u, pu, 0.0), zero(uu), uu)
        @test Jm == Ju
    end

    @testset "value-identical invariant tier SURVIVES the merge (both forms)" begin
        N = 12
        ics = _om_ics(N)
        # in place: inv slots kept (evaluated once per call, not per lane) …
        fm, um, pm, _, dm = _im_build(_om_twin_inv_model(N), ics; merged=true, codegen=false)
        fu, uu, pu, _, du_ = _im_build(_om_twin_inv_model(N), ics; merged=false, codegen=false)
        @test dm.n_acc_kernels < du_.n_acc_kernels     # classes merged
        @test dm.n_acc_inv_slots >= 1                  # …but the hoist survived
        for t in (0.0, 0.42)
            @test _ip(fm, um, pm, t) == _ip(fu, uu, pu, t)
        end
        # …and through the codegen tier
        fmc, umc, pmc, _, _ = _im_build(_om_twin_inv_model(N), ics; merged=true)
        @test _ip(fmc, umc, pmc, 0.42) == _ip(fu, uu, pu, 0.42)
        # :oop: the merged kernel's kept inv tier runs the vectorized prelude
        fom, u0, p, _ = _om_build(_om_twin_inv_model(N), ics; merged=true)
        fou, _, _, _  = _om_build(_om_twin_inv_model(N), ics; merged=false)
        @test _om_nkernels(fom) < _om_nkernels(fou)
        for t in (0.0, 0.42)
            @test fom(u0, p, t) == fou(u0, p, t)
            @test fom(u0, p, t) == _ip(fm, um, pm, t)  # oop ≡ inplace
        end
    end

    @testset "ESS_KERNEL_CLASS_MERGE_DISABLE alias disables the pass too" begin
        N = 8
        ics = _om_ics(N)
        falias, _, _, _, dalias = withenv("ESS_KERNEL_CLASS_MERGE_DISABLE" => "1",
                                          "ESS_CODEGEN_DISABLE" => "1") do
            f!, u0, p, _t, vm, d = ESM._build_evaluator_impl(_om_twin_model(N);
                initial_conditions=ics)
            (f!, u0, p, vm, d)
        end
        fu, _, _, _, du_ = _im_build(_om_twin_model(N), ics; merged=false, codegen=false)
        @test _im_nkernels(falias) == _im_nkernels(fu)
        @test dalias.n_acc_kernels == du_.n_acc_kernels
    end
end
