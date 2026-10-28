"""Document-scoped solver hints (esm-spec §2.2).

The `solver` block records numerics the document knows about *itself* —
stiffness, integration tolerances, and a splitting hint — which each binding
maps to its own integrator, plus ``external``: a reference to a separate
run-configuration document (§2.2.6) that this binding never opens, and
``time_span``: the interval the document is meant to be simulated over
(§2.2.7).

Every field is ADVISORY: a binding may ignore any or all of them and still
conform. Advisory governs the MECHANISM, never the OUTCOME — the
CONFORMANCE_SPEC §5.9 requirement to integrate successfully and agree within
the error band is untouched by this block and is not excused by it.

This module carries the things that are NOT advisory: the spec-version gates
(§2.2.4), the ``${`` refusal and the resolution of ``external`` (§2.2.6), the
load-time check and the seconds conversion of ``time_span`` (§2.2.7), and the
tolerance and interval resolution orders (§2.2.2, §2.2.7).
"""

from __future__ import annotations

import math
import os
import re
from typing import TYPE_CHECKING, Any

from ._data_source_urls import _SCHEME_RE, _remove_dot_segments
from .error_handling import (
    SOLVER_EXTERNAL_UNRESOLVED,
    SOLVER_EXTERNAL_VERSION_TOO_OLD,
    SOLVER_TIME_SPAN_INVALID,
    SOLVER_TIME_SPAN_VERSION_TOO_OLD,
    SOLVER_VERSION_TOO_OLD,
)

if TYPE_CHECKING:
    from .esm_types import EsmFile

__all__ = [
    "SolverBlockError",
    "reject_solver_external_pre_v13",
    "reject_solver_external_unresolved",
    "reject_solver_pre_v11",
    "reject_solver_time_span_invalid",
    "reject_solver_time_span_pre_v13",
    "resolve_time_span",
    "resolve_tolerances",
    "solver_external_location",
    "time_origin",
    "timestamp_to_seconds",
]

#: Canonical cross-binding tolerance defaults (API_SPEC §5.8), and the bottom of
#: the §2.2.2 chain: the same knobs under the same names produce comparable
#: trajectories in Julia, Python and Rust.
#:
#: These are Julia's values, and they are LOOSER than what this binding used to
#: default to (1e-10 / 1e-14). A default is what a document gets when its author
#: has expressed no opinion about accuracy, so it is the cheapest of the three
#: rather than the most accurate. A caller who needs tighter integration passes
#: `reltol=` / `abstol=` -- and a TEST that asserts trajectory accuracy must do
#: so, rather than lean on the default and thereby assert something about the
#: library's default instead of about the model.
#:
#: They live HERE, in the lowest module of the two, so `solve()`'s signature and
#: `resolve_tolerances`'s bottom-of-chain cannot drift apart; `problem.py`
#: re-exports them under its historical names. Rust does the same in the other
#: direction (`solver.rs` imports `simulate::DEFAULT_*`).
DEFAULT_RELTOL = 1e-4
DEFAULT_ABSTOL = 1e-6


class SolverBlockError(Exception):
    """Raised for a `solver` block a document may not carry.

    Carries the stable diagnostic ``code`` (esm-spec §2.2.5) alongside the
    message, matching how ``ExpressionTemplateError`` reports the §9.7 gate.
    """

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


def reject_solver_pre_v11(view: Any) -> None:
    """Reject a top-level `solver` block in a file declaring esm < 1.1.0.

    The block arrives at ``esm: 1.1.0``; a document declaring an earlier
    version that carries one is rejected with ``solver_version_too_old``
    (esm-spec §2.2.4). Mirrors :func:`reject_template_imports_pre_v08`.
    """
    if not isinstance(view, dict) or "solver" not in view:
        return
    version = _declared_minor(view)
    if version is None or version >= (1, 1):
        return
    raise SolverBlockError(
        SOLVER_VERSION_TOO_OLD,
        f"the top-level `solver` block requires esm >= 1.1.0; file declares {view['esm']}. "
        "Offending path: /solver",
    )


def _declared_minor(view: Any) -> tuple[int, int] | None:
    """``(major, minor)`` of the document's ``esm`` string, or ``None``."""
    esm = view.get("esm")
    if not isinstance(esm, str):
        return None
    m = re.match(r"^(\d+)\.(\d+)\.(\d+)$", esm)
    if not m:
        return None
    return int(m.group(1)), int(m.group(2))


