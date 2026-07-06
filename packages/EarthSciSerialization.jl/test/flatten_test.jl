using EarthSciSerialization
using EarthSciSerialization: Expr as ESMExpr
using Test
import ModelingToolkit

include("testutils.jl")  # _op builder + TESTUTILS_REPO_ROOT

# Helpers for building expressions inside tests (on top of testutils.jl's _op).
const _N = EarthSciSerialization.NumExpr
const _V = EarthSciSerialization.VarExpr
_deriv(name) = _op("D", _V(name); wrt="t")

# Locate a flattened equation whose LHS dependent variable matches `dep`.
function _find_eq(flat::FlattenedSystem, dep::String)
    for eq in flat.equations
        if eq.lhs isa EarthSciSerialization.OpExpr && eq.lhs.op == "D" &&
           !isempty(eq.lhs.args) && eq.lhs.args[1] isa EarthSciSerialization.VarExpr &&
           (eq.lhs.args[1]::EarthSciSerialization.VarExpr).name == dep
            return eq
        end
        if eq.lhs isa EarthSciSerialization.VarExpr && eq.lhs.name == dep
            return eq
        end
    end
    return nothing
end

# Does an Expr tree contain a VarExpr whose name matches `target`?
function _uses_var(expr::EarthSciSerialization.Expr, target::String)
    if expr isa EarthSciSerialization.VarExpr
        return expr.name == target
    elseif expr isa EarthSciSerialization.OpExpr
        return any(a -> _uses_var(a, target), expr.args)
    end
    return false
end

# Does an Expr tree contain any OpExpr matching `op_name`?
function _has_op(expr::EarthSciSerialization.Expr, op_name::String)
    if expr isa EarthSciSerialization.OpExpr
        expr.op == op_name && return true
        return any(a -> _has_op(a, op_name), expr.args)
    end
    return false
end

