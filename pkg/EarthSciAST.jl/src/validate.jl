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
Contains path, message, and error type for structural issues.
"""
struct StructuralError
    path::String
    message::String
    error_type::String
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
# JSON-Pointer-style "/a/b/3" (root → "/").
function _issue_pointer(path::AbstractString)::String
    isempty(path) && return "/"
    segments = [String(m.captures[1]) for m in eachmatch(r"\[([^\]]*)\]", path)]
    isempty(segments) && return "/"
    return "/" * join(segments, "/")
end

"""
    validate_schema(data::Any) -> Vector{SchemaError}

Validate data against the ESM schema.
Returns an empty vector if valid; otherwise a vector holding AT MOST ONE
`SchemaError` — JSONSchema.jl reports only the *first* failing issue it
encounters, so the result is never longer than one entry today. The `Vector`
return type is kept (it is the public contract, and leaves room for a
multi-error validator later); callers must not assume an exhaustive error
list. Each error carries the path (JSON-Pointer style), message, and keyword
extracted from that issue.
"""
function validate_schema(data::Any)::Vector{SchemaError}
    if ESM_SCHEMA === nothing
        @warn "Schema validation skipped - schema not loaded"
        return SchemaError[]
    end

    try
        result = JSONSchema.validate(ESM_SCHEMA, data)
        if result === nothing
            return SchemaError[]
        elseif result isa JSONSchema.SingleIssue
            # Extract the issue's location and failing keyword instead of
            # collapsing everything to "/" / "unknown".
            return [SchemaError(_issue_pointer(result.path), string(result), result.reason)]
        else
            return [SchemaError("/", string(result), "unknown")]
        end
    catch e
        return [SchemaError("/", "Schema validation error: $(e)", "error")]
    end
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

    # 1. Validate model equation-unknown balance
    if file.models !== nothing
        composed = _operator_composed_systems(file)
        for (model_name, model) in file.models
            append!(errors, validate_model_balance(model, "/models/$model_name";
                                                   check_excess = model_name ∉ composed))
        end
    end

    # 2. Validate reference integrity
    append!(errors, validate_reference_integrity(file))

    # 3. Validate reaction system consistency
    if file.reaction_systems !== nothing
        for (rs_name, rs) in file.reaction_systems
            append!(errors, validate_reaction_consistency(rs, "/reaction_systems/$rs_name"))
            append!(errors, validate_reaction_rate_units(rs, "/reaction_systems/$rs_name"))
        end
    end

    # 4. Validate event consistency
    if file.models !== nothing
        for (model_name, model) in file.models
            append!(errors, validate_event_consistency(model, "/models/$model_name"))
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
    data = serialize_esm_file(file)

    schema_errors = validate_schema(data)
    structural_errors = validate_structural(file)
    # Mirror the TS binding (validate.ts): unit findings are surfaced both as
    # `unit_warnings` strings and as promoted `unit_inconsistency` structural
    # errors, so neither channel is dead.
    unit_warnings = [e.message for e in structural_errors if e.error_type == "unit_inconsistency"]

    return ValidationResult(schema_errors, structural_errors, unit_warnings=unit_warnings)
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
                "equation_count_mismatch"
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
                "equation_count_mismatch"
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

    # Validate model variable references
    if file.models !== nothing
        for (model_name, model) in file.models
            append!(errors, validate_model_references(file, model, "/models/$model_name"))
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

"""
    validate_model_references(file::EsmFile, model::Model, path::String) -> Vector{StructuralError}

Validate variable references within a model.
"""
function validate_model_references(file::EsmFile, model::Model, path::String)::Vector{StructuralError}
    errors = StructuralError[]

    # Names in scope for this model's equations: its declared variables (state,
    # parameter, observed), the document-scoped `index_sets` registry (a
    # legitimate non-variable identifier namespace an aggregate may name — RFC
    # semiring-faq-unified-ir §5.2), and each equation's LHS target (a
    # solved-for unknown, e.g. an ODE state referenced as `D(u)` that is not
    # separately listed under `variables`). Bound loop indices and the time
    # variable are added per-node during the descent (see
    # `validate_expression_references`).
    scope = Set{String}(keys(model.variables))
    union!(scope, keys(file.index_sets))
    for eq in model.equations
        target = _equation_lhs_target(eq)
        target === nothing || push!(scope, target)
    end

    # Validate equation references
    for (i, eq) in enumerate(model.equations)
        append!(errors, validate_expression_references(file, eq.lhs, "$path/equations/$(i-1)/lhs"; scope=scope))
        append!(errors, validate_expression_references(file, eq.rhs, "$path/equations/$(i-1)/rhs"; scope=scope))
    end

    # Validate discrete event references
    for (i, event) in enumerate(model.discrete_events)
        append!(errors, validate_event_references(file, event, "$path/discrete_events/$(i-1)"))
    end

    # Validate continuous event references
    for (i, event) in enumerate(model.continuous_events)
        append!(errors, validate_event_references(file, event, "$path/continuous_events/$(i-1)"))
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
    if op.op == "index"
        # index(array, pos…): the positional element indices after the array
        # head that are bare names are bound index symbols.
        for i in 2:length(op.args)
            op.args[i] isa VarExpr && push!(syms, op.args[i].name)
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
# (qualified) reference (handled by the qualified-reference resolver), for the
# time variable, for a derivative form, or for a builtin function name.
function _check_bare_variable!(errors::Vector{StructuralError}, name::String,
                               path::String, scope::Union{Set{String},Nothing})
    scope === nothing && return errors
    occursin('.', name) && return errors
    (name == "t" || startswith(name, "d(") || name in _BUILTIN_FUNCTION_NAMES) && return errors
    if !(name in scope)
        push!(errors, StructuralError(
            path,
            "Variable '$name' referenced in equation is not declared",
            "undefined_variable"
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
    validate_event_references(file::EsmFile, event::EventType, path::String) -> Vector{StructuralError}

Validate event variable references.
"""
function validate_event_references(file::EsmFile, event::EventType, path::String)::Vector{StructuralError}
    errors = StructuralError[]

    if isa(event, ContinuousEvent)
        # Validate condition expressions
        for (i, condition) in enumerate(event.conditions)
            append!(errors, validate_expression_references(file, condition, "$path/conditions/$(i-1)"))
        end

        # Validate affect references
        for (i, affect) in enumerate(event.affects)
            append!(errors, validate_expression_references(file, affect.rhs, "$path/affects/$(i-1)/rhs"))
            # affect.lhs is a string (variable name) - would need model context to validate
        end

    elseif isa(event, DiscreteEvent)
        # Validate functional affect references
        for (i, affect) in enumerate(event.affects)
            append!(errors, validate_expression_references(file, affect.expression, "$path/affects/$(i-1)/expression"))
            # affect.target is a string (variable name) - would need model context to validate
        end

        # Validate trigger references (if condition-based)
        if isa(event.trigger, ConditionTrigger)
            append!(errors, validate_expression_references(file, event.trigger.expression, "$path/trigger/expression"))
        end
    end

    return errors
