"""
Type definitions for EarthSciML Serialization Format.

This module defines the complete type hierarchy for the ESM format,
matching the JSON schema definitions for language-agnostic model interchange.
"""

# Apply `f` to `x`, propagating `nothing` (the standard absent-optional-field
# guard: `_maybe(string, get(data, key, nothing))`).
_maybe(f, x) = x === nothing ? nothing : f(x)

"""
    ESM_FORMAT_VERSION

The ESM format version (semver string) this implementation targets — the value
written into the `esm` field of freshly constructed files. Files loaded from
disk keep whatever version they declare; this constant is only the default for
documents the library itself creates (flatten wrappers, MTK/Catalyst export).
Must track the version on the first line of `esm-spec.md`.
"""
const ESM_FORMAT_VERSION = "0.8.0"

# ========================================
# 1. Expression Type Hierarchy
# ========================================

"""
    abstract type ASTExpr end

Abstract base type for all mathematical expressions in the ESM format.
Expressions can be numeric literals, variable references, or operator nodes.
"""
# NAMING: this abstract type is spelled `ASTExpr` (not `Expr`) specifically so
# it does NOT shadow `Core.Expr` (Julia's own AST node type) inside this module
# or for consumers that `using EarthSciAST`. Module-internal code that builds
# Julia AST still writes `Core.Expr` explicitly (see codegen.jl and the package
# extensions), and struct fields that would naturally be called `expr` use
# `expr_body`-style names (e.g. `OpExpr.expr_body` for the wire key "expr") to
# keep the ESM and Julia AST vocabularies distinct.
abstract type ASTExpr end

"""
    NumExpr(value::Float64)

Floating-point numeric literal expression. Represents a JSON number whose
mathematical value is **non-integral** (or integral but not `Int64`-
representable): literal type is decided by *value*, not by the token's source
spelling (CONFORMANCE_SPEC §5.5.3.1 rules 1/3). A JSON number whose value is
integral and `Int64`-representable — however it was spelled (`1`, `1.0`,
`2.5e1`) — parses as an `IntExpr`, so `parse_expression` never produces
`NumExpr(1.0)`; such a node can only be built directly in Julia code.
"""
struct NumExpr <: ASTExpr
    value::Float64
end

"""
    IntExpr(value::Int64)

Integer numeric literal expression. Represents a JSON number whose
mathematical value is integral and `Int64`-representable, **regardless of how
the source document spelled the token** (`0.0` → `IntExpr(0)`, `2.5e1` →
`IntExpr(25)`; CONFORMANCE_SPEC §5.5.3.1 rules 1/3). The AST distinguishes
integer and float nodes: `IntExpr(1)` and `NumExpr(1.0)` are different values,
and canonicalization never auto-promotes one to the other (RFC §5.4.1); on the
wire an `IntExpr` serializes as an integer literal (no `.`/`e`).
"""
struct IntExpr <: ASTExpr
    value::Int64
end

"""
    VarExpr(name::String)

Variable or parameter reference expression containing a name string.
"""
struct VarExpr <: ASTExpr
    name::String
end

# One resolved key-column pair of an aggregate `join` (RFC §5.3): the two range
# symbols and, for each, a map from a range position (the loop-variable value)
# to its bucket code. A combination is admitted iff
# `codes_l[pos_l] == codes_r[pos_r]` for every gate. Defined HERE — ahead of
# `OpExpr` — so the internal `OpExpr.join_gates` field can name this concrete
# element type; it is BUILT and CONSUMED in tree_walk/semiring.jl
# (`_resolve_join_gates_for` / `_join_admits`), never parsed or serialized.
struct _JoinGate
    sym_l::String
    sym_r::String
    codes_l::Dict{Int,Int}
    codes_r::Dict{Int,Int}
end

"""
    OpExpr(op::String, args::Vector{ASTExpr}; wrt, dim, int_var, lower, upper, output_idx, expr_body, reduce, ranges, regions, values, shape, perm, axis, fn)

Operator expression node containing:
- `op`: operator name (e.g., "+", "*", "log", "D", "arrayop")
- `args`: vector of argument expressions
- `wrt`: variable name for differentiation (optional; for `D`)
- `dim`: dimension for spatial operators (optional; for `grad`, `div`)
- `int_var`: integration variable name (optional; for `integral`, matches JSON field "var")
- `lower`: lower integration bound expression (optional; for `integral`)
- `upper`: upper integration bound expression (optional; for `integral`)
- `output_idx`: for `arrayop`, list of result index symbols (String) or literal
  singleton dimensions (Int 1). Mirrors SymbolicUtils.ArrayOp.output_idx.
- `expr_body`: for `arrayop`, the scalar body evaluated at each index point
  (a nested `ASTExpr` tree). Named `expr_body` — not `expr` — to avoid shadowing
  the `EarthSciAST.ASTExpr` abstract type.
- `reduce`: for `arrayop`/`aggregate`, the reduction operator applied to
  contracted indices (one of "+", "*", "max", "min"; default "+"). Names the
  semiring ⊕ only; it is the shorthand retained for files that omit `semiring`
  (RFC semiring-faq-unified-ir §5.1).
- `semiring`: for `arrayop`/`aggregate`, the named semiring `(⊕, ⊗)` with
  normative identity elements that parameterizes the reduction (closed registry:
  "sum_product", "max_product", "min_sum", "max_sum", "bool_and_or"). Absent ⇒
  "sum_product", reproducing today's einsum semantics. When present it supersedes
  `reduce`; the ⊕/⊗ operators and BOTH identities come from the registry table,
  never the file (RFC §5.1).
- `ranges`: for `arrayop`, map from index symbol name to iteration range
  (vector of 2 or 3 ints `[start, stop]` / `[start, step, stop]`).
- `regions`: for `makearray`, list of sub-region boxes, each a list of
  `[start, stop]` pairs per output dimension.
- `values`: for `makearray`, one sub-expression per entry in `regions`.
- `shape`: for `reshape`, target shape; entries are `Int` (concrete length)
  or `String` (symbolic dimension).
- `perm`: for `transpose`, optional 0-based axis permutation.
- `axis`: for `concat`, 0-based axis to concatenate along.
- `fn`: for `broadcast`, the scalar operator to apply element-wise.
- `name`: for the `fn` op, the dotted module path of a function in the closed
  function registry (esm-spec §9.2). The set of valid `name` values is fixed by
  the spec version; bindings MUST reject unknown names with diagnostic
  `unknown_closed_function`.
- `value`: for the `const` op, the inline literal value carried by this node.
  Any JSON value (number, integer, or nested array thereof); `args` MUST be
  empty for a const node.
- `label`: optional documentary relation tag for a `skolem` node (e.g. "edge",
  "bin", "pair") — the human-facing name of the relation the emitted key belongs
  to. Purely documentary: it is NOT part of the emitted key and is NOT rendered;
  `args` are the pure key components.
"""
# `mutable struct` (not `struct`) is a deliberate PERFORMANCE choice, not a
# licence to mutate: the build path treats `OpExpr` as an immutable value and only
# ever copies-with-changes through `reconstruct` (fields are never assigned after
# construction). Mutability buys true POINTER-IDENTITY for the build-time
# memoization `IdDict{OpExpr,…}` caches (`_BuildMemo` in tree_walk/compile.jl and
# the `_stencil_var_set` cache in tree_walk/stencil.jl). With an *immutable*
# `OpExpr`, `IdDict` falls back to `objectid`/`===`, which for an immutable struct
# are STRUCTURAL — every memo probe re-hashes the `op` String and walks all ~35
# fields (measured ~17× slower per probe than pointer identity), and those probes
# dominate the `build_evaluator` profile. A mutable struct makes `objectid`/`===`
# (hence `IdDict` and the `r !== args[i]` "did this subtree change" identity checks
# throughout the tree walk) pointer-based, so the memos become the O(1) identity
# caches they were always meant to be. No custom `==`/`hash` is defined: `OpExpr`
# is never a *value*-keyed `Dict`/`Set` key anywhere (only ever an `IdDict` key),
# and default `==` was already non-structural for trees — two distinct-but-equal
# `OpExpr`s compared `false` because their `args` `Vector`s differ by identity — so
# pointer `==` matches the pre-existing de-facto behaviour.
mutable struct OpExpr <: ASTExpr
    op::String
    args::Vector{ASTExpr}
    wrt::Union{String,Nothing}
    dim::Union{String,Nothing}
    int_var::Union{String,Nothing}
    lower::Union{ASTExpr,Nothing}
    upper::Union{ASTExpr,Nothing}
    output_idx::Union{Vector{Any},Nothing}
    expr_body::Union{ASTExpr,Nothing}
    reduce::Union{String,Nothing}
    semiring::Union{String,Nothing}
    ranges::Union{Dict{String,Any},Nothing}
    regions::Union{Vector{Vector{Vector{Int}}},Nothing}
    values::Union{Vector{ASTExpr},Nothing}
    shape::Union{Vector{Any},Nothing}
    perm::Union{Vector{Int},Nothing}
    axis::Union{Int,Nothing}
    fn::Union{String,Nothing}
    name::Union{String,Nothing}
    value::Any
    # table_lookup (esm-spec §9.5, v0.4.0): the function_tables entry id this
    # node references. ``args`` MUST be empty for a table_lookup node — the
    # per-axis input expressions live in ``table_axes``.
    table::Union{String,Nothing}
    # Per-axis input-coordinate expression map for a table_lookup node.
    # Stored under the JSON key ``axes`` on the wire.
    table_axes::Union{Dict{String,ASTExpr},Nothing}
    # Output selector for a multi-output table_lookup. Either a non-negative
    # integer (0-based index) or a string (entry of the table's outputs).
    output::Any

    # ── M2: value-equality joins + filter predicates on aggregate/arrayop ──
    # (RFC semiring-faq-unified-ir §5.3 / §7.2; schema bead ess-my4.2.1).
    #
    # `join`   — the parsed join clauses, an inner equi-join of factors by key
    #            columns. Each clause is a `Vector{Tuple{String,String}}` of
    #            `[left, right]` key-column pairs that must all compare equal for
    #            a ⊗-product term to contribute. This is the wire form (parsed /
    #            serialized); the build path resolves it into `join_gates`.
    # `filter` — an optional boolean predicate Expression restricting which index
    #            combinations contribute a term (§7.2). A combination for which it
    #            is false contributes the additive identity 0̄ — compiled into a
    #            runtime `ifelse(pred, term, 0̄)` guard (it may reference factors
    #            whose values are only known at run time, so it is NOT folded).
    # `join_gates` — INTERNAL: the build-time-resolved join, a
    #            `Vector{_JoinGate}` mapping each key symbol's range position to a
    #            bucket code (equal codes ⇔ equal key values). Populated by
    #            `_resolve_join_gates` against the document index-set registry;
    #            never parsed or serialized (the wire form is `join`).
    join::Union{Vector{Any},Nothing}
    filter::Union{ASTExpr,Nothing}
    join_gates::Union{Vector{_JoinGate},Nothing}

    # ── M4 geometry kernel (RFC semiring-faq-unified-ir §8.1 / Appendix B;
    #    schema bead ess-my4.4.2; Julia kernel ess-my4.4.3) ──
    #
    # `id`       — node-local identifier (RFC §6.1) by which a `kind:"derived"`
    #              index set names its producer via `from_faq`. Carried on an
    #              `intersect_polygon` leaf so its data-dependent clip ring is
    #              exposed as the derived index set a `polygon_area` FAQ ranges
    #              over (§8.1). Emitted only when present (byte-identical round-trip
    #              for non-geometry nodes).
    # `manifold` — geometry interpretation for the `intersect_polygon` leaf:
    #              "planar" | "spherical" | "geodesic" (CONFORMANCE_SPEC.md §5.8.4).
    #              REQUIRED on every `intersect_polygon` node, no default; matched
    #              EXACTLY across bindings. Meaningful only for `intersect_polygon`.
    id::Union{String,Nothing}
    manifold::Union{String,Nothing}

    # ── Value-invention aggregate vocabulary (RFC §5.5 / §6.1) ──
    # `distinct` — an index-set-PRODUCING aggregate (a `distinct:true` relational
    #              set former); its emitted `key`s are deduplicated in §5.5.1 sorted
    #              order to materialise a derived index set (matched by `from_faq`).
    # `key`       — the skolem/tuple KEY expression the producer emits per surviving
    #              index combination (`{op:skolem, args:[…]}`). Both live ONLY in the
    #              raw value-invention front-door (they are read off the raw JSON),
    #              but MUST survive the typed-IR round-trip so a flattened multi-model
    #              document's producer is still recognised (else the derived set is
    #              never sized and the producer's ODE equation is not dropped).
    distinct::Union{Bool,Nothing}
    key::Union{ASTExpr,Nothing}

    # ── Arg-witness / expression-template display fields ──
    # `arg`      — for `argmin`/`argmax`, the witnessing index symbol name whose
    #              value at the optimum is returned (RENDERING_CONTRACT.md §argmin/
    #              argmax: `{op, arg, expr, ranges?}`). Carried on the typed node so
    #              the pretty-printer can render `argmin[arg] (expr)`.
    # `bindings` — for `apply_expression_template`, the parameter→argument-expression
    #              map (esm-spec §9.6). Templates are normally lowered before typed
    #              parsing, but the node is renderable directly so the pretty-printer
    #              can emit `name⟨p=e, …⟩` byte-identically to the other bindings.
    arg::Union{String,Nothing}
    bindings::Union{Dict{String,ASTExpr},Nothing}

    # ── Skolem documentary relation tag ──
    # `label` — an OPTIONAL documentary relation tag on a `skolem` node (e.g.
    #           "edge"/"bin"/"pair"): the human-facing name of the relation the
    #           emitted key belongs to. Formerly this tag was overloaded onto the
    #           FIRST `args` position, where a typo silently masqueraded as a real
    #           key component; it now lives in its own field so `args` are PURE key
    #           components. Purely documentary — NOT part of the emitted key
    #           (`_vi_skolem` reads it for provenance only) and NOT rendered by the
    #           pretty-printer (a skolem renders as `skolem(<args>)`).
    label::Union{String,Nothing}

    OpExpr(op::String, args::Vector{ASTExpr};
           wrt=nothing, dim=nothing,
           int_var=nothing, lower=nothing, upper=nothing,
           output_idx=nothing, expr_body=nothing, reduce=nothing,
           semiring=nothing,
           ranges=nothing, regions=nothing, values=nothing,
           shape=nothing, perm=nothing, axis=nothing, fn=nothing,
           name=nothing, value=nothing,
           table=nothing, table_axes=nothing, output=nothing,
           join=nothing, filter=nothing, join_gates=nothing,
           id=nothing, manifold=nothing,
           distinct=nothing, key=nothing,
           arg=nothing, bindings=nothing, label=nothing,
           # `handler_id` was the v0.2.x field for the now-removed `call`
           # op (esm-spec §9.2 closure). Accept and ignore on construction
           # so internal helpers that still pass it through don't break
           # mid-migration; the field is no longer stored or serialized.
           handler_id=nothing) =
        new(op, args, wrt, dim, int_var, lower, upper, output_idx, expr_body, reduce,
            semiring, ranges,
            regions, values, shape, perm, axis, fn, name, value,
            table, table_axes, output, join, filter, join_gates,
            id, manifold, distinct, key, arg, bindings, label)

    # Fully-positional inner constructor — the ALLOCATION-FREE reconstruction
    # path. The keyword constructor above builds a ~30-entry `NamedTuple` for its
    # kwargs on every call, and `reconstruct` (the one canonical copy-with-changes
    # site, invoked once per rewritten node in `_sub_preserving`/`_resolve_*`)
    # would pay that on every substitution. Routing `reconstruct` through this
    # positional form drops the per-node NamedTuple allocation entirely. The
    # arguments MUST be all fields in exact struct-field order — enforced by the
    # arity check (compile-time-constant after specialization, so it costs
    # nothing at runtime). `Vararg{Any,N} where N` (not bare `fields...`) forces
    # Julia to SPECIALIZE per call-site arity/type instead of applying its
    # "pass-through varargs" despecialization heuristic — the generated
    # `reconstruct` below is the hot caller and must stay allocation-free.
    global _reconstruct_opexpr(fields::Vararg{Any,N}) where {N} =
        (N === fieldcount(OpExpr) ||
             throw(ArgumentError("_reconstruct_opexpr requires all $(fieldcount(OpExpr)) OpExpr fields in struct order"));
         new(fields...))
