# Discretization pipeline per discretization RFC §11 (gt-gbs2) and
# DAE support / binding contract per RFC §12 (gt-q7sh).
#
# The public entry point is `discretize(esm::AbstractDict)`, which walks a
# parsed ESM document and emits a discretized ESM:
#
#   1. Canonicalize all expressions (§5.4).
#   2. Resolve model-level boundary conditions into a synthetic `bc` op so
#      they flow through the same rule engine as interior equations.
#   3. Apply the rule engine (§5.2) to every equation RHS and every BC
#      value with a max-pass budget.
#   4. Re-canonicalize the rewritten ASTs.
#   5. Check for unrewritten PDE ops (§11 Step 7) — error or
#      passthrough-annotate depending on `strict_unrewritten`.
#   6. RFC §12: classify each equation as `differential` vs `algebraic`
#      (LHS `D(x, wrt=<indep>)` versus anything else), count algebraic
#      equations across all models, stamp `metadata.system_class` on the
#      output (`"ode"` or `"dae"`), and either hand the DAE off to the
#      host assembler or abort with `E_NO_DAE_SUPPORT` per the
#      `dae_support` knob.
#   7. Record `metadata.discretized_from` provenance.
#
# Scheme-expansion of `use:<scheme>` rules (§7.2.1) is deferred to Step 1b
# and is out of scope here. Cross-grid `regrid` wrapping is likewise out
# of scope. The Julia binding's DAE **strategy** is direct hand-off to
# ModelingToolkit.jl, which natively accepts mixed differential/algebraic
# equation sets; we do not attempt index reduction here. See
# `docs/rfcs/discretization.md` §12 and `docs/rfcs/dae-binding-strategies.md`
# for the normative per-binding strategies.

"""
    discretize(esm::AbstractDict; max_passes::Int=32, strict_unrewritten::Bool=true,
               dae_support::Bool=true, lift_1d_arrayop::Bool=false) -> Dict{String,Any}

Run the RFC §11 discretization pipeline on an ESM document and apply
the RFC §12 DAE binding contract.

`esm` is the parsed ESM payload as a `Dict{String,Any}` (the form produced
by [`load`](@ref) followed by `_to_native_json`, or by direct JSON
decoding). The function returns a new `Dict{String,Any}`; the input is not
mutated.

Behavior:

- Every equation in every model, and every boundary condition `value`
  expression, is first canonicalized per §5.4, then rewritten by the rule
  engine built from `esm["rules"]` (optional top-level, per RFC §5.2) plus
  any per-model `rules`, then canonicalized again.
- `max_passes` is the per-expression rule-engine budget (§5.2.5).
- With `strict_unrewritten=true` (the default) a rewritten expression that
  still carries a PDE op (`grad`, `div`, `laplacian`, `D`, `bc`) raises
  [`RuleEngineError`](@ref) with code `E_UNREWRITTEN_PDE_OP`. With
  `strict_unrewritten=false` the offending equation/BC is instead marked
  `passthrough: true` and retained verbatim.
- After the pipeline, every equation is classified as either
  `differential` (LHS is `D(x, wrt=<independent_variable>)`) or
  `algebraic` (anything else — includes `produces: algebraic` output
  once rule `produces` lands, and authored non-differential equations).
  The total and per-model algebraic counts are written to the top-level
  `metadata.dae_info` (`{algebraic_equation_count, per_model}`), and
  `metadata.system_class` is set to `"dae"` if any model has at least
  one algebraic equation, else `"ode"`. (Model schemas use
  `additionalProperties: false`, so the counts live only on the
  top-level metadata, not inside each model.)
- If any model contains algebraic equations **and** `dae_support=false`
  (or the environment variable `ESM_DAE_SUPPORT=0`), `discretize` throws
  [`RuleEngineError`](@ref) with code `E_NO_DAE_SUPPORT`. The message
  names the first model and algebraic equation path found. Per RFC §12
  the Julia binding's default strategy is direct DAE hand-off to
  ModelingToolkit, so `dae_support=true` is the normal setting.
- `metadata.discretized_from` is set on the output to the input's
  `metadata.name`.
- With `lift_1d_arrayop=true`, differential equations for 1-dimensional
  array variables are lifted to arrayop form just like multidimensional
  ones. The default (`false`) preserves the bare `D(var, wrt=t)` LHS for
  1D variables, which the committed cross-binding discretize goldens
  encode; opt in when the consumer evaluates through the tree-walk
  arrayop path (e.g. the EarthSciDiscretizations Layer-B conformance
  walker).
"""
function discretize(esm::AbstractDict;
                    max_passes::Int = 32,
                    strict_unrewritten::Bool = true,
                    dae_support::Bool = _default_dae_support(),
                    lift_1d_arrayop::Bool = false,
                    source_path::Union{String,Nothing} = nothing)::Dict{String,Any}
    out = _deep_native(esm)
    out isa Dict{String,Any} || throw(ArgumentError(
        "discretize: input must be a JSON object / Dict; got $(typeof(esm))"))

    base_path = source_path !== nothing ? dirname(abspath(source_path)) : ""

    # Parse rules declared at the top level.
    top_rules = _load_rules(get(out, "rules", nothing))

    ctx = _build_rule_context(out, base_path)

    models = get(out, "models", nothing)
    if models isa AbstractDict
        for (mname, mraw) in models
            model = mraw isa Dict{String,Any} ? mraw : Dict{String,Any}(String(k) => v for (k, v) in mraw)
            _discretize_model!(String(mname), model, top_rules, ctx,
                               max_passes, strict_unrewritten, lift_1d_arrayop)
            models[mname] = model
        end
    end

    # RFC §12 — DAE classification + binding contract.
    _apply_dae_contract!(out, dae_support)

    _record_discretized_from!(out)
    return out
