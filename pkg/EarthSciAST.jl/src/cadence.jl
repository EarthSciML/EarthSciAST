# Cadence classification (CONFORMANCE_SPEC.md §5.7) on the typed tree: the one
# classifier the build's value-invention guard and the cadence conformance pass
# both use.
#
# Every value is classified by the cadence at which it can change, the total
# order `const ⊏ discrete ⊏ continuous`. A leaf is seeded from its derived role
# (esm-spec §6.3.1, `cadence_seeds`); an operator node is the maximum over its
# children (`cadence_class`), drawn from every expression-bearing `OpExpr` field
# (`foreach_child`). For a gather `index(A, e…)` that maximum classes the index
# expressions independently of the array, which is what lets a stencil split:
# in `index(u, index(nbr, i, k))` the inner topology selection is `const` while
# the outer value load is `continuous` (§5.7.3).

"""
    CadenceClass

The §5.7.1 cadence lattice, ordered `CadenceConst < CadenceDiscrete <
CadenceContinuous`; the class of a node is the `max` over its inputs.
[`cadence_name`](@ref) gives the wire spelling.
"""
@enum CadenceClass::UInt8 CadenceConst CadenceDiscrete CadenceContinuous

"""
    cadence_name(c::CadenceClass) -> String

The wire spelling of a class: `"const"`, `"discrete"` or `"continuous"`.
"""
cadence_name(c::CadenceClass) =
    c === CadenceConst ? "const" : c === CadenceDiscrete ? "discrete" : "continuous"

"""
    cadence_seeds(model::Model; data_sources = nothing, independent_variable = "t") -> Dict{String,CadenceClass}

The cadence seed of every variable of `model` (CONFORMANCE_SPEC §5.7.2), from
the esm-spec §6.3.1 classification rather than a declared type:

| Derived category | Seed |
|---|---|
| `ode_states`, `algebraic_unknowns` | continuous |
| `brownian_parameters` | continuous (resampled every step) |
| `observed_unknowns` | the class of its defining equation's right-hand side, transitively |
| `discrete_parameters` | discrete, or const when its `data` update's source declares no `temporal` block |
| `sampled_parameters`, `constant_parameters` | const |

The independent variable (`independent_variable`, the document's
`domain.independent_variable`) seeds `continuous`. A name absent from the
result (an index-set name, a bound index) is `const` ([`cadence_class`](@ref)
applies that). `data_sources` is the document's `data_sources` table; without it no
source can be resolved and every discrete parameter seeds `discrete`, which
moves no value across the `continuous` boundary.

An observed definition cycle is refused (`observed_cycle`): a cycle has no
class to resolve to.
"""
function cadence_seeds(
        model::Model; data_sources = nothing, independent_variable::AbstractString = "t"
    )::Dict{String, CadenceClass}
    seeds = Dict{String, CadenceClass}(String(independent_variable) => CadenceContinuous)
    for n in solver_unknowns(model)
        seeds[n] = CadenceContinuous
    end
    for n in brownian_parameters(model)
        seeds[n] = CadenceContinuous
    end
    for n in discrete_parameters(model)
        seeds[n] = _data_source_without_temporal(model.variables[n], data_sources) ?
            CadenceConst : CadenceDiscrete
    end
    for n in Iterators.flatten((sampled_parameters(model), constant_parameters(model)))
        seeds[n] = CadenceConst
    end
    defs = observed_definitions(model)
    resolving = String[]
    function resolve(name::String)
        haskey(seeds, name) && return seeds[name]
        def = get(defs, name, nothing)
        def === nothing && return CadenceConst
        if name in resolving
            throw(
                TreeWalkError(
                    ERROR_CODES.OBSERVED_CYCLE,
                    "observed definition cycle through $(repr(name)): " *
                        join(vcat(resolving, name), " -> ")
                )
            )
        end
        push!(resolving, name)
        cls = _cadence_walk(def, n -> haskey(defs, n) ? resolve(n) : get(seeds, n, CadenceConst), nothing)
        pop!(resolving)
        seeds[name] = cls
        return cls
    end
    for name in sort!(collect(keys(defs)))
        resolve(name)
    end
    return seeds
end

# Whether `v` is fed by a `data` update whose source, in `data_sources`, declares
# no `temporal` block: non-time-varying data, read once (CONFORMANCE_SPEC §5.7.2).
function _data_source_without_temporal(v::ModelVariable, data_sources)
    data_sources isa AbstractDict || return false
    i = findfirst(r -> r.kind == "data", _update_rules(v))
    i === nothing && return false
    source = _update_rules(v)[i].source
    source === nothing && return false
    ds = get(data_sources, source, nothing)
    return ds !== nothing && ds.temporal === nothing
