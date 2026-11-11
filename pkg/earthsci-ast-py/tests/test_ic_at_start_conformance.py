"""Cross-language conformance: an ``ic`` right-hand side is evaluated once, at
the start of the run (esm-spec §11.4.2; §6.6.5 "Build-time evaluation scope";
esm-libraries-spec §2.5.2 "An `ic` reads its data at the run's start, not at
`sample_time`").

Shared fixtures and the manifest live under ``tests/conformance/ic_at_start/``
(repo root); Julia and Rust run the same cases. Each case builds its fixture
with the case's ``tspan``, ``p``, ``providers`` and ``sample_time`` and checks
the state a solve starts from at ``tspan[0]``, element by element, or that
construction refuses the document with the case's ``error_code``.
"""

from __future__ import annotations

import datetime as _dt
import json
from collections.abc import Callable
from pathlib import Path

import numpy as np
import pytest

from earthsci_ast.errors import IcReadsStateError
from earthsci_ast.problem import ReturnCode, esm_problem, remake, solve

_ROOT = Path(__file__).resolve().parents[3] / "tests" / "conformance" / "ic_at_start"
_MANIFEST = _ROOT / "manifest.json"

#: Simulation-clock zero for the discrete test providers. A provider carrying a
#: ``time_origin`` names the instant of sim-clock 0 itself, so its refresh
#: anchors and refresh requests are plain offsets from this instant.
_EPOCH = _dt.datetime(2000, 1, 1)


def _manifest() -> dict:
    return json.loads(_MANIFEST.read_text())


class _ConstProvider:
    """The manifest's const provider: one field, ``base`` at every time."""

    def __init__(self, base: np.ndarray) -> None:
        self._base = base

    def sample(self, t: float) -> np.ndarray:
        return self._base.copy()


class _LinearDiscreteProvider:
    """The manifest's discrete provider: ``base + slope * t`` at sim time ``t``,
    refreshing at ``refresh_times`` (sim seconds after :data:`_EPOCH`)."""

    def __init__(self, base: np.ndarray, slope: float, refresh_times: list[float]) -> None:
        self._base = base
        self._slope = slope
        self._times = [float(t) for t in refresh_times]
        self.time_origin = _EPOCH

    def _at(self, t: float) -> np.ndarray:
        return np.asarray(self._base + self._slope * float(t), dtype=float)

    def sample(self, t: float) -> np.ndarray:
        return self._at(t)

    def refresh_times(self) -> list[_dt.datetime]:
        return [_EPOCH + _dt.timedelta(seconds=t) for t in self._times]

    def refresh(self, when: _dt.datetime) -> np.ndarray:
        return self._at((when - _EPOCH).total_seconds())


def _provider(entry: dict) -> object:
    base = np.asarray(entry["base"], dtype=float).reshape(tuple(entry["shape"]))
    if entry["refresh_times"]:
        return _LinearDiscreteProvider(base, float(entry["slope"]), entry["refresh_times"])
    assert float(entry["slope"]) == 0.0
    return _ConstProvider(base)


def _build(case: dict):
    providers = {e["key"]: _provider(e) for e in case["providers"]}
    kwargs: dict = {}
    if "sample_time" in case:
        kwargs["sample_time"] = float(case["sample_time"])
    return esm_problem(
        str(_ROOT / case["fixture"]),
        tuple(float(x) for x in case["tspan"]),
        p={k: float(v) for k, v in case.get("p", {}).items()},
        providers=providers or None,
        **kwargs,
    )


def test_manifest_requires_python() -> None:
    manifest = _manifest()
    assert manifest["category"] == "ic_at_start"
    assert "python" in manifest["bindings_required"]
    assert manifest["cases"]


_CASES = _manifest()["cases"]


@pytest.mark.parametrize("case", [c for c in _CASES if "expected" in c], ids=lambda c: c["id"])
def test_initial_state_is_evaluated_at_run_start(case: dict) -> None:
    tol = _manifest()["tolerances"]
    prob = _build(case)
    t0 = float(case["tspan"][0])
    sol = solve(prob, saveat=[t0])
    assert sol.retcode is ReturnCode.Success, sol.message
    assert float(sol.t[0]) == t0
    start = {name: float(sol.y[k][0]) for k, name in enumerate(sol.vars)}
    for name, want in case["expected"].items():
        assert name in start, f"{name} not among the solution's states {sorted(start)}"
        assert start[name] == pytest.approx(
            float(want), rel=float(tol["rtol"]), abs=float(tol["atol"])
        ), f"{case['id']}: {name} starts at {start[name]}, expected {want}"


