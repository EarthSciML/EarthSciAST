# esm-spec §4.2 — a RIGHT-HAND-SIDE structural `D` is the named unknown's
# tendency. This is Julia's side of the rule, in two parts.
#
# PART 1 pins what this binding implements: `flatten` step 3c substitutes a
# structural `D` over an unknown that CARRIES a differential equation with that
# unknown's tendency, recursing through chained tendencies, and leaves every
# other `D` exactly as authored. The end-to-end assertion goes through a STATE,
# not an observed — see part 2 for why that matters.
#
# PART 2 asserts this binding's own EXCLUSION from the shared
# `rhs_time_derivative` conformance category, following the convention
# `assertion_nonfinite` established: an exclusion is invisible by construction,
# so it has to be asserted somewhere that goes red when it stops being true.
# The two gaps are in `run_pde_tests`, not in the §4.2 transform:
#
#   1. it cannot READ a 0-D observed — `_evaluate_assertion`'s pointwise branch
#      resolves the asserted name against the state vector alone (`_scalar_slot`)
#      with no state-free-observed fallback, so `dxdt ~ D(x, t)` answers
#      "scalar state 'dxdt' not found";
#   2. it does not REFUSE an unresolvable right-hand-side `D` — the category's
#      three refusal fixtures build and solve without complaint, so the
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

@testset "§4.2 right-hand-side D — Julia resolves the tendency (flatten step 3c)" begin
    path = joinpath(_RTD_DIR, "fixtures", "tendency_resolution.esm")
    @test isfile(path)
    flat = EarthSciAST.flatten(load_path(path))

    rhs_of(name) = begin
        idx = findfirst(eq -> eq.lhs isa EarthSciAST.VarExpr &&
                              (eq.lhs::EarthSciAST.VarExpr).name == name,
                        flat.equations)
        idx === nothing ? nothing : flat.equations[idx].rhs
    end
    d_rhs_of(name) = begin
        idx = findfirst(flat.equations) do eq
            eq.lhs isa EarthSciAST.OpExpr && (eq.lhs::EarthSciAST.OpExpr).op == "D" &&
                !isempty((eq.lhs::EarthSciAST.OpExpr).args) &&
                (eq.lhs::EarthSciAST.OpExpr).args[1] isa EarthSciAST.VarExpr &&
                ((eq.lhs::EarthSciAST.OpExpr).args[1]::EarthSciAST.VarExpr).name == name
        end
        idx === nothing ? nothing : flat.equations[idx].rhs
    end

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

    @testset "an unresolvable D is left exactly as authored" begin
        # `D` of an observed, of a parameter, and of a compound expression: the
        # format defines no symbolic differentiation, so the phase must not
        # invent a substitution for any of them.
        for (file, lhs) in (("d_of_observed.esm",  "M.dcombo"),
                            ("d_of_parameter.esm", "M.dk"),
                            ("d_of_compound.esm",  "M.dscaled"))
            f = EarthSciAST.flatten(load_path(joinpath(_RTD_DIR, "fixtures", file)))
            i = findfirst(eq -> eq.lhs isa EarthSciAST.VarExpr &&
                                (eq.lhs::EarthSciAST.VarExpr).name == lhs,
                          f.equations)
            @test i !== nothing
            i === nothing && continue
            @test length(_structural_ds(f.equations[i].rhs)) == 1
        end
    end

    @testset "non-vacuity: the chained tendency reaches the trajectory" begin
        # The assertion that proves the phase is not merely cosmetic, and the
        # one shape this runner CAN read: `l` is a STATE. Its tendency names
        # `D(b)/dt`, so without step 3c the derivative never resolves and `l`
        # stays at its initial 1.0 instead of reaching 1 + 3*sla*growth = 31.
        results = run_pde_tests(path; model_name="M",
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
    @testset "gap 1: a 0-D observed is unreadable by run_pde_tests" begin
        results = run_pde_tests(joinpath(_RTD_DIR, "fixtures", "tendency_resolution.esm");
                                model_name="M", alg=OrdinaryDiffEqTsit5.Tsit5(),
                                reltol=1e-12, abstol=1e-14)
        row = only(r for r in results if r.variable == "dxdt")
        @test row.actual === nothing
        @test occursin("not found", row.message)
    end

    @testset "gap 2: an unresolvable right-hand-side D is not refused" begin
        results = run_pde_tests(joinpath(_RTD_DIR, "fixtures", "d_of_parameter.esm");
                                model_name="M", alg=OrdinaryDiffEqTsit5.Tsit5(),
                                reltol=1e-12, abstol=1e-14)
        row = only(r for r in results if r.variable == "dk")
        # §4.2 requires `unlowered_operator`. It is not produced: the run builds
        # and solves, and only the assertion lookup fails.
        @test !occursin("unlowered_operator", row.message)
    end
end
