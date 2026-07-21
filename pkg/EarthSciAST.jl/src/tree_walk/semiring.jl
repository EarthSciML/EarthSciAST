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

# Resolve a join-key name to the range symbol it denotes (RFC §5.3): either a
# declared range symbol directly, or the name of an index set bound by exactly
# one range symbol via `{from: <name>}` (naming the dimension instead of the loop
# symbol). Zero or multiple bindings are build-time errors.
function _join_sym_for_key(key::String, ranges::AbstractDict, sym_to_set::AbstractDict)
    haskey(ranges, key) && return key
    candidates = sort!(String[s for (s, setn) in sym_to_set if setn == key])
    if length(candidates) == 1
        return candidates[1]
    elseif isempty(candidates)
        throw(TreeWalkError("E_TREEWALK_JOIN_UNKNOWN_KEY",
            "join key '$key' is neither a declared range symbol nor an index set " *
            "bound by a range of this aggregate (RFC semiring-faq-unified-ir §5.3)"))
    else
        throw(TreeWalkError("E_TREEWALK_JOIN_AMBIGUOUS_KEY",
            "join key '$key' names an index set bound by multiple range symbols " *
            "$(candidates); reference the range symbol directly (RFC §5.3)"))
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

# The empty value-invention map registry: no materialised buffers. A join over
# categorical / interval members never consults it, so join resolution stays
# byte-identical for every non-value-invention document. Read-only sentinel —
# see the `_EMPTY_*` invariant block next to `_EMPTY_DERIVED_EXTENTS`.
const _EMPTY_VI_MAPS = (maps=Dict{String,Any}(), map_sets=Dict{String,String}())

# Resolve one join-key name to `(sym, positions, values)` — the range symbol it
# denotes, the 1-based positions iterated for it, and the key VALUE at each
# position. Two cases (RFC §5.3):
#  - the key names a value-invention MAP buffer (e.g. `src_bin`, materialised by
#    the front-door): the broad-phase bin key is DATA-DERIVED, so it is not a
#    categorical index-set member — read the key value per position from the
#    buffer `vi_maps.maps[key]`, and find the range symbol via the buffer's
#    declared 1-D shape index set (`vi_maps.map_sets[key]`);
#  - otherwise the key is a range symbol / index-set name whose key column is the
#    categorical member (or interval integer index) from the document registry.
function _join_key_sym_pos_vals(key::String, ranges::AbstractDict,
                                index_sets::AbstractDict, sym_to_set::AbstractDict,
                                vi_maps)
    if haskey(vi_maps.maps, key)
        setn = get(vi_maps.map_sets, key, nothing)
        setn === nothing && throw(TreeWalkError("E_TREEWALK_JOIN_UNKNOWN_KEY",
            "value-invention join key '$key' has no recorded 1-D shape index set " *
            "(RFC semiring-faq-unified-ir §5.3)"))
        sym = _join_sym_for_key(setn, ranges, sym_to_set)
        positions = _join_key_positions(sym, ranges, index_sets)
        buf = vi_maps.maps[key]
        vals = Any[buf[p] for p in positions]
        return (sym, positions, vals)
    end
    sym = _join_sym_for_key(key, ranges, sym_to_set)
    positions = _join_key_positions(sym, ranges, index_sets)
    vals = _key_member_values(sym, ranges, positions, index_sets)
    return (sym, positions, vals)
end

