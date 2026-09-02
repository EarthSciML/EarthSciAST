# ========================================================================
# tree_walk/semiring.jl — part of the tree-walk evaluator (gt-e8yw).
# Included by src/tree_walk.jl; see that file for the full layout and
# include order. Sections 5c/5c-join: the closed semiring registry and build-time
# value-equality join resolution (RFC semiring-faq-unified-ir).
# ========================================================================

# ============================================================
# 5c. Semiring registry (RFC semiring-faq-unified-ir §5.1)
# ============================================================
#
# A semiring is the pair (⊕, ⊗) together with its two NORMATIVE identity
# elements (0̄, 1̄): 0̄ is the value of an empty ⊕-reduction and 1̄ the value of
# an empty ⊗-product. The `reduce` field on an aggregate names ⊕ only; the
# matching ⊗ and BOTH identities come from this table, NEVER from the file.
# The registry is closed and exhaustive — adding a semiring is a spec change.
struct _Semiring
    name::String
    oplus::String      # ⊕ reduce spelling
    zerobar::Float64   # 0̄ : result of an empty ⊕-reduction
    otimes::String     # ⊗ product spelling
    onebar::Float64    # 1̄ : result of an empty ⊗-product
end

# ±∞ identities are represented per-binding (Julia: Inf/-Inf) and are the
# *result* of an empty reduction — never written into a file (§5.1 note 2).
const _SEMIRING_REGISTRY = Dict{String,_Semiring}(
    "sum_product" => _Semiring("sum_product", "+",   0.0,  "*", 1.0),
    "max_product" => _Semiring("max_product", "max", -Inf, "*", 1.0),
    "min_sum"     => _Semiring("min_sum",     "min",  Inf, "+", 0.0),
    "max_sum"     => _Semiring("max_sum",     "max", -Inf, "+", 0.0),
    "bool_and_or" => _Semiring("bool_and_or", "or",   0.0, "and", 1.0),  # false / true
)

# ⊕-spelling → 0̄, the empty-⊕-reduction identity. Derived from (and consistent
# with) the registry table; this is what the legacy `reduce`-only shorthand
# resolves to when no `semiring` is given (⊕ = reduce, ⊗ = "*"; §5.1 note 1).
# "*" is the legacy product-reduce: no registry semiring has ⊕=× (it appears
# only as ⊗), but files predating the registry may carry reduce="*".
const _OPLUS_IDENTITY = Dict{String,Float64}(
    "+" => 0.0, "max" => -Inf, "min" => Inf, "*" => 1.0, "or" => 0.0,
)

# Resolve an aggregate node's (⊕ spelling, 0̄ identity) — everything the
# evaluator needs to fold a reduction and to value an empty one. `semiring`
# (if present) is authoritative and supersedes `reduce`; otherwise `reduce`
# (default "+") names ⊕. Both ⊗ and the identities are sourced here, never
# from the file.
function _aggregate_oplus_identity(semiring::Union{String,Nothing},
                                   reduce::Union{String,Nothing})
    if semiring !== nothing
        sr = get(_SEMIRING_REGISTRY, semiring, nothing)
        sr === nothing && throw(TreeWalkError("E_TREEWALK_UNKNOWN_SEMIRING",
            "unknown semiring '$semiring'; the closed registry is " *
            join(sort(collect(keys(_SEMIRING_REGISTRY))), ", ")))
        return (sr.oplus, sr.zerobar)
    end
    r = reduce === nothing ? "+" : reduce
    haskey(_OPLUS_IDENTITY, r) || throw(TreeWalkError("E_TREEWALK_ARRAYOP_UNKNOWN_REDUCE",
        "unsupported reduce='$r'; expected one of +, *, max, min (or set `semiring`)"))
    return (r, _OPLUS_IDENTITY[r])
end

# True for both the canonical `aggregate` op tag and its deprecated `arrayop`
# alias (§5.6). The evaluator dispatches on the two identically.
@inline _is_aggregate_op(op::AbstractString) = (op == "arrayop" || op == "aggregate")

# Combine a vector of expressions with the semiring ⊕ (`oplus`), returning the
# 0̄ identity (`zerobar`) for an empty reduction. Build-time helper for
# expression-position aggregate expansion.
# For "+" and "*" we emit an n-ary OpExpr (matching _eval_node_op hot paths).
# For "max"/"min" we emit left-folded binary OpExprs to avoid adding n-ary
# variants to _eval_node_op (which already handles them as ≥2-arg ops, but
# the build-time fold keeps runtime dispatch uniform).
function _combine_with_reducer(oplus::String, zerobar::Float64, terms::Vector{ASTExpr})
    isempty(terms) && return NumExpr(zerobar)
    length(terms) == 1 && return terms[1]
    if oplus == "+"
        return OpExpr("+", terms)
    elseif oplus == "*"
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
        # ⊕ ∈ {or} (bool_and_or) is index-set-producing (§5.5) — out of scope
        # for the M1 array-producing tree-walk evaluator.
        throw(TreeWalkError("E_TREEWALK_ARRAYOP_UNSUPPORTED_SEMIRING",
            "array-producing aggregate with ⊕='$oplus' is not supported by the " *
            "tree-walk evaluator (M1); only numeric semirings (+, *, max, min) " *
            "reduce to an array — bool_and_or is index-set-producing (§5.5)"))
    end
end

