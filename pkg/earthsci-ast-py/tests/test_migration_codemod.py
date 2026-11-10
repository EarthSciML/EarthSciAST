"""The esm 2.0.0 codemod (earthsci_ast.migration.migrate_document and
``python -m earthsci_ast.migrate``).

A 1.x document cannot be loaded at 2.0.0 when it uses a removed operator, so
nothing here evaluates the operator form. Instead each family is checked two
ways: the converted document is what it must be structurally (the template,
its bindings, the import), and it evaluates to the operator's pinned values —
the scenarios of ``tests/closed_functions/*/expected.json`` for ``fn``, the
§9.5.3 lowering for ``table_lookup`` (the codemod writes it, so a table lookup
must give the bits of the inline call it lowers to), exact dyadic areas for the
planar overlap, and Girard's theorem for the spherical one.
"""

from __future__ import annotations

import copy
import json
import math
import struct

import numpy as np
import pytest
from conftest import FIXTURES_ROOT

from earthsci_ast import load_string
from earthsci_ast.migration import (
    CODEMOD_TARGET_VERSION,
    REMOVED_OPS,
    CodemodError,
    MigrationError,
    find_removed,
    main,
    migrate_document,
    migrate_text,
)
from earthsci_ast.numpy_interpreter import evaluate
from earthsci_ast.parse import SCHEMA_VERSION
from earthsci_ast.problem import _rhs_of, esm_problem

CLOSED = FIXTURES_ROOT / "closed_functions"
DATETIME = [
    "year",
    "month",
    "day",
    "hour",
    "minute",
    "second",
    "day_of_year",
    "julian_day",
    "is_leap_year",
]


def _const(v):
    return {"op": "const", "args": [], "value": v}


def _doc(rhs, variables=None, **extra):
    """A 1.2.0 document whose model ``M`` defines ``r = rhs``."""
    variables = dict(variables or {})
    variables.setdefault("r", {"type": "unknown"})
    doc = {
        "esm": "1.2.0",
        "metadata": {"name": "codemod_probe"},
        "models": {"M": {"variables": variables, "equations": [{"lhs": "r", "rhs": rhs}]}},
    }
    doc.update(extra)
    return doc


def _params(*names):
    return {n: {"type": "parameter", "default": 0.0} for n in names}


def _converted_rhs(doc, **kw):
    """Convert ``doc`` and load it; the expanded right-hand side of ``r``."""
    out = migrate_document(doc, **kw).document
    out["esm"] = SCHEMA_VERSION
    return load_string(json.dumps(out)).models["M"].equations[0].rhs


def _bits(x):
    x = float(x)
    return "nan" if math.isnan(x) else struct.pack("<d", x).hex()


def _scenarios(path):
    data = json.loads(path.read_text())
    return data, [s for s in data["scenarios"] if "expected" in s]


def _numeric(v):
    if isinstance(v, list):
        return all(_numeric(x) for x in v)
    return isinstance(v, (int, float)) and not isinstance(v, bool)


# ---------------------------------------------------------------------------
# fn
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("name", DATETIME)
def test_datetime_call_becomes_the_calendar_template(name):
    doc = _doc({"op": "fn", "name": f"datetime.{name}", "args": ["tu"]}, _params("tu"))
    res = migrate_document(doc)
    model = res.document["models"]["M"]
    assert res.document["esm"] == CODEMOD_TARGET_VERSION
    assert model["equations"][0]["rhs"] == {
        "op": "apply_expression_template",
        "args": [],
        "name": name,
        "bindings": {"t": "tu"},
    }
    assert model["expression_template_imports"] == [{"ref": "esm:std/calendar.esm", "only": [name]}]
    assert list(model)[0] == "expression_template_imports"
    assert find_removed(res.document) == []


@pytest.mark.parametrize("name", DATETIME)
def test_datetime_template_gives_the_pinned_values(name):
    data, scenarios = _scenarios(CLOSED / "datetime" / name / "expected.json")
    rhs = _converted_rhs(
        _doc({"op": "fn", "name": f"datetime.{name}", "args": ["tu"]}, _params("tu"))
    )
    tol = data.get("tolerance", {})
    checked = 0
    for s in scenarios:
        (t,) = s["inputs"]
        # The templates are NaN at |t| >= 2^52 s, where the operator answered (MIGRATION.md).
        if not _numeric(t) or not abs(t) < 2.0**52:
            continue
        got = evaluate(rhs, {"tu": float(t)})
        exp = float(s["expected"])
        assert abs(got - exp) <= max(tol.get("abs", 0), tol.get("rel", 0) * abs(exp)), (
            s["name"],
            got,
            exp,
        )
        checked += 1
    assert checked > 5


def _interp_call(fn, inputs):
    """The `fn` node of a closed_functions scenario, arrays as consts and each
    scalar input a parameter ``q<i>``."""
    args, bindings = [], {}
    for i, v in enumerate(inputs):
        if isinstance(v, list):
            args.append(_const(v))
        else:
            args.append(f"q{i}")
            bindings[f"q{i}"] = float(v)
    return {"op": "fn", "name": fn, "args": args}, bindings


