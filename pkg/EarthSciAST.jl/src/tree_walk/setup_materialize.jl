# tree_walk/setup_materialize.jl — materializing the selected setup arrays:
# general maps, whole-array observeds, value-invention columns, and the setup
# environment the build reads them from.

# ============================================================
# Build-once PROMOTED-PHYSICS MAP aggregates (fuel/moisture/wind lookups)
# ============================================================
# A build-once array observed need not be geometry. When a per-cell field (e.g.
# `FuelModelLookup.code`, temperature, wind) is produced by an in-model regridder,
# the physics that reads it is promoted to a build-once MAP over that grid. A
# body that reaches an operator outside the setup-time geometry language
# (`_GEO_EVAL_OPS`, below) materializes through the GENERAL build-time cell
# evaluator (`_eval_cellwise`), the one `_materialize_setup_wholearray` uses.

# The op vocabulary of the setup-time geometry language (compiled by
# `_geo_compile`, tree_walk/geometry_compile.jl): the operators the registry
# flags `:geo_eval`. A build-once MAP whose body uses only these stays on the
# geometry materializer (a loader-field reindex `F[c] = F_raw[floor((c-1)/GX)+1, …]`,
# a constructed cell ring `tgt_poly[j,v,k] = ifelse(k==1, …, …)`, a geometry
# weight over a derived set); one that reaches any other operator (`const`,
# `exp`, `log`, `tan`, …) is a promoted physics lookup and routes to
# `_eval_cellwise`.
# Membership is declared per-op in src/op_registry.jl (flag `:geo_eval`) and
# pinned by op_registry_test.jl.
const _GEO_EVAL_OPS = _ops_with(:geo_eval)

# True iff any op node in the subtree is OUTSIDE the `_GEO_EVAL_OPS` vocabulary
# — i.e. the body cannot be materialized by the setup-time geometry path and
# needs the general build-time cell evaluator instead.
function _body_needs_general_eval(e::OpExpr)
    if _tpl_is_call(e)
        # A template call (call.jl): its body's operators, and its arguments.
        _call_body_any_op(op -> !(op in _GEO_EVAL_OPS), e) && return true
        b = e.bindings
        return b !== nothing && _anyof(v -> v isa OpExpr && _body_needs_general_eval(v), collect(values(b)))
    end
    e.op in _GEO_EVAL_OPS || return true
    _anyof(a -> a isa OpExpr && _body_needs_general_eval(a), e.args) && return true
    e.expr_body isa OpExpr && _body_needs_general_eval(e.expr_body::OpExpr) && return true
    e.filter isa OpExpr && _body_needs_general_eval(e.filter::OpExpr) && return true
    if e.values !== nothing
        _anyof(v -> v isa OpExpr && _body_needs_general_eval(v), e.values) && return true
    end
    return false
end

# True iff `rhs` is a build-once NON-GEOMETRY MAP aggregate that NEEDS the general
# evaluator: an array-producing `faq` (non-empty `output_idx`) that
# is a pure MAP — every range key is an output index, so no top-level CONTRACTION —
# carries no join/filter gate, and whose body reaches an op OUTSIDE the geometry
# vocabulary `_GEO_EVAL_OPS` (the registry's geometry operators) — i.e. a
# promoted per-cell physics lookup. Every geometry aggregate — an overlap-area
# weight, a `A_j[j] = Σ_i A_ij[i,j]` row-sum, a constructed cell ring, a binning
# coordinate, a loader-field reindex — uses only `_GEO_EVAL_OPS` and stays on
# the compiled geometry path (`_materialize_geom_array`).
function _is_setup_general_map(rhs)
    (rhs isa OpExpr && _is_faq_op(rhs.op)) || return false
    (rhs.output_idx !== nothing && any(s -> s isa AbstractString, rhs.output_idx)) || return false
    rhs.expr_body === nothing && return false
    (rhs.join === nothing && rhs.join_gates === nothing && rhs.filter === nothing) || return false
    out = Set{String}(String(s) for s in rhs.output_idx if s isa AbstractString)
    ranges = rhs.ranges === nothing ? Dict{String, Any}() : rhs.ranges
    all(k -> String(k) in out, keys(ranges)) || return false   # pure MAP: no contraction
    return _body_needs_general_eval(rhs::OpExpr)
