---
title: "The canonical number spelling (CONFORMANCE §5.5.3.1)"
type: lean
lean_module: "Esm.Document.Number"
weight: 2
---

<p class="lean-meta">Lean module <code>Esm.Document.Number</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Number.lean"><code>formal/Esm/Document/Number.lean</code></a> at <code>5af01ca9d41a</code><br>Imports <a href="/generated/document-formats/esm-document-json"><code>Esm.Document.Json</code></a>, <code>Esm.Digits</code></p>

* An integer prints plainly, `-` for a negative one.
* A decimal prints its digits positionally when its decimal exponent `e10` is in
  `[-4, 5]` (`0.000123456`, `999999.5`), and otherwise in scientific notation
  `d.f…e<exp>` with at least one fraction digit, a lowercase `e`, and `-` but never `+`
  on the exponent (`1.0e-9`, `1.0000005e6`).

[`print`](#Esm.Document.Number.print) writes the spelling, [`parse`](#Esm.Document.Number.parse) reads a number token, and [`parse_print`](#Esm.Document.Number.parse_print) is the
round trip: parsing the printed spelling, followed by anything that does not continue a
number token, gives back the number and the rest.

[`parse`](#Esm.Document.Number.parse) reads any decimal spelling of a number, not only the canonical one, and
returns it in canonical form: `1.0` and `1.0e0` are the integer `1`, `0.0e10` is the
integer `0`, `2.50` is `2.5` (§5.5.3.1 rules 1 and 3). It rejects what has no
canonical form or is not a JSON number: an integer outside `Int64` (§5.5.3.1 rule 1),
and a leading zero (`007`, `01.5`). [`parse_wf`](#Esm.Document.Number.parse_wf): whatever [`parse`](#Esm.Document.Number.parse) returns is well
formed.

## Digits

<div class="lean-decl" id="Esm.Document.Number.charDigit">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Number.charDigit" title="Esm.Document.Number.charDigit"><code>charDigit</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Number.lean#L32">source</a></div>

```lean
def charDigit (c : Char) : Nat
```

The digit a digit character stands for.

</div>

<div class="lean-decl" id="Esm.Document.Number.natDigits">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Number.natDigits" title="Esm.Document.Number.natDigits"><code>natDigits</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Number.lean#L45">source</a></div>

```lean
def natDigits (n : Nat) : List Nat
```

The big-endian decimal digits of `n` (`[0]` for zero).

</div>

<div class="lean-decl" id="Esm.Document.Number.leadZero">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Number.leadZero" title="Esm.Document.Number.leadZero"><code>leadZero</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Number.lean#L56">source</a></div>

```lean
def leadZero (ip : List Nat) : Bool
```

More than one digit, the first of them `0`: a leading zero, which JSON forbids.

</div>

<div class="lean-decl" id="Esm.Document.Number.printNat">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Number.printNat" title="Esm.Document.Number.printNat"><code>printNat</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Number.lean#L67">source</a></div>

```lean
def printNat (n : Nat) : List Char
```

The spelling of a natural number.

</div>

<div class="lean-decl" id="Esm.Document.Number.printInt">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Number.printInt" title="Esm.Document.Number.printInt"><code>printInt</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Number.lean#L70-L71">source</a></div>

```lean
def printInt (z : Int) : List Char
```

The spelling of an integer.

</div>

<div class="lean-decl" id="Esm.Document.Number.readDigits">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Number.readDigits" title="Esm.Document.Number.readDigits"><code>readDigits</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Number.lean#L74-L80">source</a></div>

```lean
def readDigits : List Char → List Nat × List Char
```

The maximal run of digit characters at the front, as digits.

</div>

<div class="lean-decl" id="Esm.Document.Number.NoDigit">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Number.NoDigit" title="Esm.Document.Number.NoDigit"><code>NoDigit</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Number.lean#L83">source</a></div>

```lean
def NoDigit (rest : List Char) : Prop
```

`rest` does not start with a digit.

</div>

<div class="lean-decl" id="Esm.Document.Number.parseNat">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Number.parseNat" title="Esm.Document.Number.parseNat"><code>parseNat</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Number.lean#L100-L102">source</a></div>

```lean
def parseNat (input : List Char) : Option (Nat × List Char)
```

A natural number token.

</div>

<div class="lean-decl" id="Esm.Document.Number.parseInt">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Number.parseInt" title="Esm.Document.Number.parseInt"><code>parseInt</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Number.lean#L105-L108">source</a></div>

```lean
def parseInt (input : List Char) : Option (Int × List Char)
```

An integer token: an optional `-`, then digits.

</div>

## Decimals

<div class="lean-decl" id="Esm.Document.Number.fracDigits">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Number.fracDigits" title="Esm.Document.Number.fracDigits"><code>fracDigits</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Number.lean#L142">source</a></div>

```lean
def fracDigits (fp : List Nat) : List Nat
```

The fraction digits printed after the point: at least one.

</div>

<div class="lean-decl" id="Esm.Document.Number.decBody">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Number.decBody" title="Esm.Document.Number.decBody"><code>decBody</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Number.lean#L145-L154">source</a></div>

```lean
def decBody (ds : List Nat) (e10 : Int) : List Char
```

The unsigned spelling of the decimal `d₁.d₂… × 10^e10`.

</div>

<div class="lean-decl" id="Esm.Document.Number.print">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Number.print" title="Esm.Document.Number.print"><code>print</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Number.lean#L157-L159">source</a></div>

```lean
def print : JNum → List Char
```

The canonical spelling of a number (CONFORMANCE §5.5.3.1).

</div>

<div class="lean-decl" id="Esm.Document.Number.mkDec">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Number.mkDec" title="Esm.Document.Number.mkDec"><code>mkDec</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Number.lean#L163-L166">source</a></div>

```lean
def mkDec (neg : Bool) (ds : List Nat) (e10 : Int) : JNum
```

The decimal with digits `ds` (any leading or trailing zeros dropped) whose first
listed digit sits at decimal exponent `e10`.

</div>

<div class="lean-decl" id="Esm.Document.Number.finishDec">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Number.finishDec" title="Esm.Document.Number.finishDec"><code>finishDec</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Number.lean#L169-L173">source</a></div>

```lean
def finishDec (neg : Bool) (ds : List Nat) (e10 : Int) (r : List Char) :
    Option (JNum × List Char)
```

After the fraction digits of a decimal: an optional `e` exponent.

</div>

<div class="lean-decl" id="Esm.Document.Number.afterInt">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Number.afterInt" title="Esm.Document.Number.afterInt"><code>afterInt</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Number.lean#L186-L191">source</a></div>

```lean
def afterInt (neg : Bool) (ip : List Nat) (r : List Char) : Option (JNum × List Char)
```

After the integer digits `ip`: a `.` and fraction digits make a decimal, anything
else ends an integer.

</div>

<div class="lean-decl" id="Esm.Document.Number.parseRaw">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Number.parseRaw" title="Esm.Document.Number.parseRaw"><code>parseRaw</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Number.lean#L196-L201">source</a></div>

```lean
def parseRaw (input : List Char) : Option (JNum × List Char)
```

A number token as written: `-`?, digits with no leading zero, then either nothing
(an integer) or `.`, digits, and an optional `e` exponent (a decimal). Not yet in
canonical form (see [`parse`](#Esm.Document.Number.parse)).

</div>

<div class="lean-decl" id="Esm.Document.Number.canonize">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Number.canonize" title="Esm.Document.Number.canonize"><code>canonize</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Number.lean#L206-L212">source</a></div>

```lean
def canonize : JNum → JNum
```

The canonical form of a number read as written: a decimal whose digits are all
zero is the integer `0`, and an integral decimal in `Int64` is that integer
(§5.5.3.1 rules 1 and 3).

</div>

<div class="lean-decl" id="Esm.Document.Number.parse">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Number.parse" title="Esm.Document.Number.parse"><code>parse</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Number.lean#L216-L219">source</a></div>

```lean
def parse (input : List Char) : Option (JNum × List Char)
```

A number token, in canonical form; `none` for one that has none (an integer
outside `Int64`).

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Number.parse_wf">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Number.parse_wf" title="Esm.Document.Number.parse_wf"><code>parse_wf</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Number.lean#L222-L229">source</a></div>

```lean
theorem parse_wf {input rest : List Char} {n : JNum} (h : parse input = some (n, rest)) :
    n.WF
```

**What [`parse`](#Esm.Document.Number.parse) reads is well formed.**

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Number.canonize_wf">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Number.canonize_wf" title="Esm.Document.Number.canonize_wf"><code>canonize_wf</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Number.lean#L232-L241">source</a></div>

```lean
theorem canonize_wf (n : JNum) (hn : n.WF) : canonize n = n
```

A well-formed number is already canonical.

</div>

<div class="lean-decl" id="Esm.Document.Number.NumStop">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Number.NumStop" title="Esm.Document.Number.NumStop"><code>NumStop</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Number.lean#L255-L256">source</a></div>

```lean
def NumStop (rest : List Char) : Prop
```

What may follow a number token: anything that does not start with a digit, `.` or
`e`.

</div>

### [`mkDec`](#Esm.Document.Number.mkDec) undoes the padding the printer adds

### The round trip

<div class="lean-decl lean-theorem" id="Esm.Document.Number.parse_digits">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Number.parse_digits" title="Esm.Document.Number.parse_digits"><code>parse_digits</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Number.lean#L305-L322">source</a></div>

```lean
theorem parse_digits (neg : Bool) (ip : List Nat) (rest : List Char)
    (hip : ip ≠ []) (hi : ∀ d ∈ ip, d < 10) (hl : leadZero ip = false) (hr : NoDigit rest) :
    parseRaw ((if neg then ['-'] else []) ++ (ip.map digitChar ++ rest)) = afterInt neg ip rest
```

Parsing `-`? digits, followed by `rest`.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Number.parse_shape">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Number.parse_shape" title="Esm.Document.Number.parse_shape"><code>parse_shape</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Number.lean#L325-L331">source</a></div>

```lean
theorem parse_shape (neg : Bool) (ip fp : List Nat) (rest : List Char)
    (hip : ip ≠ []) (hfp : fp ≠ []) (hi : ∀ d ∈ ip, d < 10) (hf : ∀ d ∈ fp, d < 10)
    (hl : leadZero ip = false) (hr : NoDigit rest) :
    parseRaw ((if neg then ['-'] else []) ++ (ip.map digitChar ++ '.' :: (fp.map digitChar ++ rest))) =
      finishDec neg (ip ++ fp) (ip.length - 1) rest
```

Parsing `-`? digits `.` digits, followed by `rest`.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Number.parse_dec">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Number.parse_dec" title="Esm.Document.Number.parse_dec"><code>parse_dec</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Number.lean#L334-L340">source</a></div>

```lean
theorem parse_dec (neg : Bool) (ip fp : List Nat) (rest : List Char) (n : JNum)
    (hip : ip ≠ []) (hfp : fp ≠ []) (hi : ∀ d ∈ ip, d < 10) (hf : ∀ d ∈ fp, d < 10)
    (hl : leadZero ip = false) (hr : NumStop rest) (hm : mkDec neg (ip ++ fp) (ip.length - 1) = n) :
    parseRaw ((if neg then ['-'] else []) ++ (ip.map digitChar ++ '.' :: (fp.map digitChar ++ rest))) =
      some (n, rest)
```

A decimal spelling whose digits normalize to `n`, followed by a number stop.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Number.parse_print">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Number.parse_print" title="Esm.Document.Number.parse_print"><code>parse_print</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Number.lean#L456-L459">source</a></div>

```lean
theorem parse_print (n : JNum) (rest : List Char) (hn : n.WF) (hr : NumStop rest) :
    parse (print n ++ rest) = some (n, rest)
```

**The number round trip.**

</div>

## Canonical form of what [`parse`](#Esm.Document.Number.parse) reads

<div class="lean-decl" id="Esm.Document.Number.NumHead">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Number.NumHead" title="Esm.Document.Number.NumHead"><code>NumHead</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Number.lean#L477">source</a></div>

```lean
def NumHead (c : Char) : Prop
```

The first character of a printed number: `-` or a digit.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Number.NumHead.of_fin">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Number.NumHead.of_fin" title="Esm.Document.Number.NumHead.of_fin"><code>NumHead.of_fin</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Number.lean#L481-L485">source</a></div>

```lean
theorem NumHead.of_fin {P : Char → Prop} (h1 : P '-') (h2 : ∀ d : Fin 10, P (digitChar d.val))
    {c : Char} (hc : NumHead c) : P c
```

A fact about every possible first character of a number, checked character by
character.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Number.print_head">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Number.print_head" title="Esm.Document.Number.print_head"><code>print_head</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Number.lean#L488-L515">source</a></div>

```lean
theorem print_head (n : JNum) (hn : n.WF) : ∃ c t, print n = c :: t ∧ NumHead c
```

A printed number starts with `-` or a digit.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Number.print_neg_head">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Number.print_neg_head" title="Esm.Document.Number.print_neg_head"><code>print_neg_head</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Number.lean#L534-L558">source</a></div>

```lean
theorem print_neg_head (n : JNum) (hn : n.WF) (t : List Char) (h : print n = '-' :: t) :
    ∃ d t', d < 10 ∧ t = digitChar d :: t'
```

After a leading `-`, a printed number continues with a digit.

</div>

## The CONFORMANCE §5.5.3.1 probe table

<div class="lean-decl" id="Esm.Document.Number.L571">
<div class="lean-decl-head"><span class="lean-kind">example</span> <a class="lean-name" href="#Esm.Document.Number.L571">¶</a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Number.lean#L571">source</a></div>

```lean
example : print (.int 0) = "0".toList
```

`0.0` is the integer `0` (rule 1).

</div>

<p class="lean-meta">This module also proves 21 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Number.lean">the source</a>.</p>
