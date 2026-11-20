# tree_walk/build_pipeline.jl — the four build phases and `_build_evaluator_impl`.

# ============================================================
# 2c. Build phases
# ============================================================
# `_build_evaluator_impl` runs as four phases, each a function of the records
# the earlier ones return (build_records.jl):
#   1. `_build_lower_and_classify`        — equation pre-lowering and the
#      variable classification (`_VariableClasses`).
#   2. `_build_partition_and_materialize` — the ODE variable partition, the
#      scalar parameter scope, the setup-time arrays and the equation-stream
#      rewrites down to the `ic` fold (`_EquationPartition`).
#   3. `_build_state_layout`              — array-cell discovery, the flat
#      state layout, `u0` and the parameter tuple (`_StatePlan`).
#   4. `_build_compile_evaluator`         — the right-hand side, in stages.

# ---- Phase 1: equation pre-lowering + build-owned variable classification ----
# Everything through the bare-alias registration: the synthesized/folded/lifted
# equation stream plus the classification sets naming which array observeds are
# owned by a setup/inline/materialize mechanism (and therefore carry no ODE
# partition slot). `geom_inline_vars`/`array_inline_vars` are returned already
# discrete-cut-adjusted when a `materialize_out` sink opted in.
function _build_lower_and_classify(
        model::Model;
        const_arrays::AbstractDict, param_arrays::AbstractDict,
        vi_vars::Set{String}, materialize_out::Union{Nothing, DiscreteMaterializer}, index_sets = nothing
    )
    # ---- Observed synthesis + equation pre-lowering ----
    # (see `_prepare_model_equations`: expression-defined observed synthesis,
    # WS4 elementwise array-observed fold, whole-array derivative lift)
    equations, folded_array_obs = _prepare_model_equations(model; vi_vars = vi_vars)
    # Every reachability question phase 1 asks about the observed definitions.
    graph = _DefGraph(equations)

    # ---- Geometry variable discovery ----
    # (see `_discover_geometry_vars`: build-once setup vars, live-field inline
    # vars, and the has_* gate)
    geo = _discover_geometry_vars(
        model, equations, graph, param_arrays, vi_vars; index_sets = index_sets
    )
    geom_inline_vars = geo.inline_vars

    # ---- Promoted array observeds (shape-promotion inlining) ----
    array_inline_vars = _collect_array_inline_vars(
        model, equations,
        geo.setup_vars, geom_inline_vars
    )

    # ---- Cadence materialization split (discrete + const cuts) ----
    # OPT-IN (gated on the `materialize_out` sink): pull two classes of array observed
    # out of the inline sets so they are NOT inlined into the state RHS.
    #   • DISCRETE (param-tainted, state-free): the per-bracket conservative regrids,
    #     materialized once per refresh into cache buffers gathered via `pgather`
    #     (phase 4). This is the pre-existing middle cadence phase.
    #   • CONST (const-cadence, state-free): the nearest-neighbour coordinate fuel
    #     regrid (+ its const dependencies) — folded into `geom_setup_vars` so it
    #     materializes BUILD-ONCE through `_materialize_geometry_setup` (the float +
    #     parameter aware setup evaluator that resolves the coordinate gather), is
    #     registered as a const array, and its equation dropped. Its downstream table
    #     lookups stay inlined and fold over that const array per cell.
    # The param-tainted state/`t`-reaching fields (the time-interp ERA5 met blend + the
    # physics over it) stay inlined: after the discrete cut they reduce to affine blends
    # of the discrete caches that the symbolic-stencil folder handles. Without the sink
    # both sets are empty and the inline sets are untouched (byte-identical pre-cut).
    # ---- Causal self-references (esm-spec §4.3.1.1, recurrence_sweep.jl) ----
    # Array observeds whose own definition reads `index(self, …)`. Each is
    # materialized into a buffer by an ordered sweep under every compiler, so it
    # is kept out of every cut below that would move it elsewhere, together with
    # everything that reads it (a discrete- or const-cadence fill runs outside
    # the right-hand side, where its buffer is not filled).
    recur_vars = _recurrence_names(
        Dict{String, ASTExpr}(
            (eq.lhs::VarExpr).name => eq.rhs
                for eq in equations if eq.lhs isa VarExpr &&
                (eq.lhs::VarExpr).name in array_inline_vars
        ),
        array_inline_vars
    )
    discrete_vars = Set{String}()
    if materialize_out !== nothing
        pre_state = setdiff(Set{String}(solver_unknowns(model)), vi_vars)
        scalar_params = Set{String}(
            n for (n, v) in model.variables
                if v.type == ParameterVariable && !_is_array_shape(v.shape)
        )
        discrete_vars, const_mat_vars = _discrete_materialize_split(
            graph, union(geom_inline_vars, array_inline_vars),
            copy(array_inline_vars), pre_state,
            Set{String}(String(k) for k in keys(param_arrays)), scalar_params
        )
        if !isempty(recur_vars)
            reach = union!(_readers_of(graph, recur_vars), recur_vars)
            setdiff!(discrete_vars, reach)
            setdiff!(const_mat_vars, reach)
        end
        setdiff!(geom_inline_vars, discrete_vars)
        setdiff!(array_inline_vars, discrete_vars)
        setdiff!(array_inline_vars, const_mat_vars)
        # Route the const cut into the setup-geometry machinery: it flows through
        # `_materialize_geometry_setup` (float + parameter aware — resolves the
        # coordinate gather), registers as const arrays, and its equations drop.
        # Merge its defs into `geo.defs` so `_geom_setup_order` resolves them even
        # for a model with no polygon geometry (where `geo.defs` is otherwise empty).
        if !isempty(const_mat_vars)
            for eq in equations
                (eq.lhs isa VarExpr && (eq.lhs::VarExpr).name in const_mat_vars) &&
                    (geo.defs[(eq.lhs::VarExpr).name] = eq.rhs)
            end
            union!(geo.setup_vars, const_mat_vars)
        end
    end
    gated_geom_vars = _move_gated_geometry_inline_vars!(
        geom_inline_vars, array_inline_vars, equations
    )

    # ---- const-op array observeds (in-file polygon rings / source fields) ----
    const_obs_vars, const_obs_arrays = _collect_const_obs_arrays(
        model,
        const_arrays, geo.has_setup_geometry || !isempty(vi_vars)
    )

    # ---- bare-alias array observeds (keyed-factor re-exposure, esm-spec §4.6) ----
    _register_bare_alias_arrays!(
        const_obs_arrays, const_obs_vars, model, equations;
        const_arrays = const_arrays, geom_setup_vars = geo.setup_vars,
        geom_inline_vars = geom_inline_vars, array_inline_vars = array_inline_vars
    )

    # ---- Factored array observeds (buffer-materialized, per RHS call) ----
    # A SUBSET of `array_inline_vars` (so every ownership/partition exclusion
    # keyed on that set keeps holding): the promoted array observeds that get a
    # dense buffer instead of being spliced into each reader. Phase 3 narrows it
    # again to the ones whose extents actually resolve. Empty (byte-identical)
    # under `compiler=:interpreter` and for any model with no promoted array
    # observed.
    #
    # BOTH EMITTERS (`:inplace` and `:oop`) carry the same materialized-observed
    # fill levels: inlining is superlinear (a reader spliced with a reduction
    # body pays the whole body per output cell), so making it mandatory for one
    # form would make large models impossible to build in it.
    skipped = Dict{String, String}()
    mat_array_vars = _collect_materialized_array_obs(
        model, equations,
        array_inline_vars, discrete_vars; why = skipped
    )
    _refuse_unmaterialized_gated(filter(kv -> first(kv) in gated_geom_vars, skipped))
    # A recurrence cannot be inlined into its readers — its cells are defined by
    # one another — so it is materialized whatever the compiler, and whether or
    # not anything reads it: the output-time routes read the same buffer.
    union!(mat_array_vars, recur_vars)

    return _VariableClasses(
        equations, folded_array_obs, geo.setup_vars, geo.defs, geom_inline_vars,
        array_inline_vars, discrete_vars, const_obs_vars, const_obs_arrays,
        mat_array_vars, gated_geom_vars
    )
end

