# Cross-language conformance for the graph representations (esm-libraries-spec §4.8).
#
# Drives the shared corpus at tests/conformance/graph/cases.json, GENERATED from
# the TypeScript oracle by scripts/generate-graph-corpus.mjs. The corpus pins the
# SEMANTIC graph model — component nodes with their types and summary counts,
# coupling edges with their types and labels, variable nodes with their DERIVED
# kinds, dependency edges with their relationships and equation indices, the
# adjacency closure, and the JSON adjacency-list export.
#
# Node and edge ORDER is not a conformance property: each binding iterates its
# own maps. Every list is compared as a SORTED MULTISET.
#
# The DOT and Mermaid HEADER lines are pinned (§4.8.3 requires both formats and
# specifies neither, so the tie-break is the majority of the five bindings). The
# rest of their bytes is not: every node line carries a label run through the
# chemical-subscript formatter, which two of the five bindings do not have. See
# the corpus README.

using Test
using JSON3
using EarthSciAST

# `testutils.jl` provides TESTUTILS_REPO_ROOT + `_require_fixture`. `Test` must
# already be imported before it is included (its guard block expands
# `@test_skip` at lowering time).
if !isdefined(Main, :ESM_TESTUTILS_LOADED)
    include("testutils.jl")
end

const _GRAPH_CORPUS_PATH =
    joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance", "graph", "cases.json")
const _VALID_DIR = joinpath(TESTUTILS_REPO_ROOT, "tests", "valid")

# ── comparison helpers ──────────────────────────────────────────────────────

"""Canonical JSON of each record, sorted, so a list compares order-insensitively."""
_multiset(records) = sort!([JSON3.write(r) for r in records])

"""
Normalize a corpus record into the `Dict{String,Any}` shape `_multiset` compares.

The corpus is read with JSON3, so its objects are `JSON3.Object`s whose key
ORDER is the file's. Rebuilding each record as a sorted-key Dict makes the
JSON3.write of a corpus record and of a locally-built record comparable.
"""
_norm(o) = Dict{String,Any}(String(k) => (v isa JSON3.Object ? _norm(v) :
                                          v isa JSON3.Array ? [x for x in v] : v)
                            for (k, v) in pairs(o))
_norm_all(list) = [_norm(o) for o in list]

"""Sort a record Dict's keys by rebuilding it in sorted order for JSON3.write."""
_sorted(d::AbstractDict) = JSON3.write(sort!(collect(pairs(d)), by=first))

_multiset_d(records) = sort!([_sorted(r) for r in records])

# ── actual-value extraction ─────────────────────────────────────────────────

function _actual_component(graph)
    nodes = [Dict{String,Any}(
        "id" => n.id,
        "type" => n.type,
        "var_count" => n.metadata["var_count"],
        "eq_count" => n.metadata["eq_count"],
        "species_count" => n.metadata["species_count"],
    ) for n in graph.nodes]
    edges = [Dict{String,Any}(
        "from" => e.data.from,
        "to" => e.data.to,
        "type" => e.data.type,
        "label" => e.data.label,
    ) for e in graph.edges]
    closure = Dict{String,Any}(
        n.id => Dict{String,Any}(
            "adjacency" => sort!(String[m.id for m in EarthSciAST._adjacent_nodes(graph, n)]),
            "predecessors" => sort!(String[m.id for m in predecessors(graph, n)]),
            "successors" => sort!(String[m.id for m in successors(graph, n)]),
        ) for n in graph.nodes)
    return (nodes=nodes, edges=edges, closure=closure)
end

function _actual_expression(graph)
    nodes = [Dict{String,Any}(
        "name" => n.name,
        "kind" => n.kind,
        "units" => n.units,
        "system" => n.system,
    ) for n in graph.nodes]
    edges = [Dict{String,Any}(
        "source" => e.data.source,
        "target" => e.data.target,
        "relationship" => e.data.relationship,
        "equation_index" => e.data.equation_index,
    ) for e in graph.edges]
    closure = Dict{String,Any}(
        n.name => Dict{String,Any}(
            "adjacency" => sort!(String[m.name for m in EarthSciAST._adjacent_nodes(graph, n)]),
            "predecessors" => sort!(String[m.name for m in predecessors(graph, n)]),
            "successors" => sort!(String[m.name for m in successors(graph, n)]),
        ) for n in graph.nodes)
    return (nodes=nodes, edges=edges, closure=closure)
