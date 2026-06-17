# Symbolic ArrayOp assembly (esm-tet).
#
# Ported from EarthSciDiscretizations/src/discretization.jl, refactored against
# the esm-a3z `AbstractCurvilinearGrid` trait. Every function here takes a
# trait-typed grid and queries it only through bulk-array methods
# (`metric_ginv`, `metric_jacobian`, `coord_jacobian`,
# `coord_jacobian_second`, `neighbor_indices`, `cell_widths`, `n_cells`).
# No struct-field access (no `grid.J`, no `grid.dξ`, no concrete grid type).
#
# Under the trait, periodic / unstructured topology is hidden inside
# `neighbor_indices`, which returns flat indices. So the trait-based "ghost
# extension" is a per-cell stencil-point gather table: `u_ext[c, k]` is
# `u_sym` evaluated at the k-th stencil point of flat cell `c`. Indexing is
# flat `(c, k)` and works for every grid family the trait covers.
#
# Stencil point conventions (matching the numeric `FVLaplacianStencil` /
# `FVGradientStencil` packed-column layout):
#   Laplacian (K=9): 1=C, 2=E (+ξ), 3=W (-ξ), 4=N (+η), 5=S (-η),
#                    6=NE, 7=NW, 8=SE, 9=SW
#   Gradient  (K=5): 1=C, 2=E, 3=W, 4=N, 5=S
#
# Symbolics-API note: written against the SymbolicUtils v4 / Symbolics v7
# API (`SymbolicUtils.SymReal`, `SymbolicUtils.idxs_for_arrayop`,
# `SymbolicUtils.Const`, `SymbolicUtils.ArrayOp`). This is what
# `Project.toml` declares as compatible (`Symbolics = "7"`) and what
# `Pkg.test` resolves to. ESD uses the same API.

# ---------------------------------------------------------------------------
# ArrayOp utilities (ported from ESD src/operators/arrayop_utils.jl)
# ---------------------------------------------------------------------------

const SymReal = SymUtils.SymReal
const ConstSR = SymUtils.Const{SymReal}

"""
    const_wrap(arr) -> Const{SymReal}

Wrap a numerical or symbolic array in `SymbolicUtils.Const{SymReal}` so it
can be indexed inside an ArrayOp body with the shared `SymReal` integer
indices returned by `get_idx_vars`.
"""
const_wrap(arr) = ConstSR(arr)

"""
    get_idx_vars(ndim) -> Vector

Get `ndim` symbolic integer index variables from the shared ArrayOp index
pool (`SymbolicUtils.idxs_for_arrayop(SymReal)`). All ArrayOps in this
package draw indices from this pool so indices interoperate cleanly when
ArrayOps are composed.
"""
function get_idx_vars(ndim::Int)
    idxs_arr = SymUtils.idxs_for_arrayop(SymReal)
    return [idxs_arr[d] for d in 1:ndim]
end

"""
    make_arrayop(idx_vars, expr, ranges) -> ArrayOp{SymReal}

Construct a `SymbolicUtils.ArrayOp{SymReal}` over `idx_vars` with the given
body expression and per-index ranges. Reduction op is `+` (matches all
existing ArrayOp uses in this package).
"""
function make_arrayop(idx_vars, expr, ranges)
    return SymUtils.ArrayOp{SymReal}(idx_vars, Symbolics.unwrap(expr),
        +, nothing, ranges)
end

"""
    evaluate_arrayop(ao) -> Array{Float64}

Evaluate an ArrayOp built from `Const`-wrapped numeric data by iterating over
the output index range and substituting each concrete index value. Returns a
`Float64` vector. For tests and validation; production callers should keep the
ArrayOp symbolic and let MTK compile it.
"""
function evaluate_arrayop(ao)
    c = ao.output_idx[1]
    rng = ao.ranges[c]
    result = Array{Float64}(undef, length(rng))
    for (i, c_val) in enumerate(rng)
        val = SymUtils.substitute(ao.expr, Dict(c => c_val); fold = Val{true}())
        result[i] = Float64(Symbolics.value(val))
    end
    return result
