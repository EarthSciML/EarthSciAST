using OrderedCollections: OrderedDict

"""
Type definitions for EarthSciML Abstract Syntax Tree Format.

This module defines the complete type hierarchy for the ESM format,
matching the JSON schema definitions for language-agnostic model interchange.
"""

# Apply `f` to `x`, propagating `nothing` (the standard absent-optional-field
# guard: `_maybe(string, get(data, key, nothing))`).
_maybe(f, x) = x === nothing ? nothing : f(x)

# `f(args...)` through a dynamic call, which leaves the caller no backedge into
# `f` for a later-loaded package's methods to invalidate. Assert the result type.
_dynamic(f::F, args...) where {F} = Base.inferencebarrier(f)(args...)
_as_type(::Type{T}, x::T) where {T} = x
_as_type(::Type{T}, x) where {T} = _dynamic(convert, T, x)::T

# Defines `_new_typed(T, fields...)`, `new` with each field through `_as_type`: a
# constructor inferred with `Any` arguments then keeps no backedge into `convert`.
function _def_new_typed(T::DataType)
    xs = [Symbol(:x, i) for i in 1:fieldcount(T)]
    new = Expr(:new, T, (:(_as_type($(fieldtype(T, i)), $(xs[i]))) for i in eachindex(xs))...)
    return @eval _new_typed(::Type{$T}, $(xs...)) = $new
end

# `any(f, xs)` / `all(f, xs)` as loops: Base's are inferred through `mapreduce`
# code that later-loaded array types invalidate.
function _anyof(f::F, xs) where {F}
    for x in xs
        f(x) && return true
    end
    return false
end
function _allof(f::F, xs) where {F}
    for x in xs
        f(x) || return false
    end
    return true
end

"""
    _as_int64(x::Real) -> Union{Int64, Nothing}

The exact `Int64` value of `x` when `x` is integral and in `Int64` range, else
`nothing`: CONFORMANCE_SPEC §5.5.3.1 rule 1, "an integral JSON number in
`Int64` range is an integer, however it was spelled". `-0.0` is the integer
`0`. A `Bool` is an `Integer` here; a caller that refuses booleans screens
them first.
"""
_as_int64(x::Int64) = x
_as_int64(x::Integer) = typemin(Int64) <= x <= typemax(Int64) ? Int64(x) : nothing
_as_int64(x::AbstractFloat) = isinteger(x) && -0x1p63 <= x < 0x1p63 ? Int64(x) : nothing
_as_int64(x::Real) = _as_int64(Float64(x))

"""
    SCHEMA_VERSION

The `.esm` FORMAT version (semver string) this implementation targets — the
value written into the `esm` field of freshly constructed files. Files loaded
from disk keep whatever version they declare; this constant is only the default
for documents the library itself creates (flatten wrappers, MTK/Catalyst
export). Must track the version on the first line of `esm-spec.md` and in the
bundled schema's `\$id`, which the `SCHEMA_VERSION tracks the bundled schema`
test enforces. NOT the version of this PACKAGE — that is
[`LIBRARY_VERSION`](@ref).
"""
const SCHEMA_VERSION = "2.4.0"

"""
    LIBRARY_VERSION

This package's OWN version, read from its `Project.toml` — NOT the `.esm`
format version, which is [`SCHEMA_VERSION`](@ref). The two are unrelated
numbers.
"""
const LIBRARY_VERSION = string(pkgversion(@__MODULE__))
# The constant is fixed when the package precompiles, and Julia decides whether
# a cache is stale from the files the package includes, which Project.toml is
# not. Without this, a cache built before a version bump survives it: CI
# restored a 0.3.0 depot for the 0.3.1 release and LIBRARY_VERSION said 0.3.0.
include_dependency(joinpath(dirname(@__DIR__), "Project.toml"))

# ========================================
# 1. Expression Type Hierarchy
# ========================================

# NAMING: this abstract type is spelled `ASTExpr` (not `Expr`) specifically so
# it does NOT shadow `Core.Expr` (Julia's own AST node type) inside this module
# or for consumers that `using EarthSciAST`. Module-internal code that builds
# Julia AST still writes `Core.Expr` explicitly (see codegen.jl and the package
# extensions), and struct fields that would naturally be called `expr` use
# `expr_body`-style names (e.g. `OpExpr.expr_body` for the wire key "expr") to
# keep the ESM and Julia AST vocabularies distinct.
"""
    abstract type ASTExpr end

Abstract base type for all mathematical expressions in the ESM format.
Expressions can be numeric literals, variable references, or operator nodes.
"""
abstract type ASTExpr end

"""
    NumExpr(value::Float64)

Floating-point numeric literal expression. Represents a JSON number whose
mathematical value is **non-integral** (or integral but not `Int64`-
representable): literal type is decided by *value*, not by the token's source
spelling (CONFORMANCE_SPEC §5.5.3.1 rules 1/3). A JSON number whose value is
integral and `Int64`-representable — however it was spelled (`1`, `1.0`,
`2.5e1`) — parses as an `IntExpr`, so `expression_from_json` never produces
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

# The broad-phase candidate set of an OVERLAP join gate (§5.5.6), together with
# the DERIVED views the candidate-driven enumerator reads. Defined HERE — ahead
# of `_JoinGate` — so both resolved gate types can name it; the views are built
# in broad_phase.jl and consumed by BOTH enumeration paths.
#
#   * `pairs`  — the raw `(pos_src, pos_tgt)` membership set (the `in` test);
#   * `sorted` — the same pairs ascending, the PAIR drive order;
#   * `adj_l` / `adj_r` — one side's position ⇒ its SORTED partner positions on
#     the other side, the drive order used when the aggregate has already bound
#     one gated axis (a per-output-cell dense aggregate).
#
# The derived views are built LAZILY and cached on the gate. A gate is resolved
# ONCE per node but consulted once per output cell, so rebuilding an adjacency
# per cell would reinstate exactly the O(N_tgt·N_src) cost the driver removes.
mutable struct _OverlapIndex
    pairs::Set{Tuple{Int, Int}}
    sorted::Union{Vector{Tuple{Int, Int}}, Nothing}
    adj_l::Union{Dict{Int, Vector{Int}}, Nothing}
    adj_r::Union{Dict{Int, Vector{Int}}, Nothing}
end
_OverlapIndex(pairs::Set{Tuple{Int, Int}}) = _OverlapIndex(pairs, nothing, nothing, nothing)
# Membership / cardinality forward to the raw pair set, so an `_OverlapIndex`
# reads exactly like the `Set` it wraps at every existing use site. `in` is
# deliberately UNTYPED in its first argument: `_vi_join_ok` builds its probe from
# a `Dict{String,Any}` binding, so a categorical range would hand it a
# non-`Tuple{Int,Int}`. A `Set` answers `false` for such a probe; a narrowly
# typed method would raise `MethodError` instead, turning a rejected binding into
# a crash.
Base.in(p, oi::_OverlapIndex) = in(p, oi.pairs)
Base.length(oi::_OverlapIndex) = length(oi.pairs)
Base.isempty(oi::_OverlapIndex) = isempty(oi.pairs)

# One resolved key-column pair of an aggregate `join` (RFC §5.3): the two range
# symbols and, for each, a map from a range position (the loop-variable value)
# to its bucket code. A bin-EQUALITY combination is admitted iff
# `codes_l[pos_l] == codes_r[pos_r]` for every gate. Defined HERE — ahead of
# `OpExpr` — so the internal `OpExpr.join_gates` field can name this concrete
# element type; it is BUILT and CONSUMED in tree_walk/join_gates.jl
# (`_resolve_join_gates_for` / `_join_admits`), never parsed or serialized.
#
# The two fields answer two DIFFERENT questions, and a gate may carry both.
#
# `codes_l`/`codes_r` are ADMISSION: a value-equality (`on`) gate admits iff
# `codes_l[pos_l] == codes_r[pos_r]`. They are empty for an OVERLAP gate, whose
# admission is envelope candidacy rather than key equality.
#
# `candidates` is the prebuilt `(pos_l, pos_r)` index, and it is an ENUMERATION
# EXTENT: the gate that carries one can DRIVE enumeration instead of being
# tested per tuple (`_overlap_drive_plan` / `_drivable_gate`, broad_phase.jl).
# An OVERLAP gate's index is the broad-phase candidate set
# (`_overlap_candidate_set`), and for it the index IS also the admission test.
# An `on` gate's index is the §5.5.8 match set (`_on_gate_match_pairs`), and
# there it is purely an extent — `_join_admits` still tests the codes, so the
# driven walk is re-checked against the same predicate the full product applies.
# `nothing` means the gate materialised no index and filters only.
struct _JoinGate
    sym_l::String
    sym_r::String
    codes_l::Dict{Int, Int}
    codes_r::Dict{Int, Int}
    candidates::Union{_OverlapIndex, Nothing}
end
# Bin-equality gate convenience ctor (candidates ≡ nothing).
_JoinGate(sym_l, sym_r, codes_l, codes_r) = _JoinGate(sym_l, sym_r, codes_l, codes_r, nothing)

# A parsed value-equality (`on`) join clause: the `[left, right]` key-column
# pairs, plus the OPTIONAL `syms` naming the two range symbols those pairs are
# read at (CONFORMANCE_SPEC §5.5.8 "Two ranges over one index set").
#
# `syms` exists for the one thing a pair of column names cannot say. A key column
# resolves to a loop symbol through its declared AXIS, which is unique for a join
# between two distinct relations; when a node draws ONE index set with SEVERAL of
# its ranges — a relation joined to ITSELF — the axis names two or more candidate
# symbols and the pair alone does not say which side is which. Absent ⇒ the
# DEFAULT side assignment (`_join_sym_for_key`): with exactly two candidates the
# left key reads at the earlier in canonical range order and the right at the
# later; three or more is refused.
#
# It is an `AbstractVector` of the pairs, so every consumer that iterates or
# indexes a clause — `_resolve_join_gates_for`, `value_invention`, `serialize`,
# `display` — sees exactly the pair list it always saw, and only the code that
# needs `syms` mentions it.
struct _OnJoinSpec <: AbstractVector{Tuple{String, String}}
    pairs::Vector{Tuple{String, String}}
    syms::Union{Nothing, Tuple{String, String}}
end
_OnJoinSpec(pairs) = _OnJoinSpec(pairs, nothing)
Base.size(c::_OnJoinSpec) = size(c.pairs)
Base.getindex(c::_OnJoinSpec, i::Int) = c.pairs[i]
Base.IndexStyle(::Type{_OnJoinSpec}) = IndexLinear()

# The `syms` of a clause, or `nothing` for a clause that carries none — including
# a bare pair vector, which older callers and hand-built trees still construct.
_clause_syms(c::_OnJoinSpec) = c.syms
_clause_syms(::Any) = nothing

# `c` with the same `syms` but `pairs` replaced — what namespacing and coupling
# renaming need, since both rewrite key COLUMNS (references) and must leave the
# range symbols (binders) alone.
_with_pairs(c::_OnJoinSpec, pairs) = _OnJoinSpec(pairs, c.syms)
_with_pairs(::Any, pairs) = pairs

# A parsed OVERLAP join clause — the spatial-index-backed broad-phase
# gate that replaces uniform-grid bin equality with envelope candidacy. It names
# CONST-ARRAY FACTORS interpreted as per-position envelopes:
#   4 names → rectangles [xmin, ymin, xmax, ymax] (e.g. ISRM cells [W,S,E,N]),
#   2 names → points [x, y] → degenerate envelope (x,y,x,y) (e.g. emission X/Y),
#   1 name  → a [pos, verts, coord] ring factor → AABB via `_ring_xybbox`.
# `src_env` maps to one join range, `tgt_env` to the other (each factor's 1-D
# shape index set names the range, exactly like the `on` gate's key columns).
# `eps` is the outward envelope inflation (FP-conservative slack, default 0.0).
# `eps_given` records whether the clause SPELLED `eps` (an explicit `0` included):
# an absent `eps` means the schema default 0 and is neither serialized nor
# printed, while a present one round-trips as written (RENDERING_CONTRACT.md).
# It is BUILT by `_coerce_join`, round-trips through `serialize`/`namespacing`/
# `display`, and is CONSUMED by `_resolve_join_gates_for` (main-graph) and
# `_vi_resolve_join` (value-invention) into the resolved gates above.
struct _OverlapJoinSpec
    src_env::Vector{String}
    tgt_env::Vector{String}
    eps::Float64
    eps_given::Bool
end

"""
    EXPRESSION_NODE_ANNOTATIONS

