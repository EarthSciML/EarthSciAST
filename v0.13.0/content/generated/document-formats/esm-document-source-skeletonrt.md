---
title: "The document layer round trip"
type: lean
lean_module: "Esm.Document.Source.SkeletonRT"
weight: 49
---

<p class="lean-meta">Lean module <code>Esm.Document.Source.SkeletonRT</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Source/SkeletonRT.lean"><code>formal/Esm/Document/Source/SkeletonRT.lean</code></a> at <code>5af01ca9d41a</code><br>Imports <a href="/generated/document-formats/esm-document-source-skeleton"><code>Esm.Document.Source.Skeleton</code></a></p>

[`ofDoc_toDoc`](#Esm.Document.Source.ofDoc_toDoc): a canonical document is rebuilt exactly from its skeleton, for every
choice of container predicates [`Caps`](/generated/document-formats/esm-document-source-skeleton#Esm.Document.Source.Caps).

## Entries kept, dropped or replaced by key

<div class="lean-decl lean-theorem" id="Esm.Document.Source.at_filterMap_comm">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.at_filterMap_comm" title="Esm.Document.Source.at_filterMap_comm"><code>at_filterMap_comm</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Source/SkeletonRT.lean#L17-L40">source</a></div>

```lean
theorem at_filterMap_comm (g : String × Json → Option (String × Json))
    (hg : ∀ kv w, g kv = some w → w.1 = kv.1) (k : String) :
    ∀ kvs : List (String × Json), at_ k (kvs.filterMap g) = (at_ k kvs).filterMap g
```

Restricting to a key commutes with a map that keeps keys.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.sortKeys_cons_filter">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.sortKeys_cons_filter" title="Esm.Document.Source.sortKeys_cons_filter"><code>sortKeys_cons_filter</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Source/SkeletonRT.lean#L93-L106">source</a></div>

```lean
theorem sortKeys_cons_filter {kvs : List (String × Json)} (hl : keysSorted kvs = true)
    {k : String} {v : Json} (hk : look k kvs = some v) :
    sortKeys ((k, v) :: kvs.filter (fun kv => kv.1 != k)) = kvs
```

Putting back an entry that was filtered out of a canonical object restores it.

</div>

## Declarations

<div class="lean-decl lean-theorem" id="Esm.Document.Source.declFields_back">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.declFields_back" title="Esm.Document.Source.declFields_back"><code>declFields_back</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Source/SkeletonRT.lean#L174-L191">source</a></div>

```lean
theorem declFields_back (caps : Caps) (K : Kind) :
    ∀ f ∈ declFields caps K, ∀ n v d, f.2 n v = some d → canonVal v = true →
      backDecl K d = some (n, v) ∧ declField K d.kind = some f.1
```

Every declaration a field's picker produces belongs to that field, and stands for
its entry.

</div>

## A component

<div class="lean-decl lean-theorem" id="Esm.Document.Source.compBase_blocks_at">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.compBase_blocks_at" title="Esm.Document.Source.compBase_blocks_at"><code>compBase_blocks_at</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Source/SkeletonRT.lean#L253-L271">source</a></div>

```lean
theorem compBase_blocks_at (caps : Caps) (K : Kind) (name : String) {kvs : List (String × Json)}
    (hl : keysSorted kvs = true) (k : String) :
    at_ k (compBase caps K name kvs).blocks = match look k kvs with
```

The blocks of a component, key by key.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.declKv_compOf">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.declKv_compOf" title="Esm.Document.Source.declKv_compOf"><code>declKv_compOf</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Source/SkeletonRT.lean#L274-L350">source</a></div>

```lean
theorem declKv_compOf (caps : Caps) (root : List (String × Json)) (rt : List (String × List String)) (K : Kind) (name : String)
    {kvs : List (String × Json)} (hv : canonVal (.obj kvs) = true) (f : String × (String → Json → Option Decl))
    (hf : f ∈ declFields caps K)
    (hsep : ∀ g ∈ declFields caps K, ∀ d ∈ (splitOpt g.2 (look g.1 kvs)).1,
      (declField K d.kind == some f.1) = (g.1 == f.1)) :
    declKv K (compOf caps root rt K name kvs) f.1 = some (at_ f.1 kvs)
```

A declaration field is rebuilt from the declarations and the residue block.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.filter_flatMap_field">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.filter_flatMap_field" title="Esm.Document.Source.filter_flatMap_field"><code>filter_flatMap_field</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Source/SkeletonRT.lean#L389-L410">source</a></div>

```lean
theorem filter_flatMap_field (P : String → List MC) (hP : ∀ g, ∀ m ∈ P g, m.field = g) :
    ∀ L : List String, L.Nodup → ∀ f ∈ L, (L.flatMap P).filter (fun m => m.field == f) = P f
```

The entries of the parts for field `f`, among the parts of distinct fields.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.at_filterMap_field">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.at_filterMap_field" title="Esm.Document.Source.at_filterMap_field"><code>at_filterMap_field</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Source/SkeletonRT.lean#L413-L448">source</a></div>

```lean
theorem at_filterMap_field (Q : String → Option (String × Json))
    (hQ : ∀ g kv, Q g = some kv → kv.1 = g) :
    ∀ L : List String, L.Nodup → ∀ f ∈ L, at_ f (L.filterMap Q) = (Q f).toList
```

The blocks of the parts for field `f`, among the parts of distinct fields.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.mathKv_compOf">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.mathKv_compOf" title="Esm.Document.Source.mathKv_compOf"><code>mathKv_compOf</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Source/SkeletonRT.lean#L473-L494">source</a></div>

```lean
theorem mathKv_compOf (caps : Caps) (root : List (String × Json)) (rt : List (String × List String)) (K : Kind) (name : String)
    {kvs : List (String × Json)} (hl : keysSorted kvs = true) (f : String) (hf : f ∈ mathFields) :
    mathKv (compOf caps root rt K name kvs) f = some (at_ f kvs)
```

A math field is rebuilt from its entries or its block.

</div>

## The symbol table of a finished section

<div class="lean-decl lean-theorem" id="Esm.Document.Source.templatesOf_mathOf">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.templatesOf_mathOf" title="Esm.Document.Source.templatesOf_mathOf"><code>templatesOf_mathOf</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Source/SkeletonRT.lean#L529-L554">source</a></div>

```lean
theorem templatesOf_mathOf {caps : Caps} {S : Sym} {v : Json} {ms : List MC}
    (h : mathOf caps S "expression_templates" v = some ms) :
    templatesOf (some v) = ms.filterMap Mx.head
```

The headers of the native template entries are the symbol-table entries of the
`expression_templates` value.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.compTs_compOf">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.compTs_compOf" title="Esm.Document.Source.compTs_compOf"><code>compTs_compOf</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Source/SkeletonRT.lean#L590-L615">source</a></div>

```lean
theorem compTs_compOf (caps : Caps) (root : List (String × Json)) (rt : List (String × List String))
    (K : Kind) (name : String) (kvs : List (String × Json)) :
    compTs (compOf caps root rt K name kvs) = templatesOf (look "expression_templates" kvs)
```

**The finished section's templates are those its entries were decided under.**

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.symWith_compOf">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.symWith_compOf" title="Esm.Document.Source.symWith_compOf"><code>symWith_compOf</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Source/SkeletonRT.lean#L618-L622">source</a></div>

```lean
theorem symWith_compOf (caps : Caps) (root : List (String × Json)) (rt : List (String × List String))
    (K : Kind) (name : String) (kvs : List (String × Json)) :
    symWith root rt (compOf caps root rt K name kvs) (compTs (compOf caps root rt K name kvs)) =
      compSym root rt K caps name kvs
```

The table of a finished section is the one its entries were decided under.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.at_flatMap_at">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.at_flatMap_at" title="Esm.Document.Source.at_flatMap_at"><code>at_flatMap_at</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Source/SkeletonRT.lean#L625-L635">source</a></div>

```lean
theorem at_flatMap_at (k : String) (kvs : List (String × Json)) :
    ∀ L : List String, L.Nodup → at_ k (L.flatMap (fun f => at_ f kvs)) = if k ∈ L then at_ k kvs else []
```

Restricting a concatenation of restrictions to distinct keys.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.ofComp_compOf">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.ofComp_compOf" title="Esm.Document.Source.ofComp_compOf"><code>ofComp_compOf</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Source/SkeletonRT.lean#L638-L695">source</a></div>

```lean
theorem ofComp_compOf (caps : Caps) (root : List (String × Json)) (rt : List (String × List String)) (K : Kind) (name : String)
    {kvs : List (String × Json)} (hv : canonVal (.obj kvs) = true) :
    ofComp (compOf caps root rt K name kvs) = some (.obj kvs)
```

**A component is rebuilt exactly from its section.**

</div>

## The document

<div class="lean-decl lean-theorem" id="Esm.Document.Source.meta_rebuild">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.meta_rebuild" title="Esm.Document.Source.meta_rebuild"><code>meta_rebuild</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Source/SkeletonRT.lean#L719-L749">source</a></div>

```lean
theorem meta_rebuild (caps : Caps) {mkvs : List (String × Json)} (hl : keysSorted mkvs = true) :
    sortKeys (mkvs.filter (fun kv => !(kv.1 == "description" &&
        (descOf caps (look "description" mkvs)).isSome)) ++
      optKv "description" ((descOf caps (look "description" mkvs)).map Json.str)) = mkvs
```

The `metadata` entries are rebuilt from the front matter and the description.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.compField_join">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.compField_join" title="Esm.Document.Source.compField_join"><code>compField_join</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Source/SkeletonRT.lean#L806-L824">source</a></div>

```lean
theorem compField_join (caps : Caps) {kvs : List (String × Json)}
    (hv : canonVal (.obj kvs) = true) (root : List (String × Json)) (rt : List (String × List String))
    (K : Kind) (f : String) :
    joinField backComp ((splitOpt (pickComp caps) (look f kvs)).1.map
        (fun p => compOf caps root rt K p.1 p.2)) (splitOpt (pickComp caps) (look f kvs)).2 =
      some (look f kvs)
```

A component field (`models`, `reaction_systems`) is rebuilt from its directives
and its residue block.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.ofDoc_toDoc">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.ofDoc_toDoc" title="Esm.Document.Source.ofDoc_toDoc"><code>ofDoc_toDoc</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Source/SkeletonRT.lean#L846-L1012">source</a></div>

```lean
theorem ofDoc_toDoc (caps : Caps) (d : Json) (hd : canonDoc d = true) :
    ofDoc (toDoc caps d) = some d
```

**The document layer round trip.** For every container (`caps`), a document in
canonical form is rebuilt exactly from its skeleton.

</div>

<p class="lean-meta">This module also proves 36 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Source/SkeletonRT.lean">the source</a>.</p>
