#!/usr/bin/env python3
"""Turn rustdoc's JSON output for `earthsci-ast` into build/api-docs/rust.json.

Called by `scripts/api_docs/rust.sh`, which runs rustdoc first. The output
shape is the contract in docs/api/README.md §2: one entry per Rust spelling
in api-surface.json, with signatures, CommonMark docs, source location and a
docs.rs link.

Uses only the standard library. Rustdoc's JSON format is unstable and
versioned (`format_version`); the reader below accepts the field spellings of
the versions listed in TESTED_FORMAT_VERSIONS and warns, rather than fails, on
any other version.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

# The rustdoc JSON format versions this reader has been run against.
TESTED_FORMAT_VERSIONS = {57, 61}

CRATE_DIR = "pkg/earthsci-ast-rs"
DOCS_RS_ROOT = "https://docs.rs/earthsci-ast/latest/"
# Cargo features docs.rs builds with: the crate's defaults, since Cargo.toml
# has no [package.metadata.docs.rs] table. An item gated on any other feature
# has no docs.rs page.
DOCS_RS_FEATURES = {"cli", "solve"}

URL_PREFIX = {
    "function": "fn",
    "struct": "struct",
    "enum": "enum",
    "union": "union",
    "trait": "trait",
    "trait_alias": "traitalias",
    "type_alias": "type",
    "constant": "constant",
    "static": "static",
    "macro": "macro",
    "module": "index",
}


class Doc:
    """The rustdoc JSON document, with lookups that tolerate format drift."""

    def __init__(self, data: dict):
        self.data = data
        self.index = data["index"]
        self.paths = data["paths"]
        self.version = data.get("format_version")
        # Paths of types, to tell a method (whose parent is a type) from a
        # free function: newer formats list methods in `paths` too.
        self.type_paths = {
            tuple(p["path"])
            for p in self.paths.values()
            if p.get("kind") in ("struct", "enum", "union", "trait", "type_alias")
        }

    def item(self, item_id):
        if item_id is None:
            return None
        return self.index.get(str(item_id))

    def path_of(self, item_id):
        return self.paths.get(str(item_id))


def kind_of(item: dict) -> str:
    return next(iter(item["inner"]))


# ---------------------------------------------------------------------------
# Types and signatures
# ---------------------------------------------------------------------------


def path_name(path: dict) -> str:
    # `path` in recent formats, `name` in older ones. Show the last segment:
    # `crate::simulate::SolveOptions` reads as `SolveOptions` on docs.rs too.
    raw = path.get("path", path.get("name", "?"))
    return raw.rsplit("::", 1)[-1]


def fmt_generic_args(args) -> str:
    if not args:
        return ""
    if "angle_bracketed" in args:
        ab = args["angle_bracketed"]
        parts = [fmt_generic_arg(a) for a in ab.get("args", [])]
        parts += [fmt_constraint(c) for c in ab.get("constraints", ab.get("bindings", []))]
        return "<" + ", ".join(parts) + ">" if parts else ""
    if "parenthesized" in args:
        p = args["parenthesized"]
        out = "(" + ", ".join(fmt_type(t) for t in p.get("inputs", [])) + ")"
        if p.get("output"):
            out += " -> " + fmt_type(p["output"])
        return out
    if "return_type_notation" in args or args == "return_type_notation":
        return "(..)"
    return ""


def fmt_generic_arg(a) -> str:
    if isinstance(a, str):
        return "_" if a == "infer" else a
    if "lifetime" in a:
        return a["lifetime"]
    if "type" in a:
        return fmt_type(a["type"])
    if "const" in a:
        c = a["const"]
        return c.get("expr", "_") if isinstance(c, dict) else str(c)
    return "_"


def fmt_constraint(c) -> str:
    name = c["name"] + fmt_generic_args(c.get("args"))
    binding = c.get("binding", {})
    if "equality" in binding:
        term = binding["equality"]
        value = (
            fmt_type(term["type"]) if "type" in term else term.get("constant", {}).get("expr", "_")
        )
        return f"{name} = {value}"
    if "constraint" in binding:
        return f"{name}: " + fmt_bounds(binding["constraint"])
    return name


def fmt_bounds(bounds) -> str:
    return " + ".join(fmt_bound(b) for b in bounds)


def fmt_bound(b) -> str:
    if "trait_bound" in b:
        tb = b["trait_bound"]
        modifier = {"maybe": "?", "maybe_const": "~const "}.get(tb.get("modifier"), "")
        hrtb = fmt_hrtb(tb.get("generic_params", []))
        return hrtb + modifier + path_name(tb["trait"]) + fmt_generic_args(tb["trait"].get("args"))
    if "outlives" in b:
        return b["outlives"]
    if "use" in b:
        return (
            "use<"
            + ", ".join(str(x if isinstance(x, str) else next(iter(x.values()))) for x in b["use"])
            + ">"
        )
    return "?"


def fmt_hrtb(params) -> str:
    if not params:
        return ""
    return "for<" + ", ".join(p["name"] for p in params) + "> "


def fmt_type(t) -> str:
    if t is None:
        return "()"
    if isinstance(t, str):
        return "_" if t == "infer" else t
    ((k, v),) = t.items()
    if k == "resolved_path":
        return path_name(v) + fmt_generic_args(v.get("args"))
    if k == "dyn_trait":
        traits = [
            fmt_hrtb(p.get("generic_params", []))
            + path_name(p["trait"])
            + fmt_generic_args(p["trait"].get("args"))
            for p in v["traits"]
        ]
        if v.get("lifetime"):
            traits.append(v["lifetime"])
        return "dyn " + " + ".join(traits)
    if k == "generic":
        return v
    if k == "primitive":
        return v
    if k == "tuple":
        inner = ", ".join(fmt_type(x) for x in v)
        return f"({inner},)" if len(v) == 1 else f"({inner})"
    if k == "slice":
        return f"[{fmt_type(v)}]"
    if k == "array":
        return f"[{fmt_type(v['type'])}; {v['len']}]"
    if k == "pat":
        return fmt_type(v["type"])
    if k == "impl_trait":
        return "impl " + fmt_bounds(v)
    if k == "infer":
        return "_"
    if k == "raw_pointer":
        mut = v.get("is_mutable", v.get("mutable"))
        return ("*mut " if mut else "*const ") + fmt_type(v["type"])
    if k == "borrowed_ref":
        mut = v.get("is_mutable", v.get("mutable"))
        lt = (v["lifetime"] + " ") if v.get("lifetime") else ""
        return "&" + lt + ("mut " if mut else "") + fmt_type(v["type"])
    if k == "qualified_path":
        self_ty = fmt_type(v["self_type"])
        trait = v.get("trait")
        base = (
            f"<{self_ty} as {path_name(trait)}{fmt_generic_args(trait.get('args'))}>"
            if trait
            else self_ty
        )
        return f"{base}::{v['name']}{fmt_generic_args(v.get('args'))}"
    if k == "function_pointer":
        sig = v.get("sig", v.get("decl"))
        args = ", ".join(fmt_type(ty) for _, ty in sig["inputs"])
        out = sig.get("output")
        return f"fn({args})" + (f" -> {fmt_type(out)}" if out else "")
    return "?"


def fmt_generic_params(generics, skip_synthetic=True) -> str:
    parts = []
    for p in generics.get("params", []):
        kind = p["kind"]
        if "lifetime" in kind:
            outlives = kind["lifetime"].get("outlives", [])
            parts.append(p["name"] + (": " + " + ".join(outlives) if outlives else ""))
        elif "type" in kind:
            ty = kind["type"]
            if skip_synthetic and ty.get("is_synthetic", ty.get("synthetic")):
                continue  # `impl Trait` in argument position
            s = p["name"]
            if ty.get("bounds"):
                s += ": " + fmt_bounds(ty["bounds"])
            if ty.get("default"):
                s += " = " + fmt_type(ty["default"])
            parts.append(s)
        elif "const" in kind:
            c = kind["const"]
            s = f"const {p['name']}: {fmt_type(c['type'])}"
            if c.get("default"):
                s += " = " + c["default"]
            parts.append(s)
    return "<" + ", ".join(parts) + ">" if parts else ""


def fmt_where(generics) -> str:
    preds = []
    for w in generics.get("where_predicates", []):
        if "bound_predicate" in w:
            bp = w["bound_predicate"]
            preds.append(
                fmt_hrtb(bp.get("generic_params", []))
                + fmt_type(bp["type"])
                + ": "
                + fmt_bounds(bp["bounds"])
            )
        elif "lifetime_predicate" in w:
            lp = w["lifetime_predicate"]
            preds.append(lp["lifetime"] + ": " + " + ".join(lp["outlives"]))
        elif "eq_predicate" in w:
            ep = w["eq_predicate"]
            rhs = ep["rhs"]
            rhs_s = (
                fmt_type(rhs["type"]) if "type" in rhs else rhs.get("constant", {}).get("expr", "_")
            )
            preds.append(fmt_type(ep["lhs"]) + " = " + rhs_s)
    return (" where " + ", ".join(preds)) if preds else ""


def fmt_fn(name: str, f: dict, vis: str = "pub ") -> str:
    sig = f.get("sig", f.get("decl"))
    header = f.get("header", {})
    if isinstance(header, list):  # older formats: a list of qualifiers
        header = {"is_" + h: True for h in header}
    quals = ""
    if header.get("is_const"):
        quals += "const "
    if header.get("is_async"):
        quals += "async "
    if header.get("is_unsafe"):
        quals += "unsafe "
    args = []
    for arg_name, ty in sig["inputs"]:
        if arg_name == "self":
            ts = fmt_type(ty)
            args.append(
                {"Self": "self", "&Self": "&self", "&mut Self": "&mut self"}.get(ts, f"self: {ts}")
            )
        else:
            args.append(f"{arg_name}: {fmt_type(ty)}")
    out = sig.get("output")
    ret = f" -> {fmt_type(out)}" if out else ""
    generics = f.get("generics", {})
    return f"{vis}{quals}fn {name}{fmt_generic_params(generics)}({', '.join(args)}){ret}{fmt_where(generics)}"


def fmt_variant(doc: Doc, v: dict) -> str:
    kind = v["inner"]["variant"]["kind"]
    name = v["name"]
    if kind == "plain":
        disc = v["inner"]["variant"].get("discriminant")
        return name + (f" = {disc['expr']}" if disc else "")
    if "tuple" in kind:
        fields = [doc.item(i) for i in kind["tuple"]]
        return (
            name
            + "("
            + ", ".join(fmt_type(f["inner"]["struct_field"]) if f else "_" for f in fields)
            + ")"
        )
    if "struct" in kind:
        fields = [doc.item(i) for i in kind["struct"]["fields"]]
        body = ", ".join(
            f"{f['name']}: {fmt_type(f['inner']['struct_field'])}" for f in fields if f
        )
        return name + " { " + body + " }"
    return name


def declaration(doc: Doc, item: dict, name: str) -> str:
    """The item's own declaration, as docs.rs shows it at the top of its page."""
    k = kind_of(item)
    v = item["inner"][k]
    if k == "function":
        return fmt_fn(name, v)
    if k in ("constant", "static"):
        ty = fmt_type(v["type"])
        expr = v.get("const", {}).get("expr") if k == "constant" else v.get("expr")
        mut = "mut " if k == "static" and v.get("is_mutable", v.get("mutable")) else ""
        kw = "const" if k == "constant" else "static"
        s = f"pub {kw} {mut}{name}: {ty}"
        if expr and expr != "_" and len(expr) <= 80:
            s += f" = {expr}"
        return s + ";"
    if k == "type_alias":
        return f"pub type {name}{fmt_generic_params(v['generics'])} = {fmt_type(v['type'])};"
    if k == "struct":
        head = f"pub struct {name}{fmt_generic_params(v['generics'])}"
        sk = v["kind"]
        if sk == "unit":
            return head + ";"
        if "tuple" in sk:
            fields = [doc.item(i) for i in sk["tuple"]]
            inner = ", ".join(
                ("pub " + fmt_type(f["inner"]["struct_field"])) if f else "/* private field */"
                for f in fields
            )
            return f"{head}({inner}){fmt_where(v['generics'])};"
        plain = sk["plain"]
        lines = [
            f"    pub {f['name']}: {fmt_type(f['inner']['struct_field'])},"
            for f in map(doc.item, plain["fields"])
            if f
        ]
        if plain.get("has_stripped_fields", plain.get("fields_stripped")):
            lines.append("    /* private fields */")
        if not lines:
            return head + fmt_where(v["generics"]) + " { /* private fields */ }"
        return head + fmt_where(v["generics"]) + " {\n" + "\n".join(lines) + "\n}"
    if k == "enum":
        head = f"pub enum {name}{fmt_generic_params(v['generics'])}{fmt_where(v['generics'])}"
        lines = [f"    {fmt_variant(doc, var)}," for var in map(doc.item, v["variants"]) if var]
        if v.get("has_stripped_variants", v.get("variants_stripped")):
            lines.append("    // some variants omitted")
        return head + " {\n" + "\n".join(lines) + "\n}" if lines else head + " {}"
    if k == "trait":
        bounds = (": " + fmt_bounds(v["bounds"])) if v.get("bounds") else ""
        head = f"pub {'unsafe ' if v.get('is_unsafe') else ''}trait {name}{fmt_generic_params(v['generics'])}{bounds}{fmt_where(v['generics'])}"
        lines = []
        for member in map(doc.item, v.get("items", [])):
            if not member:
                continue
            mk = kind_of(member)
            if mk == "function":
                lines.append(
                    "    " + fmt_fn(member["name"], member["inner"]["function"], vis="") + ";"
                )
            elif mk == "assoc_type":
                lines.append(f"    type {member['name']};")
            elif mk == "assoc_const":
                lines.append(
                    f"    const {member['name']}: {fmt_type(member['inner']['assoc_const']['type'])};"
                )
        return head + " {\n" + "\n".join(lines) + "\n}" if lines else head + " {}"
    if k == "union":
        return f"pub union {name}{fmt_generic_params(v['generics'])} {{ /* fields */ }}"
    return f"pub {k} {name}"