@pytest.mark.parametrize("fn", ["searchsorted", "linear", "bilinear"])
def test_interp_template_gives_the_pinned_values(fn):
    _, scenarios = _scenarios(CLOSED / "interp" / fn / "expected.json")
    checked = 0
    for s in scenarios:
        if not _numeric(s["inputs"]) or not _numeric(s["expected"]):
            continue
        call, bindings = _interp_call(f"interp.{fn}", s["inputs"])
        if any(isinstance(v, list) and len(v) == 0 for v in s["inputs"]):
            continue  # an empty axis has no const length to pass (n = 0)
        rhs = _converted_rhs(_doc(call, _params(*bindings)))
        got = evaluate(rhs, bindings)
        assert _bits(got) == _bits(s["expected"]), (s["name"], got, s["expected"])
        checked += 1
    assert checked > 5


def test_interp_calls_take_their_axis_lengths_from_the_consts():
    table2 = _const([[1.0, 2.0, 4.0], [3.0, 5.0, 9.0]])
    doc = _doc(
        {
            "op": "+",
            "args": [
                {
                    "op": "fn",
                    "name": "interp.linear",
                    "args": [_const([1.0, 2.0, 3.0]), _const([0.0, 1.0, 2.0]), "x"],
                },
                {
                    "op": "fn",
                    "name": "interp.bilinear",
                    "args": [table2, _const([0.0, 1.0]), _const([0.0, 0.5, 1.0]), "x", "y"],
                },
                {
                    "op": "fn",
                    "name": "interp.searchsorted",
                    "args": ["x", _const([0.0, 1.0, 2.0, 3.0])],
                },
            ],
        },
        _params("x", "y"),
    )
    res = migrate_document(doc)
    lin, bil, ss = res.document["models"]["M"]["equations"][0]["rhs"]["args"]
    assert lin["name"] == "linear" and lin["bindings"]["n"] == 3 and lin["bindings"]["x"] == "x"
    assert bil["name"] == "bilinear" and (bil["bindings"]["nx"], bil["bindings"]["ny"]) == (2, 3)
    assert (
        ss["name"] == "searchsorted"
        and ss["bindings"]["n"] == 4
        and ss["bindings"]["xs"]["value"] == [0.0, 1.0, 2.0, 3.0]
    )
    assert res.document["models"]["M"]["expression_template_imports"] == [
        {"ref": "esm:std/interp.esm", "only": ["linear", "bilinear", "searchsorted"]}
    ]
    assert res.counts == {
        "fn interp.linear": 1,
        "fn interp.bilinear": 1,
        "fn interp.searchsorted": 1,
    }


def test_nested_calls_are_converted_inside_out():
    inner = {"op": "fn", "name": "datetime.hour", "args": ["tu"]}
    doc = _doc(
        {
            "op": "fn",
            "name": "interp.linear",
            "args": [_const([0.5, 1.5]), _const([0.0, 23.0]), inner],
        },
        _params("tu"),
    )
    rhs = migrate_document(doc).document["models"]["M"]["equations"][0]["rhs"]
    assert rhs["bindings"]["x"]["name"] == "hour"
    imports = migrate_document(doc).document["models"]["M"]["expression_template_imports"]
    assert {e["ref"] for e in imports} == {"esm:std/calendar.esm", "esm:std/interp.esm"}


@pytest.mark.parametrize(
    "node, match",
    [
        ({"op": "fn", "name": "datetime.century", "args": ["x"]}, "no esm 2.0.0 replacement"),
        ({"op": "fn", "name": "constructor.toString", "args": []}, "no esm 2.0.0 replacement"),
        (
            {"op": "fn", "name": "interp.linear", "args": [_const([1.0, 2.0]), "x", "x"]},
            "must be a `const` array",
        ),
        (
            {"op": "fn", "name": "interp.linear", "args": [_const([1.0, 2.0]), _const([1.0, 2.0])]},
            "takes 3",
        ),
    ],
)
def test_fn_without_a_template_is_refused_with_its_path(node, match):
    with pytest.raises(CodemodError, match=match) as e:
        migrate_document(_doc(node, _params("x")))
    assert e.value.path == "/models/M/equations/0/rhs"


# ---------------------------------------------------------------------------
# function_tables / table_lookup
# ---------------------------------------------------------------------------

TABLES = {
    "sigma": {
        "axes": [{"name": "lam", "values": [1.0, 2.0, 4.0, 8.0]}],
        "interpolation": "linear",
        "data": [11.0, 10.0, 9.5, 8.75],
    },
    "F": {
        "axes": [
            {"name": "P", "values": [10.0, 100.0, 1000.0]},
            {"name": "c", "values": [0.1, 0.5, 1.0]},
        ],
        "interpolation": "bilinear",
        "outputs": ["NO2", "O3"],
        "data": [
            [[1.0, 1.5, 2.0], [1.1, 1.6, 2.1], [1.2, 1.7, 2.2]],
            [[2.0, 2.5, 3.0], [2.1, 2.6, 3.1], [2.2, 2.7, 3.2]],
        ],
    },
    "near": {
        "axes": [{"name": "p", "values": [0.0, 1.0, 3.0]}],
        "interpolation": "nearest",
        "data": [10.0, 20.0, 30.0],
    },
}