# ---- Phase 2: ODE variable partition + setup materialization + equation rewrites ----
# From the classified equation stream (`cls`) to the ODE-ready one: partition
# the variables, resolve the scalar parameter scope, materialize the setup-time
# arrays (A_ij, …) and the derived index-set extents,
# then run the equation rewrites in their pinned order — setup-equation drop,
# join-gate resolution, index-set range resolution, value-invention drop,
# discrete-cadence def extraction, and the `ic` fold.
function _build_partition_and_materialize(
        model::Model, cls::_VariableClasses;
        index_sets::AbstractDict, const_arrays::AbstractDict,
        param_arrays::AbstractDict, parameter_overrides::AbstractDict, vi_vars::Set{String}, vi_extents::AbstractDict,
        vi_maps,
        # Build-time parameter-read sink (see `_record_param_read`): the two consumers
        # below (`_materialize_geometry_setup`, the `ic` evaluation) record the
        # names they resolve, which is what makes a parameter STRUCTURAL.
        param_reads::Union{Nothing, Set{String}} = nothing,
        # The start of the run and the data-fed parameters' values there,
        # which the `ic` right-hand sides read (esm-spec §11.4.2).
        ic_t0::Float64 = 0.0,
        ic_data::AbstractDict = Dict{String, Any}()
    )
    # ---- Partition variables ----
    param_names, observed_names, state_var_names, supplied_scalars = _partition_variables(
        model, cls; vi_vars = vi_vars, const_arrays = const_arrays, param_arrays = param_arrays
    )

    # ---- Scalar parameter scope (load-time constants) ----
    param_scope = _resolve_param_scope(
        model, param_names, parameter_overrides;
        supplied = const_arrays, supplied_live = param_arrays
    )
    merge!(param_scope, supplied_scalars)

    # Value-invention derived index sets (distinct producers) materialized via
    # the relational engine in the AbstractDict front-door (RFC §6.1 / §5.5):
    # supply each producer's distinct-set cardinality as the resolver's dense
    # extent `[1, n]`.
    #
    # Merged BEFORE the geometry-setup materialization below, because a
    # setup-time body may RANGE over a derived set. The projection pushdown
    # re-points a binning aggregate onto `pd_support__<C>`, and when that
    # aggregate's weight is an overlap-area template the body is setup-time
    # geometry — so `_geo_index_extent` must be able to resolve the derived extent.
    has_value_invention = !isempty(vi_vars)
    derived_extents = has_value_invention ?
        Dict{String, Int}(String(k) => Int(v) for (k, v) in vi_extents) :
        _EMPTY_DERIVED_EXTENTS

    # Materialize the per-pair-area / A_ij setup arrays into const arrays BEFORE
    # index-set ranges are resolved.
    geom_setup_arrays = Dict{String, AbstractArray{Float64}}()
    if !isempty(cls.geom_setup_vars)
        geom_setup_arrays = _with_param_reads(param_reads) do
            _materialize_geometry_setup(
                cls.geom_setup_vars,
                cls.geom_defs, model, const_arrays, index_sets, derived_extents;
                vi_maps = vi_maps.maps, param_overrides = parameter_overrides,
                const_obs_arrays = cls.const_obs_arrays
            )
        end
    end
    # Geometry-setup vars (per-pair area / A_ij / their bin buffers) are
    # materialized at setup — drop their equations before the ODE-lowering passes
    # so their join/filter nodes never reach the join-gate / index-set-range
    # resolvers (those expect the relational/value-invention vocabulary, not the
    # setup-geometry one). A const-op array observed's equation is likewise
    # dropped: its value is in const_arrays.
    ode_equations = Equation[
        eq for eq in cls.equations
            if !(
                eq.lhs isa VarExpr && (
                    (eq.lhs::VarExpr).name in cls.geom_setup_vars ||
                    (eq.lhs::VarExpr).name in cls.const_obs_vars
                )
            )
    ]

    # ---- Resolve value-equality joins (RFC §5.3) ----
    # Rewrite each aggregate's `join` clauses into build-time `join_gates` (a
    # canonical bucket code per key-column position, or — Phase 2a — a prebuilt
    # spatial-overlap candidate set for a `join.overlap` gate) BEFORE index-set
    # ranges are resolved away — categorical members are read from the still-
    # present `{from}` references here, and a `join.overlap` gate reads its
    # envelope factor arrays from `const_arrays` (with each factor's 1-D shape
    # from `join_var_shapes`). No-op (byte-identical) for files without a join.
    join_var_shapes = Dict{String, Vector{String}}(
        String(n) => (v.shape === nothing ? String[] : Vector{String}(v.shape))
            for (n, v) in model.variables
    )
    # A §5.5.8 `on` key column and a §5.5.6 overlap envelope factor are both
    # build-time data, so the resolver gets the same storage the right-hand side
    # will read: the caller's const arrays overlaid with everything this build
    # materialized (setup arrays such as a `[pos, verts, coord]` ring stack built
    # from parameters, const-op array observeds), by the one precedence rule in
    # `_overlay_build_time_arrays!`.
    # The equations of all of these were dropped from the ODE partition above.
    # A document-literal key column that is still an equation is materialized on
    # demand from the observed definitions by `_join_key_column_values`.
    join_key_arrays = _overlay_build_time_arrays!(
        Dict{String, Any}(const_arrays), geom_setup_arrays, cls.const_obs_arrays
    )
    join_obs_defs = observed_definitions(model)
    # A key column computed from scalar parameters folds their values into the
    # match set, so each one it reads is recorded as read at build
    # (`:structural`: a `remake` that changes it is refused).
    equations, init_equations = _with_param_reads(param_reads) do
        _with_join_params(param_scope) do
            (
                _resolve_join_gates(
                    ode_equations, index_sets, vi_maps,
                    join_key_arrays, join_var_shapes, join_obs_defs
                ),
                _resolve_join_gates(
                    model.initialization_equations,
                    index_sets, vi_maps, join_key_arrays,
                    join_var_shapes, join_obs_defs
                ),
            )
        end
    end

    # ---- Resolve index-set references in ranges (RFC §5.2) ----
    # Rewrite any `ranges[*]` `{from: <name>}` reference against the document's
    # `index_sets` registry into the dense / dynamic-bound form the range
    # machinery already consumes, BEFORE any range expansion runs. No-op (and
    # therefore byte-identical) for files that use no `{from}` references.
    #
    # A RAGGED set's `offsets` keyed factor binds by BARE name in the model
    # scope (§5.4; the grids' wiring contract), but flattening prefixes every
    # variable with its owning component path while the document-scoped registry
    # keeps the authored bare name. Map each bare factor name to its in-scope
    # variable: an exact-name variable wins; otherwise the dot-suffix match at
    # the SHALLOWEST namespace depth (the model's own re-exposed alias, not the
    # mounted subsystem's original) — unique at that depth, else left bare so
    # the existing unbound-name error surfaces. Empty (byte-identical) for
    # documents without ragged index sets.
    factor_scope = _ragged_factor_scope(index_sets, model.variables)
    let pre = equations
        equations = _resolve_index_set_ranges(
            equations, index_sets, derived_extents,
            factor_scope
        )
    end
    init_equations = _resolve_index_set_ranges(
        init_equations,
        index_sets, derived_extents,
        factor_scope
    )

    # ---- Drop value-invention equations from the ODE (RFC §6.1) ----
    # The value-invention LHS vars are materialized at setup, not integrated;
    # their defining equations (a relational aggregate RHS) must not reach the
    # numeric pipeline. Their derived index-set extents were already harvested
    # above, so the index-set ranges resolved before this filter.
    if has_value_invention
        equations = Equation[
            eq for eq in equations
                if !(_vi_typed_lhs_base(eq.lhs) in vi_vars)
        ]
        init_equations = Equation[
            eq for eq in init_equations
                if !(_vi_typed_lhs_base(eq.lhs) in vi_vars)
        ]
    end

    # ---- Extract discrete-cadence materialize defs (RANGE-RESOLVED) + drop them ----
    # The discrete-cadence array observeds were kept through join-gate + index-set
    # range resolution so their faq `ranges` lower to concrete `[1, n]`. Capture
    # their resolved defining aggregates now (for the per-refresh fill kernels in
    # phase 4) and remove their equations from the ODE stream — they are
    # materialized into cache buffers, never compiled as observeds/derivatives.
    # Empty (no-op) unless the `materialize_out` sink opted in.
    discrete_defs = Dict{String, ASTExpr}()
    if !isempty(cls.discrete_vars)
        kept = Equation[]
        for eq in equations
            if eq.lhs isa VarExpr && (eq.lhs::VarExpr).name in cls.discrete_vars
                discrete_defs[(eq.lhs::VarExpr).name] = eq.rhs
            else
                push!(kept, eq)
            end
        end
        equations = kept
    end

    # ---- Fold `ic(var) = <initial value>` equations into u0 (esm-spec §11.4) ----
    # (see `_split_ic_equations`; scoped-reference / array targets are deferred
    # in `field_ics` and folded per cell by `_fold_field_ics!` once cells are known)
    # Every `ic` right-hand side is evaluated in the START-OF-RUN SCOPE
    # (esm-spec §11.4.2, `_ic_start_scope`): the parameters, `t` bound to the
    # start of the run, each data-fed parameter's value there, and the
    # observeds over those, each evaluated once as a whole field.
    # `ic_plan` is what that evaluation needs (`_IcPlan`); `_ic_evaluate` runs
    # it at a start `t0` with the data-fed values there, and a `remake` that
    # moves the start runs it again.
    equations, scalar_ics, raw_field_ics = _split_ic_equations(equations, model)
    ic_plan, ic_start, eq_ics, field_ics = _with_param_reads(param_reads) do
        plan = _ic_plan(
            model, scalar_ics, raw_field_ics;
            param_scope = param_scope, base_arrays = join_key_arrays,
            param_arrays = param_arrays, index_sets = index_sets,
            derived_extents = derived_extents, factor_scope = factor_scope, vi_vars = vi_vars
        )
        (plan, _ic_evaluate(plan, ic_t0, ic_data)...)
    end

    return _EquationPartition(
        param_names, observed_names, state_var_names, param_scope,
        geom_setup_arrays, derived_extents, equations, init_equations,
        discrete_defs, eq_ics, field_ics, ic_start, ic_plan
    )
end

