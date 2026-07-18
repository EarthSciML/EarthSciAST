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
const _NK_PARAM_GATHER = UInt8(8)   # read a captured live forcing buffer: payload[idx] (ess-14f.3)

# One compiled scalar-IR node. `kind` selects which fields are live. The
# catch-all `payload::Any` slot carries a KIND-DEPENDENT runtime payload,
# type-asserted at its read sites (`_eval_node` / `_eval_node_op`, and the
# vectorized lowerings `_merge_nodes` / `_lower_template`, which mirror the
# same field on `_VecNode` — the name is shared across both IRs):
#   * `_NK_OP` with `op === :fn` — `(fname, spec)::Tuple{String,Any}`: the
#     closed-function name plus either `nothing` (all args scalar — the boxed
#     `datetime.*` path) or a build-time-validated typed `_Interp*Spec`
#     (`_InterpLinearSpec` / `_InterpBilinearSpec` / `_InterpSearchsortedSpec`,
#     registered_functions.jl) carrying the const table/axis as concrete
#     `Vector{Float64}` for the `interp.*` functions (the `_FN_CONST_ARG_SPECS`
#     protocol). The `:fn` eval arm dispatches on the spec's concrete type and
#     calls `_interp_*_core` directly; every other `_NK_OP` carries `nothing`.
#   * `_NK_PARAM_GATHER` — the aliased flat `Vector{Float64}` of a live
#     forcing buffer (`_PGatherArray.flat`, ess-14f.3); `idx` holds the
#     pre-linearized column-major offset.
#   * `_NK_CACHED` — the shared CSE scratch (`_CSECache`, ess-r7h); `idx` holds
#     the value-number slot.
#   * every other kind — `nothing`.
struct _Node
    kind::UInt8
    op::Symbol
    literal::Float64
    idx::Int
    sym::Symbol
    payload::Any
    children::Vector{_Node}
end

# Build-time side channel from `_resolve_indices` to `_compile` (ess-14f.3): a
# RESOLVED live-forcing gather, carried in the `value` slot of a synthetic
# argless `index` node. It exists only between the resolve and compile passes of
# one build and never reaches the SERIALIZER — but it does reach `canonical_json`,
# which is a different thing and was the bug (ess-qic): the `index` op being
# CSE-opaque only stops the gather from being hoisted ITSELF; `_cse_key` still
# canonicalizes every hoistable ANCESTOR of it, and a canonical node emits its
# `value` field. A raw `_PGatherRef` there is not a JSON type, so `canonical_json`
# threw `E_CANONICAL_BAD_CONST`, `_cse_key` caught it and declined — silently
# switching CSE off for every expression built over a live forcing buffer. The
# gather therefore carries a CANONICALIZABLE identity (`name`, below) alongside its
# runtime payload; `_cse_key` swaps the ref for a stand-in node built from it.
#
# A dedicated wrapper type (not a raw `(Vector{Float64}, Int)` tuple) makes the
# payload type-checkable and greppable at both ends of the channel.
struct _PGatherRef
    flat::Vector{Float64}   # aliased flat view of the caller's live buffer
    lin::Int                # pre-linearized column-major offset into `flat`
    # The buffer's registry name — its key in the build's `pgather` dict, which is
    # what makes it the gather's CSE identity (see `_pgather_key_expr`). Distinct
    # buffers necessarily have distinct names (they are Dict KEYS), so two gathers
    # collide on `(name, lin)` iff they read the same offset of the same buffer.
    # That distinctness is a Dict invariant rather than a hand-maintained counter,
    # which matters: a collision here would not lose sharing, it would MERGE two
    # different reads and produce silently wrong numbers.
    name::String
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
    resolve::IdDict{OpExpr,ASTExpr}
    compile::IdDict{OpExpr,_Node}
end
_BuildMemo() = _BuildMemo(IdDict{OpExpr,ASTExpr}(), IdDict{OpExpr,_Node}())
const _MaybeMemo = Union{Nothing,_BuildMemo}

function _mknode(; kind::UInt8, op::Symbol=Symbol(""),
                 literal::Float64=0.0, idx::Int=0,
                 sym::Symbol=Symbol(""), payload=nothing,
                 children::Vector{_Node}=_Node[])
    return _Node(kind, op, literal, idx, sym, payload, children)
end

# ---- interp.* const-arg protocol (one table, both ends) ------------------------
# Which spec arg positions of each `interp.*` closed function are CONST-ARRAY
# args. `_compile_op` pre-extracts those args, validates + coerces them into a
# typed `_Interp*Spec` (registered_functions.jl) ONCE at build time, and stores
# `(fname, spec)` in the node's `payload` slot; only the remaining scalar args
# are compiled as children (in spec order). The `:fn` arm of `_eval_node_op`
# then dispatches on the concrete spec type and calls the validation-free
# `_interp_*_core` kernel directly with the typed `Float64` query — no per-call
# box, no per-call axis re-validation, no `_fn_const_arg_spec` scan. The
# vectorized `_merge_fn_node` (vectorize.jl) consumes the SAME `(fname, spec)`
# payload — it reuses the already-built spec rather than rebuilding it — so the
# two ends of the protocol cannot drift. Moving validation to build time makes a
# bad axis (non-monotonic / NaN / too-short / length-mismatch) fail fast at build
# with its pinned `ClosedFunctionError` code, matching the vectorized path
# (ess-wrh) which already validated at build time. `const_errs` are the pinned
# per-position diagnostics for a non-const argument.
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

# Build the validated, typed `_Interp*Spec` (registered_functions.jl) for a
# const-arg closed function from its pre-extracted const arrays (`const_args`,
# in `_FN_CONST_ARG_SPECS` `const_positions` order). Runs the SAME validation +
# `Float64` coercion the runtime kernels require, ONCE at build time — a bad
# axis throws its pinned `ClosedFunctionError` here (fail-fast). Shared by the
# scalar `_compile_op` and the vectorized `_merge_fn_node`, so both ends build
# the same spec object from the one table. `fname` MUST be a `_fn_const_arg_spec`
# name (the caller gates on that); the `else` is an internal-consistency guard.
function _build_interp_spec(fname::AbstractString, const_args::Vector{Any})
    if fname == "interp.linear"
        return _build_interp_linear_spec(fname, const_args...)
    elseif fname == "interp.bilinear"
        return _build_interp_bilinear_spec(fname, const_args...)
    elseif fname == "interp.searchsorted"
        return _build_interp_searchsorted_spec(fname, const_args...)
    end
    throw(TreeWalkError("E_TREEWALK_UNKNOWN_CLOSED_FUNCTION",
        "fn '$(fname)' carries const args but has no interp.* spec builder"))
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
    _BENCH_ON[] && (_BENCH_COMPILE_CALLS[] += 1)   # §12 node-lowering counter (off by default)
    memo === nothing && return _compile_op(expr, var_map, param_syms, reg_funcs, nothing)
    m = memo.compile
    r = get(m, expr, nothing)
    r === nothing || return r
    r = _compile_op(expr, var_map, param_syms, reg_funcs, memo)
    m[expr] = r
    return r
end