def inherent_methods(doc: Doc, item: dict, name: str) -> list[str]:
    """Public inherent methods of a struct or enum, one signature each."""
    k = kind_of(item)
    if k not in ("struct", "enum", "union"):
        return []
    out = []
    for impl in map(doc.item, item["inner"][k].get("impls", [])):
        if not impl:
            continue
        iv = impl["inner"]["impl"]
        if (
            iv.get("trait") is not None
            or iv.get("is_synthetic", iv.get("synthetic"))
            or iv.get("blanket_impl")
        ):
            continue
        self_ty = fmt_type(iv["for"])
        impl_generics = fmt_generic_params(iv.get("generics", {}))
        for member in map(doc.item, iv.get("items", [])):
            if not member or member.get("visibility") != "public":
                continue
            if kind_of(member) != "function":
                continue
            sig = fmt_fn(member["name"], member["inner"]["function"])
            out.append(f"impl{impl_generics} {self_ty} {{ {sig} }}")
    return out


# ---------------------------------------------------------------------------
# Docs: rustdoc Markdown -> the contract's CommonMark
# ---------------------------------------------------------------------------

FENCE_RE = re.compile(r"^(\s*)(```+|~~~+)\s*(.*)$")
HEADING_RE = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$")
REFDEF_RE = re.compile(r"^\s{0,3}\[([^\]]+)\]:\s*(\S+)\s*$")
# Rustdoc code-block attributes that still mean "this is Rust".
RUST_FENCE_ATTRS = {
    "",
    "rust",
    "ignore",
    "no_run",
    "should_panic",
    "compile_fail",
    "test_harness",
    "edition2015",
    "edition2018",
    "edition2021",
    "edition2024",
}