end

# Default `dae_support` honors the `ESM_DAE_SUPPORT` env var (RFC §12 says
# bindings MAY expose either an env var or a binding-specific flag; Julia
# exposes both). Any falsy value ("0", "false", "off", "no") disables.
function _default_dae_support()::Bool
    raw = get(ENV, "ESM_DAE_SUPPORT", nothing)
    raw === nothing && return true
    v = lowercase(strip(String(raw)))
    return !(v in ("0", "false", "off", "no"))
end

# ============================================================================
# Rule-context assembly (grids + variables)
# ============================================================================

function _build_rule_context(esm::Dict{String,Any}, base_path::String = "")::RuleContext
    grids = Dict{String,Dict{String,Any}}()
    grids_raw = get(esm, "grids", nothing)
    if grids_raw isa AbstractDict
        for (gname, graw) in grids_raw
            grids[String(gname)] = _extract_grid_meta(graw)
        end
    end

    variables = Dict{String,Dict{String,Any}}()
    models = get(esm, "models", nothing)
    if models isa AbstractDict
        for (_, mraw) in models
            mgrid = _string_or_nothing_any(get(mraw, "grid", nothing))
            vars = get(mraw, "variables", nothing)
            vars isa AbstractDict || continue
            for (vname, vraw) in vars
                meta = Dict{String,Any}()
                if mgrid !== nothing
                    meta["grid"] = mgrid
                end
                shape = get(vraw, "shape", nothing)
                if shape !== nothing
                    meta["shape"] = shape
                end
                loc = get(vraw, "location", nothing)
                if loc !== nothing
                    meta["location"] = String(loc)
                end
                variables[String(vname)] = meta
            end
        end
    end
    schemes = parse_schemes(get(esm, "discretizations", nothing), base_path)
    return RuleContext(grids, variables, Dict{String,Int}(), nothing,
                       Dict{String,Vector{Dict{String,Int}}}(), schemes)
end

function _extract_grid_meta(graw)::Dict{String,Any}
    meta = Dict{String,Any}()
    dims_raw = get(graw, "dimensions", nothing)
    if dims_raw isa AbstractVector
        spatial = String[]
        periodic = String[]
        nonuniform = String[]
        dim_sizes = Dict{String,Int}()
        for d in dims_raw
            name = get(d, "name", nothing)
            name === nothing && continue
            push!(spatial, String(name))
            periodicity = get(d, "periodic", nothing)
            if periodicity === true
                push!(periodic, String(name))
            end
            spacing = get(d, "spacing", nothing)
            if spacing isa AbstractString && String(spacing) in ("nonuniform", "stretched")
                push!(nonuniform, String(name))
            elseif spacing === "nonuniform" || spacing == "nonuniform"
                push!(nonuniform, String(name))
            end
            sz = get(d, "size", nothing)
            if sz isa Integer
                dim_sizes[String(name)] = Int(sz)
            end
        end
        meta["spatial_dims"] = spatial
        meta["periodic_dims"] = periodic
        meta["nonuniform_dims"] = nonuniform
        meta["dim_sizes"] = dim_sizes
    end
    # §6.2.1 — collect metric array names for nonuniform dimension rewrites
    metric_arrays_raw = get(graw, "metric_arrays", nothing)
    if metric_arrays_raw isa AbstractDict
        meta["metric_array_names"] = String[String(k) for k in keys(metric_arrays_raw)]
    else
        meta["metric_array_names"] = String[]
    end
    return meta
end

_string_or_nothing_any(x) = x === nothing ? nothing : String(x)

# ============================================================================
# Model-level pipeline
# ============================================================================

function _discretize_model!(mname::String, model::Dict{String,Any},
                             top_rules::Vector{Rule}, ctx::RuleContext,
                             max_passes::Int, strict_unrewritten::Bool,
                             lift_1d_arrayop::Bool = false)
    # Clear emission buffers from any previous model (ctx is shared per document).
    empty!(ctx.emitted_equations)
    empty!(ctx.emitted_variables)
    empty!(ctx.emitted_scheme_keys)

    # Collect rules: model-local overrides/extends top-level.
    local_rules_raw = get(model, "rules", nothing)
    local_rules = _load_rules(local_rules_raw)
    rules = isempty(local_rules) ? top_rules : vcat(top_rules, local_rules)

    # Per-model max_passes override (§5.2.5).
    mp = _lookup_max_passes(model, max_passes)

    # Equations
    eqns = get(model, "equations", nothing)
    if eqns isa AbstractVector
        for (i, eqn_any) in enumerate(eqns)
            eqn = eqn_any isa Dict{String,Any} ? eqn_any :
                Dict{String,Any}(String(k) => v for (k, v) in eqn_any)
            _discretize_equation!("models.$mname.equations[$i]", eqn,
                                   rules, ctx, mp, strict_unrewritten)
            eqns[i] = eqn
        end
    end

    # Boundary conditions (model-level). Processed BEFORE arrayop lifting so
    # the lift can consume the rewritten BC values when emitting boundary-cell
    # equations on non-periodic dimensions (ess-gp3).
    bcs = get(model, "boundary_conditions", nothing)
    if bcs isa AbstractDict
        for (bc_name, bc_any) in bcs
            bc = bc_any isa Dict{String,Any} ? bc_any :
                Dict{String,Any}(String(k) => v for (k, v) in bc_any)
            _discretize_bc!("models.$mname.boundary_conditions.$bc_name",
                             bc, rules, ctx, mp, strict_unrewritten)
            bcs[bc_name] = bc
        end
    end

    # Inject observed equations and auto-declared variables emitted by
    # multi_output_stencil trigger 1 expansion (RFC §7.9, ess-ebe).
    # These are appended before arrayop lifting so the lift sees the full
    # equation list. Observed arrayop equations have a non-D(…) LHS and
    # are skipped by _try_arrayop_lift_equation! (which only lifts D(v,wrt=t)).
    if !isempty(ctx.emitted_equations)
        existing = get(model, "equations", Any[])
        model["equations"] = vcat(existing, ctx.emitted_equations)
    end
    if !isempty(ctx.emitted_variables)
        vars = _ensure_dict!(model, "variables")
        for (vname, vmeta) in ctx.emitted_variables
            haskey(vars, vname) && continue  # author pre-declared: don't overwrite
            vars[vname] = vmeta
            # Register in ctx.variables so guard checks and subsequent rewrite
            # passes (if any) can resolve the new variable's metadata.
            vgrid = get(model, "grid", nothing)
            vmeta_ctx = Dict{String,Any}()
            vgrid !== nothing && (vmeta_ctx["grid"] = String(vgrid))
            shape = get(vmeta, "shape", nothing)
            shape !== nothing && (vmeta_ctx["shape"] = shape)
            loc   = get(vmeta, "location", nothing)
            loc   !== nothing && (vmeta_ctx["location"] = String(loc))
            ctx.variables[vname] = vmeta_ctx
        end
    end

    # Arrayop lifting: wrap array-variable differential equations in arrayop
    # after the rule engine rewrites PDE ops to stencil/index form. On
    # non-periodic dimensions with declared dirichlet/neumann BCs, the
    # interior arrayop range shrinks by the stencil reach and per-cell
    # boundary equations are emitted (ess-gp3).
    _arrayop_lift_equations!(model, ctx.grids, ctx.variables; lift_1d = lift_1d_arrayop)
