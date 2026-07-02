"""Unit tests for expression_templates / apply_expression_template
(esm-spec §9.6, docs/rfcs/ast-expression-templates.md, esm-giy).
"""
from __future__ import annotations

import copy
import json
import os

import numpy as np
import pytest

from earthsci_toolkit.esm_types import ExprNode
from earthsci_toolkit.parse import load
from earthsci_toolkit.lower_expression_templates import (
    ExpressionTemplateError,
    lower_expression_templates,
    reject_expression_templates_pre_v04,
)


ARRHENIUS_FIXTURE: dict = {
    "esm": "0.4.0",
    "metadata": {"name": "expr_template_smoke", "authors": ["esm-giy"]},
    "reaction_systems": {
        "chem": {
            "species": {
                "A": {"default": 1.0},
                "B": {"default": 0.5},
                "C": {"default": 0.0},
            },
            "parameters": {
                "T": {"default": 298.15},
                "num_density": {"default": 2.5e19},
            },
            "expression_templates": {
                "arrhenius": {
                    "params": ["A_pre", "Ea"],
                    "body": {
                        "op": "*",
                        "args": [
                            "A_pre",
                            {
                                "op": "exp",
                                "args": [
                                    {
                                        "op": "/",
                                        "args": [
                                            {"op": "-", "args": ["Ea"]},
                                            "T",
                                        ],
                                    }
                                ],
                            },
                            "num_density",
                        ],
                    },
                }
            },
            "reactions": [
                {
                    "id": "R1",
                    "substrates": [{"species": "A", "stoichiometry": 1}],
                    "products": [{"species": "B", "stoichiometry": 1}],
                    "rate": {
                        "op": "apply_expression_template",
                        "args": [],
                        "name": "arrhenius",
                        "bindings": {"A_pre": 1.8e-12, "Ea": 1500},
                    },
                },
                {
                    "id": "R2",
                    "substrates": [{"species": "B", "stoichiometry": 1}],
                    "products": [{"species": "C", "stoichiometry": 1}],
                    "rate": {
                        "op": "apply_expression_template",
                        "args": [],
                        "name": "arrhenius",
                        "bindings": {"A_pre": 3.4e-13, "Ea": 800},
                    },
                },
            ],
        }
    },
}


def _inline_arrhenius(A: float, Ea: float) -> dict:
    return {
        "op": "*",
        "args": [
            A,
            {
                "op": "exp",
                "args": [
                    {"op": "/", "args": [{"op": "-", "args": [Ea]}, "T"]}
                ],
            },
            "num_density",
        ],
    }


def test_expansion_at_load_strips_templates_and_produces_inline_ast():
    expanded = lower_expression_templates(copy.deepcopy(ARRHENIUS_FIXTURE))
    chem = expanded["reaction_systems"]["chem"]
    assert "expression_templates" not in chem
    assert chem["reactions"][0]["rate"] == _inline_arrhenius(1.8e-12, 1500)
    assert chem["reactions"][1]["rate"] == _inline_arrhenius(3.4e-13, 800)


def test_lower_expression_templates_is_deterministic():
    a = lower_expression_templates(copy.deepcopy(ARRHENIUS_FIXTURE))
    b = lower_expression_templates(copy.deepcopy(ARRHENIUS_FIXTURE))
    assert a == b


def test_files_without_templates_pass_through_unchanged():
    fixture = {
        "esm": "0.4.0",
        "metadata": {"name": "no_templates", "authors": ["t"]},
        "reaction_systems": {
            "chem": {
                "species": {"A": {}},
                "parameters": {"k": {"default": 1.0}},
                "reactions": [
                    {
                        "id": "R1",
                        "substrates": [{"species": "A", "stoichiometry": 1}],
                        "products": None,
                        "rate": "k",
                    }
                ],
            }
        },
    }
    out = lower_expression_templates(copy.deepcopy(fixture))
    # Same shape as input, no expression_templates block introduced.
    assert "expression_templates" not in out["reaction_systems"]["chem"]
    assert out["reaction_systems"]["chem"]["reactions"][0]["rate"] == "k"


def test_rejects_apply_expression_template_pre_v04():
    fixture = copy.deepcopy(ARRHENIUS_FIXTURE)
    fixture["esm"] = "0.3.5"
    with pytest.raises(ExpressionTemplateError) as excinfo:
        reject_expression_templates_pre_v04(fixture)
    assert excinfo.value.code == "apply_expression_template_version_too_old"


def test_rejects_unknown_template_name():
    fixture = copy.deepcopy(ARRHENIUS_FIXTURE)
    fixture["reaction_systems"]["chem"]["reactions"][0]["rate"]["name"] = "missing"
    with pytest.raises(ExpressionTemplateError) as excinfo:
        lower_expression_templates(fixture)
    assert excinfo.value.code == "apply_expression_template_unknown_template"


def test_rejects_bindings_missing_a_param():
    fixture = copy.deepcopy(ARRHENIUS_FIXTURE)
    del fixture["reaction_systems"]["chem"]["reactions"][0]["rate"]["bindings"]["Ea"]
    with pytest.raises(ExpressionTemplateError) as excinfo:
        lower_expression_templates(fixture)
    assert excinfo.value.code == "apply_expression_template_bindings_mismatch"