def is_rust_fence(info: str) -> bool:
    tokens = [t.strip() for t in re.split(r"[,\s]+", info.strip()) if t.strip()]
    return all(
        t in RUST_FENCE_ATTRS or t.startswith("edition") or t.startswith("ignore-") for t in tokens
    )


class LinkResolver:
    def __init__(self, doc: Doc, links: dict, refdefs: dict, self_name: str | None = None):
        self.self_name = self_name
        self.doc = doc
        self.links = links or {}
        self.refdefs = refdefs

    def resolve(self, key: str):
        """`api:` target for an intra-doc link key, `""` for a known link to
        something outside this crate, None when the key is not a link."""
        item_id = self.links.get(key)
        if item_id is None and key in self.refdefs:
            item_id = self.links.get(self.refdefs[key])
        if item_id is None:
            return None
        target = self.doc.item(item_id)
        path = self.doc.path_of(item_id)
        if target is None and path is None:
            return ""  # a member of another crate's item, e.g. `Iterator::max`
        crate_id = (target or path or {}).get("crate_id", 0)
        if crate_id != 0:
            return ""
        # The binding's spelling: the item's own name. A method, field or
        # variant is not in rustdoc's `paths` table and is shown as
        # `Type::member`, taken from the link text; the renderer prints a
        # spelling it has no page for as plain code.
        if path:
            segments = path["path"]
            member = path.get("kind") in (
                "variant",
                "struct_field",
                "method",
                "assoc_const",
                "assoc_type",
            )
            if member or tuple(segments[:-1]) in self.doc.type_paths:
                return "api:" + "::".join(segments[-2:])
            return f"api:{segments[-1]}"
        text = re.sub(
            r"^(fn|struct|enum|trait|type|const|constant|static|mod|macro|method|field|variant|tymethod)@",
            "",
            key.strip("`"),
        )
        text = text.rstrip("!").removesuffix("()")
        segments = [
            self.self_name if seg == "Self" and self.self_name else seg for seg in text.split("::")
        ]
        segments = [seg for seg in segments if seg not in ("crate", "self", "super", "Self")]
        if not segments:
            return f"api:{target['name']}" if target and target.get("name") else ""
        return "api:" + "::".join(segments[-2:])


