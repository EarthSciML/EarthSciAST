"""
The Typst value codec: a JSON value as a Typst code-mode value.

Port of `formal/Esm/Document/TypstDict.lean` (Rust `document::typst_dict`).

* `none`, `true`, `false`; numbers in the canonical spelling, except `-2^63`,
  printed `(-9223372036854775807 - 1)` because Typst reads the literal
  `-9223372036854775808` as a float;
* strings with Typst escapes (`\\u{XXXX}`);
* arrays `(a, b)`, `()` empty; dictionaries `(key: v, "quoted key": v)`,
  `(:)` empty. A key is bare when it is an identifier and not a Typst keyword;
* a math leaf `\$…\$`, Typst math content: its text up to the next `\$`
  (`Json.mathOK`). Only a path block holds one (`Source.mathify`).

The canonical layout is one element per line, each indented two spaces deeper
than the opening line and followed by `,`. The reader skips whitespace between
tokens, accepts a trailing comma or none, and rejects a one-element array
without its comma (Typst reads `(x)` as `x`).
"""
module DTypstDict

using ..DJson
import ..DNumber
using ..DLimits: nested
using ..DStrings: parse_key, parse_quoted, print_key, quote_str, spaces

"""`TypstDict.keywords`: Typst keywords, which cannot be bare dictionary keys."""
const KEYWORDS = Set{String}(
    [
        "none", "auto", "true", "false", "not", "and", "or", "let", "set", "show", "if",
        "else", "for", "in", "while", "break", "continue", "return", "import", "include",
        "context", "as", "_",
    ]
)

"""`TypstDict.reserved`."""
reserved(k::AbstractString) = k in KEYWORDS

const INT64_MIN = Int128(typemin(Int64))
const MIN_LIT = "-9223372036854775807"

"""`TypstDict.printNum`."""
print_num(n::JNum) =
    (n isa JInt && n.z == INT64_MIN) ? collect("(-9223372036854775807 - 1)") : DNumber.print(n)

"""`TypstDict.enc`: the canonical print of a value whose first line is indented
by `m` spaces (the indentation itself is not printed)."""
function enc(m::Int, v, out::Vector{Char})
    if v isa JNull
        append!(out, "none")
    elseif v === true
        append!(out, "true")
    elseif v === false
        append!(out, "false")
    elseif v isa JNum
        append!(out, print_num(v))
    elseif v isa String
        append!(out, quote_str(true, v))
    elseif v isa JMath
        push!(out, '$')
        append!(out, v.s)
        push!(out, '$')
    elseif v isa JArr
        if isempty(v.xs)
            push!(out, '(', ')')
        else
            push!(out, '(', '\n')
            for x in v.xs
                append!(out, spaces(m + 2))
                enc(m + 2, x, out)
                push!(out, ',', '\n')
            end
            append!(out, spaces(m))
            push!(out, ')')
        end
    elseif v isa JObj
        if isempty(v.kvs)
            push!(out, '(', ':', ')')
        else
            push!(out, '(', '\n')
            for (k, x) in v.kvs
                append!(out, spaces(m + 2))
                append!(out, print_key(true, reserved, k))
                push!(out, ':', ' ')
                enc(m + 2, x, out)
                push!(out, ',', '\n')
            end
            append!(out, spaces(m))
            push!(out, ')')
        end
    else
        error("not a document value")
    end
    return out
end

"""`TypstDict.encode`: the canonical Typst spelling of a value, as characters."""
encode(v) = enc(0, v, Char[])

"""`TypstDict.isWs`."""
is_ws(c::Char) = c == ' ' || c == '\n' || c == '\t' || c == '\r'

"""`TypstDict.skipWs`."""
function skip_ws(r::Chars)
    n = 0
    while is_ws(at(r, n + 1))
        n += 1
    end
    return drop(r, n)
end

"""`TypstDict.isEntry`: the input starts with a key and a colon."""
function is_entry(input::Chars)
    x = parse_key(true, reserved, input)
    x === nothing && return false
    return at(skip_ws(x[2])) == ':'
