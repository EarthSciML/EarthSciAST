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
# `D(sp) = <reaction> + <-u·makearray(D(sp, x))>` still has a SCALAR `sp` while
# its advection `makearray` indexes `sp` per grid cell. This step performs the
# `lifting:"pointwise"` promotion — it reuses the same faq lowering a spatial
# MODEL uses — by wrapping each such merged state ODE in a `faq` over the
# grid, indexing the bare reaction species per cell and each operator makearray
# per cell, and giving the species a grid shape. The reaction network then runs
# pointwise on the grid through the existing faq evaluator.

# Collect every `makearray` OpExpr node reachable from `expr`.
function _collect_makearrays!(acc::Vector{OpExpr}, expr::ASTExpr)
    expr isa OpExpr || return acc
    expr.op == "makearray" && push!(acc, expr)
    # Walk every immediate sub-expression via the shared traversal instead of a
    # hand-listed {args, expr_body, values} field walk. `child_exprs` is a strict
    # superset (it also visits `lower`/`upper`/`filter`/`key`/dense
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
function _index_arg_loop(expr::ASTExpr)::Union{String, Nothing}
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

# The expansion of the template reference `e` against `reg`, for analysis only:
# the equation tree keeps the reference. Each reference is expanded once
# (`peek`, `memo`); `nothing` with no registry, or when the expansion fails for
# a reason other than resources (an unknown template, bad bindings), which the
# build reports with its own diagnostic.
function _peek_expansion(peek::IdDict{OpExpr, Any}, e::OpExpr, reg, memo::_ExpandCache)
    reg === nothing && return nothing
    return get!(peek, e) do
        try
            _expand_expr_refs(e, reg, nothing, memo)
        catch err
            _is_resource_error(err) && rethrow()
            nothing
        end
    end
end

# Determine the ordered spatial loop variables of a lowered spatial operator by
# reading an `index(<lifted species>, a1, …, aRank)` gather inside `ma` whose
# every position carries a loop variable (the interior stencil). Returns the loop
# names in index-position (dim) order, or `nothing` if none is found.
#
# `reg` (the merged flat template registry, esm-spec §9.6.4 Option B) makes the
# search see THROUGH surviving `apply_expression_template` region values: the
# interior gather lives inside the referenced template body, so the walk peeks
# at the body's expansion — ANALYSIS ONLY, the equation tree is never rewritten,
# and the compile-once build still receives the reference-preserving form.
function _detect_lift_loops(
        ma::OpExpr, lifted::Set{String}, rank::Int,
        reg = nothing
    )
    result = Ref{Union{Vector{String}, Nothing}}(nothing)
    peek = IdDict{OpExpr, Any}()
    # Expansions share their subtrees, so each reference is expanded through
    # one memo and each node is walked once: a second visit finds nothing the
    # first did not.
    memo = _ExpandCache()
    seen = IdDict{OpExpr, Nothing}()
    function walk(e)
        result[] === nothing || return
        e isa OpExpr || return
        haskey(seen, e) && return
        seen[e] = nothing
        if e.op == APPLY_EXPRESSION_TEMPLATE_OP
            body = _peek_expansion(peek, e, reg, memo)
            body === nothing || walk(body)
            return
        end
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
        # lower/upper/filter/key/dense-ranges bounds). The
        # interior-stencil gather this searches for lives in a makearray's
        # `values` (or a body nested under them); widening the walk into the
        # scalar-valued fields could match a gather inside a filter/bound and
        # CHANGE which loop names are detected, so the restricted subset is
        # behavior-pinned.
        for a in e.args
            walk(a)
        end
        e.expr_body === nothing || walk(e.expr_body)
        return if e.values !== nothing
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

# The ops that restructure a WHOLE array (esm-spec §4.3.5). Inside a lifted
# right-hand side there is no per-cell reading of their operands, so an array
# operand beneath one is refused rather than gathered per cell.
const _LIFT_WHOLE_ARRAY_OPS = Tuple(sort!(collect(_ops_with(:shape_remap))))

