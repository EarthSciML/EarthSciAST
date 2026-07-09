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
        idx_args = Expr[VarExpr(off)]
        append!(idx_args, Expr[VarExpr(p) for p in ref.of])
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
function _has_index_set_ref(expr::OpExpr)
    if expr.ranges !== nothing
        for v in values(expr.ranges)
            v isa IndexSetRef && return true
        end
    end
    any(_has_index_set_ref, expr.args) && return true
    expr.expr_body !== nothing && _has_index_set_ref(expr.expr_body) && return true
    expr.values !== nothing && any(_has_index_set_ref, expr.values) && return true
    expr.lower !== nothing && _has_index_set_ref(expr.lower) && return true
    expr.upper !== nothing && _has_index_set_ref(expr.upper) && return true
    return false
end
_has_index_set_ref(::Expr) = false
_has_index_set_ref(eq::Equation) = _has_index_set_ref(eq.lhs) || _has_index_set_ref(eq.rhs)

# Rewrite every IndexSetRef in the subtree's ranges to its resolved concrete
# form, rebuilding OpExpr nodes while preserving all fields.
function _resolve_isr(expr::OpExpr, index_sets::AbstractDict,
                      derived_extents::AbstractDict=_EMPTY_DERIVED_EXTENTS,
                      factor_scope::AbstractDict=_EMPTY_FACTOR_SCOPE)
    new_args = Expr[_resolve_isr(a, index_sets, derived_extents, factor_scope) for a in expr.args]
    new_body = expr.expr_body === nothing ? nothing : _resolve_isr(expr.expr_body, index_sets, derived_extents, factor_scope)
    new_values = expr.values === nothing ? nothing :
                 Expr[_resolve_isr(v, index_sets, derived_extents, factor_scope) for v in expr.values]
    new_lower = expr.lower === nothing ? nothing : _resolve_isr(expr.lower, index_sets, derived_extents, factor_scope)
    new_upper = expr.upper === nothing ? nothing : _resolve_isr(expr.upper, index_sets, derived_extents, factor_scope)
    new_ranges = expr.ranges
    if expr.ranges !== nothing && any(v -> v isa IndexSetRef, values(expr.ranges))
        new_ranges = Dict{String,Any}()
        for (k, v) in expr.ranges
            new_ranges[k] = v isa IndexSetRef ?
                _resolve_one_index_set_ref(v, index_sets, derived_extents, factor_scope) : v
        end
    end
    return reconstruct(expr; args=new_args, expr_body=new_body,
                       values=new_values, lower=new_lower, upper=new_upper,
                       ranges=new_ranges)
end
_resolve_isr(expr::Expr, ::AbstractDict, ::AbstractDict=_EMPTY_DERIVED_EXTENTS,
             ::AbstractDict=_EMPTY_FACTOR_SCOPE) = expr
_resolve_isr(eq::Equation, index_sets::AbstractDict,
             derived_extents::AbstractDict=_EMPTY_DERIVED_EXTENTS,
             factor_scope::AbstractDict=_EMPTY_FACTOR_SCOPE) =
    Equation(_resolve_isr(eq.lhs, index_sets, derived_extents, factor_scope),
             _resolve_isr(eq.rhs, index_sets, derived_extents, factor_scope);
             _comment=eq._comment)

# Resolve all index-set references across a vector of equations. Returns the
# input unchanged when no equation uses a `{from}` reference — preserving
# byte-identical behaviour (and the compiled tree) for existing files (§6).
function _resolve_index_set_ranges(eqs::Vector{Equation}, index_sets::AbstractDict,
                                   derived_extents::AbstractDict=_EMPTY_DERIVED_EXTENTS,
                                   factor_scope::AbstractDict=_EMPTY_FACTOR_SCOPE)
    any(_has_index_set_ref, eqs) || return eqs
    return Equation[_resolve_isr(eq, index_sets, derived_extents, factor_scope) for eq in eqs]
end

