# tree_walk/gather_resolve.jl — gathers: which subscripts are known only
# at run time, the guarded out-of-range rule, const and inline-const reads,
# and the run-time state gather.

# True iff a subscript's value is known only at run time: it references a name
# no integer environment binds here — a bound output-index symbol, or a
# parameter, a state, an observed or `t` (esm-spec §4.3.2 lets a subscript be
# any integer-valued expression) — or reads an array producer. After loop substitution every other name a
# subscript holds is an array in an `index` head position or a binder of a
# producer inside it. `local` holds names that do not count: a producer's own
# binders, and for a caller that keeps bound symbols on its own path, those.
function _subscript_is_runtime(
        e::ASTExpr, local_names::Set{String},
        const_arrays::Union{Nothing, AbstractDict} = nothing
    )::Bool
    e isa VarExpr && return !((e::VarExpr).name in local_names)
    e isa OpExpr || return false
    o = e::OpExpr
    # An array producer read at the subscript (`c[j[i]]` with `j` an inlined
    # faq) has no integer evaluation; resolved, it is the producer's body at
    # that subscript, evaluated in floating point as the run time would.
    _is_array_producer(o) && return true
    inner = local_names
    binders = String[]
    o.output_idx === nothing || for x in o.output_idx
        x isa AbstractString && push!(binders, String(x))
    end
    o.ranges === nothing || for k in keys(o.ranges)
        push!(binders, String(k))
    end
    isempty(binders) || (inner = union(local_names, binders))
    for (k, a) in enumerate(_operands(o))
        if k == 1 && o.op == "index" && a isa VarExpr
            # A gather from anything but a const array (a state, a
            # materialized observed) reads a run-time value.
            (const_arrays === nothing || haskey(const_arrays, (a::VarExpr).name)) ||
                return true
            continue
        end
        _subscript_is_runtime(a, inner, const_arrays) && return true
    end
    o.expr_body === nothing ||
        (_subscript_is_runtime(o.expr_body, inner, const_arrays) && return true)
    o.filter === nothing ||
        (_subscript_is_runtime(o.filter, inner, const_arrays) && return true)
    if o.values !== nothing
        for v in o.values
            _subscript_is_runtime(v, inner, const_arrays) && return true
        end
    end
    return false
end
_subscript_is_runtime(e::ASTExpr, const_arrays::AbstractDict) =
    _subscript_is_runtime(e, _EMPTY_BOUND_SYMS, const_arrays)

# True iff a run-time subscript is built only from loop counters — a bound
# output-index symbol of a symbolic resolve, or a contraction loop variable
# (`__esm_lv_*`) — integer literals, `+ - *`, and a quotient that is the DIRECT
# operand of `floor` or `ceil`: what a gather can evaluate from the counters
# alone (`_index_int`) and the walk can compile. (`mod` is no esm operator, so
# the scalar compiler refuses it; admitting it here would refuse a subscript the
# unrolled fold evaluates.) The rounded quotient is the cell-to-row
# reindex a flattened loader field takes (`F[floor((c - 1) / NX) + 1, c - NX *
# floor((c - 1) / NX)]`).
#
# Every intermediate must be an integer, because the traced evaluator works in
# integers while the walk evaluates the subscript in floating point and rounds
# once at the end. So a quotient anywhere else (`floor(2 * (k / 3))`,
# `floor(k / 2 + k / 3)`, a bare `k / 2`) and a non-integer literal
# (`floor(k * 0.5)`) are refused: the two evaluators would read different rows.
# The quotient's own operands follow the same rule. A subscript that reads a
# state, an observed, a parameter, `t` or an array is not one.
_subscript_from_counters(e::VarExpr, bound_syms::Set{String}) =
    e.name in bound_syms || startswith(e.name, _LOOPVAR_PREFIX)
_subscript_from_counters(::IntExpr, ::Set{String}) = true
_subscript_from_counters(e::NumExpr, ::Set{String}) = isinteger(e.value)
function _subscript_from_counters(e::OpExpr, bound_syms::Set{String})
    op = e.op
    if op == "+" || op == "-" || op == "*"
        return all(a -> _subscript_from_counters(a, bound_syms), e.args)
    elseif (op == "floor" || op == "ceil") && length(e.args) == 1
        q = e.args[1]
        q isa OpExpr && q.op == "/" && length(q.args) == 2 &&
            return all(a -> _subscript_from_counters(a, bound_syms), q.args)
        return _subscript_from_counters(q, bound_syms)
    end
    return false
end
_subscript_from_counters(::ASTExpr, ::Set{String}) = false

