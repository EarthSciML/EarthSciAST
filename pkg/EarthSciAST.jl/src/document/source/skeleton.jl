"""
The document skeleton: front matter, description, path blocks, and one section
per model or reaction system, with the path-keyed fallback for every field
without a native surface.

Port of `formal/Esm/Document/Source/Skeleton.lean` (Rust
`document::source::skeleton`). The mapping is total: every field a container
cannot spell natively falls back to a block keyed by its JSON path relative to
the enclosing section. [`Caps`](@ref) are the container's predicates saying
which values it spells natively.
"""
module SSkeleton

using ..DJson
using ..SKeys: at_, join_field, pick_one, sort_kvs, split_opt
using ..MExpr: Sym, is_e, jwf, keys_sorted

export Kind, K_MODEL, K_RS, DKind, D_VAR, D_PARAM, D_SPECIES, D_SUB, Decl, Eqn,
    Role, R_EQN, R_INIT, R_CONS, Term, Rxn, Tm, Mx, MxEq, MxRxn, MxPlot, MxTm, Comp, Doc,
    Phase, AsRead, AsText, Caps

# ## The canonical form of a document

"""`Source.sortedDeep`: every object, at every depth, has strictly increasing
keys."""
sorted_deep(j::JObj) = keys_sorted(j.kvs) && all(kv -> sorted_deep(kv.second), j.kvs)
sorted_deep(j::JArr) = all(sorted_deep, j.xs)
sorted_deep(::Any) = true

"""`Source.canonDoc`: a JSON object, well formed, with sorted keys at every
depth."""
canon_doc(j) = j isa JObj && jwf(j) && sorted_deep(j)

"""`Source.Kind`: a model or a reaction system."""
@enum Kind K_MODEL K_RS

"""`Source.DKind`: the declaration directives (`D_SUB`: a subsystem included by
reference)."""
@enum DKind D_VAR D_PARAM D_SPECIES D_SUB

"""`Source.Decl`: the directive, the declared name, and the other fields of the
declared object as attributes."""
struct Decl
    kind::DKind
    name::String
    attrs::Kvs
end

"""`Source.Eqn`: `lhs = rhs`, with its optional `_comment`."""
struct Eqn
    comment::Union{Nothing, String}
    lhs::Any
    rhs::Any
end

"""`Source.Role`: the field an equation belongs to."""
@enum Role R_EQN R_INIT R_CONS

"""`Role.field`."""
field(r::Role) = r == R_EQN ? "equations" :
    r == R_INIT ? "initialization_equations" : "constraint_equations"

"""`Source.Term`: a species and its stoichiometric coefficient."""
struct Term
    species::String
    coef::JNum
end

"""`Source.Rxn`: a reaction's `id`, sides (`nothing` for an empty side), rate
(the expression, or its math text) and other fields."""
struct Rxn
    id::String
    subs::Union{Nothing, Vector{Term}}
    prods::Union{Nothing, Vector{Term}}
    rate::Any
    attrs::Kvs
end

"""`Source.Tm`: an entry of `expression_templates`: a template
(`lhs === nothing`) or a rewrite rule (`lhs` the match)."""
struct Tm
    name::String
    params::Vector{String}
    lhs::Any
    body::Any
    attrs::Kvs
end

"""`Source.Mx`: a list entry of a component. As read ([`AsRead`](@ref)) it
holds an `Eqn` and JSON math; as the container's text ([`AsText`](@ref)),
strings. The phase is carried by the [`Comp`](@ref) and [`Doc`](@ref) that
hold the entries."""
abstract type Mx end
struct MxEq <: Mx
    role::Role
    a::Any
end
struct MxRxn <: Mx
    x::Rxn
end
struct MxPlot <: Mx
    a::Kvs
end
struct MxTm <: Mx
    t::Tm
end

"""`Mx.field`."""
field(m::MxEq) = field(m.role)
field(::MxRxn) = "reactions"
field(::MxPlot) = "analyses"
field(::MxTm) = "expression_templates"

"""`Mx.key`."""
key(m::MxTm) = m.t.name
key(::Mx) = ""

