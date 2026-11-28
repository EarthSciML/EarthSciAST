---
title: "JSON values of an ESM document, in canonical form"
type: lean
lean_module: "Esm.Document.Json"
weight: 4
---

<p class="lean-meta">Lean module <code>Esm.Document.Json</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Json.lean"><code>formal/Esm/Document/Json.lean</code></a> at <code>9c3b4aa7587e</code><br>Imports <code>Mathlib.Data.List.Nodup</code></p>

The value type the document codecs ([`Esm.Document.Yaml`](/generated/document-formats/esm-document-yaml), [`Esm.Document.TypstDict`](/generated/document-formats/esm-document-typstdict))
print and read. Numbers are already in the canonical form of CONFORMANCE §5.5.3.1:

* rule 1 and rule 3: a number whose value is integral and representable in `Int64` is
  the integer literal (`1.0` IS the integer `1`), so it is `JNum.int`;
* rule 2: every other finite number is `JNum.dec`, its shortest round-trip decimal
  digits and the decimal exponent of the first digit. Binary64 is not modelled; the
  shortest digits are given data.

Object key order is part of the value (the codecs preserve it; they never sort).

<div class="lean-decl" id="Esm.Document.JNum">
<div class="lean-decl-head"><span class="lean-kind">inductive</span> <a class="lean-name" href="#Esm.Document.JNum" title="Esm.Document.JNum"><code>JNum</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Json.lean#L25-L28">source</a></div>

```lean
inductive JNum where
  | int (z : Int)
  | dec (neg : Bool) (digits : List Nat) (e10 : Int)
  deriving DecidableEq, Repr
```

A JSON number in canonical form.

* `int z`: an integer literal (well formed when `z` fits in `Int64`).
* `dec neg ds e10`: the value `±d₁.d₂d₃… × 10^e10`, `-` when `neg`, with `ds` the
  shortest round-trip digits.

</div>

<div class="lean-decl" id="Esm.Document.JNum.InInt64">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.JNum.InInt64" title="Esm.Document.JNum.InInt64"><code>InInt64</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Json.lean#L33">source</a></div>

```lean
def InInt64 (z : Int) : Prop
```

`z` is representable in `Int64`.

</div>

<div class="lean-decl" id="Esm.Document.JNum.digitsVal">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.JNum.digitsVal" title="Esm.Document.JNum.digitsVal"><code>digitsVal</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Json.lean#L36">source</a></div>

```lean
def digitsVal (ds : List Nat) : Nat
```

The value of a big-endian decimal digit list.

</div>

<div class="lean-decl" id="Esm.Document.JNum.decInt?">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.JNum.decInt?" title="Esm.Document.JNum.decInt?"><code>decInt?</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Json.lean#L40-L44">source</a></div>

```lean
def decInt? (neg : Bool) (ds : List Nat) (e10 : Int) : Option Int
```

The integer a decimal denotes, when the decimal is integral (its last digit sits at
or left of the units place), else `none`.

</div>

<div class="lean-decl" id="Esm.Document.JNum.WF">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.JNum.WF" title="Esm.Document.JNum.WF"><code>WF</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Json.lean#L51-L55">source</a></div>

```lean
def WF : JNum → Prop
```

Canonical form of a number:

* an `int` fits in `Int64`;
* a `dec` has nonempty digits, each below 10, with no leading and no trailing zero,
  and is not an integral `Int64` value (that number is an `int`, §5.5.3.1 rule 1).

</div>

<div class="lean-decl" id="Esm.Document.JNum.wfb">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.JNum.wfb" title="Esm.Document.JNum.wfb"><code>wfb</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Json.lean#L60-L66">source</a></div>

```lean
def wfb : JNum → Bool
```

