# ============================================================
# Enum lowering — esm-spec §9.3
# ============================================================

"""
    EnumLoweringError <: EarthSciASTError

Raised when enum lowering (esm-spec §9.3) fails, carrying the stable diagnostic
`code` as a structured field rather than interpolated into the message — the
same error TYPE the four other bindings raise here (`EnumLoweringError` in TypeScript, Python and Rust;
`DiagnosticError` in Go). Julia raised `ParseError` from this pass until
API_SPEC.md §8 item 15, which made a caller's `catch e; e isa ParseError` the
only portable way to handle a failure that is not a parse failure at all.

Codes: `enum_op_malformed`, `unknown_enum`, `unknown_enum_symbol`.
"""
struct EnumLoweringError <: EarthSciASTError
    code::String
    message::String
end

Base.showerror(io::IO, e::EnumLoweringError) =
    print(io, "EnumLoweringError(", e.code, "): ", e.message)

# esm-spec §9.3: within ONE enum the integer values are unique — `0` included —
# and a duplicate is a defect of the block itself, raised whether or not any
# `enum` op names either symbol and before any op resolves. Values may coincide
# ACROSS enums. Takes the typed map or the raw JSON block; a non-integer value
# is left to the coercer's own diagnostic.
function _check_enum_values_unique(enums)::Nothing
    (enums === nothing || !(enums isa AbstractDict)) && return nothing
    for (enum_name, mapping) in pairs(enums)
        mapping isa AbstractDict || continue
        seen = Dict{Int, String}()
        for (sym, v) in pairs(mapping)
            (v isa Integer && !(v isa Bool)) || continue
            prior = get(seen, Int(v), nothing)
            prior === nothing || throw(
                EnumLoweringError(
                    ERROR_CODES.ENUM_DUPLICATE_VALUE,
                    "enums.$(enum_name): symbols `$(prior)` and `$(sym)` both map to " *
                        "$(Int(v)); values within one enum must be unique (esm-spec §9.3)"
                )
            )
            seen[Int(v)] = string(sym)
        end
    end
    return nothing
end

"""
    _lower_enum_ops_for_file(document, target, open_names) -> target′

Return raw-JSON `target` with its `enum` ops lowered against the `enums` block
of `document`, the file that wrote `target`. `target` is not modified.

An `enum` op is file-local (esm-spec §9.3): it resolves against the block of the
file it is written in. [`lower_enums!`](@ref) runs once over the root document,
so a tree that crosses a file boundary before that pass (a template-library body
reaching an importer, §9.7.5) is lowered here, at the edge, while its own file's
block is still at hand.

An op with an argument spelled by a name in `open_names` is left in place: a
template parameter substitutes position-blind (§9.6.3 constraint 5), so the call
site decides what it spells and the op resolves there. An op whose arguments are
not two strings is left for [`lower_enums!`](@ref), which owns the malformed-op
diagnostic. Raises [`EnumLoweringError`](@ref).
"""
function _lower_enum_ops_for_file(
        document, target,
        open_names::AbstractSet{String} = Set{String}()
    )
    enums = _is_object(document) ? _raw_get(document, "enums") : nothing
    _check_enum_values_unique(enums)
    return _lower_raw_enum_ops(target, enums, open_names)
end

function _lower_raw_enum_ops(node, enums, open_names::AbstractSet{String})
    if _is_array(node)
        return Any[_lower_raw_enum_ops(v, enums, open_names) for v in node]
    elseif _is_object(node)
        if _raw_get(node, "op") == "enum"
            args = _raw_get(node, "args")
            (
                args !== nothing && _is_array(args) && length(args) == 2 &&
                    _allof(a -> a isa AbstractString, args) &&
                    !_anyof(a -> String(a) in open_names, args)
            ) || return node
            enum_name, symbol = String(args[1]), String(args[2])
            mapping = enums !== nothing && _is_object(enums) ?
                _raw_get(enums, enum_name) : nothing
            mapping === nothing && throw(
                EnumLoweringError(
                    ERROR_CODES.UNKNOWN_ENUM,
                    "enum `$(enum_name)` is not declared in the file's `enums` block"
                )
            )
            (_is_object(mapping) && _raw_haskey(mapping, symbol)) ||
                throw(
                EnumLoweringError(
                    ERROR_CODES.UNKNOWN_ENUM_SYMBOL,
                    "symbol `$(symbol)` is not declared under enum `$(enum_name)`"
                )
            )
            return OrderedDict{String, Any}(
                "op" => "const", "args" => Any[],
                "value" => Int(_raw_get(mapping, symbol))
            )
        end
        out = OrderedDict{String, Any}()
        for (k, v) in pairs(node)
            out[string(k)] = _lower_raw_enum_ops(v, enums, open_names)
        end
        return out
    end
    return node