"""`Mx.head`: the symbol-table entry of a template or rule."""
head(m::MxTm) = (m.t.name, ps(m.t))
head(::Mx) = nothing

"""`Source.mathFields`."""
const MATH_FIELDS = (
    "analyses", "constraint_equations", "equations", "expression_templates",
    "initialization_equations", "reactions",
)

"""`k ∈ mathFields`."""
is_math_field(k::AbstractString) = k in MATH_FIELDS

"""
The two phases of a skeleton, Lean's `MC` and `MR`: `AsRead`, math as the
document holds it (an `Eqn`, JSON rates and template bodies), and `AsText`,
math as the container's text. [`to_doc`](@ref) makes an `AsRead` skeleton and
`of_doc` takes one; `raw_doc` prints it into an `AsText` one, which `items`
lists; `unitems` reads an `AsText` one and `cook_doc` reads its math back.
A step given the other phase is a `MethodError` at the call.
"""
abstract type Phase end
struct AsRead <: Phase end
struct AsText <: Phase end

"""`Source.Comp`: one component section, in phase `P`."""
struct Comp{P <: Phase}
    kind::Kind
    name::String
    desc::Union{Nothing, String}
    decls::Vector{Decl}
    math::Vector{Any}
    math_blocks::Kvs
    blocks::Kvs
end

"""`Source.Doc`: a document skeleton, in phase `P`."""
struct Doc{P <: Phase}
    front::Kvs
    desc::Union{Nothing, String}
    blocks::Kvs
    math::Vector{Any}
    comps::Vector{Comp{P}}
end

"""`Comp.mapMath`: `f(c, m)` for every math entry, the result in phase `Q`."""
map_math(c::Comp, f, ::Type{Q}) where {Q <: Phase} =
    Comp{Q}(c.kind, c.name, c.desc, c.decls, Any[f(c, m) for m in c.math], c.math_blocks, c.blocks)

# ## Expressions inside path blocks

"""`Notation.Seg.any`: a path segment matching every element of an array and
every value of an object. A `String` segment is `Notation.Seg.key`: the entry
of that key of an object."""
struct SegAny end
const ANY = SegAny()

"""`Notation.Seg.elem`: a path segment matching every element of an array only
(the array form of a field that is one object or an array of them)."""
struct SegElem end
const ELEM = SegElem()

"""`Notation.compExprPaths`: the expression-valued fields of a component's path
blocks, as paths from the block's key (esm-schema.json: `Assertion.reference`,
`ContinuousEvent.conditions`, `AffectEquation.rhs`,
`DiscreteEventTrigger.expression`, `Model.guesses`, `ParameterUpdate.expression`
and `.when`, `DataSourceBinding.unit_conversion` under `ParameterUpdate.from`;
an update is one rule or an array of them). A value there that is a
well-formed expression prints as math (`Source.mathify`)."""
const COMP_EXPR_PATHS = Vector{Any}[
    Any["continuous_events", ANY, "affect_neg", ANY, "rhs"],
    Any["continuous_events", ANY, "affects", ANY, "rhs"],
    Any["continuous_events", ANY, "conditions", ANY],
    Any["discrete_events", ANY, "affects", ANY, "rhs"],
    Any["discrete_events", ANY, "trigger", "expression"],
    Any["guesses", ANY],
    Any["parameters", ANY, "update", "expression"],
    Any["parameters", ANY, "update", "from", "unit_conversion"],
    Any["parameters", ANY, "update", "when"],
    Any["parameters", ANY, "update", ELEM, "expression"],
    Any["parameters", ANY, "update", ELEM, "from", "unit_conversion"],
    Any["parameters", ANY, "update", ELEM, "when"],
    Any["tests", ANY, "assertions", ANY, "reference"],
    Any["variables", ANY, "update", "expression"],
    Any["variables", ANY, "update", "from", "unit_conversion"],
    Any["variables", ANY, "update", "when"],
    Any["variables", ANY, "update", ELEM, "expression"],
    Any["variables", ANY, "update", ELEM, "from", "unit_conversion"],
    Any["variables", ANY, "update", ELEM, "when"],
]

