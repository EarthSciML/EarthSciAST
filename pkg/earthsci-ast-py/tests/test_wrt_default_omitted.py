"""esm-spec §4.2: on a ``D`` node an ABSENT ``wrt`` MEANS ``t``.

Regression for EarthSciAST#407. Python did not merely mishandle the default, it
refused the document outright::

    ParseError: Operator 'D' requires 'wrt' field to be specified

raised from ``parse.py`` before any consumer could apply a default at all — so
a document the schema accepts, and that the Go and TypeScript bindings load and
classify correctly, could not be read here in either its scalar or its shaped
form. The second half of the fix is in the SymPy bridge, which carried the same
rejection one layer down (``expression.py``: ``if not expr.wrt: raise``), and
which only became reachable once the parse gate was lifted.

``wrt`` is deliberately left ``None`` on the parsed node rather than
materialized to ``"t"``: the canonical encoding emits ``wrt`` whenever it is
set, so filling it in would make Python's round-trip of a document differ from
the other bindings' byte for byte.

Both shapes are covered, each against its explicitly-spelled twin, so the two
spellings cannot drift apart.
"""

from __future__ import annotations

import json

import pytest
from conftest import CONFORMANCE_DIR, REPO_ROOT

from earthsci_ast import classification as C
from earthsci_ast.canonicalize import canonical_json
from earthsci_ast.esm_types import ExprNode
from earthsci_ast.inline_tests import run_inline_tests
from earthsci_ast.parse import _parse_expression, load_path

# The scalar and shaped halves live in separate shared fixtures because the
# ``tests/simulation/`` corpus's generic runner drives a SCALAR backend with no
# ``faq`` evaluator; the shaped pair is registered in the ``simulate_faq``
# conformance manifest instead.
SCALAR_FIXTURE = REPO_ROOT / "tests" / "simulation" / "wrt_default_omitted.esm"
# The shaped pair is two FILES, not two models of one file: every runner binds
# the per-cell initial conditions by bare name, which is ambiguous when two
# models in one document both declare ``x``.
SHAPED_OMITTED = REPO_ROOT / "tests" / "fixtures" / "faq" / "28_wrt_default_omitted_shaped.esm"
SHAPED_EXPLICIT = REPO_ROOT / "tests" / "fixtures" / "faq" / "29_wrt_default_explicit_shaped.esm"
CLASSIFICATION_FIXTURE = CONFORMANCE_DIR / "classification" / "fixtures" / "wrt_default_omitted.esm"


def test_a_d_node_without_wrt_parses() -> None:
    """The short spelling is a legal node, not a parse error."""
    node = _parse_expression({"op": "D", "args": ["z"]})
    assert isinstance(node, ExprNode)
    assert node.op == "D"
    assert node.wrt is None, "the default belongs at the consumer, not on the node"


def test_the_absent_wrt_is_not_materialized_into_the_canonical_form() -> None:
    """Round-tripping must not invent a field the author did not write."""
    omitted = canonical_json(_parse_expression({"op": "D", "args": ["z"]}))
    explicit = canonical_json(_parse_expression({"op": "D", "args": ["z"], "wrt": "t"}))
    assert json.loads(omitted) == {"args": ["z"], "op": "D"}
    assert json.loads(explicit) == {"args": ["z"], "op": "D", "wrt": "t"}


@pytest.mark.parametrize(
    ("model", "ode_states", "system_kind"),
    [
        ("ScalarWrtOmitted", ["z"], "ode"),
        ("ScalarWrtExplicit", ["z"], "ode"),
        ("ShapedWrtOmitted", ["x"], "ode"),
        ("ShapedWrtExplicit", ["x"], "ode"),
        # The complement, which stops an over-broad fix: a SPATIAL `wrt` is
        # still not a time derivative.
        ("SpatialControl", [], "pde"),
    ],
)
def test_classification_reads_both_spellings_the_same(
    model: str, ode_states: list[str], system_kind: str
) -> None:
    doc = load_path(str(CLASSIFICATION_FIXTURE))
    m = doc.models[model]
    assert sorted(C.ode_states(m)) == ode_states
    assert C.system_kind(m) == system_kind


