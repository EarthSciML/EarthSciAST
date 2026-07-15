# Execution runner for inline `tests` blocks (schema gt-cc1).
#
# The `tests/valid/tests_examples_comprehensive.esm` fixture exists for
# schema coverage of the inline `tests` / `examples` surface — parsing and
# round-trip only. This file closes the schema-vs-execution gap for the
# Julia reference binding: it walks every Model's inline `tests` list,
# builds the MTK system, applies `initial_conditions` and
# `parameter_overrides`, solves across the test's `time_span`, and
# verifies each `Assertion` against the resolved tolerance (assertion
# → test → model). Without this, a regression in the `tests`-block
# execution path outside of the arrayop-specific fixtures would pass CI.
using Test
using EarthSciAST
import ModelingToolkit
import OrdinaryDiffEqTsit5
import OrdinaryDiffEqNonlinearSolve

const _ESM_TB = EarthSciAST
const _MTK_TB = ModelingToolkit

# Resolve a local name ("N", "r", ...) against a compiled MTK system,
# searching unknowns first, then parameters. The flattener namespaces
# names as `Model.local`, which the MTK extension sanitizes to
# `Model_local`; we match either the exact name or the `_local` suffix.
function _find_sym(simp, system_name::Symbol, local_name::AbstractString)
    suffix = "_" * local_name
    for u in _MTK_TB.unknowns(simp)
        nm = string(_MTK_TB.getname(u))
        (nm == local_name || endswith(nm, suffix)) && return u
    end
    for p in _MTK_TB.parameters(simp)
        nm = string(_MTK_TB.getname(p))
        (nm == local_name || endswith(nm, suffix)) && return p
    end
    error("No symbol '$local_name' on compiled $(system_name) system " *
          "(unknowns=$(_MTK_TB.unknowns(simp)), " *
          "parameters=$(_MTK_TB.parameters(simp)))")
end

# Resolve (rel, abs) precedence: assertion-level wins, then test-level,
# then model-level. An unset field contributes 0. Falls back to rtol=1e-6
# when nothing is configured.
function _resolve_tol(model_tol, test_tol, assertion_tol)
    for cand in (assertion_tol, test_tol, model_tol)
        cand === nothing && continue
        r = cand.rel === nothing ? 0.0 : cand.rel
        a = cand.abs === nothing ? 0.0 : cand.abs
        return (r, a)
    end
    return (1.0e-6, 0.0)
end

function _run_one_test(simp, system_name::Symbol,
                       model_tol, t::_ESM_TB.InlineTest)
    u0_map = Dict{Any,Float64}()
    for (name, val) in t.initial_conditions
        u0_map[_find_sym(simp, system_name, name)] = Float64(val)
    end
    p_map = Dict{Any,Float64}()
    for (name, val) in t.parameter_overrides
        p_map[_find_sym(simp, system_name, name)] = Float64(val)
    end

    tspan = (t.time_span.start, t.time_span.stop)
    # Current MTK prefers a single merged u0+p map; the 4-arg form is
    # deprecated. Merging is safe here because u0_map and p_map key off
    # disjoint symbolic handles (unknowns vs parameters).
    combined = Dict{Any,Float64}()
    for (k, v) in u0_map; combined[k] = v; end
    for (k, v) in p_map;  combined[k] = v; end
    prob = _MTK_TB.ODEProblem(simp, combined, tspan)
    sol = OrdinaryDiffEqTsit5.solve(prob, OrdinaryDiffEqTsit5.Tsit5();
                                    reltol=1e-10, abstol=1e-12)
    @test sol.retcode == _MTK_TB.SciMLBase.ReturnCode.Success

    for a in t.assertions
        handle = _find_sym(simp, system_name, a.variable)
        rel, abs_ = _resolve_tol(model_tol, t.tolerance, a.tolerance)
        actual = sol(a.time, idxs=handle)
        if abs_ > 0 && iszero(a.expected)
            @test isapprox(actual, a.expected; atol=abs_)
        elseif rel > 0
            @test isapprox(actual, a.expected; rtol=rel, atol=abs_)
        else
            @test isapprox(actual, a.expected; atol=abs_)
        end
    end
end

