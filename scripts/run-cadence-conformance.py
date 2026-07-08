#!/usr/bin/env python3
"""
Cross-binding cadence-partition conformance runner (ess-my4.3.6).

Backs the normative dependency-partition (cadence) contract in
CONFORMANCE_SPEC.md §5.7 (RFC semiring-faq-unified-ir §6.1) with an executable
harness. The partition pass classifies every node by the CADENCE at which its
value can change — const ⊏ discrete ⊏ continuous, class(node) = max over inputs
— and schedules each class into its own phase (folded artifact / per-event
handler / hot per-step tree). Two bindings that disagree on a node's class, on
the SET of materialization points, or on the bytes of a CONST-folded buffer
produce *different models*. This runner asserts they do not.

Two phases, one harness (mirrors run-determinism-conformance.py):

  * NOW (skeleton): `--self-test` runs an embedded REFERENCE classifier + folder
    over the static golden (tests/conformance/cadence/manifest.json) and the
    three §6.1 fixtures (tests/valid/cadence/*.esm), asserting that (a) the
    reference-derived class of every annotated node equals both the node's own
    `expect_cadence` assertion and the golden class summary; (b) the
    materialization frontier the reference derives (cadence drops across
    expression edges) matches the golden materialization-point set, and the
    hot-tree / per-event-handler emptiness matches; (c) the CONST-folded buffers
    the reference computes serialize byte-for-byte to the golden; and (d) the
    guards actually REJECT non-conforming input (negative controls: a wrong
    expect_cadence, a CONTINUOUS relational node, a from_faq cycle). Runs green
    before any partition-pass producer exists.

  * LATER (ess-my4.3.7 Julia partition pass + Rust/Python siblings): each binding
    ships a thin adapter registered via $EARTHSCI_CADENCE_ADAPTER_<BINDING> (or
    on PATH as earthsci-cadence-adapter-<binding>). The default run mode invokes
    each adapter on the same manifest and asserts its class map, materialization
    set, and CONST-folded buffers are identical to the golden and to each other.
    Populate `bindings_required` in the manifest as producers land.

See tests/conformance/cadence/README.md for the adapter contract.

Usage:
    python scripts/run-cadence-conformance.py --self-test
    python scripts/run-cadence-conformance.py \\
        --manifest tests/conformance/cadence/manifest.json \\
        --output  conformance-results/cadence/report.json \\
        [--bindings julia,rust,python]

Exit codes:
    0  self-test passed, or every required binding matched the golden
    1  a contract violation / mismatch (or self-test failed)
    2  manifest / config error (no run attempted)
"""

from __future__ import annotations

import copy
import json
import sys
from pathlib import Path
from typing import Any

# The shared harness (manifest loading, adapter dispatch, CLI skeleton) lives
# in scripts/conformance_lib.py; hyphenated runner filenames cannot import
# each other, so put scripts/ on sys.path first.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from conformance_lib import (  # noqa: E402 — needs the sys.path bootstrap above
    KNOWN_BINDINGS,
    REPO_ROOT,
    AdapterHarness,
    ManifestError,
    _eprint,
    build_parser,
    cli_main,
    print_summary,
    write_report,
)
from conformance_lib import load_manifest as _load_manifest  # noqa: E402

DEFAULT_MANIFEST = REPO_ROOT / "tests" / "conformance" / "cadence" / "manifest.json"

# Adapter addressing: $EARTHSCI_CADENCE_ADAPTER_<BINDING> or
# earthsci-cadence-adapter-<binding> on PATH.
_ADAPTERS = AdapterHarness("cadence")

# The cadence lattice (CONFORMANCE_SPEC.md §5.7): const ⊏ discrete ⊏ continuous.
# class(node) = max over inputs is the lattice join.
CLASS_RANK = {"const": 0, "discrete": 1, "continuous": 2}
RANK_CLASS = {v: k for k, v in CLASS_RANK.items()}

