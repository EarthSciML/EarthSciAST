"""Template rewrites of the skolem / rank / gated-argmin fixtures against the
op forms (``tests/conformance/relational_templates/rewrites/manifest.json``).

Each rewrite replaces the value-invention ops with lib/relational.esm templates
(``pair_key`` / ``edge_key`` keys, per-component join columns, the loop index
for a set's own rank, ``argmin_where`` for a gated arg-witness). Both forms are
built with the same caller data and must agree: the derived set's members (the
op's tuples against the template's integer keys, decoded), the 1-based dense
IDs, the arg-witness buffers, and the right-hand side at the initial state, bit
for bit. Both forms are also checked against the expected values the manifest's
``golden`` files hold (computed from the op form by the reference binding,
``rewrites/goldens.py``). A `value_invention_key_out_of_range` refusal names
the column.
"""

from __future__ import annotations

import json
import struct
import warnings

import numpy as np
import pytest
from conftest import REPO_ROOT

from earthsci_ast import load_path, load_string, relational
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
def test_rewrite_agrees_with_the_op_form(entry: dict, idx: int, case: dict, compiler: str) -> None:
    cmp = entry["compare"]
    model = entry["models"][0]
    gold = GOLDEN[entry["id"]]["cases"][idx]
    if cmp.get("vi_only"):
        _check_vi_only(entry, case, model, gold)
        return
    op_prob = _build(REPO_ROOT / entry["source"], case, "interpreter", model)
    tp_prob = _build(_rewrite_path(entry), case, compiler, model)
    for s in cmp.get("sets", []):
        faq = s["faq"]
        op_members = list(op_prob.build.vi_members[faq])
        tp_members = list(tp_prob.build.vi_members[faq])
        assert all(isinstance(m, int) for m in tp_members), tp_members
        assert tp_members == sorted(set(tp_members))
        decoded = [_decode(m, s["decode"]["lo"], s["decode"]["n_b"]) for m in tp_members]
        assert decoded == [tuple(m) for m in op_members]
        assert tp_prob.build.derived_extents[faq] == op_prob.build.derived_extents[faq]
        want = [tuple(m) for m in gold["sets"][faq]["members"]]
        assert [tuple(m) for m in op_members] == want, "op form vs golden"
        assert decoded == want, "template form vs golden"
        assert tp_prob.build.derived_extents[faq] == gold["sets"][faq]["extent"]
    if "rank" in cmp:
        faq = cmp["rank"]["faq"]
        op_members = [tuple(m) for m in op_prob.build.vi_members[faq]]
        op_ids = relational.rank(op_members, base=0)
        want = [op_ids[m] + 1 for m in op_members]  # the 0 -> 1 base shift
        got = observed_field(tp_prob, cmp["rank"]["variable"])
        assert list(np.asarray(got, dtype=float)) == [float(x) for x in want]
        assert [float(x) for x in want] == gold["rank"]["values"], "op form vs golden"
        assert _bits(got) == _bits(gold["rank"]["values"]), "template form vs golden"
        # rank_of over the template's own members returns the same IDs.
        members = list(tp_prob.build.vi_members[faq])
        assert [_rank_of(m, members) for m in members] == [float(x) for x in want]
    if "rank_lookup" in cmp:
        # A rank looked up against the derived set (rank_of_set over its
        # members): the op set's 0-based rank of each row's tuple, plus one.
        rl = cmp["rank_lookup"]
        op_members = [tuple(m) for m in op_prob.build.vi_members[rl["faq"]]]
        op_ids = relational.rank(op_members, base=0)
        cols = [np.asarray(case["const_arrays"][c], dtype=float) for c in rl["columns"]]
        want = np.vectorize(lambda *t: op_ids[tuple(sorted(int(x) for x in t))] + 1.0)(*cols)
        got = np.asarray(observed_field(tp_prob, rl["variable"]), dtype=float)
        assert _bits(got) == _bits(want), (got, want)
        assert _bits(want) == _bits(gold["rank_lookup"]["values"]), "op form vs golden"
    for a in cmp.get("assignments", []):
        # The op's buffer is a value-invention output, not an observed.
        src = json.loads((REPO_ROOT / entry["source"]).read_text())
        raw = {**src["models"][model], "index_sets": src["index_sets"]}
        ca = {k: np.asarray(v, dtype=float) for k, v in case["const_arrays"].items()}
        vi = materialize_value_invention(raw, ca, case["params"])
        op_buf = np.asarray(vi.assignments[a["op"]], dtype=float)
        tp_buf = np.asarray(observed_field(tp_prob, a["template"]), dtype=float)
        assert _bits(tp_buf) == _bits(op_buf), (tp_buf, op_buf)
        assert _bits(op_buf) == _bits(gold["assignments"][a["template"]]), "op form vs golden"
    if cmp.get("rhs"):
        b_op, b_tp = op_prob.build, tp_prob.build
        assert b_tp.elem_names == b_op.elem_names
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", RuntimeWarning)
            dy_op = b_op.rhs_function(0.0, np.asarray(b_op.y0, dtype=float))
            dy_tp = b_tp.rhs_function(0.0, np.asarray(b_tp.y0, dtype=float))
        assert _bits(dy_tp) == _bits(dy_op), (dy_tp, dy_op)
        g = gold["rhs"]
        want = [g["dy"][n] for n in sorted(g["dy"])]
        for form, b in (("op", b_op), ("template", b_tp)):
            got = _rhs_at(b, model, g["state"])
            assert _bits([got[n] for n in sorted(g["dy"])]) == _bits(want), f"{form} form vs golden"


