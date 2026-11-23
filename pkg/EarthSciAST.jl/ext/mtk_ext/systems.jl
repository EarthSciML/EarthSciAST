# ========================================
# ModelingToolkit.System constructors
# ========================================

# A flattened system whose independent variables are more than `[:t]` is a PDE
# (esm-libraries-spec §4.7.6): this extension builds ODE systems only.
_has_spatial_ivs(flat::FlattenedSystem) = flat.independent_variables != [:t]

# The refusal for calling the ODE constructor `ctor` on such a system.
_spatial_system_msg(flat::FlattenedSystem, ctor::String) =
    "Flattened system has independent variables $(flat.independent_variables), " *
    "which indicates a PDE with a continuous spatial dimension. $(ctor) builds " *
    "ODE systems only and this binding has no PDE constructor: discretize the " *
    "spatial operators (a `faq` stencil over an index set) first."

# ---- Route `ic(var) = <initial value>` equations out of the ODE set ----
# (esm-spec v0.8.0) An `ic`-LHS equation declares an initial value (u0 /
# variable default), NOT an ODE right-hand side. Mirror the tree-walk
# simulate path (src/tree_walk.jl): pull each `ic` equation out before
# symbolic lowering (leaving it in would send it to `_esm_to_symbolic`,
# which has no handler → "Unsupported operator: ic"). Returns the
# `(variable name, lowered value)` pairs plus the remaining dynamic
# equations; `_apply_ic_defaults!` folds the values into the states.
function _split_ic_equations(flat::FlattenedSystem, L::_Lowering)
    ic_values = Tuple{String, Any}[]
    dyn_equations = Equation[]
    # `field_ics` are classified OUT of `flat.equations` (esm-libraries-spec
    # §4.7.5 step 4), so they have to be read from their own field or the states
    # they seed silently fall back to their bare `default`.
    for (vn, rhs) in flat.field_ics
        haskey(L.vars, vn) || throw(
            SimulateError(
                "ic($(vn)) targets unknown variable '$(vn)'",
                ERROR_CODES.UNDEFINED_VARIABLE
            )
        )
        push!(ic_values, (vn, _esm_to_symbolic(rhs, L)))
    end
    for eq in flat.equations
        if eq.lhs isa OpExpr && (eq.lhs::OpExpr).op == "ic"
            lop = eq.lhs::OpExpr
            (length(lop.args) == 1 && lop.args[1] isa VarExpr) ||
                throw(SimulateError("ic(...) LHS must name a single state variable", ERROR_CODES.UNSUPPORTED_CONSTRUCT))
            vn = (lop.args[1]::VarExpr).name
            haskey(L.vars, vn) || throw(
                SimulateError(
                    "ic($(vn)) targets unknown variable '$(vn)'",
                    ERROR_CODES.UNDEFINED_VARIABLE
                )
            )
            push!(
                ic_values,
                (vn, _esm_to_symbolic(eq.rhs, L))
            )
        else
            push!(dyn_equations, eq)
        end
    end
    return ic_values, dyn_equations
end

# Fold each ic value into the target state's default via `setdefaultval`,
# rewriting the shared handle in both `L.vars` (so the equations, events,
# and `state_syms` built afterwards reference the defaulted symbol) and
# `states` (so the default rides through into `dvs`). The default-value
# metadata is the same channel `_build_var_dict` uses for
# `ModelVariable.default` — the MTK System constructor takes no `defaults`
# keyword. MTK then wires the default into ODEProblem u0 construction, and a
# caller-supplied initial condition still overrides it. Must run before the
# dynamic equations are lowered.
#
# An ARRAY state is in `states` as its scalar cells, not as the array, and
# ModelingToolkit reads a cell's default off the array the cell indexes. So
# the cells are rebuilt out of the DEFAULTED array; left as they were, they
# still index the array without one, and the initial condition never reaches
# the system (the initialization then solves for the whole state from
# nothing).
function _apply_ic_defaults!(
        var_dict::Dict{String, Any}, states,
        ic_values::Vector{Tuple{String, Any}}
    )
    for (vn, val) in ic_values
        old = var_dict[vn]
        if old isa Num
            new = Symbolics.setdefaultval(old, val)
            for i in eachindex(states)
                states[i] === old && (states[i] = new)
            end
        else
            new = Symbolics.setdefaultval(old, _fold_constant_array(val, size(old)))
            _reindex_cells!(states, old, new)
        end
        var_dict[vn] = new
    end
    return nothing
end

