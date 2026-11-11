"""Enum lowering (esm-spec §9.3): ``enum`` ops resolve to ``const`` integers
against the ``enums`` block of the file that wrote them."""

from __future__ import annotations

import json

import pytest
from conftest import INVALID_DIR, VALID_DIR

from earthsci_ast import load_path, load_string
from earthsci_ast.enums import EnumLoweringError
from earthsci_ast.numpy_interpreter import evaluate


def test_enums_lowered_to_const():
    """End-to-end: ``enum`` ops are resolved to ``const`` integers at load."""
    fixture = VALID_DIR / "enums_categorical_lookup.esm"
    file = load_path(fixture)
    assert "season" in file.enums
    assert file.enums["season"]["summer"] == 3
    assert file.enums["land_use_class"]["deciduous_forest"] == 3

    # `r_c` is an OBSERVED unknown: 1.0.0 has no variable `expression` field, so
    # its definition is the bare-variable-LHS equation naming it.
    model = file.models["DryDep"]
    defining = [eq for eq in model.equations if eq.lhs == "r_c"]
    assert len(defining) == 1
    expr = defining[0].rhs
    # `index` op with two enum-resolved arguments — both should now be `const` ints.
    assert expr.op == "index"
    assert expr.args[1].op == "const"
    assert expr.args[1].value == 3  # summer
    assert expr.args[2].op == "const"
    assert expr.args[2].value == 3  # deciduous_forest


def test_zero_and_negative_enum_members_load_and_resolve_to_themselves():
    """An ``enums`` member may be ANY integer (esm-spec §9.3; CONFORMANCE_SPEC,
    "An ``enums`` Member Is a Code, Not a Position").

    The schema used to carry ``minimum: 1`` on
    ``EnumDeclaration.additionalProperties``, so a zero-valued identifier could
    not be named at all -- and MOVES has load-bearing ones:
    ``operatingmode.opModeID = 0`` is Braking (an emitting mode with its own
    rate) and ``opmodepolprocassoc.polProcessID = -1`` marks the drive-cycle
    modes associated with no pollutant/process.

    Both halves are pinned here: the document LOADS, and each member resolves
    to EXACTLY its declared integer -- a binding that accepted the document but
    clamped or dropped the sign would still be wrong.
    """
    fixture = VALID_DIR / "enums_zero_and_negative.esm"
    file = load_path(fixture)
    assert file.enums["operating_mode"]["Braking"] == 0
    assert file.enums["pol_process"]["Unassociated"] == -1

    model = file.models["EnumsZeroAndNegative"]
    defining = [eq for eq in model.equations if eq.lhs == "mode_code"]
    assert len(defining) == 1
    expr = defining[0].rhs
    assert expr.op == "makearray"

    # values[0] — the zero-valued member; values[1] — the negative one.
    assert expr.values[0].op == "const"
    assert expr.values[0].value == 0
    assert expr.values[1].op == "const"
    assert expr.values[1].value == -1

    # values[2] — both read through ARITHMETIC: 0 + 10*1 + (-1) = 9.
    assert evaluate(expr.values[0], {}) == 0.0
    assert evaluate(expr.values[1], {}) == -1.0
    assert evaluate(expr.values[2], {}) == 9.0


def test_enum_values_must_still_be_unique_including_zero():
    """Uniqueness is unchanged by the widened domain: ``0`` is a value like any
    other, so two symbols may not both map to it (esm-spec §9.3). Written as a
    separate case from the positive duplicate because a "seen set" that used
    ``0`` as its own sentinel would pass the positive case and let this one
    through."""

    def doc(enums: str) -> str:
        return (
            '{"esm":"1.0.0","metadata":{"name":"T","description":"d",'
            '"authors":["a"]},"enums":' + enums + ","
            '"models":{"M":{"variables":{"x":{"type":"unknown","units":"1"}},'
            '"equations":[{"lhs":"x","rhs":{"op":"enum","args":["m","A"]}}]}}}'
        )

    for enums in ('{"m":{"A":0,"B":0}}', '{"m":{"A":3,"B":3}}'):
        with pytest.raises(EnumLoweringError) as excinfo:
            load_string(doc(enums))
        assert excinfo.value.code == "enum_duplicate_value"
    # A duplicate no `enum` op names is still a defect of the block.
    with pytest.raises(EnumLoweringError) as excinfo:
        load_string(doc('{"m":{"A":1},"n":{"P":2,"Q":2}}'))
    assert excinfo.value.code == "enum_duplicate_value"
    # Distinct values, one of them zero and one negative, are fine, and values
    # may coincide ACROSS enums.
    loaded = load_string(doc('{"m":{"A":0,"B":-1},"n":{"P":0,"Q":-1}}'))
    assert loaded.enums["m"] == {"A": 0, "B": -1}


