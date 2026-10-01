# Julia adapter for the scaling conformance tier.
#
# For every document an index names, it builds `esm_problem(doc; compiler)`,
# measures the build, the compiled program's size, the first and the steady
# right-hand-side call and the bytes a steady call allocates, runs the family's
# hand-written loop (hand_loops.jl) on the same state and times it, and writes
# one result file in the tier's result format (../README.md). It measures and
# reports; the gates and the known-failure ledger are applied by ../check.py.
#
#   julia --project=pkg/EarthSciAST.jl/scripts/scaling_env [-t K] \
#         tests/conformance/scaling/julia/adapter.jl \
#         --docs <dir with index.json> --output <result.json> \
#         [--family F ...] [--max-n N] [--budget SECONDS] [--max-build SECONDS]
#         [--interpreter-max-states N] [--timeout-s SECONDS] [--max-rss-gb GB]
#         [--in-process]
#
# `--docs` is a tree `generate.py --out` wrote, or the committed fixtures/.
# `--budget` is the least wall time each steady measurement samples for
# (default 0.25 s, the README's). `--max-build` stops a family's ladder once one
# of its builds takes longer; the sizes not attempted are recorded as errors
# that say so. `--interpreter-max-states` (default 2000) is the largest document
# the interpreter is also built for, as the oracle for native's dy
# (`interpreter_max_abs_diff`) and for the hand loop's when native does not
# build (`hand_loop_checked_against` is then "interpreter"); 0 turns it off.
# The default stays low because the interpreter's per-cell expansion of a
# prefix scan or a dense contraction grows as N^2 in memory: past 12 GB at
# prefix_scan's 10^4 cells and source_receptor's 3162, where native needs
# under 3 GB, and the oracle's memory would be charged to native's document.
#
# THREADS. Native threads its compiled sections only when Polyester is loaded
# (the opt-in lives in EarthSciASTPolyesterExt), so this adapter always loads
# it: with one thread native runs its serial path, and with `-t K` native runs
# whatever it threads today. The result file's `threads` is Julia's thread
# count, and `hand_loop_s` is then the threaded hand loop.
#
# ONE CHILD PROCESS PER FAMILY. The adapter measures each family's ladder in a
# child Julia process (this script with `--in-process --family F`) and watches
# it: a child whose resident memory passes `--max-rss-gb` (default 12), or that
# finishes no document for `--timeout-s` (default 1800), is killed, and a child
# that dies on its own is noticed. The memory cap is the same on every machine,
# and is also the child's GC heap-size hint, so whether a document fits is a
# property of the document and the compiler rather than of the machine. The document it was working on is then recorded as an `error`
# that says which, and the family's larger sizes as not attempted, so a
# document too big for the machine is a result rather than a lost run. The
# memory cap reads /proc, so it holds on Linux only. `--in-process` measures in
# this process, with neither guard.
#
# OUTCOMES. `refused` is a `compiler_refused_rule` out of the build; `error` is
# anything else the build or a call threw, or a child's end above. Every one
# records the message and the run continues with the next document. The file
# is rewritten after every document, so a process that is itself killed
# part-way leaves every result it finished.

import Pkg
# A child runs in the environment its parent has already instantiated.
get(ENV, "SCALING_ADAPTER_CHILD", "") == "1" || let env = normpath(joinpath(@__DIR__, "..", "..", "..", "..", "pkg", "EarthSciAST.jl",
                            "scripts", "scaling_env")),
    manifest = joinpath(env, "Manifest.toml")
    bootstrap() = begin
        Pkg.activate(env; io=devnull)
        isfile(manifest) ||
            Pkg.develop(path=normpath(joinpath(env, "..", "..")); io=devnull)
        Pkg.instantiate(; io=devnull)
    end
    try
        bootstrap()
    catch err
        @warn "$(basename(env)) did not instantiate; rebuilding Manifest.toml" exception = (err, catch_backtrace())
        rm(manifest; force=true)
        bootstrap()
    end
end

using EarthSciAST
using JSON3
using Polyester

