# Round-trip Tests (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/runtests.jl`

```julia
# Test that load_string(to_json(load_path(file))) == load_path(file) for all valid fixtures
            valid_fixtures_dir = joinpath(@__DIR__, "..", "..", "..", "tests", "valid")

            if isdir(valid_fixtures_dir)
                valid_files = filter(f ->
```