end

# ---------------------------------------------------------------------------
# Neighbor / stencil-table assembly (trait-only)
# ---------------------------------------------------------------------------

@inline _sentinel_or_self(n::Int, s::Int) = n == 0 ? s : n

"""
    laplacian_neighbor_table(grid; xi_axis=:xi, eta_axis=:eta) -> Matrix{Int}

Build the `(N, 9)` neighbor table for the 9-point Laplacian stencil under
the Grid trait. Column order: C, E, W, N, S, NE, NW, SE, SW.
"""
function laplacian_neighbor_table(grid::AbstractCurvilinearGrid;
        xi_axis::Symbol = :xi, eta_axis::Symbol = :eta)
    N = n_cells(grid)
    self = collect(1:N)
    nb_E = neighbor_indices(grid, xi_axis, +1)
    nb_W = neighbor_indices(grid, xi_axis, -1)
    nb_N = neighbor_indices(grid, eta_axis, +1)
    nb_S = neighbor_indices(grid, eta_axis, -1)
    E = map(_sentinel_or_self, nb_E, self)
    W = map(_sentinel_or_self, nb_W, self)
    Np = map(_sentinel_or_self, nb_N, self)
    Sp = map(_sentinel_or_self, nb_S, self)

    NE = neighbor_indices(grid, eta_axis, +1)[E]
    NW = neighbor_indices(grid, eta_axis, +1)[W]
    SE = neighbor_indices(grid, eta_axis, -1)[E]
    SW = neighbor_indices(grid, eta_axis, -1)[W]
    NE = map(_sentinel_or_self, NE, self)
    NW = map(_sentinel_or_self, NW, self)
    SE = map(_sentinel_or_self, SE, self)
    SW = map(_sentinel_or_self, SW, self)

    nb = Matrix{Int}(undef, N, 9)
    nb[:, 1] .= self
    nb[:, 2] .= E
    nb[:, 3] .= W
    nb[:, 4] .= Np
    nb[:, 5] .= Sp
    nb[:, 6] .= NE
    nb[:, 7] .= NW
    nb[:, 8] .= SE
    nb[:, 9] .= SW
    return nb
end

"""
    gradient_neighbor_table(grid; xi_axis=:xi, eta_axis=:eta) -> Matrix{Int}

Build the `(N, 5)` neighbor table for the 5-point gradient stencil.
Column order: C, E, W, N, S.
"""
function gradient_neighbor_table(grid::AbstractCurvilinearGrid;
        xi_axis::Symbol = :xi, eta_axis::Symbol = :eta)
    N = n_cells(grid)
    self = collect(1:N)
    nb_E = neighbor_indices(grid, xi_axis, +1)
    nb_W = neighbor_indices(grid, xi_axis, -1)
    nb_N = neighbor_indices(grid, eta_axis, +1)
    nb_S = neighbor_indices(grid, eta_axis, -1)

    nb = Matrix{Int}(undef, N, 5)
    nb[:, 1] .= self
    nb[:, 2] .= map(_sentinel_or_self, nb_E, self)
    nb[:, 3] .= map(_sentinel_or_self, nb_W, self)
    nb[:, 4] .= map(_sentinel_or_self, nb_N, self)
    nb[:, 5] .= map(_sentinel_or_self, nb_S, self)
    return nb
end

