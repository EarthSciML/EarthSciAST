# Flatten error taxonomy (spec §4.7.5 / §4.7.6): the 8 exported error types,
# kept name-for-name with the Rust `FlattenError` variants and the Python
# `flatten()` exception set for cross-language parity. Split from flatten.jl;
# see flatten.jl for the pipeline overview.

# ========================================
# Error Types (§4.7.5 / §4.7.6 taxonomy)
# ========================================

"""
    ConflictingDerivativeError

Raised when a species appears both as the left-hand side of an explicit
differential equation (`D(X, t) = ...`) and as a substrate or product of any
reaction in the same flattened file. Such a system is over-determined: the
reaction contribution to `d[X]/dt` would silently shadow the user's equation.

Fields:
- `species::Vector{String}`: fully-qualified (dot-namespaced) names of every
  offending species.
"""
struct ConflictingDerivativeError <: EarthSciASTError
    species::Vector{String}
end

function Base.showerror(io::IO, e::ConflictingDerivativeError)
    names = join(e.species, ", ")
    print(io, "ConflictingDerivativeError: species have both an explicit ",
          "derivative equation and a reaction contribution: ", names)
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
struct OperatorComposeNoMergeError <: EarthSciASTError
    details::String
end
Base.showerror(io::IO, e::OperatorComposeNoMergeError) =
    print(io, "OperatorComposeNoMergeError: ", e.details)

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
struct OperatorComposeRequireMatchError <: EarthSciASTError
    details::String
end
Base.showerror(io::IO, e::OperatorComposeRequireMatchError) =
    print(io, "OperatorComposeRequireMatchError: ", e.details)

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
struct OperatorComposeAmbiguousBareNameError <: EarthSciASTError
    details::String
end
Base.showerror(io::IO, e::OperatorComposeAmbiguousBareNameError) =
    print(io, "OperatorComposeAmbiguousBareNameError: ", e.details)

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
struct VariableMapUnresolvedEndpointError <: EarthSciASTError
    from::String
    to::String
    side::String
    endpoint::String
end

Base.showerror(io::IO, e::VariableMapUnresolvedEndpointError) =
    print(io, "VariableMapUnresolvedEndpointError: variable_map(", e.from, " -> ", e.to,
          "): the '", e.side, "' endpoint '", e.endpoint, "' resolves to no variable, ",
          "parameter or observed in the flattened system (esm-spec §4.6, §10.4). A scoped ",
          "reference walks EVERY dot-separated segment, so a subsystem endpoint is spelled ",
          "'<Model>.<Subsystem>.<name>'.")

"""
    DimensionPromotionError

Raised during flatten when a variable or equation cannot be promoted from
its source domain to the target domain given the available `Interface` rules
(§4.7.6).
"""
struct DimensionPromotionError <: EarthSciASTError
    details::String
end
Base.showerror(io::IO, e::DimensionPromotionError) =
    print(io, "DimensionPromotionError: ", e.details)

"""
    UnmappedDomainError

Raised when two systems on different domains are coupled without an `Interface`
that defines their dimension mapping (§4.7.6).
"""
struct UnmappedDomainError <: EarthSciASTError
    source::String
    target::String
end
Base.showerror(io::IO, e::UnmappedDomainError) =
    print(io, "UnmappedDomainError: no Interface maps domain '", e.source,
          "' to domain '", e.target, "'")

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
struct UnsupportedMappingError <: EarthSciASTError
    mapping_type::String
end
Base.showerror(io::IO, e::UnsupportedMappingError) =
    print(io, "UnsupportedMappingError: mapping type '",
          e.mapping_type, "' is not supported by this library tier")

"""
    DomainUnitMismatchError

Raised when coupling across an `Interface` requires a unit conversion that
was not declared by the user (§4.7.6).
"""
struct DomainUnitMismatchError <: EarthSciASTError
    variable::String
    source_units::String
    target_units::String
end
Base.showerror(io::IO, e::DomainUnitMismatchError) =
    print(io, "DomainUnitMismatchError: variable '", e.variable,
          "' has units '", e.source_units, "' on source and '",
          e.target_units, "' on target")

"""
    DomainExtentMismatchError

Defined for cross-language error-name parity with the Rust `FlattenError`
taxonomy and the Python `flatten()` exception set. Would be raised when an
`identity` mapping bridges two domains whose spatial extents on a shared
independent variable disagree. The Julia flatten pipeline does not currently
perform this check, so this type is reserved and never raised by the current
implementation — it exists so consumers can catch it by name.
"""
struct DomainExtentMismatchError <: EarthSciASTError
    variable::String
end
Base.showerror(io::IO, e::DomainExtentMismatchError) =
    print(io, "DomainExtentMismatchError: domain extent mismatch on ",
          "independent variable '", e.variable, "' under identity mapping")

"""
    SliceOutOfDomainError

Defined for cross-language error-name parity; only raised if `slice` is ever
implemented at a higher tier in the Julia flatten pipeline. Would be raised
when a `slice` mapping's fixed coordinate lies outside the source variable's
declared domain extent.
"""
struct SliceOutOfDomainError <: EarthSciASTError
    coordinate::String
    value::String
end
Base.showerror(io::IO, e::SliceOutOfDomainError) =
    print(io, "SliceOutOfDomainError: slice coordinate '", e.coordinate,
          "' = ", e.value, " lies outside the source domain extent")

"""
    CyclicPromotionError

Defined for cross-language error-name parity. Not raised by Core-tier Julia
because no promotion graph is built — reserved for a future tier upgrade that
does promotion-graph analysis. Would signal that the declared `Interface`
rules form a cycle (A promotes to B, B promotes back to A on a different
axis).
"""
struct CyclicPromotionError <: EarthSciASTError
    variables::Vector{String}
end
Base.showerror(io::IO, e::CyclicPromotionError) =
    print(io, "CyclicPromotionError: cyclic promotion detected involving ",
          "variables ", e.variables)