# ── Guarded out-of-range reads ───────────────────────────────────────────────
# esm-spec evaluates `ifelse` lazily and `and` / `or` with short circuit, so a
# const read out of range under a branch the cell does not take is no error
# (the interpreter raises E_TREEWALK_CONSTARRAY_OOB where a read is
# EVALUATED). The resolve below builds every branch, so it keeps the guards
# the node being resolved sits under (`_ResolveCtx.guards`): the resolved
# condition and the truth value its branch needs. An out-of-range constant
# subscript is then raised at build only when every guard is decided at build
# and taken; otherwise it becomes a run-time gather that raises the same error
# if it is ever evaluated.

# Whether the read the current guards protect is certainly evaluated: every
# guard reads only literals (so its value is the build's to know) and has the
# value its branch needs. A guard that reads any name — a state, a parameter,
# an observed, `t` — is decided at run time.
function _guarded_read_taken(guards::_ResolveGuards)
    for (c, want) in guards
        isempty(_referenced_var_names(c)) || return false
        v = try
            _eval_node(
                _compile(c, Dict{String, Int}(), Set{Symbol}()),
                Float64[], NamedTuple(), 0.0
            )
        catch err
            err isa EarthSciASTError || rethrow()
            return false
        end
        (v != 0) == want || return false
    end
    return true
end

# Whether an out-of-range read under the current guards is left for run time:
# some guard is in force and the build cannot show every one taken.
_guarded_oob_deferred(rc::_ResolveCtx) =
    !isempty(rc.guards) && !_guarded_read_taken(rc.guards)

@noinline _throw_pgather_oob(name, ci, n, d) = throw(
    TreeWalkError(
        "E_TREEWALK_PGATHER_OOB",
        "forcing array '$(name)' index $(ci) out of range [1, $(n)] on dim $(d)"
    )
)

# A const read at constant subscripts the build may not raise for (see above):
# the run-time gather, which resolves each subscript under the array's
# boundary policy when — and only if — it is evaluated.
_deferred_const_gather(vals::AbstractArray, name::String, subs::Vector{Int}) =
    OpExpr(
    "index", ASTExpr[IntExpr(Int64(i)) for i in subs];
    value = _ConstGatherRef(vals, name)
)

# Resolve `ifelse` / `and` / `or` with each lazily evaluated operand under its
# guard (see above). Every other operand is resolved exactly as the generic
# recursion does, and an unchanged node is returned as is.
function _resolve_guarded_op(expr::OpExpr, rc::_ResolveCtx)
    args = expr.args
    guards = rc.guards
    depth = length(guards)
    new_args = Vector{ASTExpr}(undef, length(args))
    res(a) = (a isa OpExpr || a isa VarExpr) ? _resolve_indices(a, rc) : a
    try
        new_args[1] = res(args[1])
        if expr.op == "ifelse"
            push!(guards, (new_args[1], true))
            new_args[2] = res(args[2])
            guards[end] = (new_args[1], false)
            new_args[3] = res(args[3])
        else
            for j in 2:length(args)
                push!(guards, (new_args[j - 1], expr.op == "and"))
                new_args[j] = res(args[j])
            end
        end
    finally
        resize!(guards, depth)
    end
    all(i -> new_args[i] === args[i], eachindex(args)) && return expr
    return reconstruct(expr; args = new_args)
end

