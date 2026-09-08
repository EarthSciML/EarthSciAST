"""Shared building blocks for the simulation pathways.

Holds the pieces every simulation pathway needs — the
:class:`Solution` container and its :class:`ReturnCode`, the optional SciPy
import guard, and the dense-output point budget — so the pathway submodules
(:mod:`.simulation_array`, :mod:`.simulation_loaders`,
:mod:`.simulation_scalar`) can share them without importing each other.
``earthsci_ast.simulation`` re-exports this module's API.
"""

from __future__ import annotations

import warnings
from collections.abc import Collection, Iterable, Sequence
from dataclasses import dataclass
from enum import Enum
from typing import Any

import numpy as np

from .errors import AmbiguousParameterError, UnknownParameterError
from .numpy_interpreter import _require_real
from .sympy_bridge import SimulationError

# Optional scipy import - only needed for actual simulation.
#
# esm-libraries-spec §2.4 / §2.5.9: a library MUST NOT embed a solver as a
# runtime dependency, so SciPy is an OPTIONAL extra here (`simulate`), the
# counterpart of Rust's non-default `solve` feature and Julia's
# `EarthSciASTSimulateExt`. Problem CONSTRUCTION never touches it; only the
# actual integration does.
try:
    from scipy.integrate import solve_ivp

    SCIPY_AVAILABLE = True
except (ImportError, ValueError):
    # ValueError can occur due to numpy/scipy compatibility issues
    SCIPY_AVAILABLE = False
    solve_ivp = None

#: The message a solver entry point reports when SciPy is missing. Names the
#: extra that supplies it, so a caller is not left to guess which of the several
#: optional extras carries the solver (phase-6 H-4).
SCIPY_MISSING_HINT = (
    "SciPy is an OPTIONAL dependency of earthsci-ast (a library must not embed "
    "a solver as a runtime dependency; esm-libraries-spec §2.4). Install it "
    'with `pip install "earthsci-ast[simulate]"`.'
)


def _scipy_missing_message(action: str) -> str:
    """Compose the missing-solver message for ``action`` (e.g. ``"solve"``)."""
    return f"SciPy is required to {action} an EsmProblem but is not installed. {SCIPY_MISSING_HINT}"


# Dense-output point budget: the minimum number of uniform sampling nodes a
# ``solve_ivp`` dense solution is resampled onto
# (:func:`simulation_array._densify_solution`). The loader-segmented path
# spreads the same budget across its cadence segments so a multi-segment run
# does not multiply the per-segment grid.
DENSE_OUTPUT_MIN_POINTS = 10001


class ReturnCode(str, Enum):
    """The SciML ``ReturnCode`` vocabulary (API_SPEC §4, esm-libraries-spec
    §2.5.3), which is how a run reports its outcome in every simulating
    binding.

    It REPLACES the ``success`` boolean / free-text ``message`` pair the Python
    binding used to carry: a caller distinguishes "ran to ``tspan[2]``" from
    "stopped early, here is why" by comparing ``retcode``, never by reading
    prose.

    * ``Success`` — the integration reached the end of ``tspan``.
    * ``MaxIters`` — the ``maxiters`` budget on right-hand-side evaluations ran
      out first.
    * ``Unstable`` — the trajectory left the domain the model can evaluate
      (a non-finite derivative or state).
    * ``Terminated`` — a continuous event stopped the run early.
    * ``Failure`` — the solver, the build, or the model reported an error.

    Subclassing :class:`str` keeps a code printable and JSON-serializable
    (``str(ReturnCode.Success) == "ReturnCode.Success"``, ``.value ==
    "Success"``) without making it a bare string at comparison sites.
    """

    Success = "Success"
    MaxIters = "MaxIters"
    Unstable = "Unstable"
    Terminated = "Terminated"
    Failure = "Failure"


