# ========================================================================
# interp.* over whole LANES: locate → gather → blend
# ========================================================================
#
# Branch-free evaluation of the `interp.*` closed functions over a whole lane of
# query points at once, plus the knot-addressing SEAMS the lane evaluators reach
# every table through. The seams exist so a backend can replace an O(table)
# select ladder with a constant-time gather: specialize `_knot_count`,
# `_knot_pair`, `_knot_pair2` and `_bilinear_corners` on its own index type and
# the evaluators below lower unchanged.

# ---- interp knot addressing: the seams a TRACER replaces --------------------
#
# The three primitive shapes the lane forms below are built from, factored out
# as SEAMS for exactly the reason `_oop_read_state` is one: the branch-free
# select-ladder lowering is RIGHT for host / ForwardDiff — a handful of fused
# broadcasts over a 2–3 knot table, no branch, no allocation per knot — and
# catastrophically WRONG for a tracer on a big table, where every ladder step is
# a separate traced op and the emitted program is O(table) PER CALL SITE.
#
# On a photolysis-style component with several bilinear calls over tables of a few
# thousand entries, the ladder traces to a program dominated by `select`/`compare`
# scaffolding rather than arithmetic, and XLA compile can exhaust host memory.
#
# A tracer has a constant-time primitive for precisely this — `stablehlo.gather`
# on a constant table — so a backend replaces the three ladders HERE rather than
# forking the three lane evaluators. What a backend method must honour,
# bit-for-bit:
#
#   `_knot_count(knots, q, cmp)`   Σ_k [cmp(knots[k], q)] as a Float64 lane
#         value. The terms are 0.0/1.0 and n ≪ 2^53, so the sum is EXACT in any
#         association order, and so is any other route to the same integer: what
#         a backend owes is the ladder's VALUE, not its shape, for every query
#         including NaN (which fails every compare and contributes 0.0 here).
#         A `reduce` along the knot axis is the obvious lowering; the Reactant
#         backend instead locates elementwise (a capped ladder for a small axis,
#         an arithmetic guess corrected by two gathers for a big uniform one, the
#         reduce as a fallback) — see the `count-locate` header in
#         ext/EarthSciASTReactantExt.jl and test/reactant_locate_test.jl for the
#         exactness argument and its pins.
#   `_knot_pair(v, i)`             `(v[i], v[i+1])` elementwise, `i` an
#         exactly-integral Float64 lane index in `[1, length(v)-1]`. SELECTION,
#         never a blend — the table entry comes through bit-exact (no `0·Inf`,
#         no signed-zero surprise), which a gather also gives by construction.
#   `_knot_pair2(a, b, i)`         the same, for two same-length tables at
#         one index, sharing the ladder's compares (the linear evaluator's
#         axis+table pair; kept fused so the host op count is UNCHANGED).
#   `_bilinear_corners(tbl, i, j, Nx, Ny)`  the four `tbl[i+a][j+b]`,
#         `a,b ∈ {0,1}`, same selection contract, `i ∈ [1,Nx-1]`, `j ∈ [1,Ny-1]`.
#
# `knots`/`v`/`a`/`b` is a `Vector{Float64}` (one table shared by every lane) or
# a `Vector{Vector{Float64}}` of lane COLUMNS (`_Interp*LaneSpec`, one table per
# lane, `col[k][l]`); `tbl` is `Vector{Vector{Float64}}` (scalar spec,
# `tbl[k][l]`) or a `Matrix{Vector{Float64}}` of lane columns (`tbl[k,l][lane]`).
# Both are build-time host constants either way, so a backend can materialize
# them as constant tensors. `_knot_at` is the one place that difference is
# read, so a backend's methods need not repeat it.
@inline _knot_at(v::AbstractVector{Float64}, k::Int) = @inbounds v[k]
@inline _knot_at(v::AbstractVector{Vector{Float64}}, k::Int) = @inbounds v[k]
@inline _tbl_at(t::Vector{Vector{Float64}}, k::Int, l::Int) = @inbounds t[k][l]
@inline _tbl_at(t::Matrix{Vector{Float64}}, k::Int, l::Int) = @inbounds t[k, l]

