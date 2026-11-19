# Reference integrity: model, expression, coupling and system references.

"""
    validate_reference_integrity(file::EsmFile; views = nothing, names = nothing) -> Vector{StructuralError}

Validate that all variable references can be resolved through the hierarchy.
`views` are the template-expanded top-level models and `names` the
document-wide name sets (`_document_names`), both from a validation pass's
context when the caller has one.
"""
function validate_reference_integrity(
        file::EsmFile; views = nothing, names = nothing
    )::Vector{StructuralError}
    errors = StructuralError[]
    names === nothing && (names = _document_names(file))

    # Validate model variable references. A COUPLED model — operator-composed or
    # a coupling target — is checked against the DOCUMENT-WIDE declared names plus
    # the §6.4 `_var` placeholder (see `validate_model_references`): composition
    # merges the participating systems' scopes, so a cross-system bare reference
    # is legitimate, while a name declared NOWHERE in the document is still an
    # `undefined_variable`.
    if file.models !== nothing
        for (model_name, model) in file.models
            append!(
                errors, validate_model_references(
                    file, model, _pointer("", "models", model_name);
                    model_name = model_name,
                    is_coupled = (model_name ∈ names.coupled), views = views,
                    names = names
                )
            )
        end
    end

    # A reaction system's constraint equations, parameter update rules, events
    # and inline tests are the same sites as a model's, and report `undefined_variable` as the model's do
    # (only a reaction `rate` keeps `undefined_parameter`). Each is checked against
    # the system's species and parameters plus the document's implicit names,
    # widened to the document scope when the system is coupled, exactly as
    # `validate_model_references` scopes a model.
    if file.reaction_systems !== nothing
        for (rs_name, rs) in file.reaction_systems
            isempty(rs.tests) && isempty(rs.constraint_equations) &&
                isempty(rs.discrete_events) && isempty(rs.continuous_events) &&
                all(p -> p.update === nothing, rs.parameters) && continue
            is_coupled = rs_name ∈ names.coupled
            scope = is_coupled ? copy(names.declared) :
                Set{String}(vcat([sp.name for sp in rs.species], [p.name for p in rs.parameters]))
            is_coupled && push!(scope, _OPERATOR_PLACEHOLDER_VAR)
            union!(scope, keys(file.index_sets))
            push!(scope, _indep_var(file))
            union!(scope, names.coordinates)
            union!(scope, names.injected)
            foreach_expression(rs, _pointer("", "reaction_systems", rs_name); subsystems = false) do e, at, kind
                kind in _REFERENCE_CHECKED_SITES || return nothing
                append!(errors, validate_expression_references(file, e, at; scope = scope))
                return nothing
            end
        end
    end

    # Validate coupling references
    for (i, coupling_entry) in enumerate(file.coupling)
        append!(errors, validate_coupling_references(file, coupling_entry, _pointer("", "coupling", i)))
    end

    # esm-spec §10.10.3: a mis-bound `coupling_import` is a bad edge, and the
    # scoped-reference check MUST see the expanded edges.
    append!(errors, _validate_imported_coupling_edges(file))

    return errors
end

# The document-wide name sets reference integrity scopes with, computed once
# per pass (a validation pass's context carries the same fields).
_document_names(file::EsmFile) = (
    coupled = _coupled_system_names(file), declared = _document_declared_names(file),
    coordinates = _coordinate_names(file), injected = _callback_injected_names(file),
)

# The component a `bind` points a role at for `ref`, and the role(s) that point
# there. A bind value may be a dotted subsystem path (`Parent.Child`, §10.10.1),
# so the LONGEST bound component that prefixes the reference wins; a reference
# no bind covers falls back to its own head segment.
function _bound_component_for(bind::AbstractDict, ref::AbstractString)
    best = ""
    for v in values(bind)
        (ref == v || startswith(ref, v * ".")) || continue
        length(v) > length(best) && (best = v)
    end
    isempty(best) && (best = String(first(split(ref, '.'))))
    roles = sort!([String(k) for (k, v) in pairs(bind) if v == best])
    return best, join(roles, ", ")
end

