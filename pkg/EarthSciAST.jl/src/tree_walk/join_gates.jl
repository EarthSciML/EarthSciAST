# tree_walk/join_gates.jl — build-time value-equality and overlap joins: the
# gates an aggregate's `join` clauses resolve to, and their admission test.

# ============================================================
# 5c-join. Value-equality joins (RFC semiring-faq-unified-ir §5.3)
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
#
# `via` says WHICH resolution step is asking, and only one of the two has a gap
# the default can fill:
#   * `:binder` — the key names an INDEX SET (§5.5.8 precedence step 1). An
#     author who meant a particular side can already name the RANGE SYMBOL
#     instead, which is what the diagnostic advises, so an ambiguous set
#     stays an error and only an explicit `syms` resolves it.
#   * `:column_axis` — the symbol came from a DATA COLUMN's declared 1-D axis
#     (step 2). Here there is nothing else the author can write: the pair holds
#     column names and the axis is a property of the column, not of the clause.
#     This is the self-join case, and the one the default exists for.
function _join_sym_for_key(
        key::String, ranges::AbstractDict, sym_to_set::AbstractDict,
        pick = :left, order::Union{Nothing, Vector{String}} = nothing,
        via::Symbol = :binder
    )
    if haskey(ranges, key)
        # A key naming a range symbol OUTRIGHT is already unambiguous; `syms`
        # may not contradict it.
        (pick isa AbstractString && String(pick) != key) && throw(
            TreeWalkError(
                "E_TREEWALK_JOIN_SYMS_CONFLICT",
                "join key '$key' names a range symbol of this aggregate, but this " *
                    "clause's `syms` puts that side on '$(pick)'; a key naming a range " *
                    "symbol must name its own side's (CONFORMANCE_SPEC §5.5.8)"
            )
        )
        return key
    end
    ord = order === nothing ? _canonical_range_order(nothing, ranges) : order
    rank(s) = something(findfirst(==(s), ord), length(ord) + 1)
    candidates = sort(String[s for (s, setn) in sym_to_set if setn == key]; by = rank)
    if pick isa AbstractString
        want = String(pick)
        want in candidates && return want
        throw(
            TreeWalkError(
                "E_TREEWALK_JOIN_SYMS_CONFLICT",
                "this clause's `syms` puts a side on range symbol '$want', but the " *
                    "key resolving through index set '$key' is read at one of " *
                    "$(candidates) — '$want' does not draw that index set " *
                    "(CONFORMANCE_SPEC §5.5.8)"
            )
        )
    end
    if length(candidates) == 1
        return candidates[1]
    elseif isempty(candidates)
        throw(
            TreeWalkError(
                "E_TREEWALK_JOIN_UNKNOWN_KEY",
                "join key '$key' is neither a declared range symbol nor an index set " *
                    "bound by a range of this aggregate (RFC semiring-faq-unified-ir §5.3)"
            )
        )
    elseif via === :binder
        # A key that NAMES the index set can already say which side it means by
        # naming the range symbol instead, so the rejection stands.
        throw(
            TreeWalkError(
                "E_TREEWALK_JOIN_AMBIGUOUS_KEY",
                "join key '$key' names an index set bound by multiple range symbols " *
                    "$(candidates); reference the range symbol directly, or name this " *
                    "clause's two sides with `join.syms` (RFC §5.3 / CONFORMANCE_SPEC §5.5.8)"
            )
        )
    elseif length(candidates) == 2
        return candidates[pick === :right ? 2 : 1]
    else
        throw(
            TreeWalkError(
                "E_TREEWALK_JOIN_AMBIGUOUS_KEY",
                "index set '$key' is drawn by $(length(candidates)) range symbols of " *
                    "this aggregate ($(candidates)), so which one a key column over it is " *
                    "read at is not determined; name the two sides explicitly with this " *
                    "clause's `join.syms` (CONFORMANCE_SPEC §5.5.8 \"Two ranges over one " *
                    "index set\")"
            )
        )
    end
end

