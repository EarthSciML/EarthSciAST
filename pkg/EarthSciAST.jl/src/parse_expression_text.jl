"""
parse_expression_text — the INVERSE of [`to_ascii`](@ref) (display.jl) for
authoring EarthSciAST expressions (esm-spec §4.2) as text.

Port of the reference implementation
`pkg/earthsci-ast-ts/src/parse-expression.ts`; its module docstring is the
spec and this file follows it construct-for-construct so the two stay in
lockstep. The concrete syntax IS what `to_ascii` emits, so the pair
round-trips: `to_ascii(parse_expression(s)) == s`. Precedence is sourced from
[`get_operator_precedence`](@ref) (display.jl, derived from the op registry) so
the parser can never drift from the printer. This parser RECONSTRUCTS existing
`OpExpr` shapes; it never invents new ones, and it requires no change to
`to_ascii`.

Coverage:
 - scalar tier: arithmetic, powers, comparisons, boolean logic, elementary
   functions, derivatives (`D(x)/Dt` and `D(x, t)`), open/user function calls;
 - array & call-shaped tier: array literals `[…]` (`const`), indexing
   `a[i, j]` (`index`), dotted closed-function calls `datetime.year(t)` (`fn`),
   the `true` literal, and `integral` / `reshape` / `transpose` / `concat`;
 - reduction & array-query tier: `aggregate` reductions
   `sum[i] (expr) where {i in set, j in lo:hi} join(a=b) if pred distinct
   key=k [semiring=…]` (all clause shapes), the `argmin`/`argmax`
   arg-witnesses `argmin[g] (expr) where {…}`, template application
   `name<binding = value, …>` (`apply_expression_template`),
   `polygon_intersection_area(a, b, manifold=…)`,
   `intersect_polygon(a, b, manifold=…[, id=…])`, the `table_lookup` bracket
   form `visc[T=temp]` / `k_rate[T=temp, p=pres]:1`, and the piecewise-region
   array `makearray([lo:hi, …] = value, …)`. The RFC §6.1 node `id` is read
   back wherever `to_ascii` emits it: as a trailing named argument on the
   geometry ops, and as a bare-name clause on aggregates and arg-witnesses.

Aggregate `args` is a derived operand cache the printer doesn't emit; it's
reconstructed best-effort (see `_tp_derive_aggregate_args`) and is
reprint-neutral. `sum` with neither an explicit `[semiring=…]` nor a `join`
reconstructs as a plain `+` reduction — the join-less `sum_product` annotation
(semantically identical there) is not recovered; both reprint identically.

Still deferred (need dedicated surface syntax — a later pass): `broadcast` and
`enum`. Those are refused with an [`ExpressionParseError`](@ref), as is the
CALL spelling `table_lookup(…)` (its real surface is `visc[T=temp]`).

Design rules: multiplication is ALWAYS explicit (`k * A`) — no implicit
juxtaposition, because identifiers are multi-letter (`NO2`, `O3`, `k_photo`).
Two known non-exactnesses trace to `to_ascii`, not the parser: float
serialization, and unary-minus operands being under-parenthesized (`-(a+b)` and
`(-a)+b` both print `-a + b`) — the parser matches the printer's loose
convention. Because the printer is not injective,
`parse_expression(to_ascii(ast))` is a faithful SEMANTIC round-trip but may
normalize structure (flat vs. nested `+`; a scalar `const`/`fn` with a
non-dotted name reprints identically to a plain number/op). Editors should
treat text as a derived view and re-parse only dirtied expressions.

Note that the JSON (wire → typed IR) decoder is a DIFFERENT entry point,
[`expression_from_json`](@ref) in parse.jl. This one consumes infix TEXT.
"""

"""
    ExpressionParseError(msg, pos)

Thrown when an expression string cannot be parsed by [`parse_expression`](@ref)
or [`parse_equation`](@ref).

- `msg`: human-readable diagnostic.
- `pos`: 0-based CHARACTER offset into the source where parsing failed
  (matching the `pos` field of the TypeScript reference implementation).
"""
struct ExpressionParseError <: EarthSciASTError
    msg::String
    pos::Int
end

Base.showerror(io::IO, e::ExpressionParseError) =
    print(io, "ExpressionParseError: ", e.msg, " (at character offset ", e.pos, ")")

# --- operator tables ---------------------------------------------------------

"""
Binary infix operators the parser recognizes. Each one's precedence comes from
[`get_operator_precedence`](@ref) at parse time, so it tracks the op registry;
only the token set and associativity live here. `^` is the sole
right-associative operator (mirrors display.jl's non-associative-right
handling).
"""
const _TP_INFIX = Set{String}([
    "or", "and", "==", "!=", "<", ">", "<=", ">=", "+", "-", "*", "/", "^",
])
const _TP_RIGHT_ASSOC = Set{String}(["^"])

# Prefix operand minimum-precedences, sourced from the registry:
#  - unary `-` binds LOOSELY (registry precedence of `-`, = additive), so it
#    swallows a whole additive/multiplicative operand, matching how the printer
#    renders `-(Ea/(R*T))` as `-Ea / (R * T)` with no inner parens.
#  - `not` binds TIGHTLY at its registry precedence
#    (`not p and q` = `(not p) and q`).
const _TP_UMINUS_MIN = get_operator_precedence("-")
const _TP_NOT_MIN = get_operator_precedence("not")
# Template binding values (`name<k = value, …>`) bind at additive precedence so
# the closing `>` — a comparison operator — is never swallowed as `value > …`.
const _TP_TEMPLATE_ARG_MIN = get_operator_precedence("+")

"""
Structural ops whose defining data lives OUTSIDE `args` AND which have no text
surface yet — refused, pending a dedicated syntax pass. (`integral`, `reshape`,
`transpose`, `concat`, `fn`, `const`, `index`, `true`, `aggregate`,
`apply_expression_template`, `polygon_intersection_area`, `intersect_polygon`,
`makearray` DO have a surface and are reconstructed below; they are
intentionally absent here. `table_lookup` IS listed: its surface is the bracket
form `visc[T=temp]`, parsed in `_tp_parse_table_lookup` without going through
`_tp_make_call`, so the CALL spelling `table_lookup(a)` — which the printer
never emits — stays refused.)
"""
const _TP_STRUCTURAL_OPS = Set{String}(["table_lookup", "broadcast", "enum"])