end

"""
    OPEXPR_FIELD_TABLE

THE `OpExpr` field-spec table — the single source of truth for what each of
the struct's fields IS, from which every field-generic consumer is derived
(by `@eval` metaprogramming or direct table lookup):

- the wire contract [`OPEXPR_WIRE_KEYS`](@ref) (parse + serialize key set),
- `_parse_op_optional_fields` (parse.jl, generated field extraction),
- `_serialize_opexpr_field` (serialize.jl, per-kind wire encoding),
- [`reconstruct(::OpExpr)`](@ref) (generated below),
- the expression walkers `child_exprs` / `foreach_child` /
  `_foreach_subexpr_children` / `map_children` / `foreach_child_with_path`
  (expression.jl, generated), and validate.jl's `_expr_children`.

One row per struct field, in exact struct-field order (asserted at load).
Columns:

- `wire`: the JSON key the field is parsed from / serialized to (`nothing`
  for an internal, never-serialized field). Three fields are spelled
  differently on the wire: `int_var` ↔ `var`, `expr_body` ↔ `expr`,
  `table_axes` ↔ `axes`.
- `kind`: the field's shape class, which determines BOTH its wire encoding
  and whether/how the expression walkers traverse it:
    - `:expr`      — optional nested `ASTExpr` (traversed),
    - `:expr_vec`  — `Vector{ASTExpr}` (traversed; `args` is the one
                     required instance, the rest are optional),
    - `:expr_map`  — `Dict{String,ASTExpr}` (values traversed in sorted-key
                     order). NOTE: `bindings` (template parameter →
                     argument-expression map) IS traversed like any other
                     expression-bearing field — historically `child_exprs`
                     skipped it (while validate's `_expr_children` skipped
                     `ranges`), leaving `free_variables`/`substitute`/
                     `contains` blind to names inside binding values.
    - `:ranges`    — the `ranges` map: `IndexSetRef` or dense bound vectors
                     whose entries MAY be expression-valued (only those
                     `ASTExpr` entries are traversed),
    - `:join`      — the parsed join clauses (column-NAME strings, no
                     sub-expressions; bespoke wire encoding),
    - `:scalar`    — plain data (strings/ints/JSON), identity-encoded on the
                     wire, never traversed,
    - `:internal`  — build-time only; never parsed, serialized or traversed.
- `parse`: for `:scalar` fields, the parse-recipe tag `_parse_op_optional_fields`
  dispatches on (`:string`, `:int`, `:int_vec`, `:bool`, `:json`,
  `:output_idx`, `:regions`, `:shape`, `:int_or_string`); `nothing` when the
  `kind` alone determines parsing.
- `binds_scope`: `true` for the one field whose KEYS validate's
  `_bound_index_symbols` credits into reference-check scope (`bindings` —
  template formal-parameter names). A legitimate consumer DIFFERENCE, not a
  traversal property: `free_variables`' binder subtraction (`_bound_symbols`,
  expression.jl) deliberately does NOT use it.

Adding an `OpExpr` field without a row here fails the load-time assert below;
`round_trip_regression_test.jl` then pins its real parse/serialize behavior.
"""
const OPEXPR_FIELD_TABLE = (
    op         = (wire = :op,         kind = :scalar, parse = nothing,          binds_scope = false),
    args       = (wire = :args,       kind = :expr_vec, parse = nothing,        binds_scope = false),
    wrt        = (wire = :wrt,        kind = :scalar, parse = :string,          binds_scope = false),
    dim        = (wire = :dim,        kind = :scalar, parse = :string,          binds_scope = false),
    int_var    = (wire = :var,        kind = :scalar, parse = :string,          binds_scope = false),
    lower      = (wire = :lower,      kind = :expr,   parse = nothing,          binds_scope = false),
    upper      = (wire = :upper,      kind = :expr,   parse = nothing,          binds_scope = false),
    output_idx = (wire = :output_idx, kind = :scalar, parse = :output_idx,      binds_scope = false),
    expr_body  = (wire = :expr,       kind = :expr,   parse = nothing,          binds_scope = false),
    reduce     = (wire = :reduce,     kind = :scalar, parse = :string,          binds_scope = false),
    semiring   = (wire = :semiring,   kind = :scalar, parse = :string,          binds_scope = false),
    ranges     = (wire = :ranges,     kind = :ranges, parse = nothing,          binds_scope = false),
    regions    = (wire = :regions,    kind = :scalar, parse = :regions,         binds_scope = false),
    values     = (wire = :values,     kind = :expr_vec, parse = nothing,        binds_scope = false),
    shape      = (wire = :shape,      kind = :scalar, parse = :shape,           binds_scope = false),
    perm       = (wire = :perm,       kind = :scalar, parse = :int_vec,         binds_scope = false),
    axis       = (wire = :axis,       kind = :scalar, parse = :int,             binds_scope = false),
    fn         = (wire = :fn,         kind = :scalar, parse = :string,          binds_scope = false),
    name       = (wire = :name,       kind = :scalar, parse = :string,          binds_scope = false),
    value      = (wire = :value,      kind = :scalar, parse = :json,            binds_scope = false),
    table      = (wire = :table,      kind = :scalar, parse = :string,          binds_scope = false),
    table_axes = (wire = :axes,       kind = :expr_map, parse = nothing,        binds_scope = false),
    output     = (wire = :output,     kind = :scalar, parse = :int_or_string,   binds_scope = false),
    join       = (wire = :join,       kind = :join,   parse = nothing,          binds_scope = false),
    filter     = (wire = :filter,     kind = :expr,   parse = nothing,          binds_scope = false),
    join_gates = (wire = nothing,     kind = :internal, parse = nothing,        binds_scope = false),
    id         = (wire = :id,         kind = :scalar, parse = :string,          binds_scope = false),
    manifold   = (wire = :manifold,   kind = :scalar, parse = :string,          binds_scope = false),
    distinct   = (wire = :distinct,   kind = :scalar, parse = :bool,            binds_scope = false),
    key        = (wire = :key,        kind = :expr,   parse = nothing,          binds_scope = false),
    arg        = (wire = :arg,        kind = :scalar, parse = :string,          binds_scope = false),
    bindings   = (wire = :bindings,   kind = :expr_map, parse = nothing,        binds_scope = true),
    label      = (wire = :label,      kind = :scalar, parse = :string,          binds_scope = false),
)

# The table must cover EXACTLY the struct's fields, in struct-field order —
# the walkers/parse/serialize generators iterate it in this order.
@assert keys(OPEXPR_FIELD_TABLE) == fieldnames(OpExpr) "OPEXPR_FIELD_TABLE rows must match fieldnames(OpExpr) exactly, in order"

"""
    OPEXPR_WIRE_KEYS

The `OpExpr` field ↔ wire (JSON) key contract, DERIVED from
[`OPEXPR_FIELD_TABLE`](@ref): every field with a non-`nothing` `wire` column,
mapped to its JSON key. `join_gates` is the one struct field deliberately
absent: it is a build-time artifact, never parsed or serialized. Consumed by
`serialize_expression`'s emit loop and pinned field-by-field by
`round_trip_regression_test.jl`.
"""
const OPEXPR_WIRE_KEYS = (;
    (f => spec.wire for (f, spec) in pairs(OPEXPR_FIELD_TABLE)
     if spec.wire !== nothing)...)

# Accept any AbstractVector of ASTExpr-subtypes (e.g. Vector{VarExpr},
# Vector{OpExpr}, mixed Any arrays) and widen to Vector{ASTExpr}. This keeps
# call sites terse — callers don't need to annotate `ASTExpr[...]` when they
# construct a homogeneous argument list.
function OpExpr(op::String, args::AbstractVector; kwargs...)
    widened = Vector{ASTExpr}(undef, length(args))
    for (i, a) in enumerate(args)
        widened[i] = a
    end
    return OpExpr(op, widened; kwargs...)
end

# GENERATED from `fieldnames(OpExpr)` (see OPEXPR_FIELD_TABLE): one kwarg per
# struct field, each defaulting to the corresponding field of `e`, forwarded
# positionally (NamedTuple-free on the hot path) to `_reconstruct_opexpr` in
# struct-field order — so a newly added field is copied by default and can
# never be silently dropped.
@eval function reconstruct(e::OpExpr;
        op::String = e.op,
        args = e.args,
        $((Expr(:kw, f, :(e.$f)) for f in fieldnames(OpExpr)
           if f !== :op && f !== :args)...))
    # Positional (NamedTuple-free) construction on the hot path. `args` defaults to
    # the `Vector{ASTExpr}` field and callers overwrite it with `Vector{ASTExpr}`s, so the
    # `isa` fast path is the norm; the widening branch preserves the historical
    # acceptance of any `AbstractVector` of `ASTExpr` (matching the keyword ctor's
    # `OpExpr(op, args::AbstractVector)` widening overload).
    argv = args isa Vector{ASTExpr} ? args : Vector{ASTExpr}(args)
    return _reconstruct_opexpr(op, argv,
        $((f for f in fieldnames(OpExpr) if f !== :op && f !== :args)...))
end

@doc """
    reconstruct(e::OpExpr; op=…, args=…, <any OpExpr field>=…) -> OpExpr

Rebuild an `OpExpr`, copying EVERY field from `e` by default and overriding only
the keywords explicitly passed. This is the ONE canonical, field-preserving way
to reconstruct a node after a structural rewrite (substitution, namespacing,
simplification, canonicalization, …).

It exists because `OpExpr` carries ~26 optional fields (geometry `manifold`/`id`,
`table`/`table_axes`/`output`, aggregate `semiring`/`ranges`/`output_idx`/
`expr_body`/`reduce`, relational `join`/`filter`/`join_gates`, `int_var`/`lower`/
`upper`, …) and the historical reconstruction sites each hand-listed a different
subset of keywords — silently dropping whatever they forgot. That made
`flatten`/`substitute`/`namespace_expr` LOSSY: e.g. a coupling `substitute`
erased an `intersect_polygon`'s `manifold`, and `namespace_expr` erased a
`table_lookup`'s `table`. Routing every rewrite through `reconstruct` makes
field preservation the default and a drop an explicit, visible choice — and the
method is GENERATED from `fieldnames(OpExpr)`, so a newly added field is
preserved automatically.

Callers that transform sub-expressions should pass the already-transformed
result for the relevant field, e.g. `reconstruct(e; args=new_args)` or
`reconstruct(e; expr_body=new_body, filter=new_filter)`.
""" reconstruct

