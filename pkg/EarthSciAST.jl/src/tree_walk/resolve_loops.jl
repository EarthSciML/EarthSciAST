# tree_walk/resolve_loops.jl — reductions kept as run-time loops: the
# symbolic resolve, the contraction loop, the whole-array term, the scalar faq.

# ── Runtime contraction loops ────────────────────────────────────────────────
# A scalar aggregate nested inside an array equation's per-cell resolve
# (`_BuildState.array_cell_depth`, compiler.jl) keeps unrolling: its node flows
# into the stencil and access-kernel merges, which model unrolled scalar terms.
# The loop node is confined to scalar contexts, whose consumers are `_eval_node`
# and the CSE keyer (which declines an unknown kind and leaves it inline).
#
# The whole-array nest resolves its term with `nest_loops` set (see
# `_ResolveCtx`): a scalar reduction nested in that term stays a loop instead of
# unrolling one term per contracted index into the nest's one body, and the
# nest's emitter writes it as a counted loop (`_cg_emit`, array_contraction.jl).

# Tier gate and coverage floor: on under `native` for reductions at least
# `_contraction_loop_min()` long; shorter ones unroll. The floor is a refusal
# boundary under `native` (which side a reduction falls on decides which tier
# compiles the equation). Both are read once per build (`_BuildContext`).
_contraction_loop_enabled() = _compiler_plan_now().contraction_loop
_contraction_loop_min() = _tuning_now().contraction_loop_min

# Resolve `body` with each of `names` replaced by a fresh reserved loop-var
# name (`_fresh_loopvar_name`) kept symbolic beside `rc.bound`, under `memo`
# (`nothing` or one made for this symbolic resolve alone, never the concrete
# build's): `(refs, resolved)`, one `Ref` per name in `names` order, or a
# `_Decline` (`:symbolic_body_did_not_lower`, the error's text as its detail).
# Only a document-level refusal (an `EarthSciASTError`) is such a decline: a
# resource error is not (the per-cell fallback resolves the same body once per
# cell, so an exhausted heap read as a decline walks the build into a larger
# allocation), and a programming error must not surface as a declined tier.
# The refs are registered on the build state only after a clean resolve, so
# `_compile` lowers each surviving loop-var `VarExpr` to an `_NK_LOOPVAR`.
function _resolve_symbolic(
        body::ASTExpr, names::Vector{String}, rc::_ResolveCtx, memo::_MaybeMemo = nothing
    )
    fresh = String[_fresh_loopvar_name() for _ in names]
    refs = Base.RefValue{Int}[Ref(0) for _ in names]
    subs = Dict{String, ASTExpr}(names[d] => VarExpr(fresh[d]) for d in eachindex(names))
    subbed = _sub_preserving(body, subs)
    sym = _derive(rc; memo = memo, bound = union(Set{String}(fresh), rc.bound))
    resolved = try
        _resolve_indices(subbed, sym)
    catch err
        err isa EarthSciASTError || rethrow()
        return _Decline(:symbolic_body_did_not_lower, sprint(showerror, err))
    end
    for d in eachindex(fresh)
        _register_loopvar!(fresh[d], refs[d])
    end
    return refs, resolved
end

# A uniform contraction as one run-time loop: a `__contract_loop` marker per
# contracted index (lowered to `_NK_CONTRACTION_LOOP` by `_compile`) around the
# body resolved once with the indices symbolic, or the resolve's `_Decline`, on
# which the caller unrolls. `rc.bound` and `rc.nest_loops` are the enclosing
# symbolic resolve's, which the body may read (a reduction nested in the
# whole-array nest's term); a context with neither gives a plain loop.
function _try_build_contraction_loop(
        body::ASTExpr, contract_names::Vector{String},
        ranges::AbstractVector, oplus::String, zerobar::Float64, rc::_ResolveCtx
    )
    got = _resolve_symbolic(body, contract_names, rc)
    got isa _Decline && return got
    refs, resolved = got
    oplus_sym = Symbol(oplus)
    node::ASTExpr = resolved
    # `contract_names[1]` varies fastest in the unroll's `Iterators.product`
    # order, so it is the innermost loop and the fold order matches
    # `_combine_with_reducer`'s.
    for d in eachindex(contract_names)
        r = ranges[d]
        node = OpExpr(
            "__contract_loop", ASTExpr[node];
            value = _Lowered(
                _NK_CONTRACTION_LOOP, oplus_sym, zerobar,
                _ContractLoop(refs[d], first(r), last(r), step(r))
            )
        )
    end
    return node
end

# ── Whole-array contraction loop nest ────────────────
# The tier that keeps the output indices symbolic too (see
# `_resolve_array_contraction_term`). `_compile_faq_equation!` offers it once
# the affine tier has declined, so the alternative is always the per-cell
# build. The in-place build offers it every such equation; the floor applies
# only to the out-of-place build, whose emitters have no arm for this tier's
# section, so there an equation under the floor keeps the per-cell build. The
# contraction-loop gate disables this tier too. The floor is a tuning
# threshold, not a refusal boundary.
_array_contraction_enabled() =
    _compiler_plan_now().array_contraction && _contraction_loop_enabled()
_array_contraction_min() = _tuning_now().array_contraction_min

