# The faq checks: index sets, bare array operands, ragged values, joins, relational nodes.

"""
    validate_aggregate_semantics(file::EsmFile) -> Vector{StructuralError}

The static aggregate/relational checks of F-6. Walks every expression site of
the document ([`foreach_expression`](@ref): every model and reaction system and
their subsystems, and the coupling entries) and, for each `faq` node it finds,
applies:

- [`_check_undefined_index_set!`] — a `ranges` `{from: NAME}` whose
  NAME is not a key of the document `index_sets` registry (run only when the
  document DECLARES a registry — see the function for why);
- [`_check_join_key_type!`] — a value-equality `join` key column resolving to a
  categorical set with a float/null member;
- [`_check_relational_in_continuous!`] — a `distinct` node whose key/body reads a
  STATE variable of the model.

Findings attach at the FIELD pointer (`/models/M/equations/i/rhs`, …), the same
convention the reference-integrity pass uses. The `faq_bare_array_operand`
check runs at the same sites; on an equation's right-hand side the names its
left-hand side defines are exempt.
"""
function validate_aggregate_semantics(file::EsmFile; views = nothing)::Vector{StructuralError}
    errors = StructuralError[]
    registry = Set{String}(keys(file.index_sets))
    if file.models !== nothing
        for model_name in sort!(collect(keys(file.models)))
            model = file.models[model_name]
            _check_model_aggregates!(
                errors, file, model,
                _pointer("", "models", model_name), registry
            )
            # A template parameter may stand for a range's `from` (esm-spec §9.6.1),
            # so the index-set name a call binds is checked on the expansion; the
            # pointer still names the authored field.
            view = _units_view(file, model_name, model, views)
            view === model && continue
            reg = get(file.component_templates, "models.$model_name", nothing)
            reg === nothing && continue
            _check_template_index_sets!(errors, model, view, _pointer("", "models", model_name), registry, reg)
        end
    end
    if file.reaction_systems !== nothing
        for rs_name in sort!(collect(keys(file.reaction_systems)))
            _check_reaction_system_aggregates!(
                errors, file, file.reaction_systems[rs_name],
                _pointer("", "reaction_systems", rs_name), registry
            )
        end
    end
    # A coupling entry names other systems' variables by scoped reference, so it
    # has no state set or array shapes of its own.
    no_names = Set{String}()
    no_shapes = Dict{String, Vector{String}}()
    for (i, entry) in enumerate(file.coupling)
        _check_site_aggregates!(
            errors, file, entry, _pointer("", "coupling", i), no_names, registry, no_shapes
        )
    end
    return errors
end

# Per-model driver: compute the model's state-variable set (for the continuous
# relational check) and walk each of its expression sites, then recurse into
# Model subsystems. The `index_sets` registry is document-scoped, so it is
# threaded down unchanged.
function _check_model_aggregates!(
        errors::Vector{StructuralError}, file::EsmFile,
        model::Model, path::String, registry::Set{String}
    )
    _foreach_component(model, path) do m, p, _
        _check_model_aggregates_here!(errors, file, m, p, registry)
    end
    return errors
end

function _check_model_aggregates_here!(
        errors::Vector{StructuralError}, file::EsmFile,
        model::Model, path::String, registry::Set{String}
    )
    # The continuous-relational guard keys off the CONTINUOUS leaves, which
    # are derived: the ODE states plus the algebraic unknowns
    # (CONFORMANCE_SPEC §5.7.2). Observed unknowns are deliberately excluded —
    # a state-free observed is not continuous, and the guard would otherwise
    # reject the const-folding geometry paths that rely on it.
    state_vars = Set{String}(solver_unknowns(model))
    # A join key may name a DATA COLUMN, whose range symbol comes from its
    # declared 1-D shape — so `_check_join_sides!` needs the model's shapes.
    var_shapes = Dict{String, Vector{String}}(
        n => String[String(x) for x in v.shape]
            for (n, v) in model.variables if v.shape !== nothing
    )
    _check_site_aggregates!(errors, file, model, path, state_vars, registry, var_shapes)
    return errors
