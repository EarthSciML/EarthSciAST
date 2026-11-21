---
title: "The canonical unit spelling"
type: lean
lean_module: "Esm.Units.Canonical"
weight: 66
---

<p class="lean-meta">Lean module <code>Esm.Units.Canonical</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Canonical.lean"><code>formal/Esm/Units/Canonical.lean</code></a> at <code>ffd5aee2f868</code><br>Imports <a href="/generated/document-formats/esm-units-factors"><code>Esm.Units.Factors</code></a>, <a href="/generated/document-formats/esm-units-strings"><code>Esm.Units.Strings</code></a>, <code>Esm.Digits</code></p>

The canonical form of a document rewrites every `units` string to ONE spelling
built from its parsed unit (esm-spec §4.8.2), so `m*h/(mi*s)`, `m h/(mi s)` and
`m·h/(mi·s)` canonicalize alike. It is a syntactic normalization of the parsed
tree, not a reduction to SI: symbols are kept (`ppm` stays `ppm`, `km` stays `km`).

From the two-sided normal form ([`norm2`](/generated/document-formats/esm-units-factors#Esm.Units.norm2), [`Esm.Units.Factors`](/generated/document-formats/esm-units-factors)): the numerator is
the factors whose net exponent is positive, each symbol once with its exponents
summed, in symbol order, joined by `*`; the denominator is the factors whose net
exponent is negative, normalized the same way, written with the exponent's
absolute value. A symbol is NEVER cancelled across the fraction bar (ruling of
2026-11-12): `mol/mol` stays `mol/mol`, `mol/mol/s` is `mol/(mol*s)`, and
`m m^-1` is `m/m`.
An exponent 1 is omitted, an integer exponent is `^n`, a non-integer rational is
`^(p/q)` in lowest terms. The spelling is [`num`](/generated/document-formats/esm-units-identities#Esm.Units.num), `num/den` when the denominator
has one factor, or `num/(den1*den2*…)`; an empty numerator is `1`, so the
dimensionless unit is `1`.

Choices beyond the grammar:

* `""`, `"1"` and `"dimensionless"` are the three §4.8.1 spellings of one
  dimensionless entry, so all three canonicalize to `"1"`, and a `dimensionless`
  factor inside a product is dropped like the atom `1` ([`UExpr.factors`](/generated/document-formats/esm-units-factors#Esm.Units.UExpr.factors)).
* A string that does not lex or parse is left unchanged ([`canon`](#Esm.Units.canon) is total and is
  the identity there). So is a string that parses but contains a symbol run with
  a `.` in it (`1.5m`: the lexer reads `digits.run` with a non-digit in the second
  run as one symbol); no table key contains `.`, so such a string never resolves.
* Because nothing cancels, a symbol of the parse is dropped from the spelling
  only when its exponent is 0 (`m^0`). A dropped symbol must still name a table
  unit ([`keepsSyms`](#Esm.Units.keepsSyms)); otherwise the string is left unchanged, so it keeps failing
  to resolve. Canonicalization never turns a resolving string into a
  non-resolving one ([`resolve_canon`](#Esm.Units.resolve_canon)), nor the reverse ([`resolve_of_canon`](#Esm.Units.resolve_of_canon)).

Theorems: [`canon_idem`](#Esm.Units.canon_idem) (idempotent), [`parse_canon`](#Esm.Units.parse_canon) (the spelling parses back to a
tree with the same two-sided normal form), [`resolve_canon`](#Esm.Units.resolve_canon) (and so the same unit),
[`resolve_of_canon`](#Esm.Units.resolve_of_canon) (a string whose spelling resolves resolves itself),
[`canon_eq_of_factors`](#Esm.Units.canon_eq_of_factors) (strings with the same two-sided normal form spell alike), and
[`parse_spell`](#Esm.Units.parse_spell) (every two-sided normal list with admissible symbols is spelled so that
it parses back to itself).

## Admissible symbols and digits

<div class="lean-decl" id="Esm.Units.symRunB">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.symRunB" title="Esm.Units.symRunB"><code>symRunB</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Canonical.lean#L53-L54">source</a></div>

```lean
def symRunB (s : String) : Bool
```

A run of identifier characters that is not all digits: one symbol token.

</div>

<div class="lean-decl" id="Esm.Units.symOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.symOK" title="Esm.Units.symOK"><code>symOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Canonical.lean#L59">source</a></div>

```lean
def symOK (s : String) : Bool
```

A symbol the canonical spelling can write: `%`, or a run of identifier
characters that is not all digits (so the lexer reads it back as one symbol),
and not `dimensionless` (a spelling of `1`).

</div>

<div class="lean-decl" id="Esm.Units.CanonFactors">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.CanonFactors" title="Esm.Units.CanonFactors"><code>CanonFactors</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Canonical.lean#L62">source</a></div>

```lean
def CanonFactors (l : List Factor) : Prop
```

A canonical factor list: two-sided normal, every symbol admissible.

</div>

<div class="lean-decl" id="Esm.Units.digs">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.digs" title="Esm.Units.digs"><code>digs</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Canonical.lean#L65">source</a></div>

```lean
def digs (n : ℕ) : List Char
```

The decimal digits of `n` (empty for `0`; only positive numbers are written).

</div>

## The spelling, as tokens

<div class="lean-decl" id="Esm.Units.numTok">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.numTok" title="Esm.Units.numTok"><code>numTok</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Canonical.lean#L99">source</a></div>

```lean
def numTok (n : ℕ) : Tok
```

The number token the lexer produces for the digits of `n`.

</div>

<div class="lean-decl" id="Esm.Units.expToks">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.expToks" title="Esm.Units.expToks"><code>expToks</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Canonical.lean#L102-L105">source</a></div>

```lean
def expToks (q : ℚ) : List Tok
```

The exponent tokens for a positive exponent `q`.

</div>

<div class="lean-decl" id="Esm.Units.fToks">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.fToks" title="Esm.Units.fToks"><code>fToks</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Canonical.lean#L108">source</a></div>

```lean
def fToks (f : Factor) : List Tok
```

One factor, written with the absolute value of its exponent.

</div>

<div class="lean-decl" id="Esm.Units.joinToks">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.joinToks" title="Esm.Units.joinToks"><code>joinToks</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Canonical.lean#L111-L113">source</a></div>

```lean
def joinToks : List Factor → List Tok
```

Factors joined by `*`.

</div>

<div class="lean-decl" id="Esm.Units.spellToks">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.spellToks" title="Esm.Units.spellToks"><code>spellToks</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Canonical.lean#L117-L122">source</a></div>

```lean
def spellToks (l : List Factor) : List Tok
```

The canonical spelling of a factor list, as tokens.

</div>

<div class="lean-decl" id="Esm.Units.spell">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.spell" title="Esm.Units.spell"><code>spell</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Canonical.lean#L138">source</a></div>

```lean
def spell (l : List Factor) : String
```

The canonical spelling of a factor list.

</div>

## The canonicalizer

<div class="lean-decl" id="Esm.Units.parseChars">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.parseChars" title="Esm.Units.parseChars"><code>parseChars</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Canonical.lean#L144-L145">source</a></div>

```lean
def parseChars (cs : List Char) : Except Err UExpr
```

Parse a unit string's characters to a tree. The empty string is the
dimensionless unit `1` (§4.8.1: `""` is a spelling of it).

</div>

<div class="lean-decl" id="Esm.Units.keepsSyms">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.keepsSyms" title="Esm.Units.keepsSyms"><code>keepsSyms</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Canonical.lean#L151-L152">source</a></div>

```lean
def keepsSyms (e : UExpr) : Bool
```

Every symbol of the parse either survives into the two-sided normal form or
names a table unit. (A symbol is dropped only when its exponent is 0, as in
`m^0`; spelling a string without such a symbol would hide that it does not
resolve.)

</div>

<div class="lean-decl" id="Esm.Units.canon">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.canon" title="Esm.Units.canon"><code>canon</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Canonical.lean#L157-L162">source</a></div>

```lean
def canon (s : String) : String
```

The canonical spelling of a unit string; the identity on a string that does
not parse, whose factors include a symbol the spelling cannot write, or that
drops a symbol naming no unit ([`keepsSyms`](#Esm.Units.keepsSyms)).

</div>

## Lexing the spelling

<div class="lean-decl" id="Esm.Units.OpHead">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.OpHead" title="Esm.Units.OpHead"><code>OpHead</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Canonical.lean#L175">source</a></div>

```lean
def OpHead (rest : List Char) : Prop
```

What may follow an operand (a symbol run or a number): nothing, or a
character that neither extends the run nor makes it a decimal.

</div>

<div class="lean-decl" id="Esm.Units.AnyRest">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.AnyRest" title="Esm.Units.AnyRest"><code>AnyRest</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Canonical.lean#L178">source</a></div>

```lean
def AnyRest (_ : List Char) : Prop
```

No condition on what follows.

</div>

<div class="lean-decl" id="Esm.Units.NoStarHead">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.NoStarHead" title="Esm.Units.NoStarHead"><code>NoStarHead</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Canonical.lean#L181">source</a></div>

```lean
def NoStarHead (rest : List Char) : Prop
```

What may follow `*`: anything but a second `*`.

</div>

<div class="lean-decl" id="Esm.Units.LexP">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.LexP" title="Esm.Units.LexP"><code>LexP</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Canonical.lean#L184-L187">source</a></div>

```lean
def LexP (toks : List Tok) (P : List Char → Prop) : Prop
```

`toks` lexes from its rendering, whatever follows that satisfies `P`.

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.lexP_op">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.lexP_op" title="Esm.Units.lexP_op"><code>lexP_op</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Canonical.lean#L227-L234">source</a></div>

```lean
theorem lexP_op (t : Tok) (c : Char) (hr : renderTok t = [c])
    (h : ∀ k cs, lexAux (k + 1) (c :: cs) = (t :: ·) <$> lexAux k cs) (P : List Char → Prop)
    (ha : c.toNat < 128) : LexP [t] P
```

A single-character operator other than `*`.

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.symOK_head">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.symOK_head" title="Esm.Units.symOK_head"><code>symOK_head</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Canonical.lean#L330-L340">source</a></div>

```lean
theorem symOK_head (s : String) (h : symOK s = true) : ∀ r, s.toList ≠ '*' :: r
```

The first character of an admissible symbol is not `*`.

</div>

<div class="lean-decl" id="Esm.Units.numToks">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.numToks" title="Esm.Units.numToks"><code>numToks</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Canonical.lean#L416-L417">source</a></div>

```lean
def numToks (l : List Factor) : List Tok
```

The numerator tokens.

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.lex_spell">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.lex_spell" title="Esm.Units.lex_spell"><code>lex_spell</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Canonical.lean#L466-L477">source</a></div>

```lean
theorem lex_spell (l : List Factor) (hl : CanonFactors l) :
    lex (normalize (renderToks (spellToks l))) = .ok (spellToks l)
```

The spelling's characters lex to the spelling's tokens.

</div>

## The parse of the spelling

<div class="lean-decl" id="Esm.Units.term">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.term" title="Esm.Units.term"><code>term</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Canonical.lean#L483">source</a></div>

```lean
def term (f : Factor) : UExpr
```

The tree one factor parses to: its symbol, raised to the exponent's absolute
value unless that is 1.

</div>

<div class="lean-decl" id="Esm.Units.foldTerms">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.foldTerms" title="Esm.Units.foldTerms"><code>foldTerms</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Canonical.lean#L486">source</a></div>

```lean
def foldTerms (acc : UExpr) (fs : List Factor) : UExpr
```

`acc * t₁ * t₂ * …`, folded left.

</div>

<div class="lean-decl" id="Esm.Units.numTree">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.numTree" title="Esm.Units.numTree"><code>numTree</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Canonical.lean#L552-L555">source</a></div>

```lean
def numTree (l : List Factor) : UExpr
```

The numerator's tree.

</div>

<div class="lean-decl" id="Esm.Units.spellTree">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.spellTree" title="Esm.Units.spellTree"><code>spellTree</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Canonical.lean#L558-L561">source</a></div>

```lean
def spellTree (l : List Factor) : UExpr
```

The tree the spelling parses to.

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.parse_spellToks">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.parse_spellToks" title="Esm.Units.parse_spellToks"><code>parse_spellToks</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Canonical.lean#L612-L659">source</a></div>

```lean
theorem parse_spellToks (l : List Factor) (hl : ∀ f ∈ l, f.2 ≠ 0) :
    parse (spellToks l) = .ok (spellTree l)
```

The spelling's tokens parse to [`spellTree`](#Esm.Units.spellTree).

</div>

## The spelling's factors

<div class="lean-decl" id="Esm.Units.absF">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.absF" title="Esm.Units.absF"><code>absF</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Canonical.lean#L667">source</a></div>

```lean
def absF (f : Factor) : Factor
```

A factor with its exponent's absolute value.

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.parse_spell">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.parse_spell" title="Esm.Units.parse_spell"><code>parse_spell</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Canonical.lean#L729-L743">source</a></div>

```lean
theorem parse_spell :
    ∀ l : List Factor, CanonFactors l →
      ∃ e, parseChars (spell l).toList = .ok e ∧ e.factors = l ∧ norm2 e.factors = l
```

**The spelling parses back.** Every canonical factor list is spelled so that
it parses (§4.8.2) to a tree whose factor list is a permutation of it, and whose
normalized factor list is it exactly.

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.canon_cases">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.canon_cases" title="Esm.Units.canon_cases"><code>canon_cases</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Canonical.lean#L751-L762">source</a></div>

```lean
theorem canon_cases (s : String) :
    canon s = s ∨ ∃ e, parseChars s.toList = .ok e ∧ CanonFactors (norm2 e.factors) ∧
      keepsSyms e = true ∧ canon s = spell (norm2 e.factors)
```

[`canon`](#Esm.Units.canon) either leaves a string alone or spells a canonical factor list —
the normalized factor list of the string's parse.

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.keepsSyms_of_normal">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.keepsSyms_of_normal" title="Esm.Units.keepsSyms_of_normal"><code>keepsSyms_of_normal</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Canonical.lean#L765-L771">source</a></div>

```lean
theorem keepsSyms_of_normal (e : UExpr) (h : norm2 e.factors = e.factors) :
    keepsSyms e = true
```

A tree whose factors are exactly its normal form keeps its symbols.

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.canon_spell">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.canon_spell" title="Esm.Units.canon_spell"><code>canon_spell</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Canonical.lean#L774-L781">source</a></div>

```lean
theorem canon_spell (l : List Factor) (hl : CanonFactors l) : canon (spell l) = spell l
```

The canonical spelling of a canonical factor list is a fixed point.

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.canon_idem">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.canon_idem" title="Esm.Units.canon_idem"><code>canon_idem</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Canonical.lean#L784-L788">source</a></div>

```lean
theorem canon_idem : ∀ s : String, canon (canon s) = canon s
```

**Idempotence.** Canonicalizing a canonical spelling returns it unchanged.

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.parse_canon">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.parse_canon" title="Esm.Units.parse_canon"><code>parse_canon</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Canonical.lean#L792-L800">source</a></div>

```lean
theorem parse_canon :
    ∀ (s : String) (e : UExpr), parseChars s.toList = .ok e →
      ∃ e', parseChars (canon s).toList = .ok e' ∧ norm2 e'.factors = norm2 e.factors
```

**The canonical spelling keeps the factors.** If a unit string parses, its
canonical spelling parses too, to a tree with the same normalized factor list.

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.canon_eq_of_factors">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.canon_eq_of_factors" title="Esm.Units.canon_eq_of_factors"><code>canon_eq_of_factors</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Canonical.lean#L806-L814">source</a></div>

```lean
theorem canon_eq_of_factors :
    ∀ (s t : String) (e e' : UExpr), parseChars s.toList = .ok e → parseChars t.toList = .ok e' →
      norm2 e.factors = norm2 e'.factors → (norm2 e.factors).all (fun f => symOK f.1) = true →
      keepsSyms e = true → keepsSyms e' = true → canon s = canon t
```

Two strings whose parses have the same normalized factor list, all of whose
symbols the spelling can write, and neither of which drops a symbol naming no unit,
have the same canonical spelling. (Strings that resolve never drop such a symbol:
[`keepsSyms_of_eval`](#Esm.Units.keepsSyms_of_eval).)

</div>

## The canonical spelling denotes the same unit

<div class="lean-decl" id="Esm.Units.vsym">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.vsym" title="Esm.Units.vsym"><code>vsym</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Canonical.lean#L819">source</a></div>

```lean
def vsym (s : String) : Dim × (Base → ℚ)
```

What a symbol denotes, as a vector (dimension, scale exponents).

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.eval_factors">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.eval_factors" title="Esm.Units.eval_factors"><code>eval_factors</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Canonical.lean#L848-L909">source</a></div>

```lean
theorem eval_factors :
    ∀ (e : UExpr) (u : U), e.eval = .ok u →
      (∀ f ∈ e.factors, f.1 ∈ keys) ∧ u.val = wsum vsym e.factors
```

A tree that evaluates names only table keys, and its unit is the weighted sum
of its factors.

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.eval_of_keys">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.eval_of_keys" title="Esm.Units.eval_of_keys"><code>eval_of_keys</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Canonical.lean#L912-L943">source</a></div>

```lean
theorem eval_of_keys :
    ∀ e : UExpr, (∀ f ∈ e.factors, f.1 ∈ keys) →
      ∃ u, e.eval = .ok u ∧ u.val = wsum vsym e.factors
```

A tree whose factors are all table keys evaluates, to the weighted sum.

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.resolve_canon">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.resolve_canon" title="Esm.Units.resolve_canon"><code>resolve_canon</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Canonical.lean#L962-L998">source</a></div>

```lean
theorem resolve_canon :
    ∀ (s : String) (u : U), resolve s = .ok u → ∃ u', resolve (canon s) = .ok u' ∧ u'.Agree u
```

**The canonical spelling denotes the same unit.** If a unit string resolves
(§4.8.1, §4.8.2), its canonical spelling resolves to a unit that agrees with it:
same dimension, same exact scale.

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.keepsSyms_of_eval">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.keepsSyms_of_eval" title="Esm.Units.keepsSyms_of_eval"><code>keepsSyms_of_eval</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Canonical.lean#L1001-L1006">source</a></div>

```lean
theorem keepsSyms_of_eval (e : UExpr) (u : U) (h : e.eval = .ok u) : keepsSyms e = true
```

A tree that evaluates drops no symbol naming no unit.

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.resolve_of_canon">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.resolve_of_canon" title="Esm.Units.resolve_of_canon"><code>resolve_of_canon</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Canonical.lean#L1011-L1037">source</a></div>

```lean
theorem resolve_of_canon :
    ∀ (s : String) (u' : U), resolve (canon s) = .ok u' → ∃ u, resolve s = .ok u ∧ u'.Agree u
```

**Canonicalization does not hide an unresolvable unit.** If the canonical
spelling of a string resolves, the string itself resolves, to a unit that agrees
with it.

</div>

<p class="lean-meta">This module also proves 61 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Canonical.lean">the source</a>.</p>