# Map an OVERLAP-gate env-factor list to the aggregate range symbol its axis
# runs over (Phase 2a): the env factors are 1-D const-array buffers, so — exactly
# like an `on` key column — the first factor's 1-D shape index set names the
# range. `var_shapes` maps a factor name to its declared shape (index-set names).
function _overlap_env_sym(env_names::AbstractVector, ranges::AbstractDict,
                          sym_to_set::AbstractDict, var_shapes::AbstractDict)
    isempty(env_names) && throw(TreeWalkError("E_TREEWALK_JOIN_OVERLAP",
        "overlap join gate has an empty env-factor list"))
    fname = String(env_names[1])
    shape = get(var_shapes, fname, nothing)
    (shape === nothing || length(shape) != 1) && throw(TreeWalkError(
        "E_TREEWALK_JOIN_OVERLAP",
        "overlap join env factor '$fname' must be a 1-D buffer whose shape index " *
        "set names the join range; shape=$(shape === nothing ? "<unknown>" : shape)"))
    return _join_sym_for_key(String(shape[1]), ranges, sym_to_set)
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
                                 var_shapes::AbstractDict=Dict{String,Vector{String}}())
    node.join === nothing && return nothing
    ranges = node.ranges === nothing ? Dict{String,Any}() : node.ranges
    sym_to_set = Dict{String,String}(
        s => spec.from for (s, spec) in ranges if spec isa IndexSetRef)
    # `OpExpr.join_gates` is typed `Union{Vector{_JoinGate},Nothing}` (types.jl
    # defines `_JoinGate` ahead of `OpExpr`), so build the concrete vector here.
    gates = _JoinGate[]
    for clause in node.join
        if clause isa _OverlapJoinSpec
            # OVERLAP gate: envelope candidacy, NOT key equality. `src_env` axis →
            # sym_l, `tgt_env` axis → sym_r; the candidate `(pos_l,pos_r)` set is
            # keyed to match, built once here from the const-array envelope factors.
            sym_l = _overlap_env_sym(clause.src_env, ranges, sym_to_set, var_shapes)
            sym_r = _overlap_env_sym(clause.tgt_env, ranges, sym_to_set, var_shapes)
            cands = _overlap_candidate_set(clause.src_env, clause.tgt_env, const_arrays;
                                           eps=clause.eps)
            push!(gates, _JoinGate(sym_l, sym_r, Dict{Int,Int}(), Dict{Int,Int}(), cands))
        else                           # clause :: Vector{Tuple{String,String}}
            for (lkey, rkey) in clause
                sym_l, pos_l, vals_l = _join_key_sym_pos_vals(lkey, ranges, index_sets, sym_to_set, vi_maps)
                sym_r, pos_r, vals_r = _join_key_sym_pos_vals(rkey, ranges, index_sets, sym_to_set, vi_maps)
                codes_l, codes_r = _encode_join_keys(vals_l, vals_r)
                push!(gates, _JoinGate(sym_l, sym_r,
                    Dict{Int,Int}(zip(pos_l, codes_l)),
                    Dict{Int,Int}(zip(pos_r, codes_r))))
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
        if g.candidates === nothing
            # Bin-equality gate: equal bucket codes at the two range positions.
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
                               var_shapes::AbstractDict=Dict{String,Vector{String}}())
    new_args = ASTExpr[_resolve_join_in_expr(a, index_sets, vi_maps, const_arrays, var_shapes) for a in expr.args]
    new_body = expr.expr_body === nothing ? nothing : _resolve_join_in_expr(expr.expr_body, index_sets, vi_maps, const_arrays, var_shapes)
    new_values = expr.values === nothing ? nothing :
                 ASTExpr[_resolve_join_in_expr(v, index_sets, vi_maps, const_arrays, var_shapes) for v in expr.values]
    new_lower = expr.lower === nothing ? nothing : _resolve_join_in_expr(expr.lower, index_sets, vi_maps, const_arrays, var_shapes)
    new_upper = expr.upper === nothing ? nothing : _resolve_join_in_expr(expr.upper, index_sets, vi_maps, const_arrays, var_shapes)
    new_filter = expr.filter === nothing ? nothing : _resolve_join_in_expr(expr.filter, index_sets, vi_maps, const_arrays, var_shapes)
    gates = (_is_aggregate_op(expr.op) && expr.join !== nothing) ?
            _resolve_join_gates_for(expr, index_sets, vi_maps, const_arrays, var_shapes) : expr.join_gates
    return reconstruct(expr; args=new_args, expr_body=new_body,
                       values=new_values, lower=new_lower, upper=new_upper,
                       filter=new_filter, join_gates=gates)
end
_resolve_join_in_expr(expr::ASTExpr, ::AbstractDict, vi_maps=_EMPTY_VI_MAPS,
                      const_arrays::AbstractDict=Dict{String,Any}(),
                      var_shapes::AbstractDict=Dict{String,Vector{String}}()) = expr

_resolve_join_in_eq(eq::Equation, index_sets::AbstractDict, vi_maps=_EMPTY_VI_MAPS,
                    const_arrays::AbstractDict=Dict{String,Any}(),
                    var_shapes::AbstractDict=Dict{String,Vector{String}}()) =
    Equation(_resolve_join_in_expr(eq.lhs, index_sets, vi_maps, const_arrays, var_shapes),
             _resolve_join_in_expr(eq.rhs, index_sets, vi_maps, const_arrays, var_shapes);
             _comment=eq._comment)

# Resolve join gates across a vector of equations. Returns the input unchanged
# when no equation uses a `join` clause (byte-identical for join-free files).
# `vi_maps` carries any value-invention map buffers a `join.on` gates on (RFC
# §5.3); `const_arrays` + `var_shapes` supply the envelope factor arrays and
# their 1-D shapes a Phase-2a `join.overlap` gate resolves against.
function _resolve_join_gates(eqs::Vector{Equation}, index_sets::AbstractDict,
                             vi_maps=_EMPTY_VI_MAPS,
                             const_arrays::AbstractDict=Dict{String,Any}(),
                             var_shapes::AbstractDict=Dict{String,Vector{String}}())
    any(_eq_has_join, eqs) || return eqs
    return Equation[_resolve_join_in_eq(eq, index_sets, vi_maps, const_arrays, var_shapes) for eq in eqs]
end