"""
The aggregate reduction symbols `to_ascii` emits (`format_aggregate`). Each maps
to a default `reduce` when no explicit `[semiring=…]` supersedes it; `sum` and
`any` carry no `reduce` field (plain `+` / semiring-only).
"""
const _TP_AGG_SYMS = Set{String}(["sum", "prod", "max", "min", "any"])
"""Arg-witness reductions (`format_arg_witness`): `argmin[g] (expr) where {…}`."""
const _TP_ARGWITNESS_SYMS = Set{String}(["argmin", "argmax"])
const _TP_REDUCE_BY_SYM = Dict{String,Union{String,Nothing}}(
    "sum" => nothing,
    "prod" => "*",
    "max" => "max",
    "min" => "min",
    "any" => nothing,
)

# --- tokenizer ---------------------------------------------------------------

# One token. `kind` is the token class; `val` carries the operator/name string
# (`:op` / `:name`) or the numeric value (`:num`) and is `nothing` for
# punctuation; `pos` is the 0-based CHARACTER offset of the token's first
# character (the offset an `ExpressionParseError` reports).
struct _TPTok
    kind::Symbol
    val::Any
    pos::Int
end

# Single-character punctuation → token kind. `:` separates range bounds
# (`lo:hi`), `;` separates aggregate join clauses, `{`/`}` delimit an aggregate
# `where { … }` clause.
const _TP_PUNCT = Dict{Char,Symbol}(
    '(' => :lparen, ')' => :rparen,
    '[' => :lbracket, ']' => :rbracket,
    '{' => :lbrace, '}' => :rbrace,
    ':' => :colon, ';' => :semicolon, ',' => :comma,
)

# Longest-match-first so `>=`/`<=`/`==`/`!=` beat `>`/`<`/`=`.
const _TP_MULTI_OPS = Set{String}([">=", "<=", "==", "!="])
const _TP_SINGLE_OPS = Set{Char}(['+', '-', '*', '/', '^', '>', '<'])
const _TP_WORD_OPS = Set{String}(["and", "or", "not"])

_tp_isdigit(c::Char) = '0' <= c <= '9'

# Identifiers allow Unicode letters (Greek variables like `ΔF_net`, `Φ`),
# Unicode numbers (subscript/superscript digits in names like `k₀`, `M₁`), and
# dots (qualified refs like `Emissions.NO`, and dotted closed-function names
# like `datetime.year`, which `_tp_make_call` turns into `fn` nodes). A leading
# digit still can't start an identifier (numbers lex first).
#
# `∂` (U+2202) and `∇` (U+2207) are also name-constituents: source variables are
# sometimes named with them (`∂u_∂z`, a discretized ∂u/∂z shear field), and
# `to_ascii` prints such names verbatim. Those glyphs are NOT ascii operators —
# the ascii derivative surface is `D(x)/Dt`, so `∂`/`∇` appear in `to_ascii`
# output ONLY inside a name, and accepting them keeps the parser its exact
# inverse. (The unicode big-operator display forms `∑ ∫ ∈ ⟨⟩` remain refused;
# they are `to_unicode`/`to_latex` forms, not the ascii surface.)
_tp_name_start(c::Char) = c == '_' || c == '∂' || c == '∇' || isletter(c)
_tp_name_cont(c::Char) =
    c == '_' || c == '.' || c == '∂' || c == '∇' ||
    _tp_isdigit(c) || ('a' <= c <= 'z') || ('A' <= c <= 'Z') ||
    isletter(c) || isnumeric(c)

# Length (in characters) of the numeric literal starting at `chars[i]`, or 0
# when none matches. Mirrors the reference regex
# `^(?:\\d+\\.?\\d*|\\.\\d+)(?:[eE][+-]?\\d+)?`.
function _tp_num_len(chars::Vector{Char}, i::Int)
    n = length(chars)
    j = i
    if _tp_isdigit(chars[j])
        while j <= n && _tp_isdigit(chars[j])
            j += 1
        end
        if j <= n && chars[j] == '.'
            j += 1
            while j <= n && _tp_isdigit(chars[j])
                j += 1
            end
        end
    elseif chars[j] == '.'
        (i + 1 <= n && _tp_isdigit(chars[i+1])) || return 0
        j = i + 1
        while j <= n && _tp_isdigit(chars[j])
            j += 1
        end
    else
        return 0
    end
    # Optional exponent — consumed only when at least one digit follows, so a
    # trailing `e` stays an identifier (`1e` lexes as `1` then `e`).
    if j <= n && (chars[j] == 'e' || chars[j] == 'E')
        k = j + 1
        if k <= n && (chars[k] == '+' || chars[k] == '-')
            k += 1
        end
        if k <= n && _tp_isdigit(chars[k])
            while k <= n && _tp_isdigit(chars[k])
                k += 1
            end
            j = k
        end
    end
    return j - i
end

