# tree_walk/field_ic.jl — a field `ic`'s value per cell: the loaded and constant forms, the
# compiled fast path and the per-cell resolution.

"""
    _field_ic_uniform(target, rhs, rank, const_arrays; params)
        -> ((tier, cell -> value) or nothing, attempts)

Steps (1) and (2) of [`_resolve_field_ic`](@ref), the two forms whose value does
not depend on the cell, answered once for a field of rank `rank`: a LOADED FIELD
(`:setup_loaded`) or a BROADCAST CONSTANT (`:setup_constant`). `nothing` when
neither serves, with `attempts` recording why the constant form failed, for the
diagnostic step (4) raises if no later form serves either. A loaded field whose
rank matches neither the grid nor a single element raises here.
"""
function _field_ic_uniform(
        target::AbstractString, rhs::EarthSciAST.ASTExpr,
        rank::Int, const_arrays;
        params::AbstractDict = _EMPTY_PARAMS
    )
    # (1) Loaded field supplied as a const array over the lifted grid.
    if rhs isa VarExpr && haskey(const_arrays, rhs.name)
        arr = const_arrays[rhs.name]
        ndims(arr) == rank && return (
            (:setup_loaded, cell -> Float64(arr[cell...])),
            String[],
        )
        if length(arr) == 1
            v = Float64(first(arr))
            return ((:setup_loaded, _ -> v), String[])
        end
        throw(
            TreeWalkError(
                "E_TREEWALK_UNSUPPORTED_EQUATION",
                "ic($(target)): loaded field '$(rhs.name)' has ndims=$(ndims(arr)) " *
                    "which does not match the $(rank)-D lifted target grid"
            )
        )
    end
    # (2) Broadcast constant (scalar model PARAMETERS in scope as load-time
    # constants; STATE is not — `params` carries only resolved scalar params).
    # A failure here is a fall-through attempt, not final: it is recorded and
    # attached to the step-(4) diagnostic so the reason the form was rejected is
    # never silently swallowed.
    try
        v = Float64(evaluate_expr(rhs, params))
        return ((:setup_constant, _ -> v), String[])
    catch err
        # A resource error is not a reason to try the NEXT form — the next form
        # allocates too — and step (4) would rebrand it as a statement about
        # this RHS. Out, unwrapped.
        _is_resource_error(err) && rethrow()
        return (nothing, String["as constant: $(sprint(showerror, err))"])
    end
end

