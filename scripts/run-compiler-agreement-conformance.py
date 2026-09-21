#!/usr/bin/env python3
"""Compiler-agreement conformance runner (the `compiler_agreement` tier).

The gate for ``esm_problem``'s ``compiler`` keyword (``API_SPEC.md`` §5.8): every
compiler a binding offers must reproduce the **Julia ``interpreter`` trajectory**
of the same document within the fixture's written band, or refuse it by name.
``compiled_rhs`` (§5.38) compares one right-hand side at fixed probe states; this
tier compares a whole RUN, across the compilers of one binding as well as across
bindings. That is the axis nothing else covers: a strict ``native`` default can be
wrong in a way no cross-binding comparison sees, because every binding's
``native`` could be wrong the same way.

The contract this implements lives in
``tests/conformance/compiler_agreement/README.md``; the normative text is
``CONFORMANCE_SPEC.md`` §5.44. Four decisions of record shape the runner:

  * **Numerical agreement, never structural.** Nothing here inspects an emitted
    program (§5.44.1).
  * **A refusal is never a fallback.** A compiler that cannot run a document says
    so, naming the rule and the reason, and the run records a NAMED EXCLUSION —
    never a pass, never a silent skip. From ``interpreter`` a refusal is always a
    failure, because the interpreter is complete over the evaluable core.
  * **Two ledgers, never merged.** ``compilers.<value>.bindings_required`` governs
    AVAILABILITY (must this binding be able to ANSWER for this compiler); a
    fixture's ``required`` map governs REFUSALS (must this compiler run THIS
    document). Merging them would make a coverage gap indistinguishable from a
    missing runtime.
  * **Fixtures are referenced, not authored.** Every fixture is a document the
    simulation tiers already own, named by path relative to ``tests/``.

Three modes, one harness (mirrors run-compiled-rhs-conformance.py):

  * ``--self-test`` — no live bindings. Validates the manifest and both ledgers,
    checks every COMMITTED golden's file shape and its agreement with whatever
    analytic anchor the fixture carries, and asserts the harness REJECTS a value
    moved off its band, a missing element, a missing save time, an error, an
    ``interpreter`` refusal and a ``required`` refusal — while REPORTING an
    unrequired refusal as a named exclusion. The always-on guard.
  * ``--write-golden --bindings julia --compiler interpreter`` — mint
    ``golden/<id>.json`` from the reference. It refuses to mint from any other
    binding or any other compiler.
  * producers (``--bindings julia,rust,python --compiler native``) — dispatch each
    binding's adapter once per compiler and gate its trajectories against the
    golden AND the carried anchors.

Usage:
    python3 scripts/run-compiler-agreement-conformance.py --self-test
    EARTHSCI_COMPILER_AGREEMENT_ADAPTER_JULIA="julia pkg/EarthSciAST.jl/scripts/compiler_agreement_adapter.jl" \\
        python3 scripts/run-compiler-agreement-conformance.py \\
            --write-golden --bindings julia --compiler interpreter
    python3 scripts/run-compiler-agreement-conformance.py --bindings julia,rust,python \\
        --compiler native --output conformance-results/compiler_agreement/report.json

Exit codes:
    0  the self-test passed, or every required binding answered within tolerance
       (an unrequired refusal and an unavailable optional compiler are green, and
       both are named in the report and on the console)
    1  a mismatch, an error, an `interpreter` refusal, a refusal from a binding a
       fixture's `required` map names, an `unavailable` from a `bindings_required`
       binding, a broken adapter, or a self-test failure
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

# The shared harness (manifest loading, adapter discovery, CLI skeleton) lives in
# scripts/conformance_lib.py; hyphenated runner filenames cannot import each
# other, so put scripts/ on sys.path first.
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
from conformance_lib import load_manifest as _load_manifest  # noqa: E402

DEFAULT_MANIFEST = REPO_ROOT / "tests" / "conformance" / "compiler_agreement" / "manifest.json"
DEFAULT_OUTPUT = Path("conformance-results/compiler_agreement/report.json")

# API_SPEC.md §5.8's closed vocabulary. A manifest naming anything else is a
# manifest error rather than a new compiler: the vocabulary is closed precisely so
# a typo cannot quietly become a tier nobody gates.
COMPILERS = ("interpreter", "native", "xla", "mtk", "sympy")

# Fallback tolerance classes, used only when a manifest omits the block. The
# manifest is the authority; these are §5.38.2's four classes written out so a
# hand-trimmed manifest cannot silently loosen the gate.
DEFAULT_TOLERANCE_CLASSES = {
    "algebraic": {"rtol": 1e-13, "atol": 1e-300},
    "transcendental": {"rtol": 1e-12, "atol": 1e-300},
    "reduction": {"rtol": 1e-11, "atol_scaled": 1e-14},
    "float32": {"rtol": 1e-5, "atol": 1e-30},
}

# The in-repo adapter each binding is planned to ship (§5.44.5). Discovery tries
# the env override first and PATH second, exactly as §5.38's does; this third step
# is what makes a stage work the moment its adapter lands, without every caller
# having to re-state the command. The `probe` path must exist for the command to
# be offered, so a checkout without the adapter falls through to `unavailable`
# with a reason rather than shelling out to something that is not there.
PLANNED_ADAPTERS: dict[str, tuple[str, list[str]]] = {
    "julia": (
        "pkg/EarthSciAST.jl/scripts/compiler_agreement_adapter.jl",
        ["julia", str(REPO_ROOT / "pkg/EarthSciAST.jl/scripts/compiler_agreement_adapter.jl")],
    ),
    "rust": (
        "pkg/earthsci-ast-rs/src/bin/earthsci-compiler-agreement-adapter-rust.rs",
        [
            "cargo",
            "run",
            "--quiet",
            "--manifest-path",
            str(REPO_ROOT / "pkg/earthsci-ast-rs/Cargo.toml"),
            "--features",
            "conformance-adapters",
            "--bin",
            "earthsci-compiler-agreement-adapter-rust",
            "--",
        ],
    ),
    "python": (
        "pkg/earthsci-ast-py/src/earthsci_ast/cli/compiler_agreement_adapter.py",
        ["python3", "-m", "earthsci_ast.cli.compiler_agreement_adapter"],
    ),
}


# === Adapter dispatch =====================================================


class CompilerAgreementHarness(AdapterHarness):
    """``AdapterHarness`` with the three shape differences this tier's adapter
    contract requires.

    1. Every invocation carries ``--compiler <value>``, so one adapter binary
       serves every compiler its binding offers. The adapter passes the value
       straight to ``esm_problem`` and does not interpret it — an adapter that
       chose a build itself would be reimplementing the thing under test.
    2. An ``unavailable`` payload — ``{"binding", "compiler", "status":
       "unavailable", "reason"}`` — is a WHOLE-OUTPUT shape carrying no
       ``fixtures`` map. The base class would classify it ``invalid_output`` and
       discard it, erasing the reason the contract requires the report to print.
    3. A non-zero exit WITH a parsable report is read and gated anyway: the
       per-fixture entries are what say which fixture broke, and throwing them
       away would collapse "one fixture errored" into "the adapter fell over".
    """

    def __init__(self, compiler: str) -> None:
        super().__init__("compiler-agreement", stderr_tail=3000, stderr_on_invalid_json=True)
        self.compiler = compiler

    def discover(self, binding: str) -> list[str] | None:
        argv = super().discover(binding)
        if argv is not None:
            return argv
        planned = PLANNED_ADAPTERS.get(binding)
        if planned is not None and (REPO_ROOT / planned[0]).exists():
            return list(planned[1])
        return None

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
                return {
                    "binding": binding,
                    "compiler": self.compiler,
                    "adapter_status": "missing",
                    "error": str(e),
                    "fixtures": {},
                }
            except subprocess.TimeoutExpired:
                return {
                    "binding": binding,
                    "compiler": self.compiler,
                    "adapter_status": "timeout",
                    "error": f"adapter timed out after {timeout}s",
                    "fixtures": {},
                }
            stderr = (proc.stderr or "").strip()[-self.stderr_tail :]
            if not out_path.exists() or out_path.stat().st_size == 0:
                return {
                    "binding": binding,
                    "compiler": self.compiler,
                    "adapter_status": "no_output",
                    "error": "adapter wrote no output",
                    "exit_code": proc.returncode,
                    "stderr": stderr,
                    "fixtures": {},
                }
            try:
                with out_path.open() as f:
                    payload = json.load(f)
            except json.JSONDecodeError as e:
                return {
                    "binding": binding,
                    "compiler": self.compiler,
                    "adapter_status": "invalid_output",
                    "error": f"adapter output not valid JSON: {e}",
                    "stderr": stderr,
                    "fixtures": {},
                }
            if not isinstance(payload, dict):
                return {
                    "binding": binding,
                    "compiler": self.compiler,
                    "adapter_status": "invalid_output",
                    "error": "adapter output must be a JSON object",
                    "stderr": stderr,
                    "fixtures": {},
                }
            if payload.get("status") == "unavailable":
                return {
                    "binding": payload.get("binding", binding),
                    "compiler": payload.get("compiler", self.compiler),
                    "adapter_status": "unavailable",
                    "reason": payload.get("reason") or "(adapter gave no reason)",
                    "fixtures": {},
                }
            if not isinstance(payload.get("fixtures"), dict):
                return {
                    "binding": binding,
                    "compiler": self.compiler,
                    "adapter_status": "invalid_output",
                    "error": "adapter output missing a 'fixtures' object",
                    "stderr": stderr,
                    "fixtures": {},
                }
            # An adapter that answered for a DIFFERENT compiler than the one it was
            # asked for has mis-wired its own CLI, and every verdict below would be
            # filed under the wrong name. Catch it here rather than let the report
            # claim `native` ran when the adapter ran its interpreter.
            answered = payload.get("compiler", self.compiler)
            if answered != self.compiler:
                return {
                    "binding": binding,
                    "compiler": self.compiler,
                    "adapter_status": "invalid_output",
                    "error": (
                        f"adapter was asked for compiler {self.compiler!r} and answered "
                        f"for {answered!r}"
                    ),
                    "stderr": stderr,
                    "fixtures": {},
                }
            payload.setdefault("binding", binding)
            payload["compiler"] = self.compiler
            payload["adapter_status"] = "ok"
            payload["exit_code"] = proc.returncode
            if stderr:
                payload["stderr"] = stderr
            return payload
        finally:
            try:
                out_path.unlink()
            except OSError:
                pass

    def missing_record(self, binding: str) -> dict:
        rec = super().missing_record(binding)
        rec["compiler"] = self.compiler
        return rec


# === Manifest loading =====================================================


def tests_root(manifest_path: Path) -> Path:
    """The corpus root a fixture ``path`` is relative to.

    The schema says "relative to the repository's ``tests/`` directory", and this
    is the one rule every adapter and the runner must agree on: walk up from the
    manifest to the NEAREST ancestor directory named ``tests``, and fall back to
    the manifest's own directory when there is none. Counting a fixed number of
    parent hops instead would break the moment a manifest moved a level."""
    manifest_path = manifest_path.resolve()
    for parent in manifest_path.parents:
        if parent.name == "tests":
            return parent
    return manifest_path.parent


def _validate_trajectory(fx: dict, fid: str, path: Path) -> None:
    tr = fx.get("trajectory")
    if not isinstance(tr, dict):
        raise ManifestError(f"{path}: fixtures[{fid}].trajectory must be an object")
    src = tr.get("from")
    if src not in ("manifest", "inline_tests"):
        raise ManifestError(
            f"{path}: fixtures[{fid}].trajectory.from must be 'manifest' or 'inline_tests'"
        )
    if src == "manifest":
        ic = tr.get("initial_conditions")
        if not isinstance(ic, dict) or not ic:
            raise ManifestError(
                f"{path}: fixtures[{fid}].trajectory.initial_conditions must name every "
                "state element (a 'manifest' trajectory restates the whole run)"
            )
        tspan = tr.get("tspan")
        if not isinstance(tspan, list) or len(tspan) != 2:
            raise ManifestError(f"{path}: fixtures[{fid}].trajectory.tspan must be [t0, t1]")
        saveat = tr.get("saveat")
        if not isinstance(saveat, list) or not saveat:
            raise ManifestError(
                f"{path}: fixtures[{fid}].trajectory.saveat must be a non-empty array"
            )
    elif not isinstance(tr.get("test_id"), str) or not tr.get("test_id"):
        raise ManifestError(
            f"{path}: fixtures[{fid}].trajectory.test_id must name the inline test whose "
            "run this fixture is"
        )
    if not isinstance(tr.get("observed", []), list):
        raise ManifestError(f"{path}: fixtures[{fid}].trajectory.observed must be an array")


def _validate_tolerance(fx: dict, fid: str, path: Path, classes: dict) -> None:
    """The §5.44.2 rule, checked as SHAPE rather than left to bite at compare time.

    Two sources. ``pde_simulation`` copies that tier's trajectory-versus-golden
    bounds verbatim, so it must state both. ``derived`` names one of the four
    classes and gets it widened by the integration tolerance; the class figures and
    the integration figures MAY be restated in the block for legibility, and when
    they are they must match their authority — a restated figure that has drifted
    from the class or from ``integration`` is a silently different gate, which is
    exactly what writing them twice is supposed to prevent. An explicit ``rtol`` /
    ``atol`` on a derived entry is the tighter-or-looser escape the spec allows,
    and only with a written ``reason``."""
    tol = fx.get("tolerance")
    if not isinstance(tol, dict):
        raise ManifestError(f"{path}: fixtures[{fid}].tolerance must be an object")
    src = tol.get("source")
    if src == "pde_simulation":
        for k in ("rtol", "atol"):
            if not isinstance(tol.get(k), (int, float)):
                raise ManifestError(
                    f"{path}: fixtures[{fid}].tolerance.{k} must be a number for a copied band"
                )
        return
    if src != "derived":
        raise ManifestError(
            f"{path}: fixtures[{fid}].tolerance.source must be 'pde_simulation' or 'derived'"
        )
    cls_name = tol.get("class")
    if cls_name not in classes:
        raise ManifestError(
            f"{path}: fixtures[{fid}].tolerance.class {cls_name!r} is not in tolerance_classes"
        )
    if "rtol" in tol or "atol" in tol:
        if not isinstance(tol.get("rtol"), (int, float)) or not isinstance(
            tol.get("atol"), (int, float)
        ):
            raise ManifestError(
                f"{path}: fixtures[{fid}].tolerance overrides the derived band and must "
                "state BOTH rtol and atol"
            )
        if not str(tol.get("reason") or "").strip():
            raise ManifestError(
                f"{path}: fixtures[{fid}].tolerance overrides the derived band without a "
                "written 'reason' (CONFORMANCE_SPEC §5.44.2 allows the override only with one)"
            )
    cls = classes[cls_name]
    restated = {
        "rtol_class": cls.get("rtol"),
        "atol_class": cls.get("atol"),
        "atol_scaled_class": cls.get("atol_scaled"),
        "reltol_integration": (fx.get("integration") or {}).get("reltol"),
        "abstol_integration": (fx.get("integration") or {}).get("abstol"),
    }
    for key, authority in restated.items():
        if key not in tol:
            continue
        if authority is None or float(tol[key]) != float(authority):
            raise ManifestError(
                f"{path}: fixtures[{fid}].tolerance.{key} is {tol[key]!r} but its authority "
                f"({'tolerance_classes' if key.endswith('_class') else 'integration'}) says "
                f"{authority!r}"
            )


def _validate_fixture_factory(classes: dict):
    def _validate(fx: dict, fid: str, path: Path) -> None:
        if not isinstance(fx.get("model"), str) or not fx["model"]:
            raise ManifestError(f"{path}: fixtures[{fid}].model must be a non-empty string")
        integ = fx.get("integration")
        if not isinstance(integ, dict) or not isinstance(
            integ.get("reltol"), (int, float)
        ) or not isinstance(integ.get("abstol"), (int, float)):
            raise ManifestError(
                f"{path}: fixtures[{fid}].integration must carry numeric reltol and abstol "
                "(a conformance tier has an opinion about what it passes to solve)"
            )
        _validate_trajectory(fx, fid, path)
        _validate_tolerance(fx, fid, path, classes)
        req = fx.get("required")
        if not isinstance(req, dict):
            raise ManifestError(f"{path}: fixtures[{fid}].required must be an object")
        for binding, compilers in req.items():
            if binding not in KNOWN_BINDINGS:
                raise ManifestError(
                    f"{path}: fixtures[{fid}].required names unknown binding {binding!r}"
                )
            if not isinstance(compilers, list) or any(c not in COMPILERS for c in compilers):
                raise ManifestError(
                    f"{path}: fixtures[{fid}].required[{binding}] must be a list of compilers "
                    f"from {COMPILERS}"
                )
        anchor = fx.get("anchor", {})
        if not isinstance(anchor, dict) or anchor.get("source") not in (
            "pde_simulation",
            "inline_tests",
            "none",
            None,
        ):
            raise ManifestError(
                f"{path}: fixtures[{fid}].anchor.source must be 'pde_simulation', "
                "'inline_tests' or 'none'"
            )

    return _validate


def _validate_ledgers(manifest: dict, path: Path) -> None:
    """The two ledgers, and the one way they are allowed to interact.

    ``compilers.<value>.bindings_required`` says a binding must be able to ANSWER
    for that compiler; a fixture's ``required`` map says that compiler must be able
    to RUN that document. A compiler can be required to exist and still be allowed
    to refuse a particular fixture — that is the normal state of a coverage
    backlog. The reverse is incoherent: a fixture cannot demand that a compiler run
    it while the availability ledger lets that binding not offer the compiler at
    all, so that combination is a manifest error the runner reports."""
    compilers = manifest.get("compilers")
    if not isinstance(compilers, dict) or not compilers:
        raise ManifestError(f"{path}: compilers must be a non-empty object")
    for name, block in compilers.items():
        if name not in COMPILERS:
            raise ManifestError(
                f"{path}: compilers names {name!r}, which is not in API_SPEC §5.8's closed "
                f"vocabulary {COMPILERS}"
            )
        if not isinstance(block, dict):
            raise ManifestError(f"{path}: compilers[{name}] must be an object")
        for key in ("bindings_required", "bindings_optional"):
            listed = block.get(key, [])
            if not isinstance(listed, list) or any(b not in KNOWN_BINDINGS for b in listed):
                raise ManifestError(
                    f"{path}: compilers[{name}].{key} must be a list of known bindings"
                )
        both = set(block.get("bindings_required") or []) & set(block.get("bindings_optional") or [])
        if both:
            raise ManifestError(
                f"{path}: compilers[{name}] lists {sorted(both)} as both required and optional"
            )
    for fx in manifest["fixtures"]:
        for binding, names in (fx.get("required") or {}).items():
            for c in names:
                if c not in compilers:
                    raise ManifestError(
                        f"{path}: fixtures[{fx['id']}].required[{binding}] names compiler {c!r}, "
                        "which the availability ledger does not carry at all"
                    )
                if binding not in (compilers[c].get("bindings_required") or []):
                    raise ManifestError(
                        f"{path}: fixtures[{fx['id']}] requires {binding}/{c} to RUN it while "
                        f"compilers[{c}].bindings_required does not require {binding} to offer "
                        f"{c} at all — the two ledgers must not contradict each other"
                    )


def load_manifest(path: Path) -> dict:
    try:
        with path.open() as f:
            probe = json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        raise ManifestError(f"failed to load manifest {path}: {e}") from e
    classes = (probe or {}).get("tolerance_classes") or DEFAULT_TOLERANCE_CLASSES
    if not isinstance(classes, dict):
        raise ManifestError(f"{path}: tolerance_classes must be an object")
    manifest = _load_manifest(
        path,
        categories=("compiler_agreement",),
        fixture_fields=("path", "model", "trajectory", "integration", "tolerance", "required"),
        check_version=True,
        validate_fixture=_validate_fixture_factory(classes),
    )
    if manifest.get("reference_compiler", "interpreter") not in COMPILERS:
        raise ManifestError(
            f"{path}: reference_compiler {manifest.get('reference_compiler')!r} is not a compiler"
        )
    _validate_ledgers(manifest, path)
    # Resolve every fixture path the way the adapters do, and fail as a CONFIG
    # error (exit 2) rather than letting each binding discover the typo on its own
    # and report it as a different kind of breakage.
    root = tests_root(path)
    missing = [fx["id"] for fx in manifest["fixtures"] if not (root / fx["path"]).is_file()]
    if missing:
        raise ManifestError(f"{path}: fixture file(s) not found under {root}: {missing}")
    return manifest


def tolerance_classes(manifest: dict) -> dict:
    return manifest.get("tolerance_classes") or DEFAULT_TOLERANCE_CLASSES


def compiler_bindings(manifest: dict, compiler: str) -> tuple[set[str], set[str]]:
    """(required, optional) bindings for one compiler — the AVAILABILITY ledger."""
    block = manifest.get("compilers", {}).get(compiler, {}) or {}
    return set(block.get("bindings_required") or []), set(block.get("bindings_optional") or [])


def fixture_required(fixture: dict, binding: str) -> list[str]:
    """The compilers that MUST run this fixture in this binding — the REFUSAL
    ledger. Empty for every fixture in phase 1; each name added is a one-way
    ratchet."""
    return list((fixture.get("required") or {}).get(binding) or [])


# === The fixture's document, and the run it defines ========================


def fixture_document(fixture: dict, manifest_path: Path) -> dict:
    fpath = tests_root(manifest_path) / fixture["path"]
    try:
        with fpath.open() as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        raise ManifestError(f"fixture {fixture['id']}: cannot read {fpath}: {e}") from e


def inline_test(fixture: dict, manifest_path: Path) -> dict:
    """The inline ``tests`` entry a ``from: inline_tests`` fixture names.

    The document stays the single source of truth for its own run: the manifest
    restates none of the initial conditions, the parameter overrides or the time
    span, so this is where the runner learns the save times (the assertion times)
    and the anchor."""
    tid = fixture["trajectory"]["test_id"]
    doc = fixture_document(fixture, manifest_path)
    model = (doc.get("models") or {}).get(fixture["model"])
    if not isinstance(model, dict):
        raise ManifestError(
            f"fixture {fixture['id']}: {fixture['path']} has no model {fixture['model']!r}"
        )
    for t in model.get("tests") or []:
        if isinstance(t, dict) and t.get("id") == tid:
            # Carry the model-level tolerance along: an assertion inherits it when
            # it declares none of its own (esm-spec §6.6.4).
            return {"_model_tolerance": model.get("tolerance") or {}, **t}
    raise ManifestError(
        f"fixture {fixture['id']}: {fixture['path']} model {fixture['model']!r} has no inline "
        f"test {tid!r}"
    )


def fixture_saveat(fixture: dict, manifest_path: Path) -> list[float]:
    """The save times of this fixture's run, from whichever source defines it.

    A ``manifest`` trajectory states them. An ``inline_tests`` trajectory does not
    restate anything, so they are the assertion times of the named test — which is
    also what makes every anchor point land on a saved row."""
    tr = fixture["trajectory"]
    if tr["from"] == "manifest":
        return [float(t) for t in tr["saveat"]]
    test = inline_test(fixture, manifest_path)
    times = {float(a["time"]) for a in test.get("assertions") or [] if "time" in a}
    if not times:
        raise ManifestError(
            f"fixture {fixture['id']}: inline test {tr['test_id']!r} has no timed assertions, "
            "so it defines no save times"
        )
    return sorted(times)


# === Numeric comparison ===================================================


def _bare(name: str) -> str:
    """Strip a leading ``Model.`` namespace so element names compare across
    bindings (Julia/Rust emit bare ``u[1]``; Python emits ``Model.u[1]``)."""
    return name.split(".", 1)[1] if "." in name else name


def _num(v) -> float:
    """One value as a float. Plain JSON has no literal for a non-finite number, so
    the contract admits three spellings: a string ``float()`` parses (``"NaN"``,
    ``"Infinity"``, ``"-Infinity"``), a bare ``NaN``/``Infinity`` token (which
    Python's json reader accepts), and ``null``, taken as NaN. The point of
    accepting ``null`` is that the element then fails its comparison BY NAME
    instead of aborting the whole run on ``float(None)``."""
    if v is None:
        return math.nan
    try:
        return float(v)
    except (TypeError, ValueError):
        return math.nan


def _norm_map(d: dict | None) -> dict[str, float]:
    return {_bare(k): _num(v) for k, v in (d or {}).items()}


def _time_key(t: Any) -> str:
    """The canonical save-time key: ``repr(float(t))``, which round-trips the exact
    double, so ``0.05`` / ``"0.05"`` / ``"0.0500"`` all collapse to one bucket and
    two genuinely different times never do."""
    return repr(float(t))


def _match_row(t: Any, state: dict | None) -> dict | None:
    """The produced row at save time ``t``.

    The golden's keys are the adapter's own float repr and the runner matches them
    BY NUMERIC VALUE, not by string. An exact key hit is the normal path; the
    nearest-within-a-hair fallback exists because an adapter that accumulates its
    save times rather than echoing the manifest's can land an ulp away, and a whole
    trajectory should not be unreadable over the last bit of a time stamp."""
    if not isinstance(state, dict) or not state:
        return None
    keyed: dict[str, tuple[float, dict]] = {}
    for k, v in state.items():
        try:
            keyed[_time_key(k)] = (float(k), v)
        except (TypeError, ValueError):
            continue
    want = float(t)
    hit = keyed.get(_time_key(want))
    if hit is not None:
        return hit[1]
    band = 1e-9 + 1e-9 * abs(want)
    best: dict | None = None
    best_d: float | None = None
    for tv, row in keyed.values():
        d = abs(tv - want)
        if d <= band and (best_d is None or d < best_d):
            best, best_d = row, d
    return best


def _close(got: float, want: float, rtol: float, atol: float) -> bool:
    """``|got - want| <= atol + rtol*|want|``, with both-non-finite treated as equal
    so an intentional non-finite identity in a fixture does not spuriously fail."""
    if math.isnan(got) or math.isnan(want):
        return math.isnan(got) and math.isnan(want)
    if math.isinf(got) or math.isinf(want):
        return got == want
    return abs(got - want) <= atol + rtol * abs(want)


def row_band(fixture: dict, classes: dict, want_row: dict[str, float]) -> tuple[float, float]:
    """The (rtol, atol) band for ONE saved row, exactly as §5.44.2 states it.

    ``source: pde_simulation`` copies that tier's trajectory-versus-golden bounds
    verbatim; nothing is added, because they already are a trajectory band.

    ``source: derived`` widens the class by the integration tolerance::

        rtol = rtol_class + reltol_integration
        atol = atol_class + abstol_integration

    and for the ``reduction`` class the class floor is scaled rather than fixed::

        atol = atol_scaled_class * max_i |want_i|  +  abstol_integration

    with the maximum taken over the saved row OF THE REFERENCE, so it is the same
    number for every binding. Adding the integration tolerance is the whole
    difference from §5.38: a trajectory carries the integrator's own error on top
    of the arithmetic's, and a band that ignored it would fail every binding for a
    defect none of them has."""
    tol = fixture["tolerance"]
    if tol.get("source") == "pde_simulation" or ("rtol" in tol and "atol" in tol):
        return float(tol["rtol"]), float(tol["atol"])
    cls = classes[tol["class"]]
    integ = fixture.get("integration") or {}
    reltol_i = float(integ.get("reltol", 0.0))
    abstol_i = float(integ.get("abstol", 0.0))
    rtol = float(cls.get("rtol", 0.0)) + reltol_i
    if "atol_scaled" in cls:
        scale = max((abs(v) for v in want_row.values() if math.isfinite(v)), default=0.0)
        atol = float(cls["atol_scaled"]) * scale + abstol_i
    else:
        atol = float(cls.get("atol", 0.0)) + abstol_i
    return rtol, atol


def compare_row(
    want: dict, got: dict, rtol: float, atol: float, label: str
) -> tuple[float, list[str]]:
    """Compare one ``{element: value}`` row. Returns (max tolerance-budget
    fraction, problems). Every reference element must be present and within
    tolerance; an element the producer adds that the reference does not carry is
    ignored, since the reference decides what the trajectory IS."""
    want_n = _norm_map(want)
    got_n = _norm_map(got)
    problems: list[str] = []
    worst = 0.0
    for name, wv in want_n.items():
        if name not in got_n:
            problems.append(f"{label}: missing element {name!r}")
            continue
        gv = got_n[name]
        budget = atol + rtol * abs(wv)
        if budget > 0 and math.isfinite(gv) and math.isfinite(wv):
            worst = max(worst, abs(gv - wv) / budget)
        elif gv != wv and not (math.isnan(gv) and math.isnan(wv)):
            worst = float("inf")
        if not _close(gv, wv, rtol, atol):
            problems.append(f"{label}: {name} = {gv!r} != {wv!r} (atol={atol:g} rtol={rtol:g})")
    return worst, problems


def compare_trajectory(
    want: dict, got: dict, fixture: dict, classes: dict, kind: str
) -> tuple[float, list[str]]:
    """Compare a whole ``{save time: {element: value}}`` state map against the
    reference, one band per row (the ``reduction`` floor scales with the row)."""
    problems: list[str] = []
    worst = 0.0
    for tk, want_row in (want or {}).items():
        want_n = _norm_map(want_row)
        got_row = _match_row(tk, got)
        if got_row is None:
            problems.append(f"{kind}: missing save time {tk!r}")
            continue
        rtol, atol = row_band(fixture, classes, want_n)
        w, p = compare_row(want_row, got_row, rtol, atol, f"{kind}[t={tk}]")
        worst = max(worst, w)
        problems += p
    return worst, problems


def compare_observed(
    want: dict, got: dict, fixture: dict, classes: dict, kind: str
) -> tuple[float, list[str]]:
    """Compare the observed fields the fixture names, at the same band as the
    state. An observed field is a value the run reports beside the state rows, so
    it is gated exactly as a state element is."""
    named = list((fixture.get("trajectory") or {}).get("observed") or [])
    if not named:
        return 0.0, []
    problems: list[str] = []
    worst = 0.0
    want_o = {_bare(k): v for k, v in (want or {}).items()}
    got_o = {_bare(k): v for k, v in (got or {}).items()}
    for name in named:
        bare = _bare(name)
        if bare not in want_o:
            problems.append(f"{kind}: the reference carries no observed field {name!r}")
            continue
        if bare not in got_o:
            problems.append(f"{kind}: missing observed field {name!r}")
            continue
        for tk, wv in (want_o[bare] or {}).items():
            row = _match_row(tk, {k: {bare: v} for k, v in (got_o[bare] or {}).items()})
            if row is None:
                problems.append(f"{kind}: observed {name!r} missing save time {tk!r}")
                continue
            rtol, atol = row_band(fixture, classes, {bare: _num(wv)})
            w, p = compare_row(
                {bare: wv}, row, rtol, atol, f"{kind}[observed {name} t={tk}]"
            )
            worst = max(worst, w)
            problems += p
    return worst, problems


# === Anchors ==============================================================


def anchor_points(fixture: dict, manifest_path: Path) -> list[dict]:
    """The fixture's INDEPENDENT anchor, as a flat list of
    ``{time, element, expected, rtol, atol}``.

    An anchor is a statement about the PHYSICS and the golden is a statement about
    the ARITHMETIC, so an anchor is gated at the tolerance its own source declares
    rather than at the fixture's band — holding them to one band would mean
    loosening the arithmetic one. ``pde_simulation`` declares ``traj_analytic_*``
    tier-wide; an inline test declares ``tolerance`` per assertion, per test, or
    per model, in that order of precedence, and ``rel`` / ``abs`` are resolved
    independently so an assertion that pins only ``abs`` still inherits the model's
    ``rel``."""
    anchor = fixture.get("anchor") or {}
    source = anchor.get("source")
    if source in (None, "none"):
        return []
    if source == "pde_simulation":
        return _pde_anchor_points(fixture, manifest_path)
    test = inline_test(fixture, manifest_path)
    model_tol = test.get("_model_tolerance") or {}
    test_tol = test.get("tolerance") or {}
    points: list[dict] = []
    for a in test.get("assertions") or []:
        a_tol = a.get("tolerance") or {}
        rel = a_tol.get("rel", test_tol.get("rel", model_tol.get("rel", 0.0)))
        abs_ = a_tol.get("abs", test_tol.get("abs", model_tol.get("abs", 0.0)))
        points.append(
            {
                "time": float(a["time"]),
                "element": _bare(str(a["variable"])),
                "expected": _num(a["expected"]),
                "rtol": float(rel),
                "atol": float(abs_),
            }
        )
    return points


def _pde_anchor_points(fixture: dict, manifest_path: Path) -> list[dict]:
    """The ``pde_simulation`` tier's own ``trajectory.analytic`` block for the same
    document, at that tier's ``traj_analytic_*`` band. The fixture is matched by
    RESOLVED PATH rather than by id: this tier names its fixtures for itself, and
    a shared id would be a second place the two tiers had to be kept in step."""
    src = tests_root(manifest_path) / "conformance" / "pde_simulation" / "manifest.json"
    try:
        with src.open() as f:
            other = json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        raise ManifestError(
            f"fixture {fixture['id']}: anchor.source is 'pde_simulation' but {src} "
            f"could not be read: {e}"
        ) from e
    tol = other.get("tolerances") or {}
    rtol = float(tol.get("traj_analytic_rtol", 0.0))
    atol = float(tol.get("traj_analytic_atol", 0.0))
    want = (tests_root(manifest_path) / fixture["path"]).resolve()
    # That tier writes its fixture paths relative to its own manifest directory,
    # this one writes them relative to `tests/`. Match on the RESOLVED FILE under
    # either reading rather than on the string, so the two tiers are free to keep
    # spelling their paths the way each already does.
    for fx in other.get("fixtures") or []:
        other_path = fx.get("path", "")
        candidates = {
            (src.parent / other_path).resolve(),
            (tests_root(src) / other_path).resolve(),
        }
        if want not in candidates:
            continue
        analytic = (fx.get("trajectory") or {}).get("analytic") or {}
        return [
            {
                "time": float(tk),
                "element": _bare(name),
                "expected": _num(value),
                "rtol": rtol,
                "atol": atol,
            }
            for tk, row in analytic.items()
            for name, value in (row or {}).items()
        ]
    raise ManifestError(
        f"fixture {fixture['id']}: anchor.source is 'pde_simulation' but that tier carries "
        f"no fixture at {fixture['path']}"
    )


def compare_anchor(points: list[dict], got_state: dict, kind: str) -> tuple[float, list[str]]:
    problems: list[str] = []
    worst = 0.0
    for pt in points:
        row = _match_row(pt["time"], got_state)
        if row is None:
            problems.append(f"{kind}: missing save time {pt['time']!r}")
            continue
        got = _norm_map(row).get(pt["element"])
        if got is None:
            problems.append(f"{kind}[t={pt['time']}]: missing element {pt['element']!r}")
            continue
        budget = pt["atol"] + pt["rtol"] * abs(pt["expected"])
        if budget > 0 and math.isfinite(got) and math.isfinite(pt["expected"]):
            worst = max(worst, abs(got - pt["expected"]) / budget)
        if not _close(got, pt["expected"], pt["rtol"], pt["atol"]):
            problems.append(
                f"{kind}[t={pt['time']}]: {pt['element']} = {got!r} != {pt['expected']!r} "
                f"(atol={pt['atol']:g} rtol={pt['rtol']:g})"
            )
    return worst, problems


# === Golden I/O ===========================================================


def golden_path(fixture: dict, manifest_path: Path) -> Path:
    """``golden/<id>.json`` beside the manifest, DERIVED from the id — the manifest
    carries no per-fixture ``golden`` field, so an id and its golden cannot drift
    apart."""
    return manifest_path.parent / "golden" / f"{fixture['id']}.json"


def load_golden(fixture: dict, manifest_path: Path) -> dict | None:
    gpath = golden_path(fixture, manifest_path)
    if not gpath.is_file():
        return None
    try:
        with gpath.open() as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return None


def golden_shape_problems(
    golden: Any, fixture: dict, manifest: dict, saveat: list[float]
) -> list[str]:
    """Everything a committed golden must be before any number in it is believed."""
    problems: list[str] = []
    if not isinstance(golden, dict):
        return ["golden is not a JSON object"]
    if golden.get("id") != fixture["id"]:
        problems.append(f"golden.id is {golden.get('id')!r}, expected {fixture['id']!r}")
    ref_b = manifest.get("reference_binding", "julia")
    ref_c = manifest.get("reference_compiler", "interpreter")
    if golden.get("binding") != ref_b:
        problems.append(f"golden.binding is {golden.get('binding')!r}, expected {ref_b!r}")
    if golden.get("compiler") != ref_c:
        problems.append(f"golden.compiler is {golden.get('compiler')!r}, expected {ref_c!r}")
    order = golden.get("state_order")
    if not isinstance(order, list) or not order or not all(isinstance(s, str) for s in order):
        problems.append("golden.state_order must be a non-empty array of element names")
        order = []
    elif len(set(order)) != len(order):
        problems.append("golden.state_order has duplicate element names")
    state = golden.get("state")
    if not isinstance(state, dict) or not state:
        problems.append("golden.state must be a non-empty object keyed by save time")
        return problems
    for t in saveat:
        row = _match_row(t, state)
        if row is None:
            problems.append(f"golden.state has no row at save time {t!r}")
            continue
        if not isinstance(row, dict):
            problems.append(f"golden.state[{t!r}] is not an object")
            continue
        bare = _norm_map(row)
        for name in order:
            if name not in bare:
                problems.append(f"golden.state[{t!r}] omits {name!r} from state_order")
            elif not math.isfinite(bare[name]):
                problems.append(f"golden.state[{t!r}][{name!r}] is not a finite number")
        for name in bare:
            if order and name not in order:
                problems.append(f"golden.state[{t!r}] carries {name!r}, which is not in state_order")
    named_observed = list((fixture.get("trajectory") or {}).get("observed") or [])
    observed = golden.get("observed", {})
    if not isinstance(observed, dict):
        problems.append("golden.observed must be an object")
    else:
        for name in named_observed:
            if _bare(name) not in {_bare(k) for k in observed}:
                problems.append(f"golden.observed omits the fixture's observed field {name!r}")
    return problems


# === The gate for one (binding, compiler, fixture) ========================


def gate_fixture(
    binding: str,
    compiler: str,
    fixture: dict,
    produced: dict,
    golden: dict | None,
    anchors: list[dict],
    classes: dict,
) -> dict:
    """Gate one binding's output for one fixture under one compiler.

    Five outcomes, and the refusal split is §5.44.3 made executable:

      * ``error`` — the load, the build or the run threw. RED for every binding and
        every compiler; unlike a refusal it says nothing about what a compiler can
        run, so ``required`` does not excuse it.
      * ``refused`` — RED. Either the compiler is ``interpreter`` (complete over
        the evaluable core, so a refusal there is a defect rather than coverage) or
        the fixture's ``required`` map names this binding+compiler.
      * ``excluded`` — the same refusal from any other compiler the fixture does
        not require. Reported by name, rule and reason, and green for now. Never a
        pass and never a silent skip; this list IS the coverage backlog.
      * ``mismatch`` — a value outside the band, or a missing element or save time.
      * ``ok``.
    """
    if produced.get("error") is not None:
        return {
            "status": "error",
            "error": str(produced["error"]),
            "problems": [f"{binding}/{compiler} could not evaluate this fixture: "
                         f"{produced['error']}"],
        }
    if produced.get("status") == "refused":
        rule = produced.get("rule") or "(adapter named no rule)"
        reason = produced.get("reason") or "(adapter gave no reason)"
        is_reference = compiler == "interpreter"
        is_required = compiler in fixture_required(fixture, binding)
        if is_reference:
            why = (
                "the interpreter is complete over the evaluable core "
                "(esm-libraries-spec §2.5.10), so a refusal there is a defect"
            )
        elif is_required:
            why = f"the fixture's `required` map lists {binding}/{compiler}"
        else:
            why = ""
        return {
            "status": "refused" if (is_reference or is_required) else "excluded",
            "rule": rule,
            "reason": reason,
            "required": is_required,
            "interpreter": is_reference,
            "problems": (
                [f"{binding}/{compiler} refused a fixture it must run — {why}: {rule} — {reason}"]
                if (is_reference or is_required)
                else []
            ),
        }
    state = produced.get("state")
    if not isinstance(state, dict):
        return {
            "status": "mismatch",
            "problems": ["adapter fixture entry has no 'state' map and is not a refusal"],
        }
    problems: list[str] = []
    frac_golden = 0.0
    if golden is not None:
        frac_golden, p = compare_trajectory(
            golden.get("state", {}), state, fixture, classes, "vs-golden"
        )
        problems += p
        w, p = compare_observed(
            golden.get("observed", {}), produced.get("observed", {}), fixture, classes, "vs-golden"
        )
        frac_golden = max(frac_golden, w)
        problems += p
    frac_anchor, p = compare_anchor(anchors, state, "vs-anchor")
    problems += p
    return {
        "status": "ok" if not problems else "mismatch",
        "tol_frac_vs_golden": frac_golden,
        "tol_frac_vs_anchor": frac_anchor,
        "problems": problems,
    }


# === Self-test ============================================================

# The synthetic reference the negative controls run against. The committed
# goldens are minted in phase 2, so a self-test that could only exercise the
# harness once they existed would leave the whole gate unchecked for exactly as
# long as there was nothing else checking it.
_SYNTH_STATE = {
    "0.025": {"u[1]": 1000.0, "u[2]": 0.0, "u[3]": -2.5},
    "0.05": {"u[1]": 500.0, "u[2]": 1e-9, "u[3]": -1.25},
}


def _synthetic_fixture(fixture: dict) -> dict:
    """A copy of a manifest fixture whose trajectory is ``_SYNTH_STATE``. The
    tolerance block, the integration block and the class are the real ones, so the
    controls exercise the band the manifest actually asks for."""
    fx = copy.deepcopy(fixture)
    fx["trajectory"] = {"from": "manifest", "observed": []}
    fx["required"] = {}
    return fx


def _report_control(rc: int, ok: bool, label: str, message: str) -> int:
    if ok:
        print(f"self-test OK   [{label}]: {message}")
        return rc
    _eprint(f"self-test FAIL [{label}]: {message}")
    return 1


def _negative_controls(fixture: dict, classes: dict, rc: int) -> int:
    """The harness must REJECT bad output and REPORT an unrequired refusal. Every
    one of the five outcomes and both ledgers get an arm here."""
    fx = _synthetic_fixture(fixture)
    golden = {"state": copy.deepcopy(_SYNTH_STATE)}
    good = {"state": copy.deepcopy(_SYNTH_STATE)}

    v = gate_fixture("julia", "native", fx, good, golden, [], classes)
    rc = _report_control(
        rc, v["status"] == "ok", "pos/exact", f"an exact trajectory passes (got {v['status']!r})"
    )

    # NC1: one element moved 10x its band. The largest-magnitude element, so the
    # relative band rather than the near-zero floor is what is being exercised.
    bad = {"state": copy.deepcopy(_SYNTH_STATE)}
    row = bad["state"]["0.025"]
    name = max(row, key=lambda k: abs(float(row[k])))
    rtol, atol = row_band(fx, classes, _norm_map(row))
    budget = atol + rtol * abs(float(row[name]))
    delta = 10.0 * budget if budget > 0 else 1.0
    if float(row[name]) + delta == float(row[name]):
        delta = 1.0
    row[name] = float(row[name]) + delta
    v = gate_fixture("julia", "native", fx, bad, golden, [], classes)
    rc = _report_control(
        rc,
        v["status"] == "mismatch",
        "neg/off_by_10_tol",
        f"{name} moved {delta:g} (10x its band) is rejected (got {v['status']!r})",
    )

    # NC2: a missing element.
    bad = {"state": copy.deepcopy(_SYNTH_STATE)}
    gone = next(iter(bad["state"]["0.025"]))
    bad["state"]["0.025"].pop(gone)
    v = gate_fixture("julia", "native", fx, bad, golden, [], classes)
    rc = _report_control(
        rc,
        v["status"] == "mismatch",
        "neg/missing_element",
        f"output missing {gone!r} is rejected (got {v['status']!r})",
    )

    # NC3: a missing save time.
    bad = {"state": copy.deepcopy(_SYNTH_STATE)}
    bad["state"].pop("0.05")
    v = gate_fixture("julia", "native", fx, bad, golden, [], classes)
    rc = _report_control(
        rc,
        v["status"] == "mismatch",
        "neg/missing_save_time",
        f"output missing save time 0.05 is rejected (got {v['status']!r})",
    )

    # NC4: an errored fixture is RED for any binding and any compiler, required or
    # not — `required` excuses a refusal, never an error.
    errored = {"error": "ValueError: injected by --self-test"}
    for req, label in (({}, "not-required"), ({"julia": ["native"]}, "required")):
        err_fx = copy.deepcopy(fx)
        err_fx["required"] = req
        v = gate_fixture("julia", "native", err_fx, errored, golden, [], classes)
        rc = _report_control(
            rc,
            v["status"] == "error",
            f"neg/errored_{label}",
            f"an errored fixture fails the gate (got {v['status']!r})",
        )

    # NC5 / NC6 / NC7: the refusal split, all three arms.
    refusal = {
        "status": "refused",
        "rule": "faq/sum_product over a filtered range",
        "reason": "injected by --self-test; no compiler produced this",
    }
    req_fx = copy.deepcopy(fx)
    req_fx["required"] = {"julia": ["native"]}
    v = gate_fixture("julia", "native", req_fx, refusal, golden, [], classes)
    rc = _report_control(
        rc,
        v["status"] == "refused",
        "neg/refusal_required",
        f"a refusal from a `required` binding+compiler fails the gate (got {v['status']!r})",
    )

    v = gate_fixture("julia", "interpreter", fx, refusal, golden, [], classes)
    rc = _report_control(
        rc,
        v["status"] == "refused",
        "neg/refusal_interpreter",
        f"an `interpreter` refusal fails the gate even unrequired (got {v['status']!r})",
    )

    v = gate_fixture("julia", "native", fx, refusal, golden, [], classes)
    rc = _report_control(
        rc,
        v["status"] == "excluded" and bool(v.get("rule")) and bool(v.get("reason")),
        "neg/refusal_excluded",
        (
            f"an unrequired non-interpreter refusal is a named exclusion carrying its rule "
            f"and reason (got {v['status']!r}, rule {v.get('rule')!r})"
        ),
    )
    return rc


def _availability_controls(manifest: dict, rc: int) -> int:
    """The OTHER ledger: an unavailable compiler is green for a binding the manifest
    lists as optional and RED for one it requires. Merging this with the refusal
    ledger would make a coverage gap indistinguishable from a missing runtime."""
    required, optional = compiler_bindings(manifest, "interpreter")
    rc = _report_control(
        rc,
        required == {"julia", "rust", "python"} and not optional,
        "ledger/interpreter_required",
        f"every binding must ANSWER for the interpreter (required={sorted(required)})",
    )
    for compiler in sorted(manifest.get("compilers", {})):
        req, opt = compiler_bindings(manifest, compiler)
        for b in sorted(req):
            rc = _report_control(
                rc,
                not _unavailable_is_green(b, req),
                f"ledger/{compiler}_unavailable_{b}",
                f"an unavailable {compiler} in {b} (a `bindings_required` binding) is RED",
            )
        for b in sorted(opt):
            rc = _report_control(
                rc,
                _unavailable_is_green(b, req),
                f"ledger/{compiler}_unavailable_{b}",
                f"an unavailable {compiler} in {b} (a `bindings_optional` binding) is a "
                "reported skip",
            )
    return rc


def _unavailable_is_green(binding: str, required: set[str]) -> bool:
    return binding not in required


def _tolerance_controls(manifest: dict, classes: dict, rc: int) -> int:
    """The §5.44.2 arithmetic itself: the derived band is the class WIDENED BY THE
    INTEGRATION TOLERANCE, and the ``reduction`` floor scales with the row."""
    for fx in manifest["fixtures"]:
        tol = fx["tolerance"]
        integ = fx["integration"]
        row = {"a": 1000.0, "b": 0.0}
        rtol, atol = row_band(fx, classes, row)
        if tol.get("source") == "pde_simulation":
            ok = rtol == float(tol["rtol"]) and atol == float(tol["atol"])
            rc = _report_control(
                rc,
                ok,
                f"tolerance/{fx['id']}",
                f"the copied band is used verbatim (rtol={rtol:g} atol={atol:g})",
            )
            continue
        cls = classes[tol["class"]]
        want_rtol = float(cls.get("rtol", 0.0)) + float(integ["reltol"])
        if "atol_scaled" in cls:
            want_atol = float(cls["atol_scaled"]) * 1000.0 + float(integ["abstol"])
        else:
            want_atol = float(cls.get("atol", 0.0)) + float(integ["abstol"])
        rc = _report_control(
            rc,
            rtol == want_rtol and atol == want_atol,
            f"tolerance/{fx['id']}",
            (
                f"class {tol['class']} widened by the integration tolerance gives "
                f"rtol={rtol:g} atol={atol:g}"
            ),
        )
    # A scaled floor must admit an exact zero beside a large entry and reject one
    # outside it — the whole reason the `reduction` class exists.
    scaled = [c for c in classes.values() if "atol_scaled" in c]
    for cls in scaled:
        probe = {"tolerance": {"source": "derived", "class": "reduction"}, "integration": {}}
        probe["tolerance"]["class"] = next(k for k, v in classes.items() if v is cls)
        rtol, atol = row_band(probe, classes, {"a": 1000.0, "b": 0.0})
        inside = {"a": 1000.0, "b": atol * 0.5}
        outside = {"a": 1000.0, "b": atol * 10.0}
        ok_in = not compare_row({"a": 1000.0, "b": 0.0}, inside, rtol, atol, "t")[1]
        ok_out = not compare_row({"a": 1000.0, "b": 0.0}, outside, rtol, atol, "t")[1]
        rc = _report_control(
            rc,
            ok_in and not ok_out,
            "tolerance/scaled_floor",
            f"the scaled floor {atol:g} admits an exact zero inside it and rejects one outside",
        )
    return rc


def self_test(manifest_path: Path) -> int:
    try:
        manifest = load_manifest(manifest_path)
    except ManifestError as e:
        _eprint(f"self-test: {e}")
        return 1
    classes = tolerance_classes(manifest)
    fixtures = manifest["fixtures"]
    rc = 0
    print(
        f"self-test OK   [manifest]: {len(fixtures)} fixture(s), "
        f"{len(manifest.get('compilers', {}))} compiler(s); both ledgers are consistent"
    )

    # --- 1. Every committed golden: file shape, then its carried anchor ------
    present = [fx for fx in fixtures if load_golden(fx, manifest_path) is not None]
    if not present:
        print(
            f"self-test ..   [goldens]: none committed yet — golden/ holds nothing for any of "
            f"the {len(fixtures)} fixtures. Phase 2 mints them with `--write-golden --bindings "
            "julia --compiler interpreter`; until then the controls below are the whole gate."
        )
    for fx in fixtures:
        golden = load_golden(fx, manifest_path)
        if golden is None:
            if present:
                # Some goldens exist, so the tier is past phase 1 and a fixture
                # without one is a hole, not a phase.
                rc = _report_control(
                    rc,
                    False,
                    f"golden/{fx['id']}",
                    f"golden missing ({golden_path(fx, manifest_path).name}) while "
                    f"{len(present)} other fixture(s) have one",
                )
            continue
        try:
            saveat = fixture_saveat(fx, manifest_path)
            anchors = anchor_points(fx, manifest_path)
        except ManifestError as e:
            rc = _report_control(rc, False, f"golden/{fx['id']}", str(e))
            continue
        problems = golden_shape_problems(golden, fx, manifest, saveat)
        if problems:
            rc = _report_control(
                rc, False, f"golden/{fx['id']}", f"{len(problems)} shape problem(s)"
            )
            for p in problems[:12]:
                _eprint(f"    {p}")
            continue
        if not anchors:
            print(
                f"self-test ..   [golden/{fx['id']}]: shape ok; no anchor carried, so this "
                "fixture's golden is only a regression check against its own output"
            )
            continue
        worst, problems = compare_anchor(anchors, golden.get("state", {}), "anchor")
        if problems:
            rc = _report_control(
                rc,
                False,
                f"golden/{fx['id']}",
                "the Julia-interpreter golden disagrees with its independent anchor",
            )
            for p in problems[:12]:
                _eprint(f"    {p}")
        else:
            print(
                f"self-test OK   [golden/{fx['id']}]: shape ok and golden == anchor over "
                f"{len(anchors)} point(s) (tol-frac {worst:.2f}x, from "
                f"{(fx.get('anchor') or {}).get('source')})"
            )

    # --- 2. Every fixture resolves the run it describes ----------------------
    for fx in fixtures:
        try:
            saveat = fixture_saveat(fx, manifest_path)
            anchors = anchor_points(fx, manifest_path)
        except ManifestError as e:
            rc = _report_control(rc, False, f"fixture/{fx['id']}", str(e))
            continue
        anchor_src = (fx.get("anchor") or {}).get("source") or "none"
        if anchor_src == "none":
            rc = _report_control(
                rc,
                False,
                f"fixture/{fx['id']}",
                "carries no anchor; a fixture that CAN carry one MUST, or the Julia leg is "
                "only a regression check against its own output",
            )
            continue
        off_grid = [
            pt["time"] for pt in anchors if not any(abs(pt["time"] - t) <= 1e-12 for t in saveat)
        ]
        rc = _report_control(
            rc,
            not off_grid,
            f"fixture/{fx['id']}",
            (
                f"{len(saveat)} save time(s) and {len(anchors)} anchor point(s), every one on a "
                f"saved row" if not off_grid else f"anchor times {off_grid} are not saved rows"
            ),
        )

    # --- 3. The harness must reject bad output and report an exclusion -------
    rc = _negative_controls(fixtures[0], classes, rc)
    rc = _availability_controls(manifest, rc)
    rc = _tolerance_controls(manifest, classes, rc)

    print("\nself-test:", "OK" if rc == 0 else "FAILED")
    return rc


# === Golden writer (reference binding, reference compiler) ================


def write_golden(
    manifest_path: Path, bindings: list[str], compilers: list[str], timeout: float | None
) -> int:
    """Mint ``golden/<id>.json`` from the reference, and from nothing else.

    The golden IS the Julia ``interpreter`` trajectory; minting it from another
    binding or another compiler would make the tier compare a compiled path against
    itself, which is precisely the reading the reference exists to prevent."""
    manifest = load_manifest(manifest_path)
    ref_b = manifest.get("reference_binding", "julia")
    ref_c = manifest.get("reference_compiler", "interpreter")
    if bindings and bindings != [ref_b]:
        _eprint(
            f"--write-golden: the golden is the {ref_b} {ref_c} trajectory; refusing to mint "
            f"from {bindings}. Pass --bindings {ref_b}."
        )
        return 2
    if compilers and compilers != [ref_c]:
        _eprint(
            f"--write-golden: the golden is the {ref_b} {ref_c} trajectory; refusing to mint "
            f"from compiler(s) {compilers}. Pass --compiler {ref_c}."
        )
        return 2
    harness = CompilerAgreementHarness(ref_c)
    argv = harness.discover(ref_b)
    if argv is None:
        _eprint(
            f"--write-golden: reference adapter for {ref_b!r} not registered "
            f"(set ${harness.env_prefix}{ref_b.upper()})"
        )
        return 2
    payload = harness.run(ref_b, argv, manifest_path, timeout)
    if payload.get("adapter_status") != "ok":
        _eprint(
            f"--write-golden: reference adapter failed: {payload.get('adapter_status')} "
            f"{payload.get('error') or payload.get('reason')}"
        )
        if payload.get("stderr"):
            _eprint(payload["stderr"])
        return 1
    written = 0
    for fx in manifest["fixtures"]:
        produced = (payload.get("fixtures") or {}).get(fx["id"])
        if produced is None:
            _eprint(f"--write-golden: the reference produced nothing for {fx['id']}")
            return 1
        if produced.get("status") == "refused":
            _eprint(
                f"--write-golden: the reference {ref_c} REFUSED {fx['id']} "
                f"({produced.get('rule')}: {produced.get('reason')}); a golden cannot be minted "
                "from a refusal, and an interpreter refusal is a defect in any case"
            )
            return 1
        if produced.get("error") is not None:
            _eprint(
                f"--write-golden: the reference could not evaluate {fx['id']}: {produced['error']}"
            )
            return 1
        state = produced.get("state")
        if not isinstance(state, dict) or not state:
            _eprint(f"--write-golden: the reference produced no state map for {fx['id']}")
            return 1
        saveat = fixture_saveat(fx, manifest_path)
        order = _golden_state_order(fx, produced, state)
        rows: dict[str, dict[str, float]] = {}
        for t in saveat:
            row = _match_row(t, state)
            if row is None:
                _eprint(f"--write-golden: the reference omitted save time {t!r} for {fx['id']}")
                return 1
            bare = _norm_map(row)
            absent = [n for n in order if n not in bare]
            if absent:
                _eprint(f"--write-golden: the reference row {fx['id']}[t={t}] omits {absent}")
                return 1
            # A golden carries EXACTLY `state_order`. A binding whose shape
            # inference invents an extra flat element must not put it in the
            # golden, where it would become a requirement every other binding had
            # to reproduce.
            rows[_time_key(t)] = {n: bare[n] for n in order}
        record = {
            "id": fx["id"],
            "binding": ref_b,
            "compiler": ref_c,
            "state_order": order,
            "saveat": [float(t) for t in saveat],
            "state": rows,
            "observed": _golden_observed(fx, produced, saveat),
        }
        gpath = golden_path(fx, manifest_path)
        gpath.parent.mkdir(parents=True, exist_ok=True)
        gpath.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
        written += 1
        try:
            print(f"wrote golden {gpath.relative_to(REPO_ROOT)}")
        except ValueError:
            print(f"wrote golden {gpath}")
    print(f"--write-golden: wrote {written} golden file(s) from {ref_b} ({ref_c})")
    return 0


def _golden_state_order(fixture: dict, produced: dict, state: dict) -> list[str]:
    """The element order a golden pins, in descending order of authority: what the
    adapter declared, then the manifest's own ``initial_conditions`` (which names
    every state element for a ``manifest`` trajectory), then the row's names
    sorted. Sorted last so the fallback is binding-independent rather than
    whichever order one adapter's dictionary happened to iterate in."""
    declared = produced.get("state_order")
    if isinstance(declared, list) and declared and all(isinstance(s, str) for s in declared):
        return [_bare(s) for s in declared]
    ic = (fixture.get("trajectory") or {}).get("initial_conditions")
    if isinstance(ic, dict) and ic:
        return [_bare(k) for k in ic]
    first = next(iter(state.values()), {}) or {}
    return sorted(_bare(k) for k in first)


