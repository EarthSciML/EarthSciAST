# =============================================================================
# Wall #2 — Phase A: scaling benchmark + type-instability + profiler attribution
# =============================================================================
#
# REPRODUCES (does NOT fix) the ISRM diagnostic-observed build-time blowup.
#
# The ISRM diagnostics TotalPM25 / deathsK / deathsL are ObservedVariables whose
# field is materialised at build time by
#   _observed_field  (src/pde_inline_tests.jl)
#     -> evaluate_cellwise  (src/pde_inline_tests.jl:110)
#       -> _eval_cellwise   (src/tree_walk/helpers.jl:533)   [ONE output cell at a time]
#         -> _index_at_cell -> _resolve_indices -> _compile -> _eval_node
#
# For an observed defined by a CONTRACTING aggregate over const arrays
#   conc[rcv] = Σ_c A[c,rcv] * E[c]
# _resolve_index_of_arrayop (src/tree_walk/resolve.jl:258) unrolls the contraction
# into an N_src-wide `+` term-tree PER output cell, and _compile const-folds every
# A[c,rcv] / E[c] const-array read into a distinct _NK_LITERAL keyed by THAT cell's
# indices. So the entire N_src-wide tree is rebuilt AND recompiled for every one of
# the N_rcv output cells => O(N_rcv * N_src) alloc-heavy recompilation on the
# dynamically-typed ASTExpr path.
#
# This script drives the ACTUAL hot path (evaluate_cellwise / _eval_cellwise) via a
# faithful hand-built aggregate ASTExpr, and:
#   (1) sweeps N_rcv and N_src, recording wall-time + alloc count/bytes,
#   (2) proves the O(N_rcv * N_src) recompile signature,
#   (3) captures @code_warntype evidence of Any / abstract-ASTExpr inference,
#   (4) attributes time with the base `Profile` profiler.
#
# Runnable standalone:  julia --project test/wall2/phaseA_scaling_bench.jl
# =============================================================================

using EarthSciAST
using InteractiveUtils
using Profile
using Printf

const EA = EarthSciAST

# ---- AST construction helpers -----------------------------------------------
_v(n)  = VarExpr(String(n))
_n(x)  = NumExpr(Float64(x))
_op(op, args...; kw...) = OpExpr(String(op), EA.ASTExpr[args...]; kw...)
# index(var, i, j, ...) with loop-var names
_idxv(var, ix...) = _op("index", _v(var), [_v(String(s)) for s in ix]...)

# conc[rcv] = Σ_c A[c,rcv] * E[c]   — a CONTRACTING aggregate over const arrays.
#   output index : rcv   (the per-output-cell index)
#   contracted   : c     (range [1, N_src], const int range => no index_sets needed)
function make_conc_agg(N_src::Int)
    body = _op("*", _idxv("A", "c", "rcv"), _idxv("E", "c"))
    return _op("aggregate"; output_idx=Any["rcv"], semiring="sum_product",
               expr_body=body, ranges=Dict{String,Any}("c" => Any[1, N_src]))
end

# out[rcv] = exp(k * conc[rcv]) - 1   — downstream ELEMENTWISE observed wrapping the
# contraction, standing in for the deathsK/deathsL formula. _index_at_cell descends
# the elementwise ops (-, exp, *) and wraps the inner aggregate producer in
# index(agg, rcv), so the full contraction still recompiles per cell.
function make_deaths_expr(N_src::Int; k::Float64 = 1e-3)
    agg = make_conc_agg(N_src)
    return _op("-", _op("exp", _op("*", _n(k), agg)), _n(1.0))
end

# const arrays: A is (N_src, N_rcv), E is length N_src.
function make_const_arrays(N_src::Int, N_rcv::Int)
    A = Matrix{Float64}(undef, N_src, N_rcv)
    @inbounds for j in 1:N_rcv, i in 1:N_src
        A[i, j] = (i + 0.5 * j) * 1e-4
    end
    E = Float64[0.1 * i for i in 1:N_src]
    return Dict{String,Any}("A" => A, "E" => E)
end

# ---- Measurement primitive (mirrors what @time reports: wall, bytes, allocs) -
function measure(f)
    GC.gc()
    a0 = Base.gc_num(); t0 = time_ns()
    val = f()
    t1 = time_ns(); a1 = Base.gc_num()
    d = Base.GC_Diff(a1, a0)
    return (value = val,
            time   = (t1 - t0) / 1e9,
            bytes  = d.allocd,
            allocs = Base.gc_alloc_count(d))
end

run_conc(N_src, N_rcv; k=1e-3) = begin
    ca    = make_const_arrays(N_src, N_rcv)
    expr  = make_conc_agg(N_src)
    cells = [[r] for r in 1:N_rcv]
    measure(() -> EA.evaluate_cellwise(expr, cells; const_arrays=ca))
end

run_deaths(N_src, N_rcv; k=1e-3) = begin
    ca    = make_const_arrays(N_src, N_rcv)
    expr  = make_deaths_expr(N_src; k=k)
    cells = [[r] for r in 1:N_rcv]
    measure(() -> EA.evaluate_cellwise(expr, cells; const_arrays=ca))
