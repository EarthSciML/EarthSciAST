# Julia adapter for the `compiler_agreement` conformance tier.
#
# The REFERENCE binding. For every fixture in the manifest it builds an
# `esm_problem` with the compiler named on the command line, integrates the run
# the fixture defines, and reports the state rows at that run's save times keyed
# by bare column-major element name.
#
# The contract (manifest schema, CLI, output JSON, the five outcomes, the golden
# format) is tests/conformance/compiler_agreement/README.md; the normative text
# is CONFORMANCE_SPEC.md §5.44.
#
#   julia pkg/EarthSciAST.jl/scripts/compiler_agreement_adapter.jl \
#         --manifest <manifest.json> --output <out.json> --compiler <value>
#
# ONE ADAPTER, EVERY COMPILER. `--compiler` is required and takes one member of
# API_SPEC §5.8's closed vocabulary. Its value is passed STRAIGHT to
# `esm_problem` and never interpreted here: an adapter that read the value and
# chose a build itself would be reimplementing the thing under test. That is
# also why `:xla` and `:mtk` are not special-cased below — they answer
# `unavailable` because `esm_problem` raises `compiler_unavailable` for them,
# which is the binding's own statement about itself.
#
# THE THREE OUTCOMES THIS ADAPTER DECIDES, and the one it must not conflate:
#
#   refused      a `compiler_refused_rule` out of the build: THIS compiler
#                cannot lower THIS document, and says which rule and why. Per
#                fixture; the run continues with the next one.
#   unavailable  a `compiler_unavailable` out of the build: this compiler does
#                not exist in this binding or its runtime is not configured
#                here. That is a fact about the BINDING, not about a document,
#                so it is the whole output and the remaining fixtures are not
#                attempted.
#   error        anything else the load, the build or the solve threw. Per
#                fixture, and RED whatever the fixture's `required` map says.
#
# A refusal is never a fallback and never a pass: nothing here retries a refused
# fixture under another compiler.

# Self-contained environment bootstrap, the shape pde_simulation_adapter.jl and
# compiled_rhs_adapter.jl already use. This tier gets its OWN project
# (scripts/compiler_agreement_env) rather than reusing scripts/pde_sim_adapter,
# because a fixture's §2.2 `solver` block may declare `stiffness: "high"` and
# selecting the stiff algorithm for it needs OrdinaryDiffEqRosenbrock, which the
# PDE tier's env does not carry. Manifest.toml is gitignored repo-wide, so on a
# fresh checkout we re-establish the local dev path then instantiate; on warm
# runs this is a fast resolve check.
import Pkg
let env = joinpath(@__DIR__, "compiler_agreement_env"),
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
        @warn "compiler_agreement_env did not instantiate; rebuilding Manifest.toml" exception = (err, catch_backtrace())
        rm(manifest; force=true)
        bootstrap()
    end
end

using EarthSciAST
using JSON3
import OrdinaryDiffEqTsit5
import OrdinaryDiffEqRosenbrock
import SciMLBase

const BINDING = "julia"

# API_SPEC §5.8's closed vocabulary, checked here as well as in the runner. A
# value outside it is a broken invocation rather than a compiler this binding
# happens not to have, and the two must not arrive at the same answer.
const COMPILER_VOCABULARY = ("interpreter", "native", "xla", "mtk", "sympy")

function parse_args(args)
    manifest = nothing
    output = nothing
    compiler = nothing
    i = 1
    while i <= length(args)
        if args[i] == "--manifest"
            manifest = args[i + 1]; i += 2
        elseif args[i] == "--output"
            output = args[i + 1]; i += 2
        elseif args[i] == "--compiler"
            compiler = args[i + 1]; i += 2
        else
            i += 1
        end
    end
    manifest === nothing && error("--manifest is required")
    output === nothing && error("--output is required")
    compiler === nothing && error("--compiler is required")
    compiler in COMPILER_VOCABULARY ||
        error("--compiler must be one of " * join(COMPILER_VOCABULARY, ", ") *
              ", got '$compiler'")
    (manifest, output, compiler)
