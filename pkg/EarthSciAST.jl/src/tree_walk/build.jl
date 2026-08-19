# ========================================================================
# tree_walk/build.jl — part of the tree-walk evaluator (gt-e8yw).
# Included by src/tree_walk.jl; see that file for the full layout and
# include order. Sections 2/2b/2c: BuildInspection, the extracted build-pipeline
# stages, the four build phases + _build_evaluator_impl, the public
# build_evaluator entry points, and evaluate_expr.
# ========================================================================

"""
    BuildInspection()

Observability record for [`build_evaluator`](@ref): pass one via the `inspect`
keyword (`build_evaluator(doc; inspect=BuildInspection())`; [`simulate`](@ref)
forwards its own `inspect` keyword) and the build fills it with named
BUILD-TIME products that are otherwise internal to the evaluator closure:

* `setup_arrays::Dict{String,Array{Float64}}` — the materialized setup-time
  geometry arrays (RFC §8.1 / esm-spec §8.6.1), keyed by (flattened) observed
  name: the per-pair overlap-area matrix `A_ij`, its row-sums `A_j`, the
  normalized weights, and every other build-once geometry-derived array
  observed. This is the official inspection surface for conformance runners
  that gate per-pair regridding values (CONFORMANCE_SPEC §5.8) — the arrays
  are deliberately absent from the ODE partition, so no state/observed
  read can reach them.
* `const_arrays::Dict{String,Any}` — the full const-array registry as
  registered for the build: caller-supplied arrays, `const`-op array
  observeds, keyed-factor aliases, materialized clip rings and setup arrays.
* `observed_exprs::Dict{String,ASTExpr}` — the resolved observed substitution
  map (post index-set-range resolution and observed-into-observed inlining),
  exactly as inlined into the compiled RHS.
* `params::Dict{String,Float64}` — the resolved SCALAR parameter values (the
  model defaults with any `parameter_overrides` applied), keyed by the
  (flattened) parameter name exactly as it appears in a compiled expression
  (`"Flattened.k"`). These are load-time CONSTANTS, so binding them into a
  build-time cellwise evaluation (`evaluate_cellwise`, §6.6.5 observed/
  reference assertions, `ic` seeding) is sound and determinism-safe — unlike
  STATE, which stays out of scope. Array-backed parameters live on
  `const_arrays`, not here (the scalar map stays homogeneous `Float64`).
* `param_classes::Dict{String,Symbol}` — the PARTITION of the declared
  parameters into `:numeric` (a scalar that lands in the runtime `p`),
  `:structural` (read at BUILD time, so its value can decide the shape of the
  problem), `:const_folded` (const data frozen into the build, never in `p`)
  and `:forcing` (a live buffer a discrete provider rewrites, never in `p`).
  Derived from what the build actually read, not from what the document
  declares — see [`parameter_classes`](@ref). This is the build-level face of the same
  partition `parameter_classes(prep)` exposes on a `PreparedModel`.

Filling the record never changes the build: the returned
`(f!, u0, p, tspan, var_map)` is identical with or without `inspect`.
"""
mutable struct BuildInspection
    setup_arrays::Dict{String,Array{Float64}}
    const_arrays::Dict{String,Any}
    observed_exprs::Dict{String,ASTExpr}
    params::Dict{String,Float64}
    # ---- UN-inlined observed definitions, for BUILD-TIME field evaluation ---
    # `observed_exprs` above is the fully SUBSTITUTED view: every observed
    # inlined into its readers. That is self-contained, but it makes a build-time
    # `evaluate_cellwise` of one observed re-execute its ENTIRE producer chain
    # once per OUTPUT CELL. On the ISRM source-receptor model that is
    # 5 pathways x |ppl| x |emission records| terms at EVERY receptor cell — the
    # spatial join re-run 52,411 times (~1.7e13 evaluations at full scale).
    #
    # This is the per-observed definition BEFORE observed-into-observed
    # substitution, so `_observed_field` can materialize each producer ONCE in
    # dependency order and let its readers gather the buffer.
    #
    # NOTE this is deliberately independent of the RHS-side factoring
    # (`_collect_materialized_array_obs`), whose liveness roots are the `D`/`ic`
    # equations. A PURE-ALGEBRAIC model — `system_kind: nonlinear`, no state, every
    # result an observed, which is exactly the ISRM case — has NO such roots, so
    # nothing is RHS-factored and the whole chain stays inlined. The build-time
    # observability path has a different root: the observed a caller asks for.
    observed_defs::Dict{String,ASTExpr}
    # Extents of DATA-DERIVED index sets (RFC §5.5 value invention), keyed by
    # index-set name. An observed shaped on a derived axis — the ISRM emission
    # binning is shaped on `emis_src_cells`, whose size is discovered by value
    # invention — cannot have its extents read from `index_sets` alone, so
    # without these it could not be materialized at all.
    derived_extents::Dict{String,Int}
    # The numeric / structural / const_folded / forcing partition of the
    # declared parameters (differentiability plan §3 Phase 5). Derived from the
    # names the build-time consumers actually READ, so it is a record of this
    # build, not a re-reading of the document.
    param_classes::Dict{String,Symbol}
end
BuildInspection() = BuildInspection(Dict{String,Array{Float64}}(),
                                    Dict{String,Any}(), Dict{String,ASTExpr}(),
                                    Dict{String,Float64}(),
                                    Dict{String,ASTExpr}(),
                                    Dict{String,Int}(),
                                    Dict{String,Symbol}())

"""
    DiscreteMaterializer()

The **discrete-cadence materialization** sink — the middle phase of the
three-phase cadence partition (`const ⊏ discrete ⊏ continuous`, `cadence.jl`).
Pass one via the `materialize_out` keyword of [`build_evaluator`](@ref) to
OPT IN to the cut; without it, discrete-cadence derived fields stay inlined into
the per-step RHS (the pre-cut behavior; every existing build is byte-identical).

A derived ARRAY observed whose value depends (transitively) on a live
`param_arrays` forcing buffer but NOT on any continuous `state` (nor the
independent variable `t`) changes only at the discrete refresh cadence. Inlining
it into the hot RHS recomputes the whole met→physics stack every step — and, for
a deep chain (a regrid feeding the Rothermel fire-physics), collapses into an
enormous per-cell expression the compiler cannot lower in bounded time. The cut
materializes each such field ONCE PER REFRESH into a dense cache buffer that the
hot RHS gathers via the existing zero-alloc `_NK_PARAM_GATHER` path — exactly as
it gathers a raw forcing buffer. The build fills it:

* `caches::Dict{String,Array{Float64}}` — var name → its cache buffer (the SAME
  object aliased into `pgather`, captured by reference; a `materialize!` write
  shows through to the RHS with zero reallocation).
* `materialize!::Function` — a `() -> nothing` closure that recomputes every
  cache from the (already-refreshed) raw forcing buffers + const arrays + upstream
  caches, in dependency order. `build_evaluator` runs it ONCE at build (so u0
  seeding and the first RHS evaluation read valid caches); the caller re-runs it
  after each in-place forcing refresh. [`simulate`](@ref) wires it as the
  refresh callback's `post_refresh` hook automatically.
* `var_order::Vector{String}` — the dependency order the fills run in.
"""
mutable struct DiscreteMaterializer
    caches::Dict{String,Array{Float64}}
    materialize!::Function
    var_order::Vector{String}
end
DiscreteMaterializer() =
    DiscreteMaterializer(Dict{String,Array{Float64}}(), () -> nothing, String[])

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
#     algebraic chain — e.g. the flattened Rothermel fire-physics chain
#     reconstituted by `flattened_to_esm` — resolve through `build_evaluator`
#     with NO caller pre-inlining (`_resolve_observed` collapses the chain to a
#     fixed point). It used to be gated on geometry, which left a non-geometry
#     expression-defined observed unbound. Synthesis only ADDS equations for
#     observeds lacking one, so equation-defined models stay byte-identical.
#  2. ELEMENTWISE ARRAY-OBSERVED FOLD (WS4): fold every array-shaped observed
#     whose lowered defining RHS is elementwise (a level-set's `U_n`, `S_n`, …)
#     into its readers, so a discretization-agnostic PDE leaf can be authored
#     with readable intermediate array fields rather than one inlined `D(ψ,t)`
#     RHS. Producer-defined array observeds (`psi_x`, `grad_mag`) survive for
#     `_array_inline_vars`. Must run BEFORE the whole-array lift so the state
#     equation carries the folded RHS.
#  3. WHOLE-ARRAY DECLARED-SHAPE DERIVATIVE LIFT: a whole-array
#     `D(state) = <array rhs>` over a declared shape is lifted into the
#     per-cell `arrayop` form the derivative partition consumes (see
#     `_lift_wholearray_deriv_equations`). Spatial-operator zeroing over a
#     structurally-0-D field is done EARLIER, at the flatten→document boundary
#     (`flattened_to_esm`), so a raw `grad`/`div`/`laplacian` reaching the
#     compiler directly (a hand-built Model, never discretized) still
#     hard-errors as the pipeline-violation guard requires. No-op for a model
#     without a whole-array D.
# Returns `(equations, folded_array_obs)`.
function _prepare_model_equations(model::Model)
    equations = model.equations
    let synth = Equation[]
        for (name, v) in model.variables
            (v.type == ObservedVariable && v.expression isa ASTExpr) || continue
            any(eq -> eq.lhs isa VarExpr && (eq.lhs::VarExpr).name == name,
                model.equations) && continue
            push!(synth, Equation(VarExpr(name), v.expression))
        end
        isempty(synth) || (equations = vcat(model.equations, synth))
    end
    equations, folded_array_obs = _fold_elementwise_array_observeds(equations, model)
    let var_shapes = Dict{String,Vector{String}}()
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
#  * `ring_vars` — (array-shaped) observeds whose defining expression is a
#    direct intersect_polygon clip; materialized into const_arrays at setup
#    (RFC §8.1) rather than treated as scalar observeds.
#  * `setup_vars` / `defs` — geometry-derived ARRAY observeds (ranged clips,
#    per-pair areas, A_ij), materialized at setup and excluded from the ODE
#    partition / observed substitution — build-once functions of the const
#    polygon inputs.
#  * `inline_vars` — live-field geometry observeds (ess-14f.4): array observeds
#    that are NOT build-once setup vars because they read a live `param_arrays`
#    buffer (the conservative-regrid output F_tgt = A_ij ⊗ F_src / A_j is the
#    motivating case). They are INLINED into the array-state RHS that consumes
#    them, so the build-time `index(arrayop,…)` reducer collapses
#    `index(F_tgt, j)` to F_tgt's body — yielding the proven array-state
#    aggregate kernel (const A_ij/A_j + live F_src), the met→fire coupling
#    edge. Empty (byte-identical) for files whose geometry outputs are all
#    const-fed (they stay setup vars).
# The FUSED `polygon_intersection_area` leaf (§8.6.1) triggers the SAME
# setup-geometry machinery as `intersect_polygon`: an array observed whose
# aggregate body is the fused leaf (`A_ij[i,j] = polygon_intersection_area(
# src[i], tgt[j])`) is a build-once setup const over the in-file polygon rings.
# `has_setup_geometry` gates the setup-vars discovery / materialization so the
# ranged narrow phase compiles even when NO `intersect_polygon` node survives.
function _discover_geometry_vars(model::Model, equations::Vector{Equation},
                                 param_arrays::AbstractDict, vi_vars)
    has_geometry = _model_has_intersect_polygon(model)
    has_pia = _model_has_polygon_intersection_area(model, equations)
    has_setup_geometry = has_geometry || has_pia
    ring_vars = Set{String}()
    if has_geometry
        for eq in equations
            if eq.lhs isa VarExpr && eq.rhs isa OpExpr &&
               (eq.rhs::OpExpr).op == "intersect_polygon"
                push!(ring_vars, (eq.lhs::VarExpr).name)
            end
        end
    end
    setup_vars = Set{String}()
    defs = Dict{String,ASTExpr}()
    inline_vars = Set{String}()
    if has_setup_geometry
        pre_state_names = Set{String}(n for (n, v) in model.variables
                                      if v.type == StateVariable && !(n in vi_vars))
        live_param_names = Set{String}(String(k) for k in keys(param_arrays))
        setup_vars, defs, live_tainted =
            _geometry_setup_vars(model, equations, ring_vars,
                                 pre_state_names, live_param_names)
        # GEOMETRY-DERIVED restriction. `live_tainted` is a DOCUMENT-WIDE set:
        # every var transitively reading a live `param_arrays` buffer. The
        # inlining below is meant for the geometry LIVE-FIELD outputs only — the
        # `F_tgt = A_ij ⊗ F_src / A_j` shape that mixes setup-const weights with a
        # live source field and so cannot be materialized at setup. Live taint
        # ALONE does not identify those: in a flattened multi-model document
        # nearly every array observed is live-tainted, because `flatten` merges
        # all models and the met forcing reaches all of them.
        #
        # Without this restriction ONE `polygon_intersection_area` — in ONE model
        # — inlined every live array observed of every UNRELATED model into its
        # readers. Adding an NEI regrid to reseact.esm swept in ~500 observeds
        # across DryDepositionGas / FastJX / WetDeposition / Transport3D,
        # including the whole RHS of the air-mass continuity equation
        # (`divh_fix`, `Mz`, `dPSdt`, `dp`). That routed host equations into the
        # array-equation compiler for the first time (the pre-geometry cascade
        # tally is EMPTY), where `D(m)` declined to the per-cell tier and emitted
        # O(#cells) IR — a >32 GiB build at NLEV=72 whose cost scaled with the
        # grid. Geometry in one model must not change how another model's
        # equations compile.
        #
        # Derived = reads a geometry setup var / clip ring, transitively. The
        # regrid's own outputs still qualify (they read `A_ij`), so the motivating
        # met→fire coupling edge is unchanged.
        geom_derived = Set{String}()
        _saturate!() do
            changed = false
            for (name, rhs) in defs
                name in geom_derived && continue
                refs = _referenced_var_names(rhs)
                if any(r -> r in setup_vars || r in ring_vars || r in geom_derived, refs)
                    push!(geom_derived, name); changed = true
                end
            end
            changed
        end
        for (name, v) in model.variables
            (v.type == ObservedVariable && _is_array_shape(v.shape) &&
             !(name in setup_vars) && !(name in ring_vars) &&
             name in live_tainted && name in geom_derived && haskey(defs, name) &&
             defs[name] isa OpExpr) || continue
            push!(inline_vars, name)
        end
        get(ENV, "ESS_STENCIL_DEBUG", "") == "1" &&
            (println(stderr, "[geom-inline] has_geometry=", has_geometry,
                     " has_pia=", has_pia, " inlined=", length(inline_vars),
                     " (live-tainted ∩ geometry-derived): ",
                     sort(collect(inline_vars))); flush(stderr))
    end
    return (; has_geometry, has_pia, has_setup_geometry,
            ring_vars, setup_vars, defs, inline_vars)
end

# ---- Stage: promoted array observeds (shape-promotion inlining) ----
# An array-shaped observed defined by an `arrayop` is inlined into its readers
# via the same index beta-reduction as a live-field geometry observed
# (`index(obs, i…)` collapses to the arrayop body) — it carries no ODE
# partition slot. This generalizes the geometry `inline_vars` to the
# non-geometry case, so a `promote_downstream_shapes`-lifted physics chain
# (scalar authored, array after promotion) runs with no per-cell runner logic.
# Excludes anything the geometry path already owns. Empty (byte-identical) for
# a system with no array observeds.
#
# The on-disk `aggregate` spelling (schema v0.8.0) and `makearray` qualify the
# same way when they PRODUCE an array (non-empty `output_idx` / regions): a
# general array-shaped observed authored as an aggregate map — an edge-indexed
# flux field, a ragged-contraction rule output like the MPAS `div(flux)`
# lowering — is exactly the promoted-arrayop case, just spelled with the
# public op name. A SCALAR reduction (empty `output_idx`) is not an array
# producer and keeps the scalar-observed path.
function _collect_array_inline_vars(model::Model, equations::Vector{Equation},
                                    geom_setup_vars, geom_ring_vars,
                                    geom_inline_vars)
    array_inline_vars = Set{String}()
    for eq in equations
        eq.lhs isa VarExpr || continue
        name = (eq.lhs::VarExpr).name
        (name in geom_setup_vars || name in geom_ring_vars ||
         name in geom_inline_vars) && continue
        haskey(model.variables, name) || continue
        v = model.variables[name]
        (v.type == ObservedVariable && _is_array_shape(v.shape)) || continue
        (eq.rhs isa OpExpr && ((eq.rhs::OpExpr).op == "arrayop" ||
                               _is_array_producer(eq.rhs))) || continue
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
#   * geometry `inline_vars` / clip rings / setup vars / `polygon_intersection_area`
#     operand arrays / `const`-op + bare-alias array observeds — none of them is
#     in `array_inline_vars` to begin with;
#   * the discrete-cadence and const-cadence cadence cuts (they are removed from
#     `array_inline_vars` BEFORE this selection runs, so a per-refresh cache is
#     never also a per-call buffer), plus anything a discrete-cadence fill reads
#     (its fill kernel runs outside the RHS, where the buffer is not filled);
#   * an observed whose declared shape does not resolve to concrete extents, or
#     whose defining aggregate's own output ranges are not the dense `1…n` the
#     buffer layout addresses;
#   * every array observed at all with `ESS_ARRAY_OBS_INLINE=1`, which restores
#     the pre-change build exactly. (The `:oop` emitter used to be excluded here
#     too; it now materializes on the same terms as `:inplace` — see the
#     `mat_array_vars` note in `_build_lower_and_classify`.)
#
# GHOST CELLS. A materialized observed is a first-class array field of its
# declared shape, so a gather OUTSIDE that shape reads the ghost literal 0.0 —
# identical to the rule for an array STATE, and to a `makearray`-defined
# observed's own "no region covers ⇒ 0" default. (An aggregate-defined observed
# that a reader gathers out of range used to beta-reduce its body at the
# out-of-range index instead; the discretizations' region-split boundary
# stencils keep their gathers in range, which the conformance goldens pin.)
_array_obs_inline_forced() = get(ENV, "ESS_ARRAY_OBS_INLINE", "") == "1"

# Candidate set: the promoted array observeds (post cadence cut) that are not
# read by a discrete-cadence fill. `discrete_defs_refs` is the set of names
# reachable from the discrete fills through the observed definitions.
function _collect_materialized_array_obs(model::Model, equations::Vector{Equation},
                                         array_inline_vars, discrete_vars)
    (_array_obs_inline_forced() || isempty(array_inline_vars)) && return Set{String}()
    defs = Dict{String,ASTExpr}()
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
    for name in array_inline_vars
        (name in blocked || !(name in live)) && continue
        v = get(model.variables, name, nothing)
        (v !== nothing && v.type == ObservedVariable && _is_array_shape(v.shape)) || continue
        push!(out, name)
    end
    # STRUCTURAL positions (mirrors the scalar slot plan's `_obs_structural_refs!`):
    # a buffer read is a RUNTIME value, so an observed referenced where the build
    # needs a CONCRETE value — a gather SUBSCRIPT, an aggregate range bound, an
    # integral bound, a value-invention key, a table-lookup axis — must stay
    # inlined. The gather TARGET itself is exempt: `index(obs, i…)` naming a
    # materialized observed is exactly the buffer read.
    if !isempty(out)
        hits = Set{String}()
        seen = _ObsSeen()
        for eq in equations
            _array_obs_structural_refs!(eq.lhs, out, hits, seen)
            _array_obs_structural_refs!(eq.rhs, out, hits, seen)
        end
        for (_, v) in model.variables
            v.expression isa ASTExpr &&
                _array_obs_structural_refs!(v.expression, out, hits, seen)
        end
        setdiff!(out, hits)
        get(ENV, "ESS_ARRAY_OBS_DEBUG", "") == "1" && !isempty(hits) &&
            (println(stderr, "[array-obs] structural, kept inline: ",
                     join(sort(collect(hits)), ", ")); flush(stderr))
    end
    get(ENV, "ESS_ARRAY_OBS_DEBUG", "") == "1" &&
        (println(stderr, "[array-obs] materialize candidates: ",
                 join(sort(collect(out)), ", ")); flush(stderr))
    return out
end

# STRUCTURAL-POSITION scan for ARRAY observeds — `_obs_structural_refs!`
# (helpers.jl) with one exemption: that walker flags EVERYTHING under an
# `index` gather, including the gather's own target, because a scalar
# observed's value must be build-time-known there. For an ARRAY observed the
# target IS the array being read, so a bare-name target that names a candidate
# is skipped while every SUBSCRIPT (and a computed target) still flags.
# Shares the (node, mode) visited-set discipline of `_obs_structural_refs!`.
function _array_obs_structural_refs!(e::ASTExpr, names::Set{String}, hits::Set{String},
                                     seen)
    e isa OpExpr || return nothing
    bits = get(seen, e, 0x00)
    bits == 0x00 || return nothing   # spine-visited, or mark-all (its superset)
    seen[e] = _OBS_SEEN_SPINE
    if e.op == "index"
        # Only the SUBSCRIPTS are build-time-resolved (`_eval_const_int`, which
        # knows loop indices and const arrays). The gather TARGET is either the
        # array being read — a materialized observed's buffer, resolved by name —
        # or an inline array PRODUCER whose region/aggregate body is an ordinary
        # EXPRESSION position (`_resolve_index_of_{makearray,arrayop}` resolves
        # the selected value through `_resolve_indices`), so recurse into it
        # rather than flagging its whole subtree.
        for k in 2:length(e.args)
            _obs_mark_refs!(e.args[k], names, hits, seen)
        end
        isempty(e.args) ||
            _array_obs_structural_refs!(e.args[1], names, hits, seen)
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
    if e.table_axes !== nothing
        for (_, ax) in e.table_axes
            _obs_mark_refs!(ax, names, hits, seen)
        end
    end
    for a in e.args
        _array_obs_structural_refs!(a, names, hits, seen)
    end
    e.expr_body === nothing ||
        _array_obs_structural_refs!(e.expr_body::ASTExpr, names, hits, seen)
    e.filter === nothing ||
        _array_obs_structural_refs!(e.filter::ASTExpr, names, hits, seen)
    if e.values !== nothing
        for v in e.values
            _array_obs_structural_refs!(v, names, hits, seen)
        end
    end
    return nothing
end

# The dense per-dimension extents of a materialized array observed's buffer.
#
# The DECLARED SHAPE is the authority whenever it resolves: it is what a reader's
# `index(obs, i…)` addresses, and therefore what the buffer's cell keys must
# match. An `aggregate`/`arrayop` producer ALSO carries its own (already
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
function _materialized_obs_dims(def::ASTExpr, shape, index_sets::AbstractDict,
                                derived_extents::AbstractDict)
    declared = _declared_shape_extents(shape, index_sets, derived_extents)
    produced = nothing
    if def isa OpExpr && _is_aggregate_op((def::OpExpr).op)
        dop = def::OpExpr
        idx_names = _output_idx_strings(dop)
        if !isempty(idx_names)
            length(unique(idx_names)) == length(idx_names) || return nothing
            ranges = _ranges_dict(dop)
            dims = Int[]
            for n in idx_names
                haskey(ranges, n) || return nothing
                r = try
                    collect(_expand_int_range(ranges[n]))
                catch
                    return nothing
                end
                (!isempty(r) && r == collect(1:length(r))) || return nothing
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

# ---- Stage: polygon_intersection_area fused-leaf operands (esm-spec §8.6.1) ----
# `polygon_intersection_area(a, b)` is a SCALAR overlap-area leaf (the fused
# clip+shoelace). Its polygon operands are build-time-known const vertex rings;
# resolve each into a matrix (a `const_arrays` kwarg entry wins, else the
# operand's own `const`-op observed value) so the leaf const-folds in
# `_resolve_indices`. Each operand array observed is materialized into
# the const-array registry and excluded from the ODE partition — it carries no state,
# exactly like an intersect_polygon clip ring (RFC §8.1). Empty (byte-identical)
# for every file without a polygon_intersection_area node. (`has_pia` is
# computed in `_discover_geometry_vars`, where it also arms the setup-geometry
# machinery for the RANGED narrow phase — an indexed-operand fused leaf inside
# an array aggregate.) Returns `(operand_vars, operand_arrays)`.
function _collect_pia_operand_arrays(model::Model, equations::Vector{Equation},
                                     const_arrays::AbstractDict, has_pia::Bool)
    pia_operand_vars = Set{String}()
    pia_operand_arrays = Dict{String,Matrix{Float64}}()
    if has_pia
        pia_names = Set{String}()
        for eq in equations
            _collect_pia_operands!(eq.lhs, pia_names)
            _collect_pia_operands!(eq.rhs, pia_names)
        end
        for (_, v) in model.variables
            v.expression isa ASTExpr && _collect_pia_operands!(v.expression, pia_names)
        end
        for name in pia_names
            var = get(model.variables, name, nothing)
            mat = if haskey(const_arrays, name)
                Matrix{Float64}(const_arrays[name])
            elseif var !== nothing && var.expression isa OpExpr &&
                   (var.expression::OpExpr).op == "const"
                _pia_const_matrix((var.expression::OpExpr).value)
            else
                throw(TreeWalkError("E_TREEWALK_GEOMETRY_OPERAND",
                    "polygon_intersection_area operand '$(name)' must be a const polygon " *
                    "ring (supplied via `const_arrays` or a `const`-op observed)"))
            end
            pia_operand_arrays[name] = mat
            (var !== nothing && _is_array_shape(var.shape)) &&
                push!(pia_operand_vars, name)
        end
    end
    return pia_operand_vars, pia_operand_arrays
end

