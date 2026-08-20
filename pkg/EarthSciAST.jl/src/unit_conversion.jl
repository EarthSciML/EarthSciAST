# ============================================================================
# Applying a data loader's declared `unit_conversion` (esm-spec §8.5).
#
#   "`unit_conversion` is either a plain multiplicative factor or a full
#    `Expression` AST (§4); the runtime applies it WHEN PRODUCING VALUES IN THE
#    DECLARED `units`."
#
# Two spellings, because a unit conversion is not always a scale. §4.8.1 keeps
# affine offsets OUT of the dimensional metadata on purpose — `degF` carries the
# Kelvin dimension and the scale 5/9, and "a unit conversion that needs the
# offset is a `unit_conversion` expression, not a dimensional judgement". So
# ft→m is the number `0.3048` and °F→K is the expression
# `stktemp*5/9 + 459.67*5/9`, and a runtime that honours only the first silently
# delivers Fahrenheit.
#
# An expression is evaluated ONCE PER ELEMENT with the raw value bound to its
# single free variable — by convention the loader variable's own name, though
# the scope a loader's conversion resolves against is every name the DOCUMENT
# declares (`_document_declared_names`), so what is bound is "the one free
# variable" rather than "the variable called X". A closed expression (no free
# variables) folds to a constant and takes the same multiply path as a bare
# factor.
#
# The Julia peer of the Python `earthsci_ast.data_sources` binding and the
# Rust `earthsci_ast::unit_conversion`. All three must agree bit for bit: the
# conversion is the last thing that touches a delivered array, so a
# disagreement here is a disagreement about the numbers the model integrates.
# ============================================================================

"""A `unit_conversion` that cannot be parsed or applied."""
struct UnitConversionError <: Exception
    msg::String
end
Base.showerror(io::IO, e::UnitConversionError) = print(io, e.msg)

"""
    parse_unit_conversion(raw; variable_name) -> Nothing | Float64 | ASTExpr

Parse a loader variable's RAW `unit_conversion` (`number | Expression`).

`nothing` (the field is absent, or `null`) means the variable declares no
conversion — so a document that declares none costs nothing and behaves exactly
as it did before this existed.
"""
function parse_unit_conversion(raw; variable_name::AbstractString)
    raw === nothing && return nothing
    raw isa Bool && throw(UnitConversionError(
        "variable '$(variable_name)' unit_conversion must be a number or an " *
        "Expression object, got a boolean"))
    raw isa Real && return Float64(raw)
    raw isa ASTExpr && return raw
    raw isa AbstractDict && return parse_expression(raw)
    throw(UnitConversionError(
        "variable '$(variable_name)' unit_conversion must be a number or an " *
        "Expression object, got $(typeof(raw))"))
end

# The constant scale `conversion` reduces to, or `nothing` when it is an OPEN
# expression that has to be evaluated per element.
function _unit_conversion_scale(conversion, variable_name::AbstractString)
    conversion isa Real && return Float64(conversion)
    isempty(free_variables(conversion)) || return nothing
    try
        node = _compile(conversion, Dict{String,Int}(), Set{Symbol}(), Dict{String,Any}())
        return _eval_node(node, Float64[], NamedTuple(), 0.0)
    catch e
        throw(UnitConversionError(
            "variable '$(variable_name)' unit_conversion is a constant expression " *
            "but did not evaluate: $(sprint(showerror, e))"))
    end
end

"""
    apply_unit_conversion!(values, conversion; variable_name) -> values

Apply `conversion` to `values` IN PLACE, producing the variable's declared units
(esm-spec §8.5).

A factor (or a closed expression, which folds to one) multiplies; a factor of
exactly `1.0` leaves the values untouched rather than round-tripping them through
a multiply. An open expression is COMPILED ONCE and then evaluated per element
with the raw value bound to its single free variable; more than one free variable
is an error, since there is no second column to bind it to.
"""
function apply_unit_conversion!(values::AbstractVector{Float64}, conversion;
                                variable_name::AbstractString)
    conversion === nothing && return values
    scale = _unit_conversion_scale(conversion, variable_name)
    if scale !== nothing
        scale == 1.0 && return values
        @inbounds for i in eachindex(values)
            values[i] *= scale
        end
        return values
    end
    free = sort!(collect(free_variables(conversion)))
    length(free) == 1 || throw(UnitConversionError(
        "variable '$(variable_name)' unit_conversion must depend on at most one " *
        "free variable, got $(free)"))
    sym = Symbol(free[1])
    node = _compile(conversion, Dict{String,Int}(), Set{Symbol}([sym]), Dict{String,Any}())
    @inbounds for i in eachindex(values)
        values[i] = _eval_node(node, Float64[], NamedTuple{(sym,)}((values[i],)), 0.0)
    end
    return values
end

"""
    apply_unit_conversion(values, conversion; variable_name) -> Array

Non-mutating [`apply_unit_conversion!`](@ref): returns a converted copy, or
`values` itself when there is nothing to apply.
"""
function apply_unit_conversion(values::AbstractArray, conversion;
                               variable_name::AbstractString)
    conversion === nothing && return values
    out = Array{Float64}(undef, size(values))
    copyto!(out, values)
    apply_unit_conversion!(vec(out), conversion; variable_name = variable_name)
    return out
end
