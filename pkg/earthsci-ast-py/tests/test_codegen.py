"""Tests for :mod:`earthsci_ast.codegen`.

Regression coverage for the schema-mismatch bugs where codegen treated the
``reactions`` array as a dict (``.values()`` / ``.items()``), read a ``unit``
field that the schema spells ``units``, and read an ``initial_value`` field that
Species spells ``default``.
"""
from __future__ import annotations

from earthsci_ast.codegen import to_julia_code, to_python_code

# A small schema-valid ESM file dict: one model (state var + parameter, both
# with `units` and `default`) and one reaction system whose `reactions` is an
# ARRAY of reaction objects and whose species carry `units` and `default`.
MODEL_DICT = {
    "esm": "0.3.0",
    "metadata": {"title": "codegen smoke test"},
    "models": {
        "M": {
            "variables": {
                "T": {"type": "state", "units": "kelvin", "default": 300.0},
                "k": {"type": "parameter", "units": "1/s", "default": 0.5},
            },
            "equations": [
                {
                    "lhs": {"op": "D", "args": ["T"], "wrt": "t"},
                    "rhs": {"op": "*", "args": ["k", "T"]},
                }
            ],
        }
    },
    "reaction_systems": {
        "RS": {
            "species": {
                "A": {"units": "mol/L", "default": 1.5},
                "B": {"units": "mol/L", "default": 0.0},
            },
            "reactions": [
                {
                    "id": "R1",
                    "substrates": [{"species": "A", "stoichiometry": 1}],
                    "products": [{"species": "B", "stoichiometry": 1}],
                    "rate": "k1",
                }
            ],
        }
    },
}


def test_to_julia_code_reactions_array_units_and_default():
    """`to_julia_code` runs on an array-valued `reactions` block and surfaces
    the variable `units` and both the variable and species `default` values."""
    code = to_julia_code(MODEL_DICT)

    # (a) reactions-as-array no longer crashes; the reaction is emitted.
    assert "Reaction(" in code
    assert "@parameters k1" in code
    # (b) variable `units` field is read (was `unit`).
    assert 'u"kelvin"' in code
    # (c) species `default` field is read (was `initial_value`).
    assert "300.0" in code  # model variable default
    assert "1.5" in code  # species A default


def test_to_python_code_reactions_array_and_units():
    """`to_python_code` runs on the same file and emits the variable `units`
    comment and a per-reaction rate binding keyed by the reaction id."""
    code = to_python_code(MODEL_DICT)

    # reactions-as-array no longer crashes; rate binding uses the reaction id.
    assert "R1_rate = k1" in code
    assert "# Reaction: R1" in code
    # variable `units` field is read (was `unit`) and emitted as a comment.
    assert "# kelvin" in code
    assert "# 1/s" in code


def test_codegen_does_not_raise_on_valid_model():
    """Both generators return non-empty strings without raising."""
    assert to_julia_code(MODEL_DICT).strip()
    assert to_python_code(MODEL_DICT).strip()
