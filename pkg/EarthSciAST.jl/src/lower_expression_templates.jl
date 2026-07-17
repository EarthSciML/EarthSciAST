"""
Load-time rewrite pass for `expression_templates` (esm-spec §9.6,
docs/rfcs/ast-expression-templates.md, esm-giy).

`expression_templates` is the single structural-substitution mechanism in the
format. Each entry is a rewrite rule with `params` (metavariables) and a `body`
(the replacement Expression), applied in one of two ways:

- WITHOUT a `match` field — invoked explicitly by an `apply_expression_template`
  node whose `bindings` supply each param's AST (named-template expansion).
- WITH a `match` field — an auto-applied rewrite rule: `match` is a pattern
  Expression whose param occurrences are wildcards, fired wherever it
  structurally matches a node. A param in an operand/`args` position binds to the
  matched sub-AST; a param in a scalar field (`dim`, `side`, …) binds to the
  matched literal. An optional `where` block (esm-spec §9.6.1,
  docs/rfcs/match-pattern-scoping-constraints.md) adds STATIC scoping
  constraints on the captured params: `{"F": {"shape": ["edges"]}}` makes the
  rule eligible only where `F` bound to a bare variable reference whose
  declaration in the enclosing component carries exactly that `shape` (ordered
  index-set names). Constraint evaluation consults declared shapes only —
  never runtime values — and is part of match ELIGIBILITY: a
  constraint-excluded rule is a non-matching rule at that node, filtered
  before the priority / declaration-order selection.

Rewriting is an OUTERMOST-FIRST, PRIORITY-ORDERED, BOUNDED-FIXPOINT process
(esm-spec §9.6.3, `_rewrite_to_fixpoint`). Rule application proceeds in passes;
one pass (`_rewrite_pass`) is a single pre-order (outermost-first) walk of the
tree. At each node the engine first tries to fire a rule AT that node before
descending: an `apply_expression_template` op is expanded, otherwise the `match`
rules are consulted and the winner is selected deterministically — highest
`priority` (integer, default 0), ties broken by DECLARATION order. The winner's
`body` replaces the node and the walk does NOT descend into that freshly-produced
body during the current pass; if no rule fires, the walk descends into children.
Passes repeat until a pass performs zero rewrites (the fixpoint) or until
`MAX_REWRITE_PASSES` productive passes have run without converging, in which case
the file is rejected with `rewrite_rule_nonterminating` (the pass bound — not a
static check — is the authoritative termination guard, so a self-reintroducing
rule simply fails to converge). Because selection and traversal are fully
deterministic, all bindings produce byte-identical fixpoints. After convergence
the tree contains no `apply_expression_template` ops and no `expression_templates`
blocks — downstream consumers see only normal Expression ASTs (Option A
round-trip). Any rewrite-target op (e.g. a spatial `D`) that survives the
fixpoint into an evaluation position is caught later by the `unlowered_operator`
gate, not here.

Operates on the raw JSON view (JSON3.Object/Array or Dict/Vector) and
returns a `Dict{String,Any}` view ready for `coerce_esm_file`.
"""

const APPLY_EXPRESSION_TEMPLATE_OP = "apply_expression_template"

"""
    JSONLikeDict

Thin wrapper around `Dict{String,Any}` that exposes string-keyed
entries via property syntax (`view.esm`, `view.metadata`, ...) so the
existing JSON3-compatible code paths in `coerce_esm_file` work
uniformly on the post-template-expansion view.

Indexing via `view[:key]` and `view["key"]`, `haskey`, `pairs`, and
iteration are all forwarded to the underlying dict; anything not
covered here is intentionally not implemented (this wrapper exists
only for the load-time path).
"""
struct JSONLikeDict
    # Any string-keyed dict (plain `Dict` from `_to_dict`, `OrderedDict` from
    # the sharing-preserving rewrite/substitution rebuilds) is carried BY
    # REFERENCE: the underlying object's identity is the key of the
    # `parse_expression` identity memo (`_PARSE_EXPR_MEMO_KEY`, parse.jl), so
    # converting on wrap would mint a fresh dict per access and silently
    # unshare a structurally-shared expanded tree.
    data::AbstractDict{String,Any}
end

_wrap(x) = x isa AbstractDict{String,Any} ? JSONLikeDict(x) :
           x isa AbstractDict ? JSONLikeDict(Dict{String,Any}(string(k) => v for (k,v) in pairs(x))) :
           x isa AbstractVector ? Any[_wrap(v) for v in x] :
           x

Base.getproperty(v::JSONLikeDict, sym::Symbol) =
    sym === :data ? getfield(v, :data) : _wrap(getfield(v, :data)[string(sym)])

Base.hasproperty(v::JSONLikeDict, sym::Symbol) =
    sym === :data || haskey(getfield(v, :data), string(sym))

Base.haskey(v::JSONLikeDict, key::Symbol) = haskey(getfield(v, :data), string(key))
Base.haskey(v::JSONLikeDict, key::AbstractString) = haskey(getfield(v, :data), String(key))

Base.getindex(v::JSONLikeDict, key::Symbol) = _wrap(getfield(v, :data)[string(key)])
Base.getindex(v::JSONLikeDict, key::AbstractString) = _wrap(getfield(v, :data)[String(key)])

function Base.get(v::JSONLikeDict, key::Symbol, default)
    d = getfield(v, :data); s = string(key)
    haskey(d, s) ? _wrap(d[s]) : default
end
function Base.get(v::JSONLikeDict, key::AbstractString, default)
    d = getfield(v, :data); s = String(key)
    haskey(d, s) ? _wrap(d[s]) : default
end

# Iteration / pairs wrap nested values so `coerce_*` functions that
# do `(k, v) in pairs(file.models)` see JSONLikeDict-wrapped models.
struct _JSONLikePairs
    inner::AbstractDict{String,Any}
end
Base.iterate(p::_JSONLikePairs) = _step(p.inner, iterate(p.inner))
Base.iterate(p::_JSONLikePairs, state) = _step(p.inner, iterate(p.inner, state))
Base.length(p::_JSONLikePairs) = length(p.inner)
function _step(_::AbstractDict{String,Any}, it)
    it === nothing && return nothing
    (kv, state) = it
    return (Pair(kv.first, _wrap(kv.second)), state)
end

Base.pairs(v::JSONLikeDict) = _JSONLikePairs(getfield(v, :data))
Base.keys(v::JSONLikeDict) = keys(getfield(v, :data))
Base.iterate(v::JSONLikeDict) = iterate(_JSONLikePairs(getfield(v, :data)))
Base.iterate(v::JSONLikeDict, state) = iterate(_JSONLikePairs(getfield(v, :data)), state)
Base.length(v::JSONLikeDict) = length(getfield(v, :data))

"""
    ExpressionTemplateError <: Exception

Exception raised when a load-time lowering pass fails: expression-template
expansion (esm-spec §9.6), template-library imports (§9.7), coupling-library
imports (§10.9–§10.11), and the subsystem-reference / index-set checks in
`parse.jl`. Carries a stable diagnostic `code` drawn from
[`_KNOWN_DIAGNOSTIC_CODES`](@ref), the single registry of every code this
exception is raised with. Codes (and their message texts) are
conformance-relevant, so a new raise site MUST use a code registered there —
and a genuinely new code MUST be added to the registry alongside its first
raise site.
"""
struct ExpressionTemplateError <: Exception
    code::String
    message::String
end

Base.showerror(io::IO, e::ExpressionTemplateError) =
    print(io, "[$(e.code)] $(e.message)")

