# Derived classification of a model's variables — esm-spec §6.3.1.
#
# esm 1.0.0 declares TWO variable types, `unknown` and `parameter`, and nothing
# else. Every finer category a solver needs is DERIVED from the equations and
# from the parameters' `distribution` / `update`, never declared. This file is
# the one place that derivation lives; every site that used to branch on
# `variable.type == "state"` / `"observed"` / `"brownian"` / `"discrete"` calls
# into it instead.
#
# The functions here are the cross-binding contract: all five bindings expose
# the same set, spelled in their own idiom, and
# `tests/conformance/classification/` pins one answer for all of them.

"""
    unknown_names(model::Model) -> Vector{String}

Every `unknown` declared by `model`, sorted lexicographically. The union of
[`ode_states`](@ref), [`observed_unknowns`](@ref) and
[`algebraic_unknowns`](@ref), which partition it.
"""
unknown_names(model::Model)::Vector{String} =
    sort!(String[n for (n, v) in model.variables if v.type == UnknownVariable])

"""
    parameter_names(model::Model) -> Vector{String}

Every `parameter` declared by `model`, sorted lexicographically. The union of
[`brownian_parameters`](@ref), [`discrete_parameters`](@ref),
[`sampled_parameters`](@ref) and [`constant_parameters`](@ref), which partition
it.
"""
parameter_names(model::Model)::Vector{String} =
    sort!(String[n for (n, v) in model.variables if v.type == ParameterVariable])

# ── Equation-LHS shapes ─────────────────────────────────────────────────────
#
# An equation says what it defines through the SHAPE of its left-hand side, and
# the corpus spells "define u" in several nested shapes. `_lhs_role` reduces
# them to three answers:
#
# | LHS | role |
# |---|---|
# | `D(u, t)`, `D(u[i])`, `aggregate{expr: D(index(u,i))}` | `(:derivative, "u")` |
# | `"y"`, `index(y,i)`, `aggregate{expr: index(y,i)}` | `(:definition, "y")` |
# | `ic(u)` | `(:none, "")` — an initial condition defines no dynamics |
# | `H*H*SO4`, `laplacian(phi)`, anything else | `(:implicit, "")` |

"""Strip the array-addressing wrappers (`index` / `arrayop`) and the
vectorising `aggregate` from an LHS, returning the node they address."""
function _lhs_unwrap(e::ASTExpr)::ASTExpr
    while e isa OpExpr
        if e.op == "aggregate" && e.expr_body !== nothing
            e = e.expr_body
        elseif (e.op == "index" || e.op == "arrayop") && !isempty(e.args)
            e = e.args[1]
        else
            return e
        end
    end
    return e
end

"""True iff `e` is a STRUCTURAL time derivative — a `D` whose `wrt` is `"t"` or
absent (esm-spec §4.2: an absent `wrt` means `t`)."""
_is_time_derivative(e::ASTExpr)::Bool =
    e isa OpExpr && e.op == "D" && (e.wrt === nothing || e.wrt == "t")

"""True iff `e` is a SPATIAL derivative — a `D` whose `wrt` is present and is
not `"t"`, or one of the `grad` / `div` / `laplacian` sugar ops (esm-spec
§6.3.1). Both spellings count: they are open-tier rewrite targets, so neither
is canonical."""
_is_spatial_derivative(e::ASTExpr)::Bool =
    e isa OpExpr && ((e.op == "D" && e.wrt !== nothing && e.wrt != "t") ||
                     e.op == "grad" || e.op == "div" || e.op == "laplacian")

"""
    _lhs_role(lhs::ASTExpr) -> Tuple{Symbol,String}

The role an equation's LHS plays in classification: `(:derivative, base)`,
`(:definition, base)`, `(:none, "")` for an `ic` LHS, or `(:implicit, "")` for
an expression LHS that constrains its operands only implicitly.
"""
function _lhs_role(lhs::ASTExpr)::Tuple{Symbol,String}
    head = _lhs_unwrap(lhs)
    # A DOTTED name is not rejected here. In a FLATTENED system every variable
    # key is `<ModelPath>.<name>`, so rejecting dots would leave a flattened
    # model with no states and no observeds at all. Whether the name belongs to
    # this model is decided by the caller's `model.variables` lookup, which also
    # filters out a genuinely cross-system target in an unflattened document.
    head isa VarExpr && return (:definition, head.name)
    head isa OpExpr || return (:implicit, "")
    head.op == "ic" && return (:none, "")
    if _is_time_derivative(head) && !isempty(head.args)
        base = _lhs_unwrap(head.args[1])
        base isa VarExpr && return (:derivative, base.name)
        return (:implicit, "")
    end
    return (:implicit, "")
