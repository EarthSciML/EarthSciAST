#!/usr/bin/env python3
"""Inline-test conformance runner (CONFORMANCE_SPEC.md §5.45).

The generic driver for a conformance tier whose fixtures are **documents that
carry their own `tests` blocks** (esm-spec §6.6). Each binding runs the same
documents through its OWN §6.6 runner under a NAMED compiler and reports, per
assertion, whether it passed and what the actual reduction value was. The runner
then gates two things that are not the same thing:

  * **the authored expectation** — `passed`, which is each binding's own §6.6.3
    predicate over the value the document declares. The document is the oracle
    here, and it is outside every binding.
  * **the reference actual** — `actual` against `golden/<id>.json`, the Julia
    `interpreter`'s number for the same assertion. The interpreter shares no
    code with the compiled or vectorized tiers it gates, so a compiled path that
    reproduces it has been checked against something it does not share code
    with.

Gating both is the point. An assertion whose band is loose enough to admit two
different answers passes for both bindings and still reports the disagreement,
because the goldens do not move.

Why this runner and not `compiler_agreement`'s: that tier compares whole STATE
trajectories keyed by bare column-major element name, so it can only carry an
anchor that names a state element directly. A §6.6.5 `coords` assertion, a
`reduce` assertion, and an assertion on an OBSERVED all name something that is
not a state element, and those are most of what a semantics fixture asserts.
Delegating the assertion to each binding's own inline-test runner is also what
makes the comparison meaningful: that runner IS the thing under test.

Three modes, one harness (mirrors `run-compiler-agreement-conformance.py`):

  * ``--self-test`` — no live bindings. Validates the manifest and both ledgers,
    and checks every COMMITTED golden against the DOCUMENT's own `expected`
    values at each assertion's resolved §6.6.4 tolerance, so a golden minted
    from a broken build cannot sit there agreeing with itself. Then asserts the
    harness REJECTS a value moved off its band, a missing assertion, an error,
    and a refusal from a binding the fixture's `required` map names — while
    REPORTING an unrequired refusal as a named exclusion. The always-on guard.
  * ``--write-golden --bindings julia --compiler interpreter`` — mint
    ``golden/<id>.json``. It refuses to mint from any other binding or compiler:
    the reference is a decision of record, not a flag.
  * producers (``--bindings julia,rust,python --compiler native``) — dispatch
    each binding's adapter once and gate every fixture.

Usage:
    python3 scripts/run-inline-tests-conformance.py \\
        --manifest tests/conformance/broadcast_alignment/manifest.json --self-test
    EARTHSCI_INLINE_TESTS_ADAPTER_JULIA="julia pkg/EarthSciAST.jl/scripts/inline_tests_adapter.jl" \\
        python3 scripts/run-inline-tests-conformance.py \\
            --manifest <m> --write-golden --bindings julia --compiler interpreter
    python3 scripts/run-inline-tests-conformance.py --manifest <m> \\
        --bindings julia --compiler native --output conformance-results/<tier>/julia-native.json

Exit codes:
    0  the self-test passed, or every binding answered within tolerance (a named
       refusal and an unavailable OPTIONAL binding are green, and both are named
       in the report and on the console)
    1  a failed assertion, a value off the golden, an unnamed refusal, an error,
       an `unavailable` from a required binding, a broken adapter, or a
       self-test failure
    2  a manifest or configuration error (no run attempted)
"""

from __future__ import annotations

import copy
import json
import math
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

# The shared harness (adapter discovery, the CLI skeleton, the report writer)
# lives in scripts/conformance_lib.py; hyphenated runner filenames cannot import
# each other, so put scripts/ on sys.path first.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from conformance_lib import (  # noqa: E402 — needs the sys.path bootstrap above
    KNOWN_BINDINGS,
    REPO_ROOT,
    AdapterHarness,
    ManifestError,
    _eprint,
    build_parser,
    write_report,
)

DEFAULT_MANIFEST = REPO_ROOT / "tests" / "conformance" / "broadcast_alignment" / "manifest.json"
DEFAULT_OUTPUT = REPO_ROOT / "conformance-results" / "inline_tests" / "report.json"

# The reference this tier family mints its goldens from. A decision of record
# (the plan's ruling, CONFORMANCE_SPEC §5.45.2), not a runtime choice: the
# `interpreter` is complete over the evaluable core (esm-libraries-spec §2.5.10)
# and shares no code with the compiled or vectorized tiers it gates.
REFERENCE_BINDING = "julia"
REFERENCE_COMPILER = "interpreter"

# API_SPEC §5.8's closed compiler vocabulary. A value outside it is a typo, and
# a typo must not read like a missing runtime.
COMPILERS = ("interpreter", "native", "xla", "mtk", "sympy")

# The diagnostic code that says a COMPILER is missing here, as opposed to one
# that cannot run a document. It is only ever the whole-output `unavailable`.
UNAVAILABLE_CODE = "compiler_unavailable"

# The §6.6.4 default when no level supplies a bound.
DEFAULT_ASSERTION_REL = 1e-6
DEFAULT_ASSERTION_ABS = 0.0


# === Manifest =============================================================


def tests_root(manifest_path: Path) -> Path:
    """The repository's `tests/` directory, found by walking UP from the
    manifest. Fixture paths are written relative to it, so a tier can reference
    a document another tier already owns without copying it."""
    for parent in manifest_path.resolve().parents:
        if parent.name == "tests":
            return parent
    return REPO_ROOT / "tests"


def load_manifest(path: Path) -> dict:
    try:
        with path.open() as f:
            manifest = json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        raise ManifestError(f"failed to load manifest {path}: {e}") from e
    if not isinstance(manifest, dict):
        raise ManifestError(f"{path}: top-level must be a JSON object")
    if manifest.get("runner") != "inline_tests":
        raise ManifestError(
            f"{path}: this runner drives a manifest whose `runner` is "
            f"'inline_tests'; got {manifest.get('runner')!r}"
        )
    for key in ("category", "version", "description"):
        if not isinstance(manifest.get(key), str):
            raise ManifestError(f"{path}: {key} must be a string")
    if manifest.get("reference_binding") != REFERENCE_BINDING:
        raise ManifestError(
            f"{path}: reference_binding must be {REFERENCE_BINDING!r} (CONFORMANCE_SPEC §5.45.2)"
        )
    if manifest.get("reference_compiler") != REFERENCE_COMPILER:
        raise ManifestError(
            f"{path}: reference_compiler must be {REFERENCE_COMPILER!r} (CONFORMANCE_SPEC §5.45.2)"
        )
    required = manifest.get("bindings_required")
    if not isinstance(required, list) or not required:
        raise ManifestError(f"{path}: bindings_required must be a non-empty array")
    for b in required:
        if b not in KNOWN_BINDINGS:
            raise ManifestError(f"{path}: bindings_required names unknown binding {b!r}")
    tol = manifest.get("tolerances")
    if not isinstance(tol, dict):
        raise ManifestError(f"{path}: tolerances must be an object")
    for key in ("golden_rtol", "golden_atol"):
        if not isinstance(tol.get(key), (int, float)):
            raise ManifestError(f"{path}: tolerances.{key} must be a number")

    fixtures = manifest.get("fixtures")
    if not isinstance(fixtures, list) or not fixtures:
        raise ManifestError(f"{path}: fixtures must be a non-empty array")
    seen: set[str] = set()
    for fx in fixtures:
        if not isinstance(fx, dict):
            raise ManifestError(f"{path}: every fixture must be an object")
        fid = fx.get("id")
        if not isinstance(fid, str) or not fid:
            raise ManifestError(f"{path}: every fixture needs a non-empty string id")
        if fid in seen:
            raise ManifestError(f"{path}: duplicate fixture id {fid!r}")
        seen.add(fid)
        for key in ("path", "model"):
            if not isinstance(fx.get(key), str) or not fx[key]:
                raise ManifestError(f"{path}: fixtures[{fid}].{key} must be a non-empty string")
        _validate_golden_field(path, fid, fx)
        _validate_ledgers(path, fid, fx, required)
    return manifest


