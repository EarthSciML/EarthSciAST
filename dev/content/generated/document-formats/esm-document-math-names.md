---
title: "Names read back"
type: lean
lean_module: "Esm.Document.Math.Names"
weight: 41
---

<p class="lean-meta">Lean module <code>Esm.Document.Math.Names</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/Names.lean"><code>formal/Esm/Document/Math/Names.lean</code></a> at <code>9c3b4aa7587e</code><br>Imports <a href="/generated/document-formats/esm-document-math-view"><code>Esm.Document.Math.View</code></a></p>

[`pName_nameToks`](#Esm.Document.Math.pName_nameToks): the tokens of a name read back to the name, whatever symbol table
printed them, before anything that does not continue a name ([`NameStop`](#Esm.Document.Math.NameStop): not the
scope dot, not an upright name subscript).

## Splitting at dots

<div class="lean-decl lean-theorem" id="Esm.Document.Math.splitDots_noDot">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.splitDots_noDot" title="Esm.Document.Math.splitDots_noDot"><code>splitDots_noDot</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/Names.lean#L53-L75">source</a></div>

```lean
theorem splitDots_noDot (l : List Char) : ∀ s ∈ splitDots l, '.' ∉ s
```

Every segment of a split has no dot.

</div>

## Segments

<div class="lean-decl" id="Esm.Document.Math.NameStop">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.NameStop" title="Esm.Document.Math.NameStop"><code>NameStop</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/Names.lean#L206-L207">source</a></div>

```lean
def NameStop (sf : Sf) (rest : List Tok) : Prop
```

What may follow a name: not the scope dot, not an upright name subscript.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.pName_nameToks">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.pName_nameToks" title="Esm.Document.Math.pName_nameToks"><code>pName_nameToks</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/Names.lean#L262-L288">source</a></div>

```lean
theorem pName_nameToks (c : Ctx) (s : String) (hs : nameOK s = true) (rest : List Tok)
    (hr : NameStop c.sf rest) : pName c.sf (nameToks c s ++ rest) = some (s, rest)
```

**Names read back.**

</div>

<p class="lean-meta">This module also proves 17 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/Names.lean">the source</a>.</p>
