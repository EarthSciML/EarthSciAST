"""Per-term provenance through flatten (esm-libraries-spec §4.7.5, issue #539).

Every flattened equation carries ``contributions``: the ordered summands of its
right-hand side, each with the component or coupling entry that authored it. The
corpus (``tests/conformance/flatten/cases.json``) pins the rendered lists for
every binding; this module checks what a rendering cannot:

* the INVARIANT, by evaluation: ``body(eq)`` evaluates bit for bit to the
  left-fold sum of the contributions' values, at a sampled non-default state;
* the systems-order pair: the same contributions and origins in both argument
  orders, in ``rhs_A + rhs_B`` order;
* non-vacuity: two structurally identical contributions stay two;
* the type contract of :class:`TermOrigin` and the default contribution of an
  equation built without one.
"""

from __future__ import annotations

import json
import struct
import warnings
import zlib

import numpy as np
import pytest
from conftest import CONFORMANCE_DIR, FIXTURES_ROOT

from earthsci_ast import (
    Contribution,
    FlattenedEquation,
    TermOrigin,
    flatten,
    load_path,
    to_ascii,
)
from earthsci_ast.esm_types import ExprNode
from earthsci_ast.expression import free_variables
from earthsci_ast.numpy_interpreter import EvalContext, eval_expr

TP_DIR = CONFORMANCE_DIR / "term_provenance" / "fixtures"
TP_FIXTURES = sorted(p.name for p in TP_DIR.glob("*.esm"))
CORPUS_CASES = json.loads((CONFORMANCE_DIR / "flatten" / "cases.json").read_text())["cases"]


def _flatten(path):
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        return flatten(load_path(str(path)))


def _origins(contribution: Contribution) -> list[dict]:
    return [o.to_json() for o in contribution.origins]


def _equation(flat, lhs: str) -> FlattenedEquation:
    matches = [eq for eq in flat.equations if to_ascii(eq.lhs) == lhs]
    assert len(matches) == 1, f"expected one equation {lhs!r}, got {len(matches)}"
    return matches[0]


# --- the invariant, by evaluation --------------------------------------------


#: Independent sampled states per equation. One state can sum to the same bits
#: in every association by chance; several make that vanishingly unlikely.
SAMPLES = 8


def _sample(name: str, salt: int) -> float:
    """A deterministic, non-default value for ``name`` in sample ``salt``. The
    magnitudes spread over many decades so that summing in another association
    rounds differently, which is what lets a bit comparison see the order."""
    h = zlib.crc32(f"{salt}:{name}".encode())
    return (1.0 + (h % 100003) / 100003.0) * 10.0 ** ((h >> 17) % 13 - 6)


def _bits(x: float) -> bytes:
    return struct.pack("<d", float(x))


class _Unevaluable(Exception):
    pass


def _context(flat, names: set[str], loops: set[str], salt: int) -> EvalContext:
    """An evaluation context binding every free name of the equation: a scalar
    name to a sampled value, a lifted state to a sampled column."""
    layout: dict[str, slice] = {}
    shapes: dict[str, tuple[int, ...]] = {}
    values: list[float] = []
    params: dict[str, float] = {}
    for name in sorted(names - loops - {"t"}):
        shape = flat.lifted_shapes.get(name)
        if shape is None:
            var = flat.state_variables.get(name) or flat.parameters.get(name)
            if var is not None and var.shape:
                raise _Unevaluable(f"{name} is arrayed outside the lift")
            params[name] = _sample(name, salt)
            continue
        n = int(np.prod(shape))
        layout[name] = slice(len(values), len(values) + n)
        shapes[name] = tuple(shape)
        values.extend(_sample(f"{name}[{k}]", salt) for k in range(n))
    return EvalContext(
        state_layout=layout,
        state_shapes=shapes,
        param_values=params,
        observed_values={},
        y=np.asarray(values, dtype=float),
        t=0.75,
        index_sets=dict(flat.index_sets),
    )


def _cells(eq: FlattenedEquation):
    """The per-cell loop bindings of a lifted equation, or one empty binding."""
    if not eq.lifted:
        yield {}
        return
    ranges = eq.rhs.ranges
    loops = list(eq.rhs.output_idx)
    grid = [range(int(ranges[k][0]), int(ranges[k][1]) + 1) for k in loops]
    for point in np.ndindex(*[len(r) for r in grid]):
        yield {k: grid[d][point[d]] for d, k in enumerate(loops)}


