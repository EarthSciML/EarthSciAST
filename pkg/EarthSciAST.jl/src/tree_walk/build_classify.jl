# tree_walk/build_classify.jl — equation pre-lowering, the build-owned variable classification
# (geometry, inline, materialized and const array observeds), the variable
# partition, and the observed / derivative split with its slot plan.

# ============================================================
# 2b. Build-pipeline stages
# ============================================================
# Each helper below is one stage of `_build_evaluator_impl`, extracted with
# explicit inputs/outputs so the impl body reads as a pipeline. Function names
# follow the stage banners in the impl; bodies are the original blocks.

# ---- Stage: observed synthesis + equation pre-lowering ----
# Three model-level rewrites, in order:
#  1. SYNTHESIS (universal): observed variables may be defined by their
#     `expression` field rather than an explicit equation; synthesize an
#     observed equation `name = expression` for each so-defined observed
#     (skipping any an equation already defines) so they flow through the same
#     ISR-resolution / observed-substitution pipeline as equation-defined
#     observeds. This is the transitive-inlining path that lets a DEEP
#     algebraic chain — e.g. the flattened Rothermel fire-physics chain of a
#     run file — resolve through `_build_evaluator`
#     with NO caller pre-inlining (`_resolve_observed` collapses the chain to a
#     fixed point). Synthesis only adds equations for observeds lacking one,
#     so an equation-defined model is unchanged by it.
#  1b. INDEXED OBSERVED-LHS NORMALIZATION (esm-spec §6.3.1): an observed's
#     defining equation may name it BARE (`y ~ f(…)`) or INDEXED
#     (`aggregate{k}(y[k]) ~ f(…)`); both spellings are normative and neither is
#     restricted by rank. Every owner-bucket collector below tests the syntactic
#     `eq.lhs isa VarExpr`, so an ARRAY-shaped observed written the indexed way
#     matched none of them and hard-errored in `_partition_variables`
#     (`E_TREEWALK_UNSUPPORTED_SHAPE`) on a document Rust and Python both run.
#     `_normalize_indexed_observed_lhs` rewrites the indexed spelling
#     into the bare one ONCE, before any classifier reads an LHS, so exactly one
#     form reaches the rest of the build. Must run BEFORE the WS4 fold and the
#     inline-var collection, which are two of the buckets it feeds.
#  2. ELEMENTWISE ARRAY-OBSERVED FOLD (WS4): fold every array-shaped observed
#     whose lowered defining RHS is elementwise (a level-set's `U_n`, `S_n`, …)
#     into its readers, so a discretization-agnostic PDE leaf can be authored
#     with readable intermediate array fields rather than one inlined `D(ψ,t)`
#     RHS. Producer-defined array observeds (`psi_x`, `grad_mag`) survive for
#     `_array_inline_vars`. Must run BEFORE the whole-array lift so the state
#     equation carries the folded RHS.
#  3. WHOLE-ARRAY DECLARED-SHAPE DERIVATIVE LIFT: a whole-array
#     `D(state) = <array rhs>` over a declared shape is lifted into the
#     per-cell `faq` form the derivative partition consumes (see
#     `_lift_wholearray_deriv_equations`). Spatial-operator zeroing over a
#     structurally-0-D field is done EARLIER, in flatten, so a raw
#     spatial `D` reaching the
#     compiler directly (a hand-built Model, never discretized) still
#     hard-errors as the pipeline-violation guard requires. No-op for a model
#     without a whole-array D.
# Returns `(equations, folded_array_obs)`.
function _prepare_model_equations(model::Model; vi_vars::Set{String} = Set{String}())
    # esm 1.0.0: an observed unknown's defining right-hand side IS an equation
    # (esm-spec §6.3), so there is no variable-level `expression` left to
    # synthesize an equation from — the list is already complete.
    equations = model.equations
    equations = _normalize_indexed_observed_lhs(equations, model; vi_vars = vi_vars)
    equations, folded_array_obs = _fold_elementwise_array_observeds(equations, model)
    let var_shapes = Dict{String, Vector{String}}()
        for (n, v) in model.variables
            v.shape === nothing && continue
            var_shapes[n] = String[String(s) for s in v.shape]
        end
        arrayvars = Set{String}(n for (n, v) in model.variables if _is_array_shape(v.shape))
        equations = _lift_wholearray_deriv_equations(equations, var_shapes, arrayvars)
    end
    return equations, folded_array_obs
end

# ---- Stage: geometry variable discovery ----
# Classify the geometry-related observeds of the model:
#  * `setup_vars` / `defs` — build-once ARRAY observeds (per-pair overlap
#    areas, A_ij, constant reduction tables), materialized at setup and
#    excluded from the ODE partition / observed substitution — build-once
#    functions of the const inputs.
#  * `inline_vars` — live-field geometry observeds: array observeds
#    that are NOT build-once setup vars because they read a live `param_arrays`
#    buffer (the conservative-regrid output F_tgt = A_ij ⊗ F_src / A_j is the
#    motivating case). They are INLINED into the array-state RHS that consumes
#    them, so the build-time `index(faq,…)` reducer collapses
#    `index(F_tgt, j)` to F_tgt's body — yielding the proven array-state
#    aggregate kernel (const A_ij/A_j + live F_src), the met→fire coupling
#    edge. Empty (byte-identical) for files whose geometry outputs are all
#    const-fed (they stay setup vars).
# `has_setup_geometry` gates the setup-vars discovery / materialization.
function _discover_geometry_vars(
        model::Model, equations::Vector{Equation}, g::_DefGraph,
        param_arrays::AbstractDict, vi_vars::Set{String}; index_sets = nothing
    )
    has_geometry_seed = _model_has_setup_join_reduction(equations)
    pre_state_names = setdiff(Set{String}(solver_unknowns(model)), vi_vars)
    has_setup_geometry = has_geometry_seed ||
        _model_has_setup_const_reduction(
        model, g, index_sets,
        union!(copy(pre_state_names), (String(k) for k in keys(param_arrays)))
    )
    setup_vars = Set{String}()
    defs = Dict{String, ASTExpr}()
    inline_vars = Set{String}()
    if has_setup_geometry
        live_param_names = Set{String}(String(k) for k in keys(param_arrays))
        setup_vars, defs, live_tainted =
            _geometry_setup_vars(
            model, g, pre_state_names, live_param_names; index_sets = index_sets
        )
        # GEOMETRY-DERIVED restriction. `live_tainted` is a DOCUMENT-WIDE set:
        # every var transitively reading a live `param_arrays` buffer. The
        # inlining below is meant for the geometry LIVE-FIELD outputs only — the
        # `F_tgt = A_ij ⊗ F_src / A_j` shape that mixes setup-const weights with a
        # live source field and so cannot be materialized at setup. Live taint
        # ALONE does not identify those: in a flattened multi-model document
        # nearly every array observed is live-tainted, because `flatten` merges
        # all models and the met forcing reaches all of them.
        #
        # Without this restriction ONE overlap-area regrid — in ONE model
        # — inlined every live array observed of every UNRELATED model into its
        # readers. Adding an NEI regrid to reseact.esm swept in ~500 observeds
        # across DryDepositionGas / FastJX / WetDeposition / Transport3D,
        # including the whole RHS of the air-mass continuity equation
        # (`divh_fix`, `Mz`, `dPSdt`, `dp`), which would route host equations
        # into the array-equation compiler and its per-cell tier. Geometry in one
        # model must not change how another model's equations compile.
        #
        # Derived = reads a geometry setup var, transitively. The
        # regrid's own outputs still qualify (they read `A_ij`), so the motivating
        # met→fire coupling edge is unchanged.
        geom_derived = _readers_of(g, setup_vars)
        obs_here = Set{String}(observed_unknowns(model))
        # Constant reduction tables alone (`_is_setup_const_reduction`) are
        # not geometry: they inline no live reader.
        for (name, v) in model.variables
            (
                has_geometry_seed && name in obs_here && _is_array_shape(v.shape) &&
                    !(name in setup_vars) &&
                    name in live_tainted && name in geom_derived && haskey(defs, name) &&
                    defs[name] isa OpExpr
            ) || continue
            push!(inline_vars, name)
        end
    end
    return (;
        has_setup_geometry, setup_vars, defs, inline_vars,
    )
