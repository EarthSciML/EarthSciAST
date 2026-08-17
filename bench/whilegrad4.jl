# WHAT EXACTLY DOES ENZYME'S while-REVERSE RULE DEMAND?
#
# whilegrad3.jl pulled the real MLIR diagnostics out of the failures. They are
# not "while is not differentiable" -- they are two specific structural demands
# of `AutoDiffWhileRev`'s trajectory cache, which is a DENSE `[N, ...]` tensor
# and so must be statically shaped:
#
#   "WhileOp does not have induction variable for cache removal"   (W2, W3)
#   "WhileOp does not have known iteration count for cache removal"(W5, W6, W7)
#   "'stablehlo.subtract' op requires compatible types"            (W4, Binomial)
#
# And reducegrad.jl G6 CROSSED a `@trace for _ in 1:5` -- which loopshape.jl
# measured as `stablehlo.while=1`. So reverse-over-while works when the rule's
# demands are met. This probe maps the boundary precisely.
#
#   X1  @trace for, STATIC range                     -- expect PASS (+ while in grad)
#   X2  @trace for, TRACED integer bound             -- proper induction var,
#                                                       unknown N.  +Periodic/+Binomial
#   X3  @trace while, INTEGER counter, traced bound  -- does an Int counter get
#                                                       recognized as induction?
#   X4  @trace while, DATA-DEPENDENT condition with an integer iteration cap
#       -- the adaptive_solve shape.  plain / Periodic / Binomial
#   X5  the SAME adaptive computation rewritten as a `@trace for` over a static
#       maximum count with a masked (ifelse'd) body -- adaptivity WITHOUT a
#       data-dependent trip count.
import Pkg
Pkg.activate("/tmp/claude-1111265/scanad-env"; io = devnull)
using Reactant, ForwardDiff, Printf
const Enzyme = Reactant.Enzyme
const RX = Reactant
try; RX.set_default_backend("cpu"); catch; end
say(s) = (println(s); flush(stdout))
ok(t, g, m) = say(@sprintf("  [%s] %-30s %s", g ? "PASS" : "FAIL", t, m))
err1(e) = first(split(sprint(showerror, e), '\n'))
# The MLIR diagnostic line is the whole point; surface it, not the wrapper.
function mlirerr(e)
    s = sprint(showerror, e)
    m = match(r"error: ([^\n]+)", s)
    return m === nothing ? err1(e) : "MLIR: " * m.captures[1]
end

const N = 6
const H = 0.01
const NSTEP = 20
u0 = [0.5 + 0.1i for i in 1:N]
k0 = 0.7
host_fixed(u, k, n) = (for _ in 1:n; u = u .+ k .* u .* H; end; sum(u))
const GREF = ForwardDiff.derivative(kk -> host_fixed(u0, kk, NSTEP), k0)

function rev(tag, f, gref, extra...; rtol = 1e-8, showhlo = false)
    ur = RX.ConcreteRArray(u0); kr = RX.ConcreteRNumber(k0)
    g = (u, k, e...) -> Enzyme.gradient(Enzyme.Reverse, f, Enzyme.Const(u), k,
                                        map(Enzyme.Const, e)...)[2]
    nw = -1
    if showhlo
        try
            s = repr(RX.@code_hlo optimize = false g(ur, kr, extra...))
            nw = length(collect(eachmatch(r"stablehlo\.while\b", s)))
        catch; end
    end
    try
        t0 = time()
        xg = RX.@compile sync = true g(ur, kr, extra...)
        tc = time() - t0
        got = Float64(xg(ur, kr, extra...))
        ok(tag, isapprox(got, gref; rtol = rtol),
           @sprintf("got %.12g want %.12g (%.1f s%s)", got, gref, tc,
                    nw >= 0 ? ", grad has while=$nw" : ""))
    catch e
        ok(tag, false, mlirerr(e))
    end
end

say("reference d/dk = $GREF")
say("")
say("=== X1  @trace for, STATIC range (emits stablehlo.while) ===")
function x1(u, k)
    RX.@trace track_numbers = false for _ in 1:NSTEP
        u = u .+ k .* u .* H
    end
    sum(u)
