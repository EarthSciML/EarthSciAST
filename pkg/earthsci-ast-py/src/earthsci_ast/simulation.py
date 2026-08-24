"""Python simulation tier with SciPy integration — the pathway facade.

The PUBLIC simulation surface is :mod:`earthsci_ast.problem`: one noun
(:class:`~earthsci_ast.problem.Problem`) and one verb
(:func:`~earthsci_ast.problem.solve`). There is no ``simulate`` here any more;
esm-libraries-spec §2.5.1 deletes it in every binding, because it conflated the
per-document build with the per-run integration.

This module remains the facade over the three pathway submodules
(:mod:`.simulation_scalar`, :mod:`.simulation_array`, :mod:`.simulation_loaders`),
re-exporting the public simulation types plus the handful of underscore-private
names consumed elsewhere — the CLI PDE adapter, the PDE inline-test runner, and
a few targeted unit tests import them through ``earthsci_ast.simulation``.

Discretized PDEs run through the array pathway: once spatial operators are
rewritten to ``arrayop`` stencils, the spatial axis folds into array dimensions
(``independent_variables == ["t"]``). The guard in
:func:`~earthsci_ast.problem.esm_problem` rejects only *undiscretized* spatial
operators, not PDEs.
"""

from __future__ import annotations

from .simulation_array import (  # noqa: F401
    BuildInspection,
    _build_numpy_rhs,
    _eval_buildtime_field,
    _order_observed_equations,
    _simulate_with_numpy,
    _time_varying_observeds,
    _vi_lhs_base,
    evaluate_rhs,
)

# Optional scipy import - only needed for actual simulation. The guard lives
# in simulation_common (shared by every pathway); the names are re-exported
# here so ``from earthsci_ast.simulation import SCIPY_AVAILABLE`` (and
# ``solve_ivp``) keep working.
from .simulation_common import (  # noqa: F401
    DENSE_OUTPUT_MIN_POINTS,
    SCIPY_AVAILABLE,
    ReturnCode,
    Solution,
    _failure_result,
    check_parameter_override_keys,
    solve_ivp,
)

# ---------------------------------------------------------------------------
# Pathway submodules. simulation.py is the facade: it re-exports the public
# simulation API plus the handful of underscore-private names that are actually
# consumed elsewhere — the CLI PDE adapter, the PDE inline-test runner, and a
# few targeted unit tests import them through ``earthsci_ast.simulation``.
# Private names used nowhere outside their defining submodule are NOT funnelled
# through here; import those directly from the submodule that defines them.
# Import direction is acyclic: the submodules never import this module.
# ---------------------------------------------------------------------------
from .simulation_loaders import (  # noqa: F401
    LoaderProvider,
    _provider_array,
    _provider_is_discrete,
    _provider_sample_field,
    _simulate_with_discrete_providers,
    _simulate_with_loaders,
)
from .simulation_scalar import (  # noqa: F401
    _build_scalar_rhs,
    _simulate_scalar,
)
from .sympy_bridge import (
    SimulationError,  # noqa: F401 — re-exported (earthsci_ast.__init__ imports it here)
)
