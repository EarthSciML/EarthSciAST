"""The ``tests/closed_functions`` scenarios through the standard-library templates.

Every scenario of ``tests/closed_functions/{interp,datetime}/*/expected.json`` is
applied to its template of ``esm:std/interp.esm`` or ``esm:std/calendar.esm``,
loaded and expanded by the normal load path, and evaluated by the scalar
interpreter. The oracle is the template contract of esm-spec §9.8:

- interp: each success scenario's ``expected``, bit for bit (NaN matches NaN).
  The ``error_scenarios`` are invalid tables (non-monotonic axis, NaN in an
  axis, length mismatch); the templates have no contract for them, so they are
  not run.
- datetime: each ``scenarios`` and ``error_scenarios`` instant ``t`` gives NaN
  when ``t`` is NaN, infinite or ``|t| >= 2^52`` s, and the scenario's
  ``expected`` otherwise (within the file's tolerance). The domain edges
  ``±(2^52 - 1)``, ``±(2^52 - 0.5)`` are checked against an exact integer
  proleptic-Gregorian computation (§9.8.2), and ``±2^52`` against NaN.
"""

from __future__ import annotations

import json
import math
import struct
import warnings
from pathlib import Path
from typing import Any

import pytest
from conftest import FIXTURES_ROOT

from earthsci_ast import load_string
from earthsci_ast.expr_walk import walk
from earthsci_ast.numpy_interpreter import evaluate

SCENARIO_ROOT = FIXTURES_ROOT / "closed_functions"
_CALENDAR_DOMAIN = 2.0**52
_CALENDAR_FIELDS = (
    "year",
    "month",
    "day",
    "hour",
    "minute",
    "second",
    "day_of_year",
    "julian_day",
    "is_leap_year",
)


def _fixture_dirs(module: str) -> list[Path]:
    root = SCENARIO_ROOT / module
    return sorted(p for p in root.iterdir() if (p / "expected.json").is_file())


_INTERP_DIRS = _fixture_dirs("interp")
_DATETIME_DIRS = _fixture_dirs("datetime")


def _decode(v: Any) -> Any:
    """A JSON scenario value: ``"NaN"``, ``"Inf"`` and ``"-Inf"`` are the
    non-finite numbers; arrays recurse."""
    if isinstance(v, str):
        return {"NaN": math.nan, "Inf": math.inf, "-Inf": -math.inf}[v]
    if isinstance(v, list):
        return [_decode(x) for x in v]
    return float(v)


def _same_bits(a: float, b: float) -> bool:
    if math.isnan(a) or math.isnan(b):
        return math.isnan(a) and math.isnan(b)
    return struct.pack("<d", a) == struct.pack("<d", b)


def _agrees(actual: float, expected: float, tol: dict) -> bool:
    if tol.get("abs", 0) == 0 and tol.get("rel", 0) == 0:
        return _same_bits(actual, expected)
    if math.isnan(actual) or math.isnan(expected):
        return math.isnan(actual) and math.isnan(expected)
    diff = abs(actual - expected)
    return diff <= tol.get("abs", 0) or diff <= tol.get("rel", 0) * max(1.0, abs(expected))


def _template_free(rhs: Any) -> bool:
    return not any(getattr(n, "op", None) == "apply_expression_template" for n in walk(rhs))


# --- interp


def _interp_call(name: str, inputs: list, tag: str) -> tuple[dict, dict]:
    """The bindings of one ``name`` application and its query values: arrays
    are ``const`` nodes, lengths integers, queries parameters (a NaN query is
    not a JSON literal)."""

    def const(v: Any) -> dict:
        return {"op": "const", "args": [], "value": v}

    qx, qy = f"qx_{tag}", f"qy_{tag}"
    if name == "searchsorted":
        x, xs = inputs
        return {"x": qx, "xs": const(xs), "n": len(xs)}, {qx: x}
    if name == "linear":
        table, axis, x = inputs
        return {"table": const(table), "axis": const(axis), "x": qx, "n": len(axis)}, {qx: x}
    table, axis_x, axis_y, x, y = inputs
    bindings = {
        "table": const(table),
        "axis_x": const(axis_x),
        "axis_y": const(axis_y),
        "x": qx,
        "y": qy,
        "nx": len(axis_x),
        "ny": len(axis_y),
    }
    return bindings, {qx: x, qy: y}


def _interp_doc(name: str, calls: list[tuple[dict, dict]]) -> dict:
    variables: dict[str, Any] = {}
    equations = []
    for i, (bindings, queries) in enumerate(calls):
        variables[f"out_{i}"] = {"type": "unknown", "units": "1"}
        for q in queries:
            variables[q] = {"type": "parameter", "default": 0.0, "units": "1"}
        equations.append(
            {
                "lhs": f"out_{i}",
                "rhs": {
                    "op": "apply_expression_template",
                    "args": [],
                    "name": name,
                    "bindings": bindings,
                },
            }
        )
    return {
        "esm": "2.0.0",
        "metadata": {"name": f"interp_{name}_scenarios"},
        "models": {
            "Probe": {
                "expression_template_imports": [{"ref": "esm:std/interp.esm", "only": [name]}],
                "variables": variables,
                "equations": equations,
            }
        },
    }


