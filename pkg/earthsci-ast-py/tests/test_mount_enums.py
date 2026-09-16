"""esm-spec §9.3: an ``enum`` op in a mounted file resolves against THAT file's
``enums`` block, at either §4.7 mount form, and ``enums`` do not merge across
the mount.

Issue #260: two leaves declaring the same enum symbol with different values
shared one registry, so a leaf could compute with another file's constant. The
fixtures are shared with the other four bindings
(``tests/conformance/mount_enums/``).
"""

from __future__ import annotations

import json

import pytest
from conftest import FIXTURES_ROOT

from earthsci_ast.parse import load_path

FIXTURES = FIXTURES_ROOT / "conformance" / "mount_enums"
EXPECTED = json.loads((FIXTURES / "expected.json").read_text())


def _rhs(esm_file, path: str):
    """The right-hand side defining the variable at the end of ``path``
    (model, then subsystem keys, then variable)."""
    *comps, var = path.split(".")
    node = esm_file.models[comps[0]]
    for sub in comps[1:]:
        node = node.subsystems[sub]
    return next(eq.rhs for eq in node.equations if eq.lhs == var)


@pytest.mark.parametrize("fixture", sorted(EXPECTED["loads"]))
def test_a_mounted_files_enum_ops_resolve_against_its_own_block(fixture):
    esm_file = load_path(str(FIXTURES / fixture))
    for path, want in EXPECTED["loads"][fixture].items():
        rhs = _rhs(esm_file, path)
        assert (getattr(rhs, "op", None), getattr(rhs, "value", None)) == ("const", want), (
            f"{path} lowers to {rhs!r}"
        )


@pytest.mark.parametrize("fixture", sorted(EXPECTED["errors"]))
def test_an_assemblys_own_enum_op_does_not_see_a_leafs_block(fixture):
    with pytest.raises(Exception) as info:
        load_path(str(FIXTURES / fixture))
    assert getattr(info.value, "code", None) == EXPECTED["errors"][fixture], info.value