"""`Notation.topExprPaths`: the expression-valued fields of the document's
top-level path blocks (the coupling entries' events and connector
equations)."""
const TOP_EXPR_PATHS = Vector{Any}[
    Any["coupling", ANY, "affect_neg", ANY, "rhs"],
    Any["coupling", ANY, "affects", ANY, "rhs"],
    Any["coupling", ANY, "conditions", ANY],
    Any["coupling", ANY, "connector", "equations", ANY, "expression"],
    Any["coupling", ANY, "trigger", "expression"],
]

# ## The symbol table of a component

"""`Source.keysOf`."""
keys_of(v) = v isa JObj ? String[kv.first for kv in v.kvs] : String[]

"""`Source.strsOf`."""
strs_of(v) = v isa JArr ? String[x for x in v.xs if x isa String] : String[]

const Templates = Vector{Tuple{String, Vector{String}}}

"""`Source.templatesOf`."""
function templates_of(v)
    out = Templates()
    v isa JObj || return out
    for (k, x) in v.kvs
        x isa JObj && push!(out, (k, strs_of(look("params", x.kvs))))
    end
    return out
end

"""`Tm.ps`: a template's header parameters; a rule's `params` attribute."""
ps(t::Tm) = t.lhs === nothing ? t.params : strs_of(look("params", t.attrs))

"""`Tm.scope`: the table around it, with the parameters declared."""
scope(t::Tm, s::Sym) = Sym(vcat(s.names, ps(t)), copy(s.templates))

"""`Tm.mscope`: the symbol table a rule's `match` pattern is read under: its
body's, with no templates. A pattern never applies a template (spec §9.7.3), so
an operator in it named like a template in scope (a rule is in scope under its
own name) reads as that operator, in the call form."""
mscope(t::Tm, s::Sym) = Sym(scope(t, s).names, Tuple{String, Vector{String}}[])

function heads(ms)
    out = Templates()
    for m in ms
        h = head(m)
        h === nothing || push!(out, h)
    end
    return out
end

"""`Source.rootTs`."""
root_ts(root, rm) = vcat(templates_of(look("expression_templates", root)), heads(rm))

"""`Source.compTs`."""
comp_ts(c::Comp) = vcat(templates_of(look("expression_templates", c.math_blocks)), heads(c.math))

"""`Source.symWith`."""
function sym_with(root, rt, c::Comp, ct)
    names = String[d.name for d in c.decls if d.kind != D_SUB]
    append!(names, keys_of(look("variables", c.blocks)))
    append!(names, keys_of(look("species", c.blocks)))
    append!(names, keys_of(look("parameters", c.blocks)))
    append!(names, keys_of(look("index_sets", root)))
    return Sym(names, vcat(Templates(rt), ct))
end

"""`Source.symFor`: the symbol table of a component."""
sym_for(d::Doc, c::Comp) = sym_with(d.blocks, root_ts(d.blocks, d.math), c, comp_ts(c))

"""`Source.topSym`: the symbol table of the top-level templates."""
top_sym(d::Doc) = Sym(keys_of(look("index_sets", d.blocks)), root_ts(d.blocks, d.math))

"""`Source.Caps`: what a container spells natively. A container defines, for
its subtype `C`: `front_key(::C, k)`, `desc(::C, s)`, `comp_name(::C, n)`,
`decl_name(::C, n)`, `attr(::C, kv)`, `eqn(::C, s, e)`, `rxn(::C, s, x)`,
`plot(::C, a)` and `tm(::C, s, t)`."""
abstract type Caps end

function front_key end
function desc end
function comp_name end
function decl_name end
function attr end
function eqn end
function rxn end
function plot end
function tm end

"""`Caps.item`: a list entry the container spells."""
item(caps::Caps, s::Sym, m::MxEq) = eqn(caps, s, m.a)
item(caps::Caps, s::Sym, m::MxRxn) = rxn(caps, s, m.x)
item(caps::Caps, s::Sym, m::MxPlot) = plot(caps, m.a)
item(caps::Caps, s::Sym, m::MxTm) = tm(caps, scope(m.t, s), m.t)

