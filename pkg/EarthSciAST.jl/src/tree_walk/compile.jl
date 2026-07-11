# ========================================================================
# tree_walk/compile.jl — part of the tree-walk evaluator (gt-e8yw).
# Included by src/tree_walk.jl; see that file for the full layout and
# include order. Sections 3/3b/4: compilation of expressions to the compact _Node IR,
# common-subexpression elimination (ess-r7h), and the compiled scalar
# walker (_eval_node / _eval_node_op) — a zero-allocation hot path.
# ========================================================================

# ============================================================
# 3. Compiled-IR — one-shot compilation to a compact, type-stable tree
# ============================================================
#
# `_eval` below walks the raw `OpExpr` tree. That's correct but every
# op dispatch is an O(N) chain of String comparisons, and every
# VarExpr lookup does a Dict probe. For 4096-equation models the
# overhead dominates. `_compile` walks the expression once at build
# time and produces `_Node` trees where:
#
#   * op is a `Symbol` (pointer compare, not byte compare)
#   * state refs have their u-index baked in
#   * parameter refs have their `Val{sym}` type param baked in for
#     `getfield(p, Val)` — monomorphic NamedTuple access
#   * literals are pre-promoted to Float64
#   * registered-function handlers are looked up and captured once
#
# The compiled tree keeps semantics identical to walking `OpExpr`
# directly; `_eval` stays available for the unit-test helper which
# exercises the fallback path.

# _NKind encodes what a node is. Keeping it as a Bare integer (UInt8)
# gives a fast `kind === K_*` dispatch inside `_eval_node`.
const _NK_LITERAL      = UInt8(1)
const _NK_STATE        = UInt8(2)   # read u[idx]
const _NK_PARAM        = UInt8(3)   # read p.<sym>
const _NK_TIME         = UInt8(4)   # return t
const _NK_OP           = UInt8(5)   # apply op to children
const _NK_CONTRACTION  = UInt8(6)   # runtime ⊕-reduction over children (seq. fold)
const _NK_CACHED       = UInt8(7)   # common-subexpression ref: read cache[idx] (ess-r7h)
const _NK_PARAM_GATHER = UInt8(8)   # read a captured live forcing buffer: handler[idx] (ess-14f.3)

# One compiled scalar-IR node. `kind` selects which fields are live. The
# catch-all `handler::Any` slot carries a KIND-DEPENDENT runtime payload,
# type-asserted at its read sites (`_eval_node` / `_eval_node_op`, and the
# vectorized lowerings `_merge_nodes` / `_lower_template`, which mirror the
# same field on `_VecNode` — the name is shared across both IRs):
#   * `_NK_OP` with `op === :fn` — `(fname, const_args)::Tuple{String,Any}`:
#     the closed-function name plus either `nothing` (all args scalar) or a
#     `Vector{Any}` of pre-extracted const arrays in spec arg-position order
#     (the `_FN_CONST_ARG_SPECS` protocol); every other `_NK_OP` carries
#     `nothing`.
#   * `_NK_PARAM_GATHER` — the aliased flat `Vector{Float64}` of a live
#     forcing buffer (`_PGatherArray.flat`, ess-14f.3); `idx` holds the
#     pre-linearized column-major offset.
#   * `_NK_CACHED` — the shared CSE scratch `Vector{Float64}` (ess-r7h);
#     `idx` holds the value-number slot.
#   * every other kind — `nothing`.
struct _Node
    kind::UInt8
    op::Symbol
    literal::Float64
    idx::Int
    sym::Symbol
    handler::Any
    children::Vector{_Node}
end

# Build-time side channel from `_resolve_indices` to `_compile` (ess-14f.3): a
# RESOLVED live-forcing gather, carried in the `value` slot of a synthetic
# argless `index` node. The `index` op is CSE-opaque and this node never reaches
# serialization (it exists only between the resolve and compile passes of one
# build), so the runtime payload is canonicalization-safe there. A dedicated
# wrapper type (not a raw `(Vector{Float64}, Int)` tuple) makes the payload
# type-checkable and greppable at both ends of the channel.
struct _PGatherRef
    flat::Vector{Float64}   # aliased flat view of the caller's live buffer
    lin::Int                # pre-linearized column-major offset into `flat`
end

# ── Per-equation build memo (ess-perf: compile one representative per group) ──
# Within one array equation's cell loop every cell resolves/compiles against the
# SAME resolve context (array_var_info / var_map / const_arrays / pgather) and
# compile context (var_map / param_syms / reg_funcs), so `_resolve_indices` and
# `_compile` are pure functions of the input expression OBJECT. A subexpression shared across cells — every state-independent
# subtree is the SAME object across cells, thanks to the `_sub_preserving` /
# `_resolve_indices` identity short-circuits — is then resolved and compiled ONCE
# instead of once per cell. `_Node` is immutable and `_merge_nodes` never mutates
# its inputs, so sharing a compiled node across cells is safe.
#
# The memo is a plain local value created in `_build_evaluator_impl` and passed
# EXPLICITLY down the resolve/compile recursion (no module-level or task-local
# state — safe under concurrent builds). Threading is fail-safe: a `_resolve_indices`
# / `_compile` call that receives `nothing` (the default, used everywhere outside
# the array-cell loop) is byte-identical to the un-memoized function, and a
# recursion that forgets to forward the memo merely stops memoizing that subtree —
# it never changes a result.
struct _BuildMemo
    resolve::IdDict{OpExpr,Expr}
    compile::IdDict{OpExpr,_Node}
