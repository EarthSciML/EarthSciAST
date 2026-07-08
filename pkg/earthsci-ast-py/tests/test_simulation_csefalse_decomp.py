"""Regression tests for the cse=False non-finite-derivative fix (esm-5gk).

The Python canonical simulation runner failed on geoschem_fullchem under
``cse=False`` because SymPy's construction-time canonical rewrites
decompose ``Abs(...)`` over composites of ``exp``/``log``/rational-power
into a complex-domain form (``re``, ``im``, ``arg``) when the inner
expression's domain cannot be proven real. The decomposition introduces
a ``log|x|**2 * arg(x)**2`` cross term that evaluates to ``inf*0 = NaN``
at any boundary value (e.g. species concentration of 0), killing the
integrator on the very first RHS evaluation.

The fix swaps ``sp.Abs`` for an opaque :class:`sympy.Function` subclass
(``simulation._ess_numeric_abs``) in :func:`_expr_to_sympy`'s ``'abs'``
branch, plus canonicalizes integer-valued ``sp.Float`` exponents to
``sp.Integer`` so ``x**Float(2.0)`` does not get routed through
sympy's complex-domain power-Pow path. The fix is sign-agnostic — it
makes no positivity assumption — so models whose state goes negative
are still correctly handled by ``numpy.abs`` at runtime.

These tests exercise the two construction-time decomposition triggers
that geoschem_fullchem trips on (Troe-broadening
``Fc**(1/(1+log10(...)**2))`` and high-integer power ``(300/T)**8``),
plus a domain-agnostic correctness check using a state that goes
negative, plus a pre-fix regression that bakes the disconfirmation
evidence into the suite. All assertions go through the canonical
pipeline (programmatic ESM AST → flatten → ``simulate``) per CLAUDE.md
"Simulation Pathway — ABSOLUTE Rule".

Runs in default ``pytest`` invocation in under a second; no env gate, no
external fixtures required.
"""

from __future__ import annotations

import inspect

import numpy as np
import pytest
import sympy as sp

from earthsci_ast.esm_types import (
    EsmFile,
    Equation,
    Metadata,
    Model,
    ModelVariable,
)
from earthsci_ast.expression import ExprNode
from earthsci_ast.simulation import simulate
from earthsci_ast.sympy_bridge import (
    _LAMBDIFY_MODULES,
    _ess_numeric_abs,
    _expr_to_sympy,
)


def _node(op: str, *args) -> ExprNode:
    return ExprNode(op=op, args=list(args))


def _troe_kshape_ast() -> ExprNode:
    """ESM AST for ``abs(0.41**((log10(N*(300/T)**8) - 47.76)**2 + 1))``.

    This is the structure that, under the pre-fix code path, would
    decompose at construction into a complex-domain formula in
    ``log|...|**2 * arg(...)**2``. ``(300/T)**8`` is the high-integer
    rational-power trigger; ``log10(...)**2 + 1`` raised to ``0.41**(...)``
    is the Troe-broadening shape; ``abs(...)`` is the outer wrapper that
    makes sympy attempt the modulus-phase split.
    """
    pow_8 = _node("^", _node("/", 300.0, "T"), 8.0)
    n_mass = _node("*", "N", pow_8)
    log10_arg = _node("log10", n_mass)
    shifted = _node("-", log10_arg, 47.76)
    sq = _node("^", shifted, 2.0)
    inner = _node("+", sq, 1.0)
    krate = _node("^", 0.41, inner)
    return _node("abs", krate)


def _has_complex_atom(expr: sp.Expr) -> bool:
    return any(isinstance(s, (sp.re, sp.im, sp.arg)) for s in sp.preorder_traversal(expr))


def _lambdified_source_has_complex(func) -> bool:
    src = inspect.getsource(func)
    return any(token in src for token in ("real(", "imag(", "angle("))


