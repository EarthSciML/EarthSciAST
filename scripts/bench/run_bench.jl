#!/usr/bin/env julia
# Phase-0 bench harness for the perf-gap-closure plan: one command that, per
# fixture, records build wall time, the compile-once tier counters
# (_BENCH_BODY_VARIANTS / _BENCH_COMPILE_CALLS), warm RHS time + allocations at
# Float64 AND ForwardDiff.Dual eltype, and peak RSS — printed as a table and
# written as JSON. A hand-written monotone-PPM reference kernel provides the
# denominator for the "within 2-3x of hand-written" runtime gate.
#
# Usage (from the repo root):
#   julia --project=pkg/EarthSciAST.jl scripts/bench/run_bench.jl [options]
#
# Options:
#   --full           also run the 7x7x72 analytic-winds transport fixture
#                    (~25 min build on current main; excluded by default)
#   --compare        diff against scripts/bench/baseline.json and exit nonzero
#                    on any >10% regression
#   --baseline=PATH  compare against PATH instead of the committed baseline
#   --json=PATH      write results JSON to PATH (default scripts/bench/results.json)
#   --only=a,b,...   run only the named fixtures (proxy27, t3d_7x7x7, t3d_7x7x72,
#                    ref_kernel)
#
# Environment:
#   RESEACT_ROOT  reseact.esm checkout (default: the real sibling path)
#   ESD_ROOT      EarthSciDiscretizations checkout (default: sibling of RESEACT_ROOT)

const BENCH_DIR = @__DIR__
const REPO_ROOT = normpath(joinpath(BENCH_DIR, "..", ".."))

# ---------------------------------------------------------------------------- #
# Stacked bench environment: BenchmarkTools/ForwardDiff are test-only deps of
# the package, so they are not in the pkg/EarthSciAST.jl project. scripts/bench
# carries its own Project.toml; instantiate it on first use and stack it onto
# LOAD_PATH so `using BenchmarkTools` resolves without touching the pkg env.
# ---------------------------------------------------------------------------- #
import Pkg
if !isfile(joinpath(BENCH_DIR, "Manifest.toml"))
    prev = Base.active_project()
    Pkg.activate(BENCH_DIR; io = devnull)
    Pkg.instantiate()
    Pkg.activate(prev; io = devnull)
end
BENCH_DIR in LOAD_PATH || push!(LOAD_PATH, BENCH_DIR)

using EarthSciAST
using JSON3, Printf, Dates
using BenchmarkTools, ForwardDiff
const EA = EarthSciAST

include(joinpath(BENCH_DIR, "ref_kernel.jl"))

# ---------------------------------------------------------------------------- #
# CLI
# ---------------------------------------------------------------------------- #
struct Opts
    full::Bool
    compare::Bool
    baseline::String
    json::String
    only::Union{Nothing,Set{String}}
end
function parse_opts(args)
    full = false; compare = false
    baseline = joinpath(BENCH_DIR, "baseline.json")
    jsonout = joinpath(BENCH_DIR, "results.json")
    only = nothing
    for a in args
        if a == "--full"; full = true
        elseif a == "--compare"; compare = true
        elseif startswith(a, "--baseline="); baseline = split(a, "="; limit = 2)[2]
        elseif startswith(a, "--json="); jsonout = split(a, "="; limit = 2)[2]
        elseif startswith(a, "--only="); only = Set(split(split(a, "="; limit = 2)[2], ","))
        else; error("unknown option $a (see header of run_bench.jl)")
        end
    end
    Opts(full, compare, String(baseline), String(jsonout), only)
end

const RESEACT_ROOT = get(ENV, "RESEACT_ROOT",
    "/projects/illinois/eng/cee/ctessum/ctessum/code/reseact.esm")
const ESD_ROOT = get(ENV, "ESD_ROOT",
    normpath(joinpath(RESEACT_ROOT, "..", "EarthSciDiscretizations")))

# ---------------------------------------------------------------------------- #
# Measurement helpers
# ---------------------------------------------------------------------------- #

"Peak RSS (VmHWM) in MiB from /proc/self/status; NaN when unavailable."
function peak_rss_mb()
    try
        for l in eachline("/proc/self/status")
            startswith(l, "VmHWM") || continue
            return parse(Float64, split(l)[2]) / 1024   # kB -> MiB
        end
    catch
    end
    return NaN
end

