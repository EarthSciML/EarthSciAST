"""Regression tests for boolean-valued selections under ``cse=True`` (#192).

``esm_problem(..., cse=True)`` failed on scalar-pathway documents whose RHS
uses ``ifelse`` over a relational whose operand is itself an ``ifelse``::

    Simulation failed: invalid entry 0 in condlist: should be boolean ndarray

The chain is:

1. ``ifelse`` lowers to ``sympy.Piecewise``. A relational over an ``ifelse``
   result — ``ifelse(ζ <= 1, …)`` where ``ζ`` is itself an ``ifelse`` — folds
   at construction into ``Piecewise((a <= 1, c), (b <= 1, True))``: a
   Piecewise whose branch VALUES are booleans.
2. Dropped into the condition slot of the enclosing ``Piecewise``, SymPy
   canonicalizes that to ``ITE``.
3. SymPy's ``NumPyPrinter`` lowers ``ITE`` (via a rewrite to ``Piecewise``) to
   ``numpy.select(conds, vals, default=numpy.nan)``, which — because of the
   ``nan`` default — always returns a FLOAT array. A boolean selection comes
   back as ``0.0``/``1.0``.
4. ``numpy.select`` rejects that float when it is the condition of the
   enclosing selection, with the message above.

Step 3 only bites under CSE. Without it, the enclosing ``_print_Piecewise``
special-cases a condition containing ``ITE`` and routes it through
``simplify_logic`` (emitting ``logical_and``/``logical_or``); with
``cse=True`` the shared ``ITE`` is hoisted into its own temporary, printed on
its own, and that escape hatch never fires — which is why the bug is
CSE-only, and why the fix is a printer (``sympy_bridge._EsmNumPyPrinter``)
that keeps a boolean selection boolean in ANY position.

Test A drives the canonical pipeline (programmatic ESM AST → flatten →
``esm_problem`` → ``solve``) per AGENTS.md "Simulation runner pathway
(ABSOLUTE)"; tests B and C pin the printer behaviour and bake in the
disconfirmation evidence against stock SymPy printing.
"""

from __future__ import annotations

import numpy as np
import pytest
import sympy as sp
from sympy.logic.boolalg import ITE
from sympy.printing.numpy import NumPyPrinter

from earthsci_ast.esm_types import (
    EsmFile,
    Equation,
    Metadata,
    Model,
    ModelVariable,
)
from earthsci_ast.expression import ExprNode
from earthsci_ast.problem import ReturnCode, esm_problem, solve
from earthsci_ast.sympy_bridge import (
    _LAMBDIFY_MODULES,
    _EsmNumPyPrinter,
    _lambdify,
)


def _node(op: str, *args) -> ExprNode:
    return ExprNode(op=op, args=list(args))


