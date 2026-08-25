# reference_graph.jl — build-time reference resolution for the semiring-FAQ
# unified IR.
#
# Implements *node addressing* and *reference-edge resolution* — the hard
# prerequisite the §6.1 cadence-partition pass of the `semiring-faq-unified-ir`
# RFC calls out:
#
#   "node addressing — referencing a node by id — is a hard prerequisite: the
#    pass cannot be built until `from_faq` and join references are real edges in
#    this DAG."
#
# The partition pass classifies every node by cadence (CONST / DISCRETE /
# CONTINUOUS) by walking the *inter-node* dependency DAG bottom-up
# (`class(n) = max` over inputs). For that walk to exist, three kinds of name/id
# reference in the document must be resolved into real, queryable graph edges
# (RFC §6.1 "Propagation"):
#
#   * an aggregate node → an index set it references (`ranges[*].from`);
#   * a `kind:"derived"` index set → its `from_faq` node (by stable id);
#   * an aggregate `join.on` factor → the factor it names.
#
# Like the Python and Rust bindings, this pass operates on the **raw parsed
# document** (a nested `AbstractDict`/`AbstractVector`, e.g. the JSON3 object or
# a `Dict{String,Any}`) rather than the typed `OpExpr`/`Model` structs: the
# typed layer deliberately drops `index_sets`, node `id`, `ranges[*].from` and
# `join`, so the references live only in the raw document. The pass is
# self-contained and additive — a document using none of these features yields
# an empty-but-valid graph.
#
# The `ReferenceGraph` output is the queryable surface the partition pass
# consumes: `dependencies` / `dependents` give the DAG adjacency, and
# `topological_order` both detects reference cycles (an out-of-scope
# implicit/iterative solve, RFC §6.1 "Acyclicity") and yields a bottom-up
# evaluation order.

using OrderedCollections: OrderedDict

# --- stable error codes (mirrored across the Python/Rust bindings) ----------

const E_REF_UNDECLARED_INDEX_SET = "E_REF_UNDECLARED_INDEX_SET"
const E_REF_UNKNOWN_FAQ_NODE = "E_REF_UNKNOWN_FAQ_NODE"
const E_REF_DUPLICATE_NODE_ID = "E_REF_DUPLICATE_NODE_ID"
const E_REF_UNRESOLVED_JOIN_FACTOR = "E_REF_UNRESOLVED_JOIN_FACTOR"
const E_REF_CYCLE = "E_REF_CYCLE"

# --- vertex / edge kind tags (string-valued, cross-language stable) ---------

const REF_VERTEX_NODE = "node"
const REF_VERTEX_INDEX_SET = "index_set"
const REF_VERTEX_FACTOR = "factor"

const REF_EDGE_RANGE_FROM = "range_from"
const REF_EDGE_FROM_FAQ = "from_faq"
const REF_EDGE_JOIN_FACTOR = "join_factor"

"""
    ReferenceResolutionError(code, message[, cycle])

A reference could not be resolved, or the reference graph has a cycle. Carries a
stable `code` (one of the `E_REF_*` constants) so callers and the cross-binding
conformance suite can assert on the failure mode, and a human-readable
`message`. For a cycle, `cycle` holds the offending vertex-key path.
"""
struct ReferenceResolutionError <: EarthSciASTError
    code::String
    message::String
    cycle::Union{Nothing,Vector{String}}
end
ReferenceResolutionError(code::AbstractString, message::AbstractString) =
    ReferenceResolutionError(String(code), String(message), nothing)

Base.showerror(io::IO, e::ReferenceResolutionError) =
    print(io, "ReferenceResolutionError(", e.code, "): ", e.message)

"""
    ReferenceVertex

A vertex in the reference graph, addressed by a kind-namespaced `key`
(`"\$kind:\$name"`). For a node vertex, `name` is the node's stable address: its
explicit `id` when present, else its structural path (e.g.
`equations/0/rhs/expr`). `op`, `node_id`, and `path` are diagnostic metadata.
"""
struct ReferenceVertex
    key::String
    kind::String
    name::String
    op::Union{Nothing,String}
    node_id::Union{Nothing,String}
    path::Union{Nothing,String}
end

"""
    ReferenceEdge

A directed `source → target` edge: *source references / depends on target*.
"""
struct ReferenceEdge
    source::String
    target::String
    kind::String
end

