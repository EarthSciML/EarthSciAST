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
#         --manifest <manifest.json> --output <out.json> --compiler <value> \
#         [--engine interpreter|compiled]
#
# `--engine` AND `--compiler` ARE DIFFERENT QUESTIONS, and both are answered
# here rather than inherited:
#
#   --engine    WHICH LANE evaluates the right-hand side — this tier's own axis.
#               The tree-walk evaluator, or direct StableHLO emission.
#   --compiler  WHICH STRATEGY BUILDS it, over API_SPEC §5.8's closed vocabulary.
#               Passed straight to the build and never interpreted here.
#
# `--compiler` is REQUIRED (CONFORMANCE_SPEC §5.44.5): a problem-building stage
# NAMES the compiler it runs, so that a change to the library's default can never
# change what this tier measures. The stages pass `native`, because every fixture
# here is in its scope. `native` refuses by name only out-of-scope constructs
# (events, implicit equations, SDE noise, a spatial operator with no
# discretization rule: API_SPEC §5.8); only a stage whose fixtures carry one
# names `interpreter` instead, and says why where it does so.
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

# Which environment depends on the ENGINE, so `--engine` is read straight off
# ARGS before anything is loaded: the interpreter lane uses the pde_sim_adapter
# project (EarthSciAST developed from ../.. + JSON3), the compiled lane
# compiled_rhs_reactant_env (the same, plus Reactant).
include(joinpath(@__DIR__, "adapter_support.jl"))
const ENGINE = flag_value(ARGS, "--engine", "interpreter")
activate_adapter_env(
    joinpath(
        @__DIR__, ENGINE == "compiled" ? "compiled_rhs_reactant_env" : "pde_sim_adapter"
    )
)

using EarthSciAST
using JSON3

const BINDING = "julia"

# `--compiler` is REQUIRED: a stage names the compiler it runs (CONFORMANCE_SPEC
# §5.44.5), so this adapter never falls back to the library default. Defaulting
# it would put the stage back in the position the rule exists to prevent — a
# change of the library's default silently changing what this tier measures.

# The value after the flag at `args[i]`; a flag at the end of the line has none.
_flag_value(args, i) =
    i < length(args) ? args[i + 1] : error("$(PROGRAM_FILE): $(args[i]) needs a value")

function parse_args(args)
    manifest = nothing
    output = nothing
    engine = "interpreter"
    compiler = nothing
    i = 1
    while i <= length(args)
        if args[i] == "--manifest"
            manifest = _flag_value(args, i); i += 2
        elseif args[i] == "--output"
            output = _flag_value(args, i); i += 2
        elseif args[i] == "--engine"
            engine = _flag_value(args, i); i += 2
        elseif args[i] == "--compiler"
            compiler = _flag_value(args, i); i += 2
        else
            error("$(PROGRAM_FILE): unrecognised argument $(repr(args[i]))")
        end
    end
    manifest === nothing && error("--manifest is required")
    output === nothing && error("--output is required")
    compiler === nothing && error("--compiler is required")
    engine in ("interpreter", "compiled") ||
        error("--engine must be 'interpreter' or 'compiled', got '$engine'")
    check_compiler(compiler, EarthSciAST.COMPILER_VOCABULARY)
    return (manifest, output, engine, compiler)
end

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
    return
end

# The flat state layout the manifest's `state_order` names: bare element name ->
# its index in `u`. Built from the evaluator's OWN var map, never by hand, so a
# manifest that drifts from the evaluator's layout is caught by name here rather
# than silently evaluated at the wrong slot.
function bare_var_map(var_map)
    out = Dict{String, Int}()
    for (name, idx) in var_map
        out[bare_name(String(name))] = idx
    end
    return out
end

# Apply the fixture's `parameters` overrides (keyed by the component's local
# parameter names) to the built parameter object, whose names are qualified.
function apply_parameters(p, model, overrides)
    (overrides === nothing || isempty(overrides)) && return p
    p === nothing && error("fixture declares parameter overrides but the model has no parameters")
    names = Symbol[]
    vals = Float64[]
    for (k, v) in pairs(overrides)
        sym = Symbol("$model.$(String(k))")
        haskey(p, sym) || error("parameter override '$(String(k))' is not a parameter of this model")
        push!(names, sym)
        push!(vals, Float64(v))
    end
    return merge(p, NamedTuple{Tuple(names)}(Tuple(vals)))
end

# The fixture's document reduced to the one model the manifest names: the tier
# measures that component's right-hand side on its own, so the document's other
# components and the couplings between them are dropped before the build
# flattens it.
function component_document(path, model)
    doc = JSON3.read(read(path, String), Dict{String, Any})
    models = doc["models"]
    haskey(models, model) || error("$(path) declares no model '$model'")
    doc["models"] = Dict{String, Any}(model => models[model])
    delete!(doc, "reaction_systems")
    delete!(doc, "coupling")
    return doc
end

build_component(fx, base, compiler; kw...) = EarthSciAST.Internal.build(
    component_document(joinpath(base, String(fx.path)), String(fx.model));
    base_path = dirname(joinpath(base, String(fx.path))),
    compiler = Symbol(compiler), kw...
)

