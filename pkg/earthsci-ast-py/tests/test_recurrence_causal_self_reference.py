"""Causal self-reference along one index axis — esm-spec §4.3.1.1.

A recurrence's output cells are **not independent**, which is what separates
this construct from everything else in the array runtime and what these tests
exist to pin. Three consequences, each asserted here on a SPECIFIC value or a
specific code rather than within a tolerance:

* the **value** is a fully determined function of the document — the sweep order
  is fixed and each cell is published before the axis advances — so a
  cancellation ladder separates the normative left fold from every reassociation
  and reordering (CONFORMANCE_SPEC §5.19.1, §5.19.3);
* an **unavailable** self-read (out of range, or a cell the sweep has not
  published) is a fault, never a number. §5.19.4 is emphatic and the reason is
  specific to a recurrence: it feeds itself, so one substituted zero propagates
  along the whole axis, and a ``max(x, 0)`` in the body launders even a NaN
  sentinel into something plausible;
* a shape that is **not** a well-founded causal read is rejected with a code, not
  evaluated to something. The pre-feature behaviour for every one of these was a
  document that validated and then produced a wrong answer or no answer at all.

Nothing below asserts a bound, and nothing asserts merely that a run completed.
"""

from __future__ import annotations

import json

import numpy as np
import pytest
from conftest import FIXTURES_ROOT, VALID_DIR

from earthsci_ast.error_handling import (
    RECURRENCE_NOT_WELLFOUNDED,
    RECURRENCE_UNSUPPORTED_FORM,
)
from earthsci_ast.numpy_interpreter import EvalContext, NumpyInterpreterError, sweep_recurrence
from earthsci_ast.parse import SchemaValidationError, load_path, load_string
from earthsci_ast.pde_inline_tests import run_pde_tests

_RECURRENCE_DIR = FIXTURES_ROOT / "fixtures" / "recurrence"


# ---------------------------------------------------------------------------
# 1. The six pinned fixtures
# ---------------------------------------------------------------------------
#
# Each fixture declares `tolerance: {rel: 0, abs: 0}`, so `run_pde_tests`
# compares with `==` and "passed" here means BIT-identical to the pinned value.
# The expected values are restated in this module as well, so a fixture edited
# to match a wrong implementation would fail here rather than pass quietly.

_FIXTURE_VALUES: dict[str, tuple[str, list[float]]] = {
    # s[1] = 1, s[k] = 2*s[k-1]. The construct's minimal case, and the one that
    # had no spelling at all: written this way the document used to validate and
    # then leave `s` unmaterialized.
    "01_recurrence_doubling": ("s", [1.0, 2.0, 4.0, 8.0]),
    # THE ORDER PIN. s[k] = s[k-1] + u[k] over u = [1e16, 1, -1e16, 1]. The
    # ascending sweep is the left fold, [1e16, 1e16, 0, 1]; a reassociating or
    # reordered evaluation reaches [1e16, 1e16, 1, 2].
    "02_recurrence_cancellation_ladder": ("s", [1e16, 1e16, 0.0, 1.0]),
    # Two LITERAL lags in one body (Fibonacci). A single-step accumulator
    # `acc[i] = f(acc[i-1], body[i])` cannot express this at all.
    "03_recurrence_multi_lag": ("s", [1.0, 1.0, 2.0, 3.0, 5.0, 8.0, 13.0, 21.0, 34.0]),
    # A SYMBOL-valued lag under a banded filter with a clamp inside the fold —
    # the shape a real bounded-lag fold has. Pins the in-body reduction order
    # too: ascending-in-`a` gives exactly -1.0 at r[3].
    "04_recurrence_banded_lag_fold": (
        "r",
        [1e-16, 0.9999999999999999, -1.0, 99999997.0, -99999997.0, -1.0000000299999992e16],
    ),
    # A rank-2 variable folding along ONE axis and free in the other: the
    # carried state is a whole column. m[i,j] = i * 10^(j-1), row-major.
    "05_recurrence_two_axes": (
        "m",
        [1.0, 10.0, 100.0, 1000.0, 2.0, 20.0, 200.0, 2000.0, 3.0, 30.0, 300.0, 3000.0],
    ),
    # The carried value is rounded to the variable's `element_type` at EVERY
    # cell (§5.19.3a). The binary32 fold; a binary64 fold narrowed once at the
    # end reaches 0.9999999999999999 at s[10].
    "06_recurrence_float32_state": (
        "s",
        [
            0.10000000149011612,
            0.20000000298023224,
            0.30000001192092896,
            0.4000000059604645,
            0.5,
            0.6000000238418579,
            0.7000000476837158,
            0.8000000715255737,
            0.9000000953674316,
            1.0000001192092896,
        ],
    ),
    # A lag the validator CANNOT prove: `s[k] = 3*s[k-n]` with `n` a PARAMETER.
    # esm-spec §4.3.1.1 splits the proof obligation — the COEFFICIENT of the
    # frame symbol must be provable, the lag's SIGN need not be — so this is
    # admitted, not rejected, and the fail-closed read guards it. With n = 2:
    "08_recurrence_parameter_valued_lag": ("s", [1.0, 1.0, 3.0, 3.0, 9.0]),
}