end

"""
    _lower_mounted_document_enums(document, target=document) -> target′

Return raw-JSON `target`, taken from a document mounted at a §4.7 edge, with its
`enum` ops lowered against `document`'s own `enums` block (esm-spec §9.3).
`target` is not modified.

Called once the mounted document has resolved in its own scope and before its
component is spliced into the mounting document, whose block is a different one.
`enums` do not merge across a mount, so this is the only block those ops can
name.

A template declaration's body is lowered with that template's `params` left
open, as at the import edge ([`_lower_enum_ops_for_file`](@ref)): an op spelled
with a parameter resolves at the call site. Everything else is lowered with no
open names. Raises [`EnumLoweringError`](@ref).
"""
function _lower_mounted_document_enums(document, target = document)
    enums = _is_object(document) ? _raw_get(document, "enums") : nothing
    return _lower_mounted_enum_ops(target, enums)
end

function _lower_mounted_enum_ops(node, enums)
    if _is_array(node)
        return Any[_lower_mounted_enum_ops(v, enums) for v in node]
    elseif _is_object(node)
        _raw_get(node, "op") == "enum" && return _lower_raw_enum_ops(node, enums, Set{String}())
        out = OrderedDict{String, Any}()
        for (k, v) in pairs(node)
            key = string(k)
            out[key] = key == "expression_templates" && _is_object(v) ?
                _lower_template_body_enums(v, enums) : _lower_mounted_enum_ops(v, enums)
        end
        return out
    end
    return node
end

function _lower_template_body_enums(templates, enums)
    out = OrderedDict{String, Any}()
    for (name, decl) in pairs(templates)
        if _is_object(decl) && _raw_haskey(decl, "body")
            params_raw = _raw_get(decl, "params")
            params = Set{String}(
                String(p) for p in
                    (params_raw !== nothing && _is_array(params_raw) ? params_raw : Any[])
                    if p isa AbstractString
            )
            lowered = OrderedDict{String, Any}(string(k) => v for (k, v) in pairs(decl))
            lowered["body"] = _lower_raw_enum_ops(_raw_get(decl, "body"), enums, params)
            out[string(name)] = lowered
        else
            out[string(name)] = decl
        end
    end
    return out
end

"""
    lower_enums(file::EsmFile) -> EsmFile

The PURE form: return a DEEP COPY of `file` with every `enum` op replaced by
the `const` integer the file's `enums` block assigns it, leaving `file`
untouched. This is the canonical spelling across the bindings (API_SPEC.md §8
item 15); [`lower_enums!`](@ref) is the in-place twin under Julia's `!`
convention (§2.2), and is what the load path calls.

Validation (esm-spec §9.3) — every rejection is an
[`EnumLoweringError`](@ref):
- an `enum` op whose args are not exactly two strings → `enum_op_malformed`;
- an `enum` op naming an undeclared enum → `unknown_enum`;
- an `enum` op naming a symbol not declared under that enum →
  `unknown_enum_symbol`.

A file with no `enums` block therefore raises `unknown_enum` on the first
`enum` op it contains.
"""
lower_enums(file::EsmFile)::EsmFile = lower_enums!(deepcopy(file))

