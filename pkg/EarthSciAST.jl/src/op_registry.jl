# Operator-vocabulary registry: the one table of the operator vocabulary. The
# registry is pure data: a load-time table with no dependency on the AST types.
# The per-pass op sets derive from it at include time, and the evaluator ladders
# (`_eval_node_op`, `_eval_acc_op`, `_scalar_op`) and the Julia emitter
# (`_cg_emit_op`) are GENERATED from its `shape` column at include time
# (tree_walk/op_ladder.jl), so nothing on a hot path looks it up at run time.
# Memberships are pinned literal-for-literal by test/op_registry_test.jl.

"""
    _OpSpec

One row of the operator registry ([`_OP_TABLE`](@ref)): the wire-form op name
(esm-spec §4.2 spelling), its argument-count range, a coarse category, the
scalar Julia function behind its elementwise evaluator arm (when one exists),
and the boolean membership flags from which the per-pass op sets derive.

Fields:

- `name::String` — the op string as it appears on the wire (and in `OpExpr.op`).
- `arity::Union{UnitRange{Int},Nothing}` — the accepted argument count
  (`1:1` unary, `2:2` binary, `1:2` for `-`/`atan`, `1:typemax(Int)` or
  `2:typemax(Int)` n-ary, `0:0` niladic constants). NORMATIVE (esm-spec §4.2):
  a node outside it is refused with `E_TREEWALK_ARITY` when the tree walk
  compiles it ([`_check_op_arity`](@ref)), by every evaluator arm and emitter
  generated from the `shape` column, and by the ModelingToolkit and Catalyst
  lowerings; an n-ary operator folds every operand. `nothing` for structural
  ops whose argument conventions live outside the scalar ladders.
- `category::Symbol` — coarse family, one of `:arithmetic`, `:comparison`,
  `:logical`, `:control`, `:elementary`, `:constant`, `:calculus`, `:array`,
  `:aggregate`, `:data`, `:value_invention`.
- `scalar_fn::Union{Function,Nothing}` — the scalar Julia function the
  elementwise evaluator arms apply per value/lane (`sin`, `+`, …). For the
  comparison ops this is the Base predicate (`<`, `==`, …); the evaluator arms
  additionally map its `Bool` through `1.0`/`0.0` (spec comparison semantics).
  `nothing` where the arm's semantics are not a single Base function
  (`and`/`or`/`not`/`ifelse`/`Pre`, constants, structural ops).
- `shape::Union{Symbol,Nothing}` — how an evaluator applies the op, one of
  [`_OP_SHAPES`](@ref); the evaluator ladders are generated from it.
  `nothing` for an op no scalar ladder evaluates (structural ops, and the
  `true`/`false` constants, which `_compile_op` folds to literals).
- `lazy_from::Int` — the first operand an evaluator may skip: `2` for `ifelse`
  (only the taken branch runs) and `and`/`or` (they stop at the first decisive
  operand), `0` for every op that evaluates all of its operands.
- `value::Union{Float64,Nothing}` — the value of a niladic constant.
- `dim_class::Union{Symbol,Nothing}` — the op's dimensional-analysis class,
  one of [`_DIM_CLASSES`](@ref) (`:transcendental`, `:circular`,
  `:inverse_circular`, `:comparison`, `:boolean`) or `nothing` for ops with
  either a bespoke dimensional rule (`sqrt` halves its argument's dimension,
  `+` demands commensurate operands, …) or none. Derives the five op-class
  sets units.jl's `_DIMENSION_RULES` is populated from (via
  [`_ops_with_dim_class`](@ref)).
- flag fields — see [`_OP_FLAG_NAMES`](@ref).
"""
struct _OpSpec
    name::String
    arity::Union{UnitRange{Int}, Nothing}
    category::Symbol
    scalar_fn::Union{Function, Nothing}
    shape::Union{Symbol, Nothing}
    lazy_from::Int
    value::Union{Float64, Nothing}
    dim_class::Union{Symbol, Nothing}
    ws4_foldable::Bool
    cse_opaque::Bool
    stencil_elementwise::Bool
    geo_eval::Bool
    mtk_known::Bool
    array_producer::Bool
    self_indexed::Bool
    builtin_fn::Bool
    xcse_expensive::Bool
    shape_remap::Bool
end

# Compact row constructor for `_OP_TABLE` (keyword flags keep the table
# readable; every flag defaults to false).
_op(
    name::String; arity = nothing, category::Symbol, fn = nothing,
    shape::Union{Symbol, Nothing} = nothing, lazy::Int = 0,
    value::Union{Float64, Nothing} = nothing,
    dimclass::Union{Symbol, Nothing} = nothing,
    ws4::Bool = false, cse::Bool = false, stencil::Bool = false,
    geo::Bool = false, known::Bool = false,
    arrprod::Bool = false, selfidx::Bool = false,
    builtin::Bool = false, xcse::Bool = false, remap::Bool = false
) =
    _OpSpec(
    name, arity, category, fn, shape, lazy, value, dimclass,
    ws4, cse, stencil, geo, known,
    arrprod, selfidx, builtin, xcse, remap
)

