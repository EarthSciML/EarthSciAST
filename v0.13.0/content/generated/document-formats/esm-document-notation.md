---
title: "Document notation: the Phase 0 tables, as data"
type: lean
lean_module: "Esm.Document.Notation"
weight: 1
---

<p class="lean-meta">Lean module <code>Esm.Document.Notation</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Notation.lean"><code>formal/Esm/Document/Notation.lean</code></a> at <code>5af01ca9d41a</code><br>Imports <code>Mathlib.Data.List.Nodup</code></p>

The signed-off notation for ESM source documents (`.md` with LaTeX math, `.typ` with
Typst math). This module is DATA ONLY: the operator tiers, the precedence levels, the
name rules, where each schema field lives in a document, and the accepted variants.
The printers, parsers and round-trip theorems of the later phases are stated against
these tables, so a notation change is a change here first.

"Lossless" for documents means equality after the canonical form (key order, number
spelling, unit spelling). Numbers follow CONFORMANCE §5.5.3.1: a literal's type is
fixed by its value, so an integral `Int64`-representable `1.0` IS the integer `1`. The canonical
form gains spelling rules for the redundant spellings listed in `spellingRules`; each
gets a meaning-preservation proof when it lands.

Decisions of record (2026-11-13):

* Redundant spellings are normalized in the canonical form, not kept apart in notation.
* `neg` and `pow` are deprecated: loaders warn and rewrite them to unary `-` and `^`;
  the §5.4 algebraic canonicalizer emits `-x` instead of `neg(x)`.
* Chemical-formula-shaped names print as formulas everywhere, with no package.
* Reactions print with the rate over the arrow, one line per reaction, `id` as its
  label. There is no reaction-table form, on output or input.
* Template arguments are positional when the parameter list is known, named otherwise.
* Index subscripts are italic expressions; the subscript part of a name is upright;
  an ambiguous digit subscript prints the index in brackets (`k[1]`).
* Expression-valued fields inside blocks are math strings; an equation's `_comment`
  is a comment line inside its math.
* Models and reaction systems keep separate directives.

## Operators (spec §4.2)

<div class="lean-decl" id="Esm.Document.Notation.Tier">
<div class="lean-decl-head"><span class="lean-kind">inductive</span> <a class="lean-name" href="#Esm.Document.Notation.Tier" title="Esm.Document.Notation.Tier"><code>Tier</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Notation.lean#L54-L59">source</a></div>

```lean
inductive Tier where
  | native
  | call
  | escape
  | deprecated
  deriving DecidableEq, Repr
```

How an operator is written.

* `native`: conventional notation.
* `call`: `\operatorname{name}(…)` in LaTeX, `op("name")(…)` in Typst. Every open
  (rewrite-target) operator and every template application also uses this form,
  with node fields such as `dim` as named arguments after a semicolon.
* `escape`: the generic node form, `\esm{op}{fields}{args}` / `esm.node("op", fields)[args]`,
  whose arguments are still ordinary math.

A JSON string among a node's fields prints in LaTeX as `\text{"…"}` (decided 2026-11-13, so
that KaTeX in strict mode renders it): printable ASCII as itself, `_`, `{`, `}` as `\_`,
`\{`, `\}`, and every other character as `{\char NNN}` (three decimal digits below 1000,
seven above), so no `$` or line break reaches the LaTeX. The earlier spelling, the string
double-quoted with JSON escapes in math mode, is still read. In Typst the string is a code
string, `#"…"`, which Typst sets whatever it holds.
* `deprecated`: read on input with a warning, rewritten, never printed.

</div>

<div class="lean-decl" id="Esm.Document.Notation.OpRow">
<div class="lean-decl-head"><span class="lean-kind">structure</span> <a class="lean-name" href="#Esm.Document.Notation.OpRow" title="Esm.Document.Notation.OpRow"><code>OpRow</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Notation.lean#L64-L71">source</a></div>

```lean
structure OpRow where
  op : String
  /-- Which nodes with this `op` the row covers; empty when it covers all of them. -/
  shape : String := ""
  tier : Tier
  latex : String
  typst : String
  deriving Repr
```

One core operator, or one shape of a core operator when its notation depends on
its fields (`D` with `wrt: "t"` vs a spatial `wrt`, `faq` with the plain semirings vs
the rest, a small vs a large array `const`).

</div>

<div class="lean-decl" id="Esm.Document.Notation.coreOps">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Notation.coreOps" title="Esm.Document.Notation.coreOps"><code>coreOps</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Notation.lean#L75-L156">source</a></div>

```lean
def coreOps : List OpRow
```

Every evaluable-core operator of spec §4.2, by notation tier.

</div>

