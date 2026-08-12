# Micro-experiment: WHICH property of the node struct makes Enzyme's type analysis
# reject a recursive tree walk, and does any cheaper-than-a-rewrite variant fix it?
#
# Each variant is a self-contained tree walker over the same tiny expression
# (a sum of products of state reads and literals). Only the NODE REPRESENTATION
# differs. Run one variant per process (Enzyme caches compiled adjoints, and the
# type-analysis failure is a compile-time event):
#
#   julia --project=. micro_variants.jl <variant> [relaxed]
#
# Variants:
#   any        payload::Any                                  (mirrors `_Node` today)
#   union      payload::Union{Nothing,Vector{Float64},Base.RefValue{Int}}
#   barrier    payload::Any, but every payload arm behind a @noinline function and
#              the hot arms reading only concrete fields
#   concrete   no payload field at all                       (the "payload-free IR")
#   anyunused  payload::Any present in the struct but NEVER LOADED by the walk
#              (this is the "route around the Any payload" the oop.jl note says
#               was tried and does not work)
#   inactive   payload::Any, arms behind functions declared
#              `EnzymeRules.inactive` — the SUPPORTED form of the barrier, which
#              sets the `enzyme_ta_norecur` LLVM attribute so type analysis does
#              not descend into the call at all

using Enzyme, ForwardDiff
using Enzyme: EnzymeRules

variant = length(ARGS) >= 1 ? ARGS[1] : "any"
if length(ARGS) >= 2 && ARGS[2] == "relaxed"
    Enzyme.API.strictAliasing!(false)
end

const K_LIT   = UInt8(1)
const K_STATE = UInt8(2)
const K_ADD   = UInt8(3)
const K_MUL   = UInt8(4)
const K_GATHER= UInt8(5)   # payload::Vector{Float64}, idx
const K_LOOP  = UInt8(6)   # payload::Base.RefValue{Int}

# ---------------- variant: any / anyunused / barrier ----------------
struct NodeAny
    kind::UInt8
    literal::Float64
    idx::Int
    payload::Any
    children::Vector{NodeAny}
end

function eval_any(n::NodeAny, u, ::Type{T})::T where {T}
    k = n.kind
    if k === K_LIT
        return convert(T, n.literal)
    elseif k === K_STATE
        return convert(T, @inbounds u[n.idx])
    elseif k === K_GATHER
        return convert(T, @inbounds (n.payload::Vector{Float64})[n.idx])
    elseif k === K_LOOP
        return convert(T, (n.payload::Base.RefValue{Int})[])
    elseif k === K_ADD
        s = zero(T)
        for c in n.children; s += eval_any(c, u, T); end
        return s
    else
        s = one(T)
        for c in n.children; s *= eval_any(c, u, T); end
        return s
    end
end

# `anyunused`: the struct still has `payload::Any`, but the walk never loads it.
function eval_anyunused(n::NodeAny, u, ::Type{T})::T where {T}
    k = n.kind
    if k === K_LIT
        return convert(T, n.literal)
    elseif k === K_STATE
        return convert(T, @inbounds u[n.idx])
    elseif k === K_ADD
        s = zero(T)
        for c in n.children; s += eval_anyunused(c, u, T); end
        return s
    else
        s = one(T)
        for c in n.children; s *= eval_anyunused(c, u, T); end
        return s
    end
end

# `barrier`: payload arms behind a @noinline boundary.
@noinline _pay_gather(n::NodeAny, ::Type{T}) where {T} =
    convert(T, @inbounds (n.payload::Vector{Float64})[n.idx])
@noinline _pay_loop(n::NodeAny, ::Type{T}) where {T} =
    convert(T, (n.payload::Base.RefValue{Int})[])

function eval_barrier(n::NodeAny, u, ::Type{T})::T where {T}
    k = n.kind
    if k === K_LIT
        return convert(T, n.literal)
    elseif k === K_STATE
        return convert(T, @inbounds u[n.idx])
    elseif k === K_GATHER
        return _pay_gather(n, T)
    elseif k === K_LOOP
        return _pay_loop(n, T)
    elseif k === K_ADD
        s = zero(T)
        for c in n.children; s += eval_barrier(c, u, T); end
        return s
    else
        s = one(T)
        for c in n.children; s *= eval_barrier(c, u, T); end
        return s
    end
end

# `inactive`: same barrier, but DECLARED rather than hoped for. `EnzymeRules.inactive`
# attaches `enzyme_ta_norecur` to the LLVM function (Enzyme compiler.jl ~1035), which
# makes type analysis return at the call site instead of descending (upstream
# TypeAnalysis.cpp). It also blocks inlining, so the barrier survives to LLVM.
# SOUNDNESS NOTE: `inactive` asserts the return value carries no derivative. True for
# a forcing-buffer read or a loop counter; NOT true in general.
_inact_gather(n::NodeAny, ::Type{T}) where {T} =
    convert(T, @inbounds (n.payload::Vector{Float64})[n.idx])
