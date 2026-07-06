"""
Tests for graph analysis functionality (src/graph.jl):
component-level and expression-level graphs, chemical formula rendering,
and Mermaid/DOT/JSON export sanitization.
"""

using Test
using EarthSciSerialization

const ESSG = EarthSciSerialization

_graph_model() = Model(
    Dict(
        "x" => ModelVariable(StateVariable, default=1.0),
        "k" => ModelVariable(ParameterVariable, default=0.5),
    ),
    [Equation(
        OpExpr("D", ESSG.Expr[VarExpr("x")], wrt="t"),
        OpExpr("*", ESSG.Expr[VarExpr("k"), VarExpr("x")]),
    )],
)

_graph_rsys() = ReactionSystem(
    [Species("NO2"), Species("O3")],
    [Reaction("r1",
              [ESSG.StoichiometryEntry("NO2", 1)],
              [ESSG.StoichiometryEntry("O3", 1)],
              VarExpr("kr"))],
)

@testset "Graph analysis" begin
    metadata = Metadata("graph-test")

    @testset "expression_graph handles model-only files" begin
        # reaction_systems === nothing must not throw
        file = EsmFile("0.1.0", metadata, models=Dict("M" => _graph_model()))
        g = expression_graph(file)
        @test any(n -> n.name == "M.x", g.nodes)
        @test any(n -> n.name == "M.k", g.nodes)
    end

    @testset "expression_graph handles reaction-only files" begin
        # models === nothing must not throw
        file = EsmFile("0.1.0", metadata, reaction_systems=Dict("R" => _graph_rsys()))
        g = expression_graph(file)
        @test any(n -> n.name == "R.NO2", g.nodes)
        @test any(n -> n.name == "R.O3", g.nodes)
    end

    @testset "variable_map coupling edge description interpolates" begin
        file = EsmFile("0.1.0", metadata,
                       models=Dict("M" => _graph_model(), "N" => _graph_model()),
                       coupling=CouplingEntry[CouplingVariableMap("M.x", "N.x", "identity")])
        g = component_graph(file)
        @test length(g.edges) == 1
        desc = g.edges[1].data.description
        @test desc == "Variable mapping: M.x -> N.x"
        @test !occursin("\$(coupling.from)", desc)
    end

    @testset "render_chemical_formula delegates to element-aware formatter" begin
        @test render_chemical_formula("CO2") == "CO₂"
        @test render_chemical_formula("H2SO4") == "H₂SO₄"
        @test render_chemical_formula("CH3OH") == "CH₃OH"
        # Element-aware: digits after a non-element are untouched
        @test render_chemical_formula("x2") == "x2"
        # Graph rendering and display rendering agree
        @test render_chemical_formula("CO2") ==
              ESSG.format_chemical_subscripts("CO2", :unicode)
        # 1-arg format_node_label
        @test format_node_label("CO2") == "CO₂"
        @test format_node_label("temp") == "temp"
    end

    @testset "to_mermaid sanitizes dotted ids and quotes labels" begin
        file = EsmFile("0.1.0", metadata,
                       models=Dict("M" => _graph_model()),
                       reaction_systems=Dict("R" => _graph_rsys()))
        g = expression_graph(file)  # node names are scoped: "M.x", "R.NO2", ...
        mmd = to_mermaid(g)
        # ids: dots replaced with underscores; labels: original names, quoted
        @test occursin("M_x((\"M.x\"))", mmd)
        @test occursin("M_k[\"M.k\"]", mmd)
        @test occursin("M_k --> M_x", mmd)
        # node ids (the token before the shape bracket) never contain dots
        for line in split(mmd, "\n")[2:end]  # skip "graph TD"
            occursin(r"[\[({]", line) || continue  # edge lines have no shape
            id_part = split(strip(line), r"[\[({]")[1]
            @test !occursin(".", id_part)
        end
    end

    @testset "to_dot escapes quotes in ids and labels" begin
        @test ESSG._dot_escape("a\"b") == "a\\\"b"
        @test ESSG._dot_escape("a\\b") == "a\\\\b"
        @test ESSG._mermaid_id("model.x") == "model_x"
        @test ESSG._mermaid_label("say \"hi\"") == "say #quot;hi#quot;"

        file = EsmFile("0.1.0", metadata, models=Dict("M" => _graph_model()))
        dot = to_dot(expression_graph(file))
        @test startswith(dot, "digraph ExpressionGraph {")
        @test occursin("\"M.x\"", dot)
    end

    @testset "to_json dispatches per graph type" begin
        file = EsmFile("0.1.0", metadata,
                       models=Dict("M" => _graph_model()),
                       coupling=CouplingEntry[CouplingOperatorCompose(["M", "M"])])
        cg_json = to_json(component_graph(file))
        @test occursin("\"nodes\"", cg_json)
        @test occursin("\"adjacency\"", cg_json)
        eg_json = to_json(expression_graph(file))
        @test occursin("\"kind\"", eg_json)
    end

    @testset "component_graph handles reaction-only files" begin
        file = EsmFile("0.1.0", metadata, reaction_systems=Dict("R" => _graph_rsys()))
        g = component_graph(file)
        @test length(g.nodes) == 1
        @test g.nodes[1].type == "reaction_system"
        @test g.nodes[1].metadata["species_count"] == 2
    end
end