@pytest.mark.parametrize("case", [c for c in _CASES if "error_code" in c], ids=lambda c: c["id"])
def test_ic_reading_a_state_is_refused_at_construction(case: dict) -> None:
    with pytest.raises(Exception) as excinfo:
        _build(case)
    err = excinfo.value
    code = case["error_code"]
    assert getattr(err, "code", None) == code, f"{case['id']}: raised {type(err).__name__}: {err}"
    assert str(err).startswith(f"{code}:"), str(err)


def test_refusal_names_the_target_the_state_and_the_chain() -> None:
    """esm-spec §11.4.2: the diagnostic names the ``ic`` target, the state read,
    and the observeds between them."""
    with pytest.raises(IcReadsStateError) as excinfo:
        esm_problem(str(_ROOT / "fixtures" / "ic_reads_state.esm"), (0.0, 1.0))
    err = excinfo.value
    assert (err.target, err.state, err.chain) == ("R.v", "R.u", ["R.g"])
    assert "ic(R.v) reads 'R.g', which reads 'R.u', a state" in str(err)

    with pytest.raises(IcReadsStateError) as excinfo:
        esm_problem(str(_ROOT / "fixtures" / "ic_reads_state_scalar.esm"), (0.0, 1.0))
    err = excinfo.value
    assert (err.target, err.state, err.chain) == ("Q.b", "Q.a", [])
    assert "ic(Q.b) reads 'Q.a', a state" in str(err)


def test_sympy_compiler_evaluates_a_scalar_ic_at_run_start() -> None:
    """The SymPy (scalar) pathway binds ``t`` to ``tspan[0]`` in an ``ic`` and in
    an observed it reads, as the default compiler does."""
    case = next(c for c in _CASES if c["id"] == "t_scalar_runtime")
    prob = esm_problem(str(_ROOT / case["fixture"]), tuple(case["tspan"]), compiler="sympy")
    t0 = float(case["tspan"][0])
    sol = solve(prob, saveat=[t0])
    start = {name: float(sol.y[k][0]) for k, name in enumerate(sol.vars)}
    for name, want in case["expected"].items():
        assert start[name] == want


def test_remake_with_a_new_start_re_evaluates_the_ic() -> None:
    """esm-spec §11.4.2: a Problem whose interval changes evaluates its ``ic``
    right-hand sides at the new start."""
    prob = esm_problem(str(_ROOT / "fixtures" / "ic_reads_t.esm"), (10.0, 11.0))
    moved = remake(prob, tspan=(0.0, 1.0))
    sol = solve(moved, saveat=[0.0])
    start = {name: float(sol.y[k][0]) for k, name in enumerate(sol.vars)}
    assert start == {"T.a": 1.0, "T.u[1]": 1.0, "T.u[2]": 2.0, "T.u[3]": 3.0}


def test_materialize_once_provider_is_read_at_run_start_for_the_ic() -> None:
    """esm-libraries-spec §2.5.2: a provider sampled once at construction (a
    plain callable) is sampled at ``sample_time`` for the Problem's forcing, but
    the ``ic`` reads it at ``tspan[0]``."""
    base = np.array([[100.0, 200.0, 300.0], [500.0, 600.0, 700.0]])
    providers = {
        "H.F": lambda t: base + 4.0 * t,
        "H.q": lambda t: np.asarray(3.0 + 0.5 * t),
    }
    prob = esm_problem(
        str(_ROOT / "fixtures" / "ic_data_fed.esm"),
        (5.0, 9.0),
        providers=providers,
        sample_time=0.0,
    )
    np.testing.assert_array_equal(prob.const_arrays["H.F"], base)
    sol = solve(prob, saveat=[5.0])
    start = {name: float(sol.y[k][0]) for k, name in enumerate(sol.vars)}
    case = next(c for c in _CASES if c["id"] == "data_fed_discrete_at_start")
    for name, want in case["expected"].items():
        assert start[name] == want


