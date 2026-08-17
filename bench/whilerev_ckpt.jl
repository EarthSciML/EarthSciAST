# whilerev_probe.jl — does reverse mode actually cross a stablehlo.while?
#
# HELPERS.md:473 / DIFFERENTIABILITY_PLAN.md:24,50 assert "REVERSE MODE CANNOT
# CROSS A stablehlo.while ... for a FIXED trip count as well as a data-dependent
# one, so it is the while region and not adaptivity."
#
# That measurement was taken with `@trace`'s DEFAULTS: checkpointing=false,
# mincut=false. Upstream Enzyme-JAX has AutoDiffWhileRev + LoopCheckpointing, and
# Reactant exposes it via `checkpointing=Periodic(n)|Binomial(n)`, present in
# THIS Reactant (0.2.274). So the fixed-trip-count datum may prove nothing.
#
# This probe re-runs the claim across the checkpointing matrix. Reference is the
# host-unrolled loop (no @trace), which the capability matrix records as exact.
#
# RESULT (Reactant 0.2.274, CPU) -- and note the hypothesis it was written to
# test turned out to be WRONG, in a useful direction:
#
#   host-unrolled (no @trace)          reverse OK  (reference)
#   @trace for, ckpt=false [DEFAULT]   reverse OK  rel=0.000e+00  MATCH  <-- !!
#   @trace for, ckpt=true              reverse OK  rel=0.000e+00  MATCH
#   @trace for, ckpt=Periodic(3)       reverse OK  rel=0.000e+00  MATCH
#   @trace for, ckpt=Binomial(3)       *** SEGFAULT *** in
#       mlir::enzyme::CheckedOpRewritePattern<BinomialProgressOp,
#       BinomialProgressConstProp>::matchAndRewrite -> stablehlo::ConstantOp::build
#
# So checkpointing is NOT the discriminator and was never needed: reverse crosses
# a static-trip-count @trace loop at the DEFAULT settings, exactly. What actually
# matters is that the trip count be a COMPILE-TIME CONSTANT (AutoDiffWhileRev tapes
# the trajectory as a dense [N, state...] tensor; non-static N => tensor<?x...>,
# which XLA cannot translate). And Binomial checkpointing is actively dangerous
# here -- it segfaults above, and on a traced-bound loop it compiles and returns a
# silently WRONG gradient (see bench/maskedloop.jl Y4).
#
# CAVEAT -- the @trace while variants below are MALFORMED and prove nothing.
# With track_numbers=false the counter `t` stays a plain host Float64, so `t < 0.5`
# is a host Bool rather than a traced condition; all three fail in the PRIMAL with
# `MLIR pass pipeline "raise_triton_custom_call" failed`, before AD is reached.
# They are kept only so the failure is on the record and nobody reads those rows as
# evidence about reverse mode. For a correctly-formed data-dependent while loop see
# bench/whilegrad3.jl.

using Reactant, Printf
# Enzyme is Reactant's dep, not this env's — reach it through Reactant.
const Enzyme = Reactant.Enzyme
# @trace is re-exported by Reactant (Reactant.jl:5,307)

Reactant.set_default_backend("cpu")

const NSTEP = 8

# One nonlinear step; identical body in every variant below.
step(x) = 0.99 .* x .+ 0.01 .* x .* x

# ---- reference: host-unrolled, no @trace, no while region at all -------------
function loss_host(x)
    for _ in 1:NSTEP
        x = step(x)
    end
    return sum(x)
end

# ---- @trace for, STATIC trip count — the datum the claim rests on -----------
function loss_for_none(x)
    @trace track_numbers = false for _ in 1:NSTEP
        x = step(x)
    end
    return sum(x)
end

function loss_for_ckpt_true(x)
    @trace track_numbers = false checkpointing = true for _ in 1:NSTEP
        x = step(x)
    end
    return sum(x)
end

function loss_for_periodic(x)
    @trace track_numbers = false checkpointing = Reactant.Periodic(3) for _ in 1:NSTEP
        x = step(x)
    end
    return sum(x)
end

function loss_for_binomial(x)
    @trace track_numbers = false checkpointing = Reactant.Binomial(3) for _ in 1:NSTEP
        x = step(x)
    end
    return sum(x)
end

function loss_for_binomial_mincut(x)
    @trace track_numbers = false checkpointing = Reactant.Binomial(3) mincut = true for _ in 1:NSTEP
        x = step(x)
    end
    return sum(x)
end

# ---- @trace while, DATA-DEPENDENT condition — our adaptive-controller shape --
# `t` accumulates a state-dependent increment, exactly like the PI controller's
# `t += dt`. This is the shape of Enzyme-JAX #2565 (open).
function loss_while_none(x)
    t = 0.0
    @trace track_numbers = false while t < 0.5
        t = t + 0.1
        x = step(x)
    end
    return sum(x)
