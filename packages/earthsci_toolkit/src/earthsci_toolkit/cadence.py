"""Build-time cadence-partition pass — the ESS ``structural_simplify`` analogue.

The dependency-partition pass (RFC ``semiring-faq-unified-ir`` §6.1, normative as
``CONFORMANCE_SPEC.md`` §5.7) is the build-phase analysis the
:mod:`earthsci_toolkit.numpy_interpreter` runs *before* it compiles a model's
hot per-step tree. It is the ESS analogue of ModelingToolkit's
``structural_simplify`` / observed-variable elimination, generalised from two
phases to three: it classifies **every node** by the *cadence* at which its
value can change and schedules each class into its own evaluation phase.

The cadence lattice
===================

Three classes form a total order ``const ⊏ discrete ⊏ continuous``:

==============  ===================================  =========================
class           changes                              evaluated
==============  ===================================  =========================
``const``       never                                once, folded into the artifact
``discrete``    only at discrete refresh events      at setup + on each event (per-event handler)
``continuous``  every step                            every RHS call (hot ``_Node`` tree)
==============  ===================================  =========================

The governing principle is that a node's class is a **pure function of the
data-dependency DAG** — ``class(node) = max`` (the lattice join) over its inputs'
classes — and is **never declared** by the author. The boundary between phases is
*derived*, not written into the file. The one new declaration the pass needs is
the leaf seed (the ``discrete`` variable kind); the optional ``expect_cadence``
annotation is a *checked assertion*, not a control input.

The gather rule (the rule that carries the design)
==================================================

For a gather ``index(A, e₁…eₖ)`` the index expressions are classified
**independently of the array**::

    class(index(A, e…)) = max( class(A), class(e₁), …, class(eₖ) )

so a stencil **splits** across phases: in ``index(u, index(nbr, i, k))`` the
inner neighbour-selection is ``const`` (topology) while the outer value load is
``continuous`` (it touches state ``u``). Operationally this is just ``max`` over
a node's children — no special case is needed; the split is a *consequence* of
classing the index sub-expressions as ordinary inputs.

The frontier cut and materialization points
============================================

Wherever a lower-cadence child feeds a higher-cadence parent, the maximal
lower-cadence sub-DAG below that edge is a **materialization point** — evaluated
in its phase, stored in a buffer, and referenced by the parent. With three
classes the cut fires at two thresholds: ``const → {discrete, continuous}`` folds
once into the artifact; ``discrete → continuous`` materialises into a per-event
buffer the hot path reads as a constant. A bare scalar-constant *leaf* feeding a
higher-cadence parent is **not** a materialization point — it inlines as a
literal (the pre-existing constant-fold). A whole equation whose RHS classifies
``const``/``discrete`` folds out of the hot path entirely — a top-level
**output buffer** (the observed-variable elimination that makes a pure-topology
rule's hot tree empty).

Topology FAQs (``distinct`` / ``skolem`` / ``rank``) fold via the build-time
relational engine (:mod:`earthsci_toolkit.relational`) in the ``const`` /
``discrete`` phase — *never* on the hot path.

The guards (checked, not hoped for)
===================================

1. **Acyclicity** — the ``≤ discrete`` sub-DAG (derived index set ``--from_faq->``
   node ``--ranges{from}->`` set) MUST be acyclic; a cycle is an implicit/
   iterative solve, out of scope. Rejected naming the cycle.
2. **No relational engine on the hot path** — a ``distinct`` / ``join`` /
   ``skolem`` / ``rank`` node that classifies ``continuous`` is rejected;
   state-dependent topology may not run per step in v1.
3. **Author assertion** — an ``expect_cadence`` annotation that disagrees with
   the derived class is an error (changes no semantics).

Conformance
===========

The classification is a compile-time property, so the cross-binding contract is
asserted **directly**: every binding MUST agree on each node's class, the *set*
of materialization points, and the **byte-identical** ``const``-folded buffers.
The Python producer is :mod:`earthsci_toolkit.cli.cadence_adapter`; the golden is
``tests/conformance/cadence/manifest.json`` and the runner
``scripts/run-cadence-conformance.py``. The §5.2 "minor formatting" tolerances do
**not** apply here.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from typing import Any, Dict, Iterator, List, Mapping, Optional, Sequence

from .relational import FloatKeyError, distinct, rank, skolem, skolem_edge

__all__ = [
    "CadenceError",
    "CLASS_ORDER",
    "RELATIONAL_OPS",
    "cadence_join",
    "seed_leaf",
    "classify",
    "check_expect_cadence",
    "tally_classes",
    "materialization_frontier",
    "has_continuous",
    "assert_no_continuous_relational",
    "assert_acyclic_index_sets",
    "fold_to_zero_based",
    "fold_identity",
    "fold_edge_enumeration",
    "fold_rank",
    "compute_fold",
    "canonical_serialize",
    "model_from_doc",
    "model_rhs_nodes",
    "MaterializationPoint",
    "Partition",
    "partition",
]


# The cadence lattice (CONFORMANCE_SPEC.md §5.7): const ⊏ discrete ⊏ continuous.
# ``class(node) = max`` over inputs is the lattice join.
CLASS_ORDER = ("const", "discrete", "continuous")
_CLASS_RANK = {name: i for i, name in enumerate(CLASS_ORDER)}

# The relational / value-invention ops that may not run on the hot path (§5.7
# guard 2): one classifying ``continuous`` is a hard error. Includes the
# arg-witness reducers (``argmin`` / ``argmax``, §5.7 rule 6) — a state-dependent
# assignment is out of scope for v1, exactly like a state-dependent ``distinct``.
RELATIONAL_OPS = frozenset({"distinct", "join", "skolem", "rank", "argmin", "argmax"})


class CadenceError(Exception):
    """A cadence-partition contract violation in a model or producer output."""


# === Classification: leaf seed + max-propagation + the gather rule ==========


def cadence_join(*classes: str) -> str:
    """The lattice join (``max``) over cadence classes — the §5.7 propagation
    rule. The empty join is ``const`` (the bottom of the lattice)."""
    if not classes:
        return "const"
    return CLASS_ORDER[max(_CLASS_RANK[c] for c in classes)]


def _loader_without_temporal(var: Mapping[str, Any], model: Mapping[str, Any]) -> bool:
    """True iff ``var`` is a discrete variable whose ``data_ingest`` refresh names
    a DataLoader — found in the document's top-level ``data_loaders``, attached to
    the model by :func:`model_from_doc` — that declares no ``temporal`` block.
    Such a loader describes non-time-varying data, so its output variable seeds
    ``const`` (folds at bind), not ``discrete`` (RFC pure-io-data-loaders §4.6 /
    §5.7.2)."""
    refresh = var.get("refresh")
    if not isinstance(refresh, Mapping) or refresh.get("kind") != "data_ingest":
        return False
    loaders = model.get("data_loaders") or {}
    loader = loaders.get(refresh.get("source"))
    return isinstance(loader, Mapping) and "temporal" not in loader


def seed_leaf(leaf: Any, model: Mapping[str, Any]) -> str:
    """Seed a leaf's cadence from its declared role (§5.7 leaf-seed table).

    ``state`` / the independent variable ``t`` → ``continuous`` (an explicit
    continuous-``t`` forcing is not piecewise-constant between events, so it may
    not be classed ``discrete``); ``discrete`` variable → ``discrete``;
    ``parameter`` / numeric literal / index-set name / bound index symbol →
    ``const``. ``brownian`` seeds ``continuous`` (a per-step noise channel).
    """
    if isinstance(leaf, bool):
        # ``bool`` is an ``int`` subclass; a boolean literal is a CONST scalar.
        return "const"
    if isinstance(leaf, (int, float)):
        return "const"
    if not isinstance(leaf, str):
        raise CadenceError(f"unexpected leaf {leaf!r}")
    if leaf == "t":
        return "continuous"
    variables = model.get("variables", {}) or {}
    if leaf in variables:
        kind = variables[leaf].get("type")
        if kind in ("state", "brownian"):
            return "continuous"
        if kind == "discrete":
            # Loader-seeded cadence refinement (§5.7.2): a discrete variable fed
            # by a ``data_ingest`` refresh whose source loader has no ``temporal``
            # block is non-time-varying and seeds ``const`` (folds at bind). With
            # ``temporal`` (or any other trigger / unresolvable source) it keeps
            # the declared ``discrete`` seed and refreshes on each ingest event.
            return "const" if _loader_without_temporal(variables[leaf], model) else "discrete"
        if kind in ("parameter", "observed"):
            # parameter = CONST. An ``observed`` leaf resolves to its defining
            # expression's class elsewhere; none of the §6.1 fixtures read an
            # observed as a leaf, so CONST is the conservative seed here.
            return "const"
        raise CadenceError(f"leaf {leaf!r}: unknown variable kind {kind!r}")
    # index-set name, bound index symbol (i, k, e, f, le), relation tag
    # ("edge"), or numeric-string literal — all CONST.
    return "const"


def child_exprs(node: Mapping[str, Any]) -> Iterator[Any]:
    """Yield every sub-Expression of a node: the operand list ``args`` plus the
    aggregate/integral value sub-fields. ``output_idx``, ``ranges``, ``wrt``,
    ``dim``, ``var`` are index/metadata declarations (const), not value inputs,
    so they are intentionally excluded — this is what makes the gather rule fall
    out of a plain ``max`` over children."""
    for a in node.get("args", []) or []:
        yield a
    for field_name in ("expr", "key", "filter", "lower", "upper"):
        if field_name in node:
            yield node[field_name]


def classify(node: Any, model: Mapping[str, Any]) -> str:
    """Derive a node's cadence class. For a leaf, seed it. For an operator node,
    ``class = max`` over child classes — which, for a gather ``index(A, e…)``, is
    ``max(class(A), class(e…))``: the index expressions are classed
    **independently** of the array, so a stencil splits (§5.7 gather rule)."""
    if not isinstance(node, Mapping):
        return seed_leaf(node, model)
    child_classes = [classify(c, model) for c in child_exprs(node)]
    return cadence_join(*child_classes)


def check_expect_cadence(node: Any, model: Mapping[str, Any], problems: List[str]) -> None:
    """Walk the tree; wherever a node carries ``expect_cadence``, assert the
    derived class agrees (§5.7 guard 3 — the author assertion)."""
    if not isinstance(node, Mapping):
        return
    if "expect_cadence" in node:
        derived = classify(node, model)
        want = node["expect_cadence"]
        if derived != want:
            problems.append(
                f"expect_cadence mismatch on op={node.get('op')!r}: "
                f"declared {want!r} but derived {derived!r}"
            )
    for c in child_exprs(node):
        check_expect_cadence(c, model, problems)


def tally_classes(node: Any, model: Mapping[str, Any], counts: Dict[str, int]) -> None:
    """Count **annotated** nodes (those carrying ``expect_cadence``) by derived
    class — the golden ``class_summary``."""
    if not isinstance(node, Mapping):
        return
    if "expect_cadence" in node:
        cls = classify(node, model)
        counts[cls] = counts.get(cls, 0) + 1
    for c in child_exprs(node):
        tally_classes(c, model, counts)


# === The frontier cut and materialization points ===========================


@dataclass(frozen=True)
class MaterializationPoint:
    """One point where the frontier cut fires.

    ``threshold`` is the cadence drop (``const->continuous``,
    ``discrete->continuous``, or ``const->artifact`` for a top-level output
    buffer) — the runner compares the threshold **multiset**. ``kind`` is
    ``expr_edge`` (an internal cut inside a hot tree) or ``output_buffer`` (a
    whole equation folded out of the hot path). ``label`` / ``produces`` are
    diagnostic.
    """

    threshold: str
    kind: str
    label: Optional[str] = None
    op: Optional[str] = None
    produces: Optional[str] = None

    def as_dict(self) -> Dict[str, Any]:
        out: Dict[str, Any] = {"threshold": self.threshold, "kind": self.kind}
        if self.label is not None:
            out["label"] = self.label
        if self.op is not None:
            out["op"] = self.op
        if self.produces is not None:
            out["produces"] = self.produces
        return out


def materialization_frontier(
    node: Mapping[str, Any], model: Mapping[str, Any], out: List[MaterializationPoint]
) -> None:
    """Derive the expr-edge materialization frontier inside a kept (continuous)
    tree: a DICT child whose class is strictly lower than its parent's is a
    materialization point. The maximal lower-cadence sub-DAG below that edge is
    cut, stored in a buffer, and referenced by the parent — so we record the
    boundary node and do **not** recurse into it (its descendants are inside the
    buffer). A bare scalar-constant *leaf* is not a buffer, so scalar inlining is
    correctly excluded (only ``Mapping`` children are considered)."""
    parent = classify(node, model)
    for c in child_exprs(node):
        if not isinstance(c, Mapping):
            continue
        cc = classify(c, model)
        if _CLASS_RANK[cc] < _CLASS_RANK[parent]:
            out.append(
                MaterializationPoint(
                    threshold=f"{cc}->{parent}", kind="expr_edge", op=c.get("op")
                )
            )
        else:
            materialization_frontier(c, model, out)


def has_continuous(node: Any, model: Mapping[str, Any]) -> bool:
    """True if any node in the tree classifies ``continuous`` (the per-step hot
    tree is non-empty)."""
    if isinstance(node, Mapping):
        if classify(node, model) == "continuous":
            return True
        return any(has_continuous(c, model) for c in child_exprs(node))
    return seed_leaf(node, model) == "continuous"


# === The guards =============================================================


def assert_no_continuous_relational(node: Any, model: Mapping[str, Any]) -> None:
    """§5.7 guard 2: a ``distinct`` / ``join`` / ``skolem`` / ``rank`` node (or a
    ``distinct`` aggregate) that classifies ``continuous`` is rejected —
    state-dependent topology may not run on the hot path in v1."""
    if not isinstance(node, Mapping):
        return
    op = node.get("op")
    is_relational = op in RELATIONAL_OPS or (op == "aggregate" and node.get("distinct"))
    if is_relational and classify(node, model) == "continuous":
        raise CadenceError(
            f"relational/value-invention node op={op!r} classifies CONTINUOUS — "
            "it may not run on the hot path (§5.7 guard 2). A state-dependent "
            "distinct/join/skolem/rank is out of scope for v1."
        )
    for c in child_exprs(node):
        assert_no_continuous_relational(c, model)


def assert_acyclic_index_sets(model: Mapping[str, Any]) -> None:
    """§5.7 guard 1: the ``≤ discrete`` sub-DAG must be acyclic. A derived index
    set points (via ``from_faq``) at the node that materialises it; that node
    references index sets (via ``ranges {from}``); a cycle in those edges is an
    implicit/iterative solve, out of scope. Reject naming the cycle."""
    index_sets = model.get("index_sets", {}) or {}
    node_reads: Dict[str, set] = {}

    def collect(node: Any) -> None:
        if not isinstance(node, Mapping):
            return
        nid = node.get("id")
        if nid:
            reads = node_reads.setdefault(nid, set())
            for r in (node.get("ranges") or {}).values():
                if isinstance(r, Mapping) and "from" in r:
                    reads.add(r["from"])
        for c in child_exprs(node):
            collect(c)

    for eq in model.get("equations", []) or []:
        collect(eq.get("lhs"))
        collect(eq.get("rhs"))

    # Edges: set --(from_faq)--> node --(reads)--> set.
    set_to_node = {
        name: s["from_faq"]
        for name, s in index_sets.items()
        if s.get("kind") == "derived" and s.get("from_faq")
    }

    WHITE, GRAY, BLACK = 0, 1, 2
    color: Dict[str, int] = {}

    def visit(name: str, stack: List[str]) -> None:
        color[name] = GRAY
        stack.append(name)
        node_id = set_to_node.get(name)
        for nxt in node_reads.get(node_id, set()):
            if nxt not in set_to_node:
                continue  # only derived sets participate in the topology DAG
            if color.get(nxt, WHITE) == GRAY:
                cyc = stack[stack.index(nxt):] + [nxt]
                raise CadenceError(
                    "cycle in the ≤DISCRETE index-set dependency graph "
                    "(implicit solve, out of scope — §5.7 guard 1): "
                    f"{' -> '.join(cyc)}"
                )
            if color.get(nxt, WHITE) == WHITE:
                visit(nxt, stack)
        stack.pop()
        color[name] = BLACK

    for name in set_to_node:
        if color.get(name, WHITE) == WHITE:
            visit(name, [])


# === CONST-fold kernels (topology FAQs via the relational engine) ===========


def canonical_serialize(value: Any) -> str:
    """The canonical byte form of a folded buffer: compact JSON (``,`` / ``:``
    separators, no spaces), UTF-8 (no ``\\uXXXX``), arrays for tuples — the same
    canonical-JSON discipline §5.5.3 / the round-trip contract require. This is
    what "byte-identical CONST-folded buffer" means."""
    return json.dumps(value, separators=(",", ":"), ensure_ascii=False)


def fold_to_zero_based(arr: Sequence[Sequence[int]]) -> List[List[int]]:
    """Fold a 1-based neighbour-index table into the 0-based buffer the hot path
    reads as a constant (``index(nbr, i, k)`` topology gather)."""
    return [[x - 1 for x in row] for row in arr]


def fold_identity(arr: Sequence[Sequence[int]]) -> List[List[int]]:
    """Fold an already-canonical coefficient table — identity, but materialised
    as the per-edge buffer baked into the artifact."""
    return [list(row) for row in arr]


def _edge_keys(face_lo: Sequence[Sequence[int]], face_hi: Sequence[Sequence[int]], mode: str):
    """Mint the canonical Skolem key for every face-local edge via the relational
    engine (``skolem_edge`` for undirected, ``skolem`` for directed). Float
    components are rejected (§5.5.1 rule 1) — surfaced as a :class:`CadenceError`
    (a float topology key, §5.7)."""
    keys = []
    try:
        for f_lo, f_hi in zip(face_lo, face_hi):
            for lo, hi in zip(f_lo, f_hi):
                if mode == "undirected":
                    keys.append(skolem_edge(lo, hi))
                else:
                    keys.append(skolem((lo, hi)))
    except FloatKeyError as e:
        raise CadenceError(f"float component forbidden in a topology key (§5.5 rule 1): {e}") from e
    return keys


def fold_edge_enumeration(
    face_lo: Sequence[Sequence[int]], face_hi: Sequence[Sequence[int]], mode: str
) -> List[List[int]]:
    """Enumerate the unique edges from the (lo, hi) endpoint tables through the
    build-time relational engine: ``skolem`` canonicalises each pair, ``distinct``
    sorts by the §5.5 total order and drops adjacent duplicates. Identical to the
    determinism ``edge_enumeration`` golden."""
    keys = _edge_keys(face_lo, face_hi, mode)
    return [list(t) for t in distinct(keys)]


def fold_rank(
    face_lo: Sequence[Sequence[int]], face_hi: Sequence[Sequence[int]], mode: str
) -> List[int]:
    """Dense 0-based ids over the deduped edge set via the relational engine's
    ``rank`` (Python's native 0-based numbering, §5.5.1 rule 3)."""
    keys = _edge_keys(face_lo, face_hi, mode)
    ranking = rank(keys)  # native 0-based
    return [ranking.ids[t] for t in ranking.order]


def compute_fold(label: str, spec: Mapping[str, Any], inputs: Mapping[str, Any]) -> List[Any]:
    """Dispatch a CONST-fold kernel by its declared ``fold`` kind, over the
    document-literal ``inputs``."""
    kind = spec.get("fold")
    if kind == "to_zero_based":
        return fold_to_zero_based(inputs[spec.get("array", label)])
    if kind == "identity":
        return fold_identity(inputs[spec.get("array", label)])
    if kind == "edge_enumeration":
        return fold_edge_enumeration(
            inputs["face_lo"], inputs["face_hi"], inputs.get("skolem", "undirected")
        )
    if kind == "rank":
        return fold_rank(
            inputs["face_lo"], inputs["face_hi"], inputs.get("skolem", "undirected")
        )
    raise CadenceError(f"buffer {label!r}: unknown fold kind {kind!r}")


# === The pass ===============================================================


def model_from_doc(doc: Mapping[str, Any], model_name: str) -> Dict[str, Any]:
    """Extract the named model from a parsed ``.esm`` document, attaching the
    document's top-level ``data_loaders`` so the loader-seeded cadence refinement
    (§5.7.2) can resolve a ``discrete`` variable's ``data_ingest`` source loader.

    Returns a shallow copy with ``data_loaders`` added (the parsed document is
    left unmutated). Raises :class:`CadenceError` if the model is absent."""
    models = doc.get("models", {}) or {}
    if model_name not in models:
        raise CadenceError(f"model {model_name!r} not found")
    model = models[model_name]
    loaders = doc.get("data_loaders")
    if loaders and "data_loaders" not in model:
        model = {**model, "data_loaders": loaders}
    return model


def model_rhs_nodes(model: Mapping[str, Any]) -> Iterator[Mapping[str, Any]]:
    """Yield every equation-RHS root expression of a model (the computations the
    partition classifies; the LHS is the output target)."""
    for eq in model.get("equations", []) or []:
        rhs = eq.get("rhs")
        if isinstance(rhs, Mapping):
            yield rhs


def _lhs_target(lhs: Any) -> Optional[str]:
    """The variable an equation assigns: ``index(var, …)`` → ``var``; a bare name
    → itself. Used to label an output-buffer materialization point."""
    if isinstance(lhs, str):
        return lhs
    if isinstance(lhs, Mapping):
        args = lhs.get("args") or []
        if args and isinstance(args[0], str):
            return args[0]
        if isinstance(lhs.get("output_idx"), list):
            # an LHS aggregate over D(u[i])/dt — the target is inside its expr
            return None
    return None


def _produced_index_set(node_id: Optional[str], index_sets: Mapping[str, Any]) -> Optional[str]:
    """The derived index set this node materialises (``edges.from_faq == id``)."""
    if not node_id:
        return None
    for name, spec in (index_sets or {}).items():
        if spec.get("kind") == "derived" and spec.get("from_faq") == node_id:
            return name
    return None


@dataclass
class Partition:
    """The result of the cadence-partition pass over one model.

    - ``class_summary`` — annotated nodes counted by derived class.
    - ``materialization_points`` — where the frontier cut fires (expr-edge cuts
      inside the hot tree + whole-equation output buffers folded out of it).
    - ``hot_tree_empty`` — no node classifies ``continuous`` (a pure-topology
      rule contributes nothing to the per-step RHS).
    - ``event_handler_empty`` — nothing materialises at the ``discrete`` cadence.
    """

    class_summary: Dict[str, int]
    materialization_points: List[MaterializationPoint] = field(default_factory=list)
    hot_tree_empty: bool = True
    event_handler_empty: bool = True

    @property
    def thresholds(self) -> List[str]:
        """The materialization threshold multiset (sorted) — the conformance key."""
        return sorted(mp.threshold for mp in self.materialization_points)


def partition(model: Mapping[str, Any]) -> Partition:
    """Run the cadence-partition pass over a parsed model.

    Classifies every node by the cadence lattice (``max``-propagation + the
    gather rule), derives the materialization frontier at both thresholds,
    checks the three guards (acyclicity / no continuous relational /
    ``expect_cadence`` agreement), and reports the class summary and the
    hot-tree / per-event-handler emptiness. Raises :class:`CadenceError` on any
    guard violation. The CONST-folded *buffers* are produced separately via
    :func:`compute_fold` (they need the document-literal inputs).
    """
    index_sets = model.get("index_sets", {}) or {}

    # Guard 1: the ≤DISCRETE index-set sub-DAG is acyclic.
    assert_acyclic_index_sets(model)

    counts: Dict[str, int] = {name: 0 for name in CLASS_ORDER}
    points: List[MaterializationPoint] = []
    problems: List[str] = []
    hot_empty = True

    for eq in model.get("equations", []) or []:
        rhs = eq.get("rhs")
        if not isinstance(rhs, Mapping):
            continue

        # Guards 2 & 3, plus the class summary, walk the RHS tree.
        assert_no_continuous_relational(rhs, model)
        check_expect_cadence(rhs, model, problems)
        tally_classes(rhs, model, counts)

        rhs_class = classify(rhs, model)
        if rhs_class == "continuous":
            hot_empty = False
            # Internal frontier cuts inside the kept hot tree.
            materialization_frontier(rhs, model, points)
        else:
            # The whole output folds out of the hot path → an output buffer
            # (``const``/``discrete`` → artifact). This is the observed-variable
            # elimination that empties a pure-topology rule's hot tree.
            node_id = rhs.get("id")
            produces = _produced_index_set(node_id, index_sets)
            points.append(
                MaterializationPoint(
                    threshold=f"{rhs_class}->artifact",
                    kind="output_buffer",
                    label=node_id or _lhs_target(eq.get("lhs")),
                    op=rhs.get("op"),
                    produces=produces,
                )
            )

    if problems:
        raise CadenceError("; ".join(problems))

    event_handler_empty = not any(
        mp.threshold.startswith("discrete") for mp in points
    )

    return Partition(
        class_summary=counts,
        materialization_points=points,
        hot_tree_empty=hot_empty,
        event_handler_empty=event_handler_empty,
    )
