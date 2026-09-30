# Conformance harness adapter — missing_data category.
#
# A SHAPED parameter with no data supplied at the front door (esm-spec §10.10:
# a parameter with neither a default nor a supplied value is an error when a
# problem is built). Without data every compiler refuses the construction with
# `E_TREEWALK_MISSING_DATA`, naming a parameter that has no value; with the
# case's `const_arrays` every compiler builds, and the right-hand side at the
# manifest's probe state is bit-for-bit the same under `native` and
# `interpreter`.
#
# See tests/conformance/missing_data/.

using Test
using JSON3
using EarthSciAST

include("testutils.jl")  # TESTUTILS_REPO_ROOT

const _MD_CAT_DIR  = joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance", "missing_data")
const _MD_MANIFEST = joinpath(_MD_CAT_DIR, "manifest.json")

# A row-major nested JSON array as a Julia array indexed the same way
# (`data[i][j]` is `A[i, j]`).
function _md_dense(v)
    v isa Number && return Float64(v)
    all(e -> e isa Number, v) && return Float64.(collect(v))
    rows = [_md_dense(e) for e in v]
    return permutedims(cat((reshape(r, 1, size(r)...) for r in rows)...; dims = 1),
                       (1, (2:ndims(rows[1]) + 1)...))
end

function _md_rhs(prob)
    n = length(prob.u0)
    u = [1 + 0.1 * sin(0.37 * k) for k in 0:n-1]
    du = zeros(n)
    prob.f!(du, u, prob.p, 0.0)
    return du
end

@testset "Conformance: missing_data (manifest-driven)" begin
    manifest = JSON3.read(read(_MD_MANIFEST, String))
    @test manifest.category == "missing_data"
    @test "julia" in String.(manifest.bindings_required)
    code = String(manifest.error_code)
    for case in manifest.cases
        fixture = joinpath(_MD_CAT_DIR, String(case.fixture))
        for compiler in manifest.compilers
            @testset "$(case.id) [$(compiler)] without data" begin
                if case.missing === nothing
                    prob = esm_problem(fixture, (0.0, 1.0); compiler = Symbol(compiler))
                    if haskey(case, :expected_rhs_without_data)
                        @test _md_rhs(prob) == Float64.(collect(case.expected_rhs_without_data))
                    end
                else
                    err = try
                        esm_problem(fixture, (0.0, 1.0); compiler = Symbol(compiler))
                        nothing
                    catch e
                        e
                    end
                    want = haskey(case, :error_code) ? String(case.error_code) : code
                    @test err isa EarthSciAST.TreeWalkError
                    @test err isa EarthSciAST.TreeWalkError && err.code == want
                    msg = err === nothing ? "" : sprint(showerror, err)
                    @test any(m -> occursin("'$(String(m))'", msg) ||
                                   occursin("'$(last(split(String(m), '.')))'", msg),
                              case.missing)
                end
            end
        end
        supply = get(case, :supply, nothing)
        case.const_arrays === nothing && supply === nothing && continue
        arrays = case.const_arrays === nothing ? Dict{String,Any}() :
                 Dict{String,Any}(String(k) => _md_dense(v) for (k, v) in pairs(case.const_arrays))
        p = Dict{String,Float64}(String(k) => Float64(v)
                                 for (k, v) in pairs(something(get(something(supply, Dict()), :p, nothing), Dict())))
        u0 = Dict{String,Float64}(String(k) => Float64(v)
                                  for (k, v) in pairs(something(get(something(supply, Dict()), :u0, nothing), Dict())))
        answers = Dict{String,Vector{Float64}}()
        for compiler in manifest.compilers
            @testset "$(case.id) [$(compiler)] with data" begin
                prob = esm_problem(fixture, (0.0, 1.0); compiler = Symbol(compiler),
                                   const_arrays = arrays, p = p, u0 = u0)
                if case.rhs
                    du = _md_rhs(prob)
                    @test all(isfinite, du)
                    if haskey(case, :expected_rhs)
                        @test du == Float64.(collect(case.expected_rhs))
                    end
                    answers[String(compiler)] = du
                end
            end
        end
        if length(answers) == 2
            a, b = answers["native"], answers["interpreter"]
            @test reinterpret(UInt64, a) == reinterpret(UInt64, b)
        end
    end
end
