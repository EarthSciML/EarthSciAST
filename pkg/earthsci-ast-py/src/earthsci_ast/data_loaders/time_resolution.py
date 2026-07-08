"""Map wall-clock times to the file that contains them.

DataLoaderTemporal carries ``file_period`` (ISO-8601 duration, e.g. ``P1D``) and
optionally ``frequency``, ``records_per_file``, and ``start``. Given a target
time ``t``, we snap it back to the start of the file period it falls into
("file anchor"), so the caller can feed that anchor into url template expansion.
"""

from __future__ import annotations

import datetime as _dt
import re
from dataclasses import dataclass
from typing import List, Optional, Union

_DURATION_RE = re.compile(
    r"^P"
    r"(?:(?P<years>\d+)Y)?"
    r"(?:(?P<months>\d+)M)?"
    r"(?:(?P<weeks>\d+)W)?"
    r"(?:(?P<days>\d+)D)?"
    r"(?:T"
    r"(?:(?P<hours>\d+)H)?"
    r"(?:(?P<minutes>\d+)M)?"
    r"(?:(?P<seconds>\d+(?:\.\d+)?)S)?"
    r")?$"
)


class TimeResolutionError(ValueError):
    """Raised when temporal resolution of a file anchor fails."""


@dataclass(frozen=True)
class Duration:
    """Calendar-aware duration parsed from an ISO-8601 period string."""

    years: int = 0
    months: int = 0
    days: int = 0
    seconds: float = 0.0

    def approximate_seconds(self) -> float:
        return (
            self.years * 365.2425 * 86400.0
            + self.months * 30.436875 * 86400.0
            + self.days * 86400.0
            + self.seconds
        )


def parse_iso_duration(duration: str) -> Duration:
    """Parse an ISO-8601 duration like ``P1D``, ``PT3H``, ``P50Y``."""
    m = _DURATION_RE.match(duration)
    if m is None:
        raise TimeResolutionError(f"invalid ISO-8601 duration: {duration!r}")
    years = int(m.group("years") or 0)
    months = int(m.group("months") or 0)
    weeks = int(m.group("weeks") or 0)
    days = int(m.group("days") or 0) + 7 * weeks
    hours = int(m.group("hours") or 0)
    minutes = int(m.group("minutes") or 0)
    seconds = float(m.group("seconds") or 0.0)
    total_seconds = hours * 3600 + minutes * 60 + seconds
    if years == 0 and months == 0 and days == 0 and total_seconds == 0.0:
        raise TimeResolutionError(f"duration {duration!r} has no nonzero components")
    return Duration(years=years, months=months, days=days, seconds=total_seconds)


def _coerce_datetime(value: Union[_dt.datetime, _dt.date, str]) -> _dt.datetime:
    """Coerce to a **naive UTC** datetime.

    The loader cadence / file-resolution code mixes datetimes from several
    sources — ISO strings with a ``Z``/offset (tz-aware), bare ISO strings and
    ``date`` objects (naive). Comparing an aware with a naive datetime raises
    ``TypeError``, which surfaces deep in ``_snap_to_period`` / ``refresh_times``.
    Normalising every coerced value to naive UTC keeps the whole loader time
    path comparable.
    """
    if isinstance(value, _dt.datetime):
        dt = value
    elif isinstance(value, _dt.date):
        return _dt.datetime(value.year, value.month, value.day)
    elif isinstance(value, str):
        if value.endswith("Z"):
            value = value[:-1] + "+00:00"
        try:
            dt = _dt.datetime.fromisoformat(value)
        except ValueError as exc:
            raise TimeResolutionError(f"cannot parse {value!r} as ISO-8601 datetime") from exc
    else:
        raise TimeResolutionError(f"expected datetime/date/str, got {type(value).__name__}")
    if dt.tzinfo is not None:
        dt = dt.astimezone(_dt.timezone.utc).replace(tzinfo=None)
    return dt


def _add_months(dt: _dt.datetime, months: int) -> _dt.datetime:
    total = dt.month - 1 + months
    year = dt.year + total // 12
    month = total % 12 + 1
    day = min(dt.day, _days_in_month(year, month))
    return dt.replace(year=year, month=month, day=day)


def _days_in_month(year: int, month: int) -> int:
    if month == 12:
        next_first = _dt.datetime(year + 1, 1, 1)
    else:
        next_first = _dt.datetime(year, month + 1, 1)
    return (next_first - _dt.datetime(year, month, 1)).days


def add_duration(start: _dt.datetime, duration: Duration) -> _dt.datetime:
    """Add a calendar-aware ``Duration`` to ``start``."""
    out = start
    if duration.years:
        out = out.replace(year=out.year + duration.years)
    if duration.months:
        out = _add_months(out, duration.months)
    if duration.days:
        out = out + _dt.timedelta(days=duration.days)
    if duration.seconds:
        out = out + _dt.timedelta(seconds=duration.seconds)
    return out


