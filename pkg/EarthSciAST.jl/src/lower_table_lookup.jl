# ===========================================================================
# lower_table_lookup.jl — `table_lookup` → `interp.*` lowering (esm-spec §9.5.3)
# ===========================================================================
#
# A `table_lookup` node is SUGAR. It names a `function_tables` entry plus one
# input expression per declared axis, and §9.5.3 gives the exact §9.2
# closed-function tree it stands for. Nothing that EVALUATES a document speaks
# `table_lookup`: the MTK lowering throws `Unsupported operator`, and the
# tree-walk compiler classes it with the rewrite targets that must be gone by
# build time. Until this pass, the lowering existed only inside the test
# harness (`test/function_tables_lowering_test.jl`) — so a real `.esm` whose
# observed is a `table_lookup` validated, flattened and round-tripped cleanly
# and then failed every inline-test assertion that read it, while the SAME
# lookup written out by hand in the lowered form passed (issue #188).
#
# **This runs at BUILD, not at LOAD, and that is the point.** §9.5.4 makes
# `function_tables` / `table_lookup` first-class AUTHORED constructs that must
# survive a round trip, and `save` re-serializes the typed `EsmFile` that
# `load` produced — so lowering inside `load_path` would emit the lowered `fn`
# form and break §9.5.4. (This is the opposite of [`lower_enums!`](@ref), whose
# §9.3 lowering IS a load-time pass: an `enum` op is not required to survive
# the round trip, and `EsmFile` deliberately never carries one.) §9.5.3 admits
# either an in-memory transformation or a direct evaluator dispatch; lowering
# on the way INTO a build satisfies the first while leaving the loaded image —
# and therefore `emit` — authored as written.
#
# Bit-equivalence with the hand-written inline-`const` lookup (§9.5's central
# promise) comes for free: the lowered tree drives the very same
# `interp.linear` / `interp.bilinear` implementations
# ([`evaluate_closed_function`](@ref), the MTK ext's registered symbolic twins)
# an author would have invoked by hand.
#
# Hooked in at the three places a document enters an evaluator:
#   * `_run_container_tests!`  (run_tests.jl)       — the MTK inline-test engine
#   * `run_inline_tests`        (inline_tests.jl) — the tree-walk engine, and
#     with it the §6.6.5 assertion `reference` expressions it evaluates
#   * `_prepare_run_doc`       (simulate.jl)        — every `esm_problem` build
# ===========================================================================

"""
    TableLookupError <: EarthSciASTError

Raised when the esm-spec §9.5.3 `table_lookup` lowering cannot be performed,
carrying the stable §9.5.5 diagnostic `code` as a structured field rather than
interpolated into the message — the same shape as [`EnumLoweringError`](@ref)
and [`ClosedFunctionError`](@ref).

Codes: `table_lookup_unknown_table`, `table_lookup_axis_name_mismatch`,
`table_lookup_output_out_of_range`, `table_interpolation_axes_mismatch`,
`table_data_shape_mismatch`, `table_axis_nan`, and the §9.5.3a refusal
`table_out_of_bounds_unsupported`.

A build diagnostic, not a load one: the offending document still loads and
still round-trips (§9.5.4) — it simply does not evaluate.
"""
struct TableLookupError <: EarthSciASTError
    code::String
    message::String
end

Base.showerror(io::IO, e::TableLookupError) =
    print(io, "TableLookupError(", e.code, "): ", e.message)

const _TABLE_LOOKUP_OP = "table_lookup"

# A table registry to lower against: the document's `function_tables`, or
# `nothing` for the overwhelmingly common document that declares none.
const _TableRegistry = Union{Nothing,AbstractDict{String,FunctionTable}}

_no_tables(tables::_TableRegistry) = tables === nothing || isempty(tables)

# ---------------------------------------------------------------------------
# Document-level entry points
# ---------------------------------------------------------------------------

