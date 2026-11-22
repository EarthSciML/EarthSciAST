# Canonical AST form per discretization RFC §5.4.
#
# Implements `canonicalize(expr)` and `canonical_json(expr)` such that two
# ASTs are canonically equal iff their `canonical_json` outputs are
# byte-identical.
#
# See `docs/content/rfcs/discretization.md` §5.4.1–§5.4.7 for the normative rules.

"""
    CanonicalizeError(code::String, message::String)

Error raised by [`canonicalize`](@ref) / [`canonical_json`](@ref). The `code`
field carries a stable error code:

- `E_CANONICAL_NONFINITE`, `E_CANONICAL_DIVBY_ZERO` — the RFC §5.4.6 / §5.4.7
  cross-language codes.
- `E_CANONICAL_UNSUPPORTED_FIELD` — Julia-local: the node carries an
  expression field outside the RFC-pinned emissible set (`op`/`args`/`wrt`/
  `dim`/`fn`/`name`/`value`), so no faithful canonical JSON exists (see
  [`canonical_json`](@ref)).
- `E_CANONICAL_BAD_CONST` — Julia-local: a `const`-op `value` payload of an
  unsupported Julia type reached the canonical emitter (internal misuse, not
  an authoring error).
- `E_CANONICAL_BAD_NODE` — Julia-local: an `ASTExpr` subtype unknown to the
  canonical emitter reached `_emit_json` (defensively unreachable for the four
  concrete node types; internal misuse, not an authoring error).
"""
struct CanonicalizeError <: EarthSciASTError
    code::String
    message::String
end

"""
    canonicalize(expr::ASTExpr) -> ASTExpr

Canonicalize an expression tree per discretization RFC §5.4. Returns a new
tree; the input is not mutated. Throws [`CanonicalizeError`](@ref) for
NaN/Inf or `0/0`.

Field handling (cross-binding parity): like the TypeScript (`{...node}`),
Python (`dataclasses.replace`), and Rust (`node.clone()`) canonicalizers,
every `OpExpr` field is PRESERVED on the rebuilt node (via `reconstruct`),
and canonicalization recurses into `args` only — sub-expressions carried by
aggregate fields (`expr_body`, `filter`, `lower`/`upper`, `values`,
`bindings`, …) pass through verbatim, exactly as in the other bindings.
RFC §5.4 pins rewrite rules only for the scalar arithmetic subset
(`+ * - /`, and the deprecated `neg` and `pow`, which canonicalize to unary
`-` and `^`: esm-spec §4.2 "Deprecated ops"); all other ops are
structure-preserving pass-throughs.
Emission of such aggregate-carrying nodes is the restricted step — see
[`canonical_json`](@ref).
"""
function canonicalize end

canonicalize(e::IntExpr) = e

function canonicalize(e::NumExpr)
    isfinite(e.value) || throw(
        CanonicalizeError(
            "E_CANONICAL_NONFINITE",
            "non-finite float in canonical form"
        )
    )
    return e
end

canonicalize(e::VarExpr) = e

function canonicalize(e::OpExpr)
    new_args = Vector{ASTExpr}(undef, length(e.args))
    for (i, a) in enumerate(e.args)
        new_args[i] = canonicalize(a)
    end
    # `reconstruct` copies EVERY OpExpr field (semiring, join, filter,
    # join_gates, id, distinct, key, …) —
    # matching the field-preserving rebuilds in the TS/Python/Rust bindings.
    work = reconstruct(e; args = new_args)
    return _canonicalize_shallow(work)
end

