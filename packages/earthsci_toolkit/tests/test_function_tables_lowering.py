"""Bit-equivalent table_lookup → interp.* lowering harness (esm-lhm).

For each conformance fixture under ``tests/conformance/function_tables/``,
load the file, walk the model equations, lower every ``table_lookup`` node
to the structurally-equivalent inline-``const`` ``interp.linear`` /
``interp.bilinear`` invocation prescribed by esm-spec §9.5.3, and assert
IEEE-754 ``binary64`` agreement with the equivalent hand-written
inline-``const`` lookup at the §9.2 tolerance contract (``abs: 0, rel: 0``,
non-FMA reference path).

Both arms drive the same :func:`evaluate_closed_function`; the harness
catches lowering-side mistakes (wrong output slice, swapped axis order,
dropped input expression) by computing the reference value from the raw
``function_tables`` block independently of the parsed ``table_lookup`` node.
"""
from __future__ import annotations

import struct
from typing import Any, Dict, List, Optional, Sequence, Tuple

from conftest import CONFORMANCE_DIR

from earthsci_toolkit import load
from earthsci_toolkit.esm_types import EsmFile, ExprNode, ModelVariable
from earthsci_toolkit.registered_functions import evaluate_closed_function


FIXTURES_ROOT = CONFORMANCE_DIR / "function_tables"


def _bit_eq(a: float, b: float) -> bool:
    """IEEE-754 binary64 bit-identity."""
    return struct.pack("<d", a) == struct.pack("<d", b)


def _resolve_axis_value(expr: Any, vars: Dict[str, ModelVariable]) -> float:
    """Resolve a per-axis input expression to a scalar.

    The conformance fixtures only use number literals or bare variable
    references; complex sub-expressions raise.
    """
    if isinstance(expr, (int, float)):
        return float(expr)
    if isinstance(expr, str):
        var = vars[expr]
        assert var.default is not None, f"variable {expr!r} has no default"
        return float(var.default)
    raise AssertionError(
        f"complex axis input expression not exercised by fixtures: {expr!r}"
    )


def _resolve_output_index(node: ExprNode, outputs: Optional[List[str]]) -> int:
    if node.output is None:
        return 0
    if isinstance(node.output, int):
        return int(node.output)
    assert outputs is not None, "string output requires table.outputs"
    return outputs.index(node.output)


def _slice_1d(data: Any, idx: int, has_outputs: bool) -> List[float]:
    return list(map(float, data[idx])) if has_outputs else list(map(float, data))


def _slice_2d(data: Any, idx: int, has_outputs: bool) -> List[List[float]]:
    rows = data[idx] if has_outputs else data
    return [list(map(float, r)) for r in rows]


def _lower_and_evaluate(
    node: ExprNode, file: EsmFile, vars: Dict[str, ModelVariable]
) -> float:
    """Lower a parsed table_lookup → interp.* inline-const invocation, evaluate."""
    assert node.op == "table_lookup"
    assert not node.args, "table_lookup.args MUST be empty"
    table = file.function_tables[node.table]
    axes_map = node.table_axes or {}
    kind = (table.interpolation or "linear").lower()
    out_idx = _resolve_output_index(node, table.outputs)
    has_outputs = table.outputs is not None

    if kind == "linear" and len(table.axes) == 1:
        axis = table.axes[0]
        data_slice = _slice_1d(table.data, out_idx, has_outputs)
        x = _resolve_axis_value(axes_map[axis.name], vars)
        return float(
            evaluate_closed_function(
                "interp.linear",
                [data_slice, list(map(float, axis.values)), x],
            )
        )
    if kind == "bilinear" and len(table.axes) == 2:
        ax, ay = table.axes
        data_slice = _slice_2d(table.data, out_idx, has_outputs)
        x = _resolve_axis_value(axes_map[ax.name], vars)
        y = _resolve_axis_value(axes_map[ay.name], vars)
        return float(
            evaluate_closed_function(
                "interp.bilinear",
                [
                    data_slice,
                    list(map(float, ax.values)),
                    list(map(float, ay.values)),
                    x,
                    y,
                ],
            )
        )
    raise AssertionError(f"unsupported lowering: kind={kind} axes={len(table.axes)}")


