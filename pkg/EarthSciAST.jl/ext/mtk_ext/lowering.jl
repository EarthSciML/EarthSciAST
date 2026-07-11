# ========================================
# ESM Expr → Symbolics conversion
# ========================================

# The mechanical unary ops the ODE/PDE lowering accepts. Deliberately NOT the
# registry's `_UNARY_ELEMENTWISE_OPS` (which also carries sign/floor/ceil/
# asinh/… this arm never accepted, and excludes the 1-or-2-ary `atan` this
# arm has always treated as unary), and deliberately wider than the Catalyst
# rate interpreter's set — membership is behavior, so it stays explicit.
const _MTK_UNARY_SCALAR_OPS = ("exp", "log", "log10", "sin", "cos", "tan",
                               "sinh", "cosh", "tanh", "asin", "acos", "atan",
                               "sqrt", "abs")

"""
Build a Symbolics.jl expression from an ESM `Expr` tree, using the given
variable dictionary (name → symbolic variable) and the time symbol `t_sym`.
Spatial dimension symbols are created on demand and cached in `dim_dict`.

The extension-independent scalar arms live in the shared
`_esm_to_symbolic_core` (ext/shared/esm_to_symbolic.jl); everything MTK-
specific — calculus/control/comparison ops and the array vocabulary — is
handled by `_mtk_extended_op` below.
"""
function _esm_to_symbolic(expr::EsmExpr, var_dict::Dict{String,Any},
                          t_sym, dim_dict::Dict{String,Any})
    return _esm_to_symbolic_core(expr,
        a -> _esm_to_symbolic(a, var_dict, t_sym, dim_dict);
        number_value = _int_promoted_number,
        resolve_var = name -> _resolve_lowering_var(name, var_dict, dim_dict),
        unary_ops = _MTK_UNARY_SCALAR_OPS,
        extended_op = (op, e) -> _mtk_extended_op(op, e, var_dict, t_sym, dim_dict))
end

# Integer-valued NumExpr is promoted to Int so arrayop index
# expressions like `i - 1` stay integer-typed when fixtures
# still encode whole numbers as NumExpr. Floats above Int64 range
# (e.g. Avogadro's number 6.022e23) stay Float64 — Int(x) on them
# raises InexactError.
function _int_promoted_number(v)
    if isfinite(v) && v == floor(v) && typemin(Int) <= v <= typemax(Int)
        return Int(v)
    else
        return v
    end
end

# Unknown-variable policy of the ODE/PDE lowering: variables must already be
# declared (state/parameter/observed dictionaries or a known dimension) —
# THROW otherwise. The Catalyst rate lowering auto-creates instead; the
# divergence is live behavior (see ext/shared/esm_to_symbolic.jl).
function _resolve_lowering_var(name::String, var_dict::Dict{String,Any},
                               dim_dict::Dict{String,Any})
    if haskey(var_dict, name)
        return var_dict[name]
    elseif haskey(dim_dict, name)
        return dim_dict[name]
    else
        throw(ArgumentError("Variable '$(name)' not found in variable dictionary"))
    end
end

# The MTK-specific OpExpr arms: calculus operators, control flow,
# comparisons, the array/aggregate vocabulary, and registered closed
# functions. Reached from `_esm_to_symbolic_core` for every op outside the
# shared scalar arms.
function _mtk_extended_op(op::AbstractString, expr::OpExpr,
                          var_dict::Dict{String,Any}, t_sym,
                          dim_dict::Dict{String,Any})
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

# The broadcast vocabulary. Membership is BEHAVIOR (a fn outside this set
# must keep erroring), and it is intentionally NARROWER than the registry's
# `_UNARY_ELEMENTWISE_OPS` (no tan/asin/floor/…), so the supported set stays
# explicit here — only the name→function mapping is delegated to the op
# registry, which records the same scalar function for every one of these.
const _BROADCAST_FNS = Dict{String,Function}(
    name => EarthSciAST._op_spec(name).scalar_fn
    for name in ("+", "-", "*", "/", "^",
                 "exp", "log", "log10", "sin", "cos", "sqrt", "abs"))

function _build_broadcast(expr::OpExpr, var_dict::Dict{String,Any},
                          t_sym, dim_dict::Dict{String,Any})
    expr.fn === nothing && throw(ArgumentError("broadcast node missing 'fn'"))
    fn_name = expr.fn
    operands = [_esm_to_symbolic(a, var_dict, t_sym, dim_dict) for a in expr.args]
    fn = get(_BROADCAST_FNS, fn_name, nothing)
    fn === nothing && throw(ArgumentError("Unsupported broadcast fn: $fn_name"))
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