def _validate_golden_field(path: Path, fid: str, fx: dict) -> None:
    """`golden` names the committed reference file, or is `null` for the ONE
    case the reference cannot produce: a fixture the Julia `interpreter` itself
    REFUSES.

    Such a fixture is not ungated — its assertions are still gated against the
    DOCUMENT's own `expected`, which is an oracle outside every binding — but it
    carries no cross-compiler drift check, and that has to be stated rather than
    inferred from a missing file. So `null` requires a written
    `golden_absent_reason` AND a named exclusion for the reference binding: if
    the reference can run the fixture, there is no excuse for not minting from
    it."""
    g = fx.get("golden")
    if isinstance(g, str) and g:
        return
    if g is not None:
        raise ManifestError(f"{path}: fixtures[{fid}].golden must be a non-empty string or null")
    if not isinstance(fx.get("golden_absent_reason"), str) or not fx["golden_absent_reason"]:
        raise ManifestError(
            f"{path}: fixtures[{fid}] has no golden and no golden_absent_reason. "
            f"A missing reference is a statement, and it has to be written down."
        )
    if not any(ex.get("binding") == REFERENCE_BINDING for ex in (fx.get("named_exclusions") or [])):
        raise ManifestError(
            f"{path}: fixtures[{fid}] has no golden, but nothing records the "
            f"{REFERENCE_BINDING} reference refusing it. The only reason a fixture may "
            f"carry no golden is that the reference cannot produce one."
        )


def has_golden(fx: dict) -> bool:
    return isinstance(fx.get("golden"), str) and bool(fx["golden"])


def _validate_ledgers(path: Path, fid: str, fx: dict, bindings_required: list) -> None:
    """The two ledgers a fixture carries, and the one contradiction between
    them that must be a manifest error rather than a run-time surprise.

    ``required`` (binding -> the compilers that MUST run THIS document) and
    ``named_exclusions`` (binding + compiler -> the refusal that is expected,
    with its code) answer opposite questions, so a fixture that both REQUIRES
    and EXCLUDES the same pair says two things at once. Catching it here means
    the contradiction is reported once, by the always-on self-test, rather than
    as a confusing red in whichever stage happens to run first."""
    req = fx.get("required")
    if not isinstance(req, dict):
        raise ManifestError(f"{path}: fixtures[{fid}].required must be an object")
    for b in bindings_required:
        if b not in req:
            raise ManifestError(
                f"{path}: fixtures[{fid}].required has no entry for required binding {b!r}; "
                f"an empty list is how a fixture says 'no compiler of this binding runs it'"
            )
    for b, compilers in req.items():
        if b not in KNOWN_BINDINGS:
            raise ManifestError(f"{path}: fixtures[{fid}].required names unknown binding {b!r}")
        if not isinstance(compilers, list):
            raise ManifestError(f"{path}: fixtures[{fid}].required[{b}] must be an array")
        for c in compilers:
            if c not in COMPILERS:
                raise ManifestError(
                    f"{path}: fixtures[{fid}].required[{b}] names {c!r}, which is outside "
                    f"API_SPEC §5.8's vocabulary {COMPILERS}"
                )

    for ex in fx.get("named_exclusions") or []:
        if not isinstance(ex, dict):
            raise ManifestError(f"{path}: fixtures[{fid}].named_exclusions holds a non-object")
        b = ex.get("binding")
        if b not in KNOWN_BINDINGS:
            raise ManifestError(
                f"{path}: fixtures[{fid}] named exclusion names unknown binding {b!r}"
            )
        compilers = ex.get("compilers")
        if not isinstance(compilers, list) or not compilers:
            raise ManifestError(
                f"{path}: fixtures[{fid}] named exclusion for {b!r} must list compilers"
            )
        for key in ("code", "reason"):
            if not isinstance(ex.get(key), str) or not ex[key]:
                raise ManifestError(
                    f"{path}: fixtures[{fid}] named exclusion for {b!r} needs a {key}"
                )
        if ex["code"] == UNAVAILABLE_CODE:
            raise ManifestError(
                f"{path}: fixtures[{fid}] named exclusion for {b!r} records "
                f"{UNAVAILABLE_CODE!r}. That is a fact about the BINDING, answered as the "
                f"whole-output `unavailable` and gated by `bindings_required`; a "
                f"per-fixture ledger entry for it would merge the two ledgers."
            )
        for c in compilers:
            if c not in COMPILERS:
                raise ManifestError(
                    f"{path}: fixtures[{fid}] named exclusion for {b!r} names compiler {c!r}, "
                    f"which is outside API_SPEC §5.8's vocabulary"
                )
            if c in (req.get(b) or []):
                raise ManifestError(
                    f"{path}: fixtures[{fid}] both REQUIRES and EXCLUDES {b}/{c}. "
                    f"`required` says that compiler must run this document; a named "
                    f"exclusion says it refuses it. One of the two is stale."
                )


def excluded_reason(fx: dict, binding: str, compiler: str) -> dict | None:
    """The named exclusion covering this (binding, compiler), or None."""
    for ex in fx.get("named_exclusions") or []:
        if ex.get("binding") == binding and compiler in (ex.get("compilers") or []):
            return ex
    return None


# === The documents and their authored expectations ========================


def fixture_path(manifest_path: Path, fx: dict) -> Path:
    """Resolve a fixture's `.esm`: relative to the manifest's own directory
    first (a document the tier authored), then relative to `tests/` (a document
    another tier already owns)."""
    rel = fx["path"]
    local = (manifest_path.parent / rel).resolve()
    if local.is_file():
        return local
    return (tests_root(manifest_path) / rel).resolve()


def golden_path(manifest_path: Path, fx: dict) -> Path:
    return (manifest_path.parent / fx["golden"]).resolve()


def _num(v: Any) -> float:
    """A number the way an adapter may have written it. A non-finite travels as
    the string `float()` parses, so a regression fails its own assertion by name
    instead of arriving as a silent `null`.

    A JSON `null` and a JSON boolean are NOT numbers and raise `TypeError`:
    Python would read `true` as `1.0`, and a value that is the wrong KIND must
    not be graded as though it were the right number."""
    if v is None or isinstance(v, bool):
        raise TypeError(f"{v!r} is not a number")
    return float(v)