const ESA = EarthSciAST
const RGF = EarthSciAST.RuntimeGeneratedFunctions

include(joinpath(@__DIR__, "hand_loops.jl"))

# ---------------------------------------------------------------------------
# Command line
# ---------------------------------------------------------------------------

function parse_args(args)
    o = Dict{String,Any}("family" => String[], "max-n" => typemax(Int), "budget" => 0.25,
                         "max-build" => 1800.0, "compiler" => "native",
                         "interpreter-max-states" => 2_000, "timeout-s" => 1800.0,
                         "max-rss-gb" => 12.0, "in-process" => false)
    i = 1
    while i <= length(args)
        a = args[i]
        startswith(a, "--") || error("unexpected argument $a")
        k = a[3:end]
        if k == "in-process"
            o[k] = true
            i += 1
            continue
        end
        i < length(args) || error("$a needs a value")
        v = args[i+1]
        if k == "family"
            push!(o["family"], v)
        elseif k in ("max-n", "interpreter-max-states")
            o[k] = parse(Int, v)
        elseif k in ("budget", "max-build", "timeout-s", "max-rss-gb")
            o[k] = parse(Float64, v)
        elseif k in ("docs", "output", "compiler")
            o[k] = v
        else
            error("unknown option $a")
        end
        i += 2
    end
    haskey(o, "docs") || error("--docs is required")
    haskey(o, "output") || error("--output is required")
    return o
end

# ---------------------------------------------------------------------------
# Code size: the program the right-hand side runs
# ---------------------------------------------------------------------------
#
# The measure is the number of expression nodes in every distinct
# RuntimeGeneratedFunction reachable from `prob.f!` (each `Expr` and each leaf
# counts one, the count the emitter's own function-size cap uses), plus every
# distinct `_Node` reachable from it (the trees the scalar and per-cell tiers
# walk on each call). Reachability is a walk of the closure's fields, so every
# tier's program is counted wherever it is stored, and nothing is counted
# twice: generated functions are keyed by their expression's hash, nodes by
# identity. Data is not code: arrays and dicts whose element types cannot hold
# either are skipped, so the slot tables and constants that do grow with N are
# never read.

_exprsize(ex) = ex isa Expr ? 1 + sum(_exprsize, ex.args; init=0) : 1

const _MAYHOLD = IdDict{Any,Bool}()
function _mayhold(@nospecialize T)
    haskey(_MAYHOLD, T) && return _MAYHOLD[T]
    T isa DataType || return true
    r = if isbitstype(T) || T <: AbstractString || T <: Symbol || T <: Module
        false
    elseif T <: RGF.RuntimeGeneratedFunction || T <: ESA._Node
        true
    elseif T <: Array
        _mayhold(eltype(T))
    elseif isabstracttype(T)
        true
    else
        _MAYHOLD[T] = true            # a self-referencing type terminates here
        any(_mayhold, fieldtypes(T))
    end
    _MAYHOLD[T] = r
    return r
end

function code_size(root)
    seen = IdDict{Any,Nothing}()
    rgfs = Set{Any}()
    kernels = 0
    emitted = 0
    walked = 0
    stack = Any[root]
    while !isempty(stack)
        x = pop!(stack)
        T = typeof(x)
        _mayhold(T) || continue
        if ismutable(x)
            haskey(seen, x) && continue
            seen[x] = nothing
        end
        if x isa RGF.RuntimeGeneratedFunction
            id = T.parameters[4]
            if !(id in rgfs)
                push!(rgfs, id)
                kernels += 1
                emitted += _exprsize(RGF.get_expression(x))
            end
            continue
        end
        x isa ESA._Node && (walked += 1)
        if x isa Array
            for i in eachindex(x)
                isassigned(x, i) && push!(stack, x[i])
            end
        else
            for i in 1:nfields(x)
                isdefined(x, i) && push!(stack, getfield(x, i))
            end
        end
    end
    return (; kernels, emitted_nodes = emitted, walked_nodes = walked)
end

# ---------------------------------------------------------------------------
# Timing
# ---------------------------------------------------------------------------