# Validate one member used as a join key (RFC §5.3 / §5.7): keys must be
# exact-equality types — integer IDs or string members. Floats (equality is not
# portable across bindings), booleans, and nulls are build-time errors.
function _validated_key_member(m, set_name::String)
    m === nothing && throw(
        TreeWalkError(
            "E_TREEWALK_JOIN_NULL_KEY",
            "null member in join key index set '$set_name': emitting null into a key " *
                "column is a build-time error (RFC semiring-faq-unified-ir §5.3)"
        )
    )
    if m isa Bool
        throw(
            TreeWalkError(
                "E_TREEWALK_JOIN_KEY_TYPE",
                "boolean member $(repr(m)) in join key index set '$set_name' is not an " *
                    "exact-equality key type (RFC §5.3)"
            )
        )
    elseif m isa AbstractFloat
        throw(
            TreeWalkError(
                "E_TREEWALK_JOIN_FLOAT_KEY",
                "floating-point member $(repr(m)) in join key index set '$set_name': " *
                    "float join keys are forbidden — equality is not portable across " *
                    "bindings (RFC semiring-faq-unified-ir §5.3 / §5.7 rule 1)"
            )
        )
    elseif m isa Integer
        return Int(m)
    elseif m isa AbstractString
        return String(m)
    else
        throw(
            TreeWalkError(
                "E_TREEWALK_JOIN_KEY_TYPE",
                "unsupported join key member type $(typeof(m)) in index set " *
                    "'$set_name'; keys must be integer IDs or categorical members (RFC §5.3)"
            )
        )
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
    v === nothing && throw(
        TreeWalkError(
            "E_TREEWALK_JOIN_NULL_KEY",
            "null value in join key column '$col_name': emitting null into a key " *
                "column is a build-time error (CONFORMANCE_SPEC §5.5.8)"
        )
    )
    if v isa Bool
        throw(
            TreeWalkError(
                "E_TREEWALK_JOIN_KEY_TYPE",
                "boolean value $(repr(v)) in join key column '$col_name' is not an " *
                    "exact-equality key type (CONFORMANCE_SPEC §5.5.8)"
            )
        )
    elseif v isa Integer
        return Int(v)
    elseif v isa AbstractString
        return String(v)
    elseif v isa AbstractFloat
        (isfinite(v) && v == round(v)) || throw(
            TreeWalkError(
                "E_TREEWALK_JOIN_FLOAT_KEY",
                "non-integral value $(repr(v)) in join key column '$col_name': a " *
                    "float-stored key column is admissible ONLY where every value is " *
                    "exactly integral (an integer ID column) — float equality is not " *
                    "portable across bindings (CONFORMANCE_SPEC §5.5.8 / §5.5.1 rule 1)"
            )
        )
        return Int(v)
    else
        throw(
            TreeWalkError(
                "E_TREEWALK_JOIN_KEY_TYPE",
                "unsupported join key value type $(typeof(v)) in column " *
                    "'$col_name'; keys must be integer IDs or categorical members " *
                    "(CONFORMANCE_SPEC §5.5.8)"
            )
        )
    end
end

# The 1-based range positions iterated for a join-key symbol — the loop-variable
# values the expansion will see (categorical / interval `{from}` resolve to
# `1:size`; a dense `[lo,hi]` tuple expands to `lo:hi`). Runs on the ORIGINAL
# (pre-index-set-resolution) ranges so the `{from}` reference is still present.
function _join_key_positions(sym::String, ranges::AbstractDict, index_sets::AbstractDict)
    spec = get(ranges, sym, nothing)
    spec === nothing && throw(
        TreeWalkError(
            "E_TREEWALK_JOIN_UNKNOWN_KEY",
            "join key symbol '$sym' is not a range of this aggregate (RFC §5.3)"
        )
    )
    if spec isa IndexSetRef
        haskey(index_sets, spec.from) || throw(
            TreeWalkError(
                "E_TREEWALK_UNDECLARED_INDEX_SET",
                "undeclared index set '$(spec.from)' referenced by join key '$sym' (RFC §5.2)"
            )
        )
        is = index_sets[spec.from]
        if is.kind == "categorical"
            n = is.members === nothing ? 0 : length(is.members)
            return collect(1:n)
        elseif is.kind == "interval"
            is.size === nothing && throw(
                TreeWalkError(
                    "E_TREEWALK_INDEX_SET_INCOMPLETE",
                    "interval index set '$(spec.from)' requires a `size`"
                )
            )
            return collect(1:Int(is.size))
        else
            throw(
                TreeWalkError(
                    "E_TREEWALK_JOIN_KEY_KIND",
                    "join key index set '$(spec.from)' has kind '$(is.kind)'; only " *
                        "'interval' (integer IDs) and 'categorical' keys can be equi-joined " *
                        "(RFC §5.3)"
                )
            )
        end
    end
    return collect(_expand_int_range(spec))
