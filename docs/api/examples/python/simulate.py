"""Build a problem from a document and integrate it."""

import math
from pathlib import Path

import earthsci_ast

FIXTURES = Path(__file__).resolve().parent.parent / "fixtures"


# region: simulate ops=esm_problem,solve,solution,return_code
doc = earthsci_ast.load_path(FIXTURES / "decay.esm")
prob = earthsci_ast.esm_problem(doc, (0.0, 10.0))

half_life = math.log(2) / 0.1
sol = earthsci_ast.solve(prob, saveat=[0.0, half_life, 10.0])
assert sol.retcode == earthsci_ast.ReturnCode.Success

# A solution is indexed by variable name.
n = sol["N"]
print("N at t = 0, ln 2 / λ, 10:", n)
assert math.isclose(n[1], 50.0, rel_tol=1e-3)
assert math.isclose(n[-1], 100.0 * math.exp(-1.0), rel_tol=1e-3)

# Observed variables are read the same way.
assert math.isclose(sol["half_life"][-1], half_life, rel_tol=1e-9)
# endregion


# region: observed_field ops=observed_field
# What the build computed for an observed that does not depend on the state.
assert math.isclose(earthsci_ast.observed_field(prob, "half_life"), half_life)
# endregion


# region: remake ops=remake
# A new parameter value reuses the same build.
faster = earthsci_ast.remake(prob, p={"lambda": 0.2})
sol2 = earthsci_ast.solve(faster, saveat=[10.0])
assert math.isclose(sol2["N"][-1], 100.0 * math.exp(-2.0), rel_tol=1e-3)
# endregion


# region: integrator ops=init,step,solve_all,integrator
integ = earthsci_ast.init(prob)
earthsci_ast.step(integ)
assert 0.0 < integ.t < 10.0
assert integ["N"] < 100.0

rest = earthsci_ast.solve_all(integ)
assert rest.retcode == earthsci_ast.ReturnCode.Success
assert rest.t[-1] == 10.0
# endregion


# region: ensemble_problem ops=ensemble_problem,solve
rates = [0.1, 0.2, 0.3]
ensemble = earthsci_ast.EnsembleProblem(
    prob, lambda p, i: earthsci_ast.remake(p, p={"lambda": rates[i]})
)
runs = earthsci_ast.solve(ensemble, trajectories=len(rates), saveat=[10.0])
finals = [run["N"][-1] for run in runs]
for rate, final in zip(rates, finals):
    assert math.isclose(final, 100.0 * math.exp(-rate * 10.0), rel_tol=1e-3)
# endregion
