#!/usr/bin/env python3

"""Cross-language conformance comparator — the gate that decides whether the
five bindings implement ONE specification.

WHAT CHANGED, AND WHY (audit 2026-07-14, C2 + F4)
-------------------------------------------------
The previous comparator could not fail. Three independent reasons:

1. **It passed at 70% divergence.** `return 0 if overall_status in [PASS, WARN]`,
   where PASS ≥ 0.90 and WARN ≥ 0.70. Up to 30% cross-language divergence exited
   0. There are no thresholds here any more: ANY divergence fails. A conformance
   suite that tolerates a percentage of disagreement is not testing conformance,
   it is measuring it and shrugging.

2. **Two of its three categories were structurally vacuous, and they DILUTED the
   third.** Rust emitted literal `"display_results": {}, "substitution_results":
   {}`; Julia and TypeScript populated theirs only for top-level fixture keys
   that no fixture in `tests/display/` has. The comparator took
   `reference_lang = list(file_results)[0]` — julia, empty — found zero
   divergences, and scored both categories a permanent 1.00, which is how a 20%
   VALIDATION divergence still averaged out to PASS. Both categories are now
   REAL: every binding renders the same expanded case list from the shared
   corpus manifest, and every rendering is compared byte-for-byte, against the
   corpus's pinned expectation AND across bindings.

3. **It never checked the EXPECTED outcome.** It compared languages to each
   other and never to the fixture's declared verdict. The `is_expected_error`
   field every producer emitted was read by nobody. A `tests/valid/*.esm`
   rejected by ALL FIVE bindings, or a `tests/invalid/*.esm` accepted by all
   five, was "consistent" → PASS. A shared regression shipped green. Every
   fixture is now asserted against its declared outcome, and every
   `tests/invalid/**` fixture against the `(code, path)` pairs pinned in
   `tests/invalid/expected_errors.json` (CONFORMANCE_SPEC §7.1.2).

Inter-language agreement is still checked — but as a SEPARATE, weaker signal. It
is not a substitute for the expected outcome, because five bindings can agree on
the wrong answer, and did.

CHECKS, IN ORDER OF STRENGTH
---------------------------
  A. COVERAGE     — every binding emitted a record for every manifest entry.
                    A producer that skips an entry fails the run instead of
                    quietly shrinking its own denominator (this is what made F5
                    survivable: four producers skipped the same 69 fixtures).
  B. OUTCOME      — `tests/valid/**` and `lib/**` MUST validate; `tests/invalid/**`
                    MUST be rejected. Per binding, no exceptions.
  C. PINS         — every `tests/invalid/**` rejection must carry the pinned
                    `(code, path)` findings (required-subset, §7.1.2).
  D. RENDERING    — display / substitution output must equal the corpus's pin.
  E. AGREEMENT    — the bindings must agree with each other (validation verdict,
                    every rendering, every substituted AST).

Any failure in ANY check → exit 1.
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parent.parent
EXPECTED_ERRORS = REPO_ROOT / "tests" / "invalid" / "expected_errors.json"


class Failure:
    """One conformance failure, attributable to a language and a fixture."""

    __slots__ = ("check", "language", "item", "expected", "actual", "note")

    def __init__(
        self,
        check: str,
        language: str,
        item: str,
        expected: Any = None,
        actual: Any = None,
        note: str = "",
    ):
        self.check = check
        self.language = language
        self.item = item
        self.expected = expected
        self.actual = actual
        self.note = note

    def to_dict(self) -> dict[str, Any]:
        return {
            "check": self.check,
            "language": self.language,
            "item": self.item,
            "expected": self.expected,
            "actual": self.actual,
            "note": self.note,
        }


def load_language_results(output_dir: Path, language: str) -> dict[str, Any] | None:
    results_file = output_dir / language / "results.json"
    if not results_file.exists():
        return None
    try:
        with open(results_file) as f:
            return json.load(f)
    except Exception as exc:
        print(f"Error loading results for {language}: {exc}", file=sys.stderr)
        return None


# --- A. coverage -------------------------------------------------------------


def check_coverage(
    manifest: dict[str, Any], results: dict[str, dict[str, Any]]
) -> list[Failure]:
    """Every binding must have emitted a record for every manifest entry.

    Without this, a producer that skips a subdirectory reports 100% consistency
    on the fixtures it happened to look at — which is precisely how the entire
    `aggregate` and `template_imports` corpora went unswept in four bindings.
    """
    failures: list[Failure] = []
    expected_sets = {
        "validation_results": [e["id"] for e in manifest["validation_files"]],
        "display_results": [c["id"] for c in manifest["display_cases"]],
        "substitution_results": [c["id"] for c in manifest["substitution_cases"]],
    }

    for language, payload in results.items():
        for section, ids in expected_sets.items():
            emitted = payload.get(section) or {}
            missing = [i for i in ids if i not in emitted]
            if missing:
                failures.append(
                    Failure(
                        "coverage",
                        language,
                        section,
                        expected=f"{len(ids)} records",
                        actual=f"{len(emitted)} records, {len(missing)} missing",
                        note=f"first missing: {missing[:5]}",
                    )
                )
    return failures


# --- B. expected outcome -----------------------------------------------------


def check_outcomes(
    manifest: dict[str, Any], results: dict[str, dict[str, Any]]
) -> list[Failure]:
    """`tests/valid/**` and `lib/**` MUST validate; `tests/invalid/**` MUST be rejected.

    This is the assertion nobody wrote. `lib/**` is in the corpus because
    CONFORMANCE_SPEC §2.2.1 pins the shipped standard library to exactly the
    `tests/valid/` standard — it was previously swept by NOTHING, which is how a
    unit that silently converts a longitude into a duration reached users.
    """
    failures: list[Failure] = []

    for entry in manifest["validation_files"]:
        expect = entry.get("expect")
        if expect is None:
            continue  # no declared outcome; agreement (check E) still applies
        for language, payload in results.items():
            record = (payload.get("validation_results") or {}).get(entry["id"])
            if record is None:
                continue  # already reported by the coverage check
            actual = record.get("outcome")
            if actual != expect:
                failures.append(
                    Failure(
                        "outcome",
                        language,
                        entry["id"],
                        expected=expect,
                        actual=actual,
                        note=_first_reason(record),
                    )
                )
    return failures


def _first_reason(record: dict[str, Any]) -> str:
    """A one-line 'why' for a verdict, so a failure is diagnosable from the log."""
    if record.get("error"):
        return f"{record.get('error_type', 'error')}: {str(record['error'])[:160]}"
    for key in ("schema_errors", "structural_errors"):
        errs = record.get(key) or []
        if errs:
            first = errs[0]
            return f"{key[:-7]}: [{first.get('code') or first.get('keyword')}] @ {first.get('path')}"
    return ""


# --- C. pinned error codes / paths (CONFORMANCE_SPEC §7.1.2) -----------------


def check_pins(
    manifest: dict[str, Any], results: dict[str, dict[str, Any]]
) -> tuple[list[Failure], list[Failure]]:
    """Assert each `tests/invalid/**` rejection against its pinned findings.

    §7.1.2 makes each entry a claim about *why* a file is invalid, not merely
    *that* it is: pinned `structural_errors` are `{path, code}` pairs and pinned
    `schema_errors` are `{path, message, keyword}` triples, each a REQUIRED
    SUBSET of what a binding emits.

    The pinned `message` is deliberately NOT compared. Five different schema
    validators (ajv, jsonschema, santhosh-tekuri, JSONSchema.jl, jsonschema-rs)
    phrase the same violation differently, and §7.1.2 itself concedes they
    "enumerate oneOf/anyOf branches differently". Comparing prose would generate
    guaranteed failures that say nothing about conformance. `(path, keyword)` and
    `(path, code)` are the machine-readable halves, and they are compared
    exactly.

    Returns (failures, corpus_failures) — the second list is fixture-side (a
    missing pin entry), which routes to the corpus owner rather than a binding.
    """
    failures: list[Failure] = []
    corpus_failures: list[Failure] = []

    if not EXPECTED_ERRORS.is_file():
        corpus_failures.append(
            Failure("pins", "-", str(EXPECTED_ERRORS), note="expected_errors.json is missing")
        )
        return failures, corpus_failures

    pins = json.loads(EXPECTED_ERRORS.read_text())

    for entry in manifest["validation_files"]:
        if entry["category"] != "invalid":
            continue
        basename = entry["basename"]
        pin = pins.get(basename)
        if pin is None:
            # §7.1.2: "Every fixture under tests/invalid/** has an entry keyed by
            # its basename." A fixture with no entry pins nothing, so its
            # rejection cannot be checked — that is dead coverage, not coverage.
            corpus_failures.append(
                Failure(
                    "pins",
                    "-",
                    entry["id"],
                    expected="an entry in tests/invalid/expected_errors.json",
                    actual="none",
                    note="fixture pins no (code, path); its rejection is unverifiable",
                )
            )
            continue

        # `resolver_only` fixtures pin no schema/structural findings by
        # construction — the rejection is the whole claim, and check B made it.
        if pin.get("resolver_only"):
            continue

        want_structural = {
            (e.get("code"), e.get("path")) for e in pin.get("structural_errors") or []
        }
        want_schema = {(e.get("keyword"), e.get("path")) for e in pin.get("schema_errors") or []}

        for language, payload in results.items():
            record = (payload.get("validation_results") or {}).get(entry["id"])
            if record is None:
                continue

            if pin.get("parse_error"):
                # A file that is not even JSON must be rejected at load.
                if record.get("resolve_ok"):
                    failures.append(
                        Failure(
                            "pins",
                            language,
                            entry["id"],
                            expected="rejected at load (parse_error)",
                            actual="loaded successfully",
                        )
                    )
                continue

            got_structural = {
                (e.get("code"), e.get("path")) for e in record.get("structural_errors") or []
            }
            got_schema = {
                (e.get("keyword"), e.get("path")) for e in record.get("schema_errors") or []
            }

            missing_structural = want_structural - got_structural
            missing_schema = want_schema - got_schema

            if missing_structural:
                failures.append(
                    Failure(
                        "pins",
                        language,
                        entry["id"],
                        expected=sorted(f"[{c}] @ {p}" for c, p in missing_structural),
                        actual=sorted(f"[{c}] @ {p}" for c, p in got_structural) or ["(none)"],
                        note="pinned structural finding not emitted",
                    )
                )
            if missing_schema:
                failures.append(
                    Failure(
                        "pins",
                        language,
                        entry["id"],
                        expected=sorted(f"[{k}] @ {p}" for k, p in missing_schema),
                        actual=sorted(f"[{k}] @ {p}" for k, p in got_schema) or ["(none)"],
                        note="pinned schema finding not emitted",
                    )
                )

    return failures, corpus_failures


# --- D. rendering vs the corpus pin -----------------------------------------

FORMATS = ("unicode", "latex", "ascii")


def _route_pin_mismatch(
    check: str,
    item: str,
    want: Any,
    got_by_lang: dict[str, Any],
    notes: dict[str, str],
    failures: list[Failure],
    corpus_failures: list[Failure],
) -> None:
    """Attribute a pin mismatch to the binding(s) — or to the pin.

    When EVERY binding produces the same output and it is not the pinned one, the
    thing that is wrong is almost certainly the PIN, not five independent
    implementations that agreed by coincidence. Routing it to the fixture owner
    is the difference between a work-list and a wall of noise.

    This is attribution, not absolution: the run fails either way. Nothing here
    is suppressed, skipped, or scored down — it is only addressed to whoever can
    fix it. (`tests/display/RENDERING_CONTRACT.md` is normative and says all five
    bindings MUST be byte-identical, so a unanimous deviation means the contract
    and its fixtures have drifted apart and one of them has to move.)
    """
    mismatched = {lang: got for lang, got in got_by_lang.items() if got != want}
    if not mismatched:
        return

    unanimous = len(mismatched) == len(got_by_lang) and len(got_by_lang) > 1
    agreed = len({json.dumps(v, sort_keys=True, default=str) for v in mismatched.values()}) == 1

    if unanimous and agreed:
        # All bindings produce the SAME output, and it is not the golden. This is
        # a triage signal, NOT a verdict: unanimity is not proof the golden
        # drifted — five bindings can share the same bug (audit F-7). Route it to
        # the fixture owner so it is not misattributed to one binding, but frame
        # it as a question. The run fails red either way; a human decides whether
        # the golden or all five bindings are wrong.
        corpus_failures.append(
            Failure(
                f"{check}:unanimous_mismatch",
                "+".join(sorted(got_by_lang)),
                item,
                expected=want,
                actual=next(iter(mismatched.values())),
                note="all bindings agree on the same output, which differs from the golden — verify whether the golden or all five bindings are wrong",
            )
        )
        return

    for lang, got in mismatched.items():
        failures.append(
            Failure(check, lang, item, expected=want, actual=got, note=notes.get(lang, ""))
        )


def check_rendering(
    manifest: dict[str, Any], results: dict[str, dict[str, Any]]
) -> tuple[list[Failure], list[Failure]]:
    """Display renderings and substituted ASTs must equal the corpus's pin.

    This is the display/substitution analogue of check B: the fixture DECLARES an
    answer, so compare against it, not merely against the other bindings.
    `tests/display/RENDERING_CONTRACT.md` is explicit that all five bindings must
    produce byte-identical output "verified by the shared fixtures in this
    directory via ./scripts/test-conformance.sh" — a claim the harness had never
    actually made.
    """
    failures: list[Failure] = []
    corpus_failures: list[Failure] = []

    for case in manifest["display_cases"]:
        expected = case.get("expected") or {}
        for fmt, want in expected.items():
            got_by_lang: dict[str, Any] = {}
            notes: dict[str, str] = {}
            for language, payload in results.items():
                record = (payload.get("display_results") or {}).get(case["id"])
                if record is None:
                    continue
                got_by_lang[language] = record.get(fmt)
                notes[language] = (record.get("errors") or {}).get(fmt, "")
            _route_pin_mismatch(
                "display", f"{case['id']}[{fmt}]", want, got_by_lang, notes, failures, corpus_failures
            )

    for case in manifest["substitution_cases"]:
        want = case.get("expected")
        if want is None:
            continue
        got_by_lang = {}
        notes = {}
        for language, payload in results.items():
            record = (payload.get("substitution_results") or {}).get(case["id"])
            if record is None:
                continue
            got_by_lang[language] = record.get("result")
            notes[language] = record.get("error", "")
        _route_pin_mismatch(
            "substitution", case["id"], want, got_by_lang, notes, failures, corpus_failures
        )

    return failures, corpus_failures


# --- E. cross-language agreement --------------------------------------------


def check_agreement(
    manifest: dict[str, Any], results: dict[str, dict[str, Any]]
) -> list[Failure]:
    """The bindings must agree with each other.

    Weaker than checks B/C/D — five bindings can agree on the wrong answer — but
    it catches everything the corpus has not pinned an answer for, and it is the
    only check that applies to a fixture with no declared outcome.
    """
    failures: list[Failure] = []

    def disagree(section: str, item_id: str, values: dict[str, Any], kind: str) -> None:
        distinct = {json.dumps(v, sort_keys=True, default=str) for v in values.values()}
        if len(distinct) > 1:
            groups: dict[str, list[str]] = defaultdict(list)
            for lang, value in values.items():
                groups[json.dumps(value, sort_keys=True, default=str)].append(lang)
            failures.append(
                Failure(
                    kind,
                    "+".join(sorted(values)),
                    item_id,
                    expected="all bindings agree",
                    actual={v[:200]: sorted(langs) for v, langs in groups.items()},
                    note=f"{len(distinct)} distinct {section} outputs",
                )
            )

    for entry in manifest["validation_files"]:
        verdicts = {}
        for language, payload in results.items():
            record = (payload.get("validation_results") or {}).get(entry["id"])
            if record is not None:
                verdicts[language] = record.get("outcome")
        if len(verdicts) >= 2:
            disagree("verdict", entry["id"], verdicts, "agreement:validation")

    for case in manifest["display_cases"]:
        for fmt in FORMATS:
            renderings = {}
            for language, payload in results.items():
                record = (payload.get("display_results") or {}).get(case["id"])
                if record is not None:
                    renderings[language] = record.get(fmt)
            if len(renderings) >= 2:
                disagree("rendering", f"{case['id']}[{fmt}]", renderings, "agreement:display")

    for case in manifest["substitution_cases"]:
        outputs = {}
        for language, payload in results.items():
            record = (payload.get("substitution_results") or {}).get(case["id"])
            if record is not None:
                outputs[language] = record.get("result")
        if len(outputs) >= 2:
            disagree("substitution", case["id"], outputs, "agreement:substitution")

    return failures


# --- reporting ---------------------------------------------------------------


def summarize(failures: list[Failure], corpus_failures: list[Failure]) -> None:
    total = len(failures) + len(corpus_failures)
    if total == 0:
        print("\n✓ CONFORMANCE PASS — every binding agrees with the corpus and with each other.")
        return

    print(f"\n✗ CONFORMANCE FAIL — {total} failure(s)\n")

    by_check: Counter[tuple[str, str]] = Counter()
    for f in failures:
        by_check[(f.check, f.language)] += 1

    if by_check:
        print("BINDING failures (route to the binding owner):")
        print(f"  {'check':<26} {'language':<28} count")
        for (check, language), count in sorted(by_check.items(), key=lambda kv: -kv[1]):
            print(f"  {check:<26} {language:<28} {count}")

    if corpus_failures:
        print(f"\nCORPUS failures (route to the fixture owner): {len(corpus_failures)}")
        by_kind: Counter[str] = Counter(f.check for f in corpus_failures)
        for kind, count in sorted(by_kind.items()):
            print(f"  {kind:<26} {count}")
        for f in corpus_failures[:10]:
            print(f"    {f.item}: {f.note}")
        if len(corpus_failures) > 10:
            print(f"    ... and {len(corpus_failures) - 10} more (see the analysis JSON)")

    # An outcome every binding gets "wrong" the same way is not five independent
    # regressions — it is the corpus and the bindings disagreeing about the SPEC.
    # Surface it separately: it is the shortest list in the report and the one
    # most likely to be a fixture or spec defect rather than a binding defect.
    outcome_langs: dict[str, set[str]] = defaultdict(set)
    for f in failures:
        if f.check == "outcome":
            outcome_langs[f.item].add(f.language)
    n_langs = len({f.language for f in failures if f.check == "outcome"})
    unanimous = sorted(i for i, langs in outcome_langs.items() if len(langs) >= n_langs > 1)
    if unanimous:
        print(
            f"\nUNANIMOUS outcome disagreements ({len(unanimous)}) — every binding disagrees "
            "with the corpus, so suspect the FIXTURE or the SPEC first:"
        )
        for item in unanimous:
            print(f"  {item}")

    print("\nFirst failures per check (full list in the analysis JSON):")
    seen: Counter[tuple[str, str]] = Counter()
    for f in failures:
        key = (f.check, f.language)
        seen[key] += 1
        if seen[key] > 3:
            continue
        print(f"  [{f.check}] {f.language} · {f.item}")
        print(f"      expected: {str(f.expected)[:150]}")
        print(f"      actual:   {str(f.actual)[:150]}")
        if f.note:
            print(f"      note:     {str(f.note)[:150]}")


def build_analysis(
    languages: list[str],
    manifest: dict[str, Any],
    failures: list[Failure],
    corpus_failures: list[Failure],
) -> dict[str, Any]:
    """Machine-readable analysis.

    Keeps the `*_analysis` / `divergence_summary` keys the HTML report generator
    reads, but their `divergent_*` counts are now REAL — and the overall status
    is a boolean verdict, not a score with a tolerance band.
    """
    counts: Counter[str] = Counter(f.check for f in failures)

    def section(name: str, total: int) -> dict[str, Any]:
        divergent = sum(v for k, v in counts.items() if k.startswith(name))
        return {
            "summary": {
                "total_tests": total,
                "divergent_tests": divergent,
                "consistent_tests": max(total - divergent, 0),
            },
            "divergence": {
                f.item: f.to_dict() for f in failures if f.check.startswith(name)
            },
        }

    n_val = len(manifest["validation_files"])
    n_disp = len(manifest["display_cases"]) * len(FORMATS)
    n_sub = len(manifest["substitution_cases"])
    status = "PASS" if not failures and not corpus_failures else "FAIL"

    return {
        "languages_tested": languages,
        "overall_status": status,
        "validation_analysis": section("outcome", n_val),
        "display_analysis": section("display", n_disp),
        "substitution_analysis": section("substitution", n_sub),
        "divergence_summary": {
            "overall_score": 1.0 if status == "PASS" else 0.0,
            "categories": {check: count for check, count in sorted(counts.items())},
            "critical_divergences": [
                {"category": check, "divergent_count": count}
                for check, count in sorted(counts.items())
            ],
            "total_divergent_categories": len(counts),
        },
        "corpus_failures": [f.to_dict() for f in corpus_failures],
        "failures": [f.to_dict() for f in failures],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Compare cross-language conformance outputs")
    parser.add_argument("--output-dir", required=True, help="Directory containing language results")
    parser.add_argument(
        "--languages",
        nargs="+",
        default=["julia", "typescript", "python", "rust", "go"],
        help="Languages to compare",
    )
    parser.add_argument("--manifest", required=True, help="Shared corpus manifest")
    parser.add_argument(
        "--comparison-output", required=True, help="Output file for comparison analysis"
    )
    args = parser.parse_args()

    output_dir = Path(args.output_dir)
    manifest = json.loads(Path(args.manifest).read_text())

    results: dict[str, dict[str, Any]] = {}
    missing_languages: list[str] = []
    for language in args.languages:
        payload = load_language_results(output_dir, language)
        if payload is None:
            missing_languages.append(language)
            print(f"✗ No results for {language}")
        else:
            results[language] = payload
            print(f"✓ Loaded results for {language}")

    if len(results) < 2:
        print("Error: need at least 2 language implementations to compare", file=sys.stderr)
        return 1

    print(
        f"\nComparing {len(results)} bindings over "
        f"{len(manifest['validation_files'])} validation files, "
        f"{len(manifest['display_cases'])} display cases, "
        f"{len(manifest['substitution_cases'])} substitution cases"
    )

    failures: list[Failure] = []
    corpus_failures: list[Failure] = []

    failures += check_coverage(manifest, results)
    failures += check_outcomes(manifest, results)

    pin_failures, pin_corpus = check_pins(manifest, results)
    failures += pin_failures
    corpus_failures += pin_corpus

    render_failures, render_corpus = check_rendering(manifest, results)
    failures += render_failures
    corpus_failures += render_corpus

    failures += check_agreement(manifest, results)

    # A language the caller ASKED for that produced nothing is a failure of the
    # run, not a smaller run. (The old comparator printed a warning and compared
    # whatever was left.)
    for language in missing_languages:
        failures.append(
            Failure(
                "coverage",
                language,
                "results.json",
                expected="a results.json from this binding",
                actual="missing",
                note="the producer did not run, or crashed before writing output",
            )
        )

    analysis = build_analysis(list(results), manifest, failures, corpus_failures)

    comparison_output = Path(args.comparison_output)
    comparison_output.parent.mkdir(parents=True, exist_ok=True)
    comparison_output.write_text(json.dumps(analysis, indent=2, default=str))
    print(f"\nComparison analysis written to: {comparison_output}")

    summarize(failures, corpus_failures)

    # ANY divergence fails. There is no threshold and no WARN band: a
    # conformance gate that exits 0 on 30% disagreement is not a gate.
    return 0 if analysis["overall_status"] == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
