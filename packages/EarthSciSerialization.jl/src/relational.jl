"""
    EarthSciSerialization.Relational

Build-time relational engine — the five primitives the unified-IR value-invention
pass (RFC `semiring-faq-unified-ir` §5.5, §6.1) runs **once at setup**, off the
per-timestep hot path, to materialise the data-derived index sets and dense IDs
that the numeric stencil then consumes:

1. [`distinct`](@ref)        — deduplicate tuples (unique mesh edges from face→vertex lists)
2. [`equijoin`](@ref)        — value-equality equi-join (connectivity inversion, *edges of cell i*)
3. [`skolem`](@ref) / [`skolem_edge`](@ref) — deterministic content-addressed key from a tuple
4. [`rank`](@ref)            — dense integer renumbering of a distinct set
5. [`group_aggregate`](@ref) — group-by + associative/commutative semiring `⊕` (sum/min/max/…)

# Determinism (the reason this module exists)

`earthsci-toolkit` is **parallel native implementations** (Julia, Rust, Python)
verified by a conformance suite, not one core behind FFI. So the hard problem is
**bit-for-bit determinism across the bindings**: identical deduped sets, identical
dense IDs, identical skolem keys. The governing principle (`CONFORMANCE_SPEC.md`
§5.5 = RFC §5.7) is that *every emitted set, key, and dense ID is a pure function
of a defined total order over tuples* — **no observable output may depend on
`Dict`/`Set` iteration order or on a `Base.hash` value** (Julia's `Dict`/`Set`
order is an unspecified implementation detail and `Base.hash` is process-seeded
and not cross-version / cross-language stable).

Concretely, per `CONFORMANCE_SPEC.md` §5.5.1:

- **Total order** — lexicographic over tuple fields; integers by value; strings
  by Unicode code-point (UTF-8 byte) order. Julia's default `sort` and `isless`
  on `String`/`Tuple` already give exactly this, and `sort`/`sort!` are stable by
  default since Julia 1.9. **Floats are forbidden in keys** (rule 1) — rejected
  at the boundary by [`FloatKeyError`](@ref).
- **`distinct`** — sort by the total order, drop *adjacent* duplicates; output
  order *is* sorted order, never first-seen / `Set` order (rule 2).
- **`rank`** — dense IDs by position in the sorted distinct sequence. Julia emits
  **1-based** (rule 3); the conformance adapter normalises to canonical 0-based
  via `canonical = reported − base`.
- **`skolem`** — a canonical *tuple*, never a hash (rule 4): sort components for a
  symmetric relation (undirected edge `(min,max)`), preserve order for a directed
  one.
- **`join` / group-by** — hashing may bucket only; the result is emitted **sorted
  by the canonical key** (rule 5). The semiring `⊕` must be associative +
  commutative; for a floating-point `⊕` the per-bucket reduction is done
  sequentially in canonical value order to avoid last-ULP drift.

# Implementation notes

Built with Julia stdlib `sort`/`Dict` (+ the `OrderedCollections` dep) per RFC
Appendix A.4. DataFrames.jl (multi-second TTFX, "undefined" join/group order) and
DuckDB.jl (native binary) are deliberately rejected (A.3) — DuckDB stays only a
throwaway *oracle* during conformance-test authoring (`SELECT DISTINCT … ORDER
BY …`, `dense_rank() OVER (ORDER BY …)`).

This formalises and pins the order of the distinct/join/group-by patterns
`src/graph.jl` already hand-rolls informally (`Set{String}` dedup, composite-key
string joins, `Dict` node-maps) — patterns that worked but carried no ordering
guarantee. The Rust (`ess-my4.3.4`) and Python (`ess-my4.3.5`) bindings implement
the same §5.5 contract, so all three produce byte-identical index sets and
identical (base-normalised) dense-ID arrays.
"""
module Relational

import JSON3

export FloatKeyError,
    skolem, skolem_edge,
    distinct,
    rank, Ranking,
    equijoin,
    group_aggregate,
    canonical_index_set_json

# ── Rule 1: floats are forbidden in keys ────────────────────────────────────
# Native float equality/order is not a portable basis for an index set (and a
# raw `Float64` may carry `-0.0`/`NaN`). Reject at the boundary so misuse fails
# loudly at build time rather than silently emitting a non-deterministic /
# non-conformant set. `Bool <: Integer` is intentionally allowed (boolean-or
# keys); `Rational`/`Integer` are exact and orderable, also allowed.

"""
    FloatKeyError(msg)

Thrown when a relational key contains a floating-point component, violating
`CONFORMANCE_SPEC.md` §5.5.1 rule 1 ("floats are forbidden in keys"). Normalise
the value to an integer / categorical ID before the build-time pre-pass.
"""
struct FloatKeyError <: Exception
    msg::String