def reject_solver_external_pre_v13(view: Any) -> None:
    """Reject ``solver.external`` in a file declaring esm < 1.3.0.

    The field arrives at ``esm: 1.3.0``; an earlier document whose ``solver``
    block carries it is rejected with ``solver_external_version_too_old`` at
    ``/solver/external`` (esm-spec §2.2.4 requirement 4). A document below
    1.1.0 never reaches this gate: :func:`reject_solver_pre_v11` refuses its
    whole block first.
    """
    if not isinstance(view, dict):
        return
    block = view.get("solver")
    if not isinstance(block, dict) or "external" not in block:
        return
    version = _declared_minor(view)
    if version is None or version >= (1, 3):
        return
    raise SolverBlockError(
        SOLVER_EXTERNAL_VERSION_TOO_OLD,
        f"`solver.external` requires esm >= 1.3.0; file declares {view['esm']}. "
        "Offending path: /solver/external",
    )


def reject_solver_time_span_pre_v13(view: Any) -> None:
    """Reject ``solver.time_span`` in a file declaring esm < 1.3.0.

    The field arrives at ``esm: 1.3.0``; an earlier document whose ``solver``
    block carries it is rejected with ``solver_time_span_version_too_old`` at
    ``/solver/time_span`` (esm-spec §2.2.4 requirement 4), before schema
    validation. A document below 1.1.0 never reaches this gate:
    :func:`reject_solver_pre_v11` refuses its whole block first.
    """
    if not isinstance(view, dict):
        return
    block = view.get("solver")
    if not isinstance(block, dict) or "time_span" not in block:
        return
    version = _declared_minor(view)
    if version is None or version >= (1, 3):
        return
    raise SolverBlockError(
        SOLVER_TIME_SPAN_VERSION_TOO_OLD,
        f"`solver.time_span` requires esm >= 1.3.0; file declares {view['esm']}. "
        "Offending path: /solver/time_span",
    )


def reject_solver_external_unresolved(view: Any) -> None:
    """Refuse a ``solver.external`` carrying ``${`` (esm-spec §2.2.6).

    There are no substitutions in ``external``: a run configuration chosen by
    the environment is not reproducible, so the reference is refused at load
    with ``solver_external_unresolved`` rather than expanded or passed through.
    """
    if not isinstance(view, dict):
        return
    block = view.get("solver")
    if not isinstance(block, dict):
        return
    external = block.get("external")
    if not isinstance(external, str) or "${" not in external:
        return
    raise SolverBlockError(
        SOLVER_EXTERNAL_UNRESOLVED,
        f"/solver/external: \"{external}\" carries an unexpanded '${{...}}' variable. "
        "esm-spec §2.2.6 does not expand environment variables into a run-"
        "configuration reference: a run configuration chosen by the environment "
        "is not reproducible. Write a path relative to this document, or pass "
        "the run configuration at the call site.",
    )


#: A drive-letter path, ``C:/`` or ``C:\\``: absolute on every host (§2.2.6).
_DRIVE_RE = re.compile(r"^[A-Za-z]:[/\\]")

