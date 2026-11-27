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
# expression into a `faq` that indexes the now-array operands per cell and
# broadcasts the genuine scalars. Because the rewrite emits standard `faq`
# nodes, the evaluator needs NO new per-cell machinery.
#
# This is broadcast shape inference over the dataflow graph:
#  - SEED: variables with an explicit (grid) shape — regrid outputs, loader
#    fields, the spatial state.
#  - PROPAGATE: an operand's shape flows to the result through elementwise ops;
#    a `faq` with a contracting `output_idx` is a PROMOTION
#    BOUNDARY (a genuine reduction stays scalar), and an `index` gather is scalar.
#  - UNION: operands over different index sets give the union of their index
#    sets (the outer product), in order of first appearance.

# The index sets `expr`'s value spans under the current per-variable shape map
# (empty for a scalar, and for an expression the inference leaves undecided):
# the one inference, `_expr_axes` (expr_axes.jl). Elementwise operands over
# different index sets give the union, in order of first appearance
# (esm-spec §4.3.4). With `ctx`, a template application is elementwise over the
# arrays its expansion reads in value positions (esm-spec §9.6.11).
_infer_expr_shape(
    expr::ASTExpr, shapes::Dict{String, Vector{String}}, ctx = nothing
)::Vector{String} = something(
    _expr_axes(_ShapeEnv(shapes; unknown = String[], ctx = ctx), expr), String[]
)

# The bare-left-hand-side definitions `x = rhs` of `equations`, in equation
# order. A name defined twice is an unbalanced system the validator and the
# build refuse; the first definition is the one read here.
function _bare_definitions(equations)::OrderedDict{String, ASTExpr}
    defs = OrderedDict{String, ASTExpr}()
    for eq in equations
        eq.lhs isa VarExpr && get!(defs, (eq.lhs::VarExpr).name, eq.rhs)
    end
    return defs
end

# Extend `shapes` to a fixed point (esm-spec §4.3.4, §9.6.11): each name `defs`
# defines and `shapes` gives no array shape takes the shape its definition
# infers, until no shape changes. A name in `declared_scalar` (an explicit
# `shape: []`) whose definition infers an array is a conflict.
function _infer_shapes!(
        shapes::Dict{String, Vector{String}}, defs, ctx;
        declared_scalar = Set{String}()
    )
    changed = true
    while changed
        changed = false
        for (name, rhs) in defs
            isempty(get(shapes, name, String[])) || continue
            inferred = _infer_expr_shape(rhs, shapes, ctx)
            isempty(inferred) && continue
            name in declared_scalar &&
                _throw_declared_scalar_conflict(name, inferred, "its defining expression")
            shapes[name] = inferred
            changed = true
        end
    end
    return shapes
end

# Wrap a (formerly scalar) defining expression in the `faq` producing `shape`:
# its array operands read at the cell (`_index_array_leaves`, aligned by
# index-set name, esm-spec §4.3.4), each loop (`_fresh_loops`) ranging over the
# index set its axis names.
#
# `bounds` replaces those index-set references with RESOLVED `[1, extent]`
# literals, one per axis, for a caller lifting a body it is about to evaluate
# rather than to store: the §6.6.5 assertion path
# ([`_authored_observed_body`](@ref)) has the extents in hand and no index-set
# registry at the evaluator. Everything else about the lift is the build's own
# promotion, which is why this takes a keyword instead of being copied.
function _lift_to_faq(
        expr::ASTExpr, shape::Vector{String},
        arrayvars::Set{String},
        var_shapes::Dict{String, Vector{String}} =
            Dict{String, Vector{String}}();
        bounds::Union{Nothing, Vector{Int}} = nothing
    )::OpExpr
    loops = _fresh_loops(expr, bounds === nothing ? length(shape) : length(bounds))
    ranges = bounds === nothing ? _cell_ranges(loops, shape) :
        Dict{String, Any}(loops[i] => Any[1, bounds[i]] for i in eachindex(bounds))
    # `_AxisAlign` is unusable (`_usable_align`) when its axes are not
    # positionally parallel to `loops`, so a shape/bounds length mismatch reads
    # positionally rather than misaligning.
    body = _index_array_leaves(expr, arrayvars, loops; align = _AxisAlign(shape, var_shapes))
    return _cell_faq(body, loops, ranges)
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

