"""Test expression manipulation and SymPy bridge functions.

End-to-end coverage of the canonical AST evaluator (``numpy_interpreter``)
lives in ``test_numpy_interpreter.py``; the few evaluator-call sites kept here
(``test_evaluate_*``) drive ``fold_constant_expr`` because ``simplify`` folds
through that helper and we want a regression hook adjacent to the simplifier
tests.
"""

import pytest
import sympy as sp
from earthsci_toolkit.expression import (
    free_variables, free_parameters, contains, simplify,
    to_sympy, from_sympy, symbolic_jacobian, SimulationError
)
from earthsci_toolkit.numpy_interpreter import fold_constant_expr
from earthsci_toolkit.esm_types import ExprNode, Model, ModelVariable, Equation


class TestBasicExpressionFunctions:
    """Test basic expression manipulation functions."""

    def test_free_variables_string(self):
        """Test free_variables with string variable."""
        vars = free_variables("x")
        assert vars == {"x"}

    def test_free_variables_number(self):
        """Test free_variables with numbers."""
        assert free_variables(5) == set()
        assert free_variables(3.14) == set()

    def test_free_variables_expr_node(self):
        """Test free_variables with ExprNode."""
        expr = ExprNode(op="+", args=["x", "y", 2])
        vars = free_variables(expr)
        assert vars == {"x", "y"}

    def test_contains_found(self):
        """Test contains when variable is present."""
        expr = ExprNode(op="*", args=["k", "x"])
        assert contains(expr, "x") is True
        assert contains(expr, "k") is True

    def test_contains_not_found(self):
        """Test contains when variable is not present."""
        expr = ExprNode(op="*", args=["k", "x"])
        assert contains(expr, "y") is False

    def test_free_parameters(self):
        """Test free_parameters extracts only parameter variables."""
        # Create a model with different variable types
        model = Model(
            name="test_model",
            variables={
                "x": ModelVariable(type="state"),
                "y": ModelVariable(type="state"),
                "k": ModelVariable(type="parameter"),
                "alpha": ModelVariable(type="parameter"),
                "z": ModelVariable(type="observed")
            }
        )

        # Test expression: k * x + alpha * y + z
        expr = ExprNode(op="+", args=[
            ExprNode(op="*", args=["k", "x"]),
            ExprNode(op="+", args=[
                ExprNode(op="*", args=["alpha", "y"]),
                "z"
            ])
        ])

        parameters = free_parameters(expr, model)
        assert parameters == {"k", "alpha"}

    def test_free_parameters_empty(self):
        """Test free_parameters with no parameters in expression."""
        model = Model(
            name="test_model",
            variables={
                "x": ModelVariable(type="state"),
                "y": ModelVariable(type="observed")
            }
        )

        expr = ExprNode(op="+", args=["x", "y"])
        parameters = free_parameters(expr, model)
        assert parameters == set()

    def test_free_parameters_undefined_variables(self):
        """Test free_parameters with variables not in model."""
        model = Model(
            name="test_model",
            variables={
                "k": ModelVariable(type="parameter")
            }
        )

        # Expression contains both defined and undefined variables
        expr = ExprNode(op="*", args=["k", "undefined_var"])
        parameters = free_parameters(expr, model)
        # Should only include the parameter that's defined in the model
        assert parameters == {"k"}

    def test_evaluate_simple(self):
        """Smoke-test the canonical evaluator wrapper used by ``simplify``."""
        assert fold_constant_expr(5, {}) == 5.0
        assert fold_constant_expr("x", {"x": 10}) == 10.0

    def test_evaluate_arithmetic(self):
        """Smoke-test fold_constant_expr arithmetic path used by simplify."""
        expr = ExprNode(op="+", args=[2, "x"])
        assert fold_constant_expr(expr, {"x": 3}) == 5.0

        expr = ExprNode(op="*", args=["x", "y"])
        assert fold_constant_expr(expr, {"x": 2, "y": 3}) == 6.0

    def test_simplify_constant_folding(self):
        """Test simplify with constant folding."""
        expr = ExprNode(op="+", args=[2, 3])
        simplified = simplify(expr)
        assert simplified == 5.0

        expr = ExprNode(op="*", args=[2, 3])
        simplified = simplify(expr)
        assert simplified == 6.0


