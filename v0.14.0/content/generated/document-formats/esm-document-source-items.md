---
title: "The skeleton as a sequence of constructs"
type: lean
lean_module: "Esm.Document.Source.Items"
weight: 51
---

<p class="lean-meta">Lean module <code>Esm.Document.Source.Items</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/Items.lean"><code>formal/Esm/Document/Source/Items.lean</code></a> at <code>ffd5aee2f868</code><br>Imports <a href="/generated/document-formats/esm-document-source-skeletonrt"><code>Esm.Document.Source.SkeletonRT</code></a></p>

A container spells a skeleton as a sequence of *constructs*: description blocks, path
blocks, component directives, declarations, equations (model, initialization and
constraint) and reactions. This is the container-independent middle layer:

* [`items`](#Esm.Document.Source.items) lists the constructs of a skeleton in the printer's order;
* [`unitems`](#Esm.Document.Source.unitems) reads a construct sequence back into a skeleton. A construct belongs to
  the section of the last component directive before it, or to the document when
  there is none; within a section, constructs may come in any order (a document can
  interleave declarations and equations with its prose), except that the math entries
  of one field keep their order. [`unitems_items`](#Esm.Document.Source.unitems_items) is the round trip.

Math entries are held as the container's math text (`Doc MR`) at this layer; [`rawDoc`](#Esm.Document.Source.rawDoc)
prints them under each component's symbol table and [`cookDoc`](#Esm.Document.Source.cookDoc) reads them back
([`cookDoc_rawDoc`](#Esm.Document.Source.cookDoc_rawDoc)), the symbol table coming from the rest of the skeleton
(`symFor_mapMath`), so both sides use the same table.

<div class="lean-decl" id="Esm.Document.Source.RItem">
<div class="lean-decl-head"><span class="lean-kind">inductive</span> <a class="lean-name" href="#Esm.Document.Source.RItem" title="Esm.Document.Source.RItem"><code>RItem</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/Items.lean#L30-L39">source</a></div>

```lean
inductive RItem where
  | desc (s : String)
  | block (k : String) (v : Json)
  | comp (K : Kind) (name : String)
  | decl (d : Decl)
  | eqn (raw : String)
  | eqx (r : Role) (raw : String)
  | rxn (x : Rxn String)
  | plot (attrs : List (String × Json))
  | tm (t : Tm String)
```

One construct of a document. An equation is its math text, uninterpreted; so is a
reaction's rate. `eqn` is a model equation, `eqx` an equation of the field of its role
(the containers write it for initialization equations and constraints).

</div>

<div class="lean-decl" id="Esm.Document.Source.mItem">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.mItem" title="Esm.Document.Source.mItem"><code>mItem</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/Items.lean#L42-L47">source</a></div>

```lean
def mItem : MR → RItem
```

The construct of a math entry.

</div>

<div class="lean-decl" id="Esm.Document.Source.compItems">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.compItems" title="Esm.Document.Source.compItems"><code>compItems</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/Items.lean#L50-L53">source</a></div>

```lean
def compItems (c : Comp MR) : List RItem
```

The constructs of a component section.

</div>

<div class="lean-decl" id="Esm.Document.Source.items">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.items" title="Esm.Document.Source.items"><code>items</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/Items.lean#L57-L59">source</a></div>

```lean
def items (D : Doc MR) : List RItem
```

**The constructs of a skeleton**, in the printer's order: the document description,
the top-level blocks, the top-level templates, then each component section.

</div>

## Reading constructs back

<div class="lean-decl" id="Esm.Document.Source.Comp.fresh">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Comp.fresh" title="Esm.Document.Source.Comp.fresh"><code>Comp.fresh</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/Items.lean#L64-L65">source</a></div>

```lean
def Comp.fresh (K : Kind) (n : String) : Comp MR
```

A fresh component section.

</div>

<div class="lean-decl" id="Esm.Document.Source.addTo">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.addTo" title="Esm.Document.Source.addTo"><code>addTo</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/Items.lean#L69-L80">source</a></div>

```lean
def addTo (c : Comp MR) : RItem → Option (Comp MR)
```

Add a construct to a component section. A second description is refused (and a
math field written twice is refused when the section is rebuilt).

</div>

<div class="lean-decl" id="Esm.Document.Source.St">
<div class="lean-decl-head"><span class="lean-kind">structure</span> <a class="lean-name" href="#Esm.Document.Source.St" title="Esm.Document.Source.St"><code>St</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/Items.lean#L84-L89">source</a></div>

```lean
structure St where
  desc : Option String
  blocks : List (String × Json)
  math : List MR
  comps : List (Comp MR)
  cur : Option (Comp MR)
```

The reader's state: the document description, blocks and templates, the finished
sections, and the open one.

</div>

<div class="lean-decl" id="Esm.Document.Source.step">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.step" title="Esm.Document.Source.step"><code>step</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/Items.lean#L93-L103">source</a></div>

```lean
def step (st : St) : RItem → Option St
```

Read one construct. Before the first directive only a description, blocks and
templates are allowed.

</div>

<div class="lean-decl" id="Esm.Document.Source.unitems">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.unitems" title="Esm.Document.Source.unitems"><code>unitems</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/Items.lean#L106-L108">source</a></div>

```lean
def unitems (front : List (String × Json)) (its : List RItem) : Option (Doc MR)
```

**Read a construct sequence** (with the front matter) into a skeleton.

</div>

## The round trip

<div class="lean-decl" id="Esm.Document.Source.itemsOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.itemsOK" title="Esm.Document.Source.itemsOK"><code>itemsOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/Items.lean#L115-L117">source</a></div>

```lean
def itemsOK (D : Doc MR) : Prop
```

A skeleton the constructs can carry: a component's blocks are not keyed by a math
field, and its math blocks are (the parser files a block by its key); the top-level
entries are templates.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.unitems_items">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.unitems_items" title="Esm.Document.Source.unitems_items"><code>unitems_items</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/Items.lean#L251-L303">source</a></div>

```lean
theorem unitems_items (D : Doc MR) (hD : itemsOK D) : unitems D.front (items D) = some D
```

**The construct round trip.**

</div>

## Math entries: printed under the symbol table, and read back

<div class="lean-decl" id="Esm.Document.Source.rawDoc">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.rawDoc" title="Esm.Document.Source.rawDoc"><code>rawDoc</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/Items.lean#L309-L311">source</a></div>

```lean
def rawDoc (pr : Sym → MC → MR) (D : Doc MC) : Doc MR
```

Print every math entry under its symbol table: a top-level template under the
document's, a component's entry under the component's.

</div>

<div class="lean-decl" id="Esm.Document.Source.cookComp">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.cookComp" title="Esm.Document.Source.cookComp"><code>cookComp</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/Items.lean#L315-L316">source</a></div>

```lean
def cookComp (ck : Sym → MR → Option (List MC)) (D : Doc MR) (c : Comp MR) : Option (Comp MC)
```

Read a component's math entries under its symbol table; one math text may hold
several equations (the multi-line variants).

</div>

<div class="lean-decl" id="Esm.Document.Source.cookDoc">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.cookDoc" title="Esm.Document.Source.cookDoc"><code>cookDoc</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/Items.lean#L319-L322">source</a></div>

```lean
def cookDoc (ck : Sym → MR → Option (List MC)) (D : Doc MR) : Option (Doc MC)
```

Read every math entry of a skeleton.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.topSym_rawDoc">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.topSym_rawDoc" title="Esm.Document.Source.topSym_rawDoc"><code>topSym_rawDoc</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/Items.lean#L346-L348">source</a></div>

```lean
theorem topSym_rawDoc (pr : Sym → MC → MR) (hpr : ∀ S, HeadsKept (pr S)) (D : Doc MC) :
    topSym (rawDoc pr D) = topSym D
```

The tables of a printed skeleton are those of the skeleton: the printer keeps every
header.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.cookDoc_rawDoc">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.cookDoc_rawDoc" title="Esm.Document.Source.cookDoc_rawDoc"><code>cookDoc_rawDoc</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/Items.lean#L358-L398">source</a></div>

```lean
theorem cookDoc_rawDoc (pr : Sym → MC → MR) (ck : Sym → MR → Option (List MC))
    (hpr : ∀ S, HeadsKept (pr S)) (D : Doc MC)
    (ht : ∀ m ∈ D.math, ck (topSym D) (pr (topSym D) m) = some [m])
    (h : ∀ c ∈ D.comps, ∀ m ∈ c.math, ck (symFor D c) (pr (symFor D c) m) = some [m]) :
    cookDoc ck (rawDoc pr D) = some D
```

**Math entries read back** when each one does under its table. The table is the same
on both sides: [`symFor`](/generated/document-formats/esm-document-source-skeleton#Esm.Document.Source.symFor) and [`topSym`](/generated/document-formats/esm-document-source-skeleton#Esm.Document.Source.topSym) read headers, never math, and the printer keeps
headers.

</div>

## A container's math printer and reader, entry by entry

<div class="lean-decl" id="Esm.Document.Source.prMx">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.prMx" title="Esm.Document.Source.prMx"><code>prMx</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/Items.lean#L403-L407">source</a></div>

```lean
def prMx (prE : Sym → Eqn → String) (prR : Sym → Json → String) (S : Sym) : MC → MR
```

Print a math entry with the container's equation printer and expression printer.

</div>

<div class="lean-decl" id="Esm.Document.Source.ckMx">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.ckMx" title="Esm.Document.Source.ckMx"><code>ckMx</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/Items.lean#L417-L428">source</a></div>

```lean
def ckMx (ckE : Sym → String → Option (List Eqn)) (ckR : Sym → String → Option Json) (S : Sym) :
    MR → Option (List MC)
```

Read a math entry with the container's equation reader and expression reader.

</div>

<p class="lean-meta">This module also proves 13 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/Items.lean">the source</a>.</p>
