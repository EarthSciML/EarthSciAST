# Operator-vocabulary registry — the single source of truth for the op sets
# that were previously hand-maintained in five parallel `const` Sets ("kept in
# sync with…" comments). The registry is pure data: a load-time table with no
# dependency on the AST types, consulted ONCE at include time to derive the
# per-pass const sets. Nothing on any hot path dispatches through it — the
# scalar/vectorized evaluator ladders (`_eval_node_op` / `_eval_vec_op`) keep
# their if/elseif form, and the derived Sets keep their original names, files,
# and element types, so runtime behavior (set membership, dispatch, error
# codes) is bit-identical to the hand-maintained originals. Memberships are
# pinned literal-for-literal by test/op_registry_test.jl.

"""
    _OpSpec

One row of the operator registry ([`_OP_TABLE`](@ref)): the wire-form op name
(esm-spec §4.2 spelling), its argument-count range, a coarse category, the
scalar Julia function behind its elementwise evaluator arm (when one exists),
and the boolean membership flags from which the per-pass op sets derive.

Fields:

- `name::String` — the op string as it appears on the wire (and in `OpExpr.op`).
- `arity::Union{UnitRange{Int},Nothing}` — nominal accepted argument count
  (`1:1` unary, `2:2` binary, `1:2` for `-`/`atan`, `2:typemax(Int)` n-ary,
  `0:0` niladic constants). INFORMATIONAL: arity enforcement stays in the
  evaluator ladders (`_expect_arity_n` and the per-arm guards), which are the
  conformance-pinned error source; `nothing` for structural ops whose argument
  conventions live outside the scalar ladders.
- `category::Symbol` — coarse family, one of `:arithmetic`, `:comparison`,
  `:logical`, `:control`, `:elementary`, `:constant`, `:calculus`, `:array`,
  `:aggregate`, `:function`, `:data`, `:geometry`, `:value_invention`.
- `scalar_fn::Union{Function,Nothing}` — the scalar Julia function the
  elementwise evaluator arms apply per value/lane (`sin`, `+`, …). For the
  comparison ops this is the Base predicate (`<`, `==`, …); the evaluator arms
  additionally map its `Bool` through `1.0`/`0.0` (spec comparison semantics).
  `nothing` where the arm's semantics are not a single Base function
  (`and`/`or`/`not`/`ifelse`/`Pre`, constants, structural ops).
- flag fields — see [`_OP_FLAG_NAMES`](@ref).
"""
struct _OpSpec
    name::String
    arity::Union{UnitRange{Int},Nothing}
    category::Symbol
    scalar_fn::Union{Function,Nothing}
    ws4_foldable::Bool
    cse_opaque::Bool
    stencil_elementwise::Bool
    geo_eval::Bool
    mtk_known::Bool
    spatial::Bool
    dim_spatial::Bool
    array_producer::Bool
    self_indexed::Bool
end

# Compact row constructor for `_OP_TABLE` (keyword flags keep the table
# readable; every flag defaults to false).
_op(name::String; arity=nothing, category::Symbol, fn=nothing,
    ws4::Bool=false, cse::Bool=false, stencil::Bool=false,
    geo::Bool=false, known::Bool=false, spatial::Bool=false,
    dimsp::Bool=false, arrprod::Bool=false, selfidx::Bool=false) =
    _OpSpec(name, arity, category, fn, ws4, cse, stencil, geo, known,
            spatial, dimsp, arrprod, selfidx)

"""
    _OP_FLAG_NAMES

The membership-flag fields of [`_OpSpec`](@ref), one per derived const set:

- `:ws4_foldable`       → `_WS4_FOLDABLE_ELEMENTWISE_OPS` (tree_walk/build_helpers.jl)
- `:cse_opaque`         → `_CSE_OPAQUE_OPS`               (tree_walk/compile.jl)
- `:stencil_elementwise`→ `_STENCIL_ELEMENTWISE_OPS`      (tree_walk/stencil.jl)
- `:geo_eval`           → `_GEO_EVAL_OPS`                 (tree_walk/geometry_setup.jl)
- `:mtk_known`          → `_KNOWN_OPS`                    (ext/EarthSciASTMTKExt.jl)
- `:spatial`            → `_SPATIAL_OPS`                  (flatten.jl)
- `:dim_spatial`        → `_DIM_SPATIAL_OPS`              (flatten.jl)
- `:array_producer`     → `_ARRAY_PRODUCER_OPS`           (shape_promotion.jl)
- `:self_indexed`       → `_SELF_INDEXED_OPS`             (shape_promotion.jl)
"""
const _OP_FLAG_NAMES =
    (:ws4_foldable, :cse_opaque, :stencil_elementwise, :geo_eval, :mtk_known,
     :spatial, :dim_spatial, :array_producer, :self_indexed)