<div class="lean-decl" id="Esm.Document.Notation.coreOpNames">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Notation.coreOpNames" title="Esm.Document.Notation.coreOpNames"><code>coreOpNames</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Notation.lean#L163-L171">source</a></div>

```lean
def coreOpNames : List String
```

The evaluable-core operator names (spec §4.2). `scripts/formal-audit.py notation`
checks this list against the operator tables of spec §4.2, so an operator added to the
spec fails that audit until it is listed here, and then [`coreOps_covers`](#Esm.Document.Notation.coreOps_covers) fails until it
has a row.

</div>

<div class="lean-decl" id="Esm.Document.Notation.annotatedNodeFields">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Notation.annotatedNodeFields" title="Esm.Document.Notation.annotatedNodeFields"><code>annotatedNodeFields</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Notation.lean#L176">source</a></div>

```lean
def annotatedNodeFields : List String
```

Any node carrying `id` or `expect_cadence` prints in its normal notation wrapped
in an annotation (the escape tier's wrapper), whatever its operator.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Notation.coreOps_covers">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Notation.coreOps_covers" title="Esm.Document.Notation.coreOps_covers"><code>coreOps_covers</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Notation.lean#L181">source</a></div>

```lean
theorem coreOps_covers : ∀ o ∈ coreOpNames, ∃ r ∈ coreOps, r.op = o
```

Every core operator has at least one notation row.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Notation.coreOps_sound">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Notation.coreOps_sound" title="Esm.Document.Notation.coreOps_sound"><code>coreOps_sound</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Notation.lean#L184">source</a></div>

```lean
theorem coreOps_sound : ∀ r ∈ coreOps, r.op ∈ coreOpNames
```

Every row is for a core operator.

</div>

<div class="lean-decl" id="Esm.Document.Notation.deprecatedOps">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Notation.deprecatedOps" title="Esm.Document.Notation.deprecatedOps"><code>deprecatedOps</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Notation.lean#L187-L188">source</a></div>

```lean
def deprecatedOps : List String
```

A deprecated operator has exactly one row, and it is never printed.

</div>

## Precedence (spec §4.1.1), loosest first

Fractions, roots, subscripts, `cases` and big operators are atoms. A right operand at
the same level is parenthesized unless it is the same n-ary `+`, `*`, `and` or `or`.
A negated sum or difference keeps its parentheses.

<div class="lean-decl" id="Esm.Document.Notation.precedence">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Notation.precedence" title="Esm.Document.Notation.precedence"><code>precedence</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Notation.lean#L211-L218">source</a></div>

```lean
def precedence : List PrecLevel
```

`"unary -"` names negation, to keep it apart from binary `-`.

</div>

<div class="lean-decl" id="Esm.Document.Notation.flattening">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Notation.flattening" title="Esm.Document.Notation.flattening"><code>flattening</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Notation.lean#L222">source</a></div>

```lean
def flattening : List String
```

Operators a parser flattens into one n-ary node.

</div>

## Names

<div class="lean-decl" id="Esm.Document.Notation.NameShape">
<div class="lean-decl-head"><span class="lean-kind">inductive</span> <a class="lean-name" href="#Esm.Document.Notation.NameShape" title="Esm.Document.Notation.NameShape"><code>NameShape</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Notation.lean#L233-L252">source</a></div>

```lean
inductive NameShape where
  /-- One letter, or a Greek letter name: `T`, `lambda`. Prints italic. -/
  | single
  /-- A single letter or Greek name, `_`, then the rest: `T_air`, `k_1`. The rest is
  an upright subscript. -/
  | subscripted
  /-- A sequence of at least two element-symbol and count tokens: `NO2`, `CH2O`.
  Prints upright with subscripted counts. -/
  | formula
  /-- Any other multi-letter name: `half_life`, `RT`, `k1`. Prints italic as one word
  (ISO 80000-2). -/
  | word
  /-- The literal name in full, `\mathit{…}` / `italic("…")`, accepted on input for ANY
  name and read as that name. It is how an author resolves a juxtaposition the parser
  rejects: with `R`, `T` and `RT` all declared, bare `RT` is refused, and the author
  writes `\mathit{RT}` for the name or `R T` for the product. For a `word` name it is the
  same text as the printed form; for the other shapes it differs (`T_air` prints
  `T_{\mathrm{air}}`, and `\mathit{T\_air}` reads back as the same name). -/
  | explicit
  deriving DecidableEq, Repr
```

The shapes a declared name can take. The printer decides the shape from the name
alone. `single`, `subscripted`, `formula` and `word` partition the names and each keeps
every character of the name, so two distinct names never print alike (a Phase 2 lemma);
the printer never needs `explicit`.

</div>

<div class="lean-decl" id="Esm.Document.Notation.indexCollisionForm">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Notation.indexCollisionForm" title="Esm.Document.Notation.indexCollisionForm"><code>indexCollisionForm</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Notation.lean#L275">source</a></div>

```lean
def indexCollisionForm : String
```

A scoped reference (`Chem.O3`) prints each segment by its own rule, joined by `.`.
Index subscripts are italic expressions (`A_{i, j}`); the subscript of a name is upright
text. A digit subscript that could be either (`k_{1}` for the name `k_1` or index 1 of
an arrayed `k`) prints the index in brackets, `k[1]`.

</div>

## Literals and units

<div class="lean-decl" id="Esm.Document.Notation.scientificLatex">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Notation.scientificLatex" title="Esm.Document.Notation.scientificLatex"><code>scientificLatex</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Notation.lean#L290">source</a></div>

```lean
def scientificLatex : String
```

Numbers print in the CONFORMANCE §5.5.3.1 canonical spelling: an integral
`Int64`-representable value is an integer with no point (`1.0` prints as `1`); any other
finite value prints its shortest round-trip digits, positional for decimal exponents
-4 to 5 and scientific otherwise. In math, scientific notation is exactly
`<decimal> \times 10^{<integer>}`, read back as one literal (with any spacing, and from an
integer mantissa too); a real product with a power of ten prints with `\cdot`. A negative literal prints as `-3`; unary minus on a
positive literal prints as `-(3)`. A `const` with units prints as the number, a thin
space, then the canonical unit spelling upright: LaTeX `3\,\mathrm{m/s}`, Typst one
`upright("sym")^(exp)` per unit factor, factors separated by `thin` (Typst sets adjacent
`upright` texts with no space), positive exponents first. No unit package is used.
The forms, their parsers and round-trip theorems are [`Esm.Units.Typeset`](/generated/document-formats/esm-units-typeset).

</div>

## Reactions

mhchem `\ce{…}` in Markdown, typsium `#ce[…]` in Typst, the rate over the arrow. The
printer writes a restricted spelling both packages read correctly: every
stoichiometric coefficient and every non-formula species name is quoted as math, and
an empty side is the empty-set symbol. Names inside the quoted math follow the name rules
(the rate `k_1` is `k_{\mathrm{1}}`, the word name `SO4_aer` is `\mathit{SO4\_aer}`); a
formula-shaped species such as `NO2` is left to the package.

The line ([`Esm.Document.Source.Reaction`](/generated/document-formats/esm-document-source-reaction), decided 2026-11-13 with the native surfaces):

* Markdown: `$$\ce{…}$$ {#id key=value …}` on one line. To remark-math this is a
  paragraph holding inline math with a two-dollar fence (not display math, which needs
  `$$` on lines of its own), and a renderer that does not know the label shows
  `{#id …}` as text. The fence is two dollars because single `$…$` would close at the
  first `$` of a quoted piece. The arrow
  label is braced, `->[{$k$}]`, since mhchem ends the label at the first `]` (an index
  `k[1]` or a `\left[`). The label holds the `id` and the reaction's other fields as
  attributes, in the declaration attribute syntax.
* Typst: `#ce[…] <id>`; a reaction with other fields is `#reaction(key: value, …)[#ce[…]] <id>`.
* A coefficient of 1 is left out. A term without `stoichiometry`, a side `[]`, a reaction
  without `id`, `substrates`, `products` or `rate`, or an id outside letters, digits,
  `_`, `-`, `.` and `:` keeps the whole `reactions` field a path block.
* The id is part of the reaction line, not a skipped label: removing it changes the
  parse.
* What the packages would misread keeps the field a block: an escaped brace `\{` or `\}`
  anywhere inside `\ce{…}` (mhchem matches braces by character), and `//` or `/*` anywhere
  inside `#ce[…]` (a Typst comment would swallow the rest of the line).

<div class="lean-decl" id="Esm.Document.Notation.typstVersion">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Notation.typstVersion" title="Esm.Document.Notation.typstVersion"><code>typstVersion</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Notation.lean#L327">source</a></div>

```lean
def typstVersion : String
```

Pinned with the format version.

</div>

## Document skeleton

Every schema field has exactly one home. A field with no row falls back to a block
keyed by its JSON path, so a field added to the schema later round-trips with no
grammar change.

## Templates and rules

[`Esm.Document.Source.Skeleton`](/generated/document-formats/esm-document-source-skeleton) (`Tm`), decided 2026-11-13 with the native surfaces:

* A template is a display whose math is its header, then `\coloneqq` (`:=` in Typst), then
  its body. The header is `\operatorname{name}(p, q)`: the name as in a template
  application (`\operatorname{}` with `escT`), the parameters as names under the empty
  symbol table, separated by `, `, `()` when there are none. Typst: `op("name")(p, q)`, the
  name a quoted string.
* A rule is `\text{rule } \operatorname{name}: \; lhs \Rightarrow rhs` in a Markdown display;
  in Typst `#rule("name", $lhs$, $rhs$, key: value, …)`. Its parameters are not in the header:
  `params` is an attribute like `where` and `priority`.
* The lexer reads the header (and splits a rule at its first ` \Rightarrow `); only the body
  and the left-hand side are math, read under the component's symbol table (or, at the top
  level of a library file, the document's index sets and templates) with the parameters
  declared. The symbol table takes each template's parameter list from its header, never
  from its math.
* Every other field is an attribute. Markdown: the display sits in a container directive,
  `:::template{description="…"}` or `:::rule{params='["u"]' priority=1}`, then the display,
  then a line `:::` (attributes after the closing `$$` would keep remark-math from closing
  the display). Typst: named arguments (a template with fields is `#template(…)[$ … $]`).
* A template or rule prints natively only when its header reads back as written (checked
  by printing it and reading it back) and its math has no `$` or line break; otherwise the
  whole `expression_templates` field is one path block. A display whose math would read as
  a template header is never printed as an equation (the equations field falls back).

<div class="lean-decl" id="Esm.Document.Notation.skippedConstructs">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Notation.skippedConstructs" title="Esm.Document.Notation.skippedConstructs"><code>skippedConstructs</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Notation.lean#L434">source</a></div>

```lean
def skippedConstructs : List String
```

Skipped by the parser: prose outside these constructs, Typst `<labels>` and `@refs`,
Markdown `{#id}` after an equation. The Phase 3 theorem says inserting or removing them
never changes the parse. A reaction's id label (`{#id}` after its `$$\ce{…}$$`, `<id>`
after its `#ce[…]`) is not skipped: it is part of the reaction line.

</div>

## Accepted variants

Spellings the parser reads and normalizes; the printer never writes them. Each math
variant has a Phase 2 lemma in [`Esm.Document.Math.Variants`](/generated/document-formats/esm-document-math-variants) (the variant parses to the
same JSON as the canonical spelling) and hand-written checks in
[`Esm.Document.Math.HandWritten`](/generated/document-formats/esm-document-math-handwritten). The document-layer rows have theirs in the Phase 3
document layer: the declarations table in [`Esm.Document.Source.Markdown`](/generated/document-formats/esm-document-source-markdown) (`lex_table`),
and aligned blocks, continuation rows and row breaks nested in a delimiter in
[`Esm.Document.Source.MultiLine`](/generated/document-formats/esm-document-source-multiline) (`cookRows_layout`; `ckMd_aligned` in
[`Esm.Document.Source.MarkdownDoc`](/generated/document-formats/esm-document-source-markdowndoc) for a Markdown `aligned` display); the reaction rows in
[`Esm.Document.Source.Reaction`](/generated/document-formats/esm-document-source-reaction) (`pTerm_coef`, `pSpecies_math`), and the container row in
[`Esm.Document.Source.Markdown`](/generated/document-formats/esm-document-source-markdown) (`contBody_many`). Unquoted `upright(e)` lexes to the token of
`upright("e")` (`variant_upright_e`); named template arguments in any order read sorted
(`variant_named_args`); a native operator in the call form reads as its native node
(`variant_native_call`). Each gets a Phase 4 fixture. `rejected` rows pin spellings the
parser refuses (the reaction table: `rateTable` in [`Esm.Document.Source.Markdown`](/generated/document-formats/esm-document-source-markdown)).

## Canonical-form spelling rules

Redundant spellings the canonical form merges (landing with the canonical unit spelling).
`esm-lean canon` (`spellRules` in `Adapter/Doc.lean`) applies the `neg` and `pow` rules and
respells every `units` and `default_units` string ([`Esm.Units.canon`](/generated/document-formats/esm-units-canonical#Esm.Units.canon), under which `""`,
`"1"` and `"dimensionless"` are all `"1"`); a `const` node whose units spell `"1"` drops
them, so one whose value is a number is that bare number, whatever other fields it has
(ruling 2026-11-14; a declaration keeps `units: "1"`).

Only the unit respelling is proved: [`Esm.Units.canon`](/generated/document-formats/esm-units-canonical#Esm.Units.canon) keeps the unit a string resolves to
(`resolve_canon`, `resolve_of_canon` in [`Esm.Units.Canonical`](/generated/document-formats/esm-units-canonical)). The other rules, and the
walk that decides which fields are units strings and which objects are name-keyed maps or
free-form (key lists copied from esm-schema.json), are adapter code with no proof that they
preserve meaning. They are pinned instead by the golden files every binding and `esm-lean`
are checked against: `tests/conformance/canonical_document/` and
`tests/conformance/document_format/`.

<p class="lean-meta">This module also proves 3 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Notation.lean">the source</a>.</p>
