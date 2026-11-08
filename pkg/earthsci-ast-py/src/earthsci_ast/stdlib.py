"""Standard-library refs (esm-spec §4.7, "Standard-library references").

A ref spelled ``esm:std/<file>.esm`` resolves to this package's bundled copy of
the repository's ``lib/`` directory (``earthsci_ast/data/lib/``, written from
``lib/`` by ``scripts/sync-lib.sh``). The whole ``esm:`` scheme is reserved:
a ref beginning with ``esm:`` is never a relative path, an absolute path or a
URL. Here a standard-library ref is mapped to the absolute path of its bundled
file, so every §4.7 loader (subsystem mounts at both forms, template imports,
coupling imports) reads it with its ordinary local-file code, and the bundled
file's own directory anchors its relative refs among the bundled files. A name
the bundle does not contain, or any other ``esm:`` spelling, maps to a path
that cannot exist, so the mechanism's ordinary unresolved diagnostic fires.

This is a leaf module (stdlib only) so :mod:`earthsci_ast.json_walk` can use it.
"""

from __future__ import annotations

import os
import re

#: The bundled standard library. Module-level so tests can substitute a
#: directory of their own (``monkeypatch.setattr(stdlib, "STDLIB_DIR", ...)``).
STDLIB_DIR: str = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data", "lib")

STD_PREFIX = "esm:std/"
_NAME_RE = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_.-]*\.esm")


def is_std_ref(ref: str) -> bool:
    """True when ``ref`` is under the reserved ``esm:`` scheme."""
    return ref.startswith("esm:")


def _bundled_path(name: str, ref: str) -> str:
    """The bundled file ``name``, or a path that cannot exist when ``name`` is
    not a single library file name present in the bundle."""
    if _NAME_RE.fullmatch(name):
        path = os.path.join(STDLIB_DIR, name)
        if os.path.isfile(path):
            return path
    # The bundle holds only `*.esm` files, so nothing under `missing/` exists.
    # Slashes are flattened so a `..` in the ref cannot climb out of it.
    return os.path.join(STDLIB_DIR, "missing", ref.replace("/", "%2F"))


def std_ref_path(ref: str) -> str:
    """Map an ``esm:`` ref to its bundled file (or to a non-existent path)."""
    name = ref[len(STD_PREFIX) :] if ref.startswith(STD_PREFIX) else ""
    return _bundled_path(name, ref)


def in_bundle_ref_path(ref: str, base_dir: str | None) -> str | None:
    """A relative ``ref`` written INSIDE a bundled file (``base_dir`` is the
    bundle directory) names a sibling bundled file: leading ``./`` segments
    are dropped and what remains must be one library file name, else the ref is
    unresolved. Returns ``None`` when ``ref`` is not such a ref."""
    if base_dir is None or os.path.isabs(ref) or ref.startswith(("http://", "https://")):
        return None
    try:
        if os.path.normpath(str(base_dir)) != os.path.normpath(STDLIB_DIR):
            return None
    except TypeError:
        return None
    name = ref
    while name.startswith("./"):
        name = name[2:]
    return _bundled_path(name, STD_PREFIX + name)
