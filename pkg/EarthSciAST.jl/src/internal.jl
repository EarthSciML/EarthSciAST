"""
    EarthSciAST.Internal

The build seam this package's own test suite and conformance adapters use: build
one input the way [`esm_problem`](@ref) builds it, and get back the right-hand
side together with a report of what the build did.

Not exported and not cross-binding API. API_SPEC §8 item 23 took the build
private behind `esm_problem`; this module is where it is reachable from, so a
test or an adapter names the one entry the build guarantees rather than the
build's own private functions. Callers outside this repository use
`esm_problem`.

* [`Internal.build`](@ref) — flatten, then build; returns a [`Internal.Build`](@ref).
* [`Internal.counting`](@ref) — the engagement counts of any call, for a build
  step run on its own.
"""
module Internal

import ..EarthSciAST
using ..EarthSciAST: Model, EsmFile, FlattenedSystem, IndexSet, CompilerPlan,
    CompilerReport, BuildProducts, Metadata, SCHEMA_VERSION
using OrderedCollections: OrderedDict

"""
    Internal.BuildReport

What one [`Internal.build`](@ref) did.

* `compiler_report` — the per-rule tier record [`compiler_report`](@ref)
  returns for a Problem built from the same input.
* `tally` — that report's cascade counters (`compiler_report.tally`).
* `counts` — every count the call produced, keyed by name: each cascade tally
  event (including those of the build's nested fills, which the report's own
  tally leaves to their own records) and the engagement counters no report row
  carries (the keys are listed beside `_count!` in `src/compiler.jl`).
* `stats` — the emitted right-hand side's structural counts: access kernels and
  their CSE slots, scalar CSE slots and occurrences, named observed slots,
  prelude slots by cadence, scan folds, array contractions, factored array
  observeds.
* `kernels` — the access kernels the right-hand side carries, after the class
  merge.
* `products` — the build's [`BuildProducts`](@ref): the public
  [`BuildInspection`](@ref) fields and the rest of what the build produced.
* `run_file` — the single-model run document the build compiled.
"""
struct BuildReport
    compiler_report::CompilerReport
    tally::Dict{Symbol, Int}
    counts::Dict{Symbol, Int}
    stats::NamedTuple
    kernels::AbstractVector
    products::BuildProducts
    run_file::EsmFile
end

"""
    Internal.Build

The result of [`Internal.build`](@ref): `f!`, `u0`, `p`, `tspan`, `var_map` and
`report` (a [`Internal.BuildReport`](@ref)). It destructures in that order, so
`f!, u0, p, tspan, var_map = Internal.build(m)` reads the first five.
"""
struct Build{F, P, V}
    f!::F
    u0::Vector{Float64}
    p::P
    tspan::Tuple{Float64, Float64}
    var_map::V
    report::BuildReport
end
Base.iterate(b::Build, i::Int = 1) = i > 6 ? nothing : (getfield(b, i), i + 1)
Base.length(::Build) = 6

# A forcing write announced to the build that reads it (see
# `EarthSciAST.notify_forcing_refresh!`).
EarthSciAST.notify_forcing_refresh!(b::Build) =
    EarthSciAST._bump_epoch!(b.report.products.forcing_epoch)
EarthSciAST._declare_announced!(b::Build) =
    (b.report.products.forcing_epoch.announced = true; nothing)