"""
Validate the edges each `coupling_import` expands to (esm-spec §10.10.3).

`validate_coupling_references` walks the SOURCE `coupling` vector, where an
import is still `{type, ref, bind}` and its edges do not exist; a mis-bind (a
structurally complete `bind` that points a role at a component lacking a variable
the library references) is caught here. Each import is expanded here on its own, against the base the loader recorded for
the document, and its edges go through the same qualified-reference check a
hand-authored edge does. A finding is re-pointed at the import entry and names the
library, the role and the bound component. An import that cannot be expanded at
all (a missing library, an unbound role, ...) is left to flatten, which owns those
§10.11 diagnostics.
"""
function _validate_imported_coupling_edges(file::EsmFile)::Vector{StructuralError}
    errors = StructuralError[]
    # Expanding reads the library from disk; without the base the loader recorded
    # for the document, the ref would resolve against the working directory, so a
    # document with no known location is left to flatten.
    base = file.coupling_import_base
    base === nothing && return errors
    src = _DocumentSource()
    for (i, entry) in enumerate(file.coupling)
        entry isa CouplingImport || continue
        local edges
        try
            edges = _expand_one(
                _read_coupling_library(src, _ref_base(base), entry.ref),
                entry.ref, entry.bind, file
            )
        catch e
            # A library that does not load or bind is flatten's diagnostic.
            e isa InterruptException && rethrow()
            continue
        end
        for edge in edges
            edge isa CouplingVariableMap || continue
            for (side, ref) in (("from", edge.from), ("to", edge.to))
                occursin('.', ref) || continue
                cause = try
                    resolve_qualified_reference(file, ref)
                    nothing
                catch e
                    isa(e, QualifiedReferenceError) ? e.message : rethrow()
                end
                cause === nothing && continue
                component, roles = _bound_component_for(entry.bind, ref)
                _report!(
                    errors, ERROR_CODES.UNRESOLVED_SCOPED_REF,
                    _pointer("", "coupling", i),
                    "coupling_import '$(entry.ref)' binds role '$roles' to '$component', " *
                        "which does not provide '$ref' referenced by the library: " *
                        "cannot resolve '$side' reference '$ref': $cause",
                    Dict{String, Any}(
                        "reference" => ref,
                        "coupling_type" => "variable_map",
                        "direction" => side,
                        "coupling_import" => entry.ref,
                        "role" => roles,
                        "bound_component" => component,
                    )
                )
            end
        end
    end
    return errors
end

# The solved-for name an equation defines: a bare `VarExpr` LHS (`x = …`) or the
# first argument of an operator LHS (`D(x, t) = …`, `ic(x) = …`). These are the
# model's unknowns and are in scope for its equations even when not separately
# listed under `variables` (an ODE state may appear only as `D(u)`). Dotted
# cross-system targets are left to the qualified-reference resolver. Returns
# `nothing` when no bare local name can be extracted.
function _equation_lhs_target(eq::Equation)::Union{String, Nothing}
    lhs = eq.lhs
    if isa(lhs, VarExpr)
        return occursin('.', lhs.name) ? nothing : lhs.name
    elseif isa(lhs, OpExpr) && !isempty(lhs.args) && isa(lhs.args[1], VarExpr)
        name = lhs.args[1].name
        return occursin('.', name) ? nothing : name
    end
    return nothing
end

"""
    _indep_var(file::EsmFile) -> String

The document's independent (time) variable — `domain.independent_variable`, or
`"t"` when the document does not say. Never hard-code `"t"`: a document may
rename it (`tau`, `depth`). Also takes a `Domain` (or `nothing`) and, in
flatten.jl, a `FlattenedSystem`.
"""
_indep_var(domain::Union{Domain, Nothing})::String =
    domain === nothing ? "t" : domain.independent_variable
_indep_var(file::EsmFile)::String = _indep_var(file.domain)

# The spatial coordinate names every document may reference WITHOUT declaring
# them. v0.8.0 removed `Domain.spatial`, so a coordinate has no declaration site
# at all: it is named directly in an expression (the `x` of an expression initial
# condition, `0.5*(1 + tanh((x - 0.3)/0.15))`) and as the `dim` of a
# spatial `D` (its `wrt`) or of an open-tier op. It belongs to the DOMAIN, not to any `variables`
# block, so reporting it `undefined_variable` rejects a valid file.
const _CONVENTIONAL_COORDINATE_NAMES = ("x", "y", "z", "lon", "lat", "lev")

"""
    _coordinate_names(file::EsmFile) -> Set{String}

The implicitly-declared coordinate namespace: the conventional axis names plus
every axis the DOCUMENT itself names — the `dim` of a spatial operator and the
`wrt` of a SPATIAL derivative (a `wrt` naming the independent variable is time,
credited separately). Mirrors Go `coordinateNames`.
"""
function _coordinate_names(file::EsmFile)::Set{String}
    coords = Set{String}(_CONVENTIONAL_COORDINATE_NAMES)
    indep = _indep_var(file)

    # Every expression site of the document: a spatial `D` or a `dim` may sit
    # in any of them, in a subsystem or a reaction system as well.
    foreach_expression(file) do site, _, _
        foreach_subexpr_once(site) do e
            e isa OpExpr || return nothing
            e.dim !== nothing && !isempty(e.dim) && push!(coords, e.dim)
            e.wrt !== nothing && !isempty(e.wrt) && e.wrt != indep && push!(coords, e.wrt)
            return nothing
        end
    end
    return coords
end

