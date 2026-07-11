#!/usr/bin/env python3

"""
Cross-language conformance output comparison tool.

This script compares the outputs from different language implementations
and identifies divergence in validation results, display formats, and
substitution results.
"""

import argparse
import json
from pathlib import Path
from typing import Dict, Any


class ConformanceAnalysis:
    def __init__(self):
        self.languages_tested = []
        self.validation_analysis = {}
        self.display_analysis = {}
        self.substitution_analysis = {}
        self.divergence_summary = {}
        self.overall_status = "PASS"

    def to_dict(self):
        return {
            "languages_tested": self.languages_tested,
            "validation_analysis": self.validation_analysis,
            "display_analysis": self.display_analysis,
            "substitution_analysis": self.substitution_analysis,
            "divergence_summary": self.divergence_summary,
            "overall_status": self.overall_status,
        }


def load_language_results(output_dir: Path, language: str) -> Dict[str, Any]:
    """Load results from a specific language implementation."""
    results_file = output_dir / language / "results.json"
    if not results_file.exists():
        print(f"Warning: Results file not found for {language}: {results_file}")
        return {}

    try:
        with open(results_file, "r") as f:
            return json.load(f)
    except Exception as e:
        print(f"Error loading results for {language}: {e}")
        return {}


def _effective_is_valid(result: Dict[str, Any]) -> bool:
    """Derive whether a language considers a file valid, regardless of which fields it emits.

    Languages differ in how they report errors:
    - Some (Rust, TS) return a result object: is_valid=False, parsed_successfully=True
    - Some (Python, Julia) throw exceptions: parsed_successfully=False, no is_valid field

    Both conventions express the same verdict; this function normalises them.
    """
    if "is_valid" in result:
        return bool(result["is_valid"])
    return bool(result.get("parsed_successfully", True))


def compare_validation_results(language_results: Dict[str, Dict[str, Any]]) -> Dict[str, Any]:
    """Compare validation results across languages."""
    print("Comparing validation results...")

    validation_analysis = {
        "files_tested": set(),
        "divergence": {},
        "error_consistency": {},
        "summary": {"total_files": 0, "consistent_files": 0, "divergent_files": 0},
    }

    # Collect all files tested across languages
    all_files = set()
    for lang, results in language_results.items():
        if "validation_results" in results:
            for category in ["valid", "invalid"]:
                if category in results["validation_results"]:
                    all_files.update(results["validation_results"][category].keys())

    validation_analysis["files_tested"] = sorted(list(all_files))
    validation_analysis["summary"]["total_files"] = len(all_files)

    # Compare each file across languages
    for filename in all_files:
        file_results = {}

        # Collect results for this file from each language
        for lang, results in language_results.items():
            if "validation_results" in results:
                for category in ["valid", "invalid"]:
                    if category in results["validation_results"]:
                        if filename in results["validation_results"][category]:
                            file_results[lang] = {
                                "category": category,
                                **results["validation_results"][category][filename],
                            }

        if len(file_results) < 2:
            continue  # Need at least 2 languages to compare

        # Check for consistency
        is_consistent = True
        reference_lang = list(file_results.keys())[0]
        reference_result = file_results[reference_lang]

        inconsistencies = []

        for lang, result in file_results.items():
            if lang == reference_lang:
                continue

            # Compare the verdict (valid vs invalid) using a normalised signal that
            # works for both exception-based and result-object error reporting styles.
            ref_verdict = _effective_is_valid(reference_result)
            lang_verdict = _effective_is_valid(result)
            if lang_verdict != ref_verdict:
                is_consistent = False
                ref_label = "valid" if ref_verdict else "invalid"
                lang_label = "valid" if lang_verdict else "invalid"
                inconsistencies.append(
                    f"verdict: {reference_lang}={ref_label} vs {lang}={lang_label}"
                )

        if is_consistent:
            validation_analysis["summary"]["consistent_files"] += 1
        else:
            validation_analysis["summary"]["divergent_files"] += 1
            validation_analysis["divergence"][filename] = {
                "languages": list(file_results.keys()),
                "inconsistencies": inconsistencies,
                "details": file_results,
            }

    return validation_analysis


