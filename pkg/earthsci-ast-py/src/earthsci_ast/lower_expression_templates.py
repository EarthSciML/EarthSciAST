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
walk of the tree. At each object node the ``match`` rules are consulted and the
winner is selected deterministically — highest ``priority`` (integer, default
0), ties broken by DECLARATION order. A firing writes a REFERENCE to the rule
bound to what the match captured (esm-spec §9.6.3 constraint 7,
:func:`_rule_reference`); the walk does NOT descend into it during the current
pass. At an ``apply_expression_template`` reference no pattern matches, but the
walk descends into the values of its ``bindings`` (§9.6.4 rule 4). Passes repeat
until a pass performs zero rewrites (the fixpoint); a rewrite whose depth (the
pass that made it) would exceed ``MAX_REWRITE_PASSES`` rejects the file with
``rewrite_rule_nonterminating`` (the bound — not a static check — is the
authoritative termination guard). Because selection and traversal are fully
deterministic, all bindings produce byte-identical fixpoints.

After the fixpoint of a component's expression positions, the component's rules
apply inside the bodies of the templates its references reach, once per
template instance (esm-spec §9.6.4 rule 3, :mod:`earthsci_ast.template_instances`).
No step of lowering inlines a template body: references survive, and
:func:`expand_document` (``Expand``, §9.6.4 rule 2) is the only expansion.

Operates on the pre-coercion JSON dict view, so it must run after
schema validation but before ``_parse_esm_data``.
"""

from __future__ import annotations

import contextlib
import contextvars
import copy
import json
import re
from collections.abc import Iterator
from typing import Any

from .error_handling import (
    APPLY_EXPRESSION_TEMPLATE_BINDINGS_MISMATCH,
    APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
    APPLY_EXPRESSION_TEMPLATE_UNKNOWN_TEMPLATE,
    APPLY_EXPRESSION_TEMPLATE_VERSION_TOO_OLD,
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
    _rewrite_json,
    _walk_json,
)

# ``emit_esm_string`` (the canonical Option-B byte writer) now lives next to
# ``serialize.save`` — the two JSON writers are co-located there. It is
# re-exported here so ``lower_expression_templates.emit_esm_string`` (used by the
# package ``__init__`` and tests, alongside :func:`emit_document`) keeps working.
from .serialize import (
    _emit_scalar,
    emit_esm_string,  # noqa: F401 — re-exported historical path
)
from .template_imports import _collect_apply_names, _compose_template_bodies


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

    # Routed through the shared sharing-preserving rebuild
    # (:func:`json_walk._rewrite_json`, ``share=True``): the identity-preserving,
    # id-memoized DAG rebuild is the combinator's job. This pass supplies only
    # the two substitution rules — a bound bare-string metavariable is spliced by
    # reference, and (esm-spec §9.6.3 constraint 5 / §9.6.4 rule 4, Option B) the
    # ``name`` field of a nested ``apply_expression_template`` is NEVER a
    # substitution site while every other value is.
    def _leaf(s: str) -> Any:
        return bindings[s] if s in bindings else s  # spliced by reference

    def _item(node: dict, key: str, value: Any, recurse) -> Any:
        if key == "name" and node.get("op") == APPLY_OP:
            return value
        return recurse(value)

    return _rewrite_json(body, on_str=_leaf, on_value=_item, share=True)


class _BodyView:
    """How the rewrite engine sees a template body it rewrites for one template
    instance (esm-spec §9.6.4 rule 3): ``params`` — the template's parameters,
    each a leaf; ``lit`` — the literal the instance binds to each parameter in a
    structural position (a scalar field, a ``ranges`` bound or ``from``, an
    ``enum`` argument); ``entries`` — each parameter's instance entry
    (:func:`earthsci_ast.template_instances._instance_entry`), which a ``where``
    ``shape`` constraint reads."""

    __slots__ = ("params", "lit", "entries")

    def __init__(self, params: set, lit: dict, entries: dict) -> None:
        self.params = params
        self.lit = lit
        self.entries = entries


class _NoLit:
    __slots__ = ()

    def __repr__(self) -> str:
        return "_NO_LIT"


#: Sentinel: a parameter its instance binds to no literal.
_NO_LIT = _NoLit()


def _canonical_compact(x: Any) -> str:
    """The canonical byte form of a raw JSON value (CONFORMANCE_SPEC §5.5.3):
    compact (``,`` and ``:`` separators), object keys sorted by UTF-8 bytes at
    every level, integral Int64-representable floats written as integers
    (§5.5.3.1 rule 1), other numbers as the emit writer writes them. Orders the
    variants of esm-spec §9.6.4 rule 3."""
    buf: list[str] = []

    def w(v: Any) -> None:
        if _is_object(v):
            buf.append("{")
            for i, k in enumerate(sorted(str(k) for k in v.keys())):
                if i:
                    buf.append(",")
                buf.append(json.dumps(k, ensure_ascii=False))
                buf.append(":")
                w(v[k])
            buf.append("}")
        elif _is_array(v):
            buf.append("[")
            for i, c in enumerate(v):
                if i:
                    buf.append(",")
                w(c)
            buf.append("]")
        else:
            buf.append(_emit_scalar(v))

    w(x)
    return "".join(buf)


def _shape_entry(shape: Any) -> str:
    """The instance entry of a bare variable with declared shape ``shape``."""
    return "V" + _canonical_compact(shape)


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
    where_c: dict[str, list] | None,
    bindings: dict,
    shape_env: dict[str, list],
    bv: _BodyView | None = None,
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
    depends only on declarations and is byte-identical across bindings.

    Inside a template body rewritten for one instance (``bv``, esm-spec §9.6.4
    rule 3), a captured value that is one of the body's parameters satisfies
    the constraint iff its instance binds a bare variable of exactly that
    declared shape (its instance entry is ``"V" + canonical(shape)``)."""
    if where_c is None:
        return True
    for p, req in where_c.items():
        b = bindings.get(p)
        if not isinstance(b, str):
            return False
        if bv is not None and b in bv.params:
            if bv.entries.get(b, "") != _shape_entry(req):
                return False
            continue
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
    __slots__ = (
        "name",
        "pattern",
        "params",
        "param_list",
        "body",
        "priority",
        "decl_index",
        "where_c",
    )

    def __init__(
        self,
        name: str,
        pattern: Any,
        params: set,
        body: Any,
        priority: int,
        decl_index: int,
        where_c: dict[str, list] | None = None,
        param_list: list[str] | None = None,
    ) -> None:
        self.name = name
        self.pattern = pattern
        self.params = params
        # ``params`` in declared order: the keys of the reference a firing
        # writes (esm-spec §9.6.3 constraint 7).
        self.param_list = list(param_list) if param_list is not None else sorted(params)
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


