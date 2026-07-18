# Invent placeholder identifiers so the variable-declaration macro sees valid
# identifiers, pairing each with its live IV object (see `_eval_var_macro`'s
# `bindings` in ext/shared/eval_var_macro.jl).
_iv_holder_bindings(iv_syms::Vector{Any}) =
    [Symbol("__esm_iv_", i) => iv_syms[i] for i in 1:length(iv_syms)]

"""
    _make_dep_var(name::Symbol, iv_syms::Vector{Any}) -> Num

Construct a symbolic variable of the form `name(iv1, iv2, ...)`, where the
`iv_syms` vector contains the actual symbolic objects to use as arguments.
Uses the public `Symbolics.@variables` macro via the shared `_eval_var_macro`
scaffold so we remain robust to changes in `FnType`'s parameter list across
Symbolics versions; the IVs are passed by value into the macro's scope
through invented placeholder identifiers.
"""
function _make_dep_var(name::Symbol, iv_syms::Vector{Any})
    bindings = _iv_holder_bindings(iv_syms)
    call_expr = Core.Expr(:call, name, first.(bindings)...)
    return _eval_var_macro(Symbolics, Symbol("@variables"), call_expr;
                           bindings=bindings)
end

"""
    _make_param(name::Symbol) -> Num

Construct a plain parameter symbol `name` using `ModelingToolkit.@parameters`.
"""
# @parameters (not @variables) stamps isparameter=true, which AffectSystem
# relies on to classify symbols inside a SymbolicDiscreteCallback affect.
_make_param(name::Symbol) =
    _eval_var_macro(ModelingToolkit, Symbol("@parameters"), name)

"""
    _build_description(desc, units) -> Union{String,Nothing}

Assemble a description string that encodes both the ESM variable's textual
description and its units. MTK's `VariableDescription` metadata is a plain
string, so we embed the unit as a `(units=...)` suffix. Returns `nothing`
when there is nothing to attach — the caller uses that to skip metadata.

The ESM binding intentionally does NOT feed units into MTK's own unit
metadata system (that path has latent bugs and duplicates the work of
`src/units.jl`); stuffing units into the description is a version-stable
alternative that still surfaces in error messages and plot labels.
"""
function _build_description(desc::Union{String,Nothing},
                            units::Union{String,Nothing})
    if desc === nothing && units === nothing
        return nothing
    elseif units === nothing
        return desc
    elseif desc === nothing
        return "(units=$(units))"
    else
        return "$(desc) (units=$(units))"
    end
end

"""
    _make_array_dep_var(name::Symbol, iv_syms::Vector{Any}, shape::Vector{UnitRange{Int}})

Construct a shape-annotated symbolic variable of the form
`name(iv1, iv2, ...)[range1, range2, ...]` — the array form produced by
`@variables (u(t))[1:N]`. We build the macro call via the shared
`_eval_var_macro` scaffold so `iv_syms` can be passed by value. The result is
the array-shaped `Symbolics.Arr` object that supports element-wise indexing
via `u[i]`, `u[i, j]`, etc.
"""
function _make_array_dep_var(name::Symbol, iv_syms::Vector{Any},
                             shape::Vector{UnitRange{Int}})
    bindings = _iv_holder_bindings(iv_syms)
    call_expr = Core.Expr(:call, name, first.(bindings)...)
    # Always pad the low side of the shape to 1. MTK's init path treats
    # Symbolics.Arr indices as raw 1-based Vector positions, so declaring
    # `@variables flux(t)[3:17]` produces a 15-slot backing Vector but
    # `flux[17]` then resolves to internal position 17 and raises
    # BoundsError during `generate_initializesystem_timevarying`. Using
    # `1:last(r)` makes the backing Vector large enough that every used
    # index is a valid position; the low slots that fall outside the
    # inferred range are simply left out of `states` in `_build_var_dict`.
    ranges_ast = [Core.Expr(:call, :(:), 1, last(r)) for r in shape]
    ref_expr = Core.Expr(:ref, call_expr, ranges_ast...)
    # `(name(iv...)[range...])` — the parenthesized form the macro expects.
    paren_expr = Core.Expr(:block, ref_expr)
    return _eval_var_macro(Symbolics, Symbol("@variables"), paren_expr;
                           bindings=bindings)