# The relational / value-invention ops that may not run on the hot path (§5.7
# guard 2): one classifying CONTINUOUS is a hard error.
RELATIONAL_OPS = {"distinct", "join", "skolem", "rank"}


# === The reference classifier + folder ====================================
#
# This is the contract as code: the leaf-seed + max-propagation + gather rule
# the §5.7 partition derives every node's class from, plus the CONST-fold
# kernels. Producers in every binding MUST reproduce these classes, this
# materialization set, and these folded bytes. Nothing here may depend on
# declaration order or a language-native hash (ties to §5.5).


class CadenceError(Exception):
    """A cadence-partition contract violation in a fixture or producer output."""


def _join(*classes: str) -> str:
    """The lattice join (max) over cadence classes — the §5.7 propagation rule."""
    return RANK_CLASS[max(CLASS_RANK[c] for c in classes)] if classes else "const"


def _loader_without_temporal(var: dict, model: dict) -> bool:
    """True iff `var` is a discrete variable whose `data_ingest` refresh names a
    DataLoader — found in the document's top-level `data_loaders`, attached to the
    model by `load_model` — that declares no `temporal` block. Such a loader
    describes non-time-varying data, so its output variable seeds CONST (folds at
    bind), not DISCRETE (RFC pure-io-data-loaders §4.6 / §5.7.2)."""
    refresh = var.get("refresh")
    if not isinstance(refresh, dict) or refresh.get("kind") != "data_ingest":
        return False
    loaders = model.get("data_loaders") or {}
    loader = loaders.get(refresh.get("source"))
    return isinstance(loader, dict) and "temporal" not in loader


def seed_leaf(leaf: Any, model: dict) -> str:
    """Seed a leaf's cadence from its declared role (§5.7 leaf-seed table):
    state → continuous, parameter/literal → const, discrete → discrete. The
    independent variable `t` is continuous (an explicit continuous-t forcing is
    not piecewise-constant between events). Index-set names are CONST topology;
    bound index symbols, numeric literals, and relation-name tags are CONST."""
    if isinstance(leaf, (int, float)) and not isinstance(leaf, bool):
        return "const"
    if not isinstance(leaf, str):
        raise CadenceError(f"unexpected leaf {leaf!r}")
    if leaf == "t":
        return "continuous"
    variables = model.get("variables", {})
    if leaf in variables:
        kind = variables[leaf].get("type")
        if kind == "state":
            return "continuous"
        if kind == "discrete":
            # Loader-seeded cadence refinement (RFC pure-io-data-loaders §4.6 /
            # §5.7.2): a discrete variable fed by a `data_ingest` refresh whose
            # source DataLoader declares no `temporal` block is non-time-varying
            # and seeds CONST (folds at bind). With `temporal` (or any other
            # trigger / an unresolvable source) it keeps the declared DISCRETE
            # seed and refreshes on each ingest event.
            if _loader_without_temporal(variables[leaf], model):
                return "const"
            return "discrete"
        if kind == "brownian":
            return "continuous"
        if kind in ("parameter", "observed"):
            # parameter = CONST. observed leaves resolve to their defining
            # expression's class elsewhere; none of the §6.1 fixtures read an
            # observed as a leaf, so CONST is the conservative seed here.
            return "const"
        raise CadenceError(f"leaf {leaf!r}: unknown variable kind {kind!r}")
    # index-set name, bound index symbol (i, k, e, f, le), relation tag
    # ("edge"), or numeric-string literal — all CONST.
    return "const"


def _child_exprs(node: dict):
    """Yield every sub-Expression of a node: the operand list `args` plus the
    aggregate/integral sub-fields. `output_idx`, `ranges`, `wrt`, `dim`, `var`
    are index/metadata declarations (const), not value inputs."""
    for a in node.get("args", []) or []:
        yield a
    for field in ("expr", "key", "filter", "lower", "upper"):
        if field in node:
            yield node[field]