# ============================================================
# 5c-join. M2 — value-equality joins (RFC semiring-faq-unified-ir §5.3)
# ============================================================
#
# A `join` clause gates which (output × contracted) index combinations of an
# aggregate contribute a ⊗-product term: a term contributes iff, for EVERY
# key-column pair of EVERY clause, the two columns hold the SAME key value
# (categorical member compared by Unicode code point; interval / dense index by
# its integer value). All pairs of all clauses are ANDed. Resolution is purely
# structural — it depends only on the index symbols and the document index-set
# registry, never on run-time factor values — so it happens once at BUILD time:
# each key symbol's range position is bucketed into a canonical code (equal codes
# ⇔ equal key values, RFC Appendix A.6) and the expansion sites drop any
# combination whose codes disagree. A dropped combination contributes nothing →
# the additive identity 0̄ once the reduction is empty (§5.1). Because the output
# stays in DECLARED index order, a degenerate / positional join (each key bound
# to its own dimension) keeps every term and is byte-identical to the join-free
# node (§5.3). Inner-only; many-to-many is defined (m·n terms), not an error.

# `_JoinGate` (one resolved key-column pair) is defined in types.jl, ahead of
# `OpExpr`, so the `OpExpr.join_gates::Union{Vector{_JoinGate},Nothing}` field
# can name it. It is built and consumed here (`_resolve_join_gates_for` /
# `_join_admits`). A combination is admitted iff `codes_l[pos_l] ==
# codes_r[pos_r]` for every gate.

# A node's CANONICAL RANGE ORDER: the `output_idx` symbols that are ranges, in
# the order `output_idx` lists them, then the contracted symbols ascending by
# name (CONFORMANCE_SPEC §5.5.8).
#
# Not a new order — it is the enumeration order the expansion already walks, and
# the order §5.5.8's partner-restricted drive shape means by "the LATER of the
# two gated axes". Reusing it is what makes the default side assignment below a
# pure function of the document rather than of a `Dict` iteration.
function _canonical_range_order(output_idx, ranges::AbstractDict)
    outs = String[]
    if output_idx !== nothing
        for o in output_idx
            o isa AbstractString || continue        # a literal singleton `1`
            so = String(o)
            (haskey(ranges, so) && !(so in outs)) && push!(outs, so)
        end
    end
    rest = sort!(String[String(s) for s in keys(ranges) if !(String(s) in outs)])
    return vcat(outs, rest)
end

# Resolve a join-key name to the range symbol it denotes (RFC §5.3): either a
# declared range symbol directly, or the name of an index set bound by a range
# symbol via `{from: <name>}` (naming the dimension instead of the loop symbol).
# Naming nothing at all is a build-time error.
#
# `pick` settles the case an axis lookup cannot — an index set drawn by SEVERAL
# of this node's ranges, i.e. a relation joined to ITSELF (CONFORMANCE_SPEC
# §5.5.8 "Two ranges over one index set"):
#
#   * `sym::String` — the clause's own `syms` named this side's symbol. It must
#     draw the axis.
#   * `:left` / `:right` — the DEFAULT: the first / second candidate in
#     canonical range order, defined only for TWO candidates. Three or more is an
#     error naming them, because taking two of three would be a guess and a guess
#     here reads as a plausible number rather than as a failure.
function _join_sym_for_key(key::String, ranges::AbstractDict, sym_to_set::AbstractDict,
                           pick=:left, order::Union{Nothing,Vector{String}}=nothing)
    if haskey(ranges, key)
        # A key naming a range symbol OUTRIGHT is already unambiguous; `syms`
        # may not contradict it.
        (pick isa AbstractString && String(pick) != key) && throw(TreeWalkError(
            "E_TREEWALK_JOIN_SYMS_CONFLICT",
            "join key '$key' names a range symbol of this aggregate, but this " *
            "clause's `syms` puts that side on '$(pick)'; a key naming a range " *
            "symbol must name its own side's (CONFORMANCE_SPEC §5.5.8)"))
        return key
    end
    ord = order === nothing ? _canonical_range_order(nothing, ranges) : order
    rank(s) = something(findfirst(==(s), ord), length(ord) + 1)
    candidates = sort(String[s for (s, setn) in sym_to_set if setn == key]; by=rank)
    if pick isa AbstractString
        want = String(pick)
        want in candidates && return want
        throw(TreeWalkError("E_TREEWALK_JOIN_SYMS_CONFLICT",
            "this clause's `syms` puts a side on range symbol '$want', but the " *
            "key resolving through index set '$key' is read at one of " *
            "$(candidates) — '$want' does not draw that index set " *
            "(CONFORMANCE_SPEC §5.5.8)"))
    end
    if length(candidates) == 1
        return candidates[1]
    elseif isempty(candidates)
        throw(TreeWalkError("E_TREEWALK_JOIN_UNKNOWN_KEY",
            "join key '$key' is neither a declared range symbol nor an index set " *
            "bound by a range of this aggregate (RFC semiring-faq-unified-ir §5.3)"))
    elseif length(candidates) == 2
        return candidates[pick === :right ? 2 : 1]
    else
        throw(TreeWalkError("E_TREEWALK_JOIN_AMBIGUOUS_KEY",
            "index set '$key' is drawn by $(length(candidates)) range symbols of " *
            "this aggregate ($(candidates)), so which one a key column over it is " *
            "read at is not determined; name the two sides explicitly with this " *
            "clause's `join.syms` (CONFORMANCE_SPEC §5.5.8 \"Two ranges over one " *
            "index set\")"))
    end
