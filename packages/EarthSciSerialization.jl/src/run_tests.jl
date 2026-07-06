"""
    run_tests.jl

Discovery + inline-test runner for `.esm` files.

Each `Model` and `ReactionSystem` may carry a `tests` block (ESM spec §6.6) of
scalar `(variable, time, expected, [tolerance])` assertions. This module walks
a given set of root directories, parses every `.esm` file via `load`, simulates
each Test on the resulting MTK system, samples each Assertion via the solution
interpolant, and compares to the declared expected value with the tolerance
resolved per spec §6.6.4 (assertion > test > model > default `rel=1e-6`).

The runner requires `ModelingToolkit`, `OrdinaryDiffEqTsit5` /
`OrdinaryDiffEqRosenbrock`, and (for `ReactionSystem` tests) `Catalyst` to be
loaded at the call site so the EarthSciSerialization MTK / Catalyst extensions
are active.

Public surface:
- `discover_esm_files(roots; root=esm_root())` — recursive `.esm` walk
- `run_esm_tests(roots; root=esm_root(), junit_xml=nothing, verbose=true)` —
  returns `(results, exit_code)` where `exit_code == 0` iff every assertion
  passed
- `write_junit_xml(results, path)` — emit a junit-compatible report
"""

using Printf: @printf

"""
    esm_root() -> String

Absolute path to the root of the package directory — the default base against
which relative `roots` and exclude patterns resolve.

!!! warning "Deprecated override pattern"
    Overwriting this method from a call site (defining your own `esm_root()`
    inside this module) to walk a different repo root is method-overwrite
    piracy and is deprecated. Pass the `root` keyword to
    [`discover_esm_files`](@ref) / [`run_esm_tests`](@ref) instead.
"""
esm_root() = pkgdir(@__MODULE__)

"""
    esm_path(parts...) -> String

Join `parts` onto `esm_root()`.
"""
esm_path(parts::AbstractString...) = joinpath(esm_root(), parts...)

# Default discovery roots (relative to `root`/`esm_root()`). This package
# itself ships no `components/` directory — the default exists for downstream
# model repos (e.g. EarthSciModels) that lay their `.esm` files out under one;
# callers here pass explicit roots. `run_esm_tests` warns when discovery
# finds zero files so a mis-rooted invocation cannot silently pass.
const DEFAULT_ROOTS = ["components"]

"""
    AssertionStatus

Outcome status of one inline-test assertion: `PASS`, `FAIL` (value outside
tolerance), or `ERROR` (the load / compile / solve / sample raised).

`SKIP` is RESERVED and currently never produced: spec §6.6 defines no skip
semantics, and mapping missing prerequisites (e.g. Catalyst not loaded for a
ReactionSystem test) to `SKIP` instead of `ERROR` would silently weaken the
exit-code contract (`exit_code == 0` iff nothing failed or errored). It is
kept in the enum so downstream tooling can rely on the value once the spec
grows skip semantics.
"""
@enum AssertionStatus PASS FAIL ERROR SKIP

"""
    AssertionResult

Outcome of one `(file, container, test, assertion_idx)` evaluation.
`message` carries the diff or error text for non-`PASS` results.
`duration_s` is this assertion's even share of its test's wall time (solve +
all samples), so summing `duration_s` over a test's assertions recovers the
test's duration (the JUnit testcase `time`).
"""
struct AssertionResult
    file::String
    container_kind::Symbol   # :model, :reaction_system, or :file (load/parse failure)
    container_name::String
    test_id::String
    assertion_idx::Int
    variable::String
    time::Float64
    expected::Float64
    actual::Union{Float64,Nothing}
    status::AssertionStatus
    message::String
    duration_s::Float64
end

# ---------------------------------------------------------------------------
# Discovery
# ---------------------------------------------------------------------------

# Resolve exclude patterns: either an explicit kwarg vector, or the
# ESM_TESTS_EXCLUDE env var (";" or ":" separated). Patterns are matched as
# substrings against the absolute discovered path AND the path relative to
# `esm_root()`, so users can write either "components/gaschem/geoschem_fullchem.esm"
# or just "geoschem_fullchem.esm".
function _resolve_exclude(exclude::Union{Nothing,AbstractVector{<:AbstractString}})
    if exclude !== nothing
        return collect(String, exclude)
    end
    raw = get(ENV, "ESM_TESTS_EXCLUDE", "")
    isempty(raw) && return String[]
    parts = split(raw, r"[;:]"; keepempty=false)
    return String[String(strip(p)) for p in parts if !isempty(strip(p))]
