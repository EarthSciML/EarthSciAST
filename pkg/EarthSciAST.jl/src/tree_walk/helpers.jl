# ========================================================================
# tree_walk/helpers.jl — part of the tree-walk evaluator (gt-e8yw).
# Included by src/tree_walk.jl; see that file for the full layout and
# include order. Sections 5/5b: misc helpers (_sub_preserving, _resolve_observed) and
# array-variable helpers (_cell_key/_parse_cell_key, field ICs, ranges,
# _eval_const_int).
# ========================================================================

# ============================================================
# 5. Misc helpers
# ============================================================

# _is_scalar_D_lhs is defined in the array helpers section (5b).

function _equation_tag(eq::Equation)
    if eq._comment !== nothing
        return eq._comment
    end
    return string(typeof(eq.lhs))
end

# Variable substitution that preserves every OpExpr field — the
# package-level `substitute` only carries `wrt`/`dim` and drops
# `handler_id`, `fn`, etc., which would corrupt `call`/`broadcast`
# nodes on their way through. Scoped here because this module is the
# only caller that needs the full preservation.
function _sub_preserving(expr::NumExpr, bindings::Dict{String,ASTExpr})
    return expr
end
function _sub_preserving(expr::IntExpr, bindings::Dict{String,ASTExpr})
    return expr
end
function _sub_preserving(expr::VarExpr, bindings::Dict{String,ASTExpr})
    return get(bindings, expr.name, expr)
end

# Substitute each expression in `args`, returning `(substituted, changed)`. Like
# `_resolve_arg_vec`, the ORIGINAL vector is returned untouched (no allocation)
# when no element binds, and only the first differing element triggers a copy.
function _sub_arg_vec(args::Vector{ASTExpr}, bindings::Dict{String,ASTExpr})
    changed = false
    new_args = args
    @inbounds for i in eachindex(args)
        a = args[i]
        # Manual union-split over the four concrete `ASTExpr` subtypes. `args` has the
        # abstract element type `ASTExpr`, so a bare `_sub_preserving(a, …)` dispatches
        # dynamically (`ijl_apply_generic`) — the single largest flat cost in the
        # build profile. Narrowing with `isa` lets the `OpExpr`/`VarExpr` calls
        # resolve statically and short-circuits the `NumExpr`/`IntExpr` leaves
        # (which `_sub_preserving` returns verbatim) with no call at all.
        r = a isa OpExpr  ? _sub_preserving(a, bindings) :
            a isa VarExpr ? get(bindings, a.name, a) :
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

function _sub_preserving(expr::OpExpr, bindings::Dict{String,ASTExpr})
    new_args, changed = _sub_arg_vec(expr.args, bindings)
    new_body = expr.expr_body
    if expr.expr_body !== nothing
        new_body = _sub_preserving(expr.expr_body, bindings)
        changed |= new_body !== expr.expr_body
    end
    new_values = expr.values
    if expr.values !== nothing
        nv, vchanged = _sub_arg_vec(expr.values, bindings)
        new_values = nv
        changed |= vchanged
    end
    # Substitute loop-var bindings into a `filter` predicate too, so a nested
    # aggregate's filter sees the outer index values (the join's `join_gates` are
    # position-keyed and need no substitution — they are carried through).
    new_filter = expr.filter
    if expr.filter !== nothing
        new_filter = _sub_preserving(expr.filter, bindings)
        changed |= new_filter !== expr.filter
    end
    # A node with no bound descendant AND no range bounds to rewrite is returned
    # verbatim — no ~30-field OpExpr rebuilt. Nodes carrying `ranges` (only nested
    # aggregates do) always take the reconstruct path so their bound expressions
    # get substituted; those are rare relative to the plain stencil math ops that
    # dominate a per-cell substitution.
    if expr.ranges === nothing && !changed
        return expr
    end
    # Substitute loop-var bindings into range BOUNDS too, so a nested arrayop
    # whose reduction bound references an OUTER loop index — e.g. a per-cell
    # variable-valence reduction `k ∈ [1, index(n_edges_on_cell, i)]` inside an
    # outer `i`-loop — has `i` resolved when the inner arrayop is later expanded.
    # Bounds are Int (pass through) or ASTExpr (recursively substituted).
    new_ranges = _sub_ranges(expr.ranges, bindings)
    # `reconstruct` (types.jl) copies every remaining OpExpr field, so the full
    # preservation this helper promises holds even as fields are added.
    return reconstruct(expr; args=new_args, expr_body=new_body,
                       values=new_values, filter=new_filter, ranges=new_ranges)
