"""The `compiler_agreement` runner's own test, driven by the stub adapter.

`scripts/run-compiler-agreement-conformance.py` is the only thing that decides
whether a compiler agreed, refused, was unavailable or errored, and whether each
of those is red or green. The adapters that feed it need a live Julia, Rust or
Python runtime; this drives the runner through all five outcomes and BOTH ledgers
against `stub_adapter.py` instead, in pure Python, with no binding imported.

What each ledger is for, since conflating them is the failure this file exists to
prevent: `compilers.<value>.bindings_required` governs AVAILABILITY (must this
binding be able to ANSWER for this compiler), and a fixture's `required` map
governs REFUSALS (must this compiler run THIS document). A compiler can be
required to exist and still be allowed to refuse a particular fixture.

Every run works on a COPY of the committed manifest, materialized under the test's
own temporary directory with its own `golden/`. Nothing here writes to
`tests/conformance/compiler_agreement/golden/`, which holds the reference
trajectories and is minted only by `--write-golden` against the real Julia
adapter.
"""

from __future__ import annotations

import copy
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parents[2]
RUNNER = REPO_ROOT / "scripts" / "run-compiler-agreement-conformance.py"
ASSERT_AVAILABLE = REPO_ROOT / "scripts" / "assert-compiler-agreement-available.py"
STUB = HERE / "stub_adapter.py"
COMMITTED_MANIFEST = HERE / "manifest.json"

# The corpus directories a fixture `path` can name. The copied manifest lives in a
# sibling of these under the test's own `tests/` root, so the runner's "walk up to
# the nearest ancestor named tests" rule resolves every fixture through them.
CORPUS_DIRS = ("conformance", "fixtures", "valid")


# === Harness ==============================================================


def materialize(tmp_path: Path, patch=None) -> Path:
    """A copy of the committed manifest under `tmp_path/tests/`, optionally patched.

    The corpus itself is symlinked rather than copied: the fixtures are referenced
    by path and never modified, and the point of the copy is only to give the run
    a `golden/` of its own and let a test rewrite the ledgers."""
    root = tmp_path / "tests"
    root.mkdir(parents=True, exist_ok=True)
    for name in CORPUS_DIRS:
        link = root / name
        if not link.exists():
            link.symlink_to(REPO_ROOT / "tests" / name, target_is_directory=True)
    manifest = json.loads(COMMITTED_MANIFEST.read_text())
    if patch is not None:
        patch(manifest)
    out_dir = root / "compiler_agreement_stub"
    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / "manifest.json"
    path.write_text(json.dumps(manifest, indent=2) + "\n")
    return path


def drop_anchors(manifest: dict) -> None:
    """Detach every fixture from its analytic anchor.

    The stub's trajectory is a canned exponential, not the fixture's physics, so
    an anchor would reject it — correctly. Tests that need an `ok` verdict drop the
    anchors and gate the stub against a golden minted from the stub itself;
    `test_anchor_rejects_wrong_physics` is where the anchor gate is exercised."""
    for fx in manifest["fixtures"]:
        fx["anchor"] = {"source": "none"}


def unrequired(manifest: dict) -> None:
    """Empty every fixture's `required` map — the REFUSAL ledger.

    A test about an UNREQUIRED refusal must construct that state rather than
    borrow the committed ledger's: fixtures gain `required` names one at a time
    as coverage lands (a one-way ratchet), and a test that read the committed
    maps would quietly stop testing the unrequired arm the day one was filled."""
    for fx in manifest["fixtures"]:
        fx["required"] = {b: [] for b in fx.get("required", {})}


def _drop_anchors_unrequired(manifest: dict) -> None:
    drop_anchors(manifest)
    unrequired(manifest)


def _drop_anchors_native_optional(manifest: dict) -> None:
    """`drop_anchors` + `native_optional`, the pair every test of the optional
    availability arm needs: a canned trajectory the anchors would reject, gated
    against a stub-minted golden, under a ledger that makes `native` optional."""
    drop_anchors(manifest)
    native_optional(manifest)