def _match(pattern: Any, node: Any, params: set, bv: _BodyView | None = None):
    """Structurally match ``pattern`` against ``node``. Returns a dict of
    metavariable bindings on success, or ``None`` on failure. A bare-string
    pattern that is a param is a wildcard binding to whatever ``node`` is;
    otherwise literals must compare equal and dict/list shapes must agree.

    Inside a template body rewritten for one instance (``bv``, esm-spec §9.6.4
    rules 3 and 4) a parameter of the body is a leaf: a metavariable captures it
    whole, and any other pattern node sees it only as the literal its instance
    binds in a structural position (and never matches an operand-position
    parameter)."""
    if (
        bv is not None
        and isinstance(node, str)
        and node in bv.params
        and not (isinstance(pattern, str) and pattern in params)
    ):
        lit = bv.lit.get(node, _NO_LIT)
        if lit is _NO_LIT:
            return None
        return _match(pattern, lit, params)
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
            b = _match(p, n, params, bv)
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
            b = _match(pv, node[k], params, bv)
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
                list(decl["params"]),
            )
        )
    rules.sort(key=lambda r: (-r.priority, r.decl_index))
    return rules


def _expand_apply(node: dict, templates: dict, scope: str) -> Any:
    # Call-site validation — name resolves to an in-scope MATCH-LESS template and
    # bindings cover its params exactly — is shared with the surviving-reference
    # check (:func:`_validate_apply_ref`); identical codes/messages, so the two
    # paths cannot diverge.
    _validate_apply_ref(node, templates, scope)
    decl = templates[node["name"]]
    # Outermost-first (esm-spec §9.6.3): the template ``body`` is instantiated by
    # pure structural substitution with the bindings' sub-ASTs spliced in as-is.
    # It is NOT re-scanned within this pass; any apply / match ops it introduces
    # (including inside the substituted bindings) are rewritten in subsequent
    # passes, up to the bounded fixpoint.
    resolved = dict(node["bindings"].items())
    return _substitute(decl["body"], resolved)


def _validate_apply_ref(
    node: dict, templates: dict, scope: str, reject_match_rule: bool = True
) -> None:
    """Call-site check for a SURVIVING (non-expanded) ``apply_expression_template``
    reference (esm-spec §9.6.9): the referenced ``name`` must resolve to an
    in-scope MATCH-LESS template and ``bindings`` must cover its ``params``
    exactly. Same diagnostics as :func:`_expand_apply`
    (``apply_expression_template_unknown_template`` /
    ``apply_expression_template_bindings_mismatch``), but WITHOUT expanding — the
    reference is preserved (§9.6.4 rule 1). ``reject_match_rule=False`` admits a
    reference a firing wrote, which names its (still ``match``-carrying) rule
    until esm-spec §9.6.4 rule 3 materializes it."""
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
    if reject_match_rule and _is_object(decl) and decl.get("match") is not None:
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
# Transitive op flags (the library-edge ``enum`` check, esm-spec §9.7.5)
# ---------------------------------------------------------------------------


def _contains_op(node: Any, pred) -> bool:
    """True iff ``node`` contains, ANYWHERE within it (descending through every
    field, including the ``bindings`` of nested ``apply_expression_template``
    nodes), an object whose ``op`` string satisfies ``pred``. Does NOT follow
    references to other templates — that transitive step is
    :func:`_template_bearing`."""
    found = [False]

    def _visit(obj: dict, _path: str) -> None:
        if found[0]:
            return
        op = obj.get("op")
        if isinstance(op, str) and pred(op):
            found[0] = True

    _walk_json(node, on_obj=_visit, dedup=True)
    return found[0]


def _template_bearing(named: dict, direct_pred) -> dict[str, bool]:
    """Compute, for every template in ``named``, whether it can produce a node
    whose op satisfies ``direct_pred`` — directly in its body
    (:func:`_contains_op`, including inside nested references' ``bindings``), OR
    transitively through a referenced template in the §9.7.3-checked acyclic DAG.
    The policy using this memoized DFS is the library-edge ``enum`` check
    (esm-spec §9.7.5, ``direct_pred = op == "enum"``). The DAG is
    acyclic (checked by :func:`_compose_template_bodies`), so the DFS
    terminates."""
    bearing: dict[str, bool] = {}
    inprogress: set[str] = set()

    def visit(name: str) -> bool:
        if name in bearing:
            return bearing[name]
        # Defensive against a cycle the checker somehow missed: treat an
        # in-progress node as non-contributing (acyclicity is enforced earlier).
        if name in inprogress:
            return False
        decl = named.get(name)
        if decl is None:
            bearing[name] = False
            return False
        inprogress.add(name)
        body = decl.get("body") if _is_object(decl) else None
        res = body is not None and _contains_op(body, direct_pred)
        if not res:
            for r in _collect_apply_names([], body):
                if r in named and visit(r):
                    res = True
                    break
        inprogress.discard(name)
        bearing[name] = res
        return res

    for name in named:
        visit(name)
    return bearing


#: The private key on which a load marks the root of each template expansion
#: with its template's name (``ExprNode.template_origin``). The schema refuses it
#: in an authored document.
TEMPLATE_ORIGIN_KEY = "__esm_template_origin"

_MARK_TEMPLATE_ORIGINS: contextvars.ContextVar[bool] = contextvars.ContextVar(
    "_MARK_TEMPLATE_ORIGINS", default=False
)


@contextlib.contextmanager
def marking_template_origins() -> Iterator[None]:
    """While active, :func:`expand_document` marks the root of each expansion
    it makes with its template's name (esm-spec §9.6.11: the elementwise lift
    applies only to an application, and this binding expands applications at
    load). Held by the typed load around its expansions; the public expansion,
    whose output is a document, never marks."""
    token = _MARK_TEMPLATE_ORIGINS.set(True)
    try:
        yield
    finally:
        _MARK_TEMPLATE_ORIGINS.reset(token)


def _expand(
    node: Any,
    templates: dict,
    scope: str,
    should_expand,
    memo: dict[int, tuple] | None = None,
) -> Any:
    """Shared substitution engine behind :func:`_expand_all` (esm-spec
    §9.6.4 rule 2). Recursively rewrites ``apply_expression_template`` nodes by pure
    substitution, innermost-first: the bindings are expanded before the body is
    instantiated, and the instantiated body is re-expanded. ``should_expand`` is
    consulted once per reference, on the node AFTER its bindings are expanded, to
    decide whether to expand it here — :func:`_expand_all` passes
    ``lambda n: True`` (the unconditional ``Expand`` kernel, §9.6.4 rule 2); a
    reference ``should_expand`` declines is returned intact. Deterministic and
    sharing-preserving via an identity memo.

    The list / non-apply-dict / scalar recursion and its id-memoized,
    identity-preserving DAG rebuild are the shared combinator's job
    (:func:`json_walk._rewrite_json`, ``share=True``); this pass supplies only
    the innermost-first apply handling via the whole-node ``on_object`` hook. The
    combinator manages the memo, so the legacy ``memo`` parameter is accepted for
    signature stability but no longer threaded (top-level callers always pass
    ``None``)."""

    mark = _MARK_TEMPLATE_ORIGINS.get() and should_expand is _expand_everything

    def _on_object(node: dict, recurse) -> Any:
        if node.get("op") == APPLY_OP:
            # Innermost-first: expand references inside the bindings first.
            b = node.get("bindings")
            newnode = node
            if _is_object(b):
                nb = {}
                changed = False
                for k, v in b.items():
                    rv = recurse(v)
                    if rv is not v:
                        changed = True
                    nb[k] = rv
                if changed:
                    newnode = {k: (nb if k == "bindings" else v) for k, v in node.items()}
            if should_expand(newnode):
                body = _expand_apply(newnode, templates, scope)
                expanded = recurse(body)
                if mark and isinstance(expanded, dict):
                    expanded = {**expanded, TEMPLATE_ORIGIN_KEY: newnode["name"]}
                return expanded
            return newnode
        changed = False
        out = {}
        for k, v in node.items():
            rv = recurse(v)
            if rv is not v:
                changed = True
            out[k] = rv
        return out if changed else node

    return _rewrite_json(node, on_object=_on_object, share=True)