# ## Equations and the other math entries

obj(kvs...) = JObj(Kvs(collect(Pair{String, Any}, kvs)))

"""`Source.eqnJson`."""
eqn_json(e::Eqn) = e.comment === nothing ? obj("lhs" => e.lhs, "rhs" => e.rhs) :
    obj("_comment" => e.comment, "lhs" => e.lhs, "rhs" => e.rhs)

"""`Source.eqnOf`: exactly the keys `lhs`, `rhs` and optionally a string
`_comment`, both sides well-formed expressions."""
function eqn_of(v)
    v isa JObj || return nothing
    kvs = v.kvs
    if length(kvs) == 3
        (c, cm), (l, lv), (r, rv) = kvs[1], kvs[2], kvs[3]
        (c == "_comment" && cm isa String && l == "lhs" && r == "rhs") || return nothing
        return (is_e(lv) && is_e(rv)) ? Eqn(cm, lv, rv) : nothing
    elseif length(kvs) == 2
        (l, lv), (r, rv) = kvs[1], kvs[2]
        (l == "lhs" && r == "rhs") || return nothing
        return (is_e(lv) && is_e(rv)) ? Eqn(nothing, lv, rv) : nothing
    end
    return nothing
end

"""`Source.termJson`."""
term_json(t::Term) = obj("species" => t.species, "stoichiometry" => t.coef)

"""`Source.termOf`."""
function term_of(v)
    v isa JObj || return nothing
    length(v.kvs) == 2 || return nothing
    (a, s), (b, n) = v.kvs[1], v.kvs[2]
    (a == "species" && s isa String && b == "stoichiometry" && n isa JNum) || return nothing
    return Term(s, n)
end

"""`Source.sideJson`."""
side_json(s) = s === nothing ? JNULL : JArr(Any[term_json(t) for t in s])

"""`Source.sideOf`: `null`, or a non-empty array of terms. `Some(nothing)` for
`null`, `Some(terms)`, or `nothing` when it is neither."""
function side_of(v)
    v isa JNull && return Some(nothing)
    if v isa JArr && !isempty(v.xs)
        ts = Term[]
        for x in v.xs
            t = term_of(x)
            t === nothing && return nothing
            push!(ts, t)
        end
        return Some(ts)
    end
    return nothing
end

"""`Source.rxnKeys`."""
const RXN_KEYS = ("id", "products", "rate", "substrates")

"""`Source.rxnJson`."""
function rxn_json(x::Rxn)
    kvs = Kvs(
        [
            "id" => x.id, "products" => side_json(x.prods), "rate" => x.rate,
            "substrates" => side_json(x.subs),
        ]
    )
    append!(kvs, x.attrs)
    return JObj(sort_kvs(kvs))
end

"""`Source.rxnOf`: checked by printing it back."""
function rxn_of(v)
    v isa JObj || return nothing
    kvs = v.kvs
    id = look("id", kvs)
    sv = look("substrates", kvs)
    s = sv === nothing ? nothing : side_of(sv)
    pv = look("products", kvs)
    p = pv === nothing ? nothing : side_of(pv)
    r = look("rate", kvs)
    (id isa String && s !== nothing && p !== nothing && r !== nothing) || return nothing
    x = Rxn(id, something(s), something(p), r, Kvs([kv for kv in kvs if !(kv.first in RXN_KEYS)]))
    return (rxn_json(x) == v && is_e(r)) ? x : nothing
end

"""`Source.plotJson`."""
plot_json(attrs) = JObj(
    sort_kvs(
        Kvs([k == "plot" ? ("plots" => JArr(Any[x])) : (k => x) for (k, x) in attrs])
    )
)

"""`Source.plotOf`: an analysis with exactly one plot and no `plot` field,
checked by printing it back."""
function plot_of(v)
    v isa JObj || return nothing
    kvs = v.kvs
    pl = look("plots", kvs)
    (pl isa JArr && look("plot", kvs) === nothing && length(pl.xs) == 1) || return nothing
    a = Kvs([k == "plots" ? ("plot" => pl.xs[1]) : (k => x) for (k, x) in kvs])
    return plot_json(a) == v ? a : nothing
