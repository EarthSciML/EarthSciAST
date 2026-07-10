module EarthSciASTMTKExt

using EarthSciAST
# Note: we deliberately do NOT import `Expr` from EarthSciAST into
# this extension's namespace — that would shadow Core.Expr and break the
# `Symbolics.@variables` macro call we use for programmatic variable creation
# (the macro's generated code references Core.Expr).
using EarthSciAST: FlattenedSystem, ModelVariable, StateVariable,
    ParameterVariable, ObservedVariable, BrownianVariable,
    NumExpr, IntExpr, VarExpr, OpExpr,
    Equation, AffectEquation, Model, EventType, ContinuousEvent, DiscreteEvent,
    ConditionTrigger, PeriodicTrigger, PresetTimesTrigger, FunctionalAffect,
    Domain, flatten, infer_array_shapes,
    GapReport, Metadata, EsmFile,
    # MTK-independent export helpers shared with the Catalyst extension
    # (defined next to GapReport in src/mtk_export.jl).
    _strip_time, _meta_string, _meta_vec_string, _gap_to_note,
    _reference_notes, _esm_file_metadata, _warn_gaps
# Explicit import so we can add methods to these generics.
import EarthSciAST: mtk2esm, mtk2esm_gaps
const EsmExpr = EarthSciAST.Expr
using ModelingToolkit
using ModelingToolkit: @variables, @parameters, Differential, System, PDESystem
using Symbolics
using Symbolics: Num
# SymbolicUtils ships inside Symbolics (via @reexport); access the module
# through Symbolics.SymbolicUtils so we don't need to declare a separate
# weak dep in Project.toml. Alias it locally for readability.
const SymUtils = Symbolics.SymbolicUtils
using DomainSets: Interval

# ArrayOp construction primitives for the `arrayop` → Symbolics lowering path.
# Relocated here from the former ext/grid_assembly_symbolic.jl when the dead
# covariant-FV stencil assembly was retired (ess-4g1): that file (and its
# numeric counterpart src/grid_assembly.jl) is gone, but these three
# primitives stay load-bearing for the live `arrayop` node lowering — see the
# ConstSR / get_idx_vars / SymReal uses below.
const SymReal = SymUtils.SymReal
const ConstSR = SymUtils.Const{SymReal}

"""
    get_idx_vars(ndim) -> Vector

`ndim` symbolic integer index variables drawn from the shared ArrayOp index
pool (`SymbolicUtils.idxs_for_arrayop(SymReal)`), so indices interoperate
cleanly when ArrayOps are composed.
"""
function get_idx_vars(ndim::Int)
    idxs_arr = SymUtils.idxs_for_arrayop(SymReal)
    return [idxs_arr[d] for d in 1:ndim]
end

# ========================================
# ESM Expr → Symbolics conversion
# ========================================

"""
Build a Symbolics.jl expression from an ESM `Expr` tree, using the given
variable dictionary (name → symbolic variable) and the time symbol `t_sym`.
Spatial dimension symbols are created on demand and cached in `dim_dict`.
"""
function _esm_to_symbolic(expr::EsmExpr, var_dict::Dict{String,Any},
                          t_sym, dim_dict::Dict{String,Any})
    if expr isa IntExpr
        return expr.value
    elseif expr isa NumExpr
        # Integer-valued NumExpr is promoted to Int so arrayop index
        # expressions like `i - 1` stay integer-typed when fixtures
        # still encode whole numbers as NumExpr. Floats above Int64 range
        # (e.g. Avogadro's number 6.022e23) stay Float64 — Int(x) on them
        # raises InexactError.
        v = expr.value
        if isfinite(v) && v == floor(v) && typemin(Int) <= v <= typemax(Int)
            return Int(v)
        else
            return v
        end
    elseif expr isa VarExpr
        if haskey(var_dict, expr.name)
            return var_dict[expr.name]
        elseif haskey(dim_dict, expr.name)
            return dim_dict[expr.name]
        else
            throw(ArgumentError("Variable '$(expr.name)' not found in variable dictionary"))
        end
    elseif expr isa OpExpr
        op = expr.op
        if op == "D"
            arg = _esm_to_symbolic(expr.args[1], var_dict, t_sym, dim_dict)
            wrt_name = expr.wrt === nothing ? "t" : expr.wrt
            if wrt_name == "t"
                return Differential(t_sym)(arg)
            else
                dim_sym = _get_or_make_dim(dim_dict, wrt_name)
                return Differential(dim_sym)(arg)
            end
        elseif op == "grad"
            arg = _esm_to_symbolic(expr.args[1], var_dict, t_sym, dim_dict)
            expr.dim === nothing && throw(ArgumentError("grad operator requires dim parameter"))
            dim_sym = _get_or_make_dim(dim_dict, expr.dim)
            return Differential(dim_sym)(arg)
        elseif op == "div"
            arg = _esm_to_symbolic(expr.args[1], var_dict, t_sym, dim_dict)
            expr.dim === nothing && throw(ArgumentError("div operator requires dim parameter"))
            dim_sym = _get_or_make_dim(dim_dict, expr.dim)
            return Differential(dim_sym)(arg)
        elseif op == "laplacian"
            arg = _esm_to_symbolic(expr.args[1], var_dict, t_sym, dim_dict)
            x_sym = _get_or_make_dim(dim_dict, "x")
            y_sym = _get_or_make_dim(dim_dict, "y")
            z_sym = _get_or_make_dim(dim_dict, "z")
            Dx = Differential(x_sym)
            Dy = Differential(y_sym)
            Dz = Differential(z_sym)
            return Dx(Dx(arg)) + Dy(Dy(arg)) + Dz(Dz(arg))
        elseif op == "+"
            args = [_esm_to_symbolic(a, var_dict, t_sym, dim_dict) for a in expr.args]
            return length(args) == 1 ? args[1] : sum(args)
        elseif op == "-"
            args = [_esm_to_symbolic(a, var_dict, t_sym, dim_dict) for a in expr.args]
            return length(args) == 1 ? -args[1] : args[1] - args[2]
        elseif op == "*"
            args = [_esm_to_symbolic(a, var_dict, t_sym, dim_dict) for a in expr.args]
            return length(args) == 1 ? args[1] : prod(args)
        elseif op == "/"
            l = _esm_to_symbolic(expr.args[1], var_dict, t_sym, dim_dict)
            r = _esm_to_symbolic(expr.args[2], var_dict, t_sym, dim_dict)
            return l / r
        elseif op == "^"
            l = _esm_to_symbolic(expr.args[1], var_dict, t_sym, dim_dict)
            r = _esm_to_symbolic(expr.args[2], var_dict, t_sym, dim_dict)
            return l^r
        elseif op in ("exp", "log", "log10", "sin", "cos", "tan",
                      "sinh", "cosh", "tanh", "asin", "acos", "atan",
                      "sqrt", "abs")
            arg = _esm_to_symbolic(expr.args[1], var_dict, t_sym, dim_dict)
            fn = getfield(Base, Symbol(op))
            return fn(arg)
        elseif op == "min" || op == "max"
            length(expr.args) < 2 && throw(ArgumentError("$op requires at least 2 arguments (esm-spec §4.2)"))
            args = [_esm_to_symbolic(a, var_dict, t_sym, dim_dict) for a in expr.args]
            fn = op == "min" ? min : max
            return foldl(fn, args)
        elseif op == "ifelse"
            cond = _esm_to_symbolic(expr.args[1], var_dict, t_sym, dim_dict)
            t_val = _esm_to_symbolic(expr.args[2], var_dict, t_sym, dim_dict)
            f_val = _esm_to_symbolic(expr.args[3], var_dict, t_sym, dim_dict)
            return ifelse(cond, t_val, f_val)
        elseif op == "Pre"
            arg = _esm_to_symbolic(expr.args[1], var_dict, t_sym, dim_dict)
            return ModelingToolkit.Pre(arg)
        elseif op in (">", "<", ">=", "<=", "==", "!=")
            l = _esm_to_symbolic(expr.args[1], var_dict, t_sym, dim_dict)
            r = _esm_to_symbolic(expr.args[2], var_dict, t_sym, dim_dict)
            return op == ">"  ? l > r  :
                   op == "<"  ? l < r  :
                   op == ">=" ? l >= r :
                   op == "<=" ? l <= r :
                   op == "==" ? l == r :
                                l != r
        elseif op == "arrayop" || op == "aggregate"
            return _build_arrayop_sym(expr, var_dict, t_sym, dim_dict)
        elseif op == "makearray"
            return _build_makearray(expr, var_dict, t_sym, dim_dict)
        elseif op == "index"
            return _build_index(expr, var_dict, t_sym, dim_dict)
        elseif op == "broadcast"
            return _build_broadcast(expr, var_dict, t_sym, dim_dict)
        elseif op == "reshape"
            return _build_reshape(expr, var_dict, t_sym, dim_dict)
        elseif op == "transpose"
            return _build_transpose(expr, var_dict, t_sym, dim_dict)
        elseif op == "concat"
            return _build_concat(expr, var_dict, t_sym, dim_dict)
        elseif op == "fn"
            return _build_fn(expr, var_dict, t_sym, dim_dict)
        else
            throw(ArgumentError("Unsupported operator: $op"))
        end
    end
    error("Unknown expression type: $(typeof(expr))")
end

# ========================================
# Array op dispatch helpers (gt-vt3)
# ========================================

# Map reduce-name string from the schema to the Julia reducer callable used
# by the low-level `SymbolicUtils.ArrayOp` constructor.
function _reduce_fn(name::Union{Nothing,AbstractString})
    name === nothing && return +
    return name == "+" ? (+) :
           name == "*" ? (*) :
           name == "max" ? max :
           name == "min" ? min :
           throw(ArgumentError("Unsupported arrayop reduce: $name"))
end

# ========================================
# Stencil boundary handling via numeric gather tables (ess-c59)
# ========================================
#
# Background: an arrayop body for a discretized PDE stencil reads neighbor
# cells `u[i-1, j]`, `u[i, j+1]`, ... At a Dirichlet boundary (e.g. i=1) the
# read `u[i-1, j]` resolves to `u[0, j]`, which is OUTSIDE the 1:N field and
# must take the ghost value 0. The `_build_index` ghost guard only fires for
# CONCRETE integer indices; if we baked a SYMBOLIC offset `pool[k]-1` into the
# body, the OOB index would escape to scalarize-time as `u[0, j]` and raise an
# `ArgumentError` (out of `1:N` bounds).
#
# Fix (mirrors ESD's `_stencil_arrayop` / `_build_symbolic_ghost_extension` and
# the PDE-grid `_build_ghost_vals` / `_eval_at_nb`): resolve each stencil read
# over the declared range into a NUMERIC per-cell gather table at build time.
# Each `index` read `u[i±1, …]` becomes a `Const`-wrapped N-D table whose entry
# at output cell `(c₁,…,c_M)` is the in-bounds symbolic reference `u_sym[…]`,
# or `0` for an out-of-bounds (Dirichlet ghost) cell. The body then indexes that
# Const table with the RAW 1-based pool vars, so NO symbolic index ever leaves
# `1:N` — scalarize sees only 1-based positions into a precomputed table.

# Context threaded into `_build_index` (via a reserved `dim_dict` key) while a
# stencil arrayop body is being built. Carries everything needed to materialize
# a per-output-cell gather table for an indexed read.
struct _GatherCtx
    # output index var name => (pool var, physical-index lo, length N_d)
    out_vars::Dict{String,Tuple{Any,Int,Int}}
    # ordered output var names (defines the table axis order = pool var order)
    out_order::Vector{String}
end

# SIDE CHANNEL — read this before touching `dim_dict`.
#
# The `_GatherCtx` is smuggled to `_build_index` through `dim_dict::Dict{
# String,Any}` under this reserved key rather than as an explicit argument.
# `_esm_to_symbolic` has dozens of call sites (every `_build_*` helper, the
# System/PDESystem constructors, event and slice-BC lowering), all sharing
# the `(expr, var_dict, t_sym, dim_dict)` signature; adding a context
# parameter would touch every one of them for the benefit of exactly one
# producer (`_build_arrayop_sym`) and one consumer (`_build_index`). Until
# a second consumer appears, the reserved-key hack is the lesser evil.
#
# Invariants that keep it safe:
# - `_build_arrayop_sym` installs the ctx before evaluating an arrayop body
#   and restores the previous value in a `finally` (nesting-safe).
# - `_get_or_make_dim` can never collide: the key is not a valid dimension
#   name and is only ever written by `_build_arrayop_sym`.
# - `_build_index` type-checks (`ctx isa _GatherCtx`) before use.
const _GATHER_CTX_KEY = "__esm_arrayop_gather_ctx__"

