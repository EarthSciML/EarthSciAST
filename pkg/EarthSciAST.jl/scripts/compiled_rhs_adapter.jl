# Julia adapter for the `compiled_rhs` conformance tier.
#
# The REFERENCE binding. For every fixture in the manifest it evaluates the
# right-hand side `f(u, p, t)` at each declared probe — a fixed flat state vector
# and a fixed time — and reports `du` keyed by the bare column-major element name
# (`u[1]`, `u[i,j]`, a scalar `s`; the `Model.` namespace stripped), the same
# spelling the PDE-simulation tier uses.
#
# The contract (manifest schema, CLI, output JSON, the refusal and unavailable
# outcomes) is tests/conformance/compiled_rhs/README.md; the normative text is
# CONFORMANCE_SPEC.md §5.38.
#
#   julia --project=pkg/EarthSciAST.jl/scripts/pde_sim_adapter \
#         pkg/EarthSciAST.jl/scripts/compiled_rhs_adapter.jl \
#         --manifest <manifest.json> --output <out.json> [--engine interpreter|compiled]
#
# TWO ENGINES, ONE ADAPTER:
#
#   --engine interpreter  the MTK-free tree-walk evaluator (`build_evaluator` ->
#                         `f!(du, u, p, t)`). This is what mints the tier's
#                         goldens and what the cross-binding gate compares.
#   --engine compiled     direct StableHLO emission: the model's compiled
#                         tree-walk IR is lowered op by op into a StableHLO
#                         program (ext/reactant_direct/, `direct_rhs`), compiled
#                         on an XLA client, and evaluated at every probe. WHICH
#                         client is `EARTHSCI_JULIA_XLA_DEVICE` (see below);
#                         the default is the host CPU.
#                         There is NO fallback: a model the emitter cannot lower
#                         completely is a hard `DirectEmitError`, reported as
#                         that fixture's `refused` outcome with the rule and the
#                         reason taken off the error. A fallback to the
#                         interpreter would make this tier report agreement
#                         between the interpreter and itself, which is exactly
#                         the reading the `refused` and `unavailable` outcomes
#                         exist to prevent.
#
# WHICH DEVICE, AND WHY IT IS NOT IN THE REPORT.
#
#   EARTHSCI_JULIA_XLA_DEVICE=cpu   (the default) compile and run on the host
#                                   CPU client. Always available.
#   EARTHSCI_JULIA_XLA_DEVICE=gpu   compile and run on the attached accelerator.
#                                   With no GPU on the machine this is the
#                                   whole-output `unavailable` outcome, with the
#                                   client error as the reason — never a pass,
#                                   and never a silent fall back to the CPU,
#                                   which would report a CPU run under a GPU
#                                   label.
#
# The tier's report schema has no field for the platform: a fixture entry is the
# probe values, a `refused`, or an `error`, and the README's "Adapter contract"
# admits no extra keys, because a key one binding invents becomes a key every
# other binding has to reproduce. So the platform is announced on STDERR, once,
# as `compiled_rhs_adapter: julia engine=compiled device=... platform=...`, and
# the runner's captured adapter stderr is where a reader confirms which device a
# run used. Nothing parses that line.
#
# TWO ENVIRONMENTS, for the same reason. The interpreter engine reuses
# scripts/pde_sim_adapter; the compiled engine gets its own
# scripts/compiled_rhs_reactant_env, because Reactant bundles an XLA runtime and
# the reference lane must not depend on it. Both self-bootstrap.

# Self-contained environment bootstrap, identical in shape to
# pde_simulation_adapter.jl. Which env depends on the ENGINE, so `--engine` is
# read here, straight off ARGS, before anything is loaded: the interpreter lane
# keeps the existing pde_sim_adapter project (EarthSciAST dev'd from ../.. +
# JSON3), the compiled lane gets compiled_rhs_reactant_env (the same, plus
# Reactant). Manifest.toml is gitignored repo-wide, so on a fresh checkout we
# re-establish the local dev path then instantiate; on warm runs this is a fast
# resolve check.
import Pkg
const ENGINE = let e = "interpreter"
    for i in eachindex(ARGS)
        ARGS[i] == "--engine" && i < length(ARGS) && (e = ARGS[i + 1])
    end
    e
