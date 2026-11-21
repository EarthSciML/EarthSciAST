---
title: "The LaTeX math round trip, at the string level"
type: lean
lean_module: "Esm.Document.Math.RoundTripLatex"
weight: 17
---

<p class="lean-meta">Lean module <code>Esm.Document.Math.RoundTripLatex</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Math/RoundTripLatex.lean"><code>formal/Esm/Document/Math/RoundTripLatex.lean</code></a> at <code>1b8dd9b3a909</code><br>Imports <a href="/generated/document-formats/esm-document-math-toklatex"><code>Esm.Document.Math.TokLatex</code></a></p>

<div class="lean-decl" id="Esm.Document.Math.printLatex">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.printLatex" title="Esm.Document.Math.printLatex"><code>printLatex</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Math/RoundTripLatex.lean#L12-L13">source</a></div>

```lean
def printLatex (S : Sym) (e : Json) : String
```

The LaTeX math spelling of an expression under the symbol table `S`.

</div>

<div class="lean-decl" id="Esm.Document.Math.parseLatex">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.parseLatex" title="Esm.Document.Math.parseLatex"><code>parseLatex</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Math/RoundTripLatex.lean#L16-L17">source</a></div>

```lean
def parseLatex (S : Sym) (s : String) : Option Json
```

Read LaTeX math under the symbol table `S`.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.parseLatex_printLatex">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.parseLatex_printLatex" title="Esm.Document.Math.parseLatex_printLatex"><code>parseLatex_printLatex</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Math/RoundTripLatex.lean#L22-L26">source</a></div>

```lean
theorem parseLatex_printLatex (S : Sym) (e : Json) (he : isE e = true) :
    parseLatex S (printLatex S e) = some e
```

The LaTeX round trip: every well-formed expression reads back from its LaTeX
spelling, under every symbol table (collisions included: the printer switches the
names involved to the explicit form).

</div>
