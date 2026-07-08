# OptimizationStrategy Types (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/solver_optimization_test.jl`

```julia
# Test GridSearchStrategy
        param_ranges = Dict{String,Vector{Any}}(
            "abstol" => [1e-6, 1e-8, 1e-10],
            "reltol" => [1e-3, 1e-4, 1e-6]
        )
        grid_strategy = GridSearchStrategy(param_ranges)
        @test grid_strategy.parameter_ranges == param_ranges
        @test grid_strategy.max_evaluations == 50

        grid_strategy_custom = GridSearchStrategy(param_ranges, max_evaluations=100)
        @test grid_strategy_custom.max_evaluations == 100

        # Test AdaptiveStrategy
        adaptive_strategy = AdaptiveStrategy()
        @test adaptive_strategy.learning_rate == 0.1
        @test adaptive_strategy.adaptation_threshold == 0.05
        @test adaptive_strategy.history_window == 10

        adaptive_custom = AdaptiveStrategy(learning_rate=0.2, adaptation_threshold=0.1, history_window=5)
        @test adaptive_custom.learning_rate == 0.2
        @test adaptive_custom.adaptation_threshold == 0.1
        @test adaptive_custom.history_window == 5
```