# ---- Stage: const-op array observeds (in-file polygon rings / source fields) ----
# A `const`-op observed with an ARRAY shape (`src_poly[cell,vert,coord]`, a
# `F_src[cell]` field, an MPAS mesh subsystem's connectivity/geometry factors)
# is build-time literal data, not a scalar observed and not a state.
# Materialize each into the const-array registry (so a fused-leaf aggregate
# gathers `index(src_poly,i)` at setup and an ODE reads `index(F_src,i)`) and
# exclude it from the ODE partition — exactly like an intersect_polygon clip
# ring (RFC §8.1) or a fused-leaf operand. Operands already owned by the
# scalar-leaf `_pia` path or a setup ring are left to those. This used to be
# gated on the setup-geometry machinery, which left the const mesh data of a
# geometry-free unstructured document (the MPAS keyed-factor wiring, esm-spec
# §4.6) rejected as E_TREEWALK_UNSUPPORTED_SHAPE; the materialization only ADDS
# const arrays for variables that previously hard-errored, so geometry files
# and files without const-op array observeds stay byte-identical.
#
# When `register_coord_buffers` (setup geometry or value invention present):
# a build-time BINNING-COORDINATE observed (an inline reduce aggregate over
# geometry, e.g. `src_lon[i] = min_v src_poly[i,v,1]`) is derived once by the
# AbstractDict front-door and supplied to the typed build as a `const_arrays`
# entry (RFC §8.6.1 purity). Like a `const`-op ring stack it is build-time
# literal data feeding the broad-phase skolem, so materialize it into the const
# arrays and drop it from the ODE partition — not a scalar observed / state.
# Returns `(const_obs_vars, const_obs_arrays)`.
function _collect_const_obs_arrays(model::Model, const_arrays::AbstractDict,
                                   pia_operand_vars, geom_ring_vars,
                                   register_coord_buffers::Bool)
    const_obs_vars = Set{String}()
    const_obs_arrays = Dict{String,Array{Float64}}()
    for (name, v) in model.variables
        (v.type == ObservedVariable && _is_array_shape(v.shape) &&
         _is_const_op(v.expression) && !(name in pia_operand_vars) &&
         !(name in geom_ring_vars)) || continue
        const_obs_arrays[name] = _const_op_to_array((v.expression::OpExpr).value)
        push!(const_obs_vars, name)
    end
    if register_coord_buffers
        for (name, v) in model.variables
            (v.type == ObservedVariable && _is_array_shape(v.shape) &&
             haskey(const_arrays, name) && !(name in const_obs_vars) &&
             !(name in pia_operand_vars) && !(name in geom_ring_vars) &&
             !_is_const_op(v.expression)) || continue
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
# alias as a const array too (same values), excluded from the ODE partition.
# Only chains ending at a `const`-op observed / caller `const_arrays` entry
# resolve; any other alias keeps the existing unsupported-shape error. Empty
# (byte-identical) for documents without bare-alias array observeds. Mutates
# `const_obs_arrays` / `const_obs_vars` in place. The ownership-exclusion sets
# are keyword-only: they are all same-typed `Set{String}`s, so positional
# passing could silently swap two of them.
function _register_bare_alias_arrays!(const_obs_arrays::Dict{String,Array{Float64}},
                                      const_obs_vars::Set{String},
                                      model::Model, equations::Vector{Equation};
                                      const_arrays::AbstractDict,
                                      pia_operand_vars, geom_ring_vars,
                                      geom_setup_vars, geom_inline_vars,
                                      array_inline_vars)
    alias_defs = Dict{String,ASTExpr}()
    for eq in equations
        eq.lhs isa VarExpr && (alias_defs[(eq.lhs::VarExpr).name] = eq.rhs)
    end
    for (name, v) in model.variables
        (v.type == ObservedVariable && _is_array_shape(v.shape)) || continue
        (name in const_obs_vars || name in pia_operand_vars ||
         name in geom_ring_vars || name in geom_setup_vars ||
         name in geom_inline_vars || name in array_inline_vars) && continue
        get(alias_defs, name, nothing) isa VarExpr || continue
        cur = name
        arr = nothing
        for _ in 1:(length(alias_defs) + 1)   # cap defends against a cycle
            rhs = get(alias_defs, cur, nothing)
            rhs isa VarExpr || break
            tgt = (rhs::VarExpr).name
            if haskey(const_obs_arrays, tgt)
                arr = const_obs_arrays[tgt]
            elseif haskey(const_arrays, tgt)
                arr = Array{Float64}(const_arrays[tgt])
            elseif haskey(model.variables, tgt) &&
                   model.variables[tgt].type == ObservedVariable &&
                   _is_const_op(model.variables[tgt].expression)
                arr = _const_op_to_array((model.variables[tgt].expression::OpExpr).value)
            end
            arr === nothing || break
            cur = tgt
        end
        arr === nothing && continue
        const_obs_arrays[name] = arr
        push!(const_obs_vars, name)
    end
    return nothing
end

# ---- Stage: variable partition ----
# Split `model.variables` into the ODE partition: scalar parameter names
# (sorted), scalar observed names, and state-variable names. Variables owned by
# a setup/inline/fold mechanism (value invention, geometry setup, live-field or
# promoted inlining, WS4 folds, fused-leaf operands, const-op arrays) carry no
# partition slot. Array-shaped parameters must be array-backed (const data or a
# live `param_arrays` buffer — the scalar `p` NamedTuple stays homogeneous
# Float64, see the JL-J0 note); array-shaped observeds are supported only as
# intersect_polygon clip rings. The ownership-exclusion sets are keyword-only:
# they are all same-typed `Set{String}`s, so positional passing could silently
# swap two of them. Returns `(param_names, observed_names, state_var_names)`.
function _partition_variables(model::Model;
                              vi_vars, geom_setup_vars,
                              geom_inline_vars, array_inline_vars,
                              folded_array_obs, pia_operand_vars,
                              const_obs_vars, geom_ring_vars,
                              const_arrays::AbstractDict,
                              param_arrays::AbstractDict,
                              discrete_vars=Set{String}())
    param_names = String[]
    observed_names = String[]
    state_var_names = Set{String}()
    for (name, v) in model.variables
        # Value-invention outputs (skolem/distinct/rank) are materialized once at
        # setup (RFC §6.1) and never enter the ODE — drop them from every
        # partition, exactly as a geometry clip-ring observed is not a scalar.
        name in vi_vars && continue
        # Geometry-setup vars are materialized at setup; not an ODE partition member.
        name in geom_setup_vars && continue
        # Live-field geometry observeds (F_tgt …) and promoted array observeds are
        # inlined into their readers (ess-14f.4 / shape-promotion); no partition slot.
        name in geom_inline_vars && continue
        name in array_inline_vars && continue
        # Discrete-cadence materialized array observeds: cut out of the per-step RHS
        # into a cache buffer (filled per refresh) and gathered via `pgather`; like
        # an inline var, they carry no ODE partition slot.
        name in discrete_vars && continue
        # Elementwise array observeds folded into their readers (WS4): their
        # defining equation is gone and their value lives inline in the state RHS.
        name in folded_array_obs && continue
        # polygon_intersection_area operand rings (const polygon vertex rings) are
        # materialized into const_arrays and read by the fused leaf; not a partition
        # member (they carry no state — like an intersect_polygon clip ring).
        name in pia_operand_vars && continue
        # const-op array observeds (in-file ring stacks / source fields) are
        # materialized into const_arrays; build-time data, not a partition member.
        name in const_obs_vars && continue
        if v.type == StateVariable
            push!(state_var_names, name)
        elseif v.type == ParameterVariable || v.type == DiscreteVariable
            # A DISCRETE variable lowers exactly like a parameter here: it is a
            # solver-side buffer the refresh machinery writes at each cadence
            # boundary, never a differentiated slot. Array-shaped ⇒ it must be
            # backed by a live forcing buffer (`param_arrays`) or const data;
            # scalar ⇒ an ordinary scalar parameter slot. The taint seed for the
            # discrete-materialize cut is `keys(param_arrays)` (the buffers
            # actually supplied), so declaring the forcing changes no cadence
            # semantics — it only stops the name from looking like a typo.
            if _is_array_shape(v.shape)
                # An array-shaped parameter is supported only when supplied as
                # const data (e.g. the polygon operands of an intersect_polygon
                # clip, RFC Appendix B.1; or the connectivity / coordinate factors
                # a value-invention key is computed from, §5.2) OR as a live
                # forcing buffer via `param_arrays` (a discrete-cadence loader
                # buffer, ess-14f.3). Either way it is array-backed, not a scalar
                # parameter, so it is NOT added to param_names.
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
                (name in geom_ring_vars) ||
                    throw(TreeWalkError("E_TREEWALK_UNSUPPORTED_SHAPE", name))
            else
                push!(observed_names, name)
            end
        elseif v.type == BrownianVariable
            throw(TreeWalkError("E_TREEWALK_UNSUPPORTED_BROWNIAN", name))
        end
    end
    sort!(param_names)
    return param_names, observed_names, state_var_names
end

# ---- Stage: canonicalize the caller's `parameter_overrides` keys ----
# esm-spec §6.6 pins `parameter_overrides` as "keyed by LOCAL parameter name"
# (`pert_amp`), but every document front-door reaches the build through
# `flatten`, which renames each parameter after its owning component
# (`SimpleClimate.pert_amp`). An exact-key lookup therefore MISSES the very
# spelling the spec tells authors to write, and — because the resolved scope
# feeds the coordinate-expression `ic` seed, the parameter NamedTuple, and
# `inspect.params` (the §6.6.5 reference / observed assertion scope) — the
# override was silently dropped: the run used the DEFAULT and the inline test
# still reported a verdict. A quiet wrong answer in the test runner, not a
# loud failure.
#
# So rewrite each caller key onto the name the build actually resolves, once,
# before any consumer sees it:
#   1. an exact parameter-name hit wins;
#   2. else a DOTTED key whose trailing segment is itself a parameter name
#      resolves to that parameter (`M.A` against a bare-named `Model`);
#   3. else a BARE key that is the trailing segment of exactly ONE parameter
#      resolves to it (`A` against the flattened `M.A`);
#   4. a BARE key that is the trailing segment of MORE THAN ONE parameter is
#      AMBIGUOUS — the caller named one local parameter that two mounted
#      components both carry — and is rejected naming the candidates, never
#      guessed at;
#   5. anything else matches no parameter and is rejected as UNKNOWN.
# This is the Julia counterpart of Python's `_resolve_override` and Rust's
# `Compiled::normalize_override_keys`, so one authored test behaves identically
# in all three executing bindings — see esm-spec §6.6.2 "Unrecognized override
# keys" and CONFORMANCE_SPEC §5.15.
#
# Rules 4 and 5 used to leave the key verbatim, so an unmatched override was
# INERT: the run silently used the declared default and still reported a
# verdict. That is the same silent-wrong-answer shape this canonicalization was
# introduced to fix, one level up — the author writes an override, nothing
# happens, and the model quietly measures the configuration they thought they
# had switched off. Rust already raised `InvalidParameter` here; Julia and
# Python now match it.
function _normalize_param_override_keys(model::Model, overrides::AbstractDict)
    isempty(overrides) && return overrides
    param_names = Set{String}(n for (n, v) in model.variables
                              if v.type == ParameterVariable)
    normalized, unknown, ambiguous =
        _canonicalize_override_keys(param_names, overrides)
    if !isempty(ambiguous)
        k, cands = first(sort!(collect(ambiguous), by = first))
        throw(ArgumentError(
            "parameter_overrides: ambiguous parameter name '$(k)' — it is the " *
            "local name of $(length(cands)) parameters ($(join(sort(cands), ", "))). " *
            "Qualify it with its owning component (esm-spec §6.6.2)."))
    end
    if !isempty(unknown)
        throw(ArgumentError(
            "parameter_overrides: unknown parameter '$(first(sort(unknown)))' — " *
            "this model declares no such parameter " *
            "(known: $(isempty(param_names) ? "none" : join(sort(collect(param_names)), ", "))). " *
            "esm-spec §6.6.2 keys parameter_overrides by LOCAL parameter name."))
    end
    return normalized
end

# ---- Shared caller-key canonicalization (esm-spec §6.6.2) ----
# Rewrite each caller key onto the build-resolved name it designates, and
# classify the ones that designate none. `names` is the set of names the build
# actually resolves (flattening-qualified parameters, or state elements).
# Returns `(normalized, unknown, ambiguous)` where `ambiguous` maps a bare key
# to the candidates that carry it, so the caller can raise the two cases apart.
#
# The value type `V` is a parameter so the SOLVE-time override path
# (`remake_parameters`, simulate.jl) can reuse the identical key resolution
# while keeping each value's own type — a `Dual` passed as a numeric parameter
# override must stay a `Dual`, or differentiating through `remake(prob; p = …)`
# would be defeated by the resolver.
_canonicalize_override_keys(names::AbstractSet{String}, overrides::AbstractDict) =
    _canonicalize_override_keys(Float64, names, overrides)

@inline _override_value(::Type{Any}, v) = v
@inline _override_value(::Type{V}, v) where {V} = V(v)

function _canonicalize_override_keys(::Type{V}, names::AbstractSet{String},
                                     overrides::AbstractDict) where {V}
    # Bare trailing segment → the unique name carrying it. A bare segment
    # carried by two or more names is AMBIGUOUS: recorded here with its
    # candidates rather than resolved, so it is never bound to one of them.
    bare_group = Dict{String,Vector{String}}()
    for n in names
        b = _bare_param_name(n)
        b == n && continue
        push!(get!(bare_group, b, String[]), n)
    end
    normalized = Dict{String,V}()
    unknown = String[]
    ambiguous = Dict{String,Vector{String}}()
    # Two passes so precedence is DETERMINISTIC when a caller supplies both
    # spellings of one name (`A` and `M.A`): the alias-resolved keys land first,
    # the exact-name keys overwrite them. Same order as Python's
    # `_resolve_override` (exact key checked before the bare segment).
    for (rawk, v) in overrides
        k = String(rawk)
        k in names && continue
        bare = _bare_param_name(k)
        if bare in names                      # rule 2: dotted key, bare target
            normalized[bare] = _override_value(V, v)
        elseif haskey(bare_group, k)
            cands = bare_group[k]
            if length(cands) == 1             # rule 3: unique bare alias
                normalized[cands[1]] = _override_value(V, v)
            else                              # rule 4: ambiguous local name
                ambiguous[k] = cands
            end
        else                                  # rule 5: matches nothing
            push!(unknown, k)
        end
    end
    for (rawk, v) in overrides
        k = String(rawk)
        k in names && (normalized[k] = _override_value(V, v))   # rule 1: exact hit
    end
    return normalized, unknown, ambiguous
end

_bare_param_name(name::AbstractString) =
    (i = findlast('.', name)) === nothing ? String(name) : String(name[nextind(name, i):end])

# ---- Stage: scalar parameter scope (load-time constants) ----
# Each scalar parameter's RESOLVED value: `parameter_overrides` if given,
# else the model default (else 0.0). These are load-time CONSTANTS, so they
# are bindable into the build-time cellwise evaluation (coordinate-expression
# `ic` seeding, and — via `inspect.params` — the §6.6.5 observed/reference
# assertions), while STATE stays out of scope. Computed before the ic fold so
# the same map feeds both the seed path and the parameter NamedTuple.
function _resolve_param_scope(model::Model, param_names::Vector{String},
                              parameter_overrides::AbstractDict)
    param_scope = Dict{String,Float64}()
    for name in param_names
        param_scope[name] = haskey(parameter_overrides, name) ?
            Float64(parameter_overrides[name]) :
            (model.variables[name].default === nothing ? 0.0 :
             Float64(model.variables[name].default))
    end
    return param_scope
end

# ---- Build-time parameter READS: the structural/numeric discriminator -------
#
# A parameter is STRUCTURAL iff its value is consumed at BUILD time — where it
# can decide the SHAPE of the problem (a value-invention index-set extent, i.e.
# `length(u)`; a setup-geometry array's dimensions; a binning quantization; the
# u0 an `ic()` fold produces). The declared `"type": "parameter"` says nothing
# about this: every parameter is declared the same way. WHERE THE VALUE IS
# CONSUMED is the discriminator, so this records consumption rather than
# analysing the document a second time — if a name is read at build, it is
# structural, by construction.
#
# The recording is a dynamically scoped sink installed around each build-time
# consumer (`_fold_ic_equations`, `_fold_field_ics!`, `_materialize_geometry_setup`,
# `_derive_binning_coords`, `materialize_value_invention`) and read by the three
# places a NAME is actually resolved to a build-time VALUE:
#
#   * `_compile(::VarExpr, …)` (compile.jl) — the general build-time cell
#     pipeline. Both name arms record: `evaluate_expr` binds the parameter scope
#     as pseudo-STATE (`var_map`), while `_eval_cellwise` /
#     `_try_field_ic_fastpath` bind it as `param_syms`.
#   * `_geo_compile(::VarExpr, …)` (geometry_compile.jl) — the setup-time
#     geometry compiler, which folds a scalar `env` entry to a literal.
#   * `_vi_param` (value_invention.jl) — the relational engine's own evaluator.
#
# Recording at the RESOLUTION site (not at the dict) is what makes it precise:
# every one of those consumers materializes the WHOLE parameter scope into a
# NamedTuple/vector before compiling, so a read-recording Dict would report
# every parameter as structural. Only the compiler knows which names the
# expression actually mentions.
#
# The sink is `nothing` outside those scopes — in particular during the ODE RHS
# compile, where a parameter read is a RUNTIME read of `p` and therefore
# NUMERIC, the exact opposite conclusion.
const _PARAM_READS = Ref{Union{Nothing,Set{String}}}(nothing)

@inline function _record_param_read(name)
    s = _PARAM_READS[]
    s === nothing || push!(s, String(name))
    return nothing
end

# Run `f` with build-time name resolutions recorded into `sink`. Save/restore
# (not clear-on-exit) so a nested build cannot clobber an outer one's sink,
# mirroring `_LANE_INTERN_POOL`.
function _with_param_reads(f, sink::Union{Nothing,Set{String}})
    sink === nothing && return f()
    prev = _PARAM_READS[]
    _PARAM_READS[] = sink
    try
        return f()
    finally
        _PARAM_READS[] = prev
    end
end

# ---- Stage: the parameter partition (esm differentiability plan §3 Phase 5) ----
# Every DECLARED parameter (and the discrete variables that lower like one) gets
# exactly one class:
#
#   `:numeric`      — a scalar that lands in the runtime `p`. Differentiable,
#                     and overridable at solve time by swapping `p`.
#   `:structural`   — read at BUILD time (see `_PARAM_READS`). Its value can
#                     change the shape of the problem, so changing it is a
#                     rebuild, not a `p` swap. Per NAME, not per use: a name
#                     read once at build is structural even if the RHS also
#                     reads it at runtime.
#   `:const_folded` — supplied as CONST DATA (a const provider / caller
#                     `const_arrays` entry), frozen into the
#                     build and inlined into the RHS. It never reaches `p`, so a
#                     derivative w.r.t. it is an unconditional zero that a
#                     finite-difference check on the declared default CONFIRMS —
#                     a wrong gradient and a wrong check agreeing silently. Named
#                     and refused explicitly for exactly that reason.
#   `:forcing`      — the live-buffer sibling of `:const_folded`: an array
#                     parameter bound to a `param_arrays` buffer a discrete
#                     provider rewrites in place at each refresh. Also never in
#                     `p`; changing it means changing the buffer, not `p`.
function _classify_parameters(model::Model, param_names::Vector{String},
                              reads::Set{String}, const_arrays::AbstractDict,
                              param_arrays::AbstractDict)
    classes = Dict{String,Symbol}()
    in_p = Set{String}(param_names)
    for (name, v) in model.variables
        (v.type == ParameterVariable || v.type == DiscreteVariable) || continue
        classes[name] = if name in reads
            :structural
        elseif name in in_p
            :numeric
        elseif haskey(param_arrays, name)
            :forcing
        else
            :const_folded
        end
    end
    # A `p` slot with no declared variable behind it cannot happen (param_names
    # comes from `model.variables`), but never leave a slot unclassified: the
    # solve-time override path refuses anything it cannot name a class for.
    for name in param_names
        haskey(classes, name) || (classes[name] = name in reads ? :structural : :numeric)
    end
    # The INJECTED data channels. A document's `"type": "parameter"` field may
    # stop being a parameter variable by the time the evaluator is built: a
    # coupling `variable_map` rewires the consumer's declared field onto the
    # LOADER's variable, which flattening emits as an observed (measured on
    # reseact.esm: `NEIRegrid.F_NO` is gone, and the emission field the regrid
    # actually folds is `NEI2016Emis.NEI2016.NO`). The surviving name is still
    # something a caller may try to override — and it is exactly the case a
    # gradient lies about, since the value was frozen into the build. So class
    # every caller-supplied array by its REGISTRY, keeping only names the model
    # actually carries (a synthetic build key like `__stgfw_…` is not a
    # user-facing parameter). A declared parameter keeps the class it already
    # has: `:structural` outranks "it is also const data".
    for (regname, cls) in ((const_arrays, :const_folded), (param_arrays, :forcing))
        for (rawk, _) in regname
            k = String(rawk)
            (haskey(classes, k) || !haskey(model.variables, k)) && continue
            classes[k] = cls
        end
    end
    return classes
end

# ---- Stage: fold `ic(var) = <initial value>` equations (esm-spec v0.8.0) ----
# An `ic`-LHS equation declares an initial condition. The tree-walk path seeds
# u0 from the `initial_conditions` kwarg / variable defaults, so pull each ic
# equation out here: const-fold its RHS to a scalar and record it (unless the
# caller already overrode that state), then drop the equation before the ODE
# partition / observed-substitution passes (its LHS is not a `D`, so it would
# otherwise be rejected as an unsupported equation form). No-op for files
# without an ic equation in `equations`.
#
# Scoped-reference / array `ic` targets (spec §11.4.1) are deferred (returned
# in `field_ics`) and folded per grid cell once array cells are known — see
# `_fold_field_ics!`. Each entry is `(target_state_name, rhs_field_expr)`; the
# target may be a dot-namespaced reference to another component's species that
# coupling has lifted onto the grid (`ic(Chemistry.O3) ~
# InitialConditions.O3_init`), and the RHS is a per-cell FIELD (a loaded
# const-array field, a broadcast constant, or a coordinate expression) rather
# than a single scalar. Returns `(kept_equations, eq_ics, field_ics)`.
function _fold_ic_equations(equations::Vector{Equation}, model::Model,
                            param_scope::AbstractDict,
                            registered_functions::AbstractDict)
    eq_ics = Dict{String,Float64}()
    field_ics = Tuple{String,EarthSciAST.ASTExpr}[]
    kept = Equation[]
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
            tvar = get(model.variables, vn, nothing)
            if tvar !== nothing && _is_array_shape(tvar.shape)
                push!(field_ics, (vn, eq.rhs))
            else
                # Scalar model PARAMETERS are in scope as load-time constants
                # (esm-spec §6.6.5 build-time evaluation scope), matching the
                # array/field-ic path (`_resolve_field_ic`); STATE stays out
                # of scope.
                eq_ics[vn] = try
                    Float64(evaluate_expr(eq.rhs, param_scope;
                                          registered_functions=registered_functions))
                catch err
                    throw(TreeWalkError("E_TREEWALK_UNSUPPORTED_EQUATION",
                        "ic($(vn)) RHS must const-fold to a scalar for the " *
                        "tree-walk path ($(sprint(showerror, err)))"))
                end
            end
        else
            push!(kept, eq)
        end
    end
    return kept, eq_ics, field_ics
end

# ---- Stage: enumerate declared-shape cells for equation-less array states ----
# A declared array STATE may carry only an `ic` and NO per-cell / whole-array
# `D` equation (a constant field held at its initial value, e.g. an ocean
# current pinned to 0). Such a state appears in no equation LHS and no per-cell
# ic key, so `_discover_array_cells` finds no cells for it — yet it needs one
# u0 slot per cell. Enumerate its cells from the declared shape's index-set
# extents (interval size / categorical cardinality / derived-set extent), the
# same registry the range machinery resolves. No-op for a state whose cells the
# equations already pin. Mutates `array_cells` in place.
function _enumerate_declared_array_cells!(array_cells, model::Model,
                                          index_sets::AbstractDict,
                                          derived_extents::AbstractDict, vi_vars)
    for (n, v) in model.variables
        (v.type == StateVariable && _is_array_shape(v.shape) && !(n in vi_vars)) || continue
        (haskey(array_cells, n) && !isempty(array_cells[n])) && continue
        exts = _declared_shape_extents(v.shape, index_sets, derived_extents)
        exts === nothing && continue
        cells = Vector{Int}[collect(Int, Tuple(I)) for I in CartesianIndices(Tuple(exts))]
        array_cells[n] = sort!(cells)
    end
    return nothing
end

# Per-dimension extents of a DECLARED shape, resolved against the document's
# index-set registry (interval `size` / categorical `members`) with the
# geometry- and value-invention-derived extents as the fallback. `nothing` when
# any axis does not resolve — the caller then leaves that variable alone.
function _declared_shape_extents(shape, index_sets::AbstractDict,
                                 derived_extents::AbstractDict)
    shape === nothing && return nothing
    exts = Int[]
    for s in shape
        ss = String(s)
        e = if haskey(index_sets, ss)
            is = index_sets[ss]
            if is.kind == "interval"
                is.size
            elseif is.kind == "categorical"
                _maybe(length, is.members)
            else
                get(derived_extents, ss, nothing)
            end
        else
            get(derived_extents, ss, nothing)
        end
        e === nothing && return nothing
        push!(exts, Int(e))
    end
    return exts
end