# ========================================
# 2. Equation Types
# ========================================

"""
    Equation(lhs::ASTExpr, rhs::ASTExpr; _comment=nothing)

Mathematical equation with left-hand side and right-hand side expressions.
Used for differential equations and algebraic constraints.
Optional `_comment` provides a human-readable description.
"""
struct Equation
    lhs::ASTExpr
    rhs::ASTExpr
    _comment::Union{String,Nothing}

    Equation(lhs::ASTExpr, rhs::ASTExpr; _comment=nothing) =
        new(lhs, rhs, _comment)
end

"""
    AffectEquation(lhs::String, rhs::ASTExpr)

Assignment equation for discrete events.
- `lhs`: target variable name (string)
- `rhs`: expression for the new value
"""
struct AffectEquation
    lhs::String
    rhs::ASTExpr
end

# ========================================
# 3. Event System Base Types
# ========================================

"""
    abstract type EventType end

Abstract base type for all event types in the ESM format.
"""
abstract type EventType end

"""
    abstract type DiscreteEventTrigger end

Abstract base type for discrete event triggers.
"""
abstract type DiscreteEventTrigger end

"""
    ConditionTrigger(expression::ASTExpr)

Trigger based on boolean condition expression.
"""
struct ConditionTrigger <: DiscreteEventTrigger
    expression::ASTExpr
end

"""
    PeriodicTrigger(period::Float64, phase::Float64)

Trigger that fires periodically.
- `period`: time interval between triggers
- `phase`: time offset for first trigger
"""
struct PeriodicTrigger <: DiscreteEventTrigger
    period::Float64
    phase::Float64

    # Constructor with optional phase
    PeriodicTrigger(period::Float64; phase=0.0) = new(period, phase)
end

"""
    PresetTimesTrigger(times::Vector{Float64})

Trigger that fires at preset times.
"""
struct PresetTimesTrigger <: DiscreteEventTrigger
    times::Vector{Float64}
end

# ========================================
# 4. Event Types
# ========================================

"""
    ContinuousEvent <: EventType

Event triggered by zero-crossing of condition expressions.
"""
struct ContinuousEvent <: EventType
    conditions::Vector{ASTExpr}
    affects::Vector{AffectEquation}
    description::Union{String,Nothing}

    # Constructor with optional description
    ContinuousEvent(conditions::Vector{ASTExpr}, affects::Vector{AffectEquation}; description=nothing) =
        new(conditions, affects, description)
end

"""
    DiscreteEvent <: EventType

Event triggered by discrete triggers whose symbolic `affects` are
[`AffectEquation`](@ref)s (`lhs` target name, `rhs` new-value expression) —
the schema's `AffectEquation` shape, shared with `ContinuousEvent`.

`functional_affect` carries the raw schema `functional_affect` handler
descriptor (`handler_id`, `read_vars`, `read_params`, optional
`modified_params` / `config`) verbatim, so a handler-based event survives a
parse → serialize round trip instead of degrading into a bogus `{lhs, rhs}`
affect equation. The schema (`DiscreteEvent` oneOf) requires exactly one of
symbolic `affects` or a `functional_affect` descriptor.
"""
struct DiscreteEvent <: EventType
    trigger::DiscreteEventTrigger
    affects::Vector{AffectEquation}
    description::Union{String,Nothing}
    functional_affect::Union{Dict{String,Any},Nothing}
    # Names the event mutates as *discrete parameters* (MTK `discrete_parameters`).
    # Every entry must name a declared PARAMETER of the enclosing model — see
    # `validate_single_event_consistency`, which reports `invalid_discrete_param`
    # otherwise. Previously parsed-and-dropped, which both lost the field on
    # round-trip and made the check impossible.
    discrete_parameters::Union{Vector{String},Nothing}

    # Constructor with optional description / handler descriptor
    DiscreteEvent(trigger::DiscreteEventTrigger, affects::Vector{AffectEquation};
                  description=nothing, functional_affect=nothing,
                  discrete_parameters=nothing) =
        new(trigger, affects, description, functional_affect, discrete_parameters)
end

# ========================================
# 5. Model Component Types
# ========================================

"""
    @enum ModelVariableType

Type enumeration for model variables:
- StateVariable: differential state variables
- ParameterVariable: constant parameters
- ObservedVariable: derived/computed variables
- BrownianVariable: stochastic noise sources (Wiener processes). The presence
  of any brownian variable promotes the enclosing model from an ODE system to
  an SDE system. Maps to MTK `@brownians` and an `SDESystem`.
- DiscreteVariable: piecewise-constant between refreshes rather than
  continuously integrated — it holds its value until a `cadence` boundary, a
  loader refresh, or an event assigns a new one, so the solver never
  differentiates it. This is the fifth member of the schema's
  `ModelVariable.type` enum (the spelling for a loader/forcing-fed field,
  CONFORMANCE_SPEC §5.10.1). It lowers to a solver-side PARAMETER BUFFER: the
  refresh machinery writes it (`build_evaluator(...; param_arrays = …)`), and
  the cadence partition (§5.7) seeds it `discrete`, tainting every field that
  reads it. Declaring it is what distinguishes a real forcing from a typo
  (esm-spec §4.9.5); a bare undeclared forcing name is indistinguishable from
  a misspelling.

`discrete` is deliberately LAST so the existing members keep their integer
values.
"""
@enum ModelVariableType begin
    StateVariable
    ParameterVariable
    ObservedVariable
    BrownianVariable
    DiscreteVariable
end

"""
    MODEL_VARIABLE_TYPE_TABLE

The bidirectional `ModelVariableType` ↔ string vocabulary — one row per enum
member, the single source of truth for every kind-string mapping (previously
three hand-maintained parallel ladders). It lives here, next to the enum it
maps, following the [`OPEXPR_FIELD_TABLE`](@ref) precedent (op_registry.jl is
scoped to the `OpExpr.op` operator vocabulary; a variable-kind enum is not an
op). Columns:

- `enum`: the `ModelVariableType` member.
- `wire`: the schema's canonical spelling (`ModelVariable.type` enum values)
  — the serialize target (`serialize_model_variable_type`, serialize.jl) AND
  the `expression_graph` node-kind string (graph.jl), which is the wire
  spelling by contract.
- `legacy`: parse-only aliases `coerce_model_variable_type` (parse.jl) must
  keep accepting — the pre-schema CamelCase spellings matching the Julia
  member names.

Derived (below): [`_MODEL_VARIABLE_TYPE_WIRE`](@ref) and
[`_MODEL_VARIABLE_TYPE_FROM_STRING`](@ref). Round-trip and legacy-spelling
behavior is pinned by test/types_test.jl.
"""
const MODEL_VARIABLE_TYPE_TABLE = (
    (enum = StateVariable,     wire = "state",     legacy = ("StateVariable",)),
    (enum = ParameterVariable, wire = "parameter", legacy = ("ParameterVariable",)),
    (enum = ObservedVariable,  wire = "observed",  legacy = ("ObservedVariable",)),
    (enum = BrownianVariable,  wire = "brownian",  legacy = ("BrownianVariable",)),
    (enum = DiscreteVariable,  wire = "discrete",  legacy = ("DiscreteVariable",)),
)

# The table must cover EXACTLY the enum's members, in order — a new member
# without a row would otherwise silently serialize/graph as missing.
@assert Tuple(row.enum for row in MODEL_VARIABLE_TYPE_TABLE) ==
        Tuple(instances(ModelVariableType)) "MODEL_VARIABLE_TYPE_TABLE rows must match instances(ModelVariableType) exactly, in order"

"""
    _MODEL_VARIABLE_TYPE_WIRE

Enum → canonical wire spelling, derived from
[`MODEL_VARIABLE_TYPE_TABLE`](@ref). Consumers: `serialize_model_variable_type`
(serialize.jl) and `expression_graph`'s node-kind lookup (graph.jl).
"""
const _MODEL_VARIABLE_TYPE_WIRE = Dict{ModelVariableType,String}(
    row.enum => row.wire for row in MODEL_VARIABLE_TYPE_TABLE)

"""
    _MODEL_VARIABLE_TYPE_FROM_STRING

String → enum, derived from [`MODEL_VARIABLE_TYPE_TABLE`](@ref): every wire
spelling plus every legacy alias. Consumer: `coerce_model_variable_type`
(parse.jl).
"""
const _MODEL_VARIABLE_TYPE_FROM_STRING = let d = Dict{String,ModelVariableType}()
    for row in MODEL_VARIABLE_TYPE_TABLE
        d[row.wire] = row.enum
        for alias in row.legacy
            d[alias] = row.enum
        end
    end
    d
end

"""
    ModelVariable

Structure defining a model variable with its type, default value, and optional expression.

Brownian-only fields:
- `noise_kind`: stochastic process kind (currently only `"wiener"`).
- `correlation_group`: opaque tag grouping correlated noise sources.
"""
struct ModelVariable
    type::ModelVariableType
    default::Union{Float64,Nothing}
    description::Union{String,Nothing}
    expression::Union{ASTExpr,Nothing}
    units::Union{String,Nothing}
    default_units::Union{String,Nothing}
    # Arrayed-variable shape: ordered dimension names drawn from the
    # enclosing model's domain.spatial. `nothing` means scalar.
    # See discretization RFC §10.2.
    shape::Union{Vector{String},Nothing}
    # Staggered-grid location tag (e.g. "cell_center", "edge_normal",
    # "vertex"). `nothing` means no explicit staggering. See RFC §10.2.
    location::Union{String,Nothing}
    noise_kind::Union{String,Nothing}
    correlation_group::Union{String,Nothing}

    # Constructor with optional parameters
    ModelVariable(type::ModelVariableType;
                  default=nothing,
                  description=nothing,
                  expression=nothing,
                  units=nothing,
                  default_units=nothing,
                  shape=nothing,
                  location=nothing,
                  noise_kind=nothing,
                  correlation_group=nothing) =
        new(type, default, description, expression, units, default_units,
            shape, location, noise_kind, correlation_group)
end

"""
    reconstruct(v::ModelVariable; <any ModelVariable field>=…) -> ModelVariable

Rebuild a `ModelVariable`, copying every field from `v` by default and
overriding only the keywords explicitly passed. The `ModelVariable` analogue of
[`reconstruct(::OpExpr)`](@ref): route all copy-with-changes sites through this
helper so a newly added field is preserved by default instead of silently
dropped by a hand-listed subset.
"""
function reconstruct(v::ModelVariable;
        type::ModelVariableType = v.type,
        default = v.default,
        description = v.description,
        expression = v.expression,
        units = v.units,
        default_units = v.default_units,
        shape = v.shape,
        location = v.location,
        noise_kind = v.noise_kind,
        correlation_group = v.correlation_group)
    return ModelVariable(type;
        default=default, description=description, expression=expression,
        units=units, default_units=default_units, shape=shape,
        location=location, noise_kind=noise_kind,
        correlation_group=correlation_group)
end

"""
    TimeSpan(start::Float64, stop::Float64)

Simulation time interval for inline model tests and examples (§gt-cc1).
"""
struct TimeSpan
    start::Float64
    stop::Float64
end

"""
    Tolerance(abs::Union{Float64,Nothing}, rel::Union{Float64,Nothing})

Numerical comparison tolerance. Either or both of `abs` / `rel` may be
set; an assertion passes when any set bound is satisfied.
"""
struct Tolerance
    abs::Union{Float64,Nothing}
    rel::Union{Float64,Nothing}

    Tolerance(; abs=nothing, rel=nothing) = new(abs, rel)
end

