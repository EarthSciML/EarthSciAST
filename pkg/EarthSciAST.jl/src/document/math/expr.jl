"""
Expressions as JSON values, and the symbol table.

Port of `formal/Esm/Document/Math/Expr.lean` (Rust `document::math::expr`).
An expression is the JSON value at an expression position (spec §4.1): a
number, a name (dot-separated identifier segments), or a node (`op`, `args` and
any other fields). [`is_e`](@ref) is the well-formedness check;
[`Sym`](@ref) is what a document declares.
"""
module MExpr

using ..DJson
using ..DJson: dec_int

# ## Characters (`Math.isLetter` …): ASCII only.

"""`Math.isLetter`."""
is_letter(c::Char) = ('a' <= c <= 'z') || ('A' <= c <= 'Z')
"""`Math.isUpper`."""
is_upper(c::Char) = 'A' <= c <= 'Z'
"""`Math.isLower`."""
is_lower(c::Char) = 'a' <= c <= 'z'
"""`Math.isDig`."""
is_dig(c::Char) = '0' <= c <= '9'
"""`Math.isIdStart`."""
is_id_start(c::Char) = is_letter(c) || c == '_'
"""`Math.isIdChar`."""
is_id_char(c::Char) = is_letter(c) || is_dig(c) || c == '_'

# ## Names

"""`Math.splitDots`: split at every `.` (an empty input is one empty segment)."""
function split_dots(cs)
    out = Vector{Vector{Char}}()
    cur = Char[]
    for c in cs
        if c == '.'
            push!(out, cur)
            cur = Char[]
        else
            push!(cur, c)
        end
    end
    push!(out, cur)
    return out
end

"""`Math.segOK`: an identifier segment `[A-Za-z_][A-Za-z0-9_]*`."""
function seg_ok(cs)
    isempty(cs) && return false
    is_id_start(cs[1]) || return false
    for i in 2:length(cs)
        is_id_char(cs[i]) || return false
    end
    return true
end

"""`Math.nameOK`: dot-separated identifier segments."""
name_ok(s::AbstractString) = all(seg_ok, split_dots(collect(Char, s)))

"""`Math.greek`: the Greek letter names that are a LaTeX command and a Typst
symbol."""
const GREEK = (
    "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta", "iota", "kappa",
    "lambda", "mu", "nu", "xi", "pi", "rho", "sigma", "tau", "upsilon", "phi", "chi", "psi",
    "omega", "Gamma", "Delta", "Theta", "Lambda", "Xi", "Pi", "Sigma", "Upsilon", "Phi", "Psi",
    "Omega",
)
const GREEK_SET = Set{String}(GREEK)

"""`Math.isGreek`."""
is_greek(s::AbstractString) = s in GREEK_SET
is_greek(s) = String(collect(Char, s)) in GREEK_SET

"""`Math.isSingle`: one letter, or a Greek letter name."""
function is_single(s)
    cs = collect(Char, s)
    length(cs) == 1 && return is_letter(cs[1])
    return is_greek(String(cs))
end

"""`Math.elements`: the element symbols a chemical-formula name is built from."""
const ELEMENTS = Set{String}(
    [
        "H", "He", "Li", "Be", "B", "C", "N", "O", "F", "Ne", "Na", "Mg", "Al", "Si", "P", "S",
        "Cl", "Ar", "K", "Ca", "Ti", "Cr", "Mn", "Fe", "Co", "Ni", "Cu", "Zn", "Br", "Kr", "Ag",
        "Sn", "I", "Xe", "Hg", "Pb", "Rn",
    ]
)

"""`Math.digRun`: the maximal run of digits at the front (the run and the
rest)."""
function dig_run(cs::Chars)
    n = 0
    while is_dig(at(cs, n + 1))
        n += 1
    end
    return view(cs, 1:n), drop(cs, n)
end

"""`Math.letRun`: the maximal run of letters at the front."""
function let_run(cs::Chars)
    n = 0
    while is_letter(at(cs, n + 1))
        n += 1
    end
    return view(cs, 1:n), drop(cs, n)
end

"""`Math.pieces`: a run of letters and the run of digits after it, repeatedly.
`CH2O` is `[("CH", "2"), ("O", "")]`."""
function pieces(s)
    out = Vector{Tuple{Vector{Char}, Vector{Char}}}()
    cs = view(collect(Char, s), :)
    for _ in 1:length(s)
        isempty(cs) && break
        a, r = let_run(cs)
        b, r = dig_run(r)
        isempty(a) && break
        push!(out, (collect(a), collect(b)))
        cs = r
    end
    return out