# Resolve index(arrayop(...), k1, k2, ...) in expression position by
# substituting the output_idx values and unrolling contracted indices at
# build time. Mirrors the LHS-arrayop expansion (the `_is_arrayop_D_lhs`
# branch of `_build_evaluator_impl`'s derivative loop) but produces a scalar
# Expr instead of writing to rhs_list.
function _resolve_index_of_arrayop(arrayop_expr::OpExpr, idx_args::Vector{Expr},
                                    array_var_info, var_map, const_arrays,
                                    pgather::AbstractDict=_EMPTY_PGATHER,
                                    memo::_MaybeMemo=nothing)
    output_idx_raw = arrayop_expr.output_idx === nothing ? Any[] : arrayop_expr.output_idx
    output_idx_strs = [String(s) for s in output_idx_raw if s isa AbstractString]
    length(output_idx_strs) == length(idx_args) ||
        throw(TreeWalkError("E_TREEWALK_ARRAYOP_INDEX_NDIM",
              "arrayop output_idx has $(length(output_idx_strs)) dims " *
              "but $(length(idx_args)) index args"))
    body = arrayop_expr.expr_body
    body === nothing &&
        throw(TreeWalkError("E_TREEWALK_ARRAYOP_NO_BODY",
                            "arrayop requires an expr body"))
    ranges_dict = arrayop_expr.ranges === nothing ? Dict{String,Any}() : arrayop_expr.ranges
    oplus, zerobar = _aggregate_oplus_identity(arrayop_expr.semiring, arrayop_expr.reduce)

    # Substitute concrete output-index values into body.
    k_vals = [_eval_const_int(a, _EMPTY_IDX_ENV, const_arrays) for a in idx_args]
    idx_exprs = Dict{String,Expr}(
        output_idx_strs[d] => IntExpr(Int64(k_vals[d]))
        for d in 1:length(output_idx_strs))
    sub_body = _sub_preserving(body, idx_exprs)

    # Contracted indices: all range keys NOT appearing in output_idx.
    output_idx_set = Set(output_idx_strs)
    contract_names = sort!(String[n for n in keys(ranges_dict) if !(n in output_idx_set)])
    # A contracted bound may be *expression-valued*: a RAGGED index-set range
    # (`{from: <ragged>, of: [i]}`, esm-spec §4.3.1 / RFC §5.2) resolves to the
    # per-cell dynamic upper bound `index(offsets, i)` whose parent index `i` is
    # one of THIS gather's (now concrete) output indices. Evaluate such bounds
    # under the output-index environment via the same `_expand_int_range_dyn`
    # primitive the LHS-arrayop einsum uses (variable-valence segment reduction
    # over the CSR offsets keyed factor — a const array; no host-side padding).
    # Constant bounds keep the unchanged fast path.
    _out_idx_env = Dict{String,Int}(output_idx_strs[d] => k_vals[d]
                                    for d in 1:length(output_idx_strs))
    contract_iters = [collect(_is_const_int_range(ranges_dict[n]) ?
                              _expand_int_range(ranges_dict[n]) :
                              _expand_int_range_dyn(ranges_dict[n], _out_idx_env,
                                                    const_arrays))
                      for n in contract_names]

    # M2 (§5.3 / §7.2): value-equality join gates + filter predicate. Resolved at
    # build time for the join (drop non-matching combinations) and compiled to a
    # runtime `ifelse(pred, term, 0̄)` for the filter. With neither, this is the
    # unchanged M1 expansion.
    gates = arrayop_expr.join_gates
    filt0 = arrayop_expr.filter
    if isempty(contract_names) && gates === nothing && filt0 === nothing
        return _resolve_indices(sub_body, array_var_info, var_map, const_arrays, pgather, memo)
    end

    terms = Expr[]
    # Reused across the product: `_sub_preserving`/`_join_admits` only READ these
    # dicts (never retain them), and the key SET is identical every iteration — only
    # the values change — so overwriting in place avoids a fresh `Dict` allocation
    # (and its string hashing) per contracted tuple. `binding` additionally holds the
    # (fixed) output indices, seeded once here.
    k_exprs = Dict{String,Expr}()
    binding = gates === nothing ? nothing : Dict{String,Int}()
    if binding !== nothing
        for d in 1:length(output_idx_strs)
            binding[output_idx_strs[d]] = k_vals[d]
        end
    end
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
        term = _sub_preserving(sub_body, k_exprs)
        if filt0 !== nothing
            filt = _sub_preserving(_sub_preserving(filt0, idx_exprs), k_exprs)
            term = OpExpr("ifelse", Expr[filt, term, NumExpr(zerobar)])
        end
        push!(terms, _resolve_indices(term, array_var_info, var_map, const_arrays, pgather, memo))
    end
    return _combine_with_reducer(oplus, zerobar, terms)
