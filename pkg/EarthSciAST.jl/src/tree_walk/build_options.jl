# tree_walk/build_options.jl — what one build of a document is asked for.

"""
    BuildOptions(; compiler, form, initial_conditions, parameter_overrides, …)

What one document build is asked for (internal), spelled once: the caller's
options, the build's sinks, and what the front door's pre-passes add
(`_front_door`). Constructed from the keywords of a document build entry
(`_build_run`, `_build_evaluator(::EsmFile)`), so a misspelled keyword is
refused there, before any pre-pass runs. A field left `nothing` is not passed
on, and the build takes its own default.

The caller's options:

* `compiler` — a vocabulary `Symbol` or a `CompilerPlan`; `form` — `:inplace`
  or `:oop` (tree_walk/oop.jl);
* `initial_conditions`, `parameter_overrides`, `tspan`;
* `const_arrays` (frozen data), `param_arrays` (live forcing buffers, bound by
  reference), `const_array_boundaries` (per-array out-of-range policy);
* `runtime_array_parameters` — a shaped parameter whose value the document
  supplies becomes a live buffer (`esm_problem(…; runtime_array_parameters)`);
  `live_fed_parameters` — every externally fed parameter does (a program
  build, src/rhs_program.jl);
* `ic_t0`, `ic_data` — the start of the run and the data-fed values there,
  which the `ic` right-hand sides read (esm-spec §11.4.2);
* `caller_u0` — the caller's initial state (`esm_problem`'s `u0`), which an
  initialization equation reads and a cell it names keeps.

The sinks: `products` (`BuildProducts`), `materialize_out`
(`DiscreteMaterializer`), `param_classes` (name → parameter class).

The front door's products: `param_reads` (the build-time parameter-read set),
`expand_cache` (`_ExpandCache`), and the value-invention result
(`vi_extents`, `vi_vars`, `vi_maps`).
"""
Base.@kwdef mutable struct BuildOptions
    compiler::Union{Symbol, CompilerPlan} = :native
    form::Symbol = :inplace
    initial_conditions::Union{Nothing, AbstractDict} = nothing
    parameter_overrides::Union{Nothing, AbstractDict} = nothing
    tspan::Union{Nothing, Tuple{Real, Real}} = nothing
    const_arrays::Union{Nothing, AbstractDict} = nothing
    param_arrays::Union{Nothing, AbstractDict} = nothing
    const_array_boundaries::Union{Nothing, AbstractDict} = nothing
    runtime_array_parameters::Bool = false
    live_fed_parameters::Bool = false
    ic_t0::Union{Nothing, Real} = nothing
    ic_data::Union{Nothing, AbstractDict} = nothing
    caller_u0::Any = nothing
    products::Union{Nothing, BuildProducts} = nothing
    materialize_out::Union{Nothing, DiscreteMaterializer} = nothing
    param_classes::Union{Nothing, AbstractDict} = nothing
    param_reads::Union{Nothing, Set{String}} = nothing
    expand_cache::Any = nothing
    vi_extents::Union{Nothing, AbstractDict} = nothing
    vi_vars::Union{Nothing, AbstractSet} = nothing
    vi_maps::Any = nothing
end

Base.copy(o::BuildOptions) = BuildOptions((getfield(o, f) for f in fieldnames(BuildOptions))...)

# Each optional field and the keyword of `_build_evaluator_impl` that takes it.
const _BUILD_KEYWORDS = (
    initial_conditions = :initial_conditions,
    parameter_overrides = :parameter_overrides,
    tspan = :tspan,
    const_arrays = :const_arrays,
    param_arrays = :param_arrays,
    const_array_boundaries = :const_array_boundaries,
    ic_t0 = :_ic_t0,
    ic_data = :_ic_data,
    caller_u0 = :_caller_u0,
    products = :products,
    materialize_out = :materialize_out,
    param_classes = :_param_classes,
    param_reads = :_param_reads,
    expand_cache = :_expand_cache,
    vi_extents = :_vi_extents,
    vi_vars = :_vi_vars,
    vi_maps = :_vi_maps,
)

# `o` as the keywords of `_build_evaluator_impl`.
function _build_kwargs(o::BuildOptions)
    kw = Pair{Symbol, Any}[
        :compiler => o.compiler, :form => o.form,
        :_runtime_array_parameters => o.runtime_array_parameters,
        :_live_fed_parameters => o.live_fed_parameters,
    ]
    for (f, k) in pairs(_BUILD_KEYWORDS)
        v = getfield(o, f)
        v === nothing || push!(kw, k => v)
    end
    return (; kw...)
end

# The options of a re-lowering of a recorded build (a range-restricted program,
# src/range/): every registry and read set a build may extend copied, so one
# build never sees another's additions, and no sink and no caller state. A
# re-lowering may run on any thread, and writes into none of the recorded
# build's sinks.
function _relower_options(o::BuildOptions)
    r = copy(o)
    o.const_arrays === nothing || (r.const_arrays = copy(o.const_arrays))
    o.param_arrays === nothing || (r.param_arrays = copy(o.param_arrays))
    o.param_reads === nothing || (r.param_reads = copy(o.param_reads))
    r.materialize_out = nothing
    r.products = nothing
    r.param_classes = nothing
    r.expand_cache = nothing     # the recorded build owns it
    r.caller_u0 = nothing
    return r
end
