# ========================================================================
# intern.jl — structural interning (hash-consing) of the expression AST.
# Perf-plan item A1 (prototypes/perf-gap-closure-plan.md in reseact.esm).
#
# `_intern_expr` maps every `OpExpr` to ONE canonical object per structure, so
# the in-memory AST becomes a DAG: textually identical subtrees — which
# template inlining (esm-spec §9.7.3 has no `let` node) manufactures as fresh
# copies, re-inflating one species' RHS to ~57,000 index ops — become the SAME
# object. Every downstream build pass is already identity-memoized
# (`_sub_preserving`, `foreach_subexpr_once`, `_BuildMemo.resolve/compile`,
# `_build_acc_cse`, the `_stencilize` smemo, the ESS-0hh lowering memo); today
# those memos mostly miss because the copies are distinct objects. After
# interning they hit, and the build cost collapses to the unique-node count.
#
# WHERE it runs: once, at the `_build_evaluator_impl` entry (tree_walk/build.jl),
# right after `apply_expression_template` reference expansion — the latest
# point that covers the whole build hot path. NOT at parse: parse-time
# interning would also be sound today (the mutation audit in
# audits/intern_preaudit_2026-07-19.md found no post-construction mutation of
# any expression node anywhere in src/ or ext/), but the build entry keeps the
# blast radius minimal and covers exactly the passes whose memos need it.
#
# CORRECTNESS INVARIANTS (see the pre-audit for the site-by-site argument):
#   1. Structural equality/hash cover ALL semantic `OpExpr` fields — the
#      three walkers below are GENERATED from `OPEXPR_FIELD_TABLE` (types.jl),
#      the same single source of truth the parse/serialize/traversal walkers
#      derive from, so a newly added field is covered automatically (an
#      unknown-kind or unknown-typed field falls to the `===`-only fallback:
#      MISSED sharing, never a wrong merge).
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
# KILL SWITCH: `ESS_INTERN_DISABLE=1` restores the pre-interning build
# byte-for-byte (the intern pass is simply skipped). The differential oracle
# (test/intern_oracle_test.jl) builds gridded fixtures both ways and asserts
# bit-identical `du` and identical state maps.
# ========================================================================

_intern_disabled() = get(ENV, "ESS_INTERN_DISABLE", "") == "1"

# Per-build intern context. `table` is the hash-cons table (structural hash →
# bucket of canonical nodes, scanned with `_intern_shallow_equal`); `memo`
# short-circuits re-visits of already-processed nodes (any node object is
# interned at most once per build, so the pass is linear in distinct nodes).
struct _InternCtx
    table::Dict{UInt,Vector{OpExpr}}
    memo::IdDict{OpExpr,OpExpr}
end
_InternCtx() = _InternCtx(Dict{UInt,Vector{OpExpr}}(), IdDict{OpExpr,OpExpr}())

# ------------------------------------------------------------------------
# Fail-closed structural equality / hash for NON-child-slot payloads: the
# `:scalar` / `:join` / `:internal` / `:ranges` field kinds — plain JSON data
# (strings, ints, floats, bools, nested vectors), `ranges` dicts whose entries
# may be `IndexSetRef`s or bound vectors mixing Ints with (already interned)
# `ASTExpr`s, and any build-internal payload. Unrecognized types compare
# `===`-only with an `objectid` hash — consistent, and fail-safe (no merge).
# ------------------------------------------------------------------------
_plain_eq(a, b) = a === b                       # unknown type: identity only
_plain_eq(::Nothing, ::Nothing) = true
_plain_eq(a::String, b::String) = a == b
_plain_eq(a::Bool, b::Bool) = a === b
_plain_eq(a::Int64, b::Int64) = a === b
_plain_eq(a::Float64, b::Float64) = a === b     # bit-egal: -0.0 ≠ 0.0, NaN payloads distinct
_plain_eq(a::ASTExpr, b::ASTExpr) = a === b     # children are interned ⇒ === is structural
_plain_eq(a::IndexSetRef, b::IndexSetRef) = a.from == b.from && a.of == b.of
function _plain_eq(a::AbstractVector, b::AbstractVector)
    a === b && return true
    typeof(a) === typeof(b) || return false
    length(a) == length(b) || return false
    for i in eachindex(a)
        _plain_eq(a[i], b[i]) || return false
    end
    return true