"""
    _OP_FLAG_NAMES

The membership-flag fields of [`_OpSpec`](@ref), one per derived const set:

- `:ws4_foldable`       → `_WS4_FOLDABLE_ELEMENTWISE_OPS` (tree_walk/build_helpers.jl)
- `:cse_opaque`         → `_CSE_OPAQUE_OPS`               (tree_walk/scalar_cse.jl)
- `:stencil_elementwise`→ `_STENCIL_ELEMENTWISE_OPS`      (tree_walk/stencil.jl)
- `:geo_eval`           → `_GEO_EVAL_OPS`                 (tree_walk/setup_materialize.jl)
- `:mtk_known`          → `_KNOWN_OPS`                    (ext/mtk_ext/export.jl)
- `:array_producer`     → `_ARRAY_PRODUCER_OPS`           (shape_promotion.jl)
- `:self_indexed`       → `_SELF_INDEXED_OPS`             (shape_promotion.jl)
- `:builtin_fn`         → `_BUILTIN_FUNCTION_NAMES`       (validation/references.jl)
- `:xcse_expensive`     → `_XCSE_EXPENSIVE_OPS`           (tree_walk/xcse.jl)
- `:shape_remap`        → `_SHAPE_REMAP_OPS`              (tree_walk/shape_ops.jl) and
                          `_LIFT_WHOLE_ARRAY_OPS`         (pointwise_lift.jl): the ops
                          that restructure a whole array (esm-spec §4.3.5)
"""
const _OP_FLAG_NAMES =
    (
    :ws4_foldable, :cse_opaque, :stencil_elementwise, :geo_eval, :mtk_known,
    :array_producer, :self_indexed, :builtin_fn, :xcse_expensive, :shape_remap,
)

