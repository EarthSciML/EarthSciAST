"""Version migration for ESM documents (esm-libraries-spec §8.3) and the
esm 2.0.0 codemod.

Two things live here.

**Marker migration** (:func:`migrate`, :func:`can_migrate`,
:func:`supported_migration_targets`) works on a loaded
:class:`~earthsci_ast.esm_types.EsmFile` and only ever changes its ``esm``
field. That is sound along an ADDITIVE line — a run of schema releases each of
which introduced its changes as additive fields, so an older file already loads
under the newer schema. The current additive line is
``2.0.0 … <current schema version>``. A 1.x source is relabelled to the current
version when it uses none of the operators and fields esm 2.0.0 removed;
otherwise :func:`migrate` refuses with a :class:`MigrationError` whose ``code``
is ``removed_op`` and which names the codemod below. A 0.x source has no target
at all: esm 1.0.0 was a clean break that reshaped documents (two variable
types, observed expressions as equations, ``data_sources``), so no marker bump
can carry one forward.

**The codemod** (:func:`migrate_document`, :func:`migrate_text`,
:func:`migrate_path`, and the command line ``python -m earthsci_ast.migrate``)
rewrites a 1.x document's JSON into esm 2.0.0. esm 2.0.0 removed every external
function from the expression AST in favour of the pure-AST templates of the
standard library (``lib/*.esm``, referenced as ``esm:std/<file>.esm``):

=============================================  ==========================================
1.x                                             2.0.0
=============================================  ==========================================
``fn`` ``datetime.<f>(t)``                      ``<f>(t)`` of ``esm:std/calendar.esm``
``fn`` ``interp.searchsorted(x, xs)``           ``searchsorted(x, xs, n)`` of interp.esm
``fn`` ``interp.linear(table, axis, x)``        ``linear(table, axis, x, n)``
``fn`` ``interp.bilinear(t, ax, ay, x, y)``     ``bilinear(t, ax, ay, x, y, nx, ny)``
``function_tables`` + ``table_lookup``          the 1.x table lowering (esm-spec 1.x
                                                §9.5.3), inline, over the interp templates
``polygon_intersection_area`` planar            ``overlap_area_planar`` (geometry.esm)
``polygon_intersection_area`` spherical or      ``overlap_area_spherical`` over a
geodesic                                        ``lonlat_to_unit`` stack the codemod adds
``argmin`` / ``argmax``                         ``argmin`` / ``argmax`` (relational.esm);
                                                ``argmin_where`` / ``argmax_where`` with
                                                a ``join`` or ``filter``
``skolem`` key of a ``distinct`` producer       ``pair_key`` (nested for 3+ components),
                                                ``edge_key`` on request, the bare
                                                component for one
``skolem`` map read only by ``join.on``         one integer column per component
``rank(S)`` over S's own members                the loop index minus one (0-based)
``aggregate`` (the pre-1.1.0 ``faq``)           ``faq``
=============================================  ==========================================

Each replacement adds an ``expression_template_imports`` entry to the component
that holds it (in a template-library file, to the top level), and ``esm``
becomes ``2.0.0``. Every template reproduces its operator's ``binary64`` result,
with these documented exceptions: the overlap templates agree with the geometry
backends within CONFORMANCE_SPEC §5.8.2 rather than bit for bit; ``argmin`` /
``argmax`` return a NaN candidate after the first where the operator skipped
it; and a ``distinct`` set keyed by ``pair_key`` holds integer keys where the
``skolem`` set held tuples (same members, same order).

What has no replacement is refused with :class:`CodemodError`, naming the node:
``intersect_polygon``, any ``fn`` outside ``datetime.*`` / ``interp.*``, a
table declaring ``out_of_bounds: "error"``, a ``polygon_intersection_area``
whose manifold or operands are template parameters, a ``skolem`` or ``rank``
outside the shapes above, and a multi-component ``skolem`` key whose component
ranges the caller has not given (``key_bounds`` / ``--key-bounds``).
"""

from __future__ import annotations

import argparse
import copy
import dataclasses
import json
import re
import sys
from collections import Counter
from dataclasses import dataclass, field, replace
from pathlib import Path
from typing import Any

from .errors import EarthSciAstError
from .esm_types import EsmFile
from .parse import _CURRENT_VERSION, SCHEMA_VERSION

__all__ = [
    "CODEMOD_TARGET_VERSION",
    "CodemodError",
    "CodemodResult",
    "MigrationError",
    "REMOVED_FIELDS",
    "REMOVED_OPS",
    "SCHEMA_VERSION",
    "can_migrate",
    "find_removed",
    "migrate",
    "migrate_document",
    "migrate_path",
    "migrate_text",
    "supported_migration_targets",
]

# The additive line runs from 2.0.0 up to (and including) the current schema
# version. 2.0.0 removed operators, so the 1.x line ended at a break; a 1.x
# source is relabelled only when it uses none of them (see `migrate`).
_ADDITIVE_FLOOR = (2, 0, 0)

_SEMVER_RE = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")

#: The version the codemod writes.
CODEMOD_TARGET_VERSION = "2.0.0"

#: Expression operators esm 2.0.0 removed.
REMOVED_OPS = (
    "fn",
    "table_lookup",
    "skolem",
    "rank",
    "intersect_polygon",
    "polygon_intersection_area",
    "argmin",
    "argmax",
    "aggregate",
)

#: Document fields esm 2.0.0 removed (top level or on a component).
REMOVED_FIELDS = ("function_tables",)

#: The command line, as diagnostics name it.
CODEMOD_COMMAND = "python -m earthsci_ast.migrate"

_CODEMOD_HINT = (
    f"convert the document with the esm 2.0.0 codemod: `{CODEMOD_COMMAND} <file>` "
    f"(earthsci_ast.migration.migrate_document)"
)


class MigrationError(EarthSciAstError):
    """Raised when an ESM document cannot be migrated to the requested version.

    ``code`` is ``"removed_op"`` when :func:`migrate` refuses because the
    document uses an operator or field esm 2.0.0 removed, and ``None`` otherwise.
    """

    def __init__(self, message: str, code: str | None = None) -> None:
        super().__init__(message)
        self.code = code


class CodemodError(MigrationError):
    """Raised by the codemod for a construct it cannot rewrite. ``path`` is the
    slash-separated location of the node in the document."""

    def __init__(self, message: str, path: str = "") -> None:
        super().__init__(f"{path}: {message}" if path else message)
        self.path = path


# ---------------------------------------------------------------------------
# Marker migration
# ---------------------------------------------------------------------------


def _parse_version(version: Any) -> tuple[int, int, int] | None:
    """Parse ``major.minor.patch``; ``None`` for anything else."""
    if not isinstance(version, str):
        return None
    match = _SEMVER_RE.match(version)
    if match is None:
        return None
    return (int(match.group(1)), int(match.group(2)), int(match.group(3)))


