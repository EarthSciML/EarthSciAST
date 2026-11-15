"""
Lines of text, and the input decoding.

Port of `formal/Esm/Document/Source/Lines.lean` (Rust
`document::source::lines`).
"""
module SLines

using ..DJson

"""`Source.dropBOM`."""
drop_bom(s::Chars) = at(s) == '﻿' ? drop(s) : s

"""`Source.firstCRLF`: whether the first line ends in CRLF."""
function first_crlf(s::Chars)
    for i in eachindex(s)
        c = s[i]
        c == '\n' && return false
        c == '\r' && at(s, i + 1) == '\n' && return true
    end
    return false
end

"""`Source.unCRLF`: every CRLF as LF."""
function un_crlf(s::Chars)
    out = Char[]
    sizehint!(out, length(s))
    for i in eachindex(s)
        c = s[i]
        (c == '\r' && at(s, i + 1) == '\n') || push!(out, c)
    end
    return out
end

"""`Source.decodeText`: no byte-order mark, and LF line endings when the first
line ends in CRLF."""
function decode_text(s::Chars)
    d = drop_bom(s)
    return first_crlf(d) ? un_crlf(d) : collect(Char, d)
end

end # module SLines