end

# Substitute loop-var bindings into an arrayop `ranges` dict's bound expressions.
# Each entry is a vector whose elements are Int (left as-is) or an ASTExpr bound
# (recursively `_sub_preserving`d). Returns `nothing` unchanged when ranges is
# nothing; otherwise a fresh Dict so the original is never mutated.
_sub_ranges(ranges::Nothing, ::Dict{String,ASTExpr}) = nothing
function _sub_ranges(ranges, bindings::Dict{String,ASTExpr})
    out = Dict{String,Any}()
    for (k, v) in ranges
        out[String(k)] = v isa AbstractVector ?
            Any[(e isa ASTExpr ? _sub_preserving(e, bindings) : e) for e in v] : v
    end
    return out
end

# Resolve observed-into-observed substitutions to a fixed point. After
# this runs, no RHS in the returned dict contains another observed
# variable as a free variable — so inlining observed names into a
# model equation is a single `_sub_preserving` call. Iteration cap =
# depth of the longest valid chain; exceeding it means there's a cycle.
function _resolve_observed(obs::Dict{String,ASTExpr})
    resolved = Dict{String,ASTExpr}()
    for (k, v) in obs
        resolved[k] = v
    end
    names = Set(keys(obs))
    # Max chain depth before we call it a cycle. One pass per observer
    # is always enough to collapse any acyclic chain.
    for _ in 1:(length(obs) + 1)
        any_change = false
        for (k, v) in resolved
            # `_referenced_var_names` (not `free_variables`) so a chain that runs
            # THROUGH an arrayop/aggregate body is detected — a live-field geometry
            # observed reads its upstream regrid output inside an arrayop, which
            # `free_variables` treats as bound-away and would leave un-inlined
            # (ess-14f.4). For a scalar value the two agree, so scalar observeds are
            # byte-identical; only array-valued observeds gain transitive collapse.
            # The `n in names` guard means only observed-named references trigger a
            # rewrite, so the extra bound loop indices it surfaces are inert.
            fv = _referenced_var_names(v)
            if any(n -> n in names, fv)
                resolved[k] = _sub_preserving(v, resolved)
                any_change = true
            end
        end
        any_change || return resolved
    end
    throw(TreeWalkError("E_TREEWALK_OBSERVED_CYCLE",
                        join(sort(collect(keys(obs))), ",")))
end

function _pick_tspan(tspan, model::Model)
    tspan === nothing || return (Float64(tspan[1]), Float64(tspan[2]))
    if !isempty(model.tests)
        ts = model.tests[1].time_span
        return (Float64(ts.start), Float64(ts.stop))
    end
    return (0.0, 1.0)
end

# ============================================================
# 5b. Array-variable helpers (arrayop evaluation support)
# ============================================================

# Format an array-cell key like "u[3]" (1D) or "u[2,3]" (2D).
function _cell_key(var_name::String, indices)
    return "$(var_name)[$(join(indices, ","))]"
end

const _CELL_KEY_RE = r"^([^\[]+)\[([0-9]+(?:,[0-9]+)*)\]$"

"""
    _parse_cell_key(key) -> Union{Nothing, Tuple{String, Vector{Int}}}

Inverse of [`_cell_key`](@ref): parse a flat array-cell key like `"u[3]"` or
`"u[2,3]"` into `(name, indices)` — e.g. `("u", [3])` / `("u", [2, 3])`.
Returns `nothing` when `key` is not a well-formed cell key (no bracket suffix,
empty variable name, or non-integer indices), so callers can use it both to
decode known-valid keys and to test whether a string IS a cell key. Accepts
any `AbstractString`. Shared with simulate.jl / pde_inline_tests.jl — keep the
signature stable.
"""
function _parse_cell_key(key::AbstractString)
    m = match(_CELL_KEY_RE, key)
    m === nothing && return nothing
    name = String(m.captures[1])
    indices = Int[parse(Int, s) for s in split(m.captures[2], ",")]
    return (name, indices)
