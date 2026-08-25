"""Unit tests for :mod:`earthsci_ast.reference_resolution`.

Covers the four acceptance criteria of the node-addressing bead (RFC
``semiring-faq-unified-ir`` §6.1):

1. a derived index set resolves its ``from_faq`` to a specific node;
2. a join factor resolves to its referenced factor;
3. references are edges queryable by the partition pass;
4. a reference cycle is detectable.
"""

from __future__ import annotations

import pytest

from earthsci_ast.reference_resolution import (
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
        "variables": {"u": {"type": "unknown"}},
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


# --- from_faq resolves at DOCUMENT scope (esm-spec.md §9.7.5) ---------------
#
# `index_sets` is a document-scoped registry, so a `kind:"derived"` entry is
# visible to every model and its producing node may live in ANY of them. Until
# this ruling every binding resolved `from_faq` against one model's nodes, which
# made the cross-model shape unresolvable. The consequence: node ids are unique
# per DOCUMENT, not per model.


def test_from_faq_resolves_a_producer_in_another_model():
    producer = {
        "equations": [
            _eqn(_agg(id="edge_faq", output_idx=["edge"], ranges={"f": {"from": "faces"}}), 0)
        ]
    }
    consumer = {
        "equations": [_eqn(_agg(output_idx=[], ranges={"e": {"from": "edges"}}), 0)],
    }
    doc = {
        "index_sets": {
            "faces": {"kind": "interval", "size": 8},
            "edges": {"kind": "derived", "from_faq": "edge_faq"},
        },
        "models": {"Consumer": consumer, "Producer": producer},
    }
    graphs = resolve_references(doc)
    # BOTH graphs carry the from_faq edge: the registry entry is document-scoped,
    # so every model sees the same derived set and the same producer.
    for name in ("Consumer", "Producer"):
        faq = graphs[name].edges_of_kind(EdgeKind.FROM_FAQ)
        assert len(faq) == 1, name
        assert faq[0].source == f"{VertexKind.INDEX_SET}:edges"
        assert faq[0].target == f"{VertexKind.NODE}:edge_faq"
    # the consumer's graph gained a real vertex for the foreign producer, so the
    # partition pass can walk index_set -> node across the model boundary.
    v = graphs["Consumer"].vertices[f"{VertexKind.NODE}:edge_faq"]
    assert v.node_id == "edge_faq"
    assert v.path == "models/Producer/equations/0/lhs"


def test_from_faq_naming_no_node_in_the_document_still_errors():
    doc = {
        "index_sets": {"edges": {"kind": "derived", "from_faq": "nowhere"}},
        "models": {
            "A": {"equations": [_eqn(_agg(id="here"), 0)]},
            "B": {"equations": [_eqn(_agg(id="there"), 0)]},
        },
    }
    with pytest.raises(ReferenceResolutionError) as exc:
        resolve_references(doc)
    assert exc.value.code == E_REF_UNKNOWN_FAQ_NODE


def test_duplicate_node_id_across_two_models_errors():
    # Same id in two different models. Legal before the §9.7.5 ruling, a
    # load-time error now: one document-wide id namespace cannot hold two.
    doc = {
        "models": {
            "A": {"equations": [_eqn(_agg(id="dup"), 0)]},
            "B": {"equations": [_eqn(_agg(id="dup"), 0)]},
        }
    }
    with pytest.raises(ReferenceResolutionError) as exc:
        resolve_references(doc)
    assert exc.value.code == E_REF_DUPLICATE_NODE_ID
    assert "dup" in str(exc.value)


def test_cross_model_from_faq_corpus_fixture_resolves():
    """The shared cross-binding fixture for the §9.7.5 ruling."""
    from conftest import load_fixture

    doc = load_fixture("valid/aggregate/cross_model_from_faq.esm")
    graphs = resolve_references(doc)
    assert set(graphs) == {"EdgeProducer", "FluxConsumer"}
    faq = graphs["FluxConsumer"].edges_of_kind(EdgeKind.FROM_FAQ)
    assert [(e.source, e.target) for e in faq] == [
        (f"{VertexKind.INDEX_SET}:edges", f"{VertexKind.NODE}:edge_enum")
    ]


def test_wildfire_fixture_resolves_fully():
    """CORPUS_DEFECTS #2 AND #3 are both fixed on this fixture.

    It was the SECOND instance of #3, masked until #2 landed:

    * #2 — ``rg_candidate_pairs.from_faq`` names ``rg_candidate_set``, which
      lives in ``OceanDynamics`` while the registry entry is document-scoped.
    * #3 — that producing node carries
      ``join.on == [["rg_src_bin", "rg_tgt_bin"]]``, naming declared model
      VARIABLES (per-cell value-invention bin buffers written by equations 0 and
      1) rather than node-local binders. Both columns now resolve through the
      variable class of ``join_binder_class``.
    """
    from conftest import load_fixture

    doc = load_fixture("valid/wildfire_atmosphere_ocean.esm")
    graphs = resolve_references(doc)
    ocean = graphs["OceanDynamics"]
    targets = {e.target for e in ocean.edges_of_kind(EdgeKind.JOIN_FACTOR)}
    assert f"{VertexKind.FACTOR}:rg_src_bin" in targets


def test_conservative_regrid_assembly_resolves():
    """The other instance of CORPUS_DEFECTS #3.

    Six aggregates in ``ConservativeRegridAssembly`` join on
    ``[["src_bin", "tgt_bin"]]``; both are declared model variables shaped over
    the join's range index sets.
    """
    from conftest import load_fixture

    doc = load_fixture("valid/geometry/conservative_regrid_assembly.esm")
    resolve_references(doc)


# --- the four join binder classes (esm-spec §4.9.5 / CONFORMANCE_SPEC §5.5.6) -


def _four_class_doc(on):
    """One document declaring all four binder classes.

    A variable (``bin``), an index set (``cells``), a bound range (``i``) and a
    string factor arg (``w``) — so every registry the check consults is
    non-empty and the check is genuinely reached.
    """
    return {
        "index_sets": {"cells": {"kind": "interval", "size": 4}},
        "models": {
            "M": {
                "variables": {"bin": {"type": "parameter"}, "w": {"type": "parameter"}},
                "equations": [
                    {
                        "lhs": "y",
                        "rhs": {
                            "op": "aggregate",
                            "id": "j",
                            "args": ["w"],
                            "output_idx": [],
                            "ranges": {"i": {"from": "cells"}},
                            "join": [{"on": [list(on)]}],
                        },
                    }
                ],
            }
        },
    }


@pytest.mark.parametrize(
    "on",
    [
        ("i", "i"),  # 1. node-local binder (ranges key)
        ("w", "w"),  # 2. node-local string factor arg
        ("bin", "bin"),  # 3. declared model variable — the defect-#3 class
        ("cells", "cells"),  # 4. document-scoped index set
    ],
)
def test_join_binder_classes_all_resolve_on_both_columns(on):
    resolve_references(_four_class_doc(on))


@pytest.mark.parametrize("on", [("no_such_name", "bin"), ("bin", "no_such_name")])
def test_join_binder_classes_still_reject_an_undefined_name(on):
    """The NEGATIVE guard on the widened scope.

    Consulting the variable and index-set registries must not degrade into
    "accept any string": a name in NONE of the four classes is still a typo, on
    either key column. The right column was never validated before this fix.
    """
    with pytest.raises(ReferenceResolutionError) as exc:
        resolve_references(_four_class_doc(on))
    assert exc.value.code == E_REF_UNRESOLVED_JOIN_FACTOR
    assert "no_such_name" in str(exc.value)


def test_model_nested_index_sets_merge_over_the_document_registry():
    """The document registry is the base; a pre-0.8.0 model-nested entry wins.

    Python was the odd binding out: a supplied document registry made the
    model-nested key invisible entirely, so a ``ranges[*].from`` naming a
    model-nested-only set raised ``undeclared_index_set`` where Julia,
    TypeScript, Rust and Go all resolved it.
    """
    node = _agg(output_idx=["i"], ranges={"i": {"from": "cells"}})
    # (a) model-nested only, with a document registry present but empty.
    doc = {
        "index_sets": {},
        "models": {"M": {"index_sets": {"cells": {"kind": "interval", "size": 4}},
                         "equations": [_eqn(node, 0)]}},
    }
    assert len(resolve_references(doc)["M"].edges_of_kind(EdgeKind.RANGE_FROM)) == 1
    # (b) declared in both: the MODEL entry wins.
    doc = {
        "index_sets": {"cells": {"kind": "interval", "size": 9}},
        "models": {"M": {"index_sets": {"cells": {"kind": "derived", "from_faq": "nope"}},
                         "equations": [_eqn(node, 0)]}},
    }
    with pytest.raises(ReferenceResolutionError) as exc:
        resolve_references(doc)
    assert exc.value.code == E_REF_UNKNOWN_FAQ_NODE
