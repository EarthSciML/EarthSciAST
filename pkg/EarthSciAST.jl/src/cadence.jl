"""
    EarthSciAST.Cadence

The raw-JSON **cadence classifier** backing the cross-binding conformance
contract of `CONFORMANCE_SPEC.md` §5.7 (RFC `semiring-faq-unified-ir` §6.1,
bead `ess-my4.3.7`) — the EarthSciAST analogue of ModelingToolkit's
`structural_simplify` / observed-variable elimination, generalised from two
phases to three.

Every value is classified by the **cadence** at which it can change, forming the
total order `const ⊏ discrete ⊏ continuous`:

| Class | Changes | Phase | Leaf seed |
|---|---|---|---|
| `const` | never | folded artifact | `parameter` / literal / index-set name / bound index |
| `discrete` | only at discrete events | per-event handler | `discrete` variable |
| `continuous` | every step | hot per-step `_Node` tree | `state` variable, the independent variable `t` |

The pass is a **pure function of the data-dependency DAG**: `class(node) = max`
over its inputs' classes, derived bottom-up, never declared.

# CONFORMANCE-ONLY: why raw JSON, not the typed IR

This module walks the **raw parsed JSON** of a model (`AbstractDict` /
`JSON3.Object` → native dicts) because the conformance fixtures carry the
`expect_cadence` assertion — an annotation the typed IR deliberately does not
parse. It is consumed ONLY by the conformance surface: the cadence adapter
(`scripts/cadence_adapter.jl`, which also hosts the §5.7 `partition_model`
pass and the CONST-fold kernels) and `test/cadence_test.jl`. The PRODUCTION
build path no longer touches it: the value-invention front door
(`value_invention.jl`) derives the §5.7 guard-2 classification directly on the
typed `OpExpr` IR, which now preserves every wire field
(`OPEXPR_FIELD_TABLE`, types.jl). `reference_graph.jl` walks raw JSON for the
same conformance reason.

# The gather rule (the design's load-bearing rule)

For a gather `index(A, e₁…eₖ)` the index expressions are classified
**independently of the array**:

    class(index(A, e…)) = max(class(A), class(e₁), …, class(eₖ))

This is just `max` over a node's children, so it needs no special case — but it
is what lets a stencil *split* across phases: in `index(u, index(nbr,i,k))` the
inner topology selection `index(nbr,i,k)` is `const` while the outer value load
`index(u, .)` is `continuous`.

The guards ([`assert_no_continuous_relational`](@ref),
[`assert_acyclic_index_sets`](@ref), and the [`check_expect_cadence!`](@ref)
assertion) are *checked*, not hoped for. The index-set acyclicity guard routes
through the shared three-color DFS (`detect_cycle`, reference_graph.jl) over a
materialised set→set graph instead of carrying its own cycle detector.
"""
module Cadence

import JSON3
using ..EarthSciAST: ReferenceGraph, ReferenceVertex, detect_cycle,
    _ensure_vertex!, _add_edge!

export CadenceError, classify,
    assert_no_continuous_relational, assert_acyclic_index_sets,
    load_model_json

# The cadence lattice (§5.7.1): const ⊏ discrete ⊏ continuous. `class(node) =
# max over inputs` is the lattice join over these ranks.
const CLASS_RANK = Dict("const" => 0, "discrete" => 1, "continuous" => 2)
const RANK_CLASS = Dict(0 => "const", 1 => "discrete", 2 => "continuous")

# The relational / value-invention ops that may not run on the hot path (§5.7
# guard 2): one classifying `continuous` is a hard error. Includes the arg-witness
# reducers (`argmin`/`argmax`, §5.7 rule 6) — a state-dependent assignment is
# out of scope for v1, exactly like a state-dependent `distinct`.
const RELATIONAL_OPS = Set(["distinct", "join", "skolem", "rank", "argmin", "argmax"])

"""
    CadenceError(msg)

A cadence-partition contract violation in a fixture or producer output —
a wrong `expect_cadence`, a `continuous` relational node (§5.7 guard 2), a
`from_faq` cycle (§5.7 guard 1), a float topology key, or an unknown fold.
"""
struct CadenceError <: Exception
    msg::String
end
Base.showerror(io::IO, e::CadenceError) = print(io, "CadenceError: ", e.msg)