@inline function _knot_count(knots, q, cmp::F) where {F}
    n = length(knots)
    cnt = ifelse.(cmp.(_knot_at(knots, 1), q), 1.0, 0.0)
    for k in 2:n
        cnt = cnt .+ ifelse.(cmp.(_knot_at(knots, k), q), 1.0, 0.0)
    end
    return cnt
end

@inline function _knot_pair(v, i)
    n = length(v)
    lo = _knot_at(v, 1) .+ zero.(i)
    hi = _knot_at(v, 2) .+ zero.(i)
    for k in 2:(n - 1)
        sel = i .== Float64(k)
        lo = ifelse.(sel, _knot_at(v, k),     lo)
        hi = ifelse.(sel, _knot_at(v, k + 1), hi)
    end
    return lo, hi
end

@inline function _knot_pair2(a, b, i)
    n = length(a)
    alo = _knot_at(a, 1) .+ zero.(i); ahi = _knot_at(a, 2) .+ zero.(i)
    blo = _knot_at(b, 1) .+ zero.(i); bhi = _knot_at(b, 2) .+ zero.(i)
    for k in 2:(n - 1)
        sel = i .== Float64(k)
        alo = ifelse.(sel, _knot_at(a, k),     alo)
        ahi = ifelse.(sel, _knot_at(a, k + 1), ahi)
        blo = ifelse.(sel, _knot_at(b, k),     blo)
        bhi = ifelse.(sel, _knot_at(b, k + 1), bhi)
    end
    return alo, ahi, blo, bhi
end

@inline function _bilinear_corners(tbl, i, j, Nx::Int, Ny::Int)
    z = zero.(i .+ j)
    t_ij    = _tbl_at(tbl, 1, 1) .+ z; t_i1j   = _tbl_at(tbl, 2, 1) .+ z
    t_ijp1  = _tbl_at(tbl, 1, 2) .+ z; t_i1jp1 = _tbl_at(tbl, 2, 2) .+ z
    for k in 1:(Nx - 1), l in 1:(Ny - 1)
        (k == 1 && l == 1) && continue
        sel = (i .== Float64(k)) .& (j .== Float64(l))
        t_ij    = ifelse.(sel, _tbl_at(tbl, k,     l),     t_ij)
        t_i1j   = ifelse.(sel, _tbl_at(tbl, k + 1, l),     t_i1j)
        t_ijp1  = ifelse.(sel, _tbl_at(tbl, k,     l + 1), t_ijp1)
        t_i1jp1 = ifelse.(sel, _tbl_at(tbl, k + 1, l + 1), t_i1jp1)
    end
    return t_ij, t_i1j, t_ijp1, t_i1jp1
end

# ---- interp.* over whole LANES: locate → gather → blend ----------------------
#
# The de-scalarized interp forms the affine access-kernel path evaluates (and the
# forms an XLA/Reactant trace needs): NO branch on the query, NO opaque scalar
# core inside a broadcast — every step is elementwise arithmetic + a knot-
# addressing seam, so a traced query lane vector flows through as whole-array ops
# and the emitted program's size is independent of the GRID. (It is independent
# of the TABLE too, but only on a backend that gives the seams above a gather;
# the default lowering is the O(table) select ladder — see the seam header.)
#
# BIT-IDENTICAL to the scalar cores, by mirroring their decision trees with
# `ifelse` selects instead of branches:
#   * locate: `i = clamp(Σ_k [axis[k] ≤ x], 1, n-1)` — for a validated strictly-
#     increasing axis this is exactly the scan's "largest k with axis[k] ≤ x".
#   * gather: `_knot_pair` / `_bilinear_corners` SELECT (never blend)
#     the cell's endpoints, so table entries come through exactly (no `0·Inf`, no
#     signed-zero surprises).
#   * blend: the cores' pinned form `tᵢ + w·(tᵢ₊₁ − tᵢ)` verbatim.
#   * clamps: the same outer `x ≤ axis[1]` / `x ≥ axis[n]` selects the cores
#     early-return on. A NaN query fails both compares, takes the blend arm, and
#     `w = (NaN − aᵢ)/…` propagates NaN — the cores' documented NaN semantics.
# The oop test file pins these against the scalar cores over dense query sweeps
# (in-range, knots, both clamps, NaN).
#
# `q` may be a lane vector OR a scalar (an invariant query) — broadcast serves
# both, exactly like the rest of this emitter.
function _interp_linear_lanes(h::_InterpLinearSpec, q, ::Type{T}) where {T}
    axis = h.axis; table = h.table
    n = length(axis)
    cnt = _knot_count(axis, q, <=)
    i = min.(max.(cnt, 1.0), Float64(n - 1))
    ai, ai1, ti, ti1 = _knot_pair2(axis, table, i)
    w = (q .- ai) ./ (ai1 .- ai)
    blend = ti .+ w .* (ti1 .- ti)
    return ifelse.(q .<= axis[1], table[1],
                   ifelse.(q .>= axis[n], table[n], blend))
