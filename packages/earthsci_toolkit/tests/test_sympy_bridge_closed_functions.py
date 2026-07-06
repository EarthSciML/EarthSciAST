"""SymPy bridge support for ``fn`` / ``const`` closed-function ops (esm-6ka).

Regression tests for the SymPy/lambdify simulator path's handling of inline
``const`` arrays and ``fn`` calls into the closed-function registry. Before
this fix the bridge raised ``Unsupported operation: const`` whenever an ODE
RHS referenced ``interp.linear`` / ``interp.bilinear`` (or any other closed
function with materialized table / axis arguments), so EarthSciModels'
``fastjx.esm`` reported 45 ERROR / 0 PASS on the Python runner. The numpy
interpreter (``numpy_interpreter.py``) already handled both ops — this
brings the SymPy/lambdify path that ``simulate()`` uses for the ODE RHS up
to parity.
"""

from __future__ import annotations

import numpy as np
import pytest

from earthsci_toolkit.esm_types import (
    EsmFile,
    Equation,
    Metadata,
    Model,
    ModelVariable,
)
from earthsci_toolkit.expression import ExprNode
from earthsci_toolkit.simulation import simulate


def _const(value):
    return ExprNode(op="const", args=[], value=value)


def test_interp_linear_in_ode_rhs_runs_via_sympy_bridge():
    """``dx/dt = -k * interp.linear(table, axis, x)`` integrates correctly.

    Uses a closed-form-checkable choice: the table tabulates ``f(axis[i]) =
    axis[i]`` (identity), so ``interp.linear(table, axis, x) = x`` for any
    ``x`` in ``[axis[0], axis[-1]]`` and the ODE collapses to
    ``dx/dt = -k * x`` whose closed-form is ``x(t) = x0 * exp(-k*t)``.

    A pure-table-lookup integration is the disconfirmation evidence: if the
    bridge silently substituted ``0`` for the unknown ``fn`` op (the
    pre-fix failure mode if we'd routed through ``UnsupportedExprError``
    differently), ``x`` would stay at its initial value and the asserted
    ``exp(-k*t)`` decay would not hold.
    """
    fn_node = ExprNode(
        op="fn",
        name="interp.linear",
        args=[
            _const([0.0, 1.0, 2.0, 3.0, 4.0, 5.0]),  # table (identity)
            _const([0.0, 1.0, 2.0, 3.0, 4.0, 5.0]),  # axis
            "x",
        ],
    )
    rhs = ExprNode(op="*", args=[-0.5, fn_node])
    model = Model(
        name="M",
        variables={"x": ModelVariable(type="state", default=2.0)},
        equations=[Equation(lhs=ExprNode(op="D", args=["x"], wrt="t"), rhs=rhs)],
    )
    esm = EsmFile(
        version="0.4.0",
        metadata=Metadata(title="t"),
        models={"M": model},
    )

    res = simulate(esm, tspan=(0.0, 1.0))
    assert res.success, res.message

    x_idx = next(i for i, name in enumerate(res.vars) if name.endswith(".x"))
    x_final = float(res.y[x_idx, -1])
    # x(1) = 2 * exp(-0.5) ≈ 1.2131
    assert x_final == pytest.approx(2.0 * np.exp(-0.5), rel=1e-3)


def test_interp_bilinear_in_ode_rhs_runs_via_sympy_bridge():
    """``dx/dt = -interp.bilinear(table, ax, ay, p_x, p_y)`` with
    parameter-driven query coordinates.

    The bilinear table is constructed so that the lookup at ``(p_x=1.0,
    p_y=0.5)`` is exactly ``0.5`` (interior cell ``i=1, j=0``,
    ``wx=0.0``, ``wy=0.5``, blending between ``table[1][0]=0.0`` and
    ``table[1][1]=1.0``). The integrator then sees ``dx/dt = -0.5`` so
    the closed-form is ``x(t) = x0 - 0.5*t``.

    Mirrors the fastjx.esm shape: const table + const axes + dynamic
    parameter args. (esm-6ka acceptance.)
    """
    fn_node = ExprNode(
        op="fn",
        name="interp.bilinear",
        args=[
            _const([[0.0, 0.0], [0.0, 1.0], [0.0, 2.0]]),  # 3x2 table
            _const([0.0, 1.0, 2.0]),  # axis_x
            _const([0.0, 1.0]),  # axis_y
            "p_x",
            "p_y",
        ],
    )
    rhs = ExprNode(op="-", args=[fn_node])
    model = Model(
        name="M",
        variables={
            "x": ModelVariable(type="state", default=10.0),
            "p_x": ModelVariable(type="parameter", default=1.0),
            "p_y": ModelVariable(type="parameter", default=0.5),
        },
        equations=[Equation(lhs=ExprNode(op="D", args=["x"], wrt="t"), rhs=rhs)],
    )
    esm = EsmFile(
        version="0.4.0",
        metadata=Metadata(title="t"),
        models={"M": model},
    )

    res = simulate(esm, tspan=(0.0, 1.0))
    assert res.success, res.message

    x_idx = next(i for i, name in enumerate(res.vars) if name.endswith(".x"))
    x_final = float(res.y[x_idx, -1])
    # x(1) = 10 - 0.5 = 9.5
    assert x_final == pytest.approx(9.5, abs=1e-6)


def test_interp_bilinear_via_observed_variable_substitution():
    """The fn-call placeholder survives observed→differential substitution.

    Mirrors the fastjx.esm pattern where ``j_<species> = interp.bilinear(...)``
    is an observed variable and ``D(species)/dt = -j_<species> * species``
    references it by name. The SymPy bridge's observed-substitution pass
    folds the lookup body into the differential RHS, and the synthetic
    ``_ess_fn_<idx>`` placeholder must still resolve against the merged
    lambdify modules dict after substitution.
    """
    j_lookup = ExprNode(
        op="fn",
        name="interp.bilinear",
        args=[
            _const([[1.0, 1.0], [1.0, 1.0]]),  # constant 1.0 table
            _const([0.0, 1.0]),
            _const([0.0, 1.0]),
            "p_x",
            "p_y",
        ],
    )
    # D(c)/dt = -j_c * c, with j_c = interp.bilinear(...) observed.
    rhs = ExprNode(
        op="-",
        args=[ExprNode(op="*", args=["j_c", "c"])],
    )
    model = Model(
        name="M",
        variables={
            "c": ModelVariable(type="state", default=1.0),
            "j_c": ModelVariable(type="observed", expression=j_lookup),
            "p_x": ModelVariable(type="parameter", default=0.5),
            "p_y": ModelVariable(type="parameter", default=0.5),
        },
        equations=[Equation(lhs=ExprNode(op="D", args=["c"], wrt="t"), rhs=rhs)],
    )
    esm = EsmFile(
        version="0.4.0",
        metadata=Metadata(title="t"),
        models={"M": model},
    )

    res = simulate(esm, tspan=(0.0, 1.0))
    assert res.success, res.message

    c_idx = next(i for i, name in enumerate(res.vars) if name.endswith(".c"))
    c_final = float(res.y[c_idx, -1])
    # j_c == 1 everywhere → dc/dt = -c → c(1) = c0 * exp(-1)
    assert c_final == pytest.approx(np.exp(-1.0), rel=1e-3)
