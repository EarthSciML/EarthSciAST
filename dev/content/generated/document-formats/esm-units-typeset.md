---
title: "Typeset unit spellings: LaTeX and Typst, with no unit package"
type: lean
lean_module: "Esm.Units.Typeset"
weight: 67
---

<p class="lean-meta">Lean module <code>Esm.Units.Typeset</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Units/Typeset.lean"><code>formal/Esm/Units/Typeset.lean</code></a> at <code>1b8dd9b3a909</code><br>Imports <a href="/generated/document-formats/esm-units-canonical"><code>Esm.Units.Canonical</code></a></p>

A `const` with units prints in a document as the number, a thin space, then the
canonical unit ([`Esm.Document.Notation`](/generated/document-formats/esm-document-notation)). This module gives the two typeset
forms of a canonical factor list ([`CanonFactors`](/generated/document-formats/esm-units-canonical#Esm.Units.CanonFactors), [`Esm.Units.Canonical`](/generated/document-formats/esm-units-canonical)), a
parser for each, and the round-trip theorems.

**LaTeX** ([`latex`](#Esm.Units.latex)): the canonical spelling's layout inside `\mathrm{…}`.
The numerator factors are joined by a thin space `\,`, a denominator follows
`/`, parenthesized when it has more than one factor; an exponent is a braced
superscript `^{3}` or `^{1/3}` (braces are required: `^12` would raise only
the `1`). Inside `\mathrm{}` an underscore is a subscript and `%` starts a
comment, so a symbol's `_` is written `\_` and its `%` is written `\%`. So
`J/(K*mol)` is `\mathrm{J/(K\,mol)}`, `short_ton/yr` is `\mathrm{short\_ton/yr}`.

**Typst** ([`typst`](#Esm.Units.typst)): one `upright("sym")^(exp)` per factor, with its SIGNED
exponent and no `/`: the positive-exponent factors, then the negative ones, each
group in symbol order (the order the canonical spelling reads in). The exponent is omitted when it is 1, is
`^3` for a positive integer, `^(-1)` for a negative one and `^(1\/3)` or
`^(-1\/3)` for a non-integer (`\/` is Typst's literal slash; a bare `/` in
math would build a fraction). Factors are separated by ` thin `: Typst math
sets two adjacent `upright` texts with no space between them (`cm³molec⁻¹`),
so the thin space is what keeps the factors apart. Symbols are `%` or runs of
`[A-Za-z0-9_]`, so no character in a Typst string needs escaping. The
dimensionless unit is `1` in both forms.

Theorems: [`parseLatex_latex`](#Esm.Units.parseLatex_latex) and [`parseTypst_typst`](#Esm.Units.parseTypst_typst), over every canonical factor
list.

## Shared parsing pieces

<div class="lean-decl lean-theorem" id="Esm.Units.dropPrefix?_append">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.dropPrefix?_append" title="Esm.Units.dropPrefix?_append"><code>dropPrefix?_append</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Units/Typeset.lean#L43-L44">source</a></div>

```lean
theorem dropPrefix?_append (p rest : List Char) : (p ++ rest).dropPrefix? p = some rest
```

Stripping a literal prefix (`List.dropPrefix?`) undoes prepending it.

The literal prefixes below that are spelled as `String.toList` are `@[noinline]`: the
compiler otherwise specializes `List.dropPrefix?` to the literal and tries to evaluate
`String.toList` at compile time, which makes compiling these definitions very slow.

</div>

<div class="lean-decl" id="Esm.Units.pDigits">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.pDigits" title="Esm.Units.pDigits"><code>pDigits</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Units/Typeset.lean#L47-L49">source</a></div>

```lean
def pDigits (cs : List Char) : Option (ℕ × List Char)
```

A run of digits, read as a natural number.

</div>

<div class="lean-decl" id="Esm.Units.NoDigitHead">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.NoDigitHead" title="Esm.Units.NoDigitHead"><code>NoDigitHead</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Units/Typeset.lean#L52">source</a></div>

```lean
def NoDigitHead (rest : List Char) : Prop
```

What may follow a digit run without extending it.

</div>

<div class="lean-decl" id="Esm.Units.joinWith">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.joinWith" title="Esm.Units.joinWith"><code>joinWith</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Units/Typeset.lean#L62-L64">source</a></div>

```lean
def joinWith (pr : Factor → List Char) (sep : List Char) : List Factor → List Char
```

Items printed by `pr`, joined by `sep`.

</div>

<div class="lean-decl" id="Esm.Units.pSepBy">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.pSepBy" title="Esm.Units.pSepBy"><code>pSepBy</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Units/Typeset.lean#L72-L84">source</a></div>

```lean
def pSepBy (pf : List Char → Option (Factor × List Char)) (sep : List Char) :
    ℕ → List Char → Option (List Factor × List Char)
```

Items read by `pf`, separated by `sep`; at least one.

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.pSepBy_joinWith">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.pSepBy_joinWith" title="Esm.Units.pSepBy_joinWith"><code>pSepBy_joinWith</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Units/Typeset.lean#L89-L108">source</a></div>

```lean
theorem pSepBy_joinWith (pf : List Char → Option (Factor × List Char)) (pr : Factor → List Char)
    (sep : List Char) (P : Factor → Prop) (Stop : List Char → Prop)
    (hpf : ∀ f, P f → ∀ rest, Stop rest → pf (pr f ++ rest) = some (f, rest))
    (hsep : ∀ x, Stop (sep ++ x)) :
    ∀ (fs : List Factor) (f : Factor) (rest : List Char), (∀ g ∈ f :: fs, P g) → Stop rest →
      rest.dropPrefix? sep = none → ∀ n, fs.length < n →
      pSepBy pf sep n (joinWith pr sep (f :: fs) ++ rest) = some (f :: fs, rest)
```

Reading back a joined list: each item reads back before anything satisfying
`Stop`, the separator is such a thing, and the list ends before something that is
not a separator.

</div>

## LaTeX

<div class="lean-decl" id="Esm.Units.latexSym">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.latexSym" title="Esm.Units.latexSym"><code>latexSym</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Units/Typeset.lean#L113-L115">source</a></div>

```lean
def latexSym : List Char → List Char
```

A symbol's characters with `_` and `%` escaped.

</div>

<div class="lean-decl" id="Esm.Units.latexExp">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.latexExp" title="Esm.Units.latexExp"><code>latexExp</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Units/Typeset.lean#L118-L121">source</a></div>

```lean
def latexExp (q : ℚ) : List Char
```

A positive exponent as a braced superscript (nothing for 1).

</div>

<div class="lean-decl" id="Esm.Units.latexFactor">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.latexFactor" title="Esm.Units.latexFactor"><code>latexFactor</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Units/Typeset.lean#L124">source</a></div>

```lean
def latexFactor (f : Factor) : List Char
```

One factor, with the absolute value of its exponent.

</div>

<div class="lean-decl" id="Esm.Units.latexBody">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.latexBody" title="Esm.Units.latexBody"><code>latexBody</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Units/Typeset.lean#L129-L134">source</a></div>

```lean
def latexBody (l : List Factor) : List Char
```

The body of `\mathrm{…}`.

</div>

<div class="lean-decl" id="Esm.Units.latex">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.latex" title="Esm.Units.latex"><code>latex</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Units/Typeset.lean#L139">source</a></div>

```lean
def latex (l : List Factor) : String
```

The LaTeX form of a canonical factor list.

</div>

<div class="lean-decl" id="Esm.Units.pLSym">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.pLSym" title="Esm.Units.pLSym"><code>pLSym</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Units/Typeset.lean#L142-L150">source</a></div>

```lean
def pLSym : List Char → List Char × List Char
```

Read a symbol: identifier characters, `%`, and the escapes `\_`, `\%`.

</div>

<div class="lean-decl" id="Esm.Units.pLExp">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.pLExp" title="Esm.Units.pLExp"><code>pLExp</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Units/Typeset.lean#L153-L162">source</a></div>

```lean
def pLExp : List Char → Option (ℚ × List Char)
```

Read a braced superscript, or nothing (exponent 1).

</div>

<div class="lean-decl" id="Esm.Units.pLDen">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.pLDen" title="Esm.Units.pLDen"><code>pLDen</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Units/Typeset.lean#L173-L181">source</a></div>

```lean
def pLDen (r : List Char) : Option (List Factor)
```

Read a LaTeX denominator (after the `/`): one factor, or a parenthesized list.

</div>

<div class="lean-decl" id="Esm.Units.parseLatex">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.parseLatex" title="Esm.Units.parseLatex"><code>parseLatex</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Units/Typeset.lean#L184-L199">source</a></div>

```lean
def parseLatex (s : String) : Option (List Factor)
```

Read a LaTeX unit back to its two-sided factor list.

</div>

### The LaTeX round trip

<div class="lean-decl" id="Esm.Units.SymChars">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.SymChars" title="Esm.Units.SymChars"><code>SymChars</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Units/Typeset.lean#L227">source</a></div>

```lean
def SymChars (cs : List Char) : Prop
```

Characters a symbol may contain.

</div>

<div class="lean-decl" id="Esm.Units.LStop">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.LStop" title="Esm.Units.LStop"><code>LStop</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Units/Typeset.lean#L243">source</a></div>

```lean
def LStop (rest : List Char) : Prop
```

What stops a LaTeX symbol run: not a symbol character, not an escape.

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.pLExp_latexExp">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.pLExp_latexExp" title="Esm.Units.pLExp_latexExp"><code>pLExp_latexExp</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Units/Typeset.lean#L266-L283">source</a></div>

```lean
theorem pLExp_latexExp (q : ℚ) (hq : 0 < q) (rest : List Char) (hr : ∀ r, rest ≠ '^' :: r) :
    pLExp (latexExp q ++ rest) = some (q, rest)
```

A positive exponent reads back.

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.pLFactor_latexFactor">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.pLFactor_latexFactor" title="Esm.Units.pLFactor_latexFactor"><code>pLFactor_latexFactor</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Units/Typeset.lean#L294-L299">source</a></div>

```lean
theorem pLFactor_latexFactor (f : Factor) (hs : SymChars f.1.toList) (hq : 0 < f.2)
    (rest : List Char) (hr : LStop rest) : pLFactor (latexFactor f ++ rest) = some (f, rest)
```

One LaTeX factor reads back (with its positive exponent).

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.pSepBy_latex">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.pSepBy_latex" title="Esm.Units.pSepBy_latex"><code>pSepBy_latex</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Units/Typeset.lean#L312-L318">source</a></div>

```lean
theorem pSepBy_latex (fs : List Factor) (f : Factor)
    (hP : ∀ g ∈ f :: fs, SymChars g.1.toList ∧ 0 < g.2) (rest : List Char) (hS : LStop rest)
    (hD : rest.dropPrefix? latexSep = none) (n : ℕ) (hn : fs.length < n) :
    pSepBy pLFactor latexSep n (joinWith latexFactor latexSep (f :: fs) ++ rest) =
      some (f :: fs, rest)
```

A list of positive-exponent factors reads back from its LaTeX join.

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.parseLatex_latex">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.parseLatex_latex" title="Esm.Units.parseLatex_latex"><code>parseLatex_latex</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Units/Typeset.lean#L328-L445">source</a></div>

```lean
theorem parseLatex_latex :
    ∀ l : List Factor, CanonFactors l → parseLatex (latex l) = some l
```

**LaTeX round trip.** Every canonical factor list reads back from its LaTeX form.

</div>

## Typst

<div class="lean-decl" id="Esm.Units.typstExp">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.typstExp" title="Esm.Units.typstExp"><code>typstExp</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Units/Typeset.lean#L454-L459">source</a></div>

```lean
def typstExp (q : ℚ) : List Char
```

A signed exponent: nothing for 1, `^n`, `^(-n)`, `^(p\/q)`, `^(-p\/q)`.

</div>

<div class="lean-decl" id="Esm.Units.typstFactor">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.typstFactor" title="Esm.Units.typstFactor"><code>typstFactor</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Units/Typeset.lean#L462-L463">source</a></div>

```lean
def typstFactor (f : Factor) : List Char
```

One factor: `upright("sym")` and its signed exponent.

</div>

<div class="lean-decl" id="Esm.Units.typst">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.typst" title="Esm.Units.typst"><code>typst</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Units/Typeset.lean#L468-L469">source</a></div>

```lean
def typst (l : List Factor) : String
```

The Typst form of a canonical factor list (`1` when it is empty): the
positive-exponent factors, then the negative ones, each group in symbol order
(the order the canonical spelling reads in).

</div>

<div class="lean-decl" id="Esm.Units.pTParen">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.pTParen" title="Esm.Units.pTParen"><code>pTParen</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Units/Typeset.lean#L472-L484">source</a></div>

```lean
def pTParen (cs : List Char) : Option (ℚ × List Char)
```

After `^(`: `'-'? digits (')' | '\/' digits ')')`.

</div>

<div class="lean-decl" id="Esm.Units.pTExp">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.pTExp" title="Esm.Units.pTExp"><code>pTExp</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Units/Typeset.lean#L487-L495">source</a></div>

```lean
def pTExp (cs : List Char) : Option (ℚ × List Char)
```

An optional exponent (none means 1).

</div>

<div class="lean-decl" id="Esm.Units.parseTypst">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.parseTypst" title="Esm.Units.parseTypst"><code>parseTypst</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Units/Typeset.lean#L510-L515">source</a></div>

```lean
def parseTypst (s : String) : Option (List Factor)
```

Read a Typst unit back to its two-sided factor list.

</div>

### The Typst round trip

<div class="lean-decl" id="Esm.Units.TStop">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.TStop" title="Esm.Units.TStop"><code>TStop</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Units/Typeset.lean#L520">source</a></div>

```lean
def TStop (rest : List Char) : Prop
```

What may follow a Typst factor: not an exponent, not a digit.

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.parseTypst_typst">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.parseTypst_typst" title="Esm.Units.parseTypst_typst"><code>parseTypst_typst</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Units/Typeset.lean#L612-L640">source</a></div>

```lean
theorem parseTypst_typst :
    ∀ l : List Factor, CanonFactors l → parseTypst (typst l) = some l
```

**Typst round trip.** Every canonical factor list reads back from its Typst form.

</div>

<p class="lean-meta">This module also proves 22 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Units/Typeset.lean">the source</a>.</p>