@testset "Flatten System" begin

    @testset "1. Reactions-only Model" begin
        species = [EarthSciSerialization.Species("A", default=1.0),
                   EarthSciSerialization.Species("B", default=0.0)]
        params = [EarthSciSerialization.Parameter("k", 0.1)]
        rate = _op("*", _V("k"), _V("A"))
        rxns = [EarthSciSerialization.Reaction("r1",
            [EarthSciSerialization.StoichiometryEntry("A", 1)],
            [EarthSciSerialization.StoichiometryEntry("B", 1)],
            rate)]
        rsys = EarthSciSerialization.ReactionSystem(species, rxns, parameters=params)
        file = EarthSciSerialization.EsmFile("0.1.0",
            EarthSciSerialization.Metadata("t1"),
            reaction_systems=Dict("Chem" => rsys))
        flat = flatten(file)

        @test haskey(flat.state_variables, "Chem.A")
        @test haskey(flat.state_variables, "Chem.B")
        @test haskey(flat.parameters, "Chem.k")
        @test length(flat.equations) == 2

        eq_A = _find_eq(flat, "Chem.A")
        eq_B = _find_eq(flat, "Chem.B")
        @test eq_A !== nothing && eq_B !== nothing
        # d[A]/dt = -k*A
        @test _uses_var(eq_A.rhs, "Chem.k") && _uses_var(eq_A.rhs, "Chem.A")
        # d[B]/dt = +k*A
        @test _uses_var(eq_B.rhs, "Chem.k") && _uses_var(eq_B.rhs, "Chem.A")
    end

    @testset "2. Mixed equations + reactions (disjoint species)" begin
        vars = Dict{String, ModelVariable}(
            "T" => ModelVariable(StateVariable, default=300.0),
            "k" => ModelVariable(ParameterVariable, default=0.1),
        )
        eqs = [Equation(_deriv("T"), _op("*", _V("k"), _V("T")))]
        model = Model(vars, eqs)

        species = [EarthSciSerialization.Species("A", default=1.0)]
        rxns = [EarthSciSerialization.Reaction("r1", nothing,
            [EarthSciSerialization.StoichiometryEntry("A", 1)],
            _N(0.5))]
        rsys = EarthSciSerialization.ReactionSystem(species, rxns)

        file = EarthSciSerialization.EsmFile("0.1.0",
            EarthSciSerialization.Metadata("t2"),
            models=Dict("Climate" => model),
            reaction_systems=Dict("Chem" => rsys))
        flat = flatten(file)

        @test haskey(flat.state_variables, "Climate.T")
        @test haskey(flat.state_variables, "Chem.A")
        @test haskey(flat.parameters, "Climate.k")
        @test _find_eq(flat, "Climate.T") !== nothing
        @test _find_eq(flat, "Chem.A") !== nothing
    end

    @testset "3. Autocatalytic A + B → 2B (net stoich of B is +1)" begin
        species = [EarthSciSerialization.Species("A"),
                   EarthSciSerialization.Species("B")]
        # Pass k as the rate constant. `mass_action_rate` multiplies by the
        # substrate concentrations (A and B) to form the full rate expression.
        rate = _V("k")
        rxns = [EarthSciSerialization.Reaction("r1",
            [EarthSciSerialization.StoichiometryEntry("A", 1),
             EarthSciSerialization.StoichiometryEntry("B", 1)],
            [EarthSciSerialization.StoichiometryEntry("B", 2)],
            rate)]
        params = [EarthSciSerialization.Parameter("k", 0.3)]
        rsys = EarthSciSerialization.ReactionSystem(species, rxns, parameters=params)
        file = EarthSciSerialization.EsmFile("0.1.0",
            EarthSciSerialization.Metadata("t3"),
            reaction_systems=Dict("Auto" => rsys))
        flat = flatten(file)

        eq_A = _find_eq(flat, "Auto.A")
        eq_B = _find_eq(flat, "Auto.B")
        @test eq_A !== nothing && eq_B !== nothing

        # Net stoich of B = 2 - 1 = +1. The reaction lowering MUST take the
        # `stoich == 1` branch, which passes the mass_action_rate expression
        # through unmodified — i.e. eq_B.rhs is exactly `k * A * B` with:
        #
        #   - a top-level OpExpr("*") (not "+" and not "-")
        #   - no leading NumExpr coefficient (no `2*rate` artifact)
        #   - references to k, A, and B
        #
        # This distinguishes the correct +1 case from the incorrect
        # structures `2*rate + (-rate)` (would be top-level "+"),
        # `2*rate` (would have a leading NumExpr(2)), or `-rate` (would be
        # top-level unary "-").
        @test eq_B.rhs isa EarthSciSerialization.OpExpr
        top_B = eq_B.rhs::EarthSciSerialization.OpExpr
        @test top_B.op == "*"
        @test top_B.op != "+"
        @test top_B.op != "-"
        @test !any(a -> a isa EarthSciSerialization.NumExpr, top_B.args)
        @test _uses_var(eq_B.rhs, "Auto.k")
        @test _uses_var(eq_B.rhs, "Auto.A")
        @test _uses_var(eq_B.rhs, "Auto.B")

        # Net stoich of A = -1. The A equation MUST take the `stoich == -1`
        # branch, which wraps the mass_action_rate term in a unary negation.
        # Structurally: eq_A.rhs is OpExpr("-", [rate_expr]) — a unary minus
        # with exactly one arg that itself contains k, A, and B.
        @test eq_A.rhs isa EarthSciSerialization.OpExpr
        top_A = eq_A.rhs::EarthSciSerialization.OpExpr
        @test top_A.op == "-"
        @test length(top_A.args) == 1
        @test _uses_var(eq_A.rhs, "Auto.k")
        @test _uses_var(eq_A.rhs, "Auto.A")
        @test _uses_var(eq_A.rhs, "Auto.B")
    end

    @testset "4. Source (null substrates) and sink (null products) reactions" begin
        species = [EarthSciSerialization.Species("X")]
        source = EarthSciSerialization.Reaction("src", nothing,
            [EarthSciSerialization.StoichiometryEntry("X", 1)],
            _V("kin"))
        sink = EarthSciSerialization.Reaction("snk",
            [EarthSciSerialization.StoichiometryEntry("X", 1)], nothing,
            _op("*", _V("kout"), _V("X")))
        params = [EarthSciSerialization.Parameter("kin", 1.0),
                  EarthSciSerialization.Parameter("kout", 0.5)]
        rsys = EarthSciSerialization.ReactionSystem(species, [source, sink], parameters=params)
        file = EarthSciSerialization.EsmFile("0.1.0",
            EarthSciSerialization.Metadata("t4"),
            reaction_systems=Dict("S" => rsys))
        flat = flatten(file)

        eq_X = _find_eq(flat, "S.X")
        @test eq_X !== nothing
        @test _uses_var(eq_X.rhs, "S.kin")
        @test _uses_var(eq_X.rhs, "S.kout")
    end

    @testset "5. ConflictingDerivativeError for explicit D + reaction on same species" begin
        # Model with explicit D(O3)/dt = ...
        mvars = Dict{String, ModelVariable}(
            "O3" => ModelVariable(StateVariable, default=1e-6),
            "k" => ModelVariable(ParameterVariable, default=0.1),
        )
        meqs = [Equation(_deriv("O3"), _op("-", _op("*", _V("k"), _V("O3"))))]
        model = Model(mvars, meqs)

        # Reaction system also touches O3
        species = [EarthSciSerialization.Species("O3", default=1e-6)]
        rate = _V("kr")
        rxns = [EarthSciSerialization.Reaction("r1", nothing,
            [EarthSciSerialization.StoichiometryEntry("O3", 1)], rate)]
        params = [EarthSciSerialization.Parameter("kr", 0.01)]
        rsys = EarthSciSerialization.ReactionSystem(species, rxns, parameters=params)

        # Model prefix is "SimpleOzone" and reaction system is also "SimpleOzone"
        file = EarthSciSerialization.EsmFile("0.1.0",
            EarthSciSerialization.Metadata("t5"),
            models=Dict("SimpleOzone" => model),
            reaction_systems=Dict("SimpleOzone" => rsys))

        # Flatten must throw.
        err = nothing
        try
            flatten(file)
        catch e
            err = e
        end
        @test err isa ConflictingDerivativeError
        @test "SimpleOzone.O3" in err.species

        # Validate must also flag the conflict.
        errs = validate_structural(file)
        @test any(e -> e.error_type == "conflicting_derivative" &&
                       occursin("SimpleOzone.O3", e.message), errs)
    end

    @testset "6. operator_compose across two models (summed RHS)" begin
        # Two models both declaring T with D(T)/dt; compose them.
        vars1 = Dict{String, ModelVariable}(
            "T" => ModelVariable(StateVariable),
            "k" => ModelVariable(ParameterVariable, default=0.1),
        )
        eqs1 = [Equation(_deriv("T"), _op("*", _V("k"), _V("T")))]
        m1 = Model(vars1, eqs1)

        vars2 = Dict{String, ModelVariable}(
            "T" => ModelVariable(StateVariable),
            "j" => ModelVariable(ParameterVariable, default=0.05),
        )
        eqs2 = [Equation(_deriv("T"), _op("*", _V("j"), _V("T")))]
        m2 = Model(vars2, eqs2)

        coupling = CouplingEntry[
            CouplingOperatorCompose(["A", "B"];
                translate=Dict{String,Any}("A.T" => "B.T")),
        ]
        file = EarthSciSerialization.EsmFile("0.1.0",
            EarthSciSerialization.Metadata("t6"),
            models=Dict("A" => m1, "B" => m2),
            coupling=coupling)
        flat = flatten(file)

        # After compose we expect a single equation for the canonical dep var
        # (B.T, since A.T was translated to B.T) and none for A.T.
        @test _find_eq(flat, "B.T") !== nothing
        eq = _find_eq(flat, "B.T")
        # Merged RHS MUST reference BOTH A's parameter (k) AND B's parameter (j),
        # i.e. both sides of the summed equation made it through the merge.
        # Using || would mask the case where only one side survived.
        @test _uses_var(eq.rhs, "A.k")
        @test _uses_var(eq.rhs, "B.j")
        # And both state references (A.T and B.T) must appear.
        @test _uses_var(eq.rhs, "A.T")
        @test _uses_var(eq.rhs, "B.T")
        # The top-level RHS should be a sum (+) of the two composed terms.
        @test eq.rhs isa EarthSciSerialization.OpExpr
        @test (eq.rhs::EarthSciSerialization.OpExpr).op == "+"
    end

    @testset "7. variable_map param_to_var substitutes and removes parameter" begin
        vars = Dict{String, ModelVariable}(
            "T" => ModelVariable(StateVariable),
            "k" => ModelVariable(ParameterVariable, default=0.1),
            "external" => ModelVariable(ParameterVariable, default=1.0),
        )
        eqs = [Equation(_deriv("T"),
                        _op("*", _V("external"), _op("*", _V("k"), _V("T"))))]
        model = Model(vars, eqs)

        source_vars = Dict{String, ModelVariable}(
            "value" => ModelVariable(StateVariable, default=0.5),
        )
        source_model = Model(source_vars, Equation[])

        coupling = CouplingEntry[
            CouplingVariableMap("Source.value", "Target.external", "param_to_var"),
        ]
        file = EarthSciSerialization.EsmFile("0.1.0",
            EarthSciSerialization.Metadata("t7"),
            models=Dict("Target" => model, "Source" => source_model),
            coupling=coupling)
        flat = flatten(file)

        # Target.external should be removed from parameters.
        @test !haskey(flat.parameters, "Target.external")
        # The Target.T equation should now reference Source.value.
        eq = _find_eq(flat, "Target.T")
        @test eq !== nothing
        @test _uses_var(eq.rhs, "Source.value")
    end

    @testset "7b. variable_map expression transform makes target an observed (esm-spec §10.4)" begin
        # Sink: parameter F_in (target), parameter offset, state u with du/dt = F_in.
        sink_vars = Dict{String, ModelVariable}(
            "u" => ModelVariable(StateVariable, default=0.0),
            "offset" => ModelVariable(ParameterVariable, default=1.5, units="1"),
            "F_in" => ModelVariable(ParameterVariable, units="1",
                                    description="receiving target"),
        )
        sink = Model(sink_vars, [Equation(_deriv("u"), _V("F_in"))])
        # Src: observed F = 4.0.
        src_vars = Dict{String, ModelVariable}(
            "F" => ModelVariable(ObservedVariable, units="1",
                                 expression=_N(4.0)),
        )
        src = Model(src_vars, Equation[])
        # transform = 2*Src.F + Sink.offset — fully-scoped refs per §10.4.
        transform = _op("+", _op("*", _N(2.0), _V("Src.F")), _V("Sink.offset"))
        coupling = CouplingEntry[
            CouplingVariableMap("Src.F", "Sink.F_in", transform),
        ]
        file = EarthSciSerialization.EsmFile("0.8.0",
            EarthSciSerialization.Metadata("t7b"),
            models=Dict("Sink" => sink, "Src" => src),
            coupling=coupling)
        flat = flatten(file)

        # The target parameter is promoted out of the parameters map...
        @test !haskey(flat.parameters, "Sink.F_in")
        # ...and becomes an observed whose defining expression IS the transform.
        @test haskey(flat.observed_variables, "Sink.F_in")
        obs = flat.observed_variables["Sink.F_in"]
        @test obs.type == ObservedVariable
        @test obs.units == "1"
        @test obs.expression == transform
        # A defining equation Sink.F_in ~ transform is synthesized.
        defeq = _find_eq(flat, "Sink.F_in")
        @test defeq !== nothing
        @test defeq.rhs == transform
        # The consuming ODE still references the target by name (no inlining).
        ueq = _find_eq(flat, "Sink.u")
        @test ueq !== nothing
        @test _uses_var(ueq.rhs, "Sink.F_in")
    end

    @testset "7c. variable_map expression transform must reference `from`" begin
        sink_vars = Dict{String, ModelVariable}(
            "u" => ModelVariable(StateVariable, default=0.0),
            "F_in" => ModelVariable(ParameterVariable, units="1"),
        )
        sink = Model(sink_vars, [Equation(_deriv("u"), _V("F_in"))])
        src_vars = Dict{String, ModelVariable}(
            "F" => ModelVariable(ObservedVariable, units="1", expression=_N(4.0)),
        )
        src = Model(src_vars, Equation[])
        # Bogus transform: never references Src.F.
        transform = _op("*", _N(2.0), _V("Sink.u"))
        file = EarthSciSerialization.EsmFile("0.8.0",
            EarthSciSerialization.Metadata("t7c"),
            models=Dict("Sink" => sink, "Src" => src),
            coupling=CouplingEntry[CouplingVariableMap("Src.F", "Sink.F_in", transform)])
        @test_throws ArgumentError flatten(file)
    end

    @testset "7d. expression transform takes no factor" begin
        transform = _op("*", _N(2.0), _V("Src.F"))
        @test_throws ArgumentError CouplingVariableMap(
            "Src.F", "Sink.F_in", transform; factor=3.0)
    end

    @testset "8. couple with connector equations" begin
        v1 = Dict{String, ModelVariable}("x" => ModelVariable(StateVariable))
        m1 = Model(v1, Equation[Equation(_deriv("x"), _V("x"))])
        v2 = Dict{String, ModelVariable}("y" => ModelVariable(StateVariable))
        m2 = Model(v2, Equation[Equation(_deriv("y"), _V("y"))])

        # Connector equation structured as an already-parsed Equation object.
        connector_eq = Equation(_V("A.x"), _V("B.y"))
        connector = Dict{String, Any}("equations" => [connector_eq])

        coupling = CouplingEntry[CouplingCouple(["A", "B"], connector)]
        file = EarthSciSerialization.EsmFile("0.1.0",
            EarthSciSerialization.Metadata("t8"),
            models=Dict("A" => m1, "B" => m2),
            coupling=coupling)
        flat = flatten(file)

        # The connector equation should appear in the flattened equations.
        found_connector = any(flat.equations) do eq
            eq.lhs isa EarthSciSerialization.VarExpr && eq.lhs.name == "A.x" &&
            eq.rhs isa EarthSciSerialization.VarExpr && eq.rhs.name == "B.y"
        end
        @test found_connector
    end

    @testset "9. Nested subsystems produce full dot paths" begin
        inner_v = Dict{String, ModelVariable}("v" => ModelVariable(StateVariable))
        inner = Model(inner_v, Equation[])
        outer_v = Dict{String, ModelVariable}("u" => ModelVariable(StateVariable))
        outer = Model(outer_v, Equation[],
            subsystems=Dict{String, Model}("Child" => inner))

        file = EarthSciSerialization.EsmFile("0.1.0",
            EarthSciSerialization.Metadata("t9"),
            models=Dict("Parent" => outer))
        flat = flatten(file)

        @test haskey(flat.state_variables, "Parent.u")
        @test haskey(flat.state_variables, "Parent.Child.v")
    end

    @testset "9b. Subsystem-scoped refs in parent expressions get prefixed (esm-v3x)" begin
        # Parent observed variable references `Sub.x` where `Sub` is a local
        # subsystem. Flattening must rewrite the dotted name to
        # `<parent_prefix>.Sub.x`, not leave it as `Sub.x` (which would fail
        # to resolve against the flat dictionary).
        sub_vars = Dict{String, ModelVariable}(
            "x" => ModelVariable(StateVariable; default=1.0))
        sub = Model(sub_vars, Equation[])

        parent_vars = Dict{String, ModelVariable}(
            "y" => ModelVariable(ObservedVariable;
                expression=_V("Sub.x")))
        parent = Model(parent_vars, Equation[],
            subsystems=Dict{String, Model}("Sub" => sub))

        file = EarthSciSerialization.EsmFile("0.1.0",
            EarthSciSerialization.Metadata("t9b"),
            models=Dict("Parent" => parent))
        flat = flatten(file)

        eq = _find_eq(flat, "Parent.y")
        @test eq !== nothing
        @test _uses_var(eq.rhs, "Parent.Sub.x")
        @test !_uses_var(eq.rhs, "Sub.x")
    end

    @testset "14. §4.7.6 DomainUnitMismatchError from real variable_map flatten" begin
        # A variable_map with transform="identity" between two variables
        # carrying DIFFERENT declared units MUST raise DomainUnitMismatchError.
        vars_a = Dict{String, ModelVariable}(
            "T" => ModelVariable(StateVariable; units="K"),
        )
        m_a = Model(vars_a, Equation[Equation(_deriv("T"), _V("T"))])
        vars_b = Dict{String, ModelVariable}(
            "T" => ModelVariable(ParameterVariable; units="degC"),
        )
        m_b = Model(vars_b, Equation[])
        coupling = CouplingEntry[
            CouplingVariableMap("A.T", "B.T", "identity"),
        ]
        file = EarthSciSerialization.EsmFile("0.1.0",
            EarthSciSerialization.Metadata("t14_units"),
            models=Dict("A" => m_a, "B" => m_b),
            coupling=coupling)
        err = try
            flatten(file); nothing
        catch e
            e
        end
        @test err isa DomainUnitMismatchError
        @test err.variable == "A.T"
        @test err.source_units == "K"
        @test err.target_units == "degC"
        @test occursin("K", sprint(showerror, err))
        @test occursin("degC", sprint(showerror, err))
    end

    @testset "15. No @eval or __precompile__(false) in flatten.jl" begin
        flatten_src = read(joinpath(@__DIR__, "..", "src", "flatten.jl"), String)
        @test !occursin("@eval", flatten_src)
        @test !occursin("__precompile__(false)", flatten_src)
    end

    @testset "flatten(::Model) convenience" begin
        vars = Dict{String, ModelVariable}("x" => ModelVariable(StateVariable))
        eqs = [Equation(_deriv("x"), _V("x"))]
        m = Model(vars, eqs)
        flat = flatten(m)
        @test flat isa FlattenedSystem
        @test haskey(flat.state_variables, "anonymous.x")
    end

    @testset "lower_reactions_to_equations helper" begin
        species = [EarthSciSerialization.Species("A"),
                   EarthSciSerialization.Species("B")]
        rxns = [EarthSciSerialization.Reaction("r1",
            [EarthSciSerialization.StoichiometryEntry("A", 1)],
            [EarthSciSerialization.StoichiometryEntry("B", 1)],
            _V("k"))]
        eqs = lower_reactions_to_equations(rxns, species)
        @test length(eqs) == 2
        # Every equation is a D(species, t) = ... form.
        for eq in eqs
            @test eq.lhs isa EarthSciSerialization.OpExpr
            @test eq.lhs.op == "D"
        end
    end

    @testset "FlattenedSystem metadata provenance" begin
        v1 = Dict{String, ModelVariable}("x" => ModelVariable(StateVariable))
        m1 = Model(v1, Equation[])
        v2 = Dict{String, ModelVariable}("y" => ModelVariable(StateVariable))
        m2 = Model(v2, Equation[])
        coupling = CouplingEntry[
            CouplingOperatorApply("my_op"),
            CouplingCallback("cb1"),
        ]
        file = EarthSciSerialization.EsmFile("0.1.0",
            EarthSciSerialization.Metadata("mdata"),
            models=Dict("A" => m1, "B" => m2),
            coupling=coupling)
        flat = flatten(file)
        @test "A" in flat.metadata.source_systems
        @test "B" in flat.metadata.source_systems
        @test length(flat.metadata.coupling_rules_applied) == 2
        @test "operator_apply:my_op" in flat.metadata.opaque_coupling_refs
        @test "callback:cb1" in flat.metadata.opaque_coupling_refs
    end

    @testset "couple: unparsed dict connector equation goes to opaque refs" begin
        v1 = Dict{String, ModelVariable}("x" => ModelVariable(StateVariable))
        m1 = Model(v1, Equation[Equation(_deriv("x"), _V("x"))])
        v2 = Dict{String, ModelVariable}("y" => ModelVariable(StateVariable))
        m2 = Model(v2, Equation[Equation(_deriv("y"), _V("y"))])
        # Dict-shaped connector equation whose lhs/rhs are NOT parsed Exprs.
        connector = Dict{String, Any}("equations" =>
            Any[Dict{String, Any}("lhs" => "A.x", "rhs" => "B.y")])
        coupling = CouplingEntry[CouplingCouple(["A", "B"], connector)]
        file = EarthSciSerialization.EsmFile("0.8.0",
            EarthSciSerialization.Metadata("t8b"),
            models=Dict("A" => m1, "B" => m2),
            coupling=coupling)
        flat = flatten(file)
        # No bogus `__coupling_placeholder__ = 0.0` equation is fabricated...
        @test !any(eq -> eq.lhs isa EarthSciSerialization.VarExpr &&
                         eq.lhs.name == "__coupling_placeholder__", flat.equations)
        # ...the skipped entry is visible on the opaque-coupling channel instead.
        @test any(r -> occursin("unparsed_connector_equation", r),
                  flat.metadata.opaque_coupling_refs)
    end

    @testset "placeholder substitution preserves non-args fields (regression)" begin
        E = EarthSciSerialization
        # A `_var` template whose RHS carries a table_lookup (table/table_axes)
        # and an aggregate with filter/bounds — fields the old hand-listed
        # rebuild dropped and never recursed into.
        tl = E.OpExpr("table_lookup", E.Expr[]; table="fuel", output=1,
            table_axes=Dict{String,E.Expr}("code" => _V("_var")))
        agg = E.OpExpr("aggregate", E.Expr[];
            output_idx=Any[],
            ranges=Dict{String,Any}("i" => E.IndexSetRef("cells")),
            expr_body=_op("*", _V("_var"), _V("w")),
            filter=_op(">", _V("_var"), _N(0.0)),
            lower=_V("_var"), upper=_N(1.0))
        tmpl = _op("+", tl, agg)
        out = E._substitute_placeholder(tmpl, "_var", "Chem.O3")
        otl, oagg = out.args[1], out.args[2]
        # table/table_axes survive AND the axis input was substituted.
        @test otl.table == "fuel" && otl.output == 1
        @test otl.table_axes["code"] == _V("Chem.O3")
        # filter / bounds / body recursed; ranges preserved.
        @test _uses_var(oagg.expr_body, "Chem.O3")
        @test _uses_var(oagg.filter, "Chem.O3")
        @test oagg.lower == _V("Chem.O3")
        @test oagg.ranges["i"] isa E.IndexSetRef
    end

    @testset "flatten preserves DiscreteEvent.functional_affect (regression)" begin
        E = EarthSciSerialization
        fa = Dict{String,Any}("handler" => "reset", "args" => Any["x"])
        ev = DiscreteEvent(
            PeriodicTrigger(1.0),
            [FunctionalAffect("x", _N(0.0))];
            description="periodic reset", functional_affect=fa)
        vars = Dict{String, ModelVariable}("x" => ModelVariable(StateVariable, default=1.0))
        model = Model(vars, [Equation(_deriv("x"), _V("x"))]; discrete_events=[ev])
        flat = flatten(model; name="M")
        @test length(flat.discrete_events) == 1
        @test flat.discrete_events[1].functional_affect == fa
        @test flat.discrete_events[1].description == "periodic reset"
    end

    @testset "current-format version defaults (ESM_FORMAT_VERSION)" begin
        E = EarthSciSerialization
        vars = Dict{String, ModelVariable}("x" => ModelVariable(StateVariable, default=1.0))
        model = Model(vars, [Equation(_deriv("x"), _V("x"))])
        flat = flatten(model; name="V")
        @test flat isa FlattenedSystem
        doc = E.flattened_to_esm(flat)
        @test doc["esm"] == E.ESM_FORMAT_VERSION
        @test E.ESM_FORMAT_VERSION == "0.8.0"
    end

    @testset "Flatten valid fixtures smoke test" begin
        # Every shared valid fixture must load and flatten cleanly (verified:
        # none currently throws, so failures here are genuine regressions and
        # propagate with their full stack trace).
        valid_fixtures_dir = joinpath(TESTUTILS_REPO_ROOT, "tests", "valid")
        @test isdir(valid_fixtures_dir)
        for filename in filter(f -> endswith(f, ".esm"), readdir(valid_fixtures_dir))
            filepath = joinpath(valid_fixtures_dir, filename)
            @testset "Flatten fixture: $filename" begin
                esm_data = EarthSciSerialization.load(filepath)
                flat = flatten(esm_data)
                @test flat isa FlattenedSystem
            end
        end
    end
end