def compare_display_results(language_results: Dict[str, Dict[str, Any]]) -> Dict[str, Any]:
    """Compare display format outputs across languages."""
    print("Comparing display results...")

    display_analysis = {
        "test_files": set(),
        "divergence": {},
        "format_consistency": {"unicode": {}, "latex": {}, "ascii": {}},
        "summary": {"total_tests": 0, "consistent_tests": 0, "divergent_tests": 0},
    }

    # Collect all test files
    all_test_files = set()
    for lang, results in language_results.items():
        if "display_results" in results:
            all_test_files.update(results["display_results"].keys())

    display_analysis["test_files"] = sorted(list(all_test_files))

    # Compare each test file
    for test_file in all_test_files:
        file_results = {}

        # Collect results for this test file from each language
        for lang, results in language_results.items():
            if "display_results" in results and test_file in results["display_results"]:
                file_results[lang] = results["display_results"][test_file]

        if len(file_results) < 2:
            continue

        # Compare display outputs
        divergences = []
        reference_lang = list(file_results.keys())[0]
        reference_result = file_results[reference_lang]

        # Compare chemical formulas
        if "chemical_formulas" in reference_result:
            for i, ref_formula in enumerate(reference_result["chemical_formulas"]):
                for lang, result in file_results.items():
                    if lang == reference_lang or "chemical_formulas" not in result:
                        continue

                    if i < len(result["chemical_formulas"]):
                        lang_formula = result["chemical_formulas"][i]

                        # Compare unicode output
                        if ref_formula.get("output_unicode") != lang_formula.get("output_unicode"):
                            divergences.append(
                                {
                                    "type": "chemical_formula_unicode",
                                    "input": ref_formula.get("input", ""),
                                    "reference_lang": reference_lang,
                                    "reference_output": ref_formula.get("output_unicode", ""),
                                    "divergent_lang": lang,
                                    "divergent_output": lang_formula.get("output_unicode", ""),
                                }
                            )

        # Compare expressions
        if "expressions" in reference_result:
            for i, ref_expr in enumerate(reference_result["expressions"]):
                for lang, result in file_results.items():
                    if lang == reference_lang or "expressions" not in result:
                        continue

                    if i < len(result["expressions"]):
                        lang_expr = result["expressions"][i]

                        # Compare outputs for each format
                        for output_format in ["output_unicode", "output_latex", "output_ascii"]:
                            if ref_expr.get(output_format) != lang_expr.get(output_format):
                                divergences.append(
                                    {
                                        "type": f"expression_{output_format.split('_')[1]}",
                                        "input": ref_expr.get("input", ""),
                                        "reference_lang": reference_lang,
                                        "reference_output": ref_expr.get(output_format, ""),
                                        "divergent_lang": lang,
                                        "divergent_output": lang_expr.get(output_format, ""),
                                    }
                                )

        if divergences:
            display_analysis["divergence"][test_file] = divergences
            display_analysis["summary"]["divergent_tests"] += 1
        else:
            display_analysis["summary"]["consistent_tests"] += 1

        display_analysis["summary"]["total_tests"] += 1

    return display_analysis


def compare_substitution_results(language_results: Dict[str, Dict[str, Any]]) -> Dict[str, Any]:
    """Compare substitution results across languages."""
    print("Comparing substitution results...")

    substitution_analysis = {
        "test_files": set(),
        "divergence": {},
        "summary": {"total_tests": 0, "consistent_tests": 0, "divergent_tests": 0},
    }

    # Collect all test files
    all_test_files = set()
    for lang, results in language_results.items():
        if "substitution_results" in results:
            all_test_files.update(results["substitution_results"].keys())

    substitution_analysis["test_files"] = sorted(list(all_test_files))

    # Compare each test file
    for test_file in all_test_files:
        file_results = {}

        # Collect results for this test file from each language
        for lang, results in language_results.items():
            if "substitution_results" in results and test_file in results["substitution_results"]:
                file_results[lang] = results["substitution_results"][test_file]

        if len(file_results) < 2:
            continue

        # Compare substitution outputs
        divergences = []
        reference_lang = list(file_results.keys())[0]
        reference_result = file_results[reference_lang]

        if isinstance(reference_result, list):
            for i, ref_test in enumerate(reference_result):
                for lang, result in file_results.items():
                    if lang == reference_lang or not isinstance(result, list):
                        continue

                    if i < len(result):
                        lang_test = result[i]

                        # Compare results
                        if ref_test.get("result") != lang_test.get("result"):
                            divergences.append(
                                {
                                    "test_index": i,
                                    "input": ref_test.get("input", ""),
                                    "substitutions": ref_test.get("substitutions", {}),
                                    "reference_lang": reference_lang,
                                    "reference_result": ref_test.get("result", ""),
                                    "divergent_lang": lang,
                                    "divergent_result": lang_test.get("result", ""),
                                }
                            )

        if divergences:
            substitution_analysis["divergence"][test_file] = divergences
            substitution_analysis["summary"]["divergent_tests"] += 1
        else:
            substitution_analysis["summary"]["consistent_tests"] += 1

        substitution_analysis["summary"]["total_tests"] += 1

    return substitution_analysis


