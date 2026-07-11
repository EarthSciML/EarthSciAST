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
    :mod:`earthsci_ast.diagnostics`; their string values are part of the
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
    """
    if isinstance(node, str):
        if on_str is not None:
            on_str(node)
        return
    if _is_array(node):
        for i, child in enumerate(node):
            _walk_json(
                child, on_str=on_str, on_obj=on_obj, skip_keys=skip_keys, path=f"{path}/{i}"
            )
        return
    if _is_object(node):
        if on_obj is not None:
            on_obj(node, path)
        for k, v in node.items():
            if skip_keys is not None and k in skip_keys:
                continue
            _walk_json(
                v, on_str=on_str, on_obj=on_obj, skip_keys=skip_keys, path=f"{path}/{k}"
            )


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
    if ref.startswith("http://") or ref.startswith("https://"):
        import urllib.request

        try:
            with urllib.request.urlopen(ref) as response:
                content = response.read().decode("utf-8")
        except Exception as e:  # noqa: BLE001 — reported with the stable code
            raise ExpressionTemplateError(
                code, f"{prefix}failed to download {subject} ref '{ref}': {e}"
            ) from e
        try:
            raw = json.loads(content)
        except ValueError as e:
            raise ExpressionTemplateError(
                code, f"{prefix}{subject} ref '{ref}' is not valid JSON: {e}"
            ) from e
        # A relative ref inside a remote library has no resolvable base; it
        # fails as unresolved when encountered.
        return raw, base_dir
    path = os.path.abspath(os.path.join(base_dir, ref))
    if not os.path.isfile(path):
        raise ExpressionTemplateError(
            code, f"{prefix}{subject} file not found: {path} (from ref '{ref}')"
        )
    try:
        with open(path, encoding="utf-8") as fh:
            content = fh.read()
    except OSError as e:
        raise ExpressionTemplateError(
            code, f"{prefix}{subject} file unreadable: {path} (from ref '{ref}'): {e}"
        ) from e
    try:
        raw = json.loads(content)
    except ValueError as e:
        raise ExpressionTemplateError(
            code, f"{prefix}{subject} ref '{path}' is not valid JSON: {e}"
        ) from e
    return raw, os.path.dirname(path)