A name carrying BOTH forms stays a state here and keeps both of its equations,
but no run reaches that state: `_build_evaluator` refuses such a document at its
entry with `equation_count_mismatch`, because esm-spec §4.9.4 counts an equation
whichever form its LHS takes and the system is therefore unbalanced — which is
what `validate` reports for the same file.
"""
function algebraic_states_to_observeds(flat::FlattenedSystem)::FlattenedSystem
    diff_states = Set{String}()
    alg_defined = Set{String}()
    for eq in flat.equations
        dv = differential_lhs_variable(eq.lhs)
        if dv !== nothing
            push!(diff_states, dv)
        elseif eq.lhs isa VarExpr
            push!(alg_defined, (eq.lhs::VarExpr).name)
        end
    end
    new_states = OrderedDict{String, ModelVariable}()
    new_obs = OrderedDict{String, ModelVariable}(flat.observed_variables)
    for (k, v) in flat.state_variables
        if (k in alg_defined) && !(k in diff_states)
            # Both sides are `unknown`; the move between the
            # FlattenedSystem's state and observed buckets IS the reclassification
            # (an algebraically-defined name is observed, esm-spec §6.3.1), so the
            # declared type is already right and the variable copies across as-is.
            new_obs[k] = v
        else
            new_states[k] = v
        end
    end
    return FlattenedSystem(
        flat; state_variables = new_states,
        observed_variables = new_obs
    )
end

"""
    promote_downstream_shapes(flat::FlattenedSystem) -> FlattenedSystem

Promote every variable whose defining algebraic equation has an inferred ARRAY
(grid) shape from scalar to that shape, rewriting its equation into a `faq`
that indexes the now-array operands per cell. Shape inference is seeded by the
variables already carrying a grid shape (regrid outputs, loader fields, the
spatial state) and propagates through elementwise ops, stopping at aggregate
reductions and `index` gathers. The transform is a no-op for a system with no
scalar-downstream-of-array variables (it returns an equivalent system).

Only a variable declared WITHOUT a `shape` is promoted. An explicit `shape: []`
declares a scalar (esm-spec §4.3.4); a definition that infers an array for one —
an elementwise expression over an array, or a `faq` over inline ranges — throws
a `DimensionPromotionError` (`array_shape_mismatch`) naming the variable.

CONSUMERS of a promoted variable are closed too: a bare reference to a newly
promoted name inside the body of a `faq` that already carries
its loops (a pointwise-lifted species ODE, an authored per-cell equation) is
rewritten to an `index(var, <loops>)` gather bound in that body's own loop
scope — name-aligned against the enclosing `ranges`' index sets where possible,
positionally over the enclosing producer's `output_idx` otherwise (see
[`_index_promoted_consumer_refs`](@ref)). A reference in SCALAR position (the
un-discretized spatial state equation) is left bare: its loops do not exist
until `discretize` lowers the equation.