def _on_additive_line(version: tuple[int, int, int]) -> bool:
    """True when ``version`` can be carried to the current schema by a no-op bump."""
    current = _CURRENT_VERSION
    return version[0] == current[0] and _ADDITIVE_FLOOR <= version <= current


def _relabel_line(version: tuple[int, int, int]) -> bool:
    """True for a 1.x source the current 2.x schema relabels when it uses none of
    the removed operators."""
    return version[0] == 1 and _CURRENT_VERSION[0] == 2


def supported_migration_targets(from_version: str) -> list[str]:
    """The schema versions ``from_version`` can migrate to.

    * a version on the additive line ``2.0.0 … <current>``, or a 1.x version →
      ``[SCHEMA_VERSION]`` (a 1.x source only when it uses none of the removed
      operators, which :func:`migrate` checks);
    * everything else — every 0.x version included — → ``[]``.
    """
    parsed = _parse_version(from_version)
    if parsed is not None and (_on_additive_line(parsed) or _relabel_line(parsed)):
        return [SCHEMA_VERSION]
    return []


def can_migrate(from_version: str, to_version: str) -> bool:
    """True when :func:`migrate` could succeed for this version pair (a 1.x
    source still fails when it uses a removed operator)."""
    return to_version in supported_migration_targets(from_version)


def _removed_uses(obj: Any, path: str, out: list[tuple[str, str]], seen: set[int]) -> None:
    """Collect ``(path, name)`` for every removed operator, and every non-empty
    removed field, reachable from a JSON document or a loaded document object."""
    if id(obj) in seen:
        return
    if dataclasses.is_dataclass(obj) and not isinstance(obj, type):
        seen.add(id(obj))
        op = getattr(obj, "op", None)
        if isinstance(op, str) and op in REMOVED_OPS:
            out.append((path, op))
        for f in dataclasses.fields(obj):
            value = getattr(obj, f.name, None)
            if f.name in REMOVED_FIELDS and value:
                out.append((f"{path}/{f.name}", f.name))
                continue
            _removed_uses(value, f"{path}/{f.name}", out, seen)
    elif isinstance(obj, dict):
        seen.add(id(obj))
        op = obj.get("op")
        if isinstance(op, str) and op in REMOVED_OPS:
            out.append((path, op))
        for k, v in obj.items():
            if k in REMOVED_FIELDS and v:
                out.append((f"{path}/{k}", str(k)))
                continue
            _removed_uses(v, f"{path}/{k}", out, seen)
    elif isinstance(obj, (list, tuple)):
        seen.add(id(obj))
        for i, v in enumerate(obj):
            _removed_uses(v, f"{path}/{i}", out, seen)


def find_removed(doc: Any) -> list[tuple[str, str]]:
    """Every removed operator or field in a document (parsed JSON or a loaded
    :class:`~earthsci_ast.esm_types.EsmFile`), as ``(path, name)``."""
    out: list[tuple[str, str]] = []
    _removed_uses(doc, "", out, set())
    return out


def migrate(file: EsmFile, target_version: str) -> EsmFile:
    """Migrate ``file`` to ``target_version`` by relabelling its ``esm`` field.

    Supported: an additive-line source (``2.0.0 … <current>``) to the current
    version, and a 1.x source to the current version when it uses none of the
    operators or fields esm 2.0.0 removed. A 1.x source that uses one is refused
    with ``code == "removed_op"``, naming the first use and the codemod. Every
    other pair raises :class:`MigrationError`. The input is never mutated: a
    shallow copy carrying the new marker is returned.
    """
    source_version = getattr(file, "version", None)
    if not source_version:
        raise MigrationError("Source file has no 'esm' version field")

    if not can_migrate(source_version, target_version):
        raise MigrationError(
            f"Migration from {source_version} to {target_version} is not supported"
        )

    parsed = _parse_version(source_version)
    if parsed is not None and parsed[0] == 1:
        uses = find_removed(file)
        if uses:
            where, name = uses[0]
            raise MigrationError(
                f"removed_op: `{name}` at {where or '/'} was removed at esm 2.0.0, so this "
                f"{source_version} document cannot be relabelled; {_CODEMOD_HINT}",
                code="removed_op",
            )

    return replace(file, version=target_version)


# ---------------------------------------------------------------------------
# The codemod
# ---------------------------------------------------------------------------

_STD_REF = {
    "interp": "esm:std/interp.esm",
    "calendar": "esm:std/calendar.esm",
    "geometry": "esm:std/geometry.esm",
    "relational": "esm:std/relational.esm",
}

_DATETIME = frozenset(
    {
        "year",
        "month",
        "day",
        "hour",
        "minute",
        "second",
        "day_of_year",
        "julian_day",
        "is_leap_year",
    }
)

_UNIT_INDEX_SET = "unit_xyz"

# Why a removed operator the walk left in place has no rewrite there.
_LEFTOVER = {
    "rank": (
        "`rank` has a template form only as the body of a `faq` whose one output symbol ranges "
        "over the ranked set (the loop index minus one); elsewhere use `rank_of_set` of "
        "esm:std/relational.esm by hand"
    ),
    "skolem": (
        "`skolem` has a template form only as the `key` of a `distinct` producer or as the body "
        "of a map read only by `join.on`"
    ),
    "argmin": "a joined `argmin` has a template form only as the body of a `faq` with one output symbol",
    "argmax": "a joined `argmax` has a template form only as the body of a `faq` with one output symbol",
}


@dataclass
class CodemodResult:
    """A converted document and what the codemod did to it."""

    document: dict
    #: One line per rewrite, in document order: ``<path>: <what>``.
    notes: list[str] = field(default_factory=list)
    #: Rewrites by kind (``fn datetime.hour``, ``table_lookup``, ...).
    counts: dict[str, int] = field(default_factory=dict)

    @property
    def changed(self) -> bool:
        return bool(self.counts)


def _op(o: str, *args: Any) -> dict:
    return {"op": o, "args": list(args)}


def _apply(name: str, bindings: dict) -> dict:
    return {"op": "apply_expression_template", "args": [], "name": name, "bindings": bindings}


def _const(value: Any) -> dict:
    return {"op": "const", "args": [], "value": value}


def _is_node(x: Any) -> bool:
    return isinstance(x, dict) and isinstance(x.get("op"), str)


def _rename_symbol(expr: Any, old: str, new: Any) -> Any:
    """Replace every bare-name occurrence of ``old`` by ``new`` (a copy each)."""
    if isinstance(expr, str):
        return copy.deepcopy(new) if expr == old else expr
    if isinstance(expr, list):
        return [_rename_symbol(e, old, new) for e in expr]
    if isinstance(expr, dict):
        return {k: _rename_symbol(v, old, new) for k, v in expr.items()}
    return expr


