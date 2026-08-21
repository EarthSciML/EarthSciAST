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
from .template_imports import resolve_template_machinery
from .simulation_array import (
    BuildInspection,
    _build_numpy_rhs,
    _fill_build_inspection,
    _NumpyRhsBuild,
)
from .simulation_common import check_parameter_override_keys
from .sympy_bridge import SimulationError

__all__ = ["PreparedModel", "prepare", "observed_field"]


def _discover_loader_extents(
    providers: dict[str, Any] | None,
    pd_gates: dict[str, dict],
    metaparameters: dict[str, int] | None,
    t0: float,
) -> tuple[dict[str, int], dict[str, Any]]:
    """The extent-discovery pre-pass (esm-spec §8.9.4, CONFORMANCE_SPEC §5.5).

    A loader whose record count is only knowable once the table is read declares
    ``extent: {"metaparameter": "N_REC"}``. This runs BEFORE metaparameters are
    closed at the loader API, so an index set declared ``size: "N_REC"`` is sized
    by the DATA rather than by a caller who counted rows first.

    Returns ``(metaparameters, discovered)`` — the closed metaparameter map, and
    the arrays already materialised here, keyed by provider, so the injection
    pass below REUSES them and never samples a loader twice.

    Three conditions are errors rather than a silent preference for one answer:
    a provider that both gates on a derived set and declares an extent (a gated
    slab's extent is the gating set's); two variables of one loader that
    disagree on the count (named, because that IS the alignment check); and a
    caller binding that contradicts the discovered value.
    """
    from .simulation_loaders import _provider_sample_field

    closed: dict[str, int] = {str(k): int(v) for k, v in (metaparameters or {}).items()}
    discovered: dict[str, Any] = {}
    discovered_by: dict[str, tuple[int, str]] = {}
    for k in sorted(str(x) for x in (providers or {})):
        prov = providers[k]  # type: ignore[index]
        mp = getattr(prov, "extent_metaparameter", None)
        if not mp:
            continue
        mp = str(mp)
        if k in pd_gates or getattr(prov, "gate_spec", None) is not None:
            raise SimulationError(
                f"prepare: provider '{k}' both GATES on a derived index set and "
                f"declares the extent metaparameter '{mp}'; a gated slab's extent "
                f"is the gating set's, not a discovered one"
            )
        try:
            arr = np.asarray(_provider_sample_field(prov, t0), dtype=float)
        except SimulationError:
            raise
        except Exception as exc:  # noqa: BLE001 — re-raised with the site named
            raise SimulationError(f"extent discovery for '{k}': {exc}") from exc
        n = int(arr.shape[0]) if arr.ndim else 0
        prev = discovered_by.get(mp)
        if prev is not None and prev[0] != n:
            raise SimulationError(
                f"prepare: loader extent '{mp}' is {prev[0]} from provider "
                f"'{prev[1]}' but {n} from '{k}' — the loader's variables are not "
                f"aligned on one record axis"
            )
        if prev is None and mp in closed and closed[mp] != n:
            raise SimulationError(
                f"prepare: metaparameter '{mp}' was closed at {closed[mp]} by the "
                f"caller but provider '{k}' discovers {n} records; drop the binding "
                f"and let the loader declare its own extent"
            )
        discovered_by[mp] = (n, k)
        closed[mp] = n
        discovered[k] = arr
    return closed, discovered


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


