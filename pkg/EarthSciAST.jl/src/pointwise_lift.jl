# Pointwise spatial lift (esm-spec §10.5): flatten step 3b. Split from
# flatten.jl.

using OrderedCollections: OrderedDict

# ========================================
# Pointwise spatial lift of merged state ODEs (§10.5)
# ========================================
#
# Reaction ODE-gen and coupling both run at the AST level and IN THAT ORDER
# (reactions → generic `D(sp)=Σ terms` equations, then `operator_compose` merges
# each species' reaction ODE with the spatial operator's advection contribution).
# What operator_compose does NOT do is array-ify the result: the merged
# `D(sp) = <reaction> + <-u·makearray(grad(sp))>` still has a SCALAR `sp` while
# its advection `makearray` indexes `sp` per grid cell. This step performs the
# `lifting:"pointwise"` promotion — it reuses the same arrayop lowering a spatial
# MODEL uses — by wrapping each such merged state ODE in an `aggregate` over the
# grid, indexing the bare reaction species per cell and each operator makearray
# per cell, and giving the species a grid shape. The reaction network then runs
# pointwise on the grid through the existing arrayop evaluator.

# Collect every `makearray` OpExpr node reachable from `expr`.
function _collect_makearrays!(acc::Vector{OpExpr}, expr::ASTExpr)
    expr isa OpExpr || return acc
    expr.op == "makearray" && push!(acc, expr)
    # Walk every immediate sub-expression via the shared traversal instead of a
    # hand-listed {args, expr_body, values} field walk. `child_exprs` is a strict
    # superset (it also visits `lower`/`upper`/`filter`/`key`/`table_axes`/dense
    # `ranges` bounds), but a `makearray` — a materialized spatial array — never
    # lives inside those scalar-valued fields, so both the set of collected nodes
    # and their depth-first order (`args`, then `expr_body`, then `values`) are
    # unchanged.
    for c in child_exprs(expr)
        _collect_makearrays!(acc, c)
    end
    return acc
end

# First VarExpr leaf name in an index-argument expression (the loop variable of
# that index position), or `nothing` for a constant position.
function _index_arg_loop(expr::ASTExpr)::Union{String,Nothing}
    if expr isa VarExpr
        return expr.name
    elseif expr isa OpExpr
        for a in expr.args
            v = _index_arg_loop(a)
            v === nothing || return v
        end
    end
    return nothing
end

# Determine the ordered spatial loop variables of a lowered spatial operator by
# reading an `index(<lifted species>, a1, …, aRank)` gather inside `ma` whose
# every position carries a loop variable (the interior stencil). Returns the loop
# names in index-position (dim) order, or `nothing` if none is found.
function _detect_lift_loops(ma::OpExpr, lifted::Set{String}, rank::Int)
    result = Ref{Union{Vector{String},Nothing}}(nothing)
    function walk(e)
        result[] === nothing || return
        e isa OpExpr || return
        if e.op == "index" && !isempty(e.args) && e.args[1] isa VarExpr &&
           ((e.args[1]::VarExpr).name in lifted) && length(e.args) - 1 == rank
            loops = String[]
            ok = true
            for k in 2:length(e.args)
                lv = _index_arg_loop(e.args[k])
                lv === nothing && (ok = false; break)
                push!(loops, lv)
            end
            ok && (result[] = loops; return)
        end
        # NOTE: this walk deliberately covers only {args, expr_body, values} —
        # NOT the full `child_exprs` field set (which also visits
        # lower/upper/filter/key/table_axes/dense-ranges bounds). The
        # interior-stencil gather this searches for lives in a makearray's
        # `values` (or a body nested under them); widening the walk into the
        # scalar-valued fields could match a gather inside a filter/bound and
        # CHANGE which loop names are detected, so the restricted subset is
        # behavior-pinned.
        for a in e.args
            walk(a)
        end
        e.expr_body === nothing || walk(e.expr_body)
        if e.values !== nothing
            for v in e.values
                walk(v)
            end
        end
    end
    walk(ma)
    return result[]
end

# Per-dimension grid extent of a lowered spatial operator: the largest cell index
# addressed in each `regions` dimension (the regions partition the grid).
function _makearray_extents(ma::OpExpr)::Vector{Int}
    regions = ma.regions
    (regions === nothing || isempty(regions)) && return Int[]
    rank = length(regions[1])
    ext = zeros(Int, rank)
    for region in regions
        length(region) == rank || continue
        for d in 1:rank
            ext[d] = max(ext[d], region[d][2])
        end
    end
    return ext
end

