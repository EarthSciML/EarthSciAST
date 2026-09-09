# esm-spec §4.2 — a RIGHT-HAND-SIDE structural `D` is the named unknown's
# tendency. This is Julia's side of the rule, in two parts.
#
# PART 1 pins what this binding implements: `flatten` step 3c resolves a
# right-hand-side structural `D` to the total time derivative the system already
# defines — a STATE's own tendency, an OBSERVED's definition differentiated by
# the chain rule, `0` for a time-invariant name, and the sum / product /
# quotient rules through `+ - neg * /` — recursing throughout, and leaving every
# shape outside that closed set (and every cyclic chain) exactly as authored.
# The end-to-end assertion goes through a STATE, not an observed — see part 2
# for why that matters.
#
# PART 2 asserts this binding's own EXCLUSION from the shared
# `rhs_time_derivative` conformance category, following the convention
# `assertion_nonfinite` established: an exclusion is invisible by construction,
# so it has to be asserted somewhere that goes red when it stops being true.
# The two gaps are in `run_inline_tests`, not in the §4.2 transform:
#
#   1. it cannot READ a 0-D observed — `_evaluate_assertion`'s pointwise branch
#      resolves the asserted name against the state vector alone (`_scalar_slot`)
#      with no state-free-observed fallback, so `dxdt ~ D(x, t)` answers
#      "scalar state 'dxdt' not found";
#   2. it does not REFUSE an unresolvable right-hand-side `D` — the category's
#      two refusal fixtures build and solve without complaint, so the
#      `unlowered_operator` contract §4.2 requires is unmet on this path (the
#      gate in `tree_walk/compile.jl` belongs to the other runner).
#
# When either is fixed, part 2 fails and Julia should move into
# `bindings_required` with a real adapter.

using Test
using JSON3
using EarthSciAST
import SciMLBase
import OrdinaryDiffEqTsit5

include("testutils.jl")  # TESTUTILS_REPO_ROOT

const _RTD_DIR = joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance",
                          "rhs_time_derivative")

"Every structural `D` (`wrt` absent or `\"t\"`) reachable from `e`."
function _structural_ds(e)
    out = Any[]
    walk(x) = begin
        if x isa EarthSciAST.OpExpr
            if x.op == "D" && (x.wrt === nothing || x.wrt == "t")
                push!(out, x)
            end
            EarthSciAST.foreach_child(walk, x)
        end
        nothing
    end
    walk(e)
    return out
end

"The right-hand side of the `name ~ …` equation of `flat`, or `nothing`."
function _rhs_of(flat, name)
    idx = findfirst(eq -> eq.lhs isa EarthSciAST.VarExpr &&
                          (eq.lhs::EarthSciAST.VarExpr).name == name,
                    flat.equations)
    return idx === nothing ? nothing : flat.equations[idx].rhs
end

"The right-hand side of the `D(name)/dt ~ …` equation of `flat`, or `nothing`."
function _d_rhs_of(flat, name)
    idx = findfirst(flat.equations) do eq
        eq.lhs isa EarthSciAST.OpExpr && (eq.lhs::EarthSciAST.OpExpr).op == "D" &&
            !isempty((eq.lhs::EarthSciAST.OpExpr).args) &&
            (eq.lhs::EarthSciAST.OpExpr).args[1] isa EarthSciAST.VarExpr &&
            ((eq.lhs::EarthSciAST.OpExpr).args[1]::EarthSciAST.VarExpr).name == name
    end
    return idx === nothing ? nothing : flat.equations[idx].rhs
end