def calculate_divergence_summary(analysis: ConformanceAnalysis) -> Dict[str, Any]:
    """Calculate overall divergence summary across all test categories."""
    summary = {
        "total_divergent_categories": 0,
        "categories": {},
        "critical_divergences": [],
        "overall_score": 0.0,
    }

    categories = [
        ("validation", analysis.validation_analysis),
        ("display", analysis.display_analysis),
        ("substitution", analysis.substitution_analysis),
    ]

    total_score = 0.0
    categories_with_tests = 0

    for category_name, category_data in categories:
        if "summary" not in category_data:
            continue

        category_summary = category_data["summary"]
        total_tests = category_summary.get("total_tests", category_summary.get("total_files", 0))
        divergent_tests = category_summary.get(
            "divergent_tests", category_summary.get("divergent_files", 0)
        )

        # A category with nothing to compare (e.g. only one language emitted
        # data for it, so no cross-language pair exists) is UNTESTED — NOT
        # trivially consistent. It is surfaced explicitly and excluded from the
        # overall score so an empty category can never inflate the verdict.
        if total_tests == 0:
            summary["categories"][category_name] = {
                "total_tests": 0,
                "divergent_tests": 0,
                "consistency_score": None,
                "status": "UNTESTED",
            }
            continue

        consistency_score = (total_tests - divergent_tests) / total_tests
        summary["categories"][category_name] = {
            "total_tests": total_tests,
            "divergent_tests": divergent_tests,
            "consistency_score": consistency_score,
            "status": "PASS"
            if consistency_score >= 0.9
            else "WARN"
            if consistency_score >= 0.7
            else "FAIL",
        }

        total_score += consistency_score
        categories_with_tests += 1

        if divergent_tests > 0:
            summary["total_divergent_categories"] += 1

            # Identify critical divergences
            if consistency_score < 0.7:
                summary["critical_divergences"].append(
                    {
                        "category": category_name,
                        "score": consistency_score,
                        "divergent_count": divergent_tests,
                    }
                )

    # Overall score averages only categories that actually had cross-language
    # comparisons. When nothing was comparable the run is UNTESTED, not a pass.
    summary["categories_with_tests"] = categories_with_tests
    if categories_with_tests > 0:
        summary["overall_score"] = total_score / categories_with_tests
    else:
        summary["overall_score"] = 0.0
        summary["overall_status_hint"] = "UNTESTED"

    return summary


def main():
    parser = argparse.ArgumentParser(description="Compare cross-language conformance outputs")
    parser.add_argument("--output-dir", required=True, help="Directory containing language results")
    parser.add_argument(
        "--languages",
        nargs="+",
        default=["julia", "typescript", "python", "rust"],
        help="Languages to compare",
    )
    parser.add_argument(
        "--comparison-output", required=True, help="Output file for comparison analysis"
    )

    args = parser.parse_args()

    output_dir = Path(args.output_dir)

    print("Loading results from language implementations...")
    language_results = {}

    for language in args.languages:
        results = load_language_results(output_dir, language)
        if results:
            language_results[language] = results
            print(f"✓ Loaded results for {language}")
        else:
            print(f"✗ Failed to load results for {language}")

    if len(language_results) < 2:
        print("Error: Need at least 2 language implementations to perform comparison")
        return 1

    print(
        f"\nComparing results from {len(language_results)} languages: {list(language_results.keys())}"
    )

    # Perform comparisons
    analysis = ConformanceAnalysis()
    analysis.languages_tested = list(language_results.keys())

    analysis.validation_analysis = compare_validation_results(language_results)
    analysis.display_analysis = compare_display_results(language_results)
    analysis.substitution_analysis = compare_substitution_results(language_results)

    # Calculate divergence summary
    analysis.divergence_summary = calculate_divergence_summary(analysis)

    # Determine overall status. When no category had a cross-language pair to
    # compare, the run is UNTESTED rather than a (misleading) PASS.
    if analysis.divergence_summary.get("categories_with_tests", 0) == 0:
        analysis.overall_status = "UNTESTED"
    elif analysis.divergence_summary["overall_score"] >= 0.9:
        analysis.overall_status = "PASS"
    elif analysis.divergence_summary["overall_score"] >= 0.7:
        analysis.overall_status = "WARN"
    else:
        analysis.overall_status = "FAIL"

    # Write comparison results
    comparison_output = Path(args.comparison_output)
    comparison_output.parent.mkdir(parents=True, exist_ok=True)

    with open(comparison_output, "w") as f:
        json.dump(analysis.to_dict(), f, indent=2, default=str)

    print(f"\nComparison analysis written to: {comparison_output}")
    print(f"Overall status: {analysis.overall_status}")
    print(f"Overall consistency score: {analysis.divergence_summary['overall_score']:.2%}")

    if analysis.divergence_summary["critical_divergences"]:
        print("\nCritical divergences found:")
        for divergence in analysis.divergence_summary["critical_divergences"]:
            print(
                f"  - {divergence['category']}: {divergence['score']:.2%} consistency ({divergence['divergent_count']} divergent tests)"
            )

    return 0 if analysis.overall_status in ["PASS", "WARN"] else 1


if __name__ == "__main__":
    exit(main())