"""
    _OP_TABLE

The operator registry. **To add (or re-classify) an operator, edit this table**
— the following consts derive from it at load time and must NOT be edited by
hand:

- `_WS4_FOLDABLE_ELEMENTWISE_OPS` (src/tree_walk/build_equation_prep.jl) — elementwise
  ops the array-observed fold may inline; every member MUST have a scalar
  arm in `_eval_node_op` (see the invariant comment at its definition site).
- `_CSE_OPAQUE_OPS` (src/tree_walk/scalar_cse.jl) — ops `_compile` handles
  specially; CSE never hoists through them.
- `_STENCIL_ELEMENTWISE_OPS` (src/tree_walk/stencil.jl) — pure-elementwise ops
  the symbolic stencil fast path whitelists.
- `_GEO_EVAL_OPS` (src/tree_walk/setup_materialize.jl) — the exact vocabulary of
  the setup-time geometry language (compiled by `_geo_compile`,
  src/tree_walk/geometry_compile.jl).
- `_KNOWN_OPS` (ext/mtk_ext/export.jl) — ops the MTK exporter recognizes;
  anything else is reported as an `unknown_operator` gap.
- `_ARRAY_PRODUCER_OPS` / `_SELF_INDEXED_OPS` (src/cell_read.jl) —
  array-producing nodes for the shape-promotion / pointwise-lift rewrites,
  and the nodes that carry their own indexing (the producers plus `index`),
  which the leaf-indexing rewrites never descend into.
- `_BUILTIN_FUNCTION_NAMES` (src/validation/references.jl) — bare names the reference
  checker excuses as always-in-scope builtins (mirrors Rust
  `is_builtin_function`, structural.rs).
- `_XCSE_EXPENSIVE_OPS` (src/tree_walk/xcse.jl) — the cross-kernel CSE cost
  gate: closed-function calls and the transcendental / power-class elementary
  ops. Bare arithmetic, comparisons and min/max are not worth a store and K
  loads on their own.
- `_TRANSCENDENTAL_OPS` / `_CIRCULAR_OPS` / `_INVERSE_CIRCULAR_OPS` /
  `_COMPARISON_OPS` / `_BOOLEAN_OPS` (src/units.jl) — the dimensional-rule
  op classes (from the `dim_class` column via
  [`_ops_with_dim_class`](@ref)); `_TRANSCENDENTAL_OPS` additionally unions
  spec-adjacent spellings with no registry row (`ln`/`log2`/`expm1` — see the
  note at its definition site).
- [`_UNARY_ELEMENTWISE_OPS`](@ref), [`_COMPARISON_ELEMENTWISE_OPS`](@ref),
  [`_BINARY_ELEMENTWISE_OPS`](@ref), [`_NARY_MINMAX_OPS`](@ref) — the ordered
  mechanical ladder-arm tables the evaluator ladders generate their arms from
  (derived by filter, not by flag).

These sets gate fold, CSE, fast-path and materialization decisions, and
test/op_registry_test.jl pins each membership literally (update it with any
flag change). Row order is meaningful only for the derived ordered table
`_UNARY_ELEMENTWISE_OPS`, which preserves it — the elementary rows below are
listed in the `_eval_node_op` / `_eval_acc_op` ladder-arm order.
"""
const _OP_TABLE = _OpSpec[
    # ── Arithmetic (esm-spec §4.2; `neg`/`pow` are the DEPRECATED word
    #    spellings of unary `-` / `^` (see `_DEPRECATED_OPS`): the loader rewrites
    #    them away, so they reach the evaluator only from an AST built in code) ──
    _op(
        "+"; shape = :fold, arity = 1:typemax(Int), category = :arithmetic, fn = (+),
        ws4 = true, stencil = true, geo = true, known = true
    ),
    _op(
        "-"; shape = :minus, arity = 1:2, category = :arithmetic, fn = (-),
        ws4 = true, stencil = true, geo = true, known = true
    ),
    _op(
        "*"; shape = :fold, arity = 1:typemax(Int), category = :arithmetic, fn = (*),
        ws4 = true, stencil = true, geo = true, known = true
    ),
    _op(
        "/"; shape = :binary, arity = 2:2, category = :arithmetic, fn = (/),
        ws4 = true, stencil = true, geo = true, known = true
    ),
    _op(
        "^"; shape = :binary, arity = 2:2, category = :arithmetic, fn = (^),
        ws4 = true, stencil = true, geo = true, known = true, xcse = true
    ),
    _op(
        "pow"; shape = :binary, arity = 2:2, category = :arithmetic, fn = (^),
        ws4 = true, stencil = true, xcse = true
    ),
    _op(
        "neg"; shape = :negate, arity = 1:1, category = :arithmetic, fn = (-),
        ws4 = true, stencil = true
    ),

    # ── Comparisons → 1.0/0.0 (spec comparison semantics) ──
    _op(
        "<"; shape = :compare, arity = 2:2, category = :comparison, fn = (<), dimclass = :comparison,
        stencil = true, geo = true, known = true
    ),
    _op(
        "<="; shape = :compare, arity = 2:2, category = :comparison, fn = (<=), dimclass = :comparison,
        stencil = true, geo = true, known = true
    ),
    _op(
        ">"; shape = :compare, arity = 2:2, category = :comparison, fn = (>), dimclass = :comparison,
        stencil = true, geo = true, known = true
    ),
    _op(
        ">="; shape = :compare, arity = 2:2, category = :comparison, fn = (>=), dimclass = :comparison,
        stencil = true, geo = true, known = true
    ),
    _op(
        "=="; shape = :compare, arity = 2:2, category = :comparison, fn = (==), dimclass = :comparison,
        stencil = true, geo = true, known = true
    ),
    _op(
        "!="; shape = :compare, arity = 2:2, category = :comparison, fn = (!=), dimclass = :comparison,
        stencil = true, geo = true, known = true
    ),

    # ── Logical (n-ary and/or fold in child order; no single Base scalar fn —
    #    the arms carry the 0.0/1.0 truth-value convention) ──
    # `geo=true`: a setup-time geometry body may carry a CONTAINMENT PREDICATE,
    # and the canonical spelling of one is `ifelse(and(cmp, cmp, …), …)` — every
    # comparison already carried the flag, so without it here a polygon-area
    # binning body (the shape the pushdown's own conformance corpus uses) could
    # not compile at all. The runtime ladder these lower to already has the
    # `:and` / `:or` / `:not` arms; only the vocabulary gate was missing.
    _op(
        "and"; shape = :and, lazy = 2, arity = 2:typemax(Int), category = :logical, dimclass = :boolean,
        stencil = true, geo = true
    ),
    _op(
        "or"; shape = :or, lazy = 2, arity = 2:typemax(Int), category = :logical, dimclass = :boolean,
        stencil = true, geo = true
    ),
    _op(
        "not"; shape = :not, arity = 1:1, category = :logical, dimclass = :boolean,
        stencil = true, geo = true
    ),

    # ── Control (`ifelse` tests its condition `!= 0`; `Pre` is the MTK
    #    previous-value marker, a pass-through on the tree-walk path) ──
    _op(
        "ifelse"; shape = :select, lazy = 2, arity = 3:3, category = :control, ws4 = true,
        stencil = true, geo = true, known = true, builtin = true
    ),
    _op(
        "Pre"; shape = :passthrough, arity = 1:1, category = :control, stencil = true, known = true,
        builtin = true
    ),

    # ── Elementary functions, in `_eval_node_op` / `_eval_acc_op` ladder-arm
    #    order (the derived `_UNARY_ELEMENTWISE_OPS` table preserves this
    #    order). `atan` is 1-or-2-ary (NOT mechanical-unary); `atan2` is the
    #    explicit 2-ary spelling. ──
    #    All elementary rows are `builtin` (reference-checker excused names).
    #    `dim_class`: circular ops take an angle, inverse-circular ops return
    #    one, transcendentals demand a dimensionless argument; `sqrt` (halves
    #    its dimension) and the dimension-preserving `abs`/`sign`/`floor`/
    #    `ceil`/`min`/`max` have bespoke rules, not a class (units.jl).
    _op(
        "sin"; shape = :unary, arity = 1:1, category = :elementary, fn = sin,
        dimclass = :circular, builtin = true,
        ws4 = true, stencil = true, geo = true, known = true, xcse = true
    ),
    _op(
        "cos"; shape = :unary, arity = 1:1, category = :elementary, fn = cos,
        dimclass = :circular, builtin = true,
        ws4 = true, stencil = true, geo = true, known = true, xcse = true
    ),
    _op(
        "tan"; shape = :unary, arity = 1:1, category = :elementary, fn = tan,
        dimclass = :circular, builtin = true,
        ws4 = true, stencil = true, known = true, xcse = true
    ),
    _op(
        "asin"; shape = :unary, arity = 1:1, category = :elementary, fn = asin,
        dimclass = :inverse_circular, builtin = true,
        ws4 = true, stencil = true, known = true, xcse = true
    ),
    _op(
        "acos"; shape = :unary, arity = 1:1, category = :elementary, fn = acos,
        dimclass = :inverse_circular, builtin = true,
        ws4 = true, stencil = true, known = true, xcse = true
    ),
    _op(
        "atan"; shape = :atan, arity = 1:2, category = :elementary, fn = atan,
        dimclass = :inverse_circular, builtin = true,
        ws4 = true, stencil = true, known = true, xcse = true
    ),
    _op(
        "atan2"; shape = :binary, arity = 2:2, category = :elementary, fn = atan,
        dimclass = :inverse_circular, builtin = true,
        stencil = true, geo = true, xcse = true
    ),
    _op(
        "sinh"; shape = :unary, arity = 1:1, category = :elementary, fn = sinh,
        dimclass = :transcendental, builtin = true,
        ws4 = true, stencil = true, known = true, xcse = true
    ),
    _op(
        "cosh"; shape = :unary, arity = 1:1, category = :elementary, fn = cosh,
        dimclass = :transcendental, builtin = true,
        ws4 = true, stencil = true, known = true, xcse = true
    ),
    _op(
        "tanh"; shape = :unary, arity = 1:1, category = :elementary, fn = tanh,
        dimclass = :transcendental, builtin = true,
        ws4 = true, stencil = true, known = true, xcse = true
    ),
    _op(
        "asinh"; shape = :unary, arity = 1:1, category = :elementary, fn = asinh,
        dimclass = :transcendental, builtin = true, stencil = true, xcse = true
    ),
    _op(
        "acosh"; shape = :unary, arity = 1:1, category = :elementary, fn = acosh,
        dimclass = :transcendental, builtin = true, stencil = true, xcse = true
    ),
    _op(
        "atanh"; shape = :unary, arity = 1:1, category = :elementary, fn = atanh,
        dimclass = :transcendental, builtin = true, stencil = true, xcse = true
    ),
    _op(
        "exp"; shape = :unary, arity = 1:1, category = :elementary, fn = exp,
        dimclass = :transcendental, builtin = true,
        ws4 = true, stencil = true, known = true, xcse = true
    ),
    _op(
        "log"; shape = :unary, arity = 1:1, category = :elementary, fn = log,
        dimclass = :transcendental, builtin = true,
        ws4 = true, stencil = true, known = true, xcse = true
    ),
    _op(
        "log10"; shape = :unary, arity = 1:1, category = :elementary, fn = log10,
        dimclass = :transcendental, builtin = true,
        ws4 = true, stencil = true, known = true, xcse = true
    ),
    _op(
        "sqrt"; shape = :unary, arity = 1:1, category = :elementary, fn = sqrt, builtin = true,
        ws4 = true, stencil = true, geo = true, known = true, xcse = true
    ),
    _op(
        "abs"; shape = :unary, arity = 1:1, category = :elementary, fn = abs, builtin = true,
        ws4 = true, stencil = true, geo = true, known = true
    ),
    _op(
        "sign"; shape = :unary, arity = 1:1, category = :elementary, fn = sign, builtin = true,
        ws4 = true, stencil = true
    ),
    _op(
        "floor"; shape = :unary, arity = 1:1, category = :elementary, fn = floor, builtin = true,
        ws4 = true, stencil = true, geo = true
    ),
    _op(
        "ceil"; shape = :unary, arity = 1:1, category = :elementary, fn = ceil, builtin = true,
        ws4 = true, stencil = true, geo = true
    ),
    _op(
        "min"; shape = :minmax, arity = 2:typemax(Int), category = :elementary, fn = min,
        builtin = true, ws4 = true, stencil = true, geo = true, known = true
    ),
    _op(
        "max"; shape = :minmax, arity = 2:typemax(Int), category = :elementary, fn = max,
        builtin = true, ws4 = true, stencil = true, geo = true, known = true
    ),

    # ── Niladic constants (`true`/`false` have no shape: `_compile_op` and
    #    `_geo_compile` fold them to their `value` as literals, so no scalar
    #    ladder sees them) ──
    _op("pi"; shape = :constant, value = Float64(pi), arity = 0:0, category = :constant, stencil = true),
    _op("π"; shape = :constant, value = Float64(pi), arity = 0:0, category = :constant, stencil = true),
    _op("e"; shape = :constant, value = Float64(ℯ), arity = 0:0, category = :constant, stencil = true),
    _op("true"; value = 1.0, arity = 0:0, category = :constant, geo = true),
    _op("false"; value = 0.0, arity = 0:0, category = :constant, geo = true),

    # ── Const data / enum markers ──
    _op("const"; category = :data, cse = true),
    _op("enum"; category = :data, cse = true),

    # ── Calculus / initial-condition markers (resolved or rejected at build
    #    time; never scalar-evaluated) ──
    #    The former spatial-calculus sugar `grad`/`div`/`laplacian` was
    #    removed at esm 2.4.0 (refused by name at load, `removed_op`) and is
    #    not registered. An open-tier USER op is in the rewrite-target tier T
    #    (`_op_in_T`, templates/rewrite.jl) by having no registry entry: it is a
    #    non-hoistable CSE barrier and is rejected by the GENERIC
    #    `unlowered_operator` gate when no rule lowers it (tree_walk/compile.jl;
    #    pinned by tree_walk_test.jl "unlowered rewrite-target op surfaced
    #    before evaluation"). `D`/`ic` keep `cse=true`: `D` is in T but `ic` is
    #    not, and both stay CSE barriers via their own `_compile_op` arms.
    #    `D`'s arity is FIELD-dependent (esm-spec §4.2 "Arity of `D`"), which is
    #    why the nominal range below is open-ended rather than `1:1`. The
    #    STRUCTURAL time derivative (`wrt == "t"`, or an absent `wrt`) is
    #    evaluable-core, consumed by system assembly, and STRICTLY UNARY — that
    #    half is enforced by the schema's `D`/`wrt:"t"` clause, which every
    #    binding validates against. A REWRITE-TARGET `D` (spatial `wrt`) MAY
    #    carry TRAILING AUXILIARY OPERANDS after `args[1]`: the per-face
    #    boundary/halo values a discretization rule binds as ordinary §9.6.1
    #    wildcards and consumes (§9.6.8). Their count is unbounded — a property
    #    of the scheme, not of the format — and they carry no evaluator
    #    semantics, since a spatial `D` is never evaluated directly. Declaring
    #    the range makes that union EXPLICIT instead of leaving it to `nothing`.
    _op("D"; arity = 1:typemax(Int), category = :calculus, cse = true, known = true),
    _op("ic"; category = :calculus, cse = true, known = true),

    # ── Array producers / gathers / reshapes ──
    _op(
        "index"; category = :array, cse = true, geo = true, known = true,
        selfidx = true
    ),
    _op(
        "makearray"; category = :array, cse = true, known = true,
        arrprod = true, selfidx = true
    ),
    _op("broadcast"; category = :array, cse = true, known = true),
    _op("reshape"; category = :array, cse = true, known = true, remap = true),
    _op("transpose"; category = :array, cse = true, known = true, remap = true),
    _op("concat"; category = :array, cse = true, known = true, remap = true),

    # ── Functional Aggregate Query (semiring FAQ; RFC §5.3/§7.2) ──
    _op(
        "faq"; category = :aggregate, cse = true, geo = true, known = true,
        arrprod = true, selfidx = true
    ),

    # ── Value invention (RFC §5.5). Registered so `distinct` is read as an
    #    evaluable-core op rather than an open-tier rewrite target (`_op_in_T`):
    #    the tree-walk evaluator has no rule for it, so one reaching the build is
    #    refused with `unevaluable_operator`, not `unlowered_operator`. ──
    _op("distinct"; category = :value_invention),
]

