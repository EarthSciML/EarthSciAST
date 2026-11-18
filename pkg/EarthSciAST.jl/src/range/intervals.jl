# Interval sets: the integer-cell algebra the need-box analysis
# (need_analysis.jl) computes images and boxes in. Depends on nothing else in
# the package.

# A sorted list of disjoint, non-adjacent integer intervals.
struct _ISet
    ivs::Vector{UnitRange{Int}}
end
_ISet() = _ISet(UnitRange{Int}[])
_ISet(r::UnitRange{Int}) = isempty(r) ? _ISet() : _ISet(UnitRange{Int}[r])
Base.isempty(s::_ISet) = isempty(s.ivs)
Base.length(s::_ISet) = sum(length, s.ivs; init = 0)
Base.minimum(s::_ISet) = first(s.ivs[1])
Base.maximum(s::_ISet) = last(s.ivs[end])
Base.in(x::Integer, s::_ISet) = any(r -> x in r, s.ivs)
Base.:(==)(a::_ISet, b::_ISet) = a.ivs == b.ivs
_points(s::_ISet) = Iterators.flatten(s.ivs)

function _iset_points(pts)
    v = sort!(unique!(collect(Int, pts)))
    isempty(v) && return _ISet()
    out = UnitRange{Int}[]
    lo = prev = v[1]
    for x in Iterators.drop(v, 1)
        if x == prev + 1
            prev = x
        else
            push!(out, lo:prev)
            lo = prev = x
        end
    end
    push!(out, lo:prev)
    return _ISet(out)
end

function _iset_union(a::_ISet, b::_ISet)
    isempty(a) && return b
    isempty(b) && return a
    rs = sort!(vcat(a.ivs, b.ivs); by = first)
    out = UnitRange{Int}[rs[1]]
    for r in Iterators.drop(rs, 1)
        if first(r) <= last(out[end]) + 1
            out[end] = first(out[end]):max(last(out[end]), last(r))
        else
            push!(out, r)
        end
    end
    return _ISet(out)
end

function _iset_intersect(a::_ISet, r::UnitRange{Int})
    out = UnitRange{Int}[]
    for x in a.ivs
        y = max(first(x), first(r)):min(last(x), last(r))
        isempty(y) || push!(out, y)
    end
    return _ISet(out)
end
_iset_intersect(a::_ISet, b::_ISet) =
    foldl(_iset_union, (_iset_intersect(a, r) for r in b.ivs); init = _ISet())