"""
    _resolve_field_ic(access, target, rhs, cell, const_arrays) -> Float64

Resolve one grid cell's initial value for a scoped-reference / array `ic`
equation (spec §11.4.1). `cell` is the 1-based integer index tuple of the
element. Supported RHS forms, in order:

1. A LOADED FIELD — a bare reference to a `const_arrays` entry that supplies the
   initial field over the lifted grid. The cell is read directly when the field's
   rank matches the target grid; a single-element field is broadcast.
2. A BROADCAST CONSTANT — an RHS that const-folds to a scalar applied to every
   cell.
3. A COORDINATE EXPRESSION — an elementwise expression over array-producing
   `faq`/`makearray` nodes (e.g. `cos(pi * x_coord)` where `x_coord` is a
   grid-geometry aggregate expanded from a §9.7 template import). The expression
   is indexed at this cell ([`_index_at_cell`](@ref)) and folded through the
   standard `_resolve_indices` + `_compile` build-time machinery.

Anything else (e.g. a loaded expression the seed path cannot fold) is a hard
error, so a scoped-reference ic that cannot be resolved is never silently
dropped.

Step 3 resolves and compiles once per cell, so `access` is a `_PerCellLicense`
or a refusal's one-cell probe (compiler.jl).
"""
function _resolve_field_ic(
        access::_PerCellAccess, target::AbstractString,
        rhs::EarthSciAST.ASTExpr,
        cell::Vector{Int}, const_arrays;
        params::AbstractDict = _EMPTY_PARAMS,
        uniform = _field_ic_uniform(
            target, rhs, length(cell),
            const_arrays;
            params = params
        )
    )::Float64
    # (1) and (2) do not depend on the cell: `uniform` is their verdict, which a
    # caller seeding a whole field computes once and passes for every cell.
    hit, attempts = uniform
    hit === nothing || return Float64(hit[2](cell))
    _errs = copy(attempts)
    # (3) Coordinate expression over the grid geometry (per-cell field); model
    # parameters (e.g. a free-name geometry `x0`/`dx`) bind via `params`.
    if rhs isa OpExpr
        # THE per-cell step: `_eval_cellwise` re-runs `_index_at_cell` →
        # `_resolve_indices` → `_compile` for this one cell, so seeding a field
        # costs one whole lowering per cell. Steps (1) and (2) above do not.
        v = try
            _eval_cellwise(
                access, rhs, cell; const_arrays = const_arrays,
                params = params
            )
        catch err
            _is_resource_error(err) && rethrow()
            # A cell-assigning `faq` is only ever a coordinate expression: its
            # own refusal (an out-of-range gather, say) is the document's error,
            # code and all, not a reason to report the forms that never applied.
            _is_cell_faq(rhs) && err isa TreeWalkError &&
                err.code != "E_TREEWALK_UNSUPPORTED_EQUATION" && rethrow()
            push!(_errs, "as coordinate expression: $(sprint(showerror, err))")
            nothing
        end
        v === nothing || return v
    end
    # (4) Unsupported RHS — a clear error, never a silent drop.
    _fld = rhs isa VarExpr ? " (no const_arrays entry named '$(rhs.name)')" : ""
    _why = isempty(_errs) ? "" : "; attempts failed — " * join(_errs, "; ")
    throw(
        TreeWalkError(
            "E_TREEWALK_UNSUPPORTED_EQUATION",
            "ic($(target)): RHS is neither a loaded const-array field, a constant, " *
                "nor a per-cell coordinate expression$(_fld); supply the initial field " *
                "via const_arrays or a grid-geometry expression$(_why)"
        )
    )
end

const _NO_STATE_U = Float64[]

# A field-ic RHS body is "closed form" iff it has no gather / array-producer node
# that would need per-cell index resolution — every op is scalar-computable with
# the loop indices bound as parameters. Reduction bounds / filters / table axes /
# ranges on an inner node are conservatively rejected.
function _ic_body_is_closed_form(e)::Bool
    e isa OpExpr || return true
    _is_self_indexed_op(e.op) && return false
    _is_array_producer(e) && return false
    (
        e.lower !== nothing || e.upper !== nothing || e.filter !== nothing ||
            e.key !== nothing || e.ranges !== nothing
    ) && return false
    for a in _operands(e)
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

# Compile-once fast path for a coordinate-field ic: a `faq` over the output
# loop indices whose body is closed form (see above), compiled once with the
# loop indices bound as parameters (`_cell_evaluator`) instead of resolved and
# compiled per cell. A loop index bound as a `Float64` parameter equals that
# index folded to a literal, so the values are the per-cell path's. Returns the
# `_CellEval` (called with the cell), or `nothing` for the per-cell fallback.
function _try_field_ic_fastpath(
        rhs, params::AbstractDict, const_arrays
    )
    rhs isa OpExpr || return nothing
    (rhs.op == "faq") || return nothing
    (rhs.join_gates === nothing && rhs.filter === nothing) || return nothing
    body = rhs.expr_body
    body === nothing && return nothing
    oi_raw = rhs.output_idx === nothing ? Any[] : rhs.output_idx
    all(s -> s isa AbstractString, oi_raw) || return nothing
    oi = String[String(s) for s in oi_raw]
    isempty(oi) && return nothing
    # Non-contracting: every declared range index is an output index (a contracted
    # index would need reduction, not a single per-cell value).
    ranges = rhs.ranges === nothing ? Dict{String, Any}() : rhs.ranges
    all(n -> n in oi, keys(ranges)) || return nothing
    _ic_body_is_closed_form(body) || return nothing
    return _cell_evaluator(body, oi, const_arrays, params; index_outputs = false)
end
