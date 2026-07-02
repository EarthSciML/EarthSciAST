# ===========================================================================
# pde_inline_tests — the §6.6.5-capable inline-test runner over the tree-walk
# simulation pathway (the PDE dual of run_tests.jl's MTK scalar runner).
#
# A PDE model's inline tests (esm-spec §6.6.5) assert REDUCTIONS of a spatial
# field — `reduce: L2_error | Linf_error` against a `reference` (an analytic
# expression or a `from_file` JSON snapshot), or the pure collapsers
# `integral | mean | max | min` — or point-sample it via `coords`. The
# MTK-based `run_esm_tests` cannot compile
# `aggregate`/`makearray` discretizations; this runner drives the official
# tree-walk pipeline instead: `simulate` (build_evaluator → seed ICs → solve
# via the SciMLBase extension) then per-assertion field reduction.
#
# `[[library-exposes-rhs-not-solver]]`: the caller supplies the ODE algorithm
# (`alg = Tsit5()` with OrdinaryDiffEqTsit5 loaded), exactly as for `simulate`.
#
# Cross-binding pinned conventions (identical in the Julia / Python / Rust
# bindings; the esm-spec leaves these open, so determinism requires pinning):
#
# 1. `coords` point-sampling — coords values are positions in INDEX space
#    (1-based, fractional allowed) along the named interval index sets;
#    sampling picks the NEAREST grid index, with exact half-way ties rounding
#    DOWN toward the lower index (`idx = ceil(c - 1/2)`). Keys must name the
#    asserted field's index sets; a strict subset pins only when every
#    remaining dimension has exactly one sample; the resolved index must lie
#    in `1:size`. Mutually exclusive with `reduce`.
# 2. `integral` reduce — the uniform-cell Riemann sum under a UNIT total
#    domain measure per axis: `integral = Σ field / N_cells = mean(field)`.
#    Authors of non-unit physical domains must scale the expectation until
#    the spec grows a measure concept. This is exactly the measure convention
#    under which the relative-L2 reduction is measure-free (the per-cell
#    measure cancels between numerator and denominator).
# 3. `from_file` references — `{type: "from_file", path, format?}`: `path`
#    resolves relative to the .esm file's directory (`base_dir`, defaulting
#    to the loaded path's directory, else the working directory); the default
#    and only v1 `format` is "json" — a row-major nested JSON array exactly
#    matching the field's shape (validated; mismatch is a clear error). The
#    loaded array is used exactly like an evaluated inline reference in the
#    error-norm reductions.
#
# Public surface:
# - `evaluate_cellwise(expr, cells; …)` — official per-cell evaluation of an
#   array-valued expression (grid geometry / §6.6.5 analytic references),
#   through the same `_index_at_cell → _resolve_indices → _compile` machinery
#   the evaluator uses for coordinate-expression `ic` seeding.
# - `field_reduce(kind, actual; reference=…)` — the §6.6.5 reduction semantics
#   (relative L2, absolute Linf, integral/mean/max/min).
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
- `"integral"` — the uniform-cell Riemann sum under a UNIT total domain
  measure per axis: `Σ field / N_cells`, i.e. exactly `mean`. This is the
  pinned cross-binding convention (the same measure convention under which
  the relative-L2 reduction is measure-free); non-unit physical domains must
  be scaled by the author until the spec grows a measure concept.
- `"mean" | "max" | "min"` — pure collapsers of `actual`.
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
    elseif k == "mean" || k == "integral"
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

# A §6.6.5 assertion may target an ARRAY OBSERVED (e.g. a rule output surfaced
# "for direct assertion", like the MPAS `div_flux`) rather than a state: an
# observed carries no ODE slot, so its field is evaluated from the build's
# RESOLVED observed expression (BuildInspection.observed_exprs) through the same
# official `evaluate_cellwise` machinery as an analytic `reference`, with the
# build's const-array registry in scope. STATE-FREE observeds only — a
# state-dependent observed's references stay unbound and error like before.
# Cells are enumerated from the declared shape's interval index sets. Returns
# `(field, cells)` or `nothing` when the variable is not such an observed.
function _observed_field(insp::BuildInspection, file::EsmFile,
                         mname::AbstractString, variable::AbstractString)
    model = get(file.models, String(mname), nothing)
    model === nothing && return nothing
    v = get(model.variables, String(variable), nothing)
    (v !== nothing && v.type == ObservedVariable && v.shape !== nothing &&
     !isempty(v.shape)) || return nothing
    exts = Int[]
    for s in v.shape
        iset = get(file.index_sets, String(s), nothing)
        (iset !== nothing && iset.kind == "interval" && iset.size !== nothing) ||
            return nothing
        push!(exts, Int(iset.size))
    end
    qualified = String(mname) * "." * String(variable)
    expr = get(insp.observed_exprs, qualified,
               get(insp.observed_exprs, String(variable), nothing))
    expr === nothing && return nothing
    cells = sort!(Vector{Int}[collect(Int, Tuple(I))
                              for I in CartesianIndices(Tuple(exts))])
    field = evaluate_cellwise(expr, cells; const_arrays=insp.const_arrays)
    return (field, cells)
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