# ---- Stage: fold scoped-reference / array `ic` equations (spec §11.4.1) ----
# Now that each array state's cells are known, expand every deferred field-ic
# into per-element initial values keyed by the flat element name. The RHS may
# be a LOADED FIELD (a `const_arrays` entry supplying the initial field over
# the lifted grid), a broadcast constant, or a coordinate expression. Folding
# here means the array-cell u0 seeding (and callers that don't override)
# pick these up exactly like a model-local `ic`. A target that resolves to no
# array cells, or an RHS the seed path cannot evaluate, is a hard error — a
# missing/unsupported scoped ic is never silently dropped. Mutates `eq_ics`.
function _fold_field_ics!(eq_ics::Dict{String,Float64}, field_ics, array_cells,
                          param_scope::AbstractDict,
                          registered_functions::AbstractDict,
                          const_arrays::AbstractDict)
    for (target, rhs) in field_ics
        cells = get(array_cells, target, nothing)
        (cells === nothing || isempty(cells)) && throw(TreeWalkError(
            "E_TREEWALK_UNSUPPORTED_EQUATION",
            "ic($(target)): scoped-reference target resolves to no array cells; the " *
            "target must name a lifted/array state variable of the flattened system"))
        # Compile the coordinate field ONCE (indices as params) when possible; else
        # fall back to the per-cell resolve+compile. `ESS_STENCIL_DISABLE` forces the
        # per-cell path for both this and the symbolic stencil compiler.
        fast = _stencil_disabled() ? nothing :
               _try_field_ic_fastpath(rhs, param_scope, registered_functions, const_arrays)
        for cell in cells
            idxs = collect(Int, cell)
            eq_ics[_cell_key(target, idxs)] = fast === nothing ?
                _resolve_field_ic(target, rhs, idxs, const_arrays, registered_functions;
                                  params=param_scope) :
                fast(idxs)
        end
    end
    return nothing
end

# ---- Stage: flat state-vector cell names ----
# Array cells are enumerated in column-major order (first index fastest,
# consistent with Julia's native array layout and the Rust/Python runtimes).
function _enumerate_array_cell_names(array_cells, array_var_info)
    array_cell_names = String[]
    for vname in sort(collect(keys(array_cells)))
        haskey(array_var_info, vname) || continue
        lo, hi = array_var_info[vname]
        # `CartesianIndices` iterates the first index fastest — the same
        # column-major order the sibling `_enumerate_declared_array_cells!`
        # (and the manual linear-decode loop this replaced) produces.
        for I in CartesianIndices(ntuple(d -> lo[d]:hi[d], length(lo)))
            push!(array_cell_names, _cell_key(vname, collect(Int, Tuple(I))))
        end
    end
    return array_cell_names
end

# ---- Stage: initial-condition vector ----
# Seed u0 per state slot: an explicit `initial_conditions` entry wins, then an
# `ic`-equation value (scalar or per-cell field), then the variable's declared
# scalar default (an array cell falls back to its parent variable's default).
function _build_u0(model::Model, scalar_state_names::Vector{String},
                   array_cell_names::Vector{String},
                   initial_conditions::AbstractDict,
                   eq_ics::Dict{String,Float64})
    u0 = Vector{Float64}(undef, length(scalar_state_names) + length(array_cell_names))
    for (i, name) in enumerate(scalar_state_names)
        if haskey(initial_conditions, name)
            u0[i] = Float64(initial_conditions[name])
        elseif haskey(eq_ics, name)
            u0[i] = eq_ics[name]   # ic(var) = <value> equation
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
        elseif haskey(eq_ics, cname)
            u0[i_abs] = eq_ics[cname]   # scoped-reference / array ic (§11.4.1)
        else
            # Try the parent variable's scalar default (rare fallback).
            parsed = _parse_cell_key(cname)
            vname = parsed === nothing ? "" : parsed[1]
            if haskey(model.variables, vname)
                d = model.variables[vname].default
                u0[i_abs] = d === nothing ? 0.0 : Float64(d)
            else
                u0[i_abs] = 0.0
            end
        end
    end
    return u0
end

# ---- Stage: observed substitution / derivative-equation split ----
# Partition the surviving equations into derivative equations (scalar,
# indexed, and arrayop `D` forms) and the observed substitution map, then
# resolve observed-into-observed references to a fixed point. A live-field
# geometry observed (F_tgt …) or a promoted array observed enters the
# substitution map as an arrayop value; `index(obs, j)` in a reader
# beta-reduces to its body via `_resolve_indices` (ess-14f.4 /
# shape-promotion). Returns `(derivative_eqs, resolved_obs, raw_obs)`; the RAW
# map preserves the author-declared observed-into-observed references so the
# scalar-slot plan (`_plan_observed_slots`) can compile each observed once as a
# named prelude def instead of splicing the resolved chain into every reader.
function _split_observed_and_derivatives(equations::Vector{Equation},
                                         observed_names, geom_ring_vars,
                                         geom_setup_vars, geom_inline_vars,
                                         array_inline_vars,
                                         mat_array_vars=_EMPTY_NAME_SET)
    observed_exprs = Dict{String,ASTExpr}()
    # FACTORED array observeds are pulled OUT of the substitution map: their
    # readers gather the buffer by name (`index(obs, i…)` → a slot read), so
    # inlining their bodies is exactly what the buffer exists to avoid.
    mat_defs = Dict{String,ASTExpr}()
    derivative_eqs = Equation[]
    for eq in equations
        if eq.lhs isa VarExpr && (eq.lhs::VarExpr).name in mat_array_vars
            mat_defs[(eq.lhs::VarExpr).name] = eq.rhs
            continue
        end
        if eq.lhs isa VarExpr && ((eq.lhs::VarExpr).name in geom_ring_vars ||
                                  (eq.lhs::VarExpr).name in geom_setup_vars)
            # intersect_polygon clip ring / ranged-clip / per-pair area / A_ij —
            # materialized into a const_array at setup (RFC §8.1, §6.1); not a
            # scalar observed and produces no ODE.
            continue
        elseif _is_scalar_D_lhs(eq.lhs)
            push!(derivative_eqs, eq)
        elseif _is_indexed_D_lhs(eq.lhs) || _is_arrayop_D_lhs(eq.lhs)
            push!(derivative_eqs, eq)
        elseif isa(eq.lhs, VarExpr) && (eq.lhs.name in observed_names ||
                                        eq.lhs.name in geom_inline_vars ||
                                        eq.lhs.name in array_inline_vars)
            observed_exprs[eq.lhs.name] = eq.rhs
        else
            # Algebraic constraint / unsupported equation form.
            # The tree-walk path is ODE-only; see bead's "Not in scope".
            throw(TreeWalkError("E_TREEWALK_UNSUPPORTED_EQUATION",
                                _equation_tag(eq)))
        end
    end
    return derivative_eqs, _resolve_observed(observed_exprs), observed_exprs, mat_defs
end

const _EMPTY_NAME_SET = Set{String}()

# ---- Stage: scalar-observed slot plan (named prelude defs; ess-obs-slots) ----
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
#   * ARRAY-valued observeds (arrayop/makearray producers, geometry live fields,
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
# The ARRAY paths (arrayop kernels, stencil/affine builds, discrete-cadence
# fills) keep receiving the FULL resolved map and inline exactly as before; a
# kernel's inlined copy of a slotted observed is later collapsed onto the
# observed's slot by `_share_lane_invariants!` when the value numbers match.
#
# Returns `(; defs, inline, n_inlined)`:
#   defs      — dependency-ordered `name => body` pairs; each body is the RAW
#               observed RHS with only the non-slot observeds substituted (so
#               slot-to-slot references stay by-name and compile to slot reads);
#   inline    — the substitution map for SCALAR equations: `resolved_obs` minus
#               the slotted names (`nothing` ⇔ no slots, so the caller passes
#               `resolved_obs` through untouched — byte-identical build);
#   n_inlined — observed equations NOT slotted (array + leaf + demoted).
function _plan_observed_slots(derivative_eqs::Vector{Equation},
                              raw_obs::Dict{String,ASTExpr},
                              resolved_obs::Dict{String,ASTExpr},
                              observed_names)
    n_total = length(raw_obs)
    none = (; defs=Pair{String,ASTExpr}[], inline=nothing, n_inlined=n_total)
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
    scalar_rhs = ASTExpr[eq.rhs for eq in derivative_eqs
                         if _is_scalar_D_lhs(eq.lhs) || _is_indexed_D_lhs(eq.lhs)]
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
        tot = Dict{String,Int}()
        unc = Dict{String,Int}()
        for rhs in scalar_rhs
            _count_obs_refs!(rhs, candidates, tot, unc, false)
        end
        for name in candidates
            _count_obs_refs!(raw_obs[name], candidates, tot, unc, false)
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
    inline = Dict{String,ASTExpr}(k => v for (k, v) in resolved_obs
                                  if !(k in candidates))
    order = _dependency_order(sort!(collect(candidates)),
        n -> String[r for r in _referenced_var_names(raw_obs[n]) if r in candidates];
        on_cycle=done -> throw(TreeWalkError("E_TREEWALK_OBSERVED_CYCLE",
            join(sort!(collect(setdiff(candidates, done))), ","))))
    defs = Pair{String,ASTExpr}[]
    for n in order
        body = raw_obs[n]
        isempty(inline) || (body = _sub_preserving(body, inline))
        push!(defs, n => body)
    end
    return (; defs, inline, n_inlined=n_total - length(defs))
end

# ---- Stage: const-array registry ----
# Pre-computed constant arrays (Fornberg weights, mesh connectivity, etc.).
# Supports both 1D (Fornberg weights) and ND (connectivity matrices for
# mesh reductions). 1D entries are stored as Vector{Float64}; higher-rank
# entries as plain Array{Float64,N}. An array named in `const_array_boundaries`
# is wrapped in a BoundedConstArray so OOB stencil gathers resolve per its
# declared per-dimension policy (ess-gj4). Setup-materialized geometry (clip
# rings, per-pair areas), fused-leaf operand rings, and const-op array
# observeds are registered on top.
function _register_const_arrays(const_arrays::AbstractDict,
                                const_array_boundaries::AbstractDict,
                                geom_rings, geom_setup_arrays,
                                pia_operand_arrays, const_obs_arrays)
    const_boundaries = Dict{String,Any}(String(k) => v for (k, v) in const_array_boundaries)
    registry = Dict{String,AbstractArray{Float64}}()
    for (k, v) in const_arrays
        k_str = String(k)
        arr = ndims(v) == 1 ? Vector{Float64}(v) : Array{Float64}(v)
        bnd = get(const_boundaries, k_str, nothing)
        registry[k_str] = bnd === nothing ? arr : _wrap_bounded_const(arr, bnd, k_str)
    end
    # M4 (RFC §8.1): register each materialized intersect_polygon clip ring as a
    # 2D const_array under its observed-variable name, so the polygon_area FAQ body
    # reads its vertices via `index(clip, v, c)` through the existing const-array
    # path. The CLOSED ring (n+1 rows) makes the wrap edge an ordinary `v+1` lookup.
    for (k, ring) in geom_rings
        registry[k] = ring
    end
    # M4+: register each setup-materialized geometry array (per-pair area, A_ij, …)
    # so the ODE body reads it via `index(area, p)` / `index(A_ij, i, j)`.
    for (k, arr) in geom_setup_arrays
        registry[k] = arr
    end
    # polygon_intersection_area operands: the const polygon vertex rings the fused
    # leaf clips + areas. Registered as 2D const_arrays so `_resolve_indices` folds
    # `polygon_intersection_area(src, tgt)` to its scalar overlap area (§8.6.1).
    for (k, ring) in pia_operand_arrays
        registry[k] = ring
    end
    # const-op array observeds (in-file ring stacks / source fields): registered so
    # an ODE reads `index(F_src, i)` and a setup aggregate gathers `index(src_poly, i)`.
    for (k, arr) in const_obs_arrays
        haskey(registry, k) || (registry[k] = arr)
    end
    return registry
end

# ---- Stage: live forcing buffers (ess-14f.3, JL-J0 — the one engine touch) ----
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
function _build_pgather(param_arrays::AbstractDict)
    pgather = Dict{String,_PGatherArray}()
    for (k, v) in param_arrays
        k_str = String(k)
        v isa Array{Float64} ||
            throw(TreeWalkError("E_TREEWALK_PARAM_ARRAY_TYPE",
                  "param_arrays['$(k_str)'] must be a dense Array{Float64} " *
                  "(captured by reference for live refresh), got $(typeof(v))"))
        # `vec` of a dense Array{Float64} ALIASES its buffer — captured by
        # reference, NOT copied (unlike const_arrays), so the caller's / J1
        # callback's in-place `v .= …` refreshes what the RHS reads.
        pgather[k_str] = _PGatherArray(vec(v), collect(size(v)))
    end
    return pgather
end

# ---- Stage: arrayop-valued initialization_equations → u0 ----
# When discretize() materializes an IC equation as an arrayop (coord-subst
# x→index(coord_x,i)), we evaluate it per-cell here using the same
# index-substitution + _resolve_indices + _compile pattern used by the ODE
# arrayop path. The coord_<dim> const_array must be provided by the caller.
# Explicit initial_conditions values take precedence (already seeded in u0).
function _seed_arrayop_init_u0!(u0::Vector{Float64}, init_equations,
                                initial_conditions::AbstractDict,
                                var_map::Dict{String,Int}, array_var_info,
                                const_arrays::AbstractDict,
                                pgather::AbstractDict, param_sym_set, reg_funcs, p)
    for eq in init_equations
        eq.lhs isa VarExpr || continue
        eq.rhs isa OpExpr && _is_aggregate_op((eq.rhs::OpExpr).op) || continue
        var_name = (eq.lhs::VarExpr).name
        rhs_op   = eq.rhs::OpExpr
        idx_names = _output_idx_strings(rhs_op)
        ranges_dict = _ranges_dict(rhs_op)
        body = rhs_op.expr_body
        body === nothing && continue
        range_iters = [collect(_expand_int_range(ranges_dict[n])) for n in idx_names]
        for idx_tuple in Iterators.product(range_iters...)
            idx_exprs = Dict{String,ASTExpr}(idx_names[d] => IntExpr(Int64(idx_tuple[d]))
                                          for d in 1:length(idx_names))
            cname = _cell_key(var_name, [idx_tuple[d] for d in 1:length(idx_names)])
            slot = get(var_map, cname, 0)
            slot == 0 && continue
            haskey(initial_conditions, cname) && continue   # explicit override wins
            sub_body = _sub_preserving(body, idx_exprs)
            body_r   = _resolve_indices(sub_body, array_var_info, var_map, const_arrays, pgather)
            node     = _compile(body_r, var_map, param_sym_set, reg_funcs)
            u0[slot] = _eval_node(node, u0, isnothing(p) ? NamedTuple() : p, 0.0)
        end
    end
    return nothing
end

# True if `e` contains a gather `index(arr, sub…)` whose SUBSCRIPT references a scalar
# parameter — the signature of a nearest-neighbour COORDINATE regrid
# (`index(F_fuel, floor((tgt_lat[j] − src_y0)/src_dy)…)`, whose subscript reads the
# grid-geometry parameters src_y0/src_dy). The integer const-index folder cannot
# evaluate such a subscript, so it marks the const-tier materialization seed. An affine
# subscript (loop vars + const-array gathers, e.g. a conservative regrid's `W[i,j]` or
# a reshape `(gy−1)·NX+gx`) references no scalar parameter and is NOT flagged.
# The scan visits EVERY expression-bearing field via the shared traversal (not a
# hand-rolled args/expr_body/values subset), so a coordinate gather buried in an
# aggregate `filter` predicate or a table-lookup axis is seen too.
# IDENTITY-MEMOIZED (`foreach_subexpr_once`): a pure existence predicate is
# path-multiplicity-insensitive, and the cadence-split def bodies scanned here
# are DAGs after template lowering / `_sub_preserving` — the per-path walk
# (`foreach_subexpr`) was exponential on a shared doubling chain (ESS-0hh).
function _has_param_indexed_gather(e::ASTExpr, scalar_params::Set{String})
    found = false
    foreach_subexpr_once(e) do n
        found && return nothing
        n isa OpExpr && n.op == "index" && length(n.args) >= 2 || return nothing
        for k in 2:length(n.args)
            if any(r -> r in scalar_params, _referenced_var_names(n.args[k]))
                found = true
                return nothing
            end
        end
        return nothing
    end
    return found
end

# ---- Stage: cadence materialization split (the discrete + const cuts) ----
# From the INLINE-candidate array observeds (`geom_inline_vars` ∪ `array_inline_vars`)
# pull out two classes that must NOT be inlined into the state RHS. A field is
# PARAM-TAINTED iff its def transitively reads a live `param_arrays` buffer;
# STATE-REACHING iff it transitively reads a continuous `state` or `t`.
#
#   • DISCRETE (param-tainted, NOT state-reaching): a per-bracket conservative regrid —
#     materialized ONCE PER REFRESH into a cache buffer (the pre-existing middle phase).
#   • CONST (const-cadence, NOT state-reaching): a NEAREST-NEIGHBOUR COORDINATE regrid
#     (`index(F_fuel, floor((tgt_lat[j] − src_y0)/src_dy)…)`) whose gather SUBSCRIPT is
#     a coordinate/parameter FLOAT the integer const-index folder cannot evaluate. It
#     (and its const dependency chain) materializes BUILD-ONCE into a const array
#     through the setup-time evaluator (see the call site); its readers then fold over
#     that const array per cell. The seed is precise — a def that gathers with a
#     subscript referencing a SCALAR PARAMETER — so a conservative Era5/elevation regrid
#     (affine src gather) and an ordinary contraction (`Σ_i W[i,j]·x`) are NOT flagged.
#
# Everything else (a param-tainted AND state/`t`-reaching field — the time-interpolated
# ERA5 met blend + the Rothermel/EMC/wind physics over it) STAYS inlined: after the
# discrete cut its body is an AFFINE blend of the discrete caches
# (`(1−w_time)·index(t_xy0,x,y) + w_time·index(t_xy1,x,y)`) the symbolic-stencil folder
# handles. `array_inline_candidates` is the const-tier pool (the geometry live-field
# set is param-tainted by construction, never const). A model with no coordinate regrid
# gets an empty const set (byte-identical). Returns `(discrete_vars, const_vars)`.
function _discrete_materialize_split(equations::Vector{Equation},
                                     inline_candidates, array_inline_candidates,
                                     state_var_names, param_names, scalar_param_names)
    empty = Set{String}()
    isempty(inline_candidates) && isempty(array_inline_candidates) &&
        return (empty, copy(empty))
    defs = Dict{String,ASTExpr}()
    for eq in equations
        eq.lhs isa VarExpr && (defs[(eq.lhs::VarExpr).name] = eq.rhs)
    end
    _closure(seed_set) = begin
        reached = Set{String}()
        changed = true
        while changed
            changed = false
            for (n, rhs) in defs
                n in reached && continue
                refs = _referenced_var_names(rhs)
                if any(r -> (r in seed_set) || (r in reached), refs)
                    push!(reached, n); changed = true
                end
            end
        end
        reached
    end
    # PARAM-TAINTED: transitively reads a live forcing buffer name.
    param_tainted = isempty(param_names) ? Set{String}() : _closure(Set{String}(param_names))
    # STATE-REACHING: transitively reads a continuous state (seeded with the states
    # themselves so a direct reader is caught) or `t`.
    state_seed = Set{String}(state_var_names); push!(state_seed, "t")
    state_reaching = _closure(state_seed)
    discrete = Set{String}(n for n in inline_candidates
                           if (n in param_tainted) && !(n in state_reaching))
    # CONST tier — coordinate-regrid SEED (a parameter-indexed gather), then close over
    # its const-cadence array dependencies so `_materialize_geometry_setup` can resolve
    # each body against the already-materialized upstream. Restricted to const-cadence
    # producers (neither param-tainted nor state/`t`-reaching).
    is_const(n) = !(n in param_tainted) && !(n in state_reaching)
    const_vars = Set{String}(n for n in array_inline_candidates
        if is_const(n) && haskey(defs, n) &&
           _has_param_indexed_gather(defs[n], scalar_param_names))
    changed = true
    while changed
        changed = false
        for n in collect(const_vars)
            for r in _referenced_var_names(defs[n])
                (r in array_inline_candidates) && !(r in const_vars) && is_const(r) || continue
                push!(const_vars, r); changed = true
            end
        end
    end
    return (discrete, const_vars)
end

# Dependency order over the discrete-materialize vars (a cache that gathers another
# cache must fill AFTER it). Mirrors `_geom_setup_order`.
function _discrete_fill_order(discrete_vars, discrete_defs)
    return _dependency_order(collect(discrete_vars),
        n -> intersect(_referenced_var_names(discrete_defs[n]), discrete_vars);
        on_cycle=done -> throw(TreeWalkError("E_TREEWALK_DISCRETE_MATERIALIZE",
            "cyclic dependency among discrete-cadence vars: $(setdiff(discrete_vars, done))")))
end

# ---- The discrete-cadence STATE-FREEDOM CHECK (ess-5d1) ----
# `materialize!` evaluates every fill node with `u = zeros(n_states)` and `t = 0.0`,
# and re-runs only on a data-refresh event — so a fill node that READS a continuous
# state or `t` does not merely give a wrong number once, it FREEZES the field at
# `u = 0` for the whole integration, silently. State-freedom is supposed to be
# guaranteed upstream by `_discrete_materialize_split` (a state-reaching def is never
# classified discrete), but that guarantee rests on a name-reachability walker, and a
# walker that misses one expression-bearing field turns the whole class of bug into a
# wrong trajectory with no error. So we do not ASSUME it — we CHECK it, on the thing
# that actually runs: the compiled fill node.
#
# Legal leaves in a fill: `_NK_LITERAL`, `_NK_PARAM` (a scalar param), `_NK_OP` /
# `_NK_CONTRACTION`, and — expected, not exceptional — `_NK_PARAM_GATHER`, which is
# how a fill reads a raw live forcing buffer or an upstream discrete cache.
# `_NK_CACHED` (a CSE prelude slot) cannot occur: fills compile through plain
# `_compile`, never `_cse_compile_scalar`. If one ever appears the prelude that backs
# it is not evaluated by `materialize!`, so the read would be garbage — that is an
# internal invariant break, and it is reported rather than silenced.
# (`node` is a `_Node`; it is left unannotated because `compile.jl` — where `_Node`
# is defined — is `include`d after this file, so the signature cannot name the type.)
function _check_discrete_fill_state_free(node, name::String)
    k = node.kind
    if k === _NK_STATE || k === _NK_TIME
        what = k === _NK_STATE ? "a continuous state variable" : "the time variable `t`"
        throw(TreeWalkError("E_TREEWALK_DISCRETE_MATERIALIZE",
            "discrete-cadence var '$name' depends on $what. A discrete-cadence cache " *
            "is filled only when the forcing data refreshes (its fill kernel runs " *
            "with u = 0 and t = 0), so it CANNOT depend on a continuous state or on " *
            "`t` — the field would silently freeze at u = 0 instead of tracking the " *
            "solution. Either drop the state/`t` dependency from '$name' (keep the " *
            "state-dependent part in its readers, where it stays on the continuous " *
            "path), or, if the reference reaches '$name' through an expression field " *
            "the cadence classifier does not walk, that classifier is the bug."))
    elseif k === _NK_CACHED
        throw(TreeWalkError("E_TREEWALK_DISCRETE_MATERIALIZE",
            "internal: the discrete-cadence fill kernel for '$name' contains a CSE " *
            "cache reference (_NK_CACHED), whose prelude `materialize!` does not " *
            "evaluate. Fill kernels compile through `_compile`, not the CSE pass — " *
            "this is a build-pipeline invariant break, not a model error."))
    end
    for c in node.children
        _check_discrete_fill_state_free(c, name)
    end
    return nothing
end

