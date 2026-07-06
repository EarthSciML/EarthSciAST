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
import re
from typing import Any, Iterable

APPLY_OP = "apply_expression_template"

# Geometry-kernel ops whose `manifold` scalar field is restricted to the closed
# manifold registry (CONFORMANCE_SPEC §5.8.4). The document schema admits any
# string in the `manifold` position so a template `body` can carry a parameter
# name there (esm-spec §9.6.1 scalar-field substitution site); the closed set
# is enforced by :func:`_validate_geometry_manifolds` on the EXPANDED form per
# esm-spec §9.6.4.
_GEOMETRY_MANIFOLD_OPS = ("intersect_polygon", "polygon_intersection_area")
_GEOMETRY_MANIFOLD_VALUES = ("planar", "spherical", "geodesic")


class ExpressionTemplateError(Exception):
    """Raised when expression-template expansion fails.

    The ``code`` attribute carries one of the stable diagnostic codes:
    ``apply_expression_template_unknown_template``,
    ``apply_expression_template_bindings_mismatch``,
    ``apply_expression_template_recursive_body``,
    ``apply_expression_template_invalid_declaration``,
    ``apply_expression_template_version_too_old``,
    ``rewrite_rule_nonterminating``,
    ``template_constraint_unknown_index_set`` (§9.6.1 `where` scoping),
    ``makearray_region_inverted`` (§4.3.2 empty/inverted bounds),

    or one of the esm-spec §9.7 template-library / metaparameter codes
    (§9.6.6, raised from :mod:`earthsci_toolkit.template_imports` and
    :mod:`earthsci_toolkit.parse`):

    ``template_import_version_too_old``, ``template_import_unresolved``,
    ``template_import_not_library``, ``subsystem_ref_is_template_library``,
    ``template_import_cycle``, ``template_import_name_conflict``,
    ``template_import_unknown_name``, ``template_import_index_set_conflict``,
    ``template_body_expansion_too_deep``, ``metaparameter_unbound``,
    ``metaparameter_type_error``, ``metaparameter_name_conflict``,

    or one of the esm-spec §9.7.7 import-renaming codes (raised from
    :mod:`earthsci_toolkit.template_imports`):

    ``template_import_rename_unknown_name``,
    ``template_import_rebind_unknown_name``,
    ``template_import_rename_collision``, ``template_import_rename_invalid``.
    """

    def __init__(self, code: str, message: str) -> None:
        super().__init__(f"[{code}] {message}")
        self.code = code


def _is_object(v: Any) -> bool:
    return isinstance(v, dict)


def _is_array(v: Any) -> bool:
    return isinstance(v, list)


def _assert_no_nested_apply(body: Any, template_name: str, path: str) -> None:
    """Reject ``apply_expression_template`` nodes inside a ``match`` pattern
    (esm-spec §9.7.3: match patterns MUST NOT reference templates)."""
    if _is_array(body):
        for i, child in enumerate(body):
            _assert_no_nested_apply(child, template_name, f"{path}/{i}")
        return
    if _is_object(body):
        if body.get("op") == APPLY_OP:
            raise ExpressionTemplateError(
                "apply_expression_template_invalid_declaration",
                f"expression_templates.{template_name}: `match` contains an "
                f"'apply_expression_template' node at {path}; match patterns "
                "MUST NOT reference templates (esm-spec §9.7.3)",
            )
        for k, v in body.items():
            _assert_no_nested_apply(v, template_name, f"{path}/{k}")


