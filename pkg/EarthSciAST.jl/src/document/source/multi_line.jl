"""
Multi-line equations (accepted input variants): rows split at top-level line
breaks, cells at the first top-level `&`.

Port of `formal/Esm/Document/Source/MultiLine.lean` (Rust
`document::source::multi_line`). The reader works on the math tokens, so rows
and cells are found by token and depth.
"""
module SMultiLine

using ..DJson
using ..MToken
import ..DMath
using ..MExpr: Sym
using ..SEquation: eq_sides
using ..SSkeleton: Eqn

const OPENS = (KLp, KLpg, KLb, KLbk, KBcases, KBmat, KLbkg)
const CLOSES = (KRp, KRpg, KRb, KRbk, KEcases, KEmat, KRbkg)

"""`Source.delta`: how a token changes the delimiter depth."""
function delta(t::Tok)
    t isa TKw || return 0
    t.k in OPENS && return 1
    t.k in CLOSES && return -1
    return 0
end

"""`Source.isKw`."""
is_kw(k::Kw, t::Tok) = iskw(t, k)

"""`Source.cut`: cut at the first `k` at depth 0 (starting at depth `d`): the
tokens before it and those after it (`nothing` when there is no such `k`)."""
function cut(k::Kw, d::Int, ts::AbstractVector)
    for i in eachindex(ts)
        t = ts[i]
        d == 0 && is_kw(k, t) && return view(ts, 1:(i - 1)), view(ts, (i + 1):length(ts))
        d += delta(t)
    end
    return ts, nothing
end

"""`Source.splitAll`: split at every top-level `k`."""
function split_all(k::Kw, ts::AbstractVector)
    out = Vector{Vector{Tok}}()
    while true
        a, r = cut(k, 0, ts)
        if r === nothing
            push!(out, collect(Tok, ts))
            return out
        end
        push!(out, collect(Tok, a))
        ts = r
    end
    return out
end

"""`Source.group`: rows into equations (`one`: all rows are one equation)."""
function group(one::Bool, rows)
    acc = Vector{Vector{Tok}}()
    for row in rows
        l, r = cut(KAmp, 0, row)
        if r === nothing
            isempty(l) && continue
            if one && !isempty(acc)
                append!(acc[end], l)
            else
                push!(acc, collect(Tok, l))
            end
        else
            cut(KAmp, 0, r)[2] === nothing || return nothing
            if isempty(l) && !one
                isempty(acc) && return nothing
                (!isempty(r) && iskw(r[1], KEq)) && return nothing
                append!(acc[end], r)
            elseif one
                if isempty(acc)
                    push!(acc, vcat(collect(Tok, l), collect(Tok, r)))
                else
                    append!(acc[end], l)
                    append!(acc[end], r)
                end
            else
                push!(acc, vcat(collect(Tok, l), collect(Tok, r)))
            end
        end
    end
    return acc
end

"""`Source.cookRows`: read the rows of a multi-line display into equations."""
function cook_rows(sf::Sf, s::Sym, one::Bool, ts::AbstractVector)
    eqs = group(one, split_all(KNl, ts))
    eqs === nothing && return nothing
    out = Eqn[]
    for t in eqs
        j = DMath.parse_toks(sf, s, t)
        j === nothing && return nothing
        lr = eq_sides(j)
        lr === nothing && return nothing
        push!(out, Eqn(nothing, lr[1], lr[2]))
    end
    return out
end

end # module SMultiLine
