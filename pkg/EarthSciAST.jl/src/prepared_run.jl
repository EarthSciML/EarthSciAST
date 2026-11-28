# The prepared run: what every route that builds a document — `esm_problem`
# under every compiler, `Internal.build`, `rhs_program`, `strip` — starts from.
#
# A path, a native `Dict`, an `EsmFile` or a `FlattenedSystem` is loaded, checked
# by the document-level refusals and flattened ONCE, here (`_prepare_run`). The
# result is a typed `PreparedRun`; the build reads a typed single-model
# `EsmFile` made from it (`_run_file`), never a JSON document.
#
# A `Dict` is loaded, not coerced: the build runs ONE model (`_select_model`)
# and never reads `reaction_systems` or `coupling`, which `flatten` lowers and
# applies, so an authored `Dict` handed to the build directly would run a single
# model with its reaction network and every coupling edge dropped. Loading gives
# it the schema validation, version gates and `{ref}` resolution a path has —
# the last mattering because `flatten` skips an unresolved `SubsystemRef`. Every
# name a run sees is therefore the flattener's qualified one (`"M.y"`).
# `base_path` anchors a `Dict`'s relative refs; a path anchors them at its own
# directory.

"""
    PreparedRun

A document prepared for one run: the flattened system and the document-scoped
blocks `flatten` does not carry.

* `flat` — the flattened system: table-lowered, its namespaced initialization
  equations on it, before the tree-walk shape transforms (`_run_file` applies
  those). Its per-term provenance (`equation_contributions`) is what
  [`rhs_program`](@ref) selects operators from.
* `coordinates` — the document's `coordinates` registry (streaming-output RFC
  §8.3), or `nothing`.
* `solver` — the document's `solver` block (esm-spec §2.2), or `nothing`.
* `coupling_reads` — the names a `variable_map` coupling reads (its `from`
  endpoints), which flatten resolves away: a provider keyed by one keeps its
  own name (`_routable_keys`).
* `file` — the loaded document `flat` was flattened from (`nothing` for a
  `FlattenedSystem` input), which a compiler's file-level refusals read when
  the run is reused (`_prepare_run(::PreparedRun)`).
"""
struct PreparedRun
    flat::FlattenedSystem
    coordinates::Union{Nothing, Dict{String, Any}}
    solver::Union{Nothing, Solver}
    coupling_reads::Set{String}
    file::Union{Nothing, EsmFile}
end

PreparedRun(flat::FlattenedSystem) = PreparedRun(flat, nothing, nothing, Set{String}(), nothing)

# `prep` with its flattened system replaced.
_with_flat(prep::PreparedRun, flat::FlattenedSystem) =
    PreparedRun(flat, prep.coordinates, prep.solver, prep.coupling_reads, prep.file)

# The states an `operator_compose` renaming match DELETED, mapped onto the
# survivors they were folded into (esm-libraries-spec §4.7.1 step 4).
_merged_renames(prep::PreparedRun) = prep.flat.metadata.merged_variable_renames

# The initialization equations of a flattened system that are not explicit
# initial conditions (esm-spec §11.4.3): the initialization system the build
# classifies, balances and solves (tree_walk/build_ic_system.jl).
_initialization_system(flat::FlattenedSystem) = flat.initialization_equations

# The refusals of a construct the tree-walk build does not run (esm-spec
# §9.6.6): an event, a Wiener-noise parameter, a parameter recomputed by its own
# update rule. A compiler that runs some of them (`:mtk`) applies its own.
function _refuse_tree_walk_constructs(flat::FlattenedSystem)
    _refuse_flat_events(flat)
    _refuse_flat_wiener_noise(flat)
    _refuse_flat_symbolic_updates(flat)
    return nothing
end

# The tree-walk build's file-level refusal: a coupling-level event, unless the
# caller stripped its class (`esm_problem(…; strip)`).
_refuse_tree_walk_file(file::EsmFile, strip_taken) = _refuse_coupling_events(file, strip_taken)

