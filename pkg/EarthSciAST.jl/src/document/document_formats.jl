"""
ESM documents as Markdown and Typst source text.

An `.esm` document can be written as Markdown (LaTeX math, remark-directive
directives, YAML front matter and container bodies) or as Typst (Typst math,
`esm` package functions, Typst dictionaries). Both formats are lossless:
printing a document and reading it back gives the document again, and prose
between the constructs never changes what is read.

The specification of both formats is the Lean model in `formal/`:
`formal/Esm/Document/Notation.lean` is the notation table, and this module is a
port of the executable definitions under `formal/Esm/Document/`, laid out file
by file as the Rust binding's `document` module is (one submodule per Lean
file with executable definitions):

| Julia | Lean |
|---|---|
| `DJson` | `Json.lean` (the value type, canonical numbers) |
| `DLimits` | none: the bounds the readers add to the Lean model (Rust `document::limits`) |
| `DNumber` | `Number.lean` |
| `DStrings` | `Strings.lean` |
| `DYaml` | `Yaml.lean` |
| `DTypstDict` | `TypstDict.lean` |
| `MUnits`, `MExpr`, `MToken`, `MSurface`, `MPrint`, `MParse`, `MLatex`, `MTypst`, `DMath` | `Math/*.lean`, `Units/Typeset.lean` |
| `SKeys`, `SLines`, `SText`, `SSkeleton`, `SEquation`, `SItems`, `SReaction`, `SMultiLine`, `SMarkdown`, `SMarkdownDoc`, `STypst`, `STypstDoc`, `DSource` | `Source/*.lean` |

The golden set every binding reproduces is
`tests/conformance/document_format/` (CONFORMANCE_SPEC §5.58). The public entry
points ([`print_markdown`](@ref) and the rest) are in `src/document_format.jl`.
"""
module DocumentFormats

include("json.jl")
include("limits.jl")
include("number.jl")
include("strings.jl")
include("yaml.jl")
include("typst_dict.jl")

include("math/units.jl")
include("math/expr.jl")
include("math/token.jl")
include("math/surface.jl")
include("math/print.jl")
include("math/parse.jl")
include("math/latex.jl")
include("math/typst.jl")
include("math/math.jl")

include("source/keys.jl")
include("source/lines.jl")
include("source/text.jl")
include("source/skeleton.jl")
include("source/equation.jl")
include("source/items.jl")
include("source/reaction.jl")
include("source/multi_line.jl")
include("source/markdown.jl")
include("source/markdown_doc.jl")
include("source/typst.jl")
include("source/typst_doc.jl")
include("source/source.jl")

end # module DocumentFormats