_inact_loop(n::NodeAny, ::Type{T}) where {T} =
    convert(T, (n.payload::Base.RefValue{Int})[])
EnzymeRules.inactive(::typeof(_inact_gather), args...) = nothing
EnzymeRules.inactive(::typeof(_inact_loop), args...) = nothing

function eval_inactive(n::NodeAny, u, ::Type{T})::T where {T}
    k = n.kind
    if k === K_LIT
        return convert(T, n.literal)
    elseif k === K_STATE
        return convert(T, @inbounds u[n.idx])
    elseif k === K_GATHER
        return _inact_gather(n, T)
    elseif k === K_LOOP
        return _inact_loop(n, T)
    elseif k === K_ADD
        s = zero(T)
        for c in n.children; s += eval_inactive(c, u, T); end
        return s
    else
        s = one(T)
        for c in n.children; s *= eval_inactive(c, u, T); end
        return s
    end
end

# ---------------- variant: union ----------------
const Payload = Union{Nothing,Vector{Float64},Base.RefValue{Int}}
struct NodeUnion
    kind::UInt8
    literal::Float64
    idx::Int
    payload::Payload
    children::Vector{NodeUnion}
end

function eval_union(n::NodeUnion, u, ::Type{T})::T where {T}
    k = n.kind
    if k === K_LIT
        return convert(T, n.literal)
    elseif k === K_STATE
        return convert(T, @inbounds u[n.idx])
    elseif k === K_GATHER
        return convert(T, @inbounds (n.payload::Vector{Float64})[n.idx])
    elseif k === K_LOOP
        return convert(T, (n.payload::Base.RefValue{Int})[])
    elseif k === K_ADD
        s = zero(T)
        for c in n.children; s += eval_union(c, u, T); end
        return s
    else
        s = one(T)
        for c in n.children; s *= eval_union(c, u, T); end
        return s
    end
end

# ---------------- variant: concrete (payload-free) ----------------
# The payload-carrying kinds get their own SIDE TABLES, indexed by `idx`; the node
# itself is all-isbits except its children vector.
struct NodeC
    kind::UInt8
    literal::Float64
    idx::Int
    children::Vector{NodeC}
end
struct CTables
    gathers::Vector{Vector{Float64}}
    loops::Vector{Base.RefValue{Int}}
end

function eval_concrete(n::NodeC, u, tb::CTables, ::Type{T})::T where {T}
    k = n.kind
    if k === K_LIT
        return convert(T, n.literal)
    elseif k === K_STATE
        return convert(T, @inbounds u[n.idx])
    elseif k === K_GATHER
        return convert(T, @inbounds tb.gathers[1][n.idx])
    elseif k === K_LOOP
        return convert(T, (@inbounds tb.loops[1])[])
    elseif k === K_ADD
        s = zero(T)
        for c in n.children; s += eval_concrete(c, u, tb, T); end
        return s
    else
        s = one(T)
        for c in n.children; s *= eval_concrete(c, u, tb, T); end
        return s
    end
end

# ---------------- the same tiny expression in each representation --------------
const GATHER_DATA = [1.5, 2.5, 3.5]
const LOOP_REF = Ref(2)