end

# Resolve index(makearray(regions=[...], values=[...]), k1, k2, ...) by
# selecting the value expression whose region covers (k1, k2, ...).
# Later regions overwrite earlier ones, matching the Python reference
# semantics (`_eval_makearray` in numpy_interpreter.py).
function _resolve_index_of_makearray(makearray_expr::OpExpr, idx_args::Vector{Expr},
                                      array_var_info, var_map, const_arrays,
                                      pgather::AbstractDict=_EMPTY_PGATHER,
                                      memo::_MaybeMemo=nothing)
    regions = makearray_expr.regions === nothing ?
              Vector{Vector{Vector{Int}}}() : makearray_expr.regions
    values  = makearray_expr.values  === nothing ? Expr[] : makearray_expr.values
    length(regions) == length(values) ||
        throw(TreeWalkError("E_TREEWALK_MAKEARRAY_MISMATCH",
              "makearray regions/values length mismatch " *
              "($(length(regions)) vs $(length(values)))"))
    k_vals = [_eval_const_int(a, _EMPTY_IDX_ENV, const_arrays) for a in idx_args]
    ndim   = length(k_vals)
    result_expr::Expr = NumExpr(0.0)  # default: 0 if no region covers the point
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
            count(s -> s isa AbstractString, re.output_idx)
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
        sel_exprs = Expr[IntExpr(Int64(v)) for v in sel]
        return re.op == "makearray" ?
            _resolve_index_of_makearray(re, sel_exprs, array_var_info, var_map,
                                        const_arrays, pgather) :
            _resolve_index_of_arrayop(re, sel_exprs, array_var_info, var_map,
                                      const_arrays, pgather)
    end
    return _resolve_indices(result_expr, array_var_info, var_map, const_arrays, pgather, memo)
end

# Expand a scalar arrayop (empty output_idx) to a plain scalar Expr by
# unrolling all contracted indices at build time and combining them with the
# declared reducer. This is the build-time equivalent of an einsum over a
# general expression body — compile once, evaluate cheaply at every RHS call.
function _resolve_scalar_arrayop(arrayop_expr::OpExpr, array_var_info, var_map, const_arrays,
                                 pgather::AbstractDict=_EMPTY_PGATHER,
                                 memo::_MaybeMemo=nothing)
    body = arrayop_expr.expr_body
    body === nothing &&
        throw(TreeWalkError("E_TREEWALK_ARRAYOP_NO_BODY",
                            "arrayop requires an expr body"))
    ranges_dict  = arrayop_expr.ranges === nothing ? Dict{String,Any}() : arrayop_expr.ranges
    oplus, zerobar = _aggregate_oplus_identity(arrayop_expr.semiring, arrayop_expr.reduce)
    contract_names = sort!(String[n for n in keys(ranges_dict)])
    # A contracted range bound may be a per-cell INDEX EXPRESSION (e.g. the
    # variable-valence unstructured reduction's `index(n_edges_on_cell, i)`).
    # This scalar-arrayop resolver is reached from `_resolve_indices` AFTER the
    # outer loop variable has been substituted to a literal in `body`/`ranges`,
    # so the bound is evaluable now via `_eval_const_int` against `const_arrays`
    # with an empty idx_env (any surviving symbol would be unbound — an error,
    # as before). Constant bounds pass through unchanged (backward compatible).
    _empty_idx = Dict{String,Int}()
    contract_iters = [collect(_is_const_int_range(ranges_dict[n]) ?
                              _expand_int_range(ranges_dict[n]) :
                              _expand_int_range_dyn(ranges_dict[n], _empty_idx, const_arrays))
                      for n in contract_names]
    # M2 (§5.3 / §7.2): build-time join gates + runtime filter guard. Every join
    # key of a scalar aggregate is a contracted symbol, so the binding is the
    # contraction tuple. With neither join nor filter, this is the unchanged M1
    # scalar expansion.
    gates = arrayop_expr.join_gates
    filt0 = arrayop_expr.filter
    if isempty(contract_names) && gates === nothing && filt0 === nothing
        return _resolve_indices(body, array_var_info, var_map, const_arrays, pgather, memo)
    end
    terms = Expr[]
    for k_tuple in Iterators.product(contract_iters...)
        if gates !== nothing
            binding = Dict{String,Int}()
            for d in 1:length(contract_names)
                binding[contract_names[d]] = k_tuple[d]
            end
            _join_admits(gates, binding) || continue
        end
        k_exprs = Dict{String,Expr}(
            contract_names[d] => IntExpr(Int64(k_tuple[d]))
            for d in 1:length(contract_names))
        term = _sub_preserving(body, k_exprs)
        if filt0 !== nothing
            filt = _sub_preserving(filt0, k_exprs)
            term = OpExpr("ifelse", Expr[filt, term, NumExpr(zerobar)])
        end
        push!(terms, _resolve_indices(term, array_var_info, var_map, const_arrays, pgather, memo))
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