end
_BuildMemo() = _BuildMemo(IdDict{OpExpr,Expr}(), IdDict{OpExpr,_Node}())
const _MaybeMemo = Union{Nothing,_BuildMemo}

function _mknode(; kind::UInt8, op::Symbol=Symbol(""),
                 literal::Float64=0.0, idx::Int=0,
                 sym::Symbol=Symbol(""), handler=nothing,
                 children::Vector{_Node}=_Node[])
    return _Node(kind, op, literal, idx, sym, handler, children)
end

# ---- interp.* const-arg protocol (one table, both ends) ------------------------
# Which spec arg positions of each `interp.*` closed function are CONST-ARRAY
# args. `_compile_op` pre-extracts those args into the node's `handler` payload
# (`(fname, Vector{Any})`, in table order) and compiles only the remaining
# scalar args as children (in spec order); the `:fn` arm of `_eval_node_op`
# re-splices both back into spec arg-position order from this SAME table, so
# the two ends of the protocol cannot drift. The vectorized `_merge_fn_node`
# (vectorize.jl) consumes the handler payload layout pinned here. `const_errs`
# are the pinned per-position diagnostics for a non-const argument.
const _FN_CONST_ARG_SPECS = (
    # Spec arg order: (x, xs) — xs const, x scalar.
    (fname = "interp.searchsorted", arity = 2, const_positions = (2,),
     const_errs = ("interp.searchsorted: 2nd arg must be a `const`-op array",)),
    # Spec arg order: (table, axis, x) — table & axis const, x scalar.
    (fname = "interp.linear", arity = 3, const_positions = (1, 2),
     const_errs = ("interp.linear: `table` argument must be a `const`-op array node",
                   "interp.linear: `axis` argument must be a `const`-op array node")),
    # Spec arg order: (table, axis_x, axis_y, x, y) — first three const.
    (fname = "interp.bilinear", arity = 5, const_positions = (1, 2, 3),
     const_errs = ("interp.bilinear: `table` argument must be a `const`-op array node",
                   "interp.bilinear: `axis_x` argument must be a `const`-op array node",
                   "interp.bilinear: `axis_y` argument must be a `const`-op array node")),
)

# The `_FN_CONST_ARG_SPECS` entry for `fname`, or `nothing` for a closed
# function whose args are all scalar. A linear scan over the length-3 const
# tuple — string compares only, no runtime Dict lookup (the eval side also
# calls this, staying in the same cost class as the ladder it replaced).
@inline function _fn_const_arg_spec(fname::AbstractString)
    for spec in _FN_CONST_ARG_SPECS
        spec.fname == fname && return spec
    end
    return nothing
end

# A `const`-op array argument's payload, or throw the pinned per-position
# diagnostic from `_FN_CONST_ARG_SPECS`.
@inline function _const_array_arg(arg, errmsg::String)
    if arg isa OpExpr && arg.op == "const" && arg.value isa AbstractVector
        return arg.value
    end
    throw(TreeWalkError("E_TREEWALK_FN_ARG_NOT_CONST", errmsg))
end

# `param_syms` is a `Set{Symbol}` so parameters can be distinguished
# from unbound-variable errors without another pass.
function _compile(expr::NumExpr, var_map, param_syms, reg_funcs, memo::_MaybeMemo=nothing)
    return _mknode(kind=_NK_LITERAL, literal=expr.value)
end
function _compile(expr::IntExpr, var_map, param_syms, reg_funcs, memo::_MaybeMemo=nothing)
    return _mknode(kind=_NK_LITERAL, literal=Float64(expr.value))
end
function _compile(expr::VarExpr, var_map, param_syms, reg_funcs, memo::_MaybeMemo=nothing)
    name = expr.name
    if name == "t"
        return _mknode(kind=_NK_TIME)
    end
    idx = get(var_map, name, 0)
    if idx != 0
        return _mknode(kind=_NK_STATE, idx=idx)
    end
    sym = Symbol(name)
    if sym in param_syms
        return _mknode(kind=_NK_PARAM, sym=sym)
    end
    throw(TreeWalkError("E_TREEWALK_UNBOUND_VARIABLE", name))
end
function _compile(expr::OpExpr, var_map, param_syms, reg_funcs, memo::_MaybeMemo=nothing)
    memo === nothing && return _compile_op(expr, var_map, param_syms, reg_funcs, nothing)
    m = memo.compile
    r = get(m, expr, nothing)
    r === nothing || return r
    r = _compile_op(expr, var_map, param_syms, reg_funcs, memo)
    m[expr] = r
    return r