end

function _is_excluded(path::AbstractString, base::AbstractString,
                     patterns::Vector{String})
    isempty(patterns) && return false
    rel = startswith(path, base) ? relpath(path, base) : path
    for pat in patterns
        (occursin(pat, path) || occursin(pat, rel)) && return true
    end
    return false
end

"""
    discover_esm_files(roots; root=esm_root(), exclude=nothing) -> Vector{String}

Recursively walk each directory in `roots` (relative to `root` if not
absolute) and return all `*.esm` paths in deterministic sorted order. Missing
roots are skipped silently.

`root` is the base directory against which relative `roots` and repo-relative
exclude patterns resolve; it defaults to this package's [`esm_root`](@ref).
Pass it to walk a different repo (e.g. EarthSciModels) — do NOT overwrite
`esm_root()` itself.

`exclude` (or the `ESM_TESTS_EXCLUDE` env var, ";"- or ":"-separated) is a list
of substring patterns; any discovered file whose absolute or root-relative
path contains a pattern is dropped.
"""
function discover_esm_files(roots::AbstractVector{<:AbstractString};
                            root::AbstractString=esm_root(),
                            exclude::Union{Nothing,AbstractVector{<:AbstractString}}=nothing)
    base = String(root)
    patterns = _resolve_exclude(exclude)
    found = String[]
    for r in roots
        dir = isabspath(r) ? r : joinpath(base, r)
        isdir(dir) || continue
        for (root, _dirs, files) in walkdir(dir)
            for f in files
                endswith(f, ".esm") || continue
                full = joinpath(root, f)
                _is_excluded(full, base, patterns) && continue
                push!(found, full)
            end
        end
    end
    sort!(found)
    return found
end

discover_esm_files(; kwargs...) = discover_esm_files(DEFAULT_ROOTS; kwargs...)

# ---------------------------------------------------------------------------
# SHARED §6.6 assertion helpers — used by BOTH this MTK scalar runner and the
# tree-walk PDE runner (pde_inline_tests.jl). The two runners' tolerance
# resolution and pass predicate must stay in lockstep; edit here only.
# ---------------------------------------------------------------------------

const _DEFAULT_REL_TOL = 1.0e-6

# Tight solver tolerances for integrating inline tests, shared between
# `_run_tests_on_compiled` (MTK path) and `run_pde_tests`' keyword defaults
# (tree-walk path): assertion expectations are pinned to many digits, so the
# integration error must sit well below the default rel=1e-6 assertion gate.
const DEFAULT_TEST_RELTOL = 1e-10
const DEFAULT_TEST_ABSTOL = 1e-12

# Returns (rtol, atol) — the most-specific declared tolerance wins (spec
# §6.6.4: assertion > test > model > default rel=1e-6).
function _resolve_tolerance(model_tol, test_tol, assertion_tol)
    for candidate in (assertion_tol, test_tol, model_tol)
        candidate === nothing && continue
        rel = candidate.rel === nothing ? 0.0 : candidate.rel
        atol = candidate.abs === nothing ? 0.0 : candidate.abs
        return (Float64(rel), Float64(atol))
    end
    return (_DEFAULT_REL_TOL, 0.0)
end

# The §6.6.3 pass predicate (exact when no tolerance is declared anywhere).
function _check_assertion(actual::Real, expected::Float64,
                          rtol::Float64, atol::Float64)
    if rtol == 0.0 && atol == 0.0
        return Float64(actual) == expected
    end
    return isapprox(Float64(actual), expected; rtol=rtol, atol=atol)
end

# ---------------------------------------------------------------------------
# Symbol lookup on a compiled MTK system
# ---------------------------------------------------------------------------

