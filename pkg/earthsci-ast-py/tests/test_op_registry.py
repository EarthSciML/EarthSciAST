"""Keep :mod:`earthsci_ast.op_registry` in sync with every renderer/dispatcher.

There is no single source of truth for the AST ``op`` vocabulary in the codebase;
:mod:`earthsci_ast.op_registry` is the canonical enumeration, and this test asserts
that each of the six independent tables / dispatch chains covers exactly the
subset of that registry it is CONTRACTUALLY responsible for. The scope for each
table is encoded explicitly (and justified in a comment) so the checks are
meaningful rather than vacuous:

* data-driven tables (the ``expression`` / ``numpy_interpreter`` dicts,
  ``cadence.RELATIONAL_OPS``, ``flatten._SPATIAL_OPS``) are read directly and
  compared bidirectionally with a registry-derived subset; and
* the if-chain renderers (``display`` / ``codegen``) are checked by extracting
  the op string literals their dispatch branches on from the module source, so a
  handler that is added/removed is reflected in the check.

The intended failure mode: adding a new op to the registry WITHOUT wiring the
corresponding renderer/dispatcher makes a check here fail loudly with a message
naming the offending ops (and vice-versa).
"""

from __future__ import annotations

import importlib
import re
import warnings

import pytest

# Import the submodules via importlib: the package ``__init__`` re-exports the
# ``flatten`` FUNCTION under the name ``flatten``, shadowing the submodule in the
# package namespace, so ``from earthsci_ast import flatten`` would bind the
# function. ``import_module`` always returns the real module.
cadence = importlib.import_module("earthsci_ast.cadence")
codegen = importlib.import_module("earthsci_ast.codegen")
display = importlib.import_module("earthsci_ast.display")
expression = importlib.import_module("earthsci_ast.expression")
flatten = importlib.import_module("earthsci_ast.flatten")
numpy_interpreter = importlib.import_module("earthsci_ast.numpy_interpreter")
reg = importlib.import_module("earthsci_ast.op_registry")

REG_NAMES = set(reg.names())
REG_CANONICAL = set(reg.canonical_names())


def _cat(category: str) -> set[str]:
    return set(reg.by_category(category))


def _unary_elementary() -> set[str]:
    """Registry elementary functions that are unary (single-callable) — the shape
    both ``expression._UNARY_SYMPY`` and ``numpy_interpreter._SCALAR_FUNCS``
    dispatch. Excludes ``atan2`` (binary) and ``min``/``max`` (n-ary)."""
    return {n for n in _cat("elementary") if reg.OPS[n].arity == "unary"}


def _comparison_noalias() -> set[str]:
    """The six evaluable comparison ops (drops the display-only ``=`` alias)."""
    return {n for n in _cat("comparison") if reg.OPS[n].alias_of is None}


# ---------------------------------------------------------------------------
# Registry self-consistency
# ---------------------------------------------------------------------------


def test_registry_labels_are_from_the_closed_sets():
    for name, spec in reg.OPS.items():
        assert spec.name == name, f"OPS key {name!r} != spec.name {spec.name!r}"
        assert spec.category in reg.CATEGORIES, f"{name!r}: bad category {spec.category!r}"
        assert spec.tier in reg.TIERS, f"{name!r}: bad tier {spec.tier!r}"
        assert spec.arity in reg.ARITIES, f"{name!r}: bad arity {spec.arity!r}"


def test_registry_has_no_duplicate_entries():
    # The dict would silently dedup a repeated tuple entry; guard against it.
    assert len(reg._ALL) == len(reg.OPS)


def test_registry_aliases_point_at_canonical_ops():
    for name, spec in reg.OPS.items():
        if spec.alias_of is not None:
            assert spec.alias_of in reg.OPS, f"{name!r} aliases unknown op {spec.alias_of!r}"
            assert reg.OPS[spec.alias_of].alias_of is None, (
                f"{name!r} aliases {spec.alias_of!r}, which is itself an alias"
            )


def test_rewrite_target_tier_is_exactly_spatial_sugar():
    # The only open-tier (no-evaluator) ops are the spatial-sugar family.
    assert set(reg.by_tier("rewrite_target")) == _cat("spatial_sugar")


# ---------------------------------------------------------------------------
# expression.py — ESM<->SymPy tables
# ---------------------------------------------------------------------------


