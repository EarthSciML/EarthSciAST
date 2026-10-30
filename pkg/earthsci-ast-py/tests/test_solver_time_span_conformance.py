"""esm-spec §2.2.7 `solver.time_span`, against the SHARED pin.

Reads ``tests/conformance/solver_time_span/manifest.json`` and asserts this
binding against it (CONFORMANCE_SPEC §5.49). An accepted fixture pins two
things: what :func:`earthsci_ast.resolve_time_span` returns with no call-site
interval (binary64 seconds, compared EXACTLY), and the root's ``solver`` block
as ``emit`` writes it (the authored bounds, compared as JSON values). A refused
fixture pins the diagnostic code and substrings of its message.
"""

from __future__ import annotations

import json
import math
from pathlib import Path

import pytest

import earthsci_ast
from earthsci_ast.error_handling import ERROR_CODES
from earthsci_ast.esm_types import EsmFile, Metadata, Solver, SolverTimeSpan

REPO_ROOT = Path(__file__).resolve().parents[3]
SUITE = REPO_ROOT / "tests" / "conformance" / "solver_time_span"
MANIFEST = json.loads((SUITE / "manifest.json").read_text())

BY_ID = {f["id"]: f for f in MANIFEST["fixtures"]}
ACCEPTED = [f for f in MANIFEST["fixtures"] if f["expect"] == "accepted"]
REFUSED = [f for f in MANIFEST["fixtures"] if f["expect"] == "refused"]
CALL_SITE = MANIFEST["call_site"]["cases"]


def _load(fixture: dict) -> earthsci_ast.EsmFile:
    return earthsci_ast.load_path(str(SUITE / fixture["path"]))


def test_the_manifest_requires_this_binding() -> None:
    assert "python" in MANIFEST["bindings_required"]


@pytest.mark.parametrize("fixture", ACCEPTED, ids=[f["id"] for f in ACCEPTED])
def test_time_span_resolves_as_pinned(fixture: dict) -> None:
    loaded = _load(fixture)

    seconds = earthsci_ast.resolve_time_span(loaded)
    if fixture["seconds"] is None:
        assert seconds is None
    else:
        assert seconds is not None
        assert all(isinstance(s, float) for s in seconds)
        # Exact binary64 equality: every pinned value is exact.
        assert list(seconds) == [float(s) for s in fixture["seconds"]]

    emitted = json.loads(earthsci_ast.to_json(loaded))
    assert emitted.get("solver") == fixture["solver"]


WITH_SPAN = [f for f in ACCEPTED if (f["solver"] or {}).get("time_span") is not None]


@pytest.mark.parametrize("fixture", WITH_SPAN, ids=[f["id"] for f in WITH_SPAN])
def test_emit_keeps_each_bound_in_its_authored_form(fixture: dict) -> None:
    """§2.2.4 requirement 2: a timestamp stays the string, a number stays a number."""
    pinned = fixture["solver"]["time_span"]
    emitted = json.loads(earthsci_ast.to_json(_load(fixture)))["solver"]["time_span"]
    for key in ("start", "end"):
        assert isinstance(emitted[key], str) == isinstance(pinned[key], str)


@pytest.mark.parametrize("fixture", REFUSED, ids=[f["id"] for f in REFUSED])
def test_a_time_span_that_is_no_interval_is_refused(fixture: dict) -> None:
    code = fixture["error_code"]
    assert code in ERROR_CODES.values()
    with pytest.raises(earthsci_ast.SolverBlockError) as excinfo:
        _load(fixture)
    err = excinfo.value
    assert err.code == code, f"expected {code!r}, got {err!r}"
    for needle in fixture["message_contains"]:
        assert needle in str(err), f"the diagnostic must name {needle!r}; got: {err}"


@pytest.mark.parametrize(
    "case", CALL_SITE, ids=[f"{c['fixture']}-{c['call_site']}" for c in CALL_SITE]
)
def test_a_call_site_interval_wins_both_bounds(case: dict) -> None:
    loaded = _load(BY_ID[case["fixture"]])
    resolved = earthsci_ast.resolve_time_span(loaded, tuple(case["call_site"]))
    assert resolved == tuple(float(s) for s in case["resolved"])