`index_sets` for the grid axes must already be declared (the loop ranges resolve
against them); supply them on the FlattenedSystem before calling. Returns a new
FlattenedSystem; the input is untouched.
"""
function promote_downstream_shapes(flat::FlattenedSystem)::FlattenedSystem
    # Current shapes from declarations (scalar = []). An ABSENT `shape` may be
    # inferred below; an explicit `shape: []` DECLARES a scalar and is never
    # promoted (esm-spec §4.3.4) — a definition that infers an array for one is
    # a conflict, not a promotion.
    shapes = Dict{String, Vector{String}}()
    for d in (flat.state_variables, flat.parameters, flat.observed_variables)
        for (k, v) in d
            shapes[k] = v.shape === nothing ? String[] : String[string(s) for s in v.shape]
        end
    end
    declared_scalar = Set{String}(
        k for d in (flat.state_variables, flat.parameters, flat.observed_variables)
            for (k, v) in d if _declares_scalar(v)
    )

    # Reads the template references the elementwise lift meets (esm-spec
    # §9.6.11). The cellwise variants it adds go to a copy of the registry:
    # naming them may renumber those flatten named, and the input is untouched.
    registry = copy(flat.template_registry)
    ew = _ElementwiseContext(registry)

    # The ALGEBRAIC defining equations (bare `x = expr`). State equations
    # (`D(x,t) = …`) don't define x's shape (x keeps its declared shape).
    defs = _bare_definitions(flat.equations)

    # A variable defined by a `faq` whose output indices range over inline
    # intervals takes its shape from those ranges (esm-spec §6.3): each axis is
    # named by the index set of that extent the output symbol names, or else by
    # an anonymous interval index set registered here. A declared shape must
    # agree with the ranges' extents.
    index_sets = flat.index_sets
    added = false
    for (name, rhs) in defs
        axes = _inline_producer_axes(rhs)
        axes === nothing && continue
        name in declared_scalar &&
            _throw_declared_scalar_conflict(name, [n for (_, n) in axes], "a faq over inline ranges")
        cur = get(shapes, name, String[])
        if !isempty(cur)
            _check_declared_producer_extents(name, cur, axes, index_sets)
            continue
        end
        names = String[]
        for (sym, n) in axes
            is = get(index_sets, sym, nothing)
            if is isa IndexSet && is.kind == "interval" && is.size == n
                push!(names, sym)
            else
                anon = string(name, "__", sym)
                added || (index_sets = OrderedDict{String, IndexSet}(index_sets); added = true)
                _register_synthetic_index_set!(
                    index_sets, anon, n, "shape promotion: '$(name)'", "output index '$(sym)'"
                )
                push!(names, anon)
            end
        end
        shapes[name] = names
    end

    # A scalar variable whose defining expression infers an array shape is
    # promoted.
    _infer_shapes!(shapes, defs, ew; declared_scalar = declared_scalar)

    # The set of variables that are now array-shaped (for leaf indexing).
    arrayvars = Set{String}(k for (k, s) in shapes if !isempty(s))

    # An equation applying a template elementwise over an array (esm-spec
    # §9.6.11) is lifted over its variable's shape — declared, or inferred
    # above — with each array its applications read in a value position read
    # at the cell. It replaces the leaf-indexing lift below, which does not
    # reach into template applications. An application that reads an anonymous
    # array there, in any equation, is refused first.
    for eq in flat.equations
        _refuse_anonymous_arrays(eq.rhs, eq.lhs, ew)
    end
    ew_lifted = Dict{String, OpExpr}()
    for (name, rhs) in defs
        sh = get(shapes, name, String[])
        (isempty(sh) || !_has_elementwise_application(rhs, shapes, ew)) && continue
        ew_lifted[name] = _lift_elementwise_application(rhs, sh, shapes, ew, name)
    end

    # Rebuild variable partitions with promoted shapes.
    function promote_partition(part)
        out = OrderedDict{String, ModelVariable}()
        for (k, v) in part
            s = get(shapes, k, String[])
            if !isempty(s) && v.shape === nothing
                out[k] = _with_shape(v, s)              # promoted: was unshaped
            else
                out[k] = v
            end
        end
        return out
    end
    new_states = promote_partition(flat.state_variables)
    new_params = promote_partition(flat.parameters)
    new_observeds = promote_partition(flat.observed_variables)

    # Names whose shape GREW in this pass (scalar → array). Only these need
    # consumer-side gathers below: a pre-existing array operand was already the
    # author's (or an earlier lift's) responsibility to index, and rewriting it
    # here would change working documents.
    newly_promoted = Set{String}(k for k in arrayvars if flat_was_scalar(flat, k))
    _refuse_faq_bare_promoted_reads(flat, newly_promoted, shapes)

    # Rewrite equations: a promoted var's bare `x = expr` becomes `x = faq(…)`;
    # then, in EVERY equation, a bare reference to a newly promoted variable
    # inside a loop-carrying faq body becomes an `index` gather in
    # that body's own loop scope (`_index_promoted_consumer_refs`). Without the
    # consumer rewrite, a pointwise-lifted state ODE — whose lift indexed only
    # the operands that carried a shape AT FLATTEN TIME — ships a bare scalar
    # name for a now-array variable, and the evaluator fails to bind it
    # (`E_TREEWALK_UNBOUND_VARIABLE`). Scalar-position references are left
    # bare.
    #
    # Per-term provenance (esm-libraries-spec §4.7.5): the consumer rewrite
    # applies inside each contribution (a lifted equation's in its `faq` loop
    # scope). Wrapping a definition into a `faq` is NOT additive — the producer
    # computes the whole sum per cell — so a promoted definition's contributions
    # COLLAPSE into the one wrapped expression, origins their union.
    new_eqs = Equation[]
    new_contribs = Vector{Contribution}[]
    for (eq, cs) in zip(flat.equations, _flat_contributions(flat))
        out, out_cs = eq, cs
        if eq.lhs isa VarExpr && haskey(ew_lifted, (eq.lhs::VarExpr).name)
            out_cs = Contribution[Contribution(ew_lifted[(eq.lhs::VarExpr).name], _union_origins(cs))]
            out = _equation_from(eq, out_cs)
        elseif eq.lhs isa VarExpr && (eq.lhs::VarExpr).name in arrayvars &&
                haskey(defs, (eq.lhs::VarExpr).name) &&
                (flat_was_scalar(flat, (eq.lhs::VarExpr).name))
            wrapped = _lift_to_faq(eq.rhs, shapes[(eq.lhs::VarExpr).name], arrayvars, shapes)
            if wrapped !== eq.rhs
                out_cs = Contribution[Contribution(wrapped, _union_origins(cs))]
                out = _equation_from(eq, out_cs)
            end
        end
        out, out_cs = _rewrite_contributions(
            e -> _index_promoted_consumer_refs(e, newly_promoted, shapes), out, out_cs,
            _is_lifted(out, flat.lifted_shapes)
        )
        push!(new_eqs, out)
        push!(new_contribs, out_cs)
    end

    promoted = FlattenedSystem(
        flat; state_variables = new_states, parameters = new_params,
        observed_variables = new_observeds, equations = new_eqs,
        equation_contributions = new_contribs, index_sets = index_sets,
        template_registry = registry
    )
    # The cellwise variants this pass's lift made take their final names, with
    # those flatten named (esm-spec §9.6.11).
    return _rename_flat_refs(promoted, _name_cellwise_variants!(registry))
end

# `[(output symbol, extent)…]` of a `faq` producer every one of whose output
# indices ranges over an inline dense interval starting at 1, or `nothing`.
function _inline_producer_axes(rhs::ASTExpr)
    (rhs isa OpExpr && (rhs::OpExpr).op in _ARRAY_PRODUCER_OPS) || return nothing
    o = rhs::OpExpr
    (o.output_idx === nothing || isempty(o.output_idx) || o.ranges === nothing) &&
        return nothing
    axes = Tuple{String, Int}[]
    for x in o.output_idx
        x isa AbstractString || return nothing
        r = get(o.ranges, String(x), nothing)
        (r isa AbstractVector && length(r) == 2 && all(v -> v isa Integer, r)) || return nothing
        (r[1] == 1 && r[2] >= 1) || return nothing
        push!(axes, (String(x), Int(r[2])))
    end
    return axes
end

# A declared shape against the inline extents of the `faq` defining it.
function _check_declared_producer_extents(
        name::String, declared::Vector{String},
        axes::Vector{Tuple{String, Int}}, index_sets
    )
    ext = Int[]
    for d in declared
        is = get(index_sets, d, nothing)
        (is isa IndexSet && is.kind == "interval" && is.size !== nothing) || return nothing
        push!(ext, is.size)
    end
    ext == Int[n for (_, n) in axes] && return nothing
    throw(
        DimensionPromotionError(
            "array_shape_mismatch: '$(name)' declares shape $(declared) with extents $(ext), " *
                "but the faq defining it ranges over extents $([n for (_, n) in axes]) " *
                "(esm-spec §6.3: a variable defined over inline ranges takes its shape from " *
                "them, and a declared shape must agree)"
        )
    )
end

# esm-spec §4.3.1 `faq_bare_array_operand`, against the shapes this pass
# inferred: the build decides the rule "against the shape the build gives each
# variable — its declared `shape`, or, for a variable declared without one, the
# array shape its defining equation evaluates to". A bare read of a newly
# promoted name in an AUTHORED `faq` body or filter is refused, as it would be
# had the shape been declared; the consumer rewrite below would otherwise pick
# an alignment for it. A pointwise-lifted equation is exempt: the lift, not the
# author, put the bare name in its `faq` body.
function _refuse_faq_bare_promoted_reads(
        flat::FlattenedSystem, promoted::Set{String}, shapes::Dict{String, Vector{String}}
    )
    isempty(promoted) && return nothing
    promoted_shapes = Dict{String, Vector{String}}(n => shapes[n] for n in promoted)
    for eq in flat.equations
        _is_lifted(eq, flat.lifted_shapes) && continue
        found = faq_bare_array_operands(
            eq.rhs, promoted_shapes; exclude = faq_bare_exempt_names(eq.lhs)
        )
        isempty(found) && continue
        field, name, shape = first(found)
        throw(
            DimensionPromotionError(
                "$(ERROR_CODES.FAQ_BARE_ARRAY_OPERAND): '$(name)' is declared without a " *
                    "shape and its definition makes it an array; " *
                    faq_bare_array_operand_message(field, name, shape)
            )
        )
    end
    return nothing
end

"""
    _index_promoted_consumer_refs(expr, promoted, var_shapes) -> ASTExpr