# Rewrite a scalar (merged reaction + operator) RHS into its per-cell form over
# the spatial `loops`: a bare reference to an array variable becomes
# `index(var, loops…)`, and each spatial-operator `makearray` becomes
# `index(makearray, loops…)` (its region values already index per cell).
# Self-contained nodes (index / aggregate / arrayop) are left untouched;
# elementwise ops recurse. Expressed via the shared `_wrap_bare_array_refs`
# rewrite (shape_promotion.jl); its typed twin with a different wrap/stop set
# is `_index_array_leaves`. The stop set here deliberately omits `makearray` —
# the wrap predicate claims every makearray first.
function _lift_rhs_to_cell(expr::ASTExpr, arrayvars::Set{String},
                           loops::Vector{String})::ASTExpr
    return _wrap_bare_array_refs(expr, arrayvars, loops;
        wrap_node = e -> e.op == "makearray",
        stop_node = e -> e.op == "index" || e.op == "aggregate" ||
                         e.op == "arrayop")
end

"""
    _apply_pointwise_lift!(equations, states, params, observeds, index_sets, coupling)

Pointwise spatial lift (§10.5) for `operator_compose` couplings that declare
`lifting: "pointwise"`. Promotes every state ODE that `operator_compose` merged
with a spatial operator (its merged RHS carries an operator `makearray`) from a
0-D scalar to the operator's grid shape, and rewrites the equation into an
`aggregate` over the grid. No-op when no coupling requests pointwise lifting, or
no merged equation carries a spatial-operator makearray.
"""
function _apply_pointwise_lift!(equations::Vector{Equation},
                                states::OrderedDict{String,ModelVariable},
                                params::OrderedDict{String,ModelVariable},
                                observeds::OrderedDict{String,ModelVariable},
                                index_sets::OrderedDict{String,IndexSet},
                                coupling)
    any(c -> c isa CouplingOperatorCompose &&
             (c.lifting !== nothing && c.lifting == "pointwise"), coupling) || return

    lifted = _pointwise_lifted_species(equations, states)
    isempty(lifted) && return
    arrayvars = _pointwise_lift_operands(lifted, states, params, observeds)
    size_to_names = _index_sets_by_size(index_sets)

    for (n, eq) in enumerate(equations)
        species = differential_lhs_variable(eq.lhs)
        species === nothing && continue
        species in lifted || continue

        mas = _collect_makearrays!(OpExpr[], eq.rhs)
        (isempty(mas) || mas[1].regions === nothing || isempty(mas[1].regions)) && continue
        rank = length(mas[1].regions[1])
        loops = _pointwise_lift_loops(mas, lifted, rank, species)
        gaxes, ranges = _pointwise_lift_axes(mas[1], loops, size_to_names,
                                             species, rank)

        # Promote the species to the grid shape so the scoped-ic fold, array-cell
        # discovery, and evaluator all see an array state.
        haskey(states, species) && (states[species] = _with_shape(states[species], gaxes))
        equations[n] = _pointwise_lift_equation(eq, species, arrayvars, loops,
                                                ranges)
    end
    return
end

# A species is lifted iff its state ODE's merged RHS carries a spatial-operator
# makearray (the advection contribution operator_compose added) AND the state is
# still SCALAR.
#
# The shape test is what keeps a mixed document working. Pointwise lifting is
# defined (§10.5) as the 0-D ↔ spatial promotion, so a state the author already
# gave a grid shape is already spatial and must be left alone: its equation is
# ALREADY an aggregate over the grid, and lifting it again would wrap a second
# aggregate around it.
#
# Without the test, any already-spatial state sharing a document with a lifted
# reaction network is swept in merely because its own RHS carries a makearray —
# a prognostic air-mass `D(m,t) = -(D(Mx,lon) + D(My,lat) + D(Mz,lev))` beside a
# lifted chemistry mechanism is the motivating case. That one cannot be lifted
# even in principle: `_pointwise_lift_loops` recovers a species' loop variables by
# finding it INSIDE its own makearray, and `m` never appears inside a flux
# divergence over `Mx` — so it failed with "could not determine the spatial loop
# variables", which read as a defect in the author's model rather than as a state
# that simply needed no lifting.
function _pointwise_lifted_species(equations::Vector{Equation},
                                   states::OrderedDict{String,ModelVariable})::Set{String}
    lifted = Set{String}()
    for eq in equations
        species = differential_lhs_variable(eq.lhs)
        species === nothing && continue
        isempty(_collect_makearrays!(OpExpr[], eq.rhs)) && continue
        # Already carries a grid shape ⇒ already spatial ⇒ nothing to lift.
        if haskey(states, species)
            sh = states[species].shape
            (sh !== nothing && !isempty(sh)) && continue
        end
        push!(lifted, species)
    end
    return lifted