end

# `TypstDict.pNext`: what follows one element: `(:more, rest)` for `,` and
# another element, `(:close_comma, rest)` / `(:close, rest)` for `)` after a
# `,` or directly.
function p_next(r::Chars)
    r = skip_ws(r)
    c = at(r)
    if c == ','
        r1 = skip_ws(drop(r))
        at(r1) == ')' && return :close_comma, drop(r1)
        return :more, r1
    elseif c == ')'
        return :close, drop(r)
    end
    return nothing
end

# `TypstDict.pMin`: after `(` and any whitespace, the rest of
# `(-9223372036854775807 - 1)`.
function p_min(r::Chars)
    r1 = strip_prefix(r, MIN_LIT)
    r1 === nothing && return nothing
    r2 = skip_ws(r1)
    at(r2) == '-' || return nothing
    r3 = skip_ws(drop(r2))
    at(r3) == '1' || return nothing
    r4 = skip_ws(drop(r3))
    at(r4) == ')' || return nothing
    return drop(r4)
end

"""`TypstDict.pVal`: a value, at its first character."""
p_val(input::Chars) = nested(_p_val, input)

# The body of `p_val`, with its construct open (Rust `Nest::enter`).
function _p_val(input::Chars)
    c = at(input)
    c == EOFC && return nothing
    if c == '('
        r = skip_ws(drop(input))
        r1 = p_min(r)
        r1 !== nothing && return JInt(INT64_MIN), r1
        return p_paren(r)
    elseif c == '"'
        return parse_quoted(true, input)
    elseif c == '$'
        return p_math(drop(input))
    elseif c == 'n'
        r = strip_prefix(input, "none")
        return r === nothing ? nothing : (JNULL, r)
    elseif c == 't'
        r = strip_prefix(input, "true")
        return r === nothing ? nothing : (true, r)
    elseif c == 'f'
        r = strip_prefix(input, "false")
        return r === nothing ? nothing : (false, r)
    end
    return DNumber.parse(input)
end

# `TypstDict.pParen`: after `(` and any whitespace.
function p_paren(input::Chars)
    c = at(input)
    c == EOFC && return nothing
    c == ')' && return JArr(), drop(input)
    if c == ':'
        r1 = skip_ws(drop(input))
        at(r1) == ')' || return nothing
        return JObj(), drop(r1)
    end
    if is_entry(input)
        x = p_entries(input)
        x === nothing && return nothing
        return JObj(x[1]), x[2]
    end
    x = p_items(input)
    x === nothing && return nothing
    return JArr(x[1]), x[2]
end

# `TypstDict.pItems`: array elements; the first needs a `,` after it even when
# it is the last.
function p_items(input::Chars)
    out = Any[]
    first = true
    while true
        x = p_val(input)
        x === nothing && return nothing
        push!(out, x[1])
        n = p_next(x[2])
        n === nothing && return nothing
        tag, r1 = n
        if tag === :more
            input = r1
            first = false
        else
            (first && tag === :close) && return nothing
            return out, r1
        end
    end
    return nothing
end

# `TypstDict.pEntries`: dictionary entries, at the first key.
function p_entries(input::Chars)
    out = Kvs()
    while true
        x = parse_key(true, reserved, input)
        x === nothing && return nothing
        k, r = x
        r = skip_ws(r)
        at(r) == ':' || return nothing
        y = p_val(skip_ws(drop(r)))
        y === nothing && return nothing
        push!(out, k => y[1])
        n = p_next(y[2])
        n === nothing && return nothing
        tag, r3 = n
        tag === :more || return out, r3
        input = r3
    end
    return nothing
end

"""`TypstDict.decode`: whitespace, the value, whitespace, end of input. The
value must be well formed, math leaves allowed (`Json.WFm`)."""
function decode(s::Chars)
    x = p_val(skip_ws(s))
    x === nothing && return nothing
    v, r = x
    (isempty(skip_ws(r)) && wfmb(v)) || return nothing
    return v
end

end # module DTypstDict
