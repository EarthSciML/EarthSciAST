# ========================================
# Reverse direction: MTK → ESM Model
# ========================================

"""
    EarthSciAST.Model(sys::ModelingToolkit.AbstractSystem)

Convert a ModelingToolkit System back to an ESM `Model`. Supports ODESystems
and systems that expose `unknowns`, `parameters`, and `equations`.

Defaults come from the system defaults map / per-symbol metadata via
`_lookup_default`; when no default is recorded the ESM `default` field is
left as `nothing` (omitted on serialization) rather than fabricated.
Expressions are serialized with `_symbolic_to_esm_export` so callable
states `x(t)` become `VarExpr("x")` instead of the schema-invalid
`OpExpr("x", [VarExpr("t")])` shape.
"""
function EarthSciAST.Model(sys::ModelingToolkit.AbstractSystem)
    variables = Dict{String,ModelVariable}()

    sys_defaults = try
        ModelingToolkit.defaults(sys)
    catch e
        @debug "Model(sys): ModelingToolkit.defaults unavailable" exception=(e, catch_backtrace())
        Dict()
    end
    obs_eqs = try
        ModelingToolkit.observed(sys)
    catch e
        @debug "Model(sys): ModelingToolkit.observed unavailable" exception=(e, catch_backtrace())
        []
    end

    # Collect every known variable name up front so the expression walk can
    # disambiguate callable-symbolic states `x(t)` from operator calls.
    known_vars = Set{String}()
    for state in ModelingToolkit.unknowns(sys)
        push!(known_vars, _strip_time(string(ModelingToolkit.getname(state))))
    end
    for param in ModelingToolkit.parameters(sys)
        push!(known_vars, string(ModelingToolkit.getname(param)))
    end
    for obs in obs_eqs
        push!(known_vars, _strip_time(string(ModelingToolkit.getname(obs.lhs))))
    end

    for state in ModelingToolkit.unknowns(sys)
        var_name = _strip_time(string(ModelingToolkit.getname(state)))
        variables[var_name] = ModelVariable(StateVariable;
            default=_lookup_default(state, sys_defaults))
    end

    for param in ModelingToolkit.parameters(sys)
        pname = string(ModelingToolkit.getname(param))
        variables[pname] = ModelVariable(ParameterVariable;
            default=_lookup_default(param, sys_defaults))
    end

    for obs in obs_eqs
        oname = _strip_time(string(ModelingToolkit.getname(obs.lhs)))
        variables[oname] = ModelVariable(ObservedVariable;
            expression=_symbolic_to_esm_export(obs.rhs, known_vars))
    end

    equations = Equation[]
    for eq in ModelingToolkit.equations(sys)
        push!(equations, Equation(_symbolic_to_esm_export(eq.lhs, known_vars),
                                  _symbolic_to_esm_export(eq.rhs, known_vars)))
    end

    return Model(variables, equations)
end

# ========================================
# MTK → ESM export (gt-dod2; Phase 1 migration tooling)
# ========================================

"""
Return a user-facing system kind name used in warnings and TODO_GAP notes.
Catalyst.ReactionSystem is handled in the Catalyst extension; the cases
here cover plain MTK systems whose type name matches the expected system
class.
"""
function _sys_kind(sys)
    # Common arms: an exact type-name match (`nameof` sees through module
    # qualification and type parameters, unlike matching on the printed
    # type string).
    tn = string(nameof(typeof(sys)))
    tn in ("PDESystem", "SDESystem", "ReactionSystem",
           "NonlinearSystem", "ODESystem", "System") && return tn
    # Fallback for wrapped/renamed types (e.g. `MyPDESystemAdapter`): keep
    # the historical order-sensitive substring matching on the printed type.
    t = string(typeof(sys))
    if occursin("PDESystem", t);       return "PDESystem"
    elseif occursin("SDESystem", t);   return "SDESystem"
    elseif occursin("ReactionSystem", t); return "ReactionSystem"
    elseif occursin("NonlinearSystem", t); return "NonlinearSystem"
    elseif occursin("ODESystem", t);   return "ODESystem"
    else;                              return "System"
    end
end

# Return `true` if the System *declares* brownian variables (SDE). We detect
# by presence of the `brownians` getter on AbstractSystem (MTK v11+). For
# older systems or systems without the field, return `false`.
function _mtk_brownians(sys)
    try
        return ModelingToolkit.brownians(sys)
    catch
        return Any[]
    end
