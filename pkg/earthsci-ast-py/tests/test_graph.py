"""Graph-representation tests for the Python binding (esm-libraries-spec §4.8).

Cross-binding agreement is asserted by ``test_graph_conformance.py``, which
drives the shared corpus at ``tests/conformance/graph/cases.json``. This file
keeps the Python-local assertions: the DATA MODEL invariants that read clearly
as prose (a data source is not a node, file-level names are scoped, rate edges
reach every species) and the exporters' structure.

The exporters are asserted STRUCTURALLY — headers, one node line, one edge line
— and not against a golden. §4.8.3 requires DOT and Mermaid but specifies
neither, and the five bindings do not agree on either format's bytes; see
``tests/conformance/graph/README.md``.
"""

from __future__ import annotations

import json

import pytest
from conftest import FIXTURES_ROOT, VALID_DIR

import earthsci_ast as esm
from earthsci_ast.esm_types import (
    Equation,
    ExprNode,
    Model,
    ModelVariable,
    Parameter,
    Reaction,
    ReactionSystem,
    Species,
)
from earthsci_ast.graph import (
    EXPR_RESULT,
    NON_EQUATION_INDEX,
    ComponentNode,
    CouplingEdge,
    DependencyEdge,
    Graph,
    VariableNode,
    component_exists,
    component_graph,
    component_type,
    expression_graph,
    to_dot,
    to_json,
    to_mermaid,
)

#: The document the graph corpus uses for the reaction-system cases.
CHEMISTRY_FIXTURE = VALID_DIR / "minimal_chemistry.esm"


@pytest.fixture
def chemistry_file():
    return esm.load_string(CHEMISTRY_FIXTURE.read_text())


@pytest.fixture
def coupled_file():
    return esm.load_string((VALID_DIR / "full_coupled.esm").read_text())


@pytest.fixture
def variable_map_file():
    return esm.load_string((VALID_DIR / "coupling_variable_map_identity_units_match.esm").read_text())


# ---------------------------------------------------------------------------
# Component graph
# ---------------------------------------------------------------------------


class TestComponentGraph:
    def test_nodes_are_models_and_reaction_systems(self, chemistry_file):
        graph = component_graph(chemistry_file)
        assert graph.node_type is ComponentNode
        by_id = {node.id: node for node in graph.nodes}
        assert by_id["Advection"].type == "model"
        assert by_id["SimpleOzone"].type == "reaction_system"

    def test_data_source_is_not_a_node(self, chemistry_file):
        """From esm 1.0.0 a data source is an ingest registry, not a component.

        ``minimal_chemistry.esm`` declares a ``GEOSFP`` data source.
        esm-libraries-spec §4.8.1 is explicit: "A ``data_sources`` entry is not
        a component and is NOT a node" (see also esm-spec §5.5 / §8.5).
        """
        assert "GEOSFP" in chemistry_file.data_sources
        graph = component_graph(chemistry_file)
        assert "GEOSFP" not in {node.id for node in graph.nodes}

    def test_node_metadata_counts(self, chemistry_file):
        graph = component_graph(chemistry_file)
        by_id = {node.id: node for node in graph.nodes}
        assert by_id["Advection"].metadata["var_count"] == len(
            chemistry_file.models["Advection"].variables
        )
        assert by_id["Advection"].metadata["eq_count"] == len(
            chemistry_file.models["Advection"].equations
        )
        rxn_sys = chemistry_file.reaction_systems["SimpleOzone"]
        assert by_id["SimpleOzone"].metadata["species_count"] == len(rxn_sys.species)
        assert by_id["SimpleOzone"].metadata["eq_count"] == len(rxn_sys.reactions)

    def test_operator_compose_edge(self, chemistry_file):
        """One directed ``systems[0] -> systems[1]`` edge, as in every binding."""
        graph = component_graph(chemistry_file)
        assert len(graph.edges) == 1
        edge = graph.edges[0]
        assert (edge.source, edge.target) == ("SimpleOzone", "Advection")
        assert edge.data.type == "operator_compose"
        assert edge.data.label == "compose"
        assert edge.data.id == "coupling-0"

    def test_variable_map_edge_carries_the_source_variable(self, variable_map_file):
        graph = component_graph(variable_map_file)
        edge = next(e for e in graph.edges if e.data.type == "variable_map")
        assert (edge.data.from_component, edge.data.to_component) == (
            "SystemA",
            "SystemB",
        )
        assert edge.data.label == "temperature"

    def test_dangling_endpoint_contributes_no_edge(self, chemistry_file):
        """An endpoint that is not a declared node is skipped, never fabricated."""
        from earthsci_ast.esm_types import OperatorComposeCoupling

        chemistry_file.coupling.append(
            OperatorComposeCoupling(systems=["SimpleOzone", "NoSuchSystem"])
        )
        graph = component_graph(chemistry_file)
        assert all("NoSuchSystem" not in (e.source, e.target) for e in graph.edges)

    def test_operator_apply_contributes_no_edge(self, chemistry_file):
        """`operator_apply` names no two concrete components (all bindings)."""
        from earthsci_ast.esm_types import OperatorApplyCoupling

        before = len(component_graph(chemistry_file).edges)
        chemistry_file.coupling.append(OperatorApplyCoupling(operator="advect"))
        assert len(component_graph(chemistry_file).edges) == before

    def test_component_type_and_exists(self, chemistry_file):
        assert component_type(chemistry_file, "Advection") == "model"
        assert component_type(chemistry_file, "SimpleOzone") == "reaction_system"
        # A data source is not a component, so it has no component type.
        assert component_type(chemistry_file, "GEOSFP") is None
        assert component_type(chemistry_file, "nope") is None
        assert component_exists(chemistry_file, "Advection")
        assert not component_exists(chemistry_file, "nope")


