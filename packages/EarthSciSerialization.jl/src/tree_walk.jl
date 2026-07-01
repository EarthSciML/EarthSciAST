"""
Tree-walk evaluator for discretized `.esm` models (gt-e8yw).

Compiles the canonical-form equations of a `Model` into a plain
`f!(du, u, p, t)` by walking the expression AST at every RHS call.
Bypasses ModelingToolkit entirely, so compile time is independent of
the system size — the path is intended for discretized PDEs whose
scalar count exceeds MTK's tearing/codegen ceiling.

Public API:

    build_evaluator(model::Model; kwargs...)
        → (f!, u0::Vector{Float64}, p::NamedTuple, tspan::Tuple{Float64,Float64},
           var_map::Dict{String,Int})

The returned tuple plugs straight into `ODEProblem(f!, u0, tspan, p)`.
`var_map` is the state-name → index lookup so callers can probe the
solution at specific variables.

Dict and EsmFile convenience entry points select a model by name (or
the single model, if the file carries only one).
"""

# ============================================================
# 1. Error type
# ============================================================

"""
    TreeWalkError

Raised when the walker encounters an operator or construct it cannot
evaluate. `code` is always one of the `E_TREEWALK_*` codes from the
bead's acceptance criterion; `detail` carries op name or variable name
for diagnostics.
"""
struct TreeWalkError <: Exception
    code::String
    detail::String
end

Base.showerror(io::IO, e::TreeWalkError) =
    print(io, "$(e.code): $(e.detail)")

# ============================================================
# 2. Build — entry points
# ============================================================

"""
    build_evaluator(model::Model; initial_conditions=Dict(),
                    parameter_overrides=Dict(), tspan=nothing,
                    registered_functions=Dict())

Build a tree-walk ODE RHS evaluator for `model`.

All state variables must be scalar (shape === nothing) — the walker
assumes equations have already been scalarized by the discretize
pipeline. `arrayop` and `makearray` are supported in expression
position: scalar `arrayop` (empty `output_idx`) is expanded inline;
`index(arrayop(...), k...)` and `index(makearray(...), k...)` are
resolved at build time. Other array-typed ops (`broadcast`, `reshape`,
`transpose`, `concat`) raise `E_TREEWALK_UNSUPPORTED_OP`.

The returned `f!` closure reads `u`, the captured parameter vector
`p` (a NamedTuple keyed by parameter name), and `t`, and writes
time-derivatives into `du`. Observed variables are substituted into
RHS expressions at build time.

Keyword arguments:

* `initial_conditions::Dict{String,<:Real}` — override the default
  values in `model.variables` for specific state variables.
* `parameter_overrides::Dict{String,<:Real}` — override the default
  values for specific parameters.
* `tspan::Union{Nothing,Tuple{Real,Real}}` — explicit time span. If
  `nothing`, the first inline `tests` block's `time_span` is used; if
  the model has no tests, the null default `(0.0, 1.0)` is returned.
* `registered_functions::Dict{String,<:Function}` — handlers for
  `call` ops, keyed by `handler_id`.
"""
# ============================================================
# M4 geometry kernel — build-time intersect_polygon clip (RFC §8.1 / Appendix B)
# ============================================================
#
# The `intersect_polygon` leaf runs at SETUP time (RFC Appendix B.1): its polygon
# operands are build-time-known parameters supplied via `const_arrays`, so the clip
# is evaluated ONCE here into a closed vertex ring. The ring is registered as a 2D
# const_array (read by the `polygon_area` FAQ as `index(clip, v, c)`) and its
# distinct-vertex count feeds the `kind:"derived"` index set the FAQ ranges over —
# so `polygon_area` rides the existing M1 aggregate machinery unchanged.
#
# All of this is guarded behind "an equation uses intersect_polygon", so every
# non-geometry file compiles byte-identically.

# True iff any node in the subtree is an intersect_polygon op.
_expr_has_intersect_polygon(e::OpExpr) =
    e.op == "intersect_polygon" ||
    any(_expr_has_intersect_polygon, e.args) ||
    (e.expr_body !== nothing && _expr_has_intersect_polygon(e.expr_body))
_expr_has_intersect_polygon(::Expr) = false
_equations_have_intersect_polygon(eqs) =
    any(eq -> _expr_has_intersect_polygon(eq.lhs) || _expr_has_intersect_polygon(eq.rhs), eqs)

# An intersect_polygon may live in an equation RHS or in an observed variable's
# `expression` field (the shared geometry fixtures use the latter — the Python
# evaluator reads `variable.expression` directly).
function _model_has_intersect_polygon(model::Model)
    for (_, v) in model.variables
        v.expression isa Expr && _expr_has_intersect_polygon(v.expression) && return true
    end
    return _equations_have_intersect_polygon(model.equations)
end

# Resolve an intersect_polygon polygon operand to its const-array matrix. The clip
# runs at setup, so each operand must be a variable name supplied in `const_arrays`.
function _geometry_operand(arg::Expr, const_arrays_kw::AbstractDict, who::AbstractString)
    arg isa VarExpr || throw(TreeWalkError("E_TREEWALK_GEOMETRY_OPERAND",
        "intersect_polygon operand for '$who' must be a polygon variable name"))
    name = (arg::VarExpr).name
    haskey(const_arrays_kw, name) || throw(TreeWalkError("E_TREEWALK_GEOMETRY_OPERAND",
        "intersect_polygon operand '$name' for '$who' must be supplied in `const_arrays` " *
        "(the clip runs at setup time; RFC Appendix B.1)"))
    return const_arrays_kw[name]
end

# Evaluate every intersect_polygon clip ring at setup. Returns
# `(rings, extents)`: observed-var-name → CLOSED ring matrix `[n+1, 2]`, and
# `from_faq` key (the clip node `id` AND the observed var name) → distinct vertex
# count `n`. `geom_ring_vars` are the observed vars whose RHS is intersect_polygon.
function _materialize_geometry_rings(equations, const_arrays_kw::AbstractDict,
                                     geom_ring_vars::Set{String})
    rings = Dict{String,Matrix{Float64}}()
    extents = Dict{String,Int}()
    for eq in equations
        eq.lhs isa VarExpr || continue
        vname = (eq.lhs::VarExpr).name
        vname in geom_ring_vars || continue
        rhs = eq.rhs
        (rhs isa OpExpr && (rhs::OpExpr).op == "intersect_polygon") || continue
        op = rhs::OpExpr
        manifold = op.manifold
        manifold === nothing && throw(TreeWalkError("E_TREEWALK_GEOMETRY_NO_MANIFOLD",
            "intersect_polygon observed '$vname' requires a `manifold` (planar / spherical / geodesic)"))
        length(op.args) == 2 || throw(TreeWalkError("E_TREEWALK_GEOMETRY_ARITY",
            "intersect_polygon is strictly binary; '$vname' has $(length(op.args)) operand(s)"))
        poly_a = _geometry_operand(op.args[1], const_arrays_kw, vname)
        poly_b = _geometry_operand(op.args[2], const_arrays_kw, vname)
        ring = try
            intersect_polygon(poly_a, poly_b, manifold)
        catch err
            err isa GeometryError &&
                throw(TreeWalkError("E_TREEWALK_GEOMETRY_CLIP", err.msg))
            rethrow()
        end
        closed = close_ring(ring)
        rings[vname] = closed
        n = max(size(closed, 1) - 1, 0)   # closed ring has n+1 rows
        extents[vname] = n                # derived set may name the var…
        op.id === nothing || (extents[op.id] = n)   # …or the clip node id (from_faq)
    end
    return rings, extents
end

# ============================================================
# polygon_intersection_area — FUSED clip+area scalar leaf (esm-spec §4.2 / §8.6.1)
# ============================================================
#
# `polygon_intersection_area` returns the SCALAR overlap area of two polygon vertex
# rings under a declared `manifold`. It is DEFINED to equal
# `polygon_area(intersect_polygon(a, b))` at the same manifold — the FUSED form of
# the existing Sutherland–Hodgman clip and the shoelace / spherical-excess area FAQ.
# Unlike `intersect_polygon` (which surfaces a data-dependent clip ring as a
# `kind:"derived"` index set the `polygon_area` FAQ ranges over, RFC §8.1), the
# fused leaf exposes NO ring: it evaluates to an ordinary Float64 scalar, so it
# drops into any expression — an ODE RHS or an `aggregate` body — with no ragged
# intermediate. Both constituent kernels are reused verbatim: `intersect_polygon`
# (the clip, planar or S2) and `_polygon_area_via_faq` (the shoelace / Van
# Oosterom–Strackee area over the CLOSED ring, run through the generic aggregate
# machinery). This is the densely-evaluable narrow phase of a conservative regrid.

# True iff any node in the subtree is a polygon_intersection_area op.
_expr_has_polygon_intersection_area(e::OpExpr) =
    e.op == "polygon_intersection_area" ||
    any(_expr_has_polygon_intersection_area, e.args) ||
    (e.expr_body !== nothing && _expr_has_polygon_intersection_area(e.expr_body))
_expr_has_polygon_intersection_area(::Expr) = false

# An intersection-area leaf may live in an equation LHS/RHS or in an observed
# variable's `expression` field (the shared fixtures use the latter).
function _model_has_polygon_intersection_area(model::Model, equations)
    for (_, v) in model.variables
        v.expression isa Expr && _expr_has_polygon_intersection_area(v.expression) && return true
    end
    for eq in equations
        (_expr_has_polygon_intersection_area(eq.lhs) ||
         _expr_has_polygon_intersection_area(eq.rhs)) && return true
    end
    return false
end

# Collect the variable names appearing as direct operands of any
# polygon_intersection_area node in `e` (the const polygon vertex rings).
function _collect_pia_operands!(e::OpExpr, acc::Set{String})
    if e.op == "polygon_intersection_area"
        for a in e.args
            a isa VarExpr && push!(acc, (a::VarExpr).name)
        end
    end
    for a in e.args
        _collect_pia_operands!(a, acc)
    end
    e.expr_body !== nothing && _collect_pia_operands!(e.expr_body, acc)
    return acc
end
_collect_pia_operands!(::Expr, acc::Set{String}) = acc

# A `const`-op node's stored (nested-vector) value → a dense `[nrows, ncols]`
# Float64 vertex-ring matrix.
function _pia_const_matrix(val)::Matrix{Float64}
    rows = collect(val)
    nr = length(rows)
    nr == 0 && return Matrix{Float64}(undef, 0, 2)
    nc = length(collect(rows[1]))
    M = Matrix{Float64}(undef, nr, nc)
    for i in 1:nr
        r = collect(rows[i])
        for j in 1:nc
            M[i, j] = Float64(r[j])
        end
    end
    return M
end

# True iff `e` is a `const`-op node (build-time literal data — a polygon vertex
# ring array, a source field). Its value lives in `e.value`, not `e.args`.
_is_const_op(e) = e isa OpExpr && (e::OpExpr).op == "const"

# A `const`-op node's stored (nested-vector) value → a dense Float64 array whose
# rank is the nesting depth (`[[[...]]]` → 3-D). Generalizes `_pia_const_matrix`
# (which fixes rank 2) to the ND case: an in-file `src_poly[cell, vert, coord]`
# ring stack or a 1-D `F_src[cell]` field. Column-major fill matches Julia's
# native layout, so `index(src_poly, i)` slices out cell `i`'s ring matrix.
function _const_op_to_array(val)::Array{Float64}
    dims = Int[]
    node = val
    while !(node isa Number)
        n = length(node)
        push!(dims, n)
        n == 0 && break
        node = first(node)
    end
    A = Array{Float64}(undef, dims...)
    _fill_const_array!(A, val, ())
    return A
end

function _fill_const_array!(A, node, idx::Tuple)
    if node isa Number
        A[idx...] = Float64(node)
        return
    end
    for (k, sub) in enumerate(node)
        _fill_const_array!(A, sub, (idx..., k))
    end
    return
end

"""
    _polygon_intersection_area(poly_a, poly_b, manifold) -> Float64

The fused `polygon_intersection_area` leaf: clip the two operand rings under
`manifold` (`intersect_polygon`), then area the CLOSED overlap ring through the
generic `polygon_area` FAQ (`_polygon_area_via_faq`). Equals
`polygon_area(intersect_polygon(a, b))` at the same manifold. A degenerate /
non-overlapping clip (`< 3` distinct vertices) has zero overlap area.
"""
function _polygon_intersection_area(poly_a, poly_b, manifold::AbstractString)::Float64
    ring = try
        intersect_polygon(poly_a, poly_b, manifold)
    catch err
        err isa GeometryError &&
            throw(TreeWalkError("E_TREEWALK_GEOMETRY_CLIP", err.msg))
        rethrow()
    end
    size(ring, 1) < 3 && return 0.0
    return _polygon_area_via_faq(close_ring(ring), manifold)
end

# Resolve a polygon_intersection_area operand to its const polygon-ring matrix. The
# fused leaf is build-time-evaluable, so each operand must be a const-array variable
# name (supplied via `const_arrays` or a materialized `const`-op observed).
function _pia_operand_ring(arg::Expr, const_arrays::AbstractDict)
    arg isa VarExpr && haskey(const_arrays, (arg::VarExpr).name) &&
        return const_arrays[(arg::VarExpr).name]
    throw(TreeWalkError("E_TREEWALK_GEOMETRY_OPERAND",
        "polygon_intersection_area operand must be a build-time-known polygon ring " *
        "(a const-array variable name)"))
end

# ============================================================
# M4+ : intersect_polygon RANGED over a candidate-pair set (declarative A_ij).
# ============================================================
# The single-clip M4 kernel above materializes ONE intersect_polygon ring from
# whole-array const operands. A conservative-regrid `A_ij` instead needs the clip
# RANGED over a candidate-pair set: `clip[p,w,c] = intersect_polygon(src[p],
# tgt[p])[w,c]`, then `area[p] = polygon_area(clip[p])` (an aggregate), then the
# matrix scatter. These geometry-derived ARRAY observeds are pure functions of the
# const polygon inputs (no state, no time), so — exactly like the single clip
# (RFC §8.1) and the value-invention skolems (§6.1) — they are evaluated ONCE at
# setup into const_arrays and dropped from the ODE. `_geometry_setup_vars` finds
# them; `_materialize_geometry_setup` evaluates them.

# Extent of an IndexSetRef range against the model's index sets + derived extents.
function _geo_index_extent(ref, index_sets, derived_extents)
    name = ref isa IndexSetRef ? ref.from : String(ref)
    haskey(derived_extents, name) && return derived_extents[name]
    s = index_sets === nothing ? nothing : get(index_sets, name, nothing)
    sz = s === nothing ? nothing :
         hasproperty(s, :size) ? getproperty(s, :size) :
         (s isa AbstractDict ? get(s, "size", get(s, :size, nothing)) : nothing)
    sz === nothing && throw(TreeWalkError("E_TREEWALK_GEOMETRY_SETUP",
        "cannot resolve extent of index set '$(name)' for setup-time geometry"))
    return Int(sz)
end

# Apply a scalar op at setup time (the polygon-area / overlap FAQ vocabulary).
function _geo_apply_scalar(op::AbstractString, a::Vector{Float64})
    op == "+"     && return sum(a)
    op == "*"     && return prod(a)
    op == "-"     && return length(a) == 1 ? -a[1] : a[1] - sum(@view a[2:end])
    op == "/"     && return a[1] / a[2]
    op == "^"     && return a[1] ^ a[2]
    op == "max"   && return maximum(a)
    op == "min"   && return minimum(a)
    op == "sqrt"  && return sqrt(a[1])
    op == "abs"   && return abs(a[1])
    op == "cos"   && return cos(a[1])
    op == "sin"   && return sin(a[1])
    op == "atan2" && return atan(a[1], a[2])
    op == "ifelse" && return a[1] != 0.0 ? a[2] : a[3]
    op == "floor" && return floor(a[1])
    op == "ceil"  && return ceil(a[1])
    op == ">"  && return a[1] >  a[2] ? 1.0 : 0.0
    op == "<"  && return a[1] <  a[2] ? 1.0 : 0.0
    op == ">=" && return a[1] >= a[2] ? 1.0 : 0.0
    op == "<=" && return a[1] <= a[2] ? 1.0 : 0.0
    op == "==" && return a[1] == a[2] ? 1.0 : 0.0
    op == "!=" && return a[1] != a[2] ? 1.0 : 0.0
    throw(TreeWalkError("E_TREEWALK_GEOMETRY_SETUP",
        "unsupported op '$(op)' in setup-time geometry"))
end

# Map a join key column to the aggregate loop var that indexes it (via its
# declared 1-D shape's index set).
function _geo_loopvar_for(col, setof, var_shapes)
    sets = get(var_shapes, col, String[])
    isempty(sets) && return nothing
    for (lv, st) in setof
        st == sets[1] && return lv
    end
    return nothing
end

# Aggregate gate: honor a `join` (key-equality across the joined columns — the
# bin-skolem BROAD PHASE) and a `filter` predicate (sliver removal). A tuple that
# fails either contributes the additive identity (RFC §5.3 / §5.8); ignoring the
# join is numerically equivalent (non-candidate pairs have zero overlap) but the
# gate makes the setup loop O(candidates) and faithful to the component structure.
function _geo_agg_gate(expr, ie, env, setof, var_shapes, index_sets, derived_extents)
    if expr.join !== nothing
        for clause in expr.join, pair in clause
            colA, colB = String(pair[1]), String(pair[2])
            lvA = _geo_loopvar_for(colA, setof, var_shapes)
            lvB = _geo_loopvar_for(colB, setof, var_shapes)
            (lvA === nothing || lvB === nothing) && continue
            (haskey(env, colA) && haskey(env, colB)) || continue
            env[colA][ie[lvA]] == env[colB][ie[lvB]] || return false
        end
    end
    if expr.filter !== nothing
        _geo_eval(expr.filter, env, ie, index_sets, derived_extents, var_shapes, setof) != 0.0 ||
            return false
    end
    return true
end

# Setup-time evaluator for the geometry chain. Walks an expression to a Float64
# (or, for `index` of a multi-dim array with FEWER indices, a slice array) against
# `env` (name → Julia value: const arrays + scalar params + materialized geometry),
# `idx_env` (loop var → Int), and `var_shapes` (var → its shape's index-set names,
# for join-column resolution). Covers exactly the ops the polygon-area / overlap-
# join FAQ uses; anything else is an explicit setup-geometry error.
function _geo_eval(expr, env, idx_env, index_sets, derived_extents,
                   var_shapes=Dict{String,Vector{String}}(),
                   outer_setof=Dict{String,String}())
    if expr isa NumExpr
        return expr.value
    elseif expr isa IntExpr
        return Float64(expr.value)
    elseif expr isa VarExpr
        haskey(idx_env, expr.name) && return Float64(idx_env[expr.name])
        haskey(env, expr.name) && return env[expr.name]
        throw(TreeWalkError("E_TREEWALK_GEOMETRY_SETUP",
            "unbound name '$(expr.name)' in setup-time geometry"))
    elseif expr isa OpExpr
        op = expr.op
        if op == "index"
            arr = _geo_eval(expr.args[1], env, idx_env, index_sets, derived_extents, var_shapes, outer_setof)
            arr isa AbstractArray || throw(TreeWalkError("E_TREEWALK_GEOMETRY_SETUP",
                "index of a non-array in setup-time geometry"))
            idxs = Int[Int(round(_geo_eval(a, env, idx_env, index_sets, derived_extents, var_shapes, outer_setof)))
                       for a in expr.args[2:end]]
            if length(idxs) == ndims(arr)
                return arr[idxs...]
            else
                colons = ntuple(_ -> Colon(), ndims(arr) - length(idxs))
                return Array(arr[idxs..., colons...])   # partial index → slice
            end
        elseif op == "intersect_polygon"
            a = _geo_eval(expr.args[1], env, idx_env, index_sets, derived_extents, var_shapes, outer_setof)
            b = _geo_eval(expr.args[2], env, idx_env, index_sets, derived_extents, var_shapes, outer_setof)
            expr.manifold === nothing && throw(TreeWalkError("E_TREEWALK_GEOMETRY_NO_MANIFOLD",
                "intersect_polygon requires a manifold"))
            return close_ring(intersect_polygon(a, b, expr.manifold))
        elseif op == "polygon_intersection_area"
            # FUSED scalar leaf (esm-spec §8.6.1): the overlap AREA of the two rings,
            # with no exposed clip ring — so it evaluates as an ordinary scalar even
            # inside a setup-time aggregate body (dense narrow phase, no ragged extent).
            a = _geo_eval(expr.args[1], env, idx_env, index_sets, derived_extents, var_shapes, outer_setof)
            b = _geo_eval(expr.args[2], env, idx_env, index_sets, derived_extents, var_shapes, outer_setof)
            expr.manifold === nothing && throw(TreeWalkError("E_TREEWALK_GEOMETRY_NO_MANIFOLD",
                "polygon_intersection_area requires a manifold"))
            return _polygon_intersection_area(a, b, expr.manifold)
        elseif op == "skolem"
            # A skolem key is a deterministic id for its arg tuple; at setup it is
            # only ever COMPARED (the bin equi-join), so a stable hash suffices.
            vals = Any[_geo_eval(a, env, idx_env, index_sets, derived_extents, var_shapes, outer_setof)
                       for a in expr.args]
            return Float64(hash(Tuple(vals)) % (1 << 52))
        elseif op == "true"
            return 1.0
        elseif op == "false"
            return 0.0
        elseif op == "aggregate" || (op == "arrayop" && isempty(expr.output_idx))
            # Scalar reduction over the declared ranges, honoring join/filter gates.
            # `setof` accumulates loop-var → index-set across nesting so a join can
            # resolve a key column indexed by an OUTER loop var (per-cell F_tgt).
            loopvars = collect(keys(expr.ranges))
            exts = Int[_geo_index_extent(expr.ranges[v], index_sets, derived_extents)
                       for v in loopvars]
            setof = copy(outer_setof)
            for lv in loopvars
                r = expr.ranges[lv]
                r isa IndexSetRef && (setof[lv] = r.from)
            end
            acc = 0.0
            for tup in Iterators.product((1:e for e in exts)...)
                ie = copy(idx_env)
                for (lv, iv) in zip(loopvars, tup); ie[lv] = iv; end
                _geo_agg_gate(expr, ie, env, setof, var_shapes, index_sets, derived_extents) || continue
                acc += _geo_eval(expr.expr_body, env, ie, index_sets, derived_extents, var_shapes, setof)
            end
            return acc
        else
            vals = Float64[_geo_eval(x, env, idx_env, index_sets, derived_extents, var_shapes, outer_setof)
                           for x in expr.args]
            return _geo_apply_scalar(op, vals)
        end
    else
        throw(TreeWalkError("E_TREEWALK_GEOMETRY_SETUP",
            "unsupported expression $(typeof(expr)) in setup-time geometry"))
    end
end

# A clip ranged over an outer index set: an array-producing aggregate whose body
# is `index(intersect_polygon(src[outer], tgt[outer]), ring, coord)`. The
# array-producing form is the on-disk `aggregate` op with a non-empty `output_idx`
# (schema v0.8.0; the op enum dropped `arrayop`), OR the internal `arrayop` alias
# `shape_promotion.jl` still emits — `_is_aggregate_op` accepts both, and the
# non-empty `output_idx` guard keeps a SCALAR reduction (empty `output_idx`) out.
_is_ranged_clip(rhs) =
    rhs isa OpExpr && _is_aggregate_op(rhs.op) &&
    rhs.output_idx !== nothing && !isempty(rhs.output_idx) &&
    rhs.expr_body isa OpExpr &&
    (rhs.expr_body::OpExpr).op == "index" &&
    length((rhs.expr_body::OpExpr).args) >= 1 &&
    (rhs.expr_body::OpExpr).args[1] isa OpExpr &&
    ((rhs.expr_body::OpExpr).args[1]::OpExpr).op == "intersect_polygon"

# Materialize a per-outer-cell family of clip rings, padded to the max distinct-
# vertex count (the pad repeats the closing vertex so the shoelace pad-edges add
# zero area), into one dense const array `[outer…, maxn+1, coord]`; record the
# clip_ring extent so the polygon_area FAQ ranges `[1, maxn]` over it.
function _materialize_ranged_clip(arrayop, env, index_sets, derived_extents,
                                  var_shapes=Dict{String,Vector{String}}())
    body  = arrayop.expr_body::OpExpr          # index(intersect_polygon(...), w, c)
    ipoly = body.args[1]::OpExpr
    ringvar  = (body.args[2]::VarExpr).name
    coordvar = (body.args[3]::VarExpr).name
    outer = String[v for v in arrayop.output_idx if v != ringvar && v != coordvar]
    outer_ext = Int[_geo_index_extent(arrayop.ranges[v], index_sets, derived_extents)
                    for v in outer]
    coord_ext = _geo_index_extent(arrayop.ranges[coordvar], index_sets, derived_extents)
    manifold = ipoly.manifold
    manifold === nothing && throw(TreeWalkError("E_TREEWALK_GEOMETRY_NO_MANIFOLD",
        "ranged intersect_polygon requires a manifold"))
    rings = Dict{Tuple,Matrix{Float64}}()
    maxn = 0
    for tup in Iterators.product((1:e for e in outer_ext)...)
        ie = Dict{String,Any}(zip(outer, tup))
        A = _geo_eval(ipoly.args[1], env, ie, index_sets, derived_extents, var_shapes)
        B = _geo_eval(ipoly.args[2], env, ie, index_sets, derived_extents, var_shapes)
        # A non-overlapping pair yields a degenerate (< 3 vertex) clip → a zero-area
        # cell; the matrix is sparse over non-candidate pairs and that is normal,
        # not an error (RFC §5.8: unmatched rows add the additive identity).
        ring = try
            r = intersect_polygon(A, B, manifold)
            size(r, 1) >= 3 ? close_ring(r) : zeros(Float64, 0, coord_ext)
        catch err
            err isa GeometryError ? zeros(Float64, 0, coord_ext) : rethrow()
        end
        rings[Tuple(tup)] = ring
        maxn = max(maxn, size(ring, 1) - 1)
    end
    maxn = max(maxn, 0)
    clip = zeros(Float64, (outer_ext..., maxn + 1, coord_ext)...)
    for (tup, ring) in rings
        nrows = size(ring, 1)
        nrows == 0 && continue          # empty overlap → cell stays zero (area 0)
        for w in 1:(maxn + 1)
            sr = w <= nrows ? w : 1     # pad rows repeat the closing vertex (row 1)
            for c in 1:coord_ext
                clip[tup..., w, c] = ring[sr, c]
            end
        end
    end
    ringset = arrayop.ranges[ringvar] isa IndexSetRef ?
              (arrayop.ranges[ringvar]::IndexSetRef).from : ringvar
    derived_extents[ringset] = maxn
    ipoly.id === nothing || (derived_extents[ipoly.id] = maxn)
    return clip
end

# The (init, ⊕) fold for a setup-time array reduction, keyed by the aggregate's
# `reduce` / `semiring`. Defaults to SUM (the `sum_product` FAQ additive identity),
# so every existing geometry materialization (`A_j` row-sum, `A_ij` map) is
# byte-identical; `min` / `max` / `prod` support a build-time BINNING-COORDINATE
# projection over an in-file geometry array (e.g. `src_lon[i] = min_v src_poly[i,v,1]`,
# RFC §8.6.1 broad phase) so the coordinate need not be supplied by the host.
function _geo_reduce_fold(reduce_spec, semiring_spec)
    r = reduce_spec !== nothing ? reduce_spec : semiring_spec
    r == "min" && return (Inf, min)
    r == "max" && return (-Inf, max)
    (r == "prod" || r == "*") && return (1.0, *)
    return (0.0, +)   # "+", "sum", "sum_product", or unspecified → additive fold