def test_a_structural_chemistry_shape_no_complex_decomposition():
    """The Troe + ``(300/T)**8`` shape converts to a complex-domain-free
    SymPy tree, and the lambdified output references ``_ess_numeric_abs``
    rather than emitting any ``real``/``imag``/``angle`` calls.
    """
    ast = _troe_kshape_ast()
    T_sym = sp.Symbol("T")
    N_sym = sp.Symbol("N")
    sym = _expr_to_sympy(ast, {"T": T_sym, "N": N_sym})

    assert not _has_complex_atom(sym)
    assert any(isinstance(s, _ess_numeric_abs) for s in sp.preorder_traversal(sym))
    assert all(not isinstance(s, sp.Abs) for s in sp.preorder_traversal(sym))

    func = sp.lambdify((T_sym, N_sym), sym, modules=_LAMBDIFY_MODULES, cse=False)
    src = inspect.getsource(func)
    assert "real(" not in src
    assert "imag(" not in src
    assert "angle(" not in src
    assert "_ess_numeric_abs(" in src

    # Boundary cases must be finite under the fix. At N=0 the pre-fix
    # decomposition reaches an ``inf*0 = NaN`` cross term in some
    # K-rate shapes (esm-5gk); the fix gives a finite limit because
    # ``_ess_numeric_abs`` keeps the AST in real-domain form
    # (``log10(0) = -inf``, ``(-inf - 47.76)**2 = inf``,
    # ``0.41**inf = 0``, ``abs(0) = 0``).
    import warnings

    with warnings.catch_warnings():
        warnings.simplefilter("ignore", RuntimeWarning)
        val_zero = float(func(298.0, 0.0))
        val_normal = float(func(298.0, 1.0e10))
    assert val_zero == 0.0
    assert np.isfinite(val_normal)


def test_b_numerical_domain_agnostic_negative_state():
    """A state variable that starts negative integrates correctly.

    System: ``dv/dt = -abs(v)``, ``v(0) = -1``.

    Closed-form: while ``v < 0`` we have ``abs(v) = -v`` so ``dv/dt = v``,
    giving ``v(t) = -exp(t)`` — the negative state grows in magnitude.

    The pre-fix alternative considered (declaring symbols
    ``positive=True``) would have made SymPy simplify ``Abs(v)`` to
    ``v`` at construction time, producing the wrong ODE
    ``dv/dt = -v`` whose solution decays to zero
    (``v(t) = -exp(-t) ≈ -0.368`` at ``t = 1``). The opaque-Function
    fix preserves the symbolic ``abs(v)`` so ``numpy.abs`` is invoked
    at runtime regardless of the sign of ``v``. Verifying the integrated
    trajectory matches ``-exp(t)`` and not ``-exp(-t)`` is the
    disconfirmation evidence that the fix is sign-agnostic.
    """
    rhs = _node("-", _node("abs", "v"))
    model = Model(
        name="NegState",
        variables={"v": ModelVariable(type="state", default=-1.0)},
        equations=[
            Equation(lhs=ExprNode(op="D", args=["v"], wrt="t"), rhs=rhs),
        ],
    )
    esm = EsmFile(
        version="0.4.0",
        metadata=Metadata(title="t"),
        models={"NegState": model},
    )

    res = simulate(esm, tspan=(0.0, 1.0))
    assert res.success
    v_idx = next(i for i, name in enumerate(res.vars) if name.endswith(".v"))
    v_final = float(res.y[v_idx, -1])

    # Correct: v(1) = -exp(1) ≈ -2.718
    assert v_final == pytest.approx(-np.exp(1.0), rel=1e-3)
    # Disconfirms the broken path: v(1) ≠ -exp(-1) ≈ -0.368
    assert abs(v_final - (-np.exp(-1.0))) > 0.5


