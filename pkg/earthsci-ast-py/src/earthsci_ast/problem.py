"""The simulation Problem — one noun, and the verbs that run it.

This module is the Python binding's whole simulation surface
(esm-libraries-spec §2.5, ``API_SPEC.md`` §5.8):

.. code-block:: python

    prob = esm_problem(input, tspan, p=..., u0=..., providers=...)   # build once
    sol  = solve(prob, alg="LSODA", abstol=1e-14, reltol=1e-10)      # run per knob-set
    sol["Chem.O3"]                                                    # index by NAME

``esm_problem`` absorbs the whole deterministic-per-document pipeline — the
pushdown rewrite, load, flatten, loader-extent discovery, the gated fetch of
provider data, and the compile of the right-hand side — because that work is
per-DOCUMENT, while ``solve``'s arguments are per-RUN. There is no ``simulate``:
it conflated the two, which is exactly why this binding had grown a second,
``prepare``-shaped entry point beside it. ``prepare`` and ``PreparedModel`` are
this module's ``esm_problem`` / :class:`Problem` under a local name, and are
gone.

The vocabulary is SciML's in every binding (``API_SPEC.md`` §4), so this module
takes ``abstol`` / ``reltol`` / ``alg`` / ``saveat`` / ``tspan`` / ``u0`` / ``p``
— *not* SciPy's ``atol`` / ``rtol`` / ``method`` / ``t_eval``. A run reports its
outcome as a :class:`~earthsci_ast.simulation_common.ReturnCode`, never as a
boolean beside a sentence.

``pushdown_rewrite=True`` opts into the automatic projection-pushdown desugar
(:func:`earthsci_ast.pushdown_rewrite.desugar_pushdown`) at construction,
exactly as in Julia:

* the rewrite runs on the RAW authored document BEFORE parsing/flattening
  (see the raw-dict design note in :mod:`earthsci_ast.pushdown_rewrite`);
* the engine derives every provider gate from the rewrite's OWN record
  (``metadata.x_esd.pushdown.gated_select``) + the document coupling — the
  caller hand-authors NO gate dict;
* a ``providers`` entry the coupling routes onto a rewritten array is
  DEFERRED and fetched pre-sliced to the invented support set inside
  ``_build_numpy_rhs`` (pushdown hook 2), after value-invention has
  materialised the set's members.

Per esm-libraries-spec §2.5.9 the solver stays optional: importing this module
and CONSTRUCTING a Problem never needs SciPy. Only :func:`solve`, :func:`init`,
:func:`step` and :func:`solve_all` do.
"""

from __future__ import annotations

import json
import os
from collections.abc import Iterable
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable

import numpy as np

from .esm_types import EsmFile
from .flatten import (
    FlattenedSystem,
    UnsupportedDimensionalityError,
    _has_array_op,
    flatten,
)
from .parse import load_document, load_path
from .pushdown_rewrite import (
    _inject_pushdown_aliases,
    _pushdown_coupling_pairs,
    _pushdown_provider_gates,
    desugar_pushdown,
)
from .simulation_array import (
    BuildInspection,
    _build_numpy_rhs,
    _element_names,
    _fill_build_inspection,
    _NumpyRhsBuild,
    _simulate_with_numpy,
)
from .simulation_common import (
    SCIPY_AVAILABLE,
    ReturnCode,
    Solution,
    _failure_result,
    _limit_iters,
    _retcode_for_error,
    check_parameter_override_keys,
)
from .simulation_loaders import (
    LoaderProvider,
    _provider_is_discrete,
    _provider_sample_field,
    _simulate_with_discrete_providers,
    _simulate_with_loaders,
)
from .simulation_scalar import (
    _build_scalar_rhs,
    _ScalarRhsBuild,
    _simulate_scalar,
)
from .sympy_bridge import SimulationError
from .template_imports import resolve_template_machinery

__all__ = [
    "CallbackSet",
    "EnsembleProblem",
    "Integrator",
    "Problem",
    "ReturnCode",
    "Solution",
    "callbacks",
    "esm_problem",
    "init",
    "observed_field",
    "remake",
    "solve",
    "solve_all",
    "step",
]

#: The default solver algorithm. ``alg`` is the canonical SciML spelling
#: (API_SPEC §4); this binding's ecosystem has no first-class algorithm object,
#: so a SciPy method NAME is accepted, which §2.5.3 explicitly permits.
DEFAULT_ALG = "LSODA"
#: Canonical cross-binding tolerance defaults (API_SPEC §5.8): the same knobs
#: under the same names produce comparable trajectories in Julia, Python and Rust.
DEFAULT_RELTOL = 1e-10
DEFAULT_ABSTOL = 1e-14


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
                f"esm_problem: provider '{k}' both GATES on a derived index set and "
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
                f"esm_problem: loader extent '{mp}' is {prev[0]} from provider "
                f"'{prev[1]}' but {n} from '{k}' — the loader's variables are not "
                f"aligned on one record axis"
            )
        if prev is None and mp in closed and closed[mp] != n:
            raise SimulationError(
                f"esm_problem: metaparameter '{mp}' was closed at {closed[mp]} by the "
                f"caller but provider '{k}' discovers {n} records; drop the binding "
                f"and let the loader declare its own extent"
            )
        discovered_by[mp] = (n, k)
        closed[mp] = n
        discovered[k] = arr
    return closed, discovered


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




# --------------------------------------------------------------------------- #
# Callbacks (esm-libraries-spec §2.5.4)
# --------------------------------------------------------------------------- #


