# Flatten error taxonomy (esm-libraries-spec §4.7.5, §4.7.6), kept name for
# name with the Rust `FlattenError` variants and the Python `flatten()`
# exception set.

"""
    _FlattenDiagnostic <: EarthSciASTError

Supertype of the errors `flatten` raises about the document it flattens. Each
subtype leads with `code::String`, the diagnostic code a caller branches on
(for a type whose message begins with a code, `"<code>: …"`, that code), and
prints through the one `showerror` below: the type's name, then its message.
Each keeps its positional constructor without the code, which it fills in.
"""
abstract type _FlattenDiagnostic <: EarthSciASTError end

Base.showerror(io::IO, e::_FlattenDiagnostic) =
    (print(io, nameof(typeof(e)), ": "); _flatten_message(io, e))

# The code a message spells as its prefix (`"array_shape_mismatch: …"`), else
# `default`.
function _prefix_code(details::AbstractString, default::String)
    m = match(r"^([a-z][a-z0-9_]*): ", details)
    return m === nothing ? default : String(m.captures[1])
end

# ========================================
# Error Types (§4.7.5 / §4.7.6 taxonomy)
# ========================================

"""
    ConflictingDerivativeError

Raised when a species appears both as the left-hand side of an explicit
differential equation (`D(X, t) = ...`) and as a substrate or product of any
reaction in the same flattened file. Such a system is over-determined: the
reaction contribution to `d[X]/dt` would silently shadow the user's equation.

Also raised when a state has more than one initial condition `ic(x)` after
coupling (an authored one and an operator's `ic(_var)` expanded onto it, or two
such templates): `field_ics` holds at most one entry per state
(esm-libraries-spec §4.7.5 step 4).

Fields:
- `species::Vector{String}`: fully-qualified (dot-namespaced) names of every
  offending species.
- `reason::String`: what conflicts; the reaction-contribution wording when
  constructed with the species alone.
"""
struct ConflictingDerivativeError <: _FlattenDiagnostic
    code::String
    species::Vector{String}
    reason::String
end
ConflictingDerivativeError(species, reason) = ConflictingDerivativeError("conflicting_derivative", species, reason)

ConflictingDerivativeError(species::Vector{String}) = ConflictingDerivativeError(
    species, "species have both an explicit derivative equation and a reaction contribution"
)

function _flatten_message(io::IO, e::ConflictingDerivativeError)
    return print(io, e.reason, ": ", join(e.species, ", "))
end

"""
    OperatorComposeNoMergeError

Raised when an `operator_compose` entry merges NOTHING (esm-libraries-spec §4.7.1
step 5).

An entry that matches nothing is indistinguishable from an entry that is not
there: the operator integrates a private, decoupled system from its own defaults,
the other system receives no contribution at all, and the only evidence is a
state count one too high. That is the one outcome a coupling mis-specification
must not have, so it is refused rather than reported.

An operator that genuinely contributes only states of its own — a transport
operator whose single equation defines its own wind field, say — says so with
`require_match: false`, and is then permitted.

Fields:
- `details::String`: the entry, the merge tally, and the unmatched dependent
  variables.
"""
struct OperatorComposeNoMergeError <: _FlattenDiagnostic
    code::String
    details::String
end
OperatorComposeNoMergeError(details) = OperatorComposeNoMergeError(_prefix_code(details, "operator_compose_no_merge"), details)
_flatten_message(io::IO, e::OperatorComposeNoMergeError) =
    print(io, e.details)

"""
    OperatorComposeRequireMatchError

Raised when an `operator_compose` entry declares `require_match: true` and one of
`systems[2]`'s equations found no equation of `systems[1]` to land on
(esm-libraries-spec §4.7.1 step 5).

Step 5 otherwise preserves an unmatched equation unchanged, and a PARTIAL
shortfall is only a warning by default; `require_match` is the author's opt-in to
make it fatal. A PARTIAL match raises here — there is no "some is enough" reading
an author could rely on.

Fields:
- `details::String`: the entry, the merge tally, and the unmatched dependent
  variables.
"""
struct OperatorComposeRequireMatchError <: _FlattenDiagnostic
    code::String
    details::String
end
OperatorComposeRequireMatchError(details) = OperatorComposeRequireMatchError(_prefix_code(details, "operator_compose_require_match_unmatched"), details)
_flatten_message(io::IO, e::OperatorComposeRequireMatchError) =
    print(io, e.details)