def authored_assertions(manifest_path: Path, fx: dict) -> list[dict]:
    """Every assertion the DOCUMENT declares for the fixture's model, flattened
    to `{test_id, assertion_idx, variable, expected, rtol, atol}`.

    `assertion_idx` is 1-based within its test, which is the numbering every
    binding's §6.6 runner reports. Tolerance resolves per FIELD through
    assertion -> test -> model -> the §6.6.4 default, so an assertion that pins
    only `abs` still inherits the model's `rel` (CONFORMANCE_SPEC §5.21)."""
    path = fixture_path(manifest_path, fx)
    try:
        with path.open() as f:
            doc = json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        raise ManifestError(f"fixture {fx['id']}: cannot read {path}: {e}") from e
    models = doc.get("models") or {}
    model = models.get(fx["model"])
    if not isinstance(model, dict):
        raise ManifestError(f"fixture {fx['id']}: {path} has no model {fx['model']!r}")
    model_tol = model.get("tolerance") or {}
    out: list[dict] = []
    for test in model.get("tests") or []:
        test_tol = test.get("tolerance") or {}
        for i, a in enumerate(test.get("assertions") or [], start=1):
            a_tol = a.get("tolerance") or {}
            where = f"fixture {fx['id']}: {test.get('id')}#{i}"
            try:
                expected = _num(a.get("expected"))
                rtol = _num(_resolve_bound("rel", a_tol, test_tol, model_tol))
                atol = _num(_resolve_bound("abs", a_tol, test_tol, model_tol))
            except (TypeError, ValueError) as e:
                raise ManifestError(
                    f"{where}: `expected` and every tolerance bound must be numbers "
                    f"(esm-schema `Assertion`): {e}"
                ) from e
            out.append(
                {
                    "test_id": str(test.get("id")),
                    "assertion_idx": i,
                    "variable": str(a.get("variable")),
                    "expected": expected,
                    "rtol": rtol,
                    "atol": atol,
                }
            )
    if not out:
        raise ManifestError(
            f"fixture {fx['id']}: model {fx['model']!r} in {path} declares no inline "
            f"assertions, so there is nothing for this tier to gate"
        )
    return out


def _resolve_bound(field: str, a_tol: dict, test_tol: dict, model_tol: dict) -> Any:
    """One §6.6.4 bound, resolved PER FIELD through assertion -> test -> model
    -> the implementation default. Only an ABSENT key falls through: an explicit
    `0` is a declaration ("no bound of this kind") and stops the chain, and a
    JSON `null` is read as absent, which §6.6.4 requires of a runtime that
    accepts one."""
    for level in (a_tol, test_tol, model_tol):
        if level.get(field) is not None:
            return level[field]
    return DEFAULT_ASSERTION_REL if field == "rel" else DEFAULT_ASSERTION_ABS


def _key(entry: dict) -> tuple[str, int]:
    return (str(entry["test_id"]), int(entry["assertion_idx"]))


def within(got: float, want: float, rtol: float, atol: float) -> bool:
    """The esm-spec §6.6.3 pass predicate, as the spec states it:

        actual == expected  OR  (both finite AND |a - e| <= max(abs, rel * max(|a|, |e|)))

    Finiteness is judged BEFORE tolerance, so no bound admits an infinity or a
    NaN; the equality clause is what lets the same infinity match, and what
    makes a `{rel: 0, abs: 0}` band an exact comparison. The relative scale is
    symmetric in the two values and carries no epsilon floor. The golden band
    uses the same predicate at the tier's own `golden_rtol` / `golden_atol`."""
    if got == want:
        return True
    if not (math.isfinite(got) and math.isfinite(want)):
        return False
    return abs(got - want) <= max(atol, rtol * max(abs(got), abs(want)))


# === Gating ===============================================================


def compare_fixture(
    fx: dict,
    produced: Any,
    golden: dict | None,
    authored: list[dict],
    rtol: float,
    atol: float,
    binding: str,
    compiler: str,
) -> dict:
    """Gate one fixture's answer from one binding under one compiler.

    `golden` is `None` for the one case the reference cannot produce — a
    fixture the Julia `interpreter` itself refuses. The authored expectation is
    then the whole gate, which is still an oracle outside every binding; what is
    missing is the cross-compiler drift check, and the manifest says so in
    `golden_absent_reason`."""
    if not isinstance(produced, dict):
        return {"status": "invalid", "problems": ["adapter entry is not an object"]}

    status = produced.get("status")
    if status == "refused":
        ex = excluded_reason(fx, binding, compiler)
        code = str(produced.get("code") or "")
        reason = str(produced.get("reason") or "")
        if code == UNAVAILABLE_CODE:
            return {
                "status": "invalid",
                "problems": [
                    f"{binding}/{compiler} answered {UNAVAILABLE_CODE!r} for this ONE fixture "
                    f"({reason}). A missing compiler is a fact about the binding and is the "
                    f"WHOLE adapter output `unavailable` (CONFORMANCE_SPEC §5.45.3), which is "
                    f"what the `bindings_required` ledger is consulted on; the adapter is "
                    f"broken."
                ],
                "code": code,
                "reason": reason,
            }
        if ex is None:
            return {
                "status": "refused_unnamed",
                "problems": [
                    f"{binding}/{compiler} refused this fixture with {code!r} ({reason}), and "
                    f"no named exclusion covers it. A refusal is a NAMED exclusion or a "
                    f"failure; it is never a silent skip."
                ],
                "code": code,
                "reason": reason,
            }
        if ex["code"] != code:
            return {
                "status": "refused_wrong_code",
                "problems": [
                    f"{binding}/{compiler} refused with {code!r}, but the named exclusion "
                    f"records {ex['code']!r}. The refusal moved; the ledger did not."
                ],
                "code": code,
                "reason": reason,
            }
        return {
            "status": "ok",
            "outcome": "named_exclusion",
            "code": code,
            "reason": reason,
            "ledger_reason": ex["reason"],
        }

    if "error" in produced:
        return {"status": "error", "problems": [str(produced["error"])]}

    entries = produced.get("assertions")
    if not isinstance(entries, list):
        return {"status": "invalid", "problems": ["adapter entry carries no `assertions` array"]}

    ex = excluded_reason(fx, binding, compiler)
    by_key = {}
    problems: list[str] = []
    for e in entries:
        if not isinstance(e, dict) or "test_id" not in e or "assertion_idx" not in e:
            problems.append(f"malformed assertion entry {e!r}")
            continue
        by_key[_key(e)] = e

    golden_by_key = {}
    for g in (golden or {}).get("assertions") or []:
        if isinstance(g, dict) and "test_id" in g and "assertion_idx" in g:
            golden_by_key[_key(g)] = g
        else:
            problems.append(f"malformed golden entry {g!r}")
    authored_by_key = {_key(a): a for a in authored}

    checked = 0
    for key, want in authored_by_key.items():
        label = f"{key[0]}#{key[1]} ({want['variable']})"
        got = by_key.get(key)
        if got is None:
            problems.append(f"{key[0]}#{key[1]}: the adapter reported no result")
            continue
        passed = got.get("passed")
        if not isinstance(passed, bool):
            problems.append(f"{label}: `passed` is {passed!r}, not a JSON boolean")
            continue
        raw = got.get("actual")
        if not passed:
            problems.append(
                f"{label}: the binding's own §6.6.3 predicate FAILED — actual {raw!r} vs "
                f"the document's expected {want['expected']!r}: {got.get('message', '')}"
            )
            continue
        if raw is None:
            problems.append(f"{label}: passed with no `actual` recorded")
            continue
        try:
            actual = _num(raw)
        except (TypeError, ValueError):
            problems.append(f"{label}: `actual` {raw!r} is not a number")
            continue
        # The runner's OWN verdict on the authored expectation. `passed` is the
        # binding's word for it, and a binding whose predicate is broken would
        # otherwise be trusted by the one gate a no-golden fixture has.
        if not within(actual, want["expected"], want["rtol"], want["atol"]):
            problems.append(
                f"{label}: the binding reported PASSED, but actual {actual!r} is outside "
                f"the document's band around expected {want['expected']!r} "
                f"(rel {want['rtol']!r}, abs {want['atol']!r}); the binding's §6.6.3 "
                f"predicate disagrees with the spec's"
            )
            continue
        if golden is None:
            checked += 1
            continue
        g = golden_by_key.get(key)
        if g is None:
            problems.append(
                f"{key[0]}#{key[1]}: no golden entry — the golden is stale against the document"
            )
            continue
        try:
            reference = _num(g.get("actual"))
        except (TypeError, ValueError):
            reference = None
        if reference is None or not math.isfinite(reference):
            problems.append(
                f"{label}: the committed golden's `actual` is {g.get('actual')!r}, which is "
                f"not a finite number — the golden is malformed; re-mint it"
            )
            continue
        if not within(actual, reference, rtol, atol):
            problems.append(
                f"{label}: actual {actual!r} is outside the band around the "
                f"{REFERENCE_BINDING} {REFERENCE_COMPILER} golden {reference!r}"
            )
            continue
        checked += 1

    extra = sorted(set(by_key) - set(authored_by_key))
    if extra:
        problems.append(
            f"the adapter reported {len(extra)} assertion(s) the document does not declare: "
            f"{extra[:4]}"
        )

    if problems:
        return {"status": "fail", "problems": problems, "checked": checked}
    record: dict[str, Any] = {"status": "ok", "outcome": "ran", "checked": checked}
    if golden is None:
        record["no_golden"] = fx.get("golden_absent_reason")
    if ex is not None:
        # An exclusion that no longer excludes anything is an IMPROVEMENT, and
        # reporting it as a failure would fail the binding that got better. It
        # is a visible note so the ledger entry gets trimmed by hand.
        record["stale_exclusion"] = (
            f"{binding}/{compiler} is named as excluded ({ex['code']}) but ran this fixture "
            f"cleanly; the ledger entry is stale and should be trimmed"
        )
    return record


