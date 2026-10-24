"""esm-spec §4.7 "Working precision crosses a mount" (CONFORMANCE_SPEC
§5.18.2b): a mounted document's ``domain.element_type`` does not merge, so the
mount edge writes it onto the variables of the component it splices in whenever
it differs from the mounting document's effective precision.

The fixtures are shared with the other four bindings
(``tests/conformance/mount_element_type/``). This binding asserts the loader
contract (``loads``, ``load_errors``); it does not evaluate per-variable
precision, so ``values`` and ``build_errors`` belong to the bindings listed in
``evaluated_by``.
"""

from __future__ import annotations

import json

import pytest
from conftest import FIXTURES_ROOT

from earthsci_ast.parse import load_path, load_string
from earthsci_ast.serialize import to_json

FIXTURES = FIXTURES_ROOT / "conformance" / "mount_element_type"
EXPECTED = json.loads((FIXTURES / "expected.json").read_text())


def _carried(doc: dict) -> dict:
    """Every variable (subsystems as ``Model.Sub.var``) -> its emitted
    ``element_type``, or ``None``."""
    out: dict = {}

    def walk(prefix: str, system: dict) -> None:
        for name, decl in (system.get("variables") or {}).items():
            out[f"{prefix}.{name}"] = decl.get("element_type")
        for key, sub in (system.get("subsystems") or {}).items():
            walk(f"{prefix}.{key}", sub)

    for name, model in (doc.get("models") or {}).items():
        walk(name, model)
    return out


def _emitted(esm_file) -> dict:
    return json.loads(to_json(esm_file))


@pytest.mark.parametrize("fixture", sorted(EXPECTED["loads"]))
def test_a_mount_writes_exactly_the_leafs_differing_precision(fixture):
    want = EXPECTED["loads"][fixture]
    doc = _emitted(load_path(str(FIXTURES / fixture)))
    assert (doc.get("domain") or {}).get("element_type") == want["domain_element_type"]
    assert _carried(doc) == want["element_types"]


@pytest.mark.parametrize("fixture", sorted(EXPECTED["loads"]))
def test_the_written_fields_round_trip(fixture):
    once = _emitted(load_path(str(FIXTURES / fixture)))
    twice = _emitted(load_string(json.dumps(once)))
    assert _carried(twice) == _carried(once)


def _expected_load_error(want: dict, binding: str):
    """The code ``binding`` must refuse a fixture with, or ``None`` when it must
    only refuse (``load_errors`` maps a fixture to ``{code: [bindings]}``)."""
    return next((code for code, bindings in want.items() if binding in bindings), None)


@pytest.mark.parametrize("fixture", sorted(EXPECTED["load_errors"]))
def test_a_reaction_system_cannot_carry_a_mounted_precision(fixture):
    code = _expected_load_error(EXPECTED["load_errors"][fixture], "python")
    with pytest.raises(Exception) as info:
        load_path(str(FIXTURES / fixture))
    if code is not None:
        assert getattr(info.value, "code", None) == code, info.value