end

# ========================================
# Build symbolic variable dictionaries from a FlattenedSystem
# ========================================

# (The ODE-vs-PDE predicate `_has_spatial_ivs` lives in src/flatten.jl,
# next to `FlattenedSystem`.)

"""
Create Symbolics.jl variable/parameter symbols for every state, parameter, and
observed variable in a flattened system. Returns `(var_dict, t_sym, dim_dict,
states, parameters, observed, spatial_syms)` where `states`/`parameters`/
`observed` are typed `Vector{Num}` and `spatial_syms` holds the non-time
independent-variable symbols (empty for ODE systems).

For ODE systems, state variables are functions of `t` only. For PDE systems,
state variables are functions of `t` and the spatial dimensions declared in
`flat.independent_variables` (minus `:t`).

When the flattened system contains `arrayop`/`makearray`/`index` nodes,
shape inference is run first and any variable that appears inside an array
operator is declared as a shaped `@variables (u(t))[1:N]` instead of a
scalar `u(t)`. The `states`/`observed` vectors then contain the individual
scalar elements of those array variables (so `length(states) == M*N` for a
2-D array), matching the scalar dvs list passed to
`System(..., dvs, [])` in the MTK fork's native `@arrayop` tests.
"""
function _build_var_dict(flat::FlattenedSystem)
    is_pde = _has_spatial_ivs(flat)

    # Independent variables
    t_sym = _get_or_make_dim(Dict{String,Any}(), "t")
    dim_dict = Dict{String,Any}("t" => t_sym)

    spatial_syms = Any[]
    if is_pde
        for iv in flat.independent_variables
            iv == :t && continue
            dim_sym = _get_or_make_dim(dim_dict, String(iv))
            push!(spatial_syms, dim_sym)
        end
    end

    # Shape inference: scalar-only systems get an empty dict and pay nothing.
    # Use LHS arrayop output ranges as the authoritative shape when available:
    # they define the actual grid (e.g. 1:N × 1:N), while infer_array_shapes
    # can widen the shape to cover stencil ghost-cell offsets (e.g. 0:N+1).
    inferred_shapes = infer_array_shapes(flat.equations)
    lhs_shapes = _lhs_arrayop_shapes(flat.equations)
    merge!(inferred_shapes, lhs_shapes)  # LHS definition takes precedence

    var_dict = Dict{String,Any}()
    states = Vector{Num}()
    parameters = Vector{Num}()
    observed = Vector{Num}()

    # Concrete IV symbol objects to pass to the @variables macro via our
    # _make_dep_var helper (see the bindings trick inside that function).
    iv_syms_any = Any[t_sym]
    for s in spatial_syms
        push!(iv_syms_any, s)
    end

    # Sanitize names for use as Julia symbols (dots in "System.var" would
    # otherwise produce invalid symbols in the generated @variables call).
    _san(s::AbstractString) = Symbol(replace(String(s), '.' => '_'))

    # Attach a default value to a Symbolics variable via VariableDefaultValue
    # metadata. MTK v11 uses this to wire initial conditions on states and
    # parameter values into ODEProblem/PDESystem construction without
    # requiring the caller to pass u0/p maps manually.
    _with_default(v, val) =
        val === nothing ? v : Symbolics.setdefaultval(v, Float64(val))

    _with_description(v, desc_text) =
        desc_text === nothing ? v :
            Symbolics.setmetadata(v, ModelingToolkit.VariableDescription, desc_text)

    # State variables — functions of independent variables
    for (vname, mvar) in flat.state_variables
        sym_name = _san(vname)
        shape = get(inferred_shapes, vname, nothing)
        desc_text = _build_description(mvar.description, mvar.units)
        if shape === nothing
            v_num = _with_description(
                _with_default(_make_dep_var(sym_name, iv_syms_any), mvar.default),
                desc_text)
            push!(states, v_num)
            var_dict[vname] = v_num
        else
            array_var = _make_array_dep_var(sym_name, iv_syms_any, shape)
            var_dict[vname] = array_var
            # Enumerate the individual scalar elements for the dvs vector.
            # Description metadata is attached per-element because
            # Symbolics.setmetadata has no method for Symbolics.Arr.
            for idx in Iterators.product(shape...)
                elt = _with_description(Num(array_var[idx...]), desc_text)
                push!(states, elt)
            end
        end
    end

    # Parameters — plain symbols
    for (pname, mvar) in flat.parameters
        p_num = _with_description(
            _with_default(_make_param(_san(pname)), mvar.default),
            _build_description(mvar.description, mvar.units))
        push!(parameters, p_num)
        var_dict[pname] = p_num
    end

    # Observed variables — same shape as states
    for (oname, mvar) in flat.observed_variables
        ov_num = _with_description(
            _with_default(_make_dep_var(_san(oname), iv_syms_any), mvar.default),
            _build_description(mvar.description, mvar.units))
        push!(observed, ov_num)
        var_dict[oname] = ov_num
    end

    return var_dict, t_sym, dim_dict, states, parameters, observed, spatial_syms