def _const_len(arg: Any, what: str, path: str) -> int:
    if _is_node(arg) and arg["op"] == "const" and isinstance(arg.get("value"), list):
        return len(arg["value"])
    raise CodemodError(f"{what} must be a `const` array, whose length the template takes", path)


@dataclass
class _Scope:
    """A component, or a template-library file's top level, that receives imports."""

    path: str
    node: dict
    variables: dict
    local_templates: set
    tables: dict
    imports: dict = field(default_factory=dict)  # std file -> ordered names
    visible: dict = field(default_factory=dict)  # (file, name) -> name the scope sees
    new_variables: dict = field(default_factory=dict)
    new_equations: list = field(default_factory=list)
    unit_stacks: dict = field(default_factory=dict)  # ring variable -> unit-vector stack
    split: dict = field(default_factory=dict)  # skolem join key -> its components

    def use(self, file: str, name: str) -> str:
        names = self.imports.setdefault(file, [])
        if name not in names:
            names.append(name)
        key = (file, name)
        if key not in self.visible:
            seen = name
            if name in self.local_templates:
                seen = f"std_{file}_{name}"
                while seen in self.local_templates:
                    seen += "_"
            self.visible[key] = seen
        return self.visible[key]


class _Codemod:
    def __init__(self, doc: dict, key_bounds: dict | None) -> None:
        self.doc = doc
        self.key_bounds = dict(key_bounds or {})
        self.index_sets = doc.get("index_sets") if isinstance(doc.get("index_sets"), dict) else {}
        self.top_tables = doc.get("function_tables") or {}
        self.notes: list[str] = []
        self.counts: dict[str, int] = {}
        self.used_bounds: set[str] = set()

    def _count(self, kind: str, path: str, what: str) -> None:
        self.counts[kind] = self.counts.get(kind, 0) + 1
        self.notes.append(f"{path}: {what}")

    def _index_set_size(self, name: Any, path: str) -> int:
        spec = self.index_sets.get(name) if isinstance(name, str) else None
        size = spec.get("size") if isinstance(spec, dict) else None
        if isinstance(size, int) and not isinstance(size, bool):
            return size
        raise CodemodError(
            f"index set `{name}` has no literal integer size, which the template takes as a "
            f"`ranges` bound",
            path,
        )

    # -- driver -------------------------------------------------------------

    def run(self) -> None:
        doc = self.doc
        self._rename_aggregate(doc, "")
        for section in ("models", "reaction_systems"):
            comps = doc.get(section)
            if not isinstance(comps, dict):
                continue
            for cname, comp in comps.items():
                if not isinstance(comp, dict):
                    continue
                path = f"/{section}/{cname}"
                variables = comp.get("variables")
                scope = _Scope(
                    path=path,
                    node=comp,
                    variables=variables if isinstance(variables, dict) else {},
                    local_templates=set((comp.get("expression_templates") or {}).keys()),
                    tables={**self.top_tables, **(comp.get("function_tables") or {})},
                )
                self._split_join_keys(scope)
                for key in list(comp.keys()):
                    if key != "function_tables":
                        comp[key] = self._walk(comp[key], scope, f"{path}/{key}")
                self._finish_scope(scope)
                if "function_tables" in comp:
                    del comp["function_tables"]
                    self._count(
                        "function_tables", path, "removed the component's `function_tables`"
                    )
        if isinstance(doc.get("expression_templates"), dict):
            scope = _Scope(
                path="",
                node=doc,
                variables={},
                local_templates=set(doc["expression_templates"].keys()),
                tables=dict(self.top_tables),
            )
            doc["expression_templates"] = self._walk(
                doc["expression_templates"], scope, "/expression_templates"
            )
            self._finish_scope(scope)
        if "function_tables" in doc:
            del doc["function_tables"]
            self._count("function_tables", "", "removed the top-level `function_tables`")
        unused = set(self.key_bounds) - self.used_bounds - {"*"}
        if unused:
            raise CodemodError(
                f"key bounds were given for {sorted(unused)}, which name no `distinct` producer "
                f"with a multi-component `skolem` key"
            )
        left = find_removed(doc)
        if left:
            where, name = left[0]
            raise CodemodError(
                _LEFTOVER.get(name, f"`{name}` has no rewrite in this position"), where
            )
        doc["esm"] = CODEMOD_TARGET_VERSION

    def _rename_aggregate(self, x: Any, path: str) -> None:
        """``aggregate``, the pre-1.1.0 spelling of ``faq``, is removed at 2.0.0."""
        if isinstance(x, dict):
            if x.get("op") == "aggregate":
                x["op"] = "faq"
                self._count("aggregate", path, "`aggregate` -> `faq`")
            for k, v in x.items():
                self._rename_aggregate(v, f"{path}/{k}")
        elif isinstance(x, list):
            for i, v in enumerate(x):
                self._rename_aggregate(v, f"{path}/{i}")

    def _finish_scope(self, scope: _Scope) -> None:
        comp = scope.node
        if scope.new_variables:
            comp.setdefault("variables", {}).update(scope.new_variables)
        if scope.new_equations:
            comp.setdefault("equations", []).extend(scope.new_equations)
        if not scope.imports:
            return
        imports = comp.get("expression_template_imports") or []
        for file, names in scope.imports.items():
            ref = _STD_REF[file]
            renames = {n: scope.visible[(file, n)] for n in names if scope.visible[(file, n)] != n}
            plain = next(
                (
                    e
                    for e in imports
                    if isinstance(e, dict)
                    and e.get("ref") == ref
                    and not any(k in e for k in ("prefix", "rename", "rebind", "bindings"))
                ),
                None,
            )
            if plain is not None and not renames:
                if "only" in plain:
                    plain["only"] += [n for n in names if n not in plain["only"]]
                continue
            entry: dict = {"ref": ref, "only": list(names)}
            if renames:
                entry["rename"] = renames
            imports.append(entry)
        if scope.path == "":
            comp["expression_template_imports"] = imports
            return
        # A component's imports lead it, where EarthSciModels#46 and the
        # phase-3 rewrites put them.
        rest = {k: v for k, v in comp.items() if k != "expression_template_imports"}
        comp.clear()
        comp["expression_template_imports"] = imports
        comp.update(rest)

    # -- generic walk -------------------------------------------------------

    def _walk(self, x: Any, scope: _Scope, path: str) -> Any:
        if isinstance(x, list):
            return [self._walk(v, scope, f"{path}/{i}") for i, v in enumerate(x)]
        if not isinstance(x, dict):
            return x
        out = {k: self._walk(v, scope, f"{path}/{k}") for k, v in x.items()}
        if not _is_node(out):
            return out
        op = out["op"]
        if op == "fn":
            return self._fn(out, scope, path)
        if op == "table_lookup":
            return self._table_lookup(out, scope, path)
        if op == "polygon_intersection_area":
            return self._overlap(out, scope, path)
        if op == "intersect_polygon":
            raise CodemodError(
                "`intersect_polygon` has no esm 2.0.0 replacement: the overlap ring is not "
                "expressible as a template. Where only its area is used, write "
                "`overlap_area_planar` / `overlap_area_spherical` of esm:std/geometry.esm by hand",
                path,
            )
        if op in ("argmin", "argmax") and "join" not in out:
            return self._argwitness(out, scope, path)
        if op == "faq":
            return self._faq(out, scope, path)
        return out

    # -- fn -----------------------------------------------------------------

    def _fn(self, node: dict, scope: _Scope, path: str) -> dict:
        name = node.get("name")
        args = node.get("args") or []

        def arity(k: int) -> None:
            if len(args) != k:
                raise CodemodError(f"`{name}` takes {k} argument(s), got {len(args)}", path)

        if isinstance(name, str) and name.startswith("datetime.") and name[9:] in _DATETIME:
            arity(1)
            self._count(f"fn {name}", path, f"`fn {name}` -> calendar `{name[9:]}`")
            return _apply(scope.use("calendar", name[9:]), {"t": args[0]})
        if name == "interp.searchsorted":
            arity(2)
            n = _const_len(args[1], "interp.searchsorted's axis", path)
            self._count(f"fn {name}", path, f"`fn {name}` -> interp `searchsorted`")
            return _apply(
                scope.use("interp", "searchsorted"), {"x": args[0], "xs": args[1], "n": n}
            )
        if name == "interp.linear":
            arity(3)
            n = _const_len(args[1], "interp.linear's axis", path)
            self._count(f"fn {name}", path, f"`fn {name}` -> interp `linear`")
            return _apply(
                scope.use("interp", "linear"),
                {"table": args[0], "axis": args[1], "x": args[2], "n": n},
            )
        if name == "interp.bilinear":
            arity(5)
            nx = _const_len(args[1], "interp.bilinear's axis_x", path)
            ny = _const_len(args[2], "interp.bilinear's axis_y", path)
            self._count(f"fn {name}", path, f"`fn {name}` -> interp `bilinear`")
            return _apply(
                scope.use("interp", "bilinear"),
                {
                    "table": args[0],
                    "axis_x": args[1],
                    "axis_y": args[2],
                    "x": args[3],
                    "y": args[4],
                    "nx": nx,
                    "ny": ny,
                },
            )
        raise CodemodError(
            f"`fn` `{name}` has no esm 2.0.0 replacement: only "
            f"{', '.join('datetime.' + n for n in sorted(_DATETIME))}, interp.searchsorted, "
            f"interp.linear and interp.bilinear have standard-library templates",
            path,
        )

    # -- table_lookup -------------------------------------------------------

    def _table_lookup(self, node: dict, scope: _Scope, path: str) -> Any:
        tid = node.get("table")
        table = scope.tables.get(tid)
        if not isinstance(table, dict):
            raise CodemodError(f"`table_lookup` names unknown table `{tid}`", path)
        if node.get("args"):
            raise CodemodError("`table_lookup` carries non-empty `args`", path)
        if table.get("out_of_bounds", "clamp") != "clamp":
            raise CodemodError(
                f"table `{tid}` declares out_of_bounds {table.get('out_of_bounds')!r}; only "
                f"`clamp` has a template form",
                path,
            )
        axes = table.get("axes") or []
        names = [a.get("name") for a in axes]
        supplied = node.get("axes") or {}
        if set(supplied) != set(names):
            raise CodemodError(
                f"`table_lookup` axes {sorted(supplied)} do not match table `{tid}` axes {names}",
                path,
            )
        data, outputs, out = table.get("data"), table.get("outputs"), node.get("output", 0)
        if outputs is not None:
            if isinstance(out, str):
                if out not in outputs:
                    raise CodemodError(f"table `{tid}` has no output `{out}`", path)
                out = outputs.index(out)
            if not isinstance(out, int) or isinstance(out, bool) or not 0 <= out < len(outputs):
                raise CodemodError(f"table `{tid}` has no output {out!r}", path)
            d = data[out]
        else:
            if out != 0:
                raise CodemodError(f"single-output table `{tid}` read with output {out!r}", path)
            d = data
        interp = table.get("interpolation", "linear")
        inputs = [supplied[n] for n in names]
        values = [list(a.get("values")) for a in axes]
        if interp == "nearest" and len(axes) == 1:
            self._count("table_lookup", path, f"`table_lookup` of `{tid}` (nearest) -> §9.5.3 tree")
            return self._nearest(d, values[0], inputs[0], scope)
        if interp == "linear" and len(axes) == 1:
            fn = {
                "op": "fn",
                "name": "interp.linear",
                "args": [_const(copy.deepcopy(d)), _const(values[0]), inputs[0]],
            }
        elif interp == "bilinear" and len(axes) == 2:
            fn = {
                "op": "fn",
                "name": "interp.bilinear",
                "args": [
                    _const(copy.deepcopy(d)),
                    _const(values[0]),
                    _const(values[1]),
                    inputs[0],
                    inputs[1],
                ],
            }
        else:
            raise CodemodError(
                f"table `{tid}` has interpolation `{interp}` with {len(axes)} axes", path
            )
        self._count("table_lookup", path, f"`table_lookup` of `{tid}` ({interp})")
        # §9.5.3: the lookup IS the inline `fn` call; convert that.
        return self._fn(fn, scope, path)

    def _nearest(self, data: Any, axis: list, x: Any, scope: _Scope) -> dict:
        """The §9.5.3 ``nearest`` tree, node for node, with the ``searchsorted``
        template in place of ``interp.searchsorted``."""
        n = len(axis)
        name = scope.use("interp", "searchsorted")

        def xq():
            return copy.deepcopy(x)

        def a():
            return _const(list(axis))

        def j():
            return _apply(name, {"x": xq(), "xs": a(), "n": n})

        def lo():
            return _op("max", _op("-", j(), 1), 1)

        def hi():
            return _op("min", j(), n)

        upper = _op("-", _op("index", a(), hi()), xq())
        lower = _op("-", xq(), _op("index", a(), lo()))
        knot = _op("ifelse", _op("<", upper, lower), hi(), lo())
        return _op(
            "ifelse", _op("==", xq(), xq()), _op("index", _const(copy.deepcopy(data)), knot), xq()
        )

    # -- geometry -----------------------------------------------------------

    def _ring_operand(self, arg: Any, scope: _Scope, path: str) -> tuple[str, Any, list]:
        """``(ring stack, cell, stack shape)`` of an operand: ``index(stack, cell)``
        of a [cells, verts, 2] variable, or a bare [verts, 2] variable, which gets
        a one-cell stack."""
        if isinstance(arg, str):
            shape = self._shape_of(arg, scope)
            if isinstance(shape, list) and len(shape) == 2:
                return self._one_cell_stack(arg, shape, scope), 1, None
        elif (
            _is_node(arg)
            and arg["op"] == "index"
            and len(arg.get("args") or []) == 2
            and isinstance(arg["args"][0], str)
        ):
            ring, cell = arg["args"]
            shape = self._shape_of(ring, scope)
            if isinstance(shape, list) and len(shape) == 3:
                return ring, cell, shape
        raise CodemodError(
            "a `polygon_intersection_area` operand must be `index(stack, cell)` of a "
            "[cells, verts, 2] variable or a bare [verts, 2] variable of this component, so the "
            "codemod knows its vertex-slot count (in a template body, pass the ring stacks and "
            "the count as template parameters by hand)",
            path,
        )

    @staticmethod
    def _shape_of(name: str, scope: _Scope) -> Any:
        decl = scope.variables.get(name, scope.new_variables.get(name))
        return decl.get("shape") if isinstance(decl, dict) else None

    def _fresh_index_set(self, base: str, spec: dict) -> str:
        name = base
        while name in self.index_sets and self.index_sets[name] != spec:
            name += "_"
        if name not in self.index_sets:
            self.index_sets[name] = dict(spec)
            self.doc["index_sets"] = self.index_sets
        return name

    def _fresh_variable(self, base: str, scope: _Scope) -> str:
        name = base
        while name in scope.variables or name in scope.new_variables:
            name += "_"
        return name

    def _one_cell_stack(self, ring: str, shape: list, scope: _Scope) -> str:
        key = ("stack", ring)
        if key in scope.unit_stacks:
            return scope.unit_stacks[key]
        one = self._fresh_index_set("one_cell", {"kind": "interval", "size": 1})
        name = self._fresh_variable(f"{ring}_stack", scope)
        scope.new_variables[name] = {
            "type": "unknown",
            "shape": [one, shape[0], shape[1]],
            "description": (
                f"The ring `{ring}` as a one-cell ring stack, the operand form of the "
                f"esm:std/geometry.esm overlap templates (written by the esm 2.0.0 codemod)."
            ),
        }
        scope.new_equations.append(
            {
                "lhs": name,
                "rhs": {
                    "op": "faq",
                    "args": [],
                    "output_idx": ["c", "v", "d"],
                    "ranges": {
                        "c": {"from": one},
                        "v": {"from": shape[0]},
                        "d": {"from": shape[1]},
                    },
                    "expr": _op("index", ring, "v", "d"),
                },
            }
        )
        scope.unit_stacks[key] = name
        return name

    def _overlap(self, node: dict, scope: _Scope, path: str) -> dict:
        manifold = node.get("manifold")
        args = node.get("args") or []
        if len(args) != 2:
            raise CodemodError("`polygon_intersection_area` takes 2 operands", path)
        if manifold not in ("planar", "spherical", "geodesic"):
            raise CodemodError(
                f"`polygon_intersection_area` manifold {manifold!r} is not a literal planar, "
                f"spherical or geodesic, so the codemod cannot choose between "
                f"overlap_area_planar and overlap_area_spherical",
                path,
            )
        (ra, ca, sa), (rb, cb, sb) = (self._ring_operand(a, scope, path) for a in args)
        sa, sb = self._shape_of(ra, scope), self._shape_of(rb, scope)
        nva = self._index_set_size(sa[1], path)
        nvb = self._index_set_size(sb[1], path)
        if manifold == "planar":
            self._count(
                "polygon_intersection_area planar", path, "planar overlap -> `overlap_area_planar`"
            )
            ra_, rb_, name = ra, rb, "overlap_area_planar"
        else:
            ra_ = self._unit_stack(ra, sa, scope)
            rb_ = self._unit_stack(rb, sb, scope)
            name = "overlap_area_spherical"
            self._count(
                f"polygon_intersection_area {manifold}", path, f"{manifold} overlap -> `{name}`"
            )
        return _apply(
            scope.use("geometry", name),
            {"ring_a": ra_, "cell_a": ca, "nv_a": nva, "ring_b": rb_, "cell_b": cb, "nv_b": nvb},
        )

    def _unit_stack(self, ring: str, shape: list, scope: _Scope) -> str:
        if ring in scope.unit_stacks:
            return scope.unit_stacks[ring]
        xyz = self._fresh_index_set(_UNIT_INDEX_SET, {"kind": "interval", "size": 3})
        name = self._fresh_variable(f"{ring}_unit", scope)
        scope.new_variables[name] = {
            "type": "unknown",
            "shape": [shape[0], shape[1], xyz],
            "description": (
                f"Unit vectors (x, y, z) of the lon-lat ring stack `{ring}`, the operand of "
                f"`overlap_area_spherical` (written by the esm 2.0.0 codemod)."
            ),
        }
        scope.new_equations.append(
            {
                "lhs": name,
                "rhs": {
                    "op": "faq",
                    "args": [],
                    "output_idx": ["c", "v", "d"],
                    "ranges": {
                        "c": {"from": shape[0]},
                        "v": {"from": shape[1]},
                        "d": {"from": xyz},
                    },
                    "expr": _apply(
                        scope.use("geometry", "lonlat_to_unit"),
                        {"ring": ring, "cell": "c", "vert": "v", "comp": "d"},
                    ),
                },
            }
        )
        scope.unit_stacks[ring] = name
        return name

    # -- relational ---------------------------------------------------------

    def _candidates(self, node: dict, path: str) -> tuple[str, int, int]:
        sym = node.get("arg")
        ranges = node.get("ranges") or {}
        if not isinstance(sym, str) or list(ranges) != [sym]:
            raise CodemodError(f"`{node['op']}` must range over exactly its `arg` symbol", path)
        spec = ranges[sym]
        if isinstance(spec, dict) and set(spec) == {"from"}:
            return sym, 1, self._index_set_size(spec["from"], path)
        if isinstance(spec, list) and len(spec) == 2 and all(isinstance(v, int) for v in spec):
            return sym, spec[0], spec[1] - spec[0] + 1
        raise CodemodError(f"`{node['op']}` range {spec!r} has no literal candidate count", path)

    def _argwitness(self, node: dict, scope: _Scope, path: str) -> Any:
        o = node["op"]
        sym, lo, n = self._candidates(node, path)
        if "filter" in node:
            k = f"k_{o}_where_1"
            repl: Any = k if lo == 1 else _op("+", k, lo - 1)
            call = _apply(
                scope.use("relational", f"{o}_where"),
                {
                    "f": _rename_symbol(node.get("expr"), sym, repl),
                    "p": _rename_symbol(node["filter"], sym, repl),
                    "n": n,
                },
            )
        else:
            k = f"k_{o}_1"
            repl = k if lo == 1 else _op("+", k, lo - 1)
            call = _apply(
                scope.use("relational", o),
                {"f": _rename_symbol(node.get("expr"), sym, repl), "n": n},
            )
        self._count(o, path, f"`{o}` -> `{call['name']}`")
        return call if lo == 1 else _op("+", call, lo - 1)

    def _split_join_keys(self, scope: _Scope) -> None:
        """Split each multi-component ``skolem`` map read only by ``join.on`` into
        one integer column per component (``<name>_c1``, ``<name>_c2``, ...)."""
        comp = scope.node
        eqs = comp.get("equations")
        if not isinstance(eqs, list):
            return
        split: dict[str, list] = {}
        for eq in eqs:
            lhs, rhs = eq.get("lhs"), eq.get("rhs")
            if (
                _is_node(rhs)
                and rhs["op"] == "faq"
                and not rhs.get("distinct")
                and _is_node(rhs.get("expr"))
                and rhs["expr"]["op"] == "skolem"
                and _is_node(lhs)
                and lhs["op"] == "index"
            ):
                split[lhs["args"][0]] = rhs["expr"]["args"]
        if not split:
            return
        for name in split:
            uses = self._non_join_uses(comp, name)
            if uses:
                raise CodemodError(
                    f"the `skolem` key `{name}` is read outside `join.on` (at {scope.path}{uses[0]}); "
                    f"only a key read as a join column has a template form",
                    f"{scope.path}/equations",
                )
        new_eqs = []
        for i, eq in enumerate(eqs):
            lhs = eq.get("lhs")
            name = lhs["args"][0] if _is_node(lhs) and lhs["op"] == "index" else None
            if (
                name in split
                and eq["rhs"].get("op") == "faq"
                and eq["rhs"]["expr"].get("op") == "skolem"
            ):
                for c, comp_expr in enumerate(split[name], 1):
                    e2 = copy.deepcopy(eq)
                    e2["lhs"]["args"][0] = f"{name}_c{c}"
                    e2["rhs"]["expr"] = copy.deepcopy(comp_expr)
                    e2["rhs"]["args"] = []
                    e2["_comment"] = (
                        f"Component {c} of the former `skolem` key `{name}`: an integer join column."
                    )
                    new_eqs.append(e2)
                self._count(
                    "skolem join key",
                    f"{scope.path}/equations/{i}",
                    f"`skolem` key `{name}` -> {len(split[name])} integer join columns",
                )
            else:
                new_eqs.append(eq)
        comp["equations"] = new_eqs
        variables = comp.setdefault("variables", {})
        for name, comps in split.items():
            decl = variables.pop(name, {"type": "unknown"})
            for c in range(1, len(comps) + 1):
                d = copy.deepcopy(decl)
                d["description"] = (
                    f"Component {c} of the key formerly `{name}` (an integer join column)."
                )
                variables[f"{name}_c{c}"] = d
        scope.variables = variables
        scope.split = split

    @staticmethod
    def _non_join_uses(comp: dict, name: str) -> list[str]:
        """Where ``name`` is read other than as a ``join.on`` column, its own
        definition or a ``faq`` dependency list."""
        out: list[str] = []

        def walk(x: Any, path: str) -> None:
            if isinstance(x, str):
                if x == name:
                    out.append(path)
            elif isinstance(x, list):
                for i, v in enumerate(x):
                    walk(v, f"{path}/{i}")
            elif isinstance(x, dict):
                for k, v in x.items():
                    if k in ("on", "_comment", "description"):
                        continue
                    if k == "args" and x.get("op") == "faq":
                        continue
                    if k == "lhs" and _is_node(v) and v["op"] == "index" and v["args"][0] == name:
                        continue
                    walk(v, f"{path}/{k}")

        walk({k: v for k, v in comp.items() if k != "variables"}, "")
        return out

    def _faq(self, node: dict, scope: _Scope, path: str) -> dict:
        split = scope.split
        if split:
            if "join" in node:
                node["join"] = self._split_on(node["join"], split, path)
            if isinstance(node.get("args"), list):
                node["args"] = [a for a in node["args"] if a not in split] + [
                    f"{a}_c{c}"
                    for a in node["args"]
                    if a in split
                    for c in range(1, len(split[a]) + 1)
                ]
        key = node.get("key")
        if _is_node(key) and key["op"] == "skolem":
            node["key"] = self._key(key, node, scope, path)
        expr = node.get("expr")
        if _is_node(expr) and expr["op"] == "rank":
            node["expr"] = self._rank(expr, node, path)
        elif _is_node(expr) and expr["op"] in ("argmin", "argmax") and "join" in expr:
            node["expr"] = self._joined_argwitness(expr, node, scope, path)
        return node

    @staticmethod
    def _split_on(join: list, split: dict, path: str) -> list:
        out = []
        for clause in join:
            if isinstance(clause, dict) and "on" in clause:
                pairs = []
                for a, b in clause["on"]:
                    if a in split and b in split:
                        if len(split[a]) != len(split[b]):
                            raise CodemodError(
                                f"join keys `{a}` and `{b}` have different component counts", path
                            )
                        pairs += [[f"{a}_c{c}", f"{b}_c{c}"] for c in range(1, len(split[a]) + 1)]
                    elif a in split or b in split:
                        raise CodemodError(
                            f"join pair [{a}, {b}] mixes a `skolem` key and a plain column", path
                        )
                    else:
                        pairs.append([a, b])
                clause = {**clause, "on": pairs}
            out.append(clause)
        return out

    def _key(self, key: dict, faq: dict, scope: _Scope, path: str) -> Any:
        comps = key.get("args") or []
        fid = faq.get("id")
        if len(comps) == 1:
            self._count(
                "skolem key", path, f"one-component `skolem` key of `{fid}` -> the component"
            )
            return comps[0]
        spec = self.key_bounds.get(fid) if fid is not None else None
        if spec is None:
            spec = self.key_bounds.get("*")
        else:
            self.used_bounds.add(fid)
        if spec is None:
            raise CodemodError(
                f"the {len(comps)}-component `skolem` key of `distinct` producer `{fid}` becomes a "
                f"`pair_key`, which needs each component's integer range [lo, lo + n); give it as "
                f"key_bounds={{{fid!r}: {{'kind': 'pair', 'lo': [...], 'n': [...]}}}} "
                f"(command line: --key-bounds {fid}=pair:LO:N,LO:N)",
                path,
            )
        kind, lo, n = spec.get("kind", "pair"), spec.get("lo"), spec.get("n")
        if kind == "edge":
            if len(comps) != 2 or not isinstance(lo, int) or not isinstance(n, int):
                raise CodemodError(
                    f"an `edge` key for `{fid}` needs two components and one lo and n", path
                )
            self._count("skolem key", path, f"`skolem` key of `{fid}` -> `edge_key`")
            return _apply(
                scope.use("relational", "edge_key"),
                {"u": comps[0], "v": comps[1], "lo": lo, "n": n},
            )
        if (
            kind != "pair"
            or not isinstance(lo, list)
            or not isinstance(n, list)
            or len(lo) != len(comps)
            or len(n) != len(comps)
        ):
            raise CodemodError(
                f"key bounds for `{fid}` must give one lo and one n per component ({len(comps)})",
                path,
            )
        total = 1
        for v in n:
            total *= v
        if total > 2**53:
            raise CodemodError(
                f"key bounds for `{fid}` span {total} keys, more than 2^53 (not exact in binary64)",
                path,
            )
        name = scope.use("relational", "pair_key")
        acc, lo_acc, n_acc = comps[0], lo[0], n[0]
        for c, lo_c, n_c in zip(comps[1:], lo[1:], n[1:]):
            acc = _apply(
                name, {"a": acc, "b": c, "lo_a": lo_acc, "lo_b": lo_c, "n_a": n_acc, "n_b": n_c}
            )
            lo_acc, n_acc = 0, n_acc * n_c
        self._count("skolem key", path, f"`skolem` key of `{fid}` -> `pair_key`")
        return acc

    def _rank(self, expr: dict, faq: dict, path: str) -> Any:
        args = expr.get("args") or []
        out_idx = faq.get("output_idx") or []
        ranges = faq.get("ranges") or {}
        if (
            len(args) == 1
            and isinstance(args[0], str)
            and len(out_idx) == 1
            and list(ranges) == [out_idx[0]]
            and ranges[out_idx[0]] == {"from": args[0]}
        ):
            sym = out_idx[0]
            self._count("rank", path, f"`rank({args[0]})` over its own members -> `{sym} - 1`")
            return _op("-", sym, 1)
        raise CodemodError(_LEFTOVER["rank"], path)

    def _joined_argwitness(self, node: dict, faq: dict, scope: _Scope, path: str) -> dict:
        o = node["op"]
        out_idx = faq.get("output_idx") or []
        if len(out_idx) != 1:
            raise CodemodError(
                f"a joined `{o}` must be the body of a `faq` with one output symbol", path
            )
        outer = out_idx[0]
        outer_range = (faq.get("ranges") or {}).get(outer)
        outer_set = outer_range.get("from") if isinstance(outer_range, dict) else None
        sym, lo, n = self._candidates(node, path)
        if lo != 1:
            raise CodemodError(f"a joined `{o}` needs a candidate range starting at 1", path)
        ks = f"k_{o}_where_1"
        col_set = {}
        for v, decl in scope.variables.items():
            shp = decl.get("shape") if isinstance(decl, dict) else None
            col_set[v] = shp[0] if isinstance(shp, list) and len(shp) == 1 else None
        conds = []
        for clause in self._split_on(node["join"], scope.split, path):
            if not isinstance(clause, dict) or set(clause) != {"on"}:
                raise CodemodError(
                    f"a joined `{o}` has a template form only for `on` clauses", path
                )
            for a, b in clause["on"]:
                if col_set.get(a) == outer_set:
                    conds.append(_op("==", _op("index", a, outer), _op("index", b, ks)))
                elif col_set.get(b) == outer_set:
                    conds.append(_op("==", _op("index", b, outer), _op("index", a, ks)))
                else:
                    raise CodemodError(
                        f"neither join column `{a}` nor `{b}` is shaped over `{outer_set}`", path
                    )
        if "filter" in node:
            conds.append(_rename_symbol(node["filter"], sym, ks))
        p = conds[0]
        for c in conds[1:]:
            p = _op("and", p, c)
        call = _apply(
            scope.use("relational", f"{o}_where"),
            {"f": _rename_symbol(node.get("expr"), sym, ks), "p": p, "n": n},
        )
        if isinstance(faq.get("args"), list):
            faq["args"] = [a for a in faq["args"] if a in scope.variables]
        self._count(o, path, f"joined `{o}` -> `{o}_where`")
        return call


