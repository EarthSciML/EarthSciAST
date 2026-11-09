"""
Structural-validation conformance for the aggregate / semiring / index-set
fixtures (bead ess-my4.1.7).

Every fixture under ``tests/valid/faq/`` is schema-valid AND must pass the
full structural ``validate()`` verdict — not merely schema validation. These
fixtures exercise the aggregate IR: LHS-aggregate ODEs (``op:aggregate`` whose
contracted body is ``D(index(v, i))``), relational element assignments
(``index(v, i) = aggregate(...)`` from skolem / distinct / rank), and contracted
index symbols (``i``, ``j``, ``e``).

The Python structural pass counts one equation entry per declared equation and
does not walk equation expressions for undefined references, so it recognises an
LHS-aggregate equation as the equation for its state variable and never flags a
contracted index symbol — i.e. it is structurally aggregate-clean. This module
locks that contract in (the TypeScript binding asserts the same in
``faq-fixtures.test.ts``); a regression that makes ``validate()`` reject a
schema-valid aggregate model — e.g. a spurious ``equation_count_mismatch`` or
``undefined_variable`` — fails here.

RFC: ``docs/content/rfcs/semiring-faq-unified-ir.md`` §5.1 / §5.2 / §8.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import List

import pytest
from conftest import CONFORMANCE_DIR, INVALID_DIR, VALID_DIR

from earthsci_ast.validation import validate_text


_FIXTURES_DIR = VALID_DIR / "faq"


def _collect_fixtures() -> List[Path]:
    if not _FIXTURES_DIR.is_dir():
        return []
    return sorted(_FIXTURES_DIR.glob("*.esm"))


def test_has_aggregate_fixtures() -> None:
    assert _collect_fixtures(), f"no aggregate fixtures found under {_FIXTURES_DIR}"


@pytest.mark.parametrize("fixture_path", _collect_fixtures(), ids=lambda p: p.name)
def test_aggregate_fixture_structurally_valid(fixture_path: Path) -> None:
    """A schema-valid aggregate fixture must also pass the structural verdict."""
    data = json.loads(fixture_path.read_text())

    result = validate_text(json.dumps(data))

    assert not result.schema_errors, (
        f"{fixture_path.name}: unexpected schema errors: "
        f"{[e.message for e in result.schema_errors]}"
    )
    assert not result.structural_errors, (
        f"{fixture_path.name}: unexpected structural errors: "
        f"{[(e.code, e.path, e.message) for e in result.structural_errors]}"
    )
    assert result.is_valid, f"{fixture_path.name}: validate().is_valid is False"


_AGNOSTIC_LEAF = CONFORMANCE_DIR / "expression_templates" / "inject_agnostic_faq" / "fixture.esm"


def test_agnostic_leaf_aggregate_range_is_not_undefined_index_set() -> None:
    """A §9.7.10 discretization-agnostic leaf declares no `index_sets` of its own.

    Its registry arrives from a grid library injected into the component's scope
    at mount / test time (§6.6.6), so an `aggregate` range naming a set the
    document does not declare is NOT decidable at standalone load and MUST NOT
    be reported as ``undefined_index_set`` — mirroring §9.6.1, where
    ``template_constraint_unknown_index_set`` does not run for a library file
    validated standalone. Before issue #185 the check resolved against
    ``data["index_sets"]`` unconditionally, so every conforming leaf was
    rejected at ``load_path()``.
    """
    result = validate_text(_AGNOSTIC_LEAF.read_text())

    assert not result.schema_errors, [e.message for e in result.schema_errors]
    assert [e.code for e in result.structural_errors] == []
    assert result.is_valid


def test_undeclared_range_still_rejected_when_the_document_declares_a_registry() -> None:
    """The negative control: the deferral is scoped to a document with NO registry.

    A document that declares one is resolved against it, so a typo'd `from` name
    is still an ``undefined_index_set`` at validate() — the typo-catching value
    the issue asked to preserve.
    """
    fixture = INVALID_DIR / "faq" / "undeclared_from_name.esm"

    result = validate_text(fixture.read_text())

    assert not result.is_valid
    assert "undefined_index_set" in {e.code for e in result.structural_errors}


def test_ragged_range_without_a_values_gather_is_rejected() -> None:
    """Issue #259: a range over a ``kind: "ragged"`` index set binds the POSITION
    k in 1..offsets[parent], not a member (esm-spec §4.3.1). A body that never
    reads the set's ``values`` array therefore reads positions -- 10, 30, 60 where
    the author meant 10, 50, 150 -- and validated clean. It is now
    ``ragged_values_not_gathered``, with a message that shows the gather."""
    fixture = INVALID_DIR / "faq" / "ragged_values_not_gathered.esm"

    result = validate_text(fixture.read_text())

    assert not result.is_valid
    found = [e for e in result.structural_errors if e.code == "ragged_values_not_gathered"]
    assert [e.path for e in found] == ["/models/RaggedValuesNotGathered/equations/3/rhs"]
    assert "index(parentMember, i, j)" in found[0].message


def test_ragged_range_with_the_values_gather_is_valid() -> None:
    """The positive control: the same sum with ``index(parentMember, i, j)``
    gathered in the body is the defined spelling and validates clean."""
    fixture = VALID_DIR / "faq" / "ragged_member_gather.esm"

    result = validate_text(fixture.read_text())

    assert [e.code for e in result.structural_errors] == []
    assert result.is_valid


def test_faq_filter_reading_a_shaped_variable_bare_is_rejected() -> None:
    """Issue #441: a ``faq`` filter naming a shaped variable bare. With two
    output indices Rust's reference ignored it silently and this binding's
    whole-box tier aligned it with the box's last axis. It is now
    ``faq_bare_array_operand`` at the containing field (esm-spec §4.3.1)."""
    fixture = INVALID_DIR / "faq" / "bare_array_operand_filter.esm"

    result = validate_text(fixture.read_text())

    assert not result.is_valid
    found = [e for e in result.structural_errors if e.code == "faq_bare_array_operand"]
    assert [e.path for e in found] == ["/models/Probe/equations/2/rhs"]
    assert found[0].details["variable"] == "a_val"
    assert found[0].details["field"] == "filter"


def test_faq_indexed_filter_over_two_outputs_is_valid() -> None:
    """The positive control: the filter read through ``index(a_val, i)``."""
    fixture = (
        CONFORMANCE_DIR / "faq_pointwise_filter" / "fixtures" / "indexed_filter_two_outputs.esm"
    )
    result = validate_text(fixture.read_text())
    assert [e.code for e in result.structural_errors] == []


def _bare_operand_doc(filter_expr, *, templates=None, a_size=2):
    """A two-output ``faq`` over two equal-extent index sets whose filter is
    ``filter_expr`` (``a_val = [1, 2]``, ``c_val = [10, 20]``)."""
    idx = lambda v, s: {"op": "index", "args": [v, s]}  # noqa: E731
    model = {
        "variables": {
            "a_val": {"type": "unknown", "units": "1", "shape": ["a_rows"]},
            "c_val": {"type": "unknown", "units": "1", "shape": ["c_rows"]},
            "y": {"type": "unknown", "units": "1", "shape": ["a_rows", "c_rows"]},
        },
        "equations": [
            {"lhs": "a_val", "rhs": {"op": "const", "args": [], "value": [1.0, 2.0]}},
            {"lhs": "c_val", "rhs": {"op": "const", "args": [], "value": [10.0, 20.0]}},
            {
                "lhs": "y",
                "rhs": {
                    "op": "faq",
                    "args": [],
                    "output_idx": ["i", "g"],
                    "ranges": {"i": {"from": "a_rows"}, "g": {"from": "c_rows"}},
                    "filter": filter_expr,
                    "expr": {"op": "*", "args": [idx("a_val", "i"), idx("c_val", "g")]},
                },
            },
        ],
    }
    if templates:
        model["expression_templates"] = templates
    return {
        "esm": "1.2.0",
        "metadata": {"name": "bare_operand", "authors": ["test"]},
        "index_sets": {
            "a_rows": {"kind": "interval", "size": a_size},
            "c_rows": {"kind": "interval", "size": 2},
        },
        "models": {"M": model},
    }


def test_faq_bare_filter_through_a_template_is_refused_at_build() -> None:
    """The issue's own spelling: the bare name arrives through an
    ``apply_expression_template`` binding, which ``validate`` cannot see into.
    The build front door checks the expanded system and refuses it by code,
    under both compilers -- before this the native whole-box tier aligned
    ``a_val`` with ``g`` (the extents are equal) and returned a wrong number."""
    from earthsci_ast.problem import esm_problem

    gate = {"op": "ifelse", "args": [{"op": ">", "args": ["x", 1.5]}, 1.0, 0.0]}
    doc = _bare_operand_doc(
        {"op": "apply_expression_template", "args": [], "name": "gate", "bindings": {"x": "a_val"}},
        templates={"gate": {"params": ["x"], "body": gate}},
    )
    for compiler in ("interpreter", "native"):
        with pytest.raises(Exception, match="faq_bare_array_operand"):
            esm_problem(doc, (0.0, 0.0), compiler=compiler)


def test_whole_box_filter_mask_of_the_wrong_rank_declines() -> None:
    """Defense in depth for an array whose shape no declaration states: a
    whole-box filter value whose rank is neither 0 nor the box's raises, so the
    tier declines rather than letting numpy broadcasting pick the axis."""
    import numpy as np

    from earthsci_ast.numpy_interpreter import _box_aligned_mask

    assert _box_aligned_mask(np.ones((2, 2)), 2).dtype == bool
    assert _box_aligned_mask(np.asarray(1.0), 2).ndim == 0
    with pytest.raises(ValueError, match="not the node's symbols"):
        _box_aligned_mask(np.ones(2), 2)


@pytest.mark.parametrize(
    ("name", "path"),
    [
        ("bare_array_operand_derivative.esm", "/models/Probe/equations/0/rhs"),
        ("bare_array_operand_subsystem.esm", "/models/Host/subsystems/Probe/equations/2/rhs"),
        ("bare_array_operand_beside_template.esm", "/models/Probe/equations/0/rhs"),
    ],
)
def test_faq_bare_array_operand_fixture_pins(name, path) -> None:
    """The derivative left-hand side exempts nothing, the check reaches inline
    subsystems, and a template application is opaque while a bare read beside
    it is not: exactly one finding each."""
    result = validate_text((INVALID_DIR / "faq" / name).read_text())
    found = [e for e in result.structural_errors if e.code == "faq_bare_array_operand"]
    assert [e.path for e in found] == [path]


def test_faq_bare_array_operand_beside_template_names_the_bare_read() -> None:
    result = validate_text(
        (INVALID_DIR / "faq" / "bare_array_operand_beside_template.esm").read_text()
    )
    found = [e for e in result.structural_errors if e.code == "faq_bare_array_operand"]
    assert [e.details["variable"] for e in found] == ["w"]


def test_template_application_is_opaque_to_validate() -> None:
    """An array bound to a template argument inside a faq body is not a bare
    read at validation (esm-spec §4.3.1); its expansion is the build's to
    check."""
    doc = json.loads((INVALID_DIR / "faq" / "bare_array_operand_beside_template.esm").read_text())
    doc["models"]["Probe"]["equations"][0]["rhs"]["expr"]["args"][1] = {
        "op": "index",
        "args": ["w", "i"],
    }
    result = validate_text(json.dumps(doc))
    assert [e.code for e in result.structural_errors] == []


def test_derivative_state_delivered_bare_by_a_template_is_refused_at_build() -> None:
    """``D(y) ~ faq(… twice(y) …)``: the template hides the bare ``y`` from
    validate, and the build check no longer exempts a derivative's own state."""
    from earthsci_ast.problem import esm_problem

    doc = json.loads((INVALID_DIR / "faq" / "bare_array_operand_derivative.esm").read_text())
    model = doc["models"]["Probe"]
    model["expression_templates"] = {
        "twice": {"params": ["x"], "body": {"op": "*", "args": [2.0, "x"]}}
    }
    model["equations"][0]["rhs"]["expr"]["args"][1] = {
        "op": "apply_expression_template",
        "args": [],
        "name": "twice",
        "bindings": {"x": "y"},
    }
    assert validate_text(json.dumps(doc)).structural_errors == []
    for compiler in ("interpreter", "native"):
        with pytest.raises(Exception, match="faq_bare_array_operand"):
            esm_problem(doc, (0.0, 0.0), compiler=compiler)