# Execute every inline `tests` block / `ReactionSystem` tests list inside
# a single .esm fixture. Shared by the comprehensive fixture and the
# tests/simulation/ physics fixtures (gt-l5b).
function _execute_fixture_tests(fpath::AbstractString; label::AbstractString=basename(fpath))
    file = _ESM_TB.load(fpath)
    ran = false
    if file.models !== nothing
        for (mname, model) in file.models
            isempty(model.tests) && continue
            ran = true
            sys = _MTK_TB.System(model; name=Symbol(mname))
            simp = _MTK_TB.mtkcompile(sys)
            for t in model.tests
                @testset "$(label)/$(mname)/$(t.id)" begin
                    _run_one_test(simp, Symbol(mname), model.tolerance, t)
                end
            end
        end
    end
    if file.reaction_systems !== nothing
        for (rsname, rsys) in file.reaction_systems
            isempty(rsys.tests) && continue
            ran = true
            flat = _ESM_TB.flatten(rsys; name=String(rsname))
            sys = _MTK_TB.System(flat; name=Symbol(rsname))
            simp = _MTK_TB.mtkcompile(sys)
            for t in rsys.tests
                @testset "$(label)/$(rsname)/$(t.id)" begin
                    _run_one_test(simp, Symbol(rsname), rsys.tolerance, t)
                end
            end
        end
    end
    return ran
end

@testset "Inline tests-block execution runner" begin
    fixture_path = joinpath(@__DIR__, "..", "..", "..",
                            "tests", "valid",
                            "tests_examples_comprehensive.esm")
    @test isfile(fixture_path)

    any_tests = _execute_fixture_tests(fixture_path; label="tests_examples_comprehensive")
    @test any_tests

    # tests/simulation/ physics fixtures — gt-l5b migrated these from the
    # filesystem-paired `.esm` + `reference_solutions/*.json` convention to
    # inline `tests` blocks. Walk the directory so newly-migrated fixtures
    # are picked up automatically without editing this runner.
    #
    # Known-broken fixtures exercise Julia-binding gaps rather than spec
    # gaps; they stay in the directory (the schema / other bindings can
    # still use them) but are skipped here until the underlying bugs land.
    simulation_skip = Dict(
        # bouncing_ball.esm is driven by a REAL assertion below
        # ("continuous events fire (audit J2)") rather than by this generic
        # inline-tests runner. Its `tests` block pins a reference trajectory
        # that disagrees with the exactly-computable analytic one — it expects
        # h(1.984081) = 4.882389 where the closed form gives 4.71543 — so
        # running it would assert a wrong physics, and the fixture is shared
        # (this binding must not edit it). The real assertion below checks the
        # thing J2 is actually about: that the event EXISTS, that it lowers to
        # the right zero-crossing equation, and that it FIRES.
        "bouncing_ball.esm" => "driven by the explicit J2 continuous-event testset below",
        # PDE fixtures (spatial independent variables) — the System()
        # constructor routes to ModelingToolkit.PDESystem, which this
        # ODE-only runner does not drive. A parallel PDE runner is out
        # of scope for the inline tests-block contract; schema + other
        # bindings still consume these fixtures.
        "spatial_diffusion.esm" => "PDE (no ODE runner path)",
        "spatial_limitation.esm" => "PDE (no ODE runner path)",
    )
    simulation_dir = joinpath(@__DIR__, "..", "..", "..",
                              "tests", "simulation")
    if isdir(simulation_dir)
        sim_files = sort(filter(f -> endswith(f, ".esm"),
                                readdir(simulation_dir)))
        @testset "tests/simulation fixtures" begin
            for fname in sim_files
                fpath = joinpath(simulation_dir, fname)
                if haskey(simulation_skip, fname)
                    @testset "$(fname) [SKIPPED: $(simulation_skip[fname])]" begin
                        # `@test_skip false` — the old body — is a test that can
                        # NEVER pass even if the skip is lifted, so it can only
                        # ever hide a bug (audit 2026-07-14). Skip the REAL call
                        # instead: unskipping it is then a one-line change and
                        # the recorded Broken entry names the thing it defers.
                        @test_skip _execute_fixture_tests(fpath; label=fname)
                    end
                    continue
                end
                @testset "$(fname)" begin
                    _execute_fixture_tests(fpath; label=fname)
                end
            end
        end
    end