"""
    lower_enums!(file::EsmFile)

Walk every expression tree in `file` and replace each `enum` op with a
`const` integer per the file's `enums` block. After this pass runs, no
`enum`-op nodes remain in the in-memory representation.

The in-place twin of [`lower_enums`](@ref), which documents the validation
rules and the [`EnumLoweringError`](@ref) codes both raise.

Mutates `file` in place; returns the file for convenience.
"""
function lower_enums!(file::EsmFile)::EsmFile
    enums = file.enums === nothing ? Dict{String, Dict{String, Int}}() : file.enums
    _check_enum_values_unique(enums)
    if file.models !== nothing
        for (_, m) in file.models
            _lower_model_enums!(m, enums)
        end
    end
    if file.reaction_systems !== nothing
        for (_, rs) in file.reaction_systems
            _lower_reaction_system_enums!(rs, enums)
        end
    end
    if file.coupling !== nothing
        for ce in file.coupling
            _lower_coupling_entry_enums!(ce, enums)
        end
    end
    return file
end

function _lower_model_enums!(model::Model, enums::Dict{String, Dict{String, Int}})
    # esm 1.0.0: a variable carries no defining expression, so the only
    # per-variable expression positions left are a parameter update's `when`
    # trigger and its `expression` value form (esm-spec §5.4).
    for (name, var) in model.variables
        var.update === nothing && continue
        rules = ParameterUpdate[]
        changed = false
        for r in var.update
            nw = r.when === nothing ? nothing : _lower_expr_enums(r.when, enums)
            ne = r.expression === nothing ? nothing : _lower_expr_enums(r.expression, enums)
            (nw !== r.when || ne !== r.expression) && (changed = true)
            push!(
                rules, ParameterUpdate(
                    r.kind; times = r.times, interval = r.interval,
                    initial_offset = r.initial_offset, when = nw, direction = r.direction,
                    source = r.source, hook = r.hook, expression = ne, from = r.from,
                    handler = r.handler
                )
            )
        end
        changed && (model.variables[name] = reconstruct(var; update = rules))
    end
    new_eqs = Equation[]
    for eq in model.equations
        push!(
            new_eqs, Equation(
                _lower_expr_enums(eq.lhs, enums),
                _lower_expr_enums(eq.rhs, enums);
                _comment = eq._comment
            )
        )
    end
    empty!(model.equations)
    append!(model.equations, new_eqs)

    new_init_eqs = Equation[]
    for eq in model.initialization_equations
        push!(
            new_init_eqs, Equation(
                _lower_expr_enums(eq.lhs, enums),
                _lower_expr_enums(eq.rhs, enums);
                _comment = eq._comment
            )
        )
    end
    empty!(model.initialization_equations)
    append!(model.initialization_equations, new_init_eqs)

    for (_, sub) in model.subsystems
        # An unresolved SubsystemRef carries no enums to lower.
        sub isa Model || continue
        _lower_model_enums!(sub, enums)
    end
    return
end

function _lower_reaction_system_enums!(
        rs::ReactionSystem,
        enums::Dict{String, Dict{String, Int}}
    )
    new_reactions = Reaction[]
    for r in rs.reactions
        # `raw_substrates`/`raw_products`: the ordered StoichiometryEntry
        # fields (`get_reactants_dict`/`get_products_dict` give the unordered
        # `Dict{String,Float64}` view instead).
        push!(
            new_reactions, Reaction(
                r.id,
                raw_substrates(r),
                raw_products(r),
                _lower_expr_enums(r.rate, enums);
                name = r.name,
                reference = r.reference
            )
        )
    end
    empty!(rs.reactions)
    append!(rs.reactions, new_reactions)
    for (_, sub) in rs.subsystems
        _lower_reaction_system_enums!(sub, enums)
    end
    return
end

function _lower_coupling_entry_enums!(
        ce::CouplingEntry,
        enums::Dict{String, Dict{String, Int}}
    )
    return if ce isa CouplingCouple && haskey(ce.connector, "equations")
        eqs = ce.connector["equations"]
        if eqs isa AbstractVector
            for (i, e) in enumerate(eqs)
                if e isa AbstractDict && haskey(e, "expression")
                    expr_obj = e["expression"]
                    if expr_obj isa ASTExpr
                        e["expression"] = _lower_expr_enums(expr_obj, enums)
                    end
                end
            end
        end
    end
end