# Lower one `fn` (closed-function) OpExpr to its `_NK_OP` node (esm-spec §9.2 /
# esm-tzp). The function name is captured in the node's `payload` slot as a tuple
# of (name::String, spec_or_nothing). For the `interp.*` functions the const-array
# args are pre-extracted per `_FN_CONST_ARG_SPECS` AND validated + coerced into a
# typed `_Interp*Spec` here at build time, so the runtime hot path neither walks
# the AST nor re-validates the axis. All-scalar closed functions (`datetime.*`)
# store `nothing` and keep the boxed `evaluate_closed_function` path.
#
# `compile_child` lowers ONE scalar argument expression to a `_Node`. It is a
# parameter — not a hardcoded `_compile` call — so the CSE pass can reuse this
# exact lowering while compiling the scalar args through `_compile_cse` (ess-r7h
# follow-up, ess-obs): a closed function is a pure, deterministic node, so both
# the `fn` node itself and every scalar subexpression BELOW it are legitimate CSE
# hoist candidates. Routing both callers through one function is what keeps the
# const-arg protocol (`_FN_CONST_ARG_SPECS`) single-sourced — a CSE-local copy of
# this branch could drift from the eval arm's payload contract.
function _compile_fn_node(expr::OpExpr, compile_child)
    fname = expr.name
    fname === nothing &&
        throw(TreeWalkError("E_TREEWALK_FN_MISSING_NAME", expr.op))
    if !(fname in _CLOSED_FUNCTION_NAMES)
        throw(TreeWalkError("E_TREEWALK_UNKNOWN_CLOSED_FUNCTION", fname))
    end
    cspec = _fn_const_arg_spec(fname)
    if cspec === nothing
        children = _Node[compile_child(a) for a in expr.args]
        # Datetime.* etc.: `(fname, nothing)`; the eval arm's concrete-tuple
        # split takes the boxed `evaluate_closed_function` fallback.
        payload = (fname, nothing)
    else
        length(expr.args) == cspec.arity ||
            throw(TreeWalkError("E_TREEWALK_FN_ARITY",
                "$(fname) expects $(cspec.arity) args, got $(length(expr.args))"))
        # Validate + extract every const position first (matching the
        # pre-table ladders, which never compiled a scalar arg before a
        # failed const check), then compile the scalar args — in spec
        # order — as the node's children. The const arrays are validated +
        # coerced into a typed spec ONCE here (fail-fast on a bad axis). The
        # payload is the CONCRETE `Tuple{String,_Interp*Spec}`; the eval arm
        # `isa`-matches that concrete tuple type so the spec is read without
        # a per-call re-box (a `Tuple{String,Any}` read would box the inline
        # immutable struct every call).
        const_args = Any[_const_array_arg(expr.args[pos], cspec.const_errs[k])
                         for (k, pos) in enumerate(cspec.const_positions)]
        children = _Node[compile_child(expr.args[pos])
                         for pos in 1:cspec.arity if !(pos in cspec.const_positions)]
        payload = (fname, _build_interp_spec(fname, const_args))
    end
    return _mknode(kind=_NK_OP, op=:fn, children=children, payload=payload)
end

function _compile_op(expr::OpExpr, var_map, param_syms, reg_funcs, memo::_MaybeMemo)
    op_sym = Symbol(expr.op)
    payload = nothing
    if op_sym === :fn
        return _compile_fn_node(expr,
            a -> _compile(a, var_map, param_syms, reg_funcs, memo))
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
        # CSE-opaque, so the gather is never HOISTED; `_cse_key` still keys its
        # ancestors, and swaps the ref for a canonicalizable stand-in to do so —
        # see `_PGatherRef`). Lower it to a
        # live-read `_NK_PARAM_GATHER` instead of the const-fold a frozen
        # `const_arrays` entry would get. This is the binding-time reroute of an
        # EXISTING gather by its cadence class — no new IR op (the wire op is still
        # `index`); see the JL-J0 feasibility-gate note in `_build_evaluator_impl`.
        if expr.value isa _PGatherRef
            ref = expr.value::_PGatherRef
            return _mknode(kind=_NK_PARAM_GATHER, idx=ref.lin, payload=ref.flat)
        end
        # Otherwise: index ops must be resolved to state-slot references by
        # _resolve_indices before reaching _compile; encountering one here
        # means the caller skipped that pass.
        throw(TreeWalkError("E_TREEWALK_UNSUPPORTED_OP",
                            "$(expr.op) reached _compile unresolved — " *
                            "_resolve_indices must run first"))
    end
    return _mknode(kind=_NK_OP, op=op_sym, children=children, payload=payload)
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
# IDENTITY IS CANONICAL, NOT STRUCTURAL — and that is a decision, not an accident.
# `canonical_json` CANONICALIZES before it emits (canonicalize.jl): n-ary `+`/`*`
# are flattened and their arguments sorted. Three consequences, stated exactly:
#
#   (a) CSE keys on CANONICAL identity. Two subexpressions share a slot iff their
#       canonical forms are equal — the same identity all five bindings already
#       agree on, which is what makes keying on it conformance-safe.
#   (b) Reassociation-equivalent expressions therefore SHARE A SLOT. `(a+b)+c` and
#       `a+(b+c)` have one key, `{"args":["a","b","c"],"op":"+"}`, hence one slot.
#   (c) The FIRST-SEEN operand order is what every occurrence reads back. The slot's
#       def is compiled from the first occurrence encountered (`_cse_rebuild`), so
#       the other occurrences get that association order, not their own.
#
# The consequence is worth naming, because it is surprising: since float `+`/`*` are
# not associative, an equation's numeric output is NOT a function of that equation
# alone — adding a canonically-equal expression elsewhere in the model can shift it.
# The difference is bounded by float reassociation of a CANONICALLY EQUAL expression
# (normally sub-ulp; catastrophic cancellation can amplify it), and the format
# already reassociates freely as a matter of course: `discretize` canonicalizes each
# per-cell RHS before it is ever compiled, so canonical form *is* this format's
# notion of expression identity and a conforming reader may associate `+(a,b,c)`
# however it likes. Keying CSE structurally instead would restore per-equation
# locality, but it would lose commutative sharing (which tree_walk_cse_test.jl pins)
# and would itself change the numbers of models that work today. So: the key stays
# canonical, and this property is PINNED by a test rather than left latent.
#
# What IS bit-exact: a model with nothing to share gets an empty prelude, and
# `_compile_cse` then produces the identical `_Node` tree `_compile` would — so f!
# is unchanged, instruction for instruction, for models with no common subexpression.
#
# GUARDS — the prelude is UNCONDITIONAL, the walker is LAZY. `_make_rhs` fills every
# slot at the top of every call, before any equation runs, while `_eval_node_op` is
# lazy for `ifelse` (only the taken branch is walked) and short-circuits `and`/`or`.
# Hoisting a subexpression that occurs ONLY under a guard would therefore evaluate it
# when no guard fires — turning `ifelse(a >= 0, sqrt(a), 0)` at `a = -1` into a
# `DomainError`, and making whether a guard protects its operand depend on how many
# times that operand happens to appear in the model. So a key is hoisted iff
#
#     total_occurrences >= 2   AND   unconditional_occurrences >= 1
#
# (see `_cse_count!`). If a key has an unconditional occurrence the original walk
# evaluates it anyway at that occurrence, so evaluating it once in the prelude is
# exactly as safe — no new throw, no new NaN — and the GUARDED occurrences of that
# same key may then freely read the cache (`_compile_cse` needs no guard logic: slot
# membership already implies an unconditional occurrence). A key occurring only under
# guards is left inline, where its guard still protects it. Note this is deliberately
# not "refuse to recurse into guarded arms", which would lose legitimate sharing
# within an arm and between an arm and an unconditional occurrence.
#
# Guard laziness holds only on the two SCALAR walkers (`_eval_node`, `_oop_eval`).
# The vectorized `_eval_vec` is EAGER for `ifelse`/`and`/`or` BY CONSTRUCTION — it
# broadcasts over lanes, and per-lane laziness would need masked evaluation — so a
# guarded-domain expression inside an `arrayop` is NOT protected by its guard, with
# or without CSE. That is a known, deliberate divergence between the scalar and
# array paths (see the `ifelse` arm of `_eval_vec` in vectorize.jl), and it is why
# the guard rule above lives in the scalar CSE pass only.
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