function _tp_tokenize(src::AbstractString)
    chars = collect(src)
    n = length(chars)
    toks = _TPTok[]
    i = 1
    while i <= n
        c = chars[i]
        if c == ' ' || c == '\t' || c == '\n' || c == '\r'
            i += 1
            continue
        end
        punct = get(_TP_PUNCT, c, nothing)
        if punct !== nothing
            push!(toks, _TPTok(punct, nothing, i - 1))
            i += 1
            continue
        end
        if i < n
            two = string(c, chars[i+1])
            if two in _TP_MULTI_OPS
                push!(toks, _TPTok(:op, two, i - 1))
                i += 2
                continue
            end
        end
        if c == '='
            # lone '=' (the '==' case was handled just above)
            push!(toks, _TPTok(:eq, nothing, i - 1))
            i += 1
            continue
        end
        if c in _TP_SINGLE_OPS
            push!(toks, _TPTok(:op, string(c), i - 1))
            i += 1
            continue
        end
        if c == '.' || _tp_isdigit(c)
            len = _tp_num_len(chars, i)
            if len > 0
                push!(toks, _TPTok(:num, parse(Float64, String(chars[i:i+len-1])), i - 1))
                i += len
                continue
            end
        end
        if _tp_name_start(c)
            j = i + 1
            while j <= n && _tp_name_cont(chars[j])
                j += 1
            end
            v = String(chars[i:j-1])
            push!(toks, _TPTok(v in _TP_WORD_OPS ? :op : :name, v, i - 1))
            i = j
            continue
        end
        # The big-operator / unicode display forms (∑ ∫ ∈ ⟨⟩ …) are rendered by
        # to_unicode/to_latex, not the ascii form this parser inverts; refuse
        # them so a caller routes such input elsewhere. (The ascii aggregate
        # surface uses the words `sum`/`where`/`in`/`join`/`if` and `{ }` `:`
        # `;`, all handled above; `∂`/`∇` are name-constituents just above.)
        if UInt32(c) > 127
            throw(ExpressionParseError(
                "unicode operator syntax (\"$c\") — use the ascii text form", i - 1))
        end
        throw(ExpressionParseError("Unexpected character \"$c\"", i - 1))
    end
    push!(toks, _TPTok(:eof, nothing, n))
    return toks
end

# --- parser (Pratt / precedence-climbing) ------------------------------------

mutable struct _TPParser
    toks::Vector{_TPTok}
    p::Int   # 1-based index of the next token
end
_TPParser(toks::Vector{_TPTok}) = _TPParser(toks, 1)

_tp_peek(ps::_TPParser, k::Int=0) = ps.toks[min(ps.p + k, length(ps.toks))]

# Consume and return the next token. Clamped at the trailing `:eof` sentinel so
# an over-consuming error path reports at eof instead of raising BoundsError.
function _tp_next!(ps::_TPParser)
    t = ps.toks[min(ps.p, length(ps.toks))]
    ps.p += 1
    return t
end

_tp_fail(ps::_TPParser, msg::AbstractString) =
    throw(ExpressionParseError(String(msg), _tp_peek(ps).pos))
_tp_fail_at(t::_TPTok, msg::AbstractString) =
    throw(ExpressionParseError(String(msg), t.pos))

function _tp_expect!(ps::_TPParser, kind::Symbol, what::AbstractString)
    _tp_peek(ps).kind === kind || _tp_fail(ps, "Expected $what")
    _tp_next!(ps)
    return nothing
end

function _tp_expect_op!(ps::_TPParser, v::AbstractString, what::AbstractString)
    t = _tp_peek(ps)
    (t.kind === :op && t.val == v) || _tp_fail(ps, "Expected $what")
    _tp_next!(ps)
    return nothing
end

"""True when the next token is the contextual keyword name `v`."""
function _tp_at_word(ps::_TPParser, v::AbstractString)
    t = _tp_peek(ps)
    return t.kind === :name && t.val == v
end

# A numeric token → the AST literal node. Mirrors `expression_from_json`'s
# literal rule (CONFORMANCE_SPEC §5.5.3.1): a value that is integral AND
# Int64-representable is an `IntExpr` regardless of source spelling (`1.0e4` →
# `IntExpr(10000)`); everything else is a `NumExpr`.
function _tp_number(x::Float64)
    if isfinite(x) && isinteger(x) &&
       typemin(Int64) <= x <= typemax(Int64) && Float64(Int64(x)) == x
        return IntExpr(Int64(x))
    end
    return NumExpr(x)
end

function _tp_parse_entry(ps::_TPParser)
    e = _tp_parse_expr(ps, 0)
    _tp_peek(ps).kind === :eof || _tp_fail(ps, "Unexpected trailing input")
    return _tp_flatten(e)
end

function _tp_parse_expr(ps::_TPParser, minprec::Int)
    left = _tp_parse_prefix(ps)
    while true
        t = _tp_peek(ps)
        (t.kind === :op && t.val in _TP_INFIX) || break
        prec = get_operator_precedence(t.val)
        prec < minprec && break
        _tp_next!(ps)
        rhs = _tp_parse_expr(ps, t.val in _TP_RIGHT_ASSOC ? prec : prec + 1)
        left = OpExpr(t.val, ASTExpr[left, rhs])
    end
    return left
end

function _tp_parse_prefix(ps::_TPParser)
    t = _tp_peek(ps)
    # `-` directly before a number is a NEGATIVE LITERAL, not a unary-minus
    # node. Both print as `-1.3`, but only a literal reprints WITHOUT parens as
    # an operand (`x^-1.3`, not `x^(-1.3)`) — matching how `to_ascii` emits
    # negative constants (e.g. Arrhenius `(300/T)^-1.3`).
    if t.kind === :op && t.val == "-" && _tp_peek(ps, 1).kind === :num
        _tp_next!(ps)
        num = _tp_next!(ps)
        return _tp_number(-(num.val::Float64))
    end
    if t.kind === :op && (t.val == "-" || t.val == "not")
        _tp_next!(ps)
        operand = _tp_parse_expr(ps, t.val == "not" ? _TP_NOT_MIN : _TP_UMINUS_MIN)
        return OpExpr(t.val, ASTExpr[operand])
    end
    return _tp_parse_postfix(ps)
end

"""Atom, then postfix `[…]` indexing, then the derivative sugar `D(expr)/D<name>`."""
function _tp_parse_postfix(ps::_TPParser)
    node = _tp_parse_atom(ps)
    while _tp_peek(ps).kind === :lbracket
        # A trailing `[semiring=…]` is an aggregate suffix, never an index —
        # leave it for the aggregate tail (it can follow a `key=`/`if`
        # expression).
        nxt = _tp_peek(ps, 1)
        (nxt.kind === :name && nxt.val == "semiring") && break
        # `name[axis=expr, …]` is a `table_lookup` (format_structural_op), not an
        # index: `=` is never an expression operator (only `==` is), so a `name`
        # `=` pair inside the brackets discriminates the two unambiguously. Only
        # a bare variable can name a table.
        if node isa VarExpr && nxt.kind === :name && _tp_peek(ps, 2).kind === :eq
            node = _tp_parse_table_lookup(ps, (node::VarExpr).name)
            continue
        end
        _tp_next!(ps)  # '['
        idx = ASTExpr[_tp_parse_expr(ps, 0)]
        while _tp_peek(ps).kind === :comma
            _tp_next!(ps)
            push!(idx, _tp_parse_expr(ps, 0))
        end
        _tp_expect!(ps, :rbracket, "']'")
        node = OpExpr("index", ASTExpr[node, idx...])
    end
    slash = _tp_peek(ps)
    if node isa OpExpr && node.op == "D" && slash.kind === :op && slash.val == "/"
        nametok = _tp_peek(ps, 1)
        if nametok.kind === :name
            nm = nametok.val::String
            if length(nm) > 1 && first(nm) == 'D'
                _tp_next!(ps)  # '/'
                _tp_next!(ps)  # 'D<var>'
                return OpExpr("D", node.args; wrt=String(nm[nextind(nm, 1):end]))
            end
        end
    end
    return node