@dataclass
class Solution:
    """What :func:`earthsci_ast.problem.solve` returns.

    Indexed **by variable name** (esm-libraries-spec §2.5.7): ``sol["Chem.O3"]``
    is that variable's trajectory over :attr:`t`. The flattened state ordering
    is an implementation detail coupling can change, so the positional
    :attr:`y` / :attr:`vars` pair remains available but is not the documented
    path.

    :attr:`retcode` is the run's outcome. :attr:`message`, :attr:`nfev`,
    :attr:`njev` and :attr:`nlu` are informative extras (§2.5.3 permits solver
    statistics beside the code); ``message`` carries the solver's or the
    failure's own prose and is a diagnostic, never the channel a caller decides
    success on.
    """

    t: np.ndarray
    y: np.ndarray
    vars: list[str]  # Variable names corresponding to y rows
    retcode: ReturnCode
    message: str = ""
    nfev: int = 0
    njev: int = 0
    nlu: int = 0
    events: list[np.ndarray] | None = None

    # ---- name-keyed access (esm-libraries-spec §2.5.7) --------------------
    def __getitem__(self, key: str | int) -> np.ndarray:
        """``sol[name]`` — the named variable's trajectory; ``sol[i]`` — row i.

        A name resolves exactly first, then by its trailing segment against the
        flattened names (``"O3"`` finds ``"Chem.O3"``), and finally against an
        array state's element spellings (``"u"`` finds the rows ``u[1]``,
        ``u[2]``, ... stacked in element order).
        """
        if isinstance(key, (int, np.integer)):
            return np.asarray(self.y[int(key)])
        name = str(key)
        idx = self._row_index(name)
        if idx is not None:
            return np.asarray(self.y[idx])
        rows = self._element_rows(name)
        if rows:
            return np.asarray(self.y[rows])
        raise KeyError(
            f"{name!r} is not a variable of this solution (have: {', '.join(self.vars)})"
        )

    def _row_index(self, name: str) -> int | None:
        if name in self.vars:
            return self.vars.index(name)
        tails = [i for i, v in enumerate(self.vars) if v.rsplit(".", 1)[-1] == name]
        if len(tails) == 1:
            return tails[0]
        return None

    def _element_rows(self, name: str) -> list[int]:
        """Row indices of the element spellings of an array state ``name``."""
        out: list[int] = []
        for i, v in enumerate(self.vars):
            base = v.split("[", 1)[0]
            if base == name or base.rsplit(".", 1)[-1] == name:
                out.append(i)
        return out

    def __contains__(self, name: object) -> bool:
        try:
            self[str(name)]
        except KeyError:
            return False
        return True

    def keys(self) -> list[str]:
        """The variable names this solution is indexed by."""
        return list(self.vars)

    def get(self, name: str, default: Any = None) -> Any:
        try:
            return self[name]
        except KeyError:
            return default

    def plot(self, variables: list[str] | None = None, **kwargs):
        """
        Plot simulation results using matplotlib.

        Args:
            variables: Optional list of variable names to plot. If None, plots all.
            **kwargs: A fixed set of recognized formatting options (NOT forwarded
                verbatim to matplotlib). Recognized keys:

                - ``figsize`` (default ``(10, 6)``) — passed to ``plt.subplots``.
                - ``linewidth`` (default ``2``) — per-series line width.
                - ``xlabel`` (default ``"Time"``), ``ylabel`` (default
                  ``"Concentration"``), ``title`` (default ``"Simulation Results"``).
                - ``xlim`` / ``ylim`` — axis limits, applied only if present.
                - ``save_path`` — if set, save the figure there (with ``dpi``,
                  default ``150``).
                - ``show`` (default ``True``) — call ``plt.show()`` when truthy.

                Any other key is ignored. Returns ``(fig, ax)``.
        """
        try:
            import matplotlib.pyplot as plt
        except ImportError as exc:
            raise ImportError(
                "matplotlib is required for plotting. Install with: pip install matplotlib"
            ) from exc

        if self.retcode is not ReturnCode.Success:
            raise RuntimeError(
                f"Cannot plot a run that returned {self.retcode.value}: {self.message}"
            )

        # Determine which variables to plot
        if variables is None:
            plot_vars = self.vars
            plot_indices = list(range(len(self.vars)))
        else:
            plot_vars = []
            plot_indices = []
            for var in variables:
                if var in self.vars:
                    plot_vars.append(var)
                    plot_indices.append(self.vars.index(var))
                else:
                    warnings.warn(
                        f"Variable '{var}' not found in simulation results",
                        UserWarning,
                        stacklevel=2,
                    )

        if not plot_vars:
            raise ValueError("No valid variables to plot")

        # Create the plot
        fig, ax = plt.subplots(figsize=kwargs.get("figsize", (10, 6)))

        for var, idx in zip(plot_vars, plot_indices):
            ax.plot(self.t, self.y[idx, :], label=var, linewidth=kwargs.get("linewidth", 2))

        ax.set_xlabel(kwargs.get("xlabel", "Time"))
        ax.set_ylabel(kwargs.get("ylabel", "Concentration"))
        ax.set_title(kwargs.get("title", "Simulation Results"))
        ax.legend()
        ax.grid(True, alpha=0.3)

        # Apply any additional formatting
        if "xlim" in kwargs:
            ax.set_xlim(kwargs["xlim"])
        if "ylim" in kwargs:
            ax.set_ylim(kwargs["ylim"])

        plt.tight_layout()

        if kwargs.get("save_path"):
            plt.savefig(kwargs["save_path"], dpi=kwargs.get("dpi", 150), bbox_inches="tight")

        if kwargs.get("show", True):
            plt.show()

        return fig, ax


