# Dependency cycles: coupling cycles, observed cycles, strongly connected components.

"""
    _scoped_resolver(members) -> resolve(path, ref)

The document-wide reference resolver of esm-spec §4.9.7. `members` holds every
declared member (variable, species, reaction-system parameter) of every
component at every depth by full scoped name; `resolve(path, ref)` resolves
`ref` as written in the model or subsystem at scoped `path`: its own names,
then a path relative to its own subsystems, then a top-level system path. It
returns the scoped name, or `nothing` when `ref` names no declared member.
"""
function _scoped_resolver(members)
    return function resolve(path::String, ref::String)
        inner = path * "." * ref   # own name, or relative to own subsystems
        haskey(members, inner) && return inner
        return occursin('.', ref) && haskey(members, ref) ? ref : nothing
    end
end

"""
    _scoped_observed_graph(file; toplevel=nothing) -> NamedTuple

The scoped observed definitions of every model and subsystem of `file`, the
inputs of [`validate_coupling_cycles`](@ref) and of the bound circularity check
(esm-spec §6.3.2 rule 3):

- `members`: the scoped member map (`toplevel` when the caller built it);
- `resolve`: [`_scoped_resolver`](@ref) over `members`;
- `defs`: scoped name → defining RHS of each observed unknown, with every
  unknown some model puts under `D(·, t)` removed (it is a state);
- `scope`: scoped name of each observed → the scoped path of its model;
- `self_exempt`, `scoped_groups`: the §4.3.1.1 recurrence candidates and the
  §4.3.1.2 recurrence groups, by scoped name.
"""
function _scoped_observed_graph(file::EsmFile; toplevel = nothing)
    members = toplevel === nothing ? _toplevel_scoped_units(file) : toplevel
    resolve = _scoped_resolver(members)
    defs = Dict{String, ASTExpr}()            # scoped name → defining RHS
    scope = Dict{String, String}()           # scoped name → its model path
    self_exempt = Set{String}()              # §4.3.1.1 recurrence candidates
    scoped_groups = Vector{Vector{String}}()  # §4.3.1.2 recurrence groups, scoped
    states = Set{String}()                   # `D(·, t)` targets, scoped
    function walk(path::String, m::Model)
        local_defs = observed_definitions(m)
        candidates = _recurrence_candidate_names(m, local_defs)
        for (name, rhs) in local_defs
            scoped = path * "." * name
            defs[scoped] = rhs
            scope[scoped] = path
            name in candidates && push!(self_exempt, scoped)
        end
        for g in recurrence_groups(m)
            push!(scoped_groups, sort!([path * "." * n for n in g]))
        end
        for eq in m.equations
            role, name = _lhs_role(eq.lhs)
            role === :derivative || continue
            target = resolve(path, name)
            target === nothing || push!(states, target)
        end
        for (sub, node) in model_subsystems(m)
            walk(path * "." * sub, node)
        end
        return
    end
    if file.models !== nothing
        for (name, model) in file.models
            walk(String(name), model)
        end
    end
    for st in states
        delete!(defs, st)
    end
    return (;
        members, resolve, defs, scope, self_exempt, scoped_groups,
    )
end

