"""
ESM Format Schema Validation

Provides functionality to validate ESM files against the JSON schema.
"""

using JSON3
using JSONSchema

"""
    SchemaError

Represents a validation error with detailed information.
Contains path, message, and keyword from JSON Schema validation.
"""
struct SchemaError
    path::String
    message::String
    keyword::String
end

"""
    StructuralError

Represents a structural validation error with detailed information.
Contains path, message, error type, and machine-readable `details`.

`details` is the MACHINE-READABLE half of the error, and Julia was the only
binding without it (CONFORMANCE_SPEC row (j)). A conformance pin asserts code,
path AND `details` under REQUIRED-SUBSET semantics (§7.1.2): every key the pin
names must be present with the pinned value, and extra keys are fine. Without the
field Julia cannot satisfy the 134 pins that carry one — it would be red in the
harness for a structural reason rather than a real disagreement.

It defaults to empty, so the three-positional-argument construction used
throughout keeps working; sites that name a variable populate `details["variable"]`
(the settled spelling), plus whatever else is locally meaningful.
"""
struct StructuralError
    path::String
    message::String
    error_type::String
    details::Dict{String,Any}

    StructuralError(path::AbstractString, message::AbstractString, error_type::AbstractString,
                    details::AbstractDict=Dict{String,Any}()) =
        new(String(path), String(message), String(error_type), Dict{String,Any}(details))
end

"""
    ValidationResult

Combined validation result containing schema errors, structural errors,
unit warnings, and overall validation status.

`unit_warnings` mirrors the TS/Python bindings' `ValidationResult` shape:
unit findings appear both here (as human-readable strings) and as promoted
`unit_inconsistency` entries in `structural_errors`. Unit warnings never
affect `is_valid` on their own — the promoted structural errors do.
"""
struct ValidationResult
    is_valid::Bool
    schema_errors::Vector{SchemaError}
    structural_errors::Vector{StructuralError}
    unit_warnings::Vector{String}
end

# Constructor for ValidationResult
ValidationResult(schema_errors::Vector{SchemaError}, structural_errors::Vector{StructuralError}; unit_warnings::Vector{String}=String[]) =
    ValidationResult(isempty(schema_errors) && isempty(structural_errors), schema_errors, structural_errors, unit_warnings)

"""
    SchemaValidationError

Exception thrown when schema validation fails.
Contains detailed error information including paths and messages.
"""
struct SchemaValidationError <: Exception
    message::String
    errors::Vector{SchemaError}
end

# `message` is already the fully rendered multi-line diagnostic
# (`_format_schema_errors`), so the standard "TypeName: message" layout is all
# that is added here.
Base.showerror(io::IO, e::SchemaValidationError) =
    print(io, "SchemaValidationError: ", e.message)

# Load schema at module initialization from bundled package data
const SCHEMA_PATH = joinpath(pkgdir(@__MODULE__), "data", "esm-schema.json")
# Track data file so precompile cache invalidates when schema changes.
@static if ccall(:jl_generating_output, Cint, ()) == 1
    include_dependency(SCHEMA_PATH)
end

# Global schema validator
const ESM_SCHEMA = if isfile(SCHEMA_PATH)
    try
        Schema(JSON3.read(read(SCHEMA_PATH, String)))
    catch e
        @warn "Failed to load ESM schema: $e"
        nothing
    end
else
    @warn "ESM schema file not found at $SCHEMA_PATH"
    nothing
end

# JSONSchema.jl formats issue paths as "[a][b][3]"; convert to a
# JSON-Pointer-style "/a/b/3". The DOCUMENT ROOT is the empty string "" (the
# cross-language wire contract — NOT "/", "$", or "(root)" — CONFORMANCE_SPEC
# §7.1.2). Retained for any caller still speaking the bracket form.
function _issue_pointer(path::AbstractString)::String
    isempty(path) && return ""
    segments = [String(m.captures[1]) for m in eachmatch(r"\[([^\]]*)\]", path)]
    isempty(segments) && return ""
    return "/" * join(segments, "/")
end

# ── Schema-error collection (AJV-parity leaf enumeration) ───────────────────
#
# JSONSchema.jl's `validate` short-circuits at the FIRST failing keyword and, at
# a `oneOf`/`anyOf`/`allOf` node, reports ONLY the enclosing combinator — never
# the underlying keyword (e.g. the missing `required` inside the intended
# branch). It also reports the whole document at path "" but everything else at
# a 1-based Julia bracket path. The cross-language conformance contract
# (CONFORMANCE_SPEC §7.1.2) instead wants ONE record per schema violation, each
# carrying the standard JSON-Schema keyword that failed and the RFC-6901 JSON
# Pointer of the offending node (0-based array indices, root ""), matching
# TypeScript's AJV `allErrors` output.
#
# `_collect_schema_errors!` re-walks the (ref-resolved) schema alongside the
# instance and accumulates every leaf failure. It REUSES JSONSchema.jl's own
# `_validate`: as a whole-subschema pass/fail ORACLE at combinator decision
# points (so the verdict on which branch matched is byte-for-byte the library's)
# and to evaluate the leaf assertion keywords (`type`, `required`, `enum`, …)
# exactly as the library does. Only the applicator keywords
# (`properties`/`items`/`oneOf`/`if`…) are descended here, so a VALID document —
# every combinator satisfied — yields ZERO errors, identical to the library.

# RFC-6901 JSON Pointer builder. Each segment is prefixed with "/"; the special
# characters `~` and `/` are escaped per §4 of the RFC.
_ptr_escape(seg::AbstractString) = replace(replace(seg, "~" => "~0"), "/" => "~1")
_ptr_child(path::AbstractString, seg) = string(path, "/", _ptr_escape(string(seg)))

# Schema keywords that carry no assertion of their own (identifiers, metadata,
# and the `$defs`/`definitions` stores), skipped during the walk.
const _SCHEMA_ANNOTATION_KEYS = Set{String}([
    "\$schema", "\$id", "\$ref", "\$anchor", "\$dynamicAnchor", "\$dynamicRef",
    "\$vocabulary", "\$comment", "\$defs", "definitions",
    "title", "description", "examples", "default", "deprecated",
    "readOnly", "writeOnly", "contentEncoding", "contentMediaType",
])

# Does instance `x` satisfy `subschema` in full? Delegated to JSONSchema.jl so
# the branch-selection verdict is identical to the library's.
_schema_matches(x, subschema) = JSONSchema._validate(x, subschema, "") === nothing

function _schema_error_message(keyword::AbstractString)::String
    keyword == "required"             && return "missing required property"
    keyword == "additionalProperties" && return "unexpected additional property"
    keyword == "type"                 && return "value has the wrong type"
    keyword == "enum"                 && return "value is not one of the permitted values"
    keyword == "const"                && return "value does not equal the required constant"
    keyword == "oneOf"                && return "must match exactly one schema in oneOf"
    keyword == "anyOf"                && return "must match at least one schema in anyOf"
    keyword == "not"                  && return "must not match the schema"
    return "schema validation failed: $keyword"
end

_push_schema_error!(errors::Vector{SchemaError}, path::AbstractString, keyword::AbstractString) =
    push!(errors, SchemaError(String(path), _schema_error_message(keyword), String(keyword)))

function _collect_schema_errors!(errors::Vector{SchemaError}, x, schema, path::String)
    schema = JSONSchema._resolve_refs(schema)
    if schema isa Bool
        schema || _push_schema_error!(errors, path, "schema")
        return errors
    end
    schema isa AbstractDict || return errors
    for (k, v) in schema
        _collect_schema_keyword!(errors, x, schema, String(k), v, path)
    end
    return errors
end

function _collect_schema_keyword!(errors::Vector{SchemaError}, x, schema, k::String, v, path::String)
    if k in _SCHEMA_ANNOTATION_KEYS || k == "then" || k == "else"
        # `then`/`else` are evaluated together with `if` (below).
        return errors

    elseif k == "properties"
        if x isa AbstractDict && v isa AbstractDict
            for (pk, sub) in v
                skey = String(pk)
                haskey(x, skey) || continue
                _collect_schema_errors!(errors, x[skey], sub, _ptr_child(path, skey))
            end
        end

    elseif k == "patternProperties"
        if x isa AbstractDict && v isa AbstractDict
            for (pat, sub) in v
                r = Regex(String(pat))
                for (xk, xv) in x
                    occursin(r, String(xk)) &&
                        _collect_schema_errors!(errors, xv, sub, _ptr_child(path, xk))
                end
            end
        end

    elseif k == "additionalProperties"
        if x isa AbstractDict
            props = get(schema, "properties", nothing)
            patterns = get(schema, "patternProperties", nothing)
            _covered(key) =
                (props isa AbstractDict && haskey(props, String(key))) ||
                (patterns isa AbstractDict &&
                 any(p -> occursin(Regex(String(p)), String(key)), keys(patterns)))
            if v isa Bool
                v || for (xk, _) in x
                    _covered(xk) || _push_schema_error!(errors, path, "additionalProperties")
                end
            else
                for (xk, xv) in x
                    _covered(xk) ||
                        _collect_schema_errors!(errors, xv, v, _ptr_child(path, xk))
                end
            end
        end

    elseif k == "items"
        if x isa AbstractVector
            if v isa AbstractVector
                # Tuple validation: element i against subschema i (1-based Julia).
                for (i, xi) in enumerate(x)
                    i <= length(v) || break
                    _collect_schema_errors!(errors, xi, v[i], _ptr_child(path, i - 1))
                end
            else
                for (i, xi) in enumerate(x)
                    _collect_schema_errors!(errors, xi, v, _ptr_child(path, i - 1))
                end
            end
        end

    elseif k == "allOf"
        v isa AbstractVector && for sub in v
            _collect_schema_errors!(errors, x, sub, path)
        end

    elseif k == "anyOf"
        if v isa AbstractVector && !any(sub -> _schema_matches(x, sub), v)
            _push_schema_error!(errors, path, "anyOf")
            for sub in v
                _collect_schema_errors!(errors, x, sub, path)
            end
        end

    elseif k == "oneOf"
        if v isa AbstractVector
            nmatch = count(sub -> _schema_matches(x, sub), v)
            if nmatch != 1
                _push_schema_error!(errors, path, "oneOf")
                # ZERO matches ⇒ every branch failed, so descend them all for the
                # underlying leaf errors. ≥2 matches ⇒ the branches PASS (no leaf
                # error to find); the `oneOf` itself is the finding.
                nmatch == 0 && for sub in v
                    _collect_schema_errors!(errors, x, sub, path)
                end
            end
        end

    elseif k == "not"
        _schema_matches(x, v) && _push_schema_error!(errors, path, "not")

    elseif k == "if"
        if haskey(schema, "then") || haskey(schema, "else")
            if _schema_matches(x, v)
                haskey(schema, "then") &&
                    _collect_schema_errors!(errors, x, schema["then"], path)
            elseif haskey(schema, "else")
                _collect_schema_errors!(errors, x, schema["else"], path)
            end
        end

    else
        # Leaf assertion keyword (`type`, `required`, `enum`, `minItems`,
        # `pattern`, `exclusiveMinimum`, …): evaluated by JSONSchema.jl exactly
        # as in a normal validation. A non-`nothing` return means it failed at
        # THIS node; the standard keyword name is `k`.
        JSONSchema._validate(x, schema, Val{Symbol(k)}(), v, path) === nothing ||
            _push_schema_error!(errors, path, k)
    end
    return errors
