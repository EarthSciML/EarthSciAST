---
title: "Math tokens, shared by the two surfaces"
type: lean
lean_module: "Esm.Document.Math.Token"
weight: 7
---

<p class="lean-meta">Lean module <code>Esm.Document.Math.Token</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Token.lean"><code>formal/Esm/Document/Math/Token.lean</code></a> at <code>ffd5aee2f868</code><br>Imports <a href="/generated/document-formats/esm-document-math-expr"><code>Esm.Document.Math.Expr</code></a></p>

One token type serves LaTeX math and Typst math. A token names what the surface text
MEANS (`land` is `\land` in LaTeX and `and` in Typst), so one parser reads both;
each surface has its own renderer and lexer ([`Esm.Document.Math.Latex`](/generated/document-formats/esm-document-math-latex),
[`Esm.Document.Math.Typst`](/generated/document-formats/esm-document-math-typst)), and one lexer lemma per surface connects strings to
tokens.

A few tokens exist on one surface only: `rm` (LaTeX `\mathrm{…}`, kept raw: it holds
a formula or a name subscript), `jstr` (LaTeX JSON string, inside an escape node's
fields), `esc` (LaTeX `\esm{op}`); `ups` (Typst run of adjacent `upright("…")` pieces),
`code` (Typst `#value`). `units` is the unit after a quantity's number, one token on both
surfaces: LaTeX `\,\mathrm{…}`, Typst ` thin upright(…)…`.

<div class="lean-decl" id="Esm.Document.Math.Kw">
<div class="lean-decl-head"><span class="lean-kind">inductive</span> <a class="lean-name" href="#Esm.Document.Math.Kw" title="Esm.Document.Math.Kw"><code>Kw</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Token.lean#L24-L49">source</a></div>

```lean
inductive Kw where
  -- operators
  | plus | minus | eq | ne | lt | gt | le | ge | land | lor | lnot | cdot | times | slash
  | caret | us
  -- delimiters: `lp`/`rp` call parentheses (LaTeX `(` `)`, Typst `(` right after a
  -- name or `)`), `lpg`/`rpg` grouping parentheses (LaTeX `\left(` `\right)`, Typst
  -- `(` after a space or an operator; Typst has no `rpg`)
  | lp | rp | lpg | rpg | lb | rb | lbk | rbk | comma | semi | colon | amp | nl | sdot
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
  -- makearray: LaTeX `\begin{array}{l|l}` `\end{array}`
  | barr | earr
  -- a constant matrix wider than `bmatrix` allows: LaTeX `\begin{array}{c…c}`, one `c` per
  -- column (`n` of them), closed by `\end{array}`
  | barrC (n : Nat)
  -- a set of names, LaTeX `\{` `\}`, Typst `{` `}` (the `args` of a `faq`)
  | lset | rset
  deriving DecidableEq, Repr
```

Keywords and punctuation.

</div>

<div class="lean-decl" id="Esm.Document.Math.Sf">
<div class="lean-decl-head"><span class="lean-kind">inductive</span> <a class="lean-name" href="#Esm.Document.Math.Sf" title="Esm.Document.Math.Sf"><code>Sf</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Token.lean#L68-L71">source</a></div>

```lean
inductive Sf where
  | latex
  | typst
  deriving DecidableEq, Repr
```

Which surface.

</div>