end

# Materialize a geometry-derived array observed (e.g. `area[p]`, `A_ij[i,j]`) by
# evaluating its `arrayop` body once per output cell against the (already
# materialized) geometry in `env`.
#
# Two shapes are handled uniformly. A pure MAP (`output_idx == ranges` keys, e.g.
# `A_ij[i,j] = polygon_intersection_area(src[i], tgt[j])`) evaluates the body once
# per output cell. A CONTRACTING aggregate — the on-disk einsum form where some
# `ranges` keys are NOT in `output_idx` (e.g. `A_j[j] = Σ_i A_ij[i,j]`, the
# row-sum) — sums the body over the contracted indices for each output cell. Both
# honor the aggregate's `join` / `filter` gate (`_geo_agg_gate`): a rejected
# contraction tuple contributes the additive identity 0̄ (RFC §5.3 / §5.8). This is
# the setup-time twin of the ODE arrayop einsum path.
function _materialize_geom_array(arrayop, env, index_sets, derived_extents,
                                 var_shapes=Dict{String,Vector{String}}())
    out  = String[v for v in arrayop.output_idx]
    exts = Int[_geo_index_extent(arrayop.ranges[v], index_sets, derived_extents) for v in out]
    # Contracted indices: `ranges` keys not among the output indices (§5.1). Their
    # extents are reduced (⊕ = + for the sum_product FAQ) per output cell.
    contract = String[k for k in keys(arrayop.ranges) if !(k in out)]
    # Seed the loop-var → index-set map with this arrayop's output AND contracted
    # indices, so a join can resolve a key column indexed by either (per-cell F_tgt
    # keys on an outer output var; the row-sum keys on the contracted `i`).
    setof = Dict{String,String}()
    for v in Iterators.flatten((out, contract))
        r = arrayop.ranges[v]
        r isa IndexSetRef && (setof[v] = r.from)
    end
    arr  = zeros(Float64, exts...)
    if isempty(contract)
        for tup in Iterators.product((1:e for e in exts)...)
            ie = Dict{String,Any}(zip(out, tup))
            # A no-contraction map still honors an output-cell join/filter gate: a
            # rejected cell keeps the zero-initialized 0̄ (a cross-bin W_ij, a
            # sub-atol sliver). Degenerate (no join/filter) ⇒ gate is always true.
            _geo_agg_gate(arrayop, ie, env, setof, var_shapes, index_sets, derived_extents) || continue
            arr[tup...] = _geo_eval(arrayop.expr_body, env, ie, index_sets, derived_extents,
                                    var_shapes, setof)
        end
    else
        init, fold = _geo_reduce_fold(arrayop.reduce, arrayop.semiring)
        cexts = Int[_geo_index_extent(arrayop.ranges[c], index_sets, derived_extents)
                    for c in contract]
        for tup in Iterators.product((1:e for e in exts)...)
            acc = init
            for ct in Iterators.product((1:e for e in cexts)...)
                ie = Dict{String,Any}(zip(out, tup))
                for (lv, cv) in zip(contract, ct)
                    ie[lv] = cv
                end
                _geo_agg_gate(arrayop, ie, env, setof, var_shapes, index_sets, derived_extents) || continue
                acc = fold(acc, _geo_eval(arrayop.expr_body, env, ie, index_sets, derived_extents,
                                          var_shapes, setof))
            end
            arr[tup...] = acc
        end
    end
    return arr
end

# Geometry-derived ARRAY observeds to materialize at setup: those whose defining
# RHS contains an intersect_polygon (ranged clips), plus the closure of array
# observeds that depend on them WITHOUT touching a state variable. Single direct
# clips (in `geom_ring_vars`) keep the existing 2-D ring path. Returns the set and
# the name → RHS map.
# Every VarExpr name appearing anywhere in `expr` (args / arrayop-aggregate body /
# bounds / makearray values). Unlike `free_variables`, this does NOT treat an
# arrayop/aggregate as binding its references away — we need the array vars an
# expression READS (intersected with declared variable names by the caller, which
# drops bound loop indices). Used for the setup-geometry dependency closure.
function _referenced_var_names(expr, acc::Set{String}=Set{String}())
    if expr isa VarExpr
        push!(acc, expr.name)
    elseif expr isa OpExpr
        for a in expr.args
            _referenced_var_names(a, acc)
        end
        expr.expr_body !== nothing && _referenced_var_names(expr.expr_body, acc)
        expr.lower !== nothing && _referenced_var_names(expr.lower, acc)
        expr.upper !== nothing && _referenced_var_names(expr.upper, acc)
        if expr.values !== nothing
            for v in expr.values
                _referenced_var_names(v, acc)
            end
        end
    end
    return acc
end

function _geometry_setup_vars(model, equations, geom_ring_vars, state_var_names,
                              live_params)
    defs = Dict{String,Expr}()
    for eq in equations
        eq.lhs isa VarExpr || continue
        defs[(eq.lhs::VarExpr).name] = eq.rhs
    end
    is_arr_obs(n) = haskey(model.variables, n) &&
        model.variables[n].type == ObservedVariable &&
        _is_array_shape(model.variables[n].shape)
    # Live taint (ess-14f.4): a var whose defining expression (transitively)
    # reads a `param_arrays` buffer is a LIVE-FIELD observed — its value changes
    # each refresh, so it CANNOT be a build-once setup const. `F_tgt = A_ij ⊗
    # F_src / A_j` mixes setup-const weights (A_ij/A_j) with a live field (F_src):
    # the weights materialize at setup, but F_tgt itself must stay a runtime
    # observed (inlined into its readers below), never pulled into setup where
    # F_src is unbound. Seed from the live param names, propagate through `defs`.
    tainted = Set{String}()
    changed = true
    while changed
        changed = false
        for (n, rhs) in defs
            n in tainted && continue
            refs = _referenced_var_names(rhs)
            if any(r -> (r in live_params) || (r in tainted), refs)
                push!(tainted, n); changed = true
            end
        end
    end
    setup = Set{String}()
    for (n, _) in defs
        (is_arr_obs(n) && !(n in geom_ring_vars) && !(n in tainted) && haskey(defs, n)) || continue
        # Seed on EITHER geometry leaf. `intersect_polygon` surfaces a ragged clip
        # ring (§8.1); the FUSED `polygon_intersection_area` returns the scalar
        # overlap area with no exposed ring (§8.6.1) — so an `A_ij[i,j] =
        # polygon_intersection_area(src[i], tgt[j])` aggregate is a build-once setup
        # const exactly like a ranged clip, just dense (no derived clip_ring set).
        (_expr_has_intersect_polygon(defs[n]) ||
         _expr_has_polygon_intersection_area(defs[n])) && push!(setup, n)
    end
    mvars = Set{String}(keys(model.variables))
    changed = true
    while changed
        changed = false
        for (n, rhs) in defs
            (is_arr_obs(n) && !(n in setup) && !(n in geom_ring_vars) && !(n in tainted)) || continue
            refs = intersect(_referenced_var_names(rhs), mvars)
            if any(f -> (f in setup) || (f in geom_ring_vars), refs) &&
               !any(f -> f in state_var_names, refs)
                push!(setup, n); changed = true
            end
        end
    end
    # Backward pass: also materialize state-free array observeds REFERENCED BY a
    # setup var — the bin buffers a broad-phase `join` gates on (src_bin/tgt_bin),
    # which a setup aggregate reads but which are not themselves geometry-derived.
    # A `const`-op operand (an in-file `src_poly` / `tgt_poly` ring stack the fused
    # leaf gathers per cell) is NOT pulled in here: it is build-time literal data
    # seeded into the setup env directly (and registered as a const_array for the
    # ODE), so it needs no `_materialize_geom_array` pass.
    changed = true
    while changed
        changed = false
        for n in collect(setup)
            for r in intersect(_referenced_var_names(defs[n]), mvars)
                (is_arr_obs(r) && !(r in setup) && !(r in geom_ring_vars) &&
                 !(r in tainted) && haskey(defs, r) && !_is_const_op(defs[r])) || continue
                rrefs = intersect(_referenced_var_names(defs[r]), mvars)
                any(f -> f in state_var_names, rrefs) && continue
                push!(setup, r); changed = true
            end
        end
    end
    return setup, defs, tainted
end

# Dependency order over the setup vars (clip before area before A_ij).
function _geom_setup_order(setup, defs)
    order = String[]; done = Set{String}()
    while length(order) < length(setup)
        progressed = false
        for n in setup
            n in done && continue
            if all(d -> d in done, intersect(_referenced_var_names(defs[n]), setup))
                push!(order, n); push!(done, n); progressed = true
            end
        end
        progressed || throw(TreeWalkError("E_TREEWALK_GEOMETRY_SETUP",
            "cyclic setup-time geometry dependency"))
    end
    return order
end

# A materialized value-invention map buffer (`Dict(position => bin key)`, the
# `src_bin`/`tgt_bin` broad-phase bins) as a dense vector the setup-time join gate
# indexes by loop position. Keys are 1-based positions over the buffer's 1-D index
# set (`_vi_materialize_map!`); the values are the bin keys (a tuple/int from
# `_vi_skolem`), compared only for equality by the gate.
function _vi_buf_vector(buf)
    isempty(buf) && return Any[]
    n = maximum(Int(k) for k in keys(buf))
    v = Vector{Any}(undef, n)
    for (k, val) in buf
        v[Int(k)] = val
    end
    return v
end

# Evaluate the geometry-setup vars in dependency order into const arrays.
# `vi_maps` carries any materialized value-invention bin buffers a setup-time
# broad-phase `join` gates on (RFC §5.3); `param_overrides` carries scalar
# parameter values (e.g. a sliver-filter `atol`, the bin width `dx`/`dy`) so a
# setup-time `filter`/quantization that references them resolves.
function _materialize_geometry_setup(setup, defs, model, const_arrays_kw,
                                     index_sets, derived_extents;
                                     vi_maps=Dict{String,Any}(),
                                     param_overrides=Dict{String,Float64}())
    out = Dict{String,AbstractArray{Float64}}()
    isempty(setup) && return out
    env = Dict{String,Any}()
    for (k, v) in const_arrays_kw
        env[String(k)] = v isa AbstractArray ? Array{Float64}(v) : v
    end
    # `const`-op array observeds (in-file polygon ring stacks / fields) are
    # build-time literal data: seed env with their materialized values so a fused
    # `polygon_intersection_area` aggregate can gather a per-cell ring via
    # `index(src_poly, i)` at setup. A const_arrays kwarg entry (if any) wins.
    for (n, v) in model.variables
        (v.type == ObservedVariable && _is_array_shape(v.shape) && _is_const_op(v.expression)) || continue
        haskey(env, n) && continue
        env[n] = _const_op_to_array((v.expression::OpExpr).value)
    end
    for (n, v) in model.variables
        v.type == ParameterVariable && !_is_array_shape(v.shape) && v.default !== nothing &&
            (env[n] = Float64(v.default))
    end
    # Scalar parameter OVERRIDES win over declared defaults: a setup-time geometry
    # node may reference `atol`/`dx`/`dy` (the sliver floor / bin quantization),
    # which are build-time constants known here but often have no `default`.
    for (k, v) in param_overrides
        env[String(k)] = Float64(v)
    end
    # Materialized value-invention bin buffers (`src_bin`/`tgt_bin`): a setup-time
    # broad-phase `join` gate reads the per-cell bin key from these so the
    # denominator row-sum (`A_j_w = Σ_i A_ij`) contracts over exactly the same
    # candidate set as the numerator — without the gate it sums DENSELY and picks up
    # the spurious sub-grid slivers a spherical clip emits for edge-adjacent cells,
    # breaking the partition of unity (RFC §5.3 / §5.8).
    for (name, buf) in vi_maps
        env[String(name)] = _vi_buf_vector(buf)
    end
    # Declared shapes (index-set names per dim) — used to resolve join key columns.
    var_shapes = Dict{String,Vector{String}}()
    for (n, v) in model.variables
        v.shape === nothing && continue
        var_shapes[n] = String[String(s) for s in v.shape if s isa AbstractString]
    end
    for n in _geom_setup_order(setup, defs)
        rhs = defs[n]
        arr = _is_ranged_clip(rhs) ?
              _materialize_ranged_clip(rhs, env, index_sets, derived_extents, var_shapes) :
              _materialize_geom_array(rhs, env, index_sets, derived_extents, var_shapes)
        env[n] = arr
        out[n] = arr
    end
    return out
end

# ---- Build-time binning-COORDINATE derivation (RFC §8.6.1 broad phase) ----
# A broad-phase binning coordinate may be declared INLINE as a `reduce` aggregate
# over the in-file `const` cell geometry — e.g. a bbox-min corner
# `src_lon[i] = min_v src_poly[i, v, 1]` — instead of being supplied as a `const`
# vector. Such an observed reads only build-time literal geometry (no state, no live
# field), so its value is a build-time constant: it is evaluated ONCE here and fed
# into the value-invention `const_arrays` so `skolem("bin", floor(index(src_lon,i)/dx),
# …)` resolves at setup, and to the typed build as a derived const array (excluded
# from the ODE like any `const`-op array observed). This keeps the fixture PURE — the
# coordinate is derived from geometry, not hand-supplied.

# A reduce-aggregate whose body reads only const-array factors already in `env`
# (never a state / live field), contracting at least one non-output index — i.e. a
# build-time coordinate projection eligible for the derivation above.
_REDUCE_PROJECTION_KINDS = ("min", "max", "sum", "prod")

function _is_reduce_projection_agg(e, env, state_names)
    (e isa OpExpr && _is_aggregate_op(e.op)) || return false
    (e.reduce !== nothing && e.reduce in _REDUCE_PROJECTION_KINDS) || return false
    (e.output_idx !== nothing && !isempty(e.output_idx)) || return false
    (e.ranges !== nothing && !isempty(e.ranges)) || return false
    e.expr_body === nothing && return false
    any(k -> !(k in e.output_idx), keys(e.ranges)) || return false   # genuine reduction
    # Bound loop indices (the aggregate's own `ranges` / `output_idx` symbols) are
    # not data references — only the FACTOR names the body gathers from must be
    # build-time const arrays already in `env`.
    bound = Set{String}(String(k) for k in keys(e.ranges))
    for k in e.output_idx
        push!(bound, String(k))
    end
    for r in _referenced_var_names(e)
        r in bound && continue
        r in state_names && return false        # must be build-time, not live state
        haskey(env, r) || return false          # every referenced factor is a const array
    end
    return true
end

# Evaluate every inline binning-coordinate observed (a `_is_reduce_projection_agg`
# over the in-file `const`-op geometry) into a dense `Vector{Float64}`, reusing the
# reduce-aware setup-time array materializer (`_materialize_geom_array`). Returns
# name → values; empty (byte-identical) for a model without such an observed.
function _derive_binning_coords(model, index_sets, const_arrays_kw, param_overrides)
    out = Dict{String,Vector{Float64}}()
    env = Dict{String,Any}()
    # In-file `const`-op array observeds (the `src_poly` / `tgt_poly` ring stacks) are
    # build-time literal data the projection gathers per cell via `index(src_poly,i)`.
    for (n, v) in model.variables
        (v.type == ObservedVariable && _is_array_shape(v.shape) && _is_const_op(v.expression)) || continue
        env[n] = _const_op_to_array((v.expression::OpExpr).value)
    end
    for (k, v) in const_arrays_kw
        env[String(k)] = v isa AbstractArray ? Array{Float64}(v) : v
    end
    for (n, v) in model.variables
        v.type == ParameterVariable && !_is_array_shape(v.shape) && v.default !== nothing &&
            (env[n] = Float64(v.default))
    end
    for (k, v) in param_overrides
        env[String(k)] = Float64(v)
    end
    state_names = Set{String}(n for (n, v) in model.variables if v.type == StateVariable)
    var_shapes = Dict{String,Vector{String}}()
    for (n, v) in model.variables
        v.shape === nothing && continue
        var_shapes[n] = String[String(s) for s in v.shape if s isa AbstractString]
    end
    derived_extents = Dict{String,Int}()
    for (n, v) in model.variables
        (v.type == ObservedVariable && _is_array_shape(v.shape)) || continue
        _is_reduce_projection_agg(v.expression, env, state_names) || continue
        arr = _materialize_geom_array(v.expression, env, index_sets, derived_extents, var_shapes)
        out[n] = vec(Array{Float64}(arr))
    end
    return out
end

const _EMPTY_DERIVED_EXTENTS = Dict{String,Int}()

# An explicit empty shape (`[]`, a rank-0 declaration) is scalar, not an array;
# only a non-empty declared shape marks an array variable. `nothing` (no shape) is
# also scalar.
_is_array_shape(shape) = shape !== nothing && !isempty(shape)

# ---- Const-array boundary policy (ess-gj4) ----
# A const array (Fornberg weights, mesh connectivity, a per-cell metric factor)
# may carry a per-dimension boundary policy so that a stencil gather at an
# out-of-range index resolves declaratively instead of erroring. This mirrors the
# state-variable gather, which honors grid periodicity (periodic-wrap) and applies
# a finite boundary policy at non-periodic edges. The covariant-FV connection
# terms gather metric factors at lat±1 / lon±1 offsets; on a lon-periodic metric
# those must WRAP, and at a non-periodic lat pole they must edge-extend — the
# zero-ghost convention is physically wrong for a metric.
#
# Per-dimension policy symbols:
#   :periodic — wrap the index into 1..N via mod1; correct for a periodic axis.
#   :clamp    — edge-extend (clamp to 1..N); the correct finite policy for a
#               metric/geometry factor at a non-periodic boundary.
#   :error    — throw E_TREEWALK_CONSTARRAY_OOB (default for any array WITHOUT a
#               declared policy, so genuine out-of-bounds bugs in connectivity /
#               stencil-weight factors are never masked).
const _CONST_BOUNDARY_KINDS = (:periodic, :clamp, :error)

# A const array tagged with a per-dimension boundary policy. It IS an
# `AbstractArray{Float64,N}` (forwards size/getindex to `data`), so it flows
# through the existing `const_arrays` threading transparently; only the gather's
# out-of-range handling branches on the wrapper via `_const_dim_boundary`.
struct BoundedConstArray{N} <: AbstractArray{Float64,N}
    data::Array{Float64,N}
    boundary::NTuple{N,Symbol}   # per-dim: :periodic | :clamp | :error
end
Base.size(a::BoundedConstArray) = size(a.data)
Base.IndexStyle(::Type{<:BoundedConstArray}) = IndexLinear()
Base.@propagate_inbounds Base.getindex(a::BoundedConstArray, i::Int) = a.data[i]

# Per-dimension boundary policy: declared dims for a BoundedConstArray, :error
# (throw on OOB) for any plain const array.
_const_dim_boundary(a::BoundedConstArray, d::Int) = a.boundary[d]
_const_dim_boundary(::AbstractArray, ::Int) = :error

# Resolve a possibly-out-of-range 1-based index `i` in dimension `d` (size `n`) of
# const array `name` per its boundary policy. In-range indices pass through.
function _resolve_const_index(arr::AbstractArray, name::AbstractString,
                              d::Int, i::Int, n::Int)
    (1 <= i <= n) && return i
    pol = _const_dim_boundary(arr, d)
    if n >= 1
        pol === :periodic && return mod1(i, n)
        pol === :clamp && return clamp(i, 1, n)
    end
    throw(TreeWalkError("E_TREEWALK_CONSTARRAY_OOB",
          "const array '$(name)' index $(i) out of range 1..$(n) in dim $(d)"))
end

# Wrap a const array with a declared per-dimension boundary policy. `boundary` is
# an iterable of per-dim policy symbols (or strings); its length must equal the
# array rank and each entry must be one of `_CONST_BOUNDARY_KINDS`.
function _wrap_bounded_const(arr::Array{Float64,N}, boundary, name::AbstractString) where {N}
    syms = Symbol[Symbol(b) for b in boundary]
    length(syms) == N ||
        throw(TreeWalkError("E_TREEWALK_CONSTARRAY_BOUNDARY_NDIM",
              "const array '$(name)' boundary has $(length(syms)) dims but array is $(N)D"))
    for s in syms
        s in _CONST_BOUNDARY_KINDS ||
            throw(TreeWalkError("E_TREEWALK_CONSTARRAY_BOUNDARY_KIND",
                  "const array '$(name)' boundary '$(s)' must be one of $(_CONST_BOUNDARY_KINDS)"))
    end
    return BoundedConstArray{N}(arr, NTuple{N,Symbol}(syms))
end

# ---- Whole-array declared-shape derivative lift -------------------------------
# A declared array-shaped state may be integrated by a WHOLE-ARRAY equation
# `D(SST) = <array-valued rhs>` (bare `VarExpr` LHS, no per-cell `index`). The
# tree-walk's derivative partition only recognises `D(scalar)`, `D(index(var,k))`,
# and `arrayop(D(index(var,…)))`, so lift the whole-array form into the `arrayop`
# per-cell form the machinery already consumes: loop over the state's declared
# shape index set(s), gathering every array operand of the rhs per cell (a genuine
# scalar / reduction leaf is left as-is by `_index_array_leaves`). This also lets
# `_discover_array_cells` enumerate the state's cells from the lifted `arrayop`
# ranges — a declared array state with a broadcast `ic` and no per-cell equation
# otherwise resolves to no cells.
function _lift_wholearray_deriv_equations(eqs::Vector{Equation},
        var_shapes::Dict{String,Vector{String}}, arrayvars::Set{String},
        index_sets::AbstractDict)
    any(eq -> eq.lhs isa OpExpr && (eq.lhs::OpExpr).op == "D" &&
              length((eq.lhs::OpExpr).args) == 1 &&
              (eq.lhs::OpExpr).args[1] isa VarExpr &&
              (eq.lhs::OpExpr).args[1].name in arrayvars, eqs) || return eqs
    out = Equation[]
    for eq in eqs
        lhs = eq.lhs
        if lhs isa OpExpr && lhs.op == "D" && length(lhs.args) == 1 &&
           lhs.args[1] isa VarExpr && (lhs.args[1]::VarExpr).name in arrayvars
            vname = (lhs.args[1]::VarExpr).name
            shape = var_shapes[vname]
            loops = String["_lp$(i-1)_$(vname)" for i in 1:length(shape)]
            ranges = Dict{String,Any}()
            for i in eachindex(shape)
                ranges[loops[i]] = haskey(index_sets, shape[i]) ?
                    IndexSetRef(shape[i]) : IndexSetRef(shape[i])
            end
            idx_args = Expr[VarExpr(vname)]
            for l in loops
                push!(idx_args, VarExpr(l))
            end
            lhs_body = OpExpr("D", Expr[OpExpr("index", idx_args)]; wrt=lhs.wrt)
            new_lhs = OpExpr("arrayop", Expr[];
                             output_idx=Any[l for l in loops], ranges=ranges,
                             expr_body=lhs_body)
            new_rhs = _index_array_leaves(eq.rhs, arrayvars, loops)
            push!(out, Equation(new_lhs, new_rhs; _comment=eq._comment))
        else
            push!(out, eq)
        end
    end
    return out
end