end
let env = joinpath(@__DIR__, ENGINE == "compiled" ? "compiled_rhs_reactant_env" :
                             "pde_sim_adapter"),
    manifest = joinpath(env, "Manifest.toml")
    bootstrap() = begin
        Pkg.activate(env; io=devnull)
        isfile(manifest) ||
            Pkg.develop(path=normpath(joinpath(@__DIR__, "..")); io=devnull)
        Pkg.instantiate(; io=devnull)
    end
    try
        bootstrap()
    catch err
        # A Manifest.toml is a machine-local CACHE that can lag a Project.toml
        # that has moved on and then contradict it; one that cannot instantiate
        # has no value, so rebuild rather than fail the gate. `Pkg.develop` only
        # writes the Manifest here — EarthSciAST is already in the Project's
        # [deps], so the tracked Project.toml is not touched.
        @warn "$(basename(env)) env did not instantiate; rebuilding Manifest.toml" exception = (err, catch_backtrace())
        rm(manifest; force=true)
        bootstrap()
    end
end

using EarthSciAST
using JSON3

const BINDING = "julia"

function parse_args(args)
    manifest = nothing
    output = nothing
    engine = "interpreter"
    i = 1
    while i <= length(args)
        if args[i] == "--manifest"
            manifest = args[i + 1]; i += 2
        elseif args[i] == "--output"
            output = args[i + 1]; i += 2
        elseif args[i] == "--engine"
            engine = args[i + 1]; i += 2
        else
            i += 1
        end
    end
    manifest === nothing && error("--manifest is required")
    output === nothing && error("--output is required")
    engine in ("interpreter", "compiled") ||
        error("--engine must be 'interpreter' or 'compiled', got '$engine'")
    (manifest, output, engine)
end

# Strip a leading `Model.` namespace so element names compare across bindings
# (`AtmColumn.T[1]` -> `T[1]`). An un-namespaced name has no dot and passes
# through; the bracketed index part never contains one.
_bare(name::AbstractString) = occursin('.', name) ? String(split(name, '.'; limit = 2)[2]) : String(name)

# Manifest `path` is relative to the repository's `tests/` directory. Every
# adapter and the runner resolve it the same way: walk up from the manifest to
# the NEAREST ancestor directory named `tests`, falling back to the manifest's
# own directory when there is none. A fixed number of parent hops would break the
# moment a manifest moved a level; deriving the root rather than taking it from
# the environment keeps the adapter runnable from any working directory, which is
# what the runner's tempfile handoff assumes.
function tests_root(manifest_path)
    dir = dirname(abspath(manifest_path))
    cur = dir
    while true
        basename(cur) == "tests" && return cur
        parent = dirname(cur)
        parent == cur && return dir
        cur = parent
    end
end

# The flat state layout the manifest's `state_order` names: bare element name ->
# its index in `u`. Built from the evaluator's OWN var map, never by hand, so a
# manifest that drifts from the evaluator's layout is caught by name here rather
# than silently evaluated at the wrong slot.
function bare_var_map(var_map)
    out = Dict{String,Int}()
    for (name, idx) in var_map
        out[_bare(String(name))] = idx
    end
    out
end

# Apply the fixture's `parameters` overrides to the built parameter object.
# Phase 1 manifests use empty maps only; the override path is implemented rather
# than stubbed so a phase-2 manifest that starts using it does not need the
# adapters re-opened.
function apply_parameters(p, overrides)
    (overrides === nothing || isempty(overrides)) && return p
    p === nothing && error("fixture declares parameter overrides but the model has no parameters")
    names = Symbol[]
    vals = Float64[]
    for (k, v) in pairs(overrides)
        sym = Symbol(String(k))
        haskey(p, sym) || error("parameter override '$(String(k))' is not a parameter of this model")
        push!(names, sym)
        push!(vals, Float64(v))
    end
    merge(p, NamedTuple{Tuple(names)}(Tuple(vals)))
end

function fixture_rhs(fx, base)
    path = joinpath(base, String(fx.path))
    file = load_path(path)
    f!, u0, p, _, var_map = build_evaluator(file; model_name = String(fx.model))
    slot = bare_var_map(var_map)

    order = [String(s) for s in fx.state_order]
    for name in order
        haskey(slot, name) ||
            error("state_order element '$name' is not in the evaluator var map for " *
                  "$(fx.id) (have: $(join(sort(collect(keys(slot))), ", ")))")
    end
    length(order) == length(u0) ||
        error("state_order for $(fx.id) has $(length(order)) elements but the " *
              "evaluator's state vector has $(length(u0))")

    p_fx = apply_parameters(p, get(fx, :parameters, nothing))

    rhs = Dict{String,Any}()
    for pr in fx.rhs_probes
        u = copy(u0)
        for (rawname, val) in pairs(pr.state)
            u[slot[String(rawname)]] = Float64(val)
        end
        # Zero-initialize du: a state slot carrying no explicit `D`-equation is
        # never written by `f!`, so `similar` would leave uninitialized garbage
        # in its entry. Every sanctioned integrator zero-inits du before each
        # call; mirror that so the probe reports a deterministic 0 there.
        du = zero(u)
        f!(du, u, p_fx, Float64(pr.t))
        # Emit EXACTLY the manifest's `state_order`, and nothing else. A binding
        # whose shape inference invents an extra flat element must not smuggle it
        # into the comparison, where it would become a requirement every other
        # binding had to reproduce.
        rhs[String(pr.id)] = Dict{String,Float64}(name => Float64(du[slot[name]])
                                                  for name in order)
    end
    Dict("rhs" => rhs)
