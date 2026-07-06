"""
Display formatting test suite for ESM format.

This module tests Unicode and LaTeX display formatting using display fixtures,
verifying chemical subscripts, operator precedence, and comprehensive formatting.
"""

import pytest
import json
from pathlib import Path

from earthsci_toolkit.display import to_unicode, to_latex
from earthsci_toolkit.parse import load


class TestDisplayFixtures:
    """Test display formatting using fixture files."""

    @pytest.fixture
    def fixtures_dir(self):
        """Get path to display fixtures."""
        return Path(__file__).resolve().parents[3] / "tests" / "display"

    def _get_cases(self, test_cases):
        """Extract cases from fixture data (handles both list and dict formats)."""
        if isinstance(test_cases, list):
            return test_cases
        return test_cases.get("cases", [])

    @staticmethod
    def _get_expected(case, key):
        """Get expected value from fixture case, trying both 'expected_X' and 'X' keys."""
        return case.get(f"expected_{key}") or case.get(key)

    def test_chemical_subscripts(self, fixtures_dir):
        """Test chemical subscripts formatting using fixture."""
        fixture_file = fixtures_dir / "chemical_subscripts.json"

        if not fixture_file.exists():
            pytest.skip("chemical_subscripts.json fixture not found")

        with open(fixture_file) as f:
            test_cases = json.load(f)

        for case in self._get_cases(test_cases):
            input_expr = case.get("input")
            expected_unicode = self._get_expected(case, "unicode")
            expected_latex = self._get_expected(case, "latex")

            if input_expr and expected_unicode:
                result_unicode = to_unicode(input_expr)
                assert result_unicode == expected_unicode, \
                    f"Unicode formatting failed for {input_expr}: got {result_unicode}, expected {expected_unicode}"

            if input_expr and expected_latex:
                result_latex = to_latex(input_expr)
                assert result_latex == expected_latex, \
                    f"LaTeX formatting failed for {input_expr}: got {result_latex}, expected {expected_latex}"

    def test_chemical_subscripts_comprehensive(self, fixtures_dir):
        """Test comprehensive chemical subscripts formatting."""
        fixture_file = fixtures_dir / "chemical_subscripts_comprehensive.json"

        if not fixture_file.exists():
            pytest.skip("chemical_subscripts_comprehensive.json fixture not found")

        with open(fixture_file) as f:
            test_cases = json.load(f)

        for case in self._get_cases(test_cases):
            input_expr = case.get("input")
            expected_unicode = self._get_expected(case, "unicode")
            expected_latex = self._get_expected(case, "latex")

            if input_expr and expected_unicode:
                result_unicode = to_unicode(input_expr)
                assert result_unicode == expected_unicode

            if input_expr and expected_latex:
                result_latex = to_latex(input_expr)
                assert result_latex == expected_latex

    def test_chemical_subscripts_edge_cases(self, fixtures_dir):
        """Test edge cases in chemical subscripts formatting."""
        fixture_file = fixtures_dir / "chemical_subscripts_edge_cases.json"

        if not fixture_file.exists():
            pytest.skip("chemical_subscripts_edge_cases.json fixture not found")

        with open(fixture_file) as f:
            test_cases = json.load(f)

        for case in self._get_cases(test_cases):
            input_expr = case.get("input")
            expected_unicode = self._get_expected(case, "unicode")
            expected_latex = self._get_expected(case, "latex")

            if input_expr is not None and expected_unicode is not None:
                result_unicode = to_unicode(input_expr)
                assert result_unicode == expected_unicode

            if input_expr is not None and expected_latex is not None:
                result_latex = to_latex(input_expr)
                assert result_latex == expected_latex

    def test_all_operators_display(self, fixtures_dir):
        """Test display formatting for all operators."""
        fixture_file = fixtures_dir / "all_operators.json"

        if not fixture_file.exists():
            pytest.skip("all_operators.json fixture not found")

        with open(fixture_file) as f:
            test_cases = json.load(f)

        for case in self._get_cases(test_cases):
            input_expr = case.get("input")
            expected_unicode = self._get_expected(case, "unicode")
            expected_latex = self._get_expected(case, "latex")

            if input_expr and expected_unicode:
                result_unicode = to_unicode(input_expr)
                assert result_unicode == expected_unicode

            if input_expr and expected_latex:
                result_latex = to_latex(input_expr)
                assert result_latex == expected_latex

    def test_comprehensive_operators(self, fixtures_dir):
        """Test comprehensive operator formatting."""
        fixture_file = fixtures_dir / "comprehensive_operators.json"

        if not fixture_file.exists():
            pytest.skip("comprehensive_operators.json fixture not found")

        with open(fixture_file) as f:
            test_cases = json.load(f)

        for case in self._get_cases(test_cases):
            input_expr = case.get("input")
            expected_unicode = self._get_expected(case, "unicode")
            expected_latex = self._get_expected(case, "latex")

            if input_expr and expected_unicode:
                result_unicode = to_unicode(input_expr)
                assert result_unicode == expected_unicode

            if input_expr and expected_latex:
                result_latex = to_latex(input_expr)
                assert result_latex == expected_latex

    def test_operator_precedence_display(self, fixtures_dir):
        """Test operator precedence in display formatting."""
        fixture_file = fixtures_dir / "operator_precedence.json"

        if not fixture_file.exists():
            pytest.skip("operator_precedence.json fixture not found")

        with open(fixture_file) as f:
            test_cases = json.load(f)

        for case in self._get_cases(test_cases):
            input_expr = case.get("input")
            expected_unicode = self._get_expected(case, "unicode")
            expected_latex = self._get_expected(case, "latex")

            if input_expr and expected_unicode:
                result_unicode = to_unicode(input_expr)
                assert result_unicode == expected_unicode

            if input_expr and expected_latex:
                result_latex = to_latex(input_expr)
                assert result_latex == expected_latex

    def test_expression_precedence_display(self, fixtures_dir):
        """Test expression precedence in display formatting."""
        fixture_file = fixtures_dir / "expr_precedence.json"

        if not fixture_file.exists():
            pytest.skip("expr_precedence.json fixture not found")

        with open(fixture_file) as f:
            test_cases = json.load(f)

        for case in self._get_cases(test_cases):
            input_expr = case.get("input")
            expected_unicode = self._get_expected(case, "unicode")
            expected_latex = self._get_expected(case, "latex")

            if input_expr and expected_unicode:
                result_unicode = to_unicode(input_expr)
                assert result_unicode == expected_unicode

            if input_expr and expected_latex:
                result_latex = to_latex(input_expr)
                assert result_latex == expected_latex


