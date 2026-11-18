# ========================================
# ESM ASTExpr → Symbolics conversion
# ========================================

# The stencil gather context `_build_arrayop_sym` installs while it lowers an
# arrayop body: the output index variables (`name => (pool var, physical lo,
# length, step)`) in table-axis order. `_build_index` reads it to turn an
# affine neighbour read into a numeric per-cell gather table (arrayop.jl).
struct _GatherCtx
    out_vars::Dict{String, Tuple{Any, Int, Int, Int}}
    out_order::Vector{String}
end

"""
    _Lowering

Everything the ODE lowering reads besides the expression itself:

- `vars`: ESM name => symbolic variable (states, parameters, observeds, and an
  arrayop's index variables while its body is lowered, see `_with_bindings`);
- `t`: the time symbol;
- `extents`: index-set sizes, which decode an `IndexSetRef` range;
- `const_arrays`: observeds defined by a `const` array, read as literal data;
- `gather`: the stencil gather context while an arrayop body is lowered.
"""
mutable struct _Lowering
    vars::Dict{String, Any}
    t::Any
    extents::Dict{String, Int}
    const_arrays::Dict{String, Array{Float64}}
    gather::Union{Nothing, _GatherCtx}
end

_Lowering(
    vars::Dict{String, Any}, t;
    extents::AbstractDict = Dict{String, Int}(),
    const_arrays::AbstractDict = Dict{String, Array{Float64}}()
) = _Lowering(
    vars, t, Dict{String, Int}(extents),
    Dict{String, Array{Float64}}(const_arrays), nothing
)

# Run `f()` with `pairs` (name => value) bound in `L.vars`, restoring whatever
# those names held before.
function _with_bindings(f, L::_Lowering, pairs)
    saved = Dict{String, Any}()
    for (k, v) in pairs
        haskey(L.vars, k) && (saved[k] = L.vars[k])
        L.vars[k] = v
    end
    try
        return f()
    finally
        for (k, _) in pairs
            haskey(saved, k) ? (L.vars[k] = saved[k]) : delete!(L.vars, k)
        end
    end
end

# Run `f()` with the stencil gather context `ctx` installed.
function _with_gather(f, L::_Lowering, ctx::_GatherCtx)
    prev = L.gather
    L.gather = ctx
    try
        return f()
    finally
        L.gather = prev
    end
end