def _golden_observed(fixture: dict, produced: dict, saveat: list[float]) -> dict:
    named = list((fixture.get("trajectory") or {}).get("observed") or [])
    out: dict[str, dict[str, float]] = {}
    got = {_bare(k): v for k, v in (produced.get("observed") or {}).items()}
    for name in named:
        series = got.get(_bare(name)) or {}
        out[_bare(name)] = {
            _time_key(t): _num(series.get(k))
            for t in saveat
            for k in series
            if abs(float(k) - float(t)) <= 1e-9 + 1e-9 * abs(float(t))
        }
    return out


# === Producer run mode ====================================================


def run_suite(
    manifest_path: Path,
    bindings: list[str],
    compilers: list[str],
    output_path: Path,
    timeout: float | None,
) -> int:
    manifest = load_manifest(manifest_path)
    classes = tolerance_classes(manifest)
    fixtures = manifest["fixtures"]
    known_compilers = list(manifest.get("compilers", {}))
    if not compilers:
        compilers = known_compilers
    for c in compilers:
        if c not in known_compilers:
            _eprint(f"error: compiler {c!r} is not in the manifest; known: {known_compilers}")
            return 2
    scope_excluded = manifest.get("scope_excluded") or {}
    for b in bindings:
        if b not in KNOWN_BINDINGS:
            _eprint(f"error: unknown binding {b!r}; known: {KNOWN_BINDINGS}")
            return 2
        if b in scope_excluded:
            _eprint(
                f"error: {b} is out of scope for this tier: {scope_excluded[b]}. Asking for it "
                "would report a compiler it has no way to name."
            )
            return 2

    goldens = {fx["id"]: load_golden(fx, manifest_path) for fx in fixtures}
    missing_golden = [fid for fid, g in goldens.items() if g is None]
    if missing_golden:
        _eprint(
            f"error: golden(s) missing: {missing_golden}. The reference trajectory is what "
            "every compiler is gated against, so there is nothing to compare to yet; mint them "
            "with --write-golden --bindings julia --compiler interpreter."
        )
        return 2
    anchors = {fx["id"]: anchor_points(fx, manifest_path) for fx in fixtures}

    report: dict[str, Any] = {
        "manifest_path": str(manifest_path),
        "reference_binding": manifest.get("reference_binding", "julia"),
        "reference_compiler": manifest.get("reference_compiler", "interpreter"),
        "status": "ok",
        "compilers": {},
        # The two ledgers the contract requires the report to print BY NAME: every
        # refusal (with its rule and its reason) and every compiler that was not
        # available (with its reason). Neither is ever a silent skip.
        "refusals": [],
        "unavailable": [],
        "manifest_excluded": manifest.get("excluded", []),
    }
    overall_ok = True

    for compiler in compilers:
        required, optional = compiler_bindings(manifest, compiler)
        run_bindings = bindings or sorted(required | optional)
        if not run_bindings:
            _eprint(f"error: compiler {compiler!r} names no bindings and none were given")
            return 2
        harness = CompilerAgreementHarness(compiler)
        adapters = harness.collect(run_bindings, manifest_path, timeout)
        c_report: dict[str, Any] = {
            "bindings_required": sorted(required),
            "bindings_optional": sorted(optional),
            "bindings": {},
            "status": "ok",
        }
        c_ok = True
        for b in run_bindings:
            b_report, b_ok = _gate_binding(
                b, compiler, adapters[b], fixtures, goldens, anchors, classes, required, report
            )
            c_report["bindings"][b] = b_report
            c_ok = c_ok and b_ok
        c_report["status"] = "ok" if c_ok else "fail"
        overall_ok = overall_ok and c_ok
        report["compilers"][compiler] = c_report

    report["status"] = "ok" if overall_ok else "fail"
    write_report(report, output_path)
    _print_summary(report)
    return 1 if report["status"] == "fail" else 0