"build_evaluator with the compile-once tier counters on; returns result + stats."
function timed_build(doc; kwargs...)
    GC.gc()
    EA._BENCH_ON[] = true
    EA._bench_reset!()
    t0 = time()
    built = EA.build_evaluator(doc; kwargs...)
    build_s = time() - t0
    stats = (build_s = build_s,
             body_variants = EA._BENCH_BODY_VARIANTS[],
             compile_calls = EA._BENCH_COMPILE_CALLS[])
    EA._BENCH_ON[] = false
    return built, stats
end

"Warm in-place RHS timing + allocs at Float64 and at ForwardDiff.Dual eltype."
function bench_rhs(f!, u0, p, t)
    du = similar(u0)
    f!(du, u0, p, t)                      # warm (JIT) before measuring
    t_f64 = @belapsed $f!($du, $u0, $p, $t) seconds = 3
    allocs_f64 = @allocated f!(du, u0, p, t)

    # Dual through the SAME in-place evaluator (the tree-walk RHS is generic in
    # its value type; see test/tree_walk_iip_generic_test.jl). One partial is
    # enough to exercise the Dual arithmetic path.
    DT = ForwardDiff.Dual{Nothing,Float64,1}
    uD = DT.(u0)
    duD = similar(uD)
    f!(duD, uD, p, t)
    t_dual = @belapsed $f!($duD, $uD, $p, $t) seconds = 3
    allocs_dual = @allocated f!(duD, uD, p, t)

    return (rhs_f64_s = t_f64, rhs_f64_allocs = Int(allocs_f64),
            rhs_dual_s = t_dual, rhs_dual_allocs = Int(allocs_dual))
end

# ---------------------------------------------------------------------------- #
# Fixture preparation
# ---------------------------------------------------------------------------- #

# The generated transport fixtures import EarthSciDiscretizations rules by the
# same ../../../EarthSciDiscretizations relative ref the prototypes use, so they
# are staged exactly three directory levels below a directory holding a symlink
# to the real ESD checkout. Rules are loaded from the live checkout, not copied.
function _stage_dir()
    tmp = mktempdir(; prefix = "esm_bench_")
    symlink(ESD_ROOT, joinpath(tmp, "EarthSciDiscretizations"))
    d = joinpath(tmp, "fixtures", "gen", "t3d")
    mkpath(d)
    return d
end

function _generate_t3d(nlev::Int)
    out = joinpath(_stage_dir(), "transport_3d_bench_$(nlev).esm")
    cmd = String["python3", joinpath(BENCH_DIR, "gen_transport_fixture.py"),
                 ESD_ROOT, out, string(nlev)]
    nlev == 7 ||
        push!(cmd, joinpath(RESEACT_ROOT, "prototypes", "reseact_3d", "hybrid_coefs.json"))
    run(Cmd(cmd))
    co = JSON3.read(read(out * ".hybrid_coefs.json", String))
    ca = Dict{String,Any}("dA" => Float64.(co.dA), "dB" => Float64.(co.dB))
    return out, ca
end

# The committed prototype artifact is usable only when its regional-inflow D
# call sites carry the operand count the on-disk ESD rules expect (the contract
# changed in ESD e358325, "promote qbc_* to a rule param"; reseact.esm 0fc02f4
# regenerated the artifact for the new arity). Checked structurally, offline.
function _committed_t3d_compatible(esm_path::String)
    try
        return _committed_t3d_compatible_impl(esm_path)
    catch err
        return false, "compatibility probe failed: $(sprint(showerror, err))"
    end
end
function _committed_t3d_compatible_impl(esm_path::String)
    isfile(esm_path) || return false, "missing $(esm_path)"
    rule = joinpath(ESD_ROOT, "grids", "latlon3d", "rules", "ppm_flux_D_lon_mono_inflow_bc.esm")
    isfile(rule) || return false, "missing $(rule)"
    doc = JSON3.read(read(esm_path, String))
    tpl = JSON3.read(read(rule, String))
    nparams = length(first(values(tpl.expression_templates)).params)  # [q, U, (qbc_w, qbc_e)]
    want_dargs = nparams - 1                                          # D operands = params minus U
    # The tracer-advection inflow sites are the D-lon nodes with the WIDEST
    # operand list (the mass equation's D(Mx) is always 1-operand and is matched
    # by facediv, not the inflow PPM rule).
    m = first(values(doc.models))
    nmax = 0
    for eq in m.equations, node in (eq.lhs.op == "D" ? eq.rhs.args[1].args : ())
        (node isa JSON3.Object && get(node, :op, "") == "D" &&
         get(node, :wrt, "") == "lon") || continue
        nmax = max(nmax, length(node.args))
    end
    nmax == 0 && return false, "no D-lon site found in $(esm_path)"
    nmax == want_dargs && return true, ""
    return false, "committed artifact has $(nmax)-operand D-lon inflow sites, " *
                  "on-disk ESD rules expect $(want_dargs) (contract skew across ESD e358325)"
