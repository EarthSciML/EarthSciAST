# tree_walk/rhs_seams.jl — the right-hand side's value type, parameter read seam and
# Float32 state guard.

# ---- The RHS value type -----------------------------------------------------
#
# The type the RHS computes in, fixed by the three runtime inputs: the state, the
# parameter VALUES, and time. Literals, const arrays and captured forcing buffers
# are `Float64` DATA — never differentiated — so they promote INTO this type rather
# than constraining it (and, for `^`, deliberately do not: see `_eval_node_op`).
#
# Deriving `T` from all three (not just `eltype(u)`) is load-bearing. Under
# ForwardDiff-over-PARAMETERS `u` is a plain `Vector{Float64}` and only the `p`
# values are `Dual`; a scratch buffer sized from `eltype(u)` alone would compile
# fine and then throw `Float64(::Dual)` on the first store.
#
# Every argument's TYPE determines the answer, so inference constant-folds this to
# a `Type{…}` at each `f!` specialization — which is what makes `_cse_buf` a
# static dispatch and keeps the Float64 path byte-for-byte what it was.

@inline _promote_val_types(::Tuple{}) = Bool   # identity for `promote_type`
@inline _promote_val_types(x::Tuple) =
    promote_type(typeof(x[1]), _promote_val_types(Base.tail(x)))

@inline _rhs_value_type(u, p::NamedTuple, t) =
    promote_type(eltype(u), _promote_val_types(values(p)), typeof(t))

# A parameter-free model carries SciMLBase's `nothing` sentinel instead of an empty
# NamedTuple (see `_build_state_layout`); with no parameters there is nothing for it
# to contribute to the value type.
@inline _rhs_value_type(u, ::Nothing, t) = promote_type(eltype(u), typeof(t))

# A parameter VECTOR (`Vector`, `ComponentVector`, …) is homogeneous, so its one
# `eltype` is the whole of its contribution — no per-field `promote_type` fold. The
# same three-way promotion as the NamedTuple method, and for the same reason: under
# ∂/∂p only `eltype(p)` is `Dual` and `u` stays `Float64`.
@inline _rhs_value_type(u, p::AbstractVector, t) =
    promote_type(eltype(u), eltype(p), typeof(t))

# ---- The parameter read seam ------------------------------------------------
#
# A CONTAINER SEAM: the one place the walkers turn "parameter named `sym`" into
# a value, kept as named one-liners so a different `p` container adds a METHOD
# instead of forking every walker. Every `_NK_PARAM` arm in the package goes
# through it: `_eval_node` (compile.jl), `_eval_acc` (access_kernel.jl) and the
# codegen tier (codegen_kernel.jl).
#
# TWO COORDINATES, ONE NODE. A `_NK_PARAM` node carries BOTH the parameter's
# `sym` and its `idx` — its position in the build's already-sorted `param_names`
# (`_build_state_layout`), which is also its position in the `p` NamedTuple. A
# NamedTuple container wants the symbol, a vector container wants the index, and
# handing the seam both is what lets one compiled IR serve either without a
# rebuild. (`idx == 0` marks a node compiled outside the evaluator build — the
# build-time constant folders in helpers.jl, which only ever evaluate against a
# NamedTuple. A vector `p` reaching such a node raises a BoundsError, which is the
# right answer: loud, not a silently wrong parameter.)
#
# THE NAMEDTUPLE METHOD IS `getfield`, UNCHANGED — the production Float64 path
# must stay instruction-for-instruction what it was, and an `@inline` one-liner
# around the same `getfield` compiles to the same code.
@inline _read_param(p::NamedTuple, sym::Symbol, ::Int) = getfield(p, sym)

# The vector container (a plain `Vector`, or a `ComponentVector`, whose integer
# `getindex` reads its data vector), read by position. Not by symbol:
# `getfield(::ComponentVector, ::Symbol)` throws (a ComponentArray's fields are
# `data`/`axes`, not its components).
@inline _read_param(p::AbstractVector, ::Symbol, idx::Int) = _read_param_data(p, idx)

# Read one scalar out of that dense vector. DELIBERATELY NOT `@inbounds`: a short
# or misordered `p` is a caller error with no other detector (a NamedTuple `p`
# catches it by name; a vector `p` has only its length), and a `BoundsError` is
# loud where an out-of-range read is a silently wrong parameter value. The check is
# a predictable compare-and-branch on the Float64 path and off the NamedTuple path
# entirely. (A compiled backend reads parameters out of the container itself and
# never reaches this method — see `_de_param`, ext/reactant_direct/emit.jl.)
@inline _read_param_data(d::AbstractVector, idx::Int) = d[idx]

# ---- Float32 state guard ----------------------------------------------------
#
# `Float32` state is refused LOUDLY at the RHS entry. The walkers are
# eltype-generic, but every literal, const array, and captured forcing buffer is
# `Float64` DATA — so a `Float32` `u` does not buy a Float32 pipeline: it
# promotes to `T == Float64` at the first operator and the whole RHS computes in
# Float64 anyway, plus one convert per state read/store. That is strictly SLOWER
# than handing the same values over as `Float64`, and the silent promotion hides
# it, so rejecting is the kindness. The `eltype` test is static per `f!`/`f`
# specialization, so at Float64 (and under AD `Dual`s) the branch folds away and
# the zero-alloc / instruction-identical property of the hot path is untouched.
@inline function _reject_float32_state(u)
    eltype(u) === Float32 && throw(
        TreeWalkError(
            "E_TREEWALK_FLOAT32_STATE",
            "Float32 state is not supported: the compiled RHS's literals and const " *
                "data are Float64, so Float32 `u` silently promotes and computes in " *
                "Float64 anyway — with an extra convert per state access, i.e. strictly " *
                "slower than Float64 state. Pass the state as Vector{Float64}."
        )
    )
    return nothing
end
