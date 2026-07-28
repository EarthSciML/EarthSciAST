# ========================================================================
# tree_walk/resolve.jl — part of the tree-walk evaluator (gt-e8yw).
# Included by src/tree_walk.jl; see that file for the full layout and
# include order. Section 5d: index-set registry resolution, build-time index resolution
# (_resolve_indices and the arrayop/makearray expansions), live-forcing
# buffers (_PGatherArray), array-cell discovery, and model selection.
# ========================================================================

# ============================================================
# 5d. Index-set registry resolution (RFC semiring-faq-unified-ir §5.2)
# ============================================================
#
# A `ranges[*]` value may be a dense `[lo,hi]`/`[lo,step,hi]` tuple (as today) or
# an `IndexSetRef` `{from: <name>, of?: [...]}`. The pre-pass below resolves each
# reference against the model's `index_sets` registry into the dense / dynamic
# forms the existing range machinery already consumes, so the downstream einsum /
# scalar-aggregate expansion (and the compiled `_Node` tree) is unchanged (§6):
#   interval     → dense bound `[1, size]`
#   categorical  → enumerated members `[1, |members|]`
#   ragged       → per-cell dynamic bound `[1, index(offsets, of…)]` — exactly the
#                  existing `_expand_int_range_dyn` mechanism + a `values` gather
#                  authored in the body (§5.2). offsets/values are keyed factors (§5.4).

# Keyed factors (a ragged set's `offsets`/`values`, RFC §5.4) resolve by BARE
# name in the model scope; the empty default scope keeps every bare name as-is.
# Read-only sentinel — see the `_EMPTY_*` invariant block next to
# `_EMPTY_DERIVED_EXTENTS`.
const _EMPTY_FACTOR_SCOPE = Dict{String,String}()

# Resolve ONE IndexSetRef to a concrete `ranges` value. Errors clearly on an
# undeclared name — no implicit interval is inferred, so a typo can't silently
# become an empty set (§5.2). `factor_scope` maps a ragged set's bare keyed-factor
# name to the in-scope variable that backs it (flattening prefixes variables with
# their owning component path, e.g. "nEdgesOnCell" → "Divergence.nEdgesOnCell",
# while the document-scoped registry keeps the bare authored name).
function _resolve_one_index_set_ref(ref::IndexSetRef, index_sets::AbstractDict,
                                    derived_extents::AbstractDict=_EMPTY_DERIVED_EXTENTS,
                                    factor_scope::AbstractDict=_EMPTY_FACTOR_SCOPE)
    haskey(index_sets, ref.from) || throw(TreeWalkError(
        "E_TREEWALK_UNDECLARED_INDEX_SET",
        "undeclared index set '$(ref.from)' referenced in ranges; declare it in " *
        "the model's `index_sets` registry (no implicit interval is inferred)"))
    is = index_sets[ref.from]
    if is.kind == "interval"
        is.size === nothing && throw(TreeWalkError("E_TREEWALK_INDEX_SET_INCOMPLETE",
            "interval index set '$(ref.from)' requires a `size`"))
        return Any[1, Int(is.size)]
    elseif is.kind == "categorical"
        is.members === nothing && throw(TreeWalkError("E_TREEWALK_INDEX_SET_INCOMPLETE",
            "categorical index set '$(ref.from)' requires `members`"))
        return Any[1, length(is.members)]
    elseif is.kind == "ragged"
        is.offsets === nothing && throw(TreeWalkError("E_TREEWALK_INDEX_SET_INCOMPLETE",
            "ragged index set '$(ref.from)' requires an `offsets` backing factor"))
        isempty(ref.of) && throw(TreeWalkError("E_TREEWALK_RAGGED_NO_PARENTS",
            "ragged index set '$(ref.from)' referenced without `of` parent index " *
            "variable(s); a ragged set's per-tuple length is a function of its parent"))
        # Per-cell dynamic upper bound |set(of…)| = offsets[of…]. The member
        # gather through `values` is authored in the body (e.g.
        # index(values, of…, k)) and resolved by the existing const_array path.
        # The offsets factor binds by BARE name in the model scope (§5.4);
        # `factor_scope` supplies the in-scope (possibly namespaced) variable.
        off = String(get(factor_scope, String(is.offsets), String(is.offsets)))
        idx_args = ASTExpr[VarExpr(off)]
        append!(idx_args, ASTExpr[VarExpr(p) for p in ref.of])
        return Any[1, OpExpr("index", idx_args)]
    elseif is.kind == "derived"
        # M4 (RFC §8.1): a derived index set names its producing FAQ node via
        # `from_faq`. The intersect_polygon clip ring is materialized at setup time
        # (`_materialize_geometry_rings`); its distinct-vertex count is the resolved
        # dense extent `[1, n]`, so the polygon_area FAQ unrolls over the ring like
        # any other aggregate. The general §5.5 distinct/skolem materialization for
        # non-geometry derived sets remains out of the tree-walk scope (M1).
        faq = is.from_faq
        faq === nothing && throw(TreeWalkError("E_TREEWALK_DERIVED_NO_FAQ",
            "derived index set '$(ref.from)' requires a `from_faq` naming its " *
            "producing node (§5.5)"))
        haskey(derived_extents, faq) || throw(TreeWalkError("E_TREEWALK_DERIVED_INDEX_SET",
            "derived index set '$(ref.from)' (from_faq '$faq') is not materialized; its " *
            "producing intersect_polygon node has not been evaluated at setup (RFC §8.1). " *
            "Materialized: $(sort(collect(keys(derived_extents)))). The general §5.5 " *
            "distinct/skolem materialization is out of the tree-walk scope (M1)."))
        return Any[1, derived_extents[faq]]
    end
    throw(TreeWalkError("E_TREEWALK_UNKNOWN_INDEX_SET_KIND",
        "unknown index set kind '$(is.kind)' for '$(ref.from)'"))
end

# True iff any node in the subtree carries a `ranges` entry that is an IndexSetRef.
# Identity-deduped (ESS-0hh): a pure existence predicate over a possibly
# structurally-shared tree — the per-path recursion was exponential on a DAG.
_has_index_set_ref(expr::OpExpr) = _has_index_set_ref(expr, IdDict{OpExpr,Nothing}())
function _has_index_set_ref(expr::OpExpr, seen::IdDict{OpExpr,Nothing})
    haskey(seen, expr) && return false
    seen[expr] = nothing
    if expr.ranges !== nothing
        for v in values(expr.ranges)
            v isa IndexSetRef && return true
        end
    end
    for a in expr.args
        a isa OpExpr && _has_index_set_ref(a, seen) && return true
    end
    expr.expr_body isa OpExpr && _has_index_set_ref(expr.expr_body::OpExpr, seen) && return true
    if expr.values !== nothing
        for v in expr.values
            v isa OpExpr && _has_index_set_ref(v, seen) && return true
        end
    end
    expr.lower isa OpExpr && _has_index_set_ref(expr.lower::OpExpr, seen) && return true
    expr.upper isa OpExpr && _has_index_set_ref(expr.upper::OpExpr, seen) && return true
    return false
end
_has_index_set_ref(::ASTExpr) = false
_has_index_set_ref(eq::Equation) = _has_index_set_ref(eq.lhs) || _has_index_set_ref(eq.rhs)

