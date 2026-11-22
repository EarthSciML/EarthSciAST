# Rewriting inside template bodies, once per template instance (esm-spec §9.6.4
# rule 3). After a component's expression positions reach their §9.6.3
# fixpoint (where every firing wrote a reference, constraint 7), the component's
# rules, and its `enum` lowering, apply inside the bodies of the templates its
# references reach — without expanding any reference.
#
# An instance is a template plus, per parameter, the literal bound to it when the
# parameter sits in a structural position of the body, and otherwise the kind of
# what is bound (a bare variable with its declared shape, a literal, any other
# expression). Each instance's body is rewritten once; inside it a parameter is a
# leaf (`_BodyView`). When every reachable instance of a template rewrites to the
# same body, that body replaces the template's in place — unless a registry entry
# rule 3 leaves as authored still references the template, directly or through
# such entries; otherwise each distinct body becomes `<name>.variant<k>`, numbered
# by canonical bytes, and every reference is re-pointed to the entry of its
# instance.

# ---------------------------------------------------------------------------
# Canonical bytes (CONFORMANCE_SPEC §5.5.3): compact JSON, keys sorted
# ---------------------------------------------------------------------------

"""
    _canonical_compact(x) -> String

The canonical byte form of a raw JSON value (CONFORMANCE_SPEC §5.5.3): compact
(`,` and `:` separators), object keys sorted by UTF-8 bytes, integral
Int64-representable floats written as integers (§5.5.3.1 rule 1), other
numbers as JSON3 writes them. Orders the variants of §9.6.4 rule 3.
"""
function _canonical_compact(x)::String
    io = IOBuffer()
    _canonical_write(io, x)
    return String(take!(io))
end

function _canonical_write(io::IO, x)
    if _is_object(x)
        ks = sort!(String[string(k) for (k, _) in pairs(x)])
        print(io, "{")
        for (i, k) in enumerate(ks)
            i > 1 && print(io, ",")
            print(io, JSON3.write(k), ":")
            _canonical_write(io, _raw_get(x, k))
        end
        print(io, "}")
    elseif _is_array(x)
        print(io, "[")
        for (i, v) in enumerate(x)
            i > 1 && print(io, ",")
            _canonical_write(io, v)
        end
        print(io, "]")
    elseif x isa AbstractFloat && _as_int64(x) !== nothing
        print(io, _as_int64(x))
    else
        print(io, JSON3.write(x))
    end
    return
end

# ---------------------------------------------------------------------------
# Instances
# ---------------------------------------------------------------------------

# The instance entry of a bare variable with declared shape `shape`.
_shape_entry(shape) = "V" * _canonical_compact(shape)

# Fields whose value is an Expression (an operand position): a parameter
# string there is an operand; anywhere else it is structural.
const _OPERAND_FIELDS = ("expr", "filter", "key", "lower", "upper")
const _OPERAND_LIST_FIELDS = ("args", "values")

"""
    _structural_params(body, params) -> Set{String}

The parameters of a template that occur in a structural position of `body`
(esm-spec §9.6.4 rule 3): anywhere but an operand position — a scalar field
(`wrt`, `dim`, `fn`, …), a `ranges` bound or `from`, an `enum` argument. An
operand position is an element of `args` or `values` (but not an `enum` op's
`args`), the value of `expr`, `filter`, `key`, `lower` or `upper`, a value of a
nested reference's `bindings`, or the body itself.
"""
function _structural_params(body, params)::Set{String}
    P = Set{String}(params)
    out = Set{String}()
    _structural_walk!(out, body, P, true)
    return out
end

