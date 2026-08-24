"""Graph representations of ESM documents (esm-libraries-spec §4.8).

Two graphs are offered, matching the other bindings:

* :func:`component_graph` — the COMPONENT graph. Nodes are models and reaction
  systems; edges are the coupling entries that name two of them.
* :func:`expression_graph` — the VARIABLE-dependency graph. Nodes are
  variables / parameters / species; edges are the dependencies read off
  equations, reactions and (optionally) ``variable_map`` coupling.

Both are exported to Graphviz DOT, Mermaid and JSON by :func:`to_dot`,
:func:`to_mermaid` and :func:`to_json`.

Where the bindings disagree
---------------------------
The four existing implementations (Julia ``src/graph.jl``, Rust
``src/graph.rs``, TypeScript ``src/graph.ts``, Go ``pkg/esm/graph.go`` +
``graph_export.go``) agree on the DATA MODEL — node/edge field names, the
coupling kinds that produce an edge, the ``additive`` / ``rate`` /
``stoichiometric`` relationship vocabulary — but NOT on the exact bytes their
exporters emit, and the shared ``tests/graphs/`` fixtures do not pin any
binding's rendered output (they are hand-authored illustrations; Rust's
``graph_structure.rs`` only checks that the DOT it produced contains
``digraph``). This module therefore follows, item by item, whatever the
majority of the four does, and where they split 2-2 it follows Julia — the
binding whose public surface (``component_graph`` / ``expression_graph`` /
``to_dot`` / ``to_mermaid`` / ``to_json``) is spelled exactly like this one.
The individual choices are noted at each site.

A ``data_sources`` entry contributes NO node. From esm 1.0.0 a source is a
document-scoped ingest registry rather than a component: it declares no
variables and cannot be a coupling endpoint, so a model reaches it through a
PARAMETER whose ``update`` names it, and that parameter is already a node
(esm-spec §5.5 / §8.5). TypeScript and Go both dropped the node for that
reason; Rust and Julia still emit one, which this module does not follow.
"""

from __future__ import annotations

import json
import re
from collections.abc import Iterable
from dataclasses import dataclass, field
from typing import Any, Generic, TypeVar

from .classification import (
    algebraic_unknowns,
    brownian_parameters,
    constant_parameters,
    discrete_parameters,
    observed_unknowns,
    ode_states,
    sampled_parameters,
)
from .display import _format_chemical_subscripts
from .esm_types import (
    CallbackCoupling,
    CouplingCouple,
    CouplingImport,
    Equation,
    EsmFile,
    EventCoupling,
    Expr,
    ExprNode,
    Model,
    OperatorApplyCoupling,
    OperatorComposeCoupling,
    Reaction,
    ReactionSystem,
    Reference,
    VariableMapCoupling,
)
from .expr_walk import iter_children

__all__ = [
    "EXPR_RESULT",
    "NON_EQUATION_INDEX",
    "ComponentNode",
    "CouplingEdge",
    "DependencyEdge",
    "Graph",
    "GraphEdge",
    "VariableNode",
    "component_exists",
    "component_graph",
    "component_type",
    "expression_graph",
    "to_dot",
    "to_json",
    "to_mermaid",
]


# ---------------------------------------------------------------------------
# 1. Graph data structures
# ---------------------------------------------------------------------------

N = TypeVar("N")
E = TypeVar("E")

#: ``system`` value used for a bare ``Model`` / ``ReactionSystem`` / ``Equation``
#: / ``Reaction`` / expression target. Node names are NOT scoped under it, so a
#: standalone target yields bare variable names while a whole-file target yields
#: ``Component.variable`` (matching TypeScript's ``'default'`` sentinel and
#: Julia's file-level scoping).
DEFAULT_SYSTEM = "default"

#: `equation_index` for a dependency that no positionally-numbered equation or
#: reaction produced: an expression-target definition, or a coupling variable
#: map. Spelled -1 rather than None so "no positional equation" is a positive
#: statement (TypeScript's `NON_EQUATION_INDEX`).
NON_EQUATION_INDEX = -1

#: Name of the synthetic node standing for a bare expression's VALUE, so the
#: §4.8.2 expression overload has a target to draw its dependency edges to.
EXPR_RESULT = "expr_result"


@dataclass
class GraphEdge(Generic[E]):
    """One directed edge: node keys plus the edge payload.

    Mirrors the ``{source, target, data}`` triple TypeScript, Go and Julia all
    use. ``source`` / ``target`` are node KEYS (a :class:`ComponentNode`'s
    ``id``, a :class:`VariableNode`'s ``name``), not the node objects.
    """

    source: str
    target: str
    data: E


