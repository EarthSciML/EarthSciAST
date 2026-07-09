"""EARTHSCIDATADIR-aware content-addressed cache for the loader DI seam.

This is the *ESS side* of the data-cache story. It wraps the existing
``opener=`` / ``fetcher=`` dependency-injection seam used by the runtime
loaders — ``GridLoader``/``StaticLoader`` take ``opener(url) -> Dataset`` and
``PointsLoader`` takes ``fetcher(url) -> bytes`` — with a local disk cache
keyed on ``sha256(resolved_url)`` under ``EARTHSCIDATADIR``.

It deliberately does **not** reimplement the heavy transport story (auth
tokens, ETag/TTL/checksum revalidation, advisory multi-process locking,
async CDS request-poll-download). Those live *behind* the injected base
``opener``/``fetcher`` — e.g. the ``earthsciio`` (esio) http+file transport
and local-disk store registries. What this module adds is the seam wiring
plus two things a pure-offline run needs:

* **content addressing** — ``sha256(resolved_url)`` so a cache populated by
  the data-engineering acquisition step is readable here without a network;
* **offline mode** — a cache-only mode where a miss raises :class:`CacheMiss`
  (an ``OSError``) so the existing :func:`mirror.open_with_fallback` mirror
  failover treats it like any other unreachable URL and tries the next one.

Wiring is additive: ``opener=None`` / ``fetcher=None`` on the loaders is
unchanged. Callers opt in by passing ``opener=cached_opener(...)`` (grid /
static) or ``fetcher=cached_fetcher(...)`` (points).
"""

from __future__ import annotations

import hashlib
import os
import tempfile
from pathlib import Path
from typing import Any, Callable, Union
from urllib.parse import urlsplit

from ..errors import EarthSciAstError

#: Environment variable naming the cache root. Honored by every helper here.
DATADIR_ENV = "EARTHSCIDATADIR"
#: Environment variable that forces cache-only (offline) behavior when set
#: truthy and the ``offline=`` argument is left as ``None``.
OFFLINE_ENV = "EARTHSCI_OFFLINE"
#: Fallback cache directory name used only when neither ``data_dir`` nor
#: ``EARTHSCIDATADIR`` is provided.
DEFAULT_CACHE_DIRNAME = "earthsci-cache"

_TRUTHY = frozenset({"1", "true", "yes", "on"})

PathLike = Union[str, "os.PathLike[str]"]


class CacheMiss(EarthSciAstError, OSError):
    """A URL was absent from the local cache and fetching was disabled.

    Subclasses :class:`OSError` on purpose: the loaders open through
    :func:`mirror.open_with_fallback`, whose default ``expected_errors``
    include ``OSError``. An offline miss on one URL therefore falls through
    to the next mirror exactly like a network failure would, and a miss on
    every URL surfaces as the usual ``MirrorFallbackError``.
    """

    def __init__(self, url: str, path: Path) -> None:
        self.url = url
        self.path = path
        super().__init__(f"offline cache miss for {url!r} (expected at {path})")


def resolve_data_dir(data_dir: PathLike | None = None) -> Path:
    """Resolve the cache root: explicit ``data_dir`` > ``EARTHSCIDATADIR`` > temp.

    The temp-dir fallback (rather than ``$HOME``) keeps the default off
    inode-quota'd home filesystems, matching the esio store convention.
    """
    if data_dir is not None:
        return Path(data_dir)
    env = os.environ.get(DATADIR_ENV)
    if env:
        return Path(env)
    return Path(tempfile.gettempdir()) / DEFAULT_CACHE_DIRNAME


def _offline_enabled(offline: bool | None) -> bool:
    if offline is not None:
        return offline
    return os.environ.get(OFFLINE_ENV, "").strip().lower() in _TRUTHY


def _url_suffix(url: str) -> str:
    """Return the URL path's file suffix (``.nc``, ``.tif``, ...) if sane.

    Preserved on the cache filename only as a format hint for openers that
    sniff by extension; the cache *key* is the sha256, so the suffix never
    affects addressing. Query-string-only URLs (e.g. ArcGIS ``exportImage``)
    have no path suffix and get a bare digest.
    """
    suffix = Path(urlsplit(url).path).suffix
    return suffix if 0 < len(suffix) <= 8 else ""