end

# ---- Stage: gated live-field geometry observeds → the materialized path ----
# A live-field geometry observed (`inline_vars` above) whose definition holds a
# `join` or `filter` aggregate (the `conservative_overlap_apply_gated` regrid
# over a live source field) cannot be spliced into its reader: the
# `index(obs, j)` beta-reduction declines an aggregate with a join or filter
# (`index(aggregate) with join/filter`), and with no other whole-array route
# the reader's equation is refused. `esm_problem` never meets this, because its
# discrete-cadence cut lifts the observed into a per-refresh cache first; an
# `rhs_program` build has no such cut (its forcing is an argument of every
# call), so the observed stays inline.
#
# Hand such an observed to the promoted-array-observed set instead, so the
# compiled builds give it a buffer filled once per right-hand-side call
# (`_collect_materialized_array_obs`), whose fill compiles the gated aggregate
# on its own (live source gathers included) and whose readers gather the
# buffer. The interpreter inlines every array observed anyway, so nothing
# changes there; an ungated live-field observed keeps the inline path.
#
# Returns the names moved. Such an observed has no inline route back, so one
# that is read but does not get a buffer is refused by name and with the
# reason (`_refuse_unmaterialized_gated`) rather than with the reader's
# `index(aggregate) with join/filter`.
_has_gated_aggregate(e::ASTExpr) = _any_subexpr(e) do x
    x isa OpExpr && (x.join !== nothing || x.join_gates !== nothing || x.filter !== nothing)
end

function _move_gated_geometry_inline_vars!(
        geom_inline_vars::Set{String}, array_inline_vars::Set{String},
        equations::Vector{Equation}
    )
    moved = Set{String}()
    (isempty(geom_inline_vars) || _array_obs_inline_forced()) && return moved
    for eq in equations
        eq.lhs isa VarExpr || continue
        name = (eq.lhs::VarExpr).name
        (name in geom_inline_vars && _has_gated_aggregate(eq.rhs)) || continue
        delete!(geom_inline_vars, name)
        push!(array_inline_vars, name)
        push!(moved, name)
    end
    return moved
end

# Raise for the first (in name order) of the gated live-field geometry
# observeds in `skipped` (name => why its buffer was not made).
function _refuse_unmaterialized_gated(skipped::AbstractDict{String, String})
    isempty(skipped) && return
    name = minimum(keys(skipped))
    throw(
        TreeWalkError(
            "E_TREEWALK_GATED_OBSERVED",
            "array observed '$(name)' is a `join`/`filter` aggregate over a live " *
                "forcing field, which this build can only evaluate into a buffer " *
                "filled once per right-hand-side call (it cannot be spliced into " *
                "its readers), but it gets no buffer: $(skipped[name])"
        )
    )
end

# ---- Stage: promoted array observeds (shape-promotion inlining) ----
# An array-shaped observed defined by a `faq` is inlined into its readers
# via the same index beta-reduction as a live-field geometry observed
# (`index(obs, i…)` collapses to the faq body) — it carries no ODE
# partition slot. This generalizes the geometry `inline_vars` to the
# non-geometry case, so a `promote_downstream_shapes`-lifted physics chain
# (scalar authored, array after promotion) runs with no per-cell runner logic.
# Excludes anything the geometry path already owns. Empty (byte-identical) for
# a system with no array observeds.
#
# The on-disk `faq` spelling (schema v0.8.0) and `makearray` qualify the
# same way when they PRODUCE an array (non-empty `output_idx` / regions): a
# general array-shaped observed authored as an aggregate map — an edge-indexed
# flux field, a ragged-contraction rule output like the MPAS `div(flux)`
# lowering — is exactly the promoted-faq case, just spelled with the
# public op name. A SCALAR reduction (empty `output_idx`) is not an array
# producer and keeps the scalar-observed path.
# A bare transpose also qualifies for per-cell gathers when the build cannot
# fold it into a const array.
function _collect_array_inline_vars(
        model::Model, equations::Vector{Equation},
        geom_setup_vars::Set{String}, geom_inline_vars::Set{String}
    )
    array_inline_vars = Set{String}()
    observed_here = Set{String}(observed_unknowns(model))
    for eq in equations
        eq.lhs isa VarExpr || continue
        name = (eq.lhs::VarExpr).name
        (
            name in geom_setup_vars || name in geom_inline_vars
        ) && continue
        haskey(model.variables, name) || continue
        v = model.variables[name]
        (name in observed_here && _is_array_shape(v.shape)) || continue
        (
            eq.rhs isa OpExpr && (
                (eq.rhs::OpExpr).op in ("faq", "transpose") ||
                    _is_array_producer(eq.rhs)
            )
        ) || continue
        push!(array_inline_vars, name)
    end
    return array_inline_vars
end

# ---- Stage: FACTORED array observeds (the array analogue of the scalar slot) ----
#
# STOP INLINING ARRAY OBSERVEDS INTO EVERY READER. `_collect_array_inline_vars`
# above hands the whole class to the `index(obs, i…)` beta-reduction, which
# splices the observed's WHOLE defining body into each gather site. A
# discretization stencil gathers its operand at many points (a PPM rule reads it
# at 7 offsets, across ~7 `makearray` regions), so ONE array observed is
# duplicated ~50× per reader, and a chain of array observeds nests
# MULTIPLICATIVELY — the build allocates until it is killed before the solve
# starts.
#
# A materialized array observed is instead evaluated ONCE PER RHS CALL into a
# dense buffer, in dependency order, and every reader GATHERS that buffer. The
# buffer lives in the same flat vector as the state (slots `n_states+1…`), so a
# reader's `index(obs, i…)` resolves through the SAME `array_var_info`/`var_map`
# path a state array's gather does: no new node kind, no new access descriptor,
# full affine/stencil coverage, and — because the read compiles to `_NK_STATE` —
# the cadence classifier (const_tier.jl) calls it DYNAMIC for free, which is what
# it must be for a state-dependent field. It is also eltype-generic, so an
# AD-driven `f!` (`Dual` state or `Dual` parameters) differentiates THROUGH the
# buffer instead of truncating it to Float64 (the reason the discrete-cadence
# `pgather` cache — a state-FREE field — could not be reused here).
#
# WHAT STAYS INLINED (every one of these keeps its own path, untouched):
#   * geometry `inline_vars` / setup vars / `const`-op + bare-alias array
#     observeds — none of them is
#     in `array_inline_vars` to begin with;
#   * the discrete-cadence and const-cadence cadence cuts (they are removed from
#     `array_inline_vars` BEFORE this selection runs, so a per-refresh cache is
#     never also a per-call buffer), plus anything a discrete-cadence fill reads
#     (its fill kernel runs outside the RHS, where the buffer is not filled);
#   * an observed whose declared shape does not resolve to concrete extents, or
#     whose defining aggregate's own output ranges are not the dense `1…n` the
#     buffer layout addresses;
#   * every array observed at all under `compiler=:interpreter`, which is the
#     inlining build. Both build forms materialize on the same terms — see the
#     `mat_array_vars` note in `_build_lower_and_classify`.
#
# GHOST CELLS. A materialized observed is a first-class array field of its
# declared shape, so a gather OUTSIDE that shape reads the ghost literal 0.0 —
# identical to the rule for an array STATE, and to a `makearray`-defined
# observed's own "no region covers ⇒ 0" default.
_array_obs_inline_forced() = _compiler_plan_now().name === :interpreter

