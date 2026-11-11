# Edge enumeration and rank lookup in template form, Julia native.
#
# For each `mesh_rank_tpl_E<e>.esm` written by generate.py (in DIR), runs REPS
# fresh processes. Each process builds the document twice under strict
# `native` (the first build includes Julia compilation; the second is the setup
# time that grows with the data: value invention, the rank table, the kernels),
# then reports the first right-hand-side call, the median steady call and the
# peak resident memory. The table is the median over the processes. The
# derivative is compared bit for bit across the processes, and with the
# interpreter's when INTERP_CHECK=1 (small sizes only: the interpreter
# re-counts every rank on every call).
#
# Usage (an environment with EarthSciAST):
#
#     python3 bench/closed_templates/generate.py --out DIR --only mesh --mesh 57 --mesh 182
#     julia --project=<env> bench/closed_templates/bench_mesh_rank.jl DIR [name-filter…]
#
# With no DIR (or `-`), the default-size document (208 edges) is generated into
# $CLOSED_TEMPLATES_DIR, else closed_templates under $TMPDIR.
#
# Environment: REPS (default 3), CALLS (default 20), INTERP_CHECK (default 0).

using EarthSciAST, Statistics, Printf, Serialization

const E = EarthSciAST

function build(path, compiler)
    E._reset_cascade_tally!()
    GC.gc()
    t0 = time_ns()
    prob = E.esm_problem(path, (0.0, 1.0); compiler = compiler)
    dt = (time_ns() - t0) / 1.0e9
    u = copy(prob.u0)
    for (r, k) in enumerate(sort!(collect(keys(prob.var_map))))
        u[prob.var_map[k]] += r / 64
    end
    return (; f! = prob.f!, u, p = prob.p, vm = prob.var_map, dt, tally = copy(E._CASCADE_TALLY))
end

function du_of(b)
    du = fill(NaN, length(b.u))
    b.f!(du, b.u, b.p, 0.3)
    return Dict(k => du[v] for (k, v) in b.vm)
end

# One process: one document, one compiler.
function one(path, out, calls)
    b1 = build(path, :native)
    b = build(path, :native)
    du = similar(b.u)
    t0 = time_ns()
    b.f!(du, b.u, b.p, 0.0)
    first_call = (time_ns() - t0) / 1.0e9
    ts = Float64[]
    for r in 1:7
        t0 = time_ns()
        for i in 1:calls
            b.f!(du, b.u, b.p, 1.0e-3 * i)
        end
        push!(ts, (time_ns() - t0) / calls / 1.0e9)
    end
    res = (;
        build1 = b1.dt, build = b.dt, first_call, call = median(ts),
        maxrss = Sys.maxrss() / 2^30, states = length(b.u), tally = b.tally, du = du_of(b),
    )
    serialize(out, res)
    return
end

if length(ARGS) >= 3 && ARGS[1] == "--one"
    one(ARGS[2], ARGS[3], parse(Int, get(ENV, "CALLS", "20")))
    exit(0)
end

include(joinpath(@__DIR__, "docs.jl"))
const DIR = bench_docs(
    "generate.py", isempty(ARGS) || ARGS[1] == "-" ? nothing : ARGS[1], ["--only", "mesh"];
    env = "CLOSED_TEMPLATES_DIR", name = "closed_templates", prefix = "mesh_rank_tpl_"
)
const FILTERS = length(ARGS) > 1 ? ARGS[2:end] : String[]
const REPS = parse(Int, get(ENV, "REPS", "3"))
const INTERP_CHECK = get(ENV, "INTERP_CHECK", "0") == "1"
const TMP = mktempdir(get(ENV, "TMPDIR", tempdir()))

function run_one(path)
    out = joinpath(TMP, "r$(rand(UInt32)).jls")
    cmd = `$(Base.julia_cmd()) --project=$(Base.active_project()) -t $(Threads.nthreads()) $(@__FILE__) --one $path $out`
    run(cmd)
    return deserialize(out)
end

same(a, b) = keys(a) == keys(b) && all(a[k] === b[k] for k in keys(a))

for f in sort(readdir(DIR))
    match(r"^mesh_rank_tpl_E\d+\.esm$", f) === nothing && continue
    isempty(FILTERS) || any(occursin(x, f) for x in FILTERS) || continue
    rs = [run_one(joinpath(DIR, f)) for _ in 1:REPS]
    med(s) = median(getfield.(rs, s))
    @printf(
        "%-26s states %8d  build %8.3f s (first %8.3f s)  first call %9.4f s  call %11.2f us  peak %6.2f GB\n",
        f, rs[1].states, med(:build), med(:build1), med(:first_call), med(:call) * 1.0e6, med(:maxrss)
    )
    @printf("    tally: %s\n", join(("$k=$v" for (k, v) in sort(collect(rs[1].tally); by = first)), " "))
    @printf("    derivative bit-identical across processes: %s\n", all(same(rs[1].du, r.du) for r in rs))
    if INTERP_CHECK
        bi = build(joinpath(DIR, f), :interpreter)
        @printf("    native vs interpreter bit-identical: %s\n", same(rs[1].du, du_of(bi)))
    end
    flush(stdout)
end
