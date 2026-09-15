"""Every diagnostic code this binding raises is a registered one.

The code strings are a cross-binding wire contract (esm-spec §9.6.6 calls the
table "cross-language uniform"), and a code that reaches a raise site without
being in ``ERROR_CODES`` is exactly how one binding silently drifts from the
others. This test reads ``src/earthsci_ast`` with :mod:`ast` and checks that
every code it can resolve at a raise site is registered. A raise site is:

* the argument bound to a parameter named ``code`` -- of a class constructor
  (``__init__``, inherited by class name), or of a function in the same module;
* that parameter's default value;
* a ``code=`` keyword argument to any call;
* a class-body ``code = ...`` attribute;
* a ``"code": ...`` entry in a dict literal;
* an assignment to ``<obj>.code``.

A raised value resolves when it is a string literal, a module-level string
constant of the package, or an ``ERROR_CODES.<NAME>`` / ``ErrorCode.<NAME>``
reference; anything computed at run time is out of reach and skipped. It also
checks that every code in the esm-spec §9.6.6 table is registered. A registered
code nothing raises is reported with :func:`warnings.warn`, not failed.
"""

from __future__ import annotations

import ast
import re
import warnings
from pathlib import Path

from conftest import REPO_ROOT

from earthsci_ast.error_handling import ERROR_CODES, ErrorCode

SRC = Path(__file__).resolve().parents[1] / "src" / "earthsci_ast"

#: §9.6.6 codes no binding registers yet. ``unevaluable_operator`` is registered
#: across the bindings by the issue #247 work (branch
#: claude/issue-247-unevaluable-operator); drop it from this set when that lands.
SPEC_CODES_EXEMPT = frozenset({"unevaluable_operator"})

#: A diagnostic code: snake_case. The uppercase ``E_*`` names are a separate
#: stable error-name vocabulary that no binding's code registry carries.
_CODE_SHAPE = re.compile(r"^[a-z][a-z0-9]*(?:_[a-z0-9]+)*$")


def _modules() -> dict[Path, ast.Module]:
    return {p: ast.parse(p.read_text(), filename=str(p)) for p in sorted(SRC.rglob("*.py"))}


def _module_string_constants(modules) -> dict[str, set[str]]:
    out: dict[str, set[str]] = {}
    for tree in modules.values():
        for stmt in tree.body:
            targets, value = [], None
            if isinstance(stmt, ast.Assign):
                targets, value = stmt.targets, stmt.value
            elif isinstance(stmt, ast.AnnAssign) and stmt.value is not None:
                targets, value = [stmt.target], stmt.value
            if isinstance(value, ast.Constant) and isinstance(value.value, str):
                for t in targets:
                    if isinstance(t, ast.Name):
                        out.setdefault(t.id, set()).add(value.value)
    return out


def _code_param_index(args: ast.arguments, *, skip_self: bool) -> int | None:
    params = [*args.posonlyargs, *args.args]
    if skip_self:
        params = params[1:]
    for i, a in enumerate(params):
        if a.arg == "code":
            return i
    return None


