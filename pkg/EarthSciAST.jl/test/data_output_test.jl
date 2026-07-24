# Streaming output sinks — build_output_callback (streaming-output-sinks RFC §16,
# Wave 1). The OUTPUT mirror of data_refresh_test.jl.
#
# Where the refresh surface PULLS native arrays into live buffers at each cadence
# anchor, the output surface PUSHES a `StateSnapshot` to a Sink at each output
# anchor: a `PresetTimeCallback` whose `affect!` snapshots the integrator state
# (host-gather `state_snapshot`) and hands it to every sink whose output times
# include the tick. These tests exercise the full user wiring — a hand-written ODE
# + `build_output_callback` + an honest `solve(prob, Tsit5(); callback, tstops,
# save_everystep=false)` (the solver is the test-only dep; ESS ships none) — and
# pin every acceptance clause:
#   • build_output_callback returns (cb, tstops);
#   • each sink captures state at exactly its own output times (host-gather);
#   • tstops are the sorted, de-duplicated UNION across sinks;
#   • observed fields reach the sink when the snapshot carries them, pre_write first;
# Plus the protocol/type guards (throwing fallbacks, defaults) that need no solver.

using Test
using EarthSciAST
using DiffEqCallbacks            # loads EarthSciASTDataOutputExt
using SciMLBase                  # ext co-trigger
import OrdinaryDiffEqTsit5 as ODE  # Tsit5 + ODEProblem + solve

const ESM = EarthSciAST

# ---- A mock Sink implementing the full ESS producer protocol ----
# Records (t, copy of the first state slab, copy of the observed dict) on each
# `sink_write!`, tracks the lifecycle calls, and carries a settable
# `sink_output_times`. `nwrites` proves a sink writes only at its OWN anchors.
mutable struct MockSink
    times::Vector{Float64}
    records::Vector{Tuple{Float64,Vector{Float64},Dict{String,Array}}}
    observed_names::Vector{String}
    supports_partial::Bool
    opened::Bool
    closed::Bool
    nflush::Int
end
MockSink(times; observed_names=String[], supports_partial=false) =
    MockSink(Float64[t for t in times],
             Tuple{Float64,Vector{Float64},Dict{String,Array}}[],
             observed_names, supports_partial, false, false, 0)

ESM.sink_output_times(s::MockSink) = s.times
ESM.sink_open!(s::MockSink) = (s.opened = true; nothing)
function ESM.sink_write!(s::MockSink, snap::StateSnapshot; selection=nothing)
    slab = snap.state[1][1]                       # v1: one (slab, range) pair
    obs = Dict{String,Array}(k => copy(v) for (k, v) in snap.observed)
    push!(s.records, (snap.t, Vector{Float64}(slab), obs))
    return nothing
end
ESM.sink_flush!(s::MockSink) = (s.nflush += 1; nothing)
ESM.sink_close!(s::MockSink) = (s.closed = true; nothing)
ESM.sink_supports_partial(s::MockSink) = s.supports_partial
ESM.sink_observed_names(s::MockSink) = s.observed_names

# A source with NO protocol methods — its generics must throw a clean OutputError.
struct _BareSink end

# The trivial linear-decay ODE: D(u) = -u, so u(t) = exp(-t) .* u0 exactly. A
# direct readout of "the snapshot saw the state at each output anchor."
_decay!(du, u, p, t) = (du .= .-u; nothing)
const _U0 = [1.0, 2.0]