def _shape_rank_outputs(doc: dict) -> None:
    """A rank variable the operator form left unshaped is now an ordinary observed
    over the derived set: declare its shape."""
    for section in ("models", "reaction_systems"):
        for comp in (doc.get(section) or {}).values():
            if not isinstance(comp, dict):
                continue
            for eq in comp.get("equations") or []:
                lhs, rhs = eq.get("lhs"), eq.get("rhs")
                if not (
                    _is_node(lhs) and lhs["op"] == "index" and _is_node(rhs) and rhs["op"] == "faq"
                ):
                    continue
                out_idx = rhs.get("output_idx") or []
                if len(out_idx) == 1 and rhs.get("expr") == _op("-", out_idx[0], 1):
                    var = (comp.get("variables") or {}).get(lhs["args"][0])
                    if isinstance(var, dict) and not var.get("shape"):
                        var["shape"] = [rhs["ranges"][out_idx[0]]["from"]]


def migrate_document(doc: dict, *, key_bounds: dict | None = None) -> CodemodResult:
    """Rewrite a 1.x ESM document (parsed JSON) into esm 2.0.0.

    ``key_bounds`` maps the ``id`` of a ``distinct`` producer whose ``key`` is a
    multi-component ``skolem`` to the integer range of each component:
    ``{"kind": "pair", "lo": [lo_1, ...], "n": [n_1, ...]}`` (component i in
    ``[lo_i, lo_i + n_i)``), or ``{"kind": "edge", "lo": lo, "n": n}`` for an
    undirected two-vertex key (``edge_key``, sound only when the author meant
    the pair unordered). The key ``"*"`` applies to every producer not named.
    The input is not modified.

    A 2.x document with nothing to convert is returned unchanged. Raises
    :class:`CodemodError` for a construct with no replacement, and
    :class:`MigrationError` for a document that is neither.
    """
    if not isinstance(doc, dict):
        raise MigrationError("the codemod takes a JSON object")
    version = _parse_version(doc.get("esm"))
    if version is None:
        raise MigrationError(f"the document's `esm` field {doc.get('esm')!r} is not a version")
    if version[0] != 1:
        if version[0] >= 2 and not find_removed(doc):
            return CodemodResult(copy.deepcopy(doc))
        raise MigrationError(
            f"the codemod converts esm 1.x documents; this one is {doc.get('esm')}"
        )
    work = copy.deepcopy(doc)
    mod = _Codemod(work, key_bounds)
    mod.run()
    _shape_rank_outputs(work)
    return CodemodResult(work, mod.notes, mod.counts)


