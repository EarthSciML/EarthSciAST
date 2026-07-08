# System Configuration Types (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/runtests.jl`

```julia
# Test Reference
        ref = Reference(doi="10.1000/test", citation="Test paper")
        @test ref.doi == "10.1000/test"
        @test ref.citation == "Test paper"
        @test ref.url === nothing
        @test ref.notes === nothing

        # Test Metadata
        metadata = Metadata("test_model",
                          description="A test model",
                          authors=["Test Author"],
                          license="MIT")
        @test metadata.name == "test_model"
        @test metadata.description == "A test model"
        @test metadata.authors == ["Test Author"]
        @test metadata.license == "MIT"

        # Test Domain
        domain = Domain(spatial=Dict("x" => [0.0, 1.0]), temporal=Dict("t" => [0.0, 100.0]))
        @test domain.spatial isa Dict
        @test domain.temporal isa Dict

        # Test Solver (new format)
        solver = Solver("imex", stiff_algorithm="Tsit5")
        solver.config.stiff_kwargs["rtol"] = 1e-8
        @test solver.strategy == IMEX
        @test solver.config.stiff_algorithm == "Tsit5"
        @test solver.config.stiff_kwargs["rtol"] == 1e-8

        # Test EsmFile
        esm_file = EsmFile("0.1.0", metadata)
        @test esm_file.esm == "0.1.0"
        @test esm_file.metadata == metadata
        @test esm_file.models === nothing
        @test esm_file.coupling == []
```