end

# Collapse identical (path, keyword) findings (a `oneOf` branch descent or a
# per-extra-key `additionalProperties` scan can raise the same finding twice).
# The comparator matches on (keyword, path) sets, so this is loss-free.
function _dedup_schema_errors(errors::Vector{SchemaError})::Vector{SchemaError}
    seen = Set{Tuple{String,String}}()
    out = SchemaError[]
    for e in errors
        key = (e.path, e.keyword)
        key in seen && continue
        push!(seen, key)
        push!(out, e)
    end
    return out
end

"""
    validate_schema(data::Any) -> Vector{SchemaError}

Validate `data` (a native JSON tree of `Dict`/`Vector`/scalars) against the ESM
schema. Returns an empty vector when valid; otherwise ONE `SchemaError` per
schema violation (CONFORMANCE_SPEC §7.1.2), each carrying:

- `path` — the RFC-6901 JSON Pointer of the offending node (document root `""`,
  0-based array indices);
- `keyword` — the JSON-Schema keyword that failed (`required`, `type`, `enum`,
  `minItems`, `oneOf`, `additionalProperties`, …);
- `message` — free human-readable text (not part of the conformance contract).

Unlike JSONSchema.jl's single-issue `validate`, this enumerates leaf failures
INSIDE failed `oneOf`/`anyOf`/`allOf`/`if` branches (see
`_collect_schema_errors!`), matching TypeScript's AJV `allErrors` output.
"""
function validate_schema(data::Any)::Vector{SchemaError}
    if ESM_SCHEMA === nothing
        @warn "Schema validation skipped - schema not loaded"
        return SchemaError[]
    end
    errors = SchemaError[]
    try
        # Normalise to NATIVE JSON containers first. The two callers hand this
        # function different carriers — the conformance producer a native
        # `Dict{String,Any}` tree, but `load` the raw `JSON3.Object` straight off
        # the parser — and JSON3's `JSON3.Array` is not a `Base.Array`, so
        # JSONSchema.jl's `type: array` check (and every `oneOf` branch that
        # depends on it) misfires on the JSON3 carrier. Coercing to native
        # containers makes the walk carrier-independent (the same reason
        # `validate()` funnels its input through `_plain_json`).
        native = _to_native_json(data)
        _collect_schema_errors!(errors, native, ESM_SCHEMA.data, "")
    catch e
        return [SchemaError("", "Schema validation error: $(e)", "error")]
    end
    return _dedup_schema_errors(errors)
end

"""
    validate_structural(file::EsmFile) -> Vector{StructuralError}

Validate structural consistency of ESM file according to spec Section 3.2.
Checks equation-unknown balance, reference integrity, reaction consistency,
and event consistency.

Error paths use 0-based JSON-Pointer slash style (e.g.
`/models/M/equations/0`), matching the shared cross-language fixtures in
`tests/invalid/expected_errors.json` and the TS/Python bindings.
"""
function validate_structural(file::EsmFile)::Vector{StructuralError}
    errors = StructuralError[]

    # 1. Validate model equation-unknown balance.
    #
    # (e) A COUPLED model is skipped ENTIRELY. Its states may be supplied from
    # outside — by a `variable_map` (tests/valid/data_loaders_comprehensive.esm
    # feeds `SimpleChemistry.wind_u` from a loader) or by the system it is
    # composed onto — so its own equations need not balance its own unknowns.
    # Demanding a defining equation for every declared state rejected three
    # perfectly good fixtures. The narrower `check_excess=false` carve-out that
    # used to stand in for this was only half the rule: it forgave the EXTRA
    # equations and still demanded the MISSING ones.
    if file.models !== nothing
        coupled = _coupled_system_names(file)
        composed = _operator_composed_systems(file)
        for (model_name, model) in file.models
            model_name ∈ coupled && continue
            append!(errors, validate_model_balance(model, "/models/$model_name";
                                                   check_excess = model_name ∉ composed))
        end
    end

    # 2. Validate reference integrity
    append!(errors, validate_reference_integrity(file))

    # 3. Validate reaction system consistency
    if file.reaction_systems !== nothing
        for (rs_name, rs) in file.reaction_systems
            append!(errors, validate_reaction_consistency(rs, "/reaction_systems/$rs_name";
                                                          indep=_indep_var(file)))
            append!(errors, validate_reaction_rate_units(rs, "/reaction_systems/$rs_name"))
        end
    end

    # 3b. Data-loader `unit_conversion` expressions (audit finding (h)). A
    # loader variable's conversion may be an Expression rather than a numeric
    # factor, and nothing walked it — an undefined name in one was invisible.
    # Its scope is the loader's own declared variables.
    if file.data_loaders !== nothing
        for loader_name in sort!(collect(keys(file.data_loaders)))
            loader = file.data_loaders[loader_name]
            lscope = Set{String}(keys(loader.variables))
            for vname in sort!(collect(keys(loader.variables)))
                uc = loader.variables[vname].unit_conversion
                isa(uc, ASTExpr) || continue
                append!(errors, validate_expression_references(
                    file, uc, "/data_loaders/$loader_name/variables/$vname/unit_conversion";
                    scope=lscope))
            end
        end
    end

    # 4. Validate event consistency. Unlike balance and reference integrity, this
    # still RUNS for a coupled model — it is where a genuinely undeclared event
    # target is caught — but with the §6.4 `_var` placeholder credited (finding (b)).
    if file.models !== nothing
        coupled_ev = _coupled_system_names(file)
        for (model_name, model) in file.models
            append!(errors, validate_event_consistency(model, "/models/$model_name";
                                                       is_coupled = model_name ∈ coupled_ev))
            append!(errors, validate_model_gradient_units(file, model, "/models/$model_name"))
            append!(errors, validate_physical_constant_units(model, "/models/$model_name"))
            append!(errors, validate_conversion_factor_consistency(model, "/models/$model_name"))
            # Dimensional analysis over equations and variable definitions. This
            # is the ONLY caller of the units engine in the validation path; it
            # was missing entirely until the 2026-07-14 audit (finding J1), which
            # is why `validate()` accepted every dimensionally-inconsistent
            # fixture in the shared corpus.
            append!(errors, validate_model_unit_consistency(model, "/models/$model_name"))
        end
    end

    # 5. Validate multi-domain consistency
    append!(errors, validate_multi_domain(file))

    # 5b. Coupling-cycle detection (§3.2). A dependency cycle among top-level
    # systems means no evaluation order exists.
    append!(errors, validate_coupling_cycles(file))

    # 6. Conflicting derivative detection (§4.7.5 item E). A species cannot
    # have both an explicit D(X, t) = ... equation and a reaction contribution.
    # `_find_conflicting_derivatives` is defined in flatten.jl. The conflict
    # spans TWO top-level blocks (a model equation AND a reaction), so there is
    # no single JSON location; per this function's JSON-Pointer path contract
    # the root pointer "/" is used as the documented sentinel (the offending
    # species name is in the message).
    conflicting = _find_conflicting_derivatives(file)
    for name in conflicting
        push!(errors, StructuralError(
            "/",
            "Species '$name' has both an explicit derivative equation and a reaction contribution",
            "conflicting_derivative",
        ))
    end

    return errors
end

"""
    validate(file::EsmFile) -> ValidationResult

Complete validation combining schema, structural, and unit validation.
Returns ValidationResult with all errors and warnings.
"""
function validate(file::EsmFile)::ValidationResult
    # Schema validation requires the full serialized document: the schema's
    # top-level `anyOf` requires either `models` or `reaction_systems`, so a
    # stub dict with just `esm` and `metadata.name` would always fail.
    #
    # `_plain_json` is not cosmetic. Several fields are RAW passthrough
    # (`coupling[*].connector`, `callback.config`, `translate`, `domain.temporal`,
    # the template declarations), and they still hold the JSON3 values they were
    # parsed from — `JSON3.Object`, `JSON3.Array`. JSONSchema.jl does not
    # recognize those as JSON objects/arrays, so it failed `type: object` and
    # reported a bogus `oneOf` failure on a document a compliant Draft 2020-12
    # validator accepts with ZERO errors: tests/valid/scoped_refs_coupling.esm was
    # rejected for a `couple` entry whose `connector.equations` were `JSON3.Object`
    # rather than `Dict`. The error was in the validator's INPUT, not the document.
    data = _plain_json(serialize_esm_file(file))

    schema_errors = validate_schema(data)
    structural_errors = validate_structural(file)
    # Mirror the TS binding (validate.ts): unit findings are surfaced both as
    # `unit_warnings` strings and as promoted `unit_inconsistency` structural
    # errors, so neither channel is dead.
    unit_warnings = [e.message for e in structural_errors if e.error_type == "unit_inconsistency"]

    return ValidationResult(schema_errors, structural_errors, unit_warnings=unit_warnings)
end

"""
    validate(path::AbstractString) -> ValidationResult

Validate the document at `path`, INCLUDING the failures that happen while
loading it.

An unresolvable or ambiguous subsystem ref is a validation FINDING — the corpus
pins `unresolved_subsystem_ref` / `ambiguous_subsystem_ref` at
`/models/<M>/subsystems/<S>` with `details` — but Julia could only ever raise it
as an exception out of `load`, so `validate(load(path))` never ran and the
finding was unreportable in the shape everyone else reports it (finding (f)).

`load` still throws: a document whose mount does not resolve genuinely cannot be
built, and callers that want the exception keep it. This entry point is the one
the conformance harness wants — it renders the throw as the structural error it
always was.
"""
function validate(path::AbstractString)::ValidationResult
    file = try
        load(path)
    catch e
        e isa SubsystemRefError || rethrow()
        err = StructuralError(
            isempty(e.parent_model) ? "" :
                "/models/$(e.parent_model)/subsystems/$(e.subsystem)",
            e.message,
            e.code,
            Dict{String,Any}("ref" => e.ref,
                             "subsystem" => e.subsystem,
                             "parent_model" => e.parent_model)
        )
        return ValidationResult(SchemaError[], StructuralError[err])
    end
    return validate(file)
end

# ============================================================================
# Helper Functions for Structural Validation
# ============================================================================

"""
    model_subsystems(model::Model)

Iterator over the `(name, subsystem)` pairs of `model.subsystems` whose value
is itself a `Model`. Model subsystems may also hold DataLoader / SubsystemRef
entries (RFC pure-io-data-loaders §4.3), which carry no model semantics for
the model-specific validators — this helper skips them once, instead of every
recursion site repeating the `subsys isa Model || continue` boilerplate.
"""
model_subsystems(model::Model) =
    (pair for pair in model.subsystems if pair.second isa Model)