end

# The reaction-system twin: its species are its continuous states, and its
# parameters the variables that may carry a shape.
function _check_reaction_system_aggregates!(
        errors::Vector{StructuralError}, file::EsmFile,
        rs::ReactionSystem, path::String, registry::Set{String}
    )
    _foreach_component(rs, path) do r, p, _
        _check_reaction_system_aggregates_here!(errors, file, r, p, registry)
    end
    return errors
end

function _check_reaction_system_aggregates_here!(
        errors::Vector{StructuralError}, file::EsmFile,
        rs::ReactionSystem, path::String, registry::Set{String}
    )
    state_vars = Set{String}(sp.name for sp in rs.species)
    var_shapes = Dict{String, Vector{String}}(
        p.name => String[String(x) for x in p.shape]
            for p in rs.parameters if p.shape !== nothing
    )
    _check_site_aggregates!(errors, file, rs, path, state_vars, registry, var_shapes)
    return errors
end

# The site kinds that are an equation's right-hand side, keyed to the kind of
# the left-hand side visited just before it.
const _RHS_OF_LHS = Dict{Symbol, Symbol}(
    :equation_lhs => :equation_rhs, :initialization_lhs => :initialization_rhs,
    :constraint_lhs => :constraint_rhs,
)
const _EQUATION_RHS_KINDS = Set{Symbol}(values(_RHS_OF_LHS))

# The faq checks over the expression sites of one component (not its
# subsystems) or one coupling entry. A left-hand side is visited immediately
# before its right-hand side (`foreach_expression`), so the right-hand side's
# bare-array check exempts what that left-hand side defines.
function _check_site_aggregates!(
        errors::Vector{StructuralError}, file::EsmFile, x, path::String,
        state_vars::Set{String}, registry::Set{String},
        var_shapes::Dict{String, Vector{String}}
    )
    lhs = Ref{Union{ASTExpr, Nothing}}(nothing)
    visit = function (e, anchor, kind)
        if haskey(_RHS_OF_LHS, kind)
            lhs[] = e
        else
            excl = kind in _EQUATION_RHS_KINDS ? lhs[]::ASTExpr : nothing
            _check_faq_bare_array_operands!(errors, excl, e, anchor, var_shapes)
        end
        _walk_aggregates!(errors, file, e, anchor, state_vars, registry, var_shapes)
        return nothing
    end
    if x isa CouplingEntry
        foreach_expression(visit, x, path)
    else
        foreach_expression(visit, x, path; subsystems = false)
    end
    return errors
end

# The `undefined_index_set` check of `_check_undefined_index_set!` on every
# expression site of `model` and its subsystem models (`foreach_expression`)
# that calls a template, read from the expanded `view`. A
# field the view leaves unexpanded is expanded here against `reg`.
function _check_template_index_sets!(
        errors::Vector{StructuralError}, model::Model, view::Model,
        path::String, registry::Set{String}, reg
    )
    templated = Set{String}()
    foreach_expression(model, path) do e, anchor, _
        _contains_template_reference(e) && push!(templated, anchor)
        nothing
    end
    isempty(templated) && return errors
    memo = _ExpandCache()
    foreach_expression(view, path) do e, anchor, _
        anchor in templated || return nothing
        any(x -> x.path == anchor && x.error_type == ERROR_CODES.UNDEFINED_INDEX_SET, errors) &&
            return nothing
        if _contains_template_reference(e)
            e = try
                _expand_expr_refs(e, reg, nothing, memo)
            catch err
                # An unresolvable call is reported by the template checks.
                err isa ExpressionTemplateError || rethrow()
                return nothing
            end
        end
        foreach_subexpr_once(e) do sub
            sub isa OpExpr && sub.op == "faq" && _check_undefined_index_set!(errors, sub, anchor, registry)
            nothing
        end
        return nothing
    end
    return errors
