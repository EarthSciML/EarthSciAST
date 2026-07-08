#!/usr/bin/env python3
"""Generate a corpus of property-test expression fixtures.

Phase 2 of the cross-binding property-test initiative (gt-3fbf, follow-up to
gt-72z phase 1). Reuses the hypothesis strategies defined in
``test_property_expression.py`` to materialize a stable corpus of expression
JSON files on disk. Every binding's round-trip driver then reads the same
corpus and the runner (``run-property-corpus-conformance.py``) compares
the outputs to surface cross-binding divergence.

The corpus lives at ``tests/property_corpus/expressions/expr_NNN.json``.
It is regenerated deterministically (hypothesis ``derandomize=True``) so
rerunning this script yields the same fixtures unless the strategy itself
changes.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_ROOT / "pkg" / "earthsci-ast-py" / "src"))
sys.path.insert(0, str(PROJECT_ROOT / "pkg" / "earthsci-ast-py" / "tests"))

from hypothesis import given, settings, strategies as st  # noqa: E402
from test_property_expression import (  # noqa: E402
    _expr_strategy,
    _op_aggregate,
    _op_broadcast,
    _op_concat,
    _op_makearray,
    _op_reshape,
    _op_transpose,
)
from earthsci_ast.serialize import _serialize_expression  # noqa: E402


def _collect(strategy, count: int) -> list:
    """Drain ``count`` examples from ``strategy`` using the @given harness."""
    out: list = []

    @given(strategy)
    @settings(
        max_examples=count,
        deadline=None,
        database=None,
        derandomize=True,
    )
    def _run(expr):
        out.append(_serialize_expression(expr))

    _run()
    return out[:count]


def generate(count: int) -> list:
    """Return ``count`` hypothesis-generated expressions as serialized dicts.

    The corpus is deliberately split between the general ``_expr_strategy``
    (which favors shallow arithmetic trees because of hypothesis' shrinking)
    and the array-op strategies applied *at the root*. Without the latter
    split, bindings that drop operator-node aux fields only on the root
    (notably the Go binding — its ExprNode struct has no output_idx/expr/
    reduce/ranges/regions/values/shape/perm/axis/fn) would never be exercised
    because the general strategy almost never roots at an array op.
    """
    half = max(1, count // 2)
    remainder = count - half

    general = _collect(_expr_strategy, half)

    # Build a child strategy that feeds the array-op constructors with
    # non-trivial subtrees drawn from the full expression strategy. Each
    # array-op strategy then becomes root of a fixture.
    arrayop_root = st.one_of(
        _op_aggregate(_expr_strategy),
        _op_makearray(_expr_strategy),
        _op_reshape(_expr_strategy),
        _op_transpose(_expr_strategy),
        _op_concat(_expr_strategy),
        _op_broadcast(_expr_strategy),
    )
    array_rooted = _collect(arrayop_root, remainder)

    return (general + array_rooted)[:count]


def write_corpus(out_dir: Path, payloads: list) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    # Clean any stale fixtures so the corpus is exactly `count` files.
    for existing in out_dir.glob("expr_*.json"):
        existing.unlink()
    for i, payload in enumerate(payloads):
        path = out_dir / f"expr_{i:03d}.json"
        with open(path, "w") as f:
            json.dump(payload, f, indent=2, sort_keys=True)
            f.write("\n")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--out",
        default=str(PROJECT_ROOT / "tests" / "property_corpus" / "expressions"),
        help="Output directory for generated fixtures.",
    )
    ap.add_argument("--count", type=int, default=50, help="Number of fixtures to emit.")
    args = ap.parse_args()

    payloads = generate(args.count)
    out_dir = Path(args.out)
    write_corpus(out_dir, payloads)
    print(f"Wrote {len(payloads)} fixtures to {out_dir}")


if __name__ == "__main__":
    main()
