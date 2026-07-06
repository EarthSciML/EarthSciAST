"""Tests for the EARTHSCIDATADIR content-addressed loader cache (campfire-e2e C2).

Two layers:

* **Unit** — the content-addressing, EARTHSCIDATADIR resolution, offline
  (cache-only) behavior, atomic fetch-and-store, and mirror-failover wiring of
  :mod:`earthsci_toolkit.data_loaders.cache`. These use fake openers/fetchers
  and need no scientific stack.
* **Integration** — the three Camp Fire loaders (ERA5 grid, LANDFIRE static,
  USGS3DEP static) materialize real arrays from a populated local cache with
  no network, threaded through the *existing* ``opener=`` DI seam. These need
  numpy/xarray/netCDF4 and skip cleanly when absent.

The acceptance contract: a URL fetch caches, then re-reads in OFFLINE mode via
``EARTHSCIDATADIR``; existing loader behavior (``opener=None``) is unchanged.
"""

from __future__ import annotations

import datetime as dt
import hashlib
import os
import tempfile
from pathlib import Path
from typing import Dict, List

import pytest

from earthsci_toolkit import (
    CacheMiss,
    MirrorFallbackError,
    cache_path_for_url,
    cached_fetcher,
    cached_opener,
    load_data,
    open_with_fallback,
    resolve_data_dir,
)
from earthsci_toolkit.data_loaders import cache as cache_mod


# ---------------------------------------------------------------------------
# Content addressing + cache-root resolution
# ---------------------------------------------------------------------------


class TestCachePath:
    def test_content_addressed_and_deterministic(self, tmp_path):
        url = "cds://reanalysis-era5-pressure-levels/era5_pl_2018_11.nc"
        p1 = cache_path_for_url(url, data_dir=tmp_path)
        p2 = cache_path_for_url(url, data_dir=tmp_path)
        assert p1 == p2, "same URL must map to the same path"

        digest = hashlib.sha256(url.encode("utf-8")).hexdigest()
        assert p1.name == f"{digest}.nc", "filename is sha256(url) + suffix"
        assert p1.parent.name == digest[:2], "sharded by first two hex digits"
        assert tmp_path in p1.parents

    def test_distinct_urls_distinct_paths(self, tmp_path):
        a = cache_path_for_url("https://h/a.nc", data_dir=tmp_path)
        b = cache_path_for_url("https://h/b.nc", data_dir=tmp_path)
        assert a != b

    def test_suffix_preserved_only_for_path_extensions(self, tmp_path):
        nc = cache_path_for_url("file:///d/x.nc", data_dir=tmp_path)
        assert nc.suffix == ".nc"
        # ArcGIS-style query endpoints have no path suffix -> bare digest.
        export = cache_path_for_url(
            "https://srv/ImageServer/exportImage?bbox=1,2,3,4&format=tiff",
            data_dir=tmp_path,
        )
        assert export.suffix == ""
        assert (
            export.name
            == hashlib.sha256(
                "https://srv/ImageServer/exportImage?bbox=1,2,3,4&format=tiff".encode()
            ).hexdigest()
        )

    def test_keep_suffix_false_gives_bare_digest(self, tmp_path):
        p = cache_path_for_url("file:///d/x.nc", data_dir=tmp_path, keep_suffix=False)
        assert p.suffix == ""


class TestResolveDataDir:
    def test_explicit_wins_over_env(self, tmp_path, monkeypatch):
        monkeypatch.setenv(cache_mod.DATADIR_ENV, "/env/should/lose")
        assert resolve_data_dir(tmp_path) == Path(tmp_path)

    def test_env_used_when_no_explicit(self, monkeypatch):
        monkeypatch.setenv(cache_mod.DATADIR_ENV, "/scratch.local/earthsci")
        assert resolve_data_dir() == Path("/scratch.local/earthsci")

    def test_tempdir_fallback_when_unset(self, monkeypatch):
        monkeypatch.delenv(cache_mod.DATADIR_ENV, raising=False)
        out = resolve_data_dir()
        assert out == Path(tempfile.gettempdir()) / cache_mod.DEFAULT_CACHE_DIRNAME

    def test_cache_path_honors_earthscidatadir(self, tmp_path, monkeypatch):
        monkeypatch.setenv(cache_mod.DATADIR_ENV, os.fspath(tmp_path))
        p = cache_path_for_url("https://h/x.nc")  # no explicit data_dir
        assert tmp_path in p.parents


