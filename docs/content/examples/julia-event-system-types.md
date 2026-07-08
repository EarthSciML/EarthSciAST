# Event System Types (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/runtests.jl`

```julia
# Test DiscreteEventTrigger types
        cond_trigger = ConditionTrigger(VarExpr("x"))
        @test cond_trigger isa DiscreteEventTrigger
        @test cond_trigger.expression isa VarExpr

        periodic_trigger = PeriodicTrigger(10.0, phase=2.0)
        @test periodic_trigger isa DiscreteEventTrigger
        @test periodic_trigger.period == 10.0
        @test periodic_trigger.phase == 2.0

        preset_trigger = PresetTimesTrigger([1.0, 5.0, 10.0])
        @test preset_trigger isa DiscreteEventTrigger
        @test preset_trigger.times == [1.0, 5.0, 10.0]

        # Test FunctionalAffect
        affect = FunctionalAffect("x", NumExpr(1.0), operation="add")
        @test affect.target == "x"
        @test affect.expression isa NumExpr
        @test affect.operation == "add"
```

