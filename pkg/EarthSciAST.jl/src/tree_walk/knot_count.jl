# ========================================================================
# The comparison count over a whole lane: `Σ_k [cmp(knots[k], q)]`
# ========================================================================
#
# The count the closed-AST templates' comparison folds lower to under a
# compiled backend (ext/reactant_direct/closed.jl). The default lowering below
# is a branch-free select ladder — right for host and ForwardDiff, a handful of
# fused broadcasts — and a backend replaces it by specializing `_knot_count` on
# its own query type (ext/reactant_knot_count.jl).
#
# What a backend method must honour, bit for bit: the terms are 0.0/1.0 and
# n ≪ 2^53, so the sum is EXACT in any association order, and so is any other
# route to the same integer. A backend owes the ladder's VALUE, not its shape,
# for every query including NaN (which fails every compare and contributes 0.0).
@inline function _knot_count(knots::AbstractVector{Float64}, q, cmp::F) where {F}
    n = length(knots)
    cnt = ifelse.(cmp.(@inbounds(knots[1]), q), 1.0, 0.0)
    for k in 2:n
        cnt = cnt .+ ifelse.(cmp.(@inbounds(knots[k]), q), 1.0, 0.0)
    end
    return cnt
end
