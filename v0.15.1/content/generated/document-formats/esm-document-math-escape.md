---
title: "Round trip, case by case: the escape form"
type: lean
lean_module: "Esm.Document.Math.Escape"
weight: 32
---

<p class="lean-meta">Lean module <code>Esm.Document.Math.Escape</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Math/Escape.lean"><code>formal/Esm/Document/Math/Escape.lean</code></a> at <code>86bed77c797f</code><br>Imports <a href="/generated/document-formats/esm-document-math-cases9"><code>Esm.Document.Math.Cases9</code></a></p>

Every node has it: LaTeX `\esm{op}{fields}{args}` with the fields as JSON tokens, Typst
`esm.node("op", #(fields), args)`. The parser puts `op` and `args` back in their
sorted places among the fields (`mkNode_fieldsOf`).

## JSON tokens

## Putting `op` and `args` back

<div class="lean-decl lean-theorem" id="Esm.Document.Math.addAcc_of_lvl">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.addAcc_of_lvl" title="Esm.Document.Math.addAcc_of_lvl"><code>addAcc_of_lvl</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Math/Escape.lean#L206-L218">source</a></div>

```lean
theorem addAcc_of_lvl {c : Ctx} {kvs : List (String × Json)} (h : (pr c (.obj kvs)).lvl = 10) :
    addAcc (.obj kvs) = [.obj kvs]
```

A node printed at level 10 is not a `+` chain.

</div>

## The escape node

<div class="lean-decl lean-theorem" id="Esm.Document.Math.fieldsOf_wf">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.fieldsOf_wf" title="Esm.Document.Math.fieldsOf_wf"><code>fieldsOf_wf</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Math/Escape.lean#L245-L258">source</a></div>

```lean
theorem fieldsOf_wf {kvs : List (String × Json)} (hs : keysSorted kvs = true)
    (hf : ∀ kv ∈ fieldsOf kvs, jwf kv.2 = true) : (Json.obj (fieldsOf kvs)).WF
```

The fields of a node with sorted keys, each well formed, are a well-formed object.

</div>

<p class="lean-meta">This module also proves 11 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Math/Escape.lean">the source</a>.</p>