"""
    Assertion(variable::String, time::Float64, expected::Float64, tolerance, coords, reduce, reference)

A scalar `(variable, time, expected)` check used inside a `InlineTest`.

PDE-aware variants (gt-vzwk):
- `coords`: pin a spatial point as `dim => coordinate` (mutually exclusive with `reduce`).
- `reduce`: collapse the spatial field to a scalar — one of `integral`, `mean`,
  `max`, `min`, `L2_error`, `Linf_error`. Mutually exclusive with `coords`.
- `reference`: required for error-norm reductions; either an `ASTExpr` AST evaluated
  over the domain coordinates, or a `Dict` representing the `{type: from_file,
  path, format?}` shape.
"""
struct Assertion
    variable::String
    time::Float64
    expected::Float64
    tolerance::Union{Tolerance,Nothing}
    coords::Union{Dict{String,Float64},Nothing}
    reduce::Union{String,Nothing}
    reference::Any

    function Assertion(variable::AbstractString, time::Real, expected::Real;
                       tolerance=nothing,
                       coords=nothing,
                       reduce=nothing,
                       reference=nothing)
        if coords !== nothing && reduce !== nothing
            throw(ArgumentError("Assertion: `coords` and `reduce` are mutually exclusive"))
        end
        if reduce !== nothing && (reduce == "L2_error" || reduce == "Linf_error") &&
                reference === nothing
            throw(ArgumentError("Assertion: `reduce=$(reduce)` requires `reference`"))
        end
        if reference !== nothing && reduce !== nothing &&
                !(reduce in ("L2_error", "Linf_error"))
            throw(ArgumentError("Assertion: `reference` is only meaningful for error-norm reductions"))
        end
        coords_typed = coords === nothing ? nothing :
            Dict{String,Float64}(string(k) => Float64(v) for (k, v) in coords)
        reduce_typed = _maybe(String, reduce)
        return new(String(variable), Float64(time), Float64(expected),
                   tolerance, coords_typed, reduce_typed, reference)
    end
end

"""
    InlineTest(id, time_span, assertions; description, initial_conditions, parameter_overrides, tolerance)

Inline validation test for a Model (schema gt-cc1). Defines the run
configuration — initial conditions, parameter overrides, simulation time
span — and a list of scalar assertions that must hold.
"""
# NAMING: this struct is spelled `InlineTest` (not `Test`) so it does NOT
# collide with the `Test` STANDARD-LIBRARY MODULE that every test suite brings
# in via `using Test`. It is the schema's inline-validation-test construct
# (`models.*.tests`, gt-cc1; esm-spec §6.6); not exported — reach it qualified
# as `EarthSciAST.InlineTest`.
struct InlineTest
    id::String
    description::Union{String,Nothing}
    initial_conditions::Dict{String,Float64}
    parameter_overrides::Dict{String,Float64}
    time_span::TimeSpan
    tolerance::Union{Tolerance,Nothing}
    assertions::Vector{Assertion}
    # Raw §9.7.2 import entries injected into the ENCLOSING component's scope
    # for THIS test's run only (esm-spec §9.7.10 form C / §6.6.6): the
    # discretization a discretization-agnostic PDE leaf is lowered under in the
    # per-test ephemeral build. Authored per-run config — a peer of
    # `parameter_overrides` — so unlike a component's own imports it DOES
    # survive `parse → emit`. Empty for a non-PDE / agnostic-free test.
    expression_template_imports::Vector{Any}

    function InlineTest(id::AbstractString, time_span::TimeSpan, assertions::Vector{Assertion};
                  description=nothing,
                  initial_conditions=Dict{String,Float64}(),
                  parameter_overrides=Dict{String,Float64}(),
                  tolerance=nothing,
                  expression_template_imports=Any[])
        return new(String(id), description,
                   Dict{String,Float64}(string(k) => Float64(v) for (k, v) in initial_conditions),
                   Dict{String,Float64}(string(k) => Float64(v) for (k, v) in parameter_overrides),
                   time_span, tolerance, assertions,
                   Vector{Any}(expression_template_imports))
    end
end

"""
    IndexSet(kind; size, members, of, offsets, values, from_faq)

A declared index set in the document-scoped `index_sets` registry
(RFC semiring-faq-unified-ir §5.2). Unifies ESM grid dims and ESI categorical
dims under one shape. `kind` is one of:

- `"interval"`   — dense integer axis; `size` gives its length.
- `"categorical"`— enumerated members; `members` is the ordered member list.
- `"ragged"`     — data-dependent inner set (e.g. the edges of a cell); `of`
  names the parent index set(s), `offsets` the length/CSR-offset backing factor,
  and `values` the member-id backing factor (both keyed factors, §5.4).
- `"derived"`    — materialized from another FAQ (§5.5); `from_faq` is its node
  id. Not evaluated by the tree-walk evaluator in M1.
"""
struct IndexSet
    kind::String
    size::Union{Int,Nothing}
    members::Union{Vector{String},Nothing}
    of::Union{Vector{String},Nothing}
    offsets::Union{String,Nothing}
    values::Union{String,Nothing}
    from_faq::Union{String,Nothing}
    # The original, un-stringified categorical members, retained ONLY when at
    # least one member is non-string (float / null / boolean / integer). Lets the
    # join-key validator (RFC §5.3) reject keys whose equality is not portable
    # across bindings — float and null members — which `members` (always coerced
    # to `String`) can no longer distinguish. `nothing` for ordinary string-only
    # sets, so they stay byte-identical to before.
    members_raw::Union{Vector{Any},Nothing}

    IndexSet(kind::AbstractString; size=nothing, members=nothing, of=nothing,
             offsets=nothing, values=nothing, from_faq=nothing, members_raw=nothing) =
        new(String(kind), size, members, of, offsets, values, from_faq, members_raw)
end

"""
    IndexSetRef(from; of)

A reference to a declared `IndexSet`, used as a `ranges[*]` value in place of a
dense `[lo, hi]` / `[lo, step, hi]` integer tuple (RFC §5.2). `from` is the
registry key; `of` lists the parent index *variable* names for a ragged /
dependent inner set (e.g. `of=["i"]` for the edges of cell `i`).
"""
struct IndexSetRef
    from::String
    of::Vector{String}

    IndexSetRef(from::AbstractString; of::AbstractVector=String[]) =
        new(String(from), String[String(x) for x in of])
end

"""
    abstract type SubsystemNode end

Common supertype of the three legal `Model.subsystems` values: a child
`Model`, a pure-I/O `DataLoader` (RFC pure-io-data-loaders §4.3), or — only
until references are resolved — a `SubsystemRef`. Exists so
`Model.subsystems` can be concretely typed `Dict{String,SubsystemNode}` even
though `DataLoader` is declared later in this file than `Model`.
"""
abstract type SubsystemNode end

"""
    SubsystemRef(ref::String)
    SubsystemRef(ref::String, bindings::Dict{String,Int})

Unresolved reference to an external ESM file used as a subsystem (esm-spec §4.7).
Produced by `coerce_model` for a `{"ref": "..."}` subsystem entry and replaced
in place by `resolve_subsystem_refs!` with the loaded `Model` or `DataLoader`.
A `SubsystemRef` only survives parsing when references are not resolved (e.g.
`load(::IO)` without a base path); `load(::String)` always resolves them.
`bindings` closes the referenced document's open metaparameters at this edge
(esm-spec §9.7.6 binding site 3 — e.g. a convergence wrapper instantiating a
problem file at a given size). `expression_template_imports` are the raw
§9.7.2 import entries injected into the REFERENCED component's own template
scope (esm-spec §9.7.10 form A — assembler-chosen discretization for a mounted
PDE leaf); they are threaded into the referenced document's load and consumed by
the §9.6.3 fixpoint, so a resolved subsystem round-trips as the lowered inline
component and the field does not survive `parse → emit`.
"""
struct SubsystemRef <: SubsystemNode
    ref::String
    bindings::Dict{String,Int}
    expression_template_imports::Vector{Any}
end

SubsystemRef(ref::AbstractString, bindings::AbstractDict) =
    SubsystemRef(String(ref),
                 Dict{String,Int}(string(k) => Int(v) for (k, v) in bindings), Any[])
SubsystemRef(ref::AbstractString) =
    SubsystemRef(String(ref), Dict{String,Int}(), Any[])

"""
    Model

ODE-based model component containing variables, equations, and optional subsystems.
Supports hierarchical composition through subsystems. A subsystem value is a
child `Model`, a pure-I/O `DataLoader` (RFC pure-io-data-loaders §4.3), or — only
until references are resolved — a `SubsystemRef`; the field is typed by their
shared supertype, `Dict{String,SubsystemNode}`.
"""
struct Model <: SubsystemNode
    variables::Dict{String,ModelVariable}
    equations::Vector{Equation}
    discrete_events::Vector{DiscreteEvent}
    continuous_events::Vector{ContinuousEvent}
    subsystems::Dict{String,SubsystemNode}
    tolerance::Union{Tolerance,Nothing}
    tests::Vector{InlineTest}
    initialization_equations::Vector{Equation}
    guesses::Dict{String,Union{Float64,ASTExpr}}
    system_kind::Union{String,Nothing}

    # Primary constructor with separate event arrays
    Model(variables::AbstractDict{String,ModelVariable}, equations::Vector{Equation},
          discrete_events::Vector{DiscreteEvent}, continuous_events::Vector{ContinuousEvent},
          subsystems::AbstractDict{String};
          tolerance=nothing, tests=InlineTest[],
          initialization_equations=Equation[],
          guesses=Dict{String,Union{Float64,ASTExpr}}(),
          system_kind=nothing) =
        new(Dict{String,ModelVariable}(variables), equations,
            discrete_events, continuous_events, Dict{String,SubsystemNode}(subsystems),
            tolerance, tests,
            initialization_equations, guesses, system_kind)

    # Convenience constructor with optional event arrays and subsystems.
    Model(variables::AbstractDict{String,ModelVariable}, equations::Vector{Equation};
          discrete_events=DiscreteEvent[],
          continuous_events=ContinuousEvent[],
          subsystems=Dict{String,SubsystemNode}(),
          tolerance=nothing,
          tests=InlineTest[],
          initialization_equations=Equation[],
          guesses=Dict{String,Union{Float64,ASTExpr}}(),
          system_kind=nothing) =
        new(Dict{String,ModelVariable}(variables), equations,
            discrete_events, continuous_events, Dict{String,SubsystemNode}(subsystems),
            tolerance, tests,
            initialization_equations, guesses, system_kind)
end

"""
    Species

Chemical species definition with name and optional properties.
"""
struct Species
    name::String
    units::Union{String,Nothing}
    default::Union{Float64,Nothing}
    description::Union{String,Nothing}
    default_units::Union{String,Nothing}
    constant::Union{Bool,Nothing}

    # Constructor with optional parameters
    Species(name::String; units=nothing, default=nothing, description=nothing, default_units=nothing, constant=nothing) =
        new(name, units, default, description, default_units, constant)
end

"""
    Parameter

Model parameter with name, default value, and optional metadata.
"""
struct Parameter
    name::String
    default::Float64
    description::Union{String,Nothing}
    units::Union{String,Nothing}
    default_units::Union{String,Nothing}

    # Constructor with optional parameters
    Parameter(name::String, default::Float64; description=nothing, units=nothing, default_units=nothing) =
        new(name, default, description, units, default_units)
end



# ========================================
# 6. Data and Operator Types
# ========================================

"""
    Reference

Academic citation or data source reference.
"""
struct Reference
    doi::Union{String,Nothing}
    citation::Union{String,Nothing}
    url::Union{String,Nothing}
    notes::Union{String,Nothing}

    # Constructor with all optional parameters
    Reference(; doi=nothing, citation=nothing, url=nothing, notes=nothing) =
        new(doi, citation, url, notes)
end

"""
    abstract type CouplingEntry end

Abstract base type for coupling entries that connect model components.
"""
abstract type CouplingEntry end

"""
    CouplingOperatorCompose <: CouplingEntry

Match LHS time derivatives and add RHS terms together.
"""
struct CouplingOperatorCompose <: CouplingEntry
    systems::Vector{String}
    translate::Union{Dict{String,Any},Nothing}
    description::Union{String,Nothing}
    lifting::Union{String,Nothing}

    CouplingOperatorCompose(systems::Vector{String}; translate=nothing, description=nothing, lifting=nothing) =
        new(systems, translate, description, lifting)
end

"""
    CouplingCouple <: CouplingEntry

Bi-directional coupling via connector equations.
"""
struct CouplingCouple <: CouplingEntry
    systems::Vector{String}
    connector::Dict{String,Any}
    description::Union{String,Nothing}
    lifting::Union{String,Nothing}

    CouplingCouple(systems::Vector{String}, connector::Dict{String,Any}; description=nothing, lifting=nothing) =
        new(systems, connector, description, lifting)
end

"""
    CouplingVariableMap <: CouplingEntry

Replace a parameter in one system with a variable from another, or — when
`transform` is an `ASTExpr` operator node rather than one of the named transform
strings — with a derived value computed from it (esm-spec §10.4: the target
parameter becomes an observed whose defining expression is the transform,
evaluated in the flattened coupled system's scope; §8.6/§10.5 regridding form).
An `ASTExpr` transform takes no `factor` (fold scaling into the expression).
"""
struct CouplingVariableMap <: CouplingEntry
    from::String
    to::String
    transform::Union{String,ASTExpr}
    factor::Union{Float64,Nothing}
    description::Union{String,Nothing}
    lifting::Union{String,Nothing}

    function CouplingVariableMap(from::String, to::String, transform::Union{String,ASTExpr};
                                 factor=nothing, description=nothing, lifting=nothing)
        # SINGLE enforcement point for the "expression transform takes no
        # factor" invariant. The parser (`coerce_variable_map`, parse.jl) does
        # not pre-check; it catches this ArgumentError and rebrands it as a
        # ParseError so `load` keeps its historical error type/message.
        if transform isa ASTExpr && factor !== nothing
            throw(ArgumentError("variable_map: an expression `transform` takes no `factor` (fold the scaling into the expression)"))
        end
        new(from, to, transform, factor, description, lifting)
    end