end
function _plain_eq(a::AbstractDict, b::AbstractDict)
    a === b && return true
    typeof(a) === typeof(b) || return false
    length(a) == length(b) || return false
    for (k, v) in a
        haskey(b, k) || return false
        _plain_eq(v, b[k]) || return false
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
function _plain_hash(x::AbstractVector, h::UInt)
    h = hash(objectid(typeof(x)), hash(0x76, h))
    h = hash(length(x), h)
    for el in x
        h = _plain_hash(el, h)
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
# Child-slot interning helpers (identity-preserving: the ORIGINAL container is
# returned untouched when no element changed, so an already-canonical subtree
# costs no allocation on re-intern).
# ------------------------------------------------------------------------
function _intern_expr_vec(v::Vector{ASTExpr}, ctx::_InternCtx)
    out = v
    @inbounds for i in eachindex(v)
        a = v[i]
        r = a isa OpExpr ? _intern_expr(a, ctx) : a
        if r !== a
            out === v && (out = copy(v))
            out[i] = r
        end
    end
    return out
end
_intern_expr_map(::Nothing, ::_InternCtx) = nothing
function _intern_expr_map(m::Dict{String,ASTExpr}, ctx::_InternCtx)
    out = m
    for (k, x) in m
        r = x isa OpExpr ? _intern_expr(x, ctx) : x
        if r !== x
            out === m && (out = copy(m))
            out[k] = r
        end
    end
    return out
end
_intern_ranges(::Nothing, ::_InternCtx) = nothing
function _intern_ranges(m, ctx::_InternCtx)
    out = m
    for (k, v) in m
        v isa AbstractVector || continue        # IndexSetRef etc.: no sub-exprs
        nv = v
        for i in eachindex(v)
            b = v[i]
            b isa OpExpr || continue
            r = _intern_expr(b, ctx)
            if r !== b
                nv === v && (nv = copy(v))
                nv[i] = r
            end
        end
        if nv !== v
            out === m && (out = copy(m))
            out[k] = nv
        end
    end
    return out
end

# ------------------------------------------------------------------------
# The three GENERATED walkers. One statement per `OPEXPR_FIELD_TABLE` row, in
# struct-field order, dispatched on the row's `kind` — expression-bearing
# kinds (`:expr`, `:expr_vec`, `:expr_map`, `:ranges`) get child-slot
# handling (identity compare / objectid hash over interned children); every
# other kind (`:scalar`, `:join`, `:internal`) routes through the fail-closed
# `_plain_eq`/`_plain_hash` pair. A row added to the table with a new kind
# would fail the exhaustiveness assert at the bottom of this file.
# ------------------------------------------------------------------------

const _INTERN_EXPR_KINDS = (:expr, :expr_vec, :expr_map, :ranges)

# (1) Intern every expression-bearing field of `e` bottom-up; return `e`
# itself when nothing changed, else a `reconstruct` copy with the interned
# slots (all other fields copied verbatim by `reconstruct`'s contract).
@eval function _intern_children(e::OpExpr, ctx::_InternCtx)
    $((
        begin
            nf = Symbol(:new_, f)
            if spec.kind === :expr
                :($nf = (let x = e.$f
                    x isa OpExpr ? _intern_expr(x, ctx) : x
                end))
            elseif spec.kind === :expr_vec
                :($nf = (let v = e.$f
                    v === nothing ? nothing : _intern_expr_vec(v, ctx)
                end))
            elseif spec.kind === :expr_map
                :($nf = _intern_expr_map(e.$f, ctx))
            else # :ranges
                :($nf = _intern_ranges(e.$f, ctx))
            end
        end
        for (f, spec) in pairs(OPEXPR_FIELD_TABLE)
        if spec.kind in _INTERN_EXPR_KINDS
    )...)
    if $(foldl((acc, f) -> :($acc && $(Symbol(:new_, f)) === e.$f),
               [f for (f, spec) in pairs(OPEXPR_FIELD_TABLE)
                if spec.kind in _INTERN_EXPR_KINDS]; init=true))
        return e
    end
    return reconstruct(e; $((Expr(:kw, f, Symbol(:new_, f))
                             for (f, spec) in pairs(OPEXPR_FIELD_TABLE)
                             if spec.kind in _INTERN_EXPR_KINDS)...))
end