# The median of individual calls after one untimed call: at least 5 calls and
# at least `budget` seconds of them, at most 1000 (the tier's README).
function _median(x)
    y = sort(x)
    m = length(y)
    return isodd(m) ? y[(m+1)÷2] : (y[m÷2] + y[m÷2+1]) / 2
end

function timeit(f::F; budget = 0.25) where {F}
    f()
    samples = Float64[]
    total = 0.0
    while length(samples) < 5 || (total < budget && length(samples) < 1000)
        t0 = time_ns()
        f()
        dt = (time_ns() - t0) / 1e9
        push!(samples, dt)
        total += dt
    end
    return _median(samples)
end

# A function barrier, so the count is the call's and not the caller's.
function steady_alloc(f::F, du, u, p, t) where {F}
    f(du, u, p, t)
    f(du, u, p, t)
    return @allocated f(du, u, p, t)
end

# ---------------------------------------------------------------------------
# One document
# ---------------------------------------------------------------------------

_refused(err) = hasproperty(err, :code) &&
                String(getproperty(err, :code)) == ESA.ERROR_CODES.COMPILER_REFUSED_RULE

_msg(err) = first(sprint(showerror, err), 2000)

function blank_result(entry)
    return Dict{String,Any}(
        "family" => String(entry["family"]), "n" => Int(entry["n"]),
        "n_cells" => Int(entry["n_cells"]), "n_states" => Int(entry["n_states"]),
        "status" => "error", "reason" => nothing,
        "build_s" => nothing, "code_size" => nothing,
        "code_size_unit" => "emitted_expr_nodes+walked_nodes",
        "first_call_s" => nothing, "steady_rhs_s" => nothing, "allocs_per_call" => nothing,
        "hand_loop_s" => nothing, "hand_loop_max_abs_diff" => nothing, "dy_max_abs" => nothing,
        "interpreter_max_abs_diff" => nothing,
        # Julia's own fields, beyond the tier's format:
        "tiers" => nothing, "code_size_parts" => nothing, "hand_loop_serial_s" => nothing,
        "hand_loop_threads" => nothing, "hand_loop_checked_against" => nothing,
        "interpreter_note" => nothing, "peak_rss_bytes" => nothing)
end

# The state every call is measured at (the tier's README, "The measured
# state"): element k, 0-based in the family's canonical order, is
# d_k * (1 + 0.1 sin(0.37 k)) + 0.01 (1 + sin(0.53 k)) with d_k its declared
# default, at t = 0. The canonical order is spelled here as the element names
# `prob.var_map` uses, so the layout native chose does not matter.

# Row-major (last axis fastest) keys of array variable `name` shaped `dims`.
function _rowmajor(name, dims)
    rev = CartesianIndices(reverse(dims))
    return [string(name, "[", join(reverse(Tuple(I)), ","), "]") for I in rev]
end

function canonical_names(fam, entry)
    sh(k) = Int(entry["shape"][k])
    n = Int(entry["n_cells"])
    rank = Dict("stencil_1d" => 1, "stencil_2d" => 2, "stencil_3d" => 3, "stencil_4d" => 4)
    if haskey(rank, fam)
        return _rowmajor("Diffusion.u", ntuple(_ -> sh("side"), rank[fam]))
    elseif fam == "transport_3d"
        return _rowmajor("Transport.q", ntuple(_ -> sh("side"), 3))
    elseif fam == "chemistry_grid"
        return reduce(vcat, [_rowmajor("Pollu." * s, (sh("nlon"), sh("nlat"))) for s in POLLU_SPECIES])
    elseif fam == "prefix_scan"
        return _rowmajor("Column.u", (n,))
    elseif fam == "unstructured_gather"
        return _rowmajor("Mesh.u", (n,))
    elseif fam == "source_receptor"
        return vcat(_rowmajor("SourceReceptor.c", (n,)), _rowmajor("SourceReceptor.e", (n,)))
    elseif fam == "regrid"
        return vcat(_rowmajor("Regrid.F_src", (n,)), _rowmajor("Regrid.F_tgt", (n,)))
    elseif fam == "scalar_chemistry"
        return ["Boxes." * s * "_" * string(b) for b in 1:sh("boxes") for s in POLLU_SPECIES]
    end
    error("no canonical state order for family $fam")