def test_expression_unary_sympy_matches_registry():
    # _UNARY_SYMPY handles the unary elementary functions EXCEPT `abs` (which uses
    # the NaN-safe `_ess_numeric_abs` placeholder, handled explicitly), PLUS the
    # unary logical `not`.
    expected = (_unary_elementary() - {"abs"}) | {"not"}
    assert set(expression._UNARY_SYMPY) == expected


def test_expression_binary_sympy_matches_registry():
    # _BINARY_SYMPY handles division, atan2, and the six evaluable comparisons.
    expected = {"/", "atan2"} | _comparison_noalias()
    assert set(expression._BINARY_SYMPY) == expected


def test_expression_from_sympy_tables_are_registered():
    # The reverse (SymPy->ESM) tables are keyed by SymPy names; their VALUES are
    # ESM ops and must all be canonical registry ops.
    for table_name in ("_FROM_SYMPY_ALL_ARGS", "_FROM_SYMPY_RELATIONAL", "_FROM_SYMPY_UNARY"):
        table = getattr(expression, table_name)
        unknown = set(table.values()) - REG_CANONICAL
        assert not unknown, f"{table_name} maps to unregistered ops: {sorted(unknown)}"


# ---------------------------------------------------------------------------
# numpy_interpreter.py — evaluator tables
# ---------------------------------------------------------------------------


def test_numpy_scalar_funcs_matches_registry():
    # _SCALAR_FUNCS is exactly the unary elementary functions (incl. abs).
    assert set(numpy_interpreter._SCALAR_FUNCS) == _unary_elementary()


def test_numpy_cmp_ufuncs_matches_registry():
    assert set(numpy_interpreter._CMP_UFUNCS) == _comparison_noalias()


# ---------------------------------------------------------------------------
# cadence.py — the value-invention hot-path guard
# ---------------------------------------------------------------------------


def test_cadence_relational_ops_matches_registry():
    # RELATIONAL_OPS is exactly the `relational` category (value-invention +
    # index-returning reducers): skolem/rank/argmin/argmax/distinct/join.
    assert set(cadence.RELATIONAL_OPS) == _cat("relational")


# ---------------------------------------------------------------------------
# flatten.py — the spatial-operator detector
# ---------------------------------------------------------------------------


def test_flatten_spatial_ops_matches_registry():
    # _SPATIAL_OPS is the differential spatial sugar (grad/div/laplacian/curl).
    # `integral` is spatial-sugar too but is NOT a differential operator node
    # (no `.dim`), so this detector legitimately excludes it.
    expected = _cat("spatial_sugar") - {"integral"}
    assert set(flatten._SPATIAL_OPS) == expected


# ---------------------------------------------------------------------------
# display.py / codegen.py — if-chain renderers (source-literal extraction)
# ---------------------------------------------------------------------------


def _op_literals_in_source(module) -> set[str]:
    """Extract every op string a module's dispatch branches on: the literals in
    ``op == "X"`` and ``op in ("A", "B")`` / ``op in ["A", "B"]`` patterns.
    Reading the real source keeps the coverage check honest — a handler that is
    added or removed changes this set."""
    with open(module.__file__, encoding="utf-8") as fh:
        src = fh.read()
    ops: set[str] = set()
    for m in re.finditer(r'\bop\s*==\s*"([^"]+)"', src):
        ops.add(m.group(1))
    for m in re.finditer(r"\bop\s+in\s*[\(\[]([^\)\]]*)[\)\]]", src):
        ops.update(re.findall(r'"([^"]+)"', m.group(1)))
    return ops


# Registered ops for which display's generic `op(args)` fallback IS the intended
# rendering (they carry no dedicated math notation): the open-tier spatial sugar,
# and the build-time relational / boolean-literal ops. Every OTHER registered op
# must be specifically rendered.
DISPLAY_GENERIC_OK = {
    "grad", "div", "laplacian", "curl",  # open-tier sugar (rewrite-target)
    "ic",                                 # equation-LHS declaration
    "skolem", "rank", "distinct", "join",  # build-time value-invention ops
    "false",                              # display renders `true` but not `false`
}


