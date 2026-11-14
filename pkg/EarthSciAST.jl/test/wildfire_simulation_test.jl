# The coupled wildfire–atmosphere–ocean fixture
# `tests/valid/wildfire_atmosphere_ocean.esm` at the Julia build entry points.
#
# Its `OceanDynamics.SST -> AirSeaFluxCalculator.SST` variable_map declares
# `lifting: "mean"`, a kind esm-spec §10.5 reserves and no compiler here
# implements. A binding that builds a runnable problem MUST refuse it with
# `unsupported_construct`, naming the edge and the kind, rather than read the
# raw array where the document asks for its mean. Validation and flatten accept
# the document; only the build refuses. The last testset pins the refusal on a
# small inline document, for both reserved kinds.
using Test
using EarthSciAST
import SciMLBase
import OrdinaryDiffEqTsit5: Tsit5
const _ESS_WF = EarthSciAST

# The refusal a build of a document with a reserved lifting raises.
function _wf_build_error(f)
    try
        f()
    catch e
        return e
    end
    return nothing
end

function _wf_is_lifting_refusal(err, edge, kind)
    err isa _ESS_WF.TreeWalkError || return false
    err.code == _ESS_WF.ERROR_CODES.UNSUPPORTED_CONSTRUCT || return false
    msg = sprint(showerror, err)
    return occursin(edge, msg) && occursin("\"$(kind)\"", msg) &&
        occursin("esm-spec §10.5", msg) && occursin("not supported yet", msg)
end

@testset "wildfire_atmosphere_ocean.esm — the mean variable_map is refused at build" begin
    fixture = joinpath(
        @__DIR__, "..", "..", "..", "tests", "valid",
        "wildfire_atmosphere_ocean.esm"
    )
    @test isfile(fixture)

    file = _ESS_WF.load_path(fixture)
    ocean = file.models["OceanDynamics"]
    @test !isempty(ocean.tests)
    # Validation and flatten are unaffected.
    @test _ESS_WF.validate(file).is_valid
    @test _ESS_WF.flatten(file) isa _ESS_WF.FlattenedSystem

    edge = "OceanDynamics.SST -> AirSeaFluxCalculator.SST"
    @testset "esm_problem [$(c)]" for c in (:interpreter, :native)
        err = _wf_build_error(() -> _ESS_WF.esm_problem(fixture, (0.0, 3600.0); compiler = c))
        @test _wf_is_lifting_refusal(err, edge, "mean")
    end
    @testset "run_inline_tests" begin
        results = _ESS_WF.run_inline_tests(fixture; compiler = :interpreter)
        @test !isempty(results)
        @test all(r -> r.status != _ESS_WF.PASS, results)
        @test all(r -> occursin(edge, something(r.message, "")), results)
    end
end

# A small coupled document whose variable_map declares `lifting`.
function _wf_lifting_doc(kind)
    return Dict{String, Any}(
        "esm" => "2.2.0",
        "metadata" => Dict("name" => "reserved_lifting", "authors" => ["EarthSciAST test suite"]),
        "index_sets" => Dict("x" => Dict("kind" => "interval", "size" => 3)),
        "models" => Dict(
            "Grid" => Dict(
                "variables" => Dict(
                    "q" => Dict(
                        "type" => "parameter", "units" => "1", "default" => 1.0,
                        "shape" => ["x"]
                    )
                ),
                "equations" => []
            ),
            "Box" => Dict(
                "variables" => Dict(
                    "q_in" => Dict("type" => "parameter", "units" => "1", "default" => 0.0),
                    "y" => Dict("type" => "unknown", "units" => "1", "default" => 0.0)
                ),
                "equations" => [
                    Dict(
                        "lhs" => Dict("op" => "D", "args" => ["y"], "wrt" => "t"),
                        "rhs" => Dict("op" => "*", "args" => [0.1, "q_in"])
                    ),
                ]
            )
        ),
        "coupling" => [
            Dict(
                "type" => "variable_map", "from" => "Grid.q", "to" => "Box.q_in",
                "transform" => "param_to_var", "lifting" => kind
            ),
        ]
    )
end

@testset "a mean or integral variable_map lifting is refused at build (esm-spec §10.5)" begin
    @testset "$(kind)" for kind in ("mean", "integral")
        doc = _wf_lifting_doc(kind)
        file = _ESS_WF.load_document(doc)
        @test _ESS_WF.validate(file).is_valid
        @test _ESS_WF.flatten(file) isa _ESS_WF.FlattenedSystem
        @testset "[$(c)]" for c in (:interpreter, :native)
            err = _wf_build_error(() -> _ESS_WF.esm_problem(doc, (0.0, 1.0); compiler = c))
            @test _wf_is_lifting_refusal(err, "Grid.q -> Box.q_in", kind)
        end
    end
    # `broadcast` and `pointwise` are not refused.
    @testset "$(kind) is not refused" for kind in ("broadcast", "pointwise")
        file = _ESS_WF.load_document(_wf_lifting_doc(kind))
        @test _ESS_WF._refuse_reserved_liftings(file) === nothing
    end
end