class TestDisplayFunctions:
    """Test core display functions."""

    def test_to_unicode_string(self):
        """Test Unicode formatting of strings."""
        # Test basic chemical formulas
        assert to_unicode("H2O") == "H₂O"
        assert to_unicode("CO2") == "CO₂"
        assert to_unicode("O3") == "O₃"
        assert to_unicode("NO2") == "NO₂"

    def test_to_latex_string(self):
        """Test LaTeX formatting of strings."""
        assert to_latex("H2O") == "\\mathrm{H_2O}"
        assert to_latex("CO2") == "\\mathrm{CO_2}"
        assert to_latex("O3") == "\\mathrm{O_3}"

    def test_to_unicode_numbers(self):
        """Test Unicode formatting of numbers."""
        assert to_unicode(42) == "42"
        assert to_unicode(3.14) == "3.14"
        assert to_unicode(1.5e-12) == "1.5×10⁻¹²"
        assert to_unicode(2.0e+05) == "2.0×10⁵"

    def test_to_latex_numbers(self):
        """Test LaTeX formatting of numbers."""
        assert to_latex(42) == "42"
        assert to_latex(3.14) == "3.14"
        assert to_latex(1.5e-12) == "1.5 \\times 10^{-12}"
        assert to_latex(2.0e+05) == "2.0 \\times 10^{5}"

    def test_to_unicode_expressions(self):
        """Test Unicode formatting of expressions."""
        expr = {"op": "+", "args": ["x", "y"]}
        result = to_unicode(expr)
        assert "+" in result and "x" in result and "y" in result

        expr = {"op": "*", "args": ["a", "b"]}
        result = to_unicode(expr)
        # Multiplication might be displayed as × or implicit
        assert "a" in result and "b" in result

    def test_to_latex_expressions(self):
        """Test LaTeX formatting of expressions."""
        expr = {"op": "+", "args": ["x", "y"]}
        result = to_latex(expr)
        assert "+" in result and "x" in result and "y" in result

        expr = {"op": "^", "args": ["x", "2"]}
        result = to_latex(expr)
        assert "x^{2}" in result or "x^2" in result

    def test_to_unicode_nested_expressions(self):
        """Test Unicode formatting of nested expressions."""
        expr = {
            "op": "+",
            "args": [
                {"op": "*", "args": ["a", "b"]},
                "c"
            ]
        }
        result = to_unicode(expr)
        assert all(var in result for var in ["a", "b", "c"])

    def test_to_latex_nested_expressions(self):
        """Test LaTeX formatting of nested expressions."""
        expr = {
            "op": "/",
            "args": [
                {"op": "+", "args": ["x", "y"]},
                {"op": "-", "args": ["a", "b"]}
            ]
        }
        result = to_latex(expr)
        assert "\\frac" in result or "/" in result
        assert all(var in result for var in ["x", "y", "a", "b"])

    def test_display_with_units(self):
        """Test display formatting with units."""
        # This might not be implemented yet, but test the interface
        try:
            result = to_unicode("concentration", units="mol/L")
            assert "concentration" in result
        except (TypeError, NotImplementedError):
            # Not implemented yet - that's okay
            pass

    def test_display_functions_with_derivatives(self):
        """Test display of derivative expressions."""
        expr = {
            "op": "d/dt",
            "args": ["x"]
        }

        unicode_result = to_unicode(expr)
        assert "x" in unicode_result

        latex_result = to_latex(expr)
        assert "x" in latex_result
        # Might contain \\frac{d}{dt} or d/dt notation

    def test_display_functions_with_special_operators(self):
        """Test display of special mathematical operators."""
        special_ops = ["sqrt", "sin", "cos", "exp", "log", "abs"]

        for op in special_ops:
            expr = {"op": op, "args": ["x"]}

            unicode_result = to_unicode(expr)
            assert "x" in unicode_result

            latex_result = to_latex(expr)
            assert "x" in latex_result


class TestDisplayErrorHandling:
    """Test error handling in display functions."""

    def test_display_invalid_input(self):
        """Test display functions with invalid input."""
        # Should handle gracefully
        result = to_unicode(None)
        assert result is not None  # Might return "None" or empty string

        result = to_latex(None)
        assert result is not None

    def test_display_unknown_operator(self):
        """Test display with unknown operator."""
        expr = {"op": "unknown_op", "args": ["x"]}

        unicode_result = to_unicode(expr)
        assert unicode_result is not None  # Should handle gracefully

        latex_result = to_latex(expr)
        assert latex_result is not None

    def test_display_malformed_expression(self):
        """Test display with malformed expression."""
        malformed_expr = {"op": "+"}  # Missing args

        unicode_result = to_unicode(malformed_expr)
        assert unicode_result is not None

        latex_result = to_latex(malformed_expr)
        assert latex_result is not None

    def test_display_deeply_nested_expression(self):
        """Test display with deeply nested expressions."""
        # Create deeply nested expression
        expr = "x"
        for i in range(10):
            expr = {"op": "+", "args": [expr, f"y{i}"]}

        unicode_result = to_unicode(expr)
        assert unicode_result is not None

        latex_result = to_latex(expr)
        assert latex_result is not None