function _structural_walk!(out::Set{String}, x, P::Set{String}, operand::Bool)
    if x isa AbstractString
        (!operand && String(x) in P) && push!(out, String(x))
    elseif _is_array(x)
        for v in x
            _structural_walk!(out, v, P, operand)
        end
    elseif _is_object(x)
        op = _raw_get(x, "op")
        ops = op === nothing ? "" : string(op)
        for (k, v) in pairs(x)
            ks = string(k)
            if ks == "op" || (ks == "name" && ops == APPLY_EXPRESSION_TEMPLATE_OP)
                continue
            elseif ks == "bindings" && ops == APPLY_EXPRESSION_TEMPLATE_OP && _is_object(v)
                for (_, bvv) in pairs(v)
                    _structural_walk!(out, bvv, P, true)
                end
            elseif ks in _OPERAND_LIST_FIELDS && ops != "enum"
                _structural_walk!(out, v, P, true)
            elseif ks in _OPERAND_FIELDS
                _structural_walk!(out, v, P, true)
            else
                _structural_walk!(out, v, P, false)
            end
        end
    end
    return out
end

"""
    _instance_entry(v, structural, L, bv) -> (entry, literal)

The instance entry (esm-spec §9.6.4 rule 3) for one parameter bound to `v`:
inside a body (`bv`), a binding that is one of the body's own parameters
forwards the enclosing instance's entry; a structural parameter takes the
literal bound (`"L" * canonical bytes`); otherwise the kind — `"V" * shape` for
a bare variable with a declared shape, `"V"` for one without, `"N"` for a
number or boolean literal, `"E"` for any other expression. `literal` is the
value a structural position reads, or `_NO_LIT`.
"""
function _instance_entry(v, structural::Bool, L::_Lowering, bv::Union{Nothing, _BodyView})
    if v isa AbstractString && bv !== nothing && String(v) in bv.params
        return (bv.entries[String(v)], get(bv.lit, String(v), _NO_LIT))
    end
    if structural
        (v isa AbstractString || v isa Number || v isa Bool) &&
            return ("L" * _canonical_compact(v), v)
        return ("E", _NO_LIT)
    end
    if v isa AbstractString
        shp = get(L.shape_env, String(v), nothing)
        return (shp === nothing ? "V" : _shape_entry(shp), _NO_LIT)
    end
    (v isa Number || v isa Bool) && return ("N", _NO_LIT)
    return ("E", _NO_LIT)
end

# One rewritten template instance: the template's `name`, the body as rule 3
# rewrote it (references not yet re-pointed to variants), the instance key of
# every reference in that body (by node identity), and its height — the deepest
# rewrite depth below the reference that names it (own passes, or a written
# reference's pass plus the height of the instance it names).
struct _InstanceResult
    key::String
    name::String
    body::Any
    refs::IdDict{Any, String}
    height::Int
end

mutable struct _Rule3State
    L::_Lowering
    done::Dict{String, _InstanceResult}
    active::Vector{String}
    structural::Dict{String, Set{String}}
    order::Vector{String}
end

_Rule3State(L::_Lowering) =
    _Rule3State(L, Dict{String, _InstanceResult}(), String[], Dict{String, Set{String}}(), String[])

# The structural parameters of template `name` (`_structural_params`), plus
# each parameter forwarded whole into a structural parameter of a template its
# body references (transitively): through the reference the parameter reaches
# a structural position of the expansion.
function _template_structural!(st::_Rule3State, name::String, decl)
    r = get(st.structural, name, nothing)
    r === nothing || return r
    td = _TemplateDecl(decl)
    S = _structural_params(td.body, td.params)
    st.structural[name] = S          # a cycle reads the direct set
    P = Set{String}(td.params)
    _visit_json(td.body) do _, n
        _is_apply_node(n) || return true
        inner = _raw_get(n, "name")
        b = _raw_get(n, "bindings")
        (inner isa AbstractString && _is_object(b)) || return true
        idecl = get(st.L.named, String(inner), nothing)
        idecl === nothing && return true
        IS = _template_structural!(st, String(inner), idecl)
        for (k, v) in pairs(b)
            v isa AbstractString && String(v) in P && string(k) in IS && push!(S, String(v))
        end
        return true
    end
    return S
end

_nonterminating(scope, msg) = throw(
    ExpressionTemplateError(ERROR_CODES.REWRITE_RULE_NONTERMINATING, "$scope: $msg (esm-spec §9.6.4 rule 3)")
)

