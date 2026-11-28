# ========================================================================
# intern.jl — structural interning (hash-consing) of the expression AST.
#
# `_intern_expr` maps every `OpExpr` to ONE canonical object per structure, so
# the in-memory AST becomes a DAG: textually identical subtrees — which
# template inlining (esm-spec §9.7.3 has no `let` node) manufactures as fresh
# copies — become the SAME object. Every downstream build pass is
# identity-memoized (`_sub_preserving`, `foreach_subexpr_once`,
# `_BuildMemo.resolve/compile`, `_build_acc_cse`, the `_stencilize` memo, the
# lowering memo), so with interning the build cost is the unique-node count.
#
# It runs once, at the `_build_evaluator_impl` entry
# (tree_walk/build_pipeline.jl), right after `apply_expression_template`
# reference expansion.
#
# CORRECTNESS INVARIANTS:
#   1. Structural equality/hash cover ALL semantic `OpExpr` fields — the
#      three walkers below are GENERATED from `OPEXPR_FIELD_TABLE` (types.jl),
#      the same single source of truth the parse/serialize/traversal walkers
#      derive from, so a newly added field is covered automatically (an
#      unknown-kind or unknown-typed field falls to the `===`-only fallback:
#      MISSED sharing, never a wrong merge). "Semantic" here means *emitted*,
#      not merely *evaluated*: `expect_cadence` and `attrs` change no
#      evaluation result but DO round-trip to the wire, so two nodes differing
#      only in one of them must not collapse. Their `:scalar` rows put them on
#      the `_plain_eq`/`_plain_hash` path; Rust's `node_eq`/`node_hash` agree.
#   2. Children are interned bottom-up, so `===` on an already-interned child
#      IS structural equality — shallow comparisons/hashes over child slots
#      use pointer identity (`===` / `objectid`), making one intern pass
#      O(nodes), not O(nodes²). Leaves (`NumExpr`/`IntExpr`/`VarExpr`) are
#      immutable structs whose egal is already content-based, so they need no
#      interning and compare correctly under `===`.
#   3. Scalar payloads compare FAIL-CLOSED: numbers by bit-egal (`-0.0` never
#      merges with `0.0`, `1` never merges with `1.0`), strings by content,
#      known containers element-wise with a `typeof` guard, anything
#      unrecognized by `===` only. Every equality arm has a hash arm that is
#      consistent with it (equal ⇒ equal hash; collisions are resolved by the
#      bucket scan, never by trusting the hash).
#   4. No `Base.hash`/`Base.:(==)` methods are added for `OpExpr` — the
#      codebase deliberately relies on pointer `==`/`IdDict` semantics
#      (types.jl field-table note); the intern table is a private
#      hash-bucket structure instead.
#
# Under `compiler=:interpreter` the pass is simply skipped, which is the
# reference build; the differential oracle (test/intern_oracle_test.jl) builds
# gridded fixtures under both compilers and asserts bit-identical `du` and
# identical state maps.
# ========================================================================

_intern_disabled() = !_compiler_plan_now().intern

# Per-build intern context. `table` is the hash-cons table (structural hash →
# bucket of canonical nodes, scanned with `_intern_shallow_equal`); `memo`
# short-circuits re-visits of already-processed nodes (any node object is
# interned at most once per build, so the pass is linear in distinct nodes).
struct _InternCtx
    table::Dict{UInt, Vector{OpExpr}}
    memo::IdDict{OpExpr, OpExpr}
end
_InternCtx() = _InternCtx(Dict{UInt, Vector{OpExpr}}(), IdDict{OpExpr, OpExpr}())