end
Base.showerror(io::IO, e::FloatKeyError) = print(io, "FloatKeyError: ", e.msg)

@inline _has_float(::AbstractFloat) = true
@inline _has_float(::Integer) = false        # Bool <: Integer ⇒ allowed
@inline _has_float(::AbstractString) = false
@inline _has_float(::Symbol) = false
@inline _has_float(::AbstractChar) = false
_has_float(t::Tuple) = any(_has_float, t)
_has_float(_) = false                         # other exact/categorical scalars

@inline function _assert_key(k)
    if _has_float(k)
        throw(FloatKeyError(
            "float in relational key $(repr(k)); keys must be integer / " *
            "categorical IDs (CONFORMANCE_SPEC.md §5.5.1 rule 1). Normalise to " *
            "an ID before the build-time relational pre-pass."))
    end
    return k
end

# ── Primitive 3: skolem (canonical-tuple content-addressed key) ─────────────

"""
    skolem_edge(a, b) -> Tuple

Canonical key for an **undirected** pair (a symmetric relation): `(min(a,b),
max(a,b))`. The deterministic, content-addressed identity of a mesh edge (RFC
§5.5 generalises ESI `pack`). It is **not** a hash (rule 4) — the tuple itself is
the key, so the dense ID later assigned by [`rank`](@ref) is reproducible across
bindings. `a` and `b` must be order-comparable and non-float.
"""
@inline function skolem_edge(a, b)
    _assert_key((a, b))
    return a <= b ? (a, b) : (b, a)
end

"""
    skolem(components::Tuple; symmetric::Bool=false) -> Tuple

Canonical-tuple Skolem key (rule 4). For a `symmetric` relation the components
are sorted (generalising [`skolem_edge`](@ref) to arity > 2); for a directed
relation the order is preserved, so `(1, 2)` and `(2, 1)` stay distinct. Never a
`Base.hash` — the tuple *is* the content-addressed key. The dense ID then comes
from [`rank`](@ref).
"""
function skolem(components::Tuple; symmetric::Bool=false)
    _assert_key(components)
    symmetric || return components
    return Tuple(sort!(collect(components)))
end

# ── Primitive 1: distinct (sort + drop adjacent duplicates) ─────────────────

"""
    distinct(rows) -> Vector

Set semantics over `rows`: sort by the §5.5.1 total order, then drop **adjacent**
duplicates (rule 2). The returned order **is** the sorted order — never
first-seen / `Set` iteration order. A pure function of the input multiset, so
duplicate, reversed, and permuted inputs all collapse to the identical output.

`rows` is any iterable of order-comparable keys: integer / categorical scalars,
or tuples thereof. Floats in keys raise [`FloatKeyError`](@ref) (rule 1).

Mirrors the DuckDB oracle `SELECT DISTINCT … ORDER BY …`.
"""
function distinct(rows)
    v = collect(rows)
    for r in v
        _assert_key(r)
    end
    sort!(v)                       # stable, total order (Julia ≥ 1.9)
    return _dedup_adjacent!(v)
end

# In-place adjacent dedup of an already-sorted vector. Equality (`!=`) — not the
# hash — decides duplicates, so it depends only on the values, not on Dict order.
function _dedup_adjacent!(sorted::Vector)
    isempty(sorted) && return sorted
    w = firstindex(sorted)
    @inbounds for i in (w + 1):lastindex(sorted)
        if sorted[i] != sorted[w]
            w += 1
            sorted[w] = sorted[i]
        end
    end
    resize!(sorted, w)
    return sorted
end

# ── Primitive 4: rank (dense integer renumbering) ───────────────────────────

"""
    Ranking{T}

Result of [`rank`](@ref):

- `order::Vector{T}` — the distinct tuples in §5.5.1 total order.
- `id::Dict{T,Int}`  — `id[t]` is the dense integer assigned to tuple `t`.
- `base::Int`        — the emission base. Julia emits **1-based** (`CONFORMANCE_SPEC.md`
  §5.5.1 rule 3); the conformance adapter recovers the canonical 0-based ID via
  `canonical = reported − base`.
"""
struct Ranking{T}
    order::Vector{T}
    id::Dict{T,Int}
    base::Int
end