end

function _tp_parse_atom(ps::_TPParser)
    t = _tp_next!(ps)
    t.kind === :num && return _tp_number(t.val::Float64)
    if t.kind === :lparen
        e = _tp_parse_expr(ps, 0)
        _tp_expect!(ps, :rparen, "')'")
        return e
    end
    # A leading `[` is a const array literal (`[1, 2, 3]`, `[[1, 2], [3, 4]]`).
    t.kind === :lbracket &&
        return OpExpr("const", ASTExpr[]; value=_tp_parse_array_rest(ps))
    if t.kind === :name
        name = t.val::String
        name == "true" && return OpExpr("true", ASTExpr[])
        # `makearray(region = value, …)` — a piecewise-region array. Its
        # arguments are `[lo:hi, …] = value` pairs, not plain call args, so it
        # needs its own parse rather than the generic call path.
        (name == "makearray" && _tp_peek(ps).kind === :lparen) &&
            return _tp_parse_makearray(ps)
        _tp_peek(ps).kind === :lparen && return _tp_parse_call(ps, name)
        # Template application `name<binding = value, …>` (or empty `name<>`) →
        # apply_expression_template. The `< NAME =` / `< >` lookahead
        # distinguishes it from a `<` comparison (whose RHS is never a lone `=`
        # nor an empty `>`).
        lt = _tp_peek(ps)
        lt1 = _tp_peek(ps, 1)
        if lt.kind === :op && lt.val == "<" &&
           ((lt1.kind === :op && lt1.val == ">") ||
            (lt1.kind === :name && _tp_peek(ps, 2).kind === :eq))
            return _tp_parse_template(ps, name)
        end
        # Aggregate reduction `sym[out_idx] (expr) where {…} …`. Only when the
        # bracket is followed (past its match) by `(` — otherwise `sym[i]` is an
        # ordinary index into a variable that happens to be named `sum`/`max`/….
        if name in _TP_AGG_SYMS && _tp_peek(ps).kind === :lbracket &&
           _tp_aggregate_ahead(ps)
            return _tp_parse_aggregate(ps, name)
        end
        # Arg-witness reduction `argmin[g] (expr) where {…}` (same `[…] (` shape).
        if name in _TP_ARGWITNESS_SYMS && _tp_peek(ps).kind === :lbracket &&
           _tp_aggregate_ahead(ps)
            return _tp_parse_arg_witness(ps, name)
        end
        return VarExpr(name)  # bare variable / species / qualified reference
    end
    _tp_fail_at(t, "Expected a number, name, '(', or '['")
end

"""
Parse the elements of an array literal after `[` up to and including `]`, as the
RAW JSON value an `OpExpr`'s `value` field carries (numbers, strings, nested
arrays, or a wire-form node object) — the same shape `expression_from_json`
would have been handed.
"""
function _tp_parse_array_rest(ps::_TPParser)
    els = Any[]
    if _tp_peek(ps).kind !== :rbracket
        while true
            if _tp_peek(ps).kind === :lbracket
                _tp_next!(ps)
                push!(els, _tp_parse_array_rest(ps))  # nested raw array
            else
                # number / name / expression element, demoted to its wire form
                push!(els, serialize_expression(_tp_parse_expr(ps, 0)))
            end
            if _tp_peek(ps).kind === :comma
                _tp_next!(ps)
                continue
            end
            break
        end
    end
    _tp_expect!(ps, :rbracket, "']'")
    return els
end

function _tp_parse_call(ps::_TPParser, name::AbstractString)
    _tp_next!(ps)  # '('
    args = ASTExpr[]
    named = Dict{String,ASTExpr}()
    order = String[]
    if _tp_peek(ps).kind !== :rparen
        while true
            # A `key = value` argument (e.g. concat `axis=0`); a lone `=` (not
            # `==`) after a bare name marks it.
            if _tp_peek(ps).kind === :name && _tp_peek(ps, 1).kind === :eq
                key = (_tp_next!(ps).val)::String
                _tp_next!(ps)  # '='
                haskey(named, key) || push!(order, key)
                named[key] = _tp_parse_expr(ps, 0)
            else
                push!(args, _tp_parse_expr(ps, 0))
            end
            if _tp_peek(ps).kind === :comma
                _tp_next!(ps)
                continue
            end
            break
        end
    end
    _tp_expect!(ps, :rparen, "',' or ')' in call to $name(...)")
    return _tp_make_call(String(name), args, named, order, _tp_peek(ps).pos)
end

# --- aggregate / template (the reduction & array-query tier) ------------------

"""
True when the `[` at the current position closes with a `]` immediately followed
by `(` — the signature of an aggregate `sym[…] (expr)`, as opposed to plain
indexing `sym[i]`. Scans balanced brackets; consumes nothing.
"""
function _tp_aggregate_ahead(ps::_TPParser)
    depth = 0
    for i in ps.p:length(ps.toks)
        k = ps.toks[i].kind
        if k === :lbracket
            depth += 1
        elseif k === :rbracket
            depth -= 1
            if depth == 0
                return i + 1 <= length(ps.toks) && ps.toks[i+1].kind === :lparen
            end
        end
    end
    return false
end