_VERSION_RE = re.compile(r'(^\s*\{\s*"esm"\s*:\s*")[^"]*(")')
_AGGREGATE_RE = re.compile(r'("op"\s*:\s*)"aggregate"')


_INLINE_NUMBERS_RE = re.compile(r"\[\s*-?[0-9][^\n\[\]{}]*,\s*-?[0-9][^\n\[\]{}]*\]")


def _dumps_inline_numbers(x: Any, indent: int, ascii_only: bool, level: int = 0) -> str:
    """``json.dumps(indent=...)``, except that a list of numbers stays on one line."""
    pad, inner = " " * (indent * level), " " * (indent * (level + 1))
    if isinstance(x, dict):
        if not x:
            return "{}"
        items = [
            f"{inner}{json.dumps(k, ensure_ascii=ascii_only)}: "
            f"{_dumps_inline_numbers(v, indent, ascii_only, level + 1)}"
            for k, v in x.items()
        ]
        return "{\n" + ",\n".join(items) + "\n" + pad + "}"
    if isinstance(x, list):
        if not x:
            return "[]"
        if all(isinstance(v, (int, float)) and not isinstance(v, bool) for v in x):
            return json.dumps(x)
        items = [inner + _dumps_inline_numbers(v, indent, ascii_only, level + 1) for v in x]
        return "[\n" + ",\n".join(items) + "\n" + pad + "]"
    return json.dumps(x, ensure_ascii=ascii_only)