def _scan():
    modules = _modules()
    constants = _module_string_constants(modules)
    registered = set(ERROR_CODES.values())

    # Pass 1: constructor and function signatures that carry a `code`.
    ctor_index: dict[str, int | None] = {}
    bases: dict[str, str] = {}
    fn_index: dict[tuple[Path, str], int] = {}
    for path, tree in modules.items():
        for node in ast.walk(tree):
            if isinstance(node, ast.ClassDef):
                if node.bases and isinstance(node.bases[0], ast.Name):
                    bases[node.name] = node.bases[0].id
                for item in node.body:
                    if isinstance(item, ast.FunctionDef) and item.name == "__init__":
                        ctor_index[node.name] = _code_param_index(item.args, skip_self=True)
            elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                i = _code_param_index(node.args, skip_self=False)
                if i is not None:
                    fn_index[(path, node.name)] = i

    def resolve_ctor(name: str) -> int | None:
        for _ in range(32):
            if name in ctor_index:
                return ctor_index[name]
            if name not in bases:
                return None
            name = bases[name]
        return None

    violations: list[str] = []
    raised: set[str] = set()
    checked = 0

    def resolve(expr: ast.expr) -> set[str] | None:
        if isinstance(expr, ast.Constant) and isinstance(expr.value, str):
            return {expr.value}
        if isinstance(expr, ast.Name) and expr.id in constants:
            return constants[expr.id]
        if isinstance(expr, ast.Attribute):
            inner = expr.value
            if expr.attr == "value" and isinstance(inner, ast.Attribute):
                expr, inner = inner, inner.value
            if isinstance(inner, ast.Name) and inner.id in ("ERROR_CODES", "ErrorCode"):
                if expr.attr in ERROR_CODES:
                    return {ERROR_CODES[expr.attr]}
                return {f"<unregistered name {inner.id}.{expr.attr}>"}
        return None

    def check(expr: ast.expr | None, where: str) -> None:
        nonlocal checked
        if expr is None:
            return
        values = resolve(expr)
        if values is None:
            return
        for value in values:
            if value.startswith("<unregistered name"):
                checked += 1
                violations.append(f"{where}: raises {value[1:-1]}")
                continue
            if not _CODE_SHAPE.match(value):
                continue
            checked += 1
            raised.add(value)
            if value not in registered:
                violations.append(f"{where}: raises {value!r}, which ERROR_CODES does not register")

    for path, tree in modules.items():
        rel = path.relative_to(SRC)
        for node in ast.walk(tree):
            where = f"{rel}:{getattr(node, 'lineno', '?')}"
            if isinstance(node, ast.Call):
                fn = node.func
                index = None
                if isinstance(fn, ast.Name):
                    index = fn_index.get((path, fn.id))
                    if index is None and fn.id[:1].isupper():
                        index = resolve_ctor(fn.id)
                elif isinstance(fn, ast.Attribute) and fn.attr[:1].isupper():
                    index = resolve_ctor(fn.attr)
                if index is not None and index < len(node.args):
                    check(node.args[index], where)
                for kw in node.keywords:
                    if kw.arg == "code":
                        check(kw.value, where)
            elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                args = node.args
                positional = [*args.posonlyargs, *args.args]
                defaults = dict(
                    zip(positional[len(positional) - len(args.defaults) :], args.defaults)
                )
                defaults.update(
                    (a, d) for a, d in zip(args.kwonlyargs, args.kw_defaults) if d is not None
                )
                for a, d in defaults.items():
                    if a.arg == "code":
                        check(d, where)
            elif isinstance(node, ast.ClassDef):
                for item in node.body:
                    if (
                        isinstance(item, ast.Assign)
                        and any(isinstance(t, ast.Name) and t.id == "code" for t in item.targets)
                    ) or (
                        isinstance(item, ast.AnnAssign)
                        and isinstance(item.target, ast.Name)
                        and item.target.id == "code"
                    ):
                        check(item.value, f"{rel}:{item.lineno}")
            elif isinstance(node, ast.Dict):
                for k, v in zip(node.keys, node.values):
                    if isinstance(k, ast.Constant) and k.value == "code":
                        check(v, where)
            elif isinstance(node, ast.Assign):
                for t in node.targets:
                    if isinstance(t, ast.Attribute) and t.attr == "code":
                        check(node.value, where)
    return violations, raised, checked, modules


def _spec_diagnostic_codes() -> list[str]:
    text = (REPO_ROOT / "esm-spec.md").read_text()
    start = text.index("\n#### 9.6.6 ")
    section = text[start + 1 :]
    end = section.find("\n#### ")
    if end >= 0:
        section = section[:end]
    return re.findall(r"^\| `([a-z][a-z0-9_]*)` \|", section, re.M)


def test_every_raised_diagnostic_code_is_registered():
    violations, raised, checked, modules = _scan()
    # Guard the scan: a layout drift that matched no raise site would pass
    # vacuously.
    assert checked >= 100, f"scanned only {checked} raise sites"
    assert violations == [], "\n".join(violations)

    # Registered but never raised: advisory only.
    source = "\n".join(p.read_text() for p in modules if p.name != "error_handling.py")
    unused = sorted(
        name
        for name, value in ERROR_CODES.items()
        if value not in raised
        and not re.search(rf"\b{name}\b", source)
        and f'"{value}"' not in source
    )
    if unused:
        warnings.warn(f"ERROR_CODES entries nothing raises: {', '.join(unused)}", stacklevel=1)


def test_every_spec_diagnostic_code_is_registered():
    codes = _spec_diagnostic_codes()
    # Guard the extraction: a heading or table-layout change that matched
    # nothing would pass the membership check vacuously.
    assert len(codes) >= 30, codes
    registered = set(ERROR_CODES.values()) | {m.value for m in ErrorCode}
    missing = [c for c in codes if c not in registered and c not in SPEC_CODES_EXEMPT]
    assert missing == [], missing