def test_rejects_extra_bindings_param():
    fixture = copy.deepcopy(ARRHENIUS_FIXTURE)
    fixture["reaction_systems"]["chem"]["reactions"][0]["rate"]["bindings"]["bogus"] = 99
    with pytest.raises(ExpressionTemplateError) as excinfo:
        lower_expression_templates(fixture)
    assert excinfo.value.code == "apply_expression_template_bindings_mismatch"


def test_rejects_nested_apply_in_template_body():
    fixture = copy.deepcopy(ARRHENIUS_FIXTURE)
    fixture["reaction_systems"]["chem"]["expression_templates"]["arrhenius"]["body"] = {
        "op": "apply_expression_template",
        "args": [],
        "name": "arrhenius",
        "bindings": {"A_pre": 1, "Ea": 1},
    }
    with pytest.raises(ExpressionTemplateError) as excinfo:
        lower_expression_templates(fixture)
    assert excinfo.value.code == "apply_expression_template_recursive_body"


def test_ast_valued_bindings_are_substituted():
    fixture = copy.deepcopy(ARRHENIUS_FIXTURE)
    fixture["reaction_systems"]["chem"]["reactions"][0]["rate"]["bindings"]["Ea"] = {
        "op": "*",
        "args": [3, "T"],
    }
    out = lower_expression_templates(fixture)
    rate = out["reaction_systems"]["chem"]["reactions"][0]["rate"]
    assert rate["op"] == "*"
    # The exp's argument (-Ea/T) should now contain the (3*T) sub-AST.
    exp_node = rate["args"][1]
    assert exp_node["op"] == "exp"
    div_node = exp_node["args"][0]
    assert div_node["op"] == "/"
    neg_node = div_node["args"][0]
    assert neg_node["op"] == "-"
    inner = neg_node["args"][0]
    assert isinstance(inner, dict)
    assert inner["op"] == "*"


def test_conformance_fixture_matches_expanded_form():
    """Loading the conformance fixture must yield the canonical expanded form
    pinned in `tests/conformance/expression_templates/arrhenius_smoke/expanded.esm`.
    """
    import os

    here = os.path.dirname(__file__)
    # tests/test_expression_templates.py → packages/earthsci_toolkit/tests
    # → packages/earthsci_toolkit → packages → repo root.
    root = os.path.abspath(os.path.join(here, "..", "..", ".."))
    fixture_path = os.path.join(
        root,
        "tests",
        "conformance",
        "expression_templates",
        "arrhenius_smoke",
        "fixture.esm",
    )
    expanded_path = os.path.join(
        root,
        "tests",
        "conformance",
        "expression_templates",
        "arrhenius_smoke",
        "expanded.esm",
    )
    with open(fixture_path) as fp:
        fixture_src = fp.read()
    with open(expanded_path) as fp:
        expanded_dict = json.load(fp)
    expanded_via_pass = lower_expression_templates(json.loads(fixture_src))
    assert (
        expanded_via_pass["reaction_systems"]["chem"]["reactions"]
        == expanded_dict["reaction_systems"]["chem"]["reactions"]
    )


def test_load_end_to_end_produces_inline_rate_in_typed_object():
    """The full ``load`` path should expand templates and surface inline ASTs."""
    file = load(json.dumps(ARRHENIUS_FIXTURE))
    rs = file.reaction_systems["chem"]
    rate = rs.reactions[0].rate_constant  # python binding stores rate as `rate_constant`
    # Walk the typed expression: should be `*` with three args, no apply op.
    assert rate.op == "*"

    def assert_no_apply(node):
        if hasattr(node, "op"):
            assert node.op != "apply_expression_template"
            for a in getattr(node, "args", []) or []:
                assert_no_apply(a)

    assert_no_apply(rate)


# ===========================================================================
# 0.8.0 rewrite engine — outermost-first + priority + bounded fixpoint
# (docs/content/rfcs/open-op-namespace-fixpoint-rewrite.md §8). Mirrors the
# Julia reference testset in EarthSciSerialization.jl/test/expression_templates_test.jl
# ("0.8.0 outermost-first + fixpoint") and test/tree_walk_test.jl.
# ===========================================================================


def _conf_dir(fix: str) -> str:
    # tests/test_expression_templates.py → packages/earthsci_toolkit/tests →
    # packages/earthsci_toolkit → packages → repo root.
    here = os.path.dirname(__file__)
    root = os.path.abspath(os.path.join(here, "..", "..", ".."))
    return os.path.join(root, "tests", "conformance", "expression_templates", fix)


def _conf_fixture(fix: str, name: str = "fixture.esm") -> dict:
    with open(os.path.join(_conf_dir(fix), name)) as fp:
        return json.load(fp)


