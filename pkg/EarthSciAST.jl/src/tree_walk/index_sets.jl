# tree_walk/index_sets.jl — part of the tree-walk evaluator: a `ranges` entry
# that names an index set (`{from: <name>, of?: […]}`) resolved against the
# model's `index_sets` registry, before any expansion reads the ranges.

# Index-set registry resolution (esm-spec §4.3.1).
#
# A `ranges[*]` value may be a dense `[lo,hi]`/`[lo,step,hi]` tuple or an
# `IndexSetRef` `{from: <name>, of?: [...]}`. The pre-pass below resolves each
# reference against the model's `index_sets` registry into the dense / dynamic
# forms the range machinery consumes, so the einsum / scalar-aggregate
# expansion sees only those:
#   interval     → dense bound `[1, size]`
#   categorical  → enumerated members `[1, |members|]`
#   ragged       → per-cell dynamic bound `[1, index(offsets, of…)]` — exactly the
#                  existing `_expand_int_range_dyn` mechanism + a `values` gather
#                  authored in the body (§5.2). offsets/values are keyed factors (§5.4).

# Keyed factors (a ragged set's `offsets`/`values`, RFC §5.4) resolve by BARE
# name in the model scope; the empty default scope keeps every bare name as-is.
# Read-only sentinel — see the `_EMPTY_*` invariant block next to
# `_EMPTY_DERIVED_EXTENTS`.
const _EMPTY_FACTOR_SCOPE = Dict{String, String}()

# A ragged set's `offsets` / `values` keyed factors bind by BARE name in the
# model scope (§5.4), but flattening prefixes every variable with its owning
# component path while the document-scoped registry keeps the authored bare
# name. Map each bare factor name to its in-scope variable: an exact-name
# variable wins (and needs no entry); otherwise the dot-suffix match at the
# SHALLOWEST namespace depth (the model's own re-exposed alias, not the mounted
# subsystem's original) — unique at that depth, else left bare so the unbound-
# name error surfaces. Empty for documents without ragged index sets.
function _ragged_factor_scope(index_sets::AbstractDict, variables::AbstractDict)
    factor_scope = Dict{String, String}()
    for (_, iset) in index_sets
        (iset isa IndexSet && iset.kind == "ragged") || continue
        for f in (iset.offsets, iset.values)
            f === nothing && continue
            fname = String(f)
            (haskey(factor_scope, fname) || haskey(variables, fname)) && continue
            cands = String[n for n in keys(variables) if endswith(n, "." * fname)]
            isempty(cands) && continue
            mindepth = minimum(count(==('.'), c) for c in cands)
            best = String[c for c in cands if count(==('.'), c) == mindepth]
            length(best) == 1 && (factor_scope[fname] = best[1])
        end
    end
    return factor_scope
end

# Resolve ONE IndexSetRef to a concrete `ranges` value. Errors clearly on an
# undeclared name — no implicit interval is inferred, so a typo can't silently
# become an empty set (§5.2). `factor_scope` maps a ragged set's bare keyed-factor
# name to the in-scope variable that backs it (flattening prefixes variables with
# their owning component path, e.g. "nEdgesOnCell" → "Divergence.nEdgesOnCell",
# while the document-scoped registry keeps the bare authored name).
function _resolve_one_index_set_ref(
        ref::IndexSetRef, index_sets::AbstractDict,
        derived_extents::AbstractDict = _EMPTY_DERIVED_EXTENTS,
        factor_scope::AbstractDict = _EMPTY_FACTOR_SCOPE
    )
    haskey(index_sets, ref.from) || throw(
        TreeWalkError(
            "E_TREEWALK_UNDECLARED_INDEX_SET",
            "undeclared index set '$(ref.from)' referenced in ranges; declare it in " *
                "the model's `index_sets` registry (no implicit interval is inferred)"
        )
    )
    is = index_sets[ref.from]
    if is.kind == "interval"
        is.size === nothing && throw(
            TreeWalkError(
                "E_TREEWALK_INDEX_SET_INCOMPLETE",
                "interval index set '$(ref.from)' requires a `size`"
            )
        )
        return Any[1, Int(is.size)]
    elseif is.kind == "categorical"
        is.members === nothing && throw(
            TreeWalkError(
                "E_TREEWALK_INDEX_SET_INCOMPLETE",
                "categorical index set '$(ref.from)' requires `members`"
            )
        )
        return Any[1, length(is.members)]
    elseif is.kind == "ragged"
        is.offsets === nothing && throw(
            TreeWalkError(
                "E_TREEWALK_INDEX_SET_INCOMPLETE",
                "ragged index set '$(ref.from)' requires an `offsets` backing factor"
            )
        )
        isempty(ref.of) && throw(
            TreeWalkError(
                "E_TREEWALK_RAGGED_NO_PARENTS",
                "ragged index set '$(ref.from)' referenced without `of` parent index " *
                    "variable(s); a ragged set's per-tuple length is a function of its parent"
            )
        )
        # Per-cell dynamic upper bound |set(of…)| = offsets[of…]. The member
        # gather through `values` is authored in the body (e.g.
        # index(values, of…, k)) and resolved by the existing const_array path.
        # The offsets factor binds by BARE name in the model scope (§5.4);
        # `factor_scope` supplies the in-scope (possibly namespaced) variable.
        off = String(get(factor_scope, String(is.offsets), String(is.offsets)))
        idx_args = ASTExpr[VarExpr(off)]
        append!(idx_args, ASTExpr[VarExpr(p) for p in ref.of])
        return Any[1, OpExpr("index", idx_args)]
    elseif is.kind == "derived"
        # A derived index set names its producing FAQ node via `from_faq`: a
        # `distinct` value-invention producer materialized at setup
        # (`materialize_value_invention`, §5.5). Its cardinality is the dense
        # extent `[1, n]`. A set with no extent
        # is refused rather than contracted as empty: an empty range would fold
        # to the additive identity and read as a plausible 0 (esm-spec §9.6.6).
        faq = is.from_faq
        faq === nothing && throw(
            TreeWalkError(
                "E_TREEWALK_DERIVED_NO_FAQ",
                "derived index set '$(ref.from)' requires a `from_faq` naming its " *
                    "producing node (§5.5)"
            )
        )
        haskey(derived_extents, faq) || throw(
            TreeWalkError(
                "derived_index_set_unmaterialized",
                "derived index set '$(ref.from)' (from_faq '$faq') is not materialized: no " *
                    "geometry or value-invention producer supplied its extent at setup. " *
                    "Materialized: $(sort(collect(keys(derived_extents))))."
            )
        )
        return Any[1, derived_extents[faq]]
    end
    throw(
        TreeWalkError(
            "E_TREEWALK_UNKNOWN_INDEX_SET_KIND",
            "unknown index set kind '$(is.kind)' for '$(ref.from)'"
        )
    )