# The LOCAL (single-node) canonicalization step, applied to a node whose args
# are already canonical. Factored out of `canonicalize(::OpExpr)` so the
# tree-walk CSE's identity-memoized driver (`_canonicalize_memo`,
# tree_walk/scalar_cse.jl) can canonicalize a structurally-SHARED expression DAG
# node-by-unique-node — `canonicalize` is compositional, so
# `canonicalize(e) == _canonicalize_shallow(e with canonicalized args)` and
# the memoized driver gives the same result as the plain recursion.
function _canonicalize_shallow(work::OpExpr)
    if work.units !== nothing
        # A `const` node's declared units take the canonical unit spelling
        # (esm-spec §4.8.2), so two spellings of one unit canonicalize alike.
        units = _canonical_units(work.units::String)
        units == work.units || (work = reconstruct(work; units = units))
        if work.op == "const" && units == "1"
            # A dimensionless const drops its units (user ruling 2026-11-14):
            # a scalar becomes the bare literal, an array a unitless const.
            v = work.value
            v isa Integer && !(v isa Bool) && return IntExpr(Int64(v))
            v isa AbstractFloat && return canonicalize(NumExpr(Float64(v)))
            work = reconstruct(work; units = nothing)
        end
    end
    if work.op == "+"
        return _canon_add(work)
    elseif work.op == "*"
        return _canon_mul(work)
    elseif work.op == "-"
        return _canon_sub(work)
    elseif work.op == "/"
        return _canon_div(work)
    elseif work.op == "neg"
        return _canon_neg(work)
    elseif work.op == "pow" && length(work.args) == 2
        # Deprecated word spelling of `^` (esm-spec §4.2): the canonical form
        # never contains it. A malformed `pow` is left as written.
        return reconstruct(work; op = "^")
    end
    return work
end

function _canon_add(node::OpExpr)
    flat = _flatten_same_op(node.args, "+")
    others, _had_int_zero, had_float_zero = _partition_identity(flat, 0)
    if had_float_zero && !_all_float_literals(others)
        push!(others, NumExpr(0.0))
    end
    if isempty(others)
        return had_float_zero ? NumExpr(0.0) : IntExpr(0)
    end
    if length(others) == 1
        return others[1]
    end
    _sort_args!(others)
    return reconstruct(node; args = others)
end

function _canon_mul(node::OpExpr)
    flat = _flatten_same_op(node.args, "*")
    for a in flat
        if a isa IntExpr && a.value == 0
            return IntExpr(0)
        end
        if a isa NumExpr && a.value == 0.0
            # Preserve signbit: -0.0 stays as -0.0 via copysign.
            return NumExpr(copysign(0.0, a.value))
        end
    end
    others, _had_int_one, had_float_one = _partition_identity(flat, 1)
    if had_float_one && !_all_float_literals(others)
        push!(others, NumExpr(1.0))
    end
    if isempty(others)
        return had_float_one ? NumExpr(1.0) : IntExpr(1)
    end
    if length(others) == 1
        return others[1]
    end
    _sort_args!(others)
    return reconstruct(node; args = others)
end

function _canon_sub(node::OpExpr)
    if length(node.args) == 1
        return _canon_neg_value(node.args[1])
    end
    if length(node.args) == 2
        a, b = node.args[1], node.args[2]
        # `0 - x` is NOT `-x` when x is +0.0 (`0 - 0.0` is +0.0, `-(0.0)` is
        # -0.0), so only a literal subtrahend folds, to the exact difference:
        # an integer when both are integers, else the IEEE float difference.
        # Any other `-(0, x)` stays binary (RFC §5.4.7).
        if _is_zero_any(a)
            if a isa IntExpr && b isa IntExpr
                return IntExpr(-b.value)
            elseif b isa IntExpr || b isa NumExpr
                return NumExpr(0.0 - Float64(b.value))
            end
        end
        if _is_zero_any(b)
            if b isa NumExpr && a isa IntExpr
                return NumExpr(Float64(a.value))
            end
            return a
        end
    end
    return node
end

function _canon_div(node::OpExpr)
    length(node.args) == 2 || return node
    a, b = node.args[1], node.args[2]
    if _is_zero_any(a) && _is_zero_any(b)
        throw(CanonicalizeError("E_CANONICAL_DIVBY_ZERO", "0/0 in canonical form"))
    end
    if _is_one_any(b)
        if b isa NumExpr && a isa IntExpr
            return NumExpr(Float64(a.value))
        end
        return a
    end
    if _is_zero_any(a)
        return a isa NumExpr ? NumExpr(0.0) : IntExpr(0)
    end
    return node
end

function _canon_neg(node::OpExpr)
    length(node.args) == 1 || return node
    return _canon_neg_value(node.args[1])
end

# Negation of an already-canonical operand (RFC §5.4.7). The canonical form is
# the unary `-` node; the deprecated `neg` spelling (esm-spec §4.2) is accepted
# on input but never emitted. A double negation collapses whichever spelling
# either negation uses.
function _canon_neg_value(arg::ASTExpr)
    if arg isa IntExpr
        return IntExpr(-arg.value)
    elseif arg isa NumExpr
        return NumExpr(-arg.value)
    elseif arg isa OpExpr && (arg.op == "neg" || arg.op == "-") && length(arg.args) == 1
        return arg.args[1]
    end
    return OpExpr("-", ASTExpr[arg])