"""
    validate_coupling_cycles(file::EsmFile; toplevel=nothing) -> Vector{StructuralError}

Detect a dependency cycle among observeds that crosses a scope boundary
(`circular_dependency`, esm-spec §4.9.7).

This is [`validate_observed_cycles`](@ref)'s graph (§4.9.6) built over the whole
document instead of one model. The nodes are the observed unknowns
([`observed_definitions`](@ref)) of every model and subsystem at every depth,
named by full scoped name (`ModelA.a`, `ModelN.Sub.c`). `V → W` when `W` occurs
free in `V`'s defining RHS (the same walk, [`_observed_dependency_names`](@ref))
and resolves to an observed. A reference resolves with the reference-integrity
walk's precedence (§4.8.4, "A scoped reference carries its target's units"):
`V`'s own model or subsystem's names, then a path relative to its own
subsystems, then a top-level path — the member set is the units check's
document-wide scoped map, passed in as `toplevel` when `validate` has built it.
The scoped name under a `D(·, t)` resolves the same way, and the unknown it
names is a state, not a node, whichever model's equation wrote it.

Only an observed is computed during an evaluation, so only a read inside an
observed's definition orders two computations. A read of a state, a
parameter, a reaction-system species, an algebraic unknown, or an unknown no
equation defines (one a coupling `variable_map` alias supplies, say) is not an
edge. **`coupling` entries are not edges either**: a `variable_map` is a
declared data flow the flattener resolves by aliasing, and mutual physical
coupling is the point of the format (`tests/valid/wildfire_atmosphere_ocean.esm`).

A cycle inside one model or one subsystem is that model's `observed_cycle`,
reported by [`validate_observed_cycles`](@ref), so a back edge closing such a
cycle is skipped and the search continues. The traversal is the pinned one:
roots and successors in lexicographic order of scoped name, the first accepted
back edge closes the reported cycle. ONE `circular_dependency` per document, at
`/models`, with `details.cycle` the scoped names with the entry repeated
(`tests/invalid/circular_coupling.esm`,
`tests/invalid/circular_coupling_subsystem.esm`).

A subsystem still held as an unresolved [`SubsystemRef`](@ref) (a document
loaded from a string without a base path) has no equations to read, so it
contributes no nodes; `load_path` always resolves references, and the check
runs over that resolved tree.
"""
function validate_coupling_cycles(file::EsmFile; toplevel = nothing)::Vector{StructuralError}
    file.models === nothing && return StructuralError[]
    g = _scoped_observed_graph(file; toplevel = toplevel)
    resolve, defs, scope = g.resolve, g.defs, g.scope
    self_exempt, scoped_groups = g.self_exempt, g.scoped_groups

    adj = Dict{String, Vector{String}}()
    for (v, rhs) in defs
        deps = Set{String}()
        for ref in _observed_dependency_names(rhs)
            w = resolve(scope[v], ref)
            w !== nothing && haskey(defs, w) && push!(deps, w)
        end
        v in self_exempt && delete!(deps, v)
        adj[v] = sort!(collect(deps))
    end
    # esm-spec §4.3.1.2: a recurrence group is swept as ONE unit, so here it is
    # one node — its first member — carrying every member's external reads.
    # CONTRACTED rather than stripped of its internal edges: a cycle that leaves
    # the group through another scope and comes back (`a →(group) b → X.c → a`)
    # is a real cycle, and dropping `a → b` would hide it.
    for g in scoped_groups
        members = filter(n -> haskey(adj, n), g)
        isempty(members) && continue
        rep = members[1]
        merged = Set{String}()
        for mem in members
            union!(merged, adj[mem])
            delete!(adj, mem)
        end
        setdiff!(merged, members)
        adj[rep] = sort!(collect(merged))
        for (n, succ) in adj
            any(s -> s in members, succ) || continue
            kept = Set{String}(s for s in succ if !(s in members))
            n == rep || push!(kept, rep)
            adj[n] = sort!(collect(kept))
        end
    end

    # A cycle whose nodes all share one scope is `observed_cycle`, not this.
    crosses_scope(cycle) = any(n -> scope[n] != scope[cycle[1]], cycle)
    cycle = _first_observed_cycle(adj; accept = crosses_scope)
    cycle === nothing && return StructuralError[]
    return [
        StructuralError(
            "/models",
            "Circular dependency among observeds: " * join(cycle, " → "),
            ERROR_CODES.CIRCULAR_DEPENDENCY,
            Dict{String, Any}("cycle" => cycle)
        ),
    ]
end

"""
    validate_observed_cycles(file::EsmFile) -> Vector{StructuralError}

Detect a dependency cycle among ONE model's observed unknowns (esm-spec §4.9.6).

An observed is *defined* by the right-hand side of the equation whose LHS names
it (§6.3.1), so a model's observed definitions induce a dependency graph over
the observed names: `V → W` whenever `W` occurs free in `V`'s defining RHS and
`W` is itself an observed of the same model. A cycle in that graph means no
evaluation order satisfies every definition, and — crucially — that is a
function of the equations ALONE: no shapes, no values, no solver. So it is
decided here, at the same layer as `undefined_variable`, and it is a hard error
on the same grounds as every other provable conflict in §4.9.

Naming the cycle is the point, not a nicety. Before this check `validate()`
accepted `tests/invalid/observed_cycle_array_elementwise.esm` and the tree-walk
build reported `E_TREEWALK_UNBOUND_NAME: 'in_pbl'` — `in_pbl` being a fourth
observed that is declared, defined and referenced perfectly well and merely
reads one member of the cycle. It was simply the name the materialization walk
happened to try first after the cycle stalled (issue #181). A report against an
innocent bystander, from a stage that had already lost the information needed to
say what was actually wrong, is what this replaces.

This is distinct from [`validate_coupling_cycles`](@ref), which finds the same
kind of cycle when it crosses a model or subsystem boundary; that one attaches
at `/models`, this one at `/models/<M>` (a cycle belongs to no single equation,
so it pins at the model exactly as `equation_count_mismatch` does).

Cross-binding pins: `(observed_cycle, /models/<M>)` only — the prose is
deliberately NOT pinned (CONFORMANCE_SPEC §5.19.5); what every binding owes is
that the message NAME the observeds on the cycle.
"""
function validate_observed_cycles(file::EsmFile)::Vector{StructuralError}
    errors = StructuralError[]
    file.models === nothing && return errors
    for model_name in sort!(collect(keys(file.models)))
        _check_observed_cycles!(errors, file.models[model_name], "/models/$model_name")
    end
    return errors
