# tree_walk/semiring.jl — the closed semiring registry and the reducers: each
# aggregate's ⊕ and its identity 0̄, and how a list of terms is folded.

# ============================================================
# 5c. Semiring registry (RFC semiring-faq-unified-ir §5.1)
# ============================================================
#
# A semiring is the pair (⊕, ⊗) together with its two NORMATIVE identity
# elements (0̄, 1̄): 0̄ is the value of an empty ⊕-reduction and 1̄ the value of
# an empty ⊗-product (CONFORMANCE_SPEC §5.6.1). An aggregate's body writes its
# own ⊗ as ordinary operators, so what the evaluator takes from this table is ⊕
# and 0̄; the `reduce` field names ⊕ only, and 0̄ comes from here, NEVER from the
# file. The registry is closed and exhaustive — adding a semiring is a spec
# change.
struct _Semiring
    oplus::String      # ⊕ reduce spelling
    zerobar::Float64   # 0̄ : result of an empty ⊕-reduction
end

# ±∞ identities are represented per-binding (Julia: Inf/-Inf) and are the
# *result* of an empty reduction — never written into a file (§5.1 note 2).
const _SEMIRING_REGISTRY = Dict{String, _Semiring}(
    "sum_product" => _Semiring("+", 0.0),
    "max_product" => _Semiring("max", -Inf),
    "min_sum" => _Semiring("min", Inf),
    "max_sum" => _Semiring("max", -Inf),
    "bool_and_or" => _Semiring("or", 0.0),  # false
)

# ============================================================
# The reducer table: every ⊕ an aggregate can fold with
# ============================================================
#
# A reducer is a value, not a name compared at each use: its symbol (what
# `_Node.op` and the build carry), its 0̄ identity, the Julia function a fold
# applies (and an emitter splices, by name), and whether it is NUMERIC — may run
# as a loop and produce an array. `or` (bool_and_or's ⊕) is index-set-producing
# (§5.5): it folds only in a scalar (rank-0) faq. Adding a reducer is one row;
# the run-time step `_oplus`, the whitelist `_is_numeric_reducer` and the emitted
# function `_reducer_fnsym` all read it.
struct _Reducer
    sym::Symbol
    zerobar::Float64
    fn::Function
    numeric::Bool
end

const _REDUCERS = (
    _Reducer(:+, 0.0, +, true),
    _Reducer(:*, 1.0, *, true),
    _Reducer(:max, -Inf, max, true),
    _Reducer(:min, Inf, min, true),
    _Reducer(:or, 0.0, _or_combine, false),
)

const _REDUCER_INDEX = Dict{Symbol, _Reducer}(r.sym => r for r in _REDUCERS)

for _r in _REDUCERS
    getfield(@__MODULE__, nameof(_r.fn)) === _r.fn ||
        error("semiring: reducer $(_r.sym) does not resolve to its function in module scope")
end
for (_n, _sr) in _SEMIRING_REGISTRY
    _rr = get(_REDUCER_INDEX, Symbol(_sr.oplus), nothing)
    (_rr !== nothing && _rr.zerobar === _sr.zerobar) ||
        error("semiring: '$_n' names ⊕ '$(_sr.oplus)' with a 0̄ the reducer table does not have")
end

# `reduce` spelling → 0̄, the empty-reduction identity: what the `reduce`
# shorthand resolves to when no `semiring` is given (⊕ = reduce, ⊗ = "*";
# §5.1 note 1). The keys are exactly the schema's `reduce` enum, the numeric
# reducers. Boolean `or` is reachable only as `semiring: "bool_and_or"`;
# `reduce: "or"` is refused, as the schema refuses it.
const _OPLUS_IDENTITY = Dict{String, Float64}(
    String(r.sym) => r.zerobar for r in _REDUCERS if r.numeric
)

"""
    _is_numeric_reducer(oplus) -> Bool

True for a ⊕ (a `String` or `Symbol`) that may run as a loop and produce an
array: `+`, `*`, `max`, `min`. False for `or` and for any unknown name.
"""
_is_numeric_reducer(oplus::Symbol) =
    (r = get(_REDUCER_INDEX, oplus, nothing); r !== nothing && r.numeric)
_is_numeric_reducer(oplus::AbstractString) = _is_numeric_reducer(Symbol(oplus))

@noinline _throw_unknown_reducer(op) = throw(
    TreeWalkError(
        "E_TREEWALK_ARRAYOP_UNKNOWN_REDUCE",
        "unknown reducer ⊕ '$(op)'; the reducers are " *
            join((String(r.sym) for r in _REDUCERS), ", ")
    )
)

"""
    _reducer_fnsym(op::Symbol) -> Symbol

The module-scope name of the function a fold with ⊕ `op` applies, for an
emitter to splice (`:+`, `:*`, `:max`, `:min`, `:_or_combine`). Declines
(`_Decline(:unsupported_op)`) for an unknown ⊕.
"""
function _reducer_fnsym(op::Symbol)
    r = get(_REDUCER_INDEX, op, nothing)
    r === nothing && _decline(:unsupported_op, "⊕ = $(op)")
    return nameof(r.fn)
end

