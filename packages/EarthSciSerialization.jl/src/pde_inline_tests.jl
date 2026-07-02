# ===========================================================================
# pde_inline_tests — the §6.6.5-capable inline-test runner over the tree-walk
# simulation pathway (the PDE dual of run_tests.jl's MTK scalar runner).
#
# A PDE model's inline tests (esm-spec §6.6.5) assert REDUCTIONS of a spatial
# field — `reduce: L2_error | Linf_error` against an analytic `reference`
# expression, or the pure collapsers `mean | max | min` — rather than scalar
# point samples. The MTK-based `run_esm_tests` cannot compile
# `aggregate`/`makearray` discretizations; this runner drives the official
# tree-walk pipeline instead: `simulate` (build_evaluator → seed ICs → solve
# via the SciMLBase extension) then per-assertion field reduction.
#
# `[[library-exposes-rhs-not-solver]]`: the caller supplies the ODE algorithm
# (`alg = Tsit5()` with OrdinaryDiffEqTsit5 loaded), exactly as for `simulate`.
#
# Public surface:
# - `evaluate_cellwise(expr, cells; …)` — official per-cell evaluation of an
#   array-valued expression (grid geometry / §6.6.5 analytic references),
#   through the same `_index_at_cell → _resolve_indices → _compile` machinery
#   the evaluator uses for coordinate-expression `ic` seeding.
# - `field_reduce(kind, actual; reference=…)` — the §6.6.5 reduction semantics
#   (relative L2, absolute Linf, mean/max/min).
# - `run_pde_tests(input; model_name, alg, reltol, abstol)` — run every inline
#   test of the selected model(s); returns per-assertion results carrying the
#   ACTUAL reduction values (conformance runners record these).
# ===========================================================================

"""
    PdeAssertionResult

Outcome of one §6.6.5 inline-test assertion evaluated through the tree-walk
simulation pathway. `actual` is the computed reduction value (`nothing` when
the simulation or reduction itself failed); `message` carries the diff or
error text for non-passing results.
"""
struct PdeAssertionResult
    model::String
    test_id::String
    assertion_idx::Int
    variable::String
    time::Float64
    reduce::Union{String,Nothing}
    expected::Float64
    actual::Union{Float64,Nothing}
    rtol::Float64
    atol::Float64
    passed::Bool
    message::String
end

"""
    evaluate_cellwise(expr, cells; const_arrays=Dict(), registered_functions=Dict())
        -> Vector{Float64}

Evaluate an array-valued expression (elementwise ops over array-producing
`aggregate`/`makearray` nodes — e.g. a grid-geometry template expanded by a
§9.7 import, or a §6.6.5 analytic `reference`) at each 1-based integer cell of
`cells`, returning one Float64 per cell. This is the public entry to the same
build-time machinery `build_evaluator` uses to seed coordinate-expression `ic`
fields; state references are not in scope.
"""
function evaluate_cellwise(expr::Expr, cells::AbstractVector{<:AbstractVector{<:Integer}};
                           const_arrays::AbstractDict=Dict{String,Any}(),
                           registered_functions::AbstractDict=Dict{String,Function}())::Vector{Float64}
    return Float64[_eval_cellwise(expr, collect(Int, c);
                                  const_arrays=const_arrays,
                                  registered_functions=registered_functions)
                   for c in cells]
end

