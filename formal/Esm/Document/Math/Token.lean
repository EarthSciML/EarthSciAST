import Esm.Document.Math.Expr

/-!
# Math tokens, shared by the two surfaces

One token type serves LaTeX math and Typst math. A token names what the surface text
MEANS (`land` is `\land` in LaTeX and `and` in Typst), so one parser reads both;
each surface has its own renderer and lexer (`Esm.Document.Math.Latex`,
`Esm.Document.Math.Typst`), and one lexer lemma per surface connects strings to
tokens.

A few tokens exist on one surface only: `rm` (LaTeX `\mathrm{…}`, kept raw: it holds
a formula, a name subscript or a unit), `jstr` (LaTeX JSON string, inside an escape
node's fields), `esc` (LaTeX `\esm{op}`); `ups` (Typst run of adjacent
`upright("…")` pieces), `code` (Typst `#value`), `units` (Typst ` thin upright(…)…`
unit block).
-/

namespace Esm.Document.Math

open Esm.Document

/-- Keywords and punctuation. -/
inductive Kw where
  -- operators
  | plus | minus | eq | ne | lt | gt | le | ge | land | lor | lnot | cdot | times | slash
  | caret | us
  -- delimiters: `lp`/`rp` call parentheses (LaTeX `(` `)`, Typst `(` right after a
  -- name or `)`), `lpg`/`rpg` grouping parentheses (LaTeX `\left(` `\right)`, Typst
  -- `(` after a space or an operator; Typst has no `rpg`)
  | lp | rp | lpg | rpg | lb | rb | lbk | rbk | comma | semi | colon | amp | nl | sdot | thin
  -- functions and notations
  | frac | sqrt | exp | ln | log | sin | cos | tan | asin | acos | atan | sinh | cosh | tanh
  | min | max | labs | rabs | lfloor | rfloor | lceil | rceil | abs | floor | ceil
  | pdiff | dif | dotacc | bcases | ecases | cases | esmnode
  -- constant arrays: LaTeX `\begin{bmatrix}` `\end{bmatrix}`, Typst `vec` `mat`
  | bmat | emat | vec | mat
  -- faq reductions: `\sum` `\prod` `\in` `\substack` `\limits` `\left[` `\right]`, Typst `lr`
  | sum | prod | inn | substack | limits | lbkg | rbkg | lr
  -- the LaTeX marker `\limits` (Typst writes `limits(…)` around the operator)
  | limitsL
  deriving DecidableEq, Repr

inductive Tok where
  | num (n : JNum)
  | letter (c : Char)
  | greek (g : String)
  | word (s : String)
  | it (s : String)
  | rm (raw : String)
  | ups (ps : List (String × String))
  | opn (s : String)
  | txt (s : String)
  | jstr (s : String)
  | esc (op : String)
  | code (j : Json)
  | units (l : List Esm.Units.Factor)
  | kw (k : Kw)

/-- Which surface. -/
inductive Sf where
  | latex
  | typst
  deriving DecidableEq, Repr

end Esm.Document.Math
