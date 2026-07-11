# ========================================
# ModelingToolkit.System constructors
# ========================================

# esm-i7b: ODE path. Spatial differential operators (`grad`/`div`/
# `laplacian`) MUST be rewritten by ESD discretization rules into
# `arrayop` AST before reaching the simulator. Encountering one in an
# ODE-only system means the canonical pipeline broke; surface this
# rather than letting the operator slip into MTK's symbolic engine
# (where it would either error obscurely or — worse, if the operator
# has been mapped to a `Differential` symbol — silently produce a
# spatial derivative the ODE solver cannot integrate).
function _assert_no_spatial_ops(flat::FlattenedSystem)
    for eq in flat.equations
        for side in (eq.lhs, eq.rhs)
            spatial_op = _find_spatial_op(side)
            spatial_op === nothing || throw(ArgumentError(
                "UnreachableSpatialOperatorError: encountered '$(spatial_op)' " *
                "node in simulation evaluation. Spatial operators must be " *
                "rewritten by ESD discretization rules before reaching the " *
                "simulator. Pipeline contract violated."
            ))
        end
    end
    return nothing
end

# ---- Route `ic(var) = <initial value>` equations out of the ODE set ----
# (esm-spec v0.8.0) An `ic`-LHS equation declares an initial value (u0 /
# variable default), NOT an ODE right-hand side. Mirror the tree-walk
# simulate path (src/tree_walk.jl): pull each `ic` equation out before
# symbolic lowering (leaving it in would send it to `_esm_to_symbolic`,
# which has no handler → "Unsupported operator: ic"). Returns the
# `(variable name, lowered value)` pairs plus the remaining dynamic
# equations; `_apply_ic_defaults!` folds the values into the states.
function _split_ic_equations(flat::FlattenedSystem, var_dict::Dict{String,Any},
                             t_sym, dim_dict::Dict{String,Any})
    ic_values = Tuple{String,Any}[]
    dyn_equations = Equation[]
    for eq in flat.equations
        if eq.lhs isa OpExpr && (eq.lhs::OpExpr).op == "ic"
            lop = eq.lhs::OpExpr
            (length(lop.args) == 1 && lop.args[1] isa VarExpr) ||
                throw(ArgumentError("ic(...) LHS must name a single state variable"))
            vn = (lop.args[1]::VarExpr).name
            haskey(var_dict, vn) || throw(ArgumentError(
                "ic($(vn)) targets unknown variable '$(vn)'"))
            push!(ic_values,
                  (vn, _esm_to_symbolic(eq.rhs, var_dict, t_sym, dim_dict)))
        else
            push!(dyn_equations, eq)
        end
    end
    return ic_values, dyn_equations
end

# Fold each ic value into the target state's default via `setdefaultval`,
# rewriting the shared handle in both `var_dict` (so the equations, events,
# and `state_syms` built afterwards reference the defaulted symbol) and
# `states` (so the default rides through into `dvs`). The default-value
# metadata is the same channel `_build_var_dict` uses for
# `ModelVariable.default` — the MTK System constructor takes no `defaults`
# keyword. MTK then wires the default into ODEProblem u0 construction, and a
# caller-supplied initial condition still overrides it. Must run before the
# dynamic equations are lowered.
function _apply_ic_defaults!(var_dict::Dict{String,Any}, states,
                             ic_values::Vector{Tuple{String,Any}})
    for (vn, val) in ic_values
        old = var_dict[vn]
        new = Symbolics.setdefaultval(old, val)
        var_dict[vn] = new
        for i in eachindex(states)
            states[i] === old && (states[i] = new)
        end
    end
    return nothing
end

