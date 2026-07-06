"""Unit tests for :mod:`earthsci_toolkit.reference_resolution`.

Covers the four acceptance criteria of the node-addressing bead (RFC
``semiring-faq-unified-ir`` §6.1):

1. a derived index set resolves its ``from_faq`` to a specific node;
2. a join factor resolves to its referenced factor;
3. references are edges queryable by the partition pass;
4. a reference cycle is detectable.
"""

from __future__ import annotations

import pytest

from earthsci_toolkit.reference_resolution import (
    EdgeKind,
    ReferenceResolutionError,
    VertexKind,
    build_reference_graph,
    resolve_references,
    E_REF_CYCLE,
    E_REF_DUPLICATE_NODE_ID,
    E_REF_UNDECLARED_INDEX_SET,
    E_REF_UNKNOWN_FAQ_NODE,
    E_REF_UNRESOLVED_JOIN_FACTOR,
)


def _agg(**kw):
    """A minimal aggregate node dict."""
    node = {"op": "aggregate", "args": []}
    node.update(kw)
    return node


def _eqn(lhs, rhs):
    return {"lhs": lhs, "rhs": rhs}


# --- (1) from_faq resolves to a specific node ------------------------------


def test_from_faq_resolves_to_node_by_id():
    # an index-set-producing node tagged id="edge_faq"; a derived index set
    # naming it via from_faq.
    producer = _agg(id="edge_faq", output_idx=["edge"], ranges={"f": {"from": "faces"}})
    model = {
        "index_sets": {
            "faces": {"kind": "interval", "size": 8},
            "edges": {"kind": "derived", "from_faq": "edge_faq"},
        },
        "equations": [_eqn(producer, 0)],
    }
    g = build_reference_graph(model, "M")

    from_faq = g.edges_of_kind(EdgeKind.FROM_FAQ)
    assert len(from_faq) == 1
    e = from_faq[0]
    assert e.source == f"{VertexKind.INDEX_SET}:edges"
    assert e.target == f"{VertexKind.NODE}:edge_faq"
    # the resolved target is the specific node carrying that id
    assert g.vertices[e.target].node_id == "edge_faq"
    assert g.vertices[e.target].op == "aggregate"
    # and it is queryable as a dependency edge: edges depends on the node.
    assert e.target in g.dependencies(f"{VertexKind.INDEX_SET}:edges")


def test_from_faq_unknown_node_id_errors():
    model = {
        "index_sets": {"edges": {"kind": "derived", "from_faq": "missing"}},
        "equations": [_eqn(_agg(id="present"), 0)],
    }
    with pytest.raises(ReferenceResolutionError) as exc:
        build_reference_graph(model, "M")
    assert exc.value.code == E_REF_UNKNOWN_FAQ_NODE


def test_duplicate_node_id_errors():
    model = {
        "equations": [
            _eqn(_agg(id="dup"), 0),
            _eqn(_agg(id="dup"), 0),
        ]
    }
    with pytest.raises(ReferenceResolutionError) as exc:
        build_reference_graph(model, "M")
    assert exc.value.code == E_REF_DUPLICATE_NODE_ID


# --- ranges[*].from resolves to an index set -------------------------------


def test_range_from_resolves_to_index_set():
    node = _agg(output_idx=["i"], ranges={"i": {"from": "cells"}})
    model = {
        "index_sets": {"cells": {"kind": "interval", "size": 4}},
        "equations": [_eqn(node, 0)],
    }
    g = build_reference_graph(model, "M")
    rf = g.edges_of_kind(EdgeKind.RANGE_FROM)
    assert len(rf) == 1
    assert rf[0].target == f"{VertexKind.INDEX_SET}:cells"
    # queryable: the node depends on the index set.
    assert rf[0].target in g.dependencies(rf[0].source)


def test_range_from_undeclared_index_set_errors():
    node = _agg(output_idx=["i"], ranges={"i": {"from": "nope"}})
    model = {"index_sets": {"cells": {"kind": "interval", "size": 4}}, "equations": [_eqn(node, 0)]}
    with pytest.raises(ReferenceResolutionError) as exc:
        build_reference_graph(model, "M")
    assert exc.value.code == E_REF_UNDECLARED_INDEX_SET


def test_dense_tuple_ranges_make_no_edge():
    # back-compat: a plain [lo, hi] range is not a reference, so no edge.
    node = _agg(output_idx=["i"], ranges={"i": [1, 64]})
    model = {"equations": [_eqn(node, 0)]}
    g = build_reference_graph(model, "M")
    assert g.edges == []


# --- (2) a join factor resolves to its referenced factor -------------------


def test_join_factor_resolves_to_arg_factor():
    # ESI-style aggregate(join...): the join references the factor "activity",
    # which the node names in its args.
    node = _agg(
        output_idx=["county"],
        ranges={"county": {"from": "county"}, "src": {"from": "sourceType"}},
        join=[{"on": [["activity", "sourceType"]]}],
        args=["activity", "base_rate"],
        expr={"op": "*", "args": ["activity", "base_rate"]},
    )
    model = {
        "index_sets": {
            "county": {"kind": "categorical", "members": ["A", "B"]},
            "sourceType": {"kind": "categorical", "members": ["x"]},
        },
        "equations": [_eqn(node, 0)],
    }
    g = build_reference_graph(model, "M")
    jf = g.edges_of_kind(EdgeKind.JOIN_FACTOR)
    assert len(jf) == 1
    assert jf[0].target == f"{VertexKind.FACTOR}:activity"
    assert g.vertices[jf[0].target].kind == VertexKind.FACTOR
    # queryable as a dependency of the node.
    assert jf[0].target in g.dependencies(jf[0].source)


