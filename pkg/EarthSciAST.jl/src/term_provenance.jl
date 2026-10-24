"""
Per-term provenance through flatten (esm-libraries-spec §4.7.5, "Per-term
provenance"; issue #539).

Every flattened equation carries an ordered list of [`Contribution`](@ref)s: the
summands of its right-hand side, each with the component or coupling entry that
authored it. The list lives BESIDE the expression tree, never on a node, so
canonical JSON, interning and CSE keys do not see it.

The invariant every helper here maintains: `body(eq)` — the right-hand side, or
the `faq` body of a pointwise-lifted equation — is the LEFT-FOLD sum of the
contribution expressions. The right-hand side is always BUILT from the list
([`_fold_contributions`](@ref)), and every pass that rewrites a flattened
equation does so inside each contribution and rebuilds
([`_rewrite_contributions`](@ref)), so no term moves across a contribution
boundary.
"""

"""
    TermOrigin(; component=nothing, coupling=nothing)

Who authored one [`Contribution`](@ref). Exactly one field is set:

- `component`: the full dotted path of the model, subsystem or reaction system
  whose equation contained the expression (`"Atmosphere.Chemistry"`);
- `coupling`: the 0-based index of the coupling entry that wrote the expression
  itself, in the coupling sequence AFTER `coupling_import` expansion (the
  sequence `metadata.coupling_rules_applied` lists).
"""
struct TermOrigin
    component::Union{String,Nothing}
    coupling::Union{Int,Nothing}

    function TermOrigin(component, coupling)
        (component === nothing) == (coupling === nothing) && throw(ArgumentError(
            "a TermOrigin names exactly one of `component` or `coupling`"))
        coupling === nothing || coupling >= 0 || throw(ArgumentError(
            "a TermOrigin's `coupling` index is 0-based and cannot be negative (got $(coupling))"))
        return new(component === nothing ? nothing : String(component),
                   coupling === nothing ? nothing : Int(coupling))
    end
end

TermOrigin(; component=nothing, coupling=nothing) = TermOrigin(component, coupling)

"""
    Contribution(expr, origins)

One summand of a flattened equation's right-hand side, with its authors.

`origins` is non-empty and deduplicated in first-appearance order for every
equation `flatten` produces. It has more than one entry only where a
non-additive merge (a multiplicative `couple`, or an `operator_compose`
`translate` factor over a multi-contribution equation) collapsed several
contributions into one indivisible expression. An EMPTY `origins` means "author
unknown": the keyword copy constructor `FlattenedSystem(flat; equations = eqs)`
produces it when a caller replaces the equations without their contributions.
"""
struct Contribution
    expr::ASTExpr
    origins::Vector{TermOrigin}
end

"""
    equation_contributions(flat::FlattenedSystem) -> Vector{Vector{Contribution}}

The per-term provenance of `flat`: entry `i` is the ordered list of
contributions whose left-fold sum is `flat.equations[i]`'s right-hand side (its
`faq` body when the pointwise lift wrapped it). See esm-libraries-spec §4.7.5.
"""
function equation_contributions end

_component_origin(path::AbstractString) = TermOrigin(String(path), nothing)
_coupling_origin(index::Integer) = TermOrigin(nothing, Int(index))

"""One contribution authored by `origin`."""
_authored(expr::ASTExpr, origin::TermOrigin) = Contribution[Contribution(expr, TermOrigin[origin])]

"""Every origin of `contributions`, then `extra`, deduplicated in first-appearance order."""
function _union_origins(contributions::AbstractVector{Contribution},
                        extra::TermOrigin...)::Vector{TermOrigin}
    out = TermOrigin[]
    for c in contributions, o in c.origins
        o in out || push!(out, o)
    end
    for o in extra
        o in out || push!(out, o)
    end
    return out
end

"""
The expression a contribution list stands for: its single expression, or one
n-ary `+` over the contribution expressions, which every evaluator folds left
to right — the left fold the invariant names.
"""
function _fold_contributions(contributions::AbstractVector{Contribution})::ASTExpr
    isempty(contributions) && throw(ArgumentError("an equation has at least one contribution"))
    length(contributions) == 1 && return contributions[1].expr
    return OpExpr("+", ASTExpr[c.expr for c in contributions])
end