def _lookup(table, axes, output=None):
    node = {"op": "table_lookup", "args": [], "table": table, "axes": axes}
    if output is not None:
        node["output"] = output
    return node


def test_function_tables_block_is_removed_and_lookups_inlined():
    doc = _doc(_lookup("sigma", {"lam": "x"}), _params("x"), function_tables=copy.deepcopy(TABLES))
    res = migrate_document(doc)
    assert "function_tables" not in res.document
    rhs = res.document["models"]["M"]["equations"][0]["rhs"]
    assert rhs["name"] == "linear"
    assert rhs["bindings"]["table"] == _const([11.0, 10.0, 9.5, 8.75])
    assert rhs["bindings"]["axis"] == _const([1.0, 2.0, 4.0, 8.0])
    assert rhs["bindings"]["n"] == 4
    assert find_removed(res.document) == []


@pytest.mark.parametrize(
    "lookup, inline",
    [
        (
            _lookup("sigma", {"lam": "x"}),
            {
                "op": "fn",
                "name": "interp.linear",
                "args": [_const([11.0, 10.0, 9.5, 8.75]), _const([1.0, 2.0, 4.0, 8.0]), "x"],
            },
        ),
        (
            _lookup("F", {"c": "y", "P": "x"}, "O3"),
            {
                "op": "fn",
                "name": "interp.bilinear",
                "args": [
                    _const(TABLES["F"]["data"][1]),
                    _const([10.0, 100.0, 1000.0]),
                    _const([0.1, 0.5, 1.0]),
                    "x",
                    "y",
                ],
            },
        ),
        (
            _lookup("F", {"c": "y", "P": "x"}),
            {
                "op": "fn",
                "name": "interp.bilinear",
                "args": [
                    _const(TABLES["F"]["data"][0]),
                    _const([10.0, 100.0, 1000.0]),
                    _const([0.1, 0.5, 1.0]),
                    "x",
                    "y",
                ],
            },
        ),
    ],
    ids=["linear", "bilinear_named_output", "bilinear_omitted_output"],
)
def test_table_lookup_gives_the_bits_of_its_inline_lowering(lookup, inline):
    a = _converted_rhs(_doc(lookup, _params("x", "y"), function_tables=copy.deepcopy(TABLES)))
    b = _converted_rhs(_doc(inline, _params("x", "y")))
    for x in [-1.0, 1.0, 1.5, 3.0, 10.0, 55.0, 100.0, 999.0, 1e4]:
        for y in [0.0, 0.1, 0.3, 0.5, 0.75, 1.0, 2.0]:
            q = {"x": x, "y": y}
            assert _bits(evaluate(a, q)) == _bits(evaluate(b, q)), q


def test_nearest_table_lookup_is_the_section_9_5_3_tree():
    rhs = _converted_rhs(
        _doc(_lookup("near", {"p": "x"}), _params("x"), function_tables=copy.deepcopy(TABLES))
    )
    cases = {
        -5.0: 10.0,
        0.0: 10.0,
        0.4: 10.0,
        0.5: 10.0,
        0.6: 20.0,
        1.0: 20.0,
        2.0: 20.0,
        2.5: 30.0,
        9.0: 30.0,
    }
    for x, want in cases.items():
        assert evaluate(rhs, {"x": x}) == want, x
    assert math.isnan(evaluate(rhs, {"x": math.nan}))


def test_component_function_tables_are_read_and_removed():
    doc = _doc(_lookup("sigma", {"lam": 2.0}))
    doc["models"]["M"]["function_tables"] = {"sigma": copy.deepcopy(TABLES["sigma"])}
    res = migrate_document(doc)
    assert "function_tables" not in res.document["models"]["M"]
    assert res.document["models"]["M"]["equations"][0]["rhs"]["name"] == "linear"


@pytest.mark.parametrize(
    "table_patch, node, match",
    [
        ({"out_of_bounds": "error"}, _lookup("sigma", {"lam": "x"}), "out_of_bounds"),
        ({}, _lookup("nope", {"lam": "x"}), "unknown table"),
        ({}, _lookup("sigma", {"z": "x"}), "do not match"),
        ({}, _lookup("sigma", {"lam": "x"}, 1), "single-output"),
    ],
)
def test_table_lookups_without_a_template_form_are_refused(table_patch, node, match):
    tables = copy.deepcopy(TABLES)
    tables["sigma"].update(table_patch)
    with pytest.raises(CodemodError, match=match):
        migrate_document(_doc(node, _params("x"), function_tables=tables))


# ---------------------------------------------------------------------------
# geometry
# ---------------------------------------------------------------------------

SQUARES = {
    "src": [
        [[0.0, 0.0], [2.0, 0.0], [2.0, 2.0], [0.0, 2.0]],
        [[2.0, 0.0], [4.0, 0.0], [4.0, 2.0], [2.0, 2.0]],
    ],
    "tgt": [[[1.0, 1.0], [3.0, 1.0], [3.0, 3.0], [1.0, 3.0]]],
}


