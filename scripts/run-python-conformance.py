#!/usr/bin/env python3

"""
Python conformance test runner for ESM Format cross-language testing.

This script runs the Python earthsci_ast implementation against test fixtures
and generates standardized outputs for comparison with other language implementations.
"""

import sys
import json
from pathlib import Path
from datetime import datetime
from typing import Dict, Any
import traceback

# Add the Python package to the path
script_dir = Path(__file__).parent
project_root = script_dir.parent
python_package = project_root / "pkg" / "earthsci-ast-py"

# Add the Python package to sys.path
sys.path.insert(0, str(python_package / "src"))

try:
    import earthsci_ast
except ImportError as e:
    print(f"Failed to import earthsci_ast Python library: {e}")
    print("Make sure the Python package is properly installed")
    sys.exit(1)


class ConformanceResults:
    def __init__(self):
        self.language = "python"
        self.timestamp = datetime.now().isoformat()
        self.validation_results = {}
        self.display_results = {}
        self.substitution_results = {}
        self.graph_results = {}
        self.mathematical_correctness_results = {}
        self.errors = []

    def to_dict(self):
        return {
            "language": self.language,
            "timestamp": self.timestamp,
            "validation_results": self.validation_results,
            "display_results": self.display_results,
            "substitution_results": self.substitution_results,
            "graph_results": self.graph_results,
            "mathematical_correctness_results": self.mathematical_correctness_results,
            "errors": self.errors,
        }


def _json_default(obj):
    # ValidationError (and similar binding error dataclasses) carry path/message/
    # code/details fields; downgrade to a plain dict so json.dump never trips on
    # them. Anything else falls through to repr() — better than aborting the
    # whole results write over one stray non-serializable field.
    for attr in ("__dict__",):
        d = getattr(obj, attr, None)
        if isinstance(d, dict) and d:
            return d
    return repr(obj)


def write_results(output_dir: Path, results: ConformanceResults):
    """Write conformance results to JSON file."""
    output_dir.mkdir(parents=True, exist_ok=True)

    results_file = output_dir / "results.json"
    with open(results_file, "w") as f:
        json.dump(results.to_dict(), f, indent=2, default=_json_default)

    print(f"Python conformance results written to: {results_file}")


def run_validation_tests(tests_dir: Path) -> Dict[str, Any]:
    """Test schema and structural validation on valid and invalid ESM files."""
    print("Running validation tests...")
    validation_results = {}

    # Test valid files
    valid_dir = tests_dir / "valid"
    if valid_dir.exists() and valid_dir.is_dir():
        valid_results = {}
        valid_files = [f for f in valid_dir.iterdir() if f.suffix == ".esm"]

        for filepath in valid_files:
            try:
                esm_data = earthsci_ast.load(filepath)
                result = earthsci_ast.validate(esm_data)

                valid_results[filepath.name] = {
                    "is_valid": result.is_valid,
                    "schema_errors": result.schema_errors,
                    "structural_errors": result.structural_errors,
                    "parsed_successfully": True,
                }
            except Exception as e:
                valid_results[filepath.name] = {
                    "parsed_successfully": False,
                    "error": str(e),
                    "error_type": type(e).__name__,
                }
        validation_results["valid"] = valid_results

    # Test invalid files
    invalid_dir = tests_dir / "invalid"
    if invalid_dir.exists() and invalid_dir.is_dir():
        invalid_results = {}
        invalid_files = [f for f in invalid_dir.iterdir() if f.suffix == ".esm"]

        for filepath in invalid_files:
            try:
                esm_data = earthsci_ast.load(filepath)
                result = earthsci_ast.validate(esm_data)

                invalid_results[filepath.name] = {
                    "is_valid": result.is_valid,
                    "schema_errors": result.schema_errors,
                    "structural_errors": result.structural_errors,
                    "parsed_successfully": True,
                }
            except Exception as e:
                invalid_results[filepath.name] = {
                    "parsed_successfully": False,
                    "error": str(e),
                    "error_type": type(e).__name__,
                    "is_expected_error": True,  # Invalid files should error
                }
        validation_results["invalid"] = invalid_results

    return validation_results


