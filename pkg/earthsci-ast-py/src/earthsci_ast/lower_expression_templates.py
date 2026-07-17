"""Load-time rewrite pass for ``expression_templates`` (esm-spec §9.6).

docs/content/rfcs/open-op-namespace-fixpoint-rewrite.md, esm-giy.

``expression_templates`` is the single structural-substitution mechanism in the
format. Each entry is a rewrite rule with ``params`` (metavariables) and a
``body`` (the replacement Expression), applied in one of two ways:

- WITHOUT a ``match`` field — invoked explicitly by an
  ``apply_expression_template`` node whose ``bindings`` supply each param's AST
  (named-template expansion).
- WITH a ``match`` field — an auto-applied rewrite rule: ``match`` is a pattern
  Expression whose param occurrences are wildcards, fired wherever it
  structurally matches a node. A param in an operand/``args`` position binds to
  the matched sub-AST; a param in a scalar field (``dim``, ``side``, an
  ``attrs.<key>``, …) binds to the matched literal.

Rewriting is an OUTERMOST-FIRST, PRIORITY-ORDERED, BOUNDED-FIXPOINT process
(esm-spec §9.6.3, :func:`_rewrite_to_fixpoint`). Rule application proceeds in
passes; one pass (:func:`_rewrite_pass`) is a single pre-order (outermost-first)
walk of the tree. At each node the engine first tries to fire a rule AT that
node before descending: an ``apply_expression_template`` op is expanded,
otherwise the ``match`` rules are consulted and the winner is selected
deterministically — highest ``priority`` (integer, default 0), ties broken by
DECLARATION order. The winner's ``body`` replaces the node and the walk does NOT
descend into that freshly-produced body during the current pass; if no rule
fires, the walk descends into children. Passes repeat until a pass performs zero
rewrites (the fixpoint) or until ``MAX_REWRITE_PASSES`` productive passes have
run without converging, in which case the file is rejected with
``rewrite_rule_nonterminating`` (the pass bound — not a static check — is the
authoritative termination guard, so a self-reintroducing rule simply fails to
converge). Because selection and traversal are fully deterministic, all bindings
produce byte-identical fixpoints. After convergence the tree contains no
``apply_expression_template`` ops and no ``expression_templates`` blocks —
downstream consumers see only normal Expression ASTs (Option A round-trip). Any
rewrite-target op (e.g. a spatial ``D``) that survives the fixpoint into an
evaluation position is caught later by the ``unlowered_operator`` gate, not here.

Operates on the pre-coercion JSON dict view, so it must run after
schema validation but before ``_parse_esm_data``.
"""

from __future__ import annotations

import copy
import json
import math
import re
from typing import Any

from . import op_registry
from .diagnostics import (
    APPLY_EXPRESSION_TEMPLATE_BINDINGS_MISMATCH,
    APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
    APPLY_EXPRESSION_TEMPLATE_UNKNOWN_TEMPLATE,
    APPLY_EXPRESSION_TEMPLATE_VERSION_TOO_OLD,
    GEOMETRY_MANIFOLD_INVALID,
    MAKEARRAY_REGION_INVERTED,
    REWRITE_RULE_NONTERMINATING,
    TEMPLATE_CONSTRAINT_UNKNOWN_INDEX_SET,
)

# ``ExpressionTemplateError`` + the JSON-walk primitives + ``APPLY_OP`` now live
# in the leaf :mod:`earthsci_ast.json_walk` (shared with template_imports /
# coupling_imports). ``ExpressionTemplateError`` and ``APPLY_OP`` are re-exported
# here so their historical import paths keep resolving. ``_compose_template_bodies``
# is imported at module level (see :func:`_component_registry`): the former lazy
# back-import is gone now that the shared primitives are in a common leaf, so
# there is no longer a module cycle to dodge.
from .json_walk import (  # noqa: F401 — re-exported for the historical import path
    APPLY_OP,
    ExpressionTemplateError,
    _is_array,
    _is_object,
    _walk_json,
)
from .template_imports import _collect_apply_names, _compose_template_bodies

# Geometry-kernel ops whose `manifold` scalar field is restricted to the closed
# manifold registry (CONFORMANCE_SPEC §5.8.4). The document schema admits any
# string in the `manifold` position so a template `body` can carry a parameter
# name there (esm-spec §9.6.1 scalar-field substitution site); the closed set
# is enforced by :func:`_validate_geometry_manifolds` on the EXPANDED form per
# esm-spec §9.6.4.
_GEOMETRY_MANIFOLD_OPS = ("intersect_polygon", "polygon_intersection_area")
_GEOMETRY_MANIFOLD_VALUES = ("planar", "spherical", "geodesic")


def _assert_no_nested_apply(body: Any, template_name: str, path: str) -> None:
    """Reject ``apply_expression_template`` nodes inside a ``match`` pattern
    (esm-spec §9.7.3: match patterns MUST NOT reference templates)."""

    def _check(node: dict, p: str) -> None:
        if node.get("op") == APPLY_OP:
            raise ExpressionTemplateError(
                APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
                f"expression_templates.{template_name}: `match` contains an "
                f"'apply_expression_template' node at {p}; match patterns "
                "MUST NOT reference templates (esm-spec §9.7.3)",
            )

    _walk_json(body, on_obj=_check, path=path)


def _validate_templates(templates: dict, scope: str) -> None:
    for name, decl in templates.items():
        if not _is_object(decl):
            raise ExpressionTemplateError(
                APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
                f"{scope}.expression_templates.{name}: entry must be an object with params + body",
            )
        # ``params`` MAY be empty (esm-spec §9.6.1, 0.8.0): a zero-parameter
        # template is a named constant fragment (common in library files).
        params = decl.get("params")
        if not isinstance(params, list):
            raise ExpressionTemplateError(
                APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
                f"{scope}.expression_templates.{name}: 'params' must be an array of strings",
            )
        seen: set[str] = set()
        for p in params:
            if not isinstance(p, str) or not p:
                raise ExpressionTemplateError(
                    APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
                    f"{scope}.expression_templates.{name}: param names must be non-empty strings",
                )
            if p in seen:
                raise ExpressionTemplateError(
                    APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
                    f"{scope}.expression_templates.{name}: param '{p}' is declared twice",
                )
            seen.add(p)
        if "body" not in decl:
            raise ExpressionTemplateError(
                APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
                f"{scope}.expression_templates.{name}: 'body' is required",
            )
        # A body MAY reference other match-less in-scope templates via
        # apply_expression_template nodes (esm-spec §9.7.3); those are checked
        # (acyclic, depth <= MAX_TEMPLATE_EXPANSION_DEPTH) and inlined at
        # registration by ``_compose_template_bodies`` — the old any-nesting
        # rejection is now cycle-only (`apply_expression_template_recursive_body`).
        # ``match`` (optional) turns the entry into an auto-applied rewrite rule.
        # It must be a pattern Expression (a bare-metavar string or an op node).
        # Nontermination is NOT checked statically any more — the bounded
        # fixpoint (``MAX_REWRITE_PASSES``, esm-spec §9.6.3) is the sole guard, so
        # a self-reintroducing rule is rejected with ``rewrite_rule_nonterminating``
        # only when it actually fails to converge within the pass bound.
        if "match" in decl:
            match = decl["match"]
            if not (isinstance(match, str) or _is_object(match)):
                raise ExpressionTemplateError(
                    APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
                    f"{scope}.expression_templates.{name}: 'match' must be a "
                    "pattern Expression (a metavariable string or an op node)",
                )
            _assert_no_nested_apply(match, name, "/match")

        # esm-spec §9.6.1 (0.8.0): an optional `where` block adds static
        # match-scoping constraints on the captured params. Structural
        # validation only, here; the unknown-index-set check runs at rule
        # REGISTRATION in the consuming component (where the merged
        # `index_sets` registry is in scope) — see :func:`_registered_where`.
        if "where" in decl:
            whr = decl["where"]
            if "match" not in decl:
                raise ExpressionTemplateError(
                    APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
                    f"{scope}.expression_templates.{name}: 'where' is only "
                    "admissible alongside 'match' — constraints scope an "
                    "auto-applied rewrite rule, not a named fragment "
                    "(esm-spec §9.6.1)",
                )
            if not (_is_object(whr) and whr):
                raise ExpressionTemplateError(
                    APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
                    f"{scope}.expression_templates.{name}: 'where' must be a "
                    "non-empty object mapping declared params to constraint "
                    "objects",
                )
            for p, cobj in whr.items():
                ps = str(p)
                if ps not in seen:
                    raise ExpressionTemplateError(
                        APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
                        f"{scope}.expression_templates.{name}: 'where' "
                        f"constrains '{ps}', which is not a declared param "
                        "(esm-spec §9.6.1)",
                    )
                if not _is_object(cobj):
                    raise ExpressionTemplateError(
                        APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
                        f"{scope}.expression_templates.{name}: where.{ps} must "
                        "be a constraint object (v1 admits exactly the 'shape' "
                        "kind)",
                    )
                ckeys = {str(k) for k in cobj.keys()}
                if ckeys != {"shape"}:
                    kinds = ", ".join(sorted(ckeys))
                    raise ExpressionTemplateError(
                        APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
                        f"{scope}.expression_templates.{name}: where.{ps} "
                        f"carries constraint kind(s) {kinds}; the v1 constraint "
                        "vocabulary is exactly {shape} (esm-spec §9.6.1)",
                    )
                shp = cobj.get("shape")
                if not (_is_array(shp) and shp):
                    raise ExpressionTemplateError(
                        APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
                        f"{scope}.expression_templates.{name}: where.{ps}.shape "
                        "must be a non-empty array of index-set names",
                    )
                for s in shp:
                    if not (isinstance(s, str) and s):
                        raise ExpressionTemplateError(
                            APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
                            f"{scope}.expression_templates.{name}: "
                            f"where.{ps}.shape entries must be non-empty strings",
                        )