# ---- Phase 3: array-cell discovery + flat state layout + u0 / parameter tuple ----
# Discover every array cell (declared shapes + `D(index(var,k))` usage), lay out
# the flat state vector (scalars first, then array cells in column-major cell
# order), fold the deferred field ics now that cells are known (mutating
# `parts.eq_ics`), and seed u0 and the scalar-parameter NamedTuple.
function _build_state_layout(
        model::Model, cls::_VariableClasses, parts::_EquationPartition;
        initial_conditions::AbstractDict, index_sets::AbstractDict, const_arrays::AbstractDict, vi_vars::Set{String},
        # Build-time parameter-read sink (see `_record_param_read`): the field-ic fold
        # below is the fourth build-time consumer of the parameter scope.
        param_reads::Union{Nothing, Set{String}} = nothing,
        # Filled with the slots nothing gave a starting value (`_build_u0`).
        unvalued::Union{Nothing, Vector{Int}} = nothing
    )
    # ---- Discover array cells from equations and initial conditions ----
    # Array variable detection: a variable is treated as an array if it has
    # an explicit non-empty shape, OR if it appears inside index(var, k...)
    # in an equation LHS. This handles both declared-shape variables and the
    # common pattern where shape=nothing but equations use D(index(var, k)). An
    # explicit empty shape (`[]`, rank-0) is scalar, not an array.
    array_var_names_declared = Set{String}(
        n for n in solver_unknowns(model)
            if _is_array_shape(model.variables[n].shape) && !(n in vi_vars)
    )
    # Detect array usage from equations even when shape is not declared.
    array_var_names = _detect_array_vars(
        parts.equations, parts.state_var_names,
        initial_conditions
    )
    union!(array_var_names, array_var_names_declared)

    # array_cells: var_name → the cells its equations and initial conditions name
    array_cells = _discover_array_cells(
        parts.equations, initial_conditions,
        array_var_names
    )
    # Equation-less declared array states still get one u0 slot per cell.
    _enumerate_declared_array_cells!(
        array_cells, model, index_sets,
        parts.derived_extents, vi_vars
    )

    # Scalar state variables: all state vars not treated as arrays.
    scalar_state_names = String[]
    for name in parts.state_var_names
        name in array_var_names || push!(scalar_state_names, name)
    end
    sort!(scalar_state_names)

    # Build per-var bounds for in-bounds / ghost-cell checks.
    # array_var_info: var_name → (lo::Vector{Int}, hi::Vector{Int})
    array_var_info = Dict{String, Tuple{Vector{Int}, Vector{Int}}}()
    for (vname, cells) in array_cells
        isempty(cells) && continue
        array_var_info[vname] = _cellset_bbox(cells)
    end
    # A range-restricted program lays each array state out over its storage.
    _range_state_boxes!(_range_spec_now(), array_var_info)

    # ---- Flat state layout: scalars first, then one block per array ----
    # Each array variable's block covers the bounding box of its cells,
    # column-major (first index fastest, consistent with Julia's native array
    # layout and the Rust/Python runtimes), arrays in name order.
    var_map = StateLayout(
        scalar_state_names,
        [vname => array_var_info[vname] for vname in sort(collect(keys(array_var_info)))]
    )

    # ---- Initial condition vector, with the scoped-reference / array `ic`
    # equations folded in (spec §11.4.1) ----
    u0 = _build_u0(
        model, var_map, initial_conditions, parts.eq_ics,
        set -> _with_param_reads(param_reads) do
            _fold_field_ics!(
                set, parts.field_ics, array_cells, var_map,
                parts.ic_start.scalars,
                _ic_field_arrays(const_arrays, parts.ic_start)
            )
        end; unvalued = unvalued
    )
    # The same initial state at another start of the run (`remake` with a new
    # `tspan`, esm-spec §11.4.2), for a document whose `ic` right-hand sides
    # read the start: `t`, or a data-fed parameter. `nothing` otherwise, since
    # the initial state then does not depend on it.
    ic_reseed = !parts.ic_start.reads_start ? nothing :
        _IcReseed(parts.ic_plan, u0, var_map, initial_conditions, array_cells, const_arrays)

    # ---- Parameter NamedTuple ----
    p_vals = Float64[]
    p_syms = Symbol[]
    for name in parts.param_names
        push!(p_syms, Symbol(name))
        push!(p_vals, parts.param_scope[name])  # resolved (override-or-default)
    end
    # Use `nothing` for parameter-free models: some SciMLBase versions enter
    # an infinite recursion in SymbolicIndexingInterface when the problem
    # carries an empty NamedTuple{(),()} as `p`. `nothing` is SciMLBase's
    # canonical "no parameters" sentinel and avoids the dispatch loop.
    p = isempty(p_syms) ? nothing :
        NamedTuple{Tuple(p_syms)}(Tuple(p_vals))

    # ---- Factored array-observed buffer layout (perf: array-observed slots) ----
    # Each materialized array observed gets a dense block of slots ABOVE the
    # ODE state (`n_states+1 …`) in the same flat vector, laid out column-major
    # exactly as an array state's cells are (one `StateLayout` block each), and
    # is registered in `array_var_info` + `var_map` so a reader's
    # `index(obs, i…)` resolves through the ordinary array-gather path. `u0`
    # and the PUBLIC `var_map` keep only the ODE slots — the buffers are
    # build-owned scratch, never an integrator slot.
    mat_dims = Dict{String, Vector{Int}}()
    var_map_ext = var_map
    array_var_info_ext = array_var_info
    if !isempty(cls.mat_array_vars)
        mat_defs_raw = Dict{String, ASTExpr}()
        for eq in parts.equations
            eq.lhs isa VarExpr &&
                ((eq.lhs::VarExpr).name in cls.mat_array_vars) &&
                (mat_defs_raw[(eq.lhs::VarExpr).name] = eq.rhs)
        end
        array_var_info_ext = copy(array_var_info)
        mat_blocks = Pair{String, Tuple{Vector{Int}, Vector{Int}}}[]
        # A gated live-field geometry observed has no inline path to fall back
        # on (`_move_gated_geometry_inline_vars!`), so each skip below that
        # leaves a reader of it is refused with its reason. One whose equation
        # the range restriction dropped, or that the tile does not need, has
        # no reader here.
        gated_skips = Dict{String, String}()
        skip!(name, why) = name in cls.gated_geom_vars && (gated_skips[name] = why)
        for name in sort(collect(cls.mat_array_vars))
            haskey(mat_defs_raw, name) || continue
            if haskey(array_var_info_ext, name)    # never shadow a state
                skip!(name, "its name is also a state's")
                continue
            end
            v = model.variables[name]
            dims = _materialized_obs_dims(
                mat_defs_raw[name], v.shape,
                index_sets, parts.derived_extents
            )
            if dims === nothing || isempty(dims) || any(d -> d <= 0, dims)
                skip!(name, "its extents do not resolve to positive sizes at build time")
                continue
            end
            # A declared shape of a different rank than the producer's output
            # would make the cell keys ambiguous — leave it inlined.
            if v.shape !== nothing && length(v.shape) != length(dims)
                skip!(
                    name, "its declared shape has rank $(length(v.shape)) but its " *
                        "definition produces rank $(length(dims))"
                )
                continue
            end
            box = _range_observed_box(_range_spec_now(), name, dims)
            box === nothing && continue
            mat_dims[name] = dims
            array_var_info_ext[name] = box
            push!(mat_blocks, name => array_var_info_ext[name])
        end
        _refuse_unmaterialized_gated(gated_skips)
        var_map_ext = _layout_extend(var_map, mat_blocks)
    end

    # The parameter scope handed to `_compile`, as an ORDERED map: `sym → its
    # position in `p_syms``. `p_syms` came from the already-sorted
    # `parts.param_names`, so this position is stable across builds of the same
    # document and is the SAME position the value has in the `p` NamedTuple —
    # which is the whole point: a `_NK_PARAM` node both names a parameter and
    # locates it. (The public `param_map(p)` is this map keyed by NAME.)
    param_index = Dict{Symbol, Int}(s => i for (i, s) in enumerate(p_syms))

    return _StatePlan(
        u0, p, var_map, array_var_info, param_index, var_map_ext, array_var_info_ext,
        mat_dims, ic_reseed
    )
end

# ---- Phase 4: compile the right-hand side ----

# What the right-hand-side slot holds (tree_walk/oop.jl): `_InPlace`, the
# zero-allocation evaluator `f!(du, u, p, t)`, or `_OutOfPlace`, the compiled IR
# a compiled backend lowers and the host does not evaluate. Read once, at the
# build entry (`_build_form`); every stage that differs by form is a method.
abstract type _BuildForm end
struct _InPlace <: _BuildForm end
struct _OutOfPlace <: _BuildForm end

function _build_form(form::Symbol)
    form === :inplace && return _InPlace()
    form === :oop && return _OutOfPlace()
    throw(
        TreeWalkError(
            "E_TREEWALK_UNKNOWN_FORM",
            "the build's `form` must be :inplace or :oop, got :$(form)"
        )
    )
end

# Whether whatever consumes the scalar list compiles it: the out-of-place
# product's emitters lower the per-cell contraction loop into a program of
# their own; the in-place `f!` walks the list.
_rhs_list_compiled(::_InPlace) = false
_rhs_list_compiled(::_OutOfPlace) = true

# The state length of a two-buffer slot space (`_ObsSplitVec`, obs_buffers.jl)
# the in-place sections address, or 0 for one plain vector: the out-of-place
# product is read as one vector.
_obs_split_nst(::_InPlace, n_states::Int, n_total::Int) = n_total > n_states ? n_states : 0
_obs_split_nst(::_OutOfPlace, ::Int, ::Int) = 0
# An observed fill level always runs on the split slot space in place.
_level_nst(::_InPlace, n_states::Int) = n_states
_level_nst(::_OutOfPlace, ::Int) = 0

