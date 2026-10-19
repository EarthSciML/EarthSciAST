#!/usr/bin/env python3
"""Render the cross-language API reference into docs/content/generated/api/.

Joins four inputs (see docs/api/README.md):

  api-surface.json               canonical names, tiers, per-binding spellings
  build/api-docs/<binding>.json  normalized docstrings, one file per binding
  docs/api/examples/<binding>/   example programs with tagged regions
  docs/api/groups.toml           topic grouping of the stable operations

and the usage guides in docs/api/guides/, whose example placeholders it fills.
A missing <binding>.json is not an error: that binding's tabs say it was not
extracted in this build. Problems that would publish a wrong page (a bad
region, an unknown name in groups.toml, a malformed docstring file) are
errors and exit non-zero.

Usage, from the repository root (Python 3.11 or newer, standard library only):

    python3 scripts/api_docs/render.py
    python3 scripts/api_docs/render.py --api-docs build/api-docs --out docs/content/generated/api
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

try:
    import tomllib
except ModuleNotFoundError:  # Python < 3.11
    sys.exit("render.py needs Python 3.11 or newer (for tomllib)")

sys.path.insert(0, str(Path(__file__).resolve().parent))
import regions as regions_mod  # noqa: E402

BINDINGS = ("julia", "typescript", "python", "rust", "go")
LABEL = {
    "julia": "Julia",
    "typescript": "TypeScript",
    "python": "Python",
    "rust": "Rust",
    "go": "Go",
}
FENCE_LANG = {b: b for b in BINDINGS}
PROFILE_LABEL = {
    "core": "core",
    "classification": "classification",
    "simulation": "simulation",
    "runtime_io": "runtime I/O",
}
DEFAULT_REPO_URL = "https://github.com/EarthSciML/EarthSciAST"

# Content paths. Links are written as site content paths ("/generated/api/...")
# so the layouts' render-link hook resolves them to permalinks under any base URL.
SITE_ROOT = "/generated/api"

PLACEHOLDER_RE = re.compile(r"^\s*<!--\s*example:\s*(?P<id>[A-Za-z0-9_.-]+)(?P<opts>(?:\s+\w+=\S+)*)\s*-->\s*$")
API_LINK_RE = re.compile(r"\[(?P<text>[^\]\n]*)\]\(api:(?P<target>[^)\s]+)\)")
FENCE_RE = re.compile(r"^\s{0,3}(`{3,}|~{3,})")
ATX_RE = re.compile(r"^(\s{0,3})(#{1,6})(\s+|$)")
CODE_SPAN_RE = re.compile(r"(`+)(.+?)\1", re.S)
AUTOLINK_RE = re.compile(r"<(https?://[^>\s]+|mailto:[^>\s]+)>")


class RenderError(Exception):
    pass


@dataclass
class Diagnostics:
    errors: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)

    def error(self, msg: str) -> None:
        self.errors.append(msg)

    def warn(self, msg: str) -> None:
        self.warnings.append(msg)


# --------------------------------------------------------------------------
# Inputs
# --------------------------------------------------------------------------


@dataclass
class Symbol:
    name: str
    kind: str
    tier: str
    bindings: dict[str, list[str]]
    notes: str = ""
    slug: str = ""
    group: str = ""

    @property
    def key(self) -> tuple[str, str]:
        return (self.name, self.kind)

    @property
    def page(self) -> str:
        return f"{SITE_ROOT}/ref/{self.slug}"

    @property
    def title(self) -> str:
        return self.name if self.slug == self.name else f"{self.name} ({self.kind})"


@dataclass
class BindingDocs:
    binding: str
    present: bool
    package_version: str = ""
    extractor: str = ""
    by_key: dict[tuple[str, str], dict] = field(default_factory=dict)
    by_spelling: dict[str, dict] = field(default_factory=dict)

    def lookup(self, spelling: str, kind: str) -> dict | None:
        return self.by_key.get((spelling, kind)) or self.by_spelling.get(spelling)


@dataclass
class Group:
    id: str
    title: str
    description: str
    profile: str | None
    members: list[Symbol] = field(default_factory=list)

    @property
    def page(self) -> str:
        return f"{SITE_ROOT}/topics/{self.id}"


def load_surface(root: Path) -> tuple[dict, list[Symbol]]:
    surface = json.loads((root / "api-surface.json").read_text(encoding="utf-8"))
    symbols = []
    for raw in surface["symbols"]:
        spellings = {}
        for b, sp in raw["bindings"].items():
            spellings[b] = list(sp) if isinstance(sp, list) else [sp]
        symbols.append(
            Symbol(raw["name"], raw["kind"], raw["tier"], spellings, raw.get("notes", ""))
        )
    stable = [s for s in symbols if s.tier == "stable"]
    names: dict[str, int] = {}
    for s in stable:
        names[s.name] = names.get(s.name, 0) + 1
    for s in stable:
        s.slug = s.name if names[s.name] == 1 else f"{s.name}-{s.kind}"
    return surface, symbols


def load_binding_docs(api_docs: Path, binding: str, diag: Diagnostics) -> BindingDocs:
    path = api_docs / f"{binding}.json"
    if not path.is_file():
        diag.warn(f"{path}: not found; {LABEL[binding]} renders as not extracted in this build")
        return BindingDocs(binding, present=False)
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        diag.error(f"{path}: not valid JSON: {exc}")
        return BindingDocs(binding, present=False)
    if data.get("binding") != binding:
        diag.error(f"{path}: \"binding\" is {data.get('binding')!r}, expected {binding!r}")
    docs = BindingDocs(
        binding,
        present=True,
        package_version=str(data.get("package_version") or ""),
        extractor=str(data.get("extractor") or ""),
    )
    for i, sym in enumerate(data.get("symbols", [])):
        spelling = sym.get("spelling")
        if not isinstance(spelling, str):
            diag.error(f"{path}: symbols[{i}] has no string \"spelling\"")
            continue
        docs.by_key.setdefault((spelling, sym.get("kind", "")), sym)
        docs.by_spelling.setdefault(spelling, sym)
    return docs


def load_groups(root: Path, stable: list[Symbol], surface: dict, diag: Diagnostics) -> list[Group]:
    path = root / "docs" / "api" / "groups.toml"
    data = tomllib.loads(path.read_text(encoding="utf-8"))
    by_name: dict[str, list[Symbol]] = {}
    for s in stable:
        by_name.setdefault(s.name, []).append(s)
    groups: list[Group] = []
    seen_ids: set[str] = set()
    for g in data.get("group", []):
        gid = g.get("id", "")
        if not gid or gid in seen_ids or gid in ("other",):
            diag.error(f"{path}: group id {gid!r} is missing, repeated or reserved")
            continue
        seen_ids.add(gid)
        profile = g.get("profile")
        if profile is not None and profile not in surface["capability_profiles"]:
            diag.error(f"{path}: group {gid!r} names unknown profile {profile!r}")
            profile = None
        group = Group(gid, g.get("title", gid), g.get("description", ""), profile)
        for op in g.get("ops", []):
            name, _, kind = op.partition(":")
            matches = [s for s in by_name.get(name, []) if not kind or s.kind == kind]
            if not matches:
                diag.error(f"{path}: group {gid!r} lists {op!r}, which is not a stable canonical name")
                continue
            for s in matches:
                if s.group:
                    diag.error(f"{path}: {s.name} ({s.kind}) is in both {s.group!r} and {gid!r}")
                    continue
                s.group = gid
                group.members.append(s)
        groups.append(group)
    other = [s for s in stable if not s.group]
    if other:
        og = Group("other", "Other", "Stable operations not yet placed in a topic.", None)
        for s in other:
            s.group = "other"
            og.members.append(s)
        groups.append(og)
        diag.warn(
            f"{path}: {len(other)} stable symbol(s) in no group, rendered under Other: "
            + ", ".join(f"{s.name} ({s.kind})" for s in other)
        )
    return groups


# --------------------------------------------------------------------------
# Markdown helpers
# --------------------------------------------------------------------------


def yaml_str(s: str) -> str:
    return json.dumps(s, ensure_ascii=False)


def front_matter(**fields) -> str:
    lines = ["---"]
    for k, v in fields.items():
        if v is None:
            continue
        if isinstance(v, bool):
            lines.append(f"{k}: {'true' if v else 'false'}")
        elif isinstance(v, int):
            lines.append(f"{k}: {v}")
        else:
            lines.append(f"{k}: {yaml_str(str(v))}")
    lines.append("---")
    return "\n".join(lines) + "\n\n"


def code(s: str) -> str:
    """An inline code span that survives backticks in ``s``."""
    run = max((len(m) for m in re.findall(r"`+", s)), default=0)
    ticks = "`" * (run + 1)
    pad = " " if s.startswith("`") or s.endswith("`") else ""
    return f"{ticks}{pad}{s}{pad}{ticks}"


def fence(body: str, lang: str = "") -> str:
    run = max((len(m) for m in re.findall(r"`{3,}", body)), default=2)
    ticks = "`" * max(3, run + 1)
    return f"{ticks}{lang}\n{body.rstrip()}\n{ticks}\n"


def table_cell(s: str) -> str:
    return s.replace("|", "\\|").replace("\n", " ")


def _escape_html_outside_code(line: str) -> str:
    """Escape ``<`` outside code spans, so ``Vec<T>`` in prose stays text.

    Docstrings are written for each language's doc tool, not for a site that
    renders raw HTML; a stray ``<div`` would break the tab layout around it.
    """
    out = []
    pos = 0
    for m in CODE_SPAN_RE.finditer(line):
        out.append(_escape_lt(line[pos : m.start()]))
        out.append(m.group(0))
        pos = m.end()
    out.append(_escape_lt(line[pos:]))
    return "".join(out)


def _escape_lt(text: str) -> str:
    keep = {}

    def stash(m):
        keep[len(keep)] = m.group(0)
        return f"\x00{len(keep) - 1}\x00"

    text = AUTOLINK_RE.sub(stash, text)
    text = text.replace("<", "&lt;")
    return re.sub(r"\x00(\d+)\x00", lambda m: keep[int(m.group(1))], text)


def clean_doc(doc: str, resolve) -> str:
    """Prepare a docstring for embedding in a reference page.

    Resolves ``api:`` links, demotes headings below the page's own, escapes raw
    HTML in prose and closes an unterminated code fence.
    """
    lines = doc.replace("\r\n", "\n").strip("\n").split("\n")
    out: list[str] = []
    in_fence: str | None = None
    for line in lines:
        m = FENCE_RE.match(line)
        if in_fence is not None:
            out.append(line)
            if m and m.group(1)[0] == in_fence[0] and len(m.group(1)) >= len(in_fence) and not line.strip()[len(m.group(1)) :].strip():
                in_fence = None
            continue
        if m:
            in_fence = m.group(1)
            out.append(line)
            continue
        h = ATX_RE.match(line)
        if h:
            line = f"{h.group(1)}#### {line[h.end():]}".rstrip() if line[h.end():].strip() else line
        line = API_LINK_RE.sub(lambda mm: resolve(mm.group("text"), mm.group("target")), line)
        out.append(_escape_html_outside_code(line))
    if in_fence is not None:
        out.append(in_fence)
    text = "\n".join(out)
    # Hugo would read these as shortcode calls.
    return text.replace("{{<", "{{&lt;").replace("{{%", "{{&#37;")


def first_sentence(doc: str | None, limit: int = 180) -> str:
    if not doc:
        return ""
    para = []
    for line in doc.strip().split("\n"):
        if not line.strip():
            if para:
                break
            continue
        if FENCE_RE.match(line) or line.lstrip().startswith(("#", "**", "- ", "* ", "|", ">")):
            if para:
                break
            continue
        para.append(line.strip())
    text = " ".join(para)
    text = API_LINK_RE.sub(lambda m: m.group("text"), text)
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)
    m = re.search(r"(?<=[.!?])\s", text)
    if m:
        text = text[: m.start()]
    if len(text) > limit:
        text = text[: limit - 1].rsplit(" ", 1)[0] + "…"
    return _escape_html_outside_code(text)


# --------------------------------------------------------------------------
# The renderer
# --------------------------------------------------------------------------


class Renderer:
    def __init__(self, args, diag: Diagnostics):
        self.root: Path = args.root.resolve()
        self.out: Path = (args.out if args.out.is_absolute() else self.root / args.out)
        self.diag = diag
        self.repo_url = args.repo_url.rstrip("/")
        self.sha = args.sha or self._git_sha()
        self.surface, self.symbols = load_surface(self.root)
        self.stable = [s for s in self.symbols if s.tier == "stable"]
        self.extension = [s for s in self.symbols if s.tier == "extension"]
        self.profiles = self.surface["capability_profiles"]
        api_docs = args.api_docs if args.api_docs.is_absolute() else self.root / args.api_docs
        self.docs = {b: load_binding_docs(api_docs, b, diag) for b in BINDINGS}
        self.groups = load_groups(self.root, self.stable, self.surface, diag)
        self.group_by_id = {g.id: g for g in self.groups}
        ex_dir = args.examples_dir
        if ex_dir is not None and not ex_dir.is_absolute():
            ex_dir = self.root / ex_dir
        canonical = {s.name for s in self.symbols}
        extracted = regions_mod.extract(self.root, BINDINGS, canonical, examples_dir=ex_dir)
        for e in extracted.errors:
            diag.error(f"example region: {e}")
        self.regions = extracted.regions
        self.region_by_id: dict[str, dict[str, regions_mod.Region]] = {}
        for r in self.regions:
            self.region_by_id.setdefault(r.id, {})[r.binding] = r
        self.guides_dir = self.root / "docs" / "api" / "guides"
        self._build_link_maps()
        self._check_manifest_coverage()

    # ---- setup -----------------------------------------------------------

    def _git_sha(self) -> str:
        try:
            return subprocess.run(
                ["git", "rev-parse", "HEAD"],
                cwd=self.root,
                check=True,
                capture_output=True,
                text=True,
            ).stdout.strip()
        except (OSError, subprocess.CalledProcessError):
            self.diag.warn("could not read the git commit; source links point at main")
            return "main"

    def _build_link_maps(self) -> None:
        self.ext_anchor: dict[tuple[str, str, str], str] = {}
        self.link_map: dict[str, dict[str, str]] = {b: {} for b in BINDINGS}
        for s in sorted(self.stable, key=lambda s: (s.kind != "function", s.name)):
            for b, spellings in s.bindings.items():
                for sp in spellings:
                    self.link_map[b].setdefault(sp, s.page)
        for b in BINDINGS:
            used: set[str] = set()
            for s in sorted(self.extension, key=lambda s: s.name):
                for sp in s.bindings.get(b, []):
                    base = "x-" + re.sub(r"[^A-Za-z0-9_-]+", "-", sp).strip("-").lower()
                    anchor = base
                    n = 2
                    while anchor in used:
                        anchor = f"{base}-{n}"
                        n += 1
                    used.add(anchor)
                    self.ext_anchor[(b, sp, s.kind)] = anchor
                    self.link_map[b].setdefault(sp, f"{SITE_ROOT}/extension/{b}#{anchor}")

    def _check_manifest_coverage(self) -> None:
        for b in BINDINGS:
            docs = self.docs[b]
            if not docs.present:
                continue
            absent = [
                sp
                for s in self.symbols
                for sp in s.bindings.get(b, [])
                if docs.lookup(sp, s.kind) is None
            ]
            if absent:
                self.diag.warn(
                    f"{b}.json leaves out {len(absent)} manifest spelling(s) (the contract wants "
                    f"an entry with \"missing\": true): {', '.join(absent[:12])}"
                    + (" …" if len(absent) > 12 else "")
                )

    # ---- small pieces ----------------------------------------------------

    def resolver(self, binding: str):
        def resolve(text: str, target: str) -> str:
            url = self.link_map[binding].get(target)
            shown = text if text.startswith("`") else code(text or target)
            return f"[{shown}]({url})" if url else shown

        return resolve

    def source_link(self, path: str, line: int | None = None, end: int | None = None) -> str:
        url = f"{self.repo_url}/blob/{self.sha}/{path}"
        if line:
            url += f"#L{line}"
            if end and end != line:
                url += f"-L{end}"
        return url

    def profile_gap(self, binding: str, profile: str | None) -> str | None:
        """Why ``binding`` lacks an operation of ``profile``, or None."""
        if not profile or profile not in self.profiles:
            return None
        members = self.profiles[profile]["bindings"]
        if binding in members:
            return None
        who = ", ".join(LABEL[m] for m in members)
        summary = self.profiles[profile]["summary"]
        return (
            f"{LABEL[binding]} is outside the {PROFILE_LABEL.get(profile, profile)} "
            f"capability profile ({who}): {summary}."
        )

    def planned_note(self, sym: Symbol, binding: str) -> str | None:
        for p in self.surface.get("planned", []):
            if binding not in p.get("affects", []):
                continue
            if re.search(rf"(?<![A-Za-z0-9_]){re.escape(sym.name)}(?![A-Za-z0-9_])", p.get("canonical", "")):
                return p.get("resolution")
        return None

    def summary(self, sym: Symbol) -> str:
        for b in BINDINGS:
            for sp in sym.bindings.get(b, []):
                entry = self.docs[b].lookup(sp, sym.kind)
                if entry and entry.get("doc"):
                    s = first_sentence(entry["doc"])
                    if s:
                        return s
        return ""

    def availability_table(self, sym: Symbol, group: Group) -> str:
        head = "| " + " | ".join(LABEL[b] for b in BINDINGS) + " |\n"
        head += "|" + "---|" * len(BINDINGS) + "\n"
        cells = []
        for b in BINDINGS:
            sps = sym.bindings.get(b)
            if sps:
                cells.append(", ".join(code(sp) for sp in sps))
            elif self.profile_gap(b, group.profile):
                cells.append("outside profile")
            else:
                cells.append("not exported")
        return head + "| " + " | ".join(cells) + " |\n"

    def tabs(self, panels: list[tuple[str, str]], gaps: frozenset = frozenset()) -> str:
        """A language-tab group. ``panels`` is [(binding, markdown body)].

        Bindings in ``gaps`` hold only a note; the tab script does not open
        them by default when the reader's language has no panel.
        """
        parts = ['<div class="api-tabs">', ""]
        for b, body in panels:
            gap = ' data-gap="true"' if b in gaps else ""
            parts.append(f'<div class="api-tab" data-lang="{b}" data-label="{LABEL[b]}"{gap}>')
            parts.append(f'<p class="api-tab-label">{LABEL[b]}</p>')
            parts.append("")
            parts.append(body.strip("\n"))
            parts.append("")
            parts.append("</div>")
            parts.append("")
        parts.append("</div>")
        return "\n".join(parts) + "\n"

    def region_block(self, r: regions_mod.Region) -> str:
        link = self.source_link(r.path, r.start_line, r.end_line)
        return fence(r.code, FENCE_LANG[r.binding]) + (
            f'\n<p class="api-src">From <a href="{link}">{r.path}</a></p>\n'
        )

    # ---- pages -----------------------------------------------------------

    def write(self, rel: str, text: str) -> None:
        path = self.out / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        self.pages_written += 1

    def render(self) -> None:
        if self.out.exists():
            shutil.rmtree(self.out)
        self.pages_written = 0
        guides = self.render_guides()
        self.render_landing(guides)
        self.render_ref_index()
        for g in self.groups:
            self.render_group(g)
        for s in self.stable:
            self.render_symbol(s)
        self.render_binding_indexes()
        for b in BINDINGS:
            self.render_extension(b)
        self.render_coverage()

    def render_landing(self, guides: list[tuple[str, str, str]]) -> None:
        md = [
            front_matter(
                title="API reference",
                description="Every stable operation of the five EarthSciAST bindings, side by side.",
                type="api",
                api_tabs=True,
            )
        ]
        md.append(
            "EarthSciAST has five bindings — Julia, TypeScript, Python, Rust and Go — that "
            "read, check, transform and (in three of them) simulate the same `.esm` documents. "
            "This reference has one page per **stable** operation, with a tab for each binding "
            "showing its spelling, signatures and documentation, taken from the binding's own "
            "documentation tooling, along with runnable examples. The examples run in CI, so "
            "what is shown here is what the code does.\n"
        )
        md.append(
            "The surface has two tiers (see "
            f"[API_SPEC.md §3]({self.repo_url}/blob/main/API_SPEC.md#3-surface-tiers)). "
            "**Stable** names are harmonized across bindings and break only at a major version. "
            "**Extension** names are a binding's own documented seams; they may differ between "
            "bindings and may change in a minor release, and each binding lists them on one page.\n"
        )
        if guides:
            md.append("## Guides\n")
            for slug, title, desc in guides:
                md.append(f"- [{title}]({SITE_ROOT}/guides/{slug}) — {desc}" if desc else f"- [{title}]({SITE_ROOT}/guides/{slug})")
            md.append("")
        md.append("## Capability profiles\n")
        md.append(
            "Not every binding does everything. An operation missing from a binding outside "
            "its profile is by design, and the operation's page says so.\n"
        )
        md.append("| Profile | Covers | " + " | ".join(LABEL[b] for b in BINDINGS) + " |")
        md.append("|---|---|" + "---|" * len(BINDINGS))
        for pid, p in self.profiles.items():
            row = [PROFILE_LABEL.get(pid, pid), table_cell(p["summary"])]
            row += ["yes" if b in p["bindings"] else "—" for b in BINDINGS]
            md.append("| " + " | ".join(row) + " |")
        md.append("")
        md.append("## Topics\n")
        for g in self.groups:
            md.append(f"- [{g.title}]({g.page}) ({len(g.members)}) — {g.description}")
        md.append(f"\nOr browse [all stable operations A–Z]({SITE_ROOT}/ref).\n")
        md.append("## Bindings\n")
        md.append("| Binding | Package | Version | Docs from | Stable | Extension |")
        md.append("|---|---|---|---|---|---|")
        for b in BINDINGS:
            d = self.docs[b]
            pkg = self.surface["binding_profiles"].get(b, {}).get("package", "")
            n_st = sum(len(s.bindings.get(b, [])) for s in self.stable)
            n_ex = sum(len(s.bindings.get(b, [])) for s in self.extension)
            ver = d.package_version if d.present else "not extracted in this build"
            md.append(
                f"| [{LABEL[b]}]({SITE_ROOT}/bindings/{b}) | {code(pkg) if pkg else ''} | {table_cell(ver)} | "
                f"{table_cell(d.extractor)} | {n_st} | [{n_ex}]({SITE_ROOT}/extension/{b}) |"
            )
        md.append(
            f"\n[Documentation coverage]({SITE_ROOT}/coverage) lists the stable names each "
            "binding has not documented yet.\n"
        )
        self.write("_index.md", "\n".join(md))

    def render_ref_index(self) -> None:
        md = [
            front_matter(
                title="All stable operations",
                description="Every stable (name, kind) of the API surface, A–Z.",
                type="api",
            )
        ]
        md.append("| Operation | Kind | Topic | " + " | ".join(LABEL[b] for b in BINDINGS) + " |")
        md.append("|---|---|---|" + "---|" * len(BINDINGS))
        for s in sorted(self.stable, key=lambda s: (s.name, s.kind)):
            g = self.group_by_id[s.group]
            marks = ["yes" if s.bindings.get(b) else "—" for b in BINDINGS]
            md.append(f"| [{code(s.name)}]({s.page}) | {s.kind} | [{g.title}]({g.page}) | " + " | ".join(marks) + " |")
        self.write("ref/_index.md", "\n".join(md) + "\n")

    def render_group(self, g: Group) -> None:
        md = [front_matter(title=g.title, description=g.description, type="api")]
        if g.profile and g.profile != "core":
            members = ", ".join(LABEL[b] for b in self.profiles[g.profile]["bindings"])
            md.append(
                f"These operations belong to the **{PROFILE_LABEL.get(g.profile, g.profile)}** "
                f"capability profile: {members}.\n"
            )
        md.append("| Operation | Kind | Bindings | Summary |")
        md.append("|---|---|---|---|")
        order = {"function": 0, "type": 1, "error": 2, "constant": 3}
        for s in sorted(g.members, key=lambda s: (order.get(s.kind, 9), s.name)):
            who = ", ".join(LABEL[b] for b in BINDINGS if s.bindings.get(b))
            md.append(f"| [{code(s.name)}]({s.page}) | {s.kind} | {who} | {table_cell(self.summary(s))} |")
        md.append(f"\n[All topics]({SITE_ROOT})\n")
        self.write(f"topics/{g.id}.md", "\n".join(md))

    def symbol_panel(self, s: Symbol, b: str, group: Group) -> str:
        spellings = s.bindings.get(b, [])
        docs = self.docs[b]
        if not spellings:
            gap = self.profile_gap(b, group.profile)
            plan = self.planned_note(s, b)
            if gap:
                text = f"Not available in {LABEL[b]}. {gap}"
            else:
                text = f"{LABEL[b]} does not export this {s.kind}."
            if plan:
                text += f"\n\n**Planned:** {_escape_html_outside_code(plan)}"
            return f'<p class="api-absent">{text}</p>\n' if not plan else text + "\n"
        out: list[str] = []
        if len(spellings) > 1:
            out.append(
                "Exported as "
                + " and ".join(code(sp) for sp in spellings)
                + ". Both names refer to the same operation.\n"
            )
        if not docs.present:
            out.append(
                f'<p class="api-absent">{LABEL[b]} documentation was not extracted in this build.</p>\n'
            )
        resolve = self.resolver(b)
        examples = [r for r in self.regions if r.binding == b and s.name in r.ops]
        for sp in spellings:
            entry = docs.lookup(sp, s.kind) if docs.present else None
            if len(spellings) > 1:
                out.append(f"**{code(sp)}**\n")
            elif not entry or not entry.get("signatures"):
                out.append(f"{code(sp)}\n")
            if entry is None:
                if docs.present:
                    out.append('<p class="api-absent">Not found by the documentation extractor.</p>\n')
                continue
            if entry.get("missing"):
                out.append('<p class="api-absent">Not found by the documentation extractor.</p>\n')
            sigs = [x for x in entry.get("signatures") or [] if x]
            if sigs:
                sep = "\n\n" if any("\n" in x for x in sigs) else "\n"
                out.append(fence(sep.join(sigs), FENCE_LANG[b]))
            doc = entry.get("doc")
            if doc:
                out.append(clean_doc(doc, resolve) + "\n")
            elif not entry.get("missing"):
                out.append('<p class="api-absent">No docstring.</p>\n')
            links = []
            src = entry.get("source") or {}
            if src.get("path"):
                links.append(f"[Source]({self.source_link(src['path'], src.get('line'))})")
            if entry.get("native_url"):
                links.append(f"[{LABEL[b]} docs]({entry['native_url']})")
            if links:
                out.append(" · ".join(links) + "\n")
        for r in examples:
            out.append(f"**Example** ({code(r.id)})\n")
            out.append(self.region_block(r))
        return "\n".join(out)

    def render_symbol(self, s: Symbol) -> None:
        g = self.group_by_id[s.group]
        md = [
            front_matter(
                title=s.title,
                description=f"Stable {s.kind} · {g.title}",
                type="api",
                api_tabs=True,
            )
        ]
        md.append(f"**Tier:** stable · **Kind:** {s.kind} · **Topic:** [{g.title}]({g.page})\n")
        md.append(self.availability_table(s, g))
        if s.notes:
            md.append(f"\n**Note:** {_escape_html_outside_code(s.notes)}\n")
        md.append("")
        md.append(self.tabs([(b, self.symbol_panel(s, b, g)) for b in BINDINGS]))
        self.write(f"ref/{s.slug}.md", "\n".join(md))

    def render_binding_indexes(self) -> None:
        md = [front_matter(title="Bindings", description="Per-binding indexes of the API surface.", type="api")]
        for b in BINDINGS:
            md.append(f"- [{LABEL[b]}]({SITE_ROOT}/bindings/{b})")
        self.write("bindings/_index.md", "\n".join(md) + "\n")
        for b in BINDINGS:
            d = self.docs[b]
            prof = self.surface["binding_profiles"].get(b, {})
            md = [
                front_matter(
                    title=f"{LABEL[b]} API index",
                    description=f"Every stable name {LABEL[b]} exports, and its extension seams.",
                    type="api",
                )
            ]
            if prof.get("package"):
                md.append(f"**Package:** {code(prof['package'])}" + (f" {d.package_version}" if d.package_version else "") + "\n")
            if d.present:
                md.append(f"Documentation extracted with {d.extractor or 'the binding tooling'}.\n")
            else:
                md.append(f'<p class="api-absent">{LABEL[b]} documentation was not extracted in this build.</p>\n')
            caps = [PROFILE_LABEL.get(pid, pid) for pid, p in self.profiles.items() if b in p["bindings"]]
            md.append(f"**Capability profiles:** {', '.join(caps)}.\n")
            md.append(f"Extension-tier names are on the [{LABEL[b]} extension page]({SITE_ROOT}/extension/{b}).\n")
            md.append("## Stable names\n")
            md.append(f"| {LABEL[b]} | Canonical | Kind | Summary |")
            md.append("|---|---|---|---|")
            rows = []
            for s in self.stable:
                for sp in s.bindings.get(b, []):
                    entry = d.lookup(sp, s.kind) if d.present else None
                    summ = first_sentence(entry.get("doc")) if entry else ""
                    rows.append((sp.lower(), f"| {code(sp)} | [{code(s.name)}]({s.page}) | {s.kind} | {table_cell(summ)} |"))
            md.extend(r for _, r in sorted(rows))
            self.write(f"bindings/{b}.md", "\n".join(md) + "\n")

    def render_extension(self, b: str) -> None:
        d = self.docs[b]
        md = [
            front_matter(
                title=f"{LABEL[b]} extension seams",
                description=f"{LABEL[b]}'s extension-tier names: documented, reachable, not portable.",
                type="api",
            )
        ]
        md.append(
            "Extension-tier names are part of this binding's documented surface but are not "
            "harmonized across bindings, and may change in a minor release "
            f"([API_SPEC.md §7]({self.repo_url}/blob/main/API_SPEC.md#7-extension-seams)).\n"
        )
        if not d.present:
            md.append(f'<p class="api-absent">{LABEL[b]} documentation was not extracted in this build.</p>\n')
        if b == "rust":
            mods = self.surface["binding_profiles"]["rust"].get("public_modules", [])
            if mods:
                md.append(
                    "The interiors of these public modules are extension seams too: "
                    + ", ".join(code(f"earthsci_ast::{m}") for m in mods)
                    + ".\n"
                )
        entries = []
        for s in self.extension:
            for sp in s.bindings.get(b, []):
                entries.append((sp.lower(), sp, s))
        entries.sort(key=lambda e: (e[0], e[1]))
        if not entries:
            md.append("This binding has no extension-tier names.\n")
        md.append(f"{len(entries)} names.\n")
        resolve = self.resolver(b)
        for _, sp, s in entries:
            anchor = self.ext_anchor[(b, sp, s.kind)]
            md.append(f"### {code(sp)} {{#{anchor}}}\n")
            entry = d.lookup(sp, s.kind) if d.present else None
            meta = f"*{s.kind}* · canonical name {code(s.name)}"
            md.append(meta + "\n")
            if entry is None:
                continue
            sigs = [x for x in entry.get("signatures") or [] if x]
            if sigs:
                sep = "\n\n" if any("\n" in x for x in sigs) else "\n"
                md.append(fence(sep.join(sigs), FENCE_LANG[b]))
            if entry.get("doc"):
                md.append(clean_doc(entry["doc"], resolve) + "\n")
            links = []
            src = entry.get("source") or {}
            if src.get("path"):
                links.append(f"[Source]({self.source_link(src['path'], src.get('line'))})")
            if entry.get("native_url"):
                links.append(f"[{LABEL[b]} docs]({entry['native_url']})")
            if links:
                md.append(" · ".join(links) + "\n")
        self.write(f"extension/{b}.md", "\n".join(md))
        if b == BINDINGS[0]:
            idx = [front_matter(title="Extension seams", description="Each binding's extension-tier names.", type="api")]
            for bb in BINDINGS:
                idx.append(f"- [{LABEL[bb]}]({SITE_ROOT}/extension/{bb})")
            self.write("extension/_index.md", "\n".join(idx) + "\n")

    def render_coverage(self) -> None:
        md = [
            front_matter(
                title="Documentation coverage",
                description="Stable names each binding exports without a docstring.",
                type="api",
            )
        ]
        md.append("| Binding | Stable names | Documented | Without a docstring | Not found by the extractor |")
        md.append("|---|---|---|---|---|")
        sections = []
        for b in BINDINGS:
            d = self.docs[b]
            names = [(sp, s) for s in self.stable for sp in s.bindings.get(b, [])]
            if not d.present:
                md.append(f"| {LABEL[b]} | {len(names)} | not extracted in this build | | |")
                continue
            undocumented, missing = [], []
            for sp, s in names:
                e = d.lookup(sp, s.kind)
                if e is None or e.get("missing"):
                    missing.append((sp, s))
                elif not (e.get("doc") or "").strip():
                    undocumented.append((sp, s))
            documented = len(names) - len(undocumented) - len(missing)
            md.append(
                f"| [{LABEL[b]}](#{b}) | {len(names)} | {documented} | {len(undocumented)} | {len(missing)} |"
            )
            sec = [f"## {LABEL[b]} {{#{b}}}\n"]
            if not undocumented and not missing:
                sec.append("Every stable name is documented.\n")
            if undocumented:
                sec.append("**Without a docstring:** " + ", ".join(
                    f"[{code(sp)}]({s.page})" for sp, s in sorted(undocumented, key=lambda x: x[0].lower())
                ) + "\n")
            if missing:
                sec.append("**Not found by the extractor:** " + ", ".join(
                    f"[{code(sp)}]({s.page})" for sp, s in sorted(missing, key=lambda x: x[0].lower())
                ) + "\n")
            sections.append("\n".join(sec))
        md.append("")
        md.extend(sections)
        self.write("coverage.md", "\n".join(md) + "\n")

    # ---- guides ----------------------------------------------------------

    def example_tabs(self, rid: str, profile: str | None, where: str) -> str:
        have = self.region_by_id.get(rid, {})
        if not have:
            self.diag.warn(f"{where}: no binding has an example region {rid!r}")
            return f'<p class="api-absent">The {code(rid)} example is not available in this build.</p>\n'
        if profile is None:
            # The capability profile of the region: the most restrictive profile
            # among the groups of the operations it demonstrates.
            ops = {op for r in have.values() for op in r.ops}
            for s in self.stable:
                if s.name in ops:
                    gp = self.group_by_id[s.group].profile
                    if gp and gp != "core" and gp in self.profiles:
                        if profile is None or len(self.profiles[gp]["bindings"]) < len(self.profiles[profile]["bindings"]):
                            profile = gp
        panels = []
        gaps = set()
        for b in BINDINGS:
            r = have.get(b)
            if r is not None:
                panels.append((b, self.region_block(r)))
                continue
            gap = self.profile_gap(b, profile)
            if gap:
                panels.append((b, f'<p class="api-absent">No example: {gap}</p>\n'))
                gaps.add(b)
        return self.tabs(panels, frozenset(gaps))

    def render_guides(self) -> list[tuple[str, str, str]]:
        if not self.guides_dir.is_dir():
            return []
        found = []
        for path in sorted(self.guides_dir.glob("*.md")):
            text = path.read_text(encoding="utf-8")
            fm, body = _split_front_matter(text)
            weight = int(fm.get("weight", 100))
            found.append((weight, path, fm, body))
        found.sort(key=lambda t: (t[0], t[1].name))
        listing = []
        for weight, path, fm, body in found:
            slug = path.stem
            rel = path.relative_to(self.root).as_posix()
            lines = []
            in_fence = None
            for n, line in enumerate(body.split("\n"), start=1):
                m = FENCE_RE.match(line)
                if in_fence is not None:
                    if m and m.group(1)[0] == in_fence[0]:
                        in_fence = None
                    lines.append(line)
                    continue
                if m:
                    in_fence = m.group(1)
                    lines.append(line)
                    continue
                pm = PLACEHOLDER_RE.match(line)
                if pm:
                    opts = dict(o.split("=", 1) for o in pm.group("opts").split())
                    profile = opts.get("profile")
                    if profile is not None and profile not in self.profiles:
                        self.diag.error(f"{rel}:{n}: unknown profile {profile!r}")
                        profile = None
                    lines.append("")
                    lines.append(self.example_tabs(pm.group("id"), profile, f"{rel}:{n}"))
                    continue
                if line.strip().startswith("<!--") and "example:" in line:
                    self.diag.error(f"{rel}:{n}: malformed example placeholder: {line.strip()}")
                lines.append(line)
            title = fm.get("title", slug.replace("-", " ").capitalize())
            desc = fm.get("description", "")
            out = front_matter(title=title, description=desc or None, weight=weight, api_tabs=True)
            self.write(f"guides/{slug}.md", out + "\n".join(lines).strip("\n") + "\n")
            listing.append((slug, title, desc))
        idx = [front_matter(title="Guides", description="Using the EarthSciAST bindings, step by step, in every language.", type="api")]
        for slug, title, desc in listing:
            idx.append(f"- [{title}]({SITE_ROOT}/guides/{slug})" + (f" — {desc}" if desc else ""))
        self.write("guides/_index.md", "\n".join(idx) + "\n")
        return listing


def _split_front_matter(text: str) -> tuple[dict, str]:
    """Split a guide's YAML front matter of simple ``key: value`` lines."""
    if not text.startswith("---\n"):
        return {}, text
    end = text.find("\n---\n", 4)
    if end < 0:
        return {}, text
    fm = {}
    for line in text[4:end].split("\n"):
        if ":" in line and not line.startswith((" ", "#")):
            k, v = line.split(":", 1)
            v = v.strip()
            if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
                v = v[1:-1]
            fm[k.strip()] = v
    return fm, text[end + 5 :]


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", type=Path, default=Path.cwd(), help="repository root (default: cwd)")
    ap.add_argument("--api-docs", type=Path, default=Path("build/api-docs"), help="directory of <binding>.json files")
    ap.add_argument("--examples-dir", type=Path, default=None, help="examples directory (default: docs/api/examples)")
    ap.add_argument("--out", type=Path, default=Path("docs/content/generated/api"), help="output directory")
    ap.add_argument("--sha", default=None, help="commit for source links (default: git rev-parse HEAD)")
    ap.add_argument("--repo-url", default=DEFAULT_REPO_URL)
    ap.add_argument("--strict", action="store_true", help="treat warnings as errors")
    args = ap.parse_args(argv)

    diag = Diagnostics()
    renderer = Renderer(args, diag)
    if not diag.errors:
        renderer.render()
    for w in diag.warnings:
        print(f"warning: {w}", file=sys.stderr)
    for e in diag.errors:
        print(f"error: {e}", file=sys.stderr)
    if diag.errors or (args.strict and diag.warnings):
        return 1
    present = [LABEL[b] for b in BINDINGS if renderer.docs[b].present]
    print(
        f"wrote {renderer.pages_written} pages to {renderer.out} "
        f"(docs from: {', '.join(present) or 'none'}; {len(renderer.regions)} example regions)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
