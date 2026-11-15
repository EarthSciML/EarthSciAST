"""
JSON values of an ESM document, in canonical form, and the character-slice
helpers every reader of the document codecs uses.

Port of `formal/Esm/Document/Json.lean` (Rust `document::json`). The document
codecs and the math layer work on this value type, not on the binding's
`OrderedDict`/`JSON3` values: numbers are kept in the canonical form of
CONFORMANCE §5.5.3.1 (an integral value that fits in `Int64` IS an integer;
every other finite number is its shortest round-trip decimal digits and the
decimal exponent of the first digit), and object entries keep their order.
[`from_value`](@ref) and [`to_value`](@ref) convert at the public boundary.

A value is one of `JNULL`, a `Bool`, a [`JNum`](@ref), a `String`, a
[`JArr`](@ref) or a [`JObj`](@ref). Arrays and objects are wrapped so that an
empty array and an empty object never compare equal.

The readers mirror the Lean ones, which consume a list of characters and
return what they read and the rest of the list. Here the input is a
`Vector{Char}` and the rest is a view of it (`Chars`); a failed read is
`nothing`.
"""
module DJson

using OrderedCollections: OrderedDict

export JNull, JNULL, JNum, JInt, JDec, JArr, JObj, Kvs, Json, Chars,
    EOFC, at, drop, starts, strip_prefix, chars, fieldeq, in_int64, look,
    jstr, jint, sort_keys, keys_distinct, wfb

# ## Character slices

"""A read position: the rest of the input, as a view."""
const Chars = AbstractVector{Char}

"""The character [`at`](@ref) answers past the end of the input; never in a
decoded string."""
const EOFC = reinterpret(Char, 0xffffffff)

"""`r[i]`, or [`EOFC`](@ref) past the end."""
@inline at(r::Chars, i::Int = 1) = i <= length(r) ? @inbounds(r[i]) : EOFC

"""The input after its first `n` characters (`n <= length(r)`)."""
@inline drop(r::Chars, n::Int = 1) = @view r[(n + 1):end]

"""The input starts with the characters of `lit`."""
function starts(r::Chars, lit::AbstractString)
    i = 1
    for c in lit
        at(r, i) == c || return false
        i += 1
    end
    return true
end

"""The input after the prefix `lit`, or `nothing` when it does not start with
it."""
strip_prefix(r::Chars, lit::AbstractString) =
    starts(r, lit) ? drop(r, length(lit)) : nothing

"""A string's characters, as the input a reader takes."""
chars(s::AbstractString) = collect(Char, s)
chars(s::Chars) = s

"""Field-wise `==`, for the structs of the codecs whose fields hold vectors."""
fieldeq(a::T, b::T) where {T} =
    all(i -> getfield(a, i) == getfield(b, i), 1:fieldcount(T))

# ## Values

"""`Json.null`."""
struct JNull end
const JNULL = JNull()

"""A JSON number in canonical form (`Esm.Document.JNum`)."""
abstract type JNum end

"""An integer literal (well formed when it fits in `Int64`). Lean's `Int` is
unbounded; `Int128` holds every value the readers produce before the `Int64`
check rejects it."""
struct JInt <: JNum
    z::Int128
end

"""The value `±d₁.d₂d₃… × 10^e10`, with `digits` the shortest round-trip
digits (each below 10)."""
struct JDec <: JNum
    neg::Bool
    digits::Vector{UInt8}
    e10::Int
end
Base.:(==)(a::JDec, b::JDec) = a.neg == b.neg && a.digits == b.digits && a.e10 == b.e10
Base.hash(a::JDec, h::UInt) = hash((a.neg, a.digits, a.e10), hash(:JDec, h))

"""An object's entries, in order."""
const Kvs = Vector{Pair{String, Any}}

"""A JSON array."""
struct JArr
    xs::Vector{Any}
end
JArr() = JArr(Any[])
Base.:(==)(a::JArr, b::JArr) = a.xs == b.xs
Base.hash(a::JArr, h::UInt) = hash(a.xs, hash(:JArr, h))

"""A JSON object; its entries keep their order."""
struct JObj
    kvs::Kvs
end
JObj() = JObj(Kvs())
Base.:(==)(a::JObj, b::JObj) = a.kvs == b.kvs
Base.hash(a::JObj, h::UInt) = hash(a.kvs, hash(:JObj, h))

"""A document value: `JNull`, `Bool`, `JNum`, `String`, `JArr` or `JObj`."""
const Json = Any

jstr(s::AbstractString) = String(s)
jint(z::Integer) = JInt(Int128(z))

# ## Numbers

"""`JNum.InInt64`."""
in_int64(z::Integer) = typemin(Int64) <= z <= typemax(Int64)

"""`JNum.digitsVal`: the value of a big-endian digit list (`nothing` on
overflow)."""
function digits_val(ds)
    a = Int128(0)
    for d in ds
        a, o1 = Base.Checked.mul_with_overflow(a, Int128(10))
        o1 && return nothing
        a, o2 = Base.Checked.add_with_overflow(a, Int128(d))
        o2 && return nothing
    end
    return a
end

"""`JNum.decInt?`: the integer a decimal denotes, when it is integral.

`nothing` when the decimal is not integral (Lean's `none`); otherwise
`Some(z)`, with `z` `nothing` when the integer does not fit in `Int128` (so
certainly not in `Int64`)."""
function dec_int(neg::Bool, ds, e10::Integer)
    len = length(ds)
    len <= e10 + 1 || return nothing
    zeros = e10 + 1 - len
    v = digits_val(ds)
    v === nothing && return Some(nothing)
    m = v
    for _ in 1:zeros
        m, o = Base.Checked.mul_with_overflow(m, Int128(10))
        o && return Some(nothing)
    end
    return Some(neg ? -m : m)