"""
    field_reduce(kind, actual; reference=nothing) -> Float64

Collapse a spatial field to the scalar a §6.6.5 `reduce` assertion compares
(esm-spec §6.6.5):

- `"L2_error"`  — `‖actual − reference‖₂ / ‖reference‖₂` (relative L2 over the
  domain; requires `reference`).
- `"Linf_error"` — `max |actual − reference|` (absolute supremum norm; requires
  `reference`).
- `"mean" | "max" | "min"` — pure collapsers of `actual`.

`"integral"` requires the grid measure and is not implemented here.
"""
function field_reduce(kind::AbstractString, actual::AbstractVector{<:Real};
                      reference::Union{Nothing,AbstractVector{<:Real}}=nothing)::Float64
    k = String(kind)
    if k == "L2_error" || k == "Linf_error"
        reference === nothing &&
            throw(ArgumentError("field_reduce: `$(k)` requires a reference field"))
        length(reference) == length(actual) ||
            throw(ArgumentError("field_reduce: actual has $(length(actual)) cells " *
                                "but reference has $(length(reference))"))
        diff = Float64[Float64(a) - Float64(r) for (a, r) in zip(actual, reference)]
        if k == "L2_error"
            refnorm = sqrt(sum(abs2(Float64(r)) for r in reference))
            refnorm == 0.0 &&
                throw(ArgumentError("field_reduce: L2_error reference has zero norm"))
            return sqrt(sum(abs2, diff)) / refnorm
        end
        return maximum(abs, diff)
    elseif k == "mean"
        isempty(actual) && throw(ArgumentError("field_reduce: empty field"))
        return sum(Float64(a) for a in actual) / length(actual)
    elseif k == "max"
        return Float64(maximum(actual))
    elseif k == "min"
        return Float64(minimum(actual))
    end
    throw(ArgumentError("field_reduce: unsupported reduce kind '$(k)'"))
end

# Collect the (cell-index-tuple, flat-slot) pairs of one array state from a
# var_map. Flattening may prefix element names with the owning model
# ("Heat.u[3]"); a name matches when its element stem equals `variable` bare,
# or `model.variable` qualified. Sorted by cell tuple so callers get a
# deterministic pairing.
function _state_cells(var_map::AbstractDict, variable::AbstractString,
                      model::AbstractString)
    out = Tuple{Vector{Int},Int}[]
    qualified = String(model) * "." * String(variable)
    for (name, slot) in var_map
        m = match(r"^(.+)\[([0-9,]+)\]$", String(name))
        m === nothing && continue
        stem = m.captures[1]
        bare = occursin('.', stem) ? String(split(stem, '.'; limit=2)[2]) : String(stem)
        (stem == qualified || stem == String(variable) || bare == String(variable)) ||
            continue
        push!(out, ([parse(Int, x) for x in split(m.captures[2], ",")], Int(slot)))
    end
    sort!(out; by=first)
    return out
end

# Flat slot of a SCALAR state by bare or model-qualified name; 0 if absent.
function _scalar_slot(var_map::AbstractDict, variable::AbstractString,
                      model::AbstractString)::Int
    qualified = String(model) * "." * String(variable)
    for (name, slot) in var_map
        s = String(name)
        bare = occursin('.', s) ? String(split(s, '.'; limit=2)[2]) : s
        (s == qualified || s == String(variable) || bare == String(variable)) &&
            return Int(slot)
    end
    return 0
end

