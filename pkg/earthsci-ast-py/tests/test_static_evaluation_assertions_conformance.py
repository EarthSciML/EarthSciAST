"""Cross-language conformance: an assertion's ``time`` is the time its
expression is EVALUATED at (esm-spec §6.6.3), including on a document with no
differential equations at all (§6.3.1).

Shared fixtures + Julia-minted goldens live under
``tests/conformance/static_evaluation_assertions/`` (repo root); the Julia
runner (``conformance_static_evaluation_assertions_test.jl``) and the Rust
runner (``static_evaluation_assertions_conformance.rs``) gate the same goldens.

Python is the binding that was ALREADY RIGHT here, and that is why it is in
scope: it is the cross-check that fixes what the intended answer is. Rust
handed the algebraic fixture's compiled, state-free right-hand side to diffsol
and failed every assertion past the span's start with "Exceeded maximum number
of nonlinear solver failures (51) at time = 0" (issue #406); Julia threw a
``BoundsError`` out of OrdinaryDiffEq's dense interpolant on the same document,
and separately read every ``t``-dependent observed as zero because its
build-time cellwise evaluator bound the time slot to a literal ``0.0``. These
tests are the standing guard that Python does not regress onto either.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from earthsci_ast.inline_tests import bind_dimension_names, run_inline_tests

_ROOT = (
    Path(__file__).resolve().parents[3] / "tests" / "conformance" / "static_evaluation_assertions"
)
_MANIFEST = _ROOT / "manifest.json"


def _manifest() -> dict:
    return json.loads(_MANIFEST.read_text())


def test_manifest_declares_the_three_executing_bindings() -> None:
    manifest = _manifest()
    assert manifest["category"] == "static_evaluation_assertions"
    assert manifest["reference_binding"] == "julia"
    assert set(manifest["bindings_required"]) == {"julia", "python", "rust"}
    # Go and TypeScript ship no integrator and no inline-test runner, so there
    # is no execution path in either that could read an assertion's `time`.
    assert set(manifest["scope_excluded"]) == {"go", "typescript"}
    assert manifest["fixtures"]


@pytest.mark.parametrize("fixture", _manifest()["fixtures"], ids=lambda f: f["id"])
def test_static_evaluation_assertions_match_golden(fixture: dict) -> None:
    manifest = _manifest()
    rtol = float(manifest["tolerances"]["assertion_rtol"])
    atol = float(manifest["tolerances"]["assertion_atol"])
    integ = manifest["integrators"]["python"]

    esm_path = _ROOT / fixture["path"]
    golden = json.loads((_ROOT / fixture["golden"]).read_text())
    assert golden["reference_binding"] == "julia"

    results = run_inline_tests(
        str(esm_path),
        model_name=fixture["model"],
        method=integ["method"],
        rtol=float(integ["rtol"]),
        atol=float(integ["atol"]),
    )
    assert len(results) == len(golden["assertions"])

    by_key = {(r.test_id, r.assertion_idx): r for r in results}
    for g in golden["assertions"]:
        key = (g["test_id"], int(g["assertion_idx"]))
        assert key in by_key, f"missing assertion {key}"
        r = by_key[key]
        assert r.passed, f"{key}: {r.message}"
        assert r.actual is not None
        assert r.actual == pytest.approx(float(g["actual"]), rel=rtol, abs=atol)


@pytest.mark.parametrize(("time", "expected"), [(0.0, 0.0), (5.0, 10.0), (10.0, 20.0)])
def test_an_algebraic_document_is_evaluated_at_every_asserted_time(
    time: float, expected: float
) -> None:
    """The regression from issue #406, stated without the golden machinery.

    Only the ``time == 0.0`` case passed in Rust before the fix, because that
    is the one saved time an integrator never has to step for — which is how
    the defect survived a corpus whose static documents almost all assert at
    ``time: 0``.
    """
    from earthsci_ast.parse import load_string

    doc = f"""
    {{
      "esm": "1.1.0",
      "metadata": {{"name": "TimeProbe", "description": "algebraic-only", "license": "MIT"}},
      "models": {{"TimeProbe": {{
        "variables": {{
          "a": {{"type": "parameter", "units": "1/s", "default": 2.0}},
          "y": {{"type": "unknown", "units": "1"}}
        }},
        "equations": [{{"lhs": "y", "rhs": {{"op": "*", "args": ["a", "t"]}}}}],
        "tests": [{{"id": "t_dep", "time_span": {{"start": 0, "end": 10}},
          "assertions": [{{"variable": "y", "time": {time}, "expected": {expected},
                          "tolerance": {{"abs": 1e-12}}}}]}}]
      }}}}
    }}
    """
    results = run_inline_tests(load_string(doc))
    assert len(results) == 1
    r = results[0]
    assert r.passed, f"y = a*t at t={time} should be {expected}: {r.message}"
    assert r.actual == pytest.approx(expected, abs=1e-12)


def test_declaring_system_kind_nonlinear_changes_nothing() -> None:
    """``system_kind`` is a CHECKED DECLARATION, not a selector (esm-spec
    §6.3.1: a binding "uses the derivation when the field is absent, and
    reports ``system_kind_mismatch`` when a present field contradicts it").

    So the document must answer identically with and without the declaration,
    and a CONTRADICTING one must be rejected rather than dispatched on. Issue
    #406 read the byte-identical outcome as evidence the field was ignored; it
    is evidence the field is not a switch.
    """
    from earthsci_ast.parse import load_string
    from earthsci_ast.validation import validate_text

    def doc(declared: str) -> str:
        return f"""
        {{
          "esm": "1.1.0",
          "metadata": {{"name": "TimeProbe", "description": "algebraic-only", "license": "MIT"}},
          "models": {{"TimeProbe": {{
            {declared}
            "variables": {{
              "a": {{"type": "parameter", "units": "1/s", "default": 2.0}},
              "y": {{"type": "unknown", "units": "1"}}
            }},
            "equations": [{{"lhs": "y", "rhs": {{"op": "*", "args": ["a", "t"]}}}}],
            "tests": [{{"id": "t_dep", "time_span": {{"start": 0, "end": 10}},
              "assertions": [{{"variable": "y", "time": 5.0, "expected": 10.0,
                              "tolerance": {{"abs": 1e-12}}}}]}}]
          }}}}
        }}
        """

    def actual(declared: str) -> float:
        results = run_inline_tests(load_string(doc(declared)))
        assert len(results) == 1
        assert results[0].passed, results[0].message
        return results[0].actual

    assert actual("") == actual('"system_kind": "nonlinear",')

    # The declaration is not inert: a contradicting one is a structural error,
    # which is the whole of what the field does.
    report = validate_text(doc('"system_kind": "ode",'))
    codes = [e.code for e in report.structural_errors]
    assert "system_kind_mismatch" in codes, codes


def test_an_assertion_outside_the_declared_span_is_refused() -> None:
    """esm-spec §6.6.3 constrains an assertion's ``time`` to
    ``[time_span.start, time_span.end]``.

    Python enforces it incidentally, by sampling the trajectory over the span
    and refusing a time that is not on it — on a document with nothing to
    integrate as much as on one that integrates. This is the cross-binding
    anchor for that refusal: Julia and Rust evaluate a static document's
    observed graph directly, which has no boundary of its own, so both restrict
    the evaluation grid to the span rather than answering ``t = 100`` on a span
    of ``[0, 1]`` and reporting a pass.
    """
    from earthsci_ast.parse import load_string

    doc = """
    {
      "esm": "1.1.0",
      "metadata": {"name": "TimeProbe", "description": "algebraic-only", "license": "MIT"},
      "models": {"TimeProbe": {
        "variables": {
          "a": {"type": "parameter", "units": "1/s", "default": 2.0},
          "y": {"type": "unknown", "units": "1"}
        },
        "equations": [{"lhs": "y", "rhs": {"op": "*", "args": ["a", "t"]}}],
        "tests": [
          {"id": "past_end", "time_span": {"start": 0, "end": 1},
           "assertions": [{"variable": "y", "time": 100.0, "expected": 200.0}]},
          {"id": "before_start", "time_span": {"start": 0, "end": 1},
           "assertions": [{"variable": "y", "time": -5.0, "expected": -10.0}]},
          {"id": "at_the_end", "time_span": {"start": 0, "end": 1},
           "assertions": [{"variable": "y", "time": 1.0, "expected": 2.0,
                           "tolerance": {"abs": 1e-12}}]}
        ]
      }}
    }
    """
    by_test = {r.test_id: r for r in run_inline_tests(load_string(doc))}
    assert len(by_test) == 3
    for test_id in ("past_end", "before_start"):
        r = by_test[test_id]
        assert not r.passed, f"{test_id} must not pass: actual={r.actual}"
        assert "no saved state" in r.message, r.message
    # The span's own endpoint is inside it and still answers.
    at_end = by_test["at_the_end"]
    assert at_end.passed, at_end.message
    assert at_end.actual == pytest.approx(2.0, abs=1e-12)


def test_a_reference_that_mentions_t_is_refused() -> None:
    """esm-spec §6.6.5 names what an analytic ``reference`` may read — the
    asserted field's dimension names, FREE, and the model's parameters — and
    ``t`` is neither.

    The build-time cellwise evaluator has a time slot holding ``0.0``, so a
    reference of ``t`` did not fail there: it answered with the expression at
    the start of the span and reported a plausible wrong number, in Python,
    Julia and Rust alike. Before the refusal this document reported
    ``actual = 2.0`` against ``expected = 0.0``.
    """
    from earthsci_ast.inline_tests import REFERENCE_MENTIONS_TIME
    from earthsci_ast.parse import load_string

    doc = """
    {
      "esm": "1.1.0",
      "metadata": {"name": "RefT", "description": "a reference that mentions t", "license": "MIT"},
      "index_sets": {"x": {"kind": "interval", "size": 2}},
      "models": {"RefT": {
        "variables": {"u": {"type": "unknown", "units": "1", "shape": ["x"]}},
        "equations": [
          {"lhs": {"op": "ic", "args": ["u"]},
           "rhs": {"op": "faq", "args": [], "output_idx": ["i"], "ranges": {"i": {"from": "x"}}, "expr": 0.0}},
          {"lhs": {"op": "faq", "args": [], "output_idx": ["i"], "ranges": {"i": [1, 2]},
                   "expr": {"op": "D", "args": [{"op": "index", "args": ["u", "i"]}], "wrt": "t"}},
           "rhs": {"op": "faq", "args": [], "output_idx": ["i"], "ranges": {"i": [1, 2]}, "expr": 1.0}}
        ],
        "tests": [{"id": "reference_mentions_t", "time_span": {"start": 0.0, "end": 2.0},
          "assertions": [{"variable": "u", "time": 2.0, "reduce": "Linf_error",
                          "reference": {"op": "*", "args": [1.0, "t"]}, "expected": 0.0,
                          "tolerance": {"abs": 1e-9}}]}]
      }}
    }
    """
    results = run_inline_tests(load_string(doc))
    assert len(results) == 1
    r = results[0]
    assert not r.passed, f"actual={r.actual}"
    assert r.actual is None
    # The sentence is BYTE-IDENTICAL in Rust and Julia; the three bindings must
    # reject the same document the same way.
    assert REFERENCE_MENTIONS_TIME in r.message
    assert REFERENCE_MENTIONS_TIME == (
        "inline `reference` mentions `t`, which esm-spec §6.6.5 does not admit: a reference's free variables are the field's dimension names, and its other names are the model's parameters. A reference is evaluated at build time, where the independent variable has no value, so `t` would silently read 0 rather than the asserted time."
    )


def test_bind_dimension_names_refuses_a_free_t() -> None:
    """The rule at the one function that carries it: a FREE ``t`` is refused,
    a ``t`` that IS a dimension name of the asserted field is admitted and
    binds to the cell index like any other, and a binder's own loop symbol is
    not a free mention."""
    from earthsci_ast.expression import ExprNode

    tref = "t"
    with pytest.raises(RuntimeError, match="does not admit"):
        bind_dimension_names(tref, ["x"])
    # Refused on an UNSHAPED target too — the check runs before the dims exit.
    with pytest.raises(RuntimeError, match="does not admit"):
        bind_dimension_names(tref, [])
    # A field shaped over an index set NAMED `t`.
    assert bind_dimension_names(tref, ["t"]) is not tref
    # A binder's own loop symbol is not a free mention.
    bound = ExprNode(op="faq", args=[], output_idx=["t"], ranges={"t": {"from": "x"}}, expr="t")
    assert bind_dimension_names(bound, ["x"]) is bound
