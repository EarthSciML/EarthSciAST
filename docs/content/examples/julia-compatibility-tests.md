# Compatibility Tests (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/compat_test.jl`

```julia
@testset "Julia Version Compatibility" begin
        # Test that we're compatible with the declared minimum Julia version
        julia_version = VERSION
        @test julia_version >= v"1.10"
        println("Julia version: $julia_version ✓")
```