"""
    _coupled_system_names(file::EsmFile) -> Set{String}

Every system a coupling entry NAMES — as a `systems` member (including the ROOT
of a dotted subsystem path) or as the system half of a `from`/`to` scoped
reference.

A COUPLED system does not own all the names its equations mention. An
operator-style model spells its operand as the §6.4 placeholder `_var`; a
`variable_map` supplies a value the target never declares; and its `equations`
may drive a state that lives in the system it is composed with, so its own
equation/unknown count need not balance. Equation balance and reference integrity
are therefore SKIPPED for these systems — the settled cross-binding rule (Go
`coupledSystemNames`, TS `coupledSystems`). Event consistency still runs, with
`_var` credited, which is where a genuinely undeclared event target is caught.
"""
function _coupled_system_names(file::EsmFile)::Set{String}
    coupled = Set{String}()
    add!(name::AbstractString) = begin
        isempty(name) && return
        push!(coupled, String(name))
        # A dotted endpoint ("Atmosphere.Chemistry.O3") couples the ROOT system
        # too — that is the model whose checks must relax.
        i = findfirst('.', name)
        i === nothing || push!(coupled, String(name[1:prevind(name, i)]))
    end
    for entry in file.coupling
        if entry isa CouplingOperatorCompose || entry isa CouplingCouple
            for s in entry.systems
                add!(s)
            end
        elseif entry isa CouplingVariableMap
            add!(entry.from); add!(entry.to)
        end
    end
    return coupled
end

"""
    _document_declared_names(file::EsmFile) -> Set{String}

Every name declared ANYWHERE in the document: each top-level model's `variables`,
each reaction system's `species` / `parameters`, and each data loader's
`variables`. This is the scope a data loader's `unit_conversion` expression
resolves against (a loader has no equations of its own, so its conversion may
scale a loaded field by a model's declared parameter). Mirrors TS
`documentDeclaredNames`.
"""
function _document_declared_names(file::EsmFile)::Set{String}
    names = Set{String}()
    if file.models !== nothing
        # `file.models` is `Dict{String,Model}` — no non-Model guard needed.
        for (_, model) in file.models
            union!(names, keys(model.variables))
        end
    end
    if file.reaction_systems !== nothing
        for (_, rs) in file.reaction_systems
            for sp in rs.species
                push!(names, sp.name)
            end
            for p in rs.parameters
                push!(names, p.name)
            end
        end
    end
    # A data source declares no variables of its own — the consuming
    # PARAMETER does, and it is already collected from its model above
    # (esm-spec §8).
    return names
end

"""
    _callback_injected_names(file::EsmFile) -> Set{String}

Every name a `callback` coupling entry INJECTS into the system it targets, read
off `coupling[i].config.callback_variables[j].name` (the config is raw JSON, so
this reads it defensively).

These are declaration sites (esm-spec §4.9.5, checker row (k)) and must be in
scope, or reference integrity reports a name the document really does declare.
The set is DOCUMENT-scoped rather than per-target: `config` is untyped, so the
target cannot be resolved reliably, and being slightly over-permissive here is
the right trade — a missed typo is a lesser harm than rejecting a valid file.
"""
function _callback_injected_names(file::EsmFile)::Set{String}
    names = Set{String}()
    for entry in file.coupling
        entry isa CouplingCallback || continue
        cfg = entry.config
        cfg === nothing && continue
        cvs = get(cfg, "callback_variables", nothing)
        cvs isa AbstractVector || continue
        for cv in cvs
            cv isa AbstractDict || continue
            nm = get(cv, "name", nothing)
            nm isa AbstractString && push!(names, String(nm))
        end
    end
    return names
end

# The expression sites (`EXPRESSION_SITE_KINDS`) of a model or reaction system
# whose names the reference-integrity check resolves against the component's
# scope. Not here: a reaction `rate` (`validate_reaction_consistency` reports
# `undefined_parameter` there), a data update's `from.unit_conversion`
# (`_check_update_unit_conversions!`) and a variable's `lb` / `ub`. An inline
# test's `from_file` reference (esm-spec §6.6.5 convention 3) is data, not an
# expression, and is not a site.
const _REFERENCE_CHECKED_SITES = (
    :equation_lhs, :equation_rhs, :initialization_lhs, :initialization_rhs,
    :constraint_lhs, :constraint_rhs, :guess, :update_when, :update_expression,
    :event_condition, :event_trigger, :affect, :affect_neg, :test_reference,
)

"""
    validate_model_references(file::EsmFile, model::Model, path::String) -> Vector{StructuralError}

Validate the variable references at every expression site of `model` and of
its model subsystems (an event's affect targets are names, not sites).
"""
function validate_model_references(
        file::EsmFile, model::Model, path::String;
        model_name::AbstractString = "",
        is_coupled::Bool = false, views = nothing, names = nothing
    )::Vector{StructuralError}
    errors = StructuralError[]
    names === nothing && (names = _document_names(file))
    # The view expands every site of the model and of its subsystems. A
    # subsystem of a coupled model is composed along with its parent, so it is
    # checked with the parent's scope rule.
    view = isempty(model_name) ? model : _units_view(file, model_name, model, views)
    _foreach_component(view, path) do m, p, _
        _check_component_references!(errors, file, m, p, is_coupled, names)
    end
    return errors