def _expand_everything(_node: dict) -> bool:
    """The :func:`_expand_all` policy: every reference expands."""
    return True


def _expand_all(
    node: Any, templates: dict, scope: str, memo: dict[int, tuple] | None = None
) -> Any:
    """Fully expand EVERY ``apply_expression_template`` node in ``node`` by pure
    substitution to a fixpoint (innermost-first: bindings are expanded before
    the body is instantiated, and the instantiated body is re-expanded). This is
    the per-registry kernel of the public :func:`expand_document` /
    :func:`Expand` function (esm-spec §9.6.4 rule 2). Deterministic and
    sharing-preserving."""
    return _expand(node, templates, scope, _expand_everything, memo)


class _Lowering:
    """One component's rewrite state (esm-spec §9.6.3, §9.6.4 rule 3):
    ``named`` — every template declaration keyed by name (the registry
    references resolve against; rule 3 adds its variants here);
    ``match_rules`` — the auto-applied rules pre-sorted into §9.6.3 selection
    order; ``shape_env`` — the component's static shape environment
    (:func:`_component_shape_env`) for ``where`` constraints; ``enums`` — the
    document's ``enums`` block, for the per-instance ``enum`` lowering of rule
    3; ``scope`` — the component's diagnostic scope; ``depth`` — the rewrite
    depth of each reference a firing wrote (the pass that wrote it), keyed by
    node identity as ``id -> (node, depth)`` (a reference the author wrote has
    depth 0 and no entry). This is also everything needed to rewrite a coupling
    ``variable_map`` transform against the RECEIVING component (esm-spec
    §10.4)."""

    __slots__ = ("named", "match_rules", "shape_env", "enums", "scope", "depth")

    def __init__(
        self, named: dict, match_rules: list, shape_env: dict, enums: Any, scope: str
    ) -> None:
        self.named = named
        self.match_rules = match_rules
        self.shape_env = shape_env
        self.enums = enums
        self.scope = scope
        self.depth: dict[int, tuple[Any, int]] = {}

    def depth_of(self, node: Any) -> int | None:
        hit = self.depth.get(id(node))
        return None if hit is None else hit[1]

    def set_depth(self, node: Any, d: int) -> None:
        self.depth[id(node)] = (node, d)


def _rule_reference(rule: MatchRule, captured: dict) -> Any:
    """What a firing of ``rule`` writes in place of the matched node (esm-spec
    §9.6.3 constraint 7): a reference to the rule bound to what the match
    captured, a parameter the match never bound being bound to its own name. A
    rule whose body is a single leaf writes the leaf (for one of its
    parameters, what that parameter bound): there is no body to share."""
    body = rule.body
    if not (_is_object(body) or _is_array(body)):
        if isinstance(body, str) and body in rule.params:
            return captured.get(body, body)
        return body
    b = {p: captured.get(p, p) for p in rule.param_list}
    return {"op": APPLY_OP, "args": [], "name": rule.name, "bindings": b}


# Maximum rewrite depth (esm-spec §9.6.3/§9.6.4 rule 3, diagnostic
# ``rewrite_rule_nonterminating``): a rewrite made in pass ``p`` has depth
# ``p``, and one deeper than this rejects the file. Pinned identically across
# all bindings so the accept/reject decision is byte-identical everywhere.
MAX_REWRITE_PASSES = 64


def _rewrite_pass(
    node: Any,
    L: _Lowering,
    pass_no: int,
    last: list,
    bv: _BodyView | None = None,
    memo: dict[int, tuple] | None = None,
) -> tuple:
    """One pre-order (outermost-first) rewrite pass over ``node`` (esm-spec
    §9.6.3). At each object node the first rule in ``L.match_rules`` (highest
    ``priority`` first, ties by declaration order) whose ``match`` pattern
    matches the node AND whose ``where`` constraints hold fires; constraint
    filtering is part of match eligibility (§9.6.3 constraint 2). A firing
    writes a reference to the rule (:func:`_rule_reference`, constraint 7),
    recorded in ``L.depth`` at depth ``pass_no``, and the walk does not descend
    into it during this pass. At a reference — authored or written — no pattern
    matches (§9.6.4 rule 4), but the walk descends into the values of its
    ``bindings``, which are expressions of the call site. ``bv`` is the
    template-body view when ``node`` is a template body being rewritten for one
    instance (§9.6.4 rule 3), ``None`` at a component's expression positions.
    Returns ``(new_node, changed)``; ``last`` (a one-element list) records the
    name of the last rule that fired, for the non-convergence diagnostic.

    The pass is IDENTITY-PRESERVING (an unchanged subtree is returned as the
    same object) and MEMOIZED on node identity via ``memo`` (one dict per
    pass): a subtree shared under many parents is rewritten once. The memo
    stores ``(node, new_node, changed)`` tuples so ids are not recycled
    mid-pass.
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
            nc, ch = _rewrite_pass(c, L, pass_no, last, bv, memo)
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
    if node.get("op") == APPLY_OP:
        # esm-spec §9.6.4 rule 4: a reference is a leaf for matching; the walk
        # descends into the values of its ``bindings`` only.
        b = node.get("bindings")
        if not _is_object(b):
            memo[id(node)] = (node, node, False)
            return node, False
        nb = {}
        changed = False
        for k, v in b.items():
            nv, ch = _rewrite_pass(v, L, pass_no, last, bv, memo)
            nb[k] = nv
            changed = changed or ch
        if not changed:
            memo[id(node)] = (node, node, False)
            return node, False
        nn = {k: (nb if k == "bindings" else v) for k, v in node.items()}
        d = L.depth_of(node)
        if d is not None:
            L.set_depth(nn, d)  # the same reference, rebuilt
        memo[id(node)] = (node, nn, True)
        return nn, True
    for rule in L.match_rules:
        binds = _match(rule.pattern, node, rule.params, bv)
        if binds is not None and _where_satisfied(rule.where_c, binds, L.shape_env, bv):
            last[0] = rule.name
            r = _rule_reference(rule, binds)
            if _is_object(r) and r.get("op") == APPLY_OP:
                L.set_depth(r, pass_no)
            memo[id(node)] = (node, r, True)
            return r, True
    # No rule fired here — descend into children.
    changed = False
    out = {}
    for k, v in node.items():
        nv, ch = _rewrite_pass(v, L, pass_no, last, bv, memo)
        out[k] = nv
        changed = changed or ch
    if not changed:
        out = node  # identity-preserving
    memo[id(node)] = (node, out, changed)
    return out, changed


def _rewrite_to_fixpoint(
    node: Any, L: _Lowering, scope: str, bv: _BodyView | None = None
) -> tuple[Any, int]:
    """Drive :func:`_rewrite_pass` to a fixpoint (esm-spec §9.6.3): repeat
    pre-order passes until a pass performs zero rewrites. A rewrite made in
    pass ``p`` has depth ``p``; one whose depth would exceed
    ``MAX_REWRITE_PASSES`` rejects the file with ``rewrite_rule_nonterminating``
    (§9.6.4 rule 3, "Rewrite depth"), so 64 productive passes are accepted and
    a 65th is not. This bound — not a static check — is the authoritative
    termination guard. Returns ``(rewritten node, productive passes)``."""
    last = [""]
    current = node
    for pass_no in range(1, MAX_REWRITE_PASSES + 2):
        # Fresh identity memo per pass: rewriting is pure within one pass, but a
        # node's fate can change between passes.
        current, changed = _rewrite_pass(current, L, pass_no, last, bv, {})
        if not changed:
            return current, pass_no - 1  # fixpoint reached
    raise ExpressionTemplateError(
        REWRITE_RULE_NONTERMINATING,
        f"{scope}: expression-template rewriting did not converge within "
        f"MAX_REWRITE_PASSES={MAX_REWRITE_PASSES} passes (last rule fired "
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


def _component_registry(comp: dict, scope: str, iset_names: set) -> tuple[dict, list, dict]:
    """Build one component's rewrite registry from its ``expression_templates``
    block: the validated + body-CHECKED named-template dict, the pre-sorted
    ``match``-rule list (with registered ``where`` constraints resolved against
    ``iset_names``), and the static shape environment for ``where`` evaluation
    (esm-spec §9.6.1). A component without a block yields
    ``({}, [], shape_env)``.
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
        # preserved (§9.6.4).
        _compose_template_bodies(templates, scope)
        match_rules = _build_match_rules(templates, scope, iset_names)
    return templates, match_rules, shape_env


