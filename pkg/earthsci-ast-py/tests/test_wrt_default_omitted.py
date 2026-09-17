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
SHAPED_FIXTURE = (
    REPO_ROOT / "tests" / "fixtures" / "faq" / "28_wrt_default_omitted_shaped.esm"
)
CLASSIFICATION_FIXTURE = (
    CONFORMANCE_DIR / "classification" / "fixtures" / "wrt_default_omitted.esm"
)


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
    ("fixture", "omitted", "explicit"),
    [
        (SCALAR_FIXTURE, "ScalarWrtOmitted", "ScalarWrtExplicit"),
        (SHAPED_FIXTURE, "ShapedWrtOmitted", "ShapedWrtExplicit"),
    ],
)
def test_both_spellings_integrate_identically(fixture, omitted: str, explicit: str) -> None:
    a = _run(fixture, omitted)
    b = _run(fixture, explicit)
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