def _reference_inline_const(
    table_id: str,
    output: Optional[str],
    output_idx: Optional[int],
    axis_inputs: Sequence[Tuple[str, str]],
    file: EsmFile,
    vars: Dict[str, ModelVariable],
) -> float:
    """Independent reference: hand-driven from the raw function_tables block."""
    table = file.function_tables[table_id]
    has_outputs = table.outputs is not None
    if output is not None:
        idx = table.outputs.index(output)
    elif output_idx is not None:
        idx = output_idx
    else:
        idx = 0

    kind = (table.interpolation or "linear").lower()
    if kind == "linear":
        axis = table.axes[0]
        axis_name, var_name = axis_inputs[0]
        assert axis_name == axis.name
        data_slice = _slice_1d(table.data, idx, has_outputs)
        x = float(vars[var_name].default)
        return float(
            evaluate_closed_function(
                "interp.linear",
                [data_slice, list(map(float, axis.values)), x],
            )
        )
    if kind == "bilinear":
        ax, ay = table.axes
        (axn0, vn0), (axn1, vn1) = axis_inputs
        assert axn0 == ax.name and axn1 == ay.name
        data_slice = _slice_2d(table.data, idx, has_outputs)
        x = float(vars[vn0].default)
        y = float(vars[vn1].default)
        return float(
            evaluate_closed_function(
                "interp.bilinear",
                [
                    data_slice,
                    list(map(float, ax.values)),
                    list(map(float, ay.values)),
                    x,
                    y,
                ],
            )
        )
    raise AssertionError(f"unsupported reference kind: {kind}")


def _first_table_lookup(file: EsmFile, model_id: str, eq_idx: int) -> ExprNode:
    eq = file.models[model_id].equations[eq_idx]
    rhs = eq.rhs
    assert isinstance(rhs, ExprNode), f"eq {eq_idx} rhs must be ExprNode"
    return rhs


def test_linear_fixture_lowering_is_bit_equivalent():
    file = load(FIXTURES_ROOT / "linear" / "fixture.esm")
    vars = file.models["M"].variables
    node = _first_table_lookup(file, "M", 0)

    lowered = _lower_and_evaluate(node, file, vars)
    reference = _reference_inline_const(
        "sigma_O3_298", None, None, [("lambda_idx", "lambda")], file, vars
    )
    assert _bit_eq(lowered, reference)

    # Sanity: lambda=4.5 → i=3 (a4=4), w=0.5 → t3 + 0.5*(t4-t3)
    expected = 8.7e-18 + 0.5 * (7.9e-18 - 8.7e-18)
    assert _bit_eq(lowered, expected)


def test_bilinear_fixture_lowering_is_bit_equivalent():
    file = load(FIXTURES_ROOT / "bilinear" / "fixture.esm")
    vars = file.models["M"].variables

    # Eq 0: output by name "NO2".
    node0 = _first_table_lookup(file, "M", 0)
    lowered0 = _lower_and_evaluate(node0, file, vars)
    reference0 = _reference_inline_const(
        "F_actinic",
        "NO2",
        None,
        [("P", "P_atm"), ("cos_sza", "cos_sza")],
        file,
        vars,
    )
    assert _bit_eq(lowered0, reference0)

    # Eq 1: output by integer index 1 → "O3".
    node1 = _first_table_lookup(file, "M", 1)
    lowered1 = _lower_and_evaluate(node1, file, vars)
    reference1 = _reference_inline_const(
        "F_actinic",
        None,
        1,
        [("P", "P_atm"), ("cos_sza", "cos_sza")],
        file,
        vars,
    )
    assert _bit_eq(lowered1, reference1)

    # Sanity: P=100, cos_sza=0.5 sits on the (1,1) interior knot.
    assert lowered0 == 1.6  # data[0][1][1]
    assert lowered1 == 2.6  # data[1][1][1]


def test_roundtrip_fixture_lowering_matches_inline_const_companion():
    file = load(FIXTURES_ROOT / "roundtrip" / "fixture.esm")
    model = file.models["M"]
    vars = model.variables

    node = _first_table_lookup(file, "M", 0)
    lowered = _lower_and_evaluate(node, file, vars)

    # Eq 1 carries the equivalent inline-const interp.linear call by hand.
    inline = model.equations[1].rhs
    assert isinstance(inline, ExprNode)
    assert inline.op == "fn"
    assert inline.name == "interp.linear"
    table_arg = inline.args[0]
    axis_arg = inline.args[1]
    x_arg = inline.args[2]
    assert isinstance(table_arg, ExprNode) and table_arg.op == "const"
    assert isinstance(axis_arg, ExprNode) and axis_arg.op == "const"
    inline_val = float(
        evaluate_closed_function(
            "interp.linear",
            [
                list(map(float, table_arg.value)),
                list(map(float, axis_arg.value)),
                _resolve_axis_value(x_arg, vars),
            ],
        )
    )
    assert _bit_eq(lowered, inline_val)
