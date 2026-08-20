# Derived variable classification (esm-spec §6.3.1) against the cross-binding
# oracle in `tests/conformance/classification/`.
#
# esm 1.0.0 declares two variable types and derives every finer category a
# solver needs. These fixtures are the one answer all five bindings are compared
# against, so this file asserts the goldens directly rather than re-stating the
# rules in Julia-local expectations.

using Test
using EarthSciAST
using JSON3

include("testutils.jl")

const _CLS_DIR = joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance", "classification")
include(joinpath(@__DIR__, "..", "scripts", "classification_adapter.jl"))
const _CLS = ClassificationConformanceAdapter

@testset "Classification API (esm-spec §6.3.1)" begin
    manifest_path = joinpath(_CLS_DIR, "manifest.json")
    @test isfile(manifest_path)
    manifest = JSON3.read(read(manifest_path, String))

    @testset "golden agreement — $(String(fx["id"]))" for fx in manifest["fixtures"]
        fixture_path = joinpath(_CLS_DIR, String(fx["fixture"]))
        golden_path = joinpath(_CLS_DIR, String(fx["golden"]))
        @test isfile(fixture_path)
        @test isfile(golden_path)

        got = _CLS.classify_fixture(fixture_path)["models"]
        want = JSON3.read(read(golden_path, String))["models"]

        # Same set of model NODES: a binding that flattens the document before
        # classifying returns one merged node where the golden expects two.
        @test sort!(collect(keys(got))) == sort!(String[String(k) for k in keys(want)])

        for (mname, wmodel) in pairs(want)
            gmodel = got[String(mname)]
            for key in ("ode_states", "observed_unknowns", "algebraic_unknowns",
                        "brownian_parameters", "discrete_parameters",
                        "sampled_parameters", "constant_parameters")
                @test (String(mname), key, gmodel[key]) ==
                      (String(mname), key, String[String(x) for x in wmodel[key]])
            end
            @test (String(mname), gmodel["system_kind"]) ==
                  (String(mname), String(wmodel["system_kind"]))
            # `declared_system_kind` is absent from a golden that does not pin
            # it; where present, `null` means the model omits the field.
            if haskey(wmodel, "declared_system_kind")
                w = wmodel["declared_system_kind"]
                @test gmodel["declared_system_kind"] ==
                      (w === nothing ? nothing : String(w))
            end
        end
    end

    @testset "the sets PARTITION their side of the variables" begin
        # §6.3.1 states the partition normatively, so it is checked on every
        # fixture rather than trusted. `assert_classification_partitions` throws
        # on an overlap or a gap; `classify_fixture` calls it per model node.
        for fx in manifest["fixtures"]
            path = joinpath(_CLS_DIR, String(fx["fixture"]))
            @test _CLS.classify_fixture(path) isa AbstractDict
        end
    end

    @testset "is_ode_state agrees with ode_states" begin
        file = EarthSciAST.load(joinpath(_CLS_DIR, "fixtures", "basic_partition.esm"))
        m = file.models["M"]
        states = Set(ode_states(m))
        for name in keys(m.variables)
            @test is_ode_state(m, name) == (name in states)
        end
        # A name the model does not declare is not an ODE state, and asking is
        # not an error.
        @test is_ode_state(m, "not_declared") == false
    end

    @testset "a derivative LHS may be wrapped (D(u), D(u[i]), aggregate{D(...)})" begin
        # `tests/valid/cadence/observed_leaf_seeds.esm` writes its state
        # equation as an `aggregate` whose body is `D(index(u,i))`. A binding
        # that only recognises a bare `D(u)` LHS misses the state entirely and
        # then reports every unknown as algebraic.
        path = joinpath(TESTUTILS_REPO_ROOT, "tests", "valid", "cadence",
                        "observed_leaf_seeds.esm")
        if _require_fixture(path)
            m = EarthSciAST.load(path).models["ObservedLeafSeeds"]
            @test ode_states(m) == ["u"]
            @test observed_unknowns(m) == ["geom", "geom_chain", "k_scaled", "u_scaled"]
            @test algebraic_unknowns(m) == String[]
            @test discrete_parameters(m) == ["Kdiff"]
            @test constant_parameters(m) == ["dx"]
        end
    end

    @testset "observed_definitions resolves out of declaration order" begin
        path = joinpath(_CLS_DIR, "fixtures", "observed_chain.esm")
        m = EarthSciAST.load(path).models["M"]
        defs = observed_definitions(m)
        @test sort!(collect(keys(defs))) == ["y", "z"]
        # `z ~ y*2` is declared FIRST and resolved LAST; the definition it maps
        # to is its own equation's RHS, not the first equation in the file.
        @test defs["z"] isa OpExpr
        @test observed_definition(m, "y") === defs["y"]
        @test observed_definition(m, "x") === nothing   # an ODE state, not observed
    end

    @testset "system_kind derivation: order is sde → pde → nonlinear → ode" begin
        pde = EarthSciAST.load(joinpath(_CLS_DIR, "fixtures", "system_kind_pde.esm"))
        # A spatial `D` (wrt an axis) and the grad/div/laplacian sugar are both
        # the pde signal; neither spelling is canonical.
        @test system_kind(pde.models["Transient"]) == "pde"
        @test system_kind(pde.models["SugarOps"]) == "pde"
        # pde BEFORE nonlinear: a steady-state PDE has no time derivative.
        @test system_kind(pde.models["SteadyState"]) == "pde"
        @test has_time_derivative(pde.models["SteadyState"]) == false
        # sde BEFORE pde: there is no SPDESystem to select.
        @test system_kind(pde.models["StochasticSpatial"]) == "sde"
        @test has_spatial_derivative(pde.models["StochasticSpatial"]) == true

        # The document declares ONE domain shared by all four models, which is
        # the discriminator: a binding deriving `pde` from the presence of a
        # domain block classifies all four alike.
        @test pde.domain !== nothing
    end

    @testset "system_kind_mismatch fires only on a contradicting field" begin
        variants = EarthSciAST.load(
            joinpath(_CLS_DIR, "fixtures", "system_kind_variants.esm"))
        # `Declared` carries a field that AGREES — no mismatch.
        @test declared_system_kind_mismatch(variants.models["Declared"]) === nothing
        # An absent field is never a mismatch.
        @test declared_system_kind_mismatch(variants.models["Sde"]) === nothing

        # A contradicting field is reported as (declared, derived).
        sde = variants.models["Sde"]
        wrong = Model(sde.variables, sde.equations; system_kind="ode")
        @test declared_system_kind_mismatch(wrong) == ("ode", "sde")
        errs = validate_structural(EsmFile("1.0.0", Metadata("M");
                                           models=Dict("Wrong" => wrong)))
        @test any(e -> e.error_type == "system_kind_mismatch", errs)
    end

    @testset "a distribution alone is NOT Brownian; an update alone is not either" begin
        m = EarthSciAST.load(
            joinpath(_CLS_DIR, "fixtures", "parameter_cadences.esm")).models["M"]
        # The two easy mistakes the fixture is built to catch.
        @test !("p_sampled" in brownian_parameters(m))
        @test !("p_uniform_sampled" in brownian_parameters(m))
        @test brownian_parameters(m) == ["p_wiener"]
        # The handler and `from` value forms classify exactly like `expression`.
        @test "p_handler" in discrete_parameters(m)
        @test "p_data" in discrete_parameters(m)
    end
end