"""
    _equation_lhs_names(lhs::ASTExpr) -> Set{String}

The names an equation's LHS *solves for*. The LHS is not always a bare variable:
the corpus spells the same "define `u`" in five shapes, and a balance check that
only understands two of them manufactures false `missing_equation` errors on
~20 valid fixtures (bug audit 2026-07-14).

Recognised shapes, in the order they nest:

| LHS | solves for |
|---|---|
| `"u"` (bare) | `u` |
| `D(u, t)` | `u` |
| `index(u, i)` / `index(D(u), i)` | `u` (an element assignment defines the array) |
| `aggregate{output_idx: [i], expr: D(index(u,i))}` | `u` (a vectorised ODE) |
| `H*H*SO4 = Ksp` (implicit/algebraic) | every bare variable on the LHS |

`ic(u)` is deliberately NOT a defining equation — an initial condition
constrains `u`'s value at t₀, it does not supply `u`'s dynamics — so it returns
the empty set and cannot satisfy a state variable's balance obligation.

Dotted (cross-system) names are excluded: they are the qualified-reference
resolver's business, not this model's balance.
"""
function _equation_lhs_names(lhs::ASTExpr)::Set{String}
    names = Set{String}()
    _collect_lhs_names!(names, lhs)
    return names
end

function _collect_lhs_names!(names::Set{String}, e::ASTExpr)
    if e isa VarExpr
        occursin('.', e.name) || push!(names, e.name)
    elseif e isa OpExpr
        if e.op == "ic"
            # Initial condition: constrains a value, does not define dynamics.
            return names
        elseif e.op in ("D", "index", "arrayop") && !isempty(e.args)
            # Structural wrappers: the solved-for name is the head operand.
            _collect_lhs_names!(names, e.args[1])
        elseif e.op == "aggregate" && e.expr_body !== nothing
            # Vectorised equation: the body is the real LHS.
            _collect_lhs_names!(names, e.expr_body)
        else
            # Implicit / algebraic LHS (`H*H*SO4 = Ksp`): any bare variable on
            # the LHS is a candidate unknown this equation constrains.
            for a in e.args
                _collect_lhs_names!(names, a)
            end
        end
    end
    return names
end

"""
    validate_model_balance(model::Model, path::String) -> Vector{StructuralError}

Validate equation/unknown balance for a model, in BOTH directions (the docstring
has always promised "equation-unknown balance"; only the first direction was
ever implemented — bug audit 2026-07-14, finding J3):

1. **A state variable with no defining equation.** Skipped when the model has
   subsystems: its dynamics may live there (`tests/valid/scoped_refs_coupling.esm`
   declares state variables and `equations: []` for exactly this reason).
2. **An excess equation** — one that solves for a name the model does not
   declare, e.g. a stray `D(y)` in a model whose only state is `x`.

Both are reported under the code the shared corpus pins,
`equation_count_mismatch`, at the MODEL's pointer (`/models/<M>`) — a balance is
a property of the model, not of any one equation.

`check_excess=false` disables direction 2 only. It is passed for a model that
participates in an `operator_compose` coupling: such a model is an OPERATOR, and
its equations act on the unknowns of the system it is composed onto, not on
unknowns of its own. `tests/valid/minimal_chemistry.esm` is the canonical shape —
`Advection` declares only the parameters `u_wind`/`v_wind` and writes
`D(u) = -u_wind*grad(u,x) - …`, where `u` is the advected field supplied by the
composition. Treating that `u` as an excess equation rejects a valid file.
Direction 1 still applies: an operator that declares a state of its own must
still define it.
"""
function validate_model_balance(model::Model, path::String;
                                check_excess::Bool=true)::Vector{StructuralError}
    errors = StructuralError[]

    state_vars = Set{String}()
    for (name, var) in model.variables
        var.type == StateVariable && push!(state_vars, name)
    end

    # An ALGEBRAIC model (`system_kind: "nonlinear"`) has NO derivatives, and its
    # equations need not have an assignment target: ISORROPIA's charge balance is
    # `H ~ 2*SO4` (a bare target) but its solubility product is `H*H*SO4 ~ Ksp` —
    # an expression on the left, crediting no single variable. The balance is
    # therefore a COUNT (square-ness), not a per-variable credit: 2 equations
    # determine 2 unknowns. Running the per-variable rule there reports "no
    # defining equation" for a perfectly balanced system.
    #
    # An `ic` equation prescribes an initial value, not a determining equation,
    # so it does not count toward the square-ness.
    if model.system_kind == "nonlinear"
        n_eqs = count(eq -> !(eq.lhs isa OpExpr && eq.lhs.op == "ic"), model.equations)
        n_states = length(state_vars)
        if n_states != n_eqs
            push!(errors, StructuralError(
                path,
                "Equation-unknown balance failed: found $n_states state variables " *
                "but $n_eqs algebraic equations",
                "equation_count_mismatch",
                Dict{String,Any}("state_count" => n_states, "equation_count" => n_eqs)
            ))
        end
        return errors
    end

    # Names solved for by the model's own equations.
    equation_vars = Set{String}()
    for eq in model.equations
        union!(equation_vars, _equation_lhs_names(eq.lhs))
    end

    has_subsystems = !isempty(model.subsystems)

    # Direction 1: a declared state with nothing to define it. An observed-style
    # `expression` on the variable counts as its definition. A model WITH
    # subsystems is exempt — the defining equation may be down there.
    if !has_subsystems
        for var in sort!(collect(state_vars))
            var ∈ equation_vars && continue
            model.variables[var].expression === nothing || continue
            push!(errors, StructuralError(
                path,
                "Model declares state variable '$var' but has no defining equation for it",
                "equation_count_mismatch",
                Dict{String,Any}("variable" => var)
            ))
        end
    end

    # Direction 2: an equation solving for a name the model never declares.
    # `_equation_lhs_names` already dropped dotted cross-system targets, and the
    # time variable is never an unknown.
    if check_excess
        for name in sort!(collect(equation_vars))
            (name == "t" || haskey(model.variables, name)) && continue
            push!(errors, StructuralError(
                path,
                "Equation solves for '$name', which is not a declared variable of this model " *
                "(number of equations does not match the number of unknowns)",
                "equation_count_mismatch",
                Dict{String,Any}("variable" => name)
            ))
        end
    end

    # Recursively check subsystems. The operator exemption is inherited: a
    # subsystem of an operator is still acting on the composed system's state.
    for (subsys_name, subsys) in model_subsystems(model)
        append!(errors, validate_model_balance(subsys, "$path/subsystems/$subsys_name";
                                               check_excess=check_excess))
    end

    return errors
end

"""
    _operator_composed_systems(file::EsmFile) -> Set{String}

Every system named in an `operator_compose` coupling entry. Their equations are
operator contributions to a shared state, so the excess-equation direction of
[`validate_model_balance`](@ref) does not apply to them.
"""
function _operator_composed_systems(file::EsmFile)::Set{String}
    names = Set{String}()
    for entry in file.coupling
        entry isa CouplingOperatorCompose || continue
        union!(names, entry.systems)
    end
    return names
end

"""
    validate_model_unit_consistency(model::Model, path::String) -> Vector{StructuralError}

Promote every units finding in `model` to a structural error under its own
esm-spec §4.8.4 code — `unit_inconsistency` for a PROVABLE dimensional
inconsistency, `unit_parse_error` for a unit string that names no real unit.
Both are hard errors; a GENUINELY UNDETERMINABLE dimension is not a finding at
all. The findings (and the "provable vs unknown" discipline that makes them
trustworthy) come from [`model_unit_findings`](@ref) in units.jl; this function
only attaches the model's JSON pointer and recurses into subsystems.

This is what wires the units engine into `validate()`. Before the 2026-07-14
audit the engine had no caller outside its own test file.
"""
function validate_model_unit_consistency(model::Model, path::String)::Vector{StructuralError}
    errors = StructuralError[]

    for f in model_unit_findings(model)
        push!(errors, StructuralError("$path/$(f.subpath)", f.message, f.code))
    end

    for (subsys_name, subsys) in model_subsystems(model)
        append!(errors, validate_model_unit_consistency(subsys, "$path/subsystems/$subsys_name"))
    end

    return errors
end

"""
    validate_coupling_cycles(file::EsmFile) -> Vector{StructuralError}

Detect a dependency cycle among the document's top-level systems.

An edge `M → N` exists when a model `M`'s own equations name `N` directly, via a
qualified reference `N.v` (searched over the full expression child set, sidecar
fields included). A cycle in that graph means the systems' definitions are
mutually recursive with no evaluation order — see
`tests/invalid/circular_coupling.esm`, which validated clean because NO
coupling-cycle check of any kind existed.

**`coupling` entries are deliberately NOT edges.** A `variable_map` is a
declared data flow that the flattener resolves by aliasing, and mutual physical
coupling between systems is the whole point of the format: `tests/valid/`
`wildfire_atmosphere_ocean.esm` couples wind → fire spread → heat release → wind,
a legitimate three-system feedback loop. Treating those as dependency edges
rejects it.

Reported once per cycle, as `circular_dependency` at the pointer of the cycle's
entry system, with the cycle rendered in the message (`ModelA → ModelB → ModelA`).

The traversal is deterministic (systems and successors are visited in sorted
order) so the reported cycle and its entry point do not depend on Dict hashing.
"""
function validate_coupling_cycles(file::EsmFile)::Vector{StructuralError}
    # System name → its kind's pointer prefix, for the error path.
    prefix = Dict{String,String}()
    file.models !== nothing && for name in keys(file.models)
        prefix[name] = "/models/$name"
    end
    file.reaction_systems !== nothing && for name in keys(file.reaction_systems)
        prefix[name] = "/reaction_systems/$name"
    end
    isempty(prefix) && return StructuralError[]

    adj = Dict{String,Set{String}}(name => Set{String}() for name in keys(prefix))

    # Edges from qualified references inside a model's equations.
    if file.models !== nothing
        for (model_name, model) in file.models
            for eq in model.equations
                for side in (eq.lhs, eq.rhs)
                    for ref in _referenced_var_names(side)
                        head = _qualified_head(ref)
                        (head === nothing || head == model_name) && continue
                        haskey(prefix, head) && push!(adj[model_name], head)
                    end
                end
            end
        end
    end

    # DFS with an explicit path stack; the first back-edge found in sorted order
    # is reported.
    WHITE, GREY, BLACK = 0, 1, 2
    color = Dict{String,Int}(name => WHITE for name in keys(prefix))
    path_stack = String[]
    errors = StructuralError[]

    function dfs(u::String)::Bool
        color[u] = GREY
        push!(path_stack, u)
        for v in sort!(collect(adj[u]))
            if color[v] == GREY
                # Back edge: the cycle is path_stack[from v ..] + v.
                start = findfirst(==(v), path_stack)
                cycle = vcat(path_stack[start:end], v)
                entry = cycle[1]
                push!(errors, StructuralError(
                    prefix[entry],
                    "Circular coupling detected: " * join(cycle, " → "),
                    "circular_dependency"
                ))
                return true
            elseif color[v] == WHITE && dfs(v)
                return true
            end
        end
        pop!(path_stack)
        color[u] = BLACK
        return false
    end

    for u in sort!(collect(keys(prefix)))
        color[u] == WHITE || continue
        dfs(u) && break   # one cycle report is enough; the model is unorderable
    end

    return errors
end

# The system part of a qualified reference `System.var` (or `A.B.var`), or
# `nothing` for a bare local name.
function _qualified_head(ref::AbstractString)::Union{String,Nothing}
    idx = findfirst('.', ref)
    idx === nothing ? nothing : String(ref[1:prevind(ref, idx)])
end

