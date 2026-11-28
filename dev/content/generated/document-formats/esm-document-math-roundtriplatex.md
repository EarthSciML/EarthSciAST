---
title: "The LaTeX math round trip, at the string level"
type: lean
lean_module: "Esm.Document.Math.RoundTripLatex"
weight: 17
---

<p class="lean-meta">Lean module <code>Esm.Document.Math.RoundTripLatex</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/RoundTripLatex.lean"><code>formal/Esm/Document/Math/RoundTripLatex.lean</code></a> at <code>9c3b4aa7587e</code><br>Imports <a href="/generated/document-formats/esm-document-math-toklatex"><code>Esm.Document.Math.TokLatex</code></a></p>

Two printers, as for Typst: [`printLatex`](#Esm.Document.Math.printLatex) writes an expression (an `==` at its top is a
comparison and prints as any expression does), [`printLatexEqn`](#Esm.Document.Math.printLatexEqn) an equation's expression,
in its defining form when it has one ([`Math.print`](/generated/document-formats/esm-document-math-print#Esm.Document.Math.print)).

<div class="lean-decl" id="Esm.Document.Math.printLatex">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.printLatex" title="Esm.Document.Math.printLatex"><code>printLatex</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/RoundTripLatex.lean#L16-L17">source</a></div>

```lean
def printLatex (S : Sym) (e : Json) : String
```

The LaTeX math spelling of an expression under the symbol table `S`.

</div>

<div class="lean-decl" id="Esm.Document.Math.printLatexEqn">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.printLatexEqn" title="Esm.Document.Math.printLatexEqn"><code>printLatexEqn</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/RoundTripLatex.lean#L21-L22">source</a></div>

```lean
def printLatexEqn (S : Sym) (e : Json) : String
```

The LaTeX math spelling of an equation's expression (`==(lhs, rhs)`) under the symbol
table `S`: in its defining form when it has one.

</div>

<div class="lean-decl" id="Esm.Document.Math.parseLatex">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.parseLatex" title="Esm.Document.Math.parseLatex"><code>parseLatex</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/RoundTripLatex.lean#L25-L26">source</a></div>

```lean
def parseLatex (S : Sym) (s : String) : Option Json
```

Read LaTeX math under the symbol table `S`.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.parseLatex_printLatex">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.parseLatex_printLatex" title="Esm.Document.Math.parseLatex_printLatex"><code>parseLatex_printLatex</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/RoundTripLatex.lean#L31-L35">source</a></div>

```lean
theorem parseLatex_printLatex (S : Sym) (e : Json) (he : isE e = true) :
    parseLatex S (printLatex S e) = some e
```

The LaTeX round trip: every well-formed expression reads back from its LaTeX
spelling, under every symbol table (collisions included: the printer switches the
names involved to the explicit form).

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.parseLatex_printLatexEqn">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.parseLatex_printLatexEqn" title="Esm.Document.Math.parseLatex_printLatexEqn"><code>parseLatex_printLatexEqn</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/RoundTripLatex.lean#L38-L42">source</a></div>

```lean
theorem parseLatex_printLatexEqn (S : Sym) (e : Json) (he : isE e = true) :
    parseLatex S (printLatexEqn S e) = some e
```

The LaTeX round trip of an equation's expression, its defining form included.

</div>