def test_display_covers_every_registered_op():
    handled = _op_literals_in_source(display)

    # 1. Every op display branches on must be registered (no orphan handler/typo).
    orphan = handled - REG_NAMES
    assert not orphan, f"display renders ops not in the registry: {sorted(orphan)}"

    # 2. The generic-fallback allowlist must itself be registered and must not
    #    overlap the specifically-handled set.
    assert DISPLAY_GENERIC_OK <= REG_NAMES
    assert handled.isdisjoint(DISPLAY_GENERIC_OK), (
        "op(s) both specifically handled AND listed as generic-ok in display: "
        f"{sorted(handled & DISPLAY_GENERIC_OK)}"
    )

    # 3. THE LOUD CHECK: every registered op that is not explicitly allowed to
    #    render generically must have a dedicated display handler. A new op added
    #    to the registry without a renderer fails here, naming itself.
    missing = (REG_NAMES - DISPLAY_GENERIC_OK) - handled
    assert not missing, (
        f"display has no dedicated renderer for registered op(s): {sorted(missing)}. "
        "Add a handler in display._format_structural_op / _format_expression_node, "
        "or (if generic `op(args)` really is correct) add it to DISPLAY_GENERIC_OK."
    )


# codegen intentionally special-cases only the operator / control-flow subset it
# must reshape for the Julia / Python targets; every other registered op is
# rendered by the generic function-call fallback (`sin(x)`, `min(a, b)`, the array
# ops, …), which is the deliberate, correct behaviour. So codegen's contract is a
# SUBSET of the registry, pinned here explicitly.
CODEGEN_HANDLED = {
    "+", "*", "-", "/", "^", "**", "pow",
    "D", "grad",
    "exp", "ifelse", "Pre", "not",
    "<", ">", "<=", ">=", "==", "!=",
    "and", "or",
}


def test_codegen_special_cases_are_registered_and_pinned():
    handled = _op_literals_in_source(codegen)
    # codegen dispatches the arithmetic / comparison / call ops through
    # per-target spelling tables rather than inline ``op ==`` branches, so
    # harvest those op keys too (``_NOT_PREFIX`` is keyed by target, not op —
    # its ``not`` op still has an explicit branch the source scan catches).
    handled |= set(codegen._INFIX_SEP)
    handled |= set(codegen._COMPARISON_OPS)
    handled |= set(codegen._CALL_NAME)

    # Every op codegen special-cases must be registered (no orphan / typo).
    orphan = handled - REG_NAMES
    assert not orphan, f"codegen special-cases ops not in the registry: {sorted(orphan)}"

    # Coverage pinned: adding or removing a codegen special case forces updating
    # this set (a review checkpoint) and re-confirming the op is registered.
    assert handled == CODEGEN_HANDLED, (
        "codegen's special-cased op set drifted from CODEGEN_HANDLED; "
        f"added={sorted(handled - CODEGEN_HANDLED)} removed={sorted(CODEGEN_HANDLED - handled)}"
    )


# ---------------------------------------------------------------------------
# Loud degradation (step 3): the generic fallbacks warn on unregistered ops
# ---------------------------------------------------------------------------


def test_display_warns_on_unregistered_op():
    with pytest.warns(RuntimeWarning, match="op_registry"):
        display.to_unicode({"op": "totally_made_up_op_xyz", "args": ["x"]})


def test_display_does_not_warn_on_registered_generic_op():
    # `grad` is a registered open-tier op that renders generically — no warning.
    with warnings.catch_warnings():
        warnings.simplefilter("error")
        display.to_unicode({"op": "grad", "args": ["x"]})
        display.to_latex({"op": "grad", "args": ["x"]})


def test_codegen_warns_on_unregistered_op():
    with pytest.warns(RuntimeWarning, match="op_registry"):
        codegen._format_expression({"op": "totally_made_up_op_xyz", "args": ["x"]})
    with pytest.warns(RuntimeWarning, match="op_registry"):
        codegen._format_python_expression({"op": "totally_made_up_op_xyz", "args": ["x"]})


def test_codegen_does_not_warn_on_registered_generic_op():
    # `sin` is registered; codegen renders it via the generic function-call path
    # (which is correct Julia/SymPy) — no warning.
    with warnings.catch_warnings():
        warnings.simplefilter("error")
        codegen._format_expression({"op": "sin", "args": ["x"]})
        codegen._format_python_expression({"op": "sin", "args": ["x"]})