"""
    rank(rows; base::Int=1) -> Ranking

Dense integer renumbering (rule 3): assign IDs by position in the sorted
[`distinct`](@ref) sequence. `base` is the emission base — Julia's native
**1-based** is the default; pass `base = 0` for the canonical 0-based numbering
the conformance suite asserts on. Equivalent to SQL `dense_rank() OVER (ORDER BY
…)` over the deduplicated rows.
"""
function rank(rows; base::Int=1)
    order = distinct(rows)
    T = eltype(order)
    id = Dict{T,Int}()
    @inbounds for (i, t) in enumerate(order)
        id[t] = (i - 1) + base
    end
    return Ranking{T}(order, id, base)
end

# ── Primitive 2: equijoin (value-equality equi-join) ────────────────────────

"""
    equijoin(left, right; on_left=identity, on_right=identity) -> Vector{Tuple}

Value-equality equi-join (rule 5): emit every `(l, r)` pair where `on_left(l) ==
on_right(r)`. Hashing is used **only** to bucket `right` by key; the result is
emitted **sorted by the canonical key** `(joinkey, l, r)`, so the output is
independent of `Dict` bucket iteration order *and* of input order.

This is the connectivity-inversion primitive — join an edge→cell table against a
cell table on the shared ID to recover the *edges of cell i*. Join keys must be
non-float (rule 1).
"""
function equijoin(left, right; on_left=identity, on_right=identity)
    # Dict{Any,...}/abstract containers are acceptable here: this module is
    # build-time-only (one-shot setup, off the per-timestep hot path), where
    # generality over key/row types beats container specialization.
    buckets = Dict{Any,Vector{Any}}()
    for r in right
        k = _assert_key(on_right(r))
        push!(get!(() -> Vector{Any}(), buckets, k), r)
    end
    out = Tuple[]
    for l in left
        k = _assert_key(on_left(l))
        bucket = get(buckets, k, nothing)
        bucket === nothing && continue
        for r in bucket
            push!(out, (l, r))
        end
    end
    # Canonical key first so the order is well defined even when `on_left` is a
    # projection rather than the identity.
    sort!(out; by = pair -> (on_left(pair[1]), pair[1], pair[2]))
    return out
end

# ── Primitive 5: group-by + semiring aggregate ──────────────────────────────

"""
    group_aggregate(rows; key, value, op) -> Vector{Pair}

Group-by + semiring aggregate (rule 5). Bucket `rows` by `key(row)` (hashing only
to bucket), combine the `value(row)`s within each group with the semiring `op`
(`⊕`), and emit `key => aggregate` pairs **sorted by the canonical key**.

`op` MUST be associative + commutative (every registry `⊕` — `+`, `*`, `min`,
`max`, `&`, `|`, count — is) so the result is independent of input / bucket order.
For a **floating-point** `op` the per-bucket reduction is done **sequentially in
canonical (sorted) value order** (rule 5) so the last-ULP result is reproducible;
the exact/integer path uses the same canonical order (immaterial there, but
keeps one code path). Group keys must be non-float (rule 1).

Mirrors the DuckDB oracle `SELECT key, ⊕(value) … GROUP BY key ORDER BY key`.
"""
function group_aggregate(rows; key, value, op)
    buckets = Dict{Any,Vector{Any}}()
    for row in rows
        k = _assert_key(key(row))
        push!(get!(() -> Vector{Any}(), buckets, k), value(row))
    end
    out = Pair[]
    for k in sort!(collect(keys(buckets)))
        vals = buckets[k]
        sort!(vals)                # canonical value order ⇒ reproducible float ⊕
        push!(out, k => foldl(op, vals))
    end
    return out
end

# ── Canonical serialization (CONFORMANCE_SPEC.md §5.5.3) ─────────────────────

"""
    canonical_index_set_json(rows) -> String

Canonical byte form of an index set (`CONFORMANCE_SPEC.md` §5.5.3): the
[`distinct`](@ref) rows, each tuple serialised as a JSON array, in §5.5.1 sorted
order, as **compact JSON** (`,` / `:` separators, no spaces, UTF-8). Two
conforming bindings MUST produce byte-for-byte identical output for the same
input multiset. Scalars serialise as bare JSON scalars; tuples as arrays.

This is the artifact the adversarial conformance harness (§5.5.4) compares
byte-for-byte across duplicate / reversed / permuted inputs.
"""
canonical_index_set_json(rows) = "[" * join((_emit_token(x) for x in distinct(rows)), ",") * "]"

_emit_token(t::Tuple) = "[" * join((_emit_token(x) for x in t), ",") * "]"
_emit_token(x::Bool) = x ? "true" : "false"
_emit_token(x::Integer) = string(x)                 # bare digits
_emit_token(x::AbstractString) = JSON3.write(String(x))   # JSON-escaped, matches canonicalize.jl
_emit_token(x::Symbol) = JSON3.write(String(x))

end # module Relational