# A recurrence sweep has no lowering in the out-of-place product.
_check_recurrence_form(::_InPlace, ::String) = nothing
_check_recurrence_form(::_OutOfPlace, name::String) = _refuse_rule(
    name,
    "an ordered recurrence sweep (esm-spec §4.3.1.1) has no " *
        "lowering in the out-of-place product this compiler emits; " *
        "its cells cannot be computed as one whole-array program " *
        "(CONFORMANCE_SPEC §5.19.2)"
)

# Phase 4 (`_build_compile_evaluator`): the observed split, the const-array
# registry, the live forcing buffers and the two compile scopes, the discrete
# caches, the initialization-equation seed, the materialized-observed fill
# levels, the state equations, the scalar prelude, and the assembled
# right-hand side. Fills `products` (when given) and returns
# `(f!, u0, p, tspan, var_map)`, `var_map` the ODE layout.
#
# The ordering constraints between the stages: the discrete materializer adds
# its caches to `pgather` before the seed, the fill plan and every compile read
# it; the in-place levels' sections are made after the state equations are
# compiled (a fused scan may take in a state kernel); the class merge runs
# before the cross-kernel sharing, and the sharing before the per-cell
# reference is appended and before the prelude's cadence tiers.
function _build_compile_evaluator(
        model::Model, cls::_VariableClasses, parts::_EquationPartition, layout::_StatePlan;
        index_sets::AbstractDict = Dict{String, Any}(), const_arrays::AbstractDict,
        const_array_boundaries::AbstractDict, param_arrays::AbstractDict,
        initial_conditions::AbstractDict, tspan,
        products::Union{Nothing, BuildProducts}, materialize_out::Union{Nothing, DiscreteMaterializer},
        form::_BuildForm,
        caller_u0 = nothing
    )
    u0 = layout.u0
    p = layout.p
    n_states = _n_states(layout)
    n_total = _n_total(layout)
    # The materialized set, narrowed to the observeds whose buffer extents
    # resolved (`mat_dims`); the rest stayed on the inline path.
    mat_vars = Set{String}(keys(layout.mat_dims))

    split = _split_observed_and_derivatives(
        parts.equations, parts.observed_names, cls, mat_vars,
        Set{String}(n for (n, v) in model.variables if _is_array_shape(v.shape))
    )
    const_registry = _register_const_arrays(
        const_arrays, const_array_boundaries,
        parts.geom_setup_arrays, cls.const_obs_arrays
    )
    products === nothing ||
        _publish_build_time!(products, parts, const_registry, split, mat_vars)

    # The live forcing buffers (`_build_pgather`), and the two scopes the build
    # compiles against: the state-only one (construction-time fills and
    # output-time reads, where the observed buffers do not exist) and the
    # right-hand side's, whose layout adds the materialized observeds' blocks.
    pgather = _build_pgather(param_arrays)
    _ws_note_pgather!(pgather)
    state_scope = _CompileScope(
        layout.array_var_info, layout.var_map, const_registry, pgather, layout.param_index
    )
    rhs_scope = _CompileScope(
        layout.array_var_info_ext, layout.var_map_ext, const_registry, pgather,
        layout.param_index
    )
    # This build's forcing epoch: the problem's (its discrete sink carries it),
    # bumped when a refresh of a buffer the build reads is announced to its owner.
    forcing_epoch = materialize_out === nothing ? _new_forcing_epoch() :
        materialize_out.epoch
    products === nothing || (products.forcing_epoch = forcing_epoch)

    # The discrete-cadence caches (`DiscreteMaterializer`): each discrete
    # observed's cache joins `pgather`, so a reader gathers it live. The fills
    # run outside the right-hand side, against the state-only scope, and the
    # initial fill makes the caches valid before anything below reads them.
    discrete_refill = materialize_out === nothing ? nothing :
        _build_discrete_materializer!(
            materialize_out, cls.discrete_vars, parts.discrete_defs, split.resolved,
            state_scope, p, n_states
        )

    # What an output-time read (observed_program.jl) compiles against.
    if products !== nothing
        products.observed_ctx = _ObsProgramCtx(
            model, cls, parts, index_sets, state_scope, n_states, p,
            materialize_out === nothing ? Dict{String, Array{Float64}}() :
                materialize_out.caches,
            merge(Dict{String, ASTExpr}(split.raw), split.materialized),
            _state_base_names(layout.var_map, layout.array_var_info),
            Dict{String, Any}(), ReentrantLock(), _build_state().calls
        )
    end

    # The faq-valued initialization equations seed `u0`. A caller's `u0` is
    # part of the state they read, and a cell it names keeps its value.
    caller_slots = _apply_caller_u0!(u0, layout.var_map, parts.init_equations, caller_u0)
    seeded = _seed_faq_init_u0!(
        u0, parts.init_equations, initial_conditions, state_scope, p;
        skip_slots = caller_slots
    )
    # A cell an initialization equation set has a starting value.
    products === nothing || isempty(seeded) ||
        filter!(s -> !(s in seeded), products.unvalued_slots)

    # The scalar observeds compiled once as named prelude slots
    # (`_plan_observed_slots`), each resolved in dependency order through the
    # scope the scalar equations use.
    obs_plan = _plan_observed_slots(
        split.derivatives, split.raw, split.resolved, parts.observed_names
    )
    obs_defs = Pair{String, ASTExpr}[
        name => _resolve_in(rhs_scope, body) for (name, body) in obs_plan.defs
    ]

    levels = _compile_fill_levels(
        form, split, mat_vars, layout, model, rhs_scope, products
    )
    oop_levels = _oop_fill_levels(form, levels)
    products === nothing || sort!(products.recurrences; by = r -> r.var)

    # The state equations, against the right-hand side's scope: a reader's
    # `index(<materialized observed>, i…)` gathers the observed's buffer block.
    # A state without a `D` equation keeps du = 0.
    state_eqs = _compile_derivative_equations(
        split.derivatives, split.resolved, rhs_scope, n_states;
        scalar_obs_inline = obs_plan.inline,
        rhs_list_compiled = _rhs_list_compiled(form),
        obs_nst = _obs_split_nst(form, n_states, n_total)
    )

    sealed = _seal_fill_levels(form, levels, oop_levels, state_eqs, split, n_states, n_total)
    rhs = _compile_scalar_rhs(
        form, state_eqs, sealed.acc_kernels, obs_defs, rhs_scope, forcing_epoch
    )
    tspan_default = _pick_tspan(tspan)
    if products !== nothing
        # Published for both forms, from the `pgather` the out-of-place product
        # carries, so `forcing_buffers(prob)` does not depend on the form.
        products.forcing_buffers, products.forcing_buffer_index =
            _forcing_buffer_container(pgather)
    end
    f! = _assemble_rhs(
        form, rhs, sealed, state_eqs, pgather, n_states, n_total, forcing_epoch,
        discrete_refill
    )
    if products !== nothing
        products.stats = _rhs_stats(rhs, sealed, state_eqs, levels, obs_plan, mat_vars, n_states, n_total)
        products.kernels = sealed.acc_kernels
    end
    # The public map is the ODE layout: the observed buffers are build-owned
    # scratch above `length(u0)`.
    return f!, u0, p, tspan_default, layout.var_map
end

# Copy the build-time products into `products`. The right-hand side does not
# consult them. `observed_exprs` is the fully resolved observed map, factored
# observeds included (an output-time cellwise read substitutes every
# reference); a recurrence has no substituted form and is published as authored.
# `observed_defs` keeps each observed's definition before substitution.
function _publish_build_time!(
        products::BuildProducts, parts::_EquationPartition, const_registry::AbstractDict,
        split::_ObservedSplit, mat_vars::Set{String}
    )
    for (k, arr) in parts.geom_setup_arrays
        # Published by reference, as the const arrays are.
        products.setup_arrays[String(k)] = arr isa Array{Float64} ? arr : Array{Float64}(arr)
    end
    for (k, arr) in const_registry
        products.const_arrays[String(k)] = arr
    end
    mat_defs = split.materialized
    recur_pub = _recurrence_names(mat_defs, mat_vars)
    published = isempty(mat_defs) ? split.resolved :
        _resolve_observed(
            merge(
                Dict{String, ASTExpr}(split.resolved),
                Dict{String, ASTExpr}(k => v for (k, v) in mat_defs if !(k in recur_pub))
            )
        )
    if !isempty(recur_pub)
        published = Dict{String, ASTExpr}(published)
        for k in recur_pub
            published[k] = mat_defs[k]
        end
    end
    # Filled as each sweep compiles, so the sweep's own checks run first and
    # decide any error the build raises.
    empty!(products.recurrences)
    for (k, e) in published
        _is_hoisted_name(String(k)) || (products.observed_exprs[String(k)] = e)
    end
    for (k, e) in split.raw
        _is_hoisted_name(String(k)) || (products.observed_defs[String(k)] = e)
    end
    # Keyed by producer id, as the build holds it; a `kind: "derived"` axis
    # follows its set's `from_faq` here.
    for (k, n) in parts.derived_extents
        products.derived_extents[String(k)] = Int(n)
    end
    for (k, val) in parts.param_scope
        products.params[String(k)] = val
    end
    return nothing
end