end

function prepare_t3d(nlev::Int)
    if nlev == 7
        committed = joinpath(RESEACT_ROOT, "prototypes", "transport_3d", "transport_3d.esm")
        ok, why = _committed_t3d_compatible(committed)
        if ok
            # dA/dB for the committed 7-level fixture: regenerate the coef table
            # only (same hybrid edges gen_t3d.py hardcodes).
            _, ca = _generate_t3d(7)
            return committed, ca, "committed"
        end
        @info "t3d_7x7x7: regenerating from the on-disk ESD exemplar" reason = why
        out, ca = _generate_t3d(7)
        return out, ca, "regenerated"
    end
    out, ca = _generate_t3d(nlev)
    return out, ca, "regenerated"
end

# ---------------------------------------------------------------------------- #
# Fixture runners: each returns a Dict of recorded metrics
# ---------------------------------------------------------------------------- #

function run_esm_fixture(name, esm_path; const_arrays = Dict{String,Any}(),
                         warm_rebuild::Bool = false, source = "committed")
    println("== fixture $name ==")
    println("   esm: $esm_path")
    flush(stdout)
    t0 = time()
    doc = EA.load(esm_path)
    load_s = time() - t0
    built, b1 = timed_build(doc; const_arrays)
    f!, u0, p, tspan, _ = built
    @printf("   build: %.2f s   body_variants=%d compile_calls=%d   nstates=%d\n",
            b1.build_s, b1.body_variants, b1.compile_calls, length(u0))
    flush(stdout)
    r = Dict{String,Any}(
        "esm" => esm_path, "source" => source, "nstates" => length(u0),
        "load_s" => load_s, "build_s" => b1.build_s,
        "body_variants" => b1.body_variants, "compile_calls" => b1.compile_calls)
    if warm_rebuild
        # Second in-session build: the build machinery is JIT-compiled now, so
        # this is the number comparable across engine changes (and the one the
        # 08c4985b commit message quotes for the 27-box proxy).
        _, b2 = timed_build(doc; const_arrays)
        r["build_warm_s"] = b2.build_s
        @printf("   build (warm rebuild): %.4f s\n", b2.build_s)
    end
    rhs = bench_rhs(f!, u0, p, tspan[1])
    @printf("   rhs f64:  %.6g s/call  %d B/call\n", rhs.rhs_f64_s, rhs.rhs_f64_allocs)
    @printf("   rhs dual: %.6g s/call  %d B/call\n", rhs.rhs_dual_s, rhs.rhs_dual_allocs)
    for (k, v) in pairs(rhs); r[String(k)] = v; end
    r["peak_rss_mb"] = peak_rss_mb()
    @printf("   peak RSS: %.0f MiB (process high-water mark)\n", r["peak_rss_mb"])
    flush(stdout)
    return r
end

function run_ref_kernel(; nlon = 7, nlat = 7, nlev = 72)
    println("== reference kernel (hand-written monotone-PPM lon sweep, $(nlon)x$(nlat)x$(nlev)) ==")
    s = BenchRefKernel.setup(nlon, nlat, nlev)
    t_sweep = @belapsed BenchRefKernel.ppm_lon_sweep!($(s.du), $(s.q), $(s.U), $(s.w), $(s.ws)) seconds = 3
    allocs = @allocated BenchRefKernel.ppm_lon_sweep!(s.du, s.q, s.U, s.w, s.ws)
    ncells = nlon * nlat * nlev
    r = Dict{String,Any}(
        "grid" => "$(nlon)x$(nlat)x$(nlev)", "ncells" => ncells,
        "sweep_s" => t_sweep, "sweep_allocs" => Int(allocs),
        # per-RHS-equivalent: 3 axes x 3 advected fields (m/mq/dev structure)
        "rhs_equiv_s" => 9 * t_sweep, "rhs_equiv_convention" => "9 x lon sweep (3 axes x 3 fields)")
    @printf("   sweep: %.6g s (%d cells, %d B)   per-RHS-equivalent (x9): %.6g s\n",
            t_sweep, ncells, allocs, r["rhs_equiv_s"])
    return r
end

# ---------------------------------------------------------------------------- #
# Baseline comparison: >10% regression on any tracked metric fails the run.
# ---------------------------------------------------------------------------- #
const COMPARE_METRICS = ["build_s", "build_warm_s", "rhs_f64_s", "rhs_dual_s",
                         "rhs_f64_allocs", "rhs_dual_allocs",
                         "body_variants", "compile_calls", "sweep_s", "rhs_equiv_s"]

