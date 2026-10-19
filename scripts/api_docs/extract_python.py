"""Extract the Python binding's API documentation into the normalized JSON form.

Reads the Python spellings listed in ``api-surface.json`` and writes
``build/api-docs/python.json`` in the shape ``docs/api/README.md`` §2 defines.

The package is read statically with griffe, which follows ``__all__`` and the
re-exports in ``earthsci_ast/__init__.py`` back to the defining module. Each
docstring is parsed with griffe's ``auto`` parser, because the package mixes
Google-style (``Args:``) and NumPy-style (``Parameters`` / ``----------``)
sections, and the parsed sections are rendered to CommonMark here. The prose
inside a docstring is reStructuredText-flavoured (``literal``, ``:func:`x```,
``::`` literal blocks), so that is converted too.

Module-level constants and type aliases cannot carry a docstring; for those
the Sphinx autodoc ``#:`` comment convention above the assignment is read
instead, since that is how this package documents them.

Usage::

    python extract_python.py --repo-root . --output build/api-docs/python.json
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import textwrap
from pathlib import Path

import logging

import griffe

PACKAGE = "earthsci_ast"
PACKAGE_DIR = Path("pkg/earthsci-ast-py")
SRC_DIR = PACKAGE_DIR / "src"

# Dunder methods a caller uses through syntax (``sol["N"]``, ``for t, u in
# integ``), so they belong in a class's public surface.
PUBLIC_DUNDERS = {"__getitem__", "__contains__", "__iter__", "__len__", "__call__", "__add__"}


# --------------------------------------------------------------------------
# Manifest
# --------------------------------------------------------------------------


def manifest_spellings(manifest: dict) -> list[tuple[str, str, str]]:
    """Return ``(spelling, kind, tier)`` for every Python spelling, in order."""
    seen: dict[str, tuple[str, str, str]] = {}
    for sym in manifest["symbols"]:
        binding = sym.get("bindings", {}).get("python")
        if binding is None:
            continue
        spellings = [binding] if isinstance(binding, str) else list(binding)
        for spelling in spellings:
            seen.setdefault(spelling, (spelling, sym["kind"], sym["tier"]))
    return sorted(seen.values(), key=lambda s: s[0].lower())


# --------------------------------------------------------------------------
# Signatures
# --------------------------------------------------------------------------


def _ann(expr) -> str:
    return "" if expr is None else str(expr)


def format_parameters(params, *, drop_first: bool) -> str:
    """Render griffe parameters in Python's own ``def`` syntax."""
    items = list(params)
    if drop_first and items and items[0].name in ("self", "cls"):
        items = items[1:]
    parts: list[str] = []
    saw_posonly = False
    saw_star = False
    for p in items:
        kind = p.kind.value
        if kind == "positional-only":
            saw_posonly = True
        elif saw_posonly:
            parts.append("/")
            saw_posonly = False
        if kind == "keyword-only" and not saw_star:
            parts.append("*")
            saw_star = True
        prefix = ""
        if kind == "variadic positional":
            prefix, saw_star = "*", True
        elif kind == "variadic keyword":
            prefix = "**"
        text = prefix + p.name
        ann = _ann(p.annotation)
        if ann:
            text += f": {ann}"
        if p.default is not None and prefix == "":
            text += f" = {p.default}" if ann else f"={p.default}"
        parts.append(text)
    if saw_posonly:
        parts.append("/")
    return ", ".join(parts)


def function_signature(func, name: str, *, method: bool = False) -> str:
    sig = f"{name}({format_parameters(func.parameters, drop_first=method)})"
    ret = _ann(func.returns)
    if ret:
        sig += f" -> {ret}"
    if "async" in func.labels:
        sig = "async " + sig
    return sig


def _resolve(obj):
    if obj.is_alias:
        return obj.final_target
    return obj


def _is_enum(cls) -> bool:
    return any(str(b).split(".")[-1] in ("Enum", "IntEnum", "StrEnum", "Flag") for b in cls.bases)


def _public_class_members(cls):
    """Yield ``(name, member)`` for the class's own public methods and properties."""
    for name, member in cls.members.items():
        if name.startswith("_") and name not in PUBLIC_DUNDERS:
            continue
        try:
            member = _resolve(member)
        except Exception:
            continue
        if member.is_function or "property" in member.labels:
            yield name, member


