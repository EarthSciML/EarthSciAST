# Valid fixture: $filename (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/runtests.jl`

```julia
try
                            esm_data = EarthSciAST.load(filepath)
                            @test esm_data isa EarthSciAST.EsmFile
                            @test !isnothing(esm_data.esm)
                            @test !isnothing(esm_data.metadata)
                            @info "✓ Successfully loaded $filename"
                        catch e
                            @warn "Failed to load valid fixture $filename: $e"
                            @test false
```

