---
title: "Esm.Units.Examples"
type: lean
lean_module: "Esm.Units.Examples"
weight: 69
---

<p class="lean-meta">Lean module <code>Esm.Units.Examples</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Examples.lean"><code>formal/Esm/Units/Examples.lean</code></a> at <code>ffd5aee2f868</code><br>Imports <a href="/generated/document-formats/esm-units-grammarlaws"><code>Esm.Units.GrammarLaws</code></a></p>

Concrete checks of the §4.8.2 grammar on the spec's own example strings
(tests, not properties: the kernel evaluates normalisation, lexing and parsing).

<div class="lean-decl" id="Esm.Units.Examples.parseChars">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.Examples.parseChars" title="Esm.Units.Examples.parseChars"><code>parseChars</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Examples.lean#L11">source</a></div>

```lean
def parseChars (cs : List Char) : Except Err UExpr
```

Normalise, lex and parse (no table lookup).

</div>