def test_the_gates_run_before_schema_validation_in_order() -> None:
    """Version gate first; the invalid check still precedes the schema."""
    doc = json.loads((SUITE / "fixtures" / "version_too_old.esm").read_text())
    doc["solver"]["not_a_solver_key"] = True
    with pytest.raises(earthsci_ast.SolverBlockError) as excinfo:
        earthsci_ast.load_document(doc)
    assert excinfo.value.code == "solver_time_span_version_too_old"

    doc = json.loads((SUITE / "fixtures" / "equal_bounds.esm").read_text())
    doc["solver"]["not_a_solver_key"] = True
    with pytest.raises(earthsci_ast.SolverBlockError) as excinfo:
        earthsci_ast.load_document(doc)
    assert excinfo.value.code == "solver_time_span_invalid"


def test_the_pre_1_1_gate_wins_over_the_time_span_gate() -> None:
    doc = json.loads((SUITE / "fixtures" / "numbers.esm").read_text())
    doc["esm"] = "1.0.0"
    with pytest.raises(earthsci_ast.SolverBlockError) as excinfo:
        earthsci_ast.load_document(doc)
    assert excinfo.value.code == "solver_version_too_old"


def test_a_malformed_bound_is_left_to_the_schema() -> None:
    """An offset bound is not schema-valid in form, so the load-time check
    skips it even though the interval would be reversed."""
    doc = json.loads((SUITE / "fixtures" / "numbers.esm").read_text())
    doc["solver"]["time_span"] = {"start": "2019-07-03T02:00:00+02:00", "end": 0}
    with pytest.raises(Exception) as excinfo:  # noqa: PT011 - the code is the assertion
        earthsci_ast.load_document(doc)
    assert getattr(excinfo.value, "code", None) != "solver_time_span_invalid"


def test_numbers_alone_never_read_the_origin() -> None:
    """A binding reads the origin only when a bound is a timestamp."""
    doc = json.loads((SUITE / "fixtures" / "unreadable_origin.esm").read_text())
    doc["solver"]["time_span"] = {"start": 0, "end": 1}
    loaded = earthsci_ast.load_document(doc)
    assert earthsci_ast.resolve_time_span(loaded) == (0.0, 1.0)


def _in_memory(start, end, temporal: dict) -> EsmFile:
    from earthsci_ast.esm_types import Domain, TemporalDomain

    f = EsmFile(
        version="1.3.0",
        metadata=Metadata(title="m"),
        solver=Solver(time_span=SolverTimeSpan(start=start, end=end)),
    )
    if temporal:
        f.domain = Domain(temporal=TemporalDomain(**temporal))
    return f


@pytest.mark.parametrize(
    ("start", "end", "temporal", "expected"),
    [
        # Far outside any host date library's comfortable range.
        ("0001-01-01T00:00:00Z", "9999-12-31T23:59:59Z", {}, (-62135596800.0, 253402300799.0)),
        # Negative offset on the origin: 22:00 at -02:00 is midnight UTC.
        (
            "2019-07-02T00:00:00Z",
            "2019-07-02T00:00:00.5Z",
            {"start": "2019-07-01T22:00:00-02:00"},
            (0.0, 0.5),
        ),
        # The origin's fraction is subtracted in binary64.
        (
            "2019-07-01T00:00:01Z",
            "2019-07-01T00:00:02Z",
            {"reference_time": "2019-07-01T00:00:00.5z"},
            (0.5, 1.5),
        ),
    ],
)
def test_conversion_is_exact_arithmetic_on_the_fields(start, end, temporal, expected) -> None:
    assert earthsci_ast.resolve_time_span(_in_memory(start, end, temporal)) == expected


def test_the_accessor_on_a_document_without_a_solver_block() -> None:
    f = EsmFile(version="1.3.0", metadata=Metadata(title="m"))
    assert earthsci_ast.resolve_time_span(f) is None
    assert earthsci_ast.resolve_time_span(f, (1, 2)) == (1.0, 2.0)