@pytest.mark.parametrize("fname", ["enum_duplicate_value.esm", "enum_duplicate_zero_value.esm"])
def test_enum_duplicate_value_fixtures_are_rejected_with_the_code(fname):
    """The two shared invalid fixtures pinned to `enum_duplicate_value` in
    tests/invalid/expected_errors.json (CONFORMANCE_SPEC §5.26.5)."""
    expected = json.loads((INVALID_DIR / "expected_errors.json").read_text())[fname]
    assert expected["resolver_error_code"] == "enum_duplicate_value"
    with pytest.raises(EnumLoweringError) as excinfo:
        load_path(INVALID_DIR / fname)
    assert excinfo.value.code == expected["resolver_error_code"]


def test_enum_duplicate_value_is_raised_at_an_edge_before_any_op_resolves():
    """The raw-JSON edge lowering (a mounted file or a template library, §9.3)
    checks the block before it resolves an op, so a duplicate is reported even
    when the op it lowers names an unduplicated member."""
    from earthsci_ast.enums import lower_enum_ops_for_file

    document = {"enums": {"m": {"A": 1, "B": 2, "C": 2}}}
    with pytest.raises(EnumLoweringError) as excinfo:
        lower_enum_ops_for_file(document, {"op": "enum", "args": ["m", "A"]})
    assert excinfo.value.code == "enum_duplicate_value"


def test_enums_lowered_in_bound_filter_and_key():
    """Regression: ``enum`` ops hidden in an integral bound, an aggregate
    ``filter`` predicate, or a ``distinct`` ``key`` must also lower to
    ``const``."""
    from earthsci_ast.enums import _lower_expr
    from earthsci_ast.esm_types import ExprNode

    enums = {"Season": {"summer": 2, "winter": 4}}

    integral = ExprNode(
        op="integral",
        args=[],
        lower=ExprNode(op="enum", args=["Season", "summer"]),
        upper=ExprNode(op="const", args=[], value=10),
        expr=ExprNode(op="const", args=[], value=1),
    )
    out = _lower_expr(integral, enums)
    assert out.lower.op == "const" and out.lower.value == 2

    agg = ExprNode(
        op="sum",
        args=[],
        filter=ExprNode(op="enum", args=["Season", "winter"]),
        expr=ExprNode(op="const", args=[], value=1),
    )
    out = _lower_expr(agg, enums)
    assert out.filter.op == "const" and out.filter.value == 4

    keyed = ExprNode(op="faq", args=[], key=ExprNode(op="enum", args=["Season", "summer"]))
    out = _lower_expr(keyed, enums)
    assert out.key.op == "const" and out.key.value == 2

    # Identity preserved when no child changes.
    plain = ExprNode(
        op="add",
        args=[ExprNode(op="const", args=[], value=1), ExprNode(op="const", args=[], value=2)],
    )
    assert _lower_expr(plain, enums) is plain


def test_serializer_roundtrip_enums_block():
    """The top-level ``enums`` block round-trips through serialize → reload."""
    from earthsci_ast import to_json

    fixture = VALID_DIR / "enums_categorical_lookup.esm"
    file = load_path(fixture)
    out = to_json(file)
    file2 = load_string(out)
    assert file2.enums == file.enums
