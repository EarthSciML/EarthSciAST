"""Range-restricted right-hand sides in Python (CONFORMANCE_SPEC §5.49).

Python has no native tile or lane implementation: every entry point of API_SPEC
§5.8 "Range-restricted right-hand sides" exists and raises
``compiler_unavailable``, naming the call. The suite's manifest says so in its
``scope_excluded`` entry; this test is what keeps that entry honest.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

import earthsci_ast as esa
from earthsci_ast.error_handling import COMPILER_UNAVAILABLE

SUITE = Path(__file__).resolve().parents[3] / "tests" / "conformance" / "range_restricted_rhs"


def _first_case() -> dict:
    manifest = json.loads((SUITE / "manifest.json").read_text())
    assert "python" in manifest["scope_excluded"]
    return manifest["cases"][0]


@pytest.fixture(scope="module")
def prob():
    case = _first_case()
    return esa.esm_problem(
        str(SUITE / case["document"]),
        (0.0, 1.0),
        metaparameters=case.get("metaparameters") or {},
    )


@pytest.mark.parametrize(
    ("name", "call"),
    [
        ("rhs_program", lambda p: esa.rhs_program(p)),
        ("select", lambda p: esa.select(p, writes="all", terms="all")),
        ("halo", lambda p: esa.halo(p, None)),
        ("restrict", lambda p: esa.restrict(p, None, owned={}, storage={})),
        ("lanes", lambda p: esa.lanes(p, "cells", ["x"])),
    ],
)
def test_entry_point_raises_compiler_unavailable(prob, name, call):
    with pytest.raises(esa.CompilerUnavailableError) as info:
        call(prob)
    assert info.value.code == COMPILER_UNAVAILABLE
    assert f"`{name}`" in str(info.value)
