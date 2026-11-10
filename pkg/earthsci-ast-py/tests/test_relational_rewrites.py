"""The lib/relational.esm template rewrites of
``tests/conformance/relational_templates/rewrites/manifest.json`` against the
expected values the manifest's ``golden`` files hold.

Each rewrite spells value invention with lib/relational.esm templates
(``pair_key`` / ``edge_key`` keys, per-component join columns, the loop index
for a set's own rank, ``argmin_where`` for a gated arg-witness). Built with the
manifest's caller data under both compilers, it must reproduce the golden
derived set's members (its integer keys, decoded), the 1-based dense IDs, the
arg-witness buffers, and the right-hand side at the golden state, bit for bit.
A `value_invention_key_out_of_range` refusal names the column.
"""

from __future__ import annotations

import json
import struct
import warnings

import numpy as np
import pytest
from conftest import REPO_ROOT

from earthsci_ast import load_path, load_string
from earthsci_ast.flatten import flatten
from earthsci_ast.inline_tests import run_inline_tests
from earthsci_ast.numpy_interpreter import evaluate
from earthsci_ast.problem import esm_problem, observed_field
from earthsci_ast.simulation_array import _reconstruct_model_json
from earthsci_ast.value_invention import ValueInventionError, materialize_value_invention

REWRITES = REPO_ROOT / "tests" / "conformance" / "relational_templates" / "rewrites"
MANIFEST = json.loads((REWRITES / "manifest.json").read_text())["rewrites"]
LIBRARY = REPO_ROOT / "lib" / "relational.esm"
GOLDEN = {
    e["id"]: json.loads((REWRITES / e["golden"]).read_text()) for e in MANIFEST if e.get("golden")
}

CASES = [
    (e, i, case)
    for e in MANIFEST
    for i, case in enumerate(e["cases"])
    if not e["compare"].get("tier")
]


def _rewrite_path(entry: dict):
    return REPO_ROOT / entry["out"] if "out" in entry else REWRITES / f"{entry['id']}.esm"


def _ode_states(path, model: str) -> list[str]:
    """The `D` targets of ``model`` (a state the harness must give a start)."""
    doc = json.loads(path.read_text())
    out = []

    def target(lhs):
        if isinstance(lhs, dict):
            if lhs.get("op") == "D":
                a = lhs["args"][0]
                return a if isinstance(a, str) else a["args"][0]
            if lhs.get("op") == "faq":
                return target(lhs.get("expr"))
        return None

    for eq in doc["models"][model]["equations"]:
        t = target(eq.get("lhs"))
        if t is not None:
            out.append(t)
    return out


def _build(path, case: dict, compiler: str, model: str):
    ca = {f"{model}.{k}": np.asarray(v, dtype=float) for k, v in case["const_arrays"].items()}
    u0 = {f"{model}.{s}": 1.0 for s in _ode_states(path, model)}
    u0.update(case.get("u0", {}))
    doc = json.loads(path.read_text())
    doc["models"] = {model: doc["models"][model]}
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", RuntimeWarning)
        return esm_problem(
            doc,
            (0.0, 1.0),
            p=dict(case["params"]),
            u0=u0,
            model_name=model,
            const_arrays=ca,
            compiler=compiler,
            base_path=str(path.parent),
        )


