---
title: "The token-level round trip, by induction over the expression"
type: lean
lean_module: "Esm.Document.Math.Induct"
weight: 34
---

<p class="lean-meta">Lean module <code>Esm.Document.Math.Induct</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/Induct.lean"><code>formal/Esm/Document/Math/Induct.lean</code></a> at <code>9c3b4aa7587e</code><br>Imports <a href="/generated/document-formats/esm-document-math-makearray"><code>Esm.Document.Math.Makearray</code></a></p>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.M_all">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.M_all" title="Esm.Document.Math.M_all"><code>M_all</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/Induct.lean#L34-L100">source</a></div>

```lean
theorem M_all (c : Ctx) : ∀ n e, sizeOf e < n → isE e = true → M c e
```

Every well-formed expression carries the round-trip facts.

</div>

<div class="lean-decl" id="Esm.Document.Math.parseToks">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.parseToks" title="Esm.Document.Math.parseToks"><code>parseToks</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/Induct.lean#L107-L117">source</a></div>

```lean
def parseToks (sf : Sf) (S : Sym) (ts : List Tok) : Option Json
```

Read a whole token list as one expression: an expression, or an equation in its
defining form (`x_s = …, s ∈ S`, [`unlift`](/generated/document-formats/esm-document-math-print#Esm.Document.Math.unlift)).

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.parseToks_pa">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.parseToks_pa" title="Esm.Document.Math.parseToks_pa"><code>parseToks_pa</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/Induct.lean#L120-L126">source</a></div>

```lean
theorem parseToks_pa (sf : Sf) (S : Sym) (e : Json) (he : isE e = true) :
    parseToks sf S (pa ⟨sf, S⟩ 1 e) = some e
```

An expression printed whole reads back.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.pTail_tail">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.pTail_tail" title="Esm.Document.Math.pTail_tail"><code>pTail_tail</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/Induct.lean#L134-L162">source</a></div>

```lean
theorem pTail_tail (c : Ctx) (rows : List (String × Json)) (hne : rows ≠ [])
    (hrows : rows.all (fun kv => nameOK kv.1 && rangeOK kv.2 &&
      match kv.2 with | .arr [a, b] => isE a && isE b | _ => true) = true)
    (f : Nat) (hf : 30 * (defRowsToks c rows).length + 12 ≤ f) :
    pTail c (f + 1) (defRowsToks c rows) = some (rows.map fun kv => Row.rng kv.1 kv.2)
```

The range rows after a defining equation read back.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.parseToks_print">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.parseToks_print" title="Esm.Document.Math.parseToks_print"><code>parseToks_print</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/Induct.lean#L166-L206">source</a></div>

```lean
theorem parseToks_print (sf : Sf) (S : Sym) (e : Json) (he : isE e = true) :
    parseToks sf S (print sf S e) = some e
```

The token-level round trip: every well-formed expression reads back from its
printed tokens, on both surfaces and under every symbol table.

</div>

<p class="lean-meta">This module also proves 7 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/Induct.lean">the source</a>.</p>