"""
    ReferenceGraph

The resolved reference DAG for one model — the partition pass's input. Edges
point from a vertex to a vertex it *depends on*, so a bottom-up
([`topological_order`](@ref)) walk visits each vertex after its dependencies —
the order `class(n) = max(class(inputs))` propagation needs.
"""
mutable struct ReferenceGraph
    model::String
    vertices::OrderedDict{String,ReferenceVertex}
    edges::Vector{ReferenceEdge}
    out::OrderedDict{String,Vector{String}}
    incoming::OrderedDict{String,Vector{String}}
end
ReferenceGraph(model::AbstractString = "") = ReferenceGraph(
    String(model),
    OrderedDict{String,ReferenceVertex}(),
    ReferenceEdge[],
    OrderedDict{String,Vector{String}}(),
    OrderedDict{String,Vector{String}}(),
)

function _ensure_vertex!(g::ReferenceGraph, v::ReferenceVertex)
    if !haskey(g.vertices, v.key)
        g.vertices[v.key] = v
        get!(g.out, v.key, String[])
        get!(g.incoming, v.key, String[])
    end
    return g
end

function _add_edge!(g::ReferenceGraph, source::AbstractString, target::AbstractString,
                    kind::AbstractString)
    push!(g.edges, ReferenceEdge(String(source), String(target), String(kind)))
    push!(get!(g.out, String(source), String[]), String(target))
    push!(get!(g.incoming, String(target), String[]), String(source))
    return g
end

"""
    dependencies(g, key)

Vertices `key` references / depends on (its out-neighbours).
"""
dependencies(g::ReferenceGraph, key::AbstractString) = copy(get(g.out, String(key), String[]))

"""
    dependents(g, key)

Vertices that reference / depend on `key` (its in-neighbours).
"""
dependents(g::ReferenceGraph, key::AbstractString) = copy(get(g.incoming, String(key), String[]))

"""
    edges_of_kind(g, kind)

All edges of a given kind, in insertion order.
"""
edges_of_kind(g::ReferenceGraph, kind::AbstractString) =
    [e for e in g.edges if e.kind == String(kind)]

"""
    detect_cycle(g) -> Union{Nothing,Vector{String}}

Return a reference cycle as a vertex-key path `[v, …, v]` (the repeated vertex
closes the cycle), or `nothing` if the graph is acyclic. Three-color DFS over
the dependency edges, deterministic (sorted vertices, sorted neighbours).
"""
function detect_cycle(g::ReferenceGraph)
    # Three-color (WHITE/GRAY/BLACK) DFS, iterative, over a materialized graph.
    # This is the ONE cycle detector: `Cadence.assert_acyclic_index_sets`
    # (cadence.jl) materializes its implicit set→node→set relation into a small
    # `ReferenceGraph` and routes through here rather than carrying a twin.
    WHITE, GRAY, BLACK = 0, 1, 2
    color = Dict{String,Int}(k => WHITE for k in keys(g.vertices))
    # Precompute sorted adjacency once: the DFS revisits each vertex's
    # neighbour list once per outgoing edge, and re-sorting per visit was
    # needless repeated work.
    sorted_out = Dict{String,Vector{String}}(k => sort(v) for (k, v) in g.out)
    for start in sort(collect(keys(g.vertices)))
        get(color, start, WHITE) == WHITE || continue
        stack = Tuple{String,Int}[(start, 1)]   # (vertex, 1-based neighbour index)
        path = String[start]
        color[start] = GRAY
        while !isempty(stack)
            node, i = stack[end]
            neigh = get(sorted_out, node, String[])
            if i <= length(neigh)
                stack[end] = (node, i + 1)
                nxt = neigh[i]
                c = get(color, nxt, WHITE)
                if c == GRAY
                    idx = findfirst(==(nxt), path)
                    return vcat(path[idx:end], String[nxt])
                elseif c == WHITE
                    color[nxt] = GRAY
                    push!(stack, (nxt, 1))
                    push!(path, nxt)
                end
            else
                color[node] = BLACK
                pop!(stack)
                pop!(path)
            end
        end
    end
    return nothing
end

