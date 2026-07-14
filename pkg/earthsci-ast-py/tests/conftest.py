"""Shared pytest configuration and fixture-loading helpers.

The cross-language ESM test fixtures live at the repository root under
``tests/`` (``tests/valid``, ``tests/invalid``, ``tests/conformance``, ...).
This module exposes the canonical paths to those directories plus a single
``load_fixture`` helper so individual test modules no longer recompute
``Path(__file__).resolve().parents[3]`` or hand-roll JSON loading.

Usage from test modules (tests/ is a package, so import via ``conftest``):

    from conftest import REPO_ROOT, VALID_DIR, load_fixture

    doc = load_fixture("valid/minimal.esm")
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Union

import pytest

# Repository root (this file lives at pkg/earthsci-ast-py/tests/).
REPO_ROOT: Path = Path(__file__).resolve().parents[3]

# Shared cross-language fixture tree at the repository root.
FIXTURES_ROOT: Path = REPO_ROOT / "tests"
VALID_DIR: Path = FIXTURES_ROOT / "valid"
INVALID_DIR: Path = FIXTURES_ROOT / "invalid"
CONFORMANCE_DIR: Path = FIXTURES_ROOT / "conformance"


# ---------------------------------------------------------------------------
# Corpus fixtures in tests/valid/ that the SHARED CORPUS is wrong about, under
# the units severity policy decided in the 2026-07-14 audit:
#
#   * a provable dimensional mismatch is a HARD ERROR;
#   * a unit string that does not denote a real unit is a HARD ERROR (the
#     declaration is false — that is a defect in the FILE);
#   * only a genuinely UNDETERMINABLE dimension stays a warning.
#
# Every binding now rejects these three files, and each rejection is CORRECT.
# The corpus is owned by a different work-stream, so this package cannot repair
# them; they are named — never glob-matched — and carry the exact defect and its
# repair, so the list cannot silently absorb an unrelated regression. Delete an
# entry the moment its fixture is repaired upstream.
# ---------------------------------------------------------------------------
CORPUS_UNIT_DEFECTS: dict[str, str] = {
    "unparseable_unit_warning.esm": (
        "declares units 'not_a_unit' and pins it as a WARNING; the decided policy "
        "makes an unreal unit string a hard error, so this fixture belongs in "
        "tests/invalid/ (repair: move it, or give the variable a real unit)"
    ),
    "events_continuous_affect_neg.esm": (
        "declares units '1/time'; 'time' is not a unit in any binding's registry "
        "(repair: '1/day' or '1/yr' — the model is a logistic population growth rate)"
    ),
    "units_dimensional_analysis.esm": (
        "computes entropy as 'n*R*log(V)' with V in m^3 — the argument of a "
        "logarithm must be dimensionless (repair: 'log(V/V0)'). The same file is "
        "pinned INVALID for ln(mass) in tests/invalid/units_invalid_logarithm.esm, "
        "so the corpus contradicts itself; the valid fixture is the wrong one"
    ),
}


def load_fixture(relative_path: Union[str, Path]) -> dict:
    """Read and JSON-parse a fixture given a path relative to REPO_ROOT/tests.

    ``relative_path`` may be a string like ``"valid/minimal.esm"`` or a Path;
    absolute paths are also accepted and read as-is.
    """
    path = Path(relative_path)
    if not path.is_absolute():
        path = FIXTURES_ROOT / path
    return json.loads(path.read_text(encoding="utf-8"))


@pytest.fixture(scope="session")
def repo_root() -> Path:
    """Session-scoped fixture exposing the repository root."""
    return REPO_ROOT