end

"""
    _resolve_field_ic(target, rhs, cell, const_arrays, registered_functions) -> Float64

Resolve one grid cell's initial value for a scoped-reference / array `ic`
equation (spec §11.4.1). `cell` is the 1-based integer index tuple of the
element. Supported RHS forms, in order:

1. A LOADED FIELD — a bare reference to a `const_arrays` entry that supplies the
   initial field over the lifted grid. The cell is read directly when the field's
   rank matches the target grid; a single-element field is broadcast.
2. A BROADCAST CONSTANT — an RHS that const-folds to a scalar applied to every
   cell.
3. A COORDINATE EXPRESSION — an elementwise expression over array-producing
   `aggregate`/`makearray` nodes (e.g. `cos(pi * x_coord)` where `x_coord` is a
   grid-geometry aggregate expanded from a §9.7 template import). The expression
   is indexed at this cell ([`_index_at_cell`](@ref)) and folded through the
   standard `_resolve_indices` + `_compile` build-time machinery.

Anything else (e.g. a loaded expression the seed path cannot fold) is a hard
error, so a scoped-reference ic that cannot be resolved is never silently
dropped.
"""
function _resolve_field_ic(target::AbstractString, rhs::EarthSciAST.ASTExpr,
                           cell::Vector{Int}, const_arrays, registered_functions;
                           params::AbstractDict=_EMPTY_PARAMS)::Float64
    # (1) Loaded field supplied as a const array over the lifted grid.
    if rhs isa VarExpr && haskey(const_arrays, rhs.name)
        arr = const_arrays[rhs.name]
        if ndims(arr) == length(cell)
            return Float64(arr[cell...])
        elseif length(arr) == 1
            return Float64(first(arr))
        else
            throw(TreeWalkError("E_TREEWALK_UNSUPPORTED_EQUATION",
                "ic($(target)): loaded field '$(rhs.name)' has ndims=$(ndims(arr)) " *
                "which does not match the $(length(cell))-D lifted target grid"))
        end
    end
    # (2) Broadcast constant (scalar model PARAMETERS in scope as load-time
    # constants; STATE is not — `params` carries only resolved scalar params).
    # Failures here and in (3) are fall-through attempts, not final: each error
    # is recorded and attached to the step-(4) diagnostic so the reason a form
    # was rejected is never silently swallowed.
    _errs = String[]
    try
        return Float64(evaluate_expr(rhs, params;
                                     registered_functions=registered_functions))
    catch err
        push!(_errs, "as constant: $(sprint(showerror, err))")
    end
    # (3) Coordinate expression over the grid geometry (per-cell field); model
    # parameters (e.g. a free-name geometry `x0`/`dx`) bind via `params`.
    if rhs isa OpExpr
        try
            return _eval_cellwise(rhs, cell; const_arrays=const_arrays,
                                  registered_functions=registered_functions,
                                  params=params)
        catch err
            push!(_errs, "as coordinate expression: $(sprint(showerror, err))")
        end
    end
    # (4) Unsupported RHS — a clear error, never a silent drop.
    _fld = rhs isa VarExpr ? " (no const_arrays entry named '$(rhs.name)')" : ""
    _why = isempty(_errs) ? "" : "; attempts failed — " * join(_errs, "; ")
    throw(TreeWalkError("E_TREEWALK_UNSUPPORTED_EQUATION",
        "ic($(target)): RHS is neither a loaded const-array field, a constant, " *
        "nor a per-cell coordinate expression$(_fld); supply the initial field " *
        "via const_arrays or a grid-geometry expression$(_why)"))
end