end

# ========================================
# Event conversion
# ========================================

# Substitute every state variable reference in `expr` with
# `ModelingToolkit.Pre(var)`. Required on event-affect RHS expressions:
# current MTK interprets an un-`Pre`-wrapped affect equation as an
# algebraic constraint to hold after the callback, which renders
# assignments like `x ~ x + dose` unsatisfiable (see
# ModelingToolkit/callbacks.jl:85 warning). Parameters are left alone —
# they don't vary across the affect, and wrapping them would force the
# discrete-parameter machinery for no gain.
function _wrap_pre_states(expr, state_syms)
    isempty(state_syms) && return expr
    subs = Dict{Any,Any}()
    for sv in state_syms
        u = Symbolics.unwrap(sv)
        subs[u] = ModelingToolkit.Pre(sv)
    end
    if expr isa AbstractArray
        return map(e -> Symbolics.substitute(e, subs), expr)
    end
    return Symbolics.substitute(expr, subs)
end

function _affect_to_eq(affect, var_dict::Dict{String,Any}, t_sym, dim_dict,
                      state_syms)
    if affect isa AffectEquation
        if !haskey(var_dict, affect.lhs)
            @warn "Target variable $(affect.lhs) not found for event affect"
            return nothing
        end
        target = var_dict[affect.lhs]
        rhs = _esm_to_symbolic(affect.rhs, var_dict, t_sym, dim_dict)
        rhs = _wrap_pre_states(rhs, state_syms)
        return target ~ rhs
    end
    return nothing
end