end

# Descend `expr`; at every `faq` node apply the three checks, then recurse
# into the full expression-bearing child set (so a NESTED aggregate is checked
# too). `anchor` is the field pointer and stays constant through the descent —
# a finding attaches at the field, not the leaf.
function _walk_aggregates!(
        errors::Vector{StructuralError}, file::EsmFile,
        expr::ASTExpr, anchor::String, state_vars::Set{String},
        registry::Set{String},
        var_shapes::Dict{String, Vector{String}}
    )
    isa(expr, OpExpr) || return errors
    if expr.op == "faq"
        _check_undefined_index_set!(errors, expr, anchor, registry)
        _check_ragged_values_gathered!(errors, file, expr, anchor)
        _check_join_key_type!(errors, file, expr, anchor)
        _check_join_sides!(errors, expr, anchor, var_shapes)
        _check_relational_in_continuous!(errors, expr, anchor, state_vars)
    end
    for c in child_exprs(expr)
        _walk_aggregates!(errors, file, c, anchor, state_vars, registry, var_shapes)
    end
    return errors
end

# F-6 check: every `{from: NAME}` range of an aggregate must name a declared
# index set. One finding per DISTINCT undeclared name (a set referenced by two
# range symbols is one defect).
#
# Run only when the document DECLARES a registry. A document that declares none
# is a §9.7.10 discretization-agnostic PDE leaf: its index sets arrive from a
# discretization library injected into this component's scope by a composing
# document, a subsystem-ref edge or an inline test (§6.6.6), so the effective
# registry exists only in that per-run build and resolving `{from: NAME}`
# against the empty local registry would reject every conforming leaf. The check
# is deferred there, mirroring §9.6.1's standalone exemption for
# `template_constraint_unknown_index_set`; a name still unresolved once
# injection has run is rejected by the evaluating bindings' resolvers
# (`E_REF_UNDECLARED_INDEX_SET` / `E_TREEWALK_UNDECLARED_INDEX_SET`).
function _check_undefined_index_set!(
        errors::Vector{StructuralError}, agg::OpExpr,
        anchor::String, registry::Set{String}
    )
    (agg.ranges === nothing || isempty(registry)) && return errors
    reported = Set{String}()
    for sym in sort!(collect(keys(agg.ranges)))
        rv = agg.ranges[sym]
        rv isa IndexSetRef || continue
        from = rv.from
        (from in registry || from in reported) && continue
        push!(reported, from)
        _report!(
            errors, ERROR_CODES.UNDEFINED_INDEX_SET,
            anchor,
            "aggregate range '$sym' references index set '$from', which is not " *
                "declared in the document `index_sets` registry",
            Dict{String, Any}("index_set" => from, "range" => sym)
        )
    end
    return errors
end