"""
Parse an `aggregate` reduction (esm-spec §4.2) — the inverse of
`format_aggregate`:

    sym '[' out_idx ']' '(' expr ')' ('where' '{' ranges '}')? ('join' '(' … ')')?
    ('if' filter)? 'distinct'? ('key' '=' expr)? ('[' 'semiring' '=' name ']')?

`sym` selects the default `reduce`; an explicit `[semiring=…]` supersedes it, as
does a `join` (which implies `sum_product`). `args` is a derived dependency
cache (see `_tp_derive_aggregate_args`); `to_ascii` doesn't print it, so its
exact value is reprint-neutral.
"""
function _tp_parse_aggregate(ps::_TPParser, sym::AbstractString)
    _tp_next!(ps)  # '['
    output_idx = Any[]
    if _tp_peek(ps).kind !== :rbracket
        while true
            t = _tp_next!(ps)
            t.kind === :name || _tp_fail_at(t, "Expected an output index name")
            push!(output_idx, t.val::String)
            if _tp_peek(ps).kind === :comma
                _tp_next!(ps)
                continue
            end
            break
        end
    end
    _tp_expect!(ps, :rbracket, "']' after aggregate output indices")
    _tp_expect!(ps, :lparen, "'(' before the aggregate body")
    body = _tp_parse_expr(ps, 0)
    _tp_expect!(ps, :rparen, "')' after the aggregate body")

    ranges = Dict{String,Any}()
    if _tp_at_word(ps, "where")
        _tp_next!(ps)
        ranges = _tp_parse_ranges(ps)
    end
    joins = Any[]
    if _tp_at_word(ps, "join")
        _tp_next!(ps)
        append!(joins, _tp_parse_join(ps))
    end
    filt = nothing
    if _tp_at_word(ps, "if")
        _tp_next!(ps)
        filt = _tp_parse_expr(ps, 0)
    end
    distinct = false
    if _tp_at_word(ps, "distinct")
        _tp_next!(ps)
        distinct = true
    end
    key = nothing
    if _tp_at_word(ps, "key") && _tp_peek(ps, 1).kind === :eq
        _tp_next!(ps)  # 'key'
        _tp_next!(ps)  # '='
        key = _tp_parse_expr(ps, 0)
    end
    # `id=<name>` (RFC §6.1 node identity), emitted by `format_aggregate` after
    # `key=`. A bare-name clause, so it adds no bracket ambiguity.
    id = _tp_parse_id_clause!(ps)
    semiring = nothing
    nxt = _tp_peek(ps, 1)
    if _tp_peek(ps).kind === :lbracket && nxt.kind === :name && nxt.val == "semiring"
        _tp_next!(ps)  # '['
        _tp_next!(ps)  # 'semiring'
        _tp_expect!(ps, :eq, "'=' in [semiring=…]")
        nm = _tp_next!(ps)
        nm.kind === :name || _tp_fail_at(nm, "Expected a semiring name")
        semiring = nm.val::String
        _tp_expect!(ps, :rbracket, "']' after [semiring=…]")
    end
    # A join with no explicit semiring is the sum-of-products contraction.
    (semiring === nothing && !isempty(joins)) && (semiring = "sum_product")

    reduce = semiring === nothing ? _TP_REDUCE_BY_SYM[String(sym)] : nothing
    return OpExpr("aggregate",
        ASTExpr[VarExpr(n) for n in
                _tp_derive_aggregate_args(body, joins, filt, key)];
        output_idx=output_idx,
        reduce=reduce,
        semiring=semiring,
        ranges=ranges,
        join=isempty(joins) ? nothing : joins,
        filter=filt,
        distinct=distinct ? true : nothing,
        key=key,
        id=id,
        expr_body=body)
end

"""
Parse an `argmin` / `argmax` arg-witness (esm-spec §4.2) — the inverse of
`format_arg_witness`: `op '[' arg ']' '(' expr ')' ('where' '{' ranges '}')?`.
Like aggregate, its `args` operand cache isn't printed and is derived.
"""
function _tp_parse_arg_witness(ps::_TPParser, op::AbstractString)
    _tp_next!(ps)  # '['
    at = _tp_next!(ps)
    at.kind === :name || _tp_fail_at(at, "Expected the arg-witness index name")
    _tp_expect!(ps, :rbracket, "']' after the arg-witness index")
    _tp_expect!(ps, :lparen, "'(' before the arg-witness body")
    body = _tp_parse_expr(ps, 0)
    _tp_expect!(ps, :rparen, "')' after the arg-witness body")
    ranges = Dict{String,Any}()
    if _tp_at_word(ps, "where")
        _tp_next!(ps)
        ranges = _tp_parse_ranges(ps)
    end
    # `id=<name>` (RFC §6.1 node identity), emitted by `format_arg_witness`
    # after the where-clause. Mirrors the aggregate tail.
    id = _tp_parse_id_clause!(ps)
    return OpExpr(String(op),
        ASTExpr[VarExpr(n) for n in
                _tp_derive_aggregate_args(body, Any[], nothing, nothing)];
        arg=at.val::String, ranges=ranges, id=id, expr_body=body)
end

"""
Read the optional bare-name `id=<name>` clause (RFC §6.1 node identity) that
`format_aggregate` / `format_arg_witness` emit, returning `nothing` when absent.
Deliberately NOT part of the `[…]` suffix — putting it there would collide with
`table_lookup`'s `name[axis=…]` bracket surface.
"""
function _tp_parse_id_clause!(ps::_TPParser)
    (_tp_at_word(ps, "id") && _tp_peek(ps, 1).kind === :eq) || return nothing
    _tp_next!(ps)  # 'id'
    _tp_next!(ps)  # '='
    nm = _tp_next!(ps)
    nm.kind === :name || _tp_fail_at(nm, "Expected a name after id=")
    return nm.val::String
end