@testset "§4.2 right-hand-side D — Julia resolves the tendency (flatten step 3c)" begin
    path = joinpath(_RTD_DIR, "fixtures", "tendency_resolution.esm")
    @test isfile(path)
    flat = EarthSciAST.flatten(load_path(path))

    rhs_of(name) = _rhs_of(flat, name)
    d_rhs_of(name) = _d_rhs_of(flat, name)

    @testset "own-state form: dxdt ~ D(x, t) becomes x's tendency" begin
        rhs = rhs_of("M.dxdt")
        @test rhs !== nothing
        @test isempty(_structural_ds(rhs))
        rendered = string(rhs)
        @test occursin("M.kx", rendered) && occursin("M.x", rendered)
    end

    @testset "chained form: D(l)/dt ~ sla*D(b)/dt resolves transitively" begin
        rhs = d_rhs_of("M.l")
        @test rhs !== nothing
        @test isempty(_structural_ds(rhs))
        rendered = string(rhs)
        @test occursin("M.sla", rendered) && occursin("M.growth", rendered)
    end

    @testset "scoped form: D(Chem.A, t) is the mechanism's mass-action tendency" begin
        # The tendency exists only because §7.4 lowered the reaction list, so
        # this is the shape that needs the phase to run AFTER reaction lowering.
        rhs = rhs_of("M.dAdt")
        @test rhs !== nothing
        @test isempty(_structural_ds(rhs))
        rendered = string(rhs)
        @test occursin("Chem.k", rendered) && occursin("Chem.A", rendered)
    end

    @testset "left-hand sides are never rewritten" begin
        # Every differential equation must still HAVE its `D` LHS; resolving one
        # away would silently turn an ODE into an algebraic equation.
        for name in ("M.x", "M.b", "M.l", "Chem.A", "Chem.B")
            @test d_rhs_of(name) !== nothing
        end
    end

    @testset "chain rule: D of an OBSERVED resolves through its definition" begin
        # `combo ~ 2*x` carries no d(combo)/dt equation, but its DEFINITION does
        # one level down. Substituting the definition and applying the product
        # rule is the whole of it — no differentiation engine, and no arbitrary
        # stop one substitution short of the answer.
        f = EarthSciAST.flatten(load_path(joinpath(_RTD_DIR, "fixtures", "d_of_observed.esm")))
        rhs = _rhs_of(f, "M.dcombo")
        @test rhs !== nothing
        @test isempty(_structural_ds(rhs))
        rendered = string(rhs)
        @test occursin("M.k", rendered) && occursin("M.x", rendered)
    end

    @testset "product rule: D of a COMPOUND resolves, with a parameter factor at 0" begin
        f = EarthSciAST.flatten(load_path(joinpath(_RTD_DIR, "fixtures", "d_of_compound.esm")))
        rhs = _rhs_of(f, "M.dscaled")
        @test rhs !== nothing
        @test isempty(_structural_ds(rhs))
        @test occursin("M.scale", string(rhs))
    end

    @testset "a TIME-INVARIANT name differentiates to a literal 0" begin
        # A parameter does not vary with t, so `D(k, t)` is 0 — and folding
        # makes it the literal `0`, not a sum of zero terms, so a downstream
        # classifier can still read it as constant.
        f = EarthSciAST.flatten(load_path(joinpath(_RTD_DIR, "fixtures", "d_of_parameter.esm")))
        rhs = _rhs_of(f, "M.dk")
        @test rhs !== nothing
        @test isempty(_structural_ds(rhs))
        @test rhs isa EarthSciAST.NumExpr && (rhs::EarthSciAST.NumExpr).value == 0.0
    end

    @testset "what the resolution CANNOT answer is left exactly as authored" begin
        # The closed set stops at `+ - neg * /`. `^` needs the power RULE, and a
        # self-referential tendency would substitute into itself without end —
        # so both survive untouched, for the `unlowered_operator` gate to refuse.
        for (file, lhs) in (("d_of_unsupported.esm", "M.dsq"),
                            ("d_of_cycle.esm",       "M.dx"))
            f = EarthSciAST.flatten(load_path(joinpath(_RTD_DIR, "fixtures", file)))
            rhs = _rhs_of(f, lhs)
            @test rhs !== nothing
            rhs === nothing && continue
            @test length(_structural_ds(rhs)) == 1
        end
    end

    @testset "the cycle guard terminates rather than overflowing" begin
        # The load above already proves it — an unguarded substitution does not
        # return at all — but assert the SHAPE too: `D(x)/dt ~ k*D(x, t)` keeps
        # its own `D` on the right, rather than being expanded one level and
        # silently truncated.
        f = EarthSciAST.flatten(load_path(joinpath(_RTD_DIR, "fixtures", "d_of_cycle.esm")))
        d_rhs = _d_rhs_of(f, "M.x")
        @test d_rhs !== nothing
        @test length(_structural_ds(d_rhs)) == 1
    end

    @testset "non-vacuity: the chained tendency reaches the trajectory" begin
        # The assertion that proves the phase is not merely cosmetic, and the
        # one shape this runner CAN read: `l` is a STATE. Its tendency names
        # `D(b)/dt`, so without step 3c the derivative never resolves and `l`
        # stays at its initial 1.0 instead of reaching 1 + 3*sla*growth = 31.
        results = run_inline_tests(path; model_name="M",
                                alg=OrdinaryDiffEqTsit5.Tsit5(),
                                reltol=1e-12, abstol=1e-14)
        row = only(r for r in results if r.variable == "l")
        @test row.actual !== nothing
        @test row.actual !== nothing && isapprox(Float64(row.actual), 31.0; rtol=1e-8)
        @test row.passed
    end
end

@testset "§4.2 right-hand-side D — Julia's exclusion from the shared category" begin
    manifest = JSON3.read(read(joinpath(_RTD_DIR, "manifest.json"), String))
    @test manifest.category == "rhs_time_derivative"

    # The exclusion must be declared, and it must carry a reason.
    @test !("julia" in manifest.bindings_required)
    @test haskey(manifest.scope_excluded, :julia)
    @test !isempty(strip(String(manifest.scope_excluded.julia)))

    # The fixture still LOADS and FLATTENS here — a category whose document one
    # binding cannot even parse would be a format divergence hiding behind a
    # scope exclusion, which is a different and worse thing than a runner gap.
    for fixture in manifest.fixtures
        p = joinpath(_RTD_DIR, String(fixture.path))
        @test isfile(p)
        @test EarthSciAST.flatten(load_path(p)) !== nothing
    end

    # And the gaps are real, so the exclusion is honest. Both are asserted
    # directly: when either stops being true this test fails and Julia should
    # join `bindings_required`.
    @testset "gap 1: a 0-D observed is unreadable by run_inline_tests" begin
        results = run_inline_tests(joinpath(_RTD_DIR, "fixtures", "tendency_resolution.esm");
                                model_name="M", alg=OrdinaryDiffEqTsit5.Tsit5(),
                                reltol=1e-12, abstol=1e-14)
        row = only(r for r in results if r.variable == "dxdt")
        @test row.actual === nothing
        @test occursin("not found", row.message)
    end

    @testset "gap 2: an unresolvable right-hand-side D is not refused" begin
        results = run_inline_tests(joinpath(_RTD_DIR, "fixtures", "d_of_unsupported.esm");
                                model_name="M", alg=OrdinaryDiffEqTsit5.Tsit5(),
                                reltol=1e-12, abstol=1e-14)
        row = only(r for r in results if r.variable == "dsq")
        # §4.2 requires `unlowered_operator`. It is not produced: the run builds
        # and solves, and only the assertion lookup fails.
        @test !occursin("unlowered_operator", row.message)
    end
end