# Rewrite a scalar (merged reaction + operator) right-hand side into its
# per-cell form on the lift grid: the loops `loops` run over the index sets
# `align.axes`. Each spatial-operator `makearray` is tagged with the loop
# symbols (as every binding does) and read per cell, `index(makearray, loops…)`;
# `index` and `faq` nodes carry their own indexing and are kept.
#
# A bare reference to an array operand is read per cell: a lifted state, or a
# variable with no declared shape, positionally; a variable with a declared
# shape by index-set NAME (esm-spec §4.3.4, `_lift_gather_shaped`), so a
# `[lev]` profile in a `[lon, lat, lev]` lift is `index(p, k)` and a
# `[lev, lat, lon]` field is `index(m, k, j, i)`.
#
# Where the variable sits decides what happens when it shares NO index set with
# the grid. Under an element-wise operator (`_is_elementwise_node`) it must be
# read per cell, so that is an error. As an argument of any other op (a closed
# `fn`, say, whose lookup table is a shaped parameter) it is consumed whole
# under that op's contract and stays bare. The whole-array shape ops
# (`reshape`, `transpose`, `concat`) have no per-cell reading at all, so any
# array operand beneath one is an error.
#
# A template application counts as its expansion (esm-spec §9.6.4 rule 4): with
# a template context `ctx`, it is replaced by its expansion read at the cell
# the way the elementwise lift reads one (`_ew_at_cell`, esm-spec §9.6.11), so
# an array bound to a parameter the body reads per value is gathered, not left
# bare inside the lifted `faq`.
function _lift_rhs_to_cell(
        expr::ASTExpr, arrayvars::Set{String}, loops::Vector{String},
        align::_AxisAlign, species::String, ctx::Union{Nothing, _ElementwiseContext} = nothing
    )::ASTExpr
    foreign(v, shape, axes, s) = throw(
        DimensionPromotionError(
            "pointwise lift: '$(v.name)' (shape $(shape)) cannot be read per cell on " *
                "the grid $(axes) that species '$(species)' is lifted to: the grid is " *
                "not shaped over index set '$(s)' (esm-spec §4.3.4)"
        )
    )
    function leaf(v::VarExpr, elementwise::Bool)
        v.name in arrayvars || return v
        shape = get(align.var_shapes, v.name, nothing)
        shape === nothing && return _index_wrap(v, loops)
        return _lift_gather_shaped(v, shape, loops, align.axes, species, elementwise)
    end
    function node(e::OpExpr)
        if ctx !== nothing && e.op == APPLY_EXPRESSION_TEMPLATE_OP
            return _ew_at_cell(e, align.var_shapes, ctx, loops, align, foreign)
        elseif e.op == "makearray"
            return _index_wrap(reconstruct(e; output_idx = Any[loops...]), loops)
        elseif e.op == "index" || e.op == "faq"
            return e
        elseif e.op in _LIFT_WHOLE_ARRAY_OPS
            name = _first_array_operand(e, arrayvars)
            name === nothing || throw(
                DimensionPromotionError(
                    "pointwise lift: '$(name)' is an operand of '$(e.op)' in the " *
                        "right-hand side of species '$(species)'; '$(e.op)' " *
                        "consumes a whole array, so it has no per-cell reading on the " *
                        "lifted grid"
                )
            )
            return e
        end
        return nothing
    end
    return _read_at_cell(leaf, node, expr)
end

# The first bare variable reference beneath `expr` (through `args`) that names
# an array operand, or `nothing`.
function _first_array_operand(expr::ASTExpr, arrayvars::Set{String})::Union{String, Nothing}
    expr isa VarExpr && return expr.name in arrayvars ? expr.name : nothing
    expr isa OpExpr || return nothing
    for a in expr.args
        n = _first_array_operand(a, arrayvars)
        n === nothing || return n
    end
    return nothing
end

# The shaped variable `v` read at the current cell of the lift grid, by
# index-set name (`_gather_by_name`, esm-spec §4.3.4): a SUBSET of the grid's
# index sets replicates along the others and a permuted shape transposes.
#
# Refused, because no per-cell read would be right:
# * an index set the grid is not shaped over, alongside ones it is (a
#   staggered `[lon, lat, lev_edge]` field), or in element-wise position at all;
# * a shape that repeats an index set, or a grid that does, where the
#   variable's shape is not the grid's own: there is then no single loop for
#   the repeated name.
#
# A variable sharing no index set with the grid, outside element-wise position,
# stays bare: it is a whole-array argument of the enclosing op.
function _lift_gather_shaped(
        v::VarExpr, shape::Vector{String}, loops::Vector{String},
        axes::Vector{String}, species::String, elementwise::Bool
    )::ASTExpr
    r = _gather_by_name(v, shape, axes, loops)
    r isa OpExpr && return r
    why, s = r
    (why == :foreign && !elementwise && !any(in(axes), shape)) && return v
    reason = why == :foreign ? "the grid is not shaped over index set '$(s)'" :
        why == :repeated ? "index set '$(s)' appears twice in its shape" :
        "the grid runs over index set '$(s)' on more than one axis"
    throw(
        DimensionPromotionError(
            "pointwise lift: '$(v.name)' (shape $(shape)) cannot be read per cell on " *
                "the grid $(axes) that species '$(species)' is lifted to: " *
                "$(reason) (esm-spec §4.3.4)"
        )
    )