"""
    topological_order(g) -> Vector{String}

Bottom-up order (dependencies before dependents). Throws a
[`ReferenceResolutionError`](@ref) (`E_REF_CYCLE`) if the graph is cyclic — a
cycle among reference edges is an out-of-scope implicit/iterative solve (RFC
§6.1 "Acyclicity").
"""
function topological_order(g::ReferenceGraph)
    cyc = detect_cycle(g)
    cyc !== nothing && throw(ReferenceResolutionError(
        E_REF_CYCLE, "reference cycle detected: " * join(cyc, " -> "), cyc))
    emitted = String[]
    done = Set{String}()
    # Round-based scan preserving the historical (cross-binding) emission
    # order; vertices emitted in an earlier round are dropped from the scan
    # list instead of being re-checked every subsequent round.
    remaining = sort(collect(keys(g.vertices)))
    while !isempty(remaining)
        progressed = false
        next_remaining = String[]
        for k in remaining
            if all(d -> d in done, get(g.out, k, String[]))
                push!(emitted, k)
                push!(done, k)
                progressed = true
            else
                push!(next_remaining, k)
            end
        end
        progressed || break
        remaining = next_remaining
    end
    return emitted
end

# --- raw-document accessor helpers (String- or Symbol-keyed dicts) ----------
#
# NOTE(idiom): these `_get` / `_haskey` / `_str_keys` accessors tolerate
# String- OR Symbol-keyed dicts IN PLACE (no copy of the parsed document),
# threaded through every walk below. The Cadence classifier (cadence.jl) —
# conformance-only, like this pass — instead converts each (small) fixture
# model to native `Dict{String,Any}` up front (`Cadence.to_native`); the
# production build path parses straight into the typed IR and runs neither
# idiom.

const _AGGREGATE_OPS = ("aggregate", "arrayop")

_node_key(addr::AbstractString) = string(REF_VERTEX_NODE, ":", addr)
_index_set_key(name::AbstractString) = string(REF_VERTEX_INDEX_SET, ":", name)
_factor_key(name::AbstractString) = string(REF_VERTEX_FACTOR, ":", name)

# Look up a string key in an AbstractDict that may be keyed by String or Symbol.
function _get(d::AbstractDict, k::AbstractString)
    haskey(d, k) && return d[k]
    sk = Symbol(k)
    haskey(d, sk) && return d[sk]
    return nothing
end
_get(::Any, ::AbstractString) = nothing

_haskey(d::AbstractDict, k::AbstractString) = haskey(d, k) || haskey(d, Symbol(k))
_haskey(::Any, ::AbstractString) = false

_str_keys(d::AbstractDict) = String[string(k) for k in keys(d)]

_as_dict(x) = x isa AbstractDict ? x : nothing
_as_vec(x) = x isa AbstractVector ? x : nothing
_as_str(x) = x isa AbstractString ? String(x) : nothing
function _nonempty_str(x)
    s = _as_str(x)
    return (s !== nothing && !isempty(s)) ? s : nothing
end

_is_node(x) = x isa AbstractDict && _haskey(x, "op")

# Names a `join.on` reference may resolve to: the node's string factor-args, its
# declared range keys, and its symbolic output_idx.
function _factor_scope(node::AbstractDict)
    names = Set{String}()
    args = _as_vec(_get(node, "args"))
    if args !== nothing
        for a in args
            s = _as_str(a)
            s !== nothing && push!(names, s)
        end
    end
    ranges = _as_dict(_get(node, "ranges"))
    ranges !== nothing && union!(names, _str_keys(ranges))
    oi = _as_vec(_get(node, "output_idx"))
    if oi !== nothing
        for o in oi
            s = _as_str(o)
            s !== nothing && push!(names, s)
        end
    end
    return names
end

# One id-bearing expression node, as the `from_faq` scope sees it.
struct _RefNode
    addr::String
    path::String
    op::Union{Nothing,String}
end

# The model members whose expression trees carry addressable nodes.
const _WALK_ROOTS = ("equations", "initialization_equations")