INLINE_CODE_RE = re.compile(r"(`+)([^`][\s\S]*?)\1(?!`)")


def convert_links(text: str, resolver: LinkResolver) -> str:
    """Rewrite intra-doc links in one line of prose (outside code spans)."""
    # Split out code spans so their brackets are never touched, except where
    # a code span is itself the label of a link: `[`Foo`]` is handled by
    # treating the whole `[...]` group as one unit first.
    out = []
    i = 0
    n = len(text)
    while i < n:
        ch = text[i]
        if ch == "`":
            m = INLINE_CODE_RE.match(text, i)
            if m:
                out.append(m.group(0))
                i = m.end()
                continue
        if ch == "[":
            close = find_label_end(text, i)
            if close is not None:
                label = text[i + 1 : close]
                rest = text[close + 1 :]
                # [label](dest)
                if rest.startswith("("):
                    dest_end = rest.find(")")
                    if dest_end != -1:
                        dest = rest[1:dest_end].strip()
                        if not re.match(
                            r"^[a-z][a-z0-9+.-]*://|^mailto:|^#|^/|.*\.(md|html)(#.*)?$", dest
                        ):
                            target = resolver.resolve(dest)
                            out.append(render_link(label, target, dest))
                            i = close + 1 + dest_end + 1
                            continue
                        out.append(f"[{label}]({dest})")
                        i = close + 1 + dest_end + 1
                        continue
                # [label][key]
                if rest.startswith("["):
                    key_end = find_label_end(rest, 0)
                    if key_end is not None:
                        key = rest[1:key_end] or label
                        target = resolver.resolve(key)
                        if target is not None:
                            out.append(render_link(label, target, key))
                            i = close + 1 + key_end + 1
                            continue
                # [key] shortcut; `[key]: dest` at the start of a line is a
                # reference definition, already taken out by convert_doc.
                at_line_start = re.search(r"(^|\n) {0,3}$", text[:i]) is not None
                if not (rest.startswith(":") and at_line_start):
                    target = resolver.resolve(label)
                    if target is not None:
                        out.append(render_link(label, target, label))
                        i = close + 1
                        continue
                    if re.fullmatch(r"`[^`]+`", label):
                        # Rustdoc could not resolve it: keep the code, drop the link.
                        out.append(label)
                        i = close + 1
                        continue
        out.append(ch)
        i += 1
    return "".join(out)


