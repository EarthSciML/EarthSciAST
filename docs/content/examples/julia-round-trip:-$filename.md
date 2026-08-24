# Round-trip: $filename (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/runtests.jl`

```julia
try
                            # Load original
                            original = EarthSciAST.load_path(filepath)

                            # Create temp file for round-trip test
                            temp_file = tempname() * ".esm"

                            try
                                # Save and reload
                                EarthSciAST.write_path(original, temp_file)
                                reloaded = EarthSciAST.load_path(temp_file)

                                # Compare key fields
                                @test original.esm == reloaded.esm
                                @test original.metadata.name == reloaded.metadata.name

                                # For files with models, compare model count
                                if !isnothing(original.models) && !isnothing(reloaded.models)
                                    @test length(original.models) == length(reloaded.models)
```

