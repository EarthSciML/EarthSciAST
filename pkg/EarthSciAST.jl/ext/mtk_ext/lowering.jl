# ========================================
# ESM ASTExpr → Symbolics conversion
# ========================================

# The mechanical unary ops the ODE/PDE lowering accepts. Deliberately NOT the
# registry's `_UNARY_ELEMENTWISE_OPS` (which also carries sign/floor/ceil/
# asinh/… this arm never accepted, and excludes the 1-or-2-ary `atan` this
# arm has always treated as unary), and deliberately wider than the Catalyst
# rate interpreter's set — membership is behavior, so it stays explicit.
const _MTK_UNARY_SCALAR_OPS = (
    "exp", "log", "log10", "sin", "cos", "tan",
    "sinh", "cosh", "tanh", "asin", "acos", "atan",
    "sqrt", "abs",
)

"""
Build a Symbolics.jl expression from an ESM `ASTExpr` tree, using the given
variable dictionary (name → symbolic variable) and the time symbol `t_sym`.
Spatial dimension symbols are created on demand and cached in `dim_dict`.

The extension-independent scalar arms live in the shared
`_esm_to_symbolic_core` (ext/shared/esm_to_symbolic.jl); everything MTK-
specific — calculus/control/comparison ops and the array vocabulary — is
handled by `_mtk_extended_op` below.
"""
function _esm_to_symbolic(
        expr::EsmExpr, var_dict::Dict{String, Any},
        t_sym, dim_dict::Dict{String, Any}
    )
    return _esm_to_symbolic_core(
        expr,
        a -> _esm_to_symbolic(a, var_dict, t_sym, dim_dict);
        number_value = _int_promoted_number,
        resolve_var = name -> _resolve_lowering_var(name, var_dict, dim_dict),
        unary_ops = _MTK_UNARY_SCALAR_OPS,
        extended_op = (op, e) -> _mtk_extended_op(op, e, var_dict, t_sym, dim_dict)
    )
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
function _resolve_lowering_var(
        name::String, var_dict::Dict{String, Any},
        dim_dict::Dict{String, Any}
    )
    if haskey(var_dict, name)
        return var_dict[name]
    elseif haskey(dim_dict, name)
        return dim_dict[name]
    else
        throw(ArgumentError("Variable '$(name)' not found in variable dictionary"))
    end
end

# The MTK-specific OpExpr arms: calculus operators, control flow,
# comparisons and the array/aggregate vocabulary. Reached from `_esm_to_symbolic_core` for every op outside the
# shared scalar arms.
function _mtk_extended_op(
        op::AbstractString, expr::OpExpr,
        var_dict::Dict{String, Any}, t_sym,
        dim_dict::Dict{String, Any}
    )
    if op == "neg"
        # The CANONICAL unary minus (`src/canonicalize.jl` rewrites `{"op":"-"}`
        # with one argument to it), so every canonicalized document that negates
        # anything arrives here. Its absence made `ModelingToolkit.System` throw
        # "Unsupported operator: neg" on `tests/valid/solver_block.esm` — a
        # two-line scalar decay — while the un-canonicalized `-` spelling built
        # fine, which is the same operator wearing a different name.
        return -_esm_to_symbolic(expr.args[1], var_dict, t_sym, dim_dict)
    elseif op == "pow"
        # `pow(a, b)` is the registry's named spelling of `a ^ b` (op_registry
        # `_op("pow"; fn=(^))`), the twin of the `neg`/`-` pair above.
        return _esm_to_symbolic(expr.args[1], var_dict, t_sym, dim_dict) ^
            _esm_to_symbolic(expr.args[2], var_dict, t_sym, dim_dict)
    elseif op == "D"
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
        return op == ">" ? l > r :
            op == "<" ? l < r :
            op == ">=" ? l >= r :
            op == "<=" ? l <= r :
            op == "==" ? l == r :
            l != r
    elseif op == "faq"
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
    elseif op == "const"
        # esm-spec §9.2: a `const` node IS its value. A scalar lowers to the
        # number. An ARRAY lowers to a dense `Array{Float64}` (`value[i][j]` is
        # element `(i, j)`): it is the RHS of a const-array observed, which the
        # system builders lower element by element (`_push_lowered_equation!`).
        # An array read through `index` never reaches this arm — `_build_index`
        # takes it as a const-array gather.
        expr.value isa Real && return expr.value
        expr.value isa AbstractVector && return EarthSciAST._const_op_to_array(expr.value)
        throw(
            ArgumentError(
                "`const` with a $(typeof(expr.value)) value has no " *
                    "MTK lowering (esm-spec §9.2)"
            )
        )
    else
        throw(ArgumentError("Unsupported operator: $op"))
    end