# Pure-integer evaluation of an ESM index-argument expression given concrete
# integer values for the output index vars (`binding`). Returns the resolved
# Int, or `nothing` if the expression is not resolvable to a concrete integer
# from the output vars alone (e.g. it references a reduction var, a parameter,
# or a non-affine/function term — in which case the read is NOT gather-eligible
# and the caller falls back to the symbolic-offset path).
function _eval_index_arg_int(e::EsmExpr, binding::Dict{String,Int})
    if e isa IntExpr
        return Int(e.value)
    elseif e isa NumExpr
        v = e.value
        (isfinite(v) && v == floor(v)) || return nothing
        return Int(v)
    elseif e isa VarExpr
        return get(binding, e.name, nothing)
    elseif e isa OpExpr
        if e.op == "+" || e.op == "-" || e.op == "*"
            vals = Int[]
            for a in e.args
                r = _eval_index_arg_int(a, binding)
                r === nothing && return nothing
                push!(vals, r)
            end
            isempty(vals) && return nothing
            if e.op == "+"
                return sum(vals)
            elseif e.op == "*"
                return prod(vals)
            else # "-"
                return length(vals) == 1 ? -vals[1] : foldl(-, vals)
            end
        end
        return nothing
    end
    return nothing
end

# True iff EVERY index arg of an `index` node is resolvable to a concrete
# integer from the output index vars alone (across the whole output grid).
# Such reads are handled by a numeric gather table; everything else falls back.
function _index_args_gatherable(idx_args::Vector{<:EsmExpr}, ctx::_GatherCtx)
    isempty(idx_args) && return false
    # Probe with the lower-corner physical indices; `_eval_index_arg_int`
    # returns `nothing` structurally (independent of the concrete values) when
    # a non-output symbol or unsupported op appears, so one probe suffices.
    binding = Dict{String,Int}(name => lo for (name, (_, lo, _)) in ctx.out_vars)
    for a in idx_args
        _eval_index_arg_int(a, binding) === nothing && return false
    end
    return true
end

# Build the per-output-cell gather table for a single indexed read of a shaped
# state-variable array `arr` (a `Symbolics.Arr`). `idx_args` are the ESM index
# expressions (affine in the output vars). Each entry of the returned N-D table
# is `unwrap(arr[resolved...])` for an in-bounds read or `0` for a Dirichlet
# ghost (any axis out of the array's declared bounds). The table is then
# `Const`-wrapped and indexed by the output pool vars so it scalarizes cleanly.
function _build_gather_read(arr, idx_args::Vector{<:EsmExpr}, ctx::_GatherCtx)
    sz = size(arr)                       # declared 1-based field extent, e.g. (3, 3)
    ndim_out = length(ctx.out_order)
    dims = ntuple(d -> ctx.out_vars[ctx.out_order[d]][3], ndim_out)  # (N₁, …, N_M)

    table = Array{Any}(undef, dims...)
    for cell in CartesianIndices(dims)
        # Physical index value for each output var at this cell.
        binding = Dict{String,Int}()
        for d in 1:ndim_out
            name = ctx.out_order[d]
            lo = ctx.out_vars[name][2]
            binding[name] = lo + cell[d] - 1
        end
        # Resolve each axis index of the read.
        resolved = ntuple(k -> _eval_index_arg_int(idx_args[k], binding)::Int,
                          length(idx_args))
        inbounds = length(resolved) == length(sz) &&
                   all(1 <= resolved[k] <= sz[k] for k in 1:length(resolved))
        table[cell] = inbounds ? Symbolics.unwrap(getindex(arr, resolved...)) :
                                 Symbolics.unwrap(Symbolics.Num(0))
    end

    pool_idx = Any[ctx.out_vars[ctx.out_order[d]][1] for d in 1:ndim_out]
    return Symbolics.wrap(ConstSR(table)[pool_idx...])
end

# Build an un-scalarized `Symbolics.wrap(ArrayOp)` for an ESM `arrayop` node.
# All index variables are drawn from the shared `SymbolicUtils.idxs_for_arrayop`
# pool; the body is built once with symbolic indices and handed to MTK's
# `mtkcompile` to own scalarization. This requires all output ranges to be
# 1-based (guaranteed by the ess-5kf canonicalization gate).
#
# Stencil neighbor reads that can leave the field bounds at a boundary cell are
# materialized as numeric gather tables (see `_build_gather_read` above) so no
# symbolic out-of-bounds index ever reaches the scalarizer.
function _build_arrayop_sym(expr::OpExpr, var_dict::Dict{String,Any},
                             t_sym, dim_dict::Dict{String,Any})
    output_idx = expr.output_idx === nothing ? Any[] : expr.output_idx
    body = expr.expr_body
    body === nothing && throw(ArgumentError("arrayop node missing 'expr' body"))
    reduce_fn = _reduce_fn(expr.reduce)

    expr.ranges === nothing && throw(ArgumentError(
        "arrayop without explicit 'ranges' is not supported — all index " *
        "variables must declare a concrete range"))
    ranges = Dict{String,UnitRange{Int}}()
    for (name, r) in expr.ranges
        lo, hi = _range_bounds_int(r)
        ranges[name] = lo:hi
    end

    output_names = String[]
    for entry in output_idx
        if entry isa AbstractString
            name = String(entry)
            haskey(ranges, name) || throw(ArgumentError("arrayop output index '$name' has no declared range"))
            push!(output_names, name)
        elseif entry == 1
            # Singleton axis — no iteration variable; shape 1 handled below.
        else
            throw(ArgumentError("arrayop output_idx entry must be a string or 1, got $(entry)"))
        end
    end

    # Pure scalar output (empty output_idx or all singletons): pre-scalarize
    # via integer iteration (rare path, not in current simulation fixtures).
    if isempty(output_names)
        return _arrayop_scalar_reduce(body, var_dict, t_sym, dim_dict, ranges, reduce_fn)
    end

    # Draw symbolic integer index vars from the shared pool.
    # One per named range entry (output + reduction) + one per singleton axis.
    n_singletons = count(==(1), output_idx)
    all_named = collect(keys(ranges))
    n_named = length(all_named)
    pool = get_idx_vars(n_named + n_singletons)
    # idx_sym: raw pool vars, used as keys in output_idx_syms and ranges_sym.
    # idx_body: offset-adjusted vars injected into var_dict for body evaluation.
    # SymbolicUtils scalarizes by iterating the shape (1:length(r)) and
    # substituting pool[k] = 1..N. For non-1-based ranges (e.g. i ∈ 2:4),
    # we inject pool[k] + offset into the body so that when pool[k] = 1..3
    # the body sees 2..4 (the actual physical indices).
    idx_sym = Dict{String,Any}()
    idx_body = Dict{String,Any}()
    for (k, name) in enumerate(all_named)
        r = ranges[name]
        idx_sym[name] = pool[k]
        offset = first(r) - 1
        # Use pool[k] directly (BasicSymbolic{SymReal}), not Symbolics.wrap(pool[k])
        # (Num), so that u[idx_body[i], idx_body[j]] dispatches correctly.
        idx_body[name] = offset == 0 ? pool[k] : pool[k] + offset
    end
    singleton_vars = [pool[n_named + s] for s in 1:n_singletons]

    # Build the gather context for the OUTPUT index vars. Stencil reads whose
    # indices are affine in these (and so resolvable to a concrete cell index)
    # are materialized as numeric gather tables inside `_build_index`, which
    # keeps boundary/ghost reads within `1:N`. Reads referencing reduction-only
    # index vars are not gatherable and fall back to the symbolic-offset path
    # below (correct for in-bounds contractions, which was already passing).
    out_vars = Dict{String,Tuple{Any,Int,Int}}()
    out_order = String[]
    for entry in output_idx
        entry isa AbstractString || continue
        name = String(entry)
        r = ranges[name]
        out_vars[name] = (pool[findfirst(==(name), all_named)], first(r), length(r))
        push!(out_order, name)
    end
    gather_ctx = _GatherCtx(out_vars, out_order)

    # Inject OFFSET-ADJUSTED index vars into var_dict and evaluate the body.
    # Also install the gather context so `_build_index` can intercept
    # gather-eligible reads. Both are restored in the `finally`.
    saved = Dict{String,Any}()
    for (k, v) in idx_body
        if haskey(var_dict, k); saved[k] = var_dict[k]; end
        var_dict[k] = v
    end
    saved_ctx = get(dim_dict, _GATHER_CTX_KEY, nothing)
    dim_dict[_GATHER_CTX_KEY] = gather_ctx
    body_sym = try
        _esm_to_symbolic(body, var_dict, t_sym, dim_dict)
    finally
        for k in keys(idx_body)
            if haskey(saved, k); var_dict[k] = saved[k]; else; delete!(var_dict, k); end
        end
        if saved_ctx === nothing
            delete!(dim_dict, _GATHER_CTX_KEY)
        else
            dim_dict[_GATHER_CTX_KEY] = saved_ctx
        end
    end

    # Assemble output index symbol list using RAW pool vars (not offset-adjusted),
    # interleaving named and singleton vars.
    output_idx_syms = Any[]
    s_i = 0
    for entry in output_idx
        if entry isa AbstractString
            push!(output_idx_syms, idx_sym[String(entry)])
        else
            s_i += 1
            push!(output_idx_syms, singleton_vars[s_i])
        end
    end

    # Ranges dict keyed by RAW pool vars, all 1-based (shape = 1:length(r)).
    # The body uses idx_body (offset-adjusted) so physical index values are correct.
    ranges_sym = Dict{Any,Any}()
    for (name, r) in ranges
        ranges_sym[idx_sym[name]] = StepRange(1, 1, length(r))
    end
    for sv in singleton_vars
        ranges_sym[sv] = StepRange(1, 1, 1)
    end

    body_unwrapped = Symbolics.unwrap(body_sym)
    # arrayop_shape requires a BasicSymbolic; wrap numeric constants (e.g. literal
    # Dirichlet BC bodies like `0.0`) so ArrayOp construction doesn't MethodError.
    if !(body_unwrapped isa SymUtils.BasicSymbolic)
        body_unwrapped = ConstSR(body_unwrapped)
    end
    arr_op = SymUtils.ArrayOp{SymReal}(output_idx_syms, body_unwrapped,
        reduce_fn, nothing, ranges_sym)
    return Symbolics.wrap(arr_op)
end

# Scalar-output fallback: iterate all ranges and reduce. Used only when
# output_idx is empty or all-singleton (no named output dimensions).
function _arrayop_scalar_reduce(body, var_dict, t_sym, dim_dict, ranges, reduce_fn)
    all_names = collect(keys(ranges))
    range_tuple = Tuple(ranges[n] for n in all_names)
    acc = nothing
    for vals in Iterators.product(range_tuple...)
        saved = Dict{String,Any}()
        for (k, v) in zip(all_names, vals)
            if haskey(var_dict, k); saved[k] = var_dict[k]; end
            var_dict[k] = Int(v)
        end
        contrib = try
            _esm_to_symbolic(body, var_dict, t_sym, dim_dict)
        finally
            for k in all_names
                if haskey(saved, k); var_dict[k] = saved[k]; else; delete!(var_dict, k); end
            end
        end
        acc = acc === nothing ? contrib : reduce_fn(acc, contrib)
    end
    return acc === nothing ? Symbolics.Num(0) : acc
end