end

# The key VALUE at each range position for a join-key symbol (RFC §5.3): a
# categorical range yields its declared members (validated as exact-equality
# keys); an interval or dense integer range yields the integer index itself.
function _key_member_values(
        sym::String, ranges::AbstractDict, positions::Vector{Int},
        index_sets::AbstractDict
    )
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
        throw(
            TreeWalkError(
                "E_TREEWALK_JOIN_KEY_TYPE",
                "join pair couples incompatible key types (integer IDs vs categorical " *
                    "string members); both sides must be the same exact-equality type " *
                    "(RFC semiring-faq-unified-ir §5.3)"
            )
        )
    end
    # Keys of one concrete type (the integer IDs)
    # are coded through a typed table: the same values, the same `isless`
    # order and the same `isequal` buckets as the `Any` table, without a
    # dynamic dispatch per comparison.
    T = mapreduce(
        typeof, typejoin, vals_l; init = mapreduce(
            typeof, typejoin, vals_r;
            init = Union{}
        )
    )
    isconcretetype(T) && return _encode_join_keys_typed(
        convert(Vector{T}, vals_l),
        convert(Vector{T}, vals_r)
    )
    return _encode_join_keys_typed(vals_l, vals_r)
end

function _encode_join_keys_typed(vals_l::Vector{T}, vals_r::Vector{T}) where {T}
    table = sort!(unique(vcat(vals_l, vals_r)))
    code_of = Dict{T, Int}(v => i for (i, v) in enumerate(table))
    return (Int[code_of[v] for v in vals_l], Int[code_of[v] for v in vals_r])
end

# Off, an `on` clause resolves to the equality CODES only and attaches no match
# index, so the gate filters the full product instead of driving it. That is the
# differential oracle for the driver: the admitted leaf set is identical either
# way, so any difference in the ANSWER is a driver bug, and the visit counts
# must differ or the gate never fired.
_join_on_gate_disabled() = !_compiler_plan_now().join_on_gate

# The DRIVABLE match set of one composite `on` key (CONFORMANCE_SPEC §5.5.8):
# `{ (pos_l, pos_r) : key_l(pos_l) == key_r(pos_r) }`, built ONCE per node.
#
# `group` is every resolved pair of the clause over the SAME two loop symbols —
# §5.5.8's COMPOSITE KEY, which matches iff every listed pair agrees. The key of
# a position is therefore the §5.5.1 rule-4 key TUPLE of that position's
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
_on_gate_match_pairs(group) =
    _on_gate_match_pairs(group, [_encode_join_keys(g[5], g[6]) for g in group])

function _on_gate_match_pairs(group, coded::AbstractVector)
    sym_l, sym_r = group[1][1], group[1][2]
    sym_l == sym_r && return nothing
    pos_l, pos_r = group[1][3], group[1][4]
    # A SINGLE pair — the overwhelmingly common case, and the one that has to
    # stay cheap at 1e5 rows — keys on the bucket code itself; a composite key
    # keys on the per-pair code vector, which orders lexicographically exactly as
    # the §5.5.1 rule-4 key tuple does.
    length(coded) == 1 && return _int_code_equijoin(pos_l, pos_r, coded[1][1], coded[1][2])
    kl = Dict{Int, Vector{Int}}(p => Int[c[1][i] for c in coded] for (i, p) in enumerate(pos_l))
    kr = Dict{Int, Vector{Int}}(p => Int[c[2][i] for c in coded] for (i, p) in enumerate(pos_r))
    matches = Relational.equijoin(pos_l, pos_r; on_left = p -> kl[p], on_right = p -> kr[p])
    return Tuple{Int, Int}[(Int(m[1]), Int(m[2])) for m in matches]
end

# `Relational.equijoin` on one integer bucket code per position, typed: the
# pairs whose codes are equal, sorted by (code, left position, right
# position) — the order `equijoin` sorts its output into.
function _int_code_equijoin(pos_l, pos_r, codes_l::Vector{Int}, codes_r::Vector{Int})
    buckets = Dict{Int, Vector{Int}}()
    for (i, p) in enumerate(pos_r)
        push!(get!(() -> Int[], buckets, codes_r[i]), Int(p))
    end
    out = Tuple{Int, Int, Int}[]
    for (i, p) in enumerate(pos_l)
        b = get(buckets, codes_l[i], nothing)
        b === nothing && continue
        for q in b
            push!(out, (codes_l[i], Int(p), q))
        end
    end
    sort!(out)
    return Tuple{Int, Int}[(t[2], t[3]) for t in out]
