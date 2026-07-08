# Substitution Tests (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/runtests.jl`

```julia
# Test substitution functionality with fixture data
            substitution_fixtures_dir = joinpath(@__DIR__, "..", "..", "..", "tests", "substitution")

            if isdir(substitution_fixtures_dir)
                substitution_files = filter(f ->
```

