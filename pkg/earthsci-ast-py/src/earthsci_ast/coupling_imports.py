"""Coupling-library files and ``coupling_import`` role binding (esm-spec §10.9–§10.11).

A *coupling-library file* is a document whose payload is a top-level
``coupling_roles`` map plus a role-scoped ``coupling`` array. An assembly reuses
it with a ``{"type": "coupling_import", "ref": ..., "bind": ...}`` coupling
entry: at flatten the import expands into concrete ``variable_map`` / ``couple``
/ ``operator_compose`` / ``event`` edges by substituting the bound actual
component for every role-named top-level segment (the §10.10.2 occurrence
surface).

Expansion runs *inside* flatten (esm-spec §10.10.3), after subsystem mounting
(which happens at load) and before the coupling-rule step, so every ``bind``
target resolves against fully-mounted components. The ``coupling_import`` source
entry is preserved for round-trip; only the flattened system carries the
expanded edges.

This module is the Python counterpart of ``pkg/earthsci-ast-ts/src/coupling-imports.ts``.
"""

from __future__ import annotations

import copy
from typing import Any, Callable

from .error_handling import (
    COUPLING_EDGE_UNKNOWN_ROLE,
    COUPLING_IMPORT_BIND_NOT_A_COMPONENT,
    COUPLING_IMPORT_NOT_LIBRARY,
    COUPLING_IMPORT_ROLE_UNBOUND,
    COUPLING_IMPORT_UNKNOWN_ROLE,
    COUPLING_IMPORT_UNRESOLVED,
    COUPLING_LIBRARY_ILLEGAL_PAYLOAD,
    COUPLING_LIBRARY_NESTED_IMPORT,
    COUPLING_ROLE_UNUSED,
)
from .json_walk import (
    DICT_LIST_CHILD_FIELDS,
    DICT_MAP_CHILD_FIELDS,
    DICT_SINGLE_CHILD_FIELDS,
    ExpressionTemplateError,
    load_ref_raw,
)

# Payload keys a coupling-library file MUST NOT declare (esm-spec §10.9).
_LIBRARY_FORBIDDEN_KEYS = (
    "models",
    "reaction_systems",
    "data_loaders",
    "domain",
    "index_sets",
    "metaparameters",
    "expression_templates",
)

# Coupling-entry types a library edge MAY carry (esm-spec §10.9).
_ROLE_BEARING_TYPES = frozenset({"variable_map", "couple", "operator_compose", "event"})

# A resolver mapping a ``ref`` string (+ base directory) to a parsed
# coupling-library document (a dict). Tests may supply an in-memory resolver.
LoadRefFn = Callable[[str, str], Any]

# A reference-rewriting function: role-scoped ref string -> rewritten ref.
RefFn = Callable[[str], str]


def _is_object(v: Any) -> bool:
    return isinstance(v, dict)


def is_coupling_library_doc(raw: Any) -> bool:
    """True when ``raw`` has the coupling-library-file FORM (top-level
    ``coupling_roles``, esm-spec §10.9). Presence of that key is the sole
    positive identifier of the file kind; purity is checked separately at the
    import edge."""
    return _is_object(raw) and "coupling_roles" in raw


# ---------------------------------------------------------------------------
# Reference rewriting — the §10.10.2 occurrence surface
# ---------------------------------------------------------------------------


def _head_segment(ref: str) -> str:
    dot = ref.find(".")
    return ref if dot == -1 else ref[:dot]


def _rewrite_scoped_ref(ref: str, bind: dict[str, str]) -> str:
    """Replace the top-level segment of a scoped reference with its bound actual.

    ``"Fuel.w_0"`` under ``{"Fuel": "FuelModelLookup"}`` -> ``"FuelModelLookup.w_0"``;
    a dotted bind value (``{"Fuel": "Parent.Child"}``) -> ``"Parent.Child.w_0"``.
    A segment not in ``bind`` is returned unchanged (e.g. bare ``"t"``, literals).
    """
    dot = ref.find(".")
    head = ref if dot == -1 else ref[:dot]
    tail = "" if dot == -1 else ref[dot:]
    actual = bind.get(head)
    return ref if actual is None else actual + tail