def classify(node: Any, model: dict) -> str:
    """Derive a node's cadence class. For a leaf, seed it. For an operator node,
    class = max over child classes — which, for a gather index(A, e…), is
    max(class(A), class(e…)): the index expressions are classed INDEPENDENTLY of
    the array, so a stencil splits (§5.7 gather rule)."""
    if not isinstance(node, dict):
        return seed_leaf(node, model)
    child_classes = [classify(c, model) for c in _child_exprs(node)]
    return _join(*child_classes) if child_classes else "const"


def check_expect_cadence(node: Any, model: dict, problems: list) -> None:
    """Walk the tree; wherever a node carries `expect_cadence`, assert the
    derived class agrees (§5.7 guard 3 — the author assertion)."""
    if not isinstance(node, dict):
        return
    if "expect_cadence" in node:
        derived = classify(node, model)
        want = node["expect_cadence"]
        if derived != want:
            problems.append(
                f"expect_cadence mismatch on op={node.get('op')!r}: "
                f"declared {want!r} but derived {derived!r}"
            )
    for c in _child_exprs(node):
        check_expect_cadence(c, model, problems)


def tally_classes(node: Any, model: dict, counts: dict) -> None:
    """Count annotated nodes by derived class (for the golden class_summary)."""
    if not isinstance(node, dict):
        return
    if "expect_cadence" in node:
        counts[classify(node, model)] = counts.get(classify(node, model), 0) + 1
    for c in _child_exprs(node):
        tally_classes(c, model, counts)


def materialization_frontier(node: dict, model: dict, out: list) -> None:
    """Derive the expr-edge materialization frontier: a DICT child whose class is
    strictly lower than its parent's is a materialization point (the maximal
    lower-cadence sub-DAG below that edge is cut, stored in a buffer, referenced
    by the parent). We record the boundary node and do NOT recurse into it — its
    descendants are inside the buffer. A bare scalar-constant LEAF is not a
    buffer, so scalar inlining is correctly excluded."""
    parent = classify(node, model)
    for c in _child_exprs(node):
        if not isinstance(c, dict):
            continue
        cc = classify(c, model)
        if CLASS_RANK[cc] < CLASS_RANK[parent]:
            out.append({"threshold": f"{cc}->{parent}", "op": c.get("op")})
        else:
            materialization_frontier(c, model, out)


def has_continuous(node: Any, model: dict) -> bool:
    if isinstance(node, dict):
        if classify(node, model) == "continuous":
            return True
        return any(has_continuous(c, model) for c in _child_exprs(node))
    return seed_leaf(node, model) == "continuous"


def assert_no_continuous_relational(node: Any, model: dict) -> None:
    """§5.7 guard 2: a distinct/join/skolem/rank node (or a distinct aggregate)
    that classifies CONTINUOUS is rejected — state-dependent topology may not run
    per step in v1."""
    if not isinstance(node, dict):
        return
    op = node.get("op")
    is_relational = op in RELATIONAL_OPS or (op == "aggregate" and node.get("distinct"))
    if is_relational and classify(node, model) == "continuous":
        raise CadenceError(
            f"relational/value-invention node op={op!r} classifies CONTINUOUS — "
            "it may not run on the hot path (§5.7 guard 2). A state-dependent "
            "distinct/join/skolem/rank is out of scope for v1."
        )
    for c in _child_exprs(node):
        assert_no_continuous_relational(c, model)


