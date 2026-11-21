---
title: "The skeleton as a sequence of constructs"
type: lean
lean_module: "Esm.Document.Source.Items"
weight: 51
---

<p class="lean-meta">Lean module <code>Esm.Document.Source.Items</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Items.lean"><code>formal/Esm/Document/Source/Items.lean</code></a> at <code>1b8dd9b3a909</code><br>Imports <a href="/generated/document-formats/esm-document-source-skeletonrt"><code>Esm.Document.Source.SkeletonRT</code></a>, <a href="/generated/document-formats/esm-document-notation"><code>Esm.Document.Notation</code></a></p>

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
<div class="lean-decl-head"><span class="lean-kind">inductive</span> <a class="lean-name" href="#Esm.Document.Source.RItem" title="Esm.Document.Source.RItem"><code>RItem</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Items.lean#L31-L40">source</a></div>

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
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.mItem" title="Esm.Document.Source.mItem"><code>mItem</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Items.lean#L43-L48">source</a></div>

```lean
def mItem : MR → RItem
```

The construct of a math entry.

</div>

<div class="lean-decl" id="Esm.Document.Source.compItems">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.compItems" title="Esm.Document.Source.compItems"><code>compItems</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Items.lean#L51-L54">source</a></div>

```lean
def compItems (c : Comp MR) : List RItem
```

The constructs of a component section.

</div>

<div class="lean-decl" id="Esm.Document.Source.items">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.items" title="Esm.Document.Source.items"><code>items</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Items.lean#L58-L60">source</a></div>

```lean
def items (D : Doc MR) : List RItem
```

**The constructs of a skeleton**, in the printer's order: the document description,
the top-level blocks, the top-level templates, then each component section.

</div>

## Reading constructs back

<div class="lean-decl" id="Esm.Document.Source.Comp.fresh">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Comp.fresh" title="Esm.Document.Source.Comp.fresh"><code>Comp.fresh</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Items.lean#L65-L66">source</a></div>

```lean
def Comp.fresh (K : Kind) (n : String) : Comp MR
```

A fresh component section.

</div>

<div class="lean-decl" id="Esm.Document.Source.addTo">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.addTo" title="Esm.Document.Source.addTo"><code>addTo</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Items.lean#L70-L81">source</a></div>

```lean
def addTo (c : Comp MR) : RItem → Option (Comp MR)
```

Add a construct to a component section. A second description is refused (and a
math field written twice is refused when the section is rebuilt).

</div>

<div class="lean-decl" id="Esm.Document.Source.St">
<div class="lean-decl-head"><span class="lean-kind">structure</span> <a class="lean-name" href="#Esm.Document.Source.St" title="Esm.Document.Source.St"><code>St</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Items.lean#L85-L90">source</a></div>

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
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.step" title="Esm.Document.Source.step"><code>step</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Items.lean#L94-L104">source</a></div>

```lean
def step (st : St) : RItem → Option St
```

Read one construct. Before the first directive only a description, blocks and
templates are allowed.

</div>

<div class="lean-decl" id="Esm.Document.Source.unitems">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.unitems" title="Esm.Document.Source.unitems"><code>unitems</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Items.lean#L107-L109">source</a></div>

```lean
def unitems (front : List (String × Json)) (its : List RItem) : Option (Doc MR)
```

**Read a construct sequence** (with the front matter) into a skeleton.

</div>

## The round trip

<div class="lean-decl" id="Esm.Document.Source.itemsOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.itemsOK" title="Esm.Document.Source.itemsOK"><code>itemsOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Items.lean#L116-L118">source</a></div>

```lean
def itemsOK (D : Doc MR) : Prop
```

A skeleton the constructs can carry: a component's blocks are not keyed by a math
field, and its math blocks are (the parser files a block by its key); the top-level
entries are templates.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.unitems_items">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.unitems_items" title="Esm.Document.Source.unitems_items"><code>unitems_items</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Items.lean#L252-L304">source</a></div>

```lean
theorem unitems_items (D : Doc MR) (hD : itemsOK D) : unitems D.front (items D) = some D
```

**The construct round trip.**

</div>

## Expressions inside path blocks