function _register_and_process!(g::ReferenceGraph, node::AbstractDict, path::AbstractString,
                                model_name::AbstractString,
                                index_sets::Union{Nothing,AbstractDict},
                                id_to_addr::OrderedDict{String,_RefNode})
    op = _as_str(_get(node, "op"))
    nid = _nonempty_str(_get(node, "id"))
    is_agg = op !== nothing && op in _AGGREGATE_OPS
    # only aggregate / FAQ nodes and any node carrying an explicit id become
    # addressable vertices.
    (is_agg || nid !== nothing) || return g

    addr = nid !== nothing ? nid : String(path)
    key = _node_key(addr)

    if nid !== nothing
        if haskey(id_to_addr, nid)
            throw(ReferenceResolutionError(
                E_REF_DUPLICATE_NODE_ID,
                "duplicate expression-node id '$(nid)' in model '$(model_name)' " *
                "(at $(path) and $(id_to_addr[nid].path))"))
        end
        id_to_addr[nid] = _RefNode(addr, String(path), op)
    end

    _ensure_vertex!(g, ReferenceVertex(key, REF_VERTEX_NODE, addr, op, nid, String(path)))

    # ranges[*].from -> index set
    ranges = _as_dict(_get(node, "ranges"))
    if ranges !== nothing
        for idx_name in _str_keys(ranges)
            spec = _as_dict(_get(ranges, idx_name))
            (spec !== nothing && _haskey(spec, "from")) || continue
            target = _as_str(_get(spec, "from"))
            declared = index_sets !== nothing && target !== nothing && _haskey(index_sets, target)
            if target === nothing || isempty(target) || !declared
                throw(ReferenceResolutionError(
                    E_REF_UNDECLARED_INDEX_SET,
                    "range '$(idx_name)' of node $(key) references undeclared index set " *
                    "'$(target === nothing ? "" : target)' (model '$(model_name)', at $(path))"))
            end
            _add_edge!(g, key, _index_set_key(target), REF_EDGE_RANGE_FROM)
        end
    end

    # join[*].on[*] -> factor
    join_clauses = _as_vec(_get(node, "join"))
    if join_clauses !== nothing
        scope = _factor_scope(node)
        for clause in join_clauses
            cld = _as_dict(clause)
            cld === nothing && continue
            # A Phase-2a `overlap` clause references const-array ENVELOPE factors
            # via `src_env` / `tgt_env`; each must resolve in factor scope just
            # like a bin-equality key column.
            ov = _as_dict(_get(cld, "overlap"))
            if ov !== nothing
                for envkey in ("src_env", "tgt_env")
                    names = _as_vec(_get(ov, envkey))
                    names === nothing && continue
                    for nm in names
                        ref = _as_str(nm)
                        if ref === nothing || !(ref in scope)
                            throw(ReferenceResolutionError(
                                E_REF_UNRESOLVED_JOIN_FACTOR,
                                "overlap-join env factor '$(ref === nothing ? "" : ref)' of " *
                                "node $(key) names no factor, range, or output index in " *
                                "scope (model '$(model_name)', at $(path))"))
                        end
                        _ensure_vertex!(g, ReferenceVertex(
                            _factor_key(ref), REF_VERTEX_FACTOR, ref, nothing, nothing, nothing))
                        _add_edge!(g, key, _factor_key(ref), REF_EDGE_JOIN_FACTOR)
                    end
                end
                continue
            end
            on = _as_vec(_get(cld, "on"))
            on === nothing && continue
            for pair in on
                pv = _as_vec(pair)
                (pv === nothing || isempty(pv)) && continue
                ref = _as_str(pv[1])
                if ref === nothing || !(ref in scope)
                    throw(ReferenceResolutionError(
                        E_REF_UNRESOLVED_JOIN_FACTOR,
                        "join factor '$(ref === nothing ? "" : ref)' of node $(key) names no " *
                        "factor, range, or output index in scope " *
                        "(model '$(model_name)', at $(path))"))
                end
                _ensure_vertex!(g, ReferenceVertex(
                    _factor_key(ref), REF_VERTEX_FACTOR, ref, nothing, nothing, nothing))
                _add_edge!(g, key, _factor_key(ref), REF_EDGE_JOIN_FACTOR)
            end
        end
    end

    return g
end

function _walk!(g::ReferenceGraph, value, path::AbstractString, model_name::AbstractString,
                index_sets::Union{Nothing,AbstractDict},
                id_to_addr::OrderedDict{String,_RefNode})
    if value isa AbstractDict
        _is_node(value) &&
            _register_and_process!(g, value, path, model_name, index_sets, id_to_addr)
        for k in _str_keys(value)
            _walk!(g, _get(value, k), string(path, "/", k), model_name, index_sets, id_to_addr)
        end
    elseif value isa AbstractVector
        for (i, v) in enumerate(value)
            _walk!(g, v, string(path, "/", i - 1), model_name, index_sets, id_to_addr)
        end
    end
    return g
end