"""
Parse a `table_lookup` from the surface `format_structural_op` emits:
`table '[' axis '=' expr (',' axis '=' expr)* ']' (':' <integer>)?`, e.g.
`visc[T=temp]` and `k_rate[T=temp, p=pres]:1`. The printer sorts the axis names,
so the reconstructed `axes` map reprints identically.
"""
function _tp_parse_table_lookup(ps::_TPParser, table::AbstractString)
    _tp_expect!(ps, :lbracket, "'['")
    axes = Dict{String,ASTExpr}()
    while true
        nm = _tp_next!(ps)
        nm.kind === :name || _tp_fail_at(nm, "Expected an axis name in table[axis=…]")
        _tp_expect!(ps, :eq, "'=' in table[axis=…]")
        axes[nm.val::String] = _tp_parse_expr(ps, 0)
        if _tp_peek(ps).kind === :comma
            _tp_next!(ps)
            continue
        end
        break
    end
    _tp_expect!(ps, :rbracket, "']' after table[axis=…]")
    # The optional `:N` output selector picks one column of a multi-output table.
    output = nothing
    if _tp_peek(ps).kind === :colon
        _tp_next!(ps)
        out = _tp_next!(ps)
        (out.kind === :num && isinteger(out.val::Float64)) ||
            _tp_fail_at(out, "Expected an integer output index after table[…]:")
        output = Int(out.val::Float64)
    end
    return OpExpr("table_lookup", ASTExpr[];
        table=String(table), table_axes=axes, output=output)
end

"""Parse a `{ k in <rhs>, … }` where-body into a ranges map."""
function _tp_parse_ranges(ps::_TPParser)
    _tp_expect!(ps, :lbrace, "'{' after where")
    ranges = Dict{String,Any}()
    if _tp_peek(ps).kind !== :rbrace
        while true
            kt = _tp_next!(ps)
            kt.kind === :name || _tp_fail_at(kt, "Expected a range index name")
            _tp_at_word(ps, "in") || _tp_fail(ps, "Expected 'in' in a range clause")
            _tp_next!(ps)  # 'in'
            ranges[kt.val::String] = _tp_parse_range_rhs(ps)
            if _tp_peek(ps).kind === :comma
                _tp_next!(ps)
                continue
            end
            break
        end
    end
    _tp_expect!(ps, :rbrace, "'}' to close the where clause")
    return ranges
end

# A dense range / region bound in its stored form: a concrete integer stays an
# `Int` (what `_coerce_ranges` / `_coerce_regions` produce off the wire);
# anything else stays an `ASTExpr` metaparameter expression.
_tp_bound_value(e::ASTExpr) = e isa IntExpr ? Int(e.value) : e

"""One range RHS: `set` → `IndexSetRef`; `set(a, b)` → `IndexSetRef` with `of`;
`lo:hi` → a dense two-element bound vector."""
function _tp_parse_range_rhs(ps::_TPParser)
    bound = _tp_parse_expr(ps, 0)
    if _tp_peek(ps).kind === :colon
        _tp_next!(ps)
        return Any[_tp_bound_value(bound), _tp_bound_value(_tp_parse_expr(ps, 0))]
    end
    bound isa VarExpr && return IndexSetRef(bound.name)
    # `k in set(of1, of2)` prints as a generic call → {from, of}.
    if bound isa OpExpr && !isempty(bound.op) &&
       (first(bound.op) == '_' || isletter(first(bound.op)))
        of = String[]
        for a in bound.args
            a isa VarExpr || _tp_fail(ps, "range set arguments must be names")
            push!(of, a.name)
        end
        return IndexSetRef(bound.op; of=of)
    end
    _tp_fail(ps, "malformed range (expected a set name, set(of…), or lo:hi)")
end

"""Parse `( a=b, c=d ; e=f )` → the wire join clauses `[[(a,b),(c,d)], [(e,f)]]`."""
function _tp_parse_join(ps::_TPParser)
    _tp_expect!(ps, :lparen, "'(' after join")
    clauses = Any[]
    cur = Tuple{String,String}[]
    if _tp_peek(ps).kind !== :rparen
        while true
            a = _tp_next!(ps)
            a.kind === :name || _tp_fail_at(a, "Expected a join key name")
            _tp_expect!(ps, :eq, "'=' in a join pair")
            b = _tp_next!(ps)
            b.kind === :name || _tp_fail_at(b, "Expected a join key name")
            push!(cur, (a.val::String, b.val::String))
            if _tp_peek(ps).kind === :comma
                _tp_next!(ps)
                continue
            end
            if _tp_peek(ps).kind === :semicolon
                _tp_next!(ps)
                push!(clauses, cur)
                cur = Tuple{String,String}[]
                continue
            end
            break
        end
    end
    push!(clauses, cur)
    _tp_expect!(ps, :rparen, "')' to close join(…)")
    return clauses
end

"""Parse `name<binding = value, …>` (or empty `name<>`) → apply_expression_template."""
function _tp_parse_template(ps::_TPParser, name::AbstractString)
    _tp_next!(ps)  # '<'
    bindings = Dict{String,ASTExpr}()
    while !(_tp_peek(ps).kind === :op && _tp_peek(ps).val == ">")
        kt = _tp_next!(ps)
        kt.kind === :name || _tp_fail_at(kt, "Expected a binding name in <…>")
        _tp_expect!(ps, :eq, "'=' in a template binding")
        bindings[kt.val::String] = _tp_parse_expr(ps, _TP_TEMPLATE_ARG_MIN)
        if _tp_peek(ps).kind === :comma
            _tp_next!(ps)
            continue
        end
        break
    end
    _tp_expect_op!(ps, ">", "'>' to close a template application")
    return OpExpr("apply_expression_template", ASTExpr[];
        name=String(name), bindings=bindings)
end