def assert_acyclic_index_sets(model: dict) -> None:
    """§5.7 guard 1: the ≤DISCRETE subgraph must be a DAG. A derived index set
    points (via from_faq) at the node that materializes it; that node references
    index sets (via ranges {from}); a cycle in those edges is an implicit/
    iterative solve, out of scope. Reject naming the cycle."""
    index_sets = model.get("index_sets", {})
    # Map each aggregate node id → the index sets it reads (ranges {from}).
    node_reads: dict[str, set] = {}

    def collect(node: Any) -> None:
        if not isinstance(node, dict):
            return
        nid = node.get("id")
        if nid:
            reads = node_reads.setdefault(nid, set())
            for r in (node.get("ranges") or {}).values():
                if isinstance(r, dict) and "from" in r:
                    reads.add(r["from"])
        for c in _child_exprs(node):
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

    # Detect a cycle over set → from_faq node → read sets → …
    WHITE, GRAY, BLACK = 0, 1, 2
    color: dict[str, int] = {}

    def visit(name: str, stack: list) -> None:
        color[name] = GRAY
        stack.append(name)
        node_id = set_to_node.get(name)
        for nxt in node_reads.get(node_id, set()):
            if nxt not in set_to_node:
                continue  # only derived sets participate in the topology DAG
            if color.get(nxt, WHITE) == GRAY:
                cyc = stack[stack.index(nxt) :] + [nxt]
                raise CadenceError(
                    "cycle in the ≤DISCRETE index-set dependency graph "
                    f"(implicit solve, out of scope — §5.7 guard 1): "
                    f"{' -> '.join(cyc)}"
                )
            if color.get(nxt, WHITE) == WHITE:
                visit(nxt, stack)
        stack.pop()
        color[name] = BLACK

    for name in set_to_node:
        if color.get(name, WHITE) == WHITE:
            visit(name, [])


# --- CONST-fold kernels ----------------------------------------------------


def canonical_serialize(value: Any) -> str:
    """The canonical byte form of a folded buffer: compact JSON (',' / ':'
    separators, no spaces), UTF-8 (no \\uXXXX), arrays for tuples — the same
    canonical-JSON discipline §5.5.3 / the round-trip contract require. This is
    what 'byte-identical CONST-folded buffer' means."""
    return json.dumps(value, separators=(",", ":"), ensure_ascii=False)


def fold_to_zero_based(arr: list) -> list:
    return [[x - 1 for x in row] for row in arr]


def fold_identity(arr: list) -> list:
    return arr


def fold_edge_enumeration(face_lo: list, face_hi: list, mode: str) -> list:
    """Enumerate the unique edges from the (lo, hi) endpoint tables: skolem
    canonicalizes each pair (undirected → sorted), distinct sorts by the total
    order and drops adjacent duplicates (§5.5 rules 2 & 4). Identical to the
    determinism edge_enumeration reference."""
    pairs = []
    for f_lo, f_hi in zip(face_lo, face_hi):
        for lo, hi in zip(f_lo, f_hi):
            if isinstance(lo, float) or isinstance(hi, float):
                raise CadenceError("float component forbidden in a topology key (§5.5 rule 1)")
            pairs.append(tuple(sorted((lo, hi))) if mode == "undirected" else (lo, hi))
    ordered = sorted(pairs)
    out: list = []
    for t in ordered:
        if not out or out[-1] != list(t):
            out.append(list(t))
    return out


def fold_rank(seq: list) -> list:
    return list(range(len(seq)))


def compute_fold(label: str, spec: dict, inputs: dict) -> list:
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
        edges = fold_edge_enumeration(
            inputs["face_lo"], inputs["face_hi"], inputs.get("skolem", "undirected")
        )
        return fold_rank(edges)
    raise CadenceError(f"buffer {label!r}: unknown fold kind {kind!r}")


# === Manifest / fixture loading ===========================================


def load_manifest(path: Path) -> dict:
    return _load_manifest(
        path,
        categories=("cadence_partition_conformance",),
        fixture_fields=("fixture", "model", "class_summary", "materialization_points"),
    )