# Compute the authoritative shape for array state variables by taking the
# union of all LHS-defined cell ranges across equations. This correctly
# handles both full-domain periodic stencils (where ghost-cell body accesses
# would otherwise cause infer_array_shapes to widen beyond the real grid)
# and interior-only stencils with separate scalar boundary equations.
#
# Three LHS forms are recognized:
#   1. arrayop  — output_idx+ranges give a rectangular region
#   2. D(u[k])  — scalar differential with a concrete integer index
#   3. index(u, k1, k2, ...) — direct indexed LHS
#
# The resulting shape is the union of all such contributions per variable.
function _lhs_arrayop_shapes(equations::Vector{Equation})
    shapes = Dict{String,Vector{UnitRange{Int}}}()
    for eq in equations
        lhs = eq.lhs
        lhs isa OpExpr || continue
        if lhs.op == "arrayop" || lhs.op == "aggregate"
            lhs.ranges === nothing && continue
            lhs.output_idx === nothing && continue
            isempty(lhs.output_idx) && continue
            body = lhs.expr_body
            body isa OpExpr || continue
            vname = if body.op == "D" && !isempty(body.args)
                inner = body.args[1]
                (inner isa OpExpr && inner.op == "index" &&
                 !isempty(inner.args) && inner.args[1] isa VarExpr) ?
                    inner.args[1].name : nothing
            elseif body.op == "index"
                (!isempty(body.args) && body.args[1] isa VarExpr) ?
                    body.args[1].name : nothing
            else
                nothing
            end
            vname === nothing && continue
            axis_ranges = UnitRange{Int}[]
            all_found = true
            for entry in lhs.output_idx
                entry isa AbstractString || continue
                r = get(lhs.ranges, String(entry), nothing)
                if r === nothing; all_found = false; break; end
                lo, hi = _range_bounds_int(r)
                push!(axis_ranges, lo:hi)
            end
            (!all_found || isempty(axis_ranges)) && continue
            _merge_lhs_shape!(shapes, vname, axis_ranges)
        elseif lhs.op == "D" && !isempty(lhs.args)
            # Scalar D(u[k], t): concrete integer index for boundary cells
            inner = lhs.args[1]
            inner isa OpExpr && inner.op == "index" || continue
            !isempty(inner.args) && inner.args[1] isa VarExpr || continue
            vname = inner.args[1].name
            axis_ranges = UnitRange{Int}[]
            ok = true
            for a in inner.args[2:end]
                v = a isa IntExpr ? Int(a.value) :
                    (a isa NumExpr && isinteger(a.value)) ? Int(a.value) :
                    (ok = false; break; 0)
                push!(axis_ranges, v:v)
            end
            (ok && !isempty(axis_ranges)) || continue
            _merge_lhs_shape!(shapes, vname, axis_ranges)
        elseif lhs.op == "index"
            # Direct indexed LHS: u[k1, k2, ...] = ...
            !isempty(lhs.args) && lhs.args[1] isa VarExpr || continue
            vname = lhs.args[1].name
            axis_ranges = UnitRange{Int}[]
            ok = true
            for a in lhs.args[2:end]
                v = a isa IntExpr ? Int(a.value) :
                    (a isa NumExpr && isinteger(a.value)) ? Int(a.value) :
                    (ok = false; break; 0)
                push!(axis_ranges, v:v)
            end
            (ok && !isempty(axis_ranges)) || continue
            _merge_lhs_shape!(shapes, vname, axis_ranges)
        end
    end
    return shapes
end

function _merge_lhs_shape!(shapes::Dict{String,Vector{UnitRange{Int}}},
                            vname::String, axis_ranges::Vector{UnitRange{Int}})
    if haskey(shapes, vname)
        ex = shapes[vname]
        length(ex) == length(axis_ranges) || return
        for (d, r) in enumerate(axis_ranges)
            ex[d] = min(first(ex[d]), first(r)):max(last(ex[d]), last(r))
        end
    else
        shapes[vname] = copy(axis_ranges)
    end
end

# Decode a range field `[lo, hi]` or `[lo, step, hi]` to integer bounds.
function _range_bounds_int(r::AbstractVector)
    all(x -> x isa Integer, r) || throw(ArgumentError(
        "expression-valued range bounds are not supported by the MTK evaluator path"))
    if length(r) == 2
        return Int(r[1]), Int(r[2])
    elseif length(r) == 3
        return Int(r[1]), Int(r[3])
    end
    throw(ArgumentError("range must have 2 or 3 entries, got $(length(r))"))
end

# Walk an ESM expression tree looking for any spatial differential operator
# (`grad`/`div`/`laplacian`). Returns the offending op name on the first
# match, or `nothing` if none is present. Used by the ODE-path
# `ModelingToolkit.System` constructor to enforce the canonical pipeline
# contract (esm-i7b).
function _find_spatial_op(expr::EsmExpr)::Union{String,Nothing}
    if expr isa OpExpr
        if expr.op == "grad" || expr.op == "div" || expr.op == "laplacian"
            return expr.op
        end
        for a in expr.args
            hit = _find_spatial_op(a)
            hit === nothing || return hit
        end
        if expr.expr_body !== nothing
            hit = _find_spatial_op(expr.expr_body)
            hit === nothing || return hit
        end
        if expr.values !== nothing
            for v in expr.values
                hit = _find_spatial_op(v)
                hit === nothing || return hit
            end
        end
    end
    return nothing
end

# Build a native `Array{Num}` from a `makearray` node. We construct the
# output array directly rather than going through `SymbolicUtils.ArrayMaker`,
# whose public binding disappeared in the Symbolics v7 / SymbolicUtils v4
# rewrite (the type moved to `BSImpl.ArrayMaker` with a different
# constructor; `Symbolics.ArrayMaker` is not exported and absent from the
# Symbolics public API as of Symbolics 7.25.0 — empirically verified).
#
# Regions are 1-based and may overlap; later regions in the sequence
# override earlier ones, matching both the schema contract and the
# `@makearray` runtime semantics. Each region's value is currently a
# scalar expression that is broadcast across the region; array-valued
# region fills (not used by any fixture) would need additional handling.
function _build_makearray(expr::OpExpr, var_dict::Dict{String,Any},
                          t_sym, dim_dict::Dict{String,Any})
    expr.regions === nothing && throw(ArgumentError("makearray node missing 'regions'"))
    expr.values === nothing && throw(ArgumentError("makearray node missing 'values'"))
    length(expr.regions) == length(expr.values) ||
        throw(ArgumentError("makearray regions and values length mismatch"))

    nd = length(expr.regions[1])
    sz = fill(0, nd)
    for region in expr.regions
        length(region) == nd || throw(ArgumentError("makearray regions must all share ndims"))
        for (axis, pair) in enumerate(region)
            pair[1] >= 1 || throw(ArgumentError("makearray regions must be 1-based"))
            sz[axis] = max(sz[axis], pair[2])
        end
    end

    result = Array{Symbolics.Num}(undef, sz...)
    fill!(result, Symbolics.Num(0))
    for (region, val_expr) in zip(expr.regions, expr.values)
        v = _esm_to_symbolic(val_expr, var_dict, t_sym, dim_dict)
        v_num = v isa Symbolics.Num ? v : Symbolics.Num(v)
        region_axes = Tuple(pair[1]:pair[2] for pair in region)
        for idx in Iterators.product(region_axes...)
            result[idx...] = v_num
        end
    end
    return result
end

# Build an `index` node: `args[1]` is the array-shaped operand, `args[2:]`
# are the index expressions.
#
# Ghost-cell / Dirichlet-BC semantics: when all indices are concrete integers
# and any falls outside the declared array bounds (< 1 or > size(arr, d)),
# the stencil access is on a ghost cell whose value is fixed at zero. This
# handles boundary cells in arrayops like the 2D heat stencil where `u[0,j]`
# or `u[N+1,j]` reference cells outside the interior domain. The underlying
# Symbolics.Arr is 1-based and would raise BoundsError without this guard.
# Out-of-bounds periodic reads return 0 (zero-ghost convention).
function _build_index(expr::OpExpr, var_dict::Dict{String,Any},
                      t_sym, dim_dict::Dict{String,Any})
    arr = _esm_to_symbolic(expr.args[1], var_dict, t_sym, dim_dict)
    idx_args = expr.args[2:end]

    # Stencil gather path (ess-c59): inside a stencil arrayop body, when this
    # read's indices are all affine in the output index vars, materialize a
    # numeric per-cell gather table instead of emitting a symbolic index. This
    # keeps boundary reads (e.g. u[i-1, j] at i=1 -> Dirichlet ghost 0) within
    # the 1:N field, so the scalarizer never sees an out-of-bounds index.
    ctx = get(dim_dict, _GATHER_CTX_KEY, nothing)
    if ctx isa _GatherCtx && arr isa AbstractArray && !isempty(idx_args) &&
       _index_args_gatherable(idx_args, ctx)
        return _build_gather_read(arr, idx_args, ctx)
    end

    idxs = Any[]
    for a in idx_args
        if a isa IntExpr
            push!(idxs, Int(a.value))
        elseif a isa NumExpr
            # Fixtures sometimes encode whole-number indices as floats;
            # anything fractional is a malformed index, so fail with a
            # descriptive error instead of an InexactError from Int().
            isinteger(a.value) || throw(ArgumentError(
                "index argument must be an integer, got $(a.value)"))
            push!(idxs, Int(a.value))
        else
            push!(idxs, _esm_to_symbolic(a, var_dict, t_sym, dim_dict))
        end
    end
    # Ghost-cell guard: concrete integer indices outside the declared array
    # bounds map to Dirichlet ghost cells (value = 0).
    if arr isa AbstractArray && !isempty(idxs) && all(idx isa Integer for idx in idxs)
        sz = size(arr)
        if length(sz) == length(idxs)
            for (d, idx) in enumerate(idxs)
                (idx < 1 || idx > sz[d]) && return Symbolics.Num(0)
            end
        end
    end
    return getindex(arr, idxs...)
end

function _build_broadcast(expr::OpExpr, var_dict::Dict{String,Any},
                          t_sym, dim_dict::Dict{String,Any})
    expr.fn === nothing && throw(ArgumentError("broadcast node missing 'fn'"))
    fn_name = expr.fn
    operands = [_esm_to_symbolic(a, var_dict, t_sym, dim_dict) for a in expr.args]
    fn = fn_name == "+" ? (+) :
         fn_name == "-" ? (-) :
         fn_name == "*" ? (*) :
         fn_name == "/" ? (/) :
         fn_name == "^" ? (^) :
         fn_name == "exp" ? exp :
         fn_name == "log" ? log :
         fn_name == "log10" ? log10 :
         fn_name == "sin" ? sin :
         fn_name == "cos" ? cos :
         fn_name == "sqrt" ? sqrt :
         fn_name == "abs" ? abs :
         throw(ArgumentError("Unsupported broadcast fn: $fn_name"))
    return Base.materialize(Base.broadcasted(fn, operands...))
end

function _build_reshape(expr::OpExpr, var_dict::Dict{String,Any},
                        t_sym, dim_dict::Dict{String,Any})
    expr.shape === nothing && throw(ArgumentError("reshape node missing 'shape'"))
    arr = _esm_to_symbolic(expr.args[1], var_dict, t_sym, dim_dict)
    dims = Int[]
    for entry in expr.shape
        if entry isa Integer
            push!(dims, Int(entry))
        else
            throw(ArgumentError("reshape currently only supports integer shape entries, got $(entry)"))
        end
    end
    return Symbolics.reshape(arr, dims...)
end

function _build_transpose(expr::OpExpr, var_dict::Dict{String,Any},
                          t_sym, dim_dict::Dict{String,Any})
    arr = _esm_to_symbolic(expr.args[1], var_dict, t_sym, dim_dict)
    if expr.perm !== nothing
        # Schema perm is 0-based; Julia permutedims expects 1-based axes.
        perm1 = [p + 1 for p in expr.perm]
        return permutedims(arr, perm1)
    end
    return transpose(arr)
end

function _build_concat(expr::OpExpr, var_dict::Dict{String,Any},
                       t_sym, dim_dict::Dict{String,Any})
    expr.axis === nothing && throw(ArgumentError("concat node missing 'axis'"))
    arrs = [_esm_to_symbolic(a, var_dict, t_sym, dim_dict) for a in expr.args]
    return cat(arrs...; dims=expr.axis + 1)
end

# ========================================
# Closed function `fn` op (esm-spec §9.2)
# ========================================
#
# `interp.linear` and `interp.bilinear` are registered as opaque symbolic
# operators here so that MTK `structural_simplify` does NOT decompose each
# call into the ~10 underlying searchsorted+index+blend nodes — components
# with hundreds of lookups (e.g. fastjx 18 wavelengths × 13 species ≈ 230
# lookups) blew up the alias-elimination pass otherwise (esm-94w / esm-q7a;
# rationale documented at esm-spec §9.2 + escalation hq-wisp-y6g6).
#
# The const table and axis arrays carried by the `fn` AST node are extracted
# at lowering time and passed as concrete `Vector{Float64}` (axes / 1-D
# tables) or `Vector{Vector{Float64}}` (2-D tables). These container types
# act as the non-symbolic-arg discriminators in `@register_symbolic`; the
# scalar query argument(s) are the only symbolic args MTK traces.
#
# `interp.searchsorted` is intentionally NOT registered here — its return
# is an integer index, and the only spec-supported composition with `index`
# requires array-shaped intermediate evaluation that does not lower cleanly
# to MTK. Callers needing searchsorted in symbolic contexts should use the
# named tensor-interp primitives instead (which were added precisely for
# that reason).

# 1-D linear interp registered op. The `table` and `axis` arguments are
# concrete vectors; `x` is the symbolic query that MTK's tracer flows.
function _esm_interp_linear(table::Vector{Float64}, axis::Vector{Float64}, x::Real)::Float64
    return EarthSciAST.evaluate_closed_function("interp.linear",
        Any[table, axis, Float64(x)])::Float64
end

# 2-D bilinear interp registered op. The `table` is a row-major nested
# vector (`table[i][j]` at `(axis_x[i], axis_y[j])`).
function _esm_interp_bilinear(table::Vector{Vector{Float64}},
                              axis_x::Vector{Float64}, axis_y::Vector{Float64},
                              x::Real, y::Real)::Float64
    return EarthSciAST.evaluate_closed_function("interp.bilinear",
        Any[table, axis_x, axis_y, Float64(x), Float64(y)])::Float64