function _build_evaluator_impl(model::Model;
                         initial_conditions::AbstractDict=Dict{String,Float64}(),
                         parameter_overrides::AbstractDict=Dict{String,Float64}(),
                         tspan::Union{Nothing,Tuple{<:Real,<:Real}}=nothing,
                         registered_functions::AbstractDict=Dict{String,Function}(),
                         const_arrays::AbstractDict=Dict{String,Vector{Float64}}(),
                         # Live forcing buffers bound BY REFERENCE (ess-14f.3, JL-J0).
                         # Each value MUST be a dense `Array{Float64}`; its `index(…)`
                         # reads compile to live `_NK_PARAM_GATHER`/`_VK_PGATHER`
                         # nodes over an aliased flat view, so a discrete-cadence
                         # refresh callback's in-place `buffer .= …` is seen by the
                         # RHS with zero reallocation. This is the discrete-cadence
                         # channel; const-cadence data stays on `const_arrays` (frozen
                         # literal inlining). Disjoint from the scalar `p` NamedTuple
                         # so existing scalar-param reads stay byte-identical + 0-alloc.
                         param_arrays::AbstractDict=Dict{String,Any}(),
                         # Per-const-array boundary policy (ess-gj4): name → an
                         # iterable of per-dimension policy symbols (:periodic |
                         # :clamp | :error). A const array named here is wrapped so
                         # an out-of-range stencil gather resolves declaratively
                         # (periodic-wrap / edge-extend) instead of throwing.
                         # Arrays absent from this map keep the throw-on-OOB
                         # default. Mirrors the grid periodicity honored by the
                         # state-variable gather.
                         const_array_boundaries::AbstractDict=Dict{String,Any}(),
                         # Document-scoped index-set registry (RFC §5.2; esm-spec
                         # v0.8.0). Supplied by the `EsmFile` / `AbstractDict`
                         # front-doors from the top-level `index_sets` object;
                         # `ranges[*]` `{from}`, join gates, and derived-set ranges
                         # resolve against it. Empty on a bare `Model` call.
                         index_sets::AbstractDict=Dict{String,IndexSet}(),
                         # Internal: value-invention materialisation results, set by
                         # the AbstractDict front-door (RFC §6.1). `_vi_extents` maps a
                         # `from_faq` producer id to its materialised derived-index-set
                         # extent; `_vi_vars` are the value-invention LHS vars to drop
                         # from the ODE (the relational outputs run once at setup, off
                         # the hot path — never integrated). Empty on a direct call.
                         _vi_extents::AbstractDict=Dict{String,Int}(),
                         _vi_vars=Set{String}(),
                         # Materialised value-invention map buffers (e.g. `src_bin`)
                         # a downstream `join.on [[src_bin, tgt_bin]]` gates on, plus
                         # each buffer's 1-D shape index set. Set by the AbstractDict
                         # front-door; empty on a direct typed call (RFC §5.3 / §6.1).
                         _vi_maps=_EMPTY_VI_MAPS)
    _has_value_invention = !isempty(_vi_vars)
    # ---- Observed-from-expression synthesis (universal) ----
    # Observed variables may be defined by their `expression` field rather than
    # an explicit equation; synthesize an observed equation `name = expression`
    # for each so-defined observed (skipping any an equation already defines) so
    # they flow through the same ISR-resolution / observed-substitution pipeline
    # as equation-defined observeds. This is the transitive-inlining path that
    # lets a DEEP algebraic chain — e.g. the flattened Rothermel fire-physics
    # chain reconstituted by `flattened_to_esm` — resolve through `build_evaluator`
    # with NO caller pre-inlining (`_resolve_observed` collapses the chain to a
    # fixed point below). It used to be gated on `_has_geometry`, which left a
    # non-geometry expression-defined observed unbound. Synthesis only ADDS
    # equations for observeds lacking one, so equation-defined models stay
    # byte-identical.
    _has_geometry = _model_has_intersect_polygon(model)
    _model_equations = model.equations
    let synth = Equation[]
        for (name, v) in model.variables
            (v.type == ObservedVariable && v.expression isa Expr) || continue
            any(eq -> eq.lhs isa VarExpr && (eq.lhs::VarExpr).name == name,
                model.equations) && continue
            push!(synth, Equation(VarExpr(name), v.expression))
        end
        isempty(synth) || (_model_equations = vcat(model.equations, synth))
    end
    # ---- Whole-array declared-shape derivative lift ----
    # A WHOLE-ARRAY `D(state) = <array rhs>` over a declared shape is lifted into
    # the per-cell `arrayop` form the derivative partition consumes (see
    # `_lift_wholearray_deriv_equations`). Spatial-operator zeroing over a
    # structurally-0-D field is done EARLIER, at the flatten→document boundary
    # (`flattened_to_esm`), so a raw `grad`/`div`/`laplacian` reaching the compiler
    # directly (a hand-built Model, never discretized) still hard-errors as the
    # pipeline-violation guard requires. No-op for a model without a whole-array D.
    let _var_shapes = Dict{String,Vector{String}}()
        for (n, v) in model.variables
            v.shape === nothing && continue
            _var_shapes[n] = String[String(s) for s in v.shape]
        end
        _arrayvars = Set{String}(n for (n, v) in model.variables if _is_array_shape(v.shape))
        _model_equations = _lift_wholearray_deriv_equations(_model_equations,
                _var_shapes, _arrayvars, index_sets)
    end
    # The FUSED `polygon_intersection_area` leaf (§8.6.1) triggers the SAME
    # setup-geometry machinery as `intersect_polygon`: an array observed whose
    # aggregate body is the fused leaf (`A_ij[i,j] = polygon_intersection_area(
    # src[i], tgt[j])`) is a build-once setup const over the in-file polygon rings.
    # `_has_setup_geometry` gates the setup-vars discovery / materialization so the
    # ranged narrow phase compiles even when NO `intersect_polygon` node survives.
    _has_pia = _model_has_polygon_intersection_area(model, _model_equations)
    _has_setup_geometry = _has_geometry || _has_pia
    # `_geom_ring_vars` are the (array-shaped) observed variables whose defining
    # expression is an intersect_polygon clip; they are materialized into
    # const_arrays at setup (RFC §8.1) rather than treated as scalar observeds.
    _geom_ring_vars = Set{String}()
    if _has_geometry
        for eq in _model_equations
            if eq.lhs isa VarExpr && eq.rhs isa OpExpr &&
               (eq.rhs::OpExpr).op == "intersect_polygon"
                push!(_geom_ring_vars, (eq.lhs::VarExpr).name)
            end
        end
    end
    # Geometry-derived ARRAY observeds (ranged clips, per-pair areas, A_ij) are
    # materialized at setup (below) and excluded from the ODE partition / observed
    # substitution — they are build-once functions of the const polygon inputs.
    _geom_setup_vars = Set{String}()
    _geom_defs = Dict{String,Expr}()
    # Live-field geometry observeds (ess-14f.4): array observeds that are NOT
    # build-once setup vars because they read a live `param_arrays` buffer (the
    # conservative-regrid output F_tgt = A_ij ⊗ F_src / A_j is the motivating case).
    # They are INLINED into the array-state RHS that consumes them, so the
    # build-time `index(arrayop,…)` reducer collapses `index(F_tgt, j)` to F_tgt's
    # body — yielding the proven array-state aggregate kernel (const A_ij/A_j +
    # live F_src), the met→fire coupling edge. Empty (byte-identical) for files
    # whose geometry outputs are all const-fed (they stay setup vars).
    _geom_inline_vars = Set{String}()
    if _has_setup_geometry
        _pre_state_names = Set{String}(n for (n, v) in model.variables
                                       if v.type == StateVariable && !(n in _vi_vars))
        _live_param_names = Set{String}(String(k) for k in keys(param_arrays))
        _geom_setup_vars, _geom_defs, _geom_live_tainted =
            _geometry_setup_vars(model, _model_equations, _geom_ring_vars,
                                 _pre_state_names, _live_param_names)
        for (name, v) in model.variables
            (v.type == ObservedVariable && _is_array_shape(v.shape) &&
             !(name in _geom_setup_vars) && !(name in _geom_ring_vars) &&
             name in _geom_live_tainted && haskey(_geom_defs, name) &&
             _geom_defs[name] isa OpExpr) || continue
            push!(_geom_inline_vars, name)
        end
    end

    # Promoted array observeds (shape-promotion): an array-shaped observed defined
    # by an `arrayop` is inlined into its readers via the same index beta-reduction
    # as a live-field geometry observed (`index(obs, i…)` collapses to the arrayop
    # body) — it carries no ODE partition slot. This generalizes `_geom_inline_vars`
    # to the non-geometry case, so a `promote_downstream_shapes`-lifted physics
    # chain (scalar authored, array after promotion) runs with no per-cell runner
    # logic. Excludes anything the geometry path already owns. Empty (byte-identical)
    # for a system with no array observeds.
    _array_inline_vars = Set{String}()
    for eq in _model_equations
        eq.lhs isa VarExpr || continue
        name = (eq.lhs::VarExpr).name
        (name in _geom_setup_vars || name in _geom_ring_vars ||
         name in _geom_inline_vars) && continue
        haskey(model.variables, name) || continue
        v = model.variables[name]
        (v.type == ObservedVariable && _is_array_shape(v.shape)) || continue
        (eq.rhs isa OpExpr && (eq.rhs::OpExpr).op == "arrayop") || continue
        push!(_array_inline_vars, name)
    end

    # ---- polygon_intersection_area fused leaf (esm-spec §8.6.1) ----
    # `polygon_intersection_area(a, b)` is a SCALAR overlap-area leaf (the fused
    # clip+shoelace). Its polygon operands are build-time-known const vertex rings;
    # resolve each into a matrix (a `const_arrays` kwarg entry wins, else the
    # operand's own `const`-op observed value) so the leaf const-folds in
    # `_resolve_indices`. Each operand array observed is materialized into
    # `_const_arrays` and excluded from the ODE partition — it carries no state,
    # exactly like an intersect_polygon clip ring (RFC §8.1). Empty (byte-identical)
    # for every file without a polygon_intersection_area node. (`_has_pia` is
    # computed once, above, where it also arms the setup-geometry machinery for the
    # RANGED narrow phase — an indexed-operand fused leaf inside an array aggregate.)
    _pia_operand_vars = Set{String}()
    _pia_operand_arrays = Dict{String,Matrix{Float64}}()
    if _has_pia
        _pia_names = Set{String}()
        for eq in _model_equations
            _collect_pia_operands!(eq.lhs, _pia_names)
            _collect_pia_operands!(eq.rhs, _pia_names)
        end
        for (_, v) in model.variables
            v.expression isa Expr && _collect_pia_operands!(v.expression, _pia_names)
        end
        for name in _pia_names
            mat = if haskey(const_arrays, name)
                Matrix{Float64}(const_arrays[name])
            elseif haskey(model.variables, name) &&
                   model.variables[name].expression isa OpExpr &&
                   (model.variables[name].expression::OpExpr).op == "const"
                _pia_const_matrix((model.variables[name].expression::OpExpr).value)
            else
                throw(TreeWalkError("E_TREEWALK_GEOMETRY_OPERAND",
                    "polygon_intersection_area operand '$(name)' must be a const polygon " *
                    "ring (supplied via `const_arrays` or a `const`-op observed)"))
            end
            _pia_operand_arrays[name] = mat
            (haskey(model.variables, name) && _is_array_shape(model.variables[name].shape)) &&
                push!(_pia_operand_vars, name)
        end
    end

    # ---- const-op array observeds (in-file polygon rings / source fields) ----
    # A `const`-op observed with an ARRAY shape (`src_poly[cell,vert,coord]`, a
    # `F_src[cell]` field) is build-time literal data, not a scalar observed and not
    # a state. When the ranged narrow phase is in play, materialize each into
    # `_const_arrays` (so a fused-leaf aggregate gathers `index(src_poly,i)` at setup
    # and an ODE reads `index(F_src,i)`) and exclude it from the ODE partition —
    # exactly like an intersect_polygon clip ring (RFC §8.1) or a fused-leaf operand.
    # Operands already owned by the scalar-leaf `_pia` path or a setup ring are left
    # to those. Empty (byte-identical) for files without the ranged geometry.
    _const_obs_vars = Set{String}()
    _const_obs_arrays = Dict{String,Array{Float64}}()
    if _has_setup_geometry
        for (name, v) in model.variables
            (v.type == ObservedVariable && _is_array_shape(v.shape) &&
             _is_const_op(v.expression) && !(name in _pia_operand_vars) &&
             !(name in _geom_ring_vars)) || continue
            _const_obs_arrays[name] = _const_op_to_array((v.expression::OpExpr).value)
            push!(_const_obs_vars, name)
        end
    end
    # A build-time BINNING-COORDINATE observed (an inline reduce aggregate over
    # geometry, e.g. `src_lon[i] = min_v src_poly[i,v,1]`) is derived once by the
    # AbstractDict front-door and supplied to the typed build as a `const_arrays`
    # entry (RFC §8.6.1 purity). Like a `const`-op ring stack it is build-time
    # literal data feeding the broad-phase skolem, so materialize it into the const
    # arrays and drop it from the ODE partition — not a scalar observed / state.
    if _has_setup_geometry || _has_value_invention
        for (name, v) in model.variables
            (v.type == ObservedVariable && _is_array_shape(v.shape) &&
             haskey(const_arrays, name) && !(name in _const_obs_vars) &&
             !(name in _pia_operand_vars) && !(name in _geom_ring_vars) &&
             !_is_const_op(v.expression)) || continue
            _const_obs_arrays[name] = Array{Float64}(const_arrays[name])
            push!(_const_obs_vars, name)
        end
    end

    # ---- Partition variables ----
    scalar_state_names = String[]
    param_names = String[]
    observed_names = String[]
    state_var_names = Set{String}()
    for (name, v) in model.variables
        # Value-invention outputs (skolem/distinct/rank) are materialized once at
        # setup (RFC §6.1) and never enter the ODE — drop them from every
        # partition, exactly as a geometry clip-ring observed is not a scalar.
        name in _vi_vars && continue
        # Geometry-setup vars are materialized at setup; not an ODE partition member.
        name in _geom_setup_vars && continue
        # Live-field geometry observeds (F_tgt …) and promoted array observeds are
        # inlined into their readers (ess-14f.4 / shape-promotion); no partition slot.
        name in _geom_inline_vars && continue
        name in _array_inline_vars && continue
        # polygon_intersection_area operand rings (const polygon vertex rings) are
        # materialized into const_arrays and read by the fused leaf; not a partition
        # member (they carry no state — like an intersect_polygon clip ring).
        name in _pia_operand_vars && continue
        # const-op array observeds (in-file ring stacks / source fields) are
        # materialized into const_arrays; build-time data, not a partition member.
        name in _const_obs_vars && continue
        if v.type == StateVariable
            push!(state_var_names, name)
        elseif v.type == ParameterVariable
            if _is_array_shape(v.shape)
                # An array-shaped parameter is supported only when supplied as
                # const data (e.g. the polygon operands of an intersect_polygon
                # clip, RFC Appendix B.1; or the connectivity / coordinate factors
                # a value-invention key is computed from, §5.2) OR as a live
                # forcing buffer via `param_arrays` (a discrete-cadence loader
                # buffer, ess-14f.3). Either way it is array-backed, not a scalar
                # parameter, so it is NOT added to param_names (the scalar `p`
                # NamedTuple stays homogeneous Float64 — see the JL-J0 note).
                # Array-backed: a const operand (geometry polygons, VI factors, or a
                # promoted forcing array) or a live `param_arrays` forcing buffer.
                haskey(const_arrays, name) || haskey(param_arrays, name) ||
                    throw(TreeWalkError("E_TREEWALK_UNSUPPORTED_SHAPE", name))
            else
                push!(param_names, name)
            end
        elseif v.type == ObservedVariable
            if _is_array_shape(v.shape)
                # An array-shaped observed is supported only for an
                # intersect_polygon clip ring, materialized into a const_array at
                # setup (RFC §8.1); the polygon_area FAQ then ranges over it.
                (name in _geom_ring_vars) ||
                    throw(TreeWalkError("E_TREEWALK_UNSUPPORTED_SHAPE", name))
            else
                push!(observed_names, name)
            end
        elseif v.type == BrownianVariable
            throw(TreeWalkError("E_TREEWALK_UNSUPPORTED_BROWNIAN", name))
        end
    end
    sort!(param_names)

    # ---- M4: materialize intersect_polygon clip rings at setup time ----
    # Each clip is evaluated now (operands are const_arrays) into a CLOSED ring,
    # registered below as a 2D const_array; `_derived_extents` maps each clip's
    # `from_faq` key to its distinct-vertex count so the derived clip-ring index
    # set resolves to `[1, n]` for the polygon_area FAQ.
    _geom_rings = Dict{String,Matrix{Float64}}()
    _derived_extents = (_has_geometry || _has_value_invention) ?
        Dict{String,Int}() : _EMPTY_DERIVED_EXTENTS
    if _has_geometry
        _geom_rings, geom_extents =
            _materialize_geometry_rings(_model_equations, const_arrays, _geom_ring_vars)
        merge!(_derived_extents, geom_extents)
    end
    # M4+: materialize the ranged-clip / per-pair-area / A_ij geometry into const
    # arrays (and record the per-pair clip_ring extent) BEFORE index-set ranges are
    # resolved, so the polygon_area FAQ's `clip_ring` range lowers to `[1, maxn]`.
    _geom_setup_arrays = Dict{String,AbstractArray{Float64}}()
    if !isempty(_geom_setup_vars)
        _geom_setup_arrays = _materialize_geometry_setup(_geom_setup_vars, _geom_defs,
            model, const_arrays, index_sets, _derived_extents;
            vi_maps=_vi_maps.maps, param_overrides=parameter_overrides)
    end
    # Value-invention derived index sets (skolem/distinct/rank) materialized via
    # the relational engine in the AbstractDict front-door (RFC §6.1 / §5.5):
    # supply each producer's distinct-set cardinality as the resolver's dense
    # extent `[1, n]`, generalizing the geometry handoff to the relational engine.
    merge!(_derived_extents, Dict{String,Int}(String(k) => Int(v) for (k, v) in _vi_extents))

    # Geometry-setup vars (ranged clips / per-pair area / A_ij / their bin buffers)
    # and direct clip rings are materialized at setup — drop their equations before
    # the ODE-lowering passes so their join/filter/intersect_polygon nodes never
    # reach the join-gate / index-set-range resolvers (those expect the relational/
    # value-invention vocabulary, not the setup-geometry one).
    # A polygon_intersection_area operand's const-ring equation is likewise dropped:
    # its ring is materialized into const_arrays above, so its synthetic
    # `operand = const(...)` equation must not reach the ODE-lowering passes.
    _ode_equations = Equation[eq for eq in _model_equations
        if !(eq.lhs isa VarExpr && ((eq.lhs::VarExpr).name in _geom_ring_vars ||
                                    (eq.lhs::VarExpr).name in _geom_setup_vars ||
                                    (eq.lhs::VarExpr).name in _pia_operand_vars ||
                                    (eq.lhs::VarExpr).name in _const_obs_vars))]

    # ---- Resolve value-equality joins (RFC §5.3) ----
    # Rewrite each aggregate's `join` clauses into build-time `join_gates` (a
    # canonical bucket code per key-column position) BEFORE index-set ranges are
    # resolved away — categorical members are read from the still-present
    # `{from}` references here. No-op (byte-identical) for files without a join.
    equations = _resolve_join_gates(_ode_equations, index_sets, _vi_maps)
    init_equations = _resolve_join_gates(model.initialization_equations,
                                         index_sets, _vi_maps)

    # ---- Resolve index-set references in ranges (RFC §5.2) ----
    # Rewrite any `ranges[*]` `{from: <name>}` reference against the document's
    # `index_sets` registry into the dense / dynamic-bound form the range
    # machinery already consumes, BEFORE any range expansion runs. No-op (and
    # therefore byte-identical) for files that use no `{from}` references.
    equations = _resolve_index_set_ranges(equations, index_sets, _derived_extents)
    init_equations = _resolve_index_set_ranges(init_equations,
                                               index_sets, _derived_extents)

    # ---- Drop value-invention equations from the ODE (RFC §6.1) ----
    # The skolem/distinct/rank LHS vars are materialized at setup, not integrated;
    # their defining equations (a relational aggregate RHS) must not reach the
    # numeric pipeline. Their derived index-set extents were already harvested
    # above, so the index-set ranges resolved before this filter.
    if _has_value_invention
        equations = Equation[eq for eq in equations
                             if !(_vi_typed_lhs_base(eq.lhs) in _vi_vars)]
        init_equations = Equation[eq for eq in init_equations
                                  if !(_vi_typed_lhs_base(eq.lhs) in _vi_vars)]
    end

    # ---- Fold `ic(var) = <initial value>` equations into u0 (esm-spec v0.8.0) ----
    # An `ic`-LHS equation declares an initial condition. The tree-walk path seeds
    # u0 from the `initial_conditions` kwarg / variable defaults, so pull each ic
    # equation out here: const-fold its RHS to a scalar and record it (unless the
    # caller already overrode that state), then drop the equation before the ODE
    # partition / observed-substitution passes (its LHS is not a `D`, so it would
    # otherwise be rejected as an unsupported equation form). No-op for files
    # without an ic equation in `equations`.
    _eq_ics = Dict{String,Float64}()
    # Scoped-reference / array `ic` targets (spec §11.4.1) are deferred here and
    # folded per grid cell once array cells are known (below). Each entry is
    # `(target_state_name, rhs_field_expr)`; the target may be a dot-namespaced
    # reference to another component's species that coupling has lifted onto the
    # grid (`ic(Chemistry.O3) ~ InitialConditions.O3_init`), and the RHS is a
    # per-cell FIELD (a loaded const-array field, a broadcast constant, or a
    # coordinate expression) rather than a single scalar.
    _field_ics = Tuple{String,EarthSciSerialization.Expr}[]
    let kept = Equation[]
        for eq in equations
            if eq.lhs isa OpExpr && (eq.lhs::OpExpr).op == "ic"
                lop = eq.lhs::OpExpr
                (length(lop.args) == 1 && lop.args[1] isa VarExpr) ||
                    throw(TreeWalkError("E_TREEWALK_UNSUPPORTED_EQUATION",
                        "ic(...) LHS must name a single state variable"))
                vn = (lop.args[1]::VarExpr).name
                # An `ic` whose target is an array-shaped state variable is a
                # scoped-reference / field IC: defer it (its RHS is a field, not
                # a scalar). A scalar target keeps the const-fold fast path.
                _tvar = get(model.variables, vn, nothing)
                if _tvar !== nothing && _is_array_shape(_tvar.shape)
                    push!(_field_ics, (vn, eq.rhs))
                else
                    _eq_ics[vn] = try
                        Float64(evaluate_expr(eq.rhs, Dict{String,Float64}();
                                              registered_functions=registered_functions))
                    catch err
                        throw(TreeWalkError("E_TREEWALK_UNSUPPORTED_EQUATION",
                            "ic($(vn)) RHS must const-fold to a scalar for the tree-walk path"))
                    end
                end
            else
                push!(kept, eq)
            end
        end
        equations = kept
    end

    # ---- Discover array cells from equations and initial conditions ----
    # Array variable detection: a variable is treated as an array if it has
    # an explicit non-empty shape, OR if it appears inside index(var, k...)
    # in an equation LHS. This handles both declared-shape variables and the
    # common pattern where shape=nothing but equations use D(index(var, k)). An
    # explicit empty shape (`[]`, rank-0) is scalar, not an array.
    array_var_names_declared = Set{String}(n for (n, v) in model.variables
                                           if v.type == StateVariable &&
                                              _is_array_shape(v.shape) &&
                                              !(n in _vi_vars))
    # Detect array usage from equations even when shape is not declared.
    array_var_names = _detect_array_vars(equations, state_var_names,
                                         initial_conditions)
    union!(array_var_names, array_var_names_declared)

    # array_cells: var_name → sorted list of index-tuples (1-based)
    array_cells = _discover_array_cells(equations, initial_conditions,
                                        array_var_names)

    # A declared array STATE may carry only an `ic` and NO per-cell / whole-array
    # `D` equation (a constant field held at its initial value, e.g. an ocean
    # current pinned to 0). Such a state appears in no equation LHS and no per-cell
    # ic key, so `_discover_array_cells` finds no cells for it — yet it needs one
    # u0 slot per cell. Enumerate its cells from the declared shape's index-set
    # extents (interval size / categorical cardinality / derived-set extent), the
    # same registry the range machinery resolves. No-op for a state whose cells the
    # equations already pin.
    for (n, v) in model.variables
        (v.type == StateVariable && _is_array_shape(v.shape) && !(n in _vi_vars)) || continue
        (haskey(array_cells, n) && !isempty(array_cells[n])) && continue
        exts = Int[]
        ok = true
        for s in v.shape
            ss = String(s)
            e = if haskey(index_sets, ss)
                is = index_sets[ss]
                is.kind == "interval" ? is.size :
                is.kind == "categorical" ? (is.members === nothing ? nothing : length(is.members)) :
                get(_derived_extents, ss, nothing)
            else
                get(_derived_extents, ss, nothing)
            end
            e === nothing && (ok = false; break)
            push!(exts, Int(e))
        end
        ok || continue
        cells = Vector{Int}[collect(Int, Tuple(I)) for I in CartesianIndices(Tuple(exts))]
        array_cells[n] = sort!(cells)
    end

    # Scalar state variables: all state vars not treated as arrays.
    for name in state_var_names
        name in array_var_names || push!(scalar_state_names, name)
    end
    sort!(scalar_state_names)

    # Build per-var bounds for in-bounds / ghost-cell checks.
    # array_var_info: var_name → (lo::Vector{Int}, hi::Vector{Int})
    array_var_info = Dict{String, Tuple{Vector{Int},Vector{Int}}}()
    for (vname, cells) in array_cells
        isempty(cells) && continue
        ndim = length(cells[1])
        lo = [minimum(c[d] for c in cells) for d in 1:ndim]
        hi = [maximum(c[d] for c in cells) for d in 1:ndim]
        array_var_info[vname] = (lo, hi)
    end

    # ---- Fold scoped-reference / array `ic` equations into u0 (spec §11.4.1) ----
    # Now that each array state's cells are known, expand every deferred field-ic
    # into per-element initial values keyed by the flat element name. The RHS may
    # be a LOADED FIELD (a `const_arrays` entry supplying the initial field over
    # the lifted grid), a broadcast constant, or a coordinate expression. Folding
    # here means the array-cell u0 seeding below (and callers that don't override)
    # pick these up exactly like a model-local `ic`. A target that resolves to no
    # array cells, or an RHS the seed path cannot evaluate, is a hard error — a
    # missing/unsupported scoped ic is never silently dropped.
    for (target, rhs) in _field_ics
        cells = get(array_cells, target, nothing)
        (cells === nothing || isempty(cells)) && throw(TreeWalkError(
            "E_TREEWALK_UNSUPPORTED_EQUATION",
            "ic($(target)): scoped-reference target resolves to no array cells; the " *
            "target must name a lifted/array state variable of the flattened system"))
        for cell in cells
            idxs = collect(Int, cell)
            _eq_ics[_cell_key(target, idxs)] =
                _resolve_field_ic(target, rhs, idxs, const_arrays, registered_functions)
        end
    end

    # ---- Build flat state vector: scalars first, then array cells ----
    # Array cells are enumerated in column-major order (first index fastest,
    # consistent with Julia's native array layout and the Rust/Python runtimes).
    array_cell_names = String[]
    for vname in sort(collect(keys(array_cells)))
        haskey(array_var_info, vname) || continue
        lo, hi = array_var_info[vname]
        shape = hi .- lo .+ 1
        ndim = length(lo)
        for linear in 0:prod(shape)-1
            indices = Vector{Int}(undef, ndim)
            r = linear
            for d in 1:ndim
                indices[d] = lo[d] + (r % shape[d])
                r = r ÷ shape[d]
            end
            push!(array_cell_names, _cell_key(vname, indices))
        end
    end

    all_state_names = vcat(scalar_state_names, array_cell_names)
    var_map = Dict{String,Int}(name => i for (i, name) in enumerate(all_state_names))

    # ---- Initial condition vector ----
    u0 = Vector{Float64}(undef, length(all_state_names))
    for (i, name) in enumerate(scalar_state_names)
        if haskey(initial_conditions, name)
            u0[i] = Float64(initial_conditions[name])
        elseif haskey(_eq_ics, name)
            u0[i] = _eq_ics[name]   # ic(var) = <value> equation
        else
            d = model.variables[name].default
            u0[i] = d === nothing ? 0.0 : Float64(d)
        end
    end
    n_scalar = length(scalar_state_names)
    for (i_rel, cname) in enumerate(array_cell_names)
        i_abs = n_scalar + i_rel
        if haskey(initial_conditions, cname)
            u0[i_abs] = Float64(initial_conditions[cname])
        elseif haskey(_eq_ics, cname)
            u0[i_abs] = _eq_ics[cname]   # scoped-reference / array ic (§11.4.1)
        else
            # Try the parent variable's scalar default (rare fallback).
            m = match(r"^([^\[]+)\[", cname)
            vname = m === nothing ? "" : m.captures[1]
            if haskey(model.variables, vname)
                d = model.variables[vname].default
                u0[i_abs] = d === nothing ? 0.0 : Float64(d)
            else
                u0[i_abs] = 0.0
            end
        end
    end

    # ---- Parameter NamedTuple ----
    p_vals = Float64[]
    p_syms = Symbol[]
    for name in param_names
        push!(p_syms, Symbol(name))
        if haskey(parameter_overrides, name)
            push!(p_vals, Float64(parameter_overrides[name]))
        else
            d = model.variables[name].default
            push!(p_vals, d === nothing ? 0.0 : Float64(d))
        end
    end
    # Use `nothing` for parameter-free models: some SciMLBase versions enter
    # an infinite recursion in SymbolicIndexingInterface when the problem
    # carries an empty NamedTuple{(),()} as `p`. `nothing` is SciMLBase's
    # canonical "no parameters" sentinel and avoids the dispatch loop.
    p = isempty(p_syms) ? nothing :
        NamedTuple{Tuple(p_syms)}(Tuple(p_vals))

    # ---- Observed substitution ----
    observed_exprs = Dict{String,Expr}()
    derivative_eqs = Equation[]
    for eq in equations
        if eq.lhs isa VarExpr && ((eq.lhs::VarExpr).name in _geom_ring_vars ||
                                  (eq.lhs::VarExpr).name in _geom_setup_vars)
            # intersect_polygon clip ring / ranged-clip / per-pair area / A_ij —
            # materialized into a const_array at setup (RFC §8.1, §6.1); not a
            # scalar observed and produces no ODE.
            continue
        elseif _is_scalar_D_lhs(eq.lhs)
            push!(derivative_eqs, eq)
        elseif _is_indexed_D_lhs(eq.lhs) || _is_arrayop_D_lhs(eq.lhs)
            push!(derivative_eqs, eq)
        elseif isa(eq.lhs, VarExpr) && (eq.lhs.name in observed_names ||
                                        eq.lhs.name in _geom_inline_vars ||
                                        eq.lhs.name in _array_inline_vars)
            # A live-field geometry observed (F_tgt …) or a promoted array observed
            # enters the substitution map as an arrayop value; `index(obs, j)` in a
            # reader beta-reduces to its body via `_resolve_indices` (ess-14f.4 /
            # shape-promotion).
            observed_exprs[eq.lhs.name] = eq.rhs
        else
            # Algebraic constraint / unsupported equation form.
            # The tree-walk path is ODE-only; see bead's "Not in scope".
            throw(TreeWalkError("E_TREEWALK_UNSUPPORTED_EQUATION",
                                _equation_tag(eq)))
        end
    end
    resolved_obs = _resolve_observed(observed_exprs)

    # ---- Registered-function handlers ----
    reg_funcs = Dict{String,Any}(String(k) => v
                                 for (k, v) in registered_functions)

    # ---- Pre-computed constant arrays (Fornberg weights, mesh connectivity, etc.) ----
    # Supports both 1D (Fornberg weights) and ND (connectivity matrices for
    # mesh reductions).  1D entries are stored as Vector{Float64}; higher-rank
    # entries as plain Array{Float64,N}. An array named in `const_array_boundaries`
    # is wrapped in a BoundedConstArray so OOB stencil gathers resolve per its
    # declared per-dimension policy (ess-gj4).
    _const_boundaries = Dict{String,Any}(String(k) => v for (k, v) in const_array_boundaries)
    _const_arrays = Dict{String,AbstractArray{Float64}}()
    for (k, v) in const_arrays
        k_str = String(k)
        arr = ndims(v) == 1 ? Vector{Float64}(v) : Array{Float64}(v)
        bnd = get(_const_boundaries, k_str, nothing)
        _const_arrays[k_str] = bnd === nothing ? arr : _wrap_bounded_const(arr, bnd, k_str)
    end
    # M4 (RFC §8.1): register each materialized intersect_polygon clip ring as a
    # 2D const_array under its observed-variable name, so the polygon_area FAQ body
    # reads its vertices via `index(clip, v, c)` through the existing const-array
    # path. The CLOSED ring (n+1 rows) makes the wrap edge an ordinary `v+1` lookup.
    for (k, ring) in _geom_rings
        _const_arrays[k] = ring
    end
    # M4+: register each setup-materialized geometry array (per-pair area, A_ij, …)
    # so the ODE body reads it via `index(area, p)` / `index(A_ij, i, j)`.
    for (k, arr) in _geom_setup_arrays
        _const_arrays[k] = arr
    end
    # polygon_intersection_area operands: the const polygon vertex rings the fused
    # leaf clips + areas. Registered as 2D const_arrays so `_resolve_indices` folds
    # `polygon_intersection_area(src, tgt)` to its scalar overlap area (§8.6.1).
    for (k, ring) in _pia_operand_arrays
        _const_arrays[k] = ring
    end
    # const-op array observeds (in-file ring stacks / source fields): registered so
    # an ODE reads `index(F_src, i)` and a setup aggregate gathers `index(src_poly, i)`.
    for (k, arr) in _const_obs_arrays
        haskey(_const_arrays, k) || (_const_arrays[k] = arr)
    end

    # ---- Live forcing buffers (ess-14f.3, JL-J0 — the one engine touch) ----
    #
    # FEASIBILITY GATE (declarative-or-fail). A refreshable forcing read CANNOT be
    # expressed over the existing runtime vocabulary the closure `f!(du,u,p,t)`
    # already reads, as each candidate was checked and rejected:
    #   • const_arrays   — `index(arr,…)` const-folds to a `NumExpr` literal at
    #     build time (the const-array branch of `_resolve_indices`); post-build
    #     mutation has zero effect. A refreshable buffer cannot ride it.
    #   • scalar `p` cells (one named Float64 per cell) — keeps `p` homogeneous but
    #     a NamedTuple of thousands of fields compiles pathologically AND scattered
    #     named scalars cannot gather as a contiguous slice, breaking the
    #     N-independent vectorized kernel. Refresh needs an `integrator.p` rebind.
    #   • state `u` — live + callback-mutable, but the integrator INTEGRATES it
    #     (pollutes the user's `u0`/solution + the adaptive error norm) and a
    #     callback write needs `u_modified!(true)` ⇒ trajectory re-init each
    #     boundary. Forcing is exogenous, not a state.
    #   • an array field in the SAME `p`, read via `getfield(p, n.sym)` (the plan's
    #     literal mechanism) — MEASURED to allocate: a runtime-symbol `getfield` on
    #     a heterogeneous NamedTuple boxes the union (~48 B/call) and regresses the
    #     EXISTING scalar `_NK_PARAM` path too. "Monomorphic getfield" holds only
    #     for a compile-time-literal symbol, never the tree-walk's runtime `n.sym`.
    # CONCLUSION: node JUSTIFIED. Realize the read as a build-time-CAPTURED,
    # by-reference flat `Vector{Float64}` aliasing the caller's dense buffer
    # (`vec` shares storage; the J1 refresh callback's in-place `.=` shows
    # through). `_NK_PARAM_GATHER` (+ vectorized `_VK_PGATHER`) is the zero-alloc
    # dual of the const-fold: the SAME `index` IR, rerouted by binding-time cadence
    # class. No new IR op / schema field / declarative vocabulary; disjoint from
    # the scalar `p`, so existing scalar reads stay byte-identical.
    _pgather = Dict{String,_PGatherArray}()
    for (k, v) in param_arrays
        k_str = String(k)
        v isa Array{Float64} ||
            throw(TreeWalkError("E_TREEWALK_PARAM_ARRAY_TYPE",
                  "param_arrays['$(k_str)'] must be a dense Array{Float64} " *
                  "(captured by reference for live refresh), got $(typeof(v))"))
        # `vec` of a dense Array{Float64} ALIASES its buffer — captured by
        # reference, NOT copied (unlike const_arrays), so the caller's / J1
        # callback's in-place `v .= …` refreshes what the RHS reads.
        _pgather[k_str] = _PGatherArray(vec(v), collect(size(v)))
    end

    # ---- Evaluate arrayop-valued initialization_equations into u0 ----
    # When discretize() materializes an IC equation as an arrayop (coord-subst
    # x→index(coord_x,i)), we evaluate it per-cell here using the same
    # index-substitution + _resolve_indices + _compile pattern used by the ODE
    # arrayop path. The coord_<dim> const_array must be provided by the caller.
    # Explicit initial_conditions values take precedence (already in u0 above).
    param_sym_set = Set(p_syms)
    for eq in init_equations
        eq.lhs isa VarExpr || continue
        eq.rhs isa OpExpr && _is_aggregate_op((eq.rhs::OpExpr).op) || continue
        var_name = (eq.lhs::VarExpr).name
        rhs_op   = eq.rhs::OpExpr
        idx_names_raw = rhs_op.output_idx === nothing ? Any[] : rhs_op.output_idx
        idx_names = String[String(s) for s in idx_names_raw
                           if s isa AbstractString || s isa String]
        ranges_dict = rhs_op.ranges === nothing ? Dict{String,Any}() : rhs_op.ranges
        body = rhs_op.expr_body
        body === nothing && continue
        range_iters = [collect(_expand_int_range(ranges_dict[n])) for n in idx_names]
        for idx_tuple in Iterators.product(range_iters...)
            idx_exprs = Dict{String,Expr}(idx_names[d] => IntExpr(Int64(idx_tuple[d]))
                                          for d in 1:length(idx_names))
            cname = _cell_key(var_name, [idx_tuple[d] for d in 1:length(idx_names)])
            slot = get(var_map, cname, 0)
            slot == 0 && continue
            haskey(initial_conditions, cname) && continue   # explicit override wins
            sub_body = _sub_preserving(body, idx_exprs)
            body_r   = _resolve_indices(sub_body, array_var_info, var_map, _const_arrays, _pgather)
            node     = _compile(body_r, var_map, param_sym_set, reg_funcs)
            u0[slot] = _eval_node(node, u0, isnothing(p) ? NamedTuple() : p, 0.0)
        end
    end

    # ---- Build per-derivative compiled-IR list ----
    # Each entry is (state_index, resolved-RHS-expr). The RHS is inlined with
    # observed variables and index ops are resolved to flat-slot references here;
    # compilation to the compact `_Node` form is deferred to a single batched
    # `_cse_compile_scalar` pass after the loop, so common subexpressions are
    # eliminated across equations as well as within one RHS (ess-r7h).
    scalar_entries = Tuple{Int,Expr}[]
    # Array (`arrayop`) derivative equations compile to whole-array kernels
    # (ess-dhq) instead of N per-cell scalar nodes — see section 4b.
    vec_kernels = _VecKernel[]
    covered = falses(length(all_state_names))

    for eq in derivative_eqs
        if _is_scalar_D_lhs(eq.lhs)
            # D(scalar_var) = expr
            state_name = (eq.lhs::OpExpr).args[1]::VarExpr
            idx = get(var_map, state_name.name, 0)
            idx == 0 && throw(TreeWalkError("E_TREEWALK_UNKNOWN_STATE", state_name.name))
            covered[idx] &&
                throw(TreeWalkError("E_TREEWALK_DUPLICATE_DERIVATIVE", state_name.name))
            covered[idx] = true
            rhs = isempty(resolved_obs) ? eq.rhs :
                  _sub_preserving(eq.rhs, resolved_obs)
            rhs_r = _resolve_indices(rhs, array_var_info, var_map, _const_arrays, _pgather)
            push!(scalar_entries, (idx, rhs_r))

        elseif _is_indexed_D_lhs(eq.lhs)
            # D(index(var, k...)) = expr  — indexed scalar derivative
            lhs_op = eq.lhs::OpExpr
            inner  = lhs_op.args[1]::OpExpr   # the index node
            var_expr = inner.args[1]
            var_expr isa VarExpr ||
                throw(TreeWalkError("E_TREEWALK_UNSUPPORTED_LHS",
                                    "index first arg must be a variable name"))
            concrete_idxs = [_eval_const_int(a, Dict{String,Int}())
                             for a in inner.args[2:end]]
            cname = _cell_key(var_expr.name, concrete_idxs)
            idx = get(var_map, cname, 0)
            idx == 0 && throw(TreeWalkError("E_TREEWALK_UNKNOWN_STATE", cname))
            covered[idx] &&
                throw(TreeWalkError("E_TREEWALK_DUPLICATE_DERIVATIVE", cname))
            covered[idx] = true
            rhs = isempty(resolved_obs) ? eq.rhs :
                  _sub_preserving(eq.rhs, resolved_obs)
            rhs_r = _resolve_indices(rhs, array_var_info, var_map, _const_arrays, _pgather)
            push!(scalar_entries, (idx, rhs_r))

        elseif _is_arrayop_D_lhs(eq.lhs)
            # arrayop(expr=D(index(var, ...)), output_idx=[...], ranges={...}) = rhs_arrayop(...)
            # Expand by iterating the Cartesian product of output_ranges.
            # Per-cell compiled nodes are collected here and then merged into
            # whole-array kernels (ess-dhq) rather than pushed individually into
            # `rhs_list`; the per-cell build logic (ghost cells, const-array
            # inlining, joins/filters, variable-valence bounds) is unchanged.
            cell_entries = Tuple{Int,_Node}[]
            lhs_op = eq.lhs::OpExpr
            idx_names = String[]
            for sym in (lhs_op.output_idx === nothing ? Any[] : lhs_op.output_idx)
                (sym isa String || sym isa AbstractString) &&
                    push!(idx_names, String(sym))
            end
            ranges_dict = lhs_op.ranges === nothing ?
                          Dict{String,Any}() : lhs_op.ranges
            lhs_body = lhs_op.expr_body::OpExpr  # D(index(var, ...))
            rhs_body = _extract_arrayop_body(eq.rhs)

            # Generalized einsum: detect contracted (reduction) indices in the RHS.
            # Contracted indices are keys in rhs.ranges that are NOT in output_idx.
            # Default reduce operator is "+" per ESM spec.
            #
            # A contracted range's bounds may be CONSTANT (structured grids /
            # Route-B padded unstructured form — expand once, globally) or
            # *expression-valued* per output cell (variable-valence unstructured
            # reduction, e.g. bound `index(n_edges_on_cell, i) - 1`).  We collect
            # the raw range spec for each contracted index and, for the constant
            # ones, precompute the global iterator; expression-valued ones
            # (`contract_const[d] === nothing`) are expanded per output cell
            # inside the loop below via `_expand_int_range_dyn`.
            contract_names = String[]
            contract_ranges = Vector{Any}[]            # raw [lo,hi]/[lo,step,hi]
            contract_const  = Union{Vector{Int},Nothing}[]  # nothing ⇒ per-cell
            # Semiring ⊕ and its 0̄ identity (§5.1). Default sum_product (+, 0̄=0).
            rhs_oplus = "+"
            rhs_zerobar = 0.0
            if eq.rhs isa OpExpr && _is_aggregate_op((eq.rhs::OpExpr).op)
                rhs_op = eq.rhs::OpExpr
                rhs_oplus, rhs_zerobar =
                    _aggregate_oplus_identity(rhs_op.semiring, rhs_op.reduce)
                rhs_ranges = rhs_op.ranges === nothing ?
                             Dict{String,Any}() : rhs_op.ranges
                for n in sort!(collect(keys(rhs_ranges)))
                    if !(n in idx_names)
                        rspec = collect(rhs_ranges[n])
                        push!(contract_names, n)
                        push!(contract_ranges, rspec)
                        push!(contract_const,
                              _is_const_int_range(rspec) ?
                                  collect(_expand_int_range(rspec)) : nothing)
                    end
                end
            end

            range_iters = [collect(_expand_int_range(ranges_dict[n])) for n in idx_names]
            for idx_tuple in Iterators.product(range_iters...)
                idx_env  = Dict{String,Int}(idx_names[d] => idx_tuple[d]
                                            for d in 1:length(idx_names))
                idx_exprs = Dict{String,Expr}(k => IntExpr(Int64(v))
                                              for (k, v) in idx_env)
                # Determine which cell the LHS writes to.
                sub_lhs = _sub_preserving(lhs_body, idx_exprs)
                sub_lhs isa OpExpr && sub_lhs.op == "D" ||
                    throw(TreeWalkError("E_TREEWALK_ARRAYOP_MALFORMED_LHS",
                                        "expected D(index(...)) in arrayop body"))
                inner = sub_lhs.args[1]
                inner isa OpExpr && inner.op == "index" ||
                    throw(TreeWalkError("E_TREEWALK_ARRAYOP_MALFORMED_LHS",
                                        "expected index(var,...) inside D"))
                ve = inner.args[1]
                ve isa VarExpr ||
                    throw(TreeWalkError("E_TREEWALK_ARRAYOP_MALFORMED_LHS",
                                        "index first arg must be a variable name"))
                concrete_idxs = [_eval_const_int(a, Dict{String,Int}())
                                 for a in inner.args[2:end]]
                cname = _cell_key(ve.name, concrete_idxs)
                idx = get(var_map, cname, 0)
                idx == 0 && throw(TreeWalkError("E_TREEWALK_UNKNOWN_STATE", cname))
                covered[idx] &&
                    throw(TreeWalkError("E_TREEWALK_DUPLICATE_DERIVATIVE", cname))
                covered[idx] = true

                # Substitute output loop vars into the RHS body.
                sub_rhs_outer = _sub_preserving(rhs_body, idx_exprs)

                if isempty(contract_names)
                    # No contracted indices — standard unrolled-body path.
                    sub_rhs = isempty(resolved_obs) ? sub_rhs_outer :
                              _sub_preserving(sub_rhs_outer, resolved_obs)
                    rhs_r = _resolve_indices(sub_rhs, array_var_info, var_map, _const_arrays, _pgather)
                    push!(cell_entries, (idx, _compile(rhs_r, var_map, param_sym_set, reg_funcs)))
                else
                    # Generalized einsum: compile each contracted-index term
                    # separately, then accumulate at runtime using _NK_CONTRACTION
                    # (an allocation-free sequential ⊕-fold for every semiring —
                    # `_eval_contraction` scalar, or `_VK_REDUCE` once vectorized).
                    # Constant-bound contracted ranges reuse the global iterator;
                    # expression-valued ones are expanded for THIS output cell from
                    # the current `idx_env` (variable-valence segment reduction —
                    # the per-cell bound is the cell's true valence, so absent
                    # neighbour slots are never iterated; no host-side padding).
                    cell_contract_iters = Vector{Vector{Int}}(undef, length(contract_names))
                    for d in 1:length(contract_names)
                        cc = contract_const[d]
                        cell_contract_iters[d] = cc === nothing ?
                            collect(_expand_int_range_dyn(contract_ranges[d],
                                                          idx_env, _const_arrays)) :
                            cc
                    end
                    # M2 (§5.3 / §7.2): the value-equality join gates (resolved at
                    # build time) and the boolean filter predicate restrict which
                    # contracted combinations contribute a ⊗-term. A join-rejected
                    # combination is dropped (so a degenerate join keeps every term
                    # and is byte-identical); a filter-rejected one contributes 0̄
                    # at runtime via an `ifelse` guard.
                    agg_gates  = eq.rhs isa OpExpr ? (eq.rhs::OpExpr).join_gates : nothing
                    agg_filter = eq.rhs isa OpExpr ? (eq.rhs::OpExpr).filter : nothing
                    k_nodes = _Node[]
                    for k_tuple in Iterators.product(cell_contract_iters...)
                        if agg_gates !== nothing
                            binding = Dict{String,Int}(idx_env)
                            for d in 1:length(contract_names)
                                binding[contract_names[d]] = k_tuple[d]
                            end
                            _join_admits(agg_gates, binding) || continue
                        end
                        k_exprs = Dict{String,Expr}(
                            contract_names[d] => IntExpr(Int64(k_tuple[d]))
                            for d in 1:length(contract_names))
                        term = _sub_preserving(sub_rhs_outer, k_exprs)
                        if agg_filter !== nothing
                            filt = _sub_preserving(_sub_preserving(agg_filter, idx_exprs), k_exprs)
                            term = OpExpr("ifelse", Expr[filt, term, NumExpr(rhs_zerobar)])
                        end
                        term = isempty(resolved_obs) ? term :
                               _sub_preserving(term, resolved_obs)
                        rhs_r = _resolve_indices(term, array_var_info, var_map, _const_arrays, _pgather)
                        push!(k_nodes, _compile(rhs_r, var_map, param_sym_set, reg_funcs))
                    end
                    if isempty(k_nodes)
                        # A per-cell dynamic bound can be empty (e.g. an isolated
                        # cell with zero neighbours). Emit the semiring's 0̄
                        # empty-⊕-reduction identity (§5.1): 0 for sum_product,
                        # +∞ for min_sum, -∞ for max_*, 1 for the legacy ×-reduce.
                        push!(cell_entries, (idx, _mknode(kind=_NK_LITERAL, literal=rhs_zerobar)))
                    else
                        # Carry 0̄ on the contraction node so the runtime fold is
                        # seeded from the registry table, never a hardcoded value.
                        push!(cell_entries, (idx, _mknode(kind=_NK_CONTRACTION,
                                                      op=Symbol(rhs_oplus),
                                                      literal=rhs_zerobar,
                                                      children=k_nodes)))
                    end
                end
            end
            # Merge this equation's per-cell nodes into whole-array kernels
            # (ess-dhq). Structurally-identical cells collapse to one template;
            # ghost boundaries / makearray regions / distinct valences form their
            # own (N-independent) groups.
            append!(vec_kernels, _vectorize_cell_entries(cell_entries))
        end
    end
    # States without a D(...) equation get du=0 (integrator leaves them
    # at their initial value — a common pattern for reified constants).

    # ---- Common-subexpression elimination on the scalar/indexed-D RHS (ess-r7h) ----
    # Batched compile of every scalar resolved-RHS expr: subexpressions sharing a
    # canonical_json key (within one RHS or across equations) are compiled once
    # into a prelude that fills a per-call scratch cache, and each occurrence is a
    # `_NK_CACHED` ref. Numerically identical to per-equation `_compile`; with no
    # shared subexpressions the prelude is empty and the rhs nodes are byte-identical.
    rhs_list, scalar_prelude, scalar_cache, cse_diag =
        _cse_compile_scalar(scalar_entries, var_map, param_sym_set, reg_funcs)

    # ---- Default tspan ----
    tspan_default = _pick_tspan(tspan, model)

    # ---- Closure ----
    f! = _make_rhs(rhs_list, scalar_prelude, scalar_cache, vec_kernels)

    # Diagnostics for the N-independence property (ess-dhq acceptance #3): the
    # number of array kernels and total compiled `_VecNode`s must be invariant
    # across grid sizes; only the embedded slot/value vectors grow with N.
    # `n_cse_slots` / `n_cse_occurrences` witness the CSE evaluate-once property
    # (ess-r7h #2): distinct cached subexpressions vs total replaced occurrences.
    diag = (; n_vec_kernels = length(vec_kernels),
              n_scalar_entries = length(rhs_list),
              template_node_count =
                  sum(_count_vecnodes(vk.template) for vk in vec_kernels; init=0),
              n_cse_slots = cse_diag.n_slots,
              n_cse_occurrences = cse_diag.n_occurrences)

    return f!, u0, p, tspan_default, var_map, diag