end

# Validate one member used as a join key (RFC §5.3 / §5.7): keys must be
# exact-equality types — integer IDs or string members. Floats (equality is not
# portable across bindings), booleans, and nulls are build-time errors.
function _validated_key_member(m, set_name::String)
    m === nothing && throw(TreeWalkError("E_TREEWALK_JOIN_NULL_KEY",
        "null member in join key index set '$set_name': emitting null into a key " *
        "column is a build-time error (RFC semiring-faq-unified-ir §5.3)"))
    if m isa Bool
        throw(TreeWalkError("E_TREEWALK_JOIN_KEY_TYPE",
            "boolean member $(repr(m)) in join key index set '$set_name' is not an " *
            "exact-equality key type (RFC §5.3)"))
    elseif m isa AbstractFloat
        throw(TreeWalkError("E_TREEWALK_JOIN_FLOAT_KEY",
            "floating-point member $(repr(m)) in join key index set '$set_name': " *
            "float join keys are forbidden — equality is not portable across " *
            "bindings (RFC semiring-faq-unified-ir §5.3 / §5.7 rule 1)"))
    elseif m isa Integer
        return Int(m)
    elseif m isa AbstractString
        return String(m)
    else
        throw(TreeWalkError("E_TREEWALK_JOIN_KEY_TYPE",
            "unsupported join key member type $(typeof(m)) in index set " *
            "'$set_name'; keys must be integer IDs or categorical members (RFC §5.3)"))
    end
end

# Validate one DATA-COLUMN value used as a join key (CONFORMANCE_SPEC §5.5.8's
# float-key paragraph). Same exact-equality contract as `_validated_key_member`,
# with one addition forced by the storage: a data column reaches the build as
# `Float64` (a dense const array, a `makearray` literal, a value-invention map
# buffer), so an integer ID column is INDISTINGUISHABLE from a float one by type
# alone. Admit it exactly where every value is integral — then it IS an integer
# ID column — and reject anything else as the non-portable float key it is.
# Rejecting the document is the RECOMMENDED behaviour of §5.5.8 and what the
# Python reference does; Julia follows Python here rather than Rust (which
# declines the gate and lets the lowered predicate compute float equality),
# because Julia has no lowered predicate to fall back on.
function _validated_key_datum(v, col_name::String)
    v === nothing && throw(TreeWalkError("E_TREEWALK_JOIN_NULL_KEY",
        "null value in join key column '$col_name': emitting null into a key " *
        "column is a build-time error (CONFORMANCE_SPEC §5.5.8)"))
    if v isa Bool
        throw(TreeWalkError("E_TREEWALK_JOIN_KEY_TYPE",
            "boolean value $(repr(v)) in join key column '$col_name' is not an " *
            "exact-equality key type (CONFORMANCE_SPEC §5.5.8)"))
    elseif v isa Integer
        return Int(v)
    elseif v isa AbstractString
        return String(v)
    elseif v isa AbstractFloat
        (isfinite(v) && v == round(v)) || throw(TreeWalkError("E_TREEWALK_JOIN_FLOAT_KEY",
            "non-integral value $(repr(v)) in join key column '$col_name': a " *
            "float-stored key column is admissible ONLY where every value is " *
            "exactly integral (an integer ID column) — float equality is not " *
            "portable across bindings (CONFORMANCE_SPEC §5.5.8 / §5.5.1 rule 1)"))
        return Int(v)
    else
        throw(TreeWalkError("E_TREEWALK_JOIN_KEY_TYPE",
            "unsupported join key value type $(typeof(v)) in column " *
            "'$col_name'; keys must be integer IDs or categorical members " *
            "(CONFORMANCE_SPEC §5.5.8)"))
    end
end

# The 1-based range positions iterated for a join-key symbol — the loop-variable
# values the expansion will see (categorical / interval `{from}` resolve to
# `1:size`; a dense `[lo,hi]` tuple expands to `lo:hi`). Runs on the ORIGINAL
# (pre-index-set-resolution) ranges so the `{from}` reference is still present.
function _join_key_positions(sym::String, ranges::AbstractDict, index_sets::AbstractDict)
    spec = get(ranges, sym, nothing)
    spec === nothing && throw(TreeWalkError("E_TREEWALK_JOIN_UNKNOWN_KEY",
        "join key symbol '$sym' is not a range of this aggregate (RFC §5.3)"))
    if spec isa IndexSetRef
        haskey(index_sets, spec.from) || throw(TreeWalkError(
            "E_TREEWALK_UNDECLARED_INDEX_SET",
            "undeclared index set '$(spec.from)' referenced by join key '$sym' (RFC §5.2)"))
        is = index_sets[spec.from]
        if is.kind == "categorical"
            n = is.members === nothing ? 0 : length(is.members)
            return collect(1:n)
        elseif is.kind == "interval"
            is.size === nothing && throw(TreeWalkError("E_TREEWALK_INDEX_SET_INCOMPLETE",
                "interval index set '$(spec.from)' requires a `size`"))
            return collect(1:Int(is.size))
        else
            throw(TreeWalkError("E_TREEWALK_JOIN_KEY_KIND",
                "join key index set '$(spec.from)' has kind '$(is.kind)'; only " *
                "'interval' (integer IDs) and 'categorical' keys can be equi-joined " *
                "(RFC §5.3)"))
        end
    end
    return collect(_expand_int_range(spec))