end

# Register both with `@register_symbolic` so MTK treats each call as a
# single opaque scalar node rather than alias-eliminating the underlying
# blend ASTs. The `false` flag suppresses automatic differentiation
# definition — the spec contract is bit-exact at exact-knot inputs but
# piecewise-linear in between, and a derivative-of-clamp lookup is not part
# of the spec contract; downstream users who need analytic gradients must
# define them separately.
@register_symbolic _esm_interp_linear(table::Vector{Float64}, axis::Vector{Float64}, x) false
@register_symbolic _esm_interp_bilinear(table::Vector{Vector{Float64}}, axis_x::Vector{Float64}, axis_y::Vector{Float64}, x, y) false

# Recursively coerce a JSON-parsed const-array value into the concrete
# vector type the registered op expects. Inputs may be Vector{Any} of
# Float64 (after JSON3 decode) or Vector{Float64}/Matrix-like.
function _to_float64_vector(v)::Vector{Float64}
    v isa Vector{Float64} && return v
    if v isa AbstractVector
        return Float64[Float64(x) for x in v]
    end
    throw(ArgumentError("expected a vector value, got $(typeof(v))"))
end

function _to_float64_table_2d(v)::Vector{Vector{Float64}}
    v isa Vector{Vector{Float64}} && return v
    if v isa AbstractVector
        out = Vector{Vector{Float64}}(undef, length(v))
        for (i, row) in enumerate(v)
            out[i] = _to_float64_vector(row)
        end
        return out
    end
    throw(ArgumentError("expected a 2-D nested vector, got $(typeof(v))"))
end

# Pull a `const`-op array value out of an AST argument node. Errors give
# the same `interp_*_not_const` flavor the spec defines for load-time
# validation, surfaced as plain Julia errors during MTK lowering.
function _extract_const_array_node(arg::EsmExpr, fname::String, label::String)
    if arg isa OpExpr && arg.op == "const" && arg.value isa AbstractVector
        return arg.value
    end
    throw(ArgumentError("$(fname): `$(label)` argument must be a `const`-op array " *
          "(esm-spec §9.2); got $(typeof(arg))"))
end

function _build_fn(expr::OpExpr, var_dict::Dict{String,Any},
                   t_sym, dim_dict::Dict{String,Any})
    fname = expr.name
    fname === nothing && throw(ArgumentError("`fn` op missing required `name` field (esm-spec §4.4)"))
    if fname == "interp.linear"
        length(expr.args) == 3 ||
            throw(ArgumentError("interp.linear expects 3 args, got $(length(expr.args))"))
        table = _to_float64_vector(_extract_const_array_node(expr.args[1], fname, "table"))
        axis  = _to_float64_vector(_extract_const_array_node(expr.args[2], fname, "axis"))
        x_sym = _esm_to_symbolic(expr.args[3], var_dict, t_sym, dim_dict)
        return _esm_interp_linear(table, axis, x_sym)
    elseif fname == "interp.bilinear"
        length(expr.args) == 5 ||
            throw(ArgumentError("interp.bilinear expects 5 args, got $(length(expr.args))"))
        table  = _to_float64_table_2d(_extract_const_array_node(expr.args[1], fname, "table"))
        axis_x = _to_float64_vector(_extract_const_array_node(expr.args[2], fname, "axis_x"))
        axis_y = _to_float64_vector(_extract_const_array_node(expr.args[3], fname, "axis_y"))
        x_sym  = _esm_to_symbolic(expr.args[4], var_dict, t_sym, dim_dict)
        y_sym  = _esm_to_symbolic(expr.args[5], var_dict, t_sym, dim_dict)
        return _esm_interp_bilinear(table, axis_x, axis_y, x_sym, y_sym)
    end
    # Other closed functions (datetime.*, interp.searchsorted) are not
    # exposed as registered symbolic ops — they're either unused in MTK
    # contexts or whose return shape (integer index) doesn't compose with
    # symbolic arithmetic.
    throw(ArgumentError("Unsupported `fn` name in MTK lowering: `$(fname)`. " *
          "Only `interp.linear` and `interp.bilinear` are registered as " *
          "@register_symbolic operators (esm-94w)."))
end

function _get_or_make_dim(dim_dict::Dict{String,Any}, name::AbstractString)
    if haskey(dim_dict, name)
        return dim_dict[name]
    end
    v = Symbolics.variable(Symbol(name))
    dim_dict[String(name)] = v
    return v
end

"""
    _make_dep_var(name::Symbol, iv_syms::Vector{Any}) -> Num

Construct a symbolic variable of the form `name(iv1, iv2, ...)`, where the
`iv_syms` vector contains the actual symbolic objects to use as arguments.
Uses the public `Symbolics.@variables` macro via `Core.eval` so we remain
robust to changes in `FnType`'s parameter list across Symbolics versions.

We build a quoted expression of the form
```
let
    \$iv1_ref = \$iv1
    ...
    @variables name(\$iv1_ref, ...)
end
```
so the IVs are passed by value into the macro's scope.
"""
function _make_dep_var(name::Symbol, iv_syms::Vector{Any})
    # Invent placeholder names so the macro sees valid identifiers
    holder_names = [Symbol("__esm_iv_", i) for i in 1:length(iv_syms)]
    bindings = [Core.Expr(:(=), holder_names[i], iv_syms[i]) for i in 1:length(iv_syms)]
    call_expr = Core.Expr(:call, name, holder_names...)
    block_expr = Core.Expr(:block, bindings..., :(Symbolics.@variables $(call_expr)))
    let_expr = Core.Expr(:let, Core.Expr(:block), block_expr)
    vars = Core.eval(Symbolics, let_expr)
    return vars[1]
end

"""
    _make_param(name::Symbol) -> Num

Construct a plain parameter symbol `name` using `ModelingToolkit.@parameters`.
"""
# @parameters (not @variables) stamps isparameter=true, which AffectSystem
# relies on to classify symbols inside a SymbolicDiscreteCallback affect.
function _make_param(name::Symbol)
    vars = Core.eval(ModelingToolkit, :(@parameters $(name)))
    return vars[1]
end

"""
    _build_description(desc, units) -> Union{String,Nothing}

Assemble a description string that encodes both the ESM variable's textual
description and its units. MTK's `VariableDescription` metadata is a plain
string, so we embed the unit as a `(units=...)` suffix. Returns `nothing`
when there is nothing to attach — the caller uses that to skip metadata.

The ESM binding intentionally does NOT feed units into MTK's own unit
metadata system (that path has latent bugs and duplicates the work of
`src/units.jl`); stuffing units into the description is a version-stable
alternative that still surfaces in error messages and plot labels.
"""
function _build_description(desc::Union{String,Nothing},
                            units::Union{String,Nothing})
    if desc === nothing && units === nothing
        return nothing
    elseif units === nothing
        return desc
    elseif desc === nothing
        return "(units=$(units))"
    else
        return "$(desc) (units=$(units))"
    end
end

"""
    _make_array_dep_var(name::Symbol, iv_syms::Vector{Any}, shape::Vector{UnitRange{Int}})

Construct a shape-annotated symbolic variable of the form
`name(iv1, iv2, ...)[range1, range2, ...]` — the array form produced by
`@variables (u(t))[1:N]`. We build the macro call via `Core.eval` in the
Symbolics module so `iv_syms` can be passed by value. The result is the
array-shaped `Symbolics.Arr` object that supports element-wise indexing
via `u[i]`, `u[i, j]`, etc.
"""
function _make_array_dep_var(name::Symbol, iv_syms::Vector{Any},
                             shape::Vector{UnitRange{Int}})
    holder_names = [Symbol("__esm_iv_", i) for i in 1:length(iv_syms)]
    bindings = [Core.Expr(:(=), holder_names[i], iv_syms[i]) for i in 1:length(iv_syms)]
    call_expr = Core.Expr(:call, name, holder_names...)
    # Always pad the low side of the shape to 1. MTK's init path treats
    # Symbolics.Arr indices as raw 1-based Vector positions, so declaring
    # `@variables flux(t)[3:17]` produces a 15-slot backing Vector but
    # `flux[17]` then resolves to internal position 17 and raises
    # BoundsError during `generate_initializesystem_timevarying`. Using
    # `1:last(r)` makes the backing Vector large enough that every used
    # index is a valid position; the low slots that fall outside the
    # inferred range are simply left out of `states` in `_build_var_dict`.
    ranges_ast = [Core.Expr(:call, :(:), 1, last(r)) for r in shape]
    ref_expr = Core.Expr(:ref, call_expr, ranges_ast...)
    # `(name(iv...)[range...])` — the parenthesized form the macro expects.
    paren_expr = Core.Expr(:block, ref_expr)
    block_expr = Core.Expr(:block, bindings...,
                           :(Symbolics.@variables $(paren_expr)))
    let_expr = Core.Expr(:let, Core.Expr(:block), block_expr)
    vars = Core.eval(Symbolics, let_expr)
    return vars[1]
end

# ========================================
# Build symbolic variable dictionaries from a FlattenedSystem
# ========================================

function _pde_independent_vars(flat::FlattenedSystem)
    return !(length(flat.independent_variables) == 1 &&
             flat.independent_variables[1] == :t)
end

"""
Create Symbolics.jl variable/parameter symbols for every state, parameter, and
observed variable in a flattened system. Returns `(var_dict, t_sym, dim_dict,
states, parameters, observed, spatial_syms)` where `states`/`parameters`/
`observed` are typed `Vector{Num}` and `spatial_syms` holds the non-time
independent-variable symbols (empty for ODE systems).

For ODE systems, state variables are functions of `t` only. For PDE systems,
state variables are functions of `t` and the spatial dimensions declared in
`flat.independent_variables` (minus `:t`).

When the flattened system contains `arrayop`/`makearray`/`index` nodes,
shape inference is run first and any variable that appears inside an array
operator is declared as a shaped `@variables (u(t))[1:N]` instead of a
scalar `u(t)`. The `states`/`observed` vectors then contain the individual
scalar elements of those array variables (so `length(states) == M*N` for a
2-D array), matching the scalar dvs list passed to
`System(..., dvs, [])` in the MTK fork's native `@arrayop` tests.
"""
function _build_var_dict(flat::FlattenedSystem)
    is_pde = _pde_independent_vars(flat)

    # Independent variables
    t_sym = _get_or_make_dim(Dict{String,Any}(), "t")
    dim_dict = Dict{String,Any}("t" => t_sym)

    spatial_syms = Any[]
    if is_pde
        for iv in flat.independent_variables
            iv == :t && continue
            dim_sym = _get_or_make_dim(dim_dict, String(iv))
            push!(spatial_syms, dim_sym)
        end
    end

    # Shape inference: scalar-only systems get an empty dict and pay nothing.
    # Use LHS arrayop output ranges as the authoritative shape when available:
    # they define the actual grid (e.g. 1:N × 1:N), while infer_array_shapes
    # can widen the shape to cover stencil ghost-cell offsets (e.g. 0:N+1).
    inferred_shapes = infer_array_shapes(flat.equations)
    lhs_shapes = _lhs_arrayop_shapes(flat.equations)
    merge!(inferred_shapes, lhs_shapes)  # LHS definition takes precedence

    var_dict = Dict{String,Any}()
    states = Vector{Num}()
    parameters = Vector{Num}()
    observed = Vector{Num}()

    # Concrete IV symbol objects to pass to the @variables macro via our
    # _make_dep_var helper (see the bindings trick inside that function).
    iv_syms_any = Any[t_sym]
    for s in spatial_syms
        push!(iv_syms_any, s)
    end

    # Sanitize names for use as Julia symbols (dots in "System.var" would
    # otherwise produce invalid symbols in the generated @variables call).
    _san(s::AbstractString) = Symbol(replace(String(s), '.' => '_'))

    # Attach a default value to a Symbolics variable via VariableDefaultValue
    # metadata. MTK v11 uses this to wire initial conditions on states and
    # parameter values into ODEProblem/PDESystem construction without
    # requiring the caller to pass u0/p maps manually.
    _with_default(v, val) =
        val === nothing ? v : Symbolics.setdefaultval(v, Float64(val))

    _with_description(v, desc_text) =
        desc_text === nothing ? v :
            Symbolics.setmetadata(v, ModelingToolkit.VariableDescription, desc_text)

    # State variables — functions of independent variables
    for (vname, mvar) in flat.state_variables
        sym_name = _san(vname)
        shape = get(inferred_shapes, vname, nothing)
        desc_text = _build_description(mvar.description, mvar.units)
        if shape === nothing
            v_num = _with_description(
                _with_default(_make_dep_var(sym_name, iv_syms_any), mvar.default),
                desc_text)
            push!(states, v_num)
            var_dict[vname] = v_num
        else
            array_var = _make_array_dep_var(sym_name, iv_syms_any, shape)
            var_dict[vname] = array_var
            # Enumerate the individual scalar elements for the dvs vector.
            # Description metadata is attached per-element because
            # Symbolics.setmetadata has no method for Symbolics.Arr.
            for idx in Iterators.product(shape...)
                elt = _with_description(Num(array_var[idx...]), desc_text)
                push!(states, elt)
            end
        end
    end

    # Parameters — plain symbols
    for (pname, mvar) in flat.parameters
        p_num = _with_description(
            _with_default(_make_param(_san(pname)), mvar.default),
            _build_description(mvar.description, mvar.units))
        push!(parameters, p_num)
        var_dict[pname] = p_num
    end

    # Observed variables — same shape as states
    for (oname, mvar) in flat.observed_variables
        ov_num = _with_description(
            _with_default(_make_dep_var(_san(oname), iv_syms_any), mvar.default),
            _build_description(mvar.description, mvar.units))
        push!(observed, ov_num)
        var_dict[oname] = ov_num
    end

    return var_dict, t_sym, dim_dict, states, parameters, observed, spatial_syms