def load_model(repo_root: Path, fixture_rel: str, model_name: str) -> dict:
    doc = json.loads((repo_root / fixture_rel).read_text())
    models = doc.get("models", {})
    if model_name not in models:
        raise CadenceError(f"{fixture_rel}: model {model_name!r} not found")
    model = models[model_name]
    # Attach the document's top-level `data_loaders` so the loader-seeded cadence
    # refinement (§5.7.2) can resolve a `discrete` variable's `data_ingest`
    # source loader and decide DISCRETE (temporal) vs CONST (no temporal).
    loaders = doc.get("data_loaders")
    if loaders and "data_loaders" not in model:
        model = {**model, "data_loaders": loaders}
    # Attach the document's top-level `index_sets` too: in ESM v0.8.0 `index_sets`
    # moved to the document level, so the partition's structural check (which reads
    # `model["index_sets"]` to confirm an output buffer targets a declared index
    # set) needs them threaded onto the model here.
    index_sets = doc.get("index_sets")
    if index_sets and "index_sets" not in model:
        model = {**model, "index_sets": index_sets}
    return model


def model_nodes(model: dict):
    """Yield every equation-RHS root expression of the model (the computations
    the partition classifies; the LHS is the output target)."""
    for eq in model.get("equations", []) or []:
        rhs = eq.get("rhs")
        if isinstance(rhs, dict):
            yield rhs


# === Comparison (producers, ess-my4.3.7+) =================================


def compare_to_golden(fx: dict, produced: dict) -> dict:
    """Compare one producer's partition output for one fixture to the golden:
    class summary, materialization-point threshold multiset, and byte-identical
    CONST-folded buffers."""
    problems: list = []
    if produced.get("class_summary") != fx["class_summary"]:
        problems.append(
            f"class summary differs: golden={fx['class_summary']} "
            f"got={produced.get('class_summary')}"
        )
    got_thr = sorted(m.get("threshold") for m in produced.get("materialization_points", []))
    want_thr = sorted(m["threshold"] for m in fx["materialization_points"])
    if got_thr != want_thr:
        problems.append(f"materialization thresholds differ: golden={want_thr} got={got_thr}")
    exp = (fx.get("const_fold") or {}).get("expected", {})
    got_buffers = produced.get("const_fold_buffers", {})
    for label, spec in exp.items():
        if got_buffers.get(label) != spec["serialized"]:
            problems.append(
                f"CONST-folded buffer {label!r} differs:\n"
                f"    golden={spec['serialized']!r}\n    got   ={got_buffers.get(label)!r}"
            )
    return {"match": not problems, "problems": problems}


# === Self-test (the static-example phase) =================================


