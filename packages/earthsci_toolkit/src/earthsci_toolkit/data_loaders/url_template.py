"""URL template expansion for DataLoader sources.

Templates use curly-brace placeholders:

- ``{date:%fmt}`` — strftime-formatted datetime, e.g. ``{date:%Y%m%d}``
- ``{date}`` — ISO-8601 datetime
- ``{var}`` / ``{variable}`` — a variable name
- ``{sector}`` — an emissions sector name
- ``{species}`` — a chemical species name
- any other ``{name}`` — looked up in the caller-supplied kwargs dict

The ``expand_url_template`` function mirrors the Julia-side url template grammar
used in EarthSciData.jl's ``relpath`` functions, and is kind-agnostic.
"""

from __future__ import annotations

import datetime as _dt
import re
from typing import Any, Dict, Iterable, List, Optional, Set, Union

_TOKEN_RE = re.compile(r"\{([a-zA-Z_][a-zA-Z0-9_]*)(?::([^{}]*))?\}")


class UrlTemplateError(ValueError):
    """Raised when a URL template cannot be expanded."""


def template_placeholders(template: str) -> Set[str]:
    """Return the set of placeholder names present in ``template``."""
    return {m.group(1) for m in _TOKEN_RE.finditer(template)}


def _format_date(value: Union[_dt.datetime, _dt.date, str], fmt: Optional[str]) -> str:
    if isinstance(value, str):
        parsed = _parse_iso_datetime(value)
        if parsed is None:
            raise UrlTemplateError(f"date value {value!r} is not a valid ISO-8601 datetime")
        value = parsed
    if isinstance(value, _dt.datetime):
        dt = value
    elif isinstance(value, _dt.date):
        dt = _dt.datetime(value.year, value.month, value.day)
    else:
        raise UrlTemplateError(
            f"date placeholder expects datetime/date/str, got {type(value).__name__}"
        )
    if fmt is None or fmt == "":
        return dt.isoformat()
    return dt.strftime(fmt)


def _parse_iso_datetime(value: str) -> Optional[_dt.datetime]:
    if value.endswith("Z"):
        value = value[:-1] + "+00:00"
    try:
        return _dt.datetime.fromisoformat(value)
    except ValueError:
        return None


def expand_url_template(
    template: str,
    *,
    date: Optional[Union[_dt.datetime, _dt.date, str]] = None,
    variables: Optional[Dict[str, Any]] = None,
    **kwargs: Any,
) -> str:
    """Expand ``template``, substituting ``{date:%fmt}`` and named placeholders.

    Extra values are drawn from ``variables`` and then ``kwargs``; ``kwargs``
    wins on conflict. Raises :class:`UrlTemplateError` if a placeholder has no
    value.
    """
    merged: Dict[str, Any] = {}
    if variables:
        merged.update(variables)
    merged.update(kwargs)

    def _sub(match: "re.Match[str]") -> str:
        name = match.group(1)
        fmt = match.group(2)
        if name == "date":
            if date is None:
                raise UrlTemplateError(
                    f"template {template!r} requires a date but none was supplied"
                )
            return _format_date(date, fmt)
        if name in merged:
            value = merged[name]
            if fmt:
                return format(value, fmt)
            return str(value)
        raise UrlTemplateError(f"template {template!r} has unfilled placeholder {{{name}}}")

    return _TOKEN_RE.sub(_sub, template)


def expand_with_mirrors(
    url_template: str,
    mirrors: Optional[Iterable[str]],
    *,
    date: Optional[Union[_dt.datetime, _dt.date, str]] = None,
    variables: Optional[Dict[str, Any]] = None,
    **kwargs: Any,
) -> List[str]:
    """Expand ``url_template`` followed by each mirror into a fallback list.

    Mirrors that fail expansion (e.g. missing placeholder) are skipped so that
    a misconfigured mirror cannot break the primary URL.
    """
    out: List[str] = [expand_url_template(url_template, date=date, variables=variables, **kwargs)]
    for mirror in mirrors or ():
        try:
            out.append(expand_url_template(mirror, date=date, variables=variables, **kwargs))
        except UrlTemplateError:
            continue
    return out
