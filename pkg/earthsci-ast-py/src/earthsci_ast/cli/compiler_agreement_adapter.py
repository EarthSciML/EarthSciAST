"""Python adapter for the ``compiler_agreement`` cross-compiler conformance tier.

The tier (``tests/conformance/compiler_agreement/README.md``; normative text
``CONFORMANCE_SPEC.md`` §5.44) checks that every compiler a binding offers
reproduces the Julia ``interpreter``'s trajectory of the same document within a
written band, or refuses it by name. Where ``compiled_rhs`` compares ONE
right-hand side at fixed probe states across bindings, this compares a whole
RUN, across the compilers of one binding as well as across bindings -- the axis
a strict ``native`` default can be wrong on in a way no cross-binding
comparison sees, because every binding's ``native`` could be wrong the same way.

``--compiler`` is required and is passed STRAIGHT to :func:`esm_problem`. This
adapter never inspects it to choose a build: an adapter that did would be
reimplementing the thing under test. Python answers for ``interpreter``,
``native`` and ``sympy``; ``xla`` and ``mtk`` are refused by
:func:`~earthsci_ast.compiler.resolve_compiler` and become the contract's
whole-output ``unavailable`` form, so the runner prints a named reason instead
of silently skipping the binding.

The three per-fixture outcomes the contract defines are produced here, and the
distinction between them is load-bearing:

* ``refused`` -- a :class:`~earthsci_ast.compiler.CompilerRefusedRuleError`,
  which names the rule this compiler cannot lower. It is a fact about COVERAGE,
  and the runner reads it as a named exclusion (or, for a fixture that
  ``required`` lists, as a failure).
* ``unavailable`` -- the whole output, when the compiler does not exist in this
  binding at all. A fact about this BUILD, never about a document.
* ``error`` -- anything else the load, the build or the run threw. It says
  nothing about what a compiler can run, so ``required`` does not excuse it and
  the runner reds it unconditionally.

The runner discovers this adapter via
``$EARTHSCI_COMPILER_AGREEMENT_ADAPTER_PYTHON`` or on PATH as
``earthsci-compiler-agreement-adapter-python``. This package installs no
console script -- ``esm`` (Rust) is the only command-line tool the project
ships -- so the supported invocation is the module form, and it is what
``scripts/test-conformance.sh`` sets::

    python3 -m earthsci_ast.cli.compiler_agreement_adapter \
        --manifest <manifest.json> --output <out.json> --compiler <value>
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

import numpy as np

from earthsci_ast import ReturnCode, esm_problem, load_path, solve
from earthsci_ast.compiler import (
    CompilerRefusedRuleError,
    CompilerUnavailableError,
    CompilerUnknownError,
    resolve_compiler,
)

#: The binding name this adapter reports under.
BINDING = "python"


def tests_dir_for(manifest_path: Path) -> Path:
    """The repository ``tests/`` directory a fixture's ``path`` is relative to.

    Found by walking up from the manifest's ABSOLUTE path to the nearest
    ancestor named ``tests``, which is the rule the contract states and the one
    ``compiled_rhs`` already uses: a fixed number of parent hops breaks the
    moment a manifest moves a level (a test's temporary copy, a nested tier).
    Falls back to the manifest's own directory when no ancestor is named
    ``tests``."""
    resolved = manifest_path.resolve()
    for ancestor in resolved.parents:
        if ancestor.name == "tests":
            return ancestor
    return resolved.parent


def _bare(name: str) -> str:
    """Strip the leading model namespace from a flattened element name.

    ``Diff1D.u[1]`` -> ``u[1]``, the bare column-major spelling the goldens and
    every other tier are written in. The runner strips a leading ``Model.``
    from both sides anyway, so either spelling is accepted; emitting the bare
    one keeps this adapter's output readable next to the golden it is compared
    against."""
    return name.split(".", 1)[1] if "." in name else name


def _time_key(t: float) -> str:
    """A save time as this adapter's own float repr.

    The contract leaves the spelling to the adapter and has the runner match by
    NUMERIC value, so a key within an ulp of a declared save time still lands.
    ``repr`` is the round-trippable spelling, which keeps the last bit."""
    return repr(float(t))


def fixture_document(fixture: dict[str, Any], tests_dir: Path) -> dict[str, Any]:
    """The fixture's raw document, as JSON.

    Read raw rather than through :func:`load_path` because the only thing taken
    from it here is the inline ``tests`` block, and the run a
    ``from: inline_tests`` fixture describes has to be the one the runner reads
    from the same place. Going through the typed parse for that would put a
    second interpretation of the block between the two."""
    with (tests_dir / fixture["path"]).open() as fh:
        return json.load(fh)


def inline_test(fixture: dict[str, Any], doc: dict[str, Any]) -> dict[str, Any]:
    """The inline ``tests`` entry a ``from: inline_tests`` fixture names.

    The document stays the single source of truth for its own run: the manifest
    restates none of the initial conditions, the parameter overrides or the time
    span, so this is where the save times (the assertion times) come from. Same
    lookup the runner does, deliberately."""
    tid = fixture["trajectory"]["test_id"]
    model_name = fixture["model"]
    model = (doc.get("models") or {}).get(model_name)
    if not isinstance(model, dict):
        raise KeyError(f"fixture {fixture['id']!r}: {fixture['path']} has no model {model_name!r}")
    for entry in model.get("tests") or []:
        if isinstance(entry, dict) and entry.get("id") == tid:
            return entry
    raise KeyError(
        f"fixture {fixture['id']!r}: {fixture['path']} model {model_name!r} has no "
        f"inline test {tid!r}"
    )


def fixture_run(
    fixture: dict[str, Any], doc: dict[str, Any]
) -> tuple[dict[str, float], dict[str, float], tuple[float, float], list[float]]:
    """``(u0, p, tspan, saveat)`` for one fixture, from whichever source defines it.

    Save times are NOT the adapter's to choose: the manifest's ``saveat`` for a
    ``from: manifest`` fixture, and the named inline test's ASSERTION TIMES for
    a ``from: inline_tests`` one. Both are read the same way the runner reads
    them, so a golden and the row compared against it describe the same run."""
    tr = fixture["trajectory"]
    if tr["from"] == "manifest":
        u0 = {str(k): float(v) for k, v in (tr.get("initial_conditions") or {}).items()}
        p = {str(k): float(v) for k, v in (tr.get("parameter_overrides") or {}).items()}
        tspan = (float(tr["tspan"][0]), float(tr["tspan"][1]))
        saveat = [float(t) for t in tr["saveat"]]
        return u0, p, tspan, saveat

    test = inline_test(fixture, doc)
    u0 = {str(k): float(v) for k, v in (test.get("initial_conditions") or {}).items()}
    p = {str(k): float(v) for k, v in (test.get("parameter_overrides") or {}).items()}
    span = test.get("time_span") or {}
    tspan = (float(span.get("start", 0.0)), float(span.get("end", 0.0)))
    times = {float(a["time"]) for a in (test.get("assertions") or []) if "time" in a}
    if not times:
        raise ValueError(
            f"fixture {fixture['id']!r}: inline test {tr['test_id']!r} has no timed "
            "assertions, so it defines no save times"
        )
    return u0, p, tspan, sorted(times)


def _row_at(sol: Any, t: float) -> int:
    """The index of the saved row at ``t``.

    ``saveat`` is passed to :func:`solve`, so the requested times ARE saved
    rows; this finds the one matching by value. A save time with no row is
    raised rather than interpolated: a linear interpolant across the solver's
    own grid would read back to the runner as a numerical mismatch, which is
    the one thing the tier must not confuse a missing row with."""
    ts = np.asarray(sol.t, dtype=float)
    if ts.size:
        hit = int(np.argmin(np.abs(ts - t)))
        if abs(float(ts[hit]) - t) <= 1e-12 * max(1.0, abs(t)):
            return hit
    raise KeyError(f"the solution has no saved row at t={t!r} (saved: {[float(x) for x in ts]})")


def _state_rows(sol: Any, saveat: list[float]) -> tuple[list[str], dict[str, dict[str, float]]]:
    """``(state_order, {save time: {element: value}})`` for a finished run.

    The element names are the bare column-major spellings. A document that
    mounts two components whose tails collide under that stripping is raised
    rather than answered with whichever row came last: a silently overwritten
    element is a wrong trajectory, and the runner compares by name."""
    order: list[str] = []
    for name in sol.vars:
        bare = _bare(str(name))
        if bare in order:
            raise ValueError(
                f"two state rows share the bare element name {bare!r} "
                f"(from {sol.vars}); the tier compares by name, so this document "
                "cannot be reported without inventing a disambiguation"
            )
        order.append(bare)

    rows: dict[str, dict[str, float]] = {}
    for t in saveat:
        col = _row_at(sol, t)
        rows[_time_key(t)] = {name: float(sol.y[r][col]) for r, name in enumerate(order)}
    return order, rows


def _observed_rows(
    prob: Any, sol: Any, names: list[str], saveat: list[float], order: list[str]
) -> dict[str, dict[str, float]]:
    """One series per observed field the fixture names, at the save times.

    Resolved against the solution's own rows first -- the output-node
    reconstruction carries scalar observeds there, and a value read off the
    trajectory is the value the run produced. Failing that, the observed is
    replayed at each saved state through the Problem's own graph
    (:func:`~earthsci_ast.simulation_array.observed_at_state`), which is the
    §6.6.5 answer for a state-dependent one. A name neither resolves is raised,
    not omitted: an absent series would read to the runner as a fixture that
    names no observeds."""
    from earthsci_ast.simulation_array import observed_at_state

    series: dict[str, dict[str, float]] = {}
    for name in names:
        want = str(name)
        bare = _bare(want)
        got: dict[str, float] = {}
        if bare in order:
            row = order.index(bare)
            for t in saveat:
                got[_time_key(t)] = float(sol.y[row][_row_at(sol, t)])
        else:
            build = prob.build
            if build is None:
                raise KeyError(
                    f"observed {want!r} is not a state row of this solution and this "
                    f"Problem took the {prob.engine!r} pathway, which carries no "
                    "observed graph to replay it through"
                )
            for t in saveat:
                col = _row_at(sol, t)
                value = observed_at_state(build, prob.flat, want, float(t), sol.y[:, col])
                if value is None:
                    raise KeyError(f"this Problem carries no observed named {want!r}")
                got[_time_key(t)] = float(np.asarray(value, dtype=float).reshape(()))
        series[want] = got
    return series


def run_fixture(fixture: dict[str, Any], tests_dir: Path, compiler: str) -> dict[str, Any]:
    """Build one fixture with ``compiler``, run it, and return its record.

    ``model`` is validated against the document but NOT passed to
    :func:`esm_problem`: the fixture names which model an inline ``tests`` block
    is read from, and a document that also mounts other components must produce
    the same state set here as in the reference, not a narrowed one."""
    doc = fixture_document(fixture, tests_dir)
    path = str(tests_dir / fixture["path"])
    esm = load_path(path)

    model = fixture.get("model")
    if model and esm.models and model not in esm.models:
        raise KeyError(
            f"fixture {fixture['id']!r} names model {model!r}, which {fixture['path']} "
            f"does not define (has {sorted(esm.models)})"
        )

    u0, p, tspan, saveat = fixture_run(fixture, doc)
    integration = fixture.get("integration") or {}

    prob = esm_problem(esm, tspan, u0=u0 or None, p=p or None, compiler=compiler)
    sol = solve(
        prob,
        saveat=saveat,
        reltol=float(integration["reltol"]),
        abstol=float(integration["abstol"]),
    )
    if sol.retcode is not ReturnCode.Success:
        raise RuntimeError(f"solve returned {sol.retcode.value}: {sol.message}")

    order, state = _state_rows(sol, saveat)
    observed = [str(n) for n in (fixture["trajectory"].get("observed") or [])]
    return {
        "state_order": order,
        "state": state,
        "observed": _observed_rows(prob, sol, observed, saveat, order) if observed else {},
    }


def run_manifest(manifest: dict[str, Any], manifest_path: Path, compiler: str) -> dict[str, Any]:
    """The whole adapter payload for one manifest and one compiler.

    A compiler this binding does not provide short-circuits to the contract's
    whole-output ``unavailable`` form, which carries no ``fixtures`` map -- the
    runner classifies it locally so the reason survives. Otherwise every fixture
    runs, and a refusal or an error is recorded per fixture and the next one is
    attempted: the point of the tier is the LIST of what each compiler could
    not run, which one abort would throw away."""
    try:
        resolve_compiler(compiler)
    except (CompilerUnavailableError, CompilerUnknownError) as exc:
        # `compiler_unknown` lands here too. The report has no fifth shape for
        # it, and the fact it states -- this binding will not answer for that
        # value, here is why -- is the one `unavailable` carries; the runner
        # never asks for a value outside the manifest's own vocabulary anyway.
        return {
            "binding": BINDING,
            "compiler": compiler,
            "status": "unavailable",
            "reason": str(exc),
        }

    tests_dir = tests_dir_for(manifest_path)
    fixtures: dict[str, Any] = {}
    for fixture in manifest.get("fixtures", []):
        fid = fixture["id"]
        try:
            fixtures[fid] = run_fixture(fixture, tests_dir, compiler)
        except CompilerRefusedRuleError as exc:
            fixtures[fid] = {"status": "refused", "rule": exc.rule, "reason": exc.reason}
        except Exception as exc:  # noqa: BLE001 - surface per-fixture failure to the runner
            fixtures[fid] = {"error": f"{type(exc).__name__}: {exc}"}
    return {"binding": BINDING, "compiler": compiler, "fixtures": fixtures}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Python compiler-agreement conformance adapter")
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    # Required, and not constrained to a `choices` list: the vocabulary lives in
    # `resolve_compiler`, and an argparse rejection would be a broken adapter
    # (no parsable report) where the contract wants a named `unavailable`.
    parser.add_argument("--compiler", required=True)
    args = parser.parse_args(argv if argv is not None else sys.argv[1:])

    manifest = json.loads(args.manifest.read_text())
    payload = run_manifest(manifest, args.manifest, args.compiler)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")

    # A non-zero exit WITH a valid report is allowed and means at least one
    # fixture errored; the runner gates the report regardless of the code. A
    # refusal is not an error and does not move it.
    errored = any("error" in rec for rec in payload.get("fixtures", {}).values())
    return 1 if errored else 0


if __name__ == "__main__":
    sys.exit(main())