def native_optional(manifest: dict) -> None:
    """Put `native` on the OPTIONAL arm of the availability ledger for every binding.

    A test about the optional arm must CONSTRUCT that arm rather than borrow
    whichever arm the committed ledger happens to be on: `native` crosses to
    `bindings_required` one binding at a time as each strict build lands, and a
    test that read the committed ledger would quietly change what it asserts on
    the day a binding crossed. Every fixture's `required` map is emptied with
    it: a fixture may not require a compiler its binding need not offer."""
    unrequired(manifest)
    manifest["compilers"]["native"] = {
        **manifest["compilers"]["native"],
        "bindings_required": [],
        "bindings_optional": ["julia", "rust", "python"],
    }


def run_runner(
    manifest: Path,
    *args: str,
    scenario: str | None = None,
    adapter: bool = True,
    runner: Path | None = None,
):
    """Invoke the runner with the stub registered as the `julia` adapter."""
    env = dict(os.environ)
    if adapter:
        cmd = f"{sys.executable} {STUB}"
        if scenario:
            cmd += f" --scenario {scenario}"
        env["EARTHSCI_COMPILER_AGREEMENT_ADAPTER_JULIA"] = cmd
    else:
        env.pop("EARTHSCI_COMPILER_AGREEMENT_ADAPTER_JULIA", None)
    proc = subprocess.run(
        [sys.executable, str(runner or RUNNER), "--manifest", str(manifest), *args],
        capture_output=True,
        text=True,
        env=env,
        cwd=str(REPO_ROOT),
    )
    return proc


def runner_under(tmp_path: Path) -> Path:
    """A copy of the runner whose REPO_ROOT is `tmp_path`.

    The runner derives its repository root from its own location and offers each
    binding's PLANNED adapter when that file is on disk there. That fallback is
    what makes a stage work the moment its adapter lands — and it is also why a
    test of "no adapter registered ANYWHERE" cannot simply unset the environment
    variable once a real adapter has been committed. Copying the runner beside an
    empty root gives the test a tree with no planned adapter in it, whatever the
    real repository has grown, so the case stays tested instead of quietly
    becoming untestable."""
    scripts = tmp_path / "scripts"
    scripts.mkdir(parents=True, exist_ok=True)
    for name in (RUNNER.name, "conformance_lib.py"):
        shutil.copy2(REPO_ROOT / "scripts" / name, scripts / name)
    return scripts / RUNNER.name


def mint_golden(manifest: Path) -> None:
    proc = run_runner(
        manifest, "--write-golden", "--bindings", "julia", "--compiler", "interpreter"
    )
    assert proc.returncode == 0, proc.stderr
    assert (manifest.parent / "golden").is_dir()


def produce(manifest: Path, compiler: str, tmp_path: Path, scenario: str | None = None):
    """Mint a golden from the stub's all-ok interpreter, then run one compiler."""
    report = tmp_path / "report.json"
    proc = run_runner(
        manifest,
        "--bindings",
        "julia",
        "--compiler",
        compiler,
        "--output",
        str(report),
        scenario=scenario,
    )
    payload = json.loads(report.read_text()) if report.is_file() else None
    return proc, payload


def statuses(payload: dict, compiler: str) -> dict:
    fixtures = payload["compilers"][compiler]["bindings"]["julia"]["fixtures"]
    return {fid: fr["status"] for fid, fr in fixtures.items()}


# === The always-on guard ==================================================


def test_self_test_passes_on_the_committed_manifest():
    """The committed tier, exactly as it stands: every reference trajectory in
    `golden/` is checked for shape AND against the analytic anchor its fixture
    carries, and the whole self-test exits 0."""
    proc = subprocess.run(
        [sys.executable, str(RUNNER), "--self-test"],
        capture_output=True,
        text=True,
        cwd=str(REPO_ROOT),
    )
    assert proc.returncode == 0, proc.stdout + proc.stderr
    committed = json.loads(COMMITTED_MANIFEST.read_text())["fixtures"]
    for fx in committed:
        assert f"[golden/{fx['id']}]" in proc.stdout
    assert "self-test: OK" in proc.stdout