# One ⊕ step, generated from the table as a compare chain over `op` (no table
# lookup at run time). `_oplus` covers every reducer; `_oplus_numeric` only the
# numeric ones, so its result type is the operands' (`or` maps any operand type
# to `Float64`, which would make a `Dual` fold's accumulator a union). An unknown
# `op` raises; no arm stands in for another reducer.
for (fname, rows) in (
        (:_oplus, _REDUCERS),
        (:_oplus_numeric, filter(r -> r.numeric, collect(_REDUCERS))),
    )
    chain = :(_throw_unknown_reducer(op))
    for r in reverse(rows)
        chain = Expr(:if, :(op === $(QuoteNode(r.sym))), :($(nameof(r.fn))(a, b)), chain)
    end
    @eval @inline $fname(op::Symbol, a, b) = $chain
end

# Resolve an aggregate node's (⊕ spelling, 0̄ identity) — everything the
# evaluator needs to fold a reduction and to value an empty one. `semiring`
# (if present) is authoritative and supersedes `reduce`; otherwise `reduce`
# (default "+") names ⊕. Both ⊗ and the identities are sourced here, never
# from the file.
function _aggregate_oplus_identity(
        semiring::Union{String, Nothing},
        reduce::Union{String, Nothing}
    )
    if semiring !== nothing
        sr = get(_SEMIRING_REGISTRY, semiring, nothing)
        sr === nothing && throw(
            TreeWalkError(
                "E_TREEWALK_UNKNOWN_SEMIRING",
                "unknown semiring '$semiring'; the closed registry is " *
                    join(sort(collect(keys(_SEMIRING_REGISTRY))), ", ")
            )
        )
        return (sr.oplus, sr.zerobar)
    end
    r = reduce === nothing ? "+" : reduce
    haskey(_OPLUS_IDENTITY, r) || throw(
        TreeWalkError(
            "E_TREEWALK_ARRAYOP_UNKNOWN_REDUCE",
            "unsupported reduce='$r'; expected one of +, *, max, min (or set `semiring`)"
        )
    )
    return (r, _OPLUS_IDENTITY[r])
end

# True for the canonical `faq` op tag — the ONLY spelling that reaches here.
# `aggregate` is normalized away at the wire boundary and `arrayop` is rejected
# there (docs/content/rfcs/faq-node-rename.md §5.2).
@inline _is_faq_op(op::AbstractString) = (op == "faq")

# Combine a vector of expressions with the semiring ⊕ (`oplus`), returning the
# 0̄ identity (`zerobar`) for an empty reduction. Build-time helper for
# expression-position aggregate expansion.
# The fold is seeded from 0̄ (esm-spec §4.3.1), as the bare contraction's is in
# every tier (`_unrolled_contraction_body`, `_NK_CONTRACTION`): for "+" the seed
# is a leading `0.0` term, so a sum whose terms are all `-0.0` is `+0.0`. For
# the other three ⊕ the seed is an identity bit for bit, so it is left out.
# For "+" and "*" we emit an n-ary OpExpr (matching _eval_node_op hot paths).
# For "max"/"min" we emit left-folded binary OpExprs to avoid adding n-ary
# variants to _eval_node_op (which already handles them as ≥2-arg ops, but
# the build-time fold keeps runtime dispatch uniform).
#
# `scalar = true` marks a RANK-0 faq (no output index). Only there does ⊕ = `or`
# (bool_and_or) fold, as the n-ary logical `or` from its identity `false`: a
# crisp 0/1 whatever the terms, a NaN term reading as true, which is the other
# bindings' `acc = combine(acc, term)` fold. An array-valued `bool_and_or`
# reduction stays refused (CONFORMANCE_SPEC §5.6.1).
function _combine_with_reducer(
        oplus::String, zerobar::Float64, terms::Vector{ASTExpr};
        scalar::Bool = false
    )
    if oplus == "or"
        scalar || _throw_array_bool_and_or(oplus)
        isempty(terms) && return NumExpr(zerobar)
        return OpExpr("or", ASTExpr[NumExpr(zerobar); terms])
    end
    isempty(terms) && return NumExpr(zerobar)
    oplus == "+" && return OpExpr("+", ASTExpr[NumExpr(zerobar); terms])
    length(terms) == 1 && return terms[1]
    if oplus == "*"
        return OpExpr("*", terms)
    elseif oplus == "max"
        result = terms[1]
        for i in 2:length(terms)
            result = OpExpr("max", ASTExpr[result, terms[i]])
        end
        return result
    elseif oplus == "min"
        result = terms[1]
        for i in 2:length(terms)
            result = OpExpr("min", ASTExpr[result, terms[i]])
        end
        return result
    else
        _throw_array_bool_and_or(oplus)
    end
end

# ⊕ = `or` (bool_and_or) is index-set-producing (§5.5): an array-valued
# reduction with it is refused whatever its term count, and only a scalar
# (rank-0) bool_and_or faq runs (CONFORMANCE_SPEC §5.6.1).
@noinline _throw_array_bool_and_or(oplus) = throw(
    TreeWalkError(
        "E_TREEWALK_ARRAYOP_UNSUPPORTED_SEMIRING",
        "array-producing aggregate with ⊕='$oplus' is not supported by the " *
            "tree-walk evaluator (M1); only numeric semirings (+, *, max, min) " *
            "reduce to an array — bool_and_or is index-set-producing (§5.5), and " *
            "only a scalar (rank-0) bool_and_or faq runs (CONFORMANCE_SPEC §5.6.1)"
    )
)
