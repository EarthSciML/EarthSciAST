---
title: "Pieces the LaTeX and Typst spellings share"
type: lean
lean_module: "Esm.Document.Math.Surface"
weight: 8
---

<p class="lean-meta">Lean module <code>Esm.Document.Math.Surface</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Surface.lean"><code>formal/Esm/Document/Math/Surface.lean</code></a> at <code>ffd5aee2f868</code><br>Imports <a href="/generated/document-formats/esm-document-math-token"><code>Esm.Document.Math.Token</code></a></p>

The two surfaces ([`Esm.Document.Math.Latex`](/generated/document-formats/esm-document-math-latex), [`Esm.Document.Math.Typst`](/generated/document-formats/esm-document-math-typst)) differ in their
keyword spellings and lexers, but read numbers alike: a number in its JSON spelling, or a
scientific literal `mantissa × 10^exponent`, where only the spelling of `× 10^` and of
the exponent's brackets differs. [`lexNum`](#Esm.Document.Math.lexNum) takes that difference as a parameter
(`sciExp`, which reads the tail after the mantissa), so the literal rule is written and
proved once:

* the tail is read with any amount of white space (none included) between its parts,
  so spacing never changes what is read;
* a mantissa (with or without a decimal point) followed by a complete tail is one
  literal; a tail whose exponent is not an integer (`10^{n}`) leaves the number alone,
  and the rest reads as an ordinary product.

A leading `-` belongs to the number only when its value is below zero ([`lexSigned`](#Esm.Document.Math.lexSigned)):
`-0` reads as a minus sign and `0`. Whether a negative literal is a literal or a binary
minus depends on what precedes it, which the parser decides ([`Esm.Document.Math.Parse`](/generated/document-formats/esm-document-math-parse),
`addLoop`).

## Literal prefixes

<div class="lean-decl" id="Esm.Document.Math.dropP">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.dropP" title="Esm.Document.Math.dropP"><code>dropP</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Surface.lean#L32-L35">source</a></div>

```lean
def dropP : List Char → List Char → Option (List Char)
```

Strip a literal prefix.

</div>

## Spacing

<div class="lean-decl" id="Esm.Document.Math.isBin">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.isBin" title="Esm.Document.Math.isBin"><code>isBin</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Surface.lean#L45-L49">source</a></div>

```lean
def isBin : Tok → Bool
```

Binary operators, spaced on both sides.

</div>

## Numbers

<div class="lean-decl" id="Esm.Document.Math.sciSplit">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.sciSplit" title="Esm.Document.Math.sciSplit"><code>sciSplit</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Surface.lean#L55-L60">source</a></div>

```lean
def sciSplit : JNum → Option (List Char × Int)
```

The mantissa (with its sign) and exponent of a number printed in scientific
notation.

</div>

<div class="lean-decl" id="Esm.Document.Math.negNum">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.negNum" title="Esm.Document.Math.negNum"><code>negNum</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Surface.lean#L63-L65">source</a></div>

```lean
def negNum : JNum → Bool
```

A number below zero.

</div>

<div class="lean-decl" id="Esm.Document.Math.sciNum">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.sciNum" title="Esm.Document.Math.sciNum"><code>sciNum</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Surface.lean#L69-L75">source</a></div>

```lean
def sciNum (n0 : JNum) (z : Int) : Option JNum
```

The value of a mantissa (as [`Number.parseRaw`](/generated/document-formats/esm-document-number#Esm.Document.Number.parseRaw) reads it, an integer or a decimal)
times `10^z`, in canonical form; `none` for a value with no canonical form.

</div>

<div class="lean-decl" id="Esm.Document.Math.lexNum">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.lexNum" title="Esm.Document.Math.lexNum"><code>lexNum</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Surface.lean#L80-L91">source</a></div>

```lean
def lexNum (sciExp : List Char → Option (Int × List Char)) (cs : List Char) :
    Option (Tok × List Char)
```

A number: its JSON spelling, or a decimal mantissa followed by a scientific tail that
`sciExp` reads (returning the exponent and what follows). The token ends where the number
as written ends ([`Number.parseRaw`](/generated/document-formats/esm-document-number#Esm.Document.Number.parseRaw)); its value is the canonical form.

</div>

<div class="lean-decl" id="Esm.Document.Math.lexSigned">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.lexSigned" title="Esm.Document.Math.lexSigned"><code>lexSigned</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Surface.lean#L95-L102">source</a></div>

```lean
def lexSigned (sciExp : List Char → Option (Int × List Char)) (cs : List Char) :
    Option (Tok × List Char)
```

A number at the front of the input, where `-` starts it only when the value is below
zero (otherwise the `-` is a minus sign of its own).

</div>

## Reading numbers back

<div class="lean-decl lean-theorem" id="Esm.Document.Math.lexNum_plain">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.lexNum_plain" title="Esm.Document.Math.lexNum_plain"><code>lexNum_plain</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Surface.lean#L107-L116">source</a></div>

```lean
theorem lexNum_plain (sciExp : List Char → Option (Int × List Char)) (n : JNum) (hn : n.WF)
    (X : List Char) (hX : Number.NumStop X) (hs : sciExp X = none) :
    lexNum sciExp (Number.print n ++ X) = some (.num n, X)
```

A number in its JSON spelling, before a tail that is not scientific.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.lexNum_sci">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.lexNum_sci" title="Esm.Document.Math.lexNum_sci"><code>lexNum_sci</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Surface.lean#L128-L182">source</a></div>

```lean
theorem lexNum_sci (sciExp : List Char → Option (Int × List Char)) (n : JNum) (hn : n.WF)
    (m : List Char) (e : Int) (hsp : sciSplit n = some (m, e)) (T X : List Char)
    (hT : sciExp T = some (e, X)) (hTh : ∀ c ∈ T.head?, c.isDigit = false ∧ c ≠ 'e') :
    lexNum sciExp (m ++ T) = some (.num n, X)
```

A number in scientific spelling: its mantissa, then a tail `sciExp` reads as its
exponent.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.lexSigned_of">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.lexSigned_of" title="Esm.Document.Math.lexSigned_of"><code>lexSigned_of</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Surface.lean#L226-L237">source</a></div>

```lean
theorem lexSigned_of (sciExp : List Char → Option (Int × List Char)) (N X : List Char) (n : JNum)
    (hN : N ≠ []) (hneg : ∀ r, N = '-' :: r → negNum n = true)
    (h : lexNum sciExp (N ++ X) = some (.num n, X)) : lexSigned sciExp (N ++ X) = some (.num n, X)
```

A number spelled `N` reads back with its sign: a spelling that starts with `-` is
of a negative number.

</div>

<p class="lean-meta">This module also proves 4 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Surface.lean">the source</a>.</p>
