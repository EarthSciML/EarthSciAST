"""esm-spec §6.6.2 rule 2, as of CONFORMANCE_SPEC §5.26: a dotted override key
resolves to the LONGEST of its dotted suffixes that is a known name — the
trailing segment being tried last — so the §4.6 fully-qualified ``M.sub.A``
binds a build's ``sub.A`` and ``M.A`` binds a bare ``A``, while a key none of
whose suffixes is a name (``Missing.solo``) stays UNKNOWN and rule 3 stays
bare-only."""

from __future__ import annotations

import pytest

from earthsci_ast.errors import AmbiguousParameterError, UnknownParameterError
from earthsci_ast.simulation_common import (
    _dotted_suffix_hit,
    _resolve_override,
    check_parameter_override_keys,
)


def test_dotted_suffix_hit_takes_the_longest_known_suffix() -> None:
    known = {"sub.g", "g", "Left.solo"}
    assert _dotted_suffix_hit(known, "P.sub.g") == "sub.g"
    assert _dotted_suffix_hit(known, "P.g") == "g"
    assert _dotted_suffix_hit(known, "Doc.Left.solo") == "Left.solo"
    assert _dotted_suffix_hit(known, "Missing.solo") is None
    assert _dotted_suffix_hit(known, "g") is None


def test_check_parameter_override_keys_accepts_a_suffix_hit_and_rejects_the_rest() -> None:
    names = ["Left.gain", "Left.solo", "Right.gain"]
    check_parameter_override_keys(names, {"Doc.Left.solo": 9.0})
    with pytest.raises(UnknownParameterError):
        check_parameter_override_keys(names, {"Missing.solo": 9.0})
    with pytest.raises(AmbiguousParameterError):
        check_parameter_override_keys(names, {"gain": 9.0})


def test_resolve_override_reads_a_more_qualified_key() -> None:
    assert _resolve_override("Left.solo", {"Doc.Left.solo": 9.0}, 5.0) == 9.0
    # Exact and bare keys keep precedence over the longer spelling.
    assert _resolve_override("Left.solo", {"Left.solo": 1.0, "Doc.Left.solo": 9.0}, 5.0) == 1.0
    assert _resolve_override("Left.solo", {"solo": 2.0, "Doc.Left.solo": 9.0}, 5.0) == 2.0
    # A key that merely ends with the bare segment is not a suffix match.
    assert _resolve_override("Left.solo", {"Right.solo": 9.0}, 5.0) == 5.0
