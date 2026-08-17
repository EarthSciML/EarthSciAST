# DOES REVERSE MODE CROSS THE NON-`while` LOOP SHAPES?
#
# loopshape.jl measured what each site emits:
#   host `for` (static)            -> NO region; straight-line unroll
#   `@trace for` (STATIC range)    -> stablehlo.while           (!)
#   `@trace while`                 -> stablehlo.while
#   sum / mapreduce                -> stablehlo.reduce
#   cumsum                         -> stablehlo.reduce_window   (an associative scan)
#   ESM `_apply_scan_folds_oop`    -> NO region; slice+scatter, grid-independent
#   ESM `:oop` contraction loop    -> NO region; unrolled, O(M)
#
# So the only `stablehlo.while` in this stack is `@trace`. This probe checks the
# other side: for each shape that is NOT a while, does Enzyme reverse actually
# cross it, and does it agree with ForwardDiff?
#
#   G1  reduce            (sum)
#   G2  reduce            (mapreduce max -- a non-`+` combiner body)
#   G3  reduce_window     (cumsum)  <- the one scan-shaped op StableHLO has
#   G4  ESM prefix scan fold
#   G5  ESM :oop RHS with a runtime contraction loop
#   G6  @trace for over a STATIC range   -- expected to FAIL, same as while
#   G7  @trace if (stablehlo.if)         -- can reverse cross a BRANCH region?
#   G8  a MASKED fixed-max-count unrolled adaptive stepper -- the while-free way
#       to write an accept/reject controller. Trip count is data-dependent in
#       VALUE, but the trace has a static bound and every step past termination
#       is an `ifelse` no-op. If reverse crosses this, an adaptive loop does not
#       need a while region at all -- it needs a bound.
import Pkg
Pkg.activate("/tmp/claude-1111265/scanad-env"; io = devnull)
using Reactant, ForwardDiff, Printf
const Enzyme = Reactant.Enzyme
const RX = Reactant
try; RX.set_default_backend("cpu"); catch; end
say(s) = (println(s); flush(stdout))
ok(t, g, m) = say(@sprintf("  [%s] %-22s %s", g ? "PASS" : "FAIL", t, m))
err1(e) = first(split(sprint(showerror, e), '\n'))

# One scalar parameter `k`, one array input held Const, scalar output. `href` is
# the SAME algorithm on the host, differentiated with ForwardDiff.
function check(tag, f, u0::Vector{Float64}, k0::Float64, href; rtol = 1e-8)
    gref = ForwardDiff.derivative(href, k0)
    try
        ur = RX.ConcreteRArray(u0); kr = RX.ConcreteRNumber(k0)
        g = (u, k) -> Enzyme.gradient(Enzyme.Reverse, f, Enzyme.Const(u), k)[2]
        t0 = time()
        xg = RX.@compile sync = true g(ur, kr)
        tc = time() - t0
        got = Float64(xg(ur, kr))
        ok(tag, isapprox(got, gref; rtol = rtol),
           @sprintf("got %.12g want %.12g  (compile %.1f s)", got, gref, tc))
    catch e
        ok(tag, false, err1(e))
    end
end

const N = 8
const H = 0.01
u0 = [0.5 + 0.1i for i in 1:N]
k0 = 0.7

say("=== bare Reactant shapes ===")

# G1 stablehlo.reduce
check("G1 reduce(sum)", (u, k) -> sum(k .* u .^ 2), u0, k0,
      kk -> sum(kk .* u0 .^ 2))

# G2 stablehlo.reduce with a max body -- a NON-additive combiner region.
check("G2 reduce(max)", (u, k) -> mapreduce(x -> k * x^2, max, u), u0, k0,
      kk -> mapreduce(x -> kk * x^2, max, u0))

# G3 stablehlo.reduce_window -- the associative prefix scan.
check("G3 reduce_window(cumsum)", (u, k) -> sum(cumsum(k .* u .^ 2)), u0, k0,
      kk -> sum(cumsum(kk .* u0 .^ 2)))

