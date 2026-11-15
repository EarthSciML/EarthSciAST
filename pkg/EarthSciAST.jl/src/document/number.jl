"""
The canonical number spelling (CONFORMANCE §5.5.3.1).

Port of `formal/Esm/Document/Number.lean` (and `Esm.digitChar` from
`formal/Esm/Digits.lean`); Rust `document::number`.

* An integer prints plainly, `-` for a negative one.
* A decimal prints its digits positionally when its decimal exponent is in
  `[-4, 5]`, and otherwise as `d.f…e<exp>` with at least one fraction digit.

[`parse`](@ref) reads any decimal spelling and returns the canonical number;
[`parse_raw`](@ref) reads the token as written. A digit run whose value does
not fit in `Int128` is not a number token (it has no canonical form either
way, since it is outside `Int64`).
"""
module DNumber

using ..DJson
using ..DJson: digits_val, dec_int

"""`Esm.digitChar`."""
digit_char(d::Integer) = Char(UInt32('0') + UInt32(d))

"""`Number.charDigit` (Lean's natural subtraction: `0` below `'0'`)."""
char_digit(c::Char) = UInt8(max(Int(UInt32(c)) - 48, 0))

"""`Number.natDigits`: the decimal digits, `[0]` for zero."""
nat_digits(n::Integer) = UInt8[UInt8(c - '0') for c in string(n)]

"""`Number.leadZero`."""
lead_zero(ip) = length(ip) > 1 && first(ip) == 0

"""`Number.printNat`."""
print_nat(n::Integer) = collect(Char, string(n))

"""`Number.printInt`."""
print_int(z::Integer) = collect(Char, string(z))

"""`Number.readDigits`: the maximal run of digit characters at the front."""
function read_digits(input::Chars)
    n = 0
    while isdigit_ascii(at(input, n + 1))
        n += 1
    end
    return UInt8[char_digit(input[i]) for i in 1:n], drop(input, n)
end

isdigit_ascii(c::Char) = '0' <= c <= '9'

"""`Number.parseNat`."""
function parse_nat(input::Chars)
    ds, r = read_digits(input)
    isempty(ds) && return nothing
    v = digits_val(ds)
    v === nothing && return nothing
    return v, r
end

"""`Number.parseInt`: an optional `-`, then digits."""
function parse_int(input::Chars)
    if at(input) == '-'
        x = parse_nat(drop(input))
        x === nothing && return nothing
        return -x[1], x[2]
    end
    return parse_nat(input)
end

"""`Number.fracDigits`."""
frac_digits(fp) = isempty(fp) ? UInt8[0] : collect(UInt8, fp)

"""`Number.decBody`: the unsigned spelling of `d₁.d₂… × 10^e10`."""
function dec_body(ds, e10::Integer)
    out = Char[]
    if !(-4 <= e10 <= 5)
        isempty(ds) && return out
        push!(out, digit_char(ds[1]), '.')
        append!(out, digit_char.(frac_digits(ds[2:end])))
        push!(out, 'e')
        append!(out, print_int(e10))
    elseif e10 < 0
        push!(out, '0', '.')
        for _ in 1:(-e10 - 1)
            push!(out, '0')
        end
        append!(out, digit_char.(ds))
    else
        k = e10 + 1
        for i in 1:min(k, length(ds))
            push!(out, digit_char(ds[i]))
        end
        for _ in 1:max(k - length(ds), 0)
            push!(out, '0')
        end
        push!(out, '.')
        rest = length(ds) > k ? ds[(k + 1):end] : UInt8[]
        append!(out, digit_char.(frac_digits(rest)))
    end
    return out
end

"""`Number.print`: the canonical spelling of a number, as characters."""
print(n::JInt) = print_int(n.z)
function print(n::JDec)
    out = n.neg ? Char['-'] : Char[]
    append!(out, dec_body(n.digits, n.e10))
    return out
end

"""[`print`](@ref) as a `String`."""
print_string(n::JNum) = String(print(n))

"""`Number.mkDec`: the decimal with digits `ds` (leading and trailing zeros
dropped) whose first listed digit sits at decimal exponent `e10`."""
function mk_dec(neg::Bool, ds, e10::Integer)
    lead = 0
    while lead < length(ds) && ds[lead + 1] == 0
        lead += 1
    end
    core = collect(UInt8, ds[(lead + 1):end])
    while !isempty(core) && last(core) == 0
        pop!(core)
    end
    return JDec(neg, core, e10 - lead)
end

"""`Number.finishDec`: an optional `e` exponent after the fraction digits."""
function finish_dec(neg::Bool, ds, e10::Integer, r::Chars)
    if at(r) == 'e'
        x = parse_int(drop(r))
        x === nothing && return nothing
        ex, rest = x
        in_int64(ex) || return nothing
        s, o = Base.Checked.add_with_overflow(Int64(e10), Int64(ex))
        o && return nothing
        return mk_dec(neg, ds, s), rest
    end
    return mk_dec(neg, ds, e10), r
end

"""`Number.afterInt`."""
function after_int(neg::Bool, ip, r::Chars)
    if at(r) == '.'
        q, rest = read_digits(drop(r))
        isempty(q) && return nothing
        ds = vcat(collect(UInt8, ip), q)
        return finish_dec(neg, ds, length(ip) - 1, rest)
    end
    v = digits_val(ip)
    v === nothing && return nothing
    return JInt(neg ? -v : v), r
end

"""`Number.parseRaw`: a number token as written, not yet canonical."""
function parse_raw(input::Chars)
    neg = at(input) == '-'
    s = neg ? drop(input) : input
    p, rest = read_digits(s)
    (isempty(p) || lead_zero(p)) && return nothing
    return after_int(neg, p, rest)
end

"""`Number.canonize`."""
canonize(n::JInt) = n
function canonize(n::JDec)
    isempty(n.digits) && return JInt(0)
    r = dec_int(n.neg, n.digits, n.e10)
    if r !== nothing
        z = something(r)
        z !== nothing && in_int64(z) && return JInt(z)
    end
    return n
end

"""`Number.parse`: a number token, in canonical form."""
function parse(input::Chars)
    x = parse_raw(input)
    x === nothing && return nothing
    c = canonize(x[1])
    return wfb(c) ? (c, x[2]) : nothing
end

end # module DNumber