Consumer-side companion of the promoted-definition rewrite: replace a BARE
reference to a newly promoted array variable, wherever it sits inside the body
of a loop-carrying `faq`, with an `index(var, <loops>)` gather
bound in the enclosing loop scope.

The motivating construct is a pointwise-lifted species ODE (§10.5) consuming a
scalar-authored photolysis chain (Fast-JX): the lift indexed only operands that
carried a shape AT FLATTEN TIME, so the j-rate — promoted only later, by
`promote_downstream_shapes` — survives as a bare name inside the per-cell
`faq` body, and the evaluator fails to bind it
(`E_TREEWALK_UNBOUND_VARIABLE`). Each consumer equation iterates its OWN loop
names (the lift's `["i","j","k"]` vs a promoted definition's
`["_p0","_p1","_p2"]`), so the gather is bound per scope.

Loop resolution, innermost scope winning:
- NAME-ALIGNED (preferred): every `ranges` entry of an enclosing producer whose
  spec is a plain `IndexSetRef` binds `index set → loop name` — including
  CONTRACTED loops absent from `output_idx` — and the gather lists the loop
  bound to each of the variable's declared axes in DECLARED-AXIS order, so a
  `[c,d]`-shaped variable inside a `[d,c]`-iterating body transposes correctly
  (the body-scope analogue of `_AxisAlign`). An axis bound by two loops of the
  same producer is ambiguous and poisons name alignment for that axis.
