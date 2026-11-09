# Elementwise template application (esm-spec §9.6.11), Julia native side.
#
# For each document named on the command line (written by generate.py), or each
# `<case>_{fn,tpl,faq}_<size>.esm` triple in DIR, it reports the build (first,
# which includes Julia compilation, and a second build of the same document,
# each with the bytes it allocated), the first right-hand-side call of the first
# build (which compiles its kernels), the median steady call and
# the bytes one call allocates, and checks the derivative of `tpl` and `faq`
# against `fn` bit for bit.
#
# Usage (an environment with EarthSciAST):
#
#     julia --project=<env> bench/template_array_args/bench_julia.jl [DIR] [name-filter…]
#     julia --project=<env> bench/template_array_args/bench_julia.jl --one FILE.esm
#
# `--one` builds and times one document and prints one line, with the process's
# peak resident set (run it once per document to compare build memory).
# Environment: CALLS (default 50 per sample, 7 samples).

using EarthSciAST, Statistics, Printf

const E = EarthSciAST
const CALLS = parse(Int, get(ENV, "CALLS", "50"))
const TIMES = (0.0, 0.7, 3.1)

function build(path)
    GC.gc()
    st = @timed E.esm_problem(path, (0.0, 1.0); compiler = :native)
    prob = st.value
    u = copy(prob.u0)
    for (r, k) in enumerate(sort!(collect(keys(prob.var_map))))
        u[prob.var_map[k]] += (r % 97) / 64
    end
    return (f! = prob.f!, u = u, u0 = copy(prob.u0), p = prob.p, vm = prob.var_map, time = st.time, bytes = st.bytes)
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
    alloc = @allocated f!(du, u0, p, 0.2)
    alloc = @allocated f!(du, u0, p, 0.3)
    return median(ts) / 1.0e9, alloc
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

function first_call(f!, u0, p)
    du = similar(u0)
    f!(du, u0, p, 0.0)
    return nothing
end

function one(path)
    b1 = build(path)
    # Timed from outside the call: compiling the call site for the right-hand
    # side's type, which carries every generated kernel, is part of what the
    # first call costs (on the reseact WetDeposition + FastJX piece, two
    # minutes that a timer inside the call never sees).
    t0 = time_ns()
    first_call(b1.f!, b1.u0, b1.p)
    fc = (time_ns() - t0) / 1.0e9
    b2 = build(path)
    st, al = steady(b2.f!, b2.u, b2.p)
    @printf(
        "%-36s states %8d  build %8.3fs %9.1f MiB  (first %8.3fs %9.1f MiB, first call %8.3fs)  call %12.3f us  alloc/call %8d B  maxrss %7.0f MiB\n",
        basename(path), length(b2.u), b2.time, b2.bytes / 2^20, b1.time, b1.bytes / 2^20, fc,
        st * 1.0e6, al, Sys.maxrss() / 2^20
    )
    return b2
end

if !isempty(ARGS) && ARGS[1] == "--one"
    one(ARGS[2])
else
    dir = isempty(ARGS) ? (@__DIR__) : ARGS[1]
    filters = length(ARGS) > 1 ? ARGS[2:end] : String[]
    for f in sort(readdir(dir))
        m = match(r"^(\w+?)_fn_(.+)\.esm$", f)
        m === nothing && continue
        isempty(filters) || any(occursin(x, f) for x in filters) || continue
        ref = nothing
        for s in ("fn", "tpl", "faq")
            path = joinpath(dir, "$(m[1])_$(s)_$(m[2]).esm")
            isfile(path) || continue
            b = try
                one(path)
            catch err
                @printf("%-36s FAILED: %s\n", basename(path), first(sprint(showerror, err), 300))
                continue
            end
            d = dus(b.f!, b.u, b.p, b.vm)
            if ref === nothing
                ref = d
            else
                @printf("    %s bit-identical to fn: %s\n", s, same(d, ref))
            end
        end
        flush(stdout)
    end
end