# ------------------------------------------------------------------------
# Fail-closed structural equality / hash for NON-child-slot payloads: the
# `:scalar` / `:join` / `:internal` / `:ranges` field kinds — plain JSON data
# (strings, ints, floats, bools, nested vectors), `ranges` dicts whose entries
# may be `IndexSetRef`s or bound vectors mixing Ints with `ASTExpr`s, and any
# build-internal payload. Unrecognized types compare `===`-only with an
# `objectid` hash — consistent, and fail-safe (no merge). An `ASTExpr` inside a
# payload is compared by `ceq`: `===` for interning (children are already
# interned, so identity is structure), `_expr_equal` for a deep comparison.
# ------------------------------------------------------------------------
_plain_eq(a, b, ceq::F = (===)) where {F} = a === b   # unknown type: identity only
_plain_eq(::Nothing, ::Nothing, ceq::F = (===)) where {F} = true
_plain_eq(a::String, b::String, ceq::F = (===)) where {F} = a == b
_plain_eq(a::Bool, b::Bool, ceq::F = (===)) where {F} = a === b
_plain_eq(a::Int64, b::Int64, ceq::F = (===)) where {F} = a === b
# bit-egal: -0.0 ≠ 0.0, NaN payloads distinct
_plain_eq(a::Float64, b::Float64, ceq::F = (===)) where {F} = a === b
_plain_eq(a::ASTExpr, b::ASTExpr, ceq::F = (===)) where {F} = ceq(a, b)::Bool
_plain_eq(a::IndexSetRef, b::IndexSetRef, ceq::F = (===)) where {F} =
    a.from == b.from && a.of == b.of
# Iterating an on clause exposes only its key pairs. Its selected range
# symbols also distinguish two otherwise identical self-join expressions.
_plain_eq(a::_OnJoinSpec, b::_OnJoinSpec, ceq::F = (===)) where {F} =
    a.syms == b.syms && _plain_eq(a.pairs, b.pairs, ceq)
function _plain_eq(a::AbstractVector, b::AbstractVector, ceq::F = (===)) where {F}
    a === b && return true
    typeof(a) === typeof(b) || return false
    length(a) == length(b) || return false
    for i in eachindex(a)
        _plain_eq(a[i], b[i], ceq) || return false
    end
    return true
end
function _plain_eq(a::AbstractDict, b::AbstractDict, ceq::F = (===)) where {F}
    a === b && return true
    typeof(a) === typeof(b) || return false
    length(a) == length(b) || return false
    for (k, v) in a
        haskey(b, k) || return false
        _plain_eq(v, b[k], ceq) || return false
    end
    return true
end

# Hash side of the pair above. Every arm folds a type tag so values that the
# equality side distinguishes by type (Int64 1 vs Float64 1.0 — different on
# the wire, `Base.hash`-equal) hash apart too.
_plain_hash(::Nothing, h::UInt) = hash(0x6e, h)
_plain_hash(x::String, h::UInt) = hash(x, hash(0x73, h))
_plain_hash(x::Bool, h::UInt) = hash(x, hash(0x62, h))
_plain_hash(x::Int64, h::UInt) = hash(x, hash(0x69, h))
_plain_hash(x::Float64, h::UInt) = hash(reinterpret(UInt64, x), hash(0x66, h))
_plain_hash(x::ASTExpr, h::UInt) = hash(objectid(x), hash(0x65, h))
_plain_hash(x::IndexSetRef, h::UInt) = hash(x.of, hash(x.from, hash(0x72, h)))
_plain_hash(x::_OnJoinSpec, h::UInt) = hash(x.syms, _plain_hash(x.pairs, hash(0x6a, h)))
function _plain_hash(x::AbstractVector, h::UInt)
    h = hash(objectid(typeof(x)), hash(0x76, h))
    h = hash(length(x), h)
    for el in x
        # Inline number arrays: the common leaves hash without a dynamic call.
        h = el isa Int64 ? _plain_hash(el, h) :
            el isa Float64 ? _plain_hash(el, h) :
            el isa Vector{Any} ? _plain_hash(el, h)::UInt : _plain_hash(el, h)::UInt
    end
    return h