"""
    validate_reference_integrity(file::EsmFile) -> Vector{StructuralError}

Validate that all variable references can be resolved through the hierarchy.
"""
function validate_reference_integrity(file::EsmFile)::Vector{StructuralError}
    errors = StructuralError[]

    # Validate model variable references. A COUPLED model is skipped: it does not
    # own every name it mentions (see `_coupled_system_names`). Its events are
    # still checked below, with `_var` credited — that is where a genuinely
    # undeclared event target is still caught.
    if file.models !== nothing
        coupled = _coupled_system_names(file)
        for (model_name, model) in file.models
            model_name ∈ coupled && continue
            append!(errors, validate_model_references(file, model, "/models/$model_name";
                                                      model_name=model_name))
        end
    end

    # Validate coupling references
    for (i, coupling_entry) in enumerate(file.coupling)
        append!(errors, validate_coupling_references(file, coupling_entry, "/coupling/$(i-1)"))
    end

    return errors
end

# The solved-for name an equation defines: a bare `VarExpr` LHS (`x = …`) or the
# first argument of an operator LHS (`D(x, t) = …`, `ic(x) = …`). These are the
# model's unknowns and are in scope for its equations even when not separately
# listed under `variables` (an ODE state may appear only as `D(u)`). Dotted
# cross-system targets are left to the qualified-reference resolver. Returns
# `nothing` when no bare local name can be extracted.
function _equation_lhs_target(eq::Equation)::Union{String,Nothing}
    lhs = eq.lhs
    if isa(lhs, VarExpr)
        return occursin('.', lhs.name) ? nothing : lhs.name
    elseif isa(lhs, OpExpr) && !isempty(lhs.args) && isa(lhs.args[1], VarExpr)
        name = lhs.args[1].name
        return occursin('.', name) ? nothing : name
    end
    return nothing
end

# Every expression-bearing child of an operator node, in one place: `args` plus
# the sidecars (`lower`, `upper`, `expr`, `filter`, `values`, `axes`, `key`,
# `bindings`). The set must stay identical to the one
# `_check_expression_references!` descends — a walker that misses a sidecar is
# exactly how a whole class of references went unchecked (finding (h)).
function _expr_children(e::OpExpr)::Vector{ASTExpr}
    out = ASTExpr[]
    append!(out, e.args)
    for f in (e.lower, e.upper, e.expr_body, e.filter, e.key)
        f === nothing || push!(out, f)
    end
    e.values === nothing || append!(out, e.values)
    e.table_axes === nothing || append!(out, values(e.table_axes))
    e.bindings === nothing || append!(out, values(e.bindings))
    return out
end

"""
    _indep_var(file::EsmFile) -> String

The document's independent (time) variable — `domain.independent_variable`, or
`"t"` when the document does not say. Never hard-code `"t"`: a document may
rename it (`tau`, `depth`), and the old literal check both accepted a bare `t`
there and rejected the document's real name (finding (a)).
"""
_indep_var(file::EsmFile)::String =
    file.domain === nothing ? "t" : file.domain.independent_variable

# The spatial coordinate names every document may reference WITHOUT declaring
# them. v0.8.0 removed `Domain.spatial`, so a coordinate has no declaration site
# at all: it is named directly in an expression (the `x` of an expression initial
# condition, `0.5*(1 + tanh((x - 0.3)/0.15))`) and as the `dim` of a
# `grad`/`div`/`laplacian`. It belongs to the DOMAIN, not to any `variables`
# block, so reporting it `undefined_variable` rejects a valid file.
const _CONVENTIONAL_COORDINATE_NAMES = ("x", "y", "z", "lon", "lat", "lev")

"""
    _coordinate_names(file::EsmFile) -> Set{String}

The implicitly-declared coordinate namespace: the conventional axis names plus
every axis the DOCUMENT itself names — the `dim` of a spatial operator and the
`wrt` of a SPATIAL derivative (a `wrt` naming the independent variable is time,
credited separately). Mirrors Go `coordinateNames`.
"""
function _coordinate_names(file::EsmFile)::Set{String}
    coords = Set{String}(_CONVENTIONAL_COORDINATE_NAMES)
    indep = _indep_var(file)

    walk(e) = nothing
    function walk(e::OpExpr)
        e.dim !== nothing && !isempty(e.dim) && push!(coords, e.dim)
        e.wrt !== nothing && !isempty(e.wrt) && e.wrt != indep && push!(coords, e.wrt)
        for c in _expr_children(e)
            walk(c)
        end
        return nothing
    end

    file.models === nothing && return coords
    for (_, model) in file.models
        for eq in model.equations
            walk(eq.lhs); walk(eq.rhs)
        end
        for (_, v) in model.variables
            v.expression === nothing || walk(v.expression)
        end
    end
    return coords
end

"""
    _coupled_system_names(file::EsmFile) -> Set{String}

Every system a coupling entry NAMES — as a `systems` member (including the ROOT
of a dotted subsystem path) or as the system half of a `from`/`to` scoped
reference.

A COUPLED system does not own all the names its equations mention. An
operator-style model spells its operand as the §6.4 placeholder `_var`; a
`variable_map` supplies a value the target never declares; and its `equations`
may drive a state that lives in the system it is composed with, so its own
equation/unknown count need not balance. Equation balance and reference integrity
are therefore SKIPPED for these systems — the settled cross-binding rule (Go
`coupledSystemNames`, TS `coupledSystems`). Event consistency still runs, with
`_var` credited, which is where a genuinely undeclared event target is caught.
"""
function _coupled_system_names(file::EsmFile)::Set{String}
    coupled = Set{String}()
    add!(name::AbstractString) = begin
        isempty(name) && return
        push!(coupled, String(name))
        # A dotted endpoint ("Atmosphere.Chemistry.O3") couples the ROOT system
        # too — that is the model whose checks must relax.
        i = findfirst('.', name)
        i === nothing || push!(coupled, String(name[1:prevind(name, i)]))
    end
    for entry in file.coupling
        if entry isa CouplingOperatorCompose || entry isa CouplingCouple
            for s in entry.systems
                add!(s)
            end
        elseif entry isa CouplingVariableMap
            add!(entry.from); add!(entry.to)
        end
    end
    return coupled
end

"""
    _callback_injected_names(file::EsmFile) -> Set{String}

Every name a `callback` coupling entry INJECTS into the system it targets, read
off `coupling[i].config.callback_variables[j].name` (the config is raw JSON, so
this reads it defensively).

These are declaration sites (esm-spec §4.9.5, checker row (k)) and must be in
scope, or reference integrity reports a name the document really does declare.
The set is DOCUMENT-scoped rather than per-target: `config` is untyped, so the
target cannot be resolved reliably, and being slightly over-permissive here is
the right trade — a missed typo is a lesser harm than rejecting a valid file.
"""
function _callback_injected_names(file::EsmFile)::Set{String}
    names = Set{String}()
    for entry in file.coupling
        entry isa CouplingCallback || continue
        cfg = entry.config
        cfg === nothing && continue
        cvs = get(cfg, "callback_variables", nothing)
        cvs isa AbstractVector || continue
        for cv in cvs
            cv isa AbstractDict || continue
            nm = get(cv, "name", nothing)
            nm isa AbstractString && push!(names, String(nm))
        end
    end
    return names
end

"""
    validate_model_references(file::EsmFile, model::Model, path::String) -> Vector{StructuralError}

Validate variable references within a model.
"""
function validate_model_references(file::EsmFile, model::Model, path::String;
                                   model_name::AbstractString="")::Vector{StructuralError}
    errors = StructuralError[]

    # Names in scope for this model's equations: its declared variables (state,
    # parameter, observed), the document-scoped `index_sets` registry (a
    # legitimate non-variable identifier namespace an aggregate may name — RFC
    # semiring-faq-unified-ir §5.2), and each equation's LHS target (a
    # solved-for unknown, e.g. an ODE state referenced as `D(u)` that is not
    # separately listed under `variables`). Bound loop indices are added per-node
    # during the descent (see `validate_expression_references`).
    scope = Set{String}(keys(model.variables))
    union!(scope, keys(file.index_sets))
    for eq in model.equations
        target = _equation_lhs_target(eq)
        target === nothing || push!(scope, target)
    end

    # (a) The DOMAIN's names. Neither the independent variable nor a spatial
    # coordinate is an entry of any `variables` block, yet both are perfectly
    # legal references — a forcing spells `sin(t)`, an event trigger `t > 300`,
    # an expression initial condition `tanh((x - 0.3)/0.15)`. Credit them from
    # the document, so a document that renames the independent variable to `tau`
    # gets `tau` and not `t`.
    push!(scope, _indep_var(file))
    union!(scope, _coordinate_names(file))

    # A model's variable table is NOT the complete set of declaration sites, and
    # widening reference integrity to every expression-bearing field (finding
    # (h)) makes that bite: a name declared somewhere ELSE would now be reported
    # as `undefined_variable`. A false-negative fix that becomes a false-positive
    # bug is a net loss, so the check runs against the UNION of declaration sites.
    #
    # `coupling[i].config.callback_variables[j].name` is the one the corpus
    # caught: a callback INJECTS those names into the system it targets
    # (tests/coupling/callback_examples.esm declares
    # `external_temperature_forcing` exactly this way and nowhere else).
    union!(scope, _callback_injected_names(file))

    # Validate equation references
    for (i, eq) in enumerate(model.equations)
        append!(errors, validate_expression_references(file, eq.lhs, "$path/equations/$(i-1)/lhs"; scope=scope))
        append!(errors, validate_expression_references(file, eq.rhs, "$path/equations/$(i-1)/rhs"; scope=scope))
    end

    # ---------------------------------------------------------------------
    # EVERY OTHER EXPRESSION-BEARING FIELD (audit finding (h)).
    #
    # Reference integrity used to run on `equations` (and reaction `rate`) and
    # NOTHING ELSE. The expression WALKER was complete — it descends every
    # sidecar (`expr`, `filter`, `key`, `lower`/`upper`, `values`, `axes`,
    # `bindings`) — but it was only ever CALLED from those two places, so an
    # undefined name anywhere else was simply never looked at. That is a silent
    # false negative: nothing catches it, and no fixture pinned it.
    #
    # The events were the subtler half: they WERE walked, but with `scope`
    # defaulted to `nothing`, which switches the bare-variable check off
    # (`_check_bare_variable!` returns immediately). They descended the tree and
    # then declined to look at it.
    #
    # Julia accepted 10 of the corpus's 11 pinned fixtures for this before this
    # change.
    # ---------------------------------------------------------------------

    # 1. Observed variables' defining expressions.
    for name in sort!(collect(keys(model.variables)))
        expr = model.variables[name].expression
        expr === nothing && continue
        append!(errors, validate_expression_references(
            file, expr, "$path/variables/$name/expression"; scope=scope))
    end

    # 2. `guesses` — an initial guess may be a bare number (nothing to check) or
    #    an expression over the model's names.
    for name in sort!(collect(keys(model.guesses)))
        g = model.guesses[name]
        isa(g, ASTExpr) || continue
        append!(errors, validate_expression_references(
            file, g, "$path/guesses/$name"; scope=scope))
    end

    # 3. `initialization_equations`.
    for (i, eq) in enumerate(model.initialization_equations)
        append!(errors, validate_expression_references(
            file, eq.lhs, "$path/initialization_equations/$(i-1)/lhs"; scope=scope))
        append!(errors, validate_expression_references(
            file, eq.rhs, "$path/initialization_equations/$(i-1)/rhs"; scope=scope))
    end

    # 4. Inline `tests` blocks: an assertion may carry a `reference` expression.
    for (i, t) in enumerate(model.tests)
        for (j, a) in enumerate(t.assertions)
            ref = a.reference
            ref === nothing && continue
            append!(errors, validate_expression_references(
                file, ref, "$path/tests/$(i-1)/assertions/$(j-1)/reference"; scope=scope))
        end
    end

    # Validate discrete event references. `scope` is threaded now — without it
    # the descent happened but the bare-variable check was a no-op.
    for (i, event) in enumerate(model.discrete_events)
        append!(errors, validate_event_references(file, event, "$path/discrete_events/$(i-1)"; scope=scope))
    end

    # Validate continuous event references
    for (i, event) in enumerate(model.continuous_events)
        append!(errors, validate_event_references(file, event, "$path/continuous_events/$(i-1)"; scope=scope))
    end

    # Recursively check subsystems
    for (subsys_name, subsys) in model_subsystems(model)
        append!(errors, validate_model_references(file, subsys, "$path/subsystems/$subsys_name"))
    end

    return errors
