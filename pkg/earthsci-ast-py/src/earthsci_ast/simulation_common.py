"""Shared building blocks for the simulation pathways.

Holds the pieces every simulation pathway needs — the
:class:`SimulationResult` container, the optional SciPy import guard, and the
dense-output point budget — so the pathway submodules
(:mod:`.simulation_array`, :mod:`.simulation_loaders`,
:mod:`.simulation_scalar`) can share them without importing each other.
``earthsci_ast.simulation`` re-exports this module's API.
"""
from __future__ import annotations

import warnings
from dataclasses import dataclass
from typing import Any

import numpy as np

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


@dataclass
class SimulationResult:
    """Result of a simulation run."""

    t: np.ndarray
    y: np.ndarray
    vars: list[str]  # Variable names corresponding to y rows
    success: bool
    message: str
    nfev: int
    njev: int
    nlu: int
    events: list[np.ndarray] | None = None

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

        if not self.success:
            raise RuntimeError(f"Cannot plot failed simulation: {self.message}")

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
                        UserWarning, stacklevel=2,
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
) -> SimulationResult:
    """Build the uniform failure :class:`SimulationResult` (empty trajectory).

    Every simulation pathway reports a failure with the same shape: empty ``t``
    and ``y`` (``[[]]``), no variables, ``success=False`` and the given
    ``message``. ``nfev`` / ``njev`` / ``nlu`` default to 0 (nothing ran); the
    cadence-segmented loader path passes its accumulated solver counts so a
    failure mid-run still reports the work already done.
    """
    return SimulationResult(
        t=np.array([]),
        y=np.array([[]]),
        vars=[],
        success=False,
        message=message,
        nfev=nfev,
        njev=njev,
        nlu=nlu,
    )


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
