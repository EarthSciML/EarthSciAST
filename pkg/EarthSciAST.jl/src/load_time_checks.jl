# ===========================================================================
# load_time_checks.jl — closed-function argument and function-table checks at
# load and in `validate()` (esm-spec §9.2 "When the argument checks run",
# §9.5.5 "When the table checks run"; rulings Q-106..Q-113)
# ===========================================================================
#
# Three families of checks the spec makes LOAD diagnostics:
#
#   * the ten §9.5.5 checks on EVERY `function_tables` entry, whether or not a
#     `table_lookup` references it (`_validate_function_table`,
#     lower_table_lookup.jl);
#   * the §9.2 argument checks — arity first (ruling Q-112) — on EVERY `fn` node
#     naming `interp.searchsorted`, `interp.linear` or `interp.bilinear`,
#     wherever it sits in the document, whether or not anything ever evaluates
#     it;
#   * the §9.5.5 checks of EVERY `table_lookup` node (ruling Q-112:
#     `_check_table_lookup_node`, lower_table_lookup.jl).
#
# Every table is checked before any expression node (ruling Q-113).
#
# Both reuse the validators the build already runs (the tree-walk const-arg
# protocol `_FN_CONST_ARG_SPECS` / `_const_array_arg` and the `_build_interp_*`
# spec builders), so load, `validate()` and the build name the same code for the
# same argument. The build keeps its own copy of the checks: a document built in
# memory never passes through load.
#
# A load failure throws the first finding — tables first, in document order,
# then the expressions — as the `TableLookupError` / `ClosedFunctionError` the
# build would have raised. `validate()` reports every finding as a structural
# error carrying the same code.
# ===========================================================================

const _INTERP_FN_NAMES = ("interp.searchsorted", "interp.linear", "interp.bilinear")

# One finding: the JSON pointer of the table or expression field, and the error.
const _LoadCheckFinding = Tuple{String,Union{ClosedFunctionError,TableLookupError}}

"""
    _check_function_tables(tables, findings; first_only) -> findings

Run the ten esm-spec §9.5.5 checks on every entry of `tables`, in document
order, pushing `("/function_tables/<id>", err)` for each table that fails one.
"""
function _check_function_tables(tables, findings::Vector{_LoadCheckFinding};
                                first_only::Bool=false)
    tables === nothing && return findings
    for (id, table) in tables
        try
            _validate_function_table(table, id)
        catch e
            e isa TableLookupError || rethrow()
            push!(findings, ("/function_tables/$(id)", e))
            first_only && return findings
        end
    end
    return findings
end

"""
    _check_interp_fn_node(e::OpExpr) -> Nothing

The esm-spec §9.2 load-time argument checks on ONE `fn` node, or nothing when it
names no `interp.*` function, in the pinned "Order of the argument checks"
(esm-spec §9.2, ruling Q-110): `closed_function_arity`; the const-ness of every
array position in argument order; then the spec builders' rank, length, finite
and monotonicity steps (`_validate_interp_*_args`).
"""
function _check_interp_fn_node(e::OpExpr)::Nothing
    (e.op == "fn" && e.name !== nothing && e.name in _INTERP_FN_NAMES) || return nothing
    fname = String(e.name)
    cspec = _fn_const_arg_spec(fname)
    length(e.args) == cspec.arity || throw(ClosedFunctionError(
        ERROR_CODES.CLOSED_FUNCTION_ARITY,
        "$(fname) expects $(cspec.arity) arguments, got $(length(e.args)) (esm-spec §9.2)"))
    const_args = Any[_const_array_arg(e.args[pos], cspec.const_errs[k])
                     for (k, pos) in enumerate(cspec.const_positions)]
    if fname == "interp.linear"
        _build_interp_linear_spec(fname, const_args...)
    elseif fname == "interp.bilinear"
        _build_interp_bilinear_spec(fname, const_args...)
    else
        _build_interp_searchsorted_spec(fname, const_args...)
    end
    return nothing
end

# Every `fn` and `table_lookup` node under `root`, through every
# expression-bearing field (the generated `OPEXPR_FIELD_TABLE` walk). `seen` is
# shared across the whole document, so a subtree the template machinery shares
# between fields is checked once.
function _check_interp_fns_in!(findings::Vector{_LoadCheckFinding}, root, path::String,
                               seen::IdDict{OpExpr,Nothing}, tables)
    root isa ASTExpr || return nothing
    try
        _foreach_subexpr_once(root, seen) do x
            x isa OpExpr || return nothing
            if x.op == _TABLE_LOOKUP_OP
                _check_table_lookup_node(x, tables)
            else
                _check_interp_fn_node(x)
            end
        end
    catch err
        (err isa ClosedFunctionError || err isa TableLookupError) || rethrow()
        push!(findings, (path, err))
    end
    return nothing