end

"""
Bare names that are always in scope inside an expression even when they are not
declared model variables: the elementary math functions and reductions the AST
spells as operator (`OpExpr`) names. They normally appear as `OpExpr.op`, not as
`VarExpr` leaves, but a bare occurrence (e.g. a partially-applied builtin) must
not be mis-reported as an undefined variable. Mirrors Rust
`is_builtin_function` (structural.rs) so the same names are excused across
bindings.
"""
const _BUILTIN_FUNCTION_NAMES = Set{String}([
    "exp", "log", "log10", "sqrt", "abs", "sign",
    "sin", "cos", "tan", "asin", "acos", "atan", "atan2",
    "sinh", "cosh", "tanh", "asinh", "acosh", "atanh",
    "min", "max", "floor", "ceil", "ifelse", "Pre",
])

"""
    _bound_index_symbols(op::OpExpr) -> Vector{String}

The index / iteration symbols an operator node BINDS for its own child
expressions — loop positions and invented keys, NOT declared variables. They
are in scope for the node's descended children (an aggregate body, a filter
predicate, a grouping key, integral bounds) so a bound loop index such as the
`i` in `index(u, i)` is not mis-reported as undefined.

Mirrors Rust `bound_index_symbols` (structural.rs) and Go `boundIndexSymbols`
(validate.go). Binder sources: `output_idx` (aggregate surviving indices),
`ranges` keys (contraction loop variables), `int_var` (integral integration
variable, wire `var`), `arg` (argmin/argmax witness), the positional element
indices of an `index(array, i, j, …)` node, the invented-key name of a
`skolem(name, …)` node, and `bindings` keys (`apply_expression_template`
formal parameters).
"""
# Every bare name inside a SUBSCRIPT expression. `index(u, i+1)` is index space,
# so `i` is a loop index; the arithmetic around it is the stencil offset.
function _collect_index_names!(syms::Vector{String}, e::ASTExpr)
    if e isa VarExpr
        occursin('.', e.name) || push!(syms, e.name)
    elseif e isa OpExpr
        for a in e.args
            _collect_index_names!(syms, a)
        end
    end
    return syms
end

function _bound_index_symbols(op::OpExpr)::Vector{String}
    syms = String[]
    if op.output_idx !== nothing
        for x in op.output_idx
            x isa AbstractString && push!(syms, String(x))
        end
    end
    if op.ranges !== nothing
        for k in keys(op.ranges)
            push!(syms, String(k))
        end
    end
    op.int_var !== nothing && push!(syms, op.int_var)
    op.arg !== nothing && push!(syms, op.arg)

    # NOTE: an `integral`'s `lower`/`upper` are NOT exempted. It is tempting to
    # call them coordinate-space bounds and wave them through — that would make
    # tests/valid/integral_operator_pide.esm pass, whose `lower` is an undeclared
    # `xmin` — but tests/invalid/undefined_variable_in_integral_bound.esm pins the
    # opposite: an undefined name in an integral bound IS `undefined_variable`.
    # The corpus decides, and it says the bounds are ordinary expressions. The
    # `xmin` in that "valid" fixture is therefore a fixture defect, not a checker
    # one, and is reported upstream rather than papered over here.
    if op.op == "index"
        # index(array, pos…): every SUBSCRIPT position after the array head is
        # index space, so the free names appearing in one are loop indices.
        #
        # Binding only the BARE names (`index(u, i)`) and not the ones inside a
        # subscript EXPRESSION (`index(u, i+1)`) is what made every lowered
        # stencil look broken: a finite-difference scheme is written
        # `index(u, i-1)`, `index(u, i+1)` — the offsets ARE the stencil — and
        # the `i` inside the offset was reported `undefined_variable`, rejecting
        # tests/valid/advection_reaction_loaded_ic_bc.esm with 12 errors.
        #
        # This is a subscript-position rule, NOT an allowlist of short names: a
        # name is bound because of WHERE it appears (index space), and a name
        # outside index space that nothing declares is still `undefined_variable`.
        for i in 2:length(op.args)
            _collect_index_names!(syms, op.args[i])
        end
    elseif op.op == "skolem"
        # skolem(name, …): the first positional arg is the invented-key binder.
        if !isempty(op.args) && op.args[1] isa VarExpr
            push!(syms, op.args[1].name)
        end
    end
    if op.bindings !== nothing
        for k in keys(op.bindings)
            push!(syms, String(k))
        end
    end
    return syms
end

"""
    validate_expression_references(file::EsmFile, expr::ASTExpr, path::String;
                                   scope::Union{Set{String},Nothing}=nothing) -> Vector{StructuralError}

Validate references in an expression tree.

Two independent checks run over the FULL expression child set — `args` plus the
sidecar fields (integral `lower`/`upper` bounds, an aggregate/arrayop body
`expr`, a `filter` predicate, `makearray` `values`, `table_lookup` `axes`, an
aggregate grouping `key`, and `apply_expression_template` `bindings` values),
matching Rust `for_each_child` / Go `validateExprNodeChildren`:

1. `operator_apply` operator names are always flagged (the top-level
   `operators` block was removed in esm-spec v0.3.0 §9, so they never resolve).

2. When `scope` is supplied, each bare (non-dotted) `VarExpr` that is not in
   scope is reported as `undefined_variable`. In scope = a name in `scope`
   (the enclosing model/system's declared variables/parameters, its equation
   LHS targets, and the document `index_sets` names), the time variable `t`, a
   derivative form (`d(…)`), a builtin function name, or an index symbol BOUND
   by an enclosing node (see [`_bound_index_symbols`]). Dotted `A.b` references
   are left to the qualified-reference resolver and never flagged here. When
   `scope === nothing` (event / coupling call sites) the bare-variable check is
   skipped, but the full child set is still descended so an `operator_apply`
   hidden outside `args` is not missed.
"""
function validate_expression_references(file::EsmFile, expr::ASTExpr, path::String;
                                        scope::Union{Set{String},Nothing}=nothing)::Vector{StructuralError}
    errors = StructuralError[]
    _check_expression_references!(errors, file, expr, path, scope)
    return errors
end

function _check_expression_references!(errors::Vector{StructuralError}, file::EsmFile,
                                       expr::ASTExpr, path::String,
                                       scope::Union{Set{String},Nothing})
    if isa(expr, VarExpr)
        _check_bare_variable!(errors, expr.name, path, scope)
    elseif isa(expr, OpExpr)
        # Extend the in-scope set with any index symbols this node binds, so a
        # bound loop index in a descended child is not flagged as undefined.
        child_scope = scope
        if scope !== nothing
            bound = _bound_index_symbols(expr)
            isempty(bound) || (child_scope = union(scope, bound))
        end

        # `operator_apply`: the referenced operator can never resolve (v0.3.0
        # §9 closure). Flag it, and don't also treat the operator-name arg as a
        # bare undefined variable.
        skip_operator_arg = false
        if expr.op == "operator_apply" && !isempty(expr.args) && isa(expr.args[1], VarExpr)
            push!(errors, StructuralError(
                path,
                "Operator '$(expr.args[1].name)' referenced but not defined",
                "undefined_operator"
            ))
            skip_operator_arg = true
        end

        # Descend the full expression-bearing child set (mirrors Rust
        # `for_each_child`). `args` first, then the sidecar fields.
        for (i, arg) in enumerate(expr.args)
            (skip_operator_arg && i == 1) && continue
            _check_expression_references!(errors, file, arg, "$path/args/$(i-1)", child_scope)
        end
        expr.lower !== nothing && _check_expression_references!(errors, file, expr.lower, "$path/lower", child_scope)
        expr.upper !== nothing && _check_expression_references!(errors, file, expr.upper, "$path/upper", child_scope)
        expr.expr_body !== nothing && _check_expression_references!(errors, file, expr.expr_body, "$path/expr", child_scope)
        expr.filter !== nothing && _check_expression_references!(errors, file, expr.filter, "$path/filter", child_scope)
        if expr.values !== nothing
            for (i, v) in enumerate(expr.values)
                _check_expression_references!(errors, file, v, "$path/values/$(i-1)", child_scope)
            end
        end
        if expr.table_axes !== nothing
            for (k, v) in expr.table_axes
                _check_expression_references!(errors, file, v, "$path/axes/$k", child_scope)
            end
        end
        expr.key !== nothing && _check_expression_references!(errors, file, expr.key, "$path/key", child_scope)
        if expr.bindings !== nothing
            for (k, v) in expr.bindings
                _check_expression_references!(errors, file, v, "$path/bindings/$k", child_scope)
            end
        end
    end
    # NumExpr / IntExpr are literals — no references to validate.
    return errors
end

# Flag a bare `VarExpr` name that is not in scope as `undefined_variable`.
# No-op when `scope === nothing` (scoped resolution not requested), for a dotted
# (qualified) reference (handled by the qualified-reference resolver), for a
# derivative form, or for a builtin function name.
#
# The independent variable is NOT special-cased here any more. It used to be a
# literal `name == "t"`, which is wrong twice over: a document may RENAME it
# (`domain.independent_variable: "tau"`), and a document that renames it also
# leaves a bare `t` looking legal. It is credited into `scope` instead, from the
# document (see `_indep_var`), together with the coordinate namespace — both
# belong to the DOMAIN, not to any `variables` block (finding (a)).
function _check_bare_variable!(errors::Vector{StructuralError}, name::String,
                               path::String, scope::Union{Set{String},Nothing})
    scope === nothing && return errors
    occursin('.', name) && return errors
    (startswith(name, "d(") || name in _BUILTIN_FUNCTION_NAMES) && return errors
    if !(name in scope)
        push!(errors, StructuralError(
            path,
            "Variable '$name' referenced in equation is not declared",
            "undefined_variable",
            Dict{String,Any}("variable" => name)
        ))
    end
    return errors
end

# Try to resolve `ref` as a qualified reference; on failure push a
# StructuralError at `path` whose message is "<desc> '<ref>': <cause>".
# Non-QualifiedReferenceError exceptions are rethrown.
function _check_resolvable!(errors::Vector{StructuralError}, file::EsmFile,
                            ref::String, path::String, desc::String,
                            error_type::String)
    try
        resolve_qualified_reference(file, ref)
    catch e
        if isa(e, QualifiedReferenceError)
            push!(errors, StructuralError(
                path,
                "$desc '$ref': $(e.message)",
                error_type
            ))
        else
            rethrow()
        end
    end
    return errors