The fields of an expression node that annotate it rather than define its
value: `id` (the name a derived index set gives its producer through
`from_faq`) and `expect_cadence` (an author assertion of the node's cadence
class). Metaparameter substitution leaves them alone, and the document formats
print a node carrying one in the escape form.
"""
const EXPRESSION_NODE_ANNOTATIONS = ("id", "expect_cadence")

# `mutable struct` for POINTER IDENTITY, not to be mutated: fields are never
# assigned after construction (copies go through `reconstruct`). Identity makes
# `objectid`/`===` O(1), so the build's `IdDict{OpExpr,…}` memos and the
# `r !== args[i]` "did this subtree change" checks do not hash ~35 fields. No
# custom `==`/`hash`: an `OpExpr` is only ever an `IdDict` key.
"""
    OpExpr(op::String, args::Vector{ASTExpr}; kwargs...)
    OpExpr(op::String, args::AbstractVector; kwargs...)

Operator expression node. `op` and `args` are positional; every other field is
an optional keyword (default `nothing`) that only some operators use. The
`AbstractVector` method converts `args` to `Vector{ASTExpr}`. Fields:
- `op`: operator name (e.g., "+", "*", "log", "D", "faq")
- `args`: vector of argument expressions
- `wrt`: variable name for differentiation (optional; for `D`)
- `dim`: dimension for spatial operators (optional; for `bc`, `integral`, user ops)
- `int_var`: integration variable name (optional; for `integral`, matches JSON field "var")
- `lower`: lower integration bound expression (optional; for `integral`)
- `upper`: upper integration bound expression (optional; for `integral`)
- `output_idx`: for `faq`, list of result index symbols (String) or literal
  singleton dimensions (Int 1). Mirrors SymbolicUtils.ArrayOp.output_idx.
- `expr_body`: for `faq`, the scalar body evaluated at each index point
  (a nested `ASTExpr` tree); the wire key is `"expr"`. Named `expr_body` so the
  field is not confused with Julia's own `Core.Expr`.
- `reduce`: for `faq`, the reduction operator applied to
  contracted indices (one of "+", "*", "max", "min"; default "+"). Names the
  semiring ⊕ only, for files that omit `semiring`.
- `semiring`: for `faq`, the named semiring `(⊕, ⊗)` with
  normative identity elements that parameterizes the reduction (closed registry:
  "sum_product", "max_product", "min_sum", "max_sum", "bool_and_or"). Absent ⇒
  "sum_product", the ordinary einsum semantics. When present it supersedes
  `reduce`; the ⊕/⊗ operators and both identities come from the registry table,
  never the file.
- `ranges`: for `faq`, map from index symbol name to iteration range
  (vector of 2 or 3 ints `[start, stop]` / `[start, step, stop]`).
- `regions`: for `makearray`, list of sub-region boxes, each a list of
  `[start, stop]` pairs per output dimension. A bound is normally an `Int`
  (metaparameters are folded on the raw tree before typed coercion,
  esm-spec §9.7.6), but the schema admits any `MetaparameterExpression`, so a
  bound MAY also be an `ASTExpr` — that is how a still-open bound such as
  `NLON - 1` survives the typed round-trip.
- `values`: for `makearray`, one sub-expression per entry in `regions`.
- `shape`: for `reshape`, target shape; entries are `Int` (concrete length)
  or `String` (symbolic dimension).
- `perm`: for `transpose`, optional 0-based axis permutation.
- `axis`: for `concat`, 0-based axis to concatenate along.
- `fn`: for `broadcast`, the scalar operator to apply element-wise.
- `name`: for `apply_expression_template`, the template name (esm-spec §9.6).
- `value`: for the `const` op, the inline literal value carried by this node.
  Any JSON value (number, integer, or nested array thereof); `args` MUST be
  empty for a const node.
- `units`: for `const`, the declared unit of `value` (esm-spec §4.8.5).
- `join`, `filter`: for `faq`, the equi-join clauses (each a list of
  `[left, right]` key-column pairs that must compare equal) and an optional
  boolean predicate; a combination for which the predicate is false contributes
  the additive identity.
- `join_gates`: internal, build-time resolution of `join`; never parsed or
  serialized.
- `id`: the node-local identifier a `kind: "derived"` index set names through
  `from_faq`.
- `distinct`, `key`: for a value-inventing `faq`, whether it produces a
  deduplicated index set, and the scalar integer key expression it emits per
  surviving index combination.
- `bindings`: for `apply_expression_template`, the parameter → argument
  expression map (esm-spec §9.6).
- `expect_cadence`: an optional author assertion of this node's cadence class
  (`"const"`, `"discrete"` or `"continuous"`); carried verbatim, and an error is
  raised only when the derived class disagrees.
- `attrs`: named scalar attributes of an open rewrite-target op (esm-spec
  §4.2), such as a custom scheme's parameters.
"""
mutable struct OpExpr <: ASTExpr
    op::String
    args::Vector{ASTExpr}
    wrt::Union{String, Nothing}
    dim::Union{String, Nothing}
    int_var::Union{String, Nothing}
    lower::Union{ASTExpr, Nothing}
    upper::Union{ASTExpr, Nothing}
    output_idx::Union{Vector{Any}, Nothing}
    expr_body::Union{ASTExpr, Nothing}
    reduce::Union{String, Nothing}
    semiring::Union{String, Nothing}
    ranges::Union{Dict{String, Any}, Nothing}
    regions::Union{Vector{Vector{Vector{Any}}}, Nothing}
    values::Union{Vector{ASTExpr}, Nothing}
    shape::Union{Vector{Any}, Nothing}
    perm::Union{Vector{Int}, Nothing}
    axis::Union{Int, Nothing}
    fn::Union{String, Nothing}
    name::Union{String, Nothing}
    value::Any
    # const (esm 1.2.0): the declared unit `value` is in (esm-spec §4.8.5).
    units::Union{String, Nothing}

    # ── value-equality joins + filter predicates on faq ──
    # (RFC semiring-faq-unified-ir §5.3 / §7.2).
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
    join::Union{Vector{Any}, Nothing}
    filter::Union{ASTExpr, Nothing}
    join_gates::Union{Vector{_JoinGate}, Nothing}

    # `id` — node-local identifier (RFC §6.1) by which a `kind:"derived"`
    #        index set names its producer via `from_faq`. Emitted only when
    #        present.
    id::Union{String, Nothing}

    # ── Value-invention aggregate vocabulary (RFC §5.5 / §6.1) ──
    # `distinct` — an index-set-PRODUCING aggregate (a `distinct:true` relational
    #              set former); its emitted `key`s are deduplicated in §5.5.1 sorted
    #              order to materialise a derived index set (matched by `from_faq`).
    # `key`       — the scalar integer KEY expression the producer emits per
    #              surviving index combination. Both live ONLY in the
    #              raw value-invention front-door (they are read off the raw JSON),
    #              but MUST survive the typed-IR round-trip so a flattened multi-model
    #              document's producer is still recognised (else the derived set is
    #              never sized and the producer's ODE equation is not dropped).
    distinct::Union{Bool, Nothing}
    key::Union{ASTExpr, Nothing}

    # `bindings` — for `apply_expression_template`, the parameter→argument-expression
    #              map (esm-spec §9.6). Templates are normally lowered before typed
    #              parsing, but the node is renderable directly so the pretty-printer
    #              can emit `name⟨p=e, …⟩` as the other bindings do.
    bindings::Union{Dict{String, ASTExpr}, Nothing}

    # ── Author annotations: carried verbatim, never interpreted here ──
    # `expect_cadence` — an OPTIONAL author assertion on this node's cadence
    #           class ("const"/"discrete"/"continuous"; CONFORMANCE_SPEC.md
    #           §5.7.6 rule 3). A test/diagnostic hook that changes NO
    #           semantics: the dependency-partition pass DERIVES every node's
    #           class from the data-dependency DAG and merely errors when a
    #           present assertion disagrees. Nothing in the build path reads or
    #           rewrites it, so it is authored content that must round-trip —
    #           dropping it on load disarmed that guard on every re-emitted
    #           document (Go, TypeScript and Rust all carry it).
    # `attrs`   — named scalar attributes of an OPEN rewrite-target op
    #           (esm-spec §4.2): a custom op such as `godunov_hamiltonian`
    #           carries its SCHEME PARAMETERS here instead of in dedicated
    #           schema slots, and in a rewrite rule's `match` an `attrs.<key>`
    #           whose value is a bare param name binds that param to the
    #           matched literal (§9.6.1). Evaluable-core ops MUST NOT use it.
    #           Dropping it lost a custom op's configuration outright.
    #
    # Both are semantically inert for evaluation but are NOT inert for
    # identity: they are emitted, so two nodes differing only in one of them
    # are different documents and MUST NOT be interned together (intern.jl's
    # generated walkers cover them automatically via their `:scalar` row).
    # Neither has a slot in the pinned canonical JSON node encoding, so a node
    # carrying one fails closed with `E_CANONICAL_UNSUPPORTED_FIELD` — see
    # `_NON_EMISSIBLE_FIELDS` (canonicalize.jl), which derives that from
    # `fieldnames(OpExpr)` and therefore needs no edit here.
    expect_cadence::Union{String, Nothing}
    attrs::Union{Dict{String, Any}, Nothing}

    # ── Load provenance, never on the wire ──
    # `template_origin` — the name of the template whose expansion this node is
    #           the root of, set when the load expands an
    #           `apply_expression_template` reference (a mounted leaf's, at the
    #           mount) and when the elementwise lift expands one. The lift
    #           (esm-spec §9.6.11, elementwise_lift.jl) applies only to a
    #           template application, so a shaped read an author wrote by hand
    #           is never lifted.
    template_origin::Union{String, Nothing}

    OpExpr(
        op::String, args::Vector{ASTExpr};
        wrt = nothing, dim = nothing,
        int_var = nothing, lower = nothing, upper = nothing,
        output_idx = nothing, expr_body = nothing, reduce = nothing,
        semiring = nothing,
        ranges = nothing, regions = nothing, values = nothing,
        shape = nothing, perm = nothing, axis = nothing, fn = nothing,
        name = nothing, value = nothing, units = nothing,
        join = nothing, filter = nothing, join_gates = nothing,
        id = nothing,
        distinct = nothing, key = nothing,
        bindings = nothing,
        expect_cadence = nothing, attrs = nothing, template_origin = nothing
    ) =
        _new_typed(
        OpExpr, op, args, wrt, dim, int_var, lower, upper, output_idx, expr_body, reduce,
        semiring, ranges,
        regions, values, shape, perm, axis, fn, name, value, units,
        join, filter, join_gates,
        id, distinct, key, bindings,
        expect_cadence, attrs, template_origin
    )
end

# Fully-positional constructor — the ALLOCATION-FREE reconstruction
# path. The keyword constructor above builds a ~30-entry `NamedTuple` for its
# kwargs on every call, and `reconstruct` (the one canonical copy-with-changes
# site, invoked once per rewritten node in `_sub_preserving`/`_resolve_*`)
# would pay that on every substitution. Routing `reconstruct` through this
# positional form drops the per-node NamedTuple allocation entirely. The
# arguments are all fields in struct-field order.
_def_new_typed(OpExpr)

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
    _comment::Union{String, Nothing}

    Equation(lhs::ASTExpr, rhs::ASTExpr; _comment = nothing) =
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
    PeriodicTrigger(period::Float64; phase = nothing)

Trigger that fires periodically.
- `period`: the wire `interval`, the time between firings
- `phase`: the wire `initial_offset`, the time offset of the first firing;
  `nothing` when the document does not write it (the schema default is 0), so
  an authored `0` is written back and an absent key stays absent
"""
struct PeriodicTrigger <: DiscreteEventTrigger
    period::Float64
    phase::Union{Float64, Nothing}

    PeriodicTrigger(period::Float64; phase = nothing) =
        new(period, phase === nothing ? nothing : Float64(phase))