end

# Walk an ESM expression tree looking for any spatial differential operator
# (`grad`/`div`/`laplacian`). Returns the offending op name on the first
# match, or `nothing` if none is present. Used by the ODE-path
# `ModelingToolkit.System` constructor to enforce the canonical pipeline
# contract (esm-i7b).
function _find_spatial_op(expr::EsmExpr)::Union{String, Nothing}
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
# `@makearray` runtime semantics. A scalar region value is broadcast across
# the region; an array-valued one (an interior-stencil `faq`, say) fills it
# element by element and must match the region's shape once singleton
# dimensions are dropped (esm-spec §4.3.2).
function _build_makearray(
        expr::OpExpr, var_dict::Dict{String, Any},
        t_sym, dim_dict::Dict{String, Any}
    )
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
        region_axes = Tuple(pair[1]:pair[2] for pair in region)
        if v isa Symbolics.Arr || v isa AbstractArray
            _fill_makearray_region!(result, region_axes, v)
        else
            v_num = v isa Symbolics.Num ? v : Symbolics.Num(v)
            for idx in Iterators.product(region_axes...)
                result[idx...] = v_num
            end
        end
    end
    return result
end

# Copy an array-valued region fill into `result`, element by element in
# column-major order, after checking its non-singleton extents match the
# region's.
function _fill_makearray_region!(result, region_axes, v)
    vals = collect(Symbolics.scalarize(v))
    squeeze(dims) = filter(!=(1), collect(dims))
    region_size = map(length, region_axes)
    squeeze(size(vals)) == squeeze(region_size) || throw(
        ArgumentError(
            "makearray region of size $(region_size) cannot take an " *
                "array value of size $(size(vals))"
        )
    )
    for (idx, val) in zip(Iterators.product(region_axes...), vals)
        result[idx...] = val isa Symbolics.Num ? val : Symbolics.Num(val)
    end
    return nothing
end

# ---- Const-array gathers (esm-spec §9.2, CONFORMANCE_SPEC §5.5.5) ----
#
# `index(table, e_1, …, e_D)` where `table` is a `const` array — written
# inline, or an observed whose definition is a `const` array — reads build-time
# literal data, exactly as the tree-walk's const-array registry does. An index
# that lowers to a number resolves now; any other index is read at run time
# through a registered gather, so MTK sees one opaque scalar per read. Either
# way an out-of-range index raises `E_TREEWALK_CONSTARRAY_OOB`: a document
# carries no boundary policy for a const array, so the §5.5.5 default applies,
# and the zero ghost of a state/observed gather is never used.

# `dim_dict` key of the name → `Array{Float64}` registry of const-array
# observeds, filled by `_register_const_array_observeds!`.
const _CONST_ARRAYS_KEY = "__esm_const_array_observeds__"

# Record every observed defined by a `const` array so a gather on its name
# reads the literal data rather than the symbolic array variable.
function _register_const_array_observeds!(dim_dict::Dict{String, Any}, flat)
    registry = Dict{String, Array{Float64}}()
    for eq in flat.equations
        (eq.lhs isa VarExpr && eq.rhs isa OpExpr) || continue
        rhs = eq.rhs::OpExpr
        (rhs.op == "const" && rhs.value isa AbstractVector) || continue
        registry[(eq.lhs::VarExpr).name] = EarthSciAST._const_op_to_array(rhs.value)
    end
    isempty(registry) || (dim_dict[_CONST_ARRAYS_KEY] = registry)
    return nothing
end

# `(table, name)` when `base` is a const-array gather base, else `(nothing, "")`.
function _const_index_base(base::EsmExpr, dim_dict::Dict{String, Any})
    if base isa OpExpr && base.op == "const" && base.value isa AbstractVector
        return EarthSciAST._const_op_to_array(base.value), "inline const"
    elseif base isa VarExpr
        registry = get(dim_dict, _CONST_ARRAYS_KEY, nothing)
        if registry !== nothing && haskey(registry, base.name)
            return registry[base.name], base.name
        end
    end
    return nothing, ""
end

function _esm_const_gather(table::Vector{Float64}, name::String, i::Real)::Float64
    return table[EarthSciAST._resolve_const_index(table, name, 1, round(Int, i), size(table, 1))]
end

function _esm_const_gather(table::Matrix{Float64}, name::String, i::Real, j::Real)::Float64
    ri = EarthSciAST._resolve_const_index(table, name, 1, round(Int, i), size(table, 1))
    rj = EarthSciAST._resolve_const_index(table, name, 2, round(Int, j), size(table, 2))
    return table[ri, rj]