class CallbackSet(tuple):
    """An ordered, immutable set of callbacks, declared on a :class:`Problem`.

    A callback is a callable ``(t, y)`` — ``t`` the output-time vector and ``y``
    the matching state/observed block — invoked once the run has produced its
    output nodes, and after every :meth:`Integrator.step`. Callbacks belong to
    the *document* (refreshing a provider buffer, writing an output stream), not
    to a particular run's tolerances, which is why they are declared at
    construction.

    A ``callback`` argument to :func:`solve` REPLACES this set entirely — it
    does not append, merge, or wrap (§2.5.4). Silent composition is the more
    dangerous default: a caller overriding a Problem-level callback would
    otherwise get both, and two callbacks that each write output produce a wrong
    run rather than an error. To EXTEND rather than replace, read the set back
    and compose explicitly::

        solve(prob, callback=callbacks(prob) + my_extra_callback)
    """

    def __new__(cls, callbacks: Any = ()) -> CallbackSet:
        if callbacks is None:
            items: tuple = ()
        elif isinstance(callbacks, CallbackSet):
            items = tuple(callbacks)
        elif callable(callbacks):
            items = (callbacks,)
        elif isinstance(callbacks, Iterable):
            items = tuple(callbacks)
        else:
            raise TypeError(
                f"callback must be a callable, an iterable of callables, or a "
                f"CallbackSet; got {type(callbacks).__name__}"
            )
        for cb in items:
            if not callable(cb):
                raise TypeError(f"callback entry {cb!r} is not callable")
        return super().__new__(cls, items)

    def __add__(self, other: Any) -> CallbackSet:
        """Explicit composition — the sanctioned way to EXTEND a Problem's set."""
        return CallbackSet(tuple(self) + tuple(CallbackSet(other)))

    def __call__(self, t: Any, y: Any) -> None:
        for cb in self:
            cb(t, y)

    def __repr__(self) -> str:  # pragma: no cover - display only
        return f"CallbackSet({list(self)!r})"


# --------------------------------------------------------------------------- #
# The Problem
# --------------------------------------------------------------------------- #


@dataclass
class Problem:
    """A document, built and ready to run (esm-libraries-spec §2.5.2).

    Construct one with :func:`esm_problem`; do not instantiate it directly. It
    holds everything deterministic-per-document — the flattened system, the
    materialized provider arrays, and the compiled right-hand side — so that
    :func:`solve` only varies the per-run knobs, and a parameter sweep pays the
    build cost once.

    ``p`` and ``u0`` are the SciML spellings of the parameter and initial-state
    bindings; both fix the DOCUMENT, so both live here rather than on
    :func:`solve`. :attr:`callbacks` is the Problem's callback set — read it
    back with :func:`callbacks`.
    """

    flat: FlattenedSystem
    tspan: tuple[float, float]
    p: dict[str, float] = field(default_factory=dict)
    u0: dict[str, float] = field(default_factory=dict)
    #: Which pathway :func:`solve` runs: ``"scalar"``, ``"array"``, ``"loaders"``
    #: or ``"discrete_providers"``. Chosen at construction from the system's own
    #: content, never by the caller.
    pathway: str = "scalar"
    #: The compiled NumPy right-hand side (array / PDE pathway), or ``None``.
    build: _NumpyRhsBuild | None = None
    #: The compiled lambdified SymPy right-hand side (scalar pathway), or ``None``.
    scalar_build: _ScalarRhsBuild | None = None
    #: Merged build-time array registry: caller arrays + eagerly-materialized
    #: const providers + engine-derived pushdown products.
    const_arrays: dict[str, np.ndarray] = field(default_factory=dict)
    #: The provider objects as passed, kept for the pathways that sample them
    #: per cadence segment rather than once at build.
    providers: dict[str, Any] | None = None
    gated_provider_keys: list[str] = field(default_factory=list)
    doc: dict | None = None  # the (possibly rewritten) raw document
    model_name: str | None = None
    metaparameters: dict[str, int] = field(default_factory=dict)
    sample_time: float = 0.0
    cse: bool = True
    loader_provider: Any = None
    provider_factory: Any = None
    #: The construction-time observability sink, kept only so the pathways that
    #: build per cadence SEGMENT (they have no construction-time build to fill
    #: it from) can fill it on their seed build. Extension seam, not stable API.
    inspect: BuildInspection | None = None
    callbacks: CallbackSet = field(default_factory=CallbackSet)
    # Loader-INVARIANT build products, shared with every Problem `remake`
    # derives from this one so a substituted parameter never re-materializes
    # the conservative-regrid geometry or the value-invention join buffers.
    static_cache: dict[str, Any] = field(default_factory=dict)

    def __repr__(self) -> str:  # pragma: no cover - display only
        return (
            f"Problem(pathway={self.pathway!r}, tspan={self.tspan!r}, "
            f"states={len(self.flat.state_variables)}, params={len(self.flat.parameters)})"
        )

    def observed_field(self, name: str):
        """Convenience for ``observed_field(prob, name)``."""
        return observed_field(self, name)


