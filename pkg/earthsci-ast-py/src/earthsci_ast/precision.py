"""Declared working precision of ESM variables (esm-spec §11.3.3)."""

from __future__ import annotations

from typing import Literal

from .esm_types import EsmFile, ModelVariable
from .solver import _declared_minor


def _omitted_precision(version: str) -> Literal["Float64", "unspecified"]:
    parts = _declared_minor({"esm": version})
    return "Float64" if parts is None or parts < (1, 3) else "unspecified"


def precision_source(document: EsmFile, variable: ModelVariable | None = None) -> str:
    """Return the declared element type, or `unspecified` for eligible omission.

    Pass no variable to query the document default (also used by species and
    reaction-system parameters).
    """
    if variable is not None and variable.element_type is not None:
        return variable.element_type
    if document.domain is not None and document.domain.element_type is not None:
        return document.domain.element_type
    return _omitted_precision(document.esm)
