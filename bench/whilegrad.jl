# THE make-or-break question for a whole-simulation gradient.
#
# Every gradient I have measured so far went through the RHS. But a macro step is
# not the RHS -- it is `adaptive_solve`, whose time loop is a `Reactant.@trace
# while` (a stablehlo.while region), with a data-dependent trip count set by the
# step-size controller. Reverse-mode AD through a while loop needs the trajectory
# taped, and support for reverse-over-while is exactly the kind of thing that is
# either there or catastrophically not.
#
# So: differentiate the OUTPUT of a traced while loop w.r.t. a scalar parameter,
# and check it against a closed form.
#
#   K1  FIXED trip count while loop        u <- u + k*u*h, n times
#                                          => u_n = u0*(1+k*h)^n, exact d/dk known
#   K2  DATA-DEPENDENT trip count          loop until an accumulator crosses a
#                                          threshold -- the shape adaptive_solve
#                                          actually has
#   K3  forward mode through the same loop (the fallback if reverse cannot)
import Pkg
Pkg.activate("/tmp/claude-1111265/ca-env"; io = devnull)
using Reactant, ForwardDiff, Printf
const Enzyme = Reactant.Enzyme
const RX = Reactant
try; RX.set_default_backend("cpu"); catch; end
say(s) = (println(s); flush(stdout))
ok(tag, good, msg) = say(@sprintf("  [%s] %s -- %s", good ? "PASS" : "FAIL", tag, msg))
err1(e) = first(split(sprint(showerror, e), '\n'))

const N = 6
const H = 0.01
const NSTEP = 20
u0 = [0.5 + 0.1i for i in 1:N]
k0 = 0.7

# host reference, same algorithm
function host_fixed(u, k, n)
    for _ in 1:n; u = u .+ k .* u .* H; end
    sum(u)
end
gref_fixed = ForwardDiff.derivative(kk -> host_fixed(u0, kk, NSTEP), k0)
say("K1 host reference d(sum u_n)/dk = $gref_fixed   (closed form " *
    "$(sum(u0)*NSTEP*H*(1+k0*H)^(NSTEP-1)))")

# --- K1 : fixed trip count -------------------------------------------------
function traced_fixed(u, k, nlim)
    i = zero(k)
    RX.@trace while i < nlim
        u = u .+ k .* u .* H
        i = i + one(k)
    end
    sum(u)
end
try
    ur = RX.ConcreteRArray(u0); kr = RX.ConcreteRNumber(k0)
    nr = RX.ConcreteRNumber(Float64(NSTEP))
    g = (u, k, n) -> Enzyme.gradient(Enzyme.Reverse, traced_fixed,
                                     Enzyme.Const(u), k, Enzyme.Const(n))[2]
    xg = RX.@compile sync=true g(ur, kr, nr)
    got = Float64(xg(ur, kr, nr))
    ok("K1", isapprox(got, gref_fixed; rtol = 1e-8),
       "REVERSE through a fixed-trip @trace while: got $got want $gref_fixed")
catch e
    ok("K1", false, "REVERSE through @trace while: $(err1(e))")
end

# --- K2 : data-dependent trip count ----------------------------------------
# Loop until the accumulated value crosses a threshold. The number of iterations
# depends on `k`, which is what an adaptive step-size controller does.
function host_adapt(u, k, thresh)
    s = zero(eltype(u))
    it = 0
    while s < thresh && it < 500
        u = u .+ k .* u .* H
        s = sum(u); it += 1
    end
    sum(u)
end
gref_adapt = ForwardDiff.derivative(kk -> host_adapt(u0, kk, 4.0), k0)
say("K2 host reference (data-dependent trips) d/dk = $gref_adapt")
function traced_adapt(u, k, thresh)
    s = zero(k); it = zero(k)
    RX.@trace while (s < thresh) & (it < 500.0)
        u = u .+ k .* u .* H
        s = sum(u)
        it = it + one(k)
    end
    sum(u)
end
try
    ur = RX.ConcreteRArray(u0); kr = RX.ConcreteRNumber(k0)
    thr = RX.ConcreteRNumber(4.0)
    g = (u, k, th) -> Enzyme.gradient(Enzyme.Reverse, traced_adapt,
                                      Enzyme.Const(u), k, Enzyme.Const(th))[2]
    xg = RX.@compile sync=true g(ur, kr, thr)
    got = Float64(xg(ur, kr, thr))
    ok("K2", isapprox(got, gref_adapt; rtol = 1e-6),
       "REVERSE through a DATA-DEPENDENT-trip @trace while: got $got want $gref_adapt")
catch e
    ok("K2", false, "REVERSE, data-dependent trips: $(err1(e))")
end

# --- K3 : forward mode through the same loop (the fallback) ----------------
try
    ur = RX.ConcreteRArray(u0); kr = RX.ConcreteRNumber(k0)
    nr = RX.ConcreteRNumber(Float64(NSTEP))
    g = (u, k, n) -> Enzyme.autodiff(Enzyme.Forward, traced_fixed, Enzyme.Const(u),
                                     Enzyme.Duplicated(k, one(k)), Enzyme.Const(n))[1]
    xg = RX.@compile sync=true g(ur, kr, nr)
    got = Float64(xg(ur, kr, nr))
    ok("K3", isapprox(got, gref_fixed; rtol = 1e-8),
       "FORWARD through @trace while: got $got want $gref_fixed")
catch e
    ok("K3", false, "FORWARD through @trace while: $(err1(e))")
end
say("WHILEGRAD_DONE")