"""
    _condition_to_root_equation(cond, var_dict, t_sym, dim_dict) -> Equation

Lower one ESM continuous-event condition to the MTK ROOT-FINDING equation that
expresses it.

MTK's `SymbolicContinuousCallback` takes `conditions::Vector{Equation}`, not a
scalar expression: an entry `lhs ~ rhs` names the zero-crossing function
`lhs - rhs`, and the integrator winds back to the instant it crosses zero.
Passing the raw `Num` that `_esm_to_symbolic` produces is what broke every
continuous event —

    MethodError: no method matching SymbolicContinuousCallback(::Num, ::Vector{Equation})

so the whole `continuous_events` feature failed at System() construction time.

An ESM condition (esm-spec §5) is a zero-crossing FUNCTION, so the mapping is:

  * `{"op":"-","args":[a,b]}` — the canonical spelling, 70 of the corpus's 88
    conditions — is the crossing `a - b`, i.e. `a ~ b`.
  * a RELATIONAL condition (`a < b`, `a >= b`, …) crosses exactly where its two
    sides are equal, so it is also `a ~ b`. The direction is carried by the
    edge (`affect` vs `affect_neg`), not by the operator.
  * anything else — a bare variable (`"height"`), an arbitrary expression — is
    the crossing `f ~ 0`.

A BOOLEAN CONNECTIVE (`and`/`or`/`not`) has no zero-crossing function at all: it
is piecewise-constant, so root-finding on it is meaningless. That is a discrete
trigger wearing a continuous event's clothes, and it FAILS LOUDLY here rather
than being lowered to something that silently never fires.
"""
function _condition_to_root_equation(cond::ASTExpr, var_dict, t_sym, dim_dict)
    if cond isa OpExpr
        if cond.op in ("and", "or", "not")
            throw(ArgumentError(
                "continuous-event condition uses the boolean operator '$(cond.op)', " *
                "which has no zero-crossing function — a continuous event roots on a " *
                "CONTINUOUS expression (esm-spec §5). Express the crossing directly " *
                "(e.g. {\"op\":\"-\",\"args\":[a,b]} for a ~ b), or use a discrete " *
                "event with a condition trigger."))
        end
        # Binary `-` and the relationals both root where the two sides meet.
        if length(cond.args) == 2 && cond.op in ("-", "<", "<=", ">", ">=", "==")
            lhs = _esm_to_symbolic(cond.args[1], var_dict, t_sym, dim_dict)
            rhs = _esm_to_symbolic(cond.args[2], var_dict, t_sym, dim_dict)
            return lhs ~ rhs
        end
    end
    return _esm_to_symbolic(cond, var_dict, t_sym, dim_dict) ~ 0
end

function _build_continuous_events(flat::FlattenedSystem, var_dict, t_sym, dim_dict,
                                  state_syms)
    cbs = Any[]
    for ev in flat.continuous_events
        conds = ModelingToolkit.Equation[
            _condition_to_root_equation(c, var_dict, t_sym, dim_dict)
            for c in ev.conditions
        ]
        affects = filter(!isnothing,
                         [_affect_to_eq(a, var_dict, t_sym, dim_dict, state_syms)
                          for a in ev.affects])
        # NOTE: parenthesized guard — the bare `a || b && continue` form
        # parses as `a || (b && continue)`, letting an event with EMPTY
        # conditions fall through to `conds[1]` (BoundsError).
        (isempty(conds) || isempty(affects)) && continue
        # `conditions` is a Vector{Equation}; `affect` a Vector{Equation} that
        # MTK wraps into a SymbolicAffect. `affect_neg` is deliberately left at
        # its MTK default — which is `affect` — because esm-spec §5.2 says the
        # same thing: "If `null` or absent, `affects` is used for both
        # directions." That default is what makes the bouncing ball bounce: it
        # crosses `height ~ 0` on the NEGATIVE edge (falling), so an event that
        # fired only on the positive edge would never trigger.
        push!(cbs, ModelingToolkit.SymbolicContinuousCallback(conds, affects))
    end
    return cbs
end

function _build_discrete_events(flat::FlattenedSystem, var_dict, t_sym, dim_dict,
                                state_syms)
    cbs = Any[]
    for ev in flat.discrete_events
        affects = filter(!isnothing,
                         [_affect_to_eq(a, var_dict, t_sym, dim_dict, state_syms)
                          for a in ev.affects])
        isempty(affects) && continue
        if ev.trigger isa ConditionTrigger
            cond = _esm_to_symbolic(ev.trigger.expression, var_dict, t_sym, dim_dict)
            push!(cbs, ModelingToolkit.SymbolicDiscreteCallback(cond, affects))
        elseif ev.trigger isa PeriodicTrigger
            push!(cbs, ModelingToolkit.SymbolicDiscreteCallback(ev.trigger.period, affects))
        elseif ev.trigger isa PresetTimesTrigger
            # MTK routes a Vector{<:Real} condition to PresetTimeCallback
            # (fires at exactly those times); a scalar Real goes to
            # PeriodicCallback (fires at tspan[1]+period, 2*period, ...).
            # Pass the full times vector so multi-time triggers are honored.
            if !isempty(ev.trigger.times)
                push!(cbs, ModelingToolkit.SymbolicDiscreteCallback(
                    collect(ev.trigger.times), affects))
            end
        end
    end
    return cbs
end
