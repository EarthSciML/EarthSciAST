"""Tests for subsystem reference resolution in load()."""

import json
import os
import tempfile

import pytest

from earthsci_ast import DataSource, load_path
from earthsci_ast.parse import (
    CircularReferenceError,
    SubsystemRefError,
)
from earthsci_ast.validation import validate


def _write(path: str, payload: dict) -> None:
    with open(path, "w") as f:
        json.dump(payload, f)


# A minimal schema-valid pure-I/O data source (RFC pure-io-data-loaders). In
# esm 1.0.0 a source declares NO `variables` map: it is a pure IO declaration,
# and the CONSUMING PARAMETER carries the file-variable binding and the units.
_SOURCE = {
    "kind": "grid",
    "source": {"url_template": "file:///data/{date:%Y%m%d}.nc"},
}


def test_load_resolves_local_subsystem_ref():
    with tempfile.TemporaryDirectory() as tmp:
        sub_path = os.path.join(tmp, "inner.esm.json")
        _write(
            sub_path,
            {
                "esm": "1.0.0",
                "metadata": {"name": "inner"},
                "models": {
                    "Inner": {
                        "variables": {
                            "x": {"type": "unknown", "default": 1.0},
                        },
                        "equations": [],
                    },
                },
            },
        )

        main_path = os.path.join(tmp, "main.esm.json")
        _write(
            main_path,
            {
                "esm": "1.0.0",
                "metadata": {"name": "main"},
                "models": {
                    "Outer": {
                        "variables": {},
                        "equations": [],
                        "subsystems": {
                            "Inner": {"ref": "./inner.esm.json"},
                        },
                    },
                },
            },
        )

        loaded = load_path(main_path)
        outer = loaded.models["Outer"]
        assert "Inner" in outer.subsystems
        inner = outer.subsystems["Inner"]
        # After resolution we should have the typed model with x as an unknown
        assert hasattr(inner, "variables")
        assert "x" in inner.variables


def test_load_raises_for_missing_local_ref():
    with tempfile.TemporaryDirectory() as tmp:
        main_path = os.path.join(tmp, "main.esm.json")
        _write(
            main_path,
            {
                "esm": "1.0.0",
                "metadata": {"name": "main"},
                "models": {
                    "Outer": {
                        "variables": {},
                        "equations": [],
                        "subsystems": {
                            "Missing": {"ref": "./does-not-exist.esm.json"},
                        },
                    },
                },
            },
        )

        with pytest.raises(SubsystemRefError):
            load_path(main_path)


def test_circular_reference_detection():
    with tempfile.TemporaryDirectory() as tmp:
        a_path = os.path.join(tmp, "a.esm.json")
        b_path = os.path.join(tmp, "b.esm.json")
        _write(
            a_path,
            {
                "esm": "1.0.0",
                "metadata": {"name": "a"},
                "models": {
                    "A": {
                        "variables": {},
                        "equations": [],
                        "subsystems": {"Cycle": {"ref": "./b.esm.json"}},
                    },
                },
            },
        )
        _write(
            b_path,
            {
                "esm": "1.0.0",
                "metadata": {"name": "b"},
                "models": {
                    "B": {
                        "variables": {},
                        "equations": [],
                        "subsystems": {"Cycle": {"ref": "./a.esm.json"}},
                    },
                },
            },
        )

        main_path = os.path.join(tmp, "main.esm.json")
        _write(
            main_path,
            {
                "esm": "1.0.0",
                "metadata": {"name": "main"},
                "models": {
                    "Root": {
                        "variables": {},
                        "equations": [],
                        "subsystems": {"Start": {"ref": "./a.esm.json"}},
                    },
                },
            },
        )

        with pytest.raises(CircularReferenceError):
            load_path(main_path)


def test_loader_only_file_loads_and_validates():
    """A document whose sole top-level component is data_sources is valid
    (RFC pure-io-data-loaders §4.4 / esm-spec §4.7)."""
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "loader_only.esm.json")
        _write(
            path,
            {
                "esm": "1.0.0",
                "metadata": {"name": "loader_only"},
                "data_sources": {"Met": _SOURCE},
            },
        )

        loaded = load_path(path)
        assert loaded.models == {} or not loaded.models
        assert "Met" in loaded.data_sources
        assert isinstance(loaded.data_sources["Met"], DataSource)

        # The structural validator must also accept a loader-only file.
        result = validate(loaded)
        assert result.is_valid, result.structural_errors


def test_subsystem_ref_to_source_only_file_raises():
    """esm 1.0.0 removed the loader subsystem mount: a data source is NOT a
    component, so a subsystem ref must resolve to a MODEL. A source-only file
    is no longer a valid subsystem target — a model reaches external data
    through a parameter whose ``update`` names the source instead."""
    with tempfile.TemporaryDirectory() as tmp:
        sub_path = os.path.join(tmp, "loader.esm.json")
        _write(
            sub_path,
            {
                "esm": "1.0.0",
                "metadata": {"name": "loader"},
                "data_sources": {"GEOSFP": _SOURCE},
            },
        )

        main_path = os.path.join(tmp, "main.esm.json")
        _write(
            main_path,
            {
                "esm": "1.0.0",
                "metadata": {"name": "main"},
                "models": {
                    "Regridder": {
                        "variables": {},
                        "equations": [],
                        "subsystems": {"Met": {"ref": "./loader.esm.json"}},
                    },
                },
            },
        )

        with pytest.raises(SubsystemRefError, match="does not contain a model"):
            load_path(main_path)


def test_inline_source_is_not_a_valid_subsystem():
    """A data source declared inline in a model's subsystems map is rejected."""
    from earthsci_ast.parse import SchemaValidationError

    with tempfile.TemporaryDirectory() as tmp:
        main_path = os.path.join(tmp, "main.esm.json")
        _write(
            main_path,
            {
                "esm": "1.0.0",
                "metadata": {"name": "main"},
                "models": {
                    "Regridder": {
                        "variables": {},
                        "equations": [],
                        "subsystems": {"Met": _SOURCE},
                    },
                },
            },
        )

        with pytest.raises(SchemaValidationError):
            load_path(main_path)


def test_load_raises_for_ref_without_model_or_loader():
    """A referenced file with no model is an error."""
    with tempfile.TemporaryDirectory() as tmp:
        sub_path = os.path.join(tmp, "empty.esm.json")
        # reaction_systems-only file: valid document, but not a valid Model
        # subsystem target (the schema only admits Model/DataSource/ref there).
        _write(
            sub_path,
            {
                "esm": "1.0.0",
                "metadata": {"name": "rs_only"},
                "reaction_systems": {"Chem": {"species": {}, "reactions": []}},
            },
        )

        main_path = os.path.join(tmp, "main.esm.json")
        _write(
            main_path,
            {
                "esm": "1.0.0",
                "metadata": {"name": "main"},
                "models": {
                    "Outer": {
                        "variables": {},
                        "equations": [],
                        "subsystems": {"Bad": {"ref": "./empty.esm.json"}},
                    },
                },
            },
        )

        with pytest.raises(SubsystemRefError):
            load_path(main_path)