"""
    _OP_TABLE

The operator registry. **To add (or re-classify) an operator, edit this table**
— the following consts derive from it at load time and must NOT be edited by
hand:

- `_WS4_FOLDABLE_ELEMENTWISE_OPS` (src/tree_walk/build_helpers.jl) — elementwise
  ops the WS4 array-observed fold may inline; every member MUST have a scalar
  arm in `_eval_node_op` (see the invariant comment at its definition site).
- `_CSE_OPAQUE_OPS` (src/tree_walk/compile.jl) — ops `_compile` handles
  specially; CSE never hoists through them.
- `_STENCIL_ELEMENTWISE_OPS` (src/tree_walk/stencil.jl) — pure-elementwise ops
  the symbolic stencil fast path whitelists.
- `_GEO_EVAL_OPS` (src/tree_walk/geometry_setup.jl) — the exact vocabulary the
  setup-time geometry evaluator (`_geo_eval` / `_geo_apply_scalar`) speaks.
- `_KNOWN_OPS` (ext/EarthSciASTMTKExt.jl) — ops the MTK exporter recognizes;
  anything else is flagged as a likely registered-function gap (gt-p3ep).
- `_SPATIAL_OPS` / `_DIM_SPATIAL_OPS` (src/flatten.jl) — the spatial
  differential operators the flatten pipeline detects (`_DIM_SPATIAL_OPS` are
  the subset carrying an explicit `dim` field; `laplacian` does not — it
  implies the domain's full spatial axes).
- `_ARRAY_PRODUCER_OPS` / `_SELF_INDEXED_OPS` (src/shape_promotion.jl) —
  array-producing nodes for the shape-promotion / pointwise-lift rewrites,
  and the nodes that carry their own indexing (the producers plus `index`),
  which the leaf-indexing rewrites never descend into.
- [`_UNARY_ELEMENTWISE_OPS`](@ref), [`_COMPARISON_ELEMENTWISE_OPS`](@ref),
  [`_BINARY_ELEMENTWISE_OPS`](@ref), [`_NARY_MINMAX_OPS`](@ref) — the ordered
  mechanical ladder-arm tables the evaluator ladders generate their arms from
  (derived by filter, not by flag).

Membership is BEHAVIOR: these sets gate fold/CSE/fast-path/materialization
decisions with cross-language conformance consequences, so every flag change
must be deliberate and is pinned by test/op_registry_test.jl (update the
literal there in the same commit, citing the spec section that motivates the
change). Row order is meaningful only for the derived ordered table
`_UNARY_ELEMENTWISE_OPS`, which preserves it — the elementary rows below are
listed in the `_eval_node_op` / `_eval_vec_op` ladder-arm order.
"""
const _OP_TABLE = _OpSpec[
    # ── Arithmetic (esm-spec §4.2; `neg`/`pow` are the canonicalize-internal
    #    aliases `canonicalize` may introduce for unary `-` / `^`) ──
    _op("+";   arity=1:typemax(Int), category=:arithmetic, fn=(+),
        ws4=true, stencil=true, geo=true, known=true),
    _op("-";   arity=1:2,            category=:arithmetic, fn=(-),
        ws4=true, stencil=true, geo=true, known=true),
    _op("*";   arity=1:typemax(Int), category=:arithmetic, fn=(*),
        ws4=true, stencil=true, geo=true, known=true),
    _op("/";   arity=2:2,            category=:arithmetic, fn=(/),
        ws4=true, stencil=true, geo=true, known=true),
    _op("^";   arity=2:2,            category=:arithmetic, fn=(^),
        ws4=true, stencil=true, geo=true, known=true),
    _op("pow"; arity=2:2,            category=:arithmetic, fn=(^),
        ws4=true, stencil=true),
    _op("neg"; arity=1:1,            category=:arithmetic, fn=(-),
        ws4=true, stencil=true),

    # ── Comparisons → 1.0/0.0 (spec comparison semantics) ──
    _op("<";  arity=2:2, category=:comparison, fn=(<),
        stencil=true, geo=true, known=true),
    _op("<="; arity=2:2, category=:comparison, fn=(<=),
        stencil=true, geo=true, known=true),
    _op(">";  arity=2:2, category=:comparison, fn=(>),
        stencil=true, geo=true, known=true),
    _op(">="; arity=2:2, category=:comparison, fn=(>=),
        stencil=true, geo=true, known=true),
    _op("=="; arity=2:2, category=:comparison, fn=(==),
        stencil=true, geo=true, known=true),
    _op("!="; arity=2:2, category=:comparison, fn=(!=),
        stencil=true, geo=true, known=true),

    # ── Logical (n-ary and/or fold in child order; no single Base scalar fn —
    #    the arms carry the 0.0/1.0 truth-value convention) ──
    _op("and"; arity=2:typemax(Int), category=:logical, stencil=true),
    _op("or";  arity=2:typemax(Int), category=:logical, stencil=true),
    _op("not"; arity=1:1,            category=:logical, stencil=true),

    # ── Control (`ifelse` tests its condition `!= 0`; `Pre` is the MTK
    #    previous-value marker, a pass-through on the tree-walk path) ──
    _op("ifelse"; arity=3:3, category=:control,
        stencil=true, geo=true, known=true),
    _op("Pre";    arity=1:1, category=:control, stencil=true, known=true),

    # ── Elementary functions, in `_eval_node_op` / `_eval_vec_op` ladder-arm
    #    order (the derived `_UNARY_ELEMENTWISE_OPS` table preserves this
    #    order). `atan` is 1-or-2-ary (NOT mechanical-unary); `atan2` is the
    #    explicit 2-ary spelling. ──
    _op("sin";   arity=1:1, category=:elementary, fn=sin,
        ws4=true, stencil=true, geo=true, known=true),
    _op("cos";   arity=1:1, category=:elementary, fn=cos,
        ws4=true, stencil=true, geo=true, known=true),
    _op("tan";   arity=1:1, category=:elementary, fn=tan,
        ws4=true, stencil=true, known=true),
    _op("asin";  arity=1:1, category=:elementary, fn=asin,
        ws4=true, stencil=true, known=true),
    _op("acos";  arity=1:1, category=:elementary, fn=acos,
        ws4=true, stencil=true, known=true),
    _op("atan";  arity=1:2, category=:elementary, fn=atan,
        ws4=true, stencil=true, known=true),
    _op("atan2"; arity=2:2, category=:elementary, fn=atan,
        stencil=true, geo=true),
    _op("sinh";  arity=1:1, category=:elementary, fn=sinh,
        ws4=true, stencil=true, known=true),
    _op("cosh";  arity=1:1, category=:elementary, fn=cosh,
        ws4=true, stencil=true, known=true),
    _op("tanh";  arity=1:1, category=:elementary, fn=tanh,
        ws4=true, stencil=true, known=true),
    _op("asinh"; arity=1:1, category=:elementary, fn=asinh, stencil=true),
    _op("acosh"; arity=1:1, category=:elementary, fn=acosh, stencil=true),
    _op("atanh"; arity=1:1, category=:elementary, fn=atanh, stencil=true),
    _op("exp";   arity=1:1, category=:elementary, fn=exp,
        ws4=true, stencil=true, known=true),
    _op("log";   arity=1:1, category=:elementary, fn=log,
        ws4=true, stencil=true, known=true),
    _op("log10"; arity=1:1, category=:elementary, fn=log10,
        ws4=true, stencil=true, known=true),
    _op("sqrt";  arity=1:1, category=:elementary, fn=sqrt,
        ws4=true, stencil=true, geo=true, known=true),
    _op("abs";   arity=1:1, category=:elementary, fn=abs,
        ws4=true, stencil=true, geo=true, known=true),
    _op("sign";  arity=1:1, category=:elementary, fn=sign,
        ws4=true, stencil=true),
    _op("floor"; arity=1:1, category=:elementary, fn=floor,
        ws4=true, stencil=true, geo=true),
    _op("ceil";  arity=1:1, category=:elementary, fn=ceil,
        ws4=true, stencil=true, geo=true),
    _op("min"; arity=2:typemax(Int), category=:elementary, fn=min,
        ws4=true, stencil=true, geo=true, known=true),
    _op("max"; arity=2:typemax(Int), category=:elementary, fn=max,
        ws4=true, stencil=true, geo=true, known=true),

    # ── Niladic constants (`true`/`false` appear only in the geometry-setup
    #    vocabulary — `_geo_eval` resolves them; the scalar ladders don't) ──
    _op("pi";    arity=0:0, category=:constant, stencil=true),
    _op("π";     arity=0:0, category=:constant, stencil=true),
    _op("e";     arity=0:0, category=:constant, stencil=true),
    _op("true";  arity=0:0, category=:constant, geo=true),
    _op("false"; arity=0:0, category=:constant, geo=true),

    # ── Closed functions & the retired v0.2.x closure marker (esm-spec §9.2) ──
    #    `fn` is NOT `cse_opaque`: a closed-function call is a pure, deterministic
    #    scalar function of its scalar args (the `interp.*` / `datetime.*` registry
    #    is closed), so both the call and the subexpressions beneath it are sound
    #    CSE hoist candidates. Flagging it opaque made every closed-function call a
    #    sharing BARRIER, so an observed chain reaching a costly subtree through an
    #    `interp.*` lookup (FastJX actinic-flux bands over `Solar.cos_zenith`) was
    #    re-walked once per occurrence — see `_CSE_OPAQUE_OPS` (tree_walk/compile.jl).
    #    `call` stays opaque: it was removed in v0.3.0 and always throws at compile.
    _op("fn";   category=:function, known=true),
    _op("call"; category=:function, cse=true, known=true),

    # ── Const data / enum markers ──
    _op("const"; category=:data, cse=true),
    _op("enum";  category=:data, cse=true),

    # ── Calculus / initial-condition markers (resolved or rejected at build
    #    time; never scalar-evaluated) ──
    _op("D";         category=:calculus, cse=true, known=true),
    _op("ic";        category=:calculus, cse=true, known=true),
    _op("grad";      category=:calculus, cse=true, known=true,
        spatial=true, dimsp=true),
    _op("div";       category=:calculus, cse=true, known=true,
        spatial=true, dimsp=true),
    _op("laplacian"; category=:calculus, cse=true, known=true, spatial=true),

    # ── Array producers / gathers / reshapes ──
    _op("index";     category=:array, cse=true, geo=true, known=true,
        selfidx=true),
    _op("makearray"; category=:array, cse=true, known=true,
        arrprod=true, selfidx=true),
    _op("broadcast"; category=:array, cse=true, known=true),
    _op("reshape";   category=:array, cse=true, known=true),
    _op("transpose"; category=:array, cse=true, known=true),
    _op("concat";    category=:array, cse=true, known=true),

    # ── Aggregates (semiring FAQ; RFC §5.3/§7.2) ──
    _op("arrayop";   category=:aggregate, cse=true, geo=true, known=true,
        arrprod=true, selfidx=true),
    _op("aggregate"; category=:aggregate, cse=true, geo=true, known=true,
        arrprod=true, selfidx=true),

    # ── Geometry kernel leaves (RFC §8.1) & value invention (RFC §5.5) ──
    _op("intersect_polygon";         category=:geometry, geo=true),
    _op("polygon_intersection_area"; category=:geometry, geo=true),
    _op("skolem";                    category=:value_invention, geo=true),
]

