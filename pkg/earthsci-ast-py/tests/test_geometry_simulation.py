"""Conservative-regridding geometry — solve()-path ODE conformance.

RFC ``semiring-faq-unified-ir`` §8.1; ``CONFORMANCE_SPEC.md`` §5.8.

Drives the shared ``tests/valid/geometry/*.esm`` fixtures that carry inline
``tests`` blocks END-TO-END through :func:`simulate`, exactly as
:mod:`test_faq_conformance` does for the M1 semiring fixtures (the
"Mechanism-A" runner). A geometry-ODE fixture integrates as a real ODE because
the array-op simulate driver materializes, in dependency order, each observed
(the ``lib/geometry.esm`` overlap area, …) into the eval context before the
state derivatives — so ``D(tracer) = -area·tracer`` can resolve ``area``.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Dict, List, Tuple

import numpy as np
import pytest
from conftest import VALID_DIR

from earthsci_ast.esm_types import ExprNode
from earthsci_ast.inline_tests import TEST_ABSTOL, TEST_RELTOL, _check_assertion
from earthsci_ast.parse import load_path
from earthsci_ast.problem import ReturnCode, esm_problem, solve
from earthsci_ast.simulation import (
    _order_observed_equations,
    _time_varying_observeds,
)

_GEOM_DIR = VALID_DIR / "geometry"


def _collect_fixtures() -> List[Path]:
    """Geometry fixtures that carry at least one inline model ``tests`` block."""
    if not _GEOM_DIR.is_dir():
        return []
    out: List[Path] = []
    for p in sorted(_GEOM_DIR.glob("*.esm")):
        raw = json.loads(p.read_text())
        if any(m.get("tests") for m in (raw.get("models") or {}).values()):
            out.append(p)
    return out


def _resolve_tolerance(*levels: Dict[str, float]) -> Tuple[float, float]:
    merged: Dict[str, float] = {}
    for t in levels:
        if t:
            merged.update(t)
    return float(merged.get("rel", 0.0)), float(merged.get("abs", 0.0))


def _lookup(result, var_key: str, time: float) -> float:
    match = None
    for i, name in enumerate(result.vars):
        if name == var_key or name.endswith("." + var_key):
            match = i
            break
    if match is None:
        raise AssertionError(f"variable {var_key!r} not in result vars: {result.vars}")
    row = result.y[match, :]
    if len(result.t) == 0:
        raise AssertionError("result has no time points")
    if time <= result.t[0]:
        return float(row[0])
    if time >= result.t[-1]:
        return float(row[-1])
    return float(np.interp(time, result.t, row))


def _passes(actual: float, expected: float, rel: float, ab: float) -> bool:
    """esm-spec §6.6.3, through the binding's OWN predicate — the function
    ``run_pde_tests`` calls. The hand-rolled body this replaces scaled the
    relative bound by ``|expected|`` alone rather than
    ``max(|actual|, |expected|)``, floored that scale at 1e-12 (§6.6.3 forbids
    a floor), and had no finiteness guard, so a ±inf actual satisfied it
    vacuously for every expectation."""
    return _check_assertion(actual, expected, rel, ab)


def test_at_least_one_runnable_geometry_fixture() -> None:
    """At least one geometry fixture must be drivable end-to-end through solve()."""
    assert _collect_fixtures(), (
        f"no executable geometry fixtures (inline `tests`) under {_GEOM_DIR}; "
        "the solve()-path geometry ODE is unexercised"
    )


@pytest.mark.parametrize("fixture_path", _collect_fixtures(), ids=lambda p: p.name)
def test_geometry_fixture_simulate_conformance(fixture_path: Path) -> None:
    """Run every inline test in a geometry ODE fixture through :func:`simulate`."""
    raw = json.loads(fixture_path.read_text())

    esm_file = load_path(fixture_path)
    any_assertions = False
    for model_name, model_raw in (raw.get("models") or {}).items():
        model_tol = model_raw.get("tolerance") or {}
        for test in model_raw.get("tests") or []:
            test_id = test.get("id", "?")
            tspan_raw = test["time_span"]
            tspan = (float(tspan_raw["start"]), float(tspan_raw["end"]))
            ics = {k: float(v) for k, v in (test.get("initial_conditions") or {}).items()}
            params = {k: float(v) for k, v in (test.get("parameter_overrides") or {}).items()}

            # Explicit TEST tolerances — this compares against analytic values.
            result = solve(
                esm_problem(esm_file, tspan, u0=ics, p=params),
                reltol=TEST_RELTOL,
                abstol=TEST_ABSTOL,
            )
            assert result.retcode is ReturnCode.Success, (
                f"{fixture_path.name}::{model_name}::{test_id} simulation failed: {result.message}"
            )

            test_tol = test.get("tolerance") or {}
            for assertion in test.get("assertions", []):
                any_assertions = True
                var_key = assertion["variable"]
                time = float(assertion["time"])
                expected = float(assertion["expected"])
                rel, ab = _resolve_tolerance(model_tol, test_tol, assertion.get("tolerance") or {})
                actual = _lookup(result, var_key, time)
                assert _passes(actual, expected, rel, ab), (
                    f"{fixture_path.name}::{model_name}::{test_id} "
                    f"assertion {var_key}@t={time} expected={expected} "
                    f"actual={actual} tol(rel={rel}, abs={ab})"
                )

    assert any_assertions, f"{fixture_path.name}: no assertions were checked"


# --------------------------------------------------------------------------- #
# Unit coverage for the driver's observed-scheduling helpers
# --------------------------------------------------------------------------- #


def test_order_observed_equations_is_dependency_sorted() -> None:
    """An observed is ordered after every observed its RHS references."""
    clip = ExprNode(op="*", args=["src", "tgt"])
    area = ExprNode(
        op="faq",
        semiring="sum_product",
        output_idx=[],
        args=["clip"],
        ranges={"v": {"from": "ring"}},
        expr=ExprNode(op="index", args=["clip", "v", 1]),
    )
    src = ExprNode(op="const", args=[], value=[[0.0, 0.0]])
    tgt = ExprNode(op="const", args=[], value=[[1.0, 1.0]])
    # Declared in dependent-first order to prove the sort actually reorders.
    observed_eqs = [("area", area), ("clip", clip), ("src", src), ("tgt", tgt)]
    names = {"area", "clip", "src", "tgt"}
    order = [n for n, _ in _order_observed_equations(observed_eqs, names)]
    assert order.index("src") < order.index("clip")
    assert order.index("tgt") < order.index("clip")
    assert order.index("clip") < order.index("area")


def test_time_varying_observeds_flags_state_t_and_transitive() -> None:
    """Constant observeds are excluded; state / ``t`` / transitive deps are flagged."""
    const_poly = ExprNode(op="const", args=[], value=[[0.0, 0.0]])
    # depends on a state variable directly
    rate = ExprNode(op="*", args=["k", "tracer"])
    # depends on `t` directly
    ramp = ExprNode(op="*", args=["t", 2.0])
    # depends transitively on the state-dependent observed `rate`
    scaled = ExprNode(op="*", args=["rate", 3.0])
    ordered = [("poly", const_poly), ("rate", rate), ("ramp", ramp), ("scaled", scaled)]
    varying = _time_varying_observeds(ordered, state_names={"tracer"})
    assert "poly" not in varying
    assert varying == {"rate", "ramp", "scaled"}