end

function _interp_searchsorted_lanes(h::_InterpSearchsortedSpec, q, ::Type{T}) where {T}
    xs = h.xs
    n = length(xs)
    n == 0 && return one.(q .* 0 .+ 1.0)     # empty table → 1 lane-wide (core's rule)
    # smallest i with xs[i] ≥ x  ==  #(xs .< x) + 1; NaN → n+1 (selected explicitly,
    # since `xs[k] < NaN` is false everywhere and would land on 1).
    r = _knot_count(xs, q, <) .+ 1.0
    return ifelse.(q .!= q, Float64(n + 1), r)
end

function _interp_bilinear_lanes(h::_InterpBilinearSpec, x, y, ::Type{T}) where {T}
    ax = h.axis_x; ay = h.axis_y; table = h.table
    Nx = length(ax); Ny = length(ay)
    # Per-axis clamp of the QUERY (the core's x_q/y_q), then count-locate.
    x_q = ifelse.(x .<= ax[1], ax[1], ifelse.(x .>= ax[Nx], ax[Nx], x))
    y_q = ifelse.(y .<= ay[1], ay[1], ifelse.(y .>= ay[Ny], ay[Ny], y))
    i = min.(max.(_knot_count(ax, x_q, <=), 1.0), Float64(Nx - 1))
    j = min.(max.(_knot_count(ay, y_q, <=), 1.0), Float64(Ny - 1))
    xi, xip1 = _knot_pair(ax, i)
    yj, yjp1 = _knot_pair(ay, j)
    t_ij, t_i1j, t_ijp1, t_i1jp1 = _bilinear_corners(table, i, j, Nx, Ny)
    wx = (x_q .- xi) ./ (xip1 .- xi)
    wy = (y_q .- yj) ./ (yjp1 .- yj)
    row_j   = t_ij   .+ wx .* (t_i1j   .- t_ij)
    row_jp1 = t_ijp1 .+ wx .* (t_i1jp1 .- t_ijp1)
    return row_j .+ wy .* (row_jp1 .- row_j)
end

