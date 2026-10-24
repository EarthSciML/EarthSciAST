# Building a problem from a document and solving it.
using EarthSciAST
using OrdinaryDiffEqTsit5

const FIXTURES = joinpath(@__DIR__, "..", "fixtures")

# region: simulate ops=esm_problem,observed_field
prob = esm_problem(joinpath(FIXTURES, "decay.esm"), (0.0, 10.0))
@assert prob isa EsmProblem

λ = 0.1
sol = solve(prob, Tsit5(); saveat = [0.0, log(2) / λ, 10.0], reltol = 1e-8)
@assert sol.retcode == ReturnCode.Success

# A solution is indexed by the flattened variable name, as a Symbol.
N = sol[Symbol("Decay.N")]
@assert N[1] == 100.0
@assert isapprox(N[2], 50.0; rtol = 1e-5)  # half left after one half-life

# Observed variables are read off the problem. half_life is a scalar field.
half_life = only(observed_field(prob, "half_life"))
@assert half_life ≈ log(2) / λ
# endregion

# region: esm_problem_parameters ops=esm_problem,observed_field
# Override a parameter's default at construction.
faster = esm_problem(joinpath(FIXTURES, "decay.esm"), (0.0, 10.0);
                     p = Dict("lambda" => 0.2))
@assert only(observed_field(faster, "half_life")) ≈ log(2) / 0.2
# endregion