def _gate_binding(
    binding: str,
    compiler: str,
    adapter: dict,
    fixtures: list,
    goldens: dict,
    anchors: dict,
    classes: dict,
    required: set[str],
    report: dict,
) -> tuple[dict, bool]:
    status = adapter.get("adapter_status")
    b_report: dict[str, Any] = {
        "adapter_status": status,
        "error": adapter.get("error"),
        "fixtures": {},
    }
    if status in ("unavailable", "missing"):
        # `missing` and `unavailable` are the same FACT reported from two sides:
        # the adapter saying this compiler is not configured here, and there being
        # no adapter to ask. Both are availability, which is the ledger
        # `bindings_required` governs — and neither is a refusal.
        reason = adapter.get("reason") or adapter.get("error") or "(no reason given)"
        report["unavailable"].append({"binding": binding, "compiler": compiler, "reason": reason})
        b_report["reason"] = reason
        if binding in required:
            b_report["status"] = "fail"
            return b_report, False
        b_report["status"] = "unavailable"
        return b_report, True
    if status != "ok":
        # timeout / no_output / invalid_output. An adapter that exits without a
        # parsable report is a BROKEN adapter, not an unavailable compiler, so it is
        # RED whether or not the binding is required: the alternative is a build
        # failure that reads as a legal skip.
        if adapter.get("stderr"):
            b_report["stderr"] = adapter["stderr"]
        b_report["status"] = "fail"
        return b_report, False

    b_ok = True
    if adapter.get("exit_code"):
        b_report["exit_code"] = adapter["exit_code"]
        if adapter.get("stderr"):
            b_report["stderr"] = adapter["stderr"]
    for fx in fixtures:
        produced = (adapter.get("fixtures") or {}).get(fx["id"])
        if produced is None:
            b_report["fixtures"][fx["id"]] = {
                "status": "missing",
                "problems": ["adapter produced no entry for this fixture"],
            }
            b_ok = False
            continue
        fr = gate_fixture(
            binding, compiler, fx, produced, goldens[fx["id"]], anchors[fx["id"]], classes
        )
        b_report["fixtures"][fx["id"]] = fr
        if fr["status"] in ("refused", "excluded"):
            report["refusals"].append(
                {
                    "binding": binding,
                    "compiler": compiler,
                    "fixture": fx["id"],
                    "rule": fr.get("rule"),
                    "reason": fr.get("reason"),
                    "required": fr.get("required", False),
                    "verdict": "fail" if fr["status"] == "refused" else "named exclusion",
                }
            )
        if fr["status"] not in ("ok", "excluded"):
            b_ok = False
    b_report["status"] = "ok" if b_ok else "fail"
    return b_report, b_ok