def _check_vi_only(entry: dict, case: dict, model: str, gold: dict) -> None:
    """Value invention alone, for a document whose right-hand side needs data the
    manifest does not carry: the op form's raw model against the template form's
    expanded (flattened) model."""
    ca = {k: np.asarray(v, dtype=float) for k, v in case["const_arrays"].items()}
    ca.update({f"{model}.{k}": v for k, v in list(ca.items())})
    src = json.loads((REPO_ROOT / entry["source"]).read_text())
    op_model = {**src["models"][model], "index_sets": src["index_sets"]}
    op = materialize_value_invention(op_model, ca, case["params"])
    path = _rewrite_path(entry)
    flat = flatten(load_path(str(path)), base_path=str(path.parent))
    params = {**case["params"], **{f"{model}.{k}": v for k, v in case["params"].items()}}
    tp = materialize_value_invention(
        _reconstruct_model_json(flat), ca, params, index_sets=flat.index_sets
    )
    for s in entry["compare"]["sets"]:
        decoded = [_decode(m, s["decode"]["lo"], s["decode"]["n_b"]) for m in tp.members[s["faq"]]]
        assert decoded == [tuple(m) for m in op.members[s["faq"]]]
        assert tp.extents[s["faq"]] == op.extents[s["faq"]]
        want = [tuple(m) for m in gold["sets"][s["faq"]]["members"]]
        assert decoded == want, "template form vs golden"
        assert [tuple(m) for m in op.members[s["faq"]]] == want, "op form vs golden"
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
def test_rewrite_loads_and_runs_like_the_op_form(entry: dict) -> None:
    path = _rewrite_path(entry)
    load_path(str(path))
    if entry["compare"].get("inline_tests"):
        op = run_inline_tests(str(REPO_ROOT / entry["source"]), compiler="interpreter")
        tp = run_inline_tests(str(path), compiler="interpreter")
        assert [r.actual for r in tp] == [r.actual for r in op]
        # Integrator outputs: within each assertion's tolerance, not bit for bit.
        gold = GOLDEN[entry["id"]]["inline_tests"]
        for form, res in (("op", op), ("template", tp)):
            assert len(res) == len(gold), form
            for r, g in zip(res, gold):
                band = max(g["atol"], g["rtol"] * abs(g["actual"]))
                assert abs(r.actual - g["actual"]) <= band, (form, r.actual, g)


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


def test_golden_files_are_current() -> None:
    """The golden files are what rewrites/goldens.py computes from the op forms
    today (regenerate them with it, never by hand)."""
    import importlib.util

    spec = importlib.util.spec_from_file_location("rewrite_goldens", REWRITES / "goldens.py")
    goldens = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(goldens)
    for entry in MANIFEST:
        g = goldens.golden(entry)
        if g is None:
            assert not entry.get("golden"), entry["id"]
            continue
        assert entry.get("golden") == f"golden/{entry['id']}.json", entry["id"]
        assert (REWRITES / entry["golden"]).read_text() == goldens.render(g), entry["id"]
