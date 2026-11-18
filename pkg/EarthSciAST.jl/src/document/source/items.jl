"""
The skeleton as a sequence of constructs.

Port of `formal/Esm/Document/Source/Items.lean` (Rust
`document::source::items`). [`items`](@ref) lists the constructs of a skeleton
in the printer's order; [`unitems`](@ref) reads a construct sequence back.
Math entries are held as the container's math text at this layer;
[`raw_doc`](@ref) prints them under each component's symbol table and
[`cook_doc`](@ref) reads them back.
"""
module SItems

using ..DJson
using ..MExpr: Sym
using ..SSkeleton
using ..SSkeleton: is_math_field, sym_for, top_sym, map_math, scope, mscope

export RItem, RDesc, RBlock, RComp, RDecl, REqn, REqx, RRxn, RPlot, RTm

"""`Source.RItem`: one construct of a document. An equation is its math text,
uninterpreted; so is a reaction's rate."""
abstract type RItem end
struct RDesc <: RItem
    s::String
end
struct RBlock <: RItem
    k::String
    v::Any
end
struct RComp <: RItem
    kind::Kind
    name::String
end
struct RDecl <: RItem
    d::Decl
end
struct REqn <: RItem
    s::String
end
struct REqx <: RItem
    role::Role
    s::String
end
struct RRxn <: RItem
    x::Rxn
end
struct RPlot <: RItem
    a::Kvs
end
struct RTm <: RItem
    t::Tm
end
Base.:(==)(a::T, b::T) where {T <: RItem} = fieldeq(a, b)
Base.:(==)(a::RItem, b::RItem) = false

"""`Source.mItem`: the construct of a math entry."""
m_item(m::MxEq) = m.role == R_EQN ? REqn(m.a) : REqx(m.role, m.a)
m_item(m::MxRxn) = RRxn(m.x)
m_item(m::MxPlot) = RPlot(m.a)
m_item(m::MxTm) = RTm(m.t)

"""`Source.compItems`: the constructs of a component section."""
function comp_items(c::Comp, out::Vector{RItem})
    push!(out, RComp(c.kind, c.name))
    c.desc === nothing || push!(out, RDesc(c.desc))
    for d in c.decls
        push!(out, RDecl(d))
    end
    for m in c.math
        push!(out, m_item(m))
    end
    for (k, v) in c.math_blocks
        push!(out, RBlock(k, v))
    end
    for (k, v) in c.blocks
        push!(out, RBlock(k, v))
    end
    return out
end

"""`Source.items`: the constructs of a skeleton, in the printer's order."""
function items(d::Doc)
    out = RItem[]
    d.desc === nothing || push!(out, RDesc(d.desc))
    for (k, v) in d.blocks
        push!(out, RBlock(k, v))
    end
    for m in d.math
        push!(out, m_item(m))
    end
    for c in d.comps
        comp_items(c, out)
    end
    return out
end

"""`Comp.fresh`."""
comp_fresh(k::Kind, n::String) = Comp(k, n, nothing, Decl[], Any[], Kvs(), Kvs())

with_desc(c::Comp, s) = Comp(c.kind, c.name, s, c.decls, c.math, c.math_blocks, c.blocks)

"""`Source.addTo`: add a construct to a component section (the updated section);
a second description is refused (`nothing`)."""
function add_to(c::Comp, it::RItem)
    if it isa RDesc
        c.desc === nothing || return nothing
        return with_desc(c, it.s)
    elseif it isa RBlock
        push!(is_math_field(it.k) ? c.math_blocks : c.blocks, it.k => it.v)
    elseif it isa RDecl
        push!(c.decls, it.d)
    elseif it isa REqn
        push!(c.math, MxEq(R_EQN, it.s))
    elseif it isa REqx
        push!(c.math, MxEq(it.role, it.s))
    elseif it isa RRxn
        push!(c.math, MxRxn(it.x))
    elseif it isa RPlot
        push!(c.math, MxPlot(it.a))
    elseif it isa RTm
        push!(c.math, MxTm(it.t))
    else
        return nothing
    end
    return c
end

"""`Source.St`: the reader's state."""
mutable struct St
    desc::Union{Nothing, String}
    blocks::Kvs
    math::Vector{Any}
    comps::Vector{Comp}
    cur::Union{Nothing, Comp}
end
St() = St(nothing, Kvs(), Any[], Comp[], nothing)

"""`Source.step`: read one construct (`false` when refused). Before the first
directive only a description, blocks and templates are allowed."""
function step!(st::St, it::RItem)
    if it isa RComp
        st.cur === nothing || push!(st.comps, st.cur)
        st.cur = comp_fresh(it.kind, it.name)
        return true
    end
    if st.cur !== nothing
        c = add_to(st.cur, it)
        c === nothing && return false
        st.cur = c
        return true
    end
    if it isa RDesc
        st.desc === nothing || return false
        st.desc = it.s
        return true
    elseif it isa RBlock
        push!(st.blocks, it.k => it.v)
        return true
    elseif it isa RTm
        push!(st.math, MxTm(it.t))
        return true
    end
    return false
end

"""`Source.unitems`: read a construct sequence (with the front matter) into a
skeleton."""
function unitems(front::Kvs, its)
    st = St()
    for it in its
        step!(st, it) || return nothing
    end
    comps = st.comps
    st.cur === nothing || push!(comps, st.cur)
    return Doc(front, st.desc, st.blocks, st.math, comps)