end

"""
    cadence_class(expr::ASTExpr, seeds[, memo]) -> CadenceClass

The class of `expr`: a variable's seed (a name `seeds` does not hold is
`const`; [`cadence_seeds`](@ref) seeds the independent variable `continuous`), a literal `const`, an operator node the `max` over its
children. `memo` (an `IdDict{OpExpr,CadenceClass}`) caches operator nodes when
one tree is classified repeatedly.
"""
cadence_class(expr::ASTExpr, seeds::AbstractDict{String, CadenceClass}, memo = nothing) =
    _cadence_walk(expr, n -> get(seeds, n, CadenceConst), memo)

function _cadence_walk(expr::ASTExpr, seed, memo)::CadenceClass
    expr isa VarExpr && return seed(expr.name)
    expr isa OpExpr || return CadenceConst
    if memo !== nothing
        hit = get(memo, expr, nothing)
        hit === nothing || return hit
    end
    cls = CadenceConst
    foreach_child(expr) do c
        cls = max(cls, _cadence_walk(c, seed, memo))
    end
    memo === nothing || (memo[expr] = cls)
    return cls
end

"""
    check_expect_cadence(expr, seeds[, memo]) -> Vector{String}

One message per node under `expr` whose `expect_cadence` annotation disagrees
with its derived class (§5.7.6 guard 3).
"""
function check_expect_cadence(
        expr::ASTExpr, seeds::AbstractDict{String, CadenceClass}, memo = nothing
    )
    problems = String[]
    foreach_subexpr(expr) do node
        (node isa OpExpr && node.expect_cadence !== nothing) || return
        derived = cadence_name(cadence_class(node, seeds, memo))
        derived == node.expect_cadence && return
        push!(
            problems,
            "expect_cadence mismatch on op=$(repr(node.op)): " *
                "declared $(repr(node.expect_cadence)) but derived $(repr(derived))"
        )
    end
    return problems
end

"""
    continuous_relational_nodes(expr, seeds[, memo]) -> Vector{OpExpr}

The relational nodes under `expr` (a `distinct` or `join` operator, or a
`distinct: true` `faq`) that classify `continuous`. State-dependent topology may
not run on the per-step hot path (§5.7 guard 2), so each is a refusal.
"""
function continuous_relational_nodes(
        expr::ASTExpr, seeds::AbstractDict{String, CadenceClass}, memo = nothing
    )
    out = OpExpr[]
    foreach_subexpr(expr) do node
        node isa OpExpr || return
        relational = node.op in ("distinct", "join") ||
            (node.op == "faq" && node.distinct === true)
        relational && cadence_class(node, seeds, memo) === CadenceContinuous &&
            push!(out, node)
    end
    return out
end

"""
    derived_index_set_cycle(models, index_sets) -> Union{Vector{String},Nothing}

A cycle among derived index sets, or `nothing` (§5.7 guard 1). A
`kind: "derived"` set names its producer node by `from_faq`; that node reads the
index sets of its `ranges` (`from`); a cycle in set → producer → set is an
implicit solve, out of scope. `models` is any collection of `Model`s whose
equations hold the producers.
"""
function derived_index_set_cycle(models, index_sets)
    index_sets isa AbstractDict || return nothing
    producer_of = Dict{String, String}()
    for (name, s) in index_sets
        s.kind == "derived" && s.from_faq !== nothing &&
            (producer_of[String(name)] = String(s.from_faq))
    end
    isempty(producer_of) && return nothing
    reads = Dict{String, Set{String}}()
    for m in models, eq in m.equations, side in (eq.lhs, eq.rhs)
        foreach_subexpr(side) do node
            (node isa OpExpr && node.id !== nothing) || return
            r = get!(Set{String}, reads, node.id)
            node.ranges === nothing && return
            for (_, spec) in node.ranges
                from = spec isa IndexSetRef ? spec.from :
                    spec isa AbstractDict ? get(spec, "from", nothing) : nothing
                from === nothing || push!(r, String(from))
            end
        end
    end
    g = ReferenceGraph("cadence-index-set-deps")
    for name in keys(producer_of)
        _ensure_vertex!(g, ReferenceVertex(name, "index_set", name, nothing, nothing, nothing))
    end
    for (name, node_id) in producer_of, next in get(reads, node_id, Set{String}())
        haskey(producer_of, next) && _add_edge!(g, name, next, "range_from")
    end
    return detect_cycle(g)
end
