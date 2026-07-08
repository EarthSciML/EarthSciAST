"""Unit tests for expression_templates / apply_expression_template
(esm-spec §9.6, docs/rfcs/ast-expression-templates.md, esm-giy).
"""

from __future__ import annotations

import copy
import json
import os

import numpy as np
import pytest
from conftest import CONFORMANCE_DIR

from earthsci_ast.esm_types import ExprNode
from earthsci_ast.parse import load
from earthsci_ast.lower_expression_templates import (
    ExpressionTemplateError,
    lower_expression_templates,
    reject_expression_templates_pre_v04,
)
from earthsci_ast.template_imports import resolve_template_machinery


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
                "args": [{"op": "/", "args": [{"op": "-", "args": [Ea]}, "T"]}],
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
    case = CONFORMANCE_DIR / "expression_templates" / "arrhenius_smoke"
    fixture_path = case / "fixture.esm"
    expanded_path = case / "expanded.esm"
    with open(fixture_path) as fp:
        fixture_src = fp.read()
    with open(expanded_path) as fp:
        expanded_dict = json.load(fp)
    expanded_via_pass = lower_expression_templates(json.loads(fixture_src))
    assert (
        expanded_via_pass["reaction_systems"]["chem"]["reactions"]
        == expanded_dict["reaction_systems"]["chem"]["reactions"]
    )


def test_coupling_transform_expression_conformance_fixture_matches_expanded_form():
    """The v0.8.0 variable_map expression-transform widening (esm-spec
    §10.4/§10.5): a coupling `transform` invoking a template declared by the
    RECEIVING component expands at load against that component's registry
    (§9.6.4). Cross-binding golden:
    tests/conformance/expression_templates/coupling_transform_expression/expanded.esm.
    """
    case = CONFORMANCE_DIR / "expression_templates" / "coupling_transform_expression"
    with open(case / "fixture.esm") as fp:
        fixture_src = fp.read()
    with open(case / "expanded.esm") as fp:
        expanded_dict = json.load(fp)
    expanded_via_pass = lower_expression_templates(json.loads(fixture_src))
    assert expanded_via_pass["coupling"] == expanded_dict["coupling"]
    assert expanded_via_pass["models"] == expanded_dict["models"]


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
# Julia reference testset in EarthSciAST.jl/test/expression_templates_test.jl
# ("0.8.0 outermost-first + fixpoint") and test/tree_walk_test.jl.
# ===========================================================================


def _conf_dir(fix: str) -> str:
    return str(CONFORMANCE_DIR / "expression_templates" / fix)


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
    from earthsci_ast.numpy_interpreter import (
        EvalContext,
        UnreachableSpatialOperatorError,
        eval_expr,
    )
    from earthsci_ast.simulation import simulate

    # (a) Loads clean.
    f = load(os.path.join(_conf_dir("unlowered_operator"), "fixture.esm"))
    assert "m" in f.models

    # (b) Reaching evaluation surfaces `unlowered_operator` (the fixture's RHS is a
    # spatial D(u, wrt=x)); mirrors Julia tree_walk_test.jl.
    ctx = EvalContext(
        state_layout={"u": slice(0, 1)},
        state_shapes={"u": ()},
        param_values={},
        observed_values={},
        y=np.array([1.0]),
        t=0.0,
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
                        "type": "observed",
                        "units": "1",
                        "expression": {
                            "op": "custom_scheme",
                            "args": ["u"],
                            "attrs": {"gamma": 1.4},
                        },
                    },
                },
                "equations": [],
                "expression_templates": {
                    "lower_custom": {
                        "params": ["f", "g"],
                        "match": {"op": "custom_scheme", "args": ["f"], "attrs": {"gamma": "g"}},
                        "body": {"op": "*", "args": ["g", "f"]},
                    }
                },
            }
        },
    }
    out = lower_expression_templates(src)
    assert out["models"]["m"]["variables"]["y"]["expression"] == {
        "op": "*",
        "args": [1.4, "u"],
    }


# ---------------------------------------------------------------------------
# Scalar-field template-parameter substitution
# (esm-spec §9.6.1 / §9.6.3 constraint 5; mirrors the Julia testset 1:1)
# ---------------------------------------------------------------------------