# Variable names in flattened ESM systems are dotted ("Sub.x"); the MTK
# extension's `_san` rewrites dots to underscores when constructing symbolic
# names. After mtkcompile, `getproperty(simp, Symbol(name))` returns the
# symbolic handle for either form, prefixed by the wrapper system's name.
#
# Spec §10.7 fully-qualified refs use the form "ModelName.sub.var". MTK
# exposes compiled-system properties by stripping the system's own name
# prefix, so the accessible property for "ModelName.sub.var" is "sub_var"
# (model-relative form), not "ModelName_sub_var".
function _resolve_handle(simp, sys_name::Symbol, var_spec::AbstractString)
    _require_mtk()   # guard only: fail early with a clear error when MTK is absent
    sanitized = replace(String(var_spec), "." => "_")
    qualified = Symbol(String(sys_name) * "_" * sanitized)
    if hasproperty(simp, qualified)
        return getproperty(simp, qualified)
    end
    bare = Symbol(sanitized)
    if hasproperty(simp, bare)
        return getproperty(simp, bare)
    end
    # Model-relative fallback for spec §10.7 fully-qualified refs of the form
    # "ModelName.sub.var": strip the leading "ModelName." prefix and sanitize
    # the remainder to obtain the model-relative flattened name "sub_var".
    # MTK exposes compiled-system properties without the system-name prefix,
    # so this is the correct lookup for subsystem-composed models.
    sys_prefix = String(sys_name) * "."
    if startswith(String(var_spec), sys_prefix)
        relative = String(var_spec)[(length(sys_prefix)+1):end]
        relative_san = Symbol(replace(relative, "." => "_"))
        if hasproperty(simp, relative_san)
            return getproperty(simp, relative_san)
        end
    end
    throw(ArgumentError("Variable '$(var_spec)' not found on compiled system " *
                         "(tried '$(qualified)', '$(bare)', and model-relative form)."))
end

# Lazy module lookup so this file can `include` without a hard dep on MTK
# being loaded at module-init time.
function _require_mtk()
    pkg = Base.PkgId(Base.UUID("961ee093-0014-501f-94e3-6117800e7a78"),
                     "ModelingToolkit")
    mod = get(Base.loaded_modules, pkg, nothing)
    mod === nothing && throw(ArgumentError(
        "run_esm_tests requires ModelingToolkit to be loaded. " *
        "Call `using ModelingToolkit` first."))
    return mod
end

function _try_require(uuid::AbstractString, name::AbstractString)
    pkg = Base.PkgId(Base.UUID(uuid), name)
    return get(Base.loaded_modules, pkg, nothing)
end

# Default per-file stiff-solver override set: .esm basenames listed here are
# integrated with the stiff Rosenbrock23 solver instead of the default
# non-stiff Tsit5. This is a pragmatic library default for known-stiff shared
# fixtures; callers override it per run via `run_esm_tests(...; stiff_files=…)`.
# (Declaring stiffness in the .esm test metadata itself would be the right
# long-term home, but that needs an esm-spec §6.6 change.)
const STIFF_SOLVER_OVERRIDE_FILENAMES = Set(["pollu.esm"])

# Pick a solver: prefer Tsit5 (non-stiff, fast); fall back to Rosenbrock23.
# `stiff_files` is the set of .esm basenames forced onto Rosenbrock23.
function _pick_solver(file::AbstractString="";
                      stiff_files=STIFF_SOLVER_OVERRIDE_FILENAMES)
    rb = _try_require("43230ef6-c299-4910-a778-202eb28ce4ce",
                      "OrdinaryDiffEqRosenbrock")
    if rb !== nothing && basename(file) in stiff_files
        return (rb.Rosenbrock23(), :rosenbrock23)
    end
    tsit = _try_require("b1df2697-797e-41e3-8120-5422d3b24e4a",
                        "OrdinaryDiffEqTsit5")
    tsit !== nothing && return (tsit.Tsit5(), :tsit5)
    rb !== nothing && return (rb.Rosenbrock23(), :rosenbrock23)
    throw(ArgumentError(
        "run_esm_tests requires an OrdinaryDiffEq solver to be loaded " *
        "(`using OrdinaryDiffEqTsit5` or `using OrdinaryDiffEqRosenbrock`)."))
end

# ---------------------------------------------------------------------------
# Per-container test execution
# ---------------------------------------------------------------------------