end

# A variable with no `shape`, or `shape: []`, is scalar (esm-spec §6.3).
_lift_is_scalar(v::ModelVariable)::Bool = v.shape === nothing || isempty(v.shape)

# The lift's shape inference (esm-libraries-spec §4.7.5, "Pointwise lift: which
# states are lifted") is `_expr_axes` (expr_axes.jl) over every declared
# variable, the bare definitions, the states already lifted at their grids, and
# `masked` names read as scalars: the sources of the non-pointwise
# `variable_map` entries into the component being decided.
function _lift_shape_env(variables, defs, lifted, masked, iv)
    known = Dict{String, Vector{String}}()
    for (k, v) in variables
        v.shape === nothing || (known[k] = String[string(x) for x in v.shape])
    end
    merge!(known, lifted)
    return _ShapeEnv(known; defs = defs, scalar = masked, names = Set{String}(keys(variables)), iv = iv)
end

# How one lifted state's equation is rewritten: the index set of each grid
# dimension, their sizes, and, for a state the operator route lifts, the loop
# symbols and ranges read off its `makearray` (`nothing`: fresh loops).
struct _LiftPlan
    axes::Vector{String}
    extents::Vector{Int}
    loops::Union{Vector{String}, Nothing}
    ranges::Union{Dict{String, Any}, Nothing}
end