def _snap_to_period(target: _dt.datetime, anchor: _dt.datetime, period: Duration) -> _dt.datetime:
    """Find the greatest anchor+k*period <= target, for ``period > 0``."""
    if anchor > target:
        raise TimeResolutionError(
            f"target {target.isoformat()} is before anchor {anchor.isoformat()}"
        )
    if period.years or period.months:
        delta_months = period.years * 12 + period.months
        target_months = target.year * 12 + (target.month - 1)
        anchor_months = anchor.year * 12 + (anchor.month - 1)
        diff = target_months - anchor_months
        k = diff // delta_months
        candidate = _add_months(anchor, k * delta_months)
        if candidate > target:
            candidate = _add_months(anchor, (k - 1) * delta_months)
        return candidate
    period_seconds = period.days * 86400 + period.seconds
    if period_seconds <= 0:
        raise TimeResolutionError("period must be positive")
    diff_seconds = (target - anchor).total_seconds()
    k = int(diff_seconds // period_seconds)
    return anchor + _dt.timedelta(seconds=k * period_seconds)


def file_anchor_for_time(
    time: Union[_dt.datetime, _dt.date, str],
    *,
    file_period: str,
    start: Optional[Union[_dt.datetime, _dt.date, str]] = None,
) -> _dt.datetime:
    """Snap ``time`` back to the start of the file period that contains it.

    If ``start`` is supplied (DataLoaderTemporal.start), it defines the anchor
    from which periods are measured — useful for uneven period starts like
    CEDS' 1750 baseline. Otherwise ``time`` is rounded via the natural calendar
    boundary (day/month/year), which covers the common cases ``P1D``/``P1M``/
    ``P1Y``.
    """
    target = _coerce_datetime(time)
    period = parse_iso_duration(file_period)
    if start is not None:
        anchor = _coerce_datetime(start)
        return _snap_to_period(target, anchor, period)

    if period.years and not period.months and not period.days and not period.seconds:
        year = target.year - (target.year % period.years) if period.years > 1 else target.year
        return _dt.datetime(year, 1, 1)
    if period.months and not period.years and not period.days and not period.seconds:
        month_index = target.month - 1
        snapped = month_index - (month_index % period.months)
        return _dt.datetime(target.year, snapped + 1, 1)
    if period.days and not period.years and not period.months and not period.seconds:
        midnight = _dt.datetime(target.year, target.month, target.day)
        if period.days == 1:
            return midnight
        day_of_year = (midnight - _dt.datetime(target.year, 1, 1)).days
        snapped = day_of_year - (day_of_year % period.days)
        return _dt.datetime(target.year, 1, 1) + _dt.timedelta(days=snapped)
    if period.seconds and not (period.years or period.months or period.days):
        midnight = _dt.datetime(target.year, target.month, target.day)
        seconds_today = (target - midnight).total_seconds()
        snapped = seconds_today - (seconds_today % period.seconds)
        return midnight + _dt.timedelta(seconds=snapped)
    raise TimeResolutionError(
        f"ambiguous natural anchor for period {file_period!r}; supply `start`"
    )


def file_anchors_in_range(
    start: Union[_dt.datetime, _dt.date, str],
    end: Union[_dt.datetime, _dt.date, str],
    *,
    file_period: str,
    anchor: Optional[Union[_dt.datetime, _dt.date, str]] = None,
) -> List[_dt.datetime]:
    """List all file anchors in ``[start, end]``, inclusive of both ends."""
    period = parse_iso_duration(file_period)
    first = file_anchor_for_time(start, file_period=file_period, start=anchor)
    end_dt = _coerce_datetime(end)
    out: List[_dt.datetime] = []
    current = first
    while current <= end_dt:
        out.append(current)
        nxt = add_duration(current, period)
        if nxt <= current:
            raise TimeResolutionError("period did not advance; aborting")
        current = nxt
    return out


def records_for_file(
    records_per_file: Union[int, str, None],
    *,
    file_period: Optional[str] = None,
    frequency: Optional[str] = None,
) -> Optional[int]:
    """Return the integer number of records per file, resolving ``'auto'``.

    If ``records_per_file`` is an int, return it. If it's ``'auto'`` and both
    ``file_period`` and ``frequency`` are available, infer the count as the
    ratio of approximate durations. Returns ``None`` for unknown layouts.
    """
    if records_per_file is None:
        return None
    if isinstance(records_per_file, int):
        return records_per_file
    if isinstance(records_per_file, str):
        if records_per_file == "auto":
            if not file_period or not frequency:
                return None
            fp = parse_iso_duration(file_period).approximate_seconds()
            fr = parse_iso_duration(frequency).approximate_seconds()
            if fr <= 0:
                return None
            return max(1, int(round(fp / fr)))
        try:
            return int(records_per_file)
        except ValueError as exc:
            raise TimeResolutionError(
                f"records_per_file={records_per_file!r} is not an int or 'auto'"
            ) from exc
    raise TimeResolutionError(
        f"records_per_file must be int/str/None, got {type(records_per_file).__name__}"
    )