# ── Raw-JSON access ─────────────────────────────────────────────────────────
# Convert JSON3 structures to native `Dict{String,Any}` / `Vector{Any}` so node
# access is uniform string-keyed `get`/`haskey` — a direct mirror of the
# reference classifier (`scripts/run-cadence-conformance.py`). Conformance
# fixtures are small, so the up-front copy is cheap; the production build path
# never runs this conversion (it parses straight into the typed IR).

to_native(x::JSON3.Object) = Dict{String,Any}(String(k) => to_native(v) for (k, v) in pairs(x))
to_native(x::JSON3.Array) = Any[to_native(v) for v in x]
to_native(x::AbstractDict) = Dict{String,Any}(String(k) => to_native(v) for (k, v) in x)
to_native(x::AbstractVector) = Any[to_native(v) for v in x]
to_native(x) = x

"""
    load_model_json(path, model_name) -> Dict{String,Any}

Load one model from an `.esm` document as a native JSON dict (no typed coercion:
this classifier needs the `expect_cadence` field the typed IR does not parse).
"""
function load_model_json(path::AbstractString, model_name::AbstractString)
    doc = to_native(JSON3.read(read(path, String)))
    models = get(doc, "models", Dict{String,Any}())
    haskey(models, model_name) ||
        throw(CadenceError("$(path): model $(repr(model_name)) not found"))
    model = models[model_name]
    # Attach the document's top-level `data_loaders` so the loader-seeded cadence
    # refinement (§5.7.2) can resolve a `discrete` variable's `data_ingest`
    # source loader and decide `discrete` (temporal) vs `const` (no temporal).
    loaders = get(doc, "data_loaders", nothing)
    if isa(loaders, AbstractDict) && !haskey(model, "data_loaders")
        model = merge(model, Dict{String,Any}("data_loaders" => loaders))
    end
    return model
end

# ── Classification (§5.7.2–5.7.3) ───────────────────────────────────────────

"""The lattice join (max) over cadence classes — the §5.7 propagation rule."""
_join(classes) = isempty(classes) ? "const" :
                 RANK_CLASS[maximum(CLASS_RANK[c] for c in classes)]

"""
    seed_leaf(leaf, model) -> String

Seed a leaf's cadence from its declared role (§5.7.2 leaf-seed table): `state` →
`continuous`, `parameter`/literal → `const`, `discrete` → `discrete`. The
independent variable `t` is `continuous` (an explicit continuous-`t` forcing is
not piecewise-constant between events). Index-set names, bound index symbols,
numeric literals, and relation-name tags are all `const`.
"""
function seed_leaf(leaf, model)
    # numeric literal (Bool is excluded, mirroring the reference's `not bool`)
    if (isa(leaf, Integer) && !isa(leaf, Bool)) || isa(leaf, AbstractFloat)
        return "const"
    end
    isa(leaf, AbstractString) || throw(CadenceError("unexpected leaf $(repr(leaf))"))
    leaf == "t" && return "continuous"
    variables = get(model, "variables", Dict{String,Any}())
    if haskey(variables, leaf)
        kind = get(variables[leaf], "type", nothing)
        kind == "state" && return "continuous"
        # Loader-seeded cadence refinement (§5.7.2): a discrete variable fed by a
        # `data_ingest` refresh whose source loader has no `temporal` block is
        # non-time-varying and seeds `const` (folds at bind). With `temporal` (or
        # any other trigger / unresolvable source) it keeps the `discrete` seed.
        kind == "discrete" &&
            return _loader_without_temporal(variables[leaf], model) ? "const" : "discrete"
        kind == "brownian" && return "continuous"
        (kind == "parameter" || kind == "observed") && return "const"
        throw(CadenceError("leaf $(repr(leaf)): unknown variable kind $(repr(kind))"))
    end
    # index-set name, bound index symbol (i, k, e, f, le), relation tag
    # ("edge"), or numeric-string literal — all `const`.
    return "const"
end

"""
    _loader_without_temporal(var, model) -> Bool

True iff `var` is a discrete variable whose `data_ingest` refresh names a
DataLoader — found in the document's top-level `data_loaders`, attached to the
model by [`load_model_json`](@ref) — that declares no `temporal` block. Such a
loader describes non-time-varying data, so its output variable seeds `const`
(folds at bind), not `discrete` (RFC pure-io-data-loaders §4.6 / §5.7.2).
"""
function _loader_without_temporal(var, model)
    refresh = get(var, "refresh", nothing)
    (isa(refresh, AbstractDict) && get(refresh, "kind", nothing) == "data_ingest") || return false
    loaders = get(model, "data_loaders", nothing)
    isa(loaders, AbstractDict) || return false
    loader = get(loaders, get(refresh, "source", nothing), nothing)
    return isa(loader, AbstractDict) && !haskey(loader, "temporal")