"""
    _OP_SHAPES

The legal values of the `shape` column, in the order the generated evaluator
ladders test them (tree_walk/op_ladder.jl); within one shape, rows keep registry
order. The order puts the right-hand side's hot arithmetic first.

- `:fold`        — `+`, `*`: n-ary left fold; one operand is that operand.
- `:minus`       — `-`: negation of one operand, difference of two.
- `:negate`      — `neg`: negation (the deprecated spelling of unary `-`).
- `:binary`      — `/`, `^`, `pow`, `atan2`: `scalar_fn(a, b)`.
- `:compare`     — `<` … `!=`: `scalar_fn(a, b)` mapped to `1.0`/`0.0`.
- `:and`, `:or`  — short-circuit connectives over every operand (`!= 0` is true).
- `:not`         — `1.0` when the operand is `0`, else `0.0`.
- `:select`      — `ifelse(c, a, b)`: `a` when `c != 0`; only the taken branch runs.
- `:unary`       — `scalar_fn(x)`.
- `:atan`        — `atan(y)` or `atan(y, x)`.
- `:minmax`      — `min`, `max`: n-ary left fold of `scalar_fn`.
- `:constant`    — the niladic constants; evaluate to the row's `value`.
- `:passthrough` — `Pre`: its operand's value on the tree-walk path.
"""
const _OP_SHAPES = (
    :fold, :minus, :negate, :binary, :compare, :and, :or, :not, :select,
    :unary, :atan, :minmax, :constant, :passthrough,
)