end

"""
    CouplingOperatorApply <: CouplingEntry

Register an operator (referenced by name) to run during simulation.
"""
struct CouplingOperatorApply <: CouplingEntry
    operator::String
    description::Union{String,Nothing}

    CouplingOperatorApply(operator::String; description=nothing) =
        new(operator, description)
end

"""
    CouplingCallback <: CouplingEntry

Register a callback for simulation events.
"""
struct CouplingCallback <: CouplingEntry
    callback_id::String
    config::Union{Dict{String,Any},Nothing}
    description::Union{String,Nothing}

    CouplingCallback(callback_id::String; config=nothing, description=nothing) =
        new(callback_id, config, description)
end

"""
    CouplingEvent <: CouplingEntry

Cross-system event involving variables from multiple coupled systems.
"""
struct CouplingEvent <: CouplingEntry
    event_type::String
    conditions::Union{Vector{ASTExpr},Nothing}
    trigger::Union{DiscreteEventTrigger,Nothing}
    affects::Vector{AffectEquation}
    affect_neg::Union{Vector{AffectEquation},Nothing}
    discrete_parameters::Union{Vector{String},Nothing}
    root_find::Union{String,Nothing}
    reinitialize::Union{Bool,Nothing}
    description::Union{String,Nothing}

    CouplingEvent(event_type::String, affects::Vector{AffectEquation};
                  conditions=nothing, trigger=nothing, affect_neg=nothing,
                  discrete_parameters=nothing, root_find=nothing, reinitialize=nothing, description=nothing) =
        new(event_type, conditions, trigger, affects, affect_neg, discrete_parameters, root_find, reinitialize, description)
end

"""
    CouplingImport <: CouplingEntry

Reuse of a coupling-library file (esm-spec §10.9, §10.10). Names a library by
`ref` and binds each of the library's declared roles to a component in the
assembly via `bind` (role name → a top-level `models`/`reaction_systems`/
`data_loaders` key, or a dotted `Parent.Child` subsystem path). At flatten the
import expands into concrete `variable_map`/`couple`/`operator_compose`/`event`
edges by substituting the bound actual for every role-named top-level segment
(`expand_coupling_imports`); the entry itself round-trips intact.
"""
struct CouplingImport <: CouplingEntry
    ref::String
    bind::Dict{String,String}
    description::Union{String,Nothing}

    CouplingImport(ref::String, bind::AbstractDict=Dict{String,String}(); description=nothing) =
        new(ref, Dict{String,String}(string(k) => string(v) for (k, v) in pairs(bind)), description)
end

"""
    DataLoaderSource

File discovery configuration for a DataLoader. Describes how to locate data
files at runtime via a URL template with `{date:<strftime>}`, `{var}`,
`{sector}`, `{species}`, and custom substitutions. Optional `mirrors` list
gives ordered fallback templates.
"""
struct DataLoaderSource
    url_template::String
    mirrors::Union{Vector{String},Nothing}

    DataLoaderSource(url_template::String; mirrors=nothing) =
        new(url_template, mirrors)
end

"""
    DataLoaderTemporal

Temporal coverage and record layout for a DataLoader.
"""
struct DataLoaderTemporal
    start::Union{String,Nothing}
    stop::Union{String,Nothing}           # field name "end" in JSON (reserved word in Julia)
    file_period::Union{String,Nothing}
    frequency::Union{String,Nothing}
    records_per_file::Union{Int,String,Nothing}  # integer or "auto"
    time_variable::Union{String,Nothing}

    DataLoaderTemporal(; start=nothing, stop=nothing, file_period=nothing,
                       frequency=nothing, records_per_file=nothing,
                       time_variable=nothing) =
        new(start, stop, file_period, frequency, records_per_file, time_variable)
end

"""
    DataLoaderVariable

A variable exposed by a DataLoader, mapped from a source-file variable.
`unit_conversion` may be a numeric factor or an Expression AST.
"""
struct DataLoaderVariable
    file_variable::String
    units::String
    unit_conversion::Union{Float64,ASTExpr,Nothing}
    description::Union{String,Nothing}
    reference::Union{Reference,Nothing}

    DataLoaderVariable(file_variable::String, units::String;
                       unit_conversion=nothing,
                       description=nothing,
                       reference=nothing) =
        new(file_variable, units, unit_conversion, description, reference)
end

"""
    DataLoaderDeterminism

Reproducibility contract a loader advertises to bindings (esm-spec §8.9.2).
A binding that cannot honor the declared endian / float_format / integer_width
MUST reject the file at load.

Fields (all optional):
- `endian`: "little" | "big"
- `float_format`: "ieee754_single" | "ieee754_double"
- `integer_width`: 32 | 64
"""
struct DataLoaderDeterminism
    endian::Union{String,Nothing}
    float_format::Union{String,Nothing}
    integer_width::Union{Int,Nothing}

    DataLoaderDeterminism(; endian=nothing, float_format=nothing, integer_width=nothing) =
        new(endian, float_format, integer_width)
end

"""
    DataLoader

Generic, runtime-agnostic description of an external data source. Pure I/O:
carries enough structural information to locate files, map timestamps to
files, and describe the data's native grid and variable semantics — rather
than pointing at a runtime handler or performing any regridding.
Authentication and algorithm-specific tuning are runtime-only and not part
of the schema.

Fields:
- `kind`: "grid" | "points" | "static" (structural kind; scientific role goes in `metadata.tags`)
- `source`: `DataLoaderSource` with url_template + optional mirrors
- `temporal`: optional `DataLoaderTemporal`
- `determinism`: optional `DataLoaderDeterminism` (esm-spec §8.9.2)
- `variables`: schema-level variable name → `DataLoaderVariable` (minimum one)
- `reference`: optional academic/data-source citation
- `metadata`: optional free-form map (conventionally carries a `tags` array)
"""
struct DataLoader <: SubsystemNode
    kind::String
    source::DataLoaderSource
    temporal::Union{DataLoaderTemporal,Nothing}
    determinism::Union{DataLoaderDeterminism,Nothing}
    variables::Dict{String,DataLoaderVariable}
    reference::Union{Reference,Nothing}
    metadata::Union{Dict{String,Any},Nothing}

    DataLoader(kind::String, source::DataLoaderSource,
               variables::Dict{String,DataLoaderVariable};
               temporal=nothing,
               determinism=nothing,
               reference=nothing,
               metadata=nothing) =
        new(kind, source, temporal, determinism,
            variables, reference, metadata)
end

# ========================================
# 7. System Configuration Types
# ========================================

"""
    Domain

Spatial and temporal domain specification.
"""
struct Domain
    # The name of the independent (time) variable, `"t"` unless the document
    # renames it. It was parsed by NOBODY: the field is in esm-schema.json (with
    # `additionalProperties: false`, so it is the only spelling), yet `Domain`
    # did not carry it — so `load` silently DROPPED it and a round-trip through
    # Julia rewrote a `tau`-based document as a `t`-based one. Validation needs
    # it too: the independent variable is implicitly declared (finding (a)), and
    # the check for it used to be a literal `name == "t"`, which both accepted a
    # bare `t` in a document that renamed it and rejected the real name.
    independent_variable::String
    temporal::Union{Dict{String,Any},Nothing}

    # Constructor with optional parameters
    Domain(; independent_variable::AbstractString="t", temporal=nothing) =
        new(String(independent_variable), temporal)
end

"""
    StoichiometryEntry

A species with its stoichiometric coefficient in a reaction.
"""
struct StoichiometryEntry
    species::String
    stoichiometry::Float64

    function StoichiometryEntry(species::String, stoichiometry::Real)
        if !isfinite(stoichiometry)
            throw(ArgumentError(
                "StoichiometryEntry: stoichiometry must be finite (got $(stoichiometry)) for species '$(species)'"
            ))
        end
        if stoichiometry <= 0
            throw(ArgumentError(
                "StoichiometryEntry: stoichiometry must be positive (got $(stoichiometry)) for species '$(species)'"
            ))
        end
        return new(species, Float64(stoichiometry))
    end
end

"""
    Reaction

Chemical reaction with substrates, products, and rate expression.
"""
struct Reaction
    id::String
    name::Union{String,Nothing}
    substrates::Union{Vector{StoichiometryEntry},Nothing}  # null for source reactions (∅ → X)
    products::Union{Vector{StoichiometryEntry},Nothing}    # null for sink reactions (X → ∅)
    rate::ASTExpr
    reference::Union{Reference,Nothing}

    # Constructor with optional parameters
    Reaction(id::String, substrates::Union{Vector{StoichiometryEntry},Nothing},
             products::Union{Vector{StoichiometryEntry},Nothing}, rate::ASTExpr;
             name=nothing, reference=nothing) =
        new(id, name, substrates, products, rate, reference)
end

"""
    ReactionSystem

Collection of chemical reactions with associated species, supporting hierarchical composition.
"""
struct ReactionSystem
    species::Vector{Species}
    reactions::Vector{Reaction}
    parameters::Vector{Parameter}
    subsystems::Dict{String,ReactionSystem}
    tolerance::Union{Tolerance,Nothing}
    tests::Vector{InlineTest}

    # Constructor with optional parameters and subsystems
    ReactionSystem(species::Vector{Species}, reactions::Vector{Reaction};
                   parameters=Parameter[], subsystems=Dict{String,ReactionSystem}(),
                   tolerance=nothing, tests=InlineTest[]) =
        new(species, reactions, parameters, subsystems, tolerance, tests)
end

"""
    Metadata

Authorship, provenance, and description metadata.
"""
struct Metadata
    name::String
    description::Union{String,Nothing}
    authors::Vector{String}
    license::Union{String,Nothing}
    created::Union{String,Nothing}  # ISO 8601 timestamp
    modified::Union{String,Nothing} # ISO 8601 timestamp
    tags::Vector{String}
    references::Vector{Reference}

    # Constructor with optional parameters
    Metadata(name::String;
             description=nothing,
             authors=String[],
             license=nothing,
             created=nothing,
             modified=nothing,
             tags=String[],
             references=Reference[]) =
        new(name, description, authors, license, created, modified, tags, references)
end

"""
    FunctionTableAxis

A single named axis inside a [`FunctionTable`](@ref) (esm-spec §9.5).
`values` MUST be strictly-increasing finite floats with at least 2 entries
(mirrors the §9.2 interp.linear / interp.bilinear axis contract). `units`
is advisory only in v0.4.0.
"""
struct FunctionTableAxis
    name::String
    values::Vector{Float64}
    units::Union{String,Nothing}
    FunctionTableAxis(name::AbstractString, values::AbstractVector;
                      units=nothing) =
        new(String(name), Vector{Float64}(values), units)
end

"""
    FunctionTable

A sampled function table referenced by `table_lookup` AST op nodes
(esm-spec §9.5, v0.4.0). Tables are syntactic sugar over §9.2's
`interp.linear` / `interp.bilinear` / `index` — a `table_lookup` query
MUST be bit-equivalent to the equivalent inline-`const` lookup. Shape of
`data` is `[len(outputs), len(axes[0].values), len(axes[1].values), ...]`
when `outputs` is non-`nothing`; `[len(axes[0].values), ...]` otherwise.
"""
struct FunctionTable
    axes::Vector{FunctionTableAxis}
    data::Any  # Nested-array literal of finite numbers
    description::Union{String,Nothing}
    interpolation::Union{String,Nothing}  # "linear" | "bilinear" | "nearest"
    out_of_bounds::Union{String,Nothing}  # "clamp" | "error"
    outputs::Union{Vector{String},Nothing}
    shape::Union{Vector{Int},Nothing}
    schema_version::Union{String,Nothing}
    FunctionTable(axes::AbstractVector{FunctionTableAxis}, data;
                  description=nothing, interpolation=nothing,
                  out_of_bounds=nothing, outputs=nothing,
                  shape=nothing, schema_version=nothing) =
        new(Vector{FunctionTableAxis}(axes), data, description,
            interpolation, out_of_bounds, outputs, shape, schema_version)
end

