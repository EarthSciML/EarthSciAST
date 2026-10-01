"""The Python adapter for the ``compiler_agreement`` conformance tier.

The tier itself cannot gate this adapter yet: ``golden/`` is empty until the
Julia ``interpreter`` mints it, and until then the runner exits 2 without ever
asking a producer for a number. So the parts that do not need a reference are
pinned here, against the tier's REAL manifest — the contract's own fixtures, so
a fixture added there is exercised by this file the day it lands.

What is checked:

  * ``native`` and ``interpreter`` agree BIT-for-bit on every fixture they both
    run. That is this tier's own axis, and the one no cross-binding comparison
    covers: every binding's ``native`` could be wrong the same way, but one
    binding's two compilers cannot be wrong the same way by accident;
  * the save times are the manifest's ``saveat`` for a ``from: manifest``
    fixture and the named inline test's ASSERTION TIMES for a
    ``from: inline_tests`` one — the adapter does not choose them;
  * all five outcome shapes: ``ok``, ``refused`` (``sympy`` on an array
    document, naming the rule), whole-output ``unavailable`` (``xla`` / ``mtk``),
    a per-fixture ``error``, and the non-zero exit that must still carry a
    parsable report;
  * the module's end-to-end command line, which is how the runner invokes it.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest
from conftest import CONFORMANCE_DIR

from earthsci_ast.cli.compiler_agreement_adapter import (
    fixture_run,
    run_manifest,
    tests_dir_for,
)

SRC_DIR = Path(__file__).resolve().parents[1] / "src"
MANIFEST_PATH = CONFORMANCE_DIR / "compiler_agreement" / "manifest.json"


@pytest.fixture(scope="module")
def manifest() -> dict:
    return json.loads(MANIFEST_PATH.read_text())


@pytest.fixture(scope="module")
def payloads(manifest) -> dict[str, dict]:
    """One adapter payload per compiler Python answers for. Module-scoped: each
    build is a real solve of every fixture, and nothing below mutates them."""
    return {c: run_manifest(manifest, MANIFEST_PATH, c) for c in ("interpreter", "native", "sympy")}


def _ok(payload: dict) -> dict[str, dict]:
    return {k: v for k, v in payload["fixtures"].items() if "state" in v}


def test_the_envelope_answers_for_the_compiler_it_was_given(payloads) -> None:
    """Answering for a DIFFERENT compiler is a broken adapter, and the runner
    files the verdict under the name in the payload."""
    for name, payload in payloads.items():
        assert payload["binding"] == "python"
        assert payload["compiler"] == name


def test_every_fixture_gets_an_entry(manifest, payloads) -> None:
    """A fixture the adapter omits is a failure, not a way to skip one."""
    ids = {f["id"] for f in manifest["fixtures"]}
    for payload in payloads.values():
        assert set(payload["fixtures"]) == ids


def test_native_and_interpreter_agree_bitwise(payloads) -> None:
    """The tier's own axis. Not "within tolerance": the two compilers evaluate
    the same arithmetic on the same document, so a difference of one bit is a
    difference worth seeing, and there is no integrator error between them to
    excuse one."""
    interp, native = _ok(payloads["interpreter"]), _ok(payloads["native"])
    assert set(interp) == set(native)
    assert interp  # a green comparison over an empty set would prove nothing
    for fid in interp:
        assert native[fid]["state_order"] == interp[fid]["state_order"], fid
        assert native[fid]["state"] == interp[fid]["state"], fid
        assert native[fid]["observed"] == interp[fid]["observed"], fid


def test_save_times_come_from_the_fixture_not_the_adapter(manifest, payloads) -> None:
    """The manifest's ``saveat`` for a ``from: manifest`` fixture; the named
    inline test's assertion times for a ``from: inline_tests`` one. Both read
    the way the runner reads them, so a golden and the row compared against it
    describe the same run."""
    tests_dir = tests_dir_for(MANIFEST_PATH)
    produced = _ok(payloads["interpreter"])
    for fixture in manifest["fixtures"]:
        if fixture["id"] not in produced:
            continue
        doc = json.loads((tests_dir / fixture["path"]).read_text())
        _u0, _p, _tspan, saveat = fixture_run(fixture, doc)
        got = sorted(float(k) for k in produced[fixture["id"]]["state"])
        assert got == sorted(saveat), fixture["id"]

    # And the two sources really are different, so the check above is not one
    # branch tested twice.
    sources = {f["trajectory"]["from"] for f in manifest["fixtures"]}
    assert sources == {"manifest", "inline_tests"}


def test_every_row_names_every_element(payloads) -> None:
    for payload in payloads.values():
        for fid, rec in _ok(payload).items():
            order = rec["state_order"]
            assert order and len(set(order)) == len(order), fid
            for t, row in rec["state"].items():
                assert set(row) == set(order), (fid, t)
                assert all(isinstance(v, float) for v in row.values()), (fid, t)


def test_sympy_refuses_an_array_document_by_name(payloads) -> None:
    """A refusal names the rule and the reason, and the run CONTINUES: the
    point of the tier is the list of what each compiler could not run, which
    one abort would throw away."""
    refused = {k: v for k, v in payloads["sympy"]["fixtures"].items() if v.get("status")}
    assert set(refused) == {
        "diffusion_1d_dirichlet_n4",
        "diffusion_2d_dirichlet_n3",
        "advection_1d_periodic_n4",
        "faq_discretized_1d_heat",
    }
    for fid, rec in refused.items():
        assert rec["status"] == "refused"
        assert rec["rule"] and "u" in rec["rule"], fid
        assert "SCALAR" in rec["reason"], fid
    # The scalar fixtures still run, and on the same numbers.
    assert set(_ok(payloads["sympy"])) == {"logistic_growth", "decay_solver_block"}
    for fid, rec in _ok(payloads["sympy"]).items():
        assert rec["state"] == _ok(payloads["interpreter"])[fid]["state"], fid


def test_a_refusal_is_not_an_error(payloads) -> None:
    """The two are different facts and the runner gates them differently — a
    named exclusion against an unconditional red — so a refusal must never be
    written as an ``error`` entry."""
    for rec in payloads["sympy"]["fixtures"].values():
        assert "error" not in rec


@pytest.mark.parametrize("compiler", ["xla", "mtk"])
def test_an_unprovided_compiler_is_unavailable_for_the_whole_output(manifest, compiler) -> None:
    """``unavailable`` carries NO ``fixtures`` map — the runner classifies it
    locally so the reason survives — and the reason names what would have to
    exist, not a machine's configuration."""
    payload = run_manifest(manifest, MANIFEST_PATH, compiler)
    assert payload["status"] == "unavailable"
    assert "fixtures" not in payload
    assert payload["compiler"] == compiler
    assert "compiler_unavailable" in payload["reason"]