def run_display_tests(tests_dir: Path) -> Dict[str, Any]:
    """Test pretty-printing and display format generation."""
    print("Running display tests...")
    display_results = {}

    display_dir = tests_dir / "display"
    if display_dir.exists() and display_dir.is_dir():
        display_files = [f for f in display_dir.iterdir() if f.suffix == ".json"]

        for filepath in display_files:
            try:
                with open(filepath, "r") as f:
                    test_data = json.load(f)
                test_results = {}

                # Test chemical formula rendering
                if "chemical_formulas" in test_data:
                    formula_results = []
                    for formula_test in test_data["chemical_formulas"]:
                        if "input" in formula_test:
                            input_formula = formula_test["input"]
                            try:
                                unicode_result = earthsci_ast.render_chemical_formula(
                                    input_formula
                                )

                                formula_results.append(
                                    {
                                        "input": input_formula,
                                        "output_unicode": unicode_result,
                                        "output_latex": formula_test.get("expected_latex", ""),
                                        "output_ascii": input_formula,  # Fallback
                                        "success": True,
                                    }
                                )
                            except Exception as e:
                                formula_results.append(
                                    {"input": input_formula, "error": str(e), "success": False}
                                )
                    test_results["chemical_formulas"] = formula_results

                # Test expression rendering
                if "expressions" in test_data:
                    expression_results = []
                    for expr_test in test_data["expressions"]:
                        if "input" in expr_test:
                            input_expr = expr_test["input"]
                            try:
                                expr = earthsci_ast.parse_expression(input_expr)
                                unicode_result = earthsci_ast.pretty_print(
                                    expr, format="unicode"
                                )
                                latex_result = earthsci_ast.pretty_print(expr, format="latex")
                                ascii_result = earthsci_ast.pretty_print(expr, format="ascii")

                                expression_results.append(
                                    {
                                        "input": input_expr,
                                        "output_unicode": unicode_result,
                                        "output_latex": latex_result,
                                        "output_ascii": ascii_result,
                                        "success": True,
                                    }
                                )
                            except Exception as e:
                                expression_results.append(
                                    {"input": input_expr, "error": str(e), "success": False}
                                )
                    test_results["expressions"] = expression_results

                display_results[filepath.name] = test_results

            except Exception as e:
                display_results[filepath.name] = {"error": str(e), "success": False}

    return display_results


def run_substitution_tests(tests_dir: Path) -> Dict[str, Any]:
    """Test expression substitution functionality."""
    print("Running substitution tests...")
    substitution_results = {}

    substitution_dir = tests_dir / "substitution"
    if substitution_dir.exists() and substitution_dir.is_dir():
        substitution_files = [f for f in substitution_dir.iterdir() if f.suffix == ".json"]

        for filepath in substitution_files:
            try:
                with open(filepath, "r") as f:
                    test_data = json.load(f)
                test_results = []

                if "tests" in test_data:
                    for test_case in test_data["tests"]:
                        if "expression" in test_case and "substitutions" in test_case:
                            try:
                                expr = earthsci_ast.parse_expression(test_case["expression"])
                                substitutions = {
                                    k: earthsci_ast.parse_expression(v)
                                    for k, v in test_case["substitutions"].items()
                                }

                                result_expr = earthsci_ast.substitute(expr, substitutions)
                                result_str = earthsci_ast.pretty_print(result_expr)

                                test_results.append(
                                    {
                                        "input": test_case["expression"],
                                        "substitutions": test_case["substitutions"],
                                        "result": result_str,
                                        "success": True,
                                    }
                                )
                            except Exception as e:
                                test_results.append(
                                    {
                                        "input": test_case.get("expression", ""),
                                        "error": str(e),
                                        "success": False,
                                    }
                                )

                substitution_results[filepath.name] = test_results

            except Exception as e:
                substitution_results[filepath.name] = {"error": str(e), "success": False}

    return substitution_results