end
function _plain_hash(x::AbstractDict, h::UInt)
    h = hash(objectid(typeof(x)), hash(0x64, h))
    h = hash(length(x), h)
    # Order-insensitive fold (Dict iteration order is unspecified).
    acc = UInt(0)
    for (k, v) in x
        acc ⊻= _plain_hash(v, _plain_hash(k, UInt(0x9e37)))
    end
    return hash(acc, h)
end
_plain_hash(x, h::UInt) = hash(objectid(x), hash(0x75, h))   # unknown: identity

# ------------------------------------------------------------------------
# The walkers. `_intern_children` interns every expression-bearing field
# bottom-up through `map_children` (the node itself when nothing changed). The
# hash and the equality below are GENERATED from `OPEXPR_FIELD_TABLE`, one
# statement per row in struct-field order, dispatched on the row's `kind`:
# expression-bearing kinds (`:expr`, `:expr_vec`, `:expr_map`) compare and hash
# children by identity (they are interned); every other kind (`:scalar`,
# `:join`, `:internal`, `:ranges`) goes through the fail-closed
# `_plain_eq`/`_plain_hash` pair. A row added to the table with a new kind
# fails the exhaustiveness assert at the bottom of this file.
# ------------------------------------------------------------------------

_intern_children(e::OpExpr, ctx::_InternCtx) = map_children(x -> _intern_expr(x, ctx), e)::OpExpr

# (2) Shallow structural hash of a node whose expression-bearing slots are
# already interned: child slots contribute `objectid` (canonical pointer ≡
# structure; for immutable leaves `objectid` is content-consistent with the
# `===` the equality side uses), everything else `_plain_hash`. Each field
# folds its ordinal so field boundaries cannot alias.
@eval function _intern_node_hash(e::OpExpr)::UInt
    h = hash(e.op, UInt(0x0A57))
    $(
        (
            begin
                fi = UInt(i)
                if spec.kind === :expr
                    :(
                        h = (
                            let x = e.$f
                                x === nothing ? hash($fi, h) : hash(objectid(x), hash($fi, h))
                            end
                        )
                    )
                elseif spec.kind === :expr_vec
                    :(
                        h = (
                            let v = e.$f
                                if v === nothing
                                    hash($fi, h)
                                else
                                    local hh = hash(length(v), hash($fi, h))
                                    for x in v
                                        hh = hash(objectid(x), hh)
                                    end
                                    hh
                                end
                            end
                        )
                    )
                elseif spec.kind === :expr_map
                    :(
                        h = (
                            let m = e.$f
                                if m === nothing
                                    hash($fi, h)
                                else
                                    local acc = UInt(0)
                                    for (k, x) in m
                                        acc ⊻= hash(objectid(x), hash(k, UInt(0x9e37)))
                                    end
                                    hash(acc, hash(length(m), hash($fi, h)))
                                end
                            end
                        )
                    )
                else # :scalar / :join / :internal / :ranges — plain payload
                    :(h = _plain_hash(e.$f, hash($fi, h)))
                end
            end
                for (i, (f, spec)) in enumerate(pairs(OPEXPR_FIELD_TABLE))
                if f !== :op
        )...
    )
    return h
end

