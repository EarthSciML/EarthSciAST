---
title: "Line heads of the YAML spelling"
type: lean
lean_module: "Esm.Document.Source.YamlLines"
weight: 54
---

<p class="lean-meta">Lean module <code>Esm.Document.Source.YamlLines</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/YamlLines.lean"><code>formal/Esm/Document/Source/YamlLines.lean</code></a> at <code>1b8dd9b3a909</code><br>Imports <a href="/generated/document-formats/esm-document-yaml"><code>Esm.Document.Yaml</code></a>, <a href="/generated/document-formats/esm-document-source-lines"><code>Esm.Document.Source.Lines</code></a></p>

Facts about which characters start a line of `Yaml.encode v`, used to show a YAML block
can sit inside a Markdown code fence ([`yaml_heads_tick`](#Esm.Document.Source.yaml_heads_tick)) or between front-matter `---`
delimiters ([`yaml_heads_dash`](#Esm.Document.Source.yaml_heads_dash)), and that it ends at the start of a line ([`yaml_ends`](#Esm.Document.Source.yaml_ends)).

## No raw newlines in scalars and keys

<div class="lean-decl lean-theorem" id="Esm.Document.Source.mathOK_noNL">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.mathOK_noNL" title="Esm.Document.Source.mathOK_noNL"><code>mathOK_noNL</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/YamlLines.lean#L70-L74">source</a></div>

```lean
theorem mathOK_noNL {s : String} (h : Json.mathOK s = true) : '\n' ∉ s.toList
```

Math text a container can delimit has no newline.

</div>

## Line heads

<div class="lean-decl" id="Esm.Document.Source.HeadsP">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.HeadsP" title="Esm.Document.Source.HeadsP"><code>HeadsP</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/YamlLines.lean#L86">source</a></div>

```lean
def HeadsP (p : Char → Prop) (l : List Char) : Prop
```

Every character that starts a line of `l`, wherever `l` starts, satisfies `p`.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.HeadsP.cons_mid">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.HeadsP.cons_mid" title="Esm.Document.Source.HeadsP.cons_mid"><code>HeadsP.cons_mid</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/YamlLines.lean#L105-L111">source</a></div>

```lean
theorem HeadsP.cons_mid {p : Char → Prop} {x : Char} {r : List Char} (hx : p x) (hn : x ≠ '\n')
    (hr : ∀ c ∈ heads false r, p c) : HeadsP p (x :: r)
```

A first character that is not a newline: what follows is read mid-line.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.HeadsP.line">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.HeadsP.line" title="Esm.Document.Source.HeadsP.line"><code>HeadsP.line</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/YamlLines.lean#L130-L134">source</a></div>

```lean
theorem HeadsP.line {p : Char → Prop} {x : Char} (hx : p x) (hxn : x ≠ '\n') (hn : p '\n')
    {t : List Char} (ht : '\n' ∉ t) : HeadsP p (x :: (t ++ ['\n']))
```

One line `x :: t` ending in a newline.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.HeadsP.scalarLine">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.HeadsP.scalarLine" title="Esm.Document.Source.HeadsP.scalarLine"><code>HeadsP.scalarLine</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/YamlLines.lean#L137-L139">source</a></div>

```lean
theorem HeadsP.scalarLine {p : Char → Prop} (hs : p ' ') (hn : p '\n') {x : List Char}
    (hx : '\n' ∉ x) : HeadsP p (' ' :: (x ++ ['\n']))
```

A line ` x` ending in a newline, where `x` has no newline.

</div>

<div class="lean-decl" id="Esm.Document.Source.Good">
<div class="lean-decl-head"><span class="lean-kind">abbrev</span> <a class="lean-name" href="#Esm.Document.Source.Good" title="Esm.Document.Source.Good"><code>Good</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/YamlLines.lean#L142">source</a></div>

```lean
abbrev Good (c : Char) : Prop
```

Not a backtick and not a dash.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.items_good">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.items_good" title="Esm.Document.Source.items_good"><code>items_good</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/YamlLines.lean#L210-L220">source</a></div>

```lean
theorem items_good (m : Nat) : ∀ l : List Json, Json.WFmList l → HeadsP Good (encItems (m + 1) l)
```

At a positive indentation every item line starts with a space.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.items_tick">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.items_tick" title="Esm.Document.Source.items_tick"><code>items_tick</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/YamlLines.lean#L232-L237">source</a></div>

```lean
theorem items_tick : ∀ l : List Json, Json.WFmList l → HeadsP (· ≠ '`') (encItems 0 l)
```

At indentation 0 an item line starts with `-`, never a backtick.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.inline_head">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.inline_head" title="Esm.Document.Source.inline_head"><code>inline_head</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/YamlLines.lean#L241-L250">source</a></div>

```lean
theorem inline_head (v : Json) (hv : v.WFm) (hi : isInl v = true) :
    ∃ c t, Yaml.inline v = c :: t ∧ c ≠ '`' ∧ c ≠ '\n'
```

A scalar or empty container starts with a character that is neither a backtick nor
a newline. (A number needs `WF`: an out-of-range digit could print as a backtick.)

</div>

## Line ends

## The YAML spelling

<div class="lean-decl lean-theorem" id="Esm.Document.Source.yaml_heads_tick">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.yaml_heads_tick" title="Esm.Document.Source.yaml_heads_tick"><code>yaml_heads_tick</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/YamlLines.lean#L296-L302">source</a></div>

```lean
theorem yaml_heads_tick (v : Json) (hv : v.WFm) : '`' ∉ heads true (Yaml.encode v)
```

No line of the YAML spelling of a well-formed value (math leaves allowed) starts with
a backtick, so a YAML block never closes a Markdown code fence.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.yaml_heads_dash">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.yaml_heads_dash" title="Esm.Document.Source.yaml_heads_dash"><code>yaml_heads_dash</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/YamlLines.lean#L306-L310">source</a></div>

```lean
theorem yaml_heads_dash (kvs : List (String × Json)) (hv : (Json.obj kvs).WF) :
    '-' ∉ heads true (Yaml.encode (.obj kvs))
```

No line of the YAML spelling of a well-formed object starts with `-`, so front
matter never contains the `---` delimiter line.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.yaml_ends">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.yaml_ends" title="Esm.Document.Source.yaml_ends"><code>yaml_ends</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/YamlLines.lean#L313-L320">source</a></div>

```lean
theorem yaml_ends (v : Json) : endBol false (Yaml.encode v) = true
```

The YAML spelling ends with a newline.

</div>

<p class="lean-meta">This module also proves 31 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/YamlLines.lean">the source</a>.</p>
