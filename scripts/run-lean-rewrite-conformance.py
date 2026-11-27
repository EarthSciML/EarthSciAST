#!/usr/bin/env python3
"""Compare Lean rewrite projections with the shared operator corpus."""

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
    "faq_reduction_pattern",
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
    "time_axis_in_definition",
    "two_div_two_meshes",
    "where_priority_declaration_order",
)
ROOTS = (
    "placeholder_call",
    "reference_only_round_trip",
    "rewrite_in_template_body",
    "rule_writes_reference",
)
EMITTED = (
    "emit_materialized_registry",
    "emit_rename_dotted_keys",
    "old_names",
    "opacity_negative",
    "opacity_priority_shadowing",
    "opacity_rule_replacement",
    "placeholder_call",
    "reference_only_round_trip",
    "rewrite_in_template_body",
    "rewrite_shared_by_unreached_entry",
    "rule_writes_reference",
    "template_instance_variants",
    "vector_calculus_import",
)
IMPORTS = (
    "import_diamond",
    "import_rebind_keyed_factors",
    "import_rename_diamond",
    "import_rename_integral_axis",
    "import_rename_name_keyed_map_entries",
    "import_rename_two_instances",
    "import_smoke",
    "import_symbolic_binding",
    "import_where_rename_two_instances",
    "metaparam_axis_name_collision",
    "metaparam_structural_field_collision",
    "rewrite_shared_by_unreached_entry",
)
ERRORS = (
    ("constraint_unknown_index_set", "fixture.esm", "error.json"),
    ("nonterminating_rewrite", "fixture.esm", "error.json"),
    ("operator_arity_mismatch", "fixture.esm", "error.json"),
    ("operator_defines_core_op", "fixture.esm", "error.json"),
    ("import_where_rename_unknown_index_set", "fixture.esm", "error.json"),
    ("rewrite_depth_through_bodies", "chain_depth_65.esm", "error_chain_depth_65.json"),
)
INVALID_LOAD = (
    "body_apply_cycle.esm",
    "body_chain_too_deep.esm",
    "import_cycle_a.esm",
    "import_name_conflict.esm",
    "import_not_library.esm",
    "import_unknown_only.esm",
    "index_set_conflict.esm",
    "metaparameter_inexact_division.esm",
    "metaparameter_unbound.esm",
    "rebind_unknown_free_name.esm",
    "rename_collision.esm",
    "rename_invalid_identifier.esm",
    "rename_unknown_name.esm",
    "root_templates_with_models.esm",
)
COLLECTIONS = ("equations", "initialization_equations", "reactions", "constraint_equations")


def component(document):
    components = document.get("models", {}) | document.get("reaction_systems", {})
    [(name, value)] = components.items()
    return name, value


def run(adapter, *args, timeout=None):
    return subprocess.run(
        [str(adapter), *map(str, args)], capture_output=True, check=False, timeout=timeout
    )


def rewrite(adapter, fixture, mode):
    document = json.loads(fixture.read_bytes())
    name = component(document)[0] if "models" in document or "reaction_systems" in document else "_"
    options = [f"--{mode}"] if mode != "roots" else []
    return run(adapter, "rewrite-templates", *options, fixture, name)


def compare(adapter, directory, fixture, expected, mode):
    actual = rewrite(adapter, directory / fixture, mode)
    if actual.returncode:
        raise AssertionError(actual.stderr.decode().strip())
    golden = run(adapter, "canon", directory / expected)
    if golden.returncode:
        raise AssertionError(golden.stderr.decode().strip())
    normalized = json.loads(golden.stdout)
    _, authored = component(normalized)
    projection = {key: authored[key] for key in COLLECTIONS if key in authored}
    result = json.loads(actual.stdout)
    if mode == "emitted":
        if "operators" in authored:
            projection["operators"] = authored["operators"]
        if "index_sets" in normalized:
            projection["index_sets"] = normalized["index_sets"]
    if result != projection:
        raise AssertionError(f"expected {projection!r}\nactual   {result!r}")
    if mode == "emitted":
        check_emitted(adapter, directory / expected, result, actual.stdout)


def check_emitted(adapter, golden, result, emitted_bytes):
    document = json.loads(golden.read_bytes())
    _, expected = component(document)
    definitions = expected.get("operators", expected.get("expression_templates", {}))
    names = list(result.get("operators", {}))
    if names != list(definitions):
        raise AssertionError(f"definition order: expected {list(definitions)}, got {names}")
    # Reload the actual projection in the golden's resolved document envelope.
    # The envelope supplies declarations whose projection this command omits.
    expected.pop("expression_templates", None)
    expected.update({key: value for key, value in result.items() if key != "index_sets"})
    if "index_sets" in result:
        document["index_sets"] = result["index_sets"]
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "emitted.esm"
        path.write_text(json.dumps(document, ensure_ascii=False), encoding="utf-8")
        reloaded = rewrite(adapter, path, "emitted")
    if reloaded.returncode:
        raise AssertionError(f"reload: {reloaded.stderr.decode().strip()}")
    if reloaded.stdout != emitted_bytes:
        raise AssertionError(f"reload changed emitted projection: {reloaded.stdout.decode()}")


def compare_error(adapter, fixture, diagnostic):
    actual = rewrite(adapter, fixture, "expanded")
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


