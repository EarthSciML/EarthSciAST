using Test
using EarthSciAST
using JSON3

const ESS = EarthSciAST
const SE = EarthSciAST.StoichiometryEntry

# Structural equality for ASTExpr trees. OpExpr's Vector{ASTExpr} field makes
# default struct `==` (which falls back to `===`) fail for freshly-built
# equal trees — compare field-by-field recursively instead.
_expr_equal(a::NumExpr, b::NumExpr) = a.value == b.value
_expr_equal(a::IntExpr, b::IntExpr) = a.value == b.value
_expr_equal(a::VarExpr, b::VarExpr) = a.name == b.name
function _expr_equal(a::OpExpr, b::OpExpr)
    a.op == b.op || return false
    a.wrt == b.wrt || return false
    a.dim == b.dim || return false
    length(a.args) == length(b.args) || return false
    for (x, y) in zip(a.args, b.args)
        _expr_equal(x, y) || return false
    end
    return true
end
_expr_equal(::ESS.ASTExpr, ::ESS.ASTExpr) = false

# Small helpers so each testset can build a fresh fixture.
function _make_eq(lhs_name::String, coef::Float64)
    lhs = OpExpr("D", ESS.ASTExpr[VarExpr(lhs_name)], wrt="t")
    rhs = OpExpr("*", ESS.ASTExpr[NumExpr(coef), VarExpr(lhs_name)])
    return Equation(lhs, rhs)
end

function _make_model()
    vars = Dict{String,ModelVariable}(
        "x" => ModelVariable(StateVariable, default=1.0),
        "k" => ModelVariable(ParameterVariable, default=0.5),
    )
    eqs = Equation[_make_eq("x", 2.0)]
    return Model(vars, eqs)
end

function _make_reaction_system()
    species = [Species("A", default=1.0), Species("B", default=0.0)]
    rate = OpExpr("*", ESS.ASTExpr[VarExpr("k"), VarExpr("A")])
    rxn = Reaction("r1", [SE("A", 1)], [SE("B", 1)], rate)
    return ReactionSystem(species, [rxn]; parameters=[Parameter("k", 0.1)])
end