end

"""
    build_evaluator(model::Model; kwargs...)

Public entry point — returns `(f!, u0, p, tspan, var_map)`. Thin wrapper over
`_build_evaluator_impl`, which additionally returns build diagnostics consumed
by the ess-dhq N-independence property test.
"""
function build_evaluator(model::Model; kwargs...)
    f!, u0, p, tspan_default, var_map, _diag = _build_evaluator_impl(model; kwargs...)
    return f!, u0, p, tspan_default, var_map
end

# (scalar_state_names is populated after array detection — see build_evaluator body)
# The helper is defined here since it must precede its call site.

"""
    build_evaluator(file::EsmFile; model_name=nothing, kwargs...)

Delegate to the typed entry point after selecting the model.
"""
function build_evaluator(file::EsmFile;
                         model_name::Union{Nothing,AbstractString}=nothing,
                         kwargs...)
    model = _select_model(file, model_name)
    # Thread the document-scoped index-set registry (esm-spec v0.8.0) into the
    # typed evaluator, which no longer reads it off the `Model`.
    return build_evaluator(model; index_sets=file.index_sets, kwargs...)
end

# Direct EsmFile/Model entry points carry no raw JSON, so value-invention
# materialisation can only run through the AbstractDict front-door; default the
# internal extents/vars to empty here so a direct typed call is unchanged.

"""
    build_evaluator(esm::AbstractDict; model_name=nothing, kwargs...)

Parse a raw ESM dict, then delegate. This is the signature from the
bead description; the typed entry point is faster for callers that
already have a parsed `Model`.

`const_arrays` (forwarded via kwargs) accepts pre-computed 1D float arrays
keyed by name. `index(name, i)` references in the equations are inlined as
literal values. Used to inject `__stgfw_` Fornberg weight arrays for
`stencil_gen` models with `spacing="from_grid"`.
"""
function build_evaluator(esm::AbstractDict;
                         model_name::Union{Nothing,AbstractString}=nothing,
                         kwargs...)
    # `coerce_esm_file` expects a JSON3-style object (property-access
    # getters). Round-trip through JSON3 so raw Julia Dict inputs — the
    # signature from the bead description — work.
    file = coerce_esm_file(JSON3.read(JSON3.write(esm)))

    # ---- Value-invention front-door (RFC §6.1) ----
    # The raw JSON (NOT the typed IR, which drops the aggregate `key`/`distinct`)
    # is the only place the value-invention vocabulary survives, so materialise
    # any derived index set here and thread the extents into the typed path. A
    # no-op (and byte-identical) for models without a skolem/distinct/rank node.
    kwd = Dict{Symbol,Any}(kwargs)
    model_json = _select_model_json(esm, model_name)

    # ---- Build-time binning-coordinate derivation (RFC §8.6.1 purity) ----
    # A broad-phase binning coordinate declared INLINE as a reduce aggregate over the
    # in-file `const` geometry (e.g. `src_lon[i] = min_v src_poly[i,v,1]`) is a
    # build-time constant. Evaluate it once from the const-op arrays and thread it
    # into `const_arrays`, so `floor(index(src_lon,i)/dx)→skolem` resolves at setup
    # without the host supplying the coordinate. No-op (byte-identical) when no such
    # observed exists.
    _params = get(kwd, :parameter_overrides, Dict{String,Float64}())
    _ca = Dict{String,Any}(String(k) => v for (k, v) in get(kwd, :const_arrays, Dict{String,Any}()))
    if model_json !== nothing
        _derived = _derive_binning_coords(_select_model(file, model_name),
                                          file.index_sets, _ca, _params)
        if !isempty(_derived)
            merge!(_ca, _derived)
            kwd[:const_arrays] = _ca
        end
    end

    _vi = model_json === nothing ? nothing :
          materialize_value_invention(model_json, _ca, _params)

    return build_evaluator(file; model_name=model_name,
                           _vi_extents=(_vi === nothing ? Dict{String,Int}() : _vi.extents),
                           _vi_vars=(_vi === nothing ? Set{String}() : _vi.vi_var_names),
                           _vi_maps=(_vi === nothing ? _EMPTY_VI_MAPS :
                                     (maps=_vi.maps, map_sets=_vi.map_sets)),
                           kwd...)
end

"""
    build_evaluator(flat::FlattenedSystem; kwargs...)

Build an evaluator directly from a `FlattenedSystem` by reconstituting it into a
single-model native ESM document (`flattened_to_esm`) and running the
`AbstractDict` front-door — so the regridders' value-invention geometry is
materialized. Use this for a 0-D / array flattened system; for one carrying a
spatial PDE, `discretize(flat; …)` first.
"""
function build_evaluator(flat::FlattenedSystem; kwargs...)
    return build_evaluator(flattened_to_esm(flat); kwargs...)
end

# Select one raw model document (native dict) from a raw ESM dict, mirroring
# `_select_model` for the typed path. Returns `nothing` when no model matches.
function _select_model_json(esm::AbstractDict, model_name)
    doc = Cadence.to_native(esm)
    models = get(doc, "models", nothing)
    isa(models, AbstractDict) && !isempty(models) || return nothing
    model = if model_name !== nothing
        get(models, String(model_name), nothing)
    elseif length(models) == 1
        first(values(models))
    else
        nothing
    end
    (model === nothing || !isa(model, AbstractDict)) && return model
    # esm-spec v0.8.0: the index-set registry is a single document-scoped object,
    # but the value-invention / relational front-door reads it off the model dict.
    # Inject the document registry here so a `{from}` / `from_faq` reference still
    # resolves. A no-op when the document declares none, or when the model already
    # carries its own registry (legacy internal reconstitution).
    doc_is = get(doc, "index_sets", nothing)
    if doc_is !== nothing && !haskey(model, "index_sets")
        model = Dict{String,Any}(model)
        model["index_sets"] = doc_is
    end
    return model
end

"""
    evaluate_expr(expr::Expr, bindings::AbstractDict;
                  registered_functions::AbstractDict=Dict{String,Function}())::Float64

Evaluate a single AST expression at the supplied numeric `bindings` by
running it through the same compile + walker pipeline as
[`build_evaluator`](@ref). All keys of `bindings` are exposed as readable
state variables; the special name `"t"` (if present) is bound to the
walker's time argument as well. Adding an op to the tree-walk evaluator
transparently extends this entry point — there is no separate dispatch
table.

Throws `UnboundVariableError` when `expr` references a name that is not
in `bindings` and is not the time variable; other failures surface as
[`TreeWalkError`](@ref).
"""
function evaluate_expr(expr::Expr, bindings::AbstractDict;
                       registered_functions::AbstractDict=Dict{String,Function}())::Float64
    var_map = Dict{String,Int}()
    u = Vector{Float64}(undef, length(bindings))
    i = 0
    for (name, _) in bindings
        i += 1
        sname = String(name)
        var_map[sname] = i
        u[i] = Float64(bindings[name])
    end
    reg_funcs = Dict{String,Any}(String(k) => v for (k, v) in registered_functions)
    node = try
        _compile(expr, var_map, Set{Symbol}(), reg_funcs)
    catch e
        if e isa TreeWalkError && e.code == "E_TREEWALK_UNBOUND_VARIABLE"
            throw(UnboundVariableError(e.detail,
                  "Variable '$(e.detail)' not found in bindings"))
        end
        rethrow(e)
    end
    t = haskey(bindings, "t") ? Float64(bindings["t"]) : 0.0
    return _eval_node(node, u, NamedTuple(), t)