"""
    _build_symbolic_ghost_extension(u_sym, neighbor_table) -> Array{Any}

Per-cell stencil-point gather table from a flat field array `u_sym` and
the K-point `neighbor_table`. Returns `(N, K) Array{Any}` of `unwrap`'d
expressions: `out[c, k] = unwrap(u_sym[neighbor_table[c, k]])`.

Boundary-crossing references are resolved inside `neighbor_indices`, so this
helper is grid-family-agnostic.
"""
function _build_symbolic_ghost_extension(u_sym::AbstractVector,
        neighbor_table::AbstractMatrix{Int})
    N, K = size(neighbor_table)
    length(u_sym) == N || throw(DimensionMismatch(
        "_build_symbolic_ghost_extension: length(u_sym)=$(length(u_sym)) ≠ N=$N"))

    # Element-type policy: a purely-numeric `u_sym` produces a `Matrix{Float64}`
    # so that `Const{SymReal}(out)` indexing carries `symtype = Float64`,
    # which arithmetic-combines with the `Float64` stencil weights inside
    # the ArrayOp body. A symbolic `u_sym` produces a `Matrix{Any}` of
    # `unwrap`'d expressions, matching the ESD source convention.
    is_numeric = eltype(u_sym) <: AbstractFloat || eltype(u_sym) <: Integer
    if is_numeric
        out = Array{Float64}(undef, N, K)
        @inbounds for c in 1:N, k in 1:K
            out[c, k] = Float64(u_sym[neighbor_table[c, k]])
        end
        return out
    else
        out = Array{Any}(undef, N, K)
        @inbounds for c in 1:N, k in 1:K
            out[c, k] = Symbolics.unwrap(u_sym[neighbor_table[c, k]])
        end
        return out
    end
end

# ---------------------------------------------------------------------------
# Symbolic Laplacian and gradient (ArrayOp form, trait-only)
# ---------------------------------------------------------------------------

"""
    fv_laplacian_extended(u_sym, grid::AbstractCurvilinearGrid;
                          xi_axis=:xi, eta_axis=:eta) -> ArrayOp{SymReal}

Build a `SymbolicUtils.ArrayOp{SymReal}` for the full covariant Laplacian
on `AbstractCurvilinearGrid`, operating on a flat field array `u_sym` of
length `n_cells(grid)`. Output is a 1-D ArrayOp indexed by flat cell `c`.

Reuses the numeric `precompute_laplacian_stencil(grid)` for weight assembly,
then composes a symbolic 9-point sum:

    ∇²u[c] = Σ_{k=1..9} weights[c, k] · u_sym[neighbor_table[c, k]]

The full covariant Laplacian (orthogonal `g^ξξ`/`g^ηη` part + cross-metric
`g^ξη` correction + first-derivative metric corrections) is encoded in the
precomputed weight array; see `precompute_laplacian_stencil` docstring for
the algebraic form.
"""
function fv_laplacian_extended(u_sym::AbstractVector,
        grid::AbstractCurvilinearGrid;
        xi_axis::Symbol = :xi, eta_axis::Symbol = :eta)
    stencil = precompute_laplacian_stencil(grid; xi_axis = xi_axis, eta_axis = eta_axis)
    nb = stencil.neighbors
    N = size(nb, 1)
    length(u_sym) == N || throw(DimensionMismatch(
        "fv_laplacian_extended: length(u_sym)=$(length(u_sym)) ≠ n_cells(grid)=$N"))

    return _stencil_arrayop(u_sym, nb, stencil.weights)
end

"""
    fv_gradient_extended(u_sym, grid::AbstractCurvilinearGrid, target::Symbol;
                         xi_axis=:xi, eta_axis=:eta)
        -> (ArrayOp{SymReal}, ArrayOp{SymReal})

Build two `SymbolicUtils.ArrayOp{SymReal}`s for the gradient
`(∂u/∂t1, ∂u/∂t2)` in the physical `target` coordinate system, where
`target` is passed through to `coord_jacobian(grid, target)`. Operates on a
flat field array `u_sym` of length `n_cells(grid)`.

The chain rule `∂u/∂t = (∂ξ/∂t)·∂u/∂ξ + (∂η/∂t)·∂u/∂η` is encoded in the
precomputed weight arrays from `precompute_gradient_stencil`.
"""
function fv_gradient_extended(u_sym::AbstractVector,
        grid::AbstractCurvilinearGrid, target::Symbol;
        xi_axis::Symbol = :xi, eta_axis::Symbol = :eta)
    stencil = precompute_gradient_stencil(grid, target;
        xi_axis = xi_axis, eta_axis = eta_axis)
    nb = stencil.neighbors
    N = size(nb, 1)
    length(u_sym) == N || throw(DimensionMismatch(
        "fv_gradient_extended: length(u_sym)=$(length(u_sym)) ≠ n_cells(grid)=$N"))

    return (_stencil_arrayop(u_sym, nb, stencil.weights_t1),
            _stencil_arrayop(u_sym, nb, stencil.weights_t2))