# ---- interp.* with PER-LANE spec tables (kernel-class merge) -----------------
#
# The lane-tabled twins of the three evaluators above, for a merged kernel
# class whose members carry DIFFERENT same-shape interp tables
# (`_Interp*LaneSpec`, registered_functions.jl). Same locate → gather → blend
# through the SAME seams, with every scalar knot read (`axis[k]` / `table[k]` /
# `xs[k]`) replaced by its length-L lane COLUMN (`col[k][l] == specs[l].…[k]`).
# All the selects are elementwise, so lane `l` computes exactly what the
# scalar-spec evaluator computes on `specs[l]` — bit-identical to the unmerged
# kernels by construction. The columns are host `Vector{Float64}` constants, so
# a Reactant trace embeds them as constant tensors exactly like scalar knots,
# and the emitted program stays independent of the lane count's origin. `q` may
# be a lane vector OR an invariant scalar; the columns force a length-L result
# either way (each lane still owns its own table).
#
# CLAMP/EDGE BOUNDS are the exception to "every knot read is a seam": the outer
# clamp (`ax[1]`/`ax[Nx]`, and the linear form's edge values `table[1]`/
# `table[n]`) is a plain broadcast over the boundary COLUMN, so under a trace
# each such column would be embedded as a lane-wide constant even when every lane
# holds the same bound — the one remaining O(lanes) constant after the knot/table
# gathers went grid-independent (see test/reactant_lane_dedup_test.jl).
# `_lane_bound` collapses a boundary column whose lanes are all BITWISE
# equal (`isequal` per element: NaN unifies, `-0.0` stays apart from `0.0` —
# the same key the trace-time lane dedup groups by) to its one scalar, which a
# trace then embeds as a scalar constant. Bit-identical by construction: the
# broadcasts consume one value per lane either way, and it is the same value.
# RESULT LENGTH is unchanged in every case — the length-L knot columns flow
# through `_knot_count`/`_knot_pair`/`_bilinear_corners` on every
# path, so the lane axis is carried by the located/gathered terms even when a
# collapsed bound meets a lane-invariant scalar query (the `Lq` trap the
# Reactant ext's `_rx_knot_matrix` guard documents). A mixed column (lanes
# genuinely differing in their bound) stays a column — exactly today.
# `ESS_LANE_INTERN_DISABLE=1` turns the collapse off with the rest of the
# lane-intern feature, restoring today's lane-wide bounds as the oracle.
function _lane_bound(col::Vector{Float64})
    _lane_intern_disabled() && return col
    @inbounds v1 = col[1]
    @inbounds for k in 2:length(col)
        isequal(col[k], v1) || return col
    end
    return v1
end

function _interp_linear_lanes(h::_InterpLinearLaneSpec, q, ::Type{T}) where {T}
    axis = h.axis_cols; table = h.table_cols
    n = length(axis)
    cnt = _knot_count(axis, q, <=)
    i = min.(max.(cnt, 1.0), Float64(n - 1))
    ai, ai1, ti, ti1 = _knot_pair2(axis, table, i)
    w = (q .- ai) ./ (ai1 .- ai)
    blend = ti .+ w .* (ti1 .- ti)
    return ifelse.(q .<= _lane_bound(axis[1]), _lane_bound(table[1]),
                   ifelse.(q .>= _lane_bound(axis[n]), _lane_bound(table[n]),
                           blend))
end

function _interp_searchsorted_lanes(h::_InterpSearchsortedLaneSpec, q,
                                        ::Type{T}) where {T}
    xs = h.xs_cols
    n = length(xs)
    n == 0 && return one.(q .* 0 .+ 1.0)     # empty table → 1 lane-wide (core's rule)
    r = _knot_count(xs, q, <) .+ 1.0
    return ifelse.(q .!= q, Float64(n + 1), r)
end

function _interp_bilinear_lanes(h::_InterpBilinearLaneSpec, x, y,
                                    ::Type{T}) where {T}
    ax = h.axis_x_cols; ay = h.axis_y_cols; table = h.table_cols
    Nx = length(ax); Ny = length(ay)
    ax1 = _lane_bound(ax[1]); axN = _lane_bound(ax[Nx])
    ay1 = _lane_bound(ay[1]); ayN = _lane_bound(ay[Ny])
    x_q = ifelse.(x .<= ax1, ax1, ifelse.(x .>= axN, axN, x))
    y_q = ifelse.(y .<= ay1, ay1, ifelse.(y .>= ayN, ayN, y))
    i = min.(max.(_knot_count(ax, x_q, <=), 1.0), Float64(Nx - 1))
    j = min.(max.(_knot_count(ay, y_q, <=), 1.0), Float64(Ny - 1))
    xi, xip1 = _knot_pair(ax, i)
    yj, yjp1 = _knot_pair(ay, j)
    t_ij, t_i1j, t_ijp1, t_i1jp1 = _bilinear_corners(table, i, j, Nx, Ny)
    wx = (x_q .- xi) ./ (xip1 .- xi)
    wy = (y_q .- yj) ./ (yjp1 .- yj)
    row_j   = t_ij   .+ wx .* (t_i1j   .- t_ij)
    row_jp1 = t_ijp1 .+ wx .* (t_i1jp1 .- t_ijp1)
    return row_j .+ wy .* (row_jp1 .- row_j)
end
