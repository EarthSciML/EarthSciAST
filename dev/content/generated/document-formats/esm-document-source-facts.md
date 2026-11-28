---
title: "What the skeleton of a canonical document satisfies"
type: lean
lean_module: "Esm.Document.Source.Facts"
weight: 52
---

<p class="lean-meta">Lean module <code>Esm.Document.Source.Facts</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Facts.lean"><code>formal/Esm/Document/Source/Facts.lean</code></a> at <code>9c3b4aa7587e</code><br>Imports <a href="/generated/document-formats/esm-document-source-items"><code>Esm.Document.Source.Items</code></a></p>

[`toDoc_ok`](#Esm.Document.Source.toDoc_ok): the skeleton of a canonical document only holds what its container can
spell ([`Caps`](/generated/document-formats/esm-document-source-skeleton#Esm.Document.Source.Caps)), and only well-formed JSON values; the containers' round trips assume
exactly this.

<div class="lean-decl" id="Esm.Document.Source.DocOK">
<div class="lean-decl-head"><span class="lean-kind">structure</span> <a class="lean-name" href="#Esm.Document.Source.DocOK" title="Esm.Document.Source.DocOK"><code>DocOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Facts.lean#L16-L28">source</a></div>

```lean
structure DocOK (caps : Caps) (D : Doc MC) : Prop where
  front : ∀ kv ∈ D.front, caps.frontKey kv.1 = true
  frontWF : jwf (.obj D.front) = true
  desc : ∀ s, D.desc = some s → caps.desc s = true
  blocks : ∀ kv ∈ D.blocks, jwf kv.2 = true
  compName : ∀ c ∈ D.comps, caps.compName c.name = true
  cdesc : ∀ c ∈ D.comps, ∀ s, c.desc = some s → caps.desc s = true
  declName : ∀ c ∈ D.comps, ∀ d ∈ c.decls, caps.declName d.name = true
  attrs : ∀ c ∈ D.comps, ∀ d ∈ c.decls, ∀ a ∈ d.attrs, caps.attr a = true ∧ jwf a.2 = true
  math : ∀ c ∈ D.comps, ∀ m ∈ c.math, caps.item (symFor D c) m = true ∧ mathWF m = true
  mathBlocks : ∀ c ∈ D.comps, ∀ kv ∈ c.mathBlocks, kv.1 ∈ mathFields ∧ jwf kv.2 = true
  cblocks : ∀ c ∈ D.comps, ∀ kv ∈ c.blocks, kv.1 ∉ mathFields ∧ jwf kv.2 = true
  rmath : ∀ m ∈ D.math, caps.item (topSym D) m = true ∧ mathWF m = true ∧ ∃ t, m = .tm t
```

What a container needs of a skeleton.

</div>

## Well-formed values

## A component

## The document

<div class="lean-decl lean-theorem" id="Esm.Document.Source.look_index_sets">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.look_index_sets" title="Esm.Document.Source.look_index_sets"><code>look_index_sets</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Facts.lean#L239-L247">source</a></div>

```lean
theorem look_index_sets (caps : Caps) (tn : Bool) {kvs : List (String × Json)} (hl : keysSorted kvs = true) :
    look "index_sets" (rootBlocks caps tn kvs) = look "index_sets" kvs
```

The top-level blocks keep `index_sets` as it is.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.rootTs_toDoc">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.rootTs_toDoc" title="Esm.Document.Source.rootTs_toDoc"><code>rootTs_toDoc</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Facts.lean#L251-L274">source</a></div>

```lean
theorem rootTs_toDoc (caps : Caps) {kvs : List (String × Json)} (hl : keysSorted kvs = true) :
    rootTs (toDoc caps (.obj kvs)).blocks (toDoc caps (.obj kvs)).math =
      templatesOf (look "operators" kvs)
```

The document's templates, read from the skeleton, are those of the `operators`
value.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.toDoc_ok">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.toDoc_ok" title="Esm.Document.Source.toDoc_ok"><code>toDoc_ok</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Facts.lean#L284-L460">source</a></div>

```lean
theorem toDoc_ok (caps : Caps) (hesm : caps.frontKey "esm" = true) (d : Json)
    (hd : canonDoc d = true) : DocOK caps (toDoc caps d)
```

**The skeleton of a canonical document is spellable**, when the container can spell
the front-matter key `esm`.

</div>

<p class="lean-meta">This module also proves 12 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Facts.lean">the source</a>.</p>
