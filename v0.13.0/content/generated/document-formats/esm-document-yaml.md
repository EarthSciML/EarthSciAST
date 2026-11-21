---
title: "The strict YAML subset codec"
type: lean
lean_module: "Esm.Document.Yaml"
weight: 5
---

<p class="lean-meta">Lean module <code>Esm.Document.Yaml</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Yaml.lean"><code>formal/Esm/Document/Yaml.lean</code></a> at <code>5af01ca9d41a</code><br>Imports <a href="/generated/document-formats/esm-document-number"><code>Esm.Document.Number</code></a>, <a href="/generated/document-formats/esm-document-strings"><code>Esm.Document.Strings</code></a></p>

The YAML spelling of a [`Json`](/generated/document-formats/esm-document-json#Esm.Document.Json) value, used for `esm:<path>` blocks and front matter in
Markdown documents. The printed text is block-style YAML 1.2:

* A non-empty object is one `key: value` line per entry at the current indentation.
* A non-empty array is one `- item` line per element at the current indentation.
* A scalar, `[]` or `{}` value follows its `key: ` or `- ` on the same line.
* A non-empty object or array under a key starts on the next line, indented two
  spaces deeper (`key:` then the block).
* A non-empty object as an array element starts on the `- ` line (`- key: v`), its
  other entries indented to align with the first key (two spaces past the `-`).
* A non-empty array as an array element starts on the next line, indented two
  spaces deeper (`-` alone, then the block).
* A top-level scalar, `[]` or `{}` is one line.

Scalars: `null`, `true`, `false`, numbers in the canonical spelling ([`Number.print`](/generated/document-formats/esm-document-number#Esm.Document.Number.print)),
and strings ALWAYS double-quoted with JSON-style escapes (`\uXXXX` for the characters
of [`Strings.needsHex`](/generated/document-formats/esm-document-strings#Esm.Document.Strings.needsHex)), which avoids YAML's implicit typing. A key is bare when it
matches `[A-Za-z_][A-Za-z0-9_]*` and is not, in any letter case, one of YAML's
special plain scalars (`true false null yes no on off y n`); otherwise it is quoted
like a string. A key whose spelling is longer than 1024 characters (YAML's limit on
an implicit key) is written in the explicit form instead: `? "key"` on its own line,
then `:` and the value on the next line at the same indentation.

Every line ends with a newline. The reader only accepts this layout (it is the
canonical form; other YAML is out of scope), a bare key only when it would print bare,
and only well-formed values ([`decode_wf`](#Esm.Document.Yaml.decode_wf)): it rejects a repeated key, and numbers are
read by [`Number.parse`](/generated/document-formats/esm-document-number#Esm.Document.Number.parse) (canonical form; no leading zero; integers in `Int64`).
[`decode_encode`](#Esm.Document.Yaml.decode_encode) is the round trip.

## Printer

<div class="lean-decl" id="Esm.Document.Yaml.specialWords">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Yaml.specialWords" title="Esm.Document.Yaml.specialWords"><code>specialWords</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Yaml.lean#L45">source</a></div>

```lean
def specialWords : List String
```

Plain scalars YAML 1.1 or 1.2 reads as something other than a string; a key
equal to one of them (in any letter case) is quoted.

</div>

<div class="lean-decl" id="Esm.Document.Yaml.reserved">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Yaml.reserved" title="Esm.Document.Yaml.reserved"><code>reserved</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Yaml.lean#L48">source</a></div>

```lean
def reserved (k : String) : Bool
```

A key equal (in any letter case) to a special plain scalar: never bare.

</div>

<div class="lean-decl" id="Esm.Document.Yaml.longKey">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Yaml.longKey" title="Esm.Document.Yaml.longKey"><code>longKey</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Yaml.lean#L51">source</a></div>

```lean
def longKey (k : String) : Bool
```

A key whose spelling is longer than YAML's 1024-character limit on implicit keys.

</div>

<div class="lean-decl" id="Esm.Document.Yaml.keyPart">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Yaml.keyPart" title="Esm.Document.Yaml.keyPart"><code>keyPart</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Yaml.lean#L56-L57">source</a></div>

```lean
def keyPart (m : Nat) (k : String) : List Char
```

The key of an entry at indentation `m`, up to its `:`. A long key uses the explicit
form: `? "key"` on its own line, then the `:` on the next line at the same
indentation.

</div>

<div class="lean-decl" id="Esm.Document.Yaml.inline">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Yaml.inline" title="Esm.Document.Yaml.inline"><code>inline</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Yaml.lean#L61-L68">source</a></div>

```lean
def inline : Json → List Char
```

The one-line spelling of a scalar or an empty container. (A non-empty container
is never printed inline; it gets `[]`/`{}` here only to keep the function total.)

</div>

<div class="lean-decl" id="Esm.Document.Yaml.encItems">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Yaml.encItems" title="Esm.Document.Yaml.encItems"><code>encItems</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Yaml.lean#L72-L74">source</a></div>

```lean
def encItems (m : Nat) : List Json → List Char
```

The lines of a non-empty array at indentation `m`.

</div>

<div class="lean-decl" id="Esm.Document.Yaml.itemBody">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Yaml.itemBody" title="Esm.Document.Yaml.itemBody"><code>itemBody</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Yaml.lean#L77-L85">source</a></div>

```lean
def itemBody (m : Nat) : Json → List Char
```

What follows the `-` of an array element at indentation `m`.

</div>

<div class="lean-decl" id="Esm.Document.Yaml.encEntries">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Yaml.encEntries" title="Esm.Document.Yaml.encEntries"><code>encEntries</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Yaml.lean#L88-L90">source</a></div>

```lean
def encEntries (m : Nat) : List (String × Json) → List Char
```

The lines of a non-empty object at indentation `m`.

</div>

<div class="lean-decl" id="Esm.Document.Yaml.valBody">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Yaml.valBody" title="Esm.Document.Yaml.valBody"><code>valBody</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Yaml.lean#L93-L101">source</a></div>

```lean
def valBody (m : Nat) : Json → List Char
```

What follows the `:` of an entry whose key is at indentation `m`.

</div>

<div class="lean-decl" id="Esm.Document.Yaml.encode">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Yaml.encode" title="Esm.Document.Yaml.encode"><code>encode</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Yaml.lean#L105-L108">source</a></div>

```lean
def encode : Json → List Char
```

The canonical YAML spelling of a value.

</div>

## Reader

<div class="lean-decl" id="Esm.Document.Yaml.dropSp">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Yaml.dropSp" title="Esm.Document.Yaml.dropSp"><code>dropSp</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Yaml.lean#L113-L116">source</a></div>

```lean
def dropSp : Nat → List Char → Option (List Char)
```

Drop exactly `n` leading spaces.

</div>

<div class="lean-decl" id="Esm.Document.Yaml.parseKeyAt">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Yaml.parseKeyAt" title="Esm.Document.Yaml.parseKeyAt"><code>parseKeyAt</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Yaml.lean#L120-L130">source</a></div>

```lean
def parseKeyAt (m : Nat) : List Char → Option (String × List Char)
```

The key of an entry at indentation `m`: an explicit `? "key"` line followed by
the indentation of the `:` line, or a plain key.

</div>

<div class="lean-decl" id="Esm.Document.Yaml.pInline">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Yaml.pInline" title="Esm.Document.Yaml.pInline"><code>pInline</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Yaml.lean#L133-L157">source</a></div>

```lean
def pInline : List Char → Option (Json × List Char)
```

A scalar or an empty container.

</div>

<div class="lean-decl" id="Esm.Document.Yaml.pScalarLine">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Yaml.pScalarLine" title="Esm.Document.Yaml.pScalarLine"><code>pScalarLine</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Yaml.lean#L160-L163">source</a></div>

```lean
def pScalarLine (input : List Char) : Option (Json × List Char)
```

A scalar and the end of its line.

</div>

<div class="lean-decl" id="Esm.Document.Yaml.isItemLine">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Yaml.isItemLine" title="Esm.Document.Yaml.isItemLine"><code>isItemLine</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Yaml.lean#L166-L169">source</a></div>

```lean
def isItemLine (m : Nat) (input : List Char) : Bool
```

A line at indentation `m` that starts an array element.

</div>

<div class="lean-decl" id="Esm.Document.Yaml.isEntryLine">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Yaml.isEntryLine" title="Esm.Document.Yaml.isEntryLine"><code>isEntryLine</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Yaml.lean#L172-L175">source</a></div>

```lean
def isEntryLine (m : Nat) (input : List Char) : Bool
```

A line at indentation `m` that starts an object entry.

</div>

<div class="lean-decl" id="Esm.Document.Yaml.pItems">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Yaml.pItems" title="Esm.Document.Yaml.pItems"><code>pItems</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Yaml.lean#L179-L186">source</a></div>

```lean
def pItems : Nat → Nat → List Char → Option (List Json × List Char)
```

Array elements at indentation `m`, as long as lines start with `-` there.

</div>

<div class="lean-decl" id="Esm.Document.Yaml.pItemBody">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Yaml.pItemBody" title="Esm.Document.Yaml.pItemBody"><code>pItemBody</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Yaml.lean#L189-L198">source</a></div>

```lean
def pItemBody : Nat → Nat → List Char → Option (Json × List Char)
```

After the `-` of an element at indentation `m`.

</div>

<div class="lean-decl" id="Esm.Document.Yaml.pEntries">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Yaml.pEntries" title="Esm.Document.Yaml.pEntries"><code>pEntries</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Yaml.lean#L201-L208">source</a></div>

```lean
def pEntries : Nat → Nat → List Char → Option (List (String × Json) × List Char)
```

Object entries at indentation `m`, as long as lines start with a key there.

</div>

<div class="lean-decl" id="Esm.Document.Yaml.pEntry">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Yaml.pEntry" title="Esm.Document.Yaml.pEntry"><code>pEntry</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Yaml.lean#L211-L216">source</a></div>

```lean
def pEntry : Nat → Nat → List Char → Option ((String × Json) × List Char)
```

One entry, at its key, whose key is at indentation `m`.

</div>

<div class="lean-decl" id="Esm.Document.Yaml.pValBody">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Yaml.pValBody" title="Esm.Document.Yaml.pValBody"><code>pValBody</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Yaml.lean#L219-L227">source</a></div>

```lean
def pValBody : Nat → Nat → List Char → Option (Json × List Char)
```

After the `:` of an entry whose key is at indentation `m`.

</div>

<div class="lean-decl" id="Esm.Document.Yaml.pTop">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Yaml.pTop" title="Esm.Document.Yaml.pTop"><code>pTop</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Yaml.lean#L231-L239">source</a></div>

```lean
def pTop (f : Nat) (input : List Char) : Option (Json × List Char)
```

A whole document: an array, an object, or one scalar line.

</div>

<div class="lean-decl" id="Esm.Document.Yaml.decode">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Yaml.decode" title="Esm.Document.Yaml.decode"><code>decode</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Yaml.lean#L243-L246">source</a></div>

```lean
def decode (s : List Char) : Option Json
```

Read a document; all of the input must be consumed, and the value must be well
formed (no repeated key; numbers are already canonical, [`Number.parse`](/generated/document-formats/esm-document-number#Esm.Document.Number.parse)).

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Yaml.decode_wf">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Yaml.decode_wf" title="Esm.Document.Yaml.decode_wf"><code>decode_wf</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Yaml.lean#L249-L255">source</a></div>

```lean
theorem decode_wf {s : List Char} {v : Json} (h : decode s = some v) : v.WF
```

**What [`decode`](#Esm.Document.Yaml.decode) reads is well formed.**

</div>

## The round trip

### Characters

<div class="lean-decl lean-theorem" id="Esm.Document.Yaml.keyHead_facts">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Yaml.keyHead_facts" title="Esm.Document.Yaml.keyHead_facts"><code>keyHead_facts</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Yaml.lean#L276-L283">source</a></div>

```lean
theorem keyHead_facts {c : Char} (h : c = '"' ∨ c = '?' ∨ isIdentStart c = true) :
    c ≠ ' ' ∧ c ≠ '-' ∧ (c == '"' || c == '?' || isIdentStart c) = true
```

A key never starts with a space or `-`.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Yaml.parseKeyAt_keyPart">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Yaml.parseKeyAt_keyPart" title="Esm.Document.Yaml.parseKeyAt_keyPart"><code>parseKeyAt_keyPart</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Yaml.lean#L295-L307">source</a></div>

```lean
theorem parseKeyAt_keyPart (m : Nat) (k : String) (rest : List Char)
    (hr : ∀ c ∈ rest.head?, isIdentChar c = false) :
    parseKeyAt m (keyPart m k ++ rest) = some (k, rest)
```

A printed key, plain or explicit, reads back, when what follows is not an
identifier character.

</div>

### Indentation

<div class="lean-decl" id="Esm.Document.Yaml.Ends">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Yaml.Ends" title="Esm.Document.Yaml.Ends"><code>Ends</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Yaml.lean#L315-L316">source</a></div>

```lean
def Ends (m : Nat) (rest : List Char) : Prop
```

What may follow a block at indentation `m`: nothing, or a line indented less.

</div>

### Scalars

<div class="lean-decl" id="Esm.Document.Yaml.isInl">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Yaml.isInl" title="Esm.Document.Yaml.isInl"><code>isInl</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Yaml.lean#L373-L376">source</a></div>

```lean
def isInl : Json → Bool
```

Scalars and empty containers.

</div>

### Line structure

<div class="lean-decl lean-theorem" id="Esm.Document.Yaml.pEntry_enc">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Yaml.pEntry_enc" title="Esm.Document.Yaml.pEntry_enc"><code>pEntry_enc</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Yaml.lean#L469-L473">source</a></div>

```lean
theorem pEntry_enc (f m : Nat) (k : String) (v : Json) (rest : List Char)
    (h : pValBody f m (valBody m v ++ rest) = some (v, rest)) :
    pEntry (f + 1) m (keyPart m k ++ ':' :: (valBody m v ++ rest)) = some ((k, v), rest)
```

An entry reads back once its value does.

</div>

### Whole documents

<div class="lean-decl" id="Esm.Document.Yaml.topIsArray">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Yaml.topIsArray" title="Esm.Document.Yaml.topIsArray"><code>topIsArray</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Yaml.lean#L662-L665">source</a></div>

```lean
def topIsArray (input : List Char) : Bool
```

The array test of [`pTop`](#Esm.Document.Yaml.pTop).

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Yaml.decode_encode">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Yaml.decode_encode" title="Esm.Document.Yaml.decode_encode"><code>decode_encode</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Yaml.lean#L696-L741">source</a></div>

```lean
theorem decode_encode (v : Json) (hv : v.WF) : decode (encode v) = some v
```

**The YAML round trip.** Reading the canonical YAML spelling of a well-formed value
gives the value back.

</div>

## What the reader rejects or normalizes

<p class="lean-meta">This module also proves 40 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Yaml.lean">the source</a>.</p>
