# Equation-unknown balance and the left-hand-side names it counts.

# ============================================================================
# Helper Functions for Structural Validation
# ============================================================================

"""
    model_subsystems(model::Model)

Iterator over the `(name, subsystem)` pairs of `model.subsystems` whose value
is itself a `Model`. Model subsystems may also hold an unresolved `SubsystemRef`,
which carries no model semantics for the model-specific validators — this helper
skips it once, instead of every recursion site repeating the
`subsys isa Model || continue` boilerplate.
"""
model_subsystems(model::Model) =
    (pair for pair in model.subsystems if pair.second isa Model)

"""
    _foreach_component(f, node, path; sorted = false, scope = nothing)

Call `f(component, path, key)` for `node` and for every subsystem below it of
its own kind (a `Model` below a model, a `ReactionSystem` below a reaction
system), parent before children: `path` is the component's JSON pointer, each
subsystem's extending its parent's by `/subsystems/<key>` (escaped), and `key` is its
`subsystems` key (`nothing` for `node`). Siblings come in document order, or
by key with `sorted`. With `scope`, the dotted scoped name of `node`
(`"Atmos"`), `f(component, path, key, scope)` is called instead, each
subsystem's scope extending its parent's by `.<key>`. The one walk of a
component tree the structural checks share.
"""
function _foreach_component(
        f, node::T, path::AbstractString; sorted::Bool = false, key = nothing,
        scope::Union{Nothing, AbstractString} = nothing
    ) where {T <: Union{Model, ReactionSystem}}
    scope === nothing ? f(node, String(path), key) : f(node, String(path), key, String(scope))
    subs = Pair{String, T}[k => v for (k, v) in node.subsystems if v isa T]
    sorted && sort!(subs; by = first)
    for (k, sub) in subs
        _foreach_component(
            f, sub, _pointer(path, "subsystems", k); sorted = sorted, key = k,
            scope = scope === nothing ? nothing : string(scope, ".", k)
        )
    end
    return nothing
end

# The component the dotted `path` segments name below `c`, walking
# `subsystems` one segment at a time through components of `c`'s own kind;
# `nothing` when a segment is missing or names anything else (an unresolved
# mount, a component of the other kind). The one walk of a scoped path.
function _subsystem_at(c::T, path) where {T <: Union{Model, ReactionSystem}}
    for seg in path
        next = get(c.subsystems, String(seg), nothing)
        next isa T || return nothing
        c = next
    end
    return c
end

"""
    _equation_lhs_names(lhs::ASTExpr) -> Set{String}

The names an equation's LHS *solves for*. The LHS is not always a bare variable:
the corpus spells the same "define `u`" in five shapes, and a balance check
must understand all of them or it reports a false `missing_equation`.

Recognised shapes, in the order they nest:

| LHS | solves for |
|---|---|
| `"u"` (bare) | `u` |
| `D(u, t)` | `u` |
| `index(u, i)` / `index(D(u), i)` | `u` (an element assignment defines the array) |
| `aggregate{output_idx: [i], expr: D(index(u,i))}` | `u` (a vectorised ODE) |
| `H*H*SO4 = Ksp` (implicit/algebraic) | every bare variable on the LHS |

`ic(u)` is deliberately NOT a defining equation — an initial condition
constrains `u`'s value at t₀, it does not supply `u`'s dynamics — so it returns
the empty set and cannot satisfy a state variable's balance obligation.

Dotted (cross-system) names are excluded: they are the qualified-reference
resolver's business, not this model's balance.
"""
function _equation_lhs_names(lhs::ASTExpr)::Set{String}
    names = Set{String}()
    _collect_lhs_names!(names, lhs)
    return names
end

function _collect_lhs_names!(names::Set{String}, e::ASTExpr)
    if e isa VarExpr
        occursin('.', e.name) || push!(names, e.name)
    elseif e isa OpExpr
        if e.op == "ic"
            # Initial condition: constrains a value, does not define dynamics.
            return names
        elseif e.op in ("D", "index") && !isempty(e.args)
            # Structural wrappers: the solved-for name is the head operand.
            _collect_lhs_names!(names, e.args[1])
        elseif e.op == "faq" && e.expr_body !== nothing
            # Vectorised equation: the body is the real LHS.
            _collect_lhs_names!(names, e.expr_body)
        else
            # Implicit / algebraic LHS (`H*H*SO4 = Ksp`): any bare variable on
            # the LHS is a candidate unknown this equation constrains.
            for a in e.args
                _collect_lhs_names!(names, a)
            end
        end
    end
    return names
end

