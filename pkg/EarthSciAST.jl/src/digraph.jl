# The one cycle search over a string-keyed directed graph, shared by the
# reference graph (`detect_cycle`), the index-set dependency check of the
# cadence classifier (through `detect_cycle`), the observed-dependency and
# coupling-cycle checks of `validate` and the recurrence-group check.

"""
    _find_cycle(adj, roots; accept = Returns(true)) -> Union{Nothing, Vector{String}}

A cycle of the directed graph `adj` (vertex => successors, visited in the
order given) as a vertex path `[v, …, v]` whose last element repeats the
first, or `nothing`. An iterative three-colour depth-first search starting
from each of `roots` in turn; a successor with no entry in `adj` has no
successors. A cycle `accept` rejects is passed over and the search goes on.
The search is deterministic: the order of `roots` and of each successor list
decides which cycle is reported, and pinned diagnostics depend on it.
"""
function _find_cycle(
        adj::AbstractDict{String, <:AbstractVector{String}}, roots;
        accept = Returns(true)
    )::Union{Nothing, Vector{String}}
    WHITE, GREY, BLACK = 0, 1, 2
    color = Dict{String, Int}()
    none = String[]
    path = String[]
    cursor = Int[]
    for root in roots
        get(color, root, WHITE) == WHITE || continue
        color[root] = GREY
        push!(path, root)
        push!(cursor, 1)
        while !isempty(path)
            u = path[end]
            succ = get(adj, u, none)
            if cursor[end] > length(succ)
                color[u] = BLACK
                pop!(path)
                pop!(cursor)
                continue
            end
            v = succ[cursor[end]]
            cursor[end] += 1
            c = get(color, v, WHITE)
            if c == GREY
                cycle = vcat(path[findfirst(==(v), path):end], v)
                accept(cycle) && return cycle
            elseif c == WHITE
                color[v] = GREY
                push!(path, v)
                push!(cursor, 1)
            end
        end
    end
    return nothing
end
