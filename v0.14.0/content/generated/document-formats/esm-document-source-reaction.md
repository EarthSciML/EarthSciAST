---
title: "Reaction sides, shared by the containers"
type: lean
lean_module: "Esm.Document.Source.Reaction"
weight: 55
---

<p class="lean-meta">Lean module <code>Esm.Document.Source.Reaction</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/Reaction.lean"><code>formal/Esm/Document/Source/Reaction.lean</code></a> at <code>ffd5aee2f868</code><br>Imports <a href="/generated/document-formats/esm-document-source-text"><code>Esm.Document.Source.Text</code></a></p>

A reaction prints as one line in the chemistry notation of its container (mhchem
`\ce{…}` in Markdown, typsium `#ce[…]` in Typst), the rate over the arrow
(`Notation.reactionLatex`). The sides are spelled the same way in both, up to the math
surface ([`RSurf`](#Esm.Document.Source.RSurf)):

* an empty side (JSON `null`) is the empty-set symbol as math, `$\varnothing$` /
  `$emptyset$`;
* otherwise the terms, separated by ` + `; a term is its stoichiometric coefficient as
  math followed by a space, `$2$ `, left out when it is 1, then the species;
* a species whose name is formula-shaped (`NO2`) is written bare, for the package to
  set; any other species is its name as math under the empty symbol table,
  `$\mathit{SO4\_aer}$`.

`pSide_sideTxt` reads a side back from its text.

<div class="lean-decl" id="Esm.Document.Source.RSurf">
<div class="lean-decl-head"><span class="lean-kind">structure</span> <a class="lean-name" href="#Esm.Document.Source.RSurf" title="Esm.Document.Source.RSurf"><code>RSurf</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/Reaction.lean#L28-L31">source</a></div>

```lean
structure RSurf where
  pm : String → Option Json
  prm : Json → List Char
  empty : List Char
```

A math surface for the pieces of a reaction side: how a math piece prints and
reads back (under the empty symbol table), and the content of the empty-set piece.

</div>

<div class="lean-decl" id="Esm.Document.Source.RSurf.OK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.RSurf.OK" title="Esm.Document.Source.RSurf.OK"><code>RSurf.OK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/Reaction.lean#L34">source</a></div>

```lean
def RSurf.OK (R : RSurf) : Prop
```

A surface whose pieces read back.

</div>

## Printing

<div class="lean-decl" id="Esm.Document.Source.speciesTxt">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.speciesTxt" title="Esm.Document.Source.speciesTxt"><code>speciesTxt</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/Reaction.lean#L41-L42">source</a></div>

```lean
def speciesTxt (R : RSurf) (n : String) : List Char
```

A species: bare when formula-shaped, else its name as math.

</div>

<div class="lean-decl" id="Esm.Document.Source.termTxt">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.termTxt" title="Esm.Document.Source.termTxt"><code>termTxt</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/Reaction.lean#L45-L46">source</a></div>

```lean
def termTxt (R : RSurf) (t : Term) : List Char
```

A term: the coefficient as math and a space, unless it is 1, then the species.

</div>

<div class="lean-decl" id="Esm.Document.Source.termsTxt">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.termsTxt" title="Esm.Document.Source.termsTxt"><code>termsTxt</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/Reaction.lean#L49-L51">source</a></div>

```lean
def termsTxt (R : RSurf) : List Term → List Char
```

The terms of a non-empty side, separated by ` + `.

</div>

<div class="lean-decl" id="Esm.Document.Source.sideTxt">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.sideTxt" title="Esm.Document.Source.sideTxt"><code>sideTxt</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/Reaction.lean#L54-L56">source</a></div>

```lean
def sideTxt (R : RSurf) : Option (List Term) → List Char
```

A side.

</div>

<div class="lean-decl" id="Esm.Document.Source.termOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.termOK" title="Esm.Document.Source.termOK"><code>termOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/Reaction.lean#L60-L65">source</a></div>

```lean
def termOK (R : RSurf) (t : Term) : Bool
```

A term the side syntax holds: a species name and, unless it is 1, a coefficient,
whose math has no `$` and is not the empty-set piece.

</div>

<div class="lean-decl" id="Esm.Document.Source.sideLen">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.sideLen" title="Esm.Document.Source.sideLen"><code>sideLen</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/Reaction.lean#L68-L70">source</a></div>

```lean
def sideLen : Option (List Term) → Nat
```

The number of terms of a side.

</div>

<div class="lean-decl" id="Esm.Document.Source.sideOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.sideOK" title="Esm.Document.Source.sideOK"><code>sideOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/Reaction.lean#L73-L75">source</a></div>

```lean
def sideOK (R : RSurf) : Option (List Term) → Bool
```

A side the syntax holds: empty, or non-empty terms that it holds.

</div>

## Reading

<div class="lean-decl" id="Esm.Document.Source.after">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.after" title="Esm.Document.Source.after"><code>after</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/Reaction.lean#L80">source</a></div>

```lean
def after (p s : List Char) : Option (List Char)
```

The text after the prefix `p`, when it is one.

</div>

<div class="lean-decl" id="Esm.Document.Source.idChar">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.idChar" title="Esm.Document.Source.idChar"><code>idChar</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/Reaction.lean#L87">source</a></div>

```lean
def idChar (c : Char) : Bool
```

A character of a reaction id: the identifier characters, `-`, `.` and `:` (what a
Typst label and a Pandoc identifier both hold).

</div>

<div class="lean-decl" id="Esm.Document.Source.idOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.idOK" title="Esm.Document.Source.idOK"><code>idOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/Reaction.lean#L90">source</a></div>

```lean
def idOK (i : String) : Bool
```

A reaction id the containers spell as a label.

</div>

<div class="lean-decl" id="Esm.Document.Source.pPiece">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.pPiece" title="Esm.Document.Source.pPiece"><code>pPiece</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/Reaction.lean#L101-L104">source</a></div>

```lean
def pPiece (t : List Char) : Option (List Char × List Char)
```

A math piece after its opening `$`: its content and the text after the closing `$`.

</div>

<div class="lean-decl" id="Esm.Document.Source.pSpecies">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.pSpecies" title="Esm.Document.Source.pSpecies"><code>pSpecies</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/Reaction.lean#L107-L117">source</a></div>

```lean
def pSpecies (R : RSurf) : List Char → Option (String × List Char)
```

A species: a math piece holding a name, or a bare run of letters and digits.

</div>

<div class="lean-decl" id="Esm.Document.Source.pTerm">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.pTerm" title="Esm.Document.Source.pTerm"><code>pTerm</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/Reaction.lean#L121-L133">source</a></div>

```lean
def pTerm (R : RSurf) : List Char → Option (Term × List Char)
```

A term: a math piece holding a number is the coefficient, and a species follows
after a space; otherwise the term is a species with coefficient 1.

</div>

<div class="lean-decl" id="Esm.Document.Source.pTerms">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.pTerms" title="Esm.Document.Source.pTerms"><code>pTerms</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/Reaction.lean#L136-L143">source</a></div>

```lean
def pTerms (R : RSurf) : Nat → List Char → Option (List Term × List Char)
```

Terms separated by ` + `.

</div>

<div class="lean-decl" id="Esm.Document.Source.pSide">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.pSide" title="Esm.Document.Source.pSide"><code>pSide</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/Reaction.lean#L146-L152">source</a></div>

```lean
def pSide (R : RSurf) (f : Nat) (s : List Char) : Option (Option (List Term) × List Char)
```

A side: the empty-set piece, or terms.

</div>

## Reading back

<div class="lean-decl" id="Esm.Document.Source.StopOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.StopOK" title="Esm.Document.Source.StopOK"><code>StopOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/Reaction.lean#L171-L172">source</a></div>

```lean
def StopOK (r : List Char) : Prop
```

What may follow a side: a space, `}` or `]`, and not ` + `.

</div>

## Accepted variants

<div class="lean-decl lean-theorem" id="Esm.Document.Source.pSpecies_math">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.pSpecies_math" title="Esm.Document.Source.pSpecies_math"><code>pSpecies_math</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/Reaction.lean#L294-L299">source</a></div>

```lean
theorem pSpecies_math (R : RSurf) (hR : R.OK) (n : String) (hn : nameOK n = true)
    (hd : (R.prm (.str n)).contains '$' = false) (r : List Char) :
    pSpecies R ('$' :: R.prm (.str n) ++ '$' :: r) = some (n, r)
```

**A species written as math reads as that species**, formula-shaped or not (the
printer writes a formula-shaped one bare).

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.pTerm_coef">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.pTerm_coef" title="Esm.Document.Source.pTerm_coef"><code>pTerm_coef</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/Reaction.lean#L303-L312">source</a></div>

```lean
theorem pTerm_coef (R : RSurf) (hR : R.OK) (c : JNum) (hc : numOK c = true)
    (hcd : (R.prm (.num c)).contains '$' = false) (n : String) (hn : nameOK n = true)
    (hq : isFormula n.toList = true ∨ (R.prm (.str n)).contains '$' = false) (r : List Char)
    (hr : r.head? = some ' ' ∨ r.head? = some '}' ∨ r.head? = some ']') :
    pTerm R ('$' :: R.prm (.num c) ++ '$' :: ' ' :: speciesTxt R n ++ r) = some (⟨n, c⟩, r)
```

**A coefficient written out reads as that coefficient**, 1 included (the printer
leaves 1 out).

</div>

<p class="lean-meta">This module also proves 12 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/Reaction.lean">the source</a>.</p>
