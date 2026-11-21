---
title: "Round trip, case by case: expression templates"
type: lean
lean_module: "Esm.Document.Math.Templates"
weight: 44
---

<p class="lean-meta">Lean module <code>Esm.Document.Math.Templates</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Math/Templates.lean"><code>formal/Esm/Document/Math/Templates.lean</code></a> at <code>1b8dd9b3a909</code><br>Imports <a href="/generated/document-formats/esm-document-math-openop"><code>Esm.Document.Math.OpenOp</code></a></p>

Positional arguments read back through the parameter list of the symbol table, and the
parser sorts the bindings; named arguments read back in the printed (sorted) order.

## Sorting bindings

## Reserved names

## Positional arguments

## Named arguments

<div class="lean-decl lean-theorem" id="Esm.Document.Math.pPrim_named">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.pPrim_named" title="Esm.Document.Math.pPrim_named"><code>pPrim_named</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Math/Templates.lean#L252-L287">source</a></div>

```lean
theorem pPrim_named (c : Ctx) (n : String) (bs : List (String × Json))
    (hn : tnameOK n = true) (hM : ∀ kv ∈ bs, M c kv.2) (hne : bs ≠ [])
    (hk : ∀ kv ∈ bs, nameOK kv.1 = true) (hnd : (bs.map Prod.fst).Nodup) (rest : List Tok) (f : Nat)
    (hf : need 10 (callToks c.sf [.opn n] (bs.map (itemToks c))).length ≤ f) :
    pPrim c f (callToks c.sf [.opn n] (bs.map (itemToks c)) ++ rest) =
      some (tNode n (sortKV bs), rest)
```

Named template arguments, in any order and with distinct names, read back as the
template application with its bindings sorted, whether or not the symbol table knows the
template's parameters (the printer writes them named, in sorted order, only when it does
not; `Esm.Document.Math.Variants.variant_named_args`).

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.sortKV_of_sorted">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.sortKV_of_sorted" title="Esm.Document.Math.sortKV_of_sorted"><code>sortKV_of_sorted</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Math/Templates.lean#L290-L292">source</a></div>

```lean
theorem sortKV_of_sorted (bs : List (String × Json)) (hs : keysSorted bs = true) : sortKV bs = bs
```

Sorted bindings sort to themselves.

</div>

<p class="lean-meta">This module also proves 17 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Math/Templates.lean">the source</a>.</p>
