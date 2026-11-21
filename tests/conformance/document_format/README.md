# Document source formats: the golden set

An `.esm` document can be written as Markdown (LaTeX math, remark-directive
directives) or as Typst. The notation is the table in
`formal/Esm/Document/Notation.lean`, and the Lean model in `formal/` proves both
formats lossless: printing a document and reading it back gives the document
again (`parseMd_printMd`, `parseTyp_printTyp`), and prose and labels inserted
between the constructs never change what is read.

These files pin that notation for the five language bindings. Each case is a
small, hand-picked document. Every expected text and every expected JSON value
was produced by `esm-lean`, the executable Lean model (`formal/Adapter`); only the
inputs were written by hand. A binding's printer and parser must reproduce them.

The whole-corpus round trip (every `.esm` under `tests/` through both formats)
is run at run time from the corpus itself. It is never written here. Across
bindings, the corpus goes through the cross-binding gate
(`scripts/run-document-format-gate.py`, CONFORMANCE §5.59): every participant,
the Lean model included, prints it, and every participant reads every printed
text back.

## Files

| File | Cases | What it pins |
|---|---|---|
| `operators.json` | print | Every operator tier: native arithmetic and functions, derivatives, `cases`, `faq` reductions (unmarked, the `\limits` marker, and an `args` superscript set on the operator in each subscript shape and on the output bracket), `index`, constant arrays of any size (a matrix of more than 10 columns in the LaTeX array form, since `bmatrix` holds at most 10), the `makearray` table (one- and two-dimensional regions, the lifted form with its output indices), the call tier, function-call templates (positional, named, the bare name of one with no bindings), open operators (with and without operands), the call form with named fields of the shape operators and of a `faq`, `makearray` or `const` with no native shape, and the escape form left for annotated nodes |
| `names.json` | print | The name shapes (single letter, Greek, subscripted, chemical formula, word), the collisions that force `\mathit{…}` or the bracketed index `k[1]`, declared `e` and `d`, scoped references |
| `variants.json` | variant | Every accepted hand-written math spelling (`Notation.variants`), with the canonical text it normalizes to |
| `documents.json` | print, variant | Front matter, descriptions, declarations, equations and their comments, reactions (coefficients, empty sides, attributes), initialization and constraint containers, templates and rules, by-reference subsystems, path-keyed blocks and the math of their expression-valued fields (`Notation.compExprPaths`, `Notation.topExprPaths`: `$…$` in a Typst dictionary, the plain scalar `$…$` in YAML), quoted flow-collection attributes, the plot shorthand next to the analyses block it stands for, the document-layer variants, and prose and label independence |
| `units.json` | print, variant | Constants with units in both notations |
| `refusals.json` | refusal | Removed operators refused by name, malformed input, a math leaf outside a path block or one that does not read, and array-notation spellings the printer never writes (a set on a `\limits` operator or inside an output bracket, an annotation, repeated or `args` field in the call form, a native node in the call form, a bare template whose parameter list is empty, a `bmatrix` of more than 10 columns, a mis-sized or narrow array form) |
| `limits.json` | limit | The reader limits every binding shares and the Lean model does not have (see Limits) |

## Case format

Every file is `{"$comment", "oracle", "area", "cases": [...]}`. Each case has an
`id` (unique across the files), a `kind` and a `description`.

**`print`** — a document and both of its printed texts.

- `esm`: the document, in canonical form: sorted keys and canonical numbers
  (CONFORMANCE §5.5.3.1: a decimal is read as the nearest binary64, which is an integer
  when integral and in Int64 and otherwise its shortest round-trip digits; an integer
  token in Int64 is kept exactly), every `units` and `default_units` string in the
  canonical unit spelling, the deprecated `neg` and `pow` rewritten to unary `-` and `^`
  (and a `broadcast` `fn` of `neg` to `-`), and a `const`
  node whose units spell `1` (`"1"`, `"dimensionless"`, `""`) without them, so one whose
  value is a number is the bare number whatever other fields (`id`, `shape`, …) it has.
  A declaration keeps `units: "1"`. These are the rules of every binding's
  `canonicalize_document` (`tests/conformance/canonical_document/`); `esm-lean canon`
  applies them in adapter code that is checked against those fixtures, not proved.
- `written` (cases about the canonical form only): the document as written, before the
  canonical form; `canonicalize(written) == esm`.
- `markdown`, `typst`: the exact texts the printer writes for it.
- `math` (expression cases only): `{"latex", "typst"}`, the math of the case's
  equation display, copied from the two texts. Under the names the case's model
  declares (its variables, species and parameters, and the document's index
  sets), a binding's `print_math` of the equation writes it and its `parse_math`
  reads it back to the equation in canonical form; a case with a template in
  scope is skipped.

A binding MUST satisfy, byte for byte for the texts and as JSON values for the
documents:

```
print_markdown(esm) == markdown        parse_markdown(markdown) == esm
print_typst(esm)    == typst           parse_typst(typst)       == esm
```

**`variant`** — a spelling a person may write and the printer never does.

