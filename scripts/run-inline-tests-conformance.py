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
            f"{path}: reference_binding must be {REFERENCE_BINDING!r} "
            f"(CONFORMANCE_SPEC §5.45.2)"
        )
    if manifest.get("reference_compiler") != REFERENCE_COMPILER:
        raise ManifestError(
            f"{path}: reference_compiler must be {REFERENCE_COMPILER!r} "
            f"(CONFORMANCE_SPEC §5.45.2)"
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
        raise ManifestError(
            f"{path}: fixtures[{fid}].golden must be a non-empty string or null"
        )
    if not isinstance(fx.get("golden_absent_reason"), str) or not fx["golden_absent_reason"]:
        raise ManifestError(
            f"{path}: fixtures[{fid}] has no golden and no golden_absent_reason. "
            f"A missing reference is a statement, and it has to be written down."
        )
    if not any(
        ex.get("binding") == REFERENCE_BINDING for ex in (fx.get("named_exclusions") or [])
    ):
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
    instead of arriving as a silent `null`."""
    if isinstance(v, str):
        return float(v)
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
            out.append(
                {
                    "test_id": str(test.get("id")),
                    "assertion_idx": i,
                    "variable": str(a.get("variable")),
                    "expected": _num(a.get("expected")),
                    "rtol": float(
                        a_tol.get(
                            "rel", test_tol.get("rel", model_tol.get("rel", DEFAULT_ASSERTION_REL))
                        )
                    ),
                    "atol": float(
                        a_tol.get(
                            "abs", test_tol.get("abs", model_tol.get("abs", DEFAULT_ASSERTION_ABS))
                        )
                    ),
                }
            )
    if not out:
        raise ManifestError(
            f"fixture {fx['id']}: model {fx['model']!r} in {path} declares no inline "
            f"assertions, so there is nothing for this tier to gate"
        )
    return out


def _key(entry: dict) -> tuple[str, int]:
    return (str(entry["test_id"]), int(entry["assertion_idx"]))


def within(got: float, want: float, rtol: float, atol: float) -> bool:
    """The §6.6.3 band: either bound passing counts as a pass, and a NaN on
    either side never does."""
    if math.isnan(got) or math.isnan(want):
        return False
    if math.isinf(got) or math.isinf(want):
        return got == want
    diff = abs(got - want)
    return diff <= atol or diff <= rtol * max(abs(want), abs(got))


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

    golden_by_key = {_key(g): g for g in (golden or {}).get("assertions") or []}
    authored_by_key = {_key(a): a for a in authored}

    checked = 0
    for key, want in authored_by_key.items():
        got = by_key.get(key)
        if got is None:
            problems.append(f"{key[0]}#{key[1]}: the adapter reported no result")
            continue
        if not got.get("passed"):
            problems.append(
                f"{key[0]}#{key[1]} ({want['variable']}): the binding's own §6.6.3 predicate "
                f"FAILED — actual {got.get('actual')!r} vs the document's expected "
                f"{want['expected']!r}: {got.get('message', '')}"
            )
            continue
        raw = got.get("actual")
        if raw is None:
            problems.append(f"{key[0]}#{key[1]}: passed with no `actual` recorded")
            continue
        try:
            actual = _num(raw)
        except (TypeError, ValueError):
            problems.append(f"{key[0]}#{key[1]}: `actual` {raw!r} is not a number")
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
        if not within(actual, _num(g["actual"]), rtol, atol):
            problems.append(
                f"{key[0]}#{key[1]} ({want['variable']}): actual {actual!r} is outside the "
                f"band around the {REFERENCE_BINDING} {REFERENCE_COMPILER} golden "
                f"{_num(g['actual'])!r}"
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
                return self._broken(
                    binding, "invalid_output", "adapter output missing 'fixtures'"
                )
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
        ar = adapters[b]
        b_report: dict[str, Any] = {
            "adapter_status": ar.get("adapter_status"),
            "error": ar.get("error"),
            "fixtures": {},
        }
        if ar.get("adapter_status") == "unavailable":
            b_report["reason"] = ar.get("reason")
            # Availability and refusal are two ledgers. A binding the manifest
            # REQUIRES must be able to ANSWER for the compiler the stage names;
            # "this build has no such compiler" is a coverage gap, not a fact
            # about any document, so it must not read like a refusal.
            b_report["status"] = "fail" if b in required else "skipped"
            if b in required:
                overall_ok = False
            report["bindings"][b] = b_report
            continue
        if ar.get("adapter_status") != "ok":
            if ar.get("stderr"):
                b_report["stderr"] = ar["stderr"]
            b_report["status"] = "fail" if b in required else "skipped"
            if b in required:
                overall_ok = False
            report["bindings"][b] = b_report
            continue
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
                fx, produced, goldens[fx["id"]], authored[fx["id"]], rtol, atol, b, compiler
            )
            b_report["fixtures"][fx["id"]] = fr
            if fr.get("outcome") == "named_exclusion":
                report["named_exclusions"].append(
                    {
                        "binding": b,
                        "compiler": compiler,
                        "fixture": fx["id"],
                        "code": fr.get("code"),
                        "reason": fr.get("reason"),
                    }
                )
            if fr.get("status") != "ok":
                b_ok = False
        b_report["status"] = "ok" if b_ok else "fail"
        if not b_ok:
            overall_ok = False
        report["bindings"][b] = b_report

    report["status"] = "ok" if overall_ok else "fail"
    write_report(report, output_path)
    print_report(report)
    return 1 if report["status"] == "fail" else 0


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
    written = 0
    for fx in manifest["fixtures"]:
        entry = payload.get("fixtures", {}).get(fx["id"])
        if not has_golden(fx):
            # The manifest already says the reference cannot produce this one,
            # and the self-test checked that a named exclusion backs the claim.
            # Minting is a no-op here, not a failure.
            print(f"skipped {fx['id']}: {fx.get('golden_absent_reason')}")
            continue
        if not isinstance(entry, dict) or "assertions" not in entry:
            _eprint(f"error: reference produced no assertions for {fx['id']}: {entry!r}")
            return 1
        golden = {
            "fixture": fx["id"],
            "reference_binding": REFERENCE_BINDING,
            "reference_compiler": REFERENCE_COMPILER,
            "assertions": [
                {
                    "test_id": e["test_id"],
                    "assertion_idx": e["assertion_idx"],
                    "variable": e.get("variable"),
                    "actual": e["actual"],
                }
                for e in sorted(entry["assertions"], key=_key)
            ],
        }
        gp = golden_path(args.manifest, fx)
        gp.parent.mkdir(parents=True, exist_ok=True)
        with gp.open("w") as f:
            json.dump(golden, f, indent=2)
            f.write("\n")
        written += 1
        print(f"minted {gp}")
    print(f"{written} golden(s) written from {REFERENCE_BINDING} {REFERENCE_COMPILER}")
    return 0


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
        off = [
            f"{a['test_id']}#{a['assertion_idx']} ({a['variable']}): golden "
            f"{_num(by_key[_key(a)]['actual'])!r} vs document expected {a['expected']!r}"
            for a in authored
            if not within(_num(by_key[_key(a)]["actual"]), a["expected"], a["rtol"], a["atol"])
        ]
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

    moved = copy.deepcopy(good)
    base = _num(moved["assertions"][0]["actual"])
    moved["assertions"][0]["actual"] = (base + 1.0) * 1e3 + 7.0
    check(
        compare_fixture(fx, moved, *args)["status"] == "fail",
        "control/value-off-the-golden-rejected",
        "a value far outside the band was accepted",
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

    if failures:
        print(f"\nself-test: {len(failures)} FAILURE(S)")
        return 1
    print("\nself-test: OK")
    return 0


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
