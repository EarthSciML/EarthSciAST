---
title: "The Typst math round trip, at the string level"
type: lean
lean_module: "Esm.Document.Math.RoundTripTypst"
weight: 18
---

<p class="lean-meta">Lean module <code>Esm.Document.Math.RoundTripTypst</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Math/RoundTripTypst.lean"><code>formal/Esm/Document/Math/RoundTripTypst.lean</code></a> at <code>86bed77c797f</code><br>Imports <a href="/generated/document-formats/esm-document-math-toktypst"><code>Esm.Document.Math.TokTypst</code></a></p>

<div class="lean-decl" id="Esm.Document.Math.printTypst">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.printTypst" title="Esm.Document.Math.printTypst"><code>printTypst</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Math/RoundTripTypst.lean#L12-L13">source</a></div>

```lean
def printTypst (S : Sym) (e : Json) : String
```

The Typst math spelling of an expression under the symbol table `S`.

</div>

<div class="lean-decl" id="Esm.Document.Math.parseTypst">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.parseTypst" title="Esm.Document.Math.parseTypst"><code>parseTypst</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Math/RoundTripTypst.lean#L16-L17">source</a></div>

```lean
def parseTypst (S : Sym) (s : String) : Option Json
```

Read Typst math under the symbol table `S`.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.parseTypst_printTypst">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.parseTypst_printTypst" title="Esm.Document.Math.parseTypst_printTypst"><code>parseTypst_printTypst</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Math/RoundTripTypst.lean#L22-L27">source</a></div>

```lean
theorem parseTypst_printTypst (S : Sym) (e : Json) (he : isE e = true) :
    parseTypst S (printTypst S e) = some e
```

The Typst round trip: every well-formed expression reads back from its Typst
spelling, under every symbol table (collisions included: the printer switches the
names involved to the explicit form).

</div>