def _rewrite_expr(expr: Any, fn: RefFn) -> Any:
    """Rewrite/visit every scoped reference inside an Expression tree.

    Numbers pass through; strings are rewritten via ``fn``. Operator nodes recurse
    into the FULL canonical raw-dict child set — sourced from the ONE shared slot
    set (:data:`json_walk.DICT_SINGLE_CHILD_FIELDS` /
    :data:`~json_walk.DICT_LIST_CHILD_FIELDS` /
    :data:`~json_walk.DICT_MAP_CHILD_FIELDS`) rather than a hand-copied list, so
    this rewriter can never drift from the canonical expression child slots the
    reference walkers descend. (An earlier args-only walk let a role-scoped
    reference inside an aggregate body / filter / key / bounds escape both
    rewriting and the ``coupling_edge_unknown_role`` check.) An
    ``apply_expression_template`` node's ``bindings`` VALUES are additionally
    free-variable targets (esm-spec §10.10.2) — Expressions in their own right.
    """
    if isinstance(expr, bool):
        return expr
    if isinstance(expr, (int, float)):
        return expr
    if isinstance(expr, str):
        return fn(expr)
    if not _is_object(expr):
        return expr
    node = expr
    for k in DICT_SINGLE_CHILD_FIELDS:
        if k in node:
            node[k] = _rewrite_expr(node[k], fn)
    for k in DICT_LIST_CHILD_FIELDS:
        if isinstance(node.get(k), list):
            node[k] = [_rewrite_expr(a, fn) for a in node[k]]
    # ``axes`` and ``bindings`` are the two raw-dict MAP child fields
    # (:data:`json_walk.DICT_MAP_CHILD_FIELDS`) — handled by name because their
    # scopes differ: ``axes`` values are per-axis input Expressions on any node,
    # while ``bindings`` values are free-variable-target Expressions only on an
    # ``apply_expression_template`` node (esm-spec §10.10.2).
    for k in DICT_MAP_CHILD_FIELDS:
        m = node.get(k)
        if not _is_object(m):
            continue
        if k == "bindings" and node.get("op") != "apply_expression_template":
            continue
        node[k] = {mk: _rewrite_expr(mv, fn) for mk, mv in m.items()}
    return node


