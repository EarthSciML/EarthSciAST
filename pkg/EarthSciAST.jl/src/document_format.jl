# ESM documents as Markdown and Typst source text (CONFORMANCE_SPEC §5.58).
#
# The printers and readers are a port of the Lean model under
# `formal/Esm/Document/` (the notation table is
# `formal/Esm/Document/Notation.lean`), laid out in `src/document/` file by
# file as the Rust binding's `document` module is. This file is the public
# boundary: it converts between the binding's decoded JSON (`OrderedDict`,
# `JSON3.Object`, …) and the model's canonical values, and maps a refused text
# to its diagnostic code.

include("document/document_formats.jl")

"""
    print_markdown(doc::AbstractDict) -> String

Print an ESM document as Markdown: YAML front matter, LaTeX math in `\$\$`
displays, remark directives for components, declarations and reactions, and
fenced `esm:` blocks for every field without a native spelling (Lean
`Source.Md.printMd`).

`doc` is a decoded JSON document (the object [`load`](@ref) reads, e.g. from
`JSON3.read`). It is put in canonical form first ([`canonicalize_document`](@ref),
then every object's keys sorted), so two documents that canonicalize alike
print alike, and `parse_markdown(print_markdown(d)) == canonicalize_document(d)`.

```julia
julia> print_markdown(JSON3.read(read("model.esm", String)))
```
"""
print_markdown(doc::AbstractDict)::String =
    DocumentFormats.DSource.print_md(_printable_document(doc))

"""
    print_typst(doc::AbstractDict) -> String

Print an ESM document as Typst (Lean `Source.Typ.printTyp`): the `esm` Typst
package's `esm-document` header, Typst math displays and the package's
functions for components, declarations and reactions. See
[`print_markdown`](@ref).
"""
print_typst(doc::AbstractDict)::String =
    DocumentFormats.DSource.print_typ(_printable_document(doc))

"""
    print_document(doc::AbstractDict, format::Symbol) -> String

Print an ESM document in the source format `format`: `:markdown`
([`print_markdown`](@ref)) or `:typst` ([`print_typst`](@ref)).
"""
function print_document(doc::AbstractDict, format::Symbol)::String
    format === :markdown && return print_markdown(doc)
    format === :typst && return print_typst(doc)
    throw(ArgumentError("unknown document format :$format (expected :markdown or :typst)"))
end

"""
    print_math(expr, names, format::Symbol) -> String

Print one expression, or one equation, as math under a set of declared names:
LaTeX for `:markdown` (Lean `Math.printLatex`), Typst math for `:typst`
(`Math.printTypst`).

`expr` is a decoded ESM expression (a number, a name or an operator node) or an
equation, an object with `lhs` and `rhs` (other fields, such as `_comment`, are
not printed), which prints as its two sides around `=` as in a document
(`Source.eqExpr`). `names` (any collection of strings) plays the part of the
variables a component declares: a name in it prints in its declared shape, and
the printer avoids spellings that would collide with it. The result is what a
document display holds, without its delimiters; it is meant for showing one
expression outside a document, so no template is in scope.

```julia
julia> print_math(Dict("lhs" => "y", "rhs" => Dict("op" => "+", "args" => ["a", "T"])), ["a", "T", "y"], :typst)
"y = a + T"
```
"""
function print_math(expr, names, format::Symbol)::String
    (format === :markdown || format === :typst) ||
        throw(ArgumentError("unknown document format :$format (expected :markdown or :typst)"))
    DJ = DocumentFormats.DJson
    e = DJ.sort_keys(
        DJ.from_value(
            _canonical_document_numbers(_canonicalize_document_value(expr, false))
        )
    )
    if e isa DJ.JObj
        lhs = DJ.look("lhs", e.kvs)
        rhs = DJ.look("rhs", e.kvs)
        if lhs !== nothing && rhs !== nothing
            e = DJ.JObj(DJ.Kvs(["args" => DJ.JArr(Any[lhs, rhs]), "op" => "=="]))
        end
    end
    sym = DocumentFormats.MExpr.Sym(String[String(n) for n in names], Tuple{String, Vector{String}}[])
    return format === :markdown ? DocumentFormats.DMath.print_latex(sym, e) :
        DocumentFormats.DMath.print_typst(sym, e)
