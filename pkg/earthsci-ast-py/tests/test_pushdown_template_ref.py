"""The projection-pushdown desugar THROUGH surviving expression-template
references (esm-spec §9.6.4 Option B, CONFORMANCE_SPEC §5.5.7).

Option B has ``load`` PRESERVE ``apply_expression_template`` references so the
build boundary can expand them once. ``prepare`` therefore hands
``desugar_pushdown`` an UNEXPANDED document — and an author who factored a
binning body through a template used to hide the containment ``ifelse`` from the
recogniser, which then declined SILENTLY: no derived support set, no gate, and
the provider array fetched wholesale, with the numbers still correct.

Rule 4 ("patterns do not see through surviving references") governs the §9.6.3
rewrite-rule ENGINE. This is a different consumer and rule 2 governs it: a
reference DENOTES its expansion. The invariant pinned here is

    whether the pushdown fires MUST NOT depend on whether the author factored
    the binning body through a template

with the corpus fixture ``pushdown/template_body`` pinning the emitted document
cross-binding and this file covering what a golden cannot express: the second
binding spelling, the hard post-condition error, and the diagnostic split.
"""

from __future__ import annotations

import copy
import warnings

import pytest

from earthsci_ast.json_walk import ExpressionTemplateError
from earthsci_ast.pushdown_rewrite import desugar_pushdown, pushdown_diagnostics


def _ix(f, *args):
    return {"op": "index", "args": [f, *args]}


def _op(o, *args):
    return {"op": o, "args": list(args)}


def _apply(name, bindings):
    return {"op": "apply_expression_template", "args": [], "name": name, "bindings": dict(bindings)}


def _agg(output_idx, ranges, expr, reduce=None, args=()):
    d = {
        "op": "aggregate",
        "output_idx": list(output_idx),
        "ranges": ranges,
        "args": list(args),
        "expr": expr,
    }
    if reduce is not None:
        d["reduce"] = reduce
    return d


def _param(shape):
    return {"type": "parameter", "default": 0.0, "shape": list(shape)}


def _obs(shape):
    """The DECLARATION of an observed unknown. From esm 1.0.0 the body is NOT
    here — it is the variable's defining equation; see :func:`_define`."""
    return {"type": "unknown", "shape": list(shape)}


def _define(model, name, shape, expr):
    """Declare ``name`` an observed unknown of ``model`` and DEFINE it by the
    bare-variable-LHS equation whose LHS is ``name``, replacing any definition
    already there (these tests redeclare ``E_PM25`` over ``base_doc``'s)."""
    model["variables"][name] = _obs(shape)
    for eq in model["equations"]:
        if eq.get("lhs") == name:
            eq["rhs"] = expr
            return
    model["equations"].append({"lhs": name, "rhs": expr})


def _definition(model, name):
    """``name``'s defining right-hand side — where 0.x kept ``expression``."""
    for eq in model["equations"]:
        if eq.get("lhs") == name:
            return eq["rhs"]
    raise KeyError(f"{name} has no defining equation")


def _defs(doc):
    """The model's definitions as ``{name: rhs}``, dropping the structural
    equations (the generated ``distinct`` producer has no bare-variable LHS)."""
    eqs = doc["models"]["Binned"]["equations"]
    return {e["lhs"]: e["rhs"] for e in eqs if isinstance(e.get("lhs"), str)}


def _structural(doc):
    """The equations that are NOT definitions, in order."""
    eqs = doc["models"]["Binned"]["equations"]
    return [e for e in eqs if not isinstance(e.get("lhs"), str)]


def _contain():
    return _op(
        "and",
        _op("<=", _ix("src_W", "c"), _ix("px", "r")),
        _op("<", _ix("px", "r"), _ix("src_E", "c")),
        _op("<=", _ix("src_S", "c"), _ix("py", "r")),
        _op("<", _ix("py", "r"), _ix("src_N", "c")),
    )


def _eranges():
    return {"c": {"from": "src_cells"}, "r": {"from": "emis_records"}}


_EARGS = ["src_W", "src_S", "src_E", "src_N", "px", "py", "emis_annual"]