# ---- Stage: discrete-cadence cache buffers + fill kernels ----
# Allocate a dense cache buffer per discrete var, register it in `pgather` (so a
# reader's `index(var, j…)` gathers the cache via `_NK_PARAM_GATHER` — the SAME
# zero-alloc live-buffer path a raw forcing read uses, NOT an inline beta-reduction),
# and precompile a per-cell fill node list. `materialize!` evaluates every node into
# its cache in dependency order — reusing the proven `_seed_arrayop_init_u0!`
# per-cell (`_sub_preserving` → `_resolve_indices` → `_compile` → `_eval_node`)
# pattern, but writing a cache buffer instead of a u0 slot, and reading the live raw
# buffers + const arrays + upstream caches. Runs once here (initial fill) and again
# per refresh. `mut` is the caller's `DiscreteMaterializer` sink; it is populated in
# place. Mutates `pgather` (adds the caches).
function _build_discrete_materializer!(mut::DiscreteMaterializer,
        discrete_vars, discrete_defs::Dict{String,ASTExpr}, resolved_obs::Dict{String,ASTExpr},
        array_var_info, var_map::Dict{String,Int}, const_arrays::AbstractDict,
        pgather::AbstractDict, param_sym_set, reg_funcs, p, n_states::Int)
    isempty(discrete_vars) && return nothing
    order = _discrete_fill_order(discrete_vars, discrete_defs)
    caches = Dict{String,Array{Float64}}()
    cells_of = Dict{String,Tuple{Vector{String},Vector{Vector{Int}}}}()
    # 1. Allocate + register EVERY cache first, so a fill body that gathers another
    #    discrete cache resolves to a pgather over it (values filled later, in order).
    for name in order
        rhs = discrete_defs[name]
        (rhs isa OpExpr && _is_aggregate_op((rhs::OpExpr).op)) ||
            throw(TreeWalkError("E_TREEWALK_DISCRETE_MATERIALIZE",
                "discrete-cadence var '$name' must be an arrayop/aggregate producer"))
        rop = rhs::OpExpr
        idx_names = _output_idx_strings(rop)
        ranges = _ranges_dict(rop)
        rngs = Vector{Int}[collect(_expand_int_range(ranges[n])) for n in idx_names]
        for (d, r) in enumerate(rngs)
            (!isempty(r) && r == collect(1:length(r))) || throw(TreeWalkError(
                "E_TREEWALK_DISCRETE_MATERIALIZE",
                "discrete-cadence var '$name' dim $d range must be 1..n (got $(r)); " *
                "the cache gather is 1-based column-major"))
        end
        dims = isempty(rngs) ? Int[1] : Int[length(r) for r in rngs]
        cache = zeros(Float64, dims...)
        caches[name] = cache
        pgather[name] = _PGatherArray(vec(cache), collect(size(cache)))
        cells_of[name] = (idx_names, rngs)
    end
    # 2. Precompile per-cell fill nodes: (cache_vec, linear_index, node). Each cell is
    #    compiled as `index(<the defining aggregate>, j0…)` and resolved through the
    #    SAME `_resolve_index_of_arrayop` expansion the inline reader uses — so a
    #    reduction over CONTRACTED indices (the conservative regrid Σ_i A_ij·F_src/A_j,
    #    whose sum-over-source `i` lives in the aggregate's ranges, not the body) is
    #    expanded, not silently dropped. Scalar observeds are inlined into the
    #    aggregate first via `resolved_obs` (the inline reader gets them the same way);
    #    an `index(other_discrete, i)` stays a pgather over that cache (other discrete
    #    vars are excluded from `resolved_obs`).
    fills = Tuple{Vector{Float64},Int,_Node}[]
    for name in order
        rop = discrete_defs[name]::OpExpr
        rop_res = isempty(resolved_obs) ? rop : _sub_preserving(rop, resolved_obs)
        rop_res isa OpExpr ||
            throw(TreeWalkError("E_TREEWALK_DISCRETE_MATERIALIZE",
                "discrete-cadence var '$name' resolved to a non-arrayop expression"))
        idx_names, rngs = cells_of[name]
        cvec = vec(caches[name])
        dims = isempty(rngs) ? Int[1] : Int[length(r) for r in rngs]
        lin = LinearIndices(Tuple(dims))
        for idx_tuple in Iterators.product(rngs...)
            gather = OpExpr("index", ASTExpr[rop_res::OpExpr,
                (IntExpr(Int64(idx_tuple[d])) for d in 1:length(idx_names))...])
            g_r = _resolve_indices(gather, array_var_info, var_map, const_arrays, pgather)
            node = _compile(g_r, var_map, param_sym_set, reg_funcs)
            # The cadence cut is CHECKED, not assumed: a fill kernel that reads `u` or
            # `t` would freeze at u = 0 (see `_check_discrete_fill_state_free`).
            _check_discrete_fill_state_free(node, name)
            l = isempty(idx_tuple) ? 1 : lin[idx_tuple...]
            push!(fills, (cvec, l, node))
        end
    end
    # 3. `materialize!`: eval every fill into its cache (dep order preserved by the
    #    build order). Every fill node was CHECKED state-free above, so the zero `u` /
    #    `t=0` passed to `_eval_node` is provably never read; `p` carries the scalar
    #    params a fill may use.
    uz = zeros(Float64, n_states)
    pp = isnothing(p) ? NamedTuple() : p
    function materialize!()
        @inbounds for (cv, l, node) in fills
            cv[l] = _eval_node(node, uz, pp, 0.0)
        end
        # The caches just changed IN PLACE under readers gathering them via
        # `_NK_PARAM_GATHER` — invalidate the memoized time-cadence prelude slots
        # (B3, const_tier.jl): a refresh fires AT its tstop, so the next RHS call
        # is at a `t` the t-tier stamp may already hold.
        _bump_forcing_epoch!()
        return nothing
    end
    materialize!()          # initial fill — valid caches for u0 seeding + first step
    mut.caches = caches
    mut.materialize! = materialize!
    mut.var_order = order
    return nothing
end

# ============================================================
# 2b-f. Factored array-observed buffers (per-RHS-call materialization)
# ============================================================
#
# The runtime half of `_collect_materialized_array_obs`. Each materialized array
# observed owns a dense block of slots above the ODE state in ONE extended value
# vector; `f!` copies the integrator's `u` into it, fills the observed blocks in
# dependency order, and then runs the ordinary state RHS against the extended
# vector. Since the reads compiled to plain state gathers, nothing downstream
# (the affine box processor, the kernel-class merge, the codegen tier, the
# cadence classifier) needed to learn a new leaf.

# The extended value vector. Two buffers — Float64 plus a lazily-allocated `alt`
# for the value type an AD-driven `f!` is called at — exactly like `_CSECache` /
# `_AccScratch`, so the RHS stays zero-alloc at Float64 AND differentiable.
# Allocated ONCE at build and reused across every RHS call.
mutable struct _ObsExtVec
    f64::Vector{Float64}
    alt::Any
end
_ObsExtVec(n::Int) = _ObsExtVec(zeros(Float64, n), nothing)
@inline _obsext_buf(s::_ObsExtVec, ::Type{Float64}) = s.f64
@inline function _obsext_buf(s::_ObsExtVec, ::Type{T}) where {T}
    b = s.alt
    b isa Vector{T} && return b
    nb = zeros(T, length(s.f64))
    s.alt = nb
    return nb
end

# Synthesize the per-cell fill equation for one materialized array observed:
#
#     arrayop(D(index(obs, i…)), output_idx=[i…], ranges=1…n) = index(<def>, i…)
#
# i.e. exactly the shape `_compile_arrayop_equation!` consumes for an array
# STATE equation, so the fill reuses the whole array-equation cascade (affine
# polyhedral build, per-cell fallback, per-cell CSE, class merge, codegen) with
# no bespoke kernel path.
#
# THE RHS IS THE GATHER FORM `index(<def>, i…)`, not the bare producer — even
# when `<def>` is an `aggregate` whose own `output_idx` matches. `index(<def>, i…)`
# is EXACTLY the expression every reader of this observed used to present after
# inlining, so the fill lowers through the identical, already-exercised path.
#
# HISTORICALLY this was also a correctness requirement, because the bare form
# routed a contraction into the affine LANE derivation, whose const-lane fold
# (`_derive_lane_repl`, stencil_affine.jl) then decided a lane was loop-invariant
# by comparing its VALUES at the box CORNERS: a const gather agreeing at the
# corners and differing inside — a regrid weight column `W[i, j]` reading
# (0, 0.5, 0) — folded to a literal 0.0 and the interior cell silently computed
# the wrong number. That hole is CLOSED: `_derive_lane_repl` no longer samples
# values, deriving invariance structurally from the resolved linear index
# instead. The gather form is now a lowering-path default, not a guard.
#
# EXCEPTION, applied downstream rather than here: a producer that CONTRACTS is
# unwrapped back to the bare form by `_unwrap_identity_gather`. The gather form
# hides a contraction from `_compile_arrayop_equation!` entirely (it tests
# `rhs.op == "aggregate"` and sees `index`), so scan detection, the unrolled fold
# and the runtime contraction loop are all skipped and the equation drops to the
# per-cell tier at O(#cells) IR. A NON-contracting producer keeps the gather
# form: it lowers identically either way.
function _materialized_fill_equation(name::String, def::ASTExpr, dims::Vector{Int})
    nd = length(dims)
    # Fresh loop names; the `_mo` prefix is engine-internal and never part of a
    # cell key. Guard against the (pathological) case of a body that already
    # binds one by falling back to a name-qualified variant.
    loops = String["_mo$(d-1)" for d in 1:nd]
    let clash = false
        foreach_subexpr_once(def) do x
            clash || (x isa VarExpr && x.name in loops && (clash = true))
            nothing
        end
        clash && (loops = String["_mo$(d-1)_$(name)" for d in 1:nd])
    end
    ranges = Dict{String,Any}(loops[d] => Any[1, dims[d]] for d in 1:nd)
    idx_args = ASTExpr[VarExpr(name)]
    for l in loops
        push!(idx_args, VarExpr(l))
    end
    lhs = OpExpr("arrayop", ASTExpr[];
                 output_idx=Any[l for l in loops], ranges=ranges,
                 expr_body=OpExpr("D", ASTExpr[OpExpr("index", idx_args)]; wrt="t"))
    rhs = OpExpr("index", ASTExpr[def, (VarExpr(l) for l in loops)...])
    return Equation(lhs, rhs)
end

# Dependency LEVELS over the materialized observeds: level 1 reads none of them,
# level k only levels < k. Within a level the fills are order-independent, which
# is what lets each level run its scalar entries and then its (class-merged)
# kernel section in one go. A cycle is a genuine authoring error and is reported
# with the existing observed-cycle code.
#
# The edges must be TRANSITIVE THROUGH THE OBSERVEDS THAT STAYED INLINED: if a
# materialized `M` reads an inlined observed `X` whose body reads a materialized
# `N`, then `M`'s fill reads `N`'s buffer (X is spliced into M) even though `N`
# never appears in `M`'s own def. Ordering on direct references alone would let
# `M` fill from an unfilled `N` — a silently wrong RHS, not an error. So the
# walk expands through every non-materialized observed definition and stops at
# the materialized ones (their buffers are the dependency).
function _materialized_obs_levels(mat_defs::Dict{String,ASTExpr}, names,
                                  inline_obs::Dict{String,ASTExpr})
    nm = Set{String}(names)
    function reach(root::ASTExpr)
        out = Set{String}()
        seen = Set{String}()
        frontier = collect(_referenced_var_names(root))
        while !isempty(frontier)
            r = pop!(frontier)
            if r in nm
                push!(out, r)
            elseif !(r in seen) && haskey(inline_obs, r)
                push!(seen, r)
                append!(frontier, collect(_referenced_var_names(inline_obs[r])))
            end
        end
        return out
    end
    deps = Dict{String,Set{String}}(n => setdiff(reach(mat_defs[n]), (n,))
                                    for n in names)
    order = _dependency_order(sort(collect(names)), n -> deps[n];
        on_cycle=done -> throw(TreeWalkError("E_TREEWALK_OBSERVED_CYCLE",
            join(sort(collect(setdiff(nm, done))), ","))))
    depth = Dict{String,Int}()
    for n in order
        depth[n] = isempty(deps[n]) ? 1 : 1 + maximum(depth[d] for d in deps[n])
    end
    nlev = isempty(order) ? 0 : maximum(values(depth))
    return [String[n for n in order if depth[n] == k] for k in 1:nlev]
end

# Wrap the compiled state RHS with the per-call observed fills. Returns `f_state!`
# UNCHANGED when nothing is materialized, so every model without a factored array
# observed keeps a byte-identical closure (and its zero-allocation property).
# `levels` is a vector of `(scalar_nodes, kernel_section, scan_folds)` in
# dependency order.
function _make_rhs_with_obs_buffers(f_state!, ext::_ObsExtVec, n_states::Int,
                                    levels::Tuple)
    isempty(levels) && return f_state!
    function f!(du, u, p, t)
        T = _rhs_value_type(u, p, t)
        ue = _obsext_buf(ext, T)
        @inbounds copyto!(ue, 1, u, 1, n_states)
        # Fill the observed buffers level by level: a level's defs read only the
        # state and STRICTLY LOWER levels, both already valid in `ue`.
        _fill_obs_levels!(levels, ue, p, t, T)
        f_state!(du, ue, p, t)
        return nothing
    end
    return f!
end

# The levels are a TUPLE, walked by tail recursion so the loop unrolls and every
# `_KernelSection` call site is statically dispatched — a `Vector` of levels
# would box each heterogeneously-parameterized section and cost an allocation
# per level per RHS call (the RHS must stay allocation-free in steady state).
@inline _fill_obs_levels!(::Tuple{}, ue, p, t, ::Type{T}) where {T} = nothing
@inline function _fill_obs_levels!(levels::Tuple, ue, p, t, ::Type{T}) where {T}
    lv = levels[1]
    ents = lv[1]
    @inbounds for k in eachindex(ents)
        e = ents[k]
        ue[e[1]] = _eval_node(e[2], ue, p, t, T)
    end
    lv[2](ue, ue, p, t, T)
    # ess-scan: this level's forward prefix reductions accumulate in place over
    # the terms the kernel section just wrote — the same post-pass, in the same
    # position, that `_make_rhs` runs behind the state kernel section. Empty for
    # every level whose observeds carry no cumulative reduction.
    sf = lv[3]
    isempty(sf) || _apply_scan_folds!(ue, sf)
    return _fill_obs_levels!(Base.tail(levels), ue, p, t, T)
end

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
function _build_lower_and_classify(model::Model;
        const_arrays::AbstractDict, param_arrays::AbstractDict,
        vi_vars, has_value_invention::Bool, materialize_out,
        form::Symbol=:inplace)
    # ---- Observed synthesis + equation pre-lowering ----
    # (see `_prepare_model_equations`: expression-defined observed synthesis,
    # WS4 elementwise array-observed fold, whole-array derivative lift)
    equations, folded_array_obs = _prepare_model_equations(model)

    # ---- Geometry variable discovery ----
    # (see `_discover_geometry_vars`: direct clip rings, build-once setup vars,
    # live-field inline vars, and the has_* gates)
    geo = _discover_geometry_vars(model, equations, param_arrays, vi_vars)
    geom_inline_vars = geo.inline_vars

    # ---- Promoted array observeds (shape-promotion inlining) ----
    array_inline_vars = _collect_array_inline_vars(model, equations,
        geo.setup_vars, geo.ring_vars, geom_inline_vars)

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
    discrete_vars = Set{String}()
    if materialize_out !== nothing
        pre_state = Set{String}(n for (n, v) in model.variables
                                if v.type == StateVariable && !(n in vi_vars))
        scalar_params = Set{String}(n for (n, v) in model.variables
            if v.type == ParameterVariable && !_is_array_shape(v.shape))
        discrete_vars, const_mat_vars = _discrete_materialize_split(
            equations, union(geom_inline_vars, array_inline_vars),
            copy(array_inline_vars), pre_state,
            Set{String}(String(k) for k in keys(param_arrays)), scalar_params)
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

    # ---- polygon_intersection_area fused-leaf operands (esm-spec §8.6.1) ----
    pia_operand_vars, pia_operand_arrays =
        _collect_pia_operand_arrays(model, equations, const_arrays, geo.has_pia)

    # ---- const-op array observeds (in-file polygon rings / source fields) ----
    const_obs_vars, const_obs_arrays = _collect_const_obs_arrays(model,
        const_arrays, pia_operand_vars, geo.ring_vars,
        geo.has_setup_geometry || has_value_invention)

    # ---- bare-alias array observeds (keyed-factor re-exposure, esm-spec §4.6) ----
    _register_bare_alias_arrays!(const_obs_arrays, const_obs_vars, model, equations;
        const_arrays=const_arrays, pia_operand_vars=pia_operand_vars,
        geom_ring_vars=geo.ring_vars, geom_setup_vars=geo.setup_vars,
        geom_inline_vars=geom_inline_vars, array_inline_vars=array_inline_vars)

    # ---- Factored array observeds (buffer-materialized, per RHS call) ----
    # A SUBSET of `array_inline_vars` (so every ownership/partition exclusion
    # keyed on that set keeps holding): the promoted array observeds that get a
    # dense buffer instead of being spliced into each reader. Phase 3 narrows it
    # again to the ones whose extents actually resolve. Empty (byte-identical)
    # under `ESS_ARRAY_OBS_INLINE=1` and for any model with no promoted array
    # observed.
    #
    # BOTH EMITTERS. This was `:inplace`-only, on the reasoning that the `:oop`
    # emitter builds its own `du` and had no buffer to fill. That made inlining
    # MANDATORY under `:oop`, and inlining is superlinear: a reader spliced with
    # a reduction body pays the whole body per output cell. Measured on ReSEACT
    # at 7×7×8 — the smallest grid that model builds — the SAME emitter takes
    # 2 GiB materialized and OOMs past 39 GiB inlined, so the traced build was
    # not merely slower, it was impossible. `_make_rhs_oop` now fills the same
    # observed block through the `_oop_du_zeros`/`_oop_store` seam that already
    # exists for exactly this reason (a backend may implement the writes
    # functionally on an immutable traced value).
    mat_array_vars = _collect_materialized_array_obs(model, equations,
                                                     array_inline_vars, discrete_vars)

    return (; equations, folded_array_obs,
            has_geometry=geo.has_geometry,
            has_setup_geometry=geo.has_setup_geometry,
            geom_ring_vars=geo.ring_vars, geom_setup_vars=geo.setup_vars,
            geom_defs=geo.defs, geom_inline_vars, array_inline_vars,
            discrete_vars, pia_operand_vars, pia_operand_arrays,
            const_obs_vars, const_obs_arrays, mat_array_vars)
end

# ---- Phase 2: ODE variable partition + setup materialization + equation rewrites ----
# From the classified equation stream (`cls`) to the ODE-ready one: partition
# the variables, resolve the scalar parameter scope, materialize the setup-time
# geometry (clip rings / ranged clips / A_ij) and the derived index-set extents,
# then run the equation rewrites in their pinned order — setup-equation drop,
# join-gate resolution, index-set range resolution, value-invention drop,
# discrete-cadence def extraction, and the `ic` fold.
function _build_partition_and_materialize(model::Model, cls;
        template_sites::Union{Nothing,IdDict{OpExpr,OpExpr}}=nothing,
        index_sets::AbstractDict, const_arrays::AbstractDict,
        param_arrays::AbstractDict, parameter_overrides::AbstractDict,
        registered_functions::AbstractDict, vi_vars, vi_extents::AbstractDict,
        vi_maps, has_value_invention::Bool,
        # Build-time parameter-read sink (see `_PARAM_READS`): the two consumers
        # below (`_materialize_geometry_setup`, `_fold_ic_equations`) record the
        # names they resolve, which is what makes a parameter STRUCTURAL.
        param_reads::Union{Nothing,Set{String}}=nothing)
    # ---- Partition variables ----
    param_names, observed_names, state_var_names = _partition_variables(model;
        vi_vars=vi_vars, geom_setup_vars=cls.geom_setup_vars,
        geom_inline_vars=cls.geom_inline_vars,
        array_inline_vars=cls.array_inline_vars,
        folded_array_obs=cls.folded_array_obs,
        pia_operand_vars=cls.pia_operand_vars,
        const_obs_vars=cls.const_obs_vars, geom_ring_vars=cls.geom_ring_vars,
        const_arrays=const_arrays, param_arrays=param_arrays,
        discrete_vars=cls.discrete_vars)

    # ---- Scalar parameter scope (load-time constants) ----
    param_scope = _resolve_param_scope(model, param_names, parameter_overrides)

    # ---- M4: materialize intersect_polygon clip rings at setup time ----
    # Each clip is evaluated now (operands are const_arrays) into a CLOSED ring,
    # registered in phase 4 as a 2D const_array; `derived_extents` maps each
    # clip's `from_faq` key to its distinct-vertex count so the derived clip-ring
    # index set resolves to `[1, n]` for the polygon_area FAQ.
    geom_rings = Dict{String,Matrix{Float64}}()
    derived_extents = (cls.has_geometry || has_value_invention) ?
        Dict{String,Int}() : _EMPTY_DERIVED_EXTENTS
    if cls.has_geometry
        geom_rings, geom_extents =
            _materialize_geometry_rings(cls.equations, const_arrays, cls.geom_ring_vars)
        merge!(derived_extents, geom_extents)
    end
    # M4+: materialize the ranged-clip / per-pair-area / A_ij geometry into const
    # arrays (and record the per-pair clip_ring extent) BEFORE index-set ranges are
    # resolved, so the polygon_area FAQ's `clip_ring` range lowers to `[1, maxn]`.
    geom_setup_arrays = Dict{String,AbstractArray{Float64}}()
    if !isempty(cls.geom_setup_vars)
        geom_setup_arrays = _with_param_reads(param_reads) do
            _materialize_geometry_setup(cls.geom_setup_vars,
                cls.geom_defs, model, const_arrays, index_sets, derived_extents;
                vi_maps=vi_maps.maps, param_overrides=parameter_overrides,
                const_obs_arrays=cls.const_obs_arrays,
                registered_functions=registered_functions)
        end
    end
    # Value-invention derived index sets (skolem/distinct/rank) materialized via
    # the relational engine in the AbstractDict front-door (RFC §6.1 / §5.5):
    # supply each producer's distinct-set cardinality as the resolver's dense
    # extent `[1, n]`, generalizing the geometry handoff to the relational engine.
    merge!(derived_extents, Dict{String,Int}(String(k) => Int(v) for (k, v) in vi_extents))

    # Geometry-setup vars (ranged clips / per-pair area / A_ij / their bin buffers)
    # and direct clip rings are materialized at setup — drop their equations before
    # the ODE-lowering passes so their join/filter/intersect_polygon nodes never
    # reach the join-gate / index-set-range resolvers (those expect the relational/
    # value-invention vocabulary, not the setup-geometry one).
    # A polygon_intersection_area operand's const-ring equation is likewise dropped:
    # its ring is materialized into const_arrays above, so its synthetic
    # `operand = const(...)` equation must not reach the ODE-lowering passes.
    ode_equations = Equation[eq for eq in cls.equations
        if !(eq.lhs isa VarExpr && ((eq.lhs::VarExpr).name in cls.geom_ring_vars ||
                                    (eq.lhs::VarExpr).name in cls.geom_setup_vars ||
                                    (eq.lhs::VarExpr).name in cls.pia_operand_vars ||
                                    (eq.lhs::VarExpr).name in cls.const_obs_vars))]

    # ---- Resolve value-equality joins (RFC §5.3) ----
    # Rewrite each aggregate's `join` clauses into build-time `join_gates` (a
    # canonical bucket code per key-column position, or — Phase 2a — a prebuilt
    # spatial-overlap candidate set for a `join.overlap` gate) BEFORE index-set
    # ranges are resolved away — categorical members are read from the still-
    # present `{from}` references here, and a `join.overlap` gate reads its
    # envelope factor arrays from `const_arrays` (with each factor's 1-D shape
    # from `join_var_shapes`). No-op (byte-identical) for files without a join.
    join_var_shapes = Dict{String,Vector{String}}(
        String(n) => (v.shape === nothing ? String[] : Vector{String}(v.shape))
        for (n, v) in model.variables)
    equations = _resolve_join_gates(ode_equations, index_sets, vi_maps,
                                    const_arrays, join_var_shapes)
    _translate_equation_sites!(template_sites, ode_equations, equations)
    init_equations = _resolve_join_gates(model.initialization_equations,
                                         index_sets, vi_maps, const_arrays, join_var_shapes)

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
    factor_scope = Dict{String,String}()
    for (_, iset) in index_sets
        (iset isa IndexSet && iset.kind == "ragged") || continue
        for f in (iset.offsets, iset.values)
            f === nothing && continue
            fname = String(f)
            (haskey(factor_scope, fname) || haskey(model.variables, fname)) && continue
            cands = String[n for n in keys(model.variables)
                           if endswith(n, "." * fname)]
            isempty(cands) && continue
            mindepth = minimum(count(==('.'), c) for c in cands)
            best = String[c for c in cands if count(==('.'), c) == mindepth]
            length(best) == 1 && (factor_scope[fname] = best[1])
        end
    end
    let pre = equations
        equations = _resolve_index_set_ranges(equations, index_sets, derived_extents,
                                              factor_scope)
        _translate_equation_sites!(template_sites, pre, equations)
    end
    init_equations = _resolve_index_set_ranges(init_equations,
                                               index_sets, derived_extents,
                                               factor_scope)

    # ---- Drop value-invention equations from the ODE (RFC §6.1) ----
    # The skolem/distinct/rank LHS vars are materialized at setup, not integrated;
    # their defining equations (a relational aggregate RHS) must not reach the
    # numeric pipeline. Their derived index-set extents were already harvested
    # above, so the index-set ranges resolved before this filter.
    if has_value_invention
        equations = Equation[eq for eq in equations
                             if !(_vi_typed_lhs_base(eq.lhs) in vi_vars)]
        init_equations = Equation[eq for eq in init_equations
                                  if !(_vi_typed_lhs_base(eq.lhs) in vi_vars)]
    end

    # ---- Extract discrete-cadence materialize defs (RANGE-RESOLVED) + drop them ----
    # The discrete-cadence array observeds were kept through join-gate + index-set
    # range resolution so their arrayop `ranges` lower to concrete `[1, n]`. Capture
    # their resolved defining aggregates now (for the per-refresh fill kernels in
    # phase 4) and remove their equations from the ODE stream — they are
    # materialized into cache buffers, never compiled as observeds/derivatives.
    # Empty (no-op) unless the `materialize_out` sink opted in.
    discrete_defs = Dict{String,ASTExpr}()
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

    # ---- Fold `ic(var) = <initial value>` equations into u0 (esm-spec v0.8.0) ----
    # (see `_fold_ic_equations`; scoped-reference / array targets are deferred in
    # `field_ics` and folded per cell by `_fold_field_ics!` once cells are known)
    equations, eq_ics, field_ics = _with_param_reads(param_reads) do
        _fold_ic_equations(equations, model, param_scope, registered_functions)
    end

    return (; param_names, observed_names, state_var_names, param_scope,
            geom_rings, geom_setup_arrays, derived_extents,
            equations, init_equations, discrete_defs, eq_ics, field_ics)
end

