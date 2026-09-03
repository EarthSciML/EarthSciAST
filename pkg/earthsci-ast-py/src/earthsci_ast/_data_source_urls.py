"""Load-time resolution of ``data_sources[*].source.url_template`` (esm-spec §8.2.1).

A ``url_template`` need not be an absolute URL. §8.2.1 resolves it to one at
load time, against the directory of the file the entry was read from — the same
base and the same timing rule §4.7 fixes for a ``ref``. That is what lets a
document name data that lives outside its own repository without carrying a
machine-specific absolute path.

Environment variables are deliberately NOT expanded here (§4.7 permits
``${VAR}`` in a ``ref``; §8.2 does not permit it at all), and a template that
needs one is REFUSED rather than passed through: a document reading ``${…}``
from the ambient environment does not say what it reads, the expanded value is
spliced into a URL that is then fetched, and an optional expansion capability
would make the same document resolve under one binding and not another. See
``docs/content/rfcs/portable-data-source-urls.md``.

The pass rewrites the RAW document, before schema validation and before typed
coercion, so every consumer — the typed ``DataSourceLocation``, the ingest
providers, ``emit`` — sees the resolved form without any of them having to
learn about a base directory. It is idempotent (its output is scheme-led), so
``parse → emit → parse`` is stable.
"""

from __future__ import annotations

import os
import posixpath
import re
from typing import Any

from .error_handling import DATA_SOURCE_URL_UNRESOLVED
from .json_walk import ExpressionTemplateError

__all__ = ["resolve_data_source_urls", "resolve_source_url"]

# esm-spec §8.2.1: a template is already a URL when it is scheme-led. The `://`
# is required (rather than a bare `scheme:`) so a Windows drive letter and a
# `{date:%Y}` substitution are both read as path text, not as a scheme.
_SCHEME_RE = re.compile(r"^[A-Za-z][A-Za-z0-9+.\-]*://")


def _remove_dot_segments(path: str) -> str:
    """RFC 3986 §5.2.4 dot-segment removal, lexically, on an absolute path.

    Never ``realpath``: a template carrying a ``{date:…}`` substitution names a
    file that need not exist at load time, and resolving symlinks would make
    the resolved URL depend on the filesystem rather than on the document.
    """
    out: list[str] = []
    for seg in path.split("/"):
        if seg in ("", "."):
            continue
        if seg == "..":
            if out:
                out.pop()
            continue
        out.append(seg)
    return "/" + "/".join(out)


def resolve_source_url(template: str, base_dir: str) -> str:
    """Resolve one ``url_template`` / ``mirrors`` entry per esm-spec §8.2.1.

    Raises :class:`ExpressionTemplateError` with code
    ``data_source_url_unresolved`` when the template cannot be resolved.
    """
    if "${" in template:
        raise ExpressionTemplateError(
            DATA_SOURCE_URL_UNRESOLVED,
            f"url template {template!r} carries an unexpanded '${{...}}' variable. "
            "esm-spec §8.2.1 does not expand environment variables into a data "
            "source's location: a document that reads one does not say what it "
            "reads, and the value is spliced into a URL that is then fetched. "
            "Write a path relative to this document instead (it resolves against "
            "the document's own directory), or symlink the data to that path.",
        )
    # Substitution-led: the author's own substitution supplies the location, so
    # there is no literal prefix to classify. §8.2 requires unrecognized
    # substitutions to be passed through, so this is left alone.
    if template.startswith("{"):
        return template
    if _SCHEME_RE.match(template):
        return template

    path = template if template.startswith("/") else posixpath.join(_abs_base(base_dir), template)
    resolved = _remove_dot_segments(path)
    if "?" in resolved or "#" in resolved:
        raise ExpressionTemplateError(
            DATA_SOURCE_URL_UNRESOLVED,
            f"url template {template!r} resolves to {resolved!r}, whose '?' or '#' "
            "would be read as a URL query or fragment rather than as part of the "
            "path (esm-spec §8.2.1). Rename or relocate the file.",
        )
    return "file://" + resolved


def _abs_base(base_dir: str) -> str:
    """``base_dir`` as an absolute POSIX directory.

    The loader's base may be relative (``load_path('fixtures/x.esm')`` gives
    ``fixtures``; ``load_string`` defaults to the working directory) and
    splicing a relative path after ``file://`` would silently make its first
    segment the URL HOST — the exact misresolution §8.2.1 exists to stop.
    """
    b = base_dir or "."
    if not b.startswith("/"):
        b = posixpath.join(os.getcwd().replace(os.sep, "/"), b)
    return b


def resolve_data_source_urls(data: Any, base_dir: str) -> None:
    """Resolve every ``data_sources[*].source`` location in ``data``.

    COPY-ON-WRITE, not in-place. ``load_document`` shallow-copies the caller's
    dict (so its own ``data.pop`` cannot be felt outside), which means
    ``data["data_sources"]`` is still the caller's object and its nested
    ``source`` dicts are shared. Rewriting one in place would resolve a
    location in a dict the caller still holds -- a side effect on an argument,
    and one that would make a second ``load_document`` of the same dict resolve
    an already-resolved URL against a different base. So a changed entry is
    rebuilt and only the top-level key -- which belongs to the copy -- is
    reassigned. Untouched when no location needs rewriting, which is every
    document whose templates are already absolute URLs.
    """
    if not isinstance(data, dict):
        return
    sources = data.get("data_sources")
    if not isinstance(sources, dict):
        return

    rebuilt: dict[str, Any] = {}
    changed = False
    for name, entry in sources.items():
        rebuilt[name] = entry
        if not isinstance(entry, dict):
            continue
        src = entry.get("source")
        if not isinstance(src, dict):
            continue

        new_src = dict(src)
        template = src.get("url_template")
        if isinstance(template, str):
            new_src["url_template"] = _resolved(
                template, base_dir, f"data_sources.{name}.source.url_template"
            )
        mirrors = src.get("mirrors")
        if isinstance(mirrors, list):
            new_src["mirrors"] = [
                _resolved(m, base_dir, f"data_sources.{name}.source.mirrors[{i}]")
                if isinstance(m, str)
                else m
                for i, m in enumerate(mirrors)
            ]
        if new_src == src:
            continue
        new_entry = dict(entry)
        new_entry["source"] = new_src
        rebuilt[name] = new_entry
        changed = True

    if changed:
        data["data_sources"] = rebuilt


def _resolved(template: str, base_dir: str, where: str) -> str:
    """:func:`resolve_source_url`, with the failure naming its document site.

    A resolution failure must name the entry AND the template: "io error at
    /${MOVES_SNAPSHOTS}/x.parquet" names neither, and a source whose location
    silently fails to resolve is indistinguishable from one that read zeros.
    """
    try:
        return resolve_source_url(template, base_dir)
    except ExpressionTemplateError as e:
        raise ExpressionTemplateError(
            DATA_SOURCE_URL_UNRESOLVED, f"{where}: {str(e).split('] ', 1)[-1]}"
        ) from None
