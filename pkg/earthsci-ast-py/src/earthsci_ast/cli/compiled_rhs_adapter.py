"""Python adapter for the ``compiled_rhs`` cross-language conformance tier.

The tier (``tests/conformance/compiled_rhs/README.md``) checks that every
binding reproduces the same right-hand side ``f(u, p, t)`` at a written set of
probe states. Its two engines are the AST *interpreter* and, for the bindings
that have one, a *compiled* backend. Python has no compiled backend in this
plan (ruling of 2026-09-13): it participates with its interpreter only, and
answers ``--engine compiled`` with the whole-output ``unavailable`` form the
contract defines, so the runner prints a named reason instead of silently
skipping a binding.

The interpreter engine is :func:`earthsci_ast.evaluate_rhs` -- the same
single-shot, integrator-free RHS hook the PDE-simulation tier uses, with the
same bare column-major element spelling (``u[1]``, ``u[2,3]``, ``s``).

The runner discovers this adapter via ``$EARTHSCI_COMPILED_RHS_ADAPTER_PYTHON``
or on PATH as ``earthsci-compiled-rhs-adapter-python``. This package installs
no console script for it -- ``esm`` (Rust) is the only command-line tool the
project ships -- so the supported invocation is the module form::

    python3 -m earthsci_ast.cli.compiled_rhs_adapter \
        --manifest <manifest.json> --output <out.json> [--engine interpreter|compiled]

Unknown manifest fields are ignored by construction: only the fields listed in
:func:`run_fixture` and :func:`run_manifest` are read, so the manifest can grow
(tolerance classes, exclusions, ``compiled_required``) without touching this
file.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

from earthsci_ast import evaluate_rhs, load_path

#: The binding name this adapter reports under.
BINDING = "python"

#: Engines this adapter understands. ``compiled`` is accepted and answered with
#: the ``unavailable`` form rather than rejected, because the runner asks every
#: binding for both engines and wants a reason, not an argparse error.
ENGINES = ("interpreter", "compiled")

#: Why ``--engine compiled`` is unavailable here. The text is the ruling, so the
#: runner's report names the decision rather than a machine's configuration.
COMPILED_UNAVAILABLE_REASON = "Python has no compiled backend (ruling 2026-09-13)"


def _bare(name: str) -> str:
    """Strip the leading model namespace from a flattened element name.

    Identical to the PDE-simulation adapter's spelling rule (``Diff1D.u[1]`` ->
    ``u[1]``), which is what the manifest's ``state_order`` and the tier's
    goldens are written in."""
    return name.split(".", 1)[1] if "." in name else name


def tests_dir_for(manifest_path: Path) -> Path:
    """The repository ``tests/`` directory that fixture paths are relative to.

    The manifest lives at ``tests/conformance/compiled_rhs/manifest.json`` and
    its ``fixtures[].path`` entries are written relative to ``tests/`` (so one
    fixture can be referenced from another tier's directory). Found by walking
    up from the manifest rather than by a fixed number of ``parent`` hops, so a
    manifest kept elsewhere (a test's temporary copy, a nested tier) still
    resolves; falls back to the manifest's own directory when no ancestor is
    named ``tests``."""
    resolved = manifest_path.resolve()
    for ancestor in resolved.parents:
        if ancestor.name == "tests":
            return ancestor
    return resolved.parent


def _state_vector(fixture: dict[str, Any], probe: dict[str, Any]) -> dict[str, float]:
    """The probe state as a ``{element: value}`` map over ``state_order``.

    ``state_order`` is the authoritative flat layout, and the contract requires
    every probe to name every one of its elements -- so a missing element is a
    manifest error, not something to default to zero behind the runner's back.
    A manifest without ``state_order`` falls back to the probe's own map."""
    raw = dict(probe.get("state", {}))
    order = fixture.get("state_order")
    if not order:
        return {k: float(v) for k, v in raw.items()}
    missing = [name for name in order if name not in raw]
    if missing:
        raise KeyError(
            f"probe {probe.get('id')!r} of fixture {fixture.get('id')!r} omits "
            f"state element(s) {missing} declared in state_order"
        )
    return {name: float(raw[name]) for name in order}


def _project(
    derivatives: dict[str, float], fixture: dict[str, Any], probe_id: str
) -> dict[str, float]:
    """Reduce the evaluator's namespaced RHS map to the manifest's element set.

    Two things happen here. The model namespace is stripped, giving the bare
    column-major names the tier is written in. And the result is restricted to
    ``state_order``: the interpreter's flat layout can legitimately carry
    elements the tier does not compare (shape inference on an undeclared index
    range can extend an array past the cells the equations write), and emitting
    those would invent entries no other binding is asked for."""
    bare = {_bare(name): float(value) for name, value in derivatives.items()}
    order = fixture.get("state_order")
    if not order:
        return bare
    missing = [name for name in order if name not in bare]
    if missing:
        raise KeyError(
            f"probe {probe_id!r} of fixture {fixture.get('id')!r}: the evaluated RHS "
            f"has no element(s) {missing} named by state_order "
            f"(evaluated: {sorted(bare)})"
        )
    return {name: bare[name] for name in order}


def run_fixture(
    fixture: dict[str, Any], tests_dir: Path, compiler: str | None = None
) -> dict[str, Any]:
    """Evaluate one manifest fixture's RHS at every probe with the interpreter.

    Consumes ``path`` (relative to ``tests_dir``), ``state_order``,
    ``parameters`` (overrides; an empty map means the fixture's own defaults)
    and ``rhs_probes[].id`` / ``.t`` / ``.state``. ``model`` is validated
    against the document when present. Every other field -- ``tolerance_class``,
    ``compiled_required``, ``analytic_rhs``, tags -- belongs to the runner, not
    here."""
    esm = load_path(str(tests_dir / fixture["path"]))

    model = fixture.get("model")
    if model and esm.models and model not in esm.models:
        raise KeyError(
            f"fixture {fixture.get('id')!r} names model {model!r}, which "
            f"{fixture['path']} does not define (has {sorted(esm.models)})"
        )

    parameters = {str(k): v for k, v in (fixture.get("parameters") or {}).items()}

    rhs: dict[str, dict[str, float]] = {}
    for probe in fixture.get("rhs_probes", []):
        probe_id = str(probe["id"])
        evaluated = evaluate_rhs(
            esm,
            _state_vector(fixture, probe),
            t=float(probe.get("t", 0.0)),
            parameters=parameters,
            compiler=compiler,
        )
        rhs[probe_id] = _project(evaluated, fixture, probe_id)
    return {"rhs": rhs}


def run_manifest(
    manifest: dict[str, Any],
    manifest_path: Path,
    engine: str = "interpreter",
    compiler: str | None = None,
) -> dict[str, Any]:
    """The whole adapter payload for one manifest and one engine.

    ``compiled`` short-circuits to the contract's whole-output ``unavailable``
    form. ``interpreter`` runs every fixture; a fixture whose evaluation raises
    becomes an ``{"error": ...}`` entry -- the convention the other Python
    conformance adapters share (see :mod:`earthsci_ast.cli._adapter_main`) --
    so one bad fixture is reported by name instead of aborting the run."""
    if engine == "compiled":
        return {
            "binding": BINDING,
            "engine": engine,
            "status": "unavailable",
            "reason": COMPILED_UNAVAILABLE_REASON,
        }

    tests_dir = tests_dir_for(manifest_path)
    fixtures: dict[str, Any] = {}
    for fixture in manifest.get("fixtures", []):
        try:
            fixtures[fixture["id"]] = run_fixture(fixture, tests_dir, compiler)
        except Exception as exc:  # noqa: BLE001 - surface per-fixture failure to the runner
            fixtures[fixture["id"]] = {"error": f"{type(exc).__name__}: {exc}"}
    return {"binding": BINDING, "engine": engine, "fixtures": fixtures}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Python compiled-RHS conformance adapter")
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--engine", choices=ENGINES, default="interpreter")
    # `--engine` and `--compiler` are different questions and both stay.
    # `--engine` is this tier's own axis — whether a binding has a COMPILED
    # backend at all — and Python answers `compiled` with `unavailable`.
    # `--compiler` is API_SPEC §5.8's closed vocabulary: WHICH of this binding's
    # strategies evaluates the right-hand side. Omitted, it means the strict
    # `native` default.
    parser.add_argument("--compiler", default=None)
    args = parser.parse_args(argv if argv is not None else sys.argv[1:])

    manifest = json.loads(args.manifest.read_text())
    payload = run_manifest(manifest, args.manifest, args.engine, args.compiler)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