end

# Resolve every qualified name inside a `couple` connector's equation
# `expression`s. The connector is raw JSON (`Dict{String,Any}` straight off the
# parser), so this reads it defensively rather than through the typed AST.
function _check_connector_expressions(file::EsmFile, entry::CouplingCouple,
                                      path::String)::Vector{StructuralError}
    errors = StructuralError[]
    eqs = get(entry.connector, "equations", nothing)
    eqs isa AbstractVector || return errors

    for (i, eq) in enumerate(eqs)
        eq isa AbstractDict || continue
        raw = get(eq, "expression", nothing)
        raw === nothing && continue
        expr = try
            parse_expression(raw)
        catch
            continue    # a malformed expression is the schema's business
        end
        epath = "$path/connector/equations/$(i-1)/expression"
        for name in sort!(collect(_referenced_var_names(expr)))
            occursin('.', name) || continue    # bare names are not cross-system refs
            try
                resolve_qualified_reference(file, name)
            catch e
                e isa QualifiedReferenceError || rethrow()
                push!(errors, StructuralError(
                    epath,
                    "Variable \"$name\" referenced in connector equation expression does not resolve",
                    "unresolved_scoped_ref",
                    Dict{String,Any}("variable" => name)
                ))
            end
        end
    end
    return errors
end

"""
    validate_coupling_references(file::EsmFile, coupling_entry::CouplingEntry, path::String) -> Vector{StructuralError}

Validate coupling references based on the specific coupling type.
Checks that systems, operators, and variable references can be resolved.
"""
function validate_coupling_references(file::EsmFile, coupling_entry::CouplingEntry, path::String)::Vector{StructuralError}
    errors = StructuralError[]

    if isa(coupling_entry, CouplingOperatorCompose)
        # Validate that all referenced systems exist
        for (i, system_name) in enumerate(coupling_entry.systems)
            if !system_exists_in_file(file, system_name)
                push!(errors, StructuralError(
                    "$path/systems/$(i-1)",
                    "System '$system_name' referenced in operator_compose coupling not found",
                    "undefined_system"
                ))
            end
        end

    elseif isa(coupling_entry, CouplingCouple)
        # Validate that all referenced systems exist
        for (i, system_name) in enumerate(coupling_entry.systems)
            if !system_exists_in_file(file, system_name)
                push!(errors, StructuralError(
                    "$path/systems/$(i-1)",
                    "System '$system_name' referenced in couple coupling not found",
                    "undefined_system"
                ))
            end
        end

        # A connector equation may carry an `expression` over FULLY-QUALIFIED
        # cross-system names. It was never looked at — and the fixture that pins
        # it (tests/invalid/unresolved_scoped_ref_in_connector_expression.esm) was
        # only ever "rejected" by a bogus SchemaError from the JSON3-typed
        # connector (see `validate`). Fixing that error unmasked this hole, which
        # is exactly why an invalid fixture must be rejected for the RIGHT reason.
        append!(errors, _check_connector_expressions(file, coupling_entry, path))

    elseif isa(coupling_entry, CouplingVariableMap)
        # Validate 'from' reference
        if !validate_reference_syntax(coupling_entry.from)
            push!(errors, StructuralError(
                "$path/from",
                "Invalid reference syntax: '$(coupling_entry.from)'",
                "invalid_reference_syntax"
            ))
        else
            _check_resolvable!(errors, file, coupling_entry.from, "$path/from",
                               "Cannot resolve 'from' reference", "unresolved_reference")
        end

        # Validate 'to' reference
        if !validate_reference_syntax(coupling_entry.to)
            push!(errors, StructuralError(
                "$path/to",
                "Invalid reference syntax: '$(coupling_entry.to)'",
                "invalid_reference_syntax"
            ))
        else
            _check_resolvable!(errors, file, coupling_entry.to, "$path/to",
                               "Cannot resolve 'to' reference", "unresolved_reference")
        end

        # `transform` may be an EXPRESSION rather than one of the named string
        # transforms, and it was never walked (audit finding (h)). Its names are
        # cross-system references, so they are fully qualified (§4.6) and are
        # resolved by the qualified-reference resolver, not against a model scope.
        if isa(coupling_entry.transform, ASTExpr)
            append!(errors, validate_expression_references(
                file, coupling_entry.transform, "$path/transform"))
            for name in _referenced_var_names(coupling_entry.transform)
                occursin('.', name) || continue
                _check_resolvable!(errors, file, name, "$path/transform",
                                   "Cannot resolve reference", "unresolved_scoped_ref")
            end
        end

    elseif isa(coupling_entry, CouplingOperatorApply)
        # The top-level `operators` block was removed in esm-spec v0.3.0 (§9
        # closure), so the referenced operator can never resolve — flag it.
        push!(errors, StructuralError(
            "$path/operator",
            "Operator '$(coupling_entry.operator)' referenced in operator_apply coupling not found",
            "undefined_operator"
        ))

    elseif isa(coupling_entry, CouplingCallback)
        # Basic validation - callback_id should be a non-empty string
        if isempty(coupling_entry.callback_id)
            push!(errors, StructuralError(
                "$path/callback_id",
                "Callback ID cannot be empty",
                "empty_callback_id"
            ))
        end

    elseif isa(coupling_entry, CouplingEvent)
        # Validate affect equations
        for (i, affect) in enumerate(coupling_entry.affects)
            _check_resolvable!(errors, file, affect.lhs, "$path/affects/$(i-1)/lhs",
                               "Cannot resolve affect target", "unresolved_affect_target")
            append!(errors, validate_expression_references(file, affect.rhs, "$path/affects/$(i-1)/rhs"))
        end

        # Validate negative affect equations if present
        if coupling_entry.affect_neg !== nothing
            for (i, affect) in enumerate(coupling_entry.affect_neg)
                _check_resolvable!(errors, file, affect.lhs, "$path/affect_neg/$(i-1)/lhs",
                                   "Cannot resolve negative affect target", "unresolved_affect_target")
                append!(errors, validate_expression_references(file, affect.rhs, "$path/affect_neg/$(i-1)/rhs"))
            end
        end

        # Validate condition expressions if present (for continuous events)
        if coupling_entry.conditions !== nothing
            for (i, condition) in enumerate(coupling_entry.conditions)
                append!(errors, validate_expression_references(file, condition, "$path/conditions/$(i-1)"))
            end
        end

        # Validate trigger expression if present (for discrete events)
        if coupling_entry.trigger !== nothing && isa(coupling_entry.trigger, ConditionTrigger)
            append!(errors, validate_expression_references(file, coupling_entry.trigger.expression, "$path/trigger/expression"))
        end
    end

    return errors
end

"""
    validate_event_references(file::EsmFile, event::EventType, path::String;
                              scope=nothing) -> Vector{StructuralError}

Validate event variable references.

`scope` is the enclosing model's name set. It MUST be threaded from a model call
site: without it `_check_bare_variable!` is a no-op, so the descent walks the
whole event tree and then declines to look at any of it — which is exactly how an
undefined name in a trigger, a condition or an affect stayed invisible (audit
finding (h)). It stays optional (`nothing`) only for the coupling-level event
call sites, whose names are fully-qualified cross-system references resolved by
the qualified-reference resolver rather than against any one model's scope.
"""
function validate_event_references(file::EsmFile, event::EventType, path::String;
                                   scope::Union{Set{String},Nothing}=nothing)::Vector{StructuralError}
    errors = StructuralError[]

    if isa(event, ContinuousEvent)
        # Validate condition expressions
        for (i, condition) in enumerate(event.conditions)
            append!(errors, validate_expression_references(file, condition, "$path/conditions/$(i-1)"; scope=scope))
        end

        # Validate affect references
        for (i, affect) in enumerate(event.affects)
            append!(errors, validate_expression_references(file, affect.rhs, "$path/affects/$(i-1)/rhs"; scope=scope))
            # affect.lhs is a string (variable name) - would need model context to validate
        end

    elseif isa(event, DiscreteEvent)
        # Validate functional affect references
        for (i, affect) in enumerate(event.affects)
            append!(errors, validate_expression_references(file, affect.expression, "$path/affects/$(i-1)/expression"; scope=scope))
            # affect.target is a string (variable name) - would need model context to validate
        end

        # Validate trigger references (if condition-based)
        if isa(event.trigger, ConditionTrigger)
            append!(errors, validate_expression_references(file, event.trigger.expression, "$path/trigger/expression"; scope=scope))
        end
    end

    return errors
end

"""
    validate_reaction_consistency(rs::ReactionSystem, path::String) -> Vector{StructuralError}

Validate reaction system consistency: species declared, positive stoichiometries,
no null-null reactions, rate references declared.
"""
function validate_reaction_consistency(rs::ReactionSystem, path::String;
                                       indep::AbstractString="t")::Vector{StructuralError}
    errors = StructuralError[]

    # Get set of declared species / parameters
    species_names = Set(sp.name for sp in rs.species)
    param_names = Set(p.name for p in rs.parameters)

    # Validate each reaction
    for (i, reaction) in enumerate(rs.reactions)
        reaction_path = "$path/reactions/$(i-1)"

        # Check substrates (reactants) are declared species (ordered
        # StoichiometryEntry vector, not the backward-compat Dict view)
        substrates_field = raw_substrates(reaction)
        if substrates_field !== nothing
            for entry in substrates_field
                if entry.species ∉ species_names
                    push!(errors, StructuralError(
                        "$reaction_path/substrates",
                        "Species '$(entry.species)' not declared",
                        "undefined_species"
                    ))
                end

                # Check positive stoichiometry
                if entry.stoichiometry <= 0
                    push!(errors, StructuralError(
                        "$reaction_path/substrates",
                        "Species '$(entry.species)' has non-positive stoichiometry $(entry.stoichiometry)",
                        "invalid_stoichiometry"
                    ))
                end
            end
        end

        # Check products are declared species (ordered StoichiometryEntry
        # vector, not the backward-compat Dict view)
        products_field = raw_products(reaction)
        if products_field !== nothing
            for entry in products_field
                if entry.species ∉ species_names
                    push!(errors, StructuralError(
                        "$reaction_path/products",
                        "Species '$(entry.species)' not declared",
                        "undefined_species"
                    ))
                end

                # Check positive stoichiometry
                if entry.stoichiometry <= 0
                    push!(errors, StructuralError(
                        "$reaction_path/products",
                        "Species '$(entry.species)' has non-positive stoichiometry $(entry.stoichiometry)",
                        "invalid_stoichiometry"
                    ))
                end
            end
        end

        # Check for null-null reaction (no reactants and no products)
        has_substrates = substrates_field !== nothing && !isempty(substrates_field)
        has_products = products_field !== nothing && !isempty(products_field)
        if !has_substrates && !has_products
            push!(errors, StructuralError(
                reaction_path,
                "Reaction has no reactants or products (null-null reaction)",
                "null_reaction"
            ))
        end

        # Rate expression references. A DOTTED name (`Meteo.T`) is a qualified
        # cross-system reference and belongs to the qualified-reference resolver,
        # not here — but a BARE name that is neither a declared parameter, a
        # declared species, the time variable, nor a builtin function can never
        # resolve to anything, so it is flagged. (This was previously skipped
        # wholesale, on the strength of the qualified-reference argument, which
        # let `tests/invalid/undefined_parameter.esm` validate clean.)
        for name in sort!(collect(_referenced_var_names(reaction.rate)))
            # (d) A DOTTED name is a SCOPED reference (`Meteo.T`) — a rate may
            # legitimately reach into another system, and it is the
            # qualified-reference resolver's job, not this one's.
            occursin('.', name) && continue
            (name == indep || name in _BUILTIN_FUNCTION_NAMES) && continue
            (name in species_names || name in param_names) && continue
            push!(errors, StructuralError(
                reaction_path,
                "Parameter '$name' referenced in rate expression is not declared",
                "undefined_parameter",
                Dict{String,Any}("variable" => name)
            ))
        end
    end

    # Recursively check subsystems
    for (subsys_name, subsys) in rs.subsystems
        append!(errors, validate_reaction_consistency(subsys, "$path/subsystems/$subsys_name";
                                                      indep=indep))
    end

    return errors