def _failure_result(
    message: str,
    nfev: int = 0,
    njev: int = 0,
    nlu: int = 0,
    retcode: ReturnCode = ReturnCode.Failure,
) -> Solution:
    """Build the uniform non-Success :class:`Solution` (empty trajectory).

    Every simulation pathway reports a failed run with the same shape: empty
    ``t`` and ``y`` (``[[]]``), no variables, the given ``retcode`` (default
    :attr:`ReturnCode.Failure`) and the diagnostic ``message``. ``nfev`` /
    ``njev`` / ``nlu`` default to 0 (nothing ran); the cadence-segmented loader
    path passes its accumulated solver counts so a failure mid-run still
    reports the work already done.
    """
    return Solution(
        t=np.array([]),
        y=np.array([[]]),
        vars=[],
        retcode=retcode,
        message=message,
        nfev=nfev,
        njev=njev,
        nlu=nlu,
    )


class MaxItersExceeded(Exception):
    """Raised inside a wrapped right-hand side when the ``maxiters`` budget of
    right-hand-side evaluations is spent. Caught by the pathway, which reports
    :attr:`ReturnCode.MaxIters`. Private to the simulation pathways."""


def _limit_iters(fn: Any, maxiters: int | None) -> Any:
    """Wrap ``fn(t, y)`` so that the ``maxiters + 1``-th call raises
    :class:`MaxItersExceeded`. ``None`` (the default) returns ``fn`` unchanged,
    so an unbudgeted run keeps today's call path exactly."""
    if maxiters is None:
        return fn
    budget = int(maxiters)
    seen = [0]

    def limited(t: float, y: Any) -> Any:
        seen[0] += 1
        if seen[0] > budget:
            raise MaxItersExceeded(
                f"maxiters={budget} right-hand-side evaluations exhausted before "
                f"the end of tspan (reached t={t})"
            )
        return fn(t, y)

    return limited


def _retcode_from_scipy(sol: Any) -> tuple[ReturnCode, str]:
    """Map a ``scipy.integrate.solve_ivp`` result onto the SciML vocabulary.

    SciPy's ``status`` is the authoritative field: ``0`` reached the end of the
    interval, ``1`` stopped on a termination event, ``-1`` is a solver-reported
    failure.
    """
    status = int(getattr(sol, "status", 0 if getattr(sol, "success", False) else -1))
    message = str(getattr(sol, "message", ""))
    if status == 0:
        return ReturnCode.Success, message
    if status == 1:
        return ReturnCode.Terminated, message
    return ReturnCode.Failure, message


def _retcode_for_error(exc: BaseException) -> ReturnCode:
    """Classify a pathway exception into the SciML vocabulary.

    A non-finite derivative or state is the model leaving the domain it can be
    evaluated on, which is exactly what :attr:`ReturnCode.Unstable` names; a
    spent ``maxiters`` budget is :attr:`ReturnCode.MaxIters`; anything else is
    a :attr:`ReturnCode.Failure`.
    """
    if isinstance(exc, MaxItersExceeded):
        return ReturnCode.MaxIters
    text = str(exc).lower()
    if "non-finite" in text or "not finite" in text or "overflow" in text:
        return ReturnCode.Unstable
    return ReturnCode.Failure