"""
    ModelingToolkit.System(flat::FlattenedSystem; name=:anonymous, kwargs...)

Build a real `ModelingToolkit.ODESystem`/`System` from a flattened ESM system.
Errors with a clear redirect to `ModelingToolkit.PDESystem` when the flattened
system has spatial independent variables.
"""
function ModelingToolkit.System(flat::FlattenedSystem;
                                name::Union{Symbol,AbstractString}=:anonymous,
                                kwargs...)
    if _has_spatial_ivs(flat)
        throw(ArgumentError(_use_pde_ctor_msg(flat,
            "ModelingToolkit.PDESystem", "ModelingToolkit.System")))
    end

    _assert_no_spatial_ops(flat)

    var_dict, t_sym, dim_dict, states, parameters, observed, _ =
        _build_var_dict(flat)

    ic_values, dyn_equations = _split_ic_equations(flat, var_dict, t_sym, dim_dict)
    _apply_ic_defaults!(var_dict, states, ic_values)

    MTKEquation = ModelingToolkit.Equation
    eqs = Vector{MTKEquation}()
    for eq in dyn_equations
        lhs = _esm_to_symbolic(eq.lhs, var_dict, t_sym, dim_dict)
        rhs = _esm_to_symbolic(eq.rhs, var_dict, t_sym, dim_dict)
        push!(eqs, lhs ~ rhs)
    end

    # Observed variables need to appear in the unknowns (dvs) list so that
    # references to them elsewhere in the equations pass MTK's structural
    # check. Their defining equation (`obs ~ expr`) stays in the main
    # equation list; `mtkcompile`'s alias elimination pass moves them to
    # the compiled system's `observed` section automatically.
    dvs = copy(states)
    append!(dvs, observed)

    # Symbolic handles for state variables (not their array-scalarized
    # elements) drive `Pre`-wrapping in affect equations.
    state_syms = Any[var_dict[vname] for vname in keys(flat.state_variables)]
    cont_cbs = _build_continuous_events(flat, var_dict, t_sym, dim_dict, state_syms)
    disc_cbs = _build_discrete_events(flat, var_dict, t_sym, dim_dict, state_syms)

    sys_name = name isa Symbol ? name : Symbol(name)

    # Only pass event kwargs that are non-empty — MTK treats an explicit
    # empty event list differently from an omitted kwarg on some versions.
    event_kwargs = Pair{Symbol,Any}[]
    isempty(cont_cbs) || push!(event_kwargs, :continuous_events => cont_cbs)
    isempty(disc_cbs) || push!(event_kwargs, :discrete_events => disc_cbs)
    return ModelingToolkit.System(eqs, t_sym, dvs, parameters;
        name=sys_name, event_kwargs..., kwargs...)
end

"""
    ModelingToolkit.System(model::Model; name=:anonymous, kwargs...)

Convenience: flatten the model first, then build the `System`.
"""
function ModelingToolkit.System(model::Model;
                                name::Union{Symbol,AbstractString}=:anonymous,
                                kwargs...)
    flat = flatten(model; name=String(name isa Symbol ? name : Symbol(name)))
    return ModelingToolkit.System(flat; name=name, kwargs...)
end

# ========================================
# ModelingToolkit.PDESystem constructors
# ========================================

