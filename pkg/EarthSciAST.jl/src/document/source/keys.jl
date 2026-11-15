"""
Objects in canonical form: sorting entries, and splitting an object between
surfaces.

Port of `formal/Esm/Document/Source/Keys.lean` (Rust
`document::source::keys`).
"""
module SKeys

using ..DJson

"""`Source.sortKeys`: the entries ordered by key (a stable sort)."""
sort_kvs(l) = sort!(Kvs(l); by = first, alg = Base.Sort.DEFAULT_STABLE)

"""`Source.at_`: the entries of `l` with key `k`."""
at_(k::AbstractString, l) = Kvs([kv for kv in l if kv.first == k])

"""`Source.splitField`: the entries of an object-valued field that `pick` takes
(`pick(k, v)` returns the piece or `nothing`), and the residue (`nothing` when
every entry was taken and there was at least one)."""
function split_field(pick, v)
    if v isa JObj
        ps = Any[]
        rs = Kvs()
        for (k, x) in v.kvs
            p = pick(k, x)
            if p === nothing
                push!(rs, k => x)
            else
                push!(ps, p)
            end
        end
        r = (!isempty(ps) && isempty(rs)) ? nothing : JObj(rs)
        return ps, r
    end
    return Any[], v
end

"""`Source.splitOpt`: `splitField` of a field that may be absent (`nothing`)."""
split_opt(pick, v) = v === nothing ? (Any[], nothing) : split_field(pick, v)

"""`Source.joinField`: the field rebuilt from its pieces and its residue:
`nothing` when they do not fit together, `Some(nothing)` when the field is
absent, `Some(v)` otherwise."""
function join_field(back, ps, r)
    isempty(ps) && return Some(r)
    es = Kvs()
    for p in ps
        e = back(p)
        e === nothing && return nothing
        push!(es, e)
    end
    r === nothing && return Some(JObj(sort_kvs(es)))
    if r isa JObj
        append!(es, r.kvs)
        return Some(JObj(sort_kvs(es)))
    end
    return nothing
end

"""`Source.pickOne`: the value of key `k`, when it occurs at most once:
`Some(nothing)` when absent, `Some(v)` once, `nothing` more than once."""
function pick_one(k::AbstractString, l)
    found = nothing
    n = 0
    for kv in l
        if kv.first == k
            n += 1
            n > 1 && return nothing
            found = kv.second
        end
    end
    return Some(found)
end

end # module SKeys