def _observed_rows(vals, n: int, names: Sequence[str] | None = None) -> np.ndarray:
    """Materialize observed-body outputs into a ``(len(vals), n)`` float matrix.

    Each observed value is broadcast onto the ``n``-point time grid: a scalar
    (``ndim == 0``) or a size-1 array fills the whole row with its single value;
    a full-length array (``size == n``) is copied verbatim; any other size falls
    back to its first element broadcast across the row.

    Every value passes :func:`numpy_interpreter._require_real` FIRST, mirroring
    what the array observed path already does at
    ``simulation_array._collect_observed``. Both `ifelse` lowerings in this
    binding are EAGER — the interpreter evaluates both arms, and the codegen
    path lowers to ``sympy.Piecewise`` and thence to ``numpy.select``, which
    also evaluates every arm — so an UNTAKEN arm containing ``^`` with a
    negative base and a fractional exponent promotes the whole result to a
    complex dtype with an all-zero imaginary part. That is a real answer
    wearing a complex dtype, and ``_require_real`` projects it back onto the
    reals; only a genuinely nonzero imaginary part raises.

    Without this, the two casts below did the two WORST things available: bare
    ``float()`` on a scalar raised an unnamed ``TypeError`` ("can't convert
    complex to float"), and ``np.asarray(..., dtype=float)`` on an array
    silently DISCARDED the imaginary part behind a ``ComplexWarning`` nothing
    escalates — a plausible wrong number. A model whose taken branch is
    perfectly real could not be simulated at all on the first path, and could
    be quietly wrong on the second.
    """
    block = np.empty((len(vals), n), dtype=float)
    for i, val in enumerate(vals):
        where = (
            f"observed '{names[i]}'"
            if names is not None and i < len(names)
            else f"observed output {i}"
        )
        val = _require_real(val, where)
        if np.ndim(val) == 0:
            block[i, :] = float(val)
        else:
            arr = np.asarray(val, dtype=float)
            if arr.size == 1:
                block[i, :] = float(arr.reshape(-1)[0])
            elif arr.size == n:
                block[i, :] = arr
            else:
                block[i, :] = float(arr.reshape(-1)[0])
    return block


def namespace_scope(names: Iterable[str], extra: Iterable[str] = ()) -> set[str]:
    """The COMPONENT / SUBSYSTEM names a rule-2 override key may spell in its
    LEADING segments (esm-spec §6.6.2 rule 2, §4.6).

    Every non-final dotted segment of a build-resolved name is a namespace the
    build itself carries (``Left.gain`` ⇒ ``Left``; ``M.sub.A`` ⇒ ``M``,
    ``sub``), and ``extra`` supplies the namespaces the NAMES cannot show: the
    contributing component systems of a flattened build
    (``FlattenMetadata.source_systems``) and the enclosing model's own name on a
    build that does not qualify its variables at all.

    The Julia (``_override_namespaces``) and Rust (``namespace_scope``) mirrors
    derive the same set.
    """
    out = {str(e) for e in extra}
    for name in names:
        parts = str(name).split(".")
        out.update(parts[:-1])
    return out


def flat_namespace_scope(flat: Any) -> set[str]:
    """:func:`namespace_scope` for a whole :class:`~earthsci_ast.flatten.FlattenedSystem`.

    The namespace segments of every flattened name (which is where a mounted
    subsystem shows up at all) plus ``metadata.source_systems``, the contributing
    component names — a component that declares no variable of its own still
    names a legal §4.6 qualifier. The Rust mirror reads the same two sources in
    ``Compiled::from_flattened``.
    """
    names = [
        *flat.state_variables,
        *flat.parameters,
        *flat.observed_variables,
    ]
    return namespace_scope(names, getattr(flat.metadata, "source_systems", ()) or ())


