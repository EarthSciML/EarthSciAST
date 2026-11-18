# ========================================
# Reverse direction: MTK → ESM Model
# ========================================

"""
    EarthSciAST.Model(sys::ModelingToolkit.AbstractSystem)

Convert a ModelingToolkit System back to an ESM `Model`: the model
[`mtk2esm`](@ref) builds, without its namespace stripping and file wrapper.
Constructs the export cannot carry are reported as warnings (see
[`mtk2esm_gaps`](@ref)).

Defaults come from the system's initial conditions / per-symbol metadata via
`_lookup_default`; when no default is recorded the ESM `default` field is
left as `nothing` (omitted on serialization) rather than fabricated.
"""
function EarthSciAST.Model(sys::ModelingToolkit.AbstractSystem)
    model, gaps = _export_system(sys, identity)
    _warn_gaps(gaps, "$(_sys_kind(sys)) $(_resolve_sys_name(sys, (;), "UnnamedSystem"))")
    return model
end

# ========================================
# MTK → ESM export
# ========================================

# The system kind named in warnings and gap notes: the system's type name
# (`System`, `PDESystem`, or a Catalyst `ReactionSystem` reaching the generic
# `mtk2esm_gaps`).
_sys_kind(sys) = string(nameof(typeof(sys)))

# The ESM `Model` of `sys` and the gaps found while building it — the one
# export `Model(sys)`, `mtk2esm` and `mtk2esm_gaps` share. `strip_ns` maps an
# exported name (e.g. drops the `<SystemName>_` prefix `mtk2esm` removes).
function _export_system(sys, strip_ns::Function)
    gaps = GapReport[]
    esm_vars = Dict{String, ModelVariable}()
    known_vars = Set{String}()
    observed_eqs = Equation[]
    _export_variables!(esm_vars, known_vars, gaps, sys, strip_ns, observed_eqs)
    esm_equations = _export_equations(sys, known_vars, gaps, strip_ns)
    append!(esm_equations, observed_eqs)
    _detect_unknown_op_gaps!(gaps, esm_equations)
    cont_events, disc_events = _export_events(sys, known_vars, gaps)
    # A PDE's domain has no ESM form here: esm-spec v0.8.0 moved `domain` to the
    # document level and it carries no spatial extents.
    sys isa ModelingToolkit.PDESystem && push!(
        gaps, GapReport(
            "pde_domain",
            "the PDESystem's domain specification is not serialized",
            "system.domain"
        )
    )
    model = Model(
        esm_vars, esm_equations;
        discrete_events = disc_events, continuous_events = cont_events
    )
    return model, gaps
end

# The MTK reverse walk: the shared one (ext/shared/symbolic_to_esm.jl), with
# `known_vars` naming the callable-symbolic states and observeds (`x(t)`) that
# are variables rather than operator calls.
_symbolic_to_esm_export(expr, known_vars::Set{String}, strip_ns::Function = identity) =
    _symbolic_to_esm(expr; known_vars, strip_ns)

function _symbolic_to_esm_with_gaps(
        expr, known_vars::Set{String},
        gaps::Vector{GapReport}, where_str::String;
        strip_ns::Function = identity
    )
    try
        return _symbolic_to_esm_export(expr, known_vars, strip_ns)
    catch e
        EarthSciAST._is_resource_error(e) && rethrow()
        push!(
            gaps, GapReport(
                "unknown",
                "unable to serialize symbolic node: $(sprint(showerror, e))",
                where_str
            )
        )
        return VarExpr("__TODO_GAP__")
    end
end

# (`_resolve_sys_name` is MTK-independent and lives in src/mtk_export.jl,
# shared with the Catalyst extension.)

