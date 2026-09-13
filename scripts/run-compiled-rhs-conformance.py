#!/usr/bin/env python3
"""Compiled right-hand-side conformance runner (the `compiled_rhs` tier).

The gate for the two compiled backends — Julia's direct StableHLO emission
through Reactant, and Rust's XlaBuilder emission through the ``xla`` crate — and,
today, the cross-binding gate for the three interpreters themselves. A binding's
engine must reproduce the reference interpreter's right-hand side ``f(u, p, t)``
at fixed probe states, within a written per-class tolerance.

The contract this implements verbatim lives in
``tests/conformance/compiled_rhs/README.md``; the normative text is
``CONFORMANCE_SPEC.md`` §5.38. Three decisions of record drive the shape of this
runner and are worth restating where they bite:

  * **Numerical agreement, never structural.** Nothing here inspects an emitted
    program. A compiled engine passes when its numbers land inside the tolerance
    band of the fixture's class; how it got there is its own business.
  * **A refusal is a hard error, not a fallback.** An engine that cannot lower a
    model completely says so (``{"status": "refused", ...}``) and the run records
    it as a NAMED EXCLUSION in the report. It is never a pass and never a silent
    skip. A refusal from a binding the fixture lists in ``compiled_required``
    fails the gate outright.
  * **Precision-changing fixtures are excluded**, by name and with a reason, in
    the manifest's ``excluded`` array — until both emitters lower them.

Two phases, one harness (mirrors run-pde-simulation-conformance.py):

  * ``--self-test`` — no live bindings. Asserts the committed Julia-interpreter
    golden reproduces every independent ``analytic_rhs`` anchor in the manifest,
    and that the harness REJECTS (a) a golden value perturbed by 10x its
    tolerance budget, (b) output missing an element, and (c) a refusal from a
    ``compiled_required`` binding — while REPORTING a refusal from a binding that
    is not required as an exclusion. The always-on regression guard.
  * producers (``--bindings julia,rust,python --engine interpreter|compiled``) —
    dispatch each binding's adapter (``$EARTHSCI_COMPILED_RHS_ADAPTER_<BINDING>``
    or ``earthsci-compiled-rhs-adapter-<binding>`` on PATH), collect its RHS at
    every probe, and gate it against the golden AND the analytic anchors.

``--write-golden`` runs ONLY the reference binding's INTERPRETER engine and
(re)writes ``golden/<id>.json`` from its output.

Usage:
    python3 scripts/run-compiled-rhs-conformance.py --self-test
    EARTHSCI_COMPILED_RHS_ADAPTER_JULIA="julia pkg/EarthSciAST.jl/scripts/compiled_rhs_adapter.jl" \\
        python3 scripts/run-compiled-rhs-conformance.py --write-golden --bindings julia
    python3 scripts/run-compiled-rhs-conformance.py --bindings julia,rust,python \\
        --engine interpreter --output conformance-results/compiled_rhs/report.json

Exit codes:
    0  self-test passed, or every required binding matched within tolerance
    1  a mismatch, a refusal from a `compiled_required` binding, an `unavailable`
       from a required binding, or a self-test failure
    2  manifest / configuration error (no run attempted)
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
    cli_main,
    write_report,
)
from conformance_lib import load_manifest as _load_manifest  # noqa: E402

DEFAULT_MANIFEST = REPO_ROOT / "tests" / "conformance" / "compiled_rhs" / "manifest.json"

ENGINES = ("interpreter", "compiled")

# Fallback tolerance classes, used only when a manifest omits the block. The
# manifest is the authority; these are the 2026-09-13 ruling written out so a
# hand-trimmed manifest cannot silently loosen the gate.
DEFAULT_TOLERANCE_CLASSES = {
    "algebraic": {"rtol": 1e-13, "atol": 1e-300},
    "transcendental": {"rtol": 1e-12, "atol": 1e-300},
    "reduction": {"rtol": 1e-11, "atol_scaled": 1e-14},
    "float32": {"rtol": 1e-5, "atol": 1e-30},
}


# === Adapter dispatch =====================================================


class CompiledRhsHarness(AdapterHarness):
    """``AdapterHarness`` with the two shape differences this tier's adapter
    contract requires.

    1. Every invocation carries ``--engine <interpreter|compiled>``, so one
       adapter binary serves both engines.
    2. An ``unavailable`` payload — ``{"binding", "engine", "status":
       "unavailable", "reason"}`` — is a WHOLE-OUTPUT shape that carries no
       ``fixtures`` map. The base class classifies a payload without ``fixtures``
       as ``invalid_output`` and discards it, which would erase exactly the
       reason the contract demands the report print. So the JSON classification
       is re-done here rather than inherited: an unavailable payload is accepted,
       tagged ``adapter_status == "unavailable"``, and its reason preserved.
    """

    def __init__(self, engine: str = "interpreter") -> None:
        super().__init__("compiled-rhs", stderr_tail=3000, stderr_on_invalid_json=True)
        self.engine = engine

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
                "--engine",
                self.engine,
            ]
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
            stderr = (proc.stderr or "").strip()[-self.stderr_tail :]
            if not out_path.exists() or out_path.stat().st_size == 0:
                return {
                    "binding": binding,
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
                    "adapter_status": "invalid_output",
                    "error": f"adapter output not valid JSON: {e}",
                    "stderr": stderr,
                    "fixtures": {},
                }
            if not isinstance(payload, dict):
                return {
                    "binding": binding,
                    "adapter_status": "invalid_output",
                    "error": "adapter output must be a JSON object",
                    "stderr": stderr,
                    "fixtures": {},
                }
            if payload.get("status") == "unavailable":
                return {
                    "binding": payload.get("binding", binding),
                    "engine": payload.get("engine", self.engine),
                    "adapter_status": "unavailable",
                    "reason": payload.get("reason") or "(adapter gave no reason)",
                    "fixtures": {},
                }
            if "fixtures" not in payload:
                return {
                    "binding": binding,
                    "adapter_status": "invalid_output",
                    "error": "adapter output missing 'fixtures'",
                    "stderr": stderr,
                    "fixtures": {},
                }
            payload.setdefault("binding", binding)
            payload.setdefault("engine", self.engine)
            payload["adapter_status"] = "ok"
            return payload
        finally:
            try:
                out_path.unlink()
            except OSError:
                pass


# === Manifest loading =====================================================


def _validate_fixture(fx: dict, fid: str, path: Path) -> None:
    order = fx.get("state_order")
    if not isinstance(order, list) or not order or not all(isinstance(s, str) for s in order):
        raise ManifestError(f"{path}: fixtures[{fid}].state_order must be a non-empty string array")
    if len(set(order)) != len(order):
        raise ManifestError(f"{path}: fixtures[{fid}].state_order has duplicate element names")
    if not isinstance(fx.get("parameters", {}), dict):
        raise ManifestError(f"{path}: fixtures[{fid}].parameters must be an object")
    req = fx.get("compiled_required", [])
    if not isinstance(req, list) or any(b not in KNOWN_BINDINGS for b in req):
        raise ManifestError(
            f"{path}: fixtures[{fid}].compiled_required must be a list of known bindings"
        )
    probes = fx.get("rhs_probes")
    if not isinstance(probes, list) or not probes:
        raise ManifestError(f"{path}: fixtures[{fid}].rhs_probes must be a non-empty array")
    seen: set[str] = set()
    for i, pr in enumerate(probes):
        if not isinstance(pr, dict):
            raise ManifestError(f"{path}: fixtures[{fid}].rhs_probes[{i}] must be an object")
        pid = pr.get("id")
        if not isinstance(pid, str) or not pid:
            raise ManifestError(f"{path}: fixtures[{fid}].rhs_probes[{i}].id must be a string")
        if pid in seen:
            raise ManifestError(f"{path}: fixtures[{fid}] duplicate probe id {pid!r}")
        seen.add(pid)
        if not isinstance(pr.get("t"), (int, float)):
            raise ManifestError(f"{path}: fixtures[{fid}].rhs_probes[{pid}].t must be a number")
        state = pr.get("state")
        if not isinstance(state, dict):
            raise ManifestError(
                f"{path}: fixtures[{fid}].rhs_probes[{pid}].state must be an object"
            )
        # Every probe names EVERY element of state_order: a probe that leaves one
        # out would be evaluated at a binding-chosen default, and the bindings
        # would then no longer be evaluating the same input.
        missing = [s for s in order if s not in state]
        if missing:
            raise ManifestError(
                f"{path}: fixtures[{fid}].rhs_probes[{pid}].state omits {missing} "
                "(every probe must name every state_order element)"
            )
        extra = [s for s in state if s not in order]
        if extra:
            raise ManifestError(
                f"{path}: fixtures[{fid}].rhs_probes[{pid}].state names {extra}, "
                "which are not in state_order"
            )


def load_manifest(path: Path) -> dict:
    manifest = _load_manifest(
        path,
        categories=("compiled_rhs",),
        fixture_fields=(
            "path",
            "model",
            "tolerance_class",
            "compiled_required",
            "state_order",
            "parameters",
            "rhs_probes",
        ),
        check_version=True,
        validate_fixture=_validate_fixture,
    )
    classes = manifest.get("tolerance_classes") or DEFAULT_TOLERANCE_CLASSES
    if not isinstance(classes, dict):
        raise ManifestError(f"{path}: tolerance_classes must be an object")
    for fx in manifest["fixtures"]:
        cls = fx["tolerance_class"]
        if cls not in classes:
            raise ManifestError(
                f"{path}: fixtures[{fx['id']}].tolerance_class {cls!r} is not in tolerance_classes"
            )
    engines = manifest.get("engines")
    if not isinstance(engines, dict) or any(e not in engines for e in ENGINES):
        raise ManifestError(f"{path}: engines must name both {ENGINES}")
    return manifest


def tolerance_classes(manifest: dict) -> dict:
    return manifest.get("tolerance_classes") or DEFAULT_TOLERANCE_CLASSES


def engine_bindings(manifest: dict, engine: str) -> tuple[set[str], set[str]]:
    """(required, optional) bindings for one engine, from the manifest."""
    block = manifest.get("engines", {}).get(engine, {}) or {}
    return set(block.get("bindings_required") or []), set(block.get("bindings_optional") or [])


# === Numeric comparison ===================================================


def _bare(name: str) -> str:
    """Strip a leading ``Model.`` namespace so element names compare across
    bindings (Julia/Rust emit bare ``u[1]``; Python emits ``Model.u[1]``)."""
    return name.split(".", 1)[1] if "." in name else name


def _norm_map(d: dict | None) -> dict[str, float]:
    return {_bare(k): float(v) for k, v in (d or {}).items()}


def probe_atol(want: dict[str, float], cls: dict) -> float:
    """The absolute floor for one probe under one tolerance class.

    Plain classes carry a fixed ``atol``. The ``reduction`` class instead carries
    ``atol_scaled``, and its floor is ``atol_scaled * max_i |want_i|`` over the
    WHOLE probe vector: a reduction legitimately produces exact zeros next to
    large entries (a stencil interior that cancels, a filtered `faq` row that sums
    to nothing), and a fixed relative bound on a zero is an impossible bound. The
    scale is taken from the reference vector, so it is the same number for every
    binding.
    """
    if "atol_scaled" in cls:
        scale = max((abs(v) for v in want.values() if math.isfinite(v)), default=0.0)
        return float(cls["atol_scaled"]) * scale
    return float(cls.get("atol", 0.0))


def _close(got: float, want: float, rtol: float, atol: float) -> bool:
    """``|got - want| <= atol + rtol*|want|``, with both-non-finite treated as
    equal so an intentional non-finite identity in a fixture does not spuriously
    fail."""
    if math.isnan(got) or math.isnan(want):
        return math.isnan(got) and math.isnan(want)
    if math.isinf(got) or math.isinf(want):
        return got == want
    return abs(got - want) <= atol + rtol * abs(want)


def compare_probe(want: dict, got: dict, cls: dict, label: str) -> tuple[float, list[str]]:
    """Compare one probe's ``{element: value}`` map against the reference. Returns
    (max tolerance-budget fraction, problems). Every reference element must be
    present and within tolerance."""
    want_n = _norm_map(want)
    got_n = _norm_map(got)
    rtol = float(cls.get("rtol", 0.0))
    atol = probe_atol(want_n, cls)
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


def compare_rhs(want_rhs: dict, got_rhs: dict, cls: dict, kind: str) -> tuple[float, list[str]]:
    """Compare a whole fixture's ``{probe_id: {element: value}}`` map."""
    problems: list[str] = []
    worst = 0.0
    for pid, want in want_rhs.items():
        if pid not in got_rhs:
            problems.append(f"{kind}: missing probe {pid!r}")
            continue
        w, p = compare_probe(want, got_rhs[pid], cls, f"{kind}[{pid}]")
        worst = max(worst, w)
        problems += p
    return worst, problems