# Candidate set: the promoted array observeds (post cadence cut) that are not
# read by a discrete-cadence fill. `discrete_defs_refs` is the set of names
# reachable from the discrete fills through the observed definitions.
#
# `why`, when given, receives a reason for each candidate that is READ but not
# materialized (an unread one costs nothing inlined and is not recorded).
function _collect_materialized_array_obs(
        model::Model, equations::Vector{Equation},
        array_inline_vars::Set{String}, discrete_vars::Set{String};
        why::Union{Nothing, Dict{String, String}} = nothing
    )
    (_array_obs_inline_forced() || isempty(array_inline_vars)) && return Set{String}()
    defs = Dict{String, ASTExpr}()
    for eq in equations
        eq.lhs isa VarExpr && (defs[(eq.lhs::VarExpr).name] = eq.rhs)
    end
    # Names a discrete-cadence fill can reach: its fill kernel runs at refresh
    # time (outside `f!`), where a per-call observed buffer holds stale values —
    # so anything it reads keeps the inline path.
    blocked = Set{String}()
    if !isempty(discrete_vars)
        frontier = String[n for n in discrete_vars]
        while !isempty(frontier)
            n = pop!(frontier)
            haskey(defs, n) || continue
            for r in _referenced_var_names(defs[n])
                r in blocked && continue
                push!(blocked, r); push!(frontier, r)
            end
        end
    end
    # LIVE names: everything the non-observed equations (the `D`/`ic` stream and
    # the initialization equations) can reach through the observed definitions.
    # An observed NOTHING reads costs nothing while it is inlined — its body is
    # spliced into no reader — but a buffer would be refilled on every RHS call
    # forever. So an unread diagnostic array observed keeps the inline path.
    live = Set{String}()
    let frontier = String[]
        seed(e) = append!(frontier, collect(_referenced_var_names(e)))
        for eq in equations
            eq.lhs isa VarExpr && continue      # an observed definition, not a root
            seed(eq.lhs); seed(eq.rhs)
        end
        for eq in model.initialization_equations
            seed(eq.lhs); seed(eq.rhs)
        end
        while !isempty(frontier)
            n = pop!(frontier)
            n in live && continue
            push!(live, n)
            haskey(defs, n) && seed(defs[n])
        end
    end
    out = Set{String}()
    observed_here = Set{String}(observed_unknowns(model))
    for name in array_inline_vars
        name in live || continue
        if name in blocked
            why === nothing || (
                why[name] = "a discrete-cadence fill reads it, and that fill " *
                    "runs outside the right-hand side, where the buffer is not filled"
            )
            continue
        end
        v = get(model.variables, name, nothing)
        if !(v !== nothing && name in observed_here && _is_array_shape(v.shape))
            why === nothing || (why[name] = "it is not an array-shaped observed")
            continue
        end
        push!(out, name)
    end
    # STRUCTURAL positions (mirrors the scalar slot plan's `_obs_structural_refs!`):
    # a buffer read is a RUNTIME value, so an observed referenced where the build
    # needs a CONCRETE value — a gather SUBSCRIPT, an aggregate range bound, an
    # integral bound, a value-invention key — must stay
    # inlined. The gather TARGET itself is exempt: `index(obs, i…)` naming a
    # materialized observed is exactly the buffer read.
    if !isempty(out)
        dynamic = _state_time_observeds(defs, Set{String}(ode_states(model)), out)
        hits = Set{String}()
        seen = _ObsSeen()
        for eq in equations
            _array_obs_structural_refs!(eq.lhs, out, hits, seen)
            _array_obs_structural_refs!(eq.rhs, out, hits, seen)
        end
        # A state- or time-dependent observed read in a subscript is a
        # run-time gather either way, so only its other structural uses keep
        # it inlined.
        if !isempty(dynamic)
            setdiff!(hits, dynamic)
            seen = _ObsSeen()
            for eq in equations
                _array_obs_structural_refs!(
                    eq.lhs, dynamic, hits, seen;
                    runtime_subscripts = true
                )
                _array_obs_structural_refs!(
                    eq.rhs, dynamic, hits, seen;
                    runtime_subscripts = true
                )
            end
        end
        # esm 1.0.0: an observed's definition is an equation, so the loop above
        # has already seen every one of them.
        setdiff!(out, hits)
        if why !== nothing
            for name in hits
                why[name] = "it is read where the build needs a concrete value " *
                    "(a gather subscript, a range or integral bound, a key or a " *
                    "table axis), which a per-call buffer cannot supply"
            end
        end
    end
    return out
end

# The names in `cands` whose definition reads a continuous state or `t`,
# directly or through the other observeds in `defs`.
function _state_time_observeds(
        defs::AbstractDict, state_names::Set{String},
        cands::Set{String}
    )
    memo = Dict{String, Bool}()
    function dyn(n::String, stack::Set{String})
        haskey(memo, n) && return memo[n]
        (haskey(defs, n) && !(n in stack)) || return false
        push!(stack, n)
        d = defs[n]
        st, tm = _def_state_time_refs(d, state_names)
        r = st || tm || _anyof(m -> m != n && dyn(m, stack), _referenced_var_names(d))
        delete!(stack, n)
        memo[n] = r
        return r
    end
    return Set{String}(n for n in cands if dyn(n, Set{String}()))
end