# Export states / parameters / observed / brownian variables from `sys` into
# `esm_vars`, registering every exported name in `known_vars` (used by the
# expression walk to disambiguate callable-symbolic states from op calls).
# `observed_eqs` receives one `oname ~ rhs` equation per MTK observed: from esm
# 1.0.0 the bare-variable-LHS equation is what MAKES a variable observed
# (esm-spec §6.3.1), so the export has to emit it alongside the declaration.
function _export_variables!(
        esm_vars::AbstractDict{String, ModelVariable},
        known_vars::Set{String}, gaps::Vector{GapReport},
        sys, strip_ns::Function,
        observed_eqs::Vector{Equation} = Equation[]
    )
    # System-level initial conditions — values given on System construction
    # surface here rather than on the symbolic metadata. We look up both and
    # prefer the system-level value.
    sys_defaults = ModelingToolkit.has_initial_conditions(sys) ?
        ModelingToolkit.initial_conditions(sys) : Dict()

    for state in ModelingToolkit.unknowns(sys)
        var_name = strip_ns(_strip_time(string(ModelingToolkit.getname(state))))
        push!(known_vars, var_name)
        esm_vars[var_name] = ModelVariable(
            UnknownVariable;
            default = _lookup_default(state, sys_defaults),
            units = _get_units_str(state),
            description = _get_description_str(state)
        )
    end

    for param in ModelingToolkit.parameters(sys)
        pname = strip_ns(string(ModelingToolkit.getname(param)))
        push!(known_vars, pname)
        esm_vars[pname] = ModelVariable(
            ParameterVariable;
            default = _lookup_default(param, sys_defaults),
            units = _get_units_str(param),
            description = _get_description_str(param)
        )
    end

    obs_exprs = ModelingToolkit.has_observed(sys) ? ModelingToolkit.observed(sys) : []
    for obs in obs_exprs
        oname = strip_ns(_strip_time(string(ModelingToolkit.getname(obs.lhs))))
        push!(known_vars, oname)
        rhs_esm = _symbolic_to_esm_with_gaps(
            obs.rhs, known_vars, gaps,
            "observed[$oname].rhs"; strip_ns = strip_ns
        )
        # Declaration + defining equation: the bare-variable LHS is what makes
        # it observed from esm 1.0.0 (esm-spec §6.3.1).
        esm_vars[oname] = ModelVariable(UnknownVariable)
        push!(observed_eqs, Equation(VarExpr(oname), rhs_esm))
    end

    # Brownian variables (SDE noise sources). A Brownian noise source is a
    # PARAMETER with a unit-normal distribution and a `wiener` update from esm
    # 1.0.0 (esm-spec §5.4); `brownian_parameters` derives it back, and its
    # presence is what makes `system_kind` "sde".
    brownians = ModelingToolkit.has_brownians(sys) ? ModelingToolkit.brownians(sys) : []
    for b in brownians
        bname = string(ModelingToolkit.getname(b))
        esm_vars[bname] = ModelVariable(
            ParameterVariable;
            distribution = Distribution("normal"; location = 0.0, scale = 1.0),
            update = ParameterUpdate("wiener")
        )
    end

    # An explicit diffusion matrix has no ESM form: noise enters a document
    # only through Brownian parameters in the equations.
    noise_eqs = ModelingToolkit.has_noise_eqs(sys) ?
        ModelingToolkit.get_noise_eqs(sys) : nothing
    if noise_eqs !== nothing && !isempty(noise_eqs)
        push!(
            gaps, GapReport(
                "sde_noise_eqs",
                "system has an explicit noise_eqs matrix; SDE diffusion terms are " *
                    "serialized only as Brownian parameters in the equations",
                "system.noise_eqs"
            )
        )
    end
    return nothing
end