def check_parameter_override_keys(
    parameter_names: Iterable[str],
    overrides: dict[str, Any] | None,
    namespaces: Collection[str] | None = None,
) -> None:
    """Reject any ``parameter_overrides`` key that names no single parameter, and
    any parameter that two keys both designate (esm-spec §6.6.2 "Unrecognized
    override keys").

    A key resolves under the same precedence :func:`_resolve_override` reads
    with, and that Julia's ``_canonicalize_override_keys`` and Rust's
    ``canonicalize_override_keys`` implement:

    1. an exact hit on a flattened parameter name wins;
    2. else a DOTTED key whose LONGEST dotted suffix is itself a parameter
       name resolves to it (``M.A`` against a bare-named single-model system;
       ``M.sub.A`` against a build that carries the mounted subsystem parameter
       as ``sub.A`` — the §4.6 fully-qualified spelling of a name the build
       holds in a shorter form); suffixes are tried most-qualified first and
       the trailing segment last, and EVERY leading segment dropped along the
       way must name a component or subsystem in ``namespaces``, so a typo'd
       ``Missng.M.pert_amp`` is reported rather than silently suffix-matched
       onto ``M.pert_amp``;
    3. else a BARE key that is the trailing segment of exactly ONE parameter
       resolves to it (``A`` against the flattened ``M.A``);
    4. else a BARE key carried by two or more parameters is AMBIGUOUS —
       :class:`AmbiguousParameterError`, reported with its candidates;
    5. else it is UNKNOWN — :class:`UnknownParameterError`.

    Two NON-EXACT keys designating ONE parameter — ``solo`` (rule 3) and
    ``Doc.Left.solo`` (rule 2) both landing on ``Left.solo``, or ``A.M.g`` and
    ``B.M.g`` both landing on ``M.g`` — is a document authoring error, raised as
    :class:`AmbiguousParameterError` naming the parameter and every colliding
    key. Picking a winner among them would be a wrong answer rather than a
    missing one: the caller wrote two overrides and only one can take effect. An
    EXACT key is never part of a collision — rule 1 identifies its parameter
    outright, so it wins over any suffix or bare claim on that parameter.

    ``namespaces`` defaults to the namespaces the parameter names themselves
    carry (:func:`namespace_scope`); a caller that knows the document's
    component and subsystem names passes them so a build whose variables are
    unqualified still admits their §4.6 spelling.

    Rules 4 and 5 used to be silent: ``_resolve_override`` simply never found
    the key and every parameter kept its default, so a mis-keyed override ran
    the model unperturbed and the inline test still reported a verdict. That is
    a wrong answer, not a missing one. Rust already raised
    ``SimulateError::InvalidParameter``; this makes the three bindings agree.

    Offending keys are reported in sorted order so the diagnostic does not
    depend on ``dict`` insertion order.
    """
    if not overrides:
        return
    known = set(parameter_names)
    ns = namespace_scope(known) if namespaces is None else set(namespaces)
    groups: dict[str, list[str]] = {}
    for name in known:
        bare = name.rsplit(".", 1)[-1]
        if bare != name:
            groups.setdefault(bare, []).append(name)
    unknown: list[str] = []
    ambiguous: list[tuple[str, list[str]]] = []
    exact: set[str] = set()
    claims: dict[str, list[str]] = {}
    for key in overrides:
        if key in known:
            exact.add(key)
            continue
        hit = _dotted_suffix_hit(known, key, ns)
        if hit is not None:
            claims.setdefault(hit, []).append(key)
            continue
        candidates = groups.get(key)
        if candidates is None:
            unknown.append(key)
        elif len(candidates) > 1:
            ambiguous.append((key, sorted(candidates)))
        else:
            claims.setdefault(candidates[0], []).append(key)
    if ambiguous:
        key, candidates = sorted(ambiguous)[0]
        raise AmbiguousParameterError(
            f"parameter_overrides: ambiguous parameter name {key!r} — it is the local "
            f"name of {len(candidates)} parameters ({', '.join(candidates)}). Qualify "
            f"it with its owning component (esm-spec §6.6.2)."
        )
    collisions = sorted(
        (name, sorted(keys)) for name, keys in claims.items() if name not in exact and len(keys) > 1
    )
    if collisions:
        name, keys = collisions[0]
        raise AmbiguousParameterError(
            _collision_message("parameter_overrides", "parameter", name, keys)
        )
    if unknown:
        listed = ", ".join(sorted(known)) if known else "none"
        raise UnknownParameterError(
            f"parameter_overrides: unknown parameter {sorted(unknown)[0]!r} — this "
            f"system declares no such parameter (known: {listed}). esm-spec §6.6.2 "
            f"keys parameter_overrides by LOCAL parameter name."
        )


def _collision_message(surface: str, kind: str, name: str, keys: list[str]) -> str:
    """The esm-spec §6.6.2 "two keys, one name" diagnostic, worded identically in
    Julia (``_override_collision_message``) and Rust
    (``SimulateError::CollidingParameterKeys``)."""
    return (
        f"{surface}: {len(keys)} keys designate the {kind} '{name}' "
        f"({', '.join(keys)}). Supply exactly one override key per name "
        f"(esm-spec §6.6.2)."
    )