# sum_i ( u[i] * u[i] ) + 3.0 * u[1] + gather[2] * u[2] + loopvar * u[3]
mk(::Type{NodeAny}) = NodeAny(K_ADD, 0.0, 0, nothing, [
    NodeAny(K_MUL, 0.0, 0, nothing, [NodeAny(K_STATE, 0.0, 1, nothing, NodeAny[]),
                                     NodeAny(K_STATE, 0.0, 1, nothing, NodeAny[])]),
    NodeAny(K_MUL, 0.0, 0, nothing, [NodeAny(K_LIT, 3.0, 0, nothing, NodeAny[]),
                                     NodeAny(K_STATE, 0.0, 1, nothing, NodeAny[])]),
    NodeAny(K_MUL, 0.0, 0, nothing, [NodeAny(K_GATHER, 0.0, 2, GATHER_DATA, NodeAny[]),
                                     NodeAny(K_STATE, 0.0, 2, nothing, NodeAny[])]),
    NodeAny(K_MUL, 0.0, 0, nothing, [NodeAny(K_LOOP, 0.0, 0, LOOP_REF, NodeAny[]),
                                     NodeAny(K_STATE, 0.0, 3, nothing, NodeAny[])]),
])
# `anyunused` must not contain payload kinds (the walk has no arm for them), but the
# STRUCT still declares `payload::Any` and the tree still stores non-nothing in it.
mk_unused() = NodeAny(K_ADD, 0.0, 0, GATHER_DATA, [
    NodeAny(K_MUL, 0.0, 0, LOOP_REF, [NodeAny(K_STATE, 0.0, 1, GATHER_DATA, NodeAny[]),
                                      NodeAny(K_STATE, 0.0, 1, nothing, NodeAny[])]),
    NodeAny(K_MUL, 0.0, 0, nothing, [NodeAny(K_LIT, 3.0, 0, GATHER_DATA, NodeAny[]),
                                     NodeAny(K_STATE, 0.0, 1, nothing, NodeAny[])]),
    NodeAny(K_MUL, 0.0, 0, nothing, [NodeAny(K_LIT, 2.5, 0, nothing, NodeAny[]),
                                     NodeAny(K_STATE, 0.0, 2, nothing, NodeAny[])]),
    NodeAny(K_MUL, 0.0, 0, nothing, [NodeAny(K_LIT, 2.0, 0, LOOP_REF, NodeAny[]),
                                     NodeAny(K_STATE, 0.0, 3, nothing, NodeAny[])]),
])
mk(::Type{NodeUnion}) = NodeUnion(K_ADD, 0.0, 0, nothing, [
    NodeUnion(K_MUL, 0.0, 0, nothing, [NodeUnion(K_STATE, 0.0, 1, nothing, NodeUnion[]),
                                       NodeUnion(K_STATE, 0.0, 1, nothing, NodeUnion[])]),
    NodeUnion(K_MUL, 0.0, 0, nothing, [NodeUnion(K_LIT, 3.0, 0, nothing, NodeUnion[]),
                                       NodeUnion(K_STATE, 0.0, 1, nothing, NodeUnion[])]),
    NodeUnion(K_MUL, 0.0, 0, nothing, [NodeUnion(K_GATHER, 0.0, 2, GATHER_DATA, NodeUnion[]),
                                       NodeUnion(K_STATE, 0.0, 2, nothing, NodeUnion[])]),
    NodeUnion(K_MUL, 0.0, 0, nothing, [NodeUnion(K_LOOP, 0.0, 0, LOOP_REF, NodeUnion[]),
                                       NodeUnion(K_STATE, 0.0, 3, nothing, NodeUnion[])]),
])
mk(::Type{NodeC}) = NodeC(K_ADD, 0.0, 0, [
    NodeC(K_MUL, 0.0, 0, [NodeC(K_STATE, 0.0, 1, NodeC[]), NodeC(K_STATE, 0.0, 1, NodeC[])]),
    NodeC(K_MUL, 0.0, 0, [NodeC(K_LIT, 3.0, 0, NodeC[]), NodeC(K_STATE, 0.0, 1, NodeC[])]),
    NodeC(K_MUL, 0.0, 0, [NodeC(K_GATHER, 0.0, 2, NodeC[]), NodeC(K_STATE, 0.0, 2, NodeC[])]),
    NodeC(K_MUL, 0.0, 0, [NodeC(K_LOOP, 0.0, 0, NodeC[]), NodeC(K_STATE, 0.0, 3, NodeC[])]),
])

const TABLES = CTables([GATHER_DATA], [LOOP_REF])

lossfn = if variant == "any"
    let n = mk(NodeAny); u -> eval_any(n, u, eltype(u)); end
elseif variant == "anyunused"
    let n = mk_unused(); u -> eval_anyunused(n, u, eltype(u)); end
elseif variant == "inactive"
    let n = mk(NodeAny); u -> eval_inactive(n, u, eltype(u)); end
elseif variant == "barrier"
    let n = mk(NodeAny); u -> eval_barrier(n, u, eltype(u)); end
elseif variant == "union"
    let n = mk(NodeUnion); u -> eval_union(n, u, eltype(u)); end
elseif variant == "concrete"
    let n = mk(NodeC); u -> eval_concrete(n, u, TABLES, eltype(u)); end
else
    error("unknown variant $variant")
end

u = [0.7, -0.4, 1.1]
g_fd = ForwardDiff.gradient(lossfn, u)
println("variant=$variant  value=", lossfn(u), "  fd=", g_fd)

du = zero(u)
try
    Enzyme.autodiff(Enzyme.Reverse, Enzyme.Const(lossfn), Enzyme.Active,
                    Enzyme.Duplicated(u, du))
    println("RESULT $variant: OK   enzyme=", du, "  maxdiff=", maximum(abs.(du .- g_fd)))
catch e
    io = IOBuffer(); showerror(io, e); s = String(take!(io))
    println("RESULT $variant: FAIL ", typeof(e))
    println(first(s, 2500))
end