end

function _check_observed_cycles!(
        errors::Vector{StructuralError}, model::Model,
        path::String
    )
    defs = observed_definitions(model)
    if !isempty(defs)
        observed = Set{String}(keys(defs))
        candidates = _recurrence_candidate_names(model, defs)
        groups = recurrence_groups(model)
        adj = Dict{String, Vector{String}}()
        for (name, rhs) in defs
            deps = intersect(_observed_dependency_names(rhs), observed)
            # esm-spec §4.3.1.1 / CONFORMANCE_SPEC §5.19.5: a causal self-read is
            # an ORDERING WITHIN one variable, not a dependency between two, so
            # `V → V` is dropped — for a recurrence CANDIDATE, and only for one.
            name in candidates && delete!(deps, name)
            # esm-spec §4.3.1.2: so is every edge inside a recurrence group
            # CANDIDATE. Within one model the component a group is drawn from
            # is already maximal, so dropping cannot hide a cycle through it.
            for g in groups
                name in g && setdiff!(deps, g)
            end
            adj[name] = sort!(collect(deps))
        end
        cycle = _first_observed_cycle(adj)
        if cycle !== nothing
            push!(
                errors, StructuralError(
                    path,
                    "Observed dependency cycle: " * join(cycle, " -> ") * ". Each of these " *
                        "observed variables is defined in terms of the next, so no evaluation " *
                        "order satisfies every definition (esm-spec §4.9.6). Break the cycle by " *
                        "splitting one observed into a pre-value and a post-value.",
                    ERROR_CODES.OBSERVED_CYCLE,
                    Dict{String, Any}(
                        "cycle" => cycle,
                        "dependency_type" => "observed_definitions"
                    ),
                )
            )
        end
    end

    for (subsys_name, subsys) in model_subsystems(model)
        _check_observed_cycles!(errors, subsys, "$path/subsystems/$subsys_name")
    end
    return errors
end

# Strongly connected components of `adj` (Kosaraju, both passes ITERATIVE for the
# reason `_first_observed_cycle` gives).
function _strongly_connected(adj::Dict{String, Set{String}})::Vector{Set{String}}
    visited = Set{String}()
    finish = String[]
    for root in sort!(collect(keys(adj)))
        root in visited && continue
        push!(visited, root)
        stack = Tuple{String, Vector{String}, Int}[(root, sort!(collect(adj[root])), 1)]
        while !isempty(stack)
            node, succ, i = stack[end]
            if i > length(succ)
                push!(finish, node)
                pop!(stack)
                continue
            end
            stack[end] = (node, succ, i + 1)
            nxt = succ[i]
            (haskey(adj, nxt) && !(nxt in visited)) || continue
            push!(visited, nxt)
            push!(stack, (nxt, sort!(collect(adj[nxt])), 1))
        end
    end
    rev = Dict{String, Vector{String}}()
    for (u, vs) in adj, v in vs
        haskey(adj, v) && push!(get!(rev, v, String[]), u)
    end
    assigned = Set{String}()
    out = Set{String}[]
    for root in Iterators.reverse(finish)
        root in assigned && continue
        push!(assigned, root)
        comp = Set{String}()
        st = String[root]
        while !isempty(st)
            n = pop!(st)
            push!(comp, n)
            for p in get(rev, n, String[])
                p in assigned && continue
                push!(assigned, p)
                push!(st, p)
            end
        end
        push!(out, comp)
    end
    return out
end

