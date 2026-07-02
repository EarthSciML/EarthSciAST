"""Load-time resolution for esm-spec §9.7: template-library files, cross-file
``expression_template_imports``, and load-time ``metaparameters``
(docs/content/rfcs/template-library-imports.md; esm-libraries-spec §2.1c).

Everything here resolves BEFORE the §9.6.3 rewrite fixpoint
(:mod:`earthsci_toolkit.lower_expression_templates`) and before any validator
sees the tree. Per document the order is innermost-first (esm-spec §9.7.6):

1. resolve imports (recursively, depth-first post-order, instantiating the
   imported subtree with the edge's metaparameter ``bindings`` at each edge);
2. merge imported ``index_sets`` into the document registry;
3. close and fold this document's metaparameters (loader-API bindings, then
   defaults; ``metaparameter_unbound`` if still open);
4. §9.7.3 registration-time body composition (:func:`_compose_template_bodies`,
   invoked per component from ``lower_expression_templates``);
5. the §9.6.3 fixpoint on fully-concrete trees.

Round-trip is Option A: ``expression_template_imports``, ``metaparameters``,
and top-level ``expression_templates`` do not survive ``parse → emit``; the
emitted form is the expanded, folded document.

All diagnostics are raised as :class:`ExpressionTemplateError` with the stable
§9.6.6 codes so they are machine-checkable across bindings. Mirrors the Julia
reference implementation ``EarthSciSerialization.jl/src/template_imports.jl``.
"""
from __future__ import annotations

import copy
import json
import os
import re
from typing import Any, Dict, List, Optional

from .lower_expression_templates import (
    APPLY_OP,
    ExpressionTemplateError,
    _is_array,
    _is_object,
    _validate_templates,
)

__all__ = [
    "MAX_TEMPLATE_EXPANSION_DEPTH",
    "reject_template_imports_pre_v08",
    "resolve_template_machinery",
]

#: Maximum template-body reference-chain depth (counted in TEMPLATES along the
#: longest chain, so a 33-template chain is rejected and a 32-template chain is
#: accepted) before a file is rejected with ``template_body_expansion_too_deep``
#: (esm-spec §9.7.3). Pinned identically across all bindings.
MAX_TEMPLATE_EXPANSION_DEPTH = 32

_COMPONENT_KINDS = ("models", "reaction_systems")

#: A template-library file MUST NOT declare any of these (esm-spec §9.7.1).
_LIBRARY_FORBIDDEN_KEYS = (
    "models", "reaction_systems", "data_loaders", "coupling", "domain",
)

_INT64_MIN = -(2 ** 63)
_INT64_MAX = 2 ** 63 - 1


def _is_int(v: Any) -> bool:
    return isinstance(v, int) and not isinstance(v, bool)


# ---------------------------------------------------------------------------
# Spec-version gate (esm-spec §9.6.5)
# ---------------------------------------------------------------------------