end

# ── The three unknown sets (they partition) ─────────────────────────────────

"""
    ode_states(model::Model) -> Vector{String}

The unknowns appearing under `D(·, t)` on some equation LHS — the quantities
the solver integrates (esm-spec §6.3.1). Sorted lexicographically.

A derivative LHS may be wrapped: `D(u)`, `D(u[i])`, and an `aggregate` whose
body is a `D(…)` all credit the base variable.

This replaces every 0.x `variable.type == "state"` test.
"""
function ode_states(model::Model)::Vector{String}
    out = Set{String}()
    for eq in model.equations
        role, name = _lhs_role(eq.lhs)
        role === :derivative || continue
        v = get(model.variables, name, nothing)
        v !== nothing && v.type == UnknownVariable && push!(out, name)
    end
    return sort!(collect(out))
end

"""
    is_ode_state(model::Model, name::AbstractString) -> Bool

Membership test for [`ode_states`](@ref) — the direct replacement for a 0.x
`variable.type == "state"` branch.
"""
function is_ode_state(model::Model, name::AbstractString)::Bool
    v = get(model.variables, String(name), nothing)
    (v !== nothing && v.type == UnknownVariable) || return false
    for eq in model.equations
        role, n = _lhs_role(eq.lhs)
        role === :derivative && n == name && return true
    end
    return false
end

"""
    observed_definitions(model::Model) -> Dict{String,ASTExpr}

Each observed unknown mapped to its DEFINING EQUATION's right-hand side.

This is where the 1.0.0 relocation lands: an observed's definition used to live
in `variables[v].expression` and now lives in the model's `equations` array, as
the bare-variable-LHS equation whose LHS names it. Every site that read
`var.expression` for an observed reads this instead.

An unknown that is also an ODE state is excluded (a `D(y)` equation defines
`y`'s dynamics, not `y` itself). Where more than one equation has the same
bare-variable LHS the FIRST wins, matching the reference implementation.
"""
function observed_definitions(model::Model)::Dict{String,ASTExpr}
    states = Set(ode_states(model))
    defs = Dict{String,ASTExpr}()
    for eq in model.equations
        role, name = _lhs_role(eq.lhs)
        role === :definition || continue
        name in states && continue
        v = get(model.variables, name, nothing)
        (v !== nothing && v.type == UnknownVariable) || continue
        haskey(defs, name) || (defs[name] = eq.rhs)
    end
    return defs
end

"""
    observed_definition(model::Model, name::AbstractString) -> Union{ASTExpr,Nothing}

The defining right-hand side of the observed unknown `name`, or `nothing` when
it is not an observed unknown of `model`. Convenience over
[`observed_definitions`](@ref) for a single lookup.
"""
observed_definition(model::Model, name::AbstractString) =
    get(observed_definitions(model), String(name), nothing)

"""
    observed_unknowns(model::Model) -> Vector{String}

The unknowns defined by a bare-variable LHS (`y ~ f(…)`) — eliminable and
materializable (esm-spec §6.3.1). Sorted lexicographically.

This replaces every 0.x `variable.type == "observed"` test.
"""
observed_unknowns(model::Model)::Vector{String} =
    sort!(collect(keys(observed_definitions(model))))

"""
    algebraic_unknowns(model::Model) -> Vector{String}

The unknowns constrained only implicitly (`H*H*SO4 ~ Ksp`) — those an equation
never names as a derivative target or a bare-variable LHS (esm-spec §6.3.1).
Sorted lexicographically.

Defined as the complement so that [`ode_states`](@ref),
[`observed_unknowns`](@ref) and `algebraic_unknowns` PARTITION the unknowns by
construction: an unknown with no equation of its own lands here rather than
vanishing (the equation balance, not the classification, is what reports it).
"""
function algebraic_unknowns(model::Model)::Vector{String}
    accounted = Set(ode_states(model))
    union!(accounted, keys(observed_definitions(model)))
    return String[n for n in unknown_names(model) if !(n in accounted)]
