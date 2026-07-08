# Legacy Format Parsing (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/solver_test.jl`

```julia
# Test legacy format with algorithm field
        legacy_data = Dict(
            :algorithm => "Tsit5",
            :tolerances => Dict("rtol" => 1e-6, "abstol" => 1e-8),
            :parameters => Dict("maxiters" => 1000)
        )

        # Should parse with warning
        solver = coerce_solver(legacy_data)
        @test solver.strategy == IMEX  # Default strategy for legacy format
        @test solver.config.stiff_algorithm == "Tsit5"
        @test solver.config.stiff_kwargs["reltol"] == 1e-6
        @test solver.config.stiff_kwargs["abstol"] == 1e-8
        @test solver.config.extra_parameters["maxiters"] == 1000
```

