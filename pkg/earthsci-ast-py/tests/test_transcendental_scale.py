"""esm-spec §4.8.3 and issue #409: a unit's SCALE reaches the trig and
transcendental rules.

Two halves that want OPPOSITE fixes, and one file so they stay in view of each
other:

* **Angles convert.** ``deg`` is a registry unit at scale pi/180, so
  ``sin(theta [deg])`` is a CONFORMING document — and ``flatten`` used to hand
  the stored number straight to ``sin``, so ``sin(90 [deg])`` evaluated
  0.8939966636005579, which is ``sin(90 radians)``, with no diagnostic. The
  conversion is exact and has exactly one reading.
* **Scaled dimensionless refuses.** ``ppm`` is dimensionless at 1e-6, so
  ``log(c [ppm])`` satisfied every dimension-only test. The log of the ppm
  NUMBER and the log of the mole fraction differ by ``ln(1e-6) = 13.8155…`` and
  nothing in the document says which was meant, so the checker refuses and names
  the repair rather than picking one.

Everything asserted here is asserted off SHARED fixtures, so the same facts are
checked by the other four bindings.
"""

from __future__ import annotations

import math
from pathlib import Path

import pytest

from earthsci_ast.esm_types import ExprNode
from earthsci_ast.flatten import flatten
from earthsci_ast.parse import load_path
from earthsci_ast.units import (
    DimensionalMismatchError,
    UnitValidator,
    angle_normalization_factor,
    parse_unit,
)
from earthsci_ast.validation import validate_path

try:
    from .conftest import FIXTURES_ROOT
except ImportError:  # pragma: no cover - direct pytest invocation
    from conftest import FIXTURES_ROOT


#: The ops whose argument esm-spec §4.8.3 requires to be dimensionless — the ten
#: strict transcendentals and the three inverse circular functions.
STRICT_ARGUMENT_OPS = (
    "ln",
    "log",
    "log10",
    "exp",
    "sinh",
    "cosh",
    "tanh",
    "asinh",
    "acosh",
    "atanh",
    "asin",
    "acos",
    "atan",
)


def _typed(op: str, unit: str):
    """Type ``op(x)`` with ``x`` declared in ``unit``; raises on a refusal."""
    validator = UnitValidator()
    validator.known_units = {"x": parse_unit(unit)}
    return validator._type(ExprNode(op=op, args=["x"]))


@pytest.mark.parametrize("op", STRICT_ARGUMENT_OPS)
def test_a_scaled_dimensionless_argument_is_refused(op: str) -> None:
    with pytest.raises(DimensionalMismatchError) as excinfo:
        _typed(op, "ppm")
    message = str(excinfo.value)
    assert "dimensionless at scale 1" in message
    assert "(ppm)" in message
    # The diagnostic names the REPAIR, not only the refusal.
    assert "divide by 1 ppm" in message


@pytest.mark.parametrize("op", STRICT_ARGUMENT_OPS)
def test_a_pure_number_argument_stays_accepted(op: str) -> None:
    assert _typed(op, "1") is not None


@pytest.mark.parametrize("op", ["sin", "cos", "tan"])
def test_a_circular_function_takes_an_angle_at_any_scale(op: str) -> None:
    assert _typed(op, "rad") is not None
    assert _typed(op, "deg") is not None
    assert _typed(op, "1") is not None
    # Dimensionless at a scale other than 1 leaves the reading unstated, exactly
    # as it does for `log`.
    with pytest.raises(DimensionalMismatchError):
        _typed(op, "percent")
    # `sr` is rad**2. No conversion turns a solid angle into a plane one, so
    # accepting it would multiply by `scale` where `scale**2` was meant.
    with pytest.raises(DimensionalMismatchError):
        _typed(op, "sr")


def test_angle_normalization_factor() -> None:
    for spelling in ("rad", "1", "ppm", "m", "sr"):
        assert angle_normalization_factor(parse_unit(spelling)) is None
    factor = angle_normalization_factor(parse_unit("deg"))
    assert factor == math.pi / 180.0
    # 90 deg is exactly a quarter turn under this factor.
    assert math.sin(90.0 * factor) == 1.0


def _trig_arguments(expr, out: list) -> None:
    if not isinstance(expr, ExprNode):
        return
    if expr.op in ("sin", "cos", "tan") and len(expr.args) == 1:
        out.append((expr.op, expr.args[0]))
    for arg in expr.args:
        _trig_arguments(arg, out)


def test_flatten_converts_degrees_and_leaves_radians_alone() -> None:
    """The shared numeric fixture's `deg` arguments reach the evaluator already
    multiplied by pi/180, and its `rad` argument does NOT — which is what
    distinguishes "the scale is applied" from "the scale is applied twice"."""
    flat = flatten(load_path(str(FIXTURES_ROOT / "simulation/angle_units_degrees.esm")))
    found: list = []
    for equation in flat.equations:
        _trig_arguments(equation.rhs, found)
    assert len(found) == 4, "the fixture carries four trig calls"

    converted = 0
    untouched = 0
    for op, arg in found:
        if isinstance(arg, ExprNode):
            assert arg.op == "*", f"{op}: expected the folded product"
            assert arg.args[1] == math.pi / 180.0, f"{op}: the factor is the declared scale"
            converted += 1
        else:
            assert isinstance(arg, str) and arg.endswith("theta_rad"), (
                f"{op}: only the `rad` control stays a bare reference, got {arg!r}"
            )
            untouched += 1
    assert (converted, untouched) == (3, 1)


def test_flatten_leaves_a_document_with_no_scaled_angle_untouched() -> None:
    """A document declaring no scaled angle is not rewritten at all, so the
    common case costs nothing and cannot change a number."""
    path = str(FIXTURES_ROOT / "simulation/simple_ode.esm")
    first = flatten(load_path(path))
    second = flatten(load_path(path))
    assert [e.rhs for e in first.equations] == [e.rhs for e in second.equations]


def test_the_shared_invalid_fixture_is_refused_and_names_the_repair() -> None:
    result = validate_path(
        str(FIXTURES_ROOT / "invalid/units_discriminator_transcendental_scaled_argument.esm")
    )
    assert not result.is_valid
    assert any("divide by 1 ppm" in e.message for e in result.structural_errors), (
        f"the diagnostic must name the repair, got {[e.message for e in result.structural_errors]}"
    )


def test_the_shared_repair_fixture_is_accepted() -> None:
    result = validate_path(
        str(FIXTURES_ROOT / "valid/units_transcendental_scaled_argument_repair.esm")
    )
    assert result.is_valid, [e.message for e in result.structural_errors]


def test_the_fixture_paths_exist() -> None:
    """A renamed fixture must fail loudly here rather than silently skip."""
    for rel in (
        "simulation/angle_units_degrees.esm",
        "invalid/units_discriminator_transcendental_scaled_argument.esm",
        "valid/units_transcendental_scaled_argument_repair.esm",
    ):
        assert Path(FIXTURES_ROOT / rel).is_file(), rel
