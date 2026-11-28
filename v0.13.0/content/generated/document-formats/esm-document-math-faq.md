---
title: "Round trip, case by case: reductions (faq), rows"
type: lean
lean_module: "Esm.Document.Math.Faq"
weight: 33
---

<p class="lean-meta">Lean module <code>Esm.Document.Math.Faq</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Faq.lean"><code>formal/Esm/Document/Math/Faq.lean</code></a> at <code>5af01ca9d41a</code><br>Imports <a href="/generated/document-formats/esm-document-math-arrays"><code>Esm.Document.Math.Arrays</code></a></p>

<div class="lean-decl" id="Esm.Document.Math.EndTok">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.EndTok" title="Esm.Document.Math.EndTok"><code>EndTok</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Faq.lean#L12">source</a></div>

```lean
def EndTok (k : Kw) : Prop
```

The tokens a row or an entry may end at.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.pOr_cmp">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.pOr_cmp" title="Esm.Document.Math.pOr_cmp"><code>pOr_cmp</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Faq.lean#L43-L51">source</a></div>

```lean
theorem pOr_cmp (c : Ctx) (f : Nat) (ts r r' : List Tok) (x y : Json) (k : Kw) (o : String)
    (h1 : pAdd c (f + 1) ts = some (x, .kw k :: r)) (hk : cmpOf k = some o)
    (h2 : pAdd c f r = some (y, r')) (hl : ∀ r'', r' ≠ .kw .land :: r'') (ho : ∀ r'', r' ≠ .kw .lor :: r'') :
    pOr c (f + 4) ts = some (node o [x, y], r')
```