def _format_like(text: str, doc: dict) -> str:
    """Serialize ``doc`` with the source text's indentation and escaping, and
    with lists of numbers on one line when the source writes them so."""
    indent = 2
    for line in text.splitlines()[1:]:
        stripped = line.lstrip(" ")
        if stripped and len(stripped) < len(line):
            indent = len(line) - len(stripped)
            break
    ascii_only = all(ord(ch) < 128 for ch in text)
    if "\n" not in text.strip():
        out = json.dumps(doc, separators=(",", ":"), ensure_ascii=ascii_only)
    else:
        out = json.dumps(doc, indent=indent, ensure_ascii=ascii_only)
        if _INLINE_NUMBERS_RE.search(text):
            # Keep whichever layout shares more lines with the source.
            inline = _dumps_inline_numbers(doc, indent, ascii_only)
            source = Counter(text.splitlines())
            if sum((Counter(inline.splitlines()) & source).values()) > sum(
                (Counter(out.splitlines()) & source).values()
            ):
                out = inline
    return out + ("\n" if text.endswith("\n") else "")


def migrate_text(text: str, *, key_bounds: dict | None = None) -> tuple[str, CodemodResult]:
    """Convert the text of a 1.x document; returns ``(new_text, result)``.

    A document that needs only the version bump and the ``aggregate`` rename is
    edited in place in its text, so its own layout survives; any other rewrite
    is serialized with the source's indentation and escaping."""
    result = migrate_document(json.loads(text), key_bounds=key_bounds)
    if set(result.counts) <= {"aggregate"}:
        edited = _VERSION_RE.sub(rf"\g<1>{result.document['esm']}\g<2>", text, count=1)
        edited = _AGGREGATE_RE.sub(r'\g<1>"faq"', edited)
        if json.loads(edited) == result.document:
            return edited, result
    return _format_like(text, result.document), result


