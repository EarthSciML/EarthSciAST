"""
The YAML subset of front matter and container bodies.

Port of `formal/Esm/Document/Yaml.lean` (Rust `document::yaml`). The printed
text is block-style YAML 1.2:

* a non-empty object is one `key: value` line per entry, a non-empty array
  one `- item` line per element, at the current indentation;
* a scalar, `[]` or `{}` follows its `key: ` or `- ` on the same line;
* a non-empty container under a key starts on the next line, two spaces
  deeper; a non-empty object as an array element starts on the `- ` line,
  its other entries aligned with its first key; a non-empty array as an
  element starts on the next line, two spaces deeper.

Strings are always double-quoted with JSON-style escapes, so a math leaf
(path blocks only, `Source.mathify`) is the plain scalar `\$…\$`, its text up
to the next `\$` (`Json.mathOK`); the printer makes one only of text that is
[`plain_math_ok`](@ref), which every YAML 1.2 parser reads as that string. A
key is bare when
it is an identifier and not one of YAML's special plain scalars in any letter
case; a key longer than 1024 characters uses the explicit `? "key"` form. The
reader accepts only this layout and well-formed values. The binding needs no
YAML library: this is the whole of the YAML a document holds.
"""
module DYaml

using ..DJson
import ..DNumber
using ..DLimits: nested
using ..DStrings: is_ident_start, needs_hex, parse_key, parse_quoted, print_key, quote_str, spaces

"""`Yaml.specialWords`."""
const SPECIAL_WORDS = ("true", "false", "null", "yes", "no", "on", "off", "y", "n")

"""`Yaml.reserved`: a key equal (in any ASCII letter case) to a special plain
scalar."""
function reserved(k::AbstractString)
    length(k) <= 5 || return false
    lower = String(map(c -> 'A' <= c <= 'Z' ? c + 32 : c, collect(Char, k)))
    return lower in SPECIAL_WORDS
end

"""`Yaml.longKey`."""
long_key(k::AbstractString) = 1024 < length(print_key(false, reserved, k))

"""`Yaml.keyPart`: the key of an entry at indentation `m`, up to its `:`."""
function key_part(m::Int, k::AbstractString, out::Vector{Char})
    if long_key(k)
        push!(out, '?', ' ')
        append!(out, quote_str(false, k))
        push!(out, '\n')
        append!(out, spaces(m))
    else
        append!(out, print_key(false, reserved, k))
    end
    return out
end

"""`Yaml.plainMathOK`: math text YAML holds as the plain scalar `\$…\$`, which a
YAML 1.2 parser reads as that string: [`math_ok`](@ref), and no `: ` (a mapping
indicator), no ` #` (a comment) and no character of `needs_hex`. The Markdown
printer leaves any other expression in its block as JSON."""
plain_math_ok(s::AbstractString) =
    math_ok(s) && !any(needs_hex, s) && !occursin(": ", s) && !occursin(" #", s)

"""`Yaml.inline`: the one-line spelling of a scalar or an empty container."""
function inline(v)
    v isa JNull && return collect("null")
    v === true && return collect("true")
    v === false && return collect("false")
    v isa JNum && return DNumber.print(v)
    v isa String && return quote_str(false, v)
    v isa JMath && return Char['$', v.s..., '$']
    v isa JArr && return Char['[', ']']
    v isa JObj && return Char['{', '}']
    error("not a document value")
end

function inline_line(v, out::Vector{Char})
    push!(out, ' ')
    append!(out, inline(v))
    push!(out, '\n')
    return out
end

"""`Yaml.encItems`: the lines of a non-empty array at indentation `m`."""
function enc_items(m::Int, vs, out::Vector{Char})
    for v in vs
        append!(out, spaces(m))
        push!(out, '-')
        item_body(m, v, out)
    end
    return out
end