end

# ------------------------------------------------------------
# Compile-once materialization of a promoted-physics MAP
# ------------------------------------------------------------
# The per-cell loop below re-ran the WHOLE build-time pipeline (`_index_at_cell` →
# `_resolve_indices` → `_compile` → `_eval_node`) once per output cell, so a
# promoted per-cell physics lookup over an N-cell grid paid N FULL AST LOWERINGS
# and made build cost scale with the grid.
#
# The cure already exists in this package: the compile-once cell evaluator
# (`_cellwise_compile_once`, tree_walk/cellwise.jl), which resolves + compiles ONCE
# with the output indices kept SYMBOLIC and bound as reserved parameters. A const
# read carrying an output index does not constant-fold; it lowers to a runtime
# `_NK_CONST_GATHER` that recomputes its column-major offset at eval time — exactly
# the "gather compiled once, evaluated per cell" shape a per-cell physics lookup
# needs. `_is_setup_general_map` has already established the preconditions
# (aggregate op, all-String `output_idx`, non-nothing `expr_body`, no
# join/join_gates/filter, pure MAP), so `_resolve_index_of_faq` takes its
# no-contraction early return and the body is a single substituted tree.
#
# BIT-EXACTNESS. The fast path engages only where the compiled tree is provably
# value-identical to the folded per-cell tree, so the materialized array is
# `isequal`-identical (signed zeros and NaNs included), not merely close:
#
#  1. Same numbers, same order. Substituting the output index as a SYMBOL instead
#     of a literal changes nothing else — same body, same term order, same
#     `_eval_node`, every leaf in `Float64`. A loop index bound as a `Float64`
#     param equals that index folded to a `Float64` literal.
#  2. Index arithmetic (`_subscripts_int_exact`). A gather subscript that stays
#     symbolic is evaluated in `Float64` and `round(Int, …)`-ed by the
#     `_NK_CONST_GATHER` arm, whereas a folded one goes through `_eval_const_int`
#     in INTEGER arithmetic. Those agree on every op in the index vocabulary
#     except `/`, which is TRUNCATING `div` for `_eval_const_int` and true division
#     in `Float64`. So any `/` under an `index` subscript declines the fast path.
#  3. Boundary policy. An out-of-range subscript is resolved per axis by the
#     array's declared policy on both paths — by `_resolve_const_index` when it
#     folds, by `_const_gather_sub` in the runtime gather, which both hand the
#     out-of-range case to `_resolve_const_index_oob` — so a `:periodic` or
#     `:clamp` axis reads the same element on either, and a plain (`:error`)
#     array raises `E_TREEWALK_CONSTARRAY_OOB` on either.

# Off, the MAP takes the per-cell loop, which is the differential oracle. A
# strict `native` refuses that loop rather than running it (§2.5.10), so the
# comparison is between the two compilers on the same document.
_setup_map_compile_once_disabled() = !_setup_compile_once_enabled()

# Engagement counts (`_count!`, compiler.jl): `:setup_map_fastpath_hit` for a
# MAP a compiled path materialized (the fill of setup_fill.jl or the
# compile-once sweep), `:setup_map_fastpath_miss` for one that fell back to the
# per-cell loop (a decline, or an eval-time error).

# The ops on which `_eval_const_int` (integer) and `_eval_node` (Float64 +
# `round(Int, …)`) can disagree for integer operands. Only `/` qualifies:
# `_eval_const_int` refuses an inexact quotient (`_subscript_quotient`), while
# `_compile` carries the fractional value on, so the two would disagree on
# whether the subscript is an error.
const _INDEX_INEXACT_OPS = Set{String}(["/"])