# Ops CSE must not look at: array/aggregate producers, const/enum data carriers,
# and the unresolved/illegal-in-RHS markers. CSE never hoists a node rooted at
# one of these and never rewrites their operands — such subtrees delegate to
# plain `_compile`. Everything else is a pure, deterministic scalar node whose
# value depends only on `(u, p, t)`, so naming it once and reading the name back
# is value-preserving.
#
# `fn` (the closed-function call) is deliberately NOT opaque (ess-obs). It IS
# handled specially by `_compile` — const-array args, a typed payload — but it is
# nonetheless a pure scalar function of its scalar args, and the `interp.*` /
# `datetime.*` registry (esm-spec §9.2) is closed and deterministic. Treating it
# as opaque made every closed-function call a CSE BARRIER: `_cse_count!` stopped
# at the `fn` node, so neither the call nor anything beneath it could be shared.
# That is exactly the shape of an inlined observed chain that reaches a
# time/solar-geometry subtree through an `interp.*` table lookup — e.g. FastJX's
# 18 actinic-flux bands `F_i = interp.linear(table_i, axis, cos_sza)`, each
# carrying a full copy of the inlined `Solar.cos_zenith` subtree, summed by ~14
# photolysis rates: ~250 re-walks of the same solar chain per RHS call. Hoisting
# through `fn` collapses all of them to one evaluation (see `_cse_rebuild`).
# Membership is declared per-op in src/op_registry.jl (flag `:cse_opaque`)
# and pinned by op_registry_test.jl.
const _CSE_OPAQUE_OPS = _ops_with(:cse_opaque)

# A node is a CSE hoist/recurse candidate iff it is an OpExpr whose op is not
# opaque. Leaves (state/param/literal/time) are never hoisted — caching a leaf
# costs more than the bare read it would replace.
_cse_hoistable(e::OpExpr) = !(e.op in _CSE_OPAQUE_OPS)
_cse_hoistable(::ASTExpr) = false

# ---- Keying an expression built over a live forcing buffer (ess-qic) ----------
#
# A resolved `param_arrays` gather is an argless `index` node carrying a
# `_PGatherRef` in `value` (see `_PGatherRef`). `_PGatherRef` is a runtime payload,
# not a JSON type, so `canonical_json` throws on it — and since it is canonicalized
# as a CHILD of every hoistable ancestor, that throw used to decline sharing for the
# whole met→physics stack sitting above a forcing buffer. The fix is to key the
# gather as a LEAF with a canonicalizable, DISTINGUISHABLE identity:
#
#     OpExpr("index", []; name="__pgather", value=[<buffer name>, <linear offset>])
#
# both of which `_emit_canonical_value` handles (AbstractString / Integer inside an
# AbstractArray). The gather itself STAYS CSE-opaque — it is never hoisted into the
# prelude (a live buffer read is one indexed load, cheaper than a cache slot); the
# point is only that its ancestors can now be keyed.
#
# DISTINCTNESS is the whole safety argument, and it is the one way this can go
# catastrophically wrong: if two gathers collide on a key, CSE MERGES them and the
# model computes silently wrong numbers. `(buffer name, linear offset)` is
# injective onto `(buffer, element)` because the buffer name is its KEY in the
# build's `pgather` dict — distinct buffers cannot share a name — and every entry
# (raw `param_arrays` buffers in `_build_pgather`, discrete-cadence caches in
# `_build_discrete_materializer!`) is registered before any expression is resolved
# against the dict, so a name resolves to one buffer for the whole resolve phase.
# `_pgather_check_distinct!` re-verifies that at key time rather than assuming it.
#
# LIVENESS is unaffected. Hoisting an expression built OVER a gather caches the
# expression's VALUE for one `f!` call only — the prelude is refilled at the top of
# every call — and a forcing buffer cannot change mid-call (it is refreshed by a
# discrete callback BETWEEN steps, and a discrete cache by `materialize!`). So the
# cached value is exactly what the inline walk would have computed at that call.
const _PGATHER_KEY_NAME = "__pgather"

# Per-build context for the stand-in rewrite: an identity memo (each node rewritten
# at most once, so the whole pass is O(nodes) across every `_cse_key` call) plus the
# distinctness witness (`name` → the buffer it was seen bound to).
struct _PGatherKeyCtx
    memo::IdDict{OpExpr,ASTExpr}
    seen::Dict{String,Vector{Float64}}
end
_PGatherKeyCtx() = _PGatherKeyCtx(IdDict{OpExpr,ASTExpr}(), Dict{String,Vector{Float64}}())

# The key identity `(name, lin)` is only injective if `name` names ONE buffer. That
# holds by construction today; check it anyway, because the failure mode of a broken
# assumption here is wrong numbers, not lost sharing.
function _pgather_check_distinct!(ctx::_PGatherKeyCtx, ref::_PGatherRef)
    prev = get(ctx.seen, ref.name, nothing)
    if prev === nothing
        ctx.seen[ref.name] = ref.flat
    elseif prev !== ref.flat
        throw(TreeWalkError("E_TREEWALK_PGATHER_KEY_COLLISION",
            "internal: forcing-buffer name '$(ref.name)' resolved to two different " *
            "buffers within one build. The CSE key for a live gather is " *
            "(buffer name, offset); a name bound to two buffers would let CSE merge " *
            "two DIFFERENT reads into one cache slot. Registration of every `pgather` " *
            "entry must precede expression resolution — that invariant is broken."))
    end
    return nothing
end

# Replace every resolved live-forcing gather in `e` with its canonicalizable
# stand-in, leaving everything else alone. IDENTITY-PRESERVING in the style of
# `_sub_preserving`: a subtree containing no `_PGatherRef` is returned as the SAME
# object, so a model with no forcing buffers is untouched (and `_cse_key` skips this
# pass entirely — `ctx === nothing`). Rewritten nodes are memoized by object
# identity, so a subexpression shared across equations is rewritten once.
_pgather_key_expr(e::ASTExpr, ::_PGatherKeyCtx) = e   # NumExpr / IntExpr / VarExpr
function _pgather_key_expr(e::OpExpr, ctx::_PGatherKeyCtx)
    r = get(ctx.memo, e, nothing)
    r === nothing || return r
    r = _pgather_key_expr_uncached(e, ctx)
    ctx.memo[e] = r
    return r
end
function _pgather_key_expr_uncached(e::OpExpr, ctx::_PGatherKeyCtx)
    # The ref is keyed off the `value` field rather than off `op == "index"`, so any
    # future node that carries one is keyed (never silently declined) too.
    if e.value isa _PGatherRef
        ref = e.value::_PGatherRef
        _pgather_check_distinct!(ctx, ref)
        return OpExpr(e.op, ASTExpr[]; name=_PGATHER_KEY_NAME,
                      value=Any[ref.name, ref.lin])
    end
    # `map_children` (expression.jl) is the ONE field-preserving rewrite primitive —
    # it visits every expression-bearing field, so a gather buried in an aggregate
    # body / filter / range bound is rewritten too. Its rebuilt node is DISCARDED
    # when no descendant changed, which is what keeps this identity-preserving.
    changed = false
    rebuilt = map_children(e) do c
        r = _pgather_key_expr(c, ctx)
        changed |= r !== c
        return r
    end
    return changed ? rebuilt : e
end

# Canonical-form key for a subexpression, or `nothing` if it cannot be keyed
# safely. A `nothing` key disables sharing for that subtree — CSE is a pure
# optimization and silently declines anything it cannot key safely.
#
# `pgctx` is the live-forcing stand-in context (above) when the build binds any
# `param_arrays` buffer or discrete cache, and `nothing` otherwise — in which case
# no `_PGatherRef` can exist and this is byte-for-byte the pre-ess-qic key.
#
# ---------------------------------------------------------------------------
# WHY A BARE-LITERAL CANONICAL FORM IS REFUSED (bug audit 2026-07-14, J4)
#
# The CSE key is `canonical_json`, and `canonicalize` contains folds that are NOT
# value-preserving on the IEEE reals: `_canon_mul` maps `x*0 → 0` and `_canon_div`
# maps `0/x → 0` **regardless of x**. Those are wrong when `x` is `Inf` or `NaN`
# (`Inf*0` is `NaN`, not `0`), which is fine for a canonical *identity* key in the
# abstract-algebra sense, but fatal for CSE: two structurally DIFFERENT
# expressions both canonicalize to the literal `0.0`, `_cse_count!` sees one key
# with two occurrences, hoists ONE slot, and compiles that slot's definition from
# whichever occurrence it saw FIRST. Every other occurrence then reads a value
# computed from a different expression.
#
#     D(x) = (1/z)*0                 alone  ->  du[x] = NaN   (correct: Inf*0)
#     D(y) = w*0  ;  D(x) = (1/z)*0         ->  du[x] = 0.0   (WRONG)
#
# `D(x)` is byte-identical between the two models: adding an UNRELATED equation
# changed another equation's value, and the error is unbounded (NaN ↔ 0.0), not
# the sub-ulp reassociation drift the existing pin at the top of this file
# describes. Fail-close: refuse to key any subexpression whose canonical form
# collapses to a bare literal.
#
# A canonical form that collapses to a bare VARIABLE (`x*1 → x`, `x+0 → x`) is
# NOT refused: those folds *are* value-preserving, so two expressions sharing
# such a key really do compute the same value.
# ---------------------------------------------------------------------------
function _cse_key(e::ASTExpr, pgctx::Union{Nothing,_PGatherKeyCtx})
    return _cse_key(e, pgctx, _CSEKeyMemos())
