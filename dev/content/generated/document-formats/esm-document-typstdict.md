---
title: "The Typst value codec"
type: lean
lean_module: "Esm.Document.TypstDict"
weight: 6
---

<p class="lean-meta">Lean module <code>Esm.Document.TypstDict</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/TypstDict.lean"><code>formal/Esm/Document/TypstDict.lean</code></a> at <code>9c3b4aa7587e</code><br>Imports <a href="/generated/document-formats/esm-document-number"><code>Esm.Document.Number</code></a>, <a href="/generated/document-formats/esm-document-strings"><code>Esm.Document.Strings</code></a></p>

A [`Json`](/generated/document-formats/esm-document-json#Esm.Document.Json) value prints as a Typst code-mode value:

* `none`, `true`, `false`; numbers in the canonical spelling ([`Number.print`](/generated/document-formats/esm-document-number#Esm.Document.Number.print)), except
  `-2^63`, printed `(-9223372036854775807 - 1)` because Typst reads the literal
  `-9223372036854775808` as a float;
* strings `"…"` with Typst escapes (`\\`, `\"`, `\n`, `\r`, `\t`, `\u{XXXX}`);
* arrays `(a, b)`, `()` empty; dictionaries `(key: v, "quoted key": v)`, `(:)` empty.
  A key is bare when it matches `[A-Za-z_][A-Za-z0-9_]*` and is not a Typst keyword,
  otherwise quoted;
* a math leaf `$…$`, Typst math content: its text up to the next `$` ([`Json.mathOK`](/generated/document-formats/esm-document-json#Esm.Document.Json.mathOK)).
  Only a path block holds one ([`Source.mathify`](/generated/document-formats/esm-document-source-items#Esm.Document.Source.mathify)).

The canonical layout is one element per line: `(`, a newline, then each element on
its own line indented two spaces deeper than the opening line, each followed by `,`
(so a one-element array is `(a,)`), then `)` at the opening line's indentation.

The reader skips whitespace between tokens, so it accepts any layout of the same
tokens (including the `-2^63` expression), with or without a trailing comma, except
that a one-element array needs its comma: Typst reads `(x)` as the value `x`, not an
array, so the reader rejects it. It accepts a bare key only when it would print bare
(Typst rejects a keyword as a key), and only well-formed values ([`decode_wf`](#Esm.Document.TypstDict.decode_wf)): it
rejects a repeated key, and numbers are read by [`Number.parse`](/generated/document-formats/esm-document-number#Esm.Document.Number.parse) (canonical form; no
leading zero; integers in `Int64`). [`decode_encode`](#Esm.Document.TypstDict.decode_encode) is the round trip.

## Printer

<div class="lean-decl" id="Esm.Document.TypstDict.keywords">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.TypstDict.keywords" title="Esm.Document.TypstDict.keywords"><code>keywords</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/TypstDict.lean#L39-L41">source</a></div>

```lean
def keywords : List String
```

Typst keywords, which cannot be bare dictionary keys.

</div>

<div class="lean-decl" id="Esm.Document.TypstDict.reserved">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.TypstDict.reserved" title="Esm.Document.TypstDict.reserved"><code>reserved</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/TypstDict.lean#L44">source</a></div>

```lean
def reserved (k : String) : Bool
```

A keyword: never a bare key.

</div>

<div class="lean-decl" id="Esm.Document.TypstDict.int64Min">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.TypstDict.int64Min" title="Esm.Document.TypstDict.int64Min"><code>int64Min</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/TypstDict.lean#L47">source</a></div>

```lean
def int64Min : Int
```

The `Int64` minimum, `-2^63`.

</div>

<div class="lean-decl" id="Esm.Document.TypstDict.minTail">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.TypstDict.minTail" title="Esm.Document.TypstDict.minTail"><code>minTail</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/TypstDict.lean#L52-L54">source</a></div>

```lean
def minTail : List Char
```

After `(`: the rest of `(-9223372036854775807 - 1)`. Typst reads the literal
`9223372036854775808` as a float (it overflows `Int64` before the minus applies), so
`-2^63` is printed as this integer expression instead.

</div>

<div class="lean-decl" id="Esm.Document.TypstDict.minLit">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.TypstDict.minLit" title="Esm.Document.TypstDict.minLit"><code>minLit</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/TypstDict.lean#L57-L59">source</a></div>

```lean
def minLit : List Char
```

`-9223372036854775807`, the first operand of the `-2^63` expression.

</div>

<div class="lean-decl" id="Esm.Document.TypstDict.printNum">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.TypstDict.printNum" title="Esm.Document.TypstDict.printNum"><code>printNum</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/TypstDict.lean#L64-L65">source</a></div>

```lean
def printNum (n : JNum) : List Char
```

A number: the canonical spelling, except `-2^63` (see [`minTail`](#Esm.Document.TypstDict.minTail)).

</div>

<div class="lean-decl" id="Esm.Document.TypstDict.enc">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.TypstDict.enc" title="Esm.Document.TypstDict.enc"><code>enc</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/TypstDict.lean#L70-L80">source</a></div>

```lean
def enc (m : Nat) : Json → List Char
```

The canonical print of a value whose first line is indented by `m` spaces (the
indentation itself is not printed).

</div>

<div class="lean-decl" id="Esm.Document.TypstDict.encode">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.TypstDict.encode" title="Esm.Document.TypstDict.encode"><code>encode</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/TypstDict.lean#L93">source</a></div>

```lean
def encode (v : Json) : List Char
```

The canonical Typst spelling of a value.

</div>

## Reader

<div class="lean-decl" id="Esm.Document.TypstDict.isEntry">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.TypstDict.isEntry" title="Esm.Document.TypstDict.isEntry"><code>isEntry</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/TypstDict.lean#L104-L110">source</a></div>

```lean
def isEntry (input : List Char) : Bool
```

The input starts with a key and a colon: the first element of a dictionary.

</div>

<div class="lean-decl" id="Esm.Document.TypstDict.Next">
<div class="lean-decl-head"><span class="lean-kind">inductive</span> <a class="lean-name" href="#Esm.Document.TypstDict.Next" title="Esm.Document.TypstDict.Next"><code>Next</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/TypstDict.lean#L113-L117">source</a></div>

```lean
inductive Next where
  /-- `,` and another element. -/
  | more
  /-- `)`, after a `,` (`comma`) or directly. -/
  | close (comma : Bool)
```

What follows one element.

</div>

<div class="lean-decl" id="Esm.Document.TypstDict.pNext">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.TypstDict.pNext" title="Esm.Document.TypstDict.pNext"><code>pNext</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/TypstDict.lean#L120-L127">source</a></div>

```lean
def pNext (r : List Char) : Option (Next × List Char)
```

After one element: `,` then either `)` or the next element, or `)` directly.

</div>

<div class="lean-decl" id="Esm.Document.TypstDict.pMin">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.TypstDict.pMin" title="Esm.Document.TypstDict.pMin"><code>pMin</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/TypstDict.lean#L131-L143">source</a></div>

```lean
def pMin (r : List Char) : Option (List Char)
```

After `(` and any whitespace: the rest of the `-2^63` expression
`(-9223372036854775807 - 1)`, with any whitespace between its tokens.

</div>

<div class="lean-decl" id="Esm.Document.TypstDict.pVal">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.TypstDict.pVal" title="Esm.Document.TypstDict.pVal"><code>pVal</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/TypstDict.lean#L147-L169">source</a></div>

```lean
def pVal : Nat → List Char → Option (Json × List Char)
```

A value, at its first character.

</div>

<div class="lean-decl" id="Esm.Document.TypstDict.pParen">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.TypstDict.pParen" title="Esm.Document.TypstDict.pParen"><code>pParen</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/TypstDict.lean#L172-L182">source</a></div>

```lean
def pParen : Nat → List Char → Option (Json × List Char)
```

After `(` and any whitespace.

</div>

<div class="lean-decl" id="Esm.Document.TypstDict.pItems">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.TypstDict.pItems" title="Esm.Document.TypstDict.pItems"><code>pItems</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/TypstDict.lean#L186-L195">source</a></div>

```lean
def pItems : Nat → Bool → List Char → Option (List Json × List Char)
```

Array elements, at one of them (`first`: the first, which needs a `,` after it even
when it is the last).

</div>

<div class="lean-decl" id="Esm.Document.TypstDict.pEntries">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.TypstDict.pEntries" title="Esm.Document.TypstDict.pEntries"><code>pEntries</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/TypstDict.lean#L198-L213">source</a></div>

```lean
def pEntries : Nat → List Char → Option (List (String × Json) × List Char)
```

Dictionary entries, at the first key.

</div>

<div class="lean-decl" id="Esm.Document.TypstDict.decode">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.TypstDict.decode" title="Esm.Document.TypstDict.decode"><code>decode</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/TypstDict.lean#L218-L221">source</a></div>

```lean
def decode (s : List Char) : Option Json
```

Read a value: whitespace, the value, whitespace, end of input. The value must be
well formed, math leaves allowed ([`Json.WFm`](/generated/document-formats/esm-document-json#Esm.Document.Json.WFm)).

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.TypstDict.decode_wf">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.TypstDict.decode_wf" title="Esm.Document.TypstDict.decode_wf"><code>decode_wf</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/TypstDict.lean#L224-L232">source</a></div>

```lean
theorem decode_wf {s : List Char} {v : Json} (h : decode s = some v) : v.WFm
```

**What [`decode`](#Esm.Document.TypstDict.decode) reads is well formed.**

</div>

## The round trip

### Characters

<div class="lean-decl lean-theorem" id="Esm.Document.TypstDict.enc_head">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.TypstDict.enc_head" title="Esm.Document.TypstDict.enc_head"><code>enc_head</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/TypstDict.lean#L260-L277">source</a></div>

```lean
theorem enc_head (m : Nat) (v : Json) (hv : v.WFm) :
    ∃ c t, enc m v = c :: t ∧ isWs c = false ∧ c ≠ ')' ∧ c ≠ ':'
```

What a printed value starts with.

</div>

### Keys

<div class="lean-decl lean-theorem" id="Esm.Document.TypstDict.keyHead_facts">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.TypstDict.keyHead_facts" title="Esm.Document.TypstDict.keyHead_facts"><code>keyHead_facts</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/TypstDict.lean#L287-L289">source</a></div>

```lean
theorem keyHead_facts {c : Char} (h : c = '"' ∨ isIdentStart c = true) :
    c ≠ ')' ∧ c ≠ ':' ∧ isWs c = false ∧ c ≠ '-'
```

A key starts with `"` or an identifier start: never whitespace, `)`, `:` or `-`.

</div>

### Reader steps

### The `-2^63` expression is never mistaken for another value

<div class="lean-decl lean-theorem" id="Esm.Document.TypstDict.print_minLit">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.TypstDict.print_minLit" title="Esm.Document.TypstDict.print_minLit"><code>print_minLit</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/TypstDict.lean#L326">source</a></div>

```lean
theorem print_minLit : Number.print (.int (-9223372036854775807)) = minLit
```

`-9223372036854775807` prints as the first operand of the `-2^63` expression.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.TypstDict.pMin_num">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.TypstDict.pMin_num" title="Esm.Document.TypstDict.pMin_num"><code>pMin_num</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/TypstDict.lean#L330-L366">source</a></div>

```lean
theorem pMin_num (n : JNum) (hn : n.WF) (t : List Char) :
    pMin (Number.print n ++ ',' :: t) = none
```

A printed number followed by `,` is not the `-2^63` expression, even when it is its
first operand `-9223372036854775807`.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.TypstDict.pMin_enc">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.TypstDict.pMin_enc" title="Esm.Document.TypstDict.pMin_enc"><code>pMin_enc</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/TypstDict.lean#L369-L385">source</a></div>

```lean
theorem pMin_enc (m : Nat) (v : Json) (hv : v.WFm) (t : List Char) :
    pMin (enc m v ++ ',' :: t) = none
```

A printed value followed by `,` is not the `-2^63` expression.

</div>

<div class="lean-decl" id="Esm.Document.TypstDict.itemsTail">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.TypstDict.itemsTail" title="Esm.Document.TypstDict.itemsTail"><code>itemsTail</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/TypstDict.lean#L434-L436">source</a></div>

```lean
def itemsTail (m : Nat) : List Json → List Char
```

The elements of a non-empty array after the first one's indentation.

</div>

<div class="lean-decl" id="Esm.Document.TypstDict.entriesTail">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.TypstDict.entriesTail" title="Esm.Document.TypstDict.entriesTail"><code>entriesTail</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/TypstDict.lean#L439-L442">source</a></div>

```lean
def entriesTail (m : Nat) : List (String × Json) → List Char
```

The entries of a non-empty dictionary after the first one's indentation.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.TypstDict.decode_encode">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.TypstDict.decode_encode" title="Esm.Document.TypstDict.decode_encode"><code>decode_encode</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/TypstDict.lean#L661-L670">source</a></div>

```lean
theorem decode_encode (v : Json) (hv : v.WFm) : decode (encode v) = some v
```

**The Typst round trip.** Reading the canonical Typst spelling of a well-formed
value (math leaves allowed) gives the value back.

</div>

## What the reader rejects or accepts

<p class="lean-meta">This module also proves 28 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/TypstDict.lean">the source</a>.</p>