"""
    Internal.build(input; model_name = "M", compiler = :native, index_sets = nothing,
                   metaparameters = Dict(), base_path = pwd(), kwargs...) -> Internal.Build

Build `input` exactly as [`esm_problem`](@ref) builds it: load, refuse what the
run refuses, FLATTEN, adopt the shapes of whole-bound array data, then compile.
Every name the result carries — `var_map` keys, `report.products` keys — is the
flattened, component-qualified one (`"M.x"`), and so is every name a caller
passes (`parameter_overrides`, `initial_conditions`, `const_arrays`,
`param_arrays` keys).

`input` is a path, a native document `Dict`, an [`EsmFile`](@ref), a
[`FlattenedSystem`](@ref), or a bare [`Model`](@ref). A bare `Model` is first
made the only model of a document, named `model_name`, with `index_sets` as
that document's index-set registry; for any other input the document carries
its own, and `model_name` and `index_sets` are refused.

`compiler` is a vocabulary `Symbol` or a `CompilerPlan` (a compiler with some
tiers switched off, `EarthSciAST._plan_with`). The remaining keywords are the
build's own: `parameter_overrides`, `initial_conditions`, `const_arrays`,
`param_arrays`, `const_array_boundaries`, `tspan`, `form` (`:inplace` or
`:oop`), `materialize_out`. The compile is `esm_problem`'s own
(`_problem_build_run`): a discrete-cadence materializer always (the caller's
`materialize_out` or a fresh one), so a parameter-only array observed is filled
once at setup as in a Problem, and an ODE state that neither the document nor
`initial_conditions` gives a starting value is refused
(`E_TREEWALK_MISSING_INITIAL_VALUE`, esm-spec §11.4). `pushdown_rewrite = true` rewrites the authored
document before it is flattened, as `esm_problem` does; the provider gates
`esm_problem` derives from the rewrite are not applied. `gated_providers`
(provider key => a provider carrying its own [`provider_gate_spec`](@ref)) are
fetched pre-sliced after value invention, at `sample_time`, as `esm_problem`
fetches them.

A `const_arrays` / `param_arrays` key for a name the document reads but does
not declare stays as the document spells it (`"W"`, not `"M.W"`): the
reference-integrity check matches undeclared names against the keys as written.

A build that throws returns no report; run it as
`Internal.counting(() -> try Internal.build(…) catch err; err end)` to read what
it counted before it threw.
"""
function build(
        input; model_name::Union{Nothing, AbstractString} = nothing,
        compiler::Union{Symbol, CompilerPlan} = :native,
        index_sets::Union{Nothing, AbstractDict} = nothing,
        metaparameters::AbstractDict = Dict{String, Int}(),
        base_path::AbstractString = pwd(),
        pushdown_rewrite::Bool = false,
        gated_providers::AbstractDict = Dict{String, Any}(),
        kwargs...
    )
    products = BuildProducts()
    (out, file), counts = EarthSciAST._with_counts() do
        supplied = Set{String}(
            String(k) for name in (:const_arrays, :param_arrays)
                for k in keys(get(kwargs, name, Dict{String, Any}()))
        )
        document = _document(input, model_name, index_sets)
        # The projection-pushdown rewrite reads the authored model, so it runs
        # before flattening, as in `esm_problem`.
        pushdown_rewrite && (
            document = first(
                EarthSciAST._pushdown_input(document, nothing, metaparameters, String(base_path))
            )
        )
        prep = EarthSciAST._prepare_run(
            document; metaparameters = metaparameters, base_path = String(base_path),
            supplied_names = supplied
        )
        prep = EarthSciAST._with_data_shapes(
            prep, get(kwargs, :const_arrays, Dict{String, Any}()),
            get(kwargs, :param_arrays, Dict{String, Any}())
        )
        file = EarthSciAST._run_file(prep)
        gated = Dict{String, EarthSciAST._GatedProvider}(
            String(k) => _gated(String(k), v) for (k, v) in gated_providers
        )
        out = EarthSciAST._problem_build_run(
            file; compiler = compiler, products = products, gated_providers = gated,
            kwargs...
        )
        (out, file)
    end
    f!, u0, p, tspan, var_map = out
    report = BuildReport(
        products.compiler_report, products.compiler_report.tally, counts,
        products.stats, products.kernels, products, file
    )
    return Build(f!, u0, p, (Float64(tspan[1]), Float64(tspan[2])), var_map, report)
end

# A gated provider as the build takes it: described as `esm_problem` describes
# it, which refuses one that carries no gate.
_gated(::String, g::EarthSciAST._GatedProvider) = g
function _gated(key::String, prov)
    gate = EarthSciAST._provider_traits(prov, key).gate
    gate === nothing && throw(
        ArgumentError("Internal.build: gated provider '$key' reports no provider_gate_spec")
    )
    return EarthSciAST._GatedProvider(prov, gate)
end

# The document `build` prepares: a bare `Model` becomes the only model of one.
function _document(input::Model, model_name, index_sets)
    name = model_name === nothing ? "M" : String(model_name)
    sets = OrderedDict{String, IndexSet}(
        String(k) => v for (k, v) in something(index_sets, Dict{String, IndexSet}())
    )
    return EsmFile(
        SCHEMA_VERSION, Metadata(name);
        models = OrderedDict{String, Model}(name => input), index_sets = sets
    )
end
function _document(input, model_name, index_sets)
    model_name === nothing || throw(
        ArgumentError(
            "Internal.build: `model_name` names a bare Model; a document is flattened " *
                "whole, so its names are already qualified"
        )
    )
    index_sets === nothing || throw(
        ArgumentError(
            "Internal.build: `index_sets` is a bare Model's registry; a document " *
                "carries its own"
        )
    )
    return input
end

"""
    Internal.counting(f) -> (value, counts::Dict{Symbol,Int})

Run `f()` and return its value with every engagement count it produced on this
task (see [`Internal.BuildReport`](@ref)`.counts`). For a build step run on its
own (`materialize_value_invention`, a setup-geometry sweep, an `observed_field`
read), or a build that throws.
"""
counting(f) = EarthSciAST._with_counts(f)

end # module Internal