"""
    EsmFile

Main ESM file structure containing all components.
"""
struct EsmFile
    esm::String  # Version string
    metadata::Metadata
    models::Union{Dict{String,Model},Nothing}
    reaction_systems::Union{Dict{String,ReactionSystem},Nothing}
    data_loaders::Union{Dict{String,DataLoader},Nothing}
    coupling::Vector{CouplingEntry}
    # The single temporal domain shared by every component in the document
    # (esm-spec v0.8.0: top-level `domain`, not a map of named domains). A
    # document has at most one Domain; 0-D models simply have scalar-shaped
    # variables and spatial models are shaped over index sets.
    domain::Union{Domain,Nothing}
    # File-local enum mappings used by the `enum` AST op (esm-spec §9.3).
    # Keys are enum names; each value maps a symbol → positive integer.
    # `enum`-op nodes are lowered to `const`-int nodes at load time, so the
    # in-memory expression tree never carries enum strings.
    enums::Union{Dict{String,Dict{String,Int}},Nothing}
    # Component-scoped sampled function tables (esm-spec §9.5, v0.4.0).
    # Keys are table ids; values are FunctionTable entries referenced by
    # table_lookup AST nodes.
    function_tables::Union{Dict{String,FunctionTable},Nothing}
    # Document-scoped index-set registry (RFC semiring-faq-unified-ir §5.2;
    # esm-spec v0.8.0). A single registry, sibling of `models`/`domain`, shared
    # by every component: `ranges[*]` `{from: <name>}` references, array-variable
    # `shape`s, and derived-set `from_faq` edges resolve against it. Empty when
    # the document declares none.
    index_sets::Dict{String,IndexSet}

    # The top-level `expression_templates` registry and `metaparameters` block,
    # PRESERVED VERBATIM (raw JSON) across parse → emit.
    #
    # Option A expands CALL SITES; it does not delete DECLARATIONS (esm-spec
    # §9.6.4 rule 5). These two are peers of `index_sets`, not
    # `apply_expression_template` invocations — but the loader treated the
    # registry as if it were a call site and dropped it, so a pure template
    # LIBRARY (a file whose only payload is `expression_templates`) re-emitted as
    # `{esm, metadata, index_sets}`: no payload key at all, which the top-level
    # `anyOf` correctly rejects. The file was legal on disk and illegal the
    # instant it was loaded and written back — and since §9.6.4 rule 4 runs
    # schema validation on the POST-EXPANSION form, a conforming library file was
    # literally unrepresentable (tests/valid/template_import_lib.esm,
    # template_import_rename_lib.esm).
    #
    # They are kept raw rather than typed because nothing in the pipeline reads
    # them back after lowering — their only job is to survive the round trip so a
    # library file emits to itself.
    expression_templates::Union{Dict{String,Any},Nothing}
    metaparameters::Union{Dict{String,Any},Nothing}

    # Per-component MATERIALIZED template registries (esm-spec §9.6.4 rule 5,
    # Option B reference-preserving round-trip). Keyed by "<compkind>.<cname>"
    # (e.g. "models.Advection"), each value is the emitted `expression_templates`
    # block a component's surviving `apply_expression_template` references
    # materialize into — authored entries first, then the reference closure. The
    # component's equations/variables carry the surviving references as typed
    # `apply_expression_template` `OpExpr`s; `serialize_esm_file` re-injects these
    # blocks so `save(EsmFile)` emits the reference-preserving form byte-identically
    # to `emit_document`. `nothing` under `ESS_TEMPLATE_REF_DISABLE=1` (Expand at
    # load) or for a document with no surviving references.
    component_templates::Union{Dict{String,Any},Nothing}

    # Constructor with optional parameters
    EsmFile(esm::String, metadata::Metadata;
            models=nothing,
            reaction_systems=nothing,
            data_loaders=nothing,
            coupling=CouplingEntry[],
            domain=nothing,
            enums=nothing,
            function_tables=nothing,
            index_sets=Dict{String,IndexSet}(),
            expression_templates=nothing,
            metaparameters=nothing,
            component_templates=nothing) =
        new(esm, metadata, models, reaction_systems, data_loaders,
            coupling, domain, enums, function_tables,
            Dict{String,IndexSet}(index_sets),
            expression_templates, metaparameters, component_templates)
end

# ========================================
# 8. Reference Resolution System
# ========================================

"""
    QualifiedReferenceError

Exception thrown when qualified reference resolution fails.
Contains detailed error information.
"""
struct QualifiedReferenceError <: Exception
    message::String
    reference::String
    path::Vector{String}
end

Base.showerror(io::IO, e::QualifiedReferenceError) =
    print(io, "QualifiedReferenceError: ", e.message, " (reference: '", e.reference, "')")

"""
    ReferenceResolution

Result of qualified reference resolution containing the resolved variable
and its location information.
"""
struct ReferenceResolution
    variable_name::String
    system_path::Vector{String}
    system_type::Symbol  # :model, :reaction_system, :data_loader
    resolved_system::Union{Model,ReactionSystem,DataLoader}
end

"""
    resolve_qualified_reference(esm_file::EsmFile, reference::String) -> ReferenceResolution

Resolve a qualified reference string using hierarchical dot notation.

The reference string is split on dots to produce segments [s₁, s₂, …, sₙ].
The final segment sₙ is the variable name. The preceding segments [s₁, …, sₙ₋₁]
form a path through the subsystem hierarchy.

## Algorithm
1. Split reference on "." to get segments
2. First segment must match a top-level system (models, reaction_systems, data_loaders, operators)
3. Each subsequent segment must match a key in the parent system's subsystems map
4. Final segment is the variable name to resolve

## Examples
- `"SuperFast.O3"` → Variable `O3` in top-level model `SuperFast`
- `"SuperFast.GasPhase.O3"` → Variable `O3` in subsystem `GasPhase` of model `SuperFast`
- `"Atmosphere.Chemistry.FastChem.NO2"` → Variable `NO2` in nested subsystems

## Throws
- `QualifiedReferenceError` if reference cannot be resolved
"""
function resolve_qualified_reference(esm_file::EsmFile, reference::String)::ReferenceResolution
    if isempty(reference)
        throw(QualifiedReferenceError("Empty reference string", reference, String[]))
    end

    segments = split(reference, ".")
    if length(segments) < 1
        throw(QualifiedReferenceError("Invalid reference format", reference, String[]))
    end

    # Extract variable name (last segment) and system path
    variable_name = String(segments[end])
    system_path = String.(segments[1:end-1])

    # Handle bare references (no dot)
    if length(system_path) == 0
        throw(QualifiedReferenceError("Bare references not supported without system context", reference, String[]))
    end

    # Resolve the system path
    top_level_name = system_path[1]
    remaining_path = system_path[2:end]

    # Find top-level system
    system, system_type = find_top_level_system(esm_file, top_level_name)
    if system === nothing
        throw(QualifiedReferenceError("Top-level system '$(top_level_name)' not found", reference, system_path[1:1]))
    end

    # Traverse subsystem hierarchy
    current_system = system
    traversed_path = [top_level_name]

    for segment in remaining_path
        push!(traversed_path, segment)
        current_system = find_subsystem(current_system, segment)
        if current_system === nothing
            throw(QualifiedReferenceError("Subsystem '$(segment)' not found in path", reference, traversed_path))
        end
    end

    # Validate that the variable exists in the final system
    if !variable_exists_in_system(current_system, variable_name)
        throw(QualifiedReferenceError("Variable '$(variable_name)' not found in system", reference, system_path))
    end

    return ReferenceResolution(variable_name, system_path, system_type, current_system)
end

"""
    find_top_level_system(esm_file::EsmFile, name::String) -> (Union{Model,ReactionSystem,DataLoader,Nothing}, Symbol)

Find a top-level system by name in models, reaction_systems, data_loaders, or operators.
Returns the system and its type, or (nothing, :none) if not found.
"""
function find_top_level_system(esm_file::EsmFile, name::String)
    # Check models
    if esm_file.models !== nothing && haskey(esm_file.models, name)
        return (esm_file.models[name], :model)
    end

    # Check reaction_systems
    if esm_file.reaction_systems !== nothing && haskey(esm_file.reaction_systems, name)
        return (esm_file.reaction_systems[name], :reaction_system)
    end

    # Check data_loaders
    if esm_file.data_loaders !== nothing && haskey(esm_file.data_loaders, name)
        return (esm_file.data_loaders[name], :data_loader)
    end

    return (nothing, :none)
end

"""
    find_subsystem(system::Union{Model,ReactionSystem}, name::String) -> Union{Model,ReactionSystem,DataLoader,Nothing}

Find a subsystem by name within a Model or ReactionSystem.
Returns the subsystem or nothing if not found.
"""
function find_subsystem(system::Model, name::String)::Union{Model,ReactionSystem,DataLoader,Nothing}
    # A Model's `subsystems` is a `Dict{String,Any}` and a subsystem may legitimately
    # be a DataLoader: that is exactly the loader+regridding-model split the
    # pure-io-data-loaders RFC prescribes, where the model declares the pure-I/O
    # loader as a subsystem (era5_single.esm's `sl`, geosfp.esm's `GEOSFP_I3`, …) and
    # couplings name its fields through the parent (`from: "GEOSFP.GEOSFP_I3.PS"`).
    # Annotating the return as `Union{Model,Nothing}` made that reference throw a
    # `MethodError: Cannot convert DataLoader to Model` from the conversion the
    # annotation itself forces — so `validate()` CRASHED on any assembly wiring a
    # loader field in through its data model (wildlandfire.esm included).
    #
    # Same defect as the one already fixed in `variable_exists_in_system(::DataLoader,
    # …)` below, which handles the top-level half (`from: "GEOSFP.u"`); this is the
    # subsystem-traversal half, which that fix missed.
    return get(system.subsystems, name, nothing)
end

function find_subsystem(system::ReactionSystem, name::String)::Union{ReactionSystem,Nothing}
    return get(system.subsystems, name, nothing)
end

function find_subsystem(system::DataLoader, name::String)
    # Data loaders don't have subsystems
    return nothing
end

"""
    variable_exists_in_system(system, variable_name::String) -> Bool

Check if a variable exists in the given system.
"""
function variable_exists_in_system(system::Model, variable_name::String)::Bool
    return haskey(system.variables, variable_name)
end

function variable_exists_in_system(system::ReactionSystem, variable_name::String)::Bool
    # Check species
    for species in system.species
        if species.name == variable_name
            return true
        end
    end

    # Check parameters
    for param in system.parameters
        if param.name == variable_name
            return true
        end
    end

    return false
end

function variable_exists_in_system(system::DataLoader, variable_name::String)::Bool
    # A DataLoader EXPOSES variables (`variables: {u: {file_variable: …}}`), and
    # `coupling` entries name them (`from: "GEOSFP.u"`). This used to return a
    # hardcoded `false` — "data loaders are referenced by type/name, not
    # variables" — which was true before the pure-io-data-loaders RFC gave the
    # loader a `variables` table, and afterwards made EVERY loader-sourced
    # coupling reference in the corpus fail to resolve (7 of the 82 valid
    # fixtures). Same defect as the Go binding's G7.
    return haskey(system.variables, variable_name)
end

"""
    validate_reference_syntax(reference::String) -> Bool

Validate that a reference string follows proper dot notation syntax.
"""
function validate_reference_syntax(reference::String)::Bool
    if isempty(reference)
        return false
    end

    # No leading or trailing dots
    if startswith(reference, ".") || endswith(reference, ".")
        return false
    end

    # No consecutive dots
    if occursin("..", reference)
        return false
    end

    # All segments should be valid identifiers
    segments = split(reference, ".")
    for segment in segments
        if isempty(segment) || !is_valid_identifier(String(segment))
            return false
        end
    end

    return true
end

"""
    is_valid_identifier(name::String) -> Bool

Check if a string is a valid identifier (letters, numbers, underscores, no leading digit).
"""
function is_valid_identifier(name::String)::Bool
    if isempty(name)
        return false
    end

    # Must start with letter or underscore. Iterate by character (not byte
    # index): `name[2:end]` byte-indexes and throws `StringIndexError` when the
    # identifier starts with a multi-byte (non-ASCII) letter.
    first_char = first(name)
    if !isletter(first_char) && first_char != '_'
        return false
    end

    # Rest can be letters, digits, or underscores
    for c in Iterators.drop(name, 1)
        if !isletter(c) && !isdigit(c) && c != '_'
            return false
        end
    end

    return true
end

# ========================================
# 9. Backward Compatibility Helpers
# ========================================

"""
    dict_to_stoichiometry_entries(dict::AbstractDict{String,<:Real}) -> Vector{StoichiometryEntry}

Convert old-style species→coefficient dict format to new StoichiometryEntry vector format.
Accepts any numeric coefficient type (`Int`, `Float64`, …) — fractional stoichiometries
are supported by the v0.2.x schema.
"""
function dict_to_stoichiometry_entries(dict::AbstractDict{String,<:Real})::Vector{StoichiometryEntry}
    return [StoichiometryEntry(species, stoichiometry) for (species, stoichiometry) in dict]
end

"""
    stoichiometry_entries_to_dict(entries::Vector{StoichiometryEntry}) -> Dict{String,Float64}

Convert new StoichiometryEntry vector format to species→coefficient dict.
"""
function stoichiometry_entries_to_dict(entries::Vector{StoichiometryEntry})::Dict{String,Float64}
    return Dict(entry.species => entry.stoichiometry for entry in entries)
end

# Deterministic 64-bit FNV-1a hash. Used for content-derived ids; unlike
# `Base.hash`, its value is stable across Julia versions and sessions.
function _fnv1a64(s::AbstractString)::UInt64
    h = 0xcbf29ce484222325
    for b in codeunits(s)
        h = (h ⊻ UInt64(b)) * 0x00000100000001b3
    end
    return h
end

# Render a JSON-compatible value (as produced by `serialize_expression`) to a
# deterministic string: object keys are emitted in sorted order, so the result
# depends only on content, never on Dict iteration order.
_stable_json(x::AbstractDict) =
    "{" * join(sort!([string(repr(String(string(k))), ":", _stable_json(v))
                      for (k, v) in pairs(x)]), ",") * "}"