[`Notation.compExprPaths`](/generated/document-formats/esm-document-notation#Esm.Document.Notation.compExprPaths) and [`Notation.topExprPaths`](/generated/document-formats/esm-document-notation#Esm.Document.Notation.topExprPaths) list the expression-valued fields of
path blocks. The printer turns a value there into a math leaf (`Json.math`) when it is a
well-formed expression whose math text the container can delimit ([`Json.mathOK`](/generated/document-formats/esm-document-json#Esm.Document.Json.mathOK), and the
container's own test `ok`: [`Yaml.plainMathOK`](/generated/document-formats/esm-document-yaml#Esm.Document.Yaml.plainMathOK) for Markdown); the reader reads every math
leaf back, wherever it is.

<div class="lean-decl" id="Esm.Document.Source.stepKey">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.stepKey" title="Esm.Document.Source.stepKey"><code>stepKey</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Items.lean#L316-L321">source</a></div>

```lean
def stepKey (k : Option String) (ps : List (List Notation.Seg)) : List (List Notation.Seg)
```

The paths below the entry `k` of an object, or below an element of an array (`none`,
which `Seg.any` and `Seg.elem` match).

</div>

<div class="lean-decl" id="Esm.Document.Source.atPaths">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.atPaths" title="Esm.Document.Source.atPaths"><code>atPaths</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Items.lean#L326-L329">source</a></div>

```lean
def atPaths (leaf : Json → Json) (ps : List (List Notation.Seg)) : Json → Json
```

`leaf` applied to every value of `v` at one of the paths `ps` (the shortest first:
a value at a path is not looked into); every other value as it is.

</div>

<div class="lean-decl" id="Esm.Document.Source.mathLeaf">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.mathLeaf" title="Esm.Document.Source.mathLeaf"><code>mathLeaf</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Items.lean#L342-L343">source</a></div>

```lean
def mathLeaf (prR : Sym → Json → String) (ok : String → Bool) (S : Sym) (v : Json) : Json
```

A value at an expression path: its math text, when it is a well-formed expression
whose text the container can delimit ([`Json.mathOK`](/generated/document-formats/esm-document-json#Esm.Document.Json.mathOK) and `ok`); otherwise the value.

</div>

<div class="lean-decl" id="Esm.Document.Source.mathify">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.mathify" title="Esm.Document.Source.mathify"><code>mathify</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Items.lean#L347-L349">source</a></div>

```lean
def mathify (prR : Sym → Json → String) (ok : String → Bool) (S : Sym)
    (ps : List (List Notation.Seg)) (bs : List (String × Json)) : List (String × Json)
```

**Print a section's path blocks**: every expression at one of the paths `ps` (keyed by
the block's key) as math under the symbol table `S`.

</div>

<div class="lean-decl" id="Esm.Document.Source.cookV">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.cookV" title="Esm.Document.Source.cookV"><code>cookV</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Items.lean#L353-L357">source</a></div>

```lean
def cookV (ck : String → Option Json) : Json → Option Json
```

Every math leaf of a value read back with `ck`.

</div>

<div class="lean-decl" id="Esm.Document.Source.cookBlocks">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.cookBlocks" title="Esm.Document.Source.cookBlocks"><code>cookBlocks</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Items.lean#L376-L378">source</a></div>

```lean
def cookBlocks (ckR : Sym → String → Option Json) (S : Sym) (bs : List (String × Json)) :
    Option (List (String × Json))
```

**Read a section's path blocks**: every math leaf, wherever it is, read back as an
expression under the symbol table `S`.

</div>

### The path-block round trip

<div class="lean-decl lean-theorem" id="Esm.Document.Source.cookV_wf">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.cookV_wf" title="Esm.Document.Source.cookV_wf"><code>cookV_wf</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Items.lean#L384-L391">source</a></div>

```lean
theorem cookV_wf (ck : String → Option Json) : ∀ v : Json, v.WF → cookV ck v = some v
```

A value with no math leaf reads back as itself.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.cookV_mathLeaf">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.cookV_mathLeaf" title="Esm.Document.Source.cookV_mathLeaf"><code>cookV_mathLeaf</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Items.lean#L404-L412">source</a></div>

```lean
theorem cookV_mathLeaf (prR : Sym → Json → String) (ok : String → Bool) (ck : String → Option Json) (S : Sym)
    (hck : ∀ e, isE e = true → ck (prR S e) = some e) (v : Json) (hv : v.WF) :
    cookV ck (mathLeaf prR ok S v) = some v
```

The math leaf of a value reads back as the value.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.cookBlocks_mathify">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.cookBlocks_mathify" title="Esm.Document.Source.cookBlocks_mathify"><code>cookBlocks_mathify</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Items.lean#L453-L461">source</a></div>

```lean
theorem cookBlocks_mathify (prR : Sym → Json → String) (ok : String → Bool) (ckR : Sym → String → Option Json)
    (S : Sym) (hck : ∀ e, isE e = true → ckR S (prR S e) = some e) (ps : List (List Notation.Seg)) :
    ∀ bs : List (String × Json), (∀ kv ∈ bs, kv.2.WF) → cookBlocks ckR S (mathify prR ok S ps bs) = some bs
```

**Path blocks read back**: the math the printer put in reads back under the same
table, and every other value is as it was.

</div>

### What the printer leaves for the codecs

<div class="lean-decl lean-theorem" id="Esm.Document.Source.mathify_wfm">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.mathify_wfm" title="Esm.Document.Source.mathify_wfm"><code>mathify_wfm</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Items.lean#L512-L518">source</a></div>

```lean
theorem mathify_wfm (prR : Sym → Json → String) (ok : String → Bool) (S : Sym) (ps : List (List Notation.Seg))
    (bs : List (String × Json)) (h : ∀ kv ∈ bs, kv.2.WF) :
    ∀ kv ∈ mathify prR ok S ps bs, kv.2.WFm
```

Every printed block value is well formed with math leaves.

</div>

### The symbol tables do not change

<div class="lean-decl lean-theorem" id="Esm.Document.Source.atPaths_nil">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.atPaths_nil" title="Esm.Document.Source.atPaths_nil"><code>atPaths_nil</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Items.lean#L523-L526">source</a></div>

```lean
theorem atPaths_nil (leaf : Json → Json) : ∀ v : Json, atPaths leaf [] v = v
```

Away from every path the value is as it was.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.keysOf_atPaths">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.keysOf_atPaths" title="Esm.Document.Source.keysOf_atPaths"><code>keysOf_atPaths</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Items.lean#L536-L539">source</a></div>

```lean
theorem keysOf_atPaths (leaf : Json → Json) (ps : List (List Notation.Seg)) (h : ps.contains [] = false)
    (v : Json) : keysOf (some (atPaths leaf ps v)) = keysOf (some v)
```

With no path ending here, an object keeps its keys.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.keysOf_mathify">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.keysOf_mathify" title="Esm.Document.Source.keysOf_mathify"><code>keysOf_mathify</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Items.lean#L552-L558">source</a></div>

```lean
theorem keysOf_mathify (prR : Sym → Json → String) (ok : String → Bool) (S : Sym) (ps : List (List Notation.Seg)) (k : String)
    (h : (stepKey (some k) ps).contains [] = false) (bs : List (String × Json)) :
    keysOf (look k (mathify prR ok S ps bs)) = keysOf (look k bs)
```

The keys of a block are the same after printing, when no path ends at the block.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.look_mathify_none">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.look_mathify_none" title="Esm.Document.Source.look_mathify_none"><code>look_mathify_none</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Items.lean#L561-L565">source</a></div>

```lean
theorem look_mathify_none (prR : Sym → Json → String) (ok : String → Bool) (S : Sym) (ps : List (List Notation.Seg)) (k : String)
    (h : stepKey (some k) ps = []) (bs : List (String × Json)) :
    look k (mathify prR ok S ps bs) = look k bs
```

A block no path starts at is the same after printing.

</div>

<div class="lean-decl" id="Esm.Document.Source.mathifyDoc">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.mathifyDoc" title="Esm.Document.Source.mathifyDoc"><code>mathifyDoc</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Items.lean#L569-L573">source</a></div>

```lean
def mathifyDoc {α ρ : Type} (prR : Sym → Json → String) (ok : String → Bool) (D : Doc (Mx α ρ)) : Doc (Mx α ρ)
```

**Print the path blocks of a skeleton**: each section's under its symbol table (a
component's, or the document's for the top-level blocks).

</div>

<div class="lean-decl" id="Esm.Document.Source.cookDocBlocks">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.cookDocBlocks" title="Esm.Document.Source.cookDocBlocks"><code>cookDocBlocks</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Items.lean#L577-L581">source</a></div>

```lean
def cookDocBlocks {α ρ : Type} (ckR : Sym → String → Option Json) (D : Doc (Mx α ρ)) :
    Option (Doc (Mx α ρ))
```

**Read the path blocks of a skeleton**: every math leaf of a section's blocks under the
section's symbol table.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.stepKey_table">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.stepKey_table" title="Esm.Document.Source.stepKey_table"><code>stepKey_table</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Items.lean#L585-L591">source</a></div>

```lean
theorem stepKey_table :
    (stepKey (some "index_sets") Notation.topExprPaths).contains [] = false ∧
    stepKey (some "expression_templates") Notation.topExprPaths = [] ∧
    (stepKey (some "variables") Notation.compExprPaths).contains [] = false ∧
    (stepKey (some "species") Notation.compExprPaths).contains [] = false ∧
    (stepKey (some "parameters") Notation.compExprPaths).contains [] = false
```

No expression path ends at a block, and none starts at the blocks the symbol tables
read (`index_sets`, `variables`, `species`, `parameters`, `expression_templates`).

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.topSym_mathifyDoc">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.topSym_mathifyDoc" title="Esm.Document.Source.topSym_mathifyDoc"><code>topSym_mathifyDoc</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Items.lean#L594-L597">source</a></div>

```lean
theorem topSym_mathifyDoc {α ρ : Type} (prR : Sym → Json → String) (ok : String → Bool) (D : Doc (Mx α ρ)) :
    topSym (mathifyDoc prR ok D) = topSym D
```

The document's table is the same after printing its blocks.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.symFor_mathifyDoc">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.symFor_mathifyDoc" title="Esm.Document.Source.symFor_mathifyDoc"><code>symFor_mathifyDoc</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Items.lean#L600-L607">source</a></div>

```lean
theorem symFor_mathifyDoc {α ρ : Type} (prR : Sym → Json → String) (ok : String → Bool) (D : Doc (Mx α ρ))
    (c : Comp (Mx α ρ)) :
    symFor (mathifyDoc prR ok D) { c with blocks := mathify prR ok (symFor D c) Notation.compExprPaths c.blocks } =
      symFor D c
```

A component's table is the same after printing the blocks.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.cookDocBlocks_mathifyDoc">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.cookDocBlocks_mathifyDoc" title="Esm.Document.Source.cookDocBlocks_mathifyDoc"><code>cookDocBlocks_mathifyDoc</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Items.lean#L611-L632">source</a></div>

```lean
theorem cookDocBlocks_mathifyDoc {α ρ : Type} (prR : Sym → Json → String) (ok : String → Bool)
    (ckR : Sym → String → Option Json) (hck : ∀ S e, isE e = true → ckR S (prR S e) = some e)
    (D : Doc (Mx α ρ)) (hb : ∀ kv ∈ D.blocks, kv.2.WF)
    (hc : ∀ c ∈ D.comps, ∀ kv ∈ c.blocks, kv.2.WF) :
    cookDocBlocks ckR (mathifyDoc prR ok D) = some D
```

**The path blocks of a skeleton read back** when every expression does under its
table (the math round trips `parseLatex_printLatex`, `parseTypst_printTypst`).

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.items_mathifyDoc_ok">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.items_mathifyDoc_ok" title="Esm.Document.Source.items_mathifyDoc_ok"><code>items_mathifyDoc_ok</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Items.lean#L637-L659">source</a></div>

```lean
theorem items_mathifyDoc_ok (ok : RItem → Bool) (hblk : ∀ k v, ok (.block k v) = v.wfmb)
    (prR : Sym → Json → String) (mok : String → Bool) (X : Doc MR) (hX : ∀ it ∈ items X, ok it = true)
    (hb : ∀ kv ∈ X.blocks, kv.2.WF) (hc : ∀ c ∈ X.comps, ∀ kv ∈ c.blocks, kv.2.WF) :
    ∀ it ∈ items (mathifyDoc prR mok X), ok it = true
```

**The printed constructs stay readable**: printing the blocks only changes block
values, each into one well formed with math leaves. `ok` is a container's `itemOK`, whose
test of a block is [`Json.wfmb`](/generated/document-formats/esm-document-json#Esm.Document.Json.wfmb).

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.mem_mathify_key">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.mem_mathify_key" title="Esm.Document.Source.mem_mathify_key"><code>mem_mathify_key</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Items.lean#L665-L669">source</a></div>

```lean
theorem mem_mathify_key {prR : Sym → Json → String} {ok : String → Bool} {S : Sym} {ps : List (List Notation.Seg)}
    {bs : List (String × Json)} {kv : String × Json} (h : kv ∈ mathify prR ok S ps bs) :
    ∃ kv0 ∈ bs, kv0.1 = kv.1
```

Printing the blocks keeps every key.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.itemsOK_mathifyDoc">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.itemsOK_mathifyDoc" title="Esm.Document.Source.itemsOK_mathifyDoc"><code>itemsOK_mathifyDoc</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Items.lean#L672-L679">source</a></div>

```lean
theorem itemsOK_mathifyDoc (prR : Sym → Json → String) (ok : String → Bool) (X : Doc MR) (h : itemsOK X) :
    itemsOK (mathifyDoc prR ok X)
```

The skeleton with printed blocks satisfies [`itemsOK`](#Esm.Document.Source.itemsOK) when the skeleton does.

</div>

## Math entries: printed under the symbol table, and read back

<div class="lean-decl" id="Esm.Document.Source.rawDoc">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.rawDoc" title="Esm.Document.Source.rawDoc"><code>rawDoc</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Items.lean#L685-L687">source</a></div>

```lean
def rawDoc (pr : Sym → MC → MR) (D : Doc MC) : Doc MR
```

Print every math entry under its symbol table: a top-level template under the
document's, a component's entry under the component's.

</div>

<div class="lean-decl" id="Esm.Document.Source.cookComp">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.cookComp" title="Esm.Document.Source.cookComp"><code>cookComp</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Items.lean#L691-L692">source</a></div>

```lean
def cookComp (ck : Sym → MR → Option (List MC)) (D : Doc MR) (c : Comp MR) : Option (Comp MC)
```

Read a component's math entries under its symbol table; one math text may hold
several equations (the multi-line variants).

</div>

<div class="lean-decl" id="Esm.Document.Source.cookDoc">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.cookDoc" title="Esm.Document.Source.cookDoc"><code>cookDoc</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Items.lean#L695-L698">source</a></div>

```lean
def cookDoc (ck : Sym → MR → Option (List MC)) (D : Doc MR) : Option (Doc MC)
```

Read every math entry of a skeleton.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.topSym_rawDoc">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.topSym_rawDoc" title="Esm.Document.Source.topSym_rawDoc"><code>topSym_rawDoc</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Items.lean#L722-L724">source</a></div>

```lean
theorem topSym_rawDoc (pr : Sym → MC → MR) (hpr : ∀ S, HeadsKept (pr S)) (D : Doc MC) :
    topSym (rawDoc pr D) = topSym D
```

The tables of a printed skeleton are those of the skeleton: the printer keeps every
header.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.cookDoc_rawDoc">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.cookDoc_rawDoc" title="Esm.Document.Source.cookDoc_rawDoc"><code>cookDoc_rawDoc</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Items.lean#L734-L774">source</a></div>

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
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.prMx" title="Esm.Document.Source.prMx"><code>prMx</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Items.lean#L779-L783">source</a></div>

```lean
def prMx (prE : Sym → Eqn → String) (prR : Sym → Json → String) (S : Sym) : MC → MR
```

Print a math entry with the container's equation printer and expression printer.

</div>

<div class="lean-decl" id="Esm.Document.Source.ckMx">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.ckMx" title="Esm.Document.Source.ckMx"><code>ckMx</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Items.lean#L793-L804">source</a></div>

```lean
def ckMx (ckE : Sym → String → Option (List Eqn)) (ckR : Sym → String → Option Json) (S : Sym) :
    MR → Option (List MC)
```

Read a math entry with the container's equation reader and expression reader.

</div>

<p class="lean-meta">This module also proves 25 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Items.lean">the source</a>.</p>