# ---- Phase 3: array-cell discovery + flat state layout + u0 / parameter tuple ----
# Discover every array cell (declared shapes + `D(index(var,k))` usage), lay out
# the flat state vector (scalars first, then array cells in column-major cell
# order), fold the deferred field ics now that cells are known (mutating
# `parts.eq_ics`), and seed u0 and the scalar-parameter NamedTuple.
function _build_state_layout(model::Model, cls, parts;
        initial_conditions::AbstractDict, index_sets::AbstractDict,
        registered_functions::AbstractDict, const_arrays::AbstractDict, vi_vars,
        # Build-time parameter-read sink (see `_PARAM_READS`): the field-ic fold
        # below is the fourth build-time consumer of the parameter scope.
        param_reads::Union{Nothing,Set{String}}=nothing)
    # ---- Discover array cells from equations and initial conditions ----
    # Array variable detection: a variable is treated as an array if it has
    # an explicit non-empty shape, OR if it appears inside index(var, k...)
    # in an equation LHS. This handles both declared-shape variables and the
    # common pattern where shape=nothing but equations use D(index(var, k)). An
    # explicit empty shape (`[]`, rank-0) is scalar, not an array.
    array_var_names_declared = Set{String}(n for (n, v) in model.variables
                                           if v.type == StateVariable &&
                                              _is_array_shape(v.shape) &&
                                              !(n in vi_vars))
    # Detect array usage from equations even when shape is not declared.
    array_var_names = _detect_array_vars(parts.equations, parts.state_var_names,
                                         initial_conditions)
    union!(array_var_names, array_var_names_declared)

    # array_cells: var_name → sorted list of index-tuples (1-based)
    array_cells = _discover_array_cells(parts.equations, initial_conditions,
                                        array_var_names)
    # Equation-less declared array states still get one u0 slot per cell.
    _enumerate_declared_array_cells!(array_cells, model, index_sets,
                                     parts.derived_extents, vi_vars)

    # Scalar state variables: all state vars not treated as arrays.
    scalar_state_names = String[]
    for name in parts.state_var_names
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
    _with_param_reads(param_reads) do
        _fold_field_ics!(parts.eq_ics, parts.field_ics, array_cells, parts.param_scope,
                         registered_functions, const_arrays)
    end

    # ---- Build flat state vector: scalars first, then array cells ----
    array_cell_names = _enumerate_array_cell_names(array_cells, array_var_info)
    all_state_names = vcat(scalar_state_names, array_cell_names)
    var_map = Dict{String,Int}(name => i for (i, name) in enumerate(all_state_names))

    # ---- Initial condition vector ----
    u0 = _build_u0(model, scalar_state_names, array_cell_names,
                   initial_conditions, parts.eq_ics)

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
    # exactly as an array state's cells are (`_enumerate_array_cell_names`), and
    # is registered in `array_var_info` + `var_map` so a reader's
    # `index(obs, i…)` resolves through the ordinary array-gather path. `u0`,
    # `all_state_names` and the PUBLIC `var_map` keep only the ODE slots — the
    # buffers are build-owned scratch, never an integrator slot.
    mat_dims = Dict{String,Vector{Int}}()
    mat_cell_names = String[]
    var_map_ext = var_map
    array_var_info_ext = array_var_info
    if !isempty(cls.mat_array_vars)
        mat_defs_raw = Dict{String,ASTExpr}()
        for eq in parts.equations
            eq.lhs isa VarExpr &&
                ((eq.lhs::VarExpr).name in cls.mat_array_vars) &&
                (mat_defs_raw[(eq.lhs::VarExpr).name] = eq.rhs)
        end
        var_map_ext = copy(var_map)
        array_var_info_ext = copy(array_var_info)
        for name in sort(collect(cls.mat_array_vars))
            haskey(mat_defs_raw, name) || continue
            haskey(array_var_info_ext, name) && continue   # never shadow a state
            v = model.variables[name]
            dims = _materialized_obs_dims(mat_defs_raw[name], v.shape,
                                          index_sets, parts.derived_extents)
            (dims === nothing || isempty(dims) || any(d -> d <= 0, dims)) && continue
            # A declared shape of a different rank than the producer's output
            # would make the cell keys ambiguous — leave it inlined.
            (v.shape !== nothing && length(v.shape) != length(dims)) && continue
            mat_dims[name] = dims
            array_var_info_ext[name] = (ones(Int, length(dims)), copy(dims))
            for I in CartesianIndices(Tuple(dims))
                push!(mat_cell_names, _cell_key(name, collect(Int, Tuple(I))))
            end
        end
        n_st = length(all_state_names)
        for (i, cn) in enumerate(mat_cell_names)
            var_map_ext[cn] = n_st + i
        end
    end

    # The parameter scope handed to `_compile`, as an ORDERED map: `sym → its
    # position in `p_syms``. `p_syms` came from the already-sorted
    # `parts.param_names`, so this position is stable across builds of the same
    # document and is the SAME position the value has in the `p` NamedTuple —
    # which is the whole point. The order existed before this map; it just was
    # not exposed, so a `_NK_PARAM` node could name a parameter but not locate
    # one. (`param_map` below is this map keyed by NAME, the public form.)
    param_index = Dict{Symbol,Int}(s => i for (i, s) in enumerate(p_syms))
    param_map = Dict{String,Int}(String(s) => i for (i, s) in enumerate(p_syms))

    return (; all_state_names, var_map, u0, p,
            param_sym_set=param_index, param_map, array_var_info,
            var_map_ext, array_var_info_ext, mat_dims,
            n_total=length(all_state_names) + length(mat_cell_names))
end

# ---- Phase 4: registry + forcing buffers + derivative compile + closure ----
# Observed substitution, the merged const-array registry, the live forcing
# buffers, the (opt-in) discrete-cadence materializer, u0 seeding from
# arrayop-valued initialization equations, the per-derivative compile + CSE,
# and the final `f!` closure. Returns the full `_build_evaluator_impl` result.
function _build_compile_evaluator(model::Model, cls, parts, layout;
        registered_functions::AbstractDict, const_arrays::AbstractDict,
        const_array_boundaries::AbstractDict, param_arrays::AbstractDict,
        initial_conditions::AbstractDict, tspan, inspect, materialize_out,
        form::Symbol,
        template_sites::Union{Nothing,IdDict{OpExpr,OpExpr}}=nothing)
    u0 = layout.u0
    p = layout.p
    param_sym_set = layout.param_sym_set
    n_states = length(layout.all_state_names)
    # The layout hands back TWO maps: the ODE-only one (`var_map` — the public
    # return, and the scope the setup-time seeding evaluates in, where the
    # observed buffers do not exist yet) and the EXTENDED one that also carries
    # the factored array-observed buffer slots. Everything the per-call RHS
    # compiles against uses the extended pair.
    var_map = layout.var_map_ext
    array_var_info = layout.array_var_info_ext
    n_total = layout.n_total
    # The materialized set, narrowed to the observeds whose buffer extents
    # actually resolved (`mat_dims`); the rest stayed on the inline path.
    mat_vars = Set{String}(keys(layout.mat_dims))

    # ---- Observed substitution / derivative-equation split ----
    derivative_eqs, resolved_obs, raw_obs, mat_defs = _split_observed_and_derivatives(
        parts.equations,
        parts.observed_names, cls.geom_ring_vars, cls.geom_setup_vars,
        cls.geom_inline_vars, cls.array_inline_vars, mat_vars)

    # ---- Registered-function handlers ----
    reg_funcs = Dict{String,Any}(String(k) => v
                                 for (k, v) in registered_functions)

    # ---- Const-array registry (caller arrays + boundaries + setup geometry) ----
    const_registry = _register_const_arrays(const_arrays, const_array_boundaries,
        parts.geom_rings, parts.geom_setup_arrays, cls.pia_operand_arrays,
        cls.const_obs_arrays)

    # ---- Build observability (the `inspect` kwarg; see BuildInspection) ----
    # Copy the named build-time products into the caller's sink. Read-only with
    # respect to the build: nothing downstream consults `inspect`.
    if inspect !== nothing
        for (k, arr) in parts.geom_setup_arrays
            inspect.setup_arrays[String(k)] = Array{Float64}(arr)
        end
        for (k, arr) in const_registry
            inspect.const_arrays[String(k)] = arr
        end
        # The observed map published here is the FULLY RESOLVED one — the same
        # bytes as before this change. A factored array observed no longer sits
        # in the RHS substitution map (its readers gather its buffer), but the
        # observability surface is not the RHS: `_observed_field`
        # (pde_inline_tests.jl, esm-spec §6.6.5) evaluates an asserted array
        # observed's expression CELLWISE, off the ODE path, so every reference
        # in it must be substituted — including references between factored
        # observeds. Re-resolving the merged map restores exactly that, and only
        # when a sink asked for it.
        published = isempty(mat_defs) ? resolved_obs :
            _resolve_observed(merge(Dict{String,ASTExpr}(resolved_obs), mat_defs))
        for (k, e) in published
            inspect.observed_exprs[String(k)] = e
        end
        # ALSO publish the UN-inlined per-observed definitions, so a build-time
        # field evaluation can materialize each producer once in dependency order
        # instead of re-executing the chain per output cell (see the
        # BuildInspection docstring). `observed_exprs` above is left exactly as
        # it was, so callers that do not know about this field are unaffected.
        for (k, e) in raw_obs
            inspect.observed_defs[String(k)] = e
        end
        # Keyed by the PRODUCER id (`"emis_src_cells_faq" => 9`), exactly as the
        # build holds it. A consumer resolving a `kind:"derived"` axis follows the
        # set's `from_faq` to this map (see `_materialized_obs_scope`).
        for (k, n) in parts.derived_extents
            inspect.derived_extents[String(k)] = Int(n)
        end
        # Resolved scalar parameter values (load-time constants) so a build-time
        # cellwise re-evaluation of a parameter-dependent observed / reference
        # (§6.6.5) binds them — see `evaluate_cellwise(...; params=…)`.
        for (k, val) in parts.param_scope
            inspect.params[String(k)] = val
        end
    end

    # ---- Live forcing buffers (ess-14f.3, JL-J0) ----
    # (see `_build_pgather` for the feasibility-gate design note)
    pgather = _build_pgather(param_arrays)

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
    if materialize_out !== nothing
        _build_discrete_materializer!(materialize_out, cls.discrete_vars,
            parts.discrete_defs, resolved_obs, layout.array_var_info, layout.var_map,
            const_registry, pgather, param_sym_set, reg_funcs, p, n_states)
    end

    # ---- Evaluate arrayop-valued initialization_equations into u0 ----
    _seed_arrayop_init_u0!(u0, parts.init_equations, initial_conditions, layout.var_map,
                           layout.array_var_info, const_registry, pgather,
                           param_sym_set, reg_funcs, p)

    # ---- Scalar-observed slot plan (named prelude defs; ess-obs-slots) ----
    # Decide which scalar observeds compile as named prelude slots and which
    # stay inlined (see `_plan_observed_slots`). The SCALAR equation arms then
    # substitute only the non-slot observeds; every array path below keeps the
    # full `resolved_obs` and is byte-identical to the pre-slot build.
    obs_plan = _plan_observed_slots(derivative_eqs, raw_obs, resolved_obs,
                                    parts.observed_names)
    # Each slot def resolves through the SAME context the scalar entries use,
    # in dependency order (a def may read a state gather / const array / live
    # forcing buffer exactly as its inlined copy did).
    obs_defs = Pair{String,ASTExpr}[
        name => _resolve_indices(body, array_var_info, var_map,
                                 const_registry, pgather)
        for (name, body) in obs_plan.defs]

    # ---- Factored array-observed fill kernels (per RHS call, dependency order) ----
    # Each materialized observed compiles through the SAME array-equation cascade
    # its readers do, via a synthesized `arrayop(D(index(obs, i…))) = <body>`
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
    # plumbing is not optional even while the list is empty.
    #
    # It IS empty today, and deliberately so: `_detect_prefix_scan` fires only on
    # an equation whose RHS is a top-level `aggregate`, and a fill's RHS is the
    # GATHER `index(<def>, i…)` (see `_materialized_fill_equation` for why that
    # spelling, and what handing it the bare aggregate would reach). An observed
    # whose own body is a prefix reduction therefore keeps the triangular path —
    # exactly as it did BEFORE this change, where it was inlined into a reader
    # and the scan sat buried inside that reader's body. Measured, both ways, on
    # `S[i] = Σ_{j<=i} u[j]`: `n_scan_folds == 0` under the factored build, the
    # inlining build, and pristine pre-change `main`. What the scan path does
    # keep, unchanged, is the shape it was written for — a STATE equation that is
    # itself a prefix reduction — including in a model that also materializes
    # observeds, where the two mechanisms compose bit-for-bit.
    # `mat_levels` carries the `:inplace` shape `(scalars, _KernelSection, scans)`
    # that `_fill_obs_levels!` consumes; `mat_levels_oop` carries the same fills
    # as `(scalars, kernels, oop_plans, scans)` because the out-of-place runners
    # take the kernel and its plan separately rather than a fused callable. Only
    # the emitter actually being built is populated.
    mat_levels = Any[]
    mat_levels_oop = Any[]
    mat_scan_fold_count = 0
    if !isempty(mat_vars)
        for lvl in _materialized_obs_levels(mat_defs, mat_vars, raw_obs)
            lvl_scalars = Tuple{Int,_Node}[]
            lvl_kernels = _AccKernel[]
            lvl_scans = _ScanFold[]
            for name in lvl
                feq = _materialized_fill_equation(name, mat_defs[name],
                                                  layout.mat_dims[name])
                se, pcs, aks, sfs = _compile_derivative_equations(Equation[feq],
                    resolved_obs, array_var_info, var_map, const_registry,
                    pgather, param_sym_set, reg_funcs, n_total;
                    template_sites=template_sites)
                for (slot, ex) in se
                    push!(lvl_scalars,
                          (slot, _compile(ex, var_map, param_sym_set, reg_funcs)))
                end
                append!(lvl_scalars, pcs)
                append!(lvl_kernels, aks)
                append!(lvl_scans, sfs)
            end
            merged, _ = _merge_acc_kernel_classes(lvl_kernels)
            mat_scan_fold_count += length(lvl_scans)
            if form === :oop
                push!(mat_levels_oop,
                      (lvl_scalars, merged,
                       _OopAccPlan[_build_oop_acc_plan(K) for K in merged],
                       lvl_scans))
            else
                push!(mat_levels,
                      (lvl_scalars, _make_kernel_section(merged), lvl_scans))
            end
        end
    end

    # ---- Build per-derivative compiled-IR list ----
    # (see `_compile_derivative_equations` / `_compile_arrayop_equation!`)
    # `array_var_info` here is the EXTENDED map (`layout.array_var_info_ext`,
    # bound above): a reader's `index(<materialized observed>, i…)` must resolve
    # through the ordinary array-gather path onto the observed's buffer block.
    # `scan_folds` is the ess-scan post-pass list for the STATE equations.
    scalar_entries, percell_scalar, acc_kernels_pre, scan_folds = _compile_derivative_equations(derivative_eqs,
        resolved_obs, array_var_info, var_map, const_registry, pgather,
        param_sym_set, reg_funcs, n_states; template_sites=template_sites,
        scalar_obs_inline=obs_plan.inline)
    # States without a D(...) equation get du=0 (integrator leaves them
    # at their initial value — a common pattern for reified constants).

    # ---- Kernel-CLASS merge (oop_merge.jl), for BOTH emitters ----
    # Collapse per-cell-fragmented same-structure kernels into lane-batched
    # class kernels — value-exact (bit-identical output on every runner), and
    # a large constant-factor win on class-fragmented models (ReSEACT
    # transport 7×7×8: 4,119 → 346 kernels; the in-place RHS 2.2× faster with
    # codegen disabled, codegen source generation 3.4× faster; for the :oop
    # emitter it is the difference between an XLA trace that finishes in
    # minutes and one that runs for hours). MUST run here, before the xcse
    # gate below: xcse rewrites kernel invariant-tier defs into SCALAR-cache
    # reads (`_NK_CACHED` payloads that are no kernel's scratch), which the
    # merge signature/clone does not model — merge first, then xcse runs over
    # the (fewer) merged kernels. Bound ONCE to a fresh local (`acc_kernels`),
    # never reassigned, so every downstream closure captures it unboxed.
    # ESS_OOP_MERGE_DISABLE=1 (or its form-neutral alias
    # ESS_KERNEL_CLASS_MERGE_DISABLE=1) restores the unmerged build byte for
    # byte. The ESS_STENCIL_DISABLE per-cell reference is untouched either
    # way: its trees live on `percell_scalar`, never in the kernel list.
    acc_kernels, class_merge_diag = _merge_acc_kernel_classes(acc_kernels_pre)

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
        _cse_compile_scalar(scalar_entries, var_map, param_sym_set, reg_funcs;
                            has_pgather = !isempty(pgather), obs_defs=obs_defs)

    # ---- Cross-kernel / kernel↔prelude fn-CSE (perf plan B4; xcse.jl) ----
    # A lane-invariant fn/interp subtree appearing in several array kernels'
    # invariant tiers (and possibly in scalar equations too) collapses to ONE
    # shared scalar prelude slot; each kernel's inv def becomes a bare cache
    # read. `:inplace` only — the `:oop` emitter fills its own per-call prelude
    # vector, never the `_CSECache` the kernel-side reads consult. Runs BEFORE
    # the percell append (the ESS_STENCIL_DISABLE reference trees stay exactly
    # the `_compile` output) and BEFORE the cadence split (a hoisted
    # parameter-only def still joins the const tier). ESS_XCSE_DISABLE=1
    # restores the pre-B4 build byte for byte.
    xcse_diag = if form === :inplace && !_xcse_disabled()
        _share_kernel_invariants!(rhs_list, scalar_prelude, scalar_cache,
                                  acc_kernels)
    else
        _XCSE_NONE_DIAG
    end

    # ---- Forced per-cell reference (ESS_STENCIL_DISABLE=1) ----
    # The disabled fallback's compiled per-cell nodes join the scalar list —
    # each cell evaluated by the plain scalar walker `_eval_node`, with no merge
    # machinery of any kind between it and the equation: the maximally
    # independent oracle the acc≡per-cell differential tests compare against.
    # Empty on every default build. Appended AFTER the CSE pass so the
    # reference trees are exactly the `_compile` output, untouched by sharing.
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

    # ---- Default tspan ----
    tspan_default = _pick_tspan(tspan, model)

    # ---- Closure ----
    # Two emitters over the SAME compiled IR (tree_walk/oop.jl explains why both
    # exist): `:inplace` is the zero-alloc Float64 production RHS; `:oop` is the
    # eltype-generic `f(u, p, t) → du` that ForwardDiff/Enzyme can differentiate.
    f! = if form === :inplace
        # The factored array-observed fills wrap the state RHS: `f!` copies `u`
        # into the extended value vector, fills every observed buffer in
        # dependency order, and hands the extended vector to the state RHS as its
        # `u`. With nothing materialized the wrapper is not applied at all, so the
        # closure (and its zero-allocation property) is byte-identical.
        # The inner state RHS keeps its own `scan_folds` (the prefix reductions
        # among the STATE equations); each fill level carries its own.
        _make_rhs_with_obs_buffers(
            _make_rhs(rhs_list, scalar_prelude, scalar_cache, acc_kernels,
                      const_slots, time_slots, dyn_slots, scan_folds),
            _ObsExtVec(n_total), n_states, Tuple(mat_levels))
    elseif form === :oop
        # `pgather` (raw `param_arrays` buffers + discrete-cadence caches) rides
        # along so the OOP RHS can expose its live forcing buffers as ARGUMENTS
        # (`_OopRHS` / `rhs_with_buffers`, B2) — the traceable binding.
        _make_rhs_oop(rhs_list, scalar_prelude, acc_kernels, n_states, pgather,
                      scan_folds, Tuple(mat_levels_oop), n_total)
    else
        throw(TreeWalkError("E_TREEWALK_UNKNOWN_FORM",
            "build_evaluator: `form` must be :inplace or :oop, got :$(form)"))
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
    # The `_VecNode`-overlay fields (`n_vec_kernels`, `template_node_count`, the
    # `n_invariant_*` and `n_vec_*` triples) are RETAINED AS HARD ZEROS: the
    # overlay was deleted when the access-kernel IR became the only array
    # runtime, and a large body of tests (and downstream tooling) asserts
    # `n_vec_kernels == 0` — meaning "the unified IR owns every array
    # equation" — which is now true by construction.
    # `n_acc_kernels` (and the slot sums below) count the POST-class-merge
    # list — the kernels the emitted RHS actually carries — deliberately: the
    # N-independence property still holds (a class is a structural fact of the
    # document, not of the grid), and the pre-merge count is available as
    # `n_classmerge_in`. A merged class folds varying inv defs into the cell
    # tier (value-identical ones keep a real inv tier), so `n_acc_inv_slots`
    # can shrink relative to a disabled-merge build.
    diag = (; n_vec_kernels = 0,
              # ess-scan: forward cumulative (prefix) reductions rewritten into a
              # term pass + an O(N) accumulation (scan.jl). Zero on every model
              # without one; the per-equation cascade tally records `:scan`.
              # Counts BOTH the state equations' folds and those inside the
              # factored array-observed fills — a prefix reduction that defines a
              # materialized observed is the same rewrite in the same position,
              # just over the observed's buffer block instead of the state.
              n_scan_folds = length(scan_folds) + mat_scan_fold_count,
              n_acc_kernels = length(acc_kernels),
              n_acc_cse_slots = sum(length(K.cse.recipes) for K in acc_kernels; init=0),
              n_acc_inv_slots = sum(length(K.cse.inv_recipes) for K in acc_kernels; init=0),
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
              template_node_count = 0,
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
              n_invariant_slots = 0,
              n_invariant_shared = 0,
              n_invariant_scalar_shared = 0,
              # Cross-kernel fn-CSE (plan B4; xcse.jl): shared prelude slots
              # minted by the pass / kernel inv defs rewritten to shared-slot
              # reads / scalar RHS sites rewritten onto new shared slots.
              n_xcse_slots = xcse_diag.n_xcse_slots,
              n_xcse_kernel_shared = xcse_diag.n_xcse_kernel_shared,
              n_xcse_scalar_shared = xcse_diag.n_xcse_scalar_shared,
              n_vec_slots = 0,
              n_vec_shared = 0,
              n_vec_prelude_nodes = 0,
              n_const_slots = length(const_slots),
              n_time_slots = length(time_slots),
              n_dynamic_slots = length(dyn_slots),
              # Factored array observeds (this change): how many array observeds
              # were cut out of their readers into per-call buffers, how many
              # buffer cells that is, and the dependency depth the fills run in.
              n_mat_array_obs = length(mat_vars),
              n_mat_array_cells = n_total - n_states,
              n_mat_levels = length(mat_levels),
              # Parameter NAME → position in a vector `p` — the build's own copy
              # of what the public `param_map(p)` recomputes from the NamedTuple.
              # Here so an internal consumer never has to re-derive the order.
              param_map = layout.param_map)

    # The PUBLIC map is the ODE layout only: the factored array-observed buffer
    # slots are build-owned scratch above `length(u0)`, not integrator slots, and
    # every caller (solution indexing, cellwise evaluation, the conformance
    # runners) reads `var_map` as "state name → `u` index".
    return f!, u0, p, tspan_default, layout.var_map, diag
end

# Build-scoped lane-table intern pool (acc_merge.jl): every `_Interp*Spec` mint
# and every lane-spec `.specs` collection inside this build canonicalizes
# content-equal interp tables to ONE object. The pool is installed here — the
# single entry every build path funnels through — and torn down in `finally`,
# save/restore so a nested build cannot clobber an outer one's pool. With
# `ESS_LANE_INTERN_DISABLE=1` the pool stays `nothing` and the build is
# byte-for-byte today's un-interned build (the differential oracle).
function _build_evaluator_impl(model::Model; kwargs...)
    prev = _LANE_INTERN_POOL[]
    _LANE_INTERN_POOL[] = _lane_intern_disabled() ? nothing :
                          Dict{_LaneInternKey,Any}()
    try
        return _build_evaluator_impl_inner(model; kwargs...)
    finally
        _LANE_INTERN_POOL[] = prev
    end
end

