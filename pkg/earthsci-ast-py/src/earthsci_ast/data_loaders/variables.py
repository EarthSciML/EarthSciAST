"""Variable name remapping and unit-conversion application.

Each ``DataLoaderVariable`` has a ``file_variable`` (the name in the source
file) and an optional ``unit_conversion`` which is either a numeric scalar or
an Expression tree (``earthsci_ast.esm_types.ExprNode``). The schema-facing
name is applied by renaming and the unit conversion is applied by evaluating
against the raw values.
"""

from __future__ import annotations

from collections.abc import Mapping
from numbers import Real
from typing import Any

from ..errors import EarthSciAstError
from ..esm_types import DataLoaderVariable, ExprNode
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
        f"variable {variable_name!r} unit_conversion must be a number or "
        f"ExprNode, got {type(conversion).__name__}"
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
    variables: Mapping[str, DataLoaderVariable],
    *,
    strict: bool = True,
) -> dict[str, Any]:
    """Rename ``raw`` keys from ``file_variable`` to schema name + convert units.

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
