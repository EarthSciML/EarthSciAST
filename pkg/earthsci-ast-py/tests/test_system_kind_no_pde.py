"""esm 2.4.0: there is no "pde" system kind, and `grad` / `div` / `laplacian`
are ordinary user op names.

* The §6.3.1 derivation is three rows (sde, nonlinear, ode). A spatial
  derivative — a `D` with a spatial `wrt`, or any op NAME — does not affect it.
* A model that DECLARES `system_kind: "pde"` still loads, with ONE
  `deprecated_system_kind` warning per document naming each such model by JSON
  pointer. The declared value counts as absent: `declared_system_kind` returns
  None and `system_kind_mismatch` is never reported for it. The field is kept as
  written.
"""

from __future__ import annotations

import json
import warnings

from earthsci_ast import load_string
from earthsci_ast import op_registry as reg
from earthsci_ast.classification import (
    SYSTEM_KINDS,
    declared_system_kind,
    effective_system_kind,
    system_kind,
)
from earthsci_ast.parse import EsmDeprecationWarning
from earthsci_ast.serialize import to_json
from earthsci_ast.validation import validate_text


def _doc(rhs, *, declared: str | None = None, name: str = "M") -> dict:
    model: dict = {
        "variables": {
            "u": {"type": "unknown", "units": "1", "default": 0.0},
            "k": {"type": "parameter", "units": "1", "default": 1.0},
        },
        "equations": [{"lhs": {"op": "D", "args": ["u"], "wrt": "t"}, "rhs": rhs}],
    }
    if declared is not None:
        model["system_kind"] = declared
    return {"esm": "2.4.0", "metadata": {"name": "doc"}, "models": {name: model}}


def _load(doc: dict):
    with warnings.catch_warnings(record=True) as caught:
        warnings.simplefilter("always")
        f = load_string(json.dumps(doc))
    return f, [w for w in caught if str(w.message).startswith("deprecated_system_kind")]


def test_there_is_no_pde_kind():
    assert SYSTEM_KINDS == ("ode", "nonlinear", "sde")


def test_grad_div_laplacian_are_ordinary_unregistered_names():
    for op in ("grad", "div", "laplacian"):
        assert op not in reg.OPS
        assert op not in reg.REMOVED_OPS


def test_a_document_using_grad_loads_and_classifies_ode():
    rhs = {"op": "*", "args": ["k", {"op": "grad", "args": ["u"], "dim": "x"}]}
    f, dep = _load(_doc(rhs))
    assert dep == []
    assert system_kind(f.models["M"]) == "ode"


def test_a_spatial_d_does_not_make_a_model_pde():
    rhs = {"op": "D", "args": [{"op": "D", "args": ["u"], "wrt": "x"}], "wrt": "x"}
    f, _ = _load(_doc(rhs))
    assert system_kind(f.models["M"]) == "ode"
    steady = _doc(rhs)
    steady["models"]["M"]["equations"][0]["lhs"] = 0
    assert system_kind(steady["models"]["M"]) == "nonlinear"


def test_declared_pde_warns_once_and_counts_as_absent():
    doc = _doc("k", declared="pde")
    doc["models"]["Other"] = dict(doc["models"]["M"])
    f, dep = _load(doc)
    assert len(dep) == 1, [str(w.message) for w in dep]
    assert dep[0].category is EsmDeprecationWarning
    msg = str(dep[0].message)
    assert "/models/M/system_kind" in msg and "/models/Other/system_kind" in msg
    model = f.models["M"]
    assert model.system_kind == "pde"  # kept as written
    assert declared_system_kind(model) is None
    assert system_kind(model) == "ode"
    assert effective_system_kind(model) == "ode"
    # ... and survives a round trip unchanged.
    assert json.loads(to_json(f))["models"]["M"]["system_kind"] == "pde"


def test_declared_pde_is_never_a_mismatch():
    report = validate_text(json.dumps(_doc("k", declared="pde")))
    assert "system_kind_mismatch" not in [e.code for e in report.structural_errors]


def test_a_contradicting_declared_kind_is_still_a_mismatch():
    report = validate_text(json.dumps(_doc("k", declared="nonlinear")))
    assert "system_kind_mismatch" in [e.code for e in report.structural_errors]