"""
    _apply_pointwise_lift!(pool, states, params, observeds, index_sets, coupling; iv,
                           template_registry, lifted_shapes)

Pointwise spatial lift (esm-spec §10.5; esm-libraries-spec §4.7.5, "Pointwise
lift: which states are lifted").

A scalar state is a lift candidate when its merged equation carries an operator
`makearray` (the operator route) or its right-hand side is an array under the
lift's shape inference ([`_expr_axes`](@ref)). A candidate lifts its whole
top-level component: every scalar state of that model or reaction system goes
onto the same grid. Lifting can make further right-hand sides arrays, so the
search repeats until no new component is lifted. Each lifted equation is
rewritten into a `faq` over the grid, its array operands read per cell.

A component two candidates put on different grids is refused with
`DimensionPromotionError`. Coupling entries with an explicit `lifting` other
than `"pointwise"` do not trigger the lift: an `operator_compose` one takes its
components out of the operator route, and a `variable_map` one reads its source
as a scalar when deciding the target's component.

Returns `nothing` when it lifts nothing; otherwise the array shapes it read
operands by (`_flat_array_shapes`) and the states it gave a grid shape, for
flatten's elementwise step to reuse.
"""
function _apply_pointwise_lift!(
        pool::Vector{_FlatEq},
        states::OrderedDict{String, ModelVariable},
        params::OrderedDict{String, ModelVariable},
        observeds::OrderedDict{String, ModelVariable},
        index_sets::OrderedDict{String, IndexSet},
        coupling;
        template_registry = nothing,
        lifted_shapes = nothing,
        iv::AbstractString = "t"
    )
    no_operator_route = Set{String}()
    masks = Dict{String, Set{String}}()
    for c in coupling
        lifting = hasproperty(c, :lifting) ? c.lifting : nothing
        (lifting === nothing || lifting == "pointwise") && continue
        if c isa CouplingOperatorCompose
            union!(no_operator_route, (_component_root(s) for s in c.systems))
        elseif c isa CouplingVariableMap && !isempty(c.to) && !isempty(c.from)
            push!(get!(masks, _component_root(c.to), Set{String}()), c.from)
        end
    end

    is_lift_state(name) = haskey(states, name) && _lift_is_scalar(states[name])
    equations = _pool_equations(pool)
    defs = _bare_definitions(equations)
    lift_states = String[
        n for n in keys(states)
            if !haskey(defs, n) && !haskey(observeds, n) && is_lift_state(n)
    ]
    variables = Dict{String, ModelVariable}()
    for d in (params, observeds, states), (k, v) in d
        variables[k] = v
    end
    tendencies = Tuple{String, Int}[]
    for (n, eq) in enumerate(equations)
        t = differential_lhs_variable(eq.lhs)
        (t !== nothing && is_lift_state(t)) && push!(tendencies, (t, n))
    end

    # The registry as the document declares it, before the lift adds any
    # `_liftdim<d>_<extent>` set: only a declared set names a lift dimension.
    declared = OrderedDict{String, IndexSet}(index_sets)
    size_to_names = _index_sets_by_size(declared)
    var_shapes = _declared_shapes(states, params, observeds)

    # The operator route: a scalar state whose merged equation carries an
    # operator makearray. Its grid and loops are read off the makearray.
    operator_route = _pointwise_lifted_species(
        equations, states; exclude_components = no_operator_route
    )
    plans = Dict{String, _LiftPlan}()
    for (target, n) in tendencies
        (target in operator_route && !haskey(plans, target)) || continue
        mas = _collect_makearrays!(OpExpr[], equations[n].rhs)
        (isempty(mas) || mas[1].regions === nothing || isempty(mas[1].regions)) && continue
        rank = length(mas[1].regions[1])
        loops = _pointwise_lift_loops(mas, operator_route, rank, target, template_registry)
        gaxes, ranges = _pointwise_lift_axes(
            mas[1], loops, size_to_names,
            target, rank;
            mas = mas, var_shapes = var_shapes,
            index_sets = declared,
            reg = template_registry,
            registry = index_sets
        )
        plans[target] = _LiftPlan(gaxes, _makearray_extents(mas[1]), loops, ranges)
    end

    function axis_size(axis::String, state::String)::Int
        iset = get(index_sets, axis, nothing)
        (iset !== nothing && iset.size isa Integer) || throw(
            DimensionPromotionError(
                "pointwise lift: state '$(state)' would be lifted onto index set " *
                    "'$(axis)', which has no declared size"
            )
        )
        return iset.size
    end

    function two_grids(comp, first_state, grid, other, axes)
        Set(axes) == Set(grid) && return nothing
        throw(
            DimensionPromotionError(
                "pointwise lift: component '$(comp)' would be lifted onto two " *
                    "grids: state '$(first_state)' onto $(grid) and state " *
                    "'$(other)' onto $(axes)"
            )
        )
    end

    # Operator-route plans, as opposed to the component grid a later pass gives.
    operator_plans = Set(keys(plans))
    lifted_axes = Dict{String, Vector{String}}()
    lifted_components = Set{String}()

    # Every candidate of every component `wanted` accepts, in equation order,
    # each read with the component's own states scalar and every other lifted
    # state at its lift index sets.
    function candidates_of(wanted)
        inference = Dict{String, _ShapeEnv{Nothing}}()
        found = OrderedDict{String, Vector{Tuple{String, Vector{String}}}}()
        for (target, n) in tendencies
            comp = _component_root(target)
            wanted(comp) || continue
            if target in operator_plans
                push!(get!(found, comp, Tuple{String, Vector{String}}[]), (target, plans[target].axes))
                continue
            end
            shapes = get!(inference, comp) do
                others = Dict{String, Vector{String}}(
                    s => a for (s, a) in lifted_axes if _component_root(s) != comp
                )
                _lift_shape_env(variables, defs, others, get(masks, comp, Set{String}()), iv)
            end
            axes = _expr_axes(shapes, equations[n].rhs)
            (axes === nothing || isempty(axes)) && continue
            push!(get!(found, comp, Tuple{String, Vector{String}}[]), (target, axes))
        end
        return found
    end

    # Whole-component lift, to a fixpoint.
    # The candidate that gave each lifted component its grid.
    grids = Dict{String, Tuple{String, Vector{String}}}()
    while true
        found = candidates_of(comp -> !(comp in lifted_components))
        isempty(found) && break
        for (comp, candidates) in found
            first_state, grid = candidates[1]
            for (other, axes) in candidates[2:end]
                two_grids(comp, first_state, grid, other, axes)
            end
            allunique(grid) || throw(
                DimensionPromotionError(
                    "pointwise lift: state '$(first_state)' would be lifted onto " *
                        "$(grid), which names one index set twice"
                )
            )
            for state in lift_states
                _component_root(state) == comp || continue
                haskey(plans, state) || (
                    plans[state] = _LiftPlan(
                        copy(grid), Int[axis_size(a, state) for a in grid], nothing, nothing
                    )
                )
                lifted_axes[state] = plans[state].axes
            end
            push!(lifted_components, comp)
            grids[comp] = (first_state, grid)
        end
    end
    isempty(lifted_axes) && return

    # A state can become a candidate only after its component was lifted, when
    # a later pass lifts a component it reads. Search the lifted components'
    # candidates once more with every lift final, so the answer does not depend
    # on which pass lifted what.
    for (comp, candidates) in candidates_of(comp -> comp in lifted_components)
        first_state, grid = grids[comp]
        for (other, axes) in candidates
            two_grids(comp, first_state, grid, other, axes)
        end
    end

    # The lifted states live on the lift's index sets: each `shape` names them
    # and `lifted_shapes` records their sizes (esm-libraries-spec §4.7.5).
    promoted = Set{String}()
    for state in lift_states
        haskey(lifted_axes, state) || continue
        plan = plans[state]
        states[state] = _with_shape(states[state], plan.axes)
        lifted_shapes === nothing || (lifted_shapes[state] = copy(plan.extents))
        push!(promoted, state)
    end

    # The operands read per cell are every ARRAY on the lifted system, the
    # lifted states included, not only those that declare a shape: a variable
    # declared without one whose definition is elementwise over arrays is an
    # array too (esm-spec §4.3.4), as the build sees it. A 0-D component's
    # coefficient `k = v * rho / dp`, fed grid fields by `variable_map`, is one.
    # Left bare inside the lifted `faq`, the build refuses it
    # (`faq_bare_array_operand`, esm-spec §4.3.1): the lift, not the author, put
    # it there (esm-libraries-spec §4.7.5, "Pointwise lift: operands read per
    # cell"). Read after the states above have their shapes, so a definition
    # reading a lifted state is an array too.
    read_shapes = _flat_array_shapes(
        states, params, observeds, equations,
        _ElementwiseContext(template_registry === nothing || isempty(template_registry) ? nothing : template_registry)
    )
    arrayvars = union!(_pointwise_lift_operands(promoted, states, params, observeds), keys(read_shapes))
    ctx = template_registry === nothing || isempty(template_registry) ? nothing :
        _ElementwiseContext(template_registry)

    for (n, eq) in enumerate(equations)
        target = differential_lhs_variable(eq.lhs)
        (target !== nothing && haskey(lifted_axes, target)) || continue
        plan = plans[target]
        loops, ranges = if plan.loops === nothing
            fresh = _fresh_loops((eq.lhs, eq.rhs), length(plan.axes); ctx = ctx)
            fresh, _cell_ranges(fresh, plan.axes)
        else
            plan.loops, plan.ranges
        end
        pool[n] = _pointwise_lift_equation(
            pool[n], arrayvars, target, loops,
            _AxisAlign(plan.axes, read_shapes), ranges, ctx
        )
    end
    return (shapes = read_shapes, stale = promoted)