def base_doc():
    """The minimal forward document: one provider-backed SR array, one binning
    ``E[c]``, one ``conc[rcv]`` — the ``pushdown_gated_dense`` shape."""
    v = {}
    for n in ("src_W", "src_S", "src_E", "src_N"):
        v[n] = _param(["src_cells"])
    for n in ("px", "py", "emis_annual"):
        v[n] = _param(["emis_records"])
    v["SR_PM25"] = _param(["src_cells", "rcv_cells"])
    doc = {
        "esm": "1.0.0",
        "metadata": {"name": "pd_tmpl"},
        "index_sets": {
            "src_cells": {"kind": "interval", "size": 4},
            "rcv_cells": {"kind": "interval", "size": 2},
            "emis_records": {"kind": "interval", "size": 3},
        },
        "models": {"Binned": {"variables": v, "equations": []}},
    }
    m = doc["models"]["Binned"]
    _define(
        m,
        "E_PM25",
        ["src_cells"],
        _agg(
            ["c"],
            _eranges(),
            _op("*", _op("ifelse", _contain(), 1.0, 0.0), _ix("emis_annual", "r")),
            reduce="+",
            args=_EARGS,
        ),
    )
    _define(
        m,
        "conc_PM25",
        ["rcv_cells"],
        _agg(
            ["rcv"],
            {"s": {"from": "src_cells"}, "rcv": {"from": "rcv_cells"}},
            _op("*", _ix("SR_PM25", "s", "rcv"), _ix("E_PM25", "s")),
            reduce="+",
            args=["SR_PM25", "E_PM25"],
        ),
    )
    return doc


def test_bare_factor_name_bindings_are_repointed():
    """Spelling 1 — the binding IS the factor name. This is the corpus
    fixture's spelling; asserted here for the "identical to longhand except E"
    property, which the golden pins cross-binding."""
    longhand = base_doc()
    lr = desugar_pushdown(longhand, model_name="Binned")
    assert lr is not longhand

    d = base_doc()
    m = d["models"]["Binned"]
    tpl_contain = _op(
        "and",
        _op("<=", _ix("xmin", "c"), _ix("ptx", "r")),
        _op("<", _ix("ptx", "r"), _ix("xmax", "c")),
        _op("<=", _ix("ymin", "c"), _ix("pty", "r")),
        _op("<", _ix("pty", "r"), _ix("ymax", "c")),
    )
    m["expression_templates"] = {
        "bin_into_cell": {
            "params": ["xmin", "ymin", "xmax", "ymax", "ptx", "pty", "wgt"],
            "body": _op("*", _op("ifelse", tpl_contain, 1.0, 0.0), _ix("wgt", "r")),
        }
    }
    _define(
        m,
        "E_PM25",
        ["src_cells"],
        _agg(
            ["c"],
            _eranges(),
            _apply(
                "bin_into_cell",
                {
                    "xmin": "src_W",
                    "ymin": "src_S",
                    "xmax": "src_E",
                    "ymax": "src_N",
                    "ptx": "px",
                    "pty": "py",
                    "wgt": "emis_annual",
                },
            ),
            reduce="+",
            args=_EARGS,
        ),
    )
    tpl_before = copy.deepcopy(m["expression_templates"])

    r = desugar_pushdown(d, model_name="Binned")
    assert r is not d
    # everything but E_PM25's BODY (and the template block) matches the longhand
    # rewrite. The declarations now match exactly: the two forms differ in how the
    # binning body is written, which in 1.0.0 lives in the defining equation, so
    # even `E_PM25`'s declaration (re-pointed onto the derived axis either way) is
    # identical between them.
    rv, lv = r["models"]["Binned"]["variables"], lr["models"]["Binned"]["variables"]
    assert rv == lv
    assert r["metadata"]["x_esd"] == lr["metadata"]["x_esd"]
    assert r["index_sets"] == lr["index_sets"]
    # The generated `distinct` producer is identical…
    assert _structural(r) == _structural(lr)
    # …and among the DEFINITIONS only E_PM25's body differs.
    rdef, ldef = _defs(r), _defs(lr)
    assert set(rdef) == set(ldef)
    assert [k for k in sorted(rdef) if rdef[k] != ldef[k]] == ["E_PM25"]
    # the CALL SITE moved; the shared body did not (Option B survives)
    b = _definition(r["models"]["Binned"], "E_PM25")["expr"]["bindings"]
    assert b["xmin"] == "pd_cell__src_cells__src_W"
    assert b["ymax"] == "pd_cell__src_cells__src_N"
    assert b["ptx"] == "px"
    assert r["models"]["Binned"]["expression_templates"] == tpl_before
    assert desugar_pushdown(r) is r
    assert pushdown_diagnostics(d, model_name="Binned") == []