function _run_tests_on_compiled(file::AbstractString, container_kind::Symbol,
                                container_name::AbstractString,
                                container_tolerance, tests, simp,
                                sys_name::Symbol, results::Vector{AssertionResult};
                                esm_container=nothing,
                                stiff_files=STIFF_SOLVER_OVERRIDE_FILENAMES)
    isempty(tests) && return
    MTK = _require_mtk()
    solver, _solver_kind = _pick_solver(file; stiff_files=stiff_files)

    # For reaction_system containers, species and parameter defaults declared
    # in the ESM file are NOT propagated through the Catalyst.@species /
    # @parameters metadata by the EarthSciSerialization Catalyst extension
    # (the Core.eval path builds bare symbolics). Compensate by seeding u0
    # and p from the ESM defaults here.
    defaults_u0 = Dict{Any,Float64}()
    defaults_p  = Dict{Any,Float64}()
    if container_kind === :reaction_system && esm_container !== nothing
        for sp in esm_container.species
            sp.default === nothing && continue
            handle = try _resolve_handle(simp, sys_name, sp.name) catch; nothing end
            handle === nothing && continue
            defaults_u0[handle] = Float64(sp.default)
        end
        for pr in esm_container.parameters
            pr.default === nothing && continue
            handle = try _resolve_handle(simp, sys_name, pr.name) catch; nothing end
            handle === nothing && continue
            defaults_p[handle] = Float64(pr.default)
        end
    end

    for t in tests
        t_start = time()
        local sol = nothing
        local prob_err::Union{Nothing,Exception} = nothing
        try
            u0_map = copy(defaults_u0)
            for (spec, val) in t.initial_conditions
                handle = _resolve_handle(simp, sys_name, spec)
                u0_map[handle] = Float64(val)
            end
            p_map = copy(defaults_p)
            for (spec, val) in t.parameter_overrides
                handle = _resolve_handle(simp, sys_name, spec)
                p_map[handle] = Float64(val)
            end
            tspan = (t.time_span.start, t.time_span.stop)
            merged = isempty(p_map) ? u0_map : Base.merge(u0_map, p_map)
            prob = if container_kind === :reaction_system
                MTK.ODEProblem(simp, merged, tspan; combinatoric_ratelaws=false)
            else
                MTK.ODEProblem(simp, merged, tspan)
            end
            sol = MTK.SciMLBase.solve(prob, solver;
                                       reltol=DEFAULT_TEST_RELTOL,
                                       abstol=DEFAULT_TEST_ABSTOL)
        catch err
            prob_err = err
        end

        # Evaluate every assertion first, then time the WHOLE test once and
        # give each assertion an even share of it: `write_junit_xml` sums
        # `duration_s` per testcase, so per-assertion cumulative stamps would
        # overcount the test's wall time N-fold.
        outcomes = Tuple{Int,String,Float64,Float64,
                          Union{Float64,Nothing},AssertionStatus,String}[]
        for (i, a) in enumerate(t.assertions)
            if prob_err !== nothing
                push!(outcomes, (i, a.variable, a.time, a.expected, nothing,
                                  ERROR, "Solve setup failed: $(prob_err)"))
                continue
            end

            rtol, atol = _resolve_tolerance(container_tolerance, t.tolerance,
                                             a.tolerance)
            local actual_val::Union{Float64,Nothing} = nothing
            local status::AssertionStatus = FAIL
            local msg::String = ""
            try
                handle = _resolve_handle(simp, sys_name, a.variable)
                raw = sol(a.time, idxs=handle)
                actual_val = Float64(raw)
                if _check_assertion(actual_val, a.expected, rtol, atol)
                    status = PASS
                else
                    msg = "actual=$(actual_val) expected=$(a.expected) " *
                          "(rtol=$(rtol), atol=$(atol))"
                end
            catch err
                status = ERROR
                msg = "Sample/compare failed: $(err)"
            end

            push!(outcomes, (i, a.variable, a.time, a.expected, actual_val,
                              status, msg))
        end

        duration_share = (time() - t_start) / max(length(outcomes), 1)
        for (i, var, at, expected, actual_val, status, msg) in outcomes
            push!(results, AssertionResult(
                file, container_kind, String(container_name), t.id, i,
                var, at, expected, actual_val, status, msg, duration_share))
        end
    end
end

function _compile_model(model, name::Symbol)
    MTK = _require_mtk()
    sys = MTK.System(model; name=name)
    return MTK.mtkcompile(sys)
end

function _compile_reaction_system(rs, name::Symbol)
    MTK = _require_mtk()
    cat = _try_require("479239e8-5488-4da2-87a7-35f2df7eef83", "Catalyst")
    cat === nothing && throw(ArgumentError(
        "ReactionSystem inline tests require Catalyst to be loaded."))
    catalyst_rs = cat.ReactionSystem(rs; name=name)
    return MTK.complete(catalyst_rs)
end

# ---------------------------------------------------------------------------
# Per-file driver
# ---------------------------------------------------------------------------