end

function probe_state(prob, fam, entry)
    names = canonical_names(fam, entry)
    vm = prob.var_map
    length(names) == length(prob.u0) ||
        error("the canonical order names $(length(names)) states; the problem has $(length(prob.u0))")
    u = fill(NaN, length(prob.u0))
    for (c, name) in enumerate(names)
        k = c - 1
        slot = vm[name]
        d = prob.u0[slot]
        u[slot] = d * (1 + 0.1 * sin(0.37 * k)) + 0.01 * (1 + sin(0.53 * k))
    end
    any(isnan, u) && error("the canonical order does not cover every state slot")
    return u
end
const PROBE_T = 0.0

# dy of `prob` at the measured state, keyed back to canonical element names so
# two problems with different layouts can be compared.
function dy_by_name(prob, du, names)
    vm = prob.var_map
    return [du[vm[nm]] for nm in names]
end

function measure!(rec, path, entry, compiler, budget, interp_cap)
    fam = String(entry["family"])
    insp = ESA.BuildInspection()
    prob = nothing
    try
        rec["build_s"] = @elapsed prob = ESA.esm_problem(path, (0.0, 1.0);
                                                         compiler = compiler, inspect = insp)
    catch err
        err isa InterruptException && rethrow()
        rec["status"] = _refused(err) ? "refused" : "error"
        rec["reason"] = _msg(err)
        rec["build_s"] = nothing
        rep = ESA.compiler_report(insp)
        isempty(rep.rules) || (rec["tiers"] = [[String(t), n] for (t, n) in ESA.tier_histogram(rep)])
    end
    names = canonical_names(fam, entry)
    du = nothing
    if prob !== nothing
        rec["n_states"] = length(prob.u0)
        rec["tiers"] = [[String(t), n] for (t, n) in ESA.tier_histogram(ESA.compiler_report(prob))]
        cs = code_size(prob.f!)
        rec["code_size"] = cs.emitted_nodes + cs.walked_nodes
        rec["code_size_parts"] = Dict("kernels" => cs.kernels, "emitted_nodes" => cs.emitted_nodes,
                                      "walked_nodes" => cs.walked_nodes)
        f! = prob.f!
        p = prob.p
        u = probe_state(prob, fam, entry)
        du = zeros(length(u))
        try
            rec["first_call_s"] = @elapsed f!(du, u, p, PROBE_T)
            rec["allocs_per_call"] = steady_alloc(f!, du, u, p, PROBE_T)
            rec["steady_rhs_s"] = timeit(() -> f!(du, u, p, PROBE_T); budget = budget)
            f!(du, u, p, PROBE_T)
            rec["status"] = "ok"
            rec["dy_max_abs"] = maximum(abs, du; init = 0.0)
        catch err
            err isa InterruptException && rethrow()
            rec["status"] = "error"
            rec["reason"] = "right-hand side: " * _msg(err)
            du = nothing
        end
    end
    # The interpreter, the oracle, at the same state.
    iprob = nothing
    idy = nothing
    if Int(entry["n_states"]) <= interp_cap
        try
            iprob = ESA.esm_problem(path, (0.0, 1.0); compiler = :interpreter)
            iu = probe_state(iprob, fam, entry)
            idu = zeros(length(iu))
            iprob.f!(idu, iu, iprob.p, PROBE_T)
            idy = dy_by_name(iprob, idu, names)
            du === nothing ||
                (rec["interpreter_max_abs_diff"] = maximum(abs.(dy_by_name(prob, du, names) .- idy); init = 0.0))
        catch err
            err isa InterruptException && rethrow()
            iprob = nothing
            rec["interpreter_note"] = "the interpreter did not build or run: " * first(_msg(err), 400)
        end
    end
    if du !== nothing
        hand_loop!(rec, prob, path, entry, du, budget, "native")
    elseif iprob !== nothing
        # Native did not build; the hand loop is still checked, against the
        # interpreter, so it is known good before native reaches it.
        iu = probe_state(iprob, fam, entry)
        idu = zeros(length(iu))
        iprob.f!(idu, iu, iprob.p, PROBE_T)
        hand_loop!(rec, iprob, path, entry, idu, budget, "interpreter")
    end
    return rec
