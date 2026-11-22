# Selection (API_SPEC §5.8, "Selection"): one operator of a program, as a pure
# rewrite of its flattened system — the summands a term-provenance selection
# keeps, writing only the operator's variables. `select` (rhs_program.jl) builds
# the result.

_origin_str(o::TermOrigin) = o.component !== nothing ? "{component: $(o.component)}" :
    "{coupling: $(o.coupling)}"

# The state a flattened equation's left-hand side differentiates, or `nothing`
# for an equation that is not a `D` equation.
function _d_target(lhs::ASTExpr)
    body = lhs
    if body isa OpExpr && _is_faq_op((body::OpExpr).op) && (body::OpExpr).expr_body !== nothing
        body = (body::OpExpr).expr_body
    end
    (body isa OpExpr && (body::OpExpr).op == "D" && length((body::OpExpr).args) == 1) ||
        return nothing
    a = (body::OpExpr).args[1]
    a isa VarExpr && return (a::VarExpr).name
    (
        a isa OpExpr && (a::OpExpr).op == "index" && !isempty((a::OpExpr).args) &&
            (a::OpExpr).args[1] isa VarExpr
    ) && return ((a::OpExpr).args[1]::VarExpr).name
    return nothing
end

_normalize_terms(terms::Symbol) = terms === :all ? :all :
    throw(ArgumentError("select: `terms` is `:all` or a vector of TermOrigin, got :$terms"))
function _normalize_terms(terms)
    out = TermOrigin[]
    for t in terms
        t isa TermOrigin || throw(
            ArgumentError(
                "select: `terms` is `:all` or a vector of TermOrigin, got an element $(repr(t))"
            )
        )
        push!(out, t)
    end
    return out
end

# The selected flattened system (rules 1–3 of "Selection") and the state names
# its kept rules read, directly or through observeds.
#
# `writable` is the set `writes` draws from: every state of `flat` for the
# Problem's whole model, a program's own written variables for a selection of
# a selection (whose other states are read-only `aux`).
function _select_flat(
        flat::FlattenedSystem, writes, terms,
        writable = Set{String}(keys(flat.state_variables))
    )
    states = flat.state_variables
    W = Set{String}()
    if writes === :all
        union!(W, writable)
    else
        for w in writes
            ws = String(w)
            ws in writable || throw(
                SimulateError(
                    "select: `writes` names '$ws', which is not a variable this program " *
                        "writes; it writes $(join(sort!(collect(writable)), ", "))",
                    ERROR_CODES.UNDEFINED_VARIABLE
                )
            )
            push!(W, ws)
        end
    end
    keep(c::Contribution) = terms === :all ||
        any(o -> o in terms, c.origins)
    eqs = Equation[]
    contribs = Vector{Contribution}[]
    for (eq, cs) in zip(flat.equations, flat.equation_contributions)
        tgt = _d_target(eq.lhs)
        if tgt === nothing
            push!(eqs, eq)
            push!(contribs, cs)
            continue
        end
        kept = Contribution[c for c in cs if keep(c)]
        if !(tgt in W)
            isempty(kept) || throw(
                _range_error(
                    ERROR_CODES.RANGE_SELECTION_WRITES_INCOMPLETE,
                    "select: '$tgt' has kept contributions authored by " *
                        join(unique!([_origin_str(o) for c in kept for o in c.origins]), ", ") *
                        " but is not in `writes`; add '$tgt' to `writes` or drop those terms"
                )
            )
            continue
        end
        lifted = _is_lifted(eq, flat.lifted_shapes)
        if isempty(kept)
            # An operator that does not touch a variable it writes: rhs 0.
            zero = Contribution[Contribution(NumExpr(0.0), TermOrigin[])]
            push!(eqs, _equation_from(eq, zero, lifted))
            push!(contribs, zero)
        elseif length(kept) == length(cs)
            push!(eqs, eq)
            push!(contribs, cs)
        else
            push!(eqs, _equation_from(eq, kept, lifted))
            push!(contribs, kept)
        end
    end
    # ---- the states and observeds the kept rules reach ----
    # Read through every surviving template reference without expanding it
    # (esm-spec §9.6.4 rule 2): each reference carries, as implicit bindings,
    # the names its body reads from its caller (`_tpl_augment`).
    xeqs = _tpl_augmented_equations(eqs, flat.template_registry)
    defs = Dict{String, Vector{ASTExpr}}()
    roots = Set{String}()
    for eq in xeqs
        if _d_target(eq.lhs) !== nothing
            _referenced_var_names(eq.rhs, roots)
        elseif eq.lhs isa VarExpr
            push!(get!(() -> ASTExpr[], defs, (eq.lhs::VarExpr).name), eq.rhs)
        else
            _referenced_var_names(eq.lhs, roots)
            _referenced_var_names(eq.rhs, roots)
        end
    end
    reached = Set{String}()
    todo = collect(roots)
    while !isempty(todo)
        n = pop!(todo)
        n in reached && continue
        push!(reached, n)
        for d in get(defs, n, ASTExpr[])
            for r in _referenced_var_names(d)
                r in reached || push!(todo, r)
            end
        end
    end
    R = Set{String}(n for n in reached if haskey(states, n))
    live_states = union(W, R)
    live = union(reached, live_states)
    # ---- drop what no kept rule reaches ----
    eqs2 = Equation[]
    contribs2 = Vector{Contribution}[]
    for (eq, cs) in zip(eqs, contribs)
        if _d_target(eq.lhs) === nothing && eq.lhs isa VarExpr &&
                !((eq.lhs::VarExpr).name in live)
            continue
        end
        push!(eqs2, eq)
        push!(contribs2, cs)
    end
    filt(d) = OrderedDict{String, ModelVariable}(k => v for (k, v) in d if k in live)
    flat2 = FlattenedSystem(
        flat;
        state_variables = OrderedDict{String, ModelVariable}(
            k => v for (k, v) in states
                if k in live_states
        ),
        observed_variables = filt(flat.observed_variables),
        algebraic_variables = OrderedDict{String, ModelVariable}(
            k => v for (k, v) in flat.algebraic_variables if k in live_states
        ),
        equations = eqs2,
        field_ics = Pair{String, ASTExpr}[p for p in flat.field_ics if first(p) in live_states],
        lifted_shapes = OrderedDict{String, Vector{Int}}(
            k => v for (k, v) in flat.lifted_shapes if k in live_states
        ),
        equation_contributions = contribs2
    )
    return flat2, W, R
end

# The faq initialization equations whose target the selection kept.
function _select_init(init::Vector{Equation}, live_states)
    out = Equation[]
    for eq in init
        refs = _referenced_var_names(eq.lhs)
        any(r -> r in live_states, refs) && push!(out, eq)
    end
    return out
end