# Gather from a build-time-constant Float64 array `vals` (registry `name`, used
# only for CSE identity / diagnostics) at the subscript expressions
# `idx_args_expr`. This is the ONE spelling of the const-array read, shared by
# the registered-const-array `index(name, …)` branch and the INLINE
# `index({op:const, value:[…]}, …)` branch below. Fully-constant subscripts fold
# to the scalar element (a `NumExpr` literal, the byte-identical frozen path); a
# subscript that references a bound output-index symbol kept symbolic (the
# compile-once `evaluate_cellwise` fast path, a non-empty `rc.bound`) keeps the
# read runtime-varying and lowers to a `_ConstGatherRef` (→ `_NK_CONST_GATHER`),
# with the constant dims still folded to `IntExpr`s under the same
# `_resolve_const_index` boundary policy.
function _resolve_const_array_gather(
        vals::AbstractArray, name::String, idx_args_expr::Vector{ASTExpr}, rc::_ResolveCtx
    )
    const_arrays, memo = rc.const_arrays, rc.memo
    length(idx_args_expr) == ndims(vals) ||
        throw(
        TreeWalkError(
            "E_TREEWALK_CONSTARRAY_NDIM",
            "const array '$(name)' is $(ndims(vals))D " *
                "but got $(length(idx_args_expr)) indices"
        )
    )
    if _anyof(a -> _subscript_is_runtime(a, const_arrays), idx_args_expr)
        sub_nodes = Vector{ASTExpr}(undef, length(idx_args_expr))
        guards = rc.guards
        for d in 1:ndims(vals)
            a = idx_args_expr[d]
            if _subscript_is_runtime(a, const_arrays)
                sub_nodes[d] = _resolve_indices(a, rc)
            else
                ci = _const_subscript_int(a, const_arrays)
                # The guarded out-of-range rule, as for a read at constant
                # subscripts only: under a guard the build cannot show taken,
                # the out-of-range constant stays for the run-time gather,
                # which raises if the read is ever evaluated.
                if !isempty(guards) && !(1 <= ci <= size(vals, d)) &&
                        _const_dim_boundary(vals, d) === :error &&
                        !_guarded_read_taken(guards)
                    memo === nothing || (memo.deferrals[] += 1)
                else
                    ci = _resolve_const_index(vals, name, d, ci, size(vals, d))
                end
                sub_nodes[d] = IntExpr(Int64(ci))
            end
        end
        return OpExpr("index", sub_nodes; value = _ConstGatherRef(vals, name))
    end
    # Fully-constant subscripts: inline the value as a NumExpr literal.
    int_indices = Int[_const_subscript_int(a, const_arrays) for a in idx_args_expr]
    guards = rc.guards
    if !isempty(guards) &&
            _anyof(
            d -> !(1 <= int_indices[d] <= size(vals, d)) &&
                _const_dim_boundary(vals, d) === :error, 1:ndims(vals)
        ) &&
            !_guarded_read_taken(guards)
        memo === nothing || (memo.deferrals[] += 1)
        return _deferred_const_gather(vals, name, int_indices)
    end
    for d in 1:ndims(vals)
        int_indices[d] = _resolve_const_index(vals, name, d, int_indices[d], size(vals, d))
    end
    return NumExpr(Float64(vals[int_indices...]))
end

# A build-constant subscript as the integer it selects, by `_eval_const_int`'s
# integer arithmetic (`/` is `div`, every operand an integer). A `faq` in it — a
# comparison count, the bracket index of the interpolation templates
# (lib/interp.esm) at a literal query — is the one term that integer evaluator
# cannot take, since it reads array entries as integers and a count compares
# float entries: each such term is evaluated alone with the float evaluator, as
# the run time evaluates it, and stands in the subscript as the literal it
# evaluates to. A value that is not an integer is then refused exactly as that
# literal written by hand would be.
function _const_subscript_int(a::ASTExpr, const_arrays::AbstractDict)
    _holds_faq(a) && (a = _fold_faq_terms(a, const_arrays, IdDict{OpExpr, ASTExpr}()))
    return _eval_const_int(a, _EMPTY_IDX_ENV, const_arrays)
end
_holds_faq(e::ASTExpr) = _args_any(x -> x isa OpExpr && _is_faq_op((x::OpExpr).op), e)

# `e` with each `faq` sub-term replaced by the literal it evaluates to; the
# nodes above one are copied, every other node is `e`'s own. Memoized by
# identity, so a sub-term shared by reference is evaluated once.
function _fold_faq_terms(e::ASTExpr, const_arrays::AbstractDict, memo::IdDict{OpExpr, ASTExpr})
    e isa OpExpr && _holds_faq(e) || return e
    got = get(memo, e, nothing)
    got === nothing || return got
    r = if _is_faq_op(e.op)
        t = _resolve_indices(
            e, Dict{String, Tuple{Vector{Int}, Vector{Int}}}(), Dict{String, Int}(), const_arrays
        )
        NumExpr(_eval_node(_compile(t, Dict{String, Int}(), Set{Symbol}()), Float64[], NamedTuple(), 0.0))
    else
        reconstruct(e; args = ASTExpr[_fold_faq_terms(x, const_arrays, memo) for x in e.args])
    end
    return memo[e] = r
end

# Name prefix reserved for INTERNED inline-`const` array literals (below). Kept
# distinct from any authored variable name so a synthetic entry can never shadow
# a real const-array observed, and so the dedup scan can cheaply skip non-inline
# registry rows.
const _INLINE_CONST_PREFIX = "__inline_const#"

