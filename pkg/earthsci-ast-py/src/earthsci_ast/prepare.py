"""``prepare`` — the Python mirror of the Julia binding's build-time public
surface (``prepare`` / ``observed_field``, simulate.jl), Phase 3 of the clean
consolidation.

Runs everything deterministic-per-document ONCE — load → flatten → provider
materialization → NumPy build (the const-geometry hoist evaluates every
state-free observed through the document's own graph) — and returns a
:class:`PreparedModel` whose :func:`observed_field` reads those build-time
fields back. This is the entry point the isrm.esm runner drives; unlike
:func:`earthsci_ast.simulation.simulate` it never integrates.

``pushdown_rewrite=True`` opts into the automatic projection-pushdown desugar
(:func:`earthsci_ast.pushdown_rewrite.desugar_pushdown`) at this public entry
point, exactly as in Julia:

* the rewrite runs on the RAW authored document BEFORE parsing/flattening
  (see the raw-dict design note in :mod:`earthsci_ast.pushdown_rewrite`);
* the engine derives every provider gate from the rewrite's OWN record
  (``metadata.x_esd.pushdown.gated_select``) + the document coupling — the
  caller hand-authors NO gate dict;
* a ``providers`` entry the coupling routes onto a rewritten array is
  DEFERRED and fetched pre-sliced to the invented support set inside
  ``_build_numpy_rhs`` (pushdown hook 2), after value-invention has
  materialised the set's members.
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import numpy as np

from .esm_types import EsmFile
from .flatten import FlattenedSystem, flatten
from .parse import load
from .pushdown_rewrite import (
    _inject_pushdown_aliases,
    _pushdown_coupling_pairs,
    _pushdown_provider_gates,
    desugar_pushdown,
)
from .simulation_array import (
    BuildInspection,
    _build_numpy_rhs,
    _fill_build_inspection,
    _NumpyRhsBuild,
)
from .simulation_common import check_parameter_override_keys
from .sympy_bridge import SimulationError

__all__ = ["PreparedModel", "prepare", "observed_field"]


@dataclass
class PreparedModel:
    """The product of :func:`prepare`: the flattened system plus the finished
    NumPy build (whose const-geometry hoist already materialized every
    state-free observed). ``const_arrays`` is the merged build registry —
    caller arrays + eagerly-materialized const providers + the engine-derived
    pushdown products (``pd_member_factor__*`` feedback, gated compact slabs)."""

    flat: FlattenedSystem
    build: _NumpyRhsBuild
    const_arrays: dict[str, np.ndarray]
    doc: dict | None = None  # the (possibly rewritten) raw document
    model_name: str | None = None
    sample_time: float = 0.0
    gated_provider_keys: list[str] = field(default_factory=list)

    def observed_field(self, name: str):
        return observed_field(self, name)


def _raw_document(input_: Any) -> tuple[dict | None, str | None]:
    """``(raw_dict, base_path)`` for a carrier the pushdown prepass can
    rewrite; ``(None, None)`` when the carrier is already typed."""
    if isinstance(input_, dict):
        return input_, None
    if isinstance(input_, (str, Path)) and os.path.isfile(str(input_)):
        with open(input_) as fh:
            return json.load(fh), str(Path(input_).resolve().parent)
    return None, None


def prepare(
    input_: Any,
    *,
    parameters: dict[str, float] | None = None,
    const_arrays: dict[str, Any] | None = None,
    providers: dict[str, Any] | None = None,
    model_name: str | None = None,
    metaparameters: dict[str, int] | None = None,
    sample_time: float = 0.0,
    inspect: BuildInspection | None = None,
    pushdown_rewrite: bool = False,
) -> PreparedModel:
    """Build a document once and return a :class:`PreparedModel`.

    ``input_`` is a path to an ``.esm`` file, a native document ``dict``, an
    :class:`EsmFile`, or a :class:`FlattenedSystem` (the last two are rejected
    when ``pushdown_rewrite=True`` — the rewrite needs the raw authored
    document, before the typed parse).

    ``providers`` maps ``"<Loader>.<var>"`` to a data provider: an EarthSciIO
    ``Provider`` (``materialize()``/``refresh_times()``), a callable
    ``(t) -> array``, or an object exposing ``sample(t)``. CONST providers
    (no refresh times) are materialized once here; a provider gated by the
    pushdown record is DEFERRED and fetched pre-sliced after value-invention
    (a gated provider may additionally expose ``sample(t, selection=…)`` /
    ``supports_selection``). DISCRETE providers are not supported by
    ``prepare`` (use :func:`earthsci_ast.simulation.simulate`).

    ``parameters`` are build-time parameter overrides (validated like
    ``simulate``'s). ``metaparameters`` close the document's open
    metaparameters at load. ``inspect`` is the :class:`BuildInspection`
    observability sink (filled exactly as ``simulate`` fills it).
    """
    parameters = parameters or {}
    doc_for_record: dict | None = None
    pd_gates: dict[str, dict] = {}
    pd_coupling: list[tuple[str, str]] = []

    if pushdown_rewrite:
        raw, base_path = _raw_document(input_)
        if raw is None:
            raise SimulationError(
                "prepare: pushdown_rewrite=True needs a path or a native dict "
                "input — a typed EsmFile/FlattenedSystem is already past the "
                "rewrite point (the raw-dict record would not survive the "
                "typed parse; see pushdown_rewrite.py)"
            )
        rewritten = desugar_pushdown(raw, model_name=model_name)
        if rewritten is not raw:  # the pattern matched
            pd_gates = _pushdown_provider_gates(rewritten, providers)
            pd_coupling = _pushdown_coupling_pairs(rewritten)
        doc_for_record = rewritten
        file = load(rewritten, metaparameters=metaparameters, base_path=base_path)
    elif isinstance(input_, FlattenedSystem):
        file = None
    elif isinstance(input_, EsmFile):
        file = input_
    else:
        file = load(input_, metaparameters=metaparameters)

    flat = input_ if isinstance(input_, FlattenedSystem) else flatten(file)
    check_parameter_override_keys(flat.parameters, parameters)

    # ---- provider injection: eager CONST materialization; gated deferral ----
    from .simulation_loaders import _provider_is_discrete, _provider_sample_field

    merged: dict[str, Any] = {
        str(k): np.asarray(v, dtype=float) for k, v in (const_arrays or {}).items()
    }
    gated: dict[str, Any] = {}
    t0 = float(sample_time)
    for rawk, prov in (providers or {}).items():
        k = str(rawk)
        if k in pd_gates:
            # Record-derived gate (the rewrite's own metadata.x_esd.pushdown):
            # defer — value-invention must derive the gating set's members
            # before the rows to fetch are known.
            gated[k] = (prov, pd_gates[k])
        elif getattr(prov, "gate_spec", None) is not None:
            # Provider-declared gate (the fallback protocol, mirroring Julia's
            # provider_gate_spec) — also deferred.
            gated[k] = (prov, prov.gate_spec)
        elif _provider_is_discrete(prov):
            raise SimulationError(
                f"prepare: provider '{k}' is DISCRETE (non-empty refresh_times); "
                "prepare() is build-time-only — integrate discrete forcing "
                "through simulate()"
            )
        else:
            merged[k] = np.asarray(_provider_sample_field(prov, t0), dtype=float)

    # ---- pushdown-path name aliasing (same objects, no copies) ----
    if pushdown_rewrite:
        all_var_names = (
            list(flat.state_variables) + list(flat.parameters) + list(flat.observed_variables)
        )
        _inject_pushdown_aliases(merged, all_var_names, pd_coupling)

    build = _build_numpy_rhs(
        flat,
        parameters,
        {},
        loader_arrays=merged,
        gated_providers=gated,
        sample_time=t0,
    )

    if inspect is not None:
        _fill_build_inspection(inspect, flat, build, t0, loader_arrays=merged)

    return PreparedModel(
        flat=flat,
        build=build,
        const_arrays=merged,
        doc=doc_for_record,
        model_name=model_name,
        sample_time=t0,
        gated_provider_keys=sorted(gated),
    )


def observed_field(prep: PreparedModel, name: str):
    """Evaluate/read the state-free observed ``name`` at BUILD time through the
    prepared document's own graph — the const-geometry hoist already
    materialized it; this resolves the (flattened or local) name against those
    products. Raises :class:`SimulationError` when ``name`` is not a
    build-time-evaluable observed of the prepared document."""
    v = str(name)
    build = prep.build
    arrays = build.static_derived_rings
    scalars = build.static_observed_values

    def _lookup(key: str):
        if key in arrays:
            return np.asarray(arrays[key], dtype=float)
        if key in scalars:
            return float(scalars[key])
        return None

    got = _lookup(v)
    if got is None and "." not in v:
        # local spelling: resolve against the flattened observed-name tails.
        matches = sorted(
            k for k in set(arrays) | set(scalars) if k.rsplit(".", 1)[-1] == v and "." in k
        )
        for k in matches:
            got = _lookup(k)
            if got is not None:
                break
    if got is None:
        raise SimulationError(
            f"observed_field: '{name}' is not a build-time-evaluable observed of "
            f"the prepared document (state-dependent, unresolved, or not an "
            f"observed at all)"
        )
    return got