@testset "build_output_callback (streaming-output-sinks RFC §16, Wave 1)" begin

    @testset "returns (cb, tstops); sink captures host-gathered state at each output time" begin
        m = MockSink([0.2, 0.5, 0.8])
        cb, tstops = build_output_callback(;
            sinks=[m], snapshot=state_snapshot, pre_write=() -> nothing)

        @test tstops == [0.2, 0.5, 0.8]
        @test cb isa SciMLBase.DiscreteCallback         # PresetTimeCallback is a DiscreteCallback

        prob = ODE.ODEProblem(_decay!, copy(_U0), (0.0, 1.0))
        sol = ODE.solve(prob, ODE.Tsit5();
            callback=cb, tstops=tstops, save_everystep=false)
        @test sol.retcode == ODE.SciMLBase.ReturnCode.Success

        # One record per output anchor, in order, holding exp(-t).*u0.
        @test [r[1] for r in m.records] == [0.2, 0.5, 0.8]
        for (t, slab, obs) in m.records
            @test isapprox(slab, exp(-t) .* _U0; atol=1e-6)
            @test isempty(obs)                          # no observed names ⇒ empty
        end

        # save_everystep=false ⇒ the solver stops accumulating the DENSE per-step
        # trajectory; the sink captured every output anchor — the whole point of
        # streaming output. (PresetTimeCallback still saves at its own ticks, so
        # sol.u holds the anchors + endpoints, not the full adaptive-step history.)
        @test length(sol.u) <= 2 * length(tstops) + 2
    end

    @testset "tstops are the sorted, de-duplicated UNION of two sinks' output times" begin
        # Two sinks with different cadences; each writes ONLY at its own anchors,
        # while the solver stops at the union of both.
        m1 = MockSink([0.25, 0.75])
        m2 = MockSink([0.5])
        cb, tstops = build_output_callback(;
            sinks=[m1, m2], snapshot=state_snapshot, pre_write=() -> nothing)
        @test tstops == [0.25, 0.5, 0.75]

        prob = ODE.ODEProblem(_decay!, copy(_U0), (0.0, 1.0))
        sol = ODE.solve(prob, ODE.Tsit5();
            callback=cb, tstops=tstops, save_everystep=false)
        @test sol.retcode == ODE.SciMLBase.ReturnCode.Success

        @test [r[1] for r in m1.records] == [0.25, 0.75]   # m1 only at its own times
        @test [r[1] for r in m2.records] == [0.5]          # m2 only at its own time
        for (t, slab, _) in m1.records
            @test isapprox(slab, exp(-t) .* _U0; atol=1e-6)
        end
        @test isapprox(m2.records[1][2], exp(-0.5) .* _U0; atol=1e-6)
    end

    @testset "observed fields ride the snapshot; pre_write runs BEFORE the snapshot" begin
        # A caller snapshot that folds an observed field (energy = sum(u.^2)) into
        # the StateSnapshot, and a pre_write hook that freshens a cache first. The
        # log proves pre_write fires before snapshot at each boundary.
        m = MockSink([0.3, 0.6]; observed_names=["energy"])
        log = Symbol[]
        cache = Dict{String,Array}()
        pre_write = () -> (push!(log, :pre); nothing)
        function snap_fn(integrator)
            push!(log, :snap)
            u = Array(integrator.u)
            cache["energy"] = [sum(abs2, u)]
            return StateSnapshot(Float64(integrator.t),
                Tuple{Array,Tuple{Vararg{UnitRange{Int}}}}[(u, (1:length(u),))],
                Dict{String,Array}("energy" => copy(cache["energy"])))
        end

        cb, tstops = build_output_callback(; sinks=[m], snapshot=snap_fn, pre_write=pre_write)
        prob = ODE.ODEProblem(_decay!, copy(_U0), (0.0, 1.0))
        sol = ODE.solve(prob, ODE.Tsit5();
            callback=cb, tstops=tstops, save_everystep=false)
        @test sol.retcode == ODE.SciMLBase.ReturnCode.Success

        @test log == [:pre, :snap, :pre, :snap]         # pre_write before snapshot, each anchor
        @test [r[1] for r in m.records] == [0.3, 0.6]
        for (t, slab, obs) in m.records
            @test haskey(obs, "energy")
            @test isapprox(obs["energy"][1], sum(abs2, exp(-t) .* _U0); atol=1e-6)
        end
    end

    @testset "empty output times ⇒ a valid no-op callback, empty tstops" begin
        m = MockSink(Float64[])                          # predicate-only / no fixed anchors
        cb, tstops = build_output_callback(;
            sinks=[m], snapshot=state_snapshot, pre_write=() -> nothing)
        @test isempty(tstops)
        @test cb isa SciMLBase.DiscreteCallback

        prob = ODE.ODEProblem(_decay!, copy(_U0), (0.0, 1.0))
        sol = ODE.solve(prob, ODE.Tsit5(); callback=cb, save_everystep=false)
        @test sol.retcode == ODE.SciMLBase.ReturnCode.Success
        @test isempty(m.records)                         # never written
    end

    @testset "state_snapshot: host-gather v1 shape" begin
        # One (slab, global-range) pair covering the whole flat state at offset 0.
        fakeint = (u=[3.0, 4.0, 5.0],)                   # anything with a `.u` field
        st = state_snapshot(fakeint)
        @test length(st) == 1
        slab, ranges = st[1]
        @test slab == [3.0, 4.0, 5.0]
        @test ranges == (1:3,)
        @test slab !== fakeint.u                         # Array(u) is a fresh host copy
    end

    @testset "protocol + type guards" begin
        # Unimplemented Sink protocol → a clean OutputError, not a MethodError.
        @test_throws OutputError sink_output_times(_BareSink())
        @test_throws OutputError sink_open!(_BareSink())
        @test_throws OutputError sink_write!(_BareSink(),
            StateSnapshot(0.0, Tuple{Array,Tuple{Vararg{UnitRange{Int}}}}[], Dict{String,Array}()))
        @test_throws OutputError sink_flush!(_BareSink())
        @test_throws OutputError sink_close!(_BareSink())

        # Capability defaults: partial writes off, no observed names.
        @test sink_supports_partial(_BareSink()) == false
        @test sink_observed_names(_BareSink()) == String[]

        # The MockSink's own protocol methods answer.
        m = MockSink([1.0]; observed_names=["a"], supports_partial=true)
        @test sink_output_times(m) == [1.0]
        @test sink_supports_partial(m) == true
        @test sink_observed_names(m) == ["a"]
        sink_open!(m); @test m.opened
        sink_flush!(m); @test m.nflush == 1
        sink_close!(m); @test m.closed

        # The core fallback fires for a positional-arg call (which never matches the
        # extension's keyword-only method), telling the user what to load. This is
        # the observable proxy for "extension not loaded" — the extension IS loaded
        # here (DiffEqCallbacks + SciMLBase), so unloading it to hit the fallback via
        # the keyword form is impractical; the varargs fallback path is identical.
        err = try build_output_callback(:unexpected_positional); nothing catch e; e end
        @test err isa OutputError
        @test occursin("DiffEqCallbacks", err.msg)
    end
end
