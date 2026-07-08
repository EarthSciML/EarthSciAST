"""Shared building blocks for the simulation pathways.

Holds the pieces every simulation pathway needs — the
:class:`SimulationResult` container, the optional SciPy import guard, and the
dense-output point budget — so the pathway submodules
(:mod:`.simulation_array`, :mod:`.simulation_loaders`,
:mod:`.simulation_legacy`) can share them without importing each other.
``earthsci_ast.simulation`` re-exports this module's API.
"""

import numpy as np
from typing import List, Optional
from dataclasses import dataclass

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
    vars: List[str]  # Variable names corresponding to y rows
    success: bool
    message: str
    nfev: int
    njev: int
    nlu: int
    events: Optional[List[np.ndarray]] = None

    def plot(self, variables: Optional[List[str]] = None, **kwargs):
        """
        Plot simulation results using matplotlib.

        Args:
            variables: Optional list of variable names to plot. If None, plots all.
            **kwargs: Additional arguments passed to matplotlib.pyplot
        """
        try:
            import matplotlib.pyplot as plt
        except ImportError:
            raise ImportError(
                "matplotlib is required for plotting. Install with: pip install matplotlib"
            )

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
                    print(f"Warning: Variable '{var}' not found in simulation results")

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