end

"""
    validate_reaction_rate_units(rs::ReactionSystem, path::String) -> Vector{StructuralError}

Enforce the mass-action dimensional constraint from spec §7.4: for each reaction,
rate * prod(substrate^stoichiometry) must have dimensions of species/time. The
reference concentration unit is taken from the first substrate (matching TS/Python).

The check is skipped when the reference concentration unit is dimensionless
(mol/mol, ppm, …) because atmospheric-chemistry rate expressions commonly bake
a number-density factor into rate constants.
"""
function validate_reaction_rate_units(rs::ReactionSystem, path::String)::Vector{StructuralError}
    errors = StructuralError[]

    # Build name → unit-string map using ONLY explicitly declared units.
    # Mirrors Python's conservative scope: skip when any relevant unit is
    # absent, so we do not surface false positives on partially-annotated
    # fixtures (e.g. tests that omit units to exercise other rules).
    species_units = Dict{String, String}()
    for species in rs.species
        species.units !== nothing && (species_units[species.name] = species.units)
    end
    param_units = Dict{String, String}()
    for param in rs.parameters
        param.units !== nothing && (param_units[param.name] = param.units)
    end

    time_unit = parse_units("s")

    for (i, reaction) in enumerate(rs.reactions)
        # Only check bare-variable rate references whose symbol has declared
        # units. Compound rate expressions are skipped because atmospheric-
        # chemistry rate constants routinely carry implicit units on numeric
        # literals, which defeats literal dimensional analysis.
        isa(reaction.rate, VarExpr) || continue
        rate_name = reaction.rate.name
        rate_units_str = get(param_units, rate_name, get(species_units, rate_name, nothing))
        rate_units_str === nothing && continue
        rate_dim = parse_units(rate_units_str)
        rate_dim === nothing && continue

        substrates_field = raw_substrates(reaction)
        (substrates_field === nothing || isempty(substrates_field)) && continue

        # Require every referenced substrate to have declared units.
        # Fractional stoichiometries on substrates produce non-integer unit
        # exponents, which Unitful does not support for dimensional analysis —
        # skip the dimensional check in that case (fractional substrates are
        # unusual; fractional *products* are the common atmospheric-chemistry
        # case and don't enter this path).
        resolvable = true
        substrate_dim = Unitful.NoUnits
        species_dim = nothing
        total_order = 0.0
        fractional_substrate = false
        for substrate in substrates_field
            sp_units_str = get(species_units, substrate.species, nothing)
            if sp_units_str === nothing
                resolvable = false
                break
            end
            sp_dim = parse_units(sp_units_str)
            if sp_dim === nothing
                resolvable = false
                break
            end
            species_dim === nothing && (species_dim = sp_dim)
            if !isinteger(substrate.stoichiometry)
                fractional_substrate = true
                break
            end
            substrate_dim = substrate_dim * (sp_dim^Int(substrate.stoichiometry))
            total_order += substrate.stoichiometry
        end
        fractional_substrate && continue
        (!resolvable || species_dim === nothing) && continue
        time_unit === nothing && continue

        # Skip when the reference concentration unit is dimensionless
        # (mol/mol, ppm, …) — mass-action convention is ambiguous there.
        dimension(species_dim) == dimension(Unitful.NoUnits) && continue

        expected_dim = species_dim / time_unit
        full_dim = rate_dim * substrate_dim
        if dimension(full_dim) != dimension(expected_dim)
            first_sp_units = get(species_units, substrates_field[1].species, "")
            order_str = isinteger(total_order) ? string(Int(total_order)) : string(total_order)
            push!(errors, StructuralError(
                "$path/reactions/$(i-1)",
                "Reaction $(reaction.id) rate '$rate_name' units '$rate_units_str' " *
                "incompatible with order-$order_str reaction for species units " *
                "'$first_sp_units' (expected rate*substrates to have dimensions of species/time)",
                "unit_inconsistency",
            ))
        end
    end

    # Recurse into subsystems
    for (subsys_name, subsys) in rs.subsystems
        append!(errors, validate_reaction_rate_units(subsys, "$path/subsystems/$subsys_name"))
    end

    return errors
end

"""
    validate_model_gradient_units(file::EsmFile, model::Model, path::String) -> Vector{StructuralError}

Flag `grad` / `div` / `laplacian` operators whose spatial coordinate is
declared in the enclosing model but carries no units. Since the v0.8.0
removal of the `Domain.spatial` table, a domain carries no spatial-grid
geometry: a PDE's axes are `index_sets` entries and their physical
coordinates are ordinary data — declared as model variables/parameters or
loaded fields (esm-spec §"The domain object"). The operator node's `dim` is
therefore resolved against the enclosing model's declared variables:

- `dim` names a variable declared WITH units → resolvable; no error.
- `dim` names a variable declared WITHOUT units → dimensionally ambiguous;
  `unit_inconsistency` (a validator must not silently assume a metre
  denominator — see `tests/invalid/units_gradient_operator_mismatch.esm`).
- `dim` names no declared variable — an index-set axis whose physical
  coordinate is bound elsewhere, e.g. by a discretization rewrite rule
  (esm-spec §9.6.8) — → left alone (legacy metre-denominator fallback).

Mirrors the TypeScript binding's grad/div/laplacian dimension rule
(`pkg/earthsci-ast-ts/src/units.ts`: a coordinate present in the
binding table but dimensionless is flagged; one absent falls back) and the
Rust binding's `validate_model_gradient_units`. Recurses into subsystems.
"""
function validate_model_gradient_units(file::EsmFile, model::Model, path::String)::Vector{StructuralError}
    errors = StructuralError[]

    # Coordinate → units-string map from the model's declared variables. A
    # model with no variables short-circuits: there is nothing to resolve a
    # `dim` against, so child operators fall back to legacy behaviour.
    # Subsystems still recurse so each resolves against its own declarations.
    coord_units = _collect_coordinate_units(file, model)

    if coord_units !== nothing
        for (i, eq) in enumerate(model.equations)
            eq_path = "$path/equations/$(i-1)"
            append!(errors, _check_gradient_ops(eq.lhs, coord_units, eq_path))
            append!(errors, _check_gradient_ops(eq.rhs, coord_units, eq_path))
        end
    end

    for (subsys_name, subsys) in model_subsystems(model)
        append!(errors, validate_model_gradient_units(file, subsys, "$path/subsystems/$subsys_name"))
    end

    return errors
end

# Returns a Dict{String, Union{String,Nothing}} mapping declared-variable name
# → declared units (`nothing` when the variable has no — or an empty — `units`
# field), or `nothing` when the model declares no variables at all. The model's
# own variable declarations are the coordinate source: "their physical
# coordinates, spacing, and CRS parameters are ordinary data — loaded from a
# `data_loaders` primitive or declared as variables/parameters" (esm-spec,
# domain section). The `file` argument is kept for signature parity with the
# Rust binding and for a future loader-declared-coordinate resolution path.
function _collect_coordinate_units(file::EsmFile, model::Model)::Union{Dict{String,Union{String,Nothing}},Nothing}
    isempty(model.variables) && return nothing
    coord_units = Dict{String,Union{String,Nothing}}()
    for (name, v) in model.variables
        units = v.units
        coord_units[name] = (units === nothing || isempty(units)) ? nothing : units
    end
    return coord_units
end

function _check_gradient_ops(expr::ASTExpr, coord_units::Dict{String,Union{String,Nothing}},
                             eq_path::String)::Vector{StructuralError}
    errors = StructuralError[]
    if expr isa OpExpr
        if expr.op in ("grad", "div", "laplacian") && expr.dim !== nothing
            dim_name = expr.dim
            if haskey(coord_units, dim_name) && coord_units[dim_name] === nothing
                # Describe the operand for the error message: use the variable
                # name if it's a bare reference, otherwise fall back to the
                # operator's own label. Matches the TS binding's user-visible
                # framing without committing to a fully-rendered expression.
                operand_label = if !isempty(expr.args) && expr.args[1] isa VarExpr
                    "variable '$(expr.args[1].name)'"
                else
                    "$(expr.op) operand"
                end
                push!(errors, StructuralError(
                    eq_path,
                    "Gradient operator applied to $operand_label with incompatible spatial " *
                    "units: coordinate '$dim_name' has no declared units",
                    "unit_inconsistency",
                ))
            end
        end
        for arg in expr.args
            append!(errors, _check_gradient_ops(arg, coord_units, eq_path))
        end
    end
    return errors
end

"""
    system_exists_in_file(file::EsmFile, system_name::String) -> Bool

Check if a system (model, reaction_system, data_loader, or operator) exists in
the ESM file. Delegates to [`find_top_level_system`](@ref) (types.jl) so the
top-level lookup (models, reaction systems, data loaders) lives in exactly one
place.

A coupling endpoint may name a SUBSYSTEM by its dotted path
(`AtmosphericChemistry.Aerosols`, `EmissionSources.Biogenic.Forest`), which is
the whole point of scoped references (§4.6). Only ever consulting the top-level
tables reported those as `undefined_system` and rejected the valid
tests/valid/scoped_refs_coupling.esm, so the dotted tail is now walked down the
subsystem tree.
"""
function system_exists_in_file(file::EsmFile, system_name::String)::Bool
    system, _ = find_top_level_system(file, system_name)
    system === nothing || return true

    # Dotted path: resolve the head against the top level, then walk the tail
    # through `subsystems`.
    segments = split(system_name, '.')
    length(segments) > 1 || return false
    root, _ = find_top_level_system(file, String(segments[1]))
    root isa Model || return false

    # `model_subsystems` yields a lazy (name, value) generator, not a Dict.
    current = root
    for seg in segments[2:end]
        next = nothing
        for (sub_name, sub_value) in model_subsystems(current)
            if sub_name == String(seg)
                next = sub_value
                break
            end
        end
        next === nothing && return false
        # A DataLoader leaf is a legal endpoint, but nothing can be nested under
        # it, so any remaining segment cannot resolve.
        next isa Model || return seg == segments[end]
        current = next
    end
    return true
end

