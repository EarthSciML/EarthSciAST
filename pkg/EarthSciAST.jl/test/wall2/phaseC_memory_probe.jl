# =============================================================================
# Wall #2 — Phase C memory + scaling probe (SAFE, bounded).
#
# Confirms the OOM regression is fixed: the compile-once construction at the
# representative contraction width (N_src=1520 — the width that OOM'd the machine)
# now allocates BOUNDED memory (shared const-array buffer, not one copy per term),
# and the per-cell eval is O(1) alloc so full-field eval is O(N_cells).
#
# Deliberately small N_rcv so the const array stays small and this probe can NEVER
# itself OOM — the OOM signature was O(N_terms · sizeof(A)) during a SINGLE compile,
# which this measures directly at N_src=1520 with a tiny A.
# =============================================================================
import Pkg; Pkg.activate(joinpath(@__DIR__, "..", ".."); io=devnull)
using EarthSciAST
const ESM = EarthSciAST

_v(n)  = VarExpr(String(n))
_num(x)= NumExpr(Float64(x))
_op(op, a...; kw...) = OpExpr(String(op), ESM.ASTExpr[a...]; kw...)
_idx(var, ix...) = _op("index", _v(var), [_v(String(s)) for s in ix]...)
make_conc(N_src) = _op("aggregate"; output_idx=Any["rcv"], semiring="sum_product",
    expr_body=_op("*", _idx("A","c","rcv"), _idx("E","c")),
    ranges=Dict{String,Any}("c"=>Any[1,N_src]))

const REG = Dict{String,Function}()
const NOPAR = Dict{String,Float64}()

rss_mb() = round(parse(Int, split(read(`ps -o rss= -p $(getpid())`, String))[1]) / 1024, digits=1)

println("="^78)
println("Wall #2 Phase C — memory + scaling probe   (Julia ", VERSION, ")")
println("start RSS = ", rss_mb(), " MiB")
println("="^78)

# ---- (1) COMPILE-STEP allocation at the OOM width N_src=1520 -----------------
# This is the exact operation that OOM'd: building the unrolled contraction with a
# gather per term. With the fix each gather ALIASES the one shared A buffer.
const NSRC = 1520
const A_small = rand(NSRC, 100)          # 1.2 MiB array; 1520 terms gather into it
const E_small = rand(NSRC)
const CA = Dict{String,Any}("A"=>A_small, "E"=>E_small)
const conc = make_conc(NSRC)

ESM._cellwise_compile_once(conc, 1, CA, REG, NOPAR)   # warm (compile once)
comp_alloc = @allocated (ce = ESM._cellwise_compile_once(conc, 1, CA, REG, NOPAR))
comp_mib = comp_alloc / 2^20
println("\n[1] COMPILE-ONCE @ N_src=", NSRC, " (the OOM operation):")
println("    compile allocation = ", round(comp_mib, digits=2), " MiB   (A itself = ",
        round(sizeof(A_small)/2^20, digits=2), " MiB)")
# Buggy path would be ~N_src × sizeof(A) ≈ 1520 × 1.2 = ~1800 MiB. Fixed ≪ that.
BUG_FLOOR = NSRC * sizeof(A_small) / 2^20 * 0.5     # half the buggy lower bound
if comp_mib < BUG_FLOOR
    println("    ✓ BOUNDED — far below the buggy ~", round(NSRC*sizeof(A_small)/2^20), " MiB (per-term copy) signature")
else
    println("    ✗ STILL SCALING WITH N_terms × sizeof(A) — OOM NOT FIXED"); exit(1)
end
println("    RSS after compile = ", rss_mb(), " MiB")

# ---- (2) per-cell eval is allocation-free at N_src=1520 ----------------------
# NB: the cell arg must be PRE-BOUND — a literal `ce([37])` would allocate the
# 1-element Vector{Int} argument (~80 B) and pollute the eval measurement.
const CELL = [37]
ce(CELL); ce(CELL)
ev_alloc = @allocated ce(CELL)
println("\n[2] per-cell eval alloc @ N_src=", NSRC, " = ", ev_alloc, " bytes  ",
        ev_alloc == 0 ? "✓ zero-alloc" : "✗ allocates")

# ---- (3) eval scaling — compile-once path only, O(N_cells) -------------------
println("\n[3] full-field eval via compile-once (bounded memory):")
for nrcv in (1000, 5000)
    A = rand(NSRC, nrcv); ca = Dict{String,Any}("A"=>A, "E"=>E_small)
    cells = [[r] for r in 1:nrcv]
    ESM.evaluate_cellwise(conc, cells[1:2]; const_arrays=ca)   # warm
    g = Base.gc_num(); t0 = time_ns()
    out = ESM.evaluate_cellwise(conc, cells; const_arrays=ca)
    dt = (time_ns()-t0)/1e9; d = Base.GC_Diff(Base.gc_num(), g)
    @assert length(out) == nrcv
    println("    N_rcv=", lpad(nrcv,5), "  ", lpad(round(dt,digits=3),7), " s   ",
            lpad(round(d.allocd/2^20,digits=1),8), " MiB   (",
            round(dt/nrcv*1e6,digits=2), " µs/cell)   RSS=", rss_mb(), " MiB")
end

println("\n[4] projection to full ISRM scale (N_rcv=52411, ×5 pathways):")
println("    Phase A baseline (old per-cell path): ~350 s & ~50 GiB churn PER pathway.")
println("    compile-once path is O(N_cells): extrapolate from [3] above.")
println("\nend RSS = ", rss_mb(), " MiB")
println("PROBE DONE.")