# Materialize an inline `const`-op array literal (a nested-vector `value`) into a
# dense Float64 array and INTERN it into the const-array registry so it gathers
# through the exact same path a registered const-array observed takes
# (`_resolve_const_array_gather`). Deduped BY VALUE: an identical literal resolves
# to one registry name, so its symbolic gathers share a CSE identity (a
# content-hashed name makes this deterministic even across separately-built
# equations). The gather captures `vals` directly, so registration is not needed
# for correctness — it is the task's "intern into `const_arrays`" contract plus a
# single shared array object; it is skipped for the read-only empty sentinel.
function _intern_inline_const(cexpr::OpExpr, const_arrays::AbstractDict)
    vals = _const_op_to_array(cexpr.value)
    same(v) = _dynamic((a, b) -> size(a) == size(b) && a == b, v, vals)::Bool
    name = string(_INLINE_CONST_PREFIX, hash(vals))
    # Every interned literal is registered under its own content hash and no
    # two registered ones are equal, so an equal literal is normally the one
    # under `name`. Equality is `==`, under which a value equal to this one may
    # hash differently only through a signed zero: then, or on a hash
    # collision, the scan below decides.
    v0 = get(const_arrays, name, nothing)
    v0 !== nothing && same(v0) && return v0, name
    v0 === nothing && !_dynamic(a -> any(iszero, a), vals)::Bool && return _intern_new_const(vals, name, const_arrays)
    for (k, v) in const_arrays
        (startswith(k, _INLINE_CONST_PREFIX) && same(v)) && return v, k
    end
    return _intern_new_const(vals, name, const_arrays)
end
function _intern_new_const(vals, name::String, const_arrays::AbstractDict)
    const_arrays === _EMPTY_CONST_ARRAYS || (const_arrays[name] = vals)
    return vals, name
end

# True iff the subscript `e` references a runtime contraction LOOP variable (a
# reserved `__esm_lv_*` name — `_LOOPVAR_PREFIX`); such names appear only where
# a contraction is kept as a run-time loop. One of the triggers for lowering a
# state-array read to a runtime `_NK_STATE_GATHER`. Distinct from
# `_reads_bound_sym`, which fires for ANY symbol in a caller-supplied set.
_refs_loopvar(e::ASTExpr) =
    _args_any(x -> x isa VarExpr && startswith((x::VarExpr).name, _LOOPVAR_PREFIX), e)

# Lower a STATE-array read whose subscripts depend on a contraction loop variable
# (`q[donor(i,k)]`) to a runtime `_NK_STATE_GATHER`. The
# frozen slot table maps every in-bounds state cell to its flat `u` slot (built
# once per state var per build, shared across output cells via the build state's slot tables);
# the subscript expressions resolve normally (a loop var → `_NK_LOOPVAR`; an indirect
# `index(conn,i,k)` → a nested `_NK_CONST_GATHER`) and become the node's children,
# evaluated + bounds-checked at eval time. A missing state cell (sparse layout)
# throws, which the loop-build try/catch converts to a fall-back to the exact unroll.
function _resolve_state_gather(
        vname::String, lo::Vector{Int}, hi::Vector{Int}, idx_args::Vector{ASTExpr}, rc::_ResolveCtx
    )
    nd = length(lo)
    var_map = rc.var_map
    sub_nodes = ASTExpr[_resolve_indices(a, rc) for a in idx_args]
    slot_flat, run_base, strides = get!(_build_state().slot_tables, vname) do
        dims = Int[hi[d] - lo[d] + 1 for d in 1:nd]
        strd = Vector{Int}(undef, nd)
        strd[1] = 1
        for d in 2:nd
            strd[d] = strd[d - 1] * dims[d - 1]
        end
        total = prod(dims)
        # A variable laid out as one block is one run of slots, kept as its
        # first slot: no table, and no cell key formatted per cell.
        blk = _vm_block(var_map, vname)
        if total > 0 && blk !== nothing && blk.lo == lo && blk.hi == hi && blk.strides == strd
            return (Int[], blk.base, strd)
        end
        sf = Vector{Int}(undef, total)
        cur = Vector{Int}(undef, nd)
        for lin in 0:(total - 1)
            rem = lin
            for d in 1:nd
                cur[d] = lo[d] + (rem % dims[d]); rem ÷= dims[d]
            end
            slot = blk === nothing ? 0 : _block_slot(blk, cur)
            if slot == 0
                cname = _cell_key(vname, cur)
                haskey(var_map, cname) ||
                    throw(TreeWalkError("E_TREEWALK_MISSING_CELL", cname))
                slot = var_map[cname]
            end
            sf[lin + 1] = slot
        end
        # A table that happens to be one run is kept as a run, so a gather's
        # form depends on its slots alone.
        isrun = total > 0 && all(k -> sf[k] == sf[1] + k - 1, eachindex(sf))
        isrun ? (Int[], sf[1], strd) : (sf, 0, strd)
    end
    return OpExpr(
        "__state_gather", sub_nodes;
        value = _Lowered(
            _NK_STATE_GATHER,
            _StateGather(slot_flat, run_base, strides, copy(lo), copy(hi), prod(hi .- lo .+ 1))
        )
    )
end