def _reads_t_doc(tmp_path: Path, rhs: object) -> str:
    """``ic_reads_t.esm`` with ``ic(u)``'s right-hand side replaced by ``rhs``,
    written under ``tmp_path``."""
    doc = json.loads((_ROOT / "fixtures" / "ic_reads_t.esm").read_text())
    for eq in doc["models"]["T"]["equations"]:
        if eq["lhs"] == {"op": "ic", "args": ["u"]}:
            eq["rhs"] = rhs
    path = tmp_path / "ic_bare_name.esm"
    path.write_text(json.dumps(doc))
    return str(path)


@pytest.mark.parametrize(("rhs", "want"), [("t", 10.0), ("h", 0.5)])
def test_array_ic_of_a_bare_scalar_name_is_broadcast(tmp_path: Path, rhs: str, want: float) -> None:
    """esm-spec §11.4.2: an array ``ic`` whose right-hand side is the bare
    independent variable, or a bare scalar parameter, is that scalar at the
    start of the run, over every cell."""
    prob = esm_problem(_reads_t_doc(tmp_path, rhs), (10.0, 11.0))
    sol = solve(prob, saveat=[10.0])
    start = {name: float(sol.y[k][0]) for k, name in enumerate(sol.vars)}
    assert [start[f"T.u[{i}]"] for i in (1, 2, 3)] == [want] * 3


class _CountingCallable:
    """A materialize-once provider (a plain callable) that records the times
    it is sampled at."""

    def __init__(self, value: Callable[[float], np.ndarray]) -> None:
        self._value = value
        self.times: list[float] = []

    def __call__(self, t: float) -> np.ndarray:
        self.times.append(float(t))
        return self._value(t)


def test_remake_to_a_new_start_reads_materialize_once_data_there() -> None:
    """esm-libraries-spec §2.5.5: a ``remake`` to a new start reads an ``ic``'s
    data at the new start, as ``esm_problem`` with that ``tspan`` does."""
    base = np.array([[100.0, 200.0, 300.0], [500.0, 600.0, 700.0]])

    def providers() -> dict:
        return {
            "H.F": lambda t: base + 4.0 * t,
            "H.q": lambda t: np.asarray(3.0 + 0.5 * t),
        }

    fixture = str(_ROOT / "fixtures" / "ic_data_fed.esm")
    prob = esm_problem(fixture, (0.0, 4.0), providers=providers(), sample_time=0.0)
    moved = remake(prob, tspan=(5.0, 9.0))
    direct = esm_problem(fixture, (5.0, 9.0), providers=providers(), sample_time=0.0)

    def start(pr) -> dict:
        sol = solve(pr, saveat=[pr.tspan[0]])
        return {name: float(sol.y[k][0]) for k, name in enumerate(sol.vars)}

    case = next(c for c in _CASES if c["id"] == "data_fed_discrete_at_start")
    got = start(moved)
    assert got == start(direct)
    for name, want in case["expected"].items():
        assert got[name] == want


def test_only_the_providers_an_ic_reads_are_sampled_at_the_start() -> None:
    """esm-libraries-spec §2.5.2: with ``sample_time`` off the start, only the
    materialize-once providers in an ``ic``'s read cone are sampled again at
    ``tspan[0]``."""
    base = np.array([[100.0, 200.0, 300.0], [500.0, 600.0, 700.0]])
    f = _CountingCallable(lambda t: base + 4.0 * t)
    q = _CountingCallable(lambda t: np.asarray(3.0 + 0.5 * t))
    doc = json.loads((_ROOT / "fixtures" / "ic_data_fed.esm").read_text())
    # `s` starts at a constant: nothing an `ic` reads reaches `q` any more.
    for eq in doc["models"]["H"]["equations"]:
        if eq["lhs"] == {"op": "ic", "args": ["s"]}:
            eq["rhs"] = 1.0
    esm_problem(doc, (5.0, 9.0), providers={"H.F": f, "H.q": q}, sample_time=0.0)
    assert 5.0 in f.times
    assert q.times == [0.0]