"""
    _index_at_cell(expr, idxs) -> ASTExpr

Broadcast-index an elementwise expression at the concrete 1-based cell `idxs`:
every array-PRODUCING node (`makearray`, or `aggregate`/`arrayop` with non-empty
`output_idx`) is wrapped in `index(node, idxs…)`, elementwise ops are descended,
and scalar leaves (literals, scalar names, `index` gathers, scalar reductions)
pass through. The concrete-index dual of `_index_array_leaves` (loop-name form).
"""
function _index_at_cell(expr::EarthSciAST.ASTExpr, idxs::Vector{Int})::EarthSciAST.ASTExpr
    if expr isa OpExpr
        if _is_array_producer(expr)
            idx_args = ASTExpr[expr]
            for k in idxs
                push!(idx_args, IntExpr(Int64(k)))
            end
            return OpExpr("index", idx_args)
        end
        (expr.op == "aggregate" || expr.op == "arrayop" || expr.op == "makearray" ||
         expr.op == "index") && return expr
        return reconstruct(expr; args=ASTExpr[_index_at_cell(a, idxs) for a in expr.args])
    end
    return expr
end

# Evaluate an elementwise-over-arrays expression at one concrete cell through
# the standard build-time pipeline (_index_at_cell → _resolve_indices → _compile
# → _eval_node). STATE references are not in scope — this is for build-time
# fields (grid geometry, §6.6.5 analytic references), never for RHS terms.
# Model PARAMETERS (load-time constants) supplied via `params` (name → value)
# ARE in scope: their names bind to their resolved values, so a
# parameter-dependent coordinate expression / observed / reference resolves
# (esm-spec §6.6.5). Binding them widens only what NAMES resolve, never how a
# value is computed — determinism and byte-identical output are preserved.
function _eval_cellwise(expr::EarthSciAST.ASTExpr, cell::Vector{Int};
                        const_arrays::AbstractDict=_EMPTY_CONST_ARRAYS,
                        registered_functions::AbstractDict=Dict{String,Function}(),
                        params::AbstractDict=_EMPTY_PARAMS)::Float64
    cellwise = _index_at_cell(expr, cell)
    resolved = _resolve_indices(cellwise,
                                Dict{String,Tuple{Vector{Int},Vector{Int}}}(),
                                Dict{String,Int}(), const_arrays)
    reg = Dict{String,Any}(String(k) => v for (k, v) in registered_functions)
    if isempty(params)
        node = _compile(resolved, Dict{String,Int}(), Set{Symbol}(), reg)
        return _eval_node(node, Float64[], NamedTuple(), 0.0)
    end
    psyms = Symbol[Symbol(k) for k in keys(params)]
    pvals = Float64[Float64(params[k]) for k in keys(params)]
    node = _compile(resolved, Dict{String,Int}(), Set{Symbol}(psyms), reg)
    p_nt = NamedTuple{Tuple(psyms)}(Tuple(pvals))
    return _eval_node(node, Float64[], p_nt, 0.0)
end

const _NO_STATE_U = Float64[]

# A field-ic RHS body is "closed form" iff it has no gather / array-producer node
# that would need per-cell index resolution — every op is scalar-computable with
# the loop indices bound as parameters. Reduction bounds / filters / table axes /
# ranges on an inner node are conservatively rejected.
function _ic_body_is_closed_form(e)::Bool
    e isa OpExpr || return true
    (e.op == "index" || e.op == "makearray" || e.op == "aggregate" ||
     e.op == "arrayop") && return false
    _is_array_producer(e) && return false
    (e.lower !== nothing || e.upper !== nothing || e.filter !== nothing ||
     e.key !== nothing || e.table_axes !== nothing || e.ranges !== nothing) && return false
    for a in e.args
        _ic_body_is_closed_form(a) || return false
    end
    e.expr_body !== nothing && (_ic_body_is_closed_form(e.expr_body::ASTExpr) || return false)
    if e.values !== nothing
        for v in e.values
            _ic_body_is_closed_form(v) || return false
        end
    end
    return true
end