def _scalar_field_doc(templates: dict, bindings: dict, name: str = "overlap_area") -> dict:
    return {
        "esm": "0.8.0",
        "metadata": {"name": "scalar_field_param_unit", "authors": ["t"]},
        "models": {
            "M": {
                "variables": {
                    "pa": {"type": "parameter"},
                    "pb": {"type": "parameter"},
                    "area": {
                        "type": "observed",
                        "expression": {
                            "op": "apply_expression_template",
                            "args": [],
                            "name": name,
                            "bindings": bindings,
                        },
                    },
                },
                "equations": [],
                "expression_templates": templates,
            }
        },
    }


def test_scalar_field_substitution_happy_path():
    """A parameter name appearing as the string value of a scalar
    Expression-node field in `body` is a substitution site (the mirror of the
    match-side scalar-field binding rule, esm-spec §9.6.1)."""
    src = _scalar_field_doc(
        {
            "overlap_area": {
                "params": ["K_manifold", "a", "b"],
                "body": {
                    "op": "polygon_intersection_area",
                    "manifold": "K_manifold",
                    "args": ["a", "b"],
                },
            }
        },
        {"K_manifold": "planar", "a": "pa", "b": "pb"},
    )
    out = lower_expression_templates(src)
    assert out["models"]["M"]["variables"]["area"]["expression"] == {
        "op": "polygon_intersection_area",
        "manifold": "planar",
        "args": ["pa", "pb"],
    }


def test_scalar_field_param_threads_through_body_composition():
    """A scalar-field param passed through a §9.7.3 registration-time body
    composition (outer body applies inner, forwarding its own param into the
    inner manifold slot) substitutes end-to-end."""
    src = _scalar_field_doc(
        {
            "inner": {
                "params": ["m", "x", "y"],
                "body": {"op": "polygon_intersection_area", "manifold": "m", "args": ["x", "y"]},
            },
            "outer": {
                "params": ["K", "p", "q"],
                "body": {
                    "op": "*",
                    "args": [
                        {
                            "op": "apply_expression_template",
                            "args": [],
                            "name": "inner",
                            "bindings": {"m": "K", "x": "p", "y": "q"},
                        },
                        2.0,
                    ],
                },
            },
        },
        {"K": "spherical", "p": "pa", "q": "pb"},
        name="outer",
    )
    out = lower_expression_templates(src)
    assert out["models"]["M"]["variables"]["area"]["expression"] == {
        "op": "*",
        "args": [
            {"op": "polygon_intersection_area", "manifold": "spherical", "args": ["pa", "pb"]},
            2.0,
        ],
    }


def test_invalid_substituted_manifold_rejected_post_expansion():
    """Validators run on the expanded form (esm-spec §9.6.4): a template
    invocation binding the manifold parameter to a non-member literal is
    rejected with `geometry_manifold_invalid`."""
    src = _scalar_field_doc(
        {
            "overlap_area": {
                "params": ["K_manifold", "a", "b"],
                "body": {
                    "op": "polygon_intersection_area",
                    "manifold": "K_manifold",
                    "args": ["a", "b"],
                },
            }
        },
        {"K_manifold": "bogus", "a": "pa", "b": "pb"},
    )
    with pytest.raises(ExpressionTemplateError) as exc:
        lower_expression_templates(src)
    assert exc.value.code == "geometry_manifold_invalid"


def test_params_shadow_literals_in_scalar_fields():
    """Pinned shadowing resolution (esm-spec §9.6.1): a declared param name
    shadows a coincident field literal inside `body` — the param wins. Authors
    must not name params after field literals; the engine substitutes anyway."""
    src = _scalar_field_doc(
        {
            "shadowed": {
                "params": ["planar", "x", "y"],
                "body": {
                    "op": "polygon_intersection_area",
                    "manifold": "planar",
                    "args": ["x", "y"],
                },
            }
        },
        {"planar": "spherical", "x": "pa", "y": "pb"},
        name="shadowed",
    )
    out = lower_expression_templates(src)
    expr = out["models"]["M"]["variables"]["area"]["expression"]
    assert expr["manifold"] == "spherical"


