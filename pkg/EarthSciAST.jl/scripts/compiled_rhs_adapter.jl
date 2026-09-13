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
#   --engine compiled     UNAVAILABLE in phase 1. Julia's compiled lane is direct
#                         StableHLO emission through the Reactant extension, and
#                         phase 2 owns it. Nothing is wired here on purpose: a
#                         half-wired emitter that silently fell back to the
#                         interpreter would make this tier report agreement
#                         between the interpreter and itself, which is exactly
#                         the reading the `unavailable` outcome exists to prevent.

# Self-contained environment bootstrap, identical in shape to
# pde_simulation_adapter.jl: the dedicated adapter project
# (scripts/pde_sim_adapter/Project.toml) already pins EarthSciAST (dev'd from
# ../..) + JSON3, so this adapter reuses it rather than standing up a second env.
# Manifest.toml is gitignored repo-wide, so on a fresh checkout we re-establish
# the local dev path then instantiate; on warm runs this is a fast resolve check.
import Pkg
let env = joinpath(@__DIR__, "pde_sim_adapter"), manifest = joinpath(env, "Manifest.toml")
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
        @warn "pde_sim_adapter env did not instantiate; rebuilding Manifest.toml" exception = (err, catch_backtrace())
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

# Manifest `path` is relative to the repository's `tests/` directory, and the
# manifest itself lives at tests/conformance/compiled_rhs/manifest.json — so the
# corpus root is two levels above the manifest's own directory. Deriving it
# rather than taking it from the environment keeps the adapter runnable from any
# working directory, which is what the runner's tempfile handoff assumes.
tests_root(manifest_path) = normpath(joinpath(dirname(abspath(manifest_path)), "..", ".."))

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
        rhs[String(pr.id)] = Dict{String,Float64}(name => Float64(du[idx])
                                                  for (name, idx) in slot)
    end
    Dict("rhs" => rhs)
end

function main()
    manifest_path, output_path, engine = parse_args(ARGS)

    if engine == "compiled"
        # The whole-output `unavailable` shape (README "Adapter contract"): the
        # runner prints the reason and skips, because `julia` is listed only in
        # the compiled engine's `bindings_optional`. It is NEVER a pass.
        payload = Dict(
            "binding" => BINDING,
            "engine" => engine,
            "status" => "unavailable",
            "reason" => "Julia compiled engine (direct StableHLO emission) lands in phase 2",
        )
        open(output_path, "w") do io
            JSON3.write(io, payload)
        end
        return
    end

    manifest = JSON3.read(read(manifest_path, String))
    base = tests_root(manifest_path)
    fixtures = Dict{String,Any}()
    for fx in manifest.fixtures
        fixtures[String(fx.id)] = fixture_rhs(fx, base)
    end
    payload = Dict("binding" => BINDING, "engine" => engine, "fixtures" => fixtures)
    open(output_path, "w") do io
        JSON3.write(io, payload)
    end
end

main()
