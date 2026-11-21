---
title: "The document skeleton"
type: lean
lean_module: "Esm.Document.Source.Skeleton"
weight: 49
---

<p class="lean-meta">Lean module <code>Esm.Document.Source.Skeleton</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean"><code>formal/Esm/Document/Source/Skeleton.lean</code></a> at <code>1b8dd9b3a909</code><br>Imports <a href="/generated/document-formats/esm-document-source-keys"><code>Esm.Document.Source.Keys</code></a></p>

The document layer maps an ESM document (a JSON object in canonical form) to a
*skeleton*: the front matter, the description, the path blocks, and one section per
model or reaction system with its description, its declarations, its equations and
its own path blocks. Each container (Markdown, Typst) then spells the skeleton; this
module is container-independent except for [`Caps`](#Esm.Document.Source.Caps), the predicates saying which values
a container can spell natively.

The mapping is total. Every field without a surface of its own (and every field whose
value a container cannot spell natively) falls back to a block keyed by its JSON path
relative to the enclosing section (`Notation.Home.pathBlock`). So every canonical
document round-trips ([`ofDoc_toDoc`](/generated/document-formats/esm-document-source-skeletonrt#Esm.Document.Source.ofDoc_toDoc)), and a nicer surface for some field is a change to
this file, not to the containers.

Native surfaces (`Notation.skeleton`):

* the front matter: `esm` and the entries of `metadata` other than `description`;
* the description block: `metadata.description`, and a component's `description`;
* component directives: the entries of `models` and `reaction_systems`;
* declarations: a model's `variables` (`:var`, and `:param` for `type: "parameter"`), a
  reaction system's `species` (`:species`) and `parameters` (`:param`), and the entries
  of a component's `subsystems` that are included by reference (`ref`), as subsystem
  directives (an inline subsystem stays in the `subsystems` block);
* the list entries of a component: its `equations` (display math, one equation each),
  its `initialization_equations` and `constraint_equations` (display math marked as
  such), its `reactions` (one reaction line each), and its `analyses` (a plot directive
  each, for an analysis with exactly one plot), and the entries of its
  `expression_templates` (a template display or a rule each, [`Tm`](#Esm.Document.Source.Tm)). Each of these six
  fields is native when every one of its entries is, and otherwise one path block;
* the top-level `expression_templates` of a library file, the same way (`Doc.math`).

Everything else is a path block.

The math entries are printed under the component's symbol table ([`symFor`](#Esm.Document.Source.symFor)), which is
computed from the rest of the skeleton and the template headers only (never a template's
math), so the parser can build the same table before it reads any math
(`symFor_rawDoc`); the top-level templates are printed under the document's ([`topSym`](#Esm.Document.Source.topSym)).

## The canonical form of a document

<div class="lean-decl" id="Esm.Document.Source.sortedDeep">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.sortedDeep" title="Esm.Document.Source.sortedDeep"><code>sortedDeep</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L52-L55">source</a></div>

```lean
def sortedDeep : Json → Bool
```

Every object, at every depth, has strictly increasing keys.

</div>

<div class="lean-decl" id="Esm.Document.Source.canonDoc">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.canonDoc" title="Esm.Document.Source.canonDoc"><code>canonDoc</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L68-L70">source</a></div>

```lean
def canonDoc : Json → Bool
```

A document in canonical form: a JSON object, well formed (canonical numbers,
distinct keys) with sorted keys at every depth.

</div>

<div class="lean-decl" id="Esm.Document.Source.canonVal">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.canonVal" title="Esm.Document.Source.canonVal"><code>canonVal</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L89">source</a></div>

```lean
def canonVal (v : Json) : Bool
```

A value that is canonical as a part of a document: well formed, sorted keys.

</div>

## The skeleton

<div class="lean-decl" id="Esm.Document.Source.Kind">
<div class="lean-decl-head"><span class="lean-kind">inductive</span> <a class="lean-name" href="#Esm.Document.Source.Kind" title="Esm.Document.Source.Kind"><code>Kind</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L118-L121">source</a></div>

```lean
inductive Kind where
  | model
  | rs
  deriving DecidableEq, Repr
```

The two kinds of component, each with its own directive.

</div>

<div class="lean-decl" id="Esm.Document.Source.DKind">
<div class="lean-decl-head"><span class="lean-kind">inductive</span> <a class="lean-name" href="#Esm.Document.Source.DKind" title="Esm.Document.Source.DKind"><code>DKind</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L125-L130">source</a></div>

```lean
inductive DKind where
  | var
  | param
  | species
  | sub
  deriving DecidableEq, Repr
```

The declaration directives. `sub` is a subsystem included by reference, printed as a
directive of its own line.

</div>

<div class="lean-decl" id="Esm.Document.Source.Decl">
<div class="lean-decl-head"><span class="lean-kind">structure</span> <a class="lean-name" href="#Esm.Document.Source.Decl" title="Esm.Document.Source.Decl"><code>Decl</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L134-L137">source</a></div>

```lean
structure Decl where
  kind : DKind
  name : String
  attrs : List (String × Json)
```

A declaration: the directive, the declared name, and the other fields of the
declared object as attributes.

</div>

<div class="lean-decl" id="Esm.Document.Source.Eqn">
<div class="lean-decl-head"><span class="lean-kind">structure</span> <a class="lean-name" href="#Esm.Document.Source.Eqn" title="Esm.Document.Source.Eqn"><code>Eqn</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L140-L143">source</a></div>

```lean
structure Eqn where
  comment : Option String
  lhs : Json
  rhs : Json
```

An equation: `lhs = rhs`, with its optional `_comment`.

</div>

<div class="lean-decl" id="Esm.Document.Source.Role">
<div class="lean-decl-head"><span class="lean-kind">inductive</span> <a class="lean-name" href="#Esm.Document.Source.Role" title="Esm.Document.Source.Role"><code>Role</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L146-L150">source</a></div>

```lean
inductive Role where
  | eqn
  | init
  | cons
  deriving DecidableEq, Repr
```

The field an equation belongs to.

</div>

<div class="lean-decl" id="Esm.Document.Source.Term">
<div class="lean-decl-head"><span class="lean-kind">structure</span> <a class="lean-name" href="#Esm.Document.Source.Term" title="Esm.Document.Source.Term"><code>Term</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L158-L160">source</a></div>

```lean
structure Term where
  species : String
  coef : JNum
```

One term of a reaction side: a species and its stoichiometric coefficient.

</div>

<div class="lean-decl" id="Esm.Document.Source.Rxn">
<div class="lean-decl-head"><span class="lean-kind">structure</span> <a class="lean-name" href="#Esm.Document.Source.Rxn" title="Esm.Document.Source.Rxn"><code>Rxn</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L164-L169">source</a></div>

```lean
structure Rxn (ρ : Type) where
  id : String
  subs : Option (List Term)
  prods : Option (List Term)
  rate : ρ
  attrs : List (String × Json)
```

A reaction: its `id`, its sides (`none` for an empty side, JSON `null`), its rate
(`ρ`: the expression, or its math text), and its other fields.

</div>

<div class="lean-decl" id="Esm.Document.Source.Tm">
<div class="lean-decl-head"><span class="lean-kind">structure</span> <a class="lean-name" href="#Esm.Document.Source.Tm" title="Esm.Document.Source.Tm"><code>Tm</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L175-L180">source</a></div>

```lean
structure Tm (ρ : Type) where
  name : String
  params : List String
  lhs : Option ρ
  body : ρ
  attrs : List (String × Json)
```

An entry of `expression_templates`: a template (`lhs = none`, applied by name) or a
rewrite rule (`lhs = some m`, its `match`). Its name, its parameter list (a template's,
from its header; a rule's `params` stay among its attributes, `params` here is `[]`), its
body (`ρ`: the expression, or its math text), and its other fields.

</div>

<div class="lean-decl" id="Esm.Document.Source.Mx">
<div class="lean-decl-head"><span class="lean-kind">inductive</span> <a class="lean-name" href="#Esm.Document.Source.Mx" title="Esm.Document.Source.Mx"><code>Mx</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L185-L189">source</a></div>

```lean
inductive Mx (α ρ : Type) where
  | eq (r : Role) (e : α)
  | rxn (x : Rxn ρ)
  | plot (attrs : List (String × Json))
  | tm (t : Tm ρ)
```

A list entry of a component: an equation of one of the three equation fields (`α`:
the equation, or its math text), a reaction, an analysis with one plot (its fields,
with `plots` replaced by `plot`, the one plot), or an entry of `expression_templates`.

</div>

<div class="lean-decl" id="Esm.Document.Source.MC">
<div class="lean-decl-head"><span class="lean-kind">abbrev</span> <a class="lean-name" href="#Esm.Document.Source.MC" title="Esm.Document.Source.MC"><code>MC</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L192">source</a></div>

```lean
abbrev MC
```

A math entry as read.

</div>

<div class="lean-decl" id="Esm.Document.Source.MR">
<div class="lean-decl-head"><span class="lean-kind">abbrev</span> <a class="lean-name" href="#Esm.Document.Source.MR" title="Esm.Document.Source.MR"><code>MR</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L194">source</a></div>

```lean
abbrev MR
```

A math entry as the container's text.

</div>

<div class="lean-decl" id="Esm.Document.Source.Mx.field">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Mx.field" title="Esm.Document.Source.Mx.field"><code>Mx.field</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L197-L201">source</a></div>

```lean
def Mx.field {α ρ : Type} : Mx α ρ → String
```

The field a math entry belongs to.

</div>

<div class="lean-decl" id="Esm.Document.Source.Mx.key">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Mx.key" title="Esm.Document.Source.Mx.key"><code>Mx.key</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L204-L206">source</a></div>

```lean
def Mx.key {α ρ : Type} : Mx α ρ → String
```

The key of an entry of an object-valued field (a template's name).

</div>

<div class="lean-decl" id="Esm.Document.Source.mathFields">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.mathFields" title="Esm.Document.Source.mathFields"><code>mathFields</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L210-L212">source</a></div>

```lean
def mathFields : List String
```

The fields with entries of their own, in key order. `expression_templates` is an
object (its entries keyed by name); the others are lists.

</div>

<div class="lean-decl" id="Esm.Document.Source.Comp">
<div class="lean-decl-head"><span class="lean-kind">structure</span> <a class="lean-name" href="#Esm.Document.Source.Comp" title="Esm.Document.Source.Comp"><code>Comp</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L217-L224">source</a></div>

```lean
structure Comp (α : Type) where
  kind : Kind
  name : String
  desc : Option String
  decls : List Decl
  math : List α
  mathBlocks : List (String × Json)
  blocks : List (String × Json)
```

One component section. `α` is how a math entry is held: [`MC`](#Esm.Document.Source.MC) in the semantic
skeleton, [`MR`](#Esm.Document.Source.MR) (the container's math text) in the raw one. `mathBlocks` holds the math
fields that are not printed natively.

</div>

<div class="lean-decl" id="Esm.Document.Source.Doc">
<div class="lean-decl-head"><span class="lean-kind">structure</span> <a class="lean-name" href="#Esm.Document.Source.Doc" title="Esm.Document.Source.Doc"><code>Doc</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L229-L234">source</a></div>

```lean
structure Doc (α : Type) where
  front : List (String × Json)
  desc : Option String
  blocks : List (String × Json)
  math : List α
  comps : List (Comp α)
```

A document skeleton: the front matter entries, the document description, the
top-level path blocks, the top-level templates (`expression_templates` of a library
file), and the component sections in order.

</div>

<div class="lean-decl" id="Esm.Document.Source.Comp.mapMath">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Comp.mapMath" title="Esm.Document.Source.Comp.mapMath"><code>Comp.mapMath</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L237-L238">source</a></div>

```lean
def Comp.mapMath {α β : Type} (f : Comp α → α → β) (c : Comp α) : Comp β
```

Change how math entries are held.

</div>

## The symbol table of a component

<div class="lean-decl" id="Esm.Document.Source.keysOf">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.keysOf" title="Esm.Document.Source.keysOf"><code>keysOf</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L243-L245">source</a></div>

```lean
def keysOf : Option Json → List String
```

The keys of an object value.

</div>

<div class="lean-decl" id="Esm.Document.Source.strsOf">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.strsOf" title="Esm.Document.Source.strsOf"><code>strsOf</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L248-L250">source</a></div>

```lean
def strsOf : Option Json → List String
```

The string entries of an array value.

</div>

<div class="lean-decl" id="Esm.Document.Source.templatesOf">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.templatesOf" title="Esm.Document.Source.templatesOf"><code>templatesOf</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L253-L257">source</a></div>

```lean
def templatesOf : Option Json → List (String × List String)
```

The parameter list of every template of an `expression_templates` value.

</div>

<div class="lean-decl" id="Esm.Document.Source.Tm.ps">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Tm.ps" title="Esm.Document.Source.Tm.ps"><code>Tm.ps</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L261-L264">source</a></div>

```lean
def Tm.ps {ρ : Type} (t : Tm ρ) : List String
```

The parameter list a template or rule brings into its body's scope: a template's
header parameters; a rule's `params` attribute.

</div>

<div class="lean-decl" id="Esm.Document.Source.Mx.head">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Mx.head" title="Esm.Document.Source.Mx.head"><code>Mx.head</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L267-L269">source</a></div>

```lean
def Mx.head {α ρ : Type} : Mx α ρ → Option (String × List String)
```

The symbol-table entry of a template or rule: its name and parameters.

</div>

<div class="lean-decl" id="Esm.Document.Source.Tm.scope">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Tm.scope" title="Esm.Document.Source.Tm.scope"><code>Tm.scope</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L273">source</a></div>

```lean
def Tm.scope {ρ : Type} (S : Sym) (t : Tm ρ) : Sym
```

The symbol table a template's body is read under: the table around it, with the
template's parameters declared.

</div>

<div class="lean-decl" id="Esm.Document.Source.Tm.mscope">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Tm.mscope" title="Esm.Document.Source.Tm.mscope"><code>Tm.mscope</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L279">source</a></div>

```lean
def Tm.mscope {ρ : Type} (S : Sym) (t : Tm ρ) : Sym
```

The symbol table a rule's `match` pattern is read under: its body's, with no templates.
A pattern never applies a template (spec §9.7.3: `match` patterns MUST NOT contain
`apply_expression_template` nodes), so an operator in it named like a template in scope
(a rule is in scope under its own name) reads as that operator, in the call form.

</div>

<div class="lean-decl" id="Esm.Document.Source.rootTs">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.rootTs" title="Esm.Document.Source.rootTs"><code>rootTs</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L283-L285">source</a></div>

```lean
def rootTs {α ρ : Type} (root : List (String × Json)) (rm : List (Mx α ρ)) :
    List (String × List String)
```

The templates of the document: those of the top-level block, then the top-level
template entries.

</div>

<div class="lean-decl" id="Esm.Document.Source.compTs">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.compTs" title="Esm.Document.Source.compTs"><code>compTs</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L288-L289">source</a></div>

```lean
def compTs {α ρ : Type} (c : Comp (Mx α ρ)) : List (String × List String)
```

The templates of a component: those of its block, then its template entries.

</div>

<div class="lean-decl" id="Esm.Document.Source.symWith">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.symWith" title="Esm.Document.Source.symWith"><code>symWith</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L294-L300">source</a></div>

```lean
def symWith {α : Type} (root : List (String × Json)) (rt : List (String × List String))
    (c : Comp α) (ct : List (String × List String)) : Sym
```

A component's symbol table, given the document's templates `rt` and the component's
own `ct`: the names it declares (its declarations and the entries of its declaration
fields printed as blocks) and the document's index sets.

</div>

<div class="lean-decl" id="Esm.Document.Source.symFor">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.symFor" title="Esm.Document.Source.symFor"><code>symFor</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L307-L308">source</a></div>

```lean
def symFor {α ρ : Type} (D : Doc (Mx α ρ)) (c : Comp (Mx α ρ)) : Sym
```

**The symbol table of a component** (Phase 2 `Sym`): its declared names and the
document's index sets; the templates of the document and of the component. It reads the
top-level blocks, the component's declarations and blocks, and the headers of the template
entries (name and parameters, never the math of a body), so the parser builds it before
reading any math.

</div>

<div class="lean-decl" id="Esm.Document.Source.topSym">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.topSym" title="Esm.Document.Source.topSym"><code>topSym</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L312-L313">source</a></div>

```lean
def topSym {α ρ : Type} (D : Doc (Mx α ρ)) : Sym
```

The symbol table of the top-level templates: the document's index sets and
templates.

</div>

<div class="lean-decl" id="Esm.Document.Source.HeadsKept">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.HeadsKept" title="Esm.Document.Source.HeadsKept"><code>HeadsKept</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L316">source</a></div>

```lean
def HeadsKept {α ρ β σ : Type} (f : Mx α ρ → Mx β σ) : Prop
```

A map of entries that keeps every header.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.symWith_mapMath">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.symWith_mapMath" title="Esm.Document.Source.symWith_mapMath"><code>symWith_mapMath</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L327-L328">source</a></div>

```lean
theorem symWith_mapMath {α β : Type} (root : List (String × Json)) (rt) (f : Comp α → α → β)
    (c : Comp α) (ct) : symWith root rt (c.mapMath f) ct = symWith root rt c ct
```

The printer and the parser derive the same table: it does not depend on how the
math entries are held (a map that keeps headers), nor on the math fallbacks of other
fields.

</div>

## What a container can spell natively

<div class="lean-decl" id="Esm.Document.Source.Caps">
<div class="lean-decl-head"><span class="lean-kind">structure</span> <a class="lean-name" href="#Esm.Document.Source.Caps" title="Esm.Document.Source.Caps"><code>Caps</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L338-L356">source</a></div>

```lean
structure Caps where
  /-- A front-matter key (Typst: a named argument, so an identifier). -/
  frontKey : String → Bool
  /-- A description text. -/
  desc : String → Bool
  /-- A component name in its directive. -/
  compName : String → Bool
  /-- A declared name (printed as math). -/
  declName : String → Bool
  /-- A declaration attribute. -/
  attr : String × Json → Bool
  /-- An equation under the component's symbol table. -/
  eqn : Sym → Eqn → Bool
  /-- A reaction under the component's symbol table. -/
  rxn : Sym → Rxn Json → Bool
  /-- The fields of a plot directive. -/
  plot : List (String × Json) → Bool
  /-- A template or rule, under its body's symbol table (`Tm.scope`). -/
  tm : Sym → Tm Json → Bool
```

The container-specific predicates. A value failing one of them falls back to a
path block (or, for an equation, the whole `equations` field does).

</div>

<div class="lean-decl" id="Esm.Document.Source.Caps.item">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Caps.item" title="Esm.Document.Source.Caps.item"><code>Caps.item</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L359-L363">source</a></div>

```lean
def Caps.item (caps : Caps) (S : Sym) : MC → Bool
```

A list entry the container spells.

</div>

## Equations

<div class="lean-decl" id="Esm.Document.Source.eqnJson">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.eqnJson" title="Esm.Document.Source.eqnJson"><code>eqnJson</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L368-L371">source</a></div>

```lean
def eqnJson (e : Eqn) : Json
```

The JSON value of an equation.

</div>

<div class="lean-decl" id="Esm.Document.Source.eqnOf">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.eqnOf" title="Esm.Document.Source.eqnOf"><code>eqnOf</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L375-L379">source</a></div>

```lean
def eqnOf : Json → Option Eqn
```

The equation a JSON value is, when it has exactly the keys `lhs`, `rhs` and
optionally a string `_comment`, and both sides are well-formed expressions.

</div>

## Reactions

<div class="lean-decl" id="Esm.Document.Source.sideJson">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.sideJson" title="Esm.Document.Source.sideJson"><code>sideJson</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L401-L403">source</a></div>

```lean
def sideJson : Option (List Term) → Json
```

A reaction side: JSON `null` for an empty side, else a non-empty array.

</div>

<div class="lean-decl" id="Esm.Document.Source.rxnKeys">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.rxnKeys" title="Esm.Document.Source.rxnKeys"><code>rxnKeys</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L412">source</a></div>

```lean
def rxnKeys : List String
```

The keys of a reaction with a surface of their own; every other key is an
attribute.

</div>

<div class="lean-decl" id="Esm.Document.Source.rxnOf">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.rxnOf" title="Esm.Document.Source.rxnOf"><code>rxnOf</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L420-L429">source</a></div>

```lean
def rxnOf (v : Json) : Option (Rxn Json)
```

The reaction a JSON value is, checked by printing it back: its `id` is a string, both
sides are present, and the rate is an expression.

</div>

## Plots

<div class="lean-decl" id="Esm.Document.Source.plotJson">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.plotJson" title="Esm.Document.Source.plotJson"><code>plotJson</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L447-L448">source</a></div>

```lean
def plotJson (attrs : List (String × Json)) : Json
```

The analysis a plot directive stands for: its fields, with `plot` back as the
one-element `plots`.

</div>

<div class="lean-decl" id="Esm.Document.Source.plotOf">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.plotOf" title="Esm.Document.Source.plotOf"><code>plotOf</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L452-L460">source</a></div>

```lean
def plotOf (v : Json) : Option (List (String × Json))
```

The plot directive an analysis is, when it has exactly one plot and no `plot` field,
checked by printing it back.

</div>

## Templates and rules

<div class="lean-decl" id="Esm.Document.Source.tmKeys">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.tmKeys" title="Esm.Document.Source.tmKeys"><code>tmKeys</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L476-L479">source</a></div>

```lean
def tmKeys (t : Tm Json) : List String
```

The keys of a template or rule with a surface of their own.

</div>

<div class="lean-decl" id="Esm.Document.Source.strList">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.strList" title="Esm.Document.Source.strList"><code>strList</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L487-L490">source</a></div>

```lean
def strList : List Json → Option (List String)
```

The string entries of a list, when every entry is a string.

</div>

<div class="lean-decl" id="Esm.Document.Source.tmOf">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.tmOf" title="Esm.Document.Source.tmOf"><code>tmOf</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L495-L509">source</a></div>

```lean
def tmOf (n : String) (v : Json) : Option (Tm Json)
```

The template (no `match`, `params` a list of strings) or the rule (a `match`) an entry
of `expression_templates` is, checked by printing it back; the body and the match are
expressions.

</div>

<div class="lean-decl" id="Esm.Document.Source.tmWF">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.tmWF" title="Esm.Document.Source.tmWF"><code>tmWF</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L512">source</a></div>

```lean
def tmWF (t : Tm Json) : Bool
```

Well-formed expressions in a template or rule.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.tmOf_some">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.tmOf_some" title="Esm.Document.Source.tmOf_some"><code>tmOf_some</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L542-L567">source</a></div>

```lean
theorem tmOf_some {n : String} {v : Json} {t : Tm Json} (h : tmOf n v = some t) :
    tmJson t = v ∧ t.name = n ∧ tmWF t = true ∧
      ∃ kvs, v = .obj kvs ∧ t.ps = strsOf (look "params" kvs)
```

A template or rule decoded from an entry stands for the entry, and its header is the
entry's symbol-table entry ([`templatesOf`](#Esm.Document.Source.templatesOf)).

</div>

## List entries

<div class="lean-decl" id="Esm.Document.Source.itemJson">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.itemJson" title="Esm.Document.Source.itemJson"><code>itemJson</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L572-L576">source</a></div>

```lean
def itemJson : MC → Json
```

The JSON value of a list entry.

</div>

<div class="lean-decl" id="Esm.Document.Source.fieldJson">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.fieldJson" title="Esm.Document.Source.fieldJson"><code>fieldJson</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L580-L582">source</a></div>

```lean
def fieldJson (f : String) (ms : List MC) : Json
```

The value of a field from its entries: an object keyed by the entries' names for
`expression_templates`, a list otherwise.

</div>

<div class="lean-decl" id="Esm.Document.Source.roleOf">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.roleOf" title="Esm.Document.Source.roleOf"><code>roleOf</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L585">source</a></div>

```lean
def roleOf (f : String) : Option Role
```

The role of an equation field.

</div>

<div class="lean-decl" id="Esm.Document.Source.itemOf">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.itemOf" title="Esm.Document.Source.itemOf"><code>itemOf</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L588-L591">source</a></div>

```lean
def itemOf (f : String) (v : Json) : Option MC
```

The math entry an entry of the math field `f` is.

</div>

<div class="lean-decl" id="Esm.Document.Source.mathWF">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.mathWF" title="Esm.Document.Source.mathWF"><code>mathWF</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L594-L598">source</a></div>

```lean
def mathWF : MC → Bool
```

Well-formed expressions throughout.

</div>

<div class="lean-decl" id="Esm.Document.Source.tmItem">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.tmItem" title="Esm.Document.Source.tmItem"><code>tmItem</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L638">source</a></div>

```lean
def tmItem (kv : String × Json) : Option MC
```

The template entry an entry `(name, value)` of `expression_templates` is.

</div>

<div class="lean-decl" id="Esm.Document.Source.mathOf">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.mathOf" title="Esm.Document.Source.mathOf"><code>mathOf</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L641-L653">source</a></div>

```lean
def mathOf (caps : Caps) (S : Sym) (f : String) : Json → Option (List MC)
```

The entries of a math field, when all of them print natively.

</div>

## From a document to its skeleton

<div class="lean-decl" id="Esm.Document.Source.descOf">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.descOf" title="Esm.Document.Source.descOf"><code>descOf</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L745-L747">source</a></div>

```lean
def descOf (caps : Caps) : Option Json → Option String
```

A description that prints natively.

</div>

<div class="lean-decl" id="Esm.Document.Source.metaOf">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.metaOf" title="Esm.Document.Source.metaOf"><code>metaOf</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L752-L758">source</a></div>

```lean
def metaOf (caps : Caps) : Option Json → Option (List (String × Json) × Option String)
```

`metadata` printed in the front matter: a non-empty object without an `esm` key
whose keys the container can spell there. Returns the front-matter entries and the
description.

</div>

<div class="lean-decl" id="Esm.Document.Source.pickVar">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.pickVar" title="Esm.Document.Source.pickVar"><code>pickVar</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L763-L776">source</a></div>

```lean
def pickVar (caps : Caps) (n : String) (v : Json) : Option Decl
```

A model variable as a declaration: `:param` for `type: "parameter"`, `:var`
otherwise; the `type` attribute is left out when it is `"unknown"` (the meaning of
`:var`) or `"parameter"`. A variable without `type` stays in the block.

</div>

<div class="lean-decl" id="Esm.Document.Source.pickPlain">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.pickPlain" title="Esm.Document.Source.pickPlain"><code>pickPlain</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L779-L783">source</a></div>

```lean
def pickPlain (caps : Caps) (k : DKind) (n : String) (v : Json) : Option Decl
```

A reaction-system species or parameter as a declaration of kind `k`.

</div>

<div class="lean-decl" id="Esm.Document.Source.pickSub">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.pickSub" title="Esm.Document.Source.pickSub"><code>pickSub</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L786-L789">source</a></div>

```lean
def pickSub (caps : Caps) (n : String) (v : Json) : Option Decl
```

A subsystem included by reference (it has a `ref`) as a declaration.

</div>

<div class="lean-decl" id="Esm.Document.Source.declFields">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.declFields" title="Esm.Document.Source.declFields"><code>declFields</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L792-L795">source</a></div>

```lean
def declFields (caps : Caps) : Kind → List (String × (String → Json → Option Decl))
```

The declaration fields of a component kind, with their pickers.

</div>

<div class="lean-decl" id="Esm.Document.Source.declField">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.declField" title="Esm.Document.Source.declField"><code>declField</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L798-L805">source</a></div>

```lean
def declField : Kind → DKind → Option String
```

The field a declaration of kind `k` belongs to, in a component of kind `K`.

</div>

<div class="lean-decl" id="Esm.Document.Source.backDecl">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.backDecl" title="Esm.Document.Source.backDecl"><code>backDecl</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L808-L819">source</a></div>

```lean
def backDecl (K : Kind) (d : Decl) : Option (String × Json)
```

The entry a declaration stands for, in a component of kind `K`.

</div>

<div class="lean-decl" id="Esm.Document.Source.compBlock">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.compBlock" title="Esm.Document.Source.compBlock"><code>compBlock</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L824-L830">source</a></div>

```lean
def compBlock (caps : Caps) (K : Kind) (desc : Option String) (kv : String × Json) :
    Option (String × Json)
```

Where an entry of a component goes when it is not a native surface: the
description when it does not print natively, every entry without a surface of its own,
and the residue of each declaration field; the math fields are decided later.

</div>

<div class="lean-decl" id="Esm.Document.Source.compBase">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.compBase" title="Esm.Document.Source.compBase"><code>compBase</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L834-L839">source</a></div>

```lean
def compBase (caps : Caps) (K : Kind) (name : String) (kvs : List (String × Json)) : Comp MC
```

A component, before its equations are decided: its description, its declarations,
and its blocks.

</div>

<div class="lean-decl" id="Esm.Document.Source.mathPart">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.mathPart" title="Esm.Document.Source.mathPart"><code>mathPart</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L843-L850">source</a></div>

```lean
def mathPart (caps : Caps) (S : Sym) (kvs : List (String × Json)) (f : String) :
    List MC × Option (String × Json)
```

One math field of a component: its entries when every one prints natively under the
symbol table `S`, else its block.

</div>

<div class="lean-decl" id="Esm.Document.Source.compSym">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.compSym" title="Esm.Document.Source.compSym"><code>compSym</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L855-L857">source</a></div>

```lean
def compSym (root : List (String × Json)) (rt : List (String × List String)) (K : Kind)
    (caps : Caps) (name : String) (kvs : List (String × Json)) : Sym
```

The symbol table of a component's entries, from the document's templates `rt`: the
component's own templates are read from its `expression_templates` value, which is what
the finished section's table reads from its template entries or its block ([`compTs_compOf`](/generated/document-formats/esm-document-source-skeletonrt#Esm.Document.Source.compTs_compOf)).

</div>

<div class="lean-decl" id="Esm.Document.Source.compOf">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.compOf" title="Esm.Document.Source.compOf"><code>compOf</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L861-L865">source</a></div>

```lean
def compOf (caps : Caps) (root : List (String × Json)) (rt : List (String × List String))
    (K : Kind) (name : String) (kvs : List (String × Json)) : Comp MC
```

A component: [`compBase`](#Esm.Document.Source.compBase), then its math fields, each native when every entry prints
natively under the component's symbol table, else a block.

</div>

<div class="lean-decl" id="Esm.Document.Source.pickComp">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.pickComp" title="Esm.Document.Source.pickComp"><code>pickComp</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L868-L871">source</a></div>

```lean
def pickComp (caps : Caps) (n : String) (v : Json) : Option (String × List (String × Json))
```

A component entry prints as a directive when its name does and it is an object.

</div>

<div class="lean-decl" id="Esm.Document.Source.topSymOf">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.topSymOf" title="Esm.Document.Source.topSymOf"><code>topSymOf</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L875-L876">source</a></div>

```lean
def topSymOf (kvs : List (String × Json)) : Sym
```

The symbol table of the top-level templates: the document's index sets and its
templates, read from the `expression_templates` value.

</div>

<div class="lean-decl" id="Esm.Document.Source.topMath">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.topMath" title="Esm.Document.Source.topMath"><code>topMath</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L879-L880">source</a></div>

```lean
def topMath (caps : Caps) (kvs : List (String × Json)) : Option (List MC)
```

The top-level templates, when every one prints natively.

</div>

<div class="lean-decl" id="Esm.Document.Source.rootBlock">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.rootBlock" title="Esm.Document.Source.rootBlock"><code>rootBlock</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L886-L892">source</a></div>

```lean
def rootBlock (caps : Caps) (tn : Bool) (kv : String × Json) : Option (String × Json)
```

Where a top-level entry goes when it is not a native surface: every entry without
a surface of its own, the residues of `models` and `reaction_systems`, `metadata`
when it is not in the front matter, and `expression_templates` when it is not native
(`tn`).

</div>

<div class="lean-decl" id="Esm.Document.Source.rootBlocks">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.rootBlocks" title="Esm.Document.Source.rootBlocks"><code>rootBlocks</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L895-L896">source</a></div>

```lean
def rootBlocks (caps : Caps) (tn : Bool) (kvs : List (String × Json)) : List (String × Json)
```

The top-level blocks.

</div>

<div class="lean-decl" id="Esm.Document.Source.toDoc">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.toDoc" title="Esm.Document.Source.toDoc"><code>toDoc</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L899-L912">source</a></div>

```lean
def toDoc (caps : Caps) : Json → Doc MC
```

**The skeleton of a document.**

</div>

## From a skeleton back to the document

<div class="lean-decl" id="Esm.Document.Source.optKv">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.optKv" title="Esm.Document.Source.optKv"><code>optKv</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L917-L919">source</a></div>

```lean
def optKv (k : String) : Option Json → List (String × Json)
```

An optional entry as a list.

</div>

<div class="lean-decl" id="Esm.Document.Source.mathKv">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.mathKv" title="Esm.Document.Source.mathKv"><code>mathKv</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L922-L927">source</a></div>

```lean
def mathKv (c : Comp MC) (f : String) : Option (List (String × Json))
```

One rebuilt math field: its entries, or its block, or neither.

</div>

<div class="lean-decl" id="Esm.Document.Source.mathKvs">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.mathKvs" title="Esm.Document.Source.mathKvs"><code>mathKvs</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L930-L931">source</a></div>

```lean
def mathKvs (c : Comp MC) : Option (List (String × Json))
```

The rebuilt math fields.

</div>

<div class="lean-decl" id="Esm.Document.Source.declFieldNames">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.declFieldNames" title="Esm.Document.Source.declFieldNames"><code>declFieldNames</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L934-L936">source</a></div>

```lean
def declFieldNames : Kind → List String
```

The names of the declaration fields of a component kind.

</div>

<div class="lean-decl" id="Esm.Document.Source.declKv">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.declKv" title="Esm.Document.Source.declKv"><code>declKv</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L943-L946">source</a></div>

```lean
def declKv (K : Kind) (c : Comp MC) (f : String) : Option (List (String × Json))
```

One rebuilt declaration field: its declarations joined with its residue block.

</div>

<div class="lean-decl" id="Esm.Document.Source.declKvs">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.declKvs" title="Esm.Document.Source.declKvs"><code>declKvs</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L950-L953">source</a></div>

```lean
def declKvs (K : Kind) (c : Comp MC) : Option (List (String × Json))
```

The rebuilt declaration fields; a declaration of a kind the component does not
have (`:species` in a model) is refused.

</div>

<div class="lean-decl" id="Esm.Document.Source.ofComp">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.ofComp" title="Esm.Document.Source.ofComp"><code>ofComp</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L956-L960">source</a></div>

```lean
def ofComp (c : Comp MC) : Option Json
```

**A component rebuilt from its section.**

</div>

<div class="lean-decl" id="Esm.Document.Source.backComp">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.backComp" title="Esm.Document.Source.backComp"><code>backComp</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L963">source</a></div>

```lean
def backComp (c : Comp MC) : Option (String × Json)
```

A component back to its entry.

</div>

<div class="lean-decl" id="Esm.Document.Source.ofDoc">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.ofDoc" title="Esm.Document.Source.ofDoc"><code>ofDoc</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean#L967-L979">source</a></div>

```lean
def ofDoc (D : Doc MC) : Option Json
```

**A document rebuilt from its skeleton.** The result is checked to be canonical,
which rejects a field written twice (once natively and once in a block, say).

</div>

<p class="lean-meta">This module also proves 22 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Skeleton.lean">the source</a>.</p>