end

# Build a 1-D ArrayOp over flat cell `c`: `du[c] = Σ_k weights[c, k] · u_ext[c, k]`,
# with the K-sum unrolled (the ArrayOp body must already be a scalar in `c`).
function _stencil_arrayop(u_sym, neighbor_table, weights)
    N, K = size(neighbor_table)
    u_ext = _build_symbolic_ghost_extension(u_sym, neighbor_table)

    idx = get_idx_vars(1); c = idx[1]
    w_c = const_wrap(weights)
    u_c = const_wrap(u_ext)

    expr = Symbolics.wrap(w_c[c, 1]) * Symbolics.wrap(u_c[c, 1])
    for k in 2:K
        expr += Symbolics.wrap(w_c[c, k]) * Symbolics.wrap(u_c[c, k])
    end

    return make_arrayop(idx, Symbolics.unwrap(expr), Dict(c => 1:1:N))
end

# ---------------------------------------------------------------------------
# PDE-RHS → ArrayOp (recursive, trait-only)
#
# Trait port of ESD's `_build_rhs_arrayop` / `_rhs_to_arrayop_expr` /
# `_eval_at_gridpoint` / `_arrayop_chain_coeffs` / `_arrayop_second_chain_coeffs`
# / `_match_dv`. The recursion shape is unchanged; what changes is:
#
# * Per-cell stencil-point evaluation uses the flat `(c, k)` gather table
#   built from `neighbor_indices` instead of multi-axis offset access into a
#   ghost-extended array.
# * Chain-rule coefficients query `coord_jacobian(grid, target)` and
#   `coord_jacobian_second(grid, target)` instead of `grid.dξ_dlon` etc.
# ---------------------------------------------------------------------------

const _STENCIL_K_C  = 1
const _STENCIL_K_E  = 2
const _STENCIL_K_W  = 3
const _STENCIL_K_N  = 4
const _STENCIL_K_S  = 5
const _STENCIL_K_NE = 6
const _STENCIL_K_NW = 7
const _STENCIL_K_SE = 8
const _STENCIL_K_SW = 9

function _stencil_k(di::Int, dj::Int)
    if     di == 0 && dj == 0; return _STENCIL_K_C
    elseif di == +1 && dj == 0; return _STENCIL_K_E
    elseif di == -1 && dj == 0; return _STENCIL_K_W
    elseif di == 0 && dj == +1; return _STENCIL_K_N
    elseif di == 0 && dj == -1; return _STENCIL_K_S
    elseif di == +1 && dj == +1; return _STENCIL_K_NE
    elseif di == -1 && dj == +1; return _STENCIL_K_NW
    elseif di == +1 && dj == -1; return _STENCIL_K_SE
    elseif di == -1 && dj == -1; return _STENCIL_K_SW
    else
        throw(ArgumentError("_stencil_k: offset ($di, $dj) is not in the 9-point neighborhood"))
    end
end

function _match_dv(expr, dvs)
    for dv in dvs
        if isequal(Symbolics.wrap(expr), dv)
            return dv
        end
    end
    if Symbolics.iscall(expr)
        name = Symbol(Symbolics.tosymbol(Symbolics.wrap(expr), escape = false))
        for dv in dvs
            dv_name = Symbol(Symbolics.tosymbol(dv, escape = false))
            if name == dv_name
                return dv
            end
        end
    end
    return nothing
end

