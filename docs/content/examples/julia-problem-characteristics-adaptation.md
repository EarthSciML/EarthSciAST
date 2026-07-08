# Problem Characteristics Adaptation (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/solver_optimization_test.jl`

```julia
base_config = Dict{String,Any}(
            "abstol" => 1e-6,
            "reltol" => 1e-4,
            "timestep" => 1e-2,
            "threads" => 2
        )

        # Test stiff problem adaptation
        stiff_characteristics = ProblemCharacteristics(
            stiffness_ratio=1000.0,
            temporal_scale=1e-6,
            problem_size=100
        )

        adapted_config = EarthSciAST.adapt_for_problem_characteristics(base_config, stiff_characteristics)
        @test adapted_config.stiff_kwargs["abstol"] == 1e-10  # Tighter tolerance
        @test adapted_config.stiff_kwargs["reltol"] == 1e-8   # Tighter tolerance
        @test adapted_config.stiff_algorithm == "QNDF"       # Stiff solver
        @test adapted_config.timestep < base_config["timestep"]  # Smaller timestep
        @test adapted_config.threads == 1  # Small problem, single thread

        # Test non-stiff problem adaptation
        nonstiff_characteristics = ProblemCharacteristics(
            stiffness_ratio=5.0,
            temporal_scale=1.0,
            problem_size=15000
        )

        adapted_config2 = EarthSciAST.adapt_for_problem_characteristics(base_config, nonstiff_characteristics)
        @test adapted_config2.stiff_kwargs["abstol"] == 1e-6
        @test adapted_config2.stiff_kwargs["reltol"] == 1e-4
        @test adapted_config2.nonstiff_algorithm == "Tsit5"  # Fast explicit method
        @test adapted_config2.threads > 1  # Large problem, use multiple threads
```