end

function _actual_json_export(graph)
    parsed = JSON3.read(to_json(graph))
    return (
        top_level_keys = sort!(String[String(k) for k in keys(parsed)]),
        node_ids = String[String(n["id"]) for n in parsed["nodes"]],
        edges = [Dict{String,Any}("source" => String(e["source"]),
                                  "target" => String(e["target"]))
                 for e in parsed["edges"]],
        adjacency = Dict{String,Vector{String}}(
            String(k) => sort!(String[String(x) for x in v])
            for (k, v) in pairs(parsed["adjacency"])),
    )
end

# ── expected-value extraction ───────────────────────────────────────────────

_expected_closure(c) = Dict{String,Any}(
    String(k) => Dict{String,Any}(
        "adjacency" => String[String(x) for x in v["adjacency"]],
        "predecessors" => String[String(x) for x in v["predecessors"]],
        "successors" => String[String(x) for x in v["successors"]],
    ) for (k, v) in pairs(c))

function _assert_graph(actual, expected, label)
    @testset "$label" begin
        @test _multiset_d(actual.nodes) == _multiset_d(_norm_all(expected["nodes"]))
        @test _multiset_d(actual.edges) == _multiset_d(_norm_all(expected["edges"]))
        @test actual.closure == _expected_closure(expected["closure"])
    end
end

function _assert_json_export(actual, expected, label)
    @testset "$label" begin
        @test actual.top_level_keys == String[String(x) for x in expected["top_level_keys"]]
        @test sort(actual.node_ids) == sort(String[String(x) for x in expected["node_ids"]])
        @test _multiset_d(actual.edges) == _multiset_d(_norm_all(expected["edges"]))
        @test actual.adjacency == Dict{String,Vector{String}}(
            String(k) => String[String(x) for x in v] for (k, v) in pairs(expected["adjacency"]))
    end
end

# ── target construction ─────────────────────────────────────────────────────

const _TARGET_METADATA = Dict{String,Any}("name" => "GraphCorpusTarget")

"""
Parse a bare expression payload into an `ASTExpr` by routing it through `load`
as one equation's RHS. There is no public JSON-to-expression entry point.
"""
function _parse_target_expression(payload)
    doc = Dict{String,Any}("esm" => "1.0.0", "metadata" => _TARGET_METADATA,
                           "models" => Dict{String,Any}("T" => Dict{String,Any}(
                               "variables" => Dict{String,Any}(),
                               "equations" => Any[Dict{String,Any}(
                                   "lhs" => "sink", "rhs" => payload)])))
    return load_document(doc; base_path=_VALID_DIR).models["T"].equations[1].rhs
end