end
function _compile_op(expr::OpExpr, var_map, param_syms, reg_funcs, memo::_MaybeMemo)
    op_sym = Symbol(expr.op)
    handler = nothing
    if op_sym === :fn
        # Closed function registry (esm-spec §9.2 / esm-tzp). The function
        # name is captured in the node's `handler` slot as a tuple of
        # (name::String, const_args_or_nothing). For the `interp.*` functions
        # the const-array args are pre-extracted per `_FN_CONST_ARG_SPECS` so
        # the runtime hot path doesn't walk the AST.
        fname = expr.name
        fname === nothing &&
            throw(TreeWalkError("E_TREEWALK_FN_MISSING_NAME", expr.op))
        if !(fname in _CLOSED_FUNCTION_NAMES)
            throw(TreeWalkError("E_TREEWALK_UNKNOWN_CLOSED_FUNCTION", fname))
        end
        spec = _fn_const_arg_spec(fname)
        if spec === nothing
            children = _Node[_compile(a, var_map, param_syms, reg_funcs, memo)
                             for a in expr.args]
            handler = (fname, nothing)
        else
            length(expr.args) == spec.arity ||
                throw(TreeWalkError("E_TREEWALK_FN_ARITY",
                    "$(fname) expects $(spec.arity) args, got $(length(expr.args))"))
            # Validate + extract every const position first (matching the
            # pre-table ladders, which never compiled a scalar arg before a
            # failed const check), then compile the scalar args — in spec
            # order — as the node's children.
            const_args = Any[_const_array_arg(expr.args[pos], spec.const_errs[k])
                             for (k, pos) in enumerate(spec.const_positions)]
            children = _Node[_compile(expr.args[pos], var_map, param_syms, reg_funcs, memo)
                             for pos in 1:spec.arity if !(pos in spec.const_positions)]
            handler = (fname, const_args)
        end
        return _mknode(kind=_NK_OP, op=op_sym, children=children, handler=handler)
    end

    children = _Node[_compile(a, var_map, param_syms, reg_funcs, memo)
                     for a in expr.args]
    if op_sym === :const
        # Scalar `const` ops fold to a literal at compile time. Non-scalar
        # `const` only ever appears as an argument to ops that consume
        # arrays (handled in their respective compile paths above).
        v = expr.value
        if v isa Real && !(v isa Bool)
            return _mknode(kind=_NK_LITERAL, literal=Float64(v))
        end
        throw(TreeWalkError("E_TREEWALK_UNSUPPORTED_OP",
            "non-scalar `const` op outside an array-consuming position"))
    elseif op_sym === :enum
        throw(TreeWalkError("E_TREEWALK_UNSUPPORTED_OP",
            "`enum` op encountered after lowering — call `lower_enums!` before compile"))
    elseif op_sym === :call
        # Removed in v0.3.0 (esm-spec §9 closure). `parse_expression` already
        # rejects file-loaded `call` ops; reaching this arm means a caller
        # constructed a `call` OpExpr programmatically.
        throw(TreeWalkError("E_TREEWALK_UNSUPPORTED_OP",
            "`call` op was removed in v0.3.0 — migrate to `fn` ops " *
            "or AST equations (esm-spec §9 closure, RFC closed-function-registry)"))
    elseif op_sym === :D
        # esm-spec §4.2 / §9.6.8 (open-op-namespace RFC, Change B): `D` is an
        # evaluable-core op only in its STRUCTURAL equation-LHS role. A `D`
        # reaching `_compile` — a spatial `D`, or any `D` in an RHS / observed /
        # rate position — is an unlowered rewrite-target: a discretization rule
        # must lower it to a stencil before evaluation. The gate fires here,
        # before evaluation, with the uniform `unlowered_operator` code.
        wrtdesc = expr.wrt === nothing ? "" : " (wrt=$(expr.wrt))"
        throw(TreeWalkError("unlowered_operator",
            "unlowered derivative operator 'D'$wrtdesc reached evaluation: a " *
            "spatial or right-hand-side `D` must be lowered to a stencil by a " *
            "rewrite rule before evaluation (esm-spec §4.2 / §9.6.8)."))
    elseif op_sym === :ic
        # `ic` (esm-spec v0.8.0) is an equation-LHS-only marker, like `D`:
        # `ic(var) = <initial field>` declares an initial condition. It must
        # never appear in an RHS / general expression position.
        throw(TreeWalkError("E_TREEWALK_IC_IN_RHS",
                            "ic(...) only allowed in equation LHS"))
    elseif op_sym === :grad || op_sym === :div || op_sym === :laplacian
        # esm-spec §4.2 / §9.6.8 (open-op-namespace RFC, Change D):
        # grad/div/laplacian are NOT evaluable-core ops — they are optional
        # rewrite-target sugar over `D` that a discretization rule must lower to
        # an `aggregate`/`makearray` stencil before evaluation. One reaching
        # `_compile` means no rule lowered it. This format ships no
        # discretization rules; the std-lib lives in EarthSciDiscretizations.
        # Surface the violation rather than substituting zero (the historical
        # stub behaviour in other bindings). Uniform `unlowered_operator` code.
        throw(TreeWalkError("unlowered_operator",
            "unlowered rewrite-target operator '$(expr.op)' reached evaluation: " *
            "no rewrite rule lowered it to a stencil (esm-spec §4.2 / §9.6.8). " *
            "Discretization rules live in EarthSciDiscretizations, not this format."))
    elseif op_sym === :arrayop || op_sym === :aggregate
        # If _resolve_indices ran, scalar aggregate (empty output_idx) was
        # already expanded to a plain arithmetic tree and never reaches here.
        # Reaching this branch means an array-producing aggregate (non-empty
        # output_idx) appeared without being wrapped in an index() call.
        throw(TreeWalkError("E_TREEWALK_UNSUPPORTED_OP",
                            "$(expr.op) with non-empty output_idx in expression position " *
                            "requires wrapping in index($(expr.op)(...), k1, k2, ...)"))
    elseif op_sym === :makearray
        # makearray in expression position must be wrapped in index().
        throw(TreeWalkError("E_TREEWALK_UNSUPPORTED_OP",
                            "makearray in expression position requires wrapping " *
                            "in index(makearray(...), k1, k2, ...)"))
    elseif op_sym === :broadcast || op_sym === :reshape ||
           op_sym === :transpose || op_sym === :concat
        throw(TreeWalkError("E_TREEWALK_UNSUPPORTED_OP",
                            "$(expr.op) (not yet supported in tree-walk path)"))
    elseif op_sym === :index
        # A forcing gather over a live `param_arrays` buffer (ess-14f.3): the
        # `index` branch of `_resolve_indices` already bounds-checked and
        # linearized it, stashing a `_PGatherRef` in `value` (the `index` op is
        # CSE-opaque, so `value` is never canonicalized). Lower it to a
        # live-read `_NK_PARAM_GATHER` instead of the const-fold a frozen
        # `const_arrays` entry would get. This is the binding-time reroute of an
        # EXISTING gather by its cadence class — no new IR op (the wire op is still
        # `index`); see the JL-J0 feasibility-gate note in `_build_evaluator_impl`.
        if expr.value isa _PGatherRef
            ref = expr.value::_PGatherRef
            return _mknode(kind=_NK_PARAM_GATHER, idx=ref.lin, handler=ref.flat)
        end
        # Otherwise: index ops must be resolved to state-slot references by
        # _resolve_indices before reaching _compile; encountering one here
        # means the caller skipped that pass.
        throw(TreeWalkError("E_TREEWALK_UNSUPPORTED_OP",
                            "$(expr.op) reached _compile unresolved — " *
                            "_resolve_indices must run first"))
    end
    return _mknode(kind=_NK_OP, op=op_sym, children=children, handler=handler)