def _run(fixture, model: str) -> list[tuple[str, float, float]]:
    """Every inline-test assertion of one model, demanding it passed."""
    results = run_inline_tests(str(fixture), model_name=model)
    assert results, f"{model}: the fixture declares inline tests but none ran"
    for r in results:
        assert r.passed, f"{model}/{r.test_id}[{r.assertion_idx}]: {r.message}"
    return [(r.variable, r.time, r.actual) for r in results]


@pytest.mark.parametrize(
    ("fa", "omitted", "fb", "explicit"),
    [
        (SCALAR_FIXTURE, "ScalarWrtOmitted", SCALAR_FIXTURE, "ScalarWrtExplicit"),
        (SHAPED_OMITTED, "ShapedWrtOmitted", SHAPED_EXPLICIT, "ShapedWrtExplicit"),
    ],
)
def test_both_spellings_integrate_identically(fa, omitted: str, fb, explicit: str) -> None:
    a = _run(fa, omitted)
    b = _run(fb, explicit)
    assert len(a) == len(b)
    for (va, ta, xa), (vb, tb, xb) in zip(a, b):
        assert (va, ta) == (vb, tb), "the paired assertions are not aligned"
        assert xa == pytest.approx(xb, rel=1e-9, abs=1e-12)


def test_the_sympy_bridge_applies_the_same_default() -> None:
    """``to_sympy`` on a structural ``D`` no longer needs an explicit ``wrt``."""
    import sympy as sp

    from earthsci_ast.expression import to_sympy

    omitted = to_sympy(_parse_expression({"op": "D", "args": ["z"]}))
    explicit = to_sympy(_parse_expression({"op": "D", "args": ["z"], "wrt": "t"}))
    assert isinstance(omitted, sp.Derivative)
    assert omitted == explicit


def test_unit_propagation_applies_the_same_default() -> None:
    """``D(h)`` divides by the unit of ``t`` exactly as ``D(h, wrt=t)`` does.

    The dimensional rule in ``units.py`` short-circuited on a falsy ``wrt``
    (``not wrt``) BEFORE any default could be applied, so the derivative's
    dimension came out UNKNOWN whenever the axis was declared. That is not a
    lost diagnostic in Python alone: Rust, Julia, Go and TypeScript all read an
    absent ``wrt`` as ``t`` here, so the document below — which adds a
    length-per-time to a mass — is a dimensional mismatch in four bindings and
    was silently clean in the fifth.

    The axis has to be DECLARED for the rule to fire at all (an undeclared
    ``t`` leaves the derivative indeterminate in every binding, deliberately),
    which is why this model renames its independent variable and declares ``t``
    as an ordinary parameter — the same shape as
    ``tests/valid/independent_variable_renamed.esm``.
    """
    from earthsci_ast.esm_types import Equation, Model, ModelVariable
    from earthsci_ast.units import UnitValidator

    def _model(wrt: str | None) -> Model:
        d: dict = {"op": "D", "args": ["h"]}
        if wrt is not None:
            d["wrt"] = wrt
        return Model(
            name="UnitsWrtDefault",
            variables={
                "t": ModelVariable(type="parameter", units="s", default=1.0),
                "h": ModelVariable(type="unknown", units="m", default=0.0),
                "w": ModelVariable(type="parameter", units="kg", default=2.0),
                "q": ModelVariable(type="unknown", units="m/s"),
            },
            equations=[
                Equation(lhs=_parse_expression(d), rhs=1.0),
                Equation(
                    lhs="q",
                    rhs=_parse_expression({"op": "+", "args": [d, "w"]}),
                ),
            ],
        )

    omitted = UnitValidator().validate_model(_model(None))
    explicit = UnitValidator().validate_model(_model("t"))
    assert not explicit.is_valid, "the explicit spelling has always been caught"
    assert not omitted.is_valid, (
        "an absent `wrt` MEANS `t` (esm-spec §4.2), so the same mismatch must be "
        "reported for the short spelling"
    )
    assert omitted.errors == explicit.errors