"""`Yaml.itemBody`: what follows the `-` of an array element."""
function item_body(m::Int, v, out::Vector{Char})
    if v isa JArr && !isempty(v.xs)
        push!(out, '\n')
        enc_items(m + 2, v.xs, out)
    elseif v isa JObj && !isempty(v.kvs)
        k, x = v.kvs[1]
        push!(out, ' ')
        key_part(m + 2, k, out)
        push!(out, ':')
        val_body(m + 2, x, out)
        enc_entries(m + 2, view(v.kvs, 2:length(v.kvs)), out)
    else
        inline_line(v, out)
    end
    return out
end

"""`Yaml.encEntries`: the lines of a non-empty object at indentation `m`."""
function enc_entries(m::Int, es, out::Vector{Char})
    for (k, v) in es
        append!(out, spaces(m))
        key_part(m, k, out)
        push!(out, ':')
        val_body(m, v, out)
    end
    return out
end

"""`Yaml.valBody`: what follows the `:` of an entry whose key is at indentation
`m`."""
function val_body(m::Int, v, out::Vector{Char})
    if v isa JArr && !isempty(v.xs)
        push!(out, '\n')
        enc_items(m + 2, v.xs, out)
    elseif v isa JObj && !isempty(v.kvs)
        push!(out, '\n')
        enc_entries(m + 2, v.kvs, out)
    else
        inline_line(v, out)
    end
    return out
end

"""`Yaml.encode`: the canonical YAML spelling of a value, as characters."""
function encode(v)
    out = Char[]
    if v isa JArr && !isempty(v.xs)
        enc_items(0, v.xs, out)
    elseif v isa JObj && !isempty(v.kvs)
        enc_entries(0, v.kvs, out)
    else
        append!(out, inline(v))
        push!(out, '\n')
    end
    return out
end

# ## Reader

"""`Yaml.dropSp`: drop exactly `n` leading spaces."""
function drop_sp(n::Int, l::Chars)
    length(l) >= n || return nothing
    for i in 1:n
        l[i] == ' ' || return nothing
    end
    return drop(l, n)
end

"""`Yaml.parseKeyAt`: an explicit `? "key"` line followed by the indentation of
the `:` line, or a plain key."""
function parse_key_at(m::Int, input::Chars)
    c = at(input)
    c == EOFC && return nothing
    if c == '?'
        at(input, 2) == ' ' || return nothing
        x = parse_quoted(false, drop(input, 2))
        x === nothing && return nothing
        k, r = x
        at(r) == '\n' || return nothing
        r3 = drop_sp(m, drop(r))
        r3 === nothing && return nothing
        return k, r3
    end
    return parse_key(false, reserved, input)
end

"""`Yaml.pInline`: a scalar or an empty container."""
function p_inline(input::Chars)
    c = at(input)
    c == EOFC && return nothing
    if c == 'n'
        r = strip_prefix(input, "null")
        return r === nothing ? nothing : (JNULL, r)
    elseif c == 't'
        r = strip_prefix(input, "true")
        return r === nothing ? nothing : (true, r)
    elseif c == 'f'
        r = strip_prefix(input, "false")
        return r === nothing ? nothing : (false, r)
    elseif c == '['
        r = strip_prefix(input, "[]")
        return r === nothing ? nothing : (JArr(), r)
    elseif c == '{'
        r = strip_prefix(input, "{}")
        return r === nothing ? nothing : (JObj(), r)
    elseif c == '"'
        return parse_quoted(false, input)
    elseif c == '$'
        return p_math(drop(input))
    end
    return DNumber.parse(input)
end

"""`Yaml.pScalarLine`: a scalar and the end of its line."""
function p_scalar_line(input::Chars)
    x = p_inline(input)
    x === nothing && return nothing
    v, r = x
    at(r) == '\n' || return nothing
    return v, drop(r)
end

"""`Yaml.isItemLine`."""
function is_item_line(m::Int, input::Chars)
    r = drop_sp(m, input)
    return r !== nothing && at(r) == '-'