#: The bytes a §2.2.6 location writes as themselves; every other byte of the
#: path's UTF-8 encoding is written ``%XX``.
_LOCATION_SAFE = frozenset(b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/:")


def _is_absolute(path: str) -> bool:
    return path.startswith("/") or _DRIVE_RE.match(path) is not None


def _lexical_absolute(path: str) -> str:
    """An absolute ``path`` with its dot segments removed (RFC 3986 §5.2.4).

    A drive-letter path comes back as ``C:/…``, its ``\\`` read as ``/`` and
    its drive a root that ``..`` does not climb above.
    """
    if _DRIVE_RE.match(path):
        return path[:2] + _remove_dot_segments(path[2:].replace("\\", "/"))
    return _remove_dot_segments(path)


def _absolute_directory(path: str | os.PathLike[str]) -> str:
    """``path`` as the absolute, dot-segment-free directory *D* of §2.2.6.

    A relative ``path`` is taken against the process working directory. Purely
    lexical: never ``realpath``, never touches the filesystem.
    """
    d = os.fspath(path) or "."
    if not _is_absolute(d):
        d = os.getcwd().replace(os.sep, "/") + "/" + d
    return _lexical_absolute(d)


def _file_url(path: str) -> str:
    """``file://`` plus ``path`` (absolute, dot-segment free), percent-encoded."""
    encoded = "".join(chr(b) if b in _LOCATION_SAFE else f"%{b:02X}" for b in path.encode("utf-8"))
    return "file://" + ("" if path.startswith("/") else "/") + encoded


def solver_external_location(
    esm_file: EsmFile, base: str | os.PathLike[str] | None = None
) -> str | None:
    """Where the document's ``solver.external`` points (esm-spec §2.2.6).

    Returns ``None`` when the document has no ``external``. Otherwise:

    - a URL (``scheme://…``) is returned unchanged;
    - an absolute path (``/…``, or a drive-letter ``C:/…`` / ``C:\\…``) has
      its dot segments removed, is percent-encoded and is prefixed ``file://``
      (``file:///C:/…`` for a drive);
    - anything else is joined onto *D*, dot segments removed, percent-encoded,
      and prefixed ``file://``.

    Percent-encoding writes each byte of the path's UTF-8 encoding outside
    ``A-Za-z0-9-._~/:`` as ``%XX``, ``%`` included: the input is a path, not a
    URL.

    *D* is ``base`` when given (a relative ``base`` is taken against the
    process working directory), else the directory the loader recorded: the
    directory of the file read, or the working directory for a string load or
    a document built in memory.

    Purely lexical (RFC 3986 §5.2.4): never ``realpath``, never touches the
    filesystem, so a location that does not exist resolves normally. The
    document keeps, and ``emit`` writes, the authored string.
    """
    solver = getattr(esm_file, "solver", None)
    external = getattr(solver, "external", None) if solver is not None else None
    if external is None:
        return None
    if _SCHEME_RE.match(external):
        return external
    if _is_absolute(external):
        return _file_url(_lexical_absolute(external))
    if base is not None:
        d = _absolute_directory(base)
    else:
        recorded = getattr(esm_file, "document_base", None)
        d = recorded if recorded is not None else _absolute_directory(os.getcwd())
    return _file_url(_lexical_absolute(d + "/" + external))


# ---------------------------------------------------------------------------
# `time_span` (esm-spec §2.2.7)
# ---------------------------------------------------------------------------

#: A ``time_span`` bound's timestamp form: the schema's pattern, RFC 3339 in UTC
#: with the ``Z`` required. Field ranges are the pattern's; whether the day
#: exists is the load-time check's. Both patterns end in ``\Z``, not ``$``:
#: Python's ``$`` also matches before a final newline, which the other bindings'
#: readers do not admit.
_BOUND_RE = re.compile(
    r"^([0-9]{4})-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])"
    r"T([01][0-9]|2[0-3]):([0-5][0-9]):([0-5][0-9])(?:\.([0-9]+))?Z\Z"
)

#: A time ORIGIN (``domain.temporal.reference_time`` / ``start``): an RFC 3339
#: date-time, ``T`` or ``t``, a fraction allowed, and ``Z``, ``z`` or a
#: ``±hh:mm`` offset (§2.2.7).
_ORIGIN_RE = re.compile(
    r"^([0-9]{4})-([0-9]{2})-([0-9]{2})[Tt]([0-9]{2}):([0-9]{2}):([0-9]{2})"
    r"(?:\.([0-9]+))?(?:([Zz])|([+-])([0-9]{2}):([0-9]{2}))\Z"
)

_POSIX_EPOCH = "1970-01-01T00:00:00Z"


class _NoCalendarDay(ValueError):
    """A date-time whose fields name no calendar day (``2019-02-30``)."""


def _days_from_civil(y: int, m: int, d: int) -> int:
    """Days from 1970-01-01 to ``y-m-d``, proleptic Gregorian, exact integers.

    H. Hinnant's ``days_from_civil``; deliberately not a host date library,
    whose range and calendar handling §2.2.7 does not let a binding rely on.
    """
    y -= 1 if m <= 2 else 0
    era = y // 400
    yoe = y - era * 400
    doy = (153 * (m + (-3 if m > 2 else 9)) + 2) // 5 + d - 1
    doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468


def _is_leap(y: int) -> bool:
    return y % 4 == 0 and (y % 100 != 0 or y % 400 == 0)


def _days_in_month(y: int, m: int) -> int:
    if m == 2:
        return 29 if _is_leap(y) else 28
    return 30 if m in (4, 6, 9, 11) else 31


def _whole_and_fraction(
    y: int, mo: int, d: int, h: int, mi: int, sec: int, frac: str | None, offset_s: int
) -> tuple[int, float]:
    """(*W*, *f*) of §2.2.7: integer POSIX seconds with the offset subtracted,
    and the fraction digits read as a binary64 in ``[0, 1)``."""
    if not (1 <= mo <= 12 and 1 <= d <= _days_in_month(y, mo)):
        raise _NoCalendarDay(f"{y:04d}-{mo:02d}-{d:02d}")
    whole = _days_from_civil(y, mo, d) * 86400 + h * 3600 + mi * 60 + sec - offset_s
    return whole, (float("0." + frac) if frac else 0.0)


def _parse_bound_timestamp(which: str, text: str) -> tuple[int, float]:
    """(*W*, *f*) of a timestamp bound. Raises ``solver_time_span_invalid`` when
    it does not match :data:`_BOUND_RE` (reachable only for a document built in
    memory: load leaves that to the schema) and :class:`_NoCalendarDay` when it
    matches but names no calendar day."""
    m = _BOUND_RE.match(text)
    if m is None:
        raise SolverBlockError(
            SOLVER_TIME_SPAN_INVALID,
            f'/solver/time_span/{which}: "{text}" is not an RFC 3339 UTC timestamp '
            "(YYYY-MM-DDThh:mm:ss[.f]Z). Offending path: /solver/time_span",
        )
    y, mo, d, h, mi, sec = (int(g) for g in m.groups()[:6])
    return _whole_and_fraction(y, mo, d, h, mi, sec, m.group(7), 0)


def _parse_origin(text: Any) -> tuple[int, float] | None:
    """(*W₀*, *f₀*) of a time origin, or ``None`` when it is not an RFC 3339
    date-time in the §2.2.7 form or names no calendar day."""
    if not isinstance(text, str):
        return None
    m = _ORIGIN_RE.match(text)
    if m is None:
        return None
    y, mo, d, h, mi, sec = (int(g) for g in m.groups()[:6])
    if h > 23 or mi > 59 or sec > 59:
        return None
    if m.group(8) is not None:
        offset_s = 0
    else:
        oh, om = int(m.group(10)), int(m.group(11))
        if oh > 23 or om > 59:
            return None
        offset_s = (1 if m.group(9) == "+" else -1) * (oh * 3600 + om * 60)
    try:
        return _whole_and_fraction(y, mo, d, h, mi, sec, m.group(7), offset_s)
    except _NoCalendarDay:
        return None


def _is_number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _schema_valid_bound(value: Any) -> bool:
    return _is_number(value) or (isinstance(value, str) and _BOUND_RE.match(value) is not None)


def _origin_field(temporal: Any) -> tuple[str, Any]:
    """The origin that applies (§2.2.7), as ``(pointer, authored value)``:
    ``reference_time``, else ``start``, else the POSIX epoch (pointer ``""``).

    ``temporal`` is the raw ``domain.temporal`` dict or a typed
    :class:`~earthsci_ast.esm_types.TemporalDomain`.
    """

    for name in ("reference_time", "start"):
        if isinstance(temporal, dict):
            # A PRESENT key selects its field whatever its value, ``null``
            # included; an unreadable one is refused, never skipped (§2.2.7).
            if name in temporal:
                return f"/domain/temporal/{name}", temporal[name]
        elif temporal is not None:
            # The typed form cannot hold an authored ``null`` (the load-time
            # check has already refused it), so ``None`` here means absent.
            value = getattr(temporal, name, None)
            if value is not None:
                return f"/domain/temporal/{name}", value
    return "", _POSIX_EPOCH


def _time_span_seconds(start: Any, end: Any, temporal: Any) -> tuple[float, float]:
    """Both bounds in binary64 seconds on the document's clock (§2.2.7), checked.

    Raises :class:`SolverBlockError` (``solver_time_span_invalid``) when a
    bound is neither a finite number nor a timestamp in the schema's form, a
    timestamp names no calendar day, the origin a timestamp needs cannot be
    read, or ``end`` is not after ``start``.
    """
    origin: tuple[int, float] | None = None

    def convert(which: str, value: Any) -> float:
        nonlocal origin
        if _is_number(value):
            try:
                seconds = float(value)
            except OverflowError:  # an integer literal past binary64
                seconds = math.inf
            if not math.isfinite(seconds):
                raise SolverBlockError(
                    SOLVER_TIME_SPAN_INVALID,
                    f"/solver/time_span/{which} ({value!r}) is not a finite number of "
                    "seconds in binary64 (esm-spec §2.2.7). Offending path: /solver/time_span",
                )
            return seconds
        if not isinstance(value, str):
            raise SolverBlockError(
                SOLVER_TIME_SPAN_INVALID,
                f"/solver/time_span/{which} ({value!r}) is neither a number nor a "
                "timestamp. Offending path: /solver/time_span",
            )
        try:
            whole, frac = _parse_bound_timestamp(which, value)
        except _NoCalendarDay:
            raise SolverBlockError(
                SOLVER_TIME_SPAN_INVALID,
                f'/solver/time_span/{which}: "{value}" names no calendar day. '
                "Offending path: /solver/time_span",
            ) from None
        if origin is None:
            pointer, authored = _origin_field(temporal)
            origin = _parse_origin(authored)
            if origin is None:
                raise SolverBlockError(
                    SOLVER_TIME_SPAN_INVALID,
                    f"/solver/time_span/{which} is a timestamp, which counts seconds from "
                    f"the document's time origin, but {pointer} ({authored!r}) is not an "
                    "RFC 3339 date-time naming a calendar day (esm-spec §2.2.7). "
                    "Offending path: /solver/time_span",
                )
        w0, f0 = origin
        return float(whole - w0) + (frac - f0)

    lo, hi = convert("start", start), convert("end", end)
    if not hi > lo:
        raise SolverBlockError(
            SOLVER_TIME_SPAN_INVALID,
            f"/solver/time_span: `end` ({end!r}, {hi!r} s) is not after `start` "
            f"({start!r}, {lo!r} s); a time_span must describe a non-empty interval "
            "(esm-spec §2.2.7). Offending path: /solver/time_span",
        )
    return lo, hi


def reject_solver_time_span_invalid(view: Any) -> None:
    """Refuse a ``solver.time_span`` that describes no interval (esm-spec §2.2.7).

    Converts both bounds to seconds and raises ``solver_time_span_invalid``,
    naming ``/solver/time_span``, when ``end`` is not after ``start``, when a
    timestamp names no calendar day, or when a bound is a timestamp and the
    origin field that applies cannot be read (the message then names that
    field's pointer too). Runs only when both bounds have a schema-valid form;
    anything else is the schema's to report. Called on the root document only.
    """
    if not isinstance(view, dict):
        return
    block = view.get("solver")
    if not isinstance(block, dict):
        return
    span = block.get("time_span")
    if not isinstance(span, dict) or "start" not in span or "end" not in span:
        return
    start, end = span["start"], span["end"]
    if not (_schema_valid_bound(start) and _schema_valid_bound(end)):
        return
    domain = view.get("domain")
    temporal = domain.get("temporal") if isinstance(domain, dict) else None
    _time_span_seconds(start, end, temporal)


def resolve_time_span(
    esm_file: EsmFile, tspan: tuple[float, float] | None = None
) -> tuple[float, float] | None:
    """The interval a run should cover, most-specific first (esm-spec §2.2.7).

    1. ``tspan``, an explicit call-site interval: it always wins, both bounds.
    2. Otherwise the document's ``solver.time_span``, converted to binary64
       seconds: a number bound is its value; a timestamp is seconds from the
       document's time origin (``domain.temporal.reference_time``, else
       ``domain.temporal.start``, else the POSIX epoch), computed as
       ``(W - W0) + (f - f0)`` -- whole seconds in integers, then the
       fractions in binary64.
    3. Otherwise ``None``: no interval, not a default one.

    The document keeps, and ``emit`` writes, the authored bounds; the converted
    value is never written back. Raises ``solver_time_span_invalid`` for an
    interval a load would have refused (a document built in memory is not
    checked at load), and for a bound whose form is not the schema's.
    """
    if tspan is not None:
        start, end = tspan
        return float(start), float(end)
    solver = getattr(esm_file, "solver", None)
    span = getattr(solver, "time_span", None) if solver is not None else None
    if span is None:
        return None
    domain = getattr(esm_file, "domain", None)
    temporal = getattr(domain, "temporal", None) if domain is not None else None
    return _time_span_seconds(span.start, span.end, temporal)


def _document_origin_parts(esm_file: EsmFile) -> tuple[int, float]:
    """(*W₀*, *f₀*) of the document's time origin, or a refusal (esm-spec §2.2.7).

    The origin is ``domain.temporal.reference_time``, else
    ``domain.temporal.start``, else the POSIX epoch. Raises
    ``solver_time_span_invalid`` naming ``/domain/temporal/...`` when the field
    that applies is present but is not an RFC 3339 date-time naming a calendar
    day.
    """
    domain = getattr(esm_file, "domain", None)
    temporal = getattr(domain, "temporal", None) if domain is not None else None
    pointer, authored = _origin_field(temporal)
    parsed = _parse_origin(authored)
    if parsed is None:
        raise SolverBlockError(
            SOLVER_TIME_SPAN_INVALID,
            f"the document's time origin {pointer} ({authored!r}) is not an RFC 3339 "
            "date-time naming a calendar day (esm-spec §2.2.7)",
        )
    return parsed


def time_origin(esm_file: EsmFile) -> float:
    """The document's time origin in binary64 seconds from the POSIX epoch.

    The instant ``domain.temporal.reference_time`` -- else
    ``domain.temporal.start``, else the epoch itself -- names, as ``W0 + f0``:
    whole seconds in integers and the fraction in binary64. This is the origin a
    ``solver.time_span`` timestamp counts from (esm-spec §2.2.7), exposed so a
    caller does the same arithmetic for a timestamp of its own with
    :func:`timestamp_to_seconds`.

    Raises ``solver_time_span_invalid`` naming ``/domain/temporal/...`` when the
    origin field that applies is present but is not an RFC 3339 date-time naming
    a calendar day.
    """
    whole, frac = _document_origin_parts(esm_file)
    return float(whole) + frac


def timestamp_to_seconds(esm_file: EsmFile, timestamp: str) -> float:
    """``timestamp`` as seconds from ``esm_file``'s time origin (esm-spec §2.2.7).

    ``timestamp`` is an RFC 3339 UTC timestamp (``YYYY-MM-DDThh:mm:ss[.f]Z``,
    the ``solver.time_span`` bound form). The result is ``(W - W0) + (f - f0)``:
    the whole-second difference in integers, then the fractions added in
    binary64 -- exactly what :func:`resolve_time_span` does to a ``time_span``
    timestamp. The origin is :func:`time_origin`.

    Raises ``solver_time_span_invalid`` when ``timestamp`` is not of that form or
    names no calendar day, or when the document's origin cannot be read.
    """
    if not isinstance(timestamp, str) or _BOUND_RE.match(timestamp) is None:
        raise SolverBlockError(
            SOLVER_TIME_SPAN_INVALID,
            f'timestamp "{timestamp}" is not an RFC 3339 UTC timestamp '
            "(YYYY-MM-DDThh:mm:ss[.f]Z) (esm-spec §2.2.7)",
        )
    try:
        whole, frac = _parse_bound_timestamp("timestamp", timestamp)
    except _NoCalendarDay:
        raise SolverBlockError(
            SOLVER_TIME_SPAN_INVALID,
            f'timestamp "{timestamp}" names no calendar day (esm-spec §2.2.7)',
        ) from None
    w0, f0 = _document_origin_parts(esm_file)
    return float(whole - w0) + (frac - f0)


def resolve_tolerances(
    solver: Any,
    abstol: float | None = None,
    reltol: float | None = None,
) -> tuple[float, float]:
    """Resolve integration tolerances most-specific first (esm-spec §2.2.2).

    ``solver`` may be a :class:`~earthsci_ast.esm_types.Solver`, the raw
    ``solver`` block as a dict (what ``EsmProblem.doc`` carries), or ``None``.

    1. An explicit argument at the ``solve()`` call site — wins outright.
    2. Otherwise the document's ``solver.abstol`` / ``solver.reltol``.
    3. Otherwise the binding default (``reltol`` 1e-4, ``abstol`` 1e-6).

    The two tolerances resolve INDEPENDENTLY: a document that declares only
    ``reltol`` leaves ``abstol`` to fall through to the default, exactly as
    §6.6.4 merges its own chain per field.

    These are INTEGRATION tolerances. They are a different quantity from the
    ``tolerance`` object an assertion is compared at (§6.6.4), which resolves
    on its own chain and is not touched here.
    """
    if isinstance(solver, dict):
        doc_abstol = solver.get("abstol")
        doc_reltol = solver.get("reltol")
    else:
        doc_abstol = getattr(solver, "abstol", None) if solver is not None else None
        doc_reltol = getattr(solver, "reltol", None) if solver is not None else None
    resolved_abstol = (
        abstol if abstol is not None else (doc_abstol if doc_abstol is not None else DEFAULT_ABSTOL)
    )
    resolved_reltol = (
        reltol if reltol is not None else (doc_reltol if doc_reltol is not None else DEFAULT_RELTOL)
    )
    return resolved_abstol, resolved_reltol
