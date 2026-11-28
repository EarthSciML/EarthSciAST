---
title: "The Markdown container"
type: lean
lean_module: "Esm.Document.Source.Markdown"
weight: 58
---

<p class="lean-meta">Lean module <code>Esm.Document.Source.Markdown</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean"><code>formal/Esm/Document/Source/Markdown.lean</code></a> at <code>9c3b4aa7587e</code><br>Imports <a href="/generated/document-formats/esm-document-source-reaction"><code>Esm.Document.Source.Reaction</code></a>, <a href="/generated/document-formats/esm-document-source-yamllines"><code>Esm.Document.Source.YamlLines</code></a></p>

An ESM document in Markdown is CommonMark with `$…$` / `$$…$$` math (LaTeX), fenced
blocks, YAML front matter and directives:

```
---
esm: "2.4.0"
name: "Decay"
---

```esm:description
First-order radioactive decay.
```

::model[Decay]

:var[$N$]{default=100 units="mol"}

$$
\frac{\mathrm{d} N}{\mathrm{d} t} = -\lambda N
$$
```

The constructs ([`Esm.Document.Source.RItem`](/generated/document-formats/esm-document-source-items#Esm.Document.Source.RItem)), and where they may appear:

* front matter: the first line is `---`, then the YAML of the front-matter entries
  ([`Esm.Document.Yaml`](/generated/document-formats/esm-document-yaml)), then a line `---`;
* at the start of a line: a fenced block ```` ```esm:description ```` holding a
  description verbatim, or ```` ```esm:<key> ```` holding a path block's value in YAML;
  a display equation `$$`, its LaTeX on the following lines, then `$$` (optionally
  followed by an equation label `{#eq-x}`, which is discarded); a component directive
  `::model[Name]` or `::reaction-system[Name]` on a line of its own;
* at the start of a line: a reaction, `$$\ce{…}$$ {#id key=value …}` on one line, in
  mhchem ([`Esm.Document.Source.Reaction`](/generated/document-formats/esm-document-source-reaction)) with the rate as LaTeX math over the arrow,
  `->[{$k$}]` (braced, since mhchem ends the label at the first `]`), and the reaction's
  `id` and other fields in the label;
* at the start of a line: a template, a display whose math is
  `\operatorname{f}(a, b) \coloneqq body`, or a rule,
  `\text{rule } \operatorname{r}: \; lhs \Rightarrow rhs`; with other fields the display sits in a
  container `:::template{key=value …}` or `:::rule{key=value …}` closed by `:::`;
* at the start of a line: a subsystem included by reference,
  `::subsystem[Name]{ref="…" key=value …}`;
* at the start of a line: a plot directive `::plot{key=value …}` on one line, an analysis
  with exactly one plot: the analysis's fields, the plot as the attribute `plot`;
* at the start of a line: a container `:::initialization` or `:::constraints` on a line
  of its own, then display equations, then a line `:::`; each equation in it is an
  initialization equation or a constraint;
* anywhere in a line: a declaration `:var[$N$]{…}`, `:param[…]{…}` or `:species[…]{…}`,
  the name in LaTeX math and the attributes as `key=value` pairs, each value a YAML
  scalar or a single-quoted YAML flow collection (`shape='["x", "y"]'`).

Everything else is prose, which the parser skips: [`lex`](#Esm.Document.Source.Md.lex) reads a construct where one
starts and otherwise drops one character. A code span is skipped whole: a run of
backticks (not a ```` ```esm: ```` fence at the start of a line) runs to the next
occurrence of the same run, so `` `:var[x]` `` or a fenced code block holding an example
is prose; a run with no such occurrence after it is literal. So the parse depends only on
the sequence of constructs ([`lex_render`](#Esm.Document.Source.Md.lex_render)): inserting or removing prose and code spans,
and adding or removing equation labels, never changes it.

Restrictions this places on prose outside code spans ([`Inert`](#Esm.Document.Source.Md.Inert)): prose may not contain a
declaration opener (`:var[`, `:param[`, `:species[`) anywhere, nor start a line with
```` ```esm: ````, `$$`, `::model[`, `::reaction-system[`, `| decl | name |`,
`:::initialization` or `:::constraints`, nor start a line with a table row holding a `rate`
cell (a reaction table, which the lexer refuses). In particular display math (`$$`) at the
start of a line is always a model equation, so outside a model it rejects the file;
illustrative math in prose uses inline `$…$` or another delimiter.

The reader first drops a leading byte-order mark and, when the first line ends in CRLF,
reads every CRLF as LF (`decodeText`).

## Spellings

<div class="lean-decl" id="Esm.Document.Source.Md.fenceEsm">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.fenceEsm" title="Esm.Document.Source.Md.fenceEsm"><code>fenceEsm</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L84">source</a></div>

```lean
def fenceEsm : List Char
```

```` ```esm: ````

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.fence">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.fence" title="Esm.Document.Source.Md.fence"><code>fence</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L86">source</a></div>

```lean
def fence : List Char
```

```` ``` ````

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.dd">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.dd" title="Esm.Document.Source.Md.dd"><code>dd</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L88">source</a></div>

```lean
def dd : List Char
```

`$$`

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.dModel">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.dModel" title="Esm.Document.Source.Md.dModel"><code>dModel</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L90">source</a></div>

```lean
def dModel : List Char
```

`::model[`

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.dRs">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.dRs" title="Esm.Document.Source.Md.dRs"><code>dRs</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L92">source</a></div>

```lean
def dRs : List Char
```

`::reaction-system[`

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.dashes">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.dashes" title="Esm.Document.Source.Md.dashes"><code>dashes</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L94">source</a></div>

```lean
def dashes : List Char
```

`---`

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.descInfo">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.descInfo" title="Esm.Document.Source.Md.descInfo"><code>descInfo</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L96">source</a></div>

```lean
def descInfo : List Char
```

The info string of the description block.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.dPlot">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.dPlot" title="Esm.Document.Source.Md.dPlot"><code>dPlot</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L98">source</a></div>

```lean
def dPlot : List Char
```

`::plot{`, the start of a plot directive.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.dRxn">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.dRxn" title="Esm.Document.Source.Md.dRxn"><code>dRxn</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L100">source</a></div>

```lean
def dRxn : List Char
```

`$$\ce{`, the start of a reaction line.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.dInit">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.dInit" title="Esm.Document.Source.Md.dInit"><code>dInit</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L102">source</a></div>

```lean
def dInit : List Char
```

The containers of initialization equations and constraints, and their end.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.dRole">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.dRole" title="Esm.Document.Source.Md.dRole"><code>dRole</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L112-L115">source</a></div>

```lean
def dRole : Role → List Char
```

The opening line of the container of a role.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.dkw">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.dkw" title="Esm.Document.Source.Md.dkw"><code>dkw</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L118-L122">source</a></div>

```lean
def dkw : DKind → List Char
```

The directive keyword of a declaration.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.dSub">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.dSub" title="Esm.Document.Source.Md.dSub"><code>dSub</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L125">source</a></div>

```lean
def dSub : List Char
```

`::subsystem[`, a subsystem included by reference.

</div>

## Path-block keys

<div class="lean-decl" id="Esm.Document.Source.Md.escKey">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.escKey" title="Esm.Document.Source.Md.escKey"><code>escKey</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L131-L132">source</a></div>

```lean
def escKey (c : Char) : List Char
```

One character of a quoted key: the JSON escape, and the backtick as ``` (the info
string of a backtick fence cannot hold a backtick).

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.keyMd">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.keyMd" title="Esm.Document.Source.Md.keyMd"><code>keyMd</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L136-L138">source</a></div>

```lean
def keyMd (k : String) : List Char
```

A path block's key in the fence's info string: bare when it is an identifier other
than `description` (the description block), quoted otherwise.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.parseKeyMd">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.parseKeyMd" title="Esm.Document.Source.Md.parseKeyMd"><code>parseKeyMd</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L141-L147">source</a></div>

```lean
def parseKeyMd (info : List Char) : Option String
```

Read a path block's key from the info string (all of it).

</div>

## Declarations

<div class="lean-decl" id="Esm.Document.Source.Md.nameLatex">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.nameLatex" title="Esm.Document.Source.Md.nameLatex"><code>nameLatex</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L153">source</a></div>

```lean
def nameLatex (n : String) : List Char
```

A declared name, as LaTeX math under the empty symbol table (so it reads the same
whatever else the document declares).

</div>

## Attribute values: YAML scalars and flow collections

An attribute value is a YAML scalar (`100`, `"mol"`, `true`) or a flow collection,
`["x", "y"]`, `{a: 1, "b c": [2]}`: elements and entries separated by `, `, keys bare when
they are identifiers that YAML reads as strings, else quoted. A list or object (empty ones
too) is written single-quoted, `shape='["x", "y"]'`, since remark-directive refuses an
unquoted value holding a bracket or brace; inside the quotes `'` is `&#39;` and `&` is
`&amp;`, the character references remark-directive decodes. The unquoted form is still
read.

<div class="lean-decl" id="Esm.Document.Source.Md.pFlow">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.pFlow" title="Esm.Document.Source.Md.pFlow"><code>pFlow</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L184-L194">source</a></div>

```lean
def pFlow : Nat → List Char → Option (Json × List Char)
```

A value: a flow collection at `[` or `{`, else a scalar.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.pItemsF">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.pItemsF" title="Esm.Document.Source.Md.pItemsF"><code>pItemsF</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L197-L203">source</a></div>

```lean
def pItemsF : Nat → List Char → Option (List Json × List Char)
```

The elements after the first, each after `, `, up to `]`.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.pEntryF">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.pEntryF" title="Esm.Document.Source.Md.pEntryF"><code>pEntryF</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L206-L211">source</a></div>

```lean
def pEntryF : Nat → List Char → Option ((String × Json) × List Char)
```

One entry: `key: value`.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.pEntriesF">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.pEntriesF" title="Esm.Document.Source.Md.pEntriesF"><code>pEntriesF</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L214-L220">source</a></div>

```lean
def pEntriesF : Nat → List Char → Option (List (String × Json) × List Char)
```

The entries after the first, each after `, `, up to `}`.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.isColl">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.isColl" title="Esm.Document.Source.Md.isColl"><code>isColl</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L226-L228">source</a></div>

```lean
def isColl : Json → Bool
```

A value whose YAML starts with a bracket or brace (a list or an object, empty ones
included): micromark-extension-directive, and so remark-directive, refuses such a value
unquoted.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.sqEsc">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.sqEsc" title="Esm.Document.Source.Md.sqEsc"><code>sqEsc</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L232-L234">source</a></div>

```lean
def sqEsc (cs : List Char) : List Char
```

The text of a single-quoted attribute value: `'` as `&#39;` and `&` as `&amp;`, the
character references micromark-extension-directive decodes inside a quoted value.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.sqUnesc">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.sqUnesc" title="Esm.Document.Source.Md.sqUnesc"><code>sqUnesc</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L237-L241">source</a></div>

```lean
def sqUnesc : List Char → List Char
```

Undo [`sqEsc`](#Esm.Document.Source.Md.sqEsc).

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.attrVal">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.attrVal" title="Esm.Document.Source.Md.attrVal"><code>attrVal</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L245-L246">source</a></div>

```lean
def attrVal (v : Json) : List Char
```

An attribute value: a scalar as its YAML, a list or object as its YAML flow collection
single-quoted (`shape='["x", "y"]'`).

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.attrMd">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.attrMd" title="Esm.Document.Source.Md.attrMd"><code>attrMd</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L249">source</a></div>

```lean
def attrMd (a : String × Json) : List Char
```

One attribute: `key=value`.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.attrsMd">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.attrsMd" title="Esm.Document.Source.Md.attrsMd"><code>attrsMd</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L252-L254">source</a></div>

```lean
def attrsMd : List (String × Json) → List Char
```

The attributes, separated by spaces.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.declMd">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.declMd" title="Esm.Document.Source.Md.declMd"><code>declMd</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L257-L258">source</a></div>

```lean
def declMd (d : Decl) : List Char
```

`:var[$N$]{default=100 units="mol"}`.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.pQuoted">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.pQuoted" title="Esm.Document.Source.Md.pQuoted"><code>pQuoted</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L262-L269">source</a></div>

```lean
def pQuoted (u : List Char) : Option (Json × List Char)
```

A single-quoted value after its opening quote: the YAML inside, then the text after
the closing quote.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.pAttr">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.pAttr" title="Esm.Document.Source.Md.pAttr"><code>pAttr</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L272-L278">source</a></div>

```lean
def pAttr (s : List Char) : Option ((String × Json) × List Char)
```

One attribute.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.pAttrsMore">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.pAttrsMore" title="Esm.Document.Source.Md.pAttrsMore"><code>pAttrsMore</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L281-L286">source</a></div>

```lean
def pAttrsMore : Nat → List Char → Option (List (String × Json) × List Char)
```

The attributes after the first, each after a space, up to the closing brace.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.pAttrs">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.pAttrs" title="Esm.Document.Source.Md.pAttrs"><code>pAttrs</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L289-L291">source</a></div>

```lean
def pAttrs (f : Nat) : List Char → Option (List (String × Json) × List Char)
```

The attributes after the opening brace, up to the closing one.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.declBody">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.declBody" title="Esm.Document.Source.Md.declBody"><code>declBody</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L294-L302">source</a></div>

```lean
def declBody (f : Nat) (k : DKind) : List Char → Option (RItem × List Char)
```

A declaration after its `[`.

</div>

## Block constructs

<div class="lean-decl" id="Esm.Document.Source.Md.fenceItem">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.fenceItem" title="Esm.Document.Source.Md.fenceItem"><code>fenceItem</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L307-L310">source</a></div>

```lean
def fenceItem (info body : List Char) : Option RItem
```

A fenced block's construct, from its info string and body.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.labelOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.labelOK" title="Esm.Document.Source.Md.labelOK"><code>labelOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L313-L317">source</a></div>

```lean
def labelOK (sl : List Char) : Bool
```

An equation label after the closing `$$`: nothing, or `{#id}`, with spaces around.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.fenceAt">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.fenceAt" title="Esm.Document.Source.Md.fenceAt"><code>fenceAt</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L320-L324">source</a></div>

```lean
def fenceAt (f : Nat) (u : List Char) : Option (RItem × List Char)
```

A fenced block after ```` ```esm: ````.

</div>

## Templates and rules

A template is a display whose math starts with its header, `\operatorname{f}(a, b) \coloneqq`,
then its body: `$$`, `\operatorname{f}(a, b) \coloneqq body` on one line, `$$`. A rule is
`\text{rule } \operatorname{r}: \; lhs \Rightarrow rhs`. The header (the name, the parameters
as names under the empty symbol table) and the rule's split at its arrow are read here, by
the lexer; only the body and the left-hand side are math. With other fields the display is
wrapped in a container directive whose attributes hold them, `:::template{description="…"}`
or `:::rule{params='["u"]' priority=1}`, closed by a line `:::` (attributes after the
closing `$$` would keep remark-math from closing the display).

<div class="lean-decl" id="Esm.Document.Source.Md.paramsTxt">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.paramsTxt" title="Esm.Document.Source.Md.paramsTxt"><code>paramsTxt</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L347-L349">source</a></div>

```lean
def paramsTxt : List String → List Char
```

The parameters of a template header, separated by `, `.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.tmRaw">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.tmRaw" title="Esm.Document.Source.Md.tmRaw"><code>tmRaw</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L352-L355">source</a></div>

```lean
def tmRaw (t : Tm String) : List Char
```

The math text of a template or rule display (one line).

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.pName">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.pName" title="Esm.Document.Source.Md.pName"><code>pName</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L358-L361">source</a></div>

```lean
def pName (s : List Char) : Option (String × List Char)
```

One parameter: a name, up to the next `,` or `)`.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.pParams">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.pParams" title="Esm.Document.Source.Md.pParams"><code>pParams</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L364-L378">source</a></div>

```lean
def pParams : Nat → List Char → Option (List String × List Char)
```

The parameters after `(`, up to `) \coloneqq `.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.splitAt">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.splitAt" title="Esm.Document.Source.Md.splitAt"><code>splitAt</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L381-L385">source</a></div>

```lean
def splitAt (sep : List Char) : List Char → Option (List Char × List Char)
```

Split at the first occurrence of `sep`.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.tmLex">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.tmLex" title="Esm.Document.Source.Md.tmLex"><code>tmLex</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L389-L404">source</a></div>

```lean
def tmLex (raw : List Char) : Option (String × List String × Option (List Char) × List Char)
```

Read the math text of a display as a template or rule: its name, its parameters, its
left-hand side (a rule's) and its body, as text.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.mathAt">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.mathAt" title="Esm.Document.Source.Md.mathAt"><code>mathAt</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L408-L420">source</a></div>

```lean
def mathAt (f : Nat) (u : List Char) : Option (RItem × List Char)
```

A display after its opening `$$`: a template or rule when its math reads as one,
otherwise an equation (optionally labelled).

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.tmContAt">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.tmContAt" title="Esm.Document.Source.Md.tmContAt"><code>tmContAt</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L424-L435">source</a></div>

```lean
def tmContAt (f : Nat) (u : List Char) : Option (RItem × List Char)
```

A template or rule with other fields, after `:::template{` or `:::rule{`: the
attributes, the display, and the closing `:::` line.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.dirAt">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.dirAt" title="Esm.Document.Source.Md.dirAt"><code>dirAt</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L438-L444">source</a></div>

```lean
def dirAt (K : Kind) (u : List Char) : Option (RItem × List Char)
```

A component directive after its `[`.

</div>

## Reactions

<div class="lean-decl" id="Esm.Document.Source.Md.latexR">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.latexR" title="Esm.Document.Source.Md.latexR"><code>latexR</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L449">source</a></div>

```lean
def latexR : RSurf
```

The math surface of reaction sides: LaTeX under the empty symbol table.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.arrowL">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.arrowL" title="Esm.Document.Source.Md.arrowL"><code>arrowL</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L452">source</a></div>

```lean
def arrowL : List Char
```

The arrow with the rate over it, around the rate's text (which ends at its `$`).

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.rxnEnd">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.rxnEnd" title="Esm.Document.Source.Md.rxnEnd"><code>rxnEnd</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L455">source</a></div>

```lean
def rxnEnd : List Char
```

After the products: the end of the math and the start of the label.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.rxnBody">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.rxnBody" title="Esm.Document.Source.Md.rxnBody"><code>rxnBody</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L458-L460">source</a></div>

```lean
def rxnBody (x : Rxn String) : List Char
```

The text of a reaction line after `$$\ce{`.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.rxnAt">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.rxnAt" title="Esm.Document.Source.Md.rxnAt"><code>rxnAt</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L463-L487">source</a></div>

```lean
def rxnAt (f : Nat) (u : List Char) : Option (RItem × List Char)
```

A reaction line after its `$$\ce{`.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.subAt">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.subAt" title="Esm.Document.Source.Md.subAt"><code>subAt</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L490-L500">source</a></div>

```lean
def subAt (f : Nat) (u : List Char) : Option (RItem × List Char)
```

A subsystem directive after its `::subsystem[`.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.plotAt">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.plotAt" title="Esm.Document.Source.Md.plotAt"><code>plotAt</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L503-L506">source</a></div>

```lean
def plotAt (f : Nat) (u : List Char) : Option (RItem × List Char)
```

A plot directive after its `::plot{`.

</div>

## Containers of initialization equations and constraints

<div class="lean-decl" id="Esm.Document.Source.Md.contBody">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.contBody" title="Esm.Document.Source.Md.contBody"><code>contBody</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L512-L522">source</a></div>

```lean
def contBody (ro : Role) : Nat → List Char → Option (List RItem × List Char)
```

The displays of a container, up to its closing `:::` line; blank lines between them
are skipped.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.contOpen">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.contOpen" title="Esm.Document.Source.Md.contOpen"><code>contOpen</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L525">source</a></div>

```lean
def contOpen (s : List Char) : Bool
```

A container starts here.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.contAt">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.contAt" title="Esm.Document.Source.Md.contAt"><code>contAt</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L528-L535">source</a></div>

```lean
def contAt (f : Nat) (s : List Char) : Option (List RItem × List Char)
```

A container, at its opening line.

</div>

## The lexer

<div class="lean-decl" id="Esm.Document.Source.Md.blockOpen">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.blockOpen" title="Esm.Document.Source.Md.blockOpen"><code>blockOpen</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L540-L542">source</a></div>

```lean
def blockOpen (s : List Char) : Bool
```

A block construct starts here (at the start of a line).

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.declOpen">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.declOpen" title="Esm.Document.Source.Md.declOpen"><code>declOpen</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L545-L546">source</a></div>

```lean
def declOpen (s : List Char) : Bool
```

A declaration starts here.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.blockAt">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.blockAt" title="Esm.Document.Source.Md.blockAt"><code>blockAt</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L549-L558">source</a></div>

```lean
def blockAt (f : Nat) (s : List Char) : Option (RItem × List Char)
```

Read the block construct that starts here.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.declAt">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.declAt" title="Esm.Document.Source.Md.declAt"><code>declAt</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L561-L564">source</a></div>

```lean
def declAt (f : Nat) (s : List Char) : Option (RItem × List Char)
```

Read the declaration that starts here.

</div>

## The declarations table (an accepted input variant)

A per-model declarations table is read as the declarations it lists; the printer never
writes it (it writes `:var` directives):

```
| decl | name | default | units |
| --- | --- | --- | --- |
| var | $N$ | 100 | "mol" |
| param | $\lambda$ | 0.1 | "1/s" |
```

The first two columns are the directive and the name; every other column header is an
attribute key, and a cell is a YAML scalar or empty (the attribute is absent).

<div class="lean-decl" id="Esm.Document.Source.Md.tableOpen">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.tableOpen" title="Esm.Document.Source.Md.tableOpen"><code>tableOpen</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L582">source</a></div>

```lean
def tableOpen : List Char
```

`| decl | name |`, the start of a declarations table.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.trimCell">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.trimCell" title="Esm.Document.Source.Md.trimCell"><code>trimCell</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L585-L586">source</a></div>

```lean
def trimCell (s : String) : String
```

A cell without its surrounding spaces.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.headerCells">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.headerCells" title="Esm.Document.Source.Md.headerCells"><code>headerCells</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L589-L590">source</a></div>

```lean
def headerCells (s : List Char) : List String
```

The header cells of a table line: the line split at `|`, each cell trimmed.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.rateTable">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.rateTable" title="Esm.Document.Source.Md.rateTable"><code>rateTable</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L595-L596">source</a></div>

```lean
def rateTable (s : List Char) : Bool
```

The start of a reaction table with a rate column: a line starting with `|` that has a
cell `rate`. It is not a reaction notation (`Notation.variants`, rejected), and the lexer
refuses it rather than skipping it as prose, which would drop its reactions.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.pCols">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.pCols" title="Esm.Document.Source.Md.pCols"><code>pCols</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L599-L608">source</a></div>

```lean
def pCols : Nat → List Char → Option (List String × List Char)
```

The attribute columns of the header, up to its newline.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.pCell">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.pCell" title="Esm.Document.Source.Md.pCell"><code>pCell</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L611-L617">source</a></div>

```lean
def pCell : List Char → Option (Option Json × List Char)
```

One cell: ` value |`, or ` |` when the attribute is absent.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.pCells">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.pCells" title="Esm.Document.Source.Md.pCells"><code>pCells</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L620-L623">source</a></div>

```lean
def pCells : List String → List Char → Option (List (String × Json) × List Char)
```

The cells of a row, one per attribute column.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.kindOf">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.kindOf" title="Esm.Document.Source.Md.kindOf"><code>kindOf</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L626-L631">source</a></div>

```lean
def kindOf (w : List Char) : Option DKind
```

The directive keyword of a row.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.pRow">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.pRow" title="Esm.Document.Source.Md.pRow"><code>pRow</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L634-L648">source</a></div>

```lean
def pRow (cols : List String) : List Char → Option (Decl × List Char)
```

One row: `| var | $N$ |` and the cells, then a newline.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.pRows">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.pRows" title="Esm.Document.Source.Md.pRows"><code>pRows</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L651-L656">source</a></div>

```lean
def pRows (cols : List String) : Nat → List Char → Option (List Decl × List Char)
```

The rows, as long as lines start with `| `.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.sepOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.sepOK" title="Esm.Document.Source.Md.sepOK"><code>sepOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L659">source</a></div>

```lean
def sepOK (l : List Char) : Bool
```

The separator row: only `|`, `-`, `:` and spaces.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.tableAt">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.tableAt" title="Esm.Document.Source.Md.tableAt"><code>tableAt</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L662-L666">source</a></div>

```lean
def tableAt (f : Nat) (s : List Char) : Option (List RItem × List Char)
```

A declarations table, at its `| decl | name |`.

</div>

## Code spans

A run of backticks in prose opens a code span (or, at the start of a line, a fenced code
block), which runs to the next occurrence of the same run; nothing inside it is a
construct. A run with no such occurrence after it is literal.

<div class="lean-decl" id="Esm.Document.Source.Md.afterRun">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.afterRun" title="Esm.Document.Source.Md.afterRun"><code>afterRun</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L675-L677">source</a></div>

```lean
def afterRun (n : Nat) : List Char → Option (List Char)
```

The text after the first occurrence of `n` backticks.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.skipCode">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.skipCode" title="Esm.Document.Source.Md.skipCode"><code>skipCode</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L680-L683">source</a></div>

```lean
def skipCode (s : List Char) : List Char
```

The text after the code span that starts here (at a backtick).

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.lex">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.lex" title="Esm.Document.Source.Md.lex"><code>lex</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L688-L702">source</a></div>

```lean
def lex : Nat → Bool → List Char → Option (List RItem)
```

**The Markdown lexer**: the constructs of a text, skipping prose one character at a
time and code spans whole. `bol`: the text starts at the beginning of a line. A malformed
construct is an error (`none`).

</div>

## Reading back the pieces

<div class="lean-decl lean-theorem" id="Esm.Document.Source.Md.pInline_gen">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.Md.pInline_gen" title="Esm.Document.Source.Md.pInline_gen"><code>pInline_gen</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L708-L732">source</a></div>

```lean
theorem pInline_gen (v : Json) (hi : Yaml.isInl v = true) (hv : v.WF) (rest : List Char)
    (hr : Number.NumStop rest) : Yaml.pInline (Yaml.inline v ++ rest) = some (v, rest)
```

A YAML scalar read back whatever follows it (a number needs a non-number character
after it).

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.FStop">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.FStop" title="Esm.Document.Source.Md.FStop"><code>FStop</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L735-L736">source</a></div>

```lean
def FStop (rest : List Char) : Prop
```

What may follow an attribute value: `,`, `]`, `}`, a space or `|`.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.Md.pFlow_flow'">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.Md.pFlow_flow'" title="Esm.Document.Source.Md.pFlow_flow'"><code>pFlow_flow'</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L946-L948">source</a></div>

```lean
theorem pFlow_flow' (v : Json) (hv : v.WF) (rest : List Char) (hr : FStop rest) :
    pFlow (2 * (flow v ++ rest).length + 2) (flow v ++ rest) = some (v, rest)
```

A value printed as a scalar or flow collection reads back.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.attrOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.attrOK" title="Esm.Document.Source.Md.attrOK"><code>attrOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L952">source</a></div>

```lean
def attrOK (a : String × Json) : Bool
```

An attribute the Markdown attribute syntax can hold: an identifier key and a
well-formed value.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.declOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.declOK" title="Esm.Document.Source.Md.declOK"><code>declOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L1100-L1101">source</a></div>

```lean
def declOK (d : Decl) : Bool
```

A declaration the Markdown syntax can hold.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.mhchemOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.mhchemOK" title="Esm.Document.Source.Md.mhchemOK"><code>mhchemOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L1105-L1107">source</a></div>

```lean
def mhchemOK (x : Rxn String) : Bool
```

What mhchem reads as written: no escaped brace `\{` or `\}` anywhere inside `\ce{…}`
(mhchem matches braces by character and fails on them).

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.rxnOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.rxnOK" title="Esm.Document.Source.Md.rxnOK"><code>rxnOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L1111-L1113">source</a></div>

```lean
def rxnOK (x : Rxn String) : Bool
```

A reaction the Markdown syntax can hold: sides the side syntax holds, a rate on one
line without `$`, an id label, and attributes the attribute syntax holds.

</div>

## Keys

## The printer

<div class="lean-decl" id="Esm.Document.Source.Md.subMd">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.subMd" title="Esm.Document.Source.Md.subMd"><code>subMd</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L1228">source</a></div>

```lean
def subMd (d : Decl) : List Char
```

`::subsystem[Name]{ref="…"}`, on a line of its own.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.subOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.subOK" title="Esm.Document.Source.Md.subOK"><code>subOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L1231-L1232">source</a></div>

```lean
def subOK (d : Decl) : Bool
```

A subsystem directive the syntax can hold.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.itemMd">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.itemMd" title="Esm.Document.Source.Md.itemMd"><code>itemMd</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L1236-L1250">source</a></div>

```lean
def itemMd : RItem → List Char
```

The text of a construct. A description is written verbatim in its fence; a path
block's value in YAML; a declaration inline (no newline of its own).

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.eqnLabeled">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.eqnLabeled" title="Esm.Document.Source.Md.eqnLabeled"><code>eqnLabeled</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L1253-L1254">source</a></div>

```lean
def eqnLabeled (raw : String) (label : List Char) : List Char
```

A display equation with an equation label after its closing `$$` (` {#eq-x}`).

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.Seg">
<div class="lean-decl-head"><span class="lean-kind">inductive</span> <a class="lean-name" href="#Esm.Document.Source.Md.Seg" title="Esm.Document.Source.Md.Seg"><code>Seg</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L1258-L1262">source</a></div>

```lean
inductive Seg where
  | item (it : RItem)
  | labeled (raw : String) (label : List Char)
  | prose (p : List Char)
  | code (body : List Char)
```

A piece of a Markdown document: a construct, a labelled equation, prose, or a code
span (`` `…` ``, whatever its content).

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.render">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.render" title="Esm.Document.Source.Md.render"><code>render</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L1271">source</a></div>

```lean
def render (segs : List Seg) : List Char
```

The text of a document body.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.segItems">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.segItems" title="Esm.Document.Source.Md.segItems"><code>segItems</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L1274-L1279">source</a></div>

```lean
def segItems : List Seg → List RItem
```

The constructs of a document body: prose dropped, labels dropped.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.isBlock">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.isBlock" title="Esm.Document.Source.Md.isBlock"><code>isBlock</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L1282-L1284">source</a></div>

```lean
def isBlock : RItem → Bool
```

A construct that must start a line (all but declarations).

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.itemOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.itemOK" title="Esm.Document.Source.Md.itemOK"><code>itemOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L1287-L1298">source</a></div>

```lean
def itemOK : RItem → Bool
```

What each construct's content must satisfy for its text to read back.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.Inert">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.Inert" title="Esm.Document.Source.Md.Inert"><code>Inert</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L1303-L1308">source</a></div>

```lean
def Inert : Bool → List Char → List Char → Prop
```

**Prose that the lexer skips**: at no character does a construct start (a block
construct only matters at the start of a line), and it holds no backtick (code spans are
their own pieces, `Seg.code`). `t` is the text after the prose.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.Valid">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.Valid" title="Esm.Document.Source.Md.Valid"><code>Valid</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L1312-L1318">source</a></div>

```lean
def Valid : Bool → List Seg → Prop
```

A document body whose constructs read back: each construct's content is spellable,
block constructs start a line, labels are labels, and prose is inert.

</div>

## Lexing, construct by construct

<div class="lean-decl lean-theorem" id="Esm.Document.Source.Md.lex_code">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.Md.lex_code" title="Esm.Document.Source.Md.lex_code"><code>lex_code</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L1521-L1544">source</a></div>

```lean
theorem lex_code (body t : List Char) (hb : body ≠ []) (hc : '`' ∉ body) (bol : Bool) (g : Nat) :
    lex (g + 1) bol ('`' :: body ++ '`' :: t) = lex g false t
```

**A code span is skipped whole**, whatever it holds.

</div>

### Reactions

### Subsystems

### Plots

### Templates and rules

### Containers

<div class="lean-decl" id="Esm.Document.Source.Md.dispTxt">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.dispTxt" title="Esm.Document.Source.Md.dispTxt"><code>dispTxt</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L1776">source</a></div>

```lean
def dispTxt (raw : String) : List Char
```

A display followed by a blank line.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.Md.contBody_many">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.Md.contBody_many" title="Esm.Document.Source.Md.contBody_many"><code>contBody_many</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L1781-L1816">source</a></div>

```lean
theorem contBody_many (r : Role) (t : List Char) : ∀ (raws : List String),
    (∀ raw ∈ raws, itemOK (.eqn raw) = true) → ∀ g,
    (raws.flatMap dispTxt).length + t.length + 4 < g →
    contBody r g (raws.flatMap dispTxt ++ dEnd ++ '\n' :: t) = some (raws.map (.eqx r), t)
```

**A container holding several displays reads as their equations**, in order: each
display followed by a blank line, then the closing `:::` line (the printer writes one
display per container).

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.Md.lex_render">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.Md.lex_render" title="Esm.Document.Source.Md.lex_render"><code>lex_render</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L1874-L1956">source</a></div>

```lean
theorem lex_render : ∀ (segs : List Seg) (bol : Bool), Valid bol segs →
    ∀ f, (render segs).length < f → lex f bol (render segs) = some (segItems segs)
```

**The Markdown lexer reads back every valid document body**: exactly its constructs,
whatever prose surrounds them and whatever labels the equations carry.

</div>

## The declarations table reads as its declarations

<div class="lean-decl" id="Esm.Document.Source.Md.colText">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.colText" title="Esm.Document.Source.Md.colText"><code>colText</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L1967">source</a></div>

```lean
def colText (k : String) : List Char
```

A header column.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.cellText">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.cellText" title="Esm.Document.Source.Md.cellText"><code>cellText</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L1970-L1972">source</a></div>

```lean
def cellText : Option Json → List Char
```

A cell.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.rowText">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.rowText" title="Esm.Document.Source.Md.rowText"><code>rowText</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L1975-L1977">source</a></div>

```lean
def rowText (cols : List String) (d : Decl) : List Char
```

A row of the table.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.tableText">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.tableText" title="Esm.Document.Source.Md.tableText"><code>tableText</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L1980-L1983">source</a></div>

```lean
def tableText (cols : List String) (ds : List Decl) : List Char
```

A declarations table over the attribute columns `cols`.

</div>

<div class="lean-decl" id="Esm.Document.Source.Md.TableOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Md.TableOK" title="Esm.Document.Source.Md.TableOK"><code>TableOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L1987-L1988">source</a></div>

```lean
def TableOK (cols : List String) (d : Decl) : Prop
```

A declaration a table over `cols` holds: its name and attributes spellable, and its
attributes exactly the columns it has a value in, in column order.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.Md.lex_table">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.Md.lex_table" title="Esm.Document.Source.Md.lex_table"><code>lex_table</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean#L2104-L2160">source</a></div>

```lean
theorem lex_table (cols : List String) (hc : ∀ k ∈ cols, isIdent k.toList = true)
    (ds : List Decl) (hd : ∀ d ∈ ds, TableOK cols d) (t : List Char)
    (ht : pre ['|', ' '] t = false) (g : Nat) (hg : (tableText cols ds).length + t.length < g + 1) :
    lex (g + 1) true (tableText cols ds ++ t) = (lex g true t).map (ds.map RItem.decl ++ ·)
```

**A declarations table reads as the declarations it lists** (and as the
`:var`/`:param`/`:species` directives of the same declarations: the same constructs).

</div>

<p class="lean-meta">This module also proves 86 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Markdown.lean">the source</a>.</p>
