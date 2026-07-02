# ============================================================================
# Downstream shape promotion (scalar → array) as an AST transform
# ============================================================================
#
# A coupled system is often authored with a SPATIAL field (e.g. a level-set
# `psi[x,y]`) fed by a chain of scalar "physics" variables (`R = f(U, EMC, …)`),
# which are in turn fed by ARRAY sources (a per-cell regridded forcing `F_tgt[x,y]`).
# The scalar authoring is a dimensionality fiction: each physics quantity really
# varies per grid cell. Rather than re-author every component per-cell, or lift
# scalars over the grid in the evaluator (runner logic), we PROMOTE shapes in the
# AST: any variable whose defining expression's inferred shape is an array grid
# shape is promoted to that shape, and its equation is rewritten from a scalar
# expression into an `arrayop` that indexes the now-array operands per cell and
# broadcasts the genuine scalars. Because the rewrite emits standard `arrayop`
# nodes, the evaluator needs NO new per-cell machinery.
#
# This is broadcast shape inference over the dataflow graph:
#  - SEED: variables with an explicit (grid) shape — regrid outputs, loader
#    fields, the spatial state.
#  - PROPAGATE: an operand's shape flows to the result through elementwise ops;
#    an `aggregate`/`arrayop` with a contracting `output_idx` is a PROMOTION
#    BOUNDARY (a genuine reduction stays scalar), and an `index` gather is scalar.
#  - CONFLICT: all array sources must resolve to one grid shape; a genuine
#    mismatch is an error (the caller picks the target grid).

# Output shape (vector of index-set / dim names; empty = scalar) of an expression
# under the current per-variable shape map.
function _infer_expr_shape(expr::EarthSciSerialization.Expr,
                           shapes::Dict{String,Vector{String}})::Vector{String}
    if expr isa NumExpr || expr isa IntExpr
        return String[]
    elseif expr isa VarExpr
        return get(shapes, expr.name, String[])
    elseif expr isa OpExpr
        op = expr.op
        if op == "index"
            # A gather selects one element (or a fixed slice) — scalar output for
            # promotion purposes (the level-set already indexes its own field).
            return String[]
        elseif op == "aggregate" || op == "arrayop" || op == "makearray"
            # Output is exactly the uncontracted axes named in output_idx.
            return expr.output_idx === nothing ? String[] :
                   String[string(x) for x in expr.output_idx]
        else
            # Elementwise: broadcast — all non-scalar operands must agree, the
            # result takes that shape. `lower`/`upper` (integral bounds) and
            # `filter` don't shape the elementwise result.
            sh = String[]
            for a in expr.args
                s = _infer_expr_shape(a, shapes)
                isempty(s) && continue
                if isempty(sh)
                    sh = s
                elseif sh != s
                    throw(ArgumentError(
                        "shape-promotion: conflicting operand shapes $(sh) vs $(s) " *
                        "in op '$(op)' — array sources must resolve to one grid shape"))
                end
            end
            return sh
        end
    end
    return String[]
end

# Replace each VarExpr leaf naming a promoted ARRAY variable with `index(v, loops…)`,
# leaving scalar leaves (params, constants, reductions' results) untouched. Does
# not descend into nested aggregate/arrayop bodies — those carry their own indexing.
#
# An ARRAY-PRODUCING node in elementwise position (a `makearray`, or an
# `aggregate`/`arrayop` with non-empty `output_idx`) gets the same broadcast
# treatment as an array variable leaf: it is wrapped in `index(node, loops…)` so
# the per-cell expansion gathers this cell's element. This is the whole-array
# broadcast semantics of esm-spec §9.6.8 — a discretization rule lowers
# `D(u, x)` to a `makearray`, and the surrounding equation (`rhs = -c * D(u,x)`)
# multiplies that array elementwise. A genuine scalar reduction (empty
# `output_idx`) and an `index` gather stay untouched — they are already scalar.
function _index_array_leaves(expr::EarthSciSerialization.Expr,
                             arrayvars::Set{String}, loops::Vector{String})::EarthSciSerialization.Expr
    if expr isa VarExpr
        if expr.name in arrayvars
            idx = EarthSciSerialization.Expr[VarExpr(expr.name)]
            for l in loops
                push!(idx, VarExpr(l))
            end
            return OpExpr("index", idx)
        end
        return expr
    elseif expr isa OpExpr
        if _is_array_producer(expr)
            idx = EarthSciSerialization.Expr[expr]
            for l in loops
                push!(idx, VarExpr(l))
            end
            return OpExpr("index", idx)
        end
        (expr.op == "aggregate" || expr.op == "arrayop" || expr.op == "makearray" ||
         expr.op == "index") && return expr
        new_args = EarthSciSerialization.Expr[_index_array_leaves(a, arrayvars, loops) for a in expr.args]
        return reconstruct(expr; args=new_args)
    end
    return expr