# Rewrite every IndexSetRef in the subtree's ranges to its resolved concrete
# form, rebuilding OpExpr nodes while preserving all fields.
#
# IDENTITY-MEMOIZED and IDENTITY-PRESERVING (ESS-0hh): the rewrite is a pure
# function of the node under one call's fixed registries, so a shared node
# resolves to ONE shared output node, and a node with no IndexSetRef anywhere
# below is returned VERBATIM instead of reconstruct-copied. The unconditional
# per-path rebuild both did exponential work on a structurally-shared
# equation (e.g. a folded array-observed chain) and re-inflated the DAG into
# an exponentially large tree for every stage downstream. Identity
# preservation also keeps `_translate_equation_sites!` cheap: its lockstep
# walk short-circuits on `old === new`.
function _resolve_isr(expr::OpExpr, index_sets::AbstractDict,
                      derived_extents::AbstractDict=_EMPTY_DERIVED_EXTENTS,
                      factor_scope::AbstractDict=_EMPTY_FACTOR_SCOPE,
                      memo::IdDict{OpExpr,ASTExpr}=IdDict{OpExpr,ASTExpr}())
    cached = get(memo, expr, nothing)
    cached === nothing || return cached
    changed = false
    res(x) = begin
        r = _resolve_isr(x, index_sets, derived_extents, factor_scope, memo)
        r === x || (changed = true)
        r
    end
    new_args = ASTExpr[res(a) for a in expr.args]
    new_body = expr.expr_body === nothing ? nothing : res(expr.expr_body)
    new_values = expr.values === nothing ? nothing : ASTExpr[res(v) for v in expr.values]
    new_lower = expr.lower === nothing ? nothing : res(expr.lower)
    new_upper = expr.upper === nothing ? nothing : res(expr.upper)
    new_ranges = expr.ranges
    if expr.ranges !== nothing && any(v -> v isa IndexSetRef, values(expr.ranges))
        changed = true
        new_ranges = Dict{String,Any}()
        for (k, v) in expr.ranges
            new_ranges[k] = v isa IndexSetRef ?
                _resolve_one_index_set_ref(v, index_sets, derived_extents, factor_scope) : v
        end
    end
    result = changed ?
        reconstruct(expr; args=new_args, expr_body=new_body,
                    values=new_values, lower=new_lower, upper=new_upper,
                    ranges=new_ranges) : expr
    memo[expr] = result
    return result
end
_resolve_isr(expr::ASTExpr, ::AbstractDict, ::AbstractDict=_EMPTY_DERIVED_EXTENTS,
             ::AbstractDict=_EMPTY_FACTOR_SCOPE,
             ::IdDict{OpExpr,ASTExpr}=IdDict{OpExpr,ASTExpr}()) = expr
_resolve_isr(eq::Equation, index_sets::AbstractDict,
             derived_extents::AbstractDict=_EMPTY_DERIVED_EXTENTS,
             factor_scope::AbstractDict=_EMPTY_FACTOR_SCOPE,
             memo::IdDict{OpExpr,ASTExpr}=IdDict{OpExpr,ASTExpr}()) =
    Equation(_resolve_isr(eq.lhs, index_sets, derived_extents, factor_scope, memo),
             _resolve_isr(eq.rhs, index_sets, derived_extents, factor_scope, memo);
             _comment=eq._comment)

# Resolve all index-set references across a vector of equations. Returns the
# input unchanged when no equation uses a `{from}` reference — preserving
# byte-identical behaviour (and the compiled tree) for existing files (§6).
# One shared memo across the vector: the registries are fixed for the whole
# call, so a subtree shared BETWEEN equations also resolves once and stays
# shared.
function _resolve_index_set_ranges(eqs::Vector{Equation}, index_sets::AbstractDict,
                                   derived_extents::AbstractDict=_EMPTY_DERIVED_EXTENTS,
                                   factor_scope::AbstractDict=_EMPTY_FACTOR_SCOPE)
    any(_has_index_set_ref, eqs) || return eqs
    memo = IdDict{OpExpr,ASTExpr}()
    return Equation[_resolve_isr(eq, index_sets, derived_extents, factor_scope, memo)
                    for eq in eqs]
end

# ---- Shared aggregate/einsum expansion core (one spelling, three sites) --------
# The three aggregate expansions — the LHS-arrayop einsum
# (`_compile_arrayop_percell!`), the expression-position gather
# (`_resolve_index_of_arrayop`), and the scalar reduction
# (`_resolve_scalar_arrayop`) — all unroll the same product: iterate the
# Cartesian product of the contracted-index iterators, drop join-rejected
# combinations at build time (M2, §5.3), substitute the concrete contracted
# indices into the (already output-index-substituted) `body`, and guard
# filter-rejected terms with a runtime `ifelse(pred, term, 0̄)` (§7.2). `emit!`
# receives each surviving term; the caller owns what happens next (resolve to a
# scalar ASTExpr vs resolve+compile to a `_Node`) and how the terms are ⊕-combined.
# With neither gates nor filter this is the unchanged M1 expansion.
#
# Dict reuse: `_sub_preserving`/`_join_admits` only READ these dicts (never
# retain them), and the key SET is identical every iteration — only the values
# change — so `k_exprs` is overwritten in place instead of allocating a fresh
# `Dict` (and its string hashing) per contracted tuple. `binding` additionally
# holds the (fixed) output indices, seeded once from `out_env`. `filt` must
# already carry the output-index substitution (only the contracted indices are
# substituted here); `nothing` disables the guard, as a `nothing` `gates`
# disables the join.
function _foreach_aggregate_term(emit!::F, body::ASTExpr,
        contract_names::Vector{String}, contract_iters,
        gates, filt, zerobar::Float64,
        out_env::Union{Nothing,Dict{String,Int}}=nothing) where {F}
    k_exprs = Dict{String,ASTExpr}()
    binding = gates === nothing ? nothing :
              (out_env === nothing ? Dict{String,Int}() : Dict{String,Int}(out_env))
    for k_tuple in Iterators.product(contract_iters...)
        if binding !== nothing
            for d in 1:length(contract_names)
                binding[contract_names[d]] = k_tuple[d]
            end
            _join_admits(gates, binding) || continue
        end
        for d in 1:length(contract_names)
            k_exprs[contract_names[d]] = IntExpr(Int64(k_tuple[d]))
        end
        term = _sub_preserving(body, k_exprs)
        if filt !== nothing
            fsub = _sub_preserving(filt, k_exprs)
            term = OpExpr("ifelse", ASTExpr[fsub, term, NumExpr(zerobar)])
        end
        emit!(term)
    end
    return nothing
end

# Contracted (reduction) index names of an aggregate: the `ranges` keys NOT in
# `output_idx`, sorted so the expansion (and hence ⊕-accumulation) order is
# deterministic and identical across the three expansion sites.
_contracted_index_names(ranges_dict, output_idx) =
    sort!(String[n for n in keys(ranges_dict) if !(n in output_idx)])

# Expand one contracted-range spec to its concrete iteration vector. A constant
# `[lo,hi]`/`[lo,step,hi]` bound expands directly; an *expression-valued* bound —
# a RAGGED index-set range (`{from: <ragged>, of: [i]}`, esm-spec §4.3.1 /
# RFC §5.2) resolved to the per-cell dynamic upper bound `index(offsets, i)` —
# is evaluated under the current output-index environment `idx_env` via
# `_expand_int_range_dyn` (variable-valence segment reduction over the CSR
# offsets keyed factor — a const array; no host-side padding).
_expand_contract_range(rspec, idx_env::Dict{String,Int}, const_arrays::AbstractDict) =
    collect(_is_const_int_range(rspec) ? _expand_int_range(rspec) :
            _expand_int_range_dyn(rspec, idx_env, const_arrays))