# STRUCTURAL-POSITION scan for ARRAY observeds — `_obs_structural_refs!`
# (build_classify.jl) with one exemption: that walker flags EVERYTHING under an
# `index` gather, including the gather's own target, because a scalar
# observed's value must be build-time-known there. For an ARRAY observed the
# target IS the array being read, so a bare-name target that names a candidate
# is skipped while every SUBSCRIPT (and a computed target) still flags.
# Shares the (node, mode) visited-set discipline of `_obs_structural_refs!`.
function _array_obs_structural_refs!(
        e::ASTExpr, names::Set{String}, hits::Set{String},
        seen; runtime_subscripts::Bool = false
    )
    e isa OpExpr || return nothing
    bits = get(seen, e, 0x00)
    bits == 0x00 || return nothing   # spine-visited, or mark-all (its superset)
    seen[e] = _OBS_SEEN_SPINE
    if e.op == "index"
        # Only the SUBSCRIPTS are build-time-resolved (`_eval_const_int`, which
        # knows loop indices and const arrays). The gather TARGET is either the
        # array being read — a materialized observed's buffer, resolved by name —
        # or an inline array PRODUCER whose region/aggregate body is an ordinary
        # EXPRESSION position (`_resolve_index_of_{makearray,faq}` resolves
        # the selected value through `_resolve_indices`), so recurse into it
        # rather than flagging its whole subtree. With `runtime_subscripts`,
        # a subscript is scanned like any expression: the caller passes only
        # observeds that read the state or `t`, whose value no build knows, so
        # a subscript reading them is a run-time gather (`_subscript_is_runtime`)
        # whether they are inlined or read from their buffer.
        for k in 2:length(e.args)
            runtime_subscripts ?
                _array_obs_structural_refs!(
                    e.args[k], names, hits, seen;
                    runtime_subscripts = true
                ) :
                _obs_mark_refs!(e.args[k], names, hits, seen)
        end
        isempty(e.args) ||
            _array_obs_structural_refs!(
            e.args[1], names, hits, seen;
            runtime_subscripts = runtime_subscripts
        )
        return nothing
    end
    if e.ranges !== nothing
        for (_, v) in e.ranges
            v isa AbstractVector || continue
            for b in v
                b isa ASTExpr && _obs_mark_refs!(b, names, hits, seen)
            end
        end
    end
    e.lower === nothing || _obs_mark_refs!(e.lower::ASTExpr, names, hits, seen)
    e.upper === nothing || _obs_mark_refs!(e.upper::ASTExpr, names, hits, seen)
    e.key === nothing || _obs_mark_refs!(e.key::ASTExpr, names, hits, seen)
    for a in _operands(e)
        _array_obs_structural_refs!(
            a, names, hits, seen;
            runtime_subscripts = runtime_subscripts
        )
    end
    e.expr_body === nothing ||
        _array_obs_structural_refs!(
        e.expr_body::ASTExpr, names, hits, seen;
        runtime_subscripts = runtime_subscripts
    )
    e.filter === nothing ||
        _array_obs_structural_refs!(
        e.filter::ASTExpr, names, hits, seen;
        runtime_subscripts = runtime_subscripts
    )
    if e.values !== nothing
        for v in e.values
            _array_obs_structural_refs!(
                v, names, hits, seen;
                runtime_subscripts = runtime_subscripts
            )
        end
    end
    return nothing
end

# The dense per-dimension extents of a materialized array observed's buffer.
#
# The DECLARED SHAPE is the authority whenever it resolves: it is what a reader's
# `index(obs, i…)` addresses, and therefore what the buffer's cell keys must
# match. A `faq` producer ALSO carries its own (already
# range-resolved) output ranges — those size the buffer when there is no
# resolvable declared shape, and when both are present they must AGREE. A
# disagreement means the producer does not actually cover the declared field —
# the corpus has one such observed, whose `output_idx` repeats a single loop
# name (`["gl", "gl"]`) so its "rank-2" output ranges are really one axis twice.
# Inlining tolerates that (the gather beta-reduces per reader); a buffer cannot,
# so decline and leave it inlined.
#
# Returns `nothing` — i.e. keep the inline path — when the extents do not
# resolve, disagree, are not a dense `1…n` per dimension (the layout the
# column-major cell keys address), or repeat an output-index name.
function _materialized_obs_dims(
        def::ASTExpr, shape, index_sets::AbstractDict,
        derived_extents::AbstractDict
    )
    declared = _declared_shape_extents(shape, index_sets, derived_extents)
    produced = nothing
    if def isa OpExpr && _is_faq_op((def::OpExpr).op)
        dop = def::OpExpr
        idx_names = _output_idx_strings(dop)
        if !isempty(idx_names)
            length(unique(idx_names)) == length(idx_names) || return nothing
            ranges = _ranges_dict(dop)
            dims = Int[]
            for n in idx_names
                haskey(ranges, n) || return nothing
                r = try
                    _expand_int_range(ranges[n])
                catch err
                    # A range this pass cannot read as a dense integer interval
                    # means "not a declared-dims producer" — decline. Running
                    # out of memory does not: declining here would hide that
                    # behind a shape the caller reports some other way.
                    _is_resource_error(err) && rethrow()
                    return nothing
                end
                (!isempty(r) && first(r) == 1 && _is_unit_run(r)) || return nothing
                push!(dims, length(r))
            end
            produced = dims
        end
    end
    if declared !== nothing && produced !== nothing
        declared == produced || return nothing
    end
    dims = declared === nothing ? produced : declared
    dims === nothing && return nothing
    # A `makearray` producer must be indexable at the declared rank (its regions
    # carry one `[lo, hi]` pair per dimension); a mismatch would only surface as
    # a gather-arity error deep in the fill compile, so decline here instead.
    if def isa OpExpr && (def::OpExpr).op == "makearray"
        regs = (def::OpExpr).regions
        (regs === nothing || isempty(regs) || length(regs[1]) != length(dims)) &&
            return nothing
    end
    return dims
end

# ---- Stage: const-op array observeds (in-file polygon rings / source fields) ----
# A `const`-op observed with an ARRAY shape (`src_poly[cell,vert,coord]`, a
# `F_src[cell]` field, an MPAS mesh subsystem's connectivity/geometry factors)
# is build-time literal data, not a scalar observed and not a state.
# Materialize each into the const-array registry (so a fused-leaf aggregate
# gathers `index(src_poly,i)` at setup and an ODE reads `index(F_src,i)`) and
# exclude it from the ODE partition. This holds with or without setup
# geometry (a geometry-free unstructured document's mesh data, esm-spec §4.6).
#
# When `register_coord_buffers` (setup geometry or value invention present):
# a build-time BINNING-COORDINATE observed (an inline reduce aggregate over
# geometry, e.g. `src_lon[i] = min_v src_poly[i,v,1]`) is derived once by the
# AbstractDict front-door and supplied to the typed build as a `const_arrays`
# entry (RFC §8.6.1 purity). Like a `const`-op ring stack it is build-time
# literal data feeding the broad phase, so materialize it into the const
# arrays and drop it from the ODE partition — not a scalar observed / state.
# Returns `(const_obs_vars, const_obs_arrays)`.
function _collect_const_obs_arrays(
        model::Model, const_arrays::AbstractDict,
        register_coord_buffers::Bool
    )
    const_obs_vars = Set{String}()
    const_obs_arrays = Dict{String, Array{Float64}}()
    obs_defs = observed_definitions(model)
    for (name, v) in model.variables
        defn = get(obs_defs, name, nothing)
        (
            defn !== nothing && _is_array_shape(v.shape) &&
                _is_const_op(defn)
        ) || continue
        const_obs_arrays[name] = _const_op_to_array((defn::OpExpr).value)
        push!(const_obs_vars, name)
    end
    if register_coord_buffers
        for (name, v) in model.variables
            defn = get(obs_defs, name, nothing)
            (
                defn !== nothing && _is_array_shape(v.shape) &&
                    haskey(const_arrays, name) && !(name in const_obs_vars) &&
                    !_is_const_op(defn)
            ) || continue
            const_obs_arrays[name] = Array{Float64}(const_arrays[name])
            push!(const_obs_vars, name)
        end
    end
    return const_obs_vars, const_obs_arrays
