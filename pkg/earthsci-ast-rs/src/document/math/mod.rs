//! The math surfaces: LaTeX (Markdown documents) and Typst math.
//!
//! Port of `formal/Esm/Document/Math/`. One token type ([`token::Tok`]) serves
//! both surfaces; [`print`] writes an expression's tokens under a symbol table,
//! each surface renders and lexes its own spelling, and [`parse_toks`] reads
//! the tokens of either surface back.

pub mod expr;
pub mod token;
pub mod units;

pub use expr::Sym;
use token::{Sf, Tok};

use crate::document::json::Json;

/// `Math.print`: the tokens of an expression under the symbol table `s`.
pub fn print(_sf: Sf, _s: &Sym, _e: &Json) -> Vec<Tok> {
    todo!("math layer")
}

/// `Math.parseToks`: read a token list back under the symbol table `s`.
pub fn parse_toks(_sf: Sf, _s: &Sym, _toks: &[Tok]) -> Option<Json> {
    todo!("math layer")
}

/// `Math.printLatex` (RoundTripLatex.lean).
pub fn print_latex(s: &Sym, e: &Json) -> String {
    latex::render(&print(Sf::Latex, s, e)).into_iter().collect()
}

/// `Math.parseLatex` (RoundTripLatex.lean).
pub fn parse_latex(s: &Sym, text: &str) -> Option<Json> {
    let cs: Vec<char> = text.chars().collect();
    latex::lex(&cs).and_then(|toks| parse_toks(Sf::Latex, s, &toks))
}

/// `Math.printTypst` (RoundTripTypst.lean).
pub fn print_typst(s: &Sym, e: &Json) -> String {
    typst::render(&print(Sf::Typst, s, e)).into_iter().collect()
}

/// `Math.parseTypst` (RoundTripTypst.lean).
pub fn parse_typst(s: &Sym, text: &str) -> Option<Json> {
    let cs: Vec<char> = text.chars().collect();
    typst::lex(&cs).and_then(|toks| parse_toks(Sf::Typst, s, &toks))
}

/// `Math.escT` (Print.lean): a backslash before every character of `escSet`.
pub fn esc_t(_cs: &[char]) -> Vec<char> {
    todo!("math layer")
}

/// `Math.unescT` (Print.lean): drop the backslash of every `\c` pair.
pub fn unesc_t(_cs: &[char]) -> Vec<char> {
    todo!("math layer")
}

/// `Math.rawB` (Print.lean): raw text up to the closing brace at depth `d`.
pub fn raw_b(_d: usize, _cs: &[char]) -> Option<(Vec<char>, &[char])> {
    todo!("math layer")
}

/// The LaTeX surface (`Math.Latex`).
pub mod latex {
    use super::token::Tok;

    /// `Latex.render`.
    pub fn render(_toks: &[Tok]) -> Vec<char> {
        todo!("math layer")
    }

    /// `Latex.lex`.
    pub fn lex(_cs: &[char]) -> Option<Vec<Tok>> {
        todo!("math layer")
    }
}

/// The Typst surface (`Math.Typst`).
pub mod typst {
    use super::token::Tok;

    /// `Typst.render`.
    pub fn render(_toks: &[Tok]) -> Vec<char> {
        todo!("math layer")
    }

    /// `Typst.lex`.
    pub fn lex(_cs: &[char]) -> Option<Vec<Tok>> {
        todo!("math layer")
    }
}
