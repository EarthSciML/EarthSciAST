"""Shared harness for the manifest-based cross-binding conformance runners.

``run-cadence-conformance.py``, ``run-determinism-conformance.py``,
``run-geometry-conformance.py``, and ``run-pde-simulation-conformance.py`` share
the same two-phase skeleton: a ``--self-test`` mode that asserts the suite's
contract against an embedded reference implementation + static golden, and a
producer mode that dispatches per-binding adapter subprocesses over the same
manifest and gates their output. This module holds the shared harness,
parameterized by the bits that differ per suite:

  * manifest loading / shape validation (:func:`load_manifest` — category
    string(s), required per-fixture fields, optional suite-specific fixture
    validation hook),
  * adapter discovery + invocation (:class:`AdapterHarness` — the
    ``$EARTHSCI_<SUITE>_ADAPTER_<BINDING>`` env override, the
    ``earthsci-<suite>-adapter-<binding>`` PATH fallback, the tempfile handoff,
    timeout, and malformed-output classification),
  * the CLI (:func:`build_parser` — the common ``--manifest`` / ``--output`` /
    ``--bindings`` / ``--timeout`` / ``--self-test`` flags) and the ``main()``
    dispatch skeleton (:func:`cli_main`),
  * the aggregated report writer (:func:`write_report`) and the per-binding
    summary printer (:func:`print_summary`).

Suite-specific logic — the embedded reference implementations, the
comparison / tolerance logic, ``self_test``, and ``run_suite`` orchestration —
stays in each runner. The runner filenames are hyphenated (not importable as
module names), so they load this module by putting ``scripts/`` on ``sys.path``
first:

    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from conformance_lib import ...

Exit-code convention shared by all four runners (each runner's docstring
restates it with suite-specific wording):

    0  self-test passed, or every required binding matched the golden/contract
    1  a contract violation / mismatch (or self-test failed)
    2  manifest / config error (no run attempted)
"""

from __future__ import annotations

import argparse
import json
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Callable

REPO_ROOT = Path(__file__).resolve().parent.parent

KNOWN_BINDINGS = ("julia", "rust", "python", "typescript", "go")


def _eprint(*args: Any) -> None:
    print(*args, file=sys.stderr)


# === Manifest loading =====================================================


class ManifestError(Exception):
    pass


def load_manifest(
    path: Path,
    *,
    categories: tuple[str, ...],
    fixture_fields: tuple[str, ...],
    check_version: bool = True,
    validate_fixture: Callable[[dict, str, Path], None] | None = None,
) -> dict:
    """Load and shape-validate a conformance manifest.

    Every manifest must be a JSON object with the suite's ``category``, a
    non-empty ``fixtures`` array of objects carrying unique non-empty string
    ``id``\\ s and the suite's required ``fixture_fields``. ``check_version``
    additionally requires a string ``version``. ``validate_fixture(fx, fid,
    path)``, when given, runs per fixture for suite-specific shape checks and
    raises :class:`ManifestError` on violation."""
    try:
        with path.open() as f:
            manifest = json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        raise ManifestError(f"failed to load manifest {path}: {e}") from e
    _validate_shape(
        manifest,
        path,
        categories=categories,
        fixture_fields=fixture_fields,
        check_version=check_version,
        validate_fixture=validate_fixture,
    )
    return manifest


def _validate_shape(
    manifest: Any,
    path: Path,
    *,
    categories: tuple[str, ...],
    fixture_fields: tuple[str, ...],
    check_version: bool,
    validate_fixture: Callable[[dict, str, Path], None] | None,
) -> None:
    if not isinstance(manifest, dict):
        raise ManifestError(f"{path}: top-level must be a JSON object")
    if manifest.get("category") not in categories:
        wanted = " or ".join(f"'{c}'" for c in categories)
        raise ManifestError(f"{path}: category must be {wanted}, got {manifest.get('category')!r}")
    if check_version and not isinstance(manifest.get("version"), str):
        raise ManifestError(f"{path}: version must be a string")
    fixtures = manifest.get("fixtures")
    if not isinstance(fixtures, list) or not fixtures:
        raise ManifestError(f"{path}: fixtures must be a non-empty array")
    seen: set[str] = set()
    for i, fx in enumerate(fixtures):
        if not isinstance(fx, dict):
            raise ManifestError(f"{path}: fixtures[{i}] must be an object")
        fid = fx.get("id")
        if not isinstance(fid, str) or not fid:
            raise ManifestError(f"{path}: fixtures[{i}].id must be a non-empty string")
        if fid in seen:
            raise ManifestError(f"{path}: duplicate fixture id {fid!r}")
        seen.add(fid)
        for field in fixture_fields:
            if field not in fx:
                raise ManifestError(f"{path}: fixtures[{fid}] missing '{field}'")
        if validate_fixture is not None:
            validate_fixture(fx, fid, path)