# === Adapter harness ======================================================


class InlineTestsHarness(AdapterHarness):
    """``AdapterHarness`` with the two shape differences this contract needs:
    every invocation carries ``--compiler <value>`` (one adapter binary serves
    every compiler its binding offers), and a whole-output ``unavailable``
    payload carries no ``fixtures`` map, which the base class would discard as
    malformed along with the reason the report has to print."""

    def __init__(self, compiler: str) -> None:
        super().__init__("inline-tests", stderr_tail=3000, stderr_on_invalid_json=True)
        self.compiler = compiler

    def run(
        self, binding: str, argv: list[str], manifest_path: Path, timeout: float | None
    ) -> dict:
        with tempfile.NamedTemporaryFile(
            "r", suffix=".json", prefix=f"{self.slug}-{binding}-", delete=False
        ) as tmp:
            out_path = Path(tmp.name)
        try:
            cmd = [
                *argv,
                "--manifest",
                str(manifest_path),
                "--output",
                str(out_path),
                "--compiler",
                self.compiler,
            ]
            try:
                proc = subprocess.run(
                    cmd, capture_output=True, text=True, timeout=timeout, check=False
                )
            except (FileNotFoundError, PermissionError, OSError) as e:
                return self._broken(binding, "missing", str(e))
            except subprocess.TimeoutExpired:
                return self._broken(binding, "timeout", f"adapter timed out after {timeout}s")
            if not out_path.exists() or out_path.stat().st_size == 0:
                return self._broken(
                    binding,
                    "no_output",
                    "adapter wrote no output",
                    exit_code=proc.returncode,
                    stderr=(proc.stderr or "").strip()[-self.stderr_tail :],
                )
            try:
                with out_path.open() as f:
                    payload = json.load(f)
            except json.JSONDecodeError as e:
                return self._broken(
                    binding,
                    "invalid_output",
                    f"adapter output not valid JSON: {e}",
                    stderr=(proc.stderr or "").strip()[-self.stderr_tail :],
                )
            if not isinstance(payload, dict):
                return self._broken(binding, "invalid_output", "adapter output is not an object")
            if payload.get("status") == "unavailable":
                payload.setdefault("binding", binding)
                payload.setdefault("compiler", self.compiler)
                payload.setdefault("fixtures", {})
                payload["adapter_status"] = "unavailable"
                return payload
            if "fixtures" not in payload:
                return self._broken(binding, "invalid_output", "adapter output missing 'fixtures'")
            payload.setdefault("binding", binding)
            payload.setdefault("compiler", self.compiler)
            payload["adapter_status"] = "ok"
            # A non-zero exit WITH a parsable report is read and gated anyway:
            # the per-fixture entries say which fixture broke, and discarding
            # them collapses "one fixture errored" into "the adapter fell over".
            payload["exit_code"] = proc.returncode
            return payload
        finally:
            try:
                out_path.unlink()
            except OSError:
                pass

    def _broken(self, binding: str, status: str, error: str, **extra: Any) -> dict:
        return {
            "binding": binding,
            "compiler": self.compiler,
            "adapter_status": status,
            "error": error,
            "fixtures": {},
            **extra,
        }


# === Producer mode ========================================================