def _boolean_condition_model() -> EsmFile:
    """Smallest document that reproduces #192.

    ``ζ`` is an ``ifelse``; ``φ_m`` and ``φ_h`` both branch on ``ζ <= 1``,
    so the boolean-valued selection that relational folds into is a COMMON
    subexpression — which is what makes CSE hoist it into a temporary. The
    decay state ``c`` puts the same shared selection in the differential RHS
    as well, covering both of ``_compile_flat_rhs``'s lambdify calls.

    With the defaults below (``L = 100 > 0``, ``ζ = z / L_min = 2 > 1``):
    ``φ_m = 1 + ζ = 3``, ``φ_h = 2 + ζ = 4``, and ``c(t) = exp(-7 t)``.
    """
    zeta = _node(
        "ifelse",
        _node("<", "L", 0.0),
        _node("/", _node("-", "z"), "L_min"),
        _node("/", "z", "L_min"),
    )

    def phi(offset: float) -> ExprNode:
        # ``ζ <= 1`` folds to a boolean-valued Piecewise because ζ is one;
        # as this inner ifelse's condition it becomes an ITE.
        stable = _node(
            "ifelse",
            _node("<=", "zeta", 1.0),
            _node("+", offset, _node("*", 5.0, "zeta")),
            _node("+", offset, "zeta"),
        )
        return _node("ifelse", _node(">", "L", 0.0), stable, offset)

    model = Model(
        name="BoolCond",
        variables={
            "zeta": ModelVariable(type="unknown"),
            "phi_m": ModelVariable(type="unknown"),
            "phi_h": ModelVariable(type="unknown"),
            "c": ModelVariable(type="unknown", default=1.0),
            "L": ModelVariable(type="parameter", default=100.0),
            "z": ModelVariable(type="parameter", default=10.0),
            "L_min": ModelVariable(type="parameter", default=5.0),
        },
        equations=[
            Equation(lhs="zeta", rhs=zeta),
            Equation(lhs="phi_m", rhs=phi(1.0)),
            Equation(lhs="phi_h", rhs=phi(2.0)),
            Equation(
                lhs=ExprNode(op="D", args=["c"], wrt="t"),
                rhs=_node("-", _node("*", _node("+", "phi_m", "phi_h"), "c")),
            ),
        ],
    )
    return EsmFile(
        version="1.0.0",
        metadata=Metadata(title="boolean-condition cse regression"),
        models={"BoolCond": model},
    )


def _final_values(esm: EsmFile, cse: bool, p: dict[str, float]) -> dict[str, float]:
    res = solve(esm_problem(esm, (0.0, 1.0), p=p, cse=cse), reltol=1e-10, abstol=1e-12)
    assert res.retcode is ReturnCode.Success, res.message
    return {name.split(".")[-1]: float(res.y[i, -1]) for i, name in enumerate(res.vars)}


@pytest.mark.parametrize(
    "overrides,phi_m,phi_h",
    [
        # ζ = z / L_min = 2 > 1 → the unstable arm: φ = offset + ζ.
        ({}, 3.0, 4.0),
        # ζ = 10 / 20 = 0.5 <= 1 → the stable arm: φ = offset + 5 ζ.
        ({"BoolCond.L_min": 20.0}, 3.5, 4.5),
    ],
    ids=["unstable-arm", "stable-arm"],
)
def test_a_boolean_condition_model_solves_and_agrees_under_cse(overrides, phi_m, phi_h):
    """``cse=True`` reaches the same answer as ``cse=False``, on both arms.

    Before the fix the ``cse=True`` build did not merely disagree — it
    returned ``ReturnCode.Failure`` with "invalid entry 0 in condlist"
    (``_final_values`` asserts Success, so a regression fails here first).
    Both arms are exercised because the hoisted temporary is the SELECTOR:
    a fix that returned a constant boolean would still pass one of them.
    """
    esm = _boolean_condition_model()
    no_cse = _final_values(esm, cse=False, p=overrides)
    with_cse = _final_values(esm, cse=True, p=overrides)

    assert no_cse["phi_m"] == pytest.approx(phi_m)
    assert no_cse["phi_h"] == pytest.approx(phi_h)
    assert with_cse["phi_m"] == pytest.approx(phi_m)
    assert with_cse["phi_h"] == pytest.approx(phi_h)
    # c(1) = exp(-(φ_m + φ_h)); the shared selection reaches the ODE RHS too.
    assert with_cse["c"] == pytest.approx(np.exp(-(phi_m + phi_h)), rel=1e-6)
    for name, value in no_cse.items():
        assert with_cse[name] == pytest.approx(value, rel=1e-12, abs=1e-14)


