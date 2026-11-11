# Closed-AST templates, Julia native side.
#
# For each template workload written by generate.py (in DIR, or, with no DIR or
# `-`, generated at the default sizes into $CLOSED_TEMPLATES_DIR, else
# closed_templates under $TMPDIR):
#
#   solar_year_tpl_H<h>        the lib/calendar.esm templates
#   regrid_<m>_tpl_N<n>        the lib/geometry.esm overlap-area templates
#   nearest_tpl_P<p>_G<g>      the lib/relational.esm argmin template
#
# it reports the build time (first build, which includes Julia compilation, and
# a second build of the same document), the first right-hand-side call, and the
# median steady call (the time moved every call), and checks the native
# derivative against the interpreter's bit for bit.
#
# Usage (an environment with EarthSciAST and JSON3):
#
#     julia --project=<env> bench/closed_templates/bench_julia.jl [DIR|-] [name-filter…]
#
# Environment: CALLS (default 200), INTERP_CHECK (default 1: run the interpreter oracle;
# the interpreter unrolls the argmin template's nested reductions per cell, so
# at P500 x G100 it needs tens of GB: check it at a smaller size).

using EarthSciAST, JSON3, Statistics, Printf

const E = EarthSciAST
include(joinpath(@__DIR__, "docs.jl"))
const DIR = bench_docs(
    "generate.py", isempty(ARGS) || ARGS[1] == "-" ? nothing : ARGS[1],
    ["--only", "solar", "--only", "regrid", "--only", "nearest"];
    env = "CLOSED_TEMPLATES_DIR", name = "closed_templates", prefix = ""
)
const FILTERS = length(ARGS) > 1 ? ARGS[2:end] : String[]
const CALLS = parse(Int, get(ENV, "CALLS", "200"))
const INTERP_CHECK = get(ENV, "INTERP_CHECK", "1") == "1"
const TIMES = (0.0, 0.7, 3.1, 1800.0)

function build(path, compiler)
    E._reset_cascade_tally!()
    GC.gc()
    t0 = time_ns()
    prob = E.esm_problem(path, (0.0, 1.0); compiler = compiler)
    dt = (time_ns() - t0) / 1.0e9
    # A state that differs from cell to cell, so a regrid's derivative depends
    # on every weight.
    u = copy(prob.u0)
    for (r, k) in enumerate(sort!(collect(keys(prob.var_map))))
        u[prob.var_map[k]] += r / 64
    end
    return (prob.f!, u, prob.p, prob.var_map, dt, copy(E._CASCADE_TALLY))
end

function first_call(f!, u0, p)
    du = similar(u0)
    t0 = time_ns()
    f!(du, u0, p, 0.0)
    return (time_ns() - t0) / 1.0e9
end

function steady(f!, u0, p)
    du = similar(u0)
    f!(du, u0, p, 0.1)
    ts = Vector{Float64}(undef, 7)
    for r in eachindex(ts)
        t0 = time_ns()
        for i in 1:CALLS
            f!(du, u0, p, 1.0e-3 * i)
        end
        ts[r] = (time_ns() - t0) / CALLS
    end
    return median(ts) / 1.0e9
end

function dus(f!, u0, p, vm)
    out = Dict{String, Vector{Float64}}()
    for t in TIMES
        du = similar(u0); fill!(du, NaN)
        f!(du, u0, p, t)
        for (k, v) in vm
            push!(get!(() -> Float64[], out, k), du[v])
        end
    end
    return out
end

same(a, b) = keys(a) == keys(b) && all(all(a[k] .=== b[k]) for k in keys(a))

const TEMPLATE_DOCS = (r"^solar_year_tpl_H\d+\.esm$", r"^regrid_\w+?_tpl_N\d+\.esm$", r"^nearest_tpl_P\d+_G\d+\.esm$")

for f in sort(readdir(DIR))
    any(re -> match(re, f) !== nothing, TEMPLATE_DOCS) || continue
    isempty(FILTERS) || any(occursin(x, f) for x in FILTERS) || continue
    path = joinpath(DIR, f)
    b1 = try
        build(path, :native)
    catch err
        @printf("%-34s FAILED to build: %s\n", f, first(sprint(showerror, err), 400))
        continue
    end
    f!, u0, p, vm, tb, tally = build(path, :native)
    fc = first_call(f!, u0, p)
    st = steady(f!, u0, p)
    @printf(
        "%-34s states %7d  build %8.3fs (first %8.3fs)  first call %10.6fs  call %12.3f us\n",
        f, length(u0), tb, b1[5], fc, st * 1.0e6
    )
    @printf("    tally: %s\n", join(("$k=$v" for (k, v) in sort(collect(tally); by = first)), " "))
    if INTERP_CHECK
        dt = dus(f!, u0, p, vm)
        fi, ui, pi_, vmi, _, _ = build(path, :interpreter)
        di = dus(fi, ui, pi_, vmi)
        @printf("    native vs interpreter bit-identical: %s\n", same(dt, di))
    end
    flush(stdout)
end
