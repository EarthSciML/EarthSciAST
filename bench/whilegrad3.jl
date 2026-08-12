# THE PREMISE WAS WRONG. Reverse mode CAN cross a `stablehlo.while`.
#
# whilegrad.jl concluded "reverse cannot cross a while REGION, because even a
# FIXED trip count fails". But K1's trip count was `nr = ConcreteRNumber(20.0)`
# -- a runtime ARGUMENT. Fixed in the sense that the caller passes the same
# number every time; not fixed in the only sense MLIR cares about, which is
# "statically known at compile time". reducegrad.jl G6 then crossed a
# `RX.@trace for _ in 1:5` -- which loopshape.jl measured as emitting
# `stablehlo.while=1` -- exactly, in 7.4 s.
#
# Enzyme-MLIR's reverse rule for WhileOp (`AutoDiffWhileRev`, present in the
# libReactantExtra.so in this depot) tapes the trajectory into a DENSE `[N, ...]`
# tensor, so N must be statically known or the tape is `tensor<?x...>`, which XLA
# cannot translate. Hence:
#
#   W1  @trace while, bound a HOST CONSTANT        -> static N, expect PASS
#   W2  @trace while, bound a TRACED ARGUMENT      -> the whilegrad.jl K1 case
#   W3  W2 + checkpointing=Periodic(n)             -> documented fix for while
#   W4  W2 + checkpointing=Binomial(k)
#   W5  DATA-DEPENDENT trip count (the K2/adaptive_solve shape), plain
#   W6  W5 + Periodic(n)
#   W7  W5 + Binomial(k)
#   W8  the FULL error text of a failure, to identify WHICH limit is hit
#   W9  does the DIFFERENTIATED program still contain a while region, or did
#       Enzyme unroll it away? (Otherwise W1 proves nothing about while-AD.)
import Pkg
Pkg.activate("/tmp/claude-1111265/scanad-env"; io = devnull)
using Reactant, ForwardDiff, Printf
const Enzyme = Reactant.Enzyme
const RX = Reactant
try; RX.set_default_backend("cpu"); catch; end
say(s) = (println(s); flush(stdout))
ok(t, g, m) = say(@sprintf("  [%s] %-26s %s", g ? "PASS" : "FAIL", t, m))
err1(e) = first(split(sprint(showerror, e), '\n'))

const N = 6
const H = 0.01
const NSTEP = 20
u0 = [0.5 + 0.1i for i in 1:N]
k0 = 0.7

host_fixed(u, k, n) = (for _ in 1:n; u = u .+ k .* u .* H; end; sum(u))
const GREF_FIXED = ForwardDiff.derivative(kk -> host_fixed(u0, kk, NSTEP), k0)

# `f` takes (u, k) and any extra Const args; compare reverse against `gref`.
function rev(tag, f, gref, extra...; rtol = 1e-8, verbose = false)
    try
        ur = RX.ConcreteRArray(u0); kr = RX.ConcreteRNumber(k0)
        g = (u, k, e...) -> Enzyme.gradient(Enzyme.Reverse, f, Enzyme.Const(u), k,
                                            map(Enzyme.Const, e)...)[2]
        t0 = time()
        xg = RX.@compile sync = true g(ur, kr, extra...)
        tc = time() - t0
        got = Float64(xg(ur, kr, extra...))
        ok(tag, isapprox(got, gref; rtol = rtol),
           @sprintf("got %.12g want %.12g (compile %.1f s)", got, gref, tc))
        return true
    catch e
        ok(tag, false, err1(e))
        verbose && say("      " * replace(sprint(showerror, e), "\n" => "\n      ")[1:min(end, 3000)])
        return false
    end
end

say("reference d(sum u_n)/dk = $GREF_FIXED")
say("")
say("=== W1/W2  is it the WHILE REGION, or the STATIC TRIP COUNT? ===")

# W1: meant to be whilegrad.jl K1 with a HOST bound so the iteration count is a
# compile-time constant. This SPELLING does not get there -- `@trace while`
# promotes the host `i` and the comparison lands on a `TracedRNumber{Int64}`,
# which fails in Julia before any MLIR is emitted (`MethodError: no method
# matching Float64(::TracedRNumber{Int64})`). Kept as the record of that dead
# end; the static-trip-count case is answered by whilegrad4.jl X1, which spells
# it `RX.@trace for _ in 1:NSTEP` and PASSES with `stablehlo.while` still in the
# differentiated module.
function w_hostbound(u, k)
    i = 0.0
    RX.@trace while i < Float64(NSTEP)
        u = u .+ k .* u .* H
        i = i + 1.0
    end
    sum(u)