end

"""
    child_exprs(node) -> Vector

Every sub-Expression of a RAW operator node: the operand list `args` plus the
aggregate/integral sub-fields `expr`, `key`, `filter`, `lower`, `upper`.
`output_idx`, `ranges`, `wrt`, `dim`, `var` are index/metadata declarations
(`const`), not value inputs, and are excluded. (The typed-IR analogue is the
generated `child_exprs` walker in expression.jl; this raw twin exists only
because the conformance fixtures are classified pre-parse.)
"""
function child_exprs(node::AbstractDict)
    out = Any[]
    args = get(node, "args", nothing)
    if args !== nothing
        for a in args
            push!(out, a)
        end
    end
    for field in ("expr", "key", "filter", "lower", "upper")
        haskey(node, field) && push!(out, node[field])
    end
    return out
end

# Per-pass class memo: operator node (by identity) → derived class. Threaded
# through the walkers so each node is classified exactly once per pass instead
# of re-running the recursive `classify` from scratch at every visit
# (quadratic-plus on deep trees).
const ClassMemo = IdDict{Any,String}

"""
    classify(node, model[, memo::ClassMemo]) -> String

Derive a node's cadence class. A leaf is seeded ([`seed_leaf`](@ref)); an
operator node is `max` over its child classes — which, for a gather
`index(A, e…)`, is `max(class(A), class(e…))`: the index expressions are
classed independently of the array, so a stencil splits (§5.7.3 gather rule).

`memo` caches the derived class per operator node (by identity); the walkers
in one pass share a single memo so classification is linear in tree size.
"""
function classify(node, model, memo::ClassMemo=ClassMemo())
    isa(node, AbstractDict) || return seed_leaf(node, model)
    cached = get(memo, node, nothing)
    cached !== nothing && return cached
    children = child_exprs(node)
    cls = isempty(children) ? "const" :
          _join(String[classify(c, model, memo) for c in children])
    memo[node] = cls
    return cls
end

"""Walk the tree; wherever a node carries `expect_cadence`, assert the derived
class agrees (§5.7.6 guard 3). Appends a message per disagreement to `problems`."""
function check_expect_cadence!(node, model, problems::Vector{String},
                               memo::ClassMemo=ClassMemo())
    isa(node, AbstractDict) || return
    if haskey(node, "expect_cadence")
        derived = classify(node, model, memo)
        want = node["expect_cadence"]
        if derived != want
            push!(problems,
                "expect_cadence mismatch on op=$(repr(get(node, "op", nothing))): " *
                "declared $(repr(want)) but derived $(repr(derived))")
        end
    end
    for c in child_exprs(node)
        check_expect_cadence!(c, model, problems, memo)
    end
    return
end

"""Count annotated nodes (those carrying `expect_cadence`) by derived class —
the golden `class_summary`."""
function tally_classes!(node, model, counts::Dict{String,Int},
                        memo::ClassMemo=ClassMemo())
    isa(node, AbstractDict) || return
    if haskey(node, "expect_cadence")
        c = classify(node, model, memo)
        counts[c] = get(counts, c, 0) + 1
    end
    for c in child_exprs(node)
        tally_classes!(c, model, counts, memo)
    end
    return
end

# ── Materialization frontier (§5.7.4) ───────────────────────────────────────

"""Derive the expr-edge materialization frontier: a dict child whose class is
strictly lower than its parent's is a materialization point (the maximal
lower-cadence sub-DAG below that edge is cut, stored in a buffer, referenced by
the parent). We record the boundary and do NOT recurse into it. A bare
scalar-constant leaf is not a buffer, so scalar inlining is excluded."""
function materialization_frontier!(node, model, out::Vector{Any},
                                   memo::ClassMemo=ClassMemo())
    isa(node, AbstractDict) || return
    parent = classify(node, model, memo)
    for c in child_exprs(node)
        isa(c, AbstractDict) || continue
        cc = classify(c, model, memo)
        if CLASS_RANK[cc] < CLASS_RANK[parent]
            push!(out, Dict{String,Any}(
                "threshold" => "$(cc)->$(parent)",
                "kind" => "expr_edge",
                "op" => get(c, "op", nothing)))
        else
            materialization_frontier!(c, model, out, memo)
        end
    end
    return
