# tree_walk/compile.jl — `_compile` / `_compile_op`: an expression to `_Node`, with the
# per-equation build memo and the runtime loop-variable names.

# A reserved runtime loop variable: a name no document spells, minted where the
# resolve keeps a contracted index symbolic. Its counter `Ref` is registered on
# the build state (`_register_loopvar!`) and read by `_compile`'s `VarExpr` arm,
# which lowers the name to an `_NK_LOOPVAR` node. The numbering is the build's
# own (`_BuildState.loopvar_count`, compiler.jl), so a build names its loops the
# same way every time.
const _LOOPVAR_PREFIX = "__esm_lv_"
function _fresh_loopvar_name()
    c = _build_state().loopvar_count
    c[] += 1
    return string(_LOOPVAR_PREFIX, c[])
end
_register_loopvar!(name::AbstractString, ref::Base.RefValue{Int}) =
    (_build_state().loopvars[Symbol(name)] = ref; nothing)

# ── Per-equation build memo ──
# Within one array equation's cell loop every cell resolves and compiles against
# the same context, so `_resolve_indices` and `_compile` are pure functions of
# the expression object; a subexpression shared across cells (the same object,
# by the identity short-circuits of `_sub_preserving` and `_resolve_indices`)
# is resolved and compiled once. `_Node` is immutable, so sharing a compiled
# node is safe. The memo is passed explicitly (`_ResolveCtx.memo`, `memo`
# here); `nothing` means no memo, and a recursion that drops it only stops
# memoizing, it never changes a result.
#
# `deferrals` counts the guarded out-of-range const reads the resolve deferred to
# run time (gather_resolve.jl). Such a result depends on the guards the node was
# resolved under, not on the node alone, so it is not memoized when any guard
# was in force (`_resolve_indices`).
struct _BuildMemo
    resolve::IdDict{OpExpr, ASTExpr}
    compile::IdDict{OpExpr, _Node}
    deferrals::Base.RefValue{Int}
    # An inline `const` array node => its interned array and registry name
    # (`_intern_inline_const`): one node read at many subscripts is interned once.
    inline::IdDict{OpExpr, Tuple{Any, String}}
end
_BuildMemo() = _BuildMemo(
    IdDict{OpExpr, ASTExpr}(), IdDict{OpExpr, _Node}(), Ref(0), IdDict{OpExpr, Tuple{Any, String}}()
)
const _MaybeMemo = Union{Nothing, _BuildMemo}

# `param_syms` tells a parameter from an unbound-variable error without another
# pass. It comes in two shapes, and the difference is exactly whether the
# parameter ORDER is known:
#
#   * `Dict{Symbol,Int}` — the evaluator build's map, `sym → position in the
#     sorted `param_names` (and therefore in the `p` NamedTuple). Every
#     `_NK_PARAM` node minted from it carries that position in `idx`, which is
#     what lets a VECTOR `p` be read by index (`_read_param`).
#   * `Set{Symbol}` — the build-time constant folders in cellwise.jl and field_ic.jl, which mint
#     their own ad-hoc parameter scope per call and evaluate it against a
#     NamedTuple built in the same breath. There is no global order to record, so
#     those nodes get `idx = 0` and are NamedTuple-only by construction.
#
# Keeping both is why the seam is `(sym, idx)` rather than `idx` alone.
@inline _is_param(ps::AbstractDict{Symbol, Int}, sym::Symbol) = haskey(ps, sym)
@inline _is_param(ps, sym::Symbol) = sym in ps
@inline _param_index(ps::AbstractDict{Symbol, Int}, sym::Symbol) = get(ps, sym, 0)
@inline _param_index(_, ::Symbol) = 0

function _compile(expr::NumExpr, var_map, param_syms, memo::_MaybeMemo = nothing)
    return _mknode(kind = _NK_LITERAL, literal = expr.value)
end
function _compile(expr::IntExpr, var_map, param_syms, memo::_MaybeMemo = nothing)
    return _mknode(kind = _NK_LITERAL, literal = Float64(expr.value))