# The term of an array einsum resolved once with its output and its contracted
# indices all symbolic (reserved loop-var names), and no reduction around it:
# `(out_refs, contract_refs, resolved)`, or a `_Decline` when the body does not
# resolve that way. The build is then O(1) in both extents: the body's reads
# lower through the run-time gathers (a const read at an output subscript is
# `_NK_CONST_GATHER`, a state read `_NK_STATE_GATHER`, a bare output symbol
# `_NK_LOOPVAR`) and the caller drives the counters at eval time. The
# whole-array nest (array_contraction.jl) drives the contracted refs;
# `_compile_init_once` (no contracted index) compiles the term once for every
# output cell. `rc` is the build's concrete context; this resolve gets its own
# bound names, the nest's `nest_loops` when `nest_scalar_loops` is set, and
# `memo`, a memo of this resolve's own (a sub-tree reached from several parents
# then resolves once, and the caller compiles the result with the same memo).
function _resolve_array_contraction_term(
        body::ASTExpr, out_names::Vector{String},
        contract_names::Vector{String}, rc::_ResolveCtx;
        nest_scalar_loops::Bool = false,
        memo::_MaybeMemo = nothing
    )
    nout = length(out_names)
    got = _resolve_symbolic(
        body, vcat(out_names, contract_names),
        _derive(rc; bound = _EMPTY_BOUND_SYMS, nest_loops = nest_scalar_loops), memo
    )
    got isa _Decline && return got
    refs, resolved = got
    return (refs[1:nout], refs[(nout + 1):end], resolved)
end

# A scalar faq (empty output_idx) as a plain scalar expression: the contracted
# indices unrolled at build time and combined with the declared reducer, or a
# run-time loop where the gates below admit one.
function _resolve_scalar_faq(faq_expr::OpExpr, rc::_ResolveCtx)
    body = faq_expr.expr_body
    body === nothing &&
        throw(
        TreeWalkError(
            "E_TREEWALK_ARRAYOP_NO_BODY",
            "faq requires an expr body"
        )
    )
    ranges_dict = _ranges_dict(faq_expr)
    oplus, zerobar = _aggregate_oplus_identity(faq_expr.semiring, faq_expr.reduce)
    # Every range key contracts (a scalar aggregate has no output indices).
    contract_names = _contracted_index_names(ranges_dict, ())
    gates = faq_expr.join_gates
    # A contracted bound may be a per-cell index expression (a ragged set's
    # `index(n_edges_on_cell, i)`); the outer loop variable is already a
    # literal in `body` and `ranges` here, so the bound evaluates against the
    # const arrays with no index bound.
    contract_iters = _contract_iters_at(
        contract_names, [ranges_dict[n] for n in contract_names], _EMPTY_IDX_ENV,
        rc.const_arrays; canonical = _has_equality_join(gates)
    )
    # Build-time join gates and the run-time filter guard (§5.3 / §7.2). Every
    # join key of a scalar aggregate is a contracted symbol, so the binding is
    # the contraction tuple.
    filt0 = faq_expr.filter
    if isempty(contract_names) && gates === nothing && filt0 === nothing
        return _resolve_indices(body, rc)
    end
    # A run-time loop for a simple uniform reduction: enabled by the plan, not
    # inside an array equation's cell resolve, not a symbolic resolve, a
    # numeric reducer with no gates or filter, constant contracted ranges, and
    # at least the coverage floor long. A body that does not resolve with the
    # index symbolic declines and unrolls.
    if _contraction_loop_enabled() && _build_state().array_cell_depth == 0 &&
            !_is_symbolic(rc) && gates === nothing && filt0 === nothing &&
            _is_numeric_reducer(oplus) &&
            all(n -> _is_const_int_range(ranges_dict[n]), contract_names)
        ranges = [_expand_int_range(ranges_dict[n]) for n in contract_names]
        total = isempty(ranges) ? 0 : prod(length(r) for r in ranges)
        if total >= _contraction_loop_min() && all(!isempty, ranges)
            looped = _try_build_contraction_loop(
                body, contract_names, ranges, oplus, zerobar,
                _derive(rc; memo = nothing, bound = _EMPTY_BOUND_SYMS, nest_loops = false)
            )
            looped isa _Decline || return looped
        end
    end
    # In the whole-array nest's term, a reduction over one constant range at
    # least the loop floor long stays a loop that reads the nest's counters. It
    # folds from 0̄, so its value is the unroll's bit for bit: the same terms in
    # the same order, left to right from the same seed (esm-spec §4.3.1). Two or
    # more contracted indices keep unrolling, since nested loops would group the
    # sum by the outer index.
    if rc.nest_loops && gates === nothing &&
            filt0 === nothing && length(contract_names) == 1 &&
            _is_numeric_reducer(oplus) &&
            _is_const_int_range(ranges_dict[contract_names[1]])
        r = _expand_int_range(ranges_dict[contract_names[1]])
        if length(r) >= _contraction_loop_min()
            looped = _try_build_contraction_loop(
                body, contract_names, [r], oplus, zerobar, _derive(rc; memo = nothing)
            )
            looped isa _Decline || return looped
        end
    end
    terms = ASTExpr[]
    _foreach_aggregate_term(
        body, contract_names, contract_iters,
        gates, filt0, zerobar
    ) do term
        push!(terms, _resolve_indices(term, rc))
    end
    return _combine_with_reducer(oplus, zerobar, terms; scalar = true)
end