"""
    mtk2esm(sys::ModelingToolkit.AbstractSystem; metadata=(;)) -> Dict

Walk a non-reaction MTK system and emit a schema-valid ESM `Dict` with a
top-level `models.<name>` entry. Reaction systems are handled in the
Catalyst extension via a more specific method.

Fields populated from the MTK IR:
- `variables` (state / parameter / observed / brownian, with units +
  defaults extracted from symbolic metadata where present)
- `equations` (D(x)~rhs using the spec's Expression ops)
- `continuous_events`, `discrete_events` (from MTK callback lists)

Fields left as placeholders (filled in by hand migration):
- `description`, `version`, `reference`, `tests`, `analyses`
- `metadata.tags`, `metadata.source_ref` (populated from `metadata` kwarg)
"""
function mtk2esm(sys::ModelingToolkit.AbstractSystem; metadata = (;))
    kind = _sys_kind(sys)
    sys_name = _resolve_sys_name(sys, metadata, "UnnamedSystem")

    # When an MTK System was built via our ESM.Model → MTK.System path, the
    # flatten step sanitizes names as "<SystemName>_<var>" (dots → underscores).
    # We strip that prefix so the exported ESM names round-trip back to the
    # same bare names they had in the source Model. Direct-Symbolics-built
    # systems without the prefix pass through untouched.
    sys_name_prefix = sys_name * "_"
    strip_ns = s -> startswith(s, sys_name_prefix) ?
        s[(length(sys_name_prefix) + 1):end] : s

    esm_model, gaps = _export_system(sys, strip_ns)

    # Serialize directly to a Dict so callers can mutate and embed
    # TODO_GAP notes before writing to disk. We bypass the EsmFile type
    # because the tests/analyses fields are intentionally empty placeholders
    # the downstream migration step fills in later.
    model_dict = EarthSciAST.serialize_model(esm_model)

    # Build the Model-level `reference` entry. The schema defines Reference
    # with {doi, citation, url, notes} — we fold the migration description,
    # source_ref, and TODO_GAP notes into `notes` as a human-readable string
    # so the file stays schema-conformant. Later migration steps overwrite
    # this with a real citation when the source docstring is scraped.
    ref_notes_lines = _reference_notes(metadata, gaps)
    if !isempty(ref_notes_lines)
        model_dict["reference"] = Dict{String, Any}(
            "notes" => join(ref_notes_lines, "\n")
        )
    end
    # Always emit placeholder tests/analyses arrays: the schema treats them
    # as optional, but their empty presence is the downstream migration
    # tooling's "to be filled in" signal.
    model_dict["tests"] = Any[]
    model_dict["analyses"] = Any[]

    # Wrap in an EsmFile-shaped Dict
    out = Dict{String, Any}(
        "esm" => EarthSciAST.SCHEMA_VERSION,
        "metadata" => _esm_file_metadata(metadata, sys_name),
        "models" => Dict{String, Any}(sys_name => model_dict),
    )

    # Emit warnings
    _warn_gaps(gaps, "$(kind) $(sys_name)")

    return out
end

# Serialize the system's equations, flagging initialization equations, which
# have no export.
function _export_equations(
        sys, known_vars::Set{String},
        gaps::Vector{GapReport}, strip_ns::Function
    )
    esm_equations = Equation[]
    for (i, eq) in enumerate(ModelingToolkit.equations(sys))
        lhs_esm = _symbolic_to_esm_with_gaps(
            eq.lhs, known_vars, gaps,
            "equations[$i].lhs"; strip_ns = strip_ns
        )
        rhs_esm = _symbolic_to_esm_with_gaps(
            eq.rhs, known_vars, gaps,
            "equations[$i].rhs"; strip_ns = strip_ns
        )
        push!(esm_equations, Equation(lhs_esm, rhs_esm))
    end

    init_eqs = ModelingToolkit.has_initialization_eqs(sys) ?
        ModelingToolkit.initialization_equations(sys) : []
    if !isempty(init_eqs)
        push!(
            gaps, GapReport(
                "initialization_equations",
                "system declares $(length(init_eqs)) initialization equation(s), " *
                    "which the export does not serialize",
                "system.initialization_equations"
            )
        )
    end
    return esm_equations
end

# Serialize the system's continuous/discrete callbacks to ESM event lists.
function _export_events(sys, known_vars::Set{String}, gaps::Vector{GapReport})
    cont_events = ContinuousEvent[]
    disc_events = DiscreteEvent[]

    cont_cbs = ModelingToolkit.has_continuous_events(sys) ?
        ModelingToolkit.continuous_events(sys) : []
    for (i, cb) in enumerate(cont_cbs)
        ce = _continuous_cb_to_esm(cb, known_vars, gaps, "continuous_events[$i]")
        ce !== nothing && push!(cont_events, ce)
    end

    disc_cbs = ModelingToolkit.has_discrete_events(sys) ?
        ModelingToolkit.discrete_events(sys) : []
    for (i, cb) in enumerate(disc_cbs)
        de = _discrete_cb_to_esm(cb, known_vars, gaps, "discrete_events[$i]")
        de !== nothing && push!(disc_events, de)
    end
    return cont_events, disc_events
end