end

# Return the MTK system's noise_eqs vector, or empty if not set.
function _mtk_noise_eqs(sys)
    try
        return ModelingToolkit.get_noiseeqs(sys)
    catch
        return nothing
    end
end

# Ordered operator table of the MTK reverse walk, matched with `_op_matches`
# below. Wider than the Catalyst rate walk's table (which also matches by
# `==` only) — the two coverages are deliberate, live behavior; only the
# table-scan itself is shared (`_call_op_to_esm_name`).
const _MTK_EXPORT_OP_TABLE = (
    (+, "+"), (*, "*"), (-, "-"), (/, "/"), (^, "^"),
    (exp, "exp"), (log, "log"), (log10, "log10"),
    (sin, "sin"), (cos, "cos"), (tan, "tan"),
    (sqrt, "sqrt"), (abs, "abs"),
    (ifelse, "ifelse"), (min, "min"), (max, "max"))

# Check op equality, handling SymbolicUtils-wrapped forms.
_op_matches(op, target) = op == target || string(nameof(op)) == string(nameof(target))

# Convert a symbolic to ESM expression using a known set of variable names
# to disambiguate callable-symbolic nodes like `x(t)` from operator calls.
# MTK states and observed variables appear in the symbolic tree as
# `Sym{FnType{...}}(t)`, which a naive walk would emit as
# `OpExpr("x", [VarExpr("t")])` — the wrong shape for the ESM schema.
# `known_vars` lets us recognize those nodes and emit `VarExpr("x")`.
# (Scalar fast-paths, the Const-node branch, and the operator-table scan are
# shared with the Catalyst rate walk — see ext/shared/symbolic_to_esm.jl.)
function _symbolic_to_esm_export(expr, known_vars::Set{String},
                                 strip_ns::Function=identity)
    # Scalar fast-paths
    lit = _number_to_esm_literal(expr)
    lit === nothing || return lit
    raw = Symbolics.unwrap(expr)

    # Symbolic constants (e.g. `-1` produced by SymbolicUtils' multiplication
    # simplification `-k*x`) arrive as `BasicSymbolic{Int}` / `...{Real}`
    # with issym=false AND iscall=false.
    if !Symbolics.issym(raw) && !Symbolics.iscall(raw)
        const_lit = try
            _symbolic_const_to_esm(raw)
        catch
            nothing
        end
        const_lit === nothing || return const_lit
    end

    if Symbolics.issym(raw)
        name = strip_ns(_strip_time(string(Symbolics.getname(raw))))
        return VarExpr(name)
    end

    is_diff = try
        Symbolics.is_derivative(raw)
    catch
        false
    end
    if is_diff
        inner = _symbolic_to_esm_export(Symbolics.arguments(raw)[1],
                                         known_vars, strip_ns)
        return OpExpr("D", EsmExpr[inner], wrt="t")
    end

    if Symbolics.iscall(raw)
        op = Symbolics.operation(raw)
        args = Symbolics.arguments(raw)

        # Callable-symbolic variable: `x(t)` where `x` is a state/observed
        # var. Recognize by checking if the operation's name is a known
        # variable. Preserve as a bare VarExpr(name), dropping the IV args
        # — the ESM schema implicitly threads time through state vars.
        if !isempty(args)
            opname = try
                strip_ns(_strip_time(string(Symbolics.getname(op))))
            catch
                ""
            end
            if !isempty(opname) && opname in known_vars
                return VarExpr(opname)
            end
        end

        esm_args = [_symbolic_to_esm_export(a, known_vars, strip_ns) for a in args]
        esm_op = _call_op_to_esm_name(op, _MTK_EXPORT_OP_TABLE, _op_matches)
        esm_op === nothing || return OpExpr(esm_op, esm_args)
        opname = try
            string(nameof(op))
        catch
            string(op)
        end
        return OpExpr(opname, esm_args)
    end
    return VarExpr(string(expr))
end

function _symbolic_to_esm_with_gaps(expr, known_vars::Set{String},
                                    gaps::Vector{GapReport}, where_str::String;
                                    strip_ns::Function=identity)
    try
        return _symbolic_to_esm_export(expr, known_vars, strip_ns)
    catch e
        push!(gaps, GapReport("unknown",
            "unable to serialize symbolic node: $(sprint(showerror, e))",
            where_str))
        return VarExpr("__TODO_GAP__")
    end