# ---------------------------------------------------------------------------
# Offline (cache-only) opener behavior
# ---------------------------------------------------------------------------


class TestCachedOpenerOffline:
    def test_offline_miss_raises_cachemiss_which_is_oserror(self, tmp_path):
        opener = cached_opener(opener=lambda p: ("opened", p), data_dir=tmp_path, offline=True)
        with pytest.raises(CacheMiss) as exc:
            opener("https://h/missing.nc")
        assert isinstance(exc.value, OSError), "CacheMiss must be an OSError"
        assert exc.value.url == "https://h/missing.nc"

    def test_offline_hit_reads_cache_without_fetch(self, tmp_path):
        url = "https://h/data.nc"
        cache_path_for_url(url, data_dir=tmp_path).parent.mkdir(parents=True, exist_ok=True)
        cache_path_for_url(url, data_dir=tmp_path).write_bytes(b"NETCDFBYTES")

        seen: List[str] = []

        def base_opener(path: str):
            seen.append(path)
            return Path(path).read_bytes()

        def forbidden_fetch(_url):  # pragma: no cover - must never run offline
            raise AssertionError("offline opener must not fetch")

        opener = cached_opener(
            opener=base_opener,
            fetcher=forbidden_fetch,
            data_dir=tmp_path,
            offline=True,
        )
        assert opener(url) == b"NETCDFBYTES"
        assert seen == [os.fspath(cache_path_for_url(url, data_dir=tmp_path))]

    def test_env_offline_flag_forces_cache_only(self, tmp_path, monkeypatch):
        monkeypatch.setenv(cache_mod.OFFLINE_ENV, "1")
        # offline left as None -> consults the env flag.
        opener = cached_opener(opener=lambda p: p, data_dir=tmp_path)
        with pytest.raises(CacheMiss):
            opener("https://h/x.nc")


# ---------------------------------------------------------------------------
# Online fetch-and-store
# ---------------------------------------------------------------------------


class TestCachedOpenerOnline:
    def test_online_miss_fetches_caches_then_opens(self, tmp_path):
        url = "https://h/data.nc"
        fetches: List[str] = []

        def fetcher(u: str) -> bytes:
            fetches.append(u)
            return b"PAYLOAD"

        opener = cached_opener(
            opener=lambda p: Path(p).read_bytes(),
            fetcher=fetcher,
            data_dir=tmp_path,
            offline=False,
        )
        assert opener(url) == b"PAYLOAD"
        assert fetches == [url]
        assert cache_path_for_url(url, data_dir=tmp_path).exists()

        # Second call is served from cache: the fetcher is not invoked again.
        assert opener(url) == b"PAYLOAD"
        assert fetches == [url]

    def test_atomic_write_leaves_no_temp_files(self, tmp_path):
        url = "https://h/data.nc"
        opener = cached_opener(
            opener=lambda p: Path(p).read_bytes(),
            fetcher=lambda _u: b"X" * 1024,
            data_dir=tmp_path,
            offline=False,
        )
        opener(url)
        path = cache_path_for_url(url, data_dir=tmp_path)
        leftovers = [p for p in path.parent.iterdir() if p.name != path.name]
        assert leftovers == [], f"atomic write left temp files: {leftovers}"


# ---------------------------------------------------------------------------
# cached_fetcher (points seam)
# ---------------------------------------------------------------------------