end

# The key VALUE at each range position for a join-key symbol (RFC §5.3): a
# categorical range yields its declared members (validated as exact-equality
# keys); an interval or dense integer range yields the integer index itself.
function _key_member_values(sym::String, ranges::AbstractDict, positions::Vector{Int},
                            index_sets::AbstractDict)
    spec = get(ranges, sym, nothing)
    if spec isa IndexSetRef
        is = index_sets[spec.from]
        if is.kind == "categorical"
            # Prefer the original-typed members (retained only when non-string) so
            # float / null keys are rejected; otherwise the string members are keys.
            src = is.members_raw !== nothing ? is.members_raw :
                  (is.members === nothing ? Any[] : is.members)
            return Any[_validated_key_member(src[p], spec.from) for p in positions]
        elseif is.kind == "interval"
            return Any[Int(p) for p in positions]
        end
    end
    # Dense integer-tuple range — the integer index value is the key.
    return Any[Int(p) for p in positions]
end

# Bucket two key columns into one canonical sorted order and return
# equal-iff-equal integer codes (RFC Appendix A.6 / §5.7 rule 1: integers by
# value, strings by Unicode code point). Equal values get equal codes; a value
# present on only one side never matches (inner join → 0̄). Coupling an integer
# key column to a string key column is a key-type error (they can never compare
# equal — §5.3).
function _encode_join_keys(vals_l::Vector{Any}, vals_r::Vector{Any})
    l_str = any(v -> v isa AbstractString, vals_l)
    r_str = any(v -> v isa AbstractString, vals_r)
    if l_str != r_str
        throw(TreeWalkError("E_TREEWALK_JOIN_KEY_TYPE",
            "join pair couples incompatible key types (integer IDs vs categorical " *
            "string members); both sides must be the same exact-equality type " *
            "(RFC semiring-faq-unified-ir §5.3)"))
    end
    table = sort!(unique(vcat(vals_l, vals_r)))
    code_of = Dict{Any,Int}(v => i for (i, v) in enumerate(table))
    return (Int[code_of[v] for v in vals_l], Int[code_of[v] for v in vals_r])
end

# `ESS_JOIN_ON_GATE_DISABLE=1` resolves an `on` clause to the equality CODES
# only, attaching no match index — the pre-§5.5.8 behaviour, where the gate
# filtered the full product instead of driving it. It is the differential oracle
# for the driver (mirroring `ESS_GEOM_OVERLAP_GATE_DISABLE`): the admitted leaf
# set is identical either way, so any difference in the ANSWER is a driver bug,
# and the visit counts must differ or the gate never fired.
_join_on_gate_disabled() = get(ENV, "ESS_JOIN_ON_GATE_DISABLE", "") == "1"

# The DRIVABLE match set of one composite `on` key (CONFORMANCE_SPEC §5.5.8):
# `{ (pos_l, pos_r) : key_l(pos_l) == key_r(pos_r) }`, built ONCE per node.
#
# `group` is every resolved pair of the clause over the SAME two loop symbols —
# §5.5.8's COMPOSITE KEY, which matches iff every listed pair agrees. The key of
# a position is therefore the §5.5.1 rule-4 skolem TUPLE of that position's
# per-pair bucket codes, in the order the pairs are listed (spelled below as a
# code vector, which orders lexicographically exactly as the tuple does).
#
# The match set comes from `Relational.equijoin`, the one canonical rule-5 join
# primitive: it hashes only to BUCKET and emits sorted by the canonical key, then
# left, then right — never by `Dict` iteration order — so duplicate, reversed and
# permuted inputs give a byte-identical pair list, and the cost is
# `O(|L| + |R| + |matches|)` plus that sort rather than the `O(|L|·|R|)` product.
# `_OverlapIndex` then derives the POSITION-ascending drive order from it (§5.5.8
# "a binding that drives in position-ascending order derives that order from this
# one"); both are pure functions of the input.
#
# Returns `nothing` — no index, so the gate filters as it always did — when the
# two gated symbols are the SAME range symbol. A pair set cannot bind one symbol
# to two positions, and a self-equality gate admits every position anyway.
function _on_gate_match_pairs(group)
    sym_l, sym_r = group[1][1], group[1][2]
    sym_l == sym_r && return nothing
    pos_l, pos_r = group[1][3], group[1][4]
    coded = [_encode_join_keys(g[5], g[6]) for g in group]
    # A SINGLE pair — the overwhelmingly common case, and the one that has to
    # stay cheap at 1e5 rows — keys on the bucket code itself; a composite key
    # keys on the per-pair code vector, which orders lexicographically exactly as
    # the §5.5.1 rule-4 skolem tuple does.
    kl, kr = if length(coded) == 1
        (Dict{Int,Int}(p => coded[1][1][i] for (i, p) in enumerate(pos_l)),
         Dict{Int,Int}(p => coded[1][2][i] for (i, p) in enumerate(pos_r)))
    else
        (Dict{Int,Vector{Int}}(p => Int[c[1][i] for c in coded] for (i, p) in enumerate(pos_l)),
         Dict{Int,Vector{Int}}(p => Int[c[2][i] for c in coded] for (i, p) in enumerate(pos_r)))
    end
    matches = Relational.equijoin(pos_l, pos_r; on_left = p -> kl[p], on_right = p -> kr[p])
    return Tuple{Int,Int}[(Int(m[1]), Int(m[2])) for m in matches]