def _overlap_doc(manifold, src=None, tgt=None):
    src = src or SQUARES["src"]
    tgt = tgt or SQUARES["tgt"]
    return {
        "esm": "1.2.0",
        "metadata": {"name": "overlap_probe"},
        "index_sets": {
            "src_cells": {"kind": "interval", "size": len(src)},
            "tgt_cells": {"kind": "interval", "size": len(tgt)},
            "verts": {"kind": "interval", "size": len(src[0])},
            "xy": {"kind": "interval", "size": 2},
        },
        "models": {
            "M": {
                "variables": {
                    "src_poly": {"type": "unknown", "shape": ["src_cells", "verts", "xy"]},
                    "tgt_poly": {"type": "unknown", "shape": ["tgt_cells", "verts", "xy"]},
                    "A": {"type": "unknown", "shape": ["src_cells", "tgt_cells"]},
                    "s": {"type": "unknown", "shape": ["src_cells", "tgt_cells"], "default": 0.0},
                },
                "equations": [
                    {"lhs": "src_poly", "rhs": _const(src)},
                    {"lhs": "tgt_poly", "rhs": _const(tgt)},
                    {
                        "lhs": "A",
                        "rhs": {
                            "op": "faq",
                            "args": [],
                            "output_idx": ["i", "j"],
                            "ranges": {"i": {"from": "src_cells"}, "j": {"from": "tgt_cells"}},
                            "expr": {
                                "op": "polygon_intersection_area",
                                "manifold": manifold,
                                "args": [
                                    {"op": "index", "args": ["src_poly", "i"]},
                                    {"op": "index", "args": ["tgt_poly", "j"]},
                                ],
                            },
                        },
                    },
                    {
                        "lhs": {"op": "D", "args": ["s"], "wrt": "t"},
                        "rhs": {
                            "op": "faq",
                            "args": [],
                            "output_idx": ["i", "j"],
                            "ranges": {"i": {"from": "src_cells"}, "j": {"from": "tgt_cells"}},
                            "expr": {"op": "index", "args": ["A", "i", "j"]},
                        },
                    },
                ],
            }
        },
    }


def _du(doc):
    out = copy.deepcopy(doc)
    out["esm"] = SCHEMA_VERSION
    prob = esm_problem(out, (0.0, 1.0), compiler="interpreter")
    f, y0, _ = _rhs_of(prob)
    return np.asarray(f(0.0, np.asarray(y0, dtype=float)), dtype=float)


def test_planar_overlap_becomes_the_planar_template():
    res = migrate_document(_overlap_doc("planar"))
    model = res.document["models"]["M"]
    expr = model["equations"][2]["rhs"]["expr"]
    assert expr == {
        "op": "apply_expression_template",
        "args": [],
        "name": "overlap_area_planar",
        "bindings": {
            "ring_a": "src_poly",
            "cell_a": "i",
            "nv_a": 4,
            "ring_b": "tgt_poly",
            "cell_b": "j",
            "nv_b": 4,
        },
    }
    assert model["expression_template_imports"] == [
        {"ref": "esm:std/geometry.esm", "only": ["overlap_area_planar"]}
    ]
    assert _du(res.document).tolist() == [1.0, 1.0]


@pytest.mark.parametrize("manifold", ["spherical", "geodesic"])
def test_spherical_overlap_adds_unit_vector_stacks(manifold):
    # Two 15-degree meridian triangles tiling a 30-degree one: pi/12 sr each (Girard).
    src = [[[0.0, 0.0], [90.0, 0.0], [90.0, 15.0]], [[0.0, 0.0], [90.0, 15.0], [90.0, 30.0]]]
    tgt = [[[0.0, 0.0], [90.0, 0.0], [90.0, 30.0]]]
    res = migrate_document(_overlap_doc(manifold, src, tgt))
    doc = res.document
    model = doc["models"]["M"]
    assert doc["index_sets"]["unit_xyz"] == {"kind": "interval", "size": 3}
    assert model["variables"]["src_poly_unit"]["shape"] == ["src_cells", "verts", "unit_xyz"]
    assert model["variables"]["tgt_poly_unit"]["shape"] == ["tgt_cells", "verts", "unit_xyz"]
    expr = model["equations"][2]["rhs"]["expr"]
    assert expr["name"] == "overlap_area_spherical"
    assert (expr["bindings"]["ring_a"], expr["bindings"]["ring_b"]) == (
        "src_poly_unit",
        "tgt_poly_unit",
    )
    assert model["expression_template_imports"][0]["only"] == [
        "lonlat_to_unit",
        "overlap_area_spherical",
    ]
    du = _du(doc)
    assert np.allclose(du, [math.pi / 12, math.pi / 12], rtol=1e-9, atol=1e-15)


