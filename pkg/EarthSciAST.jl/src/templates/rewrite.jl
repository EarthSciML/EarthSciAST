# The load-time rewrite pass for `expression_templates` on the raw document
# (esm-spec §9.6): substitution, apply-site expansion, `match` rules and the
# §9.6.3 fixpoint. It works on the raw JSON view and returns the rewritten
# `OrderedDict{String,Any}` document for `coerce_esm_file`.
#
# A template without `match` is expanded where an `apply_expression_template`
# node names it, its `bindings` supplying each param. A template with `match` is
# an auto-applied rule: its params are wildcards (an operand param binds the
# matched sub-AST, a scalar-field param the matched literal), and an optional
# `where` block (§9.6.1) restricts it statically to captures whose declared
# `shape` matches; a rule `where` excludes does not match at that node.
#
# Rewriting (`_rewrite_to_fixpoint`) runs passes of one outermost-first walk
# each (`_rewrite_pass`). At each node the walk first tries a rule: an
# `apply_expression_template` is expanded, else the matching rule with the
# highest `priority` (default 0, ties by declaration order) fires. Its body
# replaces the node and is not descended into in the same pass. Passes repeat
# until one rewrites nothing; `MAX_REWRITE_PASSES` productive passes without
# converging reject the file with `rewrite_rule_nonterminating`. Only eager
# (target-bearing, §9.6.4 rule 3) apply references are expanded here; the rest
# survive as leaves and each component keeps its `expression_templates` block as
# the registry the build resolves them against. A rewrite-target op that
# survives into an evaluation position is refused later (`unlowered_operator`).

const APPLY_EXPRESSION_TEMPLATE_OP = "apply_expression_template"

# Every expansion of a template reference made in this process (raw or typed),
# and the `:tpl_expanded` build count: the explicit expansion utilities
# (`Expand`, `expand_flattened_refs`, the `:mtk` target) are the only callers
# expected to move it; load, flatten, validation and build leave it at 0.
const TEMPLATE_EXPANSIONS = Threads.Atomic{Int}(0)
_note_expansion!() = (Threads.atomic_add!(TEMPLATE_EXPANSIONS, 1); _count!(:tpl_expanded); nothing)

"""
    _BodyView

How the rewrite engine sees a template body it rewrites for one template
instance (esm-spec §9.6.4 rule 3): `params` — the template's parameters, each a
leaf; `lit` — the literal the instance binds to each parameter in a structural
position (a scalar field, a `ranges` bound or `from`, an `enum` argument);
`entries` — each parameter's instance entry ([`_instance_entry`](@ref)), which
a `where` `shape` constraint reads.
"""
struct _BodyView
    params::Set{String}
    lit::Dict{String, Any}
    entries::Dict{String, String}
end

struct _NoLit end
const _NO_LIT = _NoLit()

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
function _substitute(body, bindings::Dict{String, Any})
    isempty(bindings) && return body
    return _rewrite_json(body) do rw, n
        n isa AbstractString && return get(bindings, String(n), n)
        # esm-spec §9.6.3 constraint 5 / §9.6.4 rule 4: parameter substitution
        # applies inside a nested `apply_expression_template` reference's
        # `bindings` values exactly as any other Expression position, but the
        # `name` field is never a substitution site.
        _is_apply_node(n) && return _rewrite_json_children(rw, n; keep = "name")
        return _JSON_DESCEND
    end
end

# Whether the raw JSON node `n` is an `apply_expression_template` node.
function _is_apply_node(n)
    _is_object(n) || return false
    op = _raw_get(n, "op")
    return op !== nothing && string(op) == APPLY_EXPRESSION_TEMPLATE_OP
end