end

fmt_bytes(b) = b < 1e3  ? @sprintf("%d B",   b)   :
               b < 1e6  ? @sprintf("%.1f KiB", b/1024) :
               b < 1e9  ? @sprintf("%.1f MiB", b/1024^2) :
                          @sprintf("%.2f GiB", b/1024^3)
fmt_int(n)   = replace(@sprintf("%d", round(Int, n)), r"(?<=\d)(?=(\d{3})+$)" => ",")

function print_row(label, N_src, N_rcv, r)
    percell = r.allocs / (N_rcv)
    @printf("  %-10s  N_src=%-5d  N_rcv=%-6d  |  %9.4f s   %11s   %s allocs   (%.2f allocs/cell)\n",
            label, N_src, N_rcv, r.time, fmt_bytes(r.bytes), fmt_int(r.allocs), percell)
end

println("="^92)
println("Wall #2 Phase A — scaling benchmark on evaluate_cellwise / _eval_cellwise hot path")
println("Julia ", VERSION)
println("="^92)

# ---- Warm up JIT (compile the whole path once, tiny) ------------------------
run_conc(4, 4); run_deaths(4, 4)
println("\n[warmup done]\n")

# ---- Sweep 1: N_rcv at fixed N_src -------------------------------------------
const NSRC_FIXED = 1520          # ISRM-representative contraction width (per pathway)
const NRCV_SWEEP = [100, 1000, 10000]
println("SWEEP 1 — vary N_rcv (output cells) at fixed N_src=$(NSRC_FIXED):")
sweep1_conc   = Tuple{Int,Int,Any}[]
sweep1_deaths = Tuple{Int,Int,Any}[]
for nrcv in NRCV_SWEEP
    r = run_conc(NSRC_FIXED, nrcv);  push!(sweep1_conc,   (NSRC_FIXED, nrcv, r)); print_row("conc",   NSRC_FIXED, nrcv, r)
    d = run_deaths(NSRC_FIXED, nrcv); push!(sweep1_deaths, (NSRC_FIXED, nrcv, d)); print_row("deaths", NSRC_FIXED, nrcv, d)
end

# ---- Sweep 2: N_src at fixed N_rcv -------------------------------------------
const NRCV_FIXED = 1000
const NSRC_SWEEP = [100, 500, 1520]
println("\nSWEEP 2 — vary N_src (contraction width) at fixed N_rcv=$(NRCV_FIXED):")
sweep2_conc = Tuple{Int,Int,Any}[]
for nsrc in NSRC_SWEEP
    r = run_conc(nsrc, NRCV_FIXED); push!(sweep2_conc, (nsrc, NRCV_FIXED, r)); print_row("conc", nsrc, NRCV_FIXED, r)
end

# ---- Per-cell-per-source normalisation (the O(N_rcv*N_src) signature) --------
println("\nNORMALISED cost  time / (N_rcv * N_src)  and  allocs / (N_rcv * N_src):")
println("  (flat across BOTH sweeps  =>  cost is O(N_rcv * N_src), NOT O(N_rcv + N_src))")
function print_norm(tag, rows)
    for (ns, nr, r) in rows
        prod = ns * nr
        @printf("    %-8s N_src=%-5d N_rcv=%-6d  time/cell/src=%6.3f ns   allocs/cell/src=%6.3f\n",
                tag, ns, nr, r.time/prod*1e9, r.allocs/prod)
    end
end
print_norm("conc",   sweep1_conc)
print_norm("conc",   sweep2_conc)
print_norm("deaths", sweep1_deaths)

# ---- Full-scale point (N_rcv=52,411) — measure if tractable, else extrapolate -
const N_RCV_FULL = 52411
# Use conc @ (1520, 10000) to project.
proj_base = last(sweep1_conc)[3]                       # (1520, 10000)
proj_time = proj_base.time * (N_RCV_FULL / 10000)
proj_allo = proj_base.allocs * (N_RCV_FULL / 10000)
println("\nFULL-SCALE PROJECTION (single pathway, N_src=1520, N_rcv=52411):")
@printf("  projected time  ~ %.1f s   projected allocs ~ %s   (x5 pathways ~ %.0f s)\n",
        proj_time, fmt_int(proj_allo), 5 * proj_time)
const FULL_BUDGET_S = 240.0
if proj_time < FULL_BUDGET_S
    println("  projected < $(FULL_BUDGET_S)s budget -> MEASURING full point directly:")
    rfull = run_conc(1520, N_RCV_FULL)
    print_row("conc", 1520, N_RCV_FULL, rfull)
    @printf("    measured/projected time ratio = %.2f\n", rfull.time / proj_time)
else
    println("  projected >= $(FULL_BUDGET_S)s budget -> NOT run; extrapolation above stands.")
end

# =============================================================================
# TYPE-INSTABILITY PROOF
# =============================================================================
println("\n", "="^92)
println("TYPE-INSTABILITY PROOF — @code_warntype on the _eval_cellwise body")
println("="^92)