end

# Per-build memo pair for CSE keying over a structurally-SHARED expression DAG
# (template expansion splices identical subtrees by reference, so the same
# node object hangs under exponentially many paths):
#
#   * `canon` — node object → its canonical form (or the `CanonicalizeError`
#     it raised, replayed on every later consumer so a shared failing subtree
#     declines every ancestor exactly as the plain recursion did).
#   * `key`   — node object → its `_cse_key` result (`String` or `nothing`).
#
# Both are keyed on OBJECT IDENTITY: keying is a pure function of the node
# (and the build-constant `pgctx`), so one computation per unique node is
# byte-identical to one per path. The count pass and the compile pass share
# ONE memo pair (via `_CSEContext`) for the same reason they share `pgctx`.
struct _CSEKeyMemos
    canon::IdDict{OpExpr,Any}   # ASTExpr result or CanonicalizeError
    key::IdDict{OpExpr,Any}     # String or nothing
end
_CSEKeyMemos() = _CSEKeyMemos(IdDict{OpExpr,Any}(), IdDict{OpExpr,Any}())

# Identity-memoized `canonicalize`: drives the recursion over unique nodes
# only, delegating the per-node work to `_canonicalize_shallow`
# (canonicalize.jl) — `canonicalize` is compositional, so this is
# byte-identical to the plain recursion on any tree and processes a shared
# subtree once on a DAG. A `CanonicalizeError` is memoized and re-thrown so
# repeated consumers of a failing shared subtree see the plain behavior.
function _canonicalize_memo(e::ASTExpr, memo::IdDict{OpExpr,Any})
    e isa OpExpr || return canonicalize(e)
    v = get(memo, e, nothing)
    if v !== nothing
        v isa CanonicalizeError && throw(v)
        return v::ASTExpr
    end
    local res::ASTExpr
    try
        new_args = Vector{ASTExpr}(undef, length(e.args))
        for (i, a) in enumerate(e.args)
            new_args[i] = _canonicalize_memo(a, memo)
        end
        res = _canonicalize_shallow(reconstruct(e; args=new_args))
    catch err
        if err isa CanonicalizeError
            memo[e] = err
        end
        rethrow()
    end
    memo[e] = res
    return res
end

function _cse_key(e::ASTExpr, pgctx::Union{Nothing,_PGatherKeyCtx},
                  memos::_CSEKeyMemos)
    if e isa OpExpr
        v = get(memos.key, e, _CSE_KEY_UNSET)
        v === _CSE_KEY_UNSET || return v
    end
    keyed = pgctx === nothing ? e : _pgather_key_expr(e, pgctx)
    r = try
        # `canonical_json` is `_emit_json ∘ canonicalize`; split it so the
        # canonical NODE can be inspected before it is flattened to bytes.
        canon = _canonicalize_memo(keyed, memos.canon)
        # Fail-close on a non-value-preserving collapse to a literal.
        (canon isa NumExpr || canon isa IntExpr) ? nothing : _emit_json(canon)
    catch err
        err isa CanonicalizeError || rethrow()
        nothing
    end
    e isa OpExpr && (memos.key[e] = r)
    return r
end

# Sentinel distinguishing "not memoized yet" from a memoized `nothing` key.
struct _CSEKeyUnset end
const _CSE_KEY_UNSET = _CSEKeyUnset()

# Is argument `i` of `op` evaluated CONDITIONALLY — i.e. only when a sibling
# argument takes a particular value? Exactly the three lazy/short-circuiting arms of
# `_eval_node_op`: `ifelse` walks only the taken branch (args 2 and 3), and `and` /
# `or` stop at the first decisive argument (args 2..n). Arg 1 of all three is always
# evaluated. Every other op evaluates all of its arguments, always.
#
# This is the ONE place the guard structure is declared; `_cse_count!` propagates the
# flag to all descendants, so a node inside a guarded arm is guarded however deep.
@inline _cse_arg_conditional(op::String, i::Int) =
    (op == "ifelse" && i >= 2) || ((op == "and" || op == "or") && i >= 2)

# Count pass: tally `canonical_json` occurrences of every hoistable subexpression
# across all RHS trees, splitting each key's tally into (TOTAL, UNCONDITIONAL).
#
# An occurrence is CONDITIONAL iff it sits under a guard — under a lazy `ifelse`
# branch or a short-circuited `and`/`or` argument, at any depth. Two counts, not
# one, because the hoist rule needs both (see the GUARDS note above): >= 2 total
# occurrences makes a key worth hoisting, and >= 1 unconditional occurrence makes
# hoisting it SAFE — the original walk evaluates it at that occurrence regardless,
# so the prelude's unconditional evaluation introduces no throw or NaN the walk
# did not already have.
#
# Occurrences are counted as PATHS through the expression, exactly as the
# original per-path recursion did — but computed by multiplicity propagation
# over the UNIQUE-node DAG (template expansion splices identical subtrees by
# reference, so one node object can hang under exponentially many paths; the
# naive recursion re-walked and re-keyed it once per path). One reverse-
# postorder pass pushes each node's (total, unconditional) path multiplicity
# to its children — a conditional argument edge forwards no unconditional
# multiplicity — and each unique node is then keyed ONCE and contributes its
# multiplicities to its key's tally. On a pure tree this produces the same
# numbers as the recursion, occurrence for occurrence; additions saturate at
# `typemax(Int)` so a deeply-shared DAG cannot overflow the tally (the hoist
# rule only ever asks >= 2 / >= 1).
function _cse_count!(e::ASTExpr, counts::Dict{String,Tuple{Int,Int}},
                     pgctx::Union{Nothing,_PGatherKeyCtx},
                     memos::_CSEKeyMemos=_CSEKeyMemos())
    (e isa OpExpr && _cse_hoistable(e)) || return
    # Unique hoistable nodes in postorder (children before parents). The walk
    # descends only through hoistable nodes — a non-hoistable node is a
    # counting barrier, exactly as in the original recursion.
    order = OpExpr[]
    seen = IdDict{OpExpr,Nothing}()
    function dfs(n::ASTExpr)
        (n isa OpExpr && _cse_hoistable(n)) || return
        haskey(seen, n) && return
        seen[n] = nothing
        for a in n.args
            dfs(a)
        end
        push!(order, n)
    end
    dfs(e)
    total = IdDict{OpExpr,Int}()
    uncond = IdDict{OpExpr,Int}()
    total[e] = 1
    uncond[e] = 1
    # Reverse postorder = parents before children along DAG edges.
    for i in length(order):-1:1
        n = order[i]
        t = get(total, n, 0)
        u = get(uncond, n, 0)
        for (j, a) in enumerate(n.args)
            (a isa OpExpr && _cse_hoistable(a)) || continue
            total[a] = _sat_add(get(total, a, 0), t)
            if !_cse_arg_conditional(n.op, j)
                uncond[a] = _sat_add(get(uncond, a, 0), u)
            end
        end
    end
    for n in order
        k = _cse_key(n, pgctx, memos)
        k === nothing && continue
        t0, u0 = get(counts, k, (0, 0))
        counts[k] = (_sat_add(t0, total[n]), _sat_add(u0, get(uncond, n, 0)))
    end
    return
