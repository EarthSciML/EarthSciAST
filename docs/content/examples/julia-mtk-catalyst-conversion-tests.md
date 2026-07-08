# MTK/Catalyst Conversion Tests (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/mtk_catalyst_test.jl`

```julia
@testset "ESM Model → MockMTK conversion with proper variable mapping" begin
        # Create a simple harmonic oscillator model
        variables = Dict{String,ModelVariable}(
            "x" => ModelVariable(StateVariable; default=1.0, description="Position"),
            "v" => ModelVariable(StateVariable; default=0.0, description="Velocity"),
            "omega" => ModelVariable(ParameterVariable; default=1.0, description="Angular frequency"),
            "energy" => ModelVariable(ObservedVariable;
                expression=OpExpr("+", EarthSciAST.Expr[
                    OpExpr("/", EarthSciAST.Expr[OpExpr("^", EarthSciAST.Expr[VarExpr("v"), NumExpr(2.0)]), NumExpr(2.0)]),
                    OpExpr("/", EarthSciAST.Expr[
                        OpExpr("*", EarthSciAST.Expr[
                            OpExpr("^", EarthSciAST.Expr[VarExpr("omega"), NumExpr(2.0)]),
                            OpExpr("^", EarthSciAST.Expr[VarExpr("x"), NumExpr(2.0)])
                        ]),
                        NumExpr(2.0)
                    ])
                ]))
        )

        equations = [
            Equation(
                OpExpr("D", EarthSciAST.Expr[VarExpr("x")], wrt="t"),
                VarExpr("v")
            ),
            Equation(
                OpExpr("D", EarthSciAST.Expr[VarExpr("v")], wrt="t"),
                OpExpr("*", EarthSciAST.Expr[
                    OpExpr("-", EarthSciAST.Expr[OpExpr("^", EarthSciAST.Expr[VarExpr("omega"), NumExpr(2.0)])]),
                    VarExpr("x")
                ])
            )
        ]

        model = Model(variables, equations)
        mtk_sys = to_mtk_system(model, "HarmonicOscillator")

        @test mtk_sys isa EarthSciAST.MockMTKSystem
        @test mtk_sys.name == "HarmonicOscillator"

        # Check that we have the expected number of states and parameters
        @test length(mtk_sys.states) == 2  # x, v
        @test length(mtk_sys.parameters) == 1  # omega
        @test length(mtk_sys.observed_variables) == 1  # energy
        @test length(mtk_sys.equations) == 2  # dx/dt, dv/dt

        # Verify proper variable classification
        @test "x" in mtk_sys.states
        @test "v" in mtk_sys.states
        @test "omega" in mtk_sys.parameters
        @test "energy" in mtk_sys.observed_variables
```