end

function _flatten_same_op(args::Vector{ASTExpr}, op::String)
    out = ASTExpr[]
    for a in args
        if a isa OpExpr && a.op == op
            append!(out, a.args)
        else
            push!(out, a)
        end
    end
    return out
end

function _partition_identity(args::Vector{ASTExpr}, identity::Int)
    others = ASTExpr[]
    had_int = false
    had_float = false
    for a in args
        if a isa IntExpr && a.value == identity
            had_int = true
            continue
        end
        if a isa NumExpr && a.value == Float64(identity)
            had_float = true
            continue
        end
        push!(others, a)
    end
    return others, had_int, had_float
end

_all_float_literals(args::Vector{ASTExpr}) = !isempty(args) && all(a -> a isa NumExpr, args)

_is_zero_any(e) = (e isa IntExpr && e.value == 0) || (e isa NumExpr && e.value == 0.0)
_is_one_any(e) = (e isa IntExpr && e.value == 1) || (e isa NumExpr && e.value == 1.0)

function _arg_tier(e::ASTExpr)
    if e isa IntExpr || e isa NumExpr
        return 0
    elseif e isa VarExpr
        return 1
    elseif e isa OpExpr
        return 2
    end
    return 3
end

_numeric_key(e::IntExpr) = Float64(e.value)
_numeric_key(e::NumExpr) = e.value
_numeric_key(e::ASTExpr) = 0.0

function _sort_args!(args::Vector{ASTExpr})
    cache = Dict{Int, String}()
    function get_json(idx::Int, e::ASTExpr)
        haskey(cache, idx) && return cache[idx]
        s = _emit_json(e)
        cache[idx] = s
        return s
    end
    indices = collect(1:length(args))
    sort!(indices; lt = (i, j) -> _compare(args[i], args[j], i, j, get_json))
    snap = [args[i] for i in indices]
    for i in 1:length(args)
        args[i] = snap[i]
    end
    return
end

function _compare(a::ASTExpr, b::ASTExpr, ia::Int, ib::Int, get_json)
    ta, tb = _arg_tier(a), _arg_tier(b)
    if ta != tb
        return ta < tb
    end
    if ta == 0
        av, bv = _numeric_key(a), _numeric_key(b)
        if av != bv
            return av < bv
        end
        # int before float at equal magnitude.
        return (a isa IntExpr) && (b isa NumExpr)
    elseif ta == 1
        return (a::VarExpr).name < (b::VarExpr).name
    else
        return get_json(ia, a) < get_json(ib, b)
    end
end

"""
    canonical_json(expr::ASTExpr) -> String

Emit the canonical on-wire JSON form of an expression per RFC §5.4.6: keys
sorted, no extraneous whitespace, shortest round-trip floats with trailing-`.0`
disambiguation for integer-valued magnitudes, exponent-form (`1e25`, `5e-324`)
outside `[1e-6, 1e21)`, signed zero preserved.

Emissible node fields: every binding (TS/Python/Rust/Julia) serializes exactly
`op`, `args`, `wrt`, `dim`, `fn`, `name`, `value` — the field set the
cross-language canonical fixtures (`tests/conformance/canonical/`) pin.
A node carrying any OTHER set field (aggregate `expr_body`/`ranges`/
`output_idx`/`semiring`, `join`/`filter`, node `id`, …) has NO faithful
canonical JSON in this format:
emitting only the pinned fields would make structurally-different aggregates
byte-identical. Rather than
emit ambiguous bytes — or diverge unilaterally from the other bindings by
emitting more fields — such nodes throw
`CanonicalizeError("E_CANONICAL_UNSUPPORTED_FIELD", …)`. The one in-package
caller (tree-walk CSE `_cse_key`) treats any `CanonicalizeError` as "decline
sharing", which is exactly the safe behavior.
"""
function canonical_json(expr::ASTExpr)::String
    return _emit_json(canonicalize(expr))
end