# True iff no `index` subscript anywhere in `e` uses an op whose integer and
# Float64 readings can differ (guard 2 above). Both walks go through
# `foreach_subexpr_once`, the ONE generated `OPEXPR_FIELD_TABLE` traversal, so a
# subscript hidden in a nested body / filter / value / bound / table axis is seen
# — a hand-rolled `args`-and-a-few-fields walk would silently miss those. (A
# predicate scan is exactly what its identity memo is safe for.)
function _subscripts_int_exact(e::ASTExpr)::Bool
    ok = true
    foreach_subexpr_once(e) do n
        (ok && n isa OpExpr && (n::OpExpr).op == "index") || return
        args = (n::OpExpr).args
        for k in 2:length(args)
            _subtree_free_of(args[k], _INDEX_INEXACT_OPS) && continue
            ok = false
            return
        end
    end
    return ok
end

# True iff no op in the subtree is named in `banned`.
function _subtree_free_of(e::ASTExpr, banned::Set{String})::Bool
    ok = true
    foreach_subexpr_once(e) do n
        (n isa OpExpr && (n::OpExpr).op in banned) && (ok = false)
    end
    return ok
end

# The compile-once cell evaluator for a promoted-physics MAP, or `nothing` to
# keep the per-cell loop. Every decline is silent and lossless — the caller falls
# back to the byte-identical reference path.
function _setup_map_compile_once(
        rhs::OpExpr, nd::Int, ca::AbstractDict,
        params::AbstractDict
    )
    nd >= 1 || return nothing
    _setup_map_compile_once_disabled() && return nothing
    _subscripts_int_exact(rhs) || return nothing
    return _cellwise_compile_once(rhs, nd, ca, params)
end

# Materialize a build-once NON-GEOMETRY MAP aggregate by evaluating its body once
# per output cell through the GENERAL build-time cell pipeline: `_eval_cellwise`
# wraps the MAP as `index(agg, cell…)`, `_resolve_index_of_faq` substitutes the
# output indices, then `_compile`/`_eval_node` run the full scalar language against
# the materialized `env` (its array entries become gatherable const arrays, its
# scalar params bind by name). Byte-identical to the ODE RHS resolver — the twin of
# `_materialize_setup_wholearray`, just ranging over the aggregate's declared
# `output_idx`/`ranges` extents instead of a makearray's regions.
function _materialize_setup_general_map(
        rhs::OpExpr, env::AbstractDict,
        index_sets, derived_extents
    )
    out = String[String(s) for s in rhs.output_idx if s isa AbstractString]
    exts = Int[_geo_index_extent(rhs.ranges[v], index_sets, derived_extents) for v in out]
    ca, params = _setup_env_split(env)
    nd = length(out)
    # ---- Compiled fill (setup_fill.jl) ----
    # The MAP filled through the right-hand-side cascade and emitted code, once.
    # A decline, or a run that raises, leaves the compile-once sweep and the
    # per-cell reference below exactly as they were.
    filled = _setup_fill_array(
        rhs, exts; const_arrays = ca, params = params
    )
    if filled !== nothing
        _count!(:setup_map_fastpath_hit)
        _record_rule!(_current_rule_label(), :setup_array, :setup_codegen)
        return filled
    end
    # ---- Compile-once fast path (see `_setup_map_compile_once` above) ----
    # Resolve+compile the MAP body ONCE with the output indices bound as
    # parameters, then walk the cells rebinding only those. Any decline (⇒
    # `nothing`) or ANY eval-time error keeps the untouched per-cell loop below,
    # so the values and the errors are the per-cell loop's.
    ce = _setup_map_compile_once(rhs, nd, ca, params)
    # The cell the compiled sweep failed at, if it failed: the one cell a strict
    # compiler checks against the per-cell reference before refusing.
    failed_at = Ref{Union{Nothing, Vector{Int}}}(nothing)
    if ce !== nothing
        fast = try
            _fill_map_fast(ce, exts, nd; failed_at = failed_at)
        catch err
            # Anything the compiled tree cannot evaluate (a gather the guards did
            # not anticipate, an unsupported leaf) → the per-cell reference below,
            # which reproduces the original values or the original error. A
            # RESOURCE error is NOT a fallback trigger: a user interrupt asked
            # for this sweep to stop, not to restart on the slower path, and
            # running out of memory or stack says nothing about whether the
            # compiled tree can evaluate this map — the per-cell path allocates
            # the same output array and would only fail again, later and with
            # the cause erased. Path selection for every OTHER error is
            # untouched: still `nothing`, still the per-cell reference.
            _is_resource_error(err) && rethrow()
            nothing
        end
        if fast !== nothing
            _count!(:setup_map_fastpath_hit)
            _record_rule!(_current_rule_label(), :setup_array, :setup_compiled)
            return fast
        end
    end
    _count!(:setup_map_fastpath_miss)
    # A map no form can evaluate is the document's error, not a compiler's
    # refusal, so a strict compiler's probe runs the per-cell reference at one
    # cell, for its diagnostic only, before the refusal is raised: the cell the
    # compiled sweep failed at, or else the first.
    lic = _percell_evaluation_license(
        _current_rule_label(),
        "the setup MAP materializer", prod(exts); one_cell = true,
        probe = pr -> all(>(0), exts) &&
            _eval_cellwise(
            pr, rhs, something(failed_at[], ones(Int, length(exts)));
            const_arrays = ca,
            params = params
        )
    )
    _record_rule!(_current_rule_label(), :setup_array, :setup_percell)
    return _fill_map_percell(lic, rhs, exts, ca, params)