@dataclass
class ComponentNode:
    """A model or reaction system in the component graph."""

    id: str
    name: str
    #: ``"model"`` or ``"reaction_system"``. There is no ``"data_source"``
    #: member — see the module docstring.
    type: str
    description: str | None = None
    reference: Reference | None = None
    #: ``var_count`` / ``eq_count`` / ``species_count``.
    metadata: dict[str, Any] = field(default_factory=dict)


@dataclass
class CouplingEdge:
    """A coupling relationship between two components.

    ``from_component`` / ``to_component`` spell the wire keys ``from`` / ``to``,
    which are Python keywords; the package already uses this convention for
    :class:`~earthsci_ast.esm_types.VariableMapCoupling`'s ``from_var`` /
    ``to_var``. :func:`to_json` emits them under the wire spellings.
    """

    id: str
    from_component: str
    to_component: str
    #: ``"operator_compose"``, ``"couple"`` or ``"variable_map"``.
    type: str
    label: str
    description: str | None = None
    #: The originating coupling entry, kept for editing round-trips.
    coupling: Any = None


@dataclass
class VariableNode:
    """A variable, parameter or species in the expression graph."""

    #: Scoped name (``Component.variable``) for a whole-file graph; the bare
    #: name for a standalone target.
    name: str
    #: The DERIVED category (esm-spec §6.3.1), never a declared type: one of
    #: ``state``, ``algebraic``, ``observed``, ``parameter``, ``brownian``,
    #: ``discrete``, ``species``. esm 1.0.0 declares only ``unknown`` and
    #: ``parameter``, so the finer role is recovered through
    #: :mod:`earthsci_ast.classification`.
    kind: str
    units: str | None = None
    system: str = DEFAULT_SYSTEM


@dataclass
class DependencyEdge:
    """A dependency between two variables.

    ``relationship`` is a PROVENANCE label, not a claim about the arithmetic:
    an equation edge is always ``additive`` even for ``w = u * v``. The
    vocabulary (``additive`` / ``multiplicative`` / ``rate`` /
    ``stoichiometric``) is shared by every binding.
    """

    source: str
    target: str
    relationship: str
    #: Index of the equation / reaction that produced the edge; ``None`` for a
    #: dependency with no positional equation (a coupling map).
    equation_index: int | None = None
    expression: Expr | None = None


@dataclass
class Graph(Generic[N, E]):
    """A directed graph with node/edge lists and adjacency lookups (§4.8).

    Nodes are addressed by their string key; edges reference those keys. A
    lookup on a known but unconnected node returns ``[]``, and so does a lookup
    on an unknown key.
    """

    nodes: list[N] = field(default_factory=list)
    edges: list[GraphEdge[E]] = field(default_factory=list)
    #: :class:`ComponentNode` or :class:`VariableNode`. Recorded explicitly so
    #: the exporters can dispatch on an EMPTY graph too — the Python stand-in
    #: for Julia's ``Graph{ComponentNode,CouplingEdge}`` type parameters.
    node_type: type | None = None

    def __post_init__(self) -> None:
        if self.node_type is None and self.nodes:
            self.node_type = type(self.nodes[0])

    # -- lookups ----------------------------------------------------------
    def _keys(self) -> set[str]:
        return {_node_key(node) for node in self.nodes}

    def adjacency(self, node: str) -> list[str]:
        """Every neighbour of ``node``, in either direction."""
        if node not in self._keys():
            return []
        out: dict[str, None] = {}
        for edge in self.edges:
            if edge.source == node:
                out.setdefault(edge.target, None)
            if edge.target == node:
                out.setdefault(edge.source, None)
        return list(out)

    def predecessors(self, node: str) -> list[str]:
        """Nodes with an edge pointing AT ``node``."""
        if node not in self._keys():
            return []
        out: dict[str, None] = {}
        for edge in self.edges:
            if edge.target == node:
                out.setdefault(edge.source, None)
        return list(out)

    def successors(self, node: str) -> list[str]:
        """Nodes ``node`` has an edge pointing TO."""
        if node not in self._keys():
            return []
        out: dict[str, None] = {}
        for edge in self.edges:
            if edge.source == node:
                out.setdefault(edge.target, None)
        return list(out)


def _node_key(node: Any) -> str:
    """The stable string key of a graph node."""
    if isinstance(node, ComponentNode):
        return node.id
    if isinstance(node, VariableNode):
        return node.name
    return str(node)


# ---------------------------------------------------------------------------
# 2. Component graph
# ---------------------------------------------------------------------------


