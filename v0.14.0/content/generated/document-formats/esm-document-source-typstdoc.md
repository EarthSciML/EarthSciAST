---
title: "Typst documents: printing, parsing, and the round trip"
type: lean
lean_module: "Esm.Document.Source.TypstDoc"
weight: 61
---

<p class="lean-meta">Lean module <code>Esm.Document.Source.TypstDoc</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/TypstDoc.lean"><code>formal/Esm/Document/Source/TypstDoc.lean</code></a> at <code>ffd5aee2f868</code><br>Imports <a href="/generated/document-formats/esm-document-source-typst"><code>Esm.Document.Source.Typst</code></a>, <a href="/generated/document-formats/esm-document-source-markdowndoc"><code>Esm.Document.Source.MarkdownDoc</code></a></p>

[`printTyp`](#Esm.Document.Source.Typ.printTyp) spells a canonical ESM document as Typst, [`parseTyp`](#Esm.Document.Source.Typ.parseTyp) reads it back, and
[`parseTyp_printTyp`](#Esm.Document.Source.Typ.parseTyp_printTyp) is the round trip, composed exactly as for Markdown
([`Esm.Document.Source.MarkdownDoc`](/generated/document-formats/esm-document-source-markdowndoc)) with the Typst math theorem `parseTypst_printTypst`.

## Equations in Typst math

<div class="lean-decl" id="Esm.Document.Source.Typ.prT">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.prT" title="Esm.Document.Source.Typ.prT"><code>prT</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/TypstDoc.lean#L21-L24">source</a></div>

```lean
def prT (S : Sym) (e : Eqn) : String
```

An equation's math text: its `_comment` as a `//` comment line, then the equation.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.oneT">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.oneT" title="Esm.Document.Source.Typ.oneT"><code>oneT</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/TypstDoc.lean#L28-L31">source</a></div>

```lean
def oneT (S : Sym) (c : Option String) (body : List Char) : Option (List Eqn)
```

One display in Typst math: one equation, or (an accepted variant) several rows
separated by `\` with `&` alignment, read by [`cookRows`](/generated/document-formats/esm-document-source-multiline#Esm.Document.Source.cookRows) ([`cookRows_layout`](/generated/document-formats/esm-document-source-multiline#Esm.Document.Source.cookRows_layout)).

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.ckT">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.ckT" title="Esm.Document.Source.Typ.ckT"><code>ckT</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/TypstDoc.lean#L34-L37">source</a></div>

```lean
def ckT (S : Sym) (raw : String) : Option (List Eqn)
```

**Read the math text of a display equation** under the symbol table `S`.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.prTx">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.prTx" title="Esm.Document.Source.Typ.prTx"><code>prTx</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/TypstDoc.lean#L41">source</a></div>

```lean
def prTx : Sym → MC → MR
```

A math entry's text: an equation's Typst math ([`prT`](#Esm.Document.Source.Typ.prT)), or a reaction with its rate
as Typst math.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.ckTx">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.ckTx" title="Esm.Document.Source.Typ.ckTx"><code>ckTx</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/TypstDoc.lean#L44">source</a></div>

```lean
def ckTx : Sym → MR → Option (List MC)
```

Read a math entry's text.

</div>

## What Typst spells natively

<div class="lean-decl" id="Esm.Document.Source.Typ.capsT">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.capsT" title="Esm.Document.Source.Typ.capsT"><code>capsT</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/TypstDoc.lean#L52-L62">source</a></div>

```lean
def capsT : Caps
```

The Typst container's predicates: front-matter keys and attributes are named
arguments (identifiers that are not keywords); an equation's Typst math must not contain
`$` nor start with `//` (it may span lines: a code value inside an escape node does). Descriptions and component names are always
spellable (escapes).

</div>

## The document

<div class="lean-decl" id="Esm.Document.Source.Typ.headerT">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.headerT" title="Esm.Document.Source.Typ.headerT"><code>headerT</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/TypstDoc.lean#L91">source</a></div>

```lean
def headerT (front : List (String × Json)) : List Char
```

The header: the package import, then `#show: esm-document.with(…)` with the
front-matter entries.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.canonSegs">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.canonSegs" title="Esm.Document.Source.Typ.canonSegs"><code>canonSegs</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/TypstDoc.lean#L94-L95">source</a></div>

```lean
def canonSegs (its : List RItem) : List Seg
```

The canonical layout: each construct after a blank line.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.printTyp">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.printTyp" title="Esm.Document.Source.Typ.printTyp"><code>printTyp</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/TypstDoc.lean#L98-L100">source</a></div>

```lean
def printTyp (d : Json) : String
```

**Print a document as Typst.**

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.lexDoc">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.lexDoc" title="Esm.Document.Source.Typ.lexDoc"><code>lexDoc</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/TypstDoc.lean#L103-L111">source</a></div>

```lean
def lexDoc (s : List Char) : Option (List (String × Json) × List RItem)
```

Read the header and the constructs.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.parseTyp">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.parseTyp" title="Esm.Document.Source.Typ.parseTyp"><code>parseTyp</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/TypstDoc.lean#L115-L119">source</a></div>

```lean
def parseTyp (s : String) : Option Json
```

**Read a Typst document**, after dropping a byte-order mark and reading CRLF line
endings as LF ([`decodeText`](/generated/document-formats/esm-document-source-lines#Esm.Document.Source.decodeText)).

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.Typ.decode_header">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.Typ.decode_header" title="Esm.Document.Source.Typ.decode_header"><code>decode_header</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/TypstDoc.lean#L185-L190">source</a></div>

```lean
theorem decode_header (X : List Char) : decodeText (header ++ X) = header ++ X
```

A document with the header is read as written: [`decodeText`](/generated/document-formats/esm-document-source-lines#Esm.Document.Source.decodeText) leaves it alone.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.Typ.lexDoc_front">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.Typ.lexDoc_front" title="Esm.Document.Source.Typ.lexDoc_front"><code>lexDoc_front</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/TypstDoc.lean#L198-L210">source</a></div>

```lean
theorem lexDoc_front (front : List (String × Json)) (hf : ∀ a ∈ front, argOK a = true)
    (segs : List Seg) (hv : Valid true segs) :
    lexDoc (headerT front ++ render segs) = some (front, segItems segs)
```

**The header and the body read back.**

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.Typ.items_ok">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.Typ.items_ok" title="Esm.Document.Source.Typ.items_ok"><code>items_ok</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/TypstDoc.lean#L239-L280">source</a></div>

```lean
theorem items_ok (D : Doc MC) (h : DocOK capsT D) :
    ∀ it ∈ items (rawDoc prTx D), itemOK it = true
```

Every construct of the printed skeleton satisfies [`itemOK`](/generated/document-formats/esm-document-source-typst#Esm.Document.Source.Typ.itemOK).

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.Typ.parseTyp_printTyp">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.Typ.parseTyp_printTyp" title="Esm.Document.Source.Typ.parseTyp_printTyp"><code>parseTyp_printTyp</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/TypstDoc.lean#L284-L332">source</a></div>

```lean
theorem parseTyp_printTyp (d : Json) (hd : canonDoc d = true) : parseTyp (printTyp d) = some d
```

**The Typst round trip.** Every ESM document in canonical form reads back from its
Typst spelling.

</div>

## Prose and labels do not change the parse

<div class="lean-decl lean-theorem" id="Esm.Document.Source.Typ.parseTyp_body">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.Typ.parseTyp_body" title="Esm.Document.Source.Typ.parseTyp_body"><code>parseTyp_body</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/TypstDoc.lean#L343-L349">source</a></div>

```lean
theorem parseTyp_body (front : List (String × Json)) (hf : ∀ a ∈ front, argOK a = true)
    (segs : List Seg) (hv : Valid true segs) :
    parseTyp (String.ofList (headerT front ++ render segs)) = parseItemsT front (segItems segs)
```

**The parse of a Typst document depends only on its front matter and its sequence of
constructs**: not on the prose between them, and not on equation labels.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.Typ.parseTyp_insert_prose">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.Typ.parseTyp_insert_prose" title="Esm.Document.Source.Typ.parseTyp_insert_prose"><code>parseTyp_insert_prose</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/TypstDoc.lean#L366-L370">source</a></div>

```lean
theorem parseTyp_insert_prose (front : List (String × Json)) (hf : ∀ a ∈ front, argOK a = true)
    (a b : List Seg) (p : List Char) (h₁ : Valid true (a ++ b)) (h₂ : Valid true (a ++ .prose p :: b)) :
    parseTyp (String.ofList (headerT front ++ render (a ++ .prose p :: b))) =
      parseTyp (String.ofList (headerT front ++ render (a ++ b)))
```

**Inserting prose does not change the parse.**

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.Typ.parseTyp_label">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.Typ.parseTyp_label" title="Esm.Document.Source.Typ.parseTyp_label"><code>parseTyp_label</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/TypstDoc.lean#L373-L378">source</a></div>

```lean
theorem parseTyp_label (front : List (String × Json)) (hf : ∀ a ∈ front, argOK a = true)
    (a b : List Seg) (raw : String) (l : List Char) (h₁ : Valid true (a ++ .item (.eqn raw) :: b))
    (h₂ : Valid true (a ++ .labeled raw l :: b)) :
    parseTyp (String.ofList (headerT front ++ render (a ++ .labeled raw l :: b))) =
      parseTyp (String.ofList (headerT front ++ render (a ++ .item (.eqn raw) :: b)))
```

**Adding an equation label does not change the parse.**

</div>

<p class="lean-meta">This module also proves 12 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/TypstDoc.lean">the source</a>.</p>