def test_a_bare_ring_operand_gets_a_one_cell_stack():
    doc = {
        "esm": "1.2.0",
        "metadata": {"name": "bare_rings"},
        "index_sets": {"v": {"kind": "interval", "size": 4}, "xy": {"kind": "interval", "size": 2}},
        "models": {
            "M": {
                "variables": {
                    "a": {"type": "unknown", "shape": ["v", "xy"]},
                    "b": {"type": "unknown", "shape": ["v", "xy"]},
                    "area": {"type": "unknown"},
                    "s": {"type": "unknown", "default": 0.0},
                },
                "equations": [
                    {"lhs": "a", "rhs": _const(SQUARES["src"][0])},
                    {"lhs": "b", "rhs": _const(SQUARES["tgt"][0])},
                    {
                        "lhs": "area",
                        "rhs": {
                            "op": "polygon_intersection_area",
                            "manifold": "planar",
                            "args": ["a", "b"],
                        },
                    },
                    {"lhs": {"op": "D", "args": ["s"], "wrt": "t"}, "rhs": "area"},
                ],
            }
        },
    }
    res = migrate_document(doc)
    out = res.document
    assert out["index_sets"]["one_cell"] == {"kind": "interval", "size": 1}
    assert out["models"]["M"]["variables"]["a_stack"]["shape"] == ["one_cell", "v", "xy"]
    b = out["models"]["M"]["equations"][2]["rhs"]["bindings"]
    assert (b["ring_a"], b["cell_a"], b["ring_b"], b["cell_b"]) == ("a_stack", 1, "b_stack", 1)
    assert _du(out).tolist() == [1.0]


@pytest.mark.parametrize(
    "mutate, match",
    [
        (lambda e: e.update(op="intersect_polygon"), "intersect_polygon"),
        (lambda e: e.update(manifold="K"), "not a literal"),
        (lambda e: e["args"].__setitem__(0, _const([[0.0, 0.0]])), "operand must be"),
    ],
)
def test_geometry_without_a_template_form_is_refused(mutate, match):
    doc = _overlap_doc("planar")
    mutate(doc["models"]["M"]["equations"][2]["rhs"]["expr"])
    with pytest.raises(CodemodError, match=match):
        migrate_document(doc)


# ---------------------------------------------------------------------------
# relational
# ---------------------------------------------------------------------------


def _relational_doc(equations, variables, index_sets):
    return {
        "esm": "1.2.0",
        "metadata": {"name": "relational_probe"},
        "index_sets": index_sets,
        "models": {"M": {"variables": variables, "equations": equations}},
    }


def test_argmin_and_argmax_become_the_templates():
    body = {"op": "index", "args": ["w", "g"]}
    for op, lo, hi in [("argmin", 1, 3), ("argmax", 1, 3), ("argmin", 2, 4)]:
        node = {"op": op, "args": ["w"], "arg": "g", "ranges": {"g": [lo, hi]}, "expr": body}
        rhs = migrate_document(
            _doc(node, {"w": {"type": "parameter", "shape": ["c"], "default": 0.0}})
        ).document["models"]["M"]["equations"][0]["rhs"]
        k = f"k_{op}_1"
        if lo == 1:
            assert rhs == {
                "op": "apply_expression_template",
                "args": [],
                "name": op,
                "bindings": {"f": {"op": "index", "args": ["w", k]}, "n": 3},
            }
        else:
            call, offset = rhs["args"]
            assert rhs["op"] == "+" and offset == lo - 1
            assert call["bindings"]["f"] == {
                "op": "index",
                "args": ["w", {"op": "+", "args": [k, lo - 1]}],
            }


def test_argmin_over_an_index_set_takes_its_size_and_returns_the_bits():
    doc = _relational_doc(
        [
            {
                "lhs": {"op": "D", "args": ["s"], "wrt": "t"},
                "rhs": {
                    "op": "argmin",
                    "args": ["w"],
                    "arg": "g",
                    "ranges": {"g": {"from": "gens"}},
                    "expr": {"op": "index", "args": ["w", "g"]},
                },
            }
        ],
        {
            "w": {"type": "parameter", "shape": ["gens"], "default": [3.0, 1.0, 1.0, 2.0]},
            "s": {"type": "unknown", "default": 0.0},
        },
        {"gens": {"kind": "interval", "size": 4}},
    )
    out = migrate_document(doc).document
    assert out["models"]["M"]["equations"][0]["rhs"]["bindings"]["n"] == 4
    assert _du(out).tolist() == [2.0]


