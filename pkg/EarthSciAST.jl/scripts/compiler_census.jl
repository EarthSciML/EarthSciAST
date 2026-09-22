#!/usr/bin/env julia
#
# compiler_census.jl — which tier does every equation of every corpus document
# land on, and does any kernel still walk the tree per cell at RHS-call time?
#
# Phase 0 of the compiler-selection work: the `native` compiler refuses a
# document whose RHS still runs `_run_acc_kernel!` (the per-cell interpreter),
# so the census has to separate three things a cascade tally alone conflates:
#
#   * per-cell BUILD  — `:percell_loop` / `:percell_acc` / `:percell_disabled`.
#     The faq equation declined every whole-array tier and was scalarized one
#     output cell at a time. That is a BUILD-time fact; the resulting access
#     kernels are then offered to the codegen tier.
#   * codegen decline — `codegen_decline_<reason>`. The PRIMARY (Float64)
#     RuntimeGeneratedFunction emission declined that kernel. With
#     `ESS_F64_OVERFLOW_CODEGEN` on (the default) the dual/overflow emission
#     below still serves it compiled at Float64, so a primary decline alone
#     does NOT mean the interpreter runs.
#   * dual decline    — `dual_codegen_decline_<reason>`. The overflow emission
#     declined it too. THESE are the kernels in `_KernelSection.dual_resid`,
#     the ones `_run_acc_kernel!` walks per cell on every RHS call, under every
#     element type. This count is the census's headline.
#
# Usage
# -----
#   # one document, one JSON object on stdout (prefixed `##CENSUS##`)
#   julia --project=pkg/EarthSciAST.jl scripts/compiler_census.jl \
#         --one path/to/doc.esm
#
#   # a whole corpus: a manifest of .esm paths, one per line, JSON lines out
#   julia --project=pkg/EarthSciAST.jl scripts/compiler_census.jl \
#         --manifest manifest.txt --out census.jsonl --jobs 4 --timeout 180
#
# The driver shards the manifest across `--jobs` WORKER processes. A worker
# loads EarthSciAST once and then builds documents one at a time, so the
# package load cost is paid `--jobs` times rather than once per document. The
# driver watches each worker's output file and SIGKILLs a worker whose current
# document has run past `--timeout` seconds, or that dies on its own (an
# out-of-memory build kills the process, it does not throw): the offending
# document is recorded with `status = "timeout"` / `"crashed"` and the worker
# is restarted at the next index. One pathological document therefore costs one
# worker restart, not the run.
#
# `--resume` keeps whatever is already in the output file and skips those paths.

using Dates
using Logging

# ─────────────────────────────────────────────────────────────────────────────
# Minimal JSON writer. The census must not depend on a JSON package being in
# the environment the build under test uses.
# ─────────────────────────────────────────────────────────────────────────────
_jesc(s) = sprint() do io
    for c in s
        c == '"'  ? print(io, "\\\"") :
        c == '\\' ? print(io, "\\\\") :
        c == '\n' ? print(io, "\\n")  :
        c == '\r' ? print(io, "\\r")  :
        c == '\t' ? print(io, "\\t")  :
        c < ' '   ? print(io, "\\u", lpad(string(UInt16(c), base=16), 4, '0')) :
        print(io, c)
    end
end

_jval(x::AbstractString) = "\"" * _jesc(String(x)) * "\""
_jval(x::Symbol)         = _jval(String(x))
_jval(x::Bool)           = x ? "true" : "false"
_jval(x::Integer)        = string(x)
_jval(x::AbstractFloat)  = isfinite(x) ? string(round(x; digits = 4)) : "null"
_jval(::Nothing)         = "null"
_jval(x::AbstractVector) = "[" * join((_jval(v) for v in x), ",") * "]"
_jval(x::AbstractDict)   = "{" *
    join(("$(_jval(String(k))):$(_jval(v))" for (k, v) in sort!(collect(x); by = first)), ",") *
    "}"

_jline(d::AbstractDict) = _jval(d)

# ─────────────────────────────────────────────────────────────────────────────
# One document.
# ─────────────────────────────────────────────────────────────────────────────

# Load the package under test and hand back the module. `using` is only legal at
# top level, so it goes through `@eval Main`; the binding it creates is newer
# than this function's world age, which is what `invokelatest` steps over.
function _load_esm()
    @eval Main using EarthSciAST
    return Base.invokelatest(getfield, Main, :EarthSciAST)
end

# The keys that mean "an equation was scalarized per output cell at BUILD".
const PERCELL_BUILD_KEYS = ("percell_loop", "percell_acc", "percell_disabled")