"""
    _esm_to_symbolic(expr, L::_Lowering)

Build a Symbolics.jl expression from an ESM `ASTExpr` tree under the lowering
context `L`. The registry's scalar operators lower in the shared
`_esm_to_symbolic_core` (ext/shared/esm_to_symbolic.jl); everything MTK-
specific — `D`, `Pre` and the array vocabulary — is handled by
`_mtk_extended_op` below.
"""
function _esm_to_symbolic(expr::EsmExpr, L::_Lowering)
    return _esm_to_symbolic_core(
        expr,
        a -> _esm_to_symbolic(a, L);
        number_value = _int_promoted_number,
        resolve_var = name -> _resolve_lowering_var(name, L),
        extended_op = (op, e) -> _mtk_extended_op(op, e, L)
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

# Unknown-variable policy of the ODE lowering: variables must already be
# declared (a state, parameter, observed or bound index variable, or the time
# symbol) — THROW otherwise. The Catalyst rate lowering auto-creates instead;
# the divergence is live behavior (see ext/shared/esm_to_symbolic.jl).
function _resolve_lowering_var(name::String, L::_Lowering)
    if haskey(L.vars, name)
        return L.vars[name]
    elseif name == "t"
        return L.t
    else
        throw(SimulateError("Variable '$(name)' not found in variable dictionary", ERROR_CODES.UNDEFINED_VARIABLE))
    end
end

# The arms of `_mtk_extended_op` below.
const _MTK_EXTENDED_OPS = (
    "D", "Pre", "faq", "makearray", "index", "broadcast", "reshape", "transpose",
    "concat", "const",
)

# Every operator `_esm_to_symbolic` lowers: the shared scalar vocabulary and the
# MTK arms. `compiler = :mtk` reads it to refuse an operator by name before the
# system is built.
const _MTK_LOWERED_OPS = union(_SYMBOLIC_SCALAR_OPS, Set{String}(_MTK_EXTENDED_OPS))

# The MTK-specific OpExpr arms: the time derivative, `Pre` and the
# array/aggregate vocabulary. Reached from `_esm_to_symbolic_core` for every op
# outside the shared scalar vocabulary.
function _mtk_extended_op(op::AbstractString, expr::OpExpr, L::_Lowering)
    if op == "D"
        # Only the time derivative lowers. A spatial `D` is a rewrite target
        # that a discretization rule must replace before a system is built.
        wrt_name = expr.wrt === nothing ? "t" : expr.wrt
        wrt_name == "t" || throw(
            SimulateError(
                "D(wrt = \"$(wrt_name)\") is a spatial derivative with no " *
                    "ModelingToolkit lowering: discretize it (a `faq` stencil over " *
                    "an index set) before building the system",
                ERROR_CODES.UNLOWERED_OPERATOR
            )
        )
        return Differential(L.t)(_esm_to_symbolic(expr.args[1], L))
    elseif op == "Pre"
        arg = _esm_to_symbolic(expr.args[1], L)
        return ModelingToolkit.Pre(arg)
    elseif op == "faq"
        return _build_arrayop_sym(expr, L)
    elseif op == "makearray"
        return _build_makearray(expr, L)
    elseif op == "index"
        return _build_index(expr, L)
    elseif op == "broadcast"
        return _build_broadcast(expr, L)
    elseif op == "reshape"
        return _build_reshape(expr, L)
    elseif op == "transpose"
        return _build_transpose(expr, L)
    elseif op == "concat"
        return _build_concat(expr, L)
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
            SimulateError(
                "`const` with a $(typeof(expr.value)) value has no " *
                    "MTK lowering (esm-spec §9.2)",
                ERROR_CODES.UNSUPPORTED_CONSTRUCT
            )
        )
    else
        throw(SimulateError("Unsupported operator: $op", ERROR_CODES.UNSUPPORTED_CONSTRUCT))
    end
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
        expr::OpExpr, L::_Lowering
    )
    expr.regions === nothing && throw(SimulateError("makearray node missing 'regions'", ERROR_CODES.UNSUPPORTED_CONSTRUCT))
    expr.values === nothing && throw(SimulateError("makearray node missing 'values'", ERROR_CODES.UNSUPPORTED_CONSTRUCT))
    length(expr.regions) == length(expr.values) ||
        throw(SimulateError("makearray regions and values length mismatch", ERROR_CODES.UNSUPPORTED_CONSTRUCT))

    nd = length(expr.regions[1])
    sz = fill(0, nd)
    for region in expr.regions
        length(region) == nd || throw(SimulateError("makearray regions must all share ndims", ERROR_CODES.UNSUPPORTED_CONSTRUCT))
        for (axis, pair) in enumerate(region)
            pair[1] >= 1 || throw(SimulateError("makearray regions must be 1-based", ERROR_CODES.UNSUPPORTED_CONSTRUCT))
            sz[axis] = max(sz[axis], pair[2])
        end
    end

    result = Array{Symbolics.Num}(undef, sz...)
    fill!(result, Symbolics.Num(0))
    for (region, val_expr) in zip(expr.regions, expr.values)
        v = _esm_to_symbolic(val_expr, L)
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
        SimulateError(
            "makearray region of size $(region_size) cannot take an " *
                "array value of size $(size(vals))",
            ERROR_CODES.ARRAY_SHAPE_MISMATCH
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

# Every observed defined by a `const` array, so a gather on its name reads the
# literal data rather than the symbolic array variable.
function _const_array_observeds(flat)
    registry = Dict{String, Array{Float64}}()
    for eq in flat.equations
        (eq.lhs isa VarExpr && eq.rhs isa OpExpr) || continue
        rhs = eq.rhs::OpExpr
        (rhs.op == "const" && rhs.value isa AbstractVector) || continue
        registry[(eq.lhs::VarExpr).name] = EarthSciAST._const_op_to_array(rhs.value)
    end
    return registry
end

# `(table, name)` when `base` is a const-array gather base, else `(nothing, "")`.
function _const_index_base(base::EsmExpr, L::_Lowering)
    if base isa OpExpr && base.op == "const" && base.value isa AbstractVector
        return EarthSciAST._const_op_to_array(base.value), "inline const"
    elseif base isa VarExpr && haskey(L.const_arrays, base.name)
        return L.const_arrays[base.name], base.name
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
        idx_args::AbstractVector, L::_Lowering
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
        v = _esm_to_symbolic(a, L)
        # `Num <: Real`, so test the unwrapped value: only a NUMBER resolves now.
        n = Symbolics.value(v)
        if n isa Real
            isinteger(n) || throw(
                SimulateError(
                    "index argument must be an integer, got $(n)",
                    ERROR_CODES.UNSUPPORTED_CONSTRUCT
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
        SimulateError(
            "MTK lowering gathers a const array of at most 3 dimensions at a " *
                "run-time index; '$(name)' has $(ndims(table))",
            ERROR_CODES.UNSUPPORTED_CONSTRUCT
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
    catch err
        EarthSciAST._is_resource_error(err) && rethrow()
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
            SimulateError(
                "`const` array of size $(size(rhs)) defines a variable of size $(size(lhs))",
                ERROR_CODES.ARRAY_SHAPE_MISMATCH
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
        expr::OpExpr, L::_Lowering
    )
    # A const-array gather (CONFORMANCE_SPEC §5.5.5) never takes the zero ghost
    # below, so it is routed before the operand is lowered.
    table, table_name = _const_index_base(expr.args[1], L)
    table === nothing ||
        return _build_const_gather(table, table_name, expr.args[2:end], L)

    arr = _esm_to_symbolic(expr.args[1], L)
    idx_args = expr.args[2:end]

    # Stencil gather path: inside a stencil arrayop body, when this
    # read's indices are all affine in the output index vars, materialize a
    # numeric per-cell gather table instead of emitting a symbolic index. This
    # keeps boundary reads (e.g. u[i-1, j] at i=1 -> Dirichlet ghost 0) within
    # the 1:N field, so the scalarizer never sees an out-of-bounds index.
    ctx = L.gather
    if ctx !== nothing && arr isa AbstractArray && !isempty(idx_args) &&
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
                SimulateError(
                    "index argument must be an integer, got $(a.value)",
                    ERROR_CODES.UNSUPPORTED_CONSTRUCT
                )
            )
            push!(idxs, Int(a.value))
        else
            push!(idxs, _esm_to_symbolic(a, L))
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
# `max`/`atan2`). Deriving it keeps this back end and the tree walk speaking the
# same `fn` vocabulary (esm-spec §4.3.4).
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
        expr::OpExpr, L::_Lowering
    )
    # The §4.3.4 `fn` contract, from the SAME predicate `validate()` reports as
    # `invalid_broadcast_fn` and the tree-walk build enforces: a missing /
    # unregistered / structural `fn`, or an operand count outside the named op's
    # registry arity, is rejected before any operand is lowered.
    prob = EarthSciAST._broadcast_fn_problem(expr.fn, length(expr.args))
    prob === nothing || throw(SimulateError(prob.message, ERROR_CODES.INVALID_BROADCAST_FN))
    fn_name = String(expr.fn)
    fn = get(_BROADCAST_FNS, fn_name, nothing)
    fn === nothing && throw(SimulateError("Unsupported broadcast fn: $fn_name", ERROR_CODES.INVALID_BROADCAST_FN))
    operands = [_esm_to_symbolic(a, L) for a in expr.args]
    return Base.materialize(Base.broadcasted(fn, operands...))
end

function _build_reshape(
        expr::OpExpr, L::_Lowering
    )
    expr.shape === nothing && throw(SimulateError("reshape node missing 'shape'", ERROR_CODES.UNSUPPORTED_CONSTRUCT))
    arr = _esm_to_symbolic(expr.args[1], L)
    dims = Int[]
    for entry in expr.shape
        if entry isa Integer
            push!(dims, Int(entry))
        else
            throw(SimulateError("reshape currently only supports integer shape entries, got $(entry)", ERROR_CODES.UNSUPPORTED_CONSTRUCT))
        end
    end
    return Symbolics.reshape(arr, dims...)
end

function _build_transpose(
        expr::OpExpr, L::_Lowering
    )
    arr = _esm_to_symbolic(expr.args[1], L)
    if expr.perm !== nothing
        # Schema perm is 0-based; Julia permutedims expects 1-based axes.
        perm1 = [p + 1 for p in expr.perm]
        return permutedims(arr, perm1)
    end
    return transpose(arr)
end

function _build_concat(
        expr::OpExpr, L::_Lowering
    )
    expr.axis === nothing && throw(SimulateError("concat node missing 'axis'", ERROR_CODES.UNSUPPORTED_CONSTRUCT))
    arrs = [_esm_to_symbolic(a, L) for a in expr.args]
    return cat(arrs...; dims = expr.axis + 1)
end