end

# ---------------------------------------------------------------------------
# Audit 2026-07-14, finding J2 — MTK continuous events.
#
# `ext/mtk_ext/variables.jl` handed `SymbolicContinuousCallback` the raw `Num`
# that `_esm_to_symbolic` produces. MTK takes `conditions::Vector{Equation}` —
# a vector of ZERO-CROSSING functions — so every model carrying a continuous
# event died at System() construction with
#
#     MethodError: no method matching SymbolicContinuousCallback(::Num, ::Vector{Equation})
#
# making the whole `continuous_events` feature non-functional. It was invisible
# because this file replaced the fixture with `@test_skip false` — a test that
# can never pass, and therefore can only ever hide the bug it stands in for.
#
# This is the assertion that stands in its place. It is deliberately about the
# things J2 is about — the event exists, it lowers to the right root equation,
# and it FIRES — and NOT about `bouncing_ball.esm`'s inline `tests` block, whose
# pinned reference trajectory disagrees with the exactly-computable analytic one
# (it expects h(1.984081) = 4.882389; the closed form gives 4.71543).
# ---------------------------------------------------------------------------
@testset "continuous events fire (audit J2)" begin
    fpath = joinpath(@__DIR__, "..", "..", "..",
                     "tests", "simulation", "bouncing_ball.esm")
    @test isfile(fpath)
    model = _ESM_TB.load(fpath).models["BallDynamics"]

    # 1. It BUILDS. This alone is the J2 regression guard: before the fix this
    #    line threw a MethodError for every model with a continuous event.
    sys = _MTK_TB.System(model)
    cevs = _MTK_TB.continuous_events(sys)
    @test length(cevs) == 1

    # 2. The condition lowered to a root-finding EQUATION, not a raw Num. The
    #    fixture's condition is the bare variable `height`, so the crossing is
    #    `height ~ 0`.
    conds = cevs[1].conditions
    @test conds isa Vector{<:_MTK_TB.Equation}
    @test length(conds) == 1
    @test occursin("height", string(conds[1].lhs))
    # `iszero`/`isequal` against a symbolic RHS do not reduce to a Bool here,
    # so compare the rendered form.
    @test string(conds[1].rhs) == "0"

    # 3. It FIRES. Free fall from h=10 under g=9.81 reaches h(1.984081) =
    #    -9.31 m — the ball would be 9 m BELOW the floor. The bounce puts it at
    #    +4.715 m, which is the closed form
    #        t_bounce = sqrt(2*10/9.81) = 1.42784,  v- = -14.0070,
    #        v+ = 0.8*14.0070 = 11.2056,
    #        h(t) = v+*(t - t_bounce) - g/2*(t - t_bounce)^2 = 4.71543.
    #    Nothing but a fired event can put the ball above the floor here, so
    #    this is a real, falsifiable "the event fired" assertion.
    simp = _MTK_TB.mtkcompile(sys)
    prob = _MTK_TB.ODEProblem(simp, Dict(), (0.0, 2.0))
    sol = OrdinaryDiffEqTsit5.solve(prob, OrdinaryDiffEqTsit5.Tsit5();
                                    reltol=1e-10, abstol=1e-12)
    @test sol.retcode == _MTK_TB.SciMLBase.ReturnCode.Success

    hsym = _find_sym(simp, :BallDynamics, "height")
    vsym = _find_sym(simp, :BallDynamics, "velocity")

    @test isapprox(sol(0.0, idxs=hsym), 10.0; atol=1e-8)          # start
    @test sol(1.0, idxs=hsym) > 0                                  # still falling
    @test isapprox(sol(1.0, idxs=hsym), 10 - 9.81/2; atol=1e-4)    # free fall pre-bounce

    # Post-bounce: above the floor (free fall would be far below it) and moving
    # UPWARD (free fall would still be moving down).
    h_after = sol(1.984081, idxs=hsym)
    v_after = sol(1.984081, idxs=vsym)
    @test h_after > 0
    @test isapprox(h_after, 4.71543; atol=1e-3)
    @test v_after > 0
    @test isapprox(v_after, 11.2056 - 9.81 * (1.984081 - 1.427843); atol=1e-3)
end