# Resolve index(arrayop(...), k1, k2, ...) in expression position by
# substituting the output_idx values and unrolling contracted indices at
# build time. Mirrors the LHS-arrayop expansion (`_compile_arrayop_percell!`,
# the `_is_arrayop_D_lhs` branch of the derivative loop) but produces a scalar
# ASTExpr instead of writing to rhs_list.
function _resolve_index_of_arrayop(arrayop_expr::OpExpr, idx_args::Vector{ASTExpr},
                                    array_var_info, var_map, const_arrays,
                                    pgather::AbstractDict=_EMPTY_PGATHER,
                                    memo::_MaybeMemo=nothing,
                                    bound_syms::Set{String}=_EMPTY_BOUND_SYMS)
    output_idx_strs = _output_idx_strings(arrayop_expr)
    length(output_idx_strs) == length(idx_args) ||
        throw(TreeWalkError("E_TREEWALK_ARRAYOP_INDEX_NDIM",
              "arrayop output_idx has $(length(output_idx_strs)) dims " *
              "but $(length(idx_args)) index args"))
    body = arrayop_expr.expr_body
    body === nothing &&
        throw(TreeWalkError("E_TREEWALK_ARRAYOP_NO_BODY",
                            "arrayop requires an expr body"))
    ranges_dict = _ranges_dict(arrayop_expr)
    oplus, zerobar = _aggregate_oplus_identity(arrayop_expr.semiring, arrayop_expr.reduce)

    # Output-index substitution. Each output-index arg is EITHER a bound symbol —
    # kept SYMBOLIC, substituted as its own resolved-in-place expression so the
    # unrolled body reads `A[c, <sym>]` and lowers to a runtime `_ConstGatherRef`
    # (wall2 Phase C, compile-once fast path) — OR a build-time constant, folded to
    # an `IntExpr` exactly as before. With an EMPTY `bound_syms` every arg is
    # constant, so this is byte-identical to the pre-Phase-C concrete expansion.
    nd = length(output_idx_strs)
    symbolic = falses(nd)
    k_vals = Vector{Int}(undef, nd)
    idx_exprs = Dict{String,ASTExpr}()
    for d in 1:nd
        a = idx_args[d]
        if _refs_bound_sym(a, bound_syms)
            symbolic[d] = true
            idx_exprs[output_idx_strs[d]] = a           # keep symbolic
        else
            k_vals[d] = _eval_const_int(a, _EMPTY_IDX_ENV, const_arrays)
            idx_exprs[output_idx_strs[d]] = IntExpr(Int64(k_vals[d]))
        end
    end
    any_symbolic = any(symbolic)
    sub_body = _sub_preserving(body, idx_exprs)

    # Contracted indices: all range keys NOT appearing in output_idx. A
    # contracted bound may be *expression-valued* — see `_expand_contract_range`;
    # the parent index of a ragged bound is one of THIS gather's output indices,
    # so a ragged bound is evaluable ONLY when that parent index is CONCRETE. In
    # symbolic mode a ragged bound over a symbolic output index has no concrete
    # value in `_out_idx_env`, so `_expand_int_range_dyn` throws `unbound loop var`
    # and the compile-once fast path falls back — exactly the intended coverage.
    contract_names = _contracted_index_names(ranges_dict, output_idx_strs)
    _out_idx_env = Dict{String,Int}(output_idx_strs[d] => k_vals[d]
                                    for d in 1:nd if !symbolic[d])
    contract_iters = [_expand_contract_range(ranges_dict[n], _out_idx_env, const_arrays)
                      for n in contract_names]

    gates = arrayop_expr.join_gates
    filt0 = arrayop_expr.filter
    # Build-time join gates / runtime filter guards need CONCRETE output-index
    # bindings (the join binding is seeded from `_out_idx_env`; the filter is
    # substituted with `idx_exprs`). A symbolic output index has neither, so
    # refuse the fast path here — the compile-once wrapper catches this and falls
    # back to the exact per-cell expansion (concrete mode is unaffected).
    any_symbolic && (gates !== nothing || filt0 !== nothing) &&
        throw(TreeWalkError("E_TREEWALK_COMPILE_ONCE_UNSUPPORTED",
            "aggregate join_gates/filter are not supported on the symbolic " *
            "compile-once path; falling back to per-cell resolution"))
    if isempty(contract_names) && gates === nothing && filt0 === nothing
        return _resolve_indices(sub_body, array_var_info, var_map, const_arrays,
                                pgather, memo, bound_syms)
    end

    # Join/filter expansion via the shared core; the filter carries the (fixed)
    # output-index substitution already, matching the hoisted `sub_body`. The
    # term resolution forwards `bound_syms` so the symbolic subscripts survive
    # into `_ConstGatherRef`s (in concrete mode `bound_syms` is empty → no-op).
    filt = filt0 === nothing ? nothing : _sub_preserving(filt0, idx_exprs)
    terms = ASTExpr[]
    _foreach_aggregate_term(sub_body, contract_names, contract_iters,
                            gates, filt, zerobar, _out_idx_env) do term
        push!(terms, _resolve_indices(term, array_var_info, var_map, const_arrays,
                                      pgather, memo, bound_syms))
    end
    return _combine_with_reducer(oplus, zerobar, terms)
end

# Resolve index(makearray(regions=[...], values=[...]), k1, k2, ...) by
# selecting the value expression whose region covers (k1, k2, ...).
# Later regions overwrite earlier ones, matching the Python reference
# semantics (`_eval_makearray` in numpy_interpreter.py).
function _resolve_index_of_makearray(makearray_expr::OpExpr, idx_args::Vector{ASTExpr},
                                      array_var_info, var_map, const_arrays,
                                      pgather::AbstractDict=_EMPTY_PGATHER,
                                      memo::_MaybeMemo=nothing,
                                      bound_syms::Set{String}=_EMPTY_BOUND_SYMS)
    regions = makearray_expr.regions === nothing ?
              Vector{Vector{Vector{Int}}}() : makearray_expr.regions
    values  = makearray_expr.values  === nothing ? ASTExpr[] : makearray_expr.values
    length(regions) == length(values) ||
        throw(TreeWalkError("E_TREEWALK_MAKEARRAY_MISMATCH",
              "makearray regions/values length mismatch " *
              "($(length(regions)) vs $(length(values)))"))
    k_vals = [_eval_const_int(a, _EMPTY_IDX_ENV, const_arrays) for a in idx_args]
    ndim   = length(k_vals)
    result_expr::ASTExpr = NumExpr(0.0)  # default: 0 if no region covers the point
    result_region = nothing
    for (region, val_expr) in zip(regions, values)
        length(region) == ndim ||
            throw(TreeWalkError("E_TREEWALK_MAKEARRAY_NDIM",
                  "makearray region has $(length(region)) dims but $(ndim) indices"))
        in_region = all(k_vals[d] >= region[d][1] && k_vals[d] <= region[d][2]
                        for d in 1:ndim)
        in_region && ((result_expr, result_region) = (val_expr, region))  # overwrite; last match wins
    end
    # esm-spec §9.6.8: a region value MAY be a self-contained ARRAY-VALUED
    # aggregate (the spec's worked example authors the interior stencil and the
    # boundary faces this way, each with its own `output_idx`/`ranges`). The
    # value array is indexed at the same point (k1, …). A value of lower rank
    # than the makearray covers the region's NON-SINGLETON axes — a face region
    # pins the other axes to a single line (e.g. the [[1,1],[1,NLAT]] west face
    # holds an aggregate over `j` alone).
    if _is_array_producer(result_expr)
        re = result_expr::OpExpr
        rank = re.op == "makearray" ?
            ((re.regions === nothing || isempty(re.regions)) ? 0 : length(re.regions[1])) :
            length(_output_idx_strings(re))
        sel = if rank == ndim
            k_vals
        else
            nonsingleton = [d for d in 1:ndim
                            if result_region === nothing ||
                               result_region[d][1] != result_region[d][2]]
            rank == length(nonsingleton) ||
                throw(TreeWalkError("E_TREEWALK_MAKEARRAY_VALUE_RANK",
                      "makearray region value produces a rank-$(rank) array " *
                      "but the region has $(length(nonsingleton)) non-singleton " *
                      "axis/axes of $(ndim) total"))
            k_vals[nonsingleton]
        end
        sel_exprs = ASTExpr[IntExpr(Int64(v)) for v in sel]
        return re.op == "makearray" ?
            _resolve_index_of_makearray(re, sel_exprs, array_var_info, var_map,
                                        const_arrays, pgather, memo, bound_syms) :
            _resolve_index_of_arrayop(re, sel_exprs, array_var_info, var_map,
                                      const_arrays, pgather, memo, bound_syms)
    end
    return _resolve_indices(result_expr, array_var_info, var_map, const_arrays,
                            pgather, memo, bound_syms)