#: Fixture 07 asserts all forty of its own cells against an INDEPENDENT
#: ascending-fold reference, so restating the array here would only copy it;
#: it is driven through the inline-test path and spot-pinned below instead.
#: 09 is the `apply_expression_template` hole: a self-read reached through a
#: template BINDING, which no binding's self-read walk visits. It must still
#: evaluate — the template is lowered before evaluation, so by the time the
#: recurrence lowering sees the body the read is an ordinary `index(s, k-1)`.
_INLINE_ONLY_FIXTURES = (
    "07_recurrence_thirty_eight_lags",
    "09_recurrence_through_expression_template",
)


def _sweep_fixture(stem: str) -> np.ndarray:
    """Materialize a fixture's recurrence variable directly through the sweep.

    The interpreter-level counterpart of the inline-test run below: it reads the
    whole array rather than the cells the fixture happens to assert, so a wrong
    value at an UNASSERTED cell is caught too.
    """
    var, _ = _FIXTURE_VALUES[stem]
    file = load_path(str(_RECURRENCE_DIR / f"{stem}.esm"))
    model = next(iter(file.models.values()))
    ctx = EvalContext(
        state_layout={},
        state_shapes={},
        param_values={
            # A recurrence's lag may come from a PARAMETER (fixture 08), which
            # is exactly the case no static analysis can bound.
            name: float(v.default)
            for name, v in model.variables.items()
            if v.type == "parameter" and isinstance(v.default, (int, float))
        },
        observed_values={},
        y=np.empty(0, dtype=float),
        t=0.0,
        index_sets=file.index_sets or {},
        element_types={var: model.variables[var].element_type}
        if model.variables[var].element_type
        else {},
    )
    swept = sweep_recurrence(var, model.equations[0].rhs, ctx, model.variables[var].element_type)
    assert swept is not None, f"{stem}: the equation was not recognized as a recurrence"
    return swept


@pytest.mark.parametrize("stem", sorted(_FIXTURE_VALUES))
def test_fixture_sweeps_to_the_pinned_values(stem: str) -> None:
    """Every cell of the fixture's recurrence variable, to the bit.

    ``==`` and not ``allclose``: the value is a fully determined left fold, so a
    divergence is a defect rather than a floating-point fact (§5.19.1), and a
    tolerance here would accept the reassociated answers the fixtures were
    designed to separate.
    """
    _var, expected = _FIXTURE_VALUES[stem]
    actual = [float(x) for x in np.asarray(_sweep_fixture(stem)).ravel()]
    assert actual == expected