end

function loss_while_periodic(x)
    t = 0.0
    @trace track_numbers = false checkpointing = Reactant.Periodic(3) while t < 0.5
        t = t + 0.1
        x = step(x)
    end
    return sum(x)
end

function loss_while_binomial_mincut(x)
    t = 0.0
    @trace track_numbers = false checkpointing = Reactant.Binomial(3) mincut = true while t < 0.5
        t = t + 0.1
        x = step(x)
    end
    return sum(x)
end

# -----------------------------------------------------------------------------

function grad!(f, x, dx)
    Enzyme.autodiff(Enzyme.Reverse, f, Enzyme.Active, Enzyme.Duplicated(x, dx))
    return nothing
end

const X0 = collect(range(0.5, 1.5; length = 6))

function primal(f, label)
    x = Reactant.to_rarray(copy(X0))
    try
        c = @eval Reactant.@compile raise = true sync = true $f($x)
        v = Array(c(x))
        @printf("  %-34s primal   OK   %.12f\n", label, only(v))
        return only(v)
    catch e
        m = first(split(sprint(showerror, e), '\n'))
        @printf("  %-34s primal   FAIL %s\n", label, first(m, 110))
        return nothing
    end
end

function reverse_grad(f, label, ref)
    x = Reactant.to_rarray(copy(X0))
    dx = Reactant.to_rarray(zeros(length(X0)))
    try
        cg = @eval Reactant.@compile raise = true raise_first = true sync = true grad!(
            $f, $x, $dx
        )
        cg(f, x, dx)
        g = Array(dx)
        if ref === nothing
            @printf("  %-34s reverse  OK   (no ref) g[1]=%.10f\n", label, g[1])
            return g
        end
        rel = maximum(abs.(g .- ref)) / max(maximum(abs.(ref)), eps())
        tag = rel < 1e-10 ? "MATCH" : "DIFFER"
        @printf("  %-34s reverse  OK   rel=%.3e %s\n", label, rel, tag)
        return g
    catch e
        m = replace(sprint(showerror, e), '\n' => " | ")
        @printf("  %-34s reverse  FAIL %s\n", label, first(m, 160))
        return nothing
    end
end

println("=" ^ 78)
println("Reactant ", pkgversion(Reactant), "   NSTEP=", NSTEP)
println("=" ^ 78)

println("\n--- PRIMALS (all of these must work, or the test is meaningless) ---")
p_host = primal(loss_host, "host-unrolled (no @trace)")
for (f, l) in [
    (loss_for_none, "@trace for, ckpt=false [DEFAULT]"),
    (loss_for_ckpt_true, "@trace for, ckpt=true"),
    (loss_for_periodic, "@trace for, ckpt=Periodic(3)"),
    (loss_for_binomial, "@trace for, ckpt=Binomial(3)"),
    (loss_for_binomial_mincut, "@trace for, Binomial(3)+mincut"),
    (loss_while_none, "@trace while, ckpt=false [DEFAULT]"),
    (loss_while_periodic, "@trace while, ckpt=Periodic(3)"),
    (loss_while_binomial_mincut, "@trace while, Binomial(3)+mincut"),
]
    primal(f, l)
end

println("\n--- REFERENCE GRADIENT (host-unrolled reverse) ---")
ref = reverse_grad(loss_host, "host-unrolled (no @trace)", nothing)

println("\n--- REVERSE THROUGH @trace for (STATIC trip count) ---")
println("    The claim's key datum: 'fails for a FIXED trip count as well'.")
for (f, l) in [
    (loss_for_none, "ckpt=false [DEFAULT: as measured]"),
    (loss_for_ckpt_true, "ckpt=true"),
    (loss_for_periodic, "ckpt=Periodic(3)"),
    (loss_for_binomial, "ckpt=Binomial(3)"),
    (loss_for_binomial_mincut, "ckpt=Binomial(3) + mincut"),
]
    reverse_grad(f, l, ref)
end

println("\n--- REVERSE THROUGH @trace while (DATA-DEPENDENT cond) ---")
println("    Our adaptive-controller shape; cf. Enzyme-JAX #2565 (OPEN).")
for (f, l) in [
    (loss_while_none, "ckpt=false [DEFAULT: as measured]"),
    (loss_while_periodic, "ckpt=Periodic(3)"),
    (loss_while_binomial_mincut, "ckpt=Binomial(3) + mincut"),
]
    reverse_grad(f, l, ref)
end

println("\nDONE")