def _substitute(body: Any, bindings: dict[str, Any]) -> Any:
    """Pure structural substitution: every bare-string occurrence of a bound
    metavariable in ``body`` is replaced by its bound AST/literal.

    This is the single substitution primitive of the rewrite engine — it
    instantiates both explicit ``apply_expression_template`` bodies (metavars
    bound from ``bindings``) and auto-applied ``match``-rule bodies (metavars
    bound by structural matching).

    STRUCTURAL SHARING (nested-template OOM fix; mirrors the Julia binding):
    bound ASTs are spliced BY REFERENCE, not deep-copied, the walk is
    identity-preserving (a subtree containing no bound metavariable is returned
    as the same object), and it is memoized on node identity so a subtree shared
    under many parents is rewritten once. The expanded document is therefore a
    DAG whose serialized form is byte-identical to the old tree — every
    downstream pass must treat expanded nodes as immutable (all load-path passes
    are functional or idempotent-in-place). Without this, a chain of templates
    each referencing its predecessor twice expands to 2^depth copies of the leaf
    and OOMs the loader well within the documented depth limits.
    """
    # Bespoke (not on :func:`_walk_json`): this REBUILDS the tree with shared
    # subtrees spliced in rather than merely observing it, so it stays a
    # dedicated pass. The memo stores ``(node, result)`` so the keyed object
    # stays alive alongside its entry (ids must not be recycled mid-walk).
    memo: dict[int, tuple[Any, Any]] = {}

    def sub(node: Any) -> Any:
        if isinstance(node, str):
            if node in bindings:
                return bindings[node]  # spliced by reference (shared DAG)
            return node
        if _is_array(node):
            hit = memo.get(id(node))
            if hit is not None:
                return hit[1]
            out: Any = [sub(c) for c in node]
            if all(o is c for o, c in zip(out, node)):
                out = node  # identity-preserving: nothing bound below here
            memo[id(node)] = (node, out)
            return out
        if _is_object(node):
            hit = memo.get(id(node))
            if hit is not None:
                return hit[1]
            # esm-spec §9.6.3 constraint 5 / §9.6.4 rule 4 (Option B):
            # parameter substitution applies inside a nested
            # ``apply_expression_template`` reference's ``bindings`` values
            # exactly as any other Expression position, but the ``name`` field
            # is NEVER a substitution site.
            is_apply = node.get("op") == APPLY_OP
            out = {k: (v if (is_apply and k == "name") else sub(v)) for k, v in node.items()}
            if all(out[k] is v for k, v in node.items()):
                out = node
            memo[id(node)] = (node, out)
            return out
        return node

    return sub(body)


# --- static match-scoping constraints (`where`, esm-spec §9.6.1) --------------
#
# docs/content/rfcs/match-pattern-scoping-constraints.md


def _component_shape_env(comp: dict) -> dict[str, list]:
    """The static shape environment of one component: every declared variable
    name mapped to its declared ``shape`` (ordered index-set names). This is the
    ONLY information a ``where`` constraint may consult (esm-spec §9.6.1) —
    declared shapes at lowering time, never runtime values — so constraint
    evaluation is fully static and the §9.6.3 determinism contract is untouched.
    Variables with no ``shape`` (scalars) are absent, as are species/parameters
    of reaction systems (no ``shape`` field): a shape-constrained rule can only
    fire on a declared, shaped model variable."""
    env: dict[str, list] = {}
    vars_ = comp.get("variables") if _is_object(comp) else None
    if not _is_object(vars_):
        return env
    for vn, vd in vars_.items():
        if not _is_object(vd):
            continue
        shp = vd.get("shape")
        if not _is_array(shp):
            continue
        if not all(isinstance(s, str) for s in shp):
            continue
        env[str(vn)] = [str(s) for s in shp]
    return env


def _where_satisfied(
    where_c: dict[str, list] | None, bindings: dict, shape_env: dict[str, list]
) -> bool:
    """Evaluate a registered ``where`` constraint map (param -> required shape)
    against the bindings produced by a successful structural match (esm-spec
    §9.6.1). A constraint on param ``p`` holds iff ``bindings[p]`` is a BARE
    variable-reference string naming an entry of ``shape_env`` whose declared
    shape equals the required list exactly (same names, same order). Everything
    else — a compound sub-AST, a numeric literal, a scalar-field-bound literal, a
    scoped (``System.var``) reference, an undeclared name, a scalar variable, or
    a param that never bound — fails the constraint. Deliberately syntactic and
    conservative: no shape inference over compound expressions, so eligibility
    depends only on declarations and is byte-identical across bindings."""
    if where_c is None:
        return True
    for p, req in where_c.items():
        b = bindings.get(p)
        if not isinstance(b, str):
            return False
        shp = shape_env.get(b)
        if shp is None:
            return False
        if shp != req:
            return False
    return True


def _registered_where(
    decl: dict, iset_names: set, scope: str, tname: str
) -> dict[str, list] | None:
    """Normalize a template's ``where`` block into the registered constraint map
    (param -> required shape list), checking every referenced index-set name
    against the CONSUMING document's merged ``index_sets`` registry
    (``iset_names``). An unknown name is ``template_constraint_unknown_index_set``
    (esm-spec §9.6.6) — raised here, at rule registration in the consuming
    component, not when a library file is loaded standalone: constraints name
    index sets as spelled in the consuming document's registry (post-§9.7.5
    merge, composing with import-edge index-set renaming)."""
    whr = decl.get("where")
    if whr is None:
        return None
    out: dict[str, list] = {}
    for p, cobj in whr.items():
        shp = cobj.get("shape")
        req = [str(s) for s in shp]
        for s in req:
            if s not in iset_names:
                raise ExpressionTemplateError(
                    TEMPLATE_CONSTRAINT_UNKNOWN_INDEX_SET,
                    f"{scope}.expression_templates.{tname}: where.{p}.shape "
                    f"names index set '{s}', which the consuming document's "
                    "index_sets registry does not declare "
                    "(esm-spec §9.6.1/§9.6.6)",
                )
        out[str(p)] = req
    return out


# --- match-rule machinery (auto-applied rewrite rules, esm-spec §9.6) ---------
#
# A MatchRule pairs a pattern Expression with a replacement body. ``params`` are
# the metavariables: a param appearing in an operand/``args`` position binds to
# the matched sub-AST; a param in a scalar field (``dim``, ``side``, an
# ``attrs.<key>``, ...) binds to the matched literal. The same ``_match``
# recursion handles both positions. ``priority`` (integer, default 0) is the
# selection precedence when several rules match one node; ``decl_index`` is the
# 0-based declaration order used to break priority ties (earliest wins).


class MatchRule:
    __slots__ = ("name", "pattern", "params", "body", "priority", "decl_index", "where_c")

    def __init__(
        self,
        name: str,
        pattern: Any,
        params: set,
        body: Any,
        priority: int,
        decl_index: int,
        where_c: dict[str, list] | None = None,
    ) -> None:
        self.name = name
        self.pattern = pattern
        self.params = params
        self.body = body
        self.priority = priority
        self.decl_index = decl_index
        # Registered `where` match-scoping constraint (param -> required shape),
        # or None (esm-spec §9.6.1). See :func:`_registered_where`.
        self.where_c = where_c


def _merge_bindings(acc: dict, new: dict) -> bool:
    """Merge ``new`` into ``acc``; a repeated metavariable must bind structurally
    equal sub-ASTs. Returns False on a conflicting re-bind."""
    for k, v in new.items():
        if k in acc:
            if acc[k] != v:
                return False
        else:
            acc[k] = v
    return True


def _match(pattern: Any, node: Any, params: set):
    """Structurally match ``pattern`` against ``node``. Returns a dict of
    metavariable bindings on success, or ``None`` on failure. A bare-string
    pattern that is a param is a wildcard binding to whatever ``node`` is;
    otherwise literals must compare equal and dict/list shapes must agree."""
    if isinstance(pattern, str):
        if pattern in params:
            return {pattern: node}
        return {} if (isinstance(node, str) and node == pattern) else None
    if isinstance(pattern, bool):
        return {} if (isinstance(node, bool) and node == pattern) else None
    if isinstance(pattern, (int, float)):
        # bool is a subclass of int; keep True/1 distinct from a numeric literal.
        if isinstance(node, bool):
            return None
        return {} if (isinstance(node, (int, float)) and node == pattern) else None
    if _is_array(pattern):
        if not _is_array(node) or len(node) != len(pattern):
            return None
        acc: dict = {}
        for p, n in zip(pattern, node):
            b = _match(p, n, params)
            if b is None or not _merge_bindings(acc, b):
                return None
        return acc
    if _is_object(pattern):
        if not _is_object(node):
            return None
        acc = {}
        for k, pv in pattern.items():
            if k not in node:
                return None
            b = _match(pv, node[k], params)
            if b is None or not _merge_bindings(acc, b):
                return None
        return acc
    # None or any other scalar: exact equality.
    return {} if node == pattern else None