def find_label_end(text: str, start: int):
    """Index of the `]` matching the `[` at `start`, skipping code spans."""
    depth = 0
    i = start
    while i < len(text):
        c = text[i]
        if c == "`":
            m = INLINE_CODE_RE.match(text, i)
            if m:
                i = m.end()
                continue
        if c == "[":
            depth += 1
        elif c == "]":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return None


def render_link(label: str, target, dest: str) -> str:
    if target:
        return f"[{label}]({target})"
    # Outside this crate (std, a dependency) or unresolvable: plain code.
    if re.fullmatch(r"`[^`]+`", label):
        return label
    if target is None and dest == label:
        return f"`{label}`"
    return label


def convert_doc(doc: Doc, raw: str | None, links: dict, self_name: str | None = None) -> str | None:
    if raw is None or not raw.strip():
        return None
    lines = raw.split("\n")
    refdefs = {}
    kept = []
    in_fence = False
    for line in lines:
        if FENCE_RE.match(line):
            in_fence = not in_fence
        if not in_fence:
            m = REFDEF_RE.match(line)
            if m and not re.match(r"^[a-z][a-z0-9+.-]*://", m.group(2)):
                refdefs[m.group(1)] = m.group(2)
                continue
        kept.append(line)
    resolver = LinkResolver(doc, links, refdefs, self_name)

    out = []
    prose: list[str] = []  # consecutive prose lines, converted together so a
    # code span that wraps across lines is still recognized as one span

    def flush():
        if prose:
            out.append(convert_links("\n".join(prose), resolver))
            prose.clear()

    fence = None  # (marker, is_rust, indent)
    for line in kept:
        m = FENCE_RE.match(line)
        if fence is None and m:
            flush()
            marker, info = m.group(2), m.group(3)
            rust = is_rust_fence(info)
            fence = (marker, rust, m.group(1))
            out.append(f"{m.group(1)}{marker}{'rust' if rust else info.strip()}")
            continue
        if fence is not None:
            if m and m.group(2).startswith(fence[0][:3]) and not m.group(3).strip():
                out.append(line)
                fence = None
                continue
            if fence[1]:
                body = line[len(fence[2]) :] if line.startswith(fence[2]) else line
                stripped = body.lstrip()
                # Rustdoc hides `# ` lines in Rust examples; `##` escapes a `#`.
                if stripped == "#" or stripped.startswith("# "):
                    continue
                if stripped.startswith("##"):
                    line = line.replace("##", "#", 1)
            out.append(line)
            continue
        h = HEADING_RE.match(line)
        if h:
            flush()
            out.append(f"**{convert_links(h.group(2), resolver)}**")
            continue
        if not line.strip():
            flush()
            out.append(line)
            continue
        prose.append(line)
    flush()
    return "\n".join(out).strip("\n")


