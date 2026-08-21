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


class UnknownParameterError(EarthSciAstError, ValueError):
    """Raised when a ``parameter_overrides`` key names no parameter of the model
    (esm-spec §6.6.2 "Unrecognized override keys").

    Silently ignoring such a key is a *wrong answer*, not a missing one: the
    author writes an override, nothing happens, and the run quietly measures
    the configuration they thought they had switched off — the same failure
    shape that made a mis-keyed override invisible before the §6.6.2 name
    resolution existed. Rust raises ``SimulateError::InvalidParameter`` here and
    Julia an ``ArgumentError``; this is the Python surface of the same contract.

    Subclasses ``ValueError`` as well as ``EarthSciAstError`` because it is an
    invalid *argument*, so callers that ``except ValueError`` around a
    ``simulate`` call still catch it.
    """


class AmbiguousParameterError(UnknownParameterError):
    """Raised when a BARE ``parameter_overrides`` key is the local name of two
    or more of the flattened system's parameters (esm-spec §6.6.2).

    Distinct from :class:`UnknownParameterError`: the name exists, it just does
    not identify ONE parameter — the fix is to qualify it with its owning
    component, not to correct the spelling. Subclasses it so a caller that only
    cares that the key did not resolve can catch the pair with one clause.
    """
