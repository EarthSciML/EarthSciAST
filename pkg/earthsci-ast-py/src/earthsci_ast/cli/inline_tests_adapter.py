"""Python adapter for the INLINE-TEST conformance tiers (``CONFORMANCE_SPEC.md`` §5.45).

Each tier's fixtures are documents that carry their own esm-spec §6.6 ``tests``
blocks. This adapter runs them through :func:`earthsci_ast.inline_tests.run_inline_tests`
under the compiler named on the command line and reports, per assertion, whether
this binding's own §6.6.3 predicate passed and what the ACTUAL reduction value
was. The runner gates both — ``passed`` against the document's authored
expectation, ``actual`` against the committed Julia-``interpreter`` golden —
which is why the adapter reports the number as well as the verdict.

``--compiler`` is required and is passed STRAIGHT through to ``esm_problem``.
This adapter never inspects it to choose a build: an adapter that did would be
reimplementing the thing under test.

The three per-fixture outcomes the contract defines, and the distinction between
them that is load-bearing:

* ``refused`` -- this compiler cannot evaluate this document. Two shapes reach
  it: a :class:`~earthsci_ast.compiler.CompilerRefusedRuleError` out of the
  build, and a run in which EVERY assertion failed carrying ONE coded
  diagnostic (an operator with no evaluation rule declines at evaluation rather
  than at build, and calling that "every number is wrong" would file a refusal
  in the same bucket as a numeric defect). The runner reads a refusal as a
  named exclusion, or -- for a fixture whose ``required`` map names this
  compiler -- as a failure.
* ``unavailable`` -- the whole output, when the compiler does not exist in this
  binding at all. A fact about this BUILD, never about a document.
* ``error`` -- anything else the load, the build or the run threw. It says
  nothing about what a compiler can run, so ``required`` does not excuse it.

The runner discovers this adapter via ``$EARTHSCI_INLINE_TESTS_ADAPTER_PYTHON``
or on PATH as ``earthsci-inline-tests-adapter-python``. This package installs no
console script -- ``esm`` (Rust) is the only command-line tool the project ships
-- so the supported invocation is the module form, and it is what
``scripts/test-conformance.sh`` sets::

    python3 -m earthsci_ast.cli.inline_tests_adapter \
        --manifest <manifest.json> --output <out.json> --compiler <value>
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any

from earthsci_ast.compiler import CompilerRefusedRuleError, CompilerUnavailableError
from earthsci_ast.inline_tests import run_inline_tests

#: The binding name this adapter reports under.
BINDING = "python"

#: The coded diagnostics a refusal can carry. A message naming one of these is
#: this binding declining to evaluate the document, which the tier records as a
#: NAMED EXCLUSION under the fixture's ledger -- never as a wrong answer, and
#: never as a silent skip. Anything else is an ordinary assertion failure.
REFUSAL_CODES = (
    "compiler_refused_rule",
    "compiler_unavailable",
    "unevaluable_operator",
    "unlowered_operator",
    "unsupported_construct",
)

_TREEWALK_CODE = re.compile(r"\bE_TREEWALK_[A-Z0-9_]+")


def tests_dir_for(manifest_path: Path) -> Path:
    """The repository ``tests/`` directory a fixture's ``path`` may be relative
    to, found by walking up from the manifest's ABSOLUTE path."""
    for parent in manifest_path.resolve().parents:
        if parent.name == "tests":
            return parent
    return manifest_path.resolve().parent


def fixture_path(manifest_path: Path, fixture: dict[str, Any]) -> Path:
    """Resolve a fixture's ``.esm``: against the manifest's own directory first
    (a document the tier authored), then against ``tests/`` (a document another
    tier already owns). The two-step rule every binding's adapter applies, so a
    tier is free to reference rather than copy."""
    rel = fixture["path"]
    local = (manifest_path.resolve().parent / rel).resolve()
    if local.is_file():
        return local
    return (tests_dir_for(manifest_path) / rel).resolve()


def refusal_code(message: str) -> str | None:
    """The coded diagnostic a message names, or ``None``. Matched against the
    closed list plus the ``E_TREEWALK_*`` family, so an ordinary numeric failure
    -- whose message names no code -- can never be mistaken for a refusal."""
    for code in REFUSAL_CODES:
        if code in message:
            return code
    m = _TREEWALK_CODE.search(message)
    return m.group(0) if m else None


def run_fixture(
    fixture: dict[str, Any], manifest: dict[str, Any], manifest_path: Path, compiler: str
) -> dict[str, Any]:
    path = fixture_path(manifest_path, fixture)
    if not path.is_file():
        raise FileNotFoundError(f"fixture document not found at {path}")
    integ = manifest["integrators"]["python"]
    results = run_inline_tests(
        str(path),
        model_name=fixture["model"],
        method=integ["method"],
        rtol=float(integ["rtol"]),
        atol=float(integ["atol"]),
        base_dir=str(path.parent),
        compiler=compiler,
    )
    if not results:
        raise ValueError(
            f"the document declares no inline assertions for model {fixture['model']!r}"
        )

    entries = [
        {
            "test_id": r.test_id,
            "assertion_idx": int(r.assertion_idx),
            "variable": r.variable,
            "passed": bool(r.passed),
            "actual": None if r.actual is None else float(r.actual),
            "message": r.message,
        }
        for r in results
    ]

    codes = [refusal_code(r.message) for r in results if not r.passed]
    if (
        len(codes) == len(results)
        and codes
        and all(c is not None for c in codes)
        and len(set(codes)) == 1
    ):
        return {
            "status": "refused",
            "code": codes[0],
            "reason": results[0].message[:400],
        }
    return {"assertions": entries}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument(
        "--compiler",
        required=True,
        help=(
            "Which strategy builds each fixture's right-hand side (API_SPEC §5.8). "
            "REQUIRED: a stage that names no compiler measures whatever the library "
            "default happens to be."
        ),
    )
    args = parser.parse_args(argv if argv is not None else sys.argv[1:])
    manifest = json.loads(args.manifest.read_text())

    fixtures: dict[str, Any] = {}
    failed: list[str] = []
    payload: dict[str, Any] = {
        "binding": BINDING,
        "compiler": args.compiler,
        "fixtures": fixtures,
    }
    for fixture in manifest["fixtures"]:
        fid = fixture["id"]
        try:
            fixtures[fid] = run_fixture(fixture, manifest, args.manifest, args.compiler)
        except CompilerUnavailableError as exc:
            # A fact about the BINDING, not about a document: it is the whole
            # output and the remaining fixtures are not attempted.
            payload = {
                "binding": BINDING,
                "compiler": args.compiler,
                "status": "unavailable",
                "reason": str(exc)[:400],
            }
            break
        except CompilerRefusedRuleError as exc:
            fixtures[fid] = {
                "status": "refused",
                "code": "compiler_refused_rule",
                "reason": str(exc)[:400],
            }
        except Exception as exc:  # noqa: BLE001 - surface per-fixture failure to the runner
            message = f"{type(exc).__name__}: {exc}"
            code = refusal_code(message)
            if code is not None:
                fixtures[fid] = {"status": "refused", "code": code, "reason": message[:400]}
            else:
                failed.append(fid)
                fixtures[fid] = {"error": message[:800]}

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    if failed:
        print(
            f"inline_tests_adapter: {len(failed)} fixture(s) errored: {', '.join(failed)}",
            file=sys.stderr,
        )
        # A non-zero exit WITH a parsable report is legal and is how a run that
        # broke on one fixture still hands the runner the rest.
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