def _variable_map_transforms(out: dict) -> Iterator[tuple[int, dict, str]]:
    """Each ``variable_map`` coupling entry of ``out`` whose ``transform`` is an
    expression object, as ``(index, entry, receiving component name)``: the
    component named by the first dot-segment of the entry's ``to``."""
    coupling = out.get("coupling")
    if not _is_array(coupling):
        return
    for idx, entry in enumerate(coupling):
        if not _is_object(entry) or entry.get("type") != "variable_map":
            continue
        if not _is_object(entry.get("transform")):
            continue
        to_ref = entry.get("to")
        if not isinstance(to_ref, str) or not to_ref:
            continue
        yield idx, entry, to_ref.split(".", 1)[0]


#: The post-expansion validator skips ``expression_templates`` blocks: those
#: hold pre-substitution trees where a param may legally occupy a scalar field
#: (a makearray bound); enforcement is on the expanded form only.
_EXPR_TEMPLATES_SKIP = frozenset({"expression_templates"})


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

    # dedup: runs on the expanded (possibly shared-DAG) form; a defect node
    # shared under many parents raises once, at its first pre-order path —
    # identical to the unshared behavior.
    _walk_json(x, on_obj=_check, skip_keys=_EXPR_TEMPLATES_SKIP, path=path, dedup=True)


# ---------------------------------------------------------------------------
# Reference-aware validation discharge (esm-spec §9.6.9, Option B)
# ---------------------------------------------------------------------------


def _validate_makearray_regions_in_registries(registries: Any) -> None:
    """esm-spec §9.6.9: ``makearray_region_inverted`` is discharged at
    registration on the composed, metaparameter-folded template bodies — region
    bounds cannot carry template params (they are metaparameter expressions,
    §9.7.6), so the check is instantiation-independent. Every retained template
    body (match and match-less, and every variant rule 3 added) is validated
    directly; its region bounds are already concrete integers. ``registries``
    iterates the per-component named-template dicts."""
    for templates in registries:
        for tname, decl in templates.items():
            body = decl.get("body") if _is_object(decl) else None
            if body is not None:
                _validate_makearray_regions(body, f"expression_templates.{tname}/body")


def lower_expression_templates(file: dict) -> dict:
    """Run the load-time rewrite fixpoint (esm-spec §9.6.3) over `file`,
    Option B (reference-preserving, esm-spec §9.6.4).

    Per component, an outermost-first / priority-ordered / bounded-fixpoint
    rewrite (:func:`_rewrite_to_fixpoint`) fires the component's ``match``
    rewrite rules; each firing writes a reference to its rule (esm-spec §9.6.3
    constraint 7) and references survive (§9.6.4 rule 4). Coupling
    ``variable_map`` transforms are rewritten with the receiving component's
    rules. Then the rules apply inside the bodies of the templates the
    references reach, once per template instance (§9.6.4 rule 3,
    :func:`earthsci_ast.template_instances.apply_rule3`), which may rewrite a
    body in place, add ``<name>.variant<k>`` entries, and materialize the
    referenced rules without ``match``. The per-component
    ``expression_templates`` blocks are RETAINED — emit materializes them
    (§9.6.4 rule 5) and :func:`expand_document` consumes them. Returns a new
    dict (does not mutate input). A rewrite deeper than ``MAX_REWRITE_PASSES``
    (counted through template bodies) is ``rewrite_rule_nonterminating``; call
    sites are checked for unknown template / bindings mismatch (§9.6.9).

    Pre-condition: the input has been schema-validated.
    """
    from .template_instances import apply_rule3

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
    enums = out.get("enums")

    # Per-component rewrite state, kept so top-level coupling transforms can be
    # rewritten in the RECEIVING component's context, and so rule 3 runs after
    # every expression position (and transform) reached its fixpoint. Lookup
    # by component name: models first, then reaction systems.
    lowerings: list[tuple[dict, _Lowering, list]] = []
    by_name: dict[str, int] = {}
    for compkind in ("models", "reaction_systems"):
        comps = out.get(compkind)
        if not _is_object(comps):
            continue
        for cname, comp in comps.items():
            if not _is_object(comp):
                continue
            cscope = f"{compkind}.{cname}"
            # A subsystem carrying its own block (a mounted leaf's, or an
            # authored one) joins this component's registry here (esm-spec
            # §9.6.4 rule 1), bodies unchanged.
            _hoist_mounted_templates(comp, str(cname))
            templates, match_rules, shape_env = _component_registry(comp, cscope, iset_names)
            L = _Lowering(templates, match_rules, shape_env, enums, cscope)
            for k in list(comp.keys()):
                if k == "expression_templates":
                    continue
                comp[k], _ = _rewrite_to_fixpoint(comp[k], L, f"{cscope}.{k}")
            lowerings.append((comp, L, []))
            by_name.setdefault(cname, len(lowerings) - 1)

    # Coupling `variable_map` expression transforms (esm-spec §10.4/§10.5) are
    # rewritten against the rules of the component that owns the entry's `to`
    # target — the receiving component — exactly as a field of that component
    # would be.
    for idx, entry, comp_name in _variable_map_transforms(out):
        li = by_name.get(comp_name)
        if li is None:
            continue
        _comp, L, transforms = lowerings[li]
        entry["transform"], _ = _rewrite_to_fixpoint(
            entry["transform"], L, f"coupling[{idx}].transform"
        )
        transforms.append(entry)

    # esm-spec §9.6.4 rule 3: the rules apply inside the bodies of the templates
    # the references reach, once per template instance, without expanding any
    # reference. Rule 1 (Option B): the component's `expression_templates` block
    # is RETAINED — the registry emit materializes (rule 5) and Expand consumes
    # (rule 2).
    for comp, L, transforms in lowerings:
        apply_rule3(comp, L, transforms)
        # Call-site checks on surviving references (§9.6.9): unknown name /
        # bindings mismatch, against the registry as rule 3 left it.
        for k in list(comp.keys()):
            if k == "expression_templates":
                continue
            _check_surviving_refs(comp[k], L.named, f"{L.scope}.{k}")
        for entry in transforms:
            _check_surviving_refs(entry["transform"], L.named, f"{L.scope} coupling transform")

    # Validation discharge (esm-spec §9.6.9): makearray-region checks on the
    # reference-preserving form. Region bounds cannot carry template params, so
    # the check runs on the reference-preserving tree AND the retained folded
    # template bodies directly.
    _validate_makearray_regions(out)
    _validate_makearray_regions_in_registries(L.named for _c, L, _t in lowerings)
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
    DAG is acyclic and substitution confluent, so the result is structurally
    equal to the ``expanded*.esm`` conformance oracle (§9.6.7). Non-destructive: ``loaded`` is deep copied
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
    # A coupling transform is not a component expression: its expansions are
    # not marked (the Julia reference expands them at load the same way).
    unmark = _MARK_TEMPLATE_ORIGINS.set(False)
    try:
        _expand_coupling_transforms(coupling, comp_named)
    finally:
        _MARK_TEMPLATE_ORIGINS.reset(unmark)

    return root