def _dotted_suffix_hit(
    known: Collection[str], key: str, namespaces: Collection[str] | None = None
) -> str | None:
    """Rule 2 of :func:`check_parameter_override_keys`: the LONGEST dotted
    suffix of a dotted ``key`` — every ``<segment>.`` prefix dropped in turn,
    most-qualified first — that is itself a known name, PROVIDED every segment
    dropped along the way names a component or subsystem in ``namespaces``.

    ``None`` for a bare key, when no suffix is known, or when a leading segment
    names nothing: ``M.sub.A`` tries ``sub.A`` then ``A`` when ``M`` and ``sub``
    are real, while ``Doc.Left.solo`` in a build with no component ``Doc`` is
    rejected rather than re-pointed at ``Left.solo``.
    """
    names = known if isinstance(known, (set, frozenset, dict)) else set(known)
    ns = namespace_scope(names) if namespaces is None else namespaces
    rest = key
    while "." in rest:
        head, rest = rest.split(".", 1)
        if head not in ns:
            return None
        if rest in names:
            return rest
    return None


def resolve_override_raw(
    name: str,
    overrides: dict[str, Any],
    default: Any,
    known: Collection[str] | None = None,
    namespaces: Collection[str] | None = None,
    *,
    surface: str = "parameter_overrides",
    kind: str = "parameter",
) -> Any:
    """The value :func:`_resolve_override` resolves, BEFORE the ``float`` cast.

    Precedence: a caller override wins — the dot-namespaced ``name`` first
    (rule 1, an EXACT hit), then a single NON-EXACT claim on it: its bare
    trailing segment (rule 3) or a MORE-qualified key that RESOLVES to ``name``
    under rule 2 of :func:`check_parameter_override_keys` (``Outer.M.A`` for the
    name ``M.A``) — otherwise the declared ``default``. Returns the value exactly
    as authored, so a caller that supports shaped data (esm-spec §6.3 / §6.6.2: a
    row-major nested JSON array on a SHAPED variable's ``default``,
    ``parameter_overrides`` or ``initial_conditions``) can route a list to its
    array channel instead of forcing it through ``float``. ``None`` when neither
    an override nor a declared default supplies a value.

    TWO non-exact claims on one name — the bare spelling and a more-qualified
    one, or two more-qualified ones — raise :class:`AmbiguousParameterError`
    naming ``name`` and every colliding key. The caller wrote two overrides and
    only one can take effect, so choosing between them would be a wrong answer
    rather than a missing one. An EXACT hit is never part of a collision: rule 1
    identifies the name outright and the other claims are discarded.

    Rule 2 is applied FORWARD — key to the one name it designates — exactly as
    Julia's ``_canonicalize_override_keys`` and Rust's
    ``canonicalize_override_keys`` apply it, which is why ``known`` (the build's
    full set of resolvable names) is needed rather than just ``name``. Matching
    backwards, "every key of which ``name`` is a dotted suffix", is not the same
    rule: with the flattened parameters ``Left.solo`` and ``Right.Left.solo``
    both in the build, the key ``Right.Left.solo`` is an EXACT hit on the second
    and a dotted suffix of nothing else, but read backwards it also matches
    ``Left.solo`` and silently drives two unrelated parameters from one
    override. A key that is itself a known name is therefore never read as a
    more-qualified spelling of some other name.

    ``known`` defaults to ``{name}`` — the single-name view — so a caller
    resolving one isolated name need not supply it; every caller resolving a
    whole build passes its name set. It must be a CONTAINER, not a one-shot
    iterator: it is membership-tested and reused per call. ``namespaces`` is the
    component / subsystem scope rule 2 validates a key's leading segments
    against (:func:`namespace_scope`), defaulting to the namespaces the names
    themselves carry — under which ``Doc.Left.solo`` no longer reaches
    ``Left.solo``, because no component ``Doc`` exists.

    ``surface`` / ``kind`` word the collision diagnostic for the caller's
    channel (``"parameter_overrides"`` / ``"parameter"`` versus
    ``"initial_conditions"`` / ``"state"``).
    """
    if not overrides:
        return default
    bare = name.rsplit(".", 1)[-1]
    if name in overrides:
        return overrides[name]
    # `name` is always in the view, so a caller that passes a partial `known`
    # cannot make its own name unresolvable. The caller's own set is REUSED when
    # it already carries `name` — copying it per parameter is quadratic on a
    # build with thousands of them, and this is the common case.
    if known is None:
        names: Collection[str] = {name}
    elif name in known:
        names = known
    else:
        names = set(known) | {name}
    ns = namespace_scope(names) if namespaces is None else namespaces
    claims = [k for k in overrides if k not in names and _dotted_suffix_hit(names, k, ns) == name]
    if bare != name and bare in overrides:
        claims.append(bare)
    if len(claims) > 1:
        raise AmbiguousParameterError(_collision_message(surface, kind, name, sorted(claims)))
    if claims:
        return overrides[claims[0]]
    return default