end

# ── Runtime contraction loop gate (ess-runtime-contraction) ─────────────────
# Depth of the array-equation per-cell resolve (`_compile_arrayop_percell!`). A
# scalar aggregate nested INSIDE an array-equation cell body must keep unrolling:
# its compiled node flows into the stencil / access-kernel merge (acc_merge.jl,
# stencil_affine.jl, oop_merge.jl), which model unrolled scalar terms — so the
# loop node is confined to SCALAR contexts (rhs_list / scalar observeds), where the
# eval-time consumers are exactly `_eval_node` / `_oop_eval` (both handle it) and
# the CSE keyer (xcse.jl, which safely DECLINES an unknown kind → leaves it inline).
const _ARRAY_CELL_DEPTH = Ref(0)

# Opt-in / kill-switch and coverage floor. Default ON, but only for reductions at
# least `_contraction_loop_min()` long — small reductions keep unrolling so the
# vast existing small-aggregate test surface (and its CSE / stencil interactions)
# is byte-for-byte unchanged. `ESS_CONTRACTION_LOOP=0` forces the pure-unroll
# reference everywhere.
_contraction_loop_enabled() = get(ENV, "ESS_CONTRACTION_LOOP", "1") != "0"
function _contraction_loop_min()
    v = get(ENV, "ESS_CONTRACTION_LOOP_MIN", "")
    n = tryparse(Int, v)
    return (n === nothing || n < 1) ? 8 : n
end

# Try to compile a uniform contraction to a single runtime loop node instead of
# unrolling it (ess-runtime-contraction). Returns a `__contract_loop` marker-op
# ASTExpr (lowered to `_NK_CONTRACTION_LOOP` by `_compile`) on success, or
# `nothing` to fall back to the exact unroll. Keeps the contracted index SYMBOLIC
# (a reserved bound-sym `VarExpr`) and resolves the body ONCE: a loop var reaching
# a const-array subscript lowers to a runtime `_NK_CONST_GATHER` (existing Phase-C
# machinery); a loop var reaching a STATE index or a ragged bound throws
# `E_TREEWALK_UNBOUND_LOOP_VAR` here — caught, and we unroll (correctness first).
function _try_build_contraction_loop(body::ASTExpr, contract_names::Vector{String},
        ranges::AbstractVector, oplus::String, zerobar::Float64,
        array_var_info, var_map, const_arrays, pgather::AbstractDict)
    names = String[_fresh_loopvar_name() for _ in contract_names]
    refs  = Base.RefValue{Int}[Ref(0) for _ in contract_names]
    subs  = Dict{String,ASTExpr}(contract_names[d] => VarExpr(names[d])
                                 for d in eachindex(contract_names))
    subbed = _sub_preserving(body, subs)
    bsyms  = Set{String}(names)
    resolved = try
        # memo=nothing: the symbolic (bound-sym) resolution must never share the
        # concrete RHS-build memo (same invariant the compile-once path relies on).
        _resolve_indices(subbed, array_var_info, var_map, const_arrays,
                         pgather, nothing, bsyms)
    catch
        return nothing
    end
    # Publish the refs so `_compile` lowers each surviving loop-var `VarExpr` to an
    # `_NK_LOOPVAR` reading that ref. (Registered only after a clean resolve.)
    for d in eachindex(names)
        _LOOPVAR_REFS[Symbol(names[d])] = refs[d]
    end
    oplus_sym = Symbol(oplus)
    node::ASTExpr = resolved
    # Nest innermost-first: `contract_names[1]` varies FASTEST in the unroll's
    # `Iterators.product` order, so it is the INNERMOST loop — the fold order then
    # matches the unrolled `_combine_with_reducer` accumulation.
    for d in eachindex(contract_names)
        r = ranges[d]
        node = OpExpr("__contract_loop", ASTExpr[node];
                      value=_ContractLoopBuild(refs[d], first(r), last(r), step(r),
                                               oplus_sym, zerobar))
    end
    return node
end

# Expand a scalar arrayop (empty output_idx) to a plain scalar ASTExpr by
# unrolling all contracted indices at build time and combining them with the
# declared reducer. This is the build-time equivalent of an einsum over a
# general expression body — compile once, evaluate cheaply at every RHS call.
function _resolve_scalar_arrayop(arrayop_expr::OpExpr, array_var_info, var_map, const_arrays,
                                 pgather::AbstractDict=_EMPTY_PGATHER,
                                 memo::_MaybeMemo=nothing,
                                 bound_syms::Set{String}=_EMPTY_BOUND_SYMS)
    body = arrayop_expr.expr_body
    body === nothing &&
        throw(TreeWalkError("E_TREEWALK_ARRAYOP_NO_BODY",
                            "arrayop requires an expr body"))
    ranges_dict = _ranges_dict(arrayop_expr)
    oplus, zerobar = _aggregate_oplus_identity(arrayop_expr.semiring, arrayop_expr.reduce)
    # Every range key contracts (a scalar aggregate has no output indices).
    contract_names = _contracted_index_names(ranges_dict, ())
    # A contracted range bound may be a per-cell INDEX EXPRESSION (e.g. the
    # variable-valence unstructured reduction's `index(n_edges_on_cell, i)`).
    # This scalar-arrayop resolver is reached from `_resolve_indices` AFTER the
    # outer loop variable has been substituted to a literal in `body`/`ranges`,
    # so the bound is evaluable now via `_eval_const_int` against `const_arrays`
    # with the empty idx_env (any surviving symbol would be unbound — an error,
    # as before). Constant bounds pass through unchanged (backward compatible).
    contract_iters = [_expand_contract_range(ranges_dict[n], _EMPTY_IDX_ENV, const_arrays)
                      for n in contract_names]
    # M2 (§5.3 / §7.2): build-time join gates + runtime filter guard. Every join
    # key of a scalar aggregate is a contracted symbol, so the binding is the
    # contraction tuple (no output-index seed). With neither join nor filter,
    # this is the unchanged M1 scalar expansion.
    gates = arrayop_expr.join_gates
    filt0 = arrayop_expr.filter
    if isempty(contract_names) && gates === nothing && filt0 === nothing
        return _resolve_indices(body, array_var_info, var_map, const_arrays,
                                pgather, memo, bound_syms)
    end
    # ── Runtime contraction loop opt-in (ess-runtime-contraction) ──────────────
    # Emit a compile-once loop for a SIMPLE UNIFORM reduction; everything else keeps
    # unrolling exactly as before. Gated conservatively (correctness first):
    #   * enabled (env), and NOT already inside an array-equation cell resolve
    #     (loop node is confined to scalar-walker contexts — see `_ARRAY_CELL_DEPTH`);
    #   * NOT the symbolic compile-once cellwise path (`bound_syms` empty) — that
    #     path binds its own reserved symbols and runs a separate evaluator;
    #   * a plain arithmetic reducer ∈ {+,*,max,min}, no join gates / filter;
    #   * every contracted range a CONSTANT integer range (ragged bounds keep
    #     unrolling — they already resolve to a per-cell concrete bound);
    #   * total reduction length ≥ the coverage floor;
    #   * the body resolves with the index symbolic (`_try_build_contraction_loop`
    #     returns `nothing` otherwise → unroll).
    if _contraction_loop_enabled() && _ARRAY_CELL_DEPTH[] == 0 &&
       isempty(bound_syms) && gates === nothing && filt0 === nothing &&
       (oplus == "+" || oplus == "*" || oplus == "max" || oplus == "min") &&
       all(n -> _is_const_int_range(ranges_dict[n]), contract_names)
        ranges = [_expand_int_range(ranges_dict[n]) for n in contract_names]
        total = isempty(ranges) ? 0 : prod(length(r) for r in ranges)
        if total >= _contraction_loop_min() && all(!isempty, ranges)
            looped = _try_build_contraction_loop(body, contract_names, ranges,
                        oplus, zerobar, array_var_info, var_map, const_arrays, pgather)
            looped === nothing || return looped
        end
    end
    terms = ASTExpr[]
    _foreach_aggregate_term(body, contract_names, contract_iters,
                            gates, filt0, zerobar) do term
        push!(terms, _resolve_indices(term, array_var_info, var_map, const_arrays,
                                      pgather, memo, bound_syms))
    end
    return _combine_with_reducer(oplus, zerobar, terms)