def reject_template_imports_pre_v08(view: Any) -> None:
    """Reject the §9.7 constructs in files declaring esm < 0.8.0.

    ``expression_template_imports``, top-level ``expression_templates``
    (template-library files), and ``metaparameters`` arrive at ``esm: 0.8.0``;
    files declaring an earlier version that carry any of them are rejected with
    ``template_import_version_too_old`` (esm-spec §9.6.5). Mirrors
    :func:`reject_expression_templates_pre_v04` for the §9.7 constructs.
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
    if not (major == 0 and minor < 8):
        return

    offences: List[str] = []
    if "expression_templates" in view:
        offences.append("/expression_templates")
    if "metaparameters" in view:
        offences.append("/metaparameters")
    if "expression_template_imports" in view:
        offences.append("/expression_template_imports")
    for compkind in _COMPONENT_KINDS:
        comps = view.get(compkind)
        if not _is_object(comps):
            continue
        for cname, comp in comps.items():
            if _is_object(comp) and "expression_template_imports" in comp:
                offences.append(f"/{compkind}/{cname}/expression_template_imports")
    if offences:
        raise ExpressionTemplateError(
            "template_import_version_too_old",
            "expression_template_imports / top-level expression_templates / "
            f"metaparameters require esm >= 0.8.0; file declares {esm}. "
            f"Offending paths: {', '.join(offences)}",
        )


def _is_template_library_doc(raw: Any) -> bool:
    """True when ``raw`` has the template-library-file FORM (top-level
    ``expression_templates``, esm-spec §9.7.1). Purity (no models / reaction
    systems / loaders / coupling / domain) is checked separately at import
    edges."""
    return _is_object(raw) and "expression_templates" in raw


# ---------------------------------------------------------------------------
# Metaparameters (esm-spec §9.7.6)
# ---------------------------------------------------------------------------


def _require_int(v: Any, ctx: str) -> int:
    if _is_int(v):
        return v
    raise ExpressionTemplateError(
        "metaparameter_type_error",
        f"{ctx}: value {v!r} is not an integer (esm-spec §9.7.6)",
    )


def _collect_metaparam_decls(raw: Any, origin: str) -> Dict[str, Any]:
    out: Dict[str, Any] = {}
    mp = raw.get("metaparameters") if _is_object(raw) else None
    if mp is None:
        return out
    if not _is_object(mp):
        raise ExpressionTemplateError(
            "metaparameter_type_error",
            f"{origin}: `metaparameters` must be an object",
        )
    for name, decl in mp.items():
        if not _is_object(decl):
            raise ExpressionTemplateError(
                "metaparameter_type_error",
                f"{origin}: metaparameters.{name} must be an object with "
                '`type: "integer"`',
            )
        if decl.get("type") != "integer":
            raise ExpressionTemplateError(
                "metaparameter_type_error",
                f"{origin}: metaparameters.{name}: `type` must be \"integer\" "
                "(the only kind)",
            )
        d = decl.get("default")
        if d is not None:
            _require_int(d, f"{origin}: metaparameters.{name} default")
        out[name] = copy.deepcopy(decl)
    return out


#: Keys whose VALUES are never expression positions: metaparameter names are
#: substituted as bare variable-reference strings, so structural string fields
#: must not be rewritten. Template ``params`` shadowing is handled separately
#: in :func:`_substitute_metaparams_decl`.
_META_SUBST_SKIP_KEYS = frozenset({
    "metadata", "params", "type", "units", "kind", "description", "name",
    "wrt", "expression_template_imports", "metaparameters", "only",
    # `where` match-scoping constraints (esm-spec §9.6.1) carry index-set
    # NAMES, a structural namespace — never expression positions.
    "where",
})


def _substitute_metaparams(x: Any, values: Dict[str, int]) -> Any:
    """Substitute closed metaparameter names — appearing as bare strings, the
    variable-reference surface syntax — with their integer values, everywhere
    except the :data:`_META_SUBST_SKIP_KEYS` structural fields (esm-spec
    §9.7.6: expression-position substitution; no folding here)."""
    if isinstance(x, str):
        return values.get(x, x)
    if _is_array(x):
        return [_substitute_metaparams(v, values) for v in x]
    if _is_object(x):
        return {
            k: (copy.deepcopy(v) if k in _META_SUBST_SKIP_KEYS
                else _substitute_metaparams(v, values))
            for k, v in x.items()
        }
    return x


def _substitute_metaparams_decl(decl: Any, values: Dict[str, int]) -> Any:
    """Metaparameter substitution over one ``expression_templates`` entry: the
    template's own ``params`` shadow like-named metaparameters inside its
    ``body`` and ``match`` (a param is the inner binder; substitution must not
    capture it)."""
    params = decl.get("params") if _is_object(decl) else None
    shadowed = values
    if _is_array(params) and any(str(p) in values for p in params):
        shadowed = {k: v for k, v in values.items()
                    if k not in {str(p) for p in params}}
    return _substitute_metaparams(decl, shadowed)


def _checked_int64(v: int, ctx: str) -> int:
    if v < _INT64_MIN or v > _INT64_MAX:
        raise ExpressionTemplateError(
            "metaparameter_type_error",
            f"{ctx}: 64-bit integer overflow while folding a metaparameter "
            "expression",
        )
    return v


def _try_fold(x: Any, ctx: str) -> Optional[int]:
    """Fold a metaparameter expression (integer literal, name, or ``{op,
    args}`` over ``+ - * /``) to a concrete integer with exact 64-bit
    arithmetic (esm-spec §9.7.6). Returns ``None`` when the expression still
    contains a bare name (an open metaparameter awaiting a later binding site,
    or a template-param slot inside a rule body) — the site is left symbolic
    for a later pass. Raises ``metaparameter_type_error`` for a non-integer
    literal, an op outside ``+ - * /`` over concrete args, inexact division,
    or 64-bit overflow."""
    if _is_int(x):
        return _checked_int64(x, ctx)
    if isinstance(x, str):
        return None
    if isinstance(x, (float, bool)):
        raise ExpressionTemplateError(
            "metaparameter_type_error",
            f"{ctx}: non-integer literal {x} in a structural integer site "
            "(esm-spec §9.7.6)",
        )
    if not _is_object(x):
        raise ExpressionTemplateError(
            "metaparameter_type_error",
            f"{ctx}: invalid metaparameter expression (expected integer, "
            "name, or {op, args})",
        )
    op = x.get("op")
    args = x.get("args")
    if op is None or args is None or not _is_array(args) or len(args) == 0:
        raise ExpressionTemplateError(
            "metaparameter_type_error",
            f"{ctx}: invalid metaparameter expression "
            "(expected {op: +|-|*|/, args: [...]})",
        )
    vals = [_try_fold(a, ctx) for a in args]
    if any(v is None for v in vals):
        return None
    op = str(op)
    if op not in ("+", "-", "*", "/"):
        raise ExpressionTemplateError(
            "metaparameter_type_error",
            f"{ctx}: op '{op}' is not allowed in a metaparameter expression "
            "(only + - * /)",
        )
    acc = vals[0]
    if op == "-" and len(vals) == 1:
        return _checked_int64(-acc, ctx)
    for v in vals[1:]:
        if op == "+":
            acc = _checked_int64(acc + v, ctx)
        elif op == "-":
            acc = _checked_int64(acc - v, ctx)
        elif op == "*":
            acc = _checked_int64(acc * v, ctx)
        else:  # "/"
            if v == 0:
                raise ExpressionTemplateError(
                    "metaparameter_type_error", f"{ctx}: division by zero",
                )
            if acc % v != 0:
                raise ExpressionTemplateError(
                    "metaparameter_type_error",
                    f"{ctx}: {acc} / {v} does not divide exactly "
                    "(esm-spec §9.7.6)",
                )
            # Exact division: floor == truncation when the remainder is zero.
            acc = _checked_int64(acc // v, ctx)
    return acc


def _collect_names(out: List[str], x: Any) -> List[str]:
    if isinstance(x, str):
        out.append(x)
    elif _is_array(x):
        for v in x:
            _collect_names(out, v)
    elif _is_object(x):
        for k, v in x.items():
            if k == "op":
                continue
            _collect_names(out, v)
    return out


def _fold_structural_sites(x: Any, ctx: str) -> None:
    """Fold metaparameter expressions in the structural integer sites —
    ``aggregate`` dense ``ranges`` tuple entries and ``makearray`` ``regions``
    bound pairs — to concrete integers, in place, wherever they are already
    closed. Entries still carrying a bare name (a template-param slot, or an
    open metaparameter in a not-yet-fully-bound library) are left symbolic for
    a later binding site. Index-set sizes are folded separately by
    :func:`_fold_index_set_sizes`."""
    if _is_array(x):
        for v in x:
            _fold_structural_sites(v, ctx)
        return
    if not _is_object(x):
        return
    op = x.get("op")
    op_str = op if isinstance(op, str) else ""
    if op_str == "aggregate":
        ranges = x.get("ranges")
        if _is_object(ranges):
            for k, rv in ranges.items():
                if not _is_array(rv):
                    continue  # {from: ...} index-set refs untouched
                for i, entry in enumerate(rv):
                    if _is_int(entry):
                        continue
                    f = _try_fold(entry, f"{ctx}: aggregate ranges.{k}")
                    if f is not None:
                        rv[i] = f
    elif op_str == "makearray":
        regions = x.get("regions")
        if _is_array(regions):
            for region in regions:
                if not _is_array(region):
                    continue
                for bounds in region:
                    if not _is_array(bounds):
                        continue
                    for i, entry in enumerate(bounds):
                        if _is_int(entry):
                            continue
                        f = _try_fold(entry, f"{ctx}: makearray regions bound")
                        if f is not None:
                            bounds[i] = f
    for v in x.values():
        _fold_structural_sites(v, ctx)


def _fold_index_set_sizes(index_sets: Dict[str, Any], ctx: str, *,
                          strict: bool) -> None:
    """Fold interval ``size`` metaparameter expressions in an ``index_sets``
    registry. With ``strict=True`` (the root document, after its
    metaparameters closed) any remaining bare name is ``metaparameter_unbound``;
    with ``strict=False`` (a library instantiated at an edge that left some
    metaparameters open) open sizes stay symbolic and close at a later binding
    site."""
    for name, decl in index_sets.items():
        if not _is_object(decl):
            continue
        sz = decl.get("size")
        if sz is None or _is_int(sz):
            continue
        f = _try_fold(sz, f"{ctx}: index_sets.{name}.size")
        if f is None:
            if strict:
                names = ", ".join(dict.fromkeys(_collect_names([], sz)))
                raise ExpressionTemplateError(
                    "metaparameter_unbound",
                    f"{ctx}: index_sets.{name}.size references unbound "
                    f"name(s) {names} (esm-spec §9.7.6)",
                )
        else:
            decl["size"] = f


# ---------------------------------------------------------------------------
# Registration-time body composition (esm-spec §9.7.3)
# ---------------------------------------------------------------------------


def _collect_apply_names(out: List[str], x: Any) -> List[str]:
    if _is_array(x):
        for c in x:
            _collect_apply_names(out, c)
        return out
    if _is_object(x):
        if x.get("op") == APPLY_OP:
            nm = x.get("name")
            if nm is not None:
                out.append(str(nm))
        for v in x.values():
            _collect_apply_names(out, v)
    return out


def _inline_applies(node: Any, templates: Dict[str, Any], scope: str) -> Any:
    from .lower_expression_templates import _expand_apply

    if _is_array(node):
        return [_inline_applies(c, templates, scope) for c in node]
    if not _is_object(node):
        return node
    out = {k: _inline_applies(v, templates, scope) for k, v in node.items()}
    if out.get("op") == APPLY_OP:
        # Referenced bodies are already closed (topological order), so a
        # single _expand_apply produces an apply-free subtree; the bindings'
        # own sub-ASTs were inlined by the post-order walk above.
        return _expand_apply(out, templates, scope)
    return out


def _compose_template_bodies(templates: Dict[str, Any], scope: str) -> None:
    """Registration-time body composition (esm-spec §9.7.3): template bodies
    MAY reference other in-scope MATCH-LESS templates via
    ``apply_expression_template`` nodes. Builds the body-reference graph,
    rejects cycles (``apply_expression_template_recursive_body``) and chains
    deeper than :data:`MAX_TEMPLATE_EXPANSION_DEPTH` templates
    (``template_body_expansion_too_deep``), then inlines dependencies-first by
    pure substitution — confluent, so topological order cannot affect the
    result. Afterwards every ``body`` is a closed Expression AST with zero
    ``apply_expression_template`` nodes; runs BEFORE the §9.6.3 fixpoint ever
    consults a ``match`` rule."""
    if not templates:
        return
    refs: Dict[str, List[str]] = {}
    for name, decl in templates.items():
        body = decl.get("body") if _is_object(decl) else None
        refs[name] = _collect_apply_names([], body)
    if not any(refs.values()):
        return

    for name in sorted(refs):
        for r in refs[name]:
            tdecl = templates.get(r)
            if tdecl is None:
                raise ExpressionTemplateError(
                    "apply_expression_template_unknown_template",
                    f"{scope}.expression_templates.{name}: body references "
                    f"undeclared template '{r}' (esm-spec §9.7.3)",
                )
            if _is_object(tdecl) and tdecl.get("match") is not None:
                raise ExpressionTemplateError(
                    "apply_expression_template_unknown_template",
                    f"{scope}.expression_templates.{name}: body references "
                    f"'{r}', a `match` rewrite rule — only match-less "
                    "templates are invocable by name (esm-spec §9.7.3)",
                )

    # DFS over the reference graph: cycle detection, chain-depth bound, and a
    # dependencies-first (post-) order for inlining.
    state: Dict[str, int] = {}  # 1 = on stack, 2 = done
    depth: Dict[str, int] = {}  # templates on the longest chain from this node
    order: List[str] = []
    chain: List[str] = []

    def visit(name: str) -> int:
        st = state.get(name, 0)
        if st == 1:
            cyc = chain[chain.index(name):] + [name]
            raise ExpressionTemplateError(
                "apply_expression_template_recursive_body",
                f"{scope}.expression_templates: template-body reference cycle "
                f"{' -> '.join(cyc)} (esm-spec §9.7.3)",
            )
        if st == 2:
            return depth[name]
        state[name] = 1
        chain.append(name)
        d = 1
        for r in refs[name]:
            d = max(d, 1 + visit(r))
        chain.pop()
        state[name] = 2
        depth[name] = d
        if d > MAX_TEMPLATE_EXPANSION_DEPTH:
            raise ExpressionTemplateError(
                "template_body_expansion_too_deep",
                f"{scope}.expression_templates.{name}: body-reference chain "
                f"of {d} templates exceeds MAX_TEMPLATE_EXPANSION_DEPTH="
                f"{MAX_TEMPLATE_EXPANSION_DEPTH} (esm-spec §9.7.3)",
            )
        order.append(name)
        return d

    for name in sorted(refs):
        visit(name)

    for name in order:
        if not refs[name]:
            continue
        decl = templates[name]
        decl["body"] = _inline_applies(
            decl.get("body"), templates,
            f"{scope}.expression_templates.{name}",
        )


# ---------------------------------------------------------------------------
# Import-graph resolution (esm-spec §9.7.2 / §9.7.4 / §9.7.5)
# ---------------------------------------------------------------------------


class _TemplateScope:
    """Everything one template-library file exports after resolution in its
    OWN scope: its effective template sequence (imports depth-first
    post-order, then own declarations; esm-spec §9.7.4), its instantiated
    ``index_sets``, and its still-open metaparameter declarations (re-exported
    to the importer, esm-spec §9.7.6 binding site 2). All three dicts preserve
    insertion order — the effective declaration order is normative for the
    §9.6.3 tie-break."""

    __slots__ = ("templates", "index_sets", "metaparams")

    def __init__(self) -> None:
        self.templates: Dict[str, Any] = {}
        self.index_sets: Dict[str, Any] = {}
        self.metaparams: Dict[str, Any] = {}


def _merge_named(dst: Dict[str, Any], name: str, decl: Any, code: str,
                 what: str, origin: str) -> None:
    if name in dst:
        # Deep-equal redeclaration (a diamond import) dedups at first
        # occurrence; a non-equal collision is a conflict (§9.7.4/§9.7.5).
        if dst[name] == decl:
            return
        raise ExpressionTemplateError(
            code,
            f"{origin}: {what} '{name}' collides with a non-deep-equal "
            "existing definition (esm-spec §9.7.4/§9.7.5)",
        )
    dst[name] = decl


def _merge_scope(dst: _TemplateScope, src: _TemplateScope, origin: str) -> None:
    for n, d in src.templates.items():
        _merge_named(dst.templates, n, d, "template_import_name_conflict",
                     "template", origin)
    for n, d in src.index_sets.items():
        _merge_named(dst.index_sets, n, d, "template_import_index_set_conflict",
                     "index set", origin)
    for n, d in src.metaparams.items():
        _merge_named(dst.metaparams, n, d, "template_import_name_conflict",
                     "metaparameter", origin)


def _instantiate_scope(scope: _TemplateScope, values: Dict[str, int],
                       ctx: str) -> None:
    """Per-edge metaparameter instantiation (esm-spec §9.7.6 binding site 1):
    substitute the bound names as integer literals throughout the exported
    templates and index sets, then fold the structural sites that are now
    closed."""
    newt: Dict[str, Any] = {}
    for n, d in scope.templates.items():
        nd = _substitute_metaparams_decl(d, values)
        _fold_structural_sites(nd, ctx)
        newt[n] = nd
    scope.templates = newt
    newis: Dict[str, Any] = {}
    for n, d in scope.index_sets.items():
        newis[n] = _substitute_metaparams(d, values)
    _fold_index_set_sizes(newis, ctx, strict=False)
    scope.index_sets = newis


# ---------------------------------------------------------------------------
# Import-edge renaming / namespacing + free-name rebinding (esm-spec §9.7.7)
# ---------------------------------------------------------------------------

_NAME_SEGMENT_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def _is_valid_dotted_name(s: str) -> bool:
    """Grammar for a ``prefix`` and for ``rename``/``rebind`` TARGETS (esm-spec
    §9.7.7): one or more ``[A-Za-z_][A-Za-z0-9_]*`` segments joined by single
    dots — the §4.6 scoped-reference shape. Keys are never grammar-checked: they
    must match whatever the target actually exports (or whatever occurs free)."""
    return bool(s) and all(_NAME_SEGMENT_RE.match(seg) for seg in s.split("."))


def _name_map(raw: Any, field: str, where: str) -> Dict[str, str]:
    out: Dict[str, str] = {}
    if raw is None:
        return out
    if not _is_object(raw):
        raise ExpressionTemplateError(
            "template_import_rename_invalid",
            f"{where}: `{field}` must be an object mapping names to names "
            "(esm-spec §9.7.7)",
        )
    for k, v in raw.items():
        ks = str(k)
        if ks == "":
            raise ExpressionTemplateError(
                "template_import_rename_invalid",
                f"{where}: `{field}` has an empty key (esm-spec §9.7.7)",
            )
        if not (isinstance(v, str) and _is_valid_dotted_name(v)):
            raise ExpressionTemplateError(
                "template_import_rename_invalid",
                f"{where}: `{field}`.{ks} target {v!r} is not a valid dotted "
                "identifier (segments [A-Za-z_][A-Za-z0-9_]* joined by single "
                "dots; esm-spec §9.7.7)",
            )
        out[ks] = str(v)
    return out


#: Scalar Expression-node fields whose string value names an AXIS / index set
#: (rewritten by the index-set rename map, param-shadowed like §9.6.1).
_RENAME_AXIS_KEYS = ("wrt", "dim")

#: Object keys whose values are never variable-reference positions for the
#: rename walk: the metaparameter skip set plus the remaining scalar structural
#: ExpressionNode fields. ``from``, ``wrt``/``dim``, apply-``name``, and ``of``
#: are handled positionally in the walk.
_RENAME_PROTECTED_KEYS = _META_SUBST_SKIP_KEYS | frozenset({
    "op", "id", "expect_cadence", "reduce", "semiring", "manifold", "fn",
    "table", "side", "attrs", "members", "from_faq",
})


def _rename_walk(x: Any, varmap: Dict[str, str], isetmap: Dict[str, str],
                 tplmap: Dict[str, str]) -> Any:
    """One transitive-substitution pass over an imported declaration (esm-spec
    §9.7.7): ``varmap`` (renamed open metaparameters + rebound free names)
    rewrites bare strings in variable-reference positions; ``isetmap`` rewrites
    index-set reference positions (``{"from": …}`` values, the ``wrt``/``dim``
    axis fields, and the ``where.*.shape`` match-scoping index-set names, in
    ``body`` and ``match`` alike); ``tplmap`` rewrites
    ``apply_expression_template.name``. Structural scalar fields
    (:data:`_RENAME_PROTECTED_KEYS`) and bound-index lists (range ``of``) are
    never rewritten. Pure syntactic substitution — no evaluation.

    ``where`` is handled positionally (never by the protected-key copy that
    metaparameter substitution uses, esm-spec §9.7.7): a ``where`` block is a
    map ``{paramName: {shape: [indexSetName, …]}}``. Rename renames templates,
    index sets, and metaparameters — NOT template-internal param names — so the
    constraint KEYS (param names) are copied verbatim while each constraint's
    ``shape`` entries are mapped through ``isetmap`` exactly like a ``wrt``/
    ``from`` reference (an unmapped name stays as spelled). Without this the rule
    body/registry would use the renamed set while ``where`` still named the
    original, and registration would fail with
    ``template_constraint_unknown_index_set``."""
    if isinstance(x, str):
        return varmap.get(x, x)
    if _is_array(x):
        return [_rename_walk(v, varmap, isetmap, tplmap) for v in x]
    if _is_object(x):
        op = x.get("op")
        is_apply = op is not None and str(op) == APPLY_OP
        out: Dict[str, Any] = {}
        for k, v in x.items():
            ks = str(k)
            if ks == "from" and isinstance(v, str):
                out[ks] = isetmap.get(v, v)
            elif ks in _RENAME_AXIS_KEYS and isinstance(v, str):
                out[ks] = isetmap.get(v, v)
            elif ks == "name" and is_apply and isinstance(v, str):
                out[ks] = tplmap.get(v, v)
            elif ks == "where" and _is_object(v):
                out[ks] = _rename_where(v, isetmap)
            elif ks == "of" or ks in _RENAME_PROTECTED_KEYS:
                out[ks] = copy.deepcopy(v)
            else:
                out[ks] = _rename_walk(v, varmap, isetmap, tplmap)
        return out
    return x


def _rename_where(whr: Any, isetmap: Dict[str, str]) -> Any:
    """Rewrite a ``where`` match-scoping block (esm-spec §9.6.1) under an
    import-edge index-set rename (esm-spec §9.7.7). Constraint KEYS (param names)
    are copied verbatim — rename never touches template-internal param names —
    and each constraint's ``shape`` entries (index-set names) are mapped through
    ``isetmap``, with any unmapped name left as spelled (the body-reference
    rule)."""
    out: Dict[str, Any] = {}
    for p, cobj in whr.items():
        if _is_object(cobj):
            cout: Dict[str, Any] = {}
            for ck, cv in cobj.items():
                if str(ck) == "shape" and _is_array(cv):
                    cout[str(ck)] = [isetmap.get(e, e) if isinstance(e, str)
                                     else copy.deepcopy(e) for e in cv]
                else:
                    cout[str(ck)] = copy.deepcopy(cv)
            out[str(p)] = cout
        else:
            out[str(p)] = copy.deepcopy(cobj)
    return out


def _rename_decl(decl: Any, varmap: Dict[str, str], isetmap: Dict[str, str],
                 tplmap: Dict[str, str]) -> Any:
    """:func:`_rename_walk` over one template declaration with the §9.6.1
    shadowing rule: the template's own ``params`` shadow like-named entries of
    ``varmap`` and ``isetmap`` inside its ``body``/``match``. ``tplmap`` is never
    shadowed — params do not bind template names."""
    params = decl.get("params") if _is_object(decl) else None
    v2, i2 = varmap, isetmap
    if _is_array(params) and params:
        pset = {str(p) for p in params if isinstance(p, str)}
        if any(p in varmap for p in pset):
            v2 = {k: val for k, val in varmap.items() if k not in pset}
        if any(p in isetmap for p in pset):
            i2 = {k: val for k, val in isetmap.items() if k not in pset}
    return _rename_walk(decl, v2, i2, tplmap)


def _collect_bound_syms(out: set, x: Any) -> set:
    """Bound index symbols of a declaration: aggregate ``output_idx`` entries and
    ``ranges`` keys (at any nesting depth). Rebinding one would desynchronize the
    ranges KEYS from their ``expr`` occurrences, so it is rejected outright."""
    if _is_array(x):
        for v in x:
            _collect_bound_syms(out, v)
        return out
    if not _is_object(x):
        return out
    op = x.get("op")
    if op is not None and str(op) == "aggregate":
        oi = x.get("output_idx")
        if _is_array(oi):
            for e in oi:
                if isinstance(e, str):
                    out.add(str(e))
        rg = x.get("ranges")
        if _is_object(rg):
            for k in rg.keys():
                out.add(str(k))
    for v in x.values():
        _collect_bound_syms(out, v)
    return out


def _collect_ref_names(out: set, x: Any, shadowed: set) -> set:
    """Every bare string in a variable-reference position of a declaration (the
    positions ``varmap`` would rewrite), minus the per-template ``params`` shadow
    set. Used for the rebind occurs-check and the freshness (collision) guard."""
    if isinstance(x, str):
        if x not in shadowed:
            out.add(x)
        return out
    if _is_array(x):
        for v in x:
            _collect_ref_names(out, v, shadowed)
        return out
    if _is_object(x):
        for k, v in x.items():
            ks = str(k)
            if (ks == "from" or ks in _RENAME_AXIS_KEYS or ks == "of"
                    or ks in _RENAME_PROTECTED_KEYS):
                continue
            _collect_ref_names(out, v, shadowed)
        return out
    return out


def _apply_edge_renames(scope: "_TemplateScope", entry: Any, origin: str,
                        ref: str) -> "_TemplateScope":
    """Apply one import edge's ``prefix`` / ``rename`` / ``rebind`` (esm-spec
    §9.7.7) to the target's SURVIVING export scope — templates after ``only``,
    all index sets, and metaparameters still open after this edge's ``bindings``
    — transitively through every occurrence inside the surviving declarations.
    Runs after ``bindings`` instantiation and ``only`` filtering, before the
    §9.7.4/§9.7.5 merge, so dedup and conflict detection operate on post-rename
    names. Pure load-time substitution."""
    where = f"{origin}: import of '{ref}'"
    prefix_raw = entry.get("prefix")
    rename = _name_map(entry.get("rename"), "rename", where)
    rebind = _name_map(entry.get("rebind"), "rebind", where)
    if prefix_raw is not None and not (
            isinstance(prefix_raw, str) and _is_valid_dotted_name(prefix_raw)):
        raise ExpressionTemplateError(
            "template_import_rename_invalid",
            f"{where}: `prefix` {prefix_raw!r} is not a valid dotted identifier "
            "(segments [A-Za-z_][A-Za-z0-9_]* joined by single dots; "
            "esm-spec §9.7.7)",
        )
    prefix = None if prefix_raw is None else str(prefix_raw)
    if prefix is None and not rename and not rebind:
        return scope

    # --- `rename` keys must name a surviving exported name (typo protection) ---
    exported: set = set()
    exported.update(scope.templates.keys())
    exported.update(scope.index_sets.keys())
    exported.update(scope.metaparams.keys())
    for k in rename:
        if k not in exported:
            raise ExpressionTemplateError(
                "template_import_rename_unknown_name",
                f"{where}: `rename` names '{k}', which the target does not "
                "export at this edge (the surviving exports are templates after "
                "`only`, index sets, and metaparameters left open by this "
                "edge's `bindings`; esm-spec §9.7.7)",
            )

    def _final(n: str) -> str:
        if n in rename:
            return rename[n]
        return n if prefix is None else f"{prefix}.{n}"

    tplmap = {n: _final(n) for n in scope.templates}
    isetmap = {n: _final(n) for n in scope.index_sets}
    metamap = {n: _final(n) for n in scope.metaparams}

    # --- per-namespace final-name uniqueness ---
    for what, m in (("template", tplmap), ("index set", isetmap),
                    ("metaparameter", metamap)):
        seen: Dict[str, str] = {}
        for o, n in m.items():
            if n in seen:
                raise ExpressionTemplateError(
                    "template_import_rename_collision",
                    f"{where}: {what} names '{seen[n]}' and '{o}' both map to "
                    f"'{n}' after renaming (esm-spec §9.7.7)",
                )
            seen[n] = o

    # --- free / bound name inventory over the surviving declarations ---
    free: set = set()
    bound: set = set()
    params_all: set = set()
    for d in scope.templates.values():
        _collect_bound_syms(bound, d)
        shadowed: set = set()
        params = d.get("params") if _is_object(d) else None
        if _is_array(params):
            for p in params:
                if isinstance(p, str):
                    shadowed.add(str(p))
        params_all.update(shadowed)
        _collect_ref_names(free, d, shadowed)
    for d in scope.index_sets.values():
        for f in ("offsets", "values"):
            v = d.get(f) if _is_object(d) else None
            if isinstance(v, str):
                free.add(str(v))
    free -= set(scope.metaparams.keys())   # declared names are not free

    # --- `rebind` keys must denote free names (typo protection) ---
    for k in rebind:
        if k in exported:
            raise ExpressionTemplateError(
                "template_import_rebind_unknown_name",
                f"{where}: `rebind` names '{k}', a declared name of the target "
                "(template / index set / metaparameter) — `rebind` addresses "
                "only free names; use `rename` for declared names "
                "(esm-spec §9.7.7)",
            )
        if k in bound:
            raise ExpressionTemplateError(
                "template_import_rename_invalid",
                f"{where}: `rebind` key '{k}' is a bound index symbol "
                "(`output_idx` / `ranges`) of an imported template, not a free "
                "name (esm-spec §9.7.7)",
            )
        if k not in free:
            raise ExpressionTemplateError(
                "template_import_rebind_unknown_name",
                f"{where}: `rebind` names '{k}', which does not occur free in "
                "the imported declarations (esm-spec §9.7.7)",
            )

    # --- freshness guard: new bare names must not capture / merge ---
    taken: set = set(free - set(rebind.keys())) | bound | params_all
    newnames: List[str] = []
    for o, n in metamap.items():
        if o != n:
            newnames.append(n)
    for o, n in rebind.items():
        if o != n:
            newnames.append(n)
    for t in newnames:
        if t in taken:
            raise ExpressionTemplateError(
                "template_import_rename_collision",
                f"{where}: renamed/rebound name '{t}' collides with a name "
                "still in use inside the imported declarations (a remaining "
                "free name, a bound index symbol, a template param, or another "
                "rename/rebind target; esm-spec §9.7.7)",
            )
        taken.add(t)

    # --- apply (identity entries dropped; one simultaneous substitution) ---
    varmap: Dict[str, str] = {}
    for o, n in metamap.items():
        if o != n:
            varmap[o] = n
    for o, n in rebind.items():
        if o != n:
            varmap[o] = n
    iset_changed = {o: n for o, n in isetmap.items() if o != n}
    tpl_changed = {o: n for o, n in tplmap.items() if o != n}

    newt: Dict[str, Any] = {}
    for n, d in scope.templates.items():
        newt[tplmap[n]] = _rename_decl(d, varmap, iset_changed, tpl_changed)
    scope.templates = newt

    newi: Dict[str, Any] = {}
    for n, d in scope.index_sets.items():
        nd = _rename_walk(d, varmap, iset_changed, tpl_changed)
        of = nd.get("of") if _is_object(nd) else None
        if _is_array(of):
            nd["of"] = [iset_changed.get(e, e) if isinstance(e, str) else e
                        for e in of]
        newi[isetmap[n]] = nd
    scope.index_sets = newi

    newm: Dict[str, Any] = {}
    for n, d in scope.metaparams.items():
        newm[metamap[n]] = d
    scope.metaparams = newm
    return scope


def _load_import_raw(ref: str, base_dir: str, origin: str):
    if ref.startswith("http://") or ref.startswith("https://"):
        import urllib.error
        import urllib.request
        try:
            with urllib.request.urlopen(ref) as response:
                content = response.read().decode("utf-8")
        except Exception as e:  # noqa: BLE001 — reported with the stable code
            raise ExpressionTemplateError(
                "template_import_unresolved",
                f"{origin}: failed to download template-library ref "
                f"'{ref}': {e}",
            )
        try:
            raw = json.loads(content)
        except ValueError as e:
            raise ExpressionTemplateError(
                "template_import_unresolved",
                f"{origin}: template-library ref '{ref}' is not valid "
                f"JSON: {e}",
            )
        # Relative refs inside a remote library have no resolvable base; they
        # fail as unresolved when encountered.
        return raw, base_dir
    path = os.path.abspath(os.path.join(base_dir, ref))
    if not os.path.isfile(path):
        raise ExpressionTemplateError(
            "template_import_unresolved",
            f"{origin}: template-library file not found: {path} "
            f"(from ref '{ref}')",
        )
    with open(path, "r", encoding="utf-8") as fh:
        content = fh.read()
    try:
        raw = json.loads(content)
    except ValueError as e:
        raise ExpressionTemplateError(
            "template_import_unresolved",
            f"{origin}: template-library ref '{path}' is not valid JSON: {e}",
        )
    return raw, os.path.dirname(path)


def _canonical_ref(ref: str, base_dir: str) -> str:
    """Canonical key for a reference, used for import-cycle detection: URLs
    as-is; local paths resolved to absolute paths (as §4.7)."""
    if ref.startswith("http://") or ref.startswith("https://"):
        return ref
    return os.path.abspath(os.path.join(base_dir, ref))


def _validate_import_target_schema(raw: Any, ref: str, origin: str) -> None:
    # Lazy import: parse.py imports lower_expression_templates lazily, and
    # template_imports is imported from parse.load — avoid a module cycle.
    from .parse import _get_schema
    import jsonschema

    try:
        jsonschema.validate(raw, _get_schema())
    except jsonschema.ValidationError as e:
        raise ExpressionTemplateError(
            "template_import_unresolved",
            f"{origin}: import target '{ref}' failed schema validation: "
            f"{e.message}",
        )


def _resolve_import_entry(entry: Any, base_dir: str, stack: List[str],
                          origin: str) -> _TemplateScope:
    """Resolve ONE ``expression_template_imports`` entry (esm-spec §9.7.2):
    load the target (path-scoped cycle detection over canonical refs, as
    §4.7), verify library purity, resolve the target recursively in its own
    scope, instantiate at this edge's ``bindings``, then apply ``only``
    visibility filtering."""
    from .lower_expression_templates import reject_expression_templates_pre_v04

    if not _is_object(entry):
        raise ExpressionTemplateError(
            "template_import_unresolved",
            f"{origin}: expression_template_imports entries must be objects "
            "with a `ref` field",
        )
    ref = entry.get("ref")
    if not isinstance(ref, str) or not ref:
        raise ExpressionTemplateError(
            "template_import_unresolved",
            f"{origin}: expression_template_imports entry requires a "
            "non-empty string `ref`",
        )
    canonical = _canonical_ref(ref, base_dir)
    if canonical in stack:
        cyc = stack[stack.index(canonical):] + [canonical]
        raise ExpressionTemplateError(
            "template_import_cycle",
            f"{origin}: import-graph cycle detected: {' -> '.join(cyc)} "
            "(esm-spec §9.7.2)",
        )

    raw, target_dir = _load_import_raw(ref, base_dir, origin)
    reject_expression_templates_pre_v04(raw)
    reject_template_imports_pre_v08(raw)

    # Library purity (esm-spec §9.7.1): the two reference mechanisms are
    # disjoint — a component/subsystem file is not importable as a library.
    if not _is_template_library_doc(raw):
        raise ExpressionTemplateError(
            "template_import_not_library",
            f"{origin}: import target '{ref}' lacks top-level "
            "`expression_templates` — not a template-library file "
            "(esm-spec §9.7.1)",
        )
    for k in _LIBRARY_FORBIDDEN_KEYS:
        if k in raw:
            raise ExpressionTemplateError(
                "template_import_not_library",
                f"{origin}: import target '{ref}' declares `{k}` — not a "
                "pure template-library file (esm-spec §9.7.1)",
            )
    _validate_import_target_schema(raw, ref, origin)

    stack.append(canonical)
    try:
        scope = _process_library(raw, target_dir, stack, f"{origin} -> {ref}")
    finally:
        stack.pop()

    # Edge metaparameter bindings (esm-spec §9.7.6 binding site 1).
    bindings_raw = entry.get("bindings")
    values: Dict[str, int] = {}
    if _is_object(bindings_raw):
        for name, v in bindings_raw.items():
            if name not in scope.metaparams:
                raise ExpressionTemplateError(
                    "template_import_unknown_name",
                    f"{origin}: import of '{ref}' binds metaparameter "
                    f"'{name}', which the target neither declares nor "
                    "re-exports (esm-spec §9.7.6)",
                )
            values[name] = _require_int(
                v, f"{origin}: import of '{ref}', binding '{name}'")
    if values:
        _instantiate_scope(scope, values, f"{origin} -> {ref}")
        for name in values:
            scope.metaparams.pop(name, None)

    # `only` visibility filtering (esm-spec §9.7.2) — after the target's own
    # internal wiring resolved in its own scope.
    only = entry.get("only")
    if _is_array(only):
        keep = [str(n) for n in only]
        for n in keep:
            if n not in scope.templates:
                raise ExpressionTemplateError(
                    "template_import_unknown_name",
                    f"{origin}: `only` names template '{n}', which '{ref}' "
                    "does not declare (esm-spec §9.7.2)",
                )
        keepset = set(keep)
        scope.templates = {n: d for n, d in scope.templates.items()
                           if n in keepset}

    # Import-edge renaming / namespacing / free-name rebinding (esm-spec
    # §9.7.7): after `bindings` instantiation and `only` filtering, before the
    # §9.7.4/§9.7.5 merge, so dedup and conflict detection operate on
    # post-rename names.
    _apply_edge_renames(scope, entry, origin, ref)
    return scope


def _process_library(raw: Any, base_dir: str, stack: List[str],
                     origin: str) -> _TemplateScope:
    """Resolve a template-library document in its OWN scope: its imports
    (depth-first post-order), then its own templates / index sets /
    metaparameters appended in declaration order (esm-spec §9.7.4), then
    §9.7.3 body composition — so a BC-layer body reference to an imported
    interior stencil closes here, before any ``only`` filtering by a
    downstream importer."""
    scope = _TemplateScope()
    imports = raw.get("expression_template_imports")
    if _is_array(imports):
        for entry in imports:
            sub = _resolve_import_entry(entry, base_dir, stack, origin)
            _merge_scope(scope, sub, origin)

    own: Dict[str, Any] = {}
    tpl = raw.get("expression_templates")
    if _is_object(tpl):
        for n, d in tpl.items():
            own[str(n)] = copy.deepcopy(d)
    _validate_templates(own, origin)
    for n, d in own.items():
        _merge_named(scope.templates, n, d, "template_import_name_conflict",
                     "template", origin)

    isets = raw.get("index_sets")
    if _is_object(isets):
        for n, d in isets.items():
            _merge_named(scope.index_sets, str(n), copy.deepcopy(d),
                         "template_import_index_set_conflict", "index set",
                         origin)

    for n, d in _collect_metaparam_decls(raw, origin).items():
        _merge_named(scope.metaparams, n, d, "template_import_name_conflict",
                     "metaparameter", origin)

    # §9.7.3 body composition in the library's own scope (decl objects are
    # mutated in place, so scope.templates sees the closed bodies).
    _compose_template_bodies(scope.templates, origin)
    return scope


# ---------------------------------------------------------------------------
# Root-document resolution (the load-time entry point)
# ---------------------------------------------------------------------------


def _has_import_machinery(raw: Any) -> bool:
    if not _is_object(raw):
        return False
    if ("expression_templates" in raw or "metaparameters" in raw
            or "expression_template_imports" in raw):
        return True
    for compkind in _COMPONENT_KINDS:
        comps = raw.get(compkind)
        if not _is_object(comps):
            continue
        for comp in comps.values():
            if _is_object(comp) and "expression_template_imports" in comp:
                return True
    return False


def resolve_template_machinery(
    raw: Any,
    base_path: str,
    metaparameters: Optional[Dict[str, int]] = None,
) -> Optional[Dict[str, Any]]:
    """Resolve every esm-spec §9.7 construct of the ROOT document ``raw``
    (relative import refs resolve against ``base_path``): imports recursively
    with per-edge instantiation, ``index_sets`` merge, metaparameter close
    (``metaparameters`` is the loader-API binding site 4; already-closed edge
    bindings win, then API bindings, then defaults) and fold,
    expression-position substitution, and — for a root library file — §9.7.3
    body composition.

    Returns a new order-preserving dict tree ready for
    :func:`~earthsci_toolkit.lower_expression_templates.lower_expression_templates`
    with ``expression_template_imports``, ``metaparameters``, and top-level
    ``expression_templates`` consumed (Option A round-trip: none survives
    ``parse → emit``), or ``None`` when the document carries no §9.7 machinery
    (the legacy fast path). Does not mutate the input.
    """
    from .lower_expression_templates import reject_expression_templates_pre_v04

    api_raw = dict(metaparameters or {})
    if not _has_import_machinery(raw):
        if api_raw:
            names = ", ".join(sorted(str(k) for k in api_raw))
            raise ExpressionTemplateError(
                "template_import_unknown_name",
                f"loader API binds metaparameter(s) {names} but the document "
                "declares none (esm-spec §9.7.6)",
            )
        return None

    root: Dict[str, Any] = copy.deepcopy(raw)
    stack: List[str] = []
    base_dir = str(base_path)

    doc_meta = _collect_metaparam_decls(root, "document")
    doc_isets: Dict[str, Any] = {}
    if _is_object(root.get("index_sets")):
        for n, d in root["index_sets"].items():
            doc_isets[str(n)] = d

    # --- top-level templates + imports (root template-library file) ---
    is_library = "expression_templates" in root
    top_templates: Dict[str, Any] = {}
    if is_library:
        topscope = _TemplateScope()
        imports = root.get("expression_template_imports")
        if _is_array(imports):
            for entry in imports:
                sub = _resolve_import_entry(entry, base_dir, stack, "document")
                _merge_scope(topscope, sub, "document")
        own: Dict[str, Any] = {}
        tpl = root["expression_templates"]
        if _is_object(tpl):
            for n, d in tpl.items():
                own[str(n)] = d
        _validate_templates(own, "document")
        for n, d in own.items():
            _merge_named(topscope.templates, n, d,
                         "template_import_name_conflict", "template",
                         "document")
        for n, d in topscope.index_sets.items():
            _merge_named(doc_isets, n, d, "template_import_index_set_conflict",
                         "index set", "document")
        for n, d in topscope.metaparams.items():
            _merge_named(doc_meta, n, d, "template_import_name_conflict",
                         "metaparameter", "document")
        top_templates = topscope.templates

    # --- per-component imports (models / reaction systems, §9.7.2) ---
    for compkind in _COMPONENT_KINDS:
        comps = root.get(compkind)
        if not _is_object(comps):
            continue
        for cname, comp in comps.items():
            if not _is_object(comp):
                continue
            imports = comp.get("expression_template_imports")
            if imports is None:
                continue
            cscope = _TemplateScope()
            corigin = f"{compkind}.{cname}"
            if _is_array(imports):
                for entry in imports:
                    sub = _resolve_import_entry(entry, base_dir, stack, corigin)
                    _merge_scope(cscope, sub, corigin)
            tpl = comp.get("expression_templates")
            if _is_object(tpl):
                own = {str(n): d for n, d in tpl.items()}
                _validate_templates(own, corigin)
                for n, d in own.items():
                    _merge_named(cscope.templates, n, d,
                                 "template_import_name_conflict", "template",
                                 corigin)
            for n, d in cscope.index_sets.items():
                _merge_named(doc_isets, n, d,
                             "template_import_index_set_conflict",
                             "index set", corigin)
            for n, d in cscope.metaparams.items():
                _merge_named(doc_meta, n, d, "template_import_name_conflict",
                             "metaparameter", corigin)
            # The effective sequence (imports depth-first post-order, then
            # local declarations) becomes the component's template block; the
            # dict insertion order IS the §9.6.3 declaration order.
            comp["expression_templates"] = cscope.templates
            del comp["expression_template_imports"]

    # --- close this document's metaparameters (§9.7.6 sites 4-5) ---
    api: Dict[str, int] = {}
    for k, v in api_raw.items():
        api[str(k)] = _require_int(v, f"loader API metaparameter '{k}'")
    for k in sorted(api):
        if k not in doc_meta:
            raise ExpressionTemplateError(
                "template_import_unknown_name",
                f"loader API binds metaparameter '{k}', which the document "
                "does not declare (esm-spec §9.7.6)",
            )
    values: Dict[str, int] = {}
    open_names: List[str] = []
    for name, decl in doc_meta.items():
        if name in api:
            values[name] = api[name]
        else:
            d = decl.get("default")
            if d is None:
                open_names.append(name)
            else:
                values[name] = d
    if open_names:
        raise ExpressionTemplateError(
            "metaparameter_unbound",
            f"metaparameter(s) {', '.join(open_names)} still open after edge "
            "bindings, loader-API bindings, and defaults (esm-spec §9.7.6)",
        )

    # --- §9.7.6 name-collision check: no shadowing of visible names ---
    if doc_meta:
        visible = set(doc_isets.keys())
        for compkind in _COMPONENT_KINDS:
            comps = root.get(compkind)
            if not _is_object(comps):
                continue
            for comp in comps.values():
                if not _is_object(comp):
                    continue
                for blk in ("variables", "species", "parameters"):
                    b = comp.get(blk)
                    if _is_object(b):
                        visible.update(str(vn) for vn in b.keys())
        for name in doc_meta:
            if name in visible:
                raise ExpressionTemplateError(
                    "metaparameter_name_conflict",
                    f"metaparameter '{name}' collides with a visible "
                    "variable/parameter/species/index-set name "
                    "(esm-spec §9.7.6)",
                )

    # --- expression-position substitution of the closed values ---
    if values:
        for compkind in _COMPONENT_KINDS:
            comps = root.get(compkind)
            if not _is_object(comps):
                continue
            for comp in comps.values():
                if not _is_object(comp):
                    continue
                for k in list(comp.keys()):
                    if k == "expression_templates" and _is_object(comp[k]):
                        tpl = comp[k]
                        for tn in list(tpl.keys()):
                            tpl[tn] = _substitute_metaparams_decl(
                                tpl[tn], values)
                    else:
                        comp[k] = _substitute_metaparams(comp[k], values)
        for tn in list(top_templates.keys()):
            top_templates[tn] = _substitute_metaparams_decl(
                top_templates[tn], values)
        doc_isets = {n: _substitute_metaparams(d, values)
                     for n, d in doc_isets.items()}

    # --- fold structural sites on the closed document ---
    for compkind in _COMPONENT_KINDS:
        comps = root.get(compkind)
        if not _is_object(comps):
            continue
        for cname, comp in comps.items():
            if _is_object(comp):
                _fold_structural_sites(comp, f"{compkind}.{cname}")
    for tn, td in top_templates.items():
        _fold_structural_sites(td, f"document.expression_templates.{tn}")
    _fold_index_set_sizes(doc_isets, "document", strict=True)

    # --- root library file: compose bodies (validation), then strip; no §9.7
    #     construct survives parse → emit (esm-spec §9.7.6 round-trip) ---
    if is_library:
        _compose_template_bodies(top_templates, "document")
        del root["expression_templates"]
    root.pop("expression_template_imports", None)
    root.pop("metaparameters", None)
    if doc_isets:
        root["index_sets"] = doc_isets
    return root