for _s in _OP_TABLE
    _s.shape === nothing || _s.shape in _OP_SHAPES ||
        error("op_registry: op '$(_s.name)' has unknown shape $(_s.shape)")
    _s.shape === nothing || _s.arity !== nothing ||
        error("op_registry: op '$(_s.name)' has a shape but no arity")
    _s.shape in (:binary, :compare, :unary, :minmax) && _s.scalar_fn === nothing &&
        error("op_registry: op '$(_s.name)' of shape $(_s.shape) has no scalar function")
    (_s.shape === :constant) == (_s.value !== nothing && _s.arity == 0:0 && _s.shape !== nothing) ||
        _s.shape === nothing ||
        error("op_registry: constant op '$(_s.name)' needs a value and arity 0:0")
end

"""
    _SHAPED_OPS

The registry rows that carry a `shape`, in ladder order (see
[`_OP_SHAPES`](@ref)): exactly the operators the generated scalar ladders
evaluate. Each entry is `(name, sym, spec)`.
"""
const _SHAPED_OPS = Tuple(
    (name = s.name, sym = Symbol(s.name), spec = s)
        for sh in _OP_SHAPES for s in _OP_TABLE if s.shape === sh
)

"""
    _SHAPED_OP_SYMS

The operator symbols an `_NK_OP` node may carry: the shaped registry rows.
`_compile_op` refuses any other operator with `unevaluable_operator`, and every
back end checks its own operator table against this set when it loads.
"""
const _SHAPED_OP_SYMS = Set{Symbol}(r.sym for r in _SHAPED_OPS)

