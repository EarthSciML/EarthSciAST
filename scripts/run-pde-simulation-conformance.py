#!/usr/bin/env python3
"""Cross-language PDE-simulation conformance runner (bead ess-fmw).

The **simulation** analogue of the byte-identity conformance gates: it verifies
that the three PDE-simulation-capable bindings — **Julia (reference), Python,
and Rust** — agree on the *discretized method-of-lines RHS* f(u,t) and on the
*integrated trajectory* of shared, pre-discretized ESM fixtures, compared on a
**numeric-tolerance** basis (trajectories are floating-point evaluation, not
canonical-JSON byte forms).

Unlike the IR/rewrite conformance (byte-identical canonical JSON across five
bindings), simulation outputs legitimately differ in the last bits across
language math libraries and integrators, so:

  * **RHS** is pure arithmetic over the same makearray stencil and must agree to
    a tight tolerance (``rhs_rtol``/``rhs_atol``), both across bindings (against
    the Julia golden) and against an INDEPENDENT analytic anchor ``L u + b``
    assembled by the fixture generator.
  * **Trajectory** is compared (a) across bindings against the Julia golden at a
    moderate tolerance (``traj_golden_*``) with each binding's integrator pinned
    in the manifest, and (b) against the exact matrix-exponential / manufactured
    solution at a looser tolerance (``traj_analytic_*``) that absorbs integrator
    truncation.

Two phases, one harness (mirrors run-geometry-conformance.py):

  * ``--self-test`` — no live bindings. Asserts the committed Julia golden
    reproduces the manifest's independent analytic anchors (RHS and trajectory),
    and that the harness REJECTS perturbed values (negative controls). This is
    the always-on regression guard.
  * producers (``--bindings julia,python,rust``) — dispatch each binding's
    adapter (registered via ``$EARTHSCI_PDE_SIM_ADAPTER_<BINDING>`` or found on
    PATH as ``earthsci-pde-sim-adapter-<binding>``), collect its f(u,t) +
    trajectory, and gate every binding against the golden AND the analytic
    anchors, reporting per-binding deltas. Fails loudly on any divergence.

``--write-golden`` runs ONLY the reference (Julia) adapter and (re)writes
``golden/<id>.json`` from its output — the reproducible golden-generation path.

Scope: Go and TypeScript are excluded — they implement only the rewrite half
(no arrayop/makearray evaluator, no simulator) and cannot run PDEs.

Usage:
    python scripts/run-pde-simulation-conformance.py --self-test
    EARTHSCI_PDE_SIM_ADAPTER_JULIA="julia --project=... adapter.jl" \\
        python scripts/run-pde-simulation-conformance.py --write-golden --bindings julia
    python scripts/run-pde-simulation-conformance.py --bindings julia,python,rust \\
        --output conformance-results/pde_simulation/report.json

Exit codes:
    0  self-test passed, or every required binding matched within tolerance
    1  a contract violation / mismatch (or self-test failed)
    2  manifest / config error (no run attempted)
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any

# The shared harness (manifest loading, adapter dispatch, CLI skeleton) lives
# in scripts/conformance_lib.py; hyphenated runner filenames cannot import
# each other, so put scripts/ on sys.path first.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from conformance_lib import (  # noqa: E402 — needs the sys.path bootstrap above
    KNOWN_BINDINGS,
    REPO_ROOT,
    AdapterHarness,
    ManifestError,
    _eprint,
    build_parser,
    cli_main,
    run_producer_suite,
)
from conformance_lib import load_manifest as _load_manifest  # noqa: E402

DEFAULT_MANIFEST = REPO_ROOT / "tests" / "conformance" / "pde_simulation" / "manifest.json"

DEFAULT_TOLERANCES = {
    "rhs_rtol": 1e-9,
    "rhs_atol": 1e-11,
    "traj_golden_rtol": 1e-6,
    "traj_golden_atol": 1e-9,
    "traj_analytic_rtol": 1e-4,
    "traj_analytic_atol": 1e-6,
}

# Adapter addressing: $EARTHSCI_PDE_SIM_ADAPTER_<BINDING> or
# earthsci-pde-sim-adapter-<binding> on PATH. Simulator adapters emit long
# solver diagnostics, so keep a longer stderr tail and preserve it even when
# the output file is unparseable JSON.
_ADAPTERS = AdapterHarness("pde-sim", stderr_tail=3000, stderr_on_invalid_json=True)


# === Manifest loading =====================================================


def load_manifest(path: Path) -> dict:
    # Two sibling categories share this harness: the original pre-discretized,
    # linear, matrix-exponential-anchored ``pde_simulation`` set, and the
    # full-pipeline, nonlinear, reference-integrator-anchored
    # ``pde_simulation_pipeline`` set (DESIGN.md). Both use the identical manifest
    # shape and comparison bands; the only difference is the trajectory anchor
    # (in-manifest ``trajectory.analytic`` vs. an external ``trajectory.reference``
    # file), handled in ``_analytic_reference``.
    return _load_manifest(
        path,
        categories=("pde_simulation", "pde_simulation_pipeline"),
        fixture_fields=("path", "model", "rhs_probes", "trajectory", "golden"),
        check_version=False,
    )


# === Numeric comparison ===================================================


def _close(a: float, b: float, rtol: float, atol: float) -> bool:
    """|a - b| <= atol + rtol*|b|, with both-non-finite treated as equal so an
    intentional +/-inf identity in a fixture does not spuriously fail."""
    import math

    if math.isnan(a) or math.isnan(b):
        return math.isnan(a) and math.isnan(b)
    if math.isinf(a) or math.isinf(b):
        return a == b
    return abs(a - b) <= atol + rtol * abs(b)


def _bare(name: str) -> str:
    """Strip a leading ``Model.`` namespace so element names compare across
    bindings (Julia/Rust emit bare ``u[1]``; Python emits ``Model.u[1]``)."""
    return name.split(".", 1)[1] if "." in name else name


def _norm_map(d: dict | None) -> dict[str, float]:
    return {_bare(k): float(v) for k, v in (d or {}).items()}


def _time_key(t: Any) -> str:
    """Canonical trajectory time key: ``f"{float(t):g}"`` so 0.05 / "0.05" /
    "0.0500" all collapse to the same bucket across producers."""
    return f"{float(t):g}"


def compare_state(
    ref: dict, got: dict, rtol: float, atol: float, label: str
) -> tuple[float, list[str]]:
    """Compare two ``{element_name: value}`` maps. Returns (max_tol_frac,
    problems). Every reference element must be present and within tolerance."""
    ref_n = _norm_map(ref)
    got_n = _norm_map(got)
    problems: list[str] = []
    # Report the max "tolerance-budget fraction": |got-ref| / (atol + rtol*|ref|).
    # A value < 1 means every element is within tolerance; it makes the margin
    # legible (0.03 == used 3% of the budget) without the near-zero-denominator
    # inflation a plain relative delta suffers for small-magnitude cells.
    worst = 0.0
    for name, rv in ref_n.items():
        if name not in got_n:
            problems.append(f"{label}: missing element {name!r}")
            continue
        gv = got_n[name]
        budget = atol + rtol * abs(rv)
        if budget > 0:
            worst = max(worst, abs(gv - rv) / budget)
        elif gv != rv:
            worst = float("inf")
        if not _close(gv, rv, rtol, atol):
            problems.append(f"{label}: {name} = {gv!r} != {rv!r} (atol={atol:g} rtol={rtol:g})")
    return worst, problems


def compare_against(
    fixture: dict, produced: dict, reference: dict, tol: dict, *, kind: str
) -> dict:
    """Compare one binding's produced {rhs, trajectory} for a fixture against a
    reference (the Julia golden, or the analytic anchors). ``kind`` selects the
    trajectory tolerance band ('golden' or 'analytic')."""
    problems: list[str] = []
    worst = 0.0
    # --- RHS (always the tight arithmetic tolerance) ---
    ref_rhs = reference.get("rhs", {})
    got_rhs = produced.get("rhs", {})
    for probe_id, ref_vec in ref_rhs.items():
        if probe_id not in got_rhs:
            problems.append(f"rhs: missing probe {probe_id!r}")
            continue
        w, p = compare_state(
            ref_vec, got_rhs[probe_id], tol["rhs_rtol"], tol["rhs_atol"], f"rhs[{probe_id}]"
        )
        worst = max(worst, w)
        problems += p
    # --- Trajectory ---
    if kind == "golden":
        tr_rtol, tr_atol = tol["traj_golden_rtol"], tol["traj_golden_atol"]
    else:
        tr_rtol, tr_atol = tol["traj_analytic_rtol"], tol["traj_analytic_atol"]
    ref_tr = {_time_key(k): v for k, v in reference.get("trajectory", {}).items()}
    got_tr = {_time_key(k): v for k, v in produced.get("trajectory", {}).items()}
    for tkey, ref_vec in ref_tr.items():
        if tkey not in got_tr:
            problems.append(f"trajectory: missing output time {tkey!r}")
            continue
        w, p = compare_state(ref_vec, got_tr[tkey], tr_rtol, tr_atol, f"traj[t={tkey}]")
        worst = max(worst, w)
        problems += p
    return {"match": not problems, "problems": problems, "max_tol_frac": worst}


def _analytic_reference(fixture: dict, manifest_path: Path) -> dict:
    """Build the {rhs, trajectory} reference from the fixture's INDEPENDENT
    analytic anchors.

    RHS: the per-probe ``analytic_rhs`` — ``L u + b`` for the linear
    ``pde_simulation`` category, or the independent reference integrator's
    ``f(u, t)`` for the nonlinear ``pde_simulation_pipeline`` category (§5).

    Trajectory: two sanctioned modes (DESIGN.md §6). A linear fixture carries an
    in-manifest matrix-exponential ``trajectory.analytic``. A pipeline fixture is
    nonlinear (no matrix exponential exists), so it instead points
    ``trajectory.reference`` at an external JSON file produced by the independent
    reference integrator; its ``trajectory.reference`` block is the checkpoint
    anchor (compared under the looser ``traj_analytic`` band, which absorbs
    integrator differences). Absent ``trajectory.analytic`` is tolerated whenever
    ``trajectory.reference`` is present."""
    rhs = {pr["id"]: pr["analytic_rhs"] for pr in fixture["rhs_probes"]}
    tr = fixture.get("trajectory", {})
    ref_ptr = tr.get("reference")
    if isinstance(ref_ptr, str):
        ref_path = manifest_path.parent / ref_ptr
        try:
            with ref_path.open() as f:
                ref_doc = json.load(f)
        except (OSError, json.JSONDecodeError) as e:
            raise ManifestError(f"trajectory.reference {ref_ptr!r} could not be loaded: {e}") from e
        raw_traj = ref_doc.get("trajectory", {}).get("reference", {})
        traj = {_time_key(k): v for k, v in raw_traj.items()}
    else:
        traj = {_time_key(k): v for k, v in tr.get("analytic", {}).items()}
    return {"rhs": rhs, "trajectory": traj}


# === Golden I/O ===========================================================


def load_golden(fixture: dict, manifest_path: Path) -> dict | None:
    gpath = manifest_path.parent / fixture["golden"]
    if not gpath.is_file():
        return None
    try:
        with gpath.open() as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return None


# === Self-test (golden vs independent analytic anchors) ===================


def self_test(manifest_path: Path) -> int:
    try:
        manifest = load_manifest(manifest_path)
    except ManifestError as e:
        _eprint(f"self-test: {e}")
        return 1
    tol = {**DEFAULT_TOLERANCES, **manifest.get("tolerances", {})}
    rc = 0
    fixtures = manifest["fixtures"]
    for fx in fixtures:
        golden = load_golden(fx, manifest_path)
        if golden is None:
            rc = 1
            _eprint(
                f"self-test FAIL [{fx['id']}]: golden missing "
                f"({fx['golden']}); run --write-golden first"
            )
            continue
        analytic = _analytic_reference(fx, manifest_path)
        verdict = compare_against(fx, golden, analytic, tol, kind="analytic")
        if not verdict["match"]:
            rc = 1
            _eprint(
                f"self-test FAIL [{fx['id']}]: Julia golden disagrees with "
                "independent analytic anchors"
            )
            for p in verdict["problems"][:12]:
                _eprint(f"    {p}")
        else:
            print(
                f"self-test OK   [{fx['id']}]: golden == analytic "
                f"(tol-frac {verdict['max_tol_frac']:.2f}x)"
            )

    # Negative controls — the harness MUST reject perturbed output.
    ref_fx = fixtures[0]
    golden = load_golden(ref_fx, manifest_path)
    if golden is not None:
        analytic = _analytic_reference(ref_fx, manifest_path)
        # NC1: perturb one RHS element well past the tight tolerance.
        probe0 = ref_fx["rhs_probes"][0]["id"]
        bad = json.loads(json.dumps(golden))
        any_el = next(iter(bad["rhs"][probe0]))
        bad["rhs"][probe0][any_el] = float(bad["rhs"][probe0][any_el]) + 1.0
        if compare_against(ref_fx, bad, analytic, tol, kind="analytic")["match"]:
            rc = 1
            _eprint(
                "self-test FAIL [neg/rhs_off]: harness accepted an RHS "
                "element 1.0 out of tolerance (it must reject)"
            )
        else:
            print("self-test OK   [neg/rhs_off]: out-of-tolerance RHS rejected")
        # NC2: perturb one trajectory element past the analytic band.
        bad2 = json.loads(json.dumps(golden))
        tkey = next(iter(bad2["trajectory"]))
        el = next(iter(bad2["trajectory"][tkey]))
        bad2["trajectory"][tkey][el] = float(bad2["trajectory"][tkey][el]) + 1.0
        if compare_against(ref_fx, bad2, analytic, tol, kind="analytic")["match"]:
            rc = 1
            _eprint(
                "self-test FAIL [neg/traj_off]: harness accepted a trajectory "
                "element 1.0 out of tolerance (it must reject)"
            )
        else:
            print("self-test OK   [neg/traj_off]: out-of-tolerance trajectory rejected")
        # NC3: a missing element must be rejected.
        bad3 = json.loads(json.dumps(golden))
        bad3["rhs"][probe0].pop(any_el)
        if compare_against(ref_fx, bad3, analytic, tol, kind="analytic")["match"]:
            rc = 1
            _eprint(
                "self-test FAIL [neg/missing]: harness accepted output missing "
                "an element (it must reject)"
            )
        else:
            print("self-test OK   [neg/missing]: missing element rejected")

    print("\nself-test:", "OK" if rc == 0 else "FAILED")
    return rc


# === Golden writer (reference binding only) ===============================


def write_golden(manifest_path: Path, timeout: float | None) -> int:
    manifest = load_manifest(manifest_path)
    ref = manifest.get("reference_binding", "julia")
    argv = _ADAPTERS.discover(ref)
    if argv is None:
        _eprint(
            f"--write-golden: reference adapter for {ref!r} not registered "
            f"(set $EARTHSCI_PDE_SIM_ADAPTER_{ref.upper()})"
        )
        return 2
    payload = _ADAPTERS.run(ref, argv, manifest_path, timeout)
    if payload.get("adapter_status") != "ok":
        _eprint(
            f"--write-golden: reference adapter failed: "
            f"{payload.get('adapter_status')} {payload.get('error')}"
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
        # Normalize element names to bare form so the golden is binding-neutral.
        record = {
            "fixture": fx["id"],
            "reference_binding": ref,
            "rhs": {pid: _norm_map(vec) for pid, vec in produced.get("rhs", {}).items()},
            "trajectory": {
                _time_key(k): _norm_map(v) for k, v in produced.get("trajectory", {}).items()
            },
        }
        gpath = manifest_path.parent / fx["golden"]
        gpath.parent.mkdir(parents=True, exist_ok=True)
        gpath.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
        written += 1
        print(f"wrote golden {gpath.relative_to(REPO_ROOT)}")
    print(f"--write-golden: wrote {written} golden file(s) from {ref}")
    return 0


# === Producer run mode ====================================================


def run_suite(
    manifest_path: Path, bindings: list[str], output_path: Path, timeout: float | None
) -> int:
    manifest = load_manifest(manifest_path)
    tol = {**DEFAULT_TOLERANCES, **manifest.get("tolerances", {})}
    reference_binding = manifest.get("reference_binding", "julia")
    if not bindings:
        bindings = list(manifest.get("bindings_required") or [])
    for b in bindings:
        if b not in KNOWN_BINDINGS:
            _eprint(f"error: unknown binding {b!r}; known: {KNOWN_BINDINGS}")
            return 2
    required = set(manifest.get("bindings_required") or [])
    fixtures = manifest["fixtures"]

    # Goldens must exist (they are the cross-binding reference).
    goldens = {fx["id"]: load_golden(fx, manifest_path) for fx in fixtures}
    missing_golden = [fid for fid, g in goldens.items() if g is None]
    if missing_golden:
        _eprint(f"error: golden(s) missing: {missing_golden}; run --write-golden")
        return 2

    def compare_fixture(binding: str, fx: dict, produced: dict) -> dict:
        v_golden = compare_against(fx, produced, goldens[fx["id"]], tol, kind="golden")
        v_analytic = compare_against(
            fx, produced, _analytic_reference(fx, manifest_path), tol, kind="analytic"
        )
        match = v_golden["match"] and v_analytic["match"]
        return {
            "status": "ok" if match else "mismatch",
            "tol_frac_vs_golden": v_golden["max_tol_frac"],
            "tol_frac_vs_analytic": v_analytic["max_tol_frac"],
            "problems": v_golden["problems"] + v_analytic["problems"],
        }

    # No no_producers_message: unlike determinism/cadence, an unregistered
    # required simulator is always a fail here (Julia/Python/Rust are all
    # required), so overall_ok alone decides ok/fail. attach_stderr keeps the
    # solver diagnostics for a broken adapter.
    return run_producer_suite(
        harness=_ADAPTERS,
        bindings=bindings,
        required=required,
        fixtures=fixtures,
        manifest_path=manifest_path,
        output_path=output_path,
        timeout=timeout,
        compare_fixture=compare_fixture,
        print_report=lambda r: _print_summary(r, reference_binding),
        attach_stderr=True,
    )


def _print_summary(report: dict, reference_binding: str) -> None:
    print("=== PDE-Simulation Conformance Report ===")
    print(f"manifest:  {report['manifest_path']}")
    print(f"reference: {reference_binding}")
    print(f"status:    {report['status'].upper()}")
    for b, br in report.get("bindings", {}).items():
        print(f"  {b:>10}  {str(br.get('status')).upper():8} ({br.get('adapter_status')})")
        for fid, fr in br.get("fixtures", {}).items():
            st = fr.get("status")
            if st == "ok":
                print(
                    f"      ok   {fid:30s} "
                    f"golden={fr.get('tol_frac_vs_golden', 0):.2f}x "
                    f"analytic={fr.get('tol_frac_vs_analytic', 0):.2f}x "
                    f"(tol-frac, <1=pass)"
                )
            else:
                print(f"      FAIL {fid}: {st}")
                for p in (fr.get("problems") or [])[:6]:
                    print(f"           {p}")
        if br.get("error"):
            print(f"      error: {br['error']}")
        if br.get("stderr"):
            print(f"      stderr (tail): {br['stderr'][-600:]}")


# === CLI ==================================================================


def parse_args(argv: list[str]):
    p = build_parser(
        doc=__doc__,
        default_manifest=DEFAULT_MANIFEST,
        default_output=Path("conformance-results/pde_simulation/report.json"),
        output_help=None,
        bindings_help="Comma-separated bindings (default: manifest bindings_required).",
        timeout_help=None,
        self_test_help="Assert the golden reproduces the analytic anchors, then exit.",
    )
    p.add_argument(
        "--write-golden",
        action="store_true",
        help="Run only the reference adapter and (re)write golden/*.json.",
    )
    return p.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    return cli_main(
        argv,
        parse_args=parse_args,
        self_test=self_test,
        run_suite=run_suite,
        # Historical dispatch order: manifest existence is checked before
        # --self-test / --write-golden, so a missing manifest always exits 2.
        manifest_check_first=True,
        extra_mode=lambda args: (
            write_golden(args.manifest, args.timeout) if args.write_golden else None
        ),
    )


if __name__ == "__main__":
    sys.exit(main())