function _emit_json(e::ASTExpr)::String
    if e isa IntExpr
        return string(e.value)
    elseif e isa NumExpr
        return format_canonical_float(e.value)
    elseif e isa VarExpr
        return _json_string(e.name)
    elseif e isa OpExpr
        return _emit_node_json(e)
    end
    # Defensively unreachable: the four branches above cover every concrete
    # `ASTExpr` subtype. Typed like the rest of the canonicalizer's failures so a
    # future node type surfaces as a CanonicalizeError, not an ErrorException.
    throw(
        CanonicalizeError(
            "E_CANONICAL_BAD_NODE",
            "cannot canonicalize value of type $(typeof(e))"
        )
    )
end

# OpExpr fields WITH a pinned slot in the cross-binding canonical JSON node
# encoding: exactly the set every binding serializes and the cross-language
# canonical fixtures pin (see `canonical_json` docstring). CLOSED — extending
# it is a cross-binding format change, never a Julia-local edit.
const _EMISSIBLE_FIELDS = (:op, :args, :wrt, :dim, :fn, :name, :value, :units)

# OpExpr fields that are TOLERATED-AND-IGNORED by the canonical emitter: a node
# carrying them still canonicalizes, emitting the pinned fields only:
# `bindings` — the apply_expression_template parameter map, a rendering
# convenience normally lowered away before typed parsing (pinned by
# op_registry_test.jl) — and `template_origin`, load provenance.
#
# `expect_cadence` and `attrs` are deliberately NOT here. Both are author
# annotations with no canonical wire slot, and
# `tests/conformance/canonical/README.md` names them among the fields a node may
# carry that MUST make `canonical_json` raise `E_CANONICAL_UNSUPPORTED_FIELD`.
# They fall through to the derived `_NON_EMISSIBLE_FIELDS` below.
const _CANONICAL_IGNORED_FIELDS = (:bindings, :template_origin)

# OpExpr fields WITHOUT a pinned slot in the cross-binding canonical JSON node
# encoding (see `canonical_json` docstring). If any is set, the node cannot be
# emitted faithfully and `_emit_node_json` throws E_CANONICAL_UNSUPPORTED_FIELD.
# Derived, FAIL-CLOSED: every `OpExpr` field that is neither emissible nor
# explicitly ignored is non-emissible, so a future field cannot be silently
# dropped from canonical JSON by forgetting to list it here — it must be added
# to one of the two closed tuples above deliberately. `setdiff` preserves
# `fieldnames` order, which fixes the order of the E_CANONICAL_UNSUPPORTED_FIELD
# message's field listing.
const _NON_EMISSIBLE_FIELDS = Tuple(
    setdiff(
        fieldnames(OpExpr),
        (_EMISSIBLE_FIELDS..., _CANONICAL_IGNORED_FIELDS...)
    )
)

_emit_node_json(n::OpExpr)::String = _emit_node_json(n, _emit_json)

# `emit` emits each argument: `_emit_json`, or a memoized twin of it.
function _emit_node_json(n::OpExpr, emit::F)::String where {F}
    _check_emissible(n)
    entries = Tuple{String, String}[]
    push!(entries, ("op", _json_string(n.op)))
    args_str = "[" * join((emit(a) for a in n.args), ",") * "]"
    push!(entries, ("args", args_str))
    if n.wrt !== nothing
        push!(entries, ("wrt", _json_string(n.wrt::String)))
    end
    if n.dim !== nothing
        push!(entries, ("dim", _json_string(n.dim::String)))
    end
    if n.fn !== nothing
        # `fn` carries the boundary-condition kind on synthetic `bc` nodes
        # (esm-spec §9.2). Emit it symmetrically with `dim`/`wrt` so the kind is
        # preserved in the canonical form — otherwise bc(u,dirichlet,xmin) and
        # bc(u,neumann,xmin) collapse to the same canonical JSON, making the
        # kind/side matcher's canonical equality kind-blind.
        push!(entries, ("fn", _json_string(n.fn::String)))
    end
    if n.name !== nothing
        push!(entries, ("name", _json_string(n.name::String)))
    end
    if n.value !== nothing
        push!(entries, ("value", _emit_canonical_value(n.value)))
    end
    if n.units !== nothing
        # A `const` node's declared unit (esm-spec §4.8.5) is meaning-bearing:
        # the same number in mi/h and in m/s are different quantities, so two
        # nodes differing only in `units` MUST NOT canonicalize alike.
        push!(entries, ("units", _json_string(n.units::String)))
    end
    sort!(entries, by = kv -> kv[1])
    body = join(("$(_json_string(k)):$v" for (k, v) in entries), ",")
    return "{" * body * "}"