@pytest.mark.parametrize("stem", sorted(_FIXTURE_VALUES) + list(_INLINE_ONLY_FIXTURES))
def test_fixture_inline_assertions_pass_at_zero_tolerance(stem: str) -> None:
    """The fixture's own inline ``tests``, through the official runner.

    Each fixture pins ``tolerance: {rel: 0, abs: 0}``, so this is exact equality;
    a missing ``actual`` is reported separately because it is what a variable
    that never materialized looks like.
    """
    results = run_pde_tests(str(_RECURRENCE_DIR / f"{stem}.esm"))
    assert results, f"{stem}: the fixture asserts nothing"
    for r in results:
        assert r.rtol == 0.0 and r.atol == 0.0, (
            f"{stem}: {r.test_id}[{r.assertion_idx}] is not pinned"
        )
        assert r.actual is not None, (
            f"{stem}: {r.test_id}[{r.assertion_idx}] on '{r.variable}' produced NO value — "
            f"{r.message}"
        )
        assert r.actual == r.expected, (
            f"{stem}: {r.test_id}[{r.assertion_idx}] on '{r.variable}' expected "
            f"{r.expected!r} got {r.actual!r}"
        )
        assert r.passed, f"{stem}: {r.message}"


def test_cancellation_ladder_is_the_left_fold_not_a_reassociation() -> None:
    """CONFORMANCE_SPEC §5.19.3 shape 1, stated as the wrong answer too.

    ``1.0`` at cell 3 is the signature of a reassociated or reordered window, and
    it would pass any tolerance loose enough to admit the magnitudes involved —
    so the wrong value is asserted absent, not merely the right one present.
    """
    cells = [float(x) for x in _sweep_fixture("02_recurrence_cancellation_ladder")]
    assert cells[2] == 0.0
    assert cells[2] != 1.0
    assert cells[3] == 1.0


def test_banded_lag_fold_accumulates_ascending_in_the_contracted_index() -> None:
    """CONFORMANCE_SPEC §5.19.3 shape 3: the IN-BODY order, pinned to the bit.

    ``-1.0000000000000002`` is the same admitted window folded from its high end,
    so a contraction that sums pairwise or in reverse fails here.
    """
    cells = [float(x) for x in _sweep_fixture("04_recurrence_banded_lag_fold")]
    assert cells[2] == -1.0
    assert cells[2] != -1.0000000000000002


def test_float32_recurrence_carries_binary32_state_at_every_cell() -> None:
    """CONFORMANCE_SPEC §5.19.3a.

    A binding that carries binary64 partials through the fold and narrows once at
    the end reaches ``0.9999999999999999`` — a BETTER answer than the ``real*4``
    reference this construct exists to reproduce, and the failure mode hardest to
    notice, since the numbers look right.
    """
    cells = [float(x) for x in _sweep_fixture("06_recurrence_float32_state")]
    assert cells[-1] == float(np.float32(1.0000001))
    assert cells[-1] != 0.9999999999999999
    # Every cell, not only the last, is exactly representable in binary32.
    for i, v in enumerate(cells):
        assert v == float(np.float32(v)), f"cell {i + 1} is not a binary32 value"


# ---------------------------------------------------------------------------
# 2. Fail-closed reads
# ---------------------------------------------------------------------------


def _probe_document(body: dict, *, tests: bool = True) -> str:
    """A one-variable recurrence document with ``body`` as the aggregate's ``expr``."""
    model: dict = {
        "tolerance": {"rel": 0.0, "abs": 0.0},
        "variables": {"s": {"type": "unknown", "shape": ["steps"], "units": "1"}},
        "equations": [
            {
                "lhs": "s",
                "rhs": {
                    "op": "aggregate",
                    "args": [],
                    "output_idx": ["k"],
                    "ranges": {"k": {"from": "steps"}},
                    "expr": body,
                },
            }
        ],
    }
    if tests:
        model["tests"] = [
            {
                "id": "probe",
                "description": "probe",
                "time_span": {"start": 0.0, "end": 0.0},
                "assertions": [
                    {"variable": "s", "time": 0.0, "expected": 1.0, "coords": {"steps": 1}}
                ],
            }
        ]
    return json.dumps(
        {
            "esm": "1.0.0",
            "metadata": {"name": "R", "description": "probe", "authors": ["t"]},
            "index_sets": {"steps": {"kind": "interval", "size": 4}},
            "models": {"R": model},
        }
    )


#: ``s[k] = 2*s[k-1]`` with NO base-case guard: at ``k = 1`` the body reads
#: position 0. Under the zero-ghost convention every other gather uses, that read
#: would be ``0`` and the whole array would then be zeros — four plausible
#: numbers and nothing to say they are wrong.
_UNGUARDED_BODY = {
    "op": "*",
    "args": [{"op": "index", "args": ["s", {"op": "-", "args": ["k", 1]}]}, 2.0],
}


