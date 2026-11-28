---
title: "Objects in canonical form: sorting entries, and splitting an object between surfaces"
type: lean
lean_module: "Esm.Document.Source.Keys"
weight: 48
---

<p class="lean-meta">Lean module <code>Esm.Document.Source.Keys</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Source/Keys.lean"><code>formal/Esm/Document/Source/Keys.lean</code></a> at <code>86bed77c797f</code><br>Imports <a href="/generated/document-formats/esm-document-math-expr"><code>Esm.Document.Math.Expr</code></a>, <code>Mathlib.Data.List.Sort</code>, <code>Mathlib.Data.String.Basic</code></p>

A canonical ESM document has the keys of every object in strictly increasing order
(the sorted-key canonical serialization). The document printer takes an object apart:
some entries get a surface of their own (a declaration, a component directive), the
rest is printed as a path block. The parser collects the entries back from wherever
they were written, in whatever order, and sorts them. This module holds the two facts
that make that sound:

* [`sortKeys_ext`](#Esm.Document.Source.sortKeys_ext): sorting a list that holds, key by key, the same entries as a
  canonical object gives that object;
* [`joinField_splitField`](#Esm.Document.Source.joinField_splitField): an object-valued field split between its own surfaces and a
  residue block is rebuilt exactly.

## Equality of values

Decided structurally, so a decoder can check a candidate by encoding it again.

## Sorting by key

<div class="lean-decl" id="Esm.Document.Source.sortKeys">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.sortKeys" title="Esm.Document.Source.sortKeys"><code>sortKeys</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Source/Keys.lean#L82-L83">source</a></div>

```lean
def sortKeys (l : List (String × Json)) : List (String × Json)
```

The entries ordered by key (a stable merge sort).

</div>

<div class="lean-decl" id="Esm.Document.Source.at_">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.at_" title="Esm.Document.Source.at_"><code>at_</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Source/Keys.lean#L86-L87">source</a></div>

```lean
def at_ (k : String) (l : List (String × Json)) : List (String × Json)
```

The entries of `l` with key `k`.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.sortKeys_eq">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.sortKeys_eq" title="Esm.Document.Source.sortKeys_eq"><code>sortKeys_eq</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Source/Keys.lean#L118-L132">source</a></div>

```lean
theorem sortKeys_eq {l l' : List (String × Json)} (hp : l.Perm l') (hs : keysSorted l' = true) :
    sortKeys l = l'
```

Sorting a permutation of a canonical (strictly key-sorted) list gives that list.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.sortKeys_ext">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.sortKeys_ext" title="Esm.Document.Source.sortKeys_ext"><code>sortKeys_ext</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Source/Keys.lean#L136-L146">source</a></div>

```lean
theorem sortKeys_ext {R l : List (String × Json)} (hl : keysSorted l = true)
    (h : ∀ k, at_ k R = at_ k l) : sortKeys R = l
```

**Key-by-key extensionality.** A list holding, for every key, exactly the entries a
canonical list holds sorts to that list.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.at_of_sorted">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.at_of_sorted" title="Esm.Document.Source.at_of_sorted"><code>at_of_sorted</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Source/Keys.lean#L184-L207">source</a></div>

```lean
theorem at_of_sorted {l : List (String × Json)} (hl : keysSorted l = true) (k : String) :
    at_ k l = match look k l with
```

In a canonical list, the entries with key `k` are the one `look` finds, or none.

</div>

## Splitting an object-valued field

<div class="lean-decl" id="Esm.Document.Source.splitField">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.splitField" title="Esm.Document.Source.splitField"><code>splitField</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Source/Keys.lean#L224-L229">source</a></div>

```lean
def splitField {β : Type} (pick : String → Json → Option β) : Json → List β × Option Json
```

The entries of an object-valued field that get a surface of their own (`pick`
returns their piece) and the residue, printed as a path block under the field's key.
A value that is not an object is all residue. The residue block is omitted only when
some entry was picked and none is left; an object none of whose entries is picked
(including `{}`) is all residue, so an absent field and an empty one stay apart.

</div>

<div class="lean-decl" id="Esm.Document.Source.splitOpt">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.splitOpt" title="Esm.Document.Source.splitOpt"><code>splitOpt</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Source/Keys.lean#L232-L234">source</a></div>

```lean
def splitOpt {β : Type} (pick : String → Json → Option β) : Option Json → List β × Option Json
```

[`splitField`](#Esm.Document.Source.splitField) of a field that may be absent.

</div>

<div class="lean-decl" id="Esm.Document.Source.joinField">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.joinField" title="Esm.Document.Source.joinField"><code>joinField</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Source/Keys.lean#L238-L246">source</a></div>

```lean
def joinField {β : Type} (back : β → Option (String × Json)) (ps : List β) (r : Option Json) :
    Option (Option Json)
```

The field rebuilt from its pieces (each mapped back to its entry) and its residue:
`none` when they do not fit together, `some none` when the field is absent.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.joinField_splitField">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.joinField_splitField" title="Esm.Document.Source.joinField_splitField"><code>joinField_splitField</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Source/Keys.lean#L263-L309">source</a></div>

```lean
theorem joinField_splitField {β : Type} (pick : String → Json → Option β)
    (back : β → Option (String × Json)) (v : Json)
    (hv : ∀ kvs, v = .obj kvs → keysSorted kvs = true)
    (hb : ∀ kvs, v = .obj kvs → ∀ k w p, (k, w) ∈ kvs → pick k w = some p → back p = some (k, w)) :
    joinField back (splitField pick v).1 (splitField pick v).2 = some (some v)
```

**The split field is rebuilt exactly**, when every piece maps back to its entry.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.joinField_splitOpt">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.joinField_splitOpt" title="Esm.Document.Source.joinField_splitOpt"><code>joinField_splitOpt</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Source/Keys.lean#L312-L322">source</a></div>

```lean
theorem joinField_splitOpt {β : Type} (pick : String → Json → Option β)
    (back : β → Option (String × Json)) (o : Option Json)
    (hv : ∀ kvs, o = some (.obj kvs) → keysSorted kvs = true)
    (hb : ∀ kvs, o = some (.obj kvs) →
      ∀ k w p, (k, w) ∈ kvs → pick k w = some p → back p = some (k, w)) :
    joinField back (splitOpt pick o).1 (splitOpt pick o).2 = some o
```

The same, for a field that may be absent.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.splitField_fst">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.splitField_fst" title="Esm.Document.Source.splitField_fst"><code>splitField_fst</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Source/Keys.lean#L325-L329">source</a></div>

```lean
theorem splitField_fst {β : Type} (pick : String → Json → Option β) (v : Json) :
    (splitField pick v).1 = (match v with
      | .obj kvs => kvs.filterMap (fun kv => pick kv.1 kv.2)
      | _ => [])
```

The pieces of a split field are the picks of its entries.

</div>

## Reading one entry back

<div class="lean-decl" id="Esm.Document.Source.pickOne">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.pickOne" title="Esm.Document.Source.pickOne"><code>pickOne</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Source/Keys.lean#L335-L339">source</a></div>

```lean
def pickOne (k : String) (l : List (String × Json)) : Option (Option Json)
```

The value of the only entry with key `k`: `some none` when there is none, `none`
when there are several.

</div>

<p class="lean-meta">This module also proves 15 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Source/Keys.lean">the source</a>.</p>
