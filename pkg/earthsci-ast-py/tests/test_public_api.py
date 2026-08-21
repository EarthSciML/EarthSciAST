"""Public-API integrity tests.

Guards against the failure mode where an exported name silently breaks or
disappears: every ``__all__`` entry must resolve, and the display entry
points must work on a real, non-empty ``EsmFile`` (not just on dicts or
empty files, which is how earlier breakage went unnoticed).

esm 1.0.0 moved two whole families of names, so both are pinned by name here:
the DERIVED classification API (which replaced the ``state`` / ``observed`` /
``brownian`` / ``discrete`` declared types), and the ``DataLoader*`` ->
``DataSource*`` rename.
"""

import pytest
from conftest import VALID_DIR

import earthsci_ast
from earthsci_ast import load, to_ascii, to_latex, to_unicode

_FIXTURE = VALID_DIR / "events_all_types.esm"

# The esm 1.0.0 classification API (esm-spec §6.3.1) — the ONE sanctioned way
# to recover the finer categories a solver needs from the two declared types.
_CLASSIFICATION_API = (
    "ode_states",
    "observed_unknowns",
    "algebraic_unknowns",
    "is_ode_state",
    "brownian_parameters",
    "discrete_parameters",
    "sampled_parameters",
    "constant_parameters",
    "system_kind",
    "declared_system_kind",
    "unknowns",
    "observed_definitions",
    "assert_partitions",
    "model_nodes",
    "ClassificationError",
)

# `data_loaders` -> `data_sources`: a source is a pure IO declaration, not a
# component, and every dataclass in the family was renamed with it.
_DATA_SOURCE_API = (
    "DataSource",
    "DataSourceKind",
    "DataSourceLocation",
    "DataSourceTemporal",
    "DataSourceBinding",
    "DataSourceDeterminism",
)

# The 1.0.0 parameter-behaviour dataclasses that replaced the removed
# `expression` / `noise_kind` / `refresh` fields and `FunctionalAffect`.
_PARAMETER_BEHAVIOUR_API = (
    "Distribution",
    "ParameterUpdate",
    "FunctionalUpdate",
)

# Names that 1.0.0 REMOVED. Re-exporting any of them would mean the rename was
# only additive and 0.x callers still silently work.
_RETIRED_NAMES = (
    "DataLoader",
    "DataLoaderKind",
    "DataLoaderSource",
    "DataLoaderTemporal",
    "DataLoaderVariable",
    "DataLoaderDeterminism",
    "DataLoaderDispatchError",
    "FunctionalAffect",
)


def test_all_exports_resolve():
    """Every name in __all__ must actually exist on the package."""
    missing = [n for n in earthsci_ast.__all__ if not hasattr(earthsci_ast, n)]
    assert not missing, f"__all__ names missing from package: {missing}"


@pytest.mark.parametrize("name", _CLASSIFICATION_API + _DATA_SOURCE_API + _PARAMETER_BEHAVIOUR_API)
def test_new_public_name_is_exported(name):
    """Each 1.0.0 name is both importable and advertised in __all__."""
    assert hasattr(earthsci_ast, name), f"{name} is not exported from earthsci_ast"
    assert name in earthsci_ast.__all__, f"{name} is missing from __all__"


@pytest.mark.parametrize("name", _RETIRED_NAMES)
def test_retired_name_is_gone(name):
    """A 0.x name must not survive as an alias."""
    assert not hasattr(earthsci_ast, name), f"{name} was retired in 1.0.0 but still resolves"
    assert name not in earthsci_ast.__all__


def test_data_sources_module_replaces_data_loaders():
    """The module moved too: ``earthsci_ast.data_sources.static_source``."""
    from earthsci_ast import data_sources

    assert hasattr(data_sources, "DataSourceDispatchError")
    assert hasattr(data_sources.static_source, "load_static")
    with pytest.raises(ImportError):
        import earthsci_ast.data_loaders  # noqa: F401


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
