"""The document-scoped `solver` block (esm-spec §2.2)."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

import earthsci_ast as esm
from earthsci_ast.esm_types import EsmFile
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
    from earthsci_ast.inline_tests import DEFAULT_METHOD, STIFF_METHOD, _method_for

    high = _load(BASE, tmp_path)
    assert _method_for(None, high) == STIFF_METHOD

    for declared in ({"stiffness": "moderate"}, {"stiffness": "low"}):
        assert _method_for(None, _load({**BASE, "solver": declared}, tmp_path)) == DEFAULT_METHOD

    no_block = {k: v for k, v in BASE.items() if k != "solver"}
    assert _method_for(None, _load(no_block, tmp_path)) == DEFAULT_METHOD
    # An explicit caller argument still wins (§2.2.2 level 1).
    assert _method_for("LSODA", high) == "LSODA"


def test_the_block_reaches_the_problem_on_an_ordinary_build(tmp_path: Path) -> None:
    """Regression: ``solve()`` read the block off ``prob.doc``, which is populated
    only on the ``pushdown_rewrite`` path — so the §2.2.2 chain was dead code for
    every ordinary problem and the document's tolerances were silently ignored.

    The block is now captured onto the EsmProblem at construction, from the TYPED
    file, which every input carrier except a bare ``FlattenedSystem`` produces.
    """
    from earthsci_ast.problem import esm_problem, remake

    f = _load(BASE, tmp_path)
    prob = esm_problem(f, tspan=(0.0, 4.0))
    assert prob.doc is None, "the ordinary path records no raw document"
    assert prob.solver is not None
    assert (prob.solver.abstol, prob.solver.reltol) == (1e-8, 1e-6)
    assert resolve_tolerances(prob.solver) == (1e-8, 1e-6)

    # A remade problem is the same document, so it keeps the block.
    assert remake(prob, tspan=(0.0, 2.0)).solver is prob.solver

    # And an empty block still normalizes away on that carrier.
    empty = esm_problem(_load({**BASE, "solver": {}}, tmp_path), tspan=(0.0, 4.0))
    assert empty.solver is None


def test_inline_test_integration_tolerances_come_from_the_document(tmp_path: Path) -> None:
    """§2.2.2: the runner's own TEST_* defaults sit at LEVEL 3, so a document
    that declares ``solver.reltol`` displaces them; each field falls through
    independently, and an explicit caller argument still wins.

    ``or`` would have swallowed a declared ``0.0`` — a value the author SET —
    which is why the chain tests ``is not None``.
    """
    from earthsci_ast.esm_types import Solver
    from earthsci_ast.inline_tests import (
        TEST_ABSTOL,
        TEST_RELTOL,
        _integration_tolerances,
    )

    doc = _load(BASE, tmp_path)
    assert _integration_tolerances(doc, None, None) == (1e-6, 1e-8)
    assert _integration_tolerances(doc, 1e-13, 1e-15) == (1e-13, 1e-15)

    only_reltol = _load({**BASE, "solver": {"reltol": 1e-9}}, tmp_path)
    assert _integration_tolerances(only_reltol, None, None) == (1e-9, TEST_ABSTOL)

    no_block = _load({k: v for k, v in BASE.items() if k != "solver"}, tmp_path)
    assert _integration_tolerances(no_block, None, None) == (TEST_RELTOL, TEST_ABSTOL)

    # A programmatically built file is never re-validated, so a declared 0.0
    # reaches here. It must survive as the value it is, not be swapped for the
    # runner default by a truthiness test.
    zero = EsmFile(version="1.1.0", metadata=doc.metadata, solver=Solver(reltol=0.0))
    assert _integration_tolerances(zero, None, None) == (0.0, TEST_ABSTOL)


def test_the_chain_reaches_the_stepping_api_too(tmp_path: Path) -> None:
    """§2.2.2 applies wherever a document is INTEGRATED, not just at ``solve()``.

    ``init`` / ``Integrator`` used to default ``abstol`` / ``reltol`` to the
    concrete ``DEFAULT_*`` values, which occupies LEVEL 1 of the chain: a
    stepping caller who named no tolerance was indistinguishable from one who
    passed the binding default, so the document could never win and
    ``solve(prob)`` honoured a declared ``abstol`` while ``init(prob)`` + ``step``
    silently did not, on the same document.
    """
    from earthsci_ast.problem import esm_problem, init, step

    prob = esm_problem(_load(BASE, tmp_path), tspan=(0.0, 4.0))

    # 1. The document's tolerances reach the integrator.
    integ = init(prob)
    assert (integ.abstol, integ.reltol) == (1e-8, 1e-6)

    # And they reach the SciPy solver OBJECT, not merely the wrapper's
    # attributes. Asserted through RK45 because it is an `OdeSolver` subclass
    # that keeps `rtol`/`atol` on itself; the default LSODA buries them in a
    # Fortran integrator handle, which is not a contract worth pinning.
    rk = init(prob, alg="RK45")
    assert (float(rk._solver.rtol), float(rk._solver.atol)) == (1e-6, 1e-8)

    # And they survive into stepping: `step` is what a driver actually calls.
    step(integ)
    assert integ.t > 0.0
    assert (integ.abstol, integ.reltol) == (1e-8, 1e-6)

    # 2. An explicit call-site argument still beats the document (level 1).
    explicit = init(prob, alg="RK45", abstol=1e-12, reltol=1e-11)
    assert (explicit.abstol, explicit.reltol) == (1e-12, 1e-11)
    assert (float(explicit._solver.rtol), float(explicit._solver.atol)) == (1e-11, 1e-12)

    # 3. Per field, with level 3 for whatever the document leaves unsaid.
    only_reltol = esm_problem(
        _load({**BASE, "solver": {"reltol": 1e-9}}, tmp_path), tspan=(0.0, 4.0)
    )
    partial = init(only_reltol)
    assert (partial.abstol, partial.reltol) == (DEFAULT_ABSTOL, 1e-9)

    no_block = esm_problem(
        _load({k: v for k, v in BASE.items() if k != "solver"}, tmp_path), tspan=(0.0, 4.0)
    )
    bare = init(no_block)
    assert (bare.abstol, bare.reltol) == (DEFAULT_ABSTOL, DEFAULT_RELTOL)


def test_a_declared_zero_abstol_is_not_swallowed_by_the_stepping_api(tmp_path: Path) -> None:
    """The ``or`` trap, at the stepping door.

    ``0.0`` is falsy, so ``abstol or DEFAULT_ABSTOL`` would silently replace a
    value the author SET with the binding default. The chain tests
    ``is not None``. The schema forbids a non-positive tolerance, so this state
    is only reachable by building the block programmatically — which is exactly
    why the guard has to live in the resolution and not in the validator.
    """
    from earthsci_ast.esm_types import Solver
    from earthsci_ast.problem import esm_problem, init

    prob = esm_problem(_load(BASE, tmp_path), tspan=(0.0, 4.0))
    prob.solver = Solver(abstol=0.0)
    integ = init(prob)
    assert integ.abstol == 0.0
    assert integ.reltol == DEFAULT_RELTOL