end

# Operands to index per cell: the lifted species plus any already array-shaped
# parameter/observed (e.g. a grid-shaped wind field bound from a loader).
function _pointwise_lift_operands(lifted::Set{String},
                                  states::OrderedDict{String,ModelVariable},
                                  params::OrderedDict{String,ModelVariable},
                                  observeds::OrderedDict{String,ModelVariable})::Set{String}
    arrayvars = Set{String}(lifted)
    for d in (params, observeds, states)
        for (k, v) in d
            (v.shape !== nothing && !isempty(v.shape)) && push!(arrayvars, k)
        end
    end
    return arrayvars
end

# Grid axis for a makearray dimension is the declared index set whose size
# matches that dimension's extent (the `index_sets` map is unordered, so this
# matches by size rather than key order).
function _index_sets_by_size(index_sets::OrderedDict{String,IndexSet})::Dict{Int,Vector{String}}
    size_to_names = Dict{Int,Vector{String}}()
    for (name, iset) in index_sets
        iset.size === nothing && continue
        push!(get!(size_to_names, iset.size, String[]), name)
    end
    return size_to_names
end

# The ordered spatial loop variables read off the species' operator makearrays,
# or throw `DimensionPromotionError` when no makearray carries a full-rank
# interior-stencil gather.
function _pointwise_lift_loops(mas::Vector{OpExpr}, lifted::Set{String},
                               rank::Int, species::String)::Vector{String}
    for ma in mas
        loops = _detect_lift_loops(ma, lifted, rank)
        loops === nothing || return loops
    end
    throw(DimensionPromotionError(
        "pointwise lift: could not determine the spatial loop variables for " *
        "species '$(species)' from its operator makearray"))
end

# Map each grid dimension to a declared index set by matching extents,
# producing the species' new shape axes (`gaxes`) and the aggregate loop
# `ranges`.
function _pointwise_lift_axes(ma::OpExpr, loops::Vector{String},
                              size_to_names::Dict{Int,Vector{String}},
                              species::String, rank::Int)
    extents = _makearray_extents(ma)
    gaxes = String[]
    ranges = Dict{String,Any}()
    for d in 1:rank
        cands = get(size_to_names, extents[d], String[])
        if length(cands) == 1
            push!(gaxes, cands[1])
            ranges[loops[d]] = IndexSetRef(cands[1])
        else
            # No unique index set of this size — fall back to a dense range and
            # a synthetic shape axis (still a valid non-scalar shape).
            if length(cands) > 1
                @warn "pointwise lift: grid dimension $(d) of species " *
                      "'$(species)' (extent $(extents[d])) matches multiple " *
                      "declared index sets $(sort(cands)) by size; the lift " *
                      "cannot pick one, so a synthetic dense axis " *
                      "'_liftdim$(d)_$(extents[d])' is used instead of an " *
                      "index-set reference."
            end
            # Synthetic-axis naming convention: `_liftdim<dim>_<extent>` — an
            # underscore-prefixed name that cannot collide with a declared
            # index set and stays self-describing in the promoted shape.
            axname = "_liftdim$(d)_$(extents[d])"
            push!(gaxes, axname)
            ranges[loops[d]] = Any[1, extents[d]]
        end
    end
    return gaxes, ranges
end

# Rewrite the merged scalar state ODE into per-cell `aggregate`s over the grid:
# LHS `D(sp,t)` → `aggregate(D(index(sp, loops…), t))`, RHS per-cell via
# `_lift_rhs_to_cell`.
function _pointwise_lift_equation(eq::Equation, species::String,
                                  arrayvars::Set{String},
                                  loops::Vector{String},
                                  ranges::Dict{String,Any})::Equation
    oidx = Any[l for l in loops]
    idx_species = OpExpr("index", ASTExpr[VarExpr(species),
                         (VarExpr(l) for l in loops)...])
    new_lhs = OpExpr("aggregate", ASTExpr[];
                     output_idx=oidx, ranges=ranges,
                     expr_body=OpExpr("D", ASTExpr[idx_species], wrt="t"))
    new_rhs = OpExpr("aggregate", ASTExpr[];
                     output_idx=oidx, ranges=ranges,
                     expr_body=_lift_rhs_to_cell(eq.rhs, arrayvars, loops))
    return Equation(new_lhs, new_rhs; _comment=eq._comment)
end