"""
Evaluate a symbolic expression at a stencil-point offset `(di, dj)` from
the current cell `c`. Each dependent variable in the expression is replaced
by the corresponding entry in `gather_tables[dv]` at column `k = _stencil_k(di, dj)`.

`gather_tables` is `Dict{dv => Const{SymReal}}` produced by
`const_wrap(_build_symbolic_ghost_extension(u_sym[dv], laplacian_neighbor_table(grid)))`.
"""
function _eval_at_gridpoint(expr, dvs, gather_tables, c_idx, di::Int, dj::Int)
    ex = Symbolics.unwrap(expr)
    k = _stencil_k(di, dj)

    if !Symbolics.iscall(ex)
        return Symbolics.wrap(ex)
    end

    dv = _match_dv(ex, dvs)
    if dv !== nothing
        u_c = gather_tables[dv]
        return Symbolics.wrap(u_c[c_idx, k])
    end

    op = Symbolics.operation(ex); args = Symbolics.arguments(ex)
    new_args = [Symbolics.unwrap(_eval_at_gridpoint(Symbolics.wrap(a), dvs, gather_tables, c_idx, di, dj))
                for a in args]
    return Symbolics.wrap(op(new_args...))
end

# Identify the dimension symbol for a Differential. Returns a tag in
# `(:t1, :t2, :xi, :eta)`. The two named target axes are caller-supplied so
# this helper is trait-agnostic.
function _identify_dim(diff_x, target_axes::NTuple{2, Symbol})
    name = Symbol(diff_x)
    if name === target_axes[1]
        return :t1
    elseif name === target_axes[2]
        return :t2
    elseif name === :xi
        return :xi
    elseif name === :eta
        return :eta
    else
        throw(ArgumentError("_identify_dim: differential w.r.t. $name not recognised; expected one of $(target_axes), :xi, :eta"))
    end
end

# Chain-rule coefficients (∂ξ/∂t, ∂η/∂t) for a single derivative, returned
# as scalar terms at flat cell `c_idx`.
function _arrayop_chain_coeffs(dim::Symbol, c_idx,
        cj_t1xi, cj_t1eta, cj_t2xi, cj_t2eta)
    if dim === :t1
        return (Symbolics.wrap(cj_t1xi[c_idx]), Symbolics.wrap(cj_t1eta[c_idx]))
    elseif dim === :t2
        return (Symbolics.wrap(cj_t2xi[c_idx]), Symbolics.wrap(cj_t2eta[c_idx]))
    elseif dim === :xi
        return (Symbolics.wrap(Symbolics.value(1.0)), Symbolics.wrap(Symbolics.value(0.0)))
    elseif dim === :eta
        return (Symbolics.wrap(Symbolics.value(0.0)), Symbolics.wrap(Symbolics.value(1.0)))
    end
    return (Symbolics.wrap(Symbolics.value(0.0)), Symbolics.wrap(Symbolics.value(0.0)))
end

# Second-derivative chain-rule correction (∂²ξ/∂t1∂t2, ∂²η/∂t1∂t2).
function _arrayop_second_chain_coeffs(dim_outer::Symbol, dim_inner::Symbol, c_idx,
        cjs_t11_xi, cjs_t11_eta, cjs_t22_xi, cjs_t22_eta, cjs_t12_xi, cjs_t12_eta)
    if dim_outer === :t1 && dim_inner === :t1
        return (Symbolics.wrap(cjs_t11_xi[c_idx]), Symbolics.wrap(cjs_t11_eta[c_idx]))
    elseif dim_outer === :t2 && dim_inner === :t2
        return (Symbolics.wrap(cjs_t22_xi[c_idx]), Symbolics.wrap(cjs_t22_eta[c_idx]))
    elseif (dim_outer === :t1 && dim_inner === :t2) || (dim_outer === :t2 && dim_inner === :t1)
        return (Symbolics.wrap(cjs_t12_xi[c_idx]), Symbolics.wrap(cjs_t12_eta[c_idx]))
    end
    return (Symbolics.wrap(Symbolics.value(0.0)), Symbolics.wrap(Symbolics.value(0.0)))
end

