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
print_document(doc::AbstractDict, format::Symbol)::String =
    _check_format(format) === :markdown ? print_markdown(doc) : print_typst(doc)

# `format`, when it names a source format; an `ArgumentError` otherwise.
function _check_format(format::Symbol)
    (format === :markdown || format === :typst) ||
        throw(ArgumentError("unknown document format :$format (expected :markdown or :typst)"))
    return format
end

"""
    print_math(expr, names, format::Symbol) -> String

Print one expression, or one equation, as math under a set of declared names:
LaTeX for `:markdown` (Lean `Math.printLatex`), Typst math for `:typst`
(`Math.printTypst`).

`expr` is a decoded ESM expression (a number, a name or an operator node) or an
equation, an object with `lhs` and `rhs` (other fields, such as `_comment`, are
not printed). An equation prints as in a document (`Source.eqExpr`,
`Math.printLatexEqn` / `Math.printTypstEqn`): its two sides around `=`, except
that an equation `x = faq` whose `faq` has output indices prints in its defining
form when that reads back as exactly the equation, the output indices on the left
and their ranges after the right side (Typst `y_j = sum_(i in S) w_(i, j), j in C`).
An expression whose top is `==` is a comparison and prints as any expression does,
never in the defining form. A typed [`ASTExpr`](@ref) or [`Equation`](@ref) is printed
through its serialized form. `names` (any collection of strings) plays the part of the
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
    _check_format(format)
    expr = _math_value(expr)
    DJ = DocumentFormats.DJson
    e = DJ.sort_keys(
        DJ.from_value(
            _canonical_document_numbers(_canonicalize_document_value(expr, false))
        )
    )
    eqn = false
    if e isa DJ.JObj
        lhs = DJ.look("lhs", e.kvs)
        rhs = DJ.look("rhs", e.kvs)
        if lhs !== nothing && rhs !== nothing
            e = DJ.JObj(DJ.Kvs(["args" => DJ.JArr(Any[lhs, rhs]), "op" => "=="]))
            eqn = true
        end
    end
    sym = DocumentFormats.MExpr.Sym(String[String(n) for n in names], Tuple{String, Vector{String}}[])
    # In a reading scope of its own, as `DSource.print_md` is.
    return DocumentFormats.DSource._printing() do
        M = DocumentFormats.DMath
        if format === :markdown
            eqn ? M.print_latex_eqn(sym, e) : M.print_latex(sym, e)
        else
            eqn ? M.print_typst_eqn(sym, e) : M.print_typst(sym, e)
        end
    end
end

"""
    parse_math(text::AbstractString, names, format::Symbol)

Read one expression, or one equation, written as math under a set of declared
names: LaTeX for `:markdown` (Lean `Math.parseLatex`), Typst math for `:typst`
(`Math.parseTypst`). The inverse of [`print_math`](@ref):
`parse_math(print_math(e, names, f), names, f)` is `e` in canonical form.

`text` is what a document display holds, without its delimiters. Text whose top
is `=` reads as an equation, an `OrderedDict` with `lhs` and `rhs`, as a display
does (`Source.eqSides`), and so does an equation in its defining form,
`y_j = … , j in C`, whose right side reads as the `faq` with output indices it
writes (`Math.unlift`); any other text reads as an expression (a number, a name
or an operator node, decoded as [`parse_markdown`](@ref) decodes a document).
`names` (any collection of strings) plays the part of the variables a component
declares: it decides how a run of letters reads (in LaTeX, `RT` is the name `RT`
when it is declared, the product of `R` and `T` when they are). No template is
in scope.

Throws a [`ParseError`](@ref) whose `code` is `"removed_op"` when the math uses
an operator removed from the format (esm-spec §4.2), and `"parse_error"` for
any other text that is not math, and for one past a bound of the reader (nested
too deeply, or holding a number beyond the binary64 range).

```julia
parse_math("y = 2 k", ["k", "y"], :typst)
# OrderedDict("lhs" => "y", "rhs" => OrderedDict("args" => Any[2, "k"], "op" => "*"))
```
"""
function parse_math(text::AbstractString, names, format::Symbol)
    _check_format(format)
    DF = DocumentFormats
    DJ = DF.DJson
    sym = DF.MExpr.Sym(String[String(n) for n in names], Tuple{String, Vector{String}}[])
    what = format === :markdown ? "an ESM expression in LaTeX math" :
        "an ESM expression in Typst math"
    return _checked_read(text, format, what) do str
        e = format === :markdown ? DF.DMath.parse_latex(sym, str) : DF.DMath.parse_typst(sym, str)
        e === nothing && return nothing
        sides = DF.SEquation.eq_sides(e)
        return sides === nothing ? e : DJ.JObj(DJ.Kvs(["lhs" => sides[1], "rhs" => sides[2]]))
    end
end

# The JSON form `print_math` prints: a typed expression or equation serialized,
# a decoded value as it is.
_math_value(x) = x
_math_value(x::ASTExpr) = serialize_expression(x)
_math_value(x::Equation) =
    Dict{String, Any}("lhs" => serialize_expression(x.lhs), "rhs" => serialize_expression(x.rhs))

"""
    parse_markdown(text::AbstractString) -> OrderedDict{String, Any}