def run_suite(
    manifest_path: Path,
    bindings: list[str],
    output_path: Path,
    timeout: float | None,
    compiler: str,
) -> int:
    manifest = load_manifest(manifest_path)
    fixtures = manifest["fixtures"]
    required = set(manifest["bindings_required"])
    if not bindings:
        bindings = sorted(required)
    for b in bindings:
        if b not in KNOWN_BINDINGS:
            _eprint(f"error: unknown binding {b!r}")
            return 2

    rtol = float(manifest["tolerances"]["golden_rtol"])
    atol = float(manifest["tolerances"]["golden_atol"])

    goldens: dict[str, dict | None] = {}
    authored: dict[str, list[dict]] = {}
    for fx in fixtures:
        if not has_golden(fx):
            goldens[fx["id"]] = None
            authored[fx["id"]] = authored_assertions(manifest_path, fx)
            continue
        gp = golden_path(manifest_path, fx)
        if not gp.is_file():
            _eprint(
                f"error: fixture {fx['id']} has no committed golden at {gp}. Mint it with "
                f"--write-golden --bindings {REFERENCE_BINDING} --compiler {REFERENCE_COMPILER}."
            )
            return 2
        with gp.open() as f:
            goldens[fx["id"]] = json.load(f)
        authored[fx["id"]] = authored_assertions(manifest_path, fx)

    harness = InlineTestsHarness(compiler)
    adapters = harness.collect(bindings, manifest_path, timeout)

    report: dict[str, Any] = {
        "manifest_path": str(manifest_path),
        "category": manifest["category"],
        "compiler": compiler,
        "status": "ok",
        "bindings": {},
        "named_exclusions": [],
    }
    overall_ok = True
    for b in bindings:
        b_report, exclusions = gate_binding(
            b, adapters[b], fixtures, goldens, authored, rtol, atol, compiler, b in required
        )
        report["bindings"][b] = b_report
        report["named_exclusions"].extend(exclusions)
        if b_report["status"] == "fail":
            overall_ok = False

    report["status"] = "ok" if overall_ok else "fail"
    write_report(report, output_path)
    print_report(report)
    return 1 if report["status"] == "fail" else 0


def gate_binding(
    binding: str,
    ar: dict,
    fixtures: list[dict],
    goldens: dict[str, dict | None],
    authored: dict[str, list[dict]],
    rtol: float,
    atol: float,
    compiler: str,
    required: bool,
) -> tuple[dict, list[dict]]:
    """Gate one binding's whole adapter answer: its report entry, and the named
    exclusions it recorded. `required` is whether the manifest lists the binding
    in `bindings_required`."""
    b_report: dict[str, Any] = {
        "adapter_status": ar.get("adapter_status"),
        "error": ar.get("error"),
        "fixtures": {},
    }
    exclusions: list[dict] = []
    if ar.get("adapter_status") == "unavailable":
        b_report["reason"] = ar.get("reason")
        # Availability and refusal are two ledgers. A binding the manifest
        # REQUIRES must be able to ANSWER for the compiler the stage names;
        # "this build has no such compiler" is a coverage gap, not a fact
        # about any document, so it must not read like a refusal.
        b_report["status"] = "fail" if required else "skipped"
        return b_report, exclusions
    if ar.get("adapter_status") != "ok":
        if ar.get("stderr"):
            b_report["stderr"] = ar["stderr"]
        b_report["status"] = "fail" if required else "skipped"
        return b_report, exclusions
    b_ok = True
    for fx in fixtures:
        produced = ar.get("fixtures", {}).get(fx["id"])
        if produced is None:
            b_report["fixtures"][fx["id"]] = {
                "status": "missing",
                "problems": ["the adapter reported nothing for this fixture"],
            }
            b_ok = False
            continue
        fr = compare_fixture(
            fx, produced, goldens[fx["id"]], authored[fx["id"]], rtol, atol, binding, compiler
        )
        b_report["fixtures"][fx["id"]] = fr
        if fr.get("outcome") == "named_exclusion":
            exclusions.append(
                {
                    "binding": binding,
                    "compiler": compiler,
                    "fixture": fx["id"],
                    "code": fr.get("code"),
                    "reason": fr.get("reason"),
                }
            )
        if fr.get("status") != "ok":
            b_ok = False
    b_report["status"] = "ok" if b_ok else "fail"
    return b_report, exclusions


def print_report(report: dict) -> None:
    print("=== Inline-Test Conformance Report ===")
    print(f"category: {report['category']}")
    print(f"manifest: {report['manifest_path']}")
    print(f"compiler: {report['compiler']}")
    print(f"status:   {report['status'].upper()}")
    for b, br in report.get("bindings", {}).items():
        print(f"  {b:>12}  {br.get('status')}  ({br.get('adapter_status')})")
        if br.get("error"):
            print(f"      adapter: {br['error']}")
        if br.get("reason"):
            print(f"      reason: {br['reason']}")
        for fid, fr in br.get("fixtures", {}).items():
            if fr.get("outcome") == "named_exclusion":
                print(f"      NAMED EXCLUSION {fid}: {fr.get('code')} — {fr.get('reason')}")
            elif fr.get("stale_exclusion"):
                print(f"      NOTE {fid}: {fr['stale_exclusion']}")
            if fr.get("status") != "ok":
                for p in fr.get("problems") or [fr.get("status")]:
                    print(f"      FAIL {fid}: {p}")
    if report.get("named_exclusions"):
        print(f"named exclusions: {len(report['named_exclusions'])}")


# === Golden minting =======================================================


def write_golden_mode(args: Any) -> int | None:
    if not args.write_golden:
        return None
    bindings = [b.strip() for b in args.bindings.split(",") if b.strip()]
    if bindings != [REFERENCE_BINDING] or args.compiler != REFERENCE_COMPILER:
        _eprint(
            f"error: goldens are minted from the {REFERENCE_BINDING} {REFERENCE_COMPILER} "
            f"and from nothing else (CONFORMANCE_SPEC §5.45.2). "
            f"Pass --bindings {REFERENCE_BINDING} --compiler {REFERENCE_COMPILER}."
        )
        return 2
    try:
        manifest = load_manifest(args.manifest)
    except ManifestError as e:
        _eprint(f"manifest error: {e}")
        return 2
    harness = InlineTestsHarness(REFERENCE_COMPILER)
    argv = harness.discover(REFERENCE_BINDING)
    if argv is None:
        _eprint(
            f"error: no {REFERENCE_BINDING} adapter registered; set "
            f"$EARTHSCI_INLINE_TESTS_ADAPTER_{REFERENCE_BINDING.upper()}"
        )
        return 2
    payload = harness.run(REFERENCE_BINDING, argv, args.manifest, args.timeout)
    if payload.get("adapter_status") != "ok":
        _eprint(f"error: reference adapter did not run: {payload.get('error')}")
        if payload.get("stderr"):
            _eprint(payload["stderr"])
        return 1
    # Every golden is built and checked BEFORE any is written, so a reference
    # run that is wrong anywhere leaves the committed goldens exactly as they
    # were rather than half-replaced.
    minted: list[tuple[dict, dict]] = []
    problems: list[str] = []
    for fx in manifest["fixtures"]:
        if not has_golden(fx):
            # The manifest already says the reference cannot produce this one,
            # and the self-test checked that a named exclusion backs the claim.
            # Minting is a no-op here, not a failure.
            print(f"skipped {fx['id']}: {fx.get('golden_absent_reason')}")
            continue
        golden, why = mint_golden(fx, payload.get("fixtures", {}).get(fx["id"]))
        if golden is None:
            problems.extend(why)
        else:
            minted.append((fx, golden))
    if problems:
        for p in problems:
            _eprint(f"error: {p}")
        _eprint(
            f"error: refusing to write any golden — {len(problems)} problem(s) above. A "
            f"golden is the number every other compiler is held to, so it is minted only "
            f"from an assertion the reference itself PASSED with a finite value."
        )
        return 1
    for fx, golden in minted:
        gp = golden_path(args.manifest, fx)
        gp.parent.mkdir(parents=True, exist_ok=True)
        with gp.open("w") as f:
            json.dump(golden, f, indent=2)
            f.write("\n")
        print(f"minted {gp}")
    print(f"{len(minted)} golden(s) written from {REFERENCE_BINDING} {REFERENCE_COMPILER}")
    return 0