end

# ── The compiled engine ────────────────────────────────────────────────────
#
# Direct StableHLO emission (ext/reactant_direct/): the fixture's model is built
# out-of-place, its compiled IR is lowered into a StableHLO program, that program
# is compiled on Reactant's CPU client, and every probe is evaluated by RUNNING
# it. Nothing here evaluates a probe any other way.
#
# ONE COMPILE PER FIXTURE, not per probe: `u`, `t` and the parameters are all
# program INPUTS (a `ConcreteRArray` and `ConcreteRNumber`s), so the probes of a
# fixture differ only in the values fed to the same executable. A recompile per
# probe would be an O(#probes) XLA compile that measured nothing the tier asks
# about.
#
# A `DirectEmitError` is the fixture's `refused` outcome, with `rule` and
# `reason` taken straight off the error — that is the hard-error ruling made
# visible. Every other exception is the ordinary per-fixture `error` entry,
# which is a FAILURE: unlike a refusal it says nothing about what the engine can
# lower.

# The device choice, read once. Anything other than the two spellings is a hard
# error rather than a silent default: a typo that quietly ran on the CPU would
# report a CPU run under a GPU label.
const XLA_DEVICE = let d = lowercase(strip(get(ENV, "EARTHSCI_JULIA_XLA_DEVICE", "cpu")))
    d == "" && (d = "cpu")
    d in ("cpu", "gpu") ||
        error("EARTHSCI_JULIA_XLA_DEVICE must be 'cpu' or 'gpu', got '$d'")
    d
end

const REACTANT_LOAD_ERROR = Ref{Any}(nothing)
const HAVE_REACTANT = if ENGINE != "compiled"
    false      # the interpreter lane's env does not carry Reactant, by design
else
    try
        @eval using Reactant
        true
    catch err
        REACTANT_LOAD_ERROR[] = err
        false
    end
end

# The client the compiled engine runs on, resolved ONCE (resolving it per
# fixture would re-enter the GPU client initialization 19 times). Held as a
# `Ref` so `main` can answer `unavailable` when the GPU client cannot be built,
# before any fixture is attempted.
const XLA_CLIENT = Ref{Any}(nothing)
const XLA_CLIENT_ERROR = Ref{Any}(nothing)

function resolve_client()
    ext = Base.get_extension(EarthSciAST, :EarthSciASTReactantExt)
    ext === nothing && error("the Reactant extension did not load")
    try
        XLA_CLIENT[] = ext.direct_client(XLA_DEVICE)
        true
    catch err
        XLA_CLIENT_ERROR[] = err
        false
    end
end

# THE FUNCTION BARRIER IN FRONT OF `@compile`. Nothing here is inferable: the
# evaluator, the wrapper and therefore the device inputs all come out of calls
# whose types depend on a fixture read at runtime, so at the call site above
# `d`, `u_dev` and `t_dev` are all `Any`. `Reactant.@compile` expands to
# machinery — a generated function whose generator runs GPUCompiler — that is
# inferred through those argument types, and inferring it through `Any`s sends
# Julia's abstract interpreter into a recursion that trips the stack-overflow
# guard and then WEDGES the process: it stops accumulating CPU inside `typeinf`
# and never returns, on the CPU client as readily as on a GPU one.
#
# Passing the four values through a plain function first is the ordinary Julia
# answer: Julia specializes `compile_rhs` on their runtime types, so INSIDE it
# every argument is concrete and the compile is inferred exactly as it is from a
# script that spelled the concrete constructors out. `run_rhs` is the same
# barrier for the per-probe call.
compile_rhs(d, u_dev, p_dev, t_dev) = Reactant.@compile sync = true d(u_dev, p_dev, t_dev)
run_rhs(compiled, u_dev, p_dev, t_dev) = Array(compiled(u_dev, p_dev, t_dev))