end

# ---- Stage: bare-alias array observeds (keyed-factor re-exposure, §4.6) ----
# An array-shaped observed defined by a BARE reference to another array
# variable (`nEdgesOnCell := mesh.nEdgesOnCell` — the MPAS wiring contract:
# a mesh subsystem's const factors re-exposed under the bare names a grid's
# ragged index set and rule bodies resolve) is build-time data under a second
# name. Follow the alias chain to its const-backed array and register the
# alias as a const array too, excluded from the ODE partition. An alias names
# its operand's axes by index set (esm-spec §4.3.4), so values whose declared
# axes are a permutation of the alias's are permuted into the alias's order
# (`_alias_in_own_axes`). A `transpose` or integer-shape `reshape` of such an
# operand (esm-spec §4.3.5) is build-time data too and is folded the same way.
# Only chains ending at a `const`-op observed / caller `const_arrays` entry
# resolve. A transpose the build cannot fold uses per-cell gathers.
# Mutates `const_obs_arrays` and `const_obs_vars` and removes folded
# transposes from `array_inline_vars`.
function _register_bare_alias_arrays!(
        const_obs_arrays::Dict{String, Array{Float64}},
        const_obs_vars::Set{String},
        model::Model, equations::Vector{Equation};
        const_arrays::AbstractDict,
        geom_setup_vars::Set{String}, geom_inline_vars::Set{String},
        array_inline_vars::Set{String}
    )
    alias_defs = Dict{String, ASTExpr}()
    for eq in equations
        eq.lhs isa VarExpr && (alias_defs[(eq.lhs::VarExpr).name] = eq.rhs)
    end
    obs_defs = observed_definitions(model)
    declared(n) = (v = get(model.variables, n, nothing); v === nothing ? nothing : v.shape)
    # `(values, declared axes of the values)` of a const-backed expression, or
    # `nothing`. `depth` caps an alias cycle.
    function resolve(e::ASTExpr, depth::Int)
        depth > length(alias_defs) + 1 && return nothing
        if e isa VarExpr
            tgt = (e::VarExpr).name
            if haskey(const_obs_arrays, tgt)
                return const_obs_arrays[tgt], declared(tgt)
            elseif haskey(const_arrays, tgt)
                return Array{Float64}(const_arrays[tgt]), declared(tgt)
            elseif get(obs_defs, tgt, nothing) !== nothing && _is_const_op(obs_defs[tgt])
                return _const_op_to_array((obs_defs[tgt]::OpExpr).value), declared(tgt)
            end
            rhs = get(alias_defs, tgt, nothing)
            rhs === nothing && return nothing
            r = resolve(rhs, depth + 1)
            r === nothing && return nothing
            return _alias_in_own_axes(r[1], declared(tgt), r[2]), declared(tgt)
        elseif e isa OpExpr && (e::OpExpr).op in ("transpose", "reshape") &&
                length((e::OpExpr).args) == 1
            o = e::OpExpr
            r = resolve(o.args[1], depth + 1)
            r === nothing && return nothing
            x = r[1]
            if o.op == "transpose"
                return permutedims(x, _transpose_perm(o, ndims(x)) .+ 1), nothing
            end
            (o.shape === nothing || !all(d -> d isa Integer, o.shape)) && return nothing
            ext = Int[Int(d) for d in o.shape]
            prod(ext) == length(x) || return nothing
            return reshape(x, ext...), nothing
        end
        return nothing
    end
    for (name, v) in model.variables
        (haskey(obs_defs, name) && _is_array_shape(v.shape)) || continue
        (
            name in const_obs_vars || name in geom_setup_vars ||
                name in geom_inline_vars
        ) && continue
        rhs = get(alias_defs, name, nothing)
        (
            rhs isa VarExpr ||
                (rhs isa OpExpr && (rhs::OpExpr).op in ("transpose", "reshape"))
        ) || continue
        r = resolve(rhs, 0)
        r === nothing && continue
        const_obs_arrays[name] = _alias_in_own_axes(r[1], v.shape, r[2])
        push!(const_obs_vars, name)
        # A folded transpose is already available to every reader as a const array.
        delete!(array_inline_vars, name)
    end
    return nothing
end

# Values laid out in the declared axes `src` (index-set names), in the axis
# order `own` declares: `matrix: [cols, rows]` read as `permuted: [rows, cols]`
# is `permuted[r, c] = matrix[c, r]` (esm-spec §4.3.4, axis order is
# immaterial). Anything that is not one permutation of the same named axes
# keeps its layout.
function _alias_in_own_axes(arr::AbstractArray, own, src)
    (own === nothing || src === nothing) && return Array{Float64}(arr)
    own_axes, src_axes = String[string(a) for a in own], String[string(a) for a in src]
    (
        own_axes != src_axes && length(own_axes) == ndims(arr) && allunique(own_axes) &&
            sort(own_axes) == sort(src_axes)
    ) || return Array{Float64}(arr)
    return permutedims(arr, [findfirst(==(a), src_axes) for a in own_axes])
end

# ---- Stage: variable partition ----
# Split `model.variables` into the ODE partition: scalar parameter names
# (sorted), scalar observed names, state-variable names, and the scalar
# parameters whose value arrives as data. A variable a build mechanism owns
# (`_partition_owner`) carries no partition slot. An array-shaped parameter must
# be array-backed (const data or a live `param_arrays` buffer; the scalar `p`
# tuple stays homogeneous Float64); an array-shaped observed must be owned.
function _partition_variables(
        model::Model, cls::_VariableClasses;
        vi_vars::Set{String}, const_arrays::AbstractDict, param_arrays::AbstractDict
    )
    param_names = String[]
    observed_names = String[]
    state_var_names = Set{String}()
    # Scalar parameters whose value arrives as data (`_scalar_supplied_data`),
    # with their build-time value; they take no `p` slot.
    supplied_scalars = Dict{String, Float64}()
    # The unknown split is derived (esm-spec §6.3.1): an ODE state or an
    # algebraic unknown occupies a slot the solver integrates or solves; an
    # observed unknown is eliminable and gets the observed bucket.
    observed_here = Set{String}(observed_unknowns(model))
    unknown_state_names = Set{String}(solver_unknowns(model))
    for (name, v) in model.variables
        _partition_owner(cls, vi_vars, name) === nothing || continue
        if name in unknown_state_names
            push!(state_var_names, name)
        elseif v.type == ParameterVariable
            # EVERY parameter lowers the same way here — constant, sampled, or
            # discrete-cadence: it is a solver-side value the update machinery
            # may rewrite at a cadence boundary, never a differentiated slot.
            # Array-shaped ⇒ it must be backed by a live forcing buffer
            # (`param_arrays`) or const data; scalar ⇒ an ordinary scalar
            # parameter slot. The taint seed for the discrete-materialize cut is
            # `keys(param_arrays)` (the buffers actually supplied), so declaring
            # the update changes no cadence semantics — it only stops the name
            # from looking like a typo.
            if _is_array_shape(v.shape)
                # An array-shaped parameter is supported only when supplied as
                # const data (e.g. polygon vertex rings, or the connectivity /
                # coordinate factors
                # a value-invention key is computed from, §5.2) OR as a live
                # forcing buffer via `param_arrays` (a discrete-cadence loader
                # buffer). Either way it is array-backed, not a scalar
                # parameter, so it is NOT added to param_names.
                haskey(const_arrays, name) || haskey(param_arrays, name) ||
                    throw(_missing_data_error(name, v))
            else
                _refuse_array_data_for_scalar(name, v, const_arrays, param_arrays)
                a = _scalar_supplied_data(name, const_arrays, param_arrays)
                if a === nothing
                    push!(param_names, name)
                else
                    supplied_scalars[name] = Float64(first(a))
                end
            end
        elseif name in observed_here
            if _is_array_shape(v.shape)
                # Every supported array-shaped observed is owned (and skipped)
                # above.
                throw(TreeWalkError("E_TREEWALK_UNSUPPORTED_SHAPE", name))
            else
                push!(observed_names, name)
            end
        end
    end
    sort!(param_names)
    return param_names, observed_names, state_var_names, supplied_scalars