end

"""
    PresetTimesTrigger(times::Vector{Float64})

Trigger that fires at preset times.
"""
struct PresetTimesTrigger <: DiscreteEventTrigger
    times::Vector{Float64}
    PresetTimesTrigger(times) = new(_as_type(Vector{Float64}, times))
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
    # The three remaining `ContinuousEvent` properties esm-schema.json defines.
    # `affect_neg` is the DIFFERENT-DIRECTION affect set (absent ⇒ `affects`
    # applies to both crossings), `root_find` which side of the root the event
    # lands on ("left" | "right", DiffEq's `rootfind`), `reinitialize` whether to reinitialize after
    # the event. All three are `Nothing`-able so PRESENCE round-trips: the
    # schema gives `root_find` and `reinitialize` defaults, and emitting a
    # default the author did not write is as much a rewrite as dropping one
    # they did. `CouplingEvent` already carries this exact trio.
    affect_neg::Union{Vector{AffectEquation}, Nothing}
    root_find::Union{String, Nothing}
    reinitialize::Union{Bool, Nothing}
    description::Union{String, Nothing}
    # Human-readable identifier (schema `ContinuousEvent.name`). Carried so an
    # authored event survives parse → emit, and so the
    # `event_affects_parameter` diagnostic can name the offending event.
    name::Union{String, Nothing}

    # Constructor with optional description / name
    ContinuousEvent(
        conditions::Vector{ASTExpr}, affects::Vector{AffectEquation};
        affect_neg = nothing, root_find = nothing, reinitialize = nothing,
        description = nothing, name = nothing
    ) =
        new(
        conditions, affects, affect_neg, root_find, reinitialize,
        description, name
    )
end

"""
    DiscreteEvent <: EventType

Event triggered by discrete triggers whose symbolic `affects` are
[`AffectEquation`](@ref)s (`lhs` target name, `rhs` new-value expression) —
the schema's `AffectEquation` shape, shared with `ContinuousEvent`.

An event affects **unknowns only** (esm-spec §5.4, §6.3.1). A handler that
computes a new value lives on the parameter it writes (`update.handler`,
[`FunctionalUpdate`](@ref)), and a parameter that changes during a run declares
its own [`ParameterUpdate`](@ref). An `affects` LHS naming a parameter is the
`event_affects_parameter` diagnostic.
"""
struct DiscreteEvent <: EventType
    trigger::DiscreteEventTrigger
    affects::Vector{AffectEquation}
    # Whether to reinitialize the system after the event (schema
    # `DiscreteEvent.reinitialize`). The schema gives it NO default, so its
    # presence is meaningful and it is `Nothing`-able to carry that.
    reinitialize::Union{Bool, Nothing}
    description::Union{String, Nothing}
    # Human-readable identifier (schema `DiscreteEvent.name`). Carried so an
    # authored event survives parse → emit, and so the
    # `event_affects_parameter` diagnostic can name the offending event.
    name::Union{String, Nothing}

    # Constructor with optional description / name
    DiscreteEvent(
        trigger::DiscreteEventTrigger, affects::Vector{AffectEquation};
        reinitialize = nothing, description = nothing, name = nothing
    ) =
        new(trigger, affects, reinitialize, description, name)
end

# ========================================
# 5. Model Component Types
# ========================================

"""
    Reference

Academic citation or data source reference.
"""
struct Reference
    doi::Union{String, Nothing}
    citation::Union{String, Nothing}
    url::Union{String, Nothing}
    notes::Union{String, Nothing}

    # Constructor with all optional parameters
    Reference(; doi = nothing, citation = nothing, url = nothing, notes = nothing) =
        new(doi, citation, url, notes)
end

"""
    Distribution

A parameter's value drawn from a probability distribution rather than fixed
(esm-spec §6.3, schema `Distribution`). The closed set is `normal`,
`lognormal`, and `uniform`.

The three kinds spell their parameters differently on the wire, so the struct
stores them by ROLE and the wire names are restored on emit:

| `kind` | `location` | `scale` | other |
|---|---|---|---|
| `normal` | `mean` | `std` | `cov` |
| `lognormal` | `mu` | `sigma` | `cov` |
| `uniform` | — | — | `low`, `high` |

A distribution is *univariate* when its location parameter is a number and
*multivariate* when it is an array, in which case `cov` gives the full
covariance matrix and the parameter's `shape` must agree. WHEN the value is
drawn is decided by the parameter's [`ParameterUpdate`](@ref): with no update
it is sampled once at setup (`sampled_parameters`); with `kind: "wiener"` it is
resampled every step with √dt scaling (`brownian_parameters`).
"""
struct Distribution
    kind::String
    location::Union{Float64, Vector{Float64}, Nothing}
    scale::Union{Float64, Vector{Float64}, Nothing}
    cov::Union{Vector{Vector{Float64}}, Nothing}
    low::Union{Float64, Vector{Float64}, Nothing}
    high::Union{Float64, Vector{Float64}, Nothing}

    Distribution(
        kind::AbstractString; location = nothing, scale = nothing,
        cov = nothing, low = nothing, high = nothing
    ) =
        _new_typed(Distribution, String(kind), location, scale, cov, low, high)
end
_def_new_typed(Distribution)

"""
    FunctionalUpdate

A registered handler that computes a parameter's new value when its update
fires (esm-spec §5.5). It lives on the parameter it writes, so it carries no
list of written variables. `handler_id` is the only registration mechanism in
the format.
"""
struct FunctionalUpdate
    handler_id::String
    read_vars::Union{Vector{String}, Nothing}
    read_params::Union{Vector{String}, Nothing}
    config::Union{Dict{String, Any}, Nothing}

    FunctionalUpdate(
        handler_id::AbstractString; read_vars = nothing,
        read_params = nothing, config = nothing
    ) =
        new(String(handler_id), read_vars, read_params, config)
end

"""
    DataSourceBinding

Binds a parameter to one file variable of a `data_sources` entry (esm-spec
§8.5) — the `from` value form of a `data` update. It carries no `units`: the
units are the parameter's own, declared once on the consumer.

`records_per_sample` (1 or 2, `nothing` when not written) is DEPRECATED (esm-spec
§8.5.1, removed at esm 3.0.0): the parameter's record shape says how many
records it receives, and a written value must agree with it. It parses and
round-trips as written; validation and `flatten` refuse a value that disagrees
with the record shape (`records_per_sample_invalid`).
"""
struct DataSourceBinding
    file_variable::String
    unit_conversion::Union{Float64, ASTExpr, Nothing}
    codes::Union{Dict{String, Any}, Nothing}
    select::Union{Dict{String, Any}, Nothing}
    records_per_sample::Union{Int, Nothing}
    description::Union{String, Nothing}
    reference::Union{Reference, Nothing}

    DataSourceBinding(
        file_variable::AbstractString; unit_conversion = nothing,
        codes = nothing, select = nothing, records_per_sample = nothing,
        description = nothing, reference = nothing
    ) =
        new(
        String(file_variable), unit_conversion, codes, select,
        records_per_sample, description, reference
    )
end

"""
    PARAMETER_UPDATE_KINDS

The closed set of `update.kind` values (esm-spec §5.4). `wiener` takes no value
form and requires the parameter's `distribution`; the other five take exactly
one of `expression` / `from` / `handler`. `schedule`, `data`, and `remesh`
additionally require the parameter to declare a `shape`, because such a
parameter is a buffer refilled on a discrete cadence.
"""
const PARAMETER_UPDATE_KINDS = (
    "wiener", "schedule", "condition", "crossing",
    "data", "remesh",
)

"""The update kinds that require the parameter to declare a `shape` (§5.4)."""
const SHAPE_REQUIRING_UPDATE_KINDS = ("schedule", "data", "remesh")

"""
    ParameterUpdate

One rule saying WHEN a parameter refreshes and WHAT it refreshes from
(esm-spec §5.4). One mechanism covers a Wiener noise source
(`kind: "wiener"`), a refresh on a schedule, from data or on a remesh
(`schedule` / `data` / `remesh`), and a change when a condition holds or a
crossing occurs (`condition` / `crossing`).

Trigger fields by kind: `schedule` uses `times` / `interval` /
`initial_offset`; `condition` and `crossing` use `when` (plus `direction` for
`crossing`); `data` uses `source`; `remesh` uses `hook`; `wiener` uses none.
Value forms: exactly one of `expression`, `from`, `handler` for every kind
except `wiener`, which resamples the parameter's own `distribution`.
"""
struct ParameterUpdate
    kind::String
    # schedule
    times::Union{Vector{Float64}, Nothing}
    interval::Union{Float64, Nothing}
    initial_offset::Union{Float64, Nothing}
    # condition / crossing
    when::Union{ASTExpr, Nothing}
    direction::Union{String, Nothing}
    # data
    source::Union{String, Nothing}
    # remesh
    hook::Union{String, Nothing}
    # value forms — exactly one, except for `wiener` which carries none
    expression::Union{ASTExpr, Nothing}
    from::Union{DataSourceBinding, Nothing}
    handler::Union{FunctionalUpdate, Nothing}

    ParameterUpdate(
        kind::AbstractString; times = nothing, interval = nothing,
        initial_offset = nothing, when = nothing, direction = nothing,
        source = nothing, hook = nothing, expression = nothing,
        from = nothing, handler = nothing
    ) =
        _new_typed(
        ParameterUpdate, String(kind), times, interval, initial_offset, when,
        direction, source, hook, expression, from, handler
    )
