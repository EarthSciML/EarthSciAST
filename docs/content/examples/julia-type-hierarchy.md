# Type Hierarchy (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/runtests.jl`

```julia
# Test that all expression types are subtypes of Expr
        @test NumExpr <: EarthSciAST.Expr
        @test VarExpr <: EarthSciAST.Expr
        @test OpExpr <: EarthSciAST.Expr

        # Test that trigger types are subtypes of DiscreteEventTrigger
        @test ConditionTrigger <: DiscreteEventTrigger
        @test PeriodicTrigger <: DiscreteEventTrigger
        @test PresetTimesTrigger <: DiscreteEventTrigger

        # Test that event types are subtypes of EventType
        @test ContinuousEvent <: EarthSciAST.EventType
        @test DiscreteEvent <: EarthSciAST.EventType
```