def _expand_coupling_transforms(coupling: Any, comp_named: dict) -> None:
    """Expand every ``variable_map`` transform reference of ``coupling`` against
    the receiving component's registry, in place."""
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
    """Per-component template names authored in-file in ``raw_source``
    (``compkind.cname`` → ordered names). Emit keeps these in authored position
    (esm-spec §9.6.4 rule 5): a match-less entry always, a ``match`` rule only
    when a firing referenced it (it is then materialized without ``match``,
    ``where`` and ``priority``); imported/derived templates are materialized
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
                names.append(str(n))
            authored[f"{compkind}.{cname}"] = names
    return authored


def received_transform_refs(root: Any) -> dict[str, list[str]]:
    """The template names referenced by the ``variable_map`` transforms each
    component RECEIVES, keyed by component name (the first segment of ``to``;
    the first component of that name, models before reaction systems, as the
    lowering pairs them). The transforms keep their references (esm-spec
    §10.4); the receiving component owns them, so its emitted block
    materializes their closure (§9.6.4 rule 5)."""
    out: dict[str, list[str]] = {}
    if not _is_object(root):
        return out
    for _idx, entry, comp_name in _variable_map_transforms(root):
        _collect_apply_names(out.setdefault(comp_name, []), entry["transform"])
    return out


def materialize_component_block(
    comp: dict, authored_here: list[str], received: list[str] | None = None
) -> tuple[dict[str, Any], bool, bool]:
    """One Option-B loaded component's emitted ``expression_templates`` block
    (esm-spec §9.6.4 rule 5): the entries authored in-file (``authored_here``,
    authored order) first — a ``match`` rule only once a firing referenced it
    and rule 3 materialized it without ``match`` — then the transitive closure
    of the component's surviving references not authored here, sorted by UTF-8
    bytes. Also reports whether the component carries any surviving reference
    and whether any non-authored entry was materialized (the §9.6.4 rule 8
    version stamp). Shared by :func:`emit_document` and the typed load path's
    registry (the one flatten merges), as the Julia ``_materialize_components!``
    is. ``received`` names the references of the coupling transforms the
    component receives (:func:`received_transform_refs`), which count as its
    own. ``comp`` is not modified."""
    tpl = comp.get("expression_templates")
    named: dict[str, Any] = {}
    if _is_object(tpl):
        for n, d in tpl.items():
            named[str(n)] = d
    refnames: set[str] = set(received or ())
    for k, v in comp.items():
        if k in ("expression_templates", "expression_template_imports"):
            continue
        for r in _collect_apply_names([], v):
            refnames.add(r)
    materialized = _ref_closure(refnames, named)
    authored_set = set(authored_here)
    block: dict[str, Any] = {}
    for n in authored_here:
        # A `match` rule nothing references still carries its `match` (a
        # referenced one was materialized without it, §9.6.4 rule 3).
        if n in named and not (_is_object(named[n]) and named[n].get("match") is not None):
            block[n] = named[n]
    mat_names = sorted(materialized - authored_set)
    for n in mat_names:
        block[n] = named[n]
    return block, bool(refnames), bool(mat_names)


def emit_document(raw_source: Any, base_path: str) -> dict:
    """Produce the reference-preserving, self-contained emitted document
    (esm-spec §9.6.4 rule 5, RFC out-of-line-expression-templates §7.5) from a
    source document (a fixture, or an already-emitted document for the
    idempotency property). Loads ``raw_source`` under Option B, then for every
    component builds its emitted ``expression_templates`` block — authored
    entries first in authored order (a ``match`` rule only once a firing
    referenced it and rule 3 materialized it match-less), then the materialized
    transitive closure of its surviving references (match-less), sorted —
    drops consumed ``expression_template_imports``, and version-stamps
    ``esm: 0.9.0`` when any surviving reference or materialized entry remains
    (§9.6.4 rule 8). ``emit_esm_string ∘ emit_document`` is a byte-wise fixed
    point under reload.

    ``raw_source`` passes the same wire boundary a load applies
    (:func:`earthsci_ast.parse.prepare_document_ops`), on a copy: a removed op
    is refused, and a deprecated ``neg`` / ``pow`` is rewritten with the
    ``deprecated_op`` warning, so neither spelling survives into the emitted
    document (esm-spec §4.2)."""
    from .parse import prepare_document_ops
    from .template_imports import resolve_template_machinery

    raw_source = copy.deepcopy(raw_source)
    prepare_document_ops(raw_source)
    authored = _authored_template_names(raw_source)
    resolved = resolve_template_machinery(raw_source, base_path)
    loaded = lower_expression_templates(raw_source if resolved is None else resolved)
    root = loaded
    bump = False
    received = received_transform_refs(root)

    for compkind in ("models", "reaction_systems"):
        comps = root.get(compkind)
        if not _is_object(comps):
            continue
        for cname, comp in comps.items():
            if not _is_object(comp):
                continue
            emit_block, has_refs, has_materialized = materialize_component_block(
                comp, authored.get(f"{compkind}.{cname}", []), received.pop(cname, None)
            )
            if has_refs or has_materialized:
                bump = True

            if emit_block:
                comp["expression_templates"] = emit_block
            else:
                comp.pop("expression_templates", None)
            comp.pop("expression_template_imports", None)

    root.pop("expression_template_imports", None)
    if bump:
        # The §9.6.4 rule-8 emit stamp is a FLOOR, not an assignment: an emitted
        # document carrying a surviving reference or a materialized entry "MUST
        # declare `esm: 0.9.0` OR LATER". A document already at or above the
        # floor keeps its own declared version.
        #
        # This read `_CURRENT_VERSION` unconditionally, which is a different
        # rule that happened to agree while the current version WAS 1.0.0 — the
        # floor and the assignment give the same answer for a 1.0.0 document
        # only until the schema moves on. At esm 1.1.0 they diverged and this
        # binding started stamping 1.0.0 documents up to 1.1.0 on re-emit,
        # against TypeScript, which had the floor right. Raising the stamp is
        # not harmless: it claims the document uses a format version it does
        # not, and needlessly puts it out of reach of a 1.0.x reader.
        #
        # In practice the floor never fires: esm 1.0.0 is a clean break that
        # rejects every 0.x document at load, so anything reaching emit already
        # declares >= 1.0.0. It is written out anyway so the rule is stated
        # where it is applied rather than resting on that coincidence.
        _RULE8_FLOOR = (0, 9, 0)
        declared = _parse_semver_tuple(root.get("esm"))
        if declared is None or declared < _RULE8_FLOOR:
            root["esm"] = ".".join(str(v) for v in _RULE8_FLOOR)
    return root


def _parse_semver_tuple(v: object) -> tuple[int, int, int] | None:
    """``"1.2.3"`` -> ``(1, 2, 3)``; ``None`` for anything unparseable.

    Compares numerically, so 1.10.0 orders above 1.2.0 where a lexicographic
    compare gets it backwards.
    """
    if not isinstance(v, str):
        return None
    parts = v.split(".")
    if len(parts) != 3:
        return None
    try:
        return (int(parts[0]), int(parts[1]), int(parts[2]))
    except ValueError:
        return None


# --- Canonical byte writer (2-space indent, keys sorted except the ordered
#     `expression_templates` block) — the cross-binding byte-identity surface.
#     The writer now lives next to :func:`serialize.save` (co-located JSON
#     writers); it is re-exported here (see the module head) so the historical
#     ``lower_expression_templates.emit_esm_string`` import path keeps resolving.


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
    registry rename. Sharing-preserving via the shared combinator
    (:func:`json_walk._rewrite_json`, ``share=True``): only the apply ``name``
    slot is mapped, every other value recursed unchanged."""

    def _item(n: dict, key: str, value: Any, recurse) -> Any:
        if key == "name" and n.get("op") == APPLY_OP and isinstance(value, str) and value in rename:
            return rename[value]
        return recurse(value)

    return _rewrite_json(node, on_value=_item, share=True)


