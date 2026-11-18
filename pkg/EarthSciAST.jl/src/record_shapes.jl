"""
    _written_records_per_sample(binding::DataSourceBinding, source) -> Union{Int, Nothing}
    _written_records_per_sample(coerce, from::AbstractDict, source) -> Union{Int, Nothing}

The deprecated `records_per_sample` WRITTEN for a `data` rule (esm-spec
§8.5.1): the binding's own `from.records_per_sample`, else the source's
`temporal.records_per_sample`, else `nothing`. It no longer decides how many
records the parameter receives — its record shape does (see
[`_record_axis_verdict`](@ref)) — and a written value that disagrees with the
shape is `records_per_sample_invalid`.

The typed form takes the rule's `DataSourceBinding` and the `DataSource` it
names (or `nothing`). The raw form takes the rule's `from` object and the
source's `data_sources` entry (or `nothing`) as parsed JSON, and passes each
value present through `coerce(value, origin)` before the rule picks one;
`origin` is `:from` or `:temporal`. `coerce` returns the value as an `Int` or
throws, so the caller decides how strictly a raw value is read.
"""
function _written_records_per_sample(binding::DataSourceBinding, source)
    t = source === nothing ? nothing : source.temporal
    own = binding.records_per_sample
    return own !== nothing ? own : t === nothing ? nothing : t.records_per_sample
end

function _written_records_per_sample(coerce, from::AbstractDict, source)
    own = get(from, "records_per_sample", nothing)
    t = source isa AbstractDict ? get(source, "temporal", nothing) : nothing
    inherited = t isa AbstractDict ? get(t, "records_per_sample", nothing) : nothing
    own === nothing || (own = coerce(own, :from)::Int)
    inherited === nothing || (inherited = coerce(inherited, :temporal)::Int)
    return own !== nothing ? own : inherited
end

"""
    _record_shapes(own_shape, targets, target_shape) -> (shapes, mapped)

The record shapes of a data-fed parameter (esm-spec §8.5.1), whatever carries
the document. `own_shape` is the parameter's declared `shape` (`nothing` when it
declares none); a declared shape, `[]` included, is THE record shape. Otherwise
each `t` in `targets` (the `to` of every `param_to_var` `variable_map` entry
whose `from` is the parameter) contributes `target_shape(t)`: its declared
shape (`[]` when it declares none), or `nothing` when the declaration cannot be
reached (not found, or behind a `ref` not yet mounted), which is skipped, never
read as empty. `mapped` is whether there was a declared shape or any target at
all; a shapeless parameter that is the `from` of no such entry has an empty
record shape, which the caller supplies when no target may still arrive.

Shared by validation, `flatten`, `loader_fields` and the EarthSciIO provider
extension, so the precedence is stated once.
"""
function _record_shapes(own_shape, targets, target_shape)
    own_shape === nothing || return (Vector{String}[collect(String, own_shape)], true)
    shapes = Vector{String}[]
    mapped = false
    for t in targets
        mapped = true
        s = target_shape(t)
        s === nothing || push!(shapes, collect(String, s))
    end
    return shapes, mapped
end

"""
    _record_axis_verdict(shapes, is_record_axis) -> (misplaced::Bool, records::Int)

esm-spec §8.5.1 over a data-fed parameter's record shapes: `records` is 2 when
a record shape begins with a record axis (`is_record_axis(name)`), else 1;
`misplaced` (`record_axis_misplaced`) is whether some shape names a record axis
anywhere but first, or some shapes begin with one while others do not.
"""
function _record_axis_verdict(shapes, is_record_axis)
    misplaced = false
    leading = 0
    for s in shapes
        any(is_record_axis, Iterators.drop(s, 1)) && (misplaced = true)
        (!isempty(s) && is_record_axis(first(s))) && (leading += 1)
    end
    0 < leading < length(shapes) && (misplaced = true)
    return misplaced, leading > 0 ? 2 : 1
end
