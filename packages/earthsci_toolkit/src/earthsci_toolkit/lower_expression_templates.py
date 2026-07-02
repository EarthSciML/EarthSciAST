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


class ExpressionTemplateError(Exception):
    """Raised when expression-template expansion fails.

    The ``code`` attribute carries one of the stable diagnostic codes:
    ``apply_expression_template_unknown_template``,
    ``apply_expression_template_bindings_mismatch``,
    ``apply_expression_template_recursive_body``,
    ``apply_expression_template_invalid_declaration``,
    ``apply_expression_template_version_too_old``,
    ``rewrite_rule_nonterminating``.
    """

    def __init__(self, code: str, message: str) -> None:
        super().__init__(f"[{code}] {message}")
        self.code = code


def _is_object(v: Any) -> bool:
    return isinstance(v, dict)


def _is_array(v: Any) -> bool:
    return isinstance(v, list)


def _assert_no_nested_apply(body: Any, template_name: str, path: str) -> None:
    if _is_array(body):
        for i, child in enumerate(body):
            _assert_no_nested_apply(child, template_name, f"{path}/{i}")
        return
    if _is_object(body):
        if body.get("op") == APPLY_OP:
            raise ExpressionTemplateError(
                "apply_expression_template_recursive_body",
                f"expression_templates.{template_name}: body contains nested "
                f"'apply_expression_template' at {path}; templates MUST NOT call "
                "other templates",
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
        params = decl.get("params")
        if not isinstance(params, list) or len(params) == 0:
            raise ExpressionTemplateError(
                "apply_expression_template_invalid_declaration",
                f"{scope}.expression_templates.{name}: 'params' must be a "
                "non-empty array of strings",
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
        _assert_no_nested_apply(decl["body"], name, "/body")
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
    __slots__ = ("name", "pattern", "params", "body", "priority", "decl_index")

    def __init__(self, name: str, pattern: Any, params: set, body: Any,
                 priority: int, decl_index: int) -> None:
        self.name = name
        self.pattern = pattern
        self.params = params
        self.body = body
        self.priority = priority
        self.decl_index = decl_index


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


def _build_match_rules(templates: dict, scope: str) -> list:
    """Collect the ``match``-carrying templates as auto-applied rewrite rules,
    pre-sorted for deterministic selection (esm-spec §9.6.3): highest
    ``priority`` first, ties broken by DECLARATION order (earliest wins). The
    ``_rewrite_pass`` walk then fires the FIRST rule in this order that matches a
    node. Nontermination is NOT checked here any more — the bounded fixpoint
    (``MAX_REWRITE_PASSES``) is the sole termination guard."""
    rules: list = []
    for decl_index, (name, decl) in enumerate(templates.items()):
        if "match" not in decl:
            continue
        rules.append(MatchRule(
            name, decl["match"], set(decl["params"]), decl["body"],
            _rule_priority(decl), decl_index,
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
                  last: list) -> tuple:
    """One pre-order (outermost-first) rewrite pass over ``node`` (esm-spec
    §9.6.3). At each object node the engine first tries to fire a rule AT the
    node before descending:

    1. an ``apply_expression_template`` op is expanded (:func:`_expand_apply`), OR
    2. the first rule in ``sorted_rules`` (pre-sorted highest-``priority``-first,
       ties by declaration order) whose ``match`` pattern structurally matches
       the node fires.

    A fired rule's body replaces the node and the walk does NOT descend into that
    freshly-produced body during this pass (it is revisited next pass). If nothing
    fires, the walk descends into the node's children. Returns
    ``(new_node, changed)`` where ``changed`` is True iff any rewrite occurred in
    this subtree; ``last`` (a one-element list) records the op of the most recent
    rewrite for the non-convergence diagnostic.
    """
    if _is_array(node):
        changed = False
        out = []
        for c in node:
            nc, ch = _rewrite_pass(c, templates, sorted_rules, scope, last)
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
        if binds is not None:
            op = node.get("op")
            last[0] = op if isinstance(op, str) else ""
            return _substitute(rule.body, binds), True
    # (2) No rule fired here — descend into children.
    changed = False
    out = {}
    for k, v in node.items():
        nv, ch = _rewrite_pass(v, templates, sorted_rules, scope, last)
        out[k] = nv
        changed = changed or ch
    return out, changed


def _rewrite_to_fixpoint(node: Any, templates: dict, sorted_rules: list,
                         scope: str) -> Any:
    """Drive :func:`_rewrite_pass` to a fixpoint (esm-spec §9.6.3): repeat
    pre-order passes until a pass performs zero rewrites, or reject the file with
    ``rewrite_rule_nonterminating`` once ``MAX_REWRITE_PASSES`` productive passes
    have run without converging. This bound — not a static check — is the
    authoritative termination guard, so a self-reintroducing rule fails to
    converge rather than being flagged up front."""
    last = [""]
    current = node
    for _pass in range(MAX_REWRITE_PASSES):
        current, changed = _rewrite_pass(current, templates, sorted_rules, scope, last)
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


def _has_match_rules(file: dict) -> bool:
    """True if any component declares an ``expression_templates`` entry carrying
    a ``match`` (i.e. an auto-applied rewrite rule that fires without an explicit
    ``apply_expression_template`` invocation)."""
    for compkind in ("models", "reaction_systems"):
        comps = file.get(compkind)
        if not _is_object(comps):
            continue
        for comp in comps.values():
            tplraw = _is_object(comp) and comp.get("expression_templates")
            if _is_object(tplraw) and any(
                _is_object(d) and "match" in d for d in tplraw.values()
            ):
                return True
    return False


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
    # somewhere, or a component declaring a ``match`` rewrite rule.
    if not _find_apply_paths(out) and not _has_match_rules(out):
        return _strip_expression_templates(out)

    for compkind in ("models", "reaction_systems"):
        comps = out.get(compkind)
        if not _is_object(comps):
            continue
        for cname, comp in comps.items():
            if not _is_object(comp):
                continue
            tplraw = comp.get("expression_templates")
            templates: dict[str, Any] = {}
            match_rules: list = []
            if _is_object(tplraw):
                for tname, tdecl in tplraw.items():
                    templates[tname] = tdecl
                _validate_templates(templates, f"{compkind}.{cname}")
                match_rules = _build_match_rules(templates, f"{compkind}.{cname}")
            for k in list(comp.keys()):
                if k == "expression_templates":
                    continue
                comp[k] = _rewrite_to_fixpoint(
                    comp[k], templates, match_rules, f"{compkind}.{cname}.{k}"
                )
            comp.pop("expression_templates", None)

    leftover = _find_apply_paths(out)
    if leftover:
        raise ExpressionTemplateError(
            "apply_expression_template_unknown_template",
            f"apply_expression_template ops remain after expansion at: "
            f"{', '.join(leftover)} — likely referenced from a component lacking "
            "an expression_templates block",
        )
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