end

"""`Yaml.isEntryLine`."""
function is_entry_line(m::Int, input::Chars)
    r = drop_sp(m, input)
    r === nothing && return false
    c = at(r)
    c == EOFC && return false
    return c == '"' || c == '?' || is_ident_start(c)
end

"""`Yaml.pItems`: array elements at indentation `m`."""
function p_items(m::Int, input::Chars)
    out = Any[]
    while is_item_line(m, input)
        x = p_item_body(m, drop(input, m + 1))
        x === nothing && return nothing
        push!(out, x[1])
        input = x[2]
    end
    return out, input
end

"""`Yaml.pItemBody`: after the `-` of an element at indentation `m`."""
p_item_body(m::Int, input::Chars) = nested(_p_item_body, m, input)

# The body of `p_item_body`, with its construct open (Rust `Nest::enter`).
function _p_item_body(m::Int, input::Chars)
    c = at(input)
    if c == '\n'
        x = p_items(m + 2, drop(input))
        x === nothing && return nothing
        return JArr(x[1]), x[2]
    elseif c == ' '
        r = drop(input)
        e = p_entry(m + 2, r)
        if e !== nothing
            y = p_entries(m + 2, e[2])
            y === nothing && return nothing
            es = y[1]
            pushfirst!(es, e[1])
            return JObj(es), y[2]
        end
        return p_scalar_line(r)
    end
    return nothing
end

"""`Yaml.pEntries`: object entries at indentation `m`."""
function p_entries(m::Int, input::Chars)
    out = Kvs()
    while is_entry_line(m, input)
        x = p_entry(m, drop(input, m))
        x === nothing && return nothing
        push!(out, x[1])
        input = x[2]
    end
    return out, input
end

"""`Yaml.pEntry`: one entry, at its key."""
function p_entry(m::Int, input::Chars)
    x = parse_key_at(m, input)
    x === nothing && return nothing
    k, r = x
    at(r) == ':' || return nothing
    y = p_val_body(m, drop(r))
    y === nothing && return nothing
    return (k => y[1]), y[2]
end

"""`Yaml.pValBody`: after the `:` of an entry whose key is at indentation
`m`."""
p_val_body(m::Int, input::Chars) = nested(_p_val_body, m, input)

# The body of `p_val_body`, with its construct open (Rust `Nest::enter`).
function _p_val_body(m::Int, input::Chars)
    c = at(input)
    if c == ' '
        return p_scalar_line(drop(input))
    elseif c == '\n'
        r = drop(input)
        if is_item_line(m + 2, r)
            x = p_items(m + 2, r)
            x === nothing && return nothing
            return JArr(x[1]), x[2]
        end
        x = p_entries(m + 2, r)
        x === nothing && return nothing
        return JObj(x[1]), x[2]
    end
    return nothing
end

"""`Yaml.topIsArray`."""
top_is_array(input::Chars) =
    is_item_line(0, input) && length(input) >= 2 && (input[2] == ' ' || input[2] == '\n')

"""`Yaml.pTop`: an array, an object, or one scalar line."""
function p_top(input::Chars)
    if top_is_array(input)
        x = p_items(0, input)
        x === nothing && return nothing
        return JArr(x[1]), x[2]
    end
    e = p_entry(0, input)
    if e !== nothing
        y = p_entries(0, e[2])
        y === nothing && return nothing
        es = y[1]
        pushfirst!(es, e[1])
        return JObj(es), y[2]
    end
    return p_scalar_line(input)
end

"""`Yaml.decode`: all of the input consumed, and the value well formed (math
leaves allowed, `Json.WFm`)."""
function decode(s::Chars)
    x = p_top(s)
    x === nothing && return nothing
    v, r = x
    (isempty(r) && wfmb(v)) || return nothing
    return v
end

end # module DYaml
