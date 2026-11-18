# tree_walk/build_pipeline.jl — the four build phases and `_build_evaluator_impl`.

# ============================================================
# 2c. Build phases
# ============================================================
# `_build_evaluator_impl` runs as four named phases, each a function of the
# previous phases' NamedTuple-packed products (the packing only NAMES what used
# to be ~20 locals threaded through one 400-line body; stage order and
# semantics inside each phase are exactly the pre-split impl):
#   1. `_build_lower_and_classify`        — equation pre-lowering + the
#      build-owned variable classification (`cls`).
#   2. `_build_partition_and_materialize` — the ODE variable partition, scalar
#      parameter scope, setup-time geometry materialization, and the
#      equation-stream rewrites down to the ic fold (`parts`).
#   3. `_build_state_layout`              — array-cell discovery, the flat
#      state-vector layout, u0 seeding, and the parameter NamedTuple (`layout`).
#   4. `_build_compile_evaluator`         — observed split, const-array
#      registry, forcing buffers, derivative compile + CSE, and the closure.

# ---- Phase 1: equation pre-lowering + build-owned variable classification ----
# Everything through the bare-alias registration: the synthesized/folded/lifted
# equation stream plus the classification sets naming which array observeds are
# owned by a setup/inline/materialize mechanism (and therefore carry no ODE
# partition slot). `geom_inline_vars`/`array_inline_vars` are returned already
# discrete-cut-adjusted when a `materialize_out` sink opted in.
function _build_lower_and_classify(
        model::Model;
        const_arrays::AbstractDict, param_arrays::AbstractDict,
        vi_vars, materialize_out, index_sets = nothing
    )
    # ---- Observed synthesis + equation pre-lowering ----
    # (see `_prepare_model_equations`: expression-defined observed synthesis,
    # WS4 elementwise array-observed fold, whole-array derivative lift)
    equations, folded_array_obs = _prepare_model_equations(model; vi_vars = vi_vars)

    # ---- Geometry variable discovery ----
    # (see `_discover_geometry_vars`: build-once setup vars, live-field inline
    # vars, and the has_* gate)
    geo = _discover_geometry_vars(model, equations, param_arrays, vi_vars; index_sets = index_sets)
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
            equations, union(geom_inline_vars, array_inline_vars),
            copy(array_inline_vars), pre_state,
            Set{String}(String(k) for k in keys(param_arrays)), scalar_params
        )
        if !isempty(recur_vars)
            reach = _recurrence_readers(equations, recur_vars)
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

# The names in `recur_vars` and every observed that reads one of them, directly
# or through other observed definitions.
function _recurrence_readers(equations::Vector{Equation}, recur_vars::Set{String})
    defs = Dict{String, ASTExpr}()
    for eq in equations
        eq.lhs isa VarExpr && (defs[(eq.lhs::VarExpr).name] = eq.rhs)
    end
    reach = copy(recur_vars)
    _saturate!() do
        changed = false
        for (n, rhs) in defs
            n in reach && continue
            if any(r -> r in reach, _referenced_var_names(rhs))
                push!(reach, n); changed = true
            end
        end
        changed
    end
    return reach
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
        template_sites::Union{Nothing, IdDict{OpExpr, OpExpr}} = nothing,
        index_sets::AbstractDict, const_arrays::AbstractDict,
        param_arrays::AbstractDict, parameter_overrides::AbstractDict, vi_vars, vi_extents::AbstractDict,
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
        model;
        vi_vars = vi_vars, geom_setup_vars = cls.geom_setup_vars,
        geom_inline_vars = cls.geom_inline_vars,
        array_inline_vars = cls.array_inline_vars,
        folded_array_obs = cls.folded_array_obs,
        const_obs_vars = cls.const_obs_vars,
        const_arrays = const_arrays, param_arrays = param_arrays,
        discrete_vars = cls.discrete_vars
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
    _translate_equation_sites!(template_sites, ode_equations, equations)

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
        _translate_equation_sites!(template_sites, pre, equations)
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
        initial_conditions::AbstractDict, index_sets::AbstractDict, const_arrays::AbstractDict, vi_vars,
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