def mint_golden(fx: dict, entry: Any) -> tuple[dict | None, list[str]]:
    """The golden for one fixture from the reference's adapter entry, or `None`
    and every reason it cannot be minted.

    Only an assertion the reference PASSED, with a FINITE `actual`, is minted: a
    failed one would commit a number the document itself says is wrong, and a
    `null` or a non-finite one is not a value any band can be drawn around."""
    fid = fx["id"]
    if not isinstance(entry, dict) or not isinstance(entry.get("assertions"), list):
        return None, [f"{fid}: the reference produced no assertions: {entry!r}"]
    problems: list[str] = []
    rows: list[dict] = []
    for e in entry["assertions"]:
        if not isinstance(e, dict) or "test_id" not in e or "assertion_idx" not in e:
            problems.append(f"{fid}: malformed assertion entry {e!r}")
            continue
        where = f"{fid} {e['test_id']}#{e['assertion_idx']} ({e.get('variable')})"
        if e.get("passed") is not True:
            problems.append(
                f"{where}: the reference did not pass this assertion "
                f"(passed={e.get('passed')!r}, actual={e.get('actual')!r}: "
                f"{e.get('message', '')})"
            )
            continue
        try:
            actual = _num(e.get("actual"))
        except (TypeError, ValueError):
            actual = None
        if actual is None or not math.isfinite(actual):
            problems.append(f"{where}: `actual` is {e.get('actual')!r}, not a finite number")
            continue
        rows.append(
            {
                "test_id": e["test_id"],
                "assertion_idx": e["assertion_idx"],
                "variable": e.get("variable"),
                "actual": actual,
            }
        )
    if problems:
        return None, problems
    return {
        "fixture": fid,
        "reference_binding": REFERENCE_BINDING,
        "reference_compiler": REFERENCE_COMPILER,
        "assertions": sorted(rows, key=_key),
    }, []


# === Self-test ============================================================


def _stub_entry(authored: list[dict], golden: dict) -> dict:
    by_key = {_key(g): g for g in golden["assertions"]}
    return {
        "assertions": [
            {
                "test_id": a["test_id"],
                "assertion_idx": a["assertion_idx"],
                "variable": a["variable"],
                "passed": True,
                "actual": by_key[_key(a)]["actual"],
                "message": "",
            }
            for a in authored
        ]
    }


def self_test(manifest_path: Path) -> int:
    failures: list[str] = []

    def check(ok: bool, label: str, detail: str = "") -> None:
        if ok:
            print(f"self-test OK   [{label}]")
        else:
            print(f"self-test FAIL [{label}]: {detail}")
            failures.append(f"{label}: {detail}")

    try:
        manifest = load_manifest(manifest_path)
    except ManifestError as e:
        _eprint(f"self-test FAIL [manifest]: {e}")
        return 1
    print(f"self-test: {manifest['category']} ({manifest_path})")

    rtol = float(manifest["tolerances"]["golden_rtol"])
    atol = float(manifest["tolerances"]["golden_atol"])

    for fx in manifest["fixtures"]:
        fid = fx["id"]
        p = fixture_path(manifest_path, fx)
        check(p.is_file(), f"{fid}/document", f"fixture document not found at {p}")
        if not p.is_file():
            continue
        if not has_golden(fx):
            # Nothing to check against a golden that deliberately does not
            # exist; the manifest validator already required a written reason
            # AND a named exclusion for the reference binding.
            try:
                authored_assertions(manifest_path, fx)
            except ManifestError as e:
                check(False, f"{fid}/document-assertions", str(e))
                continue
            print(
                f"self-test OK   [{fid}/no-golden]: the {REFERENCE_BINDING} "
                f"{REFERENCE_COMPILER} refuses this fixture, so the document's own "
                f"expectation is the whole gate — {fx['golden_absent_reason']}"
            )
            continue
        gp = golden_path(manifest_path, fx)
        check(gp.is_file(), f"{fid}/golden", f"golden not found at {gp}")
        if not gp.is_file():
            continue
        try:
            with gp.open() as f:
                golden = json.load(f)
        except (OSError, json.JSONDecodeError) as e:
            check(False, f"{fid}/golden-shape", str(e))
            continue
        check(
            golden.get("reference_binding") == REFERENCE_BINDING
            and golden.get("reference_compiler") == REFERENCE_COMPILER,
            f"{fid}/golden-provenance",
            f"golden was not minted from the {REFERENCE_BINDING} {REFERENCE_COMPILER}",
        )
        try:
            authored = authored_assertions(manifest_path, fx)
        except ManifestError as e:
            check(False, f"{fid}/document-assertions", str(e))
            continue
        gkeys = {_key(g) for g in golden.get("assertions") or []}
        akeys = {_key(a) for a in authored}
        check(
            gkeys == akeys,
            f"{fid}/golden-covers-document",
            f"golden covers {len(gkeys)} assertion(s), the document declares {len(akeys)}: "
            f"missing {sorted(akeys - gkeys)[:4]}, extra {sorted(gkeys - akeys)[:4]}",
        )
        if gkeys != akeys:
            continue

        # THE load-bearing self-test check: the committed golden must reproduce
        # the DOCUMENT's own expectation, at the assertion's resolved §6.6.4
        # band. Without it the golden only agrees with itself, and a reference
        # minted from a broken build would sit there being reproduced by
        # everyone.
        by_key = {_key(g): g for g in golden["assertions"]}
        off = []
        for a in authored:
            raw = by_key[_key(a)].get("actual")
            where = f"{a['test_id']}#{a['assertion_idx']} ({a['variable']})"
            try:
                value = _num(raw)
            except (TypeError, ValueError):
                off.append(f"{where}: golden `actual` {raw!r} is not a number")
                continue
            if not math.isfinite(value):
                off.append(f"{where}: golden `actual` {raw!r} is not finite")
            elif not within(value, a["expected"], a["rtol"], a["atol"]):
                off.append(f"{where}: golden {value!r} vs document expected {a['expected']!r}")
        check(
            not off,
            f"{fid}/golden-matches-authored-expectation",
            f"{len(off)} assertion(s) disagree: {off[:3]}",
        )

    if failures:
        print(f"\nself-test: {len(failures)} FAILURE(S)")
        return 1

    # --- Negative controls: the harness must REJECT each of these -----------
    fx = next((f for f in manifest["fixtures"] if has_golden(f)), None)
    if fx is None:
        print("\nself-test: OK (no fixture carries a golden, so the controls do not apply)")
        return 0
    authored = authored_assertions(manifest_path, fx)
    with golden_path(manifest_path, fx).open() as f:
        golden = json.load(f)
    good = _stub_entry(authored, golden)
    args = (golden, authored, rtol, atol, "julia", "native")

    check(
        compare_fixture(fx, good, *args)["status"] == "ok",
        "control/clean-answer-passes",
        "a clean answer did not pass",
    )

    # The golden band on its own: the DOCUMENT's band is opened wide so that
    # only the golden can reject the moved value.
    moved = copy.deepcopy(good)
    base = _num(moved["assertions"][0]["actual"])
    moved["assertions"][0]["actual"] = (base + 1.0) * 1e3 + 7.0
    wide = [{**a, "atol": math.inf} for a in authored]
    check(
        compare_fixture(fx, moved, golden, wide, rtol, atol, "julia", "native")["status"] == "fail",
        "control/value-off-the-golden-rejected",
        "a value far outside the golden band was accepted",
    )

    dropped = copy.deepcopy(good)
    dropped["assertions"] = dropped["assertions"][1:]
    check(
        compare_fixture(fx, dropped, *args)["status"] == "fail",
        "control/missing-assertion-rejected",
        "a missing assertion was accepted",
    )

    failed_pred = copy.deepcopy(good)
    failed_pred["assertions"][0]["passed"] = False
    failed_pred["assertions"][0]["message"] = "synthetic"
    check(
        compare_fixture(fx, failed_pred, *args)["status"] == "fail",
        "control/failed-predicate-rejected",
        "an assertion the binding itself failed was accepted",
    )

    check(
        compare_fixture(fx, {"error": "synthetic"}, *args)["status"] == "error",
        "control/error-rejected",
        "an adapter error was accepted",
    )

    refusal = {"status": "refused", "code": "synthetic_code", "reason": "synthetic"}
    check(
        compare_fixture(fx, refusal, *args)["status"] == "refused_unnamed",
        "control/unnamed-refusal-rejected",
        "a refusal no ledger entry covers was accepted",
    )

    # An exclusion the ledger DOES carry is a named exclusion: green, reported.
    named = copy.deepcopy(fx)
    named["required"] = {b: [] for b in manifest["bindings_required"]}
    named["named_exclusions"] = [
        {
            "binding": "julia",
            "compilers": ["native"],
            "code": "synthetic_code",
            "reason": "self-test control",
        }
    ]
    r = compare_fixture(named, refusal, *args)
    check(
        r["status"] == "ok" and r.get("outcome") == "named_exclusion",
        "control/named-refusal-is-an-exclusion",
        f"a ledgered refusal was not reported as a named exclusion: {r}",
    )
    wrong = {"status": "refused", "code": "other_code", "reason": "synthetic"}
    check(
        compare_fixture(named, wrong, *args)["status"] == "refused_wrong_code",
        "control/refusal-code-drift-rejected",
        "a refusal whose code moved away from the ledger was accepted",
    )

    _authored_verdict_controls(check, manifest, manifest_path, fx, authored, good, rtol, atol)
    _golden_controls(check, fx, authored, golden, good, rtol, atol)
    _availability_controls(check, manifest, fx, golden, authored, good, rtol, atol)

    if failures:
        print(f"\nself-test: {len(failures)} FAILURE(S)")
        return 1
    print("\nself-test: OK")
    return 0


