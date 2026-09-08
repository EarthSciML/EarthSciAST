"""esm-spec §6.3.1's INDEXED LHS spelling for an array-shaped observed (#232).

§6.3.1 admits **two** LHS spellings for the equation that DEFINES an unknown —
bare (``y ~ f(…)``) and indexed (``y[i] ~ f(…)``, "which defines the whole array
``y``") — and reads the defining form through the LHS's **base name**: "an
arrayed definition is observed exactly as its scalar counterpart is". Neither
spelling is restricted by rank.

This binding classified by the LHS's SYNTAX instead, through
``classification.inlined_unknowns`` — the strict ``y ~ f(…)`` set §6.3.1
sanctions for *inlining specifically*, used as if it were the classification,
which §6.3.1 says it is not ("does not narrow the partition"). An array-shaped
observed written the indexed way therefore landed in ``state_variables``, where
nothing ever wrote it, and three things went wrong at once — all SILENT, which
is why #232 read Python as passing:

1. Asserting the observed itself at ``t > 0`` returned **0.0**, from its
   never-written state slot.
2. An indexed LHS with a **per-cell** RHS matched no driver case and was dropped
   with ``RuntimeWarning: unrecognized algebraic equation …``, freezing the state
   it constrained at its initial value.
3. A **bare whole-array** reader (``D(u) ~ w``) read that same zero slot, because
   the array build's algebraic elimination substitutes only INDEXED reads.

One cause, one fix, in two halves: ``flatten._normalize_indexed_observed_lhs``
rewrites the spelling to the bare one upstream of classification, and
``classification._base_name`` sees through the aggregate shell so §6.6.5's
observed-assertion lookup credits the name at all.

Every test below pins the indexed spelling against the BARE-spelling twin of the
same model. That is the actual contract: the spelling must not decide the answer.
"""

from __future__ import annotations

import json
import math
import warnings

import pytest

from earthsci_ast.classification import is_observed_unknown, observed_unknowns
from earthsci_ast.flatten import _normalize_indexed_observed_lhs, flatten
from earthsci_ast.parse import load_path
from earthsci_ast.pde_inline_tests import run_pde_tests
from earthsci_ast.problem import esm_problem

E2 = math.exp(2.0)


def _agg(expr, sym="k"):
    return {
        "op": "aggregate",
        "args": [],
        "output_idx": [sym],
        "ranges": {sym: {"from": "lev"}},
        "expr": expr,
    }


def _idx(name, sym="k"):
    return {"op": "index", "args": [name, sym]}


# w[k] ~ aggregate{k}(2*u[k]) — INDEXED LHS, whole-array RHS.
EQ_W_INDEXED = {"lhs": _agg(_idx("w")), "rhs": _agg({"op": "*", "args": [2.0, _idx("u")]})}
# w[k] ~ 2*u[k] — INDEXED LHS, PER-CELL RHS (no RHS aggregate).
EQ_W_INDEXED_PERCELL = {"lhs": _agg(_idx("w")), "rhs": {"op": "*", "args": [2.0, _idx("u")]}}
# w ~ aggregate{k}(2*u[k]) — the BARE-LHS twin, the control for every case.
EQ_W_BARE = {"lhs": "w", "rhs": _agg({"op": "*", "args": [2.0, _idx("u")]})}

# aggregate{k}(D(u[k])) ~ aggregate{k}(w[k]) — the indexed derivative spelling.
EQ_D_INDEXED = {
    "lhs": _agg({"op": "D", "args": [_idx("u")], "wrt": "t"}),
    "rhs": _agg(_idx("w")),
}
# D(u) ~ w — the BARE whole-array derivative spelling.
EQ_D_BARE = {"lhs": {"op": "D", "args": ["u"], "wrt": "t"}, "rhs": "w"}


def _doc(name, equations, assertions):
    """#232's model: w = 2u and D(u) = w, so u(t) = e^(2t) and w(t) = 2e^(2t)."""
    return {
        "esm": "1.0.0",
        "metadata": {"name": name, "authors": ["repro"]},
        "index_sets": {"lev": {"kind": "interval", "size": 4}},
        "models": {
            "Column": {
                "variables": {
                    "w": {"type": "unknown", "units": "1", "shape": ["lev"]},
                    "u": {
                        "type": "unknown",
                        "units": "1",
                        "default": 1.0,
                        "shape": ["lev"],
                    },
                },
                "equations": equations,
                "tests": [
                    {
                        "id": "t",
                        "time_span": {"start": 0.0, "end": 1.0},
                        "assertions": assertions,
                    }
                ],
            }
        },
    }


def _write(tmp_path, doc, name):
    path = tmp_path / name
    path.write_text(json.dumps(doc))
    return str(path)