end

# Run the family's hand loop at the measured state of `prob`, record its max
# difference from `du` (that problem's dy; `against` names its compiler), and
# time it.
function hand_loop!(rec, prob, path, entry, du, budget, against)
    fam = String(entry["family"])
    hl = get(HAND_LOOPS, fam, nothing)
    note(msg) = (rec["reason"] = rec["reason"] === nothing ? msg : rec["reason"] * "; " * msg)
    if hl === nothing
        note("no Julia hand loop for family $fam")
        return
    end
    try
        u = probe_state(prob, fam, entry)
        doc = JSON3.read(read(path, String), Dict{String,Any})
        st = hl.setup(prob, doc, entry)
        row! = hl.row!
        duh = fill(NaN, length(u))
        hand_serial!(row!, duh, u, PROBE_T, st)
        diff = maximum(abs.(duh .- du); init = 0.0)
        if isnan(diff)
            note("the hand loop left some dy slots unwritten")
        else
            rec["hand_loop_max_abs_diff"] = diff
            rec["hand_loop_checked_against"] = against
        end
        tser = timeit(() -> hand_serial!(row!, duh, u, PROBE_T, st); budget = budget)
        rec["hand_loop_serial_s"] = tser
        rec["hand_loop_threads"] = Threads.nthreads()
        if Threads.nthreads() > 1
            duh2 = fill(NaN, length(u))
            hand_threaded!(row!, duh2, u, PROBE_T, st)
            duh2 == duh || note("the threaded hand loop disagrees with the serial one")
            rec["hand_loop_s"] = timeit(() -> hand_threaded!(row!, duh2, u, PROBE_T, st); budget = budget)
        else
            rec["hand_loop_s"] = tser
        end
    catch err
        err isa InterruptException && rethrow()
        note("hand loop: " * _msg(err))
    end
    return
end

# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------

function git_commit()
    c = get(ENV, "SCALING_COMMIT", "")
    isempty(c) || return c
    try
        return readchomp(`git -C $(@__DIR__) rev-parse HEAD`)
    catch
        return nothing
    end
end

# Where the timings were taken, since they are only worth reading from a
# machine nothing else shares: a Slurm job that holds its node exclusively, or
# the local node (whose load the header records).
function machine_note()
    id = get(ENV, "SLURM_JOB_ID", "")
    isempty(id) && return "local node (not a Slurm job)"
    excl = try
        m = match(r"OverSubscribe=(\w+)", read(`scontrol show job $id`, String))
        m === nothing ? "unknown" : (m.captures[1] == "NO" ? "exclusive" : "shared")
    catch
        "unknown"
    end
    # An exclusive job keeps other jobs off the node, not other processes of
    # the same job; the load average says whether anything else was running.
    return "Slurm job $id, node $excl"
end

# The 1, 5 and 15 minute load averages when the run started, as one string.
load_average() = try
    join(split(read("/proc/loadavg", String))[1:3], " ")
catch
    nothing
end

function write_results(path, header, results)
    tmp = path * ".tmp"
    open(tmp, "w") do io
        JSON3.pretty(io, JSON3.write(merge(header, Dict("results" => results))))
        println(io)
    end
    mv(tmp, path; force = true)
end

