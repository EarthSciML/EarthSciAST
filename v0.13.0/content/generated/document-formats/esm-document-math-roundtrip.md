---
title: "The token-level round trip: generic pieces"
type: lean
lean_module: "Esm.Document.Math.RoundTrip"
weight: 42
---

<p class="lean-meta">Lean module <code>Esm.Document.Math.RoundTrip</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/RoundTrip.lean"><code>formal/Esm/Document/Math/RoundTrip.lean</code></a> at <code>5af01ca9d41a</code><br>Imports <a href="/generated/document-formats/esm-document-math-levels"><code>Esm.Document.Math.Levels</code></a></p>

`PL c e`: the printed tokens of `e` for any level read back to `e` at that level,
before anything that does not continue it, with enough fuel ([`need`](#Esm.Document.Math.need)). The main
theorem ([`Esm.Document.Math.Main`](/generated/document-formats/esm-document-math-main)) proves it for every well-formed expression by
strong induction; this file holds the steps that do not depend on the notation.

<div class="lean-decl" id="Esm.Document.Math.need">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.need" title="Esm.Document.Math.need"><code>need</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/RoundTrip.lean#L34">source</a></div>

```lean
def need (L len : Nat) : Nat
```

Fuel enough to read `len` tokens at level `L`.

</div>

<div class="lean-decl" id="Esm.Document.Math.PL">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.PL" title="Esm.Document.Math.PL"><code>PL</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/RoundTrip.lean#L37-L39">source</a></div>

```lean
def PL (c : Ctx) (e : Json) : Prop
```

`e`'s tokens for level `L` read back at level `L`.

</div>

<div class="lean-decl" id="Esm.Document.Math.P0">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.P0" title="Esm.Document.Math.P0"><code>P0</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/RoundTrip.lean#L42-L44">source</a></div>

```lean
def P0 (c : Ctx) (e : Json) : Prop
```

`e`'s tokens read back at its own level.

</div>

<div class="lean-decl" id="Esm.Document.Math.startA">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.startA" title="Esm.Document.Math.startA"><code>startA</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/RoundTrip.lean#L48">source</a></div>

```lean
def startA (t : Tok) : Bool
```

A token a printed expression can start with: one that starts an operand, but not a
call parenthesis or a bracket (those only follow something).

</div>

<div class="lean-decl" id="Esm.Document.Math.HeadOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.HeadOK" title="Esm.Document.Math.HeadOK"><code>HeadOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/RoundTrip.lean#L51-L55">source</a></div>

```lean
def HeadOK (c : Ctx) : List Tok → Prop
```

What a printed expression starts with, as far as the variant readings care.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.lift_step">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.lift_step" title="Esm.Document.Math.lift_step"><code>lift_step</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/RoundTrip.lean#L67-L80">source</a></div>

```lean
theorem lift_step {c : Ctx} {L f : Nat} {ts r : List Tok} {x : Json} (hL : 1 ≤ L) (hL' : L < 10)
    (h : pLvl c f (L + 1) ts = some (x, r)) (hr : Fol c.sf L r) :
    pLvl c (f + 1) L ts = some (x, r)
```

One level looser.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.lift">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.lift" title="Esm.Document.Math.lift"><code>lift</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/RoundTrip.lean#L83-L91">source</a></div>

```lean
theorem lift {c : Ctx} {ts r : List Tok} {x : Json} {N : Nat} :
    ∀ (d L : Nat), 1 ≤ L → L + d ≤ 10 → (∀ f, N ≤ f → pLvl c f (L + d) ts = some (x, r)) →
      Fol c.sf L r → ∀ f, N + d ≤ f → pLvl c f L ts = some (x, r)
```

Several levels looser.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.pPrim_grp">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.pPrim_grp" title="Esm.Document.Math.pPrim_grp"><code>pPrim_grp</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/RoundTrip.lean#L132-L163">source</a></div>

```lean
theorem pPrim_grp (c : Ctx) (e : Json) (toks : List Tok) (hh : HeadOK c toks)
    (h1 : ∀ rest, Fol c.sf 1 rest → ∀ f, need 1 toks.length ≤ f → pOr c f (toks ++ rest) = some (e, rest))
    (rest : List Tok) (f : Nat) (hf : need 1 toks.length + 1 ≤ f) :
    pPrim c f (grp c.sf toks ++ rest) = some (e, rest)
```

A primary read in parentheses.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.PL_of">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.PL_of" title="Esm.Document.Math.PL_of"><code>PL_of</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/RoundTrip.lean#L172-L196">source</a></div>

```lean
theorem PL_of (c : Ctx) (e : Json) (h0 : P0 c e) (hh : HeadOK c (pr c e).toks)
    (hl1 : 1 ≤ (pr c e).lvl) (hl : (pr c e).lvl ≤ 10) : PL c e
```

From the natural-level parse to every level.

</div>

<p class="lean-meta">This module also proves 19 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/RoundTrip.lean">the source</a>.</p>
