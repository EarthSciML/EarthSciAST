"""Tests for the build-time relational engine — the five value-invention
primitives and the cross-binding determinism contract (``CONFORMANCE_SPEC.md``
§5.5 = RFC ``semiring-faq-unified-ir`` §5.7).

Golden values are the DuckDB throwaway oracle (``SELECT DISTINCT … ORDER BY …``,
``dense_rank() OVER (ORDER BY …)``) — the same hand-derived goldens the Julia
binding (``packages/EarthSciSerialization.jl/test/relational_test.jl``) and the
cross-binding manifest (``tests/conformance/determinism/manifest.json``) assert
on. The only intentional difference from Julia is the rank emission base: Python
is **0-based**, Julia 1-based (``CONFORMANCE_SPEC.md`` §5.5.1 rule 3).
"""

from __future__ import annotations

import json
import operator
import os
import subprocess
import sys
from pathlib import Path

import pytest
from conftest import CONFORMANCE_DIR, REPO_ROOT

from earthsci_toolkit.relational import (
    FloatKeyError,
    canonical_index_set_json,
    distinct,
    equijoin,
    group_aggregate,
    rank,
    serialize_canonical,
    skolem,
    skolem_edge,
)

MANIFEST = CONFORMANCE_DIR / "determinism" / "manifest.json"
RUNNER = REPO_ROOT / "scripts" / "run-determinism-conformance.py"
SRC_DIR = Path(__file__).resolve().parents[1] / "src"

_first = operator.itemgetter(0)  # key   = row[0]
_second = operator.itemgetter(1)  # value = row[1]


# ── skolem — canonical tuple, never a hash (rule 4) ─────────────────────────


def test_skolem_edge_undirected_min_max():
    # undirected edge ⇒ (min, max); reversed orientation collapses to one key
    assert skolem_edge(5, 2) == (2, 5)
    assert skolem_edge(2, 5) == (2, 5)
    assert skolem_edge(7, 7) == (7, 7)
    assert skolem_edge(3, 8) == skolem_edge(8, 3)


def test_skolem_symmetric_and_directed():
    # symmetric, arity > 2: components sorted
    assert skolem((9, 1, 5), symmetric=True) == (1, 5, 9)
    assert skolem(("b", "a"), symmetric=True) == ("a", "b")
    # directed: order preserved, so (1,2) and (2,1) stay distinct
    assert skolem((1, 2)) == (1, 2)
    assert skolem((2, 1)) == (2, 1)
    assert skolem((2, 1)) != skolem((1, 2))


# ── distinct — sorted set semantics (rules 1, 2) ────────────────────────────


def test_distinct_scalars_sorted_unique():
    assert distinct([3, 1, 2, 1, 3]) == [1, 2, 3]
    # output IS sorted order, never first-seen
    assert distinct([9, 9, 4, 7, 4]) == [4, 7, 9]


def test_distinct_tuples_lexicographic():
    assert distinct([(2, 1), (1, 2), (2, 1)]) == [(1, 2), (2, 1)]


def test_distinct_strings_codepoint_order():
    # strings by Unicode code-point / UTF-8 byte order: "B" < "Z" < "a"
    assert distinct(["a", "Z", "B", "a"]) == ["B", "Z", "a"]


def test_distinct_empty():
    assert distinct([]) == []


def test_distinct_normalises_list_rows_to_tuples():
    # JSON arrays arrive as lists; they must canonicalise like tuples.
    assert distinct([[2, 1], [1, 2], [2, 1]]) == [(1, 2), (2, 1)]


# ── rank — dense IDs, Python 0-based (rule 3) ───────────────────────────────


def test_rank_zero_based_default():
    rk = rank([30, 10, 20, 10])
    assert rk.order == [10, 20, 30]
    assert rk.base == 0
    assert (rk.ids[10], rk.ids[20], rk.ids[30]) == (0, 1, 2)
    # __getitem__ convenience mirrors the Julia Ranking.id lookup
    assert (rk[10], rk[20], rk[30]) == (0, 1, 2)


def test_rank_base_pin_round_trip():
    rk0 = rank([30, 10, 20, 10])  # canonical 0-based
    rk1 = rank([30, 10, 20, 10], base=1)  # 1-based emission (e.g. Julia)
    assert (rk1.ids[10], rk1.ids[20], rk1.ids[30]) == (1, 2, 3)
    # reported − base is binding-independent
    for t in rk0.order:
        assert rk0.ids[t] - rk0.base == rk1.ids[t] - rk1.base


# ── equijoin — emit sorted by canonical key (rule 5) ────────────────────────


def test_equijoin_connectivity_inversion():
    # edges (eid, cell) ⋈ cells (cell, name)
    edges = [(101, 1), (102, 1), (103, 2)]
    cells = [(1, "A"), (2, "B")]
    got = equijoin(edges, cells, on_left=lambda e: e[1], on_right=lambda c: c[0])
    assert got == [
        ((101, 1), (1, "A")),
        ((102, 1), (1, "A")),
        ((103, 2), (2, "B")),
    ]