"""
    _census_one(M, path) -> Dict

Build `path` through `M` (the loaded `EarthSciAST` module) and report what the
cascade did. Never throws: every failure is a record. Whatever the build writes
to stderr is captured — including the `@info` the affine fallback logs, which is
why a fresh `ConsoleLogger` is installed over the same file.
"""
function _census_one(M, path::AbstractString)
    rec = Dict{String,Any}("path" => String(path))
    # A real FILE, not an `IOBuffer`: `redirect_stderr` rewires the process file
    # descriptor and only accepts an `IOStream`/`Pipe`/TTY, so an in-memory
    # buffer cannot receive what the build writes to `stderr`.
    errpath = tempname() * ".esscensus.err"
    errio = open(errpath, "w")
    entry = nothing
    ok = false
    t_build = 0.0
    err_type = nothing
    err_code = nothing
    err_msg = nothing

    M._reset_cascade_tally!()
    t0 = time()
    try
        redirect_stderr(errio) do
            with_logger(ConsoleLogger(errio)) do
                # Front door first: `esm_problem` flattens, resolves coupling and
                # runs the same tree-walk build, so it exercises the cascade the
                # way a simulation does. `tspan` is the only argument it needs
                # that a document does not carry.
                try
                    M.esm_problem(String(path), (0.0, 1.0))
                    entry = "esm_problem"
                    ok = true
                catch e1
                    M._is_resource_error(e1) && rethrow()
                    # Documents that need providers, metaparameters or a model
                    # selection `esm_problem` cannot guess still reach the
                    # tree-walk build through the typed entry point.
                    M._reset_cascade_tally!()
                    file = M.load_path(String(path))
                    names = file.models === nothing ? String[] :
                            sort!(String[String(k) for k in keys(file.models)])
                    if length(names) <= 1
                        M._build_evaluator(file)
                    else
                        M._build_evaluator(file; model_name = names[1])
                    end
                    entry = "build_evaluator"
                    ok = true
                end
            end
        end
    catch err
        err_type = string(typeof(err))
        err_code = hasproperty(err, :code) ? string(getproperty(err, :code)) : nothing
        err_msg  = first(sprint(showerror, err), 400)
    end
    t_build = time() - t0
    close(errio)

    tally = Dict{String,Int}(String(k) => v for (k, v) in M._CASCADE_TALLY)

    percell_build = sum(get(tally, k, 0) for k in PERCELL_BUILD_KEYS)
    cg_decl  = Dict{String,Int}()
    dual_decl = Dict{String,Int}()
    for (k, v) in tally
        if startswith(k, "dual_codegen_decline_")
            dual_decl[k[length("dual_codegen_decline_")+1:end]] = v
        elseif startswith(k, "codegen_decline_")
            cg_decl[k[length("codegen_decline_")+1:end]] = v
        end
    end

    debug = String[]
    try
        for ln in eachline(errpath)
            (occursin("[ess-", ln) || occursin("affine stencil fallback", ln) ||
             occursin("DECLINED", ln)) && push!(debug, first(ln, 300))
        end
    finally
        rm(errpath; force = true)
    end

    rec["entry"]          = entry
    rec["ok"]             = ok
    rec["build_seconds"]  = t_build
    rec["error_type"]     = err_type
    rec["error_code"]     = err_code
    rec["error_message"]  = err_msg
    rec["tally"]          = tally
    rec["percell_build"]  = percell_build
    rec["codegen_kernels"]      = get(tally, "codegen_kernel", 0)
    rec["dual_codegen_kernels"] = get(tally, "dual_codegen_kernel", 0)
    rec["codegen_declines"]     = cg_decl
    rec["dual_declines"]        = dual_decl
    rec["n_codegen_decline"]    = isempty(cg_decl)   ? 0 : sum(values(cg_decl))
    # THE headline: kernels neither emission covered, i.e. `dual_resid` —
    # `_run_acc_kernel!` walks these per cell on every RHS call.
    rec["n_interp_at_rhs"]      = isempty(dual_decl) ? 0 : sum(values(dual_decl))
    # The whole-array contraction tier. Its nest is EMITTED (array_contraction.jl),
    # so an equation landing here carries no tree walk at RHS-call time; it is
    # counted separately anyway because it is a different unit — these are
    # equations, `n_interp_at_rhs` counts kernels — and because it is the tier
    # whose reach the census exists to measure.
    rec["n_array_contraction"]  = get(tally, "array_contraction_codegen", 0)
    # Per-cell at BUILD only: the equation was scalarized per output cell during
    # construction and the resulting kernels then compiled, so the RHS-call path
    # carries no tree walk from it. This is the distinction a raw
    # `:percell_acc` count hides.
    rec["percell_build_only"]   = (rec["n_interp_at_rhs"] == 0 &&
                                   rec["n_array_contraction"] == 0) ?
                                  percell_build : 0
    rec["debug"]                = first(debug, 40)
    rec["status"]               = ok ? "ok" : "build_error"
    return rec