"""
    _resolve_apply_site(node, templates, scope; reject_match_rule=false)
        -> (name, decl, bindings_raw)

The ONE call-site resolution shared by [`_expand_apply`](@ref) (expansion)
and [`_validate_apply_ref`](@ref) (surviving-reference check): `name` present,
declared in `templates`, `bindings` an object covering the declaration's
`params` exactly. `reject_match_rule = true` additionally rejects a reference
to a `match` rewrite rule (only match-less templates are invocable by name,
esm-spec §9.6.2); that check runs directly after the declaration lookup, so it
takes precedence over a bindings mismatch. Throws the stable §9.6.6
diagnostics.
"""
function _resolve_apply_site(
        node, templates::AbstractDict, scope::String;
        reject_match_rule::Bool = false
    )
    name_raw = _raw_get(node, "name")
    name_raw === nothing && throw(
        ExpressionTemplateError(
            ERROR_CODES.APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
            "$scope: apply_expression_template node missing 'name'"
        )
    )
    name = string(name_raw)
    decl = get(templates, name, nothing)
    decl === nothing && throw(
        ExpressionTemplateError(
            ERROR_CODES.APPLY_EXPRESSION_TEMPLATE_UNKNOWN_TEMPLATE,
            "$scope: apply_expression_template references undeclared template '$name'"
        )
    )
    if reject_match_rule && _raw_get(decl, "match") !== nothing
        throw(
            ExpressionTemplateError(
                ERROR_CODES.APPLY_EXPRESSION_TEMPLATE_UNKNOWN_TEMPLATE,
                "$scope: apply_expression_template references '$name', a `match` " *
                    "rewrite rule — only match-less templates are invocable by name (esm-spec §9.6.2)"
            )
        )
    end
    bindings_raw = _raw_get(node, "bindings")
    (bindings_raw === nothing || !_is_object(bindings_raw)) && throw(
        ExpressionTemplateError(
            ERROR_CODES.APPLY_EXPRESSION_TEMPLATE_BINDINGS_MISMATCH,
            "$scope: apply_expression_template '$name' missing 'bindings' object"
        )
    )
    decl_params = _TemplateDecl(decl).params
    declared = Set(decl_params)
    provided = Set{String}([string(k) for (k, _) in pairs(bindings_raw)])
    for p in decl_params
        p in provided || throw(
            ExpressionTemplateError(
                ERROR_CODES.APPLY_EXPRESSION_TEMPLATE_BINDINGS_MISMATCH,
                "$scope: apply_expression_template '$name' missing binding for param '$p'"
            )
        )
    end
    for p in provided
        p in declared || throw(
            ExpressionTemplateError(
                ERROR_CODES.APPLY_EXPRESSION_TEMPLATE_BINDINGS_MISMATCH,
                "$scope: apply_expression_template '$name' supplies unknown param '$p'"
            )
        )
    end
    return (name, decl, bindings_raw)
end

function _expand_apply(node, templates::AbstractDict, scope::String)
    _, decl, bindings_raw = _resolve_apply_site(node, templates, scope)
    # The bindings are consumed as they are: `_expand_refs_walk`, the only
    # route here, expands the references inside them first. The template
    # `body` is instantiated by pure structural substitution and is NOT
    # re-scanned (esm-spec §9.6.3 rule 2: a replacement body is not
    # re-matched).
    resolved = Dict{String, Any}()
    for (k, v) in pairs(bindings_raw)
        resolved[string(k)] = v
    end
    return _substitute(_raw_get(decl, "body"), resolved)
end

"""
    _validate_apply_ref(node, templates, scope)

Call-site check for a SURVIVING (non-expanded) `apply_expression_template`
reference (esm-spec §9.6.9): the referenced `name` must resolve to an in-scope
MATCH-LESS template and `bindings` must cover its `params` exactly. Same
diagnostics as `_expand_apply` (`apply_expression_template_unknown_template`,
`apply_expression_template_bindings_mismatch`), but WITHOUT expanding — the
reference is preserved (§9.6.4 rule 1).
"""
function _validate_apply_ref(node, templates::AbstractDict, scope::String)
    _resolve_apply_site(node, templates, scope; reject_match_rule = true)
    return
end

"""
    _check_surviving_refs(node, templates, scope)

Walk `node` and run [`_validate_apply_ref`](@ref) on every surviving
`apply_expression_template` reference it carries (esm-spec §9.6.9 call-site
checks). Descends into references' `bindings` too — a binding value MAY itself
be a surviving reference.
"""
function _check_surviving_refs(node, templates::AbstractDict, scope::String)
    _visit_json(node) do _, n
        _is_apply_node(n) && _validate_apply_ref(n, templates, scope)
        return true
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
    Set{String}(
    [
        "D", "grad", "div", "laplacian", "integral", "enum",
    ]
)

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
    _direct_op_hit(node, pred) -> Bool

True iff `node` contains, ANYWHERE within it (descending through every field,
including the `bindings` of nested `apply_expression_template` nodes), an
object whose `op` satisfies `pred(op::String)`. Does NOT follow references to
other templates — that transitive step is [`_transitive_op_flags`](@ref).
Identity-`seen` so a structurally-shared subtree is visited once.
"""
function _direct_op_hit(node, pred)::Bool
    return _visit_json(node) do _, n
        _is_object(n) || return true
        op = _raw_get(n, "op")
        return (op !== nothing && pred(string(op))) ? _JSON_STOP : true
    end
end

"""
    _direct_T_op(node) -> Bool

[`_direct_op_hit`](@ref) with the rewrite-target tier **T** predicate
(`_op_in_T`) — the direct half of the §9.6.4 rule-3 eagerness test.
"""
_direct_T_op(node) = _direct_op_hit(node, _op_in_T)

"""
    _transitive_op_flags(templates, pred; graph = _template_graph(templates)) -> Dict{String,Bool}