"""
    lower_table_lookups(file::EsmFile) -> EsmFile

The PURE form: return a copy of `file` with every `table_lookup` node replaced
by the §9.5.3 `interp.linear` / `interp.bilinear` / `index` tree it stands for,
leaving `file` untouched. [`lower_table_lookups!`](@ref) is the in-place twin
under Julia's `!` convention (API_SPEC §2.2).

A document declaring no `function_tables` is returned AS IS — not copied, not
even walked — so the pass costs nothing on the documents that make up the
corpus.

Every rejection is a [`TableLookupError`](@ref) carrying its §9.5.5 code; see
that type for the vocabulary.
"""
lower_table_lookups(file::EsmFile)::EsmFile =
    _no_tables(file.function_tables) ? file : lower_table_lookups!(deepcopy(file))

"""
    lower_table_lookups!(file::EsmFile) -> EsmFile

Walk every expression tree in `file` and replace each `table_lookup` node with
its esm-spec §9.5.3 form, in place. After this pass runs no `table_lookup`
node survives, so a second run finds nothing to do — which matters, because
the build hooks call it on whatever they are handed and a caller may have
lowered already.

The in-place twin of [`lower_table_lookups`](@ref); returns `file` for
convenience.
"""
function lower_table_lookups!(file::EsmFile)::EsmFile
    tables = file.function_tables
    _no_tables(tables) && return file
    if file.models !== nothing
        for (_, m) in file.models
            lower_table_lookups!(m, tables)
        end
    end
    if file.reaction_systems !== nothing
        for (_, rs) in file.reaction_systems
            lower_table_lookups!(rs, tables)
        end
    end
    for ce in file.coupling
        _lower_coupling_entry_table_lookups!(ce, tables)
    end
    return file
end

"""
    lower_table_lookups!(model::Model, tables) -> Model
    lower_table_lookups!(rs::ReactionSystem, tables) -> ReactionSystem

Lower one component against the DOCUMENT's table registry (`tables`, the
`EsmFile.function_tables` map or `nothing`). The per-component form is what the
inline-test runners call: they compile one container at a time, and a container
with no tests is never built — so it is never lowered, and never refused.
"""
function lower_table_lookups!(model::Model, tables::_TableRegistry)::Model
    _no_tables(tables) && return model
    f(e) = _lower_expr_table_lookups(e, tables)
    # esm 1.0.0: a variable carries no defining expression, so its only
    # expression positions are a parameter update's `when` trigger and its
    # `expression` value form (esm-spec §5.4).
    for (name, var) in model.variables
        nv = _lower_variable_update(var, f)
        nv === var || (model.variables[name] = nv)
    end
    _lower_equations!(model.equations, f)
    _lower_equations!(model.initialization_equations, f)
    for (name, guess) in model.guesses
        guess isa ASTExpr && (model.guesses[name] = f(guess))
    end
    _lower_events!(model.continuous_events, f)
    _lower_events!(model.discrete_events, f)
    _lower_test_references!(model.tests, f)
    for (_, sub) in model.subsystems
        # An unresolved SubsystemRef carries no expressions to lower.
        sub isa Model || continue
        lower_table_lookups!(sub, tables)
    end
    return model
end

function lower_table_lookups!(rs::ReactionSystem, tables::_TableRegistry)::ReactionSystem
    _no_tables(tables) && return rs
    f(e) = _lower_expr_table_lookups(e, tables)
    for (i, r) in enumerate(rs.reactions)
        rate = f(r.rate)
        rate === r.rate && continue
        # `raw_substrates` / `raw_products`: the ordered StoichiometryEntry
        # fields, not the unordered `Dict` views.
        rs.reactions[i] = Reaction(r.id, raw_substrates(r), raw_products(r), rate;
                                   name=r.name, reference=r.reference)
    end
    for (_, sub) in rs.subsystems
        lower_table_lookups!(sub, tables)
    end
    return rs
end

