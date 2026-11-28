---
title: "Expressions as JSON values, and the symbol table"
type: lean
lean_module: "Esm.Document.Math.Expr"
weight: 11
---

<p class="lean-meta">Lean module <code>Esm.Document.Math.Expr</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Expr.lean"><code>formal/Esm/Document/Math/Expr.lean</code></a> at <code>ffd5aee2f868</code><br>Imports <a href="/generated/document-formats/esm-document-number"><code>Esm.Document.Number</code></a>, <a href="/generated/document-formats/esm-units-typeset"><code>Esm.Units.Typeset</code></a></p>

The math grammars are stated over the JSON value at an expression position
(spec §4.1), not over `Esm.Ast`, which drops fields. An expression is

* a number (`Json.num`), in the canonical form of CONFORMANCE §5.5.3.1;
* a name (`Json.str`): dot-separated identifier segments (§4.6 scoped references);
* a node (`Json.obj`): `op`, `args` and any other fields.

[`isE`](#Esm.Document.Math.isE) is the well-formedness check. It asks for the canonical form only where the
round trip needs it: object keys strictly increasing (the sorted-key canonical
serialization), canonical numbers, every `args` entry an expression, and an `op` that
is neither removed (§4.2 "Removed ops") nor deprecated (`neg`, `pow`: the printer
never writes them). Every other field may hold any well-formed JSON value. The
redundant spellings of `Notation.spellingRules` (an explicit `reduce: "+"`, a
unitless scalar `const`, a `D` without `wrt`) are NOT excluded: they print in the
generic escape form and round-trip exactly, so the theorem covers them too.

The symbol table [`Sym`](#Esm.Document.Math.Sym) is what a document declares: the declared names and the
parameter lists of the templates in scope. The printer and the parser both consult
it, and the round-trip theorem holds for every table.

## Characters

## Names

<div class="lean-decl" id="Esm.Document.Math.splitDots">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.splitDots" title="Esm.Document.Math.splitDots"><code>splitDots</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Expr.lean#L44-L51">source</a></div>

```lean
def splitDots : List Char → List (List Char)
```

Split a character list at every `.`.

</div>

<div class="lean-decl" id="Esm.Document.Math.joinDots">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.joinDots" title="Esm.Document.Math.joinDots"><code>joinDots</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Expr.lean#L54-L57">source</a></div>

```lean
def joinDots : List (List Char) → List Char
```

Join segments with `.`.

</div>

<div class="lean-decl" id="Esm.Document.Math.segOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.segOK" title="Esm.Document.Math.segOK"><code>segOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Expr.lean#L60-L62">source</a></div>

```lean
def segOK : List Char → Bool
```

An identifier segment `[A-Za-z_][A-Za-z0-9_]*`.

</div>

<div class="lean-decl" id="Esm.Document.Math.nameOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.nameOK" title="Esm.Document.Math.nameOK"><code>nameOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Expr.lean#L66">source</a></div>

```lean
def nameOK (s : String) : Bool
```

A name: dot-separated identifier segments (every name in the corpus has this
shape).

</div>

<div class="lean-decl" id="Esm.Document.Math.greek">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.greek" title="Esm.Document.Math.greek"><code>greek</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Expr.lean#L71-L75">source</a></div>

```lean
def greek : List String
```

The Greek letter names that are a command in LaTeX (`\lambda`) and a symbol in
Typst (`lambda`): the lowercase letters but omicron, and the eleven uppercase letters
LaTeX has.

</div>

<div class="lean-decl" id="Esm.Document.Math.isSingle">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.isSingle" title="Esm.Document.Math.isSingle"><code>isSingle</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Expr.lean#L80-L83">source</a></div>

```lean
def isSingle (s : List Char) : Bool
```

One letter, or a Greek letter name: the `single` name shape.

</div>

<div class="lean-decl" id="Esm.Document.Math.elements">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.elements" title="Esm.Document.Math.elements"><code>elements</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Expr.lean#L86-L89">source</a></div>

```lean
def elements : List String
```

The element symbols a chemical-formula name is built from.

</div>

<div class="lean-decl" id="Esm.Document.Math.digRun">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.digRun" title="Esm.Document.Math.digRun"><code>digRun</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Expr.lean#L92-L94">source</a></div>

```lean
def digRun : List Char → List Char × List Char
```

The maximal run of digits at the front.

</div>

<div class="lean-decl" id="Esm.Document.Math.letRun">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.letRun" title="Esm.Document.Math.letRun"><code>letRun</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Expr.lean#L97-L99">source</a></div>

```lean
def letRun : List Char → List Char × List Char
```

The maximal run of letters at the front.

</div>

<div class="lean-decl" id="Esm.Document.Math.pieces">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.pieces" title="Esm.Document.Math.pieces"><code>pieces</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Expr.lean#L103-L104">source</a></div>

```lean
def pieces (s : List Char) : List (List Char × List Char)
```

Split a formula-shaped name into pieces: a run of letters and the run of digits
after it (possibly empty). `CH2O` is `[("CH", "2"), ("O", "")]`.

</div>

<div class="lean-decl" id="Esm.Document.Math.elemToks">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.elemToks" title="Esm.Document.Math.elemToks"><code>elemToks</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Expr.lean#L116-L122">source</a></div>

```lean
def elemToks : List Char → Option (List String)
```

The element-symbol tokens of a letter run: an uppercase letter, then an optional
lowercase one, greedily.

</div>

<div class="lean-decl" id="Esm.Document.Math.isFormula">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.isFormula" title="Esm.Document.Math.isFormula"><code>isFormula</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Expr.lean#L127-L136">source</a></div>

```lean
def isFormula (s : List Char) : Bool
```

A chemical-formula name (decision 2): letters and digits only, read as element
symbols and counts, starting with an element, with at least two tokens. `NO2`,
`CH2O`, `O3`, `NO`.

</div>

<div class="lean-decl" id="Esm.Document.Math.subParts">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.subParts" title="Esm.Document.Math.subParts"><code>subParts</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Expr.lean#L140-L145">source</a></div>

```lean
def subParts (s : List Char) : Option (List Char × List Char)
```

The subscripted shape `b_r`: a single letter or Greek name, `_`, then a nonempty
rest. Returns the base and the rest.

</div>

## Numbers and JSON well-formedness, as checks

<div class="lean-decl" id="Esm.Document.Math.numOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.numOK" title="Esm.Document.Math.numOK"><code>numOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Expr.lean#L152-L158">source</a></div>

```lean
def numOK : JNum → Bool
```

[`JNum.WF`](/generated/document-formats/esm-document-json#Esm.Document.JNum.WF) as a check.

</div>

<div class="lean-decl" id="Esm.Document.Math.keysSorted">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.keysSorted" title="Esm.Document.Math.keysSorted"><code>keysSorted</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Expr.lean#L185-L188">source</a></div>

```lean
def keysSorted : List (String × Json) → Bool
```

Strictly increasing keys.

</div>

<div class="lean-decl" id="Esm.Document.Math.jwf">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.jwf" title="Esm.Document.Math.jwf"><code>jwf</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Expr.lean#L192-L196">source</a></div>

```lean
def jwf : Json → Bool
```

[`Json.WF`](/generated/document-formats/esm-document-json#Esm.Document.Json.WF) as a check.

</div>

## Operators

<div class="lean-decl" id="Esm.Document.Math.removedOps">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.removedOps" title="Esm.Document.Math.removedOps"><code>removedOps</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Expr.lean#L234-L236">source</a></div>

```lean
def removedOps : List String
```

Spec §4.2 "Removed ops": refused by name.

</div>

<div class="lean-decl" id="Esm.Document.Math.deprecatedOps">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.deprecatedOps" title="Esm.Document.Math.deprecatedOps"><code>deprecatedOps</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Expr.lean#L239">source</a></div>

```lean
def deprecatedOps : List String
```

Deprecated: read in the call form and rewritten, never printed.

</div>

<div class="lean-decl" id="Esm.Document.Math.opOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.opOK" title="Esm.Document.Math.opOK"><code>opOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Expr.lean#L242-L247">source</a></div>

```lean
def opOK (s : String) : Bool
```

The `op` pattern of the schema: `[A-Za-z_][A-Za-z0-9_.]*` or `[-+*/^<>=!]+`.

</div>

<div class="lean-decl" id="Esm.Document.Math.look">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.look" title="Esm.Document.Math.look"><code>look</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Expr.lean#L250-L252">source</a></div>

```lean
def look (k : String) : List (String × Json) → Option Json
```

The value of key `k`.

</div>

## Expressions

<div class="lean-decl" id="Esm.Document.Math.opFieldOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.opFieldOK" title="Esm.Document.Math.opFieldOK"><code>opFieldOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Expr.lean#L258-L261">source</a></div>

```lean
def opFieldOK (kvs : List (String × Json)) : Bool
```

The `op` field is present and names an operator that is neither removed nor
deprecated.

</div>

<div class="lean-decl" id="Esm.Document.Math.hasArgs">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.hasArgs" title="Esm.Document.Math.hasArgs"><code>hasArgs</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Expr.lean#L264">source</a></div>

```lean
def hasArgs (kvs : List (String × Json)) : Bool
```

The `args` field is present.

</div>

<div class="lean-decl" id="Esm.Document.Math.isE">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.isE" title="Esm.Document.Math.isE"><code>isE</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Expr.lean#L267-L287">source</a></div>

```lean
def isE : Json → Bool
```

Well-formed expression (canonical form), as a check.

</div>

<div class="lean-decl" id="Esm.Document.Math.Sym">
<div class="lean-decl-head"><span class="lean-kind">structure</span> <a class="lean-name" href="#Esm.Document.Math.Sym" title="Esm.Document.Math.Sym"><code>Sym</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Expr.lean#L291-L293">source</a></div>

```lean
structure Sym where
  names : List String := []
  templates : List (String × List String) := []
```

The symbol table: the names a document declares (variables, parameters, species,
index names) and the parameter list of every template in scope.

</div>

<p class="lean-meta">This module also proves 4 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Expr.lean">the source</a>.</p>