end

# Replace index(var, k1, k2, ...) nodes:
#   - In-bounds state/array var → VarExpr(cell_key) referencing the flat state slot.
#   - In-bounds const_array entry → NumExpr(literal) inlining the pre-computed value.
#   - Out-of-bounds → NumExpr(0.0) (ghost-cell convention for state arrays).
# array_var_info: var_name → (lo::Vector{Int}, hi::Vector{Int})
# const_arrays: pre-computed float arrays (1D Fornberg weights, or ND mesh connectivity)
#   keyed by array name; index(name, i1, i2, ...) → NumExpr(const_arrays[name][i1,i2,...])
#   also used for indirect gather: u[index(conn, c, k)] resolves conn[c,k] as an integer index.
# Read-only sentinel — see the `_EMPTY_*` invariant block next to
# `_EMPTY_DERIVED_EXTENTS`.
const _EMPTY_CONST_ARRAYS = Dict{String,AbstractArray{Float64}}()

# Empty scalar-parameter scope for a build-time cellwise evaluation with no
# parameters bound (the common case). Shared so `_eval_cellwise` /
# `evaluate_cellwise` avoid allocating a fresh dict per call on the no-param
# path. Read-only sentinel — see the `_EMPTY_*` invariant block next to
# `_EMPTY_DERIVED_EXTENTS`.
const _EMPTY_PARAMS = Dict{String,Float64}()

# A live forcing buffer bound by reference into the evaluator (ess-14f.3, JL-J0).
# Unlike `const_arrays` (build-time-FROZEN: `index(arr,…)` const-folds to a
# `NumExpr` literal, tree_walk.jl const-array branch), a `_PGatherArray` reroutes
# the SAME `index(forcing,…)` gather to a LIVE read of a captured `flat`
# `Vector{Float64}`. `flat = vec(buffer)` aliases the caller's dense
# `Array{Float64}` buffer, so a discrete refresh callback's in-place `buffer .= …`
# (ess-14f.3 J1) shows through to the RHS with zero reallocation. `dims` carries
# the source shape for bounds-checking + column-major linearization at build time.
# Reading the captured `flat` (NOT `getfield(p, runtime_sym)`) is what keeps the
# read zero-alloc: a runtime-symbol `getfield` on a heterogeneous NamedTuple boxes
# the union (measured 48 B/call) and would also regress the scalar `_NK_PARAM`
# path — see the JL-J0 feasibility-gate note in `_build_evaluator_impl`.
struct _PGatherArray
    flat::Vector{Float64}   # aliased flat view of the caller's buffer (live, by-ref)
    dims::Vector{Int}       # original shape — bounds-check + linearize at build time
end
# Read-only sentinel — see the `_EMPTY_*` invariant block next to
# `_EMPTY_DERIVED_EXTENTS`.
const _EMPTY_PGATHER = Dict{String,_PGatherArray}()

# The set of OUTPUT-INDEX symbol names kept SYMBOLIC through `_resolve_indices`
# (wall2 Phase C). It is EMPTY on every path except the compile-once
# `evaluate_cellwise` fast path, so the DEFAULT threaded through the whole
# resolve recursion is this shared read-only empty set — making every existing
# caller byte-identical to the pre-Phase-C behaviour (a name in this set is the
# ONLY thing that turns a const-array read into a runtime `_ConstGatherRef`
# instead of a folded `NumExpr`). Read-only sentinel — see the `_EMPTY_*`
# invariant block next to `_EMPTY_DERIVED_EXTENTS`.
const _EMPTY_BOUND_SYMS = Set{String}()

# True iff a subscript expression references any BOUND OUTPUT-INDEX symbol — the
# predicate that classifies one gather subscript as runtime-varying (→ keep
# symbolic, lower to `_NK_CONST_GATHER`) vs. build-time-constant (→ fold). Only
# the plain arithmetic subscripts an `index` gather ever carries are walked
# (`args`); an empty `bound_syms` makes this uniformly `false`, the fast exit on
# every non-fast-path call.
_refs_bound_sym(e::VarExpr, bound_syms::Set{String}) = e.name in bound_syms
_refs_bound_sym(e::OpExpr, bound_syms::Set{String}) =
    any(a -> _refs_bound_sym(a, bound_syms), e.args)
_refs_bound_sym(::ASTExpr, ::Set{String}) = false

# Gather from a build-time-constant Float64 array `vals` (registry `name`, used
# only for CSE identity / diagnostics) at the subscript expressions
# `idx_args_expr`. This is the ONE spelling of the const-array read, shared by
# the registered-const-array `index(name, …)` branch and the INLINE
# `index({op:const, value:[…]}, …)` branch below. Fully-constant subscripts fold
# to the scalar element (a `NumExpr` literal, the byte-identical frozen path); a
# subscript that references a bound output-index symbol kept symbolic (the
# compile-once `evaluate_cellwise` fast path, non-empty `bound_syms`) keeps the
# read runtime-varying and lowers to a `_ConstGatherRef` (→ `_NK_CONST_GATHER`),
# with the constant dims still folded to `IntExpr`s under the same
# `_resolve_const_index` boundary policy.
function _resolve_const_array_gather(vals::AbstractArray, name::String,
        idx_args_expr::Vector{ASTExpr},
        array_var_info::Dict{String,Tuple{Vector{Int},Vector{Int}}},
        var_map::Dict{String,Int}, const_arrays::AbstractDict,
        pgather::AbstractDict, memo::_MaybeMemo, bound_syms::Set{String})
    length(idx_args_expr) == ndims(vals) ||
        throw(TreeWalkError("E_TREEWALK_CONSTARRAY_NDIM",
              "const array '$(name)' is $(ndims(vals))D " *
              "but got $(length(idx_args_expr)) indices"))
    if any(a -> _refs_bound_sym(a, bound_syms), idx_args_expr)
        sub_nodes = Vector{ASTExpr}(undef, length(idx_args_expr))
        for d in 1:ndims(vals)
            a = idx_args_expr[d]
            if _refs_bound_sym(a, bound_syms)
                sub_nodes[d] = _resolve_indices(a, array_var_info, var_map,
                                                const_arrays, pgather, memo, bound_syms)
            else
                ci = _eval_const_int(a, _EMPTY_IDX_ENV, const_arrays)
                ci = _resolve_const_index(vals, name, d, ci, size(vals, d))
                sub_nodes[d] = IntExpr(Int64(ci))
            end
        end
        return OpExpr("index", sub_nodes; value=_ConstGatherRef(vals, name))
    end
    # Fully-constant subscripts: inline the value as a NumExpr literal.
    int_indices = [_eval_const_int(a, _EMPTY_IDX_ENV, const_arrays)
                   for a in idx_args_expr]
    for d in 1:ndims(vals)
        int_indices[d] = _resolve_const_index(vals, name, d, int_indices[d], size(vals, d))
    end
    return NumExpr(Float64(vals[int_indices...]))
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
    for (k, v) in const_arrays
        (startswith(k, _INLINE_CONST_PREFIX) && size(v) == size(vals) && v == vals) &&
            return v, k
    end
    name = string(_INLINE_CONST_PREFIX, hash(vals))
    const_arrays === _EMPTY_CONST_ARRAYS || (const_arrays[name] = vals)
    return vals, name