def _validate_templates(templates: dict, scope: str) -> None:
    for name, decl in templates.items():
        if not _is_object(decl):
            raise ExpressionTemplateError(
                "apply_expression_template_invalid_declaration",
                f"{scope}.expression_templates.{name}: entry must be an object "
                "with params + body",
            )
        # ``params`` MAY be empty (esm-spec §9.6.1, 0.8.0): a zero-parameter
        # template is a named constant fragment (common in library files).
        params = decl.get("params")
        if not isinstance(params, list):
            raise ExpressionTemplateError(
                "apply_expression_template_invalid_declaration",
                f"{scope}.expression_templates.{name}: 'params' must be an "
                "array of strings",
            )
        seen: set[str] = set()
        for p in params:
            if not isinstance(p, str) or not p:
                raise ExpressionTemplateError(
                    "apply_expression_template_invalid_declaration",
                    f"{scope}.expression_templates.{name}: param names must "
                    "be non-empty strings",
                )
            if p in seen:
                raise ExpressionTemplateError(
                    "apply_expression_template_invalid_declaration",
                    f"{scope}.expression_templates.{name}: param '{p}' is "
                    "declared twice",
                )
            seen.add(p)
        if "body" not in decl:
            raise ExpressionTemplateError(
                "apply_expression_template_invalid_declaration",
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
                    "apply_expression_template_invalid_declaration",
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
                    "apply_expression_template_invalid_declaration",
                    f"{scope}.expression_templates.{name}: 'where' is only "
                    "admissible alongside 'match' — constraints scope an "
                    "auto-applied rewrite rule, not a named fragment "
                    "(esm-spec §9.6.1)",
                )
            if not (_is_object(whr) and whr):
                raise ExpressionTemplateError(
                    "apply_expression_template_invalid_declaration",
                    f"{scope}.expression_templates.{name}: 'where' must be a "
                    "non-empty object mapping declared params to constraint "
                    "objects",
                )
            for p, cobj in whr.items():
                ps = str(p)
                if ps not in seen:
                    raise ExpressionTemplateError(
                        "apply_expression_template_invalid_declaration",
                        f"{scope}.expression_templates.{name}: 'where' "
                        f"constrains '{ps}', which is not a declared param "
                        "(esm-spec §9.6.1)",
                    )
                if not _is_object(cobj):
                    raise ExpressionTemplateError(
                        "apply_expression_template_invalid_declaration",
                        f"{scope}.expression_templates.{name}: where.{ps} must "
                        "be a constraint object (v1 admits exactly the 'shape' "
                        "kind)",
                    )
                ckeys = {str(k) for k in cobj.keys()}
                if ckeys != {"shape"}:
                    kinds = ", ".join(sorted(ckeys))
                    raise ExpressionTemplateError(
                        "apply_expression_template_invalid_declaration",
                        f"{scope}.expression_templates.{name}: where.{ps} "
                        f"carries constraint kind(s) {kinds}; the v1 constraint "
                        "vocabulary is exactly {shape} (esm-spec §9.6.1)",
                    )
                shp = cobj.get("shape")
                if not (_is_array(shp) and shp):
                    raise ExpressionTemplateError(
                        "apply_expression_template_invalid_declaration",
                        f"{scope}.expression_templates.{name}: where.{ps}.shape "
                        "must be a non-empty array of index-set names",
                    )
                for s in shp:
                    if not (isinstance(s, str) and s):
                        raise ExpressionTemplateError(
                            "apply_expression_template_invalid_declaration",
                            f"{scope}.expression_templates.{name}: "
                            f"where.{ps}.shape entries must be non-empty strings",
                        )


def _substitute(body: Any, bindings: dict[str, Any]) -> Any:
    """Pure structural substitution: every bare-string occurrence of a bound
    metavariable in ``body`` is replaced by a deep copy of its bound AST/literal.

    This is the single substitution primitive of the rewrite engine — it
    instantiates both explicit ``apply_expression_template`` bodies (metavars
    bound from ``bindings``) and auto-applied ``match``-rule bodies (metavars
    bound by structural matching).
    """
    if isinstance(body, str):
        if body in bindings:
            return copy.deepcopy(bindings[body])
        return body
    if _is_array(body):
        return [_substitute(c, bindings) for c in body]
    if _is_object(body):
        return {k: _substitute(v, bindings) for k, v in body.items()}
    return body


# --- static match-scoping constraints (`where`, esm-spec §9.6.1) --------------
#
# docs/content/rfcs/match-pattern-scoping-constraints.md


def _component_shape_env(comp: dict) -> "dict[str, list]":
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


def _where_satisfied(where_c: "dict[str, list] | None", bindings: dict,
                     shape_env: "dict[str, list]") -> bool:
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


def _registered_where(decl: dict, iset_names: set, scope: str,
                      tname: str) -> "dict[str, list] | None":
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
                    "template_constraint_unknown_index_set",
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
    __slots__ = ("name", "pattern", "params", "body", "priority", "decl_index",
                 "where_c")

    def __init__(self, name: str, pattern: Any, params: set, body: Any,
                 priority: int, decl_index: int,
                 where_c: "dict[str, list] | None" = None) -> None:
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
        rules.append(MatchRule(
            name, decl["match"], set(decl["params"]), decl["body"],
            _rule_priority(decl), decl_index, where_c,
        ))
    rules.sort(key=lambda r: (-r.priority, r.decl_index))
    return rules