def self_test(manifest_path: Path) -> int:
    if not manifest_path.is_file():
        _eprint(f"self-test: manifest missing: {manifest_path}")
        return 1
    try:
        manifest = load_manifest(manifest_path)
    except ManifestError as e:
        _eprint(f"self-test: {e}")
        return 1

    rc = 0
    # Fixture paths in the manifest are repo-root-relative.
    repo_root = REPO_ROOT
    fixtures = manifest["fixtures"]
    models: dict[str, dict] = {}

    # --- Check A: class agreement — reference == expect_cadence == golden. --
    for fx in fixtures:
        try:
            model = load_model(repo_root, fx["fixture"], fx["model"])
        except (CadenceError, OSError, json.JSONDecodeError) as e:
            rc = 1
            _eprint(f"self-test FAIL [{fx['id']}]: cannot load fixture: {e}")
            continue
        models[fx["id"]] = model

        problems: list = []
        counts: dict = {"const": 0, "discrete": 0, "continuous": 0}
        for rhs in model_nodes(model):
            check_expect_cadence(rhs, model, problems)
            tally_classes(rhs, model, counts)
        if problems:
            rc = 1
            for p in problems:
                _eprint(f"self-test FAIL [{fx['id']}/class]: {p}")
        if counts != fx["class_summary"]:
            rc = 1
            _eprint(
                f"self-test FAIL [{fx['id']}/class_summary]: "
                f"derived {counts} != golden {fx['class_summary']}"
            )
        if not problems and counts == fx["class_summary"]:
            print(
                f"self-test OK   [{fx['id']}]: class agreement "
                f"(const={counts['const']} discrete={counts['discrete']} "
                f"continuous={counts['continuous']})"
            )

    # --- Check B: materialization set + emptiness match the golden. --------
    for fx in fixtures:
        model = models.get(fx["id"])
        if model is None:
            continue
        frontier: list = []
        for rhs in model_nodes(model):
            materialization_frontier(rhs, model, frontier)
        got_thr = sorted(m["threshold"] for m in frontier)
        want_thr = sorted(
            m["threshold"] for m in fx["materialization_points"] if m.get("kind") == "expr_edge"
        )
        if got_thr != want_thr:
            rc = 1
            _eprint(
                f"self-test FAIL [{fx['id']}/materialization]: "
                f"expr-edge thresholds derived {got_thr} != golden {want_thr}"
            )
        else:
            print(f"self-test OK   [{fx['id']}]: materialization frontier {got_thr or '[]'}")

        derived_hot_empty = not any(has_continuous(rhs, model) for rhs in model_nodes(model))
        if derived_hot_empty != fx.get("hot_tree_empty"):
            rc = 1
            _eprint(
                f"self-test FAIL [{fx['id']}/hot_tree_empty]: "
                f"derived {derived_hot_empty} != golden {fx.get('hot_tree_empty')}"
            )
        derived_handler_empty = not any(
            "discrete->" in m["threshold"] for m in frontier
        ) and not any(
            m.get("threshold", "").startswith("discrete")
            for m in fx["materialization_points"]
            if m.get("kind") != "expr_edge"
        )
        if derived_handler_empty != fx.get("event_handler_empty"):
            rc = 1
            _eprint(
                f"self-test FAIL [{fx['id']}/event_handler_empty]: "
                f"derived {derived_handler_empty} != golden {fx.get('event_handler_empty')}"
            )

        # Structural check on output_buffer points: each must name a real
        # derived index set or be a real const output.
        for mp in fx["materialization_points"]:
            if mp.get("kind") == "output_buffer" and "produces" in mp:
                if mp["produces"] not in model.get("index_sets", {}):
                    rc = 1
                    _eprint(
                        f"self-test FAIL [{fx['id']}/materialization]: "
                        f"output_buffer produces {mp['produces']!r}, not a declared index set"
                    )

    # --- Check C: CONST-folded buffers serialize byte-for-byte to golden. --
    for fx in fixtures:
        cf = fx.get("const_fold") or {}
        inputs = cf.get("inputs", {})
        for label, spec in (cf.get("expected") or {}).items():
            try:
                value = compute_fold(label, spec, inputs)
                serialized = canonical_serialize(value)
            except CadenceError as e:
                rc = 1
                _eprint(f"self-test FAIL [{fx['id']}/fold:{label}]: {e}")
                continue
            if serialized != spec["serialized"]:
                rc = 1
                _eprint(
                    f"self-test FAIL [{fx['id']}/fold:{label}]: byte mismatch\n"
                    f"    golden={spec['serialized']!r}\n    got   ={serialized!r}"
                )
            elif value != spec.get("value", value):
                rc = 1
                _eprint(f"self-test FAIL [{fx['id']}/fold:{label}]: value mismatch")
            else:
                print(f"self-test OK   [{fx['id']}]: CONST-fold {label} == golden ({serialized})")

    # --- Check D: guards hold on the good fixtures (no false positives). ----
    for fx in fixtures:
        model = models.get(fx["id"])
        if model is None:
            continue
        try:
            for rhs in model_nodes(model):
                assert_no_continuous_relational(rhs, model)
            assert_acyclic_index_sets(model)
            print(f"self-test OK   [{fx['id']}]: guards pass (no continuous relational, acyclic)")
        except CadenceError as e:
            rc = 1
            _eprint(
                f"self-test FAIL [{fx['id']}/guard]: guard wrongly rejected a valid fixture: {e}"
            )

    # --- Check E: negative controls — the guards must REJECT bad input. -----
    rc |= _negative_controls(models)

    print("\nself-test:", "OK" if rc == 0 else "FAILED")
    return 1 if rc else 0