end

# The references at every expression site of one component (not its
# subsystems), `model` already template-expanded.
function _check_component_references!(errors, file::EsmFile, model::Model, path, is_coupled::Bool, names)
    # Names in scope for this model's equations: its declared variables (state,
    # parameter, observed), the document-scoped `index_sets` registry (a
    # legitimate non-variable identifier namespace an aggregate may name — RFC
    # semiring-faq-unified-ir §5.2), and each equation's LHS target (a
    # solved-for unknown, e.g. an ODE state referenced as `D(u)` that is not
    # separately listed under `variables`). Bound loop indices are added per-node
    # during the descent (see `validate_expression_references`).
    #
    # A COUPLED model instead resolves against the DOCUMENT-WIDE declared names
    # plus the §6.4 `_var` placeholder: `operator_compose`/`couple` merge the
    # participating systems' scopes, so a cross-system bare reference is
    # legitimate, while a name declared nowhere is still an `undefined_variable`.
    # Mirrors Python's `global_symbols` and TS `documentDeclaredNames`.
    # The model's own variables are in scope either way: a subsystem's are not
    # among the document-wide (top-level) names.
    scope = Set{String}(keys(model.variables))
    is_coupled && union!(scope, names.declared, (_OPERATOR_PLACEHOLDER_VAR,))
    union!(scope, keys(file.index_sets))
    for eq in model.equations
        target = _equation_lhs_target(eq)
        target === nothing || push!(scope, target)
    end

    # (a) The DOMAIN's names. Neither the independent variable nor a spatial
    # coordinate is an entry of any `variables` block, yet both are perfectly
    # legal references — a forcing spells `sin(t)`, an event trigger `t > 300`,
    # an expression initial condition `tanh((x - 0.3)/0.15)`. Credit them from
    # the document, so a document that renames the independent variable to `tau`
    # gets `tau` and not `t`.
    push!(scope, _indep_var(file))
    union!(scope, names.coordinates)

    # A model's variable table is NOT the complete set of declaration sites, and
    # checking every expression-bearing field makes that bite: a name declared
    # somewhere ELSE would be reported as `undefined_variable`. So the check
    # runs against the UNION of declaration sites.
    #
    # `coupling[i].config.callback_variables[j].name` is the one the corpus
    # caught: a callback INJECTS those names into the system it targets
    # (tests/coupling/callback_examples.esm declares
    # `external_temperature_forcing` exactly this way and nowhere else).
    union!(scope, names.injected)

    # Check every expression site (`_REFERENCE_CHECKED_SITES`) against `scope`,
    # on the EXPANSION of any surviving `apply_expression_template` reference
    # (esm-spec §9.6.4 rule 2: a reference denotes its expansion). A template
    # binding is a value substituted into the body, and only where the body uses
    # it in an expression position is it a reference; one bound to a scalar
    # field (`K_manifold => "planar"` filling a `manifold`) or to a range's
    # `from` is a literal. Expansion keeps every site where it was, so pointers
    # still name the authored expression.
    foreach_expression(model, path; subsystems = false) do e, at, kind
        kind in _REFERENCE_CHECKED_SITES || return nothing
        append!(errors, validate_expression_references(file, e, at; scope = scope))
        return nothing
    end
    return errors
end

"""
Bare names that are always in scope inside an expression even when they are not
declared model variables: the elementary math functions and reductions the AST
spells as operator (`OpExpr`) names. They normally appear as `OpExpr.op`, not as
`VarExpr` leaves, but a bare occurrence (e.g. a partially-applied builtin) must
not be mis-reported as an undefined variable. Mirrors Rust
`is_builtin_function` (structural.rs) so the same names are excused across
bindings.

DERIVED from the op registry's `builtin_fn` flag (src/op_registry.jl): the
`:elementary` rows plus `ifelse`/`Pre`. Membership is pinned literal-for-
literal by test/op_registry_test.jl.
"""
const _BUILTIN_FUNCTION_NAMES = _ops_with(:builtin_fn)

# Every bare name inside a SUBSCRIPT expression. `index(u, i+1)` is index space,
# so `i` is a loop index; the arithmetic around it is the stencil offset.
function _collect_index_names!(syms::Vector{String}, e::ASTExpr)
    if e isa VarExpr
        occursin('.', e.name) || push!(syms, e.name)
    elseif e isa OpExpr
        for a in e.args
            _collect_index_names!(syms, a)
        end
    end
    return syms
end

