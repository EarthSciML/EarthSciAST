---
title: "Round trip, case by case: block assembly (makearray) and a bare template"
type: lean
lean_module: "Esm.Document.Math.Makearray"
weight: 40
---

<p class="lean-meta">Lean module <code>Esm.Document.Math.Makearray</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/Makearray.lean"><code>formal/Esm/Document/Math/Makearray.lean</code></a> at <code>9c3b4aa7587e</code><br>Imports <a href="/generated/document-formats/esm-document-math-faq"><code>Esm.Document.Math.Faq</code></a></p>

A native `makearray` is a bracketed two-column table, one row per region (the value,
then the region as bound pairs joined by `\times`), with its output indices as the
bracket's subscript. A template applied with no bindings, unless the symbol table knows
it with no parameters, is its bare name, `\operatorname{n}`.

## A bare template

## Block assembly

<div class="lean-decl" id="Esm.Document.Math.GoodX">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.GoodX" title="Esm.Document.Math.GoodX"><code>GoodX</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/Makearray.lean#L53">source</a></div>

```lean
def GoodX (c : Ctx) (P : Json → Out) (x : Json) : Prop
```

What the round trip of a native `makearray` knows of a sub-expression.

</div>

<div class="lean-decl" id="Esm.Document.Math.rowsToksM">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.rowsToksM" title="Esm.Document.Math.rowsToksM"><code>rowsToksM</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/Makearray.lean#L98-L99">source</a></div>

```lean
def rowsToksM (c : Ctx) (P : Json → Out) (rows : List (Json × List (Json × Json))) : List Tok
```

The rows of a table, as printed.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.M_mk">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.M_mk" title="Esm.Document.Math.M_mk"><code>M_mk</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/Makearray.lean#L227-L283">source</a></div>

```lean
theorem M_mk (c : Ctx) (kvs : List (String × Json)) (A : MkForm) (hA : mkForm kvs = some A)
    (hok : mkOK A = true) (P : Json → Out) (hP : ∀ x ∈ mkSubs A, P x = pr c x)
    (hpr : pr c (.obj kvs) = mkOutT c P A) (hM : ∀ x ∈ mkSubs A, M c x) : M c (.obj kvs)
```

A native `makearray` reads back.

</div>

<p class="lean-meta">This module also proves 12 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/Makearray.lean">the source</a>.</p>