end

# True iff `expr` is an array-PRODUCING node: a `makearray`, or an
# `aggregate`/`arrayop` with a non-empty `output_idx` (a scalar reduction has an
# empty `output_idx` and produces a scalar).
function _is_array_producer(expr::EarthSciSerialization.Expr)::Bool
    expr isa OpExpr || return false
    expr.op == "makearray" && return true
    (expr.op == "aggregate" || expr.op == "arrayop") || return false
    expr.output_idx === nothing && return false
    return any(s -> s isa AbstractString, expr.output_idx)
end

# Wrap a (formerly scalar) defining expression in an arrayop producing `shape`.
# Loop vars are fresh simple names (`_p0`, `_p1`, …) — NOT the index-set names,
# which may be dotted/namespaced. A shape axis that names a declared index set
# ranges over it (`{from: …}`); one that names a grid/domain dimension ranges over
# a dense `[1, size]` (grid dims are global, not index sets).
function _lift_to_arrayop(expr::EarthSciSerialization.Expr, shape::Vector{String},
                          arrayvars::Set{String}, index_sets, dim_sizes::Dict{String,Int})::OpExpr
    loops = String["_p$(i-1)" for i in 1:length(shape)]
    ranges = Dict{String,Any}()
    for i in eachindex(shape)
        s = shape[i]
        ranges[loops[i]] = haskey(index_sets, s) ? IndexSetRef(s) :
            (haskey(dim_sizes, s) ? Any[1, dim_sizes[s]] : IndexSetRef(s))
    end
    body = _index_array_leaves(expr, arrayvars, loops)
    return OpExpr("arrayop", EarthSciSerialization.Expr[];
                  output_idx=Any[l for l in loops], ranges=ranges, expr_body=body)
end

# Grid/domain dimension → cell count. Spatial dimension sizes used to come from
# the removed Domain.spatial spec; they are now declared via `index_sets`, so
# the domain itself contributes no array dim sizes here.
function _domain_dim_sizes(flat::FlattenedSystem)::Dict{String,Int}
    return Dict{String,Int}()
end

"""
    algebraic_states_to_observeds(flat::FlattenedSystem) -> FlattenedSystem

Reclassify every state variable that is defined by a BARE algebraic equation
(`x = expr`, no `D(x,t)`) as an observed variable. Such "algebraic states" are a
DAE authoring form (a quantity constrained by an equation rather than integrated);
for the tree-walk ODE path they are observeds — derived, inlined, never an ODE
slot. A pure ODE state (defined by `D(x,t)`) is left untouched. This normalization
lets `promote_downstream_shapes` lift a feed-forward algebraic physics chain
authored as states (Rothermel R, midflame U, EMC, …) the same as expression-defined
observeds. Returns a new system; the input is untouched.
"""
function algebraic_states_to_observeds(flat::FlattenedSystem)::FlattenedSystem
    diff_states = Set{String}()
    alg_defined = Set{String}()
    for eq in flat.equations
        if eq.lhs isa OpExpr && eq.lhs.op == "D" && !isempty(eq.lhs.args) &&
           eq.lhs.args[1] isa VarExpr
            push!(diff_states, (eq.lhs.args[1]::VarExpr).name)
        elseif eq.lhs isa VarExpr
            push!(alg_defined, (eq.lhs::VarExpr).name)
        end
    end
    new_states = OrderedDict{String,ModelVariable}()
    new_obs = OrderedDict{String,ModelVariable}(flat.observed_variables)
    for (k, v) in flat.state_variables
        if (k in alg_defined) && !(k in diff_states)
            new_obs[k] = ModelVariable(ObservedVariable; default=v.default, units=v.units,
                default_units=v.default_units, description=v.description,
                expression=v.expression, shape=v.shape, location=v.location,
                noise_kind=v.noise_kind, correlation_group=v.correlation_group)
        else
            new_states[k] = v
        end
    end
    return FlattenedSystem(flat.independent_variables, new_states, flat.parameters,
                           new_obs, flat.equations, flat.continuous_events,
                           flat.discrete_events, flat.domain, flat.metadata,
                           flat.index_sets, flat.function_tables)