end

# The operator route's states: a scalar state whose merged equation carries a
# spatial-operator makearray (the advection contribution operator_compose
# added), outside the components in `exclude_components` (those a
# non-pointwise `operator_compose` names).
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
# divergence over `Mx`.
function _pointwise_lifted_species(
        equations::Vector{Equation},
        states::OrderedDict{String, ModelVariable};
        exclude_components = ()
    )::Set{String}
    lifted = Set{String}()
    for eq in equations
        species = differential_lhs_variable(eq.lhs)
        species === nothing && continue
        (haskey(states, species) && _lift_is_scalar(states[species])) || continue
        _component_root(species) in exclude_components && continue
        isempty(_collect_makearrays!(OpExpr[], eq.rhs)) && continue
        push!(lifted, species)
    end
    return lifted
end

# Operands to index per cell: the lifted states plus every state, parameter and
# observed with a declared non-empty shape (e.g. a grid-shaped wind field bound
# from a loader, or a `[lev]` profile). A declared-shape operand is gathered by
# index-set NAME (`_lift_gather_shaped`).
function _pointwise_lift_operands(
        lifted::Set{String},
        states::OrderedDict{String, ModelVariable},
        params::OrderedDict{String, ModelVariable},
        observeds::OrderedDict{String, ModelVariable}
    )::Set{String}
    arrayvars = Set{String}(lifted)
    for d in (params, observeds, states)
        for (k, v) in d
            (v.shape !== nothing && !isempty(v.shape)) && push!(arrayvars, k)
        end
    end
    return arrayvars