end

# ============================================================
# 3b. Common-subexpression elimination (ess-r7h) — eval-time memo, approach (a)
# ============================================================
#
# APPROACH (a) — eval-time memoization. The serialized IR and the canonical
# goldens are UNCHANGED: CSE only restructures how the *compiled* tree-walk
# evaluator computes a RHS, so results are numerically identical and the
# cross-binding PDE-sim conformance suite (ess-fmw, rhs_rtol=1e-9) is untouched
# by construction. Lives only in this Julia evaluator (the bead's named main
# beneficiary); other bindings need no change because numeric output is the same.
#
# KEY = `canonical_json(expr)` from canonicalize.jl — the existing,
# cross-binding-identical canonical form. Two subexpressions are "common" iff
# their canonical_json bytes are equal; keying on this is conformance-safe by
# construction (the same identity all five bindings already agree on). NO
# parallel canonicalizer is introduced — `canonical_json` IS the key.
#
# SHARING HANDLE = a value-number (Int cache slot) per distinct canonical key.
# This realizes the RFC §6.1 "node id as a DAG vertex" role in compiled space:
# a shared subexpression is named once and referenced from each use site by a
# `_NK_CACHED` leaf carrying that slot.
#
# DAG = the value-numbered data-dependency graph `_compile_cse` walks: children
# are compiled (and hoisted) before their parent, so a cached subexpression's
# slot is always lower than the slots referencing it — the prelude is therefore
# already topologically ordered. (cadence.jl's §5.7 graph is index-set cycle
# detection over raw JSON, not an expression-CSE DAG; the reuse here is of the
# *canonical identity*, not that specific pass.)
#
# EVALUATOR MEMO POINT = a per-`f!`-call scratch `cache::Vector{Float64}`. The
# prelude evaluates each distinct cached subexpression exactly ONCE per RHS call
# into `cache` (slot order); every occurrence then reads `cache[slot]` via
# `_NK_CACHED`. A subexpression occurring K times is thus evaluated once.
#
# BIT-EXACTNESS: a cached subexpression's definition is compiled from its
# original (first-seen) operand order — identical to what `_compile` emits
# inline today — so each occurrence reads back the exact bytes it would have
# computed. With no common subexpressions the prelude is empty and `_compile_cse`
# produces the identical `_Node` tree `_compile` would, so f! is unchanged for
# models with nothing to share.
#
# SCOPE — why CSE lives on the scalar tree-walk path, not the vectorized
# (ess-dhq) arrayop path. After ess-dhq, redundancy is removed at three layers:
#   * cross-grid-cell  — eliminated by whole-array kernels (one broadcast per
#                        structural cell group), so the same stencil is never
#                        re-walked per cell;
#   * intra-expression — eliminated at DISCRETIZE time: `discretize` canonicalizes
#                        each per-cell RHS (discretize.jl), and canonicalization
#                        already merges like additive/multiplicative terms. The
#                        2D-Laplacian interior body, for instance, lands as
#                        `16*(u[i-1,j]+u[i+1,j]+u[i,j-1]+u[i,j+1]+(-4*u[i,j]))`
#                        — every gather appears exactly once, nothing to share;
#   * cross-equation / intra-RHS-across-nonlinear-contexts — SURVIVES canonicalize
#                        (it normalizes one expression at a time, and does not
#                        combine `sin(a+b)` with `cos(a+b)` or a shared reaction
#                        flux `k*A*B` across several species balances). This is
#                        exactly the scalar/indexed-D tree-walk path, and it is
#                        where this CSE pass fires.
# Conformance PDE fixtures are pure single-field arrayops (n_scalar_entries==0)
# whose canonicalized templates carry no duplicate sub-node, so vectorized-path
# CSE would be a no-op on them. Cross-KERNEL sharing for COUPLED multi-field PDEs
# (one array subexpression reused across several arrayop equations) is a genuine
# future case — keyed structurally on the post-merge `_VecNode` rather than on
# `canonical_json`, with a per-call vector cache — and is tracked as a follow-up.

