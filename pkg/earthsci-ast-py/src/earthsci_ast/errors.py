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


class AmbiguousOutputNameError(EarthSciAstError, KeyError):
    """Raised when a name read from a result matches no variable exactly and its
    last dotted segment is shared by more than one variable (CONFORMANCE_SPEC
    §5.17.4) -- ``sol["O3"]`` when both ``Chem.O3`` and ``Sink.O3`` exist.

    A last-segment match is accepted only when it designates exactly one
    variable; choosing one of several, or returning all of them, would hand back
    a variable the caller did not name. Subclasses ``KeyError`` so ``name in
    sol`` and ``sol.get(name)`` keep their not-found behaviour.
    """

    def __init__(self, name: str, candidates: list[str]) -> None:
        from .error_handling import AMBIGUOUS_OUTPUT_NAME

        self.code = AMBIGUOUS_OUTPUT_NAME
        self.name = name
        self.candidates = list(candidates)
        super().__init__(
            f"{name!r} names no variable exactly, and its last segment is shared by "
            f"{', '.join(self.candidates)}; name one of them in full"
        )


class AmbiguousParameterError(UnknownParameterError):
    """Raised when a ``parameter_overrides`` key is a DOTTED SUFFIX of two or
    more of the flattened system's parameters (esm-spec §6.6.2 rule 4) — a
    shared local name (``gain`` for ``Left.gain`` and ``Right.gain``) or a
    shared partial qualification (``sub.g`` for ``Left.sub.g`` and
    ``Right.sub.g``).

    Distinct from :class:`UnknownParameterError`: the name exists, it just does
    not identify ONE parameter — the fix is to qualify it further with its
    owning component, not to correct the spelling. Subclasses it so a caller
    that only cares that the key did not resolve can catch the pair with one
    clause.
    """


class SimulationError(EarthSciAstError):
    """Exception raised during the SymPy bridge or simulation.

    Defined in this leaf module (it imports nothing from the package) rather
    than beside the code that raises it, because the modules that raise it sit
    on both sides of an import edge: ``expression`` and ``sympy_bridge`` raise
    it for a malformed expression or a cyclic algebraic system, and
    :mod:`earthsci_ast.compiler` — which :mod:`earthsci_ast.numpy_interpreter`
    imports, and which ``expression`` therefore imports transitively — raises
    its three ``compiler_*`` subclasses. ``expression.py`` re-exports the name,
    so ``earthsci_ast.simulation.SimulationError`` and every other established
    spelling are unchanged.
    """
