# A definition whose body applies another definition, as the
# EarthSciDiscretizations conservative-overlap narrow phase is written:
# `A_ij(…)` is `pairs(…, area = area_ij(…))`, where `area_ij` reads the loop
# symbols i and j the skeleton `pairs` binds. The values run as the
# `geometry_templates` inline-test conformance tier (`nested_overlap_regrid`);
# this file pins the two ways the build failed on it:
#
#   * a structural instance made by a validation pass (the gated skeleton's
#     envelopes are parameters in a structural position) was registered in the
#     document's own registry, flatten then closed it like a declaration and
#     made the substituted names its parameters again, and the build refused
#     the reference ("cannot be compiled as a call: body (top apply_operator)");
#   * the dense skeleton is an array-valued definition read through element
#     calls, and the binding `area_ij(i = i, …)` the narrow phase passes it was
#     evaluated in the caller, where i is no name ("unbound name 'i'").

using Test
using EarthSciAST

include("testutils.jl")  # TESTUTILS_REPO_ROOT

const _NRC_PATH = joinpath(
    TESTUTILS_REPO_ROOT, "tests", "conformance", "geometry_templates", "fixtures", "nested_overlap_regrid.esm"
)

function _nrc_rhs(compiler::Symbol, path::AbstractString = _NRC_PATH)
    prob = EarthSciAST.esm_problem(path, (0.0, 1.0); compiler = compiler)
    prog = EarthSciAST.rhs_program(prob)
    du = zeros(length(prob.u0))
    EarthSciAST.rhs!(
        du, prog, EarthSciAST.rhs_workspace(prog), copy(prob.u0),
        zeros(EarthSciAST.tile_layout(prog).n_aux), EarthSciAST.parameter_vector(prog), 0.0,
        EarthSciAST.default_forcing_set(prog)
    )
    out = Dict{String, Float64}()
    for (k, v) in prob.var_map
        out[String(k)] = du[Int(v)]
    end
    return out
end

@testset "nested references compile as calls" begin
    # Loading validates the document; nothing a validation pass registers (a
    # structural instance, a view part) reaches the document's registry.
    file = EarthSciAST.load_path(_NRC_PATH)
    for (_, reg) in file.component_templates
        @test !any(k -> occursin('\0', k), keys(reg))
    end

    # E' = Σ_i A_ij F_i / A_j over the candidate pairs: 21/9, 33/9, 57/9, 69/9.
    expected = [21, 33, 57, 69] ./ 9
    for compiler in (:interpreter, :native)
        du = _nrc_rhs(compiler)
        got = [du[only(k for k in keys(du) if endswith(k, "E[$j]"))] for j in 1:4]
        @test isapprox(got, expected; rtol = 1.0e-14)
    end

    # The narrow-phase element reads the skeleton's loop symbols as IMPLICIT
    # parameters (no declared `i`, `j`), and the build sees the registry
    # unflattened, so the narrow phase passes them on as implicit bindings.
    # Their values must be the skeleton's loop symbols, not caller names that
    # happen to share the spelling: rename the loops to p, q, and feed the
    # dense narrow phase (whose loops are output indices read through element
    # calls) into the tendency in place of the gated one.
    doc = JSON3.read(read(_NRC_PATH, String), Dict{String, Any})
    m = doc["models"]["NestedOverlapRegrid"]
    delete!(m, "tests")
    ops = m["operators"]
    for k in ("pairs_dense", "pairs_gated")
        body = ops[k]["body"]
        body["output_idx"] = ["p", "q"]
        r = body["ranges"]
        body["ranges"] = Dict("p" => r["i"], "q" => r["j"])
    end
    cell = ops["area_planar_ij"]["body"]["bindings"]
    cell["cell_a"] = "p"
    cell["cell_b"] = "q"
    for eq in m["equations"]
        b = get(eq["rhs"], "bindings", nothing)
        b !== nothing && get(b, "A_ij", nothing) == "A_ij" && (b["A_ij"] = "A_dense")
    end
    path = joinpath(mktempdir(), "nested_overlap_regrid_renamed.esm")
    open(io -> JSON3.write(io, doc), path, "w")
    for compiler in (:interpreter, :native)
        du = _nrc_rhs(compiler, path)
        got = [du[only(k for k in keys(du) if endswith(k, "E[$j]"))] for j in 1:4]
        @test isapprox(got, expected; rtol = 1.0e-14)
    end
end