def test_a_value_outside_the_vocabulary_is_answered_not_crashed(manifest) -> None:
    """The report has no shape for ``compiler_unknown``, and an adapter that
    died on one would read as BROKEN — red for every binding — rather than as
    the binding declining to answer. It answers, with the reason."""
    payload = run_manifest(manifest, MANIFEST_PATH, "nosuchcompiler")
    assert payload["status"] == "unavailable"
    assert "compiler_unknown" in payload["reason"]


def test_a_broken_fixture_is_one_error_entry() -> None:
    """A fixture whose load throws becomes an ``error`` naming the exception,
    and the others still run — the whole point of recording per fixture."""
    manifest = json.loads(MANIFEST_PATH.read_text())
    good = manifest["fixtures"][0]
    manifest["fixtures"] = [{**good, "id": "missing", "path": "no/such/document.esm"}, good]
    payload = run_manifest(manifest, MANIFEST_PATH, "interpreter")
    assert "error" in payload["fixtures"]["missing"]
    assert "state" in payload["fixtures"][good["id"]]


def test_command_line_writes_the_report_and_exits_nonzero_on_an_error(tmp_path) -> None:
    """The invocation the runner uses. A non-zero exit WITH a parsable report
    is allowed and means at least one fixture errored; the report is what the
    runner reads, so it must be written before the exit."""
    manifest = json.loads(MANIFEST_PATH.read_text())
    manifest["fixtures"] = [{**manifest["fixtures"][0], "id": "missing", "path": "nope.esm"}]
    broken = tmp_path / "manifest.json"
    broken.write_text(json.dumps(manifest))
    out = tmp_path / "out.json"
    env = {**os.environ, "PYTHONPATH": str(SRC_DIR)}
    proc = subprocess.run(
        [
            sys.executable,
            "-m",
            "earthsci_ast.cli.compiler_agreement_adapter",
            "--manifest",
            str(broken),
            "--output",
            str(out),
            "--compiler",
            "interpreter",
        ],
        capture_output=True,
        text=True,
        env=env,
    )
    assert proc.returncode == 1, proc.stderr
    payload = json.loads(out.read_text())
    assert "error" in payload["fixtures"]["missing"]


def test_the_compiler_argument_is_required() -> None:
    """One adapter binary serves every compiler, and it must never guess which
    one it was asked for: a default would file a verdict under a name nobody
    chose."""
    env = {**os.environ, "PYTHONPATH": str(SRC_DIR)}
    proc = subprocess.run(
        [
            sys.executable,
            "-m",
            "earthsci_ast.cli.compiler_agreement_adapter",
            "--manifest",
            str(MANIFEST_PATH),
            "--output",
            "/dev/null",
        ],
        capture_output=True,
        text=True,
        env=env,
    )
    assert proc.returncode != 0
    assert "--compiler" in proc.stderr