end

# The empty value-invention map registry: no materialised buffers. A join over
# categorical / interval members never consults it, so join resolution stays
# byte-identical for every non-value-invention document. Read-only sentinel —
# see the `_EMPTY_*` invariant block next to `_EMPTY_DERIVED_EXTENTS`.
const _EMPTY_VI_MAPS = (maps=Dict{String,Any}(), map_sets=Dict{String,String}())

# The aggregate range symbol a 1-D DATA COLUMN runs over (CONFORMANCE_SPEC
# §5.5.8 case 2): the column's single declared shape index set names one of the
# node's ranges. `vi_maps.map_sets` records the same fact for a materialised
# value-invention buffer, which has no `variables` entry to read a shape from.
# `_overlap_env_sym` below spells the identical rule for an envelope factor;
# the two are kept apart only because their error contracts differ (an
# unresolvable envelope factor is an OVERLAP diagnostic, an unresolvable key
# column an UNKNOWN_KEY one).
function _join_key_column_sym(col::String, ranges::AbstractDict,
                              sym_to_set::AbstractDict, var_shapes::AbstractDict,
                              vi_maps, pick=:left,
                              order::Union{Nothing,Vector{String}}=nothing)
    setn = get(vi_maps.map_sets, col, nothing)
    if setn === nothing
        shape = get(var_shapes, col, nothing)
        (shape === nothing || length(shape) != 1) && throw(TreeWalkError(
            "E_TREEWALK_JOIN_UNKNOWN_KEY",
            "join key '$col' is neither a loop symbol / index set of this " *
            "aggregate's ranges nor a declared 1-D data column (its shape is " *
            "$(shape === nothing ? "<undeclared>" : shape); §5.5.8 requires a " *
            "single shape index set naming one of the node's ranges)"))
        setn = String(shape[1])
    end
    return _join_sym_for_key(setn, ranges, sym_to_set, pick, order)
end

# The build-time VALUES of a data-column key at each of `positions`. §5.5.8
# requires the column to be build-time constant by the time the gate is built,
# and there are three storages it can already be constant in:
#   * a value-invention MAP buffer (`vi_maps.maps`) — the data-derived bin key;
#   * a const array (`const_arrays`) — host-supplied, derived at the front door,
#     or a `const`-op array observed registered there;
#   * a document-LITERAL array observed still carrying its defining expression
#     (`const` / `makearray`), materialised here through the SAME
#     `_resolve_index_of_makearray` the body's own `index(col, l)` would use, so
#     the gate and the lowered body cannot disagree about the column.
# Anything else (a live state, a runtime-materialised observed) is a build error
# rather than a silently ungated product.
function _join_key_column_values(col::String, positions::Vector{Int}, vi_maps,
                                 const_arrays::AbstractDict, obs_defs::AbstractDict)
    if haskey(vi_maps.maps, col)
        # Deliberately UNVALIDATED: a skolem bin id is whatever the value-
        # invention front door minted (an integer, a tuple), it is only ever
        # compared against another buffer minted the same way, and validating it
        # here would reject documents that work today.
        buf = vi_maps.maps[col]
        return Any[buf[p] for p in positions]
    end
    arr = get(const_arrays, col, nothing)
    if arr === nothing
        defn = get(obs_defs, col, nothing)
        if defn isa OpExpr && (defn::OpExpr).op == "const"
            arr = _const_op_to_array((defn::OpExpr).value)
        elseif defn isa OpExpr && (defn::OpExpr).op == "makearray"
            return Any[_join_literal_at(defn::OpExpr, p, const_arrays) for p in positions]
        end
    end
    arr === nothing && throw(TreeWalkError("E_TREEWALK_JOIN_UNKNOWN_KEY",
        "join key column '$col' has no build-time data: §5.5.8 requires a key " *
        "column to be build-time constant by the time the gate is built (a " *
        "const array, a document-literal array observed, or a value-invention " *
        "map buffer) — it is none of those"))
    ndims(arr) == 1 || throw(TreeWalkError("E_TREEWALK_JOIN_UNKNOWN_KEY",
        "join key column '$col' is $(ndims(arr))-D; §5.5.8 admits a 1-D column"))
    for p in positions
        checkbounds(Bool, arr, p) || throw(TreeWalkError("E_TREEWALK_JOIN_UNKNOWN_KEY",
            "join key column '$col' has $(length(arr)) rows but its range runs " *
            "to position $(maximum(positions))"))
    end
    return Any[arr[p] for p in positions]
end

# One cell of a document-literal `makearray` key column, as a raw value.
function _join_literal_at(mk::OpExpr, p::Int, const_arrays::AbstractDict)
    r = _resolve_index_of_makearray(mk, ASTExpr[IntExpr(Int64(p))],
                                    Dict{String,Tuple{Vector{Int},Vector{Int}}}(),
                                    Dict{String,Int}(), const_arrays)
    r isa NumExpr && return (r::NumExpr).value
    r isa IntExpr && return (r::IntExpr).value
    throw(TreeWalkError("E_TREEWALK_JOIN_UNKNOWN_KEY",
        "join key column cell $p of a `makearray` observed did not reduce to a " *
        "build-time literal (got a $(typeof(r))); §5.5.8 requires the key column " *
        "to be build-time constant"))