def _expand_apply(node: dict, templates: dict, scope: str) -> Any:
    name = node.get("name")
    if not isinstance(name, str) or not name:
        raise ExpressionTemplateError(
            "apply_expression_template_invalid_declaration",
            f"{scope}: apply_expression_template node missing or empty 'name'",
        )
    decl = templates.get(name)
    if decl is None:
        raise ExpressionTemplateError(
            "apply_expression_template_unknown_template",
            f"{scope}: apply_expression_template references undeclared "
            f"template '{name}'",
        )
    bindings = node.get("bindings")
    if not _is_object(bindings):
        raise ExpressionTemplateError(
            "apply_expression_template_bindings_mismatch",
            f"{scope}: apply_expression_template '{name}' missing 'bindings' "
            "object",
        )
    declared = set(decl["params"])
    provided = set(bindings.keys())
    for p in decl["params"]:
        if p not in provided:
            raise ExpressionTemplateError(
                "apply_expression_template_bindings_mismatch",
                f"{scope}: apply_expression_template '{name}' missing binding "
                f"for param '{p}'",
            )
    for p in provided:
        if p not in declared:
            raise ExpressionTemplateError(
                "apply_expression_template_bindings_mismatch",
                f"{scope}: apply_expression_template '{name}' supplies unknown "
                f"param '{p}'",
            )
    # Outermost-first (esm-spec §9.6.3): the template ``body`` is instantiated by
    # pure structural substitution with the bindings' sub-ASTs spliced in as-is.
    # It is NOT re-scanned within this pass; any apply / match ops it introduces
    # (including inside the substituted bindings) are rewritten in subsequent
    # passes, up to the bounded fixpoint.
    resolved = {k: v for k, v in bindings.items()}
    return _substitute(decl["body"], resolved)


# Maximum number of productive rewrite passes before a file is rejected as
# non-converging (esm-spec §9.6.3, diagnostic ``rewrite_rule_nonterminating``).
# Pinned identically across all bindings so the accept/reject decision — and the
# resulting fixpoint — is byte-identical everywhere.
MAX_REWRITE_PASSES = 64