end

# Saturating add for path-multiplicity tallies: a structurally-shared DAG can
# have more paths than an `Int` holds, and the consumers only ever compare
# against small thresholds.
_sat_add(a::Int, b::Int) = a > typemax(Int) - b ? typemax(Int) : a + b

# The CSE prelude's per-call scratch, captured on every `_NK_CACHED` node at
# build time and refilled at the top of each `f!` call. TWO buffers, because the
# RHS has two value types (see `_rhs_value_type`):
#
#   * `f64`  — the production `Float64` slots. Sized once at build; `f!` writes it
#              and `_NK_CACHED` reads it, exactly as before this struct existed.
#   * `alt`  — the buffer for whatever NON-`Float64` value type last called `f!`
#              (a `Vector{Dual}` under ForwardDiff). `nothing` until the first such
#              call, so a model that is only ever integrated pays ZERO extra memory
#              and takes ZERO extra branches: `_cse_buf`/`_cse_read` dispatch on
#              `Type{Float64}` and compile to a bare field load.
#
# Kept as ONE cache object per evaluator (not per Dual type) because ForwardDiff
# uses a single `Dual{Tag,V,N}` for the whole Jacobian: the buffer is allocated on
# the first Dual call and reused by every later one. Alternating between two
# distinct Dual types would re-allocate `alt` each call — correct, just not free —
# which is the same non-reentrancy bargain the `_VecNode` buffers already make.
#
# Each buffer carries its OWN const-tier validity stamp (`stamp64` / `stampalt`): the
# `p` whose const slots that buffer currently holds, or `_CSE_INVALID`. The stamp is
# PER BUFFER and not merely per `p`, and that is load-bearing — a freshly allocated
# `alt` is `undef`, so "`p` has not changed, skip the const slots" would read GARBAGE
# on the first `Dual` call if the two buffers shared one stamp. `_cse_buf` therefore
# invalidates the stamp of any buffer it allocates. See const_tier.jl for the tier.
mutable struct _CSECache
    f64::Vector{Float64}
    alt::Any
    stamp64::Any
    stampalt::Any
end

# "This buffer's const slots hold nothing valid." A private singleton, so it is `!==`
# every possible `p` — including `nothing`, the parameter-free model's `p` sentinel.
struct _CSEInvalid end
const _CSE_INVALID = _CSEInvalid()

_CSECache() = _CSECache(Float64[], nothing, _CSE_INVALID, _CSE_INVALID)

# Fetch the prelude scratch for value type `T`. `T` is a compile-time constant at
# every call site (it is derived from the argument TYPES — see `_rhs_value_type`),
# so exactly one of these two methods is compiled into any given `f!`
# specialization, and the `Float64` one is a field load.
#
# `f64` is allocated ONCE, at build time (`_cse_compile_scalar` sizes it, and
# `_share_lane_invariants!` may grow it), and never replaced — so its stamp can only
# be invalidated by a `p` change. `alt` is (re)allocated lazily here, and every fresh
# `alt` is `undef` memory whose const slots have never been filled: allocating one
# MUST invalidate its stamp.
@inline _cse_buf(c::_CSECache, ::Type{Float64}) = c.f64
@inline function _cse_buf(c::_CSECache, ::Type{T}) where {T}
    b = c.alt
    b isa Vector{T} && return b
    nb = Vector{T}(undef, length(c.f64))
    c.alt = nb
    c.stampalt = _CSE_INVALID
    return nb
end

# ---- The const tier's validity check (EarthSciSerialization-4qf) --------------
#
# A CONST prelude slot (const_tier.jl) depends only on `p`, so the value in the buffer
# stays good until `p` changes — or until the buffer itself is replaced. `f!` refills
# the const slots iff `_cse_const_stale` says so, and stamps the buffer afterwards.
#
# `===` (EGAL), not `==`, is the comparison. For an immutable `NamedTuple` of scalars
# that is a cheap bitwise compare, and it is exactly the right predicate: egal is
# STRICTLY FINER than `==` (it separates `0.0` from `-0.0`, and it makes two identical
# `NaN` bit patterns compare equal), so two `p`s that compare egal have bit-identical
# parameter values and therefore produce bit-identical const slots. Two NamedTuples
# with equal values are legitimately interchangeable; a `remake`d `p` with any
# different value is not egal and refills.
#
# `isbits(p)` is the fail-closed gate, and it is free: `typeof(p)` is a compile-time
# constant at every specialization, so this folds to a literal. A `p` carrying a
# MUTABLE field would compare by OBJECT IDENTITY under `===`, so an in-place mutation
# of that field would not move the stamp and the const slots would silently go stale.
# `p` is a NamedTuple of scalars (array-valued parameters ride `param_arrays`, and
# gather as `_NK_PARAM_GATHER`, which is never const), so this holds today — but the
# failure mode of it not holding is wrong numbers, so it is checked rather than assumed.
# `nothing` (the parameter-free sentinel) is `isbits`.
@inline _cse_const_stale(c::_CSECache, ::Type{Float64}, p) =
    !(isbits(p) && c.stamp64 === p)
@inline _cse_const_stale(c::_CSECache, ::Type{T}, p) where {T} =
    !(isbits(p) && c.stampalt === p)

# Record which `p` this buffer's const slots now hold. Storing into an `Any` field
# BOXES `p` — that is fine and deliberate: it happens only when `p` CHANGES, never on
# the repeated same-`p` calls whose zero-allocation property `f!` must keep (pinned by
# tree_walk_allocation_test.jl). A non-`isbits` `p` is never stored (see above).
@inline function _cse_mark_const!(c::_CSECache, ::Type{Float64}, p)
    c.stamp64 = isbits(p) ? p : _CSE_INVALID
    return nothing
end
@inline function _cse_mark_const!(c::_CSECache, ::Type{T}, p) where {T}
    c.stampalt = isbits(p) ? p : _CSE_INVALID
    return nothing
end

# Read slot `i`. The `::Vector{T}` assert is what keeps the read monomorphic out
# of the `Any` field; `f!` calls `_cse_buf` before the prelude runs, so `alt` is
# always a live `Vector{T}` by the time an `_NK_CACHED` node is evaluated.
@inline _cse_read(c::_CSECache, i::Int, ::Type{Float64}) = @inbounds c.f64[i]
@inline _cse_read(c::_CSECache, i::Int, ::Type{T}) where {T} =
    @inbounds (c.alt::Vector{T})[i]

# ---- The RHS value type -----------------------------------------------------
#
# The type the RHS computes in, fixed by the three runtime inputs: the state, the
# parameter VALUES, and time. Literals, const arrays and captured forcing buffers
# are `Float64` DATA — never differentiated — so they promote INTO this type rather
# than constraining it (and, for `^`, deliberately do not: see `_eval_node_op`).
#
# Deriving `T` from all three (not just `eltype(u)`) is load-bearing. Under
# ForwardDiff-over-PARAMETERS `u` is a plain `Vector{Float64}` and only the `p`
# values are `Dual`; a scratch buffer sized from `eltype(u)` alone would compile
# fine and then throw `Float64(::Dual)` on the first store.
#
# Every argument's TYPE determines the answer, so inference constant-folds this to
# a `Type{…}` at each `f!` specialization — which is what makes `_cse_buf`/`_vbuf`
# static dispatches and keeps the Float64 path byte-for-byte what it was.
#
# (oop.jl's `_oop_value_type` is this same function under the emitter-local
# name — `const _oop_value_type = _rhs_value_type` — so the two emitters agree
# on the value type by construction.)
@inline _promote_val_types(::Tuple{}) = Bool   # identity for `promote_type`
@inline _promote_val_types(x::Tuple) =
    promote_type(typeof(x[1]), _promote_val_types(Base.tail(x)))