def test_unguarded_self_read_at_the_first_cell_raises_rather_than_returning_a_number() -> None:
    """The one that would otherwise return a number (CONFORMANCE_SPEC §5.19.4).

    Python's channel for a fail-closed read is a raise, so that is what is
    asserted — and specifically NOT a value: neither the §5.5.5 zero ghost nor a
    NaN, which a clamp in the body would launder back into something plausible.
    """
    file = load_string(_probe_document(_UNGUARDED_BODY, tests=False))
    model = next(iter(file.models.values()))
    ctx = EvalContext(
        state_layout={},
        state_shapes={},
        param_values={},
        observed_values={},
        y=np.empty(0, dtype=float),
        t=0.0,
        index_sets=file.index_sets or {},
    )
    with pytest.raises(NumpyInterpreterError, match="E_TREEWALK_RECUR_UNAVAILABLE"):
        sweep_recurrence("s", model.equations[0].rhs, ctx)


def test_unguarded_self_read_never_reaches_an_assertion_as_a_value() -> None:
    """The same probe through the inline-test runner: no value, and the fault named.

    A recurrence that resolved an unavailable self-read to ``0`` would reproduce
    plausible-looking numbers for the whole axis, so the assertion here is that
    ``actual`` is absent — not that it differs from the expected value.
    """
    results = run_pde_tests(load_string(_probe_document(_UNGUARDED_BODY)))
    assert len(results) == 1
    assert results[0].actual is None and not results[0].passed
    assert "E_TREEWALK_RECUR_UNAVAILABLE" in results[0].message


def test_a_bare_self_read_that_bypasses_validation_still_fails_closed() -> None:
    """A bare ``s`` inside ``s``'s own RHS, reached at EVALUATION time.

    The structural validator refuses this shape, so the evaluator is only reached
    by a document that bypassed validation — and it must still fail closed rather
    than let the name fall through to a stale observed entry.
    """
    ctx = EvalContext(
        state_layout={},
        state_shapes={},
        param_values={},
        observed_values={},
        y=np.empty(0, dtype=float),
        t=0.0,
        index_sets={"steps": {"kind": "interval", "size": 4}},
    )
    from earthsci_ast.numpy_interpreter import _RecurScope, eval_expr, rounding_for_element_type

    ctx.recur = _RecurScope("s", [(1, 4)], rounding_for_element_type(None))
    with pytest.raises(NumpyInterpreterError, match="E_TREEWALK_RECUR_UNAVAILABLE"):
        eval_expr("s", ctx)


# ---------------------------------------------------------------------------
# 3. Rejections — the structural validator
# ---------------------------------------------------------------------------
#
# Rejection parity is a duty of every binding, executing or not
# (CONFORMANCE_SPEC §5.19.5). In Python the structural suite runs inside
# ``load``, so a malformed recurrence fails to LOAD and the codes arrive on the
# raised error's ``findings`` — the same coded channel every other structural
# rule uses.


def _load_codes(doc: str) -> list[str]:
    """The structural codes ``load_string(doc)`` raises, or ``[]`` when it loads."""
    try:
        load_string(doc)
    except SchemaValidationError as err:
        return [code for code, _msg in getattr(err, "findings", [])]
    return []


_MALFORMED_PROBES: dict[str, tuple[dict, str]] = {
    # A read the sweep has not reached: no order can satisfy it.
    "forward_read": (
        {"op": "index", "args": ["s", {"op": "+", "args": ["k", 1]}]},
        RECURRENCE_NOT_WELLFOUNDED,
    ),
    # `index(s, k)` defines s in terms of itself, not of an earlier position.
    "same_cell_read": ({"op": "index", "args": ["s", "k"]}, RECURRENCE_NOT_WELLFOUNDED),
    # A bare `s` names the whole array, which does not exist during the sweep.
    "bare_read": (
        {
            "op": "+",
            "args": ["s", {"op": "index", "args": ["s", {"op": "-", "args": ["k", 1]}]}],
        },
        RECURRENCE_NOT_WELLFOUNDED,
    ),
    # `2*k` does not name a position relative to the cell being written, so it
    # decides neither the axis nor the direction.
    "non_affine_index": (
        {"op": "index", "args": ["s", {"op": "*", "args": ["k", 2]}]},
        RECURRENCE_NOT_WELLFOUNDED,
    ),
    # A constant index says nothing about which axis the recurrence folds along.
    "constant_index": ({"op": "index", "args": ["s", 1]}, RECURRENCE_NOT_WELLFOUNDED),
}