def test_a_skolem_key_needs_bounds_and_becomes_a_pair_key():
    def doc(key_args):
        return _relational_doc(
            [
                {
                    "lhs": {"op": "index", "args": ["exists", "e"]},
                    "rhs": {
                        "op": "faq",
                        "id": "edge_set",
                        "args": ["lo", "hi"],
                        "semiring": "bool_and_or",
                        "distinct": True,
                        "output_idx": ["e"],
                        "ranges": {"f": {"from": "faces"}},
                        "key": {"op": "skolem", "label": "edge", "args": key_args},
                        "expr": {"op": "true", "args": []},
                    },
                }
            ],
            {
                "lo": {"type": "parameter", "shape": ["faces"]},
                "hi": {"type": "parameter", "shape": ["faces"]},
                "exists": {"type": "unknown", "shape": ["edges"]},
            },
            {
                "faces": {"kind": "interval", "size": 3},
                "edges": {"kind": "derived", "from_faq": "edge_set"},
            },
        )

    u, v, w = ({"op": "index", "args": [n, "f"]} for n in ("lo", "hi", "lo"))
    with pytest.raises(CodemodError, match="--key-bounds edge_set=pair"):
        migrate_document(doc([u, v]))
    key = migrate_document(
        doc([u, v]), key_bounds={"edge_set": {"kind": "pair", "lo": [1, 1], "n": [6, 6]}}
    ).document["models"]["M"]["equations"][0]["rhs"]["key"]
    assert key == {
        "op": "apply_expression_template",
        "args": [],
        "name": "pair_key",
        "bindings": {"a": u, "b": v, "lo_a": 1, "lo_b": 1, "n_a": 6, "n_b": 6},
    }
    key = migrate_document(
        doc([u, v]), key_bounds={"*": {"kind": "edge", "lo": 1, "n": 6}}
    ).document["models"]["M"]["equations"][0]["rhs"]["key"]
    assert key["name"] == "edge_key" and key["bindings"] == {"u": u, "v": v, "lo": 1, "n": 6}
    key = migrate_document(
        doc([u, v, w]),
        key_bounds={"edge_set": {"kind": "pair", "lo": [0, 1, 2], "n": [10, 20, 30]}},
    ).document["models"]["M"]["equations"][0]["rhs"]["key"]
    assert (
        key["bindings"]["n_a"] == 200 and key["bindings"]["lo_a"] == 0 and key["bindings"]["b"] == w
    )
    assert key["bindings"]["a"]["bindings"] == {
        "a": u,
        "b": v,
        "lo_a": 0,
        "lo_b": 1,
        "n_a": 10,
        "n_b": 20,
    }
    assert migrate_document(doc([u])).document["models"]["M"]["equations"][0]["rhs"]["key"] == u
    with pytest.raises(CodemodError, match="name no `distinct` producer"):
        migrate_document(
            doc([u, v]),
            key_bounds={
                "edge_set": {"kind": "pair", "lo": [1, 1], "n": [6, 6]},
                "other": {"kind": "pair", "lo": [1], "n": [1]},
            },
        )
    with pytest.raises(CodemodError, match="2\\^53"):
        migrate_document(
            doc([u, v]),
            key_bounds={"edge_set": {"kind": "pair", "lo": [0, 0], "n": [2**30, 2**30]}},
        )


def test_rank_over_its_own_set_is_the_zero_based_loop_index():
    rank_eq = {
        "lhs": {"op": "index", "args": ["dense_id", "e"]},
        "rhs": {
            "op": "faq",
            "args": [],
            "output_idx": ["e"],
            "ranges": {"e": {"from": "edges"}},
            "expr": {"op": "rank", "args": ["edges"]},
        },
    }
    doc = _relational_doc(
        [rank_eq], {"dense_id": {"type": "unknown"}}, {"edges": {"kind": "interval", "size": 4}}
    )
    out = migrate_document(doc).document["models"]["M"]
    assert out["equations"][0]["rhs"]["expr"] == {"op": "-", "args": ["e", 1]}
    assert out["variables"]["dense_id"]["shape"] == ["edges"]
    bad = copy.deepcopy(doc)
    bad["models"]["M"]["equations"][0]["rhs"]["expr"] = {
        "op": "+",
        "args": [{"op": "rank", "args": ["edges"]}, 1],
    }
    with pytest.raises(CodemodError, match="`rank` has a template form only"):
        migrate_document(bad)


def _binned_doc():
    def bin_of(x, y, s):
        return {
            "op": "skolem",
            "label": "bin",
            "args": [
                {
                    "op": "floor",
                    "args": [{"op": "/", "args": [{"op": "index", "args": [x, s]}, "binw"]}],
                },
                {
                    "op": "floor",
                    "args": [{"op": "/", "args": [{"op": "index", "args": [y, s]}, "binw"]}],
                },
            ],
        }

    dist = {
        "op": "abs",
        "args": [
            {
                "op": "-",
                "args": [
                    {"op": "index", "args": ["px", "i"]},
                    {"op": "index", "args": ["gx", "g"]},
                ],
            }
        ],
    }
    return _relational_doc(
        [
            {
                "lhs": {"op": "index", "args": ["point_bin", "i"]},
                "rhs": {
                    "op": "faq",
                    "args": ["px", "py"],
                    "output_idx": ["i"],
                    "ranges": {"i": {"from": "points"}},
                    "expr": bin_of("px", "py", "i"),
                },
            },
            {
                "lhs": {"op": "index", "args": ["gen_bin", "g"]},
                "rhs": {
                    "op": "faq",
                    "args": ["gx", "gy"],
                    "output_idx": ["g"],
                    "ranges": {"g": {"from": "gens"}},
                    "expr": bin_of("gx", "gy", "g"),
                },
            },
            {
                "lhs": {"op": "index", "args": ["assign", "i"]},
                "rhs": {
                    "op": "faq",
                    "args": ["px", "gx", "point_bin", "gen_bin"],
                    "output_idx": ["i"],
                    "ranges": {"i": {"from": "points"}},
                    "expr": {
                        "op": "argmin",
                        "args": ["px", "gx"],
                        "arg": "g",
                        "ranges": {"g": {"from": "gens"}},
                        "join": [{"on": [["point_bin", "gen_bin"]]}],
                        "expr": dist,
                    },
                },
            },
        ],
        {
            "px": {"type": "parameter", "shape": ["points"]},
            "py": {"type": "parameter", "shape": ["points"]},
            "gx": {"type": "parameter", "shape": ["gens"]},
            "gy": {"type": "parameter", "shape": ["gens"]},
            "binw": {"type": "parameter", "default": 1.0},
            "point_bin": {"type": "unknown", "shape": ["points"]},
            "gen_bin": {"type": "unknown", "shape": ["gens"]},
            "assign": {"type": "unknown", "shape": ["points"]},
        },
        {"points": {"kind": "interval", "size": 4}, "gens": {"kind": "interval", "size": 3}},
    )