- POSITIONAL fallback: when name alignment cannot resolve every axis, and the
  INNERMOST enclosing producer has an all-symbolic `output_idx` whose rank
  equals the variable's, gather positionally over those loops.
- Otherwise the reference is left bare (the status-quo diagnostic fires).

A reference in scalar position (no enclosing producer) is always left bare —
its loops do not exist until `discretize` runs. References already under an `index` node are self-contained: the
gathered operand (arg 1) is never rewrapped. Pure; returns `expr` itself
(`===`) when nothing changes. Memoized by node identity per loop scope: within one scope the rewrite is a pure
function of the node, so a structurally-shared input DAG rewrites to a shared
output DAG instead of re-inflating into an exponential tree; entering a
producer opens a fresh scope (and memo), since the same node can legally
rewrite differently under different loop bindings.
"""
function _index_promoted_consumer_refs(
        expr::ASTExpr, promoted::Set{String},
        var_shapes::Dict{String, Vector{String}}
    )::ASTExpr
    isempty(promoted) && return expr
    return _index_promoted_in_scope(
        expr, promoted, var_shapes,
        Dict{String, Union{String, Nothing}}(), nothing,
        IdDict{OpExpr, ASTExpr}()
    )
end

function _index_promoted_in_scope(
        expr::ASTExpr, promoted::Set{String},
        var_shapes::Dict{String, Vector{String}},
        env::Dict{String, Union{String, Nothing}},
        poslocal::Union{Nothing, Vector{String}},
        memo::IdDict{OpExpr, ASTExpr}
    )::ASTExpr
    if expr isa VarExpr
        expr.name in promoted || return expr
        # Scalar position: no enclosing loop scope, nothing to bind against.
        (isempty(env) && poslocal === nothing) && return expr
        vs = get(var_shapes, expr.name, String[])
        isempty(vs) && return expr
        if allunique(vs)
            axes = String[ax for (ax, l) in env if l !== nothing]
            r = _gather_by_name(expr, vs, axes, String[env[ax] for ax in axes])
            (r isa OpExpr && allunique(String[(a::VarExpr).name for a in view(r.args, 2:length(r.args))])) &&
                return r
        end
        (poslocal !== nothing && length(poslocal) == length(vs)) &&
            return _index_wrap(expr, poslocal)
        return expr
    elseif expr isa OpExpr
        cached = get(memo, expr, nothing)
        cached === nothing || return cached
        result = _index_promoted_opexpr(
            expr, promoted, var_shapes, env,
            poslocal, memo
        )
        memo[expr] = result
        return result
    end
    return expr
end

function _index_promoted_opexpr(
        expr::OpExpr, promoted::Set{String},
        var_shapes::Dict{String, Vector{String}},
        env::Dict{String, Union{String, Nothing}},
        poslocal::Union{Nothing, Vector{String}},
        memo::IdDict{OpExpr, ASTExpr}
    )::ASTExpr
    if expr.op == "index"
        # The gathered operand keeps its own indexing; only the subscript
        # expressions recurse.
        length(expr.args) <= 1 && return expr
        changed = false
        new_args = Vector{ASTExpr}(undef, length(expr.args))
        new_args[1] = expr.args[1]
        for i in 2:length(expr.args)
            r = _index_promoted_in_scope(
                expr.args[i], promoted, var_shapes,
                env, poslocal, memo
            )
            r === expr.args[i] || (changed = true)
            new_args[i] = r
        end
        return changed ? reconstruct(expr; args = new_args) : expr
    end
    env2, pos2, memo2 = env, poslocal, memo
    if expr.op in _ARRAY_PRODUCER_OPS && expr.expr_body !== nothing &&
            expr.ranges !== nothing
        env2 = copy(env)
        seen = Set{String}()
        for (loop, spec) in expr.ranges
            (spec isa IndexSetRef && isempty(spec.of)) || continue
            ax = spec.from
            # Two loops of ONE producer over the same index set (a square
            # correlation) leave the axis with no unambiguous loop; poison
            # it rather than let Dict iteration order pick one.
            env2[ax] = ax in seen ? nothing : String(loop)
            push!(seen, ax)
        end
        oi = expr.output_idx
        # The positional fallback is only ever the INNERMOST producer's own
        # loops: an unusable output_idx (literal singleton dims, empty)
        # CLEARS it rather than letting an outer scope's loops leak in.
        pos2 = (
                oi !== nothing && !isempty(oi) &&
                all(x -> x isa AbstractString, oi)
            ) ?
            String[String(x) for x in oi] : nothing
        memo2 = IdDict{OpExpr, ASTExpr}()      # new loop scope ⇒ new memo
    end
    return map_children(
        c -> _index_promoted_in_scope(c, promoted, var_shapes, env2, pos2, memo2),
        expr
    )
end

# True iff `name` was authored with NO declared shape in the original system —
# the only declarations promotion may grow. An explicit `shape: []` is a declared
# scalar (`_declares_scalar`), never promoted.
function flat_was_scalar(flat::FlattenedSystem, name::AbstractString)::Bool
    for d in (flat.state_variables, flat.parameters, flat.observed_variables)
        haskey(d, name) && return d[name].shape === nothing
    end
    return true
end

# An explicit `shape: []`: a declared scalar, as opposed to an absent shape.
_declares_scalar(v::ModelVariable) = v.shape !== nothing && isempty(v.shape)

function _throw_declared_scalar_conflict(name, inferred, source::AbstractString)
    throw(
        DimensionPromotionError(
            "array_shape_mismatch: '$(name)' declares shape [] (a scalar), but " *
                "$(source) has array shape $(inferred). An explicit `shape: []` is " *
                "never promoted (esm-spec §4.3.4); omit `shape` to let it be inferred, " *
                "or declare the array shape"
        )
    )
end

# Return a copy of a ModelVariable with a new (array) shape. The
# rewritten `faq` EQUATION is the ONLY source of truth for a promoted
# variable's definition — there is no scalar `expression` on the declaration
# left to clear, so this is a shape change and nothing else.
function _with_shape(v::ModelVariable, shape::Vector{String})::ModelVariable
    return reconstruct(v; shape = copy(shape))
end