# Index symbols the reference checker credits into scope for THIS node's
# children. DELIBERATELY WIDER than expression.jl's `_bound_symbols` (the
# `free_variables` binder-subtraction set): validation answers "could this
# name legally appear here?", so it additionally credits subscript-position
# index names (`index(u, i+1)`) and `bindings` KEYS (template formal parameters —
# the `binds_scope` flag in OPEXPR_FIELD_TABLE). `_bound_symbols` answers the
# narrower "does this node bind this symbol?" for dependency analysis, where
# widening would hide real free variables. Both must stay.
"""
    _bound_index_symbols(op::OpExpr) -> Vector{String}

The index / iteration symbols an operator node BINDS for its own child
expressions — loop positions and invented keys, NOT declared variables. They
are in scope for the node's descended children (an aggregate body, a filter
predicate, a grouping key, integral bounds) so a bound loop index such as the
`i` in `index(u, i)` is not mis-reported as undefined.

Mirrors Rust `bound_index_symbols` (structural.rs) and Go `boundIndexSymbols`
(validate.go). Binder sources: `output_idx` (aggregate surviving indices),
`ranges` keys (contraction loop variables), `int_var` (integral integration
variable, wire `var`), the positional element indices of an
`index(array, i, j, …)` node, and `bindings` keys (`apply_expression_template`
formal parameters).
"""
function _bound_index_symbols(op::OpExpr)::Vector{String}
    syms = String[]
    if op.output_idx !== nothing
        for x in op.output_idx
            x isa AbstractString && push!(syms, String(x))
        end
    end
    if op.ranges !== nothing
        for k in keys(op.ranges)
            push!(syms, String(k))
        end
    end
    op.int_var !== nothing && push!(syms, op.int_var)

    # NOTE: an `integral`'s `lower`/`upper` are NOT exempted. It is tempting to
    # call them coordinate-space bounds and wave them through — that would make
    # tests/valid/integral_operator_pide.esm pass, whose `lower` is an undeclared
    # `xmin` — but tests/invalid/undefined_variable_in_integral_bound.esm pins the
    # opposite: an undefined name in an integral bound IS `undefined_variable`.
    # The corpus decides, and it says the bounds are ordinary expressions. The
    # `xmin` in that "valid" fixture is therefore a fixture defect, not a checker
    # one, and is reported upstream rather than papered over here.
    if op.op == "index"
        # index(array, pos…): every SUBSCRIPT position after the array head is
        # index space, so the free names appearing in one are loop indices.
        #
        # Binding only the BARE names (`index(u, i)`) and not the ones inside a
        # subscript EXPRESSION (`index(u, i+1)`) is what made every lowered
        # stencil look broken: a finite-difference scheme is written
        # `index(u, i-1)`, `index(u, i+1)` — the offsets ARE the stencil — and
        # the `i` inside the offset was reported `undefined_variable`, rejecting
        # tests/valid/advection_reaction_loaded_ic_bc.esm with 12 errors.
        #
        # This is a subscript-position rule, NOT an allowlist of short names: a
        # name is bound because of WHERE it appears (index space), and a name
        # outside index space that nothing declares is still `undefined_variable`.
        for i in 2:length(op.args)
            _collect_index_names!(syms, op.args[i])
        end
    end
    if op.bindings !== nothing
        for k in keys(op.bindings)
            push!(syms, String(k))
        end
    end
    return syms
end

"""
    validate_expression_references(file::EsmFile, expr::ASTExpr, path::String;
                                   scope::Union{Set{String},Nothing}=nothing) -> Vector{StructuralError}

Validate references in an expression tree.

Two independent checks run over the FULL expression child set — `args` plus the
sidecar fields (integral `lower`/`upper` bounds, a faq body
`expr`, a `filter` predicate, `makearray` `values`, an aggregate grouping `key`, and `apply_expression_template` `bindings` values),
matching Rust `for_each_child` / Go `validateExprNodeChildren`:

1. `operator_apply` operator names are always flagged (the format has no
   top-level `operators` block, esm-spec §9, so they never resolve).

2. When `scope` is supplied, each bare (non-dotted) `VarExpr` that is not in
   scope is reported as `undefined_variable`. In scope = a name in `scope`
   (the enclosing model/system's declared variables/parameters, its equation
   LHS targets, and the document `index_sets` names), the time variable `t`, a
   derivative form (`d(…)`), a builtin function name, or an index symbol BOUND
   by an enclosing node (see [`_bound_index_symbols`]). Dotted `A.b` references
   are left to the qualified-reference resolver and never flagged here. When
   `scope === nothing` (event / coupling call sites) the bare-variable check is
   skipped, but the full child set is still descended so an `operator_apply`
   hidden outside `args` is not missed.
"""
function validate_expression_references(
        file::EsmFile, expr::ASTExpr, path::String;
        scope::Union{Set{String}, Nothing} = nothing
    )::Vector{StructuralError}
    errors = StructuralError[]
    # `path` is the expression-bearing FIELD's pointer (`equations[i]/rhs`, an
    # observed `expression`, a `guesses` entry, an event trigger/condition, …).
    # A reference-integrity finding attaches at that FIELD (§7.1.2: "the node
    # that carries the defect"), NOT at the deepest leaf the walk descends into —
    # the corpus pins `undefined_variable` at `/models/M/equations/0/rhs`, never
    # at `/rhs/args/1`. The constant field root is threaded as `anchor`; no
    # diagnostic is leaf-local, so no leaf path is built (the descent still
    # visits every node so nothing goes unchecked).
    _check_expression_references!(
        errors, file, expr, path, path,
        scope === nothing ? nothing : _RefScope(scope, nothing, String[])
    )
    return errors