The one transitive op flag (the library-edge enum check): a template is flagged iff its body
contains an op satisfying `pred` anywhere (including inside nested references'
`bindings`), or it references, transitively, a flagged template
([`_flagged`](@ref), exact on a graph with cycles). A caller that already
holds the reference graph of `templates` passes it as `graph`.
"""
function _transitive_op_flags(
        templates::AbstractDict, pred; graph::_TemplateGraph = _template_graph(templates)
    )::Dict{String, Bool}
    return _flagged(graph) do name
        body = _raw_get(templates[name], "body")
        body !== nothing && _direct_op_hit(body, pred)
    end
end

"""
    _expand_refs_walk(node, named, scope, expand_pred, memo) -> node

The ONE memoized, sharing-preserving reference-expansion walk behind
[`_expand_all`](@ref) and the library-edge `enum` expansion. Innermost-first: an
`apply_expression_template` node's `bindings` are rewritten before the node
itself is considered; a node for which `expand_pred(node)` holds is expanded
by pure substitution (`_expand_apply`) and its instantiated body re-walked;
any other reference is returned intact. Unchanged subtrees are returned by
identity and the memo preserves DAG sharing.
"""
function _expand_refs_walk(
        node, named::AbstractDict, scope::String,
        expand_pred, memo::IdDict{Any, Any}
    )
    return _rewrite_json(node; memo = memo, leaves = false) do rw, n
        _is_apply_node(n) || return _JSON_DESCEND
        # Innermost-first: rewrite references inside the bindings first.
        b = _raw_get(n, "bindings")
        newnode = n
        if b !== nothing && _is_object(b)
            nb = _rewrite_json_children(rw, b)
            if nb !== b
                newnode = OrderedDict{String, Any}(
                    string(k) => (string(k) == "bindings" ? nb : v) for (k, v) in pairs(n)
                )
            end
        end
        expand_pred(newnode) || return newnode
        _note_expansion!()
        res = _rewrite_json_node(rw, _expand_apply(newnode, named, scope))
        # While marking (a mount's leaf, expanded at load), the root of the
        # expansion records that it came from an application (esm-spec
        # §9.6.11), as `_expand_expr_refs` does on typed trees.
        if _marking_template_origins() && _is_object(res)
            marked = OrderedDict{String, Any}(string(k) => v for (k, v) in pairs(res))
            marked[_TEMPLATE_ORIGIN_WIRE_KEY] = string(_raw_get(newnode, "name"))
            res = marked
        end
        return res
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
_expand_all(
    node, named::AbstractDict, scope::String,
    memo::IdDict{Any, Any} = IdDict{Any, Any}()
) =
    _expand_refs_walk(node, named, scope, _ -> true, memo)

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
function _match_pattern(
        pattern, node, params::Set{String}, bindings::Dict{String, Any},
        bv::Union{Nothing, _BodyView} = nothing
    )::Bool
    # Inside a template body (esm-spec §9.6.4 rules 3 and 4) a parameter is a
    # leaf: a metavariable captures it whole, and any other pattern node sees
    # it only as the literal its instance binds in a structural position (and
    # never matches an operand-position parameter).
    if bv !== nothing && node isa AbstractString && String(node) in bv.params &&
            !(pattern isa AbstractString && String(pattern) in params)
        lit = get(bv.lit, String(node), _NO_LIT)
        lit === _NO_LIT && return false
        return _match_pattern(pattern, lit, params, bindings)
    end
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
            _match_pattern(pp, nn, params, bindings, bv) || return false
        end
        return true
    elseif _is_object(pattern)
        _is_object(node) || return false
        for (k, pv) in pairs(pattern)
            ks = string(k)
            nv = _raw_get(node, ks)
            (nv === nothing && !_raw_haskey(node, ks)) && return false
            _match_pattern(pv, nv, params, bindings, bv) || return false
        end
        return true
    else
        # nothing / null literal in the pattern.
        return pattern === node
    end
end

# ---------------------------------------------------------------------------
# Static match-scoping constraints (`where`, esm-spec §9.6.1;
# docs/content/rfcs/match-pattern-scoping-constraints.md)
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
function _component_shape_env(comp)::Dict{String, Vector{String}}
    env = Dict{String, Vector{String}}()
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

const _EMPTY_SHAPE_ENV = Dict{String, Vector{String}}()

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
function _where_satisfied(
        where_c, bindings::Dict{String, Any},
        shape_env::Dict{String, Vector{String}},
        bv::Union{Nothing, _BodyView} = nothing
    )::Bool
    where_c === nothing && return true
    for (p, req) in where_c
        b = get(bindings, p, nothing)
        b isa AbstractString || return false
        # A template-body parameter satisfies it iff its instance binds a bare
        # variable of exactly that declared shape (esm-spec §9.6.4 rule 3).
        if bv !== nothing && String(b) in bv.params
            get(bv.entries, String(b), "") == _shape_entry(req) || return false
            continue
        end
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
function _registered_where(
        decl, iset_names::Set{String}, scope::String,
        tname::String
    )
    whr = _raw_get(decl, "where")
    whr === nothing && return nothing
    out = Dict{String, Vector{String}}()
    for (p, cobj) in pairs(whr)
        shp = _raw_get(cobj, "shape")
        req = String[string(s) for s in shp]
        for s in req
            s in iset_names || throw(
                ExpressionTemplateError(
                    ERROR_CODES.TEMPLATE_CONSTRAINT_UNKNOWN_INDEX_SET,
                    "$scope.expression_templates.$tname: where.$(string(p)).shape " *
                        "names index set '$s', which the consuming document's " *
                        "index_sets registry does not declare (esm-spec §9.6.1/§9.6.6)"
                )
            )
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
rule is unconstrained). `param_list` is `params` in declared order: the keys
of the reference a firing writes (esm-spec §9.6.3 constraint 7).
"""
struct _RewriteRule
    name::String
    pattern::Any
    params::Set{String}
    param_list::Vector{String}
    body::Any
    priority::Int
    decl_index::Int
    where_clause::Union{Nothing, Dict{String, Vector{String}}}
