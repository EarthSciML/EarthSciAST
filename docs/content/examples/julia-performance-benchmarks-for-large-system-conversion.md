# Performance benchmarks for large system conversion (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/mtk_catalyst_test.jl`

```julia
# Create a larger system for performance testing
        n_species = 50
        n_reactions = 100

        # Generate species
        large_species = [Species("S$i", description="Species $i") for i in 1:n_species]

        # Generate parameters
        large_params = [Parameter("k$i", rand(), description="Rate constant $i", units="1/s") for i in 1:n_reactions]

        # Generate random reactions with proper stoichiometry
        large_reactions = Reaction[]
        for i in 1:n_reactions
            # Random reactants and products
            n_reactants = rand(1:3)
            n_products = rand(1:3)

            reactants = Dict{String,Int}()
            products = Dict{String,Int}()

            for _ in 1:n_reactants
                species_idx = rand(1:n_species)
                reactants["S$species_idx"] = 1
```