def test_subscripted_bindings_are_repointed():
    """Spelling 2 — the binding carries ``index(src_W, c)`` and the body names
    its params as plain operands."""
    d = base_doc()
    m = d["models"]["Binned"]
    m["expression_templates"] = {
        "bin2": {
            "params": ["lo_x", "lo_y", "hi_x", "hi_y", "x", "y", "wgt"],
            "body": _op(
                "*",
                _op(
                    "ifelse",
                    _op(
                        "and",
                        _op("<=", "lo_x", "x"),
                        _op("<", "x", "hi_x"),
                        _op("<=", "lo_y", "y"),
                        _op("<", "y", "hi_y"),
                    ),
                    1.0,
                    0.0,
                ),
                "wgt",
            ),
        }
    }
    _define(
        m,
        "E_PM25",
        ["src_cells"],
        _agg(
            ["c"],
            _eranges(),
            _apply(
                "bin2",
                {
                    "lo_x": _ix("src_W", "c"),
                    "lo_y": _ix("src_S", "c"),
                    "hi_x": _ix("src_E", "c"),
                    "hi_y": _ix("src_N", "c"),
                    "x": _ix("px", "r"),
                    "y": _ix("py", "r"),
                    "wgt": _ix("emis_annual", "r"),
                },
            ),
            reduce="+",
            args=_EARGS,
        ),
    )
    tpl_before = copy.deepcopy(m["expression_templates"])

    r = desugar_pushdown(d, model_name="Binned")
    assert r is not d
    rv = r["models"]["Binned"]["variables"]
    assert rv["E_PM25"]["shape"] == ["pd_support__src_cells"]
    edef = _definition(r["models"]["Binned"], "E_PM25")
    assert edef["ranges"]["c"]["from"] == "pd_support__src_cells"
    b = edef["expr"]["bindings"]
    assert b["lo_x"]["args"][0] == "pd_cell__src_cells__src_W"
    assert b["hi_y"]["args"][0] == "pd_cell__src_cells__src_N"
    assert b["x"]["args"][0] == "px"  # records untouched
    assert r["models"]["Binned"]["expression_templates"] == tpl_before
    assert desugar_pushdown(r) is r


def test_free_rect_in_template_body_is_rejected():
    """The rewrite edits call sites only (that is what keeps the body shared and
    singly-lowered), so a rect factor named FREE in a body cannot be re-pointed.
    Left alone it would index the compact per-support gathers with FULL-GRID
    positions — wrong numbers, silently. Hence an error, not a warning."""
    d = base_doc()
    m = d["models"]["Binned"]
    m["expression_templates"] = {
        "bin3": {
            "params": ["wgt"],
            "body": _op("*", _op("ifelse", _contain(), 1.0, 0.0), _ix("wgt", "r")),
        }
    }
    _define(
        m,
        "E_PM25",
        ["src_cells"],
        _agg(["c"], _eranges(), _apply("bin3", {"wgt": "emis_annual"}), reduce="+", args=_EARGS),
    )
    with pytest.raises(ExpressionTemplateError) as ei:
        desugar_pushdown(d, model_name="Binned")
    assert ei.value.code == "template_body_references_pushdown_rewritten_variable"
    assert "src_W" in str(ei.value)
    assert "E_PM25" in str(ei.value)
    assert "Bind the value through the template's params" in str(ei.value)


def test_dense_reduction_is_silent():
    """ "Not a join" is not a defect: an aggregate with no containment predicate
    is a legitimately dense factor and MUST NOT be reported."""
    d = base_doc()
    _define(
        d["models"]["Binned"],
        "E_PM25",
        ["src_cells"],
        _agg(
            ["c"],
            _eranges(),
            _op("*", _ix("emis_annual", "r"), 1.0),
            reduce="+",
            args=["emis_annual"],
        ),
    )
    assert pushdown_diagnostics(d, model_name="Binned") == []
    assert desugar_pushdown(d, model_name="Binned") is d


def test_unexpandable_reference_in_the_join_position_is_reported():
    """A surviving reference the detector could NOT see through — here because
    the registry is gone. The document IS join-shaped, so this is reported,
    naming the template, and the document comes back untouched."""
    d = base_doc()
    _define(
        d["models"]["Binned"],
        "E_PM25",
        ["src_cells"],
        _agg(["c"], _eranges(), _apply("gone", {"wgt": "emis_annual"}), reduce="+", args=_EARGS),
    )
    dg = pushdown_diagnostics(d, model_name="Binned")
    assert len(dg) == 1
    assert dg[0]["code"] == "pushdown_join_unrecognised"
    assert dg[0]["reason"] == "surviving_template_reference"
    assert dg[0]["template"] == "gone"
    assert dg[0]["variable"] == "E_PM25"
    assert dg[0]["array"] == "SR_PM25"
    assert dg[0]["index_set"] == "src_cells"
    with warnings.catch_warnings(record=True) as w:
        warnings.simplefilter("always")
        assert desugar_pushdown(d, model_name="Binned") is d
    assert any("join-shaped" in str(x.message) for x in w)
    assert any("WHOLESALE" in str(x.message) for x in w)