end

# ========================================
# Event conversion
# ========================================

# Substitute every state variable reference in `expr` with
# `ModelingToolkit.Pre(var)`. Required on event-affect RHS expressions:
# current MTK interprets an un-`Pre`-wrapped affect equation as an
# algebraic constraint to hold after the callback, which renders
# assignments like `x ~ x + dose` unsatisfiable (see
# ModelingToolkit/callbacks.jl:85 warning). Parameters are left alone —
# they don't vary across the affect, and wrapping them would force the
# discrete-parameter machinery for no gain.
function _wrap_pre_states(expr, state_syms)
    isempty(state_syms) && return expr
    subs = Dict{Any,Any}()
    for sv in state_syms
        u = Symbolics.unwrap(sv)
        subs[u] = ModelingToolkit.Pre(sv)
    end
    if expr isa AbstractArray
        return map(e -> Symbolics.substitute(e, subs), expr)
    end
    return Symbolics.substitute(expr, subs)
end

function _affect_to_eq(affect, var_dict::Dict{String,Any}, t_sym, dim_dict,
                      state_syms)
    if affect isa AffectEquation
        if !haskey(var_dict, affect.lhs)
            @warn "Target variable $(affect.lhs) not found for event affect"
            return nothing
        end
        target = var_dict[affect.lhs]
        rhs = _esm_to_symbolic(affect.rhs, var_dict, t_sym, dim_dict)
        rhs = _wrap_pre_states(rhs, state_syms)
        return target ~ rhs
    elseif affect isa FunctionalAffect
        if !haskey(var_dict, affect.target)
            @warn "Target variable $(affect.target) not found for event affect"
            return nothing
        end
        target = var_dict[affect.target]
        rhs = _esm_to_symbolic(affect.expression, var_dict, t_sym, dim_dict)
        rhs = _wrap_pre_states(rhs, state_syms)
        # For compound operations the LHS target also appears on the RHS
        # and must refer to its pre-affect value.
        pre_target = ModelingToolkit.Pre(target)
        if affect.operation == "set"
            return target ~ rhs
        elseif affect.operation == "add"
            return target ~ pre_target + rhs
        elseif affect.operation == "multiply"
            return target ~ pre_target * rhs
        else
            @warn "Unknown affect operation: $(affect.operation)"
            return target ~ rhs
        end
    end
    return nothing
end

function _build_continuous_events(flat::FlattenedSystem, var_dict, t_sym, dim_dict,
                                  state_syms)
    cbs = Any[]
    for ev in flat.continuous_events
        conds = [_esm_to_symbolic(c, var_dict, t_sym, dim_dict) for c in ev.conditions]
        affects = filter(!isnothing,
                         [_affect_to_eq(a, var_dict, t_sym, dim_dict, state_syms)
                          for a in ev.affects])
        # NOTE: parenthesized guard — the bare `a || b && continue` form
        # parses as `a || (b && continue)`, letting an event with EMPTY
        # conditions fall through to `conds[1]` (BoundsError).
        (isempty(conds) || isempty(affects)) && continue
        # MTK's SymbolicContinuousCallback accepts a vector of condition
        # equations (all must root simultaneously); pass the single
        # condition bare to preserve the long-standing scalar behavior.
        cb = ModelingToolkit.SymbolicContinuousCallback(
            length(conds) == 1 ? conds[1] : conds, affects)
        push!(cbs, cb)
    end
    return cbs
end

function _build_discrete_events(flat::FlattenedSystem, var_dict, t_sym, dim_dict,
                                state_syms)
    cbs = Any[]
    for ev in flat.discrete_events
        affects = filter(!isnothing,
                         [_affect_to_eq(a, var_dict, t_sym, dim_dict, state_syms)
                          for a in ev.affects])
        isempty(affects) && continue
        if ev.trigger isa ConditionTrigger
            cond = _esm_to_symbolic(ev.trigger.expression, var_dict, t_sym, dim_dict)
            push!(cbs, ModelingToolkit.SymbolicDiscreteCallback(cond, affects))
        elseif ev.trigger isa PeriodicTrigger
            push!(cbs, ModelingToolkit.SymbolicDiscreteCallback(ev.trigger.period, affects))
        elseif ev.trigger isa PresetTimesTrigger
            # MTK routes a Vector{<:Real} condition to PresetTimeCallback
            # (fires at exactly those times); a scalar Real goes to
            # PeriodicCallback (fires at tspan[1]+period, 2*period, ...).
            # Pass the full times vector so multi-time triggers are honored.
            if !isempty(ev.trigger.times)
                push!(cbs, ModelingToolkit.SymbolicDiscreteCallback(
                    collect(ev.trigger.times), affects))
            end
        end
    end
    return cbs
end

# ========================================
# ModelingToolkit.System constructors
# ========================================

"""
    ModelingToolkit.System(flat::FlattenedSystem; name=:anonymous, kwargs...)

Build a real `ModelingToolkit.ODESystem`/`System` from a flattened ESM system.
Errors with a clear redirect to `ModelingToolkit.PDESystem` when the flattened
system has spatial independent variables.
"""
function ModelingToolkit.System(flat::FlattenedSystem;
                                name::Union{Symbol,AbstractString}=:anonymous,
                                kwargs...)
    if _pde_independent_vars(flat)
        throw(ArgumentError(
            "Flattened system has independent variables $(flat.independent_variables), " *
            "which indicates a PDE. Use ModelingToolkit.PDESystem(...) instead of " *
            "ModelingToolkit.System(...)."
        ))
    end

    # esm-i7b: ODE path. Spatial differential operators (`grad`/`div`/
    # `laplacian`) MUST be rewritten by ESD discretization rules into
    # `arrayop` AST before reaching the simulator. Encountering one in an
    # ODE-only system means the canonical pipeline broke; surface this
    # rather than letting the operator slip into MTK's symbolic engine
    # (where it would either error obscurely or — worse, if the operator
    # has been mapped to a `Differential` symbol — silently produce a
    # spatial derivative the ODE solver cannot integrate).
    for eq in flat.equations
        for side in (eq.lhs, eq.rhs)
            spatial_op = _find_spatial_op(side)
            spatial_op === nothing || throw(ArgumentError(
                "UnreachableSpatialOperatorError: encountered '$(spatial_op)' " *
                "node in simulation evaluation. Spatial operators must be " *
                "rewritten by ESD discretization rules before reaching the " *
                "simulator. Pipeline contract violated."
            ))
        end
    end

    var_dict, t_sym, dim_dict, states, parameters, observed, _ =
        _build_var_dict(flat)

    # ---- Route `ic(var) = <initial value>` equations out of the ODE set ----
    # (esm-spec v0.8.0) An `ic`-LHS equation declares an initial value (u0 /
    # variable default), NOT an ODE right-hand side. Mirror the tree-walk
    # simulate path (src/tree_walk.jl): pull each `ic` equation out before
    # symbolic lowering and fold its RHS into the target state's default value.
    # The default is attached via variable metadata (`Symbolics.setdefaultval`)
    # — the same channel `_build_var_dict` uses for `ModelVariable.default` —
    # since this MTK System constructor takes no `defaults` keyword. MTK then
    # wires the default into ODEProblem u0 construction, and a caller-supplied
    # initial condition still overrides it. Leaving an `ic` node in the equation
    # set would send it to `_esm_to_symbolic`, which has no handler →
    # "Unsupported operator: ic".
    ic_values = Tuple{String,Any}[]
    dyn_equations = Equation[]
    for eq in flat.equations
        if eq.lhs isa OpExpr && (eq.lhs::OpExpr).op == "ic"
            lop = eq.lhs::OpExpr
            (length(lop.args) == 1 && lop.args[1] isa VarExpr) ||
                throw(ArgumentError("ic(...) LHS must name a single state variable"))
            vn = (lop.args[1]::VarExpr).name
            haskey(var_dict, vn) || throw(ArgumentError(
                "ic($(vn)) targets unknown variable '$(vn)'"))
            push!(ic_values,
                  (vn, _esm_to_symbolic(eq.rhs, var_dict, t_sym, dim_dict)))
        else
            push!(dyn_equations, eq)
        end
    end

    # Fold each ic value into the target state's default via `setdefaultval`,
    # rewriting the shared handle in both `var_dict` (so the equations, events,
    # and `state_syms` built below reference the defaulted symbol) and `states`
    # (so the default rides through into `dvs`). Applied before `eqs` are built.
    for (vn, val) in ic_values
        old = var_dict[vn]
        new = Symbolics.setdefaultval(old, val)
        var_dict[vn] = new
        for i in eachindex(states)
            states[i] === old && (states[i] = new)
        end
    end

    MTKEquation = ModelingToolkit.Equation
    eqs = Vector{MTKEquation}()
    for eq in dyn_equations
        lhs = _esm_to_symbolic(eq.lhs, var_dict, t_sym, dim_dict)
        rhs = _esm_to_symbolic(eq.rhs, var_dict, t_sym, dim_dict)
        push!(eqs, lhs ~ rhs)
    end

    # Observed variables need to appear in the unknowns (dvs) list so that
    # references to them elsewhere in the equations pass MTK's structural
    # check. Their defining equation (`obs ~ expr`) stays in the main
    # equation list; `mtkcompile`'s alias elimination pass moves them to
    # the compiled system's `observed` section automatically.
    dvs = copy(states)
    append!(dvs, observed)

    # Symbolic handles for state variables (not their array-scalarized
    # elements) drive `Pre`-wrapping in affect equations.
    state_syms = Any[var_dict[vname] for vname in keys(flat.state_variables)]
    cont_cbs = _build_continuous_events(flat, var_dict, t_sym, dim_dict, state_syms)
    disc_cbs = _build_discrete_events(flat, var_dict, t_sym, dim_dict, state_syms)

    sys_name = name isa Symbol ? name : Symbol(name)

    # Only pass event kwargs that are non-empty — MTK treats an explicit
    # empty event list differently from an omitted kwarg on some versions.
    event_kwargs = Pair{Symbol,Any}[]
    isempty(cont_cbs) || push!(event_kwargs, :continuous_events => cont_cbs)
    isempty(disc_cbs) || push!(event_kwargs, :discrete_events => disc_cbs)
    return ModelingToolkit.System(eqs, t_sym, dvs, parameters;
        name=sys_name, event_kwargs..., kwargs...)
end

"""
    ModelingToolkit.System(model::Model; name=:anonymous, kwargs...)

Convenience: flatten the model first, then build the `System`.
"""
function ModelingToolkit.System(model::Model;
                                name::Union{Symbol,AbstractString}=:anonymous,
                                kwargs...)
    flat = flatten(model; name=String(name isa Symbol ? name : Symbol(name)))
    return ModelingToolkit.System(flat; name=name, kwargs...)
end

# ========================================
# ModelingToolkit.PDESystem constructors
# ========================================