# (2) Shallow structural hash of a node whose expression-bearing slots are
# already interned: child slots contribute `objectid` (canonical pointer ≡
# structure; for immutable leaves `objectid` is content-consistent with the
# `===` the equality side uses), everything else `_plain_hash`. Each field
# folds its ordinal so field boundaries cannot alias.
@eval function _intern_node_hash(e::OpExpr)::UInt
    h = hash(e.op, UInt(0xA57))
    $((
        begin
            fi = UInt(i)
            if spec.kind === :expr
                :(h = (let x = e.$f
                    x === nothing ? hash($fi, h) : hash(objectid(x), hash($fi, h))
                end))
            elseif spec.kind === :expr_vec
                :(h = (let v = e.$f
                    if v === nothing
                        hash($fi, h)
                    else
                        local hh = hash(length(v), hash($fi, h))
                        for x in v
                            hh = hash(objectid(x), hh)
                        end
                        hh
                    end
                end))
            elseif spec.kind === :expr_map
                :(h = (let m = e.$f
                    if m === nothing
                        hash($fi, h)
                    else
                        local acc = UInt(0)
                        for (k, x) in m
                            acc ⊻= hash(objectid(x), hash(k, UInt(0x9e37)))
                        end
                        hash(acc, hash(length(m), hash($fi, h)))
                    end
                end))
            else # :scalar / :join / :internal / :ranges — plain payload
                :(h = _plain_hash(e.$f, hash($fi, h)))
            end
        end
        for (i, (f, spec)) in enumerate(pairs(OPEXPR_FIELD_TABLE))
        if f !== :op
    )...)
    return h
end

# (3) Shallow structural equality over ALL fields, for candidates in one hash
# bucket. Child slots by `===` (interned ⇒ structural); everything else
# `_plain_eq` (fail-closed).
@eval function _intern_shallow_equal(a::OpExpr, b::OpExpr)::Bool
    a.op == b.op || return false
    $((
        begin
            if spec.kind === :expr
                :(a.$f === b.$f || return false)
            elseif spec.kind === :expr_vec
                quote
                    let va = a.$f, vb = b.$f
                        if va !== vb
                            (va === nothing || vb === nothing) && return false
                            length(va) == length(vb) || return false
                            for i in eachindex(va)
                                va[i] === vb[i] || return false
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
                                v === w || return false
                            end
                        end
                    end
                end
            else # :scalar / :join / :internal / :ranges
                :(_plain_eq(a.$f, b.$f) || return false)
            end
        end
        for (f, spec) in pairs(OPEXPR_FIELD_TABLE)
        if f !== :op
    )...)
    return true
end

# Exhaustiveness pin: the walkers above dispatch on the field kinds known
# today; a new kind must be classified here before it can ship.
@assert all(spec.kind in (:expr, :expr_vec, :expr_map, :ranges, :scalar, :join, :internal)
            for (_, spec) in pairs(OPEXPR_FIELD_TABLE)) "intern.jl: unknown OPEXPR_FIELD_TABLE kind — extend the intern walkers"

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
# Model-level pass: intern every expression the tree-walk build's hot path
# walks — variable expressions (observeds), equations, initialization
# equations, expression-valued guesses — recursing into `Model` subsystems.
# Returns a NEW `Model` (sharing untouched sub-objects) so the CALLER's model
# is never mutated; event/test expressions are off the build's memoized hot
# path and are left as-is.
# ------------------------------------------------------------------------
function _intern_equations(eqs::Vector{Equation}, ctx::_InternCtx)
    isempty(eqs) && return eqs
    changed = false
    out = Vector{Equation}(undef, length(eqs))
    for (i, eq) in enumerate(eqs)
        l = _intern_expr(eq.lhs, ctx)
        r = _intern_expr(eq.rhs, ctx)
        if l !== eq.lhs || r !== eq.rhs
            out[i] = Equation(l, r; _comment=eq._comment)
            changed = true
        else
            out[i] = eq
        end
    end
    return changed ? out : eqs
end

function _intern_model(model::Model, ctx::_InternCtx)::Model
    vars = model.variables
    nvars = vars
    for (name, v) in vars
        v.expression === nothing && continue
        ne = _intern_expr(v.expression, ctx)
        if ne !== v.expression
            nvars === vars && (nvars = copy(vars))
            nvars[name] = reconstruct(v; expression=ne)
        end
    end
    eqs = _intern_equations(model.equations, ctx)
    ieqs = _intern_equations(model.initialization_equations, ctx)
    guesses = model.guesses
    ng = guesses
    for (k, g) in guesses
        g isa ASTExpr || continue
        r = _intern_expr(g, ctx)
        if r !== g
            ng === guesses && (ng = copy(guesses))
            ng[k] = r
        end
    end
    subs = model.subsystems
    nsubs = subs
    for (k, s) in subs
        s isa Model || continue
        ns = _intern_model(s, ctx)
        if ns !== s
            nsubs === subs && (nsubs = copy(subs))
            nsubs[k] = ns
        end
    end
    (nvars === vars && eqs === model.equations &&
     ieqs === model.initialization_equations && ng === guesses &&
     nsubs === subs) && return model
    return Model(nvars, eqs, model.discrete_events, model.continuous_events,
                 nsubs; tolerance=model.tolerance, tests=model.tests,
                 initialization_equations=ieqs, guesses=ng,
                 system_kind=model.system_kind)
end