def test_a_skolem_join_key_becomes_integer_columns_and_a_joined_argmin_argmin_where():
    out = migrate_document(_binned_doc()).document["models"]["M"]
    names = [eq["lhs"]["args"][0] for eq in out["equations"]]
    assert names == ["point_bin_c1", "point_bin_c2", "gen_bin_c1", "gen_bin_c2", "assign"]
    assert "point_bin" not in out["variables"] and out["variables"]["gen_bin_c2"]["shape"] == [
        "gens"
    ]
    assign = out["equations"][4]["rhs"]
    assert assign["args"] == [
        "px",
        "gx",
        "point_bin_c1",
        "point_bin_c2",
        "gen_bin_c1",
        "gen_bin_c2",
    ]
    call = assign["expr"]
    assert call["name"] == "argmin_where" and call["bindings"]["n"] == 3
    k = "k_argmin_where_1"
    assert call["bindings"]["p"] == {
        "op": "and",
        "args": [
            {
                "op": "==",
                "args": [
                    {"op": "index", "args": ["point_bin_c1", "i"]},
                    {"op": "index", "args": ["gen_bin_c1", k]},
                ],
            },
            {
                "op": "==",
                "args": [
                    {"op": "index", "args": ["point_bin_c2", "i"]},
                    {"op": "index", "args": ["gen_bin_c2", k]},
                ],
            },
        ],
    }
    assert {"op": "index", "args": ["gx", k]} in json.loads(
        json.dumps(call["bindings"]["f"]["args"][0]["args"])
    )
    assert out["expression_template_imports"] == [
        {"ref": "esm:std/relational.esm", "only": ["argmin_where"]}
    ]


def test_a_skolem_key_read_outside_a_join_is_refused():
    doc = _binned_doc()
    doc["models"]["M"]["equations"].append(
        {"lhs": "r", "rhs": {"op": "index", "args": ["point_bin", 1]}}
    )
    doc["models"]["M"]["variables"]["r"] = {"type": "unknown"}
    with pytest.raises(CodemodError, match="read outside `join.on`"):
        migrate_document(doc)


# ---------------------------------------------------------------------------
# imports, versions, formatting
# ---------------------------------------------------------------------------


def test_imports_merge_into_an_existing_entry_and_dodge_local_template_names():
    doc = _doc({"op": "fn", "name": "datetime.hour", "args": ["tu"]}, _params("tu"))
    doc["models"]["M"]["expression_template_imports"] = [
        {"ref": "esm:std/calendar.esm", "only": ["year"]}
    ]
    imports = migrate_document(doc).document["models"]["M"]["expression_template_imports"]
    assert imports == [{"ref": "esm:std/calendar.esm", "only": ["year", "hour"]}]

    doc = _doc({"op": "fn", "name": "datetime.hour", "args": ["tu"]}, _params("tu"))
    doc["models"]["M"]["expression_templates"] = {"hour": {"params": ["x"], "body": "x"}}
    model = migrate_document(doc).document["models"]["M"]
    assert model["equations"][0]["rhs"]["name"] == "std_calendar_hour"
    assert model["expression_template_imports"] == [
        {"ref": "esm:std/calendar.esm", "only": ["hour"], "rename": {"hour": "std_calendar_hour"}}
    ]


def test_a_template_library_gets_top_level_imports():
    doc = {
        "esm": "1.2.0",
        "metadata": {"name": "lib"},
        "expression_templates": {
            "local_hour": {
                "params": ["t"],
                "body": {"op": "fn", "name": "datetime.hour", "args": ["t"]},
            },
        },
    }
    out = migrate_document(doc).document
    assert out["expression_templates"]["local_hour"]["body"]["name"] == "hour"
    assert out["expression_template_imports"] == [{"ref": "esm:std/calendar.esm", "only": ["hour"]}]