# Ops `_compile` handles specially (closed functions, array/aggregate producers,
# unresolved/illegal-in-RHS markers). CSE never hoists a node rooted at one of
# these and never rewrites their operands — such subtrees delegate to plain
# `_compile`. Everything else is the scalar arithmetic / comparison /
# transcendental family that `_compile` lowers to a plain `_NK_OP`, which is
# exactly what `_compile_cse` reconstructs, so hoisting those is sound.
# Membership is declared per-op in src/op_registry.jl (flag `:cse_opaque`)
# and pinned by op_registry_test.jl.
const _CSE_OPAQUE_OPS = _ops_with(:cse_opaque)

# A node is a CSE hoist/recurse candidate iff it is an OpExpr whose op is not
# opaque. Leaves (state/param/literal/time) are never hoisted — caching a leaf
# costs more than the bare read it would replace.
_cse_hoistable(e::OpExpr) = !(e.op in _CSE_OPAQUE_OPS)
_cse_hoistable(::Expr) = false

# Canonical-form key for a subexpression, or `nothing` if it cannot be
# canonicalized (e.g. a non-finite literal). A `nothing` key disables sharing
# for that subtree — CSE is a pure optimization and silently declines anything
# it cannot key safely.
function _cse_key(e::Expr)
    try
        return canonical_json(e)
    catch err
        err isa CanonicalizeError && return nothing
        rethrow()
    end
end

# Count pass: tally canonical_json occurrences of every hoistable subexpression
# across all RHS trees. A key seen >= 2 times is worth hoisting.
function _cse_count!(e::Expr, counts::Dict{String,Int})
    (e isa OpExpr && _cse_hoistable(e)) || return
    k = _cse_key(e)
    k === nothing || (counts[k] = get(counts, k, 0) + 1)
    for a in e.args
        _cse_count!(a, counts)
    end
    return
end

# Mutable CSE compile context: the set of cached keys, the slot assigned to each
# (assigned lazily, in topological order, at first compile), the prelude
# definitions (`defs[s]` computes `cache[s]`), and the shared scratch the
# `_NK_CACHED` nodes read from.
mutable struct _CSEContext
    cached::Set{String}
    slot::Dict{String,Int}
    defs::Vector{_Node}
    cache::Vector{Float64}
end

# Compile `expr` to a `_Node`, hoisting any subexpression whose canonical key is
# in `ctx.cached` into the prelude and replacing it with a `_NK_CACHED` ref.
# Falls back to plain `_compile` for leaves and opaque ops, so the result is
# identical to `_compile` wherever nothing is hoisted.
function _compile_cse(expr::Expr, var_map, param_syms, reg_funcs, ctx::_CSEContext)
    (expr isa OpExpr && _cse_hoistable(expr)) ||
        return _compile(expr, var_map, param_syms, reg_funcs)

    key = _cse_key(expr)
    if key !== nothing && key in ctx.cached
        s = get(ctx.slot, key, 0)
        s != 0 && return _mknode(kind=_NK_CACHED, idx=s, handler=ctx.cache)
        # First occurrence: compile children first (assigning them lower slots,
        # keeping `defs` topologically ordered), reserve this slot, register the
        # def, and return a ref. Every later occurrence hits the `s != 0` path.
        children = _Node[_compile_cse(a, var_map, param_syms, reg_funcs, ctx)
                         for a in expr.args]
        defnode = _mknode(kind=_NK_OP, op=Symbol(expr.op), children=children)
        s = length(ctx.defs) + 1
        ctx.slot[key] = s
        push!(ctx.defs, defnode)
        return _mknode(kind=_NK_CACHED, idx=s, handler=ctx.cache)
    end
    # Not cached: reconstruct the same `_NK_OP` node `_compile` would, but with
    # hoisted children.
    children = _Node[_compile_cse(a, var_map, param_syms, reg_funcs, ctx)
                     for a in expr.args]
    return _mknode(kind=_NK_OP, op=Symbol(expr.op), children=children)