end

# The declared index sets of each size, for matching a makearray dimension to
# the index set of its extent.
function _index_sets_by_size(index_sets::OrderedDict{String, IndexSet})::Dict{Int, Vector{String}}
    size_to_names = Dict{Int, Vector{String}}()
    for (name, iset) in index_sets
        iset.size === nothing && continue
        push!(get!(size_to_names, iset.size, String[]), name)
    end
    return size_to_names
end

# The ordered spatial loop variables read off the species' operator makearrays,
# or throw `DimensionPromotionError` when no makearray carries a full-rank
# interior-stencil gather.
function _pointwise_lift_loops(
        mas::Vector{OpExpr}, lifted::Set{String},
        rank::Int, species::String,
        reg = nothing
    )::Vector{String}
    for ma in mas
        loops = _detect_lift_loops(ma, lifted, rank, reg)
        loops === nothing || return loops
    end
    throw(
        DimensionPromotionError(
            "pointwise lift: could not determine the spatial loop variables for " *
                "species '$(species)' from its operator makearray"
        )
    )
end

# Every declared array shape in one lookup: for the axis-NAME propagation below,
# and for gathering each declared-shape operand per cell by name
# (`_lift_gather_shaped`).
function _declared_shapes(ds::OrderedDict{String, ModelVariable}...)::Dict{String, Vector{String}}
    out = Dict{String, Vector{String}}()
    for d in ds, (k, v) in d
        sh = v.shape
        (sh === nothing || isempty(sh)) && continue
        out[k] = collect(sh)
    end
    return out
end

# PROPAGATE the axis names, rather than recovering them from the extent.
#
# Every operand gathered inside a spatial operator's makearray is indexed at the
# lift's own loop variables, and a DECLARED-shape operand names the index set at
# each of its positions. So `index(dp, i, j, k)` with `dp :: [lon, lat, lev]`
# says directly that loop `i` runs over `lon` — no size table needed. Returns one
# name per dimension, or `nothing` where the evidence is absent or conflicting.
#
# EXTENT AGREEMENT is what makes this sound, and it is not a mere sanity check:
# a flux-form stencil gathers STAGGERED face arrays over the very same loops
# (`Mx :: [lon_nodes, lat, lev]` is read at `i` too), and those name the wrong,
# one-longer axis. Requiring the candidate index set's size to equal the
# dimension's cell extent rejects exactly the staggered operands and keeps the
# cell-centred ones. It also makes this pass a STRICT REFINEMENT of the size
# match it precedes: when only one declared index set has the dimension's size,
# any extent-agreeing name IS that index set, so it decides only the dimensions
# the size match leaves ambiguous.
#
# Walks THROUGH surviving `apply_expression_template` references (analysis only,
# exactly as `_detect_lift_loops` does): with a monotone rule stack the interior
# gathers live inside the referenced template bodies, not the equation tree.
function _lift_axis_names(
        mas::Vector{OpExpr}, loops::Vector{String},
        extents::Vector{Int},
        var_shapes::Dict{String, Vector{String}},
        index_sets::OrderedDict{String, IndexSet},
        reg
    )::Vector{Union{String, Nothing}}
    rank = length(loops)
    evidence = [Set{String}() for _ in 1:rank]
    dim_of = Dict{String, Int}()
    for (d, l) in enumerate(loops)
        # A repeated loop name (a diagonal gather) would make the position
        # ambiguous; drop it rather than guess.
        haskey(dim_of, l) ? (dim_of[l] = 0) : (dim_of[l] = d)
    end
    peek = IdDict{OpExpr, Any}()
    seen = IdDict{OpExpr, Bool}()
    # One memo for every reference, so a template referenced at several depths
    # is expanded once (and its expansion's shared subtrees walked once).
    memo = _ExpandCache()
    function walk(e)
        e isa OpExpr || return
        get!(seen, e, false) && return
        seen[e] = true
        if e.op == APPLY_EXPRESSION_TEMPLATE_OP
            body = _peek_expansion(peek, e, reg, memo)
            body === nothing || walk(body)
            return
        end
        if e.op == "index" && !isempty(e.args) && e.args[1] isa VarExpr
            sh = get(var_shapes, (e.args[1]::VarExpr).name, nothing)
            if sh !== nothing && length(sh) == length(e.args) - 1
                for p in eachindex(sh)
                    lv = _index_arg_loop(e.args[p + 1])
                    lv === nothing && continue
                    d = get(dim_of, lv, 0)
                    d == 0 && continue
                    iset = get(index_sets, sh[p], nothing)
                    (iset !== nothing && iset.size === extents[d]) || continue
                    push!(evidence[d], sh[p])
                end
            end
        end
        for c in child_exprs(e)
            walk(c)
        end
        return
    end
    for ma in mas
        walk(ma)
    end
    return Union{String, Nothing}[
        length(evidence[d]) == 1 ? first(evidence[d]) :
            nothing for d in 1:rank
    ]