# Collect every explicit expression-node id under one model's `value`, keyed by
# id, under a model-qualified path.
function _collect_ids!(nodes::OrderedDict{String,_RefNode}, value, path::AbstractString,
                       model_name::AbstractString)
    if value isa AbstractDict
        if _is_node(value)
            nid = _nonempty_str(_get(value, "id"))
            if nid !== nothing
                qualified = string("models/", model_name, "/", path)
                if haskey(nodes, nid)
                    throw(ReferenceResolutionError(
                        E_REF_DUPLICATE_NODE_ID,
                        "duplicate expression-node id '$(nid)' in document " *
                        "(at $(qualified) and $(nodes[nid].path))"))
                end
                nodes[nid] = _RefNode(nid, qualified, _as_str(_get(value, "op")))
            end
        end
        for k in _str_keys(value)
            _collect_ids!(nodes, _get(value, k), string(path, "/", k), model_name)
        end
    elseif value isa AbstractVector
        for (i, v) in enumerate(value)
            _collect_ids!(nodes, v, string(path, "/", i - 1), model_name)
        end
    end
    return nodes
end

"""
    _collect_document_node_ids(document) -> OrderedDict{String,_RefNode}

Every explicit expression-node `id` in `document`, keyed by id.

`from_faq` resolves at DOCUMENT scope (esm-spec.md §9.7.5): a document-scoped
`index_sets` entry is visible to every model, so the node it names may live in
ANY of them. This pass therefore runs over all models BEFORE any single model's
graph is built.

Because ids from different models share one namespace, uniqueness is a
DOCUMENT-wide requirement: a duplicate `id` anywhere in the document is
`E_REF_DUPLICATE_NODE_ID`.
"""
function _collect_document_node_ids(document::AbstractDict)
    nodes = OrderedDict{String,_RefNode}()
    models = _as_dict(_get(document, "models"))
    models === nothing && return nodes
    for name in _str_keys(models)
        model = _as_dict(_get(models, name))
        model === nothing && continue
        for root in _WALK_ROOTS
            v = _get(model, root)
            v === nothing || _collect_ids!(nodes, v, root, name)
        end
    end
    return nodes
end

# Union of the document-scoped registry and any model-nested one, with the
# model's entries taking precedence. Returns `nothing` when neither exists, so
# the "no registry at all" branches below stay unchanged.
function _merge_index_sets(model_sets::Union{Nothing,AbstractDict},
                           doc_sets::Union{Nothing,AbstractDict})
    doc_sets === nothing && return model_sets
    model_sets === nothing && return doc_sets
    merged = OrderedDict{String,Any}()
    for k in _str_keys(doc_sets)
        merged[k] = _get(doc_sets, k)
    end
    for k in _str_keys(model_sets)
        merged[k] = _get(model_sets, k)
    end
    return merged
end

"""
    build_reference_graph(model::AbstractDict, model_name="", index_sets=nothing)
        -> ReferenceGraph

Resolve the reference edges of one `model` dict into a graph. Throws a
[`ReferenceResolutionError`](@ref) on a duplicate node id, an undeclared
`ranges[*].from` index set, a `from_faq` naming no node, or an unresolved
`join.on` factor. (Cycles are reported lazily by [`topological_order`](@ref), or
eagerly by [`resolve_references`](@ref).)

`index_sets` is the **document-scoped** index-set registry (RFC §5.2). Since
v0.8.0 that registry is a sibling of `models` at the top level of the document,
not a key on each model, and in esm 1.0.0 it is the only place it may appear
(`esm-schema.json` declares `index_sets` at `/properties/index_sets` and
nowhere else). [`resolve_references`](@ref) threads the document's registry in
for every model; a caller holding only a raw model dict may pass it explicitly,
or omit it and get the pre-0.8.0 model-nested `index_sets` key as a fallback.

Until API_SPEC.md §8 item 17 this method read ONLY `model["index_sets"]` and
took no registry argument, so on any v0.8.0+ document every `ranges[*].from`
target was undeclared and the pass raised `undeclared_index_set` where Python,
Rust and Go all built the graph. The optional trailing argument is the shape
Python (`index_sets=`) and Go (`docIndexSets`) already use; Rust spells it as
the separate `build_reference_graph_with_index_sets`.

`from_faq` resolves at DOCUMENT scope (esm-spec.md §9.7.5). A caller holding one
model gets that model as its own document, which is the right answer for a
one-model document; [`resolve_references`](@ref) is the document-scoped entry
point and resolves against every model's nodes.
"""
function build_reference_graph(model::AbstractDict, model_name::AbstractString = "",
                               index_sets::Union{Nothing,AbstractDict} = nothing)
    return _build_reference_graph(model, model_name, index_sets, nothing)