"""
    lower_table_lookups(flat::FlattenedSystem) -> FlattenedSystem

The flattened-form entry point: the ONE hook the tree-walk build needs, because
`_prepare_run_doc` funnels a path, a native `Dict`, an `EsmFile` AND an
already-flattened system through the same `FlattenedSystem` stage. `flatten`
carries `function_tables` through untouched precisely so a flattened system
stays runnable, and lowering here (rather than pre-`flatten`) is what makes the
hook cover a caller who flattened for themselves.

Returns `flat` unchanged when the system declares no tables. The expression
rewrite is identity-preserving, so a rebuilt system shares every subtree the
rewrite did not touch (and with it the build's `IdDict` memo hits).
"""
function lower_table_lookups(flat::FlattenedSystem)::FlattenedSystem
    tables = flat.function_tables
    _no_tables(tables) && return flat
    f(e) = _lower_expr_table_lookups(e, tables)
    eqs = _lower_equations!(copy(flat.equations), f)
    cev = _lower_events!(copy(flat.continuous_events), f)
    dev = _lower_events!(copy(flat.discrete_events), f)
    ics = Pair{String,ASTExpr}[name => f(rhs) for (name, rhs) in flat.field_ics]
    states = _lower_variable_updates(flat.state_variables, f)
    params = _lower_variable_updates(flat.parameters, f)
    observed = _lower_variable_updates(flat.observed_variables, f)
    # The §6.3.1 subset maps hold the SAME `ModelVariable` objects as the maps
    # above, so a rewritten update has to be re-linked into them by name — a
    # subset still holding the pre-lowering object would make the flattened form
    # disagree with itself about that variable.
    relink(subset, parent) = OrderedDict{String,ModelVariable}(
        k => get(parent, k, v) for (k, v) in subset)
    return FlattenedSystem(flat;
        state_variables=states, parameters=params, observed_variables=observed,
        equations=eqs, continuous_events=cev, discrete_events=dev, field_ics=ics,
        algebraic_variables=relink(flat.algebraic_variables, states),
        brownian_parameters=relink(flat.brownian_parameters, params),
        discrete_parameters=relink(flat.discrete_parameters, params))
end

# ---------------------------------------------------------------------------
# The expression positions, shared by the typed and the flattened entry points
# ---------------------------------------------------------------------------

function _lower_equations!(eqs::Vector{Equation}, f)::Vector{Equation}
    for (i, eq) in enumerate(eqs)
        lhs = f(eq.lhs)
        rhs = f(eq.rhs)
        (lhs === eq.lhs && rhs === eq.rhs) && continue
        eqs[i] = Equation(lhs, rhs; _comment=eq._comment)
    end
    return eqs
end

_lower_affects(affects::Vector{AffectEquation}, f) =
    AffectEquation[AffectEquation(a.lhs, f(a.rhs)) for a in affects]

function _lower_events!(events::Vector{ContinuousEvent}, f)::Vector{ContinuousEvent}
    for (i, ev) in enumerate(events)
        events[i] = ContinuousEvent(ASTExpr[f(c) for c in ev.conditions],
            _lower_affects(ev.affects, f);
            affect_neg=(ev.affect_neg === nothing ? nothing :
                        _lower_affects(ev.affect_neg, f)),
            root_find=ev.root_find, reinitialize=ev.reinitialize,
            description=ev.description, name=ev.name)
    end
    return events
end

function _lower_events!(events::Vector{DiscreteEvent}, f)::Vector{DiscreteEvent}
    for (i, ev) in enumerate(events)
        # Only a `ConditionTrigger` carries an expression; a periodic / times
        # trigger is pure data.
        trigger = ev.trigger isa ConditionTrigger ?
            ConditionTrigger(f(ev.trigger.expression)) : ev.trigger
        events[i] = DiscreteEvent(trigger, _lower_affects(ev.affects, f);
            reinitialize=ev.reinitialize, description=ev.description, name=ev.name)
    end
    return events
end

# esm-spec §6.6.5: an error-norm assertion's `reference` is an EXPRESSION the
# runner evaluates cellwise (`run_inline_tests` → `evaluate_cellwise`), so it is an
# evaluated position like any other. A `{type: "from_file"}` reference is a data
# descriptor and is left alone.
function _lower_test_references!(tests::Vector{InlineTest}, f)::Vector{InlineTest}
    for t in tests
        for (i, a) in enumerate(t.assertions)
            a.reference isa ASTExpr || continue
            ref = f(a.reference)
            ref === a.reference && continue
            t.assertions[i] = Assertion(a.variable, a.time, a.expected;
                tolerance=a.tolerance, coords=a.coords, reduce=a.reduce,
                reference=ref)
        end
    end
    return tests
end