end

# True iff any node in the subtree carries a `ranges` entry that is an
# IndexSetRef, in any expression-bearing field (the generated walk).
_ranges_hold_isr(e::ASTExpr) =
    e isa OpExpr && (e::OpExpr).ranges !== nothing &&
    any(v -> v isa IndexSetRef, values((e::OpExpr).ranges))
_has_index_set_ref(expr::ASTExpr) = _any_subexpr_once(_ranges_hold_isr, expr)
_has_index_set_ref(eq::Equation) = _has_index_set_ref(eq.lhs) || _has_index_set_ref(eq.rhs)

# Rewrite every IndexSetRef in the subtree's ranges to its resolved concrete
# form, in every expression-bearing field (`map_children`). Memoized by
# identity and identity-preserving: a shared node resolves to one shared output
# node, and a node with no IndexSetRef below it is returned as it is, so a
# shared expression is neither walked once per path nor re-inflated into a tree.
function _resolve_isr(
        expr::OpExpr, index_sets::AbstractDict,
        derived_extents::AbstractDict = _EMPTY_DERIVED_EXTENTS,
        factor_scope::AbstractDict = _EMPTY_FACTOR_SCOPE,
        memo::IdDict{OpExpr, ASTExpr} = IdDict{OpExpr, ASTExpr}()
    )
    cached = get(memo, expr, nothing)
    cached === nothing || return cached
    e = map_children(x -> _resolve_isr(x, index_sets, derived_extents, factor_scope, memo), expr)
    if _ranges_hold_isr(e)
        resolved = Dict{String, Any}()
        for (k, v) in (e::OpExpr).ranges
            resolved[k] = v isa IndexSetRef ?
                _resolve_one_index_set_ref(v, index_sets, derived_extents, factor_scope) : v
        end
        e = reconstruct(e::OpExpr; ranges = resolved)
    end
    memo[expr] = e
    return e
end
_resolve_isr(
    expr::ASTExpr, ::AbstractDict, ::AbstractDict = _EMPTY_DERIVED_EXTENTS,
    ::AbstractDict = _EMPTY_FACTOR_SCOPE,
    ::IdDict{OpExpr, ASTExpr} = IdDict{OpExpr, ASTExpr}()
) = expr
_resolve_isr(
    eq::Equation, index_sets::AbstractDict,
    derived_extents::AbstractDict = _EMPTY_DERIVED_EXTENTS,
    factor_scope::AbstractDict = _EMPTY_FACTOR_SCOPE,
    memo::IdDict{OpExpr, ASTExpr} = IdDict{OpExpr, ASTExpr}()
) =
    Equation(
    _resolve_isr(eq.lhs, index_sets, derived_extents, factor_scope, memo),
    _resolve_isr(eq.rhs, index_sets, derived_extents, factor_scope, memo);
    _comment = eq._comment
)

# Resolve all index-set references across a vector of equations. Returns the
# input unchanged when no equation uses a `{from}` reference — preserving
# byte-identical behaviour (and the compiled tree) for existing files (§6).
# One shared memo across the vector: the registries are fixed for the whole
# call, so a subtree shared BETWEEN equations also resolves once and stays
# shared.
function _resolve_index_set_ranges(
        eqs::Vector{Equation}, index_sets::AbstractDict,
        derived_extents::AbstractDict = _EMPTY_DERIVED_EXTENTS,
        factor_scope::AbstractDict = _EMPTY_FACTOR_SCOPE
    )
    any(_has_index_set_ref, eqs) || return eqs
    memo = IdDict{OpExpr, ASTExpr}()
    return Equation[
        _resolve_isr(eq, index_sets, derived_extents, factor_scope, memo)
            for eq in eqs
    ]
end