end

# Resolve one join-key name to `(sym, positions, values)` — the range symbol it
# denotes, the 1-based positions iterated for it, and the key VALUE at each
# position. Two cases, in the §5.5.8 precedence order (which is §5.5.6's
# "binders shadow declarations" order):
#  1. a BINDER: a loop symbol of this node, or the index set one of its ranges
#     draws `{from}`. The key values are that set's declared members (a
#     categorical set) or its integer IDs (an interval), known from the
#     document registry. Tested FIRST, so a variable that happens to share a
#     name with one of the node's range symbols cannot shadow the loop symbol.
#  2. otherwise a DATA COLUMN: a declared 1-D variable — or the materialised
#     value-invention map buffer that is the special case of one — whose single
#     shape index set names one of this node's ranges. Its values ARE the key
#     values, read as data. This is how a relational port (EPA MOVES/NONROAD)
#     spells every join: one table's `sourceTypeID` column against another's.
function _join_key_sym_pos_vals(key::String, ranges::AbstractDict,
                                index_sets::AbstractDict, sym_to_set::AbstractDict,
                                vi_maps, const_arrays::AbstractDict=Dict{String,Any}(),
                                var_shapes::AbstractDict=Dict{String,Vector{String}}(),
                                obs_defs::AbstractDict=Dict{String,ASTExpr}(),
                                pick=:left,
                                order::Union{Nothing,Vector{String}}=nothing)
    if haskey(ranges, key) || any(==(key), values(sym_to_set))
        sym = _join_sym_for_key(key, ranges, sym_to_set, pick, order)
        positions = _join_key_positions(sym, ranges, index_sets)
        return (sym, positions, _key_member_values(sym, ranges, positions, index_sets))
    end
    sym = _join_key_column_sym(key, ranges, sym_to_set, var_shapes, vi_maps, pick, order)
    positions = _join_key_positions(sym, ranges, index_sets)
    raw = _join_key_column_values(key, positions, vi_maps, const_arrays, obs_defs)
    haskey(vi_maps.maps, key) && return (sym, positions, raw)
    return (sym, positions, Any[_validated_key_datum(v, key) for v in raw])
end

# Map an OVERLAP-gate env-factor list to the aggregate range symbol its axis
# runs over (Phase 2a): the env factors are 1-D const-array buffers, so — exactly
# like an `on` key column — the first factor's 1-D shape index set names the
# range. `var_shapes` maps a factor name to its declared shape (index-set names).
function _overlap_env_sym(env_names::AbstractVector, ranges::AbstractDict,
                          sym_to_set::AbstractDict, var_shapes::AbstractDict,
                          pick=:left,
                          order::Union{Nothing,Vector{String}}=nothing)
    isempty(env_names) && throw(TreeWalkError("E_TREEWALK_JOIN_OVERLAP",
        "overlap join gate has an empty env-factor list"))
    fname = String(env_names[1])
    shape = get(var_shapes, fname, nothing)
    (shape === nothing || length(shape) != 1) && throw(TreeWalkError(
        "E_TREEWALK_JOIN_OVERLAP",
        "overlap join env factor '$fname' must be a 1-D buffer whose shape index " *
        "set names the join range; shape=$(shape === nothing ? "<unknown>" : shape)"))
    return _join_sym_for_key(String(shape[1]), ranges, sym_to_set, pick, order)
end