end
rev("X1 for 1:$NSTEP static", x1, GREF; showhlo = true)

say("")
say("=== X2  @trace for, TRACED integer bound (induction var, unknown N) ===")
function x2(u, k, n)
    RX.@trace track_numbers = false for _ in 1:n
        u = u .+ k .* u .* H
    end
    sum(u)
end
function x2p(u, k, n)
    RX.@trace track_numbers = false checkpointing = RX.Periodic(5) for _ in 1:n
        u = u .+ k .* u .* H
    end
    sum(u)
end
function x2b(u, k, n)
    RX.@trace track_numbers = false checkpointing = RX.Binomial(5) for _ in 1:n
        u = u .+ k .* u .* H
    end
    sum(u)
end
nri = RX.ConcreteRNumber(NSTEP)   # Int64, a real induction bound
rev("X2 for 1:n traced, plain", x2, GREF, nri)
rev("X2 for 1:n + Periodic(5)", x2p, GREF, nri; showhlo = true)
rev("X2 for 1:n + Binomial(5)", x2b, GREF, nri)

say("")
say("=== X3  @trace while, INTEGER counter, traced bound ===")
function x3(u, k, nlim)
    i = 0
    RX.@trace while i < nlim
        u = u .+ k .* u .* H
        i = i + 1
    end
    sum(u)
end
function x3p(u, k, nlim)
    i = 0
    RX.@trace checkpointing = RX.Periodic(5) while i < nlim
        u = u .+ k .* u .* H
        i = i + 1
    end
    sum(u)
end
rev("X3 while Int ctr, plain", x3, GREF, nri)
rev("X3 while Int ctr + Periodic", x3p, GREF, nri)

say("")
say("=== X4  DATA-DEPENDENT condition (the adaptive_solve shape) ===")
function host_adapt(u, k, thresh)
    s = zero(eltype(u)); it = 0
    while s < thresh && it < 500
        u = u .+ k .* u .* H; s = sum(u); it += 1
    end
    sum(u)
end
const GREF_A = ForwardDiff.derivative(kk -> host_adapt(u0, kk, 4.0), k0)
say("reference (data-dependent) d/dk = $GREF_A")
thr = RX.ConcreteRNumber(4.0)

function x4(u, k, thresh)
    s = zero(k); it = 0
    RX.@trace while (s < thresh) & (it < 500)
        u = u .+ k .* u .* H; s = sum(u); it = it + 1
    end
    sum(u)
end
function x4p(u, k, thresh)
    s = zero(k); it = 0
    RX.@trace checkpointing = RX.Periodic(10) while (s < thresh) & (it < 500)
        u = u .+ k .* u .* H; s = sum(u); it = it + 1
    end
    sum(u)
end
function x4b(u, k, thresh)
    s = zero(k); it = 0
    RX.@trace checkpointing = RX.Binomial(10) while (s < thresh) & (it < 500)
        u = u .+ k .* u .* H; s = sum(u); it = it + 1
    end
    sum(u)
end
rev("X4 adaptive Int cap, plain", x4, GREF_A, thr; rtol = 1e-6)
rev("X4 adaptive + Periodic(10)", x4p, GREF_A, thr; rtol = 1e-6)
rev("X4 adaptive + Binomial(10)", x4b, GREF_A, thr; rtol = 1e-6)

say("")
say("=== X5  the same adaptive result, as a STATIC-count MASKED for loop ===")
# Adaptivity is preserved -- the controller still chooses when to stop -- but the
# TRIP COUNT is a compile-time constant and termination becomes a `select` on
# the carry. Every iteration past termination is an exact no-op, so the value is
# the adaptive loop's value. This is the shape that satisfies the cache's
# static-`N` demand without giving up the data-dependent stopping rule.
const CAP = 500
function x5(u, k, thresh)
    s = zero(k)
    RX.@trace track_numbers = false for _ in 1:CAP
        live = s < thresh
        un = u .+ k .* u .* H
        u = ifelse.(live, un, u)
        s = ifelse(live, sum(un), s)
    end
    sum(u)
end
rev("X5 masked for 1:$CAP static", x5, GREF_A, thr; rtol = 1e-6, showhlo = true)
say("WHILEGRAD4_DONE")