def _registry_collision_names(byname: dict[str, list[tuple[str, Any]]]) -> set[str]:
    """The set of template names the flatten-time registry merge MUST owner-path
    rename (esm-spec §9.6.4 rule 7 / §10.7). ``byname`` maps a template name to
    its per-component occurrences ``[(path, decl), …]``.

    A name collides directly when its occurrences are not all deep-equal. The set
    is then closed under the reference DAG: **if a declaration references a
    colliding name, that declaration collides too**, in every component carrying
    it. That propagation is what makes the rename total.

    Without it the common multi-model shape silently breaks. Two components
    import one rule library; the leaf stencil folds differently per component (a
    rebind, a metaparameter, or the §10.7 component-scoping of its free
    variables) and renames to ``A.leaf`` / ``B.leaf``, while the intermediate
    wrapper that REFERENCES the leaf is byte-identical and would dedup under its
    bare name. That single deduped body then carries a reference the registry no
    longer holds, and expansion fails with
    ``apply_expression_template_unknown_template`` naming a template no component
    ever mentioned. Renaming the wrapper per owner lets each copy's nested
    reference be rewritten to its own owner's leaf.

    A consequence worth relying on: a name left OUT of the returned set never
    references a name inside it, so deduped entries need no reference rewriting.
    """
    collide: set[str] = set()
    refs: dict[str, set[str]] = {}
    for name, occ in byname.items():
        if not all(_json_equal(occ[0][1], o[1]) for o in occ):
            collide.add(name)
        seen: set[str] = set()
        for _path, decl in occ:
            seen.update(_collect_apply_names([], decl))
        refs[name] = seen
    # Close under the reference edges (monotone; ≤ len(byname) rounds).
    changed = True
    while changed:
        changed = False
        for name in byname:
            if name in collide:
                continue
            if refs[name] & collide:
                collide.add(name)
                changed = True
    return collide


def _merge_flat_registry(
    blocks: list[tuple[str, Any]],
) -> tuple[dict[str, Any], dict[str, dict[str, str]]]:
    """Merge per-owner template blocks into one registry (esm-spec §9.6.4 rule 7,
    §10.7; esm-libraries-spec §4.7.5 step 4), the rule every registry merge
    shares: flatten's merged registry, :func:`flatten_template_registries`, and
    the hoist of subsystem blocks into their top-level component
    (:func:`_hoist_mounted_templates`).

    ``blocks`` is the ordered list of ``(owner path, block)``; the byname table
    is built in that (document) order, entries in block order. Deep-equal
    same-name entries dedupe at first occurrence. For a colliding name (see
    :func:`_registry_collision_names`) the owners whose entries are deep-equal
    once their nested references are renamed to that owner's entries share ONE
    entry, named ``<first such owner's path>.<name>``; colliding names are
    settled callees first. So a definition two owners carry identically (a leaf
    mounted twice) stays one definition.

    Returns the merged registry and the per-owner rename map
    (``path -> {old name: new name}``), which the caller applies to each owner's
    reference sites. Mirrors the Julia ``_merge_flat_registry``."""
    byname: dict[str, list[tuple[str, Any]]] = {}
    for path, block in blocks:
        if not _is_object(block):
            continue
        for name, decl in block.items():
            byname.setdefault(str(name), []).append((path, decl))
    collide = _registry_collision_names(byname)
    rename: dict[str, dict[str, str]] = {}
    groups: dict[str, list[tuple[str, Any]]] = {}

    def settle(name: str) -> list[tuple[str, Any]]:
        if name in groups:
            return groups[name]
        gs: list[tuple[str, Any]] = []
        for path, decl in byname[name]:
            rn: dict[str, str] = {}
            for c in _collect_apply_names([], decl):
                if c not in collide or c == name:
                    continue
                settle(c)
                new = rename.get(path, {}).get(c)
                if new is not None:
                    rn[c] = new
            d = _rename_apply_refs(decl, rn) if rn else decl
            idx = next((i for i, g in enumerate(gs) if _json_equal(g[1], d)), None)
            if idx is None:
                gs.append((f"{path}.{name}", d))
                idx = len(gs) - 1
            rename.setdefault(path, {})[name] = gs[idx][0]
        groups[name] = gs
        return gs

    for name in byname:
        if name in collide:
            settle(name)
    merged: dict[str, Any] = {}
    for name, occ in byname.items():
        if name in collide:
            for newname, decl in groups[name]:
                merged[newname] = decl
        else:
            merged[name] = occ[0][1]
    return merged, rename


