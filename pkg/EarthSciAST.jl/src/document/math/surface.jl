"""
Pieces the LaTeX and Typst spellings share: literal prefixes, binary operator
tokens, and the reading of numbers (a JSON spelling, or a scientific literal
`mantissa × 10^exponent` whose tail each surface reads with its own `sciExp`).

Port of `formal/Esm/Document/Math/Surface.lean` (Rust
`document::math::surface`).
"""
module MSurface

using ..DJson
using ..MToken
import ..DNumber

"""`Math.dropP`: strip a literal prefix (`nothing` when absent)."""
drop_p(p::AbstractString, cs::Chars) = strip_prefix(cs, p)
function drop_p(p::AbstractVector{Char}, cs::Chars)
    length(cs) >= length(p) || return nothing
    for i in eachindex(p)
        cs[i] == p[i] || return nothing
    end
    return drop(cs, length(p))
end

const BIN_KWS = (KPlus, KEq, KNe, KLt, KGt, KLe, KGe, KLand, KLor, KCdot, KTimes, KAmp, KNl, KInn)

"""`Math.isBin`: the binary operator tokens."""
is_bin(t::Tok) = t isa TKw && t.k in BIN_KWS

"""`Math.sciSplit`: the mantissa (with its sign) and exponent of a number
printed in scientific notation, or `nothing`."""
function sci_split(n::JNum)
    n isa JDec || return nothing
    (isempty(n.digits) || !(n.e10 < -4 || 5 < n.e10)) && return nothing
    m = n.neg ? Char['-'] : Char[]
    push!(m, DNumber.digit_char(n.digits[1]), '.')
    append!(m, DNumber.digit_char.(DNumber.frac_digits(n.digits[2:end])))
    return m, n.e10
end

"""`Math.negNum`: a number below zero."""
neg_num(n::JInt) = n.z < 0
neg_num(n::JDec) = n.neg

"""`Math.sciNum`: the value of a mantissa times `10^z`, in canonical form, or
`nothing` (also when the decimal exponent leaves `Int64`, which no document
writes)."""
function sci_num(n0::JNum, z::Integer)
    m = if n0 isa JDec
        e = Int128(n0.e10) + Int128(z)
        in_int64(e) || return nothing
        DNumber.canonize(JDec(n0.neg, copy(n0.digits), Int(e)))
    else
        ds = DNumber.nat_digits(abs(n0.z))
        e = Int128(length(ds) - 1) + Int128(z)
        in_int64(e) || return nothing
        d = DNumber.mk_dec(n0.z < 0, ds, Int(e))
        d === nothing && return nothing
        DNumber.canonize(d)
    end
    return wfb(m) ? m : nothing
end

"""`Math.lexNum`: a number: its JSON spelling, or a decimal mantissa followed by
a scientific tail that `sci_exp` reads (`sci_exp(r)` gives `(z, rest)` or
`nothing`)."""
function lex_num(sci_exp, cs::Chars)
    x = DNumber.parse_raw(cs)
    x === nothing && return nothing
    n0, r = x
    s = sci_exp(r)
    if s !== nothing
        z, r3 = s
        m = sci_num(n0, z)
        m !== nothing && return TNum(m), r3
    end
    p = DNumber.parse(cs)
    p === nothing && return nothing
    return TNum(p[1]), p[2]
end

"""`Math.lexSigned`: a number where `-` starts it only when the value is below
zero (otherwise the `-` is a minus sign of its own)."""
function lex_signed(sci_exp, cs::Chars)
    if at(cs) == '-'
        x = lex_num(sci_exp, cs)
        (x === nothing || !(x[1] isa TNum)) && return nothing
        neg_num(x[1].n) && return x
        return TKw(KMinus), drop(cs)
    end
    return lex_num(sci_exp, cs)
end

end # module MSurface
