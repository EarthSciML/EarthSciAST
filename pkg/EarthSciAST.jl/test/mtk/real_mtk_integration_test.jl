using Test
using EarthSciAST
using JSON3
# Qualify ModelingToolkit and Symbolics so they don't collide with
# EarthSciAST exports (e.g. `Equation`) in the shared Main scope
# used by runtests.jl.
import ModelingToolkit
import Symbolics

@testset "Real MTK Extension Integration Tests" begin

    @testset "Extension loads and registers System constructor" begin
        ext = Base.get_extension(EarthSciAST, :EarthSciASTMTKExt)
        @test ext !== nothing
        @test hasmethod(
            ModelingToolkit.System,
            Tuple{EarthSciAST.Model}
        )
        @test hasmethod(
            ModelingToolkit.System,
            Tuple{EarthSciAST.FlattenedSystem}
        )
        # There is no PDE constructor: a spatial system is refused by
        # `System`, and `PDESystem` has no method for ESM types.
        @test !hasmethod(
            ModelingToolkit.PDESystem,
            Tuple{EarthSciAST.FlattenedSystem}
        )
        @test !hasmethod(ModelingToolkit.PDESystem, Tuple{EarthSciAST.Model})
    end

    @testset "ModelingToolkit.System(::Model) builds a real System" begin
        vars = Dict(
            "x" => ModelVariable(UnknownVariable; default = 1.0),
            "k" => ModelVariable(ParameterVariable; default = 0.5),
        )
        eq = Equation(
            OpExpr("D", EarthSciAST.ASTExpr[VarExpr("x")], wrt = "t"),
            OpExpr(
                "*", EarthSciAST.ASTExpr[
                    OpExpr("-", EarthSciAST.ASTExpr[VarExpr("k")]),
                    VarExpr("x"),
                ]
            ),
        )
        model = Model(vars, [eq])
        sys = ModelingToolkit.System(model; name = :RealTest)

        type_str = string(typeof(sys))
        @test occursin("System", type_str) || occursin("ODE", type_str)

        # After flatten+extension, variables are namespaced as `RealTest.x`
        # and sanitized to `RealTest_x` for symbol construction.
        un_names = Set(
            string(ModelingToolkit.getname(u))
                for u in ModelingToolkit.unknowns(sys)
        )
        @test any(occursin("x", n) for n in un_names)

        pn_names = Set(
            string(ModelingToolkit.getname(p))
                for p in ModelingToolkit.parameters(sys)
        )
        @test any(occursin("k", n) for n in pn_names)
    end

    @testset "ModelingToolkit.System refuses a system with a spatial independent variable" begin
        # The spatial dimension `z` is harvested STRUCTURALLY from the `dim="z"`
        # scalar field carried on the operator nodes (esm-spec §4.9.1(ii)) — by
        # field, not by op name; the `grad` sugar has no privilege (§4.2).
        vars = Dict{String, ModelVariable}(
            "u" => ModelVariable(UnknownVariable; default = 1.0),
            "D" => ModelVariable(ParameterVariable; default = 0.1),
        )
        eq = Equation(
            OpExpr("D", EarthSciAST.ASTExpr[VarExpr("u")], wrt = "t"),
            OpExpr(
                "*", EarthSciAST.ASTExpr[
                    VarExpr("D"),
                    OpExpr(
                        "grad", EarthSciAST.ASTExpr[
                            OpExpr("grad", EarthSciAST.ASTExpr[VarExpr("u")], dim = "z"),
                        ], dim = "z"
                    ),
                ]
            ),
        )
        model = Model(vars, [eq])
        file = EsmFile(
            "0.1.0", Metadata("Diffuse");
            models = Dict("Diffuse" => model)
        )
        flat = flatten(file)
        @test :z in flat.independent_variables
        err = try
            ModelingToolkit.System(flat; name = :Diffuse)
            nothing
        catch e
            e
        end
        @test err isa SimulateError
        @test occursin("no PDE constructor", err.msg)
        @test !occursin("PDESystem", err.msg)
    end

    @testset "Round-trip: Model → System → Model" begin
        vars = Dict(
            "x" => ModelVariable(UnknownVariable; default = 2.0),
            "k" => ModelVariable(ParameterVariable; default = 0.3),
        )
        eq = Equation(
            OpExpr("D", EarthSciAST.ASTExpr[VarExpr("x")], wrt = "t"),
            OpExpr(
                "*", EarthSciAST.ASTExpr[
                    OpExpr("-", EarthSciAST.ASTExpr[VarExpr("k")]),
                    VarExpr("x"),
                ]
            ),
        )
        original = Model(vars, [eq])
        sys = ModelingToolkit.System(original; name = :RT)
        recovered = EarthSciAST.Model(sys)
        @test recovered isa Model
        # After round-trip, the variables carry the namespaced name from
        # flatten (e.g. `RT_x`, `RT_k` after sanitization for symbol use).
        state_vars = [
            v for (n, v) in recovered.variables
                if v.type == UnknownVariable
        ]
        param_vars = [
            v for (n, v) in recovered.variables
                if v.type == ParameterVariable
        ]
        @test length(state_vars) == 1
        @test length(param_vars) == 1
    end

    @testset "A state no equation mentions survives into the compiled system" begin
        # esm-libraries-spec §4.6.1: a species touched by no reaction gets NO
        # `D(X, t)` equation, which leaves it an unknown nothing names. It is
        # still in `state_variables` (§4.7.5's field table), so the BACKEND has
        # to carry it — MTK on its own drops an unknown that appears in no
        # equation, which would delete the species from `unknowns(simp)`, make
        # an `initial_conditions` entry naming it unbindable, and drop it from
        # every solution. `System(::FlattenedSystem)` closes it with
        # `D(X, t) ~ 0` at the lowering instead.
        rsys = EarthSciAST.ReactionSystem(
            [
                EarthSciAST.Species("A", default = 1.0),
                EarthSciAST.Species("B", default = 0.0),
                EarthSciAST.Species("Xe", default = 5.0),
            ],   # in no reaction
            [EarthSciAST.Reaction(Dict("A" => 1), Dict("B" => 1), VarExpr("k"))],
            parameters = [EarthSciAST.Parameter("k", 0.1)]
        )
        flat = EarthSciAST.flatten(rsys; name = "Chem")

        # The DOCUMENT-level artifact is unchanged by the closure: no equation
        # for Xe, and it classifies algebraic.
        @test !any(
            EarthSciAST.differential_lhs_variable(eq.lhs) == "Chem.Xe"
                for eq in flat.equations
        )
        @test haskey(flat.algebraic_variables, "Chem.Xe")

        sys = ModelingToolkit.System(flat; name = :Chem)
        simp = ModelingToolkit.mtkcompile(sys)
        names = String[
            string(ModelingToolkit.getname(u))
                for u in ModelingToolkit.unknowns(simp)
        ]
        @test any(endswith(n, "Xe") for n in names)
        # ...and the closure is a ZERO tendency, so it holds its initial value.
        d_xe = only(
            eq for eq in ModelingToolkit.equations(simp)
                if occursin("Xe", string(eq.lhs))
        )
        @test iszero(Symbolics.value(d_xe.rhs))
    end

    @testset "Extension-gated: removed exports are gone" begin
        # These names were removed as part of the extension refactor. They
        # must not exist as exported symbols of the main package.
        @test !isdefined(EarthSciAST, :to_mtk_system)
        @test !isdefined(EarthSciAST, :to_catalyst_system)
        @test !isdefined(EarthSciAST, :from_mtk_system)
        @test !isdefined(EarthSciAST, :from_catalyst_system)
        @test !isdefined(EarthSciAST, :check_mtk_availability)
        @test !isdefined(EarthSciAST, :check_catalyst_availability)
        # The vestigial Mock* fallbacks were deleted too (the MTK-free path
        # is flatten/FlattenedSystem + esm_problem).
        @test !isdefined(EarthSciAST, :MockMTKSystem)
        @test !isdefined(EarthSciAST, :MockPDESystem)
        @test !isdefined(EarthSciAST, :MockCatalystSystem)
    end

    @testset "System(::FlattenedSystem) expands surviving template references" begin
        # `flatten` ALWAYS carries `apply_expression_template` references
        # (esm-spec §9.6.4 Option B); the MTK constructor must Expand at its
        # boundary (RFC out-of-line-expression-templates §7.7) — `_esm_to_symbolic`
        # has no apply arm, so without the expansion this construction throws.
        doc = Dict{String, Any}(
            "esm" => "2.0.0",
            "metadata" => Dict{String, Any}("name" => "mtk_tpl"),
            "models" => Dict{String, Any}(
                "M" => Dict{String, Any}(
                    "expression_templates" => Dict{String, Any}(
                        "scale" => Dict{String, Any}(
                            "params" => Any["x"],
                            "body" => Dict{String, Any}("op" => "*", "args" => Any["k", "x"])
                        )
                    ),
                    "variables" => Dict{String, Any}(
                        "k" => Dict{String, Any}("type" => "parameter", "default" => 0.5),
                        "y" => Dict{String, Any}("type" => "unknown", "default" => 1.0),
                        "z" => Dict{String, Any}("type" => "unknown", "default" => 2.0)
                    ),
                    "equations" => Any[
                        Dict{String, Any}(
                            "lhs" => Dict{String, Any}("op" => "D", "args" => Any["y"], "wrt" => "t"),
                            "rhs" => Dict{String, Any}(
                                "op" => "apply_expression_template",
                                "args" => Any[], "name" => "scale",
                                "bindings" => Dict{String, Any}("x" => "z")
                            )
                        ),
                        Dict{String, Any}(
                            "lhs" => Dict{String, Any}("op" => "D", "args" => Any["z"], "wrt" => "t"),
                            "rhs" => Dict{String, Any}("op" => "-", "args" => Any["z"])
                        ),
                    ]
                )
            )
        )
        flat = EarthSciAST.flatten(EarthSciAST.load_string(IOBuffer(JSON3.write(doc))))
        @test !isempty(flat.template_registry)     # references reached the boundary
        sys = ModelingToolkit.System(flat; name = :TplRef)
        eqs = ModelingToolkit.equations(sys)
        @test length(eqs) == 2
        # The expanded body's `k` appears in the lowered equations.
        @test occursin("k", join(string.(eqs), "\n"))
        # The caller's FlattenedSystem is untouched (expansion was on a copy):
        # its D(M.y) equation still carries the surviving reference.
        has_ref = false
        for eq in flat.equations
            EarthSciAST.foreach_subexpr(eq.rhs) do x
                x isa EarthSciAST.OpExpr && x.op == "apply_expression_template" &&
                    (has_ref = true)
                nothing
            end
        end
        @test has_ref
    end

    @testset "lowering checks registry arity instead of truncating operands" begin
        ext = Base.get_extension(EarthSciAST, :EarthSciASTMTKExt)
        t = Symbolics.variable(:t)
        y, x = Symbolics.variable(:y), Symbolics.variable(:x)
        L = ext._Lowering(Dict{String, Any}("y" => y, "x" => x), t)
        lower(e) = ext._esm_to_symbolic(e, L)
        A = EarthSciAST.ASTExpr
        # Two-operand atan is atan(y, x), not atan(y).
        @test isequal(lower(OpExpr("atan", A[VarExpr("y"), VarExpr("x")])), atan(y, x))
        @test lower(OpExpr("atan", A[NumExpr(1.0), NumExpr(-1.0)])) ≈ atan(1.0, -1.0)
        @test isequal(
            lower(OpExpr("atan", A[VarExpr("y")])), atan(y)
        )
        for bad in (
                OpExpr("-", A[VarExpr("y"), VarExpr("x"), NumExpr(1.0)]),
                OpExpr("/", A[VarExpr("y"), VarExpr("x"), NumExpr(1.0)]),
                OpExpr("^", A[VarExpr("y")]),
                OpExpr("sin", A[VarExpr("y"), VarExpr("x")]),
                OpExpr("atan", A[VarExpr("y"), VarExpr("x"), NumExpr(1.0)]),
                OpExpr("max", A[VarExpr("y")]),
                OpExpr("ifelse", A[VarExpr("y"), VarExpr("x")]),
            )
            err = try
                lower(bad)
                nothing
            catch err
                err
            end
            @test err isa EarthSciAST.TreeWalkError
            @test err.code == "E_TREEWALK_ARITY"
        end
    end

    @testset "System refuses what it would build wrongly" begin
        decay(name) = Model(
            Dict(
                name => ModelVariable(UnknownVariable; default = 1.0),
                "k" => ModelVariable(ParameterVariable; default = 0.5),
            ),
            [
                Equation(
                    OpExpr("D", EarthSciAST.ASTExpr[VarExpr(name)], wrt = "t"),
                    OpExpr("*", EarthSciAST.ASTExpr[VarExpr("k"), VarExpr(name)])
                ),
            ]
        )
        # `a.b_c` and `a_b.c` both sanitize to the symbol `a_b_c`.
        file = EsmFile(
            "2.0.0", Metadata("Collide");
            models = Dict("a" => decay("b_c"), "a_b" => decay("c"))
        )
        flat = flatten(file)
        @test haskey(flat.state_variables, "a.b_c")
        @test haskey(flat.state_variables, "a_b.c")
        err = try
            ModelingToolkit.System(flat; name = :Collide)
            nothing
        catch e
            e
        end
        @test err isa SimulateError
        @test occursin("a_b_c", err.msg)

        # An event affect whose target is not a variable is refused, not dropped.
        flat1 = flatten(decay("x"); name = "D1")
        ev = EarthSciAST.ContinuousEvent(
            EarthSciAST.ASTExpr[OpExpr("-", EarthSciAST.ASTExpr[VarExpr("D1.x"), NumExpr(0.5)])],
            [EarthSciAST.AffectEquation("D1.nope", NumExpr(1.0))]
        )
        push!(flat1.continuous_events, ev)
        err = try
            ModelingToolkit.System(flat1; name = :D1)
            nothing
        catch e
            e
        end
        @test err isa SimulateError
        @test occursin("D1.nope", err.msg)
    end
end