@inline _rhs_value_type(u, p::NamedTuple, t) =
    promote_type(eltype(u), _promote_val_types(values(p)), typeof(t))

# A parameter-free model carries SciMLBase's `nothing` sentinel instead of an empty
# NamedTuple (see `_build_state_layout`); with no parameters there is nothing for it
# to contribute to the value type.
@inline _rhs_value_type(u, ::Nothing, t) = promote_type(eltype(u), typeof(t))

# ---- Float32 state guard ----------------------------------------------------
#
# `Float32` state is refused LOUDLY at the RHS entry. The walkers are
# eltype-generic, but every literal, const array, and captured forcing buffer is
# `Float64` DATA — so a `Float32` `u` does not buy a Float32 pipeline: it
# promotes to `T == Float64` at the first operator and the whole RHS computes in
# Float64 anyway, plus one convert per state read/store. That is strictly SLOWER
# than handing the same values over as `Float64`, and the silent promotion hides
# it, so rejecting is the kindness. The `eltype` test is static per `f!`/`f`
# specialization, so at Float64 (and under AD `Dual`s) the branch folds away and
# the zero-alloc / instruction-identical property of the hot path is untouched.
@inline function _reject_float32_state(u)
    eltype(u) === Float32 && throw(TreeWalkError("E_TREEWALK_FLOAT32_STATE",
        "Float32 state is not supported: the compiled RHS's literals and const " *
        "data are Float64, so Float32 `u` silently promotes and computes in " *
        "Float64 anyway — with an extra convert per state access, i.e. strictly " *
        "slower than Float64 state. Pass the state as Vector{Float64}."))
    return nothing
end

# Mutable CSE compile context: the set of cached keys, the slot assigned to each
# (assigned lazily, in topological order, at first compile), the prelude
# definitions (`defs[s]` computes `cache[s]`), the shared scratch the
# `_NK_CACHED` nodes read from, and the live-forcing stand-in context the keys were
# COUNTED with (`nothing` on a build with no forcing buffers). The count pass and
# the compile pass MUST key with the same `pgctx` or their keys would not match.
mutable struct _CSEContext
    cached::Set{String}
    slot::Dict{String,Int}
    defs::Vector{_Node}
    cache::_CSECache
    pgctx::Union{Nothing,_PGatherKeyCtx}
    # The SAME key/canonical memo pair the count pass used (the two passes
    # must key identically), plus a compiled-node identity memo so a subtree
    # shared under many parents is lowered once (`_compile_cse` is a pure
    # function of the node for a fixed build context).
    keymemos::_CSEKeyMemos
    compiled::IdDict{OpExpr,_Node}
end

# Rebuild the `_Node` that plain `_compile` would emit for a hoistable `expr`,
# but with each operand lowered through `_compile_cse` so a shared operand
# becomes a `_NK_CACHED` ref. The `fn` arm delegates to `_compile_fn_node` — the
# SAME lowering `_compile_op` uses — so the closed-function payload contract
# (const-arg extraction, typed `_Interp*Spec`, spec-order scalar children) is
# single-sourced; only the scalar children route through CSE. Every other
# hoistable op is a plain `_NK_OP` whose operands are all scalar.
function _cse_rebuild(expr::OpExpr, var_map, param_syms, reg_funcs, ctx::_CSEContext)
    if expr.op == "fn"
        return _compile_fn_node(expr,
            a -> _compile_cse(a, var_map, param_syms, reg_funcs, ctx))
    end
    children = _Node[_compile_cse(a, var_map, param_syms, reg_funcs, ctx)
                     for a in expr.args]
    return _mknode(kind=_NK_OP, op=Symbol(expr.op), children=children)
end

# Compile `expr` to a `_Node`, hoisting any subexpression whose canonical key is
# in `ctx.cached` into the prelude and replacing it with a `_NK_CACHED` ref.
# Falls back to plain `_compile` for leaves and opaque ops, so the result is
# identical to `_compile` wherever nothing is hoisted.
function _compile_cse(expr::ASTExpr, var_map, param_syms, reg_funcs, ctx::_CSEContext)
    (expr isa OpExpr && _cse_hoistable(expr)) ||
        return _compile(expr, var_map, param_syms, reg_funcs)

    # Identity memo: the lowering of a node is a pure function of the node for
    # a fixed build context, so a subtree shared under many parents (template
    # expansion splices by reference) is lowered once. The memoized value is a
    # `_NK_CACHED` ref for hoisted nodes and the rebuilt `_Node` otherwise —
    # both stable after the first visit (the first visit performs any slot
    # assignment, so def order is unchanged).
    memoized = get(ctx.compiled, expr, nothing)
    memoized === nothing || return memoized

    key = _cse_key(expr, ctx.pgctx, ctx.keymemos)
    local out::_Node
    if key !== nothing && key in ctx.cached
        s = get(ctx.slot, key, 0)
        if s != 0
            out = _mknode(kind=_NK_CACHED, idx=s, payload=ctx.cache)
        else
            # First occurrence: compile children first (assigning them lower
            # slots, keeping `defs` topologically ordered), reserve this slot,
            # register the def, and return a ref. Every later occurrence hits
            # the `s != 0` path.
            defnode = _cse_rebuild(expr, var_map, param_syms, reg_funcs, ctx)
            s = length(ctx.defs) + 1
            ctx.slot[key] = s
            push!(ctx.defs, defnode)
            out = _mknode(kind=_NK_CACHED, idx=s, payload=ctx.cache)
        end
    else
        # Not cached: reconstruct the same `_Node` `_compile` would, but with
        # hoisted children.
        out = _cse_rebuild(expr, var_map, param_syms, reg_funcs, ctx)
    end
    ctx.compiled[expr] = out
    return out
end

# Compile a batch of scalar `(state_index, resolved_rhs_expr)` entries with
# cross-equation + intra-expression CSE. Returns the compiled rhs list, the
# prelude (slot-ordered def nodes), the shared cache vector, and a diagnostic
# `(; n_slots, n_occurrences)` that witnesses the evaluate-once property
# (criterion #2: distinct evaluations == distinct canonical subexpressions).
# `has_pgather` is whether the build bound ANY live forcing buffer or discrete
# cache (`!isempty(pgather)`). It is a required keyword, not a defaulted one: a
# forgotten `false` would silently restore the ess-qic coverage hole rather than
# fail, and a hole that fails closed is exactly the bug this argument exists to fix.
function _cse_compile_scalar(entries::Vector{Tuple{Int,ASTExpr}},
                             var_map, param_syms, reg_funcs; has_pgather::Bool)
    pgctx = has_pgather ? _PGatherKeyCtx() : nothing
    # One memo pair for BOTH passes: count and compile must key identically.
    keymemos = _CSEKeyMemos()
    counts = Dict{String,Tuple{Int,Int}}()
    for (_, e) in entries
        _cse_count!(e, counts, pgctx, keymemos)
    end
    cached = Set{String}()
    n_occ = 0
    for (k, (total, uncond)) in counts
        # Hoist iff it is WORTH it (>= 2 occurrences) and SAFE (>= 1 of them
        # unconditional — the prelude then evaluates nothing the walk would not).
        # A key occurring only under guards stays inline, behind its guard.
        if total >= 2 && uncond >= 1
            push!(cached, k)
            n_occ += total   # every occurrence of a cached key becomes a cache read
        end
    end
    cache = _CSECache()
    ctx = _CSEContext(cached, Dict{String,Int}(), _Node[], cache, pgctx,
                      keymemos, IdDict{OpExpr,_Node}())
    rhs_list = Tuple{Int,_Node}[]
    for (idx, e) in entries
        push!(rhs_list, (idx, _compile_cse(e, var_map, param_syms, reg_funcs, ctx)))
    end
    # Size the scratch to the number of slots. `cache` is the SAME object the
    # `_NK_CACHED` nodes captured, so this in-place resize is visible to them.
    # (`alt` is sized from `f64` on first use, i.e. after this.)
    resize!(cache.f64, length(ctx.defs))
    diag = (; n_slots = length(ctx.defs), n_occurrences = n_occ)
    return rhs_list, ctx.defs, cache, diag
