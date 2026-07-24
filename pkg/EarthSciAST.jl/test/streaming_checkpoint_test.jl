# Wave 3 (streaming-output-sinks RFC §10, §16.7): predicate-driven checkpoint +
# manifest-driven restart. Uses the streaming_decay_grid model, whose pointwise
# decay D(c) = -k*c has the closed form c(t) = c0 * exp(-k*t) — so a checkpoint's
# state can be verified analytically without knowing the exact (predicate-driven,
# run-dependent) checkpoint time. Covers:
#   * the checkpoint predicate builtins + `any_of` combinator (pure unit tests),
#   * a predicate-fired full-state checkpoint (DiscreteCallback → write + flush +
#     terminate), read back through `zarr_restart_state` and checked analytically,
#   * a restart CONTINUATION that resumes from the committed (t, u) and reaches the
#     same endpoint as an uninterrupted run within solver tolerance (§16.7).

using Test
using EarthSciAST
import EarthSciIO
import Blosc
using DiffEqCallbacks, SciMLBase
using OrdinaryDiffEqTsit5: Tsit5

@testset "Checkpoint predicates + restart (Wave 3)" begin
    # --- predicate builtins (pure) ---
    @test any_of()() == false                          # empty OR ⇒ never fires
    @test any_of(() -> false, () -> true)() == true
    @test any_of(() -> false, () -> false)() == false

    @test spot_preemption_predicate(poll = () -> true)() == true
    @test spot_preemption_predicate(poll = () -> false)() == false

    # SLURM walltime: fires within the margin, not outside; false when unset.
    withenv("SLURM_JOB_END_TIME" => "1000") do
        near = slurm_walltime_predicate(; margin_seconds = 300, clock = () -> 800.0)
        far  = slurm_walltime_predicate(; margin_seconds = 300, clock = () -> 600.0)
        @test near() == true      # 1000 - 800 = 200 <= 300
        @test far()  == false     # 1000 - 600 = 400 >  300
    end
    withenv("SLURM_JOB_END_TIME" => nothing) do
        @test slurm_walltime_predicate(; clock = () -> 0.0)() == false   # not under SLURM
    end

    # --- a predicate-fired checkpoint, verified analytically ---
    fixture = joinpath(@__DIR__, "fixtures", "streaming_decay_grid.esm")
    prep = prepare(fixture)
    k = 0.001                                   # fixture's decay rate (scalar param)
    seed! = (u0, _vm) -> (@inbounds for i in eachindex(u0); u0[i] = Float64(i); end)

    dir = mktempdir()
    base_url = "file://" * joinpath(dir, "ckpt.zarr")
    # predicate-only sink: no fixed output cadence (output_times empty), lossless
    # checkpoint codec, one record per shard so each checkpoint auto-commits.
    cksink = build_zarr_sink(prep, base_url; output_times = Float64[],
                             profile = :checkpoint, records_per_shard = 1)

    # An always-true predicate fires at the first accepted step: checkpoint the full
    # state there, flush, and terminate for a clean early exit.
    simulate(prep, (0.0, 100.0); alg = Tsit5(),
             sinks = Any[], checkpoint_sinks = Any[cksink],
             checkpoint_predicates = Any[() -> true],
             terminate_on_checkpoint = true, seed_ic! = seed!)

    man = cksink.manifest
    @test man !== nothing
    @test man.n_records >= 1
    @test man.last_t !== nothing
    @test man.profile == "checkpoint"

    # restart-read the committed checkpoint and check it analytically.
    t1, u1 = zarr_restart_state(prep, base_url)
    @test 0.0 <= t1 < 100.0        # terminated early (well before the end)
    @test length(u1) == length(prep.u0)
    for i in eachindex(u1)
        @test isapprox(u1[i], Float64(i) * exp(-k * t1); rtol = 1e-4, atol = 1e-6)
    end

    # --- restart CONTINUATION: resume from (t1, u1), reach the same end within tol ---
    ref = simulate(prep, (0.0, 100.0); alg = Tsit5(), saveat = [100.0], seed_ic! = seed!)
    uend_ref = ref.u[end]

    seed_from_u1 = (u0, _vm) -> (u0 .= u1)
    cont = simulate(prep, (t1, 100.0); alg = Tsit5(), saveat = [100.0],
                    seed_ic! = seed_from_u1)
    uend_cont = cont.u[end]

    @test length(uend_cont) == length(uend_ref)
    for i in eachindex(uend_ref)
        @test isapprox(uend_cont[i], uend_ref[i]; rtol = 1e-5, atol = 1e-6)
    end
end