"""
    _ref_instance!(st, n, bv, scope) -> _InstanceResult

The rewritten instance a reference `n` names, computed once per instance. A
reference the author wrote must name a match-less template (§9.6.2); one a
firing wrote (it has a depth) names its rule. `bv` is the enclosing body's
view when `n` sits in a template body, `nothing` at a call site.
"""
function _ref_instance!(st::_Rule3State, n, bv::Union{Nothing, _BodyView}, scope::String)
    written = haskey(st.L.depth, n)
    name, decl, b = _resolve_apply_site(n, st.L.named, scope; reject_match_rule = !written)
    params = _TemplateDecl(decl).params
    S = _template_structural!(st, name, decl)
    entries = String[]
    lits = Dict{String, Any}()
    for p in params
        e, l = _instance_entry(_raw_get(b, p), p in S, st.L, bv)
        push!(entries, e)
        l === _NO_LIT || (lits[p] = l)
    end
    return _instance!(st, name, decl, params, entries, lits)
end

function _instance!(
        st::_Rule3State, name::String, decl, params::Vector{String},
        entries::Vector{String}, lits::Dict{String, Any}
    )
    key = join([name; entries], '\x1f')
    r = get(st.done, key, nothing)
    r === nothing || return r
    tscope = "$(st.L.scope).expression_templates.$name"
    key in st.active && _nonterminating(
        tscope,
        "rewriting template '$name' needs the same template instance again — a `match` " *
            "rule re-introduces its own pattern through the template's body"
    )
    push!(st.active, key)
    bv = _BodyView(Set{String}(params), lits, Dict{String, String}(zip(params, entries)))
    body = _raw_get(decl, "body")
    body = _lower_body_enums(body, bv, st.L.enums)
    body = _instance_partial(body, bv)
    rewritten, passes = _rewrite_to_fixpoint(body, st.L, tscope; bv = bv)
    refs = IdDict{Any, String}()
    height = passes
    _visit_json(rewritten) do _, n
        _is_apply_node(n) || return true
        child = _ref_instance!(st, n, bv, tscope)
        refs[n] = child.key
        height = max(height, get(st.L.depth, n, 0) + child.height)
        return true
    end
    height > MAX_REWRITE_PASSES && _nonterminating(
        tscope,
        "a rewrite inside template '$name' has depth $height, beyond MAX_REWRITE_PASSES=" *
            "$MAX_REWRITE_PASSES (depth counts through template bodies)"
    )
    pop!(st.active)
    res = _InstanceResult(key, name, rewritten, refs, height)
    st.done[key] = res
    push!(st.order, key)
    return res
end

"""
    _instance_partial(body, bv) -> body′

esm-spec §4.2 "Reading earlier documents": a `D` whose `wrt` is one of the
definition's `params` is decided per instance — where the instance binds that
parameter to an axis name other than `"t"`, the `D` reads as `partial` in this
instance (the wire boundary left it as written). Bound to `"t"`, it stays the
time derivative.
"""
function _instance_partial(body, bv::_BodyView)
    return _rewrite_json(body; leaves = false) do rw, n
        _raw_get(n, "op") == "D" || return _JSON_DESCEND
        w = _raw_get(n, "wrt")
        (w isa AbstractString && String(w) in bv.params) || return _JSON_DESCEND
        lit = get(bv.lit, String(w), _NO_LIT)
        (lit isa AbstractString && lit != "t") || return _JSON_DESCEND
        nn = _rewrite_json_children(rw, n)
        n2 = OrderedDict{String, Any}(string(k) => v for (k, v) in pairs(nn))
        n2["op"] = "partial"
        return n2
    end
end

"""
    _lower_body_enums(body, bv, enums) -> body′

The `enum` lowering of esm-spec §9.3 applied inside a template body for one
instance (§9.6.4 rule 3): an `enum` op whose two arguments are strings, or
parameters the instance binds to strings, becomes its `const`; one still
spelled with an unbound parameter stays as written.
"""
function _lower_body_enums(body, bv::_BodyView, enums)
    return _rewrite_json(body; leaves = false) do _, n
        _raw_get(n, "op") == "enum" || return _JSON_DESCEND
        args = _raw_get(n, "args")
        (args !== nothing && _is_array(args) && length(args) == 2) || return n
        resolved = Any[
            (a isa AbstractString && String(a) in bv.params) ? get(bv.lit, String(a), _NO_LIT) : a
                for a in args
        ]
        all(a -> a isa AbstractString, resolved) || return n
        n2 = OrderedDict{String, Any}(string(k) => v for (k, v) in pairs(n))
        n2["args"] = resolved
        return _lower_enum_op(n2, enums, Set{String}())
    end