"""
Parse a `makearray` piecewise-region array (esm-spec §4.2) — the inverse of
`format_structural_op`'s makearray case:

    'makearray' '(' region '=' value ( ',' region '=' value )* ')'
    region := '[' bound ':' bound ( ',' bound ':' bound )* ']'

Each region is a list of per-dimension `lo:hi` bounds, and `value` is the
expression that region evaluates to. A bound is any expression (a number, a name
like `NLON`, or e.g. `NLON - 1`). `args` is always empty (the printer emits
none); `regions` and `values` are positionally paired. Values are flattened to
the canonical n-ary `+`/`*` form, like the top-level parse.
"""
function _tp_parse_makearray(ps::_TPParser)
    _tp_next!(ps)  # '('
    regions = Vector{Vector{Any}}[]
    values = ASTExpr[]
    if _tp_peek(ps).kind !== :rparen
        while true
            _tp_expect!(ps, :lbracket, "'[' to open a makearray region")
            region = Vector{Any}[]
            if _tp_peek(ps).kind !== :rbracket
                while true
                    lo = _tp_parse_expr(ps, 0)
                    _tp_expect!(ps, :colon, "':' between a region's lo:hi bounds")
                    hi = _tp_parse_expr(ps, 0)
                    push!(region, Any[_tp_bound_value(_tp_flatten(lo)),
                        _tp_bound_value(_tp_flatten(hi))])
                    if _tp_peek(ps).kind === :comma
                        _tp_next!(ps)
                        continue
                    end
                    break
                end
            end
            _tp_expect!(ps, :rbracket, "']' to close a makearray region")
            _tp_expect!(ps, :eq, "'=' after a makearray region")
            push!(regions, region)
            push!(values, _tp_flatten(_tp_parse_expr(ps, 0)))
            if _tp_peek(ps).kind === :comma
                _tp_next!(ps)
                continue
            end
            break
        end
    end
    _tp_expect!(ps, :rparen, "')' to close makearray(...)")
    return OpExpr("makearray", ASTExpr[];
        regions=Vector{Vector{Vector{Any}}}(regions), values=values)
end

# --- call reconstruction -----------------------------------------------------

"""Extract the raw element list of a parsed `const` array literal, or fail."""
function _tp_array_literal(e::ASTExpr, pos::Int)
    if e isa OpExpr && e.op == "const" && e.value isa AbstractVector
        return e.value
    end
    throw(ExpressionParseError("expected an array literal [ ... ]", pos))
end

function _tp_no_named(named::Dict{String,ASTExpr}, order::Vector{String},
    name::AbstractString, pos::Int)
    isempty(order) && return nothing
    throw(ExpressionParseError("unexpected $(order[1])=… in $name(...)", pos))
end

# One `reshape(a, […])` shape entry. The `shape` field is documented as `Int`
# (concrete length) or `String` (symbolic dimension), so anything else — e.g.
# an arithmetic node such as `N + 1`, which `_tp_parse_array_rest` demotes to
# its wire object — is a clean parse refusal, not a stringified Dict.
function _tp_shape_entry(x, pos::Int)
    (x isa Integer && !(x isa Bool)) && return Int(x)
    (x isa Real && !(x isa Bool) && isfinite(x) && isinteger(x)) && return Int(x)
    x isa AbstractString && return String(x)
    throw(ExpressionParseError(
        "reshape(...) shape entries must be integers or dimension names", pos))
end

# An integer-valued literal argument (`concat(..., axis=0)`, a `transpose` perm
# entry). The corresponding `OpExpr` field is typed `Int`, so a non-integer is a
# parse refusal rather than a downstream type error.
function _tp_int_literal(x, what::AbstractString, pos::Int)
    x isa IntExpr && return Int(x.value)
    (x isa Real && !(x isa Bool) && isinteger(x)) && return Int(x)
    throw(ExpressionParseError("$what must be an integer literal", pos))
end

function _tp_make_call(name::String, args::Vector{ASTExpr},
    named::Dict{String,ASTExpr}, order::Vector{String}, pos::Int)
    # A dotted callee is a closed function — an `fn` node carrying the name.
    if occursin('.', name)
        _tp_no_named(named, order, name, pos)
        return OpExpr("fn", args; name=name)
    end
    # Call-shaped structural ops: reconstruct their non-`args` fields from the
    # positional / named arguments `to_ascii` renders.
    if name == "integral" && length(args) == 4 && args[2] isa VarExpr
        _tp_no_named(named, order, name, pos)
        return OpExpr("integral", ASTExpr[args[1]];
            int_var=(args[2]::VarExpr).name, lower=args[3], upper=args[4])
    end
    if name == "reshape" && length(args) == 2
        _tp_no_named(named, order, name, pos)
        return OpExpr("reshape", ASTExpr[args[1]];
            shape=Any[_tp_shape_entry(x, pos)
                      for x in _tp_array_literal(args[2], pos)])
    end
    if name == "transpose" && (length(args) == 1 || length(args) == 2)
        _tp_no_named(named, order, name, pos)
        length(args) == 1 && return OpExpr("transpose", ASTExpr[args[1]])
        return OpExpr("transpose", ASTExpr[args[1]];
            perm=Int[_tp_int_literal(x, "a transpose perm entry", pos)
                     for x in _tp_array_literal(args[2], pos)])
    end
    if name == "concat"
        axis = get(named, "axis", nothing)
        axis === nothing &&
            throw(ExpressionParseError("concat(...) requires axis=<n>", pos))
        return OpExpr("concat", args;
            axis=_tp_int_literal(axis, "concat(...) axis", pos))
    end
    # Geometry ops `polygon_intersection_area(a, b, manifold=<name>)` and
    # `intersect_polygon(a, b, manifold=<name>[, id=<name>])`. `id` (RFC §6.1
    # node identity) is optional and only emitted by the printer when present.
    if name == "polygon_intersection_area" || name == "intersect_polygon"
        manifold = get(named, "manifold", nothing)
        manifold isa VarExpr ||
            throw(ExpressionParseError("$name(...) requires manifold=<name>", pos))
        for k in order
            (k == "manifold" || k == "id") ||
                throw(ExpressionParseError("unexpected $k=… in $name(...)", pos))
        end
        idv = get(named, "id", nothing)
        if idv !== nothing && !(idv isa VarExpr)
            throw(ExpressionParseError("$name(...) id=… must be a name", pos))
        end
        return OpExpr(name, args;
            manifold=(manifold::VarExpr).name,
            id=idv === nothing ? nothing : (idv::VarExpr).name)
    end
    _tp_no_named(named, order, name, pos)
    if name in _TP_STRUCTURAL_OPS
        throw(ExpressionParseError(
            "'$name' is not yet expressible in the text form", pos))
    end
    if name == "D"
        # Friendly form D(expr, t) — wrt as an explicit second arg — in addition
        # to the to_ascii form D(expr)/Dt handled in `_tp_parse_postfix`. Any
        # other arity is a nonstandard / discretization D (e.g. with boundary
        # conditions) that the printer emits via the generic call fallback; keep
        # it a generic call.
        if length(args) == 2 && args[2] isa VarExpr
            return OpExpr("D", ASTExpr[args[1]]; wrt=(args[2]::VarExpr).name)
        end
        length(args) == 1 && return OpExpr("D", args)
    end
    return OpExpr(name, args)