end

# The registry a component's surviving `apply_expression_template` references
# expand against, when one of its template bodies calls an `interp.*` function
# or holds a `table_lookup`;
# `nothing` otherwise. Option B keeps references unexpanded in the typed
# document, and a `fn` node inside a template body is checked where the
# template is applied, on the arguments the expansion gives it (esm-spec §9.2).
# A body with no `interp.*` call cannot contribute one, so the common case pays
# no expansion.
function _interp_template_registry(file::EsmFile, key::String)
    file.component_templates === nothing && return nothing
    reg = get(file.component_templates, key, nothing)
    reg === nothing && return nothing
    return _raw_mentions_interp(reg) ? reg : nothing
end

function _raw_mentions_interp(x)
    if x isa AbstractDict
        n = get(x, "name", nothing)
        op = get(x, "op", nothing)
        op == "fn" && n isa AbstractString && n in _INTERP_FN_NAMES && return true
        op == _TABLE_LOOKUP_OP && return true
        return any(_raw_mentions_interp, values(x))
    elseif x isa AbstractVector
        return any(_raw_mentions_interp, x)
    end
    return false
end

_expand_for_check(e, reg) = reg === nothing ? e : _expand_expr_refs(e, reg)

"""
    _foreach_expression_field(f, file::EsmFile)

Call `f(expr, path, registry)` on the root of every expression-bearing field of
`file`: model variables' update rules, equations, initialization equations,
guesses, events and inline-test references (recursing into subsystems);
reaction rates, constraint equations, events, parameter update rules and
inline-test references of reaction systems; and the expressions of `coupling`
entries. `registry` is the component's template registry when its references
must be expanded before the check (see `_interp_template_registry`).
"""
function _foreach_expression_field(f, file::EsmFile)
    if file.models !== nothing
        for (name, m) in file.models
            reg = _interp_template_registry(file, "models.$(name)")
            _foreach_model_expression(f, m, "/models/$(name)", reg)
        end
    end
    if file.reaction_systems !== nothing
        for (name, rs) in file.reaction_systems
            reg = _interp_template_registry(file, "reaction_systems.$(name)")
            _foreach_rs_expression(f, rs, "/reaction_systems/$(name)", reg)
        end
    end
    for (i, ce) in enumerate(file.coupling)
        _foreach_coupling_expression(f, ce, "/coupling/$(i - 1)")
    end
    return nothing
end

function _foreach_update_expression(f, rules, path::String, reg)
    rules === nothing && return nothing
    for (i, r) in enumerate(rules)
        p = "$(path)/update/$(i - 1)"
        r.when === nothing || f(r.when, "$(p)/when", reg)
        r.expression === nothing || f(r.expression, "$(p)/expression", reg)
        if r.from !== nothing && r.from.unit_conversion isa ASTExpr
            f(r.from.unit_conversion, "$(p)/from/unit_conversion", reg)
        end
    end
    return nothing
end

function _foreach_equation_expression(f, eqs, path::String, reg)
    for (i, eq) in enumerate(eqs)
        f(eq.lhs, "$(path)/$(i - 1)/lhs", reg)
        f(eq.rhs, "$(path)/$(i - 1)/rhs", reg)
    end
    return nothing
end

function _foreach_affect_expression(f, affects, path::String, reg)
    affects === nothing && return nothing
    for (i, a) in enumerate(affects)
        f(a.rhs, "$(path)/$(i - 1)/rhs", reg)
    end
    return nothing
end

function _foreach_event_expression(f, cevs, devs, path::String, reg)
    for (i, ev) in enumerate(cevs)
        p = "$(path)/continuous_events/$(i - 1)"
        for (j, c) in enumerate(ev.conditions)
            f(c, "$(p)/conditions/$(j - 1)", reg)
        end
        _foreach_affect_expression(f, ev.affects, "$(p)/affects", reg)
        _foreach_affect_expression(f, ev.affect_neg, "$(p)/affect_neg", reg)
    end
    for (i, ev) in enumerate(devs)
        p = "$(path)/discrete_events/$(i - 1)"
        ev.trigger isa ConditionTrigger && f(ev.trigger.expression, "$(p)/trigger", reg)
        _foreach_affect_expression(f, ev.affects, "$(p)/affects", reg)
    end
    return nothing
end

function _foreach_test_expression(f, tests, path::String, reg)
    for (i, t) in enumerate(tests)
        for (j, a) in enumerate(t.assertions)
            a.reference isa ASTExpr &&
                f(a.reference, "$(path)/tests/$(i - 1)/assertions/$(j - 1)/reference", reg)
        end
    end
    return nothing
end