def component_graph(file: EsmFile) -> Graph[ComponentNode, CouplingEdge]:
    """Build the component/coupling graph of ``file``.

    Nodes are the file's models and reaction systems. Edges come from the
    coupling entries that name two DECLARED components:

    * ``operator_compose`` and ``couple`` — a single ``systems[0] →
      systems[1]`` edge (every binding records one directed edge, not a pair);
    * ``variable_map`` — an edge between the two endpoints' owning components,
      labelled with the source variable.

    ``operator_apply``, ``callback``, ``event`` and ``coupling_import`` name no
    two concrete components and contribute no edge, as in every binding. An
    endpoint that is not a declared node is skipped rather than fabricated.
    """
    nodes: list[ComponentNode] = []
    node_ids: set[str] = set()

    for model_id, model in (file.models or {}).items():
        nodes.append(
            ComponentNode(
                id=model_id,
                name=model_id,
                type="model",
                description=getattr(model, "description", None),
                reference=None,
                metadata={
                    "var_count": len(getattr(model, "variables", {}) or {}),
                    "eq_count": len(getattr(model, "equations", []) or []),
                    "species_count": 0,
                },
            )
        )
        node_ids.add(model_id)

    for rs_id, rxn_sys in (file.reaction_systems or {}).items():
        nodes.append(
            ComponentNode(
                id=rs_id,
                name=rs_id,
                type="reaction_system",
                description=None,
                reference=None,
                metadata={
                    # A reaction system's PARAMETERS are its variable count. The
                    # schema forbids a `variables` field here, and
                    # `species_count` below already carries the species, so
                    # `parameters` is the only thing left for §4.8.1's "variable
                    # count" to mean — and it is the exact analogue of a model's
                    # `variables`, which likewise counts unknowns and parameters
                    # together. This used to be 0, which asserted that a
                    # reaction system declares no variables at all.
                    "var_count": len(getattr(rxn_sys, "parameters", {}) or {}),
                    "eq_count": len(getattr(rxn_sys, "reactions", []) or []),
                    "species_count": len(getattr(rxn_sys, "species", []) or []),
                },
            )
        )
        node_ids.add(rs_id)

    edges: list[GraphEdge[CouplingEdge]] = []
    for index, entry in enumerate(file.coupling or []):
        edge = _coupling_edge(entry, index, node_ids)
        if edge is not None:
            edges.append(GraphEdge(source=edge.from_component, target=edge.to_component, data=edge))

    return Graph(nodes=nodes, edges=edges, node_type=ComponentNode)


def _coupling_edge(entry: Any, index: int, node_ids: set[str]) -> CouplingEdge | None:
    """The component-graph edge one coupling entry contributes, if any."""
    edge_id = f"coupling-{index}"
    description = getattr(entry, "description", None)

    if isinstance(entry, (OperatorComposeCoupling, CouplingCouple)):
        systems = entry.systems or []
        if len(systems) < 2:
            return None
        source, target = systems[0], systems[1]
        if source not in node_ids or target not in node_ids:
            return None
        is_compose = isinstance(entry, OperatorComposeCoupling)
        return CouplingEdge(
            id=edge_id,
            from_component=source,
            to_component=target,
            type="operator_compose" if is_compose else "couple",
            label="compose" if is_compose else "couple",
            description=description,
            coupling=entry,
        )

    if isinstance(entry, VariableMapCoupling):
        source_ref, target_ref = entry.from_var, entry.to_var
        if not source_ref or not target_ref:
            return None
        source_parts = source_ref.split(".")
        target_parts = target_ref.split(".")
        # Both endpoints must be scoped `Component.variable` references; a bare
        # name identifies no component. TypeScript requires the dot on both
        # sides and this follows it.
        if len(source_parts) < 2 or len(target_parts) < 2:
            return None
        source, target = source_parts[0], target_parts[0]
        if source not in node_ids or target not in node_ids:
            return None
        return CouplingEdge(
            id=edge_id,
            from_component=source,
            to_component=target,
            type="variable_map",
            label=".".join(source_parts[1:]),
            description=description or f"{source_ref} → {target_ref}",
            coupling=entry,
        )

    # operator_apply / callback / event / coupling_import: no two concrete
    # component endpoints, so no component-graph edge.
    if isinstance(entry, (OperatorApplyCoupling, CallbackCoupling, EventCoupling, CouplingImport)):
        return None
    return None


def component_exists(file: EsmFile, component_id: str) -> bool:
    """True when ``component_id`` names a model or reaction system of ``file``."""
    return component_type(file, component_id) is not None


def component_type(file: EsmFile, component_id: str) -> str | None:
    """``"model"``, ``"reaction_system"`` or ``None``.

    The harmonized spelling of Rust's ``get_component_type`` / TypeScript's
    ``getComponentType`` — the API drops the ``get`` prefix.
    """
    if component_id in (file.models or {}):
        return "model"
    if component_id in (file.reaction_systems or {}):
        return "reaction_system"
    return None


# ---------------------------------------------------------------------------
# 3. Expression graph
# ---------------------------------------------------------------------------


