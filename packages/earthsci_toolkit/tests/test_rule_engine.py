"""Unit tests for the rule engine (RFC §5.2).

Mirrors the Julia suite in
``packages/EarthSciSerialization.jl/test/rule_engine_test.jl``.
"""

from __future__ import annotations

import pytest

from earthsci_toolkit.canonicalize import canonical_json
from earthsci_toolkit.esm_types import ExprNode
from earthsci_toolkit.rule_engine import (
    BoundaryPolicySpec,
    Guard,
    Rule,
    RuleContext,
    RuleEngineError,
    apply_bindings,
    check_unrewritten_pde_ops,
    match_pattern,
    parse_rule,
    parse_rules,
    rewrite,
)


def _node(op, *args, **kw):
    return ExprNode(op=op, args=list(args), **kw)


# ============================================================================
# Pattern matching
# ============================================================================


class TestMatchPattern:
    def test_subtree_pvar_binds_whole_expr(self):
        pat = "$a"
        expr = _node("+", "x", 0)
        b = match_pattern(pat, expr)
        assert b == {"$a": expr}

    def test_literal_match(self):
        assert match_pattern(0, 0) == {}
        assert match_pattern("x", "x") == {}
        assert match_pattern(0, 1) is None
        assert match_pattern("x", "y") is None

    def test_op_node_equal(self):
        assert match_pattern(_node("+", "x", 0), _node("+", "x", 0)) == {}

    def test_op_arity_mismatch(self):
        assert match_pattern(_node("+", "x", 0), _node("+", "x", 0, 1)) is None

    def test_op_kind_mismatch(self):
        assert match_pattern(_node("+", "x", 0), _node("-", "x", 0)) is None

    def test_pvar_in_op_arg(self):
        pat = _node("+", "$a", 0)
        expr = _node("+", "x", 0)
        assert match_pattern(pat, expr) == {"$a": "x"}

    def test_pvar_nonlinear_same_binding_ok(self):
        pat = _node("-", "$a", "$a")
        assert match_pattern(pat, _node("-", "x", "x")) == {"$a": "x"}

    def test_pvar_nonlinear_divergent_binding_fails(self):
        pat = _node("-", "$a", "$a")
        assert match_pattern(pat, _node("-", "x", "y")) is None

    def test_sibling_field_pvar(self):
        pat = _node("D", "$u", wrt="$x")
        expr = _node("D", "T", wrt="t")
        assert match_pattern(pat, expr) == {"$u": "T", "$x": "t"}

    def test_sibling_field_literal_mismatch(self):
        pat = _node("D", "$u", wrt="x")
        expr = _node("D", "T", wrt="t")
        assert match_pattern(pat, expr) is None

    def test_sibling_field_missing_in_expr(self):
        pat = _node("D", "$u", wrt="$x")
        expr = _node("D", "T")
        assert match_pattern(pat, expr) is None


# ============================================================================
# apply_bindings
# ============================================================================


class TestApplyBindings:
    def test_substitute_pvar(self):
        assert apply_bindings("$a", {"$a": "x"}) == "x"

    def test_unbound_raises(self):
        with pytest.raises(RuleEngineError) as exc:
            apply_bindings("$a", {})
        assert exc.value.code == "E_PATTERN_VAR_UNBOUND"

    def test_substitute_in_op(self):
        template = _node("+", "$a", 0)
        got = apply_bindings(template, {"$a": "x"})
        assert isinstance(got, ExprNode) and got.op == "+" and got.args == ["x", 0]

    def test_sibling_field_substitute(self):
        template = _node("index", "$u", "$x")
        got = apply_bindings(template, {"$u": "T", "$x": "t"})
        assert got.args == ["T", "t"]

    def test_name_field_pvar_must_bind_bare_name(self):
        template = _node("index", "$u", wrt="$x")
        with pytest.raises(RuleEngineError) as exc:
            apply_bindings(template, {"$u": "T", "$x": _node("+", "a", "b")})
        assert exc.value.code == "E_PATTERN_VAR_TYPE"


# ============================================================================
# Rewriter
# ============================================================================