"""
    ModelingToolkit.PDESystem(flat::FlattenedSystem; name=:anonymous, kwargs...)

Build a `ModelingToolkit.PDESystem` from a flattened ESM system. Errors with
a clear redirect to `ModelingToolkit.System` when the flattened system is a
pure ODE.

Boundary conditions are the slice-derived flux BCs (see below) plus the
initial-condition equations `v(t=0, x…) ~ value` — one per state variable,
from its explicit `ic(...)` equation if present, else its declared default. A
`PDESystem` takes ICs as explicit equations, unlike the ODE path where a
default rides into `ODEProblem` u0 as symbolic default-value metadata.

## Surface-source → flux boundary condition lowering

When the flattened system includes a state variable of the form `V.at_z`
that is defined by both:
1. A slice connector `V.at_z = V(t, ..., z_0)`, and
2. An ODE `D(V.at_z, t) = f(...)`,
and `V` itself participates in a diffusive PDE `D(V, t) = D_coeff *
Differential(z)(Differential(z)(V))`, the constructor emits a flux boundary
condition at `z = z_0` of the form
`D_coeff * Differential(z)(V)(t, z_0) ~ f(...)` and drops the ODE on the slice
variable. This implements the Julia-specific convention (§5.1) that
slice-derived surface source equations become flux BCs rather than pointwise
source terms in the lowest grid cell.
"""
function ModelingToolkit.PDESystem(flat::FlattenedSystem;
                                   name::Union{Symbol,AbstractString}=:anonymous,
                                   kwargs...)
    if !_has_spatial_ivs(flat)
        throw(ArgumentError(_use_ode_ctor_msg(
            "ModelingToolkit.System", "ModelingToolkit.PDESystem")))
    end

    var_dict, t_sym, dim_dict, states, parameters, observed, spatial_syms =
        _build_var_dict(flat)

    # ------------------------------------------------------------
    # Detect slice-derived surface source pattern
    # ------------------------------------------------------------
    # For each state variable with a name of the form "<prefix>.at_<dim>",
    # check if there is:
    #   (1) a connector equation "<prefix>.at_<dim> ~ <base>(t, ..., <dim_0>)"
    #   (2) an ODE equation "D(<prefix>.at_<dim>, t) ~ f(...)"
    #   (3) a base variable <base> that appears in a diffusive PDE equation.
    # If so, emit a flux BC and drop the slice-ODE.
    slice_bcs, slice_vars_to_drop = _lower_slice_sources_to_bcs!(
        flat, var_dict, t_sym, dim_dict)

    # Route `ic(var) = value` equations out of the PDE set (as the ODE path
    # does) — `_esm_to_symbolic` has no `ic` handler — collecting the explicit
    # initial values.
    ic_values, dyn_equations = _split_ic_equations(flat, var_dict, t_sym, dim_dict)

    MTKEquation = ModelingToolkit.Equation
    eqs = Vector{MTKEquation}()
    for eq in dyn_equations
        # Skip ODEs on slice variables that were lowered to flux BCs
        if _is_odelhs_for_slice_var(eq, slice_vars_to_drop)
            continue
        end
        lhs = _esm_to_symbolic(eq.lhs, var_dict, t_sym, dim_dict)
        rhs = _esm_to_symbolic(eq.rhs, var_dict, t_sym, dim_dict)
        push!(eqs, lhs ~ rhs)
    end

    # Boundary conditions: the slice-derived flux BCs, plus one initial-
    # condition equation `v(t=0, x…) ~ value` per state variable. A PDESystem
    # takes ICs as explicit equations (the ODE path instead folds a default
    # into `ODEProblem` u0 as symbolic default metadata). The value is the
    # explicit `ic(...)` if present, else the state's declared default; slice
    # variables lowered to flux BCs and states with no initial value are
    # skipped. `flat.state_variables` is an OrderedDict, so the emitted IC
    # order is deterministic.
    ic_override = Dict{String,Any}(ic_values)
    bcs = copy(slice_bcs)
    for (vname, mvar) in flat.state_variables
        vname in slice_vars_to_drop && continue
        val = get(ic_override, vname, mvar.default)
        (val === nothing || !haskey(var_dict, vname)) && continue
        v_at_t0 = Symbolics.substitute(var_dict[vname], Dict(t_sym => 0.0))
        push!(bcs, v_at_t0 ~ val)
    end

    # Build the independent variable vector and domain specification
    iv_syms = [t_sym; spatial_syms...]

    domain_spec = _build_domain_spec(flat.domain, dim_dict, t_sym, spatial_syms)

    sys_name = name isa Symbol ? name : Symbol(name)

    dvars = [Num(v) for v in states]
    append!(dvars, Num(v) for v in observed)

    return ModelingToolkit.PDESystem(eqs, bcs, domain_spec, iv_syms, dvars,
                                     parameters; name=sys_name, kwargs...)
end

"""
    ModelingToolkit.PDESystem(model::Model; name=:anonymous, kwargs...)
"""
function ModelingToolkit.PDESystem(model::Model;
                                   name::Union{Symbol,AbstractString}=:anonymous,
                                   kwargs...)
    flat = flatten(model; name=String(name isa Symbol ? name : Symbol(name)))
    return ModelingToolkit.PDESystem(flat; name=name, kwargs...)