end
_def_new_typed(ParameterUpdate)

"""
    @enum ModelVariableType

The **two** declared variable types of esm 1.0.0 (esm-spec §6.3) — and there is
no third:

- `UnknownVariable`: a quantity the solver solves for. Its behaviour is stated
  by the model's `equations` and **nowhere else**; there is no `expression`
  field on a variable.
- `ParameterVariable`: a quantity supplied to the solver. Its value is
  `default` or a [`Distribution`](@ref), optionally refreshed by a
  [`ParameterUpdate`](@ref).

Everything else a solver needs is DERIVED, not declared. Which unknowns are ODE
states, observed, or algebraic follows from the equations; which parameters are
Brownian, discrete, sampled, or constant follows from `distribution` and
`update`. Ask those questions through the classification API of esm-spec
§6.3.1 — [`ode_states`](@ref), [`observed_unknowns`](@ref),
[`algebraic_unknowns`](@ref), [`is_ode_state`](@ref),
[`brownian_parameters`](@ref), [`discrete_parameters`](@ref),
[`sampled_parameters`](@ref), [`constant_parameters`](@ref),
[`system_kind`](@ref) — never by reading a declared type.
"""
@enum ModelVariableType begin
    UnknownVariable
    ParameterVariable
end

"""
    UnknownVariable::ModelVariableType

A variable the solver solves for (wire spelling `"unknown"`, esm-spec §6.3).
Whether it is an ODE state, an observed or an algebraic unknown is derived from
the model's equations; see [`ode_states`](@ref), [`observed_unknowns`](@ref)
and [`algebraic_unknowns`](@ref), and [`unknowns`](@ref) for all of them.
"""
UnknownVariable

"""
    ParameterVariable::ModelVariableType

A variable supplied to the solver (wire spelling `"parameter"`, esm-spec §6.3):
its value is `default` or a [`Distribution`](@ref), optionally refreshed by a
[`ParameterUpdate`](@ref). Whether it is constant, sampled, discrete or
Brownian is derived from those fields; see [`constant_parameters`](@ref),
[`sampled_parameters`](@ref), [`discrete_parameters`](@ref) and
[`brownian_parameters`](@ref), and [`parameters`](@ref) for all of them.
"""
ParameterVariable