"""
    _prepare_run(input; metaparameters, base_path, supplied_names, strip_taken,
                 refuse_file, refuse_flat) -> PreparedRun

Load `input` (a path, a native `Dict`, an `EsmFile` or a `FlattenedSystem`),
apply the document-level refusals, and flatten it. A `PreparedRun` input (one
document prepared once for several runs, as `run_inline_tests` does) is not
loaded or flattened again: only the compiler's own refusals (`refuse_file`,
`refuse_flat`) run on it, and `metaparameters`, `base_path` and
`supplied_names` must be the ones it was prepared with.

`supplied_names` are the bare names the caller binds at construction (a
`const_arrays`, `param_arrays` or `providers` key), which the
reference-integrity refusal treats as declared. `strip_taken` are the construct
classes `strip` removed. `refuse_file(file, strip_taken)` and
`refuse_flat(flat)` are the compiler's own refusals of what it does not run;
the defaults are the tree-walk build's.
"""
function _prepare_run(
        input; metaparameters::AbstractDict = Dict{String, Int}(),
        base_path::AbstractString = pwd(),
        supplied_names = (),
        strip_taken = String[],
        refuse_file = _refuse_tree_walk_file,
        refuse_flat = _refuse_tree_walk_constructs
    )::PreparedRun
    if input isa AbstractString
        input = _load_run_path(String(input), metaparameters)
    elseif input isa AbstractDict
        input = load_document(input; base_path = base_path, metaparameters = metaparameters)
    end
    if input isa EsmFile
        _refuse_unsupported_major_version(input.esm)
        _refuse_reserved_declaration_names(input)
        _refuse_unregistered_callback_reads(input)
        _refuse_reference_integrity_errors(input; supplied_names = supplied_names)
        refuse_file(input, strip_taken)
        _refuse_reserved_liftings(input)
        coupling_reads = Set{String}(
            c.from for c in input.coupling if c isa CouplingVariableMap
        )
        flat = flatten(input)
        prep = PreparedRun(flat, input.coordinates, input.solver, coupling_reads, input)
    elseif input isa PreparedRun
        prep = input
        prep.file === nothing || refuse_file(prep.file, strip_taken)
    elseif input isa FlattenedSystem
        prep = PreparedRun(input)
    else
        throw(
            SimulateError(
                "esm_problem: unsupported input of type $(typeof(input)); " *
                    "pass a path, EsmFile, FlattenedSystem, or native ESM Dict",
                ERROR_CODES.INVALID_ARGUMENT
            )
        )
    end
    _refuse_reserved_liftings(prep.flat)
    refuse_flat(prep.flat)
    return prep
end

# A path loaded for a run, with the run's metaparameters.
function _load_run_path(path::String, metaparameters)
    isfile(path) || throw(SimulateError("esm_problem: no such file '$path'", ERROR_CODES.INVALID_ARGUMENT))
    return load_path(path; metaparameters = metaparameters)
end

# The name of the one model of a run file.
const _RUN_MODEL = "Flattened"

"""
    _run_file(prep::PreparedRun; flat = prep.flat, init, shape_transforms = true) -> EsmFile

The single-model typed document the build compiles: `flat` (by default the
prepared system; `rhs_program` passes a selection of it) as one model named
`"Flattened"`, with the document-scoped index sets, domain, `coordinates` and
`solver`, and `init` (by default the initialization system,
`flat.initialization_equations`) as the model's initialization equations.

With `shape_transforms`, a feed-forward algebraic chain authored as scalars is
first lifted into the grid shape it inherits from the fields it reads
(`algebraic_states_to_observeds`, `promote_downstream_shapes`), so a scalar
observed over a build-once spatial field becomes a per-cell array whose operand
references lower to gathers. Both are no-ops for a document with nothing to
lift. A compiler that does that work itself (`:mtk`) passes `false`.
"""
function _run_file(
        prep::PreparedRun; flat::FlattenedSystem = prep.flat,
        init::Vector{Equation} = _initialization_system(flat),
        shape_transforms::Bool = true
    )::EsmFile
    shape_transforms && (flat = promote_downstream_shapes(algebraic_states_to_observeds(flat)))
    return _flat_file(flat, prep.coordinates, prep.solver, init)
end