def _actuals(tmp_path, name, equations, assertions):
    """``{variable: actual}`` from running the document's inline test."""
    path = _write(tmp_path, _doc(name, equations, assertions), name + ".esm.json")
    return {r.variable: r.actual for r in run_pde_tests(path)}


ASSERT_U = [{"variable": "u", "time": 1.0, "coords": {"lev": 1}, "expected": E2}]
ASSERT_U_AND_W = ASSERT_U + [
    {"variable": "w", "time": 1.0, "coords": {"lev": 1}, "expected": 2 * E2}
]


# --------------------------------------------------------------------------- #
# Symptom 1 — asserting the indexed-LHS observed itself
# --------------------------------------------------------------------------- #


def test_symptom_1_the_indexed_lhs_observed_is_readable_at_a_later_time(tmp_path):
    """Returned 0.0 — the never-written state slot — instead of 2·e²."""
    got = _actuals(tmp_path, "s1", [EQ_W_INDEXED, EQ_D_INDEXED], ASSERT_U_AND_W)

    assert got["w"] is not None
    assert got["w"] == pytest.approx(2 * E2, rel=1e-6)
    assert got["u"] == pytest.approx(E2, rel=1e-6)


def test_symptom_1_agrees_with_the_bare_spelling_twin(tmp_path):
    indexed = _actuals(tmp_path, "s1i", [EQ_W_INDEXED, EQ_D_INDEXED], ASSERT_U_AND_W)
    bare = _actuals(tmp_path, "s1b", [EQ_W_BARE, EQ_D_INDEXED], ASSERT_U_AND_W)

    assert indexed["w"] == pytest.approx(bare["w"], rel=1e-12)
    assert indexed["u"] == pytest.approx(bare["u"], rel=1e-12)


# --------------------------------------------------------------------------- #
# Symptom 2 — an indexed LHS with a per-cell RHS
# --------------------------------------------------------------------------- #


def test_symptom_2_a_per_cell_rhs_is_not_dropped(tmp_path):
    """The equation matched no driver case, so it was dropped with a warning and
    the state it constrains stayed frozen at its initial value 1.0."""
    with warnings.catch_warnings(record=True) as caught:
        warnings.simplefilter("always")
        got = _actuals(tmp_path, "s2", [EQ_W_INDEXED_PERCELL, EQ_D_INDEXED], ASSERT_U)

    dropped = [c for c in caught if "unrecognized algebraic equation" in str(c.message)]
    assert not dropped, f"equation dropped: {dropped[0].message}"
    assert got["u"] == pytest.approx(E2, rel=1e-6)


def test_symptom_2_agrees_with_the_bare_spelling_twin(tmp_path):
    """A per-cell RHS under the LHS's frame denotes the same whole array the
    aggregate-wrapped RHS does, so the two must give the same number."""
    percell = _actuals(tmp_path, "s2p", [EQ_W_INDEXED_PERCELL, EQ_D_INDEXED], ASSERT_U)
    bare = _actuals(tmp_path, "s2b", [EQ_W_BARE, EQ_D_INDEXED], ASSERT_U)

    assert percell["u"] == pytest.approx(bare["u"], rel=1e-12)


# --------------------------------------------------------------------------- #
# Symptom 3 — a bare whole-array derivative reading the indexed-LHS observed
# --------------------------------------------------------------------------- #


def test_symptom_3_a_bare_whole_array_derivative_reads_the_observed(tmp_path):
    """``D(u) ~ w`` read the zero state slot, because the array build's algebraic
    elimination substitutes only INDEXED reads — so ``u`` stayed at 1.0."""
    got = _actuals(tmp_path, "s3", [EQ_W_INDEXED, EQ_D_BARE], ASSERT_U)

    assert got["u"] == pytest.approx(E2, rel=1e-6)


def test_symptom_3_agrees_with_the_bare_spelling_twin(tmp_path):
    indexed = _actuals(tmp_path, "s3i", [EQ_W_INDEXED, EQ_D_BARE], ASSERT_U)
    bare = _actuals(tmp_path, "s3b", [EQ_W_BARE, EQ_D_BARE], ASSERT_U)

    assert indexed["u"] == pytest.approx(bare["u"], rel=1e-12)


def test_all_four_spelling_combinations_agree(tmp_path):
    """Two observed spellings x two derivative spellings: one model, one answer."""
    results = [
        _actuals(tmp_path, f"m{i}", [obs, drv], ASSERT_U)["u"]
        for i, (obs, drv) in enumerate(
            [
                (EQ_W_BARE, EQ_D_BARE),
                (EQ_W_BARE, EQ_D_INDEXED),
                (EQ_W_INDEXED, EQ_D_BARE),
                (EQ_W_INDEXED, EQ_D_INDEXED),
            ]
        )
    ]
    for got in results:
        assert got == pytest.approx(results[0], rel=1e-12)
        assert got == pytest.approx(E2, rel=1e-6)


