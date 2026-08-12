# IS THE MASKED STATIC-COUNT LOOP ACTUALLY USABLE FOR AN ADAPTIVE INTEGRATOR?
#
# whilegrad4.jl X5: an adaptive stopping rule rewritten as a `@trace for` over a
# COMPILE-TIME step cap, with termination as an `ifelse` on the carry, gave the
# adaptive loop's exact gradient in 0.2 s -- and the gradient module still
# contains a `stablehlo.while`, so the loop was NOT unrolled: program size is
# O(1) in the cap. That is the whole architecture question, so it has to survive
# contact with the things a real controller does.
#
#   Y1  ACCEPT/REJECT, not just early stop. A real controller retries a rejected
#       step with a smaller h. Masked, a rejected attempt is an iteration that
#       updates only h. The cap bounds ATTEMPTS, not accepted steps.
#   Y2  checkpointing on the static-count loop -- the dense tape is [CAP, state],
#       which is the one real cost. Does `checkpointing=true` (isqrt(N) for a
#       static `for`) still give the right gradient?
#   Y3  TAPE COST at a realistic state size: compile time and peak RSS for
#       CAP x state.  Does [CAP, state] fit?
#   Y4  the wrong-answer reproduction from X2: `Binomial` on a TRACED-bound loop
#       COMPILED and returned a gradient that is quietly ~0.1% off. If that is
#       real it is worse than the failure, and it is Reactant.jl#1895 territory.
import Pkg
Pkg.activate("/tmp/claude-1111265/scanad-env"; io = devnull)
using Reactant, ForwardDiff, Printf
const Enzyme = Reactant.Enzyme
const RX = Reactant
try; RX.set_default_backend("cpu"); catch; end
say(s) = (println(s); flush(stdout))
ok(t, g, m) = say(@sprintf("  [%s] %-30s %s", g ? "PASS" : "FAIL", t, m))
function mlirerr(e)
    s = sprint(showerror, e)
    m = match(r"error: ([^\n]+)", s)
    return m === nothing ? first(split(s, '\n')) : "MLIR: " * m.captures[1]
end
anon_mb() = try
    for l in eachline("/sys/fs/cgroup/memory.stat")
        startswith(l, "anon ") && return parse(Int, split(l)[2]) / 2^20
    end; NaN
catch; NaN end

# ---- Y1  a real accept/reject controller ---------------------------------
# Explicit Euler with a step-doubling error estimate. If the estimate exceeds
# tol the step is REJECTED: state and time do not advance, h shrinks, and the
# attempt is retried on the next iteration. Both the host and the traced form
# run the identical decision sequence, so ForwardDiff on the host is an exact
# reference for the traced reverse gradient.
const NS = 6
u0 = [0.5 + 0.1i for i in 1:NS]
k0 = 0.7
const TEND = 1.0
const TOL = 1e-4
const ATT = 120          # cap on ATTEMPTS (accepted + rejected)

# one attempt: returns (u', t', h', accepted)
@inline function attempt(u, k, t, h)
    f(x) = k .* x .* (1 .+ 0.1 .* x)          # mildly nonlinear, so h matters
    big = u .+ h .* f(u)                       # one step of h
    hm = h ./ 2
    half = u .+ hm .* f(u)
    half = half .+ hm .* f(half)               # two steps of h/2
    err = sum(abs2, big .- half)
    acc = err < TOL
    hnew = ifelse(acc, min(h * 1.5, TEND - (t + h)), h * 0.5)
    return (ifelse.(acc, half, u), ifelse(acc, t + h, t), max(hnew, 1e-6), acc)
end

function y1_host(k)
    u = copy(u0); t = 0.0; h = 0.05
    for _ in 1:ATT
        live = t < TEND
        hh = live ? min(h, TEND - t) : 0.0
        un, tn, hn, _ = attempt(u, k, t, hh)
        if live
            u = un; t = tn; h = hn
        end
    end
    sum(u)
end
function y1(u, k)
    t = zero(k); h = 0.05 * one(k)
    RX.@trace track_numbers = false for _ in 1:ATT
        live = t < TEND
        hh = ifelse(live, min(h, TEND - t), zero(h))
        un, tn, hn, _ = attempt(u, k, t, hh)
        u = ifelse.(live, un, u)
        t = ifelse(live, tn, t)
        h = ifelse(live, hn, h)
    end
    sum(u)
end
const GREF_Y1 = ForwardDiff.derivative(y1_host, k0)
say("Y1 host reference (accept/reject controller) d/dk = $GREF_Y1")

