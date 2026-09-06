"""The document-scoped `solver` block (esm-spec §2.2)."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

import earthsci_ast as esm
from earthsci_ast.serialize import to_json
from earthsci_ast.solver import (
    DEFAULT_ABSTOL,
    DEFAULT_RELTOL,
    SolverBlockError,
    resolve_tolerances,
)

FIXTURE = Path(__file__).resolve().parents[3] / "tests" / "valid" / "solver_block.esm"
BASE = json.loads(FIXTURE.read_text())


def _load(doc: dict, tmp_path: Path):
    p = tmp_path / "d.esm"
    p.write_text(json.dumps(doc))
    return esm.load_path(str(p))


def test_a_declared_block_round_trips_verbatim(tmp_path: Path) -> None:
    f = _load(BASE, tmp_path)
    assert f.solver is not None
    assert f.solver.stiffness == "high"
    assert json.loads(to_json(f))["solver"] == BASE["solver"]


def test_an_empty_block_normalizes_to_absence(tmp_path: Path) -> None:
    """``{}`` is legal and means what omitting the block means.

    Every other optional top-level container (``coordinates``, ``index_sets``,
    ``metaparameters``, ``coupling_roles``) admits an empty object, so making
    this one the exception would be a rule with no payoff. It normalizes away AT
    LOAD, which is what keeps the five bindings from disagreeing about whether
    ``{}`` survives ``parse -> emit``.
    """
    f = _load({**BASE, "solver": {}}, tmp_path)
    assert f.solver is None
    assert "solver" not in json.loads(to_json(f))


def test_the_block_is_rejected_below_esm_1_1_0(tmp_path: Path) -> None:
    with pytest.raises(SolverBlockError) as exc:
        _load({**BASE, "esm": "1.0.0", "solver": {"stiffness": "high"}}, tmp_path)
    assert exc.value.code == "solver_version_too_old"


def test_tolerances_resolve_most_specific_first(tmp_path: Path) -> None:
    """§2.2.2: caller, then document, then binding default — per field."""
    s = _load(BASE, tmp_path).solver
    assert resolve_tolerances(s, abstol=1e-12, reltol=1e-11) == (1e-12, 1e-11)
    assert resolve_tolerances(s) == (1e-8, 1e-6)
    assert resolve_tolerances(None) == (DEFAULT_ABSTOL, DEFAULT_RELTOL)

    only_reltol = _load({**BASE, "solver": {"reltol": 1e-9}}, tmp_path).solver
    assert resolve_tolerances(only_reltol) == (DEFAULT_ABSTOL, 1e-9)


def test_stiffness_selects_the_integrator_but_only_for_high(tmp_path: Path) -> None:
    """The motivating case: a portable declaration mapped to THIS binding's name.

    The document never carries ``"BDF"`` — that is a scipy identifier where
    Julia wants ``Rosenbrock23``, which §2.2.3 rules out. ``low`` / ``moderate``
    are ignored: they say nothing the default does not already handle.
    """
    from earthsci_ast.pde_inline_tests import DEFAULT_METHOD, STIFF_METHOD, _method_for

    high = _load(BASE, tmp_path)
    assert _method_for(None, high) == STIFF_METHOD

    for declared in ({"stiffness": "moderate"}, {"stiffness": "low"}):
        assert _method_for(None, _load({**BASE, "solver": declared}, tmp_path)) == DEFAULT_METHOD

    no_block = {k: v for k, v in BASE.items() if k != "solver"}
    assert _method_for(None, _load(no_block, tmp_path)) == DEFAULT_METHOD
    # An explicit caller argument still wins (§2.2.2 level 1).
    assert _method_for("LSODA", high) == "LSODA"