"""
    OperatorComposeAmbiguousBareNameError

Raised when the bare-name fallback would unify two STATE variables and the
document has not said which spelling survives (esm-libraries-spec §4.7.1 step 3).

The fallback binds `A.x` to `B.x` on the strength of a shared local name alone.
When both are states, each carries its own INITIAL CONDITION, and the merge has
to delete one of them — so the choice decides which IC the flattened system
integrates from. Nothing in the document expresses that choice, and picking one
silently is how flipping the entry's `systems` order came to change the answer.

So it is refused. The author says what they mean with `translate`, which names
the surviving spelling outright, or with `require_match`.

A match where only ONE side is a state is NOT ambiguous: the other carries no
initial condition, so the state is the owner and the merge renames onto it.

Fields:
- `details::String`: the entry and the two spellings it tried to unify.
"""
struct OperatorComposeAmbiguousBareNameError <: _FlattenDiagnostic
    code::String
    details::String
end
OperatorComposeAmbiguousBareNameError(details) = OperatorComposeAmbiguousBareNameError(_prefix_code(details, "operator_compose_ambiguous_bare_name"), details)
_flatten_message(io::IO, e::OperatorComposeAmbiguousBareNameError) =
    print(io, e.details)

"""
    VariableMapUnresolvedEndpointError

Raised when a `variable_map` endpoint names nothing the flattened system
carries (esm-spec §4.6, §10.4).

Both halves of the entry are load-bearing and both used to fail SILENTLY. A
`to` that resolves to no parameter is simply never promoted
(`_promote_variable_map_param!` returns on `haskey(params, entry.to) ||
return`): the document declares a coupling, the target keeps its declared
default, and nothing downstream can tell "applied" from "ignored". A `from`
that resolves to nothing is worse — `_substitute_variable_map!` runs
regardless, so every consumer of `to` is rewritten to a name no table binds and
the run yields NaN rather than a diagnostic.

Deliberately NOT exported: `api-surface.json` is the cross-binding record of
what every binding exports, and adding a name there is a five-binding contract
change. Callers catch `EarthSciASTError`.

Fields:
- `from`, `to`: the entry's two endpoints as authored.
- `side`: `"from"` or `"to"` — which endpoint failed to resolve.
- `endpoint`: the offending reference.
"""
struct VariableMapUnresolvedEndpointError <: _FlattenDiagnostic
    code::String
    from::String
    to::String
    side::String
    endpoint::String
end
VariableMapUnresolvedEndpointError(from, to, side, endpoint) = VariableMapUnresolvedEndpointError("variable_map_unresolved_endpoint", from, to, side, endpoint)

_flatten_message(io::IO, e::VariableMapUnresolvedEndpointError) =
    print(
    io, "variable_map(", e.from, " -> ", e.to,
    "): the '", e.side, "' endpoint '", e.endpoint, "' resolves to no variable, ",
    "parameter or observed in the flattened system (esm-spec §4.6, §10.4). A scoped ",
    "reference walks EVERY dot-separated segment, so a subsystem endpoint is spelled ",
    "'<Model>.<Subsystem>.<name>'."
)

"""
    VariableMapShapeConflictError

Raised when a data-fed `variable_map` source's shape differs from the shape of
the shaped target it replaces (esm-libraries-spec §4.7.3).

The parameter that survives a `param_to_var` or `conversion_factor` edge is the
SOURCE's own declaration. When the removed target is shaped, the rewritten
equations index the source the way the target was declared, so a source that
declares a `shape` (`[]`, a scalar buffer, included) must declare the target's,
and a source that declares none takes it — which requires every target it
replaces to declare the same one. Taking either shape silently would leave
equations indexing a parameter of the wrong rank, or — with one source feeding
two targets — make the result depend on coupling order.

Same export policy as [`VariableMapUnresolvedEndpointError`](@ref).

Fields:
- `from`, `to`: the entry's two endpoints.
- `source_shape`: the source's shape — its declared one, or the one it took
  from an earlier target when `took_shape`.
- `target_shape`: the removed target's declared shape.
- `took_shape`: the source declares no `shape` and took `source_shape` from an
  earlier `param_to_var` target.
"""
struct VariableMapShapeConflictError <: _FlattenDiagnostic
    code::String
    from::String
    to::String
    source_shape::Vector{String}
    target_shape::Vector{String}
    took_shape::Bool
end
VariableMapShapeConflictError(from, to, source_shape, target_shape, took_shape) = VariableMapShapeConflictError("variable_map_shape_conflict", from, to, source_shape, target_shape, took_shape)

function _flatten_message(io::IO, e::VariableMapShapeConflictError)
    print(
        io, "variable_map(", e.from, " -> ", e.to,
        "): the data-fed source '", e.from, "' "
    )
    if e.took_shape
        print(
            io, "declares no shape and took ", e.source_shape, " from an earlier ",
            "param_to_var target, but this target declares ", e.target_shape,
            ". A shapeless data-fed source takes its shape from the targets it ",
            "replaces, so they must all declare the same one"
        )
    else
        print(
            io, "declares shape ", e.source_shape, ", but the target it replaces ",
            "declares ", e.target_shape, ". The source survives with its own ",
            "declaration and the rewritten equations index it the way the target ",
            "was declared, so the two must be equal; declare '", e.from,
            "' with shape ", e.target_shape, ", or with no shape to take the target's"
        )
    end
    return print(io, " (esm-libraries-spec §4.7.3).")