def _decode(k: int, lo: list[int], n_b: int) -> tuple[int, int]:
    return (k // n_b + lo[0], k % n_b + lo[1])


def _bits(v) -> list[bytes]:
    return [struct.pack("<d", float(x)) for x in np.asarray(v, dtype=float).ravel()]


def _elem_key(name: str, model: str) -> str:
    """`Model.var[1, 2]` -> `var[1,2]`, the golden files' state-element key."""
    name = name[len(model) + 1 :] if name.startswith(model + ".") else name
    return name.replace(" ", "")


def _rhs_at(build, model: str, state: dict) -> dict:
    """The right-hand side at the golden probe state, keyed like it."""
    names = [_elem_key(n, model) for n in build.elem_names]
    assert sorted(names) == sorted(state), (names, sorted(state))
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", RuntimeWarning)
        dy = build.rhs_function(0.0, np.asarray([state[n] for n in names], dtype=float))
    return dict(zip(names, dy))


@pytest.mark.parametrize("entry,idx,case", CASES, ids=[f"{e['id']}-{i}" for e, i, _ in CASES])
@pytest.mark.parametrize("compiler", ["interpreter", "native"])
def test_rewrite_matches_the_golden(entry: dict, idx: int, case: dict, compiler: str) -> None:
    cmp = entry["compare"]
    model = entry["models"][0]
    gold = GOLDEN[entry["id"]]["cases"][idx]
    if cmp.get("vi_only"):
        _check_vi_only(entry, case, model, gold)
        return
    tp_prob = _build(_rewrite_path(entry), case, compiler, model)
    for s in cmp.get("sets", []):
        faq = s["faq"]
        tp_members = list(tp_prob.build.vi_members[faq])
        assert all(isinstance(m, int) for m in tp_members), tp_members
        assert tp_members == sorted(set(tp_members))
        decoded = [_decode(m, s["decode"]["lo"], s["decode"]["n_b"]) for m in tp_members]
        assert decoded == [tuple(m) for m in gold["sets"][faq]["members"]]
        assert tp_prob.build.derived_extents[faq] == gold["sets"][faq]["extent"]
    if "rank" in cmp:
        faq = cmp["rank"]["faq"]
        want = gold["rank"]["values"]
        got = observed_field(tp_prob, cmp["rank"]["variable"])
        assert _bits(got) == _bits(want)
        # rank_of over the template's own members returns the same IDs.
        members = list(tp_prob.build.vi_members[faq])
        assert [_rank_of(m, members) for m in members] == [float(x) for x in want]
    if "rank_lookup" in cmp:
        # A rank looked up against the derived set (rank_of_set over its members).
        got = np.asarray(observed_field(tp_prob, cmp["rank_lookup"]["variable"]), dtype=float)
        assert _bits(got) == _bits(gold["rank_lookup"]["values"])
    for a in cmp.get("assignments", []):
        tp_buf = np.asarray(observed_field(tp_prob, a["template"]), dtype=float)
        assert _bits(tp_buf) == _bits(gold["assignments"][a["template"]])
    if cmp.get("rhs"):
        g = gold["rhs"]
        want = [g["dy"][n] for n in sorted(g["dy"])]
        got = _rhs_at(tp_prob.build, model, g["state"])
        assert _bits([got[n] for n in sorted(g["dy"])]) == _bits(want)


def _check_vi_only(entry: dict, case: dict, model: str, gold: dict) -> None:
    """Value invention alone, for a document whose right-hand side needs data the
    manifest does not carry: the template form's expanded (flattened) model."""
    ca = {k: np.asarray(v, dtype=float) for k, v in case["const_arrays"].items()}
    ca.update({f"{model}.{k}": v for k, v in list(ca.items())})
    path = _rewrite_path(entry)
    flat = flatten(load_path(str(path)), base_path=str(path.parent))
    params = {**case["params"], **{f"{model}.{k}": v for k, v in case["params"].items()}}
    tp = materialize_value_invention(
        _reconstruct_model_json(flat), ca, params, index_sets=flat.index_sets
    )
    for s in entry["compare"]["sets"]:
        decoded = [_decode(m, s["decode"]["lo"], s["decode"]["n_b"]) for m in tp.members[s["faq"]]]
        assert decoded == [tuple(m) for m in gold["sets"][s["faq"]]["members"]]
        assert tp.extents[s["faq"]] == gold["sets"][s["faq"]]["extent"]


def _rank_of(x: int, members: list[int]) -> float:
    doc = {
        "esm": "1.1.0",
        "metadata": {"name": "rank_of_probe"},
        "models": {
            "M": {
                "expression_template_imports": [{"ref": str(LIBRARY)}],
                "variables": {"r": {"type": "unknown", "units": "1", "default": 0.0}},
                "equations": [
                    {
                        "lhs": {"op": "D", "args": ["r"], "wrt": "t"},
                        "rhs": {
                            "op": "apply_expression_template",
                            "args": [],
                            "name": "rank_of",
                            "bindings": {
                                "x": x,
                                "members": {"op": "const", "args": [], "value": members},
                                "n": len(members),
                            },
                        },
                    }
                ],
            }
        },
    }
    (eq,) = load_string(json.dumps(doc)).models["M"].equations
    return evaluate(eq.rhs, {})


@pytest.mark.parametrize(
    "entry",
    [e for e in MANIFEST if e["compare"].get("inline_tests") or e["compare"].get("load_only")],
    ids=lambda e: e["id"],
)
def test_rewrite_loads_and_runs_like_the_golden(entry: dict) -> None:
    path = _rewrite_path(entry)
    load_path(str(path))
    if entry["compare"].get("inline_tests"):
        tp = run_inline_tests(str(path), compiler="interpreter")
        # Integrator outputs: within each assertion's tolerance, not bit for bit.
        gold = GOLDEN[entry["id"]]["inline_tests"]
        assert len(tp) == len(gold)
        for r, g in zip(tp, gold):
            band = max(g["atol"], g["rtol"] * abs(g["actual"]))
            assert abs(r.actual - g["actual"]) <= band, (r.actual, g)


def test_out_of_range_key_component_names_the_column() -> None:
    entry = next(e for e in MANIFEST if e["id"] == "bin_skolem_spatial_join")
    doc = json.loads(_rewrite_path(entry).read_text())
    model = doc["models"]["BinSkolemSpatialJoin"]
    for eq in model["equations"]:
        rhs = eq["rhs"]
        if isinstance(rhs, dict) and rhs.get("distinct"):
            rhs["key"]["bindings"]["n_b"] = 2  # j = 3, 4 fall outside [1, 3)
    for ref in model["expression_template_imports"]:
        ref["ref"] = str(LIBRARY)
    case = entry["cases"][0]
    ca = {k: np.asarray(v, dtype=float) for k, v in case["const_arrays"].items()}
    with pytest.raises(ValueInventionError, match="value_invention_key_out_of_range") as exc:
        esm_problem(
            doc, (0.0, 1.0), p=dict(case["params"]), const_arrays=ca, compiler="interpreter"
        )
    assert exc.value.code == "value_invention_key_out_of_range"
    assert "candidate_set" in str(exc.value)