end

"""`Source.rawDoc`: every math entry printed under its symbol table
(`pr(sym, m)`)."""
function raw_doc(pr, d::Doc)
    ts = top_sym(d)
    comps = Comp[]
    for c in d.comps
        s = sym_for(d, c)
        push!(comps, map_math(c, (_, m) -> pr(s, m)))
    end
    return Doc(d.front, d.desc, d.blocks, Any[pr(ts, m) for m in d.math], comps)
end

"""`Source.cookComp`: read a component's math entries under its symbol table;
one math text may hold several equations (`ck(sym, m)` gives a vector or
`nothing`)."""
function cook_comp(ck, d::Doc, c::Comp)
    s = sym_for(d, c)
    math = Any[]
    for m in c.math
        x = ck(s, m)
        x === nothing && return nothing
        append!(math, x)
    end
    return Comp(c.kind, c.name, c.desc, c.decls, math, c.math_blocks, c.blocks)
end

"""`Source.cookDoc`: read every math entry of a skeleton."""
function cook_doc(ck, d::Doc)
    ts = top_sym(d)
    rm = Any[]
    for m in d.math
        x = ck(ts, m)
        x === nothing && return nothing
        append!(rm, x)
    end
    cs = Comp[]
    for c in d.comps
        x = cook_comp(ck, d, c)
        x === nothing && return nothing
        push!(cs, x)
    end
    return Doc(d.front, d.desc, d.blocks, rm, cs)
end

"""`Source.prMx`: a math entry's text, from the equation and expression
printers."""
pr_mx(pr_e, pr_r, s::Sym, m::MxEq) = MxEq(m.role, pr_e(s, m.a))
pr_mx(pr_e, pr_r, s::Sym, m::MxRxn) =
    MxRxn(Rxn(m.x.id, m.x.subs, m.x.prods, pr_r(s, m.x.rate), m.x.attrs))
pr_mx(pr_e, pr_r, s::Sym, m::MxPlot) = m
function pr_mx(pr_e, pr_r, s::Sym, m::MxTm)
    t = m.t
    sc = scope(t, s)
    lhs = t.lhs === nothing ? nothing : pr_r(mscope(t, s), t.lhs)
    return MxTm(Tm(t.name, t.params, lhs, pr_r(sc, t.body), t.attrs))
end

"""`Source.ckMx`: read a math entry's text back."""
function ck_mx(ck_e, ck_r, s::Sym, m::MxEq)
    es = ck_e(s, m.a)
    es === nothing && return nothing
    return Any[MxEq(m.role, e) for e in es]
end
function ck_mx(ck_e, ck_r, s::Sym, m::MxRxn)
    j = ck_r(s, m.x.rate)
    j === nothing && return nothing
    return Any[MxRxn(Rxn(m.x.id, m.x.subs, m.x.prods, j, m.x.attrs))]
end
ck_mx(ck_e, ck_r, s::Sym, m::MxPlot) = Any[m]
function ck_mx(ck_e, ck_r, s::Sym, m::MxTm)
    t = m.t
    sc = scope(t, s)
    lhs = nothing
    if t.lhs !== nothing
        lhs = ck_r(mscope(t, s), t.lhs)
        lhs === nothing && return nothing
    end
    body = ck_r(sc, t.body)
    body === nothing && return nothing
    return Any[MxTm(Tm(t.name, t.params, lhs, body, t.attrs))]
end

# ## Shared by the two containers
#
# What the Markdown and Typst containers write identically, under one name
# here; each container keeps its Lean-named forwards (`Md.render`,
# `Typ.canonSegs`, …).

"""A piece of a document body: a construct or prose (Lean `Md.Seg` and
`Typ.Seg`, whose labelled-equation and code-span cases are never built
here)."""
abstract type Seg end
struct SegItem <: Seg
    it::RItem
end
struct SegProse <: Seg
    p::Vector{Char}
end

# The text of a document body, each construct through the container's
# `item_text` (`Md.render`, `Typ.render`).
function render_segs(item_text::F, segs) where {F}
    out = Char[]
    for s in segs
        append!(out, s isa SegItem ? item_text(s.it) : s.p)
    end
    return out
end

"""`Md.isBlock`: a construct that must start a line (all but declarations);
`Typ.isBlock` is the same."""
is_block(it::RItem) = it isa RDecl ? it.d.kind == D_SUB : true

"""`Md.canonSegs`: each construct after a blank line, a declaration on a line of
its own; `Typ.canonSegs` is the same."""
function canon_segs(its)
    out = Seg[]
    for it in its
        block = is_block(it)
        push!(out, SegProse(Char['\n']))
        push!(out, SegItem(it))
        block || push!(out, SegProse(Char['\n']))
    end
    return out
end

# Read a construct sequence and its front matter into a document, the
# container's math read by `ck` (`Md.parseItemsMd`, `Typ.parseItemsT`).
function parse_items(ck, front::Kvs, its)
    r = unitems(front, its)
    r === nothing && return nothing
    d = cook_doc(ck, r)
    d === nothing && return nothing
    return SSkeleton.of_doc(d)
end

end # module SItems