"""
    faq_bare_array_operands(expr, var_shapes) -> Vector{Tuple{String,String,Vector{String}}}

`faq_bare_array_operand` (esm-spec §4.3.1): every
`(field, name, shape)` where a `faq` node's `expr` or `filter` reads a variable
declared with a non-empty `shape` by BARE name in an elementwise position.

A `faq` names its axes by its range symbols and evaluates its body and filter
once per index tuple, so a whole array there does not say which symbol each of
its axes is. The bindings disagreed about what it meant (Rust's reference kept
every term of a filter it could not align, so a filter over a node with two
output indices was silently ignored; Python's whole-box tiers aligned it to the
last box axis), so it is refused: the read must be `index(name, i, …)`.

The descent enters elementwise nodes only (`_is_elementwise_node`), as the
§4.3.4 alignment rule does; a name a `faq` binds as a loop symbol, here or
further out, shadows the declaration; nested `faq` nodes are checked in their
own right; an `apply_expression_template` application is opaque, so an array
bound to one of its arguments is not a bare read. With `opaque_applications`,
an expansion the load marked as an application (`OpExpr.template_origin`, a
mounted leaf's) is opaque too: that is how `validate` reads the equations as
authored. The build passes `false` and checks what the applications expanded
into, after the elementwise lift (esm-spec §9.6.11). Order: pre-order over nodes,
`expr` before `filter`, operands left to right — the order Rust and Python
report in.
"""
function faq_bare_array_operands(
        expr::ASTExpr, var_shapes::AbstractDict; exclude = (), opaque_applications::Bool = false,
        through_calls::Bool = false
    )
    found = Tuple{String, String, Vector{String}}[]
    shaped = Dict{String, Vector{String}}(
        String(n) => String[String(x) for x in s]
            for (n, s) in var_shapes if !isempty(s) && !(String(n) in exclude)
    )
    isempty(shaped) && return found
    # `through_calls` (the build): a template reference the build compiles as
    # a call (tree_walk/call.jl) is a scalar function of its arguments, so an
    # argument is an operand in place, read the way the body reads its
    # parameter: elementwise. `validate` reads references as opaque.
    opaque = e -> (!through_calls && e.op == "apply_expression_template") ||
        (opaque_applications && e.template_origin !== nothing)
    _faq_bare_walk!(
        found, expr, shaped, Set{String}(), IdDict{Any, Vector{Set{String}}}(), opaque
    )
    return found
end

# Both walks are DAG-safe: a node shared by many parents (a lifted or folded
# chain) is visited once per distinct loop-symbol scope, not once per path, so
# the check stays O(nodes) where a per-path walk is exponential in the depth.
function _faq_bare_operands!(
        out::Vector{String}, e::ASTExpr, shaped, opaque, seen = IdDict{Any, Nothing}()
    )
    if e isa VarExpr
        haskey(shaped, e.name) && push!(out, e.name)
    elseif e isa OpExpr && (_is_elementwise_node(e) || _tpl_is_call(e)) && !opaque(e)
        haskey(seen, e) && return out
        seen[e] = nothing
        for a in _value_operands(e)
            _faq_bare_operands!(out, a, shaped, opaque, seen)
        end
    end
    return out
end

function _faq_bare_walk!(found, e::ASTExpr, shaped, bound::Set{String}, visited, opaque)
    (e isa OpExpr && !opaque(e)) || return found
    scopes = get!(() -> Set{String}[], visited, e)
    any(==(bound), scopes) && return found
    push!(scopes, bound)
    if e.op == "faq"
        bound = copy(bound)
        e.output_idx === nothing || foreach(s -> push!(bound, string(s)), e.output_idx)
        e.ranges === nothing || foreach(s -> push!(bound, string(s)), keys(e.ranges))
        for (field, part) in (("expr", e.expr_body), ("filter", e.filter))
            part === nothing && continue
            seen = Set{String}()
            for name in _faq_bare_operands!(String[], part, shaped, opaque)
                (name in bound || name in seen) && continue
                push!(seen, name)
                push!(found, (field, name, shaped[name]))
            end
        end
    end
    for c in child_exprs(e)
        _faq_bare_walk!(found, c, shaped, bound, visited, opaque)
    end
    return found
end

"""The `faq_bare_array_operand` message, shared by `validate` and the build."""
faq_bare_array_operand_message(field::AbstractString, name::AbstractString, shape) =
    "faq `$field` reads '$name', declared over [$(join(shape, ", "))], by bare name. " *
    "A faq names its axes by its range symbols, and its `$field` is evaluated once " *
    "per index tuple, so a whole array there does not say which symbol each of its " *
    "axes is. Read it through `index`, e.g. index($name, <symbol>…) (esm-spec §4.3.1)"

"""
    faq_bare_exempt_names(lhs) -> Set{String}

The names `faq_bare_array_operand` skips for an equation with left-hand side
`lhs`: every name an observed or recurrence definition's LHS names, whose bare
self-read `recurrence_not_wellfounded` or `observed_cycle` reports (one defect,
one finding); none for a derivative — `D(y)`, or the array-equation
`faq[i](D(y[i]))` — whose bare state read no other check reports.
"""
function faq_bare_exempt_names(lhs::ASTExpr)
    derivative = false
    foreach_subexpr_once(lhs) do e
        e isa OpExpr && e.op == "D" && (derivative = true)
        nothing
    end
    return derivative ? Set{String}() : _referenced_var_names(lhs, Set{String}())
