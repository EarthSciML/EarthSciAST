# MULTI-DEVICE agreement for the compiled backend: the same right-hand side,
# sharded along the flat state's cell axis across several devices, must answer
# what one device answers and what the interpreter answers.
#
# DOUBLY OPT-IN, because it needs hardware the default test run does not have:
# `ESM_TEST_REACTANT=1` (as every reactant_*_test.jl does) AND
# `ESM_TEST_REACTANT_GPU=1`. Without the second it prints why it is skipping and
# asserts nothing.
#
#     ESM_TEST_REACTANT=1 ESM_TEST_REACTANT_GPU=1 julia --project=<env> \
#       -e 'cd("pkg/EarthSciAST.jl/test"); include("reactant_direct_sharding_test.jl")'
#
# WHICH DEVICES. `EARTHSCI_JULIA_XLA_DEVICE` picks the client, the same variable
# the conformance adapter reads; it defaults to `gpu` here, because that is the
# configuration this file exists to cover. Setting it to `cpu` with
# `XLA_FLAGS=--xla_force_host_platform_device_count=N` runs the identical
# assertions against N mock host devices, which is how the sharding was
# developed without a GPU in hand. The assertions do not depend on the platform.
#
# WHAT IS ASSERTED.
#
#   AGREEMENT at 2 and at 4 devices, against the interpreter `f!` and against
#   the unsharded compiled run, at `u0` and at deterministic perturbations, to
#   the tier's `rtol = 1e-12`. Sharding is a placement decision: it may reorder
#   a reduction across a collective, so this is a tolerance, never `==`.
#
#   THE REFUSALS, because they are the contract of device.jl: a device count
#   that does not divide the flat state, a one-device "shard", and a slab that
#   would straddle a variable block. Each is a `DirectEmitError` whose message
#   names why.

using Test
using EarthSciAST
using Reactant

include("testutils.jl")  # TESTUTILS_REPO_ROOT

const _SH_ON = get(ENV, "ESM_TEST_REACTANT_GPU", "0") == "1"

if !_SH_ON
    @info "skipping reactant_direct_sharding_test.jl: it needs two or more XLA " *
          "devices. Set ESM_TEST_REACTANT_GPU=1 on a machine with GPUs (or with " *
          "EARTHSCI_JULIA_XLA_DEVICE=cpu and " *
          "XLA_FLAGS=--xla_force_host_platform_device_count=4 to use mock host " *
          "devices)."
else

const ESM_SH = EarthSciAST
const EXT_SH = Base.get_extension(EarthSciAST, :EarthSciASTReactantExt)
@assert EXT_SH !== nothing "the Reactant extension did not load"

const SH_DEVICE = lowercase(strip(get(ENV, "EARTHSCI_JULIA_XLA_DEVICE", "gpu")))
const SH_CLIENT = EXT_SH.direct_client(SH_DEVICE)
const SH_NDEV = length(EXT_SH.direct_devices(SH_CLIENT))

@info "reactant_direct_sharding_test.jl on platform " *
      "$(Reactant.XLA.platform_name(SH_CLIENT)) with $SH_NDEV addressable device(s)"

_sh_fix(parts...) = joinpath(TESTUTILS_REPO_ROOT, "tests", parts...)

# The interpreter's answer at (u, t) — the reference every compiled answer is
# compared against, built fresh from the document so nothing is shared with the
# out-of-place build under test.
function sh_reference(path)
    file = load_path(path)
    f!, u0, p, _, _ = EarthSciAST._build_evaluator(file)
    return (u, t) -> begin
        du = zero(u)
        f!(du, u, p, Float64(t))
        du
    end, copy(u0)
end

# Compile the direct emitter for `path` on `SH_CLIENT`, optionally sharded
# across `ndev` devices, and return a closure `(u, t) -> du` on the host.
function sh_compiled(path; ndev = nothing)
    file = load_path(path)
    fo, u0, p, _, vmap = EarthSciAST._build_evaluator(file; form = :oop)
    d = EXT_SH.direct_rhs(fo; var_map = vmap, client = SH_CLIENT, sharding = ndev)
    p_dev = EXT_SH.direct_params(d, p)
    u_dev = EXT_SH.direct_state(d, copy(u0))
    t_dev = EXT_SH.direct_time(d, 0.0)
    xla = sh_compile(d, u_dev, p_dev, t_dev)
    return (u, t) -> Array(xla(EXT_SH.direct_state(d, u), p_dev,
                               EXT_SH.direct_time(d, t))), copy(u0), d
end