end

# `x` with every reference re-pointed to the entry its instance was given:
# `refs` maps a reference node (by identity) to its instance key, `final` an
# instance key to the registry name its body lives under.
function _repoint_refs(x, refs::IdDict{Any, String}, final::Dict{String, String})
    return _rewrite_json(x; leaves = false) do rw, n
        _is_apply_node(n) || return _JSON_DESCEND
        key = get(refs, n, nothing)
        nn = _rewrite_json_children(rw, n; keep = "name")
        newname = key === nothing ? nothing : final[key]
        (newname === nothing || newname == string(_raw_get(n, "name"))) && return nn
        out = OrderedDict{String, Any}(string(k) => v for (k, v) in pairs(nn))
        out["name"] = newname
        return out
    end
end

# The template-level order in which instances are named: a template after every
# template its instances' bodies reference. A cycle is a rule that re-introduces
# itself through a template body.
function _rule3_template_order(st::_Rule3State, by_template)
    deps = Dict{String, Vector{String}}()
    for (t, keys_t) in by_template
        ds = String[]
        for k in keys_t
            for (_, ck) in st.done[k].refs
                push!(ds, st.done[ck].name)
            end
        end
        deps[t] = unique!(ds)
    end
    order = String[]
    state = Dict{String, Int}()
    function visit(t)
        s = get(state, t, 0)
        s == 2 && return
        s == 1 && _nonterminating(
            st.L.scope, "template '$t' reaches itself through the references rules wrote in template bodies"
        )
        state[t] = 1
        for d in deps[t]
            visit(d)
        end
        state[t] = 2
        push!(order, t)
        return
    end
    for t in keys(by_template)
        visit(t)
    end
    return order
end

# The templates whose reached instances rewrite to more than one distinct body.
# Naming each single-bodied template in place or as `<name>.variant1` renames
# every reference to it alike, so which bodies are distinct does not depend on
# that choice: this provisional pass names every single-bodied template in place.
function _rule3_multi(st::_Rule3State, by_template, order)
    final = Dict{String, String}()
    multi = Set{String}()
    for t in order
        keys_t = by_template[t]
        canon = String[
            _canonical_compact(_repoint_refs(st.done[k].body, st.done[k].refs, final))
                for k in keys_t
        ]
        distinct = sort!(unique(canon))
        if length(distinct) == 1
            for k in keys_t
                final[k] = t
            end
        else
            push!(multi, t)
            for (k, c) in zip(keys_t, canon)
                final[k] = "$t\x1f$(findfirst(==(c), distinct))"
            end
        end
    end
    return multi
end

# The reached match-less templates whose authored body stays reachable from a
# registry entry that rule 3 does not rewrite under its own name (esm-spec
# §9.6.4 rule 3): a match-less entry no reference reaches, one whose instances
# took variants, and, transitively, any reached template such an entry
# references. Such a template keeps its authored body; a single rewritten body
# is registered as `<name>.variant1` instead.
function _rule3_exposed(st::_Rule3State, by_template, order)
    named = st.L.named
    matchless(n) = (d = get(named, n, nothing); _is_object(d) && _raw_get(d, "match") === nothing)
    memo = Dict{String, Set{String}}()
    refs_of(n) = get!(memo, n) do
        Set{String}(
            x for x in _collect_apply_names!(String[], _raw_get(named[n], "body"))
                if haskey(by_template, x) && matchless(x)
        )
    end
    stack = String[
        string(n) for n in keys(named) if !haskey(by_template, string(n)) && matchless(string(n))
    ]
    if any(t -> matchless(t) && !isempty(refs_of(t)), keys(by_template))
        append!(stack, (t for t in _rule3_multi(st, by_template, order) if matchless(t)))
    end
    visible = Set{String}()
    while !isempty(stack)
        n = pop!(stack)
        for r in refs_of(n)
            r in visible && continue
            push!(visible, r)
            push!(stack, r)
        end
    end
    return visible