def analytic_reference(fixture: dict) -> dict:
    """The fixture's INDEPENDENT anchors: ``{probe_id: analytic_rhs}`` for every
    probe that carries one. A probe without an anchor contributes nothing — it is
    still gated against the golden."""
    return {
        pr["id"]: pr["analytic_rhs"]
        for pr in fixture["rhs_probes"]
        if isinstance(pr.get("analytic_rhs"), dict)
    }


# === Golden I/O ===========================================================


def golden_path(fixture: dict, manifest_path: Path) -> Path:
    """``golden/<id>.json`` beside the manifest. The tier derives the path from
    the fixture id rather than carrying a per-fixture ``golden`` field, so an id
    and its golden can never drift apart."""
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


# === The gate for one (binding, fixture) =================================


def gate_fixture(
    binding: str, fixture: dict, produced: dict, golden: dict | None, cls: dict
) -> dict:
    """Gate one binding's output for one fixture.

    Four outcomes, and the refusal split is the hard-error ruling made visible:

      * ``refused`` — the engine could not lower the model, and the fixture lists
        this binding in ``compiled_required``. A FAILURE.
      * ``excluded`` — the same refusal from a binding the fixture does NOT
        require. Reported by name and reason, and it passes. Never silent.
      * ``mismatch`` — a value outside the class tolerance, or a missing element
        or probe.
      * ``ok``.
    """
    if produced.get("status") == "refused":
        required = binding in (fixture.get("compiled_required") or [])
        return {
            "status": "refused" if required else "excluded",
            "rule": produced.get("rule") or "(adapter named no rule)",
            "reason": produced.get("reason") or "(adapter gave no reason)",
            "compiled_required": required,
            "problems": (
                [
                    f"{binding} refused a fixture it is REQUIRED to compile: "
                    f"{produced.get('rule')} — {produced.get('reason')}"
                ]
                if required
                else []
            ),
        }
    got_rhs = produced.get("rhs")
    if not isinstance(got_rhs, dict):
        return {
            "status": "mismatch",
            "problems": ["adapter fixture entry has no 'rhs' map and is not a refusal"],
        }
    problems: list[str] = []
    frac_golden = 0.0
    if golden is not None:
        frac_golden, p = compare_rhs(golden.get("rhs", {}), got_rhs, cls, "vs-golden")
        problems += p
    frac_analytic, p = compare_rhs(analytic_reference(fixture), got_rhs, cls, "vs-analytic")
    problems += p
    return {
        "status": "ok" if not problems else "mismatch",
        "tol_frac_vs_golden": frac_golden,
        "tol_frac_vs_analytic": frac_analytic,
        "problems": problems,
    }