class TestSymPyBridge:
    """Test SymPy bridge functions."""

    def test_to_sympy_numbers(self):
        """Test to_sympy with numbers.

        The unified converter (shared with the simulation bridge) emits
        ``sp.Float`` for every numeric literal, so compare against Float —
        ``sp.Float(5) == sp.Integer(5)`` is structurally False in SymPy.
        """
        assert to_sympy(5) == sp.Float(5)
        assert to_sympy(5).equals(5)
        assert to_sympy(3.14) == sp.sympify(3.14)

    def test_to_sympy_variables(self):
        """Test to_sympy with variables."""
        result = to_sympy("x")
        assert isinstance(result, sp.Symbol)
        assert str(result) == "x"

    def test_to_sympy_arithmetic(self):
        """Test to_sympy with arithmetic operations."""
        expr = ExprNode(op="+", args=[2, "x"])
        result = to_sympy(expr)
        expected = sp.Symbol("x") + 2
        assert result.equals(expected)

        expr = ExprNode(op="*", args=["x", "y"])
        result = to_sympy(expr)
        expected = sp.Symbol("x") * sp.Symbol("y")
        assert result.equals(expected)

    def test_to_sympy_functions(self):
        """Test to_sympy with mathematical functions."""
        expr = ExprNode(op="exp", args=["x"])
        result = to_sympy(expr)
        expected = sp.exp(sp.Symbol("x"))
        assert result.equals(expected)

        expr = ExprNode(op="sin", args=["x"])
        result = to_sympy(expr)
        expected = sp.sin(sp.Symbol("x"))
        assert result.equals(expected)

    def test_to_sympy_power(self):
        """Test to_sympy with power operations."""
        expr = ExprNode(op="^", args=["x", 2])
        result = to_sympy(expr)
        expected = sp.Symbol("x") ** 2
        assert result.equals(expected)

    def test_to_sympy_derivative(self):
        """Test to_sympy with derivatives."""
        expr = ExprNode(op="D", args=["x"], wrt="t")
        result = to_sympy(expr)
        assert isinstance(result, sp.Derivative)
        assert result.args[0] == sp.Symbol("x")
        # SymPy stores derivative variables as tuples (var, order)
        assert result.args[1] == (sp.Symbol("t"), 1) or result.args[1] == sp.Symbol("t")

    def test_to_sympy_ifelse(self):
        """Test to_sympy with conditional expressions."""
        condition = ExprNode(op=">", args=["x", 0])  # This won't convert perfectly, but test the structure
        expr = ExprNode(op="ifelse", args=[condition, 1, 0])

        # For this test, we'll make a simpler conditional
        x = sp.Symbol("x")
        expr_simple = ExprNode(op="ifelse", args=["x", 1, 0])
        result = to_sympy(expr_simple)
        assert isinstance(result, sp.Piecewise)

    def test_from_sympy_numbers(self):
        """Test from_sympy with numbers."""
        assert from_sympy(sp.Integer(5)) == 5.0
        assert from_sympy(sp.Float(3.14)) == 3.14

    def test_from_sympy_variables(self):
        """Test from_sympy with variables."""
        result = from_sympy(sp.Symbol("x"))
        assert result == "x"

    def test_from_sympy_arithmetic(self):
        """Test from_sympy with arithmetic operations."""
        sympy_expr = sp.Symbol("x") + 2
        result = from_sympy(sympy_expr)
        assert isinstance(result, ExprNode)
        assert result.op == "+"
        assert len(result.args) == 2

        sympy_expr = sp.Symbol("x") * sp.Symbol("y")
        result = from_sympy(sympy_expr)
        assert isinstance(result, ExprNode)
        assert result.op == "*"

    def test_from_sympy_functions(self):
        """Test from_sympy with mathematical functions."""
        sympy_expr = sp.exp(sp.Symbol("x"))
        result = from_sympy(sympy_expr)
        assert isinstance(result, ExprNode)
        assert result.op == "exp"
        assert len(result.args) == 1

    def test_from_sympy_derivative(self):
        """Test from_sympy with derivatives."""
        x, t = sp.symbols("x t")
        sympy_expr = sp.Derivative(x, t)
        result = from_sympy(sympy_expr)
        assert isinstance(result, ExprNode)
        assert result.op == "D"
        assert result.wrt is not None

    def test_round_trip_conversion(self):
        """Test that expressions can be converted to SymPy and back."""
        # Simple arithmetic
        expr = ExprNode(op="+", args=[ExprNode(op="*", args=[2, "x"]), 1])
        sympy_expr = to_sympy(expr)
        back_to_esm = from_sympy(sympy_expr)

        # Check that it's still an addition
        assert isinstance(back_to_esm, ExprNode)
        assert back_to_esm.op == "+"

    def test_to_sympy_unsupported_operation(self):
        """Test to_sympy with unsupported operations.

        The unified converter raises ``SimulationError`` (the shared
        bridge semantics), not ``TypeError``.
        """
        expr = ExprNode(op="unsupported_op", args=["x"])
        with pytest.raises(SimulationError, match="Unsupported operation"):
            to_sympy(expr)

    def test_from_sympy_unsupported_type(self):
        """Test from_sympy with unsupported SymPy types."""
        # This is hard to test without creating a custom SymPy expression type
        # For now, just verify the error handling exists
        pass