"""
    ModelingToolkit.PDESystem(flat::FlattenedSystem; name=:anonymous, kwargs...)

Build a `ModelingToolkit.PDESystem` from a flattened ESM system. Errors with
a clear redirect to `ModelingToolkit.System` when the flattened system is a
pure ODE.

Boundary conditions are derived from the flattened system's domain and any
slice-derived surface source patterns (see below). Initial conditions come
from variable defaults.

## Surface-source → flux boundary condition lowering

When the flattened system includes a state variable of the form `V.at_z`
that is defined by both:
1. A slice connector `V.at_z = V(t, ..., z_0)`, and
2. An ODE `D(V.at_z, t) = f(...)`,
and `V` itself participates in a diffusive PDE `D(V, t) = D_coeff *
Differential(z)(Differential(z)(V))`, the constructor emits a flux boundary
condition at `z = z_0` of the form
`D_coeff * Differential(z)(V)(t, z_0) ~ f(...)` and drops the ODE on the slice
variable. This implements the Julia-specific convention (§5.1) that
slice-derived surface source equations become flux BCs rather than pointwise
source terms in the lowest grid cell.
"""
function ModelingToolkit.PDESystem(flat::FlattenedSystem;
                                   name::Union{Symbol,AbstractString}=:anonymous,
                                   kwargs...)
    if !_pde_independent_vars(flat)
        throw(ArgumentError(
            "Flattened system has independent variables [t] only — this is a " *
            "pure ODE system. Use ModelingToolkit.System(...) instead of " *
            "ModelingToolkit.PDESystem(...)."
        ))
    end

    var_dict, t_sym, dim_dict, states, parameters, observed, spatial_syms =
        _build_var_dict(flat)

    # ------------------------------------------------------------
    # Detect slice-derived surface source pattern
    # ------------------------------------------------------------
    # For each state variable with a name of the form "<prefix>.at_<dim>",
    # check if there is:
    #   (1) a connector equation "<prefix>.at_<dim> ~ <base>(t, ..., <dim_0>)"
    #   (2) an ODE equation "D(<prefix>.at_<dim>, t) ~ f(...)"
    #   (3) a base variable <base> that appears in a diffusive PDE equation.
    # If so, emit a flux BC and drop the slice-ODE.
    slice_bcs, slice_vars_to_drop = _lower_slice_sources_to_bcs!(
        flat, var_dict, t_sym, dim_dict)

    MTKEquation = ModelingToolkit.Equation
    eqs = Vector{MTKEquation}()
    for eq in flat.equations
        # Skip ODEs on slice variables that were lowered to flux BCs
        if _is_odelhs_for_slice_var(eq, slice_vars_to_drop)
            continue
        end
        lhs = _esm_to_symbolic(eq.lhs, var_dict, t_sym, dim_dict)
        rhs = _esm_to_symbolic(eq.rhs, var_dict, t_sym, dim_dict)
        push!(eqs, lhs ~ rhs)
    end

    # ------------------------------------------------------------
    # Initial conditions from variable defaults
    # ------------------------------------------------------------
    ics = MTKEquation[]
    for (vname, mvar) in flat.state_variables
        if mvar.default !== nothing && haskey(var_dict, vname)
            v = var_dict[vname]
            push!(ics, v ~ Float64(mvar.default))
        end
    end

    # Merge slice-derived BCs with any domain-declared BCs
    bcs = slice_bcs

    # Build the independent variable vector and domain specification
    iv_syms = [t_sym; spatial_syms...]

    domain_spec = _build_domain_spec(flat.domain, dim_dict, t_sym, spatial_syms)

    sys_name = name isa Symbol ? name : Symbol(name)

    dvars = [Num(v) for v in states]
    append!(dvars, Num(v) for v in observed)

    return ModelingToolkit.PDESystem(eqs, bcs, domain_spec, iv_syms, dvars,
                                     parameters; name=sys_name, kwargs...)
end

"""
    ModelingToolkit.PDESystem(model::Model; name=:anonymous, kwargs...)
"""
function ModelingToolkit.PDESystem(model::Model;
                                   name::Union{Symbol,AbstractString}=:anonymous,
                                   kwargs...)
    flat = flatten(model; name=String(name isa Symbol ? name : Symbol(name)))
    return ModelingToolkit.PDESystem(flat; name=name, kwargs...)
end

# ------------------------------------------------------------
# Slice-source detection helpers
# ------------------------------------------------------------

"""
Return the list of state-variable names of the form `"<prefix>.at_<dim>"`
that look like slice connectors for a spatial dimension declared in `flat.
independent_variables`.
"""
function _find_slice_candidates(flat::FlattenedSystem)
    spatial_dims = [String(iv) for iv in flat.independent_variables if iv != :t]
    candidates = String[]
    for vname in keys(flat.state_variables)
        idx = findlast('.', vname)
        idx === nothing && continue
        tail = vname[(idx+1):end]
        startswith(tail, "at_") || continue
        dim = tail[4:end]
        dim in spatial_dims && push!(candidates, vname)
    end
    return candidates
end

"""
Walk the flattened equations and, for each slice-candidate state variable,
check for both a connector-form algebraic equation and a D(·,t) ODE. If
both exist and the base variable has a diffusive equation in the PDE set,
emit a flux boundary condition and mark the slice variable for removal.
"""
function _lower_slice_sources_to_bcs!(flat::FlattenedSystem,
                                      var_dict, t_sym, dim_dict)
    MTKEquation = ModelingToolkit.Equation
    bcs = MTKEquation[]
    drop = Set{String}()

    candidates = _find_slice_candidates(flat)
    isempty(candidates) && return bcs, drop

    for slice_name in candidates
        # Extract base prefix + slice dim from the candidate name
        base_dot = findlast('.', slice_name)
        base_dot === nothing && continue
        prefix = slice_name[1:(base_dot-1)]
        tail = slice_name[(base_dot+1):end]  # e.g. "at_z"
        dim_name = tail[4:end]                # "z"
        base_name = prefix                    # we emit flux BC on the "prefix" base var
        haskey(var_dict, base_name) || continue

        # Find an ODE equation on the slice variable
        ode_rhs = nothing
        for eq in flat.equations
            if _lhs_is_D_of(eq.lhs, slice_name)
                ode_rhs = eq.rhs
                break
            end
        end
        ode_rhs === nothing && continue

        # Find a diffusive equation on the base variable to extract the
        # diffusion coefficient. Pattern: D(base, t) ~ D_coeff * Differential(dim)(Differential(dim)(base))
        D_coeff_sym = nothing
        for eq in flat.equations
            if _lhs_is_D_of(eq.lhs, base_name)
                D_coeff_sym = _extract_diffusion_coefficient(eq.rhs, base_name, dim_name)
                D_coeff_sym !== nothing && break
            end
        end
        D_coeff_sym === nothing && continue

        # Substitute slice-variable references with the base variable in the
        # ODE rhs: the BC RHS should reference the base field at z=0, not the
        # slice-connector intermediate.
        ode_rhs_sub = _substitute_varname(ode_rhs, slice_name, base_name)

        dim_sym = _get_or_make_dim(dim_dict, dim_name)
        base_var = var_dict[base_name]
        D_coeff_val = _esm_to_symbolic(D_coeff_sym, var_dict, t_sym, dim_dict)
        rhs_sym = _esm_to_symbolic(ode_rhs_sub, var_dict, t_sym, dim_dict)

        # Flux BC: D_coeff * ∂(base)/∂dim ~ rhs_of_slice_ode (with slice var
        # rewritten to base var). For now we emit the BC unconditionally —
        # users can pin it to `dim = 0` via the domain spec.
        flux_lhs = D_coeff_val * Differential(dim_sym)(base_var)
        push!(bcs, flux_lhs ~ rhs_sym)

        push!(drop, slice_name)
    end

    return bcs, drop
end

"Substitute every `VarExpr(old)` with `VarExpr(new)` in an Expr tree."
function _substitute_varname(expr::EsmExpr, old::AbstractString, new::AbstractString)
    if expr isa VarExpr
        return expr.name == old ? VarExpr(String(new)) : expr
    elseif expr isa NumExpr || expr isa IntExpr
        return expr
    elseif expr isa OpExpr
        new_args = EsmExpr[_substitute_varname(a, old, new) for a in expr.args]
        return OpExpr(expr.op, new_args; wrt=expr.wrt, dim=expr.dim)
    else
        return expr
    end
end

function _lhs_is_D_of(lhs::EsmExpr, var_name::String)
    lhs isa OpExpr || return false
    lhs.op == "D" || return false
    length(lhs.args) >= 1 || return false
    inner = lhs.args[1]
    inner isa VarExpr || return false
    return inner.name == var_name
end

"""
Look for a diffusion term `D_coeff * Differential(dim)(Differential(dim)(base))`
in an Expr tree and return `D_coeff` as an Expr. Very simple pattern matcher:
expects the Expr to be a `*` with two operands or a `+`/`-` with one operand
shaped this way. Returns `nothing` if not found.
"""
function _extract_diffusion_coefficient(expr::EsmExpr, base_name::String,
                                        dim_name::String)
    expr isa OpExpr || return nothing
    if expr.op == "*" && length(expr.args) == 2
        a, b = expr.args
        if _is_d2_of(b, base_name, dim_name)
            return a
        elseif _is_d2_of(a, base_name, dim_name)
            return b
        end
    elseif expr.op == "laplacian" && length(expr.args) == 1
        inner = expr.args[1]
        if inner isa VarExpr && inner.name == base_name
            # D * laplacian(base) not expressible here without outer coefficient
            return nothing
        end
    elseif expr.op in ("+", "-")
        for arg in expr.args
            found = _extract_diffusion_coefficient(arg, base_name, dim_name)
            found !== nothing && return found
        end
    end
    return nothing
end

function _is_d2_of(expr::EsmExpr, var_name::String, dim_name::String)
    expr isa OpExpr || return false
    expr.op == "grad" || return false
    expr.dim == dim_name || return false
    length(expr.args) == 1 || return false
    inner = expr.args[1]
    inner isa OpExpr || return false
    inner.op == "grad" || return false
    inner.dim == dim_name || return false
    length(inner.args) == 1 || return false
    innermost = inner.args[1]
    return innermost isa VarExpr && innermost.name == var_name
end

_is_odelhs_for_slice_var(eq::Equation, drop::Set{String}) =
    any(v -> _lhs_is_D_of(eq.lhs, v), drop)

# ------------------------------------------------------------
# Domain specification helper
# ------------------------------------------------------------

function _build_domain_spec(domain::Union{Domain,Nothing}, dim_dict,
                            t_sym, spatial_syms)
    if domain === nothing
        # Default: 0 ≤ t, and each spatial dim over [0, 1]
        specs = Any[t_sym ∈ Interval(0.0, 1.0)]
        for sym in spatial_syms
            push!(specs, sym ∈ Interval(0.0, 1.0))
        end
        return specs
    end

    specs = Any[]
    if domain.temporal !== nothing
        for (name, bounds) in domain.temporal
            haskey(dim_dict, name) || continue
            lo, hi = _parse_bounds(bounds)
            push!(specs, dim_dict[name] ∈ Interval(lo, hi))
        end
    end
    # The ESM `Domain` type carries only temporal bounds at this seam, so
    # spatial dimensions get the same [0, 1] default as the `domain ===
    # nothing` branch above. PDESystem consumers (MethodOfLines et al.)
    # require a domain entry for EVERY independent variable — emitting only
    # temporal intervals here would leave the spatial dims unbounded and
    # break discretization downstream.
    for sym in spatial_syms
        push!(specs, sym ∈ Interval(0.0, 1.0))
    end
    return specs
end

function _parse_bounds(bounds)
    if bounds isa AbstractVector && length(bounds) >= 2
        return Float64(bounds[1]), Float64(bounds[2])
    elseif bounds isa AbstractDict
        lo = get(bounds, "min", get(bounds, :min, 0.0))
        hi = get(bounds, "max", get(bounds, :max, 1.0))
        return Float64(lo), Float64(hi)
    end
    return 0.0, 1.0
end

# ========================================
# Reverse direction: MTK → ESM Model
# ========================================

"""
    EarthSciAST.Model(sys::ModelingToolkit.AbstractSystem)

Convert a ModelingToolkit System back to an ESM `Model`. Supports ODESystems
and systems that expose `unknowns`, `parameters`, and `equations`.

Defaults come from the system defaults map / per-symbol metadata via
`_lookup_default`; when no default is recorded the ESM `default` field is
left as `nothing` (omitted on serialization) rather than fabricated.
Expressions are serialized with `_symbolic_to_esm_export` so callable
states `x(t)` become `VarExpr("x")` instead of the schema-invalid
`OpExpr("x", [VarExpr("t")])` shape.
"""
function EarthSciAST.Model(sys::ModelingToolkit.AbstractSystem)
    variables = Dict{String,ModelVariable}()

    sys_defaults = try
        ModelingToolkit.defaults(sys)
    catch e
        @debug "Model(sys): ModelingToolkit.defaults unavailable" exception=(e, catch_backtrace())
        Dict()
    end
    obs_eqs = try
        ModelingToolkit.observed(sys)
    catch e
        @debug "Model(sys): ModelingToolkit.observed unavailable" exception=(e, catch_backtrace())
        []
    end

    # Collect every known variable name up front so the expression walk can
    # disambiguate callable-symbolic states `x(t)` from operator calls.
    known_vars = Set{String}()
    for state in ModelingToolkit.unknowns(sys)
        push!(known_vars, _strip_time(string(ModelingToolkit.getname(state))))
    end
    for param in ModelingToolkit.parameters(sys)
        push!(known_vars, string(ModelingToolkit.getname(param)))
    end
    for obs in obs_eqs
        push!(known_vars, _strip_time(string(ModelingToolkit.getname(obs.lhs))))
    end

    for state in ModelingToolkit.unknowns(sys)
        var_name = _strip_time(string(ModelingToolkit.getname(state)))
        variables[var_name] = ModelVariable(StateVariable;
            default=_lookup_default(state, sys_defaults))
    end

    for param in ModelingToolkit.parameters(sys)
        pname = string(ModelingToolkit.getname(param))
        variables[pname] = ModelVariable(ParameterVariable;
            default=_lookup_default(param, sys_defaults))
    end

    for obs in obs_eqs
        oname = _strip_time(string(ModelingToolkit.getname(obs.lhs)))
        variables[oname] = ModelVariable(ObservedVariable;
            expression=_symbolic_to_esm_export(obs.rhs, known_vars))
    end

    equations = Equation[]
    for eq in ModelingToolkit.equations(sys)
        push!(equations, Equation(_symbolic_to_esm_export(eq.lhs, known_vars),
                                  _symbolic_to_esm_export(eq.rhs, known_vars)))
    end

    return Model(variables, equations)