end

function _esm_const_gather(table::Array{Float64, 3}, name::String, i::Real, j::Real, k::Real)::Float64
    ri = EarthSciAST._resolve_const_index(table, name, 1, round(Int, i), size(table, 1))
    rj = EarthSciAST._resolve_const_index(table, name, 2, round(Int, j), size(table, 2))
    rk = EarthSciAST._resolve_const_index(table, name, 3, round(Int, k), size(table, 3))
    return table[ri, rj, rk]
end

@register_symbolic _esm_const_gather(table::Vector{Float64}, name::String, i) false
@register_symbolic _esm_const_gather(table::Matrix{Float64}, name::String, i, j) false
@register_symbolic _esm_const_gather(table::Array{Float64, 3}, name::String, i, j, k) false
# The registration's symtype promotion does not match a call whose table
# argument is a constant, which is how every call looks once MTK rebuilds it
# (alias elimination substitutes an observed into the index): the rebuilt call
# gets symtype `Any` and `mtkcompile` cannot subtract it. Every one of these
# calls is a real scalar, so say so for any argument types.
Symbolics.SymbolicUtils.promote_symtype(::typeof(_esm_const_gather), args...) = Real

function _build_const_gather(
        table::Array{Float64}, name::String,
        idx_args::AbstractVector, var_dict::Dict{String, Any},
        t_sym, dim_dict::Dict{String, Any}
    )
    length(idx_args) == ndims(table) ||
        throw(
        EarthSciAST.TreeWalkError(
            "E_TREEWALK_CONSTARRAY_NDIM",
            "const array '$(name)' is $(ndims(table))D but got " *
                "$(length(idx_args)) indices"
        )
    )
    idxs = Any[]
    for a in idx_args
        v = _esm_to_symbolic(a, var_dict, t_sym, dim_dict)
        # `Num <: Real`, so test the unwrapped value: only a NUMBER resolves now.
        n = Symbolics.value(v)
        if n isa Real
            isinteger(n) || throw(
                ArgumentError(
                    "index argument must be an integer, got $(n)"
                )
            )
            v = Int(n)
        end
        push!(idxs, v)
    end
    if all(i -> i isa Integer, idxs)
        resolved = ntuple(
            d -> EarthSciAST._resolve_const_index(
                table, name, d, idxs[d], size(table, d)
            ), ndims(table)
        )
        return table[resolved...]
    end
    ndims(table) <= 3 || throw(
        ArgumentError(
            "MTK lowering gathers a const array of at most 3 dimensions at a " *
                "run-time index; '$(name)' has $(ndims(table))"
        )
    )
    return _esm_const_gather(table, name, idxs...)
end

# Is a lowered operand ARRAY-SHAPED?
#
# Testing the Julia type alone gets this wrong, and did: a `Symbolics.Arr` that
# has been unwrapped — which is what an arrayop body or a whole-array reduction
# lowers to — is a `BasicSymbolic` carrying an array SYMTYPE, and it is not
# `<: AbstractArray`. Reading it as a scalar made `_push_lowered_equation!`
# broadcast a shaped right-hand side over a shaped left-hand side one cell at a
# time, which Symbolics then refused with "Cannot equate an array of different
# sizes. Got () and (4,)" on the two `wrt_default_*_shaped` fixtures. SymbolicUtils'
# own `symtype` is the question actually being asked.
function _mtk_is_array_shaped(x)
    (x isa AbstractArray || x isa Symbolics.Arr) && return true
    st = try
        SymUtils.symtype(Symbolics.unwrap(x))
    catch
        return false
    end
    return st <: AbstractArray
end

