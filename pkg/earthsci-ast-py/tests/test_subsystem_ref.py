"""Tests for subsystem reference resolution in load()."""

import json
import os
import tempfile

import pytest

from earthsci_ast import DataLoader, load
from earthsci_ast.parse import (
    CircularReferenceError,
    SubsystemRefError,
)
from earthsci_ast.validation import validate


def _write(path: str, payload: dict) -> None:
    with open(path, "w") as f:
        json.dump(payload, f)


# A minimal schema-valid pure-I/O data loader (RFC pure-io-data-loaders).
_LOADER = {
    "kind": "grid",
    "source": {"url_template": "file:///data/{date:%Y%m%d}.nc"},
    "variables": {"emis": {"file_variable": "EMIS", "units": "kg/m^2/s"}},
}


def test_load_resolves_local_subsystem_ref():
    with tempfile.TemporaryDirectory() as tmp:
        sub_path = os.path.join(tmp, "inner.esm.json")
        _write(
            sub_path,
            {
                "esm": "0.1.0",
                "metadata": {"name": "inner"},
                "models": {
                    "Inner": {
                        "variables": {
                            "x": {"type": "state", "default": 1.0},
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
                "esm": "0.1.0",
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

        loaded = load(main_path)
        outer = loaded.models["Outer"]
        assert "Inner" in outer.subsystems
        inner = outer.subsystems["Inner"]
        # After resolution we should have the typed model with x as a state var
        assert hasattr(inner, "variables")
        assert "x" in inner.variables


def test_load_raises_for_missing_local_ref():
    with tempfile.TemporaryDirectory() as tmp:
        main_path = os.path.join(tmp, "main.esm.json")
        _write(
            main_path,
            {
                "esm": "0.1.0",
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
            load(main_path)


def test_circular_reference_detection():
    with tempfile.TemporaryDirectory() as tmp:
        a_path = os.path.join(tmp, "a.esm.json")
        b_path = os.path.join(tmp, "b.esm.json")
        _write(
            a_path,
            {
                "esm": "0.1.0",
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
                "esm": "0.1.0",
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
                "esm": "0.1.0",
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
            load(main_path)


def test_loader_only_file_loads_and_validates():
    """A document whose sole top-level component is data_loaders is valid
    (RFC pure-io-data-loaders §4.4 / esm-spec §4.7)."""
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "loader_only.esm.json")
        _write(
            path,
            {
                "esm": "0.1.0",
                "metadata": {"name": "loader_only"},
                "data_loaders": {"Met": _LOADER},
            },
        )

        loaded = load(path)
        assert loaded.models == {} or not loaded.models
        assert "Met" in loaded.data_loaders
        assert isinstance(loaded.data_loaders["Met"], DataLoader)

        # The structural validator must also accept a loader-only file.
        result = validate(loaded)
        assert result.is_valid, result.structural_errors


def test_load_resolves_local_loader_ref():
    """A subsystem ref to a single-loader file resolves to that loader,
    named by the parent's subsystem key (RFC pure-io-data-loaders §4.4)."""
    with tempfile.TemporaryDirectory() as tmp:
        sub_path = os.path.join(tmp, "loader.esm.json")
        _write(
            sub_path,
            {
                "esm": "0.1.0",
                "metadata": {"name": "loader"},
                "data_loaders": {"GEOSFP": _LOADER},
            },
        )

        main_path = os.path.join(tmp, "main.esm.json")
        _write(
            main_path,
            {
                "esm": "0.1.0",
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

        loaded = load(main_path)
        met = loaded.models["Regridder"].subsystems["Met"]
        assert isinstance(met, DataLoader)
        # Named by the parent subsystem key, not the referenced file's key.
        assert met.name == "Met"
        assert "emis" in met.variables


def test_load_inline_loader_subsystem():
    """A data loader declared inline in a model's subsystems map parses as a
    DataLoader (schema oneOf [Model, DataLoader, SubsystemRef])."""
    with tempfile.TemporaryDirectory() as tmp:
        main_path = os.path.join(tmp, "main.esm.json")
        _write(
            main_path,
            {
                "esm": "0.1.0",
                "metadata": {"name": "main"},
                "models": {
                    "Regridder": {
                        "variables": {},
                        "equations": [],
                        "subsystems": {"Met": _LOADER},
                    },
                },
            },
        )

        loaded = load(main_path)
        met = loaded.models["Regridder"].subsystems["Met"]
        assert isinstance(met, DataLoader)
        assert met.name == "Met"
        assert met.kind.value == "grid"


def test_load_raises_for_ref_without_model_or_loader():
    """A referenced file with neither a model nor a data loader is an error."""
    with tempfile.TemporaryDirectory() as tmp:
        sub_path = os.path.join(tmp, "empty.esm.json")
        # reaction_systems-only file: valid document, but not a valid Model
        # subsystem target (the schema only admits Model/DataLoader/ref there).
        _write(
            sub_path,
            {
                "esm": "0.1.0",
                "metadata": {"name": "rs_only"},
                "reaction_systems": {"Chem": {"species": {}, "reactions": []}},
            },
        )

        main_path = os.path.join(tmp, "main.esm.json")
        _write(
            main_path,
            {
                "esm": "0.1.0",
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
            load(main_path)
