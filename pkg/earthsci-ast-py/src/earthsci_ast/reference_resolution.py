"""Build-time reference resolution for the semiring-FAQ unified IR.

This module implements *node addressing* and *reference-edge resolution* — the
hard prerequisite the §6.1 cadence-partition pass of the
``semiring-faq-unified-ir`` RFC calls out:

    "node addressing — referencing a node by id — is a hard prerequisite: the
     pass cannot be built until ``from_faq`` and join references are real edges
     in this DAG."

The partition pass classifies every node by cadence (``CONST`` / ``DISCRETE`` /
``CONTINUOUS``) by walking the *inter-node* dependency DAG bottom-up
(``class(n) = max`` over inputs). For that walk to exist, three kinds of
name/id reference in the document must be resolved into real, queryable graph
edges (RFC §6.1 "Propagation"):

* an aggregate node ``→`` an index set it references (``ranges[*].from``);
* a ``kind:"derived"`` index set ``→`` its ``from_faq`` node (by stable id);
* an aggregate ``join.on`` factor ``→`` the factor it names.

This pass operates on the **raw parsed document** (plain ``dict`` form, exactly
what :func:`earthsci_ast.parse.load` validates), not the typed ``ExprNode``
dataclasses: the typed layer deliberately drops ``index_sets``, node ``id``,
``ranges[*].from`` and ``join``, so the references live only in the raw JSON.
The pass is therefore self-contained and additive — a document using none of
these features yields an empty-but-valid graph.

The output :class:`ReferenceGraph` is the queryable surface the partition pass
consumes: :meth:`~ReferenceGraph.dependencies` /
:meth:`~ReferenceGraph.dependents` give the DAG adjacency, and
:meth:`~ReferenceGraph.topological_order` both detects reference cycles (an
out-of-scope implicit/iterative solve, RFC §6.1 "Acyclicity") and yields a
bottom-up evaluation order.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from .errors import EarthSciAstError

__all__ = [
    "ReferenceResolutionError",
    "VertexKind",
    "EdgeKind",
    "ReferenceVertex",
    "ReferenceEdge",
    "ReferenceGraph",
    "build_reference_graph",
    "resolve_references",
]

# --- error codes (stable; mirrored across the Julia/Rust bindings) ----------

#: undeclared name in a ``ranges[*].from`` reference.
E_REF_UNDECLARED_INDEX_SET = "E_REF_UNDECLARED_INDEX_SET"
#: a ``kind:"derived"`` index set's ``from_faq`` names no node id in the model.
E_REF_UNKNOWN_FAQ_NODE = "E_REF_UNKNOWN_FAQ_NODE"
#: two expression nodes in the same model share an explicit ``id``.
E_REF_DUPLICATE_NODE_ID = "E_REF_DUPLICATE_NODE_ID"
#: a ``join.on`` factor reference names nothing in the node's scope.
E_REF_UNRESOLVED_JOIN_FACTOR = "E_REF_UNRESOLVED_JOIN_FACTOR"
#: a directed cycle exists among the reference edges.
E_REF_CYCLE = "E_REF_CYCLE"


class ReferenceResolutionError(EarthSciAstError):
    """A reference could not be resolved, or the reference graph has a cycle.

    Carries a stable ``code`` (one of the ``E_REF_*`` constants) so callers and
    the cross-binding conformance suite can assert on the failure mode, and a
    human-readable ``message``. For a cycle, ``cycle`` holds the offending path.
    """

    def __init__(self, code: str, message: str, cycle: list[str] | None = None):
        super().__init__(f"ReferenceResolutionError({code}): {message}")
        self.code = code
        self.message = message
        self.cycle = cycle


# --- vertex / edge model ----------------------------------------------------


class VertexKind:
    """The three kinds of vertex in the reference graph."""

    NODE = "node"
    INDEX_SET = "index_set"
    FACTOR = "factor"


class EdgeKind:
    """The three kinds of reference edge (RFC §6.1 "Propagation")."""

    #: aggregate node → the index set it iterates (``ranges[*].from``).
    RANGE_FROM = "range_from"
    #: ``kind:"derived"`` index set → the node that materializes it (``from_faq``).
    FROM_FAQ = "from_faq"
    #: aggregate node → a factor named by ``join.on``.
    JOIN_FACTOR = "join_factor"


@dataclass(frozen=True)
class ReferenceVertex:
    """A vertex in the reference graph, addressed by a kind-namespaced ``key``.

    ``key`` is ``f"{kind}:{name}"``. For a ``NODE`` vertex ``name`` is the
    node's stable address: its explicit ``id`` when it has one, else its
    structural path (e.g. ``equations/0/rhs/expr``). ``node_id`` records the
    explicit id (if any), ``op`` the operator, and ``path`` the structural path,
    for diagnostics.
    """

    key: str
    kind: str
    name: str
    op: str | None = None
    node_id: str | None = None
    path: str | None = None


@dataclass(frozen=True)
class ReferenceEdge:
    """A directed ``source → target`` edge: *source references/depends on target*."""

    source: str
    target: str
    kind: str


@dataclass
class ReferenceGraph:
    """The resolved reference DAG for one model — the partition pass's input.

    Vertices are keyed by their kind-namespaced ``key``. ``edges`` point from a
    vertex to a vertex it *depends on*, so a bottom-up
    (:meth:`topological_order`) walk visits each vertex after its dependencies —
    exactly the order ``class(n) = max(class(inputs))`` propagation needs.
    """

    model: str = ""
    vertices: dict[str, ReferenceVertex] = field(default_factory=dict)
    edges: list[ReferenceEdge] = field(default_factory=list)
    # adjacency: vertex key -> ordered list of dependency keys (out-neighbours)
    _out: dict[str, list[str]] = field(default_factory=dict)
    _in: dict[str, list[str]] = field(default_factory=dict)

    # -- construction --------------------------------------------------------

    def _ensure_vertex(self, vertex: ReferenceVertex) -> None:
        if vertex.key not in self.vertices:
            self.vertices[vertex.key] = vertex
            self._out.setdefault(vertex.key, [])
            self._in.setdefault(vertex.key, [])

    def _add_edge(self, source: str, target: str, kind: str) -> None:
        self.edges.append(ReferenceEdge(source, target, kind))
        self._out.setdefault(source, []).append(target)
        self._in.setdefault(target, []).append(source)

    # -- queries (the partition-pass surface) --------------------------------

    def dependencies(self, key: str) -> list[str]:
        """Vertices ``key`` references / depends on (its out-neighbours)."""
        return list(self._out.get(key, []))

    def dependents(self, key: str) -> list[str]:
        """Vertices that reference / depend on ``key`` (its in-neighbours)."""
        return list(self._in.get(key, []))

    def edges_of_kind(self, kind: str) -> list[ReferenceEdge]:
        return [e for e in self.edges if e.kind == kind]

    def detect_cycle(self) -> list[str] | None:
        """Return a reference cycle as a vertex-key path, or ``None`` if acyclic.

        Three-colour DFS over the dependency edges. The returned path is
        ``[v, …, v]`` (the repeated vertex closes the cycle).
        """
        WHITE, GREY, BLACK = 0, 1, 2
        colour: dict[str, int] = dict.fromkeys(self.vertices, WHITE)

        # deterministic traversal: sorted keys, sorted neighbours.
        order = sorted(self.vertices)

        def visit(start: str) -> list[str] | None:
            # explicit stack of (vertex, iterator-index) with a path for reporting
            stack: list[tuple[str, int]] = [(start, 0)]
            path: list[str] = [start]
            colour[start] = GREY
            while stack:
                node, i = stack[-1]
                neighbours = sorted(self._out.get(node, []))
                if i < len(neighbours):
                    stack[-1] = (node, i + 1)
                    nxt = neighbours[i]
                    if colour.get(nxt, WHITE) == GREY:
                        # back-edge → cycle; slice the path from nxt's first use
                        idx = path.index(nxt)
                        return path[idx:] + [nxt]
                    if colour.get(nxt, WHITE) == WHITE:
                        colour[nxt] = GREY
                        stack.append((nxt, 0))
                        path.append(nxt)
                else:
                    colour[node] = BLACK
                    stack.pop()
                    path.pop()
            return None

        for start in order:
            if colour[start] == WHITE:
                cyc = visit(start)
                if cyc is not None:
                    return cyc
        return None

    def topological_order(self) -> list[str]:
        """Bottom-up order (dependencies before dependents).

        Raises :class:`ReferenceResolutionError` (``E_REF_CYCLE``) if the graph
        is cyclic — a cycle among reference edges is an out-of-scope
        implicit/iterative solve (RFC §6.1 "Acyclicity").
        """
        cyc = self.detect_cycle()
        if cyc is not None:
            raise ReferenceResolutionError(
                E_REF_CYCLE,
                "reference cycle detected: " + " -> ".join(cyc),
                cycle=cyc,
            )
        # Kahn over the dependency DAG, emitting a dependency before its
        # dependents. A vertex is ready once all its out-neighbours are emitted.
        emitted: list[str] = []
        done = set()
        remaining = {k: set(self._out.get(k, [])) for k in self.vertices}
        # deterministic: repeatedly emit the smallest key whose deps are all done
        while len(emitted) < len(self.vertices):
            progressed = False
            for k in sorted(self.vertices):
                if k in done:
                    continue
                if remaining[k] <= done:
                    emitted.append(k)
                    done.add(k)
                    progressed = True
            if not progressed:  # pragma: no cover - guarded by detect_cycle
                break
        return emitted


# --- the resolution pass ----------------------------------------------------

_AGGREGATE_OPS = ("aggregate",)


def _node_key(addr: str) -> str:
    return f"{VertexKind.NODE}:{addr}"


def _index_set_key(name: str) -> str:
    return f"{VertexKind.INDEX_SET}:{name}"


def _factor_key(name: str) -> str:
    return f"{VertexKind.FACTOR}:{name}"


def _is_node(value) -> bool:
    return isinstance(value, dict) and "op" in value


def build_reference_graph(
    model: dict,
    model_name: str = "",
    index_sets: dict | None = None,
) -> ReferenceGraph:
    """Resolve the reference edges of one ``model`` dict into a graph.

    ``index_sets`` is the document-scoped index-set registry (RFC §5.2), which
    as of v0.8.0 lives at the top level of the document rather than on each
    model. :func:`resolve_references` threads the document registry in for every
    model. When ``index_sets`` is omitted (a direct caller passing a raw model
    dict), it falls back to a ``model["index_sets"]`` key for backward
    compatibility.

    Raises :class:`ReferenceResolutionError` on a duplicate node id, an
    undeclared ``ranges[*].from`` index set, a ``from_faq`` naming no node, or
    an unresolved ``join.on`` factor. (Cycles are reported lazily by
    :meth:`ReferenceGraph.topological_order`, or eagerly by
    :func:`resolve_references`.)
    """
    graph = ReferenceGraph(model=model_name)

    # Pass 1 — register declared index sets as vertices. Prefer the
    # document-scoped registry; fall back to a model-local ``index_sets`` key
    # only when no registry was supplied (direct raw-model callers).
    if index_sets is None:
        index_sets = model.get("index_sets") or {}
    if not isinstance(index_sets, dict):
        index_sets = {}
    for name in index_sets:
        graph._ensure_vertex(
            ReferenceVertex(key=_index_set_key(name), kind=VertexKind.INDEX_SET, name=name)
        )

    # Pass 2 — walk every expression node; assign a stable address, register
    # aggregate / id-bearing nodes, and add the within-node reference edges
    # (ranges[*].from, join.on). Also build id -> address for from_faq.
    id_to_addr: dict[str, str] = {}

    def addr_of(node: dict, path: str) -> str:
        nid = node.get("id")
        return nid if isinstance(nid, str) and nid else path

    def register_node(node: dict, path: str) -> str | None:
        op = node.get("op")
        nid = node.get("id")
        nid = nid if isinstance(nid, str) and nid else None
        is_agg = op in _AGGREGATE_OPS
        # only nodes that participate in addressing become vertices: the
        # aggregate/FAQ nodes and any node carrying an explicit id.
        if not is_agg and nid is None:
            return None
        addr = nid or path
        key = _node_key(addr)
        if nid is not None:
            if nid in id_to_addr:
                raise ReferenceResolutionError(
                    E_REF_DUPLICATE_NODE_ID,
                    f"duplicate expression-node id '{nid}' in model "
                    f"'{model_name}' (at {path} and {_node_key(id_to_addr[nid])})",
                )
            id_to_addr[nid] = addr
        graph._ensure_vertex(
            ReferenceVertex(key=key, kind=VertexKind.NODE, name=addr, op=op, node_id=nid, path=path)
        )
        return key

    def factor_scope(node: dict) -> set:
        """Names a ``join.on`` reference may resolve to: the node's string
        factor-args, its declared range keys, and its symbolic output_idx."""
        names = set()
        for a in node.get("args") or []:
            if isinstance(a, str):
                names.add(a)
        ranges = node.get("ranges")
        if isinstance(ranges, dict):
            names.update(ranges.keys())
        for o in node.get("output_idx") or []:
            if isinstance(o, str):
                names.add(o)
        return names

    def process_node_refs(node: dict, key: str, path: str) -> None:
        # ranges[*].from -> index set
        ranges = node.get("ranges")
        if isinstance(ranges, dict):
            for idx_name, spec in ranges.items():
                if isinstance(spec, dict) and "from" in spec:
                    target = spec.get("from")
                    if not isinstance(target, str) or target not in index_sets:
                        raise ReferenceResolutionError(
                            E_REF_UNDECLARED_INDEX_SET,
                            f"range '{idx_name}' of node {key} references "
                            f"undeclared index set '{target}' "
                            f"(model '{model_name}', at {path})",
                        )
                    graph._add_edge(key, _index_set_key(target), EdgeKind.RANGE_FROM)
        # join[*].on[*] -> factor
        join = node.get("join")
        if isinstance(join, list):
            scope = factor_scope(node)
            for clause in join:
                if not isinstance(clause, dict):
                    continue
                for pair in clause.get("on") or []:
                    if not isinstance(pair, (list, tuple)) or not pair:
                        continue
                    ref = pair[0]
                    if not isinstance(ref, str) or ref not in scope:
                        raise ReferenceResolutionError(
                            E_REF_UNRESOLVED_JOIN_FACTOR,
                            f"join factor '{ref}' of node {key} names no factor, "
                            f"range, or output index in scope "
                            f"(model '{model_name}', at {path})",
                        )
                    graph._ensure_vertex(
                        ReferenceVertex(key=_factor_key(ref), kind=VertexKind.FACTOR, name=ref)
                    )
                    graph._add_edge(key, _factor_key(ref), EdgeKind.JOIN_FACTOR)

    # Two-step walk: register all nodes first (so every id is known before any
    # reference is resolved), then resolve within-node refs.
    pending: list[tuple[dict, str, str]] = []  # (node, key, path)

    def walk(value, path: str) -> None:
        if isinstance(value, dict):
            if _is_node(value):
                key = register_node(value, path)
                if key is not None:
                    pending.append((value, key, path))
            for k, v in value.items():
                walk(v, f"{path}/{k}")
        elif isinstance(value, list):
            for i, v in enumerate(value):
                walk(v, f"{path}/{i}")

    for root_key in ("equations", "initialization_equations"):
        walk(model.get(root_key), root_key)

    for node, key, path in pending:
        process_node_refs(node, key, path)

    # Pass 3 — derived index sets resolve their from_faq to a node by id.
    for name, entry in index_sets.items():
        if not isinstance(entry, dict):
            continue
        if entry.get("kind") == "derived":
            faq = entry.get("from_faq")
            if not isinstance(faq, str) or faq not in id_to_addr:
                raise ReferenceResolutionError(
                    E_REF_UNKNOWN_FAQ_NODE,
                    f"derived index set '{name}' references from_faq '{faq}', "
                    f"which is not the id of any expression node in model "
                    f"'{model_name}'",
                )
            graph._add_edge(_index_set_key(name), _node_key(id_to_addr[faq]), EdgeKind.FROM_FAQ)

    return graph


def resolve_references(document: dict) -> dict[str, ReferenceGraph]:
    """Resolve reference edges for every model in ``document``.

    Returns a ``{model_name: ReferenceGraph}`` map. Raises
    :class:`ReferenceResolutionError` on any unresolved reference *or* reference
    cycle (each model's graph is checked acyclic eagerly here).
    """
    out: dict[str, ReferenceGraph] = {}
    models = document.get("models") or {}
    if not isinstance(models, dict):
        return out
    # The index-set registry is document-scoped (v0.8.0): read it once from the
    # top level and thread it into every model's graph.
    doc_index_sets = document.get("index_sets") or {}
    if not isinstance(doc_index_sets, dict):
        doc_index_sets = {}
    for model_name, model in models.items():
        if not isinstance(model, dict):
            continue
        graph = build_reference_graph(model, model_name, index_sets=doc_index_sets)
        cyc = graph.detect_cycle()
        if cyc is not None:
            raise ReferenceResolutionError(
                E_REF_CYCLE,
                f"reference cycle in model '{model_name}': " + " -> ".join(cyc),
                cycle=cyc,
            )
        out[model_name] = graph
    return out