def esm_problem(
    input: Any,
    tspan: tuple[float, float],
    *,
    p: dict[str, float] | None = None,
    u0: dict[str, float] | None = None,
    providers: dict[str, Any] | None = None,
    model_name: str | None = None,
    metaparameters: dict[str, int] | None = None,
    base_path: str | None = None,
    sample_time: float | None = None,
    const_arrays: dict[str, Any] | None = None,
    cse: bool = True,
    callback: Any = None,
    loader_provider: LoaderProvider | None = None,
    provider_factory: Callable | None = None,
    inspect: BuildInspection | None = None,
    pushdown_rewrite: bool = False,
) -> Problem:
    """Build a document into a runnable :class:`Problem` (esm-libraries-spec §2.5.2).

    This runs the whole deterministic-per-document pipeline ONCE — the pushdown
    rewrite, load, flatten, loader-extent discovery, the gated fetch of provider
    data, and the compile of the right-hand side — and returns the Problem
    :func:`solve` runs. Nothing is integrated here, and SciPy is not needed
    (§2.5.9).

    Parameters
    ----------
    input:
        The document: a path to an ``.esm`` file, a native ``dict``, an
        :class:`~earthsci_ast.esm_types.EsmFile`, or an already-flattened
        :class:`~earthsci_ast.flatten.FlattenedSystem`. The last two are
        rejected when ``pushdown_rewrite=True`` — the rewrite needs the raw
        authored document, before the typed parse.
    tspan:
        ``(t_start, t_end)``, the integration interval.
    p:
        Parameter bindings, keyed by either the dot-namespaced name
        (``"Chem.k1"``) or the bare name (``"k1"``). A key naming no single
        parameter is an error here, not a silently unperturbed run
        (esm-spec §6.6.2).
    u0:
        Initial state, keyed the same way. Falls back to each variable's ``ic``
        equation, then its declared default.
    providers:
        ``{"<ModelPath>.<param>": provider}`` — the loaded-data injection seam,
        keyed by the CONSUMING parameter's flattened name, the only spelling
        that names one loaded field and every one (a source declares no
        variables of its own, esm-spec §8.5). A provider is an EarthSciIO
        ``Provider`` (``materialize()`` / ``refresh_times()``), a callable
        ``(t) -> array``, or an object exposing ``sample(t)``. CONST providers
        are materialized once here; a gated provider is DEFERRED and fetched
        pre-sliced after value-invention; a DISCRETE provider is re-sampled per
        cadence segment during :func:`solve`.
    model_name:
        Which model to build when the document holds several.
    metaparameters:
        Closes the document's open metaparameters at load. A loader that
        declares its own ``extent`` closes one from the DATA instead, and a
        caller binding that contradicts the discovered value is an error.
    base_path:
        Directory imports resolve against. Defaults to the input file's own
        directory.
    sample_time:
        The build-time clock a provider is sampled at. Defaults to ``tspan[0]``
        — the start of the run is the moment the build describes.
    const_arrays:
        Extra caller-supplied arrays merged into the build registry.
    cse:
        Share common subexpressions when lambdifying the scalar pathway's rhs /
        algebraic / observed functions. ``True`` is the production setting;
        ``False`` bypasses SymPy's CSE pass for diagnostic comparisons. Compiles
        for each setting are cached separately on the flattened system.
    callback:
        The Problem's :class:`CallbackSet`. A ``callback`` passed to
        :func:`solve` REPLACES this set entirely (§2.5.4).
    loader_provider, provider_factory:
        The data-loader seams (RFC pure-io-data-loaders §4.3), consulted only
        when the flattened system has ``loader_fields``.
    inspect:
        Optional :class:`~earthsci_ast.simulation_array.BuildInspection`
        observability sink, filled with the build-time products. Build
        observability is an extension seam, not stable API (API_SPEC §5.8).
    pushdown_rewrite:
        Opt into the projection-pushdown desugar on the raw authored document.

    Raises
    ------
    UnsupportedDimensionalityError
        If the flattened system still has a spatial independent variable — a
        spatial operator that was never discretized into an ``arrayop`` stencil
        (esm-spec §4.7.6.12). Discretized PDEs fold the spatial axis into array
        dimensions, leaving ``independent_variables == ["t"]``, and build
        normally.
    UnknownParameterError, AmbiguousParameterError
        If a ``p`` key names no single parameter.
    SimulationError
        If the compile fails. A compile error is an error, not a return code:
        :class:`~earthsci_ast.simulation_common.ReturnCode` describes RUNS.
    """
    p = dict(p or {})
    u0 = dict(u0 or {})
    tspan = (float(tspan[0]), float(tspan[1]))
    t0 = float(sample_time) if sample_time is not None else float(tspan[0])

    doc_for_record: dict | None = None
    pd_gates: dict[str, dict] = {}
    pd_coupling: list[tuple[str, str]] = []
    raw = None

    # ---- extent discovery: a loader that measures its OWN record count ------
    # FIRST, ahead of the rewrite, because a discovered extent CLOSES a
    # metaparameter and every resolution below binds metaparameters at the
    # loader API (esm-spec §9.7.6 site 4). This is the Julia ordering
    # (`simulate.jl` prepare). Runs unconditionally: even when the input is
    # already typed (nothing left to size) the agreement and caller-contradiction
    # checks are still the loader's contract.
    closed_metaparameters, discovered = _discover_loader_extents(providers, {}, metaparameters, t0)

    if pushdown_rewrite:
        raw, derived_base = _raw_document(input)
        if raw is None:
            raise SimulationError(
                "esm_problem: pushdown_rewrite=True needs a path or a native dict "
                "input — a typed EsmFile/FlattenedSystem is already past the "
                "rewrite point (the raw-dict record would not survive the "
                "typed parse; see pushdown_rewrite.py)"
            )
        base_path = base_path or derived_base
        # §9.7 imports resolve BEFORE the recogniser looks. `desugar_pushdown`
        # expands `apply_expression_template` references to find the containment
        # predicate, but it can only expand what is IN SCOPE — and an import edge
        # puts the library's templates and index sets in scope at LOAD, which has
        # not happened yet on this raw-dict path. Skipping this makes a document
        # that factors its binning body through an imported library fail
        # detection silently and fetch every provider-backed array whole.
        if _has_template_import_edge(raw):
            resolved = resolve_template_machinery(
                raw, base_path or os.getcwd(), closed_metaparameters
            )
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
                f"esm_problem: provider '{k}' both GATES on a derived index set and "
                "declares an extent metaparameter; a gated slab's extent is the "
                "gating set's, not a discovered one"
            )

    # ---- resolve the input carrier to a flattened system -------------------
    if pushdown_rewrite:
        file = load_document(rewritten, metaparameters=closed_metaparameters, base_path=base_path)
    elif isinstance(input, FlattenedSystem):
        file = None
    elif isinstance(input, EsmFile):
        file = input
    elif isinstance(input, dict):
        file = load_document(input, metaparameters=closed_metaparameters, base_path=base_path)
    else:
        file = load_path(input, metaparameters=closed_metaparameters)

    flat = input if isinstance(input, FlattenedSystem) else flatten(file)

    # esm-spec §4.7.6.12: an ODE backend MUST reject a system with a surviving
    # spatial dimension. A spatial independent variable means an unlowered
    # spatial operator reached the build, so this surfaces the uniform
    # `unlowered_operator` code at the one front door.
    if len(flat.independent_variables) > 1:
        spatial = [v for v in flat.independent_variables if v != "t"]
        raise UnsupportedDimensionalityError(
            f"unlowered_operator: esm_problem builds systems whose only "
            f"independent variable is time (['t']), but the flattened system "
            f"still has spatial independent variables {spatial} — a spatial "
            f"operator that was not discretized. Apply the discretization "
            f"template (an `expression_templates` `match` rewrite) that lowers "
            f"it to an `arrayop` stencil, then build; discretized "
            f"PDEs run natively here."
        )

    # esm-spec §6.6.2 "Unrecognized override keys": a `p` key that names no
    # single parameter is an ERROR, raised at the one front door every pathway
    # routes through so the three executing bindings agree. Ignoring it silently
    # leaves every parameter at its default, so the author's binding does
    # nothing and the run still reports a verdict: a wrong answer, not a
    # missing one.
    check_parameter_override_keys(flat.parameters, p)

    # ---- provider injection: eager CONST materialization; gated deferral ----
    merged: dict[str, Any] = {
        str(k): np.asarray(v, dtype=float) for k, v in (const_arrays or {}).items()
    }
    gated: dict[str, Any] = {}
    discrete_providers: dict[str, Any] = {}
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
            # A time-varying provider cannot be materialized at build: its whole
            # point is that it changes during the run. It is re-sampled at each
            # cadence boundary by the segmented pathway.
            discrete_providers[k] = prov
        else:
            merged[k] = np.asarray(_provider_sample_field(prov, t0), dtype=float)

    # ---- pushdown-path name aliasing (same objects, no copies) ----
    if pushdown_rewrite:
        all_var_names = (
            list(flat.state_variables) + list(flat.parameters) + list(flat.observed_variables)
        )
        _inject_pushdown_aliases(merged, all_var_names, pd_coupling)

    # ---- the pathway, and the compile ---------------------------------------
    pathway = _choose_pathway(flat, discrete_providers, merged, gated)
    static_cache: dict[str, Any] = {}
    build: _NumpyRhsBuild | None = None
    scalar_build: _ScalarRhsBuild | None = None
    if pathway == "array":
        build = _build_numpy_rhs(
            flat,
            p,
            u0,
            loader_arrays=merged,
            gated_providers=gated,
            sample_time=t0,
            build_only=True,
        )
        if inspect is not None:
            _fill_build_inspection(inspect, flat, build, t0, loader_arrays=merged)
    elif pathway == "scalar" and not flat.state_variables:
        # A document with no ODE states is a pure BUILD: its whole content is
        # the observed graph, which is exactly what `observed_field` reads back.
        # Materialize it through the NumPy interpreter — the same build the
        # pre-Problem `prepare` did for exactly these documents.
        build = _build_numpy_rhs(
            flat,
            p,
            u0,
            loader_arrays=merged,
            gated_providers=gated,
            sample_time=t0,
            build_only=True,
        )
        if inspect is not None:
            _fill_build_inspection(inspect, flat, build, t0, loader_arrays=merged)
        # `solve` still samples the observed bodies over tspan through the SymPy
        # pathway, so compile that too — but TOLERANTLY. SymPy lowering is
        # narrower than the interpreter's (no `false`, no IEEE division by a
        # literal zero), and a body only the interpreter can evaluate must not
        # make the whole document unbuildable; `solve` reports it instead.
        try:
            scalar_build = _build_scalar_rhs(flat, p, u0, cse=cse)
        except Exception:  # noqa: BLE001 — deferred to solve(), which reports it
            scalar_build = None
    elif pathway == "scalar":
        scalar_build = _build_scalar_rhs(flat, p, u0, cse=cse)
    # The loader- and discrete-provider pathways rebuild the right-hand side at
    # every cadence boundary — a refreshed forcing changes the const-hoisted
    # geometry the build folds in — so their compile belongs to the segment, not
    # to construction. They keep the provider objects instead.

    return Problem(
        flat=flat,
        tspan=tspan,
        p=p,
        u0=u0,
        pathway=pathway,
        build=build,
        scalar_build=scalar_build,
        const_arrays=merged,
        providers=dict(providers) if providers else None,
        gated_provider_keys=sorted(gated),
        doc=doc_for_record,
        model_name=model_name,
        metaparameters=dict(closed_metaparameters),
        sample_time=t0,
        cse=cse,
        loader_provider=loader_provider,
        provider_factory=provider_factory,
        inspect=inspect,
        callbacks=CallbackSet(callback),
        static_cache=static_cache,
    )