# === Self-test ============================================================


def _perturbed_golden(golden: dict, probe_id: str, cls: dict) -> tuple[dict, str, float]:
    """A copy of ``golden`` with ONE element of ``probe_id`` moved 10x its
    tolerance budget off. Picks the largest-magnitude element so the relative
    band, not the near-zero absolute floor, is what the control exercises; an
    all-zero probe falls back to a flat 1.0 bump."""
    bad = copy.deepcopy(golden)
    vec = bad["rhs"][probe_id]
    name = max(vec, key=lambda k: abs(float(vec[k])))
    want = float(vec[name])
    budget = probe_atol(_norm_map(vec), cls) + float(cls.get("rtol", 0.0)) * abs(want)
    delta = 10.0 * budget if budget > 0 else 1.0
    if want + delta == want:  # underflowed into the mantissa; use a visible bump
        delta = 1.0
    vec[name] = want + delta
    return bad, name, delta


def self_test(manifest_path: Path) -> int:
    try:
        manifest = load_manifest(manifest_path)
    except ManifestError as e:
        _eprint(f"self-test: {e}")
        return 1
    classes = tolerance_classes(manifest)
    fixtures = manifest["fixtures"]
    rc = 0
    anchored = 0

    # --- 1. The committed golden reproduces every independent anchor ---------
    for fx in fixtures:
        cls = classes[fx["tolerance_class"]]
        golden = load_golden(fx, manifest_path)
        if golden is None:
            rc = 1
            _eprint(
                f"self-test FAIL [{fx['id']}]: golden missing "
                f"({golden_path(fx, manifest_path).name}); run --write-golden first"
            )
            continue
        anchors = analytic_reference(fx)
        if not anchors:
            print(f"self-test ..   [{fx['id']}]: no analytic_rhs anchor (golden-only fixture)")
            continue
        anchored += 1
        worst, problems = compare_rhs(anchors, golden.get("rhs", {}), cls, "anchor")
        if problems:
            rc = 1
            _eprint(
                f"self-test FAIL [{fx['id']}]: the Julia-interpreter golden "
                f"disagrees with its independent analytic_rhs anchors"
            )
            for p in problems[:12]:
                _eprint(f"    {p}")
        else:
            print(
                f"self-test OK   [{fx['id']}]: golden == analytic_rhs over "
                f"{len(anchors)} probe(s) (tol-frac {worst:.2f}x, class "
                f"{fx['tolerance_class']})"
            )

    if anchored == 0:
        rc = 1
        _eprint(
            "self-test FAIL [anchors]: not one fixture carries an analytic_rhs "
            "anchor — the tier would be comparing the reference against itself"
        )

    # --- 2. Negative controls: the harness MUST reject bad output ------------
    ref_fx = fixtures[0]
    ref_cls = classes[ref_fx["tolerance_class"]]
    golden = load_golden(ref_fx, manifest_path)
    if golden is not None:
        probe0 = ref_fx["rhs_probes"][0]["id"]

        # NC1: one element moved 10x its tolerance budget off.
        bad, el, delta = _perturbed_golden(golden, probe0, ref_cls)
        v = gate_fixture("julia", ref_fx, bad, golden, ref_cls)
        if v["status"] == "ok":
            rc = 1
            _eprint(
                f"self-test FAIL [neg/off_by_10_tol]: harness accepted {el} moved "
                f"{delta:g} (10x its tolerance budget) — it must reject"
            )
        else:
            print(f"self-test OK   [neg/off_by_10_tol]: {el} moved {delta:g} (10x budget) rejected")

        # NC2: a missing element.
        bad2 = copy.deepcopy(golden)
        gone = next(iter(bad2["rhs"][probe0]))
        bad2["rhs"][probe0].pop(gone)
        if gate_fixture("julia", ref_fx, bad2, golden, ref_cls)["status"] == "ok":
            rc = 1
            _eprint(
                f"self-test FAIL [neg/missing_element]: harness accepted output "
                f"missing {gone!r} — it must reject"
            )
        else:
            print(f"self-test OK   [neg/missing_element]: missing {gone!r} rejected")

        # NC3: a missing probe.
        bad3 = copy.deepcopy(golden)
        bad3["rhs"].pop(probe0)
        if gate_fixture("julia", ref_fx, bad3, golden, ref_cls)["status"] == "ok":
            rc = 1
            _eprint(
                f"self-test FAIL [neg/missing_probe]: harness accepted output "
                f"missing probe {probe0!r} — it must reject"
            )
        else:
            print(f"self-test OK   [neg/missing_probe]: missing probe {probe0!r} rejected")

    # --- 3. Injected-refusal controls (the hard-error ruling) ----------------
    # Phase 1 leaves every `compiled_required` empty, so both arms are exercised
    # against COPIES of fixture 0 rather than against the manifest as committed.
    refusal = {
        "status": "refused",
        "rule": "faq/sum_product over a filtered range",
        "reason": "injected by --self-test; no engine produced this",
    }
    req_fx = copy.deepcopy(ref_fx)
    req_fx["compiled_required"] = ["julia"]
    v = gate_fixture("julia", req_fx, refusal, golden, ref_cls)
    if v["status"] != "refused":
        rc = 1
        _eprint(
            "self-test FAIL [neg/refusal_required]: a refusal from a "
            f"compiled_required binding reported {v['status']!r}, must be 'refused' (a failure)"
        )
    else:
        print("self-test OK   [neg/refusal_required]: required-binding refusal fails the gate")

    opt_fx = copy.deepcopy(ref_fx)
    opt_fx["compiled_required"] = []
    v = gate_fixture("julia", opt_fx, refusal, golden, ref_cls)
    if v["status"] != "excluded":
        rc = 1
        _eprint(
            "self-test FAIL [neg/refusal_excluded]: a refusal from a binding that is "
            f"NOT compiled_required reported {v['status']!r}, must be 'excluded' "
            "(reported by name, never a silent skip)"
        )
    elif not v.get("rule") or not v.get("reason"):
        rc = 1
        _eprint(
            "self-test FAIL [neg/refusal_excluded]: the exclusion carried no rule/reason; "
            "the report must name both"
        )
    else:
        print(
            "self-test OK   [neg/refusal_excluded]: non-required refusal reported as a "
            f"named exclusion ({v['rule']})"
        )

    # --- 4. The tolerance-class semantics themselves ------------------------
    # `reduction` and `float32` are declared by the manifest but carried by no
    # phase-1 fixture (the precision fixtures that would use `float32` are
    # excluded by §5.38.4), so nothing above exercises the SCALED absolute floor.
    # Gate it directly, on a synthetic probe, rather than leave the one piece of
    # arithmetic the README spells out unchecked until a fixture happens to need it.
    for cname, cls in sorted(classes.items()):
        want = {"a": 1000.0, "b": 0.0}
        floor = probe_atol(want, cls)
        if "atol_scaled" in cls:
            expect = float(cls["atol_scaled"]) * 1000.0
            if not math.isclose(floor, expect, rel_tol=0.0, abs_tol=0.0):
                rc = 1
                _eprint(
                    f"self-test FAIL [tolerance/{cname}]: the scaled floor is {floor!r}, "
                    f"expected atol_scaled * max|want| = {expect!r}"
                )
                continue
            # An exact zero beside a large entry is admitted inside the floor and
            # rejected outside it — the whole reason the class exists.
            inside = {"a": 1000.0, "b": floor * 0.5}
            outside = {"a": 1000.0, "b": floor * 10.0}
            ok_in = not compare_probe(want, inside, cls, "t")[1]
            ok_out = not compare_probe(want, outside, cls, "t")[1]
            if not ok_in or ok_out:
                rc = 1
                _eprint(
                    f"self-test FAIL [tolerance/{cname}]: the scaled floor admitted "
                    f"{'nothing' if not ok_in else 'too much'} around an exact zero"
                )
            else:
                print(
                    f"self-test OK   [tolerance/{cname}]: scaled floor = "
                    f"{cls['atol_scaled']:g} * max|want| = {floor:g}; an exact zero "
                    "passes inside it and fails outside"
                )
        else:
            expect = float(cls.get("atol", 0.0))
            if floor != expect:
                rc = 1
                _eprint(
                    f"self-test FAIL [tolerance/{cname}]: fixed floor is {floor!r}, "
                    f"expected atol = {expect!r}"
                )
            else:
                print(
                    f"self-test OK   [tolerance/{cname}]: fixed floor atol={expect:g}, "
                    f"rtol={float(cls.get('rtol', 0.0)):g}"
                )

    print("\nself-test:", "OK" if rc == 0 else "FAILED")
    return rc