class _ExprGraphBuilder:
    """Accumulator for :func:`expression_graph`, deduplicating by scoped name."""

    def __init__(self) -> None:
        self.nodes: list[VariableNode] = []
        self.edges: list[GraphEdge[DependencyEdge]] = []
        self._by_name: dict[str, VariableNode] = {}

    def add_node(
        self,
        name: str,
        kind: str,
        units: str | None = None,
        system: str = DEFAULT_SYSTEM,
    ) -> str:
        """Add a node (first writer wins) and return its scoped name."""
        scoped = name if system == DEFAULT_SYSTEM else f"{system}.{name}"
        if scoped not in self._by_name:
            node = VariableNode(name=scoped, kind=kind, units=units, system=system)
            self.nodes.append(node)
            self._by_name[scoped] = node
        return scoped

    def add_dependency(
        self,
        source: str,
        target: str,
        relationship: str,
        equation_index: int | None,
        expression: Expr | None,
    ) -> None:
        data = DependencyEdge(
            source=source,
            target=target,
            relationship=relationship,
            equation_index=equation_index,
            expression=expression,
        )
        self.edges.append(GraphEdge(source=source, target=target, data=data))

    def graph(self) -> Graph[VariableNode, DependencyEdge]:
        return Graph(nodes=self.nodes, edges=self.edges, node_type=VariableNode)


def lhs_target_name(lhs: Expr) -> str | None:
    """The variable an equation LHS defines.

    A bare name, or the name under a derivative / element-index /
    aggregate-output wrapper (``D(x)``, ``index(v, i)``, ``aggregate(...,
    expr: D(index(v, i)))``). Mirrors TypeScript's ``lhsTargetName`` and Go's
    ``extractVariableFromLHS``; Rust and Julia instead take every free variable
    of the LHS, which coincides for the common forms but credits an index
    variable as a dependency target for ``index(v, i)``.
    """
    if isinstance(lhs, str):
        return lhs
    op = getattr(lhs, "op", None)
    if op is None and isinstance(lhs, dict):
        op = lhs.get("op")
    if op in ("D", "index"):
        args = getattr(lhs, "args", None)
        if args is None and isinstance(lhs, dict):
            args = lhs.get("args")
        return lhs_target_name(args[0]) if args else None
    if op == "aggregate":
        body = getattr(lhs, "expr", None)
        if body is None and isinstance(lhs, dict):
            body = lhs.get("expr")
        return lhs_target_name(body) if body is not None else None
    return None


def _bound_index_symbols(node: ExprNode) -> list[str]:
    """Index symbols this node BINDS for its own body: an ``aggregate`` /
    ``arrayop``'s ``ranges`` keys and ``output_idx`` entries, and an
    ``integral``'s ``var``.

    Narrower than :func:`structural_checks._expression_bound_symbols`, which also
    treats every bare name in an ``index(A, i, j)`` position as bound. Those
    positions are exactly where an aggregate's binders appear, and subtracting
    them THERE rather than at the binding node would hide a real reference to a
    declared variable used as an index. The binder itself is caught at its
    ``aggregate``.
    """
    bound: list[str] = []
    ranges = getattr(node, "ranges", None)
    if isinstance(ranges, dict):
        bound.extend(ranges.keys())
    output_idx = getattr(node, "output_idx", None)
    if isinstance(output_idx, list):
        bound.extend(idx for idx in output_idx if isinstance(idx, str))
    int_var = getattr(node, "var", None)
    if isinstance(int_var, str):
        bound.append(int_var)
    return bound


def _collect_variable_references(expr: Expr, out: set[str]) -> None:
    """Accumulate ``expr``'s variable references into ``out``, subtracting each
    node's own binders at that node."""
    if isinstance(expr, str):
        out.add(expr)
        return
    if not isinstance(expr, ExprNode):
        return
    # Collect this node's subtree into a LOCAL set, subtract the symbols this
    # node binds, and only then promote what is left to the caller.
    local: set[str] = set()
    for child in iter_children(expr):
        _collect_variable_references(child, local)
    local.difference_update(_bound_index_symbols(expr))
    out.update(local)


def _sorted_free_variables(expr: Expr | None) -> list[str]:
    """The variables ``expr`` REFERENCES, with every locally-bound index symbol
    removed, sorted so edge order is deterministic — the node set §4.8.2 asks
    for.

    Deliberately NOT :func:`expression.free_variables`. That function walks every
    child and reports every bare name it reaches, so an ``aggregate``'s own range
    binders (``sum over a of src[a]``) come back looking like model variables and
    become graph nodes with no declaration, no units and no kind. A binder is
    introduced by the aggregate's own ``ranges`` clause and is scoped to it; it
    is not a variable of the system, so it is not a node.

    ``free_variables`` itself is unchanged: it is public API and is shared with
    validation and unit conversion, where "every name the subtree mentions" is
    the wanted answer.
    """
    if expr is None:
        return []
    found: set[str] = set()
    _collect_variable_references(expr, found)
    return sorted(found)