"""
    _RhsContext

Holds the shared per-grid arrays used by the recursive RHS lowering: the
per-DV gather tables, the chain-rule coordinate-Jacobian arrays, and the
computational widths `(dξ, dη)`. Built once per `_build_rhs_arrayop` call
and threaded through `_rhs_to_arrayop_expr` to avoid re-wrapping the same
metric arrays at every recursion level.
"""
struct _RhsContext
    target::Symbol
    target_axes::NTuple{2, Symbol}
    dξ::Float64
    dη::Float64
    gather_tables::Dict{Any, Any}
    cj_t1xi::ConstSR; cj_t1eta::ConstSR
    cj_t2xi::ConstSR; cj_t2eta::ConstSR
    cjs_t11_xi::ConstSR; cjs_t11_eta::ConstSR
    cjs_t22_xi::ConstSR; cjs_t22_eta::ConstSR
    cjs_t12_xi::ConstSR; cjs_t12_eta::ConstSR
end

function _build_rhs_context(grid::AbstractCurvilinearGrid, dvs, u_syms,
        target::Symbol, target_axes::NTuple{2, Symbol};
        xi_axis::Symbol = :xi, eta_axis::Symbol = :eta)
    nb = laplacian_neighbor_table(grid; xi_axis = xi_axis, eta_axis = eta_axis)
    gather_tables = Dict{Any, Any}()
    for dv in dvs
        u_ext = _build_symbolic_ghost_extension(u_syms[dv], nb)
        gather_tables[dv] = const_wrap(u_ext)
    end

    cj  = coord_jacobian(grid, target)
    cjs = coord_jacobian_second(grid, target)

    dξ = Float64(first(cell_widths(grid, xi_axis)))
    dη = Float64(first(cell_widths(grid, eta_axis)))

    return _RhsContext(
        target, target_axes, dξ, dη, gather_tables,
        const_wrap(collect(view(cj, :, 1, 1))),
        const_wrap(collect(view(cj, :, 2, 1))),
        const_wrap(collect(view(cj, :, 1, 2))),
        const_wrap(collect(view(cj, :, 2, 2))),
        const_wrap(collect(view(cjs, :, 1, 1, 1))),
        const_wrap(collect(view(cjs, :, 2, 1, 1))),
        const_wrap(collect(view(cjs, :, 1, 2, 2))),
        const_wrap(collect(view(cjs, :, 2, 2, 2))),
        const_wrap(collect(view(cjs, :, 1, 1, 2))),
        const_wrap(collect(view(cjs, :, 2, 1, 2))),
    )
end