# === Golden writer (reference binding, interpreter engine) ================


def write_golden(manifest_path: Path, timeout: float | None) -> int:
    manifest = load_manifest(manifest_path)
    ref = manifest.get("reference_binding", "julia")
    harness = CompiledRhsHarness("interpreter")
    argv = harness.discover(ref)
    if argv is None:
        _eprint(
            f"--write-golden: reference adapter for {ref!r} not registered "
            f"(set ${harness.env_prefix}{ref.upper()})"
        )
        return 2
    payload = harness.run(ref, argv, manifest_path, timeout)
    if payload.get("adapter_status") != "ok":
        _eprint(
            f"--write-golden: reference adapter failed: "
            f"{payload.get('adapter_status')} {payload.get('error') or payload.get('reason')}"
        )
        if payload.get("stderr"):
            _eprint(payload["stderr"])
        return 1
    written = 0
    for fx in manifest["fixtures"]:
        produced = payload.get("fixtures", {}).get(fx["id"])
        if produced is None:
            _eprint(f"--write-golden: reference produced nothing for {fx['id']}")
            return 1
        if produced.get("status") == "refused":
            _eprint(
                f"--write-golden: the reference INTERPRETER refused {fx['id']} "
                f"({produced.get('rule')}: {produced.get('reason')}); a golden cannot "
                "be minted from a refusal"
            )
            return 1
        record = {
            "fixture": fx["id"],
            "reference_binding": ref,
            "engine": "interpreter",
            "tolerance_class": fx["tolerance_class"],
            "rhs": {pid: _norm_map(vec) for pid, vec in produced.get("rhs", {}).items()},
        }
        gpath = golden_path(fx, manifest_path)
        gpath.parent.mkdir(parents=True, exist_ok=True)
        gpath.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
        written += 1
        print(f"wrote golden {gpath.relative_to(REPO_ROOT)}")
    print(f"--write-golden: wrote {written} golden file(s) from {ref} (interpreter)")
    return 0