# The cadence of the materialized observeds the in-place right-hand side fills
# outside every call: `const`, filled only when `p` moves, and `time`, filled
# only when `(p, t, forcing epoch)` moves. Neither under the untiered
# interpreter, which refills everything on every call, nor in the out-of-place
# product, which has no such skip.
_fill_cadences(::_OutOfPlace, split, mat_vars, layout, scope) = (Set{String}(), Set{String}())
function _fill_cadences(
        ::_InPlace, split::_ObservedSplit, mat_vars::Set{String}, layout::_StatePlan,
        scope::_CompileScope
    )
    (_untiered() || isempty(mat_vars)) && return (Set{String}(), Set{String}())
    dyn_seed = _state_base_names(layout.var_map, layout.array_var_info)
    push!(dyn_seed, "t")
    union!(dyn_seed, keys(scope.pgather))
    mat_const = _const_cadence_mat_obs(
        split.materialized, mat_vars, split.raw, dyn_seed,
        scope.param_index, scope.const_registry
    )
    # Time cadence: no state below them, but `t` or a live buffer (a
    # `param_arrays` buffer, a discrete cache) somewhere.
    tleaves = Set{String}(keys(scope.pgather))
    push!(tleaves, "t")
    mat_time = setdiff!(
        _const_cadence_mat_obs(
            split.materialized, mat_vars, split.raw,
            _state_base_names(layout.var_map, layout.array_var_info),
            scope.param_index, scope.const_registry, tleaves
        ), mat_const
    )
    return mat_const, mat_time
end

# The fill levels of the materialized observeds, in fill order: the const
# levels, the time levels, then the rest, each `(names, cadence)` with no name
# reading another of the same level.
function _fill_level_plan(
        form::_BuildForm, split::_ObservedSplit, mat_vars::Set{String},
        layout::_StatePlan, scope::_CompileScope
    )
    plan = Tuple{Vector{String}, Symbol}[]
    isempty(mat_vars) && return plan
    mat_const, mat_time = _fill_cadences(form, split, mat_vars, layout, scope)
    mat_defs = split.materialized
    isempty(mat_const) || foreach(
        l -> push!(plan, (l, :const)),
        _materialized_obs_levels(mat_defs, mat_const, split.raw)
    )
    isempty(mat_time) || foreach(
        l -> push!(plan, (l, :time)),
        _materialized_obs_levels(mat_defs, mat_time, split.raw)
    )
    foreach(
        l -> push!(plan, (l, :dynamic)),
        _materialized_obs_levels(mat_defs, setdiff(mat_vars, mat_const, mat_time), split.raw)
    )
    return plan
end

# The materialized observeds' fill levels, compiled. Each observed's fill is a
# synthesized `faq(D(index(obs, i…))) = <body>` equation through the cascade its
# readers take (`_compile_fill_level`), its output slots its buffer block; a
# causal self-reference is an ordered sweep (`_level_recurrence`). A level's
# prefix folds run after its kernel section, over the slots its own kernels
# wrote. An in-place level is sealed once the state equations are compiled
# (`_seal_fill_levels`); an out-of-place one as soon as the levels are
# (`_oop_fill_levels`).
function _compile_fill_levels(
        form::_BuildForm, split::_ObservedSplit, mat_vars::Set{String},
        layout::_StatePlan, model::Model, scope::_CompileScope,
        products::Union{Nothing, BuildProducts};
    )
    plan = _fill_level_plan(form, split, mat_vars, layout, scope)
    mat_defs = split.materialized
    recur_names = _recurrence_names(mat_defs, mat_vars)
    recurrence = name -> _level_recurrence(
        name, form, recur_names, mat_defs, layout, model, split.resolved, scope,
        products
    )
    fill = name -> _range_fill_equations(
        _range_spec_now(), name, mat_defs[name], layout.mat_dims[name],
        scope.array_var_info[name]
    )
    n_states = _n_states(layout)
    return _LevelParts[
        _compile_fill_level(
            lvl, cadence, fill, recurrence, split.resolved, scope, _n_total(layout);
            rhs_list_compiled = _rhs_list_compiled(form),
            obs_nst = _level_nst(form, n_states)
        )
            for (lvl, cadence) in plan
    ]
end

# An out-of-place level is sealed as soon as the levels are compiled: its
# kernels class-merged, with one vectorization plan per merged kernel.
_oop_fill_levels(::_InPlace, levels::Vector{_LevelParts}) = _OopFillLevel[]
function _oop_fill_levels(::_OutOfPlace, levels::Vector{_LevelParts})
    out = _OopFillLevel[]
    for lv in levels
        merged, _ = _merge_acc_kernel_classes(lv.kernels)
        push!(
            out, _OopFillLevel(
                lv.scalars, merged,
                _OopAccPlan[_build_oop_acc_plan(K) for K in merged],
                lv.scans, lv.contractions
            )
        )
    end
    return out
end

# The right-hand side's fill levels and its state kernels, ready to run.
struct _SealedFills
    # The in-place fill levels (`_RhsStage`s) by cadence (empty out of place), and the
    # out-of-place levels (empty in place).
    levels::Vector{Any}
    const_levels::Vector{Any}
    time_levels::Vector{Any}
    oop_levels::Vector{_OopFillLevel}
    # The state equations' kernels after the class merge, their prefix folds
    # (a `_ScanSection` in place) and the fused scans the state section takes.
    acc_kernels::Vector{_AccKernel}
    scan_folds::Any
    fused_scans::Tuple
    class_merge_diag::Any
    n_state_scan_folds::Int
end

function _seal_fill_levels(
        ::_OutOfPlace, levels::Vector{_LevelParts}, oop_levels::Vector{_OopFillLevel},
        state_eqs::_CompiledEquations, split::_ObservedSplit, n_states::Int, n_total::Int
    )
    acc_kernels, class_merge_diag = _merge_acc_kernel_classes(state_eqs.kernels; keep_affine = false)
    return _SealedFills(
        Any[], Any[], Any[], oop_levels, acc_kernels, state_eqs.scan_folds, (),
        class_merge_diag, length(state_eqs.scan_folds)
    )
end

# In place, a scan whose term kernel compiles into its fold's own pass
# (scan_fused.jl) leaves that kernel out of its level's section, and a state
# kernel it takes in as its consumer leaves the state kernels; the state RHS
# runs on the two-buffer slot space (`_ObsSplitVec`) only when something is
# materialized. The affine box kernels stay out of the class merge
# (`keep_affine`), each its own loop nest.
function _seal_fill_levels(
        ::_InPlace, levels::Vector{_LevelParts}, ::Vector{_OopFillLevel},
        state_eqs::_CompiledEquations, split::_ObservedSplit, n_states::Int, n_total::Int
    )
    acc_kernels_pre = state_eqs.kernels
    scan_folds = state_eqs.scan_folds
    n_state_scan_folds = length(scan_folds)
    out = (dynamic = Any[], constant = Any[], time = Any[])
    if !isempty(levels)
        consumers = _scan_consumer_plan(
            levels, acc_kernels_pre, n_states,
            state_eqs.scalar_entries, state_eqs.percell, state_eqs.contractions,
            (split.raw, split.materialized, split.resolved)
        )
        consumed = IdDict{Any, Bool}()
        for lv in levels
            lvl_kernels, lvl_scans, lvl_fused = _detach_fused_scans(
                lv.kernels, lv.scans; nst = n_states,
                consumers = consumers, consumed = consumed
            )
            lvl_acs = lv.cadence === :dynamic ?
                _ac_take_consumers(lv.contractions, acc_kernels_pre, n_states, consumed) :
                lv.contractions
            push!(
                lv.cadence === :const ? out.constant :
                    lv.cadence === :time ? out.time : out.dynamic,
                _inplace_fill_level(
                    lv.scalars, lvl_kernels, _make_scan_section(lvl_scans, lvl_fused),
                    lvl_acs, lv.recurrences; nst = n_states
                )
            )
        end
        isempty(consumed) ||
            (acc_kernels_pre = _AccKernel[K for K in acc_kernels_pre if !haskey(consumed, K)])
    end
    obs_nst = n_total > n_states ? n_states : 0
    acc_kernels_pre, scan_folds, fused_scans =
        _detach_fused_scans(acc_kernels_pre, scan_folds; nst = obs_nst)
    acc_kernels, class_merge_diag = _merge_acc_kernel_classes(acc_kernels_pre; keep_affine = true)
    return _SealedFills(
        out.dynamic, out.constant, out.time, _OopFillLevel[], acc_kernels, scan_folds,
        fused_scans, class_merge_diag, n_state_scan_folds
    )
end

# The scalar right-hand side: the state equations' scalar entries compiled in
# one batch with their shared subexpressions in a prelude (`_cse_compile_scalar`;
# with `has_pgather` a live-buffer gather keys through a stand-in), the
# cross-kernel sharing (in place), the per-cell reference appended after it,
# the prelude's cadence tiers, and in place the scalar section as generated
# code (its report rows move to the `*_codegen` tiers).
function _compile_scalar_rhs(
        form::_BuildForm, state_eqs::_CompiledEquations, acc_kernels::Vector{_AccKernel},
        obs_defs::Vector{Pair{String, ASTExpr}}, scope::_CompileScope,
        forcing_epoch::_ForcingEpoch
    )
    var_map = scope.var_map
    rhs_list, prelude, cache, cse_diag = _cse_compile_scalar(
        state_eqs.scalar_entries, var_map, scope.param_index;
        has_pgather = !isempty(scope.pgather), obs_defs = obs_defs
    )
    cache.epoch = forcing_epoch
    xcse_diag = _share_invariants!(form, rhs_list, prelude, cache, acc_kernels)
    n_scalar_rhs = length(rhs_list)
    isempty(state_eqs.percell) || append!(rhs_list, state_eqs.percell)
    const_slots, time_slots, dyn_slots = _classify_const_slots(prelude, cache)
    section = _scalar_section(
        form, rhs_list, n_scalar_rhs, prelude, cache, const_slots, time_slots,
        dyn_slots, acc_kernels, var_map
    )
    return (;
        rhs_list, prelude, cache, cse_diag, xcse_diag, n_scalar_rhs, const_slots,
        time_slots, dyn_slots, section,
    )