def _variable_kinds(model: Model) -> dict[str, str]:
    """Every declared variable's DERIVED graph kind (esm-spec §6.3.1).

    Computed once per model: each classifier walks the equation list. The
    vocabulary is the one TypeScript uses, which is the consensus of the four
    bindings — it agrees with Rust on ``state`` / ``parameter`` / ``observed`` /
    ``brownian`` / ``discrete`` / ``species`` and with Go on ``algebraic`` being
    a category of its own rather than folded into ``state``.
    """
    kinds: dict[str, str] = {}
    for names, kind in (
        (ode_states(model), "state"),
        (observed_unknowns(model), "observed"),
        (algebraic_unknowns(model), "algebraic"),
        (brownian_parameters(model), "brownian"),
        (discrete_parameters(model), "discrete"),
        (sampled_parameters(model), "parameter"),
        (constant_parameters(model), "parameter"),
    ):
        for name in names:
            kinds[name] = kind
    return kinds


def _process_equation(
    builder: _ExprGraphBuilder,
    equation: Equation,
    equation_index: int,
    system_id: str,
) -> None:
    """Add one equation's RHS → LHS dependency edges.

    A variable the equation references but the component never declared is
    fabricated as a node (Rust and TypeScript both do this; Go and Julia drop
    the edge instead, which leaves the dependency invisible). Self-references
    such as ``D(x)/dt = -x`` DO produce an edge — that is a real dependency,
    and Rust and TypeScript both keep it.
    """
    target = lhs_target_name(equation.lhs)
    if target is None:
        return
    target_key = builder.add_node(target, "state", None, system_id)
    for name in _sorted_free_variables(equation.rhs):
        source_key = builder.add_node(name, "parameter", None, system_id)
        builder.add_dependency(source_key, target_key, "additive", equation_index, equation.rhs)


def _process_reaction(
    builder: _ExprGraphBuilder,
    reaction: Reaction,
    reaction_index: int,
    system_id: str,
) -> None:
    """Add one reaction's rate and stoichiometric edges.

    Rate-expression variables are rate constants and become ``parameter`` nodes;
    reactants and products become ``species`` nodes. Both edge families carry
    the reaction's index. Emission order follows Rust: for each rate variable,
    the products then the reactants, then the reactant → product stoichiometry.
    """
    rate = reaction.rate_constant
    rate_vars = _sorted_free_variables(rate if not isinstance(rate, (int, float)) else None)
    reactants = list(reaction.reactants or {})
    products = list(reaction.products or {})

    for name in rate_vars:
        builder.add_node(name, "parameter", None, system_id)
    for name in reactants + products:
        builder.add_node(name, "species", None, system_id)

    for rate_var in rate_vars:
        source_key = builder.add_node(rate_var, "parameter", None, system_id)
        for species in products + reactants:
            target_key = builder.add_node(species, "species", None, system_id)
            builder.add_dependency(source_key, target_key, "rate", reaction_index, rate)

    for reactant in reactants:
        source_key = builder.add_node(reactant, "species", None, system_id)
        for product in products:
            target_key = builder.add_node(product, "species", None, system_id)
            # Rust and Go both leave a stoichiometric edge's `expression` empty:
            # the rate is not what relates a reactant to a product.
            builder.add_dependency(source_key, target_key, "stoichiometric", reaction_index, None)


def _process_model(builder: _ExprGraphBuilder, model: Model, system_id: str) -> None:
    kinds = _variable_kinds(model)
    for var_name, variable in (model.variables or {}).items():
        builder.add_node(var_name, kinds.get(var_name, "parameter"), variable.units, system_id)
    for index, equation in enumerate(model.equations or []):
        _process_equation(builder, equation, index, system_id)


def _process_reaction_system(
    builder: _ExprGraphBuilder, rxn_sys: ReactionSystem, system_id: str
) -> None:
    for species in rxn_sys.species or []:
        builder.add_node(species.name, "species", species.units, system_id)
    for parameter in rxn_sys.parameters or []:
        builder.add_node(parameter.name, "parameter", parameter.units, system_id)

    reactions = rxn_sys.reactions or []
    for index, reaction in enumerate(reactions):
        _process_reaction(builder, reaction, index, system_id)
    # Constraint equations are numbered after the reactions (TypeScript).
    for index, equation in enumerate(rxn_sys.constraint_equations or []):
        _process_equation(builder, equation, index + len(reactions), system_id)