end

# A trivial in-memory document, built once per worker before any real one. The
# first `esm_problem` call in a process loads the simulate extension and JITs
# the whole front door — minutes of work that would otherwise be charged to
# (and would time out) whichever document happened to be first in the shard.
# Embedded rather than read from `tests/` so the warm-up cannot itself be the
# pathological document, and so the script works from any working directory.
const WARMUP_DOC = Dict{String,Any}(
    "esm" => "1.0.0",
    "metadata" => Dict{String,Any}(
        "name" => "CensusWarmup",
        "description" => "Scalar decay, built once per worker to pay the front door's JIT.",
        "authors" => ["EarthSciAST Authors and Contributors"],
        "created" => "2026-09-21T00:00:00Z"),
    "models" => Dict{String,Any}("Warmup" => Dict{String,Any}(
        "variables" => Dict{String,Any}(
            "x" => Dict{String,Any}("type" => "unknown", "units" => "mol/mol",
                                    "default" => 1.0e-6),
            "k" => Dict{String,Any}("type" => "parameter", "units" => "1/s",
                                    "default" => 0.01)),
        "equations" => [Dict{String,Any}(
            "lhs" => Dict{String,Any}("op" => "D", "args" => ["x"], "wrt" => "t"),
            "rhs" => Dict{String,Any}("op" => "*",
                "args" => [Dict{String,Any}("op" => "-", "args" => ["k"]), "x"]))])))

function _warmup(M)
    try
        M.esm_problem(WARMUP_DOC, (0.0, 1.0))
    catch err
        println(stderr, "warm-up failed (continuing): ",
                first(sprint(showerror, err), 200))
    end
    M._reset_cascade_tally!()
    return nothing
end

# ─────────────────────────────────────────────────────────────────────────────
# Worker: load the package once, then walk a shard of the manifest.
# ─────────────────────────────────────────────────────────────────────────────
function run_worker(manifest::String, outpath::String, from::Int, to::Int)
    M = _load_esm()
    Base.invokelatest(_warmup, M)
    paths = readlines(manifest)
    open(outpath, "a") do io
        for i in from:min(to, length(paths))
            p = strip(paths[i])
            isempty(p) && continue
            # Progress marker FIRST: the driver reads it to know which document
            # is in flight, so a worker killed mid-build can be attributed.
            println(io, _jline(Dict{String,Any}(
                "marker" => "start", "index" => i, "path" => p,
                # WHOLE seconds: a `Float64` epoch prints as `1.7584e9`, and the
                # driver's `[0-9.]+` timestamp pattern would read that as
                # `1.7584` — an age of half a century, so it would kill the
                # worker on its first poll.
                "at" => floor(Int, time()))))
            flush(io)
            # `invokelatest`: the package was loaded by `_load_esm` AFTER this
            # function's world age, so every call into it needs the current world.
            rec = Base.invokelatest(_census_one, M, p)
            rec["index"] = i
            println(io, _jline(rec))
            flush(io)
            # A big build leaves a big heap behind; the next document should not
            # inherit it (and an OOM kill here costs one restart, not the shard).
            GC.gc()
        end
    end
    println(stderr, "worker $from:$to done")
    return 0
end

# ─────────────────────────────────────────────────────────────────────────────
# Driver.
# ─────────────────────────────────────────────────────────────────────────────
# The last progress marker in `f`, as `(index, path, started_at)`, or
# `nothing` when the worker wrote none.
function _last_start(f::String)
    isfile(f) || return nothing
    last = nothing
    for ln in eachline(f)
        occursin("\"marker\":\"start\"", ln) || continue
        i = match(r"\"index\":(\d+)", ln)
        a = match(r"\"at\":([0-9.]+)", ln)
        p = match(r"\"path\":\"([^\"]*)\"", ln)
        i === nothing && continue
        last = (parse(Int, i.captures[1]),
                p === nothing ? "" : p.captures[1],
                a === nothing ? time() : parse(Float64, a.captures[1]))
    end
    return last
end

