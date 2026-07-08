# Performance Comparison (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/solver_optimization_test.jl`

```julia
# Test is_better_performance function
        good_metrics = PerformanceMetrics(1.0, 20, 1e-8, 512*1024, 0.9, true)
        bad_metrics = PerformanceMetrics(3.0, 100, 1e-4, 2*1024*1024, 0.5, true)
        failed_metrics = PerformanceMetrics(1.0, 20, 1e-8, 512*1024, 0.9, false)

        @test EarthSciAST.is_better_performance(good_metrics, bad_metrics) == true
        @test EarthSciAST.is_better_performance(bad_metrics, good_metrics) == false
        @test EarthSciAST.is_better_performance(failed_metrics, good_metrics) == false
        @test EarthSciAST.is_better_performance(good_metrics, failed_metrics) == true

        # Test performance scores
        good_score = EarthSciAST.calculate_performance_score(good_metrics)
        bad_score = EarthSciAST.calculate_performance_score(bad_metrics)
        @test good_score > bad_score
```