class TestRewrite:
    def test_match_once(self):
        rules = [Rule("r", _node("+", "$a", 0), "$a")]
        got = rewrite(_node("+", "x", 0), rules)
        assert got == "x"

    def test_no_match_returns_original(self):
        rules = [Rule("r", _node("+", "$a", 0), "$a")]
        got = rewrite(_node("-", "x", 0), rules)
        assert canonical_json(got) == canonical_json(_node("-", "x", 0))

    def test_descends_into_children(self):
        rules = [Rule("r", _node("+", "$a", 0), "$a")]
        got = rewrite(_node("*", _node("+", "x", 0), "y"), rules)
        # After one pass: *(x, y). Canonical form may reorder commutative args.
        assert canonical_json(got) == canonical_json(_node("*", "x", "y"))

    def test_fixed_point_multi_pass(self):
        rules = [Rule("r", _node("+", "$a", 0), "$a")]
        got = rewrite(_node("+", _node("+", "x", 0), 0), rules)
        assert got == "x"

    def test_not_converged_raises(self):
        rules = [Rule("r", "$a", _node("+", "$a", 0))]
        with pytest.raises(RuleEngineError) as exc:
            rewrite("x", rules, max_passes=3)
        assert exc.value.code == "E_RULES_NOT_CONVERGED"

    def test_first_rule_wins(self):
        rules = [
            Rule("first", "$a", "y"),
            Rule("second", "$a", "z"),
        ]
        # Pattern "$a" matches everything; first rule replaces root with "y",
        # which is sealed. Second pass "y" -> "y" (no change after first pass
        # because replacement "y" doesn't match pattern "$a"? It does. Non-
        # terminating. Verify instead with a pattern that only matches the
        # root "x".)
        rules2 = [
            Rule("first", "x", "y"),
            Rule("second", "x", "z"),
        ]
        assert rewrite("x", rules2) == "y"


# ============================================================================
# Guards
# ============================================================================


class TestGuards:
    def test_var_has_grid_pass(self):
        ctx = RuleContext(
            grids={"g1": {"spatial_dims": ["x"]}},
            variables={"T": {"grid": "g1"}},
        )
        rules = [
            Rule(
                "r",
                _node("grad", "$u", dim="$d"),
                "$u",
                where=[Guard("var_has_grid", {"pvar": "$u", "grid": "g1"})],
            )
        ]
        got = rewrite(_node("grad", "T", dim="x"), rules, ctx)
        assert got == "T"

    def test_var_has_grid_fail(self):
        ctx = RuleContext(variables={"T": {"grid": "other"}})
        rules = [
            Rule(
                "r",
                _node("grad", "$u", dim="$d"),
                "$u",
                where=[Guard("var_has_grid", {"pvar": "$u", "grid": "g1"})],
            )
        ]
        expr = _node("grad", "T", dim="x")
        got = rewrite(expr, rules, ctx)
        assert canonical_json(got) == canonical_json(expr)

    def test_dim_is_spatial(self):
        ctx = RuleContext(
            grids={"g1": {"spatial_dims": ["x", "y"]}},
            variables={"T": {"grid": "g1"}},
        )
        rules = [
            Rule(
                "r",
                _node("grad", "$u", dim="$d"),
                "$u",
                where=[
                    Guard("var_has_grid", {"pvar": "$u", "grid": "$g"}),
                    Guard("dim_is_spatial_dim_of", {"pvar": "$d", "grid": "$g"}),
                ],
            )
        ]
        assert rewrite(_node("grad", "T", dim="x"), rules, ctx) == "T"
        got = rewrite(_node("grad", "T", dim="z"), rules, ctx)
        assert canonical_json(got) == canonical_json(_node("grad", "T", dim="z"))

    def test_unknown_guard_raises(self):
        rules = [
            Rule(
                "r",
                "$a",
                "$a",
                where=[Guard("nonsense", {})],
            )
        ]
        with pytest.raises(RuleEngineError) as exc:
            rewrite("x", rules)
        assert exc.value.code == "E_UNKNOWN_GUARD"


# ============================================================================
# Unrewritten PDE op check
# ============================================================================


class TestUnrewrittenPdeOps:
    def test_clean_expr_ok(self):
        check_unrewritten_pde_ops(_node("+", "x", 1))

    def test_detects_grad(self):
        with pytest.raises(RuleEngineError) as exc:
            check_unrewritten_pde_ops(_node("+", "x", _node("grad", "T")))
        assert exc.value.code == "E_UNREWRITTEN_PDE_OP"

    @pytest.mark.parametrize("op", ["grad", "div", "laplacian", "D", "bc"])
    def test_detects_each_pde_op(self, op):
        with pytest.raises(RuleEngineError):
            check_unrewritten_pde_ops(_node(op, "T"))


# ============================================================================
# Rule parsing
# ============================================================================