_stable_json(x::AbstractVector) = "[" * join([_stable_json(v) for v in x], ",") * "]"
_stable_json(x::AbstractString) = repr(String(x))
_stable_json(x) = string(x)

"""
    Reaction(reactants::AbstractDict{String,<:Real}, products::AbstractDict{String,<:Real}, rate::ASTExpr; reversible=false) -> Reaction

Legacy constructor for backward compatibility. Creates a reaction with an
auto-generated, content-derived id: the same reactants, products, and rate
always produce the same id (deterministic across sessions and Julia versions,
unlike `Base.hash`).
"""
function Reaction(reactants::AbstractDict{String,<:Real}, products::AbstractDict{String,<:Real}, rate::ASTExpr; reversible=false)
    # Content-derived id: sorted species:stoichiometry lists plus a
    # deterministic rendering of the rate AST, digested with FNV-1a.
    fmt(d) = join(sort!(["$(k):$(Float64(v))" for (k, v) in d]), ",")
    content = fmt(reactants) * "=>" * fmt(products) * "|" *
              _stable_json(serialize_expression(rate))
    id = "reaction_" * string(_fnv1a64(content), base=16, pad=16)

    substrates = isempty(reactants) ? nothing : dict_to_stoichiometry_entries(reactants)
    products_vec = isempty(products) ? nothing : dict_to_stoichiometry_entries(products)

    return Reaction(id, substrates, products_vec, rate)
end

"""
    get_reactants_dict(reaction::Reaction) -> Dict{String,Float64}

Get reactants as dictionary for backward compatibility.
"""
function get_reactants_dict(reaction::Reaction)::Dict{String,Float64}
    # Ordered field via `raw_substrates`, collapsed to the unordered Dict view.
    substrates_field = raw_substrates(reaction)
    if substrates_field === nothing
        return Dict{String,Float64}()
    else
        return stoichiometry_entries_to_dict(substrates_field)
    end
end

"""
    get_products_dict(reaction::Reaction) -> Dict{String,Float64}

Get products as dictionary for backward compatibility.
"""
function get_products_dict(reaction::Reaction)::Dict{String,Float64}
    # Ordered field via `raw_products`, collapsed to the unordered Dict view.
    products_field = raw_products(reaction)
    if products_field === nothing
        return Dict{String,Float64}()
    else
        return stoichiometry_entries_to_dict(products_field)
    end
end

"""
    raw_substrates(r::Reaction) -> Union{Vector{StoichiometryEntry},Nothing}
    raw_products(r::Reaction)  -> Union{Vector{StoichiometryEntry},Nothing}

The `substrates` / `products` fields as stored: the ORDERED
`Vector{StoichiometryEntry}` (or `nothing` for a source/sink reaction, ∅ → X /
X → ∅). Named accessors for the raw fields so ordered author-entry access reads
the same at every call site (equivalent to `r.substrates` / `r.products` now
that the `getproperty` shim is gone). For the unordered `Dict{String,Float64}`
species→coefficient view, use [`get_reactants_dict`](@ref) /
[`get_products_dict`](@ref).
"""
raw_substrates(r::Reaction) = getfield(r, :substrates)
raw_products(r::Reaction) = getfield(r, :products)

# NOTE: `Reaction` has no `getproperty` override — plain `r.substrates` /
# `r.products` reach the stored ORDERED `Vector{StoichiometryEntry}` fields
# directly. Use `raw_substrates` / `raw_products` for that ordered view and
# `get_reactants_dict` / `get_products_dict` for the unordered
# `Dict{String,Float64}` species→coefficient view. (A legacy shim that mapped
# `.reactants` / `.products` to the Dict view, and `.reversible` to `false`,
# was removed.)

# NOTE: `Model` has no `getproperty` override — the legacy `model.events`
# combined-vector shim was removed; use `model.discrete_events` /
# `model.continuous_events` directly.
# ========================================
# 15. Record wire-mapping tables
# ========================================

