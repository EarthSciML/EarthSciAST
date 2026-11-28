---
title: "The Typst math round trip, at the string level"
type: lean
lean_module: "Esm.Document.Math.RoundTripTypst"
weight: 18
---

<p class="lean-meta">Lean module <code>Esm.Document.Math.RoundTripTypst</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/RoundTripTypst.lean"><code>formal/Esm/Document/Math/RoundTripTypst.lean</code></a> at <code>9c3b4aa7587e</code><br>Imports <a href="/generated/document-formats/esm-document-math-toktypst"><code>Esm.Document.Math.TokTypst</code></a></p>

Two printers: [`printTypst`](#Esm.Document.Math.printTypst) writes an expression (an `==` at its top is a comparison, as
in an event's condition, and prints as any expression does), and [`printTypstEqn`](#Esm.Document.Math.printTypstEqn) writes
the expression an equation is printed as ([`Source.eqExpr`](/generated/document-formats/esm-document-source-equation#Esm.Document.Source.eqExpr)), an equation `x = faq` with
output indices in its defining form `x_s = …, s ∈ S` ([`Math.print`](/generated/document-formats/esm-document-math-print#Esm.Document.Math.print)). The one reader
takes both back.

<div class="lean-decl" id="Esm.Document.Math.printTypst">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.printTypst" title="Esm.Document.Math.printTypst"><code>printTypst</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/RoundTripTypst.lean#L18-L19">source</a></div>

```lean
def printTypst (S : Sym) (e : Json) : String
```

The Typst math spelling of an expression under the symbol table `S`.

</div>

<div class="lean-decl" id="Esm.Document.Math.printTypstEqn">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.printTypstEqn" title="Esm.Document.Math.printTypstEqn"><code>printTypstEqn</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/RoundTripTypst.lean#L23-L24">source</a></div>

```lean
def printTypstEqn (S : Sym) (e : Json) : String
```

The Typst math spelling of an equation's expression (`==(lhs, rhs)`) under the symbol
table `S`: in its defining form when it has one.

</div>

<div class="lean-decl" id="Esm.Document.Math.parseTypst">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.parseTypst" title="Esm.Document.Math.parseTypst"><code>parseTypst</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/RoundTripTypst.lean#L27-L28">source</a></div>

```lean
def parseTypst (S : Sym) (s : String) : Option Json
```

Read Typst math under the symbol table `S`.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.parseTypst_printTypst">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.parseTypst_printTypst" title="Esm.Document.Math.parseTypst_printTypst"><code>parseTypst_printTypst</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/RoundTripTypst.lean#L33-L38">source</a></div>

```lean
theorem parseTypst_printTypst (S : Sym) (e : Json) (he : isE e = true) :
    parseTypst S (printTypst S e) = some e
```

The Typst round trip: every well-formed expression reads back from its Typst
spelling, under every symbol table (collisions included: the printer switches the
names involved to the explicit form).

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.parseTypst_printTypstEqn">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.parseTypst_printTypstEqn" title="Esm.Document.Math.parseTypst_printTypstEqn"><code>parseTypst_printTypstEqn</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/RoundTripTypst.lean#L41-L46">source</a></div>

```lean
theorem parseTypst_printTypstEqn (S : Sym) (e : Json) (he : isE e = true) :
    parseTypst S (printTypstEqn S e) = some e
```

The Typst round trip of an equation's expression, its defining form included.

</div>