# Name → spec lookup (load-time derived; ops are unique by construction —
# duplicate names would silently shadow, so the ctor loop asserts uniqueness).
const _OP_INDEX = let idx = Dict{String,_OpSpec}()
    for s in _OP_TABLE
        haskey(idx, s.name) && error("op_registry: duplicate op '$(s.name)'")
        idx[s.name] = s
    end
    idx
end

"""
    _op_spec(name::AbstractString) -> Union{_OpSpec,Nothing}

The registry row for op `name`, or `nothing` for an op outside the registry
(a registered-function name, a template op, …).
"""
_op_spec(name::AbstractString) = get(_OP_INDEX, String(name), nothing)

"""
    _ops_with(flag::Symbol) -> Set{String}

The op names whose [`_OpSpec`](@ref) has `flag` set — the derivation behind
each per-pass const set (`flag` must be one of [`_OP_FLAG_NAMES`](@ref)).
Called once per derived const at include time; never on a hot path.
"""
function _ops_with(flag::Symbol)::Set{String}
    flag in _OP_FLAG_NAMES ||
        throw(ArgumentError("op_registry: unknown flag $flag (expected one of " *
                            "$(join(_OP_FLAG_NAMES, ", "))"))
    return Set{String}(s.name for s in _OP_TABLE if getfield(s, flag))
