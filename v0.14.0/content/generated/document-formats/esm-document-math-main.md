---
title: "The token-level round trip"
type: lean
lean_module: "Esm.Document.Math.Main"
weight: 19
---

<p class="lean-meta">Lean module <code>Esm.Document.Math.Main</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Main.lean"><code>formal/Esm/Document/Math/Main.lean</code></a> at <code>ffd5aee2f868</code><br>Imports <a href="/generated/document-formats/esm-document-math-atoms"><code>Esm.Document.Math.Atoms</code></a></p>

<div class="lean-decl" id="Esm.Document.Math.addAcc">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.addAcc" title="Esm.Document.Math.addAcc"><code>addAcc</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Main.lean#L12-L15">source</a></div>

```lean
def addAcc (e : Json) : List Json
```

The pending `+` operands a level-4 parse of `e` leaves in the loop.

</div>

<div class="lean-decl" id="Esm.Document.Math.PA">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.PA" title="Esm.Document.Math.PA"><code>PA</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Main.lean#L29-L32">source</a></div>

```lean
def PA (c : Ctx) (e : Json) : Prop
```

The level-4 parse of `e` stops in the `+` loop, with fuel to spare.

</div>

<div class="lean-decl" id="Esm.Document.Math.PCr">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.PCr" title="Esm.Document.Math.PCr"><code>PCr</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Main.lean#L37-L39">source</a></div>

```lean
def PCr (c : Ctx) (e : Json) : Prop
```

`e` as the last rows of a `cases` block reads back.

</div>

<div class="lean-decl" id="Esm.Document.Math.M">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.M" title="Esm.Document.Math.M"><code>M</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Main.lean#L42-L43">source</a></div>

```lean
def M (c : Ctx) (e : Json) : Prop
```

Everything the induction carries.

</div>

## Generic steps

<p class="lean-meta">This module also proves 2 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Main.lean">the source</a>.</p>
