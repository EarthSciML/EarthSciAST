"""
ESM documents as Markdown and Typst sources: the entry points of the source
layer (Rust `document::source`, Lean `Source/`).
"""
module DSource

import ..SSkeleton
import ..SMarkdownDoc
import ..STypstDoc

"""`Source.canonDoc` (Skeleton.lean): a JSON object, well formed, with sorted
keys at every depth."""
canon_doc(d) = SSkeleton.canon_doc(d)

"""`Source.Md.printMd` (MarkdownDoc.lean)."""
print_md(d) = SMarkdownDoc.print_md(d)

"""`Source.Md.parseMd` (MarkdownDoc.lean): the document, or `nothing`."""
parse_md(text::AbstractString) = SMarkdownDoc.parse_md(text)

"""`Source.Typ.printTyp` (TypstDoc.lean)."""
print_typ(d) = STypstDoc.print_typ(d)

"""`Source.Typ.parseTyp` (TypstDoc.lean): the document, or `nothing`."""
parse_typ(text::AbstractString) = STypstDoc.parse_typ(text)

end # module DSource
