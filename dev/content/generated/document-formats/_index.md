---
title: "Document formats"
type: lean
description: "The Markdown and Typst source formats of an ESM document, as the commented Lean model that defines them."
---

An ESM document can be written as a Markdown (`.md`) or Typst (`.typ`) source
file as well as `.esm` JSON. This chapter specifies those source formats: the
notation tables, the LaTeX and Typst math grammars, the value codecs (JSON, the
strict YAML subset, Typst dictionaries) and the unit spellings. It is not a
description of a Lean model; it *is* the Lean model, `formal/` in the
EarthSciAST repository, rendered page by page.

The `Esm.Document` modules, with `Esm.Units.Canonical` and `Esm.Units.Typeset`
for the unit spellings, are the authority for these formats: `esm-spec.md` only
points here, and a change to the notation is a change to the modules first. The
other `Esm.Units` modules are included as the supporting model of units and
dimensional analysis, which `esm-spec.md` §4.8 still defines. Every proof
is checked by Lean in EarthSciAST's CI (the `formal` workflow; `formal/README.md`
explains how to build it locally).

Generated from the Lean source at commit [`9c3b4aa7587e`](https://github.com/EarthSciML/EarthSciAST/tree/9c3b4aa7587e650335b61c9c6c286eeeaab7f644), without running Lean. Module comments are the prose; each documented declaration shows its statement, its doc comment and a link to its source. 77 modules, 329 documented theorems. Every theorem marked **proved** has no `sorry` or `admit` in its proof, and no file of the Lean package contains either or declares an axiom.

## `Esm.Document`

- [Document notation: the Phase 0 tables, as data](/generated/document-formats/esm-document-notation) (`Esm.Document.Notation`): The signed-off notation for ESM source documents (`.md` with LaTeX math, `.typ` with Typst math).
- [The canonical number spelling (CONFORMANCE §5.5.3.1)](/generated/document-formats/esm-document-number) (`Esm.Document.Number`)
- [Lexical pieces shared by the YAML and Typst codecs](/generated/document-formats/esm-document-strings) (`Esm.Document.Strings`)
- [JSON values of an ESM document, in canonical form](/generated/document-formats/esm-document-json) (`Esm.Document.Json`): The value type the document codecs (`Esm.Document.Yaml`, `Esm.Document.TypstDict`) print and read.
- [The strict YAML subset codec](/generated/document-formats/esm-document-yaml) (`Esm.Document.Yaml`): The YAML spelling of a `Json` value, used for `esm:<path>` blocks and front matter in Markdown documents.
- [The Typst value codec](/generated/document-formats/esm-document-typstdict) (`Esm.Document.TypstDict`): A `Json` value prints as a Typst code-mode value.

## `Esm.Document.Math`

- [Math tokens, shared by the two surfaces](/generated/document-formats/esm-document-math-token) (`Esm.Document.Math.Token`): One token type serves LaTeX math and Typst math.
- [Pieces the LaTeX and Typst spellings share](/generated/document-formats/esm-document-math-surface) (`Esm.Document.Math.Surface`): The two surfaces (`Esm.Document.Math.Latex`, `Esm.Document.Math.Typst`) differ in their keyword spellings and lexers, but read numbers alike: a number in its JSON spelling, or a scientific literal `mantissa × 10^exponent`, where only the spelling of `× 10^` and of the exponent's brackets differs.
- [LaTeX math: spelling and lexing of tokens](/generated/document-formats/esm-document-math-latex) (`Esm.Document.Math.Latex`): `render` spells a token list as LaTeX math.
- [Typst math: spelling and lexing of tokens](/generated/document-formats/esm-document-math-typst) (`Esm.Document.Math.Typst`): `render` spells a token list as Typst math.
- [Expressions as JSON values, and the symbol table](/generated/document-formats/esm-document-math-expr) (`Esm.Document.Math.Expr`): The math grammars are stated over the JSON value at an expression position (spec §4.1), not over `Esm.Ast`, which drops fields.
- [How the printer prints each expression](/generated/document-formats/esm-document-math-view) (`Esm.Document.Math.View`): `view` sorts every well-formed expression into the notation the printer gives it and states the printer's output for it, so the round-trip proof never unfolds the printer itself.
- [The printer: expressions to tokens](/generated/document-formats/esm-document-math-print) (`Esm.Document.Math.Print`): `pa c L e` prints the expression `e` for a position that needs precedence level at least `L`, adding grouping parentheses when `e`'s own level is lower.
- [The parser: tokens to expressions](/generated/document-formats/esm-document-math-parse) (`Esm.Document.Math.Parse`): Recursive descent with one function per precedence level (`Esm.Document.Math.Print` lists the levels), each taking fuel.
- [Accepted variants and refused spellings](/generated/document-formats/esm-document-math-variants) (`Esm.Document.Math.Variants`): Each accepted variant spelling is a normalization step with one lemma: the variant reads to the same token or the same value as the canonical spelling.
- [Hand-written input](/generated/document-formats/esm-document-math-handwritten) (`Esm.Document.Math.HandWritten`): The round-trip theorems cover what the printer writes; these checks cover spellings a person writes and the printer never does: binary minus without spaces, scientific literals spaced any way, `\,` between names, the italic-d derivative against declared names, field keys with LaTeX-special characters, and JSON strings.
- [The LaTeX math round trip, at the string level](/generated/document-formats/esm-document-math-roundtriplatex) (`Esm.Document.Math.RoundTripLatex`): Two printers, as for Typst.
- [The Typst math round trip, at the string level](/generated/document-formats/esm-document-math-roundtriptypst) (`Esm.Document.Math.RoundTripTypst`): Two printers.
- [The token-level round trip](/generated/document-formats/esm-document-math-main) (`Esm.Document.Math.Main`)
- [Round trip, case by case: constant arrays](/generated/document-formats/esm-document-math-arrays) (`Esm.Document.Math.Arrays`): A column for rank 1 and a matrix of at least two columns, LaTeX `bmatrix` (a matrix of more than `bmatCols` columns `\left[\begin{array}{c…c} … \end{array}\right]`), Typst `vec(…)` / `mat(…)`, with units after them as for a scalar.
- [Round trip of the atoms: numbers and names](/generated/document-formats/esm-document-math-atoms) (`Esm.Document.Math.Atoms`)
- [Round trip, case by case: atoms, prefix operators, functions](/generated/document-formats/esm-document-math-cases1) (`Esm.Document.Math.Cases1`)
- [Round trip, case by case](/generated/document-formats/esm-document-math-cases2) (`Esm.Document.Math.Cases2`)
- [Round trip, case by case: literals, prefix and infix operators](/generated/document-formats/esm-document-math-cases3) (`Esm.Document.Math.Cases3`)
- [Round trip, case by case: the and, or and * chains](/generated/document-formats/esm-document-math-cases4) (`Esm.Document.Math.Cases4`)
- [Round trip, case by case: fractions, powers, cases, initial conditions, indices, calls](/generated/document-formats/esm-document-math-cases5) (`Esm.Document.Math.Cases5`)
- [Round trip, case by case: calls, min/max, initial conditions, indices](/generated/document-formats/esm-document-math-cases6) (`Esm.Document.Math.Cases6`)
- [Round trip, case by case: indices, fractions, powers, cases](/generated/document-formats/esm-document-math-cases7) (`Esm.Document.Math.Cases7`)
- [Round trip, case by case: fractions, powers, cases](/generated/document-formats/esm-document-math-cases8) (`Esm.Document.Math.Cases8`)
- [Round trip, case by case: ifelse as cases](/generated/document-formats/esm-document-math-cases9) (`Esm.Document.Math.Cases9`)
- [Round trip, case by case: derivatives and quantities](/generated/document-formats/esm-document-math-derivs) (`Esm.Document.Math.Derivs`)
- [Round trip, case by case: the escape form](/generated/document-formats/esm-document-math-escape) (`Esm.Document.Math.Escape`): Every node has it.
- [Round trip, case by case: reductions (faq), rows](/generated/document-formats/esm-document-math-faq) (`Esm.Document.Math.Faq`)
- [The token-level round trip, by induction over the expression](/generated/document-formats/esm-document-math-induct) (`Esm.Document.Math.Induct`)
- [Which operator a printer kind stands for](/generated/document-formats/esm-document-math-kinds) (`Esm.Document.Math.Kinds`)
- [Parsing at a level, what may follow, and moving between levels](/generated/document-formats/esm-document-math-levels) (`Esm.Document.Math.Levels`): `pLvl L` parses at precedence level `L` (`1` = an `or` chain … `9` = postfix, `10` = a primary).
- [The LaTeX lexer lemma](/generated/document-formats/esm-document-math-lexlatex) (`Esm.Document.Math.LexLatex`): Every list of LaTeX tokens (`tokOK`) reads back from its rendering.
- [The Typst lexer lemma](/generated/document-formats/esm-document-math-lextypst) (`Esm.Document.Math.LexTypst`): Every list of Typst tokens (`tokOK`) in which each call parenthesis follows a token after which `(` is a call parenthesis (`CallOK`) reads back from its rendering.
- [The loops of the level parsers: stopping and running through a chain](/generated/document-formats/esm-document-math-loops) (`Esm.Document.Math.Loops`)
- [Round trip, case by case: block assembly (makearray) and a bare template](/generated/document-formats/esm-document-math-makearray) (`Esm.Document.Math.Makearray`): A native `makearray` is a bracketed two-column table, one row per region (the value, then the region as bound pairs joined by `\times`), with its output indices as the bracket's subscript.
- [Names read back](/generated/document-formats/esm-document-math-names) (`Esm.Document.Math.Names`): `pName_nameToks`: the tokens of a name read back to the name, whatever symbol table printed them, before anything that does not continue a name (`NameStop`: not the scope dot, not an upright name subscript).
- [Round trip, case by case: open operators](/generated/document-formats/esm-document-math-openop) (`Esm.Document.Math.OpenOp`)
- [The token-level round trip: generic pieces](/generated/document-formats/esm-document-math-roundtrip) (`Esm.Document.Math.RoundTrip`): `PL c e`: the printed tokens of `e` for any level read back to `e` at that level, before anything that does not continue it, with enough fuel (`need`).
- [Round trip, case by case: expression templates](/generated/document-formats/esm-document-math-templates) (`Esm.Document.Math.Templates`): Positional arguments read back through the parameter list of the symbol table, and the parser sorts the bindings; named arguments read back in the printed (sorted) order.
- [The LaTeX printer writes only LaTeX tokens](/generated/document-formats/esm-document-math-toklatex) (`Esm.Document.Math.TokLatex`): Every token of a printed well-formed expression is a LaTeX token (`tokOK`), so the LaTeX lexer lemma applies to the printer's output.
- [The Typst printer writes only Typst tokens, in lexable order](/generated/document-formats/esm-document-math-toktypst) (`Esm.Document.Math.TokTypst`): Every token of a printed well-formed expression is a Typst token (`tokOK`), every call parenthesis follows a name-like token, and no unit block follows a unit block (`Adj`), so the Typst lexer lemma applies to the printer's output.

## `Esm.Document.Source`

- [Lines of text](/generated/document-formats/esm-document-source-lines) (`Esm.Document.Source.Lines`): Containers are line-oriented: a fenced block ends at the first line that starts with its closing fence.
- [Objects in canonical form: sorting entries, and splitting an object between surfaces](/generated/document-formats/esm-document-source-keys) (`Esm.Document.Source.Keys`): A canonical ESM document has the keys of every object in strictly increasing order (the sorted-key canonical serialization).
- [The document skeleton](/generated/document-formats/esm-document-source-skeleton) (`Esm.Document.Source.Skeleton`): The document layer maps an ESM document (a JSON object in canonical form) to a *skeleton*: the front matter, the description, the path blocks, and one section per model or reaction system with its description, its declarations, its equations and its own path blocks.
- [The document layer round trip](/generated/document-formats/esm-document-source-skeletonrt) (`Esm.Document.Source.SkeletonRT`): `ofDoc_toDoc`: a canonical document is rebuilt exactly from its skeleton, for every choice of container predicates `Caps`.
- [The skeleton as a sequence of constructs](/generated/document-formats/esm-document-source-items) (`Esm.Document.Source.Items`): A container spells a skeleton as a sequence of *constructs*: description blocks, path blocks, component directives, declarations, equations (model, initialization and constraint) and reactions.
- [What the skeleton of a canonical document satisfies](/generated/document-formats/esm-document-source-facts) (`Esm.Document.Source.Facts`): `toDoc_ok`: the skeleton of a canonical document only holds what its container can spell (`Caps`), and only well-formed JSON values; the containers' round trips assume exactly this.
- [Text scanning shared by the containers](/generated/document-formats/esm-document-source-text) (`Esm.Document.Source.Text`): Prefixes, lines, fenced bodies ended by a closing line, and the facts the containers' round trips use about them.
- [Line heads of the YAML spelling](/generated/document-formats/esm-document-source-yamllines) (`Esm.Document.Source.YamlLines`): Facts about which characters start a line of `Yaml.encode v`, used to show a YAML block can sit inside a Markdown code fence (`yaml_heads_tick`) or between front-matter `---` delimiters (`yaml_heads_dash`), and that it ends at the start of a line (`yaml_ends`).
- [Reaction sides, shared by the containers](/generated/document-formats/esm-document-source-reaction) (`Esm.Document.Source.Reaction`): A reaction prints as one line in the chemistry notation of its container (mhchem `\ce{…}` in Markdown, typsium `#ce[…]` in Typst), the rate over the arrow (`Notation.reactionLatex`).
- [An equation as math](/generated/document-formats/esm-document-source-equation) (`Esm.Document.Source.Equation`): An equation `lhs = rhs` is printed as the math of the expression `==(lhs, rhs)`: the `=` is the comparison's sign at the loosest comparison level, and an equation `x = faq` with output indices is printed in its defining form `x_s = …, s ∈ S` (`Math.print`).
- [Multi-line equations (accepted input variants)](/generated/document-formats/esm-document-source-multiline) (`Esm.Document.Source.MultiLine`): The printer writes one equation per display.
- [The Markdown container](/generated/document-formats/esm-document-source-markdown) (`Esm.Document.Source.Markdown`): An ESM document in Markdown is CommonMark with `$…$` / `$$…$$` math (LaTeX), fenced blocks, YAML front matter and directives.
- [Markdown documents: printing, parsing, and the round trip](/generated/document-formats/esm-document-source-markdowndoc) (`Esm.Document.Source.MarkdownDoc`): `printMd` spells a canonical ESM document as Markdown, `parseMd` reads it back, and `parseMd_printMd` is the round trip.
- [The Typst container](/generated/document-formats/esm-document-source-typst) (`Esm.Document.Source.Typst`): An ESM document in Typst is markup plus the functions of an `esm` Typst package.
- [Typst documents: printing, parsing, and the round trip](/generated/document-formats/esm-document-source-typstdoc) (`Esm.Document.Source.TypstDoc`): `printTyp` spells a canonical ESM document as Typst, `parseTyp` reads it back, and `parseTyp_printTyp` is the round trip, composed exactly as for Markdown (`Esm.Document.Source.MarkdownDoc`) with the Typst math theorem `parseTypst_printTypst`.
- [The initialization_equations migration of the canonical form (esm-spec §11.4.4)](/generated/document-formats/esm-document-source-initmigration) (`Esm.Document.Source.InitMigration`): `initialization_equations` is deprecated (esm 2.5.0).

## `Esm.Units`

- [Units: dimensions and exact scales (esm-spec §4.8.1)](/generated/document-formats/esm-units-core) (`Esm.Units.Core`): A **dimension** is a vector of rational exponents over exactly the eight axes `m kg s mol K A cd rad` (§4.8.1 "The eight canonical dimension axes").
- [The unit registry table (esm-spec §4.8.1)](/generated/document-formats/esm-units-registry) (`Esm.Units.Registry`): The flat table, exactly as written in §4.8.1: a symbol is in it, spelled exactly, or it does not resolve.
- [The unit-string grammar (esm-spec §4.8.2)](/generated/document-formats/esm-units-grammar) (`Esm.Units.Grammar`): A unit string is resolved in four steps, each a function here.
- [Whole unit strings, end to end (esm-spec §4.8.2)](/generated/document-formats/esm-units-strings) (`Esm.Units.Strings`): Facts about `resolve` on specific strings the spec names, and about the scaling-factor diagnostic text.
- [The canonical unit spelling](/generated/document-formats/esm-units-canonical) (`Esm.Units.Canonical`): The canonical form of a document rewrites every `units` string to ONE spelling built from its parsed unit (esm-spec §4.8.2), so `m*h/(mi*s)`, `m h/(mi s)` and `m·h/(mi·s)` canonicalize alike.
- [Typeset unit spellings: LaTeX and Typst, with no unit package](/generated/document-formats/esm-units-typeset) (`Esm.Units.Typeset`): A `const` with units prints in a document as the number, a thin space, then the canonical unit (`Esm.Document.Notation`).
- [Closed examples of the canonical unit spelling](/generated/document-formats/esm-units-canonicalexamples) (`Esm.Units.CanonicalExamples`): Tests, not properties: the theorems quantifying over all inputs are in `Esm.Units.Canonical` and `Esm.Units.Typeset`.
- [Esm.Units.Examples](/generated/document-formats/esm-units-examples) (`Esm.Units.Examples`)
- [Executable read-outs of a resolved unit](/generated/document-formats/esm-units-exec) (`Esm.Units.Exec`): Rendering for the `esm-lean units` adapter: the exponent map of a scale in normal form, the exact scale as the `p/q*pi^k` string the unit-registry golden uses, and a floating-point conversion factor (for the golden's 1e-12 check only; no verdict reads it, §4.8.1).
- [Factor lists: the flattened form of a parsed unit](/generated/document-formats/esm-units-factors) (`Esm.Units.Factors`): The canonical unit spelling (`Esm.Units.Canonical`) is computed from a parsed unit tree (`UExpr`, esm-spec §4.8.2) by flattening it to a list of factors (symbol, rational exponent) and normalizing that list.
- [Laws of the unit-string grammar (esm-spec §4.8.2)](/generated/document-formats/esm-units-grammarlaws) (`Esm.Units.GrammarLaws`)
- [The identities §4.8.1 states, checked against the table](/generated/document-formats/esm-units-identities) (`Esm.Units.Identities`): Every entry of `table` is built from the scale the spec states for it, so each identity below is a genuine check that the stated scales are consistent with the stated relations, exactly (rational arithmetic on exponent maps).
- [Algebra of units (esm-spec §4.8.1 "Scales are EXACT")](/generated/document-formats/esm-units-laws) (`Esm.Units.Laws`): Units under multiplication form an abelian group up to agreement (equal dimension and equal exact scale), rational powers obey the exponent laws, and the real value of a scale is a positive homomorphism that agreement respects.
- [Exact scales of rational numbers](/generated/document-formats/esm-units-rat) (`Esm.Units.Rat`): `Scale.ofRat q` is the prime factorization of a positive rational `q` in the formal-product representation: every prime of the numerator with exponent `1` and every prime of the denominator with exponent `-1`.
- [Unit preservation for scalar expressions (esm-spec §4.8.3–4.8.4)](/generated/document-formats/esm-units-scalarcheck) (`Esm.Units.ScalarCheck`): These rules consume the unit verdicts of their child expressions.