def test_equijoin_order_independent():
    edges = [(101, 1), (102, 1), (103, 2)]
    cells = [(1, "A"), (2, "B")]
    got = equijoin(edges, cells, on_left=lambda e: e[1], on_right=lambda c: c[0])
    # permute both sides → identical result
    got2 = equijoin(
        list(reversed(edges)),
        list(reversed(cells)),
        on_left=lambda e: e[1],
        on_right=lambda c: c[0],
    )
    assert got2 == got


def test_equijoin_unmatched_key_dropped():
    cells = [(1, "A"), (2, "B")]
    assert equijoin([(1, 99)], cells, on_left=lambda e: e[1], on_right=lambda c: c[0]) == []


# ── group_aggregate — semiring ⊕, sorted by key (rule 5) ────────────────────


def _rows_symbolic():
    return [("b", 3), ("a", 1), ("b", 4), ("a", 10), ("c", 5)]


def test_group_aggregate_sum_max_min():
    rows = _rows_symbolic()
    assert group_aggregate(rows, key=_first, value=_second, op=operator.add) == [
        ("a", 11),
        ("b", 7),
        ("c", 5),
    ]
    assert group_aggregate(rows, key=_first, value=_second, op=max) == [
        ("a", 10),
        ("b", 4),
        ("c", 5),
    ]
    assert group_aggregate(rows, key=_first, value=_second, op=min) == [
        ("a", 1),
        ("b", 3),
        ("c", 5),
    ]


def test_group_aggregate_order_independent():
    rows = _rows_symbolic()
    assert group_aggregate(
        list(reversed(rows)), key=_first, value=_second, op=operator.add
    ) == group_aggregate(rows, key=_first, value=_second, op=operator.add)


def test_group_aggregate_float_values_canonical_order():
    # keys integer, values float: permuted inputs give the identical float sum
    rows1 = [(1, 0.1), (1, 0.2), (1, 0.3)]
    rows2 = [(1, 0.3), (1, 0.1), (1, 0.2)]  # permuted
    g1 = group_aggregate(rows1, key=lambda r: r[0], value=lambda r: r[1], op=operator.add)
    g2 = group_aggregate(rows2, key=lambda r: r[0], value=lambda r: r[1], op=operator.add)
    assert g1 == g2
    # reduce is sequential in canonical (sorted) value order: ((0.1+0.2)+0.3)
    assert g1[0] == (1, ((0.1 + 0.2) + 0.3))


# ── mesh-edge enumeration vs DuckDB oracle + adversarial collapse (§5.5.4) ───


def _edges_of(faces):
    """Undirected edges of a triangle face list as canonical skolem tuples."""
    out = []
    for a, b, c in faces:
        out.extend([skolem_edge(a, b), skolem_edge(b, c), skolem_edge(c, a)])
    return out


def test_mesh_edge_enumeration_matches_oracle():
    # Two triangles sharing edge (2,3); faces → vertex triples.
    faces = [(1, 2, 3), (2, 4, 3)]
    golden_set = [(1, 2), (1, 3), (2, 3), (2, 4), (3, 4)]
    golden_json = "[[1,2],[1,3],[2,3],[2,4],[3,4]]"
    golden_ids = [0, 1, 2, 3, 4]  # Python 0-based

    base = _edges_of(faces)
    assert distinct(base) == golden_set
    assert canonical_index_set_json(base) == golden_json
    rk = rank(base)
    assert [rk.ids[e] for e in golden_set] == golden_ids


@pytest.mark.parametrize(
    "name,variant",
    [
        ("duplicate edges", _edges_of([(1, 2, 3), (2, 4, 3)]) * 2),
        ("reversed faces", _edges_of([(3, 2, 1), (3, 4, 2)])),
        ("permuted input", list(reversed(_edges_of([(1, 2, 3), (2, 4, 3)])))),
        ("permuted faces", _edges_of([(2, 4, 3), (1, 2, 3)])),
    ],
)
def test_mesh_edge_adversarial_collapse(name, variant):
    # All adversarial variants must collapse to the identical canonical output.
    golden_set = [(1, 2), (1, 3), (2, 3), (2, 4), (3, 4)]
    golden_json = "[[1,2],[1,3],[2,3],[2,4],[3,4]]"
    golden_ids = [0, 1, 2, 3, 4]
    assert distinct(variant) == golden_set
    assert canonical_index_set_json(variant) == golden_json
    rk = rank(variant)
    assert [rk.ids[e] for e in golden_set] == golden_ids


# ── canonical_index_set_json — compact JSON, sorted, escaped (§5.5.3) ────────