end

"""
    _Lowering

One component's rewrite state (esm-spec §9.6.3, §9.6.4 rule 3): `named` — every
template declaration keyed by name (the registry references resolve against;
rule 3 adds its variants here); `match_rules` — the auto-applied rules
pre-sorted into §9.6.3 selection order; `shape_env` — the component's static
shape environment ([`_component_shape_env`](@ref)) for `where` constraints;
`enums` — the document's `enums` block, for the per-instance `enum` lowering
of rule 3; `depth` — the rewrite depth of each reference a firing wrote (the
pass that wrote it; a reference the author wrote has depth 0 and no entry).
This is also everything needed to rewrite a coupling `variable_map` transform
against the RECEIVING component (esm-spec §10.4).
"""
struct _Lowering
    named::Dict{String, Any}
    match_rules::Vector{_RewriteRule}
    shape_env::Dict{String, Vector{String}}
    enums::Any
    scope::String
    depth::IdDict{Any, Int}
end

"""
    _rule_reference(rule, captured) -> node

What a firing of `rule` writes in place of the matched node (esm-spec §9.6.3
constraint 7): a reference to the rule bound to what the match captured, a
parameter the match never bound being bound to its own name. A rule whose body
is a single leaf writes the leaf (for one of its parameters, what that
parameter bound): there is no body to share.
"""
function _rule_reference(rule::_RewriteRule, captured::Dict{String, Any})
    body = rule.body
    if !_is_object(body) && !_is_array(body)
        body isa AbstractString && String(body) in rule.params &&
            return get(captured, String(body), String(body))
        return body
    end
    b = OrderedDict{String, Any}()
    for p in rule.param_list
        b[p] = get(captured, p, p)
    end
    return OrderedDict{String, Any}(
        "op" => APPLY_EXPRESSION_TEMPLATE_OP, "args" => Any[],
        "name" => rule.name, "bindings" => b
    )
end

"""
    _rewrite_pass(node, L, pass, last, bv) -> (new_node, changed)

One pre-order (outermost-first) rewrite pass over `node` (esm-spec §9.6.3), a
sharing-preserving [`_rewrite_json`](@ref) walk. At each object node the first
rule in `L.match_rules` (highest `priority` first, ties by declaration order)
whose `match` pattern matches the node AND whose `where` constraints hold
fires; constraint filtering is part of match eligibility (§9.6.3 constraint 2).
A firing writes a reference to the rule ([`_rule_reference`](@ref), constraint
7), recorded in `L.depth` at depth `pass`, and the walk does not descend into
it during this pass. At a reference — authored or written — no pattern
matches (§9.6.4 rule 4), but the walk descends into the values of its
`bindings`, which are expressions of the call site. `bv` is the template-body
view when `node` is a template body being rewritten for one instance (§9.6.4
rule 3), `nothing` at a component's expression positions. `last` records the
name of the last rule that fired, for the non-convergence diagnostic.
"""
function _rewrite_pass(
        node, L::_Lowering, pass::Int, last::Ref{String},
        bv::Union{Nothing, _BodyView} = nothing
    )
    changed = Ref(false)
    # One rewrite per unique node: the rewrite of a node is a function of the
    # node alone, so a subtree shared under many parents is rewritten once.
    out = _rewrite_json(node; leaves = false) do rw, n
        op = _raw_get(n, "op")
        op_str = op === nothing ? "" : string(op)
        if op_str == APPLY_EXPRESSION_TEMPLATE_OP
            b = _raw_get(n, "bindings")
            (b === nothing || !_is_object(b)) && return n
            nb = _rewrite_json_children(rw, b)
            nb === b && return n
            nn = OrderedDict{String, Any}(
                string(k) => (string(k) == "bindings" ? nb : v) for (k, v) in pairs(n)
            )
            d = get(L.depth, n, nothing)
            d === nothing || (L.depth[nn] = d)
            return nn
        end
        for rule in L.match_rules
            bindings = Dict{String, Any}()
            if _match_pattern(rule.pattern, n, rule.params, bindings, bv) &&
                    _where_satisfied(rule.where_clause, bindings, L.shape_env, bv)
                last[] = rule.name
                changed[] = true
                r = _rule_reference(rule, bindings)
                _is_apply_node(r) && (L.depth[r] = pass)
                return r
            end
        end
        return _JSON_DESCEND
    end
    return (out, changed[])