function _foreach_model_expression(f, m::Model, path::String, reg)
    for (vname, var) in m.variables
        _foreach_update_expression(f, var.update, "$(path)/variables/$(vname)", reg)
    end
    _foreach_equation_expression(f, m.equations, "$(path)/equations", reg)
    _foreach_equation_expression(f, m.initialization_equations,
                                 "$(path)/initialization_equations", reg)
    for (gname, g) in m.guesses
        g isa ASTExpr && f(g, "$(path)/guesses/$(gname)", reg)
    end
    _foreach_event_expression(f, m.continuous_events, m.discrete_events, path, reg)
    _foreach_test_expression(f, m.tests, path, reg)
    for (sname, sub) in m.subsystems
        sub isa Model || continue
        _foreach_model_expression(f, sub, "$(path)/subsystems/$(sname)", reg)
    end
    return nothing
end

function _foreach_rs_expression(f, rs::ReactionSystem, path::String, reg)
    for (i, r) in enumerate(rs.reactions)
        f(r.rate, "$(path)/reactions/$(i - 1)/rate", reg)
    end
    for p in rs.parameters
        _foreach_update_expression(f, p.update, "$(path)/parameters/$(p.name)", reg)
    end
    _foreach_equation_expression(f, rs.constraint_equations,
                                 "$(path)/constraint_equations", reg)
    _foreach_event_expression(f, rs.continuous_events, rs.discrete_events, path, reg)
    _foreach_test_expression(f, rs.tests, path, reg)
    for (sname, sub) in rs.subsystems
        _foreach_rs_expression(f, sub, "$(path)/subsystems/$(sname)", reg)
    end
    return nothing
end

function _foreach_coupling_expression(f, ce::CouplingEntry, path::String)
    if ce isa CouplingCouple && haskey(ce.connector, "equations")
        eqs = ce.connector["equations"]
        if eqs isa AbstractVector
            for (i, e) in enumerate(eqs)
                (e isa AbstractDict && get(e, "expression", nothing) isa ASTExpr) || continue
                f(e["expression"], "$(path)/connector/equations/$(i - 1)/expression", nothing)
            end
        end
    elseif ce isa CouplingVariableMap && ce.transform isa ASTExpr
        f(ce.transform, "$(path)/transform", nothing)
    elseif ce isa CouplingEvent
        if ce.conditions !== nothing
            for (j, c) in enumerate(ce.conditions)
                f(c, "$(path)/conditions/$(j - 1)", nothing)
            end
        end
        ce.trigger isa ConditionTrigger && f(ce.trigger.expression, "$(path)/trigger", nothing)
        _foreach_affect_expression(f, ce.affects, "$(path)/affects", nothing)
        _foreach_affect_expression(f, ce.affect_neg, "$(path)/affect_neg", nothing)
    end
    return nothing
end

"""
    _load_time_check_findings(file::EsmFile; first_only=false) -> Vector

Every load-time closed-function and function-table finding of `file`: the
table checks on every `function_tables` entry, then the `interp.*` argument
checks and the `table_lookup` checks on every expression field. `first_only` stops at the first finding (the
load path, which throws it).
"""
function _load_time_check_findings(file::EsmFile; first_only::Bool=false)
    findings = _LoadCheckFinding[]
    _check_function_tables(file.function_tables, findings; first_only=first_only)
    first_only && !isempty(findings) && return findings
    seen = IdDict{OpExpr,Nothing}()
    _foreach_expression_field(file) do expr, path, reg
        first_only && !isempty(findings) && return nothing
        _check_interp_fns_in!(findings, _expand_for_check(expr, reg), path, seen,
                              file.function_tables)
    end
    return findings
end

"""
    check_closed_functions_and_tables(file::EsmFile) -> EsmFile

Throw the first load-time closed-function or function-table finding of `file`
(a [`TableLookupError`](@ref) or [`ClosedFunctionError`](@ref) carrying its
esm-spec §9.2 / §9.5.5 code), or return `file`. Every `load_*` entry point runs
it on the loaded document, after template lowering, enum lowering and mount
resolution.
"""
function check_closed_functions_and_tables(file::EsmFile)::EsmFile
    findings = _load_time_check_findings(file; first_only=true)
    isempty(findings) || throw(findings[1][2])
    return file
end

"""
    validate_closed_functions_and_tables(file::EsmFile) -> Vector{StructuralError}

The `validate()` form of [`check_closed_functions_and_tables`](@ref): one
structural error per broken table and per expression field holding a bad
`interp.*` call, each carrying its esm-spec §9.2 / §9.5.5 code.
"""
function validate_closed_functions_and_tables(file::EsmFile)::Vector{StructuralError}
    return StructuralError[StructuralError(path, err.message, err.code)
                           for (path, err) in _load_time_check_findings(file)]
end
