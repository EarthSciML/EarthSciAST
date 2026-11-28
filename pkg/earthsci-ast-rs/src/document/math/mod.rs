//! The math surfaces: LaTeX (Markdown documents) and Typst math.
//!
//! Port of `formal/Esm/Document/Math/`. One token type ([`token::Tok`]) serves
//! both surfaces; [`print()`] writes an expression's tokens under a symbol table,
//! [`print_latex`] / [`print_typst`] render an expression and
//! [`print_latex_eqn`] / [`print_typst_eqn`] an equation (in its defining form
//! when it has one), each surface renders and lexes its own spelling, and [`parse_toks`] reads
//! the tokens of either surface back.
//!
//! | Rust | Lean |
//! |---|---|
//! | [`expr`] | `Expr.lean` |
//! | [`token`] | `Token.lean` |
//! | [`surface`] | `Surface.lean` |
//! | [`print`](mod@print) | `Print.lean` |
//! | [`parse`] | `Parse.lean`, `parseToks` of `Induct.lean`, `need` of `RoundTrip.lean` |
//! | [`latex`] | `Latex.lean` |
//! | [`typst`] | `Typst.lean` |
//! | [`units`] | `Units/Typeset.lean` |
//!
//! The other Lean files under `Math/` (View, Levels, Names, Faq, Main, the
//! `Cases*`, `Lex*` and `Tok*` files, …) hold the round-trip proofs and the
//! predicates they are stated with; they have no executable definitions the
//! printer or the parser use. `HandWritten.lean`'s checks are unit tests in
//! [`tests`].

pub mod expr;
pub mod latex;
pub mod parse;
pub mod print;
pub mod surface;
pub mod token;
pub mod typst;
pub mod units;

#[cfg(test)]
mod tests;

pub use expr::Sym;
pub use print::{esc_t, raw_b, unesc_t};
use token::{Sf, Tok};

use crate::document::json::Json;

/// `Math.print` (Print.lean): the tokens of an expression under the symbol
/// table `s`.
pub fn print(sf: Sf, s: &Sym, e: &Json) -> Vec<Tok> {
    print::print(sf, s, e)
}

/// `Math.parseToks` (Induct.lean): read a token list back under the symbol
/// table `s`.
pub fn parse_toks(sf: Sf, s: &Sym, toks: &[Tok]) -> Option<Json> {
    parse::parse_toks(sf, s, toks)
}

/// `Math.printLatex` (RoundTripLatex.lean): the LaTeX of an expression (an
/// `==` at its top is a comparison and prints as any expression does).
pub fn print_latex(s: &Sym, e: &Json) -> String {
    latex::render(&print::pa(print::Ctx { sf: Sf::Latex, s }, 1, e))
        .into_iter()
        .collect()
}

/// `Math.printLatexEqn` (RoundTripLatex.lean): the LaTeX of an equation's
/// expression, `==(lhs, rhs)`, in its defining form when it has one
/// ([`print()`]).
pub fn print_latex_eqn(s: &Sym, e: &Json) -> String {
    latex::render(&print(Sf::Latex, s, e)).into_iter().collect()
}

/// `Math.parseLatex` (RoundTripLatex.lean).
pub fn parse_latex(s: &Sym, text: &str) -> Option<Json> {
    let cs: Vec<char> = text.chars().collect();
    latex::lex(&cs).and_then(|toks| parse_toks(Sf::Latex, s, &toks))
}

/// `Math.printTypst` (RoundTripTypst.lean): the Typst math of an expression
/// (an `==` at its top is a comparison, as in an event's condition, and prints
/// as any expression does).
pub fn print_typst(s: &Sym, e: &Json) -> String {
    typst::render(&print::pa(print::Ctx { sf: Sf::Typst, s }, 1, e))
        .into_iter()
        .collect()
}

/// `Math.printTypstEqn` (RoundTripTypst.lean): the Typst math of an equation's
/// expression, `==(lhs, rhs)` (`Source.eqExpr`), an equation `x = faq` with
/// output indices in its defining form `x_s = …, s ∈ S` when it has one
/// ([`print()`]).
pub fn print_typst_eqn(s: &Sym, e: &Json) -> String {
    typst::render(&print(Sf::Typst, s, e)).into_iter().collect()
}

/// `Math.parseTypst` (RoundTripTypst.lean).
pub fn parse_typst(s: &Sym, text: &str) -> Option<Json> {
    let cs: Vec<char> = text.chars().collect();
    typst::lex(&cs).and_then(|toks| parse_toks(Sf::Typst, s, &toks))
}