class TestCachedFetcher:
    def test_online_then_offline_roundtrip(self, tmp_path):
        url = "https://api/points?date=2018-11-08"
        calls: List[str] = []
        online = cached_fetcher(
            fetcher=lambda u: calls.append(u) or b'{"results": []}',
            data_dir=tmp_path,
            offline=False,
        )
        assert online(url) == b'{"results": []}'
        assert calls == [url]

        offline = cached_fetcher(data_dir=tmp_path, offline=True)
        assert offline(url) == b'{"results": []}', "offline re-read from cache"
        assert calls == [url], "offline path performs no fetch"

    def test_offline_miss_raises(self, tmp_path):
        offline = cached_fetcher(data_dir=tmp_path, offline=True)
        with pytest.raises(CacheMiss):
            offline("https://api/cold")


# ---------------------------------------------------------------------------
# Mirror failover integrates with the cached opener (offline)
# ---------------------------------------------------------------------------


class TestMirrorFailover:
    def test_offline_primary_miss_falls_through_to_cached_mirror(self, tmp_path):
        primary = "cds://reanalysis/era5_2018_11.nc"
        mirror = "file:///data/era5/era5_2018_11.nc"
        # Only the mirror is cached.
        mpath = cache_path_for_url(mirror, data_dir=tmp_path)
        mpath.parent.mkdir(parents=True, exist_ok=True)
        mpath.write_bytes(b"MIRROR")

        opener = cached_opener(
            opener=lambda p: Path(p).read_bytes(), data_dir=tmp_path, offline=True
        )
        result = open_with_fallback([primary, mirror], opener)
        assert result == b"MIRROR", "offline miss on primary -> cached mirror"

    def test_offline_all_miss_raises_mirror_fallback_error(self, tmp_path):
        opener = cached_opener(opener=lambda p: p, data_dir=tmp_path, offline=True)
        with pytest.raises(MirrorFallbackError):
            open_with_fallback(["a://x", "b://y"], opener)


# ---------------------------------------------------------------------------
# Integration: the three Camp Fire loaders read real arrays from cache offline
# ---------------------------------------------------------------------------


FIXTURES_DIR = Path(__file__).parent / "fixtures" / "data_loaders"

# Camp Fire (Paradise, CA; Nov 2018) substitutions just need to resolve each
# loader's URL template deterministically — the same string is used to write
# and to read the cache, so the exact values are immaterial to the test.
_CAMPFIRE_TIME = dt.datetime(2018, 11, 8)
_CAMPFIRE_SUBS = {
    "version": "220",
    "product": "FBFM13",
    "bbox_west": -121.8,
    "bbox_south": 39.6,
    "bbox_east": -121.4,
    "bbox_north": 40.0,
    "width": 64,
    "height": 64,
}

# (fixture file, loader name, time, {schema_var: file_variable}, probe value)
_LOADER_CASES = [
    (
        "era5.esm",
        "ERA5",
        _CAMPFIRE_TIME,
        {"t": "t", "u": "u", "v": "v", "w": "w", "q": "q", "z": "z", "o3": "o3"},
        ("u", 7.5),
    ),
    ("landfire.esm", "LANDFIRE_FBFM13", None, {"fbfm13": "fbfm13"}, ("fbfm13", 3.0)),
    (
        "usgs3dep.esm",
        "USGS3DEP",
        None,
        {"elevation": "elevation"},
        ("elevation", 1234.0),
    ),
]


def _strip_comments(data):
    if isinstance(data, dict):
        return {k: _strip_comments(v) for k, v in data.items() if not k.startswith("_comment")}
    if isinstance(data, list):
        return [_strip_comments(v) for v in data]
    return data


def _load_fixture_loader(fixture_name: str, loader_name: str):
    import json
    from earthsci_toolkit import load

    raw = json.loads((FIXTURES_DIR / fixture_name).read_text())
    esm = load(json.dumps(_strip_comments(raw)))
    return esm.data_loaders[loader_name]