end

# --- derived operand cache ---------------------------------------------------

"""
Best-effort reconstruction of an aggregate's `args` — its array operands.
`to_ascii` does NOT print `args` (it's a derived dependency cache), and the
authoritative set excludes parameter arrays by *declared role*, which needs the
variable table. From the printed structure alone it is approximated as: the base
of every `index(…)` in the body / filter / key, plus the names in `join` clauses,
in first-appearance order. This is reprint-neutral (the printer ignores it) and a
dependency superset (safe for graph/dead-code analysis); an editor holding the
symbol table should recompute it on save.
"""
function _tp_derive_aggregate_args(body::ASTExpr, joins::Vector{Any},
    filt::Union{ASTExpr,Nothing}, key::Union{ASTExpr,Nothing})
    out = String[]
    _tp_bases!(out, body)
    for clause in joins
        for (a, b) in clause
            a in out || push!(out, a)
            b in out || push!(out, b)
        end
    end
    filt === nothing || _tp_bases!(out, filt)
    key === nothing || _tp_bases!(out, key)
    return out
end

function _tp_bases!(out::Vector{String}, e)
    e isa OpExpr || return out
    if e.op == "index" && !isempty(e.args) && e.args[1] isa VarExpr
        n = (e.args[1]::VarExpr).name
        n in out || push!(out, n)
    end
    for a in e.args
        _tp_bases!(out, a)
    end
    for f in (:lower, :upper, :expr_body, :filter, :key)
        v = getfield(e, f)
        v === nothing || _tp_bases!(out, v)
    end
    if e.values !== nothing
        for v in e.values
            _tp_bases!(out, v)
        end
    end
    if e.regions !== nothing
        for region in e.regions, dim in region, b in dim
            _tp_bases!(out, b)
        end
    end
    if e.ranges !== nothing
        for k in sort(collect(keys(e.ranges)))
            v = e.ranges[k]
            v isa AbstractVector || continue
            for x in v
                _tp_bases!(out, x)
            end
        end
    end
    for f in (:bindings, :table_axes)
        m = getfield(e, f)
        m === nothing && continue
        for k in sort(collect(keys(m)))
            _tp_bases!(out, m[k])
        end
    end
    return out
end

# --- normalization -----------------------------------------------------------

"""
Flatten nested same-op `+` / `*` in `args` into the n-ary form the printer emits
and authored ASTs use: `a + b + c` → one `+` with three args, not left-nested
pairs. (`-` and `/` are binary and stay as parsed.) Non-`args` expression fields
(integral bounds, aggregate bodies, …) are left as parsed — exactly as in the
reference implementation.

Safe to mutate in place: every node it sees was freshly built by this parser and
is not shared with any other tree.
"""
function _tp_flatten(e::ASTExpr)
    e isa OpExpr || return e
    args = ASTExpr[_tp_flatten(a) for a in e.args]
    if e.op == "+" || e.op == "*"
        out = ASTExpr[]
        for a in args
            if a isa OpExpr && a.op == e.op && a.wrt === nothing
                append!(out, a.args)
            else
                push!(out, a)
            end
        end
        args = out
    end
    e.args = args
    return e
end

# --- public API --------------------------------------------------------------

"""
    parse_expression(src::AbstractString) -> ASTExpr

Parse a single expression string in the INFIX TEXT form into an AST expression —
the inverse of [`to_ascii`](@ref). Throws [`ExpressionParseError`](@ref) on
malformed input or an operator with no text surface yet.

The JSON (wire → typed IR) decoder is a different entry point,
[`expression_from_json`](@ref).

# Examples
```julia
parse_expression("k1 * NO2 * O2 - k2 * O3")
parse_expression("D(O3)/Dt")
parse_expression("sum[i] (u[i, k]) where {i in cells, k in edges_of_cell(i)}")
```
"""
parse_expression(src::AbstractString)::ASTExpr =
    _tp_parse_entry(_TPParser(_tp_tokenize(src)))

"""
    parse_equation(src::AbstractString) -> Equation

Parse `lhs = rhs` into an [`Equation`](@ref). The top-level separator is a LONE
`=`; `==` (and `>=`/`<=`/`!=`) remain comparison operators within either side,
and a template binding's `=` inside `name<…>` is not a separator either.

Throws [`ExpressionParseError`](@ref) when there is no top-level lone `=`, or
when either side fails to parse.
"""
function parse_equation(src::AbstractString)::Equation
    toks = _tp_tokenize(src)
    depth = 0
    angle = 0   # template `name<binding = value>` — its `=` is not a separator
    split = 0
    ntok = length(toks)
    for i in 1:ntok
        split == 0 || break
        t = toks[i]
        if t.kind === :lparen || t.kind === :lbracket || t.kind === :lbrace
            depth += 1
        elseif t.kind === :rparen || t.kind === :rbracket || t.kind === :rbrace
            depth -= 1
        elseif t.kind === :op && t.val == "<" && i + 2 <= ntok &&
               toks[i+1].kind === :name && toks[i+2].kind === :eq
            angle += 1
        elseif t.kind === :op && t.val == ">" && angle > 0
            angle -= 1
        elseif t.kind === :eq && depth == 0 && angle == 0
            # The FIRST top-level lone `=` splits lhs/rhs; a later binding/`key=`
            # `=` (legitimately present in an aggregate or template on the rhs)
            # is left intact.
            split = i
        end
    end
    split == 0 &&
        throw(ExpressionParseError("Expected 'lhs = rhs'", length(collect(src))))
    lhs_toks = vcat(toks[1:split-1], _TPTok(:eof, nothing, toks[split].pos))
    rhs_toks = toks[split+1:end]
    lhs = _tp_parse_entry(_TPParser(lhs_toks))
    rhs = _tp_parse_entry(_TPParser(rhs_toks))
    return Equation(lhs, rhs)
end