# Recursive enum-op lowering. Returns a new tree only if a substitution
# occurred; otherwise returns the input unchanged so identity-based caching
# upstream still works.
function _lower_expr_enums(e::NumExpr, _)
    return e
end
function _lower_expr_enums(e::IntExpr, _)
    return e
end
function _lower_expr_enums(e::VarExpr, _)
    return e
end

# Identity-memoized entry: enum lowering is a pure, context-free function of
# the node, so a subtree shared under many parents (template expansion stores
# the expanded AST as a shared DAG) is lowered ONCE and the shared result
# respliced — keeping this pass linear in UNIQUE nodes instead of exponential
# in paths, and preserving the sharing for downstream consumers (the
# build-time `IdDict` memo caches in tree_walk/compile.jl key on it).
function _lower_expr_enums(
        e::OpExpr,
        enums::Dict{String, Dict{String, Int}}
    )::ASTExpr
    return _lower_expr_enums(e, enums, IdDict{OpExpr, ASTExpr}())
end

_lower_expr_enums(e::ASTExpr, _, ::IdDict{OpExpr, ASTExpr}) = e

function _lower_expr_enums(
        e::OpExpr,
        enums::Dict{String, Dict{String, Int}},
        memo::IdDict{OpExpr, ASTExpr}
    )::ASTExpr
    r = get(memo, e, nothing)
    r === nothing || return r
    res = _lower_expr_enums_uncached(e, enums, memo)
    memo[e] = res
    return res
end

function _lower_expr_enums_uncached(
        e::OpExpr,
        enums::Dict{String, Dict{String, Int}},
        memo::IdDict{OpExpr, ASTExpr}
    )::ASTExpr
    if e.op == "enum"
        # esm-spec §4.5: args are exactly two strings — the enum name and the
        # symbolic key. Strings come through `expression_from_json` as `VarExpr`,
        # so we read `.name` to recover them.
        if length(e.args) != 2
            throw(
                EnumLoweringError(
                    ERROR_CODES.ENUM_OP_MALFORMED,
                    "`enum` op expects 2 args (enum_name, symbol_name), got $(length(e.args))"
                )
            )
        end
        a1, a2 = e.args[1], e.args[2]
        enum_name = a1 isa VarExpr ? a1.name :
            a1 isa OpExpr && a1.op == "const" && a1.value isa AbstractString ? String(a1.value) :
            throw(
                EnumLoweringError(
                    ERROR_CODES.ENUM_OP_MALFORMED,
                    "`enum` op: first arg must be a string"
                )
            )
        symbol_name = a2 isa VarExpr ? a2.name :
            a2 isa OpExpr && a2.op == "const" && a2.value isa AbstractString ? String(a2.value) :
            throw(
                EnumLoweringError(
                    ERROR_CODES.ENUM_OP_MALFORMED,
                    "`enum` op: second arg must be a string"
                )
            )
        if !haskey(enums, enum_name)
            throw(
                EnumLoweringError(
                    ERROR_CODES.UNKNOWN_ENUM,
                    "enum `$(enum_name)` is not declared in the file's `enums` block"
                )
            )
        end
        mapping = enums[enum_name]
        if !haskey(mapping, symbol_name)
            throw(
                EnumLoweringError(
                    ERROR_CODES.UNKNOWN_ENUM_SYMBOL,
                    "symbol `$(symbol_name)` is not declared under enum `$(enum_name)`"
                )
            )
        end
        return OpExpr("const", ASTExpr[]; value = mapping[symbol_name])
    end
    # Recurse into EVERY expression-bearing field via the shared field-preserving
    # rewrite (`map_children`), so an `enum` nested in an integral bound, a
    # filter/key predicate, a makearray value, a table axis, or a dense `ranges`
    # bound is also lowered — and no `OpExpr` field is silently dropped on the
    # rebuild (the previous hand-listed ~17-keyword `OpExpr(...)` reconstruction
    # dropped `int_var`/`semiring`/`join`/`filter`/`id`/… whenever any child
    # changed, and never recursed `lower`/`upper`/`filter`/`key`/`ranges`).
    return map_children(x -> _lower_expr_enums(x, enums, memo), e)
end
