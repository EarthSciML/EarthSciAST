# Whole-array contraction loop nest (ess-array-contraction).
#
# An array-producing aggregate `out[i…] = ⊕_{k…} body(i…, k…)` is compiled to ONE
# body node plus one flat slot vector, and evaluated as a loop NEST: the output
# indices iterate in the section runner below, the contracted ones inside the
# body's `_NK_CONTRACTION_LOOP` nodes.
#
# The tiers this sits above both scale the BUILD with an extent of the equation:
# the affine tier unrolls the reduction into ∏|k…| terms per structural group
# before it can model anything, and the per-cell contraction loop compiles one
# node per output cell. A dense source-receptor contraction — `conc[rcv] =
# Σ_s SR[s,rcv]·E[s]` over tens of thousands of cells each way — is unaffordable
# on both: the unroll is the product of the two extents, the per-cell loop the
# output extent. Here the build sees each extent only as a loop bound and an
# integer slot table, so it is O(1) in the contracted extent and O(cells) MACHINE
# WORDS (not AST nodes) in the output extent.
#
# Split this way — a section over `du` rather than a node kind — for the reason
# scan.jl states for its prefix folds: the access-kernel / affine / codegen /
# oop-merge passes all model per-cell scalar terms, and a section is invisible to
# every one of them. The body is an ordinary compiled `_Node`, so it evaluates
# through the SAME `_eval_node` / `_oop_eval` walkers (and therefore the same
# ForwardDiff path) as every other tree-walk node.

# `refs` are the output loop counters, in output-index order with dimension 1
# varying FASTEST — the order `Iterators.product(range_iters...)` walks, which is
# the order `outs` was filled in. `los`/`steps`/`lens` describe the same ranges as
# plain integers so the counter update is branch-free and allocation-free (a
# `Vector{StepRange}` would re-box a range object per cell). `outs[c]` is the flat
# `du` slot of output cell `c`; `body` folds the contracted indices for the cell
# the counters currently name.
struct _ArrayContraction
    refs::Vector{Base.RefValue{Int}}
    los::Vector{Int}
    steps::Vector{Int}
    lens::Vector{Int}
    outs::Vector{Int}
    body::_Node
end

# Point the output loop counters at cell `c` (1-based, product order). Derived
# from `c` by division rather than carried in a mutable odometer so the runner
# holds no state between cells — the loop is restartable and the struct stays
# read-only at eval time, which is what lets one built evaluator be called from
# several places without an ordering hazard.
@inline function _ac_seek!(ac::_ArrayContraction, c::Int)
    refs = ac.refs
    r = c - 1
    @inbounds for d in eachindex(refs)
        L = ac.lens[d]
        refs[d][] = ac.los[d] + (r % L) * ac.steps[d]
        r ÷= L
    end
    return nothing
end

# Run every whole-array contraction of this build, in place over `du`. Slots are
# disjoint from every other section's (each cell is marked `covered` at build
# time), so the position in the section order is free; it runs behind the kernel
# section, where scan.jl's folds also sit.
@inline function _apply_array_contractions!(du, u, p, t,
        acs::AbstractVector{_ArrayContraction}, ::Type{T}) where {T}
    @inbounds for j in eachindex(acs)
        _apply_array_contraction!(du, u, p, t, acs[j], T)
    end
    return nothing
end

function _apply_array_contraction!(du, u, p, t, ac::_ArrayContraction,
                                   ::Type{T}) where {T}
    outs = ac.outs
    body = ac.body
    @inbounds for c in eachindex(outs)
        _ac_seek!(ac, c)
        du[outs[c]] = _eval_node(body, u, p, t, T)
    end
    return nothing
end

# ---- The `:oop` emitter's form of the same nest ----
# Identical values written in an identical order, so a Float64 `:oop` run stays
# bit-identical to `:inplace`. The only difference is mechanical: writes go
# through the `_oop_store` seam and `du` is rebound, the discipline every other
# oop runner follows (scan.jl's `_scan_lanes_oop` says why).
function _apply_array_contractions_oop(du, u, p, t,
        acs::AbstractVector{_ArrayContraction},
        cache::AbstractVector{T}, fb) where {T}   # `fb::_OopForcing` — oop.jl is
                                                  # included after this file
    for j in eachindex(acs)
        ac = acs[j]
        outs = ac.outs
        body = ac.body
        for c in eachindex(outs)
            _ac_seek!(ac, c)
            du = _oop_store(du, outs[c], _oop_eval(body, u, p, t, cache, fb))
        end
    end
    return du
end
