"""Which registry keys bind a data-fed parameter (esm-spec §9.6.6)."""

from __future__ import annotations

from earthsci_ast.problem import _binds


def test_exact_and_dotted_suffix_keys_bind():
    assert _binds("Forcing.k", {"Forcing.k": 1})
    assert _binds("Top.Forcing.k", {"Forcing.k": 1})
    assert _binds("Forcing.k", {"k": 1})
    # a raw model's bare name, with the caller qualifying the key
    assert _binds("k", {"Forcing.k": 1})


def test_a_key_for_another_component_does_not_bind():
    assert not _binds("Forcing.k", {"Other.k": 1})
    assert not _binds("Forcing.k", {"Other.k": 1}, {"kk": 1}, {"orcing.k": 1})