# Op symbol → registry row, for the build-time arity and laziness queries.
const _OP_SYM_INDEX = Dict{Symbol, _OpSpec}(Symbol(s.name) => s for s in _OP_TABLE)

"""
    _op_lazy_from(op) -> Int

The registry's `lazy_from` for `op` (a `String` or `Symbol`): the first operand
an evaluator may skip, or `0` when every operand is always evaluated (including
for an op with no registry row). Build-time only.
"""
_op_lazy_from(op::Symbol) = (s = get(_OP_SYM_INDEX, op, nothing); s === nothing ? 0 : s.lazy_from)
_op_lazy_from(op::AbstractString) = (s = _op_spec(op); s === nothing ? 0 : s.lazy_from)

"""
    _op_arg_conditional(op, i::Int) -> Bool

Is operand `i` of `op` evaluated only when a sibling takes a particular value?
True for the operands from `lazy_from` on of `ifelse`, `and` and `or`.
"""
_op_arg_conditional(op, i::Int) = (lf = _op_lazy_from(op); lf > 0 && i >= lf)

# The registry arity as words, for the one arity message every evaluator gives.
function _arity_words(ar::UnitRange{Int})
    first(ar) == last(ar) && return "$(first(ar))"
    last(ar) == typemax(Int) && return "at least $(first(ar))"
    last(ar) == first(ar) + 1 && return "$(first(ar)) or $(last(ar))"
    return "$(first(ar)) to $(last(ar))"
end

"""
    _throw_op_arity(op::Symbol, n::Int)

Raise the `E_TREEWALK_ARITY` error for `op` applied to `n` operands, stating the
registry arity. `@noinline` so an evaluator arm's happy path stays small.
"""
@noinline function _throw_op_arity(op::Symbol, n::Int)
    s = get(_OP_SYM_INDEX, op, nothing)
    want = (s === nothing || s.arity === nothing) ? "a different number of" :
        _arity_words(s.arity::UnitRange{Int})
    throw(TreeWalkError("E_TREEWALK_ARITY", "$op expects $want args, got $n"))
end

"""
    _check_op_arity(op::Symbol, n::Int)

Refuse `n` operands for `op` when the registry arity does not admit them. A no-op
for an op with no registry arity. Called where the tree walk compiles a node, so
no evaluator, emitter or back end receives a node of the wrong arity.
"""
function _check_op_arity(op::Symbol, n::Int)
    s = get(_OP_SYM_INDEX, op, nothing)
    (s === nothing || s.arity === nothing || n in s.arity) && return nothing
    return _throw_op_arity(op, n)
end

"""
    _DEPRECATED_OPS

The deprecated op spellings (esm-spec §4.2 "Deprecated ops"), each mapped to
its replacement: `neg` → unary `-`, `pow` → `^`. Both stay registry rows, so an
AST built in code still evaluates, but the loader rewrites every well-formed
use (a node with the row's arity; any other is left for its arity error) at
the wire boundary with the warning `deprecated_op`, and `canonicalize` never
emits either.
"""
const _DEPRECATED_OPS = Dict{String, String}("neg" => "-", "pow" => "^")

# Name → spec lookup (load-time derived; ops are unique by construction —
# duplicate names would silently shadow, so the ctor loop asserts uniqueness).
const _OP_INDEX = let idx = Dict{String, _OpSpec}()
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
    _op_category(name) -> Union{Symbol,Nothing}

The registry category of op `name` (see [`_OpSpec`](@ref)), or `nothing` for
an op outside the registry. The class predicates below read it, so a test of
a registry property names the property instead of listing op spellings.
"""
_op_category(name::AbstractString) = (s = _op_spec(name); s === nothing ? nothing : s.category)

"`<`, `<=`, `>`, `>=`, `==`, `!=`: a registered comparison."
_is_comparison_op(name::AbstractString) = _op_category(name) === :comparison
"`and`, `or`, `not`: a registered boolean connective."
_is_logical_op(name::AbstractString) = _op_category(name) === :logical
"`D`, `ic`: a registered calculus operator."
_is_calculus_op(name::AbstractString) = _op_category(name) === :calculus

"""
    _is_self_indexed_op(name) -> Bool