function fixture_rhs_compiled(fx, base)
    ext = Base.get_extension(EarthSciAST, :EarthSciASTReactantExt)
    ext === nothing && error("the Reactant extension did not load")

    path = joinpath(base, String(fx.path))
    file = load_path(path)
    fo, u0, p, _, var_map = build_evaluator(file; model_name = String(fx.model),
                                            form = :oop)
    slot = bare_var_map(var_map)

    order = [String(s) for s in fx.state_order]
    for name in order
        haskey(slot, name) ||
            error("state_order element '$name' is not in the evaluator var map for " *
                  "$(fx.id) (have: $(join(sort(collect(keys(slot))), ", ")))")
    end
    length(order) == length(u0) ||
        error("state_order for $(fx.id) has $(length(order)) elements but the " *
              "evaluator's state vector has $(length(u0))")

    p_fx = apply_parameters(p, get(fx, :parameters, nothing))

    d = ext.direct_rhs(fo; var_map = var_map, client = XLA_CLIENT[])
    p_dev = ext.direct_params(d, p_fx)
    u_dev = ext.direct_state(d, copy(u0))
    t_dev = ext.direct_time(d, 0.0)
    compiled = compile_rhs(d, u_dev, p_dev, t_dev)

    rhs = Dict{String,Any}()
    for pr in fx.rhs_probes
        u = copy(u0)
        for (rawname, val) in pairs(pr.state)
            u[slot[String(rawname)]] = Float64(val)
        end
        du = run_rhs(compiled, ext.direct_state(d, u), p_dev,
                     ext.direct_time(d, Float64(pr.t)))
        rhs[String(pr.id)] = Dict{String,Float64}(name => Float64(du[slot[name]])
                                                  for name in order)
    end
    Dict("rhs" => rhs)
end

function main()
    manifest_path, output_path, engine = parse_args(ARGS)
    engine == ENGINE ||
        error("the bootstrap read engine '$ENGINE' off ARGS but parse_args read " *
              "'$engine'; the adapter would be running in the wrong environment")

    if engine == "compiled" && !HAVE_REACTANT
        # The whole-output `unavailable` shape (README "Adapter contract"): the
        # engine's runtime is not configured on this machine. The runner prints
        # the reason and skips, because `julia` is listed only in the compiled
        # engine's `bindings_optional`. It is NEVER a pass — which is why this
        # arm fires ONLY when Reactant cannot be loaded at all, never because a
        # model refused.
        payload = Dict(
            "binding" => BINDING,
            "engine" => engine,
            "status" => "unavailable",
            "reason" => "Reactant could not be loaded, so there is no XLA client " *
                        "to compile on: " * sprint(showerror, REACTANT_LOAD_ERROR[]),
        )
        open(output_path, "w") do io
            JSON3.write(io, payload)
        end
        return
    end

    if engine == "compiled" && !resolve_client()
        # Same whole-output `unavailable` shape, for the same reason: the
        # requested device is not configured on this machine. Asked for a GPU
        # and given none, the honest answer is "not run here" — falling back to
        # the CPU would report a CPU run under a GPU label.
        payload = Dict(
            "binding" => BINDING,
            "engine" => engine,
            "status" => "unavailable",
            "reason" => "EARTHSCI_JULIA_XLA_DEVICE=$XLA_DEVICE, but that XLA " *
                        "client could not be created on this machine: " *
                        sprint(showerror, XLA_CLIENT_ERROR[]),
        )
        open(output_path, "w") do io
            JSON3.write(io, payload)
        end
        return
    end

    if engine == "compiled"
        # The platform announcement (see "WHICH DEVICE" above): stderr, because
        # the report schema has no field for it.
        println(stderr, "compiled_rhs_adapter: julia engine=compiled ",
                "device=", XLA_DEVICE,
                " platform=", Reactant.XLA.platform_name(XLA_CLIENT[]),
                " addressable_devices=",
                length(Reactant.XLA.addressable_devices(XLA_CLIENT[])))
    end

    manifest = JSON3.read(read(manifest_path, String))
    base = tests_root(manifest_path)
    fixtures = Dict{String,Any}()
    failed = false
    for fx in manifest.fixtures
        id = String(fx.id)
        if engine == "interpreter"
            fixtures[id] = fixture_rhs(fx, base)
            continue
        end
        try
            fixtures[id] = fixture_rhs_compiled(fx, base)
        catch err
            if err isa EarthSciAST.DirectEmitError
                fixtures[id] = Dict("status" => "refused",
                                    "rule" => err.rule,
                                    "reason" => string(err.construct, ": ", err.detail))
            else
                failed = true
                fixtures[id] = Dict("error" => string(typeof(err), ": ",
                                                      sprint(showerror, err)))
            end
        end
    end
    payload = Dict("binding" => BINDING, "engine" => engine, "fixtures" => fixtures)
    open(output_path, "w") do io
        JSON3.write(io, payload)
    end
    # "A non-zero adapter exit with a valid report is allowed, and means at least
    # one fixture errored" (README, Adapter contract). A REFUSAL is not an error:
    # it is the documented outcome of the hard-error policy, and the runner
    # decides whether it fails the gate from `compiled_required`.
    failed && exit(1)
end

main()