def test_self_test_reports_a_golden_whose_shape_is_wrong(tmp_path):
    """Once ONE golden exists the tier is past phase 1, so a malformed golden and a
    missing one both have to be caught."""
    manifest = materialize(tmp_path, drop_anchors)
    mint_golden(manifest)
    first = sorted((manifest.parent / "golden").glob("*.json"))[0]
    broken = json.loads(first.read_text())
    broken["compiler"] = "native"
    first.write_text(json.dumps(broken))
    proc = run_runner(manifest, "--self-test")
    assert proc.returncode == 1
    assert "golden.compiler is 'native'" in proc.stderr


def test_self_test_flags_a_missing_golden_once_others_exist(tmp_path):
    manifest = materialize(tmp_path, drop_anchors)
    mint_golden(manifest)
    sorted((manifest.parent / "golden").glob("*.json"))[0].unlink()
    proc = run_runner(manifest, "--self-test")
    assert proc.returncode == 1
    assert "golden missing" in proc.stderr


# === --write-golden mints from the reference and nothing else =============


@pytest.mark.parametrize(
    "args",
    [
        ("--bindings", "rust", "--compiler", "interpreter"),
        ("--bindings", "julia", "--compiler", "native"),
    ],
)
def test_write_golden_refuses_a_non_reference_source(tmp_path, args):
    """The golden IS the Julia `interpreter` trajectory. Minting it from anything
    else would make the tier compare a compiled path against itself."""
    manifest = materialize(tmp_path, drop_anchors)
    proc = run_runner(manifest, "--write-golden", *args)
    assert proc.returncode == 2
    assert "refusing to mint" in proc.stderr


def test_write_golden_writes_one_file_per_fixture(tmp_path):
    manifest = materialize(tmp_path, drop_anchors)
    mint_golden(manifest)
    ids = {fx["id"] for fx in json.loads(manifest.read_text())["fixtures"]}
    written = {p.stem for p in (manifest.parent / "golden").glob("*.json")}
    assert written == ids
    one = json.loads((manifest.parent / "golden" / f"{sorted(ids)[0]}.json").read_text())
    assert one["binding"] == "julia"
    assert one["compiler"] == "interpreter"
    assert one["state_order"] and one["saveat"] and one["state"]


# === Outcome 1: ok ========================================================


def test_matching_trajectory_is_green(tmp_path):
    manifest = materialize(tmp_path, drop_anchors)
    mint_golden(manifest)
    proc, payload = produce(manifest, "interpreter", tmp_path)
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert payload["status"] == "ok"
    assert set(statuses(payload, "interpreter").values()) == {"ok"}


# === Outcome 2: mismatch ==================================================


def test_mismatch_is_red_for_every_compiler(tmp_path):
    manifest = materialize(tmp_path, drop_anchors)
    mint_golden(manifest)
    proc, payload = produce(manifest, "native", tmp_path, scenario="all_mismatch")
    assert proc.returncode == 1
    assert payload["status"] == "fail"
    assert set(statuses(payload, "native").values()) == {"mismatch"}
    problems = payload["compilers"]["native"]["bindings"]["julia"]["fixtures"]
    assert any("vs-golden" in p for fr in problems.values() for p in fr["problems"])


def test_anchor_rejects_wrong_physics(tmp_path):
    """With the anchors left in place the stub's canned trajectory is gated against
    the analytic solution the fixture carries from the tier it came from — and
    fails, which is the anchor doing its job. An anchor is what keeps the golden
    itself honest."""
    manifest = materialize(tmp_path)
    mint_golden(manifest)
    proc, payload = produce(manifest, "interpreter", tmp_path)
    assert proc.returncode == 1
    problems = payload["compilers"]["interpreter"]["bindings"]["julia"]["fixtures"]
    assert any("vs-anchor" in p for fr in problems.values() for p in fr["problems"])