- `surface`: `markdown` or `typst`.
- `input`: the hand-written text.
- `esm`: the document it reads as.
- `canonical`: the printer's text for that document, in the same surface.

```
parse(surface, input) == esm           print(surface, esm) == canonical
```

**`refusal`** — input every binding refuses.

- `surface`, `input`: as for a variant.
- `error`: the code the binding reports.

```
parse(surface, input) raises a diagnostic whose code is `error`
```

## Error codes

`esm-lean` refuses every bad input the same way (exit status 1, no code), so the
codes come from the specification, not from the oracle:

- `removed_op` (CONFORMANCE §7.1): an operator removed from the format, in the
  call form (`\operatorname{aggregate}(x)`, `op("fn")(x)`) or the escape form
  (`\esm{arrayop}{…}{…}`, `esm.node("rank", …)`). The spec requires a removed
  operator to be rejected by name, never read as an open operator.
- `parse_error`: everything else: an unknown word, an ambiguous juxtaposition, an
  unbalanced delimiter, a display with no `=` or two, an unclosed display,
  container or directive, a continuation row with its own `=`, two named template
  arguments with one name, a reaction table with a rate column.

A name nothing declares is not a parse error: a bare undeclared single letter, and
`\mathit{…}` / `italic("…")` for any name, read as that name. An undeclared reference is
the validator's finding (`undefined_variable`), not the parser's. This is the code
  the bindings' loaders already raise for malformed input (API_SPEC error
  registry).

The `description` of a refusal is prose and is not asserted.

## Regenerating and checking

The fixtures are generated, never hand-edited. Build the model, then run the
generator:

```bash
export ELAN_HOME=/path/to/elan        # see formal/README.md
(cd formal && lake build)             # builds formal/.lake/build/bin/esm-lean
python3 scripts/gen-document-format-fixtures.py           # rewrite the files
python3 scripts/gen-document-format-fixtures.py --check   # fail if they are stale
```

The generator refuses to write a case that does not hold in the oracle: every
printed text must read back as its document, every variant must read as the
expected document, and every refusal must be refused. It first checks that
`esm-lean canon` gives the `expected` document of every fixture in
`tests/conformance/canonical_document/`, the bindings' `canonicalize_document`
golden set, so the canonical form here is the bindings' canonical form.

`python3 scripts/formal-audit.py fixtures` runs `--check`, and the Formal model
workflow runs it after `lake build`, so a change to the Lean printer or parser
that moves a pinned spelling fails CI until these files are regenerated and the
change is reviewed here.

`--validate` also renders everything the printer wrote, with the same tools the
whole-corpus check (`formal/scripts/doc-corpus.py`) uses: each Typst document must
compile with Typst 0.15.1 against the repository's `esm` package
(`typst/packages`; `--typst-package-path` overrides it), and each piece of math in
each Markdown document must render in KaTeX in strict mode with mhchem
(`formal/scripts/katex-check.cjs`). As remark-math reads them, the `$$` display
lines render as display math and a one-line `$$\ce{…}$$` reaction line and a
directive label as inline math. It needs Typst and the `katex` npm package:

```bash
NODE_PATH=/path/to/node_modules \
    python3 scripts/gen-document-format-fixtures.py --validate --typst /path/to/typst
```

## Adding a case

Add it to the case lists in `scripts/gen-document-format-fixtures.py` (the
`operators`, `names`, `variants`, `documents`, `units` and `refusals`
functions), regenerate, run `--validate`, and read the diff. Keep the set
small: a case earns its place by pinning a notation choice no other case pins.

## Limits

`limits.json` is the one file here that `esm-lean` does not generate. The Lean model
reads exact decimals and recurses as deep as its input; a binding reads binary64
numbers on a finite stack. Every binding refuses, with `parse_error`:

- a number beyond the binary64 range (`1.0e400`; an exponent past 2^32 is never
  wrapped). A number below the smallest subnormal reads as 0, as every binding's
  JSON reader rounds it;
- a text that holds more than 128 reader constructs open at once (brackets,
  fractions, signs, operator chains, flow collections, YAML levels), or that reads
  as a value nested more than 127 arrays and objects deep. The count is of the
  reader's constructs, not of the document's depth: `((k))` reads as `k` but opens
  four;

and reports `removed_op` only for a removed operator the math reader meets, never
for one named in prose or in code.

Each case is `{"id", "surface", "input", "description"}` plus `esm_json` (the
document it reads as, as JSON text: the deepest are within the 127 levels a reader
takes, but not once nested inside this file) or `error` (the code). `input` is a recipe, so the deep inputs are
built at run time:

```
text = heads[surface] + prefix + open * n + middle + close * n + suffix
```

with missing fields empty, or, when `input` has `yaml_levels: n`, `heads[surface]`
followed by a ```` ```esm:metaparameters ```` block holding `x:` and the lines
`" " * 2i + "-"` for `i` in `1..n-1`, closed by ```` ``` ````. A binding MUST read
every case as `esm_json`, or refuse it with `error`, without exhausting its stack.

The expected outcomes come from the Rust binding
(`scripts/gen-document-format-limits.py`, which runs
`earthsci-document-format-adapter-rust`).
