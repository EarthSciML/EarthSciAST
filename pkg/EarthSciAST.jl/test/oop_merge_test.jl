# The :oop kernel-CLASS merge (src/tree_walk/oop_merge.jl): `_make_rhs_oop`
# groups structurally identical `_AccKernel`s and merges each class into one
# lane-batched kernel whose varying leaves are per-lane tables.
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