end

"""
    inline_elementwise_array_observeds(flat::FlattenedSystem) -> FlattenedSystem

Substitute away every ARRAY-shaped observed that is defined by a BARE *elementwise*
equation (`v = expr` where `expr` is not an `arrayop`/`aggregate`/`makearray`), folding
it into the equations that read it and dropping it from the system.

The tree-walk evaluator inlines an array observed only when it is defined by an
`arrayop` (per-cell index beta-reduction) or is a geometry clip ring; an array observed
authored as a plain elementwise expression over the spatial field (a level-set's
`grad_mag = sqrt(psi_x^2 + psi_y^2)`, `U_n = …`, `S_n = R_0·(1+phi_W+phi_S)`, …) has no
such per-cell form and is otherwise rejected. Rather than require every such component
to be re-authored as `arrayop`s, this pass performs the feed-forward topological
substitution a driver would otherwise do by hand (the level-set fold), in dependency
order, so the spatial state equation `D(psi,t) = …` carries the fully-inlined RHS and
`discretize` then lowers its `grad`s. Genuine reductions/gathers (`arrayop`, `aggregate`,
`makearray`) are left intact — they ARE inlinable and define their own indexing. A no-op
when no elementwise array observed exists. Returns a new system; the input is untouched.
"""
function inline_elementwise_array_observeds(flat::FlattenedSystem)::FlattenedSystem
    is_array_obs(nm) = haskey(flat.observed_variables, nm) &&
        (v = flat.observed_variables[nm]; v.shape !== nothing && !isempty(v.shape))
    is_elementwise(rhs) = !(rhs isa OpExpr &&
        ((rhs::OpExpr).op == "arrayop" || (rhs::OpExpr).op == "aggregate" ||
         (rhs::OpExpr).op == "makearray"))
    targets = Dict{String,EarthSciSerialization.Expr}()
    for eq in flat.equations
        eq.lhs isa VarExpr || continue
        nm = (eq.lhs::VarExpr).name
        (is_array_obs(nm) && is_elementwise(eq.rhs)) && (targets[nm] = eq.rhs)
    end
    isempty(targets) && return flat

    # Dependency order (the chain is feed-forward; a cycle is a real authoring error).
    order = String[]; done = Set{String}()
    while length(order) < length(targets)
        progressed = false
        for (nm, rhs) in targets
            nm in done && continue
            if all(d -> d in done, intersect(free_variables(rhs), keys(targets)))
                push!(order, nm); push!(done, nm); progressed = true
            end
        end
        progressed || throw(ArgumentError(
            "inline_elementwise_array_observeds: cyclic elementwise array-observed dependency"))
    end
    resolved = Dict{String,EarthSciSerialization.Expr}()
    for nm in order
        resolved[nm] = substitute(targets[nm], resolved)
    end

    new_obs = OrderedDict{String,ModelVariable}(
        k => v for (k, v) in flat.observed_variables if !haskey(targets, k))
    new_eqs = Equation[]
    for eq in flat.equations
        (eq.lhs isa VarExpr && haskey(targets, (eq.lhs::VarExpr).name)) && continue  # drop the def
        push!(new_eqs, Equation(eq.lhs, substitute(eq.rhs, resolved);
                                _comment=eq._comment))
    end
    return FlattenedSystem(flat.independent_variables, flat.state_variables, flat.parameters,
                           new_obs, new_eqs, flat.continuous_events, flat.discrete_events,
                           flat.domain, flat.metadata, flat.index_sets, flat.function_tables)
end