# === Outcome 3: refused, and the REFUSAL ledger ===========================


def test_unrequired_refusal_is_a_named_exclusion_and_green(tmp_path):
    manifest = materialize(tmp_path, _drop_anchors_unrequired)
    mint_golden(manifest)
    proc, payload = produce(manifest, "native", tmp_path, scenario="all_refused")
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert payload["status"] == "ok"
    assert set(statuses(payload, "native").values()) == {"excluded"}
    assert payload["refusals"], "a refusal must never be a silent skip"
    for r in payload["refusals"]:
        assert r["verdict"] == "named exclusion"
        assert r["rule"] and r["reason"]
        # Every exclusion is named ON THE CONSOLE, not only in the report.
        assert r["fixture"] in proc.stdout
        assert r["rule"] in proc.stdout


def test_interpreter_refusal_is_always_red(tmp_path):
    """The interpreter is complete over the evaluable core, so a refusal there is a
    defect rather than coverage — whatever the fixture's `required` map says."""
    manifest = materialize(tmp_path, drop_anchors)
    mint_golden(manifest)
    proc, payload = produce(manifest, "interpreter", tmp_path, scenario="all_refused")
    assert proc.returncode == 1
    assert set(statuses(payload, "interpreter").values()) == {"refused"}
    assert all(r["verdict"] == "fail" for r in payload["refusals"])


def test_required_refusal_is_red_and_the_rest_stay_exclusions(tmp_path):
    """The ratchet: a fixture that names a binding+compiler in `required` turns that
    compiler's refusal red, and leaves every other fixture's refusal a named
    exclusion."""

    def patch(manifest):
        _drop_anchors_unrequired(manifest)
        manifest["compilers"]["native"]["bindings_required"] = ["julia"]
        manifest["compilers"]["native"]["bindings_optional"] = ["rust", "python"]
        manifest["fixtures"][0]["required"]["julia"] = ["native"]

    manifest = materialize(tmp_path, patch)
    mint_golden(manifest)
    proc, payload = produce(manifest, "native", tmp_path, scenario="all_refused")
    assert proc.returncode == 1
    seen = statuses(payload, "native")
    ratcheted = json.loads(manifest.read_text())["fixtures"][0]["id"]
    assert seen.pop(ratcheted) == "refused"
    assert set(seen.values()) == {"excluded"}


def test_a_fixture_cannot_require_a_compiler_the_ledger_does_not(tmp_path):
    """The two ledgers must not contradict each other: requiring a compiler to RUN a
    document while the availability ledger lets the binding not offer it at all is
    a manifest error, not a gate."""

    def patch(manifest):
        drop_anchors(manifest)
        native_optional(manifest)
        manifest["fixtures"][0]["required"]["julia"] = ["native"]

    manifest = materialize(tmp_path, patch)
    proc = run_runner(manifest, "--self-test")
    assert proc.returncode == 1
    assert "must not contradict each other" in proc.stderr


# === Outcome 4: unavailable, and the AVAILABILITY ledger ==================


def test_unavailable_optional_compiler_is_green_and_named(tmp_path):
    manifest = materialize(tmp_path, _drop_anchors_native_optional)
    mint_golden(manifest)
    proc, payload = produce(manifest, "native", tmp_path, scenario="unavailable")
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert payload["compilers"]["native"]["bindings"]["julia"]["status"] == "unavailable"
    assert payload["unavailable"][0]["binding"] == "julia"
    assert payload["unavailable"][0]["reason"]
    assert "not available" in proc.stdout