end

"""
    _UNARY_ELEMENTWISE_OPS

Ordered table of the MECHANICAL unary elementwise ops — exactly the ops whose
scalar/vectorized evaluator arms are the repetitive one-liners
(`op === :sin → sin(x)` / `@. b = sin(c1)`): the `:elementary` registry rows
with fixed arity `1:1` and a recorded scalar function. Each entry is
`(name::String, sym::Symbol, fn::Function)`; order is the registry row order,
which matches the current `_eval_node_op` / `_eval_vec_op` arm order.

`atan` (1-or-2-ary), the arithmetic `neg` (`-x`), and the truth-valued `not`
are deliberately NOT here — their arms are not mechanical applications of a
unary scalar function. Intended consumer: `@eval`-generation of the unary
ladder arms and the MTK `_build_broadcast` function map, so a new unary op
added to `_OP_TABLE` grows every arm at once.
"""
const _UNARY_ELEMENTWISE_OPS = Tuple(
    (name = s.name, sym = Symbol(s.name), fn = s.scalar_fn::Function)
    for s in _OP_TABLE
    if s.category === :elementary && s.arity == 1:1 && s.scalar_fn !== nothing)

# The row shape shared by the three generated-ladder tables below. `sym` is the
# op symbol the ladder arm MATCHES (`OpExpr.op` as a Symbol); `fnsym` is the
# module-scope function name the generated arm CALLS — they differ exactly for
# the alias rows (`pow` calls `^`, `atan2` calls `atan`). Splicing `fnsym` as a
# call reproduces the hand-written arm's AST verbatim (`a < b` IS
# `(<)(a, b)`), so the generated methods compile to the same branches, and `@.`
# / broadcast fusion in the vectorized/oop consumers is unchanged. `fn` is kept
# so load-time guards can assert `fnsym` still resolves to it in module scope.
_ladder_row(s::_OpSpec) =
    (name = s.name, sym = Symbol(s.name),
     fnsym = nameof(s.scalar_fn::Function), fn = s.scalar_fn::Function)