end

"""`Source.tmJson`."""
function tm_json(t::Tm)
    kvs = if t.lhs === nothing
        Kvs(["body" => t.body, "params" => JArr(Any[p for p in t.params])])
    else
        Kvs(["body" => t.body, "match" => t.lhs])
    end
    append!(kvs, t.attrs)
    return JObj(sort_kvs(kvs))
end

"""`Source.strList`: the string entries of a list, when every entry is a
string."""
function str_list(xs)
    out = String[]
    for x in xs
        x isa String || return nothing
        push!(out, x)
    end
    return out
end

"""`Source.tmOf`: the template or rule an entry of `expression_templates` is,
checked by printing it back."""
function tm_of(n::AbstractString, v)
    v isa JObj || return nothing
    kvs = v.kvs
    b, m, p = look("body", kvs), look("match", kvs), look("params", kvs)
    b === nothing && return nothing
    if m === nothing
        p isa JArr || return nothing
        ps2 = str_list(p.xs)
        ps2 === nothing && return nothing
        attrs = Kvs([kv for kv in kvs if kv.first != "body" && kv.first != "params"])
        t = Tm(n, ps2, nothing, b, attrs)
        return (tm_json(t) == v && is_e(b)) ? t : nothing
    end
    attrs = Kvs([kv for kv in kvs if kv.first != "body" && kv.first != "match"])
    t = Tm(n, String[], m, b, attrs)
    return (tm_json(t) == v && is_e(b) && is_e(m)) ? t : nothing
end

"""`Source.itemJson`."""
item_json(m::MxEq) = eqn_json(m.a)
item_json(m::MxRxn) = rxn_json(m.x)
item_json(m::MxPlot) = plot_json(m.a)
item_json(m::MxTm) = tm_json(m.t)

"""`Source.fieldJson`: an object keyed by the entries' names for
`expression_templates`, a list otherwise."""
field_json(f::AbstractString, ms) = f == "expression_templates" ?
    JObj(Kvs([key(m) => item_json(m) for m in ms])) : JArr(Any[item_json(m) for m in ms])

"""`Source.roleOf`."""
function role_of(f::AbstractString)
    for r in (R_EQN, R_INIT, R_CONS)
        field(r) == f && return r
    end
    return nothing
end

"""`Source.itemOf`."""
function item_of(f::AbstractString, v)
    if f == "reactions"
        x = rxn_of(v)
        return x === nothing ? nothing : MxRxn(x)
    elseif f == "analyses"
        a = plot_of(v)
        return a === nothing ? nothing : MxPlot(a)
    end
    r = role_of(f)
    r === nothing && return nothing
    e = eqn_of(v)
    return e === nothing ? nothing : MxEq(r, e)
end

"""`Source.tmItem`."""
function tm_item(kv)
    t = tm_of(kv.first, kv.second)
    return t === nothing ? nothing : MxTm(t)
end

"""`Source.mathOf`: the entries of a math field, when all of them print
natively."""
function math_of(caps::Caps, s::Sym, f::AbstractString, v)
    ms = Any[]
    if v isa JArr && !isempty(v.xs)
        f == "expression_templates" && return nothing
        for x in v.xs
            m = item_of(f, x)
            m === nothing && return nothing
            push!(ms, m)
        end
    elseif v isa JObj && !isempty(v.kvs)
        f != "expression_templates" && return nothing
        for kv in v.kvs
            m = tm_item(kv)
            m === nothing && return nothing
            push!(ms, m)
        end
    else
        return nothing
    end
    return all(m -> item(caps, s, m), ms) ? ms : nothing
end

"""`Source.descOf`."""
desc_of(caps::Caps, v) = (v isa String && desc(caps, v)) ? v : nothing