def _process_component_tree(
    builder: _ExprGraphBuilder,
    component: Model | ReactionSystem,
    system_id: str,
) -> None:
    """Process a component and, recursively, its inline subsystems.

    A component carried as an unresolved ``{"ref": ...}`` stub (a top-level
    model included by reference, or a ref subsystem `resolve_subsystem_refs`
    has not spliced yet) contributes nothing: it declares no variables here.
    TypeScript skips reference stubs the same way — they stay COMPONENT-graph
    nodes, with no counts, but have no expression-graph content.
    """
    if not isinstance(component, (Model, ReactionSystem)):
        return
    if isinstance(component, ReactionSystem):
        _process_reaction_system(builder, component, system_id)
    else:
        _process_model(builder, component, system_id)

    for child_name, child in (getattr(component, "subsystems", None) or {}).items():
        child_scoped = child_name if system_id == DEFAULT_SYSTEM else f"{system_id}.{child_name}"
        _process_component_tree(builder, child, child_scoped)


def _process_coupling(builder: _ExprGraphBuilder, coupling: Iterable[Any]) -> None:
    """Fold ``variable_map`` entries into cross-system dependency edges."""
    for entry in coupling:
        if not isinstance(entry, VariableMapCoupling):
            continue
        source_ref, target_ref = entry.from_var, entry.to_var
        if not source_ref or not target_ref:
            continue
        source_parts = source_ref.split(".")
        target_parts = target_ref.split(".")
        if len(source_parts) < 2 or len(target_parts) < 2:
            continue
        source_key = builder.add_node(
            ".".join(source_parts[1:]), "parameter", None, source_parts[0]
        )
        target_key = builder.add_node(
            ".".join(target_parts[1:]), "parameter", None, target_parts[0]
        )
        # No positional equation produced this edge. The sentinel is -1, not
        # None: `equation_index` is `number | null` on the wire (§4.8.2), and
        # the bindings reserve null for "this binding does not track it" while
        # -1 positively means "no positional equation" (TypeScript's
        # NON_EQUATION_INDEX).
        builder.add_dependency(
            source_key, target_key, "multiplicative", NON_EQUATION_INDEX, source_ref
        )


def expression_graph(
    target: EsmFile | Model | ReactionSystem | Equation | Reaction | Expr,
    merge_coupled: bool = False,
) -> Graph[VariableNode, DependencyEdge]:
    """Build the variable-dependency graph of ``target``.

    ``target`` may be an :class:`~earthsci_ast.esm_types.EsmFile`, a
    :class:`~earthsci_ast.esm_types.Model`, a
    :class:`~earthsci_ast.esm_types.ReactionSystem`, an
    :class:`~earthsci_ast.esm_types.Equation`, a
    :class:`~earthsci_ast.esm_types.Reaction`, or a bare expression — the same
    six granularities the other bindings accept.

    For a whole file every node name is scoped ``Component.variable``; for a
    standalone target the names stay bare.

    ``merge_coupled`` folds the file's ``variable_map`` coupling entries into
    cross-system edges. It is off by default, matching TypeScript's
    ``mergeCoupled`` default and Rust's and Go's unconditional behaviour (Julia
    always adds them).
    """
    builder = _ExprGraphBuilder()

    if isinstance(target, EsmFile):
        for model_id, model in (target.models or {}).items():
            _process_component_tree(builder, model, model_id)
        for rs_id, rxn_sys in (target.reaction_systems or {}).items():
            _process_component_tree(builder, rxn_sys, rs_id)
        if merge_coupled:
            _process_coupling(builder, target.coupling or [])
    elif isinstance(target, (Model, ReactionSystem)):
        _process_component_tree(builder, target, DEFAULT_SYSTEM)
    elif isinstance(target, Equation):
        _process_equation(builder, target, 0, DEFAULT_SYSTEM)
    elif isinstance(target, Reaction):
        _process_reaction(builder, target, 0, DEFAULT_SYSTEM)
    else:
        # A bare expression. §4.8.2 requires this overload to produce EDGES, not
        # just nodes ("every variable in the expression becomes a node, and the
        # tree structure is flattened into dependency edges"), so the expression's
        # value gets a synthetic target node and every free variable feeds it.
        result = builder.add_node(EXPR_RESULT, "observed", None, DEFAULT_SYSTEM)
        for name in _sorted_free_variables(target):
            source_key = builder.add_node(name, "parameter", None, DEFAULT_SYSTEM)
            # NON_EQUATION_INDEX: a bare expression has no positional equation
            # to index, which is exactly what the sentinel is for. (The Equation
            # and Reaction overloads DO number their single target 0 — they are
            # positional statements; a loose expression is not.)
            builder.add_dependency(
                source_key, result, "multiplicative", NON_EQUATION_INDEX, target
            )

    return builder.graph()


# ---------------------------------------------------------------------------
# 4. Exporters
# ---------------------------------------------------------------------------