end

# Compile-once cell sweep: one preallocated `cell` buffer, rebound per cell. On
# a throw, `failed_at` holds the cell it was evaluating.
function _fill_map_fast(
        ce, exts::Vector{Int}, nd::Int;
        failed_at::Base.RefValue = Ref{Any}(nothing)
    )
    arr = zeros(Float64, exts...)
    cell = Vector{Int}(undef, nd)
    try
        for I in CartesianIndices(Tuple(exts))
            @inbounds for d in 1:nd
                cell[d] = I[d]
            end
            arr[I] = ce(cell)
        end
    catch
        failed_at[] = copy(cell)
        rethrow()
    end
    return arr
end

# The REFERENCE cell sweep — the original per-cell loop, unchanged. It is both
# the fallback for anything the fast path declines and the oracle a build with
# the compile-once tier off runs.
function _fill_map_percell(
        lic::_PerCellLicense, rhs::OpExpr, exts::Vector{Int},
        ca::AbstractDict,
        params::AbstractDict
    )
    arr = zeros(Float64, exts...)
    for I in CartesianIndices(Tuple(exts))
        arr[I] = _eval_cellwise(
            lic, rhs, Int[Tuple(I)...]; const_arrays = ca,
            params = params
        )
    end
    return arr
end

# ============================================================
# Build-once NON-aggregate whole-array observeds (makearray / reshape)
# ============================================================
# A build-once array observed need not be a `faq` MAP. A discretization
# rule lowers `D(field)` to a `makearray` STENCIL (the `central_D1x/D1y_periodic`
# rules' interior + periodic-boundary regions, each region a nested
# central-difference aggregate over the regridded field), and a shape rewrite may
# emit a `reshape`. Neither carries `output_idx`/`ranges`, so `_materialize_geom_array`
# (which ranges over `output_idx`) cannot evaluate them. Materialize them here
# against the already-materialized `env` (the const arrays + scalar params the
# aggregate path also reads): a `makearray` is evaluated once per output cell
# through the SAME build-time array pipeline the ODE RHS runs for
# `index(makearray,…)` — `_eval_cellwise` (`_index_at_cell` → `_resolve_indices`
# → `_compile` → `_eval_node`) — so its stencil semantics (region selection,
# nested central-difference, periodic wrap) stay byte-identical to the RHS
# resolver; a `reshape` (not an ODE-RHS-evaluable op) materializes its source
# array and reshapes it column-major.