def is_inline_array_value(value: Any) -> bool:
    """Whether a resolved ``default`` / override value is INLINE ARRAY data —
    a row-major nested JSON array (esm-spec §6.3, §6.6.2) rather than a scalar.

    ``list``/``tuple`` only: the wire form is JSON, so authored array data is
    always a list. A NumPy array supplied programmatically counts too; a string
    (a scoped reference) never does.
    """
    if isinstance(value, (list, tuple)):
        return True
    return isinstance(value, np.ndarray) and value.ndim > 0


def coerce_inline_array(
    name: str, value: Any, shape: tuple[int, ...] | None, *, origin: str
) -> np.ndarray:
    """Turn one authored row-major nested JSON array into its dense NumPy array,
    validating it against the variable's declared ``shape`` (esm-spec §6.3 /
    §6.6.2).

    ``shape`` is the declared shape resolved to integer extents after
    metaparameter folding, or ``None`` when the caller could not resolve it (a
    derived index set that has not materialized) — the value is then accepted as
    authored. A ragged array, a non-numeric leaf, or a shape mismatch is a
    LOAD-TIME error, mirroring the ``from_file`` convention of §6.6.5 ("a
    row-major nested JSON array exactly matching the field's shape.
    Implementations MUST validate the shape and reject mismatches").

    ``origin`` names the position for the diagnostic (``"default"``,
    ``"parameter_overrides"``, ``"initial_conditions"``).
    """
    try:
        arr = np.asarray(value, dtype=float)
    except (TypeError, ValueError) as exc:
        raise SimulationError(
            f"{origin}[{name}]: inline array data must be a row-major nested JSON "
            f"array of numbers with equal-length axes (esm-spec §6.3) ({exc})"
        ) from exc
    if arr.dtype != np.float64 or arr.ndim == 0:
        raise SimulationError(
            f"{origin}[{name}]: inline array data must be a row-major nested JSON "
            f"array of numbers with equal-length axes (esm-spec §6.3)"
        )
    if shape is not None and tuple(arr.shape) != tuple(shape):
        raise SimulationError(
            f"{origin}[{name}]: inline array data has shape {tuple(arr.shape)}, which "
            f"does not match the declared shape {tuple(shape)} (esm-spec §6.6.2 — the "
            f"array MUST match the variable's declared shape after metaparameter "
            f"folding)"
        )
    return arr


def _resolve_override(
    name: str,
    overrides: dict[str, Any],
    default: Any,
    known: Collection[str] | None = None,
    namespaces: Collection[str] | None = None,
    *,
    surface: str = "parameter_overrides",
    kind: str = "parameter",
) -> float:
    """Resolve a parameter / initial-condition value against caller overrides.

    Precedence: a caller override wins — the dot-namespaced ``name`` first, then
    a single non-exact claim on it (its bare trailing segment, or a
    MORE-qualified key that resolves to ``name`` under rule 2 of
    :func:`check_parameter_override_keys`) — otherwise the declared ``default``
    when numeric, otherwise ``0.0``. Always returned as ``float``. See
    :func:`resolve_override_raw` for the precedence itself, for what ``known``
    and ``namespaces`` are, and for the two-keys-one-name collision it raises.

    INLINE ARRAY data (esm-spec §6.3 / §6.6.2) is a hard error here rather than a
    ``TypeError`` out of ``float``: a shaped value belongs on the caller's ARRAY
    channel (:func:`coerce_inline_array`), and a pathway with no array channel —
    the scalar SymPy one — must say so plainly instead of failing on the cast.
    """
    value = resolve_override_raw(
        name, overrides, default, known, namespaces, surface=surface, kind=kind
    )
    if is_inline_array_value(value):
        raise SimulationError(
            f"{name!r} carries inline ARRAY data (esm-spec §6.3 / §6.6.2), which this "
            f"pathway cannot bind: a nested-array `default` / `parameter_overrides` / "
            f"`initial_conditions` value requires the array simulation pathway."
        )
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        value = 0.0
    return float(value)
