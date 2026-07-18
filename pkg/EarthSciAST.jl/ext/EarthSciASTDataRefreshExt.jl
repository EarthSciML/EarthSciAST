"""
    EarthSciASTDataRefreshExt

The discrete-cadence loader-refresh callback constructor (ess-14f.4, JL-J1),
loaded automatically when both `DiffEqCallbacks` and `SciMLBase` are in the
session. It supplies the one method the core `build_refresh_callback` generic is
missing: the body that builds a `PresetTimeCallback` whose `affect!` refreshes
the live forcing buffers (`param_arrays` / `_NK_PARAM_GATHER`, ess-14f.3).

Kept out of the base package per `[[library-exposes-rhs-not-solver]]` and R4 of
the plan (mayor-dir esio-consumer-julia-plan-2026-06-26.md §6): returning a
`PresetTimeCallback` needs `DiffEqCallbacks`, and `u_modified!` needs
`SciMLBase` — both solver-adjacent, so they stay `weakdeps`, mirroring the
existing `MTKExt` / `CatalystExt` pattern. Without them loaded, the core
fallback throws a `RefreshError` telling the user what to load.
"""
module EarthSciASTDataRefreshExt

using EarthSciAST: RefreshBuffers,
    RefreshError, provider_is_const, provider_refresh_times, provider_sample,
    _write_forcing!
# Explicit import so we can add the extension method to this generic.
import EarthSciAST: build_refresh_callback
import DiffEqCallbacks: PresetTimeCallback
import SciMLBase: u_modified!

# Group the refreshed (DISCRETE) variables by their provider OBJECT so a provider
# serving several variables is sampled once per cadence boundary, not once per
# variable. CONST providers (materialize-once, no cadence) are dropped here — they
# ride `const_arrays` and never refresh. Variables are visited in sorted order so
# the grouping, the tstops union, and the affect! are deterministic regardless of
# the `providers` dict's iteration order.
function _group_discrete_providers(providers::AbstractDict, buffers::RefreshBuffers)
    groups = Tuple{Any,Vector{String}}[]   # (provider, [var,…]) in first-seen order
    slot = Base.IdDict{Any,Int}()           # provider identity → index into `groups`
    # Sort by stringified variable name for deterministic grouping/tstops/affect,
    # independent of the dict's key type and iteration order.
    entries = sort!(Tuple{String,Any}[(String(k), v) for (k, v) in pairs(providers)];
                    by=first)
    for (var, prov) in entries
        provider_is_const(prov) && continue
        haskey(buffers, var) || throw(RefreshError(
            "build_refresh_callback: no buffer for refreshed variable '$var'; add it to " *
            "`buffers` (the same Array{Float64} passed to build_evaluator's param_arrays)"))
        i = get(slot, prov, 0)
        if i == 0
            push!(groups, (prov, String[var]))
            slot[prov] = length(groups)
        else
            push!(groups[i][2], var)
        end
    end
    return groups
end

# Zero-positional keyword method (the callback is a pure function of the
# provider/buffer registries; it never reads the model). More specific than the
# core's varargs fallback, so it wins whenever this extension is loaded.
function build_refresh_callback(;
                                providers::AbstractDict,
                                buffers::RefreshBuffers,
                                post_refresh::Function = () -> nothing)
    groups = _group_discrete_providers(providers, buffers)

    # tstops = sorted, de-duplicated union of the DISCRETE providers' refresh
    # times. Each distinct provider object is consulted once.
    tstops = Float64[]
    for (prov, _vars) in groups
        append!(tstops, provider_refresh_times(prov))
    end
    sort!(tstops)
    unique!(tstops)

    # The affect: at each anchor, sample → write each native forcing into its
    # buffer IN PLACE, then force the integrator to recompute its cached
    # derivative. (Regrid is an in-model coupling the RHS evaluates, not here.)
    #
    # `u_modified!(integrator, true)` — NOT `false`. We changed the forcing buffer
    # in `p`, so `f(u, p, t)` changed even though `u` did not. FSAL integrators
    # (Tsit5, …) reuse the last stage's derivative as the next step's first stage;
    # leaving the modified flag false would keep that STALE derivative (computed
    # from the pre-refresh forcing) for one stage, blending old and new forcing
    # across the boundary (a ~stage-sized error per anchor). `true` recomputes
    # `f` at the current `u` with the refreshed buffer; it does NOT reset `u` or
    # the trajectory — `u` is untouched, only the derivative cache is refreshed.
    # Runs only at the rare cadence boundaries; the hot per-step RHS path stays
    # zero-alloc because it only READS the (now-refreshed) aliased buffers.
    # `post_refresh` — the discrete-cadence materialization hook (the middle cadence
    # phase; see DiscreteMaterializer). After the RAW forcing buffers are refreshed,
    # it recomputes every derived discrete-cadence cache (the regrid→physics stack)
    # from them, ONCE per boundary. Runs before `u_modified!` so the recomputed
    # derivative sees the fresh caches. Defaults to a no-op (a model with no
    # discrete-materialize var, or a caller who wired none).
    function affect!(integrator)
        t = integrator.t
        for (prov, vars) in groups
            sample = provider_sample(prov, t)
            for var in vars
                _write_forcing!(buffers[var], var, sample)
            end
        end
        post_refresh()
        u_modified!(integrator, true)
        return nothing
    end

    cb = PresetTimeCallback(tstops, affect!)
    return cb, tstops
end

end # module EarthSciASTDataRefreshExt