# True iff `rhs` is a whole-array op with no `output_idx`/`ranges` to range over
# — a `makearray` stencil or a `reshape`.
_is_setup_wholearray_op(rhs) =
    rhs isa OpExpr && ((rhs::OpExpr).op == "makearray" || (rhs::OpExpr).op == "reshape")

# Output extents of a build-once makearray/reshape observed. The observed's
# declared shape (index-set names per dim, in `shape_sets`) drives the extents —
# resolved against the document index sets + derived extents, exactly like the
# aggregate path. Fallbacks keep a shapeless op materializable: a makearray's
# per-dimension region maximum (the regions partition the whole output), or a
# reshape's own integer/symbolic target `shape`.
function _setup_wholearray_extents(
        rhs::OpExpr, shape_sets::Vector{String},
        index_sets, derived_extents
    )
    isempty(shape_sets) ||
        return Int[_geo_index_extent(s, index_sets, derived_extents) for s in shape_sets]
    if rhs.op == "makearray"
        regions = rhs.regions === nothing ? Vector{Vector{Vector{Any}}}() : rhs.regions
        isempty(regions) && throw(
            TreeWalkError(
                "E_TREEWALK_GEOMETRY_SETUP",
                "cannot determine makearray output shape at setup (no declared shape, no regions)"
            )
        )
        nd = length(regions[1])
        return Int[maximum(r[d][2] for r in regions) for d in 1:nd]
    end
    shp = rhs.shape
    shp === nothing && throw(
        TreeWalkError(
            "E_TREEWALK_GEOMETRY_SETUP",
            "reshape at setup requires a target `shape`"
        )
    )
    return Int[
        s isa Integer ? Int(s) :
            _geo_index_extent(String(s), index_sets, derived_extents) for s in shp
    ]
end

# Split `env` into the (frozen) const-array registry (its array-valued entries —
# e.g. the regridded `elev_xy`) and the scalar-parameter scope (its Real entries —
# the grid spacing `dx`/`dy`, offsets, …) the build-time cell pipeline reads.
function _setup_env_split(env::AbstractDict)
    ca = Dict{String, AbstractArray{Float64}}()
    params = Dict{String, Float64}()
    for (k, v) in env
        ks = String(k)
        if v isa AbstractArray{Float64}
            ca[ks] = v
        elseif v isa AbstractArray && eltype(v) <: Real
            ca[ks] = Array{Float64}(v)
        elseif v isa Real
            params[ks] = Float64(v)
        end
        # A non-numeric array in `env` — e.g. an untyped key-column buffer a
        # broad-phase equi-join reads directly from `env` — is neither a
        # gatherable Float64 const array nor a scalar param for the physics cell
        # pipeline, so skip it.
    end
    return ca, params
end