def _netcdf_bytes(file_vars: Dict[str, float]):
    """Serialize a tiny 2x2 Camp Fire-area dataset to NetCDF bytes.

    Each file variable is filled with a distinct constant so the probe can
    confirm a *real* array (not a coincidental default) survived the trip.
    """
    import numpy as np
    import xarray as xr

    lat = [39.6, 40.0]
    lon = [-121.8, -121.4]
    data_vars = {
        name: (("lat", "lon"), np.full((2, 2), fill, dtype="float64"))
        for name, fill in file_vars.items()
    }
    ds = xr.Dataset(data_vars, coords={"lat": lat, "lon": lon})
    with tempfile.TemporaryDirectory() as d:
        p = Path(d) / "src.nc"
        ds.to_netcdf(p)
        return p.read_bytes()


@pytest.mark.parametrize(
    "fixture_name, loader_name, time, var_map, probe",
    _LOADER_CASES,
    ids=[c[1] for c in _LOADER_CASES],
)
def test_loader_reads_real_arrays_from_offline_cache(
    tmp_path, monkeypatch, fixture_name, loader_name, time, var_map, probe
):
    pytest.importorskip("numpy")
    pytest.importorskip("xarray")
    pytest.importorskip("netCDF4")
    import numpy as np

    monkeypatch.setenv(cache_mod.DATADIR_ENV, os.fspath(tmp_path))
    dl = _load_fixture_loader(fixture_name, loader_name)

    probe_var, probe_val = probe
    file_vars = {
        fv: (probe_val if sv == probe_var else float(i + 1))
        for i, (sv, fv) in enumerate(var_map.items())
    }
    payload = _netcdf_bytes(file_vars)

    fetch_calls: List[str] = []

    # (1) ONLINE pass: a single fetch populates the content-addressed cache
    # (data_dir defaults to EARTHSCIDATADIR, which we pointed at tmp_path).
    online = cached_opener(fetcher=lambda u: fetch_calls.append(u) or payload)
    res_online = load_data(dl, time=time, opener=online, **_CAMPFIRE_SUBS)
    assert len(fetch_calls) == 1, "exactly one source URL fetched and cached"
    assert np.asarray(res_online.variables[probe_var]).reshape(-1)[0] == probe_val

    # A content-addressed file now exists under EARTHSCIDATADIR.
    cached_files = [p for p in tmp_path.rglob("*") if p.is_file()]
    assert len(cached_files) == 1, cached_files

    # (2) OFFLINE pass: same loader, cache-only, NO fetcher — real arrays come
    # straight off disk with no network access.
    offline = cached_opener(offline=True)
    res_offline = load_data(dl, time=time, opener=offline, **_CAMPFIRE_SUBS)
    got = np.asarray(res_offline.variables[probe_var])
    assert got.reshape(-1)[0] == probe_val
    assert got.shape == (2, 2)


def test_existing_default_opener_path_unchanged(tmp_path):
    """Regression: opener=None still uses the default seam (no cache coupling).

    A fake opener passed positionally as before keeps working; the cache is
    strictly opt-in via cached_opener(), so existing callers are untouched.
    """
    from earthsci_toolkit import (
        DataLoader,
        DataLoaderKind,
        DataLoaderSource,
        DataLoaderVariable,
        DataLoaderTemporal,
        GridLoader,
    )

    dl = DataLoader(
        name="fake",
        kind=DataLoaderKind.GRID,
        source=DataLoaderSource(url_template="mem://{date:%Y%m%d}.nc"),
        variables={"u": DataLoaderVariable(file_variable="U", units="m/s")},
        temporal=DataLoaderTemporal(file_period="P1D"),
    )

    class _DS:
        data_vars = ["U"]

        def __getitem__(self, k):
            return [1.0, 2.0]

    res = GridLoader(dl).load(time=dt.datetime(2018, 11, 8), opener=lambda _u: _DS())
    assert res.variables["u"] == [1.0, 2.0]
