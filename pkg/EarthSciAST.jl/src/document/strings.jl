"""
Lexical pieces shared by the YAML and Typst codecs.

Port of `formal/Esm/Document/Strings.lean` (Rust `document::strings`):
double-quoted strings with JSON-style escapes (YAML writes the hex escape
`\\uXXXX`, Typst `\\u{XXXX}`; `braces` selects the Typst spelling), bare
identifier keys, and the characters a number or a key never starts with.
"""
module DStrings

using ..DJson

"""`Strings.hexChar`: a lowercase hex digit."""
hex_char(d::Integer) = d < 10 ? Char(48 + d) : Char(87 + d)

"""`Strings.hexVal`: the value of a hex digit (either case)."""
function hex_val(c::Char)
    '0' <= c <= '9' && return UInt32(c) - 48
    'a' <= c <= 'f' && return UInt32(c) - 87
    'A' <= c <= 'F' && return UInt32(c) - 55
    return nothing
end

"""`Strings.hex4`."""
hex4(n::Integer) = (hex_char(n ÷ 4096 % 16), hex_char(n ÷ 256 % 16), hex_char(n ÷ 16 % 16), hex_char(n % 16))

"""`Strings.hex4Val`."""
function hex4_val(a::Char, b::Char, c::Char, d::Char)
    va, vb, vc, vd = hex_val(a), hex_val(b), hex_val(c), hex_val(d)
    (va === nothing || vb === nothing || vc === nothing || vd === nothing) && return nothing
    return va * 4096 + vb * 256 + vc * 16 + vd
end

"""`Strings.needsHex`: characters written as a hex escape."""
function needs_hex(c::Char)
    n = UInt32(c)
    return n < 0x20 || n == 0x7f || 0x80 <= n <= 0x9f || n == 0x2028 || n == 0x2029 ||
        n == 0xfeff || n == 0xfffe || n == 0xffff
end

"""`Strings.escChar`."""
function esc_char(braces::Bool, c::Char, out::Vector{Char})
    if c == '"'
        push!(out, '\\', '"')
    elseif c == '\\'
        push!(out, '\\', '\\')
    elseif c == '\n'
        push!(out, '\\', 'n')
    elseif c == '\t'
        push!(out, '\\', 't')
    elseif c == '\r'
        push!(out, '\\', 'r')
    elseif needs_hex(c)
        push!(out, '\\', 'u')
        if braces
            push!(out, '{', hex4(UInt32(c))..., '}')
        else
            push!(out, hex4(UInt32(c))...)
        end
    else
        push!(out, c)
    end
    return out
end

"""`Strings.escape`: the escaped characters of a string, without the quotes."""
function escape(braces::Bool, cs)
    out = Char[]
    sizehint!(out, length(cs))
    for c in cs
        esc_char(braces, c, out)
    end
    return out
end

"""`Strings.quote`: a double-quoted string literal."""
function quote_str(braces::Bool, s)
    out = Char['"']
    for c in s
        esc_char(braces, c, out)
    end
    push!(out, '"')
    return out
end

"""Lean's `Char.ofNat`: a surrogate code point becomes `'\\0'`."""
char_of(n::Integer) = (0xd800 <= n <= 0xdfff || n > 0x10ffff) ? '\0' : Char(n)

"""`Strings.unquoteBody`: the characters up to the closing quote, and what
follows it."""
function unquote_body(braces::Bool, input::Chars)
    out = Char[]
    while true
        c = at(input)
        c == EOFC && return nothing
        if c == '"'
            return out, drop(input)
        elseif c == '\\'
            d = at(input, 2)
            if d == '"'
                push!(out, '"')
                input = drop(input, 2)
            elseif d == '\\'
                push!(out, '\\')
                input = drop(input, 2)
            elseif d == 'n'
                push!(out, '\n')
                input = drop(input, 2)
            elseif d == 't'
                push!(out, '\t')
                input = drop(input, 2)
            elseif d == 'r'
                push!(out, '\r')
                input = drop(input, 2)
            elseif d == 'u'
                if at(input, 3) == '{' && at(input, 8) == '}' && length(input) >= 8
                    braces || return nothing
                    v = hex4_val(input[4], input[5], input[6], input[7])
                    v === nothing && return nothing
                    push!(out, char_of(v))
                    input = drop(input, 8)
                elseif length(input) >= 6
                    braces && return nothing
                    v = hex4_val(input[3], input[4], input[5], input[6])
                    v === nothing && return nothing
                    push!(out, char_of(v))
                    input = drop(input, 6)
                else
                    return nothing
                end
            else
                return nothing
            end
        else
            push!(out, c)
            input = drop(input)
        end
    end
    return nothing
end

"""`Strings.parseQuoted`."""
function parse_quoted(braces::Bool, input::Chars)
    at(input) == '"' || return nothing
    x = unquote_body(braces, drop(input))
    x === nothing && return nothing
    return String(x[1]), x[2]
end

"""`Strings.isIdentStart` (ASCII letters, as Lean's `Char.isAlpha`)."""
is_ident_start(c::Char) = ('a' <= c <= 'z') || ('A' <= c <= 'Z') || c == '_'

"""`Strings.isIdentChar`."""
is_ident_char(c::Char) = is_ident_start(c) || ('0' <= c <= '9')

"""`Strings.isIdent`: `[A-Za-z_][A-Za-z0-9_]*`."""
function is_ident(cs)
    isempty(cs) && return false
    first(cs) isa Char || return false
    is_ident_start(first(cs)) || return false
    for (i, c) in enumerate(cs)
        i == 1 && continue
        is_ident_char(c) || return false
    end
    return true
end

"""`Strings.readIdent`: the maximal run of identifier characters at the front
(the run and the rest)."""
function read_ident(input::Chars)
    n = 0
    while is_ident_char(at(input, n + 1))
        n += 1
    end
    return view(input, 1:n), drop(input, n)
end

"""`Strings.spaces`."""
spaces(n::Integer) = fill(' ', n)

"""`Strings.bareKey`: a key prints bare when it is an identifier and not one of
the codec's reserved words."""
bare_key(reserved, k::AbstractString) = is_ident(k) && !reserved(k)

"""`Strings.printKey`."""
print_key(braces::Bool, reserved, k::AbstractString) =
    bare_key(reserved, k) ? collect(Char, k) : quote_str(braces, k)

"""`Strings.parseKey`: quoted, or an identifier that is not a reserved word."""
function parse_key(braces::Bool, reserved, input::Chars)
    c = at(input)
    c == EOFC && return nothing
    c == '"' && return parse_quoted(braces, input)
    if is_ident_start(c)
        id, r = read_ident(input)
        s = String(id)
        return reserved(s) ? nothing : (s, r)
    end
    return nothing
end

end # module DStrings