# Replace every cell of `old` in `states` with the same cell of `new`, keeping
# the cell's description. Cells are matched by the array's NAME, which is what
# `setdefaultval` leaves unchanged.
function _reindex_cells!(states, old, new)
    base = ModelingToolkit.getname(Symbolics.unwrap(old))
    for i in eachindex(states)
        u = Symbolics.unwrap(states[i])
        (SymUtils.iscall(u) && SymUtils.operation(u) === getindex) || continue
        args = SymUtils.arguments(u)
        ModelingToolkit.getname(args[1]) == base || continue
        idx = Int[Int(SymUtils.unwrap_const(Symbolics.value(a))) for a in args[2:end]]
        cell = Num(new[idx...])
        desc = Symbolics.getmetadata(u, ModelingToolkit.VariableDescription, nothing)
        desc === nothing ||
            (cell = Symbolics.setmetadata(cell, ModelingToolkit.VariableDescription, desc))
        states[i] = cell
    end
    return states
end

# An array initial value whose every cell is a NUMBER, as that numeric array.
# ModelingToolkit files a numeric default as an initial condition and anything
# symbolic as a binding, and a `faq` initial value lowers to an array
# expression whose cells are constants only once it is scalarized. A scalar
# number is broadcast over the array's `dims` (esm-spec §6.3). A value with a
# cell that reads a variable is returned unchanged.
function _fold_constant_array(val, dims)
    cells = Symbolics.scalarize(val)
    if !(cells isa AbstractArray)
        c = SymUtils.unwrap_const(Symbolics.value(cells))
        return c isa Real ? fill(Float64(c), dims) : val
    end
    out = Array{Float64}(undef, size(cells))
    for i in eachindex(cells)
        c = SymUtils.unwrap_const(Symbolics.value(cells[i]))
        c isa Real || return val
        out[i] = Float64(c)
    end
    return out
end

# ---- Close a state that NO equation mentions ----
# esm-libraries-spec §4.6.1 says a species touched by no reaction gets no
# `D(X, t)` equation: the flattened document leaves it an unknown that no
# equation names, which esm-spec §6.3.1 classifies ALGEBRAIC. That is a
# statement about the DOCUMENT. It is not a solver plan — §4.7.1 spells out
# that an unknown with no constraint is a structurally singular system — and
# `state_variables` still carries the species, because §4.7.5's field table
# says it is solved for either way.
#
# So the BACKEND has to say what "solved for" means for it, and MTK's answer
# by default is to say nothing: `mtkcompile` drops an unknown that appears in
# no equation, so the state vanishes from `unknowns(simp)`, an
# `initial_conditions` entry naming it cannot bind, and it is missing from
# every solution the caller reads back. Emit `D(X, t) ~ 0` for it instead —
# the species is held at its initial value, which is what a quantity the
# network says nothing about does, and what Python's SciPy backend already
# does for the same document (it keeps such a state in the vector at its u0).
# The zero lives HERE, at the lowering, and is never written into
# `flat.equations`, so the cross-binding flattened artifact is untouched.
#
# Only a state that appears NOWHERE is closed. An inert species that some
# other equation still names is another rule's business and is left alone —
# an operator's preserved `_var` clone (§4.7.1 step 5) names one, which is the
# shape `tests/valid/full_coupled.esm` has. Array-shaped states are skipped: a
# scalar `D(arr) ~ 0` is not the right closure for a buffer, and no path
# produces an unmentioned one.
function _closures_for_unmentioned_states(
        flat::FlattenedSystem,
        dyn_equations::Vector{Equation},
        var_dict::Dict{String, Any}
    )
    mentioned = Set{String}()
    for eq in dyn_equations
        union!(mentioned, free_variables(eq.lhs))
        union!(mentioned, free_variables(eq.rhs))
    end
    closures = Equation[]
    for vname in keys(flat.state_variables)
        vname in mentioned && continue
        get(var_dict, vname, nothing) isa Num || continue   # scalars only
        push!(
            closures,
            Equation(OpExpr("D", EsmExpr[VarExpr(vname)], wrt = "t"), NumExpr(0.0))
        )
    end
    return closures
end