end

# `lhs` is the left-hand side of the equation whose right-hand side `expr` is,
# or `nothing` for a site that is not an equation's right-hand side.
function _check_faq_bare_array_operands!(
        errors::Vector{StructuralError}, lhs::Union{ASTExpr, Nothing}, expr::ASTExpr,
        anchor::String, var_shapes
    )
    defined = lhs === nothing ? Set{String}() : faq_bare_exempt_names(lhs)
    found = faq_bare_array_operands(
        expr, var_shapes; exclude = defined, opaque_applications = true
    )
    for (field, name, shape) in found
        _report!(
            errors, ERROR_CODES.FAQ_BARE_ARRAY_OPERAND,
            anchor,
            faq_bare_array_operand_message(field, name, shape),
            Dict{String, Any}("field" => field, "variable" => name, "shape" => shape)
        )
    end
    return errors
end

# A value-invention `faq` (a `distinct` producer, or a `distinct` body). Over
# such a node a ragged range binds the MEMBER `values[parent, k]` itself
# (esm-spec §4.3.1 "Ragged ranges"), so its `values` gather is implicit rather
# than authored.
function _is_value_invention_faq(agg::OpExpr)
    agg.distinct === true && return true
    return agg.expr_body isa OpExpr && agg.expr_body.op == "distinct"
end

# Whether `expr` holds a surviving `apply_expression_template` reference
# (esm-spec §9.6.4), whose body a static walk of this document cannot see.
function _contains_template_reference(expr::ASTExpr)
    found = false
    foreach_subexpr_once(expr) do e
        e isa OpExpr && e.op == "apply_expression_template" && (found = true)
        nothing
    end
    return found
end

# esm-spec §4.3.1 "Ragged ranges": a range over a `kind: "ragged"`
# index set binds the POSITION k in 1..offsets[parent], never a member, so a
# body (`expr` / `filter`) that never reads the set's `values` array reads
# positions where the author meant members. One finding per such range.
#
# Not decided for a value-invention node, which binds the member itself, nor for
# a body that still holds a template reference, which may do the gather out of
# sight. A set the document does not declare (a §9.7.10 agnostic leaf) is left
# to the build, as `_check_undefined_index_set!` does.
function _check_ragged_values_gathered!(
        errors::Vector{StructuralError}, file::EsmFile,
        agg::OpExpr, anchor::String
    )
    (agg.ranges === nothing || isempty(file.index_sets)) && return errors
    _is_value_invention_faq(agg) && return errors
    body = ASTExpr[b for b in (agg.expr_body, agg.filter) if b !== nothing]
    any(_contains_template_reference, body) && return errors
    refs = Set{String}()
    for b in body
        _referenced_var_names(b, refs)
    end
    for sym in sort!(collect(keys(agg.ranges)))
        rv = agg.ranges[sym]
        rv isa IndexSetRef || continue
        iset = get(file.index_sets, rv.from, nothing)
        (iset isa IndexSet && iset.kind == "ragged" && iset.values !== nothing) || continue
        values = iset.values::String
        any(r -> r == values || endswith(r, "." * values), refs) && continue
        parent = isempty(rv.of) ? "<parent>" : join(rv.of, ", ")
        _report!(
            errors, ERROR_CODES.RAGGED_VALUES_NOT_GATHERED,
            anchor,
            "faq range '$sym' iterates ragged index set '$(rv.from)', so it binds the " *
                "POSITION k in 1..$(something(iset.offsets, "offsets"))[$parent], not a " *
                "member; the body never reads the set's `values` array '$values'. Gather " *
                "the member explicitly: index($values, $parent, $sym)",
            Dict{String, Any}("range" => sym, "index_set" => rv.from, "values" => values)
        )
    end
    return errors
