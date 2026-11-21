---
title: "Lines of text"
type: lean
lean_module: "Esm.Document.Source.Lines"
weight: 47
---

<p class="lean-meta">Lean module <code>Esm.Document.Source.Lines</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Lines.lean"><code>formal/Esm/Document/Source/Lines.lean</code></a> at <code>1b8dd9b3a909</code><br>Imports <code>Mathlib.Data.List.Basic</code></p>

Containers are line-oriented: a fenced block ends at the first line that starts with
its closing fence. [`heads`](#Esm.Document.Source.heads) lists the characters that start a line, so "no line of `s`
starts with a backtick" is `'`' ∉ heads true s`.

<div class="lean-decl" id="Esm.Document.Source.heads">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.heads" title="Esm.Document.Source.heads"><code>heads</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Lines.lean#L15-L17">source</a></div>

```lean
def heads : Bool → List Char → List Char
```

The characters that start a line of `s`: the first character when `s` starts at the
beginning of a line (`bol`), and every character right after a newline.

</div>

<div class="lean-decl" id="Esm.Document.Source.endBol">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.endBol" title="Esm.Document.Source.endBol"><code>endBol</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Lines.lean#L20-L23">source</a></div>

```lean
def endBol (bol : Bool) (s : List Char) : Bool
```

Whether the text after `s` starts at the beginning of a line.

</div>

## Decoding the input

A source file may start with a UTF-8 byte-order mark and may use CRLF line endings, as
editors on some systems write them. [`decodeText`](#Esm.Document.Source.decodeText) normalizes both before a reader lexes
the text: a leading U+FEFF is dropped, and when the first line ends in CRLF every CRLF
becomes LF. A text whose first line ends in a bare LF (everything the printers write) is
read as it is ([`decodeText_line`](#Esm.Document.Source.decodeText_line)), so a carriage return inside, say, a description still
reads back.

<div class="lean-decl" id="Esm.Document.Source.dropBOM">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.dropBOM" title="Esm.Document.Source.dropBOM"><code>dropBOM</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Lines.lean#L57-L59">source</a></div>

```lean
def dropBOM : List Char → List Char
```

The text with a leading byte-order mark removed.

</div>

<div class="lean-decl" id="Esm.Document.Source.firstCRLF">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.firstCRLF" title="Esm.Document.Source.firstCRLF"><code>firstCRLF</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Lines.lean#L62-L64">source</a></div>

```lean
def firstCRLF : List Char → Bool
```

Whether the first line ends in CRLF.

</div>

<div class="lean-decl" id="Esm.Document.Source.unCRLF">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.unCRLF" title="Esm.Document.Source.unCRLF"><code>unCRLF</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Lines.lean#L67-L70">source</a></div>

```lean
def unCRLF : List Char → List Char
```

Every CRLF as LF.

</div>

<div class="lean-decl" id="Esm.Document.Source.decodeText">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.decodeText" title="Esm.Document.Source.decodeText"><code>decodeText</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Lines.lean#L74-L75">source</a></div>

```lean
def decodeText (s : List Char) : List Char
```

**The input decoding**: no byte-order mark, and LF line endings when the first line
ends in CRLF.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.decodeText_line">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.decodeText_line" title="Esm.Document.Source.decodeText_line"><code>decodeText_line</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Lines.lean#L86-L96">source</a></div>

```lean
theorem decodeText_line (l t : List Char) (hn : '\n' ∉ l) (hr : '\r' ∉ l)
    (hb : l.head? ≠ some '\uFEFF') : decodeText (l ++ '\n' :: t) = l ++ '\n' :: t
```

A text whose first line has no carriage return and does not start with a byte-order
mark is read as written.

</div>

<p class="lean-meta">This module also proves 5 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Lines.lean">the source</a>.</p>