An op that carries its own indexing (`faq`, `makearray`, `index`): a rewrite
that indexes array leaves stops at it (the `self_indexed` flag).
"""
_is_self_indexed_op(name::AbstractString) = (s = _op_spec(name); s !== nothing && s.self_indexed)

"""
    _is_guarded_node_op(name, nargs) -> Bool

An op whose evaluation may skip operands (`ifelse`, `and`, `or`: `lazy_from >
0`) applied to an admissible operand count.
"""
function _is_guarded_node_op(name::AbstractString, nargs::Int)
    s = _op_spec(name)
    return s !== nothing && s.lazy_from > 0 && s.arity !== nothing && nargs in s.arity
end

"""
    _ops_with(flag::Symbol) -> Set{String}

The op names whose [`_OpSpec`](@ref) has `flag` set — the derivation behind
each per-pass const set (`flag` must be one of [`_OP_FLAG_NAMES`](@ref)).
Called once per derived const at include time; never on a hot path.
"""
function _ops_with(flag::Symbol)::Set{String}
    flag in _OP_FLAG_NAMES ||
        throw(
        ArgumentError(
            "op_registry: unknown flag $flag (expected one of " *
                "$(join(_OP_FLAG_NAMES, ", "))"
        )
    )
    return Set{String}(s.name for s in _OP_TABLE if getfield(s, flag))
end

"""
    _DIM_CLASSES

The legal values of the `dim_class` column: the dimensional-analysis op
classes units.jl attaches a shared rule to (`_DIMENSION_RULES`):

- `:transcendental`   → `_TRANSCENDENTAL_OPS`   (dimensionless argument)
- `:circular`         → `_CIRCULAR_OPS`         (argument is an angle)
- `:inverse_circular` → `_INVERSE_CIRCULAR_OPS` (result is an angle)
- `:comparison`       → `_COMPARISON_OPS`       (commensurate operands, boolean result)
- `:boolean`          → `_BOOLEAN_OPS`          (boolean connective)
"""
const _DIM_CLASSES =
    (:transcendental, :circular, :inverse_circular, :comparison, :boolean)

"""
    _ops_with_dim_class(class::Symbol) -> Set{String}

The op names whose [`_OpSpec`](@ref) carries `dim_class == class` — the
derivation behind the five units.jl op-class sets (`class` must be one of
[`_DIM_CLASSES`](@ref)). Called once per derived const at include time;
never on a hot path.
"""
function _ops_with_dim_class(class::Symbol)::Set{String}
    class in _DIM_CLASSES ||
        throw(
        ArgumentError(
            "op_registry: unknown dim class $class (expected " *
                "one of $(join(_DIM_CLASSES, ", "))"
        )
    )
    return Set{String}(s.name for s in _OP_TABLE if s.dim_class === class)
end

"""
    _SCALAR_OP_CATEGORIES

The registry [`_OpSpec`](@ref) categories whose ops are SCALAR operators — the
ops that consume and produce scalars and therefore apply element-wise when
lifted over an array. This is the positive half of esm-spec §4.3.4's
"`fn` must name a scalar operator (arithmetic, elementary function,
comparison, etc.)"; its complement is the STRUCTURAL half of the vocabulary —
`:array` (`index`/`makearray`/`broadcast`/`reshape`/`transpose`/`concat`),
`:aggregate` (`faq`), `:calculus` (`D`/`ic`), `:data` (`const`/`enum`),
`:value_invention` — none of which is a scalar operator.

`:constant` (the niladic `pi`/`e`/`true`/`false`) IS a scalar category; a
`broadcast` naming one is nonetheless rejected, by the ARITY half of the
contract (`0:0` admits no operands). Consumers: [`_is_scalar_op`](@ref) and
[`_broadcast_fn_problem`](@ref).
"""
const _SCALAR_OP_CATEGORIES =
    (:arithmetic, :comparison, :logical, :control, :elementary, :constant)

"""
    _is_scalar_op(name::AbstractString) -> Bool

True iff `name` is a REGISTERED op whose category is one of
[`_SCALAR_OP_CATEGORIES`](@ref). An op outside the registry (an open-namespace
rewrite target, a registered-function name, a template op) is NOT a scalar op:
its meaning is supplied by a rewrite rule, so it cannot be applied element-wise
by a `broadcast`.
"""
function _is_scalar_op(name::AbstractString)::Bool
    s = _op_spec(name)
    return s !== nothing && s.category in _SCALAR_OP_CATEGORIES
end

"""
    _is_elementwise_node(e::OpExpr) -> Bool

[`_is_scalar_op`](@ref) lifted to a node: true iff `e` applies element-wise
over array operands. A `broadcast` is element-wise iff its `fn` (default `+`)
is a scalar operator; every other node iff its own `op` is one.
"""
function _is_elementwise_node(e::OpExpr)::Bool
    e.op == "broadcast" && return _is_scalar_op(something(e.fn, "+"))
    return _is_scalar_op(e.op)
end

"""
    _broadcast_fn_problem(fn, nargs::Int) -> Union{Nothing,NamedTuple}