# Materialize a build-once `makearray` / `reshape` observed into a dense array
# against the already-materialized `env`.
#
#  * `makearray` — the stencil form a discretization rule lowers `D(field)` to.
#    Evaluate it once per output cell through `_eval_cellwise` (`_index_at_cell`
#    → `_resolve_indices` → `_compile` → `_eval_node`), the SAME build-time array
#    pipeline the ODE RHS runs for `index(makearray, …)`, so the region selection,
#    nested central-difference and periodic wrap stay byte-identical to the RHS
#    resolver.
#  * `reshape` — NOT an ODE-RHS-evaluable op, so materialize its SOURCE array
#    (`args[1]`, itself a setup array / aggregate / makearray) to a dense array and
#    reshape column-major (matching the numpy reference `reshape([1..6],[2,3])`
#    with `M[1,2]==3`) to the declared target shape.
function _materialize_setup_wholearray(
        rhs::OpExpr, env::AbstractDict,
        index_sets, derived_extents,
        shape_sets::Vector{String}
    )
    exts = _setup_wholearray_extents(rhs, shape_sets, index_sets, derived_extents)
    if rhs.op == "reshape"
        isempty(rhs.args) && throw(
            TreeWalkError(
                "E_TREEWALK_GEOMETRY_SETUP",
                "reshape at setup requires a source array operand"
            )
        )
        src = _setup_source_array(
            rhs.args[1], env, index_sets, derived_extents
        )
        length(src) == prod(exts) || throw(
            TreeWalkError(
                "E_TREEWALK_GEOMETRY_SETUP",
                "reshape source has $(length(src)) elements but target shape needs $(prod(exts))"
            )
        )
        return reshape(Array{Float64}(src), exts...)   # column-major, numpy-parity
    end
    ca, params = _setup_env_split(env)
    # The compiled form: the stencil filled through the right-hand-side cascade
    # and emitted code, once (setup_fill.jl) — the same lowering an
    # `index(makearray, …)` in the right-hand side gets, region selection
    # included.
    arr = _setup_fill_array(
        rhs, exts; const_arrays = ca, params = params
    )
    if arr !== nothing
        _record_rule!(_current_rule_label(), :setup_array, :setup_codegen)
        return arr
    end
    # Otherwise the stencil is resolved and compiled from scratch at every
    # output cell. A strict compiler refuses that once its probe has evaluated
    # the first cell, so that a stencil no form can evaluate raises the
    # document's own error instead.
    lic = _percell_evaluation_license(
        _current_rule_label(),
        "the whole-array setup materializer", prod(exts); one_cell = true,
        probe = pr -> all(>(0), exts) &&
            _eval_cellwise(
            pr, rhs, ones(Int, length(exts)); const_arrays = ca, params = params
        )
    )
    _record_rule!(_current_rule_label(), :setup_array, :setup_percell)
    return _fill_map_percell(lic, rhs, exts, ca, params)
end

# The dense source array of a setup-time `reshape`: a bare reference to an
# already-materialized setup / const array in `env`, or an inline array producer
# (an aggregate map / a nested makearray) materialized in place.
function _setup_source_array(
        src, env, index_sets, derived_extents
    )
    if src isa VarExpr && haskey(env, src.name) && env[src.name] isa AbstractArray
        return env[src.name]
    elseif src isa OpExpr && _is_faq_op(src.op) &&
            src.output_idx !== nothing && !isempty(src.output_idx)
        return _materialize_geom_array(src, env, index_sets, derived_extents)
    elseif src isa OpExpr && _is_setup_wholearray_op(src)
        return _materialize_setup_wholearray(
            src, env, index_sets, derived_extents,
            String[]
        )
    end
    throw(
        TreeWalkError(
            "E_TREEWALK_GEOMETRY_SETUP",
            "reshape source must be a build-once array (a setup/const array reference " *
                "or an inline array producer) at setup"
        )
    )
end

# A materialized value-invention join column (`Dict(position => integer key)`,
# the `src_bx`/`tgt_bx` broad-phase bins) as a dense vector the setup-time join
# gate indexes by loop position. Keys are 1-based positions over the column's
# 1-D index set (`_vi_materialize_column!`); the values are the integer keys,
# compared only for equality by the gate.
function _vi_buf_vector(buf)
    isempty(buf) && return Any[]
    # Keys of one concrete type at the positions 1:n are stored as that type,
    # so the gate's per-pair comparison is not a dynamic dispatch.
    typed = _vi_buf_typed(buf, typeof(first(values(buf))))
    typed === nothing || return typed
    n = maximum(Int(k) for k in keys(buf))
    v = Vector{Any}(undef, n)
    for (k, val) in buf
        v[Int(k)] = val
    end
    return v