def test_b_hoisted_boolean_selection_stays_boolean():
    """A standalone ``ITE`` — what CSE hoisting produces — lambdifies to a
    boolean, and remains usable as the condition of an enclosing selection.

    This is the printer contract in isolation: ``x`` picks between two
    RELATIONALS, so its value must be ``True``/``False``, not ``1.0``/``0.0``.
    """
    a, b = sp.symbols("a b")
    ite = ITE(a > 0, a < 1, b < 1)

    func = _lambdify([a, b], ite, modules=_LAMBDIFY_MODULES)
    assert np.asarray(func(0.5, 5.0)).dtype == np.bool_
    assert bool(func(0.5, 5.0)) is True  # a > 0 → a < 1
    assert bool(func(5.0, 0.5)) is False  # a > 0 → a < 1
    assert bool(func(-1.0, 0.5)) is True  # a <= 0 → b < 1
    assert bool(func(-1.0, 5.0)) is False

    # The hoisted value feeding an enclosing Piecewise is the shape that
    # raised "invalid entry 0 in condlist" — it must select cleanly.
    outer = sp.Piecewise((sp.Float(10.0), ite), (sp.Float(20.0), True))
    outer_func = _lambdify([a, b], outer, modules=_LAMBDIFY_MODULES, cse=True)
    assert float(outer_func(0.5, 5.0)) == 10.0
    assert float(outer_func(-1.0, 5.0)) == 20.0

    # Same guarantee for a boolean-valued Piecewise that never reached ITE
    # form (three branches: SymPy leaves it as a Piecewise).
    pw = sp.Piecewise((a < 1, a > 0), (b < 1, b > 0), (sp.true, True))
    pw_func = _lambdify([a, b], pw, modules=_LAMBDIFY_MODULES)
    assert np.asarray(pw_func(0.5, 5.0)).dtype == np.bool_
    assert bool(pw_func(0.5, 5.0)) is True  # a > 0 → a < 1
    assert bool(pw_func(5.0, 0.5)) is False  # a > 0 → a < 1
    assert bool(pw_func(-1.0, 0.5)) is True  # b > 0 → b < 1
    assert bool(pw_func(-1.0, 5.0)) is False  # b > 0 → b < 1
    assert bool(pw_func(-1.0, -1.0)) is True  # the ``True`` tail


def test_c_pre_fix_disconfirmation_stock_printer_returns_float():
    """Stock SymPy printing of the same ``ITE`` yields a FLOAT, and NumPy
    rejects that float as a condition — the pre-fix failure, pinned.

    Keeping the broken path in the suite is what makes test B meaningful: it
    shows the boolean dtype there is the fix's doing and not something the
    default printer would have given us anyway.

    This pins THIRD-PARTY behaviour, so it skips rather than fails if SymPy
    ever fixes ITE printing upstream: "upstream fixed it" and "our fix broke"
    must not look the same, and only test B can tell us the latter.
    """
    a, b = sp.symbols("a b")
    ite = ITE(a > 0, a < 1, b < 1)
    settings = {
        "fully_qualified_modules": False,
        "inline": True,
        "allow_unknown_functions": True,
    }

    stock = NumPyPrinter(settings).doprint(ite)
    if "select(" not in stock or "default=nan" not in stock:
        pytest.skip(
            f"sympy {sp.__version__} no longer lowers a boolean ITE to "
            f"select(default=nan) — got {stock!r}; the #192 workaround in "
            "_EsmNumPyPrinter may now be redundant"
        )
    assert "select(" not in _EsmNumPyPrinter(settings).doprint(ite)
    assert "where(" in _EsmNumPyPrinter(settings).doprint(ite)

    stock_func = sp.lambdify([a, b], ite, modules=_LAMBDIFY_MODULES)
    stock_value = np.asarray(stock_func(0.5, 5.0))
    assert stock_value.dtype != np.bool_
    assert float(stock_value) == 1.0

    with pytest.raises(TypeError, match="should be boolean ndarray"):
        np.select([stock_value, True], [10.0, 20.0], default=np.nan)


# ---------------------------------------------------------------------------
# The printer must reroute ONLY selections it can prove are boolean.
#
# `Symbol` (and `Dummy`, which is what CSE hands back) subclass BOTH `Boolean`
# and `Expr`, so `isinstance(value, Boolean)` alone is true of every ordinary
# numeric variable — it classifies the everyday `ifelse(c, x, y)`, whose two
# branches are plain symbols, as "boolean". The tests below pin the three ways
# that misfires; each one is a SILENT wrong answer or a compile failure on
# models that have nothing to do with #192.
# ---------------------------------------------------------------------------