# (3) Structural equality of two nodes field by field, children compared by
# `ceq`. With `ceq = ===` it is the shallow comparison of candidates in one hash
# bucket (interned children: identity is structure); with `_expr_equal` it is
# the deep comparison. `internal` decides whether `:internal` (build-time,
# never emitted) fields take part: they do for interning, which must never merge
# two nodes the build tells apart, and they do not for document equality.
@eval function _opexpr_equal(a::OpExpr, b::OpExpr, ceq::F, internal::Bool)::Bool where {F}
    a.op == b.op || return false
    $(
        (
            begin
                if spec.kind === :expr
                    quote
                        let xa = a.$f, xb = b.$f
                            xa === xb || (
                                xa !== nothing && xb !== nothing && ceq(xa, xb)::Bool
                            ) || return false
                        end
                    end
                elseif spec.kind === :expr_vec
                    quote
                        let va = a.$f, vb = b.$f
                            if va !== vb
                                (va === nothing || vb === nothing) && return false
                                length(va) == length(vb) || return false
                                for i in eachindex(va)
                                    ceq(va[i], vb[i])::Bool || return false
                                end
                            end
                        end
                    end
                elseif spec.kind === :expr_map
                    quote
                        let ma = a.$f, mb = b.$f
                            if ma !== mb
                                (ma === nothing || mb === nothing) && return false
                                length(ma) == length(mb) || return false
                                for (k, v) in ma
                                    w = get(mb, k, nothing)
                                    w === nothing && return false
                                    ceq(v, w)::Bool || return false
                                end
                            end
                        end
                    end
                elseif spec.kind === :internal
                    :(!internal || _plain_eq(a.$f, b.$f, ceq) || return false)
                else # :scalar / :join / :ranges
                    :(_plain_eq(a.$f, b.$f, ceq) || return false)
                end
            end
                for (f, spec) in pairs(OPEXPR_FIELD_TABLE)
                if f !== :op
        )...
    )
    return true
end

_intern_shallow_equal(a::OpExpr, b::OpExpr) = _opexpr_equal(a, b, ===, true)

"""
    _expr_equal(a::ASTExpr, b::ASTExpr) -> Bool

Whether two expressions are the same document expression: the same node kinds
with every emitted field equal, at every depth. Literals compare by value and
type (`1` is not `1.0`, `0.0` is not `-0.0`); build-time fields are ignored.
Identical objects are equal without a walk. Not `Base.==`: `OpExpr` keeps
identity `==` so `IdDict` memos stay constant-time.
"""
_expr_equal(a::ASTExpr, b::ASTExpr) = a === b
_expr_equal(a::OpExpr, b::OpExpr) = a === b || _opexpr_equal(a, b, _expr_equal, false)

# Exhaustiveness pin: the walkers above dispatch on the field kinds known
# today; a new kind must be classified here before it can ship.
@assert all(
    spec.kind in (:expr, :expr_vec, :expr_map, :ranges, :scalar, :join, :internal)
        for (_, spec) in pairs(OPEXPR_FIELD_TABLE)
) "intern.jl: unknown OPEXPR_FIELD_TABLE kind — extend the intern walkers"

# ------------------------------------------------------------------------
# The intern pass proper.
# ------------------------------------------------------------------------
_intern_expr(e::NumExpr, ::_InternCtx) = e
_intern_expr(e::IntExpr, ::_InternCtx) = e
_intern_expr(e::VarExpr, ::_InternCtx) = e
function _intern_expr(e::OpExpr, ctx::_InternCtx)::OpExpr
    c = get(ctx.memo, e, nothing)
    c === nothing || return c
    r = _intern_children(e, ctx)
    h = _intern_node_hash(r)
    bucket = get!(() -> OpExpr[], ctx.table, h)
    canon = nothing
    for cand in bucket
        if cand === r || _intern_shallow_equal(cand, r)
            canon = cand
            break
        end
    end
    if canon === nothing
        push!(bucket, r)
        canon = r
    end
    ctx.memo[e] = canon
    r !== e && (ctx.memo[r] = canon)
    return canon
end
_intern_expr(e::ASTExpr, ctx::_InternCtx) = e    # future leaf kinds: pass through

# ------------------------------------------------------------------------
# Model-level pass: intern every expression site of the model and its
# subsystems (`map_expressions`). Returns a model whose containers are new, so
# the caller's model is never mutated; untouched records are shared.
# ------------------------------------------------------------------------
_intern_model(model::Model, ctx::_InternCtx)::Model =
    map_expressions(e -> _intern_expr(e, ctx), model)
