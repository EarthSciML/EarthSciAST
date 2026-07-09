"""Base exception for all earthsci_ast errors."""
from __future__ import annotations


class EarthSciAstError(Exception):
    """Root of the earthsci_ast exception hierarchy.

    Every exception raised by this package derives from this class, so callers
    can catch all package errors with a single ``except EarthSciAstError``.
    """