def migrate_path(
    path: str | Path, out: str | Path | None = None, *, key_bounds: dict | None = None
) -> CodemodResult:
    """Convert the document at ``path``, writing ``out`` (default: in place)."""
    src = Path(path)
    new_text, result = migrate_text(src.read_text(), key_bounds=key_bounds)
    Path(out if out is not None else src).write_text(new_text)
    return result


def _parse_key_bounds(items: list[str]) -> dict:
    """``ID=pair:LO:N,LO:N`` or ``ID=edge:LO:N`` -> the ``key_bounds`` mapping."""
    out: dict = {}
    for item in items:
        fid, sep, spec = item.partition("=")
        kind, _, rest = spec.partition(":")
        if not sep or kind not in ("pair", "edge") or not rest:
            raise ValueError(f"--key-bounds {item!r}: expected ID=pair:LO:N,LO:N or ID=edge:LO:N")
        try:
            parts = [tuple(int(v) for v in p.split(":")) for p in rest.split(",")]
        except ValueError:
            raise ValueError(f"--key-bounds {item!r}: LO and N must be integers") from None
        if any(len(p) != 2 for p in parts):
            raise ValueError(f"--key-bounds {item!r}: each component is LO:N")
        if kind == "edge":
            if len(parts) != 1:
                raise ValueError(f"--key-bounds {item!r}: an edge key takes one LO:N")
            out[fid] = {"kind": "edge", "lo": parts[0][0], "n": parts[0][1]}
        else:
            out[fid] = {"kind": "pair", "lo": [p[0] for p in parts], "n": [p[1] for p in parts]}
    return out


