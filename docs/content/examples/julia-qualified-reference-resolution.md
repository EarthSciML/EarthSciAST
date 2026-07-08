# Qualified Reference Resolution (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/reference_resolution_test.jl`

```julia
@testset "Reference Syntax Validation" begin
        # Valid references
        @test validate_reference_syntax("System.variable") == true
        @test validate_reference_syntax("System.Subsystem.variable") == true
        @test validate_reference_syntax("A.B.C.D.variable") == true
        @test validate_reference_syntax("variable") == true
        @test validate_reference_syntax("system_1.var_2") == true
        @test validate_reference_syntax("_private.hidden") == true

        # Invalid references
        @test validate_reference_syntax("") == false
        @test validate_reference_syntax(".variable") == false
        @test validate_reference_syntax("System.") == false
        @test validate_reference_syntax("System..variable") == false
        @test validate_reference_syntax("System.Sub..var") == false
        @test validate_reference_syntax("1System.variable") == false
        @test validate_reference_syntax("System.2variable") == false
        @test validate_reference_syntax("System.var-name") == false
```