class TestParseRule:
    def test_parse_simple(self):
        r = parse_rule(
            {
                "name": "add_zero",
                "pattern": {"op": "+", "args": ["$a", 0]},
                "replacement": "$a",
            }
        )
        assert r.name == "add_zero"
        assert isinstance(r.pattern, ExprNode)
        assert r.replacement == "$a"

    def test_parse_with_guard(self):
        r = parse_rule(
            {
                "name": "g",
                "pattern": "$u",
                "replacement": "$u",
                "where": [{"guard": "var_has_grid", "pvar": "$u", "grid": "g1"}],
            }
        )
        assert len(r.where) == 1
        assert r.where[0].name == "var_has_grid"
        assert r.where[0].params == {"pvar": "$u", "grid": "g1"}

    def test_missing_replacement_raises(self):
        with pytest.raises(RuleEngineError) as exc:
            parse_rule({"name": "r", "pattern": "$a"})
        assert exc.value.code == "E_RULE_REPLACEMENT_MISSING"

    def test_parse_rules_object_form(self):
        rules = parse_rules(
            {
                "r1": {"pattern": "x", "replacement": "y"},
                "r2": {"pattern": "y", "replacement": "z"},
            }
        )
        assert [r.name for r in rules] == ["r1", "r2"]

    def test_parse_rules_array_form(self):
        rules = parse_rules(
            [
                {"name": "r1", "pattern": "x", "replacement": "y"},
                {"name": "r2", "pattern": "y", "replacement": "z"},
            ]
        )
        assert [r.name for r in rules] == ["r1", "r2"]


class TestBoundaryPolicy:
    """RFC §5.2.8 / §7 (esm-bet) — boundary_policy supports two forms:
    a closed-set string (uniform across axes) and a {by_axis: ...} object."""

    def test_uniform_string_form(self):
        for kind in (
            "periodic",
            "reflecting",
            "one_sided_extrapolation",
            "prescribed",
            "ghosted",
            "neumann_zero",
            "extrapolate",
        ):
            r = parse_rule(
                {
                    "name": "r",
                    "pattern": "$a",
                    "replacement": "$a",
                    "boundary_policy": kind,
                }
            )
            assert r.boundary_policy == kind

    def test_uniform_string_form_rejects_unknown(self):
        with pytest.raises(RuleEngineError) as exc:
            parse_rule(
                {
                    "name": "r",
                    "pattern": "$a",
                    "replacement": "$a",
                    "boundary_policy": "nonexistent",
                }
            )
        assert exc.value.code == "E_RULE_PARSE"

    def test_per_axis_form_one_sided_extrapolation_with_degree(self):
        r = parse_rule(
            {
                "name": "r",
                "pattern": "$a",
                "replacement": "$a",
                "boundary_policy": {
                    "by_axis": {
                        "x": {"kind": "one_sided_extrapolation", "degree": 2}
                    }
                },
            }
        )
        spec = r.boundary_policy["x"]
        assert spec.kind == "one_sided_extrapolation"
        assert spec.degree == 2

    def test_per_axis_form_rejects_invalid_degree(self):
        with pytest.raises(RuleEngineError) as exc:
            parse_rule(
                {
                    "name": "r",
                    "pattern": "$a",
                    "replacement": "$a",
                    "boundary_policy": {
                        "by_axis": {
                            "x": {"kind": "one_sided_extrapolation", "degree": 5}
                        }
                    },
                }
            )
        assert exc.value.code == "E_RULE_PARSE"


class TestGhostWidth:
    """RFC §5.2.8 / §7 (esm-bet) — ghost_width is either a non-negative
    integer (axis-uniform) or a {by_axis: ...} object."""

    def test_scalar_form(self):
        r = parse_rule(
            {
                "name": "r",
                "pattern": "$a",
                "replacement": "$a",
                "ghost_width": 3,
            }
        )
        assert r.ghost_width == 3

    def test_scalar_form_zero(self):
        r = parse_rule(
            {
                "name": "r",
                "pattern": "$a",
                "replacement": "$a",
                "ghost_width": 0,
            }
        )
        assert r.ghost_width == 0

    def test_scalar_form_rejects_negative(self):
        with pytest.raises(RuleEngineError) as exc:
            parse_rule(
                {
                    "name": "r",
                    "pattern": "$a",
                    "replacement": "$a",
                    "ghost_width": -1,
                }
            )
        assert exc.value.code == "E_RULE_PARSE"

    def test_per_axis_form(self):
        r = parse_rule(
            {
                "name": "r",
                "pattern": "$a",
                "replacement": "$a",
                "ghost_width": {"by_axis": {"xi": 3, "eta": 2}},
            }
        )
        assert r.ghost_width == {"xi": 3, "eta": 2}

    def test_per_axis_form_rejects_negative(self):
        with pytest.raises(RuleEngineError) as exc:
            parse_rule(
                {
                    "name": "r",
                    "pattern": "$a",
                    "replacement": "$a",
                    "ghost_width": {"by_axis": {"xi": -1}},
                }
            )
        assert exc.value.code == "E_RULE_PARSE"

    def test_rejects_string(self):
        with pytest.raises(RuleEngineError) as exc:
            parse_rule(
                {
                    "name": "r",
                    "pattern": "$a",
                    "replacement": "$a",
                    "ghost_width": "3",
                }
            )
        assert exc.value.code == "E_RULE_PARSE"