"""
    _COMPARISON_ELEMENTWISE_OPS

Ordered table of the MECHANICAL comparison arms — the `:comparison` registry
rows, in registry (= hand-ladder) order: `<`, `<=`, `>`, `>=`, `==`, `!=`.
Every evaluator ladder applies the Base predicate and maps its `Bool` through
`1.0`/`0.0` (spec comparison semantics); the per-ladder arm shape (scalar
ternary, `@.` blend, broadcast blend) lives with each generator. Consumers:
`_eval_node_comparison` (compile.jl), `_eval_vec_comparison` (vectorize.jl),
`_oop_comparison` (oop.jl), `_eval_acc_comparison` (access_kernel.jl).
"""
const _COMPARISON_ELEMENTWISE_OPS = Tuple(
    _ladder_row(s) for s in _OP_TABLE if s.category === :comparison)

"""
    _BINARY_ELEMENTWISE_OPS

Ordered table of the MECHANICAL fixed-2-ary elementwise arms: the registry's
arithmetic/elementary rows with arity exactly `2:2` and a recorded scalar
function — `/`, `^`, `pow` (the canonicalize-internal `^` alias), `atan2` (the
explicit 2-ary `atan` spelling). NOTE the `^`/`pow` arms are mechanical only
because the literal-exponent protection lives in the LEAVES, not the arm: a
literal/const exponent stays `Float64` at every value type (see the `^` notes
at `_eval_node`'s and `_eval_vec`'s literal kinds), so the generated
`x ^ y` lands on `Dual^Float64` — the power rule — exactly as the hand arms
did. Same four consumers as [`_COMPARISON_ELEMENTWISE_OPS`](@ref).
"""
const _BINARY_ELEMENTWISE_OPS = Tuple(
    _ladder_row(s) for s in _OP_TABLE
    if (s.category === :arithmetic || s.category === :elementary) &&
       s.arity == 2:2 && s.scalar_fn !== nothing)

"""
    _NARY_MINMAX_OPS

Ordered table of the MECHANICAL n-ary fold arms with a ≥2-arity guard: the
elementary rows with arity `2:typemax` — `min`, `max` (esm-spec §4.2). The
n-ary `+`/`*` are deliberately NOT here: their 1-ary form is a pass-through
(and, on the vectorized ladder, returns the CHILD's buffer — a property
`_vk_hoistable` depends on), so those arms are semantic, not mechanical. Same
four consumers as [`_COMPARISON_ELEMENTWISE_OPS`](@ref).
"""
const _NARY_MINMAX_OPS = Tuple(
    _ladder_row(s) for s in _OP_TABLE
    if s.category === :elementary && s.arity == 2:typemax(Int))

# Load-time guard for the symbol-spliced generated arms: each recorded function
# name must resolve, in THIS module's scope, to the registry's recorded
# function — so a future shadowing of e.g. `min` or `==` cannot silently desync
# the generated ladders from their `_OP_TABLE` rows. (`_UNARY_ELEMENTWISE_OPS`
# gets the equivalent check in vectorize.jl, next to its first consumer.)
for _t in (_COMPARISON_ELEMENTWISE_OPS, _BINARY_ELEMENTWISE_OPS, _NARY_MINMAX_OPS)
    for _row in _t
        getfield(@__MODULE__, _row.fnsym) === _row.fn ||
            error("op_registry: generated-ladder op '$(_row.name)' does not " *
                  "resolve to its recorded scalar function in module scope")
    end
end
