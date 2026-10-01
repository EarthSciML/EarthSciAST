"""The Python adapter for the INLINE-TEST conformance tiers (CONFORMANCE_SPEC §5.45).

What is pinned here is the one outcome the runner cannot check from outside:
``unavailable`` is the WHOLE output. ``run_inline_tests`` catches a build
failure per assertion, so an adapter that waited for ``compiler_unavailable`` to
arrive as an exception never saw it, and answered every fixture as a refusal
that the runner then failed one by one without ever consulting
``bindings_required``. Both routes to the whole-output answer are covered: the
up-front question, and a run in which every assertion failed on
``compiler_unavailable`` alone.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest
from conftest import CONFORMANCE_DIR

from earthsci_ast.cli import inline_tests_adapter
from earthsci_ast.cli.inline_tests_adapter import run_manifest

SRC_DIR = Path(__file__).resolve().parents[1] / "src"
MANIFEST_PATH = CONFORMANCE_DIR / "scalar_operator_semantics" / "manifest.json"


@pytest.fixture(scope="module")
def manifest() -> dict:
    return json.loads(MANIFEST_PATH.read_text())


@pytest.mark.parametrize("compiler", ["xla", "mtk"])
def test_an_unprovided_compiler_is_unavailable_for_the_whole_output(manifest, compiler) -> None:
    payload, failed = run_manifest(manifest, MANIFEST_PATH, compiler)
    assert payload["status"] == "unavailable"
    assert payload["compiler"] == compiler
    assert "compiler_unavailable" in payload["reason"]
    assert "fixtures" not in payload
    assert failed == []


def test_a_run_that_says_unavailable_is_unavailable_for_the_whole_output(
    manifest, monkeypatch
) -> None:
    """A compiler whose absence only shows at BUILD reaches the same answer:
    every assertion failed carrying ``compiler_unavailable`` and nothing else."""
    calls = []

    def fake_run_inline_tests(*args, **kwargs):
        calls.append(kwargs["model_name"])
        return [
            SimpleNamespace(
                test_id="t",
                assertion_idx=i,
                variable="x",
                passed=False,
                actual=None,
                message="SimulationError: compiler_unavailable: no runtime here",
            )
            for i in (1, 2)
        ]

    monkeypatch.setattr(inline_tests_adapter, "run_inline_tests", fake_run_inline_tests)
    payload, failed = run_manifest(manifest, MANIFEST_PATH, "native")
    assert payload["status"] == "unavailable"
    assert "no runtime here" in payload["reason"]
    assert "fixtures" not in payload
    assert failed == []
    assert len(calls) == 1, "the remaining fixtures must not be attempted"


def test_command_line_writes_one_unavailable_answer(tmp_path) -> None:
    out = tmp_path / "out.json"
    env = {**os.environ, "PYTHONPATH": f"{SRC_DIR}{os.pathsep}{os.environ.get('PYTHONPATH', '')}"}
    proc = subprocess.run(
        [
            sys.executable,
            "-m",
            "earthsci_ast.cli.inline_tests_adapter",
            "--manifest",
            str(MANIFEST_PATH),
            "--output",
            str(out),
            "--compiler",
            "xla",
        ],
        capture_output=True,
        text=True,
        env=env,
        check=False,
    )
    assert proc.returncode == 0, proc.stderr
    payload = json.loads(out.read_text())
    assert payload["status"] == "unavailable"
    assert "fixtures" not in payload


def test_a_value_outside_the_vocabulary_is_a_broken_invocation(tmp_path) -> None:
    env = {**os.environ, "PYTHONPATH": f"{SRC_DIR}{os.pathsep}{os.environ.get('PYTHONPATH', '')}"}
    proc = subprocess.run(
        [
            sys.executable,
            "-m",
            "earthsci_ast.cli.inline_tests_adapter",
            "--manifest",
            str(MANIFEST_PATH),
            "--output",
            str(tmp_path / "out.json"),
            "--compiler",
            "bogus",
        ],
        capture_output=True,
        text=True,
        env=env,
        check=False,
    )
    assert proc.returncode == 2
    assert "compiler_unknown" in proc.stderr
    assert not (tmp_path / "out.json").exists()