# One row per category, holding BOTH the DOT and the Mermaid styling so the two
# emitters cannot drift. Unknown categories fall back to the paired default.

_COMPONENT_NODE_STYLE: dict[str, tuple[str, tuple[str, str]]] = {
    # type -> (dot fillcolor, mermaid (open, close))
    "model": ("lightgreen", ("[", "]")),
    "reaction_system": ("lightcoral", ("(", ")")),
}
_COMPONENT_NODE_DEFAULT_STYLE = ("lightgray", ("((", "))"))

_COUPLING_EDGE_STYLE: dict[str, tuple[str, str]] = {
    # type -> (dot color, mermaid arrow)
    "operator_compose": ("blue", "-->"),
    "couple": ("blue", "-->"),
    "variable_map": ("green", "-.->"),
}
_COUPLING_EDGE_DEFAULT_STYLE = ("black", "-->")

_VARIABLE_NODE_STYLE: dict[str, tuple[str, tuple[str, str]]] = {
    # kind -> (dot shape, mermaid (open, close))
    "state": ("circle", ("((", "))")),
    "algebraic": ("circle", ("((", "))")),
    "parameter": ("box", ("[", "]")),
    "observed": ("diamond", ("{", "}")),
    "brownian": ("doubleoctagon", ("{{", "}}")),
    "discrete": ("hexagon", ("[/", "/]")),
    "species": ("ellipse", ("(", ")")),
}
_VARIABLE_NODE_DEFAULT_STYLE = ("diamond", ("((", "))"))

_DEPENDENCY_EDGE_STYLE: dict[str, tuple[str, str]] = {
    # relationship -> (dot style, mermaid arrow)
    "rate": ("dotted", "-..->"),
    "stoichiometric": ("dashed", "-..->"),
}
_DEPENDENCY_EDGE_DEFAULT_STYLE = ("solid", "-->")

#: A name is treated as a chemical formula — and rendered with subscripts —
#: only when letters are followed by digits. Mirrors Julia's `format_node_label`.
_CHEMICAL_RE = re.compile(r"[A-Za-z]+\d+")


def _format_node_label(name: str) -> str:
    """Render a node label, applying chemical subscripts where they apply."""
    if _CHEMICAL_RE.search(name):
        return _format_chemical_subscripts(name, "unicode")
    return name


def _dot_escape(text: str) -> str:
    """Escape a string for a DOT double-quoted id/label."""
    return text.replace("\\", "\\\\").replace('"', '\\"')


def _mermaid_id(name: str) -> str:
    """Mermaid ids must be plain identifiers; dotted names are ambiguous."""
    return re.sub(r"[^A-Za-z0-9_]", "_", name)


def _mermaid_label(label: str) -> str:
    """Mermaid labels are emitted quoted; escape embedded quotes."""
    return label.replace('"', "#quot;")


def _is_component_graph(graph: Graph[Any, Any]) -> bool:
    return graph.node_type is ComponentNode


def to_dot(graph: Graph[Any, Any]) -> str:
    """Render ``graph`` as Graphviz DOT.

    Component nodes are coloured by type and coupling edges by kind; variable
    nodes are shaped by their derived kind and dependency edges styled by
    relationship. The ``digraph ComponentGraph`` / ``digraph ExpressionGraph``
    headers are what Julia, Rust and Go all emit (TypeScript writes a bare
    ``digraph``).
    """
    if _is_component_graph(graph):
        lines = ["digraph ComponentGraph {"]
        for node in graph.nodes:
            fillcolor, _ = _COMPONENT_NODE_STYLE.get(node.type, _COMPONENT_NODE_DEFAULT_STYLE)
            label = _format_node_label(node.name)
            lines.append(
                f'  "{_dot_escape(node.id)}" [label="{_dot_escape(label)}", '
                f"fillcolor={fillcolor}, style=filled];"
            )
        for edge in graph.edges:
            color, _ = _COUPLING_EDGE_STYLE.get(edge.data.type, _COUPLING_EDGE_DEFAULT_STYLE)
            lines.append(
                f'  "{_dot_escape(edge.data.from_component)}" -> '
                f'"{_dot_escape(edge.data.to_component)}" '
                f'[label="{_dot_escape(edge.data.label)}", color={color}];'
            )
        lines.append("}")
        return "\n".join(lines)

    lines = ["digraph ExpressionGraph {"]
    for node in graph.nodes:
        shape, _ = _VARIABLE_NODE_STYLE.get(node.kind, _VARIABLE_NODE_DEFAULT_STYLE)
        label = _format_node_label(node.name)
        lines.append(f'  "{_dot_escape(node.name)}" [label="{_dot_escape(label)}", shape={shape}];')
    for edge in graph.edges:
        style, _ = _DEPENDENCY_EDGE_STYLE.get(
            edge.data.relationship, _DEPENDENCY_EDGE_DEFAULT_STYLE
        )
        lines.append(
            f'  "{_dot_escape(edge.data.source)}" -> "{_dot_escape(edge.data.target)}" '
            f'[label="{_dot_escape(edge.data.relationship)}", style={style}];'
        )
    lines.append("}")
    return "\n".join(lines)


