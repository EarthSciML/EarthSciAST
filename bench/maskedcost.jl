# WHAT DOES THE MASKED STATIC-COUNT FORM COST AT RUN TIME?
#
# The masked form always runs its CAP iterations; the `while` form exits as soon
# as the controller says so. That is the entire price of the switch, and it is
# the number that decides whether "just bound the loop" is a real answer or a
# toy one. Measure it directly, at matched work.
#
#   Z1  forward-only wall time: `@trace while` (exits at ~n) vs masked `@trace
#       for` at cap C, for C/n in {1, 2, 8}.
#   Z2  the TWO-PHASE design: run the cheap adaptive `while` first to learn the
#       actual iteration count, round UP to a bucket, then differentiate a
#       masked loop at that bucket. Confirms the bucket loop reproduces the
#       adaptive value and its gradient, so the overshoot factor is bounded by
#       the bucket ratio rather than by `maxiters`.
import Pkg
Pkg.activate("/tmp/claude-1111265/scanad-env"; io = devnull)
using Reactant, ForwardDiff, Printf
const Enzyme = Reactant.Enzyme
const RX = Reactant
try; RX.set_default_backend("cpu"); catch; end
say(s) = (println(s); flush(stdout))

const NS = 4096
const TEND = 1.0
u0 = [0.5 + 0.001i for i in 1:NS]
k0 = 0.7

# A fixed-h stepper so the trip count is predictable and the two forms do
# EXACTLY the same arithmetic per iteration -- this is a loop-overhead
# comparison, not a stepper comparison.
const HSTEP = 1.0 / 50          # => 50 iterations to reach TEND
@inline step1(u, k, h) = u .+ h .* (k .* u .* (1 .+ 0.1 .* u))

function z_while(u, k)
    t = zero(k)
    RX.@trace while t < TEND - 1e-9
        u = step1(u, k, HSTEP)
        t = t + HSTEP
    end
    sum(u)
end
mk_masked(cap) = (u, k) -> begin
    t = zero(k)
    RX.@trace track_numbers = false for _ in 1:cap
        live = t < TEND - 1e-9
        h = ifelse(live, HSTEP * one(t), zero(t))
        u = step1(u, k, h)
        t = t + h
    end
    sum(u)
end

# ALIASING, and it is not the donation setting. A compiled `@trace while` writes
# its loop-carried state back over the INPUT ConcreteRArray: call it twice on the
# same `ur` and the second call starts from the first call's answer (measured --
# call 1 returned the host value to 15 digits, call 2 returned Inf, and `ur`
# afterwards held the evolved state). `donated_args = :none` does NOT prevent it.
# So every timed call gets its own fresh input, allocated up front so the
# allocation is not inside the timed region.
fresh(n) = [RX.ConcreteRArray(copy(u0)) for _ in 1:n]
bench(xf, k; n = 20) = begin
    pool = fresh(n + 1)
    xf(pool[end], k)                 # warm
    t0 = time(); for i in 1:n; xf(pool[i], k); end
    (time() - t0) / n * 1e3          # ms
end
# One clean call on an untouched input.
val(xf, k) = Float64(xf(RX.ConcreteRArray(copy(u0)), k))

ur = RX.ConcreteRArray(u0); kr = RX.ConcreteRNumber(k0)
say("=== Z1  forward wall time, state=$NS, true trip count = 50 ===")
xw = RX.@compile sync = true donated_args = :none z_while(ur, kr)
tw = bench(xw, kr)
say(@sprintf("  @trace while  (exits at 50)      %7.3f ms   sum=%.9g",
             tw, val(xw, kr)))
for cap in (50, 100, 400)
    f = mk_masked(cap)
    xm = RX.@compile sync = true donated_args = :none f(ur, kr)
    tm = bench(xm, kr)
    say(@sprintf("  masked for cap=%-4d (C/n=%4.1f)  %7.3f ms   sum=%.9g   %.2fx while",
                 cap, cap / 50, tm, val(xm, kr), tm / tw))
end

say("")
say("=== Z2  two-phase: measure n with the while, differentiate a bucketed cap ===")
# Phase 1: the cheap adaptive while, forward only, to learn the trip count.
function z_count(u, k)
    t = zero(k); it = zero(k)
    RX.@trace while t < TEND - 1e-9
        u = step1(u, k, HSTEP)
        t = t + HSTEP
        it = it + 1.0
    end
    it
end
xc = RX.@compile sync = true donated_args = :none z_count(ur, kr)
nact = Int(Float64(xc(RX.ConcreteRArray(copy(u0)), kr)))
bucket = 1 << (ceil(Int, log2(nact)))          # round UP to a power of two
say(@sprintf("  phase 1: actual trips = %d  ->  bucket = %d (overshoot %.2fx)",
             nact, bucket, bucket / nact))

# Phase 2: differentiate the masked loop at the bucketed cap.
href = kk -> (u = copy(u0); t = 0.0;
              while t < TEND - 1e-9; u = step1(u, kk, HSTEP); t += HSTEP; end;
              sum(u))
gref = ForwardDiff.derivative(href, k0)
f = mk_masked(bucket)
g = (u, k) -> Enzyme.gradient(Enzyme.Reverse, f, Enzyme.Const(u), k)[2]
t0 = time(); xg = RX.@compile sync = true donated_args = :none g(ur, kr); tc = time() - t0
got = Float64(xg(RX.ConcreteRArray(copy(u0)), kr))
say(@sprintf("  phase 2: REVERSE at cap=%d  got %.10g  want %.10g  [%s] (compile %.1f s)",
             bucket, got, gref, isapprox(got, gref; rtol = 1e-8) ? "PASS" : "FAIL", tc))
say(@sprintf("  phase 2 gradient eval: %.3f ms", bench(xg, kr; n = 10)))
say("MASKEDCOST_DONE")