def _choose_pathway(
    flat: FlattenedSystem,
    discrete_providers: dict[str, Any],
    merged: dict[str, Any],
    gated: dict[str, Any],
) -> str:
    """Which engine runs this system — decided by the system's own content.

    A DISCRETE provider means the forcing changes during the run, so the
    integration must be segmented on its refresh boundaries. Injected arrays —
    a ``providers`` entry materialized at build, a caller ``const_arrays``, a
    deferred gated fetch — are array-valued by construction, so they route to
    the NumPy interpreter and take precedence over the in-document data-loader
    seam (a document with both binds the injected arrays, as the pre-Problem
    entry points did). ``loader_fields`` alone means cadence segmentation.
    Otherwise an array op anywhere (including every discretized PDE) routes to
    the NumPy interpreter, and a scalar-only system to the lambdified SymPy
    pathway.
    """
    if discrete_providers:
        return "discrete_providers"
    if merged or gated:
        return "array"
    if flat.loader_fields:
        return "loaders"
    if any(_has_array_op(eq.lhs) or _has_array_op(eq.rhs) for eq in flat.equations):
        return "array"
    return "scalar"


# --------------------------------------------------------------------------- #
# solve (esm-libraries-spec §2.5.3)
# --------------------------------------------------------------------------- #


def solve(
    prob: Problem | EnsembleProblem,
    *,
    alg: str = DEFAULT_ALG,
    abstol: float = DEFAULT_ABSTOL,
    reltol: float = DEFAULT_RELTOL,
    saveat: Any = None,
    callback: Any = None,
    maxiters: int | None = None,
    trajectories: int | None = None,
) -> Solution | list[Solution]:
    """Run ``prob`` to completion and return its :class:`Solution`.

    The vocabulary is SciML's, not SciPy's (API_SPEC §4): ``alg`` (not
    ``method``), ``abstol`` (not ``atol``), ``reltol`` (not ``rtol``), ``saveat``
    (not ``t_eval``). The defaults — ``reltol=1e-10``, ``abstol=1e-14`` — are the
    canonical cross-binding ones, so Julia, Python and Rust solving the same
    document with default options produce comparable trajectories.

    Parameters
    ----------
    prob:
        The :class:`Problem` to run, or an :class:`EnsembleProblem` (in which
        case ``trajectories`` is required and a ``list`` of solutions comes
        back).
    alg:
        The solver algorithm. This binding's ecosystem has no first-class
        algorithm object, so a SciPy method name is accepted (§2.5.3).
    abstol, reltol:
        Absolute and relative solver tolerances.
    saveat:
        Output times: an explicit sequence, or a scalar output STEP measured
        from ``tspan[0]``. ``None`` keeps the dense uniform default grid.
    callback:
        REPLACES the Problem's callback set entirely — it does not append or
        merge (§2.5.4). To extend it, compose explicitly with
        ``callbacks(prob) + extra``.
    maxiters:
        Budget of right-hand-side evaluations. When spent, the run stops and
        reports :attr:`ReturnCode.MaxIters`. ``None`` (the default) is
        unbudgeted.

    Returns
    -------
    Solution
        Indexed by variable NAME, carrying a
        :class:`~earthsci_ast.simulation_common.ReturnCode`. A failure that the
        solver or the model reports comes back as a non-``Success`` code, not an
        exception, so interactive workflows can branch on it; a dimensionality
        violation still raises.
    """
    if isinstance(prob, EnsembleProblem):
        return prob.solve(
            trajectories=trajectories,
            alg=alg,
            abstol=abstol,
            reltol=reltol,
            saveat=saveat,
            callback=callback,
            maxiters=maxiters,
        )
    if not SCIPY_AVAILABLE:
        return _failure_result("SciPy is required to solve a Problem but is not available.")

    # §2.5.4: an explicit `callback` REPLACES the Problem's set. `None` means
    # "not given", which is what leaves the Problem's own set in force.
    cbs = prob.callbacks if callback is None else CallbackSet(callback)
    cb = cbs if cbs else None

    if prob.pathway == "discrete_providers":
        sol = _simulate_with_discrete_providers(
            prob.flat,
            prob.tspan,
            prob.p,
            prob.u0,
            alg,
            reltol,
            abstol,
            prob.providers or {},
            prob.inspect,
            maxiters=maxiters,
        )
        return _finish_segmented(sol, saveat, cb)
    if prob.pathway == "loaders":
        sol = _simulate_with_loaders(
            prob.flat,
            prob.tspan,
            prob.p,
            prob.u0,
            alg,
            rtol=reltol,
            atol=abstol,
            loader_provider=prob.loader_provider,
            provider_factory=prob.provider_factory,
            maxiters=maxiters,
        )
        return _finish_segmented(sol, saveat, cb)
    if prob.pathway == "array":
        return _simulate_with_numpy(
            prob.flat,
            prob.tspan,
            prob.p,
            prob.u0,
            alg,
            rtol=reltol,
            atol=abstol,
            loader_arrays=prob.const_arrays,
            prebuilt=prob.build,
            maxiters=maxiters,
            saveat=saveat,
            callback=cb,
        )
    return _simulate_scalar(
        prob.flat,
        prob.tspan,
        prob.p,
        prob.u0,
        alg,
        reltol,
        abstol,
        prob.cse,
        prebuilt=prob.scalar_build,
        maxiters=maxiters,
        saveat=saveat,
        callback=cb,
    )