"""
    MODEL_VARIABLE_TYPE_TABLE

The bidirectional `ModelVariableType` ↔ string vocabulary — one row per enum
member, the single source of truth for every kind-string mapping. It lives here, next to the enum it
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
  member names. The 0.x wire spellings `state` / `observed` / `brownian` /
  `discrete` are deliberately NOT aliases: esm 1.0.0 is a clean break, so a
  document declaring one is rejected rather than silently reinterpreted.

Derived (below): [`_MODEL_VARIABLE_TYPE_WIRE`](@ref) and
[`_MODEL_VARIABLE_TYPE_FROM_STRING`](@ref). Round-trip and legacy-spelling
behavior is pinned by test/types_test.jl.
"""
const MODEL_VARIABLE_TYPE_TABLE = (
    (enum = UnknownVariable, wire = "unknown", legacy = ("UnknownVariable",)),
    (enum = ParameterVariable, wire = "parameter", legacy = ("ParameterVariable",)),
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
const _MODEL_VARIABLE_TYPE_WIRE = Dict{ModelVariableType, String}(
    row.enum => row.wire for row in MODEL_VARIABLE_TYPE_TABLE
)

"""
    _MODEL_VARIABLE_TYPE_FROM_STRING

String → enum, derived from [`MODEL_VARIABLE_TYPE_TABLE`](@ref): every wire
spelling plus every legacy alias. Consumer: `coerce_model_variable_type`
(parse.jl).
"""
const _MODEL_VARIABLE_TYPE_FROM_STRING = let d = Dict{String, ModelVariableType}()
    for row in MODEL_VARIABLE_TYPE_TABLE
        d[row.wire] = row.enum
        for alias in row.legacy
            d[alias] = row.enum
        end
    end
    d
end

"""
    VariableBound

The value of a variable's `lb` or `ub` (esm-spec §6.3.2): absent, a number as
authored, a reference by name, or — on a flattened variable only — the
expression a scaled `variable_map` substituted for the referenced parameter.
"""
const VariableBound = Union{Nothing, Int64, Float64, String, ASTExpr}

"""
    ModelVariable

A model variable: an `unknown` the solver solves for, or a `parameter` supplied
to it (esm-spec §6.3).

An unknown carries no `expression` — its behaviour is stated by the model's
`equations` and nowhere else, so an observed unknown's defining right-hand side
is reached through [`observed_definitions`](@ref), never off the variable.

Parameter-only value fields:
- `distribution`: draw the value from a [`Distribution`](@ref) instead of fixing
  it at `default` (mutually exclusive with `default`).
- `update`: when the parameter refreshes and what from — a vector of
  [`ParameterUpdate`](@ref) rules applied in declaration order. `nothing` means
  the parameter never changes after setup. The wire form is a single object for
  one rule and an array for two or more (a one-element array is invalid), so
  `length(update)` alone decides the emitted spelling and the round trip is
  stable.

Bounds (any variable, esm-spec §6.3.2):
- `lb` / `ub`: the range the variable's value lies in. A number (`Int64` or
  `Float64`, kept as authored so emit writes back what was read) or a `String`
  reference to another variable, resolved like a variable reference in the
  model's expressions. `nothing` means unbounded on that side. A flattened
  variable's reference is its namespaced name, or an [`ASTExpr`](@ref) where a
  scaled `variable_map` replaced the referenced parameter. Bounds state a fact
  and change no lowering.
"""
struct ModelVariable
    type::ModelVariableType
    # A scalar value, or — for a SHAPED variable — INLINE ARRAY DATA: the whole
    # field, authored as a row-major nested JSON array whose nesting matches the
    # declared `shape` after metaparameter folding (esm-spec §6.3 / §6.6.2). A
    # scalar on a shaped variable keeps its broadcast meaning.
    default::Union{Float64, Array{Float64}, Nothing}
    description::Union{String, Nothing}
    units::Union{String, Nothing}
    default_units::Union{String, Nothing}
    # Arrayed-variable shape: ordered index-set names from the document-scoped
    # `index_sets` registry. `nothing` means scalar; an empty vector is a valid
    # (scalar) shape a `schedule` / `data` / `remesh` parameter may declare.
    shape::Union{Vector{String}, Nothing}
    # Staggered-grid location tag (e.g. "cell_center", "edge_normal",
    # "vertex"). `nothing` means no explicit staggering. See RFC §10.2.
    location::Union{String, Nothing}
    distribution::Union{Distribution, Nothing}
    update::Union{Vector{ParameterUpdate}, Nothing}
    # `"Float32"` / `"Float64"`: the precision of THIS variable and of the
    # arithmetic over it, overriding `domain.element_type` (esm-spec §11.3.1);
    # `nothing` means the declaring document's. A §4.7 mount writes a leaf's
    # `domain.element_type` here ("Working precision crosses a mount"), so this is
    # also where a mounted document's precision survives load -> emit.
    element_type::Union{String, Nothing}
    lb::VariableBound
    ub::VariableBound

    # Constructor with optional parameters
    ModelVariable(
        type::ModelVariableType;
        default = nothing,
        description = nothing,
        units = nothing,
        default_units = nothing,
        shape = nothing,
        location = nothing,
        distribution = nothing,
        update = nothing,
        element_type = nothing,
        lb = nothing,
        ub = nothing
    ) =
        new(
        type, _coerce_inline_value(default), description, units, default_units,
        shape, location, distribution, _coerce_update_vector(update),
        element_type === nothing ? nothing : String(element_type),
        _coerce_variable_bound(lb), _coerce_variable_bound(ub)
    )
end

# The wire value of a bound, as its own type. An integer stays an integer so a
# bound written `0` is emitted `0`; a JSON `true` is not a number here.
_coerce_variable_bound(::Nothing) = nothing
_coerce_variable_bound(x::Bool) =
    throw(ArgumentError("a variable bound is a number or a variable name, got $(x)"))
_coerce_variable_bound(x::Integer) = something(_as_int64(x), Float64(x))
_coerce_variable_bound(x::Real) = Float64(x)
_coerce_variable_bound(x::AbstractString) = String(x)
_coerce_variable_bound(x::ASTExpr) = x
_coerce_variable_bound(x) =
    throw(ArgumentError("a variable bound is a number or a variable name, got $(repr(x))"))

# ---- Inline value coercion (esm-spec §6.3 / §6.6.2) --------------------------
# A `default`, a `parameter_overrides` entry and an `initial_conditions` entry
# each carry either a SCALAR or INLINE ARRAY DATA — a row-major nested JSON
# array holding a shaped variable's whole field. `_coerce_inline_value` maps the
# first to `Float64` and the second to a dense `Array{Float64,N}` whose axis `d`
# is the nesting depth `d`, so `A[i, j]` is the authored `data[i][j]`. A ragged
# array (sibling axes of different lengths, or a mix of number and array at one
# depth) is a load-time error, mirroring the `from_file` convention of §6.6.5.
_coerce_inline_value(::Nothing) = nothing
# Already a dense NUMERIC array (a re-coerced value, or one a caller built
# directly): its axes ARE the shape, so it passes through. Walking it as if it
# were nested would read `length` on the whole array and collapse a 2x3 slab to
# a 6-vector.
_coerce_inline_value(x::AbstractArray{<:Real}) = Array{Float64}(x)
# The wire form: a nested `Vector{Any}` (JSON), one level per axis.
_coerce_inline_value(x::AbstractArray) = _inline_array(x)
_coerce_inline_value(x) = Float64(x)

function _inline_array(v::AbstractArray)
    dims = Int[]
    node = v
    while node isa AbstractArray
        push!(dims, length(node))
        isempty(node) && break
        node = first(node)
    end
    A = Array{Float64}(undef, dims...)
    _fill_inline_array!(A, v, (), dims)
    return A
end

function _fill_inline_array!(A::Array{Float64}, v, idx::Tuple, dims::Vector{Int})
    depth = length(idx)
    if v isa AbstractArray
        depth < length(dims) || throw(
            ParseError(
                "inline array data is ragged: an array appears where a number is expected " *
                    "(esm-spec §6.3)"
            )
        )
        length(v) == dims[depth + 1] || throw(
            ParseError(
                "inline array data is ragged: axis $(depth + 1) has both $(dims[depth + 1]) " *
                    "and $(length(v)) elements (esm-spec §6.3)"
            )
        )
        for (i, x) in enumerate(v)
            _fill_inline_array!(A, x, (idx..., i), dims)
        end
    else
        depth == length(dims) || throw(
            ParseError(
                "inline array data is ragged: a number appears at nesting depth $(depth) " *
                    "where an array of $(dims[depth + 1]) elements is expected (esm-spec §6.3)"
            )
        )
        A[idx...] = Float64(v)
    end
    return nothing
end

"""
    _emit_inline_value(x)

The wire form of a coerced inline value: a scalar emits as its number, a dense
`Array{Float64,N}` re-nests into the ROW-MAJOR nested JSON array it was authored
as (axis 1 outermost), so `parse → emit` is the identity on the document text.
"""
_emit_inline_value(x::Nothing) = nothing
_emit_inline_value(x::Number) = x
function _emit_inline_value(A::AbstractArray)
    ndims(A) == 0 && return Float64(A[])
    return [_emit_inline_value(_inline_slice(A, i)) for i in axes(A, 1)]
end
_emit_inline_value(x) = x

# One outer-axis slice of `A`, dropping axis 1 (a rank-1 array yields a number).
_inline_slice(A::AbstractArray, i) =
    ndims(A) == 1 ? A[i] : view(A, i, ntuple(_ -> Colon(), ndims(A) - 1)...)

"""
    is_inline_array(x) -> Bool

Whether a resolved `default` / override value is INLINE ARRAY DATA (esm-spec
§6.3) rather than a scalar.
"""
is_inline_array(x) = x isa AbstractArray

# `update` accepts a single rule or a vector of rules; it is stored as a vector
# (or `nothing`) so every consumer iterates one shape. The emitted wire form is
# recovered from the length: one rule ⇒ object, two or more ⇒ array.
_coerce_update_vector(::Nothing) = nothing
_coerce_update_vector(u::ParameterUpdate) = ParameterUpdate[u]
_coerce_update_vector(u::Vector{ParameterUpdate}) = u
_coerce_update_vector(u::AbstractVector) = ParameterUpdate[x for x in u]

"""
    _update_is_scalar_form(rules::AbstractVector) -> Bool

Whether an `update` vector came from the wire's OBJECT form (one rule) rather
than its ARRAY form. `length(rules) == 1` decides it, and that is sound rather
than a heuristic: `esm-schema.json`'s `ParameterUpdateSpec` is
`oneOf: [ParameterUpdate, {type: array, minItems: 2}]`, so a one-element array
is not a valid document — `tests/invalid/parameter_update_singleton_array.esm`
exists for the sole purpose of pinning that, because representation uniqueness
is what makes the round trip idempotent.

This is the SINGLE place that decision is made. Both consumers must agree or
the document a diagnostic addresses is not the document the serializer emits:

- [`_emit_parameter_update_spec`](@ref) picks the wire form to write;
- [`_update_rule_path`](@ref) builds the JSON Pointer a diagnostic reports.

The Go binding derives it identically (`single := len(copied) == 1` in
`expr_walk.go`); TypeScript reads the wire form directly (`Array.isArray`)
because its typed layer keeps the union. On every schema-valid document all
three agree.
"""
_update_is_scalar_form(rules::AbstractVector) = length(rules) == 1

"""
    _update_rule_path(base::AbstractString, rules, ri::Integer) -> String

The JSON Pointer addressing update rule `ri` (1-based) of `rules`, under
`base` — `"\$base/update"` for the object form, `"\$base/update/\$(ri-1)"` for
the array form.

A diagnostic pointer must address the document **as written**. Julia's typed
model normalizes a scalar `update` into a one-element `Vector` at parse time
(see [`_coerce_update_vector`](@ref)), so the index is written only for the
array form: a document writing `update: {...}` is addressed as
`/update/from/unit_conversion`, as the corpus pin and the other bindings say.
"""
_update_rule_path(base::AbstractString, rules::AbstractVector, ri::Integer) =
    _update_is_scalar_form(rules) ? _pointer(base, "update") : _pointer(base, "update", ri)

"""
    TimeSpan(start::Float64, stop::Float64)

Simulation time interval for inline model tests and analyses (esm-spec §6.6).
"""
struct TimeSpan
    start::Float64
    stop::Float64
end

"""
    SolverTimeSpan(start, stop)

The `solver.time_span` interval (esm-spec §2.2.7): the period the document is
meant to be simulated over. Each bound is what the author wrote — a number in
the document's time units (seconds; an `Int64` when written as an integer, else
a `Float64`), or an RFC 3339 UTC timestamp `String` — so `emit` writes it back
unchanged. Its value in seconds comes from
[`resolve_time_span`](@ref). The wire key `end` is spelled `stop` here, as in
[`TimeSpan`](@ref), because `end` is a Julia keyword.
"""
struct SolverTimeSpan
    start::Union{Int64, Float64, String}
    stop::Union{Int64, Float64, String}
end

"""
    Solver(; stiffness=nothing, abstol=nothing, reltol=nothing, splitting=nothing,
           external=nothing, time_span=nothing)

Document-scoped, OPTIONAL solver hints (esm-spec §2.2) — numerics the document
knows about *itself*, which each binding maps to its own integrator — plus
`external`, a reference to a run-configuration document, and `time_span`, the
interval the document asks to be simulated over (both esm 1.3.0). The
authored `external` string is what the type holds and what `emit` writes; where
it points comes from [`solver_external_location`](@ref) (§2.2.6). Likewise
`time_span` holds the authored bounds, and [`resolve_time_span`](@ref) converts
them to seconds (§2.2.7).

Every field is ADVISORY: a binding may ignore any or all of them and still
conform. Advisory governs the MECHANISM, never the OUTCOME — a binding that
ignores every field and still converges conforms; the CONFORMANCE_SPEC §5.9
requirement to integrate successfully and agree within the error band is
untouched by this block and is not excused by it.

`abstol` / `reltol` are INTEGRATION tolerances and are a DIFFERENT QUANTITY
from [`Tolerance`](@ref), which is what an assertion is COMPARED at (§6.6.4).
They resolve on independent chains and neither substitutes for the other.

Every field is `Union{...,Nothing}` because each is independently optional and
absence is NOT a default value: a document omitting `stiffness` has not
declared its stiffness, and a binding must not read absence as an assertion
about the system.
"""
struct Solver
    stiffness::Union{String, Nothing}
    abstol::Union{Float64, Nothing}
    reltol::Union{Float64, Nothing}
    splitting::Union{String, Nothing}
    external::Union{String, Nothing}
    time_span::Union{SolverTimeSpan, Nothing}

    Solver(;
        stiffness = nothing, abstol = nothing, reltol = nothing, splitting = nothing,
        external = nothing, time_span = nothing
    ) =
        new(stiffness, abstol, reltol, splitting, external, time_span)
end

"""
    Tolerance(abs::Union{Float64,Nothing}, rel::Union{Float64,Nothing})

Numerical comparison tolerance. Either or both of `abs` / `rel` may be
set; an assertion passes when any set bound is satisfied.
"""
struct Tolerance
    abs::Union{Float64, Nothing}
    rel::Union{Float64, Nothing}

    Tolerance(; abs = nothing, rel = nothing) = new(abs, rel)
end

"""
    Assertion(variable::String, time::Float64, expected::Float64, tolerance, coords, reduce, reference)

A scalar `(variable, time, expected)` check used inside a `InlineTest`.

PDE-aware variants:
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
    tolerance::Union{Tolerance, Nothing}
    coords::Union{Dict{String, Float64}, Nothing}
    reduce::Union{String, Nothing}
    reference::Any

    function Assertion(
            variable::AbstractString, time::Real, expected::Real;
            tolerance = nothing,
            coords = nothing,
            reduce = nothing,
            reference = nothing
        )
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
            Dict{String, Float64}(string(k) => Float64(v) for (k, v) in coords)
        reduce_typed = _maybe(String, reduce)
        return new(
            String(variable), Float64(time), Float64(expected),
            tolerance, coords_typed, reduce_typed, reference
        )
    end
end

"""
    InlineTest(id, time_span, assertions; description, initial_conditions, parameter_overrides, tolerance)

Inline validation test for a Model (esm-spec §6.6). Defines the run
configuration — initial conditions, parameter overrides, simulation time
span — and a list of scalar assertions that must hold.
"""
# NAMING: this struct is spelled `InlineTest` (not `Test`) so it does NOT
# collide with the `Test` STANDARD-LIBRARY MODULE that every test suite brings
# in via `using Test`. It is the schema's inline-validation-test construct
# (`models.*.tests`, esm-spec §6.6); not exported — reach it qualified
# as `EarthSciAST.InlineTest`.
struct InlineTest
    id::String
    description::Union{String, Nothing}
    # esm-spec §6.6.2: each value is a scalar, or — for a SHAPED variable —
    # INLINE ARRAY DATA (a dense `Array{Float64,N}` coerced from the authored
    # row-major nested JSON array). `Any`-valued so one map carries both.
    initial_conditions::Dict{String, Any}
    parameter_overrides::Dict{String, Any}
    time_span::TimeSpan
    tolerance::Union{Tolerance, Nothing}
    assertions::Vector{Assertion}
    # Raw §9.7.2 import entries injected into the ENCLOSING component's scope
    # for THIS test's run only (esm-spec §9.7.10 form C / §6.6.6): the
    # discretization a discretization-agnostic PDE leaf is lowered under in the
    # per-test ephemeral build. Authored per-run config — a peer of
    # `parameter_overrides` — so unlike a component's own imports it DOES
    # survive `parse → emit`. Empty for a non-PDE / agnostic-free test.
    expression_template_imports::Vector{Any}

    function InlineTest(
            id::AbstractString, time_span::TimeSpan, assertions::Vector{Assertion};
            description = nothing,
            initial_conditions = Dict{String, Any}(),
            parameter_overrides = Dict{String, Any}(),
            tolerance = nothing,
            expression_template_imports = Any[]
        )
        return new(
            String(id), description,
            Dict{String, Any}(
                string(k) => _coerce_inline_value(v)
                    for (k, v) in initial_conditions
            ),
            Dict{String, Any}(
                string(k) => _coerce_inline_value(v)
                    for (k, v) in parameter_overrides
            ),
            time_span, tolerance, assertions,
            _dynamic(Vector{Any}, expression_template_imports)::Vector{Any}
        )
    end
end

"""
    IndexSet(kind; size, members, of, offsets, values, from_faq, records)

A declared index set in the document-scoped `index_sets` registry
(RFC semiring-faq-unified-ir §5.2). Unifies ESM grid dims and ESI categorical
dims under one shape. `kind` is one of:

- `"interval"`   — dense integer axis; `size` gives its length. `records =
  true` makes it a record axis (esm-spec §8.5.1; its `size` must be 2).
- `"categorical"`— enumerated members; `members` is the ordered member list.
- `"ragged"`     — data-dependent inner set (e.g. the edges of a cell); `of`
  names the parent index set(s), `offsets` the length/CSR-offset backing factor,
  and `values` the member-id backing factor (both keyed factors, §5.4).
- `"derived"`    — materialized from another FAQ (§5.5); `from_faq` is its node
  id. Not evaluated by the tree-walk evaluator in M1.
"""
struct IndexSet
    kind::String
    size::Union{Int, Nothing}
    members::Union{Vector{String}, Nothing}
    of::Union{Vector{String}, Nothing}
    offsets::Union{String, Nothing}
    values::Union{String, Nothing}
    from_faq::Union{String, Nothing}
    # The original, un-stringified categorical members, retained ONLY when at
    # least one member is non-string (float / null / boolean / integer). Lets the
    # join-key validator (RFC §5.3) reject keys whose equality is not portable
    # across bindings — float and null members — which `members` (always coerced
    # to `String`) cannot distinguish. `nothing` for ordinary string-only sets.
    members_raw::Union{Vector{Any}, Nothing}
    # Projection pushdown, members fed back as a const factor. For a
    # `kind:"derived"` set, names a model `parameter` const factor that the build
    # fills with this set's materialised value-invention MEMBERS (the invented
    # 1-based full-grid ids, `vi.members[from_faq]`) — so an in-model gather
    # `index(W, index(<member_factor>, c))` can pull the full-grid rows the
    # compact derived axis selects. There is no `member(set,c)` IR op; this
    # feedback IS the mechanism. `nothing` for every non-feedback set.
    member_factor::Union{String, Nothing}
    # esm-spec §8.5.1: `true` makes an `interval` of size 2 a RECORD AXIS — a
    # data-fed parameter whose record shape begins with it receives two records
    # per query time. Otherwise an ordinary interval everywhere. `nothing` when
    # not written (`false` is the same, and round-trips as written).
    records::Union{Bool, Nothing}

    IndexSet(
        kind::AbstractString; size = nothing, members = nothing, of = nothing,
        offsets = nothing, values = nothing, from_faq = nothing, members_raw = nothing,
        member_factor = nothing, records = nothing
    ) =
        _new_typed(
        IndexSet, String(kind), size, members, of, offsets, values, from_faq,
        members_raw, member_factor, records
    )
end
_def_new_typed(IndexSet)

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

    IndexSetRef(from::AbstractString; of::AbstractVector = String[]) =
        new(String(from), String[String(x) for x in of])
end

"""
    abstract type SubsystemNode end

Common supertype of the legal `Model.subsystems` values: a child `Model` or —
only until references are resolved — a `SubsystemRef`. Exists so
`Model.subsystems` can be concretely typed `Dict{String,SubsystemNode}` even
though `SubsystemRef` is declared later in this file than `Model`. A data
source is an ingest registry entry, not a component, so it is not a
`SubsystemNode`.
"""
abstract type SubsystemNode end

"""
    SubsystemRef(ref::String)
    SubsystemRef(ref::String, bindings::Dict{String,Int})

Unresolved reference to an external ESM file used as a subsystem (esm-spec §4.7).
Produced by `coerce_model` for a `{"ref": "..."}` subsystem entry and replaced
in place by `resolve_subsystem_refs!` with the loaded `Model`.
A `SubsystemRef` only survives parsing when references are not resolved (e.g.
`load_string` without a base path); `load_path` always resolves them.
`bindings` closes the referenced document's open metaparameters at this edge
(esm-spec §9.7.6 binding site 3 — e.g. a convergence wrapper instantiating a
problem file at a given size). `expression_template_imports` are the raw
§9.7.2 import entries injected into the REFERENCED component's own template
scope (esm-spec §9.7.10 form A — assembler-chosen discretization for a mounted
PDE leaf); they are threaded into the referenced document's load and consumed by
the §9.6.3 fixpoint, so a resolved subsystem round-trips as the lowered inline
component and the field does not survive `parse → emit`.
`index_set_rename` translates the mounted document's index-set names into the
mounting document's vocabulary at load (esm-spec §4.7 "Mount-edge index-set
renaming") — the §9.7.7 renaming mechanism at a component-mount edge, restricted
to index sets. Like the two fields above it is consumed at the mount and does not
survive `parse → emit`.
`url_substitutions` binds the bare `{name}` placeholders of the mounted
document's `data_sources` locations (esm-spec §4.7 "Binding a data source's
location at the mount"). Kept RAW (`nothing` when absent) so its shape is
checked at the edge, with the edge's diagnostics; consumed at the mount like the
fields above.
"""
struct SubsystemRef <: SubsystemNode
    ref::String
    bindings::Dict{String, Int}
    expression_template_imports::Vector{Any}
    index_set_rename::Union{Nothing, OrderedDict{String, String}}
    url_substitutions::Any
end

SubsystemRef(
    ref::AbstractString, bindings::AbstractDict, injected::AbstractVector,
    index_set_rename::Union{Nothing, AbstractDict}
) = SubsystemRef(
    String(ref), Dict{String, Int}(string(k) => Int(v) for (k, v) in bindings),
    Any[e for e in injected],
    index_set_rename === nothing ? nothing : OrderedDict{String, String}(index_set_rename),
    nothing
)

SubsystemRef(ref::AbstractString, bindings::AbstractDict, injected::AbstractVector) =
    SubsystemRef(
    String(ref),
    Dict{String, Int}(string(k) => Int(v) for (k, v) in bindings),
    Any[e for e in injected], nothing, nothing
)
SubsystemRef(ref::AbstractString, bindings::AbstractDict) =
    SubsystemRef(
    String(ref),
    Dict{String, Int}(string(k) => Int(v) for (k, v) in bindings), Any[], nothing, nothing
)
SubsystemRef(ref::AbstractString) =
    SubsystemRef(String(ref), Dict{String, Int}(), Any[], nothing, nothing)

"""
    Model

ODE-based model component containing variables, equations, and optional subsystems.
Supports hierarchical composition through subsystems. A subsystem value is a
child `Model` or — only until references are resolved — a `SubsystemRef`; the
field is typed by their shared supertype, `OrderedDict{String,SubsystemNode}`.

`variables` and `subsystems` are `OrderedDict`s, and the parser populates them in
DOCUMENT ORDER. That is not a convenience: esm-libraries-spec §4.7.5 step 4 makes
the flattened system's ordering normative (variables in the order their component
declares them), and a flattener can only inherit an order the IR preserved:
`flatten`'s `parameters` is read POSITIONALLY as the parameter vector.
"""
struct Model <: SubsystemNode
    variables::OrderedDict{String, ModelVariable}
    equations::Vector{Equation}
    discrete_events::Vector{DiscreteEvent}
    continuous_events::Vector{ContinuousEvent}
    subsystems::OrderedDict{String, SubsystemNode}
    tolerance::Union{Tolerance, Nothing}
    tests::Vector{InlineTest}
    # Inline illustrative analyses (schema `Model.analyses`): run configuration
    # plus derived plots. Kept VERBATIM — nothing in this package runs them, so
    # their only job is to survive parse → emit; the alternative on offer was
    # dropping every one of them.
    analyses::Vector{Any}
    initialization_equations::Vector{Equation}
    guesses::Dict{String, Union{Float64, ASTExpr}}
    system_kind::Union{String, Nothing}
    # The component's own citation (schema `Model.reference`).
    reference::Union{Reference, Nothing}

    Model(
        variables::AbstractDict{String, ModelVariable}, equations::Vector{Equation};
        discrete_events = DiscreteEvent[],
        continuous_events = ContinuousEvent[],
        subsystems = OrderedDict{String, SubsystemNode}(),
        tolerance = nothing,
        tests = InlineTest[],
        analyses = Any[],
        initialization_equations = Equation[],
        guesses = Dict{String, Union{Float64, ASTExpr}}(),
        system_kind = nothing,
        reference = nothing
    ) =
        new(
        OrderedDict{String, ModelVariable}(variables), equations,
        discrete_events, continuous_events, OrderedDict{String, SubsystemNode}(subsystems),
        tolerance, tests, _dynamic(Vector{Any}, analyses)::Vector{Any},
        initialization_equations, guesses, system_kind, reference
    )
end

# The positional form: events and subsystems in field order.
Model(
    variables::AbstractDict{String, ModelVariable}, equations::Vector{Equation},
    discrete_events::Vector{DiscreteEvent}, continuous_events::Vector{ContinuousEvent},
    subsystems::AbstractDict{String}; kwargs...
) = Model(
    variables, equations; discrete_events = discrete_events,
    continuous_events = continuous_events, subsystems = subsystems, kwargs...
)

"""
    Species

