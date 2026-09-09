# Conformance harness adapter — merged-away rename REACH (Julia).
#
# Driven by the shared manifest at
# tests/conformance/merged_rename_reach/manifest.json
# (esm-libraries-spec §4.7.1 step 4 and §4.7.5 step 3 ordering;
# EarthSciML/EarthSciAST#230).
#
# An `operator_compose` renaming match folds `B.x` into `A.x`, deleting `B.x`
# and rewriting every equation off it. That rewrite reaches equation ASTs and
# nothing else, and `operator_compose` entries run BEFORE `couple` and
# `variable_map` — so a later entry's `from`/`to`, plain scoped-reference
# STRINGS on the entry object, could still name a spelling that no longer
# exists. This file pins that they RESOLVE to the survivor, on both surfaces
# the manifest defines:
#
#   * `flatten` — a later `couple` connector lands on the survivor's tendency
#     instead of matching nothing and being dropped in SILENCE; a later
#     `variable_map` substitutes the survivor instead of injecting a name the
#     flattened system cannot resolve.
#   * `override_keys` — a caller's `initial_conditions` key naming the dead
#     spelling addresses the survivor instead of being dropped so the state runs
#     from its declared default.
#   * `output_selection` — a name-keyed READ of a finished run. This binding is
#     EXCLUDED from that surface and asserts its own exclusion below: the result
#     is a SciML `ODESolution` indexed through SciMLBase's own `SymbolCache`, so
#     the package fills the name list (`_symbol_cache`) but does not own the
#     lookup. What it DOES own — the problem-side `observed_field(prob, name)`
#     — resolves through `EsmProblem.merged_renames`, and that is pinned here
#     directly.
#
# Like `operator_compose_merge` the category carries no golden: what it pins is
# REACH, asserted as structure.

# `using Test` MUST precede the testutils include: testutils.jl uses `@test_skip`
# at top level, so `Test` has to be in scope in `Main` already.
using Test
using EarthSciAST
using JSON3
using OrdinaryDiffEqTsit5   # the inline-test surface needs an ODE algorithm

include("testutils.jl")  # TESTUTILS_REPO_ROOT

const _MRR_DIR = joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance",
                          "merged_rename_reach")

# A missing manifest is a hard failure, not a skip: the manifest IS the contract
# this file exists to enforce.
@assert isfile(joinpath(_MRR_DIR, "manifest.json")) "manifest not found in $(_MRR_DIR)"
const _MRR_MANIFEST = JSON3.read(read(joinpath(_MRR_DIR, "manifest.json"), String))
const _MRR_CASES = _MRR_MANIFEST.cases
const _MRR_FLATTEN = [c for c in _MRR_CASES if c.surface == "flatten"]
const _MRR_OVERRIDE = [c for c in _MRR_CASES if c.surface == "override_keys"]
const _MRR_OUTPUT = [c for c in _MRR_CASES if c.surface == "output_selection"]
const _MRR_EVENTS = [c for c in _MRR_CASES if c.surface == "events_and_updates"]
const _MRR_REGISTRY = [c for c in _MRR_CASES if c.surface == "template_registry"]
const _MRR_INLINE = [c for c in _MRR_CASES if c.surface == "inline_tests"]

_mrr_flatten(case) = flatten(load_path(joinpath(_MRR_DIR, String(case.path))))

