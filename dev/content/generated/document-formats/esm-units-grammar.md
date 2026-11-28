---
title: "The unit-string grammar (esm-spec §4.8.2)"
type: lean
lean_module: "Esm.Units.Grammar"
weight: 65
---

<p class="lean-meta">Lean module <code>Esm.Units.Grammar</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Units/Grammar.lean"><code>formal/Esm/Units/Grammar.lean</code></a> at <code>9c3b4aa7587e</code><br>Imports <a href="/generated/document-formats/esm-units-registry"><code>Esm.Units.Registry</code></a></p>

A unit string is resolved in four steps, each a function here:

1. `normalize` — the mandatory Unicode rewrite, applied BEFORE parsing.
2. `lex` — tokens. A symbol is a maximal run of identifier characters
   (`[A-Za-z0-9_]`); a run of digits alone (optionally `digits.digits`) is a
   number; `%` is a one-character symbol; whitespace separates tokens and is
   otherwise dropped.
3. [`parse`](#Esm.Units.parse) — the grammar, to a syntax tree `UExpr`:
   ```
   unit     := term (('*' | '/')? term)*
   term     := atom (('^' | '**') exponent)?
   exponent := integer | decimal | '(' integer '/' integer ')'
   atom     := '1' | symbol | '(' unit ')'
   ```
   `*`, `/` and juxtaposition are one precedence level, folded left to right.
   A numeric atom whose value is not 1 is a scaling factor and an error.
4. `UExpr.eval` — look each symbol up in the flat table and compose.

Readings chosen where §4.8.2 admits more than one are listed in the phase-1
report (the lexing of a run such as `s1`, a lone `%` inside a run, numeric atoms
spelled `1.0`, whitespace-only strings, whitespace inside a term).

## Errors

<div class="lean-decl" id="Esm.Units.scalingFactorText">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.scalingFactorText" title="Esm.Units.scalingFactorText"><code>scalingFactorText</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Units/Grammar.lean#L42">source</a></div>

```lean
def scalingFactorText : String
```

The two phrases §4.8.2 requires in the scaling-factor diagnostic.

</div>

## Unicode normalisation

<div class="lean-decl" id="Esm.Units.supDigit">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.supDigit" title="Esm.Units.supDigit"><code>supDigit</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Units/Grammar.lean#L58-L63">source</a></div>

```lean
def supDigit (c : Char) : Option Char
```

The ASCII digit of a superscript digit.

</div>

<div class="lean-decl" id="Esm.Units.supRun">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.supRun" title="Esm.Units.supRun"><code>supRun</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Units/Grammar.lean#L68-L70">source</a></div>

```lean
def supRun (cs : List Char) : List Char × List Char
```

The leading run of superscript digits, transliterated, and the rest.

</div>

<div class="lean-decl" id="Esm.Units.normalizeAux">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.normalizeAux" title="Esm.Units.normalizeAux"><code>normalizeAux</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Units/Grammar.lean#L73-L88">source</a></div>

```lean
def normalizeAux : Nat → List Char → List Char
```

The §4.8.2 rewrite table, applied left to right.

</div>

## Tokens

<div class="lean-decl" id="Esm.Units.isIdent">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.isIdent" title="Esm.Units.isIdent"><code>isIdent</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Units/Grammar.lean#L104">source</a></div>

```lean
def isIdent (c : Char) : Bool
```

Characters that may occur in a symbol run.

</div>

## Syntax trees and the parser

<div class="lean-decl" id="Esm.Units.pInt">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.pInt" title="Esm.Units.pInt"><code>pInt</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Units/Grammar.lean#L154-L157">source</a></div>

```lean
def pInt : List Tok → Option (ℚ × List Tok)
```

`'-'? integer`.

</div>

<div class="lean-decl" id="Esm.Units.pExp">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.pExp" title="Esm.Units.pExp"><code>pExp</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Units/Grammar.lean#L160-L172">source</a></div>

```lean
def pExp : List Tok → Except Err (ℚ × List Tok)
```

`exponent := integer | decimal | '(' integer '/' integer ')'` (signs allowed).

</div>

<div class="lean-decl" id="Esm.Units.startsTerm">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.startsTerm" title="Esm.Units.startsTerm"><code>startsTerm</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Units/Grammar.lean#L175-L177">source</a></div>

```lean
def startsTerm : List Tok → Bool
```

Does the token list begin a term (an atom)?

</div>

<div class="lean-decl" id="Esm.Units.pTail">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.pTail" title="Esm.Units.pTail"><code>pTail</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Units/Grammar.lean#L202-L219">source</a></div>

```lean
def pTail : Nat → UExpr → List Tok → Except Err (UExpr × List Tok)
```

The left fold `acc (op term)*`.

</div>

<div class="lean-decl" id="Esm.Units.parse">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.parse" title="Esm.Units.parse"><code>parse</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Units/Grammar.lean#L230-L236">source</a></div>

```lean
def parse (ts : List Tok) : Except Err UExpr
```

Parse a whole token list.

</div>

## Evaluation and resolution

<div class="lean-decl" id="Esm.Units.resolveChars">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.resolveChars" title="Esm.Units.resolveChars"><code>resolveChars</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Units/Grammar.lean#L252-L257">source</a></div>

```lean
def resolveChars (cs : List Char) : Except Err U
```

Resolve a unit string given as characters. The empty string is the
dimensionless key `""`.

</div>

<div class="lean-decl" id="Esm.Units.resolve">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.resolve" title="Esm.Units.resolve"><code>resolve</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Units/Grammar.lean#L260">source</a></div>

```lean
def resolve (s : String) : Except Err U
```

Resolve a unit string (§4.8.1 table + §4.8.2 grammar).

</div>

<div class="lean-decl" id="Esm.Units.Resolves">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.Resolves" title="Esm.Units.Resolves"><code>Resolves</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Units/Grammar.lean#L263">source</a></div>

```lean
def Resolves (s : String) : Prop
```

Does the string resolve?

</div>
