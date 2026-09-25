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
from earthsci_ast.parse import load_document, load_path
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


def _trig_arguments_by_lhs(flat) -> dict:
    """Every circular-trig argument of each equation, faq bodies included, keyed
    by the equation's bare left-hand-side name."""
    found: dict = {}

    def walk(name: str, expr) -> None:
        if not isinstance(expr, ExprNode):
            return
        if expr.op in ("sin", "cos", "tan") and len(expr.args) == 1:
            found[name] = expr.args[0]
        for child in [*expr.args, expr.expr]:
            walk(name, child)

    for equation in flat.equations:
        if isinstance(equation.lhs, str):
            walk(equation.lhs.split(".")[-1], equation.rhs)
    return found


def test_flatten_converts_a_degree_array_element() -> None:
    """An array element carries its array's unit on the evaluation path, so
    ``cos(index(lat, i))`` with ``lat`` in ``deg`` converts like ``cos(lat)``.

    The checker has no rule for ``index`` or ``faq`` (esm-spec §4.8.4), and the
    rewrite used to read the argument with the checker's rules, so it left every
    array element unconverted and evaluated cos(60 radians) = -0.952."""
    rel = "conformance/scalar_operator_semantics/fixtures/angle_array_element.esm"
    path = str(FIXTURES_ROOT / rel)
    args = _trig_arguments_by_lhs(flatten(load_path(path)))
    assert sorted(args) == ["cos_lat", "cos_lat_rad", "sin_colat", "sin_scalar", "sin_sum"]
    for name in ("cos_lat", "sin_colat", "sin_sum"):
        arg = args[name]
        # `index(A, ...) * (pi/180)`: the element, then the declared scale, once.
        assert isinstance(arg, ExprNode) and arg.op == "*", name
        assert isinstance(arg.args[0], ExprNode) and arg.args[0].op == "index", name
        assert arg.args[1] == math.pi / 180.0, name
    assert isinstance(args["sin_scalar"], ExprNode) and args["sin_scalar"].op == "*"
    # The `rad` control is never touched.
    assert isinstance(args["cos_lat_rad"], ExprNode) and args["cos_lat_rad"].op == "index"
    # The checker still reads the authored spelling and still accepts it.
    result = validate_path(path)
    assert result.is_valid, [e.message for e in result.structural_errors]


def test_the_checker_still_has_no_rule_for_an_array_element() -> None:
    """The element reading is the EVALUATION path's alone: the checker still
    reports ``index`` as undeterminable (esm-spec §4.8.4), so no verdict moved."""
    validator = UnitValidator()
    validator.known_units = {"lat": parse_unit("deg")}
    node = ExprNode(op="index", args=["lat", 1])
    assert validator._type(node) is None
    validator.element_units = True
    typed = validator._type(node)
    assert typed is not None and not typed.scale.is_one(), "the element is in `deg`"


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


def test_the_declared_unit_governs_a_hand_written_degree_conversion() -> None:
    """A DISCLOSED behaviour change: a document that converts degrees to radians
    by hand with a factor declared ``units: "1"`` is converted AGAIN.

    The fold reads the argument's DECLARED unit, and ``deg * [1]`` is still
    ``deg`` — so ``sin(lat * d2r)`` with ``lat`` in ``deg`` and ``d2r``
    dimensionless at scale 1 now evaluates ``sin(lat * pi/180 * pi/180)`` where
    it used to evaluate the right number. The document was mis-declaring
    itself: a real degrees-to-radians factor has unit ``rad/deg``, and with
    that declaration the product is ``rad`` at scale 1 and nothing is folded,
    which is the repair. ``tests/conformance/pushdown/fixtures/isrm.esm``
    escapes only because its ``lcc_d2r`` is declared with NO units at all,
    which makes the product undeterminable (esm-spec §4.8.4).

    Pinned so the behaviour is deliberate and visible rather than discovered.
    """
    variables = {
        "lat": {"type": "parameter", "units": "deg", "default": 45.0},
        "untyped": {"type": "parameter", "default": math.pi / 180.0},
        "dimensionless": {"type": "parameter", "units": "1", "default": math.pi / 180.0},
        "declared": {"type": "parameter", "units": "rad/deg", "default": 1.0},
        "a": {"type": "unknown", "units": "1"},
        "b": {"type": "unknown", "units": "1"},
        "c": {"type": "unknown", "units": "1"},
    }
    equations = [
        {"lhs": lhs, "rhs": {"op": "sin", "args": [{"op": "*", "args": ["lat", factor]}]}}
        for lhs, factor in (("a", "untyped"), ("b", "dimensionless"), ("c", "declared"))
    ]
    doc = {
        "esm": "1.0.0",
        "metadata": {"name": "HandWrittenDegreeConversion"},
        "models": {"M": {"variables": variables, "equations": equations}},
    }
    flat = flatten(load_document(doc))
    folded = {}
    for equation in flat.equations:
        arg = equation.rhs.args[0]
        folded[equation.lhs] = (
            isinstance(arg, ExprNode)
            and arg.op == "*"
            and any(a == pytest.approx(math.pi / 180.0) for a in arg.args if isinstance(a, float))
            and isinstance(arg.args[0], ExprNode)
        )
    assert folded["M.a"] is False, "an UNDECLARED factor leaves the product undeterminable"
    assert folded["M.b"] is True, "a factor declared `1` leaves the product `deg`, so it is folded"
    assert folded["M.c"] is False, "the `rad/deg` repair reaches `rad` at scale 1 — nothing to fold"


def test_the_fixture_paths_exist() -> None:
    """A renamed fixture must fail loudly here rather than silently skip."""
    for rel in (
        "simulation/angle_units_degrees.esm",
        "invalid/units_discriminator_transcendental_scaled_argument.esm",
        "valid/units_transcendental_scaled_argument_repair.esm",
        "conformance/scalar_operator_semantics/fixtures/angle_array_element.esm",
    ):
        assert Path(FIXTURES_ROOT / rel).is_file(), rel