end

# ============================================================
# 4. Compiled walker
# ============================================================

# The value type `T` is threaded through the whole walk (rather than re-derived at
# each node) so that every `Type{T}`-dispatched scratch lookup — `_cse_read` here,
# `_vbuf` on the vectorized side — is resolved statically.
#
# NOTHING in this walker CONVERTS to `T`. A leaf returns whatever it natively holds
# and Julia's promotion does the rest: a `Float64` literal beside a `Dual` state
# promotes at the operator, which is both correct (a constant's derivative is zero)
# and, for `^`, ESSENTIAL — see the note on the `^` arm in `_eval_node_op`. So under
# AD the return type is the small union `Union{Float64,T}`, which Julia union-splits;
# at `T === Float64` it collapses to `Float64` and this is the pre-existing walker,
# instruction for instruction.
#
# The 4-arg form is the build-time / test entry point (constant folding, initial
# conditions, loop bounds): it derives `T` from the arguments, which are `Float64`
# there, so it lands on the same specialization.
@inline _eval_node(n::_Node, u, p, t) = _eval_node(n, u, p, t, _rhs_value_type(u, p, t))

@inline function _eval_node(n::_Node, u, p, t, ::Type{T}) where {T}
    k = n.kind
    if k === _NK_LITERAL
        return n.literal
    elseif k === _NK_STATE
        @inbounds return u[n.idx]
    elseif k === _NK_PARAM
        return getfield(p, n.sym)
    elseif k === _NK_PARAM_GATHER
        # Live read of a captured forcing buffer (ess-14f.3). `payload` is the
        # aliased flat `Vector{Float64}` (a `_PGatherArray.flat`) and `idx` the
        # pre-linearized column-major offset, both fixed at build time; the buffer
        # CONTENTS are refreshed in place by the J1 discrete callback. The concrete
        # `::Vector{Float64}` assert keeps this monomorphic + zero-alloc (no
        # runtime-symbol `getfield`, so the scalar `p` NamedTuple stays homogeneous).
        @inbounds return (n.payload::Vector{Float64})[n.idx]
    elseif k === _NK_TIME
        return t
    elseif k === _NK_CACHED
        # Common-subexpression reference (ess-r7h). The value was computed once
        # into the per-call scratch cache by the CSE prelude (see `_make_rhs`);
        # every occurrence reads it here instead of re-walking the subtree. The
        # `_CSECache` is captured in `payload` at build time; `T` selects which of
        # its two buffers holds this call's values (Float64 slots vs. the Dual
        # buffer ForwardDiff drove `f!` with).
        return _cse_read(n.payload::_CSECache, n.idx, T)
    elseif k === _NK_CONTRACTION
        return _eval_contraction(n, u, p, t, T)
    else
        return _eval_node_op(n, u, p, t, T)
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
function _eval_contraction(n::_Node, u, p, t, ::Type{T}) where {T}
    op = n.op
    children = n.children
    if op === :+
        s = n.literal  # 0̄ = 0.0 for sum_product
        @inbounds for k in eachindex(children)
            s += _eval_node(children[k], u, p, t, T)
        end
        return s
    elseif op === :*
        s = n.literal  # 1̄ for the ×-reduce
        @inbounds for k in eachindex(children)
            s *= _eval_node(children[k], u, p, t, T)
        end
        return s
    elseif op === :max
        s = n.literal  # -∞
        @inbounds for k in eachindex(children)
            s = max(s, _eval_node(children[k], u, p, t, T))
        end
        return s
    else  # :min
        s = n.literal  # +∞
        @inbounds for k in eachindex(children)
            s = min(s, _eval_node(children[k], u, p, t, T))
        end
        return s
    end
end

