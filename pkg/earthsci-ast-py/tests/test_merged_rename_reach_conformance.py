"""Cross-language conformance for how far a merged-away rename REACHES.

Drives the shared manifest at ``tests/conformance/merged_rename_reach/``
(esm-libraries-spec §4.7.1 step 4 and §4.7.5 step 3 ordering;
EarthSciML/EarthSciAST#230).

An ``operator_compose`` renaming match folds ``B.x`` into ``A.x``, deleting
``B.x`` and rewriting every equation off it. That rewrite reaches equation ASTs
and nothing else, and ``operator_compose`` entries run BEFORE ``couple`` and
``variable_map`` — so a later entry's ``from`` / ``to``, which are plain
scoped-reference STRINGS on the entry object, could still name a spelling that
no longer exists. This module pins that they RESOLVE to the survivor:

* a later ``couple`` connector targeting the dead name lands on the survivor's
  tendency, instead of matching nothing and being dropped in silence;
* a later ``variable_map`` sourcing the dead name substitutes the SURVIVOR,
  instead of injecting a reference the flattened system cannot resolve;
* a runner override key naming the dead name addresses the survivor, instead of
  being dropped so the state runs from its declared default;
* a name-keyed READ of the finished run resolves to the survivor's row, instead
  of reporting a variable that never existed.

Like ``operator_compose_merge`` the category carries no golden: what it pins is
REACH, asserted as structure.
"""

from __future__ import annotations

import json
import warnings

import pytest
from conftest import CONFORMANCE_DIR

from earthsci_ast import flatten, load_path
from earthsci_ast.flatten import _expr_to_string, _lhs_dependent_var
from earthsci_ast.problem import esm_problem, solve

CATEGORY_DIR = CONFORMANCE_DIR / "merged_rename_reach"
MANIFEST_FILE = CATEGORY_DIR / "manifest.json"


def _load_manifest() -> dict:
    """A missing manifest is a hard failure, not a skip — the manifest IS the
    contract this module exists to enforce."""
    assert MANIFEST_FILE.exists(), f"manifest not found at {MANIFEST_FILE}"
    return json.loads(MANIFEST_FILE.read_text(encoding="utf-8"))


MANIFEST = _load_manifest()
CASES = MANIFEST["cases"]
IDS = [c["id"] for c in CASES]
FLATTEN_CASES = [c for c in CASES if c["surface"] == "flatten"]
OVERRIDE_CASES = [c for c in CASES if c["surface"] == "override_keys"]
OUTPUT_CASES = [c for c in CASES if c["surface"] == "output_selection"]


def _flatten(case):
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        return flatten(load_path(str(CATEGORY_DIR / case["path"])))


def test_the_manifest_is_not_empty():
    """A manifest that silently listed zero cases would make every parametrized
    test below vacuously green."""
    assert FLATTEN_CASES, "the merged_rename_reach manifest recorded no flatten cases"
    assert OVERRIDE_CASES, "the merged_rename_reach manifest recorded no override cases"
    assert OUTPUT_CASES, "the merged_rename_reach manifest recorded no output cases"
    assert "python" in MANIFEST["surfaces"]["flatten"]["bindings"]
    assert "python" in MANIFEST["surfaces"]["override_keys"]["bindings"]
    assert "python" in MANIFEST["surfaces"]["output_selection"]["bindings"]


def test_the_binding_column_of_the_manifest_is_this_binding():
    """The manifest names the rename-map field per binding. Reading Python's
    column back keeps the record from drifting away from the code silently."""
    recorded = MANIFEST["merged_variable_renames_field"]["python"]
    assert recorded == "FlattenMetadata.merged_variable_renames"
    flat = _flatten(FLATTEN_CASES[0])
    assert hasattr(flat.metadata, "merged_variable_renames")


@pytest.mark.parametrize("case", FLATTEN_CASES, ids=[c["id"] for c in FLATTEN_CASES])
def test_the_merge_records_which_names_it_deleted(case):
    """The rename map is what a consumer addressing a state by name resolves
    through, so it is part of the flattened form's contract, not a private
    detail of the merge."""
    flat = _flatten(case)
    assert dict(flat.metadata.merged_variable_renames) == case["merged_variable_renames"]


@pytest.mark.parametrize("case", FLATTEN_CASES, ids=[c["id"] for c in FLATTEN_CASES])
def test_the_merged_away_name_survives_nowhere(case):
    """The deleted spelling is gone from the variable tables AND from every
    equation. A reference left behind is a reference to nothing."""
    flat = _flatten(case)
    assert list(flat.state_variables) == case["state_variables"]
    for gone in case["no_equation_references"]:
        assert gone not in flat.state_variables
        assert gone not in flat.parameters
        assert gone not in flat.observed_variables
        for eq in flat.equations:
            rendered = f"{_expr_to_string(eq.lhs)} = {_expr_to_string(eq.rhs)}"
            assert gone not in rendered, (
                f"{case['id']}: equation still references the merged-away {gone!r}: {rendered}"
            )


@pytest.mark.parametrize("case", FLATTEN_CASES, ids=[c["id"] for c in FLATTEN_CASES])
def test_the_later_entry_lands_on_the_survivor(case):
    """The entry that named the dead spelling did its work — on the survivor.

    This is the non-vacuity anchor for the test above: deleting the reference
    would satisfy "the dead name survives nowhere" by doing nothing at all.
    """
    flat = _flatten(case)
    target = case["tendency_of"]
    tendencies = [eq for eq in flat.equations if _lhs_dependent_var(eq.lhs) == target]
    assert tendencies, f"{case['id']}: no equation defines {target}"
    rendered = _expr_to_string(tendencies[0].rhs)
    for name in case["tendency_references"]:
        assert name in rendered, (
            f"{case['id']}: D({target}) must reference {name!r}, got {rendered}"
        )


@pytest.mark.parametrize("case", OVERRIDE_CASES, ids=[c["id"] for c in OVERRIDE_CASES])
def test_an_override_key_naming_the_merged_away_state_resolves(case):
    """esm-spec §6.6.2's key resolution reaches through the merge's rename map.

    Both halves are asserted: the key lands on the survivor, and the value is
    the caller's rather than the state's declared default — which is what an
    unresolved key silently left in place.
    """
    flat = _flatten(case)
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        prob = esm_problem(flat, (0.0, 1.0), u0=dict(case["initial_conditions"]))
    assert prob.u0 == case["resolves_to"]
    for name, unresolved in case["default_without_resolution"].items():
        assert prob.u0[name] != unresolved


@pytest.mark.parametrize("case", OUTPUT_CASES, ids=[c["id"] for c in OUTPUT_CASES])
def test_a_name_keyed_read_of_the_result_resolves(case):
    """The solution is the one object a caller reading by name holds.

    Three things are pinned, and the third keeps the first two honest: the read
    lands on the survivor's row, it is the SAME row (not merely some row), and
    the reported row NAMES still carry only the surviving spelling — resolving a
    read must not invent a name the flattened system does not declare.
    """
    flat = _flatten(case)
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        sol = solve(esm_problem(flat, (0.0, 1.0)))

    dead, survivor = case["read_by_name"], case["same_row_as"]
    assert dead in sol, f"{case['id']}: {dead!r} must resolve through the merge map"
    assert (sol[dead] == sol[survivor]).all(), (
        f"{case['id']}: {dead!r} must read the SAME row as {survivor!r}"
    )
    assert sol.get(dead) is not None

    for gone in case["absent_from_row_names"]:
        assert gone not in sol.vars, (
            f"{case['id']}: resolving a read must not add {gone!r} to the row names"
        )