# ---------------------------------------------------------------------------
# The crate root and the manifest
# ---------------------------------------------------------------------------


def attr_text(attrs) -> str:
    parts = []
    for a in attrs or []:
        if isinstance(a, str):
            parts.append(a)
        elif isinstance(a, dict):
            parts.append(json.dumps(a))
    return " ".join(parts)


def required_features(*attr_lists) -> set[str]:
    text = " ".join(attr_text(a) for a in attr_lists)
    feats = set(re.findall(r'feature\s*=\s*\\?"([\w-]+)\\?"', text))
    feats |= set(re.findall(r'name:\s*\\?"feature\\?",\s*value:\s*Some\(\\?"([\w-]+)\\?"\)', text))
    return feats


def public_modules(doc: Doc) -> set[tuple]:
    root = doc.item(doc.data["root"])
    seen = set()

    def walk(module, prefix):
        for mid in module["inner"]["module"]["items"]:
            m = doc.item(mid)
            if m and kind_of(m) == "module" and m.get("visibility") == "public":
                path = prefix + (m["name"],)
                seen.add(path)
                walk(m, path)

    walk(root, (root["name"],))
    return seen


def root_entries(doc: Doc) -> dict[str, list[tuple[dict, dict]]]:
    """name -> [(root item, resolved target item)] for every root export."""
    root = doc.item(doc.data["root"])
    out: dict[str, list] = {}
    for item_id in root["inner"]["module"]["items"]:
        item = doc.item(item_id)
        k = kind_of(item)
        if k in ("use", "import"):
            use = item["inner"][k]
            if use.get("is_glob", use.get("glob")):
                continue
            target = doc.item(use.get("id"))
            out.setdefault(use["name"], []).append((item, target, use.get("id")))
        else:
            out.setdefault(item["name"], []).append((item, item, item_id))
    return out


