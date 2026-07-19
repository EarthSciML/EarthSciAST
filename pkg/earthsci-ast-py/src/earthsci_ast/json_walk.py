"""Shared leaf primitives for the template / coupling import machinery.

This is a dependency-free leaf module (it imports only stdlib + :mod:`.errors`)
so that :mod:`earthsci_ast.lower_expression_templates` (§9.6 lowering) and
:mod:`earthsci_ast.template_imports` (§9.7 imports) — which sit in a
mutually-recursive relationship — can both draw the low-level pieces they share
from here rather than from each other. Consolidating them here removes the
lazy back-import the two modules previously used to dodge a module cycle.

It carries:

* :class:`ExpressionTemplateError` — the stable-code error the whole
  expression-template / coupling-import stack raises (re-exported from
  ``lower_expression_templates`` for its historical import path).
* :func:`_is_object` / :func:`_is_array` — JSON-shape predicates.
* :func:`_walk_json` — the shared depth-first pre-order JSON visitor.
* :func:`expand_ref_env` / :func:`load_ref_raw` — the §4.7 ``${VAR}`` ref
  expansion + local/URL loader shared by the template-import and
  coupling-import resolvers (parameterised by the caller's diagnostic code).
"""

from __future__ import annotations

import json
import os
import re
from collections.abc import Iterator
from typing import Any, Callable

from .errors import EarthSciAstError

#: The op-name of an ``apply_expression_template`` node (esm-spec §9.6). Shared
#: by the §9.6 lowering pass and the §9.7 import machinery.
APPLY_OP = "apply_expression_template"