end

# The in-scope names at one node of the reference walk: the caller's set plus
# the symbols each enclosing node binds, as a chain (no copy of the set per
# binding node).
struct _RefScope
    base::Set{String}
    parent::Union{Nothing, _RefScope}
    bound::Vector{String}
end
function _in_ref_scope(name::String, sc::_RefScope)
    name in sc.base && return true
    s = sc
    while s !== nothing
        name in s.bound && return true
        s = s.parent
    end
    return false
end

function _check_expression_references!(
        errors::Vector{StructuralError}, file::EsmFile,
        expr::ASTExpr, path::String, anchor::String,
        scope::Union{_RefScope, Nothing}
    )
    if isa(expr, VarExpr)
        _check_bare_variable!(errors, expr.name, anchor, scope)
    elseif isa(expr, OpExpr)
        # Extend the in-scope set with any index symbols this node binds, so a
        # bound loop index in a descended child is not flagged as undefined.
        child_scope = scope
        if scope !== nothing
            bound = _bound_index_symbols(expr)
            isempty(bound) || (child_scope = _RefScope(scope.base, scope, bound))
        end

        # `operator_apply`: the referenced operator can never resolve (v0.3.0
        # §9 closure). Flag it, and don't also treat the operator-name arg as a
        # bare undefined variable.
        skip_operator_arg = false
        if expr.op == "operator_apply" && !isempty(expr.args) && isa(expr.args[1], VarExpr)
            _report!(
                errors, ERROR_CODES.UNDEFINED_OPERATOR,
                anchor,
                "Operator '$(expr.args[1].name)' referenced but not defined"
            )
            skip_operator_arg = true
        end

        # Descend the full expression-bearing child set via the SHARED generated
        # walker (`foreach_child_with_path`, expression.jl — the same
        # OPEXPR_FIELD_TABLE-derived set `child_exprs` yields, with wire-key
        # path segments; mirrors Rust `for_each_child`). The `anchor` (field
        # root) is threaded UNCHANGED so any finding raised deeper still
        # attaches at the expression FIELD, not the leaf. The `operator_apply`
        # operator-name arg is skipped by its path (`args/0`), matching the
        # hand-written descent this replaces. Findings carry no leaf path, so
        # the descent builds none (`_foreach_child_field`: the same children in
        # the same order).
        _foreach_child_field(expr) do child, field, i
            (skip_operator_arg && field === :args && i == 1) && return
            _check_expression_references!(errors, file, child, path, anchor, child_scope)
        end
    end
    # NumExpr / IntExpr are literals — no references to validate.
    return errors
end

# Flag a bare `VarExpr` name that is not in scope as `undefined_variable`.
# No-op when `scope === nothing` (scoped resolution not requested), for a dotted
# (qualified) reference (handled by the qualified-reference resolver), for a
# derivative form, or for a builtin function name.
#
# The independent variable is not special-cased: it is credited into `scope`
# from the document (`_indep_var`, which a document may rename), together with
# the coordinate namespace; both belong to the DOMAIN, not to any `variables`
# block.
function _check_bare_variable!(
        errors::Vector{StructuralError}, name::String,
        path::String, scope::Union{Set{String}, _RefScope, Nothing}
    )
    scope === nothing && return errors
    occursin('.', name) && return errors
    (startswith(name, "d(") || name in _BUILTIN_FUNCTION_NAMES) && return errors
    if !(scope isa _RefScope ? _in_ref_scope(name, scope) : name in scope)
        _report!(
            errors, ERROR_CODES.UNDEFINED_VARIABLE,
            path,
            "Variable '$name' referenced in equation is not declared",
            Dict{String, Any}("variable" => name)
        )
    end
    return errors
end

# Try to resolve `ref` as a qualified reference; on failure push a
# StructuralError at `path` whose message is "<desc> '<ref>': <cause>".
# Non-QualifiedReferenceError exceptions are rethrown.
function _check_resolvable!(
        errors::Vector{StructuralError}, file::EsmFile,
        ref::String, path::String, desc::String,
        error_type::String
    )
    try
        resolve_qualified_reference(file, ref)
    catch e
        if isa(e, QualifiedReferenceError)
            _report!(
                errors, error_type,
                path,
                "$desc '$ref': $(e.message)"
            )
        else
            rethrow()
        end
    end
    return errors
end