end

# Compile a batch of scalar `(state_index, resolved_rhs_expr)` entries with
# cross-equation + intra-expression CSE. Returns the compiled rhs list, the
# prelude (slot-ordered def nodes), the shared cache vector, and a diagnostic
# `(; n_slots, n_occurrences)` that witnesses the evaluate-once property
# (criterion #2: distinct evaluations == distinct canonical subexpressions).
function _cse_compile_scalar(entries::Vector{Tuple{Int,Expr}},
                             var_map, param_syms, reg_funcs)
    counts = Dict{String,Int}()
    for (_, e) in entries
        _cse_count!(e, counts)
    end
    cached = Set{String}()
    n_occ = 0
    for (k, c) in counts
        if c >= 2
            push!(cached, k)
            n_occ += c
        end
    end
    cache = Float64[]
    ctx = _CSEContext(cached, Dict{String,Int}(), _Node[], cache)
    rhs_list = Tuple{Int,_Node}[]
    for (idx, e) in entries
        push!(rhs_list, (idx, _compile_cse(e, var_map, param_syms, reg_funcs, ctx)))
    end
    # Size the scratch to the number of slots. `cache` is the SAME object the
    # `_NK_CACHED` nodes captured, so this in-place resize is visible to them.
    resize!(cache, length(ctx.defs))
    diag = (; n_slots = length(ctx.defs), n_occurrences = n_occ)
    return rhs_list, ctx.defs, cache, diag
end

# ============================================================
# 4. Compiled walker
# ============================================================

@inline function _eval_node(n::_Node, u, p, t)
    k = n.kind
    if k === _NK_LITERAL
        return n.literal
    elseif k === _NK_STATE
        @inbounds return u[n.idx]
    elseif k === _NK_PARAM
        return getfield(p, n.sym)
    elseif k === _NK_PARAM_GATHER
        # Live read of a captured forcing buffer (ess-14f.3). `handler` is the
        # aliased flat `Vector{Float64}` (a `_PGatherArray.flat`) and `idx` the
        # pre-linearized column-major offset, both fixed at build time; the buffer
        # CONTENTS are refreshed in place by the J1 discrete callback. The concrete
        # `::Vector{Float64}` assert keeps this monomorphic + zero-alloc (no
        # runtime-symbol `getfield`, so the scalar `p` NamedTuple stays homogeneous).
        @inbounds return (n.handler::Vector{Float64})[n.idx]
    elseif k === _NK_TIME
        return t
    elseif k === _NK_CACHED
        # Common-subexpression reference (ess-r7h). The value was computed once
        # into the per-call scratch cache by the CSE prelude (see `_make_rhs`);
        # every occurrence reads it here instead of re-walking the subtree. The
        # cache vector is captured in `handler` at build time, so this needs no
        # extra eval argument and the recursive `_eval_node` family is unchanged.
        @inbounds return (n.handler::Vector{Float64})[n.idx]
    elseif k === _NK_CONTRACTION
        return _eval_contraction(n, u, p, t)
    else
        return _eval_node_op(n, u, p, t)
    end
end

# Runtime ⊕-reduction over a node's children, parameterized by semiring (§5.1).
# The accumulator is seeded from `n.literal`, the 0̄ identity baked onto the node
# at build time from the registry table — so every arm (incl. empty-or-folded
# max/min/×) returns the normative identity without any hardcoded constant here.
# All four arms share ONE shape: an `@inbounds` sequential fold over the children
# seeded from `n.literal`. The `:+` arm sums from 0.0 (sum_product's 0̄, the only
# ⊕=+ semiring) in child order — allocation-free and bit-identical to the prior
# `@tullio s = …` sum (which `zero`-seeds the same sequential accumulation). The
# Tullio form built per-call codegen machinery (~80 B per reduced cell); keeping
# the four arms structurally identical is what makes the RHS `f!` non-allocating
# (ess-9cc). This node is only built with ≥1 child (the empty case folds to a
# literal upstream).
function _eval_contraction(n::_Node, u, p, t)
    op = n.op
    children = n.children
    if op === :+
        s = n.literal  # 0̄ = 0.0 for sum_product
        @inbounds for k in eachindex(children)
            s += _eval_node(children[k], u, p, t)
        end
        return s
    elseif op === :*
        s = n.literal  # 1̄ for the ×-reduce
        @inbounds for k in eachindex(children)
            s *= _eval_node(children[k], u, p, t)
        end
        return s
    elseif op === :max
        s = n.literal  # -∞
        @inbounds for k in eachindex(children)
            s = max(s, _eval_node(children[k], u, p, t))
        end
        return s
    else  # :min
        s = n.literal  # +∞
        @inbounds for k in eachindex(children)
            s = min(s, _eval_node(children[k], u, p, t))
        end
        return s
    end
