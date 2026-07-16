using Test
using EarthSciAST

include("testutils.jl")  # TESTUTILS_REPO_ROOT

@testset "Reaction System ODE Derivation Tests" begin

    @testset "Stoichiometric Matrix Tests" begin
        # Test simple reaction A + B -> C
        species_A = Species("A")
        species_B = Species("B")
        species_C = Species("C")
        species = [species_A, species_B, species_C]

        reaction = Reaction(
            Dict("A" => 1, "B" => 1),  # A + B
            Dict("C" => 1),            # -> C
            VarExpr("k1")
        )

        rxn_sys = ReactionSystem(species, [reaction])
        S = stoichiometric_matrix(rxn_sys)

        @test size(S) == (3, 1)  # 3 species, 1 reaction
        @test S[1, 1] == -1  # A consumed
        @test S[2, 1] == -1  # B consumed
        @test S[3, 1] == 1   # C produced

        # Test multiple reactions: A -> B, B -> C
        reaction1 = Reaction(Dict("A" => 1), Dict("B" => 1), VarExpr("k1"))
        reaction2 = Reaction(Dict("B" => 1), Dict("C" => 1), VarExpr("k2"))

        rxn_sys_multi = ReactionSystem(species, [reaction1, reaction2])
        S_multi = stoichiometric_matrix(rxn_sys_multi)

        @test size(S_multi) == (3, 2)  # 3 species, 2 reactions
        # Reaction 1: A -> B
        @test S_multi[1, 1] == -1  # A consumed
        @test S_multi[2, 1] == 1   # B produced
        @test S_multi[3, 1] == 0   # C unchanged
        # Reaction 2: B -> C
        @test S_multi[1, 2] == 0   # A unchanged
        @test S_multi[2, 2] == -1  # B consumed
        @test S_multi[3, 2] == 1   # C produced

        # Test source reaction (no reactants): -> A
        source_reaction = Reaction(Dict{String,Int}(), Dict("A" => 1), VarExpr("k_source"))
        rxn_sys_source = ReactionSystem([species_A], [source_reaction])
        S_source = stoichiometric_matrix(rxn_sys_source)

        @test size(S_source) == (1, 1)
        @test S_source[1, 1] == 1  # A produced from source

        # Test sink reaction (no products): A ->
        sink_reaction = Reaction(Dict("A" => 1), Dict{String,Int}(), VarExpr("k_sink"))
        rxn_sys_sink = ReactionSystem([species_A], [sink_reaction])
        S_sink = stoichiometric_matrix(rxn_sys_sink)

        @test size(S_sink) == (1, 1)
        @test S_sink[1, 1] == -1  # A consumed by sink

        # Test higher stoichiometry: 2A + B -> 3C
        high_stoich_reaction = Reaction(
            Dict("A" => 2, "B" => 1),
            Dict("C" => 3),
            VarExpr("k_high")
        )
        rxn_sys_high = ReactionSystem(species, [high_stoich_reaction])
        S_high = stoichiometric_matrix(rxn_sys_high)

        @test size(S_high) == (3, 1)
        @test S_high[1, 1] == -2  # 2A consumed
        @test S_high[2, 1] == -1  # B consumed
        @test S_high[3, 1] == 3   # 3C produced
    end

    @testset "Mass Action Rate Tests" begin
        species_A = Species("A")
        species_B = Species("B")
        species_C = Species("C")
        species = [species_A, species_B, species_C]

        # Test simple reaction A + B -> C
        reaction = Reaction(
            Dict("A" => 1, "B" => 1),
            Dict("C" => 1),
            VarExpr("k1")
        )

        rate_expr = mass_action_rate(reaction, species)
        @test rate_expr isa OpExpr
        @test rate_expr.op == "*"
        @test length(rate_expr.args) == 3  # k1 * A * B
        @test rate_expr.args[1] isa VarExpr
        @test rate_expr.args[1].name == "k1"

        # Test source reaction: -> A
        source_reaction = Reaction(Dict{String,Int}(), Dict("A" => 1), VarExpr("k_source"))
        source_rate = mass_action_rate(source_reaction, species)
        @test source_rate isa VarExpr
        @test source_rate.name == "k_source"

        # Test higher stoichiometry: 2A -> B
        high_stoich_reaction = Reaction(
            Dict("A" => 2),
            Dict("B" => 1),
            VarExpr("k_high")
        )
        high_rate = mass_action_rate(high_stoich_reaction, species)
        @test high_rate isa OpExpr
        @test high_rate.op == "*"
        @test length(high_rate.args) == 2  # k_high * A^2
        @test high_rate.args[1].name == "k_high"
        @test high_rate.args[2] isa OpExpr
        @test high_rate.args[2].op == "^"
        @test high_rate.args[2].args[1].name == "A"
        @test high_rate.args[2].args[2].value == 2.0

        # Test single reactant: A -> B
        single_reaction = Reaction(
            Dict("A" => 1),
            Dict("B" => 1),
            VarExpr("k_single")
        )
        single_rate = mass_action_rate(single_reaction, species)
        @test single_rate isa OpExpr
        @test single_rate.op == "*"
        @test length(single_rate.args) == 2  # k_single * A

        # esm-06a: spec §7.4 makes `reaction.rate` the COEFFICIENT and the
        # runner ALWAYS multiplies by the substrate product. There is no
        # detect-and-skip heuristic: even rates that reference substrates
        # (e.g. cancellation form `k/A`) still get the full mass-action
        # multiplication, leaving simplification to the downstream solver.
        _count_full(expr, name) = if expr isa VarExpr
            expr.name == name ? 1 : 0
        elseif expr isa OpExpr
            isempty(expr.args) ? 0 : sum(a -> _count_full(a, name), expr.args)
        else
            0
        end

        # Cancellation form: rate = k / A, substrates A + B.
        # Result: (k/A) * A * B — substrate A appears twice (denominator + multiplier).
        cancellation_rate = OpExpr("/",
            EarthSciAST.ASTExpr[VarExpr("k_cld"), VarExpr("A")])
        cancellation_reaction = Reaction(
            Dict("A" => 1, "B" => 1),
            Dict("C" => 1),
            cancellation_rate,
        )
        cancellation_result = mass_action_rate(cancellation_reaction, species)
        @test cancellation_result isa OpExpr
        @test cancellation_result.op == "*"
        @test length(cancellation_result.args) == 3  # (k/A) * A * B
        @test _count_full(cancellation_result, "A") == 2
        @test _count_full(cancellation_result, "B") == 1
        @test _count_full(cancellation_result, "k_cld") == 1

        # A rate that does NOT reference any substrate still gets the full
        # mass-action multiplication (the coefficient-only path is the
        # common case and must continue to work).
        const_reaction = Reaction(
            Dict("A" => 1, "B" => 1),
            Dict("C" => 1),
            VarExpr("k_const"),
        )
        const_result = mass_action_rate(const_reaction, species)
        @test const_result isa OpExpr
        @test const_result.op == "*"
        @test length(const_result.args) == 3
        @test const_result.args[1] isa VarExpr
        @test const_result.args[1].name == "k_const"
    end

    @testset "ODE Derivation Tests" begin
        # Test simple reaction A + B -> C
        species_A = Species("A")
        species_B = Species("B")
        species_C = Species("C")
        species = [species_A, species_B, species_C]

        param_k1 = Parameter("k1", 0.1, description="Rate constant", units="1/(mol⋅s)")
        parameters = [param_k1]

        reaction = Reaction(
            Dict("A" => 1, "B" => 1),
            Dict("C" => 1),
            VarExpr("k1")
        )

        rxn_sys = ReactionSystem(species, [reaction], parameters=parameters)
        model = derive_odes(rxn_sys)

        # Check variables
        @test length(model.variables) == 4  # 3 species + 1 parameter
        @test haskey(model.variables, "A")
        @test haskey(model.variables, "B")
        @test haskey(model.variables, "C")
        @test haskey(model.variables, "k1")

        @test model.variables["A"].type == StateVariable
        @test model.variables["B"].type == StateVariable
        @test model.variables["C"].type == StateVariable
        @test model.variables["k1"].type == ParameterVariable
        @test model.variables["k1"].default == 0.1

        # Check equations
        @test length(model.equations) == 3  # One for each species

        # Check that each equation is a differential equation
        for eq in model.equations
            @test eq.lhs isa OpExpr
            @test eq.lhs.op == "D"
            @test eq.lhs.wrt == "t"
        end

        # Find equation for species A
        eq_A = nothing
        for eq in model.equations
            if eq.lhs.args[1].name == "A"
                eq_A = eq
                break
            end
        end
        @test eq_A !== nothing

        # For A + B -> C, d[A]/dt should be negative (consumption)
        # RHS should be -k1*A*B
        @test eq_A.rhs isa OpExpr
        @test eq_A.rhs.op == "-"
        @test length(eq_A.rhs.args) == 1
        @test eq_A.rhs.args[1] isa OpExpr  # k1*A*B

        # Test multiple reactions
        reaction1 = Reaction(Dict("A" => 1), Dict("B" => 1), VarExpr("k1"))
        reaction2 = Reaction(Dict("B" => 1), Dict("C" => 1), VarExpr("k2"))
        param_k2 = Parameter("k2", 0.05, description="Rate constant 2")

        rxn_sys_multi = ReactionSystem(species, [reaction1, reaction2],
                                     parameters=[param_k1, param_k2])
        model_multi = derive_odes(rxn_sys_multi)

        @test length(model_multi.variables) == 5  # 3 species + 2 parameters
        @test length(model_multi.equations) == 3  # One for each species
        @test haskey(model_multi.variables, "k2")

        # Test source reaction: -> A with rate k_source
        param_source = Parameter("k_source", 1.0, description="Source rate")
        source_reaction = Reaction(Dict{String,Int}(), Dict("A" => 1), VarExpr("k_source"))
        rxn_sys_source = ReactionSystem([species_A], [source_reaction],
                                      parameters=[param_source])
        model_source = derive_odes(rxn_sys_source)

        @test length(model_source.variables) == 2  # 1 species + 1 parameter
        @test length(model_source.equations) == 1

        # For source reaction, d[A]/dt = k_source
        eq_source = model_source.equations[1]
        @test eq_source.lhs.args[1].name == "A"
        @test eq_source.rhs isa VarExpr
        @test eq_source.rhs.name == "k_source"

        # Test sink reaction: A -> with rate k_sink
        param_sink = Parameter("k_sink", 0.2, description="Sink rate")
        sink_reaction = Reaction(Dict("A" => 1), Dict{String,Int}(), VarExpr("k_sink"))
        rxn_sys_sink = ReactionSystem([species_A], [sink_reaction],
                                    parameters=[param_sink])
        model_sink = derive_odes(rxn_sys_sink)

        @test length(model_sink.variables) == 2  # 1 species + 1 parameter
        @test length(model_sink.equations) == 1

        # For sink reaction, d[A]/dt = -k_sink*A
        eq_sink = model_sink.equations[1]
        @test eq_sink.lhs.args[1].name == "A"
        @test eq_sink.rhs isa OpExpr
        @test eq_sink.rhs.op == "-"
    end

    @testset "Complex Reaction Networks" begin
        # Test a more complex network: A + B ⇌ C, C → D
        species = [Species("A"), Species("B"), Species("C"), Species("D")]
        parameters = [
            Parameter("k_forward", 0.1),
            Parameter("k_reverse", 0.05),
            Parameter("k_decay", 0.02)
        ]

        reactions = [
            Reaction(Dict("A"=>1, "B"=>1), Dict("C"=>1), VarExpr("k_forward")),
            Reaction(Dict("C"=>1), Dict("A"=>1, "B"=>1), VarExpr("k_reverse")),
            Reaction(Dict("C"=>1), Dict("D"=>1), VarExpr("k_decay"))
        ]

        rxn_sys = ReactionSystem(species, reactions, parameters=parameters)
        model = derive_odes(rxn_sys)

        @test length(model.variables) == 7  # 4 species + 3 parameters
        @test length(model.equations) == 4  # One for each species

        # Check that the stoichiometric matrix is correct
        S = stoichiometric_matrix(rxn_sys)
        @test size(S) == (4, 3)  # 4 species, 3 reactions

        # Reaction 1: A + B -> C
        @test S[1, 1] == -1  # A consumed
        @test S[2, 1] == -1  # B consumed
        @test S[3, 1] == 1   # C produced
        @test S[4, 1] == 0   # D unchanged

        # Reaction 2: C -> A + B (reverse)
        @test S[1, 2] == 1   # A produced
        @test S[2, 2] == 1   # B produced
        @test S[3, 2] == -1  # C consumed
        @test S[4, 2] == 0   # D unchanged

        # Reaction 3: C -> D
        @test S[1, 3] == 0   # A unchanged
        @test S[2, 3] == 0   # B unchanged
        @test S[3, 3] == -1  # C consumed
        @test S[4, 3] == 1   # D produced
    end

    @testset "Subsystem Handling" begin
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
    end

    @testset "Species Default Initial Values" begin
        # derive_odes must honor each species' declared scalar `default` as its
        # state variable's initial value (matching the main flatten path), and
        # fall back to 1.0 only when no default is declared.
        species = [
            Species("A", default=3.0),   # explicit non-fallback default
            Species("B"),                # no default -> sensible fallback (1.0)
            Species("C", default=0.0),   # explicit zero must survive (not fallback)
        ]
        reaction = Reaction(Dict("A" => 1, "B" => 1), Dict("C" => 1), VarExpr("k1"))
        rxn_sys = ReactionSystem(species, [reaction], parameters=[Parameter("k1", 0.1)])

        model = derive_odes(rxn_sys)

        @test model.variables["A"].default == 3.0
        @test model.variables["B"].default == 1.0
        @test model.variables["C"].default == 0.0

        # Defaults must also flow through subsystems.
        sub = ReactionSystem([Species("S", default=7.5)],
                             [Reaction(Dict("S" => 1), Dict{String,Int}(), VarExpr("k_s"))],
                             parameters=[Parameter("k_s", 0.2)])
        main = ReactionSystem([Species("M", default=2.0)],
                              [Reaction(Dict("M" => 1), Dict{String,Int}(), VarExpr("k_m"))],
                              parameters=[Parameter("k_m", 0.3)],
                              subsystems=Dict("sub" => sub))
        main_model = derive_odes(main)
        @test main_model.variables["M"].default == 2.0
        @test main_model.subsystems["sub"].variables["S"].default == 7.5
    end

    @testset "Reservoir species (constant: true) get no ODE" begin
        # esm-spec §7.4: "A species declared with `constant: true` is a
        # reservoir: it appears in rate laws as a concentration but no dX/dt
        # equation is generated for it. […] other bindings skip the ODE for that
        # species while still evaluating mass-action contributions from it."
        # R:  CH4 + OH -> HO2,  with CH4 a held-fixed reservoir.
        species = [Species("CH4", default=1700.0, constant=true),
                   Species("OH", default=1.0e-4),
                   Species("HO2", default=0.0)]
        rxn = Reaction(Dict("CH4" => 1, "OH" => 1), Dict("HO2" => 1), VarExpr("k"))
        rxn_sys = ReactionSystem(species, [rxn], parameters=[Parameter("k", 6.3e-15)])

        eqs = lower_reactions_to_equations(rxn_sys.reactions, rxn_sys.species)
        targets = Set(String(EarthSciAST.differential_lhs_variable(e.lhs)) for e in eqs)
        @test targets == Set(["OH", "HO2"])      # the reservoir is NOT a target
        @test !("CH4" in targets)

        # …but it still contributes its concentration to the rates it appears in:
        # dOH/dt must retain a CH4 factor, or the reservoir has been dropped from
        # the kinetics entirely rather than merely held fixed.
        oh_eq = only(e for e in eqs
                     if String(EarthSciAST.differential_lhs_variable(e.lhs)) == "OH")
        @test "CH4" in EarthSciAST._referenced_var_names(oh_eq.rhs)

        # A reservoir lowers to a PARAMETER, not to a state with a dead equation —
        # the latter would sit in `u` with a permanently-zero derivative.
        model = derive_odes(rxn_sys)
        @test model.variables["CH4"].type == ParameterVariable
        @test model.variables["CH4"].default == 1700.0
        @test model.variables["OH"].type == StateVariable
        @test model.variables["HO2"].type == StateVariable
    end

    @testset "Reservoir species stay fixed through flatten (shared fixture)" begin
        # The flatten path (namespacing.jl `_collect_reaction_system!`) must agree
        # with `derive_odes`. Asserted against the SHARED cross-binding fixture, so
        # this pins the semantics the other bindings round-trip: O2/CH4/H2O are
        # reservoirs; O3/OH/HO2 are ordinary states. Note reaction R3 PRODUCES O2 —
        # before the §7.4 fix that gave the reservoir a live, growing ODE.
        path = joinpath(TESTUTILS_REPO_ROOT, "tests", "valid",
                        "reservoir_species_constant.esm")
        flat = flatten(load(path))

        for r in ("O2", "CH4", "H2O")
            @test haskey(flat.parameters, "SuperFastSubset.$r")
            @test !haskey(flat.state_variables, "SuperFastSubset.$r")
        end
        for s in ("O3", "OH", "HO2")
            @test haskey(flat.state_variables, "SuperFastSubset.$s")
        end

        targets = Set{String}()
        for eq in flat.equations
            nm = EarthSciAST.differential_lhs_variable(eq.lhs)
            nm === nothing || push!(targets, String(nm))
        end
        @test targets == Set(["SuperFastSubset.O3", "SuperFastSubset.OH",
                              "SuperFastSubset.HO2"])
    end
end