end
rev("W1 while, HOST bound", w_hostbound, GREF_FIXED)

# W2: the whilegrad.jl K1 loop verbatim -- bound is a traced ConcreteRNumber.
function w_tracedbound(u, k, nlim)
    i = zero(k)
    RX.@trace while i < nlim
        u = u .+ k .* u .* H
        i = i + one(k)
    end
    sum(u)
end
nr = RX.ConcreteRNumber(Float64(NSTEP))
rev("W2 while, TRACED bound", w_tracedbound, GREF_FIXED, nr; verbose = true)

say("")
say("=== W3/W4  checkpointing on the traced-bound while ===")
function w_periodic(u, k, nlim)
    i = zero(k)
    RX.@trace checkpointing = RX.Periodic(5) while i < nlim
        u = u .+ k .* u .* H
        i = i + one(k)
    end
    sum(u)
end
rev("W3 while + Periodic(5)", w_periodic, GREF_FIXED, nr; verbose = true)

function w_binomial(u, k, nlim)
    i = zero(k)
    RX.@trace checkpointing = RX.Binomial(5) while i < nlim
        u = u .+ k .* u .* H
        i = i + one(k)
    end
    sum(u)
end
rev("W4 while + Binomial(5)", w_binomial, GREF_FIXED, nr; verbose = true)

say("")
say("=== W5..W7  DATA-DEPENDENT trip count (the adaptive_solve shape) ===")
function host_adapt(u, k, thresh)
    s = zero(eltype(u)); it = 0
    while s < thresh && it < 500
        u = u .+ k .* u .* H
        s = sum(u); it += 1
    end
    sum(u)
end
const GREF_ADAPT = ForwardDiff.derivative(kk -> host_adapt(u0, kk, 4.0), k0)
say("reference (data-dependent trips) d/dk = $GREF_ADAPT")

thr = RX.ConcreteRNumber(4.0)
function w_adapt(u, k, thresh)
    s = zero(k); it = zero(k)
    RX.@trace while (s < thresh) & (it < 500.0)
        u = u .+ k .* u .* H
        s = sum(u); it = it + one(k)
    end
    sum(u)
end
rev("W5 adaptive, plain", w_adapt, GREF_ADAPT, thr; rtol = 1e-6, verbose = true)

function w_adapt_p(u, k, thresh)
    s = zero(k); it = zero(k)
    RX.@trace checkpointing = RX.Periodic(10) while (s < thresh) & (it < 500.0)
        u = u .+ k .* u .* H
        s = sum(u); it = it + one(k)
    end
    sum(u)
end
rev("W6 adaptive + Periodic(10)", w_adapt_p, GREF_ADAPT, thr; rtol = 1e-6, verbose = true)

function w_adapt_b(u, k, thresh)
    s = zero(k); it = zero(k)
    RX.@trace checkpointing = RX.Binomial(10) while (s < thresh) & (it < 500.0)
        u = u .+ k .* u .* H
        s = sum(u); it = it + one(k)
    end
    sum(u)
end
rev("W7 adaptive + Binomial(10)", w_adapt_b, GREF_ADAPT, thr; rtol = 1e-6, verbose = true)

say("")
say("=== W9  does the DIFFERENTIATED program still contain a while region? ===")
# If Enzyme (or a canonicalizer) unrolled the static-bound loop away, W1 would
# be a straight-line result wearing a loop's clothes and would say nothing about
# reverse-over-while. Count while regions in the GRADIENT module.
for (tag, f, extra) in (("W1 gradient", w_hostbound, ()),
                        ("W6 gradient", w_adapt_p, (thr,)))
    try
        ur = RX.ConcreteRArray(u0); kr = RX.ConcreteRNumber(k0)
        g = (u, k, e...) -> Enzyme.gradient(Enzyme.Reverse, f, Enzyme.Const(u), k,
                                            map(Enzyme.Const, e)...)[2]
        s = repr(RX.@code_hlo optimize = false g(ur, kr, extra...))
        nw = length(collect(eachmatch(r"stablehlo\.while\b", s)))
        say(@sprintf("  %-26s stablehlo.while=%d  lines=%d", tag, nw,
                     count(==('\n'), s) + 1))
    catch e
        say(@sprintf("  %-26s ERROR %s", tag, err1(e)))
    end
end
say("WHILEGRAD3_DONE")