def _finish_segmented(sol: Solution, saveat: Any, cb: Any) -> Solution:
    """Apply the run-level ``saveat`` and callback to a cadence-segmented run.

    The segmented pathways rebuild the right-hand side at every cadence
    boundary and stitch the per-segment dense grids together, so there is no
    single continuous interpolant to evaluate ``saveat`` against. The stitched
    grid IS dense (the same point budget, spread across the segments), so the
    requested times are read off it by linear interpolation — the same thing
    every consumer of these trajectories already does.
    """
    if saveat is not None and sol.t.size:
        want = np.atleast_1d(np.asarray(saveat, dtype=float))
        if want.size == 1 and float(want[0]) > 0.0:
            step = float(want[0])
            t0, t1 = float(sol.t[0]), float(sol.t[-1])
            want = t0 + step * np.arange(int(np.floor((t1 - t0) / step + 1e-9)) + 1, dtype=float)
        y = np.vstack([np.interp(want, sol.t, sol.y[i]) for i in range(sol.y.shape[0])])
        sol = Solution(
            t=want,
            y=y,
            vars=list(sol.vars),
            retcode=sol.retcode,
            message=sol.message,
            nfev=sol.nfev,
            njev=sol.njev,
            nlu=sol.nlu,
            events=sol.events,
        )
    if cb is not None:
        cb(sol.t, sol.y)
    return sol