end

"""
    parse_markdown(text::AbstractString) -> OrderedDict{String, Any}

Read a Markdown ESM document (Lean `Source.Md.parseMd`). The result is a
decoded JSON document in canonical form, as [`canonicalize_document`](@ref)
returns it with every object's keys sorted. A byte-order mark is dropped, and
CRLF line endings are read as LF when the first line ends in CRLF.

Throws a [`ParseError`](@ref) whose `code` is `"removed_op"` when the text
writes an operator removed from the format (esm-spec §4.2) in the call or the
escape form, and `"parse_error"` for any other text that is not a Markdown ESM
document. A name nothing declares is not a parse error: an undeclared
reference is the validator's finding.
"""
function parse_markdown(text::AbstractString)
    d = DocumentFormats.DSource.parse_md(String(text))
    d === nothing && throw(_document_refusal(text, :markdown))
    return DocumentFormats.DJson.to_value(d)::OrderedDict{String, Any}
end

"""
    parse_typst(text::AbstractString) -> OrderedDict{String, Any}

Read a Typst ESM document (Lean `Source.Typ.parseTyp`). See
[`parse_markdown`](@ref).
"""
function parse_typst(text::AbstractString)
    d = DocumentFormats.DSource.parse_typ(String(text))
    d === nothing && throw(_document_refusal(text, :typst))
    return DocumentFormats.DJson.to_value(d)::OrderedDict{String, Any}
end

"""
    parse_document(text::AbstractString, format::Symbol) -> OrderedDict{String, Any}

Read an ESM document written in the source format `format`: `:markdown`
([`parse_markdown`](@ref)) or `:typst` ([`parse_typst`](@ref)).
"""
function parse_document(text::AbstractString, format::Symbol)
    format === :markdown && return parse_markdown(text)
    format === :typst && return parse_typst(text)
    throw(ArgumentError("unknown document format :$format (expected :markdown or :typst)"))
end

# The value the printers take: `canonicalize_document` applied, then every
# object's keys sorted, as the Lean printers require (`Source.canonDoc`).
_printable_document(doc::AbstractDict) =
    DocumentFormats.DJson.sort_keys(DocumentFormats.DJson.from_value(canonicalize_document(doc)))

# The diagnostic for a text the reader refused. The Lean reader refuses every
# bad input alike; the code comes from the specification: a removed operator
# written in the call form or the escape form is refused by name
# (CONFORMANCE §7.1), everything else is a parse error.
function _document_refusal(text::AbstractString, format::Symbol)
    op = _removed_op_in(text, format)
    if op !== nothing
        return ParseError(
            "`$op` was removed from the format (esm-spec §4.2)";
            code = ERROR_CODES.REMOVED_OP
        )
    end
    what = format === :markdown ? "Markdown" : "Typst"
    return ParseError("not an ESM $what document"; code = ERROR_CODES.PARSE_ERROR)
end

# The first removed operator the text writes in a call or escape form:
# `\operatorname{op}` / `\esm{op}` in LaTeX (with `\_` for `_`), `op("op")` /
# `esm.node("op"` in Typst.
function _removed_op_in(text::AbstractString, format::Symbol)
    removed = DocumentFormats.MExpr.REMOVED_OPS
    opens, close = format === :markdown ? (("\\operatorname{", "\\esm{"), '}') :
        (("op(\"", "esm.node(\""), '"')
    for open in opens
        for m in findall(open, text)
            rest = SubString(text, nextind(text, last(m)))
            stop = findfirst(close, rest)
            stop === nothing && continue
            body = rest[1:prevind(rest, stop)]
            format === :markdown && (body = replace(body, "\\_" => "_"))
            i = findfirst(==(body), removed)
            i === nothing || return removed[i]
        end
    end
    return nothing
end