Read a Markdown ESM document (Lean `Source.Md.parseMd`). The result is a
decoded JSON document in canonical form, as [`canonicalize_document`](@ref)
returns it with every object's keys sorted. A byte-order mark is dropped, and
CRLF line endings are read as LF when the first line ends in CRLF.

Throws a [`ParseError`](@ref) whose `code` is `"removed_op"` when the
document's math writes an operator removed from the format (esm-spec §4.2) in
the call or the escape form, and `"parse_error"` for any other text that is not
a Markdown ESM document, and for one past a bound of the reader: more than 128
constructs (brackets, fractions, signs, flow collections, YAML levels, …) open
at once, a value nested more than 127 arrays and objects deep, or a number
beyond the binary64 range, and for a text that is not valid UTF-8. A name nothing declares is not a parse error: an
undeclared reference is the validator's finding.
"""
parse_markdown(text::AbstractString) = _read_document(text, :markdown)

"""
    parse_typst(text::AbstractString) -> OrderedDict{String, Any}

Read a Typst ESM document (Lean `Source.Typ.parseTyp`). See
[`parse_markdown`](@ref).
"""
parse_typst(text::AbstractString) = _read_document(text, :typst)

"""
    parse_document(text::AbstractString, format::Symbol) -> OrderedDict{String, Any}

Read an ESM document written in the source format `format`: `:markdown`
([`parse_markdown`](@ref)) or `:typst` ([`parse_typst`](@ref)).
"""
parse_document(text::AbstractString, format::Symbol) =
    _check_format(format) === :markdown ? parse_markdown(text) : parse_typst(text)

# The value the printers take: `canonicalize_document` applied, then every
# object's keys sorted, as the Lean printers require (`Source.canonDoc`).
_printable_document(doc::AbstractDict) =
    DocumentFormats.DJson.sort_keys(DocumentFormats.DJson.from_value(canonicalize_document(doc)))

# Read a document.
function _read_document(text::AbstractString, format::Symbol)
    DF = DocumentFormats
    what = format === :markdown ? "an ESM Markdown document" : "an ESM Typst document"
    return _checked_read(text, format, what) do str
        format === :markdown ? DF.DSource.parse_md(str) : DF.DSource.parse_typ(str)
    end::OrderedDict{String, Any}
end

# The one checked read (Rust `checked`): the UTF-8 check, `read(str)` under the
# reader's limits, and each refusal turned into its diagnostic. The Lean reader
# refuses every bad input alike (`read` returns `nothing`); the code comes from
# the specification: a removed operator the math writes in the call form or
# the escape form is refused by name (CONFORMANCE §7.1), a text past a bound of
# the reader or holding a number beyond binary64 is a parse error, and so is
# everything else that is not `what`; the message names the first construct
# the reader gave up on, when it recorded one.
function _checked_read(read::F, text::AbstractString, format::Symbol, what::String) where {F}
    DF = DocumentFormats
    DL = DF.DLimits
    str = String(text)
    isvalid(str) ||
        throw(ParseError("the text is not valid UTF-8"; code = ERROR_CODES.PARSE_ERROR))
    v, found = DL.reading(() -> read(str))
    if found.too_deep || (v !== nothing && DL.json_depth(v) > DL.MAX_JSON_DEPTH)
        throw(
            ParseError(
                "the document nests too deeply for the reader (at most $(DL.MAX_NESTING) " *
                    "constructs open at once, and $(DL.MAX_JSON_DEPTH) levels of arrays and objects)";
                code = ERROR_CODES.PARSE_ERROR
            )
        )
    end
    if v === nothing
        found.removed_op === nothing || throw(
            ParseError(
                "`$(found.removed_op)` was removed from the format (esm-spec §4.2)";
                code = ERROR_CODES.REMOVED_OP
            )
        )
        r = found.refused
        r === nothing && throw(ParseError("not $what"; code = ERROR_CODES.PARSE_ERROR))
        # A refused construct names itself, and its line when it has one in
        # the text (line breaks before the unread rest; a byte-order mark or
        # CRLF line ends change no count).
        if r.rest_newlines < 0
            throw(ParseError("not $what: $(r.what) does not read"; code = ERROR_CODES.PARSE_ERROR))
        end
        line = 1 + count(==('\n'), str) - r.rest_newlines
        throw(
            ParseError(
                "not $what: line $line: $(r.what) does not read";
                code = ERROR_CODES.PARSE_ERROR, details = Dict{String, Any}("line" => line)
            )
        )
    end
    return try
        DF.DJson.to_value(v)
    catch e
        e isa DF.DJson.OutOfRange || rethrow()
        throw(
            ParseError(
                "the number `$(String(DF.DNumber.print(e.n)))` is outside the binary64 range";
                code = ERROR_CODES.PARSE_ERROR
            )
        )
    end
end