"""
    _rhs_to_arrayop_expr(expr, dvs, ctx::_RhsContext, c_idx, coeff)

Recursively lower a symbolic PDE RHS into a per-cell ArrayOp body.
Recognised structure (mirrors ESD `_rhs_to_arrayop_expr`):
- Numeric constants and variables: pass through with `coeff` folded in.
- `+`, `-`, `*` (numeric × symbolic split): recurse term-by-term.
- `Differential(x)(Differential(y)(f))`: 9-point covariant second derivative
  with chain-rule correction.
- `Differential(x)(f)`: 5-point first derivative with chain rule.
- DV reference: gather at center stencil point.
"""
function _rhs_to_arrayop_expr(expr, dvs, ctx::_RhsContext, c_idx, coeff)
    if !Symbolics.iscall(expr)
        v = Symbolics.value(Symbolics.wrap(expr))
        if v isa Number
            return Symbolics.wrap(Symbolics.value(coeff * Float64(v)))
        end
        return Symbolics.wrap(expr)
    end

    op = Symbolics.operation(expr)
    args = Symbolics.arguments(expr)

    if op === (+)
        result = _rhs_to_arrayop_expr(args[1], dvs, ctx, c_idx, coeff)
        for k in 2:length(args)
            result = result + _rhs_to_arrayop_expr(args[k], dvs, ctx, c_idx, coeff)
        end
        return result
    end

    if op === (-) && length(args) == 1
        return _rhs_to_arrayop_expr(args[1], dvs, ctx, c_idx, -coeff)
    end
    if op === (-) && length(args) == 2
        t1 = _rhs_to_arrayop_expr(args[1], dvs, ctx, c_idx, coeff)
        t2 = _rhs_to_arrayop_expr(args[2], dvs, ctx, c_idx, coeff)
        return t1 - t2
    end

    if op === (*)
        num_coeff = 1.0
        sym_factors = []
        for a in args
            v = Symbolics.value(Symbolics.wrap(a))
            if v isa Number
                num_coeff *= Float64(v)
            else
                push!(sym_factors, a)
            end
        end
        if length(sym_factors) == 1
            return _rhs_to_arrayop_expr(sym_factors[1], dvs, ctx, c_idx, coeff * num_coeff)
        elseif isempty(sym_factors)
            return Symbolics.wrap(Symbolics.value(coeff * num_coeff))
        end
    end

    if op isa Symbolics.Differential
        dim_outer = _identify_dim(op.x, ctx.target_axes)
        inner = args[1]

        if Symbolics.iscall(inner) && Symbolics.operation(inner) isa Symbolics.Differential
            dim_inner = _identify_dim(Symbolics.operation(inner).x, ctx.target_axes)
            innermost = Symbolics.arguments(inner)[1]

            f_c  = _eval_at_gridpoint(innermost, dvs, ctx.gather_tables, c_idx,  0,  0)
            f_e  = _eval_at_gridpoint(innermost, dvs, ctx.gather_tables, c_idx, +1,  0)
            f_w  = _eval_at_gridpoint(innermost, dvs, ctx.gather_tables, c_idx, -1,  0)
            f_n  = _eval_at_gridpoint(innermost, dvs, ctx.gather_tables, c_idx,  0, +1)
            f_s  = _eval_at_gridpoint(innermost, dvs, ctx.gather_tables, c_idx,  0, -1)
            f_ne = _eval_at_gridpoint(innermost, dvs, ctx.gather_tables, c_idx, +1, +1)
            f_nw = _eval_at_gridpoint(innermost, dvs, ctx.gather_tables, c_idx, -1, +1)
            f_se = _eval_at_gridpoint(innermost, dvs, ctx.gather_tables, c_idx, +1, -1)
            f_sw = _eval_at_gridpoint(innermost, dvs, ctx.gather_tables, c_idx, -1, -1)

            dξ = ctx.dξ; dη = ctx.dη
            d2f_dξ2  = (f_e - 2 * f_c + f_w) / dξ^2
            d2f_dη2  = (f_n - 2 * f_c + f_s) / dη^2
            d2f_dξdη = (f_ne - f_nw - f_se + f_sw) / (4 * dξ * dη)
            df_dξ    = (f_e - f_w) / (2 * dξ)
            df_dη    = (f_n - f_s) / (2 * dη)

            a_ξ_o, a_η_o = _arrayop_chain_coeffs(dim_outer, c_idx,
                ctx.cj_t1xi, ctx.cj_t1eta, ctx.cj_t2xi, ctx.cj_t2eta)
            a_ξ_i, a_η_i = _arrayop_chain_coeffs(dim_inner, c_idx,
                ctx.cj_t1xi, ctx.cj_t1eta, ctx.cj_t2xi, ctx.cj_t2eta)
            b_ξ, b_η = _arrayop_second_chain_coeffs(dim_outer, dim_inner, c_idx,
                ctx.cjs_t11_xi, ctx.cjs_t11_eta,
                ctx.cjs_t22_xi, ctx.cjs_t22_eta,
                ctx.cjs_t12_xi, ctx.cjs_t12_eta)

            result = a_ξ_o * a_ξ_i * d2f_dξ2 +
                     (a_ξ_o * a_η_i + a_η_o * a_ξ_i) * d2f_dξdη +
                     a_η_o * a_η_i * d2f_dη2 +
                     b_ξ * df_dξ + b_η * df_dη
            return coeff * result
        end

        # First derivative of general expression.
        f_e = _eval_at_gridpoint(inner, dvs, ctx.gather_tables, c_idx, +1,  0)
        f_w = _eval_at_gridpoint(inner, dvs, ctx.gather_tables, c_idx, -1,  0)
        f_n = _eval_at_gridpoint(inner, dvs, ctx.gather_tables, c_idx,  0, +1)
        f_s = _eval_at_gridpoint(inner, dvs, ctx.gather_tables, c_idx,  0, -1)

        dξ = ctx.dξ; dη = ctx.dη
        df_dξ = (f_e - f_w) / (2 * dξ)
        df_dη = (f_n - f_s) / (2 * dη)

        if dim_outer === :t1
            return coeff * (Symbolics.wrap(ctx.cj_t1xi[c_idx]) * df_dξ +
                            Symbolics.wrap(ctx.cj_t1eta[c_idx]) * df_dη)
        elseif dim_outer === :t2
            return coeff * (Symbolics.wrap(ctx.cj_t2xi[c_idx]) * df_dξ +
                            Symbolics.wrap(ctx.cj_t2eta[c_idx]) * df_dη)
        elseif dim_outer === :xi
            return coeff * df_dξ
        elseif dim_outer === :eta
            return coeff * df_dη
        end
    end

    # DV reference (reaction term) — gather at center.
    dv = _match_dv(expr, dvs)
    if dv !== nothing
        u_c = ctx.gather_tables[dv]
        return coeff * Symbolics.wrap(u_c[c_idx, _STENCIL_K_C])
    end

    return coeff * Symbolics.wrap(expr)
