#!/usr/bin/env python3
"""Compare Lean expression-root lowering with the shared template corpus."""

from __future__ import annotations

import argparse
import json
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CORPUS = ROOT / "tests/conformance/expression_templates"
INVALID = ROOT / "tests/invalid"
DEFAULT_ADAPTER = ROOT / "formal/.lake/build/bin/esm-lean"
EXPANDED = (
    "arrhenius_smoke",
    "constrained_match_scope",
    "fixpoint_nested_deriv",
    "godunov_beats_inner_deriv",
    "opacity_rule_replacement",
    "operator_call_by_name",
    "per_variable_scheme_literal_args",
    "ranges_from_param",
    "ranges_param",
    "rewrite_in_template_body",
    "rule_writes_reference",
    "scalar_field_param",
    "template_instance_variants",
    "two_div_two_meshes",
    "where_priority_declaration_order",
)
EMITTED = (
    "placeholder_call",
    "reference_only_round_trip",
    "rewrite_in_template_body",
    "rule_writes_reference",
)
ERRORS = (
    ("constraint_unknown_index_set", "fixture.esm", "error.json"),
    ("nonterminating_rewrite", "fixture.esm", "error.json"),
    ("operator_arity_mismatch", "fixture.esm", "error.json"),
    ("operator_defines_core_op", "fixture.esm", "error.json"),
    ("rewrite_depth_through_bodies", "chain_depth_65.esm", "error_chain_depth_65.json"),
)
INVALID_BODIES = ("body_apply_cycle.esm", "body_chain_too_deep.esm")
COLLECTIONS = ("equations", "initialization_equations", "reactions", "constraint_equations")


def component(document):
    components = document.get("models", {}) | document.get("reaction_systems", {})
    [(name, value)] = components.items()
    return name, value


def run(adapter, *args, timeout=None):
    return subprocess.run(
        [str(adapter), *map(str, args)], capture_output=True, check=False, timeout=timeout
    )


def rewrite(adapter, fixture, expanded):
    name, _ = component(json.loads(fixture.read_bytes()))
    options = ["--expanded"] if expanded else []
    return run(adapter, "rewrite-templates", *options, fixture, name)


def compare(adapter, directory, fixture, expected, expanded):
    actual = rewrite(adapter, directory / fixture, expanded)
    if actual.returncode:
        raise AssertionError(actual.stderr.decode().strip())
    golden = run(adapter, "canon", directory / expected)
    if golden.returncode:
        raise AssertionError(golden.stderr.decode().strip())
    _, authored = component(json.loads(golden.stdout))
    projection = {key: authored[key] for key in COLLECTIONS if key in authored}
    if json.loads(actual.stdout) != projection:
        raise AssertionError(f"expected {projection!r}\nactual   {json.loads(actual.stdout)!r}")


def compare_error(adapter, fixture, diagnostic):
    actual = rewrite(adapter, fixture, True)
    if actual.returncode != 1 or json.loads(actual.stderr)["code"] != diagnostic:
        raise AssertionError(f"expected {diagnostic}, got {actual.stderr.decode().strip()}")


def check_shared_bodies(adapter):
    def reference(index):
        return {"op": "apply_operator", "args": [], "name": f"node_{index}", "bindings": {}}

    # The 24 shared bodies describe more than 16 million leaves if expanded.
    operators = {
        f"node_{index}": {
            "params": [],
            "body": {"op": "+", "args": [reference(index + 1), reference(index + 1)]},
        }
        for index in range(24)
    }
    operators["node_24"] = {"params": [], "body": 3}
    equations = [{"lhs": "out", "rhs": reference(0)}]
    document = {
        "esm": "2.4.0",
        "metadata": {"name": "SharedRewriteBodies"},
        "models": {
            "Probe": {
                "variables": {"out": {"type": "unknown"}},
                "operators": operators,
                "equations": equations,
            }
        },
    }
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "shared_bodies.esm"
        path.write_text(json.dumps(document), encoding="utf-8")
        actual = run(adapter, "rewrite-templates", path, "Probe", timeout=30)
    if actual.returncode or json.loads(actual.stdout) != {"equations": equations}:
        raise AssertionError(f"reference-preserving rewrite failed: {actual.stderr.decode()}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--adapter", type=Path, default=DEFAULT_ADAPTER)
    args = parser.parse_args()
    cases = [
        *((name, "fixture.esm", "expanded.esm", True) for name in EXPANDED),
        *((name, "fixture.esm", "emitted.esm", False) for name in EMITTED),
        (
            "rewrite_depth_through_bodies",
            "chain_depth_64.esm",
            "expanded_chain_depth_64.esm",
            True,
        ),
    ]
    failed = []
    for name, fixture, expected, expanded in cases:
        try:
            compare(args.adapter, CORPUS / name, fixture, expected, expanded)
        except (AssertionError, ValueError) as error:
            failed.append(f"{name}/{expected}: {error}")
    errors = [
        (CORPUS / name / fixture, json.loads((CORPUS / name / expected).read_bytes())["code"])
        for name, fixture, expected in ERRORS
    ]
    invalid_diagnostics = json.loads((INVALID / "expected_errors.json").read_bytes())
    errors.extend(
        (INVALID / "template_imports" / file, invalid_diagnostics[file]["resolver_error_code"])
        for file in INVALID_BODIES
    )
    for fixture, diagnostic in errors:
        try:
            compare_error(args.adapter, fixture, diagnostic)
        except (AssertionError, ValueError) as error:
            failed.append(f"{fixture.relative_to(ROOT)}: {error}")
    try:
        check_shared_bodies(args.adapter)
    except (AssertionError, ValueError, subprocess.TimeoutExpired) as error:
        failed.append(f"shared body DAG: {error}")
    for failure in failed:
        print(failure)
    total = len(cases) + len(errors) + 1
    print(f"Lean rewrite conformance: {total - len(failed)}/{total} passed")
    return bool(failed)


if __name__ == "__main__":
    raise SystemExit(main())
