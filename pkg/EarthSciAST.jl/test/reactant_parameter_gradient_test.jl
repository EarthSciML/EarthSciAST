# The TRACED half of test/parameter_gradient_test.jl — ∂(RHS)/∂p through XLA.
#
# OPT-IN, and never loaded by the default suite: `include`d only from the bottom
# of parameter_gradient_test.jl under `ESM_TEST_REACTANT=1`, exactly as
# reactant_oop_test.jl is gated from runtests.jl and for the same reason (Reactant
# bundles an XLA runtime). It reads the model, the RHSs and the HOST ForwardDiff
# references (`_PG_G_OOP`, `_PG_G_U`) that file already computed; running this file
# standalone means running that one with the env var set.
#
# WHAT IS ASSERTED, AND AT WHAT TOLERANCE.
#
#   * Reverse-mode `∂/∂p` and `∂/∂u` against the host ForwardDiff answer at
#     rtol 1e-8 — deliberately looser than the 1e-12 host-vs-host bound next door.
#     XLA reassociates sums and contracts multiply-adds into FMAs (see
#     reactant_oop_test.jl's header); both are value-changing and both are the
#     point of compiling, and a few-ulp difference in the RHS is amplified by
#     differentiating it. Asserting equality here would be asserting that XLA did
#     not optimize.
#
#   * `p` IS A REAL XLA INPUT, not a trace-time constant. Compile ONCE, then call
#     the SAME compiled program with DIFFERENT parameter values and check the
#     answer follows and still matches the host. This is the decisive fact for any
#     gradient-based workflow: a parameter sweep costs one compile, not one per
#     parameter value (this model's real-world sibling takes ~550 s to compile).
#     It is also a silent-staleness trap of exactly the kind the forcing buffers
#     were — a baked-in `p` returns the same plausible numbers forever, with no
#     error — so it is pinned in BOTH directions, the way `t` is.
#
#   * `@test_broken`: reverse mode through a `Reactant.@trace while` region.
#     MEASURED to fail today with `MLIR pass pipeline "all" failed`, and to fail
#     for a FIXED trip count too — so the blocker is the while REGION itself, not
#     adaptivity, and the passing forward-mode test beside it localizes the
#     failure to reverse-over-while rather than to `@trace while` at large. It is
#     recorded as broken rather than deleted because it is the single upstream fix
#     that would collapse a whole planned workstream (a hand-written discrete
#     adjoint over the time loop) into nothing: the day Reactant/Enzyme gains it,
#     Test.jl raises "Unexpectedly Pass" and this suite says so out loud instead
#     of us re-measuring by hand.

using Test
using Reactant

const _PGR_RX = Reactant
# Enzyme is a dependency OF Reactant, not of the test environment — reaching it
# through Reactant is what lets this file run in any env that has Reactant.
const _PGR_Enzyme = Reactant.Enzyme

try
    _PGR_RX.set_default_backend("cpu")
catch
end

# Parameters ride as a NamedTuple of traced scalars, which is how `build_evaluator`
# already hands them out (see reactant_oop_test.jl's `_dev`).
_pgr_dev(pv) = NamedTuple{_PG_SYMS}(map(_PGR_RX.ConcreteRNumber, Tuple(pv)))
_pgr_u() = _PGR_RX.ConcreteRArray(_PG_U)
_pgr_t() = _PGR_RX.ConcreteRNumber(_PG_T)