end

# Map an OVERLAP-gate env-factor list to the aggregate range symbol its axis
# runs over. The list's length fixes every factor's rank
# (`_overlap_env_rank`, CONFORMANCE_SPEC §5.5.6): 2 or 4 names are 1-D columns,
# 1 name a `[pos, verts, coord]` RING stack. In both forms a factor's FIRST axis
# is its position axis, so the first factor's first shape index set names the
# range — the rule the setup path's `_geo_overlap_gate` also uses. Unlike that
# path, which declines to the ungated sweep on a mismatch, this throws.
# `var_shapes` maps a factor name to its declared shape (index-set names).
function _overlap_env_sym(
        env_names::AbstractVector, ranges::AbstractDict,
        sym_to_set::AbstractDict, var_shapes::AbstractDict,
        pick = :left,
        order::Union{Nothing, Vector{String}} = nothing
    )
    isempty(env_names) && throw(
        TreeWalkError(
            "E_TREEWALK_JOIN_OVERLAP",
            "overlap join gate has an empty env-factor list"
        )
    )
    rank = _overlap_env_rank(length(env_names))
    rank === nothing && throw(
        TreeWalkError(
            "E_TREEWALK_JOIN_OVERLAP",
            "overlap join env must name 1 (a [pos, verts, coord] ring stack), " *
                "2 (point [x, y]) or 4 (rect [xmin, ymin, xmax, ymax]) factors; " *
                "got $(length(env_names)): $(String[String(n) for n in env_names]) " *
                "(CONFORMANCE_SPEC §5.5.6)"
        )
    )
    for f in env_names
        fname = String(f)
        shape = get(var_shapes, fname, nothing)
        (shape === nothing || length(shape) != rank) && throw(
            TreeWalkError(
                "E_TREEWALK_JOIN_OVERLAP",
                "overlap join env factor '$fname' must be " *
                    (rank == 1 ? "a 1-D buffer" : "a [pos, verts, coord] 3-D ring stack") *
                    " whose first shape index set names the join range; " *
                    "shape=$(shape === nothing ? "<unknown>" : shape)"
            )
        )
    end
    shape = var_shapes[String(env_names[1])]
    return _join_sym_for_key(
        String(shape[1]), ranges, sym_to_set, pick, order,
        :column_axis
    )
end

# An overlap gate's envelope factors MUST be build-time data (CONFORMANCE_SPEC
# §5.5.6): the candidate set is built once, here, and never rebuilt. A factor
# missing from `arrays` (the build-time storage `_resolve_join_gates_for` is
# handed) is most often a live forcing array, so say that instead of letting
# `_envelope_vectors` raise a bare `KeyError`.
function _require_build_time_env(env_names::AbstractVector, arrays::AbstractDict)
    for f in env_names
        fname = String(f)
        haskey(arrays, fname) || throw(
            TreeWalkError(
                "E_TREEWALK_JOIN_OVERLAP",
                "overlap join env factor '$fname' is not build-time data: an " *
                    "envelope factor must be a const array, a const observed or " *
                    "setup geometry, not a live forcing / data-loader array or a " *
                    "state (CONFORMANCE_SPEC §5.5.6)"
            )
        )
    end
    return nothing
end

