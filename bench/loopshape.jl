# WHAT MLIR DOES EACH LOOP-SHAPED SITE ACTUALLY EMIT?
#
# Reverse mode cannot cross a `stablehlo.while` (whilegrad.jl: K1/K2 FAIL for a
# fixed AND a data-dependent trip count; K3 shows forward crosses the same loop
# exactly). That single fact is what forced the host-lifted adjoint architecture.
# Before redesigning anything, MEASURE which sites actually emit a while region.
#
# Census of `@code_hlo optimize=false` — pre-canonicalization, so this is what the
# emitter WROTE, not what XLA rewrote it into.
#
#   L1  host Julia `for` over a static range      -- the `_oop_contraction_loop`
#                                                    and `_scan_lanes_oop` shape
#   L2  `RX.@trace for i in 1:N`  (STATIC range)  -- what rx_traced_integrator's
#                                                    stage loop uses
#   L3  `RX.@trace while`                          -- the adaptive_solve shape
#   L4  `sum(x)`                                   -- stablehlo.reduce
#   L5  `mapreduce` with a non-`+` combiner        -- stablehlo.reduce, custom body
#   L6  `cumsum(x)`                                -- an associative SCAN: which op?
#   L7  EarthSciAST `_apply_scan_folds_oop`        -- the real prefix-scan emitter
#   L8  EarthSciAST `:oop` RHS w/ runtime contraction loop -- the real reduction
import Pkg
Pkg.activate("/tmp/claude-1111265/scanad-env"; io = devnull)
using Reactant, Printf
const RX = Reactant
try; RX.set_default_backend("cpu"); catch; end
say(s) = (println(s); flush(stdout))
err1(e) = first(split(sprint(showerror, e), '\n'))

const REGION_OPS = ("stablehlo.while", "stablehlo.reduce", "stablehlo.reduce_window",
                    "stablehlo.if", "stablehlo.case", "stablehlo.scatter",
                    "stablehlo.sort", "stablehlo.map", "stablehlo.select_and_scatter")
const BULK_OPS = ("stablehlo.add", "stablehlo.multiply", "stablehlo.slice",
                  "stablehlo.dynamic_slice", "stablehlo.dynamic_update_slice",
                  "stablehlo.constant", "stablehlo.concatenate", "stablehlo.pad")

# `stablehlo.reduce` is a PREFIX of `stablehlo.reduce_window`/`reduce_precision`,
# so count on a word boundary or the census lies.
_count(s, op) = length(collect(eachmatch(Regex(op * "\\b"), s)))

function census(tag, s)
    reg = [(op, _count(s, op)) for op in REGION_OPS]
    bulk = [(op, _count(s, op)) for op in BULK_OPS]
    say(@sprintf("  %-28s  lines=%-6d", tag, count(==('\n'), s) + 1))
    r = join([@sprintf("%s=%d", replace(o, "stablehlo." => ""), n)
              for (o, n) in reg if n > 0], " ")
    b = join([@sprintf("%s=%d", replace(o, "stablehlo." => ""), n)
              for (o, n) in bulk if n > 0], " ")
    say("      REGION: " * (isempty(r) ? "(none)" : r))
    say("      bulk  : " * (isempty(b) ? "(none)" : b))
    return Dict(o => n for (o, n) in vcat(reg, bulk))
end

function hlo(tag, f, args...)
    try
        s = repr(RX.@code_hlo optimize = false f(args...))
        return census(tag, s), s
    catch e
        say(@sprintf("  %-28s  ERROR %s", tag, err1(e)))
        return nothing, ""
    end
end

const N = 8
const H = 0.01
u0 = [0.5 + 0.1i for i in 1:N]

say("=== L1..L6  bare Reactant loop shapes ===")

# L1: a plain HOST Julia for over a compile-time range. Nothing traced about the
# loop itself; the body is re-traced per iteration, so the trace is straight-line.
l1(u, k) = (for _ in 1:5; u = u .+ k .* u .* H; end; sum(u))
hlo("L1 host for (static)", l1, RX.ConcreteRArray(u0), RX.ConcreteRNumber(0.7))