"""
Turn one corpus `targets[]` payload into the typed object `expression_graph`
takes.

There is no public per-component parser, so each payload is wrapped in a minimal
ESM document, handed to `load`, and the piece pulled back out. That keeps the
test on the public API and means the target is parsed by exactly the code path a
real document goes through.
"""
function _build_target(case)
    kind = String(case["kind"])
    payload = JSON3.read(JSON3.write(case["target"]), Dict{String,Any})
    if kind == "model"
        doc = Dict{String,Any}("esm" => "1.0.0", "metadata" => _TARGET_METADATA,
                               "models" => Dict{String,Any}("T" => payload))
        return load_document(doc; base_path=_VALID_DIR).models["T"]
    elseif kind == "reaction_system"
        doc = Dict{String,Any}("esm" => "1.0.0", "metadata" => _TARGET_METADATA,
                               "reaction_systems" => Dict{String,Any}("T" => payload))
        return load_document(doc; base_path=_VALID_DIR).reaction_systems["T"]
    elseif kind == "equation"
        doc = Dict{String,Any}("esm" => "1.0.0", "metadata" => _TARGET_METADATA,
                               "models" => Dict{String,Any}("T" => Dict{String,Any}(
                                   "variables" => Dict{String,Any}(),
                                   "equations" => Any[payload])))
        return load_document(doc; base_path=_VALID_DIR).models["T"].equations[1]
    elseif kind == "reaction"
        rxn = copy(payload)
        # Julia's `Reaction` requires an `id`; the corpus payload carries none
        # because the oracle's type does not. It plays no part in the graph.
        haskey(rxn, "id") || (rxn["id"] = "R1")
        # `species` and `parameters` are keyed MAPS on the wire, and the schema
        # requires every species a reaction names — and every free variable of
        # its rate — to be declared. None of it reaches the standalone
        # `expression_graph(reaction)` result, which reads the reaction alone;
        # the declarations exist only to get the payload through `load`.
        species = Dict{String,Any}()
        for side in ("substrates", "products"), entry in get(rxn, side, Any[])
            species[String(entry["species"])] = Dict{String,Any}("units" => "mol/mol")
        end
        parameters = Dict{String,Any}(
            name => Dict{String,Any}("units" => "1", "default" => 1.0)
            for name in free_variables(_parse_target_expression(rxn["rate"])))
        doc = Dict{String,Any}("esm" => "1.0.0", "metadata" => _TARGET_METADATA,
                               "reaction_systems" => Dict{String,Any}("T" => Dict{String,Any}(
                                   "species" => species,
                                   "parameters" => parameters,
                                   "reactions" => Any[rxn])))
        return load_document(doc; base_path=_VALID_DIR).reaction_systems["T"].reactions[1]
    elseif kind == "expression"
        return _parse_target_expression(payload)
    end
    error("unhandled corpus target kind: $kind")
end

# ── the suite ───────────────────────────────────────────────────────────────

if _require_fixture(_GRAPH_CORPUS_PATH)
    const _CORPUS = JSON3.read(read(_GRAPH_CORPUS_PATH, String))

    @testset "graph conformance corpus — whole documents" begin
        for case in _CORPUS["files"]
            name = String(case["name"])
            fixture = joinpath(TESTUTILS_REPO_ROOT, String(case["input_file"]))
            _require_fixture(fixture) || continue
            file = load_path(fixture)

            @testset "$name" begin
                _assert_graph(_actual_component(component_graph(file)),
                              case["component_graph"], "component_graph")
                _assert_json_export(_actual_json_export(component_graph(file)),
                                    case["component_graph_json"],
                                    "component_graph JSON export")

                _assert_graph(_actual_expression(expression_graph(file)),
                              case["expression_graph"], "expression_graph")
                _assert_json_export(_actual_json_export(expression_graph(file)),
                                    case["expression_graph_json"],
                                    "expression_graph JSON export")
                _assert_graph(
                    _actual_expression(expression_graph(file; merge_coupled=true)),
                    case["expression_graph_merge_coupled"],
                    "expression_graph merge_coupled")

                # The DOT and Mermaid HEADER lines (esm-libraries-spec §4.8.3).
                # The corpus pins only the first line of each: the rest carries
                # node labels run through the chemical-subscript formatter,
                # which two of the five bindings do not have. See
                # tests/conformance/graph/README.md.
                for (what, text, expected) in (
                    ("component_graph DOT", to_dot(component_graph(file)),
                     case["component_graph_dot_header"]),
                    ("component_graph Mermaid", to_mermaid(component_graph(file)),
                     case["component_graph_mermaid_header"]),
                    ("expression_graph DOT", to_dot(expression_graph(file)),
                     case["expression_graph_dot_header"]),
                    ("expression_graph Mermaid", to_mermaid(expression_graph(file)),
                     case["expression_graph_mermaid_header"]),
                )
                    @test first(split(text, "\n")) == String(expected)
                end
            end
        end
    end

    @testset "graph conformance corpus — sub-document expression_graph targets" begin
        for case in _CORPUS["targets"]
            _assert_graph(_actual_expression(expression_graph(_build_target(case))),
                          case["expression_graph"], String(case["name"]))
        end
    end
end