end

"""True iff any value under `node` is `continuous` (drives hot-tree emptiness)."""
function has_continuous(node, model, memo::ClassMemo=ClassMemo())
    if isa(node, AbstractDict)
        classify(node, model, memo) == "continuous" && return true
        return any(has_continuous(c, model, memo) for c in child_exprs(node))
    end
    return seed_leaf(node, model) == "continuous"
end

# ── Guards (§5.7.6, checked) ─────────────────────────────────────────────────

"""
    assert_no_continuous_relational(node, model)

§5.7 guard 2: a `distinct`/`join`/`skolem`/`rank` node (or a `distinct`
aggregate) that classifies `continuous` is rejected — state-dependent topology
may not run on the per-step hot path in v1. Throws [`CadenceError`](@ref).
"""
function assert_no_continuous_relational(node, model, memo::ClassMemo=ClassMemo())
    isa(node, AbstractDict) || return
    op = get(node, "op", nothing)
    is_relational = (op in RELATIONAL_OPS) ||
                    (op == "aggregate" && get(node, "distinct", false) == true)
    if is_relational && classify(node, model, memo) == "continuous"
        throw(CadenceError(
            "relational/value-invention node op=$(repr(op)) classifies CONTINUOUS — " *
            "it may not run on the hot path (§5.7 guard 2). A state-dependent " *
            "distinct/join/skolem/rank is out of scope for v1."))
    end
    for c in child_exprs(node)
        assert_no_continuous_relational(c, model, memo)
    end
    return
end

"""
    assert_acyclic_index_sets(model)

§5.7 guard 1: the `≤discrete` subgraph must be a DAG. A derived index set points
(via `from_faq`) at the node that materialises it; that node references index
sets (via `ranges {from}`); a cycle in those edges is an implicit/iterative
solve, out of scope. The implicit set→node→set relation is materialised as a
small graph and checked by the SHARED three-color DFS
([`detect_cycle`](@ref), reference_graph.jl). Throws [`CadenceError`](@ref)
naming the cycle.
"""
function assert_acyclic_index_sets(model)
    index_sets = get(model, "index_sets", Dict{String,Any}())
    # Map each aggregate node id → the index sets it reads (ranges {from}).
    node_reads = Dict{String,Set{String}}()

    function collect_reads(node)
        isa(node, AbstractDict) || return
        nid = get(node, "id", nothing)
        if nid !== nothing
            reads = get!(() -> Set{String}(), node_reads, String(nid))
            ranges = get(node, "ranges", nothing)
            if isa(ranges, AbstractDict)
                for (_, r) in ranges
                    if isa(r, AbstractDict) && haskey(r, "from")
                        push!(reads, String(r["from"]))
                    end
                end
            end
        end
        for c in child_exprs(node)
            collect_reads(c)
        end
        return
    end

    for eq in get(model, "equations", Any[])
        collect_reads(get(eq, "lhs", nothing))
        collect_reads(get(eq, "rhs", nothing))
    end

    # Edges: set --(from_faq)--> node --(reads)--> set.
    set_to_node = Dict{String,String}()
    for (name, s) in index_sets
        if isa(s, AbstractDict) && get(s, "kind", nothing) == "derived" &&
           get(s, "from_faq", nothing) !== nothing
            set_to_node[name] = String(s["from_faq"])
        end
    end

    # Materialise the derived-set dependency graph (vertex per derived set,
    # edge per set→set read through its producer node) and run the shared
    # deterministic DFS over it.
    g = ReferenceGraph("cadence-index-set-deps")
    for name in keys(set_to_node)
        _ensure_vertex!(g, ReferenceVertex(String(name), "index_set", String(name),
                                           nothing, nothing, nothing))
    end
    for (name, node_id) in set_to_node
        for nxt in get(node_reads, node_id, Set{String}())
            haskey(set_to_node, nxt) || continue  # only derived sets participate
            _add_edge!(g, String(name), String(nxt), "range_from")
        end
    end
    cyc = detect_cycle(g)
    cyc === nothing || throw(CadenceError(
        "cycle in the ≤DISCRETE index-set dependency graph " *
        "(implicit solve, out of scope — §5.7 guard 1): " * join(cyc, " -> ")))
    return
end

end # module Cadence