end

"""
    solver_unknowns(model::Model) -> Vector{String}

The unknowns that occupy a SOLVER SLOT — [`ode_states`](@ref) plus
[`algebraic_unknowns`](@ref), sorted lexicographically. Equivalently, the
unknowns minus the observed ones, which are eliminable.

This is the set the 0.x declared type `state` named, and the set every
partition, cell-enumeration, and live-state guard in the tree-walk build wants:
an algebraic unknown is solved for exactly like an ODE state (it just has no
time derivative), so treating only `ode_states` as "the states" drops a
declared, array-shaped algebraic unknown out of the partition it belongs to.
It is also the CONTINUOUS half of the cadence leaf-seed table
(CONFORMANCE_SPEC §5.7.2), which seeds both alike.
"""
function solver_unknowns(model::Model)::Vector{String}
    observed = Set(observed_unknowns(model))
    return String[n for n in unknown_names(model) if !(n in observed)]
end

# ── The four parameter sets (they partition) ────────────────────────────────

"""
    _update_rules(v::ModelVariable) -> Vector{ParameterUpdate}

The variable's update rules, empty when it declares none. `update` is stored as
a vector whatever its wire spelling, so a single rule and an ordered array read
the same here.
"""
_update_rules(v::ModelVariable)::Vector{ParameterUpdate} =
    v.update === nothing ? ParameterUpdate[] : v.update

"""True iff any of the parameter's update rules is a `wiener` process. The
schema forbids `wiener` inside an array, so in practice an array update is
never Brownian — but the test reads through the vector rather than assuming
it, so a schema relaxation cannot silently change the answer."""
_is_wiener(v::ModelVariable)::Bool = any(r -> r.kind == "wiener", _update_rules(v))

"""
    brownian_parameters(model::Model) -> Vector{String}

Parameters whose `update.kind` is `"wiener"` — the SDE noise sources
(esm-spec §6.3.1). Sorted lexicographically. Their presence is what makes
[`system_kind`](@ref) `"sde"`.

This replaces every 0.x `variable.type == "brownian"` test.
"""
brownian_parameters(model::Model)::Vector{String} =
    sort!(String[n for (n, v) in model.variables
                 if v.type == ParameterVariable && _is_wiener(v)])

"""
    discrete_parameters(model::Model) -> Vector{String}

Parameters carrying any update OTHER than `wiener` — piecewise-constant between
refreshes (esm-spec §6.3.1). Sorted lexicographically. These are the sole seed
of the DISCRETE cadence class (CONFORMANCE_SPEC §5.7.2).

This replaces every 0.x `variable.type == "discrete"` test AND the 0.x
`DiscreteEvent.discrete_parameters` list.
"""
discrete_parameters(model::Model)::Vector{String} =
    sort!(String[n for (n, v) in model.variables
                 if v.type == ParameterVariable && !isempty(_update_rules(v)) &&
                    !_is_wiener(v)])

"""
    sampled_parameters(model::Model) -> Vector{String}

Parameters with a `distribution` and no `update` — drawn ONCE at setup
(uncertainty quantification, ensembles). Sorted lexicographically.
"""
sampled_parameters(model::Model)::Vector{String} =
    sort!(String[n for (n, v) in model.variables
                 if v.type == ParameterVariable && v.distribution !== nothing &&
                    isempty(_update_rules(v))])

"""
    constant_parameters(model::Model) -> Vector{String}

Parameters with neither a `distribution` nor an `update` — plain constants.
Sorted lexicographically.
"""
constant_parameters(model::Model)::Vector{String} =
    sort!(String[n for (n, v) in model.variables
                 if v.type == ParameterVariable && v.distribution === nothing &&
                    isempty(_update_rules(v))])

# ── System kind ─────────────────────────────────────────────────────────────

"""True iff any node of `e` (descending EVERY expression-bearing field, not
just `args`) satisfies `pred`."""
function _any_subexpr(pred, e::ASTExpr)::Bool
    pred(e) && return true
    for c in child_exprs(e)
        _any_subexpr(pred, c) && return true
    end
    return false
end

