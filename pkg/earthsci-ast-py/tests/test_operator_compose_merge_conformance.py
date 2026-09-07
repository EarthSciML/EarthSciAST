"""Cross-language conformance for `operator_compose` merge intent.

Drives the shared manifest at ``tests/conformance/operator_compose_merge/``
(esm-libraries-spec §4.7.1 steps 3 and 5; EarthSciML/EarthSciAST#195).

Three things are pinned, and they are distinct:

1. An entry that merges NOTHING is ``operator_compose_no_merge``, a hard
   refusal: such an entry is indistinguishable from one that is not there. A
   PARTIAL merge stays a warning, because an operator may legitimately
   contribute states of its own alongside the ones it does merge.
2. ``require_match`` is TRI-STATE and absent is not ``false`` — absent means
   "the author has not said" (zero-merge refuses), ``true`` makes ANY shortfall
   fatal, ``false`` DECLARES a standalone-contributing operator and silences
   both. Each state has a non-vacuity anchor, so a binding cannot pass by being
   uniformly strict or uniformly lax.
3. A bare-name match that would unify two STATES is
   ``operator_compose_ambiguous_bare_name``, a refusal: each carries its own
   initial condition and the merge keeps one, which is exactly the silent choice
   that made the `systems` order matter. Where only one side is a state the
   match is unambiguous and the state owns the quantity, in either order.

Unlike the flatten corpus this category carries no golden: it compares
DIAGNOSTIC OUTCOMES, so each binding asserts its own idiomatic channel (here
``warnings.warn`` and the three :class:`FlattenError` subclasses). Cases that
flatten cleanly additionally pin the surviving state's name and default, because
those two — and nothing else — are what used to change with argument order.
"""

from __future__ import annotations

import json
import warnings

import pytest
from conftest import CONFORMANCE_DIR

from earthsci_ast import flatten, load_path
from earthsci_ast.flatten import (
    OperatorComposeAmbiguousBareNameError,
    OperatorComposeNoMergeError,
    OperatorComposeRequireMatchError,
)

CATEGORY_DIR = CONFORMANCE_DIR / "operator_compose_merge"
MANIFEST_FILE = CATEGORY_DIR / "manifest.json"

#: The refusal each code maps to in THIS binding. The manifest's
#: `diagnostic_surface.errors` records the same mapping for every binding; this
#: is the Python column, asserted rather than assumed.
ERROR_FOR_CODE = {
    "operator_compose_no_merge": OperatorComposeNoMergeError,
    "operator_compose_require_match_unmatched": OperatorComposeRequireMatchError,
    "operator_compose_ambiguous_bare_name": OperatorComposeAmbiguousBareNameError,
}


def _load_manifest() -> dict:
    """A missing manifest is a hard failure, not a skip — the manifest IS the
    contract this module exists to enforce."""
    assert MANIFEST_FILE.exists(), f"manifest not found at {MANIFEST_FILE}"
    return json.loads(MANIFEST_FILE.read_text(encoding="utf-8"))


MANIFEST = _load_manifest()
CASES = MANIFEST["cases"]
IDS = [c["id"] for c in CASES]


def _flatten_capturing(case):
    """Flatten the case's fixture, returning ``(system, operator_compose_warnings)``."""
    path = CATEGORY_DIR / case["path"]
    with warnings.catch_warnings(record=True) as caught:
        warnings.simplefilter("always")
        system = flatten(load_path(str(path)))
    messages = [str(w.message) for w in caught if str(w.message).startswith("operator_compose_")]
    return system, messages


def test_the_manifest_is_not_empty():
    """A manifest that silently listed zero cases would make every parametrized
    test below vacuously green."""
    assert CASES, "the operator_compose_merge manifest recorded no cases"
    assert set(MANIFEST["codes"]) == set(ERROR_FOR_CODE) | {"operator_compose_partial_merge"}
    assert MANIFEST["codes"]["operator_compose_partial_merge"] == "warning"
    for code in ERROR_FOR_CODE:
        assert MANIFEST["codes"][code] == "error"


def test_the_binding_column_of_the_manifest_is_this_binding():
    """The manifest names an error type per binding per code. Reading Python's
    column back keeps the record from drifting away from the code silently."""
    recorded = MANIFEST["diagnostic_surface"]["errors"]
    for code, cls in ERROR_FOR_CODE.items():
        assert recorded[code]["python"].endswith(cls.__name__)
        assert cls.code == code