@testset "conformance: merged_rename_reach (§4.7.1 step 4)" begin
    @testset "the manifest is not empty and names this binding" begin
        # Zero cases would make every testset below vacuously green.
        @test !isempty(_MRR_FLATTEN)
        @test !isempty(_MRR_OVERRIDE)
        @test !isempty(_MRR_OUTPUT)
        @test !isempty(_MRR_EVENTS)
        @test !isempty(_MRR_REGISTRY)
        @test !isempty(_MRR_INLINE)
        for surface in ("events_and_updates", "template_registry", "inline_tests")
            @test "julia" in _MRR_MANIFEST.surfaces[Symbol(surface)].bindings
        end
        @test "julia" in _MRR_MANIFEST.surfaces.flatten.bindings
        @test "julia" in _MRR_MANIFEST.surfaces.override_keys.bindings
        # The result-object READ is out of scope HERE, and the manifest must say
        # WHY — an exclusion with no reason is indistinguishable from a gap.
        @test !("julia" in _MRR_MANIFEST.surfaces.output_selection.bindings)
        @test !isempty(_MRR_MANIFEST.surfaces.output_selection.scope_excluded.julia)
        @test _MRR_MANIFEST.merged_variable_renames_field.julia ==
              "FlattenMetadata.merged_variable_renames"
    end

    for case in _MRR_FLATTEN
        @testset "$(case.id)" begin
            flat = _mrr_flatten(case)

            # (1) The merge RECORDS which names it deleted. That map is what a
            # consumer addressing a state by name resolves through, so it is
            # part of the flattened form's contract, not a private detail.
            recorded = Dict{String,String}(String(k) => String(v)
                                           for (k, v) in flat.metadata.merged_variable_renames)
            expected = Dict{String,String}(String(k) => String(v)
                                           for (k, v) in pairs(case.merged_variable_renames))
            @test recorded == expected

            # (2) The merged-away name survives NOWHERE — not in the variable
            # tables, not in any equation. A reference left behind is a
            # reference to nothing.
            @test collect(keys(flat.state_variables)) == [String(s) for s in case.state_variables]
            for gone in case.no_equation_references
                g = String(gone)
                @test !haskey(flat.state_variables, g)
                @test !haskey(flat.parameters, g)
                @test !haskey(flat.observed_variables, g)
                for eq in flat.equations
                    rendered = string(to_ascii(eq.lhs), " = ", to_ascii(eq.rhs))
                    @test !occursin(g, rendered)
                end
            end

            # (3) The later entry LANDED, on the survivor. This is the
            # non-vacuity anchor for (2): dropping the entry's reference
            # outright would satisfy "the dead name survives nowhere" by doing
            # nothing at all.
            target = String(case.tendency_of)
            idx = findfirst(eq -> EarthSciAST.lhs_dependent_variable(eq.lhs) == target,
                            flat.equations)
            @test idx !== nothing
            if idx !== nothing
                rhs = to_ascii(flat.equations[idx].rhs)
                for name in case.tendency_references
                    @test occursin(String(name), rhs)
                end
            end
        end
    end

    for case in _MRR_OVERRIDE
        @testset "$(case.id)" begin
            # esm-spec §6.6.2's key resolution reaches through the merge's
            # rename map. Both halves are asserted: the key lands on the
            # survivor, and the value is the CALLER's rather than the state's
            # declared default — which is what an unresolved key silently left
            # in place.
            flat = _mrr_flatten(case)
            u0 = Dict{String,Float64}(String(k) => Float64(v)
                                      for (k, v) in pairs(case.initial_conditions))
            prob = EarthSciAST.esm_problem(flat, (0.0, 1.0); u0=u0)
            for (name, want) in pairs(case.resolves_to)
                slot = get(prob.var_map, String(name), nothing)
                @test slot !== nothing
                if slot !== nothing
                    @test prob.u0[slot] ≈ Float64(want)
                end
            end
            # The problem carries the merge map, which is what every
            # PROBLEM-SIDE name lookup in this binding resolves through --
            # `observed_field(prob, name)` above all. Without it that lookup has
            # nothing to consult, so this is the anchor for the half of
            # `output_selection` Julia does own.
            @test prob.merged_renames == flat.metadata.merged_variable_renames
            @test !isempty(prob.merged_renames)
            for (name, unresolved) in pairs(case.default_without_resolution)
                slot = get(prob.var_map, String(name), nothing)
                if slot !== nothing
                    @test !(prob.u0[slot] ≈ Float64(unresolved))
                end
            end
        end
    end
    for case in _MRR_EVENTS
        @testset "$(case.id)" begin
            # Neither an event nor an `update` rule is an equation, and both
            # address the state BY NAME. The affect's `lhs` is the sharp one: it
            # is a plain NAME string, so a walk that maps only EXPRESSIONS
            # rewrites the affect's RHS and leaves its target pointing at a
            # state the flattened system no longer declares.
            flat = _mrr_flatten(case)
            recorded = Dict{String,String}(String(k) => String(v)
                                           for (k, v) in flat.metadata.merged_variable_renames)
            expected = Dict{String,String}(String(k) => String(v)
                                           for (k, v) in pairs(case.merged_variable_renames))
            @test recorded == expected
            @test collect(keys(flat.state_variables)) == [String(s) for s in case.state_variables]

            affects = [a for ev in vcat(flat.discrete_events, flat.continuous_events)
                       for a in ev.affects]
            @test length(affects) == length(case.event_affects)
            for (affect, want) in zip(affects, case.event_affects)
                @test affect.lhs == String(want.lhs)
                rhs = to_ascii(affect.rhs)
                for name in want.rhs_references
                    @test occursin(String(name), rhs)
                end
            end

            for (var_name, wanted) in pairs(case.variable_updates)
                v = get(flat.parameters, String(var_name),
                        get(flat.state_variables, String(var_name), nothing))
                @test v !== nothing
                if v !== nothing && v.update !== nothing
                    rendered = join([to_ascii(r.expression) for r in v.update
                                     if r.expression !== nothing], " ")
                    for name in wanted
                        @test occursin(String(name), rendered)
                    end
                end
            end

            # The dead spelling survives in NEITHER, in either form: not the
            # qualified name a collect-time namespacing carries through, and not
            # the bare local a coupling-time one leaves behind.
            haystack = join(vcat(
                [to_ascii(a.rhs) for a in affects],
                [a.lhs for a in affects],
                [to_ascii(r.expression)
                 for v in vcat(collect(values(flat.parameters)),
                               collect(values(flat.state_variables)))
                 if v.update !== nothing for r in v.update if r.expression !== nothing]), " ")
            for gone in case.absent_from_events_and_updates
                @test !(String(gone) in split(haystack))
            end
        end
    end

    for case in _MRR_REGISTRY
        @testset "$(case.id)" begin
            # The ONE surface that refuses rather than resolves. A surviving
            # registry body is authored source that expands at the BUILD
            # boundary, so it can neither be left alone nor rewritten.
            err = nothing
            try
                _mrr_flatten(case)
            catch e
                err = e
            end
            @test err isa ExpressionTemplateError
            if err isa ExpressionTemplateError
                @test err.code == String(case.raises)
                for name in case.names_in_message
                    @test occursin(String(name), err.message)
                end
            end
        end
    end

    for case in _MRR_INLINE
        @testset "$(case.id)" begin
            # Both halves in one assertion. That it RESOLVES at all is the
            # assertion half. That the actual is the caller's value rather than
            # the survivor's declared default is the `initial_conditions` half:
            # a key that silently resolved to nothing would leave the run at
            # that default and the test would still return a verdict.
            results = run_inline_tests(joinpath(_MRR_DIR, String(case.path)); alg=Tsit5())
            matching = [r for r in results if r.test_id == String(case.test_id)]
            @test !isempty(matching)
            if !isempty(matching)
                r = matching[1]
                @test r.passed == case.passes
                @test r.actual !== nothing
                if r.actual !== nothing
                    @test isapprox(r.actual, Float64(case.expected); rtol=1e-6)
                    @test !isapprox(r.actual, Float64(case.default_without_resolution);
                                    rtol=1e-6)
                end
            end
        end
    end
end