end

# ============================================================
# 3. Compiled-IR — one-shot compilation to a compact, type-stable tree
# ============================================================
#
# `_eval` below walks the raw `OpExpr` tree. That's correct but every
# op dispatch is an O(N) chain of String comparisons, and every
# VarExpr lookup does a Dict probe. For 4096-equation models the
# overhead dominates. `_compile` walks the expression once at build
# time and produces `_Node` trees where:
#
#   * op is a `Symbol` (pointer compare, not byte compare)
#   * state refs have their u-index baked in
#   * parameter refs have their `Val{sym}` type param baked in for
#     `getfield(p, Val)` — monomorphic NamedTuple access
#   * literals are pre-promoted to Float64
#   * registered-function handlers are looked up and captured once
#
# The compiled tree keeps semantics identical to walking `OpExpr`
# directly; `_eval` stays available for the unit-test helper which
# exercises the fallback path.

# _NKind encodes what a node is. Keeping it as a Bare integer (UInt8)
# gives a fast `kind === K_*` dispatch inside `_eval_node`.
const _NK_LITERAL      = UInt8(1)
const _NK_STATE        = UInt8(2)   # read u[idx]
const _NK_PARAM        = UInt8(3)   # read p.<sym>
const _NK_TIME         = UInt8(4)   # return t
const _NK_OP           = UInt8(5)   # apply op to children
const _NK_CONTRACTION  = UInt8(6)   # runtime ⊕-reduction over children (seq. fold)
const _NK_CACHED       = UInt8(7)   # common-subexpression ref: read cache[idx] (ess-r7h)
const _NK_PARAM_GATHER = UInt8(8)   # read a captured live forcing buffer: handler[idx] (ess-14f.3)

struct _Node
    kind::UInt8
    op::Symbol
    literal::Float64
    idx::Int
    sym::Symbol
    handler::Any
    children::Vector{_Node}
end

function _mknode(; kind::UInt8, op::Symbol=Symbol(""),
                 literal::Float64=0.0, idx::Int=0,
                 sym::Symbol=Symbol(""), handler=nothing,
                 children::Vector{_Node}=_Node[])
    return _Node(kind, op, literal, idx, sym, handler, children)
end

# `param_syms` is a `Set{Symbol}` so parameters can be distinguished
# from unbound-variable errors without another pass.
function _compile(expr::NumExpr, var_map, param_syms, reg_funcs)
    return _mknode(kind=_NK_LITERAL, literal=expr.value)
end
function _compile(expr::IntExpr, var_map, param_syms, reg_funcs)
    return _mknode(kind=_NK_LITERAL, literal=Float64(expr.value))
end
function _compile(expr::VarExpr, var_map, param_syms, reg_funcs)
    name = expr.name
    if name == "t"
        return _mknode(kind=_NK_TIME)
    end
    idx = get(var_map, name, 0)
    if idx != 0
        return _mknode(kind=_NK_STATE, idx=idx)
    end
    sym = Symbol(name)
    if sym in param_syms
        return _mknode(kind=_NK_PARAM, sym=sym)
    end
    throw(TreeWalkError("E_TREEWALK_UNBOUND_VARIABLE", name))
end
function _compile(expr::OpExpr, var_map, param_syms, reg_funcs)
    op_sym = Symbol(expr.op)
    handler = nothing
    if op_sym === :fn
        # Closed function registry (esm-spec §9.2 / esm-tzp). The function
        # name is captured in the node's `handler` slot as a tuple of
        # (name::String, const_array_or_nothing). For
        # `interp.searchsorted` the second arg is a const-op array which
        # we pre-extract so the runtime hot path doesn't walk the AST.
        fname = expr.name
        fname === nothing &&
            throw(TreeWalkError("E_TREEWALK_FN_MISSING_NAME", expr.op))
        if !(fname in _CLOSED_FUNCTION_NAMES)
            throw(TreeWalkError("E_TREEWALK_UNKNOWN_CLOSED_FUNCTION", fname))
        end
        if fname == "interp.searchsorted"
            length(expr.args) == 2 ||
                throw(TreeWalkError("E_TREEWALK_FN_ARITY",
                    "interp.searchsorted expects 2 args, got $(length(expr.args))"))
            tab = expr.args[2]
            if !(tab isa OpExpr && tab.op == "const" && tab.value isa AbstractVector)
                throw(TreeWalkError("E_TREEWALK_FN_ARG_NOT_CONST",
                    "interp.searchsorted: 2nd arg must be a `const`-op array"))
            end
            # Compile only the scalar first arg as a child; carry the
            # constant array on the node so the runtime call is one
            # _eval_node + one closed-function dispatch.
            children = _Node[_compile(expr.args[1], var_map, param_syms, reg_funcs)]
            handler = (fname, Any[tab.value])
        elseif fname == "interp.linear"
            # Args = (table, axis, x). Const arrays at positions [1, 2];
            # scalar query at [3]. Pre-extract the const arrays so the
            # runtime hot path skips AST traversal.
            length(expr.args) == 3 ||
                throw(TreeWalkError("E_TREEWALK_FN_ARITY",
                    "interp.linear expects 3 args, got $(length(expr.args))"))
            tbl  = _require_const_array(expr.args[1], "interp.linear", "table")
            axs  = _require_const_array(expr.args[2], "interp.linear", "axis")
            children = _Node[_compile(expr.args[3], var_map, param_syms, reg_funcs)]
            handler = (fname, Any[tbl, axs])
        elseif fname == "interp.bilinear"
            # Args = (table, axis_x, axis_y, x, y). Const arrays at [1, 2, 3];
            # scalar queries at [4, 5].
            length(expr.args) == 5 ||
                throw(TreeWalkError("E_TREEWALK_FN_ARITY",
                    "interp.bilinear expects 5 args, got $(length(expr.args))"))
            tbl  = _require_const_array(expr.args[1], "interp.bilinear", "table")
            axx  = _require_const_array(expr.args[2], "interp.bilinear", "axis_x")
            axy  = _require_const_array(expr.args[3], "interp.bilinear", "axis_y")
            children = _Node[
                _compile(expr.args[4], var_map, param_syms, reg_funcs),
                _compile(expr.args[5], var_map, param_syms, reg_funcs),
            ]
            handler = (fname, Any[tbl, axx, axy])
        else
            children = _Node[_compile(a, var_map, param_syms, reg_funcs)
                             for a in expr.args]
            handler = (fname, nothing)
        end
        return _mknode(kind=_NK_OP, op=op_sym, children=children, handler=handler)
    end

    children = _Node[_compile(a, var_map, param_syms, reg_funcs)
                     for a in expr.args]
    if op_sym === :const
        # Scalar `const` ops fold to a literal at compile time. Non-scalar
        # `const` only ever appears as an argument to ops that consume
        # arrays (handled in their respective compile paths above).
        v = expr.value
        if v isa Real && !(v isa Bool)
            return _mknode(kind=_NK_LITERAL, literal=Float64(v))
        end
        throw(TreeWalkError("E_TREEWALK_UNSUPPORTED_OP",
            "non-scalar `const` op outside an array-consuming position"))
    elseif op_sym === :enum
        throw(TreeWalkError("E_TREEWALK_UNSUPPORTED_OP",
            "`enum` op encountered after lowering — call `lower_enums!` before compile"))
    elseif op_sym === :call
        # Removed in v0.3.0 (esm-spec §9 closure). `parse_expression` already
        # rejects file-loaded `call` ops; reaching this arm means a caller
        # constructed a `call` OpExpr programmatically.
        throw(TreeWalkError("E_TREEWALK_UNSUPPORTED_OP",
            "`call` op was removed in v0.3.0 — migrate to `fn` ops " *
            "or AST equations (esm-spec §9 closure, RFC closed-function-registry)"))
    elseif op_sym === :D
        throw(TreeWalkError("E_TREEWALK_D_IN_RHS",
                            "D(...) only allowed in equation LHS"))
    elseif op_sym === :ic
        # `ic` (esm-spec v0.8.0) is an equation-LHS-only marker, like `D`:
        # `ic(var) = <initial field>` declares an initial condition. It must
        # never appear in an RHS / general expression position.
        throw(TreeWalkError("E_TREEWALK_IC_IN_RHS",
                            "ic(...) only allowed in equation LHS"))
    elseif op_sym === :grad || op_sym === :div || op_sym === :laplacian
        # esm-i7b: spatial differential operators MUST be rewritten by ESD
        # discretization rules into `arrayop` AST before reaching the
        # simulator. Encountering one here means the canonical pipeline
        # broke; surface the violation rather than substituting zero (the
        # historical stub behaviour in other bindings).
        throw(TreeWalkError("E_TREEWALK_UNREACHABLE_SPATIAL_OP",
            "UnreachableSpatialOperatorError: encountered '$(expr.op)' node " *
            "in simulation evaluation. Spatial operators must be rewritten " *
            "by ESD discretization rules before reaching the simulator. " *
            "Pipeline contract violated."))
    elseif op_sym === :arrayop || op_sym === :aggregate
        # If _resolve_indices ran, scalar aggregate (empty output_idx) was
        # already expanded to a plain arithmetic tree and never reaches here.
        # Reaching this branch means an array-producing aggregate (non-empty
        # output_idx) appeared without being wrapped in an index() call.
        throw(TreeWalkError("E_TREEWALK_UNSUPPORTED_OP",
                            "$(expr.op) with non-empty output_idx in expression position " *
                            "requires wrapping in index($(expr.op)(...), k1, k2, ...)"))
    elseif op_sym === :makearray
        # makearray in expression position must be wrapped in index().
        throw(TreeWalkError("E_TREEWALK_UNSUPPORTED_OP",
                            "makearray in expression position requires wrapping " *
                            "in index(makearray(...), k1, k2, ...)"))
    elseif op_sym === :broadcast || op_sym === :reshape ||
           op_sym === :transpose || op_sym === :concat
        throw(TreeWalkError("E_TREEWALK_UNSUPPORTED_OP",
                            "$(expr.op) (not yet supported in tree-walk path)"))
    elseif op_sym === :index
        # A forcing gather over a live `param_arrays` buffer (ess-14f.3): the
        # `index` branch of `_resolve_indices` already bounds-checked and
        # linearized it, stashing `(flat::Vector{Float64}, lin::Int)` in `value`
        # (the `index` op is CSE-opaque, so `value` is never canonicalized). Lower
        # it to a live-read `_NK_PARAM_GATHER` instead of the const-fold a frozen
        # `const_arrays` entry would get. This is the binding-time reroute of an
        # EXISTING gather by its cadence class — no new IR op (the wire op is still
        # `index`); see the JL-J0 feasibility-gate note in `_build_evaluator_impl`.
        if op_sym === :index && expr.value isa Tuple{Vector{Float64},Int}
            flat, lin = expr.value::Tuple{Vector{Float64},Int}
            return _mknode(kind=_NK_PARAM_GATHER, idx=lin, handler=flat)
        end
        # Otherwise: index ops must be resolved to state-slot references by
        # _resolve_indices before reaching _compile; encountering one here
        # means the caller skipped that pass.
        throw(TreeWalkError("E_TREEWALK_UNSUPPORTED_OP",
                            "$(expr.op) reached _compile unresolved — " *
                            "_resolve_indices must run first"))
    end
    return _mknode(kind=_NK_OP, op=op_sym, children=children, handler=handler)
end

# ============================================================
# 3b. Common-subexpression elimination (ess-r7h) — eval-time memo, approach (a)
# ============================================================
#
# APPROACH (a) — eval-time memoization. The serialized IR and the canonical
# goldens are UNCHANGED: CSE only restructures how the *compiled* tree-walk
# evaluator computes a RHS, so results are numerically identical and the
# cross-binding PDE-sim conformance suite (ess-fmw, rhs_rtol=1e-9) is untouched
# by construction. Lives only in this Julia evaluator (the bead's named main
# beneficiary); other bindings need no change because numeric output is the same.
#
# KEY = `canonical_json(expr)` from canonicalize.jl — the existing,
# cross-binding-identical canonical form. Two subexpressions are "common" iff
# their canonical_json bytes are equal; keying on this is conformance-safe by
# construction (the same identity all five bindings already agree on). NO
# parallel canonicalizer is introduced — `canonical_json` IS the key.
#
# SHARING HANDLE = a value-number (Int cache slot) per distinct canonical key.
# This realizes the RFC §6.1 "node id as a DAG vertex" role in compiled space:
# a shared subexpression is named once and referenced from each use site by a
# `_NK_CACHED` leaf carrying that slot.
#
# DAG = the value-numbered data-dependency graph `_compile_cse` walks: children
# are compiled (and hoisted) before their parent, so a cached subexpression's
# slot is always lower than the slots referencing it — the prelude is therefore
# already topologically ordered. (cadence.jl's §5.7 graph is index-set cycle
# detection over raw JSON, not an expression-CSE DAG; the reuse here is of the
# *canonical identity*, not that specific pass.)
#
# EVALUATOR MEMO POINT = a per-`f!`-call scratch `cache::Vector{Float64}`. The
# prelude evaluates each distinct cached subexpression exactly ONCE per RHS call
# into `cache` (slot order); every occurrence then reads `cache[slot]` via
# `_NK_CACHED`. A subexpression occurring K times is thus evaluated once.
#
# BIT-EXACTNESS: a cached subexpression's definition is compiled from its
# original (first-seen) operand order — identical to what `_compile` emits
# inline today — so each occurrence reads back the exact bytes it would have
# computed. With no common subexpressions the prelude is empty and `_compile_cse`
# produces the identical `_Node` tree `_compile` would, so f! is unchanged for
# models with nothing to share.
#
# SCOPE — why CSE lives on the scalar tree-walk path, not the vectorized
# (ess-dhq) arrayop path. After ess-dhq, redundancy is removed at three layers:
#   * cross-grid-cell  — eliminated by whole-array kernels (one broadcast per
#                        structural cell group), so the same stencil is never
#                        re-walked per cell;
#   * intra-expression — eliminated at DISCRETIZE time: `discretize` canonicalizes
#                        each per-cell RHS (discretize.jl), and canonicalization
#                        already merges like additive/multiplicative terms. The
#                        2D-Laplacian interior body, for instance, lands as
#                        `16*(u[i-1,j]+u[i+1,j]+u[i,j-1]+u[i,j+1]+(-4*u[i,j]))`
#                        — every gather appears exactly once, nothing to share;
#   * cross-equation / intra-RHS-across-nonlinear-contexts — SURVIVES canonicalize
#                        (it normalizes one expression at a time, and does not
#                        combine `sin(a+b)` with `cos(a+b)` or a shared reaction
#                        flux `k*A*B` across several species balances). This is
#                        exactly the scalar/indexed-D tree-walk path, and it is
#                        where this CSE pass fires.
# Conformance PDE fixtures are pure single-field arrayops (n_scalar_entries==0)
# whose canonicalized templates carry no duplicate sub-node, so vectorized-path
# CSE would be a no-op on them. Cross-KERNEL sharing for COUPLED multi-field PDEs
# (one array subexpression reused across several arrayop equations) is a genuine
# future case — keyed structurally on the post-merge `_VecNode` rather than on
# `canonical_json`, with a per-call vector cache — and is tracked as a follow-up.

# Ops `_compile` handles specially (closed functions, array/aggregate producers,
# unresolved/illegal-in-RHS markers). CSE never hoists a node rooted at one of
# these and never rewrites their operands — such subtrees delegate to plain
# `_compile`. Everything else is the scalar arithmetic / comparison /
# transcendental family that `_compile` lowers to a plain `_NK_OP`, which is
# exactly what `_compile_cse` reconstructs, so hoisting those is sound.
const _CSE_OPAQUE_OPS = Set{String}([
    "fn", "const", "enum", "call", "D", "ic", "grad", "div", "laplacian",
    "arrayop", "aggregate", "makearray", "broadcast", "reshape",
    "transpose", "concat", "index",
])

# A node is a CSE hoist/recurse candidate iff it is an OpExpr whose op is not
# opaque. Leaves (state/param/literal/time) are never hoisted — caching a leaf
# costs more than the bare read it would replace.
_cse_hoistable(e::OpExpr) = !(e.op in _CSE_OPAQUE_OPS)
_cse_hoistable(::Expr) = false

# Canonical-form key for a subexpression, or `nothing` if it cannot be
# canonicalized (e.g. a non-finite literal). A `nothing` key disables sharing
# for that subtree — CSE is a pure optimization and silently declines anything
# it cannot key safely.
function _cse_key(e::Expr)
    try
        return canonical_json(e)
    catch err
        err isa CanonicalizeError && return nothing
        rethrow()
    end
end

# Count pass: tally canonical_json occurrences of every hoistable subexpression
# across all RHS trees. A key seen >= 2 times is worth hoisting.
function _cse_count!(e::Expr, counts::Dict{String,Int})
    (e isa OpExpr && _cse_hoistable(e)) || return
    k = _cse_key(e)
    k === nothing || (counts[k] = get(counts, k, 0) + 1)
    for a in e.args
        _cse_count!(a, counts)
    end
    return
end

# Mutable CSE compile context: the set of cached keys, the slot assigned to each
# (assigned lazily, in topological order, at first compile), the prelude
# definitions (`defs[s]` computes `cache[s]`), and the shared scratch the
# `_NK_CACHED` nodes read from.
mutable struct _CSEContext
    cached::Set{String}
    slot::Dict{String,Int}
    defs::Vector{_Node}
    cache::Vector{Float64}
end

# Compile `expr` to a `_Node`, hoisting any subexpression whose canonical key is
# in `ctx.cached` into the prelude and replacing it with a `_NK_CACHED` ref.
# Falls back to plain `_compile` for leaves and opaque ops, so the result is
# identical to `_compile` wherever nothing is hoisted.
function _compile_cse(expr::Expr, var_map, param_syms, reg_funcs, ctx::_CSEContext)
    (expr isa OpExpr && _cse_hoistable(expr)) ||
        return _compile(expr, var_map, param_syms, reg_funcs)

    key = _cse_key(expr)
    if key !== nothing && key in ctx.cached
        s = get(ctx.slot, key, 0)
        s != 0 && return _mknode(kind=_NK_CACHED, idx=s, handler=ctx.cache)
        # First occurrence: compile children first (assigning them lower slots,
        # keeping `defs` topologically ordered), reserve this slot, register the
        # def, and return a ref. Every later occurrence hits the `s != 0` path.
        children = _Node[_compile_cse(a, var_map, param_syms, reg_funcs, ctx)
                         for a in expr.args]
        defnode = _mknode(kind=_NK_OP, op=Symbol(expr.op), children=children)
        s = length(ctx.defs) + 1
        ctx.slot[key] = s
        push!(ctx.defs, defnode)
        return _mknode(kind=_NK_CACHED, idx=s, handler=ctx.cache)
    end
    # Not cached: reconstruct the same `_NK_OP` node `_compile` would, but with
    # hoisted children.
    children = _Node[_compile_cse(a, var_map, param_syms, reg_funcs, ctx)
                     for a in expr.args]
    return _mknode(kind=_NK_OP, op=Symbol(expr.op), children=children)
end

# Compile a batch of scalar `(state_index, resolved_rhs_expr)` entries with
# cross-equation + intra-expression CSE. Returns the compiled rhs list, the
# prelude (slot-ordered def nodes), the shared cache vector, and a diagnostic
# `(; n_slots, n_occurrences)` that witnesses the evaluate-once property
# (criterion #2: distinct evaluations == distinct canonical subexpressions).
function _cse_compile_scalar(entries::Vector{Tuple{Int,Expr}},
                             var_map, param_syms, reg_funcs)
    counts = Dict{String,Int}()
    for (_, e) in entries
        _cse_count!(e, counts)
    end
    cached = Set{String}()
    n_occ = 0
    for (k, c) in counts
        if c >= 2
            push!(cached, k)
            n_occ += c
        end
    end
    cache = Float64[]
    ctx = _CSEContext(cached, Dict{String,Int}(), _Node[], cache)
    rhs_list = Tuple{Int,_Node}[]
    for (idx, e) in entries
        push!(rhs_list, (idx, _compile_cse(e, var_map, param_syms, reg_funcs, ctx)))
    end
    # Size the scratch to the number of slots. `cache` is the SAME object the
    # `_NK_CACHED` nodes captured, so this in-place resize is visible to them.
    resize!(cache, length(ctx.defs))
    diag = (; n_slots = length(ctx.defs), n_occurrences = n_occ)
    return rhs_list, ctx.defs, cache, diag
end

# ============================================================
# 4. Compiled walker
# ============================================================

@inline function _eval_node(n::_Node, u, p, t)
    k = n.kind
    if k === _NK_LITERAL
        return n.literal
    elseif k === _NK_STATE
        @inbounds return u[n.idx]
    elseif k === _NK_PARAM
        return getfield(p, n.sym)
    elseif k === _NK_PARAM_GATHER
        # Live read of a captured forcing buffer (ess-14f.3). `handler` is the
        # aliased flat `Vector{Float64}` (a `_PGatherArray.flat`) and `idx` the
        # pre-linearized column-major offset, both fixed at build time; the buffer
        # CONTENTS are refreshed in place by the J1 discrete callback. The concrete
        # `::Vector{Float64}` assert keeps this monomorphic + zero-alloc (no
        # runtime-symbol `getfield`, so the scalar `p` NamedTuple stays homogeneous).
        @inbounds return (n.handler::Vector{Float64})[n.idx]
    elseif k === _NK_TIME
        return t
    elseif k === _NK_CACHED
        # Common-subexpression reference (ess-r7h). The value was computed once
        # into the per-call scratch cache by the CSE prelude (see `_make_rhs`);
        # every occurrence reads it here instead of re-walking the subtree. The
        # cache vector is captured in `handler` at build time, so this needs no
        # extra eval argument and the recursive `_eval_node` family is unchanged.
        @inbounds return (n.handler::Vector{Float64})[n.idx]
    elseif k === _NK_CONTRACTION
        return _eval_contraction(n, u, p, t)
    else
        return _eval_node_op(n, u, p, t)
    end
end

# Runtime ⊕-reduction over a node's children, parameterized by semiring (§5.1).
# The accumulator is seeded from `n.literal`, the 0̄ identity baked onto the node
# at build time from the registry table — so every arm (incl. empty-or-folded
# max/min/×) returns the normative identity without any hardcoded constant here.
# All four arms share ONE shape: an `@inbounds` sequential fold over the children
# seeded from `n.literal`. The `:+` arm sums from 0.0 (sum_product's 0̄, the only
# ⊕=+ semiring) in child order — allocation-free and bit-identical to the prior
# `@tullio s = …` sum (which `zero`-seeds the same sequential accumulation). The
# Tullio form built per-call codegen machinery (~80 B per reduced cell); keeping
# the four arms structurally identical is what makes the RHS `f!` non-allocating
# (ess-9cc). This node is only built with ≥1 child (the empty case folds to a
# literal upstream).
function _eval_contraction(n::_Node, u, p, t)
    op = n.op
    children = n.children
    if op === :+
        s = n.literal  # 0̄ = 0.0 for sum_product
        @inbounds for k in eachindex(children)
            s += _eval_node(children[k], u, p, t)
        end
        return s
    elseif op === :*
        s = n.literal  # 1̄ for the ×-reduce
        @inbounds for k in eachindex(children)
            s *= _eval_node(children[k], u, p, t)
        end
        return s
    elseif op === :max
        s = n.literal  # -∞
        @inbounds for k in eachindex(children)
            s = max(s, _eval_node(children[k], u, p, t))
        end
        return s
    else  # :min
        s = n.literal  # +∞
        @inbounds for k in eachindex(children)
            s = min(s, _eval_node(children[k], u, p, t))
        end
        return s
    end
end

