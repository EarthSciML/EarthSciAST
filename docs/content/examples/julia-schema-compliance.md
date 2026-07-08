# Schema Compliance (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/solver_test.jl`

```julia
# Test that serialized format matches expected schema structure
        solver = Solver("imex", stiff_algorithm="KenCarp4", timestep=0.001)
        serialized = serialize_solver(solver)

        # Should have required strategy field
        @test haskey(serialized, "strategy")
        @test serialized["strategy"] in ["strang_threads", "strang_serial", "imex"]

        # Should have config field with proper structure
        @test haskey(serialized, "config")
        config = serialized["config"]

        # Test that config follows expected schema
        if haskey(config, "threads")
            @test config["threads"] isa Integer
            @test config["threads"] >= 1
```

