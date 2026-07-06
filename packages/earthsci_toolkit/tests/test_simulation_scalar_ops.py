"""Tests for added scalar-op coverage in `_expr_to_sympy` (esm-mvc).

The official ESS Python simulation runner (earthsci_toolkit.simulation) has
to round-trip every scalar AST op the schema declares. This file exercises
the ops added in esm-mvc — abs, min, max, pow, log10, sqrt, sign, floor,
ceil, tan/asin/acos/atan/atan2, ifelse, and/or/not — and the canonical
(a + abs(a)) / 2 max-clamp pattern from mdl-5r0 / hq-wisp-ywi that drove
this work.
"""

from __future__ import annotations

import math

import pytest
import sympy as sp

from earthsci_toolkit.esm_types import ExprNode
from earthsci_toolkit.simulation import SimulationError
from earthsci_toolkit.sympy_bridge import _expr_to_sympy


def _node(op: str, *args) -> ExprNode:
    return ExprNode(op=op, args=list(args))


@pytest.fixture
def x_sym():
    return sp.Symbol("x")


@pytest.fixture
def y_sym():
    return sp.Symbol("y")


@pytest.fixture
def symbol_map(x_sym, y_sym):
    return {"x": x_sym, "y": y_sym}


class TestAbs:
    def test_abs_positive(self, symbol_map, x_sym):
        # ``_expr_to_sympy`` returns the placeholder
        # ``sympy_bridge._ess_numeric_abs`` rather than ``sp.Abs`` so
        # SymPy's construction-time canonical rewrites for absolute
        # value cannot fire (esm-5gk). The placeholder evaluates
        # numerically on literal numbers, so substitution-based checks
        # behave identically to ``sp.Abs``.
        from earthsci_toolkit.sympy_bridge import _ess_numeric_abs

        result = _expr_to_sympy(_node("abs", "x"), symbol_map)
        assert result.func is _ess_numeric_abs
        assert result.args == (x_sym,)
        assert float(result.subs(x_sym, 3.5)) == pytest.approx(3.5)
        assert float(result.subs(x_sym, -2.25)) == pytest.approx(2.25)

    def test_max_clamp_pattern(self, symbol_map, x_sym):
        # The (a + abs(a)) / 2 pattern that triggered esm-mvc — clamps a to >= 0.
        clamp = _node("/", _node("+", "x", _node("abs", "x")), 2)
        sym = _expr_to_sympy(clamp, symbol_map)
        assert float(sp.simplify(sym.subs(x_sym, -3.0))) == pytest.approx(0.0)
        assert float(sp.simplify(sym.subs(x_sym, 4.0))) == pytest.approx(4.0)
        assert float(sp.simplify(sym.subs(x_sym, 0.0))) == pytest.approx(0.0)

    def test_abs_arity(self, symbol_map):
        with pytest.raises(SimulationError, match="abs"):
            _expr_to_sympy(_node("abs", "x", "y"), symbol_map)


class TestMinMax:
    def test_min_two_arg(self, symbol_map, x_sym, y_sym):
        result = _expr_to_sympy(_node("min", "x", "y"), symbol_map)
        assert float(result.subs([(x_sym, 1.5), (y_sym, 0.75)])) == pytest.approx(0.75)
        assert float(result.subs([(x_sym, -1), (y_sym, -2)])) == pytest.approx(-2)

    def test_max_two_arg(self, symbol_map, x_sym, y_sym):
        result = _expr_to_sympy(_node("max", "x", "y"), symbol_map)
        assert float(result.subs([(x_sym, 1.5), (y_sym, 0.75)])) == pytest.approx(1.5)

    def test_min_n_ary(self, symbol_map, x_sym, y_sym):
        # min(x, y, 0) — the schema permits n-ary min/max.
        result = _expr_to_sympy(_node("min", "x", "y", 0), symbol_map)
        assert float(result.subs([(x_sym, 5), (y_sym, 3)])) == pytest.approx(0)
        assert float(result.subs([(x_sym, -5), (y_sym, 3)])) == pytest.approx(-5)

    def test_max_n_ary(self, symbol_map, x_sym, y_sym):
        result = _expr_to_sympy(_node("max", "x", "y", 0), symbol_map)
        assert float(result.subs([(x_sym, -5), (y_sym, -3)])) == pytest.approx(0)
        assert float(result.subs([(x_sym, 5), (y_sym, -3)])) == pytest.approx(5)

    def test_min_empty_rejected(self, symbol_map):
        with pytest.raises(SimulationError, match="min"):
            _expr_to_sympy(_node("min"), symbol_map)