def _rule_priority(decl: dict) -> int:
    """The ``priority`` of a ``match`` rule (esm-spec §9.6.3): higher fires
    first, ties break by declaration order. Absent ⇒ ``0``. The schema constrains
    ``priority`` to an integer; any numeric encoding is coerced defensively (a
    bool never counts as a priority)."""
    p = decl.get("priority")
    if p is None or isinstance(p, bool):
        return 0
    if isinstance(p, int):
        return p
    if isinstance(p, float):
        return int(round(p))
    return 0


def _build_match_rules(templates: dict, scope: str, iset_names: set) -> list:
    """Collect the ``match``-carrying templates as auto-applied rewrite rules,
    pre-sorted for deterministic selection (esm-spec §9.6.3): highest
    ``priority`` first, ties broken by DECLARATION order (earliest wins). The
    ``_rewrite_pass`` walk then fires the FIRST rule in this order that matches a
    node AND whose ``where`` constraints hold. Each rule's ``where`` block is
    normalized and its index-set names resolved against the consuming document's
    merged registry (``iset_names``; ``template_constraint_unknown_index_set``).
    Nontermination is NOT checked here — the bounded fixpoint
    (``MAX_REWRITE_PASSES``) is the sole termination guard."""
    rules: list = []
    for decl_index, (name, decl) in enumerate(templates.items()):
        if "match" not in decl:
            continue
        where_c = _registered_where(decl, iset_names, scope, name)
        rules.append(
            MatchRule(
                name,
                decl["match"],
                set(decl["params"]),
                decl["body"],
                _rule_priority(decl),
                decl_index,
                where_c,
            )
        )
    rules.sort(key=lambda r: (-r.priority, r.decl_index))
    return rules


def _expand_apply(node: dict, templates: dict, scope: str) -> Any:
    name = node.get("name")
    if not isinstance(name, str) or not name:
        raise ExpressionTemplateError(
            APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
            f"{scope}: apply_expression_template node missing or empty 'name'",
        )
    decl = templates.get(name)
    if decl is None:
        raise ExpressionTemplateError(
            APPLY_EXPRESSION_TEMPLATE_UNKNOWN_TEMPLATE,
            f"{scope}: apply_expression_template references undeclared template '{name}'",
        )
    bindings = node.get("bindings")
    if not _is_object(bindings):
        raise ExpressionTemplateError(
            APPLY_EXPRESSION_TEMPLATE_BINDINGS_MISMATCH,
            f"{scope}: apply_expression_template '{name}' missing 'bindings' object",
        )
    declared = set(decl["params"])
    provided = set(bindings.keys())
    for p in decl["params"]:
        if p not in provided:
            raise ExpressionTemplateError(
                APPLY_EXPRESSION_TEMPLATE_BINDINGS_MISMATCH,
                f"{scope}: apply_expression_template '{name}' missing binding for param '{p}'",
            )
    for p in provided:
        if p not in declared:
            raise ExpressionTemplateError(
                APPLY_EXPRESSION_TEMPLATE_BINDINGS_MISMATCH,
                f"{scope}: apply_expression_template '{name}' supplies unknown param '{p}'",
            )
    # Outermost-first (esm-spec §9.6.3): the template ``body`` is instantiated by
    # pure structural substitution with the bindings' sub-ASTs spliced in as-is.
    # It is NOT re-scanned within this pass; any apply / match ops it introduces
    # (including inside the substituted bindings) are rewritten in subsequent
    # passes, up to the bounded fixpoint.
    resolved = dict(bindings.items())
    return _substitute(decl["body"], resolved)


def _validate_apply_ref(node: dict, templates: dict, scope: str) -> None:
    """Call-site check for a SURVIVING (non-expanded) ``apply_expression_template``
    reference (esm-spec §9.6.9): the referenced ``name`` must resolve to an
    in-scope MATCH-LESS template and ``bindings`` must cover its ``params``
    exactly. Same diagnostics as :func:`_expand_apply`
    (``apply_expression_template_unknown_template`` /
    ``apply_expression_template_bindings_mismatch``), but WITHOUT expanding — the
    reference is preserved (§9.6.4 rule 1)."""
    name = node.get("name")
    if not isinstance(name, str) or not name:
        raise ExpressionTemplateError(
            APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
            f"{scope}: apply_expression_template node missing or empty 'name'",
        )
    decl = templates.get(name)
    if decl is None:
        raise ExpressionTemplateError(
            APPLY_EXPRESSION_TEMPLATE_UNKNOWN_TEMPLATE,
            f"{scope}: apply_expression_template references undeclared template '{name}'",
        )
    if _is_object(decl) and decl.get("match") is not None:
        raise ExpressionTemplateError(
            APPLY_EXPRESSION_TEMPLATE_UNKNOWN_TEMPLATE,
            f"{scope}: apply_expression_template references '{name}', a `match` "
            "rewrite rule — only match-less templates are invocable by name "
            "(esm-spec §9.6.2)",
        )
    bindings = node.get("bindings")
    if not _is_object(bindings):
        raise ExpressionTemplateError(
            APPLY_EXPRESSION_TEMPLATE_BINDINGS_MISMATCH,
            f"{scope}: apply_expression_template '{name}' missing 'bindings' object",
        )
    declared = set(decl.get("params", []))
    provided = set(bindings.keys())
    for p in decl.get("params", []):
        if p not in provided:
            raise ExpressionTemplateError(
                APPLY_EXPRESSION_TEMPLATE_BINDINGS_MISMATCH,
                f"{scope}: apply_expression_template '{name}' missing binding for param '{p}'",
            )
    for p in provided:
        if p not in declared:
            raise ExpressionTemplateError(
                APPLY_EXPRESSION_TEMPLATE_BINDINGS_MISMATCH,
                f"{scope}: apply_expression_template '{name}' supplies unknown param '{p}'",
            )


def _check_surviving_refs(node: Any, templates: dict, scope: str) -> None:
    """Walk ``node`` and run :func:`_validate_apply_ref` on every surviving
    ``apply_expression_template`` reference it carries (esm-spec §9.6.9 call-site
    checks). Descends into references' ``bindings`` too — a binding value MAY
    itself be a surviving reference. Deduped for a shared DAG."""

    def _visit(obj: dict, _path: str) -> None:
        if obj.get("op") == APPLY_OP:
            _validate_apply_ref(obj, templates, scope)

    _walk_json(node, on_obj=_visit, dedup=True)


# ---------------------------------------------------------------------------
# Eager-expansion carve-out: the rewrite-target op tier T (esm-spec §9.6.4
# rule 3 / RFC out-of-line-expression-templates §7.2)
# ---------------------------------------------------------------------------

#: The rewrite-target ops explicitly named by §4.2 as the open rewrite-target
#: tier plus the two load-eliminated forms — the members of **T** that carry a
#: recognized op name. Any op that is NOT in the evaluable-core registry
#: (:mod:`earthsci_ast.op_registry`) is ALSO in T (an open-namespace custom op
#: no evaluator implements); ``apply_expression_template`` itself is excluded.
_REWRITE_TARGET_OPS = frozenset(
    {"D", "grad", "div", "laplacian", "integral", "table_lookup", "enum"}
)


def _op_in_T(op: str) -> bool:
    """True iff op string ``op`` is a member of the rewrite-target tier **T**
    (esm-spec §9.6.4 rule 3): one of the named rewrite-target ops, or an op with
    no evaluable-core registry entry (an open-namespace custom op). The template
    reference op itself is never in T."""
    if op == APPLY_OP:
        return False
    if op in _REWRITE_TARGET_OPS:
        return True
    return not op_registry.is_known(op)


def _direct_T_op(node: Any) -> bool:
    """True iff ``node`` contains, ANYWHERE within it (descending through every
    field, including the ``bindings`` of nested ``apply_expression_template``
    nodes), an object whose ``op`` is in **T** (:func:`_op_in_T`). Does NOT
    follow references to other templates — that transitive step is
    :func:`_template_target_bearing`."""
    found = [False]

    def _visit(obj: dict, _path: str) -> None:
        if found[0]:
            return
        op = obj.get("op")
        if isinstance(op, str) and _op_in_T(op):
            found[0] = True

    _walk_json(node, on_obj=_visit, dedup=True)
    return found[0]