end

# A materialized entry: the rule (or variant) without its `match`, `where` and
# `priority`, marked `reference_only` (esm-spec §9.6.1, §9.6.4 rule 5) so that
# reloading the emitted document makes it no callable definition of its
# operator: emit → load → emit is exact.
function _match_stripped(decl)
    nd = OrderedDict{String, Any}(
        string(k) => v for (k, v) in pairs(decl) if !(string(k) in ("match", "where", "priority"))
    )
    nd["reference_only"] = true
    return nd
end

"""
    _apply_rule3!(comp, L, transforms)

Esm-spec §9.6.4 rule 3 for one component whose expression positions (and the
coupling `transforms` it receives, `variable_map` entries) have reached the
§9.6.3 fixpoint: rewrite the body of every template instance their references
reach, place each result (in place, or as `<name>.variant<k>`), re-point the
references, materialize each referenced `match` rule without its `match`,
`where` and `priority`, and check the rewrite depth of every call site.
"""
function _apply_rule3!(comp, L::_Lowering, transforms)
    st = _Rule3State(L)
    site_refs = IdDict{Any, String}()
    fields = String[string(k) for k in keys(comp) if string(k) != "operators"]
    sites = Any[(comp, k) for k in fields]
    for e in transforms
        push!(sites, (e, "transform"))
    end
    for (holder, k) in sites
        scope = holder === comp ? "$(L.scope).$k" : "$(L.scope) coupling transform"
        _visit_json(holder[k]) do _, n
            _is_apply_node(n) || return true
            res = _ref_instance!(st, n, nothing, scope)
            site_refs[n] = res.key
            d = get(L.depth, n, 0) + res.height
            d > MAX_REWRITE_PASSES && _nonterminating(
                scope,
                "a rewrite through template '$(res.name)' has depth $d, beyond " *
                    "MAX_REWRITE_PASSES=$MAX_REWRITE_PASSES (depth counts through template bodies)"
            )
            return true
        end
    end
    isempty(st.order) && return comp

    by_template = OrderedDict{String, Vector{String}}()
    for k in st.order
        push!(get!(by_template, st.done[k].name, String[]), k)
    end
    final = Dict{String, String}()
    block = get!(comp, "operators") do
        OrderedDict{String, Any}()
    end
    taken = Set{String}(keys(L.named))
    order = _rule3_template_order(st, by_template)
    exposed = _rule3_exposed(st, by_template, order)
    for t in order
        keys_t = by_template[t]
        bodies = Any[_repoint_refs(st.done[k].body, st.done[k].refs, final) for k in keys_t]
        canon = String[_canonical_compact(b) for b in bodies]
        distinct = sort!(unique(canon))
        decl = L.named[t]
        if length(distinct) == 1 &&
                !(t in exposed && distinct[1] != _canonical_compact(_raw_get(decl, "body")))
            for k in keys_t
                final[k] = t
            end
            nd = _raw_get(decl, "match") === nothing ?
                OrderedDict{String, Any}(string(k) => v for (k, v) in pairs(decl)) :
                _match_stripped(decl)
            if distinct[1] != _canonical_compact(_raw_get(decl, "body"))
                nd["body"] = bodies[1]
            elseif _raw_get(decl, "match") === nothing
                continue
            end
            L.named[t] = nd
            block[t] = nd
        else
            names = Dict{String, String}()
            for (i, c) in enumerate(distinct)
                vn = "$t.variant$i"
                while vn in taken
                    vn *= "_"
                end
                push!(taken, vn)
                names[c] = vn
                nd = _match_stripped(decl)
                nd["body"] = bodies[findfirst(==(c), canon)]
                L.named[vn] = nd
                block[vn] = nd
            end
            for (k, c) in zip(keys_t, canon)
                final[k] = names[c]
            end
        end
    end
    for (holder, k) in sites
        holder[k] = _repoint_refs(holder[k], site_refs, final)
    end
    return comp
end