end

"""
    _rewrite_to_fixpoint(node, L, scope; bv = nothing) -> (rewritten node, productive passes)

Drive [`_rewrite_pass`](@ref) to a fixpoint (esm-spec §9.6.3): repeat pre-order
passes until a pass performs zero rewrites. A rewrite made in pass `p` has
depth `p`; one whose depth would exceed `MAX_REWRITE_PASSES` rejects the file
with `rewrite_rule_nonterminating` (§9.6.4 rule 3, "Rewrite depth"). This bound
— not a static check — is the authoritative termination guard, so a
self-reintroducing rule fails to converge rather than being flagged up front.
"""
function _rewrite_to_fixpoint(
        node, L::_Lowering, scope::String;
        bv::Union{Nothing, _BodyView} = nothing
    )
    last = Ref{String}("")
    current = node
    for pass in 1:(MAX_REWRITE_PASSES + 1)
        current, changed = _rewrite_pass(current, L, pass, last, bv)
        changed || return (current, pass - 1)
    end
    throw(
        ExpressionTemplateError(
            ERROR_CODES.REWRITE_RULE_NONTERMINATING,
            "$scope: expression-template rewriting did not converge within " *
                "MAX_REWRITE_PASSES=$MAX_REWRITE_PASSES passes (last rule fired " *
                "'$(last[])'). A `match` rule likely re-introduces its own pattern " *
                "(esm-spec §9.6.3)."
        )
    )
end

# ---------------------------------------------------------------------------
# Scan utilities
# ---------------------------------------------------------------------------

# The JSON pointer of every `apply_expression_template` node in `x`, under
# `path`, in document order.
function _find_apply_paths!(hits::Vector{String}, x, path::String)
    _visit_json(x; path = path) do _, n, ptr
        _is_apply_node(n) && push!(hits, string(ptr))
        return true
    end
    return hits
end

_has_apply_op(x) = _visit_json((_, n) -> _is_apply_node(n) ? _JSON_STOP : true, x)

"""
    _has_template_machinery(raw_data) -> Bool

True if `raw_data` either declares any non-empty `expression_templates`
block under `models`/`reaction_systems`, or contains any
`apply_expression_template` op anywhere in the tree. Used by
[`lower_expression_templates`](@ref) to short-circuit on files that need
no template expansion (returned unchanged, by identity).
"""
function _has_template_machinery(raw_data)
    raw_data === nothing && return false
    _is_object(raw_data) || return false
    for (_, _, comp) in _components(raw_data)
        tpl = _raw_get(comp, "expression_templates")
        _is_object(tpl) && !isempty(tpl) && return true
    end
    return _has_apply_op(raw_data)
end

# ---------------------------------------------------------------------------
# Post-expansion validation (esm-spec §9.6.4)
# ---------------------------------------------------------------------------

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
function _validate_makearray_regions(x, path::String = "")
    _visit_json(x; path = path) do key, n, ptr
        # Template bodies and matches are pre-substitution trees, whose bounds
        # may carry metaparameter names or fold later (esm-spec §9.7.6).
        key == "expression_templates" && return false
        _is_object(n) || return true
        op = _raw_get(n, "op")
        (op !== nothing && string(op) == "makearray") || return true
        regions = _raw_get(n, "regions")
        (regions !== nothing && _is_array(regions)) || return true
        for (ri, region) in enumerate(regions)
            _is_array(region) || continue
            for (di, bounds) in enumerate(region)
                (_is_array(bounds) && length(bounds) == 2) || continue
                lo, hi = bounds[1], bounds[2]
                (
                    lo isa Integer && !(lo isa Bool) &&
                        hi isa Integer && !(hi isa Bool)
                ) || continue
                hi < lo - 1 && throw(
                    ExpressionTemplateError(
                        ERROR_CODES.MAKEARRAY_REGION_INVERTED,
                        "$(string(ptr)): makearray regions[$(ri - 1)] dimension $(di - 1) " *
                            "bound pair [$lo, $hi] is inverted (stop < start - 1). " *
                            "An empty bound is spelled [start, start-1] and " *
                            "contributes no elements (esm-spec §4.3.2); a further-" *
                            "inverted pair is an authoring error — e.g. an interior " *
                            "stencil region [2, N-1] instantiated at N below the " *
                            "scheme's minimum extent (§9.6.8)."
                    )
                )
            end
        end
        return true
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
    for named in registries
        for (tname, decl) in named
            body = _raw_get(decl, "body")
            body === nothing && continue
            _validate_makearray_regions(
                body,
                "expression_templates.$tname/body"
            )
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
files declaring `esm` < 0.4.0, with `apply_expression_template_version_too_old`
naming every offending path. The rule is the `expression_templates` row of
[`_VERSION_GATES`](@ref).
"""
reject_expression_templates_pre_v04(raw_data) =
    _check_version_gate(_VERSION_GATES.expression_templates, raw_data)

# ---------------------------------------------------------------------------
# Canonical arithmetic-operand literal narrowing (CONFORMANCE_SPEC §5.5.3.1)
# ---------------------------------------------------------------------------

"""
    _int64_narrowable(v) -> Bool

