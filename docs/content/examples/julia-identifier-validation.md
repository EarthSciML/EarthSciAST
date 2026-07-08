# Identifier Validation (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/reference_resolution_test.jl`

```julia
# Valid identifiers
        @test is_valid_identifier("variable") == true
        @test is_valid_identifier("Variable") == true
        @test is_valid_identifier("var_2") == true
        @test is_valid_identifier("_private") == true
        @test is_valid_identifier("System123") == true

        # Invalid identifiers
        @test is_valid_identifier("") == false
        @test is_valid_identifier("1variable") == false
        @test is_valid_identifier("var-name") == false
        @test is_valid_identifier("var.name") == false
        @test is_valid_identifier("var name") == false
```