# Resolve every join clause of an aggregate node into `_JoinGate`s (RFC §5.3). Operates on the node's ORIGINAL ranges (index-set `{from}` refs
# intact) so it can read categorical members from the document registry; a key
# that names a value-invention map buffer gates on the materialised buffer values
# instead. A `_OverlapJoinSpec` clause resolves to an OVERLAP gate: the broad-
# phase candidate set built ONCE from its envelope factor arrays (in
# `const_arrays`) via the Phase-3a primitive, cached on the gate's `candidates`.
function _resolve_join_gates_for(
        node::OpExpr, index_sets::AbstractDict,
        vi_maps = _EMPTY_VI_MAPS,
        const_arrays::AbstractDict = Dict{String, Any}(),
        var_shapes::AbstractDict = Dict{String, Vector{String}}(),
        obs_defs::AbstractDict = Dict{String, ASTExpr}()
    )
    node.join === nothing && return nothing
    ranges = node.ranges === nothing ? Dict{String, Any}() : node.ranges
    sym_to_set = Dict{String, String}(
        s => spec.from for (s, spec) in ranges if spec isa IndexSetRef
    )
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
            sym_l = _overlap_env_sym(
                clause.src_env, ranges, sym_to_set, var_shapes,
                :left, order
            )
            sym_r = _overlap_env_sym(
                clause.tgt_env, ranges, sym_to_set, var_shapes,
                :right, order
            )
            _require_build_time_env(clause.src_env, const_arrays)
            _require_build_time_env(clause.tgt_env, const_arrays)
            cands = _overlap_candidate_set(
                clause.src_env, clause.tgt_env, const_arrays;
                eps = clause.eps
            )
            push!(
                gates, _JoinGate(
                    sym_l, sym_r, Dict{Int, Int}(), Dict{Int, Int}(),
                    _OverlapIndex(cands)
                )
            )
        else                           # clause :: an `on` pair list (`_OnJoinSpec`)
            # A clause's `syms` names the two range symbols its pairs are read
            # at; without it the DEFAULT side assignment applies, which is inert
            # unless one index set is drawn by several of the node's ranges
            # (§5.5.8 "Two ranges over one index set").
            csyms = _clause_syms(clause)
            if csyms !== nothing
                for cs in csyms
                    haskey(ranges, cs) || throw(
                        TreeWalkError(
                            "E_TREEWALK_JOIN_SYMS_UNKNOWN",
                            "`join.syms` names '$cs', which is not a range symbol of " *
                                "this aggregate ($(sort!(String[String(k) for k in keys(ranges)]))); " *
                                "both entries must name one of its `ranges` " *
                                "(CONFORMANCE_SPEC §5.5.8)"
                        )
                    )
                end
            end
            pick_l = csyms === nothing ? :left : csyms[1]
            pick_r = csyms === nothing ? :right : csyms[2]
            # Resolve EVERY pair of the clause first. Pairs over the same two
            # loop symbols are ONE composite key (§5.5.8), and
            # it is that composite match set — not the first pair's, which is a
            # superset — that drives. Pairs over different symbol pairs stay
            # separate gates, all of them ANDed by `_join_admits`.
            resolved = Tuple{String, String, Vector{Int}, Vector{Int}, Vector{Any}, Vector{Any}}[]
            for (lkey, rkey) in clause
                sym_l, pos_l, vals_l = _join_key_sym_pos_vals(
                    lkey, ranges, index_sets,
                    sym_to_set, vi_maps, const_arrays, var_shapes, obs_defs, pick_l, order
                )
                sym_r, pos_r, vals_r = _join_key_sym_pos_vals(
                    rkey, ranges, index_sets,
                    sym_to_set, vi_maps, const_arrays, var_shapes, obs_defs, pick_r, order
                )
                push!(resolved, (sym_l, sym_r, pos_l, pos_r, vals_l, vals_r))
            end
            indexed = Set{Tuple{String, String}}()
            coded = [_encode_join_keys(r[5], r[6]) for r in resolved]
            for (ri, r) in enumerate(resolved)
                codes_l, codes_r = coded[ri]
                # The FIRST gate of each symbol-pair group carries the composite
                # match index; the rest of the group stay pure code tests, so
                # admission is unchanged and only the enumeration extent moves.
                cands = nothing
                if !((r[1], r[2]) in indexed) && !_join_on_gate_disabled()
                    push!(indexed, (r[1], r[2]))
                    grp = [
                        gi for gi in eachindex(resolved)
                            if resolved[gi][1] == r[1] && resolved[gi][2] == r[2]
                    ]
                    prs = _on_gate_match_pairs(resolved[grp], coded[grp])
                    prs === nothing || (cands = _OverlapIndex(Set{Tuple{Int, Int}}(prs)))
                end
                push!(
                    gates, _JoinGate(
                        r[1], r[2],
                        Dict{Int, Int}(zip(r[3], codes_l)),
                        Dict{Int, Int}(zip(r[4], codes_r)), cands
                    )
                )
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
            # OVERLAP gate: the (pos_l, pos_r) pair must be in the
            # prebuilt broad-phase candidate set (envelope candidacy).
            (binding[g.sym_l], binding[g.sym_r]) in g.candidates || return false
        end
    end
    return true
end