# === Producer run mode ====================================================


def run_suite(
    manifest_path: Path,
    bindings: list[str],
    output_path: Path,
    timeout: float | None,
    engine: str = "interpreter",
) -> int:
    manifest = load_manifest(manifest_path)
    classes = tolerance_classes(manifest)
    fixtures = manifest["fixtures"]
    reference_binding = manifest.get("reference_binding", "julia")
    required, optional = engine_bindings(manifest, engine)
    if not bindings:
        bindings = sorted(required | optional)
    if not bindings:
        _eprint(f"error: engine {engine!r} names no bindings and none were given")
        return 2
    for b in bindings:
        if b not in KNOWN_BINDINGS:
            _eprint(f"error: unknown binding {b!r}; known: {KNOWN_BINDINGS}")
            return 2

    goldens = {fx["id"]: load_golden(fx, manifest_path) for fx in fixtures}
    missing_golden = [fid for fid, g in goldens.items() if g is None]
    if missing_golden:
        _eprint(f"error: golden(s) missing: {missing_golden}; run --write-golden")
        return 2

    harness = CompiledRhsHarness(engine)
    adapters = harness.collect(bindings, manifest_path, timeout)

    report: dict[str, Any] = {
        "manifest_path": str(manifest_path),
        "engine": engine,
        "reference_binding": reference_binding,
        "status": "ok",
        "bindings": {},
        # The two ledgers the contract requires the report to print BY NAME:
        # every refusal (with its rule and reason) and every engine that was not
        # available (with its reason). Neither is ever a silent skip.
        "refusals": [],
        "unavailable": [],
        "manifest_excluded": manifest.get("excluded", []),
    }
    overall_ok = True

    for b in bindings:
        ar = adapters[b]
        status = ar.get("adapter_status")
        b_report: dict[str, Any] = {
            "adapter_status": status,
            "error": ar.get("error"),
            "fixtures": {},
        }
        if status == "unavailable":
            reason = ar.get("reason")
            report["unavailable"].append({"binding": b, "engine": engine, "reason": reason})
            b_report["reason"] = reason
            if b in required:
                b_report["status"] = "fail"
                overall_ok = False
            else:
                b_report["status"] = "unavailable"
            report["bindings"][b] = b_report
            continue
        if status != "ok":
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
                    "problems": ["adapter produced no entry for this fixture"],
                }
                b_ok = False
                continue
            fr = gate_fixture(b, fx, produced, goldens[fx["id"]], classes[fx["tolerance_class"]])
            b_report["fixtures"][fx["id"]] = fr
            if fr["status"] in ("refused", "excluded"):
                report["refusals"].append(
                    {
                        "binding": b,
                        "engine": engine,
                        "fixture": fx["id"],
                        "rule": fr.get("rule"),
                        "reason": fr.get("reason"),
                        "compiled_required": fr.get("compiled_required", False),
                        "verdict": "fail" if fr["status"] == "refused" else "named exclusion",
                    }
                )
            if fr["status"] not in ("ok", "excluded"):
                b_ok = False
        b_report["status"] = "ok" if b_ok else "fail"
        if not b_ok:
            overall_ok = False
        report["bindings"][b] = b_report

    report["status"] = "ok" if overall_ok else "fail"
    write_report(report, output_path)
    _print_summary(report)
    return 1 if report["status"] == "fail" else 0