end

# ========================================
# MTK → ESM export (gt-dod2; Phase 1 migration tooling)
# ========================================

"""
Return a user-facing system kind name used in warnings and TODO_GAP notes.
Catalyst.ReactionSystem is handled in the Catalyst extension; the cases
here cover plain MTK systems whose type-printed name matches the expected
system class.
"""
function _sys_kind(sys)
    t = string(typeof(sys))
    if occursin("PDESystem", t);       return "PDESystem"
    elseif occursin("SDESystem", t);   return "SDESystem"
    elseif occursin("ReactionSystem", t); return "ReactionSystem"
    elseif occursin("NonlinearSystem", t); return "NonlinearSystem"
    elseif occursin("ODESystem", t);   return "ODESystem"
    else;                              return "System"
    end
end

# Return `true` if the System *declares* brownian variables (SDE). We detect
# by presence of the `brownians` getter on AbstractSystem (MTK v11+). For
# older systems or systems without the field, return `false`.
function _mtk_brownians(sys)
    try
        return ModelingToolkit.brownians(sys)
    catch
        return Any[]
    end
end

# Return the MTK system's noise_eqs vector, or empty if not set.
function _mtk_noise_eqs(sys)
    try
        return ModelingToolkit.get_noiseeqs(sys)
    catch
        return nothing
    end
end

# Convert a symbolic to ESM expression using a known set of variable names
# to disambiguate callable-symbolic nodes like `x(t)` from operator calls.
# MTK states and observed variables appear in the symbolic tree as
# `Sym{FnType{...}}(t)`, which a naive walk would emit as
# `OpExpr("x", [VarExpr("t")])` — the wrong shape for the ESM schema.
# `known_vars` lets us recognize those nodes and emit `VarExpr("x")`.
function _symbolic_to_esm_export(expr, known_vars::Set{String},
                                 strip_ns::Function=identity)
    # Scalar fast-paths
    if expr isa Bool
        return IntExpr(Int64(expr))
    elseif expr isa Integer
        return IntExpr(Int64(expr))
    elseif expr isa AbstractFloat
        return NumExpr(Float64(expr))
    elseif expr isa Real
        return NumExpr(Float64(expr))
    end
    raw = Symbolics.unwrap(expr)

    # Symbolic constants (e.g. `-1` produced by SymbolicUtils' multiplication
    # simplification `-k*x`) arrive as `BasicSymbolic{Int}` / `...{Real}`
    # with issym=false AND iscall=false. `Symbolics.value` extracts the
    # underlying Julia number without touching variable paths.
    if !Symbolics.issym(raw) && !Symbolics.iscall(raw)
        try
            val = Symbolics.value(raw)
            if val isa Bool;       return IntExpr(Int64(val))
            elseif val isa Integer; return IntExpr(Int64(val))
            elseif val isa Real;    return NumExpr(Float64(val))
            end
        catch
        end
    end

    if Symbolics.issym(raw)
        name = strip_ns(_strip_time(string(Symbolics.getname(raw))))
        return VarExpr(name)
    end

    is_diff = try
        Symbolics.is_derivative(raw)
    catch
        false
    end
    if is_diff
        inner = _symbolic_to_esm_export(Symbolics.arguments(raw)[1],
                                         known_vars, strip_ns)
        return OpExpr("D", EsmExpr[inner], wrt="t")
    end

    if Symbolics.iscall(raw)
        op = Symbolics.operation(raw)
        args = Symbolics.arguments(raw)

        # Callable-symbolic variable: `x(t)` where `x` is a state/observed
        # var. Recognize by checking if the operation's name is a known
        # variable. Preserve as a bare VarExpr(name), dropping the IV args
        # — the ESM schema implicitly threads time through state vars.
        if !isempty(args)
            opname = try
                strip_ns(_strip_time(string(Symbolics.getname(op))))
            catch
                ""
            end
            if !isempty(opname) && opname in known_vars
                return VarExpr(opname)
            end
        end

        esm_args = [_symbolic_to_esm_export(a, known_vars, strip_ns) for a in args]
        # Helper: check op equality, handling SymbolicUtils-wrapped forms
        _op_matches(op, target) = op == target || string(nameof(op)) == string(nameof(target))
        if _op_matches(op, +); return OpExpr("+", esm_args)
        elseif _op_matches(op, *); return OpExpr("*", esm_args)
        elseif _op_matches(op, -); return OpExpr("-", esm_args)
        elseif _op_matches(op, /); return OpExpr("/", esm_args)
        elseif _op_matches(op, ^); return OpExpr("^", esm_args)
        elseif _op_matches(op, exp); return OpExpr("exp", esm_args)
        elseif _op_matches(op, log); return OpExpr("log", esm_args)
        elseif _op_matches(op, log10); return OpExpr("log10", esm_args)
        elseif _op_matches(op, sin); return OpExpr("sin", esm_args)
        elseif _op_matches(op, cos); return OpExpr("cos", esm_args)
        elseif _op_matches(op, tan); return OpExpr("tan", esm_args)
        elseif _op_matches(op, sqrt); return OpExpr("sqrt", esm_args)
        elseif _op_matches(op, abs); return OpExpr("abs", esm_args)
        elseif _op_matches(op, ifelse); return OpExpr("ifelse", esm_args)
        elseif _op_matches(op, min); return OpExpr("min", esm_args)
        elseif _op_matches(op, max); return OpExpr("max", esm_args)
        else
            opname = try
                string(nameof(op))
            catch
                string(op)
            end
            return OpExpr(opname, esm_args)
        end
    end
    return VarExpr(string(expr))
end

function _symbolic_to_esm_with_gaps(expr, known_vars::Set{String},
                                    gaps::Vector{GapReport}, where_str::String;
                                    strip_ns::Function=identity)
    try
        return _symbolic_to_esm_export(expr, known_vars, strip_ns)
    catch e
        push!(gaps, GapReport("unknown",
            "unable to serialize symbolic node: $(sprint(showerror, e))",
            where_str))
        return VarExpr("__TODO_GAP__")
    end
end

# Resolve the exported component name: caller-supplied `metadata.name` wins;
# else `nameof(sys)` if non-anonymous; else the literal `fallback` placeholder
# so the output file is still addressable.
function _resolve_sys_name(sys, metadata, fallback::String)
    name_kw = _meta_string(metadata, :name, "")
    isempty(name_kw) || return name_kw
    try
        sn = String(nameof(sys))
        return sn == "" ? fallback : sn
    catch e
        @debug "mtk2esm: nameof(sys) unavailable" exception=(e, catch_backtrace())
        return fallback
    end
end

# Export states / parameters / observed / brownian variables from `sys` into
# `esm_vars`, registering every exported name in `known_vars` (used by the
# expression walk to disambiguate callable-symbolic states from op calls).
function _export_variables!(esm_vars::Dict{String,ModelVariable},
                            known_vars::Set{String}, gaps::Vector{GapReport},
                            sys, strip_ns::Function)
    # System-level defaults dict — variables declared via `defaults=Dict(...)`
    # on System construction surface here rather than on the symbolic
    # metadata. We look up both and prefer the system-level value.
    sys_defaults = try
        ModelingToolkit.defaults(sys)
    catch e
        @debug "mtk2esm: ModelingToolkit.defaults unavailable" exception=(e, catch_backtrace())
        Dict()
    end

    for state in ModelingToolkit.unknowns(sys)
        var_name = strip_ns(_strip_time(string(ModelingToolkit.getname(state))))
        push!(known_vars, var_name)
        esm_vars[var_name] = ModelVariable(StateVariable;
            default=_lookup_default(state, sys_defaults),
            units=_get_units_str(state),
            description=_get_description_str(state))
    end

    for param in ModelingToolkit.parameters(sys)
        pname = strip_ns(string(ModelingToolkit.getname(param)))
        push!(known_vars, pname)
        esm_vars[pname] = ModelVariable(ParameterVariable;
            default=_lookup_default(param, sys_defaults),
            units=_get_units_str(param),
            description=_get_description_str(param))
    end

    obs_exprs = try
        ModelingToolkit.observed(sys)
    catch e
        @debug "mtk2esm: ModelingToolkit.observed unavailable" exception=(e, catch_backtrace())
        []
    end
    for obs in obs_exprs
        oname = strip_ns(_strip_time(string(ModelingToolkit.getname(obs.lhs))))
        push!(known_vars, oname)
        rhs_esm = _symbolic_to_esm_with_gaps(obs.rhs, known_vars, gaps,
            "observed[$oname].rhs"; strip_ns=strip_ns)
        esm_vars[oname] = ModelVariable(ObservedVariable;
            expression=rhs_esm)
    end

    # Brownian variables (SDE noise sources) — gt-kuxo gate.
    brownians = _mtk_brownians(sys)
    if !isempty(brownians)
        push!(gaps, GapReport("gt-kuxo",
            "system has $(length(brownians)) brownian variable(s); " *
            "SDE noise serialization requires gt-kuxo to land first",
            "system.brownians"))
        for b in brownians
            bname = string(ModelingToolkit.getname(b))
            esm_vars[bname] = ModelVariable(BrownianVariable;
                noise_kind="wiener")
        end
    end

    noise_eqs = _mtk_noise_eqs(sys)
    if noise_eqs !== nothing && !isempty(noise_eqs)
        push!(gaps, GapReport("gt-kuxo",
            "system has explicit noise_eqs matrix; serialization of SDE " *
            "diffusion terms requires gt-kuxo to land first",
            "system.noise_eqs"))
    end
    return nothing
end