# G6 @trace for over a STATIC range. Emits a while region (measured), so this is
# the control: a compile-time-known trip count is NOT what makes reverse work.
function g6(u, k)
    RX.@trace track_numbers = false for _ in 1:5
        u = u .+ k .* u .* H
    end
    sum(u)
end
check("G6 @trace for(static)", g6, u0, k0,
      kk -> (u = copy(u0); for _ in 1:5; u = u .+ kk .* u .* H; end; sum(u)))

# G7 @trace if -- a BRANCH region, not a loop. The adaptive controller's
# accept/reject is a branch; worth knowing separately from the loop.
function g7(u, k)
    s = sum(u)
    r = zero(k)
    RX.@trace if s > 1.0
        r = k * s
    else
        r = k * s * 2
    end
    r
end
check("G7 @trace if", g7, u0, k0, kk -> (s = sum(u0); s > 1.0 ? kk * s : kk * s * 2))

# G8 MASKED, host-unrolled, fixed MAXIMUM step count. This is an adaptive loop
# with the while region removed: the controller still decides, but its decision
# becomes a `select` on the state instead of a branch on the trip count. Steps
# after termination reproduce the state exactly, so the value is the adaptive
# loop's value.
const NMAX = 40
function g8(u, k)
    t = zero(k); tlim = one(k)
    for _ in 1:NMAX
        # step-size controller: h shrinks where the state is large (a stand-in
        # for an error estimate), and is clipped so it cannot overshoot tlim.
        e = sum(abs2, u)
        h = min(0.05 / (1 + k * e), tlim - t)
        live = t < tlim                     # traced predicate, NOT control flow
        hh = ifelse(live, h, zero(h))
        u = u .+ k .* u .* hh
        t = t + hh
    end
    sum(u)
end
function g8_host(kk)
    u = copy(u0); t = 0.0; tlim = 1.0
    for _ in 1:NMAX
        e = sum(abs2, u)
        h = min(0.05 / (1 + kk * e), tlim - t)
        hh = t < tlim ? h : zero(h)
        u = u .+ kk .* u .* hh
        t = t + hh
    end
    sum(u)
end
check("G8 masked unroll x$NMAX", g8, u0, k0, g8_host; rtol = 1e-6)

say("")
say("=== EarthSciAST emitter sites ===")
using EarthSciAST
const ESM = EarthSciAST
_sf(nlanes, len; inclusive = true, oplus = :+, zerobar = 0.0) =
    ESM._ScanFold(Int[(l - 1) * len + k for l in 1:nlanes for k in 1:len],
                  len, oplus, zerobar, inclusive)

# G4 the prefix scan fold. Scale the input by `k` so there is something to
# differentiate w.r.t.; the fold itself is what reverse has to cross.
let nl = 4, len = 17
    S = _sf(nl, len)
    v = Float64[0.3 + 0.01i for i in 1:(nl * len)]
    f = (u, k) -> sum(ESM._apply_scan_folds_oop(k .* u, [S]))
    href = kk -> sum(ESM._apply_scan_folds_oop(kk .* v, [S]))
    check("G4 ESM scan fold", f, v, 0.7, href)
end

# G5 the :oop RHS with a runtime contraction loop.
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
let M = 64
    f, uc, p, _, _ = withenv("ESS_CONTRACTION_LOOP" => "1",
                             "ESS_CONTRACTION_LOOP_MIN" => "8") do
        ESM.build_evaluator(_cl_doc(M); initial_conditions = Dict("x" => 2.0,
                                                                 "s" => 0.0),
                            form = :oop)
    end
    uv = collect(Float64, uc)
    # Scale the state by `k`: du[s] = k*x0*M(M+1)/2, so d/dk is exact and known.
    fk = (u, k) -> sum(f(k .* u, p, 0.0))
    href = kk -> sum(f(kk .* uv, p, 0.0))
    check("G5 ESM contract loop", fk, uv, 0.7, href)
end
say("REDUCEGRAD_DONE")