def _template_target_bearing(templates: dict) -> dict[str, bool]:
    """Compute, for every template in ``templates``, its **target-bearing** flag
    (esm-spec §9.6.4 rule 3): a template is target-bearing iff its body contains
    an op in **T** anywhere (including inside nested references' ``bindings``),
    OR it references — transitively through the §9.7.3-checked acyclic DAG — a
    target-bearing template. The DAG is acyclic (checked by
    :func:`_compose_template_bodies`), so a memoized DFS terminates."""
    tb: dict[str, bool] = {}
    inprogress: set[str] = set()

    def visit(name: str) -> bool:
        if name in tb:
            return tb[name]
        # Defensive against a cycle the checker somehow missed: treat an
        # in-progress node as non-contributing (acyclicity is enforced earlier).
        if name in inprogress:
            return False
        decl = templates.get(name)
        if decl is None:
            tb[name] = False
            return False
        inprogress.add(name)
        body = decl.get("body") if _is_object(decl) else None
        res = body is not None and _direct_T_op(body)
        if not res:
            for r in _collect_apply_names([], body):
                if r in templates and visit(r):
                    res = True
                    break
        inprogress.discard(name)
        tb[name] = res
        return res

    for name in templates:
        visit(name)
    return tb


def _ref_is_eager(node: dict, target_bearing: dict[str, bool]) -> bool:
    """Whether an ``apply_expression_template`` ``node`` is **eager** (esm-spec
    §9.6.4 rule 3): its referenced template is target-bearing, OR any of its
    ``bindings`` values contains an op in **T**. (After innermost-first eager
    expansion of the bindings, a "nested eager reference" always manifests as a
    T-op in the bindings, so this predicate subsumes that clause — see
    :func:`_expand_eager`.)"""
    name = node.get("name")
    if not isinstance(name, str):
        return False
    if target_bearing.get(name, False):
        return True
    b = node.get("bindings")
    if not _is_object(b):
        return False
    return _direct_T_op(b)


def _expand_eager(
    node: Any,
    templates: dict,
    target_bearing: dict[str, bool],
    scope: str,
    memo: dict[int, tuple] | None = None,
) -> Any:
    """The eager-expansion pre-pass (esm-spec §9.6.4 rule 3): expand — by pure
    substitution, innermost-first — every EAGER ``apply_expression_template``
    node, and only eager nodes. Non-eager (surviving) references are returned
    intact. Consumes no ``MAX_REWRITE_PASSES`` budget (a separate pre-pass).
    Sharing is preserved via an identity memo."""
    if memo is None:
        memo = {}
    if _is_object(node):
        hit = memo.get(id(node))
        if hit is not None:
            return hit[1]
        if node.get("op") == APPLY_OP:
            # Innermost-first: expand eager references inside the bindings first.
            b = node.get("bindings")
            newnode = node
            if _is_object(b):
                nb = {}
                changed = False
                for k, v in b.items():
                    rv = _expand_eager(v, templates, target_bearing, scope, memo)
                    if rv is not v:
                        changed = True
                    nb[k] = rv
                if changed:
                    newnode = {k: (nb if k == "bindings" else v) for k, v in node.items()}
            if _ref_is_eager(newnode, target_bearing):
                body = _expand_apply(newnode, templates, scope)
                res = _expand_eager(body, templates, target_bearing, scope, memo)
            else:
                res = newnode
        else:
            changed = False
            out = {}
            for k, v in node.items():
                rv = _expand_eager(v, templates, target_bearing, scope, memo)
                if rv is not v:
                    changed = True
                out[k] = rv
            res = out if changed else node
        memo[id(node)] = (node, res)
        return res
    if _is_array(node):
        hit = memo.get(id(node))
        if hit is not None:
            return hit[1]
        changed = False
        out = []
        for v in node:
            rv = _expand_eager(v, templates, target_bearing, scope, memo)
            if rv is not v:
                changed = True
            out.append(rv)
        res = out if changed else node
        memo[id(node)] = (node, res)
        return res
    return node


def _expand_all(node: Any, templates: dict, scope: str, memo: dict[int, tuple] | None = None) -> Any:
    """Fully expand EVERY ``apply_expression_template`` node in ``node`` by pure
    substitution to a fixpoint (innermost-first: bindings are expanded before
    the body is instantiated, and the instantiated body is re-expanded). This is
    the per-registry kernel of the public :func:`expand_document` /
    :func:`Expand` function (esm-spec §9.6.4 rule 2). Deterministic and
    sharing-preserving."""
    if memo is None:
        memo = {}
    if _is_object(node):
        hit = memo.get(id(node))
        if hit is not None:
            return hit[1]
        if node.get("op") == APPLY_OP:
            b = node.get("bindings")
            newnode = node
            if _is_object(b):
                nb = {}
                changed = False
                for k, v in b.items():
                    rv = _expand_all(v, templates, scope, memo)
                    if rv is not v:
                        changed = True
                    nb[k] = rv
                if changed:
                    newnode = {k: (nb if k == "bindings" else v) for k, v in node.items()}
            body = _expand_apply(newnode, templates, scope)
            res = _expand_all(body, templates, scope, memo)
        else:
            changed = False
            out = {}
            for k, v in node.items():
                rv = _expand_all(v, templates, scope, memo)
                if rv is not v:
                    changed = True
                out[k] = rv
            res = out if changed else node
        memo[id(node)] = (node, res)
        return res
    if _is_array(node):
        hit = memo.get(id(node))
        if hit is not None:
            return hit[1]
        changed = False
        out = []
        for v in node:
            rv = _expand_all(v, templates, scope, memo)
            if rv is not v:
                changed = True
            out.append(rv)
        res = out if changed else node
        memo[id(node)] = (node, res)
        return res
    return node


# Maximum number of productive rewrite passes before a file is rejected as
# non-converging (esm-spec §9.6.3, diagnostic ``rewrite_rule_nonterminating``).
# Pinned identically across all bindings so the accept/reject decision — and the
# resulting fixpoint — is byte-identical everywhere.
MAX_REWRITE_PASSES = 64


def _rewrite_pass(
    node: Any,
    templates: dict,
    sorted_rules: list,
    scope: str,
    last: list,
    shape_env: dict[str, list],
    target_bearing: dict[str, bool],
    memo: dict[int, tuple] | None = None,
) -> tuple:
    """One pre-order (outermost-first) rewrite pass over ``node`` (esm-spec
    §9.6.3). At each object node the engine first tries to fire a rule AT the
    node before descending:

    1. an ``apply_expression_template`` op is expanded (:func:`_expand_apply`), OR
    2. the first rule in ``sorted_rules`` (pre-sorted highest-``priority``-first,
       ties by declaration order) whose ``match`` pattern structurally matches
       the node AND whose ``where`` constraints (if any) are satisfied by the
       resulting bindings fires. Constraint filtering is part of match
       ELIGIBILITY (esm-spec §9.6.3 constraint 2): a constraint-excluded rule is
       treated exactly like a non-matching rule, so the scan proceeds to the
       next candidate in priority / declaration order.

    A fired rule's body replaces the node and the walk does NOT descend into that
    freshly-produced body during this pass (it is revisited next pass). If nothing
    fires, the walk descends into the node's children. Returns
    ``(new_node, changed)`` where ``changed`` is True iff any rewrite occurred in
    this subtree; ``last`` (a one-element list) records the op of the most recent
    rewrite for the non-convergence diagnostic. ``shape_env`` is the enclosing
    component's static shape environment (:func:`_component_shape_env`).

    The pass is IDENTITY-PRESERVING (an unchanged subtree is returned as the
    same object) and MEMOIZED on node identity via ``memo`` (one dict per pass):
    template substitution splices subtrees by reference, so the tree is really a
    DAG, and a subtree shared under many parents must be rewritten once, not
    once per path. Rewriting is a pure function of the node — matching is
    structural, and ``templates`` / ``sorted_rules`` / ``shape_env`` are
    pass-constant — so aliased visits are guaranteed to agree. The memo stores
    ``(node, new_node, changed)`` tuples: keeping the keyed node alive alongside
    its entry ensures ids are not recycled mid-pass.
    """
    if memo is None:
        memo = {}
    if _is_array(node):
        hit = memo.get(id(node))
        if hit is not None:
            return hit[1], hit[2]
        changed = False
        out: Any = []
        for c in node:
            nc, ch = _rewrite_pass(
                c, templates, sorted_rules, scope, last, shape_env, target_bearing, memo
            )
            out.append(nc)
            changed = changed or ch
        if not changed:
            out = node  # identity-preserving
        memo[id(node)] = (node, out, changed)
        return out, changed
    if not _is_object(node):
        return node, False
    hit = memo.get(id(node))
    if hit is not None:
        return hit[1], hit[2]
    # (1) Outermost-first: fire a rule AT this node before descending.
    if node.get("op") == APPLY_OP:
        # esm-spec §9.6.4 rule 4 (Option B): the engine treats a surviving
        # (non-eager) reference as a LEAF — it does not descend into its
        # ``bindings``, no rule fires inside it, and it survives the fixpoint.
        # Eager references were already removed by the pre-pass
        # (:func:`_expand_eager`); a defensive check keeps any eager node that a
        # caller passed in unexpanded correct.
        if _ref_is_eager(node, target_bearing):
            last[0] = APPLY_OP
            expanded = _expand_eager(node, templates, target_bearing, scope)
            memo[id(node)] = (node, expanded, True)
            return expanded, True
        memo[id(node)] = (node, node, False)
        return node, False
    for rule in sorted_rules:
        binds = _match(rule.pattern, node, rule.params)
        if binds is not None and _where_satisfied(rule.where_c, binds, shape_env):
            op = node.get("op")
            last[0] = op if isinstance(op, str) else ""
            # Instantiate by pure substitution (through nested references'
            # ``bindings``; ``name`` is never a site). An eager reference
            # introduced by the instantiation expands as part of the same
            # rewrite (§9.6.4 rule 4) via the pre-pass.
            replaced = _expand_eager(
                _substitute(rule.body, binds), templates, target_bearing, scope
            )
            memo[id(node)] = (node, replaced, True)
            return replaced, True
    # (2) No rule fired here — descend into children.
    changed = False
    out = {}
    for k, v in node.items():
        nv, ch = _rewrite_pass(
            v, templates, sorted_rules, scope, last, shape_env, target_bearing, memo
        )
        out[k] = nv
        changed = changed or ch
    if not changed:
        out = node  # identity-preserving
    memo[id(node)] = (node, out, changed)
    return out, changed


