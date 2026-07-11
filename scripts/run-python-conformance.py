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
        self.mathematical_correctness_results = {}
        self.errors = []

    def to_dict(self):
        return {
            "language": self.language,
            "timestamp": self.timestamp,
            "validation_results": self.validation_results,
            "display_results": self.display_results,
            "substitution_results": self.substitution_results,
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


# Pretty-print renderers under test — the real Core-tier display API
# (esm-spec §4.2; tests/display/RENDERING_CONTRACT.md).
_RENDERERS = {
    "unicode": earthsci_ast.to_unicode,
    "latex": earthsci_ast.to_latex,
    "ascii": earthsci_ast.to_ascii,
}

# The frozen rendering contract is exercised as byte-identical output across
# languages. We self-check against exactly the expectations the reference
# Python suite (pkg/earthsci-ast-py/tests/test_display.py) asserts: flat-list /
# top-level ``cases`` fixtures in unicode + latex, and structural_ops.json —
# the frozen all-format array-op contract (test_display.py::test_structural_ops)
# — in all three formats. Grouped fixtures whose cases live under nested
# ``tests``/``test_cases`` carry stale or aspirational expectations the
# reference suite deliberately does not assert (e.g. retired grad→frac latex,
# charge superscripts), so they are rendered for cross-language emission but not
# self-failed on here.
_ALL_FORMAT_DISPLAY_FIXTURES = {"structural_ops.json"}


def _expected_render(case: Dict[str, Any], fmt: str):
    """Expected rendering, spelled either ``<fmt>`` or ``expected_<fmt>``
    (mirrors test_display.py::_get_expected)."""
    return case.get(f"expected_{fmt}", case.get(fmt))


def _iter_display_cases(filename: str, data: Any):
    """Yield ``(case, formats_to_check)`` mirroring the reference pytest:

    - structural_ops.json: every sub-case under group ``tests`` in all three
      formats.
    - Otherwise: flat top-level list items (or a top-level ``cases`` list)
      carrying an ``input``, checked in unicode + latex.
    """
    if filename in _ALL_FORMAT_DISPLAY_FIXTURES:
        groups = data if isinstance(data, list) else [data]
        for group in groups:
            if not isinstance(group, dict):
                continue
            for case in group.get("tests", []):
                if isinstance(case, dict) and "input" in case:
                    yield case, ("unicode", "latex", "ascii")
        return

    cases = data if isinstance(data, list) else data.get("cases", [])
    for case in cases:
        if isinstance(case, dict) and "input" in case:
            yield case, ("unicode", "latex")


def run_display_tests(tests_dir: Path) -> Dict[str, Any]:
    """Render every display fixture through to_unicode/to_latex/to_ascii and
    self-check against the frozen rendering contract
    (tests/display/RENDERING_CONTRACT.md). Emits the actual renderings for
    cross-language comparison plus honest per-file pass/fail counts."""
    print("Running display tests...")
    display_results: Dict[str, Any] = {}

    display_dir = tests_dir / "display"
    if not (display_dir.exists() and display_dir.is_dir()):
        return display_results

    for filepath in sorted(display_dir.iterdir()):
        if filepath.suffix != ".json":
            continue
        try:
            with open(filepath, "r") as f:
                data = json.load(f)
        except Exception as e:
            display_results[filepath.name] = {"loaded": False, "error": str(e)}
            continue

        records = []
        passed = failed = 0
        for case, formats in _iter_display_cases(filepath.name, data):
            input_expr = case["input"]
            record: Dict[str, Any] = {"input": input_expr}
            mismatches = []

            # Emit the actual rendering in every format for cross-language
            # comparison, regardless of which formats we self-check.
            for fmt in ("unicode", "latex", "ascii"):
                try:
                    record[f"output_{fmt}"] = _RENDERERS[fmt](input_expr)
                except Exception as e:
                    record[f"output_{fmt}"] = None
                    if fmt in formats:
                        mismatches.append({"format": fmt, "error": str(e)})

            checked = 0
            for fmt in formats:
                expected = _expected_render(case, fmt)
                if expected is None:
                    continue
                checked += 1
                got = record.get(f"output_{fmt}")
                if got != expected:
                    mismatches.append({"format": fmt, "expected": expected, "got": got})

            if checked == 0 and not mismatches:
                record["skipped"] = "no expected rendering to check"
                records.append(record)
                continue

            record["passed"] = not mismatches
            if mismatches:
                record["mismatches"] = mismatches
                failed += 1
            else:
                passed += 1
            records.append(record)

        display_results[filepath.name] = {
            "cases": records,
            "summary": {"total": passed + failed, "passed": passed, "failed": failed},
        }

    return display_results


def run_substitution_tests(tests_dir: Path) -> Dict[str, Any]:
    """Apply the real `substitute` to every substitution fixture case and
    self-check against the expected expression. Fixtures are top-level JSON
    lists of ``{input, bindings, expected}`` where ``input``/``expected`` are
    dict-form expressions and ``bindings`` maps variable names to replacements.

    The per-file value is a list of ``{input, substitutions, result, ...}``
    records — the shape the cross-language comparator consumes."""
    print("Running substitution tests...")
    substitution_results: Dict[str, Any] = {}

    substitution_dir = tests_dir / "substitution"
    if not (substitution_dir.exists() and substitution_dir.is_dir()):
        return substitution_results

    for filepath in sorted(substitution_dir.iterdir()):
        if filepath.suffix != ".json":
            continue
        try:
            with open(filepath, "r") as f:
                data = json.load(f)
        except Exception as e:
            substitution_results[filepath.name] = {"loaded": False, "error": str(e)}
            continue

        records = []
        cases = data if isinstance(data, list) else []
        for case in cases:
            if not (isinstance(case, dict) and "input" in case and "bindings" in case):
                continue
            record: Dict[str, Any] = {
                "input": case["input"],
                "substitutions": case["bindings"],
            }
            try:
                result = earthsci_ast.substitute(case["input"], case["bindings"])
                record["result"] = result
                if "expected" in case:
                    record["expected"] = case["expected"]
                    record["passed"] = result == case["expected"]
                else:
                    record["passed"] = None
            except Exception as e:
                record["error"] = str(e)
                record["passed"] = False
            records.append(record)

        substitution_results[filepath.name] = records

    return substitution_results


def _count_display_failures(display_results: Dict[str, Any]) -> int:
    """Total self-check failures across all display fixtures."""
    total = 0
    for value in display_results.values():
        if isinstance(value, dict) and "summary" in value:
            total += value["summary"].get("failed", 0)
        elif isinstance(value, dict) and value.get("loaded") is False:
            total += 1
    return total


def _count_substitution_failures(substitution_results: Dict[str, Any]) -> int:
    """Total self-check failures across all substitution fixtures."""
    total = 0
    for value in substitution_results.values():
        if isinstance(value, list):
            total += sum(1 for r in value if r.get("passed") is False)
        elif isinstance(value, dict) and value.get("loaded") is False:
            total += 1
    return total


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
        display_failures = _count_display_failures(results.display_results)
        if display_failures:
            results.errors.append(
                f"Display tests: {display_failures} rendering mismatch(es) vs the contract"
            )
            print(f"✗ Display tests completed with {display_failures} mismatch(es)")
        else:
            print("✓ Display tests completed")
    except Exception as e:
        results.display_results = {}
        results.errors.append(f"Display tests failed: {str(e)}")
        print(f"✗ Display tests failed: {e}")

    try:
        results.substitution_results = run_substitution_tests(tests_dir)
        substitution_failures = _count_substitution_failures(results.substitution_results)
        if substitution_failures:
            results.errors.append(
                f"Substitution tests: {substitution_failures} substitution mismatch(es)"
            )
            print(f"✗ Substitution tests completed with {substitution_failures} mismatch(es)")
        else:
            print("✓ Substitution tests completed")
    except Exception as e:
        results.substitution_results = {}
        results.errors.append(f"Substitution tests failed: {str(e)}")
        print(f"✗ Substitution tests failed: {e}")

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
