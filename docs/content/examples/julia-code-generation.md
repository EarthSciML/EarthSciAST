# Code Generation (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/test_codegen.jl`

```julia
@testset "to_julia_code" begin
        @testset "should generate basic Julia script structure" begin
            file = EsmFile(
                esm = "0.1.0",
                metadata = Dict{Symbol,Any}(
                    :title => "Test Model",
                    :description => "A test model for code generation"
                ),
                models = Dict{String,Model}(),
                reaction_systems = Dict{String,ReactionSystem}()
            )

            code = to_julia_code(file)

            @test occursin("using ModelingToolkit", code)
            @test occursin("using Catalyst", code)
            @test occursin("using EarthSciMLBase", code)
            @test occursin("using OrdinaryDiffEq", code)
            @test occursin("using Unitful", code)
            @test occursin("# Title: Test Model", code)
            @test occursin("# Description: A test model for code generation", code)
```