end
function _compile(expr::VarExpr, var_map, param_syms, memo::_MaybeMemo = nothing)
    name = expr.name
    # Inside a template call body every name read from outside is an argument.
    if startswith(name, '\0')
        a = _arg_leaf(name)
        a === nothing || return a
        # A template sentinel (not a stencil lane, which shares the `\0` spelling).
        (startswith(name, _TPL_ARG) || startswith(name, _TPL_FREE) || startswith(name, _TPL_OUT) ||
            startswith(name, _TPL_IN) || startswith(name, _TPL_BASE)) && throw(
            TreeWalkError(
                "E_TREEWALK_UNRESOLVED_TEMPLATE_REF",
                "a template parameter $(repr(replace(name, '\0' => '·'))) reached compile outside its call body"
            )
        )
    end
    if name == "t"
        return _mknode(kind = _NK_TIME)
    end
    idx = get(var_map, name, 0)
    if idx != 0
        # Inside a build-time evaluation scope (`_with_param_reads`) this arm IS
        # a parameter read: `evaluate_expr` binds the resolved parameter scope as
        # pseudo-state. Outside one it is an ordinary state slot and nothing is
        # recorded. See `_record_param_read` (build_caller_data.jl).
        _record_param_read(name)
        return _mknode(kind = _NK_STATE, idx = idx)
    end
    sym = Symbol(name)
    if _is_param(param_syms, sym)
        _record_param_read(name)
        return _mknode(kind = _NK_PARAM, sym = sym, idx = _param_index(param_syms, sym))
    end
    # A reserved runtime-contraction loop variable:
    # `_resolve_scalar_faq` kept the contracted index symbolic and registered
    # its shared counter `Ref` here. Lower to an `_NK_LOOPVAR` leaf that reads the
    # ref at eval time (the enclosing `_NK_CONTRACTION_LOOP` writes it per iteration).
    lref = get(_build_state().loopvars, sym, nothing)
    if lref !== nothing
        return _mknode(kind = _NK_LOOPVAR, payload = lref)
    end
    throw(TreeWalkError("E_TREEWALK_UNBOUND_VARIABLE", name))
end
function _compile(expr::OpExpr, var_map, param_syms, memo::_MaybeMemo = nothing)
    _count!(:compile_calls)
    memo === nothing && return _compile_op(expr, var_map, param_syms, nothing)
    m = memo.compile
    r = get(m, expr, nothing)
    r === nothing || return r
    r = _compile_op(expr, var_map, param_syms, memo)
    m[expr] = r
    return r
end

# The `unevaluable_operator` diagnostic (esm-spec §9.6.6): `op` IS in the §4.2
# evaluable core, but this evaluator has no rule for it where it stands. `why`
# names the stage that should have eliminated it.
_unevaluable_operator(op, why::AbstractString) = TreeWalkError(
    ERROR_CODES.UNEVALUABLE_OPERATOR,
    "operator '$(op)' is an evaluable-core op with no evaluation rule in the tree-walk " *
        "evaluator: $(why) (esm-spec §4.2 / §9.6.6)."
)