def _authored_verdict_controls(
    check: Any,
    manifest: dict,
    manifest_path: Path,
    fx: dict,
    authored: list[dict],
    good: dict,
    rtol: float,
    atol: float,
) -> None:
    """The runner's OWN §6.6.3 verdict on the document's `expected`, which it
    must reach whatever the binding's `passed` says. Run with NO golden, the
    shape a fixture the reference refuses has, where this is the whole gate."""
    no_golden = (None, authored, rtol, atol, "python", "native")

    # The predicate itself, on esm-spec §6.6.3's own worked examples.
    cases = [
        ((1.6, 1.0, 0.5, 0.0), True, "the relative scale is max(|a|, |e|), not |e|"),
        ((1e-320, 0.0, 0.5, 0.0), False, "no epsilon floor under the relative bound"),
        ((0.0, 0.0, 0.0, 0.0), True, "an exact band admits the exact value"),
        ((math.nextafter(1.0, 2.0), 1.0, 0.0, 0.0), False, "an exact band is exact"),
        ((-0.0, 0.0, 0.0, 0.0), True, "a signed zero equals zero"),
        ((math.inf, 1.0, 0.5, 1e300), False, "no bound admits an infinity"),
        ((math.inf, math.inf, 0.0, 0.0), True, "the same infinity matches itself"),
        ((math.nan, math.nan, 1.0, 1.0), False, "NaN never passes"),
        ((1.0 + 1e-10, 1.0, 0.0, 1e-9), True, "either bound is sufficient"),
    ]
    for (a, e, rel, ab), want, why in cases:
        check(
            within(a, e, rel, ab) is want,
            f"control/predicate/{why}",
            f"within({a!r}, {e!r}, rel={rel!r}, abs={ab!r}) should be {want}",
        )

    check(
        compare_fixture(fx, good, *no_golden)["status"] == "ok",
        "control/no-golden/clean-answer-passes",
        "a clean answer did not pass on the authored expectation alone",
    )
    lie = copy.deepcopy(good)
    first = authored[0]
    lie["assertions"][0]["actual"] = (abs(first["expected"]) + 1.0) * 1e3 + 7.0
    r = compare_fixture(fx, lie, *no_golden)
    check(
        r["status"] == "fail",
        "control/no-golden/passed-with-wrong-actual-rejected",
        f"a binding that reported PASSED on a value outside the document's band was accepted: {r}",
    )
    for label, patch in (
        ("non-boolean-passed-rejected", {"passed": "true"}),
        ("boolean-actual-rejected", {"actual": True}),
        ("non-finite-actual-rejected", {"actual": "inf"}),
        ("null-actual-rejected", {"actual": None}),
    ):
        bad = copy.deepcopy(good)
        bad["assertions"][0].update(patch)
        check(
            compare_fixture(fx, bad, *no_golden)["status"] == "fail",
            f"control/no-golden/{label}",
            f"{patch} was accepted",
        )
    exact = [{**a, "rtol": 0.0, "atol": 0.0} for a in authored]
    at = copy.deepcopy(good)
    for row, a in zip(at["assertions"], exact):
        row["actual"] = a["expected"]
    nudged = copy.deepcopy(at)
    nudged["assertions"][0]["actual"] = math.nextafter(exact[0]["expected"], math.inf)
    exact_args = (None, exact, rtol, atol, "python", "native")
    check(
        compare_fixture(fx, at, *exact_args)["status"] == "ok"
        and compare_fixture(fx, nudged, *exact_args)["status"] == "fail",
        "control/no-golden/exact-band-is-exact",
        "a `{rel: 0, abs: 0}` band did not admit exactly the expected value and nothing else",
    )

    # The fixtures that really carry no golden: the authored expectation is
    # their whole gate, so the same lie must fail there too.
    for nfx in (f for f in manifest["fixtures"] if not has_golden(f)):
        n_authored = authored_assertions(manifest_path, nfx)
        honest = {
            "assertions": [
                {
                    "test_id": a["test_id"],
                    "assertion_idx": a["assertion_idx"],
                    "variable": a["variable"],
                    "passed": True,
                    "actual": a["expected"],
                    "message": "",
                }
                for a in n_authored
            ]
        }
        n_args = (None, n_authored, rtol, atol, "python", "native")
        dishonest = copy.deepcopy(honest)
        dishonest["assertions"][0]["actual"] = (abs(n_authored[0]["expected"]) + 1.0) * 1e3 + 7.0
        check(
            compare_fixture(nfx, honest, *n_args)["status"] == "ok"
            and compare_fixture(nfx, dishonest, *n_args)["status"] == "fail",
            f"control/{nfx['id']}/no-golden-fixture-holds-to-the-document",
            "the document's own expectation did not gate a fixture that carries no golden",
        )