@pytest.mark.parametrize("field", ["reference_time", "start"])
def test_a_null_origin_field_is_present_and_unreadable(field: str) -> None:
    """§2.2.7: a present origin key selects that field, ``null`` included; it is
    refused, never skipped in favour of the next field."""
    doc = json.loads((SUITE / "fixtures" / "timestamps_temporal_start.esm").read_text())
    doc["domain"]["temporal"][field] = None
    with pytest.raises(earthsci_ast.SolverBlockError) as excinfo:
        earthsci_ast.load_document(doc)
    assert excinfo.value.code == "solver_time_span_invalid"
    assert "/solver/time_span" in str(excinfo.value)
    assert f"/domain/temporal/{field}" in str(excinfo.value)


@pytest.mark.parametrize(
    "origin",
    ["2019-06-30T23:59:60Z", "2019-07-01T00:00:00+24:00", "2019-07-01T00:00:00+02:60"],
)
def test_a_leap_second_or_out_of_range_offset_origin_is_unreadable(origin: str) -> None:
    doc = json.loads((SUITE / "fixtures" / "timestamps_reference_time.esm").read_text())
    doc["domain"]["temporal"]["reference_time"] = origin
    with pytest.raises(earthsci_ast.SolverBlockError) as excinfo:
        earthsci_ast.load_document(doc)
    assert excinfo.value.code == "solver_time_span_invalid"
    assert "/domain/temporal/reference_time" in str(excinfo.value)


@pytest.mark.parametrize(
    ("start", "end", "needle"),
    [
        (100, 0, "is not after"),
        (1.0, 1.0, "is not after"),
        ("2019-07-01", "2019-07-02T00:00:00Z", "not an RFC 3339 UTC timestamp"),
        (0, float("inf"), "not a finite number"),
        (None, 1, "neither a number nor a timestamp"),
    ],
)
def test_the_accessor_refuses_what_a_load_would(start, end, needle: str) -> None:
    """A document built in memory skips the load-time check, so the accessor
    makes it, with the same code as the other four bindings."""
    with pytest.raises(earthsci_ast.SolverBlockError) as excinfo:
        earthsci_ast.resolve_time_span(_in_memory(start, end, {}))
    assert excinfo.value.code == "solver_time_span_invalid"
    assert needle in str(excinfo.value)


@pytest.mark.parametrize("end", [10**400, float("inf")], ids=["huge_integer", "overflowed_float"])
def test_a_bound_past_binary64_is_refused_at_load(end) -> None:
    """`json` reads a 400-digit literal as an int and `1e400` as inf; both are
    refused with the ESM code, not an OverflowError."""
    doc = json.loads((SUITE / "fixtures" / "numbers.esm").read_text())
    doc["solver"]["time_span"]["end"] = end
    with pytest.raises(earthsci_ast.SolverBlockError) as excinfo:
        earthsci_ast.load_document(doc)
    assert excinfo.value.code == "solver_time_span_invalid"


def test_a_trailing_newline_is_not_a_date_time() -> None:
    """`$` would admit a final newline; the patterns end at the string's end,
    as RE2, JavaScript and the Rust reader do."""
    doc = json.loads((SUITE / "fixtures" / "timestamps_reference_time.esm").read_text())
    doc["domain"]["temporal"]["reference_time"] = "2019-07-01T00:00:00Z\n"
    with pytest.raises(earthsci_ast.SolverBlockError) as excinfo:
        earthsci_ast.load_document(doc)
    assert excinfo.value.code == "solver_time_span_invalid"
    assert "/domain/temporal/reference_time" in str(excinfo.value)

    # A bound with one is not in the timestamp form, so the load-time check
    # leaves it to the schema, and the accessor names its form.
    from earthsci_ast import solver

    assert not solver._schema_valid_bound("2019-07-03T00:00:00Z\n")
    with pytest.raises(earthsci_ast.SolverBlockError) as excinfo:
        earthsci_ast.resolve_time_span(
            _in_memory("2019-07-03T00:00:00Z\n", "2019-07-04T00:00:00Z", {})
        )
    assert "not an RFC 3339 UTC timestamp" in str(excinfo.value)