end

"""
    _build_rhs_arrayop(rhs, dvs, u_syms, grid::AbstractCurvilinearGrid;
                       target::Symbol, target_axes::NTuple{2, Symbol},
                       xi_axis=:xi, eta_axis=:eta) -> ArrayOp{SymReal}

Lower a symbolic PDE RHS expression `rhs` into a `SymbolicUtils.ArrayOp{SymReal}`
over flat cells `1:n_cells(grid)`. Trait port of ESD's `_build_rhs_arrayop`.

Arguments:
- `dvs`              — vector of dependent-variable symbols (`u(t,x,y)`, `v(t,x,y)`, …)
- `u_syms`           — `Dict{dv => AbstractVector}` of flat per-cell symbolic field arrays
- `target`           — physical target coordinate system passed to `coord_jacobian`
- `target_axes`      — `(t1_name, t2_name)` matching the `Differential(x)` symbols in `rhs`
                       (e.g. `(:lon, :lat)` or `(:x, :y)`)
- `xi_axis`/`eta_axis` — names of the two computational axes per the Grid trait

The returned ArrayOp is indexed by flat cell `c` and consumes the
gathered-field tables built from `neighbor_indices(grid, ...)`.
"""
function _build_rhs_arrayop(rhs, dvs, u_syms, grid::AbstractCurvilinearGrid;
        target::Symbol, target_axes::NTuple{2, Symbol},
        xi_axis::Symbol = :xi, eta_axis::Symbol = :eta)
    ctx = _build_rhs_context(grid, dvs, u_syms, target, target_axes;
        xi_axis = xi_axis, eta_axis = eta_axis)
    N = n_cells(grid)
    idx = get_idx_vars(1); c = idx[1]
    body = _rhs_to_arrayop_expr(Symbolics.unwrap(rhs), dvs, ctx, c, 1.0)
    return make_arrayop(idx, Symbolics.unwrap(body), Dict(c => 1:1:N))
end

# Re-export under the EarthSciSerialization namespace for downstream callers.
EarthSciSerialization.fv_laplacian_extended(args...; kwargs...) =
    fv_laplacian_extended(args...; kwargs...)
EarthSciSerialization.fv_gradient_extended(args...; kwargs...) =
    fv_gradient_extended(args...; kwargs...)
EarthSciSerialization.const_wrap(arr) = const_wrap(arr)
EarthSciSerialization.get_idx_vars(n::Int) = get_idx_vars(n)
EarthSciSerialization.make_arrayop(idx, expr, ranges) = make_arrayop(idx, expr, ranges)
EarthSciSerialization.evaluate_arrayop(ao) = evaluate_arrayop(ao)
EarthSciSerialization.laplacian_neighbor_table(g; kwargs...) =
    laplacian_neighbor_table(g; kwargs...)
EarthSciSerialization.gradient_neighbor_table(g; kwargs...) =
    gradient_neighbor_table(g; kwargs...)
EarthSciSerialization._build_rhs_arrayop(args...; kwargs...) =
    _build_rhs_arrayop(args...; kwargs...)