# The asserted variable's declared spatial shape (ordered index-set names).
# Errors when the variable is missing or scalar — a `coords` assertion is
# ill-formed on a 0-D variable per esm-spec §6.6.5.
function _variable_shape(file::EsmFile, mname::AbstractString,
                         variable::AbstractString)::Vector{String}
    model = file.models === nothing ? nothing : get(file.models, String(mname), nothing)
    model === nothing && error("model '$(mname)' not found")
    v = get(model.variables, String(variable), nothing)
    v === nothing && error("variable '$(variable)' is not declared in model '$(mname)'")
    (v.shape === nothing || isempty(v.shape)) &&
        error("`coords` requires a spatially-shaped variable; '$(variable)' is scalar")
    return String[String(s) for s in v.shape]
end

# Resolve a §6.6.5 `coords` map to a concrete 1-based cell tuple over `shape`
# (the field's ordered index-set names), per the pinned cross-binding
# convention: coords values are positions in INDEX space (1-based, fractional
# allowed) along interval index sets; sampling = nearest grid index with exact
# half-way ties rounding DOWN (`idx = ceil(c - 1/2)`). A strict subset of
# dimensions may be pinned only when every remaining dimension is singleton.
function _coords_cell(coords::AbstractDict, shape::Vector{String},
                      index_sets::AbstractDict)::Vector{Int}
    for k in keys(coords)
        String(k) in shape ||
            error("`coords` names unknown dimension '$(k)' " *
                  "(field dimensions: $(join(shape, ", ")))")
    end
    cell = Int[]
    for s in shape
        iset = get(index_sets, s, nothing)
        (iset !== nothing && iset.kind == "interval" && iset.size !== nothing) ||
            error("`coords` sampling requires interval index sets with a " *
                  "declared size; '$(s)' is not one")
        n = Int(iset.size)
        if haskey(coords, s)
            c = Float64(coords[s])
            idx = ceil(Int, c - 0.5)  # nearest index; exact ties round DOWN
            (1 <= idx <= n) ||
                error("`coords` position $(c) along '$(s)' resolves to index " *
                      "$(idx), outside 1..$(n)")
            push!(cell, idx)
        else
            n == 1 ||
                error("`coords` leaves dimension '$(s)' unpinned with $(n) " *
                      "samples; a strict subset pins only when every " *
                      "remaining dimension is singleton")
            push!(cell, 1)
        end
    end
    return cell
end

# Walk a row-major nested JSON array to the value at 1-based `cell`,
# validating each level's extent against `exts` (the field's per-dimension
# extents). The full Cartesian cell sweep visits every node, so ragged or
# mis-sized payloads always surface a shape-mismatch error.
function _nested_at(data, cell::Vector{Int}, exts::Vector{Int})::Float64
    node = data
    for (d, i) in enumerate(cell)
        node isa AbstractVector ||
            error("from_file reference shape mismatch along dimension $(d): " *
                  "expected a nested array of length $(exts[d])")
        length(node) == exts[d] ||
            error("from_file reference shape mismatch along dimension $(d): " *
                  "expected length $(exts[d]), found $(length(node))")
        node = node[i]
    end
    (node isa Real && !(node isa Bool)) ||
        error("from_file reference shape mismatch at cell " *
              "[$(join(cell, ","))]: expected a number")
    return Float64(node)
end

# Load a `{type: "from_file", path, format?}` reference (esm-spec §6.6.5) as
# the per-cell reference field over `cell_tuples`, per the pinned
# cross-binding convention: `path` resolves relative to `base_dir` (the .esm
# file's directory); the default and only v1 `format` is "json" — a row-major
# nested array exactly matching the field's shape.
function _from_file_reference(ref::AbstractDict, base_dir::AbstractString,
                              cell_tuples::Vector{Vector{Int}})::Vector{Float64}
    fmt_raw = get(ref, "format", nothing)
    fmt = fmt_raw === nothing ? "json" : lowercase(String(fmt_raw))
    fmt == "json" ||
        error("from_file reference format '$(fmt)' is not supported " *
              "(v1 supports \"json\" only)")
    path_raw = get(ref, "path", nothing)
    path_raw === nothing && error("from_file reference is missing `path`")
    p = String(path_raw)
    resolved = isabspath(p) ? p : joinpath(String(base_dir), p)
    isfile(resolved) || error("from_file reference file not found: $(resolved)")
    data = JSON3.read(read(resolved, String))
    isempty(cell_tuples) && error("from_file reference: field has no cells")
    nd = length(cell_tuples[1])
    exts = Int[maximum(c[d] for c in cell_tuples) for d in 1:nd]
    return Float64[_nested_at(data, c, exts) for c in cell_tuples]
end