def test_reaction_rates_are_converted():
    doc = {
        "esm": "1.2.0",
        "metadata": {"name": "rs"},
        "reaction_systems": {
            "R": {
                "species": {"A": {"default": 1.0}},
                "parameters": {"tu": {"default": 0.0}},
                "reactions": [
                    {
                        "id": "r1",
                        "substrates": [{"species": "A", "stoichiometry": 1}],
                        "products": None,
                        "rate": {"op": "fn", "name": "datetime.hour", "args": ["tu"]},
                    }
                ],
            }
        },
    }
    out = migrate_document(doc).document["reaction_systems"]["R"]
    assert out["reactions"][0]["rate"]["name"] == "hour"
    assert out["expression_template_imports"] == [{"ref": "esm:std/calendar.esm", "only": ["hour"]}]


def test_aggregate_becomes_faq():
    body = {"op": "aggregate", "args": [], "output_idx": [], "ranges": {"i": [1, 3]}, "expr": "i"}
    res = migrate_document(_doc(body))
    assert res.document["models"]["M"]["equations"][0]["rhs"]["op"] == "faq"
    assert res.counts == {"aggregate": 1}
    assert find_removed(res.document) == []


def test_a_bump_only_document_keeps_its_layout():
    text = '{\n  "esm": "1.1.0",\n  "metadata": {"name": "x"},\n  "models": {"M": {"variables": {}, "equations": [\n    {"lhs": "r", "rhs": {"op": "aggregate", "args": [], "output_idx": [], "expr": 1}}]}}\n}\n'
    new, res = migrate_text(text)
    assert new == text.replace('"1.1.0"', '"2.0.0"').replace('"aggregate"', '"faq"')
    assert res.counts == {"aggregate": 1}


def test_versions():
    clean = _doc(1.0)
    assert migrate_document(clean).document["esm"] == CODEMOD_TARGET_VERSION
    already = dict(clean, esm="2.0.0")
    res = migrate_document(already)
    assert res.document == already and not res.changed
    with pytest.raises(MigrationError, match="1.x"):
        migrate_document(dict(clean, esm="0.9.0"))
    with pytest.raises(MigrationError, match="not a version"):
        migrate_document(dict(clean, esm="one"))


def test_the_input_is_not_modified():
    doc = _doc({"op": "fn", "name": "datetime.hour", "args": ["tu"]}, _params("tu"))
    before = copy.deepcopy(doc)
    migrate_document(doc)
    assert doc == before


def test_text_keeps_indentation_and_escaping():
    doc = _doc({"op": "fn", "name": "datetime.hour", "args": ["tu"]}, _params("tu"))
    doc["metadata"]["description"] = "§9.2"
    for indent, ascii_only in [(1, True), (2, False), (4, True)]:
        text = json.dumps(doc, indent=indent, ensure_ascii=ascii_only) + "\n"
        new, _ = migrate_text(text)
        assert new.endswith("}\n")
        assert new.splitlines()[1].startswith(" " * indent + '"')
        assert ("\\u00a7" in new) == ascii_only
    compact, _ = migrate_text(json.dumps(doc, separators=(",", ":")))
    assert "\n" not in compact and compact.startswith('{"esm":"2.0.0"')


def test_find_removed_names_every_removed_op():
    for op in REMOVED_OPS:
        assert find_removed(_doc({"op": op, "args": []})) == [("/models/M/equations/0/rhs", op)]
    assert find_removed({"function_tables": {"T": {}}}) == [("/function_tables", "function_tables")]


def test_command_line(tmp_path, capsys):
    doc = _doc({"op": "fn", "name": "datetime.hour", "args": ["tu"]}, _params("tu"))
    src = tmp_path / "a.esm"
    src.write_text(json.dumps(doc, indent=2) + "\n")
    assert main([str(src), "--check"]) == 1
    assert json.loads(src.read_text()) == doc
    out = tmp_path / "b.esm"
    assert main([str(src), "-o", str(out)]) == 0
    assert json.loads(out.read_text())["esm"] == CODEMOD_TARGET_VERSION
    assert main([str(src)]) == 0
    assert json.loads(src.read_text()) == json.loads(out.read_text())
    assert main([str(src), "--check"]) == 0
    bad = tmp_path / "bad.esm"
    bad.write_text(
        json.dumps(_doc({"op": "intersect_polygon", "manifold": "planar", "args": ["a", "b"]}))
    )
    assert main([str(bad)]) == 2
    assert "intersect_polygon" in capsys.readouterr().err


def test_command_line_key_bounds(tmp_path):
    from earthsci_ast.migration import _parse_key_bounds

    assert _parse_key_bounds(["s=pair:1:4,0:3", "e=edge:1:6"]) == {
        "s": {"kind": "pair", "lo": [1, 0], "n": [4, 3]},
        "e": {"kind": "edge", "lo": 1, "n": 6},
    }
    for bad in ["s", "s=tuple:1:2", "s=pair:1", "s=pair:a:b", "e=edge:1:2,1:2"]:
        with pytest.raises(ValueError):
            _parse_key_bounds([bad])