# --- the §2.2.7 public accessors: time_origin / timestamp_to_seconds ----------

#: Each fixture's time origin as POSIX seconds: reference_time, else
#: temporal.start, else the epoch. `numbers` declares no `domain.temporal`.
_ORIGIN_SECONDS = {
    "timestamps_posix": 0.0,
    "timestamps_reference_time": 1561939200.0,  # 2019-07-01T00:00:00Z
    "timestamps_temporal_start": 1561852800.0,  # 2019-06-30T00:00:00Z
    "origin_with_offset": 1561939200.0,  # 2019-07-01T02:00:00+02:00
    "fractional_seconds": 1561939200.25,  # 2019-07-01T00:00:00.25Z
    "numbers": 0.0,
}


@pytest.mark.parametrize(("fixture_id", "expected"), sorted(_ORIGIN_SECONDS.items()))
def test_time_origin_is_the_instant_the_document_names(fixture_id: str, expected: float) -> None:
    assert earthsci_ast.time_origin(_load(BY_ID[fixture_id])) == expected


@pytest.mark.parametrize("fixture", WITH_SPAN, ids=[f["id"] for f in WITH_SPAN])
def test_timestamp_to_seconds_agrees_with_resolve_time_span(fixture: dict) -> None:
    """The converter IS the span's arithmetic on a bare timestamp."""
    loaded = _load(fixture)
    span = fixture["solver"]["time_span"]
    resolved = earthsci_ast.resolve_time_span(loaded)
    assert resolved is not None
    for index, key in ((0, "start"), (1, "end")):
        if isinstance(span[key], str):
            assert earthsci_ast.timestamp_to_seconds(loaded, span[key]) == resolved[index]


def test_timestamp_to_seconds_counts_from_the_document_origin() -> None:
    ref = _load(BY_ID["timestamps_reference_time"])
    assert earthsci_ast.timestamp_to_seconds(ref, "2019-07-01T00:00:00Z") == 0.0
    assert earthsci_ast.timestamp_to_seconds(ref, "2019-07-03T00:00:00Z") == 172800.0
    frac = _load(BY_ID["fractional_seconds"])
    assert earthsci_ast.timestamp_to_seconds(frac, "2019-07-01T00:00:00.5Z") == 0.25
    assert earthsci_ast.timestamp_to_seconds(frac, "2019-07-01T00:00:01.25Z") == 1.0


def test_the_origin_and_converter_are_consistent_for_exactly_representable_timestamps() -> None:
    """For `.0`/`.5` fractions, `time_origin + timestamp_to_seconds == POSIX time`."""
    posix = _load(BY_ID["timestamps_posix"])
    ref = _load(BY_ID["timestamps_reference_time"])
    for stamp in ("2019-07-01T00:00:00Z", "2019-07-03T00:00:00Z", "2019-07-01T00:00:00.5Z"):
        assert earthsci_ast.timestamp_to_seconds(posix, stamp) == earthsci_ast.time_origin(
            ref
        ) + earthsci_ast.timestamp_to_seconds(ref, stamp)


def test_reconstruction_from_the_pair_is_correct_only_to_within_rounding() -> None:
    """`time_origin + timestamp_to_seconds` rounds the two parts separately."""
    f = _in_memory(
        "2019-07-01T00:00:00.1Z",
        "2019-07-01T00:00:01Z",
        {"reference_time": "2019-07-01T00:00:00.2Z"},
    )
    origin = earthsci_ast.time_origin(f)
    converted = earthsci_ast.timestamp_to_seconds(f, "2019-07-01T00:00:00.1Z")
    assert converted == -0.1
    assert origin == 1561939200.2
    # One ulp above the timestamp's own POSIX time, 1561939200.1.
    assert origin + converted == math.nextafter(1561939200.1, math.inf)