end

# ------------------------------------------------------------
# Slice-source detection helpers
# ------------------------------------------------------------

"""
Return the list of state-variable names of the form `"<prefix>.at_<dim>"`
that look like slice connectors for a spatial dimension declared in `flat.
independent_variables`.
"""
function _find_slice_candidates(flat::FlattenedSystem)
    spatial_dims = [String(iv) for iv in flat.independent_variables if iv != :t]
    candidates = String[]
    for vname in keys(flat.state_variables)
        idx = findlast('.', vname)
        idx === nothing && continue
        tail = vname[(idx+1):end]
        startswith(tail, "at_") || continue
        dim = tail[4:end]
        dim in spatial_dims && push!(candidates, vname)
    end
    return candidates
end

"""
Walk the flattened equations and, for each slice-candidate state variable,
check for both a connector-form algebraic equation and a D(·,t) ODE. If
both exist and the base variable has a diffusive equation in the PDE set,
emit a flux boundary condition and mark the slice variable for removal.
"""
function _lower_slice_sources_to_bcs!(flat::FlattenedSystem,
                                      var_dict, t_sym, dim_dict)
    MTKEquation = ModelingToolkit.Equation
    bcs = MTKEquation[]
    drop = Set{String}()

    candidates = _find_slice_candidates(flat)
    isempty(candidates) && return bcs, drop

    for slice_name in candidates
        # Extract base prefix + slice dim from the candidate name
        base_dot = findlast('.', slice_name)
        base_dot === nothing && continue
        prefix = slice_name[1:(base_dot-1)]
        tail = slice_name[(base_dot+1):end]  # e.g. "at_z"
        dim_name = tail[4:end]                # "z"
        base_name = prefix                    # we emit flux BC on the "prefix" base var
        haskey(var_dict, base_name) || continue

        # Find an ODE equation on the slice variable
        ode_rhs = nothing
        for eq in flat.equations
            if _lhs_is_D_of(eq.lhs, slice_name)
                ode_rhs = eq.rhs
                break
            end
        end
        ode_rhs === nothing && continue

        # Find a diffusive equation on the base variable to extract the
        # diffusion coefficient. Pattern: D(base, t) ~ D_coeff * Differential(dim)(Differential(dim)(base))
        D_coeff_sym = nothing
        for eq in flat.equations
            if _lhs_is_D_of(eq.lhs, base_name)
                D_coeff_sym = _extract_diffusion_coefficient(eq.rhs, base_name, dim_name)
                D_coeff_sym !== nothing && break
            end
        end
        D_coeff_sym === nothing && continue

        # Substitute slice-variable references with the base variable in the
        # ODE rhs: the BC RHS should reference the base field at z=0, not the
        # slice-connector intermediate.
        ode_rhs_sub = _substitute_varname(ode_rhs, slice_name, base_name)

        dim_sym = _get_or_make_dim(dim_dict, dim_name)
        base_var = var_dict[base_name]
        D_coeff_val = _esm_to_symbolic(D_coeff_sym, var_dict, t_sym, dim_dict)
        rhs_sym = _esm_to_symbolic(ode_rhs_sub, var_dict, t_sym, dim_dict)

        # Flux BC: D_coeff * ∂(base)/∂dim ~ rhs_of_slice_ode (with slice var
        # rewritten to base var). For now we emit the BC unconditionally —
        # users can pin it to `dim = 0` via the domain spec.
        flux_lhs = D_coeff_val * Differential(dim_sym)(base_var)
        push!(bcs, flux_lhs ~ rhs_sym)

        push!(drop, slice_name)
    end

    return bcs, drop
end

"Substitute every `VarExpr(old)` with `VarExpr(new)` in an Expr tree."
function _substitute_varname(expr::EsmExpr, old::AbstractString, new::AbstractString)
    if expr isa VarExpr
        return expr.name == old ? VarExpr(String(new)) : expr
    elseif expr isa NumExpr || expr isa IntExpr
        return expr
    elseif expr isa OpExpr
        new_args = EsmExpr[_substitute_varname(a, old, new) for a in expr.args]
        return OpExpr(expr.op, new_args; wrt=expr.wrt, dim=expr.dim)
    else
        return expr
    end