end

# Resolve each expression in `args`, returning `(resolved, changed)`. When no
# element changes under resolution the ORIGINAL `args` vector is returned (no
# allocation) and `changed` is false, letting the caller keep its node verbatim;
# only the first differing element triggers a single copy. Shared by the `index`
# fallback and the generic-recurse arm of `_resolve_indices`.
function _resolve_arg_vec(args::Vector{ASTExpr},
                          array_var_info::Dict{String,Tuple{Vector{Int},Vector{Int}}},
                          var_map::Dict{String,Int},
                          const_arrays::AbstractDict,
                          pgather::AbstractDict,
                          memo::_MaybeMemo=nothing,
                          bound_syms::Set{String}=_EMPTY_BOUND_SYMS)
    changed = false
    new_args = args
    @inbounds for i in eachindex(args)
        a = args[i]
        # Manual union-split (see `_sub_arg_vec`): the abstract `ASTExpr` element type
        # makes a bare `_resolve_indices(a, …)` a dynamic dispatch. `NumExpr`/
        # `IntExpr` resolve to themselves, so short-circuit them; `VarExpr` may
        # const-fold (scalar loader field) so it keeps its call; `OpExpr` recurses —
        # both now dispatch statically.
        r = a isa OpExpr  ? _resolve_indices(a, array_var_info, var_map, const_arrays, pgather, memo, bound_syms) :
            a isa VarExpr ? _resolve_indices(a, array_var_info, var_map, const_arrays, pgather, memo, bound_syms) :
            a                                            # NumExpr / IntExpr: verbatim
        if r !== a
            if !changed
                new_args = copy(args)
                changed = true
            end
            new_args[i] = r
        end
    end
    return new_args, changed
end

function _resolve_indices(expr::NumExpr,
                          array_var_info::Dict{String,Tuple{Vector{Int},Vector{Int}}},
                          var_map::Dict{String,Int},
                          const_arrays::AbstractDict=_EMPTY_CONST_ARRAYS,
                          pgather::AbstractDict=_EMPTY_PGATHER,
                          memo::_MaybeMemo=nothing,
                          bound_syms::Set{String}=_EMPTY_BOUND_SYMS)
    return expr
end
function _resolve_indices(expr::IntExpr,
                          array_var_info::Dict{String,Tuple{Vector{Int},Vector{Int}}},
                          var_map::Dict{String,Int},
                          const_arrays::AbstractDict=_EMPTY_CONST_ARRAYS,
                          pgather::AbstractDict=_EMPTY_PGATHER,
                          memo::_MaybeMemo=nothing,
                          bound_syms::Set{String}=_EMPTY_BOUND_SYMS)
    return expr
end
function _resolve_indices(expr::VarExpr,
                          array_var_info::Dict{String,Tuple{Vector{Int},Vector{Int}}},
                          var_map::Dict{String,Int},
                          const_arrays::AbstractDict=_EMPTY_CONST_ARRAYS,
                          pgather::AbstractDict=_EMPTY_PGATHER,
                          memo::_MaybeMemo=nothing,
                          bound_syms::Set{String}=_EMPTY_BOUND_SYMS)
    # Bare (un-indexed) reference to a const-array-backed SCALAR field
    # (RFC pure-io-data-loaders §4.3): a pure-I/O data-loader subsystem lowers
    # each of its variables to a const-array-backed observed keyed
    # `<owner>.<subkey>.<var>` (see flatten `_collect_model!`), and the provider
    # seam materializes a CONST loader field into `const_arrays` under that same
    # name (simulate.jl). When such a field is referenced by BARE name (not via a
    # gather `index(name, …)`) and is a genuine scalar — a 0-D field or a
    # single-cell array — const-fold it to its literal value here, so the compiler
    # (which only consults state/param maps) resolves it exactly as the gather path
    # already resolves `index(name, …)`. A live state slot always wins (never a
    # loader field), and a multi-element array left bare is not scalarisable, so it
    # passes through unchanged for the array machinery / normal error path.
    if !haskey(var_map, expr.name) && haskey(const_arrays, expr.name)
        arr = const_arrays[expr.name]
        if arr isa AbstractArray && length(arr) == 1
            return NumExpr(Float64(first(arr)))
        end
    end
    return expr
end
function _resolve_indices(expr::OpExpr,
                          array_var_info::Dict{String,Tuple{Vector{Int},Vector{Int}}},
                          var_map::Dict{String,Int},
                          const_arrays::AbstractDict=_EMPTY_CONST_ARRAYS,
                          pgather::AbstractDict=_EMPTY_PGATHER,
                          memo::_MaybeMemo=nothing,
                          bound_syms::Set{String}=_EMPTY_BOUND_SYMS)
    # The memo is keyed on node identity and is a pure function of the node ONLY
    # for a fixed `bound_syms`. It is threaded exclusively on the empty-`bound_syms`
    # RHS-build path (the compile-once fast path passes `memo=nothing`), so the two
    # modes never share a memo — a symbolic resolution can never be served from a
    # concrete memo entry.
    memo === nothing &&
        return _resolve_indices_op(expr, array_var_info, var_map, const_arrays, pgather, nothing, bound_syms)
    m = memo.resolve
    r = get(m, expr, nothing)
    r === nothing || return r
    r = _resolve_indices_op(expr, array_var_info, var_map, const_arrays, pgather, memo, bound_syms)
    m[expr] = r
    return r