function _flat_file(
        flat::FlattenedSystem, coordinates, solver, init::Vector{Equation};
        name::String = _RUN_MODEL
    )
    # `state_variables` and `observed_variables` are not disjoint (a materialized
    # arrayed observed is filed in both, esm-libraries-spec §4.7.5 step 4) but
    # hold the same `ModelVariable` for such a name.
    variables = OrderedDict{String, ModelVariable}()
    for part in (flat.state_variables, flat.parameters, flat.observed_variables)
        merge!(variables, part)
    end
    # A field initial condition is not an equation of motion, so flatten files it
    # apart from `equations` (esm-libraries-spec §4.7.5 step 4). The build reads
    # it as the `ic(state) ~ rhs` equation a document spells it as (esm-spec
    # §11.4.1, `_split_ic_equations`).
    equations = copy(flat.equations)
    for (state, rhs) in flat.field_ics
        push!(equations, Equation(OpExpr("ic", ASTExpr[VarExpr(state)]), rhs))
    end
    guesses = Dict{String, Union{Float64, ASTExpr}}(
        k => (g isa Real ? Float64(g) : g) for (k, g) in flat.guesses if g isa Union{Real, ASTExpr}
    )
    model = Model(variables, equations; initialization_equations = copy(init), guesses = guesses)
    map_expressions!(_integer_literals_mapper(), model)
    # esm-spec §9.6.4 Option B: surviving `apply_expression_template` references
    # resolve against the merged registry, which the build expands with site
    # recording.
    templates = isempty(flat.template_registry) ? nothing :
        OrderedDict{String, Any}(
            "models.$name" => _to_native_json(
                OrderedDict{String, Any}(String(k) => v for (k, v) in flat.template_registry)
            )
        )
    return EsmFile(
        SCHEMA_VERSION, Metadata(name);
        models = OrderedDict{String, Model}(name => model),
        index_sets = OrderedDict{String, IndexSet}(flat.index_sets),
        domain = flat.domain, component_templates = templates,
        coordinates = (coordinates === nothing || isempty(coordinates)) ? nothing : coordinates,
        solver = solver
    )
end

# A literal holding an integral, Int64-representable binary64 value is the
# integer literal a document spells it as (CONFORMANCE_SPEC §5.5.3.1 rule 1), as
# every loaded expression already is. Flatten builds some literals in memory (a
# unit factor, a lifted constant); this makes them the literals a reload of the
# flattened document would hold. A negative zero keeps its sign.
function _integer_literals_mapper()
    seen = IdDict{ASTExpr, ASTExpr}()
    function f(e::ASTExpr)
        e isa NumExpr && return _integer_literal(e)
        (e isa OpExpr) || return e
        return get!(() -> map_children(f, e), seen, e)
    end
    return f
end

function _integer_literal(e::NumExpr)::ASTExpr
    (iszero(e.value) && signbit(e.value)) && return e
    i = _as_int64(e.value)
    return i === nothing ? e : IntExpr(i)
end

# `prep` with its flattened system's unshaped data-fed parameters given their
# data's shape (`_adopt_data_shapes`); `prep` itself when none adopts one.
function _with_data_shapes(prep::PreparedRun, registries...)
    flat = _adopt_data_shapes(prep.flat, registries...)
    return flat === prep.flat ? prep : _with_flat(prep, flat)
end

"""
    _build_run(file::EsmFile; compiler, gated_providers = nothing, sample_time = 0.0, kwargs...)

Build a run file (`_run_file`): the build's pre-passes (`_front_door`), then the
gated providers' slabs fetched pre-sliced to the value-invention members the
pre-passes produced, then the build. `kwargs` are the build's.

A gated provider (one reporting a `provider_gate_spec`, or one the pushdown
rewrite's record gates) is not sampled whole by `esm_problem`: its selection
is the members of a derived index set, which exist only once value invention
has run. Its slab joins the const arrays under the model variable names its
gate's `applies_to` lists.
"""
function _build_run(
        file::EsmFile; compiler::Union{Symbol, CompilerPlan} = :native,
        gated_providers = nothing, sample_time::Real = 0.0,
        model_name::Union{Nothing, AbstractString} = nothing, kwargs...
    )
    _xla_check_form(
        compiler isa Symbol ? compiler : compiler.name, get(kwargs, :form, :inplace)
    )
    return _with_compiler_plan(_plan_for(compiler)) do
        front = _front_door(file, model_name; compiler = compiler, kwargs...)
        if gated_providers !== nothing && !isempty(gated_providers)
            _merge_front_const_arrays!(
                front, _fetch_gated_providers(
                    gated_providers, file.index_sets, front.vi,
                    Float64(sample_time), front.model
                )
            )
        end
        _build_front(front)
    end
end