# ---- Phase 4: registry + forcing buffers + derivative compile + closure ----
# Observed substitution, the merged const-array registry, the live forcing
# buffers, the (opt-in) discrete-cadence materializer, u0 seeding from
# faq-valued initialization equations, the per-derivative compile + CSE,
# and the final `f!` closure. Returns the full `_build_evaluator_impl` result.
function _build_compile_evaluator(
        model::Model, cls::_VariableClasses, parts::_EquationPartition, layout::_StatePlan;
        index_sets::AbstractDict = Dict{String, Any}(), const_arrays::AbstractDict,
        const_array_boundaries::AbstractDict, param_arrays::AbstractDict,
        initial_conditions::AbstractDict, tspan, products, materialize_out,
        form::Symbol,
        template_sites::Union{Nothing, IdDict{OpExpr, OpExpr}} = nothing,
        caller_u0 = nothing
    )
    u0 = layout.u0
    p = layout.p
    param_sym_set = layout.param_index
    n_states = _n_states(layout)
    # The layout hands back TWO maps: the ODE-only one (`var_map` — the public
    # return, and the scope the setup-time seeding evaluates in, where the
    # observed buffers do not exist yet) and the EXTENDED one that also carries
    # the factored array-observed buffer slots. Everything the per-call RHS
    # compiles against uses the extended pair.
    var_map = layout.var_map_ext
    array_var_info = layout.array_var_info_ext
    n_total = _n_total(layout)
    # The materialized set, narrowed to the observeds whose buffer extents
    # actually resolved (`mat_dims`); the rest stayed on the inline path.
    mat_vars = Set{String}(keys(layout.mat_dims))

    # ---- Observed substitution / derivative-equation split ----
    split = _split_observed_and_derivatives(
        parts.equations,
        parts.observed_names, cls.geom_setup_vars,
        cls.geom_inline_vars, cls.array_inline_vars, mat_vars,
        Set{String}(n for (n, v) in model.variables if _is_array_shape(v.shape))
    )
    derivative_eqs = split.derivatives
    resolved_obs = split.resolved
    raw_obs = split.raw
    mat_defs = split.materialized

    # ---- Const-array registry (caller arrays + boundaries + setup geometry) ----
    const_registry = _register_const_arrays(
        const_arrays, const_array_boundaries,
        parts.geom_setup_arrays, cls.const_obs_arrays
    )

    # ---- The build's products (see `BuildProducts`) ----
    # Copy the named build-time products into the record. The right-hand side
    # does not consult them.
    if products !== nothing
        for (k, arr) in parts.geom_setup_arrays
            # Published by reference, as the const arrays below are.
            products.setup_arrays[String(k)] = arr isa Array{Float64} ? arr : Array{Float64}(arr)
        end
        for (k, arr) in const_registry
            products.const_arrays[String(k)] = arr
        end
        # The observed map published here is the FULLY RESOLVED one — the same
        # bytes as before this change. A factored array observed no longer sits
        # in the RHS substitution map (its readers gather its buffer), but the
        # observability surface is not the RHS: `_observed_field`
        # (inline_tests.jl, esm-spec §6.6.5) evaluates an asserted array
        # observed's expression CELLWISE, off the ODE path, so every reference
        # in it must be substituted — including references between factored
        # observeds. Re-resolving the merged map restores exactly that, and only
        # when a record asked for it.
        # A recurrence's definition reads itself, so it has no fully substituted
        # form: it is published as authored, and the others around it.
        recur_pub = _recurrence_names(mat_defs, mat_vars)
        published = isempty(mat_defs) ? resolved_obs :
            _resolve_observed(
                merge(
                    Dict{String, ASTExpr}(resolved_obs),
                    Dict{String, ASTExpr}(
                        k => v for (k, v) in mat_defs
                        if !(k in recur_pub)
                    )
                )
            )
        if !isempty(recur_pub)
            published = Dict{String, ASTExpr}(published)
            for k in recur_pub
                published[k] = mat_defs[k]
            end
        end
        # Filled as each sweep compiles (below), so the sweep's own checks
        # run first and decide any error the build raises.
        empty!(products.recurrences)
        for (k, e) in published
            _is_hoisted_name(String(k)) || (products.observed_exprs[String(k)] = e)
        end
        # ALSO publish the UN-inlined per-observed definitions, so a build-time
        # field evaluation can materialize each producer once in dependency order
        # instead of re-executing the chain per output cell (see
        # `BuildProducts`). `observed_exprs` above keeps the substituted view.
        for (k, e) in raw_obs
            _is_hoisted_name(String(k)) || (products.observed_defs[String(k)] = e)
        end
        # Keyed by the PRODUCER id (`"emis_src_cells_faq" => 9`), exactly as the
        # build holds it. A consumer resolving a `kind:"derived"` axis follows the
        # set's `from_faq` to this map (see `_materialized_obs_scope`).
        for (k, n) in parts.derived_extents
            products.derived_extents[String(k)] = Int(n)
        end
        # Resolved scalar parameter values (load-time constants) so a build-time
        # cellwise re-evaluation of a parameter-dependent observed / reference
        # (§6.6.5) binds them — see `evaluate_cellwise(...; params=…)`.
        for (k, val) in parts.param_scope
            products.params[String(k)] = val
        end
    end

    # ---- Live forcing buffers (ess-14f.3, JL-J0) ----
    # (see `_build_pgather` for the feasibility-gate design note)
    pgather = _build_pgather(param_arrays)
    _ws_note_pgather!(pgather)
    # The two scopes the build compiles against: the state-only one (the
    # construction-time fills and the output-time reads, where the observed
    # buffers do not exist) and the right-hand side's, whose layout adds the
    # materialized observeds' buffer blocks. Both read the same registries;
    # the discrete materializer adds its caches to `pgather` below.
    state_scope = _CompileScope(
        layout.array_var_info, layout.var_map, const_registry, pgather, param_sym_set
    )
    rhs_scope = _CompileScope(array_var_info, var_map, const_registry, pgather, param_sym_set)
    # This build's forcing epoch: the problem's (its discrete sink carries it),
    # bumped when a refresh of a buffer the build reads is announced to its owner.
    forcing_epoch = materialize_out === nothing ? _new_forcing_epoch() :
        materialize_out.epoch
    products === nothing || (products.forcing_epoch = forcing_epoch)

    # ---- Discrete-cadence materialization: cache buffers + fill kernels ----
    # (the middle cadence phase; see DiscreteMaterializer). Each discrete var gets a
    # cache buffer added to `pgather`, so a downstream reader (a state RHS or a
    # later discrete fill) GATHERS it live instead of inlining the whole met→physics
    # stack. Runs BEFORE u0 seeding + derivative compile so both read the caches; the
    # initial fill (inside) makes them valid immediately. No-op without the sink.
    # Both the discrete fills and the u0 seeding run OUTSIDE the per-call RHS, so
    # they compile against the ODE-ONLY layout: an observed buffer holds nothing
    # valid there (a name that reaches one keeps the inline path — see
    # `_collect_materialized_array_obs`).
    discrete_refill = materialize_out === nothing ? nothing :
        _build_discrete_materializer!(
            materialize_out, cls.discrete_vars, parts.discrete_defs, resolved_obs,
            state_scope, p, n_states
        )

    # ---- The compiled observed program's context (observed_program.jl) ----
    # Output-time reads compile against this build's ODE layout, its const
    # arrays, live buffers (discrete caches included) and parameters. Captured
    # only for a build with a sink to hold it; nothing here runs until a read.
    if products !== nothing
        products.observed_ctx = _ObsProgramCtx(
            model, cls, parts, index_sets, state_scope, n_states, p, template_sites,
            materialize_out === nothing ? Dict{String, Array{Float64}}() :
                materialize_out.caches,
            merge(Dict{String, ASTExpr}(raw_obs), mat_defs),
            _state_base_names(layout.var_map, layout.array_var_info),
            Dict{String, Any}(), ReentrantLock()
        )
    end

    # ---- Evaluate faq-valued initialization_equations into u0 ----
    # A caller's u0 override (esm_problem's `u0`) is part of the state the
    # equations read, and a cell it names keeps it.
    caller_slots = _apply_caller_u0!(u0, layout.var_map, parts.init_equations, caller_u0)
    _seed_faq_init_u0!(
        u0, parts.init_equations, initial_conditions, state_scope, p;
        skip_slots = caller_slots
    )

    # ---- Scalar-observed slot plan (named prelude defs; ess-obs-slots) ----
    # Decide which scalar observeds compile as named prelude slots and which
    # stay inlined (see `_plan_observed_slots`). The SCALAR equation arms then
    # substitute only the non-slot observeds; every array path below keeps the
    # full `resolved_obs` and is byte-identical to the pre-slot build.
    obs_plan = _plan_observed_slots(
        derivative_eqs, raw_obs, resolved_obs,
        parts.observed_names
    )
    # Each slot def resolves through the SAME context the scalar entries use,
    # in dependency order (a def may read a state gather / const array / live
    # forcing buffer exactly as its inlined copy did).
    obs_defs = Pair{String, ASTExpr}[
        name => _resolve_in(rhs_scope, body) for (name, body) in obs_plan.defs
    ]

    # ---- Factored array-observed fill kernels (per RHS call, dependency order) ----
    # Each materialized observed compiles through the SAME array-equation cascade
    # its readers do, via a synthesized `faq(D(index(obs, i…))) = <body>`
    # equation whose output slots land in the observed's buffer block. Kernels are
    # class-merged WITHIN a level only — the merge reorders, and levels are an
    # ordering constraint. Empty (and the closure below unwrapped) when nothing
    # is materialized.
    #
    # ess-scan INSIDE A FILL. The fill cascade is the SAME cascade the state
    # equations take, so it can return `_ScanFold`s, and they are collected PER
    # LEVEL and applied after that level's kernel section over the extended
    # vector the fills write into — a fold reads back only the slots its own term
    # kernels wrote, and no observed in a level can read another observed of the
    # SAME level (that is what a level means), so folding once behind the
    # class-merged section is exactly the ordering `_make_rhs` gives the state
    # equations. Dropping them would leave the buffer holding the per-cell TERMS
    # instead of their running accumulation — a silent wrong answer, so the
    # plumbing is not optional.
    #
    # The list is NOT empty in general, and it is `_unwrap_identity_gather` that
    # fills it. A fill's RHS is the GATHER `index(<def>, i…)`
    # (`_materialized_fill_equation`), which hides the aggregate from
    # `_compile_faq_equation!` — but when the producer underneath actually
    # CONTRACTS, the wrapper is lifted, `_detect_prefix_scan` sees the aggregate
    # and a materialized observed defined by a prefix reduction lands here as a
    # per-level `_ScanFold`. ReSEACT's diagnosed vertical air-mass flux
    # (`Mz[ke] = -Σ_{k < ke} …` over the level NODES contracting the level
    # centres) is exactly that shape, and it arrives as one fold on the level
    # that materializes `Mz`. Note the consequence a consumer of `mat_levels`
    # has to handle: a STAGGERED fold's last output node is left uncovered by the
    # term kernels on purpose (see `_scan_term_iters`), so the fold reads a slot
    # of the observed's buffer that nothing in the fill wrote — zero out of a
    # freshly allocated extended vector, whatever the in-place buffer held
    # before — and folds it into an accumulator it then discards.
    # `mat_levels` carries the `:inplace` shape
    # `(scalars, _KernelSection, scans, _ContractionSection)` that
    # `_fill_obs_levels!` consumes; `mat_levels_oop` carries the same fills as
    # `(scalars, kernels, oop_plans, scans, array_contractions)` because the
    # out-of-place runners take the kernel and its plan separately rather than a
    # fused callable. Only
    # the emitter actually being built is populated.
    mat_levels = Any[]
    mat_levels_oop = Any[]
    mat_scan_fold_count = 0
    mat_array_contraction_count = 0
    mat_recurrence_count = 0
    mat_const_levels = Any[]
    mat_time_levels = Any[]
    recur_names = _recurrence_names(mat_defs, mat_vars)
    # The const-cadence observeds fill in their own levels, ahead of the rest
    # and only when `p` moves (`_make_rhs_with_obs_buffers`). The untiered
    # build (`compiler = :interpreter`, the oracle) refills everything on every
    # call, as its prelude does; the out-of-place product has no such skip.
    mat_const = if form === :inplace && !_untiered() && !isempty(mat_vars)
        dyn_seed = _state_base_names(layout.var_map, layout.array_var_info)
        push!(dyn_seed, "t")
        union!(dyn_seed, keys(pgather))
        _const_cadence_mat_obs(
            mat_defs, mat_vars, raw_obs, dyn_seed,
            param_sym_set, const_registry
        )
    else
        Set{String}()
    end
    # The time-cadence observeds: no state anywhere below them, but `t` or a
    # live buffer (a `param_arrays` buffer, a discrete cache) somewhere.
    mat_time = if form === :inplace && !_untiered() && !isempty(mat_vars)
        tleaves = Set{String}(keys(pgather))
        push!(tleaves, "t")
        setdiff!(
            _const_cadence_mat_obs(
                mat_defs, mat_vars, raw_obs,
                _state_base_names(layout.var_map, layout.array_var_info),
                param_sym_set, const_registry, tleaves
            ), mat_const
        )
    else
        Set{String}()
    end
    level_plan = Tuple{Vector{String}, Symbol}[]
    if !isempty(mat_vars)
        isempty(mat_const) || foreach(
            l -> push!(level_plan, (l, :const)),
            _materialized_obs_levels(mat_defs, mat_const, raw_obs)
        )
        isempty(mat_time) || foreach(
            l -> push!(level_plan, (l, :time)),
            _materialized_obs_levels(mat_defs, mat_time, raw_obs)
        )
        foreach(
            l -> push!(level_plan, (l, :dynamic)),
            _materialized_obs_levels(
                mat_defs,
                setdiff(mat_vars, mat_const, mat_time), raw_obs
            )
        )
    end
    # A causal self-reference is an ordered sweep, not a fill equation
    # (`_level_recurrence`).
    level_recurrence = let form = form, recur_names = recur_names, mat_defs = mat_defs,
            layout = layout, model = model, resolved_obs = resolved_obs,
            rhs_scope = rhs_scope, products = products
        name -> _level_recurrence(
            name, form, recur_names, mat_defs, layout, model, resolved_obs, rhs_scope,
            products
        )
    end
    level_fill = let mat_defs = mat_defs, layout = layout, array_var_info = array_var_info
        name -> _range_fill_equations(
            _range_spec_now(), name, mat_defs[name], layout.mat_dims[name], array_var_info[name]
        )
    end
    pending_levels = _LevelParts[]
    for (lvl, lvl_cadence) in level_plan
        lv = _compile_fill_level(
            lvl, lvl_cadence, level_fill, level_recurrence, resolved_obs, rhs_scope, n_total;
            template_sites = template_sites,
            rhs_list_compiled = form === :oop,
            obs_nst = form === :inplace ? n_states : 0
        )
        mat_scan_fold_count += length(lv.scans)
        mat_array_contraction_count += length(lv.contractions)
        mat_recurrence_count += length(lv.recurrences)
        if form === :oop
            merged, _ = _merge_acc_kernel_classes(lv.kernels)
            push!(
                mat_levels_oop,
                _OopFillLevel(
                    lv.scalars, merged,
                    _OopAccPlan[_build_oop_acc_plan(K) for K in merged],
                    lv.scans, lv.contractions
                )
            )
        else
            # The in-place sections are made once the state equations are
            # compiled, so a fused scan can take in a state kernel that
            # consumes it (`_scan_consumer_plan`).
            push!(pending_levels, lv)
        end
    end
    products === nothing || sort!(products.recurrences; by = r -> r.var)

    # ---- Build per-derivative compiled-IR list ----
    # (see `_compile_derivative_equations` / `_compile_faq_equation!`)
    # `array_var_info` here is the EXTENDED map (`layout.array_var_info_ext`,
    # bound above): a reader's `index(<materialized observed>, i…)` must resolve
    # through the ordinary array-gather path onto the observed's buffer block.
    # `scan_folds` is the ess-scan post-pass list for the STATE equations.
    state_eqs = _compile_derivative_equations(
        derivative_eqs, resolved_obs, rhs_scope, n_states; template_sites = template_sites,
        scalar_obs_inline = obs_plan.inline,
        rhs_list_compiled = form === :oop,
        obs_nst = (form === :inplace && n_total > n_states) ? n_states : 0
    )
    scalar_entries = state_eqs.scalar_entries
    percell_scalar = state_eqs.percell
    acc_kernels_pre = state_eqs.kernels
    scan_folds = state_eqs.scan_folds
    array_contractions = state_eqs.contractions
    # States without a D(...) equation get du=0 (integrator leaves them
    # at their initial value — a common pattern for reified constants).

    # ---- Kernel-CLASS merge (oop_merge.jl), for BOTH emitters ----
    # Collapse per-cell-fragmented same-structure kernels into lane-batched
    # class kernels — value-exact (bit-identical output on every runner), and on a
    # class-fragmented model an order-of-magnitude reduction in kernel count. For
    # a compiled backend it is the difference between a program that compiles and
    # one that does not. MUST run here, before the xcse
    # gate below: xcse rewrites kernel invariant-tier defs into SCALAR-cache
    # reads (`_NK_CACHED` payloads that are no kernel's scratch), which the
    # merge signature/clone does not model — merge first, then xcse runs over
    # the (fewer) merged kernels. Bound ONCE to a fresh local (`acc_kernels`),
    # never reassigned, so every downstream closure captures it unboxed.
    # With the class merge off the build is the unmerged one, byte for byte.
    # The in-place build keeps its affine box kernels out of the merge
    # (`keep_affine`, oop_merge.jl), so the emitter compiles each as its own
    # loop nest instead of a slot-table lane loop.
    # The per-cell reference is untouched either way: its trees live on
    # `percell_scalar`, never in the kernel list.
    # A state scan whose term kernel compiles into its fold's own pass
    # (scan_fused.jl) leaves that kernel out of the merge and the section.
    n_state_scan_folds = length(scan_folds)
    state_fused_scans = ()
    # The state RHS runs on the two-buffer slot space (`_ObsSplitVec`) only
    # when something is materialized; its generated code then addresses each
    # buffer directly.
    obs_nst = n_total > n_states ? n_states : 0

    # ---- The in-place observed levels' sections ----
    # A scan whose term kernel compiles into its fold's own pass (scan_fused.jl)
    # leaves that kernel out of the level's section, and a state kernel it
    # takes in as its consumer leaves the state kernels.
    if !isempty(pending_levels)
        consumers = _scan_consumer_plan(
            pending_levels, acc_kernels_pre, n_states,
            scalar_entries, percell_scalar, array_contractions,
            (raw_obs, mat_defs, resolved_obs)
        )
        consumed = IdDict{Any, Bool}()
        for lv in pending_levels
            lvl_kernels, lvl_scans, lvl_fused =
                _detach_fused_scans(
                lv.kernels, lv.scans; nst = n_states,
                consumers = consumers, consumed = consumed
            )
            lvl_acs = lv.cadence === :dynamic ?
                _ac_take_consumers(lv.contractions, acc_kernels_pre, n_states, consumed) :
                lv.contractions
            push!(
                lv.cadence === :const ? mat_const_levels :
                    lv.cadence === :time ? mat_time_levels : mat_levels,
                _inplace_fill_level(
                    lv.scalars, lvl_kernels, _make_scan_section(lvl_scans, lvl_fused),
                    lvl_acs, lv.recurrences; nst = n_states
                )
            )
        end
        isempty(consumed) ||
            (acc_kernels_pre = _AccKernel[K for K in acc_kernels_pre if !haskey(consumed, K)])
    end
    if form === :inplace
        acc_kernels_pre, scan_folds, state_fused_scans =
            _detach_fused_scans(acc_kernels_pre, scan_folds; nst = obs_nst)
    end
    acc_kernels, class_merge_diag = _merge_acc_kernel_classes(
        acc_kernels_pre;
        keep_affine = form === :inplace
    )

    # ---- Common-subexpression elimination on the scalar/indexed-D RHS (ess-r7h) ----
    # Batched compile of every scalar resolved-RHS expr: subexpressions sharing a
    # canonical_json key (within one RHS or across equations) are compiled once
    # into a prelude that fills a per-call scratch cache, and each occurrence is a
    # `_NK_CACHED` ref. Numerically identical to per-equation `_compile`; with no
    # shared subexpressions the prelude is empty and the rhs nodes are byte-identical.
    # `has_pgather` tells the pass whether any resolved live-forcing gather can be in
    # the trees — if so it keys them through a canonicalizable stand-in, without which
    # every expression built over a forcing buffer declines sharing (ess-qic). Note
    # `pgather` holds BOTH the raw `param_arrays` buffers and the discrete-cadence
    # caches, which is why this is read after `_build_discrete_materializer!` ran.
    rhs_list, scalar_prelude, scalar_cache, cse_diag =
        _cse_compile_scalar(
        scalar_entries, var_map, param_sym_set;
        has_pgather = !isempty(pgather), obs_defs = obs_defs
    )
    scalar_cache.epoch = forcing_epoch

    # ---- Cross-kernel / kernel↔prelude CSE (perf plan B4; xcse.jl) ----
    # A lane-invariant expensive subtree appearing in several array kernels'
    # invariant tiers (and possibly in scalar equations too) collapses to ONE
    # shared scalar prelude slot; each kernel's inv def becomes a bare cache
    # read. `:inplace` only — a compiled backend emits the prelude itself and
    # never consults the `_CSECache` the kernel-side reads do. Runs BEFORE
    # the percell append (the per-cell reference trees stay exactly the
    # `_compile` output) and BEFORE the cadence split (a hoisted
    # parameter-only def still joins the const tier).
    xcse_diag = if form === :inplace && !_xcse_disabled()
        _share_kernel_invariants!(
            rhs_list, scalar_prelude, scalar_cache,
            acc_kernels
        )
    else
        _XCSE_NONE_DIAG
    end

    # ---- The per-cell reference, with the affine stencil tier off ----
    # Its compiled per-cell nodes join the scalar list —
    # each cell evaluated by the plain scalar walker `_eval_node`, with no merge
    # machinery of any kind between it and the equation: the maximally
    # independent oracle the acc≡per-cell differential tests compare against.
    # Empty on every default build. Appended AFTER the CSE pass so the
    # reference trees are exactly the `_compile` output, untouched by sharing.
    n_scalar_rhs = length(rhs_list)
    isempty(percell_scalar) || append!(rhs_list, percell_scalar)

    # ---- Cadence tiers of the (now final) prelude (4qf + B3, const_tier.jl) ----
    # Runs AFTER the sharing pass, because that pass APPENDS prelude defs — a
    # lane-invariant kernel subtree hoisted into the scalar prelude is a cadence-tier
    # candidate exactly like any other def. A slot is CONST iff its def touches no
    # state / time / live forcing buffer, TIME iff it touches `t` and/or a live
    # forcing buffer but no state, and DYNAMIC otherwise — with every cache ref in a
    # def contributing the tier of the slot it reads (that clause is the trap: an
    # `_NK_CACHED` node carries no leaf of its own, so a leaf scan alone would call a
    # def const while it reads a dynamic slot). `f!` then refills the const slots
    # only when `p` has moved, and the time slots only when `(p, t, forcing epoch)`
    # has — so an FD Jacobian's N+1 same-`t` calls fill the time tier once.
    const_slots, time_slots, dyn_slots =
        _classify_const_slots(scalar_prelude, scalar_cache)

    # ---- The scalar equations and the prelude as generated code (scalar_codegen.jl) ----
    # `:inplace` only: the out-of-place product hands the compiled IR itself to a
    # compiled backend. The per-cell reference entries past `n_scalar_rhs` stay
    # walked. Their report rows move to the `*_codegen` tiers here.
    scalar_section = form === :inplace ?
        _build_scalar_section(
            rhs_list, n_scalar_rhs,
            scalar_prelude, scalar_cache, const_slots, time_slots, dyn_slots,
            acc_kernels; rule_of = s -> var_map isa StateLayout ?
            _slot_key(var_map, s) : "state slot $s"
        ) :
        nothing
    scalar_section === nothing ||
        _retier_scalar_rules!(var_map, rhs_list, scalar_section)

    # ---- Default tspan ----
    tspan_default = _pick_tspan(tspan)

    # ---- The live forcing buffers (see `BuildProducts`) ----
    # Published for BOTH forms, from the same `pgather` the out-of-place product
    # carries as a field, so that `forcing_buffers(prob)` is a question about
    # the PROBLEM rather than about which build form happened to produce it.
    if products !== nothing
        _fb, _fbi = _forcing_buffer_container(pgather)
        products.forcing_buffers = _fb
        products.forcing_buffer_index = _fbi
    end

    # ---- The RHS slot ----
    # Two products of the SAME compiled IR (tree_walk/oop.jl explains why both
    # exist): `:inplace` is the zero-alloc, eltype-generic Float64 evaluator
    # `f!(du, u, p, t)`; `:oop` is the compiled IR itself, for a compiled
    # backend to lower. `:oop` does not evaluate on the host.
    f! = if form === :inplace
        # The factored array-observed fills wrap the state RHS: `f!` copies `u`
        # into the extended value vector, fills every observed buffer in
        # dependency order, and hands the extended vector to the state RHS as its
        # `u`. With nothing materialized the wrapper is not applied at all, so the
        # closure (and its zero-allocation property) is byte-identical.
        # The inner state RHS keeps its own `scan_folds` (the prefix reductions
        # among the STATE equations); each fill level carries its own.
        # The discrete caches are brought up to the call's `p` first (see
        # `_DiscreteRefill`); without a cache the wrapper is not applied.
        rhs0 = _make_rhs_with_obs_buffers(
            _make_rhs(
                rhs_list, scalar_prelude, scalar_cache, acc_kernels,
                const_slots, time_slots, dyn_slots, scan_folds,
                _make_contraction_section(array_contractions);
                scalar = scalar_section, fused_scans = state_fused_scans,
                nst = obs_nst
            ),
            n_total, n_states, Tuple(mat_levels), Tuple(mat_const_levels),
            Tuple(mat_time_levels), forcing_epoch
        )
        discrete_refill === nothing ? rhs0 : _make_rhs_discrete_refill(rhs0, discrete_refill)
    elseif form === :oop
        # `pgather` (raw `param_arrays` buffers + discrete-cadence caches) rides
        # along so the out-of-place build can expose its live forcing buffers as
        # ARGUMENTS (`_OopRHS`) — the binding a compiled backend needs.
        _make_rhs_oop(
            rhs_list, scalar_prelude, acc_kernels, n_states, pgather,
            scan_folds, Tuple(mat_levels_oop), n_total,
            array_contractions
        )
    else
        throw(
            TreeWalkError(
                "E_TREEWALK_UNKNOWN_FORM",
                "the build's `form` must be :inplace or :oop, got :$(form)"
            )
        )
    end

    # Diagnostics for the N-independence property: the number of array kernels
    # (and their CSE tiers) must be invariant across grid sizes; only the
    # embedded slot/value vectors grow with N. `n_cse_slots` /
    # `n_cse_occurrences` witness the scalar CSE evaluate-once property
    # (ess-r7h #2); `n_const_slots` / `n_time_slots` / `n_dynamic_slots` partition
    # the prelude by cadence (4qf + B3) — `n_const_slots` is the number of slots
    # `f!` skips on a call whose `p` has not moved, and `n_time_slots` the number
    # it additionally skips while `(p, t, forcing epoch)` stand still (the FD
    # Jacobian's same-`t` columns).
    #
    # `n_acc_kernels` (and the slot sums below) count the POST-class-merge
    # list — the kernels the emitted RHS actually carries — deliberately: the
    # N-independence property still holds (a class is a structural fact of the
    # document, not of the grid), and the pre-merge count is available as
    # `n_classmerge_in`. A merged class folds varying inv defs into the cell
    # tier (value-identical ones keep a real inv tier), so `n_acc_inv_slots`
    # can shrink relative to a disabled-merge build.
    diag = (;
        # ess-scan: forward cumulative (prefix) reductions rewritten into a
        # term pass + an O(N) accumulation (scan.jl). Zero on every model
        # without one; the per-equation cascade tally records `:scan`.
        # Counts BOTH the state equations' folds and those inside the
        # factored array-observed fills — a prefix reduction that defines a
        # materialized observed is the same rewrite in the same position,
        # just over the observed's buffer block instead of the state.
        n_scan_folds = n_state_scan_folds + mat_scan_fold_count,
        # ess-array-contraction: array einsums compiled to ONE loop nest
        # each (array_contraction.jl). Zero on every model whose reductions
        # stay under the tier's floor; counted here for the same reason
        # `n_scan_folds` is — it is a section of the emitted RHS, invisible
        # to the kernel counts above.
        n_array_contractions = length(array_contractions) +
            mat_array_contraction_count,
        # Causal self-references (recurrence_sweep.jl), each one ordered
        # sweep in the observed fill levels.
        n_recurrence_sweeps = mat_recurrence_count,
        n_acc_kernels = length(acc_kernels),
        n_acc_cse_slots = sum(length(K.cse.recipes) for K in acc_kernels; init = 0),
        n_acc_inv_slots = sum(length(K.cse.inv_recipes) for K in acc_kernels; init = 0),
        # Kernel-CLASS merge (oop_merge.jl, hoisted pre-xcse for both
        # emitters): pre-merge kernel count / merge-ineligible kernels /
        # classes whose group merge declined at build. All three equal
        # their no-op values (n_acc_kernels / 0 / 0) when the pass is
        # disabled or trivially small.
        n_classmerge_in = class_merge_diag === nothing ?
            length(acc_kernels) : class_merge_diag.n_in,
        n_classmerge_blocked = class_merge_diag === nothing ? 0 :
            class_merge_diag.n_blocked,
        n_classmerge_failed = class_merge_diag === nothing ? 0 :
            class_merge_diag.n_failed,
        n_scalar_entries = length(rhs_list),
        n_cse_slots = cse_diag.n_slots,
        n_cse_occurrences = cse_diag.n_occurrences,
        # Named scalar-observed prelude slots (ess-obs-slots): observeds
        # compiled once as named defs vs observed equations left inlined
        # (array-valued + leaf-bodied + structurally/guard-demoted). An
        # aliased slot (an observed whose whole body was already a CSE
        # slot) still counts as a named slot; the PRELUDE length is
        # `n_cse_slots + n_obs_slots` minus aliases.
        n_obs_slots = cse_diag.n_obs_slots,
        n_obs_inlined = obs_plan.n_inlined,
        # Cross-kernel CSE (plan B4; xcse.jl): shared prelude slots
        # minted by the pass / kernel inv defs rewritten to shared-slot
        # reads / scalar RHS sites rewritten onto new shared slots.
        n_xcse_slots = xcse_diag.n_xcse_slots,
        n_xcse_kernel_shared = xcse_diag.n_xcse_kernel_shared,
        n_xcse_scalar_shared = xcse_diag.n_xcse_scalar_shared,
        n_const_slots = length(const_slots),
        n_time_slots = length(time_slots),
        n_dynamic_slots = length(dyn_slots),
        # Factored array observeds (this change): how many array observeds
        # were cut out of their readers into per-call buffers, how many
        # buffer cells that is, and the dependency depth the fills run in.
        n_mat_array_obs = length(mat_vars),
        n_mat_array_cells = n_total - n_states,
        n_mat_levels = length(mat_levels) + length(mat_const_levels) +
            length(mat_time_levels),
        n_mat_const_levels = length(mat_const_levels),
        n_mat_time_levels = length(mat_time_levels),
    )

    if products !== nothing
        products.stats = diag
        products.kernels = acc_kernels
    end
    # The PUBLIC map is the ODE layout only: the factored array-observed buffer
    # slots are build-owned scratch above `length(u0)`, not integrator slots, and
    # every caller (solution indexing, cellwise evaluation, the conformance
    # runners) reads `var_map` as "state name → `u` index".
    return f!, u0, p, tspan_default, layout.var_map
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
        model, get(kwargs, :index_sets, Dict{String, IndexSet}())
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
        # Live forcing buffers bound BY REFERENCE (ess-14f.3, JL-J0).
        # Each value MUST be a dense `Array{Float64}`; its `index(…)`
        # reads compile to live `_NK_PARAM_GATHER` nodes over an
        # aliased flat view, so a discrete-cadence
        # refresh callback's in-place `buffer .= …` is seen by the
        # RHS with zero reallocation. This is the discrete-cadence
        # channel; const-cadence data stays on `const_arrays` (frozen
        # literal inlining). Disjoint from the scalar `p` NamedTuple
        # so existing scalar-param reads stay byte-identical + 0-alloc.
        param_arrays::AbstractDict = Dict{String, Any}(),
        # Per-const-array boundary policy (ess-gj4): name → an
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
    # §5.46): this build used to bind such a parameter from its `default` and
    # integrate it, reporting a whole trajectory under the label of a rate the
    # document says is read from a file. The three registries are every channel a
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
    # ---- Compile-once template tier: expand references at the entry, keeping
    # the SITES (RFC out-of-line-expression-templates §7.7). Every phase and
    # every fallback path below sees exactly the fused expanded tree Option A
    # produced — variable discovery, layout, validation, and the per-cell /
    # symbolic paths are byte-identical to a pre-expanded build. The recorded
    # expansion roots are consumed ONLY by the affine stencil build, which
    # compiles each (use site, region class) body once and calls it as a
    # sub-kernel. Expansion works on a copy (`_expansion_copy`): the caller's
    # typed model must keep its references (`serialize_esm_file` emits them
    # verbatim — R1).
    _template_sites = nothing
    if _template_reg !== nothing
        model = _expansion_copy(model)
        sites = IdDict{OpExpr, OpExpr}()
        _expand_model_refs!(
            model, _template_reg; sites = sites,
            memo = something(_expand_cache, _ExpandCache())
        )
        isempty(sites) || (_template_sites = sites)
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
    # ---- esm-spec §4.3.1 `faq_bare_array_operand`, on the EXPANDED model ----
    # `validate` (and the front door's reference-integrity refusal) cannot see a
    # bare shaped name a template binding delivers into a `faq` filter, the
    # spelling issue #441 was found in; here every reference is expanded.
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
    # is never mutated. `_template_sites` is keyed by node identity, so its
    # entries are re-keyed through the intern map (a merged key is harmless:
    # the only site consumers are `haskey` boundary checks, see the pre-audit
    # audits/intern_preaudit_2026-07-19.md). With interning off the pass is
    # skipped entirely.
    if !_intern_disabled()
        ictx = _InternCtx()
        model = _intern_model(model, ictx)
        if _template_sites !== nothing
            translated = IdDict{OpExpr, OpExpr}()
            for (root, ap) in _template_sites
                nr = get(ictx.memo, root, root)
                translated[nr] = ap
            end
            _template_sites = translated
        end
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
        template_sites = _template_sites,
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

    # ---- The parameter partition (differentiability plan §3 Phase 5) ----
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
        materialize_out = materialize_out, form = form,
        template_sites = _template_sites, caller_u0 = _caller_u0
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
        name::String, form::Symbol, recur_names::Set{String},
        mat_defs::Dict{String, ASTExpr}, layout::_StatePlan, model::Model,
        resolved_obs::Dict{String, ASTExpr}, cs::_CompileScope,
        products::Union{Nothing, BuildProducts}
    )
    name in recur_names || return nothing
    form === :oop && _refuse_rule(
        name,
        "an ordered recurrence sweep (esm-spec §4.3.1.1) has no " *
            "lowering in the out-of-place product this compiler emits; " *
            "its cells cannot be computed as one whole-array program " *
            "(CONFORMANCE_SPEC §5.19.2)"
    )
    sw = _compile_recurrence_sweep(
        name, mat_defs[name],
        layout.mat_dims[name], get(model.variables, name, nothing), resolved_obs, cs
    )
    _record_rule!(name, :observed, _recurrence_tier(sw))
    products === nothing ||
        push!(products.recurrences, _recurrence_info(name, mat_defs[name], sw))
    return sw
end