"""
    mtk2esm(sys::ModelingToolkit.AbstractSystem; metadata=(;)) -> Dict

Walk a non-reaction MTK system and emit a schema-valid ESM `Dict` with a
top-level `models.<name>` entry. Reaction systems are handled in the
Catalyst extension via a more specific method.

Fields populated from the MTK IR:
- `variables` (state / parameter / observed / brownian, with units +
  defaults extracted from symbolic metadata where present)
- `equations` (D(x)~rhs using the spec's Expression ops)
- `continuous_events`, `discrete_events` (from MTK callback lists)

Fields left as placeholders (filled in Phase 2 per-model migrations):
- `description`, `version`, `reference`, `tests`, `examples`
- `metadata.tags`, `metadata.source_ref` (populated from `metadata` kwarg)
"""
function mtk2esm(sys::ModelingToolkit.AbstractSystem; metadata=(;))
    gaps = GapReport[]

    kind = _sys_kind(sys)
    sys_name = _resolve_sys_name(sys, metadata, "UnnamedSystem")

    # When an MTK System was built via our ESM.Model → MTK.System path, the
    # flatten step sanitizes names as "<SystemName>_<var>" (dots → underscores).
    # We strip that prefix so the exported ESM names round-trip back to the
    # same bare names they had in the source Model. Direct-Symbolics-built
    # systems without the prefix pass through untouched.
    sys_name_prefix = sys_name * "_"
    strip_ns = s -> startswith(s, sys_name_prefix) ?
        s[length(sys_name_prefix)+1:end] : s

    # 1. Variables -----------------------------------------------------------
    esm_vars = Dict{String,ModelVariable}()
    known_vars = Set{String}()
    _export_variables!(esm_vars, known_vars, gaps, sys, strip_ns)

    # 2. Equations -----------------------------------------------------------
    esm_equations = _export_equations(sys, known_vars, gaps, strip_ns)

    # registered symbolic functions (gt-p3ep gate): detected by scanning the
    # symbolic AST for unknown `iscall` operations whose operation has a
    # non-Base name. Done during the recursive _symbolic_to_esm_export walk
    # when a call to a user-registered function produces an OpExpr with a non-
    # standard op name — conservatively report a generic gap note if we saw
    # operator names not in the schema's standard op set.
    _detect_registered_call_gaps!(gaps, esm_equations)

    # 3. Events --------------------------------------------------------------
    cont_events, disc_events = _export_events(sys, known_vars, gaps)

    # 4. Domain (PDE only) ---------------------------------------------------
    esm_domain = nothing
    if kind == "PDESystem"
        # PDESystem carries domain info; we flag as gap for now since the
        # round-trip of domain specs requires dedicated lowering logic.
        push!(gaps, GapReport("gt-vzwk",
            "PDESystem domain specification is not yet serialized — see gt-vzwk",
            "system.domain"))
    end

    # 5. Build ESM Model and wrap in EsmFile --------------------------------
    # NOTE (esm-spec v0.8.0): `domain` moved from the Model to the document
    # level, so `Model(...)` no longer accepts a `domain=` kwarg. PDE domain
    # round-trip is still an open gap (gt-vzwk, flagged above), and `esm_domain`
    # is always `nothing` here, so there is nothing to place at the document
    # level yet — the kwarg is simply dropped.
    esm_model = Model(esm_vars, esm_equations;
        discrete_events=disc_events, continuous_events=cont_events)

    # Serialize directly to a Dict so callers can mutate and embed
    # TODO_GAP notes before writing to disk. We bypass the EsmFile type
    # because the tests/examples fields are intentionally empty placeholders
    # the downstream migration step fills in later.
    model_dict = EarthSciAST.serialize_model(esm_model)

    # Build the Model-level `reference` entry. The schema defines Reference
    # with {doi, citation, url, notes} — we fold the migration description,
    # source_ref, and TODO_GAP notes into `notes` as a human-readable string
    # so the file stays schema-conformant. Later migration steps overwrite
    # this with a real citation when the source docstring is scraped.
    ref_notes_lines = _reference_notes(metadata, gaps)
    if !isempty(ref_notes_lines)
        model_dict["reference"] = Dict{String,Any}(
            "notes" => join(ref_notes_lines, "\n"))
    end
    # Always emit placeholder tests/examples arrays: the schema treats them
    # as optional, but their empty presence is the downstream migration
    # tooling's "to be filled in Phase 2" signal.
    model_dict["tests"] = Any[]
    model_dict["examples"] = Any[]

    # 6. Wrap in EsmFile-shaped Dict ----------------------------------------
    out = Dict{String,Any}(
        "esm" => EarthSciAST.ESM_FORMAT_VERSION,
        "metadata" => _esm_file_metadata(metadata, sys_name),
        "models" => Dict{String,Any}(sys_name => model_dict),
    )

    # 7. Emit warnings --------------------------------------------------------
    _warn_gaps(gaps, "$(kind) $(sys_name)")

    return out
end

# Serialize the system's equations, flagging init equations (gt-ebuq gate).
function _export_equations(sys, known_vars::Set{String},
                           gaps::Vector{GapReport}, strip_ns::Function)
    esm_equations = Equation[]
    raw_eqs = try
        ModelingToolkit.equations(sys)
    catch e
        @debug "mtk2esm: ModelingToolkit.equations unavailable" exception=(e, catch_backtrace())
        []
    end
    for (i, eq) in enumerate(raw_eqs)
        lhs_esm = _symbolic_to_esm_with_gaps(eq.lhs, known_vars, gaps,
            "equations[$i].lhs"; strip_ns=strip_ns)
        rhs_esm = _symbolic_to_esm_with_gaps(eq.rhs, known_vars, gaps,
            "equations[$i].rhs"; strip_ns=strip_ns)
        push!(esm_equations, Equation(lhs_esm, rhs_esm))
    end

    # init equations (gt-ebuq gate) — present on MTK v11 systems
    init_eqs = try
        ModelingToolkit.initialization_equations(sys)
    catch e
        @debug "mtk2esm: initialization_equations unavailable" exception=(e, catch_backtrace())
        []
    end
    if !isempty(init_eqs)
        push!(gaps, GapReport("gt-ebuq",
            "system declares $(length(init_eqs)) init equation(s); " *
            "serialization of initialization blocks requires gt-ebuq",
            "system.initialization_equations"))
    end
    return esm_equations
end

# Serialize the system's continuous/discrete callbacks to ESM event lists.
function _export_events(sys, known_vars::Set{String}, gaps::Vector{GapReport})
    cont_events = ContinuousEvent[]
    disc_events = DiscreteEvent[]

    cont_cbs = try
        ModelingToolkit.continuous_events(sys)
    catch e
        @debug "mtk2esm: continuous_events unavailable" exception=(e, catch_backtrace())
        []
    end
    for (i, cb) in enumerate(cont_cbs)
        ce = _continuous_cb_to_esm(cb, known_vars, gaps, "continuous_events[$i]")
        ce !== nothing && push!(cont_events, ce)
    end

    disc_cbs = try
        ModelingToolkit.discrete_events(sys)
    catch e
        @debug "mtk2esm: discrete_events unavailable" exception=(e, catch_backtrace())
        []
    end
    for (i, cb) in enumerate(disc_cbs)
        de = _discrete_cb_to_esm(cb, known_vars, gaps, "discrete_events[$i]")
        de !== nothing && push!(disc_events, de)
    end
    return cont_events, disc_events
end

# --- metadata helpers ---
# (`_meta_string` / `_meta_vec_string` / `_gap_to_note` are MTK-independent
# and live in src/mtk_export.jl, shared with the Catalyst extension.)

# --- symbolic metadata extraction ---

function _get_default_or(var, default)
    try
        val = ModelingToolkit.getdefault(var)
        val isa Number && return Float64(val)
        return default
    catch e
        # `getdefault` throws when the symbol carries no default metadata —
        # an expected miss, but log it so genuine failures stay diagnosable.
        @debug "mtk2esm: no readable default for $(var)" exception=(e, catch_backtrace())
        return default
    end
end

"""
Prefer the system-level defaults map (set via `System(...; defaults=...)`)
over per-symbol metadata. Returns `nothing` when no default is found so
the ESM `default` field is omitted rather than fabricated.
"""
function _lookup_default(var, sys_defaults)
    # System-level defaults dict uses the symbolic variable itself (with its
    # time dependence intact) as the key.
    if haskey(sys_defaults, var)
        v = sys_defaults[var]
        v isa Number && return Float64(v)
    end
    return _get_default_or(var, nothing)
end

function _get_units_str(var)
    raw = Symbolics.unwrap(var)
    try
        desc = Symbolics.getmetadata(raw, ModelingToolkit.VariableDescription, nothing)
        if desc isa AbstractString
            m = match(r"\(units=([^)]+)\)", desc)
            m !== nothing && return String(m.captures[1])
        end
    catch e
        @debug "mtk2esm: units metadata unreadable for $(var)" exception=(e, catch_backtrace())
    end
    return nothing
end

function _get_description_str(var)
    raw = Symbolics.unwrap(var)
    try
        desc = Symbolics.getmetadata(raw, ModelingToolkit.VariableDescription, nothing)
        if desc isa AbstractString
            # Strip the embedded (units=...) suffix we inject ourselves on
            # the reverse path; preserve the human description, if any.
            stripped = replace(desc, r"\s*\(units=[^)]+\)\s*$" => "")
            return isempty(stripped) ? nothing : String(stripped)
        end
    catch e
        @debug "mtk2esm: description metadata unreadable for $(var)" exception=(e, catch_backtrace())
    end
    return nothing
end

# --- event conversion (MTK → ESM) ---

function _continuous_cb_to_esm(cb, known_vars::Set{String},
                               gaps::Vector{GapReport}, where_str::String)
    # MTK callbacks expose fields via property access that differs across
    # versions; we try a few shapes and fall back to a gap report if we
    # can't extract the pieces we need.
    try
        conds = cb.conditions isa AbstractArray ? cb.conditions : [cb.conditions]
        esm_conds = EsmExpr[]
        for c in conds
            push!(esm_conds, _symbolic_to_esm_with_gaps(c, known_vars, gaps,
                where_str * ".condition"))
        end
        affects = cb.affects isa AbstractArray ? cb.affects : [cb.affects]
        esm_affs = AffectEquation[]
        for a in affects
            ae = _affect_to_esm(a, known_vars, gaps, where_str * ".affect")
            ae !== nothing && push!(esm_affs, ae)
        end
        return ContinuousEvent(esm_conds, esm_affs)
    catch e
        push!(gaps, GapReport("unknown",
            "unable to serialize continuous callback: $(sprint(showerror, e))",
            where_str))
        return nothing
    end
end

function _discrete_cb_to_esm(cb, known_vars::Set{String},
                             gaps::Vector{GapReport}, where_str::String)
    try
        trig_raw = hasproperty(cb, :condition) ? cb.condition : cb.conditions
        trigger = if trig_raw isa Real
            PeriodicTrigger(Float64(trig_raw))
        elseif trig_raw isa AbstractVector{<:Real}
            PresetTimesTrigger(Float64.(trig_raw))
        else
            ConditionTrigger(_symbolic_to_esm_with_gaps(trig_raw, known_vars,
                gaps, where_str * ".condition"))
        end
        affects = cb.affects isa AbstractArray ? cb.affects : [cb.affects]
        esm_affs = FunctionalAffect[]
        for a in affects
            af = _affect_to_functional(a, known_vars, gaps,
                where_str * ".affect")
            af !== nothing && push!(esm_affs, af)
        end
        return DiscreteEvent(trigger, esm_affs)
    catch e
        push!(gaps, GapReport("unknown",
            "unable to serialize discrete callback: $(sprint(showerror, e))",
            where_str))
        return nothing
    end
end

function _affect_to_esm(a, known_vars::Set{String},
                        gaps::Vector{GapReport}, where_str::String)
    try
        lhs_sym = hasproperty(a, :lhs) ? a.lhs : a[1]
        rhs_sym = hasproperty(a, :rhs) ? a.rhs : a[2]
        lhs_name = _strip_time(string(ModelingToolkit.getname(lhs_sym)))
        rhs_esm = _symbolic_to_esm_with_gaps(rhs_sym, known_vars, gaps,
            where_str * ".rhs")
        return AffectEquation(lhs_name, rhs_esm)
    catch
        return nothing
    end
end

function _affect_to_functional(a, known_vars::Set{String},
                               gaps::Vector{GapReport}, where_str::String)
    try
        lhs_sym = hasproperty(a, :lhs) ? a.lhs : a[1]
        rhs_sym = hasproperty(a, :rhs) ? a.rhs : a[2]
        lhs_name = _strip_time(string(ModelingToolkit.getname(lhs_sym)))
        rhs_esm = _symbolic_to_esm_with_gaps(rhs_sym, known_vars, gaps,
            where_str * ".rhs")
        return FunctionalAffect(lhs_name, rhs_esm; operation="set")
    catch
        return nothing
    end
end

# --- registered-function gap detection ---

# Ops the exporter recognizes as standard; any other OpExpr op is flagged as a
# likely registered-function gap. Membership is declared per-op in
# src/op_registry.jl (flag `:mtk_known`) and pinned by op_registry_test.jl.
const _KNOWN_OPS = EarthSciAST._ops_with(:mtk_known)

function _detect_registered_call_gaps!(gaps::Vector{GapReport},
                                       equations::Vector{Equation})
    seen = Set{String}()
    for (i, eq) in enumerate(equations)
        _walk_expr_for_gaps!(eq.lhs, seen, gaps, "equations[$i].lhs")
        _walk_expr_for_gaps!(eq.rhs, seen, gaps, "equations[$i].rhs")
    end
end

function _walk_expr_for_gaps!(expr, seen::Set{String}, gaps::Vector{GapReport},
                              where_str::String)
    if expr isa OpExpr
        if !(expr.op in _KNOWN_OPS) && !(expr.op in seen)
            push!(seen, expr.op)
            push!(gaps, GapReport("gt-p3ep",
                "non-standard op '$(expr.op)' likely requires a registered " *
                "function declaration — see gt-p3ep",
                where_str))
        end
        for a in expr.args
            _walk_expr_for_gaps!(a, seen, gaps, where_str)
        end
    end
end

"""
    mtk2esm_gaps(sys::ModelingToolkit.AbstractSystem) -> Vector{GapReport}

Cheap pre-flight check that currently detects ONLY brownian variables
(SDE noise, gt-kuxo). It does NOT replicate the full gap detection
performed during a `mtk2esm` export (init equations, noise_eqs,
registered-function calls, PDE domains); run `mtk2esm` itself for the
complete gap report.
"""
# TODO(aspiration): grow this into the full pre-flight scan promised by the
# original design — same gap coverage as mtk2esm without producing the
# export — so migration tooling can gate models cheaply.
function mtk2esm_gaps(sys::ModelingToolkit.AbstractSystem)
    gaps = GapReport[]
    b = _mtk_brownians(sys)
    isempty(b) || push!(gaps, GapReport("gt-kuxo",
        "system has $(length(b)) brownian variable(s)",
        "system.brownians"))
    return gaps
end
end # module EarthSciASTMTKExt