def _print_summary(report: dict) -> None:
    print("=== Compiler-Agreement Conformance Report ===")
    print(f"manifest:  {report['manifest_path']}")
    print(f"reference: {report['reference_binding']} / {report['reference_compiler']}")
    print(f"status:    {report['status'].upper()}")
    for compiler, cr in report.get("compilers", {}).items():
        print(f"  compiler {compiler}  {str(cr.get('status')).upper()}")
        for b, br in cr.get("bindings", {}).items():
            print(f"    {b:>10}  {str(br.get('status')).upper():12} ({br.get('adapter_status')})")
            for fid, fr in br.get("fixtures", {}).items():
                st = fr.get("status")
                if st == "ok":
                    print(
                        f"        ok       {fid:34s} "
                        f"golden={fr.get('tol_frac_vs_golden', 0):.2f}x "
                        f"anchor={fr.get('tol_frac_vs_anchor', 0):.2f}x (tol-frac, <1=pass)"
                    )
                elif st == "excluded":
                    print(
                        f"        excluded {fid:34s} refused: {fr.get('rule')} — "
                        f"{fr.get('reason')}"
                    )
                elif st == "error":
                    print(f"        ERROR    {fid}: {fr.get('error')}")
                else:
                    print(f"        FAIL     {fid}: {st}")
                    for p in (fr.get("problems") or [])[:6]:
                        print(f"                 {p}")
            if br.get("reason"):
                print(f"        unavailable: {br['reason']}")
            if br.get("error"):
                print(f"        error: {br['error']}")
            if br.get("stderr"):
                print(f"        stderr (tail): {br['stderr'][-600:]}")
    if report.get("unavailable"):
        print("  compilers not available:")
        for u in report["unavailable"]:
            print(f"      {u['binding']} / {u['compiler']}: {u['reason']}")
    if report.get("refusals"):
        print("  refusals (the named-exclusion list IS the coverage backlog):")
        for r in report["refusals"]:
            print(
                f"      {r['binding']} / {r['compiler']} / {r['fixture']}: {r['rule']} — "
                f"{r['reason']}  [{r['verdict']}]"
            )
    if report.get("manifest_excluded"):
        print(
            f"  manifest exclusions: {len(report['manifest_excluded'])} fixture(s) not in "
            "this tier"
        )


