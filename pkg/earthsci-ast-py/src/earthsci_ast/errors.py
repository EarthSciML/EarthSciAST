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


class MissingDataError(SimulationError):
    """``E_TREEWALK_MISSING_DATA``: a SHAPED parameter reached construction with
    no value — no ``default``, no override, no caller array, and, for one the
    document feeds from a data source or a registered handler, no data from it
    either. esm-spec §10.10 makes "a parameter with neither a default nor a
    supplied value" an error when a problem is built.

    The message names the parameter, what the document says feeds it, and how a
    caller supplies it; ``reason`` adds why a data source's read failed, when one
    did. Julia and Rust raise the same code.
    """

    code = "E_TREEWALK_MISSING_DATA"

    def __init__(self, name: str, var: object, reason: str | None = None) -> None:
        self.name = name
        shape = getattr(var, "shape", None)
        shape_s = f" (shape [{', '.join(shape)}])" if shape else ""
        update = getattr(var, "update", None)
        rules = update if isinstance(update, list) else ([update] if update is not None else [])
        feeds = []
        for rule in rules:
            src = getattr(rule, "from_source", None)
            handler = getattr(rule, "handler", None)
            if src is not None:
                feeds.append(
                    f"the data source '{getattr(rule, 'source', None) or '?'}' "
                    f"(file_variable '{src.file_variable}')"
                )
            elif handler is not None:
                feeds.append(
                    f"the registered handler '{handler.handler_id}' (update kind "
                    f"'{rule.kind}'), which writes it only when it fires"
                )
        if not feeds:
            fed = "Nothing in the document gives it a value."
            how = (
                f"pass its array in `const_arrays={{'{name}': array}}`, or declare a `default` on it"
                if shape
                else f"pass it in `p={{'{name}': value}}`, or declare a `default` on it"
            )
        else:
            if reason is None:
                fed = (
                    f"The document feeds it from {' and '.join(feeds)}, and no data for it "
                    "was supplied at construction."
                )
            else:
                fed = (
                    f"The document feeds it from {' and '.join(feeds)}, which could not be "
                    f"read at construction: {reason}."
                )
            how = (
                "pass a provider for it in `providers` (or a `provider_factory`), or its "
                f"array in `const_arrays={{'{name}': array}}` (a constant snapshot), or "
                "declare a `default` on it"
            )
        kind = "shaped " if shape else ""
        if getattr(var, "default", None) is None:
            head = f"no data supplied for the {kind}parameter '{name}'{shape_s}, which declares no `default`."
            rule = (
                " A parameter with neither a default nor a supplied value is an error when a "
                "problem is built (esm-spec §10.10)."
            )
        else:
            # Only a failed read reaches here for a parameter with a default: the
            # data the caller asked construction to fetch is not there, and a
            # failed build raises (esm-libraries-spec §2.5.2) rather than
            # running on the placeholder.
            head = f"no data could be read for the {kind}parameter '{name}'{shape_s}."
            rule = ""
        super().__init__(f"{self.code}: {head} {fed}{rule} To supply it, {how}.")


class MissingInitialValueError(SimulationError):
    """``E_TREEWALK_MISSING_INITIAL_VALUE``: an unknown that needs a starting
    value reached construction with none — no ``default``, no initial condition
    or ``ic`` equation, and no caller ``u0`` (esm-spec §11.4). Julia and Rust
    raise the same code.
    """

    code = "E_TREEWALK_MISSING_INITIAL_VALUE"

    def __init__(self, names: list[str]) -> None:
        self.names = list(names)
        shown = ", ".join(f"'{n}'" for n in self.names[:5]) + (", …" if len(self.names) > 5 else "")
        first = self.names[0]
        super().__init__(
            f"{self.code}: no starting value for {len(self.names)} unknown(s) ({shown}): "
            "the unknown declares no `default`, and no initial condition, `ic` equation or "
            "caller `u0` sets it. An unknown with no starting value is an error when a problem "
            f"is built (esm-spec §11.4). To supply it, pass `u0={{'{first}': value}}` to "
            "`esm_problem`, or declare a `default` on the unknown."
        )