True iff `v` is a float whose value is an integer in `Int64` range
([`_as_int64`](@ref), CONFORMANCE_SPEC §5.5.3.1 rule 1), the rule
`expression_from_json` applies at the AST-literal boundary.
"""
_int64_narrowable(v) = v isa AbstractFloat && _as_int64(v) !== nothing

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
→ canonical sorted write) never runs `expression_from_json`, so without this pass a
widened `1.0`/`8.0` would reach the emitted golden, which spells `[1,8]`.

Narrowing is scoped to `args` array elements (the Expression operand position),
so scalar CONFIGURATION floats an authored `1.0`/`0.0` legitimately occupies
(`variables.*.default`, a bare `expression` scalar, …) are left as written;
only arithmetic operand literals are touched. On the typed-load path this is a
no-op-equivalent: `coerce_esm_file` reads operands via `expression_from_json`, which
applies the identical narrowing, so pre-narrowing the tree here changes nothing
downstream. The §5.4.6 canonical AST form (`canonical_json`/`wire_to_expr`),
which deliberately preserves an authored `1.0`, is on a separate path and is
untouched.
"""
function _narrow_arg_literals!(x)
    # Narrowing is idempotent and local to the value, so visiting a shared
    # object once is the same as visiting it under each of its parents.
    _visit_json(x) do _, n
        _is_object(n) || return true
        args = _raw_get(n, "args")
        if args isa AbstractVector
            for i in eachindex(args)
                vi = args[i]
                _int64_narrowable(vi) && (args[i] = Int64(vi))
            end
        end
        return true
    end
    return x
end

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

"""
    _hoist_mounted_templates!(comp, cname)

Merge into the component `comp`'s `expression_templates` block the template
definitions that models mounted as its subsystems (esm-spec §4.7) brought
with them. A mounted model keeps its references (the mount does not expand
them) and its match-less definitions, already closed in its own file, on its
own `expression_templates` block. Each such block joins `comp`'s by the rule
flatten uses to merge component registries (`_merge_flat_registry`):
deep-equal entries are kept once, and a name two non-equal entries share is
renamed to `<owner path>.<name>`, one entry per distinct definition (named
after its first owner), with each owner's references renamed in lockstep. The
owner path of `comp`'s own entries is `cname`, of a mounted block its
subsystem path below `comp` (`Sub` or `Sub.Inner`).

A mounted body keeps the mounted model's own names: its free names are read in
the scope of the subsystem that owns the reference, as an authored body's are
at its call site (esm-spec §9.6.4 rule 1). So a leaf mounted twice brings two
identical blocks, which keep one definition. The mounted subtree below the
mount point keeps naming its own entries; only `comp`'s other sites follow
`comp`'s renames.
"""
function _hoist_mounted_templates!(comp::AbstractDict, cname::String)
    mounts = Tuple{String, Any}[]          # (subsystem path, subsystem)
    _collect_mounted_blocks!(mounts, comp, "")
    isempty(mounts) && return comp
    newblock, rn = _merge_mounted_blocks(_raw_get(comp, "expression_templates"), cname, mounts)
    # `comp`'s own sites, outside the mount points.
    if rn !== nothing
        for k in collect(keys(comp))
            k in ("expression_templates", "subsystems") && continue
            comp[k] = _rename_apply_refs(comp[k], rn)
        end
        _rename_outside_mounts!(comp, rn)
    end
    for (_, sub) in mounts
        delete!(sub, "expression_templates")
    end
    comp["expression_templates"] = newblock
    return comp
end