function _eval_node_op(n::_Node, u, p, t, ::Type{T}) where {T}
    op = n.op
    c = n.children

    # Arithmetic — the hot paths.
    if op === :+
        length(c) == 1 && return _eval_node(c[1], u, p, t, T)
        acc = _eval_node(c[1], u, p, t, T)
        @inbounds for i in 2:length(c)
            acc += _eval_node(c[i], u, p, t, T)
        end
        return acc
    elseif op === :*
        length(c) == 1 && return _eval_node(c[1], u, p, t, T)
        acc = _eval_node(c[1], u, p, t, T)
        @inbounds for i in 2:length(c)
            acc *= _eval_node(c[i], u, p, t, T)
        end
        return acc
    elseif op === :-
        if length(c) == 1
            return -_eval_node(c[1], u, p, t, T)
        elseif length(c) == 2
            return _eval_node(c[1], u, p, t, T) - _eval_node(c[2], u, p, t, T)
        end
        throw(TreeWalkError("E_TREEWALK_ARITY", "- expects 1 or 2 args"))
    elseif op === :neg
        # Canonical-form unary negation. `canonicalize` rewrites unary
        # `-x` to `neg(x)`, so any AST that has been through `discretize`
        # may carry `neg` ops where the source had `-x`.
        _expect_arity_n(op, c, 1)
        return -_eval_node(c[1], u, p, t, T)
    elseif op === :/
        _expect_arity_n(op, c, 2)
        return _eval_node(c[1], u, p, t, T) / _eval_node(c[2], u, p, t, T)
    elseif op === :^ || op === :pow
        # A LITERAL EXPONENT MUST STAY A `Float64`, and this arm is why the walker
        # never converts its leaves into `T`. `^` is the one op whose derivative
        # w.r.t. an OPERAND needs a function with a smaller domain than the op
        # itself: ∂(x^y)/∂y = x^y·log(x). Hand ForwardDiff a `Dual` exponent and it
        # takes that branch even when the exponent's partials are all zero, so
        # `c^2` at any NEGATIVE c evaluates log(c) and silently poisons the gradient
        # with NaN while the primal value still looks perfect. Because
        # `_NK_LITERAL` returns its raw `Float64`, this compiles to `Dual^Float64`
        # — the power rule, defined on the whole domain `^` is. (The vectorized twin
        # gets the same protection from `_VK_LITERAL`/`_VK_CONSTVEC` staying
        # `Vector{Float64}`; see `_eval_vec`.) An exponent that genuinely depends on
        # a differentiated variable still lands on `Dual^Dual`, which is correct.
        _expect_arity_n(op, c, 2)
        return _eval_node(c[1], u, p, t, T) ^ _eval_node(c[2], u, p, t, T)

    # Comparisons → 1.0/0.0 (match `evaluate` semantics)
    elseif op === :<
        _expect_arity_n(op, c, 2)
        return _eval_node(c[1], u, p, t, T) <  _eval_node(c[2], u, p, t, T) ? 1.0 : 0.0
    elseif op === Symbol("<=")
        _expect_arity_n(op, c, 2)
        return _eval_node(c[1], u, p, t, T) <= _eval_node(c[2], u, p, t, T) ? 1.0 : 0.0
    elseif op === :>
        _expect_arity_n(op, c, 2)
        return _eval_node(c[1], u, p, t, T) >  _eval_node(c[2], u, p, t, T) ? 1.0 : 0.0
    elseif op === Symbol(">=")
        _expect_arity_n(op, c, 2)
        return _eval_node(c[1], u, p, t, T) >= _eval_node(c[2], u, p, t, T) ? 1.0 : 0.0
    elseif op === Symbol("==")
        _expect_arity_n(op, c, 2)
        return _eval_node(c[1], u, p, t, T) == _eval_node(c[2], u, p, t, T) ? 1.0 : 0.0
    elseif op === Symbol("!=")
        _expect_arity_n(op, c, 2)
        return _eval_node(c[1], u, p, t, T) != _eval_node(c[2], u, p, t, T) ? 1.0 : 0.0

    # Logical
    elseif op === :and
        for child in c
            _eval_node(child, u, p, t, T) == 0 && return 0.0
        end
        return 1.0
    elseif op === :or
        for child in c
            _eval_node(child, u, p, t, T) != 0 && return 1.0
        end
        return 0.0
    elseif op === :not
        _expect_arity_n(op, c, 1)
        return _eval_node(c[1], u, p, t, T) == 0 ? 1.0 : 0.0

    elseif op === :ifelse
        _expect_arity_n(op, c, 3)
        return _eval_node(c[1], u, p, t, T) != 0 ?
               _eval_node(c[2], u, p, t, T) :
               _eval_node(c[3], u, p, t, T)

    # Elementary functions
    elseif op === :sin;   _expect_arity_n(op, c, 1); return sin(_eval_node(c[1], u, p, t, T))
    elseif op === :cos;   _expect_arity_n(op, c, 1); return cos(_eval_node(c[1], u, p, t, T))
    elseif op === :tan;   _expect_arity_n(op, c, 1); return tan(_eval_node(c[1], u, p, t, T))
    elseif op === :asin;  _expect_arity_n(op, c, 1); return asin(_eval_node(c[1], u, p, t, T))
    elseif op === :acos;  _expect_arity_n(op, c, 1); return acos(_eval_node(c[1], u, p, t, T))
    elseif op === :atan
        if length(c) == 1
            return atan(_eval_node(c[1], u, p, t, T))
        elseif length(c) == 2
            return atan(_eval_node(c[1], u, p, t, T), _eval_node(c[2], u, p, t, T))
        end
        throw(TreeWalkError("E_TREEWALK_ARITY", "atan expects 1 or 2 args"))
    elseif op === :atan2
        _expect_arity_n(op, c, 2)
        return atan(_eval_node(c[1], u, p, t, T), _eval_node(c[2], u, p, t, T))
    elseif op === :sinh;  _expect_arity_n(op, c, 1); return sinh(_eval_node(c[1], u, p, t, T))
    elseif op === :cosh;  _expect_arity_n(op, c, 1); return cosh(_eval_node(c[1], u, p, t, T))
    elseif op === :tanh;  _expect_arity_n(op, c, 1); return tanh(_eval_node(c[1], u, p, t, T))
    elseif op === :asinh; _expect_arity_n(op, c, 1); return asinh(_eval_node(c[1], u, p, t, T))
    elseif op === :acosh; _expect_arity_n(op, c, 1); return acosh(_eval_node(c[1], u, p, t, T))
    elseif op === :atanh; _expect_arity_n(op, c, 1); return atanh(_eval_node(c[1], u, p, t, T))
    elseif op === :exp;   _expect_arity_n(op, c, 1); return exp(_eval_node(c[1], u, p, t, T))
    elseif op === :log;   _expect_arity_n(op, c, 1); return log(_eval_node(c[1], u, p, t, T))
    elseif op === :log10; _expect_arity_n(op, c, 1); return log10(_eval_node(c[1], u, p, t, T))
    elseif op === :sqrt;  _expect_arity_n(op, c, 1); return sqrt(_eval_node(c[1], u, p, t, T))
    elseif op === :abs;   _expect_arity_n(op, c, 1); return abs(_eval_node(c[1], u, p, t, T))
    elseif op === :sign;  _expect_arity_n(op, c, 1); return sign(_eval_node(c[1], u, p, t, T))
    elseif op === :floor; _expect_arity_n(op, c, 1); return floor(_eval_node(c[1], u, p, t, T))
    elseif op === :ceil;  _expect_arity_n(op, c, 1); return ceil(_eval_node(c[1], u, p, t, T))
    elseif op === :min
        # n-ary min (esm-spec §4.2 — arity ≥ 2)
        length(c) < 2 && throw(TreeWalkError("E_TREEWALK_ARITY", "min needs ≥2 args"))
        acc = _eval_node(c[1], u, p, t, T)
        @inbounds for i in 2:length(c); acc = min(acc, _eval_node(c[i], u, p, t, T)); end
        return acc
    elseif op === :max
        # n-ary max (esm-spec §4.2 — arity ≥ 2)
        length(c) < 2 && throw(TreeWalkError("E_TREEWALK_ARITY", "max needs ≥2 args"))
        acc = _eval_node(c[1], u, p, t, T)
        @inbounds for i in 2:length(c); acc = max(acc, _eval_node(c[i], u, p, t, T)); end
        return acc

    elseif op === :pi || op === :π
        return Float64(pi)
    elseif op === :e
        return Float64(ℯ)

    elseif op === :Pre
        _expect_arity_n(op, c, 1)
        return _eval_node(c[1], u, p, t, T)

    elseif op === :fn
        # `n.payload` is `(fname::String, spec_or_nothing)`. For `interp.*` the
        # second slot is a build-time-validated typed `_Interp*Spec`; the payload
        # is the CONCRETE `Tuple{String,_Interp*Spec}`. We `isa`-match that whole
        # concrete tuple type (NOT `Tuple{String,Any}`) so extracting the spec
        # stays concrete — reading the second slot as `Any` would re-box the
        # inline immutable struct on EVERY call (~16 B / interp leaf). Each arm
        # then calls the validation-free `_interp_*_core` kernel directly with the
        # evaluated scalar child query — no per-call box, no per-call axis
        # re-validation, no `_fn_const_arg_spec` scan (all paid ONCE at build
        # time). Bit-identical to the vectorized `_eval_vec_interp_*` kernels:
        # SAME core, SAME const arrays. Scalar query children are compiled in spec
        # order excluding the const positions (`_compile_op`): linear → c[1]=x;
        # bilinear → c[1]=x, c[2]=y; searchsorted → c[1]=x.
        pl = n.payload
        if pl isa Tuple{String,_InterpLinearSpec}
            spec = pl[2]
            x = _eval_node(c[1], u, p, t, T)
            return _interp_linear_core(spec.table, spec.axis, x)
        elseif pl isa Tuple{String,_InterpBilinearSpec}
            spec = pl[2]
            x = _eval_node(c[1], u, p, t, T)
            y = _eval_node(c[2], u, p, t, T)
            return _interp_bilinear_core(spec.table, spec.axis_x, spec.axis_y, x, y)
        elseif pl isa Tuple{String,_InterpSearchsortedSpec}
            spec = pl[2]
            x = _eval_node(c[1], u, p, t, T)
            # `convert(T, …)`, not `Float64(…)`: the index is discrete (no
            # derivative), but the ARM must still land in the evaluator's value
            # type or the `:fn` arm infers as a `Union` under ForwardDiff.
            return convert(T, _interp_searchsorted_core("interp.searchsorted", x, spec.xs))
        elseif pl isa Tuple{String,Nothing}
            # All-scalar closed functions (e.g. `datetime.*`): boxed path. The
            # children are the full spec-order arg list; a cold case off the
            # numeric RHS hot path, so the residual `Vector{Any}` is tolerated.
            #
            # This is the site the ForwardDiff Jacobian used to die on. Because
            # `_eval_node` is type-stable in `T`, the children arrive as `Dual`s
            # even when the model differentiates only w.r.t. `u` — and the old
            # `Float64(…)` coercion (here, and inside the registry) rejected them.
            #
            # `_eval_closed_fn` picks the registry on `T` at COMPILE time: at
            # `T === Float64` it folds to the `Float64`-pinned
            # `evaluate_closed_function`, keeping this arm's inferred type at the
            # concrete `Union{Float64,Int32}` that `_eval_node_op` — and with it
            # the zero-allocation RHS — depends on. See `evaluate_closed_function_ad`.
            fname = pl[1]
            args_evaluated = Any[_eval_node(ci, u, p, t, T) for ci in c]
            return convert(T, _eval_closed_fn(fname, args_evaluated, T))
        end
        # Unreachable if `_compile_op` and this arm agree (via
        # `_FN_CONST_ARG_SPECS`) on which closed functions carry a typed spec —
        # throw explicitly rather than falling through to an implicit `nothing`.
        throw(TreeWalkError("E_TREEWALK_UNKNOWN_CLOSED_FUNCTION",
            "fn payload $(typeof(pl)) is neither a typed interp spec tuple nor (String, Nothing)"))

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