# The bare names an observed's defining RHS DEPENDS ON: every `VarExpr` in the
# tree minus every symbol some node in that tree BINDS.
#
# Binder subtraction is what keeps the graph honest. A `faq` over
# `ranges: {i: …}` writes `index(hpbl, i)`, and the `i` is a loop symbol, not a
# reference — so a model that also happens to declare an observed named `i`
# would otherwise gain a manufactured edge into it from every aggregate in the
# document. The binder set is `_bound_index_symbols`, the SAME one the
# `undefined_variable` walk credits into scope (aggregate `output_idx` and
# `ranges` keys, an integral's `int_var`, `index` subscript positions,
# template `bindings` keys) —
# two checks disagreeing about what a binder is, is how a name ends up both
# "undeclared" here and "bound" there.
#
# The subtraction is WHOLE-EXPRESSION rather than scope-threaded, matching Rust
# `collect_bound_symbols` / Go `collectBoundSymbols` / TS `collectIndexSymbols`.
# It is therefore slightly wide — a symbol bound in one subtree is credited
# across the whole RHS — and that direction is the safe one here: it can only
# MISS an edge, never invent one, and inventing one rejects a legal document.
#
# `wrt` is deliberately NOT collected (unlike `_referenced_var_names`): it names
# the coordinate a derivative is taken with respect to, not a value the RHS
# reads, and the differentiand itself is in `args` where the walk already sees
# it. Counting it would let `d(u)/d(x)` fabricate an edge into an observed that
# happens to share a coordinate's name.
function _observed_dependency_names(rhs::ASTExpr)::Set{String}
    free = Set{String}()
    bound = Set{String}()
    foreach_subexpr_once(rhs) do e
        if e isa VarExpr
            push!(free, e.name)
        elseif e isa OpExpr
            for sym in _bound_index_symbols(e)
                push!(bound, sym)
            end
        end
    end
    setdiff!(free, bound)
    return free
end

# The first cycle a DFS over `adj` closes, as the path in traversal order with
# the entry node repeated to close it (`["gamfac", "hpbl", "wscale", "gamfac"]`),
# or `nothing` when the graph has no cycle `accept` takes.
#
# `accept(cycle)` filters back edges: one whose cycle it rejects is skipped and
# the search continues. `validate_coupling_cycles` uses it to pass over a cycle
# that lies in one scope, which is `observed_cycle`'s (esm-spec §4.9.7);
# `validate_observed_cycles` takes every cycle.
#
# WHITE/GREY/BLACK with an explicit path stack. Roots AND successors are visited
# in sorted order so the cycle that gets named — and which of its members is the
# entry — does not depend on `Dict` hashing; §4.9.6 and §4.9.7 require that
# determinism explicitly, because a binding that names a different member on
# each run cannot be pinned. ONE cycle is reported per model: a second is usually the same defect seen from
# another entry point, and the author fixes them one at a time regardless.
#
# ITERATIVE, and that is not a style choice. The depth of this walk is the
# length of the longest observed CHAIN — a property of the document, and
# unbounded — not the expression nesting the schema caps. A recursive `dfs`
# raised `StackOverflowError` ("program state may be corrupted") on an ACYCLIC
# chain of somewhere under 20 000 observeds, turning a document that must
# validate CLEAN into a crash. `cursor[i]` is how far into `adj[path_stack[i]]`
# that frame has got, so resuming a parent after a child finishes picks up
# exactly where it left off.
function _first_observed_cycle(
        adj::Dict{String, Vector{String}}; accept = Returns(true)
    )::Union{Vector{String}, Nothing}
    WHITE, GREY, BLACK = 0, 1, 2
    color = Dict{String, Int}(n => WHITE for n in keys(adj))
    path_stack = String[]
    cursor = Int[]

    for root in sort!(collect(keys(adj)))
        color[root] == WHITE || continue
        color[root] = GREY
        push!(path_stack, root)
        push!(cursor, 1)
        while !isempty(path_stack)
            u = path_stack[end]
            succ = adj[u]
            if cursor[end] > length(succ)
                color[u] = BLACK
                pop!(path_stack)
                pop!(cursor)
                continue
            end
            v = succ[cursor[end]]
            cursor[end] += 1
            if color[v] == GREY
                start = findfirst(==(v), path_stack)
                cycle = vcat(path_stack[start:end], v)
                accept(cycle) && return cycle
            elseif color[v] == WHITE
                color[v] = GREY
                push!(path_stack, v)
                push!(cursor, 1)
            end
        end
    end
    return nothing
end
