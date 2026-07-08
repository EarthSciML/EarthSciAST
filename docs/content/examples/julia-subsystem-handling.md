# Subsystem Handling (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/reactions_test.jl`

```julia
# Create a main system with subsystem
        main_species = [Species("X"), Species("Y")]
        main_reaction = Reaction(Dict("X"=>1), Dict("Y"=>1), VarExpr("k_main"))
        main_params = [Parameter("k_main", 0.1)]

        # Create subsystem
        sub_species = [Species("A"), Species("B")]
        sub_reaction = Reaction(Dict("A"=>1), Dict("B"=>1), VarExpr("k_sub"))
        sub_params = [Parameter("k_sub", 0.05)]
        sub_system = ReactionSystem(sub_species, [sub_reaction], parameters=sub_params)

        # Main system with subsystem
        main_system = ReactionSystem(
            main_species,
            [main_reaction],
            parameters=main_params,
            subsystems=Dict("subsys" => sub_system)
        )

        model = derive_odes(main_system)

        # Check main system
        @test length(model.variables) == 3  # 2 species + 1 parameter
        @test haskey(model.variables, "X")
        @test haskey(model.variables, "Y")
        @test haskey(model.variables, "k_main")

        # Check subsystem was processed
        @test length(model.subsystems) == 1
        @test haskey(model.subsystems, "subsys")

        sub_model = model.subsystems["subsys"]
        @test length(sub_model.variables) == 3  # 2 species + 1 parameter
        @test haskey(sub_model.variables, "A")
        @test haskey(sub_model.variables, "B")
        @test haskey(sub_model.variables, "k_sub")
        @test length(sub_model.equations) == 2  # One for each species
```

