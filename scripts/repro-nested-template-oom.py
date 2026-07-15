#!/usr/bin/env python3
# Reproducer for the nested-expression-template memory blow-up in the Python
# binding (pkg/earthsci-ast-py) — sibling of repro-nested-template-oom.jl.
#
# A chain of match-less templates T0..T<depth> where each T_i body references
# T_{i-1} twice is inlined at registration by `_compose_template_bodies`
# (template_imports.py): before structural sharing every reference was expanded
# by pure substitution with deep copies, so the composed body of T_d held 2^d
# copies of the leaf; the §9.6.3 call-site fixpoint, the post-expansion
# validators, and `_parse_expression` each re-walked/re-built the full tree —
# a few-KB document within every documented limit (chain depth <=
# MAX_TEMPLATE_EXPANSION_DEPTH = 32) expanded to millions of AST nodes and
# gigabytes of live memory.
#
# Usage (one depth per process, so ru_maxrss is a clean per-depth peak):
#
#   pkg/earthsci-ast-py$ python3 ../../scripts/repro-nested-template-oom.py <depth>
#
# Measured BEFORE structural sharing (CPython 3.11, x86_64 Linux; logical
# expanded nodes = 2^(depth+3) - 1):
#
#   depth=10  doc=2.7KB  nodes=8,191     load= 0.5s  maxrss=158MiB
#   depth=14  doc=3.6KB  nodes=131,071   load= 4.1s  maxrss=289MiB
#   depth=16  doc=4.0KB  nodes=524,287   load=23.4s  maxrss=769MiB
#   (4x memory / time per +2 depth; depth 19 ≈ 6GiB → laptop OOM)
#
# AFTER (expanded ASTs stored as structurally-shared DAGs; identical
# semantics, tree-equivalent logical size unchanged):
#
#   depth=16  nodes=524,287        unique_dag_nodes=20  load=0.3s  maxrss=129MiB
#   depth=30  nodes=8,589,934,591  unique_dag_nodes=34  load=0.3s  maxrss=129MiB
#   depth=32  -> template_body_expansion_too_deep (33-template chain), as spec'd
#
# (~0.3s / 129MiB is the package-import baseline of this environment.)

from __future__ import annotations

import json
import resource
import sys
import time


def apply_node(name: str) -> dict:
    return {"op": "apply_expression_template", "args": [], "name": name, "bindings": {}}


def build_doc(depth: int) -> dict:
    templates: dict = {
        "T0": {
            "params": [],
            "body": {
                "op": "*",
                "args": [
                    1.8e-12,
                    {
                        "op": "exp",
                        "args": [{"op": "/", "args": [{"op": "-", "args": [1500.0]}, "T"]}],
                    },
                ],
            },
        }
    }
    for i in range(1, depth + 1):
        templates[f"T{i}"] = {
            "params": [],
            "body": {"op": "+", "args": [apply_node(f"T{i-1}"), apply_node(f"T{i-1}")]},
        }
    return {
        "esm": "0.4.0",
        "metadata": {"name": "nested_template_oom_repro", "authors": ["repro"]},
        "reaction_systems": {
            "chem": {
                "species": {"A": {"default": 1.0}, "B": {"default": 0.0}},
                "parameters": {"T": {"default": 298.15}},
                "expression_templates": templates,
                "reactions": [
                    {
                        "id": "R1",
                        "substrates": [{"species": "A", "stoichiometry": 1}],
                        "products": [{"species": "B", "stoichiometry": 1}],
                        "rate": apply_node(f"T{depth}"),
                    }
                ],
            }
        },
    }


def logical_nodes(root) -> tuple[int, int]:
    """(logical node count, unique container count) over the typed ExprNode
    tree. Identity-memoized and iterative, so it is O(unique nodes) with no
    recursion-limit exposure — NEVER count a deep expansion naively."""
    from earthsci_ast.esm_types import ExprNode
    from earthsci_ast.expr_walk import iter_children

    memo: dict[int, int] = {}
    keep = []  # keep keyed objects alive so ids are not recycled

    def children(n):
        if isinstance(n, ExprNode):
            return list(iter_children(n))
        if isinstance(n, (dict,)):
            return list(n.values())
        if isinstance(n, list):
            return list(n)
        return None

    stack = [(root, False)]
    while stack:
        node, expanded = stack.pop()
        ch = children(node)
        if ch is None or id(node) in memo:
            continue
        if not expanded:
            stack.append((node, True))
            for c in ch:
                if children(c) is not None and id(c) not in memo:
                    stack.append((c, False))
        else:
            total = 1
            for c in ch:
                total += 1 if children(c) is None else memo[id(c)]
            memo[id(node)] = total
            keep.append(node)
    if children(root) is None:
        return 1, 1
    return memo[id(root)], len(keep)


def main() -> None:
    depth = int(sys.argv[1]) if len(sys.argv) > 1 else 16
    doc = build_doc(depth)
    print(f"depth={depth} doc bytes={len(json.dumps(doc))}")

    from earthsci_ast.parse import load

    t0 = time.perf_counter()
    esm = load(doc)
    dt = time.perf_counter() - t0

    rate = esm.reaction_systems["chem"].reactions[0].rate_constant
    logical, unique = logical_nodes(rate)
    peak_mib = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024.0
    print(
        f"load: {dt:.2f}s  peak RSS: {peak_mib:.0f} MiB  "
        f"rate AST: {logical} logical nodes, {unique} unique container nodes"
    )


if __name__ == "__main__":
    main()
