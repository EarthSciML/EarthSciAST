"""Cross-language conformance for `operator_compose` merge intent.

Drives the shared manifest at ``tests/conformance/operator_compose_merge/``
(esm-libraries-spec §4.7.1 steps 3 and 5; EarthSciML/EarthSciAST#195).

Three things are pinned, and they are distinct:

1. The merge TALLY is reported. ``operator_compose_no_merge`` when nothing
   landed, ``operator_compose_partial_merge`` when only some did, both naming
   the unmatched dependent variables. Step 5 still preserves the equations —
   that half is unchanged — but it is no longer silent, because silence made
   "merged everything" and "merged nothing" the same observable outcome.
2. ``require_match: true`` promotes either to a hard refusal. A PARTIAL match
   refuses exactly as a zero match does, and ``require_match_satisfied`` is the
   non-vacuity anchor that keeps the flag from being simply always-fatal.
3. The BARE-NAME fallback's surviving spelling follows the state's OWNER — the
   component the document declares first — not ``systems[0]``. The
   ``owner_rename_*`` trio pins that an entry means the same thing in either
   argument order, which is the whole of issue #195's Symptom 1.

Unlike the flatten corpus this category carries no golden: it compares
DIAGNOSTIC OUTCOMES, so each binding asserts its own idiomatic channel (here
``warnings.warn`` / :class:`OperatorComposeRequireMatchError`). The
``owner_rename_*`` cases additionally pin two VALUES — the surviving state's
name and its default — because those two, and nothing else, are what changed
with argument order.
"""

from __future__ import annotations

import json
import warnings

import pytest
from conftest import CONFORMANCE_DIR

from earthsci_ast import flatten, load_path
from earthsci_ast.flatten import OperatorComposeRequireMatchError

CATEGORY_DIR = CONFORMANCE_DIR / "operator_compose_merge"
MANIFEST_FILE = CATEGORY_DIR / "manifest.json"


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
    assert set(MANIFEST["codes"]) == {
        "operator_compose_no_merge",
        "operator_compose_partial_merge",
        "operator_compose_require_match_unmatched",
    }


@pytest.mark.parametrize("case", CASES, ids=IDS)
def test_the_manifest_outcome_holds(case):
    """Each case's recorded outcome — warning, refusal, or clean — is produced."""
    outcome = case["outcome"]
    if outcome == "refused":
        with pytest.raises(OperatorComposeRequireMatchError) as excinfo:
            _flatten_capturing(case)
        message = str(excinfo.value)
        assert message.startswith(case["code"]), (
            f"{case['id']}: the refusal must lead with its machine-readable code"
        )
        for name in case["unmatched"]:
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


@pytest.mark.parametrize(
    "case",
    [c for c in CASES if "surviving_state" in c],
    ids=[c["id"] for c in CASES if "surviving_state" in c],
)
def test_the_bare_name_match_survives_under_its_owners_spelling(case):
    """§4.7.1 step 3: the surviving spelling is the state OWNER's.

    The tendency is arithmetically identical whichever way the entry is written,
    so the surviving NAME and its DEFAULT are the entire observable difference —
    which is exactly why they are pinned here rather than left to the equation
    comparison.
    """
    system, _ = _flatten_capturing(case)
    assert list(system.state_variables) == [case["surviving_state"]]
    assert system.state_variables[case["surviving_state"]].default == case["surviving_default"]


def test_flipping_the_systems_order_changes_nothing_observable():
    """Issue #195 Symptom 1, in the form that fails under the old rule.

    Two fixtures with identical models in identical declaration order, differing
    only in the `systems` array's order. Before the ownership rule these produced
    different state names carrying different initial conditions — an argument
    order choosing an IC, which no document author has reason to expect. Stated
    as a comparison between the two runs rather than against the manifest's
    recorded values, so it fails on DISAGREEMENT even if both were re-recorded.
    """
    pair = [
        next(c for c in CASES if c["id"] == "owner_rename_operator_first"),
        next(c for c in CASES if c["id"] == "owner_rename_mechanism_listed_first"),
    ]
    assert pair[0]["models_declared"] == pair[1]["models_declared"], (
        "the two fixtures must differ ONLY in `systems` order"
    )
    assert pair[0]["systems"] == list(reversed(pair[1]["systems"]))

    surviving = []
    for case in pair:
        system, _ = _flatten_capturing(case)
        assert len(system.state_variables) == 1
        name, var = next(iter(system.state_variables.items()))
        surviving.append((name, var.default))
    assert surviving[0] == surviving[1], (
        "flipping `systems` changed the surviving state or its initial condition"
    )


def test_declaration_order_decides_not_argument_order():
    """The companion to the test above, and what keeps it from being trivial.

    `owner_rename_mechanism_declared_first` lists the OPERATOR first in `systems`
    exactly as `owner_rename_operator_first` does, and differs only in `models`
    declaration order — so a binding that hard-coded either answer, or that kept
    renaming onto `systems[0]`, fails one of the two.
    """
    a = next(c for c in CASES if c["id"] == "owner_rename_operator_first")
    b = next(c for c in CASES if c["id"] == "owner_rename_mechanism_declared_first")
    assert a["systems"] == b["systems"], "the two fixtures must share a `systems` order"
    assert a["models_declared"] == list(reversed(b["models_declared"]))

    sa, _ = _flatten_capturing(a)
    sb, _ = _flatten_capturing(b)
    assert list(sa.state_variables) != list(sb.state_variables), (
        "declaration order must be what decides the surviving spelling"
    )
    assert list(sa.state_variables) == ["Sink.O3"]
    assert list(sb.state_variables) == ["Chem.O3"]


def test_require_match_survives_a_round_trip():
    """`require_match` is a document field, so it must reach the emitted form —
    a flag that silently vanished on save would make the refusal unreproducible
    from the file the author kept."""
    from earthsci_ast import to_json

    path = CATEGORY_DIR / "fixtures/require_match_unmatched.esm"
    emitted = json.loads(to_json(load_path(str(path))))
    assert emitted["coupling"][0]["require_match"] is True
    # ... and the DEFAULT is not written out: emitting `false` everywhere would
    # put a key on every existing fixture and break load preservation.
    clean = json.loads(to_json(load_path(str(CATEGORY_DIR / "fixtures/no_merge.esm"))))
    assert "require_match" not in clean["coupling"][0]