# === CLI ==================================================================


def parse_args(argv: list[str]):
    p = build_parser(
        doc=__doc__,
        default_manifest=DEFAULT_MANIFEST,
        default_output=DEFAULT_OUTPUT,
        output_help=(
            "Where to write the aggregated report (default: "
            f"{DEFAULT_OUTPUT}; --results-dir moves the directory)."
        ),
        bindings_help=(
            "Comma-separated bindings (default: the compiler's required + optional bindings)."
        ),
        timeout_help=None,
        self_test_help=(
            "Validate the manifest and both ledgers, check every committed golden's shape and "
            "its carried anchor, and assert the harness rejects bad output and required "
            "refusals, then exit."
        ),
    )
    p.add_argument(
        "--compiler",
        "--compilers",
        dest="compilers",
        default="",
        help=(
            "Comma-separated compilers from API_SPEC §5.8's vocabulary "
            f"{COMPILERS} (default: every compiler the manifest carries)."
        ),
    )
    p.add_argument(
        "--results-dir",
        type=Path,
        default=None,
        help=(
            "Directory for the report, used as <dir>/report.json when --output is left at its "
            "default. An explicit --output always wins."
        ),
    )
    p.add_argument(
        "--write-golden",
        action="store_true",
        help=(
            "Run only the reference binding's reference compiler and (re)write golden/*.json. "
            "Refuses any other binding or compiler."
        ),
    )
    return p.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv if argv is not None else sys.argv[1:])
    if not args.manifest.is_file():
        _eprint(f"error: manifest not found: {args.manifest}")
        return 2
    bindings = [b.strip() for b in args.bindings.split(",") if b.strip()]
    compilers = [c.strip() for c in args.compilers.split(",") if c.strip()]
    try:
        if args.self_test:
            return self_test(args.manifest)
        if args.write_golden:
            return write_golden(args.manifest, bindings, compilers, args.timeout)
        output = args.output
        if args.results_dir is not None and output == DEFAULT_OUTPUT:
            output = args.results_dir / "report.json"
        return run_suite(args.manifest, bindings, compilers, output, args.timeout)
    except ManifestError as e:
        _eprint(f"manifest error: {e}")
        return 2


if __name__ == "__main__":
    sys.exit(main())