# Resolve every join clause of an aggregate node into `_JoinGate`s (RFC §5.3 /
# Phase 2a). Operates on the node's ORIGINAL ranges (index-set `{from}` refs
# intact) so it can read categorical members from the document registry; a key
# that names a value-invention map buffer gates on the materialised buffer values
# instead. A `_OverlapJoinSpec` clause resolves to an OVERLAP gate: the broad-
# phase candidate set built ONCE from its envelope factor arrays (in
# `const_arrays`) via the Phase-3a primitive, cached on the gate's `candidates`.
function _resolve_join_gates_for(node::OpExpr, index_sets::AbstractDict,
                                 vi_maps=_EMPTY_VI_MAPS,
                                 const_arrays::AbstractDict=Dict{String,Any}(),
                                 var_shapes::AbstractDict=Dict{String,Vector{String}}(),
                                 obs_defs::AbstractDict=Dict{String,ASTExpr}())
    node.join === nothing && return nothing
    ranges = node.ranges === nothing ? Dict{String,Any}() : node.ranges
    sym_to_set = Dict{String,String}(
        s => spec.from for (s, spec) in ranges if spec isa IndexSetRef)
    # The node's canonical range order, which is what orders the candidates of an
    # index set drawn by SEVERAL ranges (§5.5.8 "Two ranges over one index set").
    order = _canonical_range_order(node.output_idx, ranges)
    # `OpExpr.join_gates` is typed `Union{Vector{_JoinGate},Nothing}` (types.jl
    # defines `_JoinGate` ahead of `OpExpr`), so build the concrete vector here.
    gates = _JoinGate[]
    for clause in node.join
        if clause isa _OverlapJoinSpec
            # OVERLAP gate: envelope candidacy, NOT key equality. `src_env` axis →
            # sym_l, `tgt_env` axis → sym_r; the candidate `(pos_l,pos_r)` set is
            # keyed to match, built once here from the const-array envelope factors.
            sym_l = _overlap_env_sym(clause.src_env, ranges, sym_to_set, var_shapes,
                                     :left, order)
            sym_r = _overlap_env_sym(clause.tgt_env, ranges, sym_to_set, var_shapes,
                                     :right, order)
            cands = _overlap_candidate_set(clause.src_env, clause.tgt_env, const_arrays;
                                           eps=clause.eps)
            push!(gates, _JoinGate(sym_l, sym_r, Dict{Int,Int}(), Dict{Int,Int}(),
                                   _OverlapIndex(cands)))
        else                           # clause :: an `on` pair list (`_OnJoinSpec`)
            # A clause's `syms` names the two range symbols its pairs are read
            # at; without it the DEFAULT side assignment applies, which is inert
            # unless one index set is drawn by several of the node's ranges
            # (§5.5.8 "Two ranges over one index set").
            csyms = _clause_syms(clause)
            if csyms !== nothing
                for cs in csyms
                    haskey(ranges, cs) || throw(TreeWalkError(
                        "E_TREEWALK_JOIN_SYMS_UNKNOWN",
                        "`join.syms` names '$cs', which is not a range symbol of " *
                        "this aggregate ($(sort!(String[String(k) for k in keys(ranges)]))); " *
                        "both entries must name one of its `ranges` " *
                        "(CONFORMANCE_SPEC §5.5.8)"))
                end
            end
            pick_l = csyms === nothing ? :left : csyms[1]
            pick_r = csyms === nothing ? :right : csyms[2]
            # Resolve EVERY pair of the clause first. Pairs over the same two
            # loop symbols are ONE composite key (§5.5.8 / BEHAV-10-B-002), and
            # it is that composite match set — not the first pair's, which is a
            # superset — that drives. Pairs over different symbol pairs stay
            # separate gates, all of them ANDed by `_join_admits`.
            resolved = Tuple{String,String,Vector{Int},Vector{Int},Vector{Any},Vector{Any}}[]
            for (lkey, rkey) in clause
                sym_l, pos_l, vals_l = _join_key_sym_pos_vals(lkey, ranges, index_sets,
                    sym_to_set, vi_maps, const_arrays, var_shapes, obs_defs, pick_l, order)
                sym_r, pos_r, vals_r = _join_key_sym_pos_vals(rkey, ranges, index_sets,
                    sym_to_set, vi_maps, const_arrays, var_shapes, obs_defs, pick_r, order)
                push!(resolved, (sym_l, sym_r, pos_l, pos_r, vals_l, vals_r))
            end
            indexed = Set{Tuple{String,String}}()
            for r in resolved
                codes_l, codes_r = _encode_join_keys(r[5], r[6])
                # The FIRST gate of each symbol-pair group carries the composite
                # match index; the rest of the group stay pure code tests, so
                # admission is unchanged and only the enumeration extent moves.
                cands = nothing
                if !((r[1], r[2]) in indexed) && !_join_on_gate_disabled()
                    push!(indexed, (r[1], r[2]))
                    prs = _on_gate_match_pairs(
                        [g for g in resolved if g[1] == r[1] && g[2] == r[2]])
                    prs === nothing || (cands = _OverlapIndex(Set{Tuple{Int,Int}}(prs)))
                end
                push!(gates, _JoinGate(r[1], r[2],
                    Dict{Int,Int}(zip(r[3], codes_l)),
                    Dict{Int,Int}(zip(r[4], codes_r)), cands))
            end
        end
    end
    return gates
end

# True iff every join pair's key columns are equal under `binding` (symbol →
# range position). `nothing` gates (no join) admit everything. `gates` is the
# concrete `Vector{_JoinGate}` from `OpExpr.join_gates`, so the loop body is
# type-stable — needed in the expansion product loops that call this per
# contracted tuple.
function _join_admits(gates, binding::AbstractDict)
    gates === nothing && return true
    for g in gates
        if g.candidates === nothing || !isempty(g.codes_l)
            # VALUE-EQUALITY gate: equal bucket codes at the two range positions.
            # Reached whether or not the gate also carries a drivable match index
            # — the codes ARE the semantics, the index only an enumeration
            # extent, and re-testing them per leaf keeps the driven walk checked
            # against the same predicate the undriven product applies. (An
            # OVERLAP gate has empty `codes_l` and falls through.)
            g.codes_l[binding[g.sym_l]] == g.codes_r[binding[g.sym_r]] || return false
        else
            # OVERLAP gate (Phase 2a): the (pos_l, pos_r) pair must be in the
            # prebuilt broad-phase candidate set (envelope candidacy).
            (binding[g.sym_l], binding[g.sym_r]) in g.candidates || return false
        end
    end
    return true
end