end

function _lookup_max_passes(model::Dict{String,Any}, default::Int)::Int
    rules_meta = get(model, "rules_config", nothing)
    if rules_meta isa AbstractDict
        mp = get(rules_meta, "max_passes", nothing)
        mp isa Integer && return Int(mp)
    end
    return default
end

# ============================================================================
# Arrayop lifting: wrap array-variable differential equations in arrayop form
# ============================================================================

# Canonical index variable names for arrayop iteration (dimension position → name).
const _ARRAYOP_INDEX_NAMES = ("i", "j", "k", "l", "m", "n")

function _arrayop_lift_equations!(model::Dict{String,Any},
                                   grids::Dict{String,Dict{String,Any}},
                                   variables::Dict{String,Dict{String,Any}};
                                   lift_1d::Bool = false)
    eqns = get(model, "equations", nothing)
    eqns isa AbstractVector || return
    bcs = get(model, "boundary_conditions", nothing)
    new_eqns = Any[]
    for eqn_any in eqns
        eqn = eqn_any isa Dict{String,Any} ? eqn_any :
            Dict{String,Any}(String(k) => v for (k, v) in eqn_any)
        info = _try_arrayop_lift_equation!(eqn, grids, variables; lift_1d = lift_1d)
        push!(new_eqns, eqn)
        if info !== nothing && bcs isa AbstractDict && !isempty(bcs)
            append!(new_eqns,
                    _apply_nonperiodic_bcs!(eqn, info, bcs, grids, variables))
        end
    end
    model["equations"] = new_eqns
end

