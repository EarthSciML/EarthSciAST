"""The Python adapter for the ``compiled_rhs`` conformance tier.

The tier's own manifest is owned by the harness, so this module builds an
equivalent one (same schema, real fixtures referenced by path relative to the
repository ``tests/`` directory) and checks the adapter against anchors that
were computed WITHOUT any binding:

  * ``diffusion_1d_dirichlet_n4`` and ``advection_1d_periodic_n4`` carry the
    ``analytic_rhs`` anchors already written in
    ``tests/conformance/pde_simulation/manifest.json`` (operator-matrix values,
    not a binding's output);
  * ``elementwise_gather`` has a state-INDEPENDENT right-hand side: its
    ``zc = [0,1,2,3]`` gives ``f = 1 + cos(pi*zc) = [2,0,2,0]``, the prefix sum
    ``colsum[i] = sum_{j<=i} f[j] = [2,2,4,4]`` drives ``u``, and the full sum
    ``total = 4`` drives ``s`` -- so ``du = [2,2,4,4,4]`` at every probe state,
    which is why two probes with different states share one anchor.

Also pinned here: the ``--engine compiled`` answer (Python has no compiled
backend, so the whole output is the contract's ``unavailable`` form), the
``state_order`` projection, and the module's end-to-end command line.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest
from conftest import CONFORMANCE_DIR, REPO_ROOT

from earthsci_ast.cli.compiled_rhs_adapter import (
    COMPILED_UNAVAILABLE_REASON,
    run_manifest,
    tests_dir_for,
)

SRC_DIR = Path(__file__).resolve().parents[1] / "src"

#: Tolerance for every element against its analytic anchor.
RTOL = 1e-12

#: A manifest in the tier's schema (tests/conformance/compiled_rhs/README.md).
#: ``path`` is relative to the repository ``tests/`` directory.
MANIFEST = {
    "category": "compiled_rhs",
    "version": "1.0",
    "reference_binding": "julia",
    "engines": {
        "interpreter": {"bindings_required": ["julia", "rust", "python"]},
        "compiled": {"bindings_required": [], "bindings_optional": ["julia", "rust"]},
    },
    "tolerance_classes": {"algebraic": {"rtol": 1e-13, "atol": 1e-300}},
    "excluded": [],
    "fixtures": [
        {
            "id": "diffusion_1d_dirichlet_n4",
            "path": "conformance/pde_simulation/fixtures/diffusion_1d_dirichlet_n4.esm",
            "model": "Diff1D",
            "tolerance_class": "algebraic",
            "compiled_required": [],
            "state_order": ["u[1]", "u[2]", "u[3]", "u[4]"],
            "parameters": {},
            "rhs_probes": [
                {
                    "id": "const1",
                    "t": 0.0,
                    "state": {"u[1]": 1.0, "u[2]": 1.0, "u[3]": 1.0, "u[4]": 1.0},
                    "analytic_rhs": {
                        "u[1]": -24.999999999999996,
                        "u[2]": 0.0,
                        "u[3]": 0.0,
                        "u[4]": -24.999999999999996,
                    },
                },
                {
                    "id": "ramp",
                    "t": 0.0,
                    "state": {"u[1]": 1.0, "u[2]": 2.0, "u[3]": 3.0, "u[4]": 4.0},
                    "analytic_rhs": {
                        "u[1]": 0.0,
                        "u[2]": 0.0,
                        "u[3]": 0.0,
                        "u[4]": -124.99999999999999,
                    },
                },
                {
                    "id": "ic",
                    "t": 0.0,
                    "state": {
                        "u[1]": 0.8377852522924731,
                        "u[2]": 1.2010565162951536,
                        "u[3]": 1.2010565162951536,
                        "u[4]": 0.8377852522924732,
                    },
                    "analytic_rhs": {
                        "u[1]": -11.862849707244816,
                        "u[2]": -9.08178160006701,
                        "u[3]": -9.08178160006701,
                        "u[4]": -11.862849707244816,
                    },
                },
            ],
        },
        {
            "id": "advection_1d_periodic_n4",
            "path": "conformance/pde_simulation/fixtures/advection_1d_periodic_n4.esm",
            "model": "Advect1D",
            "tolerance_class": "algebraic",
            "compiled_required": [],
            "state_order": ["u[1]", "u[2]", "u[3]", "u[4]"],
            "parameters": {},
            "rhs_probes": [
                {
                    "id": "const1",
                    "t": 0.0,
                    "state": {"u[1]": 1.0, "u[2]": 1.0, "u[3]": 1.0, "u[4]": 1.0},
                    "analytic_rhs": {"u[1]": 0.0, "u[2]": 0.0, "u[3]": 0.0, "u[4]": 0.0},
                },
                {
                    "id": "ramp",
                    "t": 0.0,
                    "state": {"u[1]": 1.0, "u[2]": 2.0, "u[3]": 3.0, "u[4]": 4.0},
                    "analytic_rhs": {"u[1]": 12.0, "u[2]": -4.0, "u[3]": -4.0, "u[4]": -4.0},
                },
                {
                    "id": "ic",
                    "t": 0.0,
                    "state": {
                        "u[1]": 1.5,
                        "u[2]": 1.0,
                        "u[3]": 0.5,
                        "u[4]": 0.9999999999999999,
                    },
                    "analytic_rhs": {
                        "u[1]": -2.0000000000000004,
                        "u[2]": 2.0,
                        "u[3]": 2.0,
                        "u[4]": -1.9999999999999996,
                    },
                },
            ],
        },
        {
            "id": "elementwise_gather",
            "path": "conformance/elementwise_observed_gather/fixtures/elementwise_gather.esm",
            "model": "Column",
            "tolerance_class": "transcendental",
            "compiled_required": [],
            "state_order": ["u[1]", "u[2]", "u[3]", "u[4]", "s"],
            "parameters": {},
            "rhs_probes": [
                {
                    "id": "zeros",
                    "t": 0.0,
                    "state": {"u[1]": 0.0, "u[2]": 0.0, "u[3]": 0.0, "u[4]": 0.0, "s": 0.0},
                    # State-independent RHS: colsum = prefix-sum of 1+cos(pi*zc).
                    "analytic_rhs": {
                        "u[1]": 2.0,
                        "u[2]": 2.0,
                        "u[3]": 4.0,
                        "u[4]": 4.0,
                        "s": 4.0,
                    },
                },
                {
                    "id": "ramp",
                    "t": 0.5,
                    "state": {"u[1]": 1.0, "u[2]": 2.0, "u[3]": 3.0, "u[4]": 4.0, "s": 5.0},
                    # Same anchor as `zeros`: nothing in this RHS reads the state.
                    "analytic_rhs": {
                        "u[1]": 2.0,
                        "u[2]": 2.0,
                        "u[3]": 4.0,
                        "u[4]": 4.0,
                        "s": 4.0,
                    },
                },
            ],
        },
    ],
}


@pytest.fixture()
def manifest_path(tmp_path: Path) -> Path:
    """The manifest written inside a stand-in ``tests/`` tree.

    Fixture paths are relative to the repository ``tests/`` directory, which the
    adapter finds by walking up from the manifest -- so the temporary tree needs
    a directory literally named ``tests`` with the real ``conformance/`` subtree
    reachable under it. A symlink gives that without copying fixtures or writing
    anywhere in the repository."""
    tests_root = tmp_path / "tests"
    tests_root.mkdir()
    (tests_root / "conformance").symlink_to(CONFORMANCE_DIR, target_is_directory=True)
    path = tests_root / "compiled_rhs_manifest.json"
    path.write_text(json.dumps(MANIFEST, indent=2) + "\n")
    return path


def _assert_matches_anchors(payload: dict) -> int:
    """Every element of every probe within RTOL of its analytic anchor.
    Returns how many elements were checked, so a silently empty run fails."""
    checked = 0
    for fixture in MANIFEST["fixtures"]:
        record = payload["fixtures"][fixture["id"]]
        assert "error" not in record, f"{fixture['id']}: {record.get('error')}"
        for probe in fixture["rhs_probes"]:
            got = record["rhs"][probe["id"]]
            # Key ORDER is not part of the contract (the adapter writes its
            # JSON sorted); the element SET is.
            assert set(got) == set(fixture["state_order"]), (
                f"{fixture['id']}/{probe['id']}: element set is {sorted(got)}, "
                f"expected exactly state_order {fixture['state_order']}"
            )
            for name, want in probe["analytic_rhs"].items():
                assert abs(got[name] - want) <= RTOL * abs(want), (
                    f"{fixture['id']}/{probe['id']}/{name}: got {got[name]!r}, anchor {want!r}"
                )
                checked += 1
    return checked


def test_interpreter_engine_matches_analytic_anchors(manifest_path: Path):
    """The core function, called directly: the interpreter RHS reproduces every
    binding-independent anchor to 1e-12 relative."""
    payload = run_manifest(MANIFEST, manifest_path, "interpreter")
    assert payload["binding"] == "python"
    assert payload["engine"] == "interpreter"
    assert set(payload["fixtures"]) == {f["id"] for f in MANIFEST["fixtures"]}
    assert _assert_matches_anchors(payload) == 34


def test_engine_defaults_to_interpreter(manifest_path: Path):
    assert run_manifest(MANIFEST, manifest_path) == run_manifest(
        MANIFEST, manifest_path, "interpreter"
    )


def test_state_order_projects_away_uncompared_elements(manifest_path: Path):
    """`diffusion_1d_dirichlet_n4` declares `u` over an index range the fixture
    never bounds, so the interpreter's flat layout carries a `u[5]` the tier
    does not compare. The adapter emits exactly `state_order`, so that element
    never reaches the runner as an invented entry."""
    payload = run_manifest(MANIFEST, manifest_path, "interpreter")
    for probe in payload["fixtures"]["diffusion_1d_dirichlet_n4"]["rhs"].values():
        assert "u[5]" not in probe


def test_compiled_engine_is_unavailable(manifest_path: Path):
    """Python has no compiled backend: the WHOLE output is the `unavailable`
    form with a named reason, never a per-fixture skip or a silent pass."""
    payload = run_manifest(MANIFEST, manifest_path, "compiled")
    assert payload == {
        "binding": "python",
        "engine": "compiled",
        "status": "unavailable",
        "reason": COMPILED_UNAVAILABLE_REASON,
    }
    assert "fixtures" not in payload


def test_missing_probe_element_is_a_named_error(manifest_path: Path):
    """A probe that omits a `state_order` element is a manifest defect: it is
    reported per fixture rather than defaulted to zero behind the runner."""
    broken = json.loads(json.dumps(MANIFEST))
    del broken["fixtures"][0]["rhs_probes"][0]["state"]["u[2]"]
    payload = run_manifest(broken, manifest_path, "interpreter")
    record = payload["fixtures"]["diffusion_1d_dirichlet_n4"]
    assert "error" in record and "u[2]" in record["error"]


def test_tests_dir_resolution_from_the_real_manifest_location():
    """The tier's own manifest resolves fixture paths against the repository
    `tests/` directory."""
    real = CONFORMANCE_DIR / "compiled_rhs" / "manifest.json"
    assert tests_dir_for(real) == (REPO_ROOT / "tests").resolve()


def test_module_end_to_end(manifest_path: Path, tmp_path: Path):
    """`python3 -m earthsci_ast.cli.compiled_rhs_adapter` -- the invocation the
    conformance harness uses -- for both engines."""
    env = dict(os.environ)
    env["PYTHONPATH"] = os.pathsep.join([str(SRC_DIR), env.get("PYTHONPATH", "")]).rstrip(
        os.pathsep
    )
    module = "earthsci_ast.cli.compiled_rhs_adapter"

    out = tmp_path / "out" / "python_interpreter.json"
    proc = subprocess.run(
        [sys.executable, "-m", module, "--manifest", str(manifest_path), "--output", str(out)],
        cwd=str(REPO_ROOT),
        env=env,
        capture_output=True,
        text=True,
    )
    assert proc.returncode == 0, f"adapter failed:\n{proc.stdout}\n{proc.stderr}"
    _assert_matches_anchors(json.loads(out.read_text()))

    compiled_out = tmp_path / "out" / "python_compiled.json"
    proc = subprocess.run(
        [
            sys.executable,
            "-m",
            module,
            "--manifest",
            str(manifest_path),
            "--output",
            str(compiled_out),
            "--engine",
            "compiled",
        ],
        cwd=str(REPO_ROOT),
        env=env,
        capture_output=True,
        text=True,
    )
    assert proc.returncode == 0, f"adapter failed:\n{proc.stdout}\n{proc.stderr}"
    assert json.loads(compiled_out.read_text()) == {
        "binding": "python",
        "engine": "compiled",
        "status": "unavailable",
        "reason": COMPILED_UNAVAILABLE_REASON,
    }