end

# ---- Stage: observed substitution / derivative-equation split ----
# Partition the surviving equations into derivative equations (scalar,
# indexed, and faq `D` forms) and the observed substitution map, then
# resolve observed-into-observed references to a fixed point. A live-field
# geometry observed (F_tgt …) or a promoted array observed enters the
# substitution map as a faq value; `index(obs, j)` in a reader
# beta-reduces to its body via `_resolve_indices` (
# shape-promotion). Returns an `_ObservedSplit`; its `raw` map preserves the author-declared observed-into-observed references so the
# scalar-slot plan (`_plan_observed_slots`) can compile each observed once as a
# named prelude def instead of splicing the resolved chain into every reader.
function _split_observed_and_derivatives(
        equations::Vector{Equation}, observed_names::Vector{String},
        cls::_VariableClasses, mat_array_vars::AbstractSet{String},
        array_shaped_vars::AbstractSet{String}
    )
    geom_setup_vars = cls.geom_setup_vars
    geom_inline_vars = cls.geom_inline_vars
    array_inline_vars = cls.array_inline_vars
    observed_exprs = Dict{String, ASTExpr}()
    # FACTORED array observeds are pulled OUT of the substitution map: their
    # readers gather the buffer by name (`index(obs, i…)` → a slot read), so
    # inlining their bodies is exactly what the buffer exists to avoid.
    mat_defs = Dict{String, ASTExpr}()
    derivative_eqs = Equation[]
    for eq in equations
        if eq.lhs isa VarExpr && (eq.lhs::VarExpr).name in mat_array_vars
            mat_defs[(eq.lhs::VarExpr).name] = eq.rhs
            continue
        end
        if eq.lhs isa VarExpr && (eq.lhs::VarExpr).name in geom_setup_vars
            # A build-once setup array (per-pair area / A_ij / …) — materialized
            # into a const_array at setup (RFC §6.1); not a scalar observed and
            # produces no ODE.
            continue
        elseif _is_scalar_D_lhs(eq.lhs)
            push!(derivative_eqs, eq)
        elseif _is_indexed_D_lhs(eq.lhs) || _is_faq_D_lhs(eq.lhs)
            push!(derivative_eqs, eq)
        elseif isa(eq.lhs, VarExpr) && (
                eq.lhs.name in observed_names ||
                    eq.lhs.name in geom_inline_vars ||
                    eq.lhs.name in array_inline_vars
            )
            observed_exprs[eq.lhs.name] = eq.rhs
        elseif first(_lhs_role(eq.lhs)) === :implicit &&
                !_is_spatial_derivative(_lhs_unwrap(eq.lhs))
            # An implicit equation constrains its operands without defining any
            # of them; this evaluator has no algebraic solve (esm-spec §9.6.6).
            throw(
                TreeWalkError(
                    ERROR_CODES.UNSUPPORTED_CONSTRUCT,
                    "implicit equation `$(eq)` is not " *
                        "supported by the Julia tree-walk evaluator; refusing " *
                        "the build rather than running the model without it"
                )
            )
        elseif eq.lhs isa VarExpr
            # A bare LHS naming no observed: a parameter, or a state.
            throw(
                TreeWalkError(
                    "E_TREEWALK_UNSUPPORTED_EQUATION",
                    "equation `$(first(string(eq), 200))`: its left-hand side " *
                        "'$((eq.lhs::VarExpr).name)' " *
                        "is not an unknown this equation can define (esm-spec §6.3.1): an " *
                        "equation defines an unknown, and a parameter takes its value from " *
                        "its default, an override or a coupling"
                )
            )
        else
            # Any other unsupported equation form (a spatial derivative LHS).
            throw(
                TreeWalkError(
                    "E_TREEWALK_UNSUPPORTED_EQUATION",
                    _equation_tag(eq)
                )
            )
        end
    end
    # A CAUSAL SELF-REFERENCE is not a cycle (esm-spec §4.3.1.1), and it must
    # not reach `_resolve_observed` — which would substitute the body into
    # itself, hit its iteration cap, and report `E_TREEWALK_OBSERVED_CYCLE` for
    # a document the spec calls acyclic. A recurrence is materialized (its fill
    # is an ordered sweep, recurrence_sweep.jl), so it sits in `mat_defs`; one
    # left in the substitution map is one whose buffer could not be laid out,
    # and is refused here by name. A bare self-reference keeps the cycle
    # diagnosis it earns.
    _decline_unmaterialized_recurrences(observed_exprs, array_shaped_vars)
    return _ObservedSplit(
        derivative_eqs, _resolve_observed(observed_exprs), observed_exprs, mat_defs
    )
end

# Fail closed on a recurrence definition that did not become a materialized
# observed. Its cells are defined by one another, so there is no inlined form of
# it (CONFORMANCE_SPEC §5.19.2): without the buffer its sweep writes, it cannot
# be evaluated at all, and declining loudly is the only correct behaviour.
function _decline_unmaterialized_recurrences(
        observed_exprs::Dict{String, ASTExpr},
        array_shaped_vars
    )
    for name in sort!(collect(keys(observed_exprs)))
        # CANDIDACY, exactly as CONFORMANCE_SPEC §5.19.5 defines it: an
        # array-shaped unknown with at least one `index` self-read, well
        # founded or not. A scalar self-reference has no axis to fold along
        # and can never be a recurrence, so it keeps whatever diagnosis it
        # had — the self-edge exemption must not weaken cycle handling.
        name in array_shaped_vars || continue
        recurrence_self_reference_kind(name, observed_exprs[name]; templates = _build_templates()) === :indexed || continue
        throw(
            TreeWalkError(
                "E_TREEWALK_UNSUPPORTED_RECURRENCE",
                "'$name' is defined by a causal self-reference (esm-spec §4.3.1.1): its " *
                    "own right-hand side reads `index($name, …)`. This is a well-founded " *
                    "recurrence, NOT a dependency cycle, and it is evaluated by an ordered " *
                    "sweep into a buffer laid out over its frame — but this build could not " *
                    "lay one out: its defining `faq`'s output ranges are not the dense `1…n` " *
                    "box of its declared shape, or it is owned by a mechanism that builds it " *
                    "some other way (a setup-time geometry array, a discrete-cadence cache)."
            )
        )
    end
    return nothing
end

