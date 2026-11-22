# ============================================================
# Enum lowering — esm-spec §9.3
# ============================================================

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

# Every container is rebuilt (`_map_json`): callers may mutate the result.
_lower_raw_enum_ops(node, enums, open_names::AbstractSet{String}) =
    _map_json(node) do _, n
    _is_object(n) || return _JSON_DESCEND
    return _raw_get(n, "op") == "enum" ? _lower_enum_op(n, enums, open_names) : _JSON_DESCEND
end

# One raw `enum` op lowered to its `const`, or `n` itself when its arguments
# are not two strings or one is an open name.
function _lower_enum_op(n, enums, open_names::AbstractSet{String})
    args = _raw_get(n, "args")
    (
        args !== nothing && _is_array(args) && length(args) == 2 &&
            _allof(a -> a isa AbstractString, args) &&
            !_anyof(a -> String(a) in open_names, args)
    ) || return n
    enum_name, symbol = String(args[1]), String(args[2])
    mapping = enums !== nothing && _is_object(enums) ? _raw_get(enums, enum_name) : nothing
    mapping === nothing && throw(
        EnumLoweringError(
            ERROR_CODES.UNKNOWN_ENUM,
            "enum `$(enum_name)` is not declared in the file's `enums` block"
        )
    )
    (_is_object(mapping) && _raw_haskey(mapping, symbol)) || throw(
        EnumLoweringError(
            ERROR_CODES.UNKNOWN_ENUM_SYMBOL,
            "symbol `$(symbol)` is not declared under enum `$(enum_name)`"
        )
    )
    return OrderedDict{String, Any}(
        "op" => "const", "args" => Any[], "value" => Int(_raw_get(mapping, symbol))
    )
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

_lower_mounted_enum_ops(node, enums) =
    _map_json(node) do key, n
    _is_object(n) || return _JSON_DESCEND
    key == "operators" && return _lower_template_body_enums(n, enums)
    _raw_get(n, "op") == "enum" && return _lower_enum_op(n, enums, Set{String}())
    return _JSON_DESCEND
end

function _lower_template_body_enums(templates, enums)
    out = OrderedDict{String, Any}()
    for (name, decl) in pairs(templates)
        if _is_object(decl) && _raw_haskey(decl, "body")
            params = Set{String}(_TemplateDecl(decl).params)
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

Replace each `enum` op with a `const` integer per the file's `enums` block, at
every expression site of the file ([`EXPRESSION_SITE_KINDS`](@ref), walked by
[`map_expressions!`](@ref)): a model's equations, initialization equations,
expression guesses, parameter update rules, expression bounds, events and
inline-test references (recursing into subsystems); a reaction system's
rates, parameter update rules, constraint equations, events and inline-test
references (recursing into subsystems); and the expressions of `coupling`
entries (a `variable_map` transform, an `event`'s conditions, trigger and
affects, a `couple` connector equation's typed expression).

The in-place twin of [`lower_enums`](@ref), which documents the validation
rules and the [`EnumLoweringError`](@ref) codes both raise.

Mutates `file` in place; returns the file for convenience.
"""
function lower_enums!(file::EsmFile)::EsmFile
    enums = file.enums === nothing ? Dict{String, Dict{String, Int}}() : file.enums
    _check_enum_values_unique(enums)
    memo = IdDict{OpExpr, ASTExpr}()
    return map_expressions!(e -> _lower_expr_enums(e, enums, memo), file)
end

# Recursive enum-op lowering. Returns a new tree only if a substitution
# occurred; otherwise returns the input unchanged so identity-based caching
# upstream still works.
#
# Identity-memoized: enum lowering is a pure, context-free function of the
# node, so a subtree shared under many parents (template expansion stores the
# expanded AST as a shared DAG, and one memo serves the whole file) is lowered
# ONCE and the shared result respliced — keeping this pass linear in UNIQUE
# nodes instead of exponential in paths, and preserving the sharing for
# downstream consumers (the build-time `IdDict` memo caches in
# tree_walk/compile.jl and its callers key on it).
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
    # Recurse into every expression-bearing field through the field-preserving
    # rewrite (`map_children`), so an `enum` nested in an integral bound, a
    # filter/key predicate, a makearray value, a table axis, or a dense
    # `ranges` bound is also lowered, and every other `OpExpr` field is kept.
    return map_children(x -> _lower_expr_enums(x, enums, memo), e)
end
