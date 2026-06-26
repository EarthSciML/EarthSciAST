"""Tests for top-level model reference resolution in load().

`resolve_model_refs` is the top-level analog of `resolve_subsystem_refs`
(esm-spec §4.7): a top-level `models[X]` whose body is `{"ref": "<file|url>"}`
is fetched, schema-validated, and its single model spliced into `models[X]`
under the SAME key `X`. Because flatten collects the spliced model with prefix
`X`, the flat names `X.<var>` already equal the coupling-edge endpoint names —
a coupled document that imports its components by reference assembles with zero
coupling-edge rewrites.
"""

import json
import os
import tempfile

import pytest

from earthsci_toolkit import DataLoader, flatten, load
from earthsci_toolkit.parse import (
    CircularReferenceError,
    SubsystemRefError,
    resolve_model_refs,
)


def _write(path: str, payload: dict) -> None:
    with open(path, "w") as f:
        json.dump(payload, f)


# A minimal schema-valid pure-I/O data loader (RFC pure-io-data-loaders).
_LOADER = {
    "kind": "grid",
    "source": {"url_template": "file:///data/{date:%Y%m%d}.nc"},
    "variables": {"emis": {"file_variable": "EMIS", "units": "kg/m^2/s"}},
}


def _producer(name: str = "producer") -> dict:
    """A component file exposing `Producer.out = Producer.y + 1` (observed)."""
    return {
        "esm": "0.1.0",
        "metadata": {"name": name},
        "models": {
            "Producer": {
                "variables": {
                    "y": {"type": "state", "default": 0.0},
                    "out": {
                        "type": "observed",
                        "units": "1",
                        "expression": {"op": "+", "args": ["y", 1.0]},
                    },
                },
                "equations": [
                    {"lhs": {"op": "D", "args": ["y"], "wrt": "t"}, "rhs": 1.0},
                ],
            },
        },
    }


def _consumer(name: str = "consumer") -> dict:
    """A component file with a free parameter `Consumer.p` driving `Consumer.z`."""
    return {
        "esm": "0.1.0",
        "metadata": {"name": name},
        "models": {
            "Consumer": {
                "variables": {
                    "z": {"type": "state", "default": 0.0},
                    "p": {"type": "parameter", "default": 0.0, "units": "1"},
                },
                "equations": [
                    {"lhs": {"op": "D", "args": ["z"], "wrt": "t"}, "rhs": "p"},
                ],
            },
        },
    }


def test_load_resolves_top_level_model_ref():
    """A top-level `models[X] = {ref}` splices the referenced model under X."""
    with tempfile.TemporaryDirectory() as tmp:
        _write(os.path.join(tmp, "producer.esm.json"), _producer())

        main_path = os.path.join(tmp, "main.esm.json")
        _write(main_path, {
            "esm": "0.1.0",
            "metadata": {"name": "main"},
            "models": {
                "Producer": {"ref": "./producer.esm.json"},
            },
        })

        loaded = load(main_path)
        producer = loaded.models["Producer"]
        # Spliced under the SAME key with name = X; carries its real variables.
        assert hasattr(producer, "variables")
        assert producer.name == "Producer"
        assert "y" in producer.variables
        assert "out" in producer.variables


def test_coupled_model_refs_resolve_zero_rewrite():
    """Keystone (A1e accept): a 2-ref-model + coupling-edge coupled doc loads,
    flattens to X-namespaced vars/equations, and the coupling edge resolves
    with ZERO rewrites — the consumer parameter is promoted away and the
    producer symbol survives, because `X.<var>` already equals the edge names."""
    with tempfile.TemporaryDirectory() as tmp:
        _write(os.path.join(tmp, "producer.esm.json"), _producer())
        _write(os.path.join(tmp, "consumer.esm.json"), _consumer())

        main_path = os.path.join(tmp, "main.esm.json")
        _write(main_path, {
            "esm": "0.1.0",
            "metadata": {"name": "coupled"},
            "models": {
                "Producer": {"ref": "./producer.esm.json"},
                "Consumer": {"ref": "./consumer.esm.json"},
            },
            # Edge endpoints are byte-identical to the spliced flat names —
            # no rewrite of `from`/`to` is needed for the edge to resolve.
            "coupling": [
                {
                    "type": "variable_map",
                    "from": "Producer.out",
                    "to": "Consumer.p",
                    "transform": "param_to_var",
                },
            ],
        })

        loaded = load(main_path)
        assert set(loaded.models) == {"Producer", "Consumer"}

        fs = flatten(loaded)

        # Vars/equations are X-namespaced: each state var implies its ODE.
        assert "Producer.y" in fs.state_variables
        assert "Consumer.z" in fs.state_variables
        assert "Producer.out" in fs.observed_variables

        # Zero-rewrite coupling resolution: the consumer parameter was promoted
        # (no longer a free parameter) and the surviving symbol is the producer.
        assert "Consumer.p" not in fs.parameters
        assert "Producer.out" in fs.observed_variables