"""
    promote_downstream_shapes(flat::FlattenedSystem) -> FlattenedSystem

Promote every variable whose defining algebraic equation has an inferred ARRAY
(grid) shape from scalar to that shape, rewriting its equation into an `arrayop`
that indexes the now-array operands per cell. Shape inference is seeded by the
variables already carrying a grid shape (regrid outputs, loader fields, the
spatial state) and propagates through elementwise ops, stopping at aggregate
reductions and `index` gathers. The transform is a no-op for a system with no
scalar-downstream-of-array variables (it returns an equivalent system).

`index_sets` for the grid axes must already be declared (the loop ranges resolve
against them); supply them on the FlattenedSystem before calling. Returns a new
FlattenedSystem; the input is untouched.
"""
function promote_downstream_shapes(flat::FlattenedSystem)::FlattenedSystem
    # Current shapes from declarations (scalar = []).
    shapes = Dict{String,Vector{String}}()
    for d in (flat.state_variables, flat.parameters, flat.observed_variables)
        for (k, v) in d
            shapes[k] = v.shape === nothing ? String[] : String[string(s) for s in v.shape]
        end
    end

    # Index the ALGEBRAIC defining equations (bare `x = expr`). State equations
    # (`D(x,t) = …`) don't define x's shape (x keeps its declared shape).
    defs = Dict{String,EarthSciSerialization.Expr}()
    for eq in flat.equations
        eq.lhs isa VarExpr || continue
        defs[(eq.lhs::VarExpr).name] = eq.rhs
    end

    # Fixed-point shape inference: a scalar var whose defining expression infers
    # an array shape is promoted. Repeat until stable (acyclic chain ⇒ converges).
    changed = true
    while changed
        changed = false
        for (name, rhs) in defs
            cur = get(shapes, name, String[])
            isempty(cur) || continue                     # already array — leave it
            inferred = _infer_expr_shape(rhs, shapes)
            if !isempty(inferred)
                shapes[name] = inferred
                changed = true
            end
        end
    end

    # The set of variables that are now array-shaped (for leaf indexing).
    arrayvars = Set{String}(k for (k, s) in shapes if !isempty(s))
    dim_sizes = _domain_dim_sizes(flat)

    # Rebuild variable partitions with promoted shapes.
    function promote_partition(part)
        out = OrderedDict{String,ModelVariable}()
        for (k, v) in part
            s = get(shapes, k, String[])
            if !isempty(s) && (v.shape === nothing || isempty(v.shape))
                out[k] = _with_shape(v, s)              # promoted: was scalar
            else
                out[k] = v
            end
        end
        return out
    end
    new_states = promote_partition(flat.state_variables)
    new_params = promote_partition(flat.parameters)
    new_observeds = promote_partition(flat.observed_variables)

    # Rewrite equations: a promoted var's bare `x = expr` becomes `x = arrayop(…)`;
    # otherwise index any newly-array operands that appear bare in the RHS
    # (e.g. an aggregate body, or a still-scalar consumer that must now gather).
    new_eqs = Equation[]
    for eq in flat.equations
        if eq.lhs isa VarExpr && (eq.lhs::VarExpr).name in arrayvars &&
           haskey(defs, (eq.lhs::VarExpr).name) &&
           (flat_was_scalar(flat, (eq.lhs::VarExpr).name))
            name = (eq.lhs::VarExpr).name
            push!(new_eqs, Equation(eq.lhs,
                _lift_to_arrayop(eq.rhs, shapes[name], arrayvars, flat.index_sets, dim_sizes);
                _comment=eq._comment))
        else
            push!(new_eqs, eq)
        end
    end

    return FlattenedSystem(flat.independent_variables, new_states, new_params,
                           new_observeds, new_eqs, flat.continuous_events,
                           flat.discrete_events, flat.domain, flat.metadata,
                           flat.index_sets, flat.function_tables)
end