def callbacks(prob: Problem) -> CallbackSet:
    """The Problem's callback set (esm-libraries-spec §2.5.4).

    Stable API in every simulation-capable binding for one reason: a ``callback``
    argument to :func:`solve` REPLACES this set, so without a way to read it back
    a Problem-level callback would be impossible to extend. Compose explicitly::

        solve(prob, callback=callbacks(prob) + my_extra_callback)
    """
    return prob.callbacks


# --------------------------------------------------------------------------- #
# remake (esm-libraries-spec §2.5.5)
# --------------------------------------------------------------------------- #


def remake(
    prob: Problem,
    *,
    p: dict[str, float] | None = None,
    u0: dict[str, float] | None = None,
    tspan: tuple[float, float] | None = None,
) -> Problem:
    """A NEW Problem with the named substitutions applied, everything else shared.

    It never mutates ``prob``, and it never redoes the parts of construction the
    substitution cannot have invalidated: the flattened system is shared (so the
    SymPy lambdify cache carries over), the materialized provider arrays are
    shared (a changed parameter never re-fetches a provider), and the
    loader-invariant build products — the value-invention join buffers and the
    conservative-regrid geometry — are shared through the parent's static cache.

    ``tspan``-only substitution rebinds nothing at all: the compiled right-hand
    side does not depend on the interval, so the new Problem reuses it verbatim.

    A substitution the Problem cannot honour without a rebuild RAISES, naming
    the parameter and the class that makes it un-substitutable, rather than
    silently rebuilding or silently ignoring it.
    """
    new_p = dict(prob.p) if p is None else {**prob.p, **p}
    new_u0 = dict(prob.u0) if u0 is None else {**prob.u0, **u0}
    new_tspan = prob.tspan if tspan is None else (float(tspan[0]), float(tspan[1]))

    if p:
        # The metaparameter check comes FIRST: a metaparameter is not a
        # parameter, so the generic override-key check would report it as merely
        # unknown, which is true but useless — it hides the reason.
        #
        # A metaparameter is closed at LOAD (esm-spec §9.7.6): it sizes index
        # sets, so substituting one changes the SHAPE of the system, not a value
        # in it. There is nothing to substitute into — build a new Problem.
        clash = sorted(set(p) & set(prob.metaparameters))
        if clash:
            raise SimulationError(
                f"remake: '{clash[0]}' is a METAPARAMETER of this document, not a "
                f"substitutable parameter — it is closed at load and sizes the "
                f"system's index sets, so changing it changes the shape of the "
                f"state vector. Build a new Problem with "
                f"esm_problem(..., metaparameters={{'{clash[0]}': ...}})."
            )
        check_parameter_override_keys(prob.flat.parameters, p)
        # A gated provider's fetch was SLICED to the support set value-invention
        # derived from the parameters at construction. Substituting a parameter
        # can move that set, and re-fetching is exactly what remake must not do.
        if prob.gated_provider_keys:
            raise SimulationError(
                f"remake: this Problem carries GATED providers "
                f"({', '.join(prob.gated_provider_keys)}), whose fetch was pre-sliced "
                f"to the support set derived from the build-time parameters; "
                f"substituting '{sorted(p)[0]}' could move that set, and remake must "
                f"not re-fetch provider data. Build a new Problem with esm_problem()."
            )

    rebind = p is not None or u0 is not None
    build = prob.build
    scalar_build = prob.scalar_build
    if rebind and prob.pathway == "array":
        build = _build_numpy_rhs(
            prob.flat,
            new_p,
            new_u0,
            loader_arrays=prob.const_arrays,
            static_cache=prob.static_cache,
            sample_time=prob.sample_time,
            build_only=True,
        )
    elif rebind and prob.pathway == "scalar":
        scalar_build = _build_scalar_rhs(prob.flat, new_p, new_u0, cse=prob.cse)

    return Problem(
        flat=prob.flat,
        tspan=new_tspan,
        p=new_p,
        u0=new_u0,
        pathway=prob.pathway,
        build=build,
        scalar_build=scalar_build,
        const_arrays=prob.const_arrays,
        providers=prob.providers,
        gated_provider_keys=list(prob.gated_provider_keys),
        doc=prob.doc,
        model_name=prob.model_name,
        metaparameters=dict(prob.metaparameters),
        sample_time=prob.sample_time,
        cse=prob.cse,
        loader_provider=prob.loader_provider,
        provider_factory=prob.provider_factory,
        inspect=prob.inspect,
        callbacks=prob.callbacks,
        static_cache=prob.static_cache,
    )