def check_imported_dependency_of_unused_definition(adapter):
    helper = {"params": [], "body": 3}
    unused = {
        "params": [],
        "body": {"op": "apply_operator", "args": [], "name": "helper", "bindings": {}},
    }
    document = {
        "esm": "2.4.0",
        "metadata": {"name": "UnusedDefinitionDependency"},
        "models": {
            "Probe": {
                "operators": {"unused": unused},
                "operator_imports": [{"ref": "library.esm"}],
                "variables": {"out": {"type": "unknown"}},
                "equations": [{"lhs": "out", "rhs": 7}],
            }
        },
    }
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "fixture.esm"
        library = {"esm": "2.4.0", "metadata": {"name": "Library"}, "operators": {"helper": helper}}
        (path.parent / "library.esm").write_text(json.dumps(library), encoding="utf-8")
        path.write_text(json.dumps(document), encoding="utf-8")
        actual = rewrite(adapter, path, "emitted")
        if actual.returncode:
            raise AssertionError(actual.stderr.decode().strip())
        _, model = component(document)
        model.pop("operator_imports")
        model["operators"]["helper"] = helper
        path.write_text(json.dumps(document), encoding="utf-8")
        check_emitted(adapter, path, json.loads(actual.stdout), actual.stdout)


def check_unused_symbolic_import_binding(adapter):
    document = {
        "esm": "2.4.0",
        "metadata": {"name": "UnusedSymbolicImportBinding"},
        "metaparameters": {"D": {"type": "integer", "default": 2}},
        "models": {
            "Probe": {
                "operator_imports": [{"ref": "wrapper.esm", "bindings": {"K": "D"}}],
                "variables": {"out": {"type": "unknown"}},
                "equations": [{"lhs": "out", "rhs": 7}],
            }
        },
    }
    library = {
        "esm": "2.4.0",
        "metadata": {"name": "Library"},
        "metaparameters": {"N": {"type": "integer"}},
        "operators": {
            "helper": {"params": [], "body": 3},
            "filtered": {"params": [], "body": "N"},
        },
    }
    wrapper = {
        "esm": "2.4.0",
        "metadata": {"name": "Wrapper"},
        "metaparameters": {"K": {"type": "integer"}},
        "operators": {},
        "operator_imports": [
            {
                "ref": "library.esm",
                "only": ["helper"],
                "bindings": {"N": {"op": "/", "args": [2, "K"]}},
            }
        ],
    }
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "fixture.esm"
        (path.parent / "library.esm").write_text(json.dumps(library), encoding="utf-8")
        (path.parent / "wrapper.esm").write_text(json.dumps(wrapper), encoding="utf-8")
        path.write_text(json.dumps(document), encoding="utf-8")
        actual = rewrite(adapter, path, "expanded")
        if actual.returncode:
            raise AssertionError(actual.stderr.decode().strip())
        document["metaparameters"]["D"]["default"] = 0
        path.write_text(json.dumps(document), encoding="utf-8")
        compare_error(adapter, path, "metaparameter_type_error")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--adapter", type=Path, default=DEFAULT_ADAPTER)
    args = parser.parse_args()
    cases = [
        *((name, "fixture.esm", "expanded.esm", "expanded") for name in EXPANDED + IMPORTS),
        *((name, "fixture.esm", "emitted.esm", "roots") for name in ROOTS),
        *((name, "fixture.esm", "emitted.esm", "emitted") for name in EMITTED),
        *(
            ("import_order_determinism", f"fixture_{case}.esm", f"expanded_{case}.esm", "expanded")
            for case in ("import_order", "priority_override")
        ),
        (
            "rewrite_depth_through_bodies",
            "chain_depth_64.esm",
            "expanded_chain_depth_64.esm",
            "expanded",
        ),
    ]
    failed = []
    for name, fixture, expected, mode in cases:
        try:
            compare(args.adapter, CORPUS / name, fixture, expected, mode)
        except (AssertionError, ValueError) as error:
            failed.append(f"{name}/{expected} ({mode}): {error}")
    errors = [
        (CORPUS / name / fixture, json.loads((CORPUS / name / expected).read_bytes())["code"])
        for name, fixture, expected in ERRORS
    ]
    invalid_diagnostics = json.loads((INVALID / "expected_errors.json").read_bytes())
    errors.extend(
        (INVALID / "template_imports" / file, invalid_diagnostics[file]["resolver_error_code"])
        for file in INVALID_LOAD
    )
    for fixture, diagnostic in errors:
        try:
            compare_error(args.adapter, fixture, diagnostic)
        except (AssertionError, ValueError) as error:
            failed.append(f"{fixture.relative_to(ROOT)}: {error}")
    checks = {
        "shared body DAG": check_shared_bodies,
        "unused definition's imported dependency": check_imported_dependency_of_unused_definition,
        "unused symbolic import binding": check_unused_symbolic_import_binding,
    }
    for name, check in checks.items():
        try:
            check(args.adapter)
        except (AssertionError, ValueError, subprocess.TimeoutExpired) as error:
            failed.append(f"{name}: {error}")
    for failure in failed:
        print(failure)
    total = len(cases) + len(errors) + len(checks)
    print(f"Lean rewrite conformance: {total - len(failed)}/{total} passed")
    return bool(failed)


if __name__ == "__main__":
    raise SystemExit(main())
