"""esm-spec §6.6.2 rules 2 and 6, as of CONFORMANCE_SPEC §5.31.

Rule 2: a dotted override key resolves to the LONGEST of its dotted suffixes
that is a known name — the trailing segment being tried last — so the §4.6
fully-qualified ``M.sub.A`` binds a build's ``sub.A`` and ``M.A`` binds a bare
``A``, PROVIDED every leading segment it drops names a component or subsystem
the document declares. A key none of whose suffixes is a name (``Missing.solo``)
stays UNKNOWN, a key whose qualifier names nothing (``Doc.Left.solo``) stays
UNKNOWN too, and rule 3 stays bare-only.

Rule 6: two NON-EXACT keys designating one name is a document authoring error,
not a race to be settled by a ranking.
"""

from __future__ import annotations

import json

import pytest

from earthsci_ast.errors import AmbiguousParameterError, UnknownParameterError
from earthsci_ast.simulation_common import (
    _dotted_suffix_hit,
    _resolve_override,
    check_parameter_override_keys,
    namespace_scope,
    resolve_override_raw,
)


def test_namespace_scope_reads_the_namespaces_off_the_names() -> None:
    assert namespace_scope(["Left.gain", "Left.solo", "Right.gain"]) == {"Left", "Right"}
    assert namespace_scope(["sub.g", "g"]) == {"sub"}
    assert namespace_scope(["sub.g"], ["P"]) == {"sub", "P"}
    assert namespace_scope(["M.sub.A"]) == {"M", "sub"}
    assert namespace_scope(["A"]) == set()


def test_dotted_suffix_hit_takes_the_longest_known_suffix() -> None:
    known = {"sub.g", "g", "Left.solo"}
    ns = namespace_scope(known, ["P"])
    assert _dotted_suffix_hit(known, "P.sub.g", ns) == "sub.g"
    assert _dotted_suffix_hit(known, "P.g", ns) == "g"
    assert _dotted_suffix_hit(known, "Missing.solo", ns) is None
    assert _dotted_suffix_hit(known, "g", ns) is None


def test_rule_2_rejects_a_leading_segment_that_names_nothing() -> None:
    """The leading segments are VALIDATED (esm-spec §6.6.2 rule 2).

    Without the check a typo'd qualifier is silently discarded and the key binds
    whatever name it happens to suffix-match: ``Doc.Left.solo`` driving
    ``Left.solo`` where no component ``Doc`` exists, ``Missng.M.pert_amp``
    driving ``M.pert_amp``.
    """
    known = {"Left.gain", "Left.solo", "Right.gain"}
    # The default scope is read off the build's own names.
    assert _dotted_suffix_hit(known, "Doc.Left.solo") is None
    assert _dotted_suffix_hit(known, "Left.Left.solo") == "Left.solo"
    with pytest.raises(UnknownParameterError):
        check_parameter_override_keys(sorted(known), {"Doc.Left.solo": 9.0})
    # A REAL leading segment still resolves: `P` names the model, `sub` the
    # mounted subsystem, and the build carries the parameter as `sub.g`.
    check_parameter_override_keys(["sub.g"], {"P.sub.g": 1.5}, namespace_scope(["sub.g"], ["P"]))
    assert (
        resolve_override_raw(
            "sub.g", {"P.sub.g": 1.5}, 9.81, known={"sub.g"}, namespaces={"P", "sub"}
        )
        == 1.5
    )
    # ...and without `P` in scope it does not.
    assert (
        resolve_override_raw("sub.g", {"P.sub.g": 1.5}, 9.81, known={"sub.g"}, namespaces={"sub"})
        == 9.81
    )


def test_check_parameter_override_keys_accepts_a_suffix_hit_and_rejects_the_rest() -> None:
    names = ["Left.gain", "Left.solo", "Right.gain"]
    # `Left` is a real component, so its (redundant) qualifier is admitted.
    check_parameter_override_keys(names, {"Left.Left.solo": 9.0})
    with pytest.raises(UnknownParameterError):
        check_parameter_override_keys(names, {"Missing.solo": 9.0})
    with pytest.raises(AmbiguousParameterError):
        check_parameter_override_keys(names, {"gain": 9.0})


def test_resolve_override_reads_a_more_qualified_key() -> None:
    known = {"Left.solo"}
    ns = {"Doc", "Left"}
    assert _resolve_override("Left.solo", {"Doc.Left.solo": 9.0}, 5.0, known, ns) == 9.0
    # An exact key keeps precedence over the longer spelling, and the discarded
    # claim is NOT reported as a collision.
    assert (
        _resolve_override("Left.solo", {"Left.solo": 1.0, "Doc.Left.solo": 9.0}, 5.0, known, ns)
        == 1.0
    )
    assert (
        _resolve_override(
            "Left.solo", {"Left.solo": 1.0, "solo": 2.0, "Doc.Left.solo": 9.0}, 5.0, known, ns
        )
        == 1.0
    )
    # A key that merely ends with the bare segment is not a suffix match.
    assert _resolve_override("Left.solo", {"Right.solo": 9.0}, 5.0, known, ns) == 5.0


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
    # spelling of `Left.solo` — the §4.6 case rule 2 exists for — but only once
    # `Right` is a namespace the document actually declares.
    assert (
        _resolve_override("Left.solo", overrides, 5.0, known={"Left.solo"}, namespaces={"Right"})
        == 9.0
    )
    assert _resolve_override("Left.solo", overrides, 5.0, known={"Left.solo"}) == 5.0


