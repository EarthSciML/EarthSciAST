"""
ESM documents as Markdown and Typst sources: the entry points of the source
layer (Rust `document::source`, Lean `Source/`).
"""
module DSource

import ..DLimits
import ..SMarkdownDoc
import ..STypstDoc

# A printer calls the math parser to test whether text would read back, and
# that parser keeps its nesting state in task-local storage, which `reading`
# installs and removes; so each print runs in a reading scope of its own and
# discards the findings of those trial reads.
_printing(f) = first(DLimits.reading(f))

"""`Source.Md.printMd` (MarkdownDoc.lean)."""
print_md(d) = _printing(() -> SMarkdownDoc.print_md(d))

"""`Source.Md.parseMd` (MarkdownDoc.lean): the document, or `nothing`."""
parse_md(text::AbstractString) = SMarkdownDoc.parse_md(text)

"""`Source.Typ.printTyp` (TypstDoc.lean)."""
print_typ(d) = _printing(() -> STypstDoc.print_typ(d))

"""`Source.Typ.parseTyp` (TypstDoc.lean): the document, or `nothing`."""
parse_typ(text::AbstractString) = STypstDoc.parse_typ(text)

end # module DSource
