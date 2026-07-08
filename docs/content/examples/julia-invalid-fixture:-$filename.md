# Invalid fixture: $filename (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/runtests.jl`

```julia
# Should either throw ParseError or produce validation errors
                        error_found = false
                        try
                            esm_data = EarthSciAST.load(filepath)
                            result = EarthSciAST.validate(esm_data)
                            if !result.is_valid
                                @test !isempty(result.schema_errors) || !isempty(result.structural_errors)
                                error_found = true
                                @info "✓ Invalid fixture $filename correctly produced validation errors"
```