end

# The two static `join` SIDE checks of CONFORMANCE_SPEC §5.5.8, decidable from
# this ONE document — the node's `ranges`, the declared variable shapes and the
# clause itself are all here, so no evaluation, no runtime data and no other file
# are needed. Both are stated about the DOCUMENT rather than about where any one
# implementation happens to resolve a join, which is what lets all five bindings
# pin the same fixtures (tests/invalid/expected_errors.json).
#
#  * JOIN_SYMS_UNKNOWN_SYMBOL — a clause's `syms` entry that is not a key of the
#    node's `ranges`. Unchecked, that side resolves to no symbol at all and RFC
#    §5.3's degenerate-positional rule silently DROPS the pair: an ungated full
#    product, reported as a number rather than as a failure.
#  * JOIN_SIDE_AMBIGUOUS — an `on` key for which the document does not determine
#    a range symbol. A key names a range symbol, an index set, or a declared 1-D
#    variable; in the latter two the symbol comes from the index set (named
#    outright, or the variable's sole shape axis). If that set is drawn `{from}`
#    by more than one of the node's ranges and the clause carries no `syms`, the
#    key does not say which. TWO candidates are resolved by the default side
#    assignment only when the key is a DATA COLUMN — a key naming the index set
#    can already say which side it means by naming the range symbol instead, so
#    that spelling is ambiguous at two as well.
#
# One finding per aggregate.
function _check_join_sides!(
        errors::Vector{StructuralError}, agg::OpExpr,
        anchor::String,
        var_shapes::Dict{String, Vector{String}}
    )
    (agg.join === nothing || agg.ranges === nothing) && return errors
    ranges = agg.ranges
    set_to_syms = Dict{String, Vector{String}}()
    for (sym, spec) in ranges
        spec isa IndexSetRef || continue
        push!(get!(set_to_syms, spec.from, String[]), String(sym))
    end
    for v in values(set_to_syms)
        sort!(v)
    end

    for clause in agg.join
        clause isa AbstractVector || continue      # an overlap clause gates no key
        csyms = _clause_syms(clause)
        if csyms !== nothing
            for cs in csyms
                haskey(ranges, cs) && continue
                _report!(
                    errors, ERROR_CODES.JOIN_SYMS_UNKNOWN_SYMBOL,
                    anchor,
                    "aggregate join `syms` names '$cs', which is not a range symbol of " *
                        "this aggregate; both entries must name one of its `ranges`",
                    Dict{String, Any}(
                        "join_syms_entry" => cs,
                        "declared_ranges" => sort!(String[String(k) for k in keys(ranges)])
                    )
                )
                return errors
            end
            continue      # an explicit `syms` answers every pair of this clause
        end
        for pair in clause
            (pair isa Tuple && length(pair) == 2) || continue
            for (side, key) in (("left", String(pair[1])), ("right", String(pair[2])))
                haskey(ranges, key) && continue        # names a range symbol outright
                set_name, via_column = if haskey(set_to_syms, key)
                    (key, false)
                else
                    shape = get(var_shapes, key, nothing)
                    (shape === nothing || length(shape) != 1) && continue
                    (String(shape[1]), true)
                end
                cands = get(set_to_syms, set_name, nothing)
                cands === nothing && continue
                # One candidate: the ordinary join of two distinct relations.
                # Two: the default assignment, but only for a data column.
                # Three or more: never.
                (length(cands) < 2 || (length(cands) == 2 && via_column)) && continue
                msg = via_column ?
                    "aggregate join key column '$key' lives on index set '$set_name', which " *
                    "$(length(cands)) range symbols of this aggregate draw, so the document " *
                    "does not determine which one the key is read at; name the clause's two " *
                    "sides with `syms`" :
                    "aggregate join key '$key' names an index set that $(length(cands)) range " *
                    "symbols of this aggregate draw; reference the range symbol directly, or " *
                    "name the clause's two sides with `syms`"
                _report!(
                    errors, ERROR_CODES.JOIN_SIDE_AMBIGUOUS,
                    anchor,
                    msg,
                    Dict{String, Any}(
                        "join_key" => key, "side" => side,
                        "index_set" => set_name,
                        "candidate_range_symbols" => cands
                    )
                )
                return errors
            end
        end
    end
    return errors