The `broadcast.fn` contract of esm-spec §4.3.4, as pure data: `nothing` when
`fn` is a legal scalar operator for `nargs` operands, otherwise a
`(kind::Symbol, message::String)` naming the defect. `kind` is one of

- `:missing`    — the `broadcast` node carries no `fn` field (or an empty one),
- `:unknown`    — `fn` names no registry op,
- `:non_scalar` — `fn` names a STRUCTURAL op (`faq`, `index`,
                  `makearray`, `D`, …), not a scalar operator,
- `:arity`      — `fn` is a scalar op but `nargs` is outside its arity.

**The rule is `broadcast(fn: F, args)` is legal exactly when `{op: F, args}`
is legal** — the arity bound is the REGISTRY's, not a broadcast-specific one.
Two consequences are deliberate, not accidents of the table:

- a 1-operand `+` / `*` is LEGAL (arity `1:typemax`) and means the identity,
  `+(x) ≡ x` — the shared property corpus emits exactly this node; while
- a 1-operand `min` / `max` is an ERROR (arity `2:typemax`), because esm-spec
  §4.2 says conforming bindings MUST reject `min`/`max` with fewer than two
  arguments; and
- a 2-operand `sin` is an ERROR (arity `1:1`) rather than a silent NaN.

This is the SINGLE source of the contract, shared by the `validate()` finding
`invalid_broadcast_fn` (validation/broadcast.jl), the build-time lowering
`E_TREEWALK_BROADCAST_FN` (tree_walk/build_helpers.jl), and the MTK exporter's
`_build_broadcast` (ext/mtk_ext/lowering.jl) — so a document `validate()`
accepts is exactly one both back ends lower. `kind` distinguishes the four
defects for diagnostics (`details["reason"]`); the DIAGNOSTIC CODE is the single
cross-binding `invalid_broadcast_fn` registered in esm-spec §9.6.6.
"""
function _broadcast_fn_problem(fn, nargs::Int)
    if fn === nothing || (fn isa AbstractString && isempty(fn))
        return (
            kind = :missing,
            message = "'broadcast' requires an 'fn' field naming a scalar " *
                "operator (esm-spec §4.3.4)",
        )
    end
    name = String(fn)
    spec = _op_spec(name)
    if spec === nothing || !(spec.category in _SCALAR_OP_CATEGORIES)
        return (
            kind = spec === nothing ? :unknown : :non_scalar,
            message = "'broadcast' fn '$name' does not name a scalar " *
                "operator (esm-spec §4.3.4)",
        )
    end
    ar = spec.arity
    if ar !== nothing && !(nargs in ar)
        want = first(ar) == last(ar) ? "$(first(ar))" :
            (last(ar) == typemax(Int) ? "$(first(ar))+" : "$(first(ar))-$(last(ar))")
        return (
            kind = :arity,
            message = "'broadcast' fn '$name' takes $want operand(s) but " *
                "the node has $nargs (esm-spec §4.3.4)",
        )
    end
    return nothing
end

"""
    _UNARY_ELEMENTWISE_OPS

The `:unary`-shaped registry rows (`sin` … `ceil`), in registry order, each as
`(name::String, sym::Symbol, fn::Function)`. `atan` (one or two operands), `neg`
and `not` have shapes of their own. Consumers that map a unary op to its Julia
function: the ModelingToolkit `broadcast` lowering, the geometry emitter, the
Julia emitter's audit test.
"""
const _UNARY_ELEMENTWISE_OPS = Tuple(
    (name = s.name, sym = Symbol(s.name), fn = s.scalar_fn::Function)
        for s in _OP_TABLE if s.shape === :unary
)

# The row shape of the three tables below. `sym` is the op symbol a node carries;
# `fnsym` is the module-scope function name an emitted call names. They differ
# exactly for the alias rows (`pow` calls `^`, `atan2` calls `atan`).
_ladder_row(s::_OpSpec) =
    (
    name = s.name, sym = Symbol(s.name),
    fnsym = nameof(s.scalar_fn::Function), fn = s.scalar_fn::Function,
)

"""
    _COMPARISON_ELEMENTWISE_OPS

The `:compare`-shaped rows, in registry order: `<`, `<=`, `>`, `>=`, `==`, `!=`.
An evaluator applies the Base predicate and maps its `Bool` to `1.0`/`0.0`.
"""
const _COMPARISON_ELEMENTWISE_OPS = Tuple(
    _ladder_row(s) for s in _OP_TABLE if s.shape === :compare
)

"""
    _BINARY_ELEMENTWISE_OPS

The `:binary`-shaped rows, in registry order: `/`, `^`, `pow`, `atan2`.
"""
const _BINARY_ELEMENTWISE_OPS = Tuple(
    _ladder_row(s) for s in _OP_TABLE if s.shape === :binary
)

"""
    _NARY_MINMAX_OPS

The `:minmax`-shaped rows: `min`, `max` (esm-spec §4.2, two or more operands).
"""
const _NARY_MINMAX_OPS = Tuple(
    _ladder_row(s) for s in _OP_TABLE if s.shape === :minmax
)