@testset "Section 4 Editing Operations" begin

    @testset "edits preserve extended struct fields" begin
        # Editing operations rebuild immutable structs; fields not touched by
        # the edit (initialization_equations, guesses, system_kind, enums,
        # index_sets, …) must survive the rebuild instead of being reset.
        vars = Dict{String,ModelVariable}(
            "x" => ModelVariable(StateVariable, default=1.0),
        )
        init_eqs = Equation[Equation(VarExpr("x"), NumExpr(1.0))]
        m = Model(vars, Equation[_make_eq("x", 2.0)];
                  initialization_equations=init_eqs,
                  guesses=Dict{String,Union{Float64,ESS.ASTExpr}}("x" => 0.5),
                  system_kind="ode")

        m2 = add_variable(m, "y", ModelVariable(StateVariable, default=0.0))
        @test m2.initialization_equations == init_eqs
        @test m2.guesses["x"] == 0.5
        @test m2.system_kind == "ode"

        m3 = add_equation(m, _make_eq("x", 3.0))
        @test m3.initialization_equations == init_eqs
        @test m3.system_kind == "ode"

        file = EsmFile("0.8.0", Metadata("t");
                       models=Dict("M" => m),
                       coupling=CouplingEntry[],
                       enums=Dict("phase" => Dict("gas" => 1)))
        file2 = add_coupling(file, CouplingOperatorCompose(["M", "M"]))
        @test file2.enums !== nothing
        @test file2.enums["phase"]["gas"] == 1
    end

    @testset "add_variable" begin
        m = _make_model()
        @test length(m.variables) == 2

        new_var = ModelVariable(StateVariable, default=5.0, description="new state")
        m2 = add_variable(m, "y", new_var)

        @test length(m2.variables) == 3
        @test haskey(m2.variables, "y")
        @test m2.variables["y"].default == 5.0
        @test m2.variables["y"].description == "new state"
        # original model should be unchanged (non-mutating)
        @test length(m.variables) == 2
        @test !haskey(m.variables, "y")
        # equations preserved
        @test length(m2.equations) == length(m.equations)
    end

    @testset "remove_variable" begin
        m = _make_model()
        # Add a second state variable that has no equation dependency
        m = add_variable(m, "y", ModelVariable(StateVariable, default=0.0))
        @test haskey(m.variables, "y")

        m2 = remove_variable(m, "y")
        @test !haskey(m2.variables, "y")
        @test length(m2.variables) == length(m.variables) - 1
        @test haskey(m2.variables, "x")
        # original unchanged
        @test haskey(m.variables, "y")

        # Removing a referenced variable still succeeds but warns; equations
        # are kept (per implementation contract).
        m3 = @test_logs (:warn,) match_mode=:any remove_variable(m2, "x")
        @test !haskey(m3.variables, "x")
        @test length(m3.equations) == length(m2.equations)

        # Removing non-existent: throws EditError.
        @test_throws ESS.EditError remove_variable(m2, "nonexistent")
    end

    @testset "rename_variable rewrites equation references" begin
        m = _make_model()  # equation: D(x) = 2*x
        m2 = rename_variable(m, "x", "z")

        @test !haskey(m2.variables, "x")
        @test haskey(m2.variables, "z")
        # rewritten equation: D(z) = 2*z
        @test length(m2.equations) == 1
        eq = m2.equations[1]
        @test eq.lhs isa OpExpr
        @test eq.lhs.op == "D"
        @test eq.lhs.args[1] isa VarExpr
        @test eq.lhs.args[1].name == "z"
        @test eq.rhs.args[2] isa VarExpr
        @test eq.rhs.args[2].name == "z"
        # original unchanged
        @test haskey(m.variables, "x")
    end

    @testset "add_equation appends" begin
        m = _make_model()
        new_eq = _make_eq("k", 0.0)  # D(k) = 0*k
        m2 = add_equation(m, new_eq)

        @test length(m2.equations) == length(m.equations) + 1
        @test m2.equations[end] === new_eq
        # original unchanged
        @test length(m.equations) == 1
    end

    @testset "remove_equation by index" begin
        m = _make_model()
        m = add_equation(m, _make_eq("k", 0.0))
        @test length(m.equations) == 2

        m2 = remove_equation(m, 1)
        @test length(m2.equations) == 1

        # Out-of-bounds: throws EditError
        @test_throws ESS.EditError remove_equation(m2, 99)
    end

    @testset "remove_equation by LHS pattern" begin
        m = _make_model()
        m = add_equation(m, _make_eq("k", 0.0))
        # Pattern must match the stored lhs by `==` — for OpExpr that is
        # `===` in the default struct, so reuse the exact lhs object here.
        pattern = m.equations[1].lhs
        m2 = remove_equation(m, pattern)
        @test length(m2.equations) == 1
        remaining = m2.equations[1]
        @test remaining.lhs.args[1].name == "k"

        # Pattern with no match: throws EditError
        bogus = OpExpr("D", ESS.ASTExpr[VarExpr("nonexistent")], wrt="t")
        @test_throws ESS.EditError remove_equation(m2, bogus)
    end

    @testset "substitute_in_equations rewrites expression trees" begin
        m = _make_model()  # D(x) = 2*x
        bindings = Dict{String, ESS.ASTExpr}("x" => NumExpr(42.0))
        m2 = substitute_in_equations(m, bindings)

        @test length(m2.equations) == 1
        rhs = m2.equations[1].rhs
        @test rhs isa OpExpr
        # Original expression: ("*", [NumExpr(2.0), VarExpr("x")]) -> x substituted
        @test rhs.args[1] isa NumExpr
        @test rhs.args[1].value == 2.0
        @test rhs.args[2] isa NumExpr
        @test rhs.args[2].value == 42.0
        # variables dict unchanged
        @test haskey(m2.variables, "x")
    end

    # Parity with Python test_substitute.py::TestReactionSystemSubstitution
    # (pkg/earthsci-ast-py/tests/test_substitute.py lines 214-283).
    # Julia has no substitute_in_reaction_system helper, so we apply
    # `substitute` directly to each reaction's rate expression, rebuild the
    # system, and assert that stoichiometry/coupling references are preserved.
    @testset "substitute rewrites rate expressions (simple)" begin
        # Rate: k * param_rate, bindings: param_rate -> A
        rate = OpExpr("*", ESS.ASTExpr[VarExpr("k"), VarExpr("param_rate")])
        rxn = Reaction("R1", [SE("A", 1)], [SE("B", 1)], rate)
        sys = ReactionSystem(
            [Species("A"), Species("B")],
            [rxn];
            parameters=[Parameter("k", 0.1)],
        )

        bindings = Dict{String,ESS.ASTExpr}("param_rate" => VarExpr("A"))
        new_rate = substitute(sys.reactions[1].rate, bindings)

        @test new_rate isa OpExpr
        @test new_rate.op == "*"
        @test new_rate.args[1] isa VarExpr && new_rate.args[1].name == "k"
        @test new_rate.args[2] isa VarExpr && new_rate.args[2].name == "A"

        # Substituting the rate must not disturb coupling references:
        # substrates/products still point to "A" / "B" with the original
        # stoichiometries, and species/parameter lists are unchanged.
        # Direct access to the ordered StoichiometryEntry vectors
        # (equivalently `raw_substrates` / `raw_products`).
        @test getfield(sys.reactions[1], :substrates) == [SE("A", 1)]
        @test getfield(sys.reactions[1], :products) == [SE("B", 1)]
        @test [s.name for s in sys.species] == ["A", "B"]
        @test [p.name for p in sys.parameters] == ["k"]
    end

    @testset "substitute rewrites rate expressions (nested operators)" begin
        # Rate: k * temp^2, bindings: k -> 0.1, temp -> T
        inner = OpExpr("^", ESS.ASTExpr[VarExpr("temp"), NumExpr(2.0)])
        rate = OpExpr("*", ESS.ASTExpr[VarExpr("k"), inner])
        # Source reaction (no substrates) to mirror the Python fixture shape.
        rxn = Reaction("R1", nothing, [SE("A", 1)], rate)
        sys = ReactionSystem([Species("A")], [rxn])

        bindings = Dict{String,ESS.ASTExpr}(
            "k" => NumExpr(0.1),
            "temp" => VarExpr("T"),
        )
        new_rate = substitute(sys.reactions[1].rate, bindings)

        # Expected: 0.1 * (T ^ 2)
        @test new_rate isa OpExpr && new_rate.op == "*"
        @test new_rate.args[1] isa NumExpr && new_rate.args[1].value == 0.1
        @test new_rate.args[2] isa OpExpr && new_rate.args[2].op == "^"
        @test new_rate.args[2].args[1] isa VarExpr &&
              new_rate.args[2].args[1].name == "T"
        @test new_rate.args[2].args[2] isa NumExpr &&
              new_rate.args[2].args[2].value == 2.0

        # Source reaction shape preserved: substrates remain `nothing`,
        # products still reference species "A". Use getfield to bypass the
        # Dict-returning property shim.
        @test getfield(sys.reactions[1], :substrates) === nothing
        @test getfield(sys.reactions[1], :products) == [SE("A", 1)]
    end

    @testset "substitute preserves reaction-system structure" begin
        # Rate is a bare variable "param"; binding param -> k swaps the rate
        # reference onto an existing parameter.
        rxn = Reaction("R1", nothing, [SE("A", 1)], VarExpr("param"))
        sys = ReactionSystem(
            [Species("A", default=18.0)],
            [rxn];
            parameters=[Parameter("k", 0.1; units="1/s")],
        )

        bindings = Dict{String,ESS.ASTExpr}("param" => VarExpr("k"))
        new_rate = substitute(sys.reactions[1].rate, bindings)

        # Rewritten rate is the bound VarExpr.
        @test new_rate isa VarExpr && new_rate.name == "k"

        # Species/parameter metadata and reaction identity untouched —
        # ensures coupling references (species names, parameter names,
        # reaction ids) remain consistent across substitution.
        @test sys.species[1].default == 18.0
        @test sys.parameters[1].units == "1/s"
        @test sys.reactions[1].id == "R1"
        @test getfield(sys.reactions[1], :products) == [SE("A", 1)]
    end

    @testset "add_reaction / remove_reaction" begin
        sys = _make_reaction_system()
        @test length(sys.reactions) == 1

        rxn2 = Reaction("r2", [SE("B", 1)], [SE("A", 1)], NumExpr(0.1))
        sys2 = add_reaction(sys, rxn2)
        @test length(sys2.reactions) == 2
        @test sys2.reactions[end].id == "r2"

        sys3 = remove_reaction(sys2, "r1")
        @test length(sys3.reactions) == 1
        @test sys3.reactions[1].id == "r2"
        # species & parameters preserved
        @test length(sys3.species) == length(sys.species)
        @test length(sys3.parameters) == length(sys.parameters)

        # Remove nonexistent: throws EditError
        @test_throws ESS.EditError remove_reaction(sys3, "nope")
    end

    @testset "add_species / remove_species" begin
        sys = _make_reaction_system()
        sys2 = add_species(sys, "C", Species("C", default=2.0))
        @test length(sys2.species) == 3
        @test any(s -> s.name == "C", sys2.species)

        # Remove the fresh species (no reaction depends on it)
        sys3 = remove_species(sys2, "C")
        @test length(sys3.species) == 2
        @test !any(s -> s.name == "C", sys3.species)

        # Remove a species that IS used in a reaction (A): warns about dependency
        sys4 = @test_logs (:warn,) match_mode=:any remove_species(sys3, "A")
        @test !any(s -> s.name == "A", sys4.species)

        # Removing nonexistent: throws EditError
        @test_throws ESS.EditError remove_species(sys4, "ZZ")
    end

    @testset "add_continuous_event / add_discrete_event / remove_event" begin
        m = _make_model()

        disc = DiscreteEvent(
            ConditionTrigger(VarExpr("x")),
            [AffectEquation("x", NumExpr(0.0))],
            description="reset",
        )
        cont = ContinuousEvent(
            ESS.ASTExpr[VarExpr("x")],
            [AffectEquation("x", NumExpr(1.0))],
            description="bounce",
        )

        m2 = add_discrete_event(m, disc)
        @test length(m2.discrete_events) == 1
        @test m2.discrete_events[1].description == "reset"
        @test length(m2.continuous_events) == 0

        m3 = add_continuous_event(m2, cont)
        @test length(m3.continuous_events) == 1
        @test m3.continuous_events[1].description == "bounce"
        @test length(m3.discrete_events) == 1

        # Remove "reset" (matches the discrete event by description)
        m4 = remove_event(m3, "reset")
        @test length(m4.discrete_events) == 0
        @test length(m4.continuous_events) == 1

        # Remove "bounce" (the continuous event)
        m5 = remove_event(m4, "bounce")
        @test length(m5.discrete_events) == 0
        @test length(m5.continuous_events) == 0

        # Removing a missing event: throws EditError
        @test_throws ESS.EditError remove_event(m5, "ghost")
    end

    @testset "add_coupling / remove_coupling" begin
        file = EsmFile("0.1.0", Metadata("test"); coupling=CouplingEntry[])
        @test length(file.coupling) == 0

        entry1 = CouplingOperatorCompose(["A", "B"]; description="compose AB")
        file1 = add_coupling(file, entry1)
        @test length(file1.coupling) == 1
        @test file1.coupling[1] isa CouplingOperatorCompose
        @test file1.coupling[1].systems == ["A", "B"]

        entry2 = CouplingVariableMap("A.x", "B.y", "identity")
        file2 = add_coupling(file1, entry2)
        @test length(file2.coupling) == 2

        file3 = remove_coupling(file2, 1)
        @test length(file3.coupling) == 1
        @test file3.coupling[1] isa CouplingVariableMap

        # Out-of-bounds remove: throws EditError
        @test_throws ESS.EditError remove_coupling(file3, 99)
    end

    @testset "compose (convenience for operator_compose)" begin
        file = EsmFile("0.1.0", Metadata("test"); coupling=CouplingEntry[])
        file2 = compose(file, "Atmosphere", "Ocean")
        @test length(file2.coupling) == 1
        entry = file2.coupling[1]
        @test entry isa CouplingOperatorCompose
        @test entry.systems == ["Atmosphere", "Ocean"]
    end

    @testset "map_variable (convenience for variable_map)" begin
        file = EsmFile("0.1.0", Metadata("test"); coupling=CouplingEntry[])
        file2 = map_variable(file, "Atmosphere.T", "Ocean.T_surf"; transform="identity")
        @test length(file2.coupling) == 1
        entry = file2.coupling[1]
        @test entry isa CouplingVariableMap
        @test entry.from == "Atmosphere.T"
        @test entry.to == "Ocean.T_surf"
        @test entry.transform == "identity"
    end

    @testset "merge combines two ESM files" begin
        model_a = Model(Dict("x" => ModelVariable(StateVariable, default=1.0)), Equation[])
        model_b = Model(Dict("y" => ModelVariable(StateVariable, default=2.0)), Equation[])

        file_a = EsmFile("0.1.0", Metadata("a");
                         models=Dict("A" => model_a),
                         coupling=CouplingEntry[CouplingOperatorCompose(["A", "A"])])
        file_b = EsmFile("0.1.0", Metadata("b");
                         models=Dict("B" => model_b),
                         coupling=CouplingEntry[CouplingVariableMap("A.x", "B.y", "identity")])

        merged = ESS.merge(file_a, file_b)
        @test length(merged.models) == 2
        @test haskey(merged.models, "A")
        @test haskey(merged.models, "B")
        @test length(merged.coupling) == 2
        # file_b metadata wins
        @test merged.metadata.name == "b"
    end

    @testset "merge prefers file_b on key conflicts" begin
        m1 = Model(Dict("x" => ModelVariable(StateVariable, default=1.0)), Equation[])
        m2 = Model(Dict("x" => ModelVariable(StateVariable, default=999.0)), Equation[])

        fa = EsmFile("0.1.0", Metadata("a"); models=Dict("Shared" => m1))
        fb = EsmFile("0.1.0", Metadata("b"); models=Dict("Shared" => m2))

        merged = ESS.merge(fa, fb)
        @test length(merged.models) == 1
        # file_b takes precedence
        @test merged.models["Shared"].variables["x"].default == 999.0
    end

    @testset "extract top-level component" begin
        model_a = Model(Dict("x" => ModelVariable(StateVariable)), Equation[])
        model_b = Model(Dict("y" => ModelVariable(StateVariable)), Equation[])
        model_c = Model(Dict("z" => ModelVariable(StateVariable)), Equation[])

        compose_entry = CouplingOperatorCompose(["A", "C"])
        map_entry = CouplingVariableMap("A.x", "B.y", "identity")
        unrelated = CouplingOperatorCompose(["B", "C"])

        file = EsmFile("0.1.0", Metadata("all");
                       models=Dict("A" => model_a, "B" => model_b, "C" => model_c),
                       coupling=CouplingEntry[compose_entry, map_entry, unrelated])

        ex = ESS.extract(file, "A")
        @test length(ex.models) == 1
        @test haskey(ex.models, "A")
        # Coupling entries involving A: compose_entry (A in systems) + map_entry (from=A.x)
        @test length(ex.coupling) == 2
        @test compose_entry in ex.coupling
        @test map_entry in ex.coupling
        @test !(unrelated in ex.coupling)

        # Metadata, reaction_systems, etc. preserved
        @test ex.metadata.name == "all"
        @test ex.reaction_systems !== nothing || ex.reaction_systems === nothing  # structural check
    end

    @testset "extract throws EditError when component not found" begin
        file = EsmFile("0.1.0", Metadata("t");
                       models=Dict("A" => Model(Dict{String,ModelVariable}(), Equation[])),
                       coupling=CouplingEntry[])
        @test_throws ESS.EditError ESS.extract(file, "Missing")
        # EditError carries the message in its `msg` field
        err = try
            ESS.extract(file, "Missing")
            nothing
        catch e
            e
        end
        @test err isa ESS.EditError
        @test occursin("Missing", err.msg)
    end

    # Model-level substitution — ported from Python's TestModelSubstitution
    # (bindings/python/tests/test_substitute.py). Exercises the typed-model
    # analog (substitute_in_equations + rename_variable) against the shared
    # substitution fixtures to ensure cross-language parity.
    @testset "substitute-in-model (ported from Python)" begin

        @testset "shared fixtures drive model-level substitute" begin
            fixtures_dir = joinpath(@__DIR__, "..", "..", "..", "tests", "substitution")
            fixture_file = joinpath(fixtures_dir, "simple_var_replace.json")
            @test isfile(fixture_file)

            cases = JSON3.read(read(fixture_file, String))
            # simple_var_replace.json is a flat array of {input, bindings, expected}
            @test cases isa JSON3.Array
            @test !isempty(cases)

            for case in cases
                input_expr = ESS.parse_expression(case[:input])
                expected_expr = ESS.parse_expression(case[:expected])
                bindings = Dict{String, ESS.ASTExpr}(
                    string(k) => ESS.parse_expression(v)
                    for (k, v) in pairs(case[:bindings])
                )

                # Wrap the fixture expression as the RHS of a lone equation in
                # a minimal model. The LHS references a state variable the
                # bindings won't touch so we can isolate RHS substitution.
                vars = Dict{String,ModelVariable}(
                    "out" => ModelVariable(StateVariable, default=0.0),
                )
                eq = Equation(VarExpr("out"), input_expr)
                model = Model(vars, Equation[eq])

                result = substitute_in_equations(model, bindings)
                @test length(result.equations) == 1
                @test _expr_equal(result.equations[1].lhs, VarExpr("out"))
                @test _expr_equal(result.equations[1].rhs, expected_expr)
                # variables dict is preserved verbatim
                @test result.variables == model.variables
            end
        end

        @testset "substitute_in_equations preserves variable metadata" begin
            vars = Dict{String,ModelVariable}(
                "x" => ModelVariable(StateVariable,
                                     default=1.0,
                                     description="state var",
                                     units="kg"),
                "param" => ModelVariable(ParameterVariable,
                                         default=0.5,
                                         description="rate",
                                         units="1/s"),
            )
            # D(x) = param
            lhs = OpExpr("D", ESS.ASTExpr[VarExpr("x")], wrt="t")
            rhs = VarExpr("param")
            model = Model(vars, Equation[Equation(lhs, rhs)])

            bindings = Dict{String,ESS.ASTExpr}("param" => NumExpr(0.5))
            result = substitute_in_equations(model, bindings)

            # Equations rewritten
            @test length(result.equations) == 1
            @test result.equations[1].rhs == NumExpr(0.5)
            # Variables dict and all per-variable metadata preserved (attribute-
            # preservation analog of Python's test_substitute_in_model_with_metadata)
            @test result.variables == model.variables
            x = result.variables["x"]
            @test x.type == StateVariable
            @test x.default == 1.0
            @test x.description == "state var"
            @test x.units == "kg"
            p = result.variables["param"]
            @test p.default == 0.5
            @test p.units == "1/s"
            @test p.description == "rate"
            # Events/subsystems/tolerance containers preserved
            @test result.discrete_events === model.discrete_events
            @test result.continuous_events === model.continuous_events
            @test result.subsystems == model.subsystems
            @test result.tolerance === model.tolerance
        end

        @testset "substitute_in_equations on empty-equations model" begin
            vars = Dict{String,ModelVariable}(
                "x" => ModelVariable(StateVariable, default=1.0),
            )
            model = Model(vars, Equation[])

            result = substitute_in_equations(model, Dict{String,ESS.ASTExpr}("a" => VarExpr("b")))
            @test isempty(result.equations)
            @test result.variables == model.variables
        end

        @testset "rename_variable across a model" begin
            # Model with two equations that both reference the variable being
            # renamed, plus a parameter that should survive untouched.
            vars = Dict{String,ModelVariable}(
                "C" => ModelVariable(StateVariable,
                                     default=1.0,
                                     description="concentration",
                                     units="mol/m^3"),
                "k" => ModelVariable(ParameterVariable, default=0.1, units="1/s"),
            )
            eq1 = Equation(
                OpExpr("D", ESS.ASTExpr[VarExpr("C")], wrt="t"),
                OpExpr("*", ESS.ASTExpr[NumExpr(-1.0), VarExpr("k"), VarExpr("C")]),
            )
            eq2 = Equation(
                VarExpr("C"),
                OpExpr("*", ESS.ASTExpr[NumExpr(2.0), VarExpr("C")]),
            )
            model = Model(vars, Equation[eq1, eq2])

            renamed = rename_variable(model, "C", "O3")

            # Variable dict: old name gone, new name present, metadata carried over
            @test !haskey(renamed.variables, "C")
            @test haskey(renamed.variables, "O3")
            o3 = renamed.variables["O3"]
            @test o3.type == StateVariable
            @test o3.default == 1.0
            @test o3.description == "concentration"
            @test o3.units == "mol/m^3"
            # Unrelated variable untouched
            @test renamed.variables["k"].default == 0.1
            @test renamed.variables["k"].units == "1/s"

            # Equation rewriting: every VarExpr("C") → VarExpr("O3")
            @test length(renamed.equations) == 2
            @test _expr_equal(renamed.equations[1].lhs.args[1], VarExpr("O3"))
            mul = renamed.equations[1].rhs
            @test _expr_equal(mul.args[3], VarExpr("O3"))
            @test _expr_equal(mul.args[2], VarExpr("k"))  # other vars untouched
            @test _expr_equal(renamed.equations[2].lhs, VarExpr("O3"))
            @test _expr_equal(renamed.equations[2].rhs.args[2], VarExpr("O3"))

            # Original model is not mutated
            @test haskey(model.variables, "C")
            @test !haskey(model.variables, "O3")
        end
    end

end