def _rewrite_entry_in_place(entry: dict[str, Any], struct_fn: RefFn, expr_fn: RefFn) -> None:
    """Apply ``struct_fn`` to every structural system/scoped reference of a
    coupling entry and ``expr_fn`` to every scoped reference inside its
    Expression fields (esm-spec §10.10.2). Mutates ``entry`` in place (callers
    pass a clone)."""
    etype = entry.get("type")

    if etype == "variable_map":
        if isinstance(entry.get("from"), str):
            entry["from"] = struct_fn(entry["from"])
        if isinstance(entry.get("to"), str):
            entry["to"] = struct_fn(entry["to"])
        if _is_object(entry.get("transform")):
            entry["transform"] = _rewrite_expr(entry["transform"], expr_fn)

    elif etype == "couple":
        if isinstance(entry.get("systems"), list):
            entry["systems"] = [struct_fn(s) if isinstance(s, str) else s for s in entry["systems"]]
        connector = entry.get("connector")
        if _is_object(connector) and isinstance(connector.get("equations"), list):
            for eq in connector["equations"]:
                if not _is_object(eq):
                    continue
                if isinstance(eq.get("from"), str):
                    eq["from"] = struct_fn(eq["from"])
                if isinstance(eq.get("to"), str):
                    eq["to"] = struct_fn(eq["to"])
                if eq.get("expression") is not None:
                    eq["expression"] = _rewrite_expr(eq["expression"], expr_fn)

    elif etype == "operator_compose":
        if isinstance(entry.get("systems"), list):
            entry["systems"] = [struct_fn(s) if isinstance(s, str) else s for s in entry["systems"]]
        translate = entry.get("translate")
        if _is_object(translate):
            nxt: dict[str, Any] = {}
            for k, v in translate.items():
                nk = struct_fn(k)
                if isinstance(v, str):
                    nxt[nk] = struct_fn(v)
                elif _is_object(v):
                    vv = dict(v)
                    if isinstance(vv.get("var"), str):
                        vv["var"] = struct_fn(vv["var"])
                    nxt[nk] = vv
                else:
                    nxt[nk] = v
            entry["translate"] = nxt

    elif etype == "event":
        if isinstance(entry.get("conditions"), list):
            entry["conditions"] = [_rewrite_expr(c, expr_fn) for c in entry["conditions"]]

        def rewrite_affect(a: Any) -> Any:
            if not _is_object(a):
                return a
            if isinstance(a.get("lhs"), str):
                a["lhs"] = struct_fn(a["lhs"])
            if a.get("rhs") is not None:
                a["rhs"] = _rewrite_expr(a["rhs"], expr_fn)
            return a

        if isinstance(entry.get("affects"), list):
            entry["affects"] = [rewrite_affect(a) for a in entry["affects"]]
        if isinstance(entry.get("affect_neg"), list):
            entry["affect_neg"] = [rewrite_affect(a) for a in entry["affect_neg"]]
        trigger = entry.get("trigger")
        if (
            _is_object(trigger)
            and trigger.get("type") == "condition"
            and trigger.get("expression") is not None
        ):
            trigger["expression"] = _rewrite_expr(trigger["expression"], expr_fn)
        fa = entry.get("functional_affect")
        if _is_object(fa):
            for key in ("read_vars", "read_params", "modified_params"):
                if isinstance(fa.get(key), list):
                    fa[key] = [struct_fn(s) if isinstance(s, str) else s for s in fa[key]]
        if isinstance(entry.get("discrete_parameters"), list):
            entry["discrete_parameters"] = [
                struct_fn(s) if isinstance(s, str) else s for s in entry["discrete_parameters"]
            ]


def _collect_role_segments(edge: Any) -> set[str]:
    """Collect the top-level role segments a library edge references. Structural
    ref fields (systems[], from/to, translate keys, event var lists) always name
    a role; Expression strings name a role only when they are scoped references
    (contain a dot) — bare Expression operands like ``"t"`` are incidental."""
    seen: set[str] = set()
    clone = copy.deepcopy(edge)

    def struct_fn(ref: str) -> str:
        seen.add(_head_segment(ref))
        return ref

    def expr_fn(ref: str) -> str:
        if "." in ref:
            seen.add(_head_segment(ref))
        return ref

    if _is_object(clone):
        _rewrite_entry_in_place(clone, struct_fn, expr_fn)
    return seen


# ---------------------------------------------------------------------------
# Ref loading (mirrors the §9.7 template resolver, earthsci_ast.template_imports)
# ---------------------------------------------------------------------------


def _default_load_ref(ref: str, base_path: str) -> Any:
    """Resolve a ``coupling_import`` ``ref`` to a parsed document via the shared
    §4.7 loader (:func:`json_walk.load_ref_raw`) — the same ``${VAR}`` expansion
    + local/URL loading the template-import resolver uses. Failures are reported
    with ``coupling_import_unresolved``."""
    raw, _base = load_ref_raw(
        ref, base_path, code=COUPLING_IMPORT_UNRESOLVED, subject="coupling-library"
    )
    return raw


# ---------------------------------------------------------------------------
# Component resolution (esm-spec §10.10.1)
# ---------------------------------------------------------------------------


