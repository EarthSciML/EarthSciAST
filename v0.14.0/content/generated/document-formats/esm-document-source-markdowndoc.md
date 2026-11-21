---
title: "Markdown documents: printing, parsing, and the round trip"
type: lean
lean_module: "Esm.Document.Source.MarkdownDoc"
weight: 59
---

<p class="lean-meta">Lean module <code>Esm.Document.Source.MarkdownDoc</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/MarkdownDoc.lean"><code>formal/Esm/Document/Source/MarkdownDoc.lean</code></a> at <code>ffd5aee2f868</code><br>Imports <a href="/generated/document-formats/esm-document-source-markdown"><code>Esm.Document.Source.Markdown</code></a>, <a href="/generated/document-formats/esm-document-source-equation"><code>Esm.Document.Source.Equation</code></a>, <a href="/generated/document-formats/esm-document-source-multiline"><code>Esm.Document.Source.MultiLine</code></a></p>

[`printMd`](#Esm.Document.Source.Md.printMd) spells a canonical ESM document as Markdown, [`parseMd`](#Esm.Document.Source.Md.parseMd) reads it back, and
[`parseMd_printMd`](#Esm.Document.Source.Md.parseMd_printMd) is the round trip. The layers compose:

1. `toDoc capsMd` (the skeleton, with the path-keyed fallback for anything Markdown
   cannot spell natively) and [`ofDoc`](/generated/document-formats/esm-document-source-skeleton#Esm.Document.Source.ofDoc) — [`ofDoc_toDoc`](/generated/document-formats/esm-document-source-skeletonrt#Esm.Document.Source.ofDoc_toDoc);
2. `rawDoc prMdx` (each equation, and each reaction's rate, as LaTeX under its
   component's symbol table) and `cookDoc ckMdx` — [`cookDoc_rawDoc`](/generated/document-formats/esm-document-source-items#Esm.Document.Source.cookDoc_rawDoc), with the Phase 2
   theorem `parseLatex_printLatex`;
3. [`items`](/generated/document-formats/esm-document-source-items#Esm.Document.Source.items) and [`unitems`](/generated/document-formats/esm-document-source-items#Esm.Document.Source.unitems) — [`unitems_items`](/generated/document-formats/esm-document-source-items#Esm.Document.Source.unitems_items);
4. the text: front matter, then the constructs separated by blank lines — [`lex_render`](/generated/document-formats/esm-document-source-markdown#Esm.Document.Source.Md.lex_render).

## Equations in LaTeX

<div class="lean-decl" id="Esm.Document.Source.Md.latexOf">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.latexOf" title="Esm.Document.Source.Md.latexOf"><code>latexOf</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/MarkdownDoc.lean#L27">source</a></div>

```lean
def latexOf (S : Sym) (e : Eqn) : List Char
```

An equation's LaTeX under the symbol table `S`.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.prMd">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.prMd" title="Esm.Document.Source.Md.prMd"><code>prMd</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/MarkdownDoc.lean#L30-L33">source</a></div>

```lean
def prMd (S : Sym) (e : Eqn) : String
```

An equation's math text: its `_comment` as a LaTeX comment line, then the equation.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.envs">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.envs" title="Esm.Document.Source.Md.envs"><code>envs</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/MarkdownDoc.lean#L36-L38">source</a></div>

```lean
def envs : List (String × Bool)
```

The multi-line environments: `true` when all rows are one equation.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.envOf">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.envOf" title="Esm.Document.Source.Md.envOf"><code>envOf</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/MarkdownDoc.lean#L44-L51">source</a></div>

```lean
def envOf (body : List Char) : Option (Bool × List Char)
```

A display that is one multi-line environment: whether its rows are one equation, and
the environment's body.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.withComment">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.withComment" title="Esm.Document.Source.Md.withComment"><code>withComment</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/MarkdownDoc.lean#L54-L56">source</a></div>

```lean
def withComment (c : Option String) : List Eqn → List Eqn
```

The comment goes to the first equation of a display.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.oneMd">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.oneMd" title="Esm.Document.Source.Md.oneMd"><code>oneMd</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/MarkdownDoc.lean#L60-L66">source</a></div>

```lean
def oneMd (S : Sym) (c : Option String) (body : List Char) : Option (List Eqn)
```

One display in LaTeX: a multi-line environment (an accepted variant), or one
equation.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.ckMd">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.ckMd" title="Esm.Document.Source.Md.ckMd"><code>ckMd</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/MarkdownDoc.lean#L70-L73">source</a></div>

```lean
def ckMd (S : Sym) (raw : String) : Option (List Eqn)
```

**Read the math text of a display equation** under the symbol table `S`: an
optional leading comment line `% …` (the `_comment`), then the equation.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.prMdx">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.prMdx" title="Esm.Document.Source.Md.prMdx"><code>prMdx</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/MarkdownDoc.lean#L77">source</a></div>

```lean
def prMdx : Sym → MC → MR
```

A math entry's text: an equation's LaTeX ([`prMd`](#Esm.Document.Source.Md.prMd)), or a reaction with its rate as
LaTeX.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.ckMdx">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.ckMdx" title="Esm.Document.Source.Md.ckMdx"><code>ckMdx</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/MarkdownDoc.lean#L80">source</a></div>

```lean
def ckMdx : Sym → MR → Option (List MC)
```

Read a math entry's text.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.commentOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.commentOK" title="Esm.Document.Source.Md.commentOK"><code>commentOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/MarkdownDoc.lean#L83-L85">source</a></div>

```lean
def commentOK : Option String → Bool
```

A comment Markdown can carry on its LaTeX comment line.

</div>

## What Markdown spells natively

<div class="lean-decl" id="Esm.Document.Source.Md.dqOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.dqOK" title="Esm.Document.Source.Md.dqOK"><code>dqOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/MarkdownDoc.lean#L94-L96">source</a></div>

```lean
def dqOK : Json → Bool
```

A value remark-directive reads as written in a double-quoted attribute: a string
whose characters the YAML printer writes as themselves (no `"`, which would end the
quoted value; no backslash, tab, newline, carriage return or other character written as
an escape, which remark-directive would not decode) and without `&` (a character
reference would be decoded); any other value.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.capsMd">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.capsMd" title="Esm.Document.Source.Md.capsMd"><code>capsMd</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/MarkdownDoc.lean#L102-L117">source</a></div>

```lean
def capsMd : Caps
```

The Markdown container's predicates. A description must not contain a line that
would close its fence ([`noStop`](/generated/document-formats/esm-document-source-text#Esm.Document.Source.noStop); CommonMark also closes a fence indented by up to three
spaces, and treats a carriage return as a line end). An equation's LaTeX must be one
line without `$` and not start with `%`.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.Md.ckMd_prMd">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.Md.ckMd_prMd" title="Esm.Document.Source.Md.ckMd_prMd"><code>ckMd_prMd</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/MarkdownDoc.lean#L133-L154">source</a></div>

```lean
theorem ckMd_prMd (S : Sym) (e : Eqn) (hc : capsMd.eqn S e = true) (hl : isE e.lhs = true)
    (hr : isE e.rhs = true) : ckMd S (prMd S e) = some [e]
```

**An equation reads back from its LaTeX**, comment included.

</div>

## The document

<div class="lean-decl" id="Esm.Document.Source.Md.frontMd">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.frontMd" title="Esm.Document.Source.Md.frontMd"><code>frontMd</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/MarkdownDoc.lean#L159-L160">source</a></div>

```lean
def frontMd (front : List (String × Json)) : List Char
```

The front matter: `---`, the YAML of the entries, `---`.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.canonSegs">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.canonSegs" title="Esm.Document.Source.Md.canonSegs"><code>canonSegs</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/MarkdownDoc.lean#L164-L165">source</a></div>

```lean
def canonSegs (its : List RItem) : List Seg
```

The canonical layout: each construct after a blank line, a declaration on a line of
its own.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.printMd">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.printMd" title="Esm.Document.Source.Md.printMd"><code>printMd</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/MarkdownDoc.lean#L168-L170">source</a></div>

```lean
def printMd (d : Json) : String
```

**Print a document as Markdown.**

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.lexDoc">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.lexDoc" title="Esm.Document.Source.Md.lexDoc"><code>lexDoc</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/MarkdownDoc.lean#L173-L184">source</a></div>

```lean
def lexDoc (s : List Char) : Option (List (String × Json) × List RItem)
```

Read the front matter and the constructs.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.parseMd">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.parseMd" title="Esm.Document.Source.Md.parseMd"><code>parseMd</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/MarkdownDoc.lean#L188-L192">source</a></div>

```lean
def parseMd (s : String) : Option Json
```

**Read a Markdown document**, after dropping a byte-order mark and reading CRLF line
endings as LF ([`decodeText`](/generated/document-formats/esm-document-source-lines#Esm.Document.Source.decodeText)).

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.Md.lexDoc_front">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.Md.lexDoc_front" title="Esm.Document.Source.Md.lexDoc_front"><code>lexDoc_front</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/MarkdownDoc.lean#L245-L266">source</a></div>

```lean
theorem lexDoc_front (front : List (String × Json)) (hf : jwf (.obj front) = true)
    (segs : List Seg) (hv : Valid true segs) :
    lexDoc (frontMd front ++ render segs) = some (front, segItems segs)
```

**The front matter and the body read back.**

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.Md.decode_front">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.Md.decode_front" title="Esm.Document.Source.Md.decode_front"><code>decode_front</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/MarkdownDoc.lean#L269-L274">source</a></div>

```lean
theorem decode_front (front : List (String × Json)) (X : List Char) :
    decodeText (frontMd front ++ X) = frontMd front ++ X
```

A document with front matter is read as written: [`decodeText`](/generated/document-formats/esm-document-source-lines#Esm.Document.Source.decodeText) leaves it alone.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.Md.items_ok">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.Md.items_ok" title="Esm.Document.Source.Md.items_ok"><code>items_ok</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/MarkdownDoc.lean#L301-L349">source</a></div>

```lean
theorem items_ok (D : Doc MC) (h : DocOK capsMd D) :
    ∀ it ∈ items (rawDoc prMdx D), itemOK it = true
```

Every construct of the printed skeleton satisfies [`itemOK`](/generated/document-formats/esm-document-source-markdown#Esm.Document.Source.Md.itemOK).

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.Md.parseMd_printMd">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.Md.parseMd_printMd" title="Esm.Document.Source.Md.parseMd_printMd"><code>parseMd_printMd</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/MarkdownDoc.lean#L353-L395">source</a></div>

```lean
theorem parseMd_printMd (d : Json) (hd : canonDoc d = true) : parseMd (printMd d) = some d
```

**The Markdown round trip.** Every ESM document in canonical form reads back from its
Markdown spelling.

</div>

## Prose and labels do not change the parse

<div class="lean-decl" id="Esm.Document.Source.Md.parseItemsMd">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.parseItemsMd" title="Esm.Document.Source.Md.parseItemsMd"><code>parseItemsMd</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/MarkdownDoc.lean#L400-L403">source</a></div>

```lean
def parseItemsMd (front : List (String × Json)) (its : List RItem) : Option Json
```

What a document says, given its front matter and its constructs.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.Md.parseMd_body">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.Md.parseMd_body" title="Esm.Document.Source.Md.parseMd_body"><code>parseMd_body</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/MarkdownDoc.lean#L407-L413">source</a></div>

```lean
theorem parseMd_body (front : List (String × Json)) (hf : jwf (.obj front) = true)
    (segs : List Seg) (hv : Valid true segs) :
    parseMd (String.ofList (frontMd front ++ render segs)) = parseItemsMd front (segItems segs)
```

**The parse of a Markdown document depends only on its front matter and its sequence
of constructs**: not on the prose between them, and not on equation labels.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.Md.parseMd_eq_of_items">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.Md.parseMd_eq_of_items" title="Esm.Document.Source.Md.parseMd_eq_of_items"><code>parseMd_eq_of_items</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/MarkdownDoc.lean#L416-L420">source</a></div>

```lean
theorem parseMd_eq_of_items (front : List (String × Json)) (hf : jwf (.obj front) = true)
    (s₁ s₂ : List Seg) (h₁ : Valid true s₁) (h₂ : Valid true s₂) (h : segItems s₁ = segItems s₂) :
    parseMd (String.ofList (frontMd front ++ render s₁)) =
      parseMd (String.ofList (frontMd front ++ render s₂))
```

Two valid documents with the same constructs parse alike.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.Md.segItems_prose">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.Md.segItems_prose" title="Esm.Document.Source.Md.segItems_prose"><code>segItems_prose</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/MarkdownDoc.lean#L423-L425">source</a></div>

```lean
theorem segItems_prose (a b : List Seg) (p : List Char) :
    segItems (a ++ .prose p :: b) = segItems (a ++ b)
```

Inserting prose leaves the constructs as they were.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.Md.segItems_label">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.Md.segItems_label" title="Esm.Document.Source.Md.segItems_label"><code>segItems_label</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/MarkdownDoc.lean#L428-L430">source</a></div>

```lean
theorem segItems_label (a b : List Seg) (raw : String) (l : List Char) :
    segItems (a ++ .labeled raw l :: b) = segItems (a ++ .item (.eqn raw) :: b)
```

Labelling an equation leaves the constructs as they were.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.Md.parseMd_insert_prose">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.Md.parseMd_insert_prose" title="Esm.Document.Source.Md.parseMd_insert_prose"><code>parseMd_insert_prose</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/MarkdownDoc.lean#L434-L438">source</a></div>

```lean
theorem parseMd_insert_prose (front : List (String × Json)) (hf : jwf (.obj front) = true)
    (a b : List Seg) (p : List Char) (h₁ : Valid true (a ++ b)) (h₂ : Valid true (a ++ .prose p :: b)) :
    parseMd (String.ofList (frontMd front ++ render (a ++ .prose p :: b))) =
      parseMd (String.ofList (frontMd front ++ render (a ++ b)))
```

**Inserting prose does not change the parse** (where the result is still valid: the
prose is [`Inert`](/generated/document-formats/esm-document-source-markdown#Esm.Document.Source.Md.Inert) and block constructs still start a line).

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.Md.parseMd_label">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.Md.parseMd_label" title="Esm.Document.Source.Md.parseMd_label"><code>parseMd_label</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/MarkdownDoc.lean#L441-L446">source</a></div>

```lean
theorem parseMd_label (front : List (String × Json)) (hf : jwf (.obj front) = true)
    (a b : List Seg) (raw : String) (l : List Char) (h₁ : Valid true (a ++ .item (.eqn raw) :: b))
    (h₂ : Valid true (a ++ .labeled raw l :: b)) :
    parseMd (String.ofList (frontMd front ++ render (a ++ .labeled raw l :: b))) =
      parseMd (String.ofList (frontMd front ++ render (a ++ .item (.eqn raw) :: b)))
```

**Adding an equation label does not change the parse.**

</div>

## Multi-line equations

<div class="lean-decl lean-theorem" id="Esm.Document.Source.Md.TN_joinRows">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.Md.TN_joinRows" title="Esm.Document.Source.Md.TN_joinRows"><code>TN_joinRows</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/MarkdownDoc.lean#L456-L462">source</a></div>

```lean
theorem TN_joinRows : ∀ (rows : List (List Tok)), (∀ x ∈ rows, Latex.TN x) → Latex.TN (joinRows rows)
```

Rows joined by row breaks keep `\times` before a bracket, `&` or a row break.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.Md.TN_rowsToks">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.Md.TN_rowsToks" title="Esm.Document.Source.Md.TN_rowsToks"><code>TN_rowsToks</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/MarkdownDoc.lean#L465-L481">source</a></div>

```lean
theorem TN_rowsToks (Ls : List Layout) (h : ∀ L ∈ Ls, Latex.TN L.toks) : Latex.TN (rowsToks Ls)
```

The pieces of a layout of printed tokens keep `\times` where the printer put it.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.Md.ckMd_aligned">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.Md.ckMd_aligned" title="Esm.Document.Source.Md.ckMd_aligned"><code>ckMd_aligned</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/MarkdownDoc.lean#L486-L543">source</a></div>

```lean
theorem ckMd_aligned (S : Sym) (Ls : List Layout) (es : List Eqn)
    (hL : ∀ L ∈ Ls, L.OK) (hne : Ls ≠ [])
    (h : List.Forall₂ (fun L e => L.toks = print .latex S (eqExpr e) ∧ isE e.lhs = true ∧
      isE e.rhs = true) Ls es) :
    ckMd S (String.ofList ("\\begin{aligned}".toList ++ Latex.render (rowsToks Ls) ++
      "\\end{aligned}".toList)) = some (es.map (fun e => ⟨none, e.lhs, e.rhs⟩))
```

**The `aligned` variant reads as the equations it lays out**: a display
`\begin{aligned} … \end{aligned}` whose rows lay out the canonical LaTeX of equations
([`Layout`](/generated/document-formats/esm-document-source-multiline#Esm.Document.Source.Layout)) reads back as exactly those equations.

</div>

<p class="lean-meta">This module also proves 9 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Source/MarkdownDoc.lean">the source</a>.</p>