def _print_summary(report: dict) -> None:
    print("=== Compiled-RHS Conformance Report ===")
    print(f"manifest:  {report['manifest_path']}")
    print(f"engine:    {report['engine']}")
    print(f"reference: {report['reference_binding']}")
    print(f"status:    {report['status'].upper()}")
    for b, br in report.get("bindings", {}).items():
        print(f"  {b:>10}  {str(br.get('status')).upper():12} ({br.get('adapter_status')})")
        for fid, fr in br.get("fixtures", {}).items():
            st = fr.get("status")
            if st == "ok":
                print(
                    f"      ok       {fid:44s} "
                    f"golden={fr.get('tol_frac_vs_golden', 0):.2f}x "
                    f"analytic={fr.get('tol_frac_vs_analytic', 0):.2f}x "
                    "(tol-frac, <1=pass)"
                )
            elif st == "excluded":
                print(f"      excluded {fid:44s} refused: {fr.get('rule')} — {fr.get('reason')}")
            else:
                print(f"      FAIL     {fid}: {st}")
                for p in (fr.get("problems") or [])[:6]:
                    print(f"               {p}")
        if br.get("reason"):
            print(f"      unavailable: {br['reason']}")
        if br.get("error"):
            print(f"      error: {br['error']}")
        if br.get("stderr"):
            print(f"      stderr (tail): {br['stderr'][-600:]}")
    if report.get("unavailable"):
        print("  engines not available:")
        for u in report["unavailable"]:
            print(f"      {u['binding']} / {u['engine']}: {u['reason']}")
    if report.get("refusals"):
        print("  refusals:")
        for r in report["refusals"]:
            print(
                f"      {r['binding']} / {r['engine']} / {r['fixture']}: "
                f"{r['rule']} — {r['reason']}  [{r['verdict']}]"
            )
    if report.get("manifest_excluded"):
        print(
            f"  manifest exclusions: {len(report['manifest_excluded'])} fixture(s) not in this tier"
        )