end

"""`JNum.wfb`: the number is in canonical form."""
wfb(n::JInt) = in_int64(n.z)
function wfb(n::JDec)
    ds = n.digits
    isempty(ds) && return false
    all(<(10), ds) || return false
    (first(ds) == 0 || last(ds) == 0) && return false
    r = dec_int(n.neg, ds, n.e10)
    r === nothing && return true
    z = something(r)
    return z === nothing || !in_int64(z)
end

"""`Json.wfb`: every number canonical, every object with distinct keys."""
wfb(x::JArr) = all(wfb, x.xs)
wfb(x::JObj) = keys_distinct(x.kvs) && all(kv -> wfb(kv.second), x.kvs)
wfb(::Any) = true

"""The keys of an entry list are pairwise distinct."""
function keys_distinct(kvs)
    seen = Set{String}()
    for kv in kvs
        kv.first in seen && return false
        push!(seen, kv.first)
    end
    return true
end

"""`Math.look`: the value of key `k` (the first entry with it), or
`nothing`."""
function look(k::AbstractString, kvs)
    for kv in kvs
        kv.first == k && return kv.second
    end
    return nothing
end

"""The shortest round-trip digits of a finite nonzero `Float64` and the decimal
exponent of the first digit."""
function shortest_digits(f::Float64)
    s = repr(abs(f))   # Julia prints the shortest round-trip digits
    mant, ex = if occursin('e', s)
        a, b = split(s, 'e')
        a, parse(Int, b)
    else
        s, 0
    end
    ip, fp = occursin('.', mant) ? split(mant, '.') : (mant, "")
    raw = ip * fp
    # exponent of the first digit of `raw` is length(ip) - 1 + ex
    e10 = length(ip) - 1 + ex
    lead = 0
    while lead < length(raw) && raw[lead + 1] == '0'
        lead += 1
    end
    core = raw[(lead + 1):end]
    core = rstrip(core, '0')
    return UInt8[UInt8(c - '0') for c in core], e10 - lead
end

"""The canonical number of a finite `Float64` (§5.5.3.1): an integral value in
`Int64` is the integer, any other value its shortest round-trip digits."""
function jnum_of_f64(f::Float64)
    isfinite(f) || return nothing
    f == 0.0 && return JInt(0)
    if isinteger(f) && -0x1p63 <= f < 0x1p63
        return JInt(Int128(Int64(f)))
    end
    ds, e10 = shortest_digits(f)
    return JDec(f < 0, ds, e10)
end

"""A binding number as a canonical number."""
function jnum_of_real(x::Real)
    x isa Integer && in_int64(x) && return JInt(Int128(x))
    if x isa Integer
        ds = UInt8[UInt8(c - '0') for c in string(abs(x))]
        e10 = length(ds) - 1
        while !isempty(ds) && last(ds) == 0
            pop!(ds)
        end
        return JDec(x < 0, ds, e10)
    end
    return jnum_of_f64(Float64(x))
end

# ## Conversion at the public boundary

"""A decoded JSON value of the binding (`OrderedDict`/`Dict`/`JSON3.Object`,
vectors, strings, numbers, `nothing`) as a document value. A non-finite number
becomes `null`."""
function from_value(v)
    v === nothing && return JNULL
    v isa Bool && return v
    if v isa Real
        n = jnum_of_real(v)
        return n === nothing ? JNULL : n
    end
    v isa AbstractString && return String(v)
    v isa Symbol && return String(v)
    v isa AbstractVector && return JArr(Any[from_value(x) for x in v])
    if v isa AbstractDict
        kvs = Kvs()
        for (k, x) in pairs(v)
            push!(kvs, String(k) => from_value(x))
        end
        return JObj(kvs)
    end
    throw(ArgumentError("not a JSON value: $(typeof(v))"))
end

"""A document value as the binding's decoded JSON (`OrderedDict{String, Any}`,
`Vector{Any}`, `String`, `Int64`/`Float64`, `Bool`, `nothing`). An integer
outside `Int64` and a decimal become `Float64`, as the canonical form reads
them."""
function to_value(j)
    j isa JNull && return nothing
    j isa Bool && return j
    if j isa JInt
        return in_int64(j.z) ? Int64(j.z) : Float64(j.z)
    end
    j isa JDec && return parse(Float64, String(print_number(j)))
    j isa String && return j
    j isa JArr && return Any[to_value(x) for x in j.xs]
    if j isa JObj
        d = OrderedDict{String, Any}()
        for kv in j.kvs
            d[kv.first] = to_value(kv.second)
        end
        return d
    end
    throw(ArgumentError("not a document value: $(typeof(j))"))
end

# The number printer lives in `DNumber`; `to_value` reaches it at call time.
print_number(n) = parentmodule(@__MODULE__).DNumber.print(n)

"""The value with every object's entries sorted by key (code point order), the
key order of the canonical serialization."""
sort_keys(j::JArr) = JArr(Any[sort_keys(x) for x in j.xs])
function sort_keys(j::JObj)
    kvs = Kvs([kv.first => sort_keys(kv.second) for kv in j.kvs])
    sort!(kvs; by = first, alg = Base.Sort.DEFAULT_STABLE)
    return JObj(kvs)
end
sort_keys(j) = j

end # module DJson