end

# A lane-invariant subtree shared by several kernels' invariant tiers (and
# scalar equations) collapses to one prelude slot (xcse.jl). In place only: a
# compiled backend emits the prelude itself and never reads the cache.
_share_invariants!(::_OutOfPlace, rhs_list, prelude, cache, kernels) = _XCSE_NONE_DIAG
_share_invariants!(::_InPlace, rhs_list, prelude, cache, kernels) =
    _xcse_disabled() ? _XCSE_NONE_DIAG :
    _share_kernel_invariants!(rhs_list, prelude, cache, kernels)

_scalar_section(::_OutOfPlace, args...) = nothing
function _scalar_section(
        ::_InPlace, rhs_list, n_scalar_rhs, prelude, cache, const_slots, time_slots,
        dyn_slots, kernels, var_map
    )
    sec = _build_scalar_section(
        rhs_list, n_scalar_rhs, prelude, cache, const_slots, time_slots, dyn_slots,
        kernels; rule_of = s -> var_map isa StateLayout ?
            _slot_key(var_map, s) : "state slot $s"
    )
    sec === nothing || _retier_scalar_rules!(var_map, rhs_list, sec)
    return sec
end

# The in-place evaluator (`_Rhs`, rhs_assembly.jl): the materialized
# observeds' fill levels run before the state stage (`_RhsObserved`, `nothing`
# when nothing is materialized), and the discrete caches are brought up to the
# call's `p` first (`_DiscreteRefill`, absent without a cache).
function _assemble_rhs(
        ::_InPlace, rhs, sealed::_SealedFills, state_eqs::_CompiledEquations,
        pgather, n_states::Int, n_total::Int, forcing_epoch::_ForcingEpoch,
        discrete_refill
    )
    return _make_rhs(
        rhs.rhs_list, rhs.prelude, rhs.cache, sealed.acc_kernels,
        rhs.const_slots, rhs.time_slots, rhs.dyn_slots, sealed.scan_folds,
        _make_contraction_section(state_eqs.contractions);
        scalar = rhs.section, fused_scans = sealed.fused_scans,
        nst = n_total > n_states ? n_states : 0,
        observed = _rhs_observed(
            n_total, n_states, Tuple(sealed.levels), Tuple(sealed.const_levels),
            Tuple(sealed.time_levels), forcing_epoch
        ),
        refill = discrete_refill
    )
end

# The out-of-place product: the compiled IR, with `pgather` (the
# `param_arrays` buffers and the discrete caches) so its live buffers are
# arguments of the compiled program (`_OopRHS`).
_assemble_rhs(
    ::_OutOfPlace, rhs, sealed::_SealedFills, state_eqs::_CompiledEquations,
    pgather, n_states::Int, n_total::Int, forcing_epoch::_ForcingEpoch, discrete_refill
) = _make_rhs_oop(
    rhs.rhs_list, rhs.prelude, sealed.acc_kernels, n_states, pgather,
    sealed.scan_folds, Tuple(sealed.oop_levels), n_total, state_eqs.contractions
)

# The emitted right-hand side's structural counts (`BuildProducts.stats`). The
# kernel and slot counts are of the post-merge list the right-hand side
# carries; the class merge's input count is `n_classmerge_in`. None grows with
# the grid; only the embedded slot and value vectors do.
function _rhs_stats(
        rhs, sealed::_SealedFills, state_eqs::_CompiledEquations,
        levels::Vector{_LevelParts}, obs_plan, mat_vars::Set{String},
        n_states::Int, n_total::Int
    )
    acc_kernels = sealed.acc_kernels
    cmd = sealed.class_merge_diag
    return (;
        n_scan_folds = sealed.n_state_scan_folds +
            sum(lv -> length(lv.scans), levels; init = 0),
        n_array_contractions = length(state_eqs.contractions) +
            sum(lv -> length(lv.contractions), levels; init = 0),
        n_recurrence_sweeps = sum(lv -> length(lv.recurrences), levels; init = 0),
        n_acc_kernels = length(acc_kernels),
        n_acc_cse_slots = sum(length(K.cse.recipes) for K in acc_kernels; init = 0),
        n_acc_inv_slots = sum(length(K.cse.inv_recipes) for K in acc_kernels; init = 0),
        n_classmerge_in = cmd === nothing ? length(acc_kernels) : cmd.n_in,
        n_classmerge_blocked = cmd === nothing ? 0 : cmd.n_blocked,
        n_classmerge_failed = cmd === nothing ? 0 : cmd.n_failed,
        n_scalar_entries = length(rhs.rhs_list),
        n_cse_slots = rhs.cse_diag.n_slots,
        n_cse_occurrences = rhs.cse_diag.n_occurrences,
        n_obs_slots = rhs.cse_diag.n_obs_slots,
        n_obs_inlined = obs_plan.n_inlined,
        n_xcse_slots = rhs.xcse_diag.n_xcse_slots,
        n_xcse_kernel_shared = rhs.xcse_diag.n_xcse_kernel_shared,
        n_xcse_scalar_shared = rhs.xcse_diag.n_xcse_scalar_shared,
        n_const_slots = length(rhs.const_slots),
        n_time_slots = length(rhs.time_slots),
        n_dynamic_slots = length(rhs.dyn_slots),
        n_mat_array_obs = length(mat_vars),
        n_mat_array_cells = n_total - n_states,
        n_mat_levels = length(sealed.levels) + length(sealed.const_levels) +
            length(sealed.time_levels),
        n_mat_const_levels = length(sealed.const_levels),
        n_mat_time_levels = length(sealed.time_levels),
    )
end

# `compiler` (API_SPEC §5.8) is resolved FIRST, because the plan it expands to
# is what every tier gate below reads its own on/off state from.
function _build_evaluator_impl(
        model::Model;
        compiler::Union{Symbol, CompilerPlan} = :native,
        kwargs...
    )
    _xla_check_form(
        compiler isa Symbol ? compiler : compiler.name,
        get(kwargs, :form, :inplace)
    )
    # esm-spec §4.3.1.2: each recurrence group becomes its stacked single
    # recurrence plus one slice per member, before anything is laid out, so every
    # fill route sweeps it through the one recurrence implementation
    # (tree_walk/recurrence_group.jl). `nothing` — no group — changes nothing.
    stacked = _stack_recurrence_groups(
        model, get(kwargs, :index_sets, Dict{String, IndexSet}()),
        get(kwargs, :_template_reg, nothing)
    )
    if stacked !== nothing
        model = stacked[1]
        kwargs = merge(values(kwargs), (; index_sets = stacked[2]))
    end
    plan = _plan_for(compiler)
    record = _BuildRecord(plan)
    products = get(kwargs, :products, nothing)
    # The build's own context (compiler.jl): its plan and record, and fresh
    # build-scoped state, so nothing an earlier or a concurrent build left
    # behind is read.
    return _with_build_ctx(_new_build_ctx(plan, record)) do
        try
            return _build_evaluator_impl_inner(model; kwargs...)
        finally
            # The report is filled even when the build THREW: a refusal is
            # exactly the case a caller wants the partial tier record for.
            products === nothing || (products.compiler_report = _finish_report(record))
        end
    end
end