function run_file_tests!(results::Vector{AssertionResult}, path::AbstractString;
                         stiff_files=STIFF_SOLVER_OVERRIDE_FILENAMES)
    local esm_file
    try
        esm_file = load(String(path))
    catch err
        push!(results, AssertionResult(
            path, :file, "<parse>", "<load>", 0, "", NaN, NaN, nothing,
            ERROR, "Parse failed: $(err)", 0.0))
        return
    end

    if esm_file.models !== nothing
        for (mname, model) in esm_file.models
            isempty(model.tests) && continue
            sys_name = Symbol(mname)
            local simp
            try
                simp = _compile_model(model, sys_name)
            catch err
                for t in model.tests
                    push!(results, AssertionResult(
                        path, :model, String(mname), t.id, 0, "", NaN, NaN,
                        nothing, ERROR, "Model compile failed: $(err)", 0.0))
                end
                continue
            end
            _run_tests_on_compiled(path, :model, String(mname),
                                    model.tolerance, model.tests, simp,
                                    sys_name, results; stiff_files=stiff_files)
        end
    end

    if esm_file.reaction_systems !== nothing
        for (rname, rs) in esm_file.reaction_systems
            isempty(rs.tests) && continue
            sys_name = Symbol(rname)
            local simp
            try
                simp = _compile_reaction_system(rs, sys_name)
            catch err
                for t in rs.tests
                    push!(results, AssertionResult(
                        path, :reaction_system, String(rname), t.id, 0, "",
                        NaN, NaN, nothing, ERROR,
                        "ReactionSystem compile failed: $(err)", 0.0))
                end
                continue
            end
            _run_tests_on_compiled(path, :reaction_system, String(rname),
                                    rs.tolerance, rs.tests, simp, sys_name,
                                    results; esm_container=rs,
                                    stiff_files=stiff_files)
        end
    end
end

# ---------------------------------------------------------------------------
# Top-level
# ---------------------------------------------------------------------------

"""
    run_esm_tests(roots=DEFAULT_ROOTS; root=esm_root(), junit_xml=nothing,
                  verbose=true, exclude=nothing,
                  stiff_files=STIFF_SOLVER_OVERRIDE_FILENAMES,
                  io::IO=stdout) -> (results, exit_code)

Walk each directory in `roots`, run every inline test in every `.esm` file,
and return `(results::Vector{AssertionResult}, exit_code::Int)` where
`exit_code == 0` iff every assertion passed.

`root` is the base directory against which relative `roots` (and exclude
patterns) resolve — pass it to walk a different repo instead of overwriting
`esm_root()`. Discovery finding zero files logs a `@warn` (a mis-rooted
invocation must not silently pass).

Prints a per-file summary table to `io` when `verbose=true`. When
`junit_xml` is a path, emits a junit-compatible XML report there.

`exclude` (or the `ESM_TESTS_EXCLUDE` env var) drops any `.esm` file whose
path contains one of the listed substrings.

`stiff_files` is a set/vector of `.esm` basenames to integrate with the stiff
Rosenbrock23 solver instead of the default non-stiff Tsit5; it defaults to
`STIFF_SOLVER_OVERRIDE_FILENAMES` (currently just the known-stiff `pollu.esm`).
"""
function run_esm_tests(roots::AbstractVector{<:AbstractString}=DEFAULT_ROOTS;
                       root::AbstractString=esm_root(),
                       junit_xml::Union{AbstractString,Nothing}=nothing,
                       verbose::Bool=true,
                       exclude::Union{Nothing,AbstractVector{<:AbstractString}}=nothing,
                       stiff_files=STIFF_SOLVER_OVERRIDE_FILENAMES,
                       io::IO=stdout)
    files = discover_esm_files(roots; root=root, exclude=exclude)
    results = AssertionResult[]
    if isempty(files)
        @warn "run_esm_tests discovered no .esm files" roots root
        verbose && println(io, "No .esm files discovered under: ",
                            join(roots, ", "))
    else
        for f in files
            run_file_tests!(results, f; stiff_files=stiff_files)
        end
    end

    verbose && _print_summary(io, files, results, String(root))
    junit_xml !== nothing && write_junit_xml(results, String(junit_xml))

    n_fail = count(r -> r.status == FAIL || r.status == ERROR, results)
    exit_code = n_fail == 0 ? 0 : 1
    return results, exit_code
end

run_esm_tests(roots::AbstractString...; kwargs...) =
    run_esm_tests(collect(String, roots); kwargs...)