# Lift a scalar-LHS differential equation for an N-dimensional array variable to
# arrayop form. Conditions:
#   1. LHS is D(var_name, wrt=<indep>) where var_name is a plain VarExpr.
#   2. var_name has a "shape" vector of length ≥ 1 in the variable metadata.
#   3. The variable's grid carries "dim_sizes" for every shape dimension.
# When all conditions hold, wraps both LHS and RHS in arrayop nodes with ranges
# derived from the grid dimension sizes, using canonical index names i, j, k, …
function _try_arrayop_lift_equation!(eqn::Dict{String,Any},
                                      grids::Dict{String,Dict{String,Any}},
                                      variables::Dict{String,Dict{String,Any}};
                                      lift_1d::Bool = false)
    lhs_raw = get(eqn, "lhs", nothing)
    lhs_raw === nothing && return

    lhs_expr = try parse_expression(lhs_raw) catch; return end
    lhs_expr isa OpExpr || return
    lhs_expr.op == "D" || return
    length(lhs_expr.args) == 1 || return
    var_arg = lhs_expr.args[1]
    var_arg isa VarExpr || return
    var_name = var_arg.name

    vmeta = get(variables, var_name, nothing)
    vmeta === nothing && return
    shape = get(vmeta, "shape", nothing)
    shape === nothing && return
    shape isa AbstractVector && !isempty(shape) || return
    ndims = length(shape)
    # By default only multidimensional (ndims > 1) variables are lifted to
    # arrayop form; 1D array variables preserve the bare D(var, wrt=t) LHS
    # form that the committed cross-binding discretize goldens encode.
    # `lift_1d=true` opts a caller into lifting 1D variables too (for the
    # tree-walk arrayop evaluation path).
    ndims > 1 || lift_1d || return
    ndims > length(_ARRAYOP_INDEX_NAMES) && return

    grid_name = get(vmeta, "grid", nothing)
    grid_name === nothing && return
    gmeta = get(grids, grid_name, nothing)
    gmeta === nothing && return
    dim_sizes = get(gmeta, "dim_sizes", nothing)
    dim_sizes isa AbstractDict || return

    output_idx = Any[]
    ranges = Dict{String,Any}()
    for d in 1:ndims
        dim_name = String(shape[d])
        sz = get(dim_sizes, dim_name, nothing)
        sz isa Integer || return
        idx = _ARRAYOP_INDEX_NAMES[d]
        push!(output_idx, idx)
        ranges[idx] = Any[1, Int(sz)]
    end

    # Build index args: [var_name, idx1, idx2, ...]
    index_args = Any[var_name]
    for idx in output_idx
        push!(index_args, idx)
    end

    # New LHS: arrayop{D(index(var, i, j, ...), wrt=t)}
    eqn["lhs"] = Dict{String,Any}(
        "op"         => "arrayop",
        "args"       => Any[],
        "output_idx" => output_idx,
        "expr"       => Dict{String,Any}(
            "op"   => "D",
            "args" => Any[Dict{String,Any}("op" => "index", "args" => index_args)],
            "wrt"  => lhs_expr.wrt === nothing ? "t" : lhs_expr.wrt,
        ),
        "ranges"     => ranges,
    )

    # Wrap existing (already-rewritten) RHS in arrayop.
    # For periodic grid dimensions, fold stencil boundary accesses like u[0,j]
    # into u[N,j] using ifelse-based modular arithmetic evaluated at
    # scalarization time. This avoids relying on MTK/Symbolics ghost-cell
    # behaviour for periodic BCs.
    rhs_raw = get(eqn, "rhs", nothing)
    rhs_raw === nothing && return
    # Keep a pre-fold copy: boundary-cell emission (ess-gp3) instantiates the
    # stencil at literal indices and must see raw i±k offsets, not the
    # periodic ifelse wrappers.
    rhs_prefold = _deep_native(rhs_raw)

    periodic_dims = get(gmeta, "periodic_dims", nothing)
    if periodic_dims isa AbstractVector && !isempty(periodic_dims)
        # Fold EVERY shaped variable on this grid, not just the equation's
        # LHS variable: a stencil RHS may index other fields (e.g. a
        # space-varying velocity in an advection rule), and an unfolded
        # out-of-range read would silently hit the zero-ghost convention
        # instead of wrapping.
        var_periodic_sizes = Dict{String,Vector{Tuple{Int,Bool}}}()
        for (vname, vm) in variables
            vshape = get(vm, "shape", nothing)
            vshape isa AbstractVector && !isempty(vshape) || continue
            get(vm, "grid", nothing) == grid_name || continue
            dims_info = Tuple{Int,Bool}[]
            all_found = true
            for d in eachindex(vshape)
                dim_name = String(vshape[d])
                sz = get(dim_sizes, dim_name, nothing)
                sz isa Integer || (all_found = false; break)
                is_periodic = dim_name in (String(p) for p in periodic_dims)
                push!(dims_info, (Int(sz), is_periodic))
            end
            if all_found && any(d -> d[2], dims_info)
                var_periodic_sizes[String(vname)] = dims_info
            end
        end
        if !isempty(var_periodic_sizes)
            _apply_periodic_folding!(rhs_raw, var_periodic_sizes)
        end
    end

    eqn["rhs"] = Dict{String,Any}(
        "op"         => "arrayop",
        "args"       => Any[],
        "output_idx" => output_idx,
        "expr"       => rhs_raw,
        "ranges"     => ranges,
    )

    wrt = lhs_expr.wrt === nothing ? "t" : lhs_expr.wrt
    return (var_name = var_name,
            shape = String[String(s) for s in shape],
            grid_name = String(grid_name),
            output_idx = String[String(ix) for ix in output_idx],
            rhs_prefold = rhs_prefold,
            wrt = wrt)
end

