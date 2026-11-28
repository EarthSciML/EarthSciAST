---
title: "The initialization_equations migration of the canonical form (esm-spec §11.4.4)"
type: lean
lean_module: "Esm.Document.Source.InitMigration"
weight: 62
---

<p class="lean-meta">Lean module <code>Esm.Document.Source.InitMigration</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/InitMigration.lean"><code>formal/Esm/Document/Source/InitMigration.lean</code></a> at <code>9c3b4aa7587e</code><br>Imports <a href="/generated/document-formats/esm-document-source-keys"><code>Esm.Document.Source.Keys</code></a></p>

`initialization_equations` is deprecated (esm 2.5.0). The canonical form, and so the
Markdown and Typst printers that print it, rewrite the field as a loader does
(esm-spec §11.4.4 and the `deprecated_field` row of §9.6.6), so a printed document never
carries it. For each model, top level or an inline subsystem at any depth (deepest first):

* first, an initial condition of a parameter (esm-spec §11.4.4 "An initial condition of a
  parameter") becomes the parameter's `default`: in a document declaring esm below 2.5.0,
  each `equations` entry whose left-hand side is exactly `ic(k)`, then each
  `initialization_equations` entry whose left-hand side is `k` or `ic(k)`, `k` declared in
  the model's own `variables` with `type` `"parameter"`, is removed and its right-hand side
  (a JSON number, else `ic_invalid_argument`) written as `k`'s `default`, in that order, a
  later one replacing an earlier value;

then, when the model holds `initialization_equations`, the field is removed and its
remaining equations go:

* a model with a time derivative (an equation of `equations` whose left-hand side holds an
  op `D` anywhere): each initialization equation, in the field's order, is appended to
  `equations` with its `lhs` and `rhs` rewritten by [`wrap`](#Esm.Document.Source.InitMigration.wrap): every reference to an unknown
  `w` becomes `ic(w)` and every time derivative `D(w)` of an unknown becomes `ic(D(w))`;
* a model with none: each `v ~ e` whose left-hand side is a bare name declared in the
  model's `variables` with `type` `"unknown"` becomes `guesses[v] = e` (in the field's order,
  an entry `guesses` already has, or an earlier equation gave, is kept); any other equation
  is refused (`deprecated_field`, an error).

A document with a refused equation (either refusal above, or an initial condition of a
parameter whose value is not a number) is left as it is ([`migrateOrKeep`](#Esm.Document.Source.InitMigration.migrateOrKeep)): the canonical form
of a document the loader rejects is the document unmigrated, and the printers then write
its initialization container, as every binding does.

Unproved executable code (the printers' round-trip theorems are about the canonical form
this produces), pinned by the document-format golden files and the cross-binding gate.

<div class="lean-decl" id="Esm.Document.Source.InitMigration.field">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.InitMigration.field" title="Esm.Document.Source.InitMigration.field"><code>field</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/InitMigration.lean#L47-L49">source</a></div>

```lean
def field (k : String) : Json → Option Json
```

Field `k` of an object.

</div>

<div class="lean-decl" id="Esm.Document.Source.InitMigration.isUnknownVar">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.InitMigration.isUnknownVar" title="Esm.Document.Source.InitMigration.isUnknownVar"><code>isUnknownVar</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/InitMigration.lean#L52-L55">source</a></div>

```lean
def isUnknownVar (m : Json) (v : String) : Bool
```

Whether model `m` declares `v` in its `variables` with `type` `"unknown"`.

</div>

<div class="lean-decl" id="Esm.Document.Source.InitMigration.descend">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.InitMigration.descend" title="Esm.Document.Source.InitMigration.descend"><code>descend</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/InitMigration.lean#L58-L60">source</a></div>

```lean
def descend (m : Json) : List String → Option Json
```

The inline subsystem of `m` at a path of subsystem names.

</div>

<div class="lean-decl" id="Esm.Document.Source.InitMigration.namesUnknown">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.InitMigration.namesUnknown" title="Esm.Document.Source.InitMigration.namesUnknown"><code>namesUnknown</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/InitMigration.lean#L68-L85">source</a></div>

```lean
def namesUnknown (root model : Json) (name : String) : Bool
```

Whether `name` names an unknown seen from `model`: a bare name declared in the model's
`variables` with `type` `"unknown"`; a scoped name `a.b.….v` (split at every `.`, the last
segment the variable) resolving to such a declaration first through the model's own
subsystems (`a`, then `b`, …), then from the top-level model `a` through its subsystems;
or, failing both, naming a species `v` of the top-level reaction system `a` (through its
subsystems). `root` is the document before migration.

</div>

<div class="lean-decl" id="Esm.Document.Source.InitMigration.containsD">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.InitMigration.containsD" title="Esm.Document.Source.InitMigration.containsD"><code>containsD</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/InitMigration.lean#L88-L94">source</a></div>

```lean
partial def containsD : Json → Bool
```

Whether an expression holds an op `D` node anywhere.

</div>

<div class="lean-decl" id="Esm.Document.Source.InitMigration.icOf">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.InitMigration.icOf" title="Esm.Document.Source.InitMigration.icOf"><code>icOf</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/InitMigration.lean#L97">source</a></div>

```lean
def icOf (a : Json) : Json
```

`ic(a)`, keys sorted.

</div>

<div class="lean-decl" id="Esm.Document.Source.InitMigration.exprKeys">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.InitMigration.exprKeys" title="Esm.Document.Source.InitMigration.exprKeys"><code>exprKeys</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/InitMigration.lean#L101">source</a></div>

```lean
def exprKeys : List String
```

The expression-valued fields of a node the rewrite descends into (besides `bindings`,
a name-keyed map of expressions).

</div>

<div class="lean-decl" id="Esm.Document.Source.InitMigration.wrap">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.InitMigration.wrap" title="Esm.Document.Source.InitMigration.wrap"><code>wrap</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/InitMigration.lean#L108-L130">source</a></div>

```lean
partial def wrap (isU : String → Bool) : Json → Json
```

`e` with every unknown reference `w` written `ic(w)` and every time derivative `D(w)`
(`wrt` absent, null or `"t"`, first argument an unknown name) written `ic(D(w))`. An `ic`
node is kept as it is. Other nodes are rebuilt with [`wrapIn`](#Esm.Document.Source.InitMigration.wrapIn) applied to the values of
[`exprKeys`](#Esm.Document.Source.InitMigration.exprKeys) and to every value of `bindings`; their other fields are kept.

</div>

<div class="lean-decl" id="Esm.Document.Source.InitMigration.wrapIn">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.InitMigration.wrapIn" title="Esm.Document.Source.InitMigration.wrapIn"><code>wrapIn</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/InitMigration.lean#L133-L135">source</a></div>

```lean
partial def wrapIn (isU : String → Bool) : Json → Json
```

[`wrap`](#Esm.Document.Source.InitMigration.wrap) through arrays, at any depth.

</div>

<div class="lean-decl" id="Esm.Document.Source.InitMigration.isParamVar">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.InitMigration.isParamVar" title="Esm.Document.Source.InitMigration.isParamVar"><code>isParamVar</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/InitMigration.lean#L139-L142">source</a></div>

```lean
def isParamVar (m : Json) (v : String) : Bool
```

Whether model `m` declares `v` in its `variables` with `type` `"parameter"`.

</div>

<div class="lean-decl" id="Esm.Document.Source.InitMigration.paramTarget">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.InitMigration.paramTarget" title="Esm.Document.Source.InitMigration.paramTarget"><code>paramTarget</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/InitMigration.lean#L147-L154">source</a></div>

```lean
def paramTarget (model : Json) (bare : Bool) (eq : Json) : Option String
```

The parameter of `model` an equation sets: its left-hand side is `ic(k)` (exactly: op
`ic`, `args` the one name `k`), or, when `bare`, the name `k`; `k` a parameter the model
declares.

</div>

<div class="lean-decl" id="Esm.Document.Source.InitMigration.below250">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.InitMigration.below250" title="Esm.Document.Source.InitMigration.below250"><code>below250</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/InitMigration.lean#L158-L164">source</a></div>

```lean
def below250 (doc : Json) : Bool
```

Whether the document declares an esm version below 2.5.0 (its `esm` string's first two
dot-separated parts read as natural numbers; any other `esm` is not below).

</div>

<div class="lean-decl" id="Esm.Document.Source.InitMigration.modelHas">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.InitMigration.modelHas" title="Esm.Document.Source.InitMigration.modelHas"><code>modelHas</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/InitMigration.lean#L169-L178">source</a></div>

```lean
partial def modelHas (legacy : Bool) : Json → Bool
```

Whether a model, or an inline subsystem of it at any depth, has something to migrate:
the field, or (`legacy`: the document is below esm 2.5.0) an `ic(k)` equation of a
parameter.

</div>

<div class="lean-decl" id="Esm.Document.Source.InitMigration.takeParamICs">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.InitMigration.takeParamICs" title="Esm.Document.Source.InitMigration.takeParamICs"><code>takeParamICs</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/InitMigration.lean#L183-L193">source</a></div>

```lean
def takeParamICs (model : Json) (ptr fld : String) (bare : Bool) :
    Nat → List Json → Except String (List Json × List (String × Json))
```

The equations of `es` that set a parameter ([`paramTarget`](#Esm.Document.Source.InitMigration.paramTarget)), taken out: the others, and
the `(k, value)` each sets, in order. A value that is not a number is refused. `fld`, `i`:
the list's field and the first equation's index, for the refusal.

</div>

<div class="lean-decl" id="Esm.Document.Source.InitMigration.setDefaults">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.InitMigration.setDefaults" title="Esm.Document.Source.InitMigration.setDefaults"><code>setDefaults</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/InitMigration.lean#L196-L206">source</a></div>

```lean
def setDefaults (kvs : List (String × Json)) (sets : List (String × Json)) :
    List (String × Json)
```

`kvs` (a model) with each parameter's `default` set to its value, in order.

</div>

<div class="lean-decl" id="Esm.Document.Source.InitMigration.refusal">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.InitMigration.refusal" title="Esm.Document.Source.InitMigration.refusal"><code>refusal</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/InitMigration.lean#L209-L212">source</a></div>

```lean
def refusal (ptr : String) (i : Nat) : String
```

The refusal of an initialization equation of a model with no time derivative.

</div>

<div class="lean-decl" id="Esm.Document.Source.InitMigration.toGuesses">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.InitMigration.toGuesses" title="Esm.Document.Source.InitMigration.toGuesses"><code>toGuesses</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/InitMigration.lean#L216-L224">source</a></div>

```lean
def toGuesses (model : Json) (ptr : String) :
    Nat → List (String × Json) → List Json → Except String (List (String × Json))
```

The `guesses` a model with no time derivative gets: `g` with `v ↦ e` added for each
`v ~ e`, in order, unless `v` is already there.

</div>

<div class="lean-decl" id="Esm.Document.Source.InitMigration.migrateModel">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.InitMigration.migrateModel" title="Esm.Document.Source.InitMigration.migrateModel"><code>migrateModel</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/InitMigration.lean#L228-L277">source</a></div>

```lean
partial def migrateModel (root : Json) (legacy : Bool) (ptr : String) :
    Json → Except String Json
```

One model migrated (its subsystems first). `root`: the document before migration;
`ptr`: the model's JSON pointer, for the refusal.

</div>

<div class="lean-decl" id="Esm.Document.Source.InitMigration.migrate">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.InitMigration.migrate" title="Esm.Document.Source.InitMigration.migrate"><code>migrate</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/InitMigration.lean#L280-L292">source</a></div>

```lean
def migrate (doc : Json) : Except String Json
```

Every model migrated, or the refusal of the first equation that has no reading. A document without the field is returned as it is.

</div>

<div class="lean-decl" id="Esm.Document.Source.InitMigration.migrateOrKeep">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.InitMigration.migrateOrKeep" title="Esm.Document.Source.InitMigration.migrateOrKeep"><code>migrateOrKeep</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/InitMigration.lean#L296-L299">source</a></div>

```lean
def migrateOrKeep (doc : Json) : Json
```

The canonical form's migration: [`migrate`](#Esm.Document.Source.InitMigration.migrate), or the document unmigrated when the loader
would refuse it.

</div>
