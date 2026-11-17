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
    # In a reading scope of its own, as `DSource.print_md` is.
    return DocumentFormats.DSource._printing() do
        format === :markdown ? DocumentFormats.DMath.print_latex(sym, e) :
            DocumentFormats.DMath.print_typst(sym, e)
    end
end

"""
    expression_names(expr) -> Vector{String}

The variable names an expression or an equation uses, in order of first use:
its string leaves under `lhs`, `rhs` and `args`. These are the `names` to give
[`print_math`](@ref) to show an expression on its own, with its names declared.

`expr` is a decoded ESM expression or equation (the value `print_math` takes),
or a typed [`ASTExpr`](@ref) or [`Equation`](@ref).

```julia
julia> expression_names(Dict("lhs" => "y", "rhs" => Dict("op" => "*", "args" => ["k", "y"])))
2-element Vector{String}:
 "y"
 "k"
```
"""
function expression_names(expr)
    out = String[]
    _expression_names!(out, expr)
    return out
end

function _expression_names!(out::Vector{String}, v)
    if v isa AbstractString
        name = String(v)
        name in out || push!(out, name)
    elseif v isa AbstractVector
        foreach(x -> _expression_names!(out, x), v)
    elseif v isa AbstractDict
        for key in ("lhs", "rhs", "args")
            child = get(v, key, get(v, Symbol(key), nothing))
            child === nothing || _expression_names!(out, child)
        end
    elseif v isa VarExpr
        v.name in out || push!(out, v.name)
    elseif v isa OpExpr
        foreach(x -> _expression_names!(out, x), v.args)
    elseif v isa Equation
        _expression_names!(out, v.lhs)
        _expression_names!(out, v.rhs)
    end
    return out
end