# ============================================================================
# Non-periodic boundary conditions on lifted arrayop equations (ess-gp3)
# ============================================================================
#
# For a lifted equation whose variable has declared dirichlet/neumann BCs on
# a non-periodic dimension, shrink the interior arrayop range on that side by
# the stencil reach and emit one scalar equation per excluded boundary cell
# (the tests/fixtures/arrayop/15_discretized_1d_heat.esm pattern): the
# stencil is instantiated at the literal cell indices, with out-of-range
# (ghost) reads resolved per the read variable's BC —
#
#   dirichlet  → the ghost read is replaced by the BC `value` expression
#   neumann 0  → the ghost read mirrors back in range (zero-flux:
#                u[1-k] := u[k], u[2N+1-e] := u[e])
#
# Reads of periodic dimensions wrap numerically. Ghost reads with no
# declared BC keep the zero-ghost convention (current behavior), so models
# without BC declarations are byte-identical to before. Nonzero-Neumann and
# other BC kinds on a lifted bounded dimension raise E_BC_UNSUPPORTED rather
# than being silently ignored.
function _apply_nonperiodic_bcs!(eqn::Dict{String,Any}, info::NamedTuple,
                                  bcs::AbstractDict,
                                  grids::Dict{String,Dict{String,Any}},
                                  variables::Dict{String,Dict{String,Any}})
    gmeta = get(grids, info.grid_name, nothing)
    gmeta isa AbstractDict || return Any[]
    dim_sizes = get(gmeta, "dim_sizes", nothing)
    dim_sizes isa AbstractDict || return Any[]
    periodic = Set{String}(String.(get(gmeta, "periodic_dims", Any[])))

    # BC map: (variable, dim_name, :min|:max) → (kind, value). Side names
    # follow the "<dim>min"/"<dim>max" convention.
    bc_map = Dict{Tuple{String,String,Symbol},Tuple{String,Any}}()
    for bcname in sort!(collect(String.(keys(bcs))))
        bc = bcs[bcname]
        bc isa AbstractDict || continue
        v = get(bc, "variable", nothing)
        k = get(bc, "kind", nothing)
        s = get(bc, "side", nothing)
        (v isa AbstractString && k isa AbstractString && s isa AbstractString) || continue
        for dn_any in keys(dim_sizes)
            dn = String(dn_any)
            if String(s) == dn * "min"
                bc_map[(String(v), dn, :min)] = (String(k), get(bc, "value", 0))
            elseif String(s) == dn * "max"
                bc_map[(String(v), dn, :max)] = (String(k), get(bc, "value", 0))
            end
        end
    end
    isempty(bc_map) && return Any[]

    var    = info.var_name
    shape  = info.shape
    idxs   = info.output_idx
    nd     = length(shape)
    sizes  = Int[Int(dim_sizes[shape[d]]) for d in 1:nd]

    # Stencil reach per canonical index variable (max |offset| across every
    # index read in the pre-fold RHS).
    reach = Dict{String,Int}(ix => 0 for ix in idxs)
    _scan_stencil_reach!(reach, info.rhs_prefold)

    lo = ones(Int, nd)
    hi = copy(sizes)
    bounded = falses(nd)
    for d in 1:nd
        dn = shape[d]
        dn in periodic && continue
        r = get(reach, idxs[d], 0)
        for (sym, isback) in ((:min, false), (:max, true))
            entry = get(bc_map, (var, dn, sym), nothing)
            entry === nothing && continue
            kind, value = entry
            _check_bc_supported(kind, value, var, dn)
            r == 0 && continue   # no ghost reads on this dim; nothing to emit
            if isback
                hi[d] = sizes[d] - r
            else
                lo[d] = 1 + r
            end
            bounded[d] = true
        end
    end
    any(bounded) || return Any[]
    for d in 1:nd
        lo[d] <= hi[d] || throw(RuleEngineError("E_BC_GRID_TOO_SMALL",
            "dimension '$(shape[d])' (size $(sizes[d])) is too small for the " *
            "stencil reach $(get(reach, idxs[d], 0)) with boundary conditions " *
            "on both sides"))
    end

    # Shrink the interior arrayop on the bounded dims (lhs + rhs wrappers).
    for d in 1:nd
        bounded[d] || continue
        eqn["lhs"]["ranges"][idxs[d]] = Any[lo[d], hi[d]]
        eqn["rhs"]["ranges"][idxs[d]] = Any[lo[d], hi[d]]
    end

    # Emit one scalar equation per excluded boundary cell.
    extra = Any[]
    for cell in Iterators.product((1:sizes[d] for d in 1:nd)...)
        all(d -> lo[d] <= cell[d] <= hi[d], 1:nd) && continue
        fixed = Dict{String,Int}(idxs[d] => cell[d] for d in 1:nd)
        rhs_cell = _instantiate_bc_cell(info.rhs_prefold, fixed, variables,
                                        dim_sizes, periodic, bc_map)
        lhs_cell = Dict{String,Any}(
            "op"   => "D",
            "args" => Any[Dict{String,Any}(
                "op" => "index", "args" => Any[var, cell...])],
            "wrt"  => info.wrt,
        )
        push!(extra, Dict{String,Any}(
            "_comment" => "boundary cell $(var)[$(join(cell, ','))] emitted from boundary_conditions (ess-gp3)",
            "lhs" => lhs_cell,
            "rhs" => rhs_cell,
        ))
    end
    return extra
end

function _check_bc_supported(kind::String, value, var::String, dim::String)
    kind == "dirichlet" && return
    if kind == "neumann"
        (value isa Number && iszero(value)) && return
        throw(RuleEngineError("E_BC_UNSUPPORTED",
            "nonzero-Neumann boundary condition on '$var' along '$dim' is not " *
            "yet supported by the arrayop lift (requires grid-spacing-aware " *
            "ghost extrapolation)"))
    end
    throw(RuleEngineError("E_BC_UNSUPPORTED",
        "boundary condition kind '$kind' on '$var' along '$dim' is not " *
        "supported by the arrayop lift (supported: dirichlet, zero-flux neumann)"))
end

# Max |offset| per canonical index variable across every index read.
function _scan_stencil_reach!(reach::Dict{String,Int}, node)
    node isa AbstractDict || return
    if get(node, "op", nothing) == "index"
        args = get(node, "args", Any[])
        for a in args[2:end]
            if a isa AbstractDict && get(a, "op", nothing) in ("+", "-")
                aa = get(a, "args", Any[])
                if length(aa) == 2 && aa[1] isa AbstractString && aa[2] isa Number
                    k = abs(Int(aa[2]))
                    v = String(aa[1])
                    haskey(reach, v) && (reach[v] = max(reach[v], k))
                end
            end
        end
    end
    for a in get(node, "args", Any[])
        _scan_stencil_reach!(reach, a)
    end
end

# Instantiate a stencil body at literal cell indices: canonical index
# variables resolve via `fixed`, offset arithmetic folds, periodic reads
# wrap numerically, and bounded out-of-range reads resolve per the read
# variable's BC (dirichlet value / neumann-zero mirror / zero-ghost
# passthrough when undeclared).
function _instantiate_bc_cell(node, fixed::Dict{String,Int},
                               variables::Dict{String,Dict{String,Any}},
                               dim_sizes::AbstractDict,
                               periodic::Set{String},
                               bc_map::Dict{Tuple{String,String,Symbol},Tuple{String,Any}})
    node isa AbstractDict || return node
    if get(node, "op", nothing) == "index"
        args = get(node, "args", Any[])
        if !isempty(args) && args[1] isa AbstractString
            vname = String(args[1])
            vmeta = get(variables, vname, nothing)
            vshape = vmeta === nothing ? nothing : get(vmeta, "shape", nothing)
            if vshape isa AbstractVector && length(vshape) == length(args) - 1
                new_args = Any[vname]
                for (p, a) in enumerate(args[2:end])
                    e = _fold_index_arg(a, fixed)
                    if e === nothing
                        push!(new_args, a)   # unresolvable: keep verbatim
                        continue
                    end
                    dn = String(vshape[p])
                    N = Int(get(dim_sizes, dn, 0))
                    if N > 0 && dn in periodic
                        e = mod(e - 1, N) + 1
                    elseif N > 0 && (e < 1 || e > N)
                        side = e < 1 ? :min : :max
                        entry = get(bc_map, (vname, dn, side), nothing)
                        if entry !== nothing
                            kind, value = entry
                            _check_bc_supported(kind, value, vname, dn)
                            if kind == "dirichlet"
                                # Replace the whole read with the BC value.
                                return _deep_native(value)
                            else  # zero-flux neumann
                                e = e < 1 ? 1 - e : 2N + 1 - e   # mirror
                            end
                        end
                        # No BC: keep the literal out-of-range index
                        # (zero-ghost convention, unchanged behavior).
                    end
                    push!(new_args, e)
                end
                return Dict{String,Any}("op" => "index", "args" => new_args)
            end
        end
    end
    out = Dict{String,Any}()
    for (k, v) in node
        key = String(k)
        out[key] = key == "args" && v isa AbstractVector ?
            Any[_instantiate_bc_cell(a, fixed, variables, dim_sizes, periodic, bc_map)
                for a in v] : v
    end
    return out