function _build_evaluator_impl_inner(
        model::Model;
        initial_conditions::AbstractDict = Dict{String, Float64}(),
        parameter_overrides::AbstractDict = Dict{String, Float64}(),
        tspan::Union{Nothing, Tuple{<:Real, <:Real}} = nothing,
        const_arrays::AbstractDict = Dict{String, Vector{Float64}}(),
        # Live forcing buffers bound BY REFERENCE.
        # Each value MUST be a dense `Array{Float64}`; its `index(…)`
        # reads compile to live `_NK_PARAM_GATHER` nodes over an
        # aliased flat view, so a discrete-cadence
        # refresh callback's in-place `buffer .= …` is seen by the
        # RHS with zero reallocation. This is the discrete-cadence
        # channel; const-cadence data stays on `const_arrays` (frozen
        # literal inlining). Disjoint from the scalar `p` NamedTuple
        # so existing scalar-param reads stay byte-identical + 0-alloc.
        param_arrays::AbstractDict = Dict{String, Any}(),
        # Per-const-array boundary policy: name → an
        # iterable of per-dimension policy symbols (:periodic |
        # :clamp | :error). A const array named here is wrapped so
        # an out-of-range stencil gather resolves declaratively
        # (periodic-wrap / edge-extend) instead of throwing.
        # Arrays absent from this map keep the throw-on-OOB
        # default. Mirrors the grid periodicity honored by the
        # state-variable gather.
        const_array_boundaries::AbstractDict = Dict{String, Any}(),
        # Document-scoped index-set registry (RFC §5.2; esm-spec
        # v0.8.0). Supplied by the `EsmFile` / `AbstractDict`
        # front-doors from the top-level `index_sets` object;
        # `ranges[*]` `{from}`, join gates, and derived-set ranges
        # resolve against it. Empty on a bare `Model` call.
        index_sets::AbstractDict = Dict{String, IndexSet}(),
        # Internal: value-invention materialisation results, set by
        # the AbstractDict front-door (RFC §6.1). `_vi_extents` maps a
        # `from_faq` producer id to its materialised derived-index-set
        # extent; `_vi_vars` are the value-invention LHS vars to drop
        # from the ODE (the relational outputs run once at setup, off
        # the hot path — never integrated). Empty on a direct call.
        _vi_extents::AbstractDict = Dict{String, Int}(),
        _vi_vars = Set{String}(),
        # Materialised value-invention map buffers (e.g. `src_bin`)
        # a downstream `join.on [[src_bin, tgt_bin]]` gates on, plus
        # each buffer's 1-D shape index set. Set by the AbstractDict
        # front-door; empty on a direct typed call (RFC §5.3 / §6.1).
        _vi_maps = _EMPTY_VI_MAPS,
        # The build's products record (see `BuildProducts`): when
        # non-nothing, filled with everything the build produced
        # besides the right-hand side. The right-hand side is the
        # same with or without it.
        products::Union{Nothing, BuildProducts} = nothing,
        # Discrete-cadence materialization sink (opt-in; see
        # DiscreteMaterializer). When non-nothing, a state-free
        # live-field array observed is cut out of the per-step RHS
        # into a cache buffer filled once per refresh, and the sink
        # is populated with the caches + `materialize!` closure. When
        # nothing (every existing caller), such fields stay inlined —
        # the pre-cut behavior, byte-identical.
        materialize_out::Union{Nothing, DiscreteMaterializer} = nothing,
        # Internal: the build-time parameter-READ set (see
        # `_record_param_read`). The AbstractDict front-door records
        # the two consumers that run BEFORE this entry
        # (`_derive_binning_coords`, `materialize_value_invention`)
        # and hands the same sink down, so the classification
        # covers every build-time consumer. A direct typed call
        # starts a fresh one.
        _param_reads::Union{Nothing, Set{String}} = nothing,
        # Internal: sink for the parameter PARTITION (name →
        # `:numeric` / `:structural` / `:const_folded` /
        # `:forcing`; see `_classify_parameters`). `esm_problem`
        # passes one and carries it on the `EsmProblem`, so
        # `parameter_classes(prep)` needs no sixth return value
        # — the same reasoning as `param_map`.
        _param_classes::Union{Nothing, AbstractDict} = nothing,
        # Internal: `esm_problem(…; runtime_array_parameters)`. A
        # shaped parameter whose value the document supplies is
        # registered as a live `param_arrays` buffer (added to the
        # caller's dictionary) instead of const data.
        _runtime_array_parameters::Bool = false,
        # Internal: a program build (src/rhs_program.jl). Every
        # externally fed shaped parameter is registered the same way,
        # whatever data the Problem bound to it.
        _live_fed_parameters::Bool = false,
        # Internal: the start of the run, `t0 = tspan[1]`, at which every
        # `ic` right-hand side is evaluated (esm-spec §11.4.2). `nothing`
        # takes the start of `tspan` (`_pick_tspan`). `esm_problem` passes
        # its own `tspan[1]`, which `sample_time` does not change.
        _ic_t0::Union{Nothing, Real} = nothing,
        # Internal: each data-fed parameter's value AT `_ic_t0`, keyed as
        # `param_arrays` is, for the ones whose live buffer holds another
        # instant (`sample_time` ≠ `t0`). An `ic` right-hand side reads
        # these; the forcing buffers are not touched (esm-libraries-spec
        # §2.5.2).
        _ic_data::AbstractDict = Dict{String, Any}(),
        # What to return in the RHS slot (tree_walk/oop.jl):
        # `:inplace` → the zero-alloc, eltype-generic evaluator
        # `f!(du, u, p, t)`; `:oop` → the compiled IR a compiled
        # backend lowers, which does not evaluate on the host.
        form::Symbol = :inplace,
        # Surviving `apply_expression_template` registry for the
        # selected model (esm-spec §9.6.4 Option B; name → raw
        # decl). Supplied by the `EsmFile` front-door when the
        # document carries references; `nothing` everywhere else.
        _template_reg = nothing,
        # Internal: the front door's expansion cache for `_template_reg`
        # (`_ExpandCache`), or `nothing`.
        _expand_cache = nothing,
        # Internal: the caller's initial state (`BuildOptions.caller_u0`).
        _caller_u0 = nothing
    )
    # An event, continuous or discrete, is refused before anything is built
    # (esm-spec §9.6.6): this evaluator has no event handling, so a model built
    # without its events would report a wrong answer. This check covers a model
    # handed to the builder directly. A FLATTENED system reaches this entry as a
    # run file, which carries no events, so `_prepare_run` refuses them earlier,
    # while the events are still in hand. The ModelingToolkit compiler runs both
    # kinds of event and does not come through here.
    build_form = _build_form(form)
    ev = _first_event(model)
    ev === nothing || throw(_event_refusal(ev))
    # An unknown carrying BOTH `D(x) ~ f` and `x ~ g` is one more equation than
    # this system has unknowns to bind (esm-spec §4.9.4), which `validate`
    # reports as `equation_count_mismatch`. Refused here under the same code,
    # before classification files the two equations into competing buckets and
    # the bare one falls out as an `E_TREEWALK_UNSUPPORTED_EQUATION` naming
    # neither the unknown nor either equation. A flattened system reaches this
    # entry as a run file, whose names are namespaced, so the message names the
    # unknown as the run document spells it.
    _refuse_doubly_defined_unknown(model.equations)
    # A DATA-FED parameter with nothing bound to it is refused here too, and for
    # the same reason (esm-spec §9.6.6 `data_source_unbound`, CONFORMANCE_SPEC
    # §5.46): binding it from its `default` would report a trajectory under the
    # label of a rate the document says is read from a file. The three registries are every channel a
    # value can have arrived through by now — the resolved `parameter_overrides`,
    # `const_arrays` (a CONST provider's materialized field, a gated provider's
    # fetched slab, and inline array data for a shaped parameter) and
    # `param_arrays` (the live buffer a DISCRETE provider rewrites). It sits at
    # the BUILD entry rather than in `esm_problem` so that `_build_evaluator` and
    # `run_inline_tests` answer identically, and before anything is compiled so
    # that the answer does not depend on the `compiler`.
    _refuse_unbound_data_feeds(
        model, parameter_overrides, const_arrays,
        param_arrays
    )
    # A Wiener-noise parameter makes the document an SDE, which this evaluator
    # does not integrate (esm-spec §9.6.6); refused on the same terms.
    wiener = _first_wiener_parameter(model)
    wiener === nothing || throw(_wiener_refusal(wiener))
    # A parameter recomputed by a symbolic update is an event in all but name.
    symbolic = _first_symbolic_update(model)
    symbolic === nothing || throw(_symbolic_update_refusal(symbolic...))
    # ---- Template references: compiled as calls (tree_walk/call.jl) ----
    # No reference is expanded: each stays a reference and compiles as a call;
    # an array-valued or aggregate one read whole (or an element of an
    # aggregate one) is its view (`_tpl_prepare_model!`), and one the build
    # cannot compile is refused. Preparation works on a copy
    # (`_expansion_copy`): the caller's typed model keeps its references
    # (`serialize_esm_file` emits them verbatim — R1).
    if _template_reg !== nothing
        model = _expansion_copy(model)
        # The build's own registry: structural instances and view parts are
        # registered in it, never in the caller's (call.jl `_tpl_prepare_model!`).
        _template_reg = copy(_template_reg)
        model, _ = _tpl_prepare_model!(model, _template_reg, index_sets, _vi_extents)
        _expand_cache = nothing
    elseif _model_has_surviving_refs(model)
        # A surviving reference with no registry in reach would compile into an
        # opaque op node and only fail at RHS evaluation time — fail loudly at
        # build time instead. Reached only by callers that hand a
        # reference-preserving `Model` directly to the evaluator without its
        # document's `expression_templates`; every document front-door threads
        # the registry.
        throw(
            TreeWalkError(
                "E_TREEWALK_UNRESOLVED_TEMPLATE_REF",
                "model carries apply_expression_template references but no " *
                    "expression_templates registry reached the build; construct via " *
                    "an EsmFile/document front-door (esm-spec §9.6.4 Option B)"
            )
        )
    end
    # ---- esm-spec §4.3.1 `faq_bare_array_operand` ----
    # `validate` (and the front door's reference-integrity refusal) cannot see a
    # bare shaped name a template binding delivers into a `faq` filter; the
    # check reads a call's value operands (call.jl `_value_operands`).
    _refuse_faq_bare_array_operands(model)
    # ---- §9.6.3 constraint 6: walk every equation for an unlowered op ----
    # BEFORE any pass that drops a tree (the elementwise fold, dead-observed
    # elimination), so an op in a tree the build would discard is still refused.
    # The front door gated the same expansions: what it passed is not walked again.
    if _expand_cache isa _ExpandCache
        _reject_unlowered_operators(model, _expand_cache.gate_lhs, _expand_cache.gate_rhs)
    else
        _reject_unlowered_operators(model)
    end
    # ---- esm-spec §6.3.1: an equation never defines a parameter ----
    _refuse_parameter_definitions(model.equations, model.variables)
    # ---- `broadcast` lowering (esm-spec §4.3.4; see `_lower_broadcast_model`) ----
    # Rewrite every `broadcast(fn=F, …)` node to its plain scalar-op spelling
    # `F(…)` BEFORE any other pass sees it, so `broadcast` has exactly the
    # element-wise semantics of the op it names — one node kind for the fold /
    # CSE / stencil / evaluator ladders, and the spec identity
    # `broadcast(fn=F,[x]) ≡ F(x)` holds by construction. Runs AFTER template
    # expansion (a template body may produce a `broadcast`) and BEFORE interning
    # (so the interned DAG is the lowered one). Identity — hence byte-identical —
    # for a model with no `broadcast` node.
    model = _lower_broadcast_model(model)
    # ---- Structural interning (hash-consing) of the expression AST (perf
    # plan A1; src/intern.jl). Every build pass below is identity-memoized;
    # interning makes textually identical subtrees (which template inlining
    # manufactures as fresh copies) the SAME object, so those memos hit.
    # Returns a NEW Model sharing untouched sub-objects — the caller's model
    # is never mutated. With interning off the pass is skipped entirely.
    if !_intern_disabled()
        ictx = _InternCtx()
        model = _intern_model(model, ictx)
    end
    # ---- Nested reductions lifted to internal observeds (hoist.jl) ----
    # Only where array observeds are factored: the interpreter inlines them, so
    # it builds the authored body.
    _array_obs_inline_forced() ||
        ((model, index_sets, _) = _hoist_nested_reductions(model, index_sets))
    # ---- Caller-key canonicalization (esm-spec §6.6) ----
    # A spec-spelled LOCAL override key (`pert_amp`) is rewritten onto the
    # flattening-qualified parameter name the build resolves (`M.pert_amp`)
    # BEFORE any consumer reads it, so the same map binds the parameter
    # NamedTuple, the coordinate-expression `ic` seed, the setup env, and
    # `products.params`. Idempotent — the AbstractDict front-door normalizes
    # too.
    parameter_overrides = _normalize_param_override_keys(model, parameter_overrides)
    # ---- Inline array data (esm-spec §6.3 / §6.6.2) ----
    # A SHAPED parameter whose value the document supplies — a row-major nested
    # array on its own `default` or in the caller's `parameter_overrides`, or one
    # SCALAR broadcast over the declared grid (§6.3) — is BUILD-TIME DATA, not a
    # scalar `p` slot. Register it in the const-array registry, which is exactly
    # the channel `_partition_variables` already requires an array-shaped
    # parameter to be backed by; nothing else in the build then needs to know the
    # column was authored inline rather than loaded. A shaped UNKNOWN's inline
    # `initial_conditions` profile is expanded into the per-cell keys `_build_u0`
    # seeds from. Both are no-ops (and the registries byte-identical) for a
    # document that declares no shaped parameter.
    const_arrays = _normalize_const_array_keys(model, const_arrays)
    # A boundary policy is keyed by the same caller spelling as its array, so it
    # resolves by the same rule: the policy reaches the name the equations read.
    const_array_boundaries = _normalize_const_array_keys(model, const_array_boundaries)
    # A derived index set value invention has already sized (the front door
    # ran it) resolves a declared shape here too, keyed by the SET's name.
    vi_set_extents = isempty(_vi_extents) ? _EMPTY_DERIVED_EXTENTS :
        Dict{String, Int}(
            String(k) => Int(_vi_extents[is.from_faq])
            for (k, is) in index_sets
            if is.kind == "derived" && is.from_faq !== nothing &&
            haskey(_vi_extents, is.from_faq)
        )
    const_arrays = _register_inline_array_parameters(
        model, const_arrays,
        parameter_overrides, index_sets;
        param_arrays = param_arrays,
        derived_extents = vi_set_extents,
        runtime = _runtime_array_parameters,
        live_fed = _live_fed_parameters
    )
    const_arrays = _scalar_overrides_over_supplied(
        model, const_arrays, param_arrays, parameter_overrides
    )
    initial_conditions = _expand_inline_array_ics(model, initial_conditions, index_sets)
    # ---- Phase 1: equation pre-lowering + build-owned variable classification ----
    cls = _build_lower_and_classify(
        model;
        const_arrays = const_arrays, param_arrays = param_arrays, vi_vars = _vi_vars,
        materialize_out = materialize_out, index_sets = index_sets
    )

    # The build-time parameter-read sink: continued from the front door (which
    # already recorded binning-coordinate derivation + value invention) or fresh.
    param_reads = _param_reads === nothing ? Set{String}() : _param_reads

    # ---- Phase 2: ODE partition + setup materialization + equation rewrites ----
    parts = _build_partition_and_materialize(
        model, cls;
        index_sets = index_sets, const_arrays = const_arrays,
        param_arrays = param_arrays, parameter_overrides = parameter_overrides, vi_vars = _vi_vars,
        vi_extents = _vi_extents, vi_maps = _vi_maps,
        param_reads = param_reads,
        ic_t0 = _ic_t0 === nothing ? _pick_tspan(tspan)[1] : Float64(_ic_t0),
        ic_data = _ic_data
    )
    # A range-restricted program (src/range/tile.jl) clips the equation
    # stream to the cells its owned box needs, before any cell is laid out.
    parts = _range_restrict_parts(
        _range_spec_now(), model, cls, parts, index_sets,
        const_arrays, param_arrays
    )

    # ---- Phase 3: array-cell discovery + flat state layout + u0/p ----
    # The build-time ARRAY scope a field `ic` resolves against (esm-spec §6.6.5
    # "Build-time evaluation scope"): the same storage the right-hand side and
    # the scalar `ic` fold read, by the one precedence rule of
    # `_overlay_build_time_arrays!` — the caller's const arrays, the setup
    # arrays this build materialized, and the STATE-FREE array observeds
    # (`cls.const_obs_arrays`: a `const`-op gather, a shaped parameter's inline
    # column, a bare-alias re-exposure). Such a field is resolvable before the
    # simulation runs, so §11.4.1 admits it as an `ic` right-hand side alongside
    # a loaded field, a constant and a coordinate expression.
    ic_const_arrays = _overlay_build_time_arrays!(
        Dict{String, Any}(String(k) => v for (k, v) in const_arrays),
        parts.geom_setup_arrays, cls.const_obs_arrays
    )
    layout = _build_state_layout(
        model, cls, parts;
        initial_conditions = initial_conditions, index_sets = index_sets, const_arrays = ic_const_arrays,
        vi_vars = _vi_vars, param_reads = param_reads,
        unvalued = products === nothing ? nothing : empty!(products.unvalued_slots)
    )

    # `remake` with a new start re-evaluates the `ic` right-hand sides through
    # this. An initialization equation (esm-spec §6.2) reads the seeded state
    # in a later phase, which a re-seed would not replay, so such a build
    # refuses the move instead of returning a state the equations did not see.
    if products !== nothing
        products.ic_reseed = layout.ic_reseed === nothing ? nothing :
            isempty(parts.init_equations) ? layout.ic_reseed :
            (_, _) -> throw(
                TreeWalkError(
                    "E_TREEWALK_UNSUPPORTED_EQUATION",
                    "the initial state reads the start of the run (an `ic` right-hand " *
                    "side reads `t` or a data-fed parameter) and the model has " *
                    "initialization equations, which a re-seed at a new start would not " *
                    "re-solve; build the problem again with esm_problem at the new tspan"
                )
            )
    end

    # ---- The parameter partition ----
    # Every build-time consumer has now run, so the read set is complete.
    # Published to whichever sinks the caller supplied; never changes the build.
    if _param_classes !== nothing || products !== nothing
        classes = _classify_parameters(
            model, parts.param_names, param_reads,
            const_arrays, param_arrays
        )
        if _param_classes !== nothing
            for (k, v) in classes
                _param_classes[k] = v
            end
        end
        if products !== nothing
            for (k, v) in classes
                products.param_classes[k] = v
            end
        end
    end

    # ---- Phase 4: registry + forcing buffers + derivative compile + closure ----
    return _build_compile_evaluator(
        model, cls, parts, layout;
        index_sets = index_sets, const_arrays = const_arrays,
        const_array_boundaries = const_array_boundaries, param_arrays = param_arrays,
        initial_conditions = initial_conditions, tspan = tspan, products = products,
        materialize_out = materialize_out, form = build_form,
        caller_u0 = _caller_u0
    )