"""
    _is_lifted(eq, lifted_shapes) -> Bool

True when the §10.5 pointwise lift produced `eq`: its left-hand side is the
lift's `faq` over `D(index(species, loops…))` for a species the lift recorded in
`lifted_shapes`, and its right-hand side is the `faq` the lift wrapped around the
contribution sum. An authored `faq` right-hand side is an ordinary contribution.
"""
function _is_lifted(eq::Equation, lifted_shapes::AbstractDict)::Bool
    isempty(lifted_shapes) && return false
    (eq.rhs isa OpExpr && (eq.rhs::OpExpr).op == "faq" &&
     (eq.rhs::OpExpr).expr_body !== nothing) || return false
    lhs = eq.lhs
    (lhs isa OpExpr && lhs.op == "faq" && lhs.expr_body isa OpExpr) || return false
    d = lhs.expr_body::OpExpr
    (d.op == "D" && length(d.args) == 1 && d.args[1] isa OpExpr) || return false
    ix = d.args[1]::OpExpr
    (ix.op == "index" && !isempty(ix.args) && ix.args[1] isa VarExpr) || return false
    return haskey(lifted_shapes, (ix.args[1]::VarExpr).name)
end

"""The expression the contributions of `eq` sum to: `eq.rhs`, or its `faq` body when lifted."""
_contribution_body(eq::Equation, lifted::Bool)::ASTExpr =
    lifted ? (eq.rhs::OpExpr).expr_body::ASTExpr : eq.rhs

"""
`eq` with its right-hand side REBUILT from `contributions` (re-wrapped in the
lift's `faq` when `lifted`), and `lhs` replaced when given.
"""
function _equation_from(eq::Equation, contributions::AbstractVector{Contribution},
                        lifted::Bool=false; lhs::ASTExpr=eq.lhs)::Equation
    body = _fold_contributions(contributions)
    rhs = lifted ? reconstruct(eq.rhs::OpExpr; expr_body=body) : body
    return Equation(lhs, rhs; _comment=eq._comment)
end

"""
    _rewrite_contributions(f, eq, contributions, lifted) -> (Equation, Vector{Contribution})

Apply the expression rewrite `f` INSIDE each contribution of `eq`, origins
unchanged, and rebuild the right-hand side from the result. A lifted equation's
contributions are rewritten inside the lift's `faq` shell — `f` sees each one
in the loop scope the per-cell body has — and the rebuilt shell is the one `f`
returned for the first contribution. Returns `eq` and `contributions` themselves
when `f` changed nothing.
"""
function _rewrite_contributions(f, eq::Equation,
                                contributions::Vector{Contribution},
                                lifted::Bool)
    if !lifted
        out = Contribution[Contribution(f(c.expr), c.origins) for c in contributions]
        all(i -> out[i].expr === contributions[i].expr, eachindex(out)) &&
            return eq, contributions
        return _equation_from(eq, out), out
    end
    shell = eq.rhs::OpExpr
    shells = ASTExpr[f(reconstruct(shell; expr_body=c.expr)) for c in contributions]
    for s in shells
        (s isa OpExpr && s.op == "faq" && s.expr_body !== nothing) || throw(ArgumentError(
            "a rewrite of a pointwise-lifted equation must keep its `faq` shell"))
    end
    out = Contribution[Contribution((shells[i]::OpExpr).expr_body::ASTExpr,
                                    contributions[i].origins)
                       for i in eachindex(contributions)]
    first_shell = shells[1]::OpExpr
    rhs = reconstruct(first_shell; expr_body=_fold_contributions(out))
    return Equation(eq.lhs, rhs; _comment=eq._comment), out
end

"""
The list a caller-built equation set gets when it carries no provenance: one
contribution per equation, its body, with EMPTY origins ("author unknown").
"""
_unattributed_contributions(equations::AbstractVector{Equation},
                            lifted_shapes::AbstractDict) =
    Vector{Contribution}[Contribution[Contribution(_contribution_body(eq, _is_lifted(eq, lifted_shapes)),
                                                   TermOrigin[])]
                         for eq in equations]

"""
    _rewrite_flat_equations(f, flat; lhs_rewrite=f) -> (equations, equation_contributions)

Apply the expression rewrite `f` inside every contribution of every equation of
the flattened system `flat` (and `lhs_rewrite` to each left-hand side), and
rebuild each right-hand side from its list. The shared path for a pass over a
`FlattenedSystem` that rewrites node by node — template expansion, table-lookup
lowering — so provenance survives it; pass both results to the keyword copy
constructor.
"""
function _rewrite_flat_equations(f, flat; lhs_rewrite=f)
    eqs = Equation[]
    contribs = Vector{Contribution}[]
    for (eq, cs) in zip(flat.equations, flat.equation_contributions)
        rewritten, new_cs = _rewrite_contributions(f, eq, cs, _is_lifted(eq, flat.lifted_shapes))
        lhs = lhs_rewrite(eq.lhs)
        push!(eqs, lhs === eq.lhs ? rewritten :
                   Equation(lhs, rewritten.rhs; _comment=eq._comment))
        push!(contribs, new_cs)
    end
    return eqs, contribs
end