def _check_invariant(flat, eq: FlattenedEquation) -> tuple[bool, bool]:
    """Assert the invariant for one equation at ``SAMPLES`` states.

    Returns ``(evaluated, discriminating)``: ``evaluated`` is False when this
    interpreter cannot evaluate the equation (an undiscretized spatial operator,
    an arrayed operand outside the lift); ``discriminating`` is True when some
    sampled state sums the contributions to different bits in the right-nested
    association, i.e. the check could tell the two orders apart."""
    names: set[str] = set()
    for c in eq.contributions:
        names |= free_variables(c.expr)
    loops = set(eq.rhs.output_idx) if eq.lifted else set()
    discriminating = False
    try:
        for salt in range(SAMPLES):
            ctx = _context(flat, names, loops, salt)
            for cell in _cells(eq):
                ctx.locals = dict(cell)
                body = float(eval_expr(eq.body, ctx))
                parts = [float(eval_expr(c.expr, ctx)) for c in eq.contributions]
                fold = parts[0]
                for part in parts[1:]:
                    fold = fold + part
                assert _bits(body) == _bits(fold), (
                    f"{to_ascii(eq.lhs)} at {cell}: body {body!r} != left fold {fold!r} of {parts}"
                )
                right = parts[-1]
                for part in reversed(parts[:-1]):
                    right = part + right
                discriminating = discriminating or _bits(right) != _bits(fold)
    except _Unevaluable:
        return False, False
    except AssertionError:
        raise
    except Exception:  # noqa: BLE001 -- an operator this interpreter cannot evaluate
        return False, False
    return True, discriminating


@pytest.mark.parametrize("fixture", TP_FIXTURES)
def test_body_is_the_left_fold_of_the_contributions(fixture):
    flat = _flatten(TP_DIR / fixture)
    results = [_check_invariant(flat, eq) for eq in flat.equations]
    # Only `grad` without a discretization is out of this interpreter's reach.
    if fixture != "placeholder_expansion.esm":
        assert all(ok for ok, _ in results), f"{fixture}: some equations could not be evaluated"
    # With three or more contributions the check must be able to see the order.
    for eq, (ok, discriminating) in zip(flat.equations, results):
        if ok and len(eq.contributions) >= 3:
            assert discriminating, f"{fixture}: {to_ascii(eq.lhs)} cannot tell sum orders apart"


@pytest.mark.parametrize("case", CORPUS_CASES, ids=[c["id"] for c in CORPUS_CASES])
def test_corpus_equations_keep_the_invariant(case):
    """The same check over every corpus fixture, for the equations this
    interpreter can evaluate at a scalar state."""
    flat = _flatten(FIXTURES_ROOT / case["fixture"])
    for eq in flat.equations:
        _check_invariant(flat, eq)


@pytest.mark.parametrize("case", CORPUS_CASES, ids=[c["id"] for c in CORPUS_CASES])
def test_every_contribution_has_an_author(case):
    """Origins are non-empty and deduplicated for every equation flatten
    produces; the empty list is only for equations built outside flatten."""
    flat = _flatten(FIXTURES_ROOT / case["fixture"])
    for eq in flat.equations:
        assert eq.contributions
        for c in eq.contributions:
            assert c.origins, f"{case['id']}: {to_ascii(eq.lhs)} has an unattributed term"
            assert len(set(c.origins)) == len(c.origins)


# --- the step table, row by row ----------------------------------------------


def test_systems_order_changes_order_not_origins():
    ab = _equation(_flatten(TP_DIR / "systems_order_ab.esm"), "D(Chem.O3)/Dt")
    ba = _equation(_flatten(TP_DIR / "systems_order_ba.esm"), "D(Chem.O3)/Dt")
    as_pairs = lambda eq: [(to_ascii(c.expr), _origins(c)) for c in eq.contributions]  # noqa: E731
    assert sorted(as_pairs(ab), key=str) == sorted(as_pairs(ba), key=str)
    assert [o for _, o in as_pairs(ab)] == [[{"component": "Chem"}], [{"component": "Sink"}]]
    assert [o for _, o in as_pairs(ba)] == [[{"component": "Sink"}], [{"component": "Chem"}]]


def test_structurally_identical_contributions_stay_two():
    eq = _equation(_flatten(TP_DIR / "non_vacuity.esm"), "D(Chem.O3)/Dt")
    tail = eq.contributions[1:]
    assert [to_ascii(c.expr) for c in tail] == ["Emis.flux", "Emis.flux"]
    assert [_origins(c) for c in tail] == [[{"component": "OpA"}], [{"component": "OpB"}]]


def test_chained_compose_names_every_author():
    flat = _flatten(FIXTURES_ROOT / "coupling" / "chained_operator_compose.esm")
    eq = _equation(flat, "D(Chem.O3)/Dt")
    assert [_origins(c) for c in eq.contributions] == [
        [{"component": c}] for c in ("Src", "Sink", "Chem", "Adv")
    ]
    # The slot owner is not provenance.
    assert eq.source_system == "Src"