@pytest.mark.parametrize("probe", sorted(_MALFORMED_PROBES))
def test_malformed_self_read_is_rejected_with_its_code(probe: str) -> None:
    body, expected_code = _MALFORMED_PROBES[probe]
    assert expected_code in _load_codes(_probe_document(body, tests=False))


def test_self_read_offset_on_two_axes_is_rejected() -> None:
    """``m[i,j]`` reading ``m[i-1, j-1]`` has no single axis to fold along — the
    sweep would have to advance both at once."""
    doc = json.dumps(
        {
            "esm": "1.0.0",
            "metadata": {"name": "R2", "description": "probe", "authors": ["t"]},
            "index_sets": {
                "rows": {"kind": "interval", "size": 3},
                "cols": {"kind": "interval", "size": 3},
            },
            "models": {
                "R2": {
                    "tolerance": {"rel": 0.0, "abs": 0.0},
                    "variables": {
                        "m": {"type": "unknown", "shape": ["rows", "cols"], "units": "1"}
                    },
                    "equations": [
                        {
                            "lhs": "m",
                            "rhs": {
                                "op": "aggregate",
                                "args": [],
                                "output_idx": ["i", "j"],
                                "ranges": {"i": {"from": "rows"}, "j": {"from": "cols"}},
                                "expr": {
                                    "op": "index",
                                    "args": [
                                        "m",
                                        {"op": "-", "args": ["i", 1]},
                                        {"op": "-", "args": ["j", 1]},
                                    ],
                                },
                            },
                        }
                    ],
                }
            },
        }
    )
    assert RECURRENCE_NOT_WELLFOUNDED in _load_codes(doc)


def test_makearray_region_self_read_is_refused_as_unsupported_form() -> None:
    """§4.3.2's overlap rule ("later entries overwrite earlier ones") reads like a
    licence to define position ``k`` from position ``k-1``. It is not one — the
    region order fixes which write WINS, not the order cells are EVALUATED in, and
    a region's value expression is evaluated once for the whole region. So the
    code says the READ is causal but the CARRIER cannot sequence it."""
    doc = json.dumps(
        {
            "esm": "1.0.0",
            "metadata": {"name": "RM", "description": "probe", "authors": ["t"]},
            "index_sets": {"steps": {"kind": "interval", "size": 4}},
            "models": {
                "RM": {
                    "tolerance": {"rel": 0.0, "abs": 0.0},
                    "variables": {"s": {"type": "unknown", "shape": ["steps"], "units": "1"}},
                    "equations": [
                        {
                            "lhs": "s",
                            "rhs": {
                                "op": "makearray",
                                "args": [],
                                "regions": [[[1, 1]], [[2, 4]]],
                                "values": [
                                    1.0,
                                    {
                                        "op": "aggregate",
                                        "args": [],
                                        "output_idx": ["k"],
                                        "ranges": {"k": [2, 4]},
                                        "expr": {
                                            "op": "index",
                                            "args": ["s", {"op": "-", "args": ["k", 1]}],
                                        },
                                    },
                                ],
                            },
                        }
                    ],
                }
            },
        }
    )
    assert RECURRENCE_UNSUPPORTED_FORM in _load_codes(doc)


def test_the_valid_corpus_recurrence_validates_clean() -> None:
    """The corpus fixture every binding must ACCEPT.

    Rejection parity cuts both ways: a binding that treats a self-read as a cycle
    rejects a legal document, which is the same defect as admitting an illegal
    one."""
    file = load_path(str(VALID_DIR / "recurrence_causal_self_reference.esm"))
    assert "RecurrenceCausalSelfReference" in (file.models or {})