"""`Source.metaOf`: `metadata` printed in the front matter: the front-matter
entries and the description, or `nothing`."""
function meta_of(caps::Caps, v)
    v isa JObj || return nothing
    kvs = v.kvs
    (!isempty(kvs) && look("esm", kvs) === nothing && all(kv -> front_key(caps, kv.first), kvs)) ||
        return nothing
    d = desc_of(caps, look("description", kvs))
    es = Kvs([kv for kv in kvs if !(kv.first == "description" && d !== nothing)])
    return es, d
end

"""`Source.pickVar`: a model variable as a declaration."""
function pick_var(caps::Caps, n::AbstractString, v)
    decl_name(caps, n) || return nothing
    v isa JObj || return nothing
    kvs = v.kvs
    mk(kind, attrs) = all(a -> attr(caps, a), attrs) ? Decl(kind, n, attrs) : nothing
    without_type() = Kvs([kv for kv in kvs if kv.first != "type"])
    t = look("type", kvs)
    t === nothing && return nothing
    t == "parameter" && return mk(D_PARAM, without_type())
    t == "unknown" && return mk(D_VAR, without_type())
    return mk(D_VAR, copy(kvs))
end

"""`Source.pickPlain`: a reaction-system species or parameter as a declaration
of kind `k`."""
function pick_plain(caps::Caps, k::DKind, n::AbstractString, v)
    decl_name(caps, n) || return nothing
    (v isa JObj && all(a -> attr(caps, a), v.kvs)) || return nothing
    return Decl(k, n, copy(v.kvs))
end

"""`Source.pickSub`: a subsystem included by reference."""
pick_sub(caps::Caps, n::AbstractString, v) =
    (v isa JObj && look("ref", v.kvs) !== nothing) ? pick_plain(caps, D_SUB, n, v) : nothing

# The pickers of `Source.declFields`: `:var`, a `DKind` (plain) or `:sub`.
pick(p::Symbol, caps::Caps, n, v) = p === :var ? pick_var(caps, n, v) : pick_sub(caps, n, v)
pick(p::DKind, caps::Caps, n, v) = pick_plain(caps, p, n, v)

const MODEL_FIELDS = (("variables", :var), ("subsystems", :sub))
const RS_FIELDS = (("species", D_SPECIES), ("parameters", D_PARAM), ("subsystems", :sub))

"""`Source.declFields`: the declaration fields of a component kind, with their
pickers."""
decl_fields(k::Kind) = k == K_MODEL ? MODEL_FIELDS : RS_FIELDS

"""`Source.declField`."""
function decl_field(k::Kind, d::DKind)
    d == D_SUB && return "subsystems"
    if k == K_MODEL
        return (d == D_VAR || d == D_PARAM) ? "variables" : nothing
    end
    d == D_SPECIES && return "species"
    d == D_PARAM && return "parameters"
    return nothing
end

"""`Source.backDecl`: the entry a declaration stands for."""
function back_decl(k::Kind, d::Decl)
    has_type = any(kv -> kv.first == "type", d.attrs)
    with(t) = JObj(sort_kvs(vcat(Kvs(["type" => t]), d.attrs)))
    if k == K_MODEL && d.kind == D_PARAM
        return has_type ? nothing : (d.name => with("parameter"))
    elseif k == K_MODEL && d.kind == D_VAR
        return has_type ? (d.name => JObj(sort_kvs(d.attrs))) : (d.name => with("unknown"))
    elseif (k == K_RS && (d.kind == D_SPECIES || d.kind == D_PARAM)) || d.kind == D_SUB
        return d.name => JObj(sort_kvs(d.attrs))
    end
    return nothing
end

"""`Source.compBlock`: where an entry of a component goes when it is not a
native surface."""
function comp_block(caps::Caps, k::Kind, desc, kv)
    if kv.first == "description"
        return desc === nothing ? kv : nothing
    elseif is_math_field(kv.first)
        return nothing
    end
    for (f, p) in decl_fields(k)
        if f == kv.first
            r = split_opt((n, v) -> pick(p, caps, n, v), kv.second)[2]
            return r === nothing ? nothing : (kv.first => r)
        end
    end
    return kv
end