# True if any node in the subtree carries a `join` clause — used to skip the
# resolution pre-pass (and stay byte-identical) for join-free documents.
# INTENTIONAL field subset (behavior-pinned — do NOT widen to `child_exprs`
# coverage without a spec decision): walks args / expr_body / values / filter
# only, NOT lower / upper / key / table_axes / ranges bounds. A join buried in
# e.g. an integral bound would therefore skip the pre-pass even though
# `_resolve_join_in_expr` does recurse those fields — flagged for Wave 3.
# Identity-deduped (ESS-0hh): a pure existence predicate is path-multiplicity-
# insensitive, so the visited set is exactly equivalent — and O(nodes) on a
# structurally-shared tree instead of once per path.
_expr_has_join(expr::OpExpr) = _expr_has_join(expr, IdDict{OpExpr,Nothing}())
function _expr_has_join(expr::OpExpr, seen::IdDict{OpExpr,Nothing})
    expr.join !== nothing && return true
    haskey(seen, expr) && return false
    seen[expr] = nothing
    for a in expr.args
        a isa OpExpr && _expr_has_join(a, seen) && return true
    end
    expr.expr_body isa OpExpr && _expr_has_join(expr.expr_body::OpExpr, seen) && return true
    if expr.values !== nothing
        for v in expr.values
            v isa OpExpr && _expr_has_join(v, seen) && return true
        end
    end
    expr.filter isa OpExpr && _expr_has_join(expr.filter::OpExpr, seen) && return true
    return false
end
_expr_has_join(::ASTExpr) = false
_eq_has_join(eq::Equation) = _expr_has_join(eq.lhs) || _expr_has_join(eq.rhs)

# Rewrite each aggregate node's `join` clauses into build-time `join_gates`
# against the document index-set registry, preserving every other field. Runs
# BEFORE index-set range resolution so categorical `{from}` refs are still
# present for member lookup. The wire `join`/`filter` fields are carried through
# unchanged (serialization round-trips them); only the internal `join_gates` is
# populated.
function _resolve_join_in_expr(expr::OpExpr, index_sets::AbstractDict, vi_maps=_EMPTY_VI_MAPS,
                               const_arrays::AbstractDict=Dict{String,Any}(),
                               var_shapes::AbstractDict=Dict{String,Vector{String}}(),
                               obs_defs::AbstractDict=Dict{String,ASTExpr}())
    new_args = ASTExpr[_resolve_join_in_expr(a, index_sets, vi_maps, const_arrays, var_shapes, obs_defs) for a in expr.args]
    new_body = expr.expr_body === nothing ? nothing : _resolve_join_in_expr(expr.expr_body, index_sets, vi_maps, const_arrays, var_shapes, obs_defs)
    new_values = expr.values === nothing ? nothing :
                 ASTExpr[_resolve_join_in_expr(v, index_sets, vi_maps, const_arrays, var_shapes, obs_defs) for v in expr.values]
    new_lower = expr.lower === nothing ? nothing : _resolve_join_in_expr(expr.lower, index_sets, vi_maps, const_arrays, var_shapes, obs_defs)
    new_upper = expr.upper === nothing ? nothing : _resolve_join_in_expr(expr.upper, index_sets, vi_maps, const_arrays, var_shapes, obs_defs)
    new_filter = expr.filter === nothing ? nothing : _resolve_join_in_expr(expr.filter, index_sets, vi_maps, const_arrays, var_shapes, obs_defs)
    gates = (_is_aggregate_op(expr.op) && expr.join !== nothing) ?
            _resolve_join_gates_for(expr, index_sets, vi_maps, const_arrays, var_shapes, obs_defs) : expr.join_gates
    return reconstruct(expr; args=new_args, expr_body=new_body,
                       values=new_values, lower=new_lower, upper=new_upper,
                       filter=new_filter, join_gates=gates)
end
_resolve_join_in_expr(expr::ASTExpr, ::AbstractDict, vi_maps=_EMPTY_VI_MAPS,
                      const_arrays::AbstractDict=Dict{String,Any}(),
                      var_shapes::AbstractDict=Dict{String,Vector{String}}(),
                      obs_defs::AbstractDict=Dict{String,ASTExpr}()) = expr

_resolve_join_in_eq(eq::Equation, index_sets::AbstractDict, vi_maps=_EMPTY_VI_MAPS,
                    const_arrays::AbstractDict=Dict{String,Any}(),
                    var_shapes::AbstractDict=Dict{String,Vector{String}}(),
                    obs_defs::AbstractDict=Dict{String,ASTExpr}()) =
    Equation(_resolve_join_in_expr(eq.lhs, index_sets, vi_maps, const_arrays, var_shapes, obs_defs),
             _resolve_join_in_expr(eq.rhs, index_sets, vi_maps, const_arrays, var_shapes, obs_defs);
             _comment=eq._comment)

# Resolve join gates across a vector of equations. Returns the input unchanged
# when no equation uses a `join` clause (byte-identical for join-free files).
# `vi_maps` carries any value-invention map buffers a `join.on` gates on (RFC
# §5.3); `const_arrays` + `var_shapes` supply the envelope factor arrays and
# their 1-D shapes a Phase-2a `join.overlap` gate resolves against, and — since
# §5.5.8 — the DATA COLUMNS an `on` key may name and the shapes that map each to
# its range symbol. `obs_defs` carries the remaining observed definitions, from
# which a document-literal key column is materialised on demand.
function _resolve_join_gates(eqs::Vector{Equation}, index_sets::AbstractDict,
                             vi_maps=_EMPTY_VI_MAPS,
                             const_arrays::AbstractDict=Dict{String,Any}(),
                             var_shapes::AbstractDict=Dict{String,Vector{String}}(),
                             obs_defs::AbstractDict=Dict{String,ASTExpr}())
    any(_eq_has_join, eqs) || return eqs
    return Equation[_resolve_join_in_eq(eq, index_sets, vi_maps, const_arrays, var_shapes, obs_defs) for eq in eqs]
end