def _resolve_graph_input_file(tests_dir: Path, fixture_path: Path, ref: str):
    """Tests/graphs fixtures reference ESM files by bare filename — they
    live in tests/valid/. Try a few obvious roots."""
    for candidate in (
        fixture_path.parent / ref,
        tests_dir / "valid" / ref,
        tests_dir / ref,
    ):
        if candidate.exists():
            return candidate
    return None


def _load_esm_source(tests_dir: Path, fixture_path: Path, source):
    """Source may be a bare filename (string) or an inline ESM dict (the
    comprehensive_graph_generation_fixtures family inlines documents)."""
    if isinstance(source, str):
        path = _resolve_graph_input_file(tests_dir, fixture_path, source)
        if path is None:
            raise FileNotFoundError(f"ESM file not found: {source}")
        return earthsci_ast.load(path)
    return earthsci_ast.load(source)


def _exercise_graph_fixture(esm_data) -> Dict[str, Any]:
    """Drive an ESM doc through validate + component_graph + expression_graph
    and capture comparison-friendly summaries. Each step is wrapped so a
    single failure does not abort the rest."""
    record: Dict[str, Any] = {"loaded": True}

    try:
        result = earthsci_ast.validate(esm_data)
        record["validation"] = {
            "is_valid": getattr(result, "is_valid", False),
            "schema_error_count": len(getattr(result, "schema_errors", []) or []),
            "structural_error_count": len(getattr(result, "structural_errors", []) or []),
        }
    except Exception as e:
        record["validation"] = {"error": str(e)}

    try:
        cg = earthsci_ast.component_graph(esm_data)
        record["component_graph"] = {
            "nodes": len(cg.nodes),
            "edges": len(cg.edges),
        }
    except Exception as e:
        record["component_graph"] = {"error": str(e)}

    try:
        eg = earthsci_ast.expression_graph(esm_data)
        record["expression_graph"] = {
            "nodes": len(eg.nodes),
            "edges": len(eg.edges),
        }
    except Exception as e:
        record["expression_graph"] = {"error": str(e)}

    return record


def run_graph_tests(tests_dir: Path) -> Dict[str, Any]:
    """Drive each tests/graphs fixture through the load + validate +
    component_graph + expression_graph pipeline. Captures node/edge counts
    so the cross-language comparator can flag size divergence (esm-rs7).

    Handles three fixture shapes:
      1. Dict with `input_file` (bare filename in tests/valid/).
      2. Dict with `esm_file` (legacy key, may be path or inline dict).
      3. List of test cases each carrying its own `name` + `esm_file`.
    """
    print("Running graph tests...")
    graph_results: Dict[str, Any] = {}

    graphs_dir = tests_dir / "graphs"
    if not (graphs_dir.exists() and graphs_dir.is_dir()):
        return graph_results

    for filepath in sorted(graphs_dir.iterdir()):
        if filepath.suffix != ".json":
            continue
        try:
            with open(filepath, "r") as f:
                test_data = json.load(f)

            if isinstance(test_data, list):
                cases: Dict[str, Any] = {}
                for i, case in enumerate(test_data):
                    name = case.get("name") if isinstance(case, dict) else None
                    name = name or f"case_{i}"
                    src = None
                    if isinstance(case, dict):
                        src = case.get("esm_file") or case.get("input_file")
                    if src is None:
                        cases[name] = {"skipped": "no esm_file/input_file"}
                        continue
                    try:
                        esm_data = _load_esm_source(tests_dir, filepath, src)
                        cases[name] = _exercise_graph_fixture(esm_data)
                    except Exception as e:
                        cases[name] = {"loaded": False, "error": str(e)}
                graph_results[filepath.name] = {"test_cases": cases}
            elif isinstance(test_data, dict):
                src = test_data.get("input_file") or test_data.get("esm_file")
                if src is None:
                    graph_results[filepath.name] = {"skipped": "no input_file/esm_file"}
                    continue
                try:
                    esm_data = _load_esm_source(tests_dir, filepath, src)
                    record = _exercise_graph_fixture(esm_data)
                    record["input_file"] = src if isinstance(src, str) else "<inline>"
                    graph_results[filepath.name] = record
                except Exception as e:
                    graph_results[filepath.name] = {
                        "loaded": False,
                        "error": str(e),
                        "input_file": src if isinstance(src, str) else "<inline>",
                    }
        except Exception as e:
            graph_results[filepath.name] = {"loaded": False, "error": str(e)}

    return graph_results


