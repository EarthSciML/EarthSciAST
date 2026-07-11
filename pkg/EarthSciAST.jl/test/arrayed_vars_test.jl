using Test
using EarthSciAST

@testset "Arrayed variables (RFC §10.2)" begin
    fixture_dir = joinpath(@__DIR__, "..", "..", "..", "tests", "fixtures", "arrayed_vars")

    function roundtrip(name::String)
        path = joinpath(fixture_dir, name)
        first = EarthSciAST.load(path)
        tmp = tempname() * ".esm"
        EarthSciAST.save(first, tmp)
        second = EarthSciAST.load(tmp)
        rm(tmp; force=true)
        return first, second
    end

    function varof(esm, model_name::String, var_name::String)
        return esm.models[model_name].variables[var_name]
    end

    @testset "scalar_no_shape — regression (no shape/location fields)" begin
        first, second = roundtrip("scalar_no_shape.esm")
        for esm in (first, second)
            v = varof(esm, "Scalar0D", "x")
            @test v.shape === nothing
            @test v.location === nothing
            k = varof(esm, "Scalar0D", "k")
            @test k.shape === nothing
            @test k.location === nothing
        end
    end

    @testset "scalar_explicit — empty-list shape parses as zero dims" begin
        first, second = roundtrip("scalar_explicit.esm")
        for esm in (first, second)
            mass = varof(esm, "ScalarExplicit", "mass")
            # Empty list and nothing are both valid scalar forms.
            dims = mass.shape === nothing ? 0 : length(mass.shape)
            @test dims == 0
            @test mass.location === nothing
        end
    end

    @testset "one_d — 1-D cell-centered" begin
        first, second = roundtrip("one_d.esm")
        for esm in (first, second)
            c = varof(esm, "Diffusion1D", "c")
            @test c.shape == ["x"]
            @test c.location == "cell_center"
            d = varof(esm, "Diffusion1D", "D")
            @test d.shape === nothing
            @test d.location === nothing
        end
    end

    @testset "two_d_faces — staggered locations" begin
        first, second = roundtrip("two_d_faces.esm")
        for esm in (first, second)
            p = varof(esm, "StaggeredFlow2D", "p")
            @test p.shape == ["x", "y"]
            @test p.location == "cell_center"
            u = varof(esm, "StaggeredFlow2D", "u")
            @test u.shape == ["x", "y"]
            @test u.location == "x_face"
        end
    end

    @testset "vertex_located — 2-D vertex" begin
        first, second = roundtrip("vertex_located.esm")
        for esm in (first, second)
            phi = varof(esm, "VertexScalar2D", "phi")
            @test phi.shape == ["x", "y"]
            @test phi.location == "vertex"
        end
    end
end