"""
    ModelingToolkit.System(flat::FlattenedSystem; name=:anonymous, kwargs...)

Build a `ModelingToolkit.System` (an ODE system) from a flattened ESM system.
Raises a `SimulateError` (code `unsupported_construct`) when the flattened
system has a continuous spatial independent variable: this binding has no PDE
constructor, so a spatial document must be discretized (a `faq` stencil over
an index set) first. An equation using an operator the lowering has no arm for
(an open-tier name no rule rewrote, such as `grad`) is a `SimulateError` with
code `unlowered_operator`. Every other document construct the lowering cannot
express is a `SimulateError` with a code as well.
"""
function ModelingToolkit.System(
        flat::FlattenedSystem;
        name::Union{Symbol, AbstractString} = :anonymous,
        kwargs...
    )
    # ModelingToolkit evaluates in binary64, so a variable whose working
    # precision is binary32 is refused rather than evaluated in another
    # precision: the tree-walk evaluator's rule (`_refuse_float32`,
    # CONFORMANCE_SPEC §5.18.2), which reads every variable, not only states.
    # A mounted binary32 leaf reaches here stamped onto its variables (§4.7).
    document = flat.domain === nothing ? "Float64" : something(flat.domain.element_type, "Float64")
    for variables in (flat.state_variables, flat.observed_variables, flat.parameters)
        for (variable, declaration) in variables
            something(declaration.element_type, document) == "Float32" || continue
            throw(
                SimulateError(
                    "ModelingToolkit cannot evaluate binary32 variable '$variable' at its declared precision",
                    ERROR_CODES.FLOAT32_UNSUPPORTED
                )
            )
        end
    end
    # "Expand at your boundary" (RFC out-of-line-expression-templates §7.7):
    # `flatten` carries surviving `apply_expression_template` references; MTK
    # lowering has no template handling, so expand against the merged registry
    # here. No-op for a reference-free system.
    flat = expand_flattened_refs(flat)
    _has_spatial_ivs(flat) &&
        throw(SimulateError(_spatial_system_msg(flat, "ModelingToolkit.System"), ERROR_CODES.UNSUPPORTED_CONSTRUCT))
    # An operator no arm of the lowering covers (an open-tier name such as
    # `grad`, or any other a rule should have rewritten) is refused by name
    # before lowering starts, rather than surfacing from inside it.
    unlowered = _mtk_first_unlowered_op(flat)
    if unlowered !== nothing
        eq, op = unlowered
        throw(
            SimulateError(
                "equation $(_mtk_equation_label(eq)) uses the operator `$(op)`, which " *
                    "has no ModelingToolkit lowering: a rule must rewrite it into the " *
                    "core vocabulary before the system is built (esm-spec §4.2)",
                ERROR_CODES.UNLOWERED_OPERATOR
            )
        )
    end

    (; lowering, states, parameters, observed) = _build_var_dict(flat)
    L = lowering
    var_dict = L.vars

    ic_values, dyn_equations = _split_ic_equations(flat, L)
    _apply_ic_defaults!(var_dict, states, ic_values)
    # After the `ic` split, so a state whose only appearance is an initial
    # value still counts as unmentioned and gets its closure (see above).
    append!(
        dyn_equations,
        _closures_for_unmentioned_states(flat, dyn_equations, var_dict)
    )

    MTKEquation = ModelingToolkit.Equation
    eqs = Vector{MTKEquation}()
    for eq in dyn_equations
        lhs = _esm_to_symbolic(eq.lhs, L)
        rhs = _esm_to_symbolic(eq.rhs, L)
        _push_lowered_equation!(eqs, lhs, rhs)
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
    cont_cbs = _build_continuous_events(flat, L, state_syms)
    disc_cbs = _build_discrete_events(flat, L, state_syms)

    sys_name = name isa Symbol ? name : Symbol(name)

    # Only pass event kwargs that are non-empty — MTK treats an explicit
    # empty event list differently from an omitted kwarg on some versions.
    event_kwargs = Pair{Symbol, Any}[]
    isempty(cont_cbs) || push!(event_kwargs, :continuous_events => cont_cbs)
    isempty(disc_cbs) || push!(event_kwargs, :discrete_events => disc_cbs)
    return ModelingToolkit.System(
        eqs, L.t, dvs, parameters;
        name = sys_name, event_kwargs..., kwargs...
    )
end

"""
    ModelingToolkit.System(model::Model; name=:anonymous, kwargs...)

Convenience: flatten the model first, then build the `System`.

A `Model` carries no `domain`, so the document's `domain.element_type` is not
seen here: only a variable's own `element_type` is refused when binary32. Build
from the flattened document (`flatten(file)`, or `esm_problem`) to have the
document's precision checked.
"""
function ModelingToolkit.System(
        model::Model;
        name::Union{Symbol, AbstractString} = :anonymous,
        kwargs...
    )
    flat = flatten(model; name = String(name isa Symbol ? name : Symbol(name)))
    return ModelingToolkit.System(flat; name = name, kwargs...)
end