def test_d_numeric_piecewise_keeps_sympys_own_lowering():
    """A numeric ``Piecewise`` must print exactly as stock SymPy prints it.

    Three separate guarantees, all of which a `Boolean`-only predicate breaks
    because plain symbols pass it:

    1. ``default=nan``. A Piecewise with no ``True`` tail is UNDEFINED outside
       its conditions; ``select`` spells that ``nan``. Rerouting to a boolean
       fallback turns the undefined region into ``0.0`` — a fabricated number.
    2. Float promotion. ``select``'s ``nan`` default promotes an integer
       selection to float; a boolean fallback leaves it integer.
    3. The loud error on a non-boolean condition. ``ifelse`` over a bare
       numeric variable is a malformed model, and NumPy rejecting it is the
       only thing that says so — C-truthiness would silently accept ``nan``
       (which is truthy) as "take the first branch".
    """
    a, x, y = sp.symbols("a x y")

    # 1. Undefined outside the conditions stays nan, not 0.0.
    gap = sp.Piecewise((x, a > 0), (y, a < -1))
    assert np.isnan(float(_lambdify((a, x, y), gap, modules=_LAMBDIFY_MODULES)(0.0, 10.0, 20.0)))
    assert float(_lambdify((a, x, y), gap, modules=_LAMBDIFY_MODULES)(1.0, 10.0, 20.0)) == 10.0

    # 2. Integer branches still promote to float, as select does.
    total = sp.Piecewise((x, a > 0), (y, True))
    promoted = _lambdify((a, x, y), total, modules=_LAMBDIFY_MODULES)(
        np.int64(3), np.int64(4), np.int64(1)
    )
    assert np.asarray(promoted).dtype.kind == "f"

    # 3. A bare numeric variable as a condition still raises, loudly.
    bad = sp.Piecewise((x, a), (y, True))
    bad_func = _lambdify((a, x, y), bad, modules=_LAMBDIFY_MODULES)
    with pytest.raises(TypeError, match="should be boolean ndarray"):
        bad_func(0.5, 10.0, 20.0)

    # All three hold identically under CSE — the printer, not the CSE step,
    # decides, so cse=True and cse=False cannot diverge.
    assert np.isnan(
        float(_lambdify((a, x, y), gap, modules=_LAMBDIFY_MODULES, cse=True)(0.0, 10.0, 20.0))
    )


def test_d2_wide_flat_selection_still_compiles():
    """A boolean selection stays FLAT: one ``select`` call, not N nested calls.

    Folding N branches into N nested ``numpy.where`` calls produces
    N-deep source, and CPython refuses to parse past 200 levels of nested
    parentheses — so a wide lookup-table selection would fail to compile at
    all, under any ``cse`` setting.
    """
    a = sp.Symbol("a")
    values = sp.symbols("v0:240")

    numeric = sp.Piecewise(*[(values[i], a < i) for i in range(240)])
    assert _lambdify((a, *values), numeric, modules=_LAMBDIFY_MODULES) is not None

    boolean = sp.Piecewise(*[(values[i] < 1, a < i) for i in range(240)])
    wide = _lambdify((a, *values), boolean, modules=_LAMBDIFY_MODULES)
    # ...and the wide boolean one is still boolean.
    assert np.asarray(wide(0.5, *([0.0] * 240))).dtype == np.bool_