end

"""
    DimensionPromotionError

Raised during flatten when a variable or equation cannot be promoted from
its source domain to the target domain given the available `Interface` rules
(§4.7.6).
"""
struct DimensionPromotionError <: _FlattenDiagnostic
    code::String
    details::String
end
DimensionPromotionError(details) = DimensionPromotionError(_prefix_code(details, "dimension_promotion"), details)
_flatten_message(io::IO, e::DimensionPromotionError) =
    print(io, e.details)

"""
    UnmappedDomainError

Raised when two systems on different domains are coupled without an `Interface`
that defines their dimension mapping (§4.7.6).
"""
struct UnmappedDomainError <: _FlattenDiagnostic
    code::String
    source::String
    target::String
end
UnmappedDomainError(source, target) = UnmappedDomainError("unmapped_domain", source, target)
_flatten_message(io::IO, e::UnmappedDomainError) =
    print(
    io, "no Interface maps domain '", e.source,
    "' to domain '", e.target, "'"
)

"""
    UnsupportedMappingError

Raised when an `Interface` requests a `dimension_mapping` type or regridding
strategy that is not supported by the current library tier (§4.7.6). The
`mapping_type` field carries the offending type or strategy name (e.g.
`"slice"`, `"project"`, `"regrid"`, or a specific regridding method like
`"cubic_spline"`). Matches the Rust `FlattenError::UnsupportedMapping` variant
and the Python `UnsupportedMappingError` exception for cross-language
error-name parity.
"""
struct UnsupportedMappingError <: _FlattenDiagnostic
    code::String
    mapping_type::String
end
UnsupportedMappingError(mapping_type) = UnsupportedMappingError("unsupported_mapping", mapping_type)
_flatten_message(io::IO, e::UnsupportedMappingError) =
    print(
    io, "mapping type '",
    e.mapping_type, "' is not supported by this library tier"
)

"""
    DomainUnitMismatchError

Raised when coupling across an `Interface` requires a unit conversion that
was not declared by the user (§4.7.6).
"""
struct DomainUnitMismatchError <: _FlattenDiagnostic
    code::String
    variable::String
    source_units::String
    target_units::String
end
DomainUnitMismatchError(variable, source_units, target_units) = DomainUnitMismatchError("domain_unit_mismatch", variable, source_units, target_units)
_flatten_message(io::IO, e::DomainUnitMismatchError) =
    print(
    io, "variable '", e.variable,
    "' has units '", e.source_units, "' on source and '",
    e.target_units, "' on target"
)

"""
    DomainExtentMismatchError

Defined for cross-language error-name parity with the Rust `FlattenError`
taxonomy and the Python `flatten()` exception set. Would be raised when an
`identity` mapping bridges two domains whose spatial extents on a shared
independent variable disagree. The Julia flatten pipeline does not currently
perform this check, so this type is reserved and never raised by the current
implementation — it exists so consumers can catch it by name.
"""
struct DomainExtentMismatchError <: _FlattenDiagnostic
    code::String
    variable::String
end
DomainExtentMismatchError(variable) = DomainExtentMismatchError("domain_extent_mismatch", variable)
_flatten_message(io::IO, e::DomainExtentMismatchError) =
    print(
    io, "domain extent mismatch on ",
    "independent variable '", e.variable, "' under identity mapping"
)

"""
    SliceOutOfDomainError

Defined for cross-language error-name parity; only raised if `slice` is ever
implemented at a higher tier in the Julia flatten pipeline. Would be raised
when a `slice` mapping's fixed coordinate lies outside the source variable's
declared domain extent.
"""
struct SliceOutOfDomainError <: _FlattenDiagnostic
    code::String
    coordinate::String
    value::String
end
SliceOutOfDomainError(coordinate, value) = SliceOutOfDomainError("slice_out_of_domain", coordinate, value)
_flatten_message(io::IO, e::SliceOutOfDomainError) =
    print(
    io, "slice coordinate '", e.coordinate,
    "' = ", e.value, " lies outside the source domain extent"
)

"""
    CyclicPromotionError

Defined for cross-language error-name parity. Not raised by Core-tier Julia
because no promotion graph is built — reserved for a future tier upgrade that
does promotion-graph analysis. Would signal that the declared `Interface`
rules form a cycle (A promotes to B, B promotes back to A on a different
axis).
"""
struct CyclicPromotionError <: _FlattenDiagnostic
    code::String
    variables::Vector{String}
end
CyclicPromotionError(variables) = CyclicPromotionError("cyclic_promotion", variables)
_flatten_message(io::IO, e::CyclicPromotionError) =
    print(
    io, "cyclic promotion detected involving ",
    "variables ", e.variables
)
