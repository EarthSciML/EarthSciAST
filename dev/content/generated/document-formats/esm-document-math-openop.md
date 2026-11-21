---
title: "Round trip, case by case: open operators"
type: lean
lean_module: "Esm.Document.Math.OpenOp"
weight: 42
---

<p class="lean-meta">Lean module <code>Esm.Document.Math.OpenOp</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Math/OpenOp.lean"><code>formal/Esm/Document/Math/OpenOp.lean</code></a> at <code>1b8dd9b3a909</code><br>Imports <a href="/generated/document-formats/esm-document-math-escape"><code>Esm.Document.Math.Escape</code></a></p>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.jsonVal_head">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.jsonVal_head" title="Esm.Document.Math.jsonVal_head"><code>jsonVal_head</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Math/OpenOp.lean#L12-L25">source</a></div>

```lean
theorem jsonVal_head (sf : Sf) (v : Json) (hv : jwf v = true) (hn : ∀ n, v ≠ .num n) :
    ∃ t r, jsonVal sf v = t :: r ∧
      (sf = .latex → ∀ X, jsonStart (t :: X) = true) ∧ (sf = .typst → t = .code v ∧ r = [])
```

A field value as JSON tokens starts with a token the parser takes for JSON.

</div>

<div class="lean-decl" id="Esm.Document.Math.valToks">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.valToks" title="Esm.Document.Math.valToks"><code>valToks</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Math/OpenOp.lean#L29-L30">source</a></div>

```lean
def valToks (c : Ctx) (b : Bool) (v : Json) : List Tok
```

A field value as printed: an expression at level 4 (`b`), or JSON.

</div>

<div class="lean-decl" id="Esm.Document.Math.fieldToks">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.fieldToks" title="Esm.Document.Math.fieldToks"><code>fieldToks</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Math/OpenOp.lean#L33-L34">source</a></div>

```lean
def fieldToks (c : Ctx) (o : String) (kv : String × Json) : List Tok
```

A field of the operator `o` as printed: key, `=`, value.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.callForm_facts">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.callForm_facts" title="Esm.Document.Math.callForm_facts"><code>callForm_facts</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Math/OpenOp.lean#L175-L187">source</a></div>

```lean
theorem callForm_facts {o : String} {fs : List (String × Json)} (h : callFormOK o fs = true) :
    callOps.contains o = false ∧ o ≠ "neg" ∧ o ≠ "pow" ∧ o ≠ "D" ∧
      (coreOps.contains o && !(fieldCallOps.contains o)) = false
```

What the call form's condition gives the reader.

</div>

<p class="lean-meta">This module also proves 13 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Math/OpenOp.lean">the source</a>.</p>
