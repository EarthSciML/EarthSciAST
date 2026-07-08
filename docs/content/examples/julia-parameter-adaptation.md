# Parameter Adaptation (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/solver_optimization_test.jl`

```julia
# Test configuration parameter adaptation
        config = SolverConfiguration(
            timestep=0.01,
            stiff_kwargs=Dict("abstol" => 1e-6, "reltol" => 1e-4)
        )

        # High error metrics should tighten tolerances
        high_error_metrics = PerformanceMetrics(1.0, 20, 1e-3, 1024*1024, 0.6, true)
        adapted_config = EarthSciAST.adapt_configuration_parameters(config, high_error_metrics, 0.1)
        @test adapted_config.stiff_kwargs["abstol"] < config.stiff_kwargs["abstol"]
        @test adapted_config.stiff_kwargs["reltol"] < config.stiff_kwargs["reltol"]

        # Low error, high stability metrics should relax tolerances
        excellent_metrics = PerformanceMetrics(0.5, 5, 1e-10, 256*1024, 0.95, true)
        relaxed_config = EarthSciAST.adapt_configuration_parameters(config, excellent_metrics, 0.1)
        @test relaxed_config.stiff_kwargs["abstol"] > config.stiff_kwargs["abstol"]
        @test relaxed_config.stiff_kwargs["reltol"] > config.stiff_kwargs["reltol"]

        # High iterations should reduce timestep
        slow_convergence_metrics = PerformanceMetrics(2.0, 150, 1e-6, 1024*1024, 0.8, true)
        smaller_step_config = EarthSciAST.adapt_configuration_parameters(config, slow_convergence_metrics, 0.1)
        @test smaller_step_config.timestep < config.timestep

        # Fast convergence should increase timestep
        fast_convergence_metrics = PerformanceMetrics(0.8, 5, 1e-6, 1024*1024, 0.8, true)
        larger_step_config = EarthSciAST.adapt_configuration_parameters(config, fast_convergence_metrics, 0.1)
        @test larger_step_config.timestep > config.timestep
```