# ---------------------------------------------------------------------------
# Expression graph
# ---------------------------------------------------------------------------


class TestExpressionGraph:
    def test_species_and_parameters_carry_declared_kind_and_units(self, chemistry_file):
        """Every declared species and parameter reaches the graph intact.

        This used to compare against ``tests/graphs/expression_graph.json``,
        which was removed: it recorded a pre-1.0.0 node model (``var_``-prefixed
        ids and a ``rate_R1`` node per reaction) that no binding ever produced.
        The document's own declarations are the better source for the same
        property, and the cross-binding form of it lives in the corpus.
        """
        system = "SimpleOzone"
        rxn_sys = chemistry_file.reaction_systems[system]
        graph = expression_graph(chemistry_file)
        by_name = {node.name: node for node in graph.nodes}

        for species in rxn_sys.species:
            scoped = f"{system}.{species.name}"
            assert scoped in by_name, f"{scoped} missing from the expression graph"
            assert by_name[scoped].kind == "species"
            assert by_name[scoped].units == species.units
            assert by_name[scoped].system == system

        for parameter in rxn_sys.parameters:
            scoped = f"{system}.{parameter.name}"
            assert scoped in by_name, f"{scoped} missing from the expression graph"
            assert by_name[scoped].kind == "parameter"
            assert by_name[scoped].units == parameter.units
            assert by_name[scoped].system == system

    def test_file_level_names_are_scoped(self, chemistry_file):
        graph = expression_graph(chemistry_file)
        assert graph.node_type is VariableNode
        assert all(node.name.startswith(f"{node.system}.") for node in graph.nodes)

    def test_reaction_rate_and_stoichiometric_edges(self, chemistry_file):
        """Rate variables reach every species; reactants reach every product."""
        graph = expression_graph(chemistry_file)
        rate = {
            (e.data.source, e.data.target) for e in graph.edges if e.data.relationship == "rate"
        }
        stoich = {
            (e.data.source, e.data.target)
            for e in graph.edges
            if e.data.relationship == "stoichiometric"
        }
        # R1: NO + O3 -> NO2 with a T- and M-dependent rate.
        assert ("SimpleOzone.T", "SimpleOzone.NO2") in rate
        assert ("SimpleOzone.M", "SimpleOzone.O3") in rate
        assert ("SimpleOzone.NO", "SimpleOzone.NO2") in stoich
        assert ("SimpleOzone.O3", "SimpleOzone.NO2") in stoich
        # R2: NO2 -> NO + O3, photolysed at jNO2.
        assert ("SimpleOzone.jNO2", "SimpleOzone.NO") in rate
        assert ("SimpleOzone.NO2", "SimpleOzone.O3") in stoich

    def test_edges_carry_the_producing_reaction_index(self, chemistry_file):
        graph = expression_graph(chemistry_file)
        indices = {
            e.data.equation_index for e in graph.edges if e.data.source.startswith("SimpleOzone.")
        }
        assert indices == {0, 1}

    def test_stoichiometric_edge_carries_no_expression(self, chemistry_file):
        """The rate is not what relates a reactant to a product (Rust, Go)."""
        graph = expression_graph(chemistry_file)
        stoich = [e for e in graph.edges if e.data.relationship == "stoichiometric"]
        assert stoich
        assert all(e.data.expression is None for e in stoich)

    def test_equation_edges_run_rhs_to_lhs(self):
        model = Model(
            name="M",
            variables={
                "x": ModelVariable(type="unknown"),
                "k": ModelVariable(type="parameter", default=1.0),
            },
            equations=[
                Equation(
                    lhs=ExprNode(op="D", args=["x"]),
                    rhs=ExprNode(op="*", args=["k", "x"]),
                )
            ],
        )
        graph = expression_graph(model)
        assert {node.name for node in graph.nodes} == {"x", "k"}
        assert {n.name: n.kind for n in graph.nodes}["x"] == "state"
        pairs = {(e.data.source, e.data.target) for e in graph.edges}
        # `D(x)/dt = k*x` — the LHS target is `x`, under the derivative wrapper,
        # and the self-reference IS a real dependency (Rust, TypeScript).
        assert pairs == {("k", "x"), ("x", "x")}
        assert all(e.data.relationship == "additive" for e in graph.edges)

    def test_undeclared_equation_variable_is_fabricated(self):
        """Rust and TypeScript both add a node rather than drop the edge."""
        model = Model(
            name="M",
            variables={"x": ModelVariable(type="unknown")},
            equations=[Equation(lhs="x", rhs=ExprNode(op="+", args=["x", "ghost"]))],
        )
        graph = expression_graph(model)
        assert "ghost" in {node.name for node in graph.nodes}
        assert ("ghost", "x") in {(e.data.source, e.data.target) for e in graph.edges}

    def test_bare_model_names_are_unscoped(self, chemistry_file):
        model = chemistry_file.models["Advection"]
        graph = expression_graph(model)
        assert all("." not in node.name for node in graph.nodes)
        assert all(node.system == "default" for node in graph.nodes)

    def test_standalone_equation(self):
        equation = Equation(lhs="y", rhs=ExprNode(op="+", args=["a", "b"]))
        graph = expression_graph(equation)
        assert {node.name for node in graph.nodes} == {"y", "a", "b"}
        assert {(e.data.source, e.data.target) for e in graph.edges} == {
            ("a", "y"),
            ("b", "y"),
        }
        assert all(e.data.equation_index == 0 for e in graph.edges)

    def test_standalone_reaction(self):
        reaction = Reaction(
            name="R1",
            reactants={"NO": 1, "O3": 1},
            products={"NO2": 1},
            rate_constant="k1",
        )
        graph = expression_graph(reaction)
        by_name = {node.name: node for node in graph.nodes}
        assert by_name["k1"].kind == "parameter"
        assert by_name["NO"].kind == "species"
        rate = {
            (e.data.source, e.data.target) for e in graph.edges if e.data.relationship == "rate"
        }
        assert rate == {("k1", "NO"), ("k1", "O3"), ("k1", "NO2")}
        stoich = {
            (e.data.source, e.data.target)
            for e in graph.edges
            if e.data.relationship == "stoichiometric"
        }
        assert stoich == {("NO", "NO2"), ("O3", "NO2")}

    def test_standalone_reaction_system(self):
        rxn_sys = ReactionSystem(
            name="S",
            species=[Species(name="A", units="mol/mol")],
            parameters=[Parameter(name="k", value=1.0, units="1/s")],
            reactions=[Reaction(name="R", reactants={"A": 1}, products={})],
        )
        graph = expression_graph(rxn_sys)
        by_name = {node.name: node for node in graph.nodes}
        assert by_name["A"].kind == "species" and by_name["A"].units == "mol/mol"
        assert by_name["k"].kind == "parameter" and by_name["k"].units == "1/s"

    def test_standalone_expression_feeds_a_synthetic_result_node(self):
        """§4.8.2 requires the Expr overload to produce EDGES, not just nodes.

        "every variable in the expression becomes a node, and the tree structure
        is flattened into dependency edges" — so the expression's value gets a
        synthetic ``expr_result`` target and every free variable feeds it. This
        module used to return nodes only.
        """
        graph = expression_graph(ExprNode(op="*", args=["a", ExprNode(op="+", args=["b", 2])]))
        assert {node.name for node in graph.nodes} == {"a", "b", EXPR_RESULT}
        assert {(e.data.source, e.data.target) for e in graph.edges} == {
            ("a", EXPR_RESULT),
            ("b", EXPR_RESULT),
        }

    def test_merge_coupled_is_off_by_default(self, variable_map_file):
        default = expression_graph(variable_map_file)
        merged = expression_graph(variable_map_file, merge_coupled=True)
        assert len(merged.edges) > len(default.edges)
        cross = [e for e in merged.edges if e.data.equation_index == NON_EQUATION_INDEX]
        assert ("SystemA.temperature", "SystemB.temperature") in {
            (e.data.source, e.data.target) for e in cross
        }

    def test_derived_kinds_never_read_a_declared_type(self, coupled_file):
        """esm 1.0.0 declares only ``unknown`` / ``parameter`` (§6.3.1)."""
        graph = expression_graph(coupled_file)
        kinds = {node.kind for node in graph.nodes}
        assert kinds <= {
            "state",
            "algebraic",
            "observed",
            "parameter",
            "brownian",
            "discrete",
            "species",
        }
        assert "unknown" not in kinds

    def test_unresolved_ref_component_contributes_no_variables(self, chemistry_file):
        """A `{"ref": ...}` stub is a component NODE but has no variables.

        `resolve_model_refs` / `resolve_subsystem_refs` splice these in later;
        until then there is nothing to walk. TypeScript skips reference stubs
        the same way.
        """
        chemistry_file.models["Included"] = {"ref": "other.esm"}
        component = component_graph(chemistry_file)
        included = next(n for n in component.nodes if n.id == "Included")
        assert included.metadata == {"var_count": 0, "eq_count": 0, "species_count": 0}
        graph = expression_graph(chemistry_file)
        assert all(node.system != "Included" for node in graph.nodes)

    def test_inline_subsystem_variables_are_scoped(self):
        child = Model(name="Child", variables={"c": ModelVariable(type="parameter")})
        parent = Model(
            name="Parent",
            variables={"p": ModelVariable(type="parameter")},
            subsystems={"Child": child},
        )
        graph = expression_graph(parent)
        assert {node.name for node in graph.nodes} == {"p", "Child.c"}


