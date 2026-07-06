# Live forcing-buffer gather: _NK_PARAM_GATHER / _VK_PGATHER (ess-14f.3, JL-J0).
#
# The evaluator change that lets a discrete-cadence forcing buffer be read LIVE by
# the RHS. Unlike `const_arrays` (build-time FROZEN — `index(arr,…)` const-folds to
# a literal), a buffer passed via `param_arrays` is bound BY REFERENCE: its
# `index(forcing,…)` reads compile to a live gather over an aliased flat view, so a
# refresh callback's in-place `buffer .= …` (the ess-14f.3 J1 callback) shows
# through to the RHS with zero reallocation.
#
# These tests pin: (1) the live-refresh semantics scalar + vectorized; (2)
# column-major linearization of an N-D forcing; (3) that the FROZEN const-array
# path is byte-unaffected when both channels coexist; (4) the build-time guards
# (OOB, ndim, non-Float64); (5) that a forcing array stays OUT of the scalar `p`
# NamedTuple so existing scalar-param reads are untouched.

using Test
using EarthSciSerialization

include("testutils.jl")  # _n/_i/_v/_op/_idx builder quartet

const ESM = EarthSciSerialization

@testset "live forcing gather _NK_PARAM_GATHER / _VK_PGATHER (ess-14f.3)" begin

    @testset "scalar gather reads live + reflects in-place refresh" begin
        # D(y) = forcing[2]
        model = ESM.Model(Dict("y" => ModelVariable(StateVariable)),
            [ESM.Equation(_op("D", _v("y"); wrt="t"), _idx("forcing", _i(2)))])
        buf = [3.0, 7.0, 11.0]
        f!, u0, p, _t, _vm = build_evaluator(model;
            initial_conditions=Dict("y" => 0.0), param_arrays=Dict("forcing" => buf))
        du = similar(u0); f!(du, u0, p, 0.0)
        @test du[1] == 7.0
        # In-place refresh of the SAME buffer object → RHS sees the new value.
        buf[2] = 42.0
        f!(du, u0, p, 0.0)
        @test du[1] == 42.0
    end

    @testset "vectorized gather reads live + reflects in-place refresh" begin
        # D(u[i]) = forcing[i] + u[i]
        N = 6
        model = ESM.Model(Dict("u" => ModelVariable(StateVariable)),
            [ESM.Equation(_ao1(_Didx("u", _v("i")), "i", 1, N),
                          _ao1(_op("+", _idx("forcing", _v("i")), _idx("u", _v("i"))), "i", 1, N))])
        buf = collect(10.0:10.0:10.0 * N)
        ics = Dict("u[$k]" => 0.0 for k in 1:N)
        f!, u0, p, _t, _vm = build_evaluator(model;
            initial_conditions=ics, param_arrays=Dict("forcing" => buf))
        du = similar(u0); f!(du, u0, p, 0.0)
        @test du == buf                       # u0 == 0 ⇒ du == forcing
        buf .= buf .+ 1000.0                  # in-place refresh
        f!(du, u0, p, 0.0)
        @test du == buf
    end

    @testset "N-D forcing: column-major linearization matches the buffer" begin
        # D(u[i]) = forcing2d[i, 3], a 4×5 buffer. The gather must read
        # forcing2d[i,3] for each i — i.e. column-major linear index 2*4 + i.
        nx, ny = 4, 5
        f2d = reshape(collect(1.0:Float64(nx * ny)), nx, ny)
        model = ESM.Model(Dict("u" => ModelVariable(StateVariable)),
            [ESM.Equation(_ao1(_Didx("u", _v("i")), "i", 1, nx),
                          _ao1(_idx("forcing2d", _v("i"), _i(3)), "i", 1, nx))])
        ics = Dict("u[$k]" => 0.0 for k in 1:nx)
        f!, u0, p, _t, _vm = build_evaluator(model;
            initial_conditions=ics, param_arrays=Dict("forcing2d" => f2d))
        du = similar(u0); f!(du, u0, p, 0.0)
        @test du == Float64[f2d[i, 3] for i in 1:nx]
    end

    @testset "FROZEN const-array path is byte-unaffected when both coexist" begin
        # D(u[i]) = w[i] (const, FROZEN) + forcing[i] (param, LIVE). Mutating the
        # const SOURCE after build has zero effect (it was inlined as a literal);
        # mutating the forcing buffer in place DOES refresh. This is the cadence
        # routing the node exists to honor: const ⇒ frozen, discrete ⇒ live.
        N = 4
        model = ESM.Model(Dict("u" => ModelVariable(StateVariable)),
            [ESM.Equation(_ao1(_Didx("u", _v("i")), "i", 1, N),
                          _ao1(_op("+", _idx("w", _v("i")), _idx("forcing", _v("i"))), "i", 1, N))])
        wsrc = collect(1.0:Float64(N))         # const source (will be inlined)
        fbuf = fill(100.0, N)                   # live forcing buffer
        ics = Dict("u[$k]" => 0.0 for k in 1:N)
        f!, u0, p, _t, _vm = build_evaluator(model; initial_conditions=ics,
            const_arrays=Dict("w" => wsrc), param_arrays=Dict("forcing" => fbuf))
        du = similar(u0); f!(du, u0, p, 0.0)
        @test du == Float64[wsrc[i] + 100.0 for i in 1:N]
        # Mutating the const SOURCE: NO effect (frozen at build).
        wfrozen = copy(wsrc)
        wsrc .= -999.0
        f!(du, u0, p, 0.0)
        @test du == Float64[wfrozen[i] + 100.0 for i in 1:N]
        # Mutating the forcing buffer: DOES refresh.
        fbuf .= 5.0
        f!(du, u0, p, 0.0)
        @test du == Float64[wfrozen[i] + 5.0 for i in 1:N]
    end

    @testset "array-shaped parameter via param_arrays stays out of scalar p" begin
        # A DECLARED array parameter `forcing` backed by param_arrays is accepted
        # (would otherwise be E_TREEWALK_UNSUPPORTED_SHAPE) and is NOT added to the
        # scalar `p` NamedTuple — which keeps the existing scalar-param read
        # homogeneous + zero-alloc. A scalar parameter `a` still rides `p`.
        N = 3
        vars = Dict(
            "u" => ModelVariable(StateVariable),
            "a" => ModelVariable(ParameterVariable; default=2.0),
            "forcing" => ModelVariable(ParameterVariable; shape=["i"]))
        model = ESM.Model(vars,
            [ESM.Equation(_ao1(_Didx("u", _v("i")), "i", 1, N),
                          _ao1(_op("*", _v("a"), _idx("forcing", _v("i"))), "i", 1, N))])
        buf = collect(1.0:Float64(N))
        ics = Dict("u[$k]" => 0.0 for k in 1:N)
        f!, u0, p, _t, _vm = build_evaluator(model;
            initial_conditions=ics, param_arrays=Dict("forcing" => buf))
        # `p` carries the scalar `a` but NOT the array `forcing`.
        @test haskey(p, :a)
        @test !haskey(p, :forcing)
        @test p.a == 2.0
        du = similar(u0); f!(du, u0, p, 0.0)
        @test du == Float64[2.0 * buf[i] for i in 1:N]
    end

    @testset "build-time guards" begin
        N = 3
        mk(body) = ESM.Model(Dict("u" => ModelVariable(StateVariable)),
            [ESM.Equation(_ao1(_Didx("u", _v("i")), "i", 1, N), _ao1(body, "i", 1, N))])
        ics = Dict("u[$k]" => 0.0 for k in 1:N)

        # Out-of-range index → E_TREEWALK_PGATHER_OOB.
        err = try
            build_evaluator(mk(_idx("forcing", _i(9)));
                initial_conditions=ics, param_arrays=Dict("forcing" => fill(0.0, N)))
            nothing
        catch e; e end
        @test err isa ESM.TreeWalkError && err.code == "E_TREEWALK_PGATHER_OOB"

        # ndim mismatch (2 indices into a 1-D buffer) → E_TREEWALK_PGATHER_NDIM.
        err = try
            build_evaluator(mk(_idx("forcing", _v("i"), _i(1)));
                initial_conditions=ics, param_arrays=Dict("forcing" => fill(0.0, N)))
            nothing
        catch e; e end
        @test err isa ESM.TreeWalkError && err.code == "E_TREEWALK_PGATHER_NDIM"

        # Non-Float64 buffer → E_TREEWALK_PARAM_ARRAY_TYPE.
        err = try
            build_evaluator(mk(_idx("forcing", _v("i")));
                initial_conditions=ics, param_arrays=Dict("forcing" => [1, 2, 3]))
            nothing
        catch e; e end
        @test err isa ESM.TreeWalkError && err.code == "E_TREEWALK_PARAM_ARRAY_TYPE"
    end
end