def pick(candidates, manifest_kind: str):
    """Choose among same-named root exports by the manifest's kind."""
    want_fn = manifest_kind == "function"
    want_const = manifest_kind == "constant"
    for root_item, target, tid in candidates:
        if target is None:
            continue
        k = kind_of(target)
        if want_fn and k == "function":
            return root_item, target, tid
        if want_const and k in ("constant", "static"):
            return root_item, target, tid
        if (
            not want_fn
            and not want_const
            and k in ("struct", "enum", "trait", "type_alias", "union")
        ):
            return root_item, target, tid
    return candidates[0] if candidates and candidates[0][1] is not None else (None, None, None)


def native_url(
    doc: Doc, root_item: dict, target: dict, tid, name: str, pub_mods: set
) -> str | None:
    feats = required_features(root_item.get("attrs"), target.get("attrs"))
    if feats - DOCS_RS_FEATURES:
        return None
    prefix = URL_PREFIX.get(kind_of(target))
    if prefix is None:
        return None
    # Rustdoc inlines a re-export of an item whose module is private, so its
    # page sits at the crate root. An item in a public module keeps its page
    # there, and the root shows a re-export line.
    module = ("earthsci_ast",)
    path = doc.path_of(tid)
    if path and tuple(path["path"][:-1]) in pub_mods:
        module = tuple(path["path"][:-1])
    if "doc(inline)" in attr_text(root_item.get("attrs")) or "Inline" in attr_text(
        root_item.get("attrs")
    ):
        module = ("earthsci_ast",)
    return DOCS_RS_ROOT + "/".join(module) + f"/{prefix}.{name}.html"


def feature_note(root_item: dict, target: dict) -> str | None:
    feats = sorted(
        required_features(root_item.get("attrs"), target.get("attrs")) - DOCS_RS_FEATURES
    )
    if not feats:
        return None
    names = " and ".join(f"`{f}`" for f in feats)
    plural = "features" if len(feats) > 1 else "feature"
    return f"*Available with the {names} Cargo {plural}, which is off by default.*"


