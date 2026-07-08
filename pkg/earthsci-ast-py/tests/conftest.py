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