# Compile-once fast path for a coordinate-field ic: an `aggregate`/`arrayop` over
# the output loop indices whose body is pure closed-form (see above). The body is
# compiled a SINGLE time with the loop indices bound as parameters; each cell then
# only rebinds the index values and re-evaluates — replacing the per-cell
# `_index_at_cell → _resolve_indices → _compile` rebuild that dominated
# `_resolve_field_ic` for large grids. Result is bit-identical to the per-cell
# path: `_eval_node` computes every leaf in `Float64`, so a loop index bound as a
# `Float64` param equals that index folded to a `Float64` literal. Returns a
# `(cell) -> Float64` closure, or `nothing` to signal the per-cell fallback.
function _try_field_ic_fastpath(rhs, params::AbstractDict,
                                registered_functions, const_arrays)
    rhs isa OpExpr || return nothing
    (rhs.op == "aggregate" || rhs.op == "arrayop") || return nothing
    (rhs.join_gates === nothing && rhs.filter === nothing) || return nothing
    body = rhs.expr_body
    body === nothing && return nothing
    oi_raw = rhs.output_idx === nothing ? Any[] : rhs.output_idx
    all(s -> s isa AbstractString, oi_raw) || return nothing
    oi = String[String(s) for s in oi_raw]
    isempty(oi) && return nothing
    # Non-contracting: every declared range index is an output index (a contracted
    # index would need reduction, not a single per-cell value).
    ranges = rhs.ranges === nothing ? Dict{String,Any}() : rhs.ranges
    all(n -> n in oi, keys(ranges)) || return nothing
    # A loop index must not collide with a scalar-param name or the time symbol.
    for nm in oi
        (nm == "t" || haskey(params, nm)) && return nothing
    end
    _ic_body_is_closed_form(body) || return nothing

    reg = Dict{String,Any}(String(k) => v for (k, v) in registered_functions)
    pkeys = collect(keys(params))
    psyms = Symbol[Symbol(k) for k in pkeys]
    for nm in oi
        push!(psyms, Symbol(nm))
    end
    node = try
        _compile(body, Dict{String,Int}(), Set{Symbol}(psyms), reg)
    catch
        return nothing   # anything the closed-form guard missed → per-cell fallback
    end
    pbase = Float64[Float64(params[k]) for k in pkeys]
    npar = length(pbase)
    nidx = length(oi)
    symtup = Tuple(psyms)
    return function (cell::AbstractVector{<:Integer})
        length(cell) == nidx || throw(TreeWalkError("E_TREEWALK_UNSUPPORTED_EQUATION",
            "field-ic fast path: cell rank $(length(cell)) ≠ output rank $nidx"))
        vals = Vector{Float64}(undef, npar + nidx)
        @inbounds for d in 1:npar
            vals[d] = pbase[d]
        end
        @inbounds for d in 1:nidx
            vals[npar + d] = Float64(cell[d])
        end
        p_nt = NamedTuple{symtup}(Tuple(vals))
        return _eval_node(node, _NO_STATE_U, p_nt, 0.0)
    end
end

# Expand a ranges entry to the concrete list of integer values.
# `r` is [lo, hi] or [lo, step, hi] (elements may be Int or Any, but must all
# be concrete integers — expression-valued bounds are not supported by the
# tree-walk evaluator).
function _expand_int_range(r::AbstractVector)
    all(x -> x isa Integer, r) || throw(TreeWalkError("E_TREEWALK_DYNAMIC_RANGE",
        "expression-valued range bounds are not supported in the tree-walk " *
        "evaluator; use a structured-grid discretization or ESD build_evaluator"))
    length(r) == 2 && return Int(r[1]):Int(r[2])
    length(r) == 3 && return Int(r[1]):Int(r[2]):Int(r[3])
    throw(TreeWalkError("E_TREEWALK_RANGE_ARITY",
          "range entry must have 2 or 3 entries, got $(length(r))"))
end

# True iff every element of a range spec is already a concrete Integer — i.e.
# the range can be expanded once, globally, with `_expand_int_range` (the
# constant-bound fast path used by structured grids and the Route-B padded
# unstructured form).
_is_const_int_range(r::AbstractVector) = all(x -> x isa Integer, r)