function _eval_node_op(n::_Node, u, p, t)
    op = n.op
    c = n.children

    # Arithmetic — the hot paths.
    if op === :+
        length(c) == 1 && return _eval_node(c[1], u, p, t)
        acc = _eval_node(c[1], u, p, t)
        @inbounds for i in 2:length(c)
            acc += _eval_node(c[i], u, p, t)
        end
        return acc
    elseif op === :*
        length(c) == 1 && return _eval_node(c[1], u, p, t)
        acc = _eval_node(c[1], u, p, t)
        @inbounds for i in 2:length(c)
            acc *= _eval_node(c[i], u, p, t)
        end
        return acc
    elseif op === :-
        if length(c) == 1
            return -_eval_node(c[1], u, p, t)
        elseif length(c) == 2
            return _eval_node(c[1], u, p, t) - _eval_node(c[2], u, p, t)
        end
        throw(TreeWalkError("E_TREEWALK_ARITY", "- expects 1 or 2 args"))
    elseif op === :neg
        # Canonical-form unary negation. `canonicalize` rewrites unary
        # `-x` to `neg(x)`, so any AST that has been through `discretize`
        # may carry `neg` ops where the source had `-x`.
        _expect_arity_n(op, c, 1)
        return -_eval_node(c[1], u, p, t)
    elseif op === :/
        _expect_arity_n(op, c, 2)
        return _eval_node(c[1], u, p, t) / _eval_node(c[2], u, p, t)
    elseif op === :^ || op === :pow
        _expect_arity_n(op, c, 2)
        return _eval_node(c[1], u, p, t) ^ _eval_node(c[2], u, p, t)

    # Comparisons → 1.0/0.0 (match `evaluate` semantics)
    elseif op === :<
        _expect_arity_n(op, c, 2)
        return _eval_node(c[1], u, p, t) <  _eval_node(c[2], u, p, t) ? 1.0 : 0.0
    elseif op === Symbol("<=")
        _expect_arity_n(op, c, 2)
        return _eval_node(c[1], u, p, t) <= _eval_node(c[2], u, p, t) ? 1.0 : 0.0
    elseif op === :>
        _expect_arity_n(op, c, 2)
        return _eval_node(c[1], u, p, t) >  _eval_node(c[2], u, p, t) ? 1.0 : 0.0
    elseif op === Symbol(">=")
        _expect_arity_n(op, c, 2)
        return _eval_node(c[1], u, p, t) >= _eval_node(c[2], u, p, t) ? 1.0 : 0.0
    elseif op === Symbol("==")
        _expect_arity_n(op, c, 2)
        return _eval_node(c[1], u, p, t) == _eval_node(c[2], u, p, t) ? 1.0 : 0.0
    elseif op === Symbol("!=")
        _expect_arity_n(op, c, 2)
        return _eval_node(c[1], u, p, t) != _eval_node(c[2], u, p, t) ? 1.0 : 0.0

    # Logical
    elseif op === :and
        for child in c
            _eval_node(child, u, p, t) == 0 && return 0.0
        end
        return 1.0
    elseif op === :or
        for child in c
            _eval_node(child, u, p, t) != 0 && return 1.0
        end
        return 0.0
    elseif op === :not
        _expect_arity_n(op, c, 1)
        return _eval_node(c[1], u, p, t) == 0 ? 1.0 : 0.0

    elseif op === :ifelse
        _expect_arity_n(op, c, 3)
        return _eval_node(c[1], u, p, t) != 0 ?
               _eval_node(c[2], u, p, t) :
               _eval_node(c[3], u, p, t)

    # Elementary functions
    elseif op === :sin;   _expect_arity_n(op, c, 1); return sin(_eval_node(c[1], u, p, t))
    elseif op === :cos;   _expect_arity_n(op, c, 1); return cos(_eval_node(c[1], u, p, t))
    elseif op === :tan;   _expect_arity_n(op, c, 1); return tan(_eval_node(c[1], u, p, t))
    elseif op === :asin;  _expect_arity_n(op, c, 1); return asin(_eval_node(c[1], u, p, t))
    elseif op === :acos;  _expect_arity_n(op, c, 1); return acos(_eval_node(c[1], u, p, t))
    elseif op === :atan
        if length(c) == 1
            return atan(_eval_node(c[1], u, p, t))
        elseif length(c) == 2
            return atan(_eval_node(c[1], u, p, t), _eval_node(c[2], u, p, t))
        end
        throw(TreeWalkError("E_TREEWALK_ARITY", "atan expects 1 or 2 args"))
    elseif op === :atan2
        _expect_arity_n(op, c, 2)
        return atan(_eval_node(c[1], u, p, t), _eval_node(c[2], u, p, t))
    elseif op === :sinh;  _expect_arity_n(op, c, 1); return sinh(_eval_node(c[1], u, p, t))
    elseif op === :cosh;  _expect_arity_n(op, c, 1); return cosh(_eval_node(c[1], u, p, t))
    elseif op === :tanh;  _expect_arity_n(op, c, 1); return tanh(_eval_node(c[1], u, p, t))
    elseif op === :asinh; _expect_arity_n(op, c, 1); return asinh(_eval_node(c[1], u, p, t))
    elseif op === :acosh; _expect_arity_n(op, c, 1); return acosh(_eval_node(c[1], u, p, t))
    elseif op === :atanh; _expect_arity_n(op, c, 1); return atanh(_eval_node(c[1], u, p, t))
    elseif op === :exp;   _expect_arity_n(op, c, 1); return exp(_eval_node(c[1], u, p, t))
    elseif op === :log;   _expect_arity_n(op, c, 1); return log(_eval_node(c[1], u, p, t))
    elseif op === :log10; _expect_arity_n(op, c, 1); return log10(_eval_node(c[1], u, p, t))
    elseif op === :sqrt;  _expect_arity_n(op, c, 1); return sqrt(_eval_node(c[1], u, p, t))
    elseif op === :abs;   _expect_arity_n(op, c, 1); return abs(_eval_node(c[1], u, p, t))
    elseif op === :sign;  _expect_arity_n(op, c, 1); return sign(_eval_node(c[1], u, p, t))
    elseif op === :floor; _expect_arity_n(op, c, 1); return floor(_eval_node(c[1], u, p, t))
    elseif op === :ceil;  _expect_arity_n(op, c, 1); return ceil(_eval_node(c[1], u, p, t))
    elseif op === :min
        # n-ary min (esm-spec §4.2 — arity ≥ 2)
        length(c) < 2 && throw(TreeWalkError("E_TREEWALK_ARITY", "min needs ≥2 args"))
        acc = _eval_node(c[1], u, p, t)
        @inbounds for i in 2:length(c); acc = min(acc, _eval_node(c[i], u, p, t)); end
        return acc
    elseif op === :max
        # n-ary max (esm-spec §4.2 — arity ≥ 2)
        length(c) < 2 && throw(TreeWalkError("E_TREEWALK_ARITY", "max needs ≥2 args"))
        acc = _eval_node(c[1], u, p, t)
        @inbounds for i in 2:length(c); acc = max(acc, _eval_node(c[i], u, p, t)); end
        return acc

    elseif op === :pi || op === :π
        return Float64(pi)
    elseif op === :e
        return Float64(ℯ)

    elseif op === :Pre
        _expect_arity_n(op, c, 1)
        return _eval_node(c[1], u, p, t)

    elseif op === :fn
        # `n.handler` is `(fname::String, const_args_or_nothing)`. The
        # tuple's second slot is `nothing` for closed functions whose args
        # are all scalar (e.g. `datetime.*`). For closed functions with
        # const-array args (`interp.searchsorted`, `interp.linear`,
        # `interp.bilinear`) it is a `Vector{Any}` carrying the pre-extracted
        # arrays in spec arg-position order; the remaining scalar args are
        # the node's children, also in spec order.
        fname, const_args = n.handler::Tuple{String,Any}
        if const_args === nothing
            args_evaluated = Any[_eval_node(ci, u, p, t) for ci in c]
            return Float64(evaluate_closed_function(fname, args_evaluated))
        elseif fname == "interp.searchsorted"
            # Spec arg order: (x, xs); xs is const, x is the only child.
            x = _eval_node(c[1], u, p, t)
            return Float64(evaluate_closed_function(fname, Any[x, const_args[1]]))
        elseif fname == "interp.linear"
            # Spec arg order: (table, axis, x); table & axis are const; x is the only child.
            x = _eval_node(c[1], u, p, t)
            return Float64(evaluate_closed_function(fname,
                Any[const_args[1], const_args[2], x]))
        elseif fname == "interp.bilinear"
            # Spec arg order: (table, axis_x, axis_y, x, y); first three are
            # const; x and y are children in order.
            x = _eval_node(c[1], u, p, t)
            y = _eval_node(c[2], u, p, t)
            return Float64(evaluate_closed_function(fname,
                Any[const_args[1], const_args[2], const_args[3], x, y]))
        end

    else
        throw(TreeWalkError("E_TREEWALK_UNSUPPORTED_OP", String(op)))
    end
end

@inline function _require_const_array(arg, fname::String, arg_label::String)
    if arg isa OpExpr && arg.op == "const" && arg.value isa AbstractVector
        return arg.value
    end
    throw(TreeWalkError("E_TREEWALK_FN_ARG_NOT_CONST",
        "$(fname): `$(arg_label)` argument must be a `const`-op array node"))
end

@inline function _expect_arity_n(op::Symbol, c::Vector{_Node}, n::Int)
    length(c) == n ||
        throw(TreeWalkError("E_TREEWALK_ARITY",
                            "$op expects $n args, got $(length(c))"))
    return nothing
end

# ============================================================
# 4b. Vectorized array-kernel evaluator (ess-dhq)
# ============================================================
#
# DESIGN / FEASIBILITY GATE (ess-dhq acceptance criterion #1)
# -----------------------------------------------------------
# The scalar path above (`build_evaluator` + `_make_rhs`/`_eval_node`) compiles
# every discretized `arrayop`-derivative equation into N per-cell scalar `_Node`
# trees and evaluates them with an O(N) element loop. This section makes the
# per-timestep RHS of those array equations run as **whole-array kernels** whose
# compiled-node count is **independent of the grid size N**, with results
# numerically identical to the scalar runner.
#
# Strategy — TRANSPOSE the per-cell nodes, don't re-derive them.
#   The array-D branch of `build_evaluator` already produces, for each output
#   cell, a fully-resolved scalar `_Node` (ghost cells, const-array inlining,
#   semiring joins/filters, variable-valence reduction bounds — all handled at
#   build time, exactly as before). Instead of pushing N nodes into `rhs_list`,
#   we group those nodes by structural shape and *merge each group* into ONE
#   vectorized template (`_VecNode`) whose leaves carry per-cell vectors:
#       - `index(u, ·)`  STATE leaves whose slot varies per cell → `_VK_GATHER`
#                        (a `u[slots]` offset-slice / gather)
#       - const-array / ghost LITERAL leaves that vary    → `_VK_CONSTVEC`
#       - leaves constant across the group (param, t, a   → `_VK_PARAM/_TIME/
#         scalar state read, a shared literal)              _STATE/_LITERAL`,
#                                                            broadcast over lanes
#       - arithmetic / comparison / transcendental ops    → `_VK_OP` (broadcast)
#       - `_NK_CONTRACTION` reductions                     → `_VK_REDUCE`
#         (axis fold in the same order as the scalar path)
#       - closed `fn` ops                                  → `_VK_FN` (per-lane map)
#   Each merged template evaluates over its whole cell-axis with array ops, then
#   `du[out_slots] .= result` scatters the lane values back.
#
# Why this preserves numeric identity: the merge is a structural transpose of
# the *same* compiled per-cell nodes; a broadcast `f.(a, b)` applies the identical
# scalar `f` to lane j that the scalar node computed for cell j, and reductions
# fold in the same order. Elementwise ops are bit-identical; reductions match the
# scalar Tullio/loop order (≤ rounding, absorbed by the tests' tolerances).
#
# Why the kernel count is N-independent: cells that share a structural signature
# collapse into ONE template regardless of how many there are. Ghost boundaries,
# `makearray` BC regions, and distinct contraction valences each form their own
# (N-independent) group — this IS the "interior kernel + boundary kernels"
# decomposition. Only the embedded slot/value vectors grow with N; the number of
# compiled `_VecNode`s does not.
#
# Functions touched: `build_evaluator` (the `_is_arrayop_D_lhs` branch collects
# per-cell entries then calls `_vectorize_cell_entries`; renamed to
# `_build_evaluator_impl` with a thin `build_evaluator` wrapper so the
# N-independence property is introspectable), `_make_rhs` (drives both scalar
# entries and `_VecKernel`s). The scalar/indexed-D paths, `_resolve_indices`,
# `_compile`, and `_eval_node` are UNCHANGED — non-array equations keep their
# exact scalar evaluation.
#
# Node kinds confirmed vectorizable (no scalar fallback retained):
#   stencil arrayop ✓ (gather + broadcast)   contraction/reduction ✓ (axis fold)
#   integral ✓ (resolves to dx*Σcells = an OP/REDUCE tree, vectorized like any)
#   makearray BC regions ✓ (per-region structural groups)  ghost cells ✓ (gather
#   sentinel groups)  gather/indirect ✓ (STATE-slot gather)  broadcast coeffs ✓
#   (const-array → CONSTVEC).  Closed `fn` ops are a per-lane map — one kernel
#   node, N-independent — not a per-cell scalar evaluation strategy.

# `_VecNode` kinds. Disjoint from the scalar `_NK_*` space to keep dispatch clear.
const _VK_LITERAL  = UInt8(1)   # scalar literal, broadcast across lanes
const _VK_CONSTVEC = UInt8(2)   # per-cell constants (n.vals), length = #cells
const _VK_STATE    = UInt8(3)   # scalar u[idx], broadcast across lanes
const _VK_GATHER   = UInt8(4)   # u[slots] — offset-slice / gather over the axis
const _VK_PARAM    = UInt8(5)   # scalar p.<sym>, broadcast
const _VK_TIME     = UInt8(6)   # scalar t, broadcast
const _VK_OP       = UInt8(7)   # elementwise broadcast of op over child vectors
const _VK_REDUCE   = UInt8(8)   # contraction: axis fold over children (semiring)
const _VK_FN       = UInt8(9)   # closed-function map (interp.* = whole-array)
const _VK_PGATHER  = UInt8(10)  # forcing[slots] — gather over a captured live p-buffer (ess-14f.3)

# Each node owns a preallocated `buf` (length = the kernel's lane count) into
# which `_eval_vec` writes its lane values IN PLACE at runtime, then returns it.
# This — together with the explicit `du` scatter in `f!` — is what keeps the RHS
# allocation-free (ess-9cc): the only Float64 arrays are these build-time `buf`s
# captured in the closure, none are allocated per call. CONSTVEC has no `buf` and
# is read straight from its stored `vals`. `fnargs`/`cvbufs` are scratch ONLY for
# the boxed all-scalar `fn` path (`datetime.*`): a reused closed-function argument
# vector and the child result buffers, so that map reuses one `Any[]` across lanes
# instead of building a fresh one per cell. The `interp.*` `fn` ops carry a typed
# `_Interp*Spec` in `handler` instead and run zero-box whole-array kernels
# (ess-wrh), leaving `fnargs`/`cvbufs` as shared empty sentinels; every non-`fn`
# node shares those sentinels too.
#
# Because the buffers are mutable shared state, an evaluator is NON-REENTRANT: a
# given `f!` must not run concurrently for one problem (the ODE integrator calls
# the RHS sequentially, so this holds). Concurrent/ensemble use needs one
# evaluator per task — the same constraint the preallocated MTK reference has.
struct _VecNode
    kind::UInt8
    op::Symbol
    literal::Float64
    idx::Int
    sym::Symbol
    handler::Any
    vals::Vector{Float64}
    slots::Vector{Int}
    children::Vector{_VecNode}
    buf::Vector{Float64}
    fnargs::Vector{Any}
    cvbufs::Vector{Vector{Float64}}
end

const _VK_NO_VALS   = Float64[]
const _VK_NO_SLOTS  = Int[]
const _VK_NO_BUF    = Float64[]
const _VK_NO_FNARGS = Any[]
const _VK_NO_CVBUFS = Vector{Float64}[]

function _mkvnode(; kind::UInt8, op::Symbol=Symbol(""), literal::Float64=0.0,
                  idx::Int=0, sym::Symbol=Symbol(""), handler=nothing,
                  vals::Vector{Float64}=_VK_NO_VALS, slots::Vector{Int}=_VK_NO_SLOTS,
                  children::Vector{_VecNode}=_VecNode[],
                  buf::Vector{Float64}=_VK_NO_BUF,
                  fnargs::Vector{Any}=_VK_NO_FNARGS,
                  cvbufs::Vector{Vector{Float64}}=_VK_NO_CVBUFS)
    return _VecNode(kind, op, literal, idx, sym, handler, vals, slots, children,
                    buf, fnargs, cvbufs)
end

# One vectorized array equation (or one structural sub-group of it): write the
# lane values of `template` into `du[out_slots]`.
struct _VecKernel
    out_slots::Vector{Int}
    template::_VecNode
    len::Int
end

_count_vecnodes(n::_VecNode) =
    1 + sum(_count_vecnodes(ch) for ch in n.children; init=0)

# ---- Structural grouping + merge (build time) ----

# A signature that is equal for two per-cell nodes iff they have an identical
# tree shape ignoring the values that legitimately vary per cell (STATE slot
# index, LITERAL value). Same signature ⇒ unambiguous merge into one template.
# Different signatures (in-bounds STATE vs ghost LITERAL, makearray region A vs
# B, valence-5 vs valence-6 contraction) ⇒ separate kernels.
function _struct_sig(n::_Node)::String
    k = n.kind
    if k === _NK_STATE
        return "S"
    elseif k === _NK_LITERAL
        return "L"
    elseif k === _NK_PARAM
        return string("P:", n.sym)
    elseif k === _NK_PARAM_GATHER
        # Cells gathering from the SAME captured buffer (same `handler` object)
        # merge into one `_VK_PGATHER`, exactly as same-array STATE cells merge to
        # `_VK_GATHER`; the per-lane linear `idx` becomes the gather `slots`.
        # Different buffers ⇒ different `objectid` ⇒ separate kernels.
        return string("PG:", objectid(n.handler))
    elseif k === _NK_TIME
        return "T"
    elseif k === _NK_CONTRACTION
        return string("C:", n.op, "(",
                      join((_struct_sig(ch) for ch in n.children), ","), ")")
    else  # _NK_OP (including closed `fn`)
        h = (n.handler isa Tuple && length(n.handler) >= 1) ?
            string("@", n.handler[1]) : ""
        return string("O:", n.op, h, "(",
                      join((_struct_sig(ch) for ch in n.children), ","), ")")
    end
end

# Allocate the closed-function argument vector for a vectorized all-scalar `fn`
# node (e.g. `datetime.*`): one `Any` slot per child, filled per lane in
# `_eval_vec_fn_boxed`. The `interp.*` ops do NOT use this path — they are lowered
# to typed `_Interp*Spec` carriers at build time (`_merge_nodes`) and evaluated
# through the validation-free `_interp_*_core` kernels with a typed `Float64`
# query, so no `Float64`→`Any` box is ever created on the array RHS (ess-wrh). The
# residual box on the all-scalar path is tolerated: those closed functions are a
# cold case off the PDE diffusion RHS.
_make_fnargs(nchildren::Int)::Vector{Any} = Vector{Any}(undef, nchildren)

# Merge a structurally-identical group of per-cell nodes into one `_VecNode`
# template. Precondition: all elements share `_struct_sig`. `len` is the group's
# lane count (number of cells) — every node in the template produces a length-
# `len` lane vector, so each gets a length-`len` scratch `buf` allocated here,
# ONCE at build time (CONSTVEC excepted — it is read from its stored `vals`).
function _merge_nodes(nodes::Vector{_Node}, len::Int)::_VecNode
    n1 = nodes[1]
    k = n1.kind
    if k === _NK_LITERAL
        v1 = n1.literal
        if all(isequal(nd.literal, v1) for nd in nodes)
            return _mkvnode(kind=_VK_LITERAL, literal=v1, buf=Vector{Float64}(undef, len))
        end
        return _mkvnode(kind=_VK_CONSTVEC, vals=Float64[nd.literal for nd in nodes])
    elseif k === _NK_STATE
        i1 = n1.idx
        if all(nd.idx == i1 for nd in nodes)
            return _mkvnode(kind=_VK_STATE, idx=i1, buf=Vector{Float64}(undef, len))
        end
        return _mkvnode(kind=_VK_GATHER, slots=Int[nd.idx for nd in nodes],
                        buf=Vector{Float64}(undef, len))
    elseif k === _NK_PARAM
        return _mkvnode(kind=_VK_PARAM, sym=n1.sym, buf=Vector{Float64}(undef, len))
    elseif k === _NK_PARAM_GATHER
        # All cells share the captured buffer (`handler`, guaranteed equal by
        # `_struct_sig`); the per-lane linear offsets become the gather `slots`.
        # Mirrors the STATE→`_VK_GATHER` lowering, reading the live forcing buffer
        # instead of `u` (ess-14f.3).
        return _mkvnode(kind=_VK_PGATHER, handler=n1.handler,
                        slots=Int[nd.idx for nd in nodes],
                        buf=Vector{Float64}(undef, len))
    elseif k === _NK_TIME
        return _mkvnode(kind=_VK_TIME, buf=Vector{Float64}(undef, len))
    elseif k === _NK_CONTRACTION
        m = length(n1.children)
        ch = _VecNode[_merge_nodes(_Node[nd.children[c] for nd in nodes], len) for c in 1:m]
        return _mkvnode(kind=_VK_REDUCE, op=n1.op, literal=n1.literal, children=ch,
                        buf=Vector{Float64}(undef, len))
    else  # _NK_OP / fn
        m = length(n1.children)
        ch = _VecNode[_merge_nodes(_Node[nd.children[c] for nd in nodes], len) for c in 1:m]
        if n1.op === :fn
            return _merge_fn_node(n1.handler, ch, len, m)
        end
        return _mkvnode(kind=_VK_OP, op=n1.op, handler=n1.handler, children=ch,
                        buf=Vector{Float64}(undef, len))
    end
end

# Build the vectorized node for a closed-function (`fn`) leaf. `interp.*` ops are
# lowered to a typed `_Interp*Spec` handler (validated + coerced ONCE here at build
# time) so `_eval_vec_fn` runs a zero-box whole-array kernel; all other closed
# functions (`datetime.*`, all-scalar args) keep the boxed per-lane path. As a
# build-time specialization (ess-wrh §4), an interp leaf whose query children are
# all compile-time constants folds to a single `_VK_LITERAL` — the closed-function
# call (and its box) vanish entirely for that leaf.
function _merge_fn_node(handler, ch::Vector{_VecNode}, len::Int, m::Int)::_VecNode
    fname, const_args = handler::Tuple{String,Any}
    if fname == "interp.linear"
        spec = _build_interp_linear_spec(fname, const_args[1], const_args[2])
        folded = _try_fold_const_interp(spec, ch, len)
        folded === nothing || return folded
        return _mkvnode(kind=_VK_FN, op=:fn, handler=spec, children=ch,
                        buf=Vector{Float64}(undef, len))
    elseif fname == "interp.bilinear"
        spec = _build_interp_bilinear_spec(fname, const_args[1], const_args[2], const_args[3])
        folded = _try_fold_const_interp(spec, ch, len)
        folded === nothing || return folded
        return _mkvnode(kind=_VK_FN, op=:fn, handler=spec, children=ch,
                        buf=Vector{Float64}(undef, len))
    elseif fname == "interp.searchsorted"
        spec = _build_interp_searchsorted_spec(fname, const_args[1])
        folded = _try_fold_const_interp(spec, ch, len)
        folded === nothing || return folded
        return _mkvnode(kind=_VK_FN, op=:fn, handler=spec, children=ch,
                        buf=Vector{Float64}(undef, len))
    else
        # All-scalar closed functions (e.g. `datetime.*`): boxed per-lane path.
        return _mkvnode(kind=_VK_FN, op=:fn, handler=handler, children=ch,
                        buf=Vector{Float64}(undef, len),
                        fnargs=_make_fnargs(m),
                        cvbufs=Vector{Vector{Float64}}(undef, m))
    end
end

# (ess-wrh §4) On-knot / constant-query lowering. When EVERY query child of an
# interp leaf merged to a `_VK_LITERAL` (i.e. all cells in the group share the
# same compile-time-constant query), the whole closed-function call collapses to a
# single compile-time value — no runtime kernel, no box. The value is computed
# with the SAME validated `_interp_*_core` the runtime would use, so it is exact:
# this subsumes the on-knot w=0 case the bead calls out (a query landing on an
# affine/integer-axis knot folds to its table entry) WITHOUT the `0*Inf=NaN`
# hazard a bare gather would hit on an infinite neighbor, because the full pinned
# blend is evaluated rather than shortcut. A runtime query (`u[i]` → `_VK_STATE` /
# `_VK_GATHER`) is not build-time known, so the prover declines (returns
# `nothing`) and the node falls through to the whole-array kernel. Returns a
# folded `_VK_LITERAL` `_VecNode`, or `nothing` if not foldable.
function _try_fold_const_interp(spec::_InterpLinearSpec, ch::Vector{_VecNode},
                                len::Int)::Union{_VecNode,Nothing}
    (length(ch) == 1 && ch[1].kind === _VK_LITERAL) || return nothing
    v = _interp_linear_core(spec.table, spec.axis, ch[1].literal)
    return _mkvnode(kind=_VK_LITERAL, literal=Float64(v), buf=Vector{Float64}(undef, len))
end
function _try_fold_const_interp(spec::_InterpSearchsortedSpec, ch::Vector{_VecNode},
                                len::Int)::Union{_VecNode,Nothing}
    (length(ch) == 1 && ch[1].kind === _VK_LITERAL) || return nothing
    v = _interp_searchsorted_core("interp.searchsorted", ch[1].literal, spec.xs)
    return _mkvnode(kind=_VK_LITERAL, literal=Float64(v), buf=Vector{Float64}(undef, len))
end
function _try_fold_const_interp(spec::_InterpBilinearSpec, ch::Vector{_VecNode},
                                len::Int)::Union{_VecNode,Nothing}
    (length(ch) == 2 && ch[1].kind === _VK_LITERAL && ch[2].kind === _VK_LITERAL) ||
        return nothing
    v = _interp_bilinear_core(spec.table, spec.axis_x, spec.axis_y,
                              ch[1].literal, ch[2].literal)
    return _mkvnode(kind=_VK_LITERAL, literal=Float64(v), buf=Vector{Float64}(undef, len))
end

# Group an array equation's per-cell `(du_slot, node)` entries by structure and
# build one `_VecKernel` per group. First-seen group order is preserved for
# deterministic kernel ordering (du writes are to disjoint slots regardless).
function _vectorize_cell_entries(entries::Vector{Tuple{Int,_Node}})::Vector{_VecKernel}
    isempty(entries) && return _VecKernel[]
    order = String[]
    groups = Dict{String,Tuple{Vector{Int},Vector{_Node}}}()
    for (slot, node) in entries
        sig = _struct_sig(node)
        if !haskey(groups, sig)
            groups[sig] = (Int[], _Node[])
            push!(order, sig)
        end
        slots, nds = groups[sig]
        push!(slots, slot)
        push!(nds, node)
    end
    kernels = _VecKernel[]
    for sig in order
        slots, nds = groups[sig]
        push!(kernels, _VecKernel(slots, _merge_nodes(nds, length(slots)), length(slots)))
    end
    return kernels
end

# ---- Vectorized evaluation (runtime) — fully in place (ess-9cc) ----
#
# `_eval_vec` writes the node's lane values into its preallocated `n.buf` and
# RETURNS that buffer (CONSTVEC returns its stored `n.vals`; pure pass-through
# arms return a child's buffer directly). No node ever mutates a child's buffer:
# the template is a pure tree, so every node's `buf` is disjoint from all of its
# descendants', which lets a parent hold several child buffers at once and
# combine them in place. The whole array-kernel evaluation therefore allocates
# nothing — the only Float64 arrays are the build-time `buf`s in the closure.
function _eval_vec(n::_VecNode, u, p, t)::Vector{Float64}
    k = n.kind
    if k === _VK_CONSTVEC
        return n.vals
    elseif k === _VK_GATHER
        b = n.buf; s = n.slots
        @inbounds for j in eachindex(s)
            b[j] = u[s[j]]
        end
        return b
    elseif k === _VK_PGATHER
        # Gather over a captured live forcing buffer (ess-14f.3): identical to
        # `_VK_GATHER` but reads the aliased flat `Vector{Float64}` in `handler`
        # (refreshed in place by the J1 callback) instead of the state `u`. The
        # concrete assert + preallocated `buf`/`slots` keep it zero-alloc.
        b = n.buf; f = n.handler::Vector{Float64}; s = n.slots
        @inbounds for j in eachindex(s)
            b[j] = f[s[j]]
        end
        return b
    elseif k === _VK_LITERAL
        b = n.buf; fill!(b, n.literal); return b
    elseif k === _VK_STATE
        b = n.buf; fill!(b, @inbounds(u[n.idx])); return b
    elseif k === _VK_PARAM
        b = n.buf; fill!(b, getfield(p, n.sym)); return b
    elseif k === _VK_TIME
        b = n.buf; fill!(b, t); return b
    elseif k === _VK_REDUCE
        return _eval_vec_reduce(n, u, p, t)
    elseif k === _VK_FN
        return _eval_vec_fn(n, u, p, t)
    else
        return _eval_vec_op(n, u, p, t)
    end
end

# Semiring axis reduction — folds the contraction children in the SAME order as
# the scalar `_eval_contraction`, seeded in place from the 0̄ identity on the
# node. Writes into `n.buf`; each child buffer is consumed before the next child
# is evaluated, so no child result needs to outlive its use.
function _eval_vec_reduce(n::_VecNode, u, p, t)::Vector{Float64}
    op = n.op
    c = n.children
    b = n.buf
    fill!(b, n.literal)
    if op === :+
        @inbounds for k in 1:length(c)
            ck = _eval_vec(c[k], u, p, t)
            @. b += ck
        end
    elseif op === :*
        @inbounds for k in 1:length(c)
            ck = _eval_vec(c[k], u, p, t)
            @. b *= ck
        end
    elseif op === :max
        @inbounds for k in 1:length(c)
            ck = _eval_vec(c[k], u, p, t)
            @. b = max(b, ck)
        end
    else  # :min
        @inbounds for k in 1:length(c)
            ck = _eval_vec(c[k], u, p, t)
            @. b = min(b, ck)
        end
    end
    return b