def _golden_controls(
    check: Any,
    fx: dict,
    authored: list[dict],
    golden: dict,
    good: dict,
    rtol: float,
    atol: float,
) -> None:
    """A malformed committed golden is a gated failure, never a crash; and
    `--write-golden` mints only from an assertion the reference passed with a
    finite value."""
    for label, bad_value in (("null", None), ("string", "abc"), ("non-finite", "nan")):
        broken = copy.deepcopy(golden)
        broken["assertions"][0]["actual"] = bad_value
        try:
            r = compare_fixture(fx, good, broken, authored, rtol, atol, "julia", "native")
            ok = r["status"] == "fail"
            detail = f"a {label} golden `actual` was accepted: {r}"
        except Exception as e:  # noqa: BLE001 - the control is that nothing raises
            ok, detail = False, f"a {label} golden `actual` crashed the gate: {e!r}"
        check(ok, f"control/malformed-golden-{label}-is-a-failure", detail)

    reference = copy.deepcopy(good)
    minted, why = mint_golden(fx, reference)
    check(
        minted is not None
        and {_key(g) for g in minted["assertions"]} == {_key(a) for a in authored},
        "control/mint/clean-reference-mints",
        f"a clean reference answer did not mint a golden covering the document: {why}",
    )
    for label, patch in (
        ("failed", {"passed": False, "message": "synthetic"}),
        ("null", {"actual": None}),
        ("non-finite", {"actual": "inf"}),
        ("non-boolean-passed", {"passed": 1}),
    ):
        bad = copy.deepcopy(good)
        bad["assertions"][0].update(patch)
        first = bad["assertions"][0]
        minted, why = mint_golden(fx, bad)
        named = f"{first['test_id']}#{first['assertion_idx']}"
        check(
            minted is None and any(fx["id"] in w and named in w for w in why),
            f"control/mint/{label}-assertion-refused",
            f"minting from a {label} assertion was not refused by name: {minted!r} {why}",
        )
    minted, why = mint_golden(fx, {"status": "refused", "code": "x", "reason": "y"})
    check(minted is None and why, "control/mint/refusal-refused", "a refusal minted a golden")


def _availability_controls(
    check: Any,
    manifest: dict,
    fx: dict,
    golden: dict,
    authored: list[dict],
    good: dict,
    rtol: float,
    atol: float,
) -> None:
    """`unavailable` is the WHOLE adapter output and is gated by
    `bindings_required`; a per-fixture `compiler_unavailable` is an adapter
    that broke that contract, and must not reach the refusal ledger."""
    fixtures = [fx]
    goldens = {fx["id"]: golden}
    authored_by_id = {fx["id"]: authored}
    whole = {"adapter_status": "unavailable", "reason": "synthetic", "fixtures": {}}
    req, _ = gate_binding(
        "julia", whole, fixtures, goldens, authored_by_id, rtol, atol, "xla", True
    )
    opt, _ = gate_binding(
        "julia", whole, fixtures, goldens, authored_by_id, rtol, atol, "xla", False
    )
    check(
        req["status"] == "fail" and opt["status"] == "skipped",
        "control/unavailable-is-red-only-where-required",
        f"a whole-output `unavailable` gated as {req['status']} (required) / "
        f"{opt['status']} (optional); want fail / skipped",
    )
    per_fixture = {
        "status": "refused",
        "code": UNAVAILABLE_CODE,
        "reason": "synthetic",
    }
    ledgered = copy.deepcopy(fx)
    ledgered["required"] = {b: [] for b in manifest["bindings_required"]}
    ledgered["named_exclusions"] = [
        {"binding": "julia", "compilers": ["xla"], "code": UNAVAILABLE_CODE, "reason": "x"}
    ]
    r_plain = compare_fixture(fx, per_fixture, golden, authored, rtol, atol, "julia", "xla")
    r_ledgered = compare_fixture(
        ledgered, per_fixture, golden, authored, rtol, atol, "julia", "xla"
    )
    check(
        r_plain["status"] == "invalid" and r_ledgered["status"] == "invalid",
        "control/per-fixture-unavailable-is-a-broken-adapter",
        f"a per-fixture {UNAVAILABLE_CODE!r} gated as {r_plain['status']} / "
        f"{r_ledgered['status']} (ledgered); want invalid for both",
    )
    try:
        _validate_ledgers(Path("<self-test>"), fx["id"], ledgered, manifest["bindings_required"])
        rejected = False
    except ManifestError:
        rejected = True
    check(
        rejected,
        "control/unavailable-named-exclusion-is-a-manifest-error",
        f"a named exclusion recording {UNAVAILABLE_CODE!r} was accepted by the manifest",
    )


# === CLI ==================================================================


def parse_args(argv: list[str]) -> Any:
    p = build_parser(
        doc=__doc__,
        default_manifest=DEFAULT_MANIFEST,
        default_output=DEFAULT_OUTPUT,
        manifest_help="The tier manifest (its `runner` must be 'inline_tests').",
        self_test_help=(
            "Validate the manifest and the committed goldens against the documents' own "
            "expectations, and gate the harness's negative controls. Needs no binding."
        ),
    )
    p.add_argument(
        "--compiler",
        default=None,
        help=(
            "Which compiler each adapter builds with (API_SPEC §5.8). REQUIRED for a "
            "producer run and for --write-golden: a stage that names no compiler measures "
            "whatever the library default happens to be."
        ),
    )
    p.add_argument(
        "--write-golden",
        action="store_true",
        help=(
            f"Mint golden/<id>.json from the {REFERENCE_BINDING} {REFERENCE_COMPILER}. "
            f"Refused from any other binding or compiler."
        ),
    )
    return p.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv if argv is not None else sys.argv[1:])
    if not args.manifest.is_file():
        _eprint(f"error: manifest not found: {args.manifest}")
        return 2
    if args.self_test:
        return self_test(args.manifest)
    if args.compiler is None:
        _eprint(
            "error: --compiler is required. Every problem-building stage NAMES its "
            "compiler (CONFORMANCE_SPEC §5.44.5); inheriting the library default would "
            "make this stage's goldens say what they measured before."
        )
        return 2
    if args.compiler not in COMPILERS:
        _eprint(
            f"error: --compiler {args.compiler!r} is outside API_SPEC §5.8's vocabulary "
            f"{COMPILERS}. A typo is not a missing runtime."
        )
        return 2
    rc = write_golden_mode(args)
    if rc is not None:
        return rc
    bindings = [b.strip() for b in args.bindings.split(",") if b.strip()]
    try:
        return run_suite(args.manifest, bindings, args.output, args.timeout, args.compiler)
    except ManifestError as e:
        _eprint(f"manifest error: {e}")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