def test_the_self_edge_is_not_a_cycle_but_a_two_variable_cycle_still_is() -> None:
    """A well-founded self-read is an ORDERING within one variable; an edge
    between two DISTINCT variables is a cycle and is still named."""
    from earthsci_ast import cadence
    from earthsci_ast.cadence import CadenceError

    recurrent = {
        "variables": {"s": {"type": "unknown", "shape": ["steps"]}},
        "equations": [
            {
                "lhs": "s",
                "rhs": {
                    "op": "aggregate",
                    "args": [],
                    "output_idx": ["k"],
                    "ranges": {"k": {"from": "steps"}},
                    "expr": {"op": "index", "args": ["s", {"op": "-", "args": ["k", 1]}]},
                },
            }
        ],
    }
    # No raise: the self-edge is dropped from the observed dependency graph.
    assert cadence.classify(recurrent["equations"][0]["rhs"], recurrent) == "const"

    cyclic = {
        "variables": {
            "a": {"type": "unknown", "shape": ["steps"]},
            "b": {"type": "unknown", "shape": ["steps"]},
        },
        "equations": [
            {"lhs": "a", "rhs": {"op": "index", "args": ["b", "k"]}},
            {"lhs": "b", "rhs": {"op": "index", "args": ["a", "k"]}},
        ],
    }
    with pytest.raises(CadenceError, match="observed definition cycle"):
        cadence.classify(cyclic["equations"][0]["rhs"], cyclic)


def test_an_ordinary_equation_is_not_touched_by_the_recurrence_path() -> None:
    """The construct is opt-in BY CONSTRUCTION: an equation whose RHS never reads
    the variable it defines is not a recurrence, and :func:`sweep_recurrence`
    declines it so the caller takes its pre-existing path unchanged."""
    file = load_path(str(_RECURRENCE_DIR / "01_recurrence_doubling.esm"))
    model = next(iter(file.models.values()))
    ctx = EvalContext(
        state_layout={},
        state_shapes={},
        param_values={},
        observed_values={},
        y=np.empty(0, dtype=float),
        t=0.0,
        index_sets=file.index_sets or {},
    )
    # The same RHS asked about a DIFFERENT variable reads nothing of that
    # variable, so it is not a recurrence definition of it.
    assert sweep_recurrence("not_s", model.equations[0].rhs, ctx) is None


# ---------------------------------------------------------------------------
# 4. Forbidden implementation strategies
# ---------------------------------------------------------------------------


_REORDERING_PATHS = (
    "_eval_arrayop_batched_leaf",
    "_eval_arrayop_prefix_scan",
    "_eval_arrayop_operator_cached",
    "_eval_arrayop_reduce_vectorized",
    "_eval_arrayop_vectorized",
    "_eval_arrayop_contraction_broadcast",
    "_materialize_map",
)


@pytest.mark.parametrize("stem", sorted(_FIXTURE_VALUES))
def test_no_reordering_path_is_taken_for_a_recurrence(stem: str, monkeypatch) -> None:
    """CONFORMANCE_SPEC §5.19.2, made OBSERVABLE rather than merely intended.

    Every whole-array / batched / fused / prefix-scan path in the interpreter is
    replaced with a raise for the duration of the sweep. The cells of a
    recurrence are not independent, so a reordering computes something else and a
    reassociation of the body is a different number — there is no equivalence to
    appeal to. Without this test a silent promotion back onto one of these paths
    would surface as a wrong low bit in a fixture rather than as a failure that
    names the cause.

    Fixture 04 is the load-bearing case: a contraction under a banded ``filter``
    is exactly the shape the prefix-scan and dense-reduce fast paths recognize.
    """
    from earthsci_ast import numpy_interpreter as ni

    def forbidden(name):
        def _raise(*_args, **_kwargs):
            raise AssertionError(f"a recurrence must not reach {name} (§5.19.2)")

        return _raise

    for name in _REORDERING_PATHS:
        monkeypatch.setattr(ni, name, forbidden(name))

    _var, expected = _FIXTURE_VALUES[stem]
    actual = [float(x) for x in np.asarray(_sweep_fixture(stem)).ravel()]
    assert actual == expected