end
function _resolve_indices_op(expr::OpExpr,
                          array_var_info::Dict{String,Tuple{Vector{Int},Vector{Int}}},
                          var_map::Dict{String,Int},
                          const_arrays::AbstractDict=_EMPTY_CONST_ARRAYS,
                          pgather::AbstractDict=_EMPTY_PGATHER,
                          memo::_MaybeMemo=nothing,
                          bound_syms::Set{String}=_EMPTY_BOUND_SYMS)
    if expr.op == "polygon_intersection_area"
        # FUSED clip+area scalar leaf (esm-spec §8.6.1). Both operands are
        # build-time-known const polygon rings (registered in `const_arrays`), so the
        # whole leaf const-folds to the scalar overlap area: clip under `manifold`,
        # then shoelace / spherical-excess area over the CLOSED ring. Reuses the
        # existing `intersect_polygon` + `polygon_area` FAQ kernels verbatim.
        length(expr.args) == 2 || throw(TreeWalkError("E_TREEWALK_GEOMETRY_ARITY",
            "polygon_intersection_area is strictly binary; got $(length(expr.args)) operand(s)"))
        expr.manifold === nothing && throw(TreeWalkError("E_TREEWALK_GEOMETRY_NO_MANIFOLD",
            "polygon_intersection_area requires a `manifold` (planar / spherical / geodesic)"))
        a = _pia_operand_ring(expr.args[1], const_arrays)
        b = _pia_operand_ring(expr.args[2], const_arrays)
        return NumExpr(_polygon_intersection_area(a, b, expr.manifold))
    end
    if expr.op == "index"
        isempty(expr.args) &&
            throw(TreeWalkError("E_TREEWALK_INDEX_EMPTY", "index op requires at least one arg"))
        first_arg = expr.args[1]
        # Expression-position arrayop: index(arrayop(...), k1, k2, ...)
        # Expand the arrayop at build time by substituting output_idx and
        # unrolling contracted indices (same strategy as the `_is_arrayop_D_lhs`
        # branch of `_build_evaluator_impl`'s derivative loop).
        if first_arg isa OpExpr && _is_aggregate_op(first_arg.op)
            return _resolve_index_of_arrayop(first_arg::OpExpr, expr.args[2:end],
                                             array_var_info, var_map, const_arrays, pgather, memo, bound_syms)
        end
        # Expression-position makearray: index(makearray(...), k1, k2, ...)
        # Select the value whose region covers (k1,...); later regions win.
        if first_arg isa OpExpr && first_arg.op == "makearray"
            return _resolve_index_of_makearray(first_arg::OpExpr, expr.args[2:end],
                                               array_var_info, var_map, const_arrays, pgather, memo, bound_syms)
        end
        # Expression-position INLINE `const` array literal:
        # index({op:const, value:[…]}, k1, …). A non-scalar `const` used as an
        # index target (e.g. the duo's `index({const [n][3][3]}, gt, d, k)`) is
        # build-time literal data — the same shape as a REGISTERED const-array
        # observed, only authored inline. Intern it (dedup by value) and gather it
        # through the shared const-array path so a constant index folds to the
        # element and a symbolic loop var lowers to a `_ConstGatherRef`. Without
        # this the literal survives untouched to `_compile` and hits the
        # `non-scalar const outside an array-consuming position` dead-end. A SCALAR
        # `const` (a `Real` value) is not an array target — it falls through to the
        # generic recurse and const-folds in `_compile` as before.
        if first_arg isa OpExpr && (first_arg::OpExpr).op == "const" &&
           (first_arg::OpExpr).value isa AbstractVector
            vals, cname = _intern_inline_const(first_arg::OpExpr, const_arrays)
            return _resolve_const_array_gather(vals, cname, expr.args[2:end],
                array_var_info, var_map, const_arrays, pgather, memo, bound_syms)
        end
        if first_arg isa VarExpr && haskey(array_var_info, first_arg.name)
            vname = first_arg.name
            lo, hi = array_var_info[vname]
            idx_args = expr.args[2:end]
            length(idx_args) == length(lo) ||
                throw(TreeWalkError("E_TREEWALK_INDEX_NDIM",
                      "$(vname) has $(length(lo))D but got $(length(idx_args)) index args"))
            # Pass const_arrays so nested index expressions like u[conn[c,k]] can be
            # resolved: _eval_const_int will look up conn[c,k] as an integer.
            indices = [_eval_const_int(a, _EMPTY_IDX_ENV, const_arrays) for a in idx_args]
            for d in 1:length(indices)
                if indices[d] < lo[d] || indices[d] > hi[d]
                    return NumExpr(0.0)  # ghost cell
                end
            end
            cname = _cell_key(vname, indices)
            haskey(var_map, cname) ||
                throw(TreeWalkError("E_TREEWALK_MISSING_CELL", cname))
            return VarExpr(cname)
        end
        # Live forcing buffer bound via `param_arrays` (ess-14f.3, JL-J0): reroute
        # this gather to a LIVE read instead of the frozen const-fold below. The
        # array is a discrete-cadence loader buffer (the driver routes const-cadence
        # data to `const_arrays` and discrete-cadence data here), so its contents
        # change at refresh boundaries and MUST NOT be inlined as a build-time
        # literal. Bounds-check and column-major-linearize the constant indices at
        # build time, then carry the aliased flat buffer + the offset to `_compile`
        # (which emits a `_NK_PARAM_GATHER`) as a typed `_PGatherRef` in `value`.
        # The ref also carries the buffer's registry NAME, which is what gives the
        # gather a canonicalizable CSE identity — `index` being CSE-opaque only stops
        # the gather from being hoisted itself, it does NOT keep the ref out of
        # `canonical_json`, which sees it as a child of every hoistable ancestor
        # (ess-qic; see `_PGatherRef` / `_pgather_key_expr` in compile.jl).
        if first_arg isa VarExpr && haskey(pgather, first_arg.name)
            pg = pgather[first_arg.name]::_PGatherArray
            idx_args_expr = expr.args[2:end]
            length(idx_args_expr) == length(pg.dims) ||
                throw(TreeWalkError("E_TREEWALK_PGATHER_NDIM",
                      "forcing array '$(first_arg.name)' is $(length(pg.dims))D " *
                      "but got $(length(idx_args_expr)) indices"))
            int_indices = [_eval_const_int(a, _EMPTY_IDX_ENV, const_arrays)
                           for a in idx_args_expr]
            for d in 1:length(pg.dims)
                (1 <= int_indices[d] <= pg.dims[d]) ||
                    throw(TreeWalkError("E_TREEWALK_PGATHER_OOB",
                          "forcing array '$(first_arg.name)' index $(int_indices[d]) " *
                          "out of range [1, $(pg.dims[d])] on dim $(d)"))
            end
            lin = LinearIndices(Tuple(pg.dims))[int_indices...]
            return OpExpr("index", ASTExpr[];
                          value=_PGatherRef(pg.flat, lin, first_arg.name))
        end
        # Pre-computed constant arrays (1D Fornberg weights, or ND mesh arrays).
        # RUNTIME-VARYING vs. fully-constant subscripts are handled uniformly by
        # `_resolve_const_array_gather` (see there); with an empty `bound_syms`
        # this is byte-identical to the pre-Phase-C const-fold.
        if first_arg isa VarExpr && haskey(const_arrays, first_arg.name)
            return _resolve_const_array_gather(const_arrays[first_arg.name],
                first_arg.name, expr.args[2:end], array_var_info, var_map,
                const_arrays, pgather, memo, bound_syms)
        end
        # scalar or unknown variable inside index — recurse on sub-exprs only
        new_args, changed = _resolve_arg_vec(expr.args, array_var_info, var_map, const_arrays, pgather, memo, bound_syms)
        changed || return expr   # nothing under this index resolved → keep node intact
        return reconstruct(expr; args=new_args)
    end
    if expr.op == "integral"
        # Euler/midpoint quadrature: integral(u, var=x) → dx * sum(u[k] for k in lo..hi)
        # Only expands when the integrand is a 1D array state variable known to
        # array_var_info. Falls through to generic recurse when integrand is not
        # an array var (e.g. a scalar parameter expression).
        isempty(expr.args) &&
            throw(TreeWalkError("E_TREEWALK_INTEGRAL_EMPTY",
                  "integral op requires at least one arg"))
        integrand = expr.args[1]
        iv = expr.int_var
        iv === nothing &&
            throw(TreeWalkError("E_TREEWALK_INTEGRAL_NO_INTVAR",
                  "integral op requires `var` field (integration variable name)"))
        if integrand isa VarExpr && haskey(array_var_info, integrand.name)
            vname = integrand.name
            lo_vec, hi_vec = array_var_info[vname]
            length(lo_vec) == 1 ||
                throw(TreeWalkError("E_TREEWALK_INTEGRAL_NDIM",
                      "euler_integral supports 1D integration only; " *
                      "'$vname' has $(length(lo_vec)) dimensions"))
            lo1 = lo_vec[1]; hi1 = hi_vec[1]
            cells = ASTExpr[VarExpr(_cell_key(vname, [i])) for i in lo1:hi1]
            for c in cells
                cname = (c::VarExpr).name
                haskey(var_map, cname) ||
                    throw(TreeWalkError("E_TREEWALK_MISSING_CELL", cname))
            end
            return OpExpr("*", ASTExpr[VarExpr("d$(iv)"), OpExpr("+", cells)])
        end
    end
    # Scalar aggregate (empty output_idx) in expression position: expand inline.
    # Non-scalar aggregate (non-empty output_idx) must be wrapped in index() —
    # handled by the _resolve_indices index-of-aggregate branch above.
    if _is_aggregate_op(expr.op)
        if isempty(_output_idx_strings(expr))
            return _resolve_scalar_arrayop(expr, array_var_info, var_map, const_arrays, pgather, memo, bound_syms)
        end
        # Non-scalar arrayop without index() — pass through (will become a
        # compile-time error in _compile with a helpful message).
    end
    new_args, changed = _resolve_arg_vec(expr.args, array_var_info, var_map, const_arrays, pgather, memo, bound_syms)
    new_body = expr.expr_body
    if expr.expr_body !== nothing
        new_body = _resolve_indices(expr.expr_body, array_var_info, var_map, const_arrays, pgather, memo, bound_syms)
        changed |= new_body !== expr.expr_body
    end
    new_values = expr.values
    if expr.values !== nothing
        nv, vchanged = _resolve_arg_vec(expr.values, array_var_info, var_map, const_arrays, pgather, memo, bound_syms)
        new_values = nv
        changed |= vchanged
    end
    # No child, body, or value expression changed under resolution ⇒ the node is
    # already fully resolved; return it verbatim rather than rebuilding a ~30-field
    # OpExpr. In a stencil RHS the pure-parameter subtrees hit this fast path.
    changed || return expr
    return reconstruct(expr; args=new_args, expr_body=new_body, values=new_values)