class TestPow:
    def test_pow_alias(self, symbol_map, x_sym):
        # pow(x, 2) == x ** 2
        result_pow = _expr_to_sympy(_node("pow", "x", 2), symbol_map)
        result_caret = _expr_to_sympy(_node("^", "x", 2), symbol_map)
        assert result_pow == result_caret
        assert float(result_pow.subs(x_sym, 3)) == pytest.approx(9.0)

    def test_pow_fractional(self, symbol_map, x_sym):
        # pow(x, 0.5) == sqrt
        result = _expr_to_sympy(_node("pow", "x", 0.5), symbol_map)
        assert float(result.subs(x_sym, 16)) == pytest.approx(4.0)

    def test_pow_arity(self, symbol_map):
        with pytest.raises(SimulationError, match="ower"):
            _expr_to_sympy(_node("pow", "x"), symbol_map)


class TestLog10Sqrt:
    def test_log10(self, symbol_map, x_sym):
        result = _expr_to_sympy(_node("log10", "x"), symbol_map)
        assert float(result.subs(x_sym, 1000.0)) == pytest.approx(3.0)
        assert float(result.subs(x_sym, 1.0)) == pytest.approx(0.0)

    def test_sqrt(self, symbol_map, x_sym):
        result = _expr_to_sympy(_node("sqrt", "x"), symbol_map)
        assert float(result.subs(x_sym, 49.0)) == pytest.approx(7.0)


class TestSignFloorCeil:
    def test_sign(self, symbol_map, x_sym):
        result = _expr_to_sympy(_node("sign", "x"), symbol_map)
        assert int(result.subs(x_sym, 5.0)) == 1
        assert int(result.subs(x_sym, -5.0)) == -1
        assert int(result.subs(x_sym, 0.0)) == 0

    def test_floor(self, symbol_map, x_sym):
        result = _expr_to_sympy(_node("floor", "x"), symbol_map)
        assert int(result.subs(x_sym, 3.7)) == 3
        assert int(result.subs(x_sym, -3.7)) == -4

    def test_ceil(self, symbol_map, x_sym):
        result = _expr_to_sympy(_node("ceil", "x"), symbol_map)
        assert int(result.subs(x_sym, 3.2)) == 4
        assert int(result.subs(x_sym, -3.7)) == -3


class TestTrigInverseAndAtan2:
    def test_tan(self, symbol_map, x_sym):
        result = _expr_to_sympy(_node("tan", "x"), symbol_map)
        assert float(result.subs(x_sym, 0)) == pytest.approx(0.0)

    def test_asin(self, symbol_map, x_sym):
        result = _expr_to_sympy(_node("asin", "x"), symbol_map)
        assert float(result.subs(x_sym, 1)) == pytest.approx(math.pi / 2)

    def test_acos(self, symbol_map, x_sym):
        result = _expr_to_sympy(_node("acos", "x"), symbol_map)
        assert float(result.subs(x_sym, 1)) == pytest.approx(0.0)

    def test_atan(self, symbol_map, x_sym):
        result = _expr_to_sympy(_node("atan", "x"), symbol_map)
        assert float(result.subs(x_sym, 1)) == pytest.approx(math.pi / 4)

    def test_atan2(self, symbol_map, x_sym, y_sym):
        result = _expr_to_sympy(_node("atan2", "y", "x"), symbol_map)
        assert float(result.subs([(y_sym, 1), (x_sym, 1)])) == pytest.approx(math.pi / 4)
        assert float(result.subs([(y_sym, 1), (x_sym, 0)])) == pytest.approx(math.pi / 2)


class TestIfElseAndBool:
    def test_ifelse(self, symbol_map, x_sym):
        # ifelse(x > 0, x, -x) == |x|
        result = _expr_to_sympy(
            _node("ifelse", _node(">", "x", 0), "x", _node("-", "x")),
            symbol_map,
        )
        assert float(result.subs(x_sym, 4)) == pytest.approx(4.0)
        assert float(result.subs(x_sym, -3)) == pytest.approx(3.0)

    def test_and(self, symbol_map, x_sym, y_sym):
        result = _expr_to_sympy(_node("and", _node(">", "x", 0), _node(">", "y", 0)), symbol_map)
        assert bool(result.subs([(x_sym, 1), (y_sym, 1)])) is True
        assert bool(result.subs([(x_sym, 1), (y_sym, -1)])) is False

    def test_or(self, symbol_map, x_sym, y_sym):
        result = _expr_to_sympy(_node("or", _node(">", "x", 0), _node(">", "y", 0)), symbol_map)
        assert bool(result.subs([(x_sym, -1), (y_sym, 1)])) is True
        assert bool(result.subs([(x_sym, -1), (y_sym, -1)])) is False

    def test_not(self, symbol_map, x_sym):
        result = _expr_to_sympy(_node("not", _node(">", "x", 0)), symbol_map)
        assert bool(result.subs(x_sym, -1)) is True
        assert bool(result.subs(x_sym, 1)) is False


