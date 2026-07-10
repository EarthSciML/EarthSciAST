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
struct ConflictingDerivativeError <: Exception
    species::Vector{String}
end

function Base.showerror(io::IO, e::ConflictingDerivativeError)
    names = join(e.species, ", ")
    print(io, "ConflictingDerivativeError: species have both an explicit ",
          "derivative equation and a reaction contribution: ", names)
end

"""
    DimensionPromotionError

Raised during flatten when a variable or equation cannot be promoted from
its source domain to the target domain given the available `Interface` rules
(§4.7.6).
"""
struct DimensionPromotionError <: Exception
    details::String
end
Base.showerror(io::IO, e::DimensionPromotionError) =
    print(io, "DimensionPromotionError: ", e.details)

"""
    UnmappedDomainError

Raised when two systems on different domains are coupled without an `Interface`
that defines their dimension mapping (§4.7.6).
"""
struct UnmappedDomainError <: Exception
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
struct UnsupportedMappingError <: Exception
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
struct DomainUnitMismatchError <: Exception
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
struct DomainExtentMismatchError <: Exception
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
struct SliceOutOfDomainError <: Exception
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
struct CyclicPromotionError <: Exception
    variables::Vector{String}
end
Base.showerror(io::IO, e::CyclicPromotionError) =
    print(io, "CyclicPromotionError: cyclic promotion detected involving ",
          "variables ", e.variables)