# Resolve every qualified name inside a `couple` connector's equation
# `expression`s. The connector is raw JSON (`Dict{String,Any}` straight off the
# parser), so this reads it defensively rather than through the typed AST.
function _check_connector_expressions(
        file::EsmFile, entry::CouplingCouple,
        path::String
    )::Vector{StructuralError}
    errors = StructuralError[]
    eqs = get(entry.connector, "equations", nothing)
    eqs isa AbstractVector || return errors

    for (i, eq) in enumerate(eqs)
        eq isa AbstractDict || continue
        raw = get(eq, "expression", nothing)
        raw === nothing && continue
        expr = try
            expression_from_json(raw)
        catch e
            e isa InterruptException && rethrow()
            continue    # a malformed expression is the schema's business
        end
        epath = _pointer(path, "connector", "equations", i, "expression")
        for name in sort!(collect(_referenced_var_names(expr)))
            occursin('.', name) || continue    # bare names are not cross-system refs
            try
                resolve_qualified_reference(file, name)
            catch e
                e isa QualifiedReferenceError || rethrow()
                _report!(
                    errors, ERROR_CODES.UNRESOLVED_SCOPED_REF,
                    epath,
                    "Variable \"$name\" referenced in connector equation expression does not resolve",
                    Dict{String, Any}("variable" => name)
                )
            end
        end
    end
    return errors
end

"""
    _check_coupling_role_references(file, coupling_entry, path) -> Vector{StructuralError}

Resolve a coupling library's role-scoped refs against its declared
`coupling_roles`. esm-spec §10.9 suspends ordinary §4.6 system resolution for a
library validated on its own and requires the top-level segment at every
§10.10.2 occurrence site to name a declared role instead. The site walk is shared
with the import-time check in `coupling_imports.jl`, so the two cannot drift.
"""
function _check_coupling_role_references(file::EsmFile, coupling_entry::CouplingEntry, path::String)::Vector{StructuralError}
    errors = StructuralError[]
    roles = file.coupling_roles === nothing ? Dict{String, Any}() : file.coupling_roles
    segments = _collect_role_segments(serialize_coupling_entry(coupling_entry))
    for role in sort!(collect(Iterators.filter(s -> !haskey(roles, s), segments)))
        _report!(
            errors, ERROR_CODES.COUPLING_EDGE_UNKNOWN_ROLE,
            path,
            "edge references '$role', which is not a declared role " *
                "(esm-spec §10.9: a coupling library's refs name a role in `coupling_roles`)",
            Dict{String, Any}("role" => role, "expected_in" => "coupling_roles")
        )
    end
    return errors
end