class TestEndToEndSimulation:
    """Drive .simulate() on small models that exercise the new ops."""

    def test_clamp_decay_via_simulate(self):
        """dx/dt = -k * (x + abs(x)) / 2 — only positive x decays.

        Hand-pinned closed form: with x(0) = 2, k = 1, the solution is
        x(t) = 2 * exp(-t) for t in [0, ln 2]; with x(0) = -1 there's no
        decay because the clamp zeroes the rate.
        """
        from earthsci_toolkit.esm_types import (
            EsmFile,
            Metadata,
            Model,
            ModelVariable,
            Equation,
        )
        from earthsci_toolkit.simulation import simulate

        rhs = ExprNode(
            op="*",
            args=[
                -1.0,
                ExprNode(
                    op="/",
                    args=[
                        ExprNode(op="+", args=["x", ExprNode(op="abs", args=["x"])]),
                        2.0,
                    ],
                ),
            ],
        )
        model = Model(
            name="ClampDecay",
            variables={
                "x": ModelVariable(
                    type="state",
                    default=2.0,
                ),
            },
            equations=[
                Equation(
                    lhs=ExprNode(op="D", args=["x"], wrt="t"),
                    rhs=rhs,
                ),
            ],
        )
        esm = EsmFile(version="0.4.0", metadata=Metadata(title="t"), models={"ClampDecay": model})

        result = simulate(esm, tspan=(0.0, 1.0))
        # Final value: x(1) = 2 * e^{-1} ≈ 0.7357...
        x_idx = next(i for i, v in enumerate(result.vars) if v.endswith(".x"))
        x_final = result.y[x_idx, -1]
        assert x_final == pytest.approx(2.0 * math.exp(-1.0), rel=1e-3)

    def test_min_clamp_via_simulate(self):
        """dx/dt = min(0, -x) — only positive x decays; negative x stays."""
        from earthsci_toolkit.esm_types import (
            EsmFile,
            Metadata,
            Model,
            ModelVariable,
            Equation,
        )
        from earthsci_toolkit.simulation import simulate

        rhs = ExprNode(op="min", args=[0.0, ExprNode(op="-", args=["x"])])
        model = Model(
            name="MinClamp",
            variables={
                "x": ModelVariable(type="state", default=2.0),
            },
            equations=[
                Equation(lhs=ExprNode(op="D", args=["x"], wrt="t"), rhs=rhs),
            ],
        )
        esm = EsmFile(version="0.4.0", metadata=Metadata(title="t"), models={"MinClamp": model})

        result = simulate(esm, tspan=(0.0, 1.0))
        x_idx = next(i for i, v in enumerate(result.vars) if v.endswith(".x"))
        x_final = result.y[x_idx, -1]
        assert x_final == pytest.approx(2.0 * math.exp(-1.0), rel=1e-3)

    def test_pow_via_simulate(self):
        """dx/dt = -pow(x, 2) — Bernoulli-like, closed form 1/(1/x0 + t).

        x(0)=1 ⇒ x(1) = 1/2 = 0.5.
        """
        from earthsci_toolkit.esm_types import (
            EsmFile,
            Metadata,
            Model,
            ModelVariable,
            Equation,
        )
        from earthsci_toolkit.simulation import simulate

        rhs = ExprNode(op="-", args=[ExprNode(op="pow", args=["x", 2])])
        model = Model(
            name="PowDecay",
            variables={
                "x": ModelVariable(type="state", default=1.0),
            },
            equations=[
                Equation(lhs=ExprNode(op="D", args=["x"], wrt="t"), rhs=rhs),
            ],
        )
        esm = EsmFile(version="0.4.0", metadata=Metadata(title="t"), models={"PowDecay": model})

        result = simulate(esm, tspan=(0.0, 1.0))
        x_idx = next(i for i, v in enumerate(result.vars) if v.endswith(".x"))
        x_final = result.y[x_idx, -1]
        assert x_final == pytest.approx(0.5, rel=1e-3)