[`pOr`](/generated/document-formats/esm-document-math-parse#Esm.Document.Math.pOr) over a comparison whose right side is followed by something that does not
continue an `and` or `or` chain.

</div>

## Rows

<div class="lean-decl lean-theorem" id="Esm.Document.Math.pRow_range">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.pRow_range" title="Esm.Document.Math.pRow_range"><code>pRow_range</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Faq.lean#L122-L193">source</a></div>

```lean
theorem pRow_range (c : Ctx) (P : Json → Out) (k : String) (v : Json) (hk : nameOK k = true)
    (hv : rangeOK v = true) (hM : ∀ a b, v = .arr [a, b] → M c a ∧ M c b ∧ P a = pr c a ∧ P b = pr c b)
    (isEnd : Tok → Bool) (hle : isEnd (.kw .le) = false) (hin : isEnd (.kw .inn) = false)
    (E : Kw) (hE : EndTok E) (R : List Tok) (f : Nat)
    (hf : 30 * (rowToks c P (k, v)).length + 11 ≤ f) :
    pRow c (f + 1) isEnd (rowToks c P (k, v) ++ .kw E :: R) = some (.rng k v, .kw E :: R)
```

A printed range row reads back as that range.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.pRows_read">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.pRows_read" title="Esm.Document.Math.pRows_read"><code>pRows_read</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Faq.lean#L196-L217">source</a></div>

```lean
theorem pRows_read (c : Ctx) (sep close : Kw) (hsc : sep ≠ close) (R : List Tok) :
    ∀ (rs : List (Row × List Tok)), rs ≠ [] →
      (∀ p ∈ rs, ∀ E, (E = sep ∨ E = close) → ∀ R' f, 30 * p.2.length + 11 ≤ f →
        pRow c (f + 1) (fun t => isKw sep t || isKw close t) (p.2 ++ .kw E :: R') = some (p.1, .kw E :: R')) →
      ∀ f, 30 * (sepBy [.kw sep] (rs.map Prod.snd)).length + 12 ≤ f →
      pRows c (f + 1) sep close (sepBy [.kw sep] (rs.map Prod.snd) ++ .kw close :: R) = some (rs.map Prod.fst, R)
```

Rows separated by `sep` and closed by [`close`](/generated/document-formats/esm-document-math-parse#Esm.Document.Math.close) read back, each row as printed.

</div>

<div class="lean-decl" id="Esm.Document.Math.rowsL">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.rowsL" title="Esm.Document.Math.rowsL"><code>rowsL</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Faq.lean#L220-L234">source</a></div>

```lean
def rowsL (c : Ctx) (f : Nat) (ts : List Tok) : Option (List Row × List Tok)
```

The LaTeX subscript, as [`pRedBody`](/generated/document-formats/esm-document-math-parse#Esm.Document.Math.pRedBody) reads it.

</div>

<div class="lean-decl" id="Esm.Document.Math.rowsT">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.rowsT" title="Esm.Document.Math.rowsT"><code>rowsT</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Faq.lean#L237-L240">source</a></div>

```lean
def rowsT (c : Ctx) (f : Nat) (ts : List Tok) : Option (List Row × List Tok)
```

The Typst subscript, as [`pRedBody`](/generated/document-formats/esm-document-math-parse#Esm.Document.Math.pRedBody) reads it.

</div>

## The subscript

<div class="lean-decl" id="Esm.Document.Math.FaqH">
<div class="lean-decl-head"><span class="lean-kind">structure</span> <a class="lean-name" href="#Esm.Document.Math.FaqH" title="Esm.Document.Math.FaqH"><code>FaqH</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Faq.lean#L262-L267">source</a></div>

```lean
structure FaqH (c : Ctx) (F : FaqForm) (P : Json → Out) : Prop where
  hE : M c F.expr
  hPe : P F.expr = pr c F.expr
  hFl : ∀ x, F.filter = some x → M c x ∧ P x = pr c x
  hR : ∀ kv ∈ F.ranges, nameOK kv.1 = true ∧ rangeOK kv.2 = true ∧
    ∀ a b, kv.2 = .arr [a, b] → M c a ∧ M c b ∧ P a = pr c a ∧ P b = pr c b
```

What the round trip of a native `faq` knows of its parts.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.faqRows_head">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.faqRows_head" title="Esm.Document.Math.faqRows_head"><code>faqRows_head</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Faq.lean#L297-L324">source</a></div>

```lean
theorem faqRows_head {c : Ctx} {F : FaqForm} {P : Json → Out} (h : FaqH c F P) :
    ∀ p ∈ faqRows c P F, ∃ t r, p.2 = t :: r ∧ (startA t = true ∨ t = .kw .minus)
```

Every printed row starts as an expression does.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.faqRows_ok">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.faqRows_ok" title="Esm.Document.Math.faqRows_ok"><code>faqRows_ok</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Faq.lean#L327-L343">source</a></div>

```lean
theorem faqRows_ok {c : Ctx} {F : FaqForm} {P : Json → Out} (h : FaqH c F P) (isEnd : Tok → Bool)
    (hle : isEnd (.kw .le) = false) (hin : isEnd (.kw .inn) = false) :
    ∀ p ∈ faqRows c P F, ∀ E, EndTok E → isEnd (.kw E) = true → ∀ R f, 30 * p.2.length + 11 ≤ f →
      pRow c (f + 1) isEnd (p.2 ++ .kw E :: R) = some (p.1, .kw E :: R)
```

Every printed row reads back, before any end token the row reader accepts.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.pRedBody_readL">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.pRedBody_readL" title="Esm.Document.Math.pRedBody_readL"><code>pRedBody_readL</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Faq.lean#L390-L508">source</a></div>

```lean
theorem pRedBody_readL {c : Ctx} {F : FaqForm} {P : Json → Out} (h : FaqH c F P) (hsf : c.sf = .latex)
    (rest : List Tok) (hr : Fol c.sf 5 rest) (f : Nat)
    (hf : 30 * (subToksL c P F ++ (P F.expr).at c.sf 5).length + 20 ≤ f) :
    pRedBody c (f + 1) F.red F.marked (subToksL c P F ++ ((P F.expr).at c.sf 5 ++ rest)) =
      some (⟨F.red, F.marked, [], redRanges F, F.expr, F.filter⟩, rest)
```

The LaTeX subscript and body read back.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.pRedBody_readT">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.pRedBody_readT" title="Esm.Document.Math.pRedBody_readT"><code>pRedBody_readT</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Faq.lean#L511-L555">source</a></div>

```lean
theorem pRedBody_readT {c : Ctx} {F : FaqForm} {P : Json → Out} (h : FaqH c F P) (hsf : c.sf = .typst)
    (rest : List Tok) (hr : Fol c.sf 5 rest) (f : Nat)
    (hf : 30 * (subToksT c P F ++ (P F.expr).at c.sf 5).length + 20 ≤ f) :
    pRedBody c (f + 1) F.red F.marked (subToksT c P F ++ ((P F.expr).at c.sf 5 ++ rest)) =
      some (⟨F.red, F.marked, [], redRanges F, F.expr, F.filter⟩, rest)
```

The Typst subscript and body read back.

</div>

## Operator, entries, ranges

<div class="lean-decl" id="Esm.Document.Math.outRanges">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.outRanges" title="Esm.Document.Math.outRanges"><code>outRanges</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Faq.lean#L591-L594">source</a></div>

```lean
def outRanges (F : FaqForm) : List (String × Json)
```

The range of an output index, when it has one.

</div>

## The node

<div class="lean-decl lean-theorem" id="Esm.Document.Math.pRows_entries">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.pRows_entries" title="Esm.Document.Math.pRows_entries"><code>pRows_entries</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Faq.lean#L833-L848">source</a></div>

```lean
theorem pRows_entries {c : Ctx} {F : FaqForm} {P : Json → Out} (h : FaqH c F P)
    (hO : ∀ j ∈ F.out, outOK j = true) (hout : F.out ≠ []) (close : Kw) (hc : EndTok close)
    (hcc : close ≠ .comma) (R : List Tok) (f : Nat)
    (hf : 30 * (sepBy [.kw .comma] (F.out.map (entryToks c P F))).length + 12 ≤ f) :
    pRows c (f + 1) .comma close (sepBy [.kw .comma] (F.out.map (entryToks c P F)) ++ .kw close :: R) =
      some (F.out.map (entryRow F), R)
```

The output entries read back as rows.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.M_faq">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.M_faq" title="Esm.Document.Math.M_faq"><code>M_faq</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Faq.lean#L866-L942">source</a></div>

```lean
theorem M_faq (c : Ctx) (kvs : List (String × Json)) (F : FaqForm) (hF : faqForm kvs = some F)
    (hok : faqOK F = true) (P : Json → Out) (hP : ∀ x ∈ faqSubs F, P x = pr c x)
    (hpr : pr c (.obj kvs) = faqOut c P F) (hM : ∀ x ∈ faqSubs F, M c x) : M c (.obj kvs)
```

A native `faq` reads back.

</div>

<p class="lean-meta">This module also proves 49 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Faq.lean">the source</a>.</p>