end

# Manifest `path` is relative to the repository's `tests/` directory: walk up
# from the manifest to the NEAREST ancestor directory named `tests`, falling
# back to the manifest's own directory. The same rule the runner and the
# compiled_rhs adapter use — a fixed number of parent hops would break the
# moment a manifest moved a level, and deriving the root rather than reading it
# from the environment keeps the adapter runnable from any working directory,
# which the runner's tempfile handoff assumes.
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

# The save-time key: a plain float string. The runner canonicalizes both sides
# to `repr(float(t))` and matches by NUMERIC value, so the rendering here only
# has to round-trip.
tkey(t) = string(float(t))

# ── The run a fixture defines ──────────────────────────────────────────────
#
# `trajectory.from` says where it comes from, and the adapter reads it exactly
# as the runner does. A `manifest` entry restates the whole run; an
# `inline_tests` entry restates none of it, so the document stays the single
# source of truth for its own run and the save times are the named test's
# ASSERTION TIMES. Save times are never the adapter's to choose.

_float_map(obj) = Dict{String,Any}(String(k) => v for (k, v) in pairs(obj))

function inline_test(doc, fx)
    model = get(get(doc, :models, Dict()), Symbol(String(fx.model)), nothing)
    model === nothing &&
        error("$(String(fx.path)) has no model $(String(fx.model))")
    tid = String(fx.trajectory.test_id)
    for t in get(model, :tests, ())
        String(get(t, :id, "")) == tid && return t
    end
    error("$(String(fx.path)) model $(String(fx.model)) has no inline test $tid")
end

# `(tspan, initial_conditions, parameter_overrides, saveat)` for one fixture.
function fixture_run(doc, fx)
    tr = fx.trajectory
    if String(tr.from) == "manifest"
        span = (Float64(tr.tspan[1]), Float64(tr.tspan[2]))
        saveat = Float64[Float64(t) for t in tr.saveat]
        return (span, _float_map(tr.initial_conditions),
                _float_map(get(tr, :parameter_overrides, Dict())), saveat)
    end
    t = inline_test(doc, fx)
    span = (Float64(t.time_span.start), Float64(t.time_span[Symbol("end")]))
    times = sort!(unique!(Float64[Float64(a.time) for a in get(t, :assertions, ())]))
    isempty(times) && error("inline test $(String(tr.test_id)) has no timed " *
                            "assertions, so it defines no save times")
    return (span, _float_map(get(t, :initial_conditions, Dict())),
            _float_map(get(t, :parameter_overrides, Dict())), times)
end

# The flattened system's parameter and state names, or `nothing` when the
# document cannot be flattened here — in which case the caller's keys pass
# through untouched and `esm_problem` reports the real failure rather than this
# helper reporting a derived one.
function flattened_names(path)
    try
        flat = flatten(load_path(path))
        return union(Set{String}(String(n) for n in keys(flat.parameters)),
                     Set{String}(String(n) for n in keys(flat.state_variables)))
    catch
        return nothing
    end
end

# Re-attach the scope an inline test's keys were written in.
#
# esm-spec §6.6.2 keys a test's `initial_conditions` / `parameter_overrides` by
# LOCAL name, local to the component that owns the test; `esm_problem` resolves
# against the whole flattened document, where that locality is gone. A key whose
# `<model>.<key>` form names a real variable of the flattened system is rewritten
# to it, and one that does not passes through untouched so `esm_problem` reports
# on it exactly as it would have. This is what `_scope_to_component` does for the
# library's own inline-test runner, so both paths resolve a test's keys the same
# way.
function scope_to_model(overrides, known, mname)
    (isempty(overrides) || known === nothing) && return overrides
    out = Dict{String,Any}()
    for (k, v) in overrides
        q = string(mname, ".", k)
        out[q in known ? q : k] = v
    end
    return out
end