"""`Source.compBase`: a component before its equations are decided."""
function comp_base(caps::Caps, k::Kind, name::AbstractString, kvs)
    d = desc_of(caps, look("description", kvs))
    decls = Decl[]
    for (f, p) in decl_fields(k)
        append!(decls, split_opt((n, v) -> pick(p, caps, n, v), look(f, kvs))[1])
    end
    blocks = Kvs()
    for kv in kvs
        b = comp_block(caps, k, d, kv)
        b === nothing || push!(blocks, b)
    end
    return Comp{AsRead}(k, name, d, decls, Any[], Kvs(), blocks)
end

"""`Source.mathPart`: one math field of a component: its entries when every one
prints natively under `s`, else its block."""
function math_part(caps::Caps, s::Sym, kvs, f::AbstractString)
    v = look(f, kvs)
    v === nothing && return Any[], nothing
    ms = math_of(caps, s, f, v)
    ms === nothing && return Any[], (f => v)
    return ms, nothing
end

"""`Source.compSym`."""
comp_sym(root, rt, k::Kind, caps::Caps, name, kvs) =
    sym_with(root, rt, comp_base(caps, k, name, kvs), templates_of(look("expression_templates", kvs)))

"""`Source.compOf`: a component, with its math fields decided."""
function comp_of(caps::Caps, root, rt, k::Kind, name, kvs)
    c = comp_base(caps, k, name, kvs)
    s = comp_sym(root, rt, k, caps, name, kvs)
    for f in MATH_FIELDS
        ms, b = math_part(caps, s, kvs, f)
        append!(c.math, ms)
        b === nothing || push!(c.math_blocks, b)
    end
    return c
end

"""`Source.pickComp`."""
pick_comp(caps::Caps, n::AbstractString, v) =
    (v isa JObj && comp_name(caps, n)) ? (String(n), copy(v.kvs)) : nothing

"""`Source.topSymOf`."""
top_sym_of(kvs) = Sym(keys_of(look("index_sets", kvs)), templates_of(look("expression_templates", kvs)))

"""`Source.topMath`: the top-level templates, when every one prints natively."""
function top_math(caps::Caps, kvs)
    v = look("expression_templates", kvs)
    v === nothing && return nothing
    return math_of(caps, top_sym_of(kvs), "expression_templates", v)
end

"""`Source.rootBlock`."""
function root_block(caps::Caps, tn::Bool, kv)
    k = kv.first
    k == "esm" && return nothing
    k == "metadata" && return meta_of(caps, kv.second) !== nothing ? nothing : kv
    if k == "models" || k == "reaction_systems"
        r = split_opt((n, v) -> pick_comp(caps, n, v), kv.second)[2]
        return r === nothing ? nothing : (k => r)
    end
    (k == "expression_templates" && tn) && return nothing
    return kv
end

"""`Source.rootBlocks`."""
function root_blocks(caps::Caps, tn::Bool, kvs)
    out = Kvs()
    for kv in kvs
        b = root_block(caps, tn, kv)
        b === nothing || push!(out, b)
    end
    return out
end

"""`Source.toDoc`: the skeleton of a document."""
function to_doc(caps::Caps, d)
    d isa JObj || return Doc{AsRead}(Kvs(), nothing, Kvs(), Any[], Comp{AsRead}[])
    kvs = d.kvs
    m = meta_of(caps, look("metadata", kvs))
    tmath = top_math(caps, kvs)
    blocks = root_blocks(caps, tmath !== nothing, kvs)
    rt = templates_of(look("expression_templates", kvs))
    function comps(k::Kind, f)
        out = Comp{AsRead}[]
        for (n, ckvs) in split_opt((n, v) -> pick_comp(caps, n, v), look(f, kvs))[1]
            push!(out, comp_of(caps, blocks, rt, k, n, ckvs))
        end
        return out
    end
    cs = comps(K_MODEL, "models")
    append!(cs, comps(K_RS, "reaction_systems"))
    front = at_("esm", kvs)
    dsc = m === nothing ? nothing : m[2]
    m === nothing || append!(front, m[1])
    return Doc{AsRead}(front, dsc, blocks, tmath === nothing ? Any[] : tmath, cs)
end

# ## From a skeleton back to the document