"""
    run_pde_tests(input; model_name=nothing, alg=nothing,
                  reltol=1e-10, abstol=1e-12,
                  base_dir=nothing) -> Vector{PdeAssertionResult}

Run every inline test (esm-spec §6.6, including the §6.6.5 PDE assertions) of
the selected model(s) of `input` (a path or a loaded [`EsmFile`](@ref)) through
the official tree-walk simulation pathway, and return one
[`PdeAssertionResult`](@ref) per assertion — carrying the ACTUAL reduction
value alongside pass/fail, so conformance harnesses can record and
cross-compare the numbers.

Per test: `simulate(input, (time_span.start, time_span.stop); alg, reltol,
abstol, saveat=<assertion times>)` with the test's `initial_conditions` /
`parameter_overrides` applied; then per assertion the asserted variable's field
is read at the assertion time and either point-sampled per its `coords`
(positions in 1-based INDEX space; nearest grid index, exact ties rounding
DOWN — the pinned cross-binding convention) or collapsed per its `reduce`
(error norms evaluate the `reference` — an analytic expression cellwise via
[`evaluate_cellwise`](@ref), or a `{type: "from_file", path, format?}` JSON
snapshot resolved against `base_dir`). An assertion with neither `coords` nor
`reduce` samples a scalar state. `base_dir` defaults to the .esm file's
directory when `input` is a path, else the working directory.

Tolerances resolve per esm-spec §6.6.4 (assertion > test > model > default
`rel=1e-6`); the pass predicate is the same `isapprox` check `run_esm_tests`
uses. `alg` is REQUIRED (e.g. `Tsit5()` with OrdinaryDiffEqTsit5 loaded) — the
solve runs in the SciMLBase extension.
"""
function run_pde_tests(input; model_name::Union{Nothing,AbstractString}=nothing,
                       alg=nothing, reltol::Float64=1e-10, abstol::Float64=1e-12,
                       base_dir::Union{Nothing,AbstractString}=nothing)
    file = input isa AbstractString ? load(String(input)) : input
    file isa EsmFile ||
        throw(ArgumentError("run_pde_tests expects a path or EsmFile, got $(typeof(input))"))
    resolved_base = base_dir !== nothing ? String(base_dir) :
        (input isa AbstractString ? dirname(abspath(String(input))) : pwd())
    results = PdeAssertionResult[]
    file.models === nothing && return results
    for (mname, model) in file.models
        model_name !== nothing && String(mname) != String(model_name) && continue
        isempty(model.tests) && continue
        for t in model.tests
            times = sort!(unique(Float64[a.time for a in t.assertions]))
            sim = nothing
            sim_err = ""
            # Build-observability sink: assertions on ARRAY OBSERVEDS (no ODE
            # slot) evaluate their resolved expression from here (`_observed_field`).
            insp = BuildInspection()
            try
                # `simulate` flattens the file (models + coupling) into ONE
                # runnable system named "Flattened", so no model_name is passed
                # here; element names keep their owning-model prefix, which the
                # `_state_cells` / `_scalar_slot` lookups resolve per assertion.
                sim = simulate(file, (t.time_span.start, t.time_span.stop);
                               alg=alg, reltol=reltol, abstol=abstol, saveat=times,
                               parameters=t.parameter_overrides,
                               initial_conditions=t.initial_conditions,
                               inspect=insp)
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
                    if a.coords === nothing && a.reduce === nothing
                        slot = _scalar_slot(sim.var_map, a.variable, String(mname))
                        slot == 0 && error("scalar state '$(a.variable)' not found")
                        actual = state[slot]
                    else
                        # `coords` validation runs BEFORE field materialization
                        # so a coords assertion on a scalar variable fails with
                        # the §6.6.5 coords-specific message.
                        coords_target = nothing
                        if a.coords !== nothing
                            shape = _variable_shape(file, String(mname),
                                                    String(a.variable))
                            coords_target = _coords_cell(a.coords, shape,
                                                         file.index_sets)
                        end
                        cells = _state_cells(sim.var_map, a.variable, String(mname))
                        local field::Vector{Float64}, cell_tuples::Vector{Vector{Int}}
                        if !isempty(cells)
                            field = Float64[state[slot] for (_, slot) in cells]
                            cell_tuples = [c for (c, _) in cells]
                        else
                            # No ODE slots: try a state-free ARRAY OBSERVED (a
                            # rule output asserted directly, §6.6.5).
                            obs = _observed_field(insp, file, String(mname),
                                                  String(a.variable))
                            obs === nothing &&
                                error("array state '$(a.variable)' has no cells in var_map")
                            field, cell_tuples = obs
                        end
                        if coords_target !== nothing
                            pos = findfirst(==(coords_target), cell_tuples)
                            pos === nothing &&
                                error("no grid sample at cell " *
                                      "[$(join(coords_target, ","))] of '$(a.variable)'")
                            actual = field[pos]
                        else
                            ref = nothing
                            if a.reference !== nothing
                                if a.reference isa Expr
                                    ref = evaluate_cellwise(a.reference, cell_tuples)
                                elseif a.reference isa AbstractDict &&
                                       string(get(a.reference, "type", "")) == "from_file"
                                    ref = _from_file_reference(a.reference,
                                                               resolved_base,
                                                               cell_tuples)
                                else
                                    error("unsupported `reference` shape " *
                                          "$(typeof(a.reference))")
                                end
                            end
                            actual = field_reduce(a.reduce, field; reference=ref)
                        end
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