def _negative_controls(models: dict) -> int:
    rc = 0

    # E1: a wrong expect_cadence annotation must be flagged.
    base = models.get("mixed_stencil")
    if base is not None:
        bad = copy.deepcopy(base)
        flipped = any(
            _flip_first_expect_cadence(rhs, frm="const", to="continuous")
            for rhs in model_nodes(bad)
        )
        if not flipped:
            rc = 1
            _eprint("self-test FAIL [neg/expect_cadence]: could not build the negative control")
        else:
            problems: list = []
            for rhs in model_nodes(bad):
                check_expect_cadence(rhs, bad, problems)
            if problems:
                print("self-test OK   [neg/expect_cadence]: wrong expect_cadence rejected")
            else:
                rc = 1
                _eprint(
                    "self-test FAIL [neg/expect_cadence]: a wrong expect_cadence "
                    "was NOT flagged (it must be)"
                )

    # E2: a CONTINUOUS relational (distinct) node must be rejected (guard 2).
    bad_model = {
        "variables": {"u": {"type": "state"}, "lo": {"type": "parameter"}},
        "index_sets": {"faces": {"kind": "interval", "size": 4}},
        "equations": [
            {
                "lhs": {"op": "index", "args": ["edge_exists", "e"]},
                "rhs": {
                    "op": "aggregate",
                    "distinct": True,
                    "semiring": "bool_and_or",
                    "output_idx": ["e"],
                    "ranges": {"f": {"from": "faces"}},
                    # the key reads state u → the distinct node classifies CONTINUOUS
                    "key": {"op": "skolem", "args": ["edge", {"op": "index", "args": ["u", "f"]}]},
                    "expr": {"op": "true", "args": []},
                },
            }
        ],
    }
    try:
        for rhs in model_nodes(bad_model):
            assert_no_continuous_relational(rhs, bad_model)
        rc = 1
        _eprint(
            "self-test FAIL [neg/continuous_relational]: a state-dependent "
            "distinct was NOT rejected (guard 2 must reject it)"
        )
    except CadenceError:
        print("self-test OK   [neg/continuous_relational]: continuous distinct rejected")

    # E3: a from_faq cycle in the ≤DISCRETE index-set graph must be rejected (guard 1).
    cyclic = {
        "variables": {},
        "index_sets": {
            "setA": {"kind": "derived", "from_faq": "nodeA"},
            "setB": {"kind": "derived", "from_faq": "nodeB"},
        },
        "equations": [
            {
                "lhs": {"op": "index", "args": ["a", "x"]},
                "rhs": {
                    "op": "aggregate",
                    "id": "nodeA",
                    "distinct": True,
                    "semiring": "bool_and_or",
                    "output_idx": ["x"],
                    "ranges": {"y": {"from": "setB"}},  # nodeA reads setB
                    "expr": {"op": "true", "args": []},
                },
            },
            {
                "lhs": {"op": "index", "args": ["b", "x"]},
                "rhs": {
                    "op": "aggregate",
                    "id": "nodeB",
                    "distinct": True,
                    "semiring": "bool_and_or",
                    "output_idx": ["x"],
                    "ranges": {"y": {"from": "setA"}},  # nodeB reads setA → cycle
                    "expr": {"op": "true", "args": []},
                },
            },
        ],
    }
    try:
        assert_acyclic_index_sets(cyclic)
        rc = 1
        _eprint(
            "self-test FAIL [neg/from_faq_cycle]: a from_faq cycle was NOT "
            "rejected (guard 1 must reject it)"
        )
    except CadenceError:
        print("self-test OK   [neg/from_faq_cycle]: index-set cycle rejected")

    # E4: a float topology key must be rejected by the fold (§5.5 rule 1).
    try:
        fold_edge_enumeration([[1.5]], [[2]], "undirected")
        rc = 1
        _eprint("self-test FAIL [neg/float_key]: a float topology key was NOT rejected")
    except CadenceError:
        print("self-test OK   [neg/float_key]: float topology key rejected")

    return rc