end

"""`Math.elemToks`: an uppercase letter, then an optional lowercase one,
greedily."""
function elem_toks(cs)
    out = String[]
    i = 1
    n = length(cs)
    while true
        i > n && return out
        c = cs[i]
        if i < n
            d = cs[i + 1]
            if is_upper(c) && is_lower(d)
                push!(out, string(c, d))
                i += 2
            elseif is_upper(c)
                push!(out, string(c))
                i += 1
            else
                return nothing
            end
        else
            is_upper(c) || return nothing
            push!(out, string(c))
            return out
        end
    end
    return out
end

"""`Math.isFormula`: letters and digits only, read as element symbols and
counts, starting with an element, with at least two tokens."""
function is_formula(s)
    cs = collect(Char, s)
    all(c -> is_letter(c) || is_dig(c), cs) || return false
    (!isempty(cs) && is_upper(cs[1])) || return false
    ps = pieces(cs)
    flat = Char[]
    for (a, b) in ps
        append!(flat, a)
        append!(flat, b)
    end
    flat == cs || return false
    count = 0
    for (a, b) in ps
        ts = elem_toks(a)
        ts === nothing && return false
        all(t -> t in ELEMENTS, ts) || return false
        count += length(ts) + (isempty(b) ? 0 : 1)
    end
    return 2 <= count
end

"""`Math.subParts`: the subscripted shape `b_r` (a single letter or Greek name,
`_`, a nonempty rest). Returns the base and the rest, or `nothing`."""
function sub_parts(s)
    cs = collect(Char, s)
    i = findfirst(==('_'), cs)
    i === nothing && return nothing
    b, rest = cs[1:(i - 1)], cs[(i + 1):end]
    (is_single(b) && !isempty(rest)) || return nothing
    return b, rest
end

# ## Numbers and JSON well-formedness, as checks

"""`Math.numOK`: `JNum.WF` as a check."""
num_ok(n::JNum) = wfb(n)

"""`Math.keysSorted`: object keys strictly increasing."""
function keys_sorted(kvs)
    for i in 2:length(kvs)
        kvs[i - 1].first < kvs[i].first || return false
    end
    return true
end

"""`Math.jwf`: `Json.WF` as a check."""
jwf(j) = wfb(j)

# ## Operators

"""`Math.removedOps`: spec §4.2 "Removed ops", refused by name. The host's
`_REMOVED_OPS`, the list the loader refuses."""
const REMOVED_OPS = parentmodule(parentmodule(@__MODULE__))._REMOVED_OPS

"""`Math.deprecatedOps`: read in the call form and rewritten, never printed. The
spellings of the host's `_DEPRECATED_OPS`."""
const DEPRECATED_OPS =
    Tuple(sort!(collect(keys(parentmodule(parentmodule(@__MODULE__))._DEPRECATED_OPS))))

"""`Math.opOK`: `[A-Za-z_][A-Za-z0-9_.]*` or `[-+*/^<>=!]+`."""
function op_ok(s::AbstractString)
    cs = collect(Char, s)
    isempty(cs) && return false
    if is_id_start(cs[1]) && all(d -> is_id_char(d) || d == '.', @view cs[2:end])
        return true
    end
    return all(d -> d in "-+*/^<>=!", cs)
end

"""`Math.opFieldOK`: an `op` that is neither removed nor deprecated."""
function op_field_ok(kvs)
    o = look("op", kvs)
    o isa String || return false
    return op_ok(o) && !(o in REMOVED_OPS) && !(o in DEPRECATED_OPS)
end

"""`Math.hasArgs`."""
has_args(kvs) = look("args", kvs) !== nothing

"""`Math.isE`: a well-formed expression (canonical form)."""
is_e(e::JNum) = num_ok(e)
is_e(e::String) = name_ok(e)
function is_e(e::JObj)
    kvs = e.kvs
    (keys_sorted(kvs) && op_field_ok(kvs) && has_args(kvs)) || return false
    for (k, v) in kvs
        if k == "args"
            (v isa JArr && all(is_e, v.xs)) || return false
        else
            (k == "op" || jwf(v)) || return false
        end
    end
    return true
end
is_e(::Any) = false

"""`Math.Sym`: the names a document declares and the parameter list of every
template in scope."""
struct Sym
    names::Vector{String}
    templates::Vector{Tuple{String, Vector{String}}}
end
Sym() = Sym(String[], Tuple{String, Vector{String}}[])

end # module MExpr