# Expand a ranges entry whose bounds may be *expression-valued* (e.g. a
# per-cell reduction bound `index(n_edges_on_cell, i) - 1`).  Each non-Integer
# element is evaluated to a concrete Int via `_eval_const_int` under the current
# output-cell binding `idx_env` and the model's `const_arrays` — exactly the
# primitive already used to resolve indirect neighbour gathers.  This realizes a
# variable-valence / ragged segment reduction with NO host-side padding: the
# upper bound is each cell's true valence, evaluated lazily per output cell.
# Integer elements pass through unchanged, so a fully-constant range gives the
# same result as `_expand_int_range` (backward compatible).
function _expand_int_range_dyn(r::AbstractVector, idx_env::Dict{String,Int},
                               const_arrays::AbstractDict)
    bnd(x) = x isa Integer ? Int(x) : _eval_const_int(x, idx_env, const_arrays)
    length(r) == 2 && return bnd(r[1]):bnd(r[2])
    length(r) == 3 && return bnd(r[1]):bnd(r[2]):bnd(r[3])
    throw(TreeWalkError("E_TREEWALK_RANGE_ARITY",
          "range entry must have 2 or 3 entries, got $(length(r))"))
end

# Evaluate a purely-arithmetic expression (literals + idx_env bindings + const_array
# lookups) to a concrete Int. Used to resolve index(u, i+1) after loop-var
# substitution, and for indirect gather: u[index(conn, c, k)] where conn is a
# 2D const_array holding neighbor indices.
function _eval_const_int(expr::NumExpr, idx_env::Dict{String,Int},
                          const_arrays::AbstractDict=_EMPTY_CONST_ARRAYS)
    return Int(expr.value)
end
function _eval_const_int(expr::IntExpr, idx_env::Dict{String,Int},
                          const_arrays::AbstractDict=_EMPTY_CONST_ARRAYS)
    return expr.value
end
function _eval_const_int(expr::VarExpr, idx_env::Dict{String,Int},
                          const_arrays::AbstractDict=_EMPTY_CONST_ARRAYS)
    haskey(idx_env, expr.name) ||
        throw(TreeWalkError("E_TREEWALK_UNBOUND_LOOP_VAR", expr.name))
    return idx_env[expr.name]