# --------------------------------------------------------------------------- #
# Stepping (esm-libraries-spec §2.5.6)
# --------------------------------------------------------------------------- #


#: SciPy's steppable solver classes, keyed by the ``alg`` name :func:`solve`
#: takes. Imported lazily by :func:`init` so constructing a Problem never needs
#: SciPy (§2.5.9).
_STEPPABLE_ALGS = ("RK45", "RK23", "DOP853", "Radau", "BDF", "LSODA")


class Integrator:
    """A stepping integrator over a :class:`Problem` (esm-libraries-spec §2.5.6).

    Build one with :func:`init`, advance it with :func:`step` (or
    :meth:`Integrator.step`), and run it out with :func:`solve_all`. This is the
    same lifecycle :func:`solve` performs internally, exposed for callers that
    need to interleave their own work with the integration — a coupling driver
    in a host model, an interactive session, a progress UI.

    Python has no ``!`` convention, so the spec's ``step!`` / ``solve!`` are
    spelled :func:`step` / :func:`solve_all`; both mutate the integrator, as
    their Julia twins do. An Integrator is also iterable, yielding ``(t, u)``
    after each accepted step::

        for t, u in init(prob):
            ...

    ``u`` is the current state vector; :meth:`__getitem__` indexes it BY NAME
    (§2.5.7), as a :class:`Solution` does.
    """

    def __init__(
        self,
        prob: Problem,
        *,
        alg: str = DEFAULT_ALG,
        abstol: float = DEFAULT_ABSTOL,
        reltol: float = DEFAULT_RELTOL,
        callback: Any = None,
        maxiters: int | None = None,
    ) -> None:
        if not SCIPY_AVAILABLE:
            raise SimulationError("SciPy is required to step a Problem but is not available.")
        if prob.pathway in ("loaders", "discrete_providers"):
            raise SimulationError(
                f"init: the {prob.pathway!r} pathway rebuilds its right-hand side at "
                f"every cadence boundary, so it has no single steppable integrator. "
                f"Run it with solve()."
            )
        import scipy.integrate as _si

        if alg not in _STEPPABLE_ALGS:
            raise SimulationError(
                f"init: alg={alg!r} is not a steppable SciPy solver "
                f"(have: {', '.join(_STEPPABLE_ALGS)})"
            )
        rhs, y0, names = _rhs_of(prob)
        self.prob = prob
        self.vars: list[str] = names
        self.callbacks: CallbackSet = prob.callbacks if callback is None else CallbackSet(callback)
        self.retcode: ReturnCode | None = None
        self.message: str = ""
        self._solver = getattr(_si, alg)(
            _limit_iters(rhs, maxiters),
            float(prob.tspan[0]),
            np.asarray(y0, dtype=float),
            float(prob.tspan[1]),
            rtol=reltol,
            atol=abstol,
        )
        self._ts: list[float] = [float(prob.tspan[0])]
        self._us: list[np.ndarray] = [np.array(y0, dtype=float)]

    # ---- state -----------------------------------------------------------
    @property
    def t(self) -> float:
        """The current time."""
        return float(self._solver.t)

    @property
    def u(self) -> np.ndarray:
        """The current state vector."""
        return np.asarray(self._solver.y)

    def __getitem__(self, key: str | int) -> Any:
        """``integrator[name]`` — the named variable's current value."""
        if isinstance(key, (int, np.integer)):
            return float(self.u[int(key)])
        name = str(key)
        if name in self.vars:
            return float(self.u[self.vars.index(name)])
        tails = [i for i, v in enumerate(self.vars) if v.rsplit(".", 1)[-1] == name]
        if len(tails) == 1:
            return float(self.u[tails[0]])
        rows = [i for i, v in enumerate(self.vars) if v.split("[", 1)[0] in (name,)]
        if rows:
            return np.asarray(self.u[rows])
        raise KeyError(f"{name!r} is not a state of this integrator")

    # ---- stepping --------------------------------------------------------
    def step(self) -> ReturnCode | None:
        """Advance one accepted solver step.

        Returns ``None`` while the integration is still running, and the final
        :class:`~earthsci_ast.simulation_common.ReturnCode` on the step that
        finishes it (or fails). Stepping a finished integrator is a no-op that
        re-reports the code.
        """
        if self.retcode is not None:
            return self.retcode
        try:
            message = self._solver.step()
        except Exception as exc:  # noqa: BLE001 — reported as a return code
            self.retcode = _retcode_for_error(exc)
            self.message = str(exc)
            return self.retcode
        self._ts.append(float(self._solver.t))
        self._us.append(np.array(self._solver.y, dtype=float))
        if self.callbacks:
            self.callbacks(np.asarray([self._solver.t]), np.asarray(self._solver.y)[:, None])
        if self._solver.status == "finished":
            self.retcode = ReturnCode.Success
            self.message = "The solver successfully reached the end of the integration interval."
        elif self._solver.status == "failed":
            self.retcode = ReturnCode.Failure
            self.message = str(message or "solver step failed")
        return self.retcode

    def solve(self) -> Solution:
        """Run to completion from wherever the integrator stands, and return the
        accumulated :class:`Solution`. This is the spec's ``solve!``."""
        while self.retcode is None:
            self.step()
        return self.solution()

    def solution(self) -> Solution:
        """The trajectory accumulated so far, as a :class:`Solution`."""
        t = np.asarray(self._ts, dtype=float)
        y = np.stack(self._us, axis=1) if self._us else np.empty((len(self.vars), 0))
        return Solution(
            t=t,
            y=y,
            vars=list(self.vars),
            retcode=self.retcode if self.retcode is not None else ReturnCode.Terminated,
            message=self.message,
            nfev=int(getattr(self._solver, "nfev", 0)),
            njev=int(getattr(self._solver, "njev", 0)),
            nlu=int(getattr(self._solver, "nlu", 0)),
        )

    def __iter__(self) -> Integrator:
        return self

    def __next__(self) -> tuple[float, np.ndarray]:
        if self.retcode is not None:
            raise StopIteration
        self.step()
        if self.retcode is not None and self.retcode is not ReturnCode.Success:
            raise StopIteration
        return self.t, self.u


