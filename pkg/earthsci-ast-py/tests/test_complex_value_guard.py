"""`^` must not leave the reals silently — esm-spec §4.3.4.

`x^0.333333333` with `x = -2.5` is complex. On a numpy ARRAY operand numpy
already answers `nan`, which is what the Rust binding returns; but on a PYTHON
scalar operand Python's own `**` answers a `complex`, and every place the
interpreter casts an evaluated body to a real would either raise an unnamed
`TypeError` or — through `astype` / `np.asarray` on a numpy complex — silently
DISCARD the imaginary part behind a `ComplexWarning` nothing escalates, handing
back 0.6786044051723126: a plausible wrong number, the worst of the three
possible outcomes. Julia raises `DomainError`; Python now raises the named
:class:`ComplexValueError` at the cast, on every path that reaches one.

Checked at the CAST, not inside the `^` kernel, because the interpreter's
`ifelse` is EAGER: a branch that is evaluated but not selected must not fail a
model whose taken branch is perfectly real.
"""

from __future__ import annotations

import numpy as np
import pytest

from earthsci_ast.numpy_interpreter import ComplexValueError, NumpyInterpreterError
from earthsci_ast.prepare import observed_field, prepare

CUBE_ROOT = 0.333333333


def _doc(expression, shape=None, extra_vars=None):
    variables = {"x": {"type": "parameter", "default": -2.5}}
    variables.update(extra_vars or {})
    variables["y"] = {
        "type": "observed",
        "expression": expression,
        **({"shape": list(shape)} if shape else {}),
    }
    return {
        "esm": "0.9.0",
        "metadata": {"name": "complex_guard"},
        "index_sets": {"n": {"kind": "interval", "size": 3}},
        "models": {"M": {"variables": variables, "equations": []}},
    }


def _pow_x():
    return {"op": "^", "args": ["x", CUBE_ROOT]}


@pytest.mark.parametrize(
    "label,shape,expression",
    [
        # the plain scalar observed
        ("scalar", None, _pow_x()),
        # the pure-map materializer (`np.asarray(..., dtype=float)`)
        (
            "map",
            ["n"],
            {
                "op": "aggregate",
                "output_idx": ["i"],
                "ranges": {"i": {"from": "n"}},
                "args": ["x"],
                "expr": _pow_x(),
            },
        ),
        # the scalar reducing aggregate (`float(eval_expr(body, ctx))`)
        (
            "reduce",
            None,
            {
                "op": "aggregate",
                "output_idx": [],
                "ranges": {"i": {"from": "n"}},
                "args": ["x"],
                "expr": _pow_x(),
            },
        ),
        # a SELECTED ifelse branch
        ("ifelse_taken", None, {"op": "ifelse", "args": [{"op": "true", "args": []}, _pow_x(), 1.0]}),
    ],
)
def test_complex_result_is_a_named_error_not_a_plausible_number(label, shape, expression):
    with pytest.raises(ComplexValueError) as exc:
        prepare(_doc(expression, shape), model_name="M")
    msg = str(exc.value)
    assert "COMPLEX" in msg
    # The value the silent cast would have truncated is NAMED in the diagnostic,
    # imaginary part and all — never handed back as the answer.
    assert "0.678604" in msg and "1.175377" in msg


def test_complex_value_error_is_not_swallowed_by_the_decline_or_skip_handlers():
    """`ComplexValueError` is deliberately NOT a `NumpyInterpreterError`.

    Half the interpreter catches that class to DECLINE to a slower path, and
    the tolerant build-time hoist catches it to SKIP an observed whose inputs
    are not yet bound. Neither reaction is right for a value that left the
    reals: no slower path yields a real answer, and the observed is not
    unresolved — it is wrong."""
    assert not issubclass(ComplexValueError, NumpyInterpreterError)


def test_untaken_eager_ifelse_branch_stays_evaluable():
    """The guard is at the CAST, so a complex value in a branch that is
    evaluated but NOT selected costs nothing — the taken branch is real, and a
    complex dtype whose imaginary part is identically zero is projected back
    onto the reals rather than rejected."""
    prep = prepare(
        _doc({"op": "ifelse", "args": [{"op": "false", "args": []}, _pow_x(), 1.0]}),
        model_name="M",
    )
    assert observed_field(prep, "y") == 1.0


def test_real_powers_are_untouched():
    prep = prepare(_doc({"op": "^", "args": [4.0, 0.5]}), model_name="M")
    assert observed_field(prep, "y") == 2.0


def test_array_operand_keeps_numpy_nan_semantics():
    """On an ARRAY operand numpy's real `power` already answers `nan` — the
    Rust binding's behaviour — and nothing here changes that."""
    doc = _doc(
        {
            "op": "aggregate",
            "output_idx": ["i"],
            "ranges": {"i": {"from": "n"}},
            "args": ["v"],
            "expr": {"op": "^", "args": [{"op": "index", "args": ["v", "i"]}, CUBE_ROOT]},
        },
        shape=["n"],
        extra_vars={"v": {"type": "parameter", "default": 0.0, "shape": ["n"]}},
    )
    prep = prepare(doc, const_arrays={"M.v": np.array([-2.5, 8.0, -1.0])}, model_name="M")
    got = observed_field(prep, "y")
    assert np.isnan(got[0]) and np.isnan(got[2])
    assert got[1] == pytest.approx(2.0, rel=1e-8)