"""
    _KNOWN_DIAGNOSTIC_CODES

Registry of every stable diagnostic code raised as an
[`ExpressionTemplateError`](@ref) anywhere in the package (this file,
`template_imports.jl`, `coupling_imports.jl`, `parse.jl`), grouped by the
spec section that pins it. Diagnostic codes are conformance-relevant
(cross-binding fixtures assert them), so keep this tuple in sync with the
raise sites: register any new code here when introducing it.
"""
const _KNOWN_DIAGNOSTIC_CODES = (
    # esm-spec §9.6 expression templates + §9.6.4 post-expansion validators
    # (lower_expression_templates.jl; the recursive-body composition check
    # lives in template_imports.jl).
    "apply_expression_template_unknown_template",
    "apply_expression_template_bindings_mismatch",
    "apply_expression_template_recursive_body",
    "apply_expression_template_invalid_declaration",
    "apply_expression_template_version_too_old",
    "rewrite_rule_nonterminating",
    "template_constraint_unknown_index_set",
    "geometry_manifold_invalid",
    "makearray_region_inverted",
    # esm-spec §9.7 template-library imports + metaparameters
    # (template_imports.jl).
    "template_import_version_too_old",
    "template_import_unresolved",
    "template_import_not_library",
    "template_import_is_coupling_library",
    "template_import_cycle",
    "template_import_name_conflict",
    "template_import_unknown_name",
    "template_import_index_set_conflict",
    "template_import_rename_unknown_name",
    "template_import_rebind_unknown_name",
    "template_import_rename_collision",
    "template_import_rename_invalid",
    "template_inject_target_unknown",
    "template_inject_target_not_component",
    "template_inject_target_is_loader",
    "template_body_expansion_too_deep",
    "metaparameter_unbound",
    "metaparameter_type_error",
    "metaparameter_name_conflict",
    # esm-spec §10.9–§10.11 coupling-library imports (coupling_imports.jl).
    "coupling_import_unresolved",
    "coupling_import_not_library",
    "coupling_import_unknown_role",
    "coupling_import_role_unbound",
    "coupling_import_bind_not_a_component",
    "coupling_edge_unknown_role",
    "coupling_role_unused",
    "coupling_library_illegal_payload",
    "coupling_library_nested_import",
    # Subsystem-reference / index-set checks (parse.jl).
    "subsystem_ref_is_template_library",
    "subsystem_ref_is_coupling_library",
    "subsystem_index_set_conflict",
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
# (`_is_object` / `_is_array` — the raw-JSON node-kind predicates — live in
# src/json_walk.jl with the shared traversal combinators.)

# SHARING-PRESERVING normalization: the identity memo maps each input
# container to its (single) normalized counterpart, so a shared subtree — e.g.
# a template body composed as a DAG by `_substitute` — normalizes to ONE
# shared output object instead of being expanded into an exponential tree.
# Fresh-parsed JSON3 views are trees (no aliasing is expressible in JSON
# text), so the memo is a no-op there; it only ever fires on the native
# Dict/Vector nodes the lowering passes themselves create.
function _to_dict(x)::Dict{String,Any}
    return _to_dict_memo(x, IdDict{Any,Any}())
end

function _to_dict_memo(x, memo::IdDict{Any,Any})::Dict{String,Any}
    r = get(memo, x, nothing)
    r === nothing || return r
    out = Dict{String,Any}()
    memo[x] = out
    for (k, v) in pairs(x)
        out[string(k)] = _normalize_memo(v, memo)
    end
    return out
end

_normalize(x) = _normalize_memo(x, IdDict{Any,Any}())

function _normalize_memo(x, memo::IdDict{Any,Any})
    if _is_object(x)
        return _to_dict_memo(x, memo)
    elseif _is_array(x)
        r = get(memo, x, nothing)
        r === nothing || return r
        out = Any[]
        memo[x] = out
        for v in x
            push!(out, _normalize_memo(v, memo))
        end
        return out
    else
        return x
    end
end

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

function _assert_no_nested_apply(body, template_name::String, path::String)
    if _is_array(body)
        for (i, child) in enumerate(body)
            _assert_no_nested_apply(child, template_name, "$path/$(i-1)")
        end
        return
    end
    if _is_object(body)
        op = _raw_get(body, "op")
        op_str = op === nothing ? "" : string(op)
        if op_str == APPLY_EXPRESSION_TEMPLATE_OP
            throw(ExpressionTemplateError(
                "apply_expression_template_invalid_declaration",
                "expression_templates.$(template_name): `match` contains an 'apply_expression_template' node at $path; match patterns MUST NOT reference templates (esm-spec §9.7.3)"))
        end
        for (k, v) in pairs(body)
            _assert_no_nested_apply(v, template_name, "$path/$(string(k))")
        end
    end
end

function _validate_templates(templates::Dict{String,Any}, scope::String)
    for (name, decl) in templates
        if !_is_object(decl)
            throw(ExpressionTemplateError(
                "apply_expression_template_invalid_declaration",
                "$scope.expression_templates.$name: entry must be an object with params + body"))
        end
        # `params` MAY be empty (esm-spec §9.6.1, 0.8.0): a zero-parameter
        # template is a named constant fragment (common in library files).
        params = _raw_get(decl, "params")
        if params === nothing || !_is_array(params)
            throw(ExpressionTemplateError(
                "apply_expression_template_invalid_declaration",
                "$scope.expression_templates.$name: 'params' must be an array of strings"))
        end
        seen = Set{String}()
        for p in params
            if !(p isa AbstractString) || isempty(p)
                throw(ExpressionTemplateError(
                    "apply_expression_template_invalid_declaration",
                    "$scope.expression_templates.$name: param names must be non-empty strings"))
            end
            ps = string(p)
            if ps in seen
                throw(ExpressionTemplateError(
                    "apply_expression_template_invalid_declaration",
                    "$scope.expression_templates.$name: param '$ps' is declared twice"))
            end
            push!(seen, ps)
        end
        body = _raw_get(decl, "body")
        if body === nothing
            throw(ExpressionTemplateError(
                "apply_expression_template_invalid_declaration",
                "$scope.expression_templates.$name: 'body' is required"))
        end
        # A body MAY reference other match-less in-scope templates via
        # apply_expression_template nodes (esm-spec §9.7.3); those are checked
        # (acyclic, depth <= MAX_TEMPLATE_EXPANSION_DEPTH) and inlined at
        # registration by `_compose_template_bodies!` — the old any-nesting
        # rejection is now cycle-only (`apply_expression_template_recursive_body`).

        # esm-spec §9.6: an optional `match` pattern turns the entry into an
        # auto-applied rewrite rule. The pattern is an Expression in which the
        # declared params are wildcards; it MUST NOT contain nested
        # apply_expression_template ops. Nontermination is NOT checked
        # statically any more — the bounded fixpoint (`MAX_REWRITE_PASSES`,
        # esm-spec §9.6.3) is the authoritative guard, so a self-reintroducing
        # rule is rejected at load time (`rewrite_rule_nonterminating`) only when
        # it actually fails to converge within the pass bound.
        match = _raw_get(decl, "match")
        if match !== nothing
            _assert_no_nested_apply(match, name, "/match")
        end

        # esm-spec §9.6.1 (0.8.0): an optional `where` block adds static
        # match-scoping constraints on the captured params. Structural
        # validation only, here; the unknown-index-set check runs at rule
        # REGISTRATION in the consuming component (where the merged
        # `index_sets` registry is in scope) — see `_registered_where`.
        whr = _raw_get(decl, "where")
        if whr !== nothing
            match === nothing && throw(ExpressionTemplateError(
                "apply_expression_template_invalid_declaration",
                "$scope.expression_templates.$name: 'where' is only admissible " *
                "alongside 'match' — constraints scope an auto-applied rewrite " *
                "rule, not a named fragment (esm-spec §9.6.1)"))
            (_is_object(whr) && !isempty(collect(pairs(whr)))) ||
                throw(ExpressionTemplateError(
                    "apply_expression_template_invalid_declaration",
                    "$scope.expression_templates.$name: 'where' must be a " *
                    "non-empty object mapping declared params to constraint objects"))
            for (p, cobj) in pairs(whr)
                ps = string(p)
                ps in seen || throw(ExpressionTemplateError(
                    "apply_expression_template_invalid_declaration",
                    "$scope.expression_templates.$name: 'where' constrains '$ps', " *
                    "which is not a declared param (esm-spec §9.6.1)"))
                _is_object(cobj) || throw(ExpressionTemplateError(
                    "apply_expression_template_invalid_declaration",
                    "$scope.expression_templates.$name: where.$ps must be a " *
                    "constraint object (v1 admits exactly the 'shape' kind)"))
                ckeys = Set{String}(string(k) for (k, _) in pairs(cobj))
                ckeys == Set(["shape"]) || throw(ExpressionTemplateError(
                    "apply_expression_template_invalid_declaration",
                    "$scope.expression_templates.$name: where.$ps carries " *
                    "constraint kind(s) $(join(sort(collect(ckeys)), ", ")); the " *
                    "v1 constraint vocabulary is exactly {shape} (esm-spec §9.6.1)"))
                shp = _raw_get(cobj, "shape")
                (_is_array(shp) && !isempty(shp)) || throw(ExpressionTemplateError(
                    "apply_expression_template_invalid_declaration",
                    "$scope.expression_templates.$name: where.$ps.shape must be a " *
                    "non-empty array of index-set names"))
                for s in shp
                    (s isa AbstractString && !isempty(string(s))) ||
                        throw(ExpressionTemplateError(
                            "apply_expression_template_invalid_declaration",
                            "$scope.expression_templates.$name: where.$ps.shape " *
                            "entries must be non-empty strings"))
                end
            end
        end
    end
end

# ---------------------------------------------------------------------------
# Substitution
# ---------------------------------------------------------------------------

"""
    _substitute(body, bindings) -> instantiated tree

Pure structural substitution of `bindings` into a template `body`: every
string node naming a bound param is replaced by its binding. The replacement
is spliced verbatim — NOT re-scanned for further params (esm-spec §9.6.3
rule 2: a replacement body is not re-matched).

STRUCTURAL SHARING: the instantiated tree shares every untouched subtree with
`body` and splices each binding BY REFERENCE (no deep copy), so repeated
references to the same template compose into a DAG whose size is linear in
the source, not exponential in nesting depth. This is a pure representation
choice — identical subtrees are observationally indistinguishable, so the
§9.6.3 fixpoint and every serialized byte are unchanged. The invariant that
makes it sound is the same one the typed IR already relies on (`OpExpr`,
types.jl): expanded trees are values — every later pass either reads them or
copies-with-changes; the one in-place mutation on the raw view
(`_narrow_arg_literals!`) is idempotent and value-local, so aliased visits
commute. The memo is keyed on node IDENTITY so shared subtrees are
substituted once.
"""
function _substitute(body, bindings::Dict{String,Any})
    isempty(bindings) && return body
    return _subst_shared(body, bindings, IdDict{Any,Any}())
end

function _subst_shared(n, bindings::Dict{String,Any}, memo::IdDict{Any,Any})
    if n isa AbstractString
        return haskey(bindings, string(n)) ? bindings[string(n)] : n
    elseif _is_array(n)
        r = get(memo, n, nothing)
        r === nothing || return r
        changed = false
        buf = Vector{Any}(undef, length(n))
        for (i, x) in enumerate(n)
            rx = _subst_shared(x, bindings, memo)
            rx === x || (changed = true)
            buf[i] = rx
        end
        res = changed ? buf : n
        memo[n] = res
        return res
    elseif _is_object(n)
        r = get(memo, n, nothing)
        r === nothing || return r
        # esm-spec §9.6.3 constraint 5 / §9.6.4 rule 4: parameter substitution
        # applies inside a nested `apply_expression_template` reference's
        # `bindings` values exactly as any other Expression position, but the
        # `name` field is NEVER a substitution site.
        op = _raw_get(n, "op")
        is_apply = op !== nothing && string(op) == APPLY_EXPRESSION_TEMPLATE_OP
        changed = false
        buf = OrderedDict{String,Any}()
        for (k, v) in pairs(n)
            ks = string(k)
            if is_apply && ks == "name"
                buf[ks] = v
                continue
            end
            rv = _subst_shared(v, bindings, memo)
            rv === v || (changed = true)
            buf[ks] = rv
        end
        res = changed ? buf : n
        memo[n] = res
        return res
    else
        return n
    end
end

function _expand_apply(node, templates::AbstractDict, scope::String)
    name_raw = _raw_get(node, "name")
    if name_raw === nothing
        throw(ExpressionTemplateError(
            "apply_expression_template_invalid_declaration",
            "$scope: apply_expression_template node missing 'name'"))
    end
    name = string(name_raw)
    decl = get(templates, name, nothing)
    if decl === nothing
        throw(ExpressionTemplateError(
            "apply_expression_template_unknown_template",
            "$scope: apply_expression_template references undeclared template '$name'"))
    end
    bindings_raw = _raw_get(node, "bindings")
    if bindings_raw === nothing || !_is_object(bindings_raw)
        throw(ExpressionTemplateError(
            "apply_expression_template_bindings_mismatch",
            "$scope: apply_expression_template '$name' missing 'bindings' object"))
    end
    decl_params_raw = _raw_get(decl, "params")
    decl_params = decl_params_raw === nothing ? String[] :
        String[string(p) for p in decl_params_raw]
    declared = Set(decl_params)
    provided = Set{String}([string(k) for (k, _) in pairs(bindings_raw)])
    for p in decl_params
        if !(p in provided)
            throw(ExpressionTemplateError(
                "apply_expression_template_bindings_mismatch",
                "$scope: apply_expression_template '$name' missing binding for param '$p'"))
        end
    end
    for p in provided
        if !(p in declared)
            throw(ExpressionTemplateError(
                "apply_expression_template_bindings_mismatch",
                "$scope: apply_expression_template '$name' supplies unknown param '$p'"))
        end
    end
    # The bindings have already been rewritten in place by the bottom-up
    # `_rewrite` pass (children are rewritten before their parent apply node is
    # expanded), so they are consumed as-is here. The template `body` is
    # instantiated by pure structural substitution and is NOT re-scanned
    # (esm-spec §9.6.3 rule 2: a replacement body is not re-matched).
    resolved = Dict{String,Any}()
    for (k, v) in pairs(bindings_raw)
        resolved[string(k)] = v
    end
    body = _raw_get(decl, "body")
    return _substitute(body, resolved)
end

"""
    _validate_apply_ref(node, templates, scope)

Call-site check for a SURVIVING (non-expanded) `apply_expression_template`
reference (esm-spec §9.6.9): the referenced `name` must resolve to an in-scope
template and `bindings` must cover its `params` exactly. Same diagnostics as
`_expand_apply` (`apply_expression_template_unknown_template`,
`apply_expression_template_bindings_mismatch`), but WITHOUT expanding — the
reference is preserved (§9.6.4 rule 1).
"""
function _validate_apply_ref(node, templates::AbstractDict, scope::String)
    name_raw = _raw_get(node, "name")
    name_raw === nothing && throw(ExpressionTemplateError(
        "apply_expression_template_invalid_declaration",
        "$scope: apply_expression_template node missing 'name'"))
    name = string(name_raw)
    decl = get(templates, name, nothing)
    decl === nothing && throw(ExpressionTemplateError(
        "apply_expression_template_unknown_template",
        "$scope: apply_expression_template references undeclared template '$name'"))
    if _raw_get(decl, "match") !== nothing
        throw(ExpressionTemplateError(
            "apply_expression_template_unknown_template",
            "$scope: apply_expression_template references '$name', a `match` " *
            "rewrite rule — only match-less templates are invocable by name (esm-spec §9.6.2)"))
    end
    bindings_raw = _raw_get(node, "bindings")
    (bindings_raw === nothing || !_is_object(bindings_raw)) && throw(ExpressionTemplateError(
        "apply_expression_template_bindings_mismatch",
        "$scope: apply_expression_template '$name' missing 'bindings' object"))
    decl_params_raw = _raw_get(decl, "params")
    decl_params = decl_params_raw === nothing ? String[] :
        String[string(p) for p in decl_params_raw]
    declared = Set(decl_params)
    provided = Set{String}([string(k) for (k, _) in pairs(bindings_raw)])
    for p in decl_params
        p in provided || throw(ExpressionTemplateError(
            "apply_expression_template_bindings_mismatch",
            "$scope: apply_expression_template '$name' missing binding for param '$p'"))
    end
    for p in provided
        p in declared || throw(ExpressionTemplateError(
            "apply_expression_template_bindings_mismatch",
            "$scope: apply_expression_template '$name' supplies unknown param '$p'"))
    end
    return
end

"""
    _check_surviving_refs(node, templates, scope)

Walk `node` and run [`_validate_apply_ref`](@ref) on every surviving
`apply_expression_template` reference it carries (esm-spec §9.6.9 call-site
checks). Descends into references' `bindings` too — a binding value MAY itself
be a surviving reference.
"""
function _check_surviving_refs(node, templates::AbstractDict, scope::String,
                               seen::IdDict{Any,Nothing}=IdDict{Any,Nothing}())
    if _is_array(node)
        haskey(seen, node) && return
        seen[node] = nothing
        for c in node
            _check_surviving_refs(c, templates, scope, seen)
        end
    elseif _is_object(node)
        haskey(seen, node) && return
        seen[node] = nothing
        op = _raw_get(node, "op")
        if op !== nothing && string(op) == APPLY_EXPRESSION_TEMPLATE_OP
            _validate_apply_ref(node, templates, scope)
        end
        for (_, v) in pairs(node)
            _check_surviving_refs(v, templates, scope, seen)
        end
    end
    return
end

# ---------------------------------------------------------------------------
# Eager-expansion carve-out: the rewrite-target op tier T (esm-spec §9.6.4
# rule 3 / RFC out-of-line-expression-templates §7.2)
# ---------------------------------------------------------------------------

"""
The rewrite-target ops explicitly named by §4.2 as the open rewrite-target
tier plus the two load-eliminated forms — the members of **T** that carry a
recognized op name. Any op that is NOT in the evaluable-core registry
(`op_registry.jl`) is ALSO in T (an open-namespace custom op no evaluator
implements); `apply_expression_template` itself is excluded — nested
references are handled through the §9.7.3 reference DAG, not by op membership.
"""
const _REWRITE_TARGET_OPS =
    Set{String}(["D", "grad", "div", "laplacian", "integral",
                 "table_lookup", "enum"])

"""
    _op_in_T(op) -> Bool

True iff op string `op` is a member of the rewrite-target tier **T**
(esm-spec §9.6.4 rule 3): one of the named rewrite-target ops, or an op with
no evaluable-core registry entry (an open-namespace custom op). The template
reference op itself is never in T.
"""
function _op_in_T(op::AbstractString)::Bool
    s = String(op)
    s == APPLY_EXPRESSION_TEMPLATE_OP && return false
    s in _REWRITE_TARGET_OPS && return true
    return _op_spec(s) === nothing
end

"""
    _direct_T_op(node) -> Bool

True iff `node` contains, ANYWHERE within it (descending through every field,
including the `bindings` of nested `apply_expression_template` nodes), an
object whose `op` is in **T** (`_op_in_T`). Does NOT follow references to other
templates — that transitive step is `_template_target_bearing`.
"""
function _direct_T_op(node, seen::IdDict{Any,Nothing}=IdDict{Any,Nothing}())::Bool
    if _is_array(node)
        haskey(seen, node) && return false
        seen[node] = nothing
        for c in node
            _direct_T_op(c, seen) && return true
        end
        return false
    elseif _is_object(node)
        haskey(seen, node) && return false
        seen[node] = nothing
        op = _raw_get(node, "op")
        if op !== nothing && _op_in_T(string(op))
            return true
        end
        for (_, v) in pairs(node)
            _direct_T_op(v, seen) && return true
        end
        return false
    else
        return false
    end
end

"""
    _template_target_bearing(templates) -> Dict{String,Bool}

Compute, for every template in `templates`, its **target-bearing** flag
(esm-spec §9.6.4 rule 3): a template is target-bearing iff its body contains an
op in **T** anywhere (including inside nested references' `bindings`), OR it
references — transitively through the §9.7.3-checked acyclic DAG — a
target-bearing template. The DAG is acyclic (checked by
`_compose_template_bodies!`), so a memoized DFS terminates.
"""
function _template_target_bearing(templates::AbstractDict{String,Any})::Dict{String,Bool}
    tb = Dict{String,Bool}()
    inprogress = Set{String}()
    function visit(name::String)::Bool
        haskey(tb, name) && return tb[name]
        # Defensive against a cycle the checker somehow missed: treat an
        # in-progress node as non-contributing (acyclicity is enforced earlier).
        name in inprogress && return false
        decl = get(templates, name, nothing)
        decl === nothing && (tb[name] = false; return false)
        push!(inprogress, name)
        body = _raw_get(decl, "body")
        res = body !== nothing && _direct_T_op(body)
        if !res
            for r in _collect_apply_names!(String[], body)
                haskey(templates, r) || continue
                if visit(r)
                    res = true
                    break
                end
            end
        end
        delete!(inprogress, name)
        tb[name] = res
        return res
    end
    for name in keys(templates)
        visit(name)
    end
    return tb
end

"""
    _ref_is_eager(node, target_bearing) -> Bool

Whether an `apply_expression_template` `node` is **eager** (esm-spec §9.6.4
rule 3): its referenced template is target-bearing, OR any of its `bindings`
values contains an op in **T**. (After innermost-first eager expansion of the
bindings, a "nested eager reference" always manifests as a T-op in the
bindings, so this predicate subsumes that clause — see `_expand_eager`.)
"""
function _ref_is_eager(node, target_bearing::AbstractDict{String,Bool})::Bool
    name_raw = _raw_get(node, "name")
    name_raw === nothing && return false
    get(target_bearing, string(name_raw), false) && return true
    b = _raw_get(node, "bindings")
    b === nothing && return false
    return _direct_T_op(b)
end

"""
    _expand_eager(node, named, target_bearing) -> node

The eager-expansion pre-pass (esm-spec §9.6.4 rule 3): expand — by pure
substitution, innermost-first — every EAGER `apply_expression_template` node,
and only eager nodes. Non-eager (surviving) references are returned intact.
Consumes no `MAX_REWRITE_PASSES` budget (it is a separate pre-pass). Sharing
is preserved via an identity memo.
"""
function _expand_eager(node, named::AbstractDict, target_bearing::AbstractDict{String,Bool},
                       scope::String, memo::IdDict{Any,Any}=IdDict{Any,Any}())
    if _is_object(node)
        r = get(memo, node, _JSON_DESCEND)
        r === _JSON_DESCEND || return r
        op = _raw_get(node, "op")
        op_str = op === nothing ? "" : string(op)
        local res
        if op_str == APPLY_EXPRESSION_TEMPLATE_OP
            # Innermost-first: expand eager references inside the bindings first.
            b = _raw_get(node, "bindings")
            newnode = node
            if b !== nothing && _is_object(b)
                nb = OrderedDict{String,Any}()
                changed = false
                for (k, v) in pairs(b)
                    rv = _expand_eager(v, named, target_bearing, scope, memo)
                    rv === v || (changed = true)
                    nb[string(k)] = rv
                end
                if changed
                    newnode = OrderedDict{String,Any}()
                    for (k, v) in pairs(node)
                        newnode[string(k)] = (string(k) == "bindings") ? nb : v
                    end
                end
            end
            if _ref_is_eager(newnode, target_bearing)
                body = _expand_apply(newnode, named, scope)
                res = _expand_eager(body, named, target_bearing, scope, memo)
            else
                res = newnode
            end
        else
            changed = false
            buf = OrderedDict{String,Any}()
            for (k, v) in pairs(node)
                rv = _expand_eager(v, named, target_bearing, scope, memo)
                rv === v || (changed = true)
                buf[string(k)] = rv
            end
            res = changed ? buf : node
        end
        memo[node] = res
        return res
    elseif _is_array(node)
        r = get(memo, node, _JSON_DESCEND)
        r === _JSON_DESCEND || return r
        changed = false
        buf = Vector{Any}(undef, length(node))
        for (i, v) in enumerate(node)
            rv = _expand_eager(v, named, target_bearing, scope, memo)
            rv === v || (changed = true)
            buf[i] = rv
        end
        res = changed ? buf : node
        memo[node] = res
        return res
    else
        return node
    end
end

# ---------------------------------------------------------------------------
# Full expansion — `Expand` (esm-spec §9.6.4 rule 2)
# ---------------------------------------------------------------------------

"""
    _expand_all(node, named, scope) -> node

Fully expand EVERY `apply_expression_template` node in `node` by pure
substitution to a fixpoint (innermost-first: bindings are expanded before the
body is instantiated, and the instantiated body is re-expanded). This is the
per-registry kernel of the public [`Expand`](@ref) function (esm-spec §9.6.4
rule 2). Deterministic and sharing-preserving.
"""
function _expand_all(node, named::AbstractDict, scope::String,
                     memo::IdDict{Any,Any}=IdDict{Any,Any}())
    if _is_object(node)
        r = get(memo, node, _JSON_DESCEND)
        r === _JSON_DESCEND || return r
        op = _raw_get(node, "op")
        op_str = op === nothing ? "" : string(op)
        local res
        if op_str == APPLY_EXPRESSION_TEMPLATE_OP
            b = _raw_get(node, "bindings")
            newnode = node
            if b !== nothing && _is_object(b)
                nb = OrderedDict{String,Any}()
                changed = false
                for (k, v) in pairs(b)
                    rv = _expand_all(v, named, scope, memo)
                    rv === v || (changed = true)
                    nb[string(k)] = rv
                end
                if changed
                    newnode = OrderedDict{String,Any}()
                    for (k, v) in pairs(node)
                        newnode[string(k)] = (string(k) == "bindings") ? nb : v
                    end
                end
            end
            body = _expand_apply(newnode, named, scope)
            res = _expand_all(body, named, scope, memo)
        else
            changed = false
            buf = OrderedDict{String,Any}()
            for (k, v) in pairs(node)
                rv = _expand_all(v, named, scope, memo)
                rv === v || (changed = true)
                buf[string(k)] = rv
            end
            res = changed ? buf : node
        end
        memo[node] = res
        return res
    elseif _is_array(node)
        r = get(memo, node, _JSON_DESCEND)
        r === _JSON_DESCEND || return r
        changed = false
        buf = Vector{Any}(undef, length(node))
        for (i, v) in enumerate(node)
            rv = _expand_all(v, named, scope, memo)
            rv === v || (changed = true)
            buf[i] = rv
        end
        res = changed ? buf : node
        memo[node] = res
        return res
    else
        return node
    end
end

# ---------------------------------------------------------------------------
# Structural pattern matching (auto-applied `match` rewrite rules, esm-spec §9.6)
# ---------------------------------------------------------------------------

# Structural equality over the normalized JSON view (Dict / Vector / scalar /
# String). Used to enforce that a metavariable bound twice in the same pattern
# binds to identical sub-trees.
function _json_equal(a, b)::Bool
    # Pointer-identical nodes are structurally equal by definition — and with
    # structural sharing (see `_substitute`) this fast path is what keeps a
    # twice-bound metavariable check linear on a shared DAG.
    a === b && !(a isa Number) && return true
    if a isa Bool || b isa Bool
        return (a isa Bool) && (b isa Bool) && a == b
    elseif a isa Number
        return (b isa Number) && a == b
    elseif a isa AbstractString
        return (b isa AbstractString) && string(a) == string(b)
    elseif _is_array(a)
        _is_array(b) || return false
        length(a) == length(b) || return false
        for (x, y) in zip(a, b)
            _json_equal(x, y) || return false
        end
        return true
    elseif _is_object(a)
        _is_object(b) || return false
        ka = Set(string(k) for (k, _) in pairs(a))
        kb = Set(string(k) for (k, _) in pairs(b))
        ka == kb || return false
        for k in ka
            _json_equal(_raw_get(a, k), _raw_get(b, k)) || return false
        end
        return true
    else
        return a === b || a == b
    end
end

"""
    _match_pattern(pattern, node, params, bindings) -> Bool

Structurally match `pattern` (an Expression with the declared `params` as
wildcards) against `node`, accumulating metavariable bindings in `bindings`.
A param string in an operand / `args` position binds to the matched sub-AST; a
param string in a scalar field (`dim`, `side`, …) binds to the matched literal
(esm-spec §9.6) — the same rule, since a bound param simply takes whatever the
corresponding node value is. Non-param strings, numbers, and booleans must
match literally; arrays match elementwise (same length); objects match when
every pattern key is present on `node` and matches (extra `node` keys are
allowed, so a pattern constrains only the fields it names).
"""
function _match_pattern(pattern, node, params::Set{String}, bindings::Dict{String,Any})::Bool
    if pattern isa Bool
        return (node isa Bool) && node == pattern
    elseif pattern isa AbstractString
        s = string(pattern)
        if s in params
            if haskey(bindings, s)
                return _json_equal(bindings[s], node)
            end
            bindings[s] = node
            return true
        end
        return (node isa AbstractString) && string(node) == s
    elseif pattern isa Number
        return (node isa Number) && !(node isa Bool) && node == pattern
    elseif _is_array(pattern)
        _is_array(node) || return false
        length(pattern) == length(node) || return false
        for (pp, nn) in zip(pattern, node)
            _match_pattern(pp, nn, params, bindings) || return false
        end
        return true
    elseif _is_object(pattern)
        _is_object(node) || return false
        for (k, pv) in pairs(pattern)
            ks = string(k)
            nv = _raw_get(node, ks)
            (nv === nothing && !_raw_haskey(node, ks)) && return false
            _match_pattern(pv, nv, params, bindings) || return false
        end
        return true
    else
        # nothing / null literal in the pattern.
        return pattern === node
    end
end

# ---------------------------------------------------------------------------
# Static match-scoping constraints (`where`, esm-spec §9.6.1;
# docs/rfcs/match-pattern-scoping-constraints.md)
# ---------------------------------------------------------------------------

"""
    _component_shape_env(comp) -> Dict{String,Vector{String}}

The static shape environment of one component: every declared variable name
mapped to its declared `shape` (ordered index-set names). This is the ONLY
information a `where` constraint may consult (esm-spec §9.6.1) — declared
shapes at lowering time, never runtime values — so constraint evaluation is
fully static and the §9.6.3 determinism contract is untouched. Variables with
no `shape` (scalars) are absent from the environment, as are species /
parameters of reaction systems (which carry no `shape` field): a
shape-constrained rule can only fire on a declared, shaped model variable.
"""
function _component_shape_env(comp)::Dict{String,Vector{String}}
    env = Dict{String,Vector{String}}()
    vars = _raw_get(comp, "variables")
    (vars !== nothing && _is_object(vars)) || return env
    for (vn, vd) in pairs(vars)
        _is_object(vd) || continue
        shp = _raw_get(vd, "shape")
        (shp !== nothing && _is_array(shp)) || continue
        all(s -> s isa AbstractString, shp) || continue
        env[string(vn)] = String[string(s) for s in shp]
    end
    return env
end

const _EMPTY_SHAPE_ENV = Dict{String,Vector{String}}()

"""
    _where_satisfied(where_c, bindings, shape_env) -> Bool

Evaluate a registered `where` constraint map (param → required shape) against
the bindings produced by a successful structural match (esm-spec §9.6.1). A
constraint on param `p` holds iff `bindings[p]` is a BARE variable-reference
string naming an entry of `shape_env` whose declared shape equals the required
list exactly (same names, same order). Everything else — a compound sub-AST, a
numeric literal, a scalar-field-bound literal, a scoped (`System.var`)
reference, an undeclared name, a scalar variable, or a param that never bound
— fails the constraint. The judgment is deliberately syntactic and
conservative: no shape inference over compound expressions, so eligibility
depends only on declarations and is byte-identical across bindings.
"""
function _where_satisfied(where_c, bindings::Dict{String,Any},
                          shape_env::Dict{String,Vector{String}})::Bool
    where_c === nothing && return true
    for (p, req) in where_c
        b = get(bindings, p, nothing)
        b isa AbstractString || return false
        shp = get(shape_env, string(b), nothing)
        shp === nothing && return false
        shp == req || return false
    end
    return true
end

"""
    _registered_where(decl, iset_names, scope, tname) -> Union{Nothing,Dict}

Normalize a template's `where` block into the registered constraint map
(param → `Vector{String}` required shape), checking every referenced
index-set name against the CONSUMING document's merged `index_sets` registry
(`iset_names`). An unknown name is `template_constraint_unknown_index_set`
(esm-spec §9.6.6) — raised here, at rule registration in the consuming
component, not when a library file is loaded standalone: constraints name
index sets as spelled in the consuming document's registry (post-§9.7.5
merge, composing with import-edge index-set renaming).
"""
function _registered_where(decl, iset_names::Set{String}, scope::String,
                           tname::String)
    whr = _raw_get(decl, "where")
    whr === nothing && return nothing
    out = Dict{String,Vector{String}}()
    for (p, cobj) in pairs(whr)
        shp = _raw_get(cobj, "shape")
        req = String[string(s) for s in shp]
        for s in req
            s in iset_names || throw(ExpressionTemplateError(
                "template_constraint_unknown_index_set",
                "$scope.expression_templates.$tname: where.$(string(p)).shape " *
                "names index set '$s', which the consuming document's " *
                "index_sets registry does not declare (esm-spec §9.6.1/§9.6.6)"))
        end
        out[string(p)] = req
    end
    return out
end

"""
Maximum number of productive rewrite passes before a file is rejected as
non-converging (esm-spec §9.6.3, diagnostic `rewrite_rule_nonterminating`).
Pinned identically across all bindings so the accept/reject decision — and the
resulting fixpoint — is byte-identical everywhere.
"""
const MAX_REWRITE_PASSES = 64

"""
    _rule_priority(decl) -> Int

The `priority` of a `match` rule (esm-spec §9.6.3): higher fires first, ties
break by declaration order. Absent ⇒ `0`. The schema constrains `priority` to an
integer; any numeric encoding is coerced defensively.
"""
function _rule_priority(decl)::Int
    p = _raw_get(decl, "priority")
    p === nothing && return 0
    p isa Bool && return 0
    p isa Integer && return Int(p)
    p isa Number && return round(Int, p)
    return 0
end

"""
    _RewriteRule

One registered auto-applied `match` rewrite rule (esm-spec §9.6.3), as consumed
by [`_rewrite_pass`](@ref). `priority` and `decl_index` (1-based declaration
position) carry the deterministic selection order — highest `priority` first,
ties broken by earliest declaration. `where_clause` is the normalized static
constraint map produced by [`_registered_where`](@ref) (`nothing` when the
rule is unconstrained).
"""
struct _RewriteRule
    name::String
    pattern::Any
    params::Set{String}
    body::Any
    priority::Int
    decl_index::Int
    where_clause::Union{Nothing,Dict{String,Vector{String}}}
end

"""
    _ComponentRegistry

One component's rewrite registry, captured by
[`lower_expression_templates`](@ref): `named` — every template declaration
keyed by name, consulted by `apply_expression_template` (order-independent);
`match_rules` — the auto-applied rules pre-sorted into §9.6.3 selection order;
`shape_env` — the component's static shape environment
([`_component_shape_env`](@ref)) for `where` constraint evaluation. This is
everything needed to rewrite a coupling `variable_map` transform against the
RECEIVING component (esm-spec §10.4).
"""
struct _ComponentRegistry
    named::Dict{String,Any}
    match_rules::Vector{_RewriteRule}
    shape_env::Dict{String,Vector{String}}
    target_bearing::Dict{String,Bool}
end

# Back-compat constructor for call sites that predate the target-bearing field.
_ComponentRegistry(named, match_rules, shape_env) =
    _ComponentRegistry(named, match_rules, shape_env,
                       _template_target_bearing(named))

"""
    _rewrite_pass(node, named, sorted_rules, scope, last, shape_env) -> (new_node, changed)

One pre-order (outermost-first) rewrite pass over `node` (esm-spec §9.6.3),
expressed as an identity-memoized, sharing-preserving recursion
([`_rewrite_node`](@ref)). At each object node the engine first tries to fire
a rule AT the node before descending:

1. an `apply_expression_template` op is expanded (`_expand_apply`), OR
2. the first rule in `sorted_rules` (pre-sorted highest-`priority`-first, ties by
   declaration order) whose `match` pattern structurally matches the node AND
   whose `where` constraints (if any) are satisfied by the resulting bindings
   fires. Constraint filtering is part of match ELIGIBILITY (esm-spec §9.6.3
   constraint 2): a constraint-excluded rule is treated exactly like a
   non-matching rule at this node, so the scan proceeds to the next candidate
   in priority / declaration order.

A fired rule's body replaces the node and the walk does NOT descend into that
freshly-produced body during this pass (it is revisited next pass) — the
replace-verbatim contract. If nothing fires, the walk descends into the
node's children. `changed` is `true` iff any rewrite occurred in this
subtree; `last` (a `Ref{String}`) records the op of the most recent rewrite,
for the non-convergence diagnostic. `shape_env` is the enclosing component's
static shape environment (`_component_shape_env`).
"""
function _rewrite_pass(node, named::Dict{String,Any},
                       sorted_rules::Vector{_RewriteRule},
                       scope::String, last::Ref{String},
                       shape_env::Dict{String,Vector{String}},
                       target_bearing::Dict{String,Bool})
    changed = Ref(false)
    # Identity-memoized recursion (not `_map_json`): the rewrite of a node is a
    # pure function of the node itself (pattern matching is structural, the
    # registries and `shape_env` are pass-constant), so a subtree shared under
    # many parents is rewritten ONCE and the shared result respliced —
    # preserving the DAG `_substitute` builds instead of exploding it back
    # into a tree, and keeping pass cost linear in UNIQUE nodes. Unchanged
    # subtrees are returned by identity for the same reason.
    memo = IdDict{Any,Any}()
    out = _rewrite_node(node, named, sorted_rules, scope, last, shape_env,
                        target_bearing, memo, changed)
    return (out, changed[])
end

function _rewrite_node(n, named::Dict{String,Any},
                       sorted_rules::Vector{_RewriteRule},
                       scope::String, last::Ref{String},
                       shape_env::Dict{String,Vector{String}},
                       target_bearing::Dict{String,Bool},
                       memo::IdDict{Any,Any}, changed::Base.RefValue{Bool})
    if _is_object(n)
        r = get(memo, n, _JSON_DESCEND)
        r === _JSON_DESCEND || return r
        op = _raw_get(n, "op")
        op_str = op === nothing ? "" : string(op)
        local res
        # (1) Outermost-first: fire a rule AT this node before descending.
        if op_str == APPLY_EXPRESSION_TEMPLATE_OP
            # esm-spec §9.6.4 rule 4 (Option B): the engine treats a surviving
            # (non-eager) reference as a LEAF — it does not descend into its
            # `bindings`, no rule fires inside it, and it survives the fixpoint.
            # Eager references were already removed by the pre-pass
            # (`_expand_eager`); a defensive check keeps any eager node that a
            # caller passed in unexpanded correct.
            if _ref_is_eager(n, target_bearing)
                last[] = APPLY_EXPRESSION_TEMPLATE_OP
                changed[] = true
                res = _expand_eager(n, named, target_bearing, scope)
            else
                res = n
            end
        else
            fired = false
            for rule in sorted_rules
                bindings = Dict{String,Any}()
                if _match_pattern(rule.pattern, n, rule.params, bindings) &&
                   _where_satisfied(rule.where_clause, bindings, shape_env)
                    last[] = op_str
                    changed[] = true
                    # Instantiate by pure substitution (through nested
                    # references' `bindings`; `name` is never a site). An eager
                    # reference introduced by the instantiation expands as part
                    # of the same rewrite (§9.6.4 rule 4) via the pre-pass.
                    body = _substitute(rule.body, bindings)
                    res = _expand_eager(body, named, target_bearing, scope)
                    fired = true
                    break
                end
            end
            if !fired
                # (2) No rule fired here — descend into children,
                # identity-preserving.
                kids_changed = false
                buf = OrderedDict{String,Any}()
                for (k, v) in pairs(n)
                    rv = _rewrite_node(v, named, sorted_rules, scope, last,
                                       shape_env, target_bearing, memo, changed)
                    rv === v || (kids_changed = true)
                    buf[string(k)] = rv
                end
                res = kids_changed ? buf : n
            end
        end
        memo[n] = res
        return res
    elseif _is_array(n)
        r = get(memo, n, _JSON_DESCEND)
        r === _JSON_DESCEND || return r
        kids_changed = false
        buf = Vector{Any}(undef, length(n))
        for (i, v) in enumerate(n)
            rv = _rewrite_node(v, named, sorted_rules, scope, last,
                               shape_env, target_bearing, memo, changed)
            rv === v || (kids_changed = true)
            buf[i] = rv
        end
        res = kids_changed ? buf : n
        memo[n] = res
        return res
    else
        return n
    end
end

"""
    _rewrite_to_fixpoint(node, named, sorted_rules, scope) -> rewritten node

Drive `_rewrite_pass` to a fixpoint (esm-spec §9.6.3): repeat pre-order passes
until a pass performs zero rewrites, or reject the file with
`rewrite_rule_nonterminating` once `MAX_REWRITE_PASSES` productive passes have
run without converging. This bound — not a static check — is the authoritative
termination guard, so a self-reintroducing rule fails to converge rather than
being flagged up front.
"""
function _rewrite_to_fixpoint(node, named::Dict{String,Any},
                              sorted_rules::Vector{_RewriteRule}, scope::String,
                              shape_env::Dict{String,Vector{String}}=_EMPTY_SHAPE_ENV,
                              target_bearing::Dict{String,Bool}=_template_target_bearing(named))
    last = Ref{String}("")
    # esm-spec §9.6.4 rule 3 / §7.1 step 5: the eager-expansion pre-pass runs
    # BEFORE the fixpoint and consumes no `MAX_REWRITE_PASSES` budget. It
    # removes every eager reference (target-bearing, or T-op in bindings) so the
    # fixpoint and the later `unlowered_operator` gate walk a tree in which no
    # rewrite-target op hides inside a surviving reference.
    current = _expand_eager(node, named, target_bearing, scope)
    for _pass in 1:MAX_REWRITE_PASSES
        current, changed = _rewrite_pass(current, named, sorted_rules, scope, last,
                                         shape_env, target_bearing)
        changed || return current   # fixpoint reached
    end
    throw(ExpressionTemplateError(
        "rewrite_rule_nonterminating",
        "$scope: expression-template rewriting did not converge within " *
        "MAX_REWRITE_PASSES=$MAX_REWRITE_PASSES passes (last rewritten op " *
        "'$(last[])'). A `match` rule likely re-introduces its own pattern " *
        "(esm-spec §9.6.3)."))
end

# ---------------------------------------------------------------------------
# Scan utilities
# ---------------------------------------------------------------------------

function _find_apply_paths!(hits::Vector{String}, x, path::String)
    if _is_array(x)
        for (i, child) in enumerate(x)
            _find_apply_paths!(hits, child, "$path/$(i-1)")
        end
        return
    end
    if _is_object(x)
        op = _raw_get(x, "op")
        op_str = op === nothing ? "" : string(op)
        if op_str == APPLY_EXPRESSION_TEMPLATE_OP
            push!(hits, path)
        end
        for (k, v) in pairs(x)
            _find_apply_paths!(hits, v, "$path/$(string(k))")
        end
    end
end

function _has_apply_op(x)
    found = false
    # Visit each unique container once (`seen`): on a structurally-shared
    # expanded tree the same subtree hangs under exponentially many paths.
    seen = IdDict{Any,Nothing}()
    _walk_json(x) do _, n
        found && return false   # already answered — prune the rest
        if _is_object(n) || _is_array(n)
            haskey(seen, n) && return false
            seen[n] = nothing
        end
        if _is_object(n)
            op = _raw_get(n, "op")
            if op !== nothing && string(op) == APPLY_EXPRESSION_TEMPLATE_OP
                found = true
                return false
            end
        end
        return true
    end
    return found
end

"""
    _has_template_machinery(raw_data) -> Bool

True if `raw_data` either declares any non-empty `expression_templates`
block under `models`/`reaction_systems`, or contains any
`apply_expression_template` op anywhere in the tree. Used by
[`lower_expression_templates`](@ref) to short-circuit on files that need
no template expansion (and so should not be wrapped in `JSONLikeDict`).
"""
function _has_template_machinery(raw_data)
    raw_data === nothing && return false
    _is_object(raw_data) || return false
    for compkind in ("models", "reaction_systems")
        comps = _raw_get(raw_data, compkind)
        comps === nothing && continue
        _is_object(comps) || continue
        for (_, comp) in pairs(comps)
            _is_object(comp) || continue
            tpl = _raw_get(comp, "expression_templates")
            if _is_object(tpl) && length(collect(pairs(tpl))) > 0
                return true
            end
        end
    end
    return _has_apply_op(raw_data)
end

# ---------------------------------------------------------------------------
# Post-expansion validation (esm-spec §9.6.4)
# ---------------------------------------------------------------------------

"""
Geometry-kernel ops whose `manifold` scalar field is restricted to the closed
set [`GEOMETRY_MANIFOLD_VALUES`](@ref) (CONFORMANCE_SPEC §5.8.4).
"""
const GEOMETRY_MANIFOLD_OPS = ("intersect_polygon", "polygon_intersection_area")

"""
The closed manifold registry. The document schema admits any string in the
`manifold` position so a template `body` can carry a parameter name there
(esm-spec §9.6.1 scalar-field substitution site); the closed set is enforced
here, on the EXPANDED form, per esm-spec §9.6.4.
"""
const GEOMETRY_MANIFOLD_VALUES = ("planar", "spherical", "geodesic")

"""
    _validate_geometry_manifolds(x, path="")

Post-expansion validator (esm-spec §9.6.4): every `intersect_polygon` /
`polygon_intersection_area` node OUTSIDE an `expression_templates` block must
carry a `manifold` drawn from the closed set {planar, spherical, geodesic}.
Template bodies are skipped — a parameter name in the `manifold` position of a
`body` is a legal substitution site (esm-spec §9.6.1); by the time this
validator runs on a loaded document, every such site has been substituted, so
an out-of-set value here is a real defect (e.g. a template invocation binding
the manifold parameter to a non-member literal). Throws
[`ExpressionTemplateError`](@ref) with code `geometry_manifold_invalid`.
"""
function _validate_geometry_manifolds(x, path::String="",
                                       seen::IdDict{Any,Nothing}=IdDict{Any,Nothing}())
    if _is_array(x)
        haskey(seen, x) && return
        seen[x] = nothing
        for (i, child) in enumerate(x)
            _validate_geometry_manifolds(child, "$path/$(i-1)", seen)
        end
        return
    end
    _is_object(x) || return
    haskey(seen, x) && return
    seen[x] = nothing
    op = _raw_get(x, "op")
    op_str = op === nothing ? "" : string(op)
    if op_str in GEOMETRY_MANIFOLD_OPS
        m = _raw_get(x, "manifold")
        if m !== nothing && !(m isa AbstractString && string(m) in GEOMETRY_MANIFOLD_VALUES)
            throw(ExpressionTemplateError(
                "geometry_manifold_invalid",
                "$path: `$op_str` carries manifold $(repr(m)), not a member of the " *
                "closed set {planar, spherical, geodesic}. The manifold enum is " *
                "enforced on the expanded form (esm-spec §9.6.4; CONFORMANCE_SPEC " *
                "§5.8.4) — a template parameter substituted into this scalar field " *
                "must be bound to one of the closed-set literals."))
        end
    end
    for (k, v) in pairs(x)
        ks = string(k)
        # Template bodies/matches are pre-substitution trees; params may
        # legally occupy the manifold position there (esm-spec §9.6.1).
        ks == "expression_templates" && continue
        _validate_geometry_manifolds(v, "$path/$ks", seen)
    end
    return
end

"""
    _validate_makearray_regions(x, path="")

Post-expansion validator (esm-spec §4.3.2 / §9.6.4): every `makearray` region
bound pair `[start, stop]` on the expanded, metaparameter-folded tree must
satisfy `stop >= start - 1`. `stop == start - 1` is the canonical EMPTY bound —
the region covers no elements and contributes nothing (the spelling an interior
region like `[2, N-1]` folds to at the minimum admissible extent `N = 2`).
`stop < start - 1` is INVERTED and rejected with `makearray_region_inverted`:
it is almost always an authoring bug (an interior stencil instantiated below
its minimum extent, e.g. `[2, N-1]` at `N = 1` folding to `[2, 0]`), and
silently treating it as empty would hide the defect. Template bodies are
skipped — pre-substitution bounds may legally carry metaparameter names there;
only concrete integer pairs are checked (a fully-folded document tree carries
nothing else in bound position). Throws [`ExpressionTemplateError`](@ref) with
code `makearray_region_inverted`.
"""
function _validate_makearray_regions(x, path::String="",
                                     seen::IdDict{Any,Nothing}=IdDict{Any,Nothing}())
    if _is_array(x)
        haskey(seen, x) && return
        seen[x] = nothing
        for (i, child) in enumerate(x)
            _validate_makearray_regions(child, "$path/$(i-1)", seen)
        end
        return
    end
    _is_object(x) || return
    haskey(seen, x) && return
    seen[x] = nothing
    op = _raw_get(x, "op")
    op_str = op === nothing ? "" : string(op)
    if op_str == "makearray"
        regions = _raw_get(x, "regions")
        if regions !== nothing && _is_array(regions)
            for (ri, region) in enumerate(regions)
                _is_array(region) || continue
                for (di, bounds) in enumerate(region)
                    (_is_array(bounds) && length(bounds) == 2) || continue
                    lo, hi = bounds[1], bounds[2]
                    (lo isa Integer && !(lo isa Bool) &&
                     hi isa Integer && !(hi isa Bool)) || continue
                    if hi < lo - 1
                        throw(ExpressionTemplateError(
                            "makearray_region_inverted",
                            "$path: makearray regions[$(ri-1)] dimension $(di-1) " *
                            "bound pair [$lo, $hi] is inverted (stop < start - 1). " *
                            "An empty bound is spelled [start, start-1] and " *
                            "contributes no elements (esm-spec §4.3.2); a further-" *
                            "inverted pair is an authoring error — e.g. an interior " *
                            "stencil region [2, N-1] instantiated at N below the " *
                            "scheme's minimum extent (§9.6.8)."))
                    end
                end
            end
        end
    end
    for (k, v) in pairs(x)
        ks = string(k)
        # Template bodies/matches are pre-substitution trees; bounds may
        # legally carry metaparameter names or fold later (esm-spec §9.7.6).
        ks == "expression_templates" && continue
        _validate_makearray_regions(v, "$path/$ks", seen)
    end
    return
end

# ---------------------------------------------------------------------------
# Reference-aware validation discharge (esm-spec §9.6.9, Option B)
# ---------------------------------------------------------------------------

"""
    _validate_makearray_regions_in_registries(registries)

esm-spec §9.6.9: `makearray_region_inverted` is discharged at registration on
the composed, metaparameter-folded template bodies — region bounds cannot carry
template params (they are metaparameter expressions, §9.7.6), so the check is
instantiation-independent. Every retained template body (match and match-less)
is validated directly; its region bounds are already concrete integers.
"""
function _validate_makearray_regions_in_registries(registries)
    for (_, reg) in registries
        for (tname, decl) in reg.named
            body = _raw_get(decl, "body")
            body === nothing && continue
            _validate_makearray_regions(body,
                "expression_templates.$tname/body")
        end
    end
    return
end

"""
    _template_manifold_bearing(named) -> Dict{String,Bool}

Which templates can produce a geometry-kernel node (`GEOMETRY_MANIFOLD_OPS`) —
directly in the body or transitively through a referenced template. Only
references to these templates need per-instantiation manifold validation
(§9.6.9); everything else is skipped, so a geometry-free document pays nothing.
"""
function _template_manifold_bearing(named::AbstractDict)::Dict{String,Bool}
    direct(node, seen=IdDict{Any,Nothing}()) = begin
        if _is_array(node)
            haskey(seen, node) && return false
            seen[node] = nothing
            any(c -> direct(c, seen), node)
        elseif _is_object(node)
            haskey(seen, node) && return false
            seen[node] = nothing
            op = _raw_get(node, "op")
            (op !== nothing && string(op) in GEOMETRY_MANIFOLD_OPS) && return true
            any(kv -> direct(kv[2], seen), collect(pairs(node)))
        else
            false
        end
    end
    mb = Dict{String,Bool}()
    inprog = Set{String}()
    function visit(name)
        haskey(mb, name) && return mb[name]
        name in inprog && return false
        decl = get(named, name, nothing)
        decl === nothing && (mb[name] = false; return false)
        push!(inprog, name)
        body = _raw_get(decl, "body")
        res = body !== nothing && direct(body)
        if !res
            for r in _collect_apply_names!(String[], body)
                haskey(named, r) && visit(r) && (res = true; break)
            end
        end
        delete!(inprog, name)
        mb[name] = res
        return res
    end
    for n in keys(named); visit(n); end
    return mb
end

"""
    _validate_geometry_manifolds_refaware(root, registries)

esm-spec §9.6.9: `geometry_manifold_invalid` is discharged per-instantiation (a
`manifold` may be a template param), memoized. Direct geometry nodes in the
reference-preserving tree are checked as before; every surviving
`apply_expression_template` reference whose template can produce a geometry
kernel is additionally expanded ONCE (memoized) and its expansion validated, so
an inadmissible manifold bound at a call site is caught. The diagnostic reports
(call-site path, template name, intra-body path).
"""
function _validate_geometry_manifolds_refaware(root, registries)
    # Direct nodes on the reference-preserving tree (skips template blocks and
    # does not see manifold params hidden behind references).
    _validate_geometry_manifolds(root)
    for compkind in ("models", "reaction_systems")
        comps = get(root, compkind, nothing)
        comps === nothing && continue
        _is_object(comps) || continue
        for (cname, comp) in pairs(comps)
            _is_object(comp) || continue
            reg = get(registries, string(cname), nothing)
            reg === nothing && continue
            manifold_bearing = _template_manifold_bearing(reg.named)
            any(values(manifold_bearing)) || continue   # no geometry: nothing to check
            memo = IdDict{Any,Nothing}()
            for (k, v) in pairs(comp)
                string(k) == "expression_templates" && continue
                _validate_manifolds_in_refs(v, reg.named, manifold_bearing,
                    "$compkind.$(string(cname)).$(string(k))", memo)
            end
        end
    end
    return
end

function _validate_manifolds_in_refs(node, named::AbstractDict,
                                     manifold_bearing::Dict{String,Bool},
                                     path::String,
                                     memo::IdDict{Any,Nothing})
    if _is_array(node)
        haskey(memo, node) && return
        memo[node] = nothing
        for (i, c) in enumerate(node)
            _validate_manifolds_in_refs(c, named, manifold_bearing, "$path/$(i-1)", memo)
        end
    elseif _is_object(node)
        haskey(memo, node) && return
        memo[node] = nothing
        op = _raw_get(node, "op")
        name = op !== nothing && string(op) == APPLY_EXPRESSION_TEMPLATE_OP ?
            string(something(_raw_get(node, "name"), "")) : ""
        # Per-instantiation manifold check (§9.6.9): expand ONLY references whose
        # template can produce a geometry-kernel node; everything else is cheap.
        if name != "" && get(manifold_bearing, name, false)
            expansion = try
                _expand_all(node, named, path)
            catch
                nothing
            end
            if expansion !== nothing
                try
                    _validate_geometry_manifolds(expansion)
                catch e
                    e isa ExpressionTemplateError &&
                        e.code == "geometry_manifold_invalid" || rethrow()
                    throw(ExpressionTemplateError("geometry_manifold_invalid",
                        "$path: instantiation of template '$name' — $(e.message) " *
                        "(esm-spec §9.6.9; per-instantiation manifold check)"))
                end
            end
        end
        for (k, v) in pairs(node)
            _validate_manifolds_in_refs(v, named, manifold_bearing, "$path/$(string(k))", memo)
        end
    end
    return
end

# ---------------------------------------------------------------------------
# Pre-version-0.4.0 rejection
# ---------------------------------------------------------------------------

"""
    reject_expression_templates_pre_v04(raw_data)

Reject `expression_templates` blocks and `apply_expression_template` ops in
files declaring `esm` < 0.4.0. Mirrors the equivalent TS / Python / Rust /
Go checks for cross-binding-uniform diagnostics.
"""
function reject_expression_templates_pre_v04(raw_data)
    raw_data === nothing && return
    !_is_object(raw_data) && return
    esm_raw = _raw_get(raw_data, "esm")
    esm_raw === nothing && return
    m = match(r"^(\d+)\.(\d+)\.(\d+)$", string(esm_raw))
    m === nothing && return
    major = parse(Int, m.captures[1])
    minor = parse(Int, m.captures[2])
    is_pre_v04 = (major == 0 && minor < 4)
    !is_pre_v04 && return

    offences = String[]
    for compkind in ("models", "reaction_systems")
        comps = _raw_get(raw_data, compkind)
        comps === nothing && continue
        _is_object(comps) || continue
        for (cname, comp) in pairs(comps)
            _is_object(comp) || continue
            if _raw_haskey(comp, "expression_templates")
                push!(offences, "/$compkind/$(string(cname))/expression_templates")
            end
        end
    end
    _find_apply_paths!(offences, raw_data, "")

    if !isempty(offences)
        throw(ExpressionTemplateError(
            "apply_expression_template_version_too_old",
            "expression_templates / apply_expression_template require esm >= 0.4.0; file declares $(string(esm_raw)). Offending paths: $(join(offences, ", "))"))
    end
end

# ---------------------------------------------------------------------------
# Canonical arithmetic-operand literal narrowing (CONFORMANCE_SPEC §5.5.3.1)
# ---------------------------------------------------------------------------

"""
    _int64_narrowable(v) -> Bool

True iff `v` is a `Float64` whose value is an integer exactly representable in
`Int64` (CONFORMANCE_SPEC §5.5.3.1 rule 1 / rule 3). This is the SAME predicate
`parse_expression` applies at the AST-literal boundary (`parse.jl`), so the two
narrowing sites stay uniform. Booleans are excluded (`Bool <: Integer`).
"""
_int64_narrowable(v) =
    (v isa AbstractFloat) && !(v isa Bool) && isfinite(v) && isinteger(v) &&
    typemin(Int64) <= v <= typemax(Int64) && Float64(Int64(v)) == v

"""
    _narrow_arg_literals!(x)

Walk the lowered raw-dict tree in place and narrow every integral,
Int64-representable `Float64` that sits as an element of an Expression `args`
array to an `Int64` (CONFORMANCE_SPEC §5.5.3.1 rule 1: an integral,
Int64-representable number is an integer literal regardless of source spelling,
uniformly — inside and outside aggregates).

This normalizes the values JSON3's context-dependent structural number inference
widens on read: a bare integer token (`1`) that JSON3 materializes as `Float64`
because it shares a deeply-nested, float-heavy array with non-integral floats
(the `1`/`8` of `{op:"/",args:[1,8]}` nested under a `cos(pi·…)` aggregate body).
The AST-golden pathway (`resolve_template_machinery` → `lower_expression_templates`
→ canonical sorted write) never runs `parse_expression`, so without this pass a
widened `1.0`/`8.0` survives all the way to the emitted golden — the lone Julia
outlier vs. Python/Rust/TS/Go, which read `[1,8]` as integers.

Narrowing is scoped to `args` array elements (the Expression operand position),
so scalar CONFIGURATION floats an authored `1.0`/`0.0` legitimately occupies
(`variables.*.default`, a bare `expression` scalar, …) are left byte-identical;
only arithmetic operand literals are touched. On the typed-load path this is a
no-op-equivalent: `coerce_esm_file` reads operands via `parse_expression`, which
applies the identical narrowing, so pre-narrowing the tree here changes nothing
downstream. The §5.4.6 canonical AST form (`canonical_json`/`wire_to_expr`),
which deliberately preserves an authored `1.0`, is on a separate path and is
untouched.
"""
function _narrow_arg_literals!(x)
    # One visit per unique container (`seen`): on a structurally-shared
    # expanded tree the same node hangs under many parents, and narrowing is
    # idempotent and value-local, so a single visit of the shared object is
    # exactly equivalent to (exponentially many) repeated ones.
    seen = IdDict{Any,Nothing}()
    _walk_json(x) do key, n
        # Narrow the DIRECT elements of every `args` array in place; the walk
        # then descends into the (mutated) array, recursing through nested
        # operand objects toward their own `args` arrays. This runs before the
        # seen-prune because the trigger is POSITIONAL (the parent key), and a
        # shared array can hang under more than one key.
        if key == "args" && n isa AbstractVector
            for i in eachindex(n)
                vi = n[i]
                _int64_narrowable(vi) && (n[i] = Int64(vi))
            end
        end
        if _is_object(n) || n isa AbstractVector
            haskey(seen, n) && return false
            seen[n] = nothing
        end
        return true
    end
    return x
end

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

"""
    lower_expression_templates(raw_data) -> Dict{String,Any}

Expand every `apply_expression_template` node in `raw_data` against the
component-local `expression_templates` block, then strip those blocks
from the returned tree. The output is a normalized `Dict{String,Any}`
view ready to be passed to `coerce_esm_file`.

Throws [`ExpressionTemplateError`](@ref) on any of:

- file declares `esm` < 0.4.0 but uses templates
- `apply_expression_template` references an undeclared template name
- bindings do not exactly match the template's `params`
- template body contains a nested `apply_expression_template`
- declaration is malformed (params missing, body missing, etc.)
"""
function lower_expression_templates(raw_data)
    reject_expression_templates_pre_v04(raw_data)

    # Fast path: files that neither declare `expression_templates` blocks
    # nor use any `apply_expression_template` op need no expansion at all.
    # Return raw_data unchanged so downstream `coerce_esm_file` sees the
    # original JSON3.Object / Dict shape — no `JSONLikeDict` wrapping. This
    # keeps non-template files on the legacy code path, including those
    # that exercise downstream coercers (`coerce_function_tables`,
    # `coerce_grids`, etc.) whose type-gates predate JSONLikeDict.
    if !_has_template_machinery(raw_data)
        # No expansion to run, but the §9.6.4 expanded-form validators still
        # apply — the raw tree IS the expanded form.
        _validate_geometry_manifolds(raw_data)
        _validate_makearray_regions(raw_data)
        return raw_data
    end

    root = _to_dict(raw_data)::Dict{String,Any}

    # The consuming document's merged index_sets registry (post-§9.7.5): the
    # namespace `where` shape constraints resolve against at registration
    # (esm-spec §9.6.1 — `template_constraint_unknown_index_set` for a name
    # not declared here).
    iset_names = Set{String}()
    isets_raw = get(root, "index_sets", nothing)
    if isets_raw !== nothing && _is_object(isets_raw)
        for (k, _) in pairs(isets_raw)
            push!(iset_names, string(k))
        end
    end

    # Per-component rewrite registries, captured so coupling `variable_map`
    # expression transforms (esm-spec §10.4) can be rewritten against the
    # RECEIVING component's registry below. Models are registered first; a
    # reaction system never overwrites a same-named model.
    registries = Dict{String,_ComponentRegistry}()

    for compkind in ("models", "reaction_systems")
        comps = get(root, compkind, nothing)
        comps === nothing && continue
        _is_object(comps) || continue
        for (cname, compraw) in pairs(comps)
            _is_object(compraw) || continue
            comp = compraw::Dict{String,Any}
            # Static shape environment for `where` constraint evaluation
            # (esm-spec §9.6.1): declared variable shapes only.
            shape_env = _component_shape_env(comp)
            tplraw = get(comp, "expression_templates", nothing)
            # `named`       — every template keyed by name, consulted by
            #                 `apply_expression_template` (order-independent).
            # `match_rules` — the auto-applied `match` rules, in template
            #                 DECLARATION order (esm-spec §9.6.3).
            named = Dict{String,Any}()
            match_rules = _RewriteRule[]
            if _is_object(tplraw)
                templates = Dict{String,Any}()
                for (tname, tdecl) in pairs(tplraw)
                    templates[string(tname)] = tdecl
                end
                _validate_templates(templates, "$compkind.$(string(cname))")
                # Registration-time body CHECKING (esm-spec §9.7.3, Option B):
                # validate the body-reference DAG (acyclic, depth-bounded,
                # references resolve to match-less templates). Bodies are NOT
                # inlined — references are preserved (§9.6.4).
                _compose_template_bodies!(templates, "$compkind.$(string(cname))")
                decl_index = 0
                for tname in _ordered_template_names(raw_data, compkind, string(cname), templates)
                    decl_index += 1
                    decl = templates[tname]
                    named[tname] = decl
                    m = _raw_get(decl, "match")
                    if m !== nothing
                        params_raw = _raw_get(decl, "params")
                        params = Set{String}(string(p) for p in
                                             something(params_raw, String[]))
                        body = _raw_get(decl, "body")
                        # `where` registration: normalize constraints and
                        # resolve every referenced index-set name against the
                        # consuming document's registry (esm-spec §9.6.1;
                        # `template_constraint_unknown_index_set`).
                        where_c = _registered_where(decl, iset_names,
                                                    "$compkind.$(string(cname))", tname)
                        push!(match_rules,
                              _RewriteRule(tname, m, params, body,
                                           _rule_priority(decl), decl_index,
                                           where_c))
                    end
                end
                # Deterministic selection order (esm-spec §9.6.3): highest
                # `priority` first, ties broken by declaration order (earliest
                # wins). `_rewrite_pass` then takes the FIRST matching rule.
                sort!(match_rules, by = r -> (-r.priority, r.decl_index))
            end
            # Target-bearing flags (esm-spec §9.6.4 rule 3): drive the eager
            # pre-pass and the surviving-reference leaf semantics.
            target_bearing = _template_target_bearing(named)
            # Outermost-first, priority-ordered, bounded-fixpoint rewrite per
            # non-template field (esm-spec §9.6.3): fires auto `match` rules and
            # eagerly expands target-bearing references; NON-eager references
            # survive (§9.6.4 rule 4).
            cscope = "$compkind.$(string(cname))"
            for k in collect(keys(comp))
                k == "expression_templates" && continue
                comp[k] = _rewrite_to_fixpoint(comp[k], named, match_rules,
                                   "$cscope.$k", shape_env, target_bearing)
                # Call-site checks on surviving references (§9.6.9): unknown
                # name / bindings mismatch. Known surviving references are the
                # new normal (Option B) — no longer an error.
                _check_surviving_refs(comp[k], named, "$cscope.$k")
            end
            # esm-spec §9.6.4 rule 1 (Option B): DO NOT delete the component's
            # `expression_templates` block — it is the retained registered
            # registry that emit materializes (§9.6.4 rule 5) and Expand
            # consumes (§9.6.4 rule 2).
            haskey(registries, string(cname)) ||
                (registries[string(cname)] =
                    _ComponentRegistry(named, match_rules, shape_env, target_bearing))
        end
    end

    # Coupling `variable_map` expression transforms (esm-spec §10.4/§10.5):
    # template invocations in a transform expand at load against the template
    # registry of the component that owns the entry's `to` target — the
    # receiving component, where a regridding library import (§9.7) lives.
    # The transform is rewritten to fixpoint exactly as a field of that
    # component would be (named templates + auto `match` rules, §9.6.3).
    coupling = get(root, "coupling", nothing)
    if coupling isa AbstractVector
        for (i, entry) in enumerate(coupling)
            _is_object(entry) || continue
            get(entry, "type", nothing) == "variable_map" || continue
            tr = get(entry, "transform", nothing)
            _is_object(tr) || continue
            target = get(entry, "to", nothing)
            target isa AbstractString || continue
            comp_name = String(first(split(target, "."; limit=2)))
            reg = get(registries, comp_name, nothing)
            reg === nothing && continue
            entry["transform"] = _rewrite_to_fixpoint(tr, reg.named,
                                     reg.match_rules,
                                     "coupling[$(i)].transform", reg.shape_env,
                                     reg.target_bearing)
            _check_surviving_refs(entry["transform"], reg.named,
                                  "coupling[$(i)].transform")
        end
    end

    # esm-spec §9.6.4 rule 1 (Option B): surviving `apply_expression_template`
    # references are the NEW NORMAL. Only UNKNOWN-name / bindings-mismatch
    # references are errors — already checked per component / per transform by
    # `_check_surviving_refs`. No global "no apply ops remain" gate.

    # Validation discharge (esm-spec §9.6.9): geometry-manifold and
    # makearray-region checks on the reference-preserving form. The manifold
    # check is per-instantiation (a `manifold` may be a template param), so it
    # descends through surviving references' single-instantiation expansions,
    # memoized. Region bounds cannot carry template params, so the makearray
    # check runs on the reference-preserving tree AND the retained folded
    # template bodies directly.
    _validate_geometry_manifolds_refaware(root, registries)
    _validate_makearray_regions(root)
    _validate_makearray_regions_in_registries(registries)

    # Canonical arithmetic-operand literal narrowing (CONFORMANCE_SPEC §5.5.3.1
    # rule 1): normalize any integral, Int64-representable `Float64` that JSON3's
    # structural number inference widened in an `args` position back to an
    # integer, so the AST-golden pathway (which never calls `parse_expression`)
    # emits `[1,8]` — byte-identical with Python/Rust/TS/Go — for an integer
    # ratio nested inside an aggregate. See `_narrow_arg_literals!`.
    _narrow_arg_literals!(root)

    return JSONLikeDict(root)
end

"""
    _ordered_template_names(raw_data, compkind, cname, templates) -> Vector{String}

Template names of a component in DECLARATION order. The order is read from the
original (order-preserving) source view `raw_data` — `_to_dict` produces an
unordered `Dict`, but `match`-rule precedence (esm-spec §9.6.3) requires the
authored order. Any name not found in the source view (e.g. when `raw_data` is
an already-native, unordered dict) is appended by sorted name so the result is
still deterministic.
"""
function _ordered_template_names(raw_data, compkind, cname, templates::Dict{String,Any})
    ordered = String[]
    seen = Set{String}()
    comps = raw_data === nothing ? nothing : _raw_get(raw_data, compkind)
    comp = comps === nothing ? nothing : _raw_get(comps, cname)
    tpl = (comp === nothing || !_is_object(comp)) ? nothing :
        _raw_get(comp, "expression_templates")
    if tpl !== nothing && _is_object(tpl)
        for (k, _) in pairs(tpl)
            ks = string(k)
            if haskey(templates, ks) && !(ks in seen)
                push!(ordered, ks)
                push!(seen, ks)
            end
        end
    end
    for ks in sort(collect(keys(templates)))
        ks in seen || (push!(ordered, ks); push!(seen, ks))
    end
    return ordered
end

# ===========================================================================
# Typed-IR reference expansion (esm-spec §9.6.4 rule 2 on the typed AST)
# ===========================================================================

"""
    _expand_expr_refs(e::ASTExpr, reg) -> ASTExpr

Fully expand every surviving `apply_expression_template` `OpExpr` in the typed
expression `e` against the component registry `reg` (name → raw decl), to a
fixpoint. Sound (a reference denotes its expansion, §9.6.4 rule 2): the
apply node is round-tripped to its raw form, the raw `_substitute` splices the
bindings into the template body (handling variable AND scalar-field param sites),
and the result is re-parsed and re-expanded — so nested references (in the body
OR in the bindings) are expanded too. Non-apply nodes recurse via `map_children`
(apply nodes are the only `bindings`-bearing nodes, so `map_children` not
descending into `bindings` is exactly right here). This is the per-node `Expand`
fallback the tree-walk build uses and the Expand-at-entry the MTK build uses.
"""
_expand_expr_refs(e::VarExpr, reg) = e
_expand_expr_refs(e::NumExpr, reg) = e
_expand_expr_refs(e::IntExpr, reg) = e
function _expand_expr_refs(e::OpExpr, reg)
    if e.op == APPLY_EXPRESSION_TEMPLATE_OP
        name = e.name
        (name !== nothing && reg !== nothing && haskey(reg, name)) || throw(
            ExpressionTemplateError("apply_expression_template_unknown_template",
                "apply_expression_template references template " *
                "'$(name === nothing ? "?" : name)' with no in-scope registry entry"))
        body_raw = _raw_get(reg[name], "body")
        bindings_raw = Dict{String,Any}()
        if e.bindings !== nothing
            for (k, v) in e.bindings
                bindings_raw[string(k)] = serialize_expression(v)
            end
        end
        substituted = _substitute(body_raw, bindings_raw)
        return _expand_expr_refs(parse_expression(substituted), reg)
    end
    return map_children(c -> _expand_expr_refs(c, reg), e)
end

"""
    _expand_refs!(file::EsmFile) -> EsmFile

Expand every surviving `apply_expression_template` reference in `file`'s
component expressions against `file.component_templates`, IN PLACE (the caller
passes a copy when the reference-preserving original must be kept). Mirrors
`lower_enums!`'s whole-file expression walk. A no-op when
`file.component_templates` is `nothing` (no references survived, or
`ESS_TEMPLATE_REF_DISABLE=1`).
"""
function _expand_refs!(file::EsmFile)::EsmFile
    file.component_templates === nothing && return file
    ct = file.component_templates
    if file.models !== nothing
        for (cname, m) in file.models
            reg = get(ct, "models.$cname", nothing)
            reg === nothing && continue
            _expand_model_refs!(m, reg)
        end
    end
    if file.reaction_systems !== nothing
        for (cname, rs) in file.reaction_systems
            reg = get(ct, "reaction_systems.$cname", nothing)
            reg === nothing && continue
            _expand_reaction_system_refs!(rs, reg)
        end
    end
    return file
end

function _expand_model_refs!(model::Model, reg)
    for (name, var) in model.variables
        if var.expression !== nothing
            lowered = _expand_expr_refs(var.expression, reg)
            lowered === var.expression || _replace_var_expression!(model.variables, name, var, lowered)
        end
    end
    _expand_equations_refs!(model.equations, reg)
    _expand_equations_refs!(model.initialization_equations, reg)
    for (_, sub) in model.subsystems
        sub isa Model && _expand_model_refs!(sub, reg)
    end
    return
end

function _expand_equations_refs!(eqs::Vector{Equation}, reg)
    isempty(eqs) && return
    new_eqs = Equation[Equation(_expand_expr_refs(eq.lhs, reg),
                                _expand_expr_refs(eq.rhs, reg); _comment=eq._comment)
                       for eq in eqs]
    empty!(eqs); append!(eqs, new_eqs)
    return
end

function _expand_reaction_system_refs!(rs::ReactionSystem, reg)
    new_reactions = Reaction[]
    for r in rs.reactions
        push!(new_reactions, Reaction(r.id, raw_substrates(r), raw_products(r),
            _expand_expr_refs(r.rate, reg); name=r.name, reference=r.reference))
    end
    empty!(rs.reactions); append!(rs.reactions, new_reactions)
    for (_, sub) in rs.subsystems
        _expand_reaction_system_refs!(sub, reg)
    end
    return
end

"""
    expand_flattened_refs(flat::FlattenedSystem) -> FlattenedSystem

The sound per-node `Expand` fallback applied at the tree-walk build boundary
(esm-spec §9.6.4 rule 2, RFC out-of-line-expression-templates §7.7): expand every
surviving `apply_expression_template` reference in the flattened equations and
observed expressions against the merged `template_registry`, returning an
Expanded copy. A no-op when the registry is empty (no references survived, or
`ESS_TEMPLATE_REF_DISABLE=1` expanded at load). Called by `build_evaluator` so
references that reach the tree-walk are handled and the result is bit-identical
to the Expand-at-load image.
"""
function expand_flattened_refs(flat::FlattenedSystem)::FlattenedSystem
    reg = flat.template_registry
    isempty(reg) && return flat
    neweqs = Equation[Equation(_expand_expr_refs(eq.lhs, reg),
                               _expand_expr_refs(eq.rhs, reg); _comment=eq._comment)
                      for eq in flat.equations]
    newobs = OrderedDict{String,ModelVariable}()
    for (name, var) in flat.observed_variables
        if var.expression !== nothing
            ex = _expand_expr_refs(var.expression, reg)
            newobs[name] = ex === var.expression ? var :
                ModelVariable(var.type; default=var.default, description=var.description,
                    expression=ex, units=var.units, default_units=var.default_units,
                    shape=var.shape, location=var.location, noise_kind=var.noise_kind,
                    correlation_group=var.correlation_group)
        else
            newobs[name] = var
        end
    end
    return FlattenedSystem(flat; equations=neweqs, observed_variables=newobs)
end

# ===========================================================================
# `Expand` — the public full-expansion function (esm-spec §9.6.4 rule 2)
# ===========================================================================

"""
    Expand(loaded) -> Dict{String,Any}
    expand_document(loaded) -> Dict{String,Any}

Fully expand every surviving `apply_expression_template` reference in a document
`loaded` by `lower_expression_templates` (Option B), producing the Option-A
image: every reference replaced by its expansion (pure substitution to the
acyclic fixpoint, §9.6.4 rule 2) and every per-component `expression_templates`
block stripped. Deterministic — the DAG is acyclic and substitution confluent,
so `Expand(load(f))` is structurally equal to the pre-0.9.0 expanded form (the
`expanded*.esm` conformance oracle, §9.6.7). Non-destructive: `loaded` is deep
copied first.
"""
function expand_document(loaded)
    root0 = loaded isa JSONLikeDict ? getfield(loaded, :data) : loaded
    (root0 === nothing || !_is_object(root0)) && return root0
    root = _to_dict(root0)::Dict{String,Any}

    # Capture each component's named registry BEFORE stripping the blocks.
    comp_named = Dict{Tuple{String,String},Dict{String,Any}}()
    for compkind in ("models", "reaction_systems")
        comps = get(root, compkind, nothing)
        comps === nothing && continue
        _is_object(comps) || continue
        for (cname, comp) in pairs(comps)
            _is_object(comp) || continue
            named = Dict{String,Any}()
            tpl = get(comp, "expression_templates", nothing)
            if _is_object(tpl)
                for (n, d) in pairs(tpl)
                    named[string(n)] = d
                end
            end
            comp_named[(compkind, string(cname))] = named
        end
    end

    for compkind in ("models", "reaction_systems")
        comps = get(root, compkind, nothing)
        comps === nothing && continue
        _is_object(comps) || continue
        for (cname, comp) in pairs(comps)
            _is_object(comp) || continue
            named = comp_named[(compkind, string(cname))]
            scope = "$compkind.$(string(cname))"
            for k in collect(keys(comp))
                (k == "expression_templates" || k == "expression_template_imports") && continue
                comp[k] = _expand_all(comp[k], named, "$scope.$k")
            end
            haskey(comp, "expression_templates") && delete!(comp, "expression_templates")
        end
    end

    coupling = get(root, "coupling", nothing)
    if coupling isa AbstractVector
        for (i, entry) in enumerate(coupling)
            _is_object(entry) || continue
            get(entry, "type", nothing) == "variable_map" || continue
            tr = get(entry, "transform", nothing)
            _is_object(tr) || continue
            target = get(entry, "to", nothing)
            target isa AbstractString || continue
            comp_name = String(first(split(target, "."; limit=2)))
            named = get(comp_named, ("models", comp_name),
                        get(comp_named, ("reaction_systems", comp_name), nothing))
            named === nothing && continue
            entry["transform"] = _expand_all(tr, named, "coupling[$(i)].transform")
        end
    end

    return root
end

"""
    Expand(loaded) -> Dict{String,Any}

Public alias for [`expand_document`](@ref) using the spec's spelling
(esm-spec §9.6.4 rule 2). `Expand ∘ load` reproduces the Option-A expanded form.
"""
Expand(loaded) = expand_document(loaded)

# ===========================================================================
# Reference-preserving emit (esm-spec §9.6.4 rule 5, §9.6.7)
# ===========================================================================

"""
    _ref_closure(refnames, named) -> Set{String}

The transitive closure of the templates named by `refnames` (surviving-reference
names), following references inside materialized bodies, keeping only MATCH-LESS
entries (esm-spec §9.6.4 rule 5: match rules are never materialized).
"""
function _ref_closure(refnames, named::AbstractDict)::Set{String}
    out = Set{String}()
    stack = collect(String, refnames)
    while !isempty(stack)
        n = pop!(stack)
        (n in out || !haskey(named, n)) && continue
        decl = named[n]
        _raw_get(decl, "match") === nothing || continue  # match rules not materialized
        push!(out, n)
        for r in _collect_apply_names!(String[], _raw_get(decl, "body"))
            push!(stack, r)
        end
    end
    return out
end

"""
    _authored_template_names(raw_source) -> Dict{String,Vector{String}}

Per-component MATCH-LESS template names authored in-file in `raw_source`
(compkind.cname → ordered names). Emit keeps these verbatim as authored entries
(esm-spec §9.6.4 rule 5); imported/derived templates are materialized instead.
"""
function _authored_template_names(raw_source)::Dict{String,Vector{String}}
    authored = Dict{String,Vector{String}}()
    (raw_source === nothing || !_is_object(raw_source)) && return authored
    for compkind in ("models", "reaction_systems")
        comps = _raw_get(raw_source, compkind)
        (comps === nothing || !_is_object(comps)) && continue
        for (cname, comp) in pairs(comps)
            _is_object(comp) || continue
            tpl = _raw_get(comp, "expression_templates")
            (tpl !== nothing && _is_object(tpl)) || continue
            names = String[]
            for (n, d) in pairs(tpl)
                _is_object(d) || continue
                _raw_get(d, "match") === nothing || continue
                push!(names, string(n))
            end
            authored["$compkind.$(string(cname))"] = names
        end
    end
    return authored
end

"""
    _materialize_components!(root, authored) -> (blocks, bump)

The shared per-component materialization (esm-spec §9.6.4 rule 5): for each
component of the Option-B loaded `root`, compute its emitted
`expression_templates` block — authored match-less entries first in authored
order, then the materialized transitive closure of its surviving references
(match-less), lexicographically sorted — write it back onto the component, and
drop consumed `expression_template_imports`. Returns `blocks` (compkey →
`OrderedDict` emitted block, keyed `"<compkind>.<cname>"`, only for components
with a non-empty block) and `bump` (true iff any surviving reference or
materialized entry remains → §9.6.4 rule 8 version stamp). Shared by
[`emit_document`](@ref) (raw emit) and the typed load path (`_lower_and_coerce`).
"""
function _materialize_components!(root, authored::Dict{String,Vector{String}})
    blocks = Dict{String,OrderedDict{String,Any}}()
    bump = false
    for compkind in ("models", "reaction_systems")
        comps = get(root, compkind, nothing)
        comps === nothing && continue
        _is_object(comps) || continue
        for (cname, comp) in pairs(comps)
            _is_object(comp) || continue
            key = "$compkind.$(string(cname))"
            tpl = get(comp, "expression_templates", nothing)
            named = Dict{String,Any}()
            if _is_object(tpl)
                for (n, d) in pairs(tpl)
                    named[string(n)] = d
                end
            end
            refnames = Set{String}()
            for (k, v) in comp
                (string(k) == "expression_templates" ||
                 string(k) == "expression_template_imports") && continue
                for r in _collect_apply_names!(String[], v)
                    push!(refnames, r)
                end
            end
            isempty(refnames) || (bump = true)
            materialized = _ref_closure(refnames, named)
            authored_here = get(authored, key, String[])
            authored_set = Set(authored_here)

            emit_block = OrderedDict{String,Any}()
            for n in authored_here
                haskey(named, n) && (emit_block[n] = named[n])
            end
            for n in sort(collect(setdiff(materialized, authored_set)))
                emit_block[n] = named[n]
                bump = true
            end

            if isempty(emit_block)
                haskey(comp, "expression_templates") && delete!(comp, "expression_templates")
            else
                comp["expression_templates"] = emit_block
                blocks[key] = emit_block
            end
            haskey(comp, "expression_template_imports") &&
                delete!(comp, "expression_template_imports")
        end
    end
    haskey(root, "expression_template_imports") && delete!(root, "expression_template_imports")
    return (blocks, bump)
end

"""
    _merge_flat_registry(component_templates) -> Dict{String,Any}

Merge the per-component materialized registries (compkey → block) into the
single document-scoped registry the flattened representation carries (esm-spec
§9.6.4 rule 7 / §10.7 / esm-libraries-spec §4.7.5 step 4): deep-equal same-name
entries dedupe at first occurrence; a non-deep-equal same-name collision renames
BOTH entries to `<ComponentPath>.<name>`. `nothing` in ⇒ empty out.
"""
function _merge_flat_registry(component_templates)::Dict{String,Any}
    merged = Dict{String,Any}()
    component_templates === nothing && return merged
    byname = OrderedDict{String,Vector{Tuple{String,Any}}}()
    # Deterministic component order (sorted compkey) so dedup "first occurrence"
    # and collision rename are reproducible.
    for compkey in sort(collect(keys(component_templates)))
        block = component_templates[compkey]
        _is_object(block) || continue
        path = String(last(split(compkey, "."; limit=2)))
        for name in sort(collect(string(k) for (k, _) in pairs(block)))
            push!(get!(byname, name, Tuple{String,Any}[]), (path, _raw_get(block, name)))
        end
    end
    for (name, occ) in byname
        if all(o -> _json_equal(occ[1][2], o[2]), occ)
            merged[name] = occ[1][2]
        else
            for (path, decl) in occ
                merged["$path.$name"] = decl
            end
        end
    end
    return merged
end

"""
    _expand_coupling_transform_refs!(root)

Expand surviving `apply_expression_template` references inside `variable_map`
coupling `transform`s (esm-spec §10.4) against the RECEIVING component's registry.
Coupling is not a component, so these references cannot be per-component
materialized (§9.6.4 rule 5); expanding them at load keeps the coupling section
self-contained. Called by the typed load path before `_materialize_components!`
strips the component registries.
"""
function _expand_coupling_transform_refs!(root)
    coupling = get(root, "coupling", nothing)
    coupling isa AbstractVector || return
    for entry in coupling
        _is_object(entry) || continue
        get(entry, "type", nothing) == "variable_map" || continue
        tr = get(entry, "transform", nothing)
        _is_object(tr) || continue
        target = get(entry, "to", nothing)
        target isa AbstractString || continue
        comp_name = String(first(split(target, "."; limit=2)))
        named = nothing
        for ck in ("models", "reaction_systems")
            comps = get(root, ck, nothing)
            comps isa AbstractDict || continue
            comp = get(comps, comp_name, nothing)
            comp isa AbstractDict || continue
            tpl = get(comp, "expression_templates", nothing)
            if _is_object(tpl)
                named = Dict{String,Any}(string(n) => d for (n, d) in pairs(tpl))
            end
            break
        end
        named === nothing && continue
        entry["transform"] = _expand_all(tr, named, "coupling.transform")
    end
    return
end

"""
    emit_document(raw_source, base_path) -> Dict{String,Any}

Produce the reference-preserving, self-contained emitted document (esm-spec
§9.6.4 rule 5, RFC out-of-line-expression-templates §7.5) from a source document
(a fixture, or an already-emitted document for the idempotency property). Loads
`raw_source` under Option B, then materializes each component's
`expression_templates` block ([`_materialize_components!`](@ref)), drops consumed
`expression_template_imports`, and version-stamps `esm: 0.9.0` when any surviving
reference or materialized entry remains (§9.6.4 rule 8). `emit_esm_string ∘
emit_document` is a byte-wise fixed point under reload.
"""
function emit_document(raw_source, base_path::AbstractString)
    authored = _authored_template_names(raw_source)
    resolved = resolve_template_machinery(raw_source, String(base_path))
    loaded = lower_expression_templates(resolved === nothing ? raw_source : resolved)
    root = loaded isa JSONLikeDict ? getfield(loaded, :data) : _to_dict(loaded)
    root isa Dict{String,Any} || (root = _to_dict(root))
    _blocks, bump = _materialize_components!(root, authored)
    bump && (root["esm"] = "0.9.0")
    return root
end

# --- Canonical byte writer (2-space indent, keys sorted except the ordered
#     `expression_templates` block) — the cross-binding byte-identity surface. ---

_emit_norm(x) =
    (x isa AbstractDict) ?
        OrderedDict{String,Any}(string(k) => _emit_norm(v) for (k, v) in pairs(x)) :
    (_is_object(x)) ?
        OrderedDict{String,Any}(string(k) => _emit_norm(v) for (k, v) in pairs(x)) :
    (x isa AbstractVector || _is_array(x)) ? Any[_emit_norm(v) for v in x] : x

function _emit_write(io::IO, x, indent::Int; preserve::Bool=false)
    pad = "  "^indent
    pad1 = "  "^(indent + 1)
    if x isa AbstractDict
        isempty(x) && return print(io, "{}")
        ks = preserve ? collect(keys(x)) : sort(collect(keys(x)))
        print(io, "{\n")
        for (i, k) in enumerate(ks)
            print(io, pad1, JSON3.write(string(k)), ": ")
            _emit_write(io, x[k], indent + 1;
                        preserve = (string(k) == "expression_templates"))
            i < length(ks) && print(io, ",")
            print(io, "\n")
        end
        print(io, pad, "}")
    elseif x isa AbstractVector
        isempty(x) && return print(io, "[]")
        print(io, "[\n")
        for (i, v) in enumerate(x)
            print(io, pad1)
            _emit_write(io, v, indent + 1)
            i < length(x) && print(io, ",")
            print(io, "\n")
        end
        print(io, pad, "]")
    else
        print(io, JSON3.write(x))
    end
end

# ===========================================================================
# Flatten: template-registry merge (esm-spec §9.6.4 rule 7, §10.7;
# esm-libraries-spec §4.7.5)
# ===========================================================================

"""
    _rename_apply_refs(node, rename) -> node

Rewrite the `name` of every `apply_expression_template` reference in `node`
according to `rename` (old name → new name), in lockstep with a registry
rename. Sharing-preserving.
"""
function _rename_apply_refs(node, rename::AbstractDict{String,String})
    if _is_array(node)
        changed = false
        buf = Vector{Any}(undef, length(node))
        for (i, v) in enumerate(node)
            rv = _rename_apply_refs(v, rename)
            rv === v || (changed = true)
            buf[i] = rv
        end
        return changed ? buf : node
    elseif _is_object(node)
        op = _raw_get(node, "op")
        is_apply = op !== nothing && string(op) == APPLY_EXPRESSION_TEMPLATE_OP
        changed = false
        buf = OrderedDict{String,Any}()
        for (k, v) in pairs(node)
            ks = string(k)
            if is_apply && ks == "name" && v isa AbstractString && haskey(rename, string(v))
                buf[ks] = rename[string(v)]
                changed = true
            else
                rv = _rename_apply_refs(v, rename)
                rv === v || (changed = true)
                buf[ks] = rv
            end
        end
        return changed ? buf : node
    else
        return node
    end
end

"""
    flatten_template_registries(loaded) -> (root, merged_registry)

The flatten-time template-registry merge (esm-spec §9.6.4 rule 7, §10.7;
esm-libraries-spec §4.7.5 step 4). Given an Option-B loaded multi-component
document `loaded`, merge every component's `expression_templates` registry into
a single document-scoped merged registry:

- **Deep-equal dedup at first occurrence** — the common case, two components
  importing one stencil produce identical folded bodies, kept once under the
  bare name.
- **Non-deep-equal same-name collision** — both entries are renamed
  deterministically to `<ComponentPath>.<name>` and their
  `apply_expression_template` references are rewritten in lockstep (total,
  deterministic; no new diagnostic).

Returns the rewritten document `root` (component reference sites updated) and
the merged registry as an `OrderedDict` (the FlattenedSystem's first-class
registry field). Downstream consumers resolve surviving references against it
or `Expand` them (§9.6.4 rule 2). `match` rules are not merged (only match-less
templates are referenceable, §9.6.2).
"""
function flatten_template_registries(loaded)
    root = _to_dict(loaded isa JSONLikeDict ? getfield(loaded, :data) : loaded)
    # (path, compkind, cname, comp, named)
    comps = Tuple{String,String,String,Dict{String,Any},Dict{String,Any}}[]
    for compkind in ("models", "reaction_systems")
        cs = get(root, compkind, nothing)
        (cs !== nothing && _is_object(cs)) || continue
        for (cname, comp) in pairs(cs)
            _is_object(comp) || continue
            named = Dict{String,Any}()
            tpl = get(comp, "expression_templates", nothing)
            if _is_object(tpl)
                for (n, d) in pairs(tpl)
                    _raw_get(d, "match") === nothing || continue  # match rules not merged
                    named[string(n)] = d
                end
            end
            push!(comps, (string(cname), compkind, string(cname),
                          comp::Dict{String,Any}, named))
        end
    end

    # Group each template name across components (preserving first-seen path).
    byname = OrderedDict{String,Vector{Tuple{String,Any}}}()
    for (path, _, _, _, named) in comps
        for n in sort(collect(keys(named)))
            push!(get!(byname, n, Tuple{String,Any}[]), (path, named[n]))
        end
    end

    merged = OrderedDict{String,Any}()
    rename = Dict{String,Dict{String,String}}()   # path => (old => new)
    for name in sort(collect(keys(byname)))
        occ = byname[name]
        alleq = all(o -> _json_equal(occ[1][2], o[2]), occ)
        if alleq
            merged[name] = occ[1][2]                # deep-equal dedup
        else
            for (path, decl) in occ                 # collision: owner-path rename
                newname = "$path.$name"
                merged[newname] = decl
                get!(rename, path, Dict{String,String}())[name] = newname
            end
        end
    end

    # Rewrite reference sites in lockstep (component expression positions and the
    # carried bodies of the renamed entries).
    for (path, _, _, comp, _) in comps
        rn = get(rename, path, nothing)
        rn === nothing && continue
        for k in collect(keys(comp))
            k == "expression_templates" && continue
            comp[k] = _rename_apply_refs(comp[k], rn)
        end
        # The merged (renamed) bodies owned by this path get their nested
        # references rewritten too.
        for (old, new) in rn
            haskey(merged, new) && (merged[new] = _rename_apply_refs(merged[new], rn))
        end
        # Drop the now-merged per-component block from the flattened form.
        haskey(comp, "expression_templates") && delete!(comp, "expression_templates")
    end
    for (_, _, _, comp, named) in comps
        # Components with no rename still surrender their (merged) block.
        haskey(comp, "expression_templates") && delete!(comp, "expression_templates")
    end

    return (root, merged)
end

"""
    emit_esm_string(doc) -> String

Canonical byte serialization of an emitted document (esm-spec §9.6.4 rule 5):
2-space indent, object keys sorted lexicographically EXCEPT the entries of an
`expression_templates` object, which preserve their authored-first /
materialized-sorted order. The cross-binding byte-identity surface for the
Option-B emitted form and the target of the `emitted.esm` goldens.
"""
function emit_esm_string(doc)::String
    io = IOBuffer()
    _emit_write(io, _emit_norm(doc), 0)
    print(io, "\n")
    return String(take!(io))
end