Chemical species definition with name and optional properties.
"""
struct Species
    name::String
    units::Union{String, Nothing}
    default::Union{Float64, Nothing}
    description::Union{String, Nothing}
    default_units::Union{String, Nothing}
    constant::Union{Bool, Nothing}

    # Constructor with optional parameters
    Species(name::String; units = nothing, default = nothing, description = nothing, default_units = nothing, constant = nothing) =
        new(name, units, default, description, default_units, constant)
end

"""
    Parameter

A reaction system's parameter (`reaction_systems.*.parameters.*`) — the
reaction-side twin of a [`ModelVariable`](@ref) of `ParameterVariable` type,
and it carries the SAME value model (esm-spec §5.4, §6.3): a `default`, a
`distribution`, a `shape`, and an `update` rule set.

`esm-schema.json`'s `Parameter` declares NO required properties, so `default`
is optional: a parameter valued by a `distribution` — or one whose whole value
is supplied by an `update` binding to a data source — is a legal document with
no `default` at all. It is `Union{Float64,Nothing}` for exactly that reason.

`shape` / `distribution` / `update` are here for the same reason they are on
`ModelVariable`: the schema defines them and a field this struct does not hold
is a field `load` silently drops. `update` is the load-bearing one — an
`update` block is the only channel binding a parameter to a data source
(§5.4), so dropping it does not just lose annotation, it turns a data-driven
parameter into a constant.
"""
struct Parameter
    name::String
    default::Union{Float64, Nothing}
    description::Union{String, Nothing}
    units::Union{String, Nothing}
    default_units::Union{String, Nothing}
    shape::Union{Vector{String}, Nothing}
    distribution::Union{Distribution, Nothing}
    update::Union{Vector{ParameterUpdate}, Nothing}

    # Constructor with optional parameters. `default` stays POSITIONAL (every
    # existing caller passes it there) but is now optional and nullable.
    Parameter(
        name::String, default::Union{Real, Nothing} = nothing;
        description = nothing, units = nothing, default_units = nothing,
        shape = nothing, distribution = nothing, update = nothing
    ) =
        new(
        name, default === nothing ? nothing : Float64(default),
        description, units, default_units,
        shape === nothing ? nothing : Vector{String}(shape),
        distribution, _coerce_update_vector(update)
    )
end


# ========================================
# 6. Data and Operator Types
# ========================================

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
    translate::Union{Dict{String, Any}, Nothing}
    description::Union{String, Nothing}
    lifting::Union{String, Nothing}
    # esm-libraries-spec §4.7.1 step 5, TRI-STATE — `nothing` is NOT `false`:
    #
    #   nothing  the author has not said. A zero-merge is then
    #            `operator_compose_no_merge`, an ERROR (such an entry is
    #            indistinguishable from one that is absent); a partial merge is
    #            a warning.
    #   true     `systems[2]`'s equations are CONTRIBUTIONS and every one must
    #            land; any shortfall, partial included, is a hard refusal.
    #   false    a standalone-contributing operator, DECLARED. Unmatched
    #            equations are expected and nothing is reported.
    require_match::Union{Bool, Nothing}

    CouplingOperatorCompose(
        systems::Vector{String}; translate = nothing,
        description = nothing, lifting = nothing,
        require_match::Union{Bool, Nothing} = nothing
    ) =
        new(systems, translate, description, lifting, require_match)
end

"""
    CouplingCouple <: CouplingEntry

