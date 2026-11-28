---
title: "Round trip of the atoms: numbers and names"
type: lean
lean_module: "Esm.Document.Math.Atoms"
weight: 21
---

<p class="lean-meta">Lean module <code>Esm.Document.Math.Atoms</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/Atoms.lean"><code>formal/Esm/Document/Math/Atoms.lean</code></a> at <code>9c3b4aa7587e</code><br>Imports <a href="/generated/document-formats/esm-document-math-kinds"><code>Esm.Document.Math.Kinds</code></a></p>

<div class="lean-decl" id="Esm.Document.Math.SegHead">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.SegHead" title="Esm.Document.Math.SegHead"><code>SegHead</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/Atoms.lean#L12-L17">source</a></div>

```lean
def SegHead (g : List Char) (t : Tok) (tr : List Tok) : Prop
```

How a printed name segment starts.

</div>

<div class="lean-decl" id="Esm.Document.Math.NameHead">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.NameHead" title="Esm.Document.Math.NameHead"><code>NameHead</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/Atoms.lean#L71-L77">source</a></div>

```lean
def NameHead (c : Ctx) (s : String) (t : Tok) (tr : List Tok) : Prop
```

How a printed name starts.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.pPrim_name_eq">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.pPrim_name_eq" title="Esm.Document.Math.pPrim_name_eq"><code>pPrim_name_eq</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/Atoms.lean#L147-L195">source</a></div>

```lean
theorem pPrim_name_eq (c : Ctx) (s : String) (rest : List Tok) (f : Nat) :
    pPrim c (f + 1) (nameToks c s ++ rest) = pNamePrim c (nameToks c s ++ rest)
```

A primary that starts with a name's tokens is read as a name (never as `e^x`).

</div>

<p class="lean-meta">This module also proves 8 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/Atoms.lean">the source</a>.</p>