def test_parameter_valued_lag_is_admitted_and_evaluates() -> None:
    """The unprovable-lag pin (esm-spec §4.3.1.1, RFC §2.1's last row).

    A binding whose validator treats "could not bound this lag" as "illegal"
    rejects this document — and rejects documents its own evaluator accepts,
    since the evaluator resolves ranges against the registry first and so proves
    strictly more. The coefficient is the half that must be proved; the sign is
    not.
    """
    assert RECURRENCE_NOT_WELLFOUNDED not in _load_codes(
        (_RECURRENCE_DIR / "08_recurrence_parameter_valued_lag.esm").read_text()
    )
    cells = [float(x) for x in _sweep_fixture("08_recurrence_parameter_valued_lag")]
    assert cells == [1.0, 1.0, 3.0, 3.0, 9.0]


def test_thirty_eight_lags_in_one_node_with_the_clamp_firing() -> None:
    """The real lag scale: one ``index(r, y - a)`` covering 38 lags, each with its
    own weight, under a banded ``filter``, with ``max(r, 0)`` inside the fold.

    Spot-pinned rather than restated in full — the fixture asserts all forty
    cells against an independent ascending-fold reference and
    :func:`test_fixture_inline_assertions_pass_at_zero_tolerance` runs those. The
    cells chosen here are ones where the CLAMP fires, so a linear closed form or
    a Neumann-series shortcut lands elsewhere.
    """
    cells = [float(x) for x in _sweep_fixture_07()]
    assert len(cells) == 40
    assert cells[0] == 1.05
    assert cells[1] == -1.2625000000000002
    assert cells[6] == -0.24228653906279987
    assert cells[39] == 0.7630192556962501


def _sweep_fixture_07() -> np.ndarray:
    """Fixture 07's ``r``, straight through the sweep."""
    file = load_path(str(_RECURRENCE_DIR / "07_recurrence_thirty_eight_lags.esm"))
    model = next(iter(file.models.values()))
    ctx = EvalContext(
        state_layout={},
        state_shapes={},
        param_values={},
        observed_values={},
        y=np.empty(0, dtype=float),
        t=0.0,
        index_sets=file.index_sets or {},
    )
    swept = sweep_recurrence("r", model.equations[0].rhs, ctx)
    assert swept is not None
    return swept


# ---------------------------------------------------------------------------
# 5. The shared cross-binding rejection corpus
# ---------------------------------------------------------------------------

_REJECTION_CORPUS = FIXTURES_ROOT / "conformance" / "recurrence" / "rejections.json"


def _corpus_cases() -> list[dict]:
    if not _REJECTION_CORPUS.is_file():
        return []
    return list(json.loads(_REJECTION_CORPUS.read_text()).get("cases") or [])


@pytest.mark.parametrize(
    "case", _corpus_cases(), ids=[c.get("id", str(i)) for i, c in enumerate(_corpus_cases())]
)
def test_shared_rejection_corpus_pins_the_code_and_the_path(case: dict) -> None:
    """Every malformed self-read the SHARED corpus lists, at its pinned pointer.

    The corpus pins the ``code`` and the JSON-pointer ``path`` and deliberately
    NOT the prose — the same defect legitimately reads differently depending on
    which check reached it first, so testing one binding against another's
    wording would make the first reworded message a conformance failure. This
    test therefore asserts the pair and nothing else.
    """
    records = []
    try:
        load_string(json.dumps(case["document"]))
    except SchemaValidationError as err:
        records = list(getattr(err, "records", []))
    pairs = [(r["code"], r["path"]) for r in records]
    assert (case["expected_code"], case["expected_path"]) in pairs, (
        f"{case.get('id')}: {case.get('why', '')}\n  got {pairs}"
    )


def test_the_rejection_corpus_is_actually_present() -> None:
    """The parametrization above is silently empty if the corpus file moves, so
    its presence is asserted separately rather than left to a zero-case run."""
    assert _REJECTION_CORPUS.is_file(), f"shared rejection corpus missing: {_REJECTION_CORPUS}"
    assert _corpus_cases(), "the shared rejection corpus lists no cases"