def test_canonical_index_set_json_forms():
    assert canonical_index_set_json([3, 1, 2, 1]) == "[1,2,3]"
    assert canonical_index_set_json([(2, 1), (1, 2)]) == "[[1,2],[2,1]]"
    # codepoint order + JSON-escape
    assert canonical_index_set_json(["a", "B"]) == '["B","a"]'
    assert canonical_index_set_json([]) == "[]"


def test_serialize_canonical_preserves_given_order():
    # serialize_canonical does NOT re-sort: it emits already-ordered output
    # (e.g. group_aggregate pairs) verbatim.
    pairs = [("B", 5), ("Z", 1), ("a", 9)]
    assert serialize_canonical(pairs) == '[["B",5],["Z",1],["a",9]]'


# ── negative controls (§5.5.4): float keys rejected (rule 1) ────────────────


def test_float_keys_rejected():
    with pytest.raises(FloatKeyError):
        distinct([1.0, 2.0])
    with pytest.raises(FloatKeyError):
        rank([(1, 2.5)])
    with pytest.raises(FloatKeyError):
        skolem_edge(1.0, 2.0)
    with pytest.raises(FloatKeyError):
        skolem((1, 2.0))
    with pytest.raises(FloatKeyError):
        equijoin([(1.0,)], [(1.0,)], on_left=lambda x: x[0], on_right=lambda x: x[0])
    with pytest.raises(FloatKeyError):
        group_aggregate([(1.5, 2)], key=lambda r: r[0], value=lambda r: r[1], op=operator.add)


def test_bool_keys_allowed():
    # Bool keys ARE allowed (bool is an int subclass): boolean-or-style grouping.
    # sorted({False, True}) == [False, True].
    got = group_aggregate(
        [(True, 1), (False, 2), (True, 3)],
        key=lambda r: r[0],
        value=lambda r: r[1],
        op=operator.add,
    )
    assert got == [(False, 2), (True, 4)]


# ── cross-binding determinism conformance (adapter vs golden manifest) ──────


def _load_manifest():
    with MANIFEST.open() as f:
        return json.load(f)


def test_adapter_matches_golden_manifest():
    """The Python adapter's output equals the committed golden byte-for-byte —
    i.e. matches the DuckDB oracle and (by construction) the Julia/Rust sets."""
    from earthsci_toolkit.cli.determinism_adapter import _compute_fixture

    manifest = _load_manifest()
    for fixture in manifest["fixtures"]:
        produced = _compute_fixture(fixture)
        expected = fixture["expected"]
        assert produced["serialized"] == expected["serialized"], fixture["id"]
        assert produced["index_set"] == expected["index_set"], fixture["id"]
        # Python emits 0-based already == canonical numbering.
        assert produced["dense_ids_canonical"] == expected["dense_ids_canonical"], fixture["id"]


def test_adapter_variants_collapse_to_golden():
    """Every adversarial input variant collapses to the identical golden output
    (order-, duplicate-, orientation-independence)."""
    from earthsci_toolkit.cli.determinism_adapter import _compute_fixture

    manifest = _load_manifest()
    for fixture in manifest["fixtures"]:
        golden = fixture["expected"]
        for vname, vpayload in (fixture["inputs"].get("variants") or {}).items():
            variant_fixture = dict(fixture)
            variant_fixture["inputs"] = {"canonical": vpayload}
            produced = _compute_fixture(variant_fixture)
            where = f"{fixture['id']}/{vname}"
            assert produced["serialized"] == golden["serialized"], where
            assert produced["dense_ids_canonical"] == golden["dense_ids_canonical"], where


@pytest.mark.skipif(not RUNNER.is_file(), reason="determinism runner not present")
def test_determinism_runner_accepts_python_adapter(tmp_path):
    """End-to-end: drive the real cross-binding runner with this adapter and
    assert it reports the Python binding as conformant to the golden."""
    env = dict(os.environ)
    env["EARTHSCI_DETERMINISM_ADAPTER_PYTHON"] = (
        f"{sys.executable} -m earthsci_toolkit.cli.determinism_adapter"
    )
    env["PYTHONPATH"] = os.pathsep.join([str(SRC_DIR), env.get("PYTHONPATH", "")]).rstrip(
        os.pathsep
    )
    report = tmp_path / "report.json"
    proc = subprocess.run(
        [sys.executable, str(RUNNER), "--bindings", "python", "--output", str(report)],
        cwd=str(REPO_ROOT),
        env=env,
        capture_output=True,
        text=True,
    )
    assert proc.returncode == 0, f"runner failed:\n{proc.stdout}\n{proc.stderr}"
    data = json.loads(report.read_text())
    py = data["bindings"]["python"]
    assert py["status"] == "ok", py
    for fid, fr in py["fixtures"].items():
        assert fr["status"] == "ok", (fid, fr)