@testset "∂(RHS)/∂(parameter vector) — traced (Reactant/XLA)" begin

    @testset "traced reverse-mode ∂/∂p matches host ForwardDiff" begin
        gfun = (u, p, t) -> _PGR_Enzyme.gradient(_PGR_Enzyme.Reverse, _pg_obj,
                                                 _PGR_Enzyme.Const(u), p,
                                                 _PGR_Enzyme.Const(t))[2]
        ur, pr, tr = _pgr_u(), _pgr_dev(_PG_PVEC0), _pgr_t()
        gx = _PGR_RX.@compile sync = true gfun(ur, pr, tr)
        gnt = gx(ur, pr, tr)
        gv = [Float64(getfield(gnt, s)) for s in _PG_SYMS]
        @test isapprox(gv, _PG_G_OOP; rtol = 1e-8)
    end

    @testset "traced reverse-mode ∂/∂u matches host ForwardDiff" begin
        # The other half of an adjoint step: the state VJP.
        gfun = (u, p, t) -> _PGR_Enzyme.gradient(_PGR_Enzyme.Reverse, _pg_obj, u,
                                                 _PGR_Enzyme.Const(p),
                                                 _PGR_Enzyme.Const(t))[1]
        ur, pr, tr = _pgr_u(), _pgr_dev(_PG_PVEC0), _pgr_t()
        gx = _PGR_RX.@compile sync = true gfun(ur, pr, tr)
        @test isapprox(Array(gx(ur, pr, tr)), _PG_G_U; rtol = 1e-8)
    end

    @testset "`p` is a REAL XLA input, not a baked-in constant" begin
        # Compile ONCE at _PG_PVEC0, then hand the SAME program a different `p`.
        ur, tr = _pgr_u(), _pgr_t()
        xla = _PGR_RX.@compile sync = true _PG_FO(ur, _pgr_dev(_PG_PVEC0), tr)

        a = Array(xla(ur, _pgr_dev(_PG_PVEC0), tr))
        @test isapprox(a, _PG_FO(_PG_U, _PG_P0, _PG_T); rtol = 1e-14, atol = 1e-15)

        pv2 = copy(_PG_PVEC0)
        pv2[findfirst(==(:k_diff), collect(_PG_SYMS))] *= 2.0
        b = Array(xla(ur, _pgr_dev(pv2), tr))          # no recompile
        host2 = _PG_FO(_PG_U, _pg_nt(pv2), _PG_T)

        # It MOVED (so it was not frozen) …
        @test !isapprox(a, b; rtol = 1e-12)
        @test maximum(abs, b .- a) > 1e-6
        # … and it moved to the RIGHT place …
        @test isapprox(b, host2; rtol = 1e-14, atol = 1e-15)
        # … and back again: no hysteresis in the compiled program.
        @test Array(xla(ur, _pgr_dev(_PG_PVEC0), tr)) == a
    end

    @testset "reverse mode through a `@trace while` region (BROKEN upstream)" begin
        # NOT an EarthSciAST loop — the smallest possible `Reactant.@trace while`,
        # a FIXED trip count, no adaptivity, no model. It is reduced this far
        # precisely so that when it flips green there is no doubt what got fixed.
        H, NSTEP, k0 = 0.01, 20, 0.7
        function host(u, k, n)
            for _ in 1:n
                u = u .+ k .* u .* H
            end
            return sum(u)
        end
        gref = ForwardDiff.derivative(kk -> host(_PG_U, kk, NSTEP), k0)

        function traced(u, k, nlim)
            i = zero(k)
            _PGR_RX.@trace while i < nlim
                u = u .+ k .* u .* H
                i = i + one(k)
            end
            return sum(u)
        end

        ur = _pgr_u()
        kr = _PGR_RX.ConcreteRNumber(k0)
        nr = _PGR_RX.ConcreteRNumber(Float64(NSTEP))

        # FORWARD mode crosses it exactly — a real, passing test, and the reason
        # the `@test_broken` below is about REVERSE mode rather than about
        # `@trace while` being untraceable.
        fwd = (u, k, n) -> _PGR_Enzyme.autodiff(_PGR_Enzyme.Forward, traced,
                                                _PGR_Enzyme.Const(u),
                                                _PGR_Enzyme.Duplicated(k, one(k)),
                                                _PGR_Enzyme.Const(n))[1]
        xf = _PGR_RX.@compile sync = true fwd(ur, kr, nr)
        @test isapprox(Float64(xf(ur, kr, nr)), gref; rtol = 1e-8)

        # REVERSE mode does not.
        rev = (u, k, n) -> _PGR_Enzyme.gradient(_PGR_Enzyme.Reverse, traced,
                                                _PGR_Enzyme.Const(u), k,
                                                _PGR_Enzyme.Const(n))[2]
        @test_broken begin
            xg = _PGR_RX.@compile sync = true rev(ur, kr, nr)
            isapprox(Float64(xg(ur, kr, nr)), gref; rtol = 1e-8)
        end
    end
end