def test_unavailable_required_compiler_is_red(tmp_path):
    """julia is `bindings_required` for the interpreter, so an unavailable one there
    is a missing runtime the tier will not tolerate."""
    manifest = materialize(tmp_path, drop_anchors)
    mint_golden(manifest)
    proc, payload = produce(manifest, "interpreter", tmp_path, scenario="unavailable")
    assert proc.returncode == 1
    assert payload["compilers"]["interpreter"]["bindings"]["julia"]["status"] == "fail"


def test_a_missing_adapter_is_unavailable_not_a_crash(tmp_path):
    """No adapter registered and none on disk: the same FACT as an adapter saying
    the compiler is not configured here, so it is governed by the availability
    ledger — green for an optional binding, with the reason printed."""
    manifest = materialize(tmp_path, _drop_anchors_native_optional)
    mint_golden(manifest)
    report = tmp_path / "missing.json"
    proc = run_runner(
        manifest,
        "--bindings",
        "julia",
        "--compiler",
        "native",
        "--output",
        str(report),
        adapter=False,
        runner=runner_under(tmp_path),
    )
    assert proc.returncode == 0, proc.stdout + proc.stderr
    payload = json.loads(report.read_text())
    assert payload["compilers"]["native"]["bindings"]["julia"]["status"] == "unavailable"
    assert "adapter not found" in payload["unavailable"][0]["reason"]


# === Outcome 5: error =====================================================


def test_error_is_red_whether_or_not_the_fixture_requires_the_compiler(tmp_path):
    """An error says nothing about what a compiler can run, so `required` does not
    excuse it the way it excuses a refusal. The stub also exits non-zero here, and
    the runner must still READ the report — the per-fixture entries are what say
    which fixture broke."""
    manifest = materialize(tmp_path, drop_anchors)
    mint_golden(manifest)
    proc, payload = produce(manifest, "native", tmp_path, scenario="all_error")
    assert proc.returncode == 1
    assert set(statuses(payload, "native").values()) == {"error"}
    assert payload["compilers"]["native"]["bindings"]["julia"]["exit_code"] == 1


def test_the_mixed_table_separates_all_four_adapter_outcomes(tmp_path):
    """One run, four different verdicts: the runner must not collapse them."""
    manifest = materialize(tmp_path, _drop_anchors_unrequired)
    mint_golden(manifest)
    proc, payload = produce(manifest, "native", tmp_path, scenario="mixed")
    assert proc.returncode == 1
    # The `mixed` table is positional, so read the verdicts back through the
    # manifest's own fixture order — the report is written with sorted keys.
    ids = [fx["id"] for fx in json.loads(manifest.read_text())["fixtures"]]
    seen = statuses(payload, "native")
    assert [seen[i] for i in ids[:4]] == ["ok", "mismatch", "excluded", "error"]


# === Configuration errors (exit 2) ========================================


def test_a_producer_run_without_goldens_is_a_config_error(tmp_path):
    manifest = materialize(tmp_path, drop_anchors)
    proc, _ = produce(manifest, "interpreter", tmp_path)
    assert proc.returncode == 2
    assert "golden(s) missing" in proc.stderr


def test_an_out_of_scope_binding_is_a_config_error(tmp_path):
    manifest = materialize(tmp_path, drop_anchors)
    mint_golden(manifest)
    proc = run_runner(manifest, "--bindings", "go", "--compiler", "interpreter")
    assert proc.returncode == 2
    assert "out of scope" in proc.stderr


def test_an_unknown_compiler_is_a_config_error(tmp_path):
    manifest = materialize(tmp_path, drop_anchors)
    mint_golden(manifest)
    proc = run_runner(manifest, "--bindings", "julia", "--compiler", "llvm")
    assert proc.returncode == 2
    assert "not in the manifest" in proc.stderr


def test_a_missing_manifest_is_a_config_error(tmp_path):
    proc = subprocess.run(
        [sys.executable, str(RUNNER), "--manifest", str(tmp_path / "nope.json"), "--self-test"],
        capture_output=True,
        text=True,
        cwd=str(REPO_ROOT),
    )
    assert proc.returncode == 2
    assert "manifest not found" in proc.stderr