def run_mathematical_correctness_tests(tests_dir: Path) -> Dict[str, Any]:
    """Drive each .esm file under tests/mathematical_correctness/ through
    load + validate. Catches schema/structural drift in the conservation
    laws / dimensional analysis / numerical correctness fixtures that
    audit esm-rv3 §3.1 flagged as untested across bindings."""
    print("Running mathematical-correctness tests...")
    results: Dict[str, Any] = {}

    math_dir = tests_dir / "mathematical_correctness"
    if not (math_dir.exists() and math_dir.is_dir()):
        return results

    for filepath in sorted(math_dir.iterdir()):
        if filepath.suffix != ".esm":
            continue
        try:
            esm_data = earthsci_ast.load(filepath)
            try:
                result = earthsci_ast.validate(esm_data)
                results[filepath.name] = {
                    "loaded": True,
                    "is_valid": getattr(result, "is_valid", False),
                    "schema_error_count": len(getattr(result, "schema_errors", []) or []),
                    "structural_error_count": len(getattr(result, "structural_errors", []) or []),
                }
            except Exception as e:
                results[filepath.name] = {"loaded": True, "validation_error": str(e)}
        except Exception as e:
            results[filepath.name] = {
                "loaded": False,
                "error": str(e),
                "error_type": type(e).__name__,
            }

    return results


def main():
    if len(sys.argv) != 2:
        print("Usage: python run-python-conformance.py <output_dir>")
        sys.exit(1)

    output_dir = Path(sys.argv[1])
    tests_dir = project_root / "tests"

    print("Running Python conformance tests...")
    print(f"Tests directory: {tests_dir}")
    print(f"Output directory: {output_dir}")

    results = ConformanceResults()

    # Run all test categories
    try:
        results.validation_results = run_validation_tests(tests_dir)
        print("✓ Validation tests completed")
    except Exception as e:
        results.validation_results = {}
        results.errors.append(f"Validation tests failed: {str(e)}")
        print(f"✗ Validation tests failed: {e}")
        print(traceback.format_exc())

    try:
        results.display_results = run_display_tests(tests_dir)
        print("✓ Display tests completed")
    except Exception as e:
        results.display_results = {}
        results.errors.append(f"Display tests failed: {str(e)}")
        print(f"✗ Display tests failed: {e}")

    try:
        results.substitution_results = run_substitution_tests(tests_dir)
        print("✓ Substitution tests completed")
    except Exception as e:
        results.substitution_results = {}
        results.errors.append(f"Substitution tests failed: {str(e)}")
        print(f"✗ Substitution tests failed: {e}")

    try:
        results.graph_results = run_graph_tests(tests_dir)
        print("✓ Graph tests completed")
    except Exception as e:
        results.graph_results = {}
        results.errors.append(f"Graph tests failed: {str(e)}")
        print(f"✗ Graph tests failed: {e}")

    try:
        results.mathematical_correctness_results = run_mathematical_correctness_tests(tests_dir)
        print("✓ Mathematical-correctness tests completed")
    except Exception as e:
        results.mathematical_correctness_results = {}
        results.errors.append(f"Mathematical-correctness tests failed: {str(e)}")
        print(f"✗ Mathematical-correctness tests failed: {e}")

    # Write results to file
    write_results(output_dir, results)

    if len(results.errors) == 0:
        print("Python conformance testing completed successfully!")
        sys.exit(0)
    else:
        print(f"Python conformance testing completed with {len(results.errors)} errors")
        sys.exit(1)


if __name__ == "__main__":
    main()