# --- metadata helpers ---
# (`_resolve_sys_name` / `_reference_notes` / `_esm_file_metadata` /
# `_warn_gaps` are MTK-independent and live in src/mtk_export.jl, shared
# with the Catalyst extension.)

# --- symbolic metadata extraction ---

function _get_default_or(var, default)
    try
        val = ModelingToolkit.getdefault(var)
        val isa Number && return Float64(val)
        return default
    catch e
        EarthSciAST._is_resource_error(e) && rethrow()
        # `getdefault` throws when the symbol carries no default metadata —
        # an expected miss, but log it so genuine failures stay diagnosable.
        @debug "mtk2esm: no readable default for $(var)" exception = (e, catch_backtrace())
        return default
    end
end

"""
Prefer the system-level defaults map (set via `System(...; defaults=...)`)
over per-symbol metadata. Returns `nothing` when no default is found so
the ESM `default` field is omitted rather than fabricated.
"""
function _lookup_default(var, sys_defaults)
    # The initial-conditions map is keyed by the unwrapped symbolic variable
    # (with its time dependence intact) and holds constants as symbolic nodes.
    key = Symbolics.unwrap(var)
    if haskey(sys_defaults, key)
        v = SymUtils.unwrap_const(sys_defaults[key])
        v isa Number && return Float64(v)
    end
    return _get_default_or(var, nothing)
end

function _get_units_str(var)
    raw = Symbolics.unwrap(var)
    try
        desc = Symbolics.getmetadata(raw, ModelingToolkit.VariableDescription, nothing)
        if desc isa AbstractString
            m = match(r"\(units=([^)]+)\)", desc)
            m !== nothing && return String(m.captures[1])
        end
    catch e
        EarthSciAST._is_resource_error(e) && rethrow()
        @debug "mtk2esm: units metadata unreadable for $(var)" exception = (e, catch_backtrace())
    end
    return nothing
end

function _get_description_str(var)
    raw = Symbolics.unwrap(var)
    try
        desc = Symbolics.getmetadata(raw, ModelingToolkit.VariableDescription, nothing)
        if desc isa AbstractString
            # Strip the embedded (units=...) suffix we inject ourselves on
            # the reverse path; preserve the human description, if any.
            stripped = replace(desc, r"\s*\(units=[^)]+\)\s*$" => "")
            return isempty(stripped) ? nothing : String(stripped)
        end
    catch e
        EarthSciAST._is_resource_error(e) && rethrow()
        @debug "mtk2esm: description metadata unreadable for $(var)" exception = (e, catch_backtrace())
    end
    return nothing
end

# --- event conversion (MTK → ESM) ---

function _continuous_cb_to_esm(
        cb, known_vars::Set{String},
        gaps::Vector{GapReport}, where_str::String
    )
    # MTK callbacks expose fields via property access that differs across
    # versions; we try a few shapes and fall back to a gap report if we
    # can't extract the pieces we need.
    try
        conds = cb.conditions isa AbstractArray ? cb.conditions : [cb.conditions]
        esm_conds = EsmExpr[]
        for c in conds
            push!(
                esm_conds, _symbolic_to_esm_with_gaps(
                    c, known_vars, gaps,
                    where_str * ".condition"
                )
            )
        end
        affects = cb.affects isa AbstractArray ? cb.affects : [cb.affects]
        esm_affs = AffectEquation[]
        for a in affects
            ae = _affect_to_esm(a, known_vars, gaps, where_str * ".affect")
            ae !== nothing && push!(esm_affs, ae)
        end
        return ContinuousEvent(esm_conds, esm_affs)
    catch e
        EarthSciAST._is_resource_error(e) && rethrow()
        push!(
            gaps, GapReport(
                "unknown",
                "unable to serialize continuous callback: $(sprint(showerror, e))",
                where_str
            )
        )
        return nothing
    end
end