def _child_subsystem(node: Any, name: str) -> Any:
    """Return the ``name`` subsystem of a component node (typed dataclass or raw
    dict), or ``None`` if absent."""
    subs = getattr(node, "subsystems", None)
    if subs is None and _is_object(node):
        subs = node.get("subsystems")
    if not isinstance(subs, dict):
        return None
    return subs.get(name)


def _resolves_to_component(esm_file: Any, value: str) -> bool:
    """Resolve a ``bind`` value as a component path (esm-spec §10.10.1) — a
    system or loader node, walking ``models`` / ``reaction_systems`` /
    ``data_loaders`` then nested ``subsystems``, never terminating on a
    variable."""
    if not isinstance(value, str) or not value:
        return False
    segs = value.split(".")
    top = segs[0]
    models = getattr(esm_file, "models", None) or {}
    reaction_systems = getattr(esm_file, "reaction_systems", None) or {}
    data_loaders = getattr(esm_file, "data_loaders", None) or {}
    node: Any = None
    for table in (models, reaction_systems, data_loaders):
        if isinstance(table, dict) and top in table:
            node = table[top]
            break
    if node is None:
        return False
    for seg in segs[1:]:
        node = _child_subsystem(node, seg)
        if node is None:
            return False
    return True


# ---------------------------------------------------------------------------
# Library validation + expansion
# ---------------------------------------------------------------------------


def _expand_one(lib: Any, ref: str, bind: dict[str, str], esm_file: Any) -> list[dict[str, Any]]:
    """Validate a resolved coupling-library document and expand one
    ``coupling_import`` entry into its concrete (raw) edges, bound to ``bind``.
    Raises the esm-spec §10.11 diagnostics."""
    if not is_coupling_library_doc(lib):
        raise ExpressionTemplateError(
            COUPLING_IMPORT_NOT_LIBRARY,
            f"coupling_import ref '{ref}' lacks top-level `coupling_roles` — "
            "not a coupling-library file (esm-spec §10.9)",
        )
    doc = lib

    # Purity (esm-spec §10.9).
    for k in _LIBRARY_FORBIDDEN_KEYS:
        if k in doc:
            raise ExpressionTemplateError(
                COUPLING_LIBRARY_ILLEGAL_PAYLOAD,
                f"coupling-library '{ref}' declares `{k}` — a coupling library "
                "is nothing but roles + wiring (esm-spec §10.9)",
            )

    roles_map = doc.get("coupling_roles")
    roles = list(roles_map.keys()) if _is_object(roles_map) else []
    if not roles:
        raise ExpressionTemplateError(
            COUPLING_LIBRARY_ILLEGAL_PAYLOAD,
            f"coupling-library '{ref}' declares no roles (esm-spec §10.9: "
            "`coupling_roles` is required, non-empty)",
        )
    edges = doc.get("coupling")
    edges = edges if isinstance(edges, list) else []
    if not edges:
        raise ExpressionTemplateError(
            COUPLING_LIBRARY_ILLEGAL_PAYLOAD,
            f"coupling-library '{ref}' has an empty `coupling` array "
            "(esm-spec §10.9: required, non-empty)",
        )

    # Edge-type + role-scope checks over the declared roles.
    role_set = set(roles)
    used_roles: set[str] = set()
    for edge in edges:
        if not _is_object(edge):
            continue
        etype = edge.get("type")
        if etype == "coupling_import":
            raise ExpressionTemplateError(
                COUPLING_LIBRARY_NESTED_IMPORT,
                f"coupling-library '{ref}' contains a nested coupling_import "
                "(v1 forbids layering, esm-spec §10.9)",
            )
        if etype == "callback" or "expression_template_imports" in edge:
            raise ExpressionTemplateError(
                COUPLING_LIBRARY_ILLEGAL_PAYLOAD,
                f"coupling-library '{ref}' edge of type '{etype}' is not "
                "role-substitutable (no callback entries or edge-level "
                "expression_template_imports, esm-spec §10.9)",
            )
        if not isinstance(etype, str) or etype not in _ROLE_BEARING_TYPES:
            raise ExpressionTemplateError(
                COUPLING_LIBRARY_ILLEGAL_PAYLOAD,
                f"coupling-library '{ref}' contains an unsupported edge type "
                f"'{etype}' (esm-spec §10.9)",
            )
        for seg in _collect_role_segments(edge):
            if seg not in role_set:
                raise ExpressionTemplateError(
                    COUPLING_EDGE_UNKNOWN_ROLE,
                    f"coupling-library '{ref}': edge references '{seg}', which "
                    "is not a declared role (esm-spec §10.9)",
                )
            used_roles.add(seg)
    for role in roles:
        if role not in used_roles:
            raise ExpressionTemplateError(
                COUPLING_ROLE_UNUSED,
                f"coupling-library '{ref}': role '{role}' is declared but "
                "referenced by no edge (esm-spec §10.9)",
            )

    # Binding — total and checked (esm-spec §10.10.1).
    for key in bind:
        if key not in role_set:
            raise ExpressionTemplateError(
                COUPLING_IMPORT_UNKNOWN_ROLE,
                f"coupling_import ref '{ref}': bind key '{key}' is not a "
                "declared role (esm-spec §10.10.1)",
            )
    for role in roles:
        if role not in bind:
            raise ExpressionTemplateError(
                COUPLING_IMPORT_ROLE_UNBOUND,
                f"coupling_import ref '{ref}': role '{role}' has no bind entry "
                "(binding is total, esm-spec §10.10.1)",
            )
        if not _resolves_to_component(esm_file, bind[role]):
            raise ExpressionTemplateError(
                COUPLING_IMPORT_BIND_NOT_A_COMPONENT,
                f"coupling_import ref '{ref}': bind '{role}' -> '{bind[role]}' "
                "does not resolve to a component (esm-spec §10.10.1)",
            )

    # Expand: substitute bound actuals for role names, one simultaneous rewrite.
    def rw(r: str) -> str:
        return _rewrite_scoped_ref(r, bind)

    expanded: list[dict[str, Any]] = []
    for edge in edges:
        clone = copy.deepcopy(edge)
        _rewrite_entry_in_place(clone, rw, rw)
        expanded.append(clone)
    return expanded