"""
    RECORD_FIELD_TABLES

The per-type field-spec tables for the REGULAR record types — the single
source of truth from which BOTH wire directions are generated
(`coerce_<fn>` in parse.jl, `serialize_<fn>` in serialize.jl), following the
[`OPEXPR_FIELD_TABLE`](@ref) precedent. One entry per type:

- `T`: the struct's name (a `Symbol`; resolved in this module).
- `fn`: the coercer/serializer name suffix (`coerce_<fn>` / `serialize_<fn>`).
- `tag`: for a coupling-entry type, the `"type"` discriminator string the
  serializer emits first (`nothing`/absent otherwise; the parse side never
  reads it — `coerce_coupling_entry` dispatches on it before calling in).
- `injected`: `true` when the record's `name` is the KEY of an enclosing
  name-keyed map, injected as the coercer's first argument and never
  read from or emitted to the record's own wire body (Species, Parameter).
- `rows`: one row per struct field, in HISTORICAL PARSE ORDER (which pins
  ParseError precedence on multiply-invalid nodes; emission follows the same
  order — JSON object equality, the round-trip contract, is key-order
  agnostic). Row columns:
    - `f`: struct field name == constructor keyword name.
    - `wire`: the JSON key (renames live here: `stop` ↔ `"end"`).
    - `kind`: the value class, naming the coercion/encoding pair —
      `:string` (`string(v)`/identity), `:string_strict` (`String(v)`),
      `:float`, `:int`, `:bool`, `:number_or_string`, `:number_or_expr`,
      `:expr`, `:expr_vec`, `:string_vec` (`string.()` each),
      `:string_vec_strict` (`Vector{String}(v)`), `:float_map`,
      `:str_keyed_copy` (string-keyed shallow `Dict{String,Any}` copy),
      `:raw` (`_to_native_json` verbatim passthrough), `:raw_vec`,
      `:model_variable_type`, `:record`/`:record_vec`/`:record_map`
      (nested `coerce_<of>`/`serialize_<of>`; `T` names the element type),
      `:custom` (`parse_fn` on the fetched value; `emit_fn` on the struct).
    - `mode`: parse-side fetch policy — `:req` (`data[wire]`, KeyError when
      missing, exactly as the historical direct index), `:req_err`
      (`_has_field` guard throwing the PINNED `req_err` message; a JSON
      `null` value then flows to the converter — or to `default` when the
      row has one — matching each historical site), `:req_nullerr`
      (null-or-absent throws `req_err`), `:opt` (absent/null → `nothing`),
      `:opt_empty` (absent/null → `default`), `:default` (absent/null →
      `default`, present → converted), `:force` (fetch null-as-absent and
      convert unconditionally, so the converter's own error surfaces).
    - `emit`: serialize-side omission policy — `:always`, `:nonnothing`,
      `:nonempty`, `:nondefault` (against `default`), `:custom`
      (`emit_fn(x)`, `nothing` skips the key), `:never`.
    - `pos`: `true` for the constructor's positional arguments (in row
      order); all other rows pass as keywords.

The IRREGULAR residue deliberately stays hand-written and is NOT here:
discriminated-union sniffing (`coerce_coupling_entry`, `coerce_trigger` /
`serialize_trigger`, `_coerce_subsystem_entry` / `_serialize_subsystem`),
name-keyed-map↔vector conversions with injected names (`ReactionSystem`),
`Reaction` (null-vs-absent substrates/products + `_emit_stoich`),
`CouplingVariableMap` (transform union + constructor-error rebranding),
`FunctionTable`/`FunctionTableAxis` and `coerce_enums`/
`coerce_function_tables` (table-name-context-threaded ParseError messages),
and the `EsmFile` orchestrator.

A load-time assert (below) pins each entry's rows to `fieldnames(T)` exactly;
`round_trip_regression_test.jl` / `conformance_round_trip_test.jl` pin the
wire behavior.
"""
const RECORD_FIELD_TABLES = (
    (T = :Reference, fn = :reference, rows = (
        (f = :doi,      wire = "doi",      kind = :string, mode = :opt, emit = :nonnothing),
        (f = :citation, wire = "citation", kind = :string, mode = :opt, emit = :nonnothing),
        (f = :url,      wire = "url",      kind = :string, mode = :opt, emit = :nonnothing),
        (f = :notes,    wire = "notes",    kind = :string, mode = :opt, emit = :nonnothing),
    )),
    (T = :Metadata, fn = :metadata, rows = (
        (f = :name,        wire = "name",        kind = :string, mode = :req, emit = :always, pos = true),
        (f = :description, wire = "description", kind = :string, mode = :opt, emit = :nonnothing),
        (f = :authors,     wire = "authors",     kind = :string_vec, mode = :opt_empty, default = :(String[]), emit = :nonempty),
        (f = :license,     wire = "license",     kind = :string, mode = :opt, emit = :nonnothing),
        (f = :created,     wire = "created",     kind = :string, mode = :opt, emit = :nonnothing),
        (f = :modified,    wire = "modified",    kind = :string, mode = :opt, emit = :nonnothing),
        (f = :tags,        wire = "tags",        kind = :string_vec, mode = :opt_empty, default = :(String[]), emit = :nonempty),
        (f = :references,  wire = "references",  kind = :record_vec, of = :reference, eltype = :Reference,
         mode = :opt_empty, default = :(Reference[]), emit = :nonempty),
    )),
    (T = :Tolerance, fn = :tolerance, rows = (
        (f = :abs, wire = "abs", kind = :float, mode = :opt, emit = :nonnothing),
        (f = :rel, wire = "rel", kind = :float, mode = :opt, emit = :nonnothing),
    )),
    (T = :TimeSpan, fn = :time_span, rows = (
        (f = :start, wire = "start", kind = :float, mode = :req, emit = :always, pos = true),
        (f = :stop,  wire = "end",   kind = :float, mode = :req, emit = :always, pos = true),
    )),
    (T = :Species, fn = :species, injected = true, rows = (
        (f = :units,         wire = "units",         kind = :string, mode = :opt, emit = :nonnothing),
        (f = :default,       wire = "default",       kind = :float,  mode = :opt, emit = :nonnothing),
        (f = :description,   wire = "description",   kind = :string, mode = :opt, emit = :nonnothing),
        (f = :default_units, wire = "default_units", kind = :string, mode = :opt, emit = :nonnothing),
        (f = :constant,      wire = "constant",      kind = :bool,   mode = :opt, emit = :nonnothing),
    )),
    (T = :Parameter, fn = :parameter, injected = true, rows = (
        (f = :default,       wire = "default",       kind = :float,  mode = :req, emit = :nonnothing, pos = true),
        (f = :description,   wire = "description",   kind = :string, mode = :opt, emit = :nonnothing),
        (f = :units,         wire = "units",         kind = :string, mode = :opt, emit = :nonnothing),
        (f = :default_units, wire = "default_units", kind = :string, mode = :opt, emit = :nonnothing),
    )),
    (T = :Equation, fn = :equation, rows = (
        (f = :lhs,      wire = "lhs",      kind = :expr,   mode = :req, emit = :always, pos = true),
        (f = :rhs,      wire = "rhs",      kind = :expr,   mode = :req, emit = :always, pos = true),
        (f = :_comment, wire = "_comment", kind = :string, mode = :opt, emit = :nonnothing),
    )),
    (T = :AffectEquation, fn = :affect_equation, rows = (
        (f = :lhs, wire = "lhs", kind = :string, mode = :default, default = "", emit = :always, pos = true),
        (f = :rhs, wire = "rhs", kind = :expr,   mode = :force,   emit = :always, pos = true),
    )),
    (T = :Domain, fn = :domain, rows = (
        (f = :independent_variable, wire = "independent_variable", kind = :string,
         mode = :default, default = "t", emit = :nondefault),
        (f = :temporal, wire = "temporal", kind = :str_keyed_copy, mode = :opt, emit = :nonnothing),
    )),
    (T = :DataLoaderSource, fn = :data_loader_source, rows = (
        (f = :url_template, wire = "url_template", kind = :string, mode = :req, emit = :always, pos = true),
        (f = :mirrors,      wire = "mirrors",      kind = :string_vec, mode = :opt, emit = :nonnothing),
    )),
    (T = :DataLoaderTemporal, fn = :data_loader_temporal, rows = (
        (f = :start,            wire = "start",            kind = :string, mode = :opt, emit = :nonnothing),
        (f = :stop,             wire = "end",              kind = :string, mode = :opt, emit = :nonnothing),
        (f = :file_period,      wire = "file_period",      kind = :string, mode = :opt, emit = :nonnothing),
        (f = :frequency,        wire = "frequency",        kind = :string, mode = :opt, emit = :nonnothing),
        (f = :records_per_file, wire = "records_per_file", kind = :number_or_string, mode = :opt, emit = :nonnothing),
        (f = :time_variable,    wire = "time_variable",    kind = :string, mode = :opt, emit = :nonnothing),
    )),
    (T = :DataLoaderVariable, fn = :data_loader_variable, rows = (
        (f = :file_variable,   wire = "file_variable",   kind = :string, mode = :req, emit = :always, pos = true),
        (f = :units,           wire = "units",           kind = :string, mode = :req, emit = :always, pos = true),
        (f = :unit_conversion, wire = "unit_conversion", kind = :number_or_expr, mode = :opt, emit = :nonnothing),
        (f = :description,     wire = "description",     kind = :string, mode = :opt, emit = :nonnothing),
        (f = :reference,       wire = "reference",       kind = :record, of = :reference, mode = :opt, emit = :nonnothing),
    )),
    (T = :DataLoaderDeterminism, fn = :data_loader_determinism, rows = (
        (f = :endian,        wire = "endian",        kind = :string, mode = :opt, emit = :nonnothing),
        (f = :float_format,  wire = "float_format",  kind = :string, mode = :opt, emit = :nonnothing),
        (f = :integer_width, wire = "integer_width", kind = :int,    mode = :opt, emit = :nonnothing),
    )),
    (T = :DataLoader, fn = :data_loader, rows = (
        (f = :kind,   wire = "kind",   kind = :string, mode = :req, emit = :always, pos = true),
        (f = :source, wire = "source", kind = :record, of = :data_loader_source, mode = :req, emit = :always, pos = true),
        (f = :temporal,    wire = "temporal",    kind = :record, of = :data_loader_temporal, mode = :opt, emit = :nonnothing),
        # Emit-side residue AS A COLUMN: determinism is emitted only when
        # present AND its serialized dict is non-empty (the historical
        # `isempty(det_dict) ||` guard) — a cross-field-free but
        # doubly-conditional policy, so it names a hand-written hook.
        (f = :determinism, wire = "determinism", kind = :record, of = :data_loader_determinism, mode = :opt,
         emit = :custom, emit_fn = :_emit_data_loader_determinism),
        (f = :variables, wire = "variables", kind = :record_map, of = :data_loader_variable,
         eltype = :DataLoaderVariable, mode = :req, emit = :always, pos = true),
        (f = :reference, wire = "reference", kind = :record, of = :reference, mode = :opt, emit = :nonnothing),
        (f = :metadata,  wire = "metadata",  kind = :raw, mode = :opt, emit = :nonnothing),
    )),
    (T = :CouplingImport, fn = :coupling_import, tag = "coupling_import", rows = (
        (f = :ref, wire = "ref", kind = :string_strict, mode = :req_err,
         req_err = "coupling_import requires 'ref' field", emit = :always, pos = true),
        (f = :bind, wire = "bind", kind = :custom, parse_fn = :_coerce_coupling_import_bind,
         mode = :opt_empty, default = :(Dict{String,String}()),
         emit = :custom, emit_fn = :_emit_coupling_import_bind, pos = true),
        (f = :description, wire = "description", kind = :string, mode = :opt, emit = :nonnothing),
    )),
    (T = :CouplingOperatorCompose, fn = :operator_compose, tag = "operator_compose", rows = (
        (f = :systems, wire = "systems", kind = :string_vec_strict, mode = :req_err,
         req_err = "operator_compose requires 'systems' field", emit = :always, pos = true),
        (f = :translate,   wire = "translate",   kind = :str_keyed_copy, mode = :opt, emit = :nonnothing),
        (f = :description, wire = "description", kind = :string, mode = :opt, emit = :nonnothing),
        (f = :lifting,     wire = "lifting",     kind = :string, mode = :opt, emit = :nonnothing),
    )),
    (T = :CouplingCouple, fn = :couple, tag = "couple", rows = (
        (f = :systems, wire = "systems", kind = :string_vec_strict, mode = :req_err,
         req_err = "couple requires 'systems' field", emit = :always, pos = true),
        (f = :connector, wire = "connector", kind = :str_keyed_copy, mode = :req_err,
         req_err = "couple requires 'connector' field", emit = :always, pos = true),
        (f = :description, wire = "description", kind = :string, mode = :opt, emit = :nonnothing),
        (f = :lifting,     wire = "lifting",     kind = :string, mode = :opt, emit = :nonnothing),
    )),
    (T = :CouplingOperatorApply, fn = :operator_apply, tag = "operator_apply", rows = (
        (f = :operator, wire = "operator", kind = :string_strict, mode = :req_err,
         req_err = "operator_apply requires 'operator' field", emit = :always, pos = true),
        (f = :description, wire = "description", kind = :string, mode = :opt, emit = :nonnothing),
    )),
    (T = :CouplingCallback, fn = :callback, tag = "callback", rows = (
        (f = :callback_id, wire = "callback_id", kind = :string_strict, mode = :req_err,
         req_err = "callback requires 'callback_id' field", emit = :always, pos = true),
        (f = :config,      wire = "config",      kind = :str_keyed_copy, mode = :opt, emit = :nonnothing),
        (f = :description, wire = "description", kind = :string, mode = :opt, emit = :nonnothing),
    )),
    (T = :CouplingEvent, fn = :coupling_event, tag = "event", rows = (
        (f = :event_type, wire = "event_type", kind = :string_strict, mode = :req_err,
         req_err = "event requires 'event_type' field", emit = :always, pos = true),
        (f = :conditions, wire = "conditions", kind = :expr_vec, mode = :opt, emit = :nonnothing),
        (f = :trigger,    wire = "trigger",    kind = :record, of = :trigger, mode = :opt, emit = :nonnothing),
        (f = :affects, wire = "affects", kind = :record_vec, of = :affect_equation,
         eltype = :AffectEquation, mode = :req_err,
         req_err = "event requires 'affects' field", emit = :always, pos = true),
        (f = :affect_neg, wire = "affect_neg", kind = :record_vec, of = :affect_equation,
         eltype = :AffectEquation, mode = :opt, emit = :nonnothing),
        (f = :discrete_parameters, wire = "discrete_parameters", kind = :string_vec_strict,
         mode = :opt, emit = :nonnothing),
        (f = :root_find,    wire = "root_find",    kind = :string, mode = :opt, emit = :nonnothing),
        (f = :reinitialize, wire = "reinitialize", kind = :bool,   mode = :opt, emit = :nonnothing),
        (f = :description,  wire = "description",  kind = :string, mode = :opt, emit = :nonnothing),
    )),
    (T = :IndexSet, fn = :index_set, rows = (
        (f = :kind, wire = "kind", kind = :string, mode = :req_nullerr,
         req_err = "index_sets entry requires a `kind` field", emit = :always, pos = true),
        (f = :size, wire = "size", kind = :int, mode = :opt, emit = :nonnothing),
        # ONE wire key, TWO struct fields (the §5.3 representation policy):
        # `members` is the stringified convenience view; `members_raw` retains
        # the originally-typed values only when some member is non-string, and
        # is what round-trips back to the wire `members` key when present.
        (f = :members, wire = "members", kind = :custom, parse_fn = :_coerce_index_set_members,
         mode = :opt, emit = :custom, emit_fn = :_emit_index_set_members),
        (f = :members_raw, wire = "members", kind = :custom,
         parse_fn = :_coerce_index_set_members_raw, mode = :opt, emit = :never),
        (f = :of,       wire = "of",       kind = :string_vec, mode = :opt, emit = :nonnothing),
        (f = :offsets,  wire = "offsets",  kind = :string, mode = :opt, emit = :nonnothing),
        (f = :values,   wire = "values",   kind = :string, mode = :opt, emit = :nonnothing),
        (f = :from_faq, wire = "from_faq", kind = :string, mode = :opt, emit = :nonnothing),
    )),
    (T = :ModelVariable, fn = :model_variable, rows = (
        (f = :type, wire = "type", kind = :model_variable_type, mode = :req, emit = :always, pos = true),
        (f = :default,       wire = "default",       kind = :float,  mode = :opt, emit = :nonnothing),
        (f = :description,   wire = "description",   kind = :string, mode = :opt, emit = :nonnothing),
        (f = :expression,    wire = "expression",    kind = :expr,   mode = :opt, emit = :nonnothing),
        (f = :units,         wire = "units",         kind = :string, mode = :opt, emit = :nonnothing),
        (f = :default_units, wire = "default_units", kind = :string, mode = :opt, emit = :nonnothing),
        (f = :shape,         wire = "shape",         kind = :string_vec, mode = :opt, emit = :nonnothing),
        (f = :location,      wire = "location",      kind = :string, mode = :opt, emit = :nonnothing),
        (f = :noise_kind,    wire = "noise_kind",    kind = :string, mode = :opt, emit = :nonnothing),
        (f = :correlation_group, wire = "correlation_group", kind = :string, mode = :opt, emit = :nonnothing),
    )),
    (T = :ContinuousEvent, fn = :continuous_event, rows = (
        (f = :conditions, wire = "conditions", kind = :expr_vec, mode = :req_err,
         req_err = "ContinuousEvent requires 'conditions' field", default = :(ASTExpr[]),
         emit = :always, pos = true),
        (f = :affects, wire = "affects", kind = :record_vec, of = :affect_equation,
         eltype = :AffectEquation, mode = :opt_empty, default = :(AffectEquation[]),
         emit = :always, pos = true),
        (f = :description, wire = "description", kind = :string, mode = :opt, emit = :nonnothing),
    )),
    (T = :DiscreteEvent, fn = :discrete_event, rows = (
        (f = :trigger, wire = "trigger", kind = :record, of = :trigger, mode = :req_err,
         req_err = "DiscreteEvent requires 'trigger' field", emit = :always, pos = true),
        # `affects` / `functional_affect` are the schema's oneOf pair: parse
        # accepts either (per-entry lhs/rhs presence pinned by the affects
        # hook); emit writes exactly one — the affects hook yields to a
        # present descriptor, whose own hook re-emits it verbatim and refuses
        # an event carrying both (the historical ArgumentError).
        (f = :affects, wire = "affects", kind = :custom, parse_fn = :_coerce_discrete_affects,
         mode = :opt_empty, default = :(AffectEquation[]),
         emit = :custom, emit_fn = :_emit_discrete_event_affects, pos = true),
        (f = :functional_affect, wire = "functional_affect", kind = :raw, mode = :opt,
         emit = :custom, emit_fn = :_emit_discrete_event_functional_affect),
        (f = :description, wire = "description", kind = :string, mode = :opt, emit = :nonnothing),
        (f = :discrete_parameters, wire = "discrete_parameters", kind = :string_vec_strict,
         mode = :opt, emit = :nonnothing),
    )),
    (T = :Assertion, fn = :assertion, rows = (
        (f = :variable, wire = "variable", kind = :string, mode = :req, emit = :always, pos = true),
        (f = :time,     wire = "time",     kind = :float,  mode = :req, emit = :always, pos = true),
        (f = :expected, wire = "expected", kind = :float,  mode = :req, emit = :always, pos = true),
        (f = :tolerance, wire = "tolerance", kind = :record, of = :tolerance, mode = :opt, emit = :nonnothing),
        (f = :coords,    wire = "coords",    kind = :float_map, mode = :opt, emit = :nonnothing),
        (f = :reduce,    wire = "reduce",    kind = :string, mode = :opt, emit = :nonnothing),
        # from_file-vs-Expression discriminated union (spec §6.6.5): the
        # `type` field — not dict-ness — routes to the verbatim from_file
        # shape; anything else parses as an Expression AST.
        (f = :reference, wire = "reference", kind = :custom, parse_fn = :_coerce_assertion_reference,
         mode = :opt, emit = :custom, emit_fn = :_emit_assertion_reference),
    )),
    (T = :InlineTest, fn = :test, rows = (
        (f = :id,        wire = "id",        kind = :string, mode = :req, emit = :always, pos = true),
        (f = :time_span, wire = "time_span", kind = :record, of = :time_span, mode = :req,
         emit = :always, pos = true),
        (f = :assertions, wire = "assertions", kind = :record_vec, of = :assertion,
         eltype = :Assertion, mode = :req, emit = :always, pos = true),
        (f = :description, wire = "description", kind = :string, mode = :opt, emit = :nonnothing),
        (f = :initial_conditions, wire = "initial_conditions", kind = :float_map,
         mode = :opt_empty, default = :(Dict{String,Float64}()), emit = :nonempty),
        (f = :parameter_overrides, wire = "parameter_overrides", kind = :float_map,
         mode = :opt_empty, default = :(Dict{String,Float64}()), emit = :nonempty),
        (f = :tolerance, wire = "tolerance", kind = :record, of = :tolerance, mode = :opt, emit = :nonnothing),
        # esm-spec §9.7.10 form C: a test's injected imports are authored
        # per-run config and DO survive parse → emit (unlike a component's
        # own imports, which the load-time fixpoint consumes).
        (f = :expression_template_imports, wire = "expression_template_imports", kind = :raw_vec,
         mode = :opt_empty, default = :(Any[]), emit = :nonempty),
    )),
)

# Each entry's rows (plus the injected map-key name, when marked) must cover
# EXACTLY the struct's fields — a new field without a row fails at load, the
# same guarantee `OPEXPR_FIELD_TABLE` gives `OpExpr`.
for spec in RECORD_FIELD_TABLES
    T = getfield(@__MODULE__, spec.T)
    covered = Set{Symbol}(row.f for row in spec.rows)
    get(spec, :injected, false) && push!(covered, :name)
    @assert covered == Set(fieldnames(T)) "RECORD_FIELD_TABLES.$(spec.T) rows must cover fieldnames($(spec.T)) exactly"
end