end

# The build's time span: the caller's, else `(0.0, 1.0)`. An inline test's
# `time_span` belongs to that test (esm-spec §6.6) and is not a default for the
# system; the flattened system the build reads carries no tests.
_pick_tspan(tspan) = tspan === nothing ? (0.0, 1.0) : (Float64(tspan[1]), Float64(tspan[2]))

# A materialized observed `name` of the right-hand side's fill levels that is a
# causal self-reference: its ordered sweep (recurrence_sweep.jl), its report row
# and its inspection record; `nothing` for any other name. The out-of-place
# product has no sweep section, so a compiler that builds it refuses the rule by
# name.
function _level_recurrence(
        name::String, form::_BuildForm, recur_names::Set{String},
        mat_defs::Dict{String, ASTExpr}, layout::_StatePlan, model::Model,
        resolved_obs::Dict{String, ASTExpr}, cs::_CompileScope,
        products::Union{Nothing, BuildProducts}
    )
    name in recur_names || return nothing
    _check_recurrence_form(form, name)
    sw = _compile_recurrence_sweep(
        name, mat_defs[name],
        layout.mat_dims[name], get(model.variables, name, nothing), resolved_obs, cs
    )
    _record_rule!(name, :observed, _recurrence_tier(sw))
    products === nothing ||
        push!(products.recurrences, _recurrence_info(name, mat_defs[name], sw))
    return sw
end