_equation_has(pred, eq::Equation)::Bool =
    _any_subexpr(pred, eq.lhs) || _any_subexpr(pred, eq.rhs)

"""
    has_spatial_derivative(model::Model) -> Bool

True iff some equation of `model` contains a spatial derivative anywhere in its
LHS or RHS — a `D` whose `wrt` is present and is not `"t"`, or a `grad` / `div`
/ `laplacian` sugar op (esm-spec §6.3.1).
"""
has_spatial_derivative(model::Model)::Bool =
    any(eq -> _equation_has(_is_spatial_derivative, eq), model.equations)

"""
    has_time_derivative(model::Model) -> Bool

True iff some equation of `model` contains a structural time derivative
(`D` with `wrt` `"t"` or absent) anywhere in its LHS or RHS.
"""
has_time_derivative(model::Model)::Bool =
    any(eq -> _equation_has(_is_time_derivative, eq), model.equations)

"""
    system_kind(model::Model) -> String

Derive what the `system_kind` field declares (esm-spec §6.3.1). Four conditions
tested **in this order**, first match winning:

| # | Condition | Result |
|---|---|---|
| 1 | any parameter in [`brownian_parameters`](@ref) | `"sde"` |
| 2 | any equation contains a spatial derivative | `"pde"` |
| 3 | no time-derivative equation at all | `"nonlinear"` |
| 4 | otherwise | `"ode"` |

Both orderings are load-bearing. `"pde"` precedes `"nonlinear"` so a
steady-state PDE (`laplacian(phi) ~ f`, no ∂/∂t) is a PDE rather than falling
through to `"nonlinear"`. `"sde"` precedes `"pde"` because there is no
`SPDESystem` constructor to select, so a model that is both assembles as an SDE.

The rule is stated over the EQUATIONS and not over a `domain` block: v0.8.0
removed `Domain.spatial`, so `domain` says nothing about space and a
domain-based test is not implementable.

A binding uses this derivation when the `system_kind` field is absent, and
reports `system_kind_mismatch` when a present field contradicts it — see
[`declared_system_kind_mismatch`](@ref).
"""
function system_kind(model::Model)::String
    isempty(brownian_parameters(model)) || return "sde"
    has_spatial_derivative(model) && return "pde"
    has_time_derivative(model) || return "nonlinear"
    return "ode"
end

"""
    declared_system_kind_mismatch(model::Model) -> Union{Tuple{String,String},Nothing}

`(declared, derived)` when the model declares a `system_kind` that contradicts
[`system_kind`](@ref), and `nothing` otherwise (including when the field is
absent). The `system_kind_mismatch` diagnostic reports the pair.
"""
function declared_system_kind_mismatch(model::Model)
    declared = model.system_kind
    declared === nothing && return nothing
    derived = system_kind(model)
    return declared == derived ? nothing : (declared, derived)
end

# ── Partition assertions (§6.3.1: "these sets PARTITION") ───────────────────

"""
    assert_classification_partitions(model::Model)

Check that the three unknown sets and the four parameter sets each partition
their side of the model's variables, throwing `ArgumentError` otherwise. The
spec states the partition property normatively, so it is asserted rather than
assumed; the conformance runner and `test/classification_test.jl` call it on
every fixture.
"""
function assert_classification_partitions(model::Model)
    us = ode_states(model)
    uo = observed_unknowns(model)
    ua = algebraic_unknowns(model)
    all_u = unknown_names(model)
    covered = vcat(us, uo, ua)
    length(covered) == length(unique(covered)) ||
        throw(ArgumentError("unknown sets overlap: $(sort!(covered))"))
    sort(covered) == all_u ||
        throw(ArgumentError("unknown sets do not cover the unknowns: " *
                            "$(sort!(covered)) vs $(all_u)"))

    pb = brownian_parameters(model)
    pd = discrete_parameters(model)
    ps = sampled_parameters(model)
    pc = constant_parameters(model)
    all_p = parameter_names(model)
    pcov = vcat(pb, pd, ps, pc)
    length(pcov) == length(unique(pcov)) ||
        throw(ArgumentError("parameter sets overlap: $(sort!(pcov))"))
    sort(pcov) == all_p ||
        throw(ArgumentError("parameter sets do not cover the parameters: " *
                            "$(sort!(pcov)) vs $(all_p)"))
    return nothing
end
