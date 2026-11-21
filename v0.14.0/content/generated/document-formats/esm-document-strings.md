---
title: "Lexical pieces shared by the YAML and Typst codecs"
type: lean
lean_module: "Esm.Document.Strings"
weight: 3
---

<p class="lean-meta">Lean module <code>Esm.Document.Strings</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Strings.lean"><code>formal/Esm/Document/Strings.lean</code></a> at <code>ffd5aee2f868</code><br>Imports <a href="/generated/document-formats/esm-document-number"><code>Esm.Document.Number</code></a></p>

* Double-quoted strings with JSON-style escapes: `\"`, `\\`, `\n`, `\t`, `\r`, and a
  four-digit hex escape for the other characters a reader might not take literally
  ([`needsHex`](#Esm.Document.Strings.needsHex)). YAML writes the hex escape `\uXXXX`, Typst `\u{XXXX}`; everything
  else is literal. [`parseQuoted_quote`](#Esm.Document.Strings.parseQuoted_quote) is the round trip, for both spellings at once.
* Bare identifiers `[A-Za-z_][A-Za-z0-9_]*` (keys) and the reader of a maximal run
  of identifier characters.
* Runs of spaces (indentation).
* Object keys, bare or quoted, with the codec's reserved words (which a reader would
  not take as a key string) always quoted, and never accepted bare.
  [`parseKey_printKey`](#Esm.Document.Strings.parseKey_printKey) is the round trip.
* What a number or a key never starts with, which the codecs' readers use to tell
  them apart from other tokens.

## Hex escapes

<div class="lean-decl" id="Esm.Document.Strings.hexChar">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Strings.hexChar" title="Esm.Document.Strings.hexChar"><code>hexChar</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Strings.lean#L25">source</a></div>

```lean
def hexChar (d : Nat) : Char
```

A lowercase hex digit.

</div>

<div class="lean-decl" id="Esm.Document.Strings.hexVal">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Strings.hexVal" title="Esm.Document.Strings.hexVal"><code>hexVal</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Strings.lean#L28-L32">source</a></div>

```lean
def hexVal (c : Char) : Option Nat
```

The value of a hex digit (either case).

</div>

<div class="lean-decl" id="Esm.Document.Strings.hex4">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Strings.hex4" title="Esm.Document.Strings.hex4"><code>hex4</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Strings.lean#L41-L42">source</a></div>

```lean
def hex4 (n : Nat) : List Char
```

Four hex digits, most significant first.

</div>

<div class="lean-decl" id="Esm.Document.Strings.hex4Val">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Strings.hex4Val" title="Esm.Document.Strings.hex4Val"><code>hex4Val</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Strings.lean#L45-L50">source</a></div>

```lean
def hex4Val (a b c d : Char) : Option Nat
```

The value of four hex digits.

</div>

<div class="lean-decl" id="Esm.Document.Strings.needsHex">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Strings.needsHex" title="Esm.Document.Strings.needsHex"><code>needsHex</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Strings.lean#L63-L66">source</a></div>

```lean
def needsHex (c : Char) : Bool
```

Characters written as a hex escape: the C0 controls, DEL, the C1 controls, the
Unicode line and paragraph separators, the byte-order mark, and the two BMP
noncharacters `U+FFFE`, `U+FFFF`. (YAML does not allow the controls literally, and
YAML 1.1 readers treat `U+0085`, `U+2028`, `U+2029` as line breaks.)

</div>

## Quoted strings

<div class="lean-decl" id="Esm.Document.Strings.escChar">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Strings.escChar" title="Esm.Document.Strings.escChar"><code>escChar</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Strings.lean#L76-L84">source</a></div>

```lean
def escChar (braces : Bool) (c : Char) : List Char
```

The escape of one character. `braces` selects Typst's `\u{XXXX}` over YAML's
`\uXXXX`.

</div>

<div class="lean-decl" id="Esm.Document.Strings.escape">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Strings.escape" title="Esm.Document.Strings.escape"><code>escape</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Strings.lean#L87">source</a></div>

```lean
def escape (braces : Bool) (cs : List Char) : List Char
```

The escaped characters of a string, without the quotes.

</div>

<div class="lean-decl" id="Esm.Document.Strings.quote">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Strings.quote" title="Esm.Document.Strings.quote"><code>quote</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Strings.lean#L90">source</a></div>

```lean
def quote (braces : Bool) (s : String) : List Char
```

A double-quoted string literal.

</div>

<div class="lean-decl" id="Esm.Document.Strings.unquoteBody">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Strings.unquoteBody" title="Esm.Document.Strings.unquoteBody"><code>unquoteBody</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Strings.lean#L94-L113">source</a></div>

```lean
def unquoteBody (braces : Bool) : List Char → Option (List Char × List Char)
```

The body of a quoted string after the opening quote: the characters up to the
closing quote, and what follows it.

</div>

<div class="lean-decl" id="Esm.Document.Strings.parseQuoted">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Strings.parseQuoted" title="Esm.Document.Strings.parseQuoted"><code>parseQuoted</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Strings.lean#L116-L118">source</a></div>

```lean
def parseQuoted (braces : Bool) : List Char → Option (String × List Char)
```

A quoted string literal.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Strings.parseQuoted_quote">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Strings.parseQuoted_quote" title="Esm.Document.Strings.parseQuoted_quote"><code>parseQuoted_quote</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Strings.lean#L166-L169">source</a></div>

```lean
theorem parseQuoted_quote (braces : Bool) (s : String) (rest : List Char) :
    parseQuoted braces (quote braces s ++ rest) = some (s, rest)
```

The string round trip, for both escape spellings: reading a quoted literal gives
the string back, whatever follows it.

</div>

## Identifiers and spaces

<div class="lean-decl" id="Esm.Document.Strings.isIdent">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Strings.isIdent" title="Esm.Document.Strings.isIdent"><code>isIdent</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Strings.lean#L178-L181">source</a></div>

```lean
def isIdent (cs : List Char) : Bool
```

`[A-Za-z_][A-Za-z0-9_]*`.

</div>

<div class="lean-decl" id="Esm.Document.Strings.readIdent">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Strings.readIdent" title="Esm.Document.Strings.readIdent"><code>readIdent</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Strings.lean#L184-L190">source</a></div>

```lean
def readIdent : List Char → List Char × List Char
```

The maximal run of identifier characters at the front.

</div>

<div class="lean-decl" id="Esm.Document.Strings.spaces">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Strings.spaces" title="Esm.Document.Strings.spaces"><code>spaces</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Strings.lean#L216">source</a></div>

```lean
def spaces (n : Nat) : List Char
```

`n` spaces.

</div>

## Keys

<div class="lean-decl" id="Esm.Document.Strings.bareKey">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Strings.bareKey" title="Esm.Document.Strings.bareKey"><code>bareKey</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Strings.lean#L222">source</a></div>

```lean
def bareKey (reserved : String → Bool) (k : String) : Bool
```

A key prints bare when it is an identifier and not one of the codec's `reserved`
words.

</div>

<div class="lean-decl" id="Esm.Document.Strings.printKey">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Strings.printKey" title="Esm.Document.Strings.printKey"><code>printKey</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Strings.lean#L225-L226">source</a></div>

```lean
def printKey (braces : Bool) (reserved : String → Bool) (k : String) : List Char
```

A key: bare when it can be, otherwise quoted (`braces` as in [`quote`](#Esm.Document.Strings.quote)).

</div>

<div class="lean-decl" id="Esm.Document.Strings.parseKey">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Strings.parseKey" title="Esm.Document.Strings.parseKey"><code>parseKey</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Strings.lean#L229-L236">source</a></div>

```lean
def parseKey (braces : Bool) (reserved : String → Bool) : List Char → Option (String × List Char)
```

A key: quoted, or an identifier that is not a reserved word.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Strings.parseKey_printKey">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Strings.parseKey_printKey" title="Esm.Document.Strings.parseKey_printKey"><code>parseKey_printKey</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Strings.lean#L262-L282">source</a></div>

```lean
theorem parseKey_printKey (braces : Bool) (reserved : String → Bool) (k : String)
    (rest : List Char) (hr : ∀ c ∈ rest.head?, isIdentChar c = false) :
    parseKey braces reserved (printKey braces reserved k ++ rest) = some (k, rest)
```

A printed key reads back, when what follows is not an identifier character.

</div>

<div class="lean-decl" id="Esm.Document.Strings.nonKeyHeads">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Strings.nonKeyHeads" title="Esm.Document.Strings.nonKeyHeads"><code>nonKeyHeads</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Strings.lean#L285">source</a></div>

```lean
def nonKeyHeads : List Char
```

Characters a printed key never starts with.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Strings.keyHead_ne">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Strings.keyHead_ne" title="Esm.Document.Strings.keyHead_ne"><code>keyHead_ne</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Strings.lean#L288-L295">source</a></div>

```lean
theorem keyHead_ne {c : Char} (h : c = '"' ∨ isIdentStart c = true) (x : Char)
    (hx : x ∈ nonKeyHeads := by decide) : c ≠ x
```

A key starts with `"` or an identifier start, so not with any of [`nonKeyHeads`](#Esm.Document.Strings.nonKeyHeads).

</div>

## Number heads

<div class="lean-decl" id="Esm.Document.Strings.nonNumHeads">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Strings.nonNumHeads" title="Esm.Document.Strings.nonNumHeads"><code>nonNumHeads</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Strings.lean#L300-L301">source</a></div>

```lean
def nonNumHeads : List Char
```

Characters a printed number never starts with.

</div>

<p class="lean-meta">This module also proves 12 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Strings.lean">the source</a>.</p>