def class_signatures(cls, name: str) -> list[str]:
    bases = [str(b) for b in cls.bases]
    sigs = [f"class {name}({', '.join(bases)})" if bases else f"class {name}"]
    init = cls.members.get("__init__")
    if init is not None:
        init = _resolve(init)
        sigs.append(f"{name}({format_parameters(init.parameters, drop_first=True)})")
    if _is_enum(cls):
        for mname, member in cls.members.items():
            if member.is_attribute and not mname.startswith("_"):
                sigs.append(f"{name}.{mname} = {member.value}")
    for mname, member in _public_class_members(cls):
        if member.is_function and "property" not in member.labels:
            prefix = ""
            if "staticmethod" in member.labels:
                prefix = "@staticmethod "
            elif "classmethod" in member.labels:
                prefix = "@classmethod "
            sigs.append(prefix + function_signature(member, f"{name}.{mname}", method="staticmethod" not in member.labels))
        else:
            ann = _ann(member.returns if member.is_function else member.annotation)
            sigs.append(f"{name}.{mname}" + (f": {ann}" if ann else "") + "  # property")
    return sigs


def attribute_signature(attr, name: str) -> str:
    ann = _ann(attr.annotation)
    value = "" if attr.value is None else " ".join(str(attr.value).split())
    text = name + (f": {ann}" if ann else "")
    if value and len(value) <= 400:
        text += f" = {value}"
    return text


# --------------------------------------------------------------------------
# Docstring rendering
# --------------------------------------------------------------------------

ROLE_RE = re.compile(r":(?:py:)?(func|class|meth|attr|data|exc|mod|obj|const):`(~?)([^`]+)`")
LITERAL_RE = re.compile(r"``(.+?)``", re.S)
UNDERLINE_RE = re.compile(r"^\s*([-=~^])\1{2,}\s*$")
DEFINITION_RE = re.compile(r"^([A-Za-z_][\w.]*(?:, [A-Za-z_][\w.]*)*):\s*$")