end

function _eval_node_op(n::_Node, u, p, t)
    op = n.op
    c = n.children

    # Arithmetic — the hot paths.
    if op === :+
        length(c) == 1 && return _eval_node(c[1], u, p, t)
        acc = _eval_node(c[1], u, p, t)
        @inbounds for i in 2:length(c)
            acc += _eval_node(c[i], u, p, t)
        end
        return acc
    elseif op === :*
        length(c) == 1 && return _eval_node(c[1], u, p, t)
        acc = _eval_node(c[1], u, p, t)
        @inbounds for i in 2:length(c)
            acc *= _eval_node(c[i], u, p, t)
        end
        return acc
    elseif op === :-
        if length(c) == 1
            return -_eval_node(c[1], u, p, t)
        elseif length(c) == 2
            return _eval_node(c[1], u, p, t) - _eval_node(c[2], u, p, t)
        end
        throw(TreeWalkError("E_TREEWALK_ARITY", "- expects 1 or 2 args"))
    elseif op === :neg
        # Canonical-form unary negation. `canonicalize` rewrites unary
        # `-x` to `neg(x)`, so any AST that has been through `discretize`
        # may carry `neg` ops where the source had `-x`.
        _expect_arity_n(op, c, 1)
        return -_eval_node(c[1], u, p, t)
    elseif op === :/
        _expect_arity_n(op, c, 2)
        return _eval_node(c[1], u, p, t) / _eval_node(c[2], u, p, t)
    elseif op === :^ || op === :pow
        _expect_arity_n(op, c, 2)
        return _eval_node(c[1], u, p, t) ^ _eval_node(c[2], u, p, t)

    # Comparisons → 1.0/0.0 (match `evaluate` semantics)
    elseif op === :<
        _expect_arity_n(op, c, 2)
        return _eval_node(c[1], u, p, t) <  _eval_node(c[2], u, p, t) ? 1.0 : 0.0
    elseif op === Symbol("<=")
        _expect_arity_n(op, c, 2)
        return _eval_node(c[1], u, p, t) <= _eval_node(c[2], u, p, t) ? 1.0 : 0.0
    elseif op === :>
        _expect_arity_n(op, c, 2)
        return _eval_node(c[1], u, p, t) >  _eval_node(c[2], u, p, t) ? 1.0 : 0.0
    elseif op === Symbol(">=")
        _expect_arity_n(op, c, 2)
        return _eval_node(c[1], u, p, t) >= _eval_node(c[2], u, p, t) ? 1.0 : 0.0
    elseif op === Symbol("==")
        _expect_arity_n(op, c, 2)
        return _eval_node(c[1], u, p, t) == _eval_node(c[2], u, p, t) ? 1.0 : 0.0
    elseif op === Symbol("!=")
        _expect_arity_n(op, c, 2)
        return _eval_node(c[1], u, p, t) != _eval_node(c[2], u, p, t) ? 1.0 : 0.0

    # Logical
    elseif op === :and
        for child in c
            _eval_node(child, u, p, t) == 0 && return 0.0
        end
        return 1.0
    elseif op === :or
        for child in c
            _eval_node(child, u, p, t) != 0 && return 1.0
        end
        return 0.0
    elseif op === :not
        _expect_arity_n(op, c, 1)
        return _eval_node(c[1], u, p, t) == 0 ? 1.0 : 0.0

    elseif op === :ifelse
        _expect_arity_n(op, c, 3)
        return _eval_node(c[1], u, p, t) != 0 ?
               _eval_node(c[2], u, p, t) :
               _eval_node(c[3], u, p, t)

    # Elementary functions
    elseif op === :sin;   _expect_arity_n(op, c, 1); return sin(_eval_node(c[1], u, p, t))
    elseif op === :cos;   _expect_arity_n(op, c, 1); return cos(_eval_node(c[1], u, p, t))
    elseif op === :tan;   _expect_arity_n(op, c, 1); return tan(_eval_node(c[1], u, p, t))
    elseif op === :asin;  _expect_arity_n(op, c, 1); return asin(_eval_node(c[1], u, p, t))
    elseif op === :acos;  _expect_arity_n(op, c, 1); return acos(_eval_node(c[1], u, p, t))
    elseif op === :atan
        if length(c) == 1
            return atan(_eval_node(c[1], u, p, t))
        elseif length(c) == 2
            return atan(_eval_node(c[1], u, p, t), _eval_node(c[2], u, p, t))
        end
        throw(TreeWalkError("E_TREEWALK_ARITY", "atan expects 1 or 2 args"))
    elseif op === :atan2
        _expect_arity_n(op, c, 2)
        return atan(_eval_node(c[1], u, p, t), _eval_node(c[2], u, p, t))
    elseif op === :sinh;  _expect_arity_n(op, c, 1); return sinh(_eval_node(c[1], u, p, t))
    elseif op === :cosh;  _expect_arity_n(op, c, 1); return cosh(_eval_node(c[1], u, p, t))
    elseif op === :tanh;  _expect_arity_n(op, c, 1); return tanh(_eval_node(c[1], u, p, t))
    elseif op === :asinh; _expect_arity_n(op, c, 1); return asinh(_eval_node(c[1], u, p, t))
    elseif op === :acosh; _expect_arity_n(op, c, 1); return acosh(_eval_node(c[1], u, p, t))
    elseif op === :atanh; _expect_arity_n(op, c, 1); return atanh(_eval_node(c[1], u, p, t))
    elseif op === :exp;   _expect_arity_n(op, c, 1); return exp(_eval_node(c[1], u, p, t))
    elseif op === :log;   _expect_arity_n(op, c, 1); return log(_eval_node(c[1], u, p, t))
    elseif op === :log10; _expect_arity_n(op, c, 1); return log10(_eval_node(c[1], u, p, t))
    elseif op === :sqrt;  _expect_arity_n(op, c, 1); return sqrt(_eval_node(c[1], u, p, t))
    elseif op === :abs;   _expect_arity_n(op, c, 1); return abs(_eval_node(c[1], u, p, t))
    elseif op === :sign;  _expect_arity_n(op, c, 1); return sign(_eval_node(c[1], u, p, t))
    elseif op === :floor; _expect_arity_n(op, c, 1); return floor(_eval_node(c[1], u, p, t))
    elseif op === :ceil;  _expect_arity_n(op, c, 1); return ceil(_eval_node(c[1], u, p, t))
    elseif op === :min
        # n-ary min (esm-spec §4.2 — arity ≥ 2)
        length(c) < 2 && throw(TreeWalkError("E_TREEWALK_ARITY", "min needs ≥2 args"))
        acc = _eval_node(c[1], u, p, t)
        @inbounds for i in 2:length(c); acc = min(acc, _eval_node(c[i], u, p, t)); end
        return acc
    elseif op === :max
        # n-ary max (esm-spec §4.2 — arity ≥ 2)
        length(c) < 2 && throw(TreeWalkError("E_TREEWALK_ARITY", "max needs ≥2 args"))
        acc = _eval_node(c[1], u, p, t)
        @inbounds for i in 2:length(c); acc = max(acc, _eval_node(c[i], u, p, t)); end
        return acc

    elseif op === :pi || op === :π
        return Float64(pi)
    elseif op === :e
        return Float64(ℯ)

    elseif op === :Pre
        _expect_arity_n(op, c, 1)
        return _eval_node(c[1], u, p, t)

    elseif op === :fn
        # `n.handler` is `(fname::String, const_args_or_nothing)`. The
        # tuple's second slot is `nothing` for closed functions whose args
        # are all scalar (e.g. `datetime.*`): the children are the full
        # spec-order arg list. For closed functions with const-array args it
        # is a `Vector{Any}` carrying the pre-extracted arrays in
        # `_FN_CONST_ARG_SPECS` order; re-splice them (at their table-pinned
        # spec positions) with the evaluated scalar children (in child order)
        # to rebuild the spec-order argument vector.
        fname, const_args = n.handler::Tuple{String,Any}
        if const_args === nothing
            args_evaluated = Any[_eval_node(ci, u, p, t) for ci in c]
            return Float64(evaluate_closed_function(fname, args_evaluated))
        end
        spec = _fn_const_arg_spec(fname)
        if spec !== nothing
            cas = const_args::Vector{Any}
            args = Vector{Any}(undef, spec.arity)
            for (k, pos) in enumerate(spec.const_positions)
                args[pos] = cas[k]
            end
            ci = 0
            for pos in 1:spec.arity
                isassigned(args, pos) && continue
                ci += 1
                args[pos] = _eval_node(c[ci], u, p, t)
            end
            return Float64(evaluate_closed_function(fname, args))
        end
        # Unreachable if `_compile_op` and this arm agree (via
        # `_FN_CONST_ARG_SPECS`) on which closed functions carry pre-extracted
        # const args — throw explicitly rather than falling through to an
        # implicit `nothing`.
        throw(TreeWalkError("E_TREEWALK_UNKNOWN_CLOSED_FUNCTION",
            "fn '$(fname)' carries const args but has no interp.* eval arm"))

    else
        throw(TreeWalkError("E_TREEWALK_UNSUPPORTED_OP", String(op)))
    end
end

# `c` is a `Vector{_Node}` on the scalar path and a `Vector{_VecNode}` on the
# vectorized path — only its length is read, and the error-message interpolation
# happens solely on the throw branch, so the happy path stays allocation-free.
@inline function _expect_arity_n(op::Symbol, c::AbstractVector, n::Int)
    length(c) == n ||
        throw(TreeWalkError("E_TREEWALK_ARITY",
                            "$op expects $n args, got $(length(c))"))
    return nothing
end