# ---- Stage: scalar-observed slot plan (named prelude defs) ----
#
# STOP INLINING SCALAR OBSERVEDS. The author-declared name of a scalar observed
# IS a sharing declaration — splicing its body into every reader erases the name
# and then several passes (scalar CSE plus the access-kernel invariant/per-cell CSE
# tiers) re-discover the
# sharing structurally. Instead each safe scalar observed compiles ONCE as a
# NAMED PRELUDE DEF (an ordinary `_NK_CACHED` slot in the scalar CSE prelude,
# evaluated in dependency order before the equations — see `_cse_compile_scalar`);
# every scalar-equation reader references the slot.
#
# WHAT STAYS INLINED (falls back to today's `_sub_preserving` splice, i.e. the
# entry is left in the `inline` map):
#   * ARRAY-valued observeds (faq/makearray producers, geometry live fields,
#     promoted array observeds) — the `index(obs, i)` beta-reduction path is
#     untouched by design;
#   * LEAF bodies (a bare variable/literal alias) — a slot would cost a store +
#     a read to replace a bare leaf read;
#   * STRUCTURAL references — an observed read where the build needs a concrete
#     value at build time (a gather subscript, a range bound; see
#     `_obs_structural_refs!`);
#   * GUARD-ONLY references — the prelude is unconditional while the scalar
#     walkers are lazy for `ifelse`/`and`/`or`, so an observed referenced ONLY
#     under guards must not be hoisted into unconditional evaluation (same rule
#     the CSE pass applies per-key; see `_count_obs_refs!`). The demotion is a
#     fixed point: a slot kept alive only by a demoted def's references is
#     demoted in turn, so every surviving slot has an unconditional evaluation
#     site in the pre-slot walk — hoisting it introduces no new throw/NaN.
#
# The ARRAY paths (faq kernels, stencil/affine builds, discrete-cadence
# fills) receive the full resolved map and inline every observed; a
# kernel's inlined copy of a slotted observed is later collapsed onto the
# observed's slot by `_share_kernel_invariants!` when the value numbers match.
#
# Returns `(; defs, inline, n_inlined)`:
#   defs      — dependency-ordered `name => body` pairs; each body is the RAW
#               observed RHS with only the non-slot observeds substituted (so
#               slot-to-slot references stay by-name and compile to slot reads);
#   inline    — the substitution map for SCALAR equations: `resolved_obs` minus
#               the slotted names (`nothing` ⇔ no slots, so the caller passes
#               `resolved_obs` through untouched — byte-identical build);
#   n_inlined — observed equations NOT slotted (array + leaf + demoted).
function _plan_observed_slots(
        derivative_eqs::Vector{Equation},
        raw_obs::Dict{String, ASTExpr},
        resolved_obs::Dict{String, ASTExpr},
        observed_names::Vector{String}
    )
    n_total = length(raw_obs)
    none = (; defs = Pair{String, ASTExpr}[], inline = nothing, n_inlined = n_total)
    isempty(raw_obs) && return none
    obs_scalar = Set{String}(String(n) for n in observed_names)
    # (1) Candidates: author-declared scalar observeds with an interior (OpExpr)
    # body whose resolved form is still scalar-valued.
    candidates = Set{String}()
    for (name, body) in raw_obs
        name in obs_scalar || continue
        body isa OpExpr || continue
        _is_array_producer(resolved_obs[name]) && continue
        push!(candidates, name)
    end
    isempty(candidates) && return none
    scalar_rhs = ASTExpr[
        eq.rhs for eq in derivative_eqs
            if _is_scalar_D_lhs(eq.lhs) || _is_indexed_D_lhs(eq.lhs)
    ]
    # (2) Structural demotion: a candidate read in a build-time position (in a
    # scalar reader or in another candidate's def) must stay inlined.
    hits = Set{String}()
    for rhs in scalar_rhs
        _obs_structural_refs!(rhs, candidates, hits)
    end
    for name in candidates
        _obs_structural_refs!(raw_obs[name], candidates, hits)
    end
    setdiff!(candidates, hits)
    # (3) Guard-safety fixed point over the SCALAR-path reference graph. A
    # demoted candidate's def is inlined via its RESOLVED body (which contains
    # no observed names), so its references simply drop out of the next round.
    while !isempty(candidates)
        tot = Dict{String, Int}()
        unc = Dict{String, Int}()
        for rhs in scalar_rhs
            _count_obs_refs!(rhs, candidates, tot, unc)
        end
        for name in candidates
            _count_obs_refs!(raw_obs[name], candidates, tot, unc)
        end
        demote = String[n for n in candidates if get(unc, n, 0) == 0]
        isempty(demote) && break
        setdiff!(candidates, demote)
    end
    isempty(candidates) && return none
    # (4) The scalar-path inline map (non-slot observeds only) and the
    # dependency-ordered defs. A def's references to non-slot observeds are
    # substituted with their RESOLVED bodies; references to other slots stay
    # by-name. Cycles are impossible here (`_resolve_observed` already threw),
    # but fail loudly rather than assume.
    inline = Dict{String, ASTExpr}(
        k => v for (k, v) in resolved_obs
            if !(k in candidates)
    )
    order = _dependency_order(
        sort!(collect(candidates)),
        n -> String[r for r in _referenced_var_names(raw_obs[n]) if r in candidates];
        on_cycle = done -> throw(
            TreeWalkError(
                "E_TREEWALK_OBSERVED_CYCLE",
                join(sort!(collect(setdiff(candidates, done))), ",")
            )
        )
    )
    defs = Pair{String, ASTExpr}[]
    for n in order
        body = raw_obs[n]
        isempty(inline) || (body = _sub_preserving(body, inline))
        push!(defs, n => body)
    end
    return (; defs, inline, n_inlined = n_total - length(defs))
end

# Resolve observed-into-observed substitutions to a fixed point. After
# this runs, no RHS in the returned dict contains another observed
# variable as a free variable — so inlining observed names into a
# model equation is a single `_sub_preserving` call. Iteration cap =
# depth of the longest valid chain; exceeding it means there's a cycle.
#
# CONSUMERS: the ARRAY paths (faq kernels, stencil /
# affine builds, discrete-cadence fills) and the inline FALLBACK of the scalar
# path still splice these fully-resolved bodies. The scalar path's primary
# mechanism is now the NAMED PRELUDE SLOT (`_plan_observed_slots`, build_classify.jl),
# which compiles each safe scalar observed's RAW body once and leaves its
# references by-name — this resolved map then covers only the non-slot names.
function _resolve_observed(obs::Dict{String, ASTExpr})
    resolved = Dict{String, ASTExpr}()
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
            # THROUGH a faq body is detected — a live-field geometry
            # observed reads its upstream regrid output inside a faq, which
            # `free_variables` treats as bound-away and would leave un-inlined
            #. For a scalar value the two agree, so scalar observeds are
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
    throw(
        TreeWalkError(
            "E_TREEWALK_OBSERVED_CYCLE",
            join(sort(collect(keys(obs))), ",")
        )
    )
end

# ============================================================
# 5a. Scalar-observed slot planning walkers (named prelude defs)
# ============================================================
#
# A SCALAR observed compiles as a NAMED PRELUDE DEF (one `_NK_CACHED` slot,
# evaluated once per RHS call in dependency order) instead of being spliced
# into every reader — see `_plan_observed_slots` (build_classify.jl) for the plan and
# `_cse_compile_scalar` (scalar_cse.jl) for the compile. These two walkers are the
# plan's safety analyses over the RAW (pre-`_resolve_indices`) trees.