def test_time_origin_refuses_an_unreadable_origin() -> None:
    f = _in_memory(0, 1, {"reference_time": "not-a-date"})
    with pytest.raises(earthsci_ast.SolverBlockError) as excinfo:
        earthsci_ast.time_origin(f)
    assert excinfo.value.code == "time_origin_invalid"
    assert "/domain/temporal/reference_time" in str(excinfo.value)


def test_timestamp_to_seconds_refuses_a_bad_timestamp_or_origin() -> None:
    ref = _load(BY_ID["timestamps_reference_time"])
    with pytest.raises(earthsci_ast.SolverBlockError) as excinfo:
        earthsci_ast.timestamp_to_seconds(ref, "2019-07-01")
    assert excinfo.value.code == "timestamp_malformed"
    assert "not an RFC 3339 UTC timestamp" in str(excinfo.value)

    with pytest.raises(earthsci_ast.SolverBlockError) as excinfo:
        earthsci_ast.timestamp_to_seconds(ref, "2019-02-30T00:00:00Z")
    assert excinfo.value.code == "timestamp_no_calendar_day"
    assert "names no calendar day" in str(excinfo.value)

    with pytest.raises(earthsci_ast.SolverBlockError) as excinfo:
        earthsci_ast.timestamp_to_seconds(
            _in_memory(0, 1, {"reference_time": "not-a-date"}), "2019-07-01T00:00:00Z"
        )
    assert excinfo.value.code == "time_origin_invalid"
    assert "/domain/temporal/reference_time" in str(excinfo.value)


def test_resolve_time_span_keeps_its_one_code() -> None:
    """The accessors' codes are theirs: `resolve_time_span` raises
    `solver_time_span_invalid` whatever the cause."""
    f = _in_memory("2019-07-01T00:00:00Z", "2019-07-02T00:00:00Z", {"reference_time": "x"})
    with pytest.raises(earthsci_ast.SolverBlockError) as excinfo:
        earthsci_ast.resolve_time_span(f)
    assert excinfo.value.code == "solver_time_span_invalid"


def test_the_accessors_refuse_a_source_that_is_no_domain() -> None:
    with pytest.raises(TypeError):
        earthsci_ast.time_origin("model.esm")  # type: ignore[arg-type]


# --- the shared pin of the clock accessors (manifest `clock`) -----------------

CLOCK = MANIFEST["clock"]


def test_the_clock_pin_requires_this_binding() -> None:
    assert "python" in CLOCK["bindings_required"]


def _clock_forms(case: dict) -> list:
    """The case's domain as raw JSON, and, when `typed`, as a typed `Domain`
    and inside a document built in memory."""
    from earthsci_ast.esm_types import Domain, TemporalDomain

    raw = case["domain"]
    forms: list = [raw]
    if case["typed"]:
        typed = None
        if raw is not None:
            temporal = raw.get("temporal")
            typed = Domain(temporal=None if temporal is None else TemporalDomain(**temporal))
            forms.append(typed)
        forms.append(EsmFile(version="1.3.0", metadata=Metadata(title="m"), domain=typed))
    return forms


def _attempt(call):
    try:
        return ("ok", call())
    except earthsci_ast.SolverBlockError as exc:
        return ("error", exc.code)


def _expected(want: dict):
    return ("ok", float(want["seconds"])) if "seconds" in want else ("error", want["error_code"])


@pytest.mark.parametrize("case", CLOCK["cases"], ids=[c["id"] for c in CLOCK["cases"]])
def test_the_clock_accessors_on_a_domain(case: dict) -> None:
    for form in _clock_forms(case):
        got = _attempt(lambda: earthsci_ast.time_origin(form))  # noqa: B023
        assert got == _expected(case["origin"]), (type(form).__name__, got)
        if got[0] == "ok":
            assert isinstance(got[1], float)
        for t in case["timestamps"]:
            got = _attempt(lambda: earthsci_ast.timestamp_to_seconds(form, t["timestamp"]))  # noqa: B023
            assert got == _expected(t), (type(form).__name__, t["timestamp"], got)