"""
    promoted_array_names(flat, promoted) -> Set{String}

The names of variables that `promote_downstream_shapes` turned from scalar into an
array shape — i.e. those whose shape grew. Useful to drive `index_promoted_refs!`
on a discretized document. `flat` is the ORIGINAL system, `promoted` the result.
"""
function promoted_array_names(flat::FlattenedSystem, promoted::FlattenedSystem)::Set{String}
    out = Set{String}()
    for part in (:state_variables, :parameters, :observed_variables)
        before = getfield(flat, part); after = getfield(promoted, part)
        for (k, v) in after
            (v.shape === nothing || isempty(v.shape)) && continue
            b = get(before, k, nothing)
            (b !== nothing && (b.shape === nothing || isempty(b.shape))) && push!(out, k)
        end
    end
    return out
end

"""
    index_promoted_refs!(doc, arrayvars; spatial_loops=["i","j"]) -> doc

Post-discretize pass: replace a BARE reference to a promoted array variable with
`index(var, <loops>)`, so the evaluator's index beta-reduction collapses it to the
var's per-cell value. Inside a nested `arrayop` the loops are its own `output_idx`;
in the spatial state equation (`D(psi,t) = expr(i,j)`, which `discretize` lowers
with the grad-rule grid loops — only AFTER `promote_downstream_shapes`) the loops
are `spatial_loops`. Mutates and returns the native `doc`. This generalizes the
driver's hand `couple_fields` bare→index rewrite.
"""
function index_promoted_refs!(doc::AbstractDict, arrayvars;
                              spatial_loops::Vector{String}=["i","j"])::AbstractDict
    av = Set{String}(String(x) for x in arrayvars)
    isempty(av) && return doc
    models = get(doc, "models", nothing)
    models isa AbstractDict || return doc
    for (_, m) in models
        eqs = get(m, "equations", nothing)
        eqs isa AbstractVector || continue
        for eq in eqs
            haskey(eq, "rhs") && (eq["rhs"] = _index_bare(eq["rhs"], av, spatial_loops))
        end
    end
    return doc
end

# Single loop-tracking walk: `loops` is the iteration context for bare promoted
# refs. An `arrayop` switches the context to its own output_idx for its body; an
# `index` node keeps its array operand (arg 1) and recurses only the index exprs.
function _index_bare(node, av::Set{String}, loops::Vector{String})
    if node isa AbstractString
        return node in av ? Dict{String,Any}("op"=>"index", "args"=>Any[node, loops...]) : node
    elseif node isa AbstractVector
        return Any[_index_bare(x, av, loops) for x in node]
    elseif node isa AbstractDict
        op = get(node, "op", "")
        nm = get(node, "name", nothing)
        if op == "" && nm isa AbstractString && String(nm) in av
            return Dict{String,Any}("op"=>"index", "args"=>Any[node, loops...])
        elseif op == "arrayop"
            inner = String[String(x) for x in get(node, "output_idx", Any[])]
            out = Dict{String,Any}()
            for (k, v) in node
                out[String(k)] = (k == "expr" && !isempty(inner)) ?
                    _index_bare(v, av, inner) : _index_bare(v, av, loops)
            end
            return out
        elseif op == "index"
            a = get(node, "args", nothing)
            a isa AbstractVector || return node
            out = copy(node)
            out["args"] = Any[i == 1 ? a[1] : _index_bare(a[i], av, loops) for i in eachindex(a)]
            return out
        else
            out = Dict{String,Any}()
            for (k, v) in node
                out[String(k)] = _index_bare(v, av, loops)
            end
            return out
        end
    end
    return node
end

# True iff `name` was authored scalar (no declared shape) in the original system.
function flat_was_scalar(flat::FlattenedSystem, name::AbstractString)::Bool
    for d in (flat.state_variables, flat.parameters, flat.observed_variables)
        haskey(d, name) && return d[name].shape === nothing || isempty(d[name].shape)
    end
    return true
end

# Return a copy of a ModelVariable with a new (array) shape. A promoted variable's
# defining scalar `expression` is cleared — its rewritten `arrayop` EQUATION is now
# the single source of truth (flatten always emits an equation per observed), so a
# stale scalar expression at an array shape can't be mistaken for the definition.
function _with_shape(v::ModelVariable, shape::Vector{String})::ModelVariable
    return ModelVariable(v.type; default=v.default, units=v.units,
        default_units=v.default_units, description=v.description,
        expression=nothing, shape=copy(shape), location=v.location,
        noise_kind=v.noise_kind, correlation_group=v.correlation_group)
end