# ── The trajectory this tier compares ──────────────────────────────────────

# The element slots the fixture's MODEL owns: flat index => bare name, in the
# evaluator's own column-major order.
#
# Scoped to the model the fixture names rather than taken whole, because a
# document may carry more than the one component — `tests_analyses_comprehensive`
# mounts a reaction system beside `LogisticGrowth` — and the golden is the
# reference's statement of what the trajectory IS. An element the reference does
# not carry is ignored by the gate, while one it carries and a producer does not
# is a mismatch, so a reference scoped to the named model holds every binding to
# the physics the fixture is about and to nothing else. Scoping also keeps the
# bare names unambiguous: two mounted components each declaring a `u` would
# collide the moment the namespace came off.
function model_slots(var_map, mname)
    out = Tuple{Int,String}[]
    prefix = mname * "."
    for (name, idx) in var_map
        s = String(name)
        startswith(s, prefix) || continue
        push!(out, (idx, String(SubString(s, length(prefix) + 1))))
    end
    # A document whose states carry no component namespace at all: report the
    # whole state rather than nothing, so an un-namespaced fixture is a
    # trajectory instead of an empty row nobody can read.
    if isempty(out)
        for (name, idx) in var_map
            push!(out, (idx, String(name)))
        end
    end
    sort!(out; by = first)
    return out
end

# The algorithm this fixture integrates with.
#
# esm-spec §2.2's `solver` block is the document's declaration about ITSELF, and
# `stiffness: "high"` selects a stiff algorithm. The TOLERANCES are not taken
# from the block: the manifest's per-fixture `integration` is what the adapter
# passes to `solve`, because a conformance tier has an opinion about the
# integrator's error and states it per fixture.
#
# WHY Rodas5P AND NOT Rosenbrock23, which is what `_pick_solver` hands the
# library's own inline-test runners. A GOLDEN'S OWN INTEGRATION ERROR MUST SIT
# FAR BELOW THE BAND IT IS COMPARED AT, or the tier stops measuring the compiler
# and starts measuring the integrator. On `decay_solver_block` — the one fixture
# whose document declares itself stiff — the band against the golden is 2.8e-11,
# and at this fixture's tolerances Rosenbrock23 lands 2.5e-8 from the closed form
# `2*exp(-2)`: three orders of magnitude OUTSIDE the band it is supposed to
# define. Anything more accurate than the golden then reads as a mismatch, which
# is how the Rust adapter's first run against it failed — correctly integrating,
# and red for it. Rodas5P lands 2.2e-14 from the closed form, roughly 1300x
# inside the band, so the golden is a statement about the arithmetic again.
# `stiffness: "high"` is still honoured, which is what the fixture is here to
# exercise; only the ORDER of the stiff method chosen for it changed.
function solver_alg(doc)
    blk = get(doc, :solver, nothing)
    stiff = blk === nothing ? nothing : get(blk, :stiffness, nothing)
    stiff !== nothing && String(stiff) == "high" &&
        return OrdinaryDiffEqRosenbrock.Rodas5P()
    return OrdinaryDiffEqTsit5.Tsit5()
end

# The saved point at `t`. `saveat` puts a point ON each requested time, so this
# is an exact hit up to the solver's own float arithmetic; taking the nearest
# saved index rather than the dense interpolant reports the value the solver
# actually saved.
function time_index(times, t)
    best = firstindex(times)
    bestd = abs(times[best] - t)
    for i in eachindex(times)
        d = abs(times[i] - t)
        d < bestd && (bestd = d; best = i)
    end
    best
end