# === CLI ==================================================================


def parse_args(argv: list[str]):
    p = build_parser(
        doc=__doc__,
        default_manifest=DEFAULT_MANIFEST,
        default_output=Path("conformance-results/compiled_rhs/report.json"),
        output_help=None,
        bindings_help=(
            "Comma-separated bindings (default: the engine's required + optional bindings)."
        ),
        timeout_help=None,
        self_test_help=(
            "Assert the golden reproduces every analytic_rhs anchor and that the "
            "harness rejects perturbed output and required-binding refusals, then exit."
        ),
    )
    p.add_argument(
        "--engine",
        choices=ENGINES,
        default="interpreter",
        help="Which engine to ask each adapter for (default: interpreter).",
    )
    p.add_argument(
        "--write-golden",
        action="store_true",
        help="Run only the reference binding's interpreter and (re)write golden/*.json.",
    )
    return p.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    return cli_main(
        argv,
        parse_args=parse_args,
        self_test=self_test,
        # cli_main's run_suite takes four positional arguments; --engine rides in
        # through this closure rather than widening the shared signature.
        run_suite=lambda mp, bindings, out, timeout: run_suite(
            mp, bindings, out, timeout, engine=_ENGINE[0]
        ),
        # Same dispatch order as the PDE runner: a missing manifest is a config
        # error (exit 2) even under --self-test.
        manifest_check_first=True,
        extra_mode=_extra_mode,
    )


# cli_main parses the args itself, so the chosen engine is stashed here on the
# way past `extra_mode` (which is the first callback to see the namespace).
_ENGINE = ["interpreter"]


def _extra_mode(args) -> int | None:
    _ENGINE[0] = args.engine
    if args.write_golden:
        return write_golden(args.manifest, args.timeout)
    return None


if __name__ == "__main__":
    sys.exit(main())