@pytest.mark.parametrize("fixture_dir", _INTERP_DIRS, ids=[p.name for p in _INTERP_DIRS])
def test_interp_scenarios(fixture_dir: Path):
    spec = json.loads((fixture_dir / "expected.json").read_text())
    name = spec["function"].removeprefix("interp.")
    scenarios = spec["scenarios"]
    calls = [_interp_call(name, sc["inputs"], str(i)) for i, sc in enumerate(scenarios)]
    equations = load_string(json.dumps(_interp_doc(name, calls))).models["Probe"].equations
    assert len(equations) == len(scenarios)
    failures: list[str] = []
    for sc, (_, queries), eq in zip(scenarios, calls, equations):
        if not _template_free(eq.rhs):
            failures.append(f"{sc['name']}: the template reference survived load")
            continue
        actual = float(evaluate(eq.rhs, {k: _decode(v) for k, v in queries.items()}))
        expected = _decode(sc["expected"])
        if not _agrees(actual, expected, spec["tolerance"]):
            failures.append(f"{sc['name']}: got={actual!r}, expected={expected!r}")
    assert not failures, "interp template mismatches:\n  " + "\n  ".join(failures)


# --- datetime


def _civil_from_days(z: int) -> tuple[int, int, int]:
    """Howard Hinnant's ``civil_from_days`` on Python integers."""
    z += 719468
    era = z // 146097
    doe = z - era * 146097
    yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    mp = (5 * doy + 2) // 153
    d = doy - (153 * mp + 2) // 5 + 1
    m = mp + 3 if mp < 10 else mp - 9
    return yoe + era * 400 + (1 if m <= 2 else 0), m, d


def _is_leap(y: int) -> bool:
    return y % 4 == 0 and (y % 100 != 0 or y % 400 == 0)


def _exact_field(field: str, t: float) -> float:
    """The §9.8.2 value of ``field`` at an in-domain instant ``t``, from
    integer arithmetic (and, for julian_day, the clause's binary64 formula)."""
    ft = math.floor(t)
    days, sod = divmod(ft, 86400)
    y, m, d = _civil_from_days(days)
    if field == "julian_day":
        return (float(days) + 2440588.0) + ((float(sod) - 43200.0) + (t - float(ft))) / 86400.0
    cumulative = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]
    values = {
        "year": y,
        "month": m,
        "day": d,
        "hour": sod // 3600,
        "minute": (sod // 60) % 60,
        "second": sod % 60,
        "day_of_year": cumulative[m - 1] + d + (1 if m > 2 and _is_leap(y) else 0),
        "is_leap_year": 1 if _is_leap(y) else 0,
    }
    return float(values[field])


def test_exact_field_reference_on_known_instants():
    # The reference computation itself, on instants whose fields are known.
    assert [_exact_field(f, 951825600.0) for f in _CALENDAR_FIELDS] == [
        2000.0,
        2.0,
        29.0,
        12.0,
        0.0,
        0.0,
        60.0,
        2451604.0,
        1.0,
    ]
    assert [_exact_field(f, -1.0) for f in _CALENDAR_FIELDS[:7]] == [
        1969.0,
        12.0,
        31.0,
        23.0,
        59.0,
        59.0,
        365.0,
    ]


def _calendar_rhs(field: str) -> Any:
    doc = {
        "esm": "2.0.0",
        "metadata": {"name": f"datetime_{field}_scenarios"},
        "models": {
            "Probe": {
                "expression_template_imports": [{"ref": "esm:std/calendar.esm", "only": [field]}],
                "variables": {
                    "tu": {"type": "parameter", "default": 0.0, "units": "s"},
                    "y": {"type": "unknown", "units": "1"},
                },
                "equations": [
                    {
                        "lhs": "y",
                        "rhs": {
                            "op": "apply_expression_template",
                            "args": [],
                            "name": field,
                            "bindings": {"t": "tu"},
                        },
                    }
                ],
            }
        },
    }
    rhs = load_string(json.dumps(doc)).models["Probe"].equations[0].rhs
    assert _template_free(rhs)
    return rhs


def _calendar_value(rhs: Any, t: float) -> float:
    # An infinite t makes the unselected branch subtract infinities.
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", RuntimeWarning)
        return float(evaluate(rhs, {"tu": t}))


def _in_domain(t: float) -> bool:
    return math.isfinite(t) and abs(t) < _CALENDAR_DOMAIN


_DOMAIN_EDGES = [
    _CALENDAR_DOMAIN - 1.0,
    -(_CALENDAR_DOMAIN - 1.0),
    _CALENDAR_DOMAIN - 0.5,
    -(_CALENDAR_DOMAIN - 0.5),
    _CALENDAR_DOMAIN,
    -_CALENDAR_DOMAIN,
]


@pytest.mark.parametrize("fixture_dir", _DATETIME_DIRS, ids=[p.name for p in _DATETIME_DIRS])
def test_datetime_scenarios(fixture_dir: Path):
    spec = json.loads((fixture_dir / "expected.json").read_text())
    field = spec["function"].removeprefix("datetime.")
    tol = spec["tolerance"]
    rhs = _calendar_rhs(field)
    cases: list[tuple[str, float, float, dict]] = []
    for sc in spec["scenarios"]:
        t = _decode(sc["inputs"][0])
        cases.append((sc["name"], t, _decode(sc["expected"]) if _in_domain(t) else math.nan, tol))
    for sc in spec["error_scenarios"]:
        t = _decode(sc["inputs"][0])
        assert not _in_domain(t), f"{sc['name']}: an error scenario inside the domain"
        cases.append((sc["name"], t, math.nan, tol))
    exact = {"abs": 0, "rel": 0}
    for t in _DOMAIN_EDGES:
        expected = _exact_field(field, t) if _in_domain(t) else math.nan
        cases.append((f"domain_edge_{t!r}", t, expected, exact))
    failures = [
        f"{name} (t={t!r}): got={actual!r}, expected={expected!r}"
        for name, t, expected, tol_ in cases
        if not _agrees(actual := _calendar_value(rhs, t), expected, tol_)
    ]
    assert not failures, f"{field} template mismatches:\n  " + "\n  ".join(failures)
