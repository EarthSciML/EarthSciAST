"""The closed-function argument checks (esm-spec §9.2) and the function-table
checks (§9.5.5) on a whole loaded document.

Both sections say WHEN their checks run: during load and in ``validate()``, on
every ``function_tables`` entry whether or not a lookup names it, and on every
``fn`` node naming ``interp.searchsorted`` / ``interp.linear`` /
``interp.bilinear`` wherever it appears (ruling Q-106). A binding MAY repeat
them at build or evaluation but MUST NOT defer them to then. This module is
where the loader (:func:`earthsci_ast.parse.load_document` and friends) and
:func:`earthsci_ast.validation.validate` reach them; the checks themselves are
:func:`~earthsci_ast.registered_functions.check_interp_arguments` and
:func:`~earthsci_ast.lower_table_lookup.check_function_tables` /
:func:`~earthsci_ast.lower_table_lookup.check_table_lookup`, which the
evaluator and the lowering run again.

The walk is over the TYPED document the loader returns, so it sees the tree
after the load-time rewrites: an expression template has been expanded, and a
``fn`` node that came from a template body is checked where the template was
applied, on the arguments the expansion gave it. The template declarations the
loader keeps for round-tripping (``expression_templates``,
``component_templates``) are raw bodies with unbound parameters and are not
walked.

Every field of every component is walked (equations, observed and
initialization equations, reaction rates, events, guesses, parameter updates,
inline-test references, coupling entries, ...), not a list of sites, so a new
expression-bearing field is covered without touching this module.
"""

from __future__ import annotations

import dataclasses
from collections.abc import Iterator
from typing import Any

from .errors import EarthSciAstError
from .esm_types import EsmFile, ExprNode
from .lower_table_lookup import TableLookupError, check_function_tables, check_table_lookup
from .registered_functions import (
    INTERP_CONST_ARG_POSITIONS,
    NOT_CONST,
    ClosedFunctionError,
    check_closed_function_node,
    check_interp_arguments,
)

__all__ = ["check_document", "iter_document_errors"]

#: Top-level fields the walk skips: raw template declarations (unbound
#: parameters; checked where they are applied) and blocks that carry no
#: expressions. ``function_tables`` is checked table by table, not walked.
_SKIP_FILE_FIELDS = frozenset(
    {
        "expression_templates",
        "component_templates",
        "coupling_roles",
        "metaparameters",
        "index_sets",
        "coordinates",
        "enums",
        "function_tables",
    }
)


def _escape(token: Any) -> str:
    return str(token).replace("~", "~0").replace("/", "~1")


def _check_raw_fn(node: dict) -> None:
    """The argument check on a ``fn`` node still in raw-JSON form (a field the
    typed tree keeps as a dict)."""
    name = node.get("name")
    positions = INTERP_CONST_ARG_POSITIONS.get(name if isinstance(name, str) else "")
    args = node.get("args")
    if not positions or not isinstance(args, list):
        return
    from .registered_functions import _CLOSED_FUNCTIONS

    if len(args) != _CLOSED_FUNCTIONS[name].arity:
        return
    values: list[Any] = [None] * len(args)
    for p in positions:
        a = args[p]
        values[p] = a.get("value") if isinstance(a, dict) and a.get("op") == "const" else NOT_CONST
    check_interp_arguments(name, values)


def _iter_expression_errors(
    file: EsmFile,
) -> Iterator[tuple[str, EarthSciAstError]]:
    tables = file.function_tables or {}
    seen: set[int] = set()

    def visit(obj: Any, path: str) -> Iterator[tuple[str, EarthSciAstError]]:
        if obj is None or isinstance(obj, (str, int, float, bool)):
            return
        if isinstance(obj, (ExprNode, dict, list, tuple)) or dataclasses.is_dataclass(obj):
            # The loader aliases some objects (an event lives on its component
            # and in `EsmFile.events`); check each once, at the first path.
            if id(obj) in seen:
                return
            seen.add(id(obj))
        if isinstance(obj, ExprNode):
            try:
                if obj.op == "fn":
                    check_closed_function_node(obj)
                elif obj.op == "table_lookup":
                    check_table_lookup(obj, tables)
            except (ClosedFunctionError, TableLookupError) as e:
                yield path, e
            for f in dataclasses.fields(obj):
                if f.name == "value":
                    continue
                yield from visit(getattr(obj, f.name), f"{path}/{f.name}")
            return
        if isinstance(obj, dict):
            if obj.get("op") == "fn":
                try:
                    _check_raw_fn(obj)
                except ClosedFunctionError as e:
                    yield path, e
            for k, v in obj.items():
                if k == "value" and "op" in obj:
                    continue
                yield from visit(v, f"{path}/{_escape(k)}")
            return
        if isinstance(obj, (list, tuple)):
            for i, v in enumerate(obj):
                yield from visit(v, f"{path}/{i}")
            return
        if dataclasses.is_dataclass(obj):
            for f in dataclasses.fields(obj):
                yield from visit(getattr(obj, f.name), f"{path}/{f.name}")

    for f in dataclasses.fields(file):
        if f.name in _SKIP_FILE_FIELDS:
            continue
        yield from visit(getattr(file, f.name), f"/{f.name}")


def iter_document_errors(file: EsmFile) -> Iterator[tuple[str, EarthSciAstError]]:
    """Every §9.2 closed-function argument failure and §9.5.5 table or lookup
    failure in ``file``, as ``(path, error)``; the error carries the
    diagnostic ``code``. Each table and each node contributes at most one (its
    first code). Tables come first, in declaration order, then the
    expressions. ``path`` is a JSON-Pointer-shaped location: exact for a table
    (``/function_tables/<id>``), and spelled with the typed tree's field names
    for an expression."""
    for table_id, table in (file.function_tables or {}).items():
        try:
            check_function_tables({table_id: table})
        except TableLookupError as e:
            yield f"/function_tables/{_escape(table_id)}", e
    yield from _iter_expression_errors(file)


def check_document(file: EsmFile) -> None:
    """Raise the first error :func:`iter_document_errors` finds. The loader's
    entry point: a document that fails one of these checks does not load."""
    for _path, error in iter_document_errors(file):
        raise error