def expand_coupling_imports(
    esm_file: Any,
    base_path: str = ".",
    load_ref: LoadRefFn | None = None,
) -> list[Any]:
    """Expand every ``coupling_import`` entry in ``esm_file.coupling`` into
    concrete (typed) coupling edges, splicing them in the position of the import
    entry (esm-spec §10.10.3).

    Non-import entries pass through untouched; a file with no ``coupling_import``
    entries returns its coupling list verbatim and never touches disk (so no
    ``load_ref`` is needed). ``load_ref(ref, base_path)`` returns a parsed
    coupling-library document; the default reads it from disk relative to
    ``base_path``.
    """
    from .esm_types import CouplingImport
    from .parse import _parse_coupling_entry

    coupling = list(getattr(esm_file, "coupling", None) or [])
    if not any(isinstance(e, CouplingImport) for e in coupling):
        return coupling

    resolver = load_ref if load_ref is not None else _default_load_ref
    out: list[Any] = []
    for entry in coupling:
        if not isinstance(entry, CouplingImport):
            out.append(entry)
            continue
        ref = entry.ref if isinstance(entry.ref, str) else ""
        bind: dict[str, str] = {
            k: v for k, v in (entry.bind or {}).items() if isinstance(v, str)
        }
        try:
            lib = resolver(ref, base_path)
        except ExpressionTemplateError:
            raise
        except Exception as e:  # noqa: BLE001 — reported with the stable code
            raise ExpressionTemplateError(
                COUPLING_IMPORT_UNRESOLVED,
                f"coupling_import ref '{ref}' failed to load: {e}",
            ) from e
        for raw_edge in _expand_one(lib, ref, bind, esm_file):
            out.append(_parse_coupling_entry(raw_edge))
    return out
