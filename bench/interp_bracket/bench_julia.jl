# The interpolation-bracket A/B (#588), Julia native side.
#
# Spellings, per N (the documents beside this file, written by generate.py):
#
#   fn        interp_bracket_const_fn_N<n>       the hand-written interp.linear form
#   unfused   interp_bracket_const_compose_N<n>  the composition, count rewrite off
#   fused     interp_bracket_const_compose_N<n>  the composition, count rewrite on
#   rt_unfused / rt_fused                        the run-time-axis composition,
#             interp_bracket_runtime_compose_N<n> rewrite off / on
#
# For each it times one right-hand-side call (median of many, the query moved
# every call so no time-cadence slot is reused) and a Tsit5 solve over
# [0, TEND] s, interleaving the spellings within each repeat, and checks that
# every spelling's trajectory is bit-identical to the fn spelling's.
#
# Usage (an environment with EarthSciAST, JSON3 and OrdinaryDiffEqTsit5):
#
#     julia --project=<env> bench/interp_bracket/bench_julia.jl [N…]
#
# Environment: REPEATS (default 5), TEND (default 600).

using EarthSciAST, JSON3, OrdinaryDiffEqTsit5, Statistics, Printf

const E = EarthSciAST
const HERE = @__DIR__
const REPEATS = parse(Int, get(ENV, "REPEATS", "5"))
const TEND = parse(Float64, get(ENV, "TEND", "600"))
const NOFOLD = E._plan_with(E._compiler_plan(:native); count_fold = false)

load(name) = E.load_path(joinpath(HERE, name))

function build(model, compiler)
    E._reset_cascade_tally!()
    f!, u0, p, _, vm = compiler isa Symbol ?
        E._build_evaluator(model; compiler = compiler) :
        E._with_compiler_plan(() -> E._build_evaluator(model; compiler = compiler), compiler)
    return (f!, u0, p, vm, copy(E._CASCADE_TALLY))
end

function rhs_time(f!, u0, p; calls = 2000)
    du = similar(u0)
    f!(du, u0, p, 0.0)
    ts = Vector{Float64}(undef, 7)
    for r in eachindex(ts)
        t0 = time_ns()
        for i in 1:calls
            f!(du, u0, p, 1.0e-3 * i)
        end
        ts[r] = (time_ns() - t0) / calls
    end
    return median(ts)
end

function solve_once(f!, u0, p)
    prob = ODEProblem(f!, copy(u0), (0.0, TEND), p)
    t0 = time_ns()
    sol = solve(prob, Tsit5(); saveat = TEND / 10)
    return ((time_ns() - t0) / 1.0e9, sol)
end

# The states by name, so spellings compare whatever their slot order.
states(sol, vm) = Dict(k => [u[v] for u in sol.u] for (k, v) in vm if !startswith(k, "xq") &&
    !startswith(k, "ilo") && (startswith(k, "u[") || startswith(k, "v[") || startswith(k, "th[")))

for N in (isempty(ARGS) ? [59, 200] : parse.(Int, ARGS))
    spell = [
        ("fn", "interp_bracket_const_fn_N$N.esm", :native),
        ("unfused", "interp_bracket_const_compose_N$N.esm", NOFOLD),
        ("fused", "interp_bracket_const_compose_N$N.esm", :native),
        ("rt_unfused", "interp_bracket_runtime_compose_N$N.esm", NOFOLD),
        ("rt_fused", "interp_bracket_runtime_compose_N$N.esm", :native),
    ]
    built = Dict{String, Any}()
    for (lab, file, c) in spell
        t0 = time()
        b = build(load(file), c)
        @printf("N=%d %-10s build %.2fs  count tally: search=%d linear=%d\n", N, lab,
            time() - t0, get(b[5], :count_fold_search, 0), get(b[5], :count_fold_linear, 0))
        built[lab] = b
        solve_once(b[1], b[2], b[3])    # compile the solve outside the timed runs
    end
    rhs = Dict(lab => Float64[] for (lab, _, _) in spell)
    slv = Dict(lab => Float64[] for (lab, _, _) in spell)
    ref = nothing
    for r in 1:REPEATS, (lab, _, _) in spell
        f!, u0, p, vm, _ = built[lab]
        push!(rhs[lab], rhs_time(f!, u0, p))
        t, sol = solve_once(f!, u0, p)
        push!(slv[lab], t)
        if r == 1
            st = states(sol, vm)
            if ref === nothing
                ref = st
            else
                same = keys(st) == keys(ref) && all(all(st[k] .=== ref[k]) for k in keys(ref))
                @printf("N=%d %-10s trajectory bit-identical to fn: %s (%d rhs calls)\n",
                    N, lab, same, sol.stats.nf)
            end
        end
    end
    for (lab, _, _) in spell
        @printf("N=%d %-10s rhs median %8.2f us   solve median %8.4f s   (solve runs: %s)\n",
            N, lab, median(rhs[lab]) / 1.0e3, median(slv[lab]),
            join((@sprintf("%.4f", x) for x in slv[lab]), " "))
    end
end