function revcheck(tag, f, u0v, k0v, gref; rtol = 1e-6, hlo = false)
    ur = RX.ConcreteRArray(u0v); kr = RX.ConcreteRNumber(k0v)
    g = (u, k) -> Enzyme.gradient(Enzyme.Reverse, f, Enzyme.Const(u), k)[2]
    extra = ""
    if hlo
        try
            s = repr(RX.@code_hlo optimize = false g(ur, kr))
            extra = @sprintf(", grad while=%d lines=%d",
                             length(collect(eachmatch(r"stablehlo\.while\b", s))),
                             count(==('\n'), s) + 1)
        catch; end
    end
    try
        m0 = anon_mb(); t0 = time()
        xg = RX.@compile sync = true g(ur, kr)
        tc = time() - t0
        got = Float64(xg(ur, kr)); dm = anon_mb() - m0
        ok(tag, isapprox(got, gref; rtol = rtol),
           @sprintf("got %.10g want %.10g (%.1f s, +%.0f MB anon%s)", got, gref, tc, dm, extra))
    catch e
        ok(tag, false, mlirerr(e))
    end
end

revcheck("Y1 accept/reject masked", y1, u0, k0, GREF_Y1; hlo = true)

say("")
say("=== Y2  checkpointing on the STATIC-count loop ===")
function y2(u, k)
    t = zero(k); h = 0.05 * one(k)
    RX.@trace track_numbers = false checkpointing = true for _ in 1:ATT
        live = t < TEND
        hh = ifelse(live, min(h, TEND - t), zero(h))
        un, tn, hn, _ = attempt(u, k, t, hh)
        u = ifelse.(live, un, u); t = ifelse(live, tn, t); h = ifelse(live, hn, h)
    end
    sum(u)
end
revcheck("Y2 + checkpointing=true", y2, u0, k0, GREF_Y1; hlo = true)

say("")
say("=== Y3  tape cost at a realistic state size ===")
# The reverse tape is a dense [CAP, state] tensor. This is the one cost the
# masked form pays that a host-lifted adjoint does not, so price it.
for (ns, cap) in ((256, 120), (4096, 120), (4096, 500))
    uv = [0.5 + 0.001i for i in 1:ns]
    href = kk -> (u = copy(uv); t = 0.0; h = 0.05;
                  for _ in 1:cap
                      live = t < TEND
                      hh = live ? min(h, TEND - t) : 0.0
                      un, tn, hn, _ = attempt(u, kk, t, hh)
                      if live; u = un; t = tn; h = hn; end
                  end; sum(u))
    gref = ForwardDiff.derivative(href, k0)
    f = (u, k) -> begin
        t = zero(k); h = 0.05 * one(k)
        RX.@trace track_numbers = false for _ in 1:cap
            live = t < TEND
            hh = ifelse(live, min(h, TEND - t), zero(h))
            un, tn, hn, _ = attempt(u, k, t, hh)
            u = ifelse.(live, un, u); t = ifelse(live, tn, t); h = ifelse(live, hn, h)
        end
        sum(u)
    end
    say(@sprintf("  state=%d cap=%d  dense tape ~ %.1f MB", ns, cap,
                 ns * cap * 8 / 2^20))
    revcheck(@sprintf("Y3 ns=%d cap=%d", ns, cap), f, uv, k0, gref)
end

say("")
say("=== Y4  does checkpointing SILENTLY return a wrong gradient? ===")
# X2 saw `Binomial(5)` on a traced-bound `for` COMPILE and return 1.16578 where
# the answer is 1.16456. Re-run across checkpoint counts: if the value moves with
# the checkpoint count, it is a checkpointing bug, not a tolerance question.
const H = 0.01
const NSTEP = 20
uv4 = [0.5 + 0.1i for i in 1:NS]
gref4 = ForwardDiff.derivative(kk -> (u = copy(uv4);
                                      for _ in 1:NSTEP; u = u .+ kk .* u .* H; end;
                                      sum(u)), k0)
say(@sprintf("  exact d/dk = %.12g", gref4))
for nc in (2, 4, 5, 10)
    f = (u, k, n) -> begin
        RX.@trace track_numbers = false checkpointing = RX.Binomial(nc) for _ in 1:n
            u = u .+ k .* u .* H
        end
        sum(u)
    end
    try
        ur = RX.ConcreteRArray(uv4); kr = RX.ConcreteRNumber(k0)
        nr = RX.ConcreteRNumber(NSTEP)
        g = (u, k, n) -> Enzyme.gradient(Enzyme.Reverse, f, Enzyme.Const(u), k,
                                         Enzyme.Const(n))[2]
        xg = RX.@compile sync = true g(ur, kr, nr)
        got = Float64(xg(ur, kr, nr))
        say(@sprintf("  Binomial(%2d): got %.12g   rel err %.2e %s", nc, got,
                     abs(got - gref4) / abs(gref4),
                     isapprox(got, gref4; rtol = 1e-8) ? "" : "  <-- WRONG"))
    catch e
        say(@sprintf("  Binomial(%2d): %s", nc, mlirerr(e)))
    end
end
say("MASKEDLOOP_DONE")