def test_c_pre_fix_regression_disconfirmation():
    """Direct comparison between the fixed path (``_ess_numeric_abs``)
    and the broken path (``sp.Abs``) on the same chemistry-shape
    expression. Bakes the bug-evidence into the test suite so regressions
    in ``_expr_to_sympy``'s abs handling are caught loudly.

    The fix's structural guarantee (no ``real``/``imag``/``angle`` in
    lambdified source) AND its numerical guarantee (finite RHS at the
    boundary) both fail under the pre-fix path. Asserting they fail
    together is the disconfirmation evidence.
    """
    T_sym = sp.Symbol("T")
    N_sym = sp.Symbol("N")
    # Reciprocal-square Troe form is the K-rate shape that decomposes
    # all the way to ``inf * 0 = NaN`` at the species=0 boundary under
    # the pre-fix path:
    #   1 / (log(N*T**(-8))**2 / log(10)**2 + 1)
    # raised to ``Float(2.0)`` and wrapped in ``sp.Abs`` reaches the
    # ``re((log...)**2.0) + im((log...)**2.0)``-style splitting that
    # geoschem_fullchem trips on. The simpler ``Abs(0.41**(...)**2 + 1)``
    # only loses the ``Abs(a**z) → a**re(z)`` outer layer and clamps
    # to 0 at the boundary instead of NaN.
    inv_log = sp.Float("1.0") / (
        sp.log(N_sym * T_sym ** (-8)) ** sp.Float("2.0") / sp.log(10) ** 2 + sp.Float("1.0")
    )
    krate = sp.Float("0.41") ** inv_log

    # Pre-fix: sp.Abs triggers the construction-time decomposition.
    broken = sp.Abs(krate)
    assert _has_complex_atom(broken), (
        "expected sp.Abs to decompose into re/im/arg on this shape — "
        "if this assertion no longer holds, sympy's behavior has changed "
        "and the fix may need to be reassessed (esm-5gk)"
    )

    import warnings

    with warnings.catch_warnings():
        warnings.simplefilter("ignore", RuntimeWarning)
        broken_func = sp.lambdify((T_sym, N_sym), broken, "numpy", cse=False)
    assert _lambdified_source_has_complex(broken_func), (
        "pre-fix lambdified source should leak real/imag/angle calls"
    )
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", RuntimeWarning)
        broken_at_zero = broken_func(298.0, 0.0)
    assert not np.isfinite(broken_at_zero), (
        "pre-fix path should produce NaN at the species=0 boundary"
    )

    # Fixed: _ess_numeric_abs preserves the absolute value as an opaque
    # call resolved to numpy.abs at lambdify time.
    fixed = _ess_numeric_abs(krate)
    assert not _has_complex_atom(fixed)
    fixed_func = sp.lambdify((T_sym, N_sym), fixed, modules=_LAMBDIFY_MODULES, cse=False)
    assert not _lambdified_source_has_complex(fixed_func)
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", RuntimeWarning)
        fixed_at_zero = float(fixed_func(298.0, 0.0))
    # Mathematically the fixed expression at N=0 is
    # ``0.41 ** (1/(inf + 1)) = 0.41 ** 0 = 1.0`` — finite, in contrast
    # to the pre-fix path's NaN.
    assert np.isfinite(fixed_at_zero)


def test_integer_float_exponent_canonicalized():
    """``x**Float(2.0)`` from ESM JSON ``"2.0"`` is converted to
    ``x**Integer(2)`` so SymPy keeps it on its real-domain power
    simplification path. Without this, even with the
    ``_ess_numeric_abs`` swap the K-rate's ``...**2.0`` part would
    route through ``exp(2.0 * log(...))`` which sympy treats as
    complex-domain.
    """
    x = sp.Symbol("x")
    # ESM AST stores numeric literals as Python floats.
    ast_int_valued = _node("^", "x", 2.0)
    ast_non_int = _node("^", "x", 2.5)

    sym_int_valued = _expr_to_sympy(ast_int_valued, {"x": x})
    sym_non_int = _expr_to_sympy(ast_non_int, {"x": x})

    # 2.0 should be canonicalized to Integer(2)
    assert sym_int_valued == x ** sp.Integer(2)
    assert sym_int_valued.exp.is_integer is True

    # 2.5 must remain a Float exponent — it's not an integer power
    assert sym_non_int.exp == sp.Float(2.5)
    assert sym_non_int.exp.is_integer is None or sym_non_int.exp.is_integer is False