def test_e_boolean_cse_temporary_shared_by_boolean_and_numeric_consumers():
    """The hoisted-temporary gap: a boolean selection ALL of whose branches
    are themselves CSE temporaries.

    ``ITE(e > 0, x0, x1)`` where ``x0``/``x1`` are hoisted symbols is
    indistinguishable from a numeric ``ifelse(c, x, y)`` by inspecting the
    expression alone — both are "an ITE over two bare symbols". It arises
    whenever a boolean subexpression is shared by a boolean consumer AND a
    numeric one, so CSE hoists it. ``_boolean_aware_cse`` closes the gap by
    classifying each temporary as it is created.
    """
    a, b, c, d, e = sp.symbols("a b c d e")
    left = sp.And(a > 0, b > 0)
    right = sp.Or(c > 0, d > 0)
    shared = ITE(e > 0, left, right)

    exprs = [
        # two boolean consumers of `shared`, so `shared` itself is hoisted...
        sp.Piecewise((sp.Float(1.0), shared), (sp.Float(2.0), True)),
        sp.Piecewise((sp.Float(3.0), shared), (sp.Float(4.0), True)),
        # ...and one more consumer each of its branches, so THEY are hoisted too.
        sp.Piecewise((sp.Float(5.0), left), (sp.Float(6.0), True)),
        sp.Piecewise((sp.Float(7.0), right), (sp.Float(8.0), True)),
    ]
    args = (a, b, c, d, e)
    no_cse = _lambdify(args, exprs, modules=_LAMBDIFY_MODULES, cse=False)
    with_cse = _lambdify(args, exprs, modules=_LAMBDIFY_MODULES, cse=True)

    for values, expected in (
        ((1.0, 1.0, -1.0, -1.0, 1.0), [1.0, 3.0, 5.0, 8.0]),  # e > 0 → left, true
        ((-1.0, 1.0, -1.0, -1.0, 1.0), [2.0, 4.0, 6.0, 8.0]),  # e > 0 → left, false
        ((-1.0, 1.0, 1.0, -1.0, -1.0), [1.0, 3.0, 6.0, 7.0]),  # e <= 0 → right, true
        ((-1.0, 1.0, -1.0, -1.0, -1.0), [2.0, 4.0, 6.0, 8.0]),  # e <= 0 → right, false
    ):
        assert [float(v) for v in with_cse(*values)] == pytest.approx(expected)
        assert [float(v) for v in no_cse(*values)] == pytest.approx(expected)


@pytest.mark.parametrize(
    "make_cond,expected",
    [
        (lambda z, a: z <= 1, [1.0, 9.0]),
        (lambda z, a: z < 1, [0.0, 8.0]),
        (lambda z, a: z >= 1, [1.0, 9.0]),
        (lambda z, a: z > 1, [0.0, 8.0]),
        (lambda z, a: sp.Eq(z, 1), [1.0, 9.0]),
        (lambda z, a: sp.Ne(z, 1), [0.0, 8.0]),
        (lambda z, a: sp.And(z <= 1, a > 0), [1.0, 9.0]),
        (lambda z, a: sp.Or(z > 1, a < 0), [0.0, 8.0]),
        (lambda z, a: sp.Not(z <= 1), [0.0, 8.0]),
    ],
    ids=["le", "lt", "ge", "gt", "eq", "ne", "and", "or", "not"],
)
def test_f_relational_and_logical_ops_over_a_folded_selection(make_cond, expected):
    """Every comparison and connective over an ``ifelse``-folded operand
    agrees between ``cse=True`` and ``cse=False``.

    ``z`` is a Piecewise, so ``z <= 1`` folds into a boolean-VALUED Piecewise
    at construction — the #192 shape. Sharing the condition between two
    consumers is what makes CSE hoist it.
    """
    a, b = sp.symbols("a b")
    z = sp.Piecewise((-a, b < 0), (a, True))  # a = 1, b = 1 → z = 1
    cond = make_cond(z, a)
    exprs = [
        sp.Piecewise((sp.Float(1.0), cond), (sp.Float(0.0), True)),
        sp.Piecewise((sp.Float(9.0), cond), (sp.Float(8.0), True)),
    ]

    for cse in (False, True):
        func = _lambdify((a, b), exprs, modules=_LAMBDIFY_MODULES, cse=cse)
        assert [float(v) for v in func(1.0, 1.0)] == pytest.approx(expected)