def deprecation_note(target: dict) -> str | None:
    dep = target.get("deprecation")
    if not dep:
        return None
    since = f" since {dep['since']}" if dep.get("since") else ""
    note = f": {dep['note']}" if dep.get("note") else ""
    return f"**Deprecated**{since}{note}"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--rustdoc-json", required=True, type=Path)
    ap.add_argument("--manifest", required=True, type=Path)
    ap.add_argument("--cargo-toml", required=True, type=Path)
    ap.add_argument(
        "--extractor", required=True, help="toolchain description for the `extractor` field"
    )
    ap.add_argument("--out", required=True, type=Path)
    args = ap.parse_args()

    doc = Doc(json.loads(args.rustdoc_json.read_text()))
    if doc.version not in TESTED_FORMAT_VERSIONS:
        print(
            f"rust_extract: rustdoc JSON format_version {doc.version} is untested "
            f"(tested: {sorted(TESTED_FORMAT_VERSIONS)}); check the output.",
            file=sys.stderr,
        )
    manifest = json.loads(args.manifest.read_text())
    version = re.search(r'^version\s*=\s*"([^"]+)"', args.cargo_toml.read_text(), re.M).group(1)

    spellings = []
    for sym in manifest["symbols"]:
        b = sym["bindings"].get("rust")
        if b is None:
            continue
        for s in b if isinstance(b, list) else [b]:
            spellings.append((s, sym["kind"], sym["name"], sym["tier"]))

    entries = root_entries(doc)
    pub_mods = public_modules(doc)
    symbols = []
    missing_docs = []
    for spelling, kind, canonical, tier in spellings:
        root_item, target, tid = pick(entries.get(spelling, []), kind)
        if target is None:
            symbols.append(
                {
                    "spelling": spelling,
                    "kind": kind,
                    "signatures": [],
                    "doc": None,
                    "source": None,
                    "native_url": None,
                    "missing": True,
                }
            )
            missing_docs.append((tier, canonical, spelling, "not found"))
            continue
        sigs = [declaration(doc, target, spelling)] + inherent_methods(doc, target, spelling)
        body = convert_doc(doc, target.get("docs"), target.get("links"), spelling)
        # A re-export can carry its own doc comment; append it when present.
        if root_item is not target and root_item.get("docs"):
            extra = convert_doc(doc, root_item["docs"], root_item.get("links"), spelling)
            body = f"{body}\n\n{extra}" if body else extra
        if body is None:
            missing_docs.append((tier, canonical, spelling, "no doc comment"))
        else:
            notes = [n for n in (deprecation_note(target), feature_note(root_item, target)) if n]
            if notes:
                body = "\n\n".join(notes + [body])
        span = target.get("span") or root_item.get("span")
        source = None
        if span:
            source = {"path": f"{CRATE_DIR}/{span['filename']}", "line": span["begin"][0]}
        symbols.append(
            {
                "spelling": spelling,
                "kind": kind,
                "signatures": sigs,
                "doc": body,
                "source": source,
                "native_url": native_url(doc, root_item, target, tid, spelling, pub_mods),
            }
        )

    out = {
        "binding": "rust",
        "package_version": version,
        "extractor": f"{args.extractor}, format_version {doc.version}",
        "symbols": symbols,
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(out, indent=2, ensure_ascii=False) + "\n")

    with_doc = sum(1 for s in symbols if s["doc"] is not None)
    print(
        f"rust_extract: {len(symbols)} spellings, {with_doc} with docs, "
        f"{len(symbols) - with_doc} without, -> {args.out}"
    )
    stable_gaps = [m for m in missing_docs if m[0] == "stable"]
    if stable_gaps:
        print(f"rust_extract: {len(stable_gaps)} stable-tier spellings have no docs:")
        for _, canonical, spelling, why in stable_gaps:
            print(f"  {spelling} ({canonical}): {why}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