def _rewrite_to_fixpoint(
    node: Any,
    templates: dict,
    sorted_rules: list,
    scope: str,
    shape_env: dict[str, list] | None = None,
    target_bearing: dict[str, bool] | None = None,
) -> Any:
    """Drive :func:`_rewrite_pass` to a fixpoint (esm-spec §9.6.3): repeat
    pre-order passes until a pass performs zero rewrites, or reject the file with
    ``rewrite_rule_nonterminating`` once ``MAX_REWRITE_PASSES`` productive passes
    have run without converging. This bound — not a static check — is the
    authoritative termination guard, so a self-reintroducing rule fails to
    converge rather than being flagged up front. ``shape_env`` is the enclosing
    component's static shape environment for ``where`` constraint evaluation
    (esm-spec §9.6.1); an empty environment when omitted."""
    if shape_env is None:
        shape_env = {}
    if target_bearing is None:
        target_bearing = _template_target_bearing(templates)
    last = [""]
    # esm-spec §9.6.4 rule 3 / §7.1 step 5: the eager-expansion pre-pass runs
    # BEFORE the fixpoint and consumes no ``MAX_REWRITE_PASSES`` budget. It
    # removes every eager reference (target-bearing, or T-op in bindings) so the
    # fixpoint and the later ``unlowered_operator`` gate walk a tree in which no
    # rewrite-target op hides inside a surviving reference.
    current = _expand_eager(node, templates, target_bearing, scope)
    for _pass in range(MAX_REWRITE_PASSES):
        # Fresh identity memo per pass: rewriting is pure within one pass, but a
        # node's fate can change between passes (outermost-first re-visits
        # freshly produced bodies only on the NEXT pass).
        current, changed = _rewrite_pass(
            current, templates, sorted_rules, scope, last, shape_env, target_bearing, {}
        )
        if not changed:
            return current  # fixpoint reached
    raise ExpressionTemplateError(
        REWRITE_RULE_NONTERMINATING,
        f"{scope}: expression-template rewriting did not converge within "
        f"MAX_REWRITE_PASSES={MAX_REWRITE_PASSES} passes (last rewritten op "
        f"'{last[0]}'). A `match` rule likely re-introduces its own pattern "
        "(esm-spec §9.6.3).",
    )


def _find_apply_paths(view: Any, path: str = "") -> list[str]:
    hits: list[str] = []

    def _visit(node: dict, p: str) -> None:
        if node.get("op") == APPLY_OP:
            hits.append(p)

    # dedup: the post-expansion leftover scan runs over a shared DAG (see
    # _substitute); each unique node is checked once. Leftover applies can only
    # live in never-rewritten (hence unshared) regions, so the reported path
    # list is unchanged.
    _walk_json(view, on_obj=_visit, path=path, dedup=True)
    return hits


def reject_expression_templates_pre_v04(view: Any) -> None:
    """Reject template constructs in files declaring esm < 0.4.0.

    Mirrors the equivalent TS / Julia / Rust / Go checks for
    cross-binding-uniform diagnostics.
    """
    if not _is_object(view):
        return
    esm = view.get("esm")
    if not isinstance(esm, str):
        return
    m = re.match(r"^(\d+)\.(\d+)\.(\d+)$", esm)
    if not m:
        return
    major, minor = int(m.group(1)), int(m.group(2))
    if not (major == 0 and minor < 4):
        return

    offences: list[str] = []
    for compkind in ("models", "reaction_systems"):
        comps = view.get(compkind)
        if not _is_object(comps):
            continue
        for cname, comp in comps.items():
            if _is_object(comp) and "expression_templates" in comp:
                offences.append(f"/{compkind}/{cname}/expression_templates")
    offences.extend(_find_apply_paths(view))

    if offences:
        raise ExpressionTemplateError(
            APPLY_EXPRESSION_TEMPLATE_VERSION_TOO_OLD,
            f"expression_templates / apply_expression_template require esm >= "
            f"0.4.0; file declares {esm}. Offending paths: {', '.join(offences)}",
        )


def _has_template_machinery(file: dict) -> bool:
    """True if the document carries anything the §9.6.3 engine must process: any
    component with a NON-EMPTY ``expression_templates`` block (so match-less
    named fragments and `where`-carrying rules are still validated / composed at
    load, even absent an explicit invocation) or any ``apply_expression_template``
    op anywhere. Mirrors the Julia reference ``_has_template_machinery`` so the
    accept/validate decision is identical across bindings."""
    for compkind in ("models", "reaction_systems"):
        comps = file.get(compkind)
        if not _is_object(comps):
            continue
        for comp in comps.values():
            tplraw = _is_object(comp) and comp.get("expression_templates")
            if _is_object(tplraw) and len(tplraw) > 0:
                return True
    return bool(_find_apply_paths(file))


def _component_registry(comp: dict, scope: str, iset_names: set) -> tuple[dict, list, dict, dict]:
    """Build one component's rewrite registry from its ``expression_templates``
    block: the validated + body-CHECKED named-template dict, the pre-sorted
    ``match``-rule list (with registered ``where`` constraints resolved against
    ``iset_names``), the static shape environment for ``where`` evaluation
    (esm-spec §9.6.1), and the per-template target-bearing flags (§9.6.4 rule 3)
    driving the eager pre-pass and the surviving-reference leaf semantics. A
    component without a block yields ``({}, [], shape_env, {})``.
    """
    shape_env = _component_shape_env(comp)
    tplraw = comp.get("expression_templates")
    templates: dict[str, Any] = {}
    match_rules: list = []
    if _is_object(tplraw):
        for tname, tdecl in tplraw.items():
            templates[tname] = tdecl
        _validate_templates(templates, scope)
        # Registration-time body CHECKING (esm-spec §9.7.3, Option B): validate
        # the body-reference DAG (acyclic, depth-bounded, references resolve to
        # match-less templates). Bodies are NOT inlined — references are
        # preserved (§9.6.4). Imported at module level — the shared primitives
        # live in the json_walk leaf, so no cycle.
        _compose_template_bodies(templates, scope)
        match_rules = _build_match_rules(templates, scope, iset_names)
    target_bearing = _template_target_bearing(templates)
    return templates, match_rules, shape_env, target_bearing


def _rewrite_coupling_transforms(
    out: dict,
    registries: dict[str, dict[str, tuple[dict, list, dict, dict]]],
) -> None:
    """Rewrite dict-valued ``variable_map`` coupling transforms to fixpoint.

    An expression transform on a top-level ``coupling`` entry (in-progress-0.8.0
    widening) is rewritten with the SAME context (named templates + match rules)
    as a field of the RECEIVING component — the component named by the first
    dot-segment of the entry's ``to`` reference, looked up in ``models`` then
    ``reaction_systems``. If that component does not exist or declares no
    templates the transform is left unrewritten; a leftover
    ``apply_expression_template`` op is then caught by the document-wide
    leftover-apply diagnostic in :func:`lower_expression_templates`.
    """
    coupling = out.get("coupling")
    if not _is_array(coupling):
        return
    for idx, entry in enumerate(coupling):
        if not _is_object(entry) or entry.get("type") != "variable_map":
            continue
        transform = entry.get("transform")
        if not _is_object(transform):
            continue
        to_ref = entry.get("to")
        if not isinstance(to_ref, str) or not to_ref:
            continue
        cname = to_ref.split(".", 1)[0]
        reg = None
        for compkind in ("models", "reaction_systems"):
            if cname in registries[compkind]:
                reg = registries[compkind][cname]
                break
        if reg is None:
            continue
        templates, match_rules, shape_env, target_bearing = reg
        if not templates:
            continue
        entry["transform"] = _rewrite_to_fixpoint(
            transform,
            templates,
            match_rules,
            f"coupling[{idx}].transform",
            shape_env,
            target_bearing,
        )
        _check_surviving_refs(entry["transform"], templates, f"coupling[{idx}].transform")


#: The two post-expansion validators skip ``expression_templates`` blocks:
#: those hold pre-substitution trees where a param may legally occupy a scalar
#: field (manifold, makearray bound); enforcement is on the expanded form only.
_EXPR_TEMPLATES_SKIP = frozenset({"expression_templates"})