class Renderer:
    def __init__(self, link_targets: set[str]):
        self.link_targets = link_targets

    # -- inline -------------------------------------------------------------

    def inline(self, text: str) -> str:
        def role(m: re.Match) -> str:
            kind, tilde, target = m.groups()
            target = target.strip()
            explicit = re.match(r"^(.*?)\s*<(.+)>$", target)
            label = None
            if explicit:
                label, target = explicit.group(1), explicit.group(2)
                tilde = ""
            short = target.split(".")[-1]
            shown = label or (short if tilde else target)
            if kind in ("meth", "attr") or kind == "mod":
                return f"`{shown}`"
            if short in self.link_targets:
                return f"[`{shown}`](api:{short})"
            return f"`{shown}`"

        text = ROLE_RE.sub(role, text)
        return LITERAL_RE.sub(lambda m: "`" + m.group(1).replace("\n", " ") + "`", text)

    # -- blocks ---------------------------------------------------------------

    def text(self, text: str) -> str:
        """Convert one reST-flavoured prose section to CommonMark."""
        text = textwrap.dedent(text).strip("\n")
        # An inline literal that wraps across a line break is one span.
        text = re.sub(
            r"``([^`]+?)``",
            lambda m: "``" + " ".join(m.group(1).split()) + "``" if "\n" in m.group(1) else m.group(0),
            text,
        )
        lines = text.splitlines()
        out: list[str] = []
        i = 0
        n = len(lines)
        while i < n:
            line = lines[i]
            # A doctest paragraph: lines starting with ``>>>``.
            if line.lstrip().startswith(">>>"):
                block = []
                while i < n and lines[i].strip():
                    block.append(lines[i])
                    i += 1
                out.extend(self.doctest(block))
                continue
            # A NumPy-style underlined heading inside free text.
            if i + 1 < n and line.strip() and UNDERLINE_RE.match(lines[i + 1]):
                out.append(f"**{line.strip()}**")
                out.append("")
                i += 2
                continue
            # ``name:`` followed by an indented description: a definition list.
            m = DEFINITION_RE.match(line)
            if m and i + 1 < n and lines[i + 1].startswith((" ", "\t")) and lines[i + 1].strip():
                body, i = self._indented_block(lines, i + 1)
                names = ", ".join(f"`{x.strip()}`" for x in m.group(1).split(","))
                out.extend(self._bullet(names, self.text("\n".join(body))))
                if i < n and lines[i].strip() and not DEFINITION_RE.match(lines[i]):
                    out.append("")
                continue
            # A paragraph ending in ``::`` introduces a literal block.
            if line.rstrip().endswith("::"):
                stripped = line.rstrip()[:-2].rstrip()
                if stripped:
                    out.append(self.inline(stripped + ":"))
                i += 1
                while i < n and not lines[i].strip():
                    i += 1
                body, i = self._indented_block(lines, i)
                if body:
                    out.append("")
                    out.extend(self.fence(body))
                    out.append("")
                continue
            # Any other indented block after a blank line is an rST block
            # quote; it is not code, so it is dedented rather than left to
            # become an indented code block in CommonMark.
            if line.startswith((" ", "\t")) and line.strip() and (not out or not out[-1].strip()):
                body, i = self._indented_block(lines, i)
                out.extend(self.text("\n".join(body)).splitlines())
                continue
            out.append(self.inline(line) if line.strip() else "")
            i += 1
        return self._join(out)

    @staticmethod
    def _indented_block(lines: list[str], i: int) -> tuple[list[str], int]:
        block: list[str] = []
        n = len(lines)
        while i < n and (not lines[i].strip() or lines[i].startswith((" ", "\t"))):
            block.append(lines[i])
            i += 1
        while block and not block[-1].strip():
            block.pop()
        return textwrap.dedent("\n".join(block)).splitlines(), i

    @staticmethod
    def fence(body: list[str]) -> list[str]:
        if any(line.lstrip().startswith(">>>") for line in body):
            return Renderer.doctest(body)
        return ["```python", *body, "```"]

    @staticmethod
    def doctest(block: list[str]) -> list[str]:
        """A ``>>>`` session becomes plain Python; its output becomes comments."""
        code: list[str] = []
        for raw in textwrap.dedent("\n".join(block)).splitlines():
            if raw.startswith(">>> ") or raw == ">>>":
                code.append(raw[4:])
            elif raw.startswith("... ") or raw == "...":
                code.append(raw[4:])
            elif raw.strip():
                code.append(f"# {raw}")
        return ["", "```python", *code, "```", ""]

    @staticmethod
    def _bullet(head: str, desc: str) -> list[str]:
        desc_lines = desc.strip().splitlines() if desc else []
        if not desc_lines:
            return [f"- {head}"]
        first = f"- {head} — {desc_lines[0]}"
        rest = [("  " + line) if line.strip() else "" for line in desc_lines[1:]]
        return [first, *rest]

    @staticmethod
    def _join(lines: list[str]) -> str:
        text = "\n".join(lines)
        text = re.sub(r"\n{3,}", "\n\n", text)
        return text.strip()

    def section(self, section) -> str:
        kind = section.kind.value
        if kind == "text":
            return self.text(section.value)
        if kind in ("parameters", "other parameters", "attributes", "type parameters"):
            heading = {
                "parameters": "Parameters",
                "other parameters": "Other parameters",
                "attributes": "Attributes",
                "type parameters": "Type parameters",
            }[kind]
            rows: list[str] = []
            items = list(section.value)
            j = 0
            while j < len(items):
                # NumPy ``a, b:`` lines become one row with both names.
                group = [items[j]]
                while j + 1 < len(items) and items[j + 1].description == items[j].description:
                    j += 1
                    group.append(items[j])
                j += 1
                names = ", ".join(f"`{p.name}`" for p in group)
                ann = _ann(group[0].annotation)
                head = names + (f" (`{ann}`)" if ann and len(group) == 1 else "")
                rows.extend(self._bullet(head, self.text(group[0].description or "")))
            return f"**{heading}**\n\n" + "\n".join(rows)
        if kind in ("returns", "yields", "receives"):
            heading = {"returns": "Returns", "yields": "Yields", "receives": "Receives"}[kind]
            rows = []
            for r in section.value:
                ann = _ann(r.annotation)
                head = " ".join(x for x in [f"`{r.name}`" if r.name else "", f"`{ann}`" if ann else ""] if x)
                desc = self.text(r.description or "")
                if head:
                    rows.extend(self._bullet(head, desc))
                else:
                    rows.append(desc)
            if len(rows) == 1 and not rows[0].startswith("- "):
                return f"**{heading}**\n\n{rows[0]}"
            return f"**{heading}**\n\n" + "\n".join(rows)
        if kind in ("raises", "warns"):
            heading = "Raises" if kind == "raises" else "Warns"
            rows = []
            for r in section.value:
                ann = _ann(r.annotation).strip("()")
                names = ", ".join(self._exc_link(x.strip()) for x in ann.split(",") if x.strip())
                rows.extend(self._bullet(names, self.text(r.description or "")))
            return f"**{heading}**\n\n" + "\n".join(rows)
        if kind == "examples":
            parts: list[str] = []
            for sub_kind, value in section.value:
                if sub_kind.value == "examples":
                    parts.append(self._join(self.doctest(value.splitlines())))
                else:
                    parts.append(self.text(value))
            return "**Examples**\n\n" + "\n\n".join(parts)
        if kind == "admonition":
            title = section.title or section.value.kind
            return f"**{title.strip().capitalize()}**\n\n{self.text(section.value.description)}"
        if kind == "deprecated":
            return f"**Deprecated**\n\n{self.text(section.value.description)}"
        # Any other section kind is rendered as its raw text.
        return self.text(str(section.value))

    def _exc_link(self, name: str) -> str:
        short = name.split(".")[-1]
        if short in self.link_targets:
            return f"[`{short}`](api:{short})"
        return f"`{name}`"

    def docstring(self, doc) -> str | None:
        if doc is None or not doc.value.strip():
            return None
        sections = doc.parse(griffe.Parser.auto)
        rendered = [self.section(s) for s in sections]
        return self._join(["\n\n".join(r for r in rendered if r)]) or None