function _build_evaluator_impl_inner(model::Model;
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
                         _vi_maps=_EMPTY_VI_MAPS,
                         # Build observability sink (see BuildInspection): when
                         # non-nothing, filled with the materialized setup-time
                         # geometry arrays, the const-array registry, and the
                         # resolved observed substitution map. Never changes the
                         # build itself.
                         inspect::Union{Nothing,BuildInspection}=nothing,
                         # Discrete-cadence materialization sink (opt-in; see
                         # DiscreteMaterializer). When non-nothing, a state-free
                         # live-field array observed is cut out of the per-step RHS
                         # into a cache buffer filled once per refresh, and the sink
                         # is populated with the caches + `materialize!` closure. When
                         # nothing (every existing caller), such fields stay inlined —
                         # the pre-cut behavior, byte-identical.
                         materialize_out::Union{Nothing,DiscreteMaterializer}=nothing,
                         # Internal: the build-time parameter-READ set (see
                         # `_PARAM_READS`). The AbstractDict front-door records
                         # the two consumers that run BEFORE this entry
                         # (`_derive_binning_coords`, `materialize_value_invention`)
                         # and hands the same sink down, so the classification
                         # covers every build-time consumer. A direct typed call
                         # starts a fresh one.
                         _param_reads::Union{Nothing,Set{String}}=nothing,
                         # Internal: sink for the parameter PARTITION (name →
                         # `:numeric` / `:structural` / `:const_folded` /
                         # `:forcing`; see `_classify_parameters`). `prepare`
                         # passes one and carries it on the `PreparedModel`, so
                         # `parameter_classes(prep)` needs no sixth return value
                         # — the same reasoning as `param_map`.
                         _param_classes::Union{Nothing,AbstractDict}=nothing,
                         # Which RHS to emit from the compiled IR (tree_walk/oop.jl):
                         # `:inplace` → the zero-alloc Float64 `f!(du, u, p, t)`;
                         # `:oop` → the eltype-generic `f(u, p, t) → du` that
                         # ForwardDiff/Enzyme can differentiate. Same IR, same
                         # evaluation order, so a Float64 `:oop` run is bit-identical.
                         form::Symbol=:inplace,
                         # Surviving `apply_expression_template` registry for the
                         # selected model (esm-spec §9.6.4 Option B; name → raw
                         # decl). Supplied by the `EsmFile` front-door when the
                         # document carries references; `nothing` everywhere else.
                         _template_reg=nothing)
    # Runtime contraction-loop var registry (ess-runtime-contraction) is a
    # build-scoped resolve→compile side channel; clear any stale entries from a
    # prior build so it never accumulates across builds. Loop-var names are
    # globally unique, so this only drops dead entries.
    empty!(_LOOPVAR_REFS)
    empty!(_STATE_SLOT_TABLES)   # build-scoped state-gather slot tables (ess-runtime-contraction)
    # ---- Compile-once template tier: expand references at the entry, keeping
    # the SITES (RFC out-of-line-expression-templates §7.7). Every phase and
    # every fallback path below sees exactly the fused expanded tree Option A
    # produced — variable discovery, layout, validation, and the per-cell /
    # symbolic paths are byte-identical to a pre-expanded build. The recorded
    # expansion roots are consumed ONLY by the affine stencil build, which
    # compiles each (use site, region class) body once and calls it as a
    # sub-kernel. Expansion works on a deep copy: the caller's typed model must
    # keep its references (`serialize_esm_file` emits them verbatim — R1).
    _template_sites = nothing
    if _template_reg !== nothing
        model = deepcopy(model)
        sites = IdDict{OpExpr,OpExpr}()
        _expand_model_refs!(model, _template_reg; sites=sites)
        isempty(sites) || (_template_sites = sites)
    elseif _model_has_surviving_refs(model)
        # A surviving reference with no registry in reach would compile into an
        # opaque op node and only fail at RHS evaluation time — fail loudly at
        # build time instead. Reached only by callers that hand a
        # reference-preserving `Model` directly to the evaluator without its
        # document's `expression_templates`; every document front-door threads
        # the registry.
        throw(TreeWalkError("E_TREEWALK_UNRESOLVED_TEMPLATE_REF",
            "model carries apply_expression_template references but no " *
            "expression_templates registry reached the build; construct via " *
            "an EsmFile/document front-door (esm-spec §9.6.4 Option B)"))
    end
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
    # audits/intern_preaudit_2026-07-19.md). `ESS_INTERN_DISABLE=1` skips the
    # pass, restoring the pre-interning build exactly.
    if !_intern_disabled()
        ictx = _InternCtx()
        model = _intern_model(model, ictx)
        if _template_sites !== nothing
            translated = IdDict{OpExpr,OpExpr}()
            for (root, ap) in _template_sites
                nr = get(ictx.memo, root, root)
                translated[nr] = ap
            end
            _template_sites = translated
        end
    end
    _has_value_invention = !isempty(_vi_vars)
    # ---- Caller-key canonicalization (esm-spec §6.6) ----
    # A spec-spelled LOCAL override key (`pert_amp`) is rewritten onto the
    # flattening-qualified parameter name the build resolves (`M.pert_amp`)
    # BEFORE any consumer reads it, so the same map binds the parameter
    # NamedTuple, the coordinate-expression `ic` seed, the setup env, and
    # `inspect.params`. Idempotent — the AbstractDict front-door normalizes
    # too, and a document whose parameters are already bare is unchanged.
    parameter_overrides = _normalize_param_override_keys(model, parameter_overrides)
    # ---- Phase 1: equation pre-lowering + build-owned variable classification ----
    cls = _build_lower_and_classify(model;
        const_arrays=const_arrays, param_arrays=param_arrays, vi_vars=_vi_vars,
        has_value_invention=_has_value_invention, materialize_out=materialize_out,
        form=form)

    # The build-time parameter-read sink: continued from the front door (which
    # already recorded binning-coordinate derivation + value invention) or fresh.
    param_reads = _param_reads === nothing ? Set{String}() : _param_reads

    # ---- Phase 2: ODE partition + setup materialization + equation rewrites ----
    parts = _build_partition_and_materialize(model, cls;
        template_sites=_template_sites,
        index_sets=index_sets, const_arrays=const_arrays,
        param_arrays=param_arrays, parameter_overrides=parameter_overrides,
        registered_functions=registered_functions, vi_vars=_vi_vars,
        vi_extents=_vi_extents, vi_maps=_vi_maps,
        has_value_invention=_has_value_invention, param_reads=param_reads)

    # ---- Phase 3: array-cell discovery + flat state layout + u0/p ----
    layout = _build_state_layout(model, cls, parts;
        initial_conditions=initial_conditions, index_sets=index_sets,
        registered_functions=registered_functions, const_arrays=const_arrays,
        vi_vars=_vi_vars, param_reads=param_reads)

    # ---- The parameter partition (differentiability plan §3 Phase 5) ----
    # Every build-time consumer has now run, so the read set is complete.
    # Published to whichever sinks the caller supplied; never changes the build.
    if _param_classes !== nothing || inspect !== nothing
        classes = _classify_parameters(model, parts.param_names, param_reads,
                                       const_arrays, param_arrays)
        if _param_classes !== nothing
            for (k, v) in classes
                _param_classes[k] = v
            end
        end
        if inspect !== nothing
            for (k, v) in classes
                inspect.param_classes[k] = v
            end
        end
    end

    # ---- Phase 4: registry + forcing buffers + derivative compile + closure ----
    return _build_compile_evaluator(model, cls, parts, layout;
        registered_functions=registered_functions, const_arrays=const_arrays,
        const_array_boundaries=const_array_boundaries, param_arrays=param_arrays,
        initial_conditions=initial_conditions, tspan=tspan, inspect=inspect,
        materialize_out=materialize_out, form=form,
        template_sites=_template_sites)
end

# ---- Stage: per-derivative compiled-IR list ----
# Each scalar entry is `(state_index, resolved-RHS-expr)`. The RHS is inlined
# with observed variables and index ops are resolved to flat-slot references
# here; compilation to the compact `_Node` form is deferred to the caller's
# single batched `_cse_compile_scalar` pass, so common subexpressions are
# eliminated across equations as well as within one RHS (ess-r7h). Array
# (`arrayop`) derivative equations compile to whole-array access kernels
# instead of N per-cell scalar nodes — see `_compile_arrayop_equation!`.
# `percell_scalar` carries the ESS_STENCIL_DISABLE=1 reference's compiled
# per-cell nodes (empty on every default build); the caller appends them to
# `rhs_list` so they evaluate through the plain scalar walker — the maximally
# independent differential oracle. Returns
# `(scalar_entries, percell_scalar, acc_kernels)`.
function _compile_derivative_equations(derivative_eqs::Vector{Equation},
        resolved_obs::Dict{String,ASTExpr}, array_var_info,
        var_map::Dict{String,Int}, const_registry::AbstractDict,
        pgather::AbstractDict, param_sym_set, reg_funcs, n_states::Int;
        template_sites::Union{Nothing,IdDict{OpExpr,OpExpr}}=nothing,
        # SCALAR-arm substitution map (ess-obs-slots): `resolved_obs` minus the
        # observeds compiled as named prelude slots, so a slot reference stays a
        # bare `VarExpr` for `_compile_cse` to lower onto its slot. `nothing`
        # (no slots) ⇔ the full map — byte-identical to the pre-slot build. The
        # ARRAY (`arrayop`) arm always inlines the FULL map.
        scalar_obs_inline::Union{Nothing,Dict{String,ASTExpr}}=nothing)
    scalar_inline = scalar_obs_inline === nothing ? resolved_obs : scalar_obs_inline
    scalar_entries = Tuple{Int,ASTExpr}[]
    percell_scalar = Tuple{Int,_Node}[]
    acc_kernels = _AccKernel[]
    scan_folds = _ScanFold[]           # ess-scan post-passes (scan.jl); usually empty
    covered = falses(n_states)
    # A3: ONE cross-equation store for this build's whole equation loop — the
    # compile-once variant / bound-body caches and the shared obs-inline memo
    # move from per-equation to per-build (sound because every compile input
    # threaded below is the same object for every equation; see the _XEqStore
    # note in stencil.jl). `ESS_XEQ_VARIANT_DISABLE=1` restores the
    # per-equation caches exactly.
    xeq = _xeq_disabled() ? nothing : _XEqStore()
    # Cross-equation direct class emission (acc_merge.jl,
    # ESS_CROSS_EQ_CLASS_EMIT_DISABLE): pool every per-cell equation's cell
    # entries here and run the scalarizer-level class emitter ONCE, above the
    # equation loop, so structurally identical cells arising in DIFFERENT
    # equations share a class kernel directly — no post-hoc repair needed.
    # `nothing` (the kill switch, or per-equation direct emission itself off)
    # keeps the per-equation `_acc_from_cell_entries` call byte for byte.
    pooled_cells = _cross_eq_class_emit_enabled() ? Tuple{Int,_Node}[] : nothing

    for eq in derivative_eqs
        if _is_scalar_D_lhs(eq.lhs)
            # D(scalar_var) = expr
            state_name = (eq.lhs::OpExpr).args[1]::VarExpr
            idx = get(var_map, state_name.name, 0)
            idx == 0 && throw(TreeWalkError("E_TREEWALK_UNKNOWN_STATE", state_name.name))
            covered[idx] &&
                throw(TreeWalkError("E_TREEWALK_DUPLICATE_DERIVATIVE", state_name.name))
            covered[idx] = true
            rhs = isempty(scalar_inline) ? eq.rhs :
                  _sub_preserving(eq.rhs, scalar_inline)
            rhs_r = _resolve_indices(rhs, array_var_info, var_map, const_registry, pgather)
            push!(scalar_entries, (idx, rhs_r))

        elseif _is_indexed_D_lhs(eq.lhs)
            # D(index(var, k...)) = expr  — indexed scalar derivative
            lhs_op = eq.lhs::OpExpr
            inner  = lhs_op.args[1]::OpExpr   # the index node
            var_expr = inner.args[1]
            var_expr isa VarExpr ||
                throw(TreeWalkError("E_TREEWALK_UNSUPPORTED_LHS",
                                    "index first arg must be a variable name"))
            concrete_idxs = [_eval_const_int(a, _EMPTY_IDX_ENV)
                             for a in inner.args[2:end]]
            cname = _cell_key(var_expr.name, concrete_idxs)
            idx = get(var_map, cname, 0)
            idx == 0 && throw(TreeWalkError("E_TREEWALK_UNKNOWN_STATE", cname))
            covered[idx] &&
                throw(TreeWalkError("E_TREEWALK_DUPLICATE_DERIVATIVE", cname))
            covered[idx] = true
            rhs = isempty(scalar_inline) ? eq.rhs :
                  _sub_preserving(eq.rhs, scalar_inline)
            rhs_r = _resolve_indices(rhs, array_var_info, var_map, const_registry, pgather)
            push!(scalar_entries, (idx, rhs_r))

        elseif _is_arrayop_D_lhs(eq.lhs)
            _compile_arrayop_equation!(percell_scalar, acc_kernels, scan_folds, covered, eq, resolved_obs,
                                       array_var_info, var_map, const_registry,
                                       pgather, param_sym_set, reg_funcs;
                                       template_sites=template_sites, xeq=xeq,
                                       pooled_cells=pooled_cells)
        end
    end
    # The pooled scalarizer-level emitter: one grouping over EVERY per-cell
    # equation's cells. Same-signature cells merge into one class kernel no
    # matter which equation minted them; a group's lanes keep entry order
    # (equation order, cell order within an equation), so the build stays
    # deterministic. Empty whenever no equation took the per-cell path.
    pooled_cells === nothing || isempty(pooled_cells) ||
        append!(acc_kernels, _acc_from_cell_entries(pooled_cells))
    return scalar_entries, percell_scalar, acc_kernels, scan_folds
end

# ---- Stage: one arrayop derivative equation → whole-array kernels ----
# `arrayop(expr=D(index(var, ...)), output_idx=[...], ranges={...}) = rhs_arrayop(...)`
# Expand by iterating the Cartesian product of output_ranges.
# Per-cell compiled nodes are collected and then merged into whole-array
# kernels (ess-dhq) rather than pushed individually into `rhs_list`; the
# per-cell build logic (ghost cells, const-array inlining, joins/filters,
# variable-valence bounds) is unchanged. Appends to `acc_kernels` and marks
# `covered` for every cell it owns. Two-branch dispatch: the symbolic-stencil
# fast path when it applies, else the per-cell fallback
# (`_compile_arrayop_percell!`).
# (`acc_kernels` is a `Vector{_AccKernel}`; the annotation is omitted because
# `_AccKernel` is defined in access_kernel.jl, included after this build section.)

# ess-affine: unroll a CONSTANT-bound contraction (aggregate reduction) into a
# plain ⊕-fold AST so the existing affine box processor can lower it — no runtime
# reduce, no per-cell loop. Output indices stay SYMBOLIC (one fold template shared
# across every output cell); only the contracted indices are expanded, through the
# SAME `_foreach_aggregate_term` core the per-cell path uses, so term order and the
# filter `ifelse`-guard are byte-identical. The fold is seeded with the 0̄ identity
# FIRST — matching `_eval_contraction`'s in-place fold exactly (signed-zero `+`, the
# min/max identities) — so the lowered `+`/`min`/`max`/`*` op is bit-identical.
#
# Caller guarantees every contracted bound is constant (`contract_const[d] !==
# nothing`) and there are no join gates (a join can drop terms per output cell,
# which would break the shared template). A filter is fine: it references the
# contracted (now concrete) and/or output (still symbolic) indices and lowers to a
# runtime `ifelse` guard the box processor verifies affine.
function _unrolled_contraction_body(rhs_body::ASTExpr, contract_names::Vector{String},
        contract_const, filt, oplus::String, zerobar::Float64)
    iters = Vector{Int}[c::Vector{Int} for c in contract_const]
    terms = ASTExpr[]
    _foreach_aggregate_term(rhs_body, contract_names, iters, nothing, filt, zerobar,
                            nothing) do term
        push!(terms, term)
    end
    isempty(terms) && return NumExpr(zerobar)            # empty ⊕-reduction → 0̄ (§5.1)
    return OpExpr(oplus, ASTExpr[NumExpr(zerobar); terms])
end

# ess-scan: recognize a CUMULATIVE (prefix) reduction — an aggregate whose
# filter admits the monotone window `j ⋚ i` against one output index — so the
# equation can be evaluated as a term pass plus an O(N) accumulation instead of
# the O(N²) guarded fold `_unrolled_contraction_body` would emit. See scan.jl
# for the rewrite, the bit-exactness argument, and why forward-only.
#
# Returns `(axis, inclusive, j_name, term_iters)` — `axis` the POSITION of the
# scanned symbol in `idx_names`, `term_iters` the range vector the TERM build
# must run over (`nothing` ⇒ `range_iters` unchanged; see the STAGGERED case
# below) — or `nothing` for anything that is not exactly this shape. Every
# condition below is load-bearing:
#
#   * one contracted symbol, constant-bound: a second contraction or a ragged
#     bound means the admitted set is not a simple prefix of one axis;
#   * no join gates: a join can drop terms per output cell, so consecutive
#     cells would no longer share a prefix;
#   * the filter is EXACTLY one comparison between the contracted symbol and an
#     output symbol — a conjunction, a shifted bound (`j <= i-1`) or a compare
#     against anything else is not this pattern (and `j <= i-1` is just the
#     strict form, which the caller can already spell as `<`);
#   * the ranges COINCIDE, or the contracted range is the output range minus
#     its last cell (see `_scan_term_iters`);
#   * the body does not mention the scanned OUTPUT symbol. This is the
#     condition that makes the rewrite sound rather than merely faster: if the
#     term at `j` depends on `i` (`u[j] * w[i]`, `u[i-j]`), then consecutive
#     cells sum DIFFERENT terms and share no partial result at all.
function _detect_prefix_scan(idx_names::Vector{String}, range_iters,
        contract_names::Vector{String}, contract_const, agg_gates, agg_filter,
        rhs_body::ASTExpr)
    agg_gates === nothing || return nothing
    length(contract_names) == 1 || return nothing
    citer = contract_const[1]
    citer === nothing && return nothing
    agg_filter isa OpExpr || return nothing
    f = agg_filter::OpExpr
    length(f.args) == 2 || return nothing
    # `j <= i` and its mirror `i >= j` are the SAME forward scan; `j >= i` is a
    # reverse scan and is declined by the `j_side` check below.
    local j_side::ASTExpr, i_side::ASTExpr, inclusive::Bool
    if f.op == "<=" || f.op == "<"
        j_side, i_side, inclusive = f.args[1], f.args[2], f.op == "<="
    elseif f.op == ">=" || f.op == ">"
        j_side, i_side, inclusive = f.args[2], f.args[1], f.op == ">="
    else
        return nothing
    end
    (j_side isa VarExpr && i_side isa VarExpr) || return nothing
    (j_side::VarExpr).name == contract_names[1] || return nothing
    i_name = (i_side::VarExpr).name
    axis = findfirst(isequal(i_name), idx_names)
    axis === nothing && return nothing
    term_iters = _scan_term_iters(range_iters, axis, citer, inclusive)
    term_iters === :decline && return nothing
    # `_referenced_var_names` routes through the generated field walk, so a
    # reference buried in a nested aggregate's body/filter/ranges counts.
    i_name in _referenced_var_names(rhs_body) && return nothing
    return (axis::Int, inclusive, contract_names[1], term_iters)
end

# Which axis do the TERMS live on? Two shapes are admitted, and they are the
# same recurrence — `out[i] = out[i-1] ⊕ term[i-1]` for the strict window,
# `out[i] = out[i-1] ⊕ term[i]` for the inclusive one — differing only in how
# many output cells that recurrence has to fill:
#
#   SAME-RANGE (`nothing`). Output and terms share the axis, which is the only
#   shape a scan could take before this. The term build runs over the output
#   range verbatim.
#
#   STAGGERED (a modified range vector). The output is the axis's NODES and the
#   terms its CENTRES — one fewer — which is how a cumulative flux is spelled on
#   a staggered grid: `Mz[ke] = -Σ_{k < ke}(…)` over `lev_nodes` contracting
#   `lev` (ReSEACT's diagnosed vertical air-mass flux). Admitted ONLY for the
#   STRICT window, and only when the contracted range is exactly the output
#   range minus its LAST cell, because that is precisely the condition under
#   which `{k ∈ terms : k < i}` equals `{k ∈ terms : k < i-1} ∪ {i-1}` for every
#   output cell — i.e. the same prefix recurrence, run one step further. The
#   INCLUSIVE window is declined: `out[i] = ⊕_{k <= i}` over a longer output
#   axis would need a term at the last node, which does not exist.
#
#   The last output node is then left UNCOVERED by the term build and untouched
#   by the term kernels. That is safe by inspection of `_scan_lanes!` /
#   `_scan_lanes_oop` (scan.jl): the strict fold WRITES `du[s] = acc` at every
#   cell and only reads the slot into a `term` it accumulates into an `acc` that
#   the loop then discards — so whatever the slot held on entry (0̄ from `du`
#   zeroing, or a stale observed-buffer value) cannot reach an output. The fold
#   itself is untouched by this change, which is what keeps scan.jl's
#   bit-exactness argument intact.
#
# See through a materialized observed's IDENTITY GATHER to the CONTRACTING
# producer underneath.
#
# `_materialized_fill_equation` synthesizes every array-observed fill as
# `index(<def>, i…)` rather than handing over the bare producer, so the fill
# lowers through the identical, already-exercised path every reader used after
# inlining. That is the right default and it stays. But `_compile_arrayop_equation!`
# detects a contraction by testing `rhs.op == "aggregate"` — it sees `index`,
# leaves `contract_names` empty, and NONE of the contraction machinery runs:
# not `_detect_prefix_scan`, not `_unrolled_contraction_body`, not the runtime
# contraction loop. The affine build is then handed `index(<contracting
# aggregate>, i…)` directly, which `_stencilize_indexed` cannot model
# ("index(aggregate) with contracted index"), so the whole equation lands on the
# per-cell tier at O(#cells) IR. ReSEACT's `Transport3D.Mz` (a staggered prefix
# scan, ~90% of that model's build cost) and its column integrals `divh_col` /
# `dp_col` all declined here rather than at any tier's own guard.
#
# WHY THIS IS NOW SAFE FOR MORE THAN A SCAN. This unwrap was originally admitted
# for prefix scans ALONE, and the exception was justified by a hazard downstream:
# `_derive_lane_repl` (stencil_affine.jl) used to decide a const lane was
# loop-invariant by comparing its VALUES at the box CORNERS, so a const gather
# that agreed at the corners and differed inside — a regrid weight column
# (0, 0.5, 0) — folded to a literal and silently zeroed the interior cell. A scan
# never reaches that fold (it lowers as an elementwise term body plus an O(N)
# accumulation), which is what made the narrow exception sound while the general
# relaxation was not.
#
# That hazard is GONE: `_derive_lane_repl` no longer samples values at all. It
# derives invariance STRUCTURALLY from the resolved linear INDEX — an all-zero
# stride vector over the box — and its remaining corner evaluations only pin an
# affine map that is affine by construction. The fold "cannot be fooled by
# adversarial data", so the reason to withhold the unwrap from non-scan
# producers no longer exists.
#
# STILL DELIBERATELY NARROW: the bare form is adopted only when it UNLOCKS
# something — i.e. only when the producer actually contracts. A non-contracting
# aggregate lowers identically either way, so it keeps the gather form and the
# default above governs it unchanged. Beyond that, the contracted bounds must all
# be constant integer ranges and there must be no join gate, which are exactly
# the preconditions `_unrolled_contraction_body` states for a shared fold
# template; anything else would take the per-cell path from the bare form too,
# so there would be nothing to gain and a lowering to change.
#
# Returns the bare producer when every guard holds, else `rhs` unchanged.
function _unwrap_identity_gather(rhs::ASTExpr, idx_names::Vector{String},
                                 ranges_dict)
    rhs isa OpExpr || return rhs
    g = rhs::OpExpr
    g.op == "index" || return rhs
    nd = length(idx_names)
    length(g.args) == nd + 1 || return rhs
    prod = g.args[1]
    (prod isa OpExpr && _is_aggregate_op((prod::OpExpr).op)) || return rhs
    a = prod::OpExpr
    a.expr_body === nothing && return rhs
    aranges = a.ranges
    aranges === nothing && return rhs
    # The gather must be the IDENTITY one the fill synthesizer emits — this
    # equation's own loop symbols, in order. Anything else is a real reindex.
    for d in 1:nd
        v = g.args[d + 1]
        (v isa VarExpr && (v::VarExpr).name == idx_names[d]) || return rhs
    end
    aout = _output_idx_strings(a)
    length(aout) == nd || return rhs
    # Rename the producer's own output symbols onto this equation's loops. A loop
    # name colliding with one of the producer's CONTRACTED symbols would capture
    # it, so decline rather than rename into a capture.
    contracted = _contracted_index_names(aranges, aout)
    any(n -> n in contracted, idx_names) && return rhs
    ren = Dict{String,ASTExpr}()
    renmap = Dict{String,String}()
    for d in 1:nd
        aout[d] == idx_names[d] && continue
        ren[aout[d]] = VarExpr(idx_names[d])
        renmap[aout[d]] = idx_names[d]
    end
    newranges = Dict{String,Any}()
    for (k, v) in aranges
        newranges[get(renmap, k, k)] = v
    end
    bare = reconstruct(a;
        output_idx = Any[n for n in idx_names],
        ranges = newranges,
        # `a.filter` is `nothing` for a plain (unfiltered) reduction — a shape
        # this unwrap now admits, where it once took scans only.
        filter = (a.filter === nothing || isempty(ren)) ? a.filter :
                 _sub_preserving(a.filter, ren),
        expr_body = isempty(ren) ? a.expr_body : _sub_preserving(a.expr_body, ren))
    # Everything below mirrors what `_compile_arrayop_equation!` would derive
    # from `bare`, so each detector sees exactly what it will see later.
    cnames = _contracted_index_names(newranges, idx_names)
    # No contraction ⇒ the gather form already lowers identically. Keep it.
    isempty(cnames) && return rhs
    # Every contracted bound must be a constant integer range: that is the
    # precondition BOTH the prefix-scan detector and the unrolled fold state, and
    # a variable-valence bound would take the per-cell path from either form.
    cspecs = [collect(newranges[n]) for n in cnames]
    all(_is_const_int_range, cspecs) || return rhs
    all(n -> haskey(ranges_dict, n), idx_names) || return rhs
    range_iters = [collect(_expand_int_range(ranges_dict[n])) for n in idx_names]
    cconst = Union{Vector{Int},Nothing}[collect(_expand_int_range(s)) for s in cspecs]
    # A forward prefix scan: the O(N) term-plus-accumulation tier (scan.jl).
    if length(cnames) == 1 &&
       _detect_prefix_scan(idx_names, range_iters, cnames, cconst,
                           bare.join_gates, bare.filter,
                           _extract_arrayop_body(bare)) !== nothing
        return bare
    end
    # Otherwise the ordinary contraction tiers. A join gate can drop terms per
    # output cell, which breaks the shared fold template `_unrolled_contraction_body`
    # builds — decline, exactly as that function's own contract requires.
    bare.join_gates === nothing || return rhs
    return bare
end

# Returns `nothing` (same-range), a term range vector (staggered), or `:decline`.
function _scan_term_iters(range_iters, axis::Int, citer, inclusive::Bool)
    out = collect(range_iters[axis])
    out == citer && return nothing
    (!inclusive && length(citer) == length(out) - 1 &&
     @views(out[1:end-1]) == citer) || return :decline
    term_iters = copy(range_iters)
    term_iters[axis] = citer
    return term_iters
end