"""
    validate_model_balance(model::Model, path::String) -> Vector{StructuralError}

Validate the equation/unknown balance of a model (esm-spec §4.9.4).

The balance is stated over UNKNOWNS and EQUATIONS, not over a
declared `state` type: an unknown's behaviour is given by the equations and
nowhere else, so a model is well-determined exactly when it writes one equation
per unknown. An equation counts whichever LHS form it takes — a derivative
(`D(u,t)`), a bare variable (`y ~ f(…)`), or an expression (`H*H*SO4 ~ Ksp`) —
because all three determine the unknowns they name. An `ic` LHS prescribes an
initial value rather than dynamics and does not count.

An observed unknown with nothing defining it is an unbalanced system, and
`missing_equations_for` names it.

Reported at the MODEL's pointer (`/models/<M>`) under `equation_count_mismatch`
— a balance is a property of the model, not of any one equation.

Two exemptions carry over, and both are one-directional:

- A model **with subsystems** is exempt from the SHORTFALL direction: its
  dynamics may live in a subsystem (`tests/valid/scoped_refs_coupling.esm`
  declares unknowns and `equations: []` for exactly this reason).
- `check_excess=false` exempts the SURPLUS direction. It is passed for a model
  participating in an `operator_compose` coupling: such a model is an OPERATOR,
  and its equations act on the unknowns of the system it is composed onto, not
  on unknowns of its own. `tests/valid/minimal_chemistry.esm` is the canonical
  shape — `Advection` declares only parameters and writes `D(u) ~ …`, where `u`
  is the advected field the composition supplies.
"""
function validate_model_balance(
        model::Model, path::String; check_excess::Bool = true
    )::Vector{StructuralError}
    # The operator exemption is inherited: a subsystem of an operator still
    # acts on the composed system's state.
    errors = StructuralError[]
    _foreach_component(model, path) do m, p, _
        append!(errors, _validate_model_balance_here(m, p; check_excess = check_excess))
    end
    return errors
end

function _validate_model_balance_here(
        model::Model, path::String;
        check_excess::Bool = true
    )::Vector{StructuralError}
    errors = StructuralError[]

    unknown_list = unknowns(model)
    n_unknowns = length(unknown_list)

    # An initialization equation (one that mentions `ic`, esm-spec §4.9.4,
    # §11.4.3) holds at t0 only: it has its own balance and does not count here.
    n_eqs = count(eq -> !_is_initialization_equation(eq), model.equations)

    # Names credited by the model's own equation left-hand sides.
    equation_vars = Set{String}()
    for eq in model.equations
        _is_initialization_equation(eq) && continue
        union!(equation_vars, _equation_lhs_names(eq.lhs))
    end
    missing_for = String[u for u in unknown_list if !(u in equation_vars)]

    has_subsystems = !isempty(model.subsystems)
    shortfall = n_unknowns - n_eqs

    report = (shortfall > 0 && !has_subsystems) || (shortfall < 0 && check_excess)
    if report
        details = Dict{String, Any}("unknowns" => unknown_list, "equations" => n_eqs)
        isempty(missing_for) || (details["missing_equations_for"] = missing_for)
        _report!(
            errors, ERROR_CODES.EQUATION_COUNT_MISMATCH,
            path,
            "Number of equations ($n_eqs) does not match number of unknowns ($n_unknowns)",
            details
        )
    elseif !has_subsystems && !isempty(missing_for)
        # Square by COUNT but not by assignment: some unknown has nothing
        # crediting it while some equation credits a name the model does not
        # declare. Same defect class, same code — the count alone cannot say it.
        _report!(
            errors, ERROR_CODES.EQUATION_COUNT_MISMATCH,
            path,
            "Model declares unknown '$(first(missing_for))' but has no defining " *
                "equation for it",
            Dict{String, Any}(
                "unknowns" => unknown_list, "equations" => n_eqs,
                "missing_equations_for" => missing_for
            )
        )
    end


    return errors
end

"""
    _validate_ic_overdetermination(model, path, sizes) -> Vector{StructuralError}

esm-spec §11.4.3 "What `validate` reports": the over-determination a document
shows by itself, before any supplied value. The initialization equations of
`model` that are not explicit initial conditions count at least one scalar
equation each; the distinct starting values they mention that no explicit
initial condition of the model sets count their declared element count. More
equations than starting values is reported as `ic_system_unbalanced`. A
starting value whose count the document does not settle (an observed's or a
tendency's, which expand at build; a scoped one; an unresolved shape) counts
as unbounded, so nothing is reported for it. Everything else in the balance is
the build's.
"""
function _validate_ic_overdetermination(
        model::Model, path::String, sizes::AbstractDict
    )::Vector{StructuralError}
    errors = StructuralError[]
    sys = Equation[eq for eq in model.equations if _is_initialization_equation(eq) && !_is_explicit_ic(eq)]
    isempty(sys) && return errors
    explicit = Set{String}(
        _ic_lhs_variable(_oriented_ic(eq).lhs) for eq in model.equations if _is_explicit_ic(eq)
    )
    obs = keys(observed_definitions(model))
    names = String[]
    for eq in sys, side in (eq.lhs, eq.rhs), (n, is_d) in _ic_reads(side)
        (is_d || n in obs || occursin('.', n)) && return errors
        n in explicit || n in names || push!(names, n)
    end
    n_values = 0
    for n in names
        v = get(model.variables, n, nothing)
        v === nothing && return errors
        if v.shape === nothing || isempty(v.shape)
            n_values += 1
        else
            c = 1
            for s in v.shape
                sz = get(sizes, String(s), nothing)
                sz === nothing && return errors
                c *= sz
            end
            n_values += c
        end
    end
    length(sys) > n_values || return errors
    _report!(
        errors, ERROR_CODES.IC_SYSTEM_UNBALANCED, path,
        "The initialization system is over-determined: $(length(sys)) initialization " *
            "equation(s) that are not explicit initial conditions mention " *
            "$(n_values) starting value(s) that no explicit initial condition sets " *
            "(esm-spec §11.4.3)",
        Dict{String, Any}("equations" => length(sys), "starting_values" => names)
    )
    return errors
end