"""
    validate_coupling_references(file::EsmFile, coupling_entry::CouplingEntry, path::String) -> Vector{StructuralError}

Validate coupling references based on the specific coupling type.
Checks that systems, operators, and variable references can be resolved.
"""
function validate_coupling_references(file::EsmFile, coupling_entry::CouplingEntry, path::String)::Vector{StructuralError}
    errors = StructuralError[]

    # In a coupling-library file (esm-spec §10.9) an edge's system-naming
    # segments name declared ROLES, not systems, and the library holds no models
    # by definition — resolving them against the file's systems would reject
    # every well-formed library. `coupling_roles` is the sole positive
    # identifier of the kind.
    if file.coupling_roles !== nothing
        return _check_coupling_role_references(file, coupling_entry, path)
    end

    if isa(coupling_entry, CouplingOperatorCompose)
        # Validate that all referenced systems exist. The defect is carried by
        # the `systems` field (§7.1.2); the corpus pins `/coupling/i/systems`,
        # not the individual `/systems/j` element (TS emits the same).
        for system_name in coupling_entry.systems
            if !system_exists_in_file(file, system_name)
                _report!(
                    errors, ERROR_CODES.UNDEFINED_SYSTEM,
                    "$path/systems",
                    "System '$system_name' referenced in operator_compose coupling not found",
                    Dict{String, Any}("system" => system_name)
                )
            end
        end

    elseif isa(coupling_entry, CouplingCouple)
        # Validate that all referenced systems exist
        for system_name in coupling_entry.systems
            if !system_exists_in_file(file, system_name)
                _report!(
                    errors, ERROR_CODES.UNDEFINED_SYSTEM,
                    "$path/systems",
                    "System '$system_name' referenced in couple coupling not found",
                    Dict{String, Any}("system" => system_name)
                )
            end
        end

        # A connector equation may carry an `expression` over FULLY-QUALIFIED
        # cross-system names. It was never looked at — and the fixture that pins
        # it (tests/invalid/unresolved_scoped_ref_in_connector_expression.esm) was
        # only ever "rejected" by a bogus SchemaError from the JSON3-typed
        # connector (see `validate`). Fixing that error unmasked this hole, which
        # is exactly why an invalid fixture must be rejected for the RIGHT reason.
        append!(errors, _check_connector_expressions(file, coupling_entry, path))

    elseif isa(coupling_entry, CouplingVariableMap)
        # Validate 'from' reference
        if !validate_reference_syntax(coupling_entry.from)
            _report!(
                errors, ERROR_CODES.INVALID_REFERENCE_SYNTAX,
                "$path/from",
                "Invalid reference syntax: '$(coupling_entry.from)'"
            )
        else
            # A `variable_map` endpoint is a SCOPED reference (`System.var`); an
            # unresolvable one is `unresolved_scoped_ref` (§7.1), not the generic
            # `unresolved_reference` spelling.
            _check_resolvable!(
                errors, file, coupling_entry.from, "$path/from",
                "Cannot resolve 'from' reference", ERROR_CODES.UNRESOLVED_SCOPED_REF
            )
        end

        # Validate 'to' reference
        if !validate_reference_syntax(coupling_entry.to)
            _report!(
                errors, ERROR_CODES.INVALID_REFERENCE_SYNTAX,
                "$path/to",
                "Invalid reference syntax: '$(coupling_entry.to)'"
            )
        else
            _check_resolvable!(
                errors, file, coupling_entry.to, "$path/to",
                "Cannot resolve 'to' reference", ERROR_CODES.UNRESOLVED_SCOPED_REF
            )
        end

        # `transform` may be an EXPRESSION rather than one of the named string
        # transforms. Its names are
        # cross-system references, so they are fully qualified (§4.6) and are
        # resolved by the qualified-reference resolver, not against a model scope.
        if isa(coupling_entry.transform, ASTExpr)
            append!(
                errors, validate_expression_references(
                    file, coupling_entry.transform, "$path/transform"
                )
            )
            for name in _referenced_var_names(coupling_entry.transform)
                occursin('.', name) || continue
                _check_resolvable!(
                    errors, file, name, "$path/transform",
                    "Cannot resolve reference", ERROR_CODES.UNRESOLVED_SCOPED_REF
                )
            end
        end

    elseif isa(coupling_entry, CouplingOperatorApply)
        # The format has no top-level `operators` block (esm-spec §9 closure),
        # so the referenced operator can never resolve — flag it.
        _report!(
            errors, ERROR_CODES.UNDEFINED_OPERATOR,
            "$path/operator",
            "Operator '$(coupling_entry.operator)' referenced in operator_apply coupling not found"
        )

    elseif isa(coupling_entry, CouplingCallback)
        # Basic validation - callback_id should be a non-empty string
        if isempty(coupling_entry.callback_id)
            _report!(
                errors, ERROR_CODES.EMPTY_CALLBACK_ID,
                "$path/callback_id",
                "Callback ID cannot be empty"
            )
        end

    elseif isa(coupling_entry, CouplingEvent)
        # Validate affect equations
        for (i, affect) in enumerate(coupling_entry.affects)
            _check_resolvable!(
                errors, file, affect.lhs, _pointer(path, "affects", i, "lhs"),
                "Cannot resolve affect target", ERROR_CODES.UNRESOLVED_AFFECT_TARGET
            )
            append!(errors, validate_expression_references(file, affect.rhs, _pointer(path, "affects", i, "rhs")))
        end

        # Validate negative affect equations if present
        if coupling_entry.affect_neg !== nothing
            for (i, affect) in enumerate(coupling_entry.affect_neg)
                _check_resolvable!(
                    errors, file, affect.lhs, _pointer(path, "affect_neg", i, "lhs"),
                    "Cannot resolve negative affect target", ERROR_CODES.UNRESOLVED_AFFECT_TARGET
                )
                append!(errors, validate_expression_references(file, affect.rhs, _pointer(path, "affect_neg", i, "rhs")))
            end
        end

        # Validate condition expressions if present (for continuous events)
        if coupling_entry.conditions !== nothing
            for (i, condition) in enumerate(coupling_entry.conditions)
                append!(errors, validate_expression_references(file, condition, _pointer(path, "conditions", i)))
            end
        end

        # Validate trigger expression if present (for discrete events)
        if coupling_entry.trigger !== nothing && isa(coupling_entry.trigger, ConditionTrigger)
            append!(errors, validate_expression_references(file, coupling_entry.trigger.expression, "$path/trigger/expression"))
        end
    end

    return errors
end

"""
    system_exists_in_file(file::EsmFile, system_name::String) -> Bool

Check if a system (model, reaction_system, data_loader, or operator) exists in
the ESM file. Delegates to [`find_top_level_system`](@ref) (types.jl) so the
top-level lookup (models, reaction systems, data loaders) lives in exactly one
place.

A coupling endpoint may name a SUBSYSTEM by its dotted path
(`AtmosphericChemistry.Aerosols`, `EmissionSources.Biogenic.Forest`), which is
the whole point of scoped references (§4.6). Only ever consulting the top-level
tables reported those as `undefined_system` and rejected the valid
tests/valid/scoped_refs_coupling.esm, so the dotted tail is now walked down the
subsystem tree.
"""
function system_exists_in_file(file::EsmFile, system_name::String)::Bool
    system, _ = find_top_level_system(file, system_name)
    system === nothing || return true

    # Dotted path: resolve the head against the top level, then walk the tail
    # through `subsystems`.
    segments = split(system_name, '.')
    length(segments) > 1 || return false
    root, _ = find_top_level_system(file, String(segments[1]))
    root isa Model || return false
    return _subsystem_at(root, segments[2:end]) !== nothing
end
