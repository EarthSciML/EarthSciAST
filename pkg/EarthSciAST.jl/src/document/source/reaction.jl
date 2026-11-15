"""
Reaction sides, shared by the containers.

Port of `formal/Esm/Document/Source/Reaction.lean` (Rust
`document::source::reaction`). A side is the empty-set symbol as math for an
empty side, otherwise its terms separated by ` + `; a term is its coefficient
as math and a space (left out when it is 1), then the species, bare when
formula-shaped and otherwise its name as math under the empty symbol table.
"""
module SReaction

using ..DJson
using ..MExpr: is_dig, is_formula, is_letter, name_ok, num_ok
using ..DStrings: is_ident_char
using ..SSkeleton: Term
using ..SText: pre, take_while

"""`Source.RSurf`: how a math piece prints and reads back (under the empty
symbol table): `pm(text)` reads (value or `nothing`), `prm(json)` prints
(characters); and the content of the empty-set piece."""
struct RSurf{P, Q}
    pm::P
    prm::Q
    empty::Vector{Char}
end

"""`Source.isAlnumC`."""
is_alnum_c(c::Char) = is_letter(c) || is_dig(c)

"""`Source.speciesTxt`."""
function species_txt(r::RSurf, n::AbstractString, out::Vector{Char})
    if is_formula(n)
        append!(out, n)
    else
        push!(out, '$')
        append!(out, r.prm(String(n)))
        push!(out, '$')
    end
    return out
end

"""`Source.termTxt`."""
function term_txt(r::RSurf, t::Term, out::Vector{Char})
    if t.coef != JInt(1)
        push!(out, '$')
        append!(out, r.prm(t.coef))
        push!(out, '$', ' ')
    end
    return species_txt(r, t.species, out)
end

"""`Source.termsTxt`."""
function terms_txt(r::RSurf, ts, out::Vector{Char})
    for (i, t) in enumerate(ts)
        i > 1 && push!(out, ' ', '+', ' ')
        term_txt(r, t, out)
    end
    return out
end

"""`Source.sideTxt`."""
function side_txt(r::RSurf, s)
    out = Char[]
    if s === nothing
        push!(out, '$')
        append!(out, r.empty)
        push!(out, '$')
    else
        terms_txt(r, s, out)
    end
    return out
end

"""`Source.termOK`."""
function term_ok(r::RSurf, t::Term)
    ps = r.prm(t.species)
    name_ok(t.species) || return false
    (is_formula(t.species) || (!('$' in ps) && ps != r.empty)) || return false
    t.coef == JInt(1) && return true
    pc = r.prm(t.coef)
    return num_ok(t.coef) && !('$' in pc) && pc != r.empty
end

"""`Source.sideOK`."""
side_ok(r::RSurf, s) = s === nothing || (!isempty(s) && all(t -> term_ok(r, t), s))

"""`Source.after`: the text after the prefix `p`, when it is one."""
after(p, s::Chars) = pre(p, s) ? drop(s, length(p)) : nothing

"""`Source.idChar`."""
id_char(c::Char) = is_ident_char(c) || c == '-' || c == '.' || c == ':'

"""`Source.idOK`: a reaction id the containers spell as a label."""
id_ok(i::AbstractString) = !isempty(i) && all(id_char, i)

"""`Source.pPiece`: the text up to the next `\$`, and the text after it."""
function p_piece(t::Chars)
    p, r = take_while(t, c -> c != '$')
    at(r) == '$' || return nothing
    return p, drop(r)
end

"""`Source.pSpecies`: a math piece holding a name, or a bare run of letters and
digits."""
function p_species(r::RSurf, s::Chars)
    if at(s) == '$'
        x = p_piece(drop(s))
        x === nothing && return nothing
        p, rest = x
        n = r.pm(String(p))
        n isa String || return nothing
        return n, rest
    end
    a, rest = take_while(s, is_alnum_c)
    isempty(a) && return nothing
    return String(a), rest
end

"""`Source.pTerm`."""
function p_term(r::RSurf, s::Chars)
    if at(s) == '$'
        x = p_piece(drop(s))
        x === nothing && return nothing
        p, rest = x
        v = r.pm(String(p))
        if v isa JNum
            at(rest) == ' ' || return nothing
            y = p_species(r, drop(rest))
            y === nothing && return nothing
            return Term(y[1], v), y[2]
        elseif v isa String
            return Term(v, JInt(1)), rest
        end
        return nothing
    end
    y = p_species(r, s)
    y === nothing && return nothing
    return Term(y[1], JInt(1)), y[2]
end

"""`Source.pTerms`: terms separated by ` + `."""
function p_terms(r::RSurf, s::Chars)
    out = Term[]
    while true
        x = p_term(r, s)
        x === nothing && return nothing
        t, rest = x
        push!(out, t)
        if starts(rest, " + ")
            s = drop(rest, 3)
        else
            return out, rest
        end
    end
    return nothing
end

"""`Source.pSide`: the empty-set piece, or terms: `(side, rest)` with `side`
`nothing` for the empty side."""
function p_side(r::RSurf, s::Chars)
    if at(s) == '$'
        x = p_piece(drop(s))
        x === nothing && return nothing
        p, rest = x
        p == r.empty && return nothing, rest
    end
    y = p_terms(r, s)
    y === nothing && return nothing
    return y[1], y[2]
end

end # module SReaction
