"""Cross-language conformance for the graph representations (§4.8).

Drives the shared corpus at ``tests/conformance/graph/cases.json``, generated
from the TypeScript oracle by ``scripts/generate-graph-corpus.mjs``. The corpus
pins the SEMANTIC graph model — component nodes with their types and summary
counts, coupling edges with their types and labels, variable nodes with their
DERIVED kinds, dependency edges with their relationships and equation indices,
the adjacency closure, and the JSON adjacency-list export.

Node and edge ORDER is not a conformance property: each binding iterates its own
maps. Every list is therefore compared as a sorted multiset.

The DOT and Mermaid BYTES are not pinned and are not asserted here — §4.8.3
requires both formats and specifies neither. See the corpus README.
"""

from __future__ import annotations

import json

import pytest
from conftest import CONFORMANCE_DIR, VALID_DIR

import earthsci_ast as esm
from earthsci_ast.parse import (
    _parse_equation,
    _parse_expression,
    _parse_model,
    _parse_reaction,
    _parse_reaction_system,
)
from earthsci_ast.graph import (
    Graph,
    component_graph,
    expression_graph,
    to_json,
)

CORPUS = json.loads((CONFORMANCE_DIR / "graph" / "cases.json").read_text())


def _multiset(records: list[dict]) -> list[str]:
    """Sorted canonical JSON of each record, so lists compare order-insensitively."""
    return sorted(json.dumps(r, sort_keys=True) for r in records)


def _closure(graph: Graph, keys: list[str]) -> dict[str, dict[str, list[str]]]:
    return {
        key: {
            "adjacency": sorted(graph.adjacency(key)),
            "predecessors": sorted(graph.predecessors(key)),
            "successors": sorted(graph.successors(key)),
        }
        for key in keys
    }


def _actual_component(graph: Graph) -> dict:
    return {
        "nodes": [
            {
                "id": n.id,
                "type": n.type,
                "var_count": n.metadata["var_count"],
                "eq_count": n.metadata["eq_count"],
                "species_count": n.metadata["species_count"],
            }
            for n in graph.nodes
        ],
        # `from_component` / `to_component` are this binding's spelling of the
        # wire keys `from` / `to`, which are Python keywords.
        "edges": [
            {
                "from": e.data.from_component,
                "to": e.data.to_component,
                "type": e.data.type,
                "label": e.data.label,
            }
            for e in graph.edges
        ],
        "closure": _closure(graph, [n.id for n in graph.nodes]),
    }


def _actual_expression(graph: Graph) -> dict:
    return {
        "nodes": [
            {"name": n.name, "kind": n.kind, "units": n.units, "system": n.system}
            for n in graph.nodes
        ],
        "edges": [
            {
                "source": e.data.source,
                "target": e.data.target,
                "relationship": e.data.relationship,
                "equation_index": e.data.equation_index,
            }
            for e in graph.edges
        ],
        "closure": _closure(graph, [n.name for n in graph.nodes]),
    }


def _actual_json_export(graph: Graph) -> dict:
    parsed = json.loads(to_json(graph))
    return {
        "top_level_keys": sorted(parsed.keys()),
        "node_ids": [n["id"] for n in parsed["nodes"]],
        "edges": [{"source": e["source"], "target": e["target"]} for e in parsed["edges"]],
        # Sorted — see the generator: neighbour order is not pinned.
        "adjacency": {k: sorted(v) for k, v in parsed["adjacency"].items()},
    }


def _assert_graph(actual: dict, expected: dict) -> None:
    assert _multiset(actual["nodes"]) == _multiset(expected["nodes"])
    assert _multiset(actual["edges"]) == _multiset(expected["edges"])
    assert actual["closure"] == expected["closure"]


def _assert_json_export(actual: dict, expected: dict) -> None:
    assert actual["top_level_keys"] == expected["top_level_keys"]
    assert sorted(actual["node_ids"]) == sorted(expected["node_ids"])
    assert _multiset(actual["edges"]) == _multiset(expected["edges"])
    assert actual["adjacency"] == expected["adjacency"]


def _load(case: dict):
    name = case["input_file"].removeprefix("tests/valid/")
    return esm.load_string((VALID_DIR / name).read_text())


