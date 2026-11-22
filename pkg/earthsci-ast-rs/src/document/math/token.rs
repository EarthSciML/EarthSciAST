//! Math tokens, shared by the two surfaces.
//!
//! Port of `formal/Esm/Document/Math/Token.lean`. A token names what the surface
//! text MEANS (`Land` is `\land` in LaTeX and `and` in Typst), so one parser
//! reads both; each surface has its own renderer and lexer.

use crate::document::json::{JNum, Json};
use crate::document::math::units::Factor;

/// `Math.Kw`: keywords and punctuation.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Kw {
    // operators
    Plus,
    Minus,
    Eq,
    Ne,
    Lt,
    Gt,
    Le,
    Ge,
    Land,
    Lor,
    Lnot,
    Cdot,
    Times,
    Slash,
    Caret,
    Us,
    // delimiters: `Lp`/`Rp` call parentheses, `Lpg`/`Rpg` grouping parentheses
    Lp,
    Rp,
    Lpg,
    Rpg,
    Lb,
    Rb,
    Lbk,
    Rbk,
    Comma,
    Semi,
    Colon,
    Amp,
    Nl,
    Sdot,
    // functions and notations
    Frac,
    Sqrt,
    Exp,
    Ln,
    Log,
    Sin,
    Cos,
    Tan,
    Asin,
    Acos,
    Atan,
    Sinh,
    Cosh,
    Tanh,
    Min,
    Max,
    Labs,
    Rabs,
    Lfloor,
    Rfloor,
    Lceil,
    Rceil,
    Abs,
    Floor,
    Ceil,
    Pdiff,
    Dif,
    /// `\nabla` / `nabla`: the head of the `grad`, `div`, `laplacian` and `curl`
    /// forms (esm-spec §1.2).
    Nabla,
    Dotacc,
    Bcases,
    Ecases,
    Cases,
    Esmnode,
    // constant arrays
    Bmat,
    Emat,
    Vec,
    Mat,
    // faq reductions
    Sum,
    Prod,
    Inn,
    Substack,
    Limits,
    Lbkg,
    Rbkg,
    Lr,
    /// The LaTeX marker `\limits`.
    LimitsL,
    // makearray: LaTeX `\begin{array}{l|l}`; LaTeX `\end{array}`, which also
    // closes a wide constant matrix ([`Tok::Carr`])
    Barr,
    Earr,
    // a set of names, LaTeX `\{` `\}`, Typst `{` `}` (the `args` of a `faq`)
    Lset,
    Rset,
}

/// `Math.Tok`.
#[derive(Clone, Debug, PartialEq)]
pub enum Tok {
    Num(JNum),
    Letter(char),
    Greek(String),
    Word(String),
    It(String),
    /// LaTeX `\mathrm{…}`, kept raw.
    Rm(String),
    /// Typst run of adjacent `upright("…")` pieces.
    Ups(Vec<(String, String)>),
    Opn(String),
    Txt(String),
    /// LaTeX JSON string inside an escape node's fields.
    Jstr(String),
    /// LaTeX `\esm{op}`.
    Esc(String),
    /// Typst `#value`.
    Code(Json),
    /// LaTeX `\begin{array}{c…c}` with this many columns: a constant matrix
    /// wider than `bmatrix` allows.
    Carr(usize),
    /// The unit after a quantity's number.
    Units(Vec<Factor>),
    Kw(Kw),
}

/// `Math.Sf`: which surface.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Sf {
    Latex,
    Typst,
}