end

function _json_string(s::AbstractString)::String
    # Use JSON3 to escape, but JSON3.write returns a string with surrounding
    # quotes. Strip and re-quote to avoid newlines/etc.
    return JSON3.write(String(s))
end

# Raise for a node carrying a field the canonical JSON node encoding has no
# place for.
function _check_emissible(n::OpExpr)
    offending = nothing
    for f in _NON_EMISSIBLE_FIELDS
        getfield(n, f) === nothing && continue
        offending === nothing && (offending = String[])
        push!(offending, String(f))
    end
    offending === nothing && return nothing
    throw(
        CanonicalizeError(
            "E_CANONICAL_UNSUPPORTED_FIELD",
            "op '$(n.op)' carries field(s) [$(join(offending, ", "))] outside " *
                "the canonical JSON node encoding (op/args/wrt/dim/fn/name/value/units); " *
                "emitting them would be lossy and non-portable (RFC §5.4.6)"
        )
    )
end

# Canonical JSON for `const`-op values. Values are JSON-typed (integer,
# Float64, AbstractString, or nested arrays thereof per esm-spec §4.2 / §9.2).
# Integers emit as bare digit-only tokens; arrays recurse element-wise.
#
# Floats: CONFORMANCE_SPEC §5.5.3.1 rule 1 (integral-float normalization)
# applies — a const `value` payload is JSON DATA, not an AST literal, so its
# number type is a property of the VALUE, not of the reader-inferred storage
# (Julia's JSON3 can materialise the token `1` as `Float64` inside nested
# documents, and a `[1, 2.5]` Julia literal is a `Vector{Float64}`). An
# integral, Int64-representable float therefore emits as an integer token
# (`1.0` → `1`, `-0.0` → `0`), byte-matching JSON3's read→write round trip and
# the Rust/Python const-value emitters for integer-token sources. Non-integral
# (or out-of-Int64-range) floats keep the RFC §5.4.6 canonical-float layout,
# like every other binding's const-value emitter. RFC §5.4.6's trailing-`.0`
# int/float disambiguation applies to AST literal NODES (IntExpr/NumExpr),
# never to this data payload.
function _emit_canonical_value(v)::String
    if v isa Bool
        return v ? "true" : "false"
    elseif v isa Integer
        return string(v)
    elseif v isa AbstractFloat
        i = _as_int64(v)
        return i === nothing ? format_canonical_float(Float64(v)) : string(i)
    elseif v isa AbstractString
        return _json_string(v)
    elseif v isa AbstractArray
        return "[" * join((_emit_canonical_value(x) for x in v), ",") * "]"
    end
    # Julia-local code: an unsupported-TYPE payload is internal misuse, not a
    # non-finite float — reusing E_CANONICAL_NONFINITE here would corrupt the
    # RFC §5.4.6/§5.4.7 stable-code contract for that code.
    throw(
        CanonicalizeError(
            "E_CANONICAL_BAD_CONST",
            "unsupported `const` value type: $(typeof(v))"
        )
    )
end

"""
    format_canonical_float(f::Float64) -> String

Format a finite `Float64` per RFC §5.4.6.
"""
function format_canonical_float(f::Float64)::String
    isfinite(f) || throw(
        CanonicalizeError(
            "E_CANONICAL_NONFINITE",
            "non-finite float in canonical form"
        )
    )
    if f == 0.0
        return signbit(f) ? "-0.0" : "0.0"
    end
    a = abs(f)
    use_exp = a < 1.0e-6 || a >= 1.0e21
    if use_exp
        # Julia's default Base.show gives shortest round-trip ("Ryu"); for
        # scientific values it prints e.g. "1.0e25" or "5.0e-324". Need to
        # normalize: strip mantissa trailing zeros after '.', strip leading
        # exponent zeros, no leading + on exp.
        return _normalize_julia_exp(repr(f))
    end
    s = repr(f)
    if occursin('e', s) || occursin('E', s)
        # Within plain range but Julia chose exponent — convert to plain.
        s = _expand_to_plain(f)
    end
    if !occursin('.', s)
        s *= ".0"
    end
    return s