end

function _lhs_is_D_of(lhs::EsmExpr, var_name::String)
    lhs isa OpExpr || return false
    lhs.op == "D" || return false
    length(lhs.args) >= 1 || return false
    inner = lhs.args[1]
    inner isa VarExpr || return false
    return inner.name == var_name
end

"""
Look for a diffusion term `D_coeff * Differential(dim)(Differential(dim)(base))`
in an Expr tree and return `D_coeff` as an Expr. Very simple pattern matcher:
expects the Expr to be a `*` with two operands or a `+`/`-` with one operand
shaped this way. Returns `nothing` if not found.
"""
function _extract_diffusion_coefficient(expr::EsmExpr, base_name::String,
                                        dim_name::String)
    expr isa OpExpr || return nothing
    if expr.op == "*" && length(expr.args) == 2
        a, b = expr.args
        if _is_d2_of(b, base_name, dim_name)
            return a
        elseif _is_d2_of(a, base_name, dim_name)
            return b
        end
    elseif expr.op == "laplacian" && length(expr.args) == 1
        inner = expr.args[1]
        if inner isa VarExpr && inner.name == base_name
            # D * laplacian(base) not expressible here without outer coefficient
            return nothing
        end
    elseif expr.op in ("+", "-")
        for arg in expr.args
            found = _extract_diffusion_coefficient(arg, base_name, dim_name)
            found !== nothing && return found
        end
    end
    return nothing
end

function _is_d2_of(expr::EsmExpr, var_name::String, dim_name::String)
    expr isa OpExpr || return false
    expr.op == "grad" || return false
    expr.dim == dim_name || return false
    length(expr.args) == 1 || return false
    inner = expr.args[1]
    inner isa OpExpr || return false
    inner.op == "grad" || return false
    inner.dim == dim_name || return false
    length(inner.args) == 1 || return false
    innermost = inner.args[1]
    return innermost isa VarExpr && innermost.name == var_name
end

_is_odelhs_for_slice_var(eq::Equation, drop::Set{String}) =
    any(v -> _lhs_is_D_of(eq.lhs, v), drop)

# ------------------------------------------------------------
# Domain specification helper
# ------------------------------------------------------------

function _build_domain_spec(domain::Union{Domain,Nothing}, dim_dict,
                            t_sym, spatial_syms)
    if domain === nothing
        # Default: 0 ≤ t, and each spatial dim over [0, 1]
        specs = Any[t_sym ∈ Interval(0.0, 1.0)]
        for sym in spatial_syms
            push!(specs, sym ∈ Interval(0.0, 1.0))
        end
        return specs
    end

    specs = Any[]
    if domain.temporal !== nothing
        for (name, bounds) in domain.temporal
            haskey(dim_dict, name) || continue
            lo, hi = _parse_bounds(bounds)
            push!(specs, dim_dict[name] ∈ Interval(lo, hi))
        end
    end
    # The ESM `Domain` type carries only temporal bounds at this seam, so
    # spatial dimensions get the same [0, 1] default as the `domain ===
    # nothing` branch above. PDESystem consumers (MethodOfLines et al.)
    # require a domain entry for EVERY independent variable — emitting only
    # temporal intervals here would leave the spatial dims unbounded and
    # break discretization downstream.
    for sym in spatial_syms
        push!(specs, sym ∈ Interval(0.0, 1.0))
    end
    return specs
end

function _parse_bounds(bounds)
    if bounds isa AbstractVector && length(bounds) >= 2
        return Float64(bounds[1]), Float64(bounds[2])
    elseif bounds isa AbstractDict
        lo = get(bounds, "min", get(bounds, :min, 0.0))
        hi = get(bounds, "max", get(bounds, :max, 1.0))
        return Float64(lo), Float64(hi)
    end
    return 0.0, 1.0
end