# ---------------------------------------------------------------------------
# Graph lookups
# ---------------------------------------------------------------------------


class TestGraphLookups:
    def test_adjacency_predecessors_successors(self, chemistry_file):
        graph = component_graph(chemistry_file)
        assert graph.successors("SimpleOzone") == ["Advection"]
        assert graph.predecessors("Advection") == ["SimpleOzone"]
        assert graph.adjacency("SimpleOzone") == ["Advection"]
        assert graph.adjacency("Advection") == ["SimpleOzone"]

    def test_unknown_and_unconnected_keys_return_empty_lists(self):
        graph = Graph(
            nodes=[ComponentNode(id="lonely", name="lonely", type="model")],
            edges=[],
            node_type=ComponentNode,
        )
        assert graph.adjacency("lonely") == []
        assert graph.predecessors("lonely") == []
        assert graph.successors("nope") == []


# ---------------------------------------------------------------------------
# Exporters
# ---------------------------------------------------------------------------


class TestExports:
    def test_component_dot(self, chemistry_file):
        dot = to_dot(component_graph(chemistry_file))
        assert dot.startswith("digraph ComponentGraph {")
        assert dot.endswith("}")
        assert '"Advection" [label="Advection", fillcolor=lightgreen, style=filled];' in dot
        assert '"SimpleOzone" [label="SimpleOzone", fillcolor=lightcoral, style=filled];' in dot
        assert '"SimpleOzone" -> "Advection" [label="compose", color=blue];' in dot

    def test_expression_dot(self, chemistry_file):
        dot = to_dot(expression_graph(chemistry_file))
        assert dot.startswith("digraph ExpressionGraph {")
        assert '"SimpleOzone.T" [label="SimpleOzone.T", shape=box];' in dot
        assert '"SimpleOzone.T" -> "SimpleOzone.NO2" [label="rate", style=dotted];' in dot

    def test_dot_renders_chemical_subscripts(self, chemistry_file):
        dot = to_dot(expression_graph(chemistry_file))
        assert 'label="SimpleOzone.O₃"' in dot
        # The node ID keeps the raw name; only the LABEL is formatted.
        assert '"SimpleOzone.O3" [' in dot

    def test_dot_escapes_quotes_and_backslashes(self):
        graph = Graph(
            nodes=[ComponentNode(id='a"b\\c', name='a"b\\c', type="model")],
            edges=[],
            node_type=ComponentNode,
        )
        assert '"a\\"b\\\\c"' in to_dot(graph)

    def test_component_mermaid(self, chemistry_file):
        mermaid = to_mermaid(component_graph(chemistry_file))
        lines = mermaid.splitlines()
        assert lines[0] == "graph TD"
        assert '    Advection["Advection"]' in lines
        assert '    SimpleOzone("SimpleOzone")' in lines
        assert '    SimpleOzone -->|"compose"| Advection' in lines

    def test_expression_mermaid_sanitizes_scoped_ids(self, chemistry_file):
        mermaid = to_mermaid(expression_graph(chemistry_file))
        assert mermaid.splitlines()[0] == "graph TD"
        # `SimpleOzone.T` is not a legal mermaid id, so the ID is sanitized
        # while the LABEL keeps the dotted name (as Julia does).
        assert '    SimpleOzone_T["SimpleOzone.T"]' in mermaid
        assert '    SimpleOzone_T -..->|"rate"| SimpleOzone_NO2' in mermaid

    def test_variable_map_uses_a_dotted_arrow(self, variable_map_file):
        mermaid = to_mermaid(component_graph(variable_map_file))
        assert '-.->|"temperature"|' in mermaid

    def test_component_json(self, chemistry_file):
        payload = json.loads(to_json(component_graph(chemistry_file)))
        assert set(payload) == {"nodes", "edges", "adjacency"}
        assert {node["id"] for node in payload["nodes"]} == {"Advection", "SimpleOzone"}
        edge = payload["edges"][0]
        assert edge["source"] == "SimpleOzone" and edge["target"] == "Advection"
        # The wire spellings of `from_component` / `to_component`, under `data`.
        assert edge["data"]["from"] == "SimpleOzone" and edge["data"]["to"] == "Advection"
        assert edge["data"]["type"] == "operator_compose"
        # UNDIRECTED adjacency, matching `Graph.adjacency` (§4.8.3). This used
        # to be `successors`, so the export disagreed with the graph's own
        # lookup — caught by the shared corpus.
        assert payload["adjacency"] == {
            "Advection": ["SimpleOzone"],
            "SimpleOzone": ["Advection"],
        }

    def test_expression_json(self, chemistry_file):
        payload = json.loads(to_json(expression_graph(chemistry_file)))
        assert set(payload) == {"nodes", "edges", "adjacency"}
        by_name = {node["name"]: node for node in payload["nodes"]}
        assert by_name["SimpleOzone.O3"]["kind"] == "species"
        assert by_name["SimpleOzone.O3"]["system"] == "SimpleOzone"
        assert "SimpleOzone.NO2" in payload["adjacency"]["SimpleOzone.O3"]

    def test_empty_graph_still_dispatches(self):
        """`node_type` is recorded, so an empty graph renders as its own kind."""
        assert to_dot(Graph(node_type=ComponentNode)) == "digraph ComponentGraph {\n}"
        assert to_dot(Graph(node_type=VariableNode)) == "digraph ExpressionGraph {\n}"
        assert to_mermaid(Graph(node_type=VariableNode)) == "graph TD"
        assert json.loads(to_json(Graph(node_type=VariableNode))) == {
            "nodes": [],
            "edges": [],
            "adjacency": {},
        }


def test_exported_from_the_package():
    """Every graph name is on the package surface and in ``__all__``."""
    for name in (
        "Graph",
        "GraphEdge",
        "ComponentNode",
        "CouplingEdge",
        "VariableNode",
        "DependencyEdge",
        "component_graph",
        "expression_graph",
        "component_exists",
        "component_type",
        "to_dot",
        "to_mermaid",
        "to_json",
    ):
        assert name in esm.__all__, f"{name} missing from __all__"
        assert hasattr(esm, name)
    assert esm.CouplingEdge is CouplingEdge
    assert esm.DependencyEdge is DependencyEdge