end

# (`_resolve_sys_name` is MTK-independent and lives in src/mtk_export.jl,
# shared with the Catalyst extension.)

# Export states / parameters / observed / brownian variables from `sys` into
# `esm_vars`, registering every exported name in `known_vars` (used by the
# expression walk to disambiguate callable-symbolic states from op calls).
function _export_variables!(esm_vars::Dict{String,ModelVariable},
                            known_vars::Set{String}, gaps::Vector{GapReport},
                            sys, strip_ns::Function)
    # System-level defaults dict — variables declared via `defaults=Dict(...)`
    # on System construction surface here rather than on the symbolic
    # metadata. We look up both and prefer the system-level value.
    sys_defaults = try
        ModelingToolkit.defaults(sys)
    catch e
        @debug "mtk2esm: ModelingToolkit.defaults unavailable" exception=(e, catch_backtrace())
        Dict()
    end

    for state in ModelingToolkit.unknowns(sys)
        var_name = strip_ns(_strip_time(string(ModelingToolkit.getname(state))))
        push!(known_vars, var_name)
        esm_vars[var_name] = ModelVariable(StateVariable;
            default=_lookup_default(state, sys_defaults),
            units=_get_units_str(state),
            description=_get_description_str(state))
    end

    for param in ModelingToolkit.parameters(sys)
        pname = strip_ns(string(ModelingToolkit.getname(param)))
        push!(known_vars, pname)
        esm_vars[pname] = ModelVariable(ParameterVariable;
            default=_lookup_default(param, sys_defaults),
            units=_get_units_str(param),
            description=_get_description_str(param))
    end

    obs_exprs = try
        ModelingToolkit.observed(sys)
    catch e
        @debug "mtk2esm: ModelingToolkit.observed unavailable" exception=(e, catch_backtrace())
        []
    end
    for obs in obs_exprs
        oname = strip_ns(_strip_time(string(ModelingToolkit.getname(obs.lhs))))
        push!(known_vars, oname)
        rhs_esm = _symbolic_to_esm_with_gaps(obs.rhs, known_vars, gaps,
            "observed[$oname].rhs"; strip_ns=strip_ns)
        esm_vars[oname] = ModelVariable(ObservedVariable;
            expression=rhs_esm)
    end

    # Brownian variables (SDE noise sources) — gt-kuxo gate.
    brownians = _mtk_brownians(sys)
    if !isempty(brownians)
        push!(gaps, GapReport("gt-kuxo",
            "system has $(length(brownians)) brownian variable(s); " *
            "SDE noise serialization requires gt-kuxo to land first",
            "system.brownians"))
        for b in brownians
            bname = string(ModelingToolkit.getname(b))
            esm_vars[bname] = ModelVariable(BrownianVariable;
                noise_kind="wiener")
        end
    end

    noise_eqs = _mtk_noise_eqs(sys)
    if noise_eqs !== nothing && !isempty(noise_eqs)
        push!(gaps, GapReport("gt-kuxo",
            "system has explicit noise_eqs matrix; serialization of SDE " *
            "diffusion terms requires gt-kuxo to land first",
            "system.noise_eqs"))
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