def _rhs_of(prob: Problem) -> tuple[Callable, np.ndarray, list[str]]:
    """The compiled ``(rhs, u0, element names)`` a Problem steps."""
    if prob.pathway == "array" and prob.build is not None:
        build = prob.build
        return build.rhs_function, build.y0, _element_names(build.state_names, build.shapes)
    build_s = prob.scalar_build
    if build_s is None:
        # `bare assert` would vanish under -O; this is a real reachable state
        # (a state-free document whose SymPy lowering the interpreter-only body
        # defeated), so it gets a real error.
        raise SimulationError(
            f"init: this Problem has no compiled right-hand side to step "
            f"(pathway {prob.pathway!r}). Run it with solve()."
        )
    if build_s.rhs_function is None:
        raise SimulationError(
            "init: this system has no ODE states to step (it is observed-only); "
            "sample its observed bodies with solve()."
        )
    return build_s.rhs_function, build_s.y0, list(build_s.state_names)


def init(
    prob: Problem,
    *,
    alg: str = DEFAULT_ALG,
    abstol: float = DEFAULT_ABSTOL,
    reltol: float = DEFAULT_RELTOL,
    callback: Any = None,
    maxiters: int | None = None,
) -> Integrator:
    """Build a stepping :class:`Integrator` over ``prob`` (esm-libraries-spec §2.5.6)."""
    return Integrator(
        prob, alg=alg, abstol=abstol, reltol=reltol, callback=callback, maxiters=maxiters
    )


def step(integrator: Integrator) -> ReturnCode | None:
    """Advance ``integrator`` one accepted step — the spec's ``step!``.

    Python has no ``!`` convention for a mutating function, so the bang is
    dropped; the function mutates its argument exactly as the Julia twin does.
    """
    return integrator.step()


def solve_all(integrator: Integrator) -> Solution:
    """Run ``integrator`` to completion — the spec's ``solve!``.

    Named ``solve_all`` rather than ``solve`` because Python cannot overload on
    argument type and :func:`solve` already names the Problem-to-Solution verb.
    """
    return integrator.solve()


# --------------------------------------------------------------------------- #
# Ensembles (esm-libraries-spec §2.5.8)
# --------------------------------------------------------------------------- #


@dataclass
class EnsembleProblem:
    """A :class:`Problem` plus a per-trajectory rewrite (esm-libraries-spec §2.5.8).

    This is the canonical form for a parameter sweep, Monte Carlo over declared
    distributions, and perturbed initial conditions::

        ens = EnsembleProblem(prob, lambda p, i: remake(p, p={"k1": ks[i]}))
        sols = solve(ens, trajectories=len(ks))

    ``rewrite(prob, i)`` returns the Problem for trajectory ``i`` (0-based) —
    ordinarily via :func:`remake`, so the family shares one build. A rewrite
    that returns ``None`` runs the base Problem unchanged.
    """

    prob: Problem
    rewrite: Callable[[Problem, int], Problem | None] | None = None

    def problem_for(self, i: int) -> Problem:
        """The Problem for trajectory ``i``."""
        if self.rewrite is None:
            return self.prob
        made = self.rewrite(self.prob, i)
        return self.prob if made is None else made

    def solve(self, trajectories: int | None = None, **kwargs: Any) -> list[Solution]:
        """Solve the family, returning one :class:`Solution` per trajectory."""
        if trajectories is None:
            raise SimulationError(
                "solve: an EnsembleProblem needs trajectories=N — the rewrite is "
                "what varies per trajectory, so the family size is the caller's."
            )
        return [solve(self.problem_for(i), **kwargs) for i in range(int(trajectories))]


# --------------------------------------------------------------------------- #
# Named build-time reads (§5.8: observed_field is (prob, name) in all bindings)
# --------------------------------------------------------------------------- #


def observed_field(prob: Problem, name: str):
    """Evaluate/read the state-free observed ``name`` at BUILD time through the
    Problem's own graph — the const-geometry hoist already materialized it; this
    resolves the (flattened or local) name against those products. Raises
    :class:`SimulationError` when ``name`` is not a build-time-evaluable observed
    of the Problem.

    Two arguments in every binding (API_SPEC §5.8): build observability moved to
    a construction-time seam, so no caller has to thread a BuildInspection
    through to read a field back.
    """
    v = str(name)
    build = prob.build
    if build is None:
        raise SimulationError(
            f"observed_field: this Problem took the {prob.pathway!r} pathway, which "
            f"has no build-time observed graph to read '{name}' from. Only the "
            f"array/PDE pathway materializes state-free observeds at build."
        )
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
            f"the Problem (state-dependent, unresolved, or not an "
            f"observed at all){detail}"
        )
    return got