class ExpressionTemplateError(EarthSciAstError):
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
    (§9.6.6, raised from :mod:`earthsci_ast.template_imports` and
    :mod:`earthsci_ast.parse`):

    ``template_import_version_too_old``, ``template_import_unresolved``,
    ``template_import_not_library``, ``subsystem_ref_is_template_library``,
    ``template_import_cycle``, ``template_import_name_conflict``,
    ``template_import_unknown_name``, ``template_import_index_set_conflict``,
    ``template_body_expansion_too_deep``, ``metaparameter_unbound``,
    ``metaparameter_type_error``, ``metaparameter_name_conflict``,

    or one of the esm-spec §9.7.7 import-renaming codes (raised from
    :mod:`earthsci_ast.template_imports`):

    ``template_import_rename_unknown_name``,
    ``template_import_rebind_unknown_name``,
    ``template_import_rename_collision``, ``template_import_rename_invalid``,

    or one of the esm-spec §10.9–§10.11 coupling-library / ``coupling_import``
    role-binding codes (raised from :mod:`earthsci_ast.coupling_imports`, with
    ``subsystem_ref_is_coupling_library`` / ``template_import_is_coupling_library``
    raised from :mod:`earthsci_ast.parse` / :mod:`earthsci_ast.template_imports`):

    ``coupling_import_unresolved``, ``coupling_import_not_library``,
    ``coupling_library_illegal_payload``, ``coupling_library_nested_import``,
    ``coupling_edge_unknown_role``, ``coupling_role_unused``,
    ``coupling_import_unknown_role``, ``coupling_import_role_unbound``,
    ``coupling_import_bind_not_a_component``,
    ``subsystem_ref_is_coupling_library``,
    ``template_import_is_coupling_library``.

    The code constants themselves are defined in
    :mod:`earthsci_ast.error_handling`; their string values are part of the
    cross-binding contract and must never change.
    """

    def __init__(self, code: str, message: str) -> None:
        super().__init__(f"[{code}] {message}")
        self.code = code


def _is_object(v: Any) -> bool:
    return isinstance(v, dict)


def _is_array(v: Any) -> bool:
    return isinstance(v, list)


def _walk_json(
    node: Any,
    *,
    on_str: Callable[[str], None] | None = None,
    on_obj: Callable[[dict, str], None] | None = None,
    skip_keys: frozenset[str] | None = None,
    path: str = "",
    dedup: bool = False,
) -> None:
    """Shared depth-first PRE-ORDER visitor over a JSON value — the single
    recursion skeleton behind the read-only tree-walkers in
    :mod:`earthsci_ast.lower_expression_templates` and
    :mod:`earthsci_ast.template_imports`.

    For each string it calls ``on_str(value)``; for each dict it calls
    ``on_obj(node, path)`` BEFORE descending, then recurses into list elements
    (``"{path}/{index}"``) and dict VALUES (``"{path}/{key}"``), skipping any
    key in ``skip_keys``. ``path`` is a JSON-pointer-style location for the
    diagnostics that report one (collectors that don't need it omit ``on_obj``
    or ignore its second argument). Purely observational — it never rebuilds or
    mutates the tree, so transforming passes stay bespoke.

    ``dedup=True`` visits each unique dict/list ONCE, at its first (pre-order)
    occurrence. Template expansion splices subtrees by reference (see
    :func:`earthsci_ast.lower_expression_templates._substitute`), so post-
    expansion walkers run over a shared DAG: without dedup a subtree shared
    under many parents is re-walked once per path, which is exponential in the
    template-nesting depth. Callbacks must be per-node idempotent (all current
    users are: validators raise on the node itself, collectors record the
    node). Diagnostics are unaffected on trees without sharing, and on shared
    DAGs a raising validator still fires at the same first pre-order path.
    """
    seen: dict[int, Any] = {}

    def rec(node: Any, path: str) -> None:
        if isinstance(node, str):
            if on_str is not None:
                on_str(node)
            return
        if _is_array(node):
            if dedup:
                if id(node) in seen:
                    return
                # Keep the keyed object alive in the map so ids are not recycled.
                seen[id(node)] = node
            for i, child in enumerate(node):
                rec(child, f"{path}/{i}")
            return
        if _is_object(node):
            if dedup:
                if id(node) in seen:
                    return
                seen[id(node)] = node
            if on_obj is not None:
                on_obj(node, path)
            for k, v in node.items():
                if skip_keys is not None and k in skip_keys:
                    continue
                rec(v, f"{path}/{k}")

    rec(node, path)


# ---------------------------------------------------------------------------
# Raw-dict expression child traversal (the dict-form counterpart to
# :func:`earthsci_ast.expr_walk.iter_children`)
# ---------------------------------------------------------------------------
#
# ``expr_walk`` is the ONE canonical child-field set, but it needs the typed
# :class:`~earthsci_ast.esm_types.ExprNode` dataclasses. Many passes run on the
# RAW ``dict`` decoded from JSON (before parsing) and cannot use it, so the
# child-field set was historically hand-copied at each such pass. These three
# tuples are that set for the raw-dict form; :func:`iter_child_values` is the
# single descent every raw-dict expression walker should route through.
#
# Relationship to the typed set (``expr_walk._SINGLE_CHILD_FIELDS`` +
# ``args``/``values``/``table_axes``): the SINGLE/LIST fields and the ``axes``
# MAP mirror the typed child set exactly (``axes`` is the raw JSON key for the
# dataclass ``table_axes``). ``bindings`` and ``regions`` are raw-only fields
# the typed child traversal does NOT visit — an ``apply_expression_template``'s
# free-variable targets and a ``makearray``'s ``[[lo, hi], …]`` bound
# expressions. They carry references/loop symbols that the raw-dict
# reference-integrity walkers must still see, so they are included here and
# tagged so a caller that wants only the typed-canonical subset can skip them
# by field name. NOTE: unlike ``expr_walk`` (and ``cadence.child_exprs``), this
# visits ``axes`` in INSERTION order, not sorted — it matches the raw-dict
# reference walkers that route through it; a sorted-axes consumer keeps its own
# traversal.

#: Raw-dict expression child fields carried as LISTS of child expressions.
DICT_LIST_CHILD_FIELDS = ("args", "values")
#: Raw-dict expression child fields carrying a SINGLE nested child expression,
#: the verbatim dict-form of ``expr_walk._SINGLE_CHILD_FIELDS``.
DICT_SINGLE_CHILD_FIELDS = ("lower", "upper", "expr", "filter", "key")
#: Raw-dict expression child fields carried as ``{name: child}`` MAPS.
DICT_MAP_CHILD_FIELDS = ("axes", "bindings")


def _iter_region_children(regions: Any) -> Iterator[Any]:
    """Yield each ``str``/``dict`` bound expression nested in a ``makearray``
    ``regions`` value — a per-region list of per-axis ``[lo, hi]`` lists whose
    bounds may be literals, names, or op-nodes. Nested lists are flattened via
    an explicit LIFO stack; ints/floats/None are skipped. The traversal order is
    kept byte-for-byte identical to the historical structural-checks
    ``_iter_region_bounds`` walker so routing through it changes no diagnostic
    order."""
    if not isinstance(regions, list):
        return
    stack = list(regions)
    while stack:
        item = stack.pop()
        if isinstance(item, list):
            stack.extend(item)
        elif isinstance(item, (str, dict)):
            yield item


def iter_child_values(node: Any) -> Iterator[tuple[str, Any]]:
    """Yield ``(field_name, child_value)`` for every child-bearing field of a
    raw-dict expression ``node``, driven by the ONE canonical field set above.

    Visit order (matching the raw-dict reference walkers this replaces):
    ``args`` items, then ``lower``/``upper``/``expr``/``filter``/``key``, then
    ``values`` items, then ``axes`` then ``bindings`` map values, then
    ``regions`` bound expressions. Each child is tagged with the name of the
    field it came from so a caller that treats certain fields specially — a
    binder-aware walker, or one that wants only the typed-canonical subset and
    so skips ``bindings``/``regions`` — can filter by name while still sharing
    this single field list. A non-dict ``node`` yields nothing.

    This is the raw-dict counterpart of
    :func:`earthsci_ast.expr_walk.iter_children`; see the module notes above for
    how the two sets relate (``bindings``/``regions`` and insertion-order
    ``axes`` are the raw-only differences)."""
    if not isinstance(node, dict):
        return
    for arg in node.get("args", []) or []:
        yield ("args", arg)
    for field_name in DICT_SINGLE_CHILD_FIELDS:
        child = node.get(field_name)
        if child is not None:
            yield (field_name, child)
    for val in node.get("values", []) or []:
        yield ("values", val)
    axes = node.get("axes")
    if isinstance(axes, dict):
        for child in axes.values():
            yield ("axes", child)
    bindings = node.get("bindings")
    if isinstance(bindings, dict):
        for child in bindings.values():
            yield ("bindings", child)
    yield from (("regions", child) for child in _iter_region_children(node.get("regions")))


def walk_dict_exprs(node: Any) -> Iterator[Any]:
    """Pre-order walk over a raw-dict expression tree, yielding every node — the
    root first, including ``str`` leaves and numeric literals — descending
    exactly the canonical child set via :func:`iter_child_values`. The raw-dict
    counterpart to :func:`earthsci_ast.expr_walk.walk`."""
    yield node
    if isinstance(node, dict):
        for _field_name, child in iter_child_values(node):
            yield from walk_dict_exprs(child)


# ---------------------------------------------------------------------------
# Shared §4.7 ref loading (template-import + coupling-import resolvers)
# ---------------------------------------------------------------------------

_ENV_REF_RE = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}")


def expand_ref_env(ref: str) -> str:
    """Expand ``${VAR}`` tokens in a §4.7 ref from the environment.

    esm-spec §4.7: an OPTIONAL loader capability (like URL refs). An UNSET
    variable is left literal, so the ref simply fails to resolve
    (``template_import_unresolved`` / ``coupling_import_unresolved`` / the
    subsystem error) rather than silently misresolving. Only the braced
    ``${VAR}`` form is expanded (not bare ``$VAR``), for byte-consistency with
    the Julia binding.
    """
    return _ENV_REF_RE.sub(lambda m: os.environ.get(m.group(1), m.group(0)), ref)


def read_ref_text(
    ref: str,
    base_dir: str,
    *,
    resolve_path: Callable[[str, str], str],
    on_missing: Callable[[str, str], Exception],
    on_url_error: Callable[[str, Exception], Exception],
    on_read_error: Callable[[str, str, OSError], Exception] | None = None,
    path_exists: Callable[[str], bool] = os.path.isfile,
    url_error_types: tuple[type[BaseException], ...] = (Exception,),
    encoding: str | None = "utf-8",
) -> tuple[str, str | None]:
    """Read the raw text of a §4.7 ``ref`` — the single I/O primitive shared by
    :func:`load_ref_raw` (template/coupling imports) and
    :func:`earthsci_ast.parse._fetch_ref_content` (subsystem refs).

    ``ref`` is assumed to already have had its ``${VAR}`` tokens expanded (each
    caller applies :func:`expand_ref_env` under its own policy first). An
    ``http(s)://`` ref is downloaded and UTF-8 decoded; anything else is
    resolved to a local path via ``resolve_path(base_dir, ref)`` and read from
    disk. Every divergence between the two callers is a parameter so each keeps
    its OWN error type, path-resolution policy, and read semantics:

    * ``resolve_path`` — how a relative ref becomes a local path
      (``normpath`` vs ``abspath`` join).
    * ``path_exists`` — the existence predicate (``os.path.exists`` matches dirs
      too; the default ``os.path.isfile`` does not).
    * ``encoding`` — text encoding for the local open (``None`` = platform
      default, matching a bare ``open(path)``).
    * ``url_error_types`` — which download exceptions are wrapped; anything
      outside the tuple propagates raw (subsystem refs wrap only the
      ``urllib.error`` classes, the import loaders wrap everything).
    * ``on_url_error`` / ``on_missing`` / ``on_read_error`` — build the
      caller's exception for a failed download, a missing file, and (only when
      supplied) an unreadable file. ``on_read_error=None`` lets the ``OSError``
      from a local read propagate unwrapped.

    Returns ``(text, local_path)`` where ``local_path`` is the resolved path for
    a local ref or ``None`` for a URL — letting the caller compute its own base
    dir / JSON-error label without re-deriving the path.
    """
    if ref.startswith("http://") or ref.startswith("https://"):
        import urllib.request

        try:
            with urllib.request.urlopen(ref) as response:
                return response.read().decode("utf-8"), None
        except url_error_types as e:
            raise on_url_error(ref, e) from e
    path = resolve_path(base_dir, ref)
    if not path_exists(path):
        raise on_missing(ref, path)
    if on_read_error is None:
        with open(path, encoding=encoding) as fh:
            return fh.read(), path
    try:
        with open(path, encoding=encoding) as fh:
            return fh.read(), path
    except OSError as e:
        raise on_read_error(ref, path, e) from e


def load_ref_raw(
    ref: str,
    base_dir: str,
    *,
    code: str,
    subject: str,
    origin: str | None = None,
) -> tuple[Any, str]:
    """Resolve a §4.7 ``ref`` to a parsed JSON document, reusing the same
    ``${VAR}`` expansion + local/URL loading for both the §9.7 template-import
    resolver and the §10.10 coupling-import resolver.

    ``http(s)://`` refs are downloaded; everything else is read from disk
    relative to ``base_dir``. Every failure is reported as an
    :class:`ExpressionTemplateError` carrying ``code`` (the caller's stable
    diagnostic — ``template_import_unresolved`` or ``coupling_import_unresolved``),
    with ``subject`` naming the file kind in the message (e.g.
    ``"template-library"`` / ``"coupling-library"``) and ``origin`` optionally
    prefixing it. Returns ``(raw, new_base_dir)`` where ``new_base_dir`` is the
    directory of a local file (for resolving nested relative refs) or
    ``base_dir`` unchanged for a URL.
    """
    prefix = f"{origin}: " if origin else ""
    ref = expand_ref_env(ref)
    content, path = read_ref_text(
        ref,
        base_dir,
        resolve_path=lambda base, r: os.path.abspath(os.path.join(base, r)),
        on_missing=lambda r, p: ExpressionTemplateError(
            code, f"{prefix}{subject} file not found: {p} (from ref '{r}')"
        ),
        on_url_error=lambda r, e: ExpressionTemplateError(
            code, f"{prefix}failed to download {subject} ref '{r}': {e}"
        ),
        on_read_error=lambda r, p, e: ExpressionTemplateError(
            code, f"{prefix}{subject} file unreadable: {p} (from ref '{r}'): {e}"
        ),
    )
    # JSON errors quote the URL ref itself but the resolved path for a local
    # file; the base is the URL's caller-supplied base or the local file's dir.
    # A relative ref inside a remote library has no resolvable base; it fails as
    # unresolved when encountered.
    label = ref if path is None else path
    try:
        raw = json.loads(content)
    except ValueError as e:
        raise ExpressionTemplateError(
            code, f"{prefix}{subject} ref '{label}' is not valid JSON: {e}"
        ) from e
    new_base = base_dir if path is None else os.path.dirname(path)
    return raw, new_base