def _matchless(block: Any) -> dict[str, Any]:
    """The match-less entries of a raw ``expression_templates`` block, in
    block order (only match-less templates are referenceable, §9.6.2)."""
    if not _is_object(block):
        return {}
    return {
        str(n): d for n, d in block.items() if not (_is_object(d) and d.get("match") is not None)
    }


# ===========================================================================
# Subsystem blocks join their top-level component (esm-spec §9.6.4 rule 1)
# ===========================================================================


def _collect_mounted_blocks(out: list[tuple[str, dict]], node: Any, prefix: str) -> None:
    """The subsystems below ``node`` that carry an ``expression_templates``
    block (a mounted leaf's, or an authored subsystem's own), with their paths
    below the top-level component. A subsystem with a block owns its subtree's
    definitions (they were merged into it when it was lowered), so the walk
    stops there."""
    subs = node.get("subsystems") if _is_object(node) else None
    if not _is_object(subs):
        return
    for k, sub in subs.items():
        if not _is_object(sub):
            continue
        path = str(k) if not prefix else f"{prefix}.{k}"
        if _is_object(sub.get("expression_templates")):
            out.append((path, sub))
        else:
            _collect_mounted_blocks(out, sub, path)


def _rename_outside_mounts(node: dict, rn: dict[str, str]) -> None:
    """``node``'s subsystems, outside every subsystem that carries its own block,
    with their references renamed by ``rn`` (the top-level component's own
    renames), in place."""
    subs = node.get("subsystems")
    if not _is_object(subs):
        return
    for _k, sub in subs.items():
        if not _is_object(sub) or _is_object(sub.get("expression_templates")):
            continue
        for k in list(sub.keys()):
            if k == "subsystems":
                continue
            sub[k] = _rename_apply_refs(sub[k], rn)
        _rename_outside_mounts(sub, rn)


def _merge_mounted_blocks(
    own: Any, cname: str, mounts: list[tuple[str, dict]]
) -> tuple[dict[str, Any], dict[str, str] | None]:
    """The merge :func:`_hoist_mounted_templates` describes: the component
    ``cname``'s own block ``own`` (match-less entries, owner path ``cname``)
    and each subsystem block of ``mounts`` (``(path, subsystem)``, match-less
    entries, owner path ``path``) merged by :func:`_merge_flat_registry`, bodies
    unchanged. Each subsystem's own references (its whole subtree) are renamed
    here, in place, by its owner's renames. Returns the new block (``own``'s
    ``match`` rules first, renamed by ``cname``'s renames, then the merged
    entries) and ``cname``'s renames (or ``None``). Mirrors the Julia
    ``_merge_mounted_blocks``."""
    blocks: list[tuple[str, Any]] = [(cname, _matchless(own))]
    for path, sub in mounts:
        blocks.append((path, _matchless(sub.get("expression_templates"))))
    merged, rename = _merge_flat_registry(blocks)
    for path, sub in mounts:
        rm = rename.get(path)
        if not rm:
            continue
        for k in list(sub.keys()):
            if k == "expression_templates":
                continue
            sub[k] = _rename_apply_refs(sub[k], rm)
    rn = rename.get(cname)
    newblock: dict[str, Any] = {}
    if _is_object(own):
        for n, d in own.items():
            if not (_is_object(d) and d.get("match") is not None):
                continue
            newblock[str(n)] = _rename_apply_refs(d, rn) if rn else d
    newblock.update(merged)
    return newblock, rn


def _hoist_mounted_templates(comp: dict, cname: str) -> dict:
    """Merge into the top-level component ``comp``'s ``expression_templates``
    block the definitions its subsystems carry on their own blocks (esm-spec
    §9.6.4 rule 1): a model mounted as a subsystem (esm-spec §4.7) keeps its
    references and its match-less definitions, and an authored subsystem may
    declare its own block. Each joins ``comp``'s by the registry merge
    (:func:`_merge_flat_registry`), owner path ``cname`` for ``comp``'s own
    entries and the subsystem path below ``comp`` (``Sub``, ``Sub.Inner``) for
    each subsystem block.

    Bodies are taken unchanged, in the subsystem's own names: a body's free
    names are read in the scope of the subsystem that owns the reference, so
    expanding a subsystem's reference is plain substitution, and a leaf mounted
    twice brings one definition. Each subsystem subtree's references follow its
    own owner's renames; ``comp``'s other sites follow ``comp``'s. The subsystem
    blocks are removed. In place; returns ``comp``. Mirrors the Julia
    ``_hoist_mounted_templates!``."""
    mounts: list[tuple[str, dict]] = []
    _collect_mounted_blocks(mounts, comp, "")
    if not mounts:
        return comp
    newblock, rn = _merge_mounted_blocks(comp.get("expression_templates"), cname, mounts)
    if rn:
        for k in list(comp.keys()):
            if k in ("expression_templates", "subsystems"):
                continue
            comp[k] = _rename_apply_refs(comp[k], rn)
        _rename_outside_mounts(comp, rn)
    for _path, sub in mounts:
        sub.pop("expression_templates", None)
    comp["expression_templates"] = newblock
    return comp


def mounted_registries(doc: Any) -> Any:
    """The lowered mounted leaf ``doc`` with each top-level component's
    ``expression_templates`` block kept for the mounting document (esm-spec
    §9.6.4 rule 1): its match-less entries only (the ``match`` rules have fired
    in the leaf), and none on a component no reference reads. In place; returns
    ``doc``. Mirrors the Julia ``_mounted_registries!``."""
    if not _is_object(doc):
        return doc
    for compkind in ("models", "reaction_systems"):
        comps = doc.get(compkind)
        if not _is_object(comps):
            continue
        for _cname, comp in comps.items():
            if not _is_object(comp):
                continue
            blk = comp.get("expression_templates")
            if not _is_object(blk):
                continue
            keep = _matchless(blk)
            used = any(
                bool(_find_apply_paths(v)) for k, v in comp.items() if k != "expression_templates"
            )
            if not keep or not used:
                comp.pop("expression_templates", None)
            else:
                comp["expression_templates"] = keep
    return doc


# ===========================================================================
# Closing template bodies (esm-spec §10.7; esm-libraries-spec §4.7.5 step 2)
# ===========================================================================