end

# Fold an index-argument expression to a concrete Int given fixed canonical
# index values; `nothing` when symbols remain.
function _fold_index_arg(a, fixed::Dict{String,Int})
    a isa Integer && return Int(a)
    a isa AbstractFloat && return (isinteger(a) ? Int(a) : nothing)
    a isa AbstractString && return get(fixed, String(a), nothing)
    a isa AbstractDict || return nothing
    op = get(a, "op", nothing)
    op in ("+", "-") || return nothing
    args = get(a, "args", Any[])
    length(args) == 2 || return nothing
    x = _fold_index_arg(args[1], fixed)
    y = _fold_index_arg(args[2], fixed)
    (x === nothing || y === nothing) && return nothing
    return op == "+" ? x + y : x - y
end

# Walk a raw JSON-like body Dict and fold stencil index accesses for periodic
# grid dimensions. For each `index(u, e1, e2, ...)` node where variable `u`
# lives on a periodic dimension d of size N, replaces `e_d` with:
#   ifelse(e_d < 1, e_d + N, ifelse(e_d > N, e_d - N, e_d))
# This is exact for nearest-neighbor stencils where e_d ∈ {0, 1, …, N, N+1}.
# At _build_arrayop scalarization time, e_d is a concrete integer, so the
# ifelse collapses to the correct in-bounds index.
function _apply_periodic_folding!(body::Any,
                                   var_periodic_sizes::Dict{String,Vector{Tuple{Int,Bool}}})
    body isa AbstractDict || return
    op = get(body, "op", nothing)
    if op == "index"
        args = get(body, "args", nothing)
        args isa AbstractVector && length(args) >= 2 || return
        varname = args[1] isa AbstractString ? String(args[1]) : nothing
        if varname !== nothing
            dims = get(var_periodic_sizes, varname, nothing)
            if dims !== nothing
                new_args = Any[args[1]]
                for (d, idx_expr) in enumerate(args[2:end])
                    if d <= length(dims)
                        N, is_periodic = dims[d]
                        if is_periodic && !(idx_expr isa AbstractString)
                            idx_expr = Dict{String,Any}(
                                "op"   => "ifelse",
                                "args" => Any[
                                    Dict{String,Any}("op" => "<",
                                        "args" => Any[idx_expr, 1]),
                                    Dict{String,Any}("op" => "+",
                                        "args" => Any[idx_expr, N]),
                                    Dict{String,Any}("op" => "ifelse",
                                        "args" => Any[
                                            Dict{String,Any}("op" => ">",
                                                "args" => Any[idx_expr, N]),
                                            Dict{String,Any}("op" => "-",
                                                "args" => Any[idx_expr, N]),
                                            idx_expr
                                        ])
                                ]
                            )
                        end
                    end
                    push!(new_args, idx_expr)
                end
                body["args"] = new_args
                return
            end
        end
    end
    # Recurse into all child values.
    for val in values(body)
        if val isa AbstractDict
            _apply_periodic_folding!(val, var_periodic_sizes)
        elseif val isa AbstractVector
            for item in val
                item isa AbstractDict && _apply_periodic_folding!(item, var_periodic_sizes)
            end
        end
    end
end

# ============================================================================
# Per-equation / per-BC rewrite
# ============================================================================

function _discretize_equation!(path::String, eqn::Dict{String,Any},
                                rules::Vector{Rule}, ctx::RuleContext,
                                max_passes::Int, strict_unrewritten::Bool)
    passthrough = _as_bool(get(eqn, "passthrough", false))
    # Rewrite RHS. The LHS is of the form D(x, wrt=t) or x; we canonicalize it
    # without running the rule engine, so that time derivatives are preserved.
    if haskey(eqn, "rhs")
        eqn["rhs"] = _rewrite_or_passthrough!(
            "$path.rhs", eqn["rhs"], rules, ctx,
            max_passes, strict_unrewritten, passthrough,
            (v) -> (eqn["passthrough"] = v))
    end
    if haskey(eqn, "lhs")
        eqn["lhs"] = _canonicalize_value(eqn["lhs"])
    end
end