end

"""
    validate_reaction_consistency(rs::ReactionSystem, path::String) -> Vector{StructuralError}

Validate reaction system consistency: species declared, positive stoichiometries,
no null-null reactions, rate references declared.
"""
function validate_reaction_consistency(rs::ReactionSystem, path::String)::Vector{StructuralError}
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
            occursin('.', name) && continue
            (name == "t" || name in _BUILTIN_FUNCTION_NAMES) && continue
            (name in species_names || name in param_names) && continue
            push!(errors, StructuralError(
                reaction_path,
                "Parameter '$name' referenced in rate expression is not declared",
                "undefined_parameter"
            ))
        end
    end

    # Recursively check subsystems
    for (subsys_name, subsys) in rs.subsystems
        append!(errors, validate_reaction_consistency(subsys, "$path/subsystems/$subsys_name"))
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
"""
function system_exists_in_file(file::EsmFile, system_name::String)::Bool
    system, _ = find_top_level_system(file, system_name)
    return system !== nothing
end

"""
    validate_event_consistency(model::Model, path::String) -> Vector{StructuralError}

Validate event consistency: continuous conditions are expressions,
discrete conditions produce booleans, affect variables declared,
functional affect refs valid.
"""
function validate_event_consistency(model::Model, path::String)::Vector{StructuralError}
    errors = StructuralError[]

    # Validate discrete events
    for (i, event) in enumerate(model.discrete_events)
        event_path = "$path/discrete_events/$(i-1)"
        append!(errors, validate_single_event_consistency(model, event, event_path))
    end

    # Validate continuous events
    for (i, event) in enumerate(model.continuous_events)
        event_path = "$path/continuous_events/$(i-1)"
        append!(errors, validate_single_event_consistency(model, event, event_path))
    end

    # Recursively check subsystems
    for (subsys_name, subsys) in model_subsystems(model)
        append!(errors, validate_event_consistency(subsys, "$path/subsystems/$subsys_name"))
    end

    return errors
end

"""
    validate_single_event_consistency(model::Model, event::EventType, event_path::String) -> Vector{StructuralError}

Validate consistency of a single event.
"""
function validate_single_event_consistency(model::Model, event::EventType, event_path::String)::Vector{StructuralError}
    errors = StructuralError[]

    if isa(event, ContinuousEvent)
        # Continuous event conditions should be mathematical expressions (zero-crossing)
        # This is automatically satisfied by the type system (Vector{ASTExpr})

        # Validate affect variable declarations
        for (j, affect) in enumerate(event.affects)
            if !haskey(model.variables, affect.lhs)
                push!(errors, StructuralError(
                    "$event_path/affects/$(j-1)",
                    "Affect target variable '$(affect.lhs)' not declared in model",
                    "undefined_affect_variable"
                ))
            end
        end

    elseif isa(event, DiscreteEvent)
        # For condition triggers, ensure expression could produce boolean
        if isa(event.trigger, ConditionTrigger)
            # In practice, we'd need more sophisticated analysis to ensure boolean result
            # For now, accept all expressions as they could evaluate to boolean
        end

        # Validate functional affect targets
        for (j, affect) in enumerate(event.affects)
            if !haskey(model.variables, affect.target)
                push!(errors, StructuralError(
                    "$event_path/affects/$(j-1)",
                    "Functional affect target '$(affect.target)' not declared in model",
                    "undefined_affect_target"
                ))
            end
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
# "parameter", "observed", "brownian").
function _variable_type_word(t::ModelVariableType)::String
    t == StateVariable && return "state"
    t == ParameterVariable && return "parameter"
    t == ObservedVariable && return "observed"
    return "brownian"
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