# Resolve the output slots a prefix-scan equation owns, grouped into lanes
# along the scanned axis (see `_ScanFold`). One lane per combination of the
# NON-scanned output indices; within a lane the slots ascend.
#
# Slots come from the same `lhs_body` → `_cell_key` → `var_map` path the
# per-cell build uses (`_compile_arrayop_percell!`), deliberately: the state
# ordering is a derived fact, not a convention, and this must not re-derive it.
function _build_scan_fold(axis::Int, inclusive::Bool, idx_names::Vector{String},
        range_iters, lhs_body::OpExpr, var_map::Dict{String,Int},
        oplus::String, zerobar::Float64)
    nd = length(idx_names)
    scan_range = collect(range_iters[axis])
    len = length(scan_range)
    # Unreachable — `_try_affine_stencil` already refused an empty range before
    # the caller got here — but a `nothing` return would leave the term kernels
    # in place with no fold behind them, which is a WRONG ANSWER rather than a
    # slow one. Fail loudly instead.
    len >= 1 || throw(TreeWalkError("E_TREEWALK_SCAN_EMPTY_RANGE",
        "prefix scan over an empty range on index '$(idx_names[axis])'"))
    # Pin the scanned axis to a single placeholder so the product enumerates
    # LANES; the scan coordinate is substituted in the inner loop.
    outer_iters = Vector{Vector{Int}}(undef, nd)
    for d in 1:nd
        outer_iters[d] = d == axis ? Int[first(range_iters[d])] :
                                     collect(range_iters[d])
    end
    slots = Int[]
    sizehint!(slots, len * prod(length(it) for it in outer_iters; init=1))
    idx_exprs = Dict{String,ASTExpr}()
    for outer in Iterators.product(outer_iters...)
        for s in scan_range
            for d in 1:nd
                idx_exprs[idx_names[d]] = IntExpr(Int64(d == axis ? s : outer[d]))
            end
            sub_lhs = _sub_preserving(lhs_body, idx_exprs)
            (sub_lhs isa OpExpr && (sub_lhs::OpExpr).op == "D") ||
                throw(TreeWalkError("E_TREEWALK_ARRAYOP_MALFORMED_LHS",
                                    "expected D(index(...)) in arrayop body"))
            inner = (sub_lhs::OpExpr).args[1]
            (inner isa OpExpr && (inner::OpExpr).op == "index") ||
                throw(TreeWalkError("E_TREEWALK_ARRAYOP_MALFORMED_LHS",
                                    "expected index(var,...) inside D"))
            ve = (inner::OpExpr).args[1]
            ve isa VarExpr ||
                throw(TreeWalkError("E_TREEWALK_ARRAYOP_MALFORMED_LHS",
                                    "index first arg must be a variable name"))
            cname = _cell_key((ve::VarExpr).name,
                              [_eval_const_int(a, _EMPTY_IDX_ENV)
                               for a in (inner::OpExpr).args[2:end]])
            slot = get(var_map, cname, 0)
            slot == 0 && throw(TreeWalkError("E_TREEWALK_UNKNOWN_STATE", cname))
            push!(slots, slot)
        end
    end
    return _ScanFold(slots, len, Symbol(oplus), zerobar, inclusive)
end

# ---- Cascade coverage tally (build observability) ----
# Which of the array-equation build attempts each equation LANDS on:
#   :affine             — the polyhedral access-kernel build, first try
#   :affine_fused_retry — affine succeeded only after fusing the compile-once
#                         template tier back in
#   :percell_acc        — the per-cell scalarize fallback, merged into
#                         indirect-outs `_AccKernel`s (acc_merge.jl)
#   :scan               — a forward cumulative (prefix) reduction, rewritten
#                         into an affine TERM build plus an O(N) accumulation
#                         (ess-scan, scan.jl). Counted instead of `:affine`,
#                         since the term kernels are what the affine build
#                         actually produced.
#   :percell_disabled   — ESS_STENCIL_DISABLE=1 forced the per-cell reference
#                         (plain compiled scalar nodes on `rhs_list`, evaluated
#                         by `_eval_node` — the differential oracle)
# One increment per array equation, at the cascade's dispatch below. Cheap
# (a Dict bump per EQUATION, not per cell) and always on; read it via
# `EarthSciAST._CASCADE_TALLY`, reset with `EarthSciAST._reset_cascade_tally!()`.
#
# One NON-routing key rides the same tally:
#   :affine_subtree_tbl — the subtree-table rescue fired (stencil.jl
#                         `_try_exprtbl_lane`): a build-time-evaluable subtree
#                         the stencil vocabulary could not model became a
#                         `LANE_EXPRTBL` per-box table lane instead of
#                         declining the whole equation. Counted PER RESCUED
#                         SUBTREE LANE PER BRANCH TEMPLATE (grid-independent;
#                         bounded by structural groups), not per equation —
#                         and it increments even when the equation later
#                         declines over some OTHER construct, so it measures
#                         rescue firings, not final routing.
#
# Class-emission observability keys (also non-routing) ride the same tally:
#   :direct_class_kernel  — the per-cell scalarizer emitted a kernel carrying
#                           a per-lane spec table (acc_merge.jl, direct class
#                           emission); one bump per such kernel.
#   :direct_classmerge_round{1,2}_merge
#                         — the assembled-kernel DIRECT emission stage
#                           (oop_merge.jl `_merge_acc_kernel_classes` under
#                           cross-eq/affine-box direct emission) merged one
#                           class; this is where affine-box classes are
#                           expected to land.
#   :classmerge_round{1,2}_merge
#                         — the post-hoc REPAIR pass merged one class. With
#                           direct emission on (the default) these are the
#                           safety-net counters and are expected to be ZERO;
#                           nonzero means genuinely residual work the direct
#                           stages did not see.
const _CASCADE_TALLY = Dict{Symbol,Int}()
_tally_cascade!(k::Symbol) = (_CASCADE_TALLY[k] = get(_CASCADE_TALLY, k, 0) + 1; nothing)
_reset_cascade_tally!() = (empty!(_CASCADE_TALLY); nothing)

function _compile_arrayop_equation!(percell_scalar, acc_kernels, scan_folds,
        covered::BitVector, eq::Equation, resolved_obs::Dict{String,ASTExpr},
        array_var_info, var_map::Dict{String,Int},
        const_registry::AbstractDict, pgather::AbstractDict,
        param_sym_set, reg_funcs;
        template_sites::Union{Nothing,IdDict{OpExpr,OpExpr}}=nothing,
        # `nothing` or an `_XEqStore` (untyped: stencil.jl defines the type and
        # is included after this file; `_try_affine_stencil` checks it).
        xeq=nothing,
        # `nothing`, or the cross-equation cell-entry pool, a
        # `Vector{Tuple{Int,_Node}}` (untyped in the signature: `_Node` lives
        # in compile.jl, included after this file — same reason as `xeq`).
        # See `_compile_derivative_equations`: per-cell entries are APPENDED
        # here instead of being merged per equation, and the caller runs
        # `_acc_from_cell_entries` once after the whole equation loop.
        pooled_cells=nothing)
    lhs_op = eq.lhs::OpExpr
    idx_names = _output_idx_strings(lhs_op)
    ranges_dict = _ranges_dict(lhs_op)
    lhs_body = lhs_op.expr_body::OpExpr  # D(index(var, ...))
    # A materialized observed's fill arrives as the GATHER form
    # `index(<def>, i…)` (`_materialized_fill_equation`). Speculatively unwrap it
    # back to the bare producer — adopted only when that producer CONTRACTS,
    # which is the only case the gather form costs anything (it hides the
    # contraction from every tier below). See `_unwrap_identity_gather`.
    rhs_expr = _unwrap_identity_gather(eq.rhs, idx_names, ranges_dict)
    rhs_body = _extract_arrayop_body(rhs_expr)

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
    # (`contract_const[d] === nothing`) are expanded per output cell in the
    # per-cell fallback via `_expand_contract_range`.
    contract_names = String[]
    contract_ranges = Vector{Any}[]            # raw [lo,hi]/[lo,step,hi]
    contract_const  = Union{Vector{Int},Nothing}[]  # nothing ⇒ per-cell
    # Semiring ⊕ and its 0̄ identity (§5.1). Default sum_product (+, 0̄=0).
    rhs_oplus = "+"
    rhs_zerobar = 0.0
    # M2 join gates / filter predicate (§5.3 / §7.2) — constant per equation.
    agg_gates = nothing
    agg_filter = nothing
    if rhs_expr isa OpExpr && _is_aggregate_op((rhs_expr::OpExpr).op)
        rhs_op = rhs_expr::OpExpr
        rhs_oplus, rhs_zerobar =
            _aggregate_oplus_identity(rhs_op.semiring, rhs_op.reduce)
        agg_gates  = rhs_op.join_gates
        agg_filter = rhs_op.filter
        rhs_ranges = _ranges_dict(rhs_op)
        contract_names = _contracted_index_names(rhs_ranges, idx_names)
        for n in contract_names
            rspec = collect(rhs_ranges[n])
            push!(contract_ranges, rspec)
            push!(contract_const,
                  _is_const_int_range(rspec) ?
                      collect(_expand_int_range(rspec)) : nothing)
        end
    end

    range_iters = [collect(_expand_int_range(ranges_dict[n])) for n in idx_names]

    # ── Array-einsum runtime contraction loop (ess-runtime-contraction) ────────
    # An array-producing aggregate `out[i…] = ⊕_{k…} body(i…, k…)` with a UNIFORM
    # constant-bound inner reduction is compiled to ONE `_NK_CONTRACTION_LOOP` per
    # OUTPUT cell (the contracted indices k… kept SYMBOLIC, the output indices i…
    # concrete) instead of unrolling the body into `∏|k…|` terms per cell — so build
    # IR is O(1) in the reduction length per cell (vs O(∏|k…|), quadratic-or-worse).
    # The loop cells route to `percell_scalar` (→ `rhs_list`, the `ESS_STENCIL_DISABLE`
    # scalar-walk REFERENCE path), so the loop node NEVER reaches the affine /
    # acc-merge / access-kernel / oop-merge / codegen passes, which model unrolled
    # scalar terms — the same safety envelope the scalar-reduction loop uses. Gated
    # exactly as the scalar path (const integer bounds, ⊕∈{+,*,max,min}, no join /
    # filter, total length ≥ floor) PLUS a loopability PROBE on the first output cell:
    # if the body indexes STATE at a contracted index (no static per-k slot) the probe
    # returns `nothing` and the einsum takes the existing affine / unroll path,
    # unchanged. Small reductions (< floor) also keep the existing path, so the vast
    # existing array-kernel test surface is byte-for-byte unaffected.
    use_contraction_loop = false
    if _contraction_loop_enabled() && !isempty(contract_names) &&
       agg_gates === nothing && agg_filter === nothing &&
       all(c -> c !== nothing, contract_const) &&
       (rhs_oplus == "+" || rhs_oplus == "*" || rhs_oplus == "max" || rhs_oplus == "min") &&
       !isempty(range_iters) && all(!isempty, range_iters)
        total_contract = prod(length(c) for c in contract_const)
        if total_contract >= _contraction_loop_min()
            first_idx = Dict{String,ASTExpr}(idx_names[d] => IntExpr(Int64(first(range_iters[d])))
                                             for d in 1:length(idx_names))
            probe = _sub_preserving(rhs_body, first_idx)
            probe = isempty(resolved_obs) ? probe : _sub_preserving(probe, resolved_obs)
            pranges = [_expand_int_range(contract_ranges[d]) for d in 1:length(contract_names)]
            use_contraction_loop = _try_build_contraction_loop(probe, contract_names,
                pranges, rhs_oplus, rhs_zerobar, array_var_info, var_map,
                const_registry, pgather) !== nothing
        end
    end

    # Affine polyhedral build (ess-affine, stencil_affine.jl): O(#structural
    # groups), producing `_AccKernel`s that resolve gathers at runtime. This is the
    # DEFAULT array-kernel build; it now carries its own eval-time optimization
    # (per-cell CSE + loop-invariant hoisting on the access spine), so it is a clean
    # win over the vectorized path it supersedes. Returns `nothing` (covered
    # untouched) for anything it cannot model, falling through to the symbolic /
    # per-cell chain. `ESS_STENCIL_DISABLE=1` forces the per-cell reference (the
    # differential-test escape hatch).
    #
    # A CONSTANT-bound contraction with no join gate is UNROLLED into a plain
    # ⊕-fold body (`_unrolled_contraction_body`) and lowered by the SAME box
    # processor — no runtime reduce, no per-cell loop. A variable-valence bound or
    # a join gate (either can vary the term set per output cell) is left to the
    # per-cell path.
    #
    # A FORWARD CUMULATIVE (prefix) reduction is split instead (ess-scan,
    # scan.jl): the body with the contracted symbol renamed to the output
    # symbol goes through this same affine build as an ordinary elementwise
    # body, and a `_ScanFold` accumulates over the result after the kernel
    # section. Both passes are O(N); the unrolled guarded fold below is O(N²).
    # Declining leaves `scan_fold === nothing` and changes nothing.
    scan_fold = nothing
    affine_kernels = nothing
    affine_first_try = false
    if !_stencil_disabled() && !use_contraction_loop
        scan = _detect_prefix_scan(idx_names, range_iters, contract_names,
                                   contract_const, agg_gates, agg_filter, rhs_body)
        affine_body =
            isempty(contract_names) ? rhs_body :
            scan !== nothing ?
                _sub_preserving(rhs_body,
                    Dict{String,ASTExpr}(scan[3] => VarExpr(idx_names[scan[1]]))) :
            (agg_gates === nothing && all(c -> c !== nothing, contract_const)) ?
                _unrolled_contraction_body(rhs_body, contract_names, contract_const,
                                           agg_filter, rhs_oplus, rhs_zerobar) :
            nothing
        # The TERM build runs over the axis the TERMS live on — the output axis
        # itself for a same-range scan, its centres for a staggered one
        # (`scan[4]`, see `_scan_term_iters`). The FOLD below always walks the
        # full output axis. Identical object on every pre-existing shape.
        term_iters = (scan === nothing || scan[4] === nothing) ? range_iters : scan[4]
        affine_kernels = affine_body === nothing ? nothing :
            _try_affine_stencil(affine_body, idx_names, term_iters, lhs_body,
                                resolved_obs, array_var_info, var_map,
                                const_registry, pgather, param_sym_set, reg_funcs,
                                covered; template_sites=template_sites, xeq=xeq)
        affine_first_try = affine_kernels !== nothing
        # Compile-once tier declined (a body construct the sub-kernel split cannot
        # model): retry the SAME expanded body fused — exactly the pre-tier build.
        # Rarely taken; `covered` is untouched on a `nothing` return.
        if affine_kernels === nothing && template_sites !== nothing && affine_body !== nothing
            affine_kernels =
                _try_affine_stencil(affine_body, idx_names, term_iters, lhs_body,
                                    resolved_obs, array_var_info, var_map,
                                    const_registry, pgather, param_sym_set,
                                    reg_funcs, covered; xeq=xeq)
        end
        # The term kernels are in hand — resolve the slots they write, in scan
        # order, so the post-pass can fold them. Only now, so a declined affine
        # build costs nothing.
        if scan !== nothing && affine_kernels !== nothing
            scan_fold = _build_scan_fold(scan[1], scan[2], idx_names, range_iters,
                                         lhs_body, var_map, rhs_oplus, rhs_zerobar)
        end
    end
    if affine_kernels !== nothing
        _tally_cascade!(scan_fold !== nothing ? :scan :
                        affine_first_try ? :affine : :affine_fused_retry)
        get(ENV, "ESS_STENCIL_DEBUG", "") == "1" &&
            (println(stderr, "[ess-affine] FIRED: ", length(affine_kernels),
                     " access kernels for ", _output_idx_strings(lhs_op)); flush(stderr))
        append!(acc_kernels, affine_kernels)
        scan_fold === nothing || push!(scan_folds, scan_fold)
        return nothing
    end
    # Anything the affine build cannot model takes the per-cell fallback, whose
    # cell entries merge into indirect-outs access kernels (acc_merge.jl) — or,
    # under ESS_STENCIL_DISABLE=1, stay plain per-cell scalar nodes (the
    # differential reference).
    _tally_cascade!(use_contraction_loop ? :percell_loop :
                    _stencil_disabled() ? :percell_disabled : :percell_acc)
    # ESS_STENCIL_DEBUG announced every affine FIRE but stayed silent on every
    # DECLINE — backwards for diagnosis, since the declines are what cost O(cells)
    # IR and the fires are what you wanted. Name the equation that fell back, so a
    # cascade tally reading `:percell_acc => 1` can be turned into "which one".
    get(ENV, "ESS_STENCIL_DEBUG", "") == "1" &&
        (println(stderr, "[ess-affine] DECLINED -> per-cell: lhs=",
                 sprint(show, lhs_body), " out_idx=", idx_names,
                 " ranges=", [(n, length(r)) for (n, r) in zip(idx_names, range_iters)]);
         flush(stderr))
    _compile_arrayop_percell!(percell_scalar, acc_kernels, covered, lhs_body, rhs_body;
        idx_names=idx_names, range_iters=range_iters,
        contract_names=contract_names, contract_ranges=contract_ranges,
        contract_const=contract_const, rhs_oplus=rhs_oplus,
        rhs_zerobar=rhs_zerobar, agg_gates=agg_gates, agg_filter=agg_filter,
        resolved_obs=resolved_obs, array_var_info=array_var_info,
        var_map=var_map, const_registry=const_registry, pgather=pgather,
        param_sym_set=param_sym_set, reg_funcs=reg_funcs,
        contraction_loop=use_contraction_loop, pooled_cells=pooled_cells)
    return nothing
end