@pytest.mark.parametrize("case", CASES, ids=IDS)
def test_the_manifest_outcome_holds(case):
    """Each case's recorded outcome — refusal, warning, or clean — is produced."""
    outcome = case["outcome"]
    if outcome == "refused":
        expected = ERROR_FOR_CODE[case["code"]]
        with pytest.raises(expected) as excinfo:
            _flatten_capturing(case)
        message = str(excinfo.value)
        assert message.startswith(case["code"]), (
            f"{case['id']}: the refusal must lead with its machine-readable code"
        )
        for name in case.get("unmatched", []) + case.get("unified", []):
            assert name in message, f"{case['id']}: the refusal must NAME {name}"
        return

    system, messages = _flatten_capturing(case)

    if outcome == "clean":
        assert not messages, (
            f"{case['id']}: expected no operator_compose diagnostic, got {messages}"
        )
    else:
        assert len(messages) == 1, f"{case['id']}: expected exactly one diagnostic, got {messages}"
        message = messages[0]
        assert message.startswith(case["code"]), (
            f"{case['id']}: expected {case['code']}, got {message!r}"
        )
        # The tally and the unmatched names are the content that makes the
        # diagnostic actionable; a code with no names is a shrug.
        assert f"merged {case['merged']} of {case['authored']} equations" in message
        for name in case["unmatched"]:
            assert name in message, f"{case['id']}: the diagnostic must NAME {name}"

    if "state_variables" in case:
        assert list(system.state_variables) == case["state_variables"]
    if "surviving_state" in case:
        assert system.state_variables[case["surviving_state"]].default == case["surviving_default"]


def test_the_require_match_truth_table_is_covered():
    """Every cell of the tri-state table the manifest records has a case.

    The table is the whole of `require_match`'s meaning, and its three states
    are three different things an author can mean. A column with no case is a
    column a binding could get wrong without failing anything.
    """
    covered = {(str(c.get("require_match")), c["outcome"]) for c in CASES}
    # absent: zero refuses, partial warns, satisfied is clean.
    assert ("absent", "refused") in covered
    assert ("absent", "warning") in covered
    assert ("absent", "clean") in covered
    # true: a shortfall refuses, a full match is clean.
    assert ("True", "refused") in covered
    assert ("True", "clean") in covered
    # false: permitted, silently — the escape hatch the corpus documents use.
    assert ("False", "clean") in covered
    assert not any(k == ("False", "refused") for k in covered), (
        "`require_match: false` is a declaration that unmatched equations are expected; "
        "nothing under it may refuse"
    )


def test_flipping_the_systems_order_changes_nothing_observable():
    """Issue #195 Symptom 1, in the form that fails under the old rule.

    Two pairs of fixtures, each pair differing ONLY in the `systems` array's
    order. Before this change the AMBIGUOUS pair produced different state names
    carrying different initial conditions — an argument order choosing an IC,
    which no document author has reason to expect. Stated as a comparison
    BETWEEN the two runs rather than against the manifest's recorded values, so
    it fails on disagreement even if both were re-recorded.
    """
    by_id = {c["id"]: c for c in CASES}

    def outcome_of(case):
        try:
            system, _ = _flatten_capturing(case)
        except Exception as exc:  # noqa: BLE001 - the class IS the outcome
            return (type(exc).__name__,)
        return tuple(
            (name, var.default) for name, var in system.state_variables.items()
        )

    for left, right in (
        ("ambiguous_bare_name", "ambiguous_bare_name_flipped"),
        ("owner_rename_state_wins_observed_first", "owner_rename_state_wins_state_first"),
    ):
        a, b = by_id[left], by_id[right]
        assert a["systems"] == list(reversed(b["systems"])), (
            f"{left}/{right} must differ ONLY in `systems` order"
        )
        assert outcome_of(a) == outcome_of(b), (
            f"flipping `systems` changed the outcome between {left} and {right}"
        )


def test_the_ambiguity_refusal_is_not_a_blanket_ban_on_bare_names():
    """The two ways out of an ambiguous bare-name match both still work.

    `translate` names the surviving spelling outright; and a match where only one
    side is a STATE is not ambiguous at all, because only one initial condition
    is at stake. Without this a binding could pass every refusal by refusing the
    whole bare-name fallback.
    """
    by_id = {c["id"]: c for c in CASES}
    resolved, _ = _flatten_capturing(by_id["ambiguous_resolved_by_translate"])
    assert list(resolved.state_variables) == ["Chem.O3"]
    assert resolved.state_variables["Chem.O3"].default == 30.0

    owned, _ = _flatten_capturing(by_id["owner_rename_state_wins_observed_first"])
    assert list(owned.state_variables) == ["Sink.O3"]
    assert owned.state_variables["Sink.O3"].default == 40.0


def test_require_match_round_trips_including_an_explicit_false():
    """`require_match` is TRI-STATE, so an explicit ``false`` must survive the
    round trip — dropping it as "the default" would silently re-arm the
    zero-merge refusal on every document that opted out. An ABSENT flag must
    stay absent for the same reason, in the other direction."""
    from earthsci_ast import to_json

    def emitted(name):
        return json.loads(to_json(load_path(str(CATEGORY_DIR / "fixtures" / name))))

    assert emitted("require_match_unmatched.esm")["coupling"][0]["require_match"] is True
    assert emitted("no_merge_declared.esm")["coupling"][0]["require_match"] is False
    assert "require_match" not in emitted("partial_merge.esm")["coupling"][0]