def test_model_ref_mixes_with_inline_model():
    """A referenced top-level model coexists with an inline top-level model."""
    with tempfile.TemporaryDirectory() as tmp:
        _write(os.path.join(tmp, "producer.esm.json"), _producer())

        main_path = os.path.join(tmp, "main.esm.json")
        _write(main_path, {
            "esm": "0.1.0",
            "metadata": {"name": "mixed"},
            "models": {
                "Producer": {"ref": "./producer.esm.json"},
                "Inline": {
                    "variables": {"w": {"type": "state", "default": 2.0}},
                    "equations": [
                        {"lhs": {"op": "D", "args": ["w"], "wrt": "t"}, "rhs": 0.0},
                    ],
                },
            },
        })

        loaded = load(main_path)
        assert "y" in loaded.models["Producer"].variables
        assert "w" in loaded.models["Inline"].variables


def test_model_ref_missing_file_raises():
    """A dangling top-level model ref raises SubsystemRefError."""
    with tempfile.TemporaryDirectory() as tmp:
        main_path = os.path.join(tmp, "main.esm.json")
        _write(main_path, {
            "esm": "0.1.0",
            "metadata": {"name": "main"},
            "models": {
                "Missing": {"ref": "./does-not-exist.esm.json"},
            },
        })

        with pytest.raises(SubsystemRefError):
            load(main_path)


def test_model_ref_to_loader_only_file_raises():
    """A top-level model ref must resolve to a model — a data-loader-only file
    is not a valid top-level model component (unlike a subsystem ref)."""
    with tempfile.TemporaryDirectory() as tmp:
        _write(os.path.join(tmp, "loader_only.esm.json"), {
            "esm": "0.1.0",
            "metadata": {"name": "loader_only"},
            "data_loaders": {"Met": _LOADER},
        })

        main_path = os.path.join(tmp, "main.esm.json")
        _write(main_path, {
            "esm": "0.1.0",
            "metadata": {"name": "main"},
            "models": {
                "Met": {"ref": "./loader_only.esm.json"},
            },
        })

        with pytest.raises(SubsystemRefError):
            load(main_path)


def test_circular_model_ref_detection():
    """A top-level model ref whose referenced file points a subsystem back at
    itself is a cycle — the chain is seeded with the top-level ref."""
    with tempfile.TemporaryDirectory() as tmp:
        # self_ref.esm: its model has a subsystem ref to self_ref.esm.
        _write(os.path.join(tmp, "self_ref.esm.json"), {
            "esm": "0.1.0",
            "metadata": {"name": "self_ref"},
            "models": {
                "SelfRef": {
                    "variables": {},
                    "equations": [],
                    "subsystems": {"Cycle": {"ref": "./self_ref.esm.json"}},
                },
            },
        })

        main_path = os.path.join(tmp, "main.esm.json")
        _write(main_path, {
            "esm": "0.1.0",
            "metadata": {"name": "main"},
            "models": {
                "SelfRef": {"ref": "./self_ref.esm.json"},
            },
        })

        with pytest.raises(CircularReferenceError):
            load(main_path)


def test_resolve_model_refs_is_idempotent_on_inline_models():
    """resolve_model_refs leaves an already-parsed (inline) model untouched."""
    with tempfile.TemporaryDirectory() as tmp:
        main_path = os.path.join(tmp, "main.esm.json")
        _write(main_path, {
            "esm": "0.1.0",
            "metadata": {"name": "main"},
            "models": {
                "Inline": {
                    "variables": {"w": {"type": "state", "default": 2.0}},
                    "equations": [
                        {"lhs": {"op": "D", "args": ["w"], "wrt": "t"}, "rhs": 0.0},
                    ],
                },
            },
        })

        loaded = load(main_path)
        before = loaded.models["Inline"]
        # A second pass is a no-op for concrete Model objects.
        resolve_model_refs(loaded, tmp)
        assert loaded.models["Inline"] is before