end

# F-6 check: a value-equality `join` may not key on a categorical index set with
# a float or null member — a float repr is not portable across bindings and a
# null key is unmatchable (RFC semiring-faq-unified-ir §5.3). One finding per
# aggregate (the first offending key column).
function _check_join_key_type!(
        errors::Vector{StructuralError}, file::EsmFile,
        agg::OpExpr, anchor::String
    )
    (agg.join === nothing || agg.ranges === nothing) && return errors
    cols = String[]
    for clause in agg.join
        clause isa AbstractVector || continue
        for pair in clause
            (pair isa Tuple && length(pair) == 2) || continue
            push!(cols, String(pair[1]))
            push!(cols, String(pair[2]))
        end
    end
    for sym in cols
        rv = get(agg.ranges, sym, nothing)
        rv isa IndexSetRef || continue
        iset = get(file.index_sets, rv.from, nothing)
        iset === nothing && continue
        _index_set_has_nonportable_key(iset) || continue
        _report!(
            errors, ERROR_CODES.JOIN_KEY_INVALID_TYPE,
            anchor,
            "aggregate join key column '$sym' ranges over categorical index set " *
                "'$(rv.from)', whose members include a non-portable float/null key " *
                "(value-equality join keys must be integers or strings)",
            Dict{String, Any}("index_set" => rv.from, "column" => sym)
        )
        return errors   # one finding per aggregate is enough
    end
    return errors
end

# A categorical index set whose ORIGINAL members include a float or a JSON null.
# `members_raw` is populated by the parser ONLY when some member is non-string,
# so a string-only (or int-only) set never trips this. Ints and strings are fine.
function _index_set_has_nonportable_key(iset::IndexSet)::Bool
    iset.kind == "categorical" || return false
    iset.members_raw === nothing && return false
    return any(
        m -> (m isa AbstractFloat) || (m === nothing) || (m === missing),
        iset.members_raw
    )
end

# F-6 check: a `distinct` (value-invention / relational) aggregate whose
# key / body / filter reads a declared STATE variable classifies CONTINUOUS
# (class = max over inputs; a state input is continuous), and a relational engine
# may not run on the per-step hot path (§5.7 guard 2). This is the direct-read
# form the other bindings' validators share: a state read in the
# `key`/`expr`/`filter` subtrees. The build applies the transitive form
# (`continuous_relational_nodes`, cadence.jl), which also follows observed
# definitions and `t`. A `distinct` set former over CONST mesh/parameter literals
# (tests/valid/cadence/pure_topology.esm) stays valid under both.
function _check_relational_in_continuous!(
        errors::Vector{StructuralError}, agg::OpExpr,
        anchor::String, state_vars::Set{String}
    )
    (agg.distinct === true && !isempty(state_vars)) || return errors
    refs = Set{String}()
    agg.key === nothing || _referenced_var_names(agg.key, refs)
    agg.expr_body === nothing || _referenced_var_names(agg.expr_body, refs)
    agg.filter === nothing || _referenced_var_names(agg.filter, refs)
    hits = intersect(refs, state_vars)
    isempty(hits) && return errors
    hit = first(sort!(collect(hits)))
    _report!(
        errors, ERROR_CODES.RELATIONAL_NODE_IN_CONTINUOUS,
        anchor,
        "distinct/value-invention aggregate reads state variable '$hit' in its " *
            "key/body, classifying it CONTINUOUS — a relational node may not run on " *
            "the per-step hot path (§5.7 guard 2)",
        Dict{String, Any}("variable" => hit)
    )
    return errors
end