def _validate_geometry_manifolds(tree: Any, path: str = "") -> None:
    """Post-expansion validator (esm-spec §9.6.4): every ``intersect_polygon``
    / ``polygon_intersection_area`` node OUTSIDE an ``expression_templates``
    block must carry a ``manifold`` drawn from the closed set
    {planar, spherical, geodesic}.

    Template bodies are skipped — a parameter name in the ``manifold`` position
    of a ``body`` is a legal scalar-field substitution site (esm-spec §9.6.1);
    by the time this validator runs on a loaded document every such site has
    been substituted, so an out-of-set value here is a real defect (e.g. a
    template invocation binding the manifold parameter to a non-member
    literal). Raises :class:`ExpressionTemplateError` with code
    ``geometry_manifold_invalid``.
    """

    def _check(node: dict, p: str) -> None:
        if node.get("op") in _GEOMETRY_MANIFOLD_OPS and "manifold" in node:
            m = node["manifold"]
            if not (isinstance(m, str) and m in _GEOMETRY_MANIFOLD_VALUES):
                raise ExpressionTemplateError(
                    GEOMETRY_MANIFOLD_INVALID,
                    f"{p}: `{node.get('op')}` carries manifold {m!r}, not a "
                    "member of the closed set {planar, spherical, geodesic}. The "
                    "manifold enum is enforced on the expanded form (esm-spec "
                    "§9.6.4; CONFORMANCE_SPEC §5.8.4) — a template parameter "
                    "substituted into this scalar field must be bound to one of "
                    "the closed-set literals.",
                )

    # dedup: runs on the expanded (possibly shared-DAG) form; a defect node
    # shared under many parents raises once, at its first pre-order path —
    # identical to the unshared behavior.
    _walk_json(tree, on_obj=_check, skip_keys=_EXPR_TEMPLATES_SKIP, path=path, dedup=True)


def _validate_makearray_regions(x: Any, path: str = "") -> None:
    """Post-expansion validator (esm-spec §4.3.2 / §9.6.4): every ``makearray``
    region bound pair ``[start, stop]`` on the expanded, metaparameter-folded
    tree must satisfy ``stop >= start - 1``. ``stop == start - 1`` is the
    canonical EMPTY bound — the region covers no elements (the spelling an
    interior region like ``[2, N-1]`` folds to at the minimum admissible extent
    ``N = 2``). ``stop < start - 1`` is INVERTED and rejected with
    ``makearray_region_inverted``: almost always an authoring bug (an interior
    stencil instantiated below its minimum extent, e.g. ``[2, N-1]`` at ``N = 1``
    folding to ``[2, 0]``), and silently treating it as empty would hide the
    defect. Template bodies are skipped — pre-substitution bounds may legally
    carry metaparameter names; only concrete integer pairs are checked."""

    def _check(node: dict, p: str) -> None:
        if node.get("op") != "makearray":
            return
        regions = node.get("regions")
        if not _is_array(regions):
            return
        for ri, region in enumerate(regions):
            if not _is_array(region):
                continue
            for di, bounds in enumerate(region):
                if not (_is_array(bounds) and len(bounds) == 2):
                    continue
                lo, hi = bounds[0], bounds[1]
                if not (
                    isinstance(lo, int)
                    and not isinstance(lo, bool)
                    and isinstance(hi, int)
                    and not isinstance(hi, bool)
                ):
                    continue
                if hi < lo - 1:
                    raise ExpressionTemplateError(
                        MAKEARRAY_REGION_INVERTED,
                        f"{p}: makearray regions[{ri}] dimension {di} "
                        f"bound pair [{lo}, {hi}] is inverted (stop < "
                        "start - 1). An empty bound is spelled "
                        "[start, start-1] and contributes no elements "
                        "(esm-spec §4.3.2); a further-inverted pair is an "
                        "authoring error — e.g. an interior stencil region "
                        "[2, N-1] instantiated at N below the scheme's "
                        "minimum extent (§9.6.8).",
                    )

    # dedup: same shared-DAG rationale as _validate_geometry_manifolds.
    _walk_json(x, on_obj=_check, skip_keys=_EXPR_TEMPLATES_SKIP, path=path, dedup=True)


# ---------------------------------------------------------------------------
# Reference-aware validation discharge (esm-spec §9.6.9, Option B)
# ---------------------------------------------------------------------------


def _validate_makearray_regions_in_registries(
    registries: dict[str, dict[str, tuple[dict, list, dict, dict]]],
) -> None:
    """esm-spec §9.6.9: ``makearray_region_inverted`` is discharged at
    registration on the composed, metaparameter-folded template bodies — region
    bounds cannot carry template params (they are metaparameter expressions,
    §9.7.6), so the check is instantiation-independent. Every retained template
    body (match and match-less) is validated directly; its region bounds are
    already concrete integers."""
    for compkind in ("models", "reaction_systems"):
        for reg in registries.get(compkind, {}).values():
            templates = reg[0]
            for tname, decl in templates.items():
                body = decl.get("body") if _is_object(decl) else None
                if body is not None:
                    _validate_makearray_regions(body, f"expression_templates.{tname}/body")


def _template_manifold_bearing(named: dict) -> dict[str, bool]:
    """Which templates can produce a geometry-kernel node
    (:data:`_GEOMETRY_MANIFOLD_OPS`) — directly in the body or transitively
    through a referenced template. Only references to these templates need
    per-instantiation manifold validation (§9.6.9); everything else is skipped,
    so a geometry-free document pays nothing."""

    def direct(node: Any) -> bool:
        found = [False]

        def _visit(obj: dict, _path: str) -> None:
            if found[0]:
                return
            if obj.get("op") in _GEOMETRY_MANIFOLD_OPS:
                found[0] = True

        _walk_json(node, on_obj=_visit, dedup=True)
        return found[0]

    mb: dict[str, bool] = {}
    inprog: set[str] = set()

    def visit(name: str) -> bool:
        if name in mb:
            return mb[name]
        if name in inprog:
            return False
        decl = named.get(name)
        if decl is None:
            mb[name] = False
            return False
        inprog.add(name)
        body = decl.get("body") if _is_object(decl) else None
        res = body is not None and direct(body)
        if not res:
            for r in _collect_apply_names([], body):
                if r in named and visit(r):
                    res = True
                    break
        inprog.discard(name)
        mb[name] = res
        return res

    for n in named:
        visit(n)
    return mb


def _validate_manifolds_in_refs(
    node: Any,
    named: dict,
    manifold_bearing: dict[str, bool],
    path: str,
    seen: dict[int, Any],
) -> None:
    if _is_array(node):
        if id(node) in seen:
            return
        seen[id(node)] = node
        for i, c in enumerate(node):
            _validate_manifolds_in_refs(c, named, manifold_bearing, f"{path}/{i}", seen)
        return
    if not _is_object(node):
        return
    if id(node) in seen:
        return
    seen[id(node)] = node
    name = node.get("name") if node.get("op") == APPLY_OP else None
    # Per-instantiation manifold check (§9.6.9): expand ONLY references whose
    # template can produce a geometry-kernel node; everything else is cheap.
    if isinstance(name, str) and manifold_bearing.get(name, False):
        try:
            expansion = _expand_all(node, named, path)
        except ExpressionTemplateError:
            expansion = None
        if expansion is not None:
            try:
                _validate_geometry_manifolds(expansion)
            except ExpressionTemplateError as e:
                if e.code != GEOMETRY_MANIFOLD_INVALID:
                    raise
                raise ExpressionTemplateError(
                    GEOMETRY_MANIFOLD_INVALID,
                    f"{path}: instantiation of template '{name}' — {e} "
                    "(esm-spec §9.6.9; per-instantiation manifold check)",
                ) from e
    for k, v in node.items():
        _validate_manifolds_in_refs(v, named, manifold_bearing, f"{path}/{k}", seen)


def _validate_geometry_manifolds_refaware(
    root: dict,
    registries: dict[str, dict[str, tuple[dict, list, dict, dict]]],
) -> None:
    """esm-spec §9.6.9: ``geometry_manifold_invalid`` is discharged
    per-instantiation (a ``manifold`` may be a template param), memoized. Direct
    geometry nodes in the reference-preserving tree are checked as before; every
    surviving ``apply_expression_template`` reference whose template can produce
    a geometry kernel is additionally expanded ONCE (memoized) and its expansion
    validated, so an inadmissible manifold bound at a call site is caught. The
    diagnostic reports (call-site path, template name, intra-body path)."""
    # Direct nodes on the reference-preserving tree (skips template blocks and
    # does not see manifold params hidden behind references).
    _validate_geometry_manifolds(root)
    for compkind in ("models", "reaction_systems"):
        comps = root.get(compkind)
        if not _is_object(comps):
            continue
        for cname, comp in comps.items():
            if not _is_object(comp):
                continue
            reg = registries.get(compkind, {}).get(cname)
            if reg is None:
                continue
            named = reg[0]
            manifold_bearing = _template_manifold_bearing(named)
            if not any(manifold_bearing.values()):
                continue  # no geometry: nothing to check
            seen: dict[int, Any] = {}
            for k, v in comp.items():
                if k == "expression_templates":
                    continue
                _validate_manifolds_in_refs(
                    v, named, manifold_bearing, f"{compkind}.{cname}.{k}", seen
                )


