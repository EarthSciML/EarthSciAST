---
title: "Text scanning shared by the containers"
type: lean
lean_module: "Esm.Document.Source.Text"
weight: 53
---

<p class="lean-meta">Lean module <code>Esm.Document.Source.Text</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Text.lean"><code>formal/Esm/Document/Source/Text.lean</code></a> at <code>1b8dd9b3a909</code><br>Imports <a href="/generated/document-formats/esm-document-source-facts"><code>Esm.Document.Source.Facts</code></a>, <a href="/generated/document-formats/esm-document-source-lines"><code>Esm.Document.Source.Lines</code></a>, <a href="/generated/document-formats/esm-document-yaml"><code>Esm.Document.Yaml</code></a>, <a href="/generated/document-formats/esm-document-typstdict"><code>Esm.Document.TypstDict</code></a>, <a href="/generated/document-formats/esm-document-math-roundtriplatex"><code>Esm.Document.Math.RoundTripLatex</code></a>, <a href="/generated/document-formats/esm-document-math-roundtriptypst"><code>Esm.Document.Math.RoundTripTypst</code></a></p>

Prefixes, lines, fenced bodies ended by a closing line, and the facts the containers'
round trips use about them.

## Prefixes

<div class="lean-decl" id="Esm.Document.Source.pre">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.pre" title="Esm.Document.Source.pre"><code>pre</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Text.lean#L22-L25">source</a></div>

```lean
def pre : List Char → List Char → Bool
```

`p` is a prefix of `s`.

</div>

<div class="lean-decl" id="Esm.Document.Source.hasSub">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.hasSub" title="Esm.Document.Source.hasSub"><code>hasSub</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Text.lean#L33">source</a></div>

```lean
def hasSub (p s : List Char) : Bool
```

`p` occurs in `s`.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.pre_app_long">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.pre_app_long" title="Esm.Document.Source.pre_app_long"><code>pre_app_long</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Text.lean#L36-L41">source</a></div>

```lean
theorem pre_app_long : ∀ (p x t : List Char), p.length ≤ x.length → pre p (x ++ t) = pre p x
```

A prefix no longer than `x` is decided within `x`.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.pre_app_false">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.pre_app_false" title="Esm.Document.Source.pre_app_false"><code>pre_app_false</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Text.lean#L52-L62">source</a></div>

```lean
theorem pre_app_false : ∀ (p x t : List Char), pre p x = false → pre x p = false →
    pre p (x ++ t) = false
```

Two texts neither of which starts the other differ before either ends.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.pre_line">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.pre_line" title="Esm.Document.Source.pre_line"><code>pre_line</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Text.lean#L75-L92">source</a></div>

```lean
theorem pre_line {stop x : List Char} (hn : '\n' ∉ stop) (hx : '\n' ∈ x) (y : List Char) :
    pre stop (x ++ y) = pre stop x
```

A prefix without a newline is decided within the first line.

</div>

## Lines

<div class="lean-decl" id="Esm.Document.Source.splitLine">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.splitLine" title="Esm.Document.Source.splitLine"><code>splitLine</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Text.lean#L97-L99">source</a></div>

```lean
def splitLine : List Char → List Char × List Char
```

The rest of the current line, and what follows its newline.

</div>

<div class="lean-decl" id="Esm.Document.Source.noStop">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.noStop" title="Esm.Document.Source.noStop"><code>noStop</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Text.lean#L133-L138">source</a></div>

```lean
def noStop (stop : List Char) (s : List Char) : Bool
```

No line of `s` starts with `stop`.

</div>

<div class="lean-decl" id="Esm.Document.Source.untilStop">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.untilStop" title="Esm.Document.Source.untilStop"><code>untilStop</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Text.lean#L142-L150">source</a></div>

```lean
def untilStop (stop : List Char) : Nat → List Char → Option (List Char × List Char × List Char)
```

Lines up to the first one that starts with `stop`: the lines before it (each with
its newline), the rest of the closing line, and the text after the closing line.

</div>

<div class="lean-decl" id="Esm.Document.Source.Lines">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Lines" title="Esm.Document.Source.Lines"><code>Lines</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Text.lean#L153">source</a></div>

```lean
def Lines (body : List Char) : Prop
```

Complete lines: empty, or ending with a newline.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.untilStop_body">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.untilStop_body" title="Esm.Document.Source.untilStop_body"><code>untilStop_body</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Text.lean#L203-L234">source</a></div>

```lean
theorem untilStop_body (stop : List Char) (hs : stop ≠ []) (hn : '\n' ∉ stop) :
    ∀ (body sl t : List Char), Lines body → noStop stop body = true → '\n' ∉ sl →
      ∀ f, body.length + stop.length < f →
        untilStop stop f (body ++ stop ++ sl ++ '\n' :: t) = some (body, sl, t)
```

**A fenced body is read back** up to its closing line.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.noStop_of_heads">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.noStop_of_heads" title="Esm.Document.Source.noStop_of_heads"><code>noStop_of_heads</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Text.lean#L244-L261">source</a></div>

```lean
theorem noStop_of_heads {c : Char} (p : List Char) (s : List Char) (h : c ∉ heads true s) :
    noStop (c :: p) s = true
```

A line never starts with `stop` when no line starts with its first character.

</div>

<p class="lean-meta">This module also proves 16 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Text.lean">the source</a>.</p>