def test_additive_couple_appends_and_creates_with_the_coupling_index():
    flat = _flatten(TP_DIR / "couple_additive.esm")
    co2 = _equation(flat, "D(Atm.CO2)/Dt")
    assert [_origins(c) for c in co2.contributions] == [[{"component": "Atm"}], [{"coupling": 1}]]
    # The variable_map that ran afterwards rewrote the input, not the author.
    assert to_ascii(co2.contributions[1].expr) == "Ocean.Fref"
    o2 = _equation(flat, "D(Atm.O2)/Dt")
    assert [_origins(c) for c in o2.contributions] == [[{"coupling": 1}], [{"coupling": 1}]]
    # A parameter target takes no tendency.
    assert not [eq for eq in flat.equations if "Atm.flux" in to_ascii(eq.lhs)]


def test_multiplicative_couple_collapses_to_the_union():
    eq = _equation(_flatten(TP_DIR / "couple_multiplicative.esm"), "D(Chem.O3)/Dt")
    assert len(eq.contributions) == 1
    assert _origins(eq.contributions[0]) == [
        {"component": "Chem"},
        {"component": "Sink"},
        {"coupling": 1},
    ]


def test_translate_factor_collapses_only_a_multi_contribution_b():
    flat = _flatten(TP_DIR / "translate_factor.esm")
    y = _equation(flat, "D(Host.Y)/Dt")
    assert [_origins(c) for c in y.contributions] == [
        [{"component": "Host"}],
        [{"component": "Chem"}, {"component": "Sink"}],
    ]
    w = _equation(flat, "D(Host.W)/Dt")
    assert [_origins(c) for c in w.contributions] == [
        [{"component": "Host"}],
        [{"component": "Chem"}],
    ]


def test_expression_transform_observed_is_authored_by_the_coupling():
    flat = _flatten(TP_DIR / "variable_map.esm")
    assert [_origins(c) for c in _equation(flat, "Chem.e").contributions] == [[{"coupling": 1}]]
    o3 = _equation(flat, "D(Chem.O3)/Dt")
    assert [_origins(c) for c in o3.contributions] == [[{"component": "Chem"}]]


def test_resolved_time_derivative_keeps_the_referencing_origin():
    eq = _equation(_flatten(TP_DIR / "rhs_time_derivative.esm"), "Diag.rate")
    assert [_origins(c) for c in eq.contributions] == [[{"component": "Diag"}]]
    assert "D(" not in to_ascii(eq.rhs)


def test_the_lift_indexes_inside_each_contribution():
    flat = _flatten(TP_DIR / "pointwise_lift.esm")
    (eq,) = [e for e in flat.equations if e.lifted]
    assert isinstance(eq.rhs, ExprNode) and eq.rhs.op == "faq"
    assert eq.body is eq.rhs.expr
    assert [_origins(c) for c in eq.contributions] == [
        [{"component": c}] for c in ("Chem", "Src", "Adv")
    ]


# --- the types ---------------------------------------------------------------


def test_term_origin_names_exactly_one_author():
    assert TermOrigin(component="A.B").to_json() == {"component": "A.B"}
    assert TermOrigin(coupling=0).to_json() == {"coupling": 0}
    with pytest.raises(ValueError):
        TermOrigin()
    with pytest.raises(ValueError):
        TermOrigin(component="A", coupling=0)


def test_an_equation_built_outside_flatten_has_one_unattributed_contribution():
    eq = FlattenedEquation(lhs="x", rhs=ExprNode(op="+", args=["a", "b"]), source_system="M")
    assert len(eq.contributions) == 1
    assert eq.contributions[0].expr is eq.rhs
    assert eq.contributions[0].origins == []


def test_table_lookup_lowering_keeps_the_contributions():
    """`esm_problem` lowers a caller-flattened system's `table_lookup` nodes; the
    rewrite happens inside each contribution, so origins survive it."""
    from earthsci_ast.lower_table_lookup import lower_flattened_table_lookups

    flat = _flatten(CONFORMANCE_DIR / "function_tables" / "linear" / "fixture.esm")
    lowered = lower_flattened_table_lookups(flat)
    assert lowered is not flat
    changed = 0
    for before, after in zip(flat.equations, lowered.equations):
        assert [_origins(c) for c in after.contributions] == [
            _origins(c) for c in before.contributions
        ]
        assert "table_lookup" not in json.dumps(str(after.contributions))
        changed += to_ascii(after.rhs) != to_ascii(before.rhs)
        ok, _ = _check_invariant(lowered, after)
        assert ok
    assert changed