end

# `build_reference_graph`, plus the document-wide `from_faq` scope.
# `document_nodes` is the map `_collect_document_node_ids` builds over every
# model; when it is `nothing` the model's own nodes are the scope.
function _build_reference_graph(model::AbstractDict, model_name::AbstractString,
                                index_sets::Union{Nothing,AbstractDict},
                                document_nodes::Union{Nothing,OrderedDict{String,_RefNode}})
    g = ReferenceGraph(model_name)
    # Merge the document-scoped registry (v0.8.0+) with any model-nested one
    # (pre-0.8.0); model-level entries win a key collision, matching Rust and
    # Go. For a schema-valid 1.0.0 document only one of the two is ever
    # non-empty, so the merge is observationally the same as Python's
    # "document registry, else the model key" fallback.
    index_sets = _merge_index_sets(_as_dict(_get(model, "index_sets")), index_sets)

    # Pass 1 — register declared index sets as vertices.
    if index_sets !== nothing
        for name in _str_keys(index_sets)
            _ensure_vertex!(g, ReferenceVertex(
                _index_set_key(name), REF_VERTEX_INDEX_SET, name, nothing, nothing, nothing))
        end
    end

    # Pass 2 — walk every expression node: assign a stable address, register
    # aggregate / id-bearing nodes, add within-node reference edges
    # (ranges[*].from, join.on), and build id -> address for from_faq.
    id_to_addr = OrderedDict{String,_RefNode}()
    for root in _WALK_ROOTS
        v = _get(model, root)
        v === nothing || _walk!(g, v, root, model_name, index_sets, id_to_addr)
    end

    # Pass 3 — derived index sets resolve their from_faq to a node by id, at
    # DOCUMENT scope (esm-spec.md §9.7.5): the producing node may live in any
    # model, since the registry entry naming it is visible to all of them.
    faq_scope = document_nodes === nothing ? id_to_addr : document_nodes
    if index_sets !== nothing
        for name in _str_keys(index_sets)
            entry = _as_dict(_get(index_sets, name))
            entry === nothing && continue
            _as_str(_get(entry, "kind")) == "derived" || continue
            faq = _as_str(_get(entry, "from_faq"))
            if faq === nothing || !haskey(faq_scope, faq)
                throw(ReferenceResolutionError(
                    E_REF_UNKNOWN_FAQ_NODE,
                    "derived index set '$(name)' references from_faq " *
                    "'$(faq === nothing ? "" : faq)', which is not the id of any " *
                    "expression node in the document"))
            end
            target = faq_scope[faq]
            # The producer may belong to another model; give this graph a vertex
            # for it so the edge has a real endpoint. `_ensure_vertex!` is
            # idempotent: a local producer was already registered in pass 2.
            _ensure_vertex!(g, ReferenceVertex(
                _node_key(target.addr), REF_VERTEX_NODE, target.addr,
                target.op, faq, target.path))
            _add_edge!(g, _index_set_key(name), _node_key(target.addr), REF_EDGE_FROM_FAQ)
        end
    end

    return g
end

"""
    resolve_references(document::AbstractDict) -> OrderedDict{String,ReferenceGraph}

Resolve reference edges for every model in `document`. Throws a
[`ReferenceResolutionError`](@ref) on any unresolved reference *or* reference
cycle (each model's graph is checked acyclic eagerly here).

The document's top-level `index_sets` registry is threaded into every model's
[`build_reference_graph`](@ref) call — that is where esm 1.0.0 puts it.

Node ids are collected from EVERY model first, so a derived index set's
`from_faq` may name a producer in any model (esm-spec.md §9.7.5) and a duplicate
id anywhere in the document is an error.
"""
function resolve_references(document::AbstractDict)
    out = OrderedDict{String,ReferenceGraph}()
    models = _as_dict(_get(document, "models"))
    models === nothing && return out
    doc_index_sets = _as_dict(_get(document, "index_sets"))
    document_nodes = _collect_document_node_ids(document)
    for name in _str_keys(models)
        model = _as_dict(_get(models, name))
        model === nothing && continue
        g = _build_reference_graph(model, name, doc_index_sets, document_nodes)
        cyc = detect_cycle(g)
        cyc !== nothing && throw(ReferenceResolutionError(
            E_REF_CYCLE, "reference cycle in model '$(name)': " * join(cyc, " -> "), cyc))
        out[name] = g
    end
    return out
end