# One variable's §5.4 update rules, rewritten through `f`. Returns `var` itself
# when it declares no update or nothing changed.
function _lower_variable_update(var::ModelVariable, f)::ModelVariable
    var.update === nothing && return var
    rules = ParameterUpdate[]
    changed = false
    for r in var.update
        nw = r.when === nothing ? nothing : f(r.when)
        ne = r.expression === nothing ? nothing : f(r.expression)
        (nw !== r.when || ne !== r.expression) && (changed = true)
        push!(rules, ParameterUpdate(r.kind; times=r.times, interval=r.interval,
            initial_offset=r.initial_offset, when=nw, direction=r.direction,
            source=r.source, hook=r.hook, expression=ne, from=r.from,
            handler=r.handler))
    end
    return changed ? reconstruct(var; update=rules) : var
end

# The map form: a NEW map only when some variable's update actually changed, so
# an unaffected `FlattenedSystem` keeps sharing its variable maps.
function _lower_variable_updates(vars::OrderedDict{String,ModelVariable}, f)
    lowered = nothing
    for (name, var) in vars
        nv = _lower_variable_update(var, f)
        nv === var && continue
        lowered === nothing && (lowered = OrderedDict{String,ModelVariable}(vars))
        lowered[name] = nv
    end
    return lowered === nothing ? vars : lowered
end

# A `coupling` entry's connector equations (esm-spec §10) are raw JSON carrying
# typed `ASTExpr` values — the same shape `_lower_coupling_entry_enums!` walks.
function _lower_coupling_entry_table_lookups!(ce::CouplingEntry, tables::_TableRegistry)
    (ce isa CouplingCouple && haskey(ce.connector, "equations")) || return ce
    eqs = ce.connector["equations"]
    eqs isa AbstractVector || return ce
    for e in eqs
        (e isa AbstractDict && haskey(e, "expression")) || continue
        expr_obj = e["expression"]
        expr_obj isa ASTExpr || continue
        e["expression"] = _lower_expr_table_lookups(expr_obj, tables)
    end
    return ce
end

# ---------------------------------------------------------------------------
# The expression rewrite
# ---------------------------------------------------------------------------

_lower_expr_table_lookups(e::ASTExpr, ::_TableRegistry) = e

# Identity-memoized entry: the lowering is a pure, context-free function of the
# node, so a subtree shared under many parents (template expansion stores the
# expanded AST as a shared DAG) is lowered ONCE and the shared result respliced
# — keeping the pass linear in UNIQUE nodes instead of exponential in paths,
# exactly as the enum lowering does.
_lower_expr_table_lookups(e::OpExpr, tables::_TableRegistry) =
    _lower_expr_table_lookups(e, tables, IdDict{OpExpr,ASTExpr}())

_lower_expr_table_lookups(e::ASTExpr, ::_TableRegistry, ::IdDict{OpExpr,ASTExpr}) = e

function _lower_expr_table_lookups(e::OpExpr, tables::_TableRegistry,
                                   memo::IdDict{OpExpr,ASTExpr})::ASTExpr
    r = get(memo, e, nothing)
    r === nothing || return r
    # BOTTOM-UP: children first (through the one field-preserving rewrite
    # primitive, which reaches `table_axes` like every other expression-bearing
    # field), so a `table_lookup` nested inside another node's axis input is
    # already an `interp.*` tree by the time its parent is rewritten.
    # `map_children` returns `e` itself when nothing changed, so a lookup-free
    # tree is never rebuilt.
    lowered = map_children(x -> _lower_expr_table_lookups(x, tables, memo), e)
    res = lowered isa OpExpr && lowered.op == _TABLE_LOOKUP_OP ?
        _lower_table_lookup_node(lowered, tables) : lowered
    memo[e] = res
    return res
end

