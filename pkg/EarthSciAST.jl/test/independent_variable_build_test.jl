# A document whose independent variable is not `t` (esm-spec §11.3): the build
# reads time under the document's name, and a variable that happens to be
# called `t` is an ordinary variable.

using Test
using EarthSciAST
using JSON3

const _IVB = EarthSciAST
const _IVB_FIXTURE = joinpath(
    @__DIR__, "..", "..", "..", "tests", "valid", "independent_variable_renamed.esm"
)

# The fixture with its equation replaced by `D(y, s) = t·s + y`: `s` is time,
# `t` the parameter (air temperature, default 288).
function _ivb_ode_doc(dir)
    d = JSON3.read(read(_IVB_FIXTURE, String), Dict{String, Any})
    col = d["models"]["Column"]
    col["system_kind"] = "ode"
    col["variables"]["y"]["default"] = 0.5
    # Dimensionless throughout: the test is about names, not units.
    col["variables"]["y"]["units"] = "1"
    col["variables"]["t"]["units"] = "1"
    col["equations"] = Any[
        Dict(
            # The time derivative is spelled with `wrt` absent (literally "t",
            # esm-spec §4.2): a `wrt` naming the renamed independent variable is
            # a spatial axis, read as `partial` (esm 2.4.0).
            "lhs" => Dict("op" => "D", "args" => Any["y"]),
            "rhs" => Dict(
                "op" => "+", "args" => Any[
                    Dict(
                        "op" => "*", "args" => Any["t", "s"]
                    ),
                    "y",
                ]
            ),
        ),
    ]
    col["variables"]["y"]["description"] = "Accumulated value"
    path = joinpath(dir, "ivb_ode.esm")
    write(path, JSON3.write(d))
    return path
end

@testset "a renamed independent variable is the build's time" begin
    @testset "the fixture builds" begin
        f!, u0, p = _IVB.Internal.build(_IVB_FIXTURE)
        du = similar(u0)
        f!(du, u0, p, 0.0)
        @test all(isfinite, du)
    end

    @testset "time is read under the document's name" begin
        mktempdir() do dir
            path = _ivb_ode_doc(dir)
            f!, u0, p, _, vm = _IVB.Internal.build(path)
            i = vm["Column.y"]
            du = zeros(length(u0))
            u = copy(u0)
            u[i] = 0.5
            f!(du, u, p, 2.0)
            # D(y) = t·s + y with t = 288 (the parameter), s = 2 (time), y = 0.5
            @test du[i] == 288.0 * 2.0 + 0.5
            f!(du, u, p, 3.0)
            @test du[i] == 288.0 * 3.0 + 0.5
        end
    end
end