function _discretize_bc!(path::String, bc::Dict{String,Any},
                          rules::Vector{Rule}, ctx::RuleContext,
                          max_passes::Int, strict_unrewritten::Bool)
    passthrough = _as_bool(get(bc, "passthrough", false))
    variable = _string_or_nothing_any(get(bc, "variable", nothing))
    kind     = _string_or_nothing_any(get(bc, "kind", nothing))
    side     = _string_or_nothing_any(get(bc, "side", nothing))
    value_raw = get(bc, "value", nothing)

    # Step 1: try matching a `bc` rule pattern (§9.2 — synthetic wrapper).
    # Rules MAY rewrite the BC into an algebraic equation or other form; if
    # no rule matches, we fall through and treat `value` as the BC payload.
    rewritten_via_bc_rule = false
    if variable !== nothing && kind !== nothing && !isempty(rules)
        wrapper = Dict{String,Any}(
            "op" => "bc",
            "args" => Any[variable],
            "kind" => kind,
        )
        if side !== nothing
            wrapper["side"] = side
        end
        if value_raw !== nothing
            push!(wrapper["args"], value_raw)
        end
        bc_expr = parse_expression(wrapper)
        rewrite_out = rewrite(canonicalize(bc_expr), rules, ctx; max_passes=max_passes)
        if !(rewrite_out isa OpExpr && rewrite_out.op == "bc")
            # A rule fired at the bc node; emit the rewritten form as `value`.
            final = canonicalize(rewrite_out)
            if _has_pde_op(final) && !passthrough
                if strict_unrewritten
                    op = _first_pde_op(final)
                    throw(RuleEngineError("E_UNREWRITTEN_PDE_OP",
                        "$path.value still contains PDE op '$op' after rewrite; " *
                        "annotate the BC with 'passthrough: true' to opt out"))
                end
                bc["passthrough"] = true
            end
            bc["value"] = serialize_expression(final)
            rewritten_via_bc_rule = true
        end
    end

    # Step 2: default path — canonicalize the `value` expression and run the
    # rule engine on it. The PDE-op coverage check applies only to the value,
    # never to the synthetic `bc` wrapper.
    if !rewritten_via_bc_rule && value_raw !== nothing
        bc["value"] = _rewrite_or_passthrough!(
            "$path.value", value_raw, rules, ctx,
            max_passes, strict_unrewritten, passthrough,
            (v) -> (bc["passthrough"] = v))
    end
end

function _rewrite_or_passthrough!(path::String, value_raw, rules::Vector{Rule},
                                   ctx::RuleContext, max_passes::Int,
                                   strict_unrewritten::Bool,
                                   passthrough::Bool,
                                   set_passthrough::Function)
    expr = parse_expression(value_raw)
    canon0 = canonicalize(expr)
    rewritten = isempty(rules) ? canon0 :
        rewrite(canon0, rules, ctx; max_passes=max_passes)
    canon1 = canonicalize(rewritten)
    if passthrough
        # Authorial opt-out: keep the rewritten form but do not enforce
        # coverage. `bc` ops with no matching rule fall through here too.
        return serialize_expression(canon1)
    end
    if _has_pde_op(canon1)
        if strict_unrewritten
            op = _first_pde_op(canon1)
            throw(RuleEngineError("E_UNREWRITTEN_PDE_OP",
                "$path still contains PDE op '$op' after rewrite; " *
                "annotate the equation/BC with 'passthrough: true' to opt out"))
        end
        set_passthrough(true)
    end
    return serialize_expression(canon1)
end

function _canonicalize_value(value_raw)
    expr = parse_expression(value_raw)
    return serialize_expression(canonicalize(expr))
end

# ============================================================================
# DAE classification and binding contract (RFC §12)
# ============================================================================

"""
    _apply_dae_contract!(esm, dae_support)

Classify every equation as differential vs algebraic, record the
per-model algebraic count, and either stamp `metadata.system_class`
on the output or throw `E_NO_DAE_SUPPORT`.

An equation is **differential** iff its LHS is an `OpExpr` with `op == "D"`
and `wrt` equal to the enclosing model's independent variable (the
domain's `independent_variable`, defaulting to `"t"`). Every other
equation — authored algebraic constraints, observed equations whose
LHS is a plain variable, equations emitted by a `produces: algebraic`
rule (once that lands) — is algebraic for the purpose of this contract.

This is deliberately inclusive: any binding that claims ODE-only
support and hands off a system to an ODE integrator would drop an
observed-equation LHS just as surely as a true DAE constraint. RFC §12
pins the contract as "hand to a DAE assembler, or abort".
"""
function _apply_dae_contract!(esm::Dict{String,Any}, dae_support::Bool)
    total_algebraic = 0
    per_model = Dict{String,Int}()
    first_algebraic_path::Union{Nothing,String} = nothing

    models = get(esm, "models", nothing)
    if models isa AbstractDict
        indep_by_domain = _indep_var_by_domain(esm)
        for (mname, mraw) in models
            mraw isa AbstractDict || continue
            indep = _model_independent_variable(mraw, indep_by_domain)
            count = 0
            eqns = get(mraw, "equations", nothing)
            if eqns isa AbstractVector
                for (i, eqn) in enumerate(eqns)
                    eqn isa AbstractDict || continue
                    _is_algebraic_equation(eqn, indep) || continue
                    count += 1
                    if first_algebraic_path === nothing
                        first_algebraic_path = "models.$(mname).equations[$i]"
                    end
                end
            end
            total_algebraic += count
            per_model[String(mname)] = count
        end
    end

    # Write classification to top-level metadata so downstream (MTK export,
    # conformance harness) can read it without re-walking. We do not mutate
    # per-model dicts because `Model` has `additionalProperties: false`.
    out_meta = _ensure_dict!(esm, "metadata")
    out_meta["system_class"] = total_algebraic > 0 ? "dae" : "ode"
    out_meta["dae_info"] = Dict{String,Any}(
        "algebraic_equation_count" => total_algebraic,
        "per_model" => Dict{String,Any}(k => v for (k, v) in per_model),
    )

    if total_algebraic > 0 && !dae_support
        where_ = first_algebraic_path === nothing ? "(unknown)" : first_algebraic_path
        throw(RuleEngineError("E_NO_DAE_SUPPORT",
            "discretize() output contains $(total_algebraic) algebraic " *
            "equation(s) (first at $(where_)); DAE support is disabled " *
            "(dae_support=false / ESM_DAE_SUPPORT=0). Enable DAE support " *
            "or remove the algebraic constraint(s). See RFC §12."))
    end
    return esm
