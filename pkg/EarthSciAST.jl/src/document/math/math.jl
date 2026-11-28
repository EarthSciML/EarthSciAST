"""
The math surfaces: LaTeX (Markdown documents) and Typst math.

Port of `formal/Esm/Document/Math/` (Rust `document::math`). One token type
(`MToken.Tok`) serves both surfaces; [`print`](@ref) writes an expression's
tokens under a symbol table, each surface renders and lexes its own spelling
(`MLatex`, `MTypst`), and [`parse_toks`](@ref) reads the tokens of either
surface back.

| Julia | Lean |
|---|---|
| `MExpr` | `Expr.lean` |
| `MToken` | `Token.lean` |
| `MSurface` | `Surface.lean` |
| `MPrint` | `Print.lean` |
| `MParse` | `Parse.lean`, `parseToks` of `Induct.lean`, `need` of `RoundTrip.lean` |
| `MLatex` | `Latex.lean` |
| `MTypst` | `Typst.lean` |
| `MUnits` | `Units/Typeset.lean` |
"""
module DMath

using ..DJson
using ..MToken: Sf, SF_LATEX, SF_TYPST, Tok
using ..MExpr: Sym
using ..MPrint: esc_t, raw_b, unesc_t
import ..MPrint, ..MParse, ..MLatex, ..MTypst

"""`Math.print` (Print.lean): the tokens of an expression under the symbol
table `s`."""
print(sf::Sf, s::Sym, e) = MPrint.print(sf, s, e)

"""`Math.parseToks` (Induct.lean): read a token list back under the symbol table
`s` (`nothing` when it does not read)."""
parse_toks(sf::Sf, s::Sym, toks::AbstractVector{<:Tok}) = MParse.parse_toks(sf, s, toks)

"""`Math.printLatex` (RoundTripLatex.lean): an expression (an `==` at its top is a
comparison, as in an event's condition, and prints as any expression does)."""
print_latex(s::Sym, e)::String = String(MLatex.render(MPrint.pa(MPrint.Ctx(SF_LATEX, s), 1, e)))

"""`Math.printLatexEqn` (RoundTripLatex.lean): an equation's expression,
`==(lhs, rhs)` (`Source.eqExpr`), in its defining form when it has one."""
print_latex_eqn(s::Sym, e)::String = String(MLatex.render(print(SF_LATEX, s, e)))

"""`Math.parseLatex` (RoundTripLatex.lean)."""
function parse_latex(s::Sym, text)
    toks = MLatex.lex(chars(text))
    toks === nothing && return nothing
    return parse_toks(SF_LATEX, s, toks)
end

"""`Math.printTypst` (RoundTripTypst.lean): an expression (an `==` at its top is a
comparison, as in an event's condition, and prints as any expression does)."""
print_typst(s::Sym, e)::String = String(MTypst.render(MPrint.pa(MPrint.Ctx(SF_TYPST, s), 1, e)))

"""`Math.printTypstEqn` (RoundTripTypst.lean): an equation's expression,
`==(lhs, rhs)` (`Source.eqExpr`), in its defining form when it has one."""
print_typst_eqn(s::Sym, e)::String = String(MTypst.render(print(SF_TYPST, s, e)))

"""`Math.parseTypst` (RoundTripTypst.lean)."""
function parse_typst(s::Sym, text)
    toks = MTypst.lex(chars(text))
    toks === nothing && return nothing
    return parse_toks(SF_TYPST, s, toks)
end

end # module DMath
