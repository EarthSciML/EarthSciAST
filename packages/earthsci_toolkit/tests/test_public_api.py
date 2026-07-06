"""Public-API integrity tests.

Guards against the failure mode where an exported name silently breaks or
disappears: every ``__all__`` entry must resolve, and the display entry
points must work on a real, non-empty ``EsmFile`` (not just on dicts or
empty files, which is how earlier breakage went unnoticed).
"""

from pathlib import Path

import earthsci_toolkit
from earthsci_toolkit import load, to_ascii, to_latex, to_unicode

_REPO_ROOT = Path(__file__).resolve().parents[3]
_FIXTURE = _REPO_ROOT / "tests" / "valid" / "events_all_types.esm"


def test_all_exports_resolve():
    """Every name in __all__ must actually exist on the package."""
    missing = [n for n in earthsci_toolkit.__all__ if not hasattr(earthsci_toolkit, n)]
    assert not missing, f"__all__ names missing from package: {missing}"


def test_display_formats_on_real_file():
    """to_unicode/to_latex/to_ascii must render a real non-empty EsmFile."""
    esm_file = load(_FIXTURE.read_text())
    assert esm_file.models or esm_file.reaction_systems
    for fmt in (to_unicode, to_latex, to_ascii):
        rendered = fmt(esm_file)
        assert isinstance(rendered, str) and rendered


def test_repr_latex_on_real_file():
    """The _repr_latex_ hook patched onto EsmFile must work on real files."""
    esm_file = load(_FIXTURE.read_text())
    assert esm_file._repr_latex_()