def test_join_factor_resolves_to_range_key():
    # the RFC §7.2 spelling: the join references an index variable (range key).
    node = _agg(
        output_idx=["county"],
        ranges={"county": {"from": "county"}, "src": {"from": "sourceType"}},
        join=[{"on": [["src", "sourceType"]]}],
        args=["activity"],
    )
    model = {
        "index_sets": {
            "county": {"kind": "categorical", "members": ["A"]},
            "sourceType": {"kind": "categorical", "members": ["x"]},
        },
        "equations": [_eqn(node, 0)],
    }
    g = build_reference_graph(model, "M")
    jf = g.edges_of_kind(EdgeKind.JOIN_FACTOR)
    assert len(jf) == 1
    assert jf[0].target == f"{VertexKind.FACTOR}:src"


def test_join_factor_unresolved_errors():
    node = _agg(
        output_idx=["i"],
        ranges={"i": {"from": "cells"}},
        join=[{"on": [["ghost", "col"]]}],
        args=["activity"],
    )
    model = {"index_sets": {"cells": {"kind": "interval", "size": 2}}, "equations": [_eqn(node, 0)]}
    with pytest.raises(ReferenceResolutionError) as exc:
        build_reference_graph(model, "M")
    assert exc.value.code == E_REF_UNRESOLVED_JOIN_FACTOR


# --- (3) edges are queryable by the partition pass -------------------------


def test_graph_is_queryable_topologically():
    producer = _agg(id="edge_faq", output_idx=["edge"], ranges={"f": {"from": "faces"}})
    consumer = _agg(output_idx=["e"], ranges={"e": {"from": "edges"}})
    model = {
        "index_sets": {
            "faces": {"kind": "interval", "size": 8},
            "edges": {"kind": "derived", "from_faq": "edge_faq"},
        },
        "equations": [_eqn(producer, 0), _eqn(consumer, 0)],
    }
    g = build_reference_graph(model, "M")
    order = g.topological_order()  # raises on cycle; here acyclic
    # every vertex appears exactly once
    assert sorted(order) == sorted(g.vertices)
    # a dependency is emitted before its dependent:
    # consumer depends on index_set:edges, which depends on node:edge_faq.
    pos = {k: i for i, k in enumerate(order)}
    assert pos[f"{VertexKind.NODE}:edge_faq"] < pos[f"{VertexKind.INDEX_SET}:edges"]
    # faces (a plain interval) has no dependencies
    assert g.dependencies(f"{VertexKind.INDEX_SET}:faces") == []


# --- (4) a reference cycle is detectable -----------------------------------


def test_reference_cycle_is_detected():
    # derived set "edges" is materialised by node "edge_faq", but that node
    # iterates over "edges" — a circular materialisation (out-of-scope solve).
    producer = _agg(id="edge_faq", output_idx=["edge"], ranges={"e": {"from": "edges"}})
    model = {
        "index_sets": {"edges": {"kind": "derived", "from_faq": "edge_faq"}},
        "equations": [_eqn(producer, 0)],
    }
    g = build_reference_graph(model, "M")
    cyc = g.detect_cycle()
    assert cyc is not None
    assert cyc[0] == cyc[-1]  # closed path
    assert f"{VertexKind.NODE}:edge_faq" in cyc
    assert f"{VertexKind.INDEX_SET}:edges" in cyc
    # resolve_references surfaces it eagerly as E_REF_CYCLE. index_sets is
    # document-scoped (v0.8.0): declare it at the top level of the document.
    doc = {"index_sets": model["index_sets"], "models": {"M": model}}
    with pytest.raises(ReferenceResolutionError) as exc:
        resolve_references(doc)
    assert exc.value.code == E_REF_CYCLE


# --- additive: a document with no references yields an empty graph ----------


def test_no_references_empty_graph():
    model = {
        "variables": {"u": {"type": "state"}},
        "equations": [_eqn({"op": "D", "args": ["u"], "wrt": "t"}, -1)],
    }
    g = build_reference_graph(model, "M")
    assert g.edges == []
    assert g.detect_cycle() is None


def test_resolve_references_multi_model():
    # index_sets is document-scoped (v0.8.0): the single top-level registry is
    # shared by every model in the document.
    m1 = {
        "equations": [_eqn(_agg(output_idx=["i"], ranges={"i": {"from": "cells"}}), 0)],
    }
    m2 = {"equations": [_eqn({"op": "D", "args": ["u"], "wrt": "t"}, 0)]}
    graphs = resolve_references(
        {
            "index_sets": {"cells": {"kind": "interval", "size": 4}},
            "models": {"A": m1, "B": m2},
        }
    )
    assert set(graphs) == {"A", "B"}
    assert len(graphs["A"].edges_of_kind(EdgeKind.RANGE_FROM)) == 1
    assert graphs["B"].edges == []
