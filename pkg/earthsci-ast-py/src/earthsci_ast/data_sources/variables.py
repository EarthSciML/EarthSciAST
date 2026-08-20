"""Parameter binding resolution and unit-conversion application.

From esm 1.0.0 a data source declares no variables: the CONSUMING PARAMETER
carries a ``DataSourceBinding`` on its ``update.from`` (esm-spec §8.5), naming
the ``file_variable`` to read and an optional ``unit_conversion``. That
conversion is ONE ``Expression`` and therefore has three admissible spellings —
a plain number, a bare reference string, and an operator node — all of which
this module applies. (0.x spelled the field ``oneOf: [number, Expression]``,
which is unsatisfiable for a plain factor because ``Expression`` already admits
a number; the numeric case only became schema-valid when that collapsed to a
single ``$ref``.)

The binding's name is applied by renaming and the unit conversion by evaluating
against the raw values.
"""

from __future__ import annotations

from collections.abc import Mapping
from numbers import Real
from typing import Any

from ..errors import EarthSciAstError
from ..esm_types import DataSourceBinding, ExprNode
from ..expression import free_variables
from ..numpy_interpreter import fold_constant_expr


class UnitConversionError(EarthSciAstError, ValueError):
    """Raised when unit_conversion cannot be applied."""


def _scale_factor(conversion: Any, *, variable_name: str) -> float | None:
    """Return a constant scale if the conversion reduces to ``k * x``."""
    if conversion is None:
        return 1.0
    if isinstance(conversion, Real):
        return float(conversion)
    if isinstance(conversion, str):
        # A bare reference: an OPEN expression of exactly one free name, handled
        # by the per-element path below.
        return None
    if isinstance(conversion, ExprNode):
        free = free_variables(conversion)
        if not free:
            try:
                return float(fold_constant_expr(conversion))
            except Exception as exc:
                raise UnitConversionError(
                    f"variable {variable_name!r} unit_conversion "
                    f"is a constant expression but did not evaluate: {exc}"
                ) from exc
        return None
    raise UnitConversionError(
        f"variable {variable_name!r} unit_conversion must be a number, a "
        f"reference string or an ExprNode, got {type(conversion).__name__}"
    )


def parse_unit_conversion(raw: Any, *, variable_name: str) -> float | ExprNode | None:
    """Parse a loader variable's RAW ``unit_conversion`` (esm-spec §8.5).

    The JSON spelling is ONE ``Expression``, which admits all three forms: a
    plain multiplicative factor, a bare reference string, or a full Expression
    AST for a conversion that is not a pure scale — an affine one like °F→K,
    which §4.8.1 keeps OUT of the dimensional metadata on purpose ("a unit
    conversion that needs the offset is a ``unit_conversion`` expression, not a
    dimensional judgement").

    Returns ``None`` when the variable declares none, so a document that
    declares no conversion costs nothing and behaves exactly as before. This is
    the raw-document entry point the provider paths use; the typed parse
    (:mod:`earthsci_ast.parse`) produces the same two shapes.
    """
    if raw is None:
        return None
    if isinstance(raw, bool):
        raise UnitConversionError(
            f"variable {variable_name!r} unit_conversion must be a number or an "
            f"Expression object, got a boolean"
        )
    if isinstance(raw, Real):
        return float(raw)
    if isinstance(raw, str):
        # The third Expression spelling: a bare reference to the raw column.
        return raw
    if isinstance(raw, ExprNode):
        return raw
    if isinstance(raw, Mapping):
        from ..parse import _parse_expression

        return _parse_expression(dict(raw))
    raise UnitConversionError(
        f"variable {variable_name!r} unit_conversion must be a number, a "
        f"reference string or an Expression object, got {type(raw).__name__}"
    )


def apply_unit_conversion(values: Any, conversion: Any, *, variable_name: str) -> Any:
    """Apply ``conversion`` to ``values``.

    Accepts Python scalars, numpy arrays, xarray DataArrays, or anything
    supporting numeric multiplication. If ``conversion`` is a constant
    (number or closed expression), multiplies ``values`` by that constant.
    If it is an open expression, evaluates it once per element with the raw
    value bound to the expression's single free variable.
    """
    scale = _scale_factor(conversion, variable_name=variable_name)
    if scale is not None:
        if scale == 1.0:
            return values
        try:
            return values * scale
        except TypeError:
            try:
                import numpy as _np

                return _np.asarray(values) * scale
            except ImportError:
                return [v * scale for v in values]

    free = free_variables(conversion)
    if len(free) != 1:
        raise UnitConversionError(
            f"variable {variable_name!r} unit_conversion must depend on at "
            f"most one free variable, got {sorted(free)}"
        )
    raw_name = next(iter(free))

    def _eval_scalar(raw: float) -> float:
        return float(fold_constant_expr(conversion, {raw_name: float(raw)}))

    try:
        import numpy as _np
    except ImportError:
        if hasattr(values, "__iter__"):
            return [_eval_scalar(v) for v in values]
        return _eval_scalar(values)

    arr = _np.asarray(values)
    vectorized = _np.vectorize(_eval_scalar, otypes=[float])
    return vectorized(arr)


def apply_variable_mapping(
    raw: Mapping[str, Any],
    variables: Mapping[str, DataSourceBinding],
    *,
    strict: bool = True,
) -> dict[str, Any]:
    """Rename ``raw`` keys from ``file_variable`` to parameter name + convert
    units.

    ``variables`` is ``{consuming parameter name -> its DataSourceBinding}`` —
    the 1.0.0 inversion of the 0.x ``data_loaders[l].variables`` map.

    ``raw`` is a mapping keyed by the file-side variable names (e.g., the keys
    of an xarray Dataset's data_vars). Returns a new dict keyed by the
    schema-side names with unit conversions applied. If ``strict`` and a
    required ``file_variable`` is missing from ``raw``, raises ``KeyError``.
    """
    out: dict[str, Any] = {}
    for schema_name, spec in variables.items():
        file_name = spec.file_variable
        if file_name not in raw:
            if strict:
                raise KeyError(
                    f"variable {schema_name!r} requires file_variable "
                    f"{file_name!r} which is not present in source"
                )
            continue
        values = raw[file_name]
        out[schema_name] = apply_unit_conversion(
            values, spec.unit_conversion, variable_name=schema_name
        )
    return out