# Push `lhs ~ rhs`, or one equation per element when `rhs` is a const array
# (an observed defined by a `const` array).
function _push_lowered_equation!(eqs::AbstractVector, lhs, rhs)
    # `Array{Float64}`, not `AbstractArray{<:Real}`: a `makearray` lowers to an
    # `Array{Num}` (`Num <: Real`) and keeps its whole-array equation.
    if rhs isa Array{Float64}
        size(lhs) == size(rhs) || throw(
            ArgumentError(
                "`const` array of size $(size(rhs)) defines a variable of size $(size(lhs))"
            )
        )
        for I in CartesianIndices(rhs)
            push!(eqs, lhs[I] ~ rhs[I])
        end
    elseif _mtk_is_array_shaped(lhs) && !_mtk_is_array_shaped(rhs)
        # esm-spec §4.3.4 / CONFORMANCE_SPEC §5.41: a SCALAR right-hand side on a
        # SHAPED left-hand side replicates along every axis the scalar does not
        # declare. Symbolics' `~` refuses `Arr ~ scalar` outright ("Cannot equate
        # an array of different sizes. Got (4,) and ()."), so the replication has
        # to happen here — one equation per cell, which is the same thing the
        # `const`-array arm above does for a shaped literal.
        for I in CartesianIndices(axes(lhs))
            push!(eqs, lhs[Tuple(I)...] ~ rhs)
        end
    else
        push!(eqs, lhs ~ rhs)
    end
    return eqs
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
function _build_index(
        expr::OpExpr, var_dict::Dict{String, Any},
        t_sym, dim_dict::Dict{String, Any}
    )
    # A const-array gather (CONFORMANCE_SPEC §5.5.5) never takes the zero ghost
    # below, so it is routed before the operand is lowered.
    table, table_name = _const_index_base(expr.args[1], dim_dict)
    table === nothing ||
        return _build_const_gather(
        table, table_name, expr.args[2:end],
        var_dict, t_sym, dim_dict
    )

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
            isinteger(a.value) || throw(
                ArgumentError(
                    "index argument must be an integer, got $(a.value)"
                )
            )
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

# The broadcast vocabulary, DERIVED from the op registry: every ARITHMETIC or
# ELEMENTARY row with a recorded scalar function — `+ - * / ^ pow neg` plus the
# full unary/binary elementary set (`exp`/`log`/`sin`/…/`tan`/`floor`/`min`/
# `max`/`atan2`). It used to be a hand-listed dozen, which made a perfectly
# ordinary `broadcast(fn:"tan", …)` an exporter-only failure while the tree-walk
# path evaluated it; deriving it keeps the two back ends speaking the same
# `fn` vocabulary (esm-spec §4.3.4).
#
# Deliberately EXCLUDED, and still erroring: the comparison, logical, control
# and niladic-constant rows. `Base.broadcasted(<, …)` yields a symbolic BOOLEAN,
# not the spec's 1.0/0.0 comparison value, and `and`/`or`/`not`/`ifelse`/`Pre`
# record no single Base scalar function at all — so admitting them here would
# silently diverge from the evaluator rather than extend it.
const _BROADCAST_FNS = Dict{String, Function}(
    s.name => s.scalar_fn for s in EarthSciAST._OP_TABLE
        if s.scalar_fn !== nothing &&
        (s.category === :arithmetic || s.category === :elementary)
)

function _build_broadcast(
        expr::OpExpr, var_dict::Dict{String, Any},
        t_sym, dim_dict::Dict{String, Any}
    )
    # The §4.3.4 `fn` contract, from the SAME predicate `validate()` reports as
    # `invalid_broadcast_fn` and the tree-walk build enforces: a missing /
    # unregistered / structural `fn`, or an operand count outside the named op's
    # registry arity, is rejected before any operand is lowered.
    prob = EarthSciAST._broadcast_fn_problem(expr.fn, length(expr.args))
    prob === nothing || throw(ArgumentError(prob.message))
    fn_name = String(expr.fn)
    fn = get(_BROADCAST_FNS, fn_name, nothing)
    fn === nothing && throw(ArgumentError("Unsupported broadcast fn: $fn_name"))
    operands = [_esm_to_symbolic(a, var_dict, t_sym, dim_dict) for a in expr.args]
    return Base.materialize(Base.broadcasted(fn, operands...))
end

function _build_reshape(
        expr::OpExpr, var_dict::Dict{String, Any},
        t_sym, dim_dict::Dict{String, Any}
    )
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

function _build_transpose(
        expr::OpExpr, var_dict::Dict{String, Any},
        t_sym, dim_dict::Dict{String, Any}
    )
    arr = _esm_to_symbolic(expr.args[1], var_dict, t_sym, dim_dict)
    if expr.perm !== nothing
        # Schema perm is 0-based; Julia permutedims expects 1-based axes.
        perm1 = [p + 1 for p in expr.perm]
        return permutedims(arr, perm1)
    end
    return transpose(arr)
end

function _build_concat(
        expr::OpExpr, var_dict::Dict{String, Any},
        t_sym, dim_dict::Dict{String, Any}
    )
    expr.axis === nothing && throw(ArgumentError("concat node missing 'axis'"))
    arrs = [_esm_to_symbolic(a, var_dict, t_sym, dim_dict) for a in expr.args]
    return cat(arrs...; dims = expr.axis + 1)
end

function _get_or_make_dim(dim_dict::Dict{String, Any}, name::AbstractString)
    if haskey(dim_dict, name)
        return dim_dict[name]
    end
    v = Symbolics.variable(Symbol(name))
    dim_dict[String(name)] = v
    return v
end
