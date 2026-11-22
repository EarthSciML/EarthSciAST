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
_scoped_resolver(members) = (path::String, ref::String) -> _resolve_scoped(members, path, ref)

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
    visit = function (m::Model, _, _, path::String)
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
        return
    end
    if file.models !== nothing
        for (name, model) in file.models
            _foreach_component(visit, model, _pointer("", "models", name); scope = name)
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
    return _report!(
        StructuralError[], ERROR_CODES.CIRCULAR_DEPENDENCY, "/models",
        "Circular dependency among observeds: " * join(cycle, " → "),
        Dict{String, Any}("cycle" => cycle)
    )
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

The message names the observeds on the cycle, not a bystander that merely
reads one of them (`tests/invalid/observed_cycle_array_elementwise.esm`).

This is distinct from [`validate_coupling_cycles`](@ref), which finds the same
kind of cycle when it crosses a model or subsystem boundary; that one attaches
at `/models`, this one at `/models/<M>` (a cycle belongs to no single equation,
so it pins at the model exactly as `equation_count_mismatch` does).

Cross-binding pins: `(observed_cycle, /models/<M>)` only — the prose is
deliberately NOT pinned (CONFORMANCE_SPEC §5.19.5); what every binding owes is
that the message NAME the observeds on the cycle.
"""
function validate_observed_cycles(file::EsmFile; views = nothing, tables = nothing)::Vector{StructuralError}
    errors = StructuralError[]
    file.models === nothing && return errors
    for model_name in sort!(collect(keys(file.models)))
        # The validation view and template table, as
        # `validate_recurrence_semantics` reads them, so the two agree on which
        # self-reads are recurrence candidates: each reference carries the names
        # its body reads, and is read through its frame where the check looks
        # at how a name is read.
        model = _units_view(file, model_name, file.models[model_name], views)
        templates = _tpl_component_table(file, "models", model_name, tables)
        _foreach_component(model, _pointer("", "models", model_name)) do m, p, _
            _check_observed_cycles!(errors, m, p; templates)
        end
    end
    return errors
end

# The observed dependency cycle of one component (not its subsystems).
function _check_observed_cycles!(
        errors::Vector{StructuralError}, model::Model,
        path::String; templates = nothing
    )
    defs = observed_definitions(model)
    if !isempty(defs)
        observed = Set{String}(keys(defs))
        candidates = _recurrence_candidate_names(model, defs; templates)
        groups = recurrence_groups(model; templates)
        adj = Dict{String, Vector{String}}()
        for (name, rhs) in defs
            deps = intersect(_observed_dependency_names(rhs; templates), observed)
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
            _report!(
                errors, ERROR_CODES.OBSERVED_CYCLE,
                path,
                "Observed dependency cycle: " * join(cycle, " -> ") * ". Each of these " *
                    "observed variables is defined in terms of the next, so no evaluation " *
                    "order satisfies every definition (esm-spec §4.9.6). Break the cycle by " *
                    "splitting one observed into a pre-value and a post-value.",
                Dict{String, Any}(
                    "cycle" => cycle,
                    "dependency_type" => "observed_definitions"
                )
            )
        end
    end
    return errors
end

# Strongly connected components of `adj` (Kosaraju, both passes ITERATIVE: the
# depth is the length of the longest observed chain, which is unbounded).
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
#
# With the model's template table `templates`, a template reference reads the
# bindings its expansion reads (`_tpl_reads_binding`: the names its body reads
# from the caller, carried by the validation view, and each parameter the body
# uses as a value), and its binding keys bind none of the caller's names; the
# body's own binders, which the expansion puts around a parameter's binding,
# are subtracted like any other (`_tpl_scope_binders`).
function _observed_dependency_names(rhs::ASTExpr; templates = nothing)::Set{String}
    free = Set{String}()
    bound = Set{String}()
    seen = Base.IdSet{OpExpr}()
    function walk(e)
        if e isa VarExpr
            push!(free, e.name)
            return
        end
        e isa OpExpr || return
        e in seen && return
        push!(seen, e)
        if templates !== nothing && _tpl_is_call(e)
            foreach(walk, e.args)
            b = e.bindings
            b === nothing && return
            for k in sort!(collect(keys(b)))
                _tpl_reads_binding(templates, e, k) || continue
                # A declared parameter's binding is substituted into the body,
                # where the body's own binders may capture its names.
                if !startswith(k, _TPL_FREE) && !startswith(k, _TPL_OUT)
                    try
                        union!(bound, _tpl_scope_binders(templates, e.name))
                    catch err
                        err isa ExpressionTemplateError || rethrow()
                    end
                end
                walk(b[k])
            end
            return
        end
        for sym in _bound_index_symbols(e)
            push!(bound, sym)
        end
        foreach_child(walk, e)
        return
    end
    walk(rhs)
    setdiff!(free, bound)
    return free
end

# The first cycle among the observed definitions `adj`, by `_find_cycle`
# (digraph.jl) with the roots in sorted order and each successor list as given
# (callers sort them), so the cycle that gets named, and which member is its
# entry, does not depend on `Dict` hashing (esm-spec §4.9.6, §4.9.7). `accept`
# passes over a cycle: `validate_coupling_cycles` skips one that lies in one
# scope, which is `observed_cycle`'s. ONE cycle is reported per model.
_first_observed_cycle(adj::Dict{String, Vector{String}}; accept = Returns(true)) =
    _find_cycle(adj, sort!(collect(keys(adj))); accept)