"""
    parse_math(text::AbstractString, names, format::Symbol)

Read one expression, or one equation, written as math under a set of declared
names: LaTeX for `:markdown` (Lean `Math.parseLatex`), Typst math for `:typst`
(`Math.parseTypst`). The inverse of [`print_math`](@ref):
`parse_math(print_math(e, names, f), names, f)` is `e` in canonical form.

`text` is what a document display holds, without its delimiters. Text whose top
is `=` reads as an equation, an `OrderedDict` with `lhs` and `rhs`, as a display
does (`Source.eqSides`); any other text reads as an expression (a number, a name
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
    (format === :markdown || format === :typst) ||
        throw(ArgumentError("unknown document format :$format (expected :markdown or :typst)"))
    DF = DocumentFormats
    DJ = DF.DJson
    DL = DF.DLimits
    str = String(text)
    isvalid(str) ||
        throw(ParseError("the text is not valid UTF-8"; code = ERROR_CODES.PARSE_ERROR))
    sym = DF.MExpr.Sym(String[String(n) for n in names], Tuple{String, Vector{String}}[])
    e, found = DL.reading() do
        format === :markdown ? DF.DMath.parse_latex(sym, str) : DF.DMath.parse_typst(sym, str)
    end
    if e !== nothing
        sides = DF.SEquation.eq_sides(e)
        sides === nothing || (e = DJ.JObj(DJ.Kvs(["lhs" => sides[1], "rhs" => sides[2]])))
    end
    if found.too_deep || (e !== nothing && DL.json_depth(e) > DL.MAX_JSON_DEPTH)
        throw(
            ParseError(
                "the document nests too deeply for the reader (at most $(DL.MAX_NESTING) " *
                    "constructs open at once, and $(DL.MAX_JSON_DEPTH) levels of arrays and objects)";
                code = ERROR_CODES.PARSE_ERROR
            )
        )
    end
    if e === nothing
        found.removed_op === nothing || throw(_document_refusal(found.removed_op, format))
        what = format === :markdown ? "LaTeX" : "Typst"
        throw(ParseError("not an ESM expression in $what math"; code = ERROR_CODES.PARSE_ERROR))
    end
    return try
        DJ.to_value(e)
    catch err
        err isa DJ.OutOfRange || rethrow()
        throw(
            ParseError(
                "the number `$(String(DF.DNumber.print(err.n)))` is outside the binary64 range";
                code = ERROR_CODES.PARSE_ERROR
            )
        )
    end
end

# The Typst math of an expression or an equation for messages and `show`
# (`print_math` under the names it uses). A typed expression is serialized to
# its JSON form first.
function _math_text(x)
    v = x isa Equation ? Dict{String, Any}("lhs" => serialize_expression(x.lhs), "rhs" => serialize_expression(x.rhs)) :
        x isa ASTExpr ? serialize_expression(x) : x
    return print_math(v, expression_names(v), :typst)
end

# `show` of an expression or an equation: its Typst math. An expression the
# printer cannot take (e.g. a malformed node built by hand) shows as its JSON
# form, so a `show` inside an error message never throws in turn.
function _show_math(io::IO, x)
    text = try
        _math_text(x)
    catch err
        err isa InterruptException && rethrow()
        v = x isa Equation ? Dict("lhs" => serialize_expression(x.lhs), "rhs" => serialize_expression(x.rhs)) :
            serialize_expression(x)
        JSON3.write(v)
    end
    return print(io, text)
end

Base.show(io::IO, expr::ASTExpr) = _show_math(io, expr)
Base.show(io::IO, eq::Equation) = _show_math(io, eq)

# `show` of the component types: the two-argument form is a one-line summary
# (used inside reprs and collections); the `text/plain` form lists the
# component's declarations, with every expression in its Typst math.

_math_string(x) = sprint(_show_math, x)

function Base.show(io::IO, model::Model)
    return print(
        io, "Model(", length(model.variables), " variables, ",
        length(model.equations), " equations)"
    )
end

function Base.show(io::IO, ::MIME"text/plain", model::Model)
    println(io, "Model:")
    println(io, "  Variables ($(length(model.variables))):")
    for (name, var) in model.variables
        print(io, "    ", name, ": ", _variable_type_word(var.type))
        isnothing(var.default) || print(io, " = ", var.default)
        isnothing(var.units) || print(io, " [", var.units, "]")
        isnothing(var.description) || print(io, " - ", var.description)
        println(io)
        if !isnothing(var.update)
            println(io, "      update: ", join((r.kind for r in var.update), ", "))
        end
    end
    println(io, "  Equations ($(length(model.equations))):")
    for (i, eq) in enumerate(model.equations)
        println(io, "    ", i, ". ", _math_string(eq))
    end
    _show_events(io, model.discrete_events, model.continuous_events)
    return _show_subsystem_names(io, model.subsystems)
end

function Base.show(io::IO, rs::ReactionSystem)
    return print(
        io, "ReactionSystem(", length(rs.species), " species, ",
        length(rs.reactions), " reactions)"
    )
end

# One side of a reaction in chemical notation, in author order: `2A + B`,
# `∅` for an empty side.
function _show_reaction_side(entries::Union{Vector{StoichiometryEntry}, Nothing})
    (entries === nothing || isempty(entries)) && return "∅"
    coefficient(c) = c == 1 ? "" : isinteger(c) ? string(Int(c)) : string(c)
    return join((coefficient(e.stoichiometry) * e.species for e in entries), " + ")
end

function Base.show(io::IO, ::MIME"text/plain", rs::ReactionSystem)
    println(io, "ReactionSystem:")
    println(io, "  Species ($(length(rs.species))):")
    for species in rs.species
        print(io, "    ", species.name)
        isnothing(species.units) || print(io, " [", species.units, "]")
        isnothing(species.default) || print(io, " = ", species.default)
        isnothing(species.description) || print(io, " - ", species.description)
        println(io)
    end
    println(io, "  Parameters ($(length(rs.parameters))):")
    for param in rs.parameters
        print(io, "    ", param.name, " = ", isnothing(param.default) ? "unset" : param.default)
        isnothing(param.units) || print(io, " [", param.units, "]")
        isnothing(param.description) || print(io, " - ", param.description)
        println(io)
    end
    println(io, "  Reactions ($(length(rs.reactions))):")
    for (i, reaction) in enumerate(rs.reactions)
        print(
            io, "    ", i, ". ", _show_reaction_side(raw_substrates(reaction)), " → ",
            _show_reaction_side(raw_products(reaction))
        )
        isnothing(reaction.rate) || print(io, "  [rate: ", _math_string(reaction.rate), "]")
        println(io)
    end
    _show_events(io, rs.discrete_events, rs.continuous_events)
    return _show_subsystem_names(io, rs.subsystems)
end

function Base.show(io::IO, esm_file::EsmFile)
    return print(io, "EsmFile(v", esm_file.esm, ", \"", esm_file.metadata.name, "\")")
end

function Base.show(io::IO, ::MIME"text/plain", esm_file::EsmFile)
    md = esm_file.metadata
    println(io, "ESM v", esm_file.esm, ": ", md.name)
    isnothing(md.description) || println(io, "Description: ", md.description)
    isempty(md.authors) || println(io, "Authors: ", join(md.authors, ", "))
    isnothing(md.license) || println(io, "License: ", md.license)
    isempty(md.tags) || println(io, "Tags: ", join(md.tags, ", "))
    for (label, section) in (
            ("Models", esm_file.models),
            ("Reaction systems", esm_file.reaction_systems),
            ("Data sources", esm_file.data_sources),
        )
        (isnothing(section) || isempty(section)) && continue
        println(io, label, " (", length(section), "): ", join(keys(section), ", "))
    end
    isempty(esm_file.coupling) || println(io, "Coupling entries: ", length(esm_file.coupling))
    isnothing(esm_file.domain) || println(io, "Domain: configured")
    return nothing
end

function _show_events(io::IO, discrete, continuous)
    affects(as) = join((string(a.lhs, " = ", _math_string(a.rhs)) for a in as), ", ")
    if !isempty(discrete)
        println(io, "  Discrete events ($(length(discrete))):")
        for (i, event) in enumerate(discrete)
            t = event.trigger
            trigger = t isa ConditionTrigger ? "when " * _math_string(t.expression) :
                t isa PeriodicTrigger ? "every $(t.period) s" :
                t isa PresetTimesTrigger ? "at times [" * join(t.times, ", ") * "]" :
                string(nameof(typeof(t)))
            println(io, "    ", i, ". ", trigger, ": ", affects(event.affects))
        end
    end
    if !isempty(continuous)
        println(io, "  Continuous events ($(length(continuous))):")
        for (i, event) in enumerate(continuous)
            conditions = join((_math_string(c) for c in event.conditions), ", ")
            println(io, "    ", i, ". when [", conditions, "] → [", affects(event.affects), "]")
        end
    end
    return nothing
end

function _show_subsystem_names(io::IO, subsystems)
    isempty(subsystems) || println(io, "  Subsystems ($(length(subsystems))): ", join(keys(subsystems), ", "))
    return nothing
end

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
function parse_document(text::AbstractString, format::Symbol)
    format === :markdown && return parse_markdown(text)
    format === :typst && return parse_typst(text)
    throw(ArgumentError("unknown document format :$format (expected :markdown or :typst)"))
end

# The value the printers take: `canonicalize_document` applied, then every
# object's keys sorted, as the Lean printers require (`Source.canonDoc`).
_printable_document(doc::AbstractDict) =
    DocumentFormats.DJson.sort_keys(DocumentFormats.DJson.from_value(canonicalize_document(doc)))

# Read a document, and turn a refusal into its diagnostic (Rust `read` and
# `checked`).
function _read_document(text::AbstractString, format::Symbol)
    DF = DocumentFormats
    DL = DF.DLimits
    str = String(text)
    isvalid(str) ||
        throw(ParseError("the text is not valid UTF-8"; code = ERROR_CODES.PARSE_ERROR))
    d, found = DL.reading() do
        format === :markdown ? DF.DSource.parse_md(str) : DF.DSource.parse_typ(str)
    end
    if found.too_deep || (d !== nothing && DL.json_depth(d) > DL.MAX_JSON_DEPTH)
        throw(
            ParseError(
                "the document nests too deeply for the reader (at most $(DL.MAX_NESTING) " *
                    "constructs open at once, and $(DL.MAX_JSON_DEPTH) levels of arrays and objects)";
                code = ERROR_CODES.PARSE_ERROR
            )
        )
    end
    d === nothing && throw(_document_refusal(found.removed_op, format))
    return try
        DF.DJson.to_value(d)::OrderedDict{String, Any}
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

# The diagnostic for a text the reader refused. The Lean reader refuses every
# bad input alike; the code comes from the specification: a removed operator
# the math writes in the call form or the escape form is refused by name
# (CONFORMANCE §7.1), everything else is a parse error.
function _document_refusal(removed_op::Union{Nothing, String}, format::Symbol)
    if removed_op !== nothing
        return ParseError(
            "`$removed_op` was removed from the format (esm-spec §4.2)";
            code = ERROR_CODES.REMOVED_OP
        )
    end
    what = format === :markdown ? "Markdown" : "Typst"
    return ParseError("not an ESM $what document"; code = ERROR_CODES.PARSE_ERROR)
end