[`WF`](#Esm.Document.JNum.WF), as a check.

</div>

<div class="lean-decl" id="Esm.Document.Json">
<div class="lean-decl-head"><span class="lean-kind">inductive</span> <a class="lean-name" href="#Esm.Document.Json" title="Esm.Document.Json"><code>Json</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Json.lean#L85-L93">source</a></div>

```lean
inductive Json where
  | null
  | bool (b : Bool)
  | num (n : JNum)
  | str (s : String)
  | arr (xs : List Json)
  | obj (kvs : List (String × Json))
  | math (s : String)
  deriving Repr
```

A JSON value. Strings and keys are arbitrary Lean strings (any Unicode scalar
values); object entries keep their order.

`math s` is not JSON: it is the math text of an expression inside a path block, the
form a container prints and reads there ([`Source.mathify`](/generated/document-formats/esm-document-source-items#Esm.Document.Source.mathify), [`Source.cookBlocks`](/generated/document-formats/esm-document-source-items#Esm.Document.Source.cookBlocks)). It
lives only between a container's text and the skeleton; a document never holds one
([`WF`](#Esm.Document.JNum.WF) is false on it).

</div>

<div class="lean-decl" id="Esm.Document.Json.mathOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Json.mathOK" title="Esm.Document.Json.mathOK"><code>mathOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Json.lean#L99-L101">source</a></div>

```lean
def mathOK (s : String) : Bool
```

Math text a container can delimit with `$`: not empty, no `$`, no line break, and
not ending in a backslash (which would escape the closing `$`).

</div>

<div class="lean-decl" id="Esm.Document.Json.mathBody">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Json.mathBody" title="Esm.Document.Json.mathBody"><code>mathBody</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Json.lean#L104-L106">source</a></div>

```lean
def mathBody : List Char → Option (List Char × List Char)
```

The text of a math leaf after its `$`, up to the next `$`.

</div>

<div class="lean-decl" id="Esm.Document.Json.pMath">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Json.pMath" title="Esm.Document.Json.pMath"><code>pMath</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Json.lean#L109-L112">source</a></div>

```lean
def pMath (r : List Char) : Option (Json × List Char)
```

A math leaf after its `$`: the text up to the next `$`, which must be [`mathOK`](#Esm.Document.Json.mathOK).

</div>

<div class="lean-decl" id="Esm.Document.Json.WF">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Json.WF" title="Esm.Document.Json.WF"><code>WF</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Json.lean#L132-L137">source</a></div>

```lean
def WF : Json → Prop
```

Well formed: every number is canonical, every object has distinct keys, and there is
no math leaf.

</div>

<div class="lean-decl" id="Esm.Document.Json.WFList">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Json.WFList" title="Esm.Document.Json.WFList"><code>WFList</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Json.lean#L140-L142">source</a></div>

```lean
def WFList : List Json → Prop
```

Every element is well formed.

</div>

<div class="lean-decl" id="Esm.Document.Json.WFObj">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Json.WFObj" title="Esm.Document.Json.WFObj"><code>WFObj</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Json.lean#L145-L147">source</a></div>

```lean
def WFObj : List (String × Json) → Prop
```

Every entry's value is well formed.

</div>

<div class="lean-decl" id="Esm.Document.Json.wfb">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Json.wfb" title="Esm.Document.Json.wfb"><code>wfb</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Json.lean#L152-L157">source</a></div>

```lean
def wfb : Json → Bool
```

[`WF`](#Esm.Document.Json.WF), as a check.

</div>

<div class="lean-decl" id="Esm.Document.Json.WFm">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Json.WFm" title="Esm.Document.Json.WFm"><code>WFm</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Json.lean#L197-L202">source</a></div>

```lean
def WFm : Json → Prop
```

Well formed with math leaves: [`WF`](#Esm.Document.Json.WF), except that a math leaf whose text is [`mathOK`](#Esm.Document.Json.mathOK)
is allowed. What the codecs print and read: a path block's value as a container holds
it.

</div>

<div class="lean-decl" id="Esm.Document.Json.wfmb">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Json.wfmb" title="Esm.Document.Json.wfmb"><code>wfmb</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Json.lean#L215-L220">source</a></div>

```lean
def wfmb : Json → Bool
```

[`WFm`](#Esm.Document.Json.WFm), as a check.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Json.WF.wfm">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Json.WF.wfm" title="Esm.Document.Json.WF.wfm"><code>WF.wfm</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Json.lean#L258-L265">source</a></div>

```lean
theorem WF.wfm : ∀ {v : Json}, v.WF → v.WFm
```

A well-formed value is well formed with math leaves (it has none).

</div>

<div class="lean-decl" id="Esm.Document.Json.size">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Json.size" title="Esm.Document.Json.size"><code>size</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Json.lean#L278-L281">source</a></div>

```lean
def size : Json → Nat
```

A size measure: the parsers' fuel is bounded below by it.

</div>

<p class="lean-meta">This module also proves 11 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Json.lean">the source</a>.</p>
