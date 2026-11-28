---
title: "Round trip, case by case: the escape form"
type: lean
lean_module: "Esm.Document.Math.Escape"
weight: 32
---

<p class="lean-meta">Lean module <code>Esm.Document.Math.Escape</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Escape.lean"><code>formal/Esm/Document/Math/Escape.lean</code></a> at <code>ffd5aee2f868</code><br>Imports <a href="/generated/document-formats/esm-document-math-cases9"><code>Esm.Document.Math.Cases9</code></a></p>

Every node has it: LaTeX `\esm{op}{fields}{args}` with the fields as JSON tokens, Typst
`esm.node("op", #(fields), args)`. The parser puts `op` and `args` back in their
sorted places among the fields (`mkNode_fieldsOf`).

## JSON tokens

## Putting `op` and `args` back

<div class="lean-decl lean-theorem" id="Esm.Document.Math.addAcc_of_lvl">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.addAcc_of_lvl" title="Esm.Document.Math.addAcc_of_lvl"><code>addAcc_of_lvl</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Escape.lean#L203-L215">source</a></div>

```lean
theorem addAcc_of_lvl {c : Ctx} {kvs : List (String × Json)} (h : (pr c (.obj kvs)).lvl = 10) :
    addAcc (.obj kvs) = [.obj kvs]
```

A node printed at level 10 is not a `+` chain.

</div>

## The escape node

<p class="lean-meta">This module also proves 11 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Escape.lean">the source</a>.</p>
