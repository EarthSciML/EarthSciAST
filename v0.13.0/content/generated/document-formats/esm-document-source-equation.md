---
title: "An equation as math"
type: lean
lean_module: "Esm.Document.Source.Equation"
weight: 55
---

<p class="lean-meta">Lean module <code>Esm.Document.Source.Equation</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Source/Equation.lean"><code>formal/Esm/Document/Source/Equation.lean</code></a> at <code>5af01ca9d41a</code><br>Imports <a href="/generated/document-formats/esm-document-source-facts"><code>Esm.Document.Source.Facts</code></a>, <code>Mathlib.Data.String.Basic</code></p>

An equation `lhs = rhs` is printed as the math of the expression `==(lhs, rhs)`: the
`=` is the comparison's sign at the loosest comparison level. So the Phase 2 round trip
(`parseLatex_printLatex`, `parseTypst_printTypst`) reads it back, and a side that is
itself a comparison, `and` or `or` is parenthesized by the precedence rules where
needed: on the right always, on the left when it is an `and` or an `or` (a comparison
on the left, `a < b = c`, reads back as the same equation because comparisons
associate to the left).

<div class="lean-decl" id="Esm.Document.Source.eqExpr">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.eqExpr" title="Esm.Document.Source.eqExpr"><code>eqExpr</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Source/Equation.lean#L21">source</a></div>

```lean
def eqExpr (e : Eqn) : Json
```

The expression an equation is printed as.

</div>

<div class="lean-decl" id="Esm.Document.Source.eqSides">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.eqSides" title="Esm.Document.Source.eqSides"><code>eqSides</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Source/Equation.lean#L24-L26">source</a></div>

```lean
def eqSides : Json → Option (Json × Json)
```

The equation sides of a parsed expression, when it is an `==` node.

</div>

<p class="lean-meta">This module also proves 2 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Source/Equation.lean">the source</a>.</p>
