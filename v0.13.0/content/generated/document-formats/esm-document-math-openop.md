---
title: "Round trip, case by case: open operators"
type: lean
lean_module: "Esm.Document.Math.OpenOp"
weight: 41
---

<p class="lean-meta">Lean module <code>Esm.Document.Math.OpenOp</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/OpenOp.lean"><code>formal/Esm/Document/Math/OpenOp.lean</code></a> at <code>5af01ca9d41a</code><br>Imports <a href="/generated/document-formats/esm-document-math-escape"><code>Esm.Document.Math.Escape</code></a></p>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.jsonVal_head">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.jsonVal_head" title="Esm.Document.Math.jsonVal_head"><code>jsonVal_head</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/OpenOp.lean#L12-L24">source</a></div>

```lean
theorem jsonVal_head (sf : Sf) (v : Json) (hv : jwf v = true) (hn : isE v = false) :
    ∃ t r, jsonVal sf v = t :: r ∧
      (sf = .latex → ∀ X, jsonStart (t :: X) = true) ∧ (sf = .typst → t = .code v ∧ r = [])
```

A field value as JSON tokens starts with a token the parser takes for JSON.

</div>

<div class="lean-decl" id="Esm.Document.Math.valToks">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.valToks" title="Esm.Document.Math.valToks"><code>valToks</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/OpenOp.lean#L28-L29">source</a></div>

```lean
def valToks (c : Ctx) (v : Json) : List Tok
```

A field value as printed: an expression at level 4, or JSON.

</div>

<div class="lean-decl" id="Esm.Document.Math.fieldToks">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.fieldToks" title="Esm.Document.Math.fieldToks"><code>fieldToks</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/OpenOp.lean#L32-L33">source</a></div>

```lean
def fieldToks (c : Ctx) (kv : String × Json) : List Tok
```

A field as printed: key, `=`, value.

</div>

<p class="lean-meta">This module also proves 11 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/OpenOp.lean">the source</a>.</p>