Bi-directional coupling via connector equations.
"""
struct CouplingCouple <: CouplingEntry
    systems::Vector{String}
    connector::Dict{String, Any}
    description::Union{String, Nothing}
    lifting::Union{String, Nothing}

    CouplingCouple(systems::Vector{String}, connector::Dict{String, Any}; description = nothing, lifting = nothing) =
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
    transform::Union{String, ASTExpr}
    factor::Union{Float64, Nothing}
    description::Union{String, Nothing}
    lifting::Union{String, Nothing}

    function CouplingVariableMap(
            from::String, to::String, transform::Union{String, ASTExpr};
            factor = nothing, description = nothing, lifting = nothing
        )
        # SINGLE enforcement point for the "expression transform takes no
        # factor" invariant. The parser (`coerce_variable_map`, parse.jl) does
        # not pre-check; it catches this ArgumentError and raises it as a
        # ParseError with the same message.
        if transform isa ASTExpr && factor !== nothing
            throw(ArgumentError("variable_map: an expression `transform` takes no `factor` (fold the scaling into the expression)"))
        end
        return new(from, to, transform, factor, description, lifting)
    end
end

"""
    CouplingOperatorApply <: CouplingEntry

Register an operator (referenced by name) to run during simulation.
"""
struct CouplingOperatorApply <: CouplingEntry
    operator::String
    description::Union{String, Nothing}

    CouplingOperatorApply(operator::String; description = nothing) =
        new(operator, description)
end

"""
    CouplingCallback <: CouplingEntry

Register a callback for simulation events.
"""
struct CouplingCallback <: CouplingEntry
    callback_id::String
    config::Union{Dict{String, Any}, Nothing}
    description::Union{String, Nothing}

    CouplingCallback(callback_id::String; config = nothing, description = nothing) =
        new(callback_id, config, description)
end

"""
    CouplingEvent <: CouplingEntry

Cross-system event involving variables from multiple coupled systems.
"""
struct CouplingEvent <: CouplingEntry
    event_type::String
    # Human-readable identifier (schema `CouplingEvent.name`), carried for the
    # same reason `ContinuousEvent`/`DiscreteEvent` carry theirs: an authored
    # event must survive parse → emit.
    name::Union{String, Nothing}
    conditions::Union{Vector{ASTExpr}, Nothing}
    trigger::Union{DiscreteEventTrigger, Nothing}
    affects::Vector{AffectEquation}
    affect_neg::Union{Vector{AffectEquation}, Nothing}
    root_find::Union{String, Nothing}
    reinitialize::Union{Bool, Nothing}
    description::Union{String, Nothing}

    CouplingEvent(
        event_type::String, affects::Vector{AffectEquation};
        name = nothing, conditions = nothing, trigger = nothing, affect_neg = nothing,
        root_find = nothing, reinitialize = nothing, description = nothing
    ) =
        new(
        event_type, name, conditions, trigger, affects, affect_neg, root_find,
        reinitialize, description
    )
end

"""
    CouplingImport <: CouplingEntry

Reuse of a coupling-library file (esm-spec §10.9, §10.10). Names a library by
`ref` and binds each of the library's declared roles to a component in the
assembly via `bind` (role name → a top-level `models`/`reaction_systems` key,
or a dotted `Parent.Child` subsystem path). At flatten the
import expands into concrete `variable_map`/`couple`/`operator_compose`/`event`
edges by substituting the bound actual for every role-named top-level segment
(`expand_coupling_imports`); the entry itself round-trips intact.
"""
struct CouplingImport <: CouplingEntry
    ref::String
    bind::Dict{String, String}
    description::Union{String, Nothing}

    CouplingImport(ref::String, bind::AbstractDict = Dict{String, String}(); description = nothing) =
        new(ref, Dict{String, String}(string(k) => string(v) for (k, v) in pairs(bind)), description)
end

"""
    DataSourceLocation

File discovery configuration for a data source (the schema's
`DataSource.source` object). Describes how to locate data files at runtime via
a URL template with `{date:<strftime>}`, `{var}`, `{sector}`, `{species}`, and
custom substitutions. Optional `mirrors` list gives ordered fallback templates.
"""
struct DataSourceLocation
    url_template::String
    mirrors::Union{Vector{String}, Nothing}

    DataSourceLocation(url_template::String; mirrors = nothing) =
        new(url_template, mirrors)
end

"""
    DataSourceTemporal

Temporal coverage and record layout for a data source (esm-spec §8.3). Its
PRESENCE is what makes the source time-varying, and so what keeps a parameter
drawing from it seeded DISCRETE rather than refined to CONST
(CONFORMANCE_SPEC §5.7.2).
"""
struct DataSourceTemporal
    start::Union{String, Nothing}
    stop::Union{String, Nothing}           # field name "end" in JSON (reserved word in Julia)
    file_period::Union{String, Nothing}
    frequency::Union{String, Nothing}
    records_per_file::Union{Int, String, Nothing}  # integer or "auto"
    time_variable::Union{String, Nothing}
    # DEPRECATED (esm-spec §8.3/§8.5.1, removed at esm 3.0.0): the source-wide
    # default of each consumer's deprecated `from.records_per_sample`. Only
    # checked against each consumer's record shape, never obeyed. Distinct
    # from `records_per_file`, which counts records IN one file.
    records_per_sample::Union{Int, Nothing}

    DataSourceTemporal(;
        start = nothing, stop = nothing, file_period = nothing,
        frequency = nothing, records_per_file = nothing,
        time_variable = nothing, records_per_sample = nothing
    ) =
        new(
        start, stop, file_period, frequency, records_per_file, time_variable,
        records_per_sample
    )
end

"""
    DataSourceDeterminism

Reproducibility contract a source advertises to bindings (esm-spec §8.1).
A binding that cannot honor the declared endian / float_format / integer_width
MUST reject the file at load.

Fields (all optional):
- `endian`: "little" | "big"
- `float_format`: "ieee754_single" | "ieee754_double"
- `integer_width`: 32 | 64
"""
struct DataSourceDeterminism
    endian::Union{String, Nothing}
    float_format::Union{String, Nothing}
    integer_width::Union{Int, Nothing}

    DataSourceDeterminism(; endian = nothing, float_format = nothing, integer_width = nothing) =
        new(endian, float_format, integer_width)
end

"""
    DataSource

Generic, runtime-agnostic description of an external dataset (esm-spec §8).
Pure I/O: locate, read, decode, slice, and filter bytes on disk. It performs no
reprojection and no regridding — transferring native fields onto a consuming
model's grid is an ordinary coupling expression (§8.6).

**A data source is a REGISTRY ENTRY, not a component.** It
is not a `SubsystemNode`: it exposes no variables of its own, cannot be a
coupling endpoint or a subsystem, and cannot be the path root of a scoped
reference. A model consumes one by declaring a PARAMETER whose
[`ParameterUpdate`](@ref) names the source and binds one of its file variables
([`DataSourceBinding`](@ref)), and that parameter owns the units: the binding
lives on the consumer, not on this struct.

Carries every property esm-schema.json's `DataSource` defines — the schema sets
`additionalProperties: false`, so the list is closed — for the reason
[`Domain`](@ref) states: a property this struct does not hold is a property
`load` silently drops. The four decode/slice/filter blocks are kept VERBATIM
(raw JSON) because nothing in this package reads them back; their whole job is
to reach the reader that does.

Fields:
- `kind`: "grid" | "points" | "static" (structural kind; scientific role goes in `metadata.tags`)
- `source`: [`DataSourceLocation`](@ref) with url_template + optional mirrors
- `temporal`: optional [`DataSourceTemporal`](@ref)
- `determinism`: optional [`DataSourceDeterminism`](@ref)
- `reader_options`: format-specific DECODE options passed to the reader verbatim (§8)
- `select`: source-level axis selection (schema `DataSourceSelect`)
- `record_filter`: which records of a `points` source are DELIVERED (schema `DataSourceRecordFilter`)
- `extent`: binds the source's delivered record count to a metaparameter (schema `DataSourceExtent`)
- `reference`: optional academic/data-source citation
- `metadata`: optional free-form map (conventionally carries a `tags` array)
"""
struct DataSource
    kind::String
    source::DataSourceLocation
    temporal::Union{DataSourceTemporal, Nothing}
    determinism::Union{DataSourceDeterminism, Nothing}
    reader_options::Union{Dict{String, Any}, Nothing}
    select::Union{Dict{String, Any}, Nothing}
    record_filter::Union{Dict{String, Any}, Nothing}
    extent::Union{Dict{String, Any}, Nothing}
    reference::Union{Reference, Nothing}
    metadata::Union{Dict{String, Any}, Nothing}

    DataSource(
        kind::String, source::DataSourceLocation;
        temporal = nothing,
        determinism = nothing,
        reader_options = nothing,
        select = nothing,
        record_filter = nothing,
        extent = nothing,
        reference = nothing,
        metadata = nothing
    ) =
        new(
        kind, source, temporal, determinism, reader_options, select,
        record_filter, extent, reference, metadata
    )
end

# ========================================
# 7. System Configuration Types
# ========================================

"""
    Domain

Spatial and temporal domain specification.

Carries every field esm-schema.json's `Domain` defines — the schema sets
`additionalProperties: false`, so this list is closed — because a flattened
system is required to reproduce "the file's `domain` section, unchanged"
(esm-libraries-spec §4.7.5 step 4). A field this type does not hold is a field
`load` silently drops.
"""
struct Domain
    # The name of the independent (time) variable, `"t"` unless the document
    # renames it. Validation reads it: the independent variable is implicitly
    # declared under this name and no other.
    independent_variable::String
    temporal::Union{Dict{String, Any}, Nothing}
    # Floating-point precision and array backend (esm-schema.json `Domain`:
    # `element_type` ∈ {"Float32","Float64"}, `array_type` e.g. "Array" /
    # "CuArray"). They decide behaviour downstream (Float32 vs Float64 for the
    # assembled problem, host vs GPU arrays), and esm-libraries-spec §4.7.5
    # step 4 says a `FlattenedSystem`
    # carries "the file's `domain` section, UNCHANGED". `nothing` means the
    # document declared none — absence is preserved rather than replaced by the
    # schema default, so emit round-trips byte-for-byte.
    element_type::Union{String, Nothing}
    array_type::Union{String, Nothing}

    # Constructor with optional parameters
    Domain(;
        independent_variable::AbstractString = "t", temporal = nothing,
        element_type = nothing, array_type = nothing
    ) =
        new(
        String(independent_variable), temporal,
        element_type === nothing ? nothing : String(element_type),
        array_type === nothing ? nothing : String(array_type)
    )
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
            throw(
                ArgumentError(
                    "StoichiometryEntry: stoichiometry must be finite (got $(stoichiometry)) for species '$(species)'"
                )
            )
        end
        if stoichiometry <= 0
            throw(
                ArgumentError(
                    "StoichiometryEntry: stoichiometry must be positive (got $(stoichiometry)) for species '$(species)'"
                )
            )
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
    name::Union{String, Nothing}
    substrates::Union{Vector{StoichiometryEntry}, Nothing}  # null for source reactions (∅ → X)
    products::Union{Vector{StoichiometryEntry}, Nothing}    # null for sink reactions (X → ∅)
    rate::ASTExpr
    reference::Union{Reference, Nothing}

    # Constructor with optional parameters
    Reaction(
        id::String, substrates::Union{Vector{StoichiometryEntry}, Nothing},
        products::Union{Vector{StoichiometryEntry}, Nothing}, rate::ASTExpr;
        name = nothing, reference = nothing
    ) =
        new(id, name, substrates, products, rate, reference)
end

"""
    ReactionSystem

