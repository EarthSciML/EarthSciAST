# Configuration Dictionary Conversion (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/solver_optimization_test.jl`

```julia
# Test solver_config_to_dict
        config = SolverConfiguration(
            threads=4,
            timestep=0.01,
            stiff_algorithm="QNDF",
            nonstiff_algorithm="Tsit5",
            numerical_method=FiniteDifferenceMethod,
            stiff_kwargs=Dict("abstol" => 1e-8, "reltol" => 1e-6),
            extra_parameters=Dict("custom_param" => 42)
        )

        dict_config = EarthSciAST.solver_config_to_dict(config)
        @test dict_config["threads"] == 4
        @test dict_config["timestep"] == 0.01
        @test dict_config["stiff_algorithm"] == "QNDF"
        @test dict_config["nonstiff_algorithm"] == "Tsit5"
        @test dict_config["numerical_method"] == FiniteDifferenceMethod
        @test dict_config["abstol"] == 1e-8
        @test dict_config["reltol"] == 1e-6
        @test dict_config["custom_param"] == 42

        # Test dict_to_solver_config (round trip)
        converted_config = EarthSciAST.dict_to_solver_config(dict_config)
        @test converted_config.threads == config.threads
        @test converted_config.timestep == config.timestep
        @test converted_config.stiff_algorithm == config.stiff_algorithm
        @test converted_config.nonstiff_algorithm == config.nonstiff_algorithm
        @test converted_config.numerical_method == config.numerical_method
        @test converted_config.stiff_kwargs["abstol"] == config.stiff_kwargs["abstol"]
        @test converted_config.stiff_kwargs["reltol"] == config.stiff_kwargs["reltol"]
        @test converted_config.extra_parameters["custom_param"] == config.extra_parameters["custom_param"]
```

