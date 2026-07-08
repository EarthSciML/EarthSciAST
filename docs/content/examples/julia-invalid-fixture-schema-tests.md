# Invalid Fixture Schema Tests (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/runtests.jl`

```julia
# Test that invalid fixtures produce expected schema errors
            invalid_fixtures_dir = joinpath(@__DIR__, "..", "..", "..", "tests", "invalid")

            if isdir(invalid_fixtures_dir)
                invalid_files = filter(f ->
```