# Resolve each expression in `args`, returning `(resolved, changed)`. When no
# element changes under resolution the ORIGINAL `args` vector is returned (no
# allocation) and `changed` is false, letting the caller keep its node verbatim;
# only the first differing element triggers a single copy. Shared by the `index`
# fallback and the generic-recurse arm of `_resolve_indices`.
function _resolve_arg_vec(args::Vector{Expr},
                          array_var_info::Dict{String,Tuple{Vector{Int},Vector{Int}}},
                          var_map::Dict{String,Int},
                          const_arrays::AbstractDict,
                          pgather::AbstractDict,
                          memo::_MaybeMemo=nothing)
    changed = false
    new_args = args
    @inbounds for i in eachindex(args)
        a = args[i]
        # Manual union-split (see `_sub_arg_vec`): the abstract `Expr` element type
        # makes a bare `_resolve_indices(a, …)` a dynamic dispatch. `NumExpr`/
        # `IntExpr` resolve to themselves, so short-circuit them; `VarExpr` may
        # const-fold (scalar loader field) so it keeps its call; `OpExpr` recurses —
        # both now dispatch statically.
        r = a isa OpExpr  ? _resolve_indices(a, array_var_info, var_map, const_arrays, pgather, memo) :
            a isa VarExpr ? _resolve_indices(a, array_var_info, var_map, const_arrays, pgather, memo) :
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
                          memo::_MaybeMemo=nothing)
    return expr
end
function _resolve_indices(expr::IntExpr,
                          array_var_info::Dict{String,Tuple{Vector{Int},Vector{Int}}},
                          var_map::Dict{String,Int},
                          const_arrays::AbstractDict=_EMPTY_CONST_ARRAYS,
                          pgather::AbstractDict=_EMPTY_PGATHER,
                          memo::_MaybeMemo=nothing)
    return expr
end
function _resolve_indices(expr::VarExpr,
                          array_var_info::Dict{String,Tuple{Vector{Int},Vector{Int}}},
                          var_map::Dict{String,Int},
                          const_arrays::AbstractDict=_EMPTY_CONST_ARRAYS,
                          pgather::AbstractDict=_EMPTY_PGATHER,
                          memo::_MaybeMemo=nothing)
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
                          memo::_MaybeMemo=nothing)
    memo === nothing &&
        return _resolve_indices_op(expr, array_var_info, var_map, const_arrays, pgather, nothing)
    m = memo.resolve
    r = get(m, expr, nothing)
    r === nothing || return r
    r = _resolve_indices_op(expr, array_var_info, var_map, const_arrays, pgather, memo)
    m[expr] = r
    return r