function _compile_op(expr::OpExpr, var_map, param_syms, memo::_MaybeMemo)
    # A template reference is a call (call.jl): never expanded.
    _tpl_is_call(expr) && return _compile_call(expr, var_map, param_syms, memo)
    op_sym = Symbol(expr.op)
    # A run-time loop or gather resolve lowered (`_Lowered`): its args are the
    # node's children (a loop body, ragged bounds, gather subscripts). A loop
    # body compiles iff the unrolled body would: the only leaf difference is a
    # loop-var `VarExpr` (`_NK_LOOPVAR`) where the unroll has an `IntExpr`.
    if expr.value isa _Lowered
        lw = expr.value::_Lowered
        kids = _Node[_compile(a, var_map, param_syms, memo) for a in expr.args]
        return _mknode(
            kind = lw.kind, op = lw.op, literal = lw.literal, payload = lw.payload,
            children = kids
        )
    end

    children = _Node[
        _compile(a, var_map, param_syms, memo)
            for a in expr.args
    ]
    if op_sym === :const
        # Scalar `const` ops fold to a literal at compile time. Non-scalar
        # `const` only ever appears as an argument to ops that consume
        # arrays (handled in their respective compile paths above).
        v = expr.value
        if v isa Real && !(v isa Bool)
            return _mknode(kind = _NK_LITERAL, literal = Float64(v))
        end
        throw(
            _unevaluable_operator(
                expr.op,
                "a non-scalar `const` is consumed only by an array-consuming position"
            )
        )
    elseif op_sym === Symbol("true")
        # The boolean literals (esm-spec §4.2), in the evaluator's float encoding.
        # (`:true` is the Bool `true`, not a Symbol, so it cannot be compared here.)
        return _mknode(kind = _NK_LITERAL, literal = 1.0)
    elseif op_sym === Symbol("false")
        return _mknode(kind = _NK_LITERAL, literal = 0.0)
    elseif op_sym === :enum
        throw(
            _unevaluable_operator(
                expr.op,
                "`enum` must be lowered to `const` at load — call `lower_enums!` before compile"
            )
        )
    elseif op_sym === :D
        # esm-spec §4.2 / §9.6.8: `D` is an
        # evaluable-core op only in its STRUCTURAL equation-LHS role. A `D`
        # reaching `_compile` — a spatial `D`, or any `D` in an RHS / observed /
        # rate position — is an unlowered rewrite-target: a discretization rule
        # must lower it to a stencil before evaluation. The gate fires here,
        # before evaluation, with the uniform `unlowered_operator` code.
        wrtdesc = expr.wrt === nothing ? "" : " (wrt=$(expr.wrt))"
        throw(
            TreeWalkError(
                ERROR_CODES.UNLOWERED_OPERATOR,
                "unlowered derivative operator 'D'$wrtdesc reached evaluation: a " *
                    "spatial or right-hand-side `D` must be lowered to a stencil by a " *
                    "rewrite rule before evaluation (esm-spec §4.2 / §9.6.8)."
            )
        )
    elseif op_sym === :ic
        # `ic` (esm-spec v0.8.0) is an equation-LHS-only marker, like `D`:
        # `ic(var) = <initial field>` declares an initial condition. It must
        # never appear in an RHS / general expression position.
        throw(
            TreeWalkError(
                "E_TREEWALK_IC_IN_RHS",
                "ic(...) only allowed in equation LHS"
            )
        )
    elseif op_sym === :faq
        # If _resolve_indices ran, scalar aggregate (empty output_idx) was
        # already expanded to a plain arithmetic tree and never reaches here.
        # Reaching this branch means an array-producing aggregate (non-empty
        # output_idx) appeared without being wrapped in an index() call.
        throw(
            _unevaluable_operator(
                expr.op,
                "with non-empty output_idx in expression position it " *
                    "requires wrapping in index($(expr.op)(...), k1, k2, ...)"
            )
        )
    elseif op_sym === :makearray
        # makearray in expression position must be wrapped in index().
        throw(
            _unevaluable_operator(
                expr.op,
                "in expression position it requires wrapping " *
                    "in index(makearray(...), k1, k2, ...)"
            )
        )
    elseif op_sym === :broadcast || op_sym === :reshape ||
            op_sym === :transpose || op_sym === :concat
        throw(
            _unevaluable_operator(
                expr.op,
                "outside an index(...) the tree-walk path has no rule for " *
                    "this shape op; index(op(...), k1, k2, ...) is a gather of its operand"
            )
        )
    elseif op_sym === :index
        # A live forcing buffer read at an offset resolve already checked and
        # linearized (`_PGatherRef`): a live read on every call.
        if expr.value isa _PGatherRef
            ref = expr.value::_PGatherRef
            return _mknode(kind = _NK_PARAM_GATHER, idx = ref.lin, payload = ref.flat)
        end
        # A const or provider array read at an offset computed at eval time
        # from the subscript children compiled above.
        if expr.value isa _ConstGatherRef
            ref = expr.value::_ConstGatherRef
            return _const_gather_node(ref.vals, children; name = ref.name)
        end
        # A live forcing buffer read at a runtime-computed offset: the same
        # subscript children, read from the buffer at each call.
        if expr.value isa _LiveGatherRef
            return _live_gather_node(expr.value::_LiveGatherRef, children)
        end
        # A gather `_resolve_indices` left alone because its base names no
        # array it knows: a variable with no declared or inferred shape, no
        # const/forcing data, and no equation defining its cells.
        base = isempty(expr.args) ? nothing : expr.args[1]
        if base isa VarExpr
            bn = (base::VarExpr).name
            throw(
                TreeWalkError(
                    "E_TREEWALK_INDEX_NOT_ARRAY",
                    "index($(bn), …): '$(bn)' is not an array the build can gather from — " *
                        "it has no declared `shape`, no data bound to it, and no equation " *
                        "that defines its cells, so it has no element to read"
                )
            )
        end
        # Otherwise: index ops must be resolved to state-slot references by
        # _resolve_indices before reaching _compile; encountering one here
        # means the caller skipped that pass.
        throw(
            TreeWalkError(
                "E_TREEWALK_UNSUPPORTED_OP",
                "$(expr.op) reached _compile unresolved — " *
                    "_resolve_indices must run first"
            )
        )
    end
    # An op that is not evaluable core (esm-spec §4.2 / §9.6.6) is an unlowered
    # rewrite target: `grad`/`div`/`laplacian`, `integral`, or any open-namespace
    # op with no registry row (`_op_in_T`). A discretization rule must lower it
    # first. A registered core form with no scalar meaning reports
    # `unevaluable_operator` instead, from the arms above or the gate below.
    if _op_in_T(expr.op)
        throw(
            TreeWalkError(
                ERROR_CODES.UNLOWERED_OPERATOR,
                "unlowered rewrite-target operator '$(expr.op)' reached evaluation: " *
                    "no rewrite rule lowered it to a stencil before evaluation " *
                    "(esm-spec §4.2 / §9.6.8). Open-tier ops are lowered by discretization " *
                    "rules (e.g. EarthSciDiscretizations), not evaluated directly."
            )
        )
    end
    # ── Evaluable-core op with no rule (esm-spec §9.6.6) ──
    # A core op `_eval_node_op` has no arm for (`distinct`,
    # `apply_expression_template`, …) is refused HERE, while
    # the evaluator is built, rather than at the first RHS call.
    _has_tree_walk_rule(expr.op) || throw(
        _unevaluable_operator(
            expr.op,
            "an earlier pipeline stage (value invention, or a load-time lowering pass) " *
                "must eliminate it"
        )
    )
    _check_op_arity(op_sym, length(children))
    return _mknode(kind = _NK_OP, op = op_sym, children = children)
end