def lower_expression_templates(file: dict) -> dict:
    """Run the load-time rewrite fixpoint (esm-spec §9.6.3) over `file`,
    Option B (reference-preserving, esm-spec §9.6.4).

    Per component, an outermost-first / priority-ordered / bounded-fixpoint
    rewrite (:func:`_rewrite_to_fixpoint`) fires the component's ``match``
    rewrite rules and EAGERLY expands target-bearing
    ``apply_expression_template`` references (§9.6.4 rule 3), while NON-eager
    references SURVIVE the fixpoint (§9.6.4 rule 4). The per-component
    ``expression_templates`` blocks are RETAINED — emit materializes them
    (§9.6.4 rule 5) and :func:`expand_document` consumes them. Returns a new
    dict (does not mutate input). Rejects a file whose rewriting does not
    converge within ``MAX_REWRITE_PASSES`` passes with
    ``rewrite_rule_nonterminating``; call sites are checked for unknown template
    / bindings mismatch (§9.6.9).

    Pre-condition: the input has been schema-validated.
    """
    reject_expression_templates_pre_v04(file)

    if not _is_object(file):
        return file

    out = copy.deepcopy(file)
    # Nothing to do unless something triggers the engine: an explicit apply op
    # somewhere, or a component declaring a non-empty ``expression_templates``
    # block (so a match-less fragment or a `where`-carrying rule is still
    # validated / body-checked at load — mirrors the Julia reference gate).
    if not _has_template_machinery(out):
        # No expansion to run, but the §9.6.4 expanded-form validators still
        # apply — the raw tree IS the expanded form.
        _validate_geometry_manifolds(out)
        _validate_makearray_regions(out)
        return out

    # The consuming document's merged index_sets registry (post-§9.7.5): the
    # namespace `where` shape constraints resolve against at registration
    # (esm-spec §9.6.1 — `template_constraint_unknown_index_set` for a name not
    # declared here).
    iset_names: set = set()
    isets_raw = out.get("index_sets")
    if _is_object(isets_raw):
        iset_names = {str(k) for k in isets_raw.keys()}

    # Per-component rewrite registries (named templates + sorted match rules +
    # static shape environment + target-bearing flags), kept so top-level
    # coupling transforms can be rewritten in the RECEIVING component's context
    # after the per-component loop (see below). Keyed compkind -> component name;
    # lookup order is "models" then "reaction_systems".
    registries: dict[str, dict[str, tuple[dict, list, dict, dict]]] = {
        "models": {},
        "reaction_systems": {},
    }
    for compkind in ("models", "reaction_systems"):
        comps = out.get(compkind)
        if not _is_object(comps):
            continue
        for cname, comp in comps.items():
            if not _is_object(comp):
                continue
            templates, match_rules, shape_env, target_bearing = _component_registry(
                comp, f"{compkind}.{cname}", iset_names
            )
            registries[compkind][cname] = (templates, match_rules, shape_env, target_bearing)
            for k in list(comp.keys()):
                if k == "expression_templates":
                    continue
                comp[k] = _rewrite_to_fixpoint(
                    comp[k],
                    templates,
                    match_rules,
                    f"{compkind}.{cname}.{k}",
                    shape_env,
                    target_bearing,
                )
                # Call-site checks on surviving references (§9.6.9): unknown
                # name / bindings mismatch. Known surviving references are the
                # new normal (Option B) — no longer an error.
                _check_surviving_refs(comp[k], templates, f"{compkind}.{cname}.{k}")
            # esm-spec §9.6.4 rule 1 (Option B): DO NOT delete the component's
            # ``expression_templates`` block — it is the retained registered
            # registry that emit materializes (§9.6.4 rule 5) and
            # :func:`expand_document` consumes (§9.6.4 rule 2).

    _rewrite_coupling_transforms(out, registries)

    # esm-spec §9.6.4 rule 1 (Option B): surviving ``apply_expression_template``
    # references are the NEW NORMAL. Only UNKNOWN-name / bindings-mismatch
    # references are errors — already checked per component / per transform by
    # ``_check_surviving_refs``. No global "no apply ops remain" gate.

    # Validation discharge (esm-spec §9.6.9): geometry-manifold and
    # makearray-region checks on the reference-preserving form. The manifold
    # check is per-instantiation (a ``manifold`` may be a template param), so it
    # descends through surviving references' single-instantiation expansions,
    # memoized. Region bounds cannot carry template params, so the makearray
    # check runs on the reference-preserving tree AND the retained folded
    # template bodies directly.
    _validate_geometry_manifolds_refaware(out, registries)
    _validate_makearray_regions(out)
    _validate_makearray_regions_in_registries(registries)
    return out


# ===========================================================================
# `Expand` — the public full-expansion function (esm-spec §9.6.4 rule 2)
# ===========================================================================


def expand_document(loaded: Any) -> Any:
    """Fully expand every surviving ``apply_expression_template`` reference in a
    document ``loaded`` by :func:`lower_expression_templates` (Option B),
    producing the Option-A image: every reference replaced by its expansion
    (pure substitution to the acyclic fixpoint, §9.6.4 rule 2) and every
    per-component ``expression_templates`` block stripped. Deterministic — the
    DAG is acyclic and substitution confluent, so ``expand_document(load(f))``
    is structurally equal to the pre-0.9.0 expanded form (the ``expanded*.esm``
    conformance oracle, §9.6.7). Non-destructive: ``loaded`` is deep copied
    first."""
    if not _is_object(loaded):
        return loaded
    root = copy.deepcopy(loaded)

    # Capture each component's named registry BEFORE stripping the blocks.
    comp_named: dict[tuple[str, str], dict] = {}
    for compkind in ("models", "reaction_systems"):
        comps = root.get(compkind)
        if not _is_object(comps):
            continue
        for cname, comp in comps.items():
            if not _is_object(comp):
                continue
            named: dict[str, Any] = {}
            tpl = comp.get("expression_templates")
            if _is_object(tpl):
                for n, d in tpl.items():
                    named[str(n)] = d
            comp_named[(compkind, cname)] = named

    for compkind in ("models", "reaction_systems"):
        comps = root.get(compkind)
        if not _is_object(comps):
            continue
        for cname, comp in comps.items():
            if not _is_object(comp):
                continue
            named = comp_named[(compkind, cname)]
            scope = f"{compkind}.{cname}"
            for k in list(comp.keys()):
                if k in ("expression_templates", "expression_template_imports"):
                    continue
                comp[k] = _expand_all(comp[k], named, f"{scope}.{k}")
            comp.pop("expression_templates", None)

    coupling = root.get("coupling")
    if _is_array(coupling):
        for i, entry in enumerate(coupling):
            if not _is_object(entry) or entry.get("type") != "variable_map":
                continue
            tr = entry.get("transform")
            if not _is_object(tr):
                continue
            target = entry.get("to")
            if not isinstance(target, str):
                continue
            comp_name = target.split(".", 1)[0]
            named = comp_named.get(("models", comp_name)) or comp_named.get(
                ("reaction_systems", comp_name)
            )
            if named is None:
                continue
            entry["transform"] = _expand_all(tr, named, f"coupling[{i}].transform")

    return root


#: Public alias for :func:`expand_document` using the spec's spelling
#: (esm-spec §9.6.4 rule 2). ``Expand ∘ load`` reproduces the Option-A form.
Expand = expand_document


# ===========================================================================
# Reference-preserving emit (esm-spec §9.6.4 rule 5, §9.6.7)
# ===========================================================================


def _ref_closure(refnames: Any, named: dict) -> set[str]:
    """The transitive closure of the templates named by ``refnames``
    (surviving-reference names), following references inside materialized bodies,
    keeping only MATCH-LESS entries (esm-spec §9.6.4 rule 5: match rules are
    never materialized)."""
    out: set[str] = set()
    stack = list(refnames)
    while stack:
        n = stack.pop()
        if n in out or n not in named:
            continue
        decl = named[n]
        if _is_object(decl) and decl.get("match") is not None:
            continue  # match rules not materialized
        out.add(n)
        body = decl.get("body") if _is_object(decl) else None
        stack.extend(_collect_apply_names([], body))
    return out


def _authored_template_names(raw_source: Any) -> dict[str, list[str]]:
    """Per-component MATCH-LESS template names authored in-file in ``raw_source``
    (``compkind.cname`` → ordered names). Emit keeps these verbatim as authored
    entries (esm-spec §9.6.4 rule 5); imported/derived templates are materialized
    instead."""
    authored: dict[str, list[str]] = {}
    if not _is_object(raw_source):
        return authored
    for compkind in ("models", "reaction_systems"):
        comps = raw_source.get(compkind)
        if not _is_object(comps):
            continue
        for cname, comp in comps.items():
            if not _is_object(comp):
                continue
            tpl = comp.get("expression_templates")
            if not _is_object(tpl):
                continue
            names: list[str] = []
            for n, d in tpl.items():
                if not _is_object(d):
                    continue
                if d.get("match") is not None:
                    continue
                names.append(str(n))
            authored[f"{compkind}.{cname}"] = names
    return authored