def _flip_first_expect_cadence(node: Any, frm: str, to: str) -> bool:
    """Flip the first `expect_cadence: frm` annotation to `to`, in place. Returns
    True if one was flipped (builds the E1 negative control)."""
    if not isinstance(node, dict):
        return False
    if node.get("expect_cadence") == frm:
        node["expect_cadence"] = to
        return True
    return any(_flip_first_expect_cadence(c, frm, to) for c in _child_exprs(node))


# === Default run mode (producers, ess-my4.3.7+) ===========================


def run_suite(manifest_path: Path, bindings: list, output_path: Path, timeout) -> int:
    manifest = load_manifest(manifest_path)
    if not bindings:
        bindings = list(manifest.get("bindings_required") or [])
        bindings.extend(b for b in (manifest.get("bindings_optional") or []) if b not in bindings)
    for b in bindings:
        if b not in KNOWN_BINDINGS:
            _eprint(f"error: unknown binding {b!r}; known: {KNOWN_BINDINGS}")
            return 2

    required = set(manifest.get("bindings_required") or [])
    fixtures = manifest["fixtures"]

    adapters = _ADAPTERS.collect(bindings, manifest_path, timeout)

    report: dict = {"manifest_path": str(manifest_path), "status": "ok", "bindings": {}}
    overall_ok = True
    for b in bindings:
        ar = adapters[b]
        b_report: dict = {
            "adapter_status": ar.get("adapter_status"),
            "error": ar.get("error"),
            "fixtures": {},
        }
        if ar.get("adapter_status") != "ok":
            b_report["status"] = "fail" if b in required else "skipped"
            if b in required:
                overall_ok = False
            report["bindings"][b] = b_report
            continue
        b_ok = True
        for fx in fixtures:
            produced = ar.get("fixtures", {}).get(fx["id"])
            if produced is None:
                b_report["fixtures"][fx["id"]] = {"status": "missing"}
                b_ok = False
                continue
            verdict = compare_to_golden(fx, produced)
            b_report["fixtures"][fx["id"]] = {
                "status": "ok" if verdict["match"] else "mismatch",
                "problems": verdict["problems"],
            }
            if not verdict["match"]:
                b_ok = False
        b_report["status"] = "ok" if b_ok else "fail"
        if not b_ok:
            overall_ok = False
        report["bindings"][b] = b_report

    any_ok = any(a.get("adapter_status") == "ok" for a in adapters.values())
    if not any_ok and not required:
        # No producer registered AND none demanded: nothing to check here. The
        # --self-test gate is the green check in such an environment. (Once a
        # binding is in `bindings_required`, a missing producer fails above.)
        report["status"] = "no_producers"
        print(
            "No cadence-partition adapters registered for any requested binding, "
            "and none are required. The contract is gated by --self-test here."
        )
    else:
        report["status"] = "ok" if overall_ok else "fail"

    write_report(report, output_path)
    print_summary(report, "=== Cadence-Partition Conformance Report ===")
    return 1 if report["status"] == "fail" else 0


# === CLI ==================================================================


def parse_args(argv: list):
    return build_parser(
        doc=__doc__,
        default_manifest=DEFAULT_MANIFEST,
        default_output=Path("conformance-results/cadence/report.json"),
        manifest_help="Path to the cadence manifest.json.",
        self_test_help="Assert the contract against the embedded reference "
        "classifier + folder and golden, then exit.",
    ).parse_args(argv)


def main(argv: list | None = None) -> int:
    return cli_main(argv, parse_args=parse_args, self_test=self_test, run_suite=run_suite)


if __name__ == "__main__":
    sys.exit(main())
