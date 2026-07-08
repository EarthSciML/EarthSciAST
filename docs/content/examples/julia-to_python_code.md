# to_python_code (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/test_codegen.jl`

```julia
@testset "should generate basic Python script structure" begin
            file = EsmFile(
                esm = "0.1.0",
                metadata = Dict{Symbol,Any}(
                    :title => "Test Model",
                    :description => "A test model for Python code generation"
                ),
                models = Dict{String,Model}(),
                reaction_systems = Dict{String,ReactionSystem}()
            )

            code = to_python_code(file)

            @test occursin("import sympy as sp", code)
            @test occursin("import earthsci_ast as esm", code)
            @test occursin("import scipy", code)
            @test occursin("# Title: Test Model", code)
            @test occursin("# Description: A test model for Python code generation", code)
            @test occursin("tspan = (0, 10)", code)
            @test occursin("parameters = {}", code)
            @test occursin("initial_conditions = {}", code)
```