# The §9.5.3 lowering of ONE `table_lookup` node.
function _lower_table_lookup_node(node::OpExpr,
                                  tables::AbstractDict{String,FunctionTable})::ASTExpr
    table_id = node.table
    table_id === nothing && throw(TableLookupError(
        ERROR_CODES.TABLE_LOOKUP_UNKNOWN_TABLE,
        "a `table_lookup` node carries no `table` id (esm-spec §9.5.2)"))
    haskey(tables, table_id) || throw(TableLookupError(
        ERROR_CODES.TABLE_LOOKUP_UNKNOWN_TABLE,
        "`table_lookup` references table `$(table_id)`, which the document's " *
        "`function_tables` block does not declare"))
    table = tables[table_id]
    # esm-spec §9.5.3a. Raised HERE — at the point the node would otherwise
    # lower — so the document still loads and still round-trips; what it does
    # not do is evaluate in a mode its author did not ask for.
    table.out_of_bounds == "error" && throw(TableLookupError(
        ERROR_CODES.TABLE_OUT_OF_BOUNDS_UNSUPPORTED,
        "table `$(table_id)` declares `out_of_bounds: \"error\"`; this binding " *
        "implements only the required `\"clamp\"` mode (esm-spec §9.5.1), so the " *
        "lookup is refused rather than answered with clamping semantics"))

    inputs = _table_axis_inputs(node, table, table_id)
    slice = _table_output_slice(table, _table_output_index(node, table, table_id),
                                table_id)
    kind = something(table.interpolation, "linear")
    if kind == "linear" && length(table.axes) == 1
        return OpExpr("fn", ASTExpr[_table_const(slice),
                                    _table_axis_const(table.axes[1], table_id),
                                    inputs[1]]; name="interp.linear")
    elseif kind == "bilinear" && length(table.axes) == 2
        return OpExpr("fn", ASTExpr[_table_const(slice),
                                    _table_axis_const(table.axes[1], table_id),
                                    _table_axis_const(table.axes[2], table_id),
                                    inputs[1], inputs[2]]; name="interp.bilinear")
    elseif kind == "nearest" && length(table.axes) == 1
        # `nearest` is an `index` of the table slice at the searchsorted
        # position, not an `interp` blend.
        return OpExpr("index", ASTExpr[_table_const(slice),
            OpExpr("fn", ASTExpr[inputs[1],
                                 _table_axis_const(table.axes[1], table_id)];
                   name="interp.searchsorted")])
    end
    throw(TableLookupError(ERROR_CODES.TABLE_INTERPOLATION_AXES_MISMATCH,
        "table `$(table_id)` declares `interpolation: \"$(kind)\"` over " *
        "$(length(table.axes)) axes; `linear` and `nearest` require 1, `bilinear` " *
        "requires 2 (esm-spec §9.5.1)"))
end

# The node's per-axis input expressions, in the table's DECLARED axis order —
# which is the order of `data`'s inner dimensions, and therefore the argument
# order of `interp.bilinear`.
function _table_axis_inputs(node::OpExpr, table::FunctionTable,
                            table_id::String)::Vector{ASTExpr}
    isempty(node.args) || throw(TableLookupError(
        ERROR_CODES.TABLE_LOOKUP_AXIS_NAME_MISMATCH,
        "`table_lookup` on table `$(table_id)` carries $(length(node.args)) positional " *
        "`args`; the per-axis inputs live under `axes` and `args` MUST be empty " *
        "(esm-spec §9.5.2)"))
    axes = node.table_axes
    supplied = axes === nothing ? 0 : length(axes)
    out = Vector{ASTExpr}(undef, length(table.axes))
    for (i, axis) in enumerate(table.axes)
        input = axes === nothing ? nothing : get(axes, axis.name, nothing)
        input === nothing && throw(TableLookupError(
            ERROR_CODES.TABLE_LOOKUP_AXIS_NAME_MISMATCH,
            "`table_lookup` on table `$(table_id)` supplies no input for its declared " *
            "axis `$(axis.name)`"))
        out[i] = input
    end
    supplied == length(table.axes) || throw(TableLookupError(
        ERROR_CODES.TABLE_LOOKUP_AXIS_NAME_MISMATCH,
        "`table_lookup` on table `$(table_id)` supplies $(supplied) axis inputs but " *
        "the table declares $(length(table.axes)) " *
        "($(join((ax.name for ax in table.axes), ", "))); the key sets must match " *
        "exactly (esm-spec §9.5.2)"))
    return out
end