def test_two_keys_designating_one_name_are_ambiguous() -> None:
    """esm-spec §6.6.2: two NON-EXACT keys on one name is an authoring error.

    Before rule 2 was widened, ``Doc.Left.solo`` was simply unknown and this
    collision was unreachable. Silently picking a winner — by ``dict`` order or
    by ranking the rules — would be a wrong answer rather than a missing one:
    the caller wrote two overrides and only one of them can take effect. The
    message is worded identically in Julia (``_override_collision_message``) and
    Rust (``SimulateError::CollidingParameterKeys``).
    """
    known = {"Left.solo"}
    ns = {"A", "B", "Doc", "Left"}
    # Rule 3 (bare) + rule 2 (longer dotted) on one name.
    with pytest.raises(AmbiguousParameterError) as exc:
        _resolve_override("Left.solo", {"solo": 2.0, "Doc.Left.solo": 9.0}, 5.0, known, ns)
    assert str(exc.value) == (
        "parameter_overrides: 2 keys designate the parameter 'Left.solo' "
        "(Doc.Left.solo, solo). Supply exactly one override key per name "
        "(esm-spec §6.6.2)."
    )
    # Two rule-2 keys on one name, in either insertion order.
    for overrides in (
        {"B.Left.solo": 2.0, "A.Left.solo": 1.0},
        {"A.Left.solo": 1.0, "B.Left.solo": 2.0},
    ):
        with pytest.raises(AmbiguousParameterError) as exc:
            _resolve_override("Left.solo", overrides, 5.0, known, ns)
        assert "A.Left.solo, B.Left.solo" in str(exc.value)
    # The whole-map front door reports it too, and names the state channel by
    # its own surface.
    with pytest.raises(AmbiguousParameterError) as exc:
        check_parameter_override_keys(["Left.solo"], {"solo": 2.0, "Left.Left.solo": 9.0})
    assert "2 keys designate the parameter 'Left.solo'" in str(exc.value)
    with pytest.raises(AmbiguousParameterError) as exc:
        _resolve_override(
            "Left.x",
            {"x": 2.0, "Left.Left.x": 9.0},
            0.0,
            {"Left.x"},
            {"Left"},
            surface="initial_conditions",
            kind="state",
        )
    assert str(exc.value).startswith("initial_conditions: 2 keys designate the state 'Left.x'")


def test_an_exact_hit_wins_over_a_competing_suffix_claim() -> None:
    """Rule 1 identifies its name outright, so it is never part of a collision."""
    names = ["Left.solo"]
    check_parameter_override_keys(names, {"Left.solo": 1.0, "solo": 2.0, "Left.Left.solo": 9.0})
    assert (
        _resolve_override(
            "Left.solo",
            {"Left.solo": 1.0, "solo": 2.0, "Left.Left.solo": 9.0},
            5.0,
            {"Left.solo"},
            {"Left"},
        )
        == 1.0
    )


def test_resolve_override_raw_applies_rule_2_on_the_array_channel_too() -> None:
    """The rule lives in ``resolve_override_raw``, not only in the ``float``
    wrapper, so a SHAPED parameter's inline array data (esm-spec §6.3 / §6.6.2)
    is found under a more-qualified key exactly as a scalar is. The array path
    (``simulation_array._build_numpy_rhs``) reads only the raw resolver, so a
    rule living one level up would accept ``Left.Left.solo`` in
    ``check_parameter_override_keys`` and then silently ignore it."""
    assert resolve_override_raw(
        "Left.solo", {"Left.Left.solo": [1.0, 2.0]}, None, {"Left.solo"}, {"Left"}
    ) == [1.0, 2.0]
    # …and it is still resolved FORWARD: an exact hit on another parameter is
    # never also read as a more-qualified spelling of this one.
    known = {"Left.solo", "Right.Left.solo"}
    assert resolve_override_raw("Left.solo", {"Right.Left.solo": [1.0]}, None, known=known) is None


def test_array_path_binds_a_more_qualified_parameter_key() -> None:
    """End to end on the ARRAY pathway, which reads ``resolve_override_raw``
    rather than ``_resolve_override``.

    ``check_parameter_override_keys`` accepts ``M.M.k`` under rule 2 — ``M``
    names a real model, so the redundant qualifier is dropped; if the resolver
    one level down did not, the parameter would silently keep its default, which
    is the wrong-answer shape §6.6.2's key checking exists to prevent. A key
    whose qualifier names NOTHING (``Doc.M.k``) is rejected instead. ``u``
    integrates ``k`` from 0 over [0, 1], so the override is visible in the
    trajectory.
    """
    from earthsci_ast.errors import UnknownParameterError
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
    # Rule 2 with a REAL leading segment: the extra qualifier is dropped, and
    # the parameter moves.
    assert at_t1({"M.M.k": 4.0}) == pytest.approx(4.0, rel=1e-6)
    # Rule 2 with a leading segment that names nothing: rejected, not bound.
    with pytest.raises(UnknownParameterError):
        at_t1({"Doc.M.k": 4.0})
    # The spellings that already worked keep working.
    assert at_t1({"M.k": 3.0}) == pytest.approx(3.0, rel=1e-6)
    assert at_t1({"k": 2.0}) == pytest.approx(2.0, rel=1e-6)