end

# Detect which state variables are used in array context (inside index ops)
# by scanning equation LHS patterns and initial_condition keys.
function _detect_array_vars(equations::Vector{Equation},
                             state_var_names::Set{String},
                             initial_conditions::AbstractDict)
    detected = Set{String}()
    # From initial conditions: "u[3]" style keys imply array usage.
    for (key, _) in initial_conditions
        parsed = _parse_cell_key(String(key))
        parsed === nothing && continue
        vname = parsed[1]
        vname in state_var_names && push!(detected, vname)
    end
    # From equation LHS patterns.
    for eq in equations
        lhs = eq.lhs
        if _is_indexed_D_lhs(lhs)
            inner = (lhs::OpExpr).args[1]::OpExpr
            first_arg = inner.args[1]
            if first_arg isa VarExpr && first_arg.name in state_var_names
                push!(detected, first_arg.name)
            end
        elseif lhs isa OpExpr && _is_aggregate_op(lhs.op)
            body = lhs.expr_body
            if body isa OpExpr && body.op == "D" && !isempty(body.args)
                inner = body.args[1]
                if inner isa OpExpr && inner.op == "index" && !isempty(inner.args)
                    fa = inner.args[1]
                    if fa isa VarExpr && fa.name in state_var_names
                        push!(detected, fa.name)
                    end
                end
            end
        end
    end
    return detected
end

# Scan equations and initial_conditions to discover all array cells.
# Returns Dict{String, Vector{Vector{Int}}} — var_name → sorted list of index tuples.
function _discover_array_cells(
        equations::Vector{Equation},
        initial_conditions::AbstractDict,
        array_var_names::Set{String})
    cells = Dict{String, Set{Vector{Int}}}()

    # From initial conditions: parse "u[3]" or "u[2,3]" style keys.
    for (key, _) in initial_conditions
        parsed = _parse_cell_key(String(key))
        parsed === nothing && continue
        vname, indices = parsed
        vname in array_var_names || continue
        if !haskey(cells, vname); cells[vname] = Set{Vector{Int}}(); end
        push!(cells[vname], indices)
    end

    # From equation LHS.
    for eq in equations
        _scan_lhs_cells!(cells, eq.lhs, array_var_names)
    end

    # Sort each var's cells and return as Vector{Vector{Int}}.
    return Dict{String, Vector{Vector{Int}}}(
        vname => sort(collect(cset)) for (vname, cset) in cells)
end

function _scan_lhs_cells!(cells, lhs::ASTExpr, array_var_names::Set{String})
    if lhs isa OpExpr && lhs.op == "D" && lhs.wrt == "t" &&
           length(lhs.args) == 1 && lhs.args[1] isa OpExpr &&
           lhs.args[1].op == "index"
        # D(index(var, k...))
        inner = lhs.args[1]
        first_arg = inner.args[1]
        first_arg isa VarExpr || return
        first_arg.name in array_var_names || return
        idx_args = inner.args[2:end]
        try
            indices = [_eval_const_int(a, _EMPTY_IDX_ENV) for a in idx_args]
            vname = first_arg.name
            if !haskey(cells, vname); cells[vname] = Set{Vector{Int}}(); end
            push!(cells[vname], indices)
        catch err
            # A non-constant index expression is simply not discoverable here
            # (the arrayop path enumerates it); anything else is a real bug.
            err isa TreeWalkError || rethrow()
        end
        return
    end
    if lhs isa OpExpr && _is_aggregate_op(lhs.op)
        # aggregate(expr=D(index(var, idx_exprs...)), output_idx=[...], ranges={...})
        lhs_body = lhs.expr_body
        lhs_body === nothing && return
        lhs_body isa OpExpr && lhs_body.op == "D" && lhs_body.wrt == "t" &&
            length(lhs_body.args) == 1 && lhs_body.args[1] isa OpExpr &&
            lhs_body.args[1].op == "index" || return
        inner = lhs_body.args[1]
        first_arg = inner.args[1]
        first_arg isa VarExpr || return
        first_arg.name in array_var_names || return
        vname = first_arg.name

        idx_names = _output_idx_strings(lhs)
        ranges_dict = _ranges_dict(lhs)
        range_iters = [collect(_expand_int_range(ranges_dict[n])) for n in idx_names]

        if !haskey(cells, vname); cells[vname] = Set{Vector{Int}}(); end
        idx_args = inner.args[2:end]
        try
            for idx_tuple in Iterators.product(range_iters...)
                idx_env = Dict{String,Int}(idx_names[d] => idx_tuple[d]
                                           for d in 1:length(idx_names))
                indices = [_eval_const_int(a, idx_env) for a in idx_args]
                push!(cells[vname], indices)
            end
        catch err
            # An index expression that is not constant under the loop bindings
            # is not discoverable here; anything else is a real bug.
            err isa TreeWalkError || rethrow()
        end
        return
    end
end

# Identify D(scalar_var) — the classic scalar ODE LHS.
function _is_scalar_D_lhs(lhs)
    return isa(lhs, OpExpr) && lhs.op == "D" && lhs.wrt == "t" &&
           length(lhs.args) == 1 && isa(lhs.args[1], VarExpr)
end

# Identify D(index(var, k...)) — indexed scalar derivative.
function _is_indexed_D_lhs(lhs)
    return isa(lhs, OpExpr) && lhs.op == "D" && lhs.wrt == "t" &&
           length(lhs.args) == 1 &&
           isa(lhs.args[1], OpExpr) && lhs.args[1].op == "index"
end

# Identify arrayop(D(index(var, ...)), ...) — array-loop derivative LHS.
function _is_arrayop_D_lhs(lhs)
    lhs isa OpExpr && _is_aggregate_op(lhs.op) || return false
    body = lhs.expr_body
    body === nothing && return false
    return body isa OpExpr && body.op == "D" && body.wrt == "t" &&
           length(body.args) == 1 &&
           body.args[1] isa OpExpr && body.args[1].op == "index"
end

# Extract the scalar body from an arrayop node (or return expr unchanged).
# Used to unwrap the RHS of an arrayop equation.
function _extract_arrayop_body(expr::ASTExpr)
    if expr isa OpExpr && _is_aggregate_op(expr.op)
        expr.expr_body !== nothing && return expr.expr_body
    end
    return expr
end

function _select_model(file::EsmFile, name::Union{Nothing,AbstractString})
    file.models === nothing &&
        throw(TreeWalkError("E_TREEWALK_NO_MODEL", "EsmFile.models is nothing"))
    models = file.models
    if name !== nothing
        haskey(models, String(name)) ||
            throw(TreeWalkError("E_TREEWALK_NO_MODEL", String(name)))
        return models[String(name)]
    end
    length(models) == 1 ||
        throw(TreeWalkError("E_TREEWALK_AMBIGUOUS_MODEL",
                            "specify model_name; have: " *
                            join(collect(keys(models)), ", ")))
    return first(values(models))
end
