# ProblemCharacteristics (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/solver_optimization_test.jl`

```julia
# Test default construction
        characteristics = ProblemCharacteristics()
        @test characteristics.stiffness_ratio == 1.0
        @test characteristics.nonlinearity_measure == 0.5
        @test characteristics.problem_size == 100
        @test characteristics.spatial_dimensions == 1
        @test characteristics.temporal_scale == 1.0
        @test characteristics.sparsity_pattern == "sparse"

        # Test construction with custom values
        custom_chars = ProblemCharacteristics(
            stiffness_ratio=1000.0,
            nonlinearity_measure=0.8,
            problem_size=5000,
            spatial_dimensions=3,
            temporal_scale=1e-6,
            sparsity_pattern="dense"
        )
        @test custom_chars.stiffness_ratio == 1000.0
        @test custom_chars.nonlinearity_measure == 0.8
        @test custom_chars.problem_size == 5000
        @test custom_chars.spatial_dimensions == 3
        @test custom_chars.temporal_scale == 1e-6
        @test custom_chars.sparsity_pattern == "dense"
```