end

# Resolve domain -> independent_variable (default "t").
function _indep_var_by_domain(esm::Dict{String,Any})::Dict{String,String}
    out = Dict{String,String}()
    domains = get(esm, "domains", nothing)
    domains isa AbstractDict || return out
    for (dname, draw) in domains
        draw isa AbstractDict || continue
        iv = get(draw, "independent_variable", nothing)
        out[String(dname)] = iv isa AbstractString ? String(iv) : "t"
    end
    return out
end

function _model_independent_variable(model::AbstractDict,
                                      indep_by_domain::Dict{String,String})::String
    dname = get(model, "domain", nothing)
    dname isa AbstractString || return "t"
    return get(indep_by_domain, String(dname), "t")
end

function _is_algebraic_equation(eqn::AbstractDict, indep::String)::Bool
    # An explicit marker wins if present (future `produces: algebraic`
    # output can stamp this directly).
    if haskey(eqn, "produces")
        p = eqn["produces"]
        if p == "algebraic" || (p isa AbstractDict && get(p, "kind", nothing) == "algebraic")
            return true
        end
    end
    if _as_bool(get(eqn, "algebraic", false))
        return true
    end
    lhs_raw = get(eqn, "lhs", nothing)
    lhs_raw === nothing && return true  # malformed — treat as algebraic
    # Parse defensively; if we can't parse the LHS, treat as algebraic so
    # the contract fails closed rather than silently dropping a constraint.
    lhs = try
        parse_expression(lhs_raw)
    catch
        return true
    end
    if lhs isa OpExpr && lhs.op == "D"
        wrt = lhs.wrt
        if wrt === nothing || wrt == indep
            return false
        end
    end
    if lhs isa OpExpr && lhs.op == "arrayop" && lhs.expr_body isa OpExpr
        body = lhs.expr_body
        if body.op == "D"
            wrt = body.wrt
            if wrt === nothing || wrt == indep
                return false
            end
        end
    end
    return true
end

function _ensure_dict!(container::AbstractDict, key::AbstractString)::Dict{String,Any}
    raw = get(container, key, nothing)
    if raw isa Dict{String,Any}
        return raw
    elseif raw isa AbstractDict
        d = Dict{String,Any}(String(k) => v for (k, v) in raw)
        container[key] = d
        return d
    else
        d = Dict{String,Any}()
        container[key] = d
        return d
    end
end

# ============================================================================
# Leftover-PDE-op scan (RFC §11 Step 7)
# ============================================================================

const _DISCRETIZE_PDE_OPS = Set(["grad", "div", "laplacian", "D", "bc"])

function _has_pde_op(e)::Bool
    return _first_pde_op(e) !== nothing
end

function _first_pde_op(e)::Union{String,Nothing}
    if e isa OpExpr
        if e.op == "D"
            # A leading D(var, wrt="t") on the LHS is legitimate; on the RHS of
            # an equation it is a PDE-op (time-derivative placed inside the
            # RHS after some rewrite). Treat it as PDE-op here; the LHS does
            # not flow through this check.
            return "D"
        end
        e.op in _DISCRETIZE_PDE_OPS && return e.op
        for a in e.args
            r = _first_pde_op(a)
            r === nothing || return r
        end
    end
    return nothing
end

# ============================================================================
# Rule loading (permissive: accept array form or keyed-object form)
# ============================================================================

function _load_rules(raw)::Vector{Rule}
    raw === nothing && return Rule[]
    raw isa AbstractDict || raw isa AbstractVector || return Rule[]
    isempty(raw) && return Rule[]
    return parse_rules(raw)
end

# ============================================================================
# Deep-copy of JSON-shaped data + light normalization
# ============================================================================

_deep_native(x::AbstractDict) =
    Dict{String,Any}(String(k) => _deep_native(v) for (k, v) in x)
_deep_native(x::AbstractVector) = Any[_deep_native(v) for v in x]
_deep_native(x::JSON3.Object) =
    Dict{String,Any}(String(k) => _deep_native(x[k]) for k in keys(x))
_deep_native(x::JSON3.Array) = Any[_deep_native(v) for v in x]
_deep_native(x) = x

_as_bool(x::Bool) = x
_as_bool(x::AbstractString) = (lowercase(String(x)) == "true")
_as_bool(::Nothing) = false
_as_bool(x) = x == true

# ============================================================================
# Metadata: discretized_from provenance
# ============================================================================

function _record_discretized_from!(esm::Dict{String,Any})
    meta_raw = get(esm, "metadata", nothing)
    meta = meta_raw isa Dict{String,Any} ? meta_raw :
        (meta_raw isa AbstractDict ?
            Dict{String,Any}(String(k) => v for (k, v) in meta_raw) :
            Dict{String,Any}())
    src_name = get(meta, "name", nothing)
    # `discretized_from` lives under metadata as a sub-object so we can later
    # add rule-engine provenance (version, fixture hash, etc.) without spec
    # churn. For now: name + input-hash placeholder.
    provenance = Dict{String,Any}()
    if src_name !== nothing
        provenance["name"] = String(src_name)
    end
    meta["discretized_from"] = provenance
    tags = get(meta, "tags", nothing)
    if tags isa AbstractVector
        if !("discretized" in (String(t) for t in tags))
            push!(tags, "discretized")
        end
    else
        meta["tags"] = Any["discretized"]
    end
    esm["metadata"] = meta
    return esm
end
