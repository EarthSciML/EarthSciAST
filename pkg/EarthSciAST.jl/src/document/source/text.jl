"""
Text scanning shared by the containers: prefixes, lines, and fenced bodies
ended by a closing line.

Port of `formal/Esm/Document/Source/Text.lean` (Rust
`document::source::text`).
"""
module SText

using ..DJson

"""`Source.pre`: `p` is a prefix of `s`."""
function pre(p, s::Chars)
    length(p) <= length(s) || return false
    i = 1
    for c in p
        s[i] == c || return false
        i += 1
    end
    return true
end

"""`Source.hasSub`: `p` occurs in `s`."""
has_sub(p, s::Chars) = any(i -> pre(p, drop(s, i)), 0:length(s))

"""`Source.splitLine`: the first line (without its newline) and the text after
it."""
function split_line(s::Chars)
    i = findfirst(==('\n'), s)
    i === nothing && return s, drop(s, length(s))
    return view(s, 1:(i - 1)), drop(s, i)
end

"""`Source.noStop`: no line of `s` starts with `stop`."""
function no_stop(stop, s::Chars)
    while !isempty(s)
        pre(stop, s) && return false
        s = split_line(s)[2]
    end
    return true
end

"""`Source.untilStop`: lines up to the first one that starts with `stop`: the
lines before it (each with its newline), the rest of the closing line, and the
text after the closing line; `nothing` when no line starts with `stop`."""
function until_stop(stop, s::Chars)
    body = Char[]
    while true
        isempty(s) && return nothing
        if pre(stop, s)
            a, b = split_line(drop(s, length(stop)))
            return body, a, b
        end
        line, rest = split_line(s)
        append!(body, line)
        push!(body, '\n')
        s = rest
    end
    return nothing
end

"""`l.all (· == ' ')`."""
blank(l) = all(==(' '), l)

"""`t.takeWhile p` and `t.drop (t.takeWhile p).length`."""
function take_while(t::Chars, p)
    n = 0
    while n < length(t) && p(t[n + 1])
        n += 1
    end
    return view(t, 1:n), drop(t, n)
end

"""[`pre`](@ref) with a string as the prefix."""
pre_s(p::AbstractString, s::Chars) = starts(s, p)

"""`after` (Reaction.lean) with a string as the prefix."""
after_s(p::AbstractString, s::Chars) = strip_prefix(s, p)

"""The input after its first `n` characters, or nothing of it when it is
shorter (Rust's `s.get(n..).unwrap_or(&[])`)."""
sdrop(s::Chars, n::Int) = drop(s, min(n, length(s)))

"""`String.ofList`."""
string_of(cs) = String(collect(Char, cs))

end # module SText