def emit_document(raw_source: Any, base_path: str) -> dict:
    """Produce the reference-preserving, self-contained emitted document
    (esm-spec §9.6.4 rule 5, RFC out-of-line-expression-templates §7.5) from a
    source document (a fixture, or an already-emitted document for the
    idempotency property). Loads ``raw_source`` under Option B, then for every
    component builds its emitted ``expression_templates`` block — authored
    match-less entries first in authored order, then the materialized transitive
    closure of its surviving references (match-less), lexicographically sorted —
    drops consumed ``expression_template_imports``, and version-stamps
    ``esm: 0.9.0`` when any surviving reference or materialized entry remains
    (§9.6.4 rule 8). ``emit_esm_string ∘ emit_document`` is a byte-wise fixed
    point under reload."""
    from .template_imports import resolve_template_machinery

    authored = _authored_template_names(raw_source)
    resolved = resolve_template_machinery(raw_source, base_path)
    loaded = lower_expression_templates(raw_source if resolved is None else resolved)
    root = loaded
    bump = False

    for compkind in ("models", "reaction_systems"):
        comps = root.get(compkind)
        if not _is_object(comps):
            continue
        for cname, comp in comps.items():
            if not _is_object(comp):
                continue
            key = f"{compkind}.{cname}"
            tpl = comp.get("expression_templates")
            named: dict[str, Any] = {}
            if _is_object(tpl):
                for n, d in tpl.items():
                    named[str(n)] = d
            refnames: set[str] = set()
            for k, v in comp.items():
                if k in ("expression_templates", "expression_template_imports"):
                    continue
                for r in _collect_apply_names([], v):
                    refnames.add(r)
            if refnames:
                bump = True
            materialized = _ref_closure(refnames, named)
            authored_here = authored.get(key, [])
            authored_set = set(authored_here)

            emit_block: dict[str, Any] = {}
            for n in authored_here:
                if n in named:
                    emit_block[n] = named[n]
            for n in sorted(materialized - authored_set):
                emit_block[n] = named[n]
                bump = True

            if emit_block:
                comp["expression_templates"] = emit_block
            else:
                comp.pop("expression_templates", None)
            comp.pop("expression_template_imports", None)

    root.pop("expression_template_imports", None)
    if bump:
        root["esm"] = "0.9.0"
    return root


# --- Canonical byte writer (2-space indent, keys sorted except the ordered
#     `expression_templates` block) — the cross-binding byte-identity surface. ---


def _emit_scalar(x: Any) -> str:
    """Render one JSON scalar for the canonical emit form. Integral finite
    floats render as integer literals (mirroring JSON3's read-normalization in
    the Julia reference: an integral number is written without a decimal point,
    uniformly), so the emitted bytes are cross-binding-identical; non-integral
    floats and strings render via ``json.dumps`` (``ensure_ascii=False`` keeps
    UTF-8 literals, matching JSON3's writer)."""
    if isinstance(x, bool):
        return "true" if x else "false"
    if isinstance(x, int):
        return str(x)
    if isinstance(x, float):
        if math.isfinite(x) and x.is_integer():
            return str(int(x))
        return json.dumps(x, ensure_ascii=False)
    return json.dumps(x, ensure_ascii=False)


def _emit_write(buf: list[str], x: Any, indent: int, preserve: bool = False) -> None:
    pad = "  " * indent
    pad1 = "  " * (indent + 1)
    if _is_object(x):
        if not x:
            buf.append("{}")
            return
        keys = list(x.keys()) if preserve else sorted(x.keys())
        buf.append("{\n")
        for i, k in enumerate(keys):
            buf.append(pad1)
            buf.append(json.dumps(str(k), ensure_ascii=False))
            buf.append(": ")
            _emit_write(buf, x[k], indent + 1, preserve=(str(k) == "expression_templates"))
            if i < len(keys) - 1:
                buf.append(",")
            buf.append("\n")
        buf.append(pad)
        buf.append("}")
    elif _is_array(x):
        if not x:
            buf.append("[]")
            return
        buf.append("[\n")
        for i, v in enumerate(x):
            buf.append(pad1)
            _emit_write(buf, v, indent + 1)
            if i < len(x) - 1:
                buf.append(",")
            buf.append("\n")
        buf.append(pad)
        buf.append("]")
    else:
        buf.append(_emit_scalar(x))


def emit_esm_string(doc: Any) -> str:
    """Canonical byte serialization of an emitted document (esm-spec §9.6.4
    rule 5): 2-space indent, object keys sorted lexicographically EXCEPT the
    entries of an ``expression_templates`` object, which preserve their
    authored-first / materialized-sorted order. The cross-binding byte-identity
    surface for the Option-B emitted form and the target of the ``emitted.esm``
    goldens."""
    buf: list[str] = []
    _emit_write(buf, doc, 0)
    buf.append("\n")
    return "".join(buf)


# ===========================================================================
# Flatten: template-registry merge (esm-spec §9.6.4 rule 7, §10.7;
# esm-libraries-spec §4.7.5)
# ===========================================================================


def _json_equal(a: Any, b: Any) -> bool:
    """Structural equality over the JSON view (dict / list / scalar / str),
    keeping ``bool`` distinct from numbers and int/float compared by value —
    mirroring the Julia reference ``_json_equal`` used by the flatten dedup."""
    if isinstance(a, bool) or isinstance(b, bool):
        return isinstance(a, bool) and isinstance(b, bool) and a == b
    if isinstance(a, (int, float)):
        return isinstance(b, (int, float)) and a == b
    if isinstance(a, str):
        return isinstance(b, str) and a == b
    if _is_array(a):
        if not _is_array(b) or len(a) != len(b):
            return False
        return all(_json_equal(x, y) for x, y in zip(a, b))
    if _is_object(a):
        if not _is_object(b) or set(a.keys()) != set(b.keys()):
            return False
        return all(_json_equal(a[k], b[k]) for k in a)
    return a is b or a == b


def _rename_apply_refs(node: Any, rename: dict[str, str]) -> Any:
    """Rewrite the ``name`` of every ``apply_expression_template`` reference in
    ``node`` according to ``rename`` (old name → new name), in lockstep with a
    registry rename. Sharing-preserving."""
    if _is_array(node):
        changed = False
        out = []
        for v in node:
            rv = _rename_apply_refs(v, rename)
            if rv is not v:
                changed = True
            out.append(rv)
        return out if changed else node
    if _is_object(node):
        is_apply = node.get("op") == APPLY_OP
        changed = False
        out = {}
        for k, v in node.items():
            if is_apply and k == "name" and isinstance(v, str) and v in rename:
                out[k] = rename[v]
                changed = True
            else:
                rv = _rename_apply_refs(v, rename)
                if rv is not v:
                    changed = True
                out[k] = rv
        return out if changed else node
    return node


def flatten_template_registries(loaded: Any) -> tuple[dict, dict]:
    """The flatten-time template-registry merge (esm-spec §9.6.4 rule 7, §10.7;
    esm-libraries-spec §4.7.5 step 4). Given an Option-B loaded multi-component
    document ``loaded``, merge every component's ``expression_templates``
    registry into a single document-scoped merged registry:

    - **Deep-equal dedup at first occurrence** — two components importing one
      stencil produce identical folded bodies, kept once under the bare name.
    - **Non-deep-equal same-name collision** — both entries are renamed
      deterministically to ``<ComponentPath>.<name>`` and their
      ``apply_expression_template`` references are rewritten in lockstep (total,
      deterministic; no new diagnostic).

    Returns the rewritten document ``root`` (component reference sites updated)
    and the merged registry as a dict (the FlattenedSystem's first-class
    registry field). ``match`` rules are not merged (only match-less templates
    are referenceable, §9.6.2)."""
    root = copy.deepcopy(loaded)
    # (path, compkind, cname, comp, named)
    comps: list[tuple[str, str, str, dict, dict]] = []
    for compkind in ("models", "reaction_systems"):
        cs = root.get(compkind)
        if not _is_object(cs):
            continue
        for cname, comp in cs.items():
            if not _is_object(comp):
                continue
            named: dict[str, Any] = {}
            tpl = comp.get("expression_templates")
            if _is_object(tpl):
                for n, d in tpl.items():
                    if _is_object(d) and d.get("match") is not None:
                        continue  # match rules not merged
                    named[str(n)] = d
            comps.append((cname, compkind, cname, comp, named))

    # Group each template name across components (preserving first-seen path).
    byname: dict[str, list[tuple[str, Any]]] = {}
    for path, _ck, _cn, _comp, named in comps:
        for n in sorted(named.keys()):
            byname.setdefault(n, []).append((path, named[n]))

    merged: dict[str, Any] = {}
    rename: dict[str, dict[str, str]] = {}  # path => (old => new)
    for name in sorted(byname.keys()):
        occ = byname[name]
        alleq = all(_json_equal(occ[0][1], o[1]) for o in occ)
        if alleq:
            merged[name] = occ[0][1]  # deep-equal dedup
        else:
            for path, decl in occ:  # collision: owner-path rename
                newname = f"{path}.{name}"
                merged[newname] = decl
                rename.setdefault(path, {})[name] = newname

    # Rewrite reference sites in lockstep (component expression positions and the
    # carried bodies of the renamed entries).
    for path, _ck, _cn, comp, _named in comps:
        rn = rename.get(path)
        if rn is not None:
            for k in list(comp.keys()):
                if k == "expression_templates":
                    continue
                comp[k] = _rename_apply_refs(comp[k], rn)
            # The merged (renamed) bodies owned by this path get their nested
            # references rewritten too.
            for _old, new in rn.items():
                if new in merged:
                    merged[new] = _rename_apply_refs(merged[new], rn)
        # Every component surrenders its per-component block to the merged
        # registry in the flattened form.
        comp.pop("expression_templates", None)

    return root, merged