Fields left as placeholders (filled in Phase 2 per-model migrations):
- `description`, `version`, `reference`, `tests`, `examples`
- `metadata.tags`, `metadata.source_ref` (populated from `metadata` kwarg)
"""
function mtk2esm(sys::ModelingToolkit.AbstractSystem; metadata=(;))
    gaps = GapReport[]

    kind = _sys_kind(sys)
    sys_name = _resolve_sys_name(sys, metadata, "UnnamedSystem")

    # When an MTK System was built via our ESM.Model → MTK.System path, the
    # flatten step sanitizes names as "<SystemName>_<var>" (dots → underscores).
    # We strip that prefix so the exported ESM names round-trip back to the
    # same bare names they had in the source Model. Direct-Symbolics-built
    # systems without the prefix pass through untouched.
    sys_name_prefix = sys_name * "_"
    strip_ns = s -> startswith(s, sys_name_prefix) ?
        s[length(sys_name_prefix)+1:end] : s

    # 1. Variables -----------------------------------------------------------
    esm_vars = Dict{String,ModelVariable}()
    known_vars = Set{String}()
    _export_variables!(esm_vars, known_vars, gaps, sys, strip_ns)

    # 2. Equations -----------------------------------------------------------
    esm_equations = _export_equations(sys, known_vars, gaps, strip_ns)

    # registered symbolic functions (gt-p3ep gate): detected by scanning the
    # symbolic AST for unknown `iscall` operations whose operation has a
    # non-Base name. Done during the recursive _symbolic_to_esm_export walk
    # when a call to a user-registered function produces an OpExpr with a non-
    # standard op name — conservatively report a generic gap note if we saw
    # operator names not in the schema's standard op set.
    _detect_registered_call_gaps!(gaps, esm_equations)

    # 3. Events --------------------------------------------------------------
    cont_events, disc_events = _export_events(sys, known_vars, gaps)

    # 4. Domain (PDE only) ---------------------------------------------------
    esm_domain = nothing
    if kind == "PDESystem"
        # PDESystem carries domain info; we flag as gap for now since the
        # round-trip of domain specs requires dedicated lowering logic.
        push!(gaps, GapReport("gt-vzwk",
            "PDESystem domain specification is not yet serialized — see gt-vzwk",
            "system.domain"))
    end

    # 5. Build ESM Model and wrap in EsmFile --------------------------------
    # NOTE (esm-spec v0.8.0): `domain` moved from the Model to the document
    # level, so `Model(...)` no longer accepts a `domain=` kwarg. PDE domain
    # round-trip is still an open gap (gt-vzwk, flagged above), and `esm_domain`
    # is always `nothing` here, so there is nothing to place at the document
    # level yet — the kwarg is simply dropped.
    esm_model = Model(esm_vars, esm_equations;
        discrete_events=disc_events, continuous_events=cont_events)

    # Serialize directly to a Dict so callers can mutate and embed
    # TODO_GAP notes before writing to disk. We bypass the EsmFile type
    # because the tests/examples fields are intentionally empty placeholders
    # the downstream migration step fills in later.
    model_dict = EarthSciAST.serialize_model(esm_model)

    # Build the Model-level `reference` entry. The schema defines Reference
    # with {doi, citation, url, notes} — we fold the migration description,
    # source_ref, and TODO_GAP notes into `notes` as a human-readable string
    # so the file stays schema-conformant. Later migration steps overwrite
    # this with a real citation when the source docstring is scraped.
    ref_notes_lines = _reference_notes(metadata, gaps)
    if !isempty(ref_notes_lines)
        model_dict["reference"] = Dict{String,Any}(
            "notes" => join(ref_notes_lines, "\n"))
    end
    # Always emit placeholder tests/examples arrays: the schema treats them
    # as optional, but their empty presence is the downstream migration
    # tooling's "to be filled in Phase 2" signal.
    model_dict["tests"] = Any[]
    model_dict["examples"] = Any[]

    # 6. Wrap in EsmFile-shaped Dict ----------------------------------------
    out = Dict{String,Any}(
        "esm" => EarthSciAST.ESM_FORMAT_VERSION,
        "metadata" => _esm_file_metadata(metadata, sys_name),
        "models" => Dict{String,Any}(sys_name => model_dict),
    )

    # 7. Emit warnings --------------------------------------------------------
    _warn_gaps(gaps, "$(kind) $(sys_name)")

    return out
end

# Serialize the system's equations, flagging init equations (gt-ebuq gate).
function _export_equations(sys, known_vars::Set{String},
                           gaps::Vector{GapReport}, strip_ns::Function)
    esm_equations = Equation[]
    raw_eqs = try
        ModelingToolkit.equations(sys)
    catch e
        @debug "mtk2esm: ModelingToolkit.equations unavailable" exception=(e, catch_backtrace())
        []
    end
    for (i, eq) in enumerate(raw_eqs)
        lhs_esm = _symbolic_to_esm_with_gaps(eq.lhs, known_vars, gaps,
            "equations[$i].lhs"; strip_ns=strip_ns)
        rhs_esm = _symbolic_to_esm_with_gaps(eq.rhs, known_vars, gaps,
            "equations[$i].rhs"; strip_ns=strip_ns)
        push!(esm_equations, Equation(lhs_esm, rhs_esm))
    end

    # init equations (gt-ebuq gate) — present on MTK v11 systems
    init_eqs = try
        ModelingToolkit.initialization_equations(sys)
    catch e
        @debug "mtk2esm: initialization_equations unavailable" exception=(e, catch_backtrace())
        []
    end
    if !isempty(init_eqs)
        push!(gaps, GapReport("gt-ebuq",
            "system declares $(length(init_eqs)) init equation(s); " *
            "serialization of initialization blocks requires gt-ebuq",
            "system.initialization_equations"))
    end
    return esm_equations
end

# Serialize the system's continuous/discrete callbacks to ESM event lists.
function _export_events(sys, known_vars::Set{String}, gaps::Vector{GapReport})
    cont_events = ContinuousEvent[]
    disc_events = DiscreteEvent[]

    cont_cbs = try
        ModelingToolkit.continuous_events(sys)
    catch e
        @debug "mtk2esm: continuous_events unavailable" exception=(e, catch_backtrace())
        []
    end
    for (i, cb) in enumerate(cont_cbs)
        ce = _continuous_cb_to_esm(cb, known_vars, gaps, "continuous_events[$i]")
        ce !== nothing && push!(cont_events, ce)
    end

    disc_cbs = try
        ModelingToolkit.discrete_events(sys)
    catch e
        @debug "mtk2esm: discrete_events unavailable" exception=(e, catch_backtrace())
        []
    end
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
        # `getdefault` throws when the symbol carries no default metadata —
        # an expected miss, but log it so genuine failures stay diagnosable.
        @debug "mtk2esm: no readable default for $(var)" exception=(e, catch_backtrace())
        return default
    end
end

"""
Prefer the system-level defaults map (set via `System(...; defaults=...)`)
over per-symbol metadata. Returns `nothing` when no default is found so
the ESM `default` field is omitted rather than fabricated.
"""
function _lookup_default(var, sys_defaults)
    # System-level defaults dict uses the symbolic variable itself (with its
    # time dependence intact) as the key.
    if haskey(sys_defaults, var)
        v = sys_defaults[var]
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
        @debug "mtk2esm: units metadata unreadable for $(var)" exception=(e, catch_backtrace())
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
        @debug "mtk2esm: description metadata unreadable for $(var)" exception=(e, catch_backtrace())
    end
    return nothing
end

# --- event conversion (MTK → ESM) ---

function _continuous_cb_to_esm(cb, known_vars::Set{String},
                               gaps::Vector{GapReport}, where_str::String)
    # MTK callbacks expose fields via property access that differs across
    # versions; we try a few shapes and fall back to a gap report if we
    # can't extract the pieces we need.
    try
        conds = cb.conditions isa AbstractArray ? cb.conditions : [cb.conditions]
        esm_conds = EsmExpr[]
        for c in conds
            push!(esm_conds, _symbolic_to_esm_with_gaps(c, known_vars, gaps,
                where_str * ".condition"))
        end
        affects = cb.affects isa AbstractArray ? cb.affects : [cb.affects]
        esm_affs = AffectEquation[]
        for a in affects
            ae = _affect_to_esm(a, known_vars, gaps, where_str * ".affect")
            ae !== nothing && push!(esm_affs, ae)
        end
        return ContinuousEvent(esm_conds, esm_affs)
    catch e
        push!(gaps, GapReport("unknown",
            "unable to serialize continuous callback: $(sprint(showerror, e))",
            where_str))
        return nothing
    end
end

function _discrete_cb_to_esm(cb, known_vars::Set{String},
                             gaps::Vector{GapReport}, where_str::String)
    try
        trig_raw = hasproperty(cb, :condition) ? cb.condition : cb.conditions
        trigger = if trig_raw isa Real
            PeriodicTrigger(Float64(trig_raw))
        elseif trig_raw isa AbstractVector{<:Real}
            PresetTimesTrigger(Float64.(trig_raw))
        else
            ConditionTrigger(_symbolic_to_esm_with_gaps(trig_raw, known_vars,
                gaps, where_str * ".condition"))
        end
        affects = cb.affects isa AbstractArray ? cb.affects : [cb.affects]
        esm_affs = FunctionalAffect[]
        for a in affects
            af = _affect_to_functional(a, known_vars, gaps,
                where_str * ".affect")
            af !== nothing && push!(esm_affs, af)
        end
        return DiscreteEvent(trigger, esm_affs)
    catch e
        push!(gaps, GapReport("unknown",
            "unable to serialize discrete callback: $(sprint(showerror, e))",
            where_str))
        return nothing
    end
end

# Serialize one MTK affect (an `lhs ~ rhs` shaped object or a 2-tuple) to an
# ESM affect record built by `make(lhs_name, rhs_esm)` — `AffectEquation` for
# continuous events, the operation="set" `FunctionalAffect` for discrete
# ones. Returns `nothing` when the affect's pieces can't be extracted (the
# enclosing callback then simply carries fewer affects).
function _affect_to_esm_record(a, known_vars::Set{String},
                               gaps::Vector{GapReport}, where_str::String,
                               make::Function)
    try
        lhs_sym = hasproperty(a, :lhs) ? a.lhs : a[1]
        rhs_sym = hasproperty(a, :rhs) ? a.rhs : a[2]
        lhs_name = _strip_time(string(ModelingToolkit.getname(lhs_sym)))
        rhs_esm = _symbolic_to_esm_with_gaps(rhs_sym, known_vars, gaps,
            where_str * ".rhs")
        return make(lhs_name, rhs_esm)
    catch e
        @debug "mtk2esm: unable to serialize event affect at $(where_str)" exception=(e, catch_backtrace())
        return nothing
    end
end

_affect_to_esm(a, known_vars::Set{String},
               gaps::Vector{GapReport}, where_str::String) =
    _affect_to_esm_record(a, known_vars, gaps, where_str,
        (lhs_name, rhs_esm) -> AffectEquation(lhs_name, rhs_esm))

_affect_to_functional(a, known_vars::Set{String},
                      gaps::Vector{GapReport}, where_str::String) =
    _affect_to_esm_record(a, known_vars, gaps, where_str,
        (lhs_name, rhs_esm) -> FunctionalAffect(lhs_name, rhs_esm; operation="set"))

# --- registered-function gap detection ---

# Ops the exporter recognizes as standard; any other OpExpr op is flagged as a
# likely registered-function gap. Membership is declared per-op in
# src/op_registry.jl (flag `:mtk_known`) and pinned by op_registry_test.jl.
const _KNOWN_OPS = EarthSciAST._ops_with(:mtk_known)

function _detect_registered_call_gaps!(gaps::Vector{GapReport},
                                       equations::Vector{Equation})
    seen = Set{String}()
    for (i, eq) in enumerate(equations)
        _walk_expr_for_gaps!(eq.lhs, seen, gaps, "equations[$i].lhs")
        _walk_expr_for_gaps!(eq.rhs, seen, gaps, "equations[$i].rhs")
    end
end

function _walk_expr_for_gaps!(expr, seen::Set{String}, gaps::Vector{GapReport},
                              where_str::String)
    if expr isa OpExpr
        if !(expr.op in _KNOWN_OPS) && !(expr.op in seen)
            push!(seen, expr.op)
            push!(gaps, GapReport("gt-p3ep",
                "non-standard op '$(expr.op)' likely requires a registered " *
                "function declaration — see gt-p3ep",
                where_str))
        end
        for a in expr.args
            _walk_expr_for_gaps!(a, seen, gaps, where_str)
        end
    end
end

"""
    mtk2esm_gaps(sys::ModelingToolkit.AbstractSystem) -> Vector{GapReport}

Cheap pre-flight check that currently detects ONLY brownian variables
(SDE noise, gt-kuxo). It does NOT replicate the full gap detection
performed during a `mtk2esm` export (init equations, noise_eqs,
registered-function calls, PDE domains); run `mtk2esm` itself for the
complete gap report.
"""
# TODO(aspiration): grow this into the full pre-flight scan promised by the
# original design — same gap coverage as mtk2esm without producing the
# export — so migration tooling can gate models cheaply.
function mtk2esm_gaps(sys::ModelingToolkit.AbstractSystem)
    gaps = GapReport[]
    b = _mtk_brownians(sys)
    isempty(b) || push!(gaps, GapReport("gt-kuxo",
        "system has $(length(b)) brownian variable(s)",
        "system.brownians"))
    return gaps
end
