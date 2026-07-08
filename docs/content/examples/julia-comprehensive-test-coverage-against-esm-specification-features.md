# Comprehensive test coverage against ESM specification features (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/mtk_catalyst_test.jl`

```julia
# Test complete ESM format coverage including all variable types
        comprehensive_vars = Dict{String,ModelVariable}(
            # State variables
            "temperature" => ModelVariable(StateVariable; default=298.15, description="Temperature", units="K"),
            "pressure" => ModelVariable(StateVariable; default=101325.0, description="Pressure", units="Pa"),

            # Parameter variables
            "R" => ModelVariable(ParameterVariable; default=8.314, description="Gas constant", units="J/mol/K"),
            "k_rate" => ModelVariable(ParameterVariable; default=1e-3, description="Rate constant", units="1/s"),

            # Observed variables with complex expressions
            "ideal_gas_law" => ModelVariable(ObservedVariable;
                expression=OpExpr("*", EarthSciAST.Expr[
                    VarExpr("R"), VarExpr("temperature")
                ]),
                description="RT term in ideal gas law"),
            "exponential_decay" => ModelVariable(ObservedVariable;
                expression=OpExpr("exp", EarthSciAST.Expr[
                    OpExpr("*", EarthSciAST.Expr[
                        OpExpr("-", EarthSciAST.Expr[VarExpr("k_rate")]),
                        VarExpr("t")
                    ])
                ]),
                description="Exponential decay factor")
        )

        # Complex equations with various operators
        comprehensive_eqs = [
            # Simple differential equation
            Equation(
                OpExpr("D", EarthSciAST.Expr[VarExpr("temperature")], wrt="t"),
                OpExpr("*", EarthSciAST.Expr[VarExpr("k_rate"), VarExpr("temperature")])
            ),
            # More complex differential equation
            Equation(
                OpExpr("D", EarthSciAST.Expr[VarExpr("pressure")], wrt="t"),
                OpExpr("+", EarthSciAST.Expr[
                    OpExpr("*", EarthSciAST.Expr[VarExpr("R"), VarExpr("temperature")]),
                    OpExpr("^", EarthSciAST.Expr[VarExpr("pressure"), NumExpr(0.5)])
                ])
            )
        ]

        # Events with different trigger types
        periodic_event = DiscreteEvent(
            PeriodicTrigger(10.0, phase=1.0),
            [FunctionalAffect("temperature", NumExpr(298.15), operation="set")],
            description="Reset temperature every 10 time units"
        )

        pressure_condition = OpExpr("-", EarthSciAST.Expr[VarExpr("pressure"), NumExpr(200000.0)])
        condition_event = ContinuousEvent(
            EarthSciAST.Expr[pressure_condition],
            [AffectEquation("pressure", NumExpr(101325.0))],
            description="Reset pressure if it exceeds 2 atm"
        )

        comprehensive_events = EventType[periodic_event, condition_event]

        comprehensive_model = Model(comprehensive_vars, comprehensive_eqs; events=comprehensive_events)

        # Test conversion preserves all features
        mtk_sys = to_mtk_system(comprehensive_model, "ComprehensiveModel")

        @test mtk_sys isa EarthSciAST.MockMTKSystem
        @test length(mtk_sys.states) == 2        # temperature, pressure
        @test length(mtk_sys.parameters) == 2    # R, k_rate
        @test length(mtk_sys.observed_variables) == 2  # ideal_gas_law, exponential_decay
        @test length(mtk_sys.equations) == 2     # Two differential equations
        @test length(mtk_sys.events) == 2        # Two events

        # Test bidirectional conversion preserves structure
        recovered_model = from_mtk_system(mtk_sys, "ComprehensiveModel")
        @test recovered_model isa Model

        # Verify all variable types are preserved
        state_count = count(var -> var.type == StateVariable, values(recovered_model.variables))
        param_count = count(var -> var.type == ParameterVariable, values(recovered_model.variables))
        obs_count = count(var -> var.type == ObservedVariable, values(recovered_model.variables))

        @test state_count == 2
        @test param_count == 2
        @test obs_count == 2
```