function fixture_trajectory(fx, base, compiler)
    # `observed` carries one series per name in `trajectory.observed`, and `{}`
    # when the fixture names none — which is every fixture today. A fixture that
    # NAMES one is a named failure rather than an empty map the runner would
    # report as a missing field: the trajectory-time observed reader is the piece
    # to add here, and saying so is more use than a silent hole. Checked before
    # anything is built, because the answer does not depend on the run.
    named = [String(n) for n in get(fx.trajectory, :observed, ())]
    isempty(named) || error(
        "fixture $(String(fx.id)) names observed fields $(join(named, ", ")), and " *
        "this adapter reads state rows only; add an output-time observed reader " *
        "here before that fixture can be gated")

    path = joinpath(base, String(fx.path))
    doc = JSON3.read(read(path, String))
    mname = String(fx.model)
    span, ics, pover, saveat = fixture_run(doc, fx)
    integ = fx.integration
    reltol = Float64(integ.reltol)
    abstol = Float64(integ.abstol)

    known = flattened_names(path)
    prob = esm_problem(path, span;
                       u0 = scope_to_model(ics, known, mname),
                       p = scope_to_model(pover, known, mname),
                       compiler = Symbol(compiler))
    slots = model_slots(prob.var_map, mname)

    sol = SciMLBase.solve(prob, solver_alg(doc);
                          reltol = reltol, abstol = abstol, saveat = saveat)
    SciMLBase.successful_retcode(sol) || error("solve failed: retcode $(sol.retcode)")

    state = Dict{String,Any}()
    for t in saveat
        ti = time_index(sol.t, t)
        state[tkey(t)] = Dict{String,Float64}(name => Float64(sol.u[ti][idx])
                                              for (idx, name) in slots)
    end

    return Dict("state_order" => [name for (_, name) in slots],
                "state" => state,
                "observed" => Dict{String,Any}())
end

# The refusal's `rule` and `reason`, off the message `_refuse_rule` builds:
# `compiler=:<name> refuses '<rule>': <reason>`. The shape is the one
# esm-libraries-spec §2.5.10 fixes and the one this tier reads back, so parsing
# it is reading a contract rather than scraping a string; a message that does not
# match is reported whole under an unnamed rule instead of being dropped.
function refusal_parts(detail::AbstractString)
    m = match(r"^compiler=:\w+ refuses '(.*?)': (.*)$"s, detail)
    m === nothing && return ("(unnamed rule)", String(detail))
    return (String(m.captures[1]), String(m.captures[2]))
end

function main()
    manifest_path, output_path, compiler = parse_args(ARGS)
    manifest = JSON3.read(read(manifest_path, String))
    base = tests_root(manifest_path)

    fixtures = Dict{String,Any}()
    failed = false
    unavailable = nothing
    for fx in manifest.fixtures
        id = String(fx.id)
        try
            fixtures[id] = fixture_trajectory(fx, base, compiler)
        catch err
            if err isa SimulateError &&
               err.code == ERROR_CODES.COMPILER_UNAVAILABLE
                # A fact about the BINDING, not about a document, so it becomes
                # the whole output and the remaining fixtures are not attempted:
                # each would raise the identical error, and a per-fixture answer
                # would read as a coverage backlog instead of a missing compiler.
                unavailable = err.msg
                break
            elseif err isa TreeWalkError &&
                   err.code == ERROR_CODES.COMPILER_REFUSED_RULE
                rule, reason = refusal_parts(err.detail)
                fixtures[id] = Dict("status" => "refused",
                                    "rule" => rule, "reason" => reason)
            else
                failed = true
                fixtures[id] = Dict("error" => string(typeof(err), ": ",
                                                      sprint(showerror, err)))
            end
        end
    end

    payload = unavailable === nothing ?
        Dict("binding" => BINDING, "compiler" => compiler, "fixtures" => fixtures) :
        Dict("binding" => BINDING, "compiler" => compiler,
             "status" => "unavailable", "reason" => unavailable)
    open(output_path, "w") do io
        JSON3.write(io, payload)
    end
    # "A non-zero adapter exit with a valid report is allowed and means at least
    # one fixture errored" (README, Adapter contract). A REFUSAL is not an error:
    # it is the documented outcome of the hard-error policy, and the runner
    # decides from the fixture's `required` map whether it fails the gate.
    failed && exit(1)
end

main()