# (node, MODE)-memoized visited set for the two-mode structural scan below.
# Node identity ALONE is NOT a sound memo key here: the SAME shared node can
# sit in a STRUCTURAL position under one parent (mark-ALL mode — every
# candidate reference anywhere below it is flagged) and in an EXPRESSION
# position under another (SPINE mode — only its structural sub-positions
# flag), and the two modes collect different subsets. So each node carries a
# bit per mode. Mark-all hits are a SUPERSET of spine hits for the same node
# (every structural-position reference is a reference), so a node already
# scanned in mark-all mode is skippable in either mode, while a node scanned
# only as spine must still be re-entered for a later mark-all visit.
# Both modes are monotone set-collectors into the shared `hits`, so skipping
# a repeat visit of the same (node, mode) never loses a name — this is what
# makes the walk O(nodes + edges) on the DAGs template lowering produces
# (raw observed bodies keep subtree sharing by reference) instead of
# once-per-path exponential.
const _OBS_SEEN_SPINE = 0x01
const _OBS_SEEN_MARKALL = 0x02
const _ObsSeen = IdDict{OpExpr, UInt8}

# Collect (into `hits`) every candidate observed name referenced anywhere in
# `e` — the transitive-name primitive of the structural scan below. Same
# name/`wrt` collection as `_referenced_var_names`, but threaded through the
# shared (node, mode) visited set so repeated structural positions over one
# shared sub-DAG are scanned once.
function _obs_mark_refs!(
        e::ASTExpr, names::Set{String}, hits::Set{String},
        seen::_ObsSeen
    )
    if e isa VarExpr
        e.name in names && push!(hits, e.name)
        return nothing
    end
    e isa OpExpr || return nothing
    bits = get(seen, e, 0x00)
    (bits & _OBS_SEEN_MARKALL) == 0x00 || return nothing
    seen[e] = bits | _OBS_SEEN_MARKALL
    wrt = e.wrt
    wrt === nothing || (wrt in names && push!(hits, wrt))
    foreach_child(c -> _obs_mark_refs!(c, names, hits, seen), e)
    return nothing
end

# STRUCTURAL-POSITION scan: collect every candidate name referenced where the
# build needs a concrete value at BUILD time — a slot read (a runtime value)
# cannot stand in there, so such an observed must stay inlined:
#   * `index` gather args — the target is resolved and the subscripts are folded
#     by `_eval_const_int`, which knows only loop indices and const arrays;
#   * aggregate range BOUNDS (`_expand_int_range_dyn` folds expression bounds);
#   * `lower`/`upper` integral bounds and value-invention `key`s.
# `expr_body` / `filter` / `values` / plain args are EXPRESSION positions — an
# observed reference there survives to the compiled tree and reads its slot —
# so the scan recurses rather than flags. Visits are (node, mode)-memoized via
# `seen` (see the `_ObsSeen` note above): a spine re-entry of an already
# spine- or mark-all-visited node adds nothing to `hits` and is skipped.
function _obs_structural_refs!(
        e::ASTExpr, names::Set{String}, hits::Set{String},
        seen::_ObsSeen = _ObsSeen()
    )
    e isa OpExpr || return nothing
    bits = get(seen, e, 0x00)
    bits == 0x00 || return nothing   # spine-visited, or mark-all (its superset)
    seen[e] = _OBS_SEEN_SPINE
    if e.op == "index"
        # Everything under a gather is build-time-resolved (the target itself,
        # and each subscript through `_eval_const_int`) — flag it all.
        for a in e.args
            _obs_mark_refs!(a, names, hits, seen)
        end
        return nothing
    end
    if e.ranges !== nothing
        for (_, v) in e.ranges
            v isa AbstractVector || continue
            for b in v
                b isa ASTExpr && _obs_mark_refs!(b, names, hits, seen)
            end
        end
    end
    e.lower === nothing || _obs_mark_refs!(e.lower::ASTExpr, names, hits, seen)
    e.upper === nothing || _obs_mark_refs!(e.upper::ASTExpr, names, hits, seen)
    e.key === nothing || _obs_mark_refs!(e.key::ASTExpr, names, hits, seen)
    for a in _operands(e)
        _obs_structural_refs!(a, names, hits, seen)
    end
    e.expr_body === nothing || _obs_structural_refs!(e.expr_body::ASTExpr, names, hits, seen)
    e.filter === nothing || _obs_structural_refs!(e.filter::ASTExpr, names, hits, seen)
    if e.values !== nothing
        for v in e.values
            _obs_structural_refs!(v, names, hits, seen)
        end
    end
    return nothing
end

# GUARD-CONDITIONALITY count: tally per candidate name how many references are
# TOTAL vs UNCONDITIONAL, mirroring the CSE per-key rule (`_cse_count!` /
# `_cse_arg_conditional`): a reference under a lazy `ifelse` branch or a
# short-circuited `and`/`or` argument is CONDITIONAL. A slot is evaluated
# unconditionally in the prelude, so an observed with NO unconditional
# reference must stay inlined behind its guards (`_plan_observed_slots`).
#
# Aggregate/makearray/index subtrees count all their references CONDITIONAL:
# their build-time expansion can drop terms (an empty or join-rejected range,
# an unselected makearray region), so a reference below them is not provably
# evaluated — the conservative answer is today's inlining.
#
# Occurrences are counted as PATHS through the expression: the demotion rule
# reasons about total and unconditional occurrence counts, so this is not a
# distinct-node count. The path counts come from the unique-node walk
# (`_dag_postorder`, `_dag_path_counts`, dag.jl) over `args` edges, a barrier
# node (faq / makearray / index) being a leaf whose referenced names are
# tallied once per path to it. Additions saturate at `typemax(Int)`; the rule
# only asks whether the unconditional count is zero.
_count_obs_barrier(op::String) = _is_self_indexed_op(op)

_count_obs_kids(n::OpExpr) = _count_obs_barrier(n.op) ? () : n.args

function _count_obs_refs!(
        e::ASTExpr, names::Set{String}, tot::Dict{String, Int}, unc::Dict{String, Int}
    )
    if e isa VarExpr
        if e.name in names
            tot[e.name] = _sat_add(get(tot, e.name, 0), 1)
            unc[e.name] = _sat_add(get(unc, e.name, 0), 1)
        end
        return nothing
    end
    e isa OpExpr || return nothing
    keep(a) = a isa OpExpr
    order, pos = _dag_postorder(e::OpExpr, _count_obs_kids, keep)
    total, uncond = _dag_path_counts(
        order, pos, _count_obs_kids, keep, (n, j) -> _cse_arg_conditional(n.op, j)
    )
    for (i, n) in enumerate(order)
        t = total[i]
        if _count_obs_barrier(n.op)
            for r in _referenced_var_names(n)
                r in names && (tot[r] = _sat_add(get(tot, r, 0), t))
            end
        else
            u = uncond[i]
            for (j, a) in enumerate(_operands(n))
                (a isa VarExpr && a.name in names) || continue
                tot[a.name] = _sat_add(get(tot, a.name, 0), t)
                if u > 0 && !_cse_arg_conditional(n.op, j)
                    unc[a.name] = _sat_add(get(unc, a.name, 0), u)
                end
            end
        end
    end
    return nothing
end