"""
    _merge_mounted_blocks(own, cname, mounts) -> (block, own_rename)

The merge `_hoist_mounted_templates!` describes, shared with the typed mount
path (`resolve_subsystem_refs!`): the component `cname`'s registry `own` (raw,
or `nothing`) and each mounted raw model of `mounts` (`(path, model)`, the
model still carrying its `expression_templates`) merged by flatten's rule.
Each mounted model's own references are renamed here, in place; the caller
applies `own_rename` (old name => new name, or `nothing`) to the component's
other sites. `own`'s `match` rules are kept, ahead of the merged entries.
"""
function _merge_mounted_blocks(own, cname::String, mounts)
    blocks = OrderedDict{String, Any}()
    blocks["models.$cname"] = OrderedDict{String, Any}(
        string(n) => d for (n, d) in pairs(_is_object(own) ? own : Dict{String, Any}())
            if _raw_get(d, "match") === nothing
    )
    for (path, sub) in mounts
        blocks["models.$path"] = OrderedDict{String, Any}(
            string(n) => d for (n, d) in pairs(_raw_get(sub, "expression_templates"))
                if _raw_get(d, "match") === nothing
        )
    end
    merged, rename = _merge_flat_registry(blocks)
    for (path, sub) in mounts
        rm = get(rename, path, nothing)
        rm === nothing && continue
        for k in collect(keys(sub))
            k == "expression_templates" && continue
            sub[k] = _rename_apply_refs(sub[k], rm)
        end
    end
    rn = get(rename, cname, nothing)
    newblock = OrderedDict{String, Any}()
    if _is_object(own)
        for (n, d) in pairs(own)
            _raw_get(d, "match") === nothing && continue
            newblock[string(n)] = rn === nothing ? d : _rename_apply_refs(d, rn)
        end
    end
    merge!(newblock, merged)
    return newblock, rn
end

# The subsystems below `node` that carry a mounted block, with their paths;
# a mount point's own subtree is its block's (it was merged when that model
# was lowered in its own file), so the walk stops there.
function _collect_mounted_blocks!(out, node, prefix::String)
    subs = _raw_get(node, "subsystems")
    _is_object(subs) || return out
    for (k, sub) in pairs(subs)
        _is_object(sub) || continue
        path = isempty(prefix) ? string(k) : "$prefix.$(k)"
        blk = _raw_get(sub, "expression_templates")
        if _is_object(blk)
            push!(out, (path, sub))
        else
            _collect_mounted_blocks!(out, sub, path)
        end
    end
    return out
end

# `comp`'s subsystems with the references outside every mount point renamed
# by `rn`.
function _rename_outside_mounts!(node, rn)
    subs = _raw_get(node, "subsystems")
    _is_object(subs) || return
    for (_, sub) in pairs(subs)
        _is_object(sub) || continue
        _is_object(_raw_get(sub, "expression_templates")) && continue
        for k in collect(keys(sub))
            k == "subsystems" && continue
            sub[k] = _rename_apply_refs(sub[k], rn)
        end
        _rename_outside_mounts!(sub, rn)
    end
    return
end

