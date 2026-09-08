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
#   * `output_selection` — a name-keyed READ of a finished run resolves to the
#     survivor instead of reporting a variable that never existed. In THIS
#     binding the result is a SciML solution object, which the package does not
#     own; what it does own is `observed_field(prob, name)`, the problem-side
#     name lookup, so that is what the surface asserts here.
#
# Like `operator_compose_merge` the category carries no golden: what it pins is
# REACH, asserted as structure.

# `using Test` MUST precede the testutils include: testutils.jl uses `@test_skip`
# at top level, so `Test` has to be in scope in `Main` already.
using Test
using EarthSciAST
using JSON3

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

_mrr_flatten(case) = flatten(load_path(joinpath(_MRR_DIR, String(case.path))))

@testset "conformance: merged_rename_reach (§4.7.1 step 4)" begin
    @testset "the manifest is not empty and names this binding" begin
        # Zero cases would make every testset below vacuously green.
        @test !isempty(_MRR_FLATTEN)
        @test !isempty(_MRR_OVERRIDE)
        @test !isempty(_MRR_OUTPUT)
        @test "julia" in _MRR_MANIFEST.surfaces.flatten.bindings
        @test "julia" in _MRR_MANIFEST.surfaces.override_keys.bindings
        @test "julia" in _MRR_MANIFEST.surfaces.output_selection.bindings
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
            for (name, unresolved) in pairs(case.default_without_resolution)
                slot = get(prob.var_map, String(name), nothing)
                if slot !== nothing
                    @test !(prob.u0[slot] ≈ Float64(unresolved))
                end
            end
        end
    end
end