# Indices already finished (a non-marker record) in `f`.
function _done_indices(f::String)
    s = Set{Int}()
    isfile(f) || return s
    for ln in eachline(f)
        occursin("\"marker\":\"start\"", ln) && continue
        m = match(r"\"index\":(\d+)", ln)
        m === nothing || push!(s, parse(Int, m.captures[1]))
    end
    return s
end

function run_shard(manifest::String, shard_out::String, from::Int, to::Int,
                   timeout_s::Int, script::String, project::String)
    i = from
    while i <= to
        cmd = Cmd(`$(Base.julia_cmd()) --project=$project --threads=2 $script
                   --worker $manifest $shard_out $i $to`)
        proc = run(pipeline(cmd; stdout = shard_out * ".out",
                            stderr = shard_out * ".err", append = true);
                   wait = false)
        killed_at = nothing
        while process_running(proc)
            sleep(2)
            st = _last_start(shard_out)
            if st !== nothing && (time() - st[3]) > timeout_s
                killed_at = st
                kill(proc, Base.SIGKILL)
                sleep(1)
                break
            end
        end
        wait(proc)
        done = _done_indices(shard_out)
        st = _last_start(shard_out)
        if st === nothing
            # The worker died before it even started a document (a load
            # failure); nothing more this shard can do.
            open(shard_out, "a") do io
                println(io, _jline(Dict{String,Any}(
                    "index" => i, "path" => "", "status" => "worker_load_failure",
                    "ok" => false, "n_interp_at_rhs" => 0, "percell_build" => 0)))
            end
            return
        end
        if st[1] in done
            # Clean finish of the last started document. Either the shard is
            # complete or the worker exited for another reason; continue after it.
            i = st[1] + 1
            i > to && return
            process_exited(proc) && proc.exitcode == 0 && return
        else
            # The in-flight document killed the worker.
            open(shard_out, "a") do io
                println(io, _jline(Dict{String,Any}(
                    "index" => st[1], "path" => st[2],
                    "status" => killed_at === nothing ? "crashed" : "timeout",
                    "ok" => false, "error_type" =>
                        killed_at === nothing ? "worker died (likely OOM)" :
                        "exceeded $(timeout_s)s",
                    "n_interp_at_rhs" => 0, "percell_build" => 0,
                    "build_seconds" => Float64(timeout_s))))
            end
            i = st[1] + 1
        end
    end
end

function run_driver(manifest::String, out::String; jobs::Int = 4,
                    timeout_s::Int = 180, resume::Bool = false,
                    project::String = dirname(@__DIR__))
    script = abspath(@__FILE__)
    n = count(!isempty, strip.(readlines(manifest)))
    per = cld(n, jobs)
    shards = String[]
    @sync for j in 1:jobs
        from = (j - 1) * per + 1
        to = min(j * per, n)
        from > to && continue
        so = out * ".shard$j"
        push!(shards, so)
        resume || (isfile(so) && rm(so))
        @async run_shard(manifest, so, from, to, timeout_s, script, project)
    end
    open(out, "w") do io
        for so in shards, ln in eachline(so)
            occursin("\"marker\":\"start\"", ln) || println(io, ln)
        end
    end
    println("census: $n documents -> $out")
end

# ─────────────────────────────────────────────────────────────────────────────
function main(args)
    if !isempty(args) && args[1] == "--worker"
        return run_worker(args[2], args[3], parse(Int, args[4]), parse(Int, args[5]))
    end
    if !isempty(args) && args[1] == "--one"
        M = _load_esm()
        Base.invokelatest(_warmup, M)
        println("##CENSUS## " * _jline(Base.invokelatest(_census_one, M, args[2])))
        return 0
    end
    manifest = out = nothing
    jobs, timeout_s, resume = 4, 180, false
    i = 1
    while i <= length(args)
        a = args[i]
        a == "--manifest" ? (manifest = args[i+1]; i += 2) :
        a == "--out"      ? (out = args[i+1];      i += 2) :
        a == "--jobs"     ? (jobs = parse(Int, args[i+1]); i += 2) :
        a == "--timeout"  ? (timeout_s = parse(Int, args[i+1]); i += 2) :
        a == "--resume"   ? (resume = true; i += 1) :
        error("compiler_census.jl: unknown argument '$a'")
    end
    (manifest === nothing || out === nothing) &&
        error("compiler_census.jl: --manifest and --out are required")
    run_driver(manifest, out; jobs = jobs, timeout_s = timeout_s, resume = resume)
    return 0
end

abspath(PROGRAM_FILE) == abspath(@__FILE__) && exit(main(ARGS))