class TestSymbolicJacobian:
    """Test symbolic Jacobian computation."""

    def test_simple_linear_system(self):
        """Test Jacobian for a simple linear system."""
        # dx/dt = -ax + by
        # dy/dt = cx - dy
        model = Model(
            name="linear_system",
            variables={
                "x": ModelVariable(type="state"),
                "y": ModelVariable(type="state"),
                "a": ModelVariable(type="parameter"),
                "b": ModelVariable(type="parameter"),
                "c": ModelVariable(type="parameter"),
                "d": ModelVariable(type="parameter")
            },
            equations=[
                Equation(
                    lhs=ExprNode(op="D", args=["x"], wrt="t"),
                    rhs=ExprNode(op="+", args=[
                        ExprNode(op="*", args=[ExprNode(op="*", args=[-1, "a"]), "x"]),
                        ExprNode(op="*", args=["b", "y"])
                    ])
                ),
                Equation(
                    lhs=ExprNode(op="D", args=["y"], wrt="t"),
                    rhs=ExprNode(op="-", args=[
                        ExprNode(op="*", args=["c", "x"]),
                        ExprNode(op="*", args=["d", "y"])
                    ])
                )
            ]
        )

        jacobian = symbolic_jacobian(model)
        assert jacobian.shape == (2, 2)

        # Check that Jacobian contains the expected symbolic elements
        # J[0,0] should involve 'a', J[0,1] should involve 'b', etc.
        j_00 = jacobian[0, 0]
        j_01 = jacobian[0, 1]
        j_10 = jacobian[1, 0]
        j_11 = jacobian[1, 1]

        # Convert to string to check content
        assert 'a' in str(j_00)
        assert 'b' in str(j_01)
        assert 'c' in str(j_10)
        assert 'd' in str(j_11)

    def test_no_state_variables_error(self):
        """Test error when model has no state variables."""
        model = Model(
            name="no_states",
            variables={"p": ModelVariable(type="parameter")},
            equations=[]
        )
        with pytest.raises(ValueError, match="Model has no state variables"):
            symbolic_jacobian(model)

    def test_no_equations_error(self):
        """Test error when model has no equations."""
        model = Model(
            name="no_equations",
            variables={"x": ModelVariable(type="state")},
            equations=[]
        )
        with pytest.raises(ValueError, match="Model has no equations"):
            symbolic_jacobian(model)

    def test_single_state_variable(self):
        """Test Jacobian for single state variable."""
        # dx/dt = -kx
        model = Model(
            name="single_state",
            variables={
                "x": ModelVariable(type="state"),
                "k": ModelVariable(type="parameter")
            },
            equations=[
                Equation(
                    lhs=ExprNode(op="D", args=["x"], wrt="t"),
                    rhs=ExprNode(op="*", args=[ExprNode(op="*", args=[-1, "k"]), "x"])
                )
            ]
        )

        jacobian = symbolic_jacobian(model)
        assert jacobian.shape == (1, 1)
        assert 'k' in str(jacobian[0, 0])

    def test_algebraic_equations(self):
        """Test Jacobian with algebraic equations (non-differential)."""
        # x = 2y (algebraic)
        # dy/dt = -ky (differential)
        model = Model(
            name="mixed_system",
            variables={
                "x": ModelVariable(type="state"),
                "y": ModelVariable(type="state"),
                "k": ModelVariable(type="parameter")
            },
            equations=[
                Equation(lhs="x", rhs=ExprNode(op="*", args=[2, "y"])),
                Equation(
                    lhs=ExprNode(op="D", args=["y"], wrt="t"),
                    rhs=ExprNode(op="*", args=[ExprNode(op="*", args=[-1, "k"]), "y"])
                )
            ]
        )

        jacobian = symbolic_jacobian(model)
        assert jacobian.shape == (2, 2)