end

# Closed-function map — one kernel node writing its lane values into `n.buf`. The
# `interp.*` ops run as zero-box whole-array kernels: their validated table/axis
# live on the node's typed `_Interp*Spec` handler (built once in `_merge_fn_node`)
# and the per-lane query is a typed `Float64`, so the only Float64 arrays are the
# preallocated buffers (ess-wrh) — the `f!` stays allocation-free even with an
# interp/table-lookup leaf on the RHS. Bit-identical to the scalar `:fn` arm: the
# array kernels call the SAME `_interp_*_core` (registered_functions.jl). All other
# closed functions (`datetime.*`, all-scalar args) keep the boxed `AbstractVector`
# path — a cold case off the PDE array RHS. The `isa` ladder is a manual union
# split: each branch narrows `n.handler::Any` to a concrete type, so the kernels
# it calls are type-stable (no dispatch box).
function _eval_vec_fn(n::_VecNode, u, p, t)::Vector{Float64}
    h = n.handler
    if h isa _InterpLinearSpec
        return _eval_vec_interp_linear(h, n, u, p, t)
    elseif h isa _InterpBilinearSpec
        return _eval_vec_interp_bilinear(h, n, u, p, t)
    elseif h isa _InterpSearchsortedSpec
        return _eval_vec_interp_searchsorted(h, n, u, p, t)
    else
        return _eval_vec_fn_boxed(n, u, p, t)
    end
end

# Design note (ess-wrh §2 — "whole-array" form). These kernels iterate lanes and
# call the shared `_interp_*_core` once per lane rather than materializing
# intermediate gathered-axis/table arrays and a fused `@.` blend. The choice is
# deliberate: (a) bit-identity with the scalar `:fn` arm is guaranteed because the
# SAME core (same clamp order, same locate, same pinned blend) runs on both paths
# — a separate broadcast form would have to re-derive the fiddly clamp/NaN/on-knot
# corners and risk divergence; (b) `interp.*` tables are §9.2-capped at ≤1024 (and
# are usually tiny), so a materialized locate→gather→broadcast pass would add
# several length-N scratch buffers and extra passes for no measurable gain. The
# costs ess-wrh targets — the per-lane `Float64`→`Any` box, the per-lane axis
# re-validation, and the boxed `AbstractVector` dispatch — are eliminated here
# regardless of locate strategy: the query is a typed `Float64`, the table/axis
# are validated once at build time, and the call is statically dispatched.
function _eval_vec_interp_linear(h::_InterpLinearSpec, n::_VecNode, u, p, t)::Vector{Float64}
    b = n.buf
    xq = _eval_vec(n.children[1], u, p, t)   # query lane vector (disjoint from b)
    table = h.table; axis = h.axis
    @inbounds for lane in eachindex(b)
        b[lane] = _interp_linear_core(table, axis, xq[lane])
    end
    return b
end

function _eval_vec_interp_searchsorted(h::_InterpSearchsortedSpec, n::_VecNode, u, p, t)::Vector{Float64}
    b = n.buf
    xq = _eval_vec(n.children[1], u, p, t)
    xs = h.xs
    @inbounds for lane in eachindex(b)
        b[lane] = Float64(_interp_searchsorted_core("interp.searchsorted", xq[lane], xs))
    end
    return b
end

function _eval_vec_interp_bilinear(h::_InterpBilinearSpec, n::_VecNode, u, p, t)::Vector{Float64}
    b = n.buf
    xq = _eval_vec(n.children[1], u, p, t)
    yq = _eval_vec(n.children[2], u, p, t)   # sibling buffer, disjoint from xq and b
    table = h.table; axis_x = h.axis_x; axis_y = h.axis_y
    @inbounds for lane in eachindex(b)
        b[lane] = _interp_bilinear_core(table, axis_x, axis_y, xq[lane], yq[lane])
    end
    return b
end

# Boxed fallback for all-scalar closed functions (e.g. `datetime.*`) inside a
# vectorized arrayop: one reusable `Any[]` (`n.fnargs`) is refilled per lane and
# passed to `evaluate_closed_function`. Off the PDE RHS hot loop, so the residual
# per-lane `Float64`→`Any` box is tolerated. `interp.*` never reaches here — those
# are lowered to typed specs at build time.
function _eval_vec_fn_boxed(n::_VecNode, u, p, t)::Vector{Float64}
    fname, const_args = n.handler::Tuple{String,Any}
    const_args === nothing ||
        throw(TreeWalkError("E_TREEWALK_UNSUPPORTED_VEC_OP", string("fn:", fname)))
    c = n.children
    b = n.buf
    args = n.fnargs
    cv = n.cvbufs
    len = length(b)
    @inbounds for a in eachindex(c)
        cv[a] = _eval_vec(c[a], u, p, t)
    end
    @inbounds for lane in 1:len
        for a in 1:length(cv)
            args[a] = cv[a][lane]
        end
        b[lane] = Float64(evaluate_closed_function(fname, args))
    end
    return b
end

# Elementwise op over child vectors, written in place into `n.buf`. Each arm
# mirrors the corresponding scalar arm in `_eval_node_op` — fused `@.` broadcasts
# apply the identical scalar op lane-by-lane, so lane j equals the scalar value
# for cell j (bit-identical). Children are read but never mutated; `n.buf` is
# disjoint from every child buffer, so writing it is always safe. Pure
# pass-through arms (1-ary `+`/`*`/`min`/`max`, `Pre`) return the child buffer
# directly — the parent only reads it.
function _eval_vec_op(n::_VecNode, u, p, t)::Vector{Float64}
    op = n.op
    c = n.children
    b = n.buf

    if op === :+
        c1 = _eval_vec(c[1], u, p, t)
        length(c) == 1 && return c1
        c2 = _eval_vec(c[2], u, p, t)
        @. b = c1 + c2
        @inbounds for i in 3:length(c)
            ci = _eval_vec(c[i], u, p, t)
            @. b += ci
        end
        return b
    elseif op === :*
        c1 = _eval_vec(c[1], u, p, t)
        length(c) == 1 && return c1
        c2 = _eval_vec(c[2], u, p, t)
        @. b = c1 * c2
        @inbounds for i in 3:length(c)
            ci = _eval_vec(c[i], u, p, t)
            @. b *= ci
        end
        return b
    elseif op === :-
        c1 = _eval_vec(c[1], u, p, t)
        if length(c) == 1
            @. b = -c1
            return b
        elseif length(c) == 2
            c2 = _eval_vec(c[2], u, p, t)
            @. b = c1 - c2
            return b
        end
        throw(TreeWalkError("E_TREEWALK_ARITY", "- expects 1 or 2 args"))
    elseif op === :neg
        c1 = _eval_vec(c[1], u, p, t)
        @. b = -c1
        return b
    elseif op === :/
        c1 = _eval_vec(c[1], u, p, t)
        c2 = _eval_vec(c[2], u, p, t)
        @. b = c1 / c2
        return b
    elseif op === :^ || op === :pow
        c1 = _eval_vec(c[1], u, p, t)
        c2 = _eval_vec(c[2], u, p, t)
        @. b = c1 ^ c2
        return b

    elseif op === :<
        c1 = _eval_vec(c[1], u, p, t); c2 = _eval_vec(c[2], u, p, t)
        @. b = ifelse(c1 <  c2, 1.0, 0.0); return b
    elseif op === Symbol("<=")
        c1 = _eval_vec(c[1], u, p, t); c2 = _eval_vec(c[2], u, p, t)
        @. b = ifelse(c1 <= c2, 1.0, 0.0); return b
    elseif op === :>
        c1 = _eval_vec(c[1], u, p, t); c2 = _eval_vec(c[2], u, p, t)
        @. b = ifelse(c1 >  c2, 1.0, 0.0); return b
    elseif op === Symbol(">=")
        c1 = _eval_vec(c[1], u, p, t); c2 = _eval_vec(c[2], u, p, t)
        @. b = ifelse(c1 >= c2, 1.0, 0.0); return b
    elseif op === Symbol("==")
        c1 = _eval_vec(c[1], u, p, t); c2 = _eval_vec(c[2], u, p, t)
        @. b = ifelse(c1 == c2, 1.0, 0.0); return b
    elseif op === Symbol("!=")
        c1 = _eval_vec(c[1], u, p, t); c2 = _eval_vec(c[2], u, p, t)
        @. b = ifelse(c1 != c2, 1.0, 0.0); return b

    elseif op === :and
        # 1.0 iff every child is non-zero (folds in child order, like the scalar
        # arm; all children are evaluated — no short-circuit, matching prior code).
        fill!(b, 1.0)
        @inbounds for a in eachindex(c)
            ca = _eval_vec(c[a], u, p, t)
            @. b = ifelse((b != 0) & (ca != 0), 1.0, 0.0)
        end
        return b
    elseif op === :or
        fill!(b, 0.0)
        @inbounds for a in eachindex(c)
            ca = _eval_vec(c[a], u, p, t)
            @. b = ifelse((b != 0) | (ca != 0), 1.0, 0.0)
        end
        return b
    elseif op === :not
        c1 = _eval_vec(c[1], u, p, t)
        @. b = ifelse(c1 == 0, 1.0, 0.0); return b
    elseif op === :ifelse
        c1 = _eval_vec(c[1], u, p, t)
        c2 = _eval_vec(c[2], u, p, t)
        c3 = _eval_vec(c[3], u, p, t)
        @. b = ifelse(c1 != 0, c2, c3); return b

    elseif op === :sin;   c1 = _eval_vec(c[1], u, p, t); @. b = sin(c1);   return b
    elseif op === :cos;   c1 = _eval_vec(c[1], u, p, t); @. b = cos(c1);   return b
    elseif op === :tan;   c1 = _eval_vec(c[1], u, p, t); @. b = tan(c1);   return b
    elseif op === :asin;  c1 = _eval_vec(c[1], u, p, t); @. b = asin(c1);  return b
    elseif op === :acos;  c1 = _eval_vec(c[1], u, p, t); @. b = acos(c1);  return b
    elseif op === :atan
        c1 = _eval_vec(c[1], u, p, t)
        if length(c) == 1
            @. b = atan(c1); return b
        elseif length(c) == 2
            c2 = _eval_vec(c[2], u, p, t)
            @. b = atan(c1, c2); return b
        end
        throw(TreeWalkError("E_TREEWALK_ARITY", "atan expects 1 or 2 args"))
    elseif op === :atan2
        c1 = _eval_vec(c[1], u, p, t); c2 = _eval_vec(c[2], u, p, t)
        @. b = atan(c1, c2); return b
    elseif op === :sinh;  c1 = _eval_vec(c[1], u, p, t); @. b = sinh(c1);  return b
    elseif op === :cosh;  c1 = _eval_vec(c[1], u, p, t); @. b = cosh(c1);  return b
    elseif op === :tanh;  c1 = _eval_vec(c[1], u, p, t); @. b = tanh(c1);  return b
    elseif op === :asinh; c1 = _eval_vec(c[1], u, p, t); @. b = asinh(c1); return b
    elseif op === :acosh; c1 = _eval_vec(c[1], u, p, t); @. b = acosh(c1); return b
    elseif op === :atanh; c1 = _eval_vec(c[1], u, p, t); @. b = atanh(c1); return b
    elseif op === :exp;   c1 = _eval_vec(c[1], u, p, t); @. b = exp(c1);   return b
    elseif op === :log;   c1 = _eval_vec(c[1], u, p, t); @. b = log(c1);   return b
    elseif op === :log10; c1 = _eval_vec(c[1], u, p, t); @. b = log10(c1); return b
    elseif op === :sqrt;  c1 = _eval_vec(c[1], u, p, t); @. b = sqrt(c1);  return b
    elseif op === :abs;   c1 = _eval_vec(c[1], u, p, t); @. b = abs(c1);   return b
    elseif op === :sign;  c1 = _eval_vec(c[1], u, p, t); @. b = sign(c1);  return b
    elseif op === :floor; c1 = _eval_vec(c[1], u, p, t); @. b = floor(c1); return b
    elseif op === :ceil;  c1 = _eval_vec(c[1], u, p, t); @. b = ceil(c1);  return b
    elseif op === :min
        c1 = _eval_vec(c[1], u, p, t)
        length(c) == 1 && return c1
        c2 = _eval_vec(c[2], u, p, t)
        @. b = min(c1, c2)
        @inbounds for i in 3:length(c)
            ci = _eval_vec(c[i], u, p, t)
            @. b = min(b, ci)
        end
        return b
    elseif op === :max
        c1 = _eval_vec(c[1], u, p, t)
        length(c) == 1 && return c1
        c2 = _eval_vec(c[2], u, p, t)
        @. b = max(c1, c2)
        @inbounds for i in 3:length(c)
            ci = _eval_vec(c[i], u, p, t)
            @. b = max(b, ci)
        end
        return b

    elseif op === :pi || op === :π
        fill!(b, Float64(pi)); return b
    elseif op === :e
        fill!(b, Float64(ℯ)); return b
    elseif op === :Pre
        return _eval_vec(c[1], u, p, t)
    else
        throw(TreeWalkError("E_TREEWALK_UNSUPPORTED_VEC_OP", String(op)))
    end
end

# Inner closure generator — separated so the closure's body is small
# enough to stay inferable. `rhs_list` and `vec_kernels` are captured by the
# closure; Julia specializes the generated method to the captured types.
# Scalar/indexed-D equations evaluate through `rhs_list` (one slot each); array
# (`arrayop`) equations evaluate through `vec_kernels` as whole-array ops.
# Accepts any AbstractVector so both the pre-allocated and the
# dynamically-grown forms produced by build_evaluator work.
#
# The vectorized scatter writes lane values back into `du` with an explicit
# indexed loop (NOT `du[out_slots] .= …`, whose `dotview` allocates a SubArray):
# combined with the in-place `_eval_vec`, the whole RHS is allocation-free in
# steady state (ess-9cc), so it can be reused across every RK stage without GC
# pressure. Property pinned by the `@allocated f!(du,u,p,t) == 0` test.
function _make_rhs(rhs_list::AbstractVector{Tuple{Int,_Node}},
                   cse_prelude::AbstractVector{_Node},
                   cse_cache::Vector{Float64},
                   vec_kernels::AbstractVector{_VecKernel})
    function f!(du, u, p, t)
        # CSE prelude (ess-r7h): evaluate each distinct shared subexpression
        # exactly once per call into the scratch cache, in slot order. `defs[s]`
        # references only slots < s (topological), so each read is already
        # filled. Every slot is overwritten each call, so there is no staleness;
        # the cache makes `f!` non-reentrant (one instance per integrator, which
        # is how ODE RHS closures are used). Empty prelude ⇒ this loop is a no-op
        # and f! is identical to the pre-CSE evaluator.
        @inbounds for s in 1:length(cse_prelude)
            cse_cache[s] = _eval_node(cse_prelude[s], u, p, t)
        end
        @inbounds for k in 1:length(rhs_list)
            idx_and_node = rhs_list[k]
            du[idx_and_node[1]] = _eval_node(idx_and_node[2], u, p, t)
        end
        @inbounds for j in 1:length(vec_kernels)
            vk = vec_kernels[j]
            res = _eval_vec(vk.template, u, p, t)
            out = vk.out_slots
            for m in 1:length(out)
                du[out[m]] = res[m]
            end
        end
        return nothing
    end
    return f!
end

# ============================================================
# 5. Misc helpers
# ============================================================

function _is_time_derivative_lhs(lhs)
    return isa(lhs, OpExpr) && lhs.op == "D" && lhs.wrt == "t" &&
           length(lhs.args) == 1
end

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
function _sub_preserving(expr::NumExpr, bindings::Dict{String,Expr})
    return expr
end
function _sub_preserving(expr::IntExpr, bindings::Dict{String,Expr})
    return expr
end
function _sub_preserving(expr::VarExpr, bindings::Dict{String,Expr})
    return get(bindings, expr.name, expr)
end
function _sub_preserving(expr::OpExpr, bindings::Dict{String,Expr})
    new_args = Expr[_sub_preserving(a, bindings) for a in expr.args]
    new_body = expr.expr_body === nothing ?
               nothing : _sub_preserving(expr.expr_body, bindings)
    new_values = expr.values === nothing ?
                 nothing : Expr[_sub_preserving(v, bindings) for v in expr.values]
    # Substitute loop-var bindings into range BOUNDS too, so a nested arrayop
    # whose reduction bound references an OUTER loop index — e.g. a per-cell
    # variable-valence reduction `k ∈ [1, index(n_edges_on_cell, i)]` inside an
    # outer `i`-loop — has `i` resolved when the inner arrayop is later expanded.
    # Bounds are Int (pass through) or Expr (recursively substituted).
    new_ranges = _sub_ranges(expr.ranges, bindings)
    # Substitute loop-var bindings into a `filter` predicate too, so a nested
    # aggregate's filter sees the outer index values (the join's `join_gates` are
    # position-keyed and need no substitution — they are carried through).
    new_filter = expr.filter === nothing ? nothing : _sub_preserving(expr.filter, bindings)
    return OpExpr(expr.op, new_args;
                  wrt=expr.wrt, dim=expr.dim,
                  int_var=expr.int_var, lower=expr.lower, upper=expr.upper,
                  output_idx=expr.output_idx, expr_body=new_body,
                  reduce=expr.reduce, semiring=expr.semiring, ranges=new_ranges,
                  regions=expr.regions, values=new_values,
                  shape=expr.shape, perm=expr.perm, axis=expr.axis,
                  fn=expr.fn, name=expr.name, value=expr.value,
                  join=expr.join, filter=new_filter, join_gates=expr.join_gates,
                  id=expr.id, manifold=expr.manifold)
end

# Substitute loop-var bindings into an arrayop `ranges` dict's bound expressions.
# Each entry is a vector whose elements are Int (left as-is) or an Expr bound
# (recursively `_sub_preserving`d). Returns `nothing` unchanged when ranges is
# nothing; otherwise a fresh Dict so the original is never mutated.
_sub_ranges(ranges::Nothing, ::Dict{String,Expr}) = nothing
function _sub_ranges(ranges, bindings::Dict{String,Expr})
    out = Dict{String,Any}()
    for (k, v) in ranges
        out[String(k)] = v isa AbstractVector ?
            Any[(e isa Expr ? _sub_preserving(e, bindings) : e) for e in v] : v
    end
    return out
end

# Resolve observed-into-observed substitutions to a fixed point. After
# this runs, no RHS in the returned dict contains another observed
# variable as a free variable — so inlining observed names into a
# model equation is a single `_sub_preserving` call. Iteration cap =
# depth of the longest valid chain; exceeding it means there's a cycle.
function _resolve_observed(obs::Dict{String,Expr})
    resolved = Dict{String,Expr}()
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

Anything else (e.g. a coordinate/loaded expression the seed path cannot fold) is
a hard error, so a scoped-reference ic that cannot be resolved is never silently
dropped.
"""
function _resolve_field_ic(target::AbstractString, rhs::EarthSciSerialization.Expr,
                           cell::Vector{Int}, const_arrays, registered_functions)::Float64
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
    # (2) Broadcast constant.
    try
        return Float64(evaluate_expr(rhs, Dict{String,Float64}();
                                     registered_functions=registered_functions))
    catch
    end
    # (3) Unsupported RHS — a clear error, never a silent drop.
    _fld = rhs isa VarExpr ? " (no const_arrays entry named '$(rhs.name)')" : ""
    throw(TreeWalkError("E_TREEWALK_UNSUPPORTED_EQUATION",
        "ic($(target)): RHS is neither a loaded const-array field nor a constant" *
        "$(_fld); supply the initial field via const_arrays or a scalar expression"))
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

# ============================================================
# 5c. Semiring registry (RFC semiring-faq-unified-ir §5.1)
# ============================================================
#
# A semiring is the pair (⊕, ⊗) together with its two NORMATIVE identity
# elements (0̄, 1̄): 0̄ is the value of an empty ⊕-reduction and 1̄ the value of
# an empty ⊗-product. The `reduce` field on an aggregate names ⊕ only; the
# matching ⊗ and BOTH identities come from this table, NEVER from the file.
# The registry is closed and exhaustive — adding a semiring is a spec change.
struct _Semiring
    name::String
    oplus::String      # ⊕ reduce spelling
    zerobar::Float64   # 0̄ : result of an empty ⊕-reduction
    otimes::String     # ⊗ product spelling
    onebar::Float64    # 1̄ : result of an empty ⊗-product
end

# ±∞ identities are represented per-binding (Julia: Inf/-Inf) and are the
# *result* of an empty reduction — never written into a file (§5.1 note 2).
const _SEMIRING_REGISTRY = Dict{String,_Semiring}(
    "sum_product" => _Semiring("sum_product", "+",   0.0,  "*", 1.0),
    "max_product" => _Semiring("max_product", "max", -Inf, "*", 1.0),
    "min_sum"     => _Semiring("min_sum",     "min",  Inf, "+", 0.0),
    "max_sum"     => _Semiring("max_sum",     "max", -Inf, "+", 0.0),
    "bool_and_or" => _Semiring("bool_and_or", "or",   0.0, "and", 1.0),  # false / true
)

# ⊕-spelling → 0̄, the empty-⊕-reduction identity. Derived from (and consistent
# with) the registry table; this is what the legacy `reduce`-only shorthand
# resolves to when no `semiring` is given (⊕ = reduce, ⊗ = "*"; §5.1 note 1).
# "*" is the legacy product-reduce: no registry semiring has ⊕=× (it appears
# only as ⊗), but files predating the registry may carry reduce="*".
const _OPLUS_IDENTITY = Dict{String,Float64}(
    "+" => 0.0, "max" => -Inf, "min" => Inf, "*" => 1.0, "or" => 0.0,
)

# Resolve an aggregate node's (⊕ spelling, 0̄ identity) — everything the
# evaluator needs to fold a reduction and to value an empty one. `semiring`
# (if present) is authoritative and supersedes `reduce`; otherwise `reduce`
# (default "+") names ⊕. Both ⊗ and the identities are sourced here, never
# from the file.
function _aggregate_oplus_identity(semiring::Union{String,Nothing},
                                   reduce::Union{String,Nothing})
    if semiring !== nothing
        sr = get(_SEMIRING_REGISTRY, semiring, nothing)
        sr === nothing && throw(TreeWalkError("E_TREEWALK_UNKNOWN_SEMIRING",
            "unknown semiring '$semiring'; the closed registry is " *
            join(sort(collect(keys(_SEMIRING_REGISTRY))), ", ")))
        return (sr.oplus, sr.zerobar)
    end
    r = reduce === nothing ? "+" : reduce
    haskey(_OPLUS_IDENTITY, r) || throw(TreeWalkError("E_TREEWALK_ARRAYOP_UNKNOWN_REDUCE",
        "unsupported reduce='$r'; expected one of +, *, max, min (or set `semiring`)"))
    return (r, _OPLUS_IDENTITY[r])
end

# True for both the canonical `aggregate` op tag and its deprecated `arrayop`
# alias (§5.6). The evaluator dispatches on the two identically.
@inline _is_aggregate_op(op::AbstractString) = (op == "arrayop" || op == "aggregate")

# Combine a vector of expressions with the semiring ⊕ (`oplus`), returning the
# 0̄ identity (`zerobar`) for an empty reduction. Build-time helper for
# expression-position aggregate expansion.
# For "+" and "*" we emit an n-ary OpExpr (matching _eval_node_op hot paths).
# For "max"/"min" we emit left-folded binary OpExprs to avoid adding n-ary
# variants to _eval_node_op (which already handles them as ≥2-arg ops, but
# the build-time fold keeps runtime dispatch uniform).
function _combine_with_reducer(oplus::String, zerobar::Float64, terms::Vector{Expr})
    isempty(terms) && return NumExpr(zerobar)
    length(terms) == 1 && return terms[1]
    if oplus == "+"
        return OpExpr("+", terms)
    elseif oplus == "*"
        return OpExpr("*", terms)
    elseif oplus == "max"
        result = terms[1]
        for i in 2:length(terms)
            result = OpExpr("max", Expr[result, terms[i]])
        end
        return result
    elseif oplus == "min"
        result = terms[1]
        for i in 2:length(terms)
            result = OpExpr("min", Expr[result, terms[i]])
        end
        return result
    else
        # ⊕ ∈ {or} (bool_and_or) is index-set-producing (§5.5) — out of scope
        # for the M1 array-producing tree-walk evaluator.
        throw(TreeWalkError("E_TREEWALK_ARRAYOP_UNSUPPORTED_SEMIRING",
            "array-producing aggregate with ⊕='$oplus' is not supported by the " *
            "tree-walk evaluator (M1); only numeric semirings (+, *, max, min) " *
            "reduce to an array — bool_and_or is index-set-producing (§5.5)"))
    end
end

# ============================================================
# 5c-join. M2 — value-equality joins (RFC semiring-faq-unified-ir §5.3)
# ============================================================
#
# A `join` clause gates which (output × contracted) index combinations of an
# aggregate contribute a ⊗-product term: a term contributes iff, for EVERY
# key-column pair of EVERY clause, the two columns hold the SAME key value
# (categorical member compared by Unicode code point; interval / dense index by
# its integer value). All pairs of all clauses are ANDed. Resolution is purely
# structural — it depends only on the index symbols and the document index-set
# registry, never on run-time factor values — so it happens once at BUILD time:
# each key symbol's range position is bucketed into a canonical code (equal codes
# ⇔ equal key values, RFC Appendix A.6) and the expansion sites drop any
# combination whose codes disagree. A dropped combination contributes nothing →
# the additive identity 0̄ once the reduction is empty (§5.1). Because the output
# stays in DECLARED index order, a degenerate / positional join (each key bound
# to its own dimension) keeps every term and is byte-identical to the join-free
# node (§5.3). Inner-only; many-to-many is defined (m·n terms), not an error.

# One resolved key-column pair: the two range symbols and, for each, a map from a
# range position (the loop-variable value) to its bucket code. A combination is
# admitted iff `codes_l[pos_l] == codes_r[pos_r]` for every gate.
struct _JoinGate
    sym_l::String
    sym_r::String
    codes_l::Dict{Int,Int}
    codes_r::Dict{Int,Int}
end

# Resolve a join-key name to the range symbol it denotes (RFC §5.3): either a
# declared range symbol directly, or the name of an index set bound by exactly
# one range symbol via `{from: <name>}` (naming the dimension instead of the loop
# symbol). Zero or multiple bindings are build-time errors.
function _join_sym_for_key(key::String, ranges::AbstractDict, sym_to_set::AbstractDict)
    haskey(ranges, key) && return key
    candidates = sort!(String[s for (s, setn) in sym_to_set if setn == key])
    if length(candidates) == 1
        return candidates[1]
    elseif isempty(candidates)
        throw(TreeWalkError("E_TREEWALK_JOIN_UNKNOWN_KEY",
            "join key '$key' is neither a declared range symbol nor an index set " *
            "bound by a range of this aggregate (RFC semiring-faq-unified-ir §5.3)"))
    else
        throw(TreeWalkError("E_TREEWALK_JOIN_AMBIGUOUS_KEY",
            "join key '$key' names an index set bound by multiple range symbols " *
            "$(candidates); reference the range symbol directly (RFC §5.3)"))
    end
end

# Validate one member used as a join key (RFC §5.3 / §5.7): keys must be
# exact-equality types — integer IDs or string members. Floats (equality is not
# portable across bindings), booleans, and nulls are build-time errors.
function _validated_key_member(m, set_name::String)
    m === nothing && throw(TreeWalkError("E_TREEWALK_JOIN_NULL_KEY",
        "null member in join key index set '$set_name': emitting null into a key " *
        "column is a build-time error (RFC semiring-faq-unified-ir §5.3)"))
    if m isa Bool
        throw(TreeWalkError("E_TREEWALK_JOIN_KEY_TYPE",
            "boolean member $(repr(m)) in join key index set '$set_name' is not an " *
            "exact-equality key type (RFC §5.3)"))
    elseif m isa AbstractFloat
        throw(TreeWalkError("E_TREEWALK_JOIN_FLOAT_KEY",
            "floating-point member $(repr(m)) in join key index set '$set_name': " *
            "float join keys are forbidden — equality is not portable across " *
            "bindings (RFC semiring-faq-unified-ir §5.3 / §5.7 rule 1)"))
    elseif m isa Integer
        return Int(m)
    elseif m isa AbstractString
        return String(m)
    else
        throw(TreeWalkError("E_TREEWALK_JOIN_KEY_TYPE",
            "unsupported join key member type $(typeof(m)) in index set " *
            "'$set_name'; keys must be integer IDs or categorical members (RFC §5.3)"))
    end
end

# The 1-based range positions iterated for a join-key symbol — the loop-variable
# values the expansion will see (categorical / interval `{from}` resolve to
# `1:size`; a dense `[lo,hi]` tuple expands to `lo:hi`). Runs on the ORIGINAL
# (pre-index-set-resolution) ranges so the `{from}` reference is still present.
function _join_key_positions(sym::String, ranges::AbstractDict, index_sets::AbstractDict)
    spec = get(ranges, sym, nothing)
    spec === nothing && throw(TreeWalkError("E_TREEWALK_JOIN_UNKNOWN_KEY",
        "join key symbol '$sym' is not a range of this aggregate (RFC §5.3)"))
    if spec isa IndexSetRef
        haskey(index_sets, spec.from) || throw(TreeWalkError(
            "E_TREEWALK_UNDECLARED_INDEX_SET",
            "undeclared index set '$(spec.from)' referenced by join key '$sym' (RFC §5.2)"))
        is = index_sets[spec.from]
        if is.kind == "categorical"
            n = is.members === nothing ? 0 : length(is.members)
            return collect(1:n)
        elseif is.kind == "interval"
            is.size === nothing && throw(TreeWalkError("E_TREEWALK_INDEX_SET_INCOMPLETE",
                "interval index set '$(spec.from)' requires a `size`"))
            return collect(1:Int(is.size))
        else
            throw(TreeWalkError("E_TREEWALK_JOIN_KEY_KIND",
                "join key index set '$(spec.from)' has kind '$(is.kind)'; only " *
                "'interval' (integer IDs) and 'categorical' keys can be equi-joined " *
                "(RFC §5.3)"))
        end
    end
    return collect(_expand_int_range(spec))
end

# The key VALUE at each range position for a join-key symbol (RFC §5.3): a
# categorical range yields its declared members (validated as exact-equality
# keys); an interval or dense integer range yields the integer index itself.
function _key_member_values(sym::String, ranges::AbstractDict, positions::Vector{Int},
                            index_sets::AbstractDict)
    spec = get(ranges, sym, nothing)
    if spec isa IndexSetRef
        is = index_sets[spec.from]
        if is.kind == "categorical"
            # Prefer the original-typed members (retained only when non-string) so
            # float / null keys are rejected; otherwise the string members are keys.
            src = is.members_raw !== nothing ? is.members_raw :
                  (is.members === nothing ? Any[] : is.members)
            return Any[_validated_key_member(src[p], spec.from) for p in positions]
        elseif is.kind == "interval"
            return Any[Int(p) for p in positions]
        end
    end
    # Dense integer-tuple range — the integer index value is the key.
    return Any[Int(p) for p in positions]
end

# Bucket two key columns into one canonical sorted order and return
# equal-iff-equal integer codes (RFC Appendix A.6 / §5.7 rule 1: integers by
# value, strings by Unicode code point). Equal values get equal codes; a value
# present on only one side never matches (inner join → 0̄). Coupling an integer
# key column to a string key column is a key-type error (they can never compare
# equal — §5.3).
function _encode_join_keys(vals_l::Vector{Any}, vals_r::Vector{Any})
    l_str = any(v -> v isa AbstractString, vals_l)
    r_str = any(v -> v isa AbstractString, vals_r)
    if l_str != r_str
        throw(TreeWalkError("E_TREEWALK_JOIN_KEY_TYPE",
            "join pair couples incompatible key types (integer IDs vs categorical " *
            "string members); both sides must be the same exact-equality type " *
            "(RFC semiring-faq-unified-ir §5.3)"))
    end
    table = sort!(unique(vcat(vals_l, vals_r)))
    code_of = Dict{Any,Int}(v => i for (i, v) in enumerate(table))
    return (Int[code_of[v] for v in vals_l], Int[code_of[v] for v in vals_r])
end

# The empty value-invention map registry: no materialised buffers. A join over
# categorical / interval members never consults it, so join resolution stays
# byte-identical for every non-value-invention document.
const _EMPTY_VI_MAPS = (maps=Dict{String,Any}(), map_sets=Dict{String,String}())

# Resolve one join-key name to `(sym, positions, values)` — the range symbol it
# denotes, the 1-based positions iterated for it, and the key VALUE at each
# position. Two cases (RFC §5.3):
#  - the key names a value-invention MAP buffer (e.g. `src_bin`, materialised by
#    the front-door): the broad-phase bin key is DATA-DERIVED, so it is not a
#    categorical index-set member — read the key value per position from the
#    buffer `vi_maps.maps[key]`, and find the range symbol via the buffer's
#    declared 1-D shape index set (`vi_maps.map_sets[key]`);
#  - otherwise the key is a range symbol / index-set name whose key column is the
#    categorical member (or interval integer index) from the document registry.
function _join_key_sym_pos_vals(key::String, ranges::AbstractDict,
                                index_sets::AbstractDict, sym_to_set::AbstractDict,
                                vi_maps)
    if haskey(vi_maps.maps, key)
        setn = get(vi_maps.map_sets, key, nothing)
        setn === nothing && throw(TreeWalkError("E_TREEWALK_JOIN_UNKNOWN_KEY",
            "value-invention join key '$key' has no recorded 1-D shape index set " *
            "(RFC semiring-faq-unified-ir §5.3)"))
        sym = _join_sym_for_key(setn, ranges, sym_to_set)
        positions = _join_key_positions(sym, ranges, index_sets)
        buf = vi_maps.maps[key]
        vals = Any[buf[p] for p in positions]
        return (sym, positions, vals)
    end
    sym = _join_sym_for_key(key, ranges, sym_to_set)
    positions = _join_key_positions(sym, ranges, index_sets)
    vals = _key_member_values(sym, ranges, positions, index_sets)
    return (sym, positions, vals)
end

# Resolve every join clause of an aggregate node into `_JoinGate`s (RFC §5.3).
# Operates on the node's ORIGINAL ranges (index-set `{from}` refs intact) so it
# can read categorical members from the document registry; a key that names a
# value-invention map buffer gates on the materialised buffer values instead.
function _resolve_join_gates_for(node::OpExpr, index_sets::AbstractDict,
                                 vi_maps=_EMPTY_VI_MAPS)
    node.join === nothing && return nothing
    ranges = node.ranges === nothing ? Dict{String,Any}() : node.ranges
    sym_to_set = Dict{String,String}(
        s => spec.from for (s, spec) in ranges if spec isa IndexSetRef)
    gates = Vector{Any}()
    for clause in node.join            # clause :: Vector{Tuple{String,String}}
        for (lkey, rkey) in clause
            sym_l, pos_l, vals_l = _join_key_sym_pos_vals(lkey, ranges, index_sets, sym_to_set, vi_maps)
            sym_r, pos_r, vals_r = _join_key_sym_pos_vals(rkey, ranges, index_sets, sym_to_set, vi_maps)
            codes_l, codes_r = _encode_join_keys(vals_l, vals_r)
            push!(gates, _JoinGate(sym_l, sym_r,
                Dict{Int,Int}(zip(pos_l, codes_l)),
                Dict{Int,Int}(zip(pos_r, codes_r))))
        end
    end
    return gates
end

# True iff every join pair's key columns are equal under `binding` (symbol →
# range position). `nothing` gates (no join) admit everything.
function _join_admits(gates, binding::AbstractDict)
    gates === nothing && return true
    for g in gates
        gg = g::_JoinGate
        gg.codes_l[binding[gg.sym_l]] == gg.codes_r[binding[gg.sym_r]] || return false
    end
    return true
end

# True if any node in the subtree carries a `join` clause — used to skip the
# resolution pre-pass (and stay byte-identical) for join-free documents.
function _expr_has_join(expr::OpExpr)
    expr.join !== nothing && return true
    any(_expr_has_join, expr.args) && return true
    expr.expr_body !== nothing && _expr_has_join(expr.expr_body) && return true
    expr.values !== nothing && any(_expr_has_join, expr.values) && return true
    expr.filter !== nothing && _expr_has_join(expr.filter) && return true
    return false
end
_expr_has_join(::Expr) = false
_eq_has_join(eq::Equation) = _expr_has_join(eq.lhs) || _expr_has_join(eq.rhs)

# Rewrite each aggregate node's `join` clauses into build-time `join_gates`
# against the document index-set registry, preserving every other field. Runs
# BEFORE index-set range resolution so categorical `{from}` refs are still
# present for member lookup. The wire `join`/`filter` fields are carried through
# unchanged (serialization round-trips them); only the internal `join_gates` is
# populated.
function _resolve_join_in_expr(expr::OpExpr, index_sets::AbstractDict, vi_maps=_EMPTY_VI_MAPS)
    new_args = Expr[_resolve_join_in_expr(a, index_sets, vi_maps) for a in expr.args]
    new_body = expr.expr_body === nothing ? nothing : _resolve_join_in_expr(expr.expr_body, index_sets, vi_maps)
    new_values = expr.values === nothing ? nothing :
                 Expr[_resolve_join_in_expr(v, index_sets, vi_maps) for v in expr.values]
    new_lower = expr.lower === nothing ? nothing : _resolve_join_in_expr(expr.lower, index_sets, vi_maps)
    new_upper = expr.upper === nothing ? nothing : _resolve_join_in_expr(expr.upper, index_sets, vi_maps)
    new_filter = expr.filter === nothing ? nothing : _resolve_join_in_expr(expr.filter, index_sets, vi_maps)
    gates = (_is_aggregate_op(expr.op) && expr.join !== nothing) ?
            _resolve_join_gates_for(expr, index_sets, vi_maps) : expr.join_gates
    return OpExpr(expr.op, new_args;
                  wrt=expr.wrt, dim=expr.dim, int_var=expr.int_var,
                  lower=new_lower, upper=new_upper,
                  output_idx=expr.output_idx, expr_body=new_body,
                  reduce=expr.reduce, semiring=expr.semiring, ranges=expr.ranges,
                  regions=expr.regions, values=new_values,
                  shape=expr.shape, perm=expr.perm, axis=expr.axis,
                  fn=expr.fn, name=expr.name, value=expr.value,
                  table=expr.table, table_axes=expr.table_axes, output=expr.output,
                  join=expr.join, filter=new_filter, join_gates=gates,
                  id=expr.id, manifold=expr.manifold)
end
_resolve_join_in_expr(expr::Expr, ::AbstractDict, vi_maps=_EMPTY_VI_MAPS) = expr

_resolve_join_in_eq(eq::Equation, index_sets::AbstractDict, vi_maps=_EMPTY_VI_MAPS) =
    Equation(_resolve_join_in_expr(eq.lhs, index_sets, vi_maps),
             _resolve_join_in_expr(eq.rhs, index_sets, vi_maps);
             _comment=eq._comment)

# Resolve join gates across a vector of equations. Returns the input unchanged
# when no equation uses a `join` clause (byte-identical for join-free files).
# `vi_maps` carries any value-invention map buffers a `join.on` gates on (RFC §5.3).
function _resolve_join_gates(eqs::Vector{Equation}, index_sets::AbstractDict,
                             vi_maps=_EMPTY_VI_MAPS)
    any(_eq_has_join, eqs) || return eqs
    return Equation[_resolve_join_in_eq(eq, index_sets, vi_maps) for eq in eqs]
end

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

# Resolve ONE IndexSetRef to a concrete `ranges` value. Errors clearly on an
# undeclared name — no implicit interval is inferred, so a typo can't silently
# become an empty set (§5.2).
function _resolve_one_index_set_ref(ref::IndexSetRef, index_sets::AbstractDict,
                                    derived_extents::AbstractDict=_EMPTY_DERIVED_EXTENTS)
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
        idx_args = Expr[VarExpr(is.offsets)]
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
                      derived_extents::AbstractDict=_EMPTY_DERIVED_EXTENTS)
    new_args = Expr[_resolve_isr(a, index_sets, derived_extents) for a in expr.args]
    new_body = expr.expr_body === nothing ? nothing : _resolve_isr(expr.expr_body, index_sets, derived_extents)
    new_values = expr.values === nothing ? nothing :
                 Expr[_resolve_isr(v, index_sets, derived_extents) for v in expr.values]
    new_lower = expr.lower === nothing ? nothing : _resolve_isr(expr.lower, index_sets, derived_extents)
    new_upper = expr.upper === nothing ? nothing : _resolve_isr(expr.upper, index_sets, derived_extents)
    new_ranges = expr.ranges
    if expr.ranges !== nothing && any(v -> v isa IndexSetRef, values(expr.ranges))
        new_ranges = Dict{String,Any}()
        for (k, v) in expr.ranges
            new_ranges[k] = v isa IndexSetRef ?
                _resolve_one_index_set_ref(v, index_sets, derived_extents) : v
        end
    end
    return OpExpr(expr.op, new_args;
                  wrt=expr.wrt, dim=expr.dim, int_var=expr.int_var,
                  lower=new_lower, upper=new_upper,
                  output_idx=expr.output_idx, expr_body=new_body,
                  reduce=expr.reduce, semiring=expr.semiring, ranges=new_ranges,
                  regions=expr.regions, values=new_values,
                  shape=expr.shape, perm=expr.perm, axis=expr.axis,
                  fn=expr.fn, name=expr.name, value=expr.value,
                  table=expr.table, table_axes=expr.table_axes, output=expr.output,
                  join=expr.join, filter=expr.filter, join_gates=expr.join_gates,
                  id=expr.id, manifold=expr.manifold)
end
_resolve_isr(expr::Expr, ::AbstractDict, ::AbstractDict=_EMPTY_DERIVED_EXTENTS) = expr
_resolve_isr(eq::Equation, index_sets::AbstractDict,
             derived_extents::AbstractDict=_EMPTY_DERIVED_EXTENTS) =
    Equation(_resolve_isr(eq.lhs, index_sets, derived_extents),
             _resolve_isr(eq.rhs, index_sets, derived_extents);
             _comment=eq._comment)

# Resolve all index-set references across a vector of equations. Returns the
# input unchanged when no equation uses a `{from}` reference — preserving
# byte-identical behaviour (and the compiled tree) for existing files (§6).
function _resolve_index_set_ranges(eqs::Vector{Equation}, index_sets::AbstractDict,
                                   derived_extents::AbstractDict=_EMPTY_DERIVED_EXTENTS)
    any(_has_index_set_ref, eqs) || return eqs
    return Equation[_resolve_isr(eq, index_sets, derived_extents) for eq in eqs]
end

# Resolve index(arrayop(...), k1, k2, ...) in expression position by
# substituting the output_idx values and unrolling contracted indices at
# build time. Mirrors the LHS-arrayop expansion in build_evaluator (lines
# ~280-370) but produces a scalar Expr instead of writing to rhs_list.
function _resolve_index_of_arrayop(arrayop_expr::OpExpr, idx_args::Vector{Expr},
                                    array_var_info, var_map, const_arrays,
                                    pgather::AbstractDict=_EMPTY_PGATHER)
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
    k_vals = [_eval_const_int(a, Dict{String,Int}(), const_arrays) for a in idx_args]
    idx_exprs = Dict{String,Expr}(
        output_idx_strs[d] => IntExpr(Int64(k_vals[d]))
        for d in 1:length(output_idx_strs))
    sub_body = _sub_preserving(body, idx_exprs)

    # Contracted indices: all range keys NOT appearing in output_idx.
    output_idx_set = Set(output_idx_strs)
    contract_names = sort!(String[n for n in keys(ranges_dict) if !(n in output_idx_set)])
    contract_iters = [collect(_expand_int_range(ranges_dict[n])) for n in contract_names]

    # M2 (§5.3 / §7.2): value-equality join gates + filter predicate. Resolved at
    # build time for the join (drop non-matching combinations) and compiled to a
    # runtime `ifelse(pred, term, 0̄)` for the filter. With neither, this is the
    # unchanged M1 expansion.
    gates = arrayop_expr.join_gates
    filt0 = arrayop_expr.filter
    if isempty(contract_names) && gates === nothing && filt0 === nothing
        return _resolve_indices(sub_body, array_var_info, var_map, const_arrays, pgather)
    end

    terms = Expr[]
    for k_tuple in Iterators.product(contract_iters...)
        if gates !== nothing
            binding = Dict{String,Int}()
            for d in 1:length(output_idx_strs)
                binding[output_idx_strs[d]] = k_vals[d]
            end
            for d in 1:length(contract_names)
                binding[contract_names[d]] = k_tuple[d]
            end
            _join_admits(gates, binding) || continue
        end
        k_exprs = Dict{String,Expr}(
            contract_names[d] => IntExpr(Int64(k_tuple[d]))
            for d in 1:length(contract_names))
        term = _sub_preserving(sub_body, k_exprs)
        if filt0 !== nothing
            filt = _sub_preserving(_sub_preserving(filt0, idx_exprs), k_exprs)
            term = OpExpr("ifelse", Expr[filt, term, NumExpr(zerobar)])
        end
        push!(terms, _resolve_indices(term, array_var_info, var_map, const_arrays, pgather))
    end
    return _combine_with_reducer(oplus, zerobar, terms)
end

# Resolve index(makearray(regions=[...], values=[...]), k1, k2, ...) by
# selecting the value expression whose region covers (k1, k2, ...).
# Later regions overwrite earlier ones, matching the Python reference
# semantics (_eval_makearray in numpy_interpreter.py:429-457).
function _resolve_index_of_makearray(makearray_expr::OpExpr, idx_args::Vector{Expr},
                                      array_var_info, var_map, const_arrays,
                                      pgather::AbstractDict=_EMPTY_PGATHER)
    regions = makearray_expr.regions === nothing ?
              Vector{Vector{Vector{Int}}}() : makearray_expr.regions
    values  = makearray_expr.values  === nothing ? Expr[] : makearray_expr.values
    length(regions) == length(values) ||
        throw(TreeWalkError("E_TREEWALK_MAKEARRAY_MISMATCH",
              "makearray regions/values length mismatch " *
              "($(length(regions)) vs $(length(values)))"))
    k_vals = [_eval_const_int(a, Dict{String,Int}(), const_arrays) for a in idx_args]
    ndim   = length(k_vals)
    result_expr::Expr = NumExpr(0.0)  # default: 0 if no region covers the point
    for (region, val_expr) in zip(regions, values)
        length(region) == ndim ||
            throw(TreeWalkError("E_TREEWALK_MAKEARRAY_NDIM",
                  "makearray region has $(length(region)) dims but $(ndim) indices"))
        in_region = all(k_vals[d] >= region[d][1] && k_vals[d] <= region[d][2]
                        for d in 1:ndim)
        in_region && (result_expr = val_expr)  # overwrite; last match wins
    end
    return _resolve_indices(result_expr, array_var_info, var_map, const_arrays, pgather)
end

# Expand a scalar arrayop (empty output_idx) to a plain scalar Expr by
# unrolling all contracted indices at build time and combining them with the
# declared reducer. This is the build-time equivalent of an einsum over a
# general expression body — compile once, evaluate cheaply at every RHS call.
function _resolve_scalar_arrayop(arrayop_expr::OpExpr, array_var_info, var_map, const_arrays,
                                 pgather::AbstractDict=_EMPTY_PGATHER)
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
        return _resolve_indices(body, array_var_info, var_map, const_arrays, pgather)
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
        push!(terms, _resolve_indices(term, array_var_info, var_map, const_arrays, pgather))
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
const _EMPTY_CONST_ARRAYS = Dict{String,AbstractArray{Float64}}()

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
const _EMPTY_PGATHER = Dict{String,_PGatherArray}()

function _resolve_indices(expr::NumExpr,
                          array_var_info::Dict{String,Tuple{Vector{Int},Vector{Int}}},
                          var_map::Dict{String,Int},
                          const_arrays::AbstractDict=_EMPTY_CONST_ARRAYS,
                          pgather::AbstractDict=_EMPTY_PGATHER)
    return expr
end
function _resolve_indices(expr::IntExpr,
                          array_var_info::Dict{String,Tuple{Vector{Int},Vector{Int}}},
                          var_map::Dict{String,Int},
                          const_arrays::AbstractDict=_EMPTY_CONST_ARRAYS,
                          pgather::AbstractDict=_EMPTY_PGATHER)
    return expr
end
function _resolve_indices(expr::VarExpr,
                          array_var_info::Dict{String,Tuple{Vector{Int},Vector{Int}}},
                          var_map::Dict{String,Int},
                          const_arrays::AbstractDict=_EMPTY_CONST_ARRAYS,
                          pgather::AbstractDict=_EMPTY_PGATHER)
    return expr
end
function _resolve_indices(expr::OpExpr,
                          array_var_info::Dict{String,Tuple{Vector{Int},Vector{Int}}},
                          var_map::Dict{String,Int},
                          const_arrays::AbstractDict=_EMPTY_CONST_ARRAYS,
                          pgather::AbstractDict=_EMPTY_PGATHER)
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
        # unrolling contracted indices (same strategy as the LHS-arrayop
        # equation path in build_evaluator, ~lines 280-370).
        if first_arg isa OpExpr && _is_aggregate_op(first_arg.op)
            return _resolve_index_of_arrayop(first_arg::OpExpr, expr.args[2:end],
                                             array_var_info, var_map, const_arrays, pgather)
        end
        # Expression-position makearray: index(makearray(...), k1, k2, ...)
        # Select the value whose region covers (k1,...); later regions win.
        if first_arg isa OpExpr && first_arg.op == "makearray"
            return _resolve_index_of_makearray(first_arg::OpExpr, expr.args[2:end],
                                               array_var_info, var_map, const_arrays, pgather)
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
            indices = [_eval_const_int(a, Dict{String,Int}(), const_arrays) for a in idx_args]
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
        # (which emits a `_NK_PARAM_GATHER`). `index` is CSE-opaque, so stashing the
        # `(flat, lin)` pair in `value` is canonicalization-safe.
        if first_arg isa VarExpr && haskey(pgather, first_arg.name)
            pg = pgather[first_arg.name]::_PGatherArray
            idx_args_expr = expr.args[2:end]
            length(idx_args_expr) == length(pg.dims) ||
                throw(TreeWalkError("E_TREEWALK_PGATHER_NDIM",
                      "forcing array '$(first_arg.name)' is $(length(pg.dims))D " *
                      "but got $(length(idx_args_expr)) indices"))
            int_indices = [_eval_const_int(a, Dict{String,Int}(), const_arrays)
                           for a in idx_args_expr]
            for d in 1:length(pg.dims)
                (1 <= int_indices[d] <= pg.dims[d]) ||
                    throw(TreeWalkError("E_TREEWALK_PGATHER_OOB",
                          "forcing array '$(first_arg.name)' index $(int_indices[d]) " *
                          "out of range [1, $(pg.dims[d])] on dim $(d)"))
            end
            lin = LinearIndices(Tuple(pg.dims))[int_indices...]
            return OpExpr("index", Expr[]; value=(pg.flat, lin))
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
            int_indices = [_eval_const_int(a, Dict{String,Int}(), const_arrays)
                           for a in idx_args_expr]
            for d in 1:ndims(vals)
                int_indices[d] = _resolve_const_index(vals, first_arg.name, d, int_indices[d], size(vals, d))
            end
            return NumExpr(Float64(vals[int_indices...]))
        end
        # scalar or unknown variable inside index — recurse on sub-exprs only
        new_args = Expr[_resolve_indices(a, array_var_info, var_map, const_arrays, pgather) for a in expr.args]
        return OpExpr(expr.op, new_args;
                      wrt=expr.wrt, dim=expr.dim, int_var=expr.int_var,
                      lower=expr.lower, upper=expr.upper,
                      output_idx=expr.output_idx, expr_body=expr.expr_body,
                      reduce=expr.reduce, semiring=expr.semiring, ranges=expr.ranges,
                      regions=expr.regions, values=expr.values,
                      shape=expr.shape, perm=expr.perm, axis=expr.axis,
                      fn=expr.fn, name=expr.name, value=expr.value,
                      join=expr.join, filter=expr.filter, join_gates=expr.join_gates,
                      id=expr.id, manifold=expr.manifold)
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
            return _resolve_scalar_arrayop(expr, array_var_info, var_map, const_arrays, pgather)
        end
        # Non-scalar arrayop without index() — pass through (will become a
        # compile-time error in _compile with a helpful message).
    end
    new_args = Expr[_resolve_indices(a, array_var_info, var_map, const_arrays, pgather) for a in expr.args]
    new_body = expr.expr_body === nothing ? nothing :
               _resolve_indices(expr.expr_body, array_var_info, var_map, const_arrays, pgather)
    new_values = expr.values === nothing ? nothing :
                 Expr[_resolve_indices(v, array_var_info, var_map, const_arrays, pgather) for v in expr.values]
    return OpExpr(expr.op, new_args;
                  wrt=expr.wrt, dim=expr.dim, int_var=expr.int_var,
                  lower=expr.lower, upper=expr.upper,
                  output_idx=expr.output_idx, expr_body=new_body,
                  reduce=expr.reduce, semiring=expr.semiring, ranges=expr.ranges,
                  regions=expr.regions, values=new_values,
                  shape=expr.shape, perm=expr.perm, axis=expr.axis,
                  fn=expr.fn, name=expr.name, value=expr.value,
                  join=expr.join, filter=expr.filter, join_gates=expr.join_gates,
                  id=expr.id, manifold=expr.manifold)
end

# Detect which state variables are used in array context (inside index ops)
# by scanning equation LHS patterns and initial_condition keys.
function _detect_array_vars(equations::Vector{Equation},
                             state_var_names::Set{String},
                             initial_conditions::AbstractDict)
    detected = Set{String}()
    # From initial conditions: "u[3]" style keys imply array usage.
    for (key, _) in initial_conditions
        skey = String(key)
        m = match(r"^([^\[]+)\[([0-9,]+)\]$", skey)
        m === nothing && continue
        vname = m.captures[1]
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
        skey = String(key)
        m = match(r"^([^\[]+)\[([0-9,]+)\]$", skey)
        m === nothing && continue
        vname = m.captures[1]
        vname in array_var_names || continue
        indices = parse.(Int, split(m.captures[2], ","))
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
            indices = [_eval_const_int(a, Dict{String,Int}()) for a in idx_args]
            vname = first_arg.name
            if !haskey(cells, vname); cells[vname] = Set{Vector{Int}}(); end
            push!(cells[vname], indices)
        catch; end
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
        catch; end
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
