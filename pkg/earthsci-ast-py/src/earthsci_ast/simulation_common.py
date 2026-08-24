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
from collections.abc import Iterable
from dataclasses import dataclass
from enum import Enum
from typing import Any

import numpy as np

from .errors import AmbiguousParameterError, UnknownParameterError

# Optional scipy import - only needed for actual simulation
try:
    from scipy.integrate import solve_ivp

    SCIPY_AVAILABLE = True
except (ImportError, ValueError):
    # ValueError can occur due to numpy/scipy compatibility issues
    SCIPY_AVAILABLE = False
    solve_ivp = None

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


def _observed_rows(vals, n: int) -> np.ndarray:
    """Materialize observed-body outputs into a ``(len(vals), n)`` float matrix.

    Each observed value is broadcast onto the ``n``-point time grid: a scalar
    (``ndim == 0``) or a size-1 array fills the whole row with its single value;
    a full-length array (``size == n``) is copied verbatim; any other size falls
    back to its first element broadcast across the row.
    """
    block = np.empty((len(vals), n), dtype=float)
    for i, val in enumerate(vals):
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


def check_parameter_override_keys(
    parameter_names: Iterable[str], overrides: dict[str, Any] | None
) -> None:
    """Reject any ``parameter_overrides`` key that names no single parameter
    (esm-spec §6.6.2 "Unrecognized override keys").

    A key resolves under the same precedence :func:`_resolve_override` reads
    with, and that Julia's ``_canonicalize_override_keys`` and Rust's
    ``canonicalize_override_keys`` implement:

    1. an exact hit on a flattened parameter name wins;
    2. else a DOTTED key whose trailing segment is itself a parameter name
       resolves to it (``M.A`` against a bare-named single-model system);
    3. else a BARE key that is the trailing segment of exactly ONE parameter
       resolves to it (``A`` against the flattened ``M.A``);
    4. else a BARE key carried by two or more parameters is AMBIGUOUS —
       :class:`AmbiguousParameterError`, reported with its candidates;
    5. else it is UNKNOWN — :class:`UnknownParameterError`.

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
    groups: dict[str, list[str]] = {}
    for name in known:
        bare = name.rsplit(".", 1)[-1]
        if bare != name:
            groups.setdefault(bare, []).append(name)
    unknown: list[str] = []
    ambiguous: list[tuple[str, list[str]]] = []
    for key in overrides:
        if key in known:
            continue
        bare = key.rsplit(".", 1)[-1]
        if bare != key and bare in known:
            continue
        candidates = groups.get(key)
        if candidates is None:
            unknown.append(key)
        elif len(candidates) > 1:
            ambiguous.append((key, sorted(candidates)))
    if ambiguous:
        key, candidates = sorted(ambiguous)[0]
        raise AmbiguousParameterError(
            f"parameter_overrides: ambiguous parameter name {key!r} — it is the local "
            f"name of {len(candidates)} parameters ({', '.join(candidates)}). Qualify "
            f"it with its owning component (esm-spec §6.6.2)."
        )
    if unknown:
        listed = ", ".join(sorted(known)) if known else "none"
        raise UnknownParameterError(
            f"parameter_overrides: unknown parameter {sorted(unknown)[0]!r} — this "
            f"system declares no such parameter (known: {listed}). esm-spec §6.6.2 "
            f"keys parameter_overrides by LOCAL parameter name."
        )


def _resolve_override(name: str, overrides: dict[str, Any], default: Any) -> float:
    """Resolve a parameter / initial-condition value against caller overrides.

    Precedence: a caller override wins — the dot-namespaced ``name`` first, then
    its bare trailing segment — otherwise the declared ``default`` when numeric,
    otherwise ``0.0``. Always returned as ``float``.
    """
    bare = name.rsplit(".", 1)[-1]
    if name in overrides:
        value = overrides[name]
    elif bare in overrides:
        value = overrides[bare]
    else:
        value = float(default) if isinstance(default, (int, float)) else 0.0
    return float(value)