# True if any node in the subtree carries a `join` clause, in any
# expression-bearing field — the gate that skips the resolution pre-pass for
# join-free documents. It walks the fields `_resolve_join_in_expr` rewrites, so
# the gate and the pass cannot disagree.
_expr_has_join(expr::ASTExpr) =
    _any_subexpr_once(e -> e isa OpExpr && (e::OpExpr).join !== nothing, expr)
_eq_has_join(eq::Equation) = _expr_has_join(eq.lhs) || _expr_has_join(eq.rhs)

# Rewrite each aggregate node's `join` clauses into build-time `join_gates`
# against the document index-set registry, preserving every other field. Runs
# BEFORE index-set range resolution so categorical `{from}` refs are still
# present for member lookup. The wire `join`/`filter` fields are carried through
# unchanged (serialization round-trips them); only the internal `join_gates` is
# populated.
function _resolve_join_in_expr(
        expr::OpExpr, index_sets::AbstractDict, vi_maps = _EMPTY_VI_MAPS,
        const_arrays::AbstractDict = Dict{String, Any}(),
        var_shapes::AbstractDict = Dict{String, Vector{String}}(),
        obs_defs::AbstractDict = Dict{String, ASTExpr}(),
        memo::IdDict{OpExpr, ASTExpr} = IdDict{OpExpr, ASTExpr}()
    )
    # Memoized by identity and identity-preserving, as `_resolve_isr` is: a
    # shared node resolves to one shared output node, and a subtree with no
    # `join` below it is returned as it is.
    cached = get(memo, expr, nothing)
    cached === nothing || return cached
    out = map_children(
        x -> _resolve_join_in_expr(x, index_sets, vi_maps, const_arrays, var_shapes, obs_defs, memo),
        expr
    )
    if _is_faq_op(expr.op) && expr.join !== nothing
        gates = _resolve_join_gates_for(expr, index_sets, vi_maps, const_arrays, var_shapes, obs_defs)
        out = reconstruct(out::OpExpr; join_gates = gates)
    end
    memo[expr] = out
    return out
end
_resolve_join_in_expr(
    expr::ASTExpr, ::AbstractDict, vi_maps = _EMPTY_VI_MAPS,
    const_arrays::AbstractDict = Dict{String, Any}(),
    var_shapes::AbstractDict = Dict{String, Vector{String}}(),
    obs_defs::AbstractDict = Dict{String, ASTExpr}(),
    memo::IdDict{OpExpr, ASTExpr} = IdDict{OpExpr, ASTExpr}()
) = expr

_resolve_join_in_eq(
    eq::Equation, index_sets::AbstractDict, vi_maps = _EMPTY_VI_MAPS,
    const_arrays::AbstractDict = Dict{String, Any}(),
    var_shapes::AbstractDict = Dict{String, Vector{String}}(),
    obs_defs::AbstractDict = Dict{String, ASTExpr}(),
    memo::IdDict{OpExpr, ASTExpr} = IdDict{OpExpr, ASTExpr}()
) =
    Equation(
    _resolve_join_in_expr(eq.lhs, index_sets, vi_maps, const_arrays, var_shapes, obs_defs, memo),
    _resolve_join_in_expr(eq.rhs, index_sets, vi_maps, const_arrays, var_shapes, obs_defs, memo);
    _comment = eq._comment
)

# Resolve join gates across a vector of equations. Returns the input unchanged
# when no equation uses a `join` clause (byte-identical for join-free files).
# `vi_maps` carries any value-invention map buffers a `join.on` gates on (RFC
# §5.3); `const_arrays` + `var_shapes` supply the envelope factor arrays and
# their 1-D shapes a Phase-2a `join.overlap` gate resolves against, and — since
# §5.5.8 — the DATA COLUMNS an `on` key may name and the shapes that map each to
# its range symbol. `obs_defs` carries the remaining observed definitions, from
# which a document-literal key column is materialised on demand.
function _resolve_join_gates(
        eqs::Vector{Equation}, index_sets::AbstractDict,
        vi_maps = _EMPTY_VI_MAPS,
        const_arrays::AbstractDict = Dict{String, Any}(),
        var_shapes::AbstractDict = Dict{String, Vector{String}}(),
        obs_defs::AbstractDict = Dict{String, ASTExpr}()
    )
    any(_eq_has_join, eqs) || return eqs
    memo = IdDict{OpExpr, ASTExpr}()
    return Equation[
        _resolve_join_in_eq(eq, index_sets, vi_maps, const_arrays, var_shapes, obs_defs, memo)
            for eq in eqs
    ]
end