def _rewrite_pass(node: Any, templates: dict, sorted_rules: list, scope: str,
                  last: list, shape_env: "dict[str, list]") -> tuple:
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
    """
    if _is_array(node):
        changed = False
        out = []
        for c in node:
            nc, ch = _rewrite_pass(c, templates, sorted_rules, scope, last,
                                   shape_env)
            out.append(nc)
            changed = changed or ch
        return out, changed
    if not _is_object(node):
        return node, False
    # (1) Outermost-first: fire a rule AT this node before descending.
    if node.get("op") == APPLY_OP:
        last[0] = APPLY_OP
        return _expand_apply(node, templates, scope), True
    for rule in sorted_rules:
        binds = _match(rule.pattern, node, rule.params)
        if binds is not None and _where_satisfied(rule.where_c, binds, shape_env):
            op = node.get("op")
            last[0] = op if isinstance(op, str) else ""
            return _substitute(rule.body, binds), True
    # (2) No rule fired here — descend into children.
    changed = False
    out = {}
    for k, v in node.items():
        nv, ch = _rewrite_pass(v, templates, sorted_rules, scope, last,
                               shape_env)
        out[k] = nv
        changed = changed or ch
    return out, changed


def _rewrite_to_fixpoint(node: Any, templates: dict, sorted_rules: list,
                         scope: str,
                         shape_env: "dict[str, list] | None" = None) -> Any:
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
    last = [""]
    current = node
    for _pass in range(MAX_REWRITE_PASSES):
        current, changed = _rewrite_pass(current, templates, sorted_rules,
                                         scope, last, shape_env)
        if not changed:
            return current  # fixpoint reached
    raise ExpressionTemplateError(
        "rewrite_rule_nonterminating",
        f"{scope}: expression-template rewriting did not converge within "
        f"MAX_REWRITE_PASSES={MAX_REWRITE_PASSES} passes (last rewritten op "
        f"'{last[0]}'). A `match` rule likely re-introduces its own pattern "
        "(esm-spec §9.6.3).",
    )


def _find_apply_paths(view: Any, path: str = "") -> list[str]:
    hits: list[str] = []

    def visit(v: Any, p: str) -> None:
        if _is_array(v):
            for i, child in enumerate(v):
                visit(child, f"{p}/{i}")
            return
        if _is_object(v):
            if v.get("op") == APPLY_OP:
                hits.append(p)
            for k, child in v.items():
                visit(child, f"{p}/{k}")

    visit(view, path)
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
            "apply_expression_template_version_too_old",
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


def _component_registry(comp: dict, scope: str,
                        iset_names: set) -> tuple[dict, list, dict]:
    """Build one component's rewrite registry from its ``expression_templates``
    block: the validated + body-composed named-template dict, the pre-sorted
    ``match``-rule list (with registered ``where`` constraints resolved against
    ``iset_names``), and the static shape environment for ``where`` evaluation
    (esm-spec §9.6.1). A component without a block yields ``({}, [], shape_env)``.
    """
    shape_env = _component_shape_env(comp)
    tplraw = comp.get("expression_templates")
    templates: dict[str, Any] = {}
    match_rules: list = []
    if _is_object(tplraw):
        for tname, tdecl in tplraw.items():
            templates[tname] = tdecl
        _validate_templates(templates, scope)
        # Registration-time body composition (esm-spec §9.7.3): inline
        # body references to match-less in-scope templates as a
        # statically-checked acyclic DAG, so every rule body the
        # fixpoint sees is a closed AST. Lazy import: template_imports
        # imports from this module at module level.
        from .template_imports import _compose_template_bodies
        _compose_template_bodies(templates, scope)
        match_rules = _build_match_rules(templates, scope, iset_names)
    return templates, match_rules, shape_env


def _rewrite_coupling_transforms(
    out: dict, registries: dict[str, dict[str, tuple[dict, list, dict]]],
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
        templates, match_rules, shape_env = reg
        if not templates:
            continue
        entry["transform"] = _rewrite_to_fixpoint(
            transform, templates, match_rules, f"coupling[{idx}].transform",
            shape_env,
        )


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
    if _is_array(tree):
        for i, child in enumerate(tree):
            _validate_geometry_manifolds(child, f"{path}/{i}")
        return
    if not _is_object(tree):
        return
    if tree.get("op") in _GEOMETRY_MANIFOLD_OPS and "manifold" in tree:
        m = tree["manifold"]
        if not (isinstance(m, str) and m in _GEOMETRY_MANIFOLD_VALUES):
            raise ExpressionTemplateError(
                "geometry_manifold_invalid",
                f"{path}: `{tree.get('op')}` carries manifold {m!r}, not a "
                "member of the closed set {planar, spherical, geodesic}. The "
                "manifold enum is enforced on the expanded form (esm-spec "
                "§9.6.4; CONFORMANCE_SPEC §5.8.4) — a template parameter "
                "substituted into this scalar field must be bound to one of "
                "the closed-set literals.",
            )
    for k, v in tree.items():
        if k == "expression_templates":
            # Pre-substitution template trees; params may legally occupy the
            # manifold position there (esm-spec §9.6.1).
            continue
        _validate_geometry_manifolds(v, f"{path}/{k}")


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
    if _is_array(x):
        for i, child in enumerate(x):
            _validate_makearray_regions(child, f"{path}/{i}")
        return
    if not _is_object(x):
        return
    if x.get("op") == "makearray":
        regions = x.get("regions")
        if _is_array(regions):
            for ri, region in enumerate(regions):
                if not _is_array(region):
                    continue
                for di, bounds in enumerate(region):
                    if not (_is_array(bounds) and len(bounds) == 2):
                        continue
                    lo, hi = bounds[0], bounds[1]
                    if not (isinstance(lo, int) and not isinstance(lo, bool)
                            and isinstance(hi, int) and not isinstance(hi, bool)):
                        continue
                    if hi < lo - 1:
                        raise ExpressionTemplateError(
                            "makearray_region_inverted",
                            f"{path}: makearray regions[{ri}] dimension {di} "
                            f"bound pair [{lo}, {hi}] is inverted (stop < "
                            "start - 1). An empty bound is spelled "
                            "[start, start-1] and contributes no elements "
                            "(esm-spec §4.3.2); a further-inverted pair is an "
                            "authoring error — e.g. an interior stencil region "
                            "[2, N-1] instantiated at N below the scheme's "
                            "minimum extent (§9.6.8).",
                        )
    for k, v in x.items():
        if k == "expression_templates":
            # Pre-substitution trees; bounds may carry metaparameter names or
            # fold later (esm-spec §9.7.6).
            continue
        _validate_makearray_regions(v, f"{path}/{k}")


def lower_expression_templates(file: dict) -> dict:
    """Run the load-time rewrite fixpoint (esm-spec §9.6.3) over `file`.

    Per component, an outermost-first / priority-ordered / bounded-fixpoint
    rewrite (:func:`_rewrite_to_fixpoint`) expands explicit
    ``apply_expression_template`` ops AND fires the component's ``match`` rewrite
    rules until no rule applies; the ``expression_templates`` blocks are then
    stripped. Returns a new dict (does not mutate input). Rejects a file whose
    rewriting does not converge within ``MAX_REWRITE_PASSES`` passes with
    ``rewrite_rule_nonterminating``.

    Pre-condition: the input has been schema-validated.
    """
    reject_expression_templates_pre_v04(file)

    if not _is_object(file):
        return file

    out = copy.deepcopy(file)
    # Nothing to do unless something triggers the engine: an explicit apply op
    # somewhere, or a component declaring a non-empty ``expression_templates``
    # block (so a match-less fragment or a `where`-carrying rule is still
    # validated / body-composed at load — mirrors the Julia reference gate).
    if not _has_template_machinery(out):
        # No expansion to run, but the §9.6.4 expanded-form validators still
        # apply — the raw tree IS the expanded form.
        _validate_geometry_manifolds(out)
        _validate_makearray_regions(out)
        return _strip_expression_templates(out)

    # The consuming document's merged index_sets registry (post-§9.7.5): the
    # namespace `where` shape constraints resolve against at registration
    # (esm-spec §9.6.1 — `template_constraint_unknown_index_set` for a name not
    # declared here).
    iset_names: set = set()
    isets_raw = out.get("index_sets")
    if _is_object(isets_raw):
        iset_names = {str(k) for k in isets_raw.keys()}

    # Per-component rewrite registries (named templates + sorted match rules +
    # static shape environment), kept so top-level coupling transforms can be
    # rewritten in the RECEIVING component's context after the per-component loop
    # (see below). Keyed compkind -> component name; lookup order is "models"
    # then "reaction_systems".
    registries: dict[str, dict[str, tuple[dict, list, dict]]] = {
        "models": {}, "reaction_systems": {},
    }
    for compkind in ("models", "reaction_systems"):
        comps = out.get(compkind)
        if not _is_object(comps):
            continue
        for cname, comp in comps.items():
            if not _is_object(comp):
                continue
            templates, match_rules, shape_env = _component_registry(
                comp, f"{compkind}.{cname}", iset_names)
            registries[compkind][cname] = (templates, match_rules, shape_env)
            for k in list(comp.keys()):
                if k == "expression_templates":
                    continue
                comp[k] = _rewrite_to_fixpoint(
                    comp[k], templates, match_rules, f"{compkind}.{cname}.{k}",
                    shape_env,
                )
            comp.pop("expression_templates", None)

    _rewrite_coupling_transforms(out, registries)

    leftover = _find_apply_paths(out)
    if leftover:
        raise ExpressionTemplateError(
            "apply_expression_template_unknown_template",
            f"apply_expression_template ops remain after expansion at: "
            f"{', '.join(leftover)} — likely referenced from a component lacking "
            "an expression_templates block",
        )
    # Validators run on the expanded form (esm-spec §9.6.4): reject any
    # geometry-kernel node whose (possibly just-substituted) `manifold` is
    # outside the closed set, and any makearray region whose folded bound pair
    # is inverted (stop < start - 1; esm-spec §4.3.2).
    _validate_geometry_manifolds(out)
    _validate_makearray_regions(out)
    return out


def _strip_expression_templates(file: dict) -> dict:
    for compkind in ("models", "reaction_systems"):
        comps = file.get(compkind)
        if not _is_object(comps):
            continue
        for comp in comps.values():
            if _is_object(comp):
                comp.pop("expression_templates", None)
    return file
