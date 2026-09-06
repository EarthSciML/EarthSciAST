"""esm-spec §6.6.2 rule 2, as of CONFORMANCE_SPEC §5.31: a dotted override key
resolves to the LONGEST of its dotted suffixes that is a known name — the
trailing segment being tried last — so the §4.6 fully-qualified ``M.sub.A``
binds a build's ``sub.A`` and ``M.A`` binds a bare ``A``, while a key none of
whose suffixes is a name (``Missing.solo``) stays UNKNOWN and rule 3 stays
bare-only."""

from __future__ import annotations

import json

import pytest

from earthsci_ast.errors import AmbiguousParameterError, UnknownParameterError
from earthsci_ast.simulation_common import (
    _dotted_suffix_hit,
    _resolve_override,
    check_parameter_override_keys,
    resolve_override_raw,
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


def test_a_key_that_exactly_names_one_parameter_does_not_drive_another() -> None:
    """Rule 2 resolves a key FORWARD, to the single name it designates.

    ``Right.Left.solo`` is an exact hit on the parameter of that name; read
    backwards it is also ``"." + "Left.solo"``-suffixed, so a reverse scan
    would drive BOTH parameters from the one override. Julia's
    ``_canonicalize_override_keys`` and Rust's ``canonicalize_override_keys``
    map each key to one name; Python must agree.
    """
    known = {"Left.solo", "Right.Left.solo"}
    overrides = {"Right.Left.solo": 9.0}
    assert _resolve_override("Right.Left.solo", overrides, 5.0, known=known) == 9.0
    assert _resolve_override("Left.solo", overrides, 5.0, known=known) == 5.0
    # With no such parameter in the build, the key IS the more-qualified
    # spelling of `Left.solo` — the §4.6 case rule 2 exists for.
    assert _resolve_override("Left.solo", overrides, 5.0, known={"Left.solo"}) == 9.0


def test_resolve_override_is_deterministic_when_two_keys_designate_one_name() -> None:
    known = {"Left.solo"}
    overrides = {"B.Left.solo": 2.0, "A.Left.solo": 1.0}
    assert _resolve_override("Left.solo", overrides, 5.0, known=known) == 1.0
    assert (
        _resolve_override("Left.solo", dict(reversed(list(overrides.items()))), 5.0, known=known)
        == 1.0
    )


def test_resolve_override_raw_applies_rule_2_on_the_array_channel_too() -> None:
    """The rule lives in ``resolve_override_raw``, not only in the ``float``
    wrapper, so a SHAPED parameter's inline array data (esm-spec §6.3 / §6.6.2)
    is found under a more-qualified key exactly as a scalar is. The array path
    (``simulation_array._build_numpy_rhs``) reads only the raw resolver, so a
    rule living one level up would accept ``Doc.Left.solo`` in
    ``check_parameter_override_keys`` and then silently ignore it."""
    assert resolve_override_raw("Left.solo", {"Doc.Left.solo": [1.0, 2.0]}, None) == [1.0, 2.0]
    # …and it is still resolved FORWARD: an exact hit on another parameter is
    # never also read as a more-qualified spelling of this one.
    known = {"Left.solo", "Right.Left.solo"}
    assert resolve_override_raw("Left.solo", {"Right.Left.solo": [1.0]}, None, known=known) is None


def test_array_path_binds_a_more_qualified_parameter_key() -> None:
    """End to end on the ARRAY pathway, which reads ``resolve_override_raw``
    rather than ``_resolve_override``.

    ``check_parameter_override_keys`` accepts ``Doc.M.k`` under rule 2; if the
    resolver one level down did not, the parameter would silently keep its
    default — an accepted override that does nothing, which is the wrong-answer
    shape §6.6.2's key checking exists to prevent. ``u`` integrates ``k`` from 0
    over [0, 1], so the override is visible in the trajectory.
    """
    from earthsci_ast.parse import load_string
    from earthsci_ast.problem import esm_problem, solve

    loop = {
        "op": "aggregate",
        "args": [],
        "output_idx": ["i"],
        "ranges": {"i": {"from": "x"}},
    }
    doc = {
        "esm": "1.0.0",
        "metadata": {
            "name": "override_key_array_path",
            "description": "One shaped state integrating one scalar parameter.",
            "license": "MIT",
        },
        "index_sets": {"x": {"kind": "interval", "size": 2}},
        "models": {
            "M": {
                "variables": {
                    "k": {"type": "parameter", "units": "1", "default": 1.0},
                    "u": {"type": "unknown", "units": "1", "shape": ["x"], "default": 0.0},
                },
                "equations": [
                    {
                        "lhs": {
                            **loop,
                            "expr": {
                                "op": "D",
                                "args": [{"op": "index", "args": ["u", "i"]}],
                                "wrt": "t",
                            },
                        },
                        "rhs": {**loop, "expr": "k"},
                    }
                ],
            }
        },
    }
    file = load_string(json.dumps(doc))

    def at_t1(overrides: dict[str, float] | None) -> float:
        sol = solve(esm_problem(file, (0.0, 1.0), p=overrides))
        return float(sol["M.u[1]"][-1])

    assert at_t1(None) == pytest.approx(1.0, rel=1e-6)
    # Rule 2: the extra leading qualifier is dropped, and the parameter moves.
    assert at_t1({"Doc.M.k": 4.0}) == pytest.approx(4.0, rel=1e-6)
    # The spellings that already worked keep working.
    assert at_t1({"M.k": 3.0}) == pytest.approx(3.0, rel=1e-6)
    assert at_t1({"k": 2.0}) == pytest.approx(2.0, rel=1e-6)