end

# Map each grid dimension to a declared index set — by NAME propagation from the
# operand gathers where that is decisive (`_lift_axis_names`), else by matching
# extents — producing the species' new shape axes (`gaxes`) and the aggregate
# loop `ranges`, each `{"from": <axis>}`. A synthetic axis is added to
# `registry` (the flattened `index_sets`). `reg` is the template registry.
function _pointwise_lift_axes(
        ma::OpExpr, loops::Vector{String},
        size_to_names::Dict{Int, Vector{String}},
        species::String, rank::Int;
        mas::Vector{OpExpr},
        var_shapes::Dict{String, Vector{String}},
        index_sets, reg,
        registry::AbstractDict{String, IndexSet}
    )
    extents = _makearray_extents(ma)
    named = _lift_axis_names(mas, loops, extents, var_shapes, index_sets, reg)
    gaxes = String[]
    ranges = Dict{String, Any}()
    for d in 1:rank
        nm = d <= length(named) ? named[d] : nothing
        if nm !== nothing
            push!(gaxes, nm)
            ranges[loops[d]] = IndexSetRef(nm)
            continue
        end
        cands = get(size_to_names, extents[d], String[])
        if length(cands) == 1
            push!(gaxes, cands[1])
            ranges[loops[d]] = IndexSetRef(cands[1])
        else
            # No unique index set of this size — fall back to a synthetic axis,
            # registered in the flattened `index_sets`.
            if length(cands) > 1
                _flatten_warn(
                    "pointwise_lift_ambiguous_index_set",
                    "grid dimension $(d) of species " *
                        "'$(species)' (extent $(extents[d])) matches multiple " *
                        "declared index sets $(sort(cands)) by size, and no " *
                        "declared-shape operand gathered at loop " *
                        "'$(loops[d])' names one of them unambiguously, so the " *
                        "synthetic index set '_liftdim$(d)_$(extents[d])' is " *
                        "registered and used instead."
                )
            end
            # Synthetic-axis naming convention: `_liftdim<dim>_<extent>`, a
            # self-describing name the same in every binding
            # (esm-libraries-spec §4.7.5, "Pointwise lift: index sets").
            axname = "_liftdim$(d)_$(extents[d])"
            _register_synthetic_index_set!(
                registry, axname, extents[d],
                "pointwise lift: species '$(species)'", "grid dimension $(d)"
            )
            push!(gaxes, axname)
            ranges[loops[d]] = IndexSetRef(axname)
        end
    end
    return gaxes, ranges
end

# Rewrite the merged scalar state ODE into per-cell `faq`s over the grid:
# left-hand side `D(sp)` → `faq(D(index(sp, loops…)))`, each contribution read
# at the cell by `_lift_rhs_to_cell`, and the right-hand side the `faq` of
# their left-fold sum (esm-libraries-spec §4.7.5), so the lifted equation's
# body is what the contributions sum to.
function _pointwise_lift_equation(
        fe::_FlatEq, arrayvars::Set{String}, species::String, loops::Vector{String},
        align::_AxisAlign, ranges::Dict{String, Any}, ctx = nothing
    )
    idx_species = _index_wrap(VarExpr(species), loops)
    new_lhs = _cell_faq(OpExpr("D", ASTExpr[idx_species], wrt = "t"), loops, ranges)
    lifted = Contribution[
        Contribution(_lift_rhs_to_cell(c.expr, arrayvars, loops, align, species, ctx), c.origins)
            for c in fe.contribs
    ]
    new_rhs = _cell_faq(_fold_contributions(lifted), loops, ranges)
    return _FlatEq(Equation(new_lhs, new_rhs; _comment = fe.eq._comment), lifted, fe.owner)
end