def _tpl_binders(node: dict) -> set[str]:
    """The loop symbols a raw expression node binds for all of its children:
    its ``output_idx`` names, its ``ranges`` keys and an integral's ``var``."""
    out: set[str] = set()
    for x in node.get("output_idx") or ():
        if isinstance(x, str):
            out.add(x)
    ranges = node.get("ranges")
    if _is_object(ranges):
        out.update(str(k) for k in ranges.keys())
    if node.get("op") == "integral" and isinstance(node.get("var"), str):
        out.add(node["var"])
    return out


def _tpl_children(node: dict) -> Iterator[Any]:
    """A raw expression node's expression children: ``args``, ``lower`` /
    ``upper`` / ``expr`` / ``filter`` / ``key``, ``values``, the ``bindings``
    values of a reference, and the bounds of dense ``ranges`` (the Julia
    ``foreach_child`` set; ``makearray`` ``regions`` and scalar fields such as
    ``wrt`` are not reads)."""
    from .json_walk import iter_child_values

    for field_name, child in iter_child_values(node):
        if field_name != "regions":
            yield child
    ranges = node.get("ranges")
    if _is_object(ranges):
        for bounds in ranges.values():
            if _is_array(bounds):
                for b in bounds:
                    if isinstance(b, (str, dict)):
                        yield b


def _tpl_free_leaves(e: Any) -> set[str]:
    """The variable leaves of the raw expression ``e`` not bound by an enclosing
    loop binder (:func:`_tpl_binders`); binding values of nested references are
    read. Mirrors the Julia ``_tpl_free_leaves``."""
    out: set[str] = set()

    def rec(x: Any, bound: frozenset[str]) -> None:
        if isinstance(x, str):
            if x not in bound:
                out.add(x)
            return
        if not _is_object(x):
            return
        b = _tpl_binders(x)
        inner = bound | b if b else bound
        for c in _tpl_children(x):
            rec(c, inner)

    rec(e, frozenset())
    return out


def _tpl_bind_explicit(e: Any, added: dict[str, list[str]]) -> Any:
    """``e`` with every reference to a template of ``added`` binding each added
    parameter to the same name (``n: "n"``); a binding the reference already has
    is kept. Identity-preserving: ``e`` itself when nothing changes. Mirrors the
    Julia ``_tpl_bind_explicit``."""
    if not added:
        return e

    def on_object(n: dict, rec) -> Any:
        out: dict = {k: rec(v) for k, v in n.items()}
        if all(out[k] is v for k, v in n.items()):
            out = n
        name = n.get("name")
        if n.get("op") == APPLY_OP and isinstance(name, str) and name in added:
            b = out.get("bindings")
            b = dict(b) if _is_object(b) else {}
            changed = False
            for p in added[name]:
                if p not in b:
                    b[p] = p
                    changed = True
            if changed:
                out = dict(out)
                out["bindings"] = b
        return out

    return _rewrite_json(e, on_object=on_object, share=True)


def tpl_explicit_free(block: Any) -> tuple[Any, dict[str, list[str]]]:
    """``block`` (a component's raw template registry) with every match-less
    body CLOSED (esm-spec §10.7; esm-libraries-spec §4.7.5 step 2): a name the
    body reads from its caller (a variable leaf it does not bind and that is not
    one of its ``params``, read directly or through a nested reference) is
    appended, sorted by UTF-8 bytes, to its ``params``, and every nested
    reference in a body binds its callee's added parameters to the same names
    (:func:`_tpl_bind_explicit`). Entries are visited in block order, callees
    (names of the same block a body references) first. Returns the closed block
    and ``added`` (template name -> the parameters it gained), for the
    reference sites. Mirrors the Julia ``_tpl_explicit_free``."""
    added: dict[str, list[str]] = {}
    if not _is_object(block):
        return block, added
    newdecl: dict[str, Any] = {}
    visiting: set[str] = set()

    def visit(name: str) -> None:
        if name in newdecl or name in visiting:
            return
        visiting.add(name)
        decl = block[name]
        body = decl.get("body") if _is_object(decl) else None
        if body is None or decl.get("match") is not None:
            newdecl[name] = decl
            return
        for c in _collect_apply_names([], body):
            if c in block:
                visit(c)
        bound = _tpl_bind_explicit(body, added)
        raw_params = decl.get("params")
        params = [p for p in raw_params if isinstance(p, str)] if _is_array(raw_params) else []
        free = sorted(
            _tpl_free_leaves(bound) - set(params), key=lambda s: s.encode("utf-8")
        )
        if bound is body and not free:
            newdecl[name] = decl
            return
        nd = dict(decl)
        if bound is not body:
            nd["body"] = bound
        if free:
            nd["params"] = [*(raw_params if _is_array(raw_params) else []), *free]
            added[name] = free
        newdecl[name] = nd

    for k in block:
        visit(str(k))
    return {str(k): newdecl[str(k)] for k in block}, added


def flatten_template_registries(loaded: Any) -> tuple[dict, dict]:
    """The flatten-time template-registry merge (esm-spec §9.6.4 rule 7, §10.7;
    esm-libraries-spec §4.7.5 step 4). Given an Option-B loaded multi-component
    document ``loaded``, merge every component's match-less
    ``expression_templates`` entries by :func:`_merge_flat_registry` into a
    single document-scoped merged registry:

    - **Deep-equal dedup at first occurrence** — two components importing one
      stencil produce identical folded bodies, kept once under the bare name.
    - **Non-deep-equal same-name collision** — the entries are renamed to
      ``<ComponentPath>.<name>``, one entry per distinct definition, named after
      its first owner, with every owner's ``apply_expression_template``
      references rewritten in lockstep (total, deterministic; no new
      diagnostic).
    - **Collisions propagate along the reference DAG** — a declaration that
      references a colliding name collides too (see
      :func:`_registry_collision_names`), so a byte-identical wrapper over a
      per-component leaf is renamed per owner rather than deduped into one body
      whose nested reference no longer resolves.

    The merged registry is in document order: components as the file declares
    them (models, then reaction systems), entries as their block declares them.
    Returns the rewritten document ``root`` (component reference sites updated,
    blocks removed) and the merged registry as a dict (the FlattenedSystem's
    first-class registry field). ``match`` rules are not merged (only
    match-less templates are referenceable, §9.6.2)."""
    root = copy.deepcopy(loaded)
    comps: list[tuple[str, dict]] = []  # (path, comp)
    blocks: list[tuple[str, Any]] = []
    for compkind in ("models", "reaction_systems"):
        cs = root.get(compkind)
        if not _is_object(cs):
            continue
        for cname, comp in cs.items():
            if not _is_object(comp):
                continue
            comps.append((str(cname), comp))
            tpl = comp.get("expression_templates")
            if _is_object(tpl):
                blocks.append((str(cname), _matchless(tpl)))
    merged, rename = _merge_flat_registry(blocks)

    # Rewrite each component's reference sites in lockstep with its renames,
    # and drop its now-merged block from the flattened form.
    for path, comp in comps:
        rn = rename.get(path)
        if rn:
            for k in list(comp.keys()):
                if k == "expression_templates":
                    continue
                comp[k] = _rename_apply_refs(comp[k], rn)
        comp.pop("expression_templates", None)
    return root, merged