def _has_template_import_edge(raw: Any) -> bool:
    """Does ``raw`` carry an esm-spec §9.7.2 import EDGE — at the top level of a
    library file, or inside a component?

    The pushdown prepass reads the RAW document, before the typed load, so an
    edge that is still unresolved hides the imported templates and index sets
    from the recogniser: the binning body reads as an unexpandable
    ``apply_expression_template`` and the rewrite silently declines, which costs
    the whole ungated fetch. Resolving is gated on this predicate rather than run
    unconditionally so a document with no edge reaches ``desugar_pushdown`` in
    exactly the bytes it does today (metaparameters unfolded, goldens unmoved).
    """
    if not isinstance(raw, dict):
        return False
    if "expression_template_imports" in raw:
        return True
    for compkind in ("models", "reaction_systems"):
        comps = raw.get(compkind)
        if isinstance(comps, dict) and any(
            isinstance(c, dict) and "expression_template_imports" in c for c in comps.values()
        ):
            return True
    return False


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

    ``providers`` maps ``"<ModelPath>.<param>"`` — the CONSUMING parameter's
    flattened name, the only spelling that names one loaded field and every one,
    since a source declares no variables of its own (esm-spec §8.5) — to a data
    provider: an EarthSciIO
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
    t0 = float(sample_time)
    raw = base_path = None

    # ---- extent discovery: a loader that measures its OWN record count ------
    # FIRST, ahead of the rewrite, because a discovered extent CLOSES a
    # metaparameter and every resolution below binds metaparameters at the
    # loader API (esm-spec §9.7.6 site 4). This is the Julia ordering
    # (`simulate.jl` prepare); Python used to discover AFTER the rewrite, which
    # was harmless only for as long as nothing between the two steps folded a
    # metaparameter — the §9.7 resolution added below does. Runs unconditionally:
    # even when the input is already typed (nothing left to size) the agreement
    # and caller-contradiction checks are still the loader's contract.
    metaparameters, discovered = _discover_loader_extents(providers, {}, metaparameters, t0)

    if pushdown_rewrite:
        raw, base_path = _raw_document(input_)
        if raw is None:
            raise SimulationError(
                "prepare: pushdown_rewrite=True needs a path or a native dict "
                "input — a typed EsmFile/FlattenedSystem is already past the "
                "rewrite point (the raw-dict record would not survive the "
                "typed parse; see pushdown_rewrite.py)"
            )
        # §9.7 imports resolve BEFORE the recogniser looks. `desugar_pushdown`
        # expands `apply_expression_template` references to find the containment
        # predicate, but it can only expand what is IN SCOPE — and an import edge
        # puts the library's templates and index sets in scope at LOAD, which has
        # not happened yet on this raw-dict path. Skipping this makes a document
        # that factors its binning body through an imported library fail
        # detection silently and fetch every provider-backed array whole.
        if _has_template_import_edge(raw):
            resolved = resolve_template_machinery(raw, base_path or os.getcwd(), metaparameters)
            if resolved is not None:
                raw = resolved
        rewritten = desugar_pushdown(raw, model_name=model_name)
        if rewritten is not raw:  # the pattern matched
            pd_gates = _pushdown_provider_gates(rewritten, providers)
            pd_coupling = _pushdown_coupling_pairs(rewritten)
        doc_for_record = rewritten

    # A discovered extent and a record-derived gate are mutually exclusive: a
    # gated slab's extent belongs to the gating set, which value-invention has
    # not materialised yet. (`_discover_loader_extents` catches the provider's
    # OWN declared gate; this catches the gate the rewrite record derives, which
    # only exists now.)
    for k in sorted(discovered):
        if k in pd_gates:
            raise SimulationError(
                f"prepare: provider '{k}' both GATES on a derived index set and "
                "declares an extent metaparameter; a gated slab's extent is the "
                "gating set's, not a discovered one"
            )

    if pushdown_rewrite:
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
    for rawk, prov in (providers or {}).items():
        k = str(rawk)
        if k in discovered:
            # Already materialized by the extent-discovery pre-pass; a loader
            # that declares its own extent is never sampled twice.
            merged[k] = discovered.pop(k)
        elif k in pd_gates:
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
        build_only=True,
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
        # The hoist records WHY it dropped each unresolvable observed; a skip
        # cascades, so report the FIRST recorded failure (the root cause) along
        # with the requested name's own reason — without this the visible error
        # names whatever the caller happened to read, far from the defect.
        reasons = getattr(build, "static_skip_reasons", {}) or {}
        own = reasons.get(v)
        if own is None and "." not in v:
            for k in sorted(reasons):
                if "." in k and k.rsplit(".", 1)[-1] == v:
                    own = reasons[k]
                    break
        detail = ""
        if reasons:
            root_name = next(iter(reasons))
            detail = (
                f"; build-time hoist dropped {len(reasons)} observed(s), "
                f"first '{root_name}': {reasons[root_name]}"
            )
            if own is not None and own != reasons[root_name]:
                detail += f"; '{name}': {own}"
        raise SimulationError(
            f"observed_field: '{name}' is not a build-time-evaluable observed of "
            f"the prepared document (state-dependent, unresolved, or not an "
            f"observed at all){detail}"
        )
    return got