"""
    lower_expression_templates(raw_data) -> OrderedDict{String,Any}

Run the §9.6.3 rewrite fixpoint over `raw_data` against each component-local
`expression_templates` block (esm-spec §9.6.4, Option B): auto `match` rules
fire, EAGER (target-bearing) `apply_expression_template` references are
expanded, NON-EAGER references survive as leaves, and each component's
registered `expression_templates` block is RETAINED on the returned tree. The
output is the rewritten native `OrderedDict{String,Any}` document, ready for
`coerce_esm_file`. A file with no template machinery is returned UNCHANGED
(the same object, by identity — callers use that to detect the fast path).

Throws [`ExpressionTemplateError`](@ref) on any of:

- file declares `esm` < 0.4.0 but uses templates
- `apply_expression_template` references an undeclared template name, or a
  `match` rewrite rule (only match-less templates are invocable by name)
- bindings do not exactly match the template's `params`
- template-body references form a cycle or exceed
  `MAX_TEMPLATE_EXPANSION_DEPTH` (nested body references themselves are legal,
  esm-spec §9.7.3)
- the `match`-rule fixpoint fails to converge within `MAX_REWRITE_PASSES`
- declaration is malformed (params missing, body missing, etc.)
"""
function lower_expression_templates(raw_data)
    reject_expression_templates_pre_v04(raw_data)

    # Fast path: files that neither declare `expression_templates` blocks
    # nor use any `apply_expression_template` op need no expansion at all.
    # Return raw_data unchanged — BY IDENTITY, which is the discriminator
    # `_lower_and_coerce` / `emit_document` use to tell the fast path from a
    # processed document.
    if !_has_template_machinery(raw_data)
        # No expansion to run, but the §9.6.4 expanded-form validator still
        # applies — the raw tree IS the expanded form.
        _validate_makearray_regions(raw_data)
        return raw_data
    end

    root = _to_ordered(raw_data)::OrderedDict{String, Any}

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

    # Per-component rewrite state, captured so coupling `variable_map`
    # expression transforms (esm-spec §10.4) can be rewritten against the
    # RECEIVING component's rules below. Models are registered first; a
    # reaction system never overwrites a same-named model.
    enums = _raw_get(root, "enums")
    lowerings = Tuple{Any, _Lowering, Vector{Any}}[]
    by_name = Dict{String, Int}()

    for (compkind, cname, compraw) in _components(root)
        comp = compraw::OrderedDict{String, Any}
        # A model mounted as a subsystem keeps its references and brings its
        # template definitions; they join this component's registry here.
        _hoist_mounted_templates!(comp, cname)
        # Static shape environment for `where` constraint evaluation
        # (esm-spec §9.6.1): declared variable shapes only.
        shape_env = _component_shape_env(comp)
        tplraw = get(comp, "expression_templates", nothing)
        # `named`       — every template keyed by name, consulted by
        #                 `apply_expression_template` (order-independent).
        # `match_rules` — the auto-applied `match` rules, in template
        #                 DECLARATION order (esm-spec §9.6.3).
        named = Dict{String, Any}()
        match_rules = _RewriteRule[]
        if _is_object(tplraw)
            # `root` is order-preserving (`_to_ordered`), so this map's key
            # order IS the authored declaration order — the `match`-rule
            # precedence tie-break (esm-spec §9.6.3) reads straight off it.
            templates = OrderedDict{String, Any}()
            for (tname, tdecl) in pairs(tplraw)
                templates[string(tname)] = tdecl
            end
            _validate_templates(templates, "$compkind.$cname")
            # Registration-time body CHECKING (esm-spec §9.7.3, Option B):
            # validate the body-reference DAG (acyclic, depth-bounded,
            # references resolve to match-less templates). Bodies are NOT
            # inlined — references are preserved (§9.6.4).
            _check_template_body_graph(templates, "$compkind.$cname")
            decl_index = 0
            for (tname, decl) in templates
                decl_index += 1
                named[tname] = decl
                td = _TemplateDecl(decl)
                m = td.match
                if m !== nothing
                    # `where` registration: normalize constraints and
                    # resolve every referenced index-set name against the
                    # consuming document's registry (esm-spec §9.6.1;
                    # `template_constraint_unknown_index_set`).
                    where_c = _registered_where(
                        decl, iset_names,
                        "$compkind.$cname", tname
                    )
                    push!(
                        match_rules,
                        _RewriteRule(
                            tname, m, Set{String}(td.params), String[td.params...], td.body,
                            _rule_priority(decl), decl_index, where_c
                        )
                    )
                end
            end
            # Deterministic selection order (esm-spec §9.6.3): highest
            # `priority` first, ties broken by declaration order (earliest
            # wins). `_rewrite_pass` then takes the FIRST matching rule.
            sort!(match_rules, by = r -> (-r.priority, r.decl_index))
        end
        cscope = "$compkind.$cname"
        L = _Lowering(named, match_rules, shape_env, enums, cscope, IdDict{Any, Int}())
        # Outermost-first, priority-ordered, bounded-fixpoint rewrite per
        # non-template field (esm-spec §9.6.3): each firing writes a reference
        # to its rule (constraint 7); references are leaves for matching and
        # the walk descends into their bindings (§9.6.4 rule 4).
        for k in collect(keys(comp))
            k == "expression_templates" && continue
            comp[k], _ = _rewrite_to_fixpoint(comp[k], L, "$cscope.$k")
        end
        push!(lowerings, (comp, L, Any[]))
        haskey(by_name, cname) || (by_name[cname] = length(lowerings))
    end

    # Coupling `variable_map` expression transforms (esm-spec §10.4/§10.5) are
    # rewritten against the rules of the component that owns the entry's `to`
    # target — the receiving component, where a regridding library import
    # (§9.7) lives — exactly as a field of that component would be.
    for (i, entry, tr, comp_name) in _variable_map_transforms(root)
        idx = get(by_name, comp_name, nothing)
        idx === nothing && continue
        _, L, transforms = lowerings[idx]
        entry["transform"], _ = _rewrite_to_fixpoint(tr, L, "coupling[$(i)].transform")
        push!(transforms, entry)
    end

    # esm-spec §9.6.4 rule 3: the rules apply inside the bodies of the templates
    # the references reach, once per template instance, without expanding any
    # reference. esm-spec §9.6.4 rule 1 (Option B): the component's
    # `expression_templates` block is RETAINED — the registry emit
    # materializes (§9.6.4 rule 5) and Expand consumes (§9.6.4 rule 2).
    for (comp, L, transforms) in lowerings
        _apply_rule3!(comp, L, transforms)
        # Call-site checks on surviving references (§9.6.9): unknown name /
        # bindings mismatch, against the registry as rule 3 left it.
        for k in collect(keys(comp))
            k == "expression_templates" && continue
            _check_surviving_refs(comp[k], L.named, "$(L.scope).$k")
        end
        for entry in transforms
            _check_surviving_refs(entry["transform"], L.named, "$(L.scope) coupling transform")
        end
    end

    # Validation discharge (esm-spec §9.6.9): the makearray-region check on the
    # reference-preserving form. Region bounds cannot carry template params, so
    # it runs on the reference-preserving tree AND the retained folded template
    # bodies directly.
    _validate_makearray_regions(root)
    _validate_makearray_regions_in_registries(L.named for (_, L, _) in lowerings)

    # Canonical arithmetic-operand literal narrowing (CONFORMANCE_SPEC §5.5.3.1
    # rule 1); see `_narrow_arg_literals!`.
    _narrow_arg_literals!(root)

    return root
end
