"""
Math tokens, shared by the two surfaces.

Port of `formal/Esm/Document/Math/Token.lean` (Rust `document::math::token`).
A token names what the surface text MEANS (`KLand` is `\\land` in LaTeX and
`and` in Typst), so one parser reads both; each surface has its own renderer
and lexer.
"""
module MToken

using ..DJson
using ..MUnits: Factor

export Kw, Tok, Sf, SF_LATEX, SF_TYPST,
    iskw, TNum, TLetter, TGreek, TWord, TIt, TRm, TUps, TOpn, TTxt, TJstr, TEsc, TCode, TUnits, TKw

"""`Math.Kw`: keywords and punctuation. `KLp`/`KRp` are call parentheses,
`KLpg`/`KRpg` grouping parentheses; `KLimitsL` is the LaTeX marker `\\limits`."""
@enum Kw begin
    # operators
    KPlus
    KMinus
    KEq
    KNe
    KLt
    KGt
    KLe
    KGe
    KLand
    KLor
    KLnot
    KCdot
    KTimes
    KSlash
    KCaret
    KUs
    # delimiters
    KLp
    KRp
    KLpg
    KRpg
    KLb
    KRb
    KLbk
    KRbk
    KComma
    KSemi
    KColon
    KAmp
    KNl
    KSdot
    # functions and notations
    KFrac
    KSqrt
    KExp
    KLn
    KLog
    KSin
    KCos
    KTan
    KAsin
    KAcos
    KAtan
    KSinh
    KCosh
    KTanh
    KMin
    KMax
    KLabs
    KRabs
    KLfloor
    KRfloor
    KLceil
    KRceil
    KAbs
    KFloor
    KCeil
    KPdiff
    KDif
    KDotacc
    KBcases
    KEcases
    KCases
    KEsmnode
    # constant arrays
    KBmat
    KEmat
    KVec
    KMat
    # faq reductions
    KSum
    KProd
    KInn
    KSubstack
    KLimits
    KLbkg
    KRbkg
    KLr
    KLimitsL
end
for k in instances(Kw)
    @eval export $(Symbol(k))
end

"""`Math.Tok`."""
abstract type Tok end

struct TNum <: Tok
    n::JNum
end
struct TLetter <: Tok
    c::Char
end
struct TGreek <: Tok
    s::String
end
struct TWord <: Tok
    s::String
end
struct TIt <: Tok
    s::String
end
"""LaTeX `\\mathrm{…}`, kept raw."""
struct TRm <: Tok
    s::String
end
"""Typst run of adjacent `upright("…")` pieces."""
struct TUps <: Tok
    ps::Vector{Tuple{String, String}}
end
struct TOpn <: Tok
    s::String
end
struct TTxt <: Tok
    s::String
end
"""LaTeX JSON string inside an escape node's fields."""
struct TJstr <: Tok
    s::String
end
"""LaTeX `\\esm{op}`."""
struct TEsc <: Tok
    s::String
end
"""Typst `#value`."""
struct TCode <: Tok
    j::Json
end
"""The unit after a quantity's number."""
struct TUnits <: Tok
    fs::Vector{Factor}
end
struct TKw <: Tok
    k::Kw
end

Base.:(==)(a::T, b::T) where {T <: Tok} = fieldeq(a, b)
Base.:(==)(a::Tok, b::Tok) = false
Base.hash(a::T, h::UInt) where {T <: Tok} =
    hash(ntuple(i -> getfield(a, i), fieldcount(T)), hash(T, h))

"""The token is the keyword `k`."""
iskw(t::Tok, k::Kw) = t isa TKw && t.k == k
iskw(::Nothing, ::Kw) = false

"""`Math.Sf`: which surface."""
@enum Sf SF_LATEX SF_TYPST

end # module MToken