class TestErrorHandling:
    """Test error handling in expression functions."""

    def test_to_sympy_invalid_arg_count(self):
        """Test to_sympy handles invalid argument counts.

        The unified converter raises ``SimulationError`` (the shared
        bridge semantics), not ``TypeError``.
        """
        expr = ExprNode(op="exp", args=["x", "y"])  # exp takes 1 arg
        with pytest.raises(SimulationError, match="Exponential requires exactly 1 argument"):
            to_sympy(expr)

        expr = ExprNode(op="/", args=["x"])  # division takes 2 args
        with pytest.raises(SimulationError, match="Division requires exactly 2 arguments"):
            to_sympy(expr)


class TestNAryMinMax:
    """n-ary min/max scalar ops (esm-spec §4.2 — arity ≥ 2; esm-2is).

    Evaluator-side coverage of n-ary min/max lives in
    ``test_numpy_interpreter.py``; the SymPy-bridge coverage stays here
    because ``to_sympy``/``from_sympy`` are this module's surface.
    """

    def test_to_sympy_min_max(self):
        import sympy as sp
        s = to_sympy(ExprNode(op="min", args=["x", "y"]))
        assert s == sp.Min(sp.Symbol("x"), sp.Symbol("y"))
        s = to_sympy(ExprNode(op="max", args=["x", "y", "z"]))
        assert s == sp.Max(sp.Symbol("x"), sp.Symbol("y"), sp.Symbol("z"))

    def test_to_sympy_min_single_arg_collapses(self):
        # Unified converter semantics (shared with the simulation bridge):
        # a single-argument min is degenerate but tolerated — sp.Min(x)
        # collapses to x. Only an empty argument list is rejected.
        assert to_sympy(ExprNode(op="min", args=["x"])) == sp.Symbol("x")
        with pytest.raises(SimulationError, match="min requires at least 1 argument"):
            to_sympy(ExprNode(op="min", args=[]))


class TestPublicEvaluate:
    """Unit tests for the public ``earthsci_toolkit.evaluate`` entry point.

    This verifies the thin wrapper exported from ``__init__`` delegating to
    the NumPy interpreter (the single-pathway evaluator for this binding).
    Numeric results must agree with the Julia reference for the shared test
    AST cases.
    """

    def test_import_from_package(self):
        from earthsci_toolkit import evaluate
        assert callable(evaluate)

    def test_scalar_literal(self):
        from earthsci_toolkit import evaluate
        assert evaluate(42, {}) == 42.0
        assert evaluate(3.14, {}) == pytest.approx(3.14)

    def test_variable_lookup(self):
        from earthsci_toolkit import evaluate
        assert evaluate("x", {"x": 7.0}) == pytest.approx(7.0)

    def test_arithmetic_expression(self):
        from earthsci_toolkit import evaluate
        # (x + 2) * y  with x=3, y=4 → 20
        expr = ExprNode(op="*", args=[ExprNode(op="+", args=["x", 2]), "y"])
        assert evaluate(expr, {"x": 3.0, "y": 4.0}) == pytest.approx(20.0)

    def test_t_binding_respected(self):
        from earthsci_toolkit import evaluate
        # expression is just the symbol "t"
        assert evaluate("t", {"t": 5.0}) == pytest.approx(5.0)

    def test_t_defaults_to_zero(self):
        from earthsci_toolkit import evaluate
        # "t" resolves to ctx.t which defaults to 0.0 when absent from bindings
        assert evaluate("t", {}) == pytest.approx(0.0)

    def test_unbound_variable_raises(self):
        from earthsci_toolkit import evaluate
        from earthsci_toolkit.numpy_interpreter import NumpyInterpreterError
        with pytest.raises(NumpyInterpreterError):
            evaluate("z", {})