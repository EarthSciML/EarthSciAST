# Numerical Method Enum (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/solver_test.jl`

```julia
# Test enum values exist
        @test FiniteDifferenceMethod isa NumericalMethod
        @test FiniteElementMethod isa NumericalMethod
        @test FiniteVolumeMethod isa NumericalMethod

        # Test string parsing
        @test parse_numerical_method("fdm") == FiniteDifferenceMethod
        @test parse_numerical_method("finite_difference") == FiniteDifferenceMethod
        @test parse_numerical_method("fem") == FiniteElementMethod
        @test parse_numerical_method("finite_element") == FiniteElementMethod
        @test parse_numerical_method("fvm") == FiniteVolumeMethod
        @test parse_numerical_method("finite_volume") == FiniteVolumeMethod

        # Test case insensitive parsing
        @test parse_numerical_method("FDM") == FiniteDifferenceMethod
        @test parse_numerical_method("Fem") == FiniteElementMethod

        # Test invalid method throws error
        @test_throws ArgumentError parse_numerical_method("invalid_method")

        # Test enum to string conversion
        @test numerical_method_to_string(FiniteDifferenceMethod) == "fdm"
        @test numerical_method_to_string(FiniteElementMethod) == "fem"
        @test numerical_method_to_string(FiniteVolumeMethod) == "fvm"
```

