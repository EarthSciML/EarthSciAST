"""
    EarthSciSerializationSimulateExt

The `simulate` solve seam, loaded automatically when `SciMLBase` is in the
session. It supplies the one method the core `_simulate_solve` generic is
missing: build an `ODEProblem` from the tree-walk RHS and integrate it with the
caller-supplied algorithm, returning a [`SimulationResult`](@ref).

Kept out of the base package per `[[library-exposes-rhs-not-solver]]`: ESS
exposes the RHS (`build_evaluator`) and the cadence callback
(`build_refresh_callback`) but never a solver. `ODEProblem` / `solve` /
`ReturnCode` need `SciMLBase`, so they stay a `weakdep`, mirroring the
`DataRefreshExt` / `MTKExt` / `CatalystExt` pattern. Without it loaded, the core
fallback throws a `SimulateError` telling the user what to load.

The algorithm itself (e.g. `Tsit5`) comes from the caller's own solver package
(OrdinaryDiffEq*); `solve(prob, alg)` dispatches into it. The method is typed on
`SciMLBase.AbstractODEAlgorithm` so it is strictly more specific than the core
untyped fallback and wins whenever a real ODE algorithm is passed.
"""
module EarthSciSerializationSimulateExt

import EarthSciSerialization as ESS
using EarthSciSerialization: SimulationResult
import SciMLBase

function ESS._simulate_solve(f!, u0, tspan, p, alg::SciMLBase.AbstractODEAlgorithm,
                             var_map; callback = nothing, tstops = Float64[],
                             reltol = ESS.DEFAULT_SIM_RELTOL,
                             abstol = ESS.DEFAULT_SIM_ABSTOL, saveat = nothing)
    prob = SciMLBase.ODEProblem(f!, u0, tspan, p)
    kw = Dict{Symbol,Any}(:reltol => reltol, :abstol => abstol)
    callback === nothing || (kw[:callback] = callback)
    isempty(tstops) || (kw[:tstops] = collect(Float64, tstops))
    saveat === nothing || (kw[:saveat] = saveat)
    sol = SciMLBase.solve(prob, alg; kw...)

    success = sol.retcode == SciMLBase.ReturnCode.Success
    return SimulationResult(
        collect(Float64, sol.t),
        Vector{Float64}[Vector{Float64}(u) for u in sol.u],
        var_map,
        success,
        Symbol(sol.retcode),
        success ? "The solver successfully reached the end of the integration interval." :
                  "solver returned $(sol.retcode)")
end

end # module EarthSciSerializationSimulateExt
