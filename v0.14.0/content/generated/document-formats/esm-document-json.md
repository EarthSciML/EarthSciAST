---
title: "JSON values of an ESM document, in canonical form"
type: lean
lean_module: "Esm.Document.Json"
weight: 4
---

<p class="lean-meta">Lean module <code>Esm.Document.Json</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Json.lean"><code>formal/Esm/Document/Json.lean</code></a> at <code>ffd5aee2f868</code><br>Imports <code>Mathlib.Data.List.Nodup</code></p>

The value type the document codecs ([`Esm.Document.Yaml`](/generated/document-formats/esm-document-yaml), [`Esm.Document.TypstDict`](/generated/document-formats/esm-document-typstdict))
print and read. Numbers are already in the canonical form of CONFORMANCE §5.5.3.1:

* rule 1 and rule 3: a number whose value is integral and representable in `Int64` is
  the integer literal (`1.0` IS the integer `1`), so it is `JNum.int`;
* rule 2: every other finite number is `JNum.dec`, its shortest round-trip decimal
  digits and the decimal exponent of the first digit. Binary64 is not modelled; the
  shortest digits are given data.

Object key order is part of the value (the codecs preserve it; they never sort).

<div class="lean-decl" id="Esm.Document.JNum">
<div class="lean-decl-head"><span class="lean-kind">inductive</span> <a class="lean-name" href="#Esm.Document.JNum" title="Esm.Document.JNum"><code>JNum</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Json.lean#L25-L28">source</a></div>

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
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.JNum.InInt64" title="Esm.Document.JNum.InInt64"><code>InInt64</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Json.lean#L33">source</a></div>

```lean
def InInt64 (z : Int) : Prop
```

`z` is representable in `Int64`.

</div>

<div class="lean-decl" id="Esm.Document.JNum.digitsVal">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.JNum.digitsVal" title="Esm.Document.JNum.digitsVal"><code>digitsVal</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Json.lean#L36">source</a></div>

```lean
def digitsVal (ds : List Nat) : Nat
```

The value of a big-endian decimal digit list.

</div>

<div class="lean-decl" id="Esm.Document.JNum.decInt?">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.JNum.decInt?" title="Esm.Document.JNum.decInt?"><code>decInt?</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Json.lean#L40-L44">source</a></div>

```lean
def decInt? (neg : Bool) (ds : List Nat) (e10 : Int) : Option Int
```

The integer a decimal denotes, when the decimal is integral (its last digit sits at
or left of the units place), else `none`.

</div>

<div class="lean-decl" id="Esm.Document.JNum.WF">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.JNum.WF" title="Esm.Document.JNum.WF"><code>WF</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Json.lean#L51-L55">source</a></div>

```lean
def WF : JNum → Prop
```

Canonical form of a number:

* an `int` fits in `Int64`;
* a `dec` has nonempty digits, each below 10, with no leading and no trailing zero,
  and is not an integral `Int64` value (that number is an `int`, §5.5.3.1 rule 1).

</div>

<div class="lean-decl" id="Esm.Document.JNum.wfb">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.JNum.wfb" title="Esm.Document.JNum.wfb"><code>wfb</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Json.lean#L60-L66">source</a></div>

```lean
def wfb : JNum → Bool
```

[`WF`](#Esm.Document.JNum.WF), as a check.

</div>

<div class="lean-decl" id="Esm.Document.Json">
<div class="lean-decl-head"><span class="lean-kind">inductive</span> <a class="lean-name" href="#Esm.Document.Json" title="Esm.Document.Json"><code>Json</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Json.lean#L80-L87">source</a></div>

```lean
inductive Json where
  | null
  | bool (b : Bool)
  | num (n : JNum)
  | str (s : String)
  | arr (xs : List Json)
  | obj (kvs : List (String × Json))
  deriving Repr
```

A JSON value. Strings and keys are arbitrary Lean strings (any Unicode scalar
values); object entries keep their order.

</div>

<div class="lean-decl" id="Esm.Document.Json.WF">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Json.WF" title="Esm.Document.Json.WF"><code>WF</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Json.lean#L93-L97">source</a></div>

```lean
def WF : Json → Prop
```

Well formed: every number is canonical and every object has distinct keys.

</div>

<div class="lean-decl" id="Esm.Document.Json.WFList">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Json.WFList" title="Esm.Document.Json.WFList"><code>WFList</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Json.lean#L100-L102">source</a></div>

```lean
def WFList : List Json → Prop
```

Every element is well formed.

</div>

<div class="lean-decl" id="Esm.Document.Json.WFObj">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Json.WFObj" title="Esm.Document.Json.WFObj"><code>WFObj</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Json.lean#L105-L107">source</a></div>

```lean
def WFObj : List (String × Json) → Prop
```

Every entry's value is well formed.

</div>

<div class="lean-decl" id="Esm.Document.Json.wfb">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Json.wfb" title="Esm.Document.Json.wfb"><code>wfb</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Json.lean#L112-L116">source</a></div>

```lean
def wfb : Json → Bool
```

[`WF`](#Esm.Document.Json.WF), as a check.

</div>

<div class="lean-decl" id="Esm.Document.Json.size">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Json.size" title="Esm.Document.Json.size"><code>size</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Json.lean#L153-L156">source</a></div>

```lean
def size : Json → Nat
```

A size measure: the parsers' fuel is bounded below by it.

</div>

<p class="lean-meta">This module also proves 4 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Json.lean">the source</a>.</p>