def to_mermaid(graph: Graph[Any, Any]) -> str:
    """Render ``graph`` as a Mermaid flowchart for Markdown embedding.

    Node ids are sanitized to plain identifiers (``Chem.O3`` → ``Chem_O3``) and
    labels are quoted, so scoped names render correctly. Edges carry a quoted
    label — the coupling label for a component graph, the dependency
    relationship for an expression graph.
    """
    lines = ["graph TD"]
    if _is_component_graph(graph):
        for node in graph.nodes:
            _, (open_tok, close_tok) = _COMPONENT_NODE_STYLE.get(
                node.type, _COMPONENT_NODE_DEFAULT_STYLE
            )
            label = _mermaid_label(_format_node_label(node.name))
            lines.append(f'    {_mermaid_id(node.id)}{open_tok}"{label}"{close_tok}')
        for edge in graph.edges:
            _, arrow = _COUPLING_EDGE_STYLE.get(edge.data.type, _COUPLING_EDGE_DEFAULT_STYLE)
            lines.append(
                f"    {_mermaid_id(edge.data.from_component)} {arrow}"
                f'|"{_mermaid_label(edge.data.label)}"| '
                f"{_mermaid_id(edge.data.to_component)}"
            )
        return "\n".join(lines)

    for node in graph.nodes:
        _, (open_tok, close_tok) = _VARIABLE_NODE_STYLE.get(node.kind, _VARIABLE_NODE_DEFAULT_STYLE)
        label = _mermaid_label(_format_node_label(node.name))
        lines.append(f'    {_mermaid_id(node.name)}{open_tok}"{label}"{close_tok}')
    for edge in graph.edges:
        _, arrow = _DEPENDENCY_EDGE_STYLE.get(
            edge.data.relationship, _DEPENDENCY_EDGE_DEFAULT_STYLE
        )
        lines.append(
            f"    {_mermaid_id(edge.data.source)} {arrow}"
            f'|"{_mermaid_label(edge.data.relationship)}"| '
            f"{_mermaid_id(edge.data.target)}"
        )
    return "\n".join(lines)


def to_json(graph: Graph[Any, Any]) -> str:
    """Render ``graph`` as the JSON adjacency list of esm-libraries-spec §4.8.3.

    Three top-level keys:

    * ``nodes`` — each node's own fields, prefixed with the ``id`` that keys it
      (a component node's ``id``, a variable node's ``name``);
    * ``edges`` — ``{"source", "target", "data"}``, endpoints by node key with
      the edge payload under ``data``;
    * ``adjacency`` — every node key mapped to its UNDIRECTED neighbours, which
      is what :meth:`Graph.adjacency` returns. (This used to map to
      ``successors`` instead, so a graph's JSON export disagreed with its own
      ``adjacency()`` — caught by the shared corpus.)

    Pinned by ``tests/conformance/graph/cases.json`` at the level of the
    top-level keys, the node ids, the edge endpoints and the adjacency map; the
    per-node and per-edge payloads are this binding's own and are not.
    """
    if _is_component_graph(graph):
        nodes = [
            {
                "id": node.id,
                "name": node.name,
                "type": node.type,
                "description": node.description,
                "metadata": node.metadata,
            }
            for node in graph.nodes
        ]
        edges = [
            {
                "source": edge.source,
                "target": edge.target,
                "data": {
                    "id": edge.data.id,
                    # Wire spellings of `from_component` / `to_component`.
                    "from": edge.data.from_component,
                    "to": edge.data.to_component,
                    "type": edge.data.type,
                    "label": edge.data.label,
                    "description": edge.data.description,
                },
            }
            for edge in graph.edges
        ]
    else:
        nodes = [
            {
                "id": node.name,
                "name": node.name,
                "kind": node.kind,
                "units": node.units,
                "system": node.system,
            }
            for node in graph.nodes
        ]
        edges = [
            {
                "source": edge.source,
                "target": edge.target,
                "data": {
                    "source": edge.data.source,
                    "target": edge.data.target,
                    "relationship": edge.data.relationship,
                    "equation_index": edge.data.equation_index,
                },
            }
            for edge in graph.edges
        ]

    adjacency = {_node_key(node): graph.adjacency(_node_key(node)) for node in graph.nodes}
    return json.dumps(
        {"nodes": nodes, "edges": edges, "adjacency": adjacency},
        indent=2,
        ensure_ascii=False,
    )