function fixture_rhs(fx, base, compiler)
    f!, u0, p, _, var_map = build_component(fx, base, compiler)
    slot = bare_var_map(var_map)

    order = [String(s) for s in fx.state_order]
    for name in order
        haskey(slot, name) ||
            error(
            "state_order element '$name' is not in the evaluator var map for " *
                "$(fx.id) (have: $(join(sort(collect(keys(slot))), ", ")))"
        )
    end
    length(order) == length(u0) ||
        error(
        "state_order for $(fx.id) has $(length(order)) elements but the " *
            "evaluator's state vector has $(length(u0))"
    )

    p_fx = apply_parameters(p, String(fx.model), get(fx, :parameters, nothing))

    rhs = Dict{String, Any}()
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
        rhs[String(pr.id)] = Dict{String, Float64}(
            name => Float64(du[slot[name]])
                for name in order
        )
    end
    return Dict("rhs" => rhs)
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
# visible; so is a `compiler_refused_rule` the out-of-place build raises before
# any emission, its `rule` read off the error's field. Every other exception is
# the ordinary per-fixture `error` entry, which is a FAILURE: unlike a refusal it
# says nothing about what the engine can lower.

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
    return try
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
#
# Defined only when Reactant is loaded: `Reactant.@compile` is a macro, so a
# top-level definition would be expanded — and fail with `Reactant` undefined —
# while this file loads for the INTERPRETER engine, whose environment carries no
# Reactant on purpose.
if HAVE_REACTANT
    @eval begin
        compile_rhs(d, u_dev, p_dev, t_dev) =
            Reactant.@compile sync = true d(u_dev, p_dev, t_dev)
        run_rhs(compiled, u_dev, p_dev, t_dev) = Array(compiled(u_dev, p_dev, t_dev))
    end
end

function fixture_rhs_compiled(fx, base, compiler)
    ext = Base.get_extension(EarthSciAST, :EarthSciASTReactantExt)
    ext === nothing && error("the Reactant extension did not load")

    fo, u0, p, _, var_map = build_component(fx, base, compiler; form = :oop)
    slot = bare_var_map(var_map)

    order = [String(s) for s in fx.state_order]
    for name in order
        haskey(slot, name) ||
            error(
            "state_order element '$name' is not in the evaluator var map for " *
                "$(fx.id) (have: $(join(sort(collect(keys(slot))), ", ")))"
        )
    end
    length(order) == length(u0) ||
        error(
        "state_order for $(fx.id) has $(length(order)) elements but the " *
            "evaluator's state vector has $(length(u0))"
    )

    p_fx = apply_parameters(p, String(fx.model), get(fx, :parameters, nothing))

    d = ext.direct_rhs(fo; var_map = var_map, client = XLA_CLIENT[])
    p_dev = ext.direct_params(d, p_fx)
    u_dev = ext.direct_state(d, copy(u0))
    t_dev = ext.direct_time(d, 0.0)
    compiled = compile_rhs(d, u_dev, p_dev, t_dev)

    rhs = Dict{String, Any}()
    for pr in fx.rhs_probes
        u = copy(u0)
        for (rawname, val) in pairs(pr.state)
            u[slot[String(rawname)]] = Float64(val)
        end
        du = run_rhs(
            compiled, ext.direct_state(d, u), p_dev,
            ext.direct_time(d, Float64(pr.t))
        )
        rhs[String(pr.id)] = Dict{String, Float64}(
            name => Float64(du[slot[name]])
                for name in order
        )
    end
    return Dict("rhs" => rhs)
end

function main()
    manifest_path, output_path, engine, compiler = parse_args(ARGS)
    engine == ENGINE ||
        error(
        "the bootstrap read engine '$ENGINE' off ARGS but parse_args read " *
            "'$engine'; the adapter would be running in the wrong environment"
    )

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
        println(
            stderr, "compiled_rhs_adapter: julia engine=compiled ",
            "device=", XLA_DEVICE,
            " platform=", Reactant.XLA.platform_name(XLA_CLIENT[]),
            " addressable_devices=",
            length(Reactant.XLA.addressable_devices(XLA_CLIENT[]))
        )
    end

    manifest = JSON3.read(read(manifest_path, String))
    base = tests_root(manifest_path)
    fixtures = Dict{String, Any}()
    failed = false
    for fx in manifest.fixtures
        id = String(fx.id)
        if engine == "interpreter"
            fixtures[id] = fixture_rhs(fx, base, compiler)
            continue
        end
        try
            fixtures[id] = fixture_rhs_compiled(fx, base, compiler)
        catch err
            if err isa EarthSciAST.DirectEmitError
                fixtures[id] = Dict(
                    "status" => "refused",
                    "rule" => err.rule,
                    "reason" => string(err.construct, ": ", err.detail)
                )
            elseif err isa EarthSciAST.TreeWalkError &&
                    err.code == EarthSciAST.ERROR_CODES.COMPILER_REFUSED_RULE &&
                    !isempty(err.rule)
                # The out-of-place product refused a rule by name before any
                # emission (a causal recurrence, for one): the same hard-error
                # ruling, reached one step earlier. A refusal that names no
                # rule falls through to the failure arm below.
                fixtures[id] = Dict(
                    "status" => "refused",
                    "rule" => err.rule,
                    "reason" => err.detail
                )
            else
                failed = true
                fixtures[id] = Dict(
                    "error" => string(
                        typeof(err), ": ",
                        sprint(showerror, err)
                    )
                )
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
    return failed && exit(1)
end

main()