def test_bare_read_of_an_inferred_shape_is_refused_at_build() -> None:
    """``a_val`` declares no shape; its defining faq makes it an array over
    ``a_rows``. validate reads declarations only, so it passes there; the build
    reads inferred shapes too, as Julia's does after shape promotion."""
    from earthsci_ast.problem import esm_problem

    doc = _bare_operand_doc(
        {"op": "ifelse", "args": [{"op": ">", "args": ["a_val", 1.5]}, 1.0, 0.0]}
    )
    model = doc["models"]["M"]
    del model["variables"]["a_val"]["shape"]
    model["variables"]["base"] = {
        "type": "parameter",
        "units": "1",
        "shape": ["a_rows"],
        "default": [1.0, 2.0],
    }
    model["equations"][0]["rhs"] = {
        "op": "faq",
        "args": [],
        "output_idx": ["i"],
        "ranges": {"i": {"from": "a_rows"}},
        "expr": {"op": "index", "args": ["base", "i"]},
    }
    assert validate_text(json.dumps(doc)).structural_errors == []
    for compiler in ("interpreter", "native"):
        with pytest.raises(Exception, match="faq_bare_array_operand"):
            esm_problem(doc, (0.0, 0.0), compiler=compiler)


def test_flat_entry_filter_mask_must_cover_every_entry() -> None:
    """The flat-entry tiers bind each symbol to one value per entry, so a filter
    value is 0-D or exactly one per entry. A length-1 array is not stretched
    over the entries and a rank-2 one is not flattened: the tier declines."""
    import numpy as np

    from earthsci_ast.esm_types import ExprNode
    from earthsci_ast.numpy_interpreter import (
        EvalContext,
        _entry_aligned_mask,
        _fold_ragged_entries,
    )

    assert _entry_aligned_mask(np.asarray([1.0, 0.0, 1.0]), 3).tolist() == [True, False, True]
    assert _entry_aligned_mask(np.asarray(1.0), 3).tolist() == [True, True, True]
    for bad in (np.ones(1), np.ones((3, 1))):
        with pytest.raises(ValueError, match="not the node's symbols"):
            _entry_aligned_mask(bad, 3)

    ctx = EvalContext(
        state_layout={}, state_shapes={}, param_values={}, observed_values={}, y=np.zeros(0), t=0.0
    )
    body = ExprNode(op="faq", args=[], expr=1.0)
    row = np.array([0, 0, 1])
    bindings = {"j": np.array([1.0, 2.0, 1.0])}
    one = ExprNode(op="const", args=[], value=[1.0])
    assert _fold_ragged_entries(body, ctx, row, bindings, 2, None, "+", 0.0, "t") is not None
    assert _fold_ragged_entries(body, ctx, row, bindings, 2, one, "+", 0.0, "t") is None
