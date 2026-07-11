"""Base exception for all earthsci_ast errors."""
from __future__ import annotations


class EarthSciAstError(Exception):
    """Root of the earthsci_ast exception hierarchy.

    Every exception raised by this package derives from this class, so callers
    can catch all package errors with a single ``except EarthSciAstError``.
    """


class ParseError(EarthSciAstError, ValueError):
    """Raised when JSON data cannot be parsed into ESM objects.

    Surfaced by the public ``load()`` / ``_parse_expression`` path when the
    input is structurally invalid (e.g. an operator missing a required field).
    Subclasses ``ValueError`` as well as ``EarthSciAstError`` so existing
    callers that ``except ValueError`` continue to catch it.
    """
