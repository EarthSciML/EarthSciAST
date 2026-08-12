# K1/K2 showed REVERSE mode cannot cross a `@trace while` region ("MLIR pass
# pipeline 'all' failed"), while FORWARD mode crosses it exactly. Since even a
# FIXED-trip while failed, the blocker is the while REGION, not adaptivity.
# So the obvious workaround: don't emit a while region. Unroll the step loop at
# trace time into straight-line traced code -- which is exactly what the RHS is,
# and reverse mode already handles that (measured earlier, exact).
#
#   K4  reverse through a HOST-UNROLLED fixed step count (no @trace while)
#   K5  how far does that scale before the trace explodes? (20 vs 100 steps)
import Pkg
Pkg.activate("/tmp/claude-1111265/ca-env"; io = devnull)
using Reactant, ForwardDiff, Printf
const Enzyme = Reactant.Enzyme
const RX = Reactant
try; RX.set_default_backend("cpu"); catch; end
say(s) = (println(s); flush(stdout))
ok(t,g,m) = say(@sprintf("  [%s] %s -- %s", g ? "PASS" : "FAIL", t, m))
err1(e) = first(split(sprint(showerror, e), '\n'))
const N=6; const H=0.01
u0=[0.5+0.1i for i in 1:N]; k0=0.7
host(u,k,n) = (for _ in 1:n; u = u .+ k.*u.*H; end; sum(u))

for NSTEP in (20, 100)
    gref = ForwardDiff.derivative(kk -> host(u0, kk, NSTEP), k0)
    # unrolled: a PLAIN Julia loop over a compile-time count, so the trace is
    # straight-line and no stablehlo.while is emitted at all.
    f = (u, k) -> (for _ in 1:NSTEP; u = u .+ k.*u.*H; end; sum(u))
    try
        ur = RX.ConcreteRArray(u0); kr = RX.ConcreteRNumber(k0)
        g = (u,k) -> Enzyme.gradient(Enzyme.Reverse, f, Enzyme.Const(u), k)[2]
        t0 = time()
        xg = RX.@compile sync=true g(ur, kr)
        tc = time() - t0
        got = Float64(xg(ur, kr))
        ok("K4/$NSTEP", isapprox(got, gref; rtol=1e-8),
           @sprintf("REVERSE through %d UNROLLED steps: got %.12g want %.12g (compile %.1f s)",
                    NSTEP, got, gref, tc))
    catch e
        ok("K4/$NSTEP", false, err1(e))
    end
end
say("WHILEGRAD2_DONE")
