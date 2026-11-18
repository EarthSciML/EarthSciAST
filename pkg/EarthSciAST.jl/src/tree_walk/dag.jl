# tree_walk/dag.jl — unique-node walks over a shared DAG.

# Saturating add for path-multiplicity tallies: a structurally-shared DAG can
# have more paths than an `Int` holds, and the consumers only ever compare
# against small thresholds.
_sat_add(a::Int, b::Int) = a > typemax(Int) - b ? typemax(Int) : a + b

# ---- Unique-node walks over a shared DAG (ESS-0hh) -----------------------------
# The structural passes that count repeats — the scalar CSE count (`_cse_count!`),
# the access-kernel value numbering (`_build_acc_cse`, access_kernel.jl) and the
# emitters' repeated sub-trees (`_cg_share_groups`, array_contraction.jl) — walk
# trees whose sub-trees are shared by reference, so they visit each UNIQUE node
# once and count paths by propagating multiplicities, never by recursing per path.

# The unique nodes under `root` in postorder (children before parents; a node is
# marked on entry, so one reached on several paths is visited once) and each
# one's dense position in that order; the root is last. `kids(n)` is the
# positional child list of `n` (empty where the walk stops), `keep(c)` whether a
# child is a node of the walk at all.
function _dag_postorder(root::N, kids::K, keep::F) where {N, K, F}
    order, pos, _ = _dag_postorder_until(root, kids, keep, _dag_never)
    return order, pos
end
# `_dag_postorder` that gives up at the first unique node `stop(n)` holds for
# (asked once per unique node, on entry, the root included): `stopped` is then
# `true` and the order and positions are partial.
function _dag_postorder_until(root::N, kids::K, keep::F, stop::S) where {N, K, F, S}
    order = N[]
    pos = _identity_map(N, Int)
    function walk(n::N)::Bool
        haskey(pos, n) && return false
        stop(n) && return true
        pos[n] = 0
        for c in kids(n)
            keep(c) && walk(c) && return true
        end
        push!(order, n)
        pos[n] = length(order)
        return false
    end
    stopped = walk(root)
    return order, pos, stopped
end

# Path multiplicities over `_dag_postorder`'s `order`: per position, how many
# paths from the root reach the node (`total`), and how many of those pass no
# conditionally evaluated operand (`uncond`; `cond(n, j)` says whether operand
# `j` of `n` is one). One reverse-postorder pass, parents before children, with
# saturating additions. On a pure tree these are the occurrence counts.
function _dag_path_counts(
        order::Vector, pos, kids::K, keep::F, cond::C
    ) where {K, F, C}
    P = length(order)
    total = zeros(Int, P)
    uncond = zeros(Int, P)
    P == 0 && return total, uncond
    total[P] = 1
    uncond[P] = 1
    for i in P:-1:1
        n = order[i]
        t, u = total[i], uncond[i]
        for (j, c) in enumerate(kids(n))
            keep(c) || continue
            pc = pos[c]
            total[pc] = _sat_add(total[pc], t)
            cond(n, j) || (uncond[pc] = _sat_add(uncond[pc], u))
        end
    end
    return total, uncond
end
_dag_children(n) = n.children
_dag_every(_) = true
_dag_never(_) = false
_dag_strict(_, _) = false
