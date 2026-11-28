---
title: "Esm.Units.Examples"
type: lean
lean_module: "Esm.Units.Examples"
weight: 70
---

<p class="lean-meta">Lean module <code>Esm.Units.Examples</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Units/Examples.lean"><code>formal/Esm/Units/Examples.lean</code></a> at <code>9c3b4aa7587e</code><br>Imports <a href="/generated/document-formats/esm-units-grammarlaws"><code>Esm.Units.GrammarLaws</code></a></p>

Concrete checks of the §4.8.2 grammar on the spec's own example strings
(tests, not properties: the kernel evaluates normalisation, lexing and parsing).

<div class="lean-decl" id="Esm.Units.Examples.parseChars">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.Examples.parseChars" title="Esm.Units.Examples.parseChars"><code>parseChars</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Units/Examples.lean#L11">source</a></div>

```lean
def parseChars (cs : List Char) : Except Err UExpr
```

Normalise, lex and parse (no table lookup).

</div>