end
function _eval_const_int(expr::OpExpr, idx_env::Dict{String,Int},
                          const_arrays::AbstractDict=_EMPTY_CONST_ARRAYS)
    op = expr.op
    c = expr.args
    if op == "+"
        return sum(_eval_const_int(a, idx_env, const_arrays) for a in c)
    elseif op == "-"
        length(c) == 1 && return -_eval_const_int(c[1], idx_env, const_arrays)
        length(c) == 2 || throw(TreeWalkError("E_TREEWALK_ARITY", "- in index needs 1-2 args"))
        return _eval_const_int(c[1], idx_env, const_arrays) - _eval_const_int(c[2], idx_env, const_arrays)
    elseif op == "*"
        return prod(_eval_const_int(a, idx_env, const_arrays) for a in c)
    elseif op == "/"
        length(c) == 2 || throw(TreeWalkError("E_TREEWALK_ARITY", "/ in index needs 2 args"))
        return div(_eval_const_int(c[1], idx_env, const_arrays), _eval_const_int(c[2], idx_env, const_arrays))
    elseif op == "floor"
        # `floor` in an index position wraps an already-integer subexpression (the
        # `/` case above is truncating integer `div`, == `floor` for the
        # non-negative cell subscripts a loader reindex forms). So it is a
        # pass-through here, matching the build-once `_geo_eval` path where
        # `floor((c-1)/GX)` folds to the same integer. Keeping it lets a loader
        # reindex `F[c] = F_raw[floor((c-1)/GX)+1, …]` resolve on the LIVE gather
        # path (a discrete-cadence loader field), not only build-once.
        length(c) == 1 || throw(TreeWalkError("E_TREEWALK_ARITY", "floor in index needs 1 arg"))
        return _eval_const_int(c[1], idx_env, const_arrays)
    elseif op == "mod"
        length(c) == 2 || throw(TreeWalkError("E_TREEWALK_ARITY", "mod in index needs 2 args"))
        return mod(_eval_const_int(c[1], idx_env, const_arrays), _eval_const_int(c[2], idx_env, const_arrays))
    elseif op == "max"
        # `max`/`min` in an index position are integer index-CLAMP ops (e.g. a
        # boundary-clamped subscript `max(1, i-1)` / `min(N, i+1)`, or a clamp
        # nested in a flattened linear index). Their operands are the same
        # const-foldable integer index arithmetic as the `+`/`-`/`*` cases, so
        # fold them the same way. (The `*`/`+` reductions above can descend into a
        # `max`/`min` sub-expression of a computed index; without these branches
        # that descent hit the catch-all throw below.)
        isempty(c) && throw(TreeWalkError("E_TREEWALK_ARITY", "max in index needs >=1 arg"))
        return maximum(_eval_const_int(a, idx_env, const_arrays) for a in c)
    elseif op == "min"
        isempty(c) && throw(TreeWalkError("E_TREEWALK_ARITY", "min in index needs >=1 arg"))
        return minimum(_eval_const_int(a, idx_env, const_arrays) for a in c)
    elseif op == "ifelse"
        length(c) == 3 || throw(TreeWalkError("E_TREEWALK_ARITY", "ifelse in index needs 3 args"))
        cond = _eval_const_int(c[1], idx_env, const_arrays)
        return cond != 0 ? _eval_const_int(c[2], idx_env, const_arrays) : _eval_const_int(c[3], idx_env, const_arrays)
    elseif op == "<"
        length(c) == 2 || throw(TreeWalkError("E_TREEWALK_ARITY", "< needs 2 args"))
        return _eval_const_int(c[1], idx_env, const_arrays) < _eval_const_int(c[2], idx_env, const_arrays) ? 1 : 0
    elseif op == "<="
        length(c) == 2 || throw(TreeWalkError("E_TREEWALK_ARITY", "<= needs 2 args"))
        return _eval_const_int(c[1], idx_env, const_arrays) <= _eval_const_int(c[2], idx_env, const_arrays) ? 1 : 0
    elseif op == ">"
        length(c) == 2 || throw(TreeWalkError("E_TREEWALK_ARITY", "> needs 2 args"))
        return _eval_const_int(c[1], idx_env, const_arrays) > _eval_const_int(c[2], idx_env, const_arrays) ? 1 : 0
    elseif op == ">="
        length(c) == 2 || throw(TreeWalkError("E_TREEWALK_ARITY", ">= needs 2 args"))
        return _eval_const_int(c[1], idx_env, const_arrays) >= _eval_const_int(c[2], idx_env, const_arrays) ? 1 : 0
    elseif op == "=="
        length(c) == 2 || throw(TreeWalkError("E_TREEWALK_ARITY", "== needs 2 args"))
        return _eval_const_int(c[1], idx_env, const_arrays) == _eval_const_int(c[2], idx_env, const_arrays) ? 1 : 0
    elseif op == "neg"
        length(c) == 1 || throw(TreeWalkError("E_TREEWALK_ARITY", "neg needs 1 arg"))
        return -_eval_const_int(c[1], idx_env, const_arrays)
    elseif op == "index"
        # Indirect gather: index(const_array_name, i1, i2, ...) → Int
        # Used for mesh connectivity: u[index(cells_on_cell, c, k)] resolves the
        # neighbor index from a pre-computed connectivity array.
        isempty(c) && throw(TreeWalkError("E_TREEWALK_INDEX_EMPTY",
                                           "index op in index position requires at least one arg"))
        first = c[1]
        first isa VarExpr ||
            throw(TreeWalkError("E_TREEWALK_INDEX_NOT_CONST",
                "index op in index position: first arg must be a variable name"))
        haskey(const_arrays, first.name) ||
            throw(TreeWalkError("E_TREEWALK_INDEX_NOT_CONST",
                "non-const array '$(first.name)' used in index position; " *
                "add it to const_arrays or use a state-variable index"))
        arr = const_arrays[first.name]
        idx_args = c[2:end]
        length(idx_args) == ndims(arr) ||
            throw(TreeWalkError("E_TREEWALK_INDEX_NOT_CONST",
                "const array '$(first.name)' is $(ndims(arr))D but got $(length(idx_args)) indices"))
        int_indices = [_eval_const_int(a, idx_env, const_arrays) for a in idx_args]
        for d in 1:ndims(arr)
            int_indices[d] = _resolve_const_index(arr, first.name, d, int_indices[d], size(arr, d))
        end
        return Int(round(arr[int_indices...]))
    end
    throw(TreeWalkError("E_TREEWALK_INDEX_NOT_CONST",
          "cannot evaluate '$(op)' as a constant integer index"))
end