function _print_summary(io::IO, files::Vector{String},
                        results::Vector{AssertionResult},
                        base::AbstractString=esm_root())
    rel(p) = startswith(p, base) ? relpath(p, base) : p

    println(io)
    println(io, "================ ESM inline-test summary ================")
    println(io, "Files discovered: ", length(files))
    println(io, "Assertions:       ", length(results))

    by_file = Dict{String,Vector{AssertionResult}}()
    for r in results
        push!(get!(by_file, r.file, AssertionResult[]), r)
    end

    if isempty(results)
        println(io, "(no inline tests found)")
        println(io, "=========================================================")
        return
    end

    namepad = max(20, maximum(length(rel(p)) for p in keys(by_file); init=20))
    @printf(io, "  %-*s  %5s  %5s  %5s\n", namepad, "file", "pass", "fail", "err")
    println(io, "  ", repeat("-", namepad + 25))
    for f in sort!(collect(keys(by_file)))
        rows = by_file[f]
        np = count(r -> r.status == PASS, rows)
        nf = count(r -> r.status == FAIL, rows)
        ne = count(r -> r.status == ERROR, rows)
        @printf(io, "  %-*s  %5d  %5d  %5d\n", namepad, rel(f), np, nf, ne)
    end
    println(io, "  ", repeat("-", namepad + 25))

    total_pass = count(r -> r.status == PASS, results)
    total_fail = count(r -> r.status == FAIL, results)
    total_err = count(r -> r.status == ERROR, results)
    @printf(io, "  %-*s  %5d  %5d  %5d\n", namepad, "TOTAL", total_pass,
             total_fail, total_err)

    if total_fail + total_err > 0
        println(io)
        println(io, "Failures:")
        for r in results
            (r.status == PASS) && continue
            println(io, "  - ", rel(r.file), " :: ", r.container_name, "/",
                     r.test_id, "[", r.assertion_idx, "] (",
                     r.variable, "@t=", r.time, ") — ",
                     r.status == ERROR ? "ERROR" : "FAIL")
            isempty(r.message) || println(io, "      ", r.message)
        end
    end
    println(io, "=========================================================")
end

# ---------------------------------------------------------------------------
# JUnit XML emission
# ---------------------------------------------------------------------------

function _xml_escape(s::AbstractString)
    s = replace(String(s), '&' => "&amp;")
    s = replace(s, '<' => "&lt;")
    s = replace(s, '>' => "&gt;")
    s = replace(s, '"' => "&quot;")
    return s
end

"""
    write_junit_xml(results, path)

Emit a junit-compatible XML report covering every `AssertionResult`.

Each unique `(file, container, test_id)` becomes a `<testcase>`; one or more
failing assertions inside it produce `<failure>` / `<error>` children. The
testcase `time` attribute is the sum of its assertions' `duration_s` — each
assertion carries an even share of its test's wall time, so the sum is the
test's duration (no N-fold overcount).
"""
function write_junit_xml(results::Vector{AssertionResult}, path::AbstractString)
    by_test = Dict{Tuple{String,String,String},Vector{AssertionResult}}()
    order = Tuple{String,String,String}[]
    for r in results
        key = (r.file, r.container_name, r.test_id)
        if !haskey(by_test, key)
            push!(order, key)
            by_test[key] = AssertionResult[]
        end
        push!(by_test[key], r)
    end

    n_tests = length(order)
    n_fail = sum(any(r -> r.status == FAIL, rs) for rs in values(by_test); init=0)
    n_err = sum(any(r -> r.status == ERROR, rs) for rs in values(by_test); init=0)

    open(path, "w") do io
        println(io, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
        println(io, "<testsuites tests=\"", n_tests,
                 "\" failures=\"", n_fail,
                 "\" errors=\"", n_err, "\">")
        println(io, "  <testsuite name=\"esm-inline-tests\" tests=\"",
                 n_tests, "\" failures=\"", n_fail,
                 "\" errors=\"", n_err, "\">")
        for key in order
            file, container, test_id = key
            rs = by_test[key]
            classname = _xml_escape(string(file, "::", container))
            casename = _xml_escape(test_id)
            duration = sum(r.duration_s for r in rs; init=0.0)
            println(io, "    <testcase classname=\"", classname,
                     "\" name=\"", casename,
                     "\" time=\"", duration, "\">")
            for r in rs
                if r.status == FAIL
                    println(io, "      <failure type=\"AssertionFailure\" ",
                             "message=\"", _xml_escape(r.message), "\">",
                             _xml_escape(string(r.variable, "@t=", r.time,
                                                 " expected=", r.expected,
                                                 " actual=", r.actual)),
                             "</failure>")
                elseif r.status == ERROR
                    println(io, "      <error type=\"RunnerError\" ",
                             "message=\"", _xml_escape(r.message), "\"/>")
                end
            end
            println(io, "    </testcase>")
        end
        println(io, "  </testsuite>")
        println(io, "</testsuites>")
    end
    return path
end