# === Adapter discovery / invocation =======================================


class AdapterHarness:
    """Per-binding adapter discovery + subprocess invocation for one suite.

    ``slug`` names the suite everywhere an adapter is addressed: the env
    override is ``$EARTHSCI_<SLUG>_ADAPTER_<BINDING>`` (slug upper-cased,
    hyphens to underscores), the PATH fallback is
    ``earthsci-<slug>-adapter-<binding>``, and the tempfile handoff is
    prefixed ``<slug>-<binding>-``.

    Adapters are invoked as ``<argv> --manifest <path> --output <tmp.json>``
    and must write a JSON object with a ``fixtures`` map. A missing binary,
    timeout, empty output, or malformed payload is classified into an
    ``adapter_status`` of ``missing`` / ``timeout`` / ``no_output`` /
    ``invalid_output`` (with the stderr tail preserved where useful) rather
    than raising — the caller decides whether a broken adapter fails the run
    (required binding) or skips (optional)."""

    def __init__(
        self, slug: str, *, stderr_tail: int = 2000, stderr_on_invalid_json: bool = False
    ) -> None:
        self.slug = slug
        self.env_prefix = f"EARTHSCI_{slug.upper().replace('-', '_')}_ADAPTER_"
        self.path_prefix = f"earthsci-{slug}-adapter-"
        self.stderr_tail = stderr_tail
        self.stderr_on_invalid_json = stderr_on_invalid_json

    def discover(self, binding: str) -> list[str] | None:
        env_cmd = os.environ.get(f"{self.env_prefix}{binding.upper()}")
        if env_cmd:
            return shlex.split(env_cmd)
        on_path = shutil.which(f"{self.path_prefix}{binding}")
        if on_path:
            return [on_path]
        return None

    def missing_record(self, binding: str) -> dict:
        return {
            "binding": binding,
            "adapter_status": "missing",
            "error": (
                f"adapter not found; expected on PATH as "
                f"{self.path_prefix}{binding} or via "
                f"${self.env_prefix}{binding.upper()}"
            ),
            "fixtures": {},
        }

    def run(
        self, binding: str, argv: list[str], manifest_path: Path, timeout: float | None
    ) -> dict:
        with tempfile.NamedTemporaryFile(
            "r", suffix=".json", prefix=f"{self.slug}-{binding}-", delete=False
        ) as tmp:
            out_path = Path(tmp.name)
        try:
            cmd = [*argv, "--manifest", str(manifest_path), "--output", str(out_path)]
            try:
                proc = subprocess.run(
                    cmd, capture_output=True, text=True, timeout=timeout, check=False
                )
            except FileNotFoundError as e:
                return {
                    "binding": binding,
                    "adapter_status": "missing",
                    "error": str(e),
                    "fixtures": {},
                }
            except subprocess.TimeoutExpired:
                return {
                    "binding": binding,
                    "adapter_status": "timeout",
                    "error": f"adapter timed out after {timeout}s",
                    "fixtures": {},
                }
            if not out_path.exists() or out_path.stat().st_size == 0:
                return {
                    "binding": binding,
                    "adapter_status": "no_output",
                    "error": "adapter wrote no output",
                    "exit_code": proc.returncode,
                    "stderr": (proc.stderr or "").strip()[-self.stderr_tail :],
                    "fixtures": {},
                }
            try:
                with out_path.open() as f:
                    payload = json.load(f)
            except json.JSONDecodeError as e:
                record = {
                    "binding": binding,
                    "adapter_status": "invalid_output",
                    "error": f"adapter output not valid JSON: {e}",
                    "fixtures": {},
                }
                if self.stderr_on_invalid_json:
                    record["stderr"] = (proc.stderr or "").strip()[-self.stderr_tail :]
                return record
            if not isinstance(payload, dict) or "fixtures" not in payload:
                return {
                    "binding": binding,
                    "adapter_status": "invalid_output",
                    "error": "adapter output missing 'fixtures'",
                    "fixtures": {},
                }
            payload.setdefault("binding", binding)
            payload["adapter_status"] = "ok"
            return payload
        finally:
            try:
                out_path.unlink()
            except OSError:
                pass

    def collect(
        self, bindings: list[str], manifest_path: Path, timeout: float | None
    ) -> dict[str, dict]:
        """Discover + run the adapter for every requested binding, mapping each
        to its payload (or a ``missing`` record when no adapter is registered)."""
        adapters: dict[str, dict] = {}
        for b in bindings:
            argv = self.discover(b)
            adapters[b] = (
                self.missing_record(b)
                if argv is None
                else self.run(b, argv, manifest_path, timeout)
            )
        return adapters