"""
    run_pde_tests(input; model_name=nothing, alg=nothing,
                  reltol=1e-10, abstol=1e-12) -> Vector{PdeAssertionResult}

Run every inline test (esm-spec §6.6, including the §6.6.5 PDE assertions) of
the selected model(s) of `input` (a path or a loaded [`EsmFile`](@ref)) through
the official tree-walk simulation pathway, and return one
[`PdeAssertionResult`](@ref) per assertion — carrying the ACTUAL reduction
value alongside pass/fail, so conformance harnesses can record and
cross-compare the numbers.

Per test: `simulate(input, (time_span.start, time_span.stop); alg, reltol,
abstol, saveat=<assertion times>)` with the test's `initial_conditions` /
`parameter_overrides` applied; then per assertion the asserted variable's field
is read at the assertion time and collapsed per its `reduce` (error norms
evaluate the analytic `reference` expression cellwise via
[`evaluate_cellwise`](@ref)). An assertion with neither `coords` nor `reduce`
samples a scalar state. `coords` point-sampling and `from_file` references are
not supported and yield failed results with explanatory messages.

Tolerances resolve per esm-spec §6.6.4 (assertion > test > model > default
`rel=1e-6`); the pass predicate is the same `isapprox` check `run_esm_tests`
uses. `alg` is REQUIRED (e.g. `Tsit5()` with OrdinaryDiffEqTsit5 loaded) — the
solve runs in the SciMLBase extension.
"""
function run_pde_tests(input; model_name::Union{Nothing,AbstractString}=nothing,
                       alg=nothing, reltol::Float64=1e-10, abstol::Float64=1e-12)
    file = input isa AbstractString ? load(String(input)) : input
    file isa EsmFile ||
        throw(ArgumentError("run_pde_tests expects a path or EsmFile, got $(typeof(input))"))
    results = PdeAssertionResult[]
    file.models === nothing && return results
    for (mname, model) in file.models
        model_name !== nothing && String(mname) != String(model_name) && continue
        isempty(model.tests) && continue
        for t in model.tests
            times = sort!(unique(Float64[a.time for a in t.assertions]))
            sim = nothing
            sim_err = ""
            try
                # `simulate` flattens the file (models + coupling) into ONE
                # runnable system named "Flattened", so no model_name is passed
                # here; element names keep their owning-model prefix, which the
                # `_state_cells` / `_scalar_slot` lookups resolve per assertion.
                sim = simulate(file, (t.time_span.start, t.time_span.stop);
                               alg=alg, reltol=reltol, abstol=abstol, saveat=times,
                               parameters=t.parameter_overrides,
                               initial_conditions=t.initial_conditions)
                sim.success || (sim_err = "solver retcode $(sim.retcode): $(sim.message)"; sim = nothing)
            catch err
                sim_err = "simulate failed: $(sprint(showerror, err))"
                sim = nothing
            end
            for (i, a) in enumerate(t.assertions)
                rtol, atol = _resolve_tolerance(model.tolerance, t.tolerance, a.tolerance)
                if sim === nothing
                    push!(results, PdeAssertionResult(String(mname), t.id, i,
                        a.variable, a.time, a.reduce, a.expected, nothing,
                        rtol, atol, false, sim_err))
                    continue
                end
                actual::Union{Float64,Nothing} = nothing
                msg = ""
                try
                    ti = argmin(abs.(sim.t .- a.time))
                    abs(sim.t[ti] - a.time) <= 1e-9 * max(1.0, abs(a.time)) ||
                        error("no saved state at t=$(a.time) (nearest $(sim.t[ti]))")
                    state = sim.u[ti]
                    if a.coords !== nothing
                        error("`coords` point-sampling is not supported by run_pde_tests")
                    elseif a.reduce === nothing
                        slot = _scalar_slot(sim.var_map, a.variable, String(mname))
                        slot == 0 && error("scalar state '$(a.variable)' not found")
                        actual = state[slot]
                    else
                        cells = _state_cells(sim.var_map, a.variable, String(mname))
                        isempty(cells) &&
                            error("array state '$(a.variable)' has no cells in var_map")
                        field = Float64[state[slot] for (_, slot) in cells]
                        ref = nothing
                        if a.reference !== nothing
                            a.reference isa Expr ||
                                error("only inline-expression `reference` is supported " *
                                      "(from_file references are not)")
                            ref = evaluate_cellwise(a.reference, [c for (c, _) in cells])
                        end
                        actual = field_reduce(a.reduce, field; reference=ref)
                    end
                catch err
                    msg = "assertion evaluation failed: $(sprint(showerror, err))"
                end
                if actual === nothing
                    push!(results, PdeAssertionResult(String(mname), t.id, i,
                        a.variable, a.time, a.reduce, a.expected, nothing,
                        rtol, atol, false, msg))
                else
                    ok = _check_assertion(actual, a.expected, rtol, atol)
                    ok || (msg = "actual=$(actual) expected=$(a.expected) " *
                                 "(rtol=$(rtol), atol=$(atol))")
                    push!(results, PdeAssertionResult(String(mname), t.id, i,
                        a.variable, a.time, a.reduce, a.expected, actual,
                        rtol, atol, ok, msg))
                end
            end
        end
    end
    return results
end
