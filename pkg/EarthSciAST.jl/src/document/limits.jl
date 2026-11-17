"""
What the readers bound that the Lean model leaves unbounded.

Port of the Rust binding's `document::limits`. The Lean model's numbers,
exponents and recursion are unbounded. The readers refuse, with `parse_error`,
a document past one of these bounds, rather than read it as something else or
run out of stack:

* **Nesting.** At most [`MAX_NESTING`](@ref) constructs open at once across the
  recursive-descent readers: math sub-expressions (a bracket, a fraction, a
  prefix `-` or `\\lnot`, a `cases` row, a JSON value in an escape node),
  Typst values, YAML blocks and flow collections. Each opens one with
  [`nested`](@ref) while it reads its contents, at the same points as the Rust
  readers, so both refuse the same texts.
* **Depth.** A document read from Markdown or Typst nests at most
  [`MAX_JSON_DEPTH`](@ref) arrays and objects, the depth `serde_json` reads,
  so whatever the readers return can be written as JSON and read back by every
  binding. A left-nested chain (`a - b - c - …`, LaTeX `a / b / c`, Typst
  `a / b / c`) is checked as it grows ([`shallow`](@ref)), since it deepens
  the value without nesting the reader.
* **Numbers.** A decimal beyond the binary64 range (`1.0e400`) has no value a
  JSON document can hold (`DJson.to_value`); a decimal exponent outside
  `Int64` is not a number token (`DNumber.mk_dec`).

The readers stay ports of the Lean functions, which return `nothing` for every
refusal; [`reading`](@ref) collects what a read ran into, so the refusal can
say which bound it hit, and which removed operator its math names.
"""
module DLimits

using ..DJson: JArr, JObj

export MAX_NESTING, MAX_JSON_DEPTH, Findings, reading, nested, shallow, json_depth,
    too_deep!, removed_op!

"""The most constructs a reader holds open at once."""
const MAX_NESTING = 128

"""The deepest nesting of arrays and objects in a document: the most
`serde_json` reads (its recursion limit of 128 counts the outermost value
too)."""
const MAX_JSON_DEPTH = 127

mutable struct State
    depth::Int
    too_deep::Bool
    removed_op::Union{Nothing, String}
end
State() = State(0, false, nothing)

# The state of the read running on this task (Rust keeps it per thread).
const KEY = :EarthSciAST_DocumentFormats_limits

state() = get!(State, task_local_storage(), KEY)::State

"""What one read ran into, besides its result: `too_deep`, a construct nested
past [`MAX_NESTING`](@ref) or a value deeper than [`MAX_JSON_DEPTH`](@ref);
`removed_op`, the first removed operator (esm-spec §4.2) the math parser met
in a call or escape form, or `nothing`."""
struct Findings
    too_deep::Bool
    removed_op::Union{Nothing, String}
end

"""Run one read, `f()`, and return its result with its [`Findings`](@ref)."""
function reading(f)
    tls = task_local_storage()
    saved = get(tls, KEY, nothing)
    st = State()
    tls[KEY] = st
    try
        out = f()
        return out, Findings(st.too_deep, st.removed_op)
    finally
        if saved === nothing
            delete!(tls, KEY)
        else
            tls[KEY] = saved
        end
    end
end

"""Record that the read went past a bound."""
too_deep!() = (state().too_deep = true; nothing)

"""Record a removed operator the math names (the first one is kept)."""
function removed_op!(op::String)
    st = state()
    st.removed_op === nothing && (st.removed_op = op)
    return nothing
end

"""`f(args...)` with one more construct open: `nothing`, recorded as
[`too_deep!`](@ref), when [`MAX_NESTING`](@ref) are open already (Rust
`Nest::enter`, held for the rest of the function)."""
@inline function nested(f, args...)
    st = state()
    if st.depth >= MAX_NESTING
        st.too_deep = true
        return nothing
    end
    st.depth += 1
    out = f(args...)
    # Every call runs within `reading` (a read, or a print's trial reads), and
    # a refusal never throws; a read that throws discards this state in
    # `reading`.
    st.depth -= 1
    return out
end

"""The nesting depth of arrays and objects in a value (`0` for a scalar),
found without recursion."""
function json_depth(j)
    mx = 0
    stack = Tuple{Any, Int}[(j, 0)]
    while !isempty(stack)
        v, d = pop!(stack)
        if v isa JArr
            mx = max(mx, d + 1)
            for x in v.xs
                push!(stack, (x, d + 1))
            end
        elseif v isa JObj
            mx = max(mx, d + 1)
            for kv in v.kvs
                push!(stack, (kv.second, d + 1))
            end
        end
    end
    return mx
end

"""`j` when it is no deeper than [`MAX_JSON_DEPTH`](@ref); otherwise
`nothing`, recorded as [`too_deep!`](@ref)."""
function shallow(j)
    json_depth(j) <= MAX_JSON_DEPTH && return j
    too_deep!()
    return nothing
end

end # module DLimits