function _discrete_cb_to_esm(
        cb, known_vars::Set{String},
        gaps::Vector{GapReport}, where_str::String
    )
    try
        trig_raw = hasproperty(cb, :condition) ? cb.condition : cb.conditions
        trigger = if trig_raw isa Real
            PeriodicTrigger(Float64(trig_raw))
        elseif trig_raw isa AbstractVector{<:Real}
            PresetTimesTrigger(Float64.(trig_raw))
        else
            ConditionTrigger(
                _symbolic_to_esm_with_gaps(
                    trig_raw, known_vars,
                    gaps, where_str * ".condition"
                )
            )
        end
        affects = cb.affects isa AbstractArray ? cb.affects : [cb.affects]
        esm_affs = AffectEquation[]
        for a in affects
            af = _affect_to_esm(
                a, known_vars, gaps,
                where_str * ".affect"
            )
            af !== nothing && push!(esm_affs, af)
        end
        return DiscreteEvent(trigger, esm_affs)
    catch e
        EarthSciAST._is_resource_error(e) && rethrow()
        push!(
            gaps, GapReport(
                "unknown",
                "unable to serialize discrete callback: $(sprint(showerror, e))",
                where_str
            )
        )
        return nothing
    end
end

# Serialize one MTK affect (an `lhs ~ rhs` shaped object or a 2-tuple) to an
# ESM `AffectEquation` (the affect shape shared by continuous and discrete
# events). An affect whose pieces cannot be extracted is recorded as a gap and
# returns `nothing`, so the enclosing callback carries fewer affects and the
# export says so.
function _affect_to_esm(
        a, known_vars::Set{String},
        gaps::Vector{GapReport}, where_str::String
    )
    try
        lhs_sym = hasproperty(a, :lhs) ? a.lhs : a[1]
        rhs_sym = hasproperty(a, :rhs) ? a.rhs : a[2]
        lhs_name = _strip_time(string(ModelingToolkit.getname(lhs_sym)))
        rhs_esm = _symbolic_to_esm_with_gaps(
            rhs_sym, known_vars, gaps,
            where_str * ".rhs"
        )
        return AffectEquation(lhs_name, rhs_esm)
    catch e
        EarthSciAST._is_resource_error(e) && rethrow()
        push!(
            gaps, GapReport(
                "unknown",
                "unable to serialize event affect: $(sprint(showerror, e))",
                where_str
            )
        )
        return nothing
    end
end

# --- unknown-operator gap detection ---

# Ops the exporter recognizes as standard; any other OpExpr op (a function the
# system calls that has no ESM operator) is flagged as a gap. Membership is
# declared per-op in src/op_registry.jl (flag `:mtk_known`) and pinned by
# op_registry_test.jl.
const _KNOWN_OPS = EarthSciAST._ops_with(:mtk_known)

function _detect_unknown_op_gaps!(
        gaps::Vector{GapReport},
        equations::Vector{Equation}
    )
    seen = Set{String}()
    for (i, eq) in enumerate(equations)
        _walk_expr_for_gaps!(eq.lhs, seen, gaps, "equations[$i].lhs")
        _walk_expr_for_gaps!(eq.rhs, seen, gaps, "equations[$i].rhs")
    end
    return
end

function _walk_expr_for_gaps!(
        expr, seen::Set{String}, gaps::Vector{GapReport},
        where_str::String
    )
    EarthSciAST.foreach_subexpr(expr) do x
        x isa OpExpr || return
        (x.op in _KNOWN_OPS || x.op in seen) && return
        push!(seen, x.op)
        push!(
            gaps, GapReport(
                "unknown_operator",
                "'$(x.op)' is not an ESM operator; express it with the " *
                    "built-in operators or an expression template (esm-spec §9.6)",
                where_str
            )
        )
    end
    return nothing
end

"""
    mtk2esm_gaps(sys::ModelingToolkit.AbstractSystem) -> Vector{GapReport}

Pre-flight gap scan: the gaps a full `mtk2esm` export of `sys` reports
(SDE noise matrices, initialization equations, unknown operators, PDE domains,
symbolic nodes that cannot be serialized), without wrapping the result in a
document, so migration tooling can gate models on the complete gap set.
"""
function mtk2esm_gaps(sys::ModelingToolkit.AbstractSystem)
    sys_name_prefix = _resolve_sys_name(sys, (;), "UnnamedSystem") * "_"
    strip_ns = s -> startswith(s, sys_name_prefix) ?
        s[(length(sys_name_prefix) + 1):end] : s
    return last(_export_system(sys, strip_ns))
end