end

function _vi_buf_typed(buf, ::Type{T}) where {T}
    isconcretetype(T) || return nothing
    n = length(buf)
    v = Vector{T}(undef, n)
    seen = falses(n)
    for (k, val) in buf
        (k isa Int && 1 <= k <= n && !seen[k] && val isa T) || return nothing
        seen[k] = true
        v[k] = val
    end
    return v
end

# The shared setup-time value environment (name → const array / scalar / bin
# buffer) both build-time materializers read. Effective precedence, HIGHEST
# first:
#   vi_maps  >  param_overrides  >  scalar-param defaults  >  const_arrays_kw
#            >  in-file `const`-op array observeds  >  const_obs_arrays
# This one assembly serves both former copies because their outcomes were
# already identical: `_materialize_geometry_setup` seeded kwarg-first and
# guarded the `const`-op pass with `haskey` (kwarg wins); `_derive_binning_coords`
# seeded `const`-op-first and let the kwarg pass overwrite (kwarg wins) — the
# same final map for every key, differing only in Dict insertion order, which
# nothing reads (every consumer does keyed lookups). The sources the binning
# derivation never passes (`const_obs_arrays`, `vi_maps`) default to `nothing`
# = skipped.
#
# Source notes (hoisted from the two call sites):
#  * `const`-op array observeds (in-file polygon ring stacks / fields) are
#    build-time literal data, seeded so an overlap-area aggregate can gather a
#    per-cell ring via `index(src_poly, i)` at setup.
#  * `const_obs_arrays` — resolved BARE-ALIAS const arrays
#    (`src_poly := mesh.src_poly`) and other already-materialized const-op
#    array observeds: a setup var reads the alias's VALUE from `env` (the alias
#    is registered as a const array, never materialized as an aggregate).
#  * scalar parameter OVERRIDES win over declared defaults: a setup-time node
#    may reference `atol`/`dx`/`dy` (sliver floor / bin quantization) — known
#    build-time constants that often have no `default`.
#  * `vi_maps` — materialized value-invention join columns (`src_bx`/`tgt_bx`)
#    a setup-time broad-phase `join` gates on; without the gate the denominator
#    row-sum contracts DENSELY and picks up spurious sub-grid slivers, breaking
#    the partition of unity (RFC §5.3 / §5.8).
function _build_setup_env(
        model, const_arrays_kw;
        param_overrides = Dict{String, Float64}(),
        const_obs_arrays = nothing, vi_maps = nothing
    )
    env = Dict{String, Any}()
    for (k, v) in const_arrays_kw
        env[String(k)] = v isa AbstractArray ? _dynamic(Array{Float64}, v)::Array{Float64} : v
    end
    for (n, defn) in observed_definitions(model)
        v = model.variables[n]
        (_is_array_shape(v.shape) && _is_const_op(defn)) || continue
        haskey(env, n) && continue
        env[n] = _const_op_to_array((defn::OpExpr).value)
    end
    if const_obs_arrays !== nothing
        for (n, v) in const_obs_arrays
            haskey(env, n) && continue
            env[n] = v
        end
    end
    for (n, v) in model.variables
        v.type == ParameterVariable && !_is_array_shape(v.shape) && v.default !== nothing &&
            (env[n] = Float64(v.default))
    end
    for (k, v) in param_overrides
        # esm-spec §6.6.2: a SHAPED parameter's override is INLINE ARRAY DATA —
        # build-time data the setup evaluator gathers, exactly like a `const`-op
        # array observed above, not a scalar to coerce.
        env[String(k)] = v isa AbstractArray ? _dynamic(Array{Float64}, v)::Array{Float64} : Float64(v)
    end
    if vi_maps !== nothing
        for (name, buf) in vi_maps
            env[String(name)] = _vi_buf_vector(buf)
        end
    end
    return env