end

function _normalize_julia_exp(s::String)::String
    # Examples: "1.0e25" -> "1e25", "5.0e-324" -> "5e-324", "3.14e-10" -> "3.14e-10"
    s = lowercase(s)
    if !occursin('e', s)
        return s
    end
    parts = split(s, 'e'; limit = 2)
    mant = parts[1]
    exp = parts[2]
    # Strip mantissa trailing zeros after '.'.
    if occursin('.', mant)
        mant = rstrip(mant, '0')
        mant = rstrip(mant, '.')
    end
    if isempty(mant)
        mant = "0"
    end
    # Normalize exponent: drop leading +, drop leading 0s preserving sign.
    if startswith(exp, "+")
        exp = exp[2:end]
    end
    sign = ""
    if startswith(exp, "-")
        sign = "-"
        exp = exp[2:end]
    end
    exp = lstrip(exp, '0')
    if isempty(exp)
        exp = "0"
    end
    return string(mant, "e", sign, exp)
end

function _expand_to_plain(f::Float64)::String
    # Expand Julia's shortest-round-trip exponent form (e.g. "1.5e6",
    # "1.0e-5") to plain decimal by shifting the mantissa's decimal point.
    # This is fully deterministic.
    s = repr(f)
    if !occursin('e', lowercase(s))
        return s
    end
    parts = split(lowercase(s), 'e')
    out = _shift_decimal(parts[1], parse(Int, parts[2]))
    if occursin('.', out)
        out = rstrip(out, '0')
        out = rstrip(out, '.')
    end
    return out
end

function _shift_decimal(mant::AbstractString, exp::Int)::String
    sign = ""
    if startswith(mant, '-')
        sign = "-"
        mant = mant[2:end]
    end
    if !occursin('.', mant)
        mant = mant * "."
    end
    dot = findfirst('.', mant)
    digits = String(replace(String(mant), '.' => ""))
    pos = dot - 1 + exp  # new decimal position from start
    if pos <= 0
        digits = "0"^(1 - pos) * digits
        pos = 1
    elseif pos > length(digits)
        digits = digits * "0"^(pos - length(digits))
    end
    if pos == length(digits)
        return string(sign, digits)
    end
    return string(sign, digits[1:pos], ".", digits[(pos + 1):end])
end

# ---------------------------------------------------------------------------
# The document-level canonical step (esm-spec §4.8.2 "Canonical spelling").
# ---------------------------------------------------------------------------

using OrderedCollections: OrderedDict

# Object properties whose value is a NAME-KEYED map (esm-schema.json): a map's
# keys are names, never fields, so a variable NAMED `units` is not a units
# string. The same list in every binding.
const _DOCUMENT_MAP_KEYS = Set{String}(
    [
        "bind", "bindings", "coordinates", "coords", "coupling_roles", "data_sources",
        "enums", "operator_imports", "operators", "guesses",
        "index_set_rename", "index_sets", "initial_conditions", "map", "metaparameters",
        "models", "parameter_overrides", "parameters", "pinned_coords", "ranges",
        "reaction_systems", "rebind", "rename", "species", "subsystems", "translate",
        "url_substitutions", "variables", "where",
    ]
)

# Free-form objects (schema `additionalProperties: true`), never descended.
const _DOCUMENT_FREE_KEYS = Set{String}(["attrs", "config", "metadata", "reader_options", "x_esd"])

"""
    canonicalize_document(doc::AbstractDict) -> OrderedDict{String, Any}

The document-level canonical step: every units string of a decoded document
(the JSON object `to_json` writes and `load_document` reads, e.g. from
`JSON3.read`) takes the canonical unit spelling (esm-spec §4.8.2, Lean
`Esm.Units.canon`).

That is every `units` and `default_units` string of a variable, species,
parameter, coordinate or `const` node, wherever it sits: nested subsystems,
template bodies, tests, coupling entries. Free-form objects (`metadata`,
`x_esd`, `attrs`, `config`, `reader_options`) are not respelled, and neither are
the keys of name-keyed maps. A `const` node whose units spell `1` loses them: a
scalar one becomes the bare literal, an array one a `const` without `units`.
The deprecated ops are rewritten (esm-spec §4.2): a `neg` node with one argument
becomes unary `-`, a `pow` node with two becomes `^`, and a `broadcast` of `neg`
with one argument maps `-`. Every number, free-form objects included, takes its
canonical form (CONFORMANCE §5.5.3.1): an integral value in `Int64` is an
integer (`2.0` is `2`, `-0.0` is `0`). The input is not mutated, key order is
kept, and nothing else changes. These are the rules of Lean
`Adapter.Doc.spellRules` and `Adapter.Doc.conv`.
"""
canonicalize_document(doc::AbstractDict) =
    _canonical_document_numbers(_canonicalize_document_value(_respell_old_quietly(doc), false))