# L2: `@trace for` over a STATIC range. Does the macro still emit a while region?
function l2(u, k)
    RX.@trace track_numbers = false for _ in 1:5
        u = u .+ k .* u .* H
    end
    sum(u)
end
hlo("L2 @trace for (static)", l2, RX.ConcreteRArray(u0), RX.ConcreteRNumber(0.7))

# L3: `@trace while` -- the known-bad shape, for contrast.
function l3(u, k, nlim)
    i = zero(k)
    RX.@trace while i < nlim
        u = u .+ k .* u .* H
        i = i + one(k)
    end
    sum(u)
end
hlo("L3 @trace while", l3, RX.ConcreteRArray(u0), RX.ConcreteRNumber(0.7),
    RX.ConcreteRNumber(5.0))

# L4/L5: genuine reductions.
hlo("L4 sum", u -> sum(u), RX.ConcreteRArray(u0))
hlo("L5 mapreduce max", u -> mapreduce(abs, max, u), RX.ConcreteRArray(u0))

# L6: cumsum -- the canonical ASSOCIATIVE scan. Whatever op this is, it is the
# one candidate StableHLO offers for a carry recurrence.
hlo("L6 cumsum", u -> sum(cumsum(u)), RX.ConcreteRArray(u0))

say("")
say("=== L7  EarthSciAST prefix scan (_apply_scan_folds_oop) ===")
using EarthSciAST
const ESM = EarthSciAST
_sf(nlanes, len; inclusive = true, oplus = :+, zerobar = 0.0) =
    ESM._ScanFold(Int[(l - 1) * len + k for l in 1:nlanes for k in 1:len],
                  len, oplus, zerobar, inclusive)
for (nl, len) in ((4, 17), (91, 17))
    S = _sf(nl, len)
    g = du -> sum(ESM._apply_scan_folds_oop(du, [S]))
    hlo(@sprintf("L7 scanfold %dx%d", nl, len), g, RX.ConcreteRArray(zeros(nl * len)))
end

say("")
say("=== L8  EarthSciAST :oop RHS with a runtime contraction loop ===")
# The doc from test/contraction_loop_test.jl: D(s)/dt = Sum_{k=0..M} (k*x).
# ESS_CONTRACTION_LOOP=1 + MIN=8 forces the RUNTIME LOOP node rather than the
# build-time unroll, so `_oop_contraction_loop` is the site under test.
_cl_doc(M::Int) = Dict{String,Any}(
    "esm" => "0.8.0",
    "metadata" => Dict("name" => "contraction_loop_repro"),
    "models" => Dict("Repro" => Dict{String,Any}(
        "variables" => Dict("x" => Dict("type" => "state"),
                            "s" => Dict("type" => "state")),
        "equations" => Any[
            Dict("lhs" => Dict("op" => "D", "args" => Any["x"], "wrt" => "t"),
                 "rhs" => 0.0),
            Dict("lhs" => Dict("op" => "D", "args" => Any["s"], "wrt" => "t"),
                 "rhs" => Dict("op" => "aggregate", "semiring" => "sum_product",
                               "args" => Any[], "output_idx" => Any[],
                               "ranges" => Dict("k" => Any[0, M]),
                               "expr" => Dict("op" => "*", "args" => Any["k", "x"]))),
        ],
    )),
)
for M in (16, 64)
    for loop in (true, false)
        try
            f, u0c, p, _, _ = withenv("ESS_CONTRACTION_LOOP" => (loop ? "1" : "0"),
                                      "ESS_CONTRACTION_LOOP_MIN" => "8") do
                ESM.build_evaluator(_cl_doc(M); initial_conditions = Dict("x" => 2.0,
                                                                         "s" => 0.0),
                                    form = :oop)
            end
            g = u -> sum(f(u, p, 0.0))
            hlo(@sprintf("L8 contract M=%d loop=%d", M, loop), g,
                RX.ConcreteRArray(collect(Float64, u0c)))
        catch e
            say(@sprintf("  L8 M=%d loop=%d  ERROR %s", M, loop, err1(e)))
        end
    end
end
say("LOOPSHAPE_DONE")