function compare_results(results, baseline_path)
    isfile(baseline_path) || error("baseline not found: $baseline_path")
    base = JSON3.read(read(baseline_path, String))
    fails = String[]
    for (fname, cur) in results
        haskey(base.fixtures, Symbol(fname)) || continue
        b = base.fixtures[Symbol(fname)]
        for m in COMPARE_METRICS
            (haskey(cur, m) && haskey(b, Symbol(m))) || continue
            bv = Float64(b[Symbol(m)]); cv = Float64(cur[m])
            bv > 0 || continue
            ratio = cv / bv
            if ratio > 1.10
                push!(fails, @sprintf("%s.%s: %.6g -> %.6g (%.0f%% regression)",
                                      fname, m, bv, cv, (ratio - 1) * 100))
            end
        end
        if haskey(b, :source) && haskey(cur, "source") && String(b.source) != cur["source"]
            @warn "fixture $fname source changed ($(b.source) -> $(cur["source"])); timings may not be comparable"
        end
    end
    return fails
end

# ---------------------------------------------------------------------------- #
# Main
# ---------------------------------------------------------------------------- #
function main(args)
    opts = parse_opts(args)
    torun(n) = opts.only === nothing || n in opts.only

    results = Dict{String,Any}()

    if torun("proxy27")
        results["proxy27"] = run_esm_fixture("proxy27",
            joinpath(BENCH_DIR, "fixtures", "proxy27.esm"); warm_rebuild = true,
            source = "committed")
    end
    if torun("t3d_7x7x7")
        path, ca, source = prepare_t3d(7)
        results["t3d_7x7x7"] = run_esm_fixture("t3d_7x7x7", path;
            const_arrays = ca, source = source)
    end
    if opts.full && torun("t3d_7x7x72")
        path, ca, source = prepare_t3d(72)
        results["t3d_7x7x72"] = run_esm_fixture("t3d_7x7x72", path;
            const_arrays = ca, source = source)
    end
    if torun("ref_kernel")
        results["ref_kernel"] = run_ref_kernel()
    end

    # ---- table ----
    println()
    @printf("%-12s %10s %10s %8s %8s %12s %10s %12s %10s %9s\n",
            "fixture", "nstates", "build[s]", "bodyvar", "compile",
            "rhs f64[s]", "allocs[B]", "rhs dual[s]", "allocs[B]", "RSS[MiB]")
    for name in ["proxy27", "t3d_7x7x7", "t3d_7x7x72"]
        haskey(results, name) || continue
        r = results[name]
        @printf("%-12s %10d %10.2f %8d %8d %12.3g %10d %12.3g %10d %9.0f\n",
                name, r["nstates"], r["build_s"], r["body_variants"], r["compile_calls"],
                r["rhs_f64_s"], r["rhs_f64_allocs"], r["rhs_dual_s"], r["rhs_dual_allocs"],
                r["peak_rss_mb"])
    end
    if haskey(results, "ref_kernel")
        r = results["ref_kernel"]
        @printf("%-12s %10s %10s %8s %8s %12.3g %10d %12s %10s %9s\n",
                "ref_kernel", r["grid"], "-", "-", "-",
                r["rhs_equiv_s"], r["sweep_allocs"], "-", "-", "-")
        for t in ["t3d_7x7x7", "t3d_7x7x72"]
            haskey(results, t) &&
                @printf("   %s rhs f64 / ref rhs-equiv = %.1fx\n",
                        t, results[t]["rhs_f64_s"] / r["rhs_equiv_s"])
        end
    end

    # ---- JSON ----
    out = Dict{String,Any}(
        "meta" => Dict{String,Any}(
            "timestamp" => string(now()),
            "julia" => string(VERSION),
            "hostname" => gethostname(),
            "commit" => try readchomp(`git -C $REPO_ROOT rev-parse --short HEAD`) catch; "unknown" end,
            "reseact_root" => RESEACT_ROOT, "esd_root" => ESD_ROOT),
        "fixtures" => results)
    open(opts.json, "w") do io
        JSON3.pretty(io, out)
    end
    println("\nwrote $(opts.json)")

    # ---- compare ----
    if opts.compare
        fails = compare_results(results, opts.baseline)
        if isempty(fails)
            println("compare vs $(opts.baseline): OK (no metric regressed >10%)")
        else
            println("compare vs $(opts.baseline): REGRESSIONS")
            foreach(f -> println("  FAIL ", f), fails)
            exit(1)
        end
    end
    return results
end

main(ARGS)