def test_scalar_field_param_conformance_fixture_matches_expanded():
    """Drives tests/conformance/expression_templates/scalar_field_param — the
    scalar-field substitution site rule (esm-spec §9.6.1) instantiated twice
    (planar / spherical) — against its pinned Julia-generated expanded.esm."""
    fixture = _conf_fixture("scalar_field_param")
    expanded = _conf_fixture("scalar_field_param", "expanded.esm")
    out = lower_expression_templates(fixture)
    assert out["models"] == expanded["models"]
    variables = out["models"]["Overlap"]["variables"]
    assert variables["area_planar"]["expression"]["manifold"] == "planar"
    assert variables["area_spherical"]["expression"]["manifold"] == "spherical"


# ---------------------------------------------------------------------------
# Static match-scoping constraints (`where`, esm-spec §9.6.1;
# docs/content/rfcs/match-pattern-scoping-constraints.md)
# ---------------------------------------------------------------------------


def _expand_conf(fix: str) -> dict:
    """Raw §9.7 pipeline (resolve → lower) over a conformance fixture."""
    raw = _conf_fixture(fix)
    resolved = resolve_template_machinery(raw, _conf_dir(fix))
    return lower_expression_templates(resolved if resolved is not None else raw)


@pytest.mark.parametrize(
    "fix",
    ["constrained_match_scope", "per_variable_scheme_literal_args", "two_div_two_meshes"],
)
def test_where_constraint_conformance_matches_golden(fix):
    """The three §9.6.1 `where` goldens: substantive tree (models / index_sets /
    reaction_systems) byte-identical to the Julia-generated expanded.esm. The
    illustrative `metadata` block is authored differently in the golden and is
    not part of the cross-binding contract (mirrors arrhenius_smoke / coupling)."""
    got = _expand_conf(fix)
    want = _conf_fixture(fix, "expanded.esm")
    for key in ("models", "index_sets", "reaction_systems"):
        assert got.get(key) == want.get(key), f"{fix}: {key} differs"


def test_where_constraint_scopes_positive_and_negative_case():
    """constrained_match_scope: one shape-constrained div rule, two shaped
    variables. div(F_edge) (shape [edges]) is rewritten; div(F_cell) (shape
    [cells]) is constraint-excluded and survives lowering intact."""
    out = _expand_conf("constrained_match_scope")
    vars_ = out["models"]["m"]["variables"]
    # F_edge matched the shape [edges] constraint → rewritten to inv_area * F.
    assert vars_["div_edge"]["expression"]["op"] == "*"
    # F_cell failed the constraint → the div node stays un-lowered.
    assert vars_["div_cell"]["expression"]["op"] == "div"


def test_where_unknown_index_set_rejected_at_registration():
    """constraint_unknown_index_set: a `where` shape naming an index set the
    consuming registry does not declare fails at rule registration with
    template_constraint_unknown_index_set (esm-spec §9.6.1/§9.6.6)."""
    raw = _conf_fixture("constraint_unknown_index_set")
    want = _conf_fixture("constraint_unknown_index_set", "error.json")["code"]
    with pytest.raises(ExpressionTemplateError) as exc:
        resolved = resolve_template_machinery(raw, _conf_dir("constraint_unknown_index_set"))
        lower_expression_templates(resolved if resolved is not None else raw)
    assert exc.value.code == want == "template_constraint_unknown_index_set"


def _where_pin_doc(templates: dict) -> dict:
    return {
        "esm": "0.8.0",
        "metadata": {"name": "where_pin"},
        "index_sets": {"edges": {"kind": "interval", "size": 4}},
        "models": {
            "m": {
                "variables": {
                    "Fe": {"type": "state", "units": "1", "default": 1.0, "shape": ["edges"]},
                    "k": {"type": "parameter", "units": "1", "default": 2.0},
                    "d": {
                        "type": "observed",
                        "units": "1",
                        "shape": ["edges"],
                        "expression": {"op": "div", "args": ["Fe"]},
                    },
                },
                "equations": [],
                "expression_templates": templates,
            }
        },
    }