# === Results-dir layout and the availability assertion ====================


def test_results_dir_places_the_report(tmp_path):
    manifest = materialize(tmp_path, drop_anchors)
    mint_golden(manifest)
    out = tmp_path / "results"
    proc = run_runner(
        manifest, "--bindings", "julia", "--compiler", "interpreter", "--results-dir", str(out)
    )
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert (out / "report.json").is_file()


def _assert_available(report: Path, binding: str, compiler: str):
    return subprocess.run(
        [sys.executable, str(ASSERT_AVAILABLE), str(report), binding, compiler],
        capture_output=True,
        text=True,
    )


def test_assert_available_passes_only_when_the_compiler_ran(tmp_path):
    manifest = materialize(tmp_path, drop_anchors)
    mint_golden(manifest)
    report = tmp_path / "ran.json"
    proc = run_runner(
        manifest,
        "--bindings",
        "julia",
        "--compiler",
        "native",
        "--output",
        str(report),
        scenario="all_ok",
    )
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert _assert_available(report, "julia", "native").returncode == 0


def test_assert_available_fails_on_a_skip(tmp_path):
    """The runner exits 0 on a legal skip, which is exactly the hole this script
    fills for a workflow whose point is that the compiler ran."""
    manifest = materialize(tmp_path, _drop_anchors_native_optional)
    mint_golden(manifest)
    report = tmp_path / "skipped.json"
    proc = run_runner(
        manifest,
        "--bindings",
        "julia",
        "--compiler",
        "native",
        "--output",
        str(report),
        scenario="unavailable",
    )
    assert proc.returncode == 0
    assert _assert_available(report, "julia", "native").returncode == 1


def test_assert_available_rejects_a_report_about_another_compiler(tmp_path):
    manifest = materialize(tmp_path, drop_anchors)
    mint_golden(manifest)
    report = tmp_path / "other.json"
    run_runner(
        manifest,
        "--bindings",
        "julia",
        "--compiler",
        "native",
        "--output",
        str(report),
        scenario="all_ok",
    )
    assert _assert_available(report, "julia", "xla").returncode == 2


def test_assert_available_needs_a_report(tmp_path):
    assert _assert_available(tmp_path / "absent.json", "julia", "native").returncode == 2


# === The stub's own contract ==============================================


def test_the_stub_answers_for_every_manifest_fixture(tmp_path):
    """The stub is the only producer this file has; a table that silently stopped
    covering the tier's fixtures would turn every test above into a no-op."""
    out = tmp_path / "stub.json"
    rc = subprocess.run(
        [
            sys.executable,
            str(STUB),
            "--manifest",
            str(COMMITTED_MANIFEST),
            "--output",
            str(out),
            "--compiler",
            "native",
            "--scenario",
            "mixed",
        ],
        capture_output=True,
        text=True,
    )
    assert rc.returncode == 1, "the mixed table errors one fixture, so the stub exits non-zero"
    payload = json.loads(out.read_text())
    ids = [fx["id"] for fx in json.loads(COMMITTED_MANIFEST.read_text())["fixtures"]]
    assert set(payload["fixtures"]) == set(ids)
    assert len(ids) == 6


def test_the_stub_is_reproducible():
    """`ok` in the tests above is a real comparison only if the stub returns the
    same numbers a second time."""
    first = copy.deepcopy(_stub_payload("interpreter"))
    assert first == _stub_payload("interpreter")


def _stub_payload(compiler: str) -> dict:
    import tempfile

    with tempfile.TemporaryDirectory() as d:
        out = Path(d) / "out.json"
        subprocess.run(
            [
                sys.executable,
                str(STUB),
                "--manifest",
                str(COMMITTED_MANIFEST),
                "--output",
                str(out),
                "--compiler",
                compiler,
            ],
            check=True,
            capture_output=True,
        )
        return json.loads(out.read_text())