def test_godunov_compound_rule_beats_inner_derivative():
    """Anti-regression for the old bottom-up single pass: the ``priority:100``
    compound rule must fire on the WHOLE ``sqrt(D(u,x)^2 + D(u,y)^2)`` before the
    ``priority:0`` central-difference ``D`` rule can lower either inner ``D``. The
    expanded form is ``godunov_coef * u`` — crucially with NO ``inv_dx`` (which
    only the per-derivative rule emits)."""
    out = lower_expression_templates(_conf_fixture("godunov_beats_inner_deriv"))
    got = out["models"]["m"]["variables"]
    exp = _conf_fixture("godunov_beats_inner_deriv", "expanded.esm")["models"]["m"]["variables"]
    assert got == exp
    assert got["grad_mag"]["expression"] == {"op": "*", "args": ["godunov_coef", "u"]}
    expr_json = json.dumps(got["grad_mag"]["expression"])
    assert "inv_dx" not in expr_json
    assert "godunov_coef" in expr_json


def test_nested_derivative_fixpoint_converges_across_passes():
    """laplacian → D(D(u,x),x)+D(D(u,y),y) (pass 1), then each nested D → stencil
    (pass 2). Exercises the bounded fixpoint: a produced body is re-scanned only in
    a SUBSEQUENT pass."""
    out = lower_expression_templates(_conf_fixture("fixpoint_nested_deriv"))
    got = out["models"]["m"]["variables"]
    exp = _conf_fixture("fixpoint_nested_deriv", "expanded.esm")["models"]["m"]["variables"]
    assert got == exp
    assert got["lap"]["expression"] == {
        "op": "+",
        "args": [
            {"op": "*", "args": ["inv_dx2", "u"]},
            {"op": "*", "args": ["inv_dy2", "u"]},
        ],
    }
    expr_json = json.dumps(got["lap"]["expression"])
    assert "laplacian" not in expr_json
    assert '"D"' not in expr_json


def test_self_reintroducing_rule_rejected_by_pass_bound():
    """A rule whose body re-introduces its own pattern never reaches a fixpoint;
    the engine rejects the file with ``rewrite_rule_nonterminating`` once
    MAX_REWRITE_PASSES productive passes have run (the pass bound — not a static
    pre-check — is the sole guard)."""
    with pytest.raises(ExpressionTemplateError) as excinfo:
        lower_expression_templates(_conf_fixture("nonterminating_rewrite"))
    assert excinfo.value.code == "rewrite_rule_nonterminating"


def test_unlowered_spatial_D_loads_but_errors_before_evaluation():
    """The op namespace is open (esm-spec §4.2): a spatial ``D`` with no rule is
    tolerated at LOAD. It is rejected with the uniform ``unlowered_operator`` code
    only when it reaches evaluation/compilation (the gate fires before evaluation,
    not at load — RFC decision 5)."""
    from earthsci_toolkit.numpy_interpreter import (
        EvalContext,
        UnreachableSpatialOperatorError,
        eval_expr,
    )
    from earthsci_toolkit.simulation import simulate

    # (a) Loads clean.
    f = load(os.path.join(_conf_dir("unlowered_operator"), "fixture.esm"))
    assert "m" in f.models

    # (b) Reaching evaluation surfaces `unlowered_operator` (the fixture's RHS is a
    # spatial D(u, wrt=x)); mirrors Julia tree_walk_test.jl.
    ctx = EvalContext(
        state_layout={"u": slice(0, 1)}, state_shapes={"u": ()},
        param_values={}, observed_values={}, y=np.array([1.0]), t=0.0,
    )
    with pytest.raises(UnreachableSpatialOperatorError) as excinfo:
        eval_expr(ExprNode(op="D", args=["u"], wrt="x"), ctx)
    assert excinfo.value.code == "unlowered_operator"

    # (c) End-to-end: the loaded fixture surfaces the same token when simulated.
    res = simulate(f, tspan=(0.0, 1.0))
    assert res.success is False
    assert "unlowered_operator" in (res.message or "")


def test_attrs_match_binds_scalar_metavariable():
    """esm-spec §4.2 open tier / RFC Change A: a custom op carries scheme params in
    ``attrs``; a ``match`` pattern's ``attrs.<key>`` set to a bare param binds it to
    the matched literal. This falls out of generic structural matching — no
    special-casing in the engine. Mirrors the Julia attrs testset."""
    src = {
        "esm": "0.8.0",
        "metadata": {"name": "attrs_match", "authors": ["t"]},
        "models": {
            "m": {
                "variables": {
                    "u": {"type": "state", "units": "1", "default": 0.0},
                    "y": {
                        "type": "observed", "units": "1",
                        "expression": {"op": "custom_scheme", "args": ["u"],
                                       "attrs": {"gamma": 1.4}},
                    },
                },
                "equations": [],
                "expression_templates": {
                    "lower_custom": {
                        "params": ["f", "g"],
                        "match": {"op": "custom_scheme", "args": ["f"],
                                  "attrs": {"gamma": "g"}},
                        "body": {"op": "*", "args": ["g", "f"]},
                    }
                },
            }
        },
    }
    out = lower_expression_templates(src)
    assert out["models"]["m"]["variables"]["y"]["expression"] == {
        "op": "*", "args": [1.4, "u"],
    }
