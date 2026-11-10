# Template versus closed form, Julia native side (closed-AST phase 3).
#
# For each workload pair written by generate.py (in DIR, or, with no DIR or
# `-`, generated at the default sizes into $CLOSED_TEMPLATES_DIR, else
# closed_templates under $TMPDIR):
#
#   solar_year_{fn,tpl}_H<h>        datetime.* fn calls vs lib/calendar.esm
#   regrid_<m>_{leaf,tpl}_N<n>      polygon_intersection_area vs lib/geometry.esm
#   nearest_{op,tpl}_P<p>_G<g>      argmin vs lib/relational.esm
#
# it reports the build time (first build, which includes Julia compilation, and
# a second build of the same document), the first right-hand-side call, and the
# median steady call (the time moved every call), and checks the template's
# derivative against the interpreter's bit for bit (and, for the calendar and
# argmin, against the closed form's; the geometry leaf is GeometryOps, so its
# areas are compared only by their largest difference).
#
# Usage (an environment with EarthSciAST, JSON3 and GeometryOps):
#
#     julia --project=<env> bench/closed_templates/bench_julia.jl [DIR|-] [name-filter…]
#
# Environment: CALLS (default 200), INTERP_CHECK (default 1: run the interpreter oracle;
# the interpreter unrolls the argmin template's nested reductions per cell, so
# at P500 x G100 it needs tens of GB: check it at a smaller size).

using EarthSciAST, JSON3, Statistics, Printf
import GeometryOps

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
    # A state that differs from cell to cell, the same per name in every
    # spelling, so a regrid's derivative depends on every weight.
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
maxdiff(a, b) = maximum(maximum(abs.(a[k] .- b[k])) for k in keys(a))

pairs = [
    (r"^solar_year_fn_(H\d+)\.esm$", "fn", "tpl", "solar_year_tpl_"),
    (r"^regrid_(\w+?)_leaf_(N\d+)\.esm$", "leaf", "tpl", ""),
    (r"^nearest_op_(P\d+_G\d+)\.esm$", "op", "tpl", "nearest_tpl_"),
]

for f in sort(readdir(DIR))
    for (re, cf, _, _) in pairs
        m = match(re, f)
        m === nothing && continue
        isempty(FILTERS) || any(occursin(x, f) for x in FILTERS) || continue
        tf = replace(f, "_$(cf)_" => "_tpl_")
        isfile(joinpath(DIR, tf)) || continue
        rows = Dict{String, Any}()
        ok = true
        for (lab, file) in ((cf, f), ("tpl", tf))
            path = joinpath(DIR, file)
            b1 = try
                build(path, :native)
            catch err
                @printf("%-34s %-4s FAILED to build: %s\n", file, lab, first(sprint(showerror, err), 400))
                ok = false
                break
            end
            b2 = build(path, :native)
            f!, u0, p, vm, tb, tally = b2
            fc = first_call(f!, u0, p)
            st = steady(f!, u0, p)
            rows[lab] = (b1[5], tb, fc, st, dus(f!, u0, p, vm), tally, length(u0))
            @printf(
                "%-34s %-4s states %7d  build %8.3fs (first %8.3fs)  first call %10.6fs  call %12.3f us\n",
                file, lab, length(u0), tb, b1[5], fc, st * 1.0e6
            )
            if lab == "tpl"
                @printf("    tally: %s\n", join(("$k=$v" for (k, v) in sort(collect(tally); by = first)), " "))
            end
        end
        ok || continue
        dt, dc = rows["tpl"][5], rows[cf][5]
        if cf == "leaf"
            @printf("    template vs leaf derivative: max |diff| %.3e\n", maxdiff(dt, dc))
        else
            @printf("    template vs %s derivative bit-identical: %s\n", cf, same(dt, dc))
        end
        if INTERP_CHECK
            fi, ui, pi_, vmi, _, _ = build(joinpath(DIR, tf), :interpreter)
            di = dus(fi, ui, pi_, vmi)
            @printf("    template native vs interpreter bit-identical: %s\n", same(dt, di))
        end
        @printf("    ratio template/%s: build %.2f  call %.2f\n", cf, rows["tpl"][2] / rows[cf][2], rows["tpl"][4] / rows[cf][4])
        flush(stdout)
    end
end
