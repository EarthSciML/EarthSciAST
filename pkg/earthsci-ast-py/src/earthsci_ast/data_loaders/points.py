"""Runtime loader for ``kind=points`` DataLoaders.

Points loaders describe irregular station-style observations — OpenAQ, ground
sensors, etc. The source is typically an HTTP(S) URL returning JSON or CSV.
This loader fetches the URL, parses the payload, and applies variable
remapping/unit conversion.
"""

from __future__ import annotations

import csv
import datetime as _dt
import io
import json
from collections.abc import Iterable, Mapping
from dataclasses import dataclass
from importlib.metadata import PackageNotFoundError
from importlib.metadata import version as _pkg_version
from typing import Any, Callable

from ..errors import EarthSciAstError
from ..esm_types import DataLoader, DataLoaderKind
from ._source_urls import resolve_source_urls
from .mirror import open_with_fallback
from .variables import apply_variable_mapping

# Tunables for the default HTTP fetcher (used only when no explicit fetcher is
# supplied to ``load``).
_HTTP_TIMEOUT_SECONDS = 30
try:
    _PACKAGE_VERSION = _pkg_version("earthsci-ast")
except PackageNotFoundError:  # pragma: no cover - not installed as a distribution
    _PACKAGE_VERSION = "0.1"
_HTTP_USER_AGENT = "earthsci-ast/" + _PACKAGE_VERSION


class PointsLoaderError(EarthSciAstError, RuntimeError):
    """Raised when a points source cannot be loaded or parsed."""


@dataclass
class PointsLoadResult:
    """Result of a single ``PointsLoader.load`` call."""

    urls_tried: list[str]
    records: list[dict[str, Any]]
    variables: dict[str, list[Any]]


class PointsLoader:
    """Materialise a ``kind=points`` DataLoader at a given time."""

    def __init__(self, data_loader: DataLoader) -> None:
        if data_loader.kind != DataLoaderKind.POINTS:
            raise PointsLoaderError(f"PointsLoader requires kind=points; got {data_loader.kind}")
        self.dl = data_loader

    def _resolve_urls(
        self,
        *,
        time: _dt.datetime | _dt.date | str | None,
        substitutions: Mapping[str, Any],
    ) -> list[str]:
        return resolve_source_urls(self.dl, time=time, substitutions=substitutions)

    def load(
        self,
        *,
        time: _dt.datetime | _dt.date | str | None = None,
        fetcher: Callable[[str], bytes] | None = None,
        parser: Callable[[bytes], list[dict[str, Any]]] | None = None,
        **substitutions: Any,
    ) -> PointsLoadResult:
        """Fetch records from the first URL that opens.

        ``fetcher(url) -> bytes`` defaults to ``urllib.request.urlopen``. The
        ``parser(body) -> list[dict]`` argument controls decoding; by default
        it sniffs JSON vs CSV by trying JSON first.
        """
        urls = self._resolve_urls(time=time, substitutions=substitutions)
        if fetcher is None:
            fetcher = _default_http_fetcher()
        if parser is None:
            parser = _default_parser
        body = open_with_fallback(
            urls, fetcher, expected_errors=(OSError, RuntimeError, ValueError)
        )
        records = parser(body)
        raw = _records_to_columns(records)
        mapped = apply_variable_mapping(raw, self.dl.variables, strict=False)
        return PointsLoadResult(urls_tried=urls, records=records, variables=mapped)


def load_points(
    data_loader: DataLoader,
    *,
    time: _dt.datetime | _dt.date | str | None = None,
    fetcher: Callable[[str], bytes] | None = None,
    parser: Callable[[bytes], list[dict[str, Any]]] | None = None,
    **substitutions: Any,
) -> PointsLoadResult:
    """Convenience wrapper: instantiate and call ``PointsLoader.load``."""
    return PointsLoader(data_loader).load(
        time=time, fetcher=fetcher, parser=parser, **substitutions
    )


def _default_http_fetcher() -> Callable[[str], bytes]:
    from urllib.request import Request, urlopen

    def _fetch(url: str) -> bytes:
        req = Request(url, headers={"User-Agent": _HTTP_USER_AGENT})
        with urlopen(req, timeout=_HTTP_TIMEOUT_SECONDS) as resp:
            return resp.read()

    return _fetch


def _default_parser(body: bytes) -> list[dict[str, Any]]:
    text = body.decode("utf-8") if isinstance(body, (bytes, bytearray)) else body
    text = text.strip()
    if not text:
        return []
    if text[0] in "{[":
        try:
            payload = json.loads(text)
        except json.JSONDecodeError as exc:
            raise PointsLoaderError(f"failed to parse JSON body: {exc}") from exc
        if isinstance(payload, dict):
            for key in ("results", "data", "items", "measurements", "features"):
                maybe = payload.get(key)
                if isinstance(maybe, list):
                    return [_flatten_record(r) for r in maybe]
            return [_flatten_record(payload)]
        if isinstance(payload, list):
            return [_flatten_record(r) for r in payload]
        raise PointsLoaderError(f"unexpected JSON root type: {type(payload).__name__}")
    reader = csv.DictReader(io.StringIO(text))
    return [dict(row) for row in reader]


def _flatten_record(record: Any) -> dict[str, Any]:
    if not isinstance(record, dict):
        return {"value": record}
    out: dict[str, Any] = {}
    for key, value in record.items():
        if isinstance(value, dict):
            for inner, inner_val in value.items():
                out[f"{key}.{inner}"] = inner_val
        else:
            out[key] = value
    return out


def _records_to_columns(records: Iterable[Mapping[str, Any]]) -> dict[str, list[Any]]:
    columns: dict[str, list[Any]] = {}
    record_list = list(records)
    for record in record_list:
        for key in record.keys():
            if key not in columns:
                columns[key] = [None] * len(record_list)
    for idx, record in enumerate(record_list):
        for key, value in record.items():
            columns[key][idx] = value
    return columns