# Resolve `output` (absent, 0-based integer index, or output name) to a 1-based
# row index into `data`'s leading dimension.
function _table_output_index(node::OpExpr, table::FunctionTable,
                             table_id::String)::Int
    out = node.output
    outputs = table.outputs
    out === nothing && return 1
    # `!(out isa Bool)`: `Bool <: Integer` in Julia, so a JSON `true` would
    # otherwise select output 1 rather than being refused. The other four
    # bindings reject a boolean selector; §9.5.2 admits an integer or an
    # output NAME and nothing else.
    if out isa Integer && !(out isa Bool)
        idx = Int(out)
        if outputs !== nothing
            0 <= idx < length(outputs) || throw(TableLookupError(
                ERROR_CODES.TABLE_LOOKUP_OUTPUT_OUT_OF_RANGE,
                "`table_lookup.output` $(idx) on table `$(table_id)` is out of range: " *
                "the table declares $(length(outputs)) outputs"))
            return idx + 1
        end
        # No `outputs` list means the table is single-output and `data` has no
        # leading output dimension at all (§9.5.1), so 0 is the only index that
        # names anything.
        idx == 0 && return 1
        throw(TableLookupError(ERROR_CODES.TABLE_LOOKUP_OUTPUT_OUT_OF_RANGE,
            "`table_lookup.output` $(idx) on table `$(table_id)`, which declares no " *
            "`outputs` and is therefore single-output"))
    elseif out isa AbstractString
        outputs === nothing && throw(TableLookupError(
            ERROR_CODES.TABLE_LOOKUP_OUTPUT_OUT_OF_RANGE,
            "`table_lookup.output` \"$(out)\" names an output, but table `$(table_id)` " *
            "declares no `outputs` list"))
        idx = findfirst(==(String(out)), outputs)
        idx === nothing && throw(TableLookupError(
            ERROR_CODES.TABLE_LOOKUP_OUTPUT_OUT_OF_RANGE,
            "`table_lookup.output` \"$(out)\" is not one of table `$(table_id)`'s " *
            "outputs ($(join(outputs, ", ")))"))
        return idx
    end
    throw(TableLookupError(ERROR_CODES.TABLE_LOOKUP_OUTPUT_OUT_OF_RANGE,
        "`table_lookup.output` on table `$(table_id)` must be a non-negative integer " *
        "or an output name, not a $(typeof(out))"))
end

# The `data` sub-array the lowered `const` carries: row `output` of the leading
# dimension for a multi-output table, and the whole literal for a single-output
# one (which has no leading output dimension, §9.5.1).
function _table_output_slice(table::FunctionTable, output::Int, table_id::String)
    table.outputs === nothing && return table.data
    (table.data isa AbstractVector && output <= length(table.data)) ||
        throw(TableLookupError(ERROR_CODES.TABLE_DATA_SHAPE_MISMATCH,
            "table `$(table_id)`: `data` has no row $(output - 1) for the selected " *
            "output — its leading dimension must equal `len(outputs)` (esm-spec §9.5.1)"))
    return table.data[output]
end

# `{"op": "const", "value": <data slice>}`. The value is materialized as the
# concrete `Vector{Float64}` / `Vector{Vector{Float64}}` the `interp.*`
# implementations take, so the lowered call is byte-identical to the
# hand-written inline-`const` one an author would have spelled (§9.5's
# bit-equivalence promise) rather than a `Vector{Any}` of JSON leftovers.
_table_const(slice) = OpExpr("const", ASTExpr[]; value=_table_data_value(slice))

function _table_data_value(slice)
    slice isa AbstractVector || throw(TableLookupError(
        ERROR_CODES.TABLE_DATA_SHAPE_MISMATCH,
        "a function table's `data` slice must be a nested array of finite numbers, " *
        "got a $(typeof(slice)) (esm-spec §9.5.1)"))
    all(x -> x isa Real, slice) && return Float64[Float64(x) for x in slice]
    return Vector{Float64}[_table_data_value(row) for row in slice]
end

function _table_axis_const(axis::FunctionTableAxis, table_id::String)::ASTExpr
    all(isfinite, axis.values) || throw(TableLookupError(ERROR_CODES.TABLE_AXIS_NAN,
        "table `$(table_id)`: axis `$(axis.name)` carries a non-finite value; axis " *
        "`values` must be strictly-increasing FINITE floats (esm-spec §9.5.1)"))
    return OpExpr("const", ASTExpr[]; value=copy(axis.values))
end