def comment_doc(obj, repo_root: Path) -> str | None:
    """The ``#:`` comment block directly above an assignment, if any."""
    path = repo_root / obj.relative_filepath if not Path(obj.filepath).is_absolute() else Path(obj.filepath)
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return None
    i = (obj.lineno or 1) - 2
    block: list[str] = []
    while i >= 0 and lines[i].lstrip().startswith("#:"):
        block.append(lines[i].lstrip()[2:].removeprefix(" "))
        i -= 1
    if not block:
        return None
    return "\n".join(reversed(block))


def class_members_doc(cls, renderer: Renderer) -> str | None:
    rows = []
    for mname, member in _public_class_members(cls):
        if not member.docstring or not member.docstring.value.strip():
            continue
        summary = member.docstring.value.strip().split("\n\n")[0]
        rows.extend(renderer._bullet(f"`{mname}`", renderer.inline(" ".join(summary.split()))))
    if not rows:
        return None
    return "**Members**\n\n" + "\n".join(rows)


# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------


def package_version(repo_root: Path) -> str:
    text = (repo_root / PACKAGE_DIR / "pyproject.toml").read_text(encoding="utf-8")
    m = re.search(r'^version\s*=\s*"([^"]+)"', text, re.M)
    return m.group(1) if m else "unknown"


def extract(repo_root: Path) -> dict:
    manifest = json.loads((repo_root / "api-surface.json").read_text(encoding="utf-8"))
    entries = manifest_spellings(manifest)
    link_targets = {spelling for spelling, _, _ in entries}
    renderer = Renderer(link_targets)

    # griffe warns about every parameter without a type annotation; those
    # warnings are about the source, not about this extraction.
    logging.getLogger("griffe").setLevel(logging.ERROR)
    pkg = griffe.load(
        PACKAGE,
        search_paths=[str(repo_root / SRC_DIR)],
        resolve_aliases=True,
        resolve_external=False,
    )

    symbols = []
    for spelling, kind, tier in entries:
        record = {
            "spelling": spelling,
            "kind": kind,
            "signatures": [],
            "doc": None,
            "source": None,
            "native_url": None,
        }
        try:
            obj = _resolve(pkg[spelling])
            # ``from .flatten import flatten`` rebinds the package attribute to
            # the function, but the submodule of the same name is what a
            # static lookup finds first.
            if obj.is_module and spelling in obj.members:
                obj = _resolve(obj.members[spelling])
        except Exception:
            record["missing"] = True
            symbols.append(record)
            continue

        doc = renderer.docstring(obj.docstring)
        if obj.is_function:
            record["signatures"] = [function_signature(obj, spelling)]
        elif obj.is_class:
            record["signatures"] = class_signatures(obj, spelling)
            if doc is None:
                init = obj.members.get("__init__")
                if init is not None:
                    doc = renderer.docstring(_resolve(init).docstring)
            members = class_members_doc(obj, renderer)
            if members:
                doc = f"{doc}\n\n{members}" if doc else members
        elif obj.is_attribute:
            comment = comment_doc(obj, repo_root)
            target = None
            if obj.value is not None and re.fullmatch(r"[A-Za-z_]\w*", str(obj.value)):
                target = obj.parent.members.get(str(obj.value))
            if target is not None:
                target = _resolve(target)
            if target is not None and target.is_function:
                # A plain rebinding (``Expand = expand_document``): the name is
                # callable with the target's signature.
                record["signatures"] = [function_signature(target, spelling)]
            else:
                record["signatures"] = [attribute_signature(obj, spelling)]
            if doc is None and comment:
                doc = renderer.text(comment)
        else:
            record["signatures"] = [spelling]

        record["doc"] = doc
        filepath = Path(obj.filepath).resolve()
        try:
            rel = filepath.relative_to(repo_root.resolve())
        except ValueError:
            rel = filepath
        record["source"] = {"path": rel.as_posix(), "line": obj.lineno}
        symbols.append(record)

    return {
        "binding": "python",
        "package_version": package_version(repo_root),
        "extractor": f"griffe {griffe_version()}",
        "symbols": symbols,
    }


def griffe_version() -> str:
    from importlib.metadata import version

    return version("griffe")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo-root", type=Path, default=Path("."))
    parser.add_argument("--output", type=Path, default=Path("build/api-docs/python.json"))
    args = parser.parse_args(argv)

    data = extract(args.repo_root)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    total = len(data["symbols"])
    missing = sum(1 for s in data["symbols"] if s.get("missing"))
    undocumented = sum(1 for s in data["symbols"] if s["doc"] is None)
    print(
        f"python: {total} spellings, {total - undocumented} documented, "
        f"{undocumented} without docs ({missing} not found) -> {args.output}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