# esm 2.4.0 (esm-spec §9.6.12, §4.2): the canonical form spells only the new
# names, so an earlier document's spellings are read as the wire boundary reads
# them (`_rewrite_old_spellings!`), on a copy and without the warnings.
function _respell_old_quietly(doc)
    _has_old_spellings(doc) || return doc
    d = _to_ordered(doc)
    _old_spellings_walk!(d, "", false, nothing, String[], String[], IdDict{Any, Nothing}())
    return d
end

# The deprecated ops (esm-spec §4.2): spelling => (replacement, operand count),
# from the registry (`_DEPRECATED_OPS` and each spelling's fixed arity).
const _DEPRECATED_DOCUMENT_OPS = Dict(
    k => (v, only(_op_spec(k).arity::UnitRange{Int})) for (k, v) in _DEPRECATED_OPS
)

# A JSON number in canonical form (CONFORMANCE §5.5.3.1): an integral float in
# Int64 is an integer, an integer outside Int64 a float. A float already holds
# the nearest binary64 of its token.
function _canonical_document_number(x::Real)
    x isa Bool && return x
    return something(_as_int64(x), Float64(x))
end

# Every number of a JSON value in canonical form, at every depth.
function _canonical_document_numbers(value)
    value isa Real && return _canonical_document_number(value)
    value isa AbstractVector && return Any[_canonical_document_numbers(v) for v in value]
    if value isa AbstractDict
        out = OrderedDict{String, Any}()
        for (k, v) in pairs(value)
            out[String(k)] = _canonical_document_numbers(v)
        end
        return out
    end
    return value
end

# `neg` with one argument is unary `-`, `pow` with two is `^`, a `broadcast` of
# `neg` with one argument maps `-` (Lean `Adapter.Doc.deprecatedTo`).
function _rewrite_deprecated_document_op!(out::OrderedDict{String, Any})
    op = get(out, "op", nothing)
    args = get(out, "args", nothing)
    (op isa AbstractString && args isa AbstractVector) || return out
    rule = get(_DEPRECATED_DOCUMENT_OPS, op, nothing)
    if rule !== nothing
        length(args) == rule[2] && (out["op"] = rule[1])
    elseif op == "broadcast" && get(out, "fn", nothing) == "neg" && length(args) == 1
        out["fn"] = "-"
    end
    return out
end

function _canonicalize_document_value(value, is_map::Bool)
    if value isa AbstractVector
        return Any[_canonicalize_document_value(v, false) for v in value]
    elseif value isa AbstractDict
        units = _raw_get(value, "units")
        op = _raw_get(value, "op")
        drop_units = false
        if !is_map && op == "const" && units isa AbstractString && _canonical_units(units) == "1"
            # A dimensionless const drops its units: a scalar becomes the bare
            # literal, an array a unitless const.
            literal = _raw_get(value, "value")
            literal isa Real && !(literal isa Bool) && return literal
            drop_units = true
        end
        out = OrderedDict{String, Any}()
        # A definition's `units` is a unit EXPRESSION over its params
        # (esm-spec §9.6.1), not a unit string.
        is_definition = !is_map && _raw_haskey(value, "params") && _raw_haskey(value, "body")
        for (k, v) in pairs(value)
            key = String(k)
            (drop_units && key == "units") && continue
            out[key] = if is_map
                _canonicalize_document_value(v, false)
            elseif is_definition && key == "units"
                _canonicalize_document_value(v, false)
            elseif (key == "units" || key == "default_units") && v isa AbstractString
                _canonical_units(v)
            elseif key in _DOCUMENT_FREE_KEYS
                v
            else
                _canonicalize_document_value(v, key in _DOCUMENT_MAP_KEYS)
            end
        end
        is_map || _rewrite_deprecated_document_op!(out)
        return out
    end
    return value
end