# === Report output ========================================================


def write_report(report: dict, output_path: Path) -> None:
    """Write the aggregated report as stable (indent=2, sorted-key) JSON."""
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("w") as f:
        json.dump(report, f, indent=2, sort_keys=True)
        f.write("\n")


def print_summary(report: dict, title: str) -> None:
    """The common per-binding / per-fixture console summary."""
    print(title)
    print(f"manifest: {report['manifest_path']}")
    print(f"status:   {report['status'].upper()}")
    for b, br in report.get("bindings", {}).items():
        print(f"  {b:>12}  {br.get('status')}  ({br.get('adapter_status')})")
        for fid, fr in br.get("fixtures", {}).items():
            if fr.get("status") != "ok":
                print(f"      FAIL {fid}: {fr.get('problems') or fr.get('status')}")


# === CLI ==================================================================


def build_parser(
    *,
    doc: str | None,
    default_manifest: Path,
    default_output: Path,
    manifest_help: str | None = None,
    output_help: str | None = "Where to write the aggregated report.",
    bindings_help: str | None = ("Comma-separated bindings (default: manifest required+optional)."),
    timeout_help: str | None = "Per-adapter timeout in seconds.",
    self_test_help: str | None = None,
) -> argparse.ArgumentParser:
    """The common runner CLI: ``--manifest`` / ``--output`` / ``--bindings`` /
    ``--timeout`` / ``--self-test``, with the runner's module docstring as the
    ``--help`` epilogue. Runners with extra modes (e.g. ``--write-golden``)
    add their own arguments to the returned parser before parsing."""
    p = argparse.ArgumentParser(
        description=doc, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    p.add_argument("--manifest", type=Path, default=default_manifest, help=manifest_help)
    p.add_argument("--output", type=Path, default=default_output, help=output_help)
    p.add_argument("--bindings", default="", help=bindings_help)
    p.add_argument("--timeout", type=float, default=None, help=timeout_help)
    p.add_argument("--self-test", action="store_true", help=self_test_help)
    return p


def cli_main(
    argv: list[str] | None,
    *,
    parse_args: Callable[[list[str]], argparse.Namespace],
    self_test: Callable[[Path], int],
    run_suite: Callable[[Path, list[str], Path, float | None], int],
    manifest_check_first: bool = False,
    extra_mode: Callable[[argparse.Namespace], int | None] | None = None,
) -> int:
    """The shared ``main()`` dispatch: ``--self-test`` short-circuits into the
    suite's ``self_test``; a missing manifest is a config error (exit 2);
    otherwise the producer ``run_suite`` runs with the parsed bindings list,
    and a :class:`ManifestError` exits 2.

    ``manifest_check_first`` reproduces the PDE runner's historical dispatch
    order — manifest existence is checked before ``--self-test``, so a missing
    manifest exits 2 even under ``--self-test`` (the other suites let
    ``self_test`` report it and exit 1). ``extra_mode(args)`` may claim the
    run by returning an exit code (the PDE ``--write-golden`` mode); returning
    ``None`` falls through to the producer run."""
    args = parse_args(argv if argv is not None else sys.argv[1:])
    if manifest_check_first and not args.manifest.is_file():
        _eprint(f"error: manifest not found: {args.manifest}")
        return 2
    if args.self_test:
        return self_test(args.manifest)
    if extra_mode is not None:
        rc = extra_mode(args)
        if rc is not None:
            return rc
    if not manifest_check_first and not args.manifest.is_file():
        _eprint(f"error: manifest not found: {args.manifest}")
        return 2
    bindings = [b.strip() for b in args.bindings.split(",") if b.strip()]
    try:
        return run_suite(args.manifest, bindings, args.output, args.timeout)
    except ManifestError as e:
        _eprint(f"manifest error: {e}")
        return 2