def cache_path_for_url(
    url: str,
    *,
    data_dir: PathLike | None = None,
    keep_suffix: bool = True,
) -> Path:
    """Content-addressed cache path for ``url``: ``<root>/<aa>/<sha256><suffix>``.

    Keyed on ``sha256(url)`` and sharded by the first two hex digits to keep
    any single directory small. Deterministic and side-effect free — callers
    (and the acquisition step that populates the cache) can compute the exact
    path a loader will read.
    """
    digest = hashlib.sha256(url.encode("utf-8")).hexdigest()
    suffix = _url_suffix(url) if keep_suffix else ""
    return resolve_data_dir(data_dir) / digest[:2] / f"{digest}{suffix}"


def _atomic_write(path: Path, data: bytes) -> None:
    """Write ``data`` to ``path`` via a same-directory temp file + atomic rename.

    A reader either sees no file or the complete file, never a partial one —
    enough to keep a concurrent offline reader safe. Cross-process *write*
    coordination (advisory locking) is the transport layer's job.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(
        dir=os.fspath(path.parent), prefix=f".{path.name}.", suffix=".tmp"
    )
    tmp = Path(tmp_name)
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)  # atomic within a filesystem on POSIX
    finally:
        if tmp.exists():
            try:
                tmp.unlink()
            except OSError:
                pass


def _default_dataset_opener() -> Callable[[str], Any]:
    # Imported lazily to avoid importing xarray at module import time and to
    # keep cache.py free of an import cycle with the loader modules.
    from .grid import _default_xarray_opener

    return _default_xarray_opener()


def _default_bytes_fetcher() -> Callable[[str], bytes]:
    from .points import _default_http_fetcher

    return _default_http_fetcher()


def cached_opener(
    *,
    opener: Callable[[str], Any] | None = None,
    fetcher: Callable[[str], bytes] | None = None,
    data_dir: PathLike | None = None,
    offline: bool | None = None,
) -> Callable[[str], Any]:
    """Wrap a dataset ``opener`` with the EARTHSCIDATADIR content-addressed cache.

    The returned callable has the same ``(url) -> Dataset`` shape the grid and
    static loaders expect, so it drops straight into their ``opener=`` seam:

    * **hit** — open the local cache file with ``opener`` (default:
      ``xarray.open_dataset``);
    * **miss + offline** — raise :class:`CacheMiss` (mirror failover proceeds);
    * **miss + online** — download bytes with ``fetcher`` (default: the points
      HTTP fetcher, or inject the esio transport), cache them atomically, then
      open the local file.

    Parameters
    ----------
    opener:
        Base ``(path) -> Dataset`` opener applied to the *local* cache path.
    fetcher:
        Base ``(url) -> bytes`` downloader used only on an online miss.
    data_dir:
        Cache root override; defaults to ``EARTHSCIDATADIR`` then a temp dir.
    offline:
        Force cache-only. ``None`` (default) consults ``EARTHSCI_OFFLINE``.
    """
    off = _offline_enabled(offline)

    def _open(url: str) -> Any:
        path = cache_path_for_url(url, data_dir=data_dir)
        if not path.exists():
            if off:
                raise CacheMiss(url, path)
            download = fetcher if fetcher is not None else _default_bytes_fetcher()
            _atomic_write(path, download(url))
        # Resolve the base opener lazily — only when actually opening a cached
        # file — so an offline miss raises CacheMiss above without requiring the
        # (xarray) default opener to be importable.
        base_opener = opener if opener is not None else _default_dataset_opener()
        return base_opener(os.fspath(path))

    return _open


def cached_fetcher(
    *,
    fetcher: Callable[[str], bytes] | None = None,
    data_dir: PathLike | None = None,
    offline: bool | None = None,
) -> Callable[[str], bytes]:
    """Wrap a bytes ``fetcher`` (points seam) with the same content-addressed cache.

    Returns a ``(url) -> bytes`` callable for the points loader's ``fetcher=``
    seam: a cache hit reads the local bytes; an online miss downloads with the
    base ``fetcher`` (default HTTP), caches atomically, and returns the bytes;
    an offline miss raises :class:`CacheMiss`.
    """
    off = _offline_enabled(offline)

    def _fetch(url: str) -> bytes:
        path = cache_path_for_url(url, data_dir=data_dir)
        if path.exists():
            return path.read_bytes()
        if off:
            raise CacheMiss(url, path)
        download = fetcher if fetcher is not None else _default_bytes_fetcher()
        data = download(url)
        _atomic_write(path, data)
        return data

    return _fetch