# Whether to stop a family's ladder after `rec`: its build went over
# `max_build`, or the next size's build, projected from the last two at their
# observed power law (at least linear), would.
function ladder_stop(rec, prev, next, max_build)
    b = rec["build_s"]
    b === nothing && return nothing
    if b > max_build
        return "not attempted: the build at n = $(rec["n"]) took $(round(b; digits = 1)) s, " *
               "over this run's --max-build of $(max_build) s"
    end
    (next === nothing || prev === nothing || b < 1.0) && return nothing
    s0, b0 = prev
    s1 = rec["n_states"]
    s2 = Int(next["n_states"])
    slope = s1 > s0 && b > b0 ? max(1.0, log(b / b0) / log(s1 / s0)) : 1.0
    proj = b * (s2 / s1)^slope
    proj > max_build || return nothing
    return "not attempted: the build grew as n_states^$(round(slope; digits = 2)) up to " *
           "n = $(rec["n"]) ($(round(b; digits = 1)) s), which projects $(round(proj; digits = 0)) s " *
           "at n = $(next["n"]), over this run's --max-build of $(max_build) s"
end

function run_header(o, compiler)
    return Dict{String,Any}(
        "binding" => "julia", "compiler" => String(compiler), "threads" => Threads.nthreads(),
        "commit" => git_commit(), "host" => gethostname(),
        "target" => string(Sys.MACHINE), "julia_version" => string(VERSION),
        "polyester_loaded" => ESA._polyester_loaded(),
        "machine" => machine_note(), "load_average" => load_average(),
        "cpus" => Sys.CPU_THREADS, "max_rss_gb" => o["in-process"] ? nothing : _gb(_cap(o)),
        "timeout_s" => o["in-process"] ? nothing : o["timeout-s"])
end

function selected(o)
    index = JSON3.read(read(joinpath(o["docs"], "index.json"), String), Dict{String,Any})
    entries = [e for e in index["documents"]
               if (isempty(o["family"]) || e["family"] in o["family"]) && e["n"] <= o["max-n"]]
    fams = unique(String(e["family"]) for e in entries)
    ladders = [sort([e for e in entries if e["family"] == fam]; by = e -> e["n"]) for fam in fams]
    return fams, ladders
end

function log_result(rec)
    peak = rec["peak_rss_bytes"] === nothing ? "" : " peak_rss=$(_gb(rec["peak_rss_bytes"]))GB"
    println(stderr, "[$(rec["family"]) n=$(rec["n"])] $(rec["status"]) build=$(rec["build_s"]) " *
                    "code=$(rec["code_size"]) rhs=$(rec["steady_rhs_s"]) hand=$(rec["hand_loop_s"]) " *
                    "alloc=$(rec["allocs_per_call"]) diff=$(rec["hand_loop_max_abs_diff"])$peak" *
                    (rec["reason"] === nothing ? "" : "  -- " * first(rec["reason"], 200)))
end

# Measure every selected ladder in this process.
function run_in_process(o)
    compiler = Symbol(o["compiler"])
    fams, ladders = selected(o)
    header = run_header(o, compiler)
    results = Any[]
    for (fam, ladder) in zip(fams, ladders)
        # The first build of a family in the process pays for compiling the
        # build path it takes; build the smallest document once, untimed, so
        # every recorded build_s is a warm one.
        try
            ESA.esm_problem(joinpath(o["docs"], ladder[1]["path"]), (0.0, 1.0); compiler = compiler)
        catch err
            err isa InterruptException && rethrow()
        end
        stop = nothing
        prev = nothing                       # (n_states, build_s) of the last build
        for (li, e) in enumerate(ladder)
            rec = blank_result(e)
            if stop !== nothing
                rec["reason"] = stop
            else
                GC.gc()
                measure!(rec, joinpath(o["docs"], e["path"]), e, compiler, o["budget"],
                         o["interpreter-max-states"])
                stop = ladder_stop(rec, prev, li < length(ladder) ? ladder[li+1] : nothing,
                                   o["max-build"])
                rec["build_s"] === nothing || (prev = (rec["n_states"], rec["build_s"]))
            end
            push!(results, rec)
            write_results(o["output"], header, results)
            log_result(rec)
        end
    end
    write_results(o["output"], header, results)
    return 0
end

# ---------------------------------------------------------------------------
# The parent: one watched child per family
# ---------------------------------------------------------------------------

_gb(b) = round(b / 2^30; digits = 1)
_cap(o) = o["max-rss-gb"] * 2^30