# Faithful replica of the isempty(params) branch of _eval_cellwise (helpers.jl:537-544)
# so @code_warntype can descend into the exact per-cell pipeline.
function probe_eval(expr::EA.ASTExpr, cell::Vector{Int}, ca::AbstractDict)
    cellwise = EA._index_at_cell(expr, cell)
    resolved = EA._resolve_indices(cellwise,
                    Dict{String,Tuple{Vector{Int},Vector{Int}}}(),
                    Dict{String,Int}(), ca)
    reg  = Dict{String,Any}()
    node = EA._compile(resolved, Dict{String,Int}(), Set{Symbol}(), reg)
    return EA._eval_node(node, Float64[], NamedTuple(), 0.0)
end

let ca = make_const_arrays(1520, 4), agg = make_conc_agg(1520)
    probe_eval(agg, [1], ca)   # warm

    buf = IOBuffer()
    code_warntype(buf, probe_eval, Tuple{EA.ASTExpr, Vector{Int}, Dict{String,Any}})
    wt = String(take!(buf))
    println("\n--- @code_warntype probe_eval(::ASTExpr, ::Vector{Int}, ::Dict) ---")
    println(wt)

    # Machine-checkable summary: return-type inference of the hot-path calls.
    println("--- Base.return_types of the per-cell pipeline stages ---")
    for (nm, f, T) in (
        ("_index_at_cell", EA._index_at_cell, Tuple{EA.ASTExpr, Vector{Int}}),
        ("_resolve_indices", EA._resolve_indices,
            Tuple{EA.ASTExpr, Dict{String,Tuple{Vector{Int},Vector{Int}}}, Dict{String,Int}, Dict{String,Any}}),
        ("_compile", EA._compile,
            Tuple{EA.ASTExpr, Dict{String,Int}, Set{Symbol}, Dict{String,Any}}),
    )
        rts = Base.return_types(f, T)
        concrete = all(isconcretetype, rts)
        @printf("  %-18s -> %-40s  concrete=%s\n", nm, string(rts), concrete)
    end
    # Is the whole probe inferrable to a concrete Float64?
    prts = Base.return_types(probe_eval, Tuple{EA.ASTExpr, Vector{Int}, Dict{String,Any}})
    @printf("  %-18s -> %-40s\n", "probe_eval", string(prts))
end

# =============================================================================
# PROFILER ATTRIBUTION (base Profile) at the largest tractable N
# =============================================================================
println("\n", "="^92)
println("PROFILER ATTRIBUTION — base Profile @ N_src=1520, N_rcv=10000 (conc)")
println("="^92)
let
    ca    = make_const_arrays(1520, 10000)
    expr  = make_conc_agg(1520)
    cells = [[r] for r in 1:10000]
    EA.evaluate_cellwise(expr, cells[1:4]; const_arrays=ca)   # warm
    Profile.clear()
    Profile.init(; n = 10_000_000, delay = 0.001)
    @profile EA.evaluate_cellwise(expr, cells; const_arrays=ca)

    println("\n--- flat profile (top frames by self-count, EarthSciAST/tree_walk only) ---")
    buf = IOBuffer()
    Profile.print(IOContext(buf, :displaysize => (120, 240));
                  format = :flat, sortedby = :count, mincount = 20)
    flat = String(take!(buf))
    # Print header + rows that mention the hot-path functions, to attribute time.
    lines = split(flat, '\n')
    for (i, ln) in enumerate(lines)
        if i <= 2 || occursin("resolve", ln) || occursin("_compile", ln) ||
           occursin("_index_at_cell", ln) || occursin("evaluate_cellwise", ln) ||
           occursin("_eval_cellwise", ln) || occursin("_combine", ln) ||
           occursin("_foreach_aggregate", ln) || occursin("_mknode", ln) ||
           occursin("_resolve_index_of_arrayop", ln) || occursin("reconstruct", ln) ||
           occursin("_sub_preserving", ln) || occursin("canonical", ln)
            println(ln)
        end
    end

    # Coarse attribution: count backtrace samples that pass through each stage.
    data, _ = Profile.retrieve()
    li = Profile.getdict(data)
    function frac_through(needle)
        total = 0; hit = 0
        # Walk sample blocks (0-separated) and mark a block if any frame matches.
        blockhit = false; nblocks = 0
        for ip in data
            if ip == 0
                nblocks += 1
                blockhit && (hit += 1)
                blockhit = false
            else
                frames = get(li, ip, nothing)
                if frames !== nothing
                    for fr in frames
                        occursin(needle, String(fr.func)) && (blockhit = true)
                    end
                end
            end
        end
        return hit, nblocks
    end
    println("\n--- fraction of sampled call-stacks passing through each stage ---")
    for stage in ("_resolve_index_of_arrayop", "_resolve_indices", "_compile",
                  "_index_at_cell", "_combine_with_reducer", "_foreach_aggregate_term",
                  "reconstruct", "_sub_preserving")
        h, nb = frac_through(stage)
        nb == 0 && (nb = 1)
        @printf("  %-28s %6.1f%%  of stacks\n", stage, 100 * h / nb)
    end
end

println("\n", "="^92)
println("DONE — see test/wall2/phaseA_findings.md for the written-up verdict.")
println("="^92)