end

# Declared shapes (index-set names per dim) — used to resolve join key columns.
function _declared_var_shapes(model)
    var_shapes = Dict{String, Vector{String}}()
    for (n, v) in model.variables
        v.shape === nothing && continue
        var_shapes[n] = String[String(s) for s in v.shape if s isa AbstractString]
    end
    return var_shapes
end

# Evaluate the geometry-setup vars in dependency order into const arrays.
# `vi_maps` carries any materialized value-invention bin buffers a setup-time
# broad-phase `join` gates on (RFC §5.3); `param_overrides` carries scalar
# parameter values (e.g. a sliver-filter `atol`, the bin width `dx`/`dy`) so a
# setup-time `filter`/quantization that references them resolves.
function _materialize_geometry_setup(
        setup, defs, model, const_arrays_kw,
        index_sets, derived_extents;
        vi_maps = Dict{String, Any}(),
        param_overrides = Dict{String, Float64}(),
        const_obs_arrays = Dict{String, Array{Float64}}()
    )
    out = Dict{String, AbstractArray{Float64}}()
    isempty(setup) && return out
    env = _build_setup_env(
        model, const_arrays_kw;
        param_overrides = param_overrides,
        const_obs_arrays = const_obs_arrays, vi_maps = vi_maps
    )
    var_shapes = _declared_var_shapes(model)
    # One broad-phase candidate index per distinct `overlap` clause, shared
    # across this pass (`_geo_overlap_index`). A conservative regrid resolves the
    # same `(src_poly, tgt_poly, eps)` clause once for the weight matrix and once
    # per applied species; building the candidate set six times, and its adjacency
    # views six times, is pure waste. Scoped to this call, where a name→array
    # binding in `env` is written once and never replaced.
    ov_cache = Dict{Tuple{Vector{String}, Vector{String}, Float64}, _OverlapIndex}()
    # Likewise one bin-equality match index per pair of key columns (the env
    # buffers stay bound, so their identities are stable for the pass).
    eq_cache = Dict{Tuple{UInt, UInt, Int, Int}, Union{Nothing, _OverlapIndex}}()
    # And one native body function per kernel shape (`_GeoKernelCache`): sweeps
    # that differ only in their source arrays (one template site per ring pair)
    # share it.
    kernel_cache = _GeoKernelCache()
    for n in _geom_setup_order(setup, defs)
        rhs = defs[n]
        _open_rule!(n, :setup_array)
        arr = if _is_setup_wholearray_op(rhs)
            # A `makearray` stencil (a `D(field)` lowering) or `reshape` — no
            # `output_idx`/`ranges` to range over. Evaluate per output cell via the
            # general build-time array pipeline against the materialized `env`.
            _materialize_setup_wholearray(
                rhs, env, index_sets, derived_extents,
                get(var_shapes, n, String[])
            )
        elseif _is_setup_general_map(rhs)
            # A promoted PER-CELL PHYSICS lookup (fuel/moisture/wind over the fire
            # grid): a pure MAP aggregate whose body reaches an op OUTSIDE the
            # geometry-FAQ vocabulary (`and`/`ifelse`/`const`/`exp`/
            # `log`). Materialize it through the general build-time cell evaluator (as
            # the makearray path does), byte-identical to the ODE RHS resolver. Every
            # geometry aggregate (a geometry weight, a contraction, a constructed ring,
            # a reindex — all `_GEO_EVAL_OPS`) fails `_is_setup_general_map` and falls
            # through to the compiled geometry materializer below.
            _materialize_setup_general_map(
                rhs, env, index_sets, derived_extents
            )
        else
            _materialize_geom_array(
                rhs, env, index_sets, derived_extents, var_shapes;
                ov_cache = ov_cache, eq_cache = eq_cache, kernel_cache = kernel_cache
            )
        end
        env[n] = arr
        out[n] = arr
    end
    return out
end