# Resident bytes of process `pid` now (Linux), or nothing when it cannot be read.
function rss_bytes(pid)
    s = try
        read("/proc/$pid/status", String)
    catch
        return nothing
    end
    m = match(r"VmRSS:\s+(\d+)\s+kB", s)
    return m === nothing ? nothing : parse(Int, m.captures[1]) * 1024
end

# The records a child has written so far (its output is replaced atomically).
function child_results(path)
    isfile(path) || return Any[]
    try
        return collect(Any, JSON3.read(read(path, String), Dict{String,Any})["results"])
    catch
        return Any[]
    end
end

# Measure one family's ladder in a child and return its records, completed with
# a record for the document the child did not finish and for every size above.
function run_family(o, fam, ladder)
    part = o["output"] * "." * fam * ".part"
    rm(part; force = true)
    threads = "$(Threads.nthreads(:default)),$(Threads.nthreads(:interactive))"
    cmd = `$(Base.julia_cmd()) --threads=$threads --heap-size-hint=$(round(Int, _cap(o)))
           --project=$(Base.active_project())
           $(abspath(PROGRAM_FILE)) --in-process --docs $(o["docs"]) --family $fam
           --max-n $(o["max-n"]) --budget $(o["budget"]) --max-build $(o["max-build"])
           --compiler $(o["compiler"]) --interpreter-max-states $(o["interpreter-max-states"])
           --output $part`
    proc = run(pipeline(addenv(cmd, "SCALING_ADAPTER_CHILD" => "1"); stdout = stdout, stderr = stderr);
               wait = false)
    cap = _cap(o)
    done = 0
    peaks = Int[]          # the highest resident memory sampled while each document ran
    peak = 0
    since = time()         # when the child last finished a document
    polled = 0.0
    killed = nothing
    while process_running(proc)
        r = something(rss_bytes(getpid(proc)), 0)
        peak = max(peak, r)
        if time() - polled > 1.0
            polled = time()
            k = length(child_results(part))
            while done < k
                push!(peaks, peak)
                peak = r
                done += 1
                since = time()
            end
        end
        if r > cap
            killed = "out of memory: the process measuring this document reached $(_gb(r)) GB " *
                     "resident after $(round(Int, time() - since)) s on it, over this run's " *
                     "--max-rss-gb of $(_gb(cap)) GB"
        elseif time() - since > o["timeout-s"]
            killed = "timeout: no result within $(round(Int, o["timeout-s"])) s"
        end
        if killed !== nothing
            kill(proc, Base.SIGKILL)
            break
        end
        sleep(0.1)
    end
    wait(proc)
    got = child_results(part)
    rm(part; force = true)
    while length(peaks) < length(got)
        push!(peaks, peak)
    end
    for (rec, p) in zip(got, peaks)
        startswith(something(rec["reason"], ""), "not attempted") || (rec["peak_rss_bytes"] = p)
    end
    if length(got) < length(ladder)
        e = ladder[length(got)+1]
        rec = blank_result(e)
        rec["peak_rss_bytes"] = peak
        rec["reason"] = killed !== nothing ? killed :
                        proc.termsignal != 0 ?
                        "the child process was killed by signal $(proc.termsignal) (9 is usually out of memory)" :
                        "the child process exited with code $(proc.exitcode) before this document's result"
        log_result(rec)
        why = "not attempted: the document at n = $(e["n"]) did not finish ($(rec["reason"]))"
        push!(got, rec)
        for e2 in ladder[length(got)+1:end]
            r2 = blank_result(e2)
            r2["reason"] = why
            log_result(r2)
            push!(got, r2)
        end
    end
    return got
end

function supervise(o)
    fams, ladders = selected(o)
    header = run_header(o, Symbol(o["compiler"]))
    results = Any[]
    for (fam, ladder) in zip(fams, ladders)
        append!(results, run_family(o, fam, ladder))
        write_results(o["output"], header, results)
    end
    write_results(o["output"], header, results)
    return 0
end

main(args) = (o = parse_args(args); o["in-process"] ? run_in_process(o) : supervise(o))

exit(main(ARGS))