# The function barrier the adapter uses, for the same reason: `d` and the device
# inputs are all built from values read at runtime, so at the call site above
# they are `Any`, and `Reactant.@compile` inferred through `Any` arguments sends
# Julia's abstract interpreter into the recursion that trips the stack-overflow
# guard. Passing them through a plain function first makes Julia specialize on
# their runtime types, so the compile is inferred with concrete arguments.
sh_compile(d, u_dev, p_dev, t_dev) = Reactant.@compile sync = true d(u_dev, p_dev, t_dev)

# Deterministic probes: `u0` itself plus two reproducible perturbations, at two
# times. A single probe at `u0` would pass on a program that ignored `u`.
sh_probes(u0) = [(copy(u0), 0.0),
                 (u0 .+ 0.25 .* cos.(1:length(u0)), 0.0),
                 (u0 .+ 0.5 .* sin.(2.0 .* (1:length(u0))), 1.5)]

# ---- agreement, one fixture per device count --------------------------------

@testset "direct emission, cell-axis sharding" begin
    # A 1-D periodic diffusion over 8 cells: ONE state variable, so the flat
    # state is a single block and a slab is a contiguous cell range — the shape
    # the cell-axis shard is for, and the one whose halo the collective has to
    # carry across a device boundary.
    fix = _sh_fix("conformance", "pde_simulation", "fixtures",
                  "diffusion_1d_periodic_n8.esm")
    ref, u0 = sh_reference(fix)
    one_dev, _, _ = sh_compiled(fix)

    @testset "one device agrees with the interpreter" begin
        for (u, t) in sh_probes(u0)
            @test one_dev(u, t) ≈ ref(u, t) rtol = 1e-12
        end
    end

    for nd in (2, 4)
        if SH_NDEV < nd
            @info "skipping the $nd-device leg: only $SH_NDEV addressable device(s)"
            continue
        end
        @testset "$nd devices agree with the interpreter and with one device" begin
            shard, _, d = sh_compiled(fix; ndev = nd)
            @test EXT_SH.direct_shard(d) !== nothing
            @test EXT_SH.direct_devicecount(d) == nd
            for (u, t) in sh_probes(u0)
                @test shard(u, t) ≈ ref(u, t) rtol = 1e-12
                @test shard(u, t) ≈ one_dev(u, t) rtol = 1e-12
            end
        end
    end
end

# ---- the refusals ------------------------------------------------------------

@testset "direct emission, sharding refusals" begin
    fix = _sh_fix("conformance", "pde_simulation", "fixtures",
                  "diffusion_1d_periodic_n8.esm")
    fo, u0, _, _, vmap = EarthSciAST._build_evaluator(load_path(fix); form = :oop)

    @testset "a one-device shard is refused, not silently ignored" begin
        err = try
            EXT_SH.direct_rhs(fo; var_map = vmap, client = SH_CLIENT, sharding = 1)
            nothing
        catch e
            e
        end
        @test err isa ESM_SH.DirectEmitError
        @test occursin("at least two devices", err.detail)
    end

    if SH_NDEV >= 3
        @testset "an indivisible device count is refused by name" begin
            err = try
                EXT_SH.direct_rhs(fo; var_map = vmap, client = SH_CLIENT,
                                  sharding = 3)
                nothing
            catch e
                e
            end
            @test err isa ESM_SH.DirectEmitError
            @test occursin("not divisible", err.detail)
            @test occursin("$(length(u0))", err.construct)
        end
    end

    # The 7×7×7 transport fixture: 343 cells, an ODD flat length, so no even
    # device count divides it. That is the divisibility refusal on a real model
    # rather than a contrived one — and it is why this fixture is NOT in the
    # agreement testset above.
    @testset "the 343-cell transport fixture refuses an even shard" begin
        tfo, tu0, _, _, tvmap = EarthSciAST._build_evaluator(
            load_path(joinpath(TESTUTILS_REPO_ROOT, "tests", "bench",
                               "transport_3axis_7cubed_fullrank.esm"));
            form = :oop)
        if length(tu0) % 2 == 0
            @info "the transport fixture's flat state is even ($(length(tu0)) " *
                  "slots); the divisibility refusal does not apply to it"
        else
            err = try
                EXT_SH.direct_rhs(tfo; var_map = tvmap, client = SH_CLIENT,
                                  sharding = 2)
                nothing
            catch e
                e
            end
            @test err isa ESM_SH.DirectEmitError
            @test occursin("not divisible", err.detail)
        end
    end
end

end  # if _SH_ON