def test_where_constraint_filters_before_priority():
    """§9.6.3 non-fixture pin: constraint filtering is part of match
    ELIGIBILITY, applied BEFORE priority/declaration-order selection. A
    high-priority rule whose `where` excludes the node does NOT shadow a
    lower-priority rule that legitimately fires — the scan proceeds past the
    excluded candidate."""
    doc = _where_pin_doc(
        {
            # Higher priority but constrained to a shape 'Fe' does NOT have.
            "hi": {
                "params": ["X"],
                "priority": 10,
                "match": {"op": "div", "args": ["X"]},
                "where": {"X": {"shape": ["cells_nope_unused"]}},
                "body": {"op": "*", "args": [999, "X"]},
            },
            # Lower priority, constrained to the actual shape → this one fires.
            "lo": {
                "params": ["X"],
                "priority": 0,
                "match": {"op": "div", "args": ["X"]},
                "where": {"X": {"shape": ["edges"]}},
                "body": {"op": "*", "args": ["k", "X"]},
            },
        }
    )
    # 'cells_nope_unused' must exist in the registry so registration passes;
    # it simply never matches a variable's declared shape.
    doc["index_sets"]["cells_nope_unused"] = {"kind": "interval", "size": 1}
    out = lower_expression_templates(doc)
    expr = out["models"]["m"]["variables"]["d"]["expression"]
    assert expr["op"] == "*"
    assert expr["args"][0] == "k"  # the low-priority (satisfied) rule fired


def test_where_constraint_compound_argument_fails_conservatively():
    """§9.6.1 non-fixture pin: the judgment is bare-variable-only. A `div` of a
    COMPOUND expression (not a bare declared variable) fails the constraint —
    no error, no rewrite (conservative)."""
    doc = _where_pin_doc(
        {
            "r": {
                "params": ["X"],
                "match": {"op": "div", "args": ["X"]},
                "where": {"X": {"shape": ["edges"]}},
                "body": {"op": "*", "args": ["k", "X"]},
            },
        }
    )
    # div of a compound (Fe + Fe), not a bare variable reference.
    doc["models"]["m"]["variables"]["d"]["expression"] = {
        "op": "div",
        "args": [{"op": "+", "args": ["Fe", "Fe"]}],
    }
    out = lower_expression_templates(doc)
    expr = out["models"]["m"]["variables"]["d"]["expression"]
    assert expr["op"] == "div"  # unchanged: constraint not satisfied


@pytest.mark.parametrize(
    "bad,code",
    [
        # `where` without `match`
        (
            {
                "t": {
                    "params": ["X"],
                    "where": {"X": {"shape": ["edges"]}},
                    "body": {"op": "*", "args": ["k", "X"]},
                }
            },
            "apply_expression_template_invalid_declaration",
        ),
        # `where` constrains a non-declared param
        (
            {
                "t": {
                    "params": ["X"],
                    "match": {"op": "div", "args": ["X"]},
                    "where": {"Y": {"shape": ["edges"]}},
                    "body": {"op": "*", "args": ["k", "X"]},
                }
            },
            "apply_expression_template_invalid_declaration",
        ),
        # constraint kind other than `shape`
        (
            {
                "t": {
                    "params": ["X"],
                    "match": {"op": "div", "args": ["X"]},
                    "where": {"X": {"rank": 1}},
                    "body": {"op": "*", "args": ["k", "X"]},
                }
            },
            "apply_expression_template_invalid_declaration",
        ),
        # empty shape list
        (
            {
                "t": {
                    "params": ["X"],
                    "match": {"op": "div", "args": ["X"]},
                    "where": {"X": {"shape": []}},
                    "body": {"op": "*", "args": ["k", "X"]},
                }
            },
            "apply_expression_template_invalid_declaration",
        ),
    ],
)
def test_where_structural_validation(bad, code):
    """§9.6.1 structural validation of the `where` block at registration."""
    doc = _where_pin_doc(bad)
    with pytest.raises(ExpressionTemplateError) as exc:
        lower_expression_templates(doc)
    assert exc.value.code == code