# --------------------------------------------------------------------------- #
# The two halves of the fix, directly
# --------------------------------------------------------------------------- #


def test_flatten_classifies_the_indexed_definition_as_an_observed(tmp_path):
    """It landed in ``state_variables``, where nothing ever wrote it."""
    path = _write(tmp_path, _doc("c", [EQ_W_INDEXED, EQ_D_INDEXED], ASSERT_U), "c.esm.json")
    flat = flatten(load_path(path))

    assert "Column.w" in flat.observed_variables
    assert "Column.w" not in flat.state_variables
    assert list(flat.state_variables) == ["Column.u"]


def test_classification_credits_the_indexed_lhs_to_its_base_name(tmp_path):
    """``_base_name`` did not see through the aggregate shell, so §6.6.5's
    observed-assertion lookup was gated out before it ever looked."""
    path = _write(tmp_path, _doc("c", [EQ_W_INDEXED, EQ_D_INDEXED], ASSERT_U), "c.esm.json")
    model = load_path(path).models["Column"]

    assert observed_unknowns(model) == ["w"]
    assert is_observed_unknown(model, "w")


def test_the_normalizer_returns_its_input_by_identity_when_nothing_matches(tmp_path):
    """The bare spelling is already normal — no copy, no rewrite."""
    path = _write(tmp_path, _doc("c", [EQ_W_BARE, EQ_D_INDEXED], ASSERT_U), "c.esm.json")
    model = load_path(path).models["Column"]

    assert _normalize_indexed_observed_lhs(model) is model.equations


@pytest.mark.parametrize(
    "name,equation",
    [
        # A NON-IDENTITY gather is not a definition of the whole array.
        (
            "offset_gather",
            {
                "lhs": _agg({"op": "index", "args": ["w", {"op": "+", "args": ["k", 1]}]}),
                "rhs": _agg({"op": "*", "args": [2.0, _idx("u")]}),
            },
        ),
        # A GATED shell restricts which cells contribute; it is not the frame.
        (
            "filtered_shell",
            {
                "lhs": {
                    "op": "aggregate",
                    "args": [],
                    "output_idx": ["k"],
                    "ranges": {"k": {"from": "lev"}},
                    "expr": _idx("w"),
                    "filter": {"op": ">", "args": ["k", 1]},
                },
                "rhs": _agg({"op": "*", "args": [2.0, _idx("u")]}),
            },
        ),
        # A SCALAR reduction (no output_idx) is no frame at all.
        (
            "scalar_reduction",
            {
                "lhs": {
                    "op": "aggregate",
                    "args": [],
                    "output_idx": [],
                    "ranges": {"k": {"from": "lev"}},
                    "expr": _idx("w"),
                },
                "rhs": _agg({"op": "*", "args": [2.0, _idx("u")]}),
            },
        ),
    ],
)
def test_the_normalizer_declines_outside_its_narrow_recognition(tmp_path, name, equation):
    """Recognition mirrors Julia's ``_normalize_indexed_observed_lhs``: identity
    gather on the frame, no gating shell, non-empty ``output_idx``. Anything else
    passes through untouched, so nothing else in the corpus can move."""
    path = _write(tmp_path, _doc(name, [equation, EQ_D_INDEXED], ASSERT_U), name + ".esm.json")
    model = load_path(path).models["Column"]

    assert _normalize_indexed_observed_lhs(model) is model.equations


def test_the_normalizer_declines_a_target_with_no_declared_shape(tmp_path):
    """The two corpus equations that already use this LHS shape name a variable
    with NO declared shape (``arrayop/02`` and ``arrayop/04``); the rank guard is
    what leaves them byte-identical."""
    doc = _doc("noshape", [EQ_W_INDEXED, EQ_D_INDEXED], ASSERT_U)
    del doc["models"]["Column"]["variables"]["w"]["shape"]
    path = _write(tmp_path, doc, "noshape.esm.json")
    model = load_path(path).models["Column"]

    assert _normalize_indexed_observed_lhs(model) is model.equations


def test_the_indexed_spelling_still_routes_to_the_array_pathway(tmp_path):
    """The #231 routing arm and this normalization compose: the declared shape
    still decides the engine after the LHS is rewritten."""
    path = _write(tmp_path, _doc("p", [EQ_W_INDEXED, EQ_D_BARE], ASSERT_U), "p.esm.json")

    assert esm_problem(path, (0.0, 1.0)).pathway == "array"