# ---- Stage: arrayop per-cell fallback ----
# Compile one representative per structural group: all cells of this equation
# share the same resolve/compile context, so a per-equation memo (a plain
# local, passed explicitly) lets every subexpression shared across cells
# resolve and compile exactly once instead of once per cell. A contracted
# (einsum) equation expands its reduction through the shared
# `_foreach_aggregate_term` core and accumulates at runtime via
# `_NK_CONTRACTION`; the per-cell nodes are then merged into whole-array
# kernels — structurally-identical cells collapse to one template; ghost
# boundaries / makearray regions / distinct valences form their own
# (N-independent) groups. The DEFAULT merge target is the unified access-kernel
# IR (`_acc_from_cell_entries`, acc_merge.jl → indirect-outs `_AccKernel`s,
# codegen-compiled or interpreted); `ESS_STENCIL_DISABLE=1` skips the merge and
# keeps the compiled per-cell nodes as plain scalar entries (`percell_scalar`
# → `rhs_list`, evaluated by `_eval_node`) — the maximally independent
# reference the acc≡per-cell differentials compare against. The
# equation-derived inputs are keyword-only (several share a type, so
# positional passing could silently swap two of them).
function _compile_arrayop_percell!(percell_scalar, acc_kernels, covered::BitVector,
        lhs_body::OpExpr, rhs_body::ASTExpr;
        idx_names::Vector{String}, range_iters,
        contract_names::Vector{String}, contract_ranges, contract_const,
        rhs_oplus::String, rhs_zerobar::Float64, agg_gates, agg_filter,
        resolved_obs::Dict{String,ASTExpr}, array_var_info,
        var_map::Dict{String,Int}, const_registry::AbstractDict,
        pgather::AbstractDict, param_sym_set, reg_funcs,
        contraction_loop::Bool=false,
        pooled_cells=nothing)   # `nothing` or `Vector{Tuple{Int,_Node}}` — see above
    cell_entries = Tuple{Int,_Node}[]
    cell_memo = _BuildMemo()
    # A scalar aggregate NESTED in this array-equation cell body must keep
    # unrolling: its node flows into the stencil / access-kernel merge, which
    # models unrolled scalar terms. Mark the array-cell resolve so
    # `_resolve_scalar_arrayop` confines the runtime contraction loop to scalar
    # contexts (ess-runtime-contraction). try/finally: the guard must unwind even
    # if a cell resolve throws.
    _ARRAY_CELL_DEPTH[] += 1
    try
    for idx_tuple in Iterators.product(range_iters...)
        idx_env  = Dict{String,Int}(idx_names[d] => idx_tuple[d]
                                    for d in 1:length(idx_names))
        idx_exprs = Dict{String,ASTExpr}(k => IntExpr(Int64(v))
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
        concrete_idxs = [_eval_const_int(a, _EMPTY_IDX_ENV)
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
            rhs_r = _resolve_indices(sub_rhs, array_var_info, var_map, const_registry, pgather, cell_memo)
            push!(cell_entries, (idx, _compile(rhs_r, var_map, param_sym_set, reg_funcs, cell_memo)))
        elseif contraction_loop
            # Runtime contraction loop (ess-runtime-contraction): compile the inner
            # reduction ONCE into an `_NK_CONTRACTION_LOOP` for THIS output cell —
            # the output indices are already concrete in `sub_rhs_outer`; the
            # contracted indices stay symbolic and iterate at eval time. Constant
            # bounds + no join/filter are guaranteed by the caller's gate; the
            # loopability probe already passed, so a per-cell failure is a build
            # invariant break (raised loudly, never silently miscompiled).
            body2 = isempty(resolved_obs) ? sub_rhs_outer :
                    _sub_preserving(sub_rhs_outer, resolved_obs)
            pranges = [_expand_int_range(contract_ranges[d])
                       for d in 1:length(contract_names)]
            marker = _try_build_contraction_loop(body2, contract_names, pranges,
                        rhs_oplus, rhs_zerobar, array_var_info, var_map,
                        const_registry, pgather)
            marker === nothing &&
                throw(TreeWalkError("E_TREEWALK_CONTRACTION_LOOP_INTERNAL",
                    "einsum contraction-loop build failed for a cell after the " *
                    "loopability probe passed (build invariant break)"))
            push!(cell_entries, (idx, _compile(marker, var_map, param_sym_set,
                                               reg_funcs, cell_memo)))
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
                    _expand_contract_range(contract_ranges[d], idx_env,
                                           const_registry) :
                    cc
            end
            # M2 (§5.3 / §7.2) via the shared `_foreach_aggregate_term` core:
            # a join-rejected combination is dropped (so a degenerate join
            # keeps every term and is byte-identical); a filter-rejected one
            # contributes 0̄ at runtime via an `ifelse` guard. The filter
            # carries this cell's (fixed) output-index substitution already,
            # matching the hoisted `sub_rhs_outer`; the join binding seeds
            # from this cell's `idx_env`.
            filt_cell = agg_filter === nothing ? nothing :
                        _sub_preserving(agg_filter, idx_exprs)
            k_nodes = _Node[]
            _foreach_aggregate_term(sub_rhs_outer, contract_names,
                                    cell_contract_iters, agg_gates, filt_cell,
                                    rhs_zerobar, idx_env) do term
                term = isempty(resolved_obs) ? term :
                       _sub_preserving(term, resolved_obs)
                rhs_r = _resolve_indices(term, array_var_info, var_map, const_registry, pgather, cell_memo)
                push!(k_nodes, _compile(rhs_r, var_map, param_sym_set, reg_funcs, cell_memo))
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
    finally
        _ARRAY_CELL_DEPTH[] -= 1
    end
    if contraction_loop || _stencil_disabled()
        # Loop cells evaluate through the plain scalar walker (`_eval_node`),
        # bypassing the affine / acc-merge / access-kernel / oop-merge / codegen
        # passes entirely (ess-runtime-contraction) — this IS the stencil-disabled
        # reference path, so the result is the reference result.
        append!(percell_scalar, cell_entries)
    elseif pooled_cells !== nothing
        # Cross-equation direct class emission: defer to the ONE
        # `_acc_from_cell_entries` call sited above the equation loop
        # (`_compile_derivative_equations`), so cells of identical shape in
        # DIFFERENT equations share a class kernel directly.
        append!(pooled_cells, cell_entries)
    else
        append!(acc_kernels, _acc_from_cell_entries(cell_entries))
    end
    return nothing
end

"""
    build_evaluator(model::Model; initial_conditions=Dict(),
                    parameter_overrides=Dict(), tspan=nothing,
                    registered_functions=Dict(), kwargs...)

Build a tree-walk ODE RHS evaluator for `model`. Public entry point —
returns `(f!, u0, p, tspan, var_map)`. Thin wrapper over
`_build_evaluator_impl`, which additionally returns build diagnostics
consumed by the ess-dhq N-independence property test.

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

Keyword arguments (see `_build_evaluator_impl` for the full set,
including `const_arrays`, `param_arrays`, `const_array_boundaries`,
`index_sets`, and `inspect`):

* `initial_conditions::Dict{String,<:Real}` — override the default
  values in `model.variables` for specific state variables.
* `parameter_overrides::Dict{String,<:Real}` — override the default
  values for specific parameters. Keys may be spelled either LOCALLY
  (`pert_amp`, the form esm-spec §6.6 pins for a test's
  `parameter_overrides`) or with the flattening qualification the run
  document carries (`SimpleClimate.pert_amp`); both resolve to the same
  parameter, and an ambiguous local name (the same parameter in two
  mounted components) is left unbound rather than guessed at. The
  resolved values are load-time constants, so they bind the build-time
  evaluation scope too — the coordinate-expression `ic` seed and the
  §6.6.5 reference / observed assertion scope reported via `inspect` —
  not just the runtime parameter NamedTuple.
* `tspan::Union{Nothing,Tuple{Real,Real}}` — explicit time span. If
  `nothing`, the first inline `tests` block's `time_span` is used; if
  the model has no tests, the null default `(0.0, 1.0)` is returned.
* `registered_functions::Dict{String,<:Function}` — handlers for
  `call` ops, keyed by `handler_id`.
* `form::Symbol` — which RHS to emit (`:inplace`, the default, or `:oop`).
  `:inplace` gives the `f!(du, u, p, t)` above: zero-allocation at Float64
  AND eltype-generic, so it both solves and differentiates (ForwardDiff
  over the state or over the parameters; a stiff solve gets an exact AD
  Jacobian for free). It is the right answer for almost everything.
  `:oop` gives an out-of-place `f(u, p, t) → du`. Reach for it only to
  TRACE — it is what XLA/Reactant and device backends can consume, because
  it captures no host scratch buffers and contains no per-lane scalar
  loops. It is not faster and not more differentiable than `f!`; it
  allocates one temporary per AST node. Both come from the same compiled
  IR in the same evaluation order, so a Float64 `:oop` call is
  bit-identical to `f!` — which is why the in-place tests use it as their
  oracle. SciML dispatches `ODEProblem` on RHS arity, so either drops into
  `ODEProblem(f, u0, tspan, p)` unchanged. The `:oop` RHS additionally
  carries an explicit-buffers form for tracing backends — its live forcing
  buffers (`param_arrays` + discrete caches) exposed as ARGUMENTS via
  [`rhs_with_buffers`](@ref) / [`forcing_buffers`](@ref) /
  [`forcing_buffer_index`](@ref), so `@compile` receives them as real XLA
  inputs and an in-place refresh stays visible to the compiled program.
"""
function build_evaluator(model::Model; kwargs...)
    f!, u0, p, tspan_default, var_map, _diag = _build_evaluator_impl(model; kwargs...)
    return f!, u0, p, tspan_default, var_map
end

"""
    param_map(p) -> Dict{String,Int}

Parameter NAME → its position in a parameter VECTOR, the `p`-side mirror of the
`var_map` [`build_evaluator`](@ref) returns for the state.

Take it from the `p` that `build_evaluator` handed back:

```julia
f!, u0, p, tspan, var_map = build_evaluator(doc)
pm = param_map(p)                  # "k_diff" => 1, "k_rxn" => 3, …
θ  = ComponentVector(p)            # the same order, as an AbstractVector
f!(du, u, θ, t)                    # …and it is accepted as `p`
```

`build_evaluator` keeps returning its 5-tuple — 391 call sites destructure it —
so this is a FUNCTION OF `p` rather than a sixth return value. That costs nothing
in fidelity: the order is the build's own (`param_names` is sorted, and the `p`
NamedTuple is built from it in that order), and `keys(p)` IS that order, so this
map and the `idx` baked into every `_NK_PARAM` node are the same numbering by
construction rather than by agreement.

A parameter-free model carries SciMLBase's `nothing` sentinel as `p` and maps to
the empty Dict.
"""
param_map(p::NamedTuple) = Dict{String,Int}(String(k) => i
                                            for (i, k) in enumerate(keys(p)))
param_map(::Nothing) = Dict{String,Int}()

"""
    parameter_classes(x) -> Dict{String,Symbol}

Parameter NAME → what KIND of parameter it is in the build that produced `x`
(a [`BuildInspection`](@ref) or a `PreparedModel`). Four classes:

| class | where its value is consumed | overridable at solve time? |
|---|---|---|
| `:numeric` | the runtime `p` vector | **yes** — swap `p` (`remake`), differentiable |
| `:structural` | BUILD time (setup geometry, value-invention extents, binning coordinates, `ic()` folds) | no — re-`prepare` |
| `:const_folded` | frozen into the build's const arrays and inlined into the RHS | no — re-`prepare` with new data |
| `:forcing` | a live buffer a discrete provider rewrites in place | no — write the buffer |

The partition is **derived, not declared**: every one of these is spelled
`"type": "parameter"` in the document, so the discriminator is where the value is
CONSUMED. The build records the names its build-time consumers resolve (see the
`_PARAM_READS` seam) and anything they touched is `:structural` — by
construction, not by a second static reading of the document.

`:structural` is per NAME, not per use: a name read once at build stays
structural even when the RHS also reads it at runtime, because the value baked
into the build and the value in `p` would then disagree.

`:const_folded` deserves its own name rather than being folded into
`:structural`: differentiating w.r.t. one returns an unconditional ZERO, and a
finite-difference check on its declared default CONFIRMS that zero (perturbing
the default changes nothing either) — a wrong gradient and a wrong check
agreeing silently. It is refused explicitly, with its own message.

Like [`param_map`](@ref) this is a function of an artifact rather than an extra
`build_evaluator` return value: the 5-tuple has hundreds of destructuring call
sites. Pass `inspect = BuildInspection()` to `build_evaluator` / `prepare`, or
read it off the `PreparedModel` that `prepare` returns.

```julia
prep = prepare("model.esm")
cls  = parameter_classes(prep)
θ    = [n for (n, c) in cls if c === :numeric]     # what a gradient may target
simulate(prep, tspan; alg = Tsit5(), parameters = Dict(θ[1] => 2.0))
```
"""
parameter_classes(insp::BuildInspection) = insp.param_classes

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
    return build_evaluator(model; index_sets=file.index_sets,
                           _template_reg=_component_template_reg(file, model_name),
                           kwargs...)
end

# The selected model's surviving-reference registry ("models.<name>" in
# `EsmFile.component_templates`, esm-spec §9.6.4 Option B), or `nothing` when the
# document carries none. Mirrors `_select_model`'s name resolution; a selection
# `_select_model` would reject returns `nothing` here and lets it throw.
function _component_template_reg(file::EsmFile, model_name)
    ct = file.component_templates
    ct === nothing && return nothing
    name = model_name !== nothing ? String(model_name) :
           (file.models !== nothing && length(file.models) == 1 ?
                String(first(keys(file.models))) : nothing)
    name === nothing && return nothing
    return get(ct, "models.$name", nothing)
end

"""
    expanded_model(file::EsmFile, model_name=nothing) -> Model

A deep copy of the selected model with every surviving Option-B
`apply_expression_template` reference (esm-spec §9.6.4) expanded against the
document's `component_templates` — the same expansion `build_evaluator`
performs before compiling, exposed as a public seam so downstream tools
(e.g. EarthSciASTDiff, which differentiates the tree) analyze the SAME tree
the evaluator compiles. `file` is not mutated.

Model selection matches [`build_evaluator`](@ref): `model_name = nothing`
selects the document's only model, or throws `E_TREEWALK_AMBIGUOUS_MODEL`
when there are several; an unknown name throws `E_TREEWALK_NO_MODEL`.
A document with no surviving references returns the plain copy.
"""
function expanded_model(file::EsmFile,
                        model_name::Union{Nothing,AbstractString}=nothing)::Model
    model = deepcopy(_select_model(file, model_name))
    reg = _component_template_reg(file, model_name)
    reg === nothing || _expand_model_refs!(model, reg)
    return model
end

# Value-invention materialisation runs only through the AbstractDict
# front-door (which owns the document-scoped index-set registry the pass
# needs); default the internal extents/vars to empty here so a direct
# EsmFile/Model call is unchanged.

# The const-array keys an authored bare factor name resolves to in THIS build.
# The front-door build keeps bare names, but `prepare` flattens first — every
# variable is namespaced to `<OrigModel>.<name>` (the model itself renamed
# `Flattened`), while document-scoped index-set fields (`member_factor`) and gate
# `applies_to` stay bare. So a bare authored name must be injected under BOTH the
# bare key AND every model-variable key whose final dotted segment matches it, so
# the gather (which reads the namespaced ref) resolves in either build path.
function _const_factor_aliases(model, bare::AbstractString)
    keys_out = Set{String}([String(bare)])
    if model !== nothing
        for k in keys(model.variables)
            ks = String(k)
            (ks == bare || (occursin('.', ks) &&
                            String(split(ks, '.')[end]) == bare)) && push!(keys_out, ks)
        end
    end
    return keys_out
end

# ---- Phase 2b Hook 1 helper: members-fed-back-as-const-factor ----------------
# Scan the document index-set registry for `kind:"derived"` sets that name a
# `member_factor`; for each, surface its value-invention MEMBERS (the invented,
# sorted-distinct, 1-based full-grid ids in `vi_members[from_faq]`) as a dense
# 1-D Float64 const array keyed by the factor name (and its namespaced aliases,
# see `_const_factor_aliases`). Returns a `name => vector` dict to merge into
# `const_arrays`. A derived set with no `member_factor`, or whose producer did
# not materialise, contributes nothing.
function _feed_back_vi_members(index_sets, vi_members::AbstractDict, model)
    out = Dict{String,Any}()
    index_sets === nothing && return out
    for (_, is) in index_sets
        is isa IndexSet || continue
        is.kind == "derived" || continue
        mf = is.member_factor
        (mf === nothing || is.from_faq === nothing) && continue
        faq = String(is.from_faq)
        haskey(vi_members, faq) || continue
        mem = vi_members[faq]
        # single-component skolem keys degrade to scalar ids (value_invention.jl);
        # a multi-component (tuple) member has no scalar factor form.
        vec = Vector{Float64}(undef, length(mem))
        ok = true
        for (i, m) in enumerate(mem)
            if m isa Real
                vec[i] = Float64(m)
            else
                ok = false
                break
            end
        end
        ok || throw(TreeWalkError("E_TREEWALK_VI_MEMBER_FACTOR",
            "derived index set member_factor '$mf' requires SCALAR members " *
            "(a single-component skolem key); got a composite member for faq '$faq'"))
        for k in _const_factor_aliases(model, String(mf))
            out[k] = vec
        end
    end
    return out
end

# ---- Phase 2b Hook 2 helper: gated-provider deferral → selective fetch -------
# Resolve each stashed GATED provider's `selection` from the now-materialised
# value-invention members, fetch ONLY the compact slab, and return a
# `model-var-name => compact Float64 array` dict to merge into `const_arrays`.
#
# `gated` maps a provider KEY to either the bare provider or a `(prov=…, gate=…)`
# bundle; `provider_gate_spec(prov)` supplies the gate when the bundle omits it.
# A gate is `Dict("axes"=>[…], "applies_to"=>[names…])` where each native axis is
# one of `Dict("fixed"=>[i])` (0-based native index → DROPPED length-1 axis),
# `Dict("range"=>Dict("start"=>a,"stop"=>b,"step"=>s))` (a half-open strided
# window, axis KEPT), `Dict("gated_by"=>"<derived set>")` (the set's members,
# 1-based, as the new axis), or `"all"` (whole axis) — ONE vocabulary, whether
# the author wrote it as a loader `select` (esm-spec §8.9.2) or the pushdown
# rewrite generated it (CONFORMANCE_SPEC §5.5). The compact gated axis length is
# asserted to equal the gating set's materialised extent.
function _fetch_gated_providers(gated::AbstractDict, index_sets, vi, t0::Float64, model)
    out = Dict{String,Any}()
    (vi === nothing) && isempty(gated) && return out
    # derived set name → its producer faq id (for `gated_by` resolution).
    set_to_faq = Dict{String,String}()
    if index_sets !== nothing
        for (sname, is) in index_sets
            is isa IndexSet || continue
            is.kind == "derived" && is.from_faq !== nothing &&
                (set_to_faq[String(sname)] = String(is.from_faq))
        end
    end
    vi_members = vi === nothing ? Dict{String,Vector{Any}}() : vi.members
    vi_extents = vi === nothing ? Dict{String,Int}() : vi.extents

    for (key, entry) in gated
        prov, gate = _unbundle_gated(entry)
        gate === nothing && continue
        axes = get(gate, "axes", nothing)
        applies = get(gate, "applies_to", nothing)
        (axes === nothing || applies === nothing) && throw(RefreshError(
            "gated provider '$key' gate spec needs both `axes` and `applies_to`"))

        selection = Vector{Any}(undef, length(axes))
        drop_axes = Int[]                 # positions of `fixed` axes (dropped)
        gated_pos = 0                     # position of the single gated axis
        gated_extent = 0
        for (ax_i, ax) in enumerate(axes)
            if ax == "all"
                selection[ax_i] = Colon()
            elseif ax isa AbstractDict && haskey(ax, "fixed")
                fx = ax["fixed"]
                fi = fx isa AbstractVector ? Int(first(fx)) : Int(fx)
                selection[ax_i] = fi + 1          # 0-based native → 1-based neutral
                push!(drop_axes, ax_i)
            elseif ax isa AbstractDict && haskey(ax, "range")
                # The half-open strided window of the SAME per-axis vocabulary a
                # loader's `select` writes (esm-spec §8.9.2) — the axis is kept,
                # so it neither drops nor gates. Bounds are already integers here
                # (a metaparameter name resolves where the select is parsed).
                r = ax["range"]
                start = Int(get(r, "start", 0))
                stop = Int(r["stop"])
                step = Int(get(r, "step", 1))
                step >= 1 || throw(RefreshError(
                    "gated provider '$key' axis $ax_i: range.step must be >= 1, got $step"))
                selection[ax_i] = collect((start + 1):step:stop)   # 0-based → 1-based
            elseif ax isa AbstractDict && haskey(ax, "gated_by")
                sname = String(ax["gated_by"])
                haskey(set_to_faq, sname) || throw(RefreshError(
                    "gated provider '$key' gates on '$sname' which is not a " *
                    "derived index set with a from_faq"))
                faq = set_to_faq[sname]
                haskey(vi_members, faq) || throw(RefreshError(
                    "gated provider '$key' gates on '$sname' (faq '$faq') but its " *
                    "value-invention members were not materialised"))
                mem = Int[Int(m) for m in vi_members[faq]]   # 1-based ids, set order
                selection[ax_i] = mem
                gated_pos = ax_i
                gated_extent = get(vi_extents, faq, length(mem))
            else
                throw(RefreshError("gated provider '$key' axis $ax_i is malformed " *
                    "(expected \"all\", {\"fixed\":[i]}, {\"range\":{start,stop,step}}, " *
                    "or {\"gated_by\":set})"))
            end
        end
        gated_pos == 0 && throw(RefreshError(
            "gated provider '$key' declares no {\"gated_by\":…} axis"))

        # position of the compact gated axis AFTER dropping the fixed axes.
        gated_pos_out = gated_pos - count(<(gated_pos), drop_axes)
        drop_tuple = Tuple(drop_axes)

        supports = provider_supports_selection(prov)
        if supports
            sample = provider_sample(prov, t0; selection=selection)
            for name in applies
                nm = String(name)
                field = _sample_field(sample, nm)
                isempty(drop_tuple) || (field = dropdims(field; dims=drop_tuple))
                arr = Array{Float64}(field)
                size(arr, gated_pos_out) == gated_extent || throw(RefreshError(
                    "gated provider '$key' variable '$nm': fetched compact axis is " *
                    "$(size(arr, gated_pos_out)) but the gating set extent is $gated_extent"))
                for k in _const_factor_aliases(model, nm)
                    out[k] = arr
                end
            end
        else
            # FALLBACK: reader cannot push down — fetch whole, then slice. Build a
            # per-axis index tuple (fixed→scalar DROPS the axis, gated→member vec,
            # all→Colon) so the sliced result matches the pushdown result exactly.
            sample = provider_sample(prov, t0)
            idx = Any[a == "all" ? Colon() :
                      (a isa Integer ? Int(a) : Vector{Int}(a)) for a in selection]
            for name in applies
                nm = String(name)
                full = _sample_field(sample, nm)
                field = full[idx...]
                arr = Array{Float64}(field)
                size(arr, gated_pos_out) == gated_extent || throw(RefreshError(
                    "gated provider '$key' variable '$nm' (fallback slice): compact axis " *
                    "is $(size(arr, gated_pos_out)) but the gating set extent is $gated_extent"))
                for k in _const_factor_aliases(model, nm)
                    out[k] = arr
                end
            end
        end
    end
    return out
end

# A stashed gated entry is either the bare provider (gate via `provider_gate_spec`)
# or a `(prov=…, gate=…)` / `Dict("prov"=>…, "gate"=>…)` bundle.
function _unbundle_gated(entry)
    if entry isa NamedTuple && haskey(entry, :prov)
        return entry.prov, (haskey(entry, :gate) && entry.gate !== nothing ?
                            entry.gate : provider_gate_spec(entry.prov))
    elseif entry isa AbstractDict && haskey(entry, "prov")
        g = get(entry, "gate", nothing)
        return entry["prov"], (g === nothing ? provider_gate_spec(entry["prov"]) : g)
    else
        return entry, provider_gate_spec(entry)
    end
end

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
    kwd = Dict{Symbol,Any}(kwargs)

    # ---- Phase 4: AUTOMATIC projection-pushdown desugar (opt-in) ----
    # When `pushdown_rewrite=true`, recognise the ISRM-shaped `+`-aggregate /
    # sparse-binned-factor pattern in a CLEAN model and generate the four
    # hand-authored Phase-2b constructs (derived set + `distinct` producer +
    # member_factor + gated_select) BEFORE parsing, so the value-invention
    # front door and the impl re-parse both see them. A no-op (returns `esm`
    # unchanged) when the pattern does not match or the semiring guard fails.
    # OFF by default: every existing build path is byte-identical.
    if get(kwd, :pushdown_rewrite, false) === true
        esm = desugar_pushdown(esm; model_name = model_name)
    end
    delete!(kwd, :pushdown_rewrite)

    # `coerce_esm_file` normalizes every dict-like carrier (JSON3 object,
    # native Dict, JSONLikeDict) itself — no JSON-string round-trip.
    file = coerce_esm_file(esm)

    # ---- Value-invention front-door (RFC §6.1), on the TYPED IR ----
    # `OpExpr` preserves the full value-invention vocabulary (`id`, `distinct`,
    # `key`, `arg`, `join`, `label`; see OPEXPR_FIELD_TABLE), so any derived
    # index set is materialised from the typed model and the extents threaded
    # into the typed path. A no-op (and byte-identical) for models without a
    # skolem/distinct/rank node.
    model = _select_model_or_nothing(file, model_name)

    # ---- Caller-key canonicalization (esm-spec §6.6) ----
    # Rewrite the caller's LOCAL-named `parameter_overrides` onto this
    # document's (flattening-qualified) parameter names once, at the front
    # door, so the setup env, the binning-coordinate derivation, the
    # value-invention materialisation, and the typed impl below all read the
    # SAME resolved values. Without this a spec-spelled `{"pert_amp": 0}`
    # missed every one of them and the run silently used the default.
    if model !== nothing && haskey(kwd, :parameter_overrides)
        kwd[:parameter_overrides] =
            _normalize_param_override_keys(model, kwd[:parameter_overrides])
    end

    # ---- Build-time binning-coordinate derivation (RFC §8.6.1 purity) ----
    # A broad-phase binning coordinate declared INLINE as a reduce aggregate over the
    # in-file `const` geometry (e.g. `src_lon[i] = min_v src_poly[i,v,1]`) is a
    # build-time constant. Evaluate it once from the const-op arrays and thread it
    # into `const_arrays`, so `floor(index(src_lon,i)/dx)→skolem` resolves at setup
    # without the host supplying the coordinate. No-op (byte-identical) when no such
    # observed exists.
    _params = get(kwd, :parameter_overrides, Dict{String,Float64}())
    _ca = Dict{String,Any}(String(k) => v for (k, v) in get(kwd, :const_arrays, Dict{String,Any}()))
    # The build-time parameter-read sink (see `_PARAM_READS`) is created HERE,
    # not in the impl: two of the build-time consumers — the binning-coordinate
    # derivation and value invention (whose `_vi_param` reads decide an index-set
    # EXTENT, i.e. `length(u)`) — run at this front door, before the impl entry.
    # The same set is threaded down so the classification sees all of them.
    _preads = get(kwd, :_param_reads, nothing)
    _preads === nothing && (_preads = Set{String}())
    kwd[:_param_reads] = _preads
    if model !== nothing
        # The coordinate buffers a value-invention skolem GATHERS from (`src_lon`,
        # `tgt_lon`): a build-time-constant one is derived here so a
        # TEMPLATE-CONSTRUCTED (aggregate-valued) coordinate is admissible as a
        # skolem-bin index target (not only a const-supplied / reduce-over-const one).
        _vi_targets = _vi_skolem_index_targets(model)
        # Thread the model's registered functions so a coordinate whose body needs
        # the GENERAL build-time evaluator (an LCC projection's trig/`^`/`fn`
        # expansion — ops outside the setup-time geometry vocabulary) is projected
        # HERE, before value-invention, and its `X`/`Y` fed into `const_arrays`.
        _regfns = get(kwd, :registered_functions, Dict{String,Function}())
        _derived = _with_param_reads(_preads) do
            _derive_binning_coords(model, file.index_sets, _ca, _params,
                                   _vi_targets, _regfns)
        end
        if !isempty(_derived)
            merge!(_ca, _derived)
            kwd[:const_arrays] = _ca
        end
    end

    _vi = model === nothing ? nothing :
          _with_param_reads(_preads) do
              materialize_value_invention(model, file.index_sets, _ca, _params)
          end

    # ---- Phase 2b Hook 1: value-invention MEMBERS fed back as const factors ----
    # A `kind:"derived"` index set may name a `member_factor` — a model parameter
    # const factor the build fills HERE with the set's materialised member ids
    # (`vi.members[from_faq]`, 1-based full-grid ids). This is the ONLY path a
    # derived set's member VALUES (not just its dense extent `[1,n]`) reach the
    # ODE body: `cell_W[c] = index(W, index(<member_factor>, c))` gathers the
    # full-grid rows the compact derived axis selects. (There is NO `member(set,c)`
    # IR op — this feedback IS the mechanism.) Mirrors the `_derive_binning_coords`
    # merge above: the injected factor rides `const_arrays` into the impl build.
    if _vi !== nothing && !isempty(_vi.members)
        _fed = _feed_back_vi_members(file.index_sets, _vi.members, model)
        if !isempty(_fed)
            merge!(_ca, _fed)
            kwd[:const_arrays] = _ca
        end
    end

    # ---- Phase 2b Hook 1b: OVERLAP env factors on a DERIVED axis ----
    # §5.5.6 requires an `join.overlap` gate's envelope factors to be const-array
    # data — the broad phase runs ONCE at build time. The pushdown rewrite gates
    # each rewritten binning aggregate on the generated `pd_cell__*` gathers,
    # which live on the compact derived axis and so cannot exist until the axis
    # is sized (value invention) and its member factor is fed back (Hook 1
    # above). Derive them here, immediately after. No-op (byte-identical) for a
    # document whose overlap-gate factors are already const arrays — which is
    # every document that predates the rewrite's forward gate.
    if model !== nothing
        _envf = _with_param_reads(_preads) do
            _derive_overlap_env_factors(model, file.index_sets, _ca, _params,
                (_vi === nothing ? Dict{String,Int}() : _vi.extents), _regfns)
        end
        if !isempty(_envf)
            merge!(_ca, _envf)
            kwd[:const_arrays] = _ca
        end
    end

    # ---- Phase 2b Hook 2: gated-provider deferral → post-VI selective fetch ----
    # A GATED provider (its `.esm` data_loader declares a `gated_select`; the
    # runner reports it via `provider_gate_spec`) was SKIPPED by the eager const
    # loop in `prepare` and stashed in `_gated_providers`. Now that value-invention
    # has materialised the gating derived set's members + extent, push that set
    # down to the provider as a per-axis `selection` and fetch ONLY the compact
    # slab, merging it into `const_arrays` under the model variable name(s) the
    # gate's `applies_to` lists. This is the const-tier dependency edge:
    # value-invention (above) → gated provider_sample(selection) → const merge.
    _gated = get(kwd, :_gated_providers, nothing)
    if _gated !== nothing && !isempty(_gated)
        _t0 = Float64(get(kwd, :_sample_time, 0.0))
        _fetched = _fetch_gated_providers(_gated, file.index_sets, _vi, _t0, model)
        if !isempty(_fetched)
            merge!(_ca, _fetched)
            kwd[:const_arrays] = _ca
        end
    end
    # These are consumed here; do not forward to the typed impl entry point.
    delete!(kwd, :_gated_providers)
    delete!(kwd, :_sample_time)

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
    # esm-spec §9.6.4 Option B / RFC §7.7: surviving `apply_expression_template`
    # references carried by `flatten` (a non-empty `template_registry`) ride the
    # reconstituted document (`flattened_to_esm` emits the registry as the
    # model's `expression_templates` block), and the tree-walk impl entry
    # expands them with SITE RECORDING so the affine build can compile each body
    # once and call it as a sub-kernel (the RFC's compile-once tier) — the
    # SINGLE evaluator-side expansion point. `ESS_TEMPLATE_REF_DISABLE=1`
    # (Expand at load) is the one differential escape hatch (RFC §12 gate 3).
    # A no-op for a reference-free system.
    return build_evaluator(flattened_to_esm(flat); kwargs...)
end

# Does any equation / variable expression of `model` (or a subsystem) carry a
# surviving `apply_expression_template` node? Build-time guard input; one cheap
# whole-model walk (the traversal descends `bindings` too, which is harmless
# here — the apply node itself is what is being detected). Identity-memoized
# (`foreach_subexpr_once`): an existence predicate is path-multiplicity-
# insensitive, and equation trees can be compact DAGs (ESS-0hh).
function _model_has_surviving_refs(model::Model)
    found = false
    check(e) = e === nothing || found ? nothing : foreach_subexpr_once(e) do x
        x isa OpExpr && x.op == "apply_expression_template" && (found = true)
        nothing
    end
    for eqs in (model.equations, model.initialization_equations)
        for eq in eqs
            check(eq.lhs); check(eq.rhs)
        end
    end
    for (_, var) in model.variables
        check(var.expression)
    end
    if !found
        for (_, sub) in model.subsystems
            sub isa Model && _model_has_surviving_refs(sub) && (found = true)
        end
    end
    return found
end

# Select one typed model from an `EsmFile`, mirroring `_select_model`'s name
# resolution WITHOUT throwing: the value-invention front-door skips
# materialisation when no model matches and lets the typed entry point raise the
# proper `E_TREEWALK_NO_MODEL` / `E_TREEWALK_AMBIGUOUS_MODEL` diagnostic.
function _select_model_or_nothing(file::EsmFile, model_name)
    models = file.models
    (models === nothing || isempty(models)) && return nothing
    model_name !== nothing && return get(models, String(model_name), nothing)
    return length(models) == 1 ? first(values(models)) : nothing
end

"""
    evaluate_expr(expr::ASTExpr, bindings::AbstractDict;
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
function evaluate_expr(expr::ASTExpr, bindings::AbstractDict;
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