"""`Source.optKv`."""
opt_kv(k::AbstractString, v) = v === nothing ? Kvs() : Kvs([String(k) => v])

"""`Source.mathKv`: one rebuilt math field."""
function math_kv(c::Comp, f::AbstractString)
    ms = Any[m for m in c.math if field(m) == f]
    bs = at_(f, c.math_blocks)
    isempty(ms) && isempty(bs) && return Kvs()
    isempty(ms) && length(bs) == 1 && return Kvs([String(f) => bs[1].second])
    !isempty(ms) && isempty(bs) && return Kvs([String(f) => field_json(f, ms)])
    return nothing
end

"""`Source.mathKvs`."""
function math_kvs(c::Comp)
    out = Kvs()
    for f in MATH_FIELDS
        x = math_kv(c, f)
        x === nothing && return nothing
        append!(out, x)
    end
    return out
end

"""`Source.declFieldNames`."""
decl_field_names(k::Kind) = k == K_MODEL ? ("variables", "subsystems") :
    ("species", "parameters", "subsystems")

"""`Source.declKv`."""
function decl_kv(k::Kind, c::Comp, f::AbstractString)
    r = pick_one(f, c.blocks)
    r === nothing && return nothing
    ds = [d for d in c.decls if decl_field(k, d.kind) == f]
    v = join_field(d -> back_decl(k, d), ds, something(r))
    v === nothing && return nothing
    return opt_kv(f, something(v))
end

"""`Source.declKvs`: a declaration of a kind the component does not have is
refused."""
function decl_kvs(k::Kind, c::Comp)
    all(d -> decl_field(k, d.kind) !== nothing, c.decls) || return nothing
    out = Kvs()
    for f in decl_field_names(k)
        x = decl_kv(k, c, f)
        x === nothing && return nothing
        append!(out, x)
    end
    return out
end

"""`Source.ofComp`: a component rebuilt from its section."""
function of_comp(c::Comp{AsRead})
    ds = decl_kvs(c.kind, c)
    ds === nothing && return nothing
    es = math_kvs(c)
    es === nothing && return nothing
    names = decl_field_names(c.kind)
    kvs = opt_kv("description", c.desc)
    append!(kvs, ds)
    append!(kvs, es)
    for kv in c.blocks
        kv.first in names || push!(kvs, kv)
    end
    return JObj(sort_kvs(kvs))
end

"""`Source.backComp`."""
function back_comp(c::Comp{AsRead})
    v = of_comp(c)
    return v === nothing ? nothing : (c.name => v)
end

"""`Source.ofDoc`: a document rebuilt from its skeleton, checked to be
canonical."""
function of_doc(d::Doc{AsRead})
    esm_kv = at_("esm", d.front)
    meta_es = Kvs([kv for kv in d.front if kv.first != "esm"])
    append!(meta_es, opt_kv("description", d.desc))
    meta_kv = isempty(meta_es) ? Kvs() : Kvs(["metadata" => JObj(sort_kvs(meta_es))])
    mr = pick_one("models", d.blocks)
    mr === nothing && return nothing
    ms = [c for c in d.comps if c.kind == K_MODEL]
    models = join_field(back_comp, ms, something(mr))
    models === nothing && return nothing
    rr = pick_one("reaction_systems", d.blocks)
    rr === nothing && return nothing
    rs = [c for c in d.comps if c.kind == K_RS]
    rss = join_field(back_comp, rs, something(rr))
    rss === nothing && return nothing
    tkv = isempty(d.math) ? Kvs() :
        Kvs(["expression_templates" => field_json("expression_templates", d.math)])
    kvs = esm_kv
    append!(kvs, meta_kv)
    append!(kvs, opt_kv("models", something(models)))
    append!(kvs, opt_kv("reaction_systems", something(rss)))
    append!(kvs, tkv)
    for kv in d.blocks
        (kv.first != "models" && kv.first != "reaction_systems") && push!(kvs, kv)
    end
    doc = JObj(sort_kvs(kvs))
    return canon_doc(doc) ? doc : nothing
end

end # module SSkeleton