#: Each corpus target kind, mapped to the parser that turns its inline JSON
#: payload into this binding's dataclass. An `expression` target is raw
#: `Expr` JSON and needs no construction.
_TARGET_PARSERS = {
    "model": _parse_model,
    "reaction_system": _parse_reaction_system,
    "equation": _parse_equation,
    "reaction": _parse_reaction,
    # A bare Expr payload is raw JSON; it still needs parsing into this
    # binding's node type before `free_variables` can walk it.
    "expression": _parse_expression,
}


def _build_target(case: dict):
    return _TARGET_PARSERS[case["kind"]](case["target"])


#: Fixtures whose EXPRESSION-graph node kinds this binding cannot yet match,
#: with the reason. `wildfire_atmosphere_ocean` declares three unknowns
#: (`rg_pairs`, `rg_src_bin`, `rg_tgt_bin`) defined by an INDEXED LHS
#: (`rg_src_bin[a] ~ …`). esm-spec §6.3.1 defines an observed unknown as one
#: with a "bare-variable LHS", so TypeScript and Go classify these as
#: `algebraic`; this binding and Rust classify them as `observed`, because
#: `observed_definitions` deliberately credits the arrayed form — its docstring
#: records why (an arrayed observed's cadence must resolve through its RHS, and
#: refusing to credit it would stop a const-backed geometry array folding).
#:
#: Narrowing `observed_unknowns` / `algebraic_unknowns` to the strict form would
#: fix the graph, but `algebraic_unknowns` is also the "solved unknowns" set
#: `codegen`, `value_invention` and `structural_checks` consume, so the change
#: reaches well past §4.8 and is not made here. Left as a STRICT xfail so it
#: cannot rot: the day the classifier is aligned, this fails and must be removed.
_EXPRESSION_KIND_XFAIL = {
    "wildfire_atmosphere_ocean": (
        "observed_unknowns credits an indexed LHS (rg_src_bin[a] ~ ...); §6.3.1 "
        "and the TypeScript/Go classifiers call that algebraic. Fixing it moves "
        "algebraic_unknowns, which codegen and value_invention consume."
    ),
}


def _file_params(*, expression_kinds: bool) -> list:
    """Corpus file cases as pytest params.

    ``expression_kinds`` marks the cases whose assertion depends on a variable
    node's derived KIND, so the component-graph tests stay strict.
    """
    params = []
    for case in CORPUS["files"]:
        marks = []
        reason = _EXPRESSION_KIND_XFAIL.get(case["name"])
        if expression_kinds and reason is not None:
            marks.append(pytest.mark.xfail(strict=True, reason=reason))
        params.append(pytest.param(case, id=case["name"], marks=marks))
    return params


FILE_CASES = _file_params(expression_kinds=False)
EXPRESSION_FILE_CASES = _file_params(expression_kinds=True)
TARGET_CASES = [pytest.param(c, id=c["name"]) for c in CORPUS["targets"]]


@pytest.mark.parametrize("case", FILE_CASES)
def test_component_graph(case):
    _assert_graph(_actual_component(component_graph(_load(case))), case["component_graph"])


@pytest.mark.parametrize("case", FILE_CASES)
def test_component_graph_json_export(case):
    _assert_json_export(
        _actual_json_export(component_graph(_load(case))), case["component_graph_json"]
    )


@pytest.mark.parametrize("case", EXPRESSION_FILE_CASES)
def test_expression_graph(case):
    _assert_graph(_actual_expression(expression_graph(_load(case))), case["expression_graph"])


@pytest.mark.parametrize("case", FILE_CASES)
def test_expression_graph_json_export(case):
    _assert_json_export(
        _actual_json_export(expression_graph(_load(case))), case["expression_graph_json"]
    )


@pytest.mark.parametrize("case", EXPRESSION_FILE_CASES)
def test_expression_graph_merge_coupled(case):
    _assert_graph(
        _actual_expression(expression_graph(_load(case), merge_coupled=True)),
        case["expression_graph_merge_coupled"],
    )


@pytest.mark.parametrize("case", TARGET_CASES)
def test_expression_graph_target(case):
    """The Model / ReactionSystem / Equation / Reaction / Expr overloads (§4.8.2).

    Each target is carried inline in the corpus, so the case is driven from the
    corpus alone rather than by re-reading (and re-resolving) the fixture the
    payload was lifted from.
    """
    _assert_graph(
        _actual_expression(expression_graph(_build_target(case))), case["expression_graph"]
    )