def _summary(result: CodemodResult) -> str:
    return ", ".join(f"{v} {k}" for k, v in sorted(result.counts.items())) or "version bump only"


def main(argv: list[str] | None = None) -> int:
    """``python -m earthsci_ast.migrate FILE... [-o OUT] [--check] [--key-bounds ...]``.

    Exit status: 0 on success, 1 when ``--check`` finds a file to convert, 2 when
    a file cannot be converted (the reason is printed).
    """
    parser = argparse.ArgumentParser(
        prog=CODEMOD_COMMAND,
        description=(
            "Convert esm 1.x documents to esm 2.0.0: every removed operator (fn, table_lookup, "
            "skolem, rank, polygon_intersection_area, argmin, argmax) and function_tables block "
            "becomes esm:std/*.esm template references."
        ),
    )
    parser.add_argument(
        "files", nargs="+", help="documents to convert (rewritten in place unless -o)"
    )
    parser.add_argument("-o", "--output", help="write the converted document here (one input only)")
    parser.add_argument(
        "--check", action="store_true", help="write nothing; exit 1 if a file would change"
    )
    parser.add_argument(
        "--key-bounds",
        action="append",
        default=[],
        metavar="ID=pair:LO:N,LO:N",
        help="integer range of each component of the skolem key of the distinct producer ID "
        "(ID=edge:LO:N for an undirected edge key; ID '*' for every producer); repeatable",
    )
    parser.add_argument("-q", "--quiet", action="store_true", help="print only errors")
    args = parser.parse_args(argv)
    if args.output and len(args.files) != 1:
        parser.error("-o takes exactly one input file")
    try:
        bounds = _parse_key_bounds(args.key_bounds)
    except ValueError as e:
        parser.error(str(e))
    status = 0
    for f in args.files:
        try:
            text = Path(f).read_text()
            new_text, result = migrate_text(text, key_bounds=bounds)
        except (MigrationError, json.JSONDecodeError, OSError) as e:
            print(f"{f}: error: {e}", file=sys.stderr)
            status = 2
            continue
        if args.check:
            if new_text != text:
                status = max(status, 1)
                if not args.quiet:
                    print(f"{f}: would convert ({_summary(result)})")
            continue
        if new_text != text or args.output:
            Path(args.output or f).write_text(new_text)
        if not args.quiet:
            print(f"{f}: {_summary(result) if result.changed else 'nothing to convert'}")
    return status


if __name__ == "__main__":
    sys.exit(main())