Collection of chemical reactions with associated species, supporting hierarchical composition.

Carries every property esm-schema.json's `ReactionSystem` defines, including
`subsystems` (a reaction-system hierarchy), `constraint_equations` (additional
algebraic/ODE constraints), `continuous_events` / `discrete_events` and
`analyses`, all of which load and serialize. `analyses` is kept VERBATIM for the reason [`Model`](@ref)'s is.
"""
struct ReactionSystem
    species::Vector{Species}
    reactions::Vector{Reaction}
    parameters::Vector{Parameter}
    constraint_equations::Vector{Equation}
    discrete_events::Vector{DiscreteEvent}
    continuous_events::Vector{ContinuousEvent}
    subsystems::OrderedDict{String, ReactionSystem}
    tolerance::Union{Tolerance, Nothing}
    tests::Vector{InlineTest}
    analyses::Vector{Any}
    reference::Union{Reference, Nothing}

    # Constructor with optional parameters and subsystems
    ReactionSystem(
        species::Vector{Species}, reactions::Vector{Reaction};
        parameters = Parameter[], subsystems = OrderedDict{String, ReactionSystem}(),
        constraint_equations = Equation[],
        discrete_events = DiscreteEvent[],
        continuous_events = ContinuousEvent[],
        tolerance = nothing, tests = InlineTest[], analyses = Any[],
        reference = nothing
    ) =
        new(
        species, reactions, parameters, constraint_equations,
        discrete_events, continuous_events,
        OrderedDict{String, ReactionSystem}(subsystems), tolerance, tests,
        _dynamic(Vector{Any}, analyses)::Vector{Any}, reference
    )
end

"""
    Metadata

Authorship, provenance, and description metadata.

Carries every property esm-schema.json's `Metadata` defines — it too sets
`additionalProperties: false`, so the list is closed. Beyond the authorship
block that is the three discretization diagnostics (`system_class`, `dae_info`,
`discretized_from`; RFC §12) and `x_esd`.

`x_esd`'s schema description is NORMATIVE about this struct's job: it is a
reserved extension point whose contents "core tooling MUST NOT assign meaning
to" and "MUST preserve … across parse → emit like any other metadata field".
All four are therefore kept VERBATIM and never interpreted.
"""
struct Metadata
    name::String
    description::Union{String, Nothing}
    authors::Vector{String}
    license::Union{String, Nothing}
    created::Union{String, Nothing}  # ISO 8601 timestamp
    modified::Union{String, Nothing} # ISO 8601 timestamp
    tags::Vector{String}
    references::Vector{Reference}
    system_class::Union{String, Nothing}          # "ode" | "dae"
    dae_info::Union{Dict{String, Any}, Nothing}
    discretized_from::Union{Dict{String, Any}, Nothing}
    x_esd::Union{Dict{String, Any}, Nothing}

    # Constructor with optional parameters
    Metadata(
        name::String;
        description = nothing,
        authors = String[],
        license = nothing,
        created = nothing,
        modified = nothing,
        tags = String[],
        references = Reference[],
        system_class = nothing,
        dae_info = nothing,
        discretized_from = nothing,
        x_esd = nothing
    ) =
        new(
        name, description, authors, license, created, modified, tags,
        references, system_class, dae_info, discretized_from, x_esd
    )
end

"""
    EsmFile

Main ESM file structure containing all components.

`models`, `reaction_systems`, `index_sets` and
`component_templates` are `OrderedDict`s populated by the parser in DOCUMENT
ORDER — see [`Model`](@ref) for why, and esm-libraries-spec §4.7.5 step 4 for the
normative rule.
"""
struct EsmFile
    esm::String  # Version string
    metadata::Metadata
    models::Union{OrderedDict{String, Model}, Nothing}
    reaction_systems::Union{OrderedDict{String, ReactionSystem}, Nothing}
    # Document-scoped INGEST REGISTRY (esm-spec §8). Not components: a data
    # source is not a coupling endpoint, not a subsystem, and not the path root
    # of a scoped reference. A model consumes one through a parameter whose
    # `update` names it.
    data_sources::Union{Dict{String, DataSource}, Nothing}
    coupling::Vector{CouplingEntry}
    # The single temporal domain shared by every component in the document
    # (esm-spec v0.8.0: top-level `domain`, not a map of named domains). A
    # document has at most one Domain; 0-D models simply have scalar-shaped
    # variables and spatial models are shaped over index sets.
    domain::Union{Domain, Nothing}
    # File-local enum mappings used by the `enum` AST op (esm-spec §9.3).
    # Keys are enum names; each value maps a symbol → integer (any integer:
    # a member is a categorical code, not a 1-based position).
    # `enum`-op nodes are lowered to `const`-int nodes at load time, so the
    # in-memory expression tree never carries enum strings.
    enums::Union{Dict{String, Dict{String, Int}}, Nothing}
    # Document-scoped index-set registry (RFC semiring-faq-unified-ir §5.2;
    # esm-spec v0.8.0). A single registry, sibling of `models`/`domain`, shared
    # by every component: `ranges[*]` `{from: <name>}` references, array-variable
    # `shape`s, and derived-set `from_faq` edges resolve against it. Empty when
    # the document declares none.
    index_sets::OrderedDict{String, IndexSet}

    # The top-level `expression_templates` registry and `metaparameters` block,
    # PRESERVED VERBATIM (raw JSON) across parse → emit.
    #
    # Option A expands CALL SITES; it does not delete DECLARATIONS (esm-spec
    # §9.6.4 rule 5): a template library (a file whose only payload is
    # `expression_templates`, tests/valid/template_import_lib.esm) emits to
    # itself, and so passes the post-expansion schema validation of rule 4.
    #
    # They are kept raw rather than typed because nothing in the pipeline reads
    # them back after lowering — their only job is to survive the round trip so a
    # library file emits to itself.
    expression_templates::Union{Dict{String, Any}, Nothing}
    metaparameters::Union{Dict{String, Any}, Nothing}

    # Per-component MATERIALIZED template registries (esm-spec §9.6.4 rule 5,
    # Option B reference-preserving round-trip). Keyed by "<compkind>.<cname>"
    # (e.g. "models.Advection"), each value is the emitted `expression_templates`
    # block a component's surviving `apply_expression_template` references
    # materialize into — authored entries first, then the reference closure. The
    # component's equations/variables carry the surviving references as typed
    # `apply_expression_template` `OpExpr`s; `serialize_esm_file` re-injects these
    # blocks so `to_json(EsmFile)` emits the reference-preserving form byte-identically
    # to `emit_document`. `nothing` for a document with no surviving
    # references.
    component_templates::Union{OrderedDict{String, Any}, Nothing}

    # Document-scoped `coordinates` registry (streaming-output-sinks RFC §8.3): each
    # entry marks an existing data array (by `source` name) or an inline `values`
    # vector as a CF coordinate and attaches `standard_name`/`units`/`axis`.
    # PRESERVED VERBATIM across parse → emit, exactly like `metaparameters` — nothing
    # in the pipeline reads it back after load; its job is to survive the round trip
    # and be distilled by the streaming-output writer (`derive_output_meta`) into CF
    # dimension/auxiliary coordinate emission. `nothing` when the document declares none.
    coordinates::Union{Dict{String, Any}, Nothing}

    # Coupling-library formal component roles (esm-spec §10.9), PRESERVED
    # VERBATIM like `metaparameters` and `coordinates`.
    #
    # Presence of this key is the SOLE positive identifier of the
    # coupling-library file kind (`_is_coupling_library_doc`,
    # coupling_imports.jl, tests it and nothing else), so it must survive a
    # round trip for a coupling library to stay one.
    coupling_roles::Union{Dict{String, Any}, Nothing}

    # Document-scoped, OPTIONAL and purely ADVISORY solver hints (esm-spec
    # §2.2): stiffness, integration tolerances and a splitting hint the document
    # knows about itself. Purely additive — presence changes no equations, no
    # classification and no flattened system. Authored configuration, so it
    # round-trips VERBATIM (§2.2.4 requirement 2). `nothing` when the document
    # declares none, which is NOT a synonym for any default value.
    solver::Union{Solver, Nothing}

    # The absolute, dot-segment-free directory a relative `solver.external`
    # resolves against (esm-spec §2.2.6 *D*), recorded at load: the directory of
    # the file read, or the base a string / in-memory load was given or
    # defaulted to (the working directory). NOT a wire field — it is never
    # emitted, as the other bindings' `document_base` is not — and `nothing` for
    # a document built in memory, which resolves against the working directory
    # at call time.
    document_base::Union{String, Nothing}

    # The directory a relative `coupling_import` ref resolves against (esm-spec
    # §10.10 -> §4.7: "relative to the directory of the referencing file"),
    # recorded at load only when the caller gave a base (`load_path` always
    # has one) and the document has a `coupling_import`. `nothing` leaves
    # `flatten`'s `base_path` in charge. NOT a wire field; never emitted.
    coupling_import_base::Union{String, Nothing}

    # Constructor with optional parameters
    EsmFile(
        esm::String, metadata::Metadata;
        models = nothing,
        reaction_systems = nothing,
        data_sources = nothing,
        coupling = CouplingEntry[],
        domain = nothing,
        enums = nothing,
        index_sets = OrderedDict{String, IndexSet}(),
        expression_templates = nothing,
        metaparameters = nothing,
        component_templates = nothing,
        coordinates = nothing,
        coupling_roles = nothing,
        solver = nothing,
        document_base = nothing,
        coupling_import_base = nothing
    ) =
        new(
        esm, metadata,
        models === nothing ? nothing : OrderedDict{String, Model}(models),
        reaction_systems === nothing ? nothing :
            OrderedDict{String, ReactionSystem}(reaction_systems),
        data_sources,
        coupling, domain, enums,
        OrderedDict{String, IndexSet}(index_sets),
        expression_templates, metaparameters,
        component_templates === nothing ? nothing :
            OrderedDict{String, Any}(component_templates),
        coordinates, coupling_roles, solver, document_base, coupling_import_base
    )
end