end
function _resolve_indices_op(expr::OpExpr,
                          array_var_info::Dict{String,Tuple{Vector{Int},Vector{Int}}},
                          var_map::Dict{String,Int},
                          const_arrays::AbstractDict=_EMPTY_CONST_ARRAYS,
                          pgather::AbstractDict=_EMPTY_PGATHER,
                          memo::_MaybeMemo=nothing)
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
                                             array_var_info, var_map, const_arrays, pgather, memo)
        end
        # Expression-position makearray: index(makearray(...), k1, k2, ...)
        # Select the value whose region covers (k1,...); later regions win.
        if first_arg isa OpExpr && first_arg.op == "makearray"
            return _resolve_index_of_makearray(first_arg::OpExpr, expr.args[2:end],
                                               array_var_info, var_map, const_arrays, pgather, memo)
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
        # `index` is CSE-opaque, so the runtime payload is canonicalization-safe.
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
            return OpExpr("index", Expr[]; value=_PGatherRef(pg.flat, lin))
        end
        # Pre-computed constant arrays (1D Fornberg weights, or ND mesh arrays):
        # inline the value as a NumExpr literal.
        if first_arg isa VarExpr && haskey(const_arrays, first_arg.name)
            vals = const_arrays[first_arg.name]
            idx_args_expr = expr.args[2:end]
            length(idx_args_expr) == ndims(vals) ||
                throw(TreeWalkError("E_TREEWALK_CONSTARRAY_NDIM",
                      "const array '$(first_arg.name)' is $(ndims(vals))D " *
                      "but got $(length(idx_args_expr)) indices"))
            int_indices = [_eval_const_int(a, _EMPTY_IDX_ENV, const_arrays)
                           for a in idx_args_expr]
            for d in 1:ndims(vals)
                int_indices[d] = _resolve_const_index(vals, first_arg.name, d, int_indices[d], size(vals, d))
            end
            return NumExpr(Float64(vals[int_indices...]))
        end
        # scalar or unknown variable inside index — recurse on sub-exprs only
        new_args, changed = _resolve_arg_vec(expr.args, array_var_info, var_map, const_arrays, pgather, memo)
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
            cells = Expr[VarExpr(_cell_key(vname, [i])) for i in lo1:hi1]
            for c in cells
                cname = (c::VarExpr).name
                haskey(var_map, cname) ||
                    throw(TreeWalkError("E_TREEWALK_MISSING_CELL", cname))
            end
            return OpExpr("*", Expr[VarExpr("d$(iv)"), OpExpr("+", cells)])
        end
    end
    # Scalar aggregate (empty output_idx) in expression position: expand inline.
    # Non-scalar aggregate (non-empty output_idx) must be wrapped in index() —
    # handled by the _resolve_indices index-of-aggregate branch above.
    if _is_aggregate_op(expr.op)
        output_idx_raw = expr.output_idx === nothing ? Any[] : expr.output_idx
        output_idx_strs = [s for s in output_idx_raw if s isa AbstractString]
        if isempty(output_idx_strs)
            return _resolve_scalar_arrayop(expr, array_var_info, var_map, const_arrays, pgather, memo)
        end
        # Non-scalar arrayop without index() — pass through (will become a
        # compile-time error in _compile with a helpful message).
    end
    new_args, changed = _resolve_arg_vec(expr.args, array_var_info, var_map, const_arrays, pgather, memo)
    new_body = expr.expr_body
    if expr.expr_body !== nothing
        new_body = _resolve_indices(expr.expr_body, array_var_info, var_map, const_arrays, pgather, memo)
        changed |= new_body !== expr.expr_body
    end
    new_values = expr.values
    if expr.values !== nothing
        nv, vchanged = _resolve_arg_vec(expr.values, array_var_info, var_map, const_arrays, pgather, memo)
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

function _scan_lhs_cells!(cells, lhs::Expr, array_var_names::Set{String})
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

        idx_names = String[]
        for sym in (lhs.output_idx === nothing ? Any[] : lhs.output_idx)
            (sym isa String || sym isa AbstractString) && push!(idx_names, String(sym))
        end
        ranges_dict = lhs.ranges === nothing ? Dict{String,Any}() : lhs.ranges
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
function _extract_arrayop_body(expr::Expr)
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