"""
    validate_event_consistency(model::Model, path::String) -> Vector{StructuralError}

Validate event consistency: continuous conditions are expressions,
discrete conditions produce booleans, affect variables declared,
functional affect refs valid.
"""
function validate_event_consistency(model::Model, path::String;
                                    is_coupled::Bool=false)::Vector{StructuralError}
    errors = StructuralError[]

    # Validate discrete events
    for (i, event) in enumerate(model.discrete_events)
        event_path = "$path/discrete_events/$(i-1)"
        append!(errors, validate_single_event_consistency(model, event, event_path;
                                                          is_coupled=is_coupled))
    end

    # Validate continuous events
    for (i, event) in enumerate(model.continuous_events)
        event_path = "$path/continuous_events/$(i-1)"
        append!(errors, validate_single_event_consistency(model, event, event_path;
                                                          is_coupled=is_coupled))
    end

    # Recursively check subsystems. A subsystem of a coupled model is composed
    # along with its parent, so it inherits the exemption.
    for (subsys_name, subsys) in model_subsystems(model)
        append!(errors, validate_event_consistency(subsys, "$path/subsystems/$subsys_name";
                                                   is_coupled=is_coupled))
    end

    return errors
end

"""
    validate_single_event_consistency(model::Model, event::EventType, event_path::String;
                                      is_coupled=false) -> Vector{StructuralError}

Validate consistency of a single event.
"""
# The §6.4 operator placeholder. In an operator-composed / coupled model `_var`
# stands for each matching state variable of the system this one is composed
# with, and it is substituted at composition — so an event affect that ASSIGNS to
# it is legal, exactly as an equation that differentiates it is. Reporting `_var`
# as an undeclared event target while the very same document's equations were
# exempt from the reference check was internally inconsistent, and it rejected the
# valid tests/valid/full_coupled.esm (finding (b)).
const _OPERATOR_PLACEHOLDER_VAR = "_var"

_is_declared_event_target(model::Model, name::AbstractString, is_coupled::Bool)::Bool =
    haskey(model.variables, name) || (is_coupled && name == _OPERATOR_PLACEHOLDER_VAR)

function validate_single_event_consistency(model::Model, event::EventType, event_path::String;
                                           is_coupled::Bool=false)::Vector{StructuralError}
    errors = StructuralError[]

    if isa(event, ContinuousEvent)
        # Continuous event conditions should be mathematical expressions (zero-crossing)
        # This is automatically satisfied by the type system (Vector{ASTExpr})

        # Validate affect variable declarations
        for (j, affect) in enumerate(event.affects)
            _is_declared_event_target(model, affect.lhs, is_coupled) && continue
            push!(errors, StructuralError(
                "$event_path/affects/$(j-1)",
                "Affect target variable '$(affect.lhs)' not declared in model",
                "undefined_affect_variable",
                Dict{String,Any}("variable" => affect.lhs)
            ))
        end

    elseif isa(event, DiscreteEvent)
        # For condition triggers, ensure expression could produce boolean
        if isa(event.trigger, ConditionTrigger)
            # In practice, we'd need more sophisticated analysis to ensure boolean result
            # For now, accept all expressions as they could evaluate to boolean
        end

        # Validate functional affect targets
        for (j, affect) in enumerate(event.affects)
            _is_declared_event_target(model, affect.target, is_coupled) && continue
            push!(errors, StructuralError(
                "$event_path/affects/$(j-1)",
                "Functional affect target '$(affect.target)' not declared in model",
                "undefined_affect_target",
                Dict{String,Any}("variable" => affect.target)
            ))
        end

        # `discrete_parameters` names what the event mutates as a PARAMETER
        # (MTK's `discrete_parameters`). Naming a state variable there is a
        # category error: the integrator owns that name, so the event's write is
        # either ignored or fights the solver.
        if event.discrete_parameters !== nothing
            for name in event.discrete_parameters
                var = get(model.variables, name, nothing)
                if var === nothing
                    push!(errors, StructuralError(
                        event_path,
                        "Discrete parameter '$name' is not declared in the model",
                        "invalid_discrete_param"
                    ))
                elseif var.type != ParameterVariable
                    push!(errors, StructuralError(
                        event_path,
                        "Discrete parameter '$name' is not declared as a parameter " *
                        "(found as $(_variable_type_word(var.type)) variable)",
                        "invalid_discrete_param"
                    ))
                end
            end
        end
    end

    return errors
end

# Lower-case spelling of a ModelVariableType for diagnostics ("state",
# "parameter", "observed", "brownian", "discrete"). Total over the enum: a
# missing arm here silently MISLABELS a variable in the diagnostic it prints.
function _variable_type_word(t::ModelVariableType)::String
    t == StateVariable && return "state"
    t == ParameterVariable && return "parameter"
    t == ObservedVariable && return "observed"
    t == BrownianVariable && return "brownian"
    return "discrete"
end

# ============================================================================
# Multi-Domain Validation
# ============================================================================

"""
    validate_multi_domain(file::EsmFile) -> Vector{StructuralError}

Multi-domain / interface consistency checks were retired in esm-spec v0.8.0:
a document now has a single shared `domain` (no map of named domains), no
`interfaces` block, and cross-grid coupling is an ordinary regridding
`transform` expression. Nothing here to validate; retained as a no-op so the
top-level validator (`validate_structural`) keeps a stable call surface.
"""
function validate_multi_domain(file::EsmFile)::Vector{StructuralError}
    return StructuralError[]
end

"""
Well-known physical constants whose declared units can be dimensionally
verified against a canonical form. Conservative on purpose — names chosen
to minimize collision with common non-constant uses (e.g., no `c` for
speed of light, which conflicts with concentration). Mirrors Python's
`_KNOWN_PHYSICAL_CONSTANTS` (gt-j91l / gt-3tgv).

Each tuple is (name, canonical_units, description).
"""
const _KNOWN_PHYSICAL_CONSTANTS = (
    ("R", "J/(mol*K)", "ideal gas constant"),
    ("k_B", "J/K", "Boltzmann constant"),
    ("N_A", "1/mol", "Avogadro constant"),
)

# Returns true when the expression tree references a variable by exact name
# (string leaf match). Walks operator arg lists recursively.
function _expr_references_name(expr, name::String)::Bool
    if expr isa VarExpr
        return expr.name == name
    elseif expr isa OpExpr
        for arg in expr.args
            if _expr_references_name(arg, name)
                return true
            end
        end
    end
    return false
end

"""
    validate_physical_constant_units(model::Model, path::String) -> Vector{StructuralError}

Flag parameters whose name matches a well-known physical constant but whose
declared units are dimensionally incompatible with the canonical form (e.g.,
`R` declared as `kcal/mol` — missing temperature — instead of `J/(mol*K)`).
Reports at the first observed-variable usage site in the same model;
otherwise at the declaration. Mirrors Python's
`parse._check_physical_constant_units` (gt-3tgv). Recurses into subsystems.
"""
function validate_physical_constant_units(model::Model, path::String)::Vector{StructuralError}
    errors = StructuralError[]

    for (constant_name, canonical, description) in _KNOWN_PHYSICAL_CONSTANTS
        haskey(model.variables, constant_name) || continue
        var = model.variables[constant_name]
        var.type == ParameterVariable || continue
        declared_str = var.units
        (declared_str === nothing || isempty(declared_str)) && continue

        declared_unit = parse_units(String(declared_str))
        canonical_unit = parse_units(canonical)
        (declared_unit === nothing || canonical_unit === nothing) && continue
        dimension(declared_unit) == dimension(canonical_unit) && continue

        usage_name = nothing
        for (other_name, other_var) in model.variables
            other_var.type == ObservedVariable || continue
            other_var.expression === nothing && continue
            if _expr_references_name(other_var.expression, constant_name)
                usage_name = other_name
                break
            end
        end
        target = usage_name === nothing ? constant_name : usage_name

        push!(errors, StructuralError(
            "$path/variables/$target",
            "Physical constant used with incorrect dimensional analysis " *
            "(constant '$constant_name' ($description) declared with units '$declared_str', " *
            "expected dimensions compatible with '$canonical')",
            "unit_inconsistency",
        ))
    end

    # Recurse into subsystems
    for (subsys_name, subsys) in model_subsystems(model)
        append!(errors, validate_physical_constant_units(subsys, "$path/subsystems/$subsys_name"))
    end

    return errors
end

# Compute the linear conversion factor from `from_units` to `to_units`, or
# `nothing` when the conversion is affine (e.g., degC → K) or the units can't
# be parsed/converted. A conversion is linear iff 0 `from_units` converts to
# 0 `to_units` (within tolerance).
function _linear_conversion_factor(from_units::String, to_units::String)::Union{Float64,Nothing}
    from_unit = parse_units(from_units)
    to_unit = parse_units(to_units)
    (from_unit === nothing || to_unit === nothing) && return nothing
    dimension(from_unit) == dimension(to_unit) || return nothing
    try
        q0 = Unitful.ustrip(Unitful.uconvert(to_unit, 0.0 * from_unit))
        q1 = Unitful.ustrip(Unitful.uconvert(to_unit, 1.0 * from_unit))
        abs(q0) > 1e-12 && return nothing  # affine
        return Float64(q1)
    catch
        return nothing
    end
end

"""
    validate_conversion_factor_consistency(model::Model, path::String) -> Vector{StructuralError}

Flag observed variables whose defining expression is `<numeric> * <var>`
(or `<var> * <numeric>`) where the declared units and the source variable's
units are dimensionally compatible but the numeric literal disagrees with the
correct linear conversion factor. Only linear (non-affine) conversions are
checked. Mirrors Python's `parse._check_conversion_factor_consistency`
(gt-nvdv). Recurses into subsystems.
"""
function validate_conversion_factor_consistency(model::Model, path::String)::Vector{StructuralError}
    errors = StructuralError[]

    for (vname, var) in model.variables
        var.type == ObservedVariable || continue
        lhs_units = var.units
        (lhs_units === nothing || isempty(lhs_units)) && continue
        expr = var.expression
        expr isa OpExpr || continue
        expr.op == "*" || continue
        length(expr.args) == 2 || continue

        numeric = nothing
        var_ref = nothing
        for a in expr.args
            if a isa NumExpr
                numeric = Float64(a.value)
            elseif a isa IntExpr
                numeric = Float64(a.value)
            elseif a isa VarExpr
                var_ref = a.name
            end
        end
        (numeric === nothing || var_ref === nothing) && continue

        src_var = get(model.variables, var_ref, nothing)
        src_var === nothing && continue
        src_units = src_var.units
        (src_units === nothing || isempty(src_units)) && continue

        # Skip identical unit strings — no conversion to check.
        src_units == lhs_units && continue

        factor = _linear_conversion_factor(String(src_units), String(lhs_units))
        (factor === nothing || factor == 0) && continue
        abs(numeric - factor) <= 1e-9 * max(abs(factor), 1.0) && continue

        push!(errors, StructuralError(
            "$path/variables/$vname",
            "Unit conversion factor is incorrect for specified unit transformation " *
            "(variable '$vname', declared_units='$lhs_units', source_units='$src_units', " *
            "declared_factor=$numeric, expected_factor=$factor)",
            "unit_inconsistency",
        ))
    end

    # Recurse into subsystems
    for (subsys_name, subsys) in model_subsystems(model)
        append!(errors, validate_conversion_factor_consistency(subsys, "$path/subsystems/$subsys_name"))
    end

    return errors
end