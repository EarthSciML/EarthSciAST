"""The simulation EsmProblem — one noun, and the verbs that run it.

This module is the Python binding's whole simulation surface
(esm-libraries-spec §2.5, ``API_SPEC.md`` §5.8):

.. code-block:: python

    prob = esm_problem(input, tspan, p=..., u0=..., providers=...)   # build once
    sol  = solve(prob, alg="LSODA", abstol=1e-6, reltol=1e-4)        # run per knob-set
    sol["Chem.O3"]                                                    # index by NAME

``esm_problem`` absorbs the whole deterministic-per-document pipeline — the
pushdown rewrite, load, flatten, loader-extent discovery, the gated fetch of
provider data, and the compile of the right-hand side — because that work is
per-DOCUMENT, while ``solve``'s arguments are per-RUN. There is no ``simulate``:
it conflated the two, which is exactly why this binding had grown a second,
``prepare``-shaped entry point beside it. ``prepare`` and ``PreparedModel`` are
this module's ``esm_problem`` / :class:`EsmProblem` under a local name, and are
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
and CONSTRUCTING a EsmProblem never needs SciPy. Only :func:`solve`, :func:`init`,
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

from . import op_registry
from .classification import is_implicit_lhs
from .compiler import (
    CompilerPolicy,
    CompilerRefusedRuleError,
    CompilerReport,
    phase_scope,
    resolve_compiler,
    use_policy,
)
from .esm_types import EsmFile, ExprNode
from .expr_walk import iter_children
from .expression import UnsupportedConstructError
from .flatten import (
    FlattenedSystem,
    UnsupportedDimensionalityError,
    _expr_to_string,
    _has_array_op,
    flatten,
    infer_variable_shapes,
)
from .lower_table_lookup import lower_flattened_table_lookups, lower_table_lookups
from .numpy_interpreter import (
    _EVALUABLE_CORE_OPS,
    UnevaluableOperatorError,
    UnreachableSpatialOperatorError,
)
from .parse import load_document, load_path
from .pushdown_rewrite import (
    _inject_pushdown_aliases,
    _pushdown_coupling_pairs,
    _pushdown_provider_gates,
    desugar_pushdown,
)
from .reference_resolution import E_REF_UNDECLARED_INDEX_SET
from .simulation_array import (
    BuildInspection,
    _build_numpy_rhs,
    _differentiated_lhs_target,
    _element_names,
    _fill_build_inspection,
    _NumpyRhsBuild,
    _resolve_index_set_shape,
    _simulate_with_numpy,
    classify_second_whole_definition,
    probe_output_time_observeds,
    rule_label,
)
from .simulation_common import (
    SCIPY_AVAILABLE,
    ReturnCode,
    Solution,
    _failure_result,
    _limit_iters,
    _retcode_for_error,
    _scipy_missing_message,
    check_parameter_override_keys,
    flat_namespace_scope,
    resolve_merged_renames,
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

# `DEFAULT_ABSTOL` / `DEFAULT_RELTOL` are a pure RE-EXPORT here (see the note
# under `DEFAULT_ALG`): nothing in this module names them any more, because no
# entry point may default to a concrete tolerance — that would occupy level 1 of
# the §2.2.2 chain and the document could never win. Hence the `noqa`.
from .solver import DEFAULT_ABSTOL, DEFAULT_RELTOL, resolve_tolerances  # noqa: F401
from .sympy_bridge import SimulationError, _unbalanced
from .template_imports import resolve_template_machinery

__all__ = [
    "CallbackSet",
    "EnsembleProblem",
    "Integrator",
    "EsmProblem",
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
# `DEFAULT_RELTOL` / `DEFAULT_ABSTOL` are imported at the top of this module from
# `solver.py`, which owns them because it also owns the §2.2.2 chain they sit at
# the bottom of. A second copy here would let the entry points and the bottom of
# that chain drift apart. They stay importable from this module under their
# historical names, but no entry point here uses them as a signature default:
# `solve` and `init` both take `None` and hand the chain a "caller said nothing",
# which is the only way the document can sit BETWEEN the call site and these.


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
    """An ordered, immutable set of callbacks, declared on a :class:`EsmProblem`.

    A callback is a callable ``(t, y)`` — ``t`` the output-time vector and ``y``
    the matching state/observed block — invoked once the run has produced its
    output nodes, and after every :meth:`Integrator.step`. Callbacks belong to
    the *document* (refreshing a provider buffer, writing an output stream), not
    to a particular run's tolerances, which is why they are declared at
    construction.

    A ``callback`` argument to :func:`solve` REPLACES this set entirely — it
    does not append, merge, or wrap (§2.5.4). Silent composition is the more
    dangerous default: a caller overriding a EsmProblem-level callback would
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
        """Explicit composition — the sanctioned way to EXTEND a EsmProblem's set."""
        return CallbackSet(tuple(self) + tuple(CallbackSet(other)))

    def __call__(self, t: Any, y: Any) -> None:
        for cb in self:
            cb(t, y)

    def __repr__(self) -> str:  # pragma: no cover - display only
        return f"CallbackSet({list(self)!r})"


# --------------------------------------------------------------------------- #
# The EsmProblem
# --------------------------------------------------------------------------- #


@dataclass
class EsmProblem:
    """A document, built and ready to run (esm-libraries-spec §2.5.2).

    Construct one with :func:`esm_problem`; do not instantiate it directly. It
    holds everything deterministic-per-document — the flattened system, the
    materialized provider arrays, and the compiled right-hand side — so that
    :func:`solve` only varies the per-run knobs, and a parameter sweep pays the
    build cost once.

    ``p`` and ``u0`` are the SciML spellings of the parameter and initial-state
    bindings; both fix the DOCUMENT, so both live here rather than on
    :func:`solve`. :attr:`callbacks` is the EsmProblem's callback set — read it
    back with :func:`callbacks`.
    """

    flat: FlattenedSystem
    tspan: tuple[float, float]
    p: dict[str, float] = field(default_factory=dict)
    u0: dict[str, float] = field(default_factory=dict)
    #: The compiler that BUILT this problem — one member of §5.8's closed
    #: vocabulary, and the caller's choice, not the document's. Stable surface.
    compiler: str = "native"
    #: Per rule, the tier it landed on and what declined on the way
    #: (:class:`earthsci_ast.compiler.CompilerReport`). Stable surface; the
    #: record's shape is per-binding.
    compiler_report: CompilerReport = field(default_factory=CompilerReport)
    #: Which SEGMENTING MECHANIC :func:`solve` runs: ``"array"`` (one build for
    #: the whole span), ``"loaders"`` or ``"discrete_providers"`` (rebuild per
    #: cadence segment), or ``"scalar"`` (the lambdified SymPy form, reached
    #: only under ``compiler="sympy"``). Internal, not stable surface, and NOT
    #: the compiler: under one compiler every document is built by the same
    #: machinery, and this says only whether a refreshing forcing makes that
    #: machinery run per segment.
    engine: str = "scalar"
    #: The compiled NumPy right-hand side (array / PDE pathway), or ``None``.
    build: _NumpyRhsBuild | None = None
    #: The compiled lambdified SymPy right-hand side (scalar pathway), or ``None``.
    scalar_build: _ScalarRhsBuild | None = None
    #: Why :attr:`scalar_build` is ``None`` on a state-free document, or ``None``.
    #: Such a document's build product is the interpreter build in :attr:`build`,
    #: so a SymPy tier that cannot lower one of its bodies does not fail the
    #: construction — but the reason travels with the problem, so the calls that
    #: do need that tier raise WITH it rather than rediscovering it.
    scalar_build_error: Exception | None = None
    #: Merged build-time array registry: caller arrays + eagerly-materialized
    #: const providers + engine-derived pushdown products.
    const_arrays: dict[str, np.ndarray] = field(default_factory=dict)
    #: The provider objects as passed, kept for the pathways that sample them
    #: per cadence segment rather than once at build.
    providers: dict[str, Any] | None = None
    gated_provider_keys: list[str] = field(default_factory=list)
    doc: dict | None = None  # the (possibly rewritten) raw document
    #: The document's §2.2 `solver` block, captured at construction. Kept as its
    #: OWN field rather than read back out of :attr:`doc`, because ``doc`` is
    #: only populated on the pushdown-rewrite path — reading the block from
    #: there made the §2.2.2 chain dead code for every ordinary problem. ``None``
    #: when the document declares no block, or when the problem was built from a
    #: bare :class:`FlattenedSystem` (which carries no document at all).
    solver: Any = None
    model_name: str | None = None
    metaparameters: dict[str, int] = field(default_factory=dict)
    sample_time: float = 0.0
    #: SymPy's common-subexpression pass, as it was asked for. Meaningful only
    #: when :attr:`compiler` is ``"sympy"``; carried on every problem so
    #: :func:`remake` rebuilds with the setting the original build used.
    cse: bool = True
    loader_provider: Any = None
    provider_factory: Any = None
    #: The construction-time observability sink, kept only so the pathways that
    #: build per cadence SEGMENT (they have no construction-time build to fill
    #: it from) can fill it on their seed build. Extension seam, not stable API.
    inspect: BuildInspection | None = None
    callbacks: CallbackSet = field(default_factory=CallbackSet)
    # Loader-INVARIANT build products, shared with every EsmProblem `remake`
    # derives from this one so a substituted parameter never re-materializes
    # the conservative-regrid geometry or the value-invention join buffers.
    static_cache: dict[str, Any] = field(default_factory=dict)
    #: Segment 0 of a cadence-segmented run, built at construction so the
    #: compiler has something to refuse here (esm-libraries-spec §2.5.10, "the
    #: per-segment seed") and handed to :func:`solve` so the providers are
    #: sampled once. ``None`` for every one-shot engine. Internal.
    segment_seed: Any = None

    def __repr__(self) -> str:  # pragma: no cover - display only
        return (
            f"EsmProblem(compiler={self.compiler!r}, engine={self.engine!r}, "
            f"tspan={self.tspan!r}, states={len(self.flat.state_variables)}, "
            f"params={len(self.flat.parameters)})"
        )

    def __str__(self) -> str:  # pragma: no cover - display only
        tiers = self.compiler_report.tiers()
        summary = (
            ", ".join(f"{k}×{v}" for k, v in sorted(tiers.items())) if tiers else "no aggregates"
        )
        return (
            f"EsmProblem built with compiler={self.compiler!r} "
            f"({len(self.flat.state_variables)} states, "
            f"{len(self.flat.parameters)} params) — tiers: {summary}"
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
    compiler: str | None = None,
) -> EsmProblem:
    """Build a document into a runnable :class:`EsmProblem` (esm-libraries-spec §2.5.2).

    This runs the whole deterministic-per-document pipeline ONCE — the pushdown
    rewrite, load, flatten, loader-extent discovery, the gated fetch of provider
    data, and the compile of the right-hand side — and returns the EsmProblem
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
        Share common subexpressions when lambdifying the rhs / algebraic /
        observed functions. Applies to ``compiler="sympy"`` and to NO other
        compiler — it names SymPy's own CSE pass, and the vectorized NumPy
        compilers have no lambdification to share subexpressions across.
        ``True`` is the production setting; ``False`` bypasses the pass for
        diagnostic comparisons. Compiles for each setting are cached separately
        on the flattened system.
    callback:
        The EsmProblem's :class:`CallbackSet`. A ``callback`` passed to
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
    compiler:
        WHICH strategy builds the right-hand side, over §5.8's closed
        vocabulary — ``"native"``, ``"interpreter"``, ``"xla"``, ``"mtk"``,
        ``"sympy"``. ``None`` means ``"native"``, and the default is STRICT.

        * ``"native"`` — whole-box vectorized NumPy for EVERY document, scalar
          ones included. A rule the vectorized tiers cannot express is a BUILD
          error naming the rule and the deepest decline reason
          (``compiler_refused_rule``), never a quiet demotion to the per-cell
          tree walk. Construction evaluates the const-geometry hoist, the
          right-hand side once at ``(u0, p, t0)``, and the output-time observed
          pass once, so the refusal is a construction error wherever the
          per-cell walk would have been reached (esm-libraries-spec §2.5.10).
        * ``"interpreter"`` — the reference: every fast tier off, the per-cell
          ``faq`` evaluator for every aggregate, source codegen and the
          shape-inference interval hull off. No performance promise of any
          kind; it exists to check the others, and it is bit-identical to
          ``"native"`` on every document both run.
        * ``"sympy"`` — the lambdified SymPy SCALAR right-hand side. Refuses an
          array document (an array op anywhere, or a resolvable declared
          ``shape``) and an algebraic constraint it cannot solve. ``cse``
          applies to this compiler and no other.
        * ``"xla"`` / ``"mtk"`` — in the vocabulary, not provided here:
          ``compiler_unavailable``, never answered by building something else.

        The cadence-segmented loader and discrete-provider mechanics are
        INTERNAL to both ``native`` and ``interpreter``: a document whose
        forcing refreshes still rebuilds per segment, with that compiler's
        tiers. What the compiler names is how a rule is evaluated, not how
        often.

    Raises
    ------
    UnsupportedDimensionalityError
        If the flattened system still has a spatial independent variable — a
        spatial operator that was never discretized into an ``faq`` stencil
        (esm-spec §4.7.6.12). Discretized PDEs fold the spatial axis into array
        dimensions, leaving ``independent_variables == ["t"]``, and build
        normally.
    UnknownParameterError, AmbiguousParameterError
        If a ``p`` key names no single parameter.
    SimulationError
        If the compile fails. A compile error is an error, not a return code:
        :class:`~earthsci_ast.simulation_common.ReturnCode` describes RUNS.
    CompilerUnknownError, CompilerUnavailableError, CompilerRefusedRuleError
        The three ways naming a ``compiler`` fails (esm-spec §9.6.6). All are
        :class:`~earthsci_ast.errors.SimulationError` subclasses carrying the
        registry code on ``.code``.
    """
    chosen_compiler = resolve_compiler(compiler)
    policy = CompilerPolicy(
        compiler=chosen_compiler,
        strict=chosen_compiler == "native",
        every_tier_off=chosen_compiler == "interpreter",
    )
    with use_policy(policy), phase_scope("construction"):
        return _esm_problem_under(
            policy,
            input,
            tspan,
            p=p,
            u0=u0,
            providers=providers,
            model_name=model_name,
            metaparameters=metaparameters,
            base_path=base_path,
            sample_time=sample_time,
            const_arrays=const_arrays,
            cse=cse,
            callback=callback,
            loader_provider=loader_provider,
            provider_factory=provider_factory,
            inspect=inspect,
            pushdown_rewrite=pushdown_rewrite,
        )


def _esm_problem_under(
    policy: CompilerPolicy,
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
) -> EsmProblem:
    """The body of :func:`esm_problem`, with the compiler already resolved and
    its policy already installed. Split out so that every ``return`` and every
    raise inside the pipeline is inside the policy's scope without indenting the
    whole function under a ``with``."""
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

    # esm-spec §9.5.3: `table_lookup` is SUGAR over the §9.2 closed functions,
    # and nothing downstream of the loader evaluates it — the interpreter
    # refuses the op outright. The lowering runs HERE, not in `parse`, because
    # §9.5.4 makes the AUTHORED form round-trip and this binding serializes the
    # typed document it loaded, so a load-time rewrite would emit the lowered
    # `fn` tree (issue #188). Pure and idempotent, and not even a walk for a
    # document declaring no `function_tables`.
    if file is not None:
        file = lower_table_lookups(file)

    # A caller-flattened system has no document, but `flatten` carries
    # `function_tables` so that this carrier can be lowered too.
    flat = (
        lower_flattened_table_lookups(input)
        if isinstance(input, FlattenedSystem)
        else flatten(file)
    )

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
            f"it to a `faq` stencil, then build; discretized "
            f"PDEs run natively here."
        )

    # esm-spec §9.6.3 constraint 6 — the REWRITE-TARGET OPERATOR GATE, run here
    # as the spec words it: "before a component is EVALUATED or COMPILED for
    # simulation, its expression trees are WALKED". A whole-tree walk, not a
    # reachability check.
    _assert_no_unlowered_operator(flat)

    # esm-spec §9.6.6 `unsupported_construct`: neither evaluator runs a discrete
    # event or solves an implicit equation, so refuse both here, for every route,
    # rather than build a model that silently runs without them.
    _refuse_unsupported_constructs(flat, file)

    # A declared shape over an undeclared index set, on a state nothing sizes.
    _assert_shaped_states_have_extent(flat)

    # One unknown carrying both a derivative equation and a bare-LHS one.
    _assert_no_doubly_defined_state(flat)

    # esm-spec §6.6.2 "Unrecognized override keys": a `p` key that names no
    # single parameter is an ERROR, raised at the one front door every pathway
    # routes through so the three executing bindings agree. Ignoring it silently
    # leaves every parameter at its default, so the author's binding does
    # nothing and the run still reports a verdict: a wrong answer, not a
    # missing one.
    # ...but resolve the merged-away spellings FIRST. An `operator_compose`
    # renaming match DELETES the name it consumed (esm-libraries-spec §4.7.1
    # step 4) and rewrites every equation off it -- a caller still holding
    # `"Sink.O3"` is addressing a state that moved, and the key check would
    # report it as merely unknown (issue #230). `u0` rides along: it is the same
    # kind of key against the same renames, on the state side.
    renames = dict(flat.metadata.merged_variable_renames)
    p = resolve_merged_renames(renames, p)
    u0 = resolve_merged_renames(renames, u0)

    check_parameter_override_keys(flat.parameters, p, flat_namespace_scope(flat))

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

    # ---- the engine, and the compile ----------------------------------------
    # WHICH machinery runs is the compiler's (the caller's); how OFTEN it runs
    # is the document's. `_segmenting_engine` answers only the second question.
    if policy.compiler == "sympy":
        _refuse_array_document_under_sympy(flat)
        _refuse_bound_data_under_sympy(flat, discrete_providers, merged, gated)
        engine = "scalar"
    else:
        engine = _segmenting_engine(flat, discrete_providers, merged, gated)
    static_cache: dict[str, Any] = {}
    segment_seed: Any = None
    build: _NumpyRhsBuild | None = None
    scalar_build: _ScalarRhsBuild | None = None
    scalar_build_error: Exception | None = None
    if engine == "array":
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
    elif engine == "scalar" and not flat.state_variables:
        # A document with no ODE states is a pure BUILD: its whole content is
        # the observed graph, which is exactly what `observed_field` reads back.
        # Materialize it through the NumPy interpreter — the same build the
        # pre-EsmProblem `prepare` did for exactly these documents.
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
        # `solve` samples the observed bodies over tspan through the SymPy
        # pathway, so compile that too — but this document has no ODE right-hand
        # side for the compile to PRODUCE (`_build_scalar_rhs` answers such a
        # system with `rhs_function=None`), and the build product it hands back
        # is the interpreter build above. SymPy lowering is narrower than the
        # interpreter's — no `false`, no IEEE division by a literal zero, no
        # boolean-valued body in an arithmetic position — and Julia and Rust
        # evaluate all three, so refusing the document here would make this
        # binding alone decline a model the other two run, and would take
        # `observed_field` (API_SPEC §5.8, stable API for exactly these
        # state-free documents) with it.
        #
        # What the failure must not do is VANISH. It is kept on the problem, and
        # the calls that really do need the SymPy tier — `solve`, `init` —
        # surface it with this cause attached instead of meeting it again blind.
        try:
            scalar_build = _build_scalar_rhs(flat, p, u0, cse=cse)
        except Exception as exc:  # noqa: BLE001 — recorded below, raised by solve()
            if getattr(exc, "code", None) is not None:
                # A DIAGNOSTIC this binding chose to emit — an unbalanced system,
                # an unsupported construct, an unlowerable operator. Those are
                # refusals about the DOCUMENT and are fatal wherever they are
                # raised; only an accident of SymPy lowering is tolerated here.
                raise
            scalar_build = None
            scalar_build_error = exc
    elif engine == "scalar":
        scalar_build = _build_scalar_rhs(flat, p, u0, cse=cse)
    # The loader- and discrete-provider engines rebuild the right-hand side at
    # every cadence boundary — a refreshed forcing changes the const-hoisted
    # geometry the build folds in — so their compile belongs to the segment, not
    # to construction. They keep the provider objects instead, and construction
    # builds the FIRST segment below so the compiler still has something to
    # refuse here rather than inside a run.

    # esm-libraries-spec §2.5.10: the compiler's refusal "covers every
    # evaluation the compiler performs for the Problem, not the right-hand side
    # alone", and "a binding whose ladder decides at evaluation time rather than
    # at build time MUST exercise every such evaluation at construction". The
    # Python ladder decides per aggregate, per call — so construction runs the
    # two evaluations the build itself does not: one right-hand side at
    # (u0, p, t0), and the output-time observed pass at t0. The const-geometry
    # hoist and the static observeds ran inside `_build_numpy_rhs` above, which
    # is where the census found six sevenths of this binding's per-cell landings.
    if build is not None:
        exercise_every_evaluation(flat, build, t0, loader_arrays=merged)
    elif engine in ("loaders", "discrete_providers"):
        # esm-libraries-spec §2.5.10 lists "the per-segment seed" among the
        # evaluations the compiler covers. A segmented engine compiles nothing at
        # construction, so the seed IS its construction-time build: run segment 0
        # here, keep its loader-invariant products, and let `solve` start from
        # them instead of paying for them again.
        segment_seed = _seed_segmented_engine(
            flat,
            engine,
            p,
            u0,
            tspan,
            providers=providers,
            loader_provider=loader_provider,
            provider_factory=provider_factory,
            discrete_providers=discrete_providers,
            static_cache=static_cache,
        )

    return EsmProblem(
        flat=flat,
        tspan=tspan,
        p=p,
        u0=u0,
        compiler=policy.compiler,
        compiler_report=policy.report,
        engine=engine,
        build=build,
        scalar_build=scalar_build,
        scalar_build_error=scalar_build_error,
        const_arrays=merged,
        providers=dict(providers) if providers else None,
        gated_provider_keys=sorted(gated),
        doc=doc_for_record,
        # esm-spec §2.2: the document's own solver hints, taken from the TYPED
        # file, which every input carrier except a bare FlattenedSystem produces.
        solver=getattr(file, "solver", None),
        model_name=model_name,
        metaparameters=dict(closed_metaparameters),
        sample_time=t0,
        cse=cse,
        loader_provider=loader_provider,
        provider_factory=provider_factory,
        inspect=inspect,
        callbacks=CallbackSet(callback),
        static_cache=static_cache,
        segment_seed=segment_seed,
    )


def _seed_segmented_engine(
    flat: FlattenedSystem,
    engine: str,
    p: dict[str, float],
    u0: dict[str, float],
    tspan: tuple[float, float],
    *,
    providers: dict[str, Any] | None,
    loader_provider: Any,
    provider_factory: Any,
    discrete_providers: dict[str, Any],
    static_cache: dict[str, Any],
) -> Any:
    """Build the first cadence segment at construction, for the compiler's sake.

    Failures other than a compiler refusal are swallowed, for the same reason
    the one-shot probe swallows them: a segmented document has always been
    allowed to build here and fail at `solve` when a provider cannot be reached,
    and turning that into a build error would be a different change made by
    accident. Only the refusal the active compiler owes the caller travels out.
    """
    try:
        if engine == "loaders":
            return _simulate_with_loaders(
                flat,
                tspan,
                p,
                u0,
                DEFAULT_ALG,
                loader_provider=loader_provider,
                provider_factory=provider_factory,
                static_cache=static_cache,
                seed_only=True,
            )
        return _simulate_with_discrete_providers(
            flat,
            tspan,
            p,
            u0,
            DEFAULT_ALG,
            DEFAULT_RELTOL,
            DEFAULT_ABSTOL,
            discrete_providers,
            static_cache=static_cache,
            seed_only=True,
        )
    except CompilerRefusedRuleError:
        raise
    except UnsupportedConstructError:
        raise
    except Exception:  # noqa: BLE001 — a non-refusal failure stays a run failure
        return None


def _segmenting_engine(
    flat: FlattenedSystem,
    discrete_providers: dict[str, Any],
    merged: dict[str, Any],
    gated: dict[str, Any],
) -> str:
    """How OFTEN the NumPy compilers rebuild — not WHICH machinery they use.

    ``compiler`` owns the choice of strategy, so nothing here asks whether the
    document is arrayed: esm-libraries-spec §2.5.10 forbids a binding switching
    strategy inside ``native`` on document content, so under ``native`` and
    ``interpreter`` alike a scalar document and a gridded one are built by the
    same vectorized NumPy machinery, and only the CADENCE differs.

    A DISCRETE provider means the forcing changes during the run, so the
    integration is segmented on its refresh boundaries. Injected arrays — a
    ``providers`` entry materialized at build, a caller ``const_arrays``, a
    deferred gated fetch — are already bound, so one build covers the whole
    span and takes precedence over the in-document data-loader seam (a document
    with both binds the injected arrays, as the pre-Problem entry points did).
    ``loader_fields`` alone means cadence segmentation. Everything else is one
    build for the whole span.
    """
    if discrete_providers:
        return "discrete_providers"
    if merged or gated:
        return "array"
    if flat.loader_fields:
        return "loaders"
    return "array"


def _refuse_bound_data_under_sympy(
    flat: FlattenedSystem,
    discrete_providers: dict[str, Any],
    merged: dict[str, Any],
    gated: dict[str, Any],
) -> None:
    """``compiler="sympy"`` binds no data; a problem that carries some is refused.

    The lambdified scalar right-hand side reads parameters and nothing else: it
    has no seam for a ``providers`` entry, a caller ``const_arrays``, a gated
    fetch, or the document's own ``loader_fields``. Running such a problem would
    integrate against the parameters' defaults and report success, so it is
    refused at construction instead, naming the first unbound field.
    """
    for what, names in (
        ("a time-varying provider", discrete_providers),
        ("an injected array (a provider or const_arrays)", merged),
        ("a gated provider", gated),
        ("an in-document data loader", flat.loader_fields),
    ):
        if names:
            first = sorted(str(getattr(n, "name", n)) for n in names)[0]
            raise CompilerRefusedRuleError(
                "sympy",
                f"field {first}",
                f"it is bound by {what}, and this compiler lambdifies a scalar "
                "right-hand side with no seam for bound data",
                phase="construction",
            )


def _refuse_array_document_under_sympy(flat: FlattenedSystem) -> None:
    """``compiler="sympy"`` runs SCALAR documents; an array one is refused.

    §5.8 gives ``sympy`` one job — a lambdified SymPy scalar right-hand side —
    and array-ness is a property of the document, not of how the equation
    happens to be spelled: a DECLARED ``shape`` (esm-spec §6.3) says so even
    when the defining equation is a bare whole-array ``D(theta) ~ 1``, and an
    array op anywhere says so for every discretized PDE. Both are refused here,
    at construction, rather than lambdified into a scalar the caller would then
    read as the answer for a whole field.
    """
    if _declares_resolvable_shape(flat):
        shaped = sorted(
            n
            for varmap in (flat.state_variables, flat.observed_variables)
            for n, v in varmap.items()
            if getattr(v, "shape", None)
        )
        raise CompilerRefusedRuleError(
            "sympy",
            f"variable {shaped[0]}" if shaped else "the document",
            "it declares an array `shape`, and this compiler lambdifies a SCALAR "
            "right-hand side only",
            phase="construction",
        )
    for eq in flat.equations:
        if _has_array_op(eq.lhs) or _has_array_op(eq.rhs):
            raise CompilerRefusedRuleError(
                "sympy",
                rule_label(eq),
                "it carries an array op, and this compiler lambdifies a SCALAR "
                "right-hand side only",
                phase="construction",
            )


def exercise_every_evaluation(
    flat: FlattenedSystem,
    build: _NumpyRhsBuild,
    t0: float,
    loader_arrays: dict[str, Any] | None = None,
) -> None:
    """Run, at construction, the two evaluations the build itself does not.

    The Python ``faq`` ladder decides per aggregate AT EVALUATION TIME, so a
    build that only compiled would report a tier it had not reached and a strict
    ``native`` would refuse nothing. esm-libraries-spec §2.5.10 answers this
    directly: a binding whose ladder decides at evaluation time MUST exercise
    every evaluation at construction. Three of the four evaluations it names
    already happen above — the const-geometry hoist and the static observeds
    inside ``_build_numpy_rhs``, and the per-segment seed IS a build. These are
    the remaining two.

    A failure that is not a compiler refusal is swallowed: the probe's job is to
    surface the TIERS, and a document whose right-hand side cannot be evaluated
    at ``(u0, p, t0)`` — one still waiting for a provider, say — has always been
    allowed to build here and fail at ``solve``. Turning those into build errors
    would be a different change, made by accident.
    """
    try:
        with phase_scope("rhs"):
            build.rhs_function(float(t0), build.y0)
    except CompilerRefusedRuleError:
        raise
    except Exception:  # noqa: BLE001 — a non-refusal failure stays a run failure
        pass
    try:
        probe_output_time_observeds(flat, build, float(t0), loader_arrays=loader_arrays)
    except CompilerRefusedRuleError:
        raise
    except Exception:  # noqa: BLE001 — see above
        pass


def _declares_resolvable_shape(flat: FlattenedSystem) -> bool:
    """Does any variable DECLARE an array shape this document can resolve?

    esm-spec §6.3 makes ``shape`` — "the ordered list of index-set names the
    variable is arrayed over" — the authoritative statement of array-ness; it
    says nothing about how the defining equation happens to be spelled. Equation
    content alone therefore under-reports: a bare whole-array ``D(theta) ~ 1``
    over ``"shape": ["lev"]`` carries no ``index`` / ``faq``
    node anywhere, so :func:`_has_array_op` sees a scalar system and the state
    reaches the SymPy pathway with no cells at all (issue #231). The
    ``faq`` spelling of the SAME semantics routed to the array runtime,
    which made the choice of spelling — not the model — decide the answer.

    This mirrors ``_build_numpy_rhs``'s own declared-shape resolution (esm-spec
    §11), including its fallback: a shape is only counted when every axis
    RESOLVES against the document's ``index_sets`` registry to a concrete
    extent. An unresolvable shape (an axis naming no registry entry, or a
    ``derived`` set whose extent value-invention has not materialized yet) is
    exactly the case where the array build would fall back to usage inference
    and infer the same scalar, so routing on it would change the engine without
    changing the answer.

    All three §6.3 roles, because §6.3 gives them all the same ``shape`` field
    and privileges none. A shaped PARAMETER carrying inline array data (§6.3
    "Inline array data") is array-valued whatever its consumers look like, and
    the scalar pathway refuses to bind it. A shaped OBSERVED is array-valued for
    the same reason its state counterpart is, and ``_build_numpy_rhs`` resolves
    an observed's declared shape through this very resolver — so a declaration
    that routes a document here is a declaration the build then honours.

    Why an UNRESOLVABLE shape is safe to route to the scalar engine, closed
    rather than asserted. There are exactly three sources of extent in this
    binding, and none of them can give the array build cells this predicate does
    not see. (1) Declared shape: the array layout calls this same resolver with
    the same absent ``derived_extents``, so what it cannot resolve here it cannot
    resolve there either. (2) Usage inference (``infer_variable_shapes``) and
    (3) the pointwise lift (``lifted_shapes``) both read extents out of ``index``
    / ``faq`` nodes, and any document carrying one of those takes the array route
    on the array-op test regardless of what any shape resolves to. What is left —
    a shaped parameter whose inline array data the scalar tier cannot bind — the
    scalar tier REFUSES by name rather than binding a stand-in. So the two
    engines agree on such a document or one of them declines it; neither answers
    differently.
    """
    for varmap in (flat.state_variables, flat.parameters, flat.observed_variables):
        for var in varmap.values():
            declared = getattr(var, "shape", None)
            if not declared:
                continue
            resolved = _resolve_index_set_shape(list(declared), flat.index_sets)
            if resolved:
                return True
    return False


def _assert_shaped_states_have_extent(flat: FlattenedSystem) -> None:
    """Refuse a shaped state that names an undeclared index set and has no extent.

    esm-spec §6.3 makes a variable's ``shape`` a list of keys in the
    ``index_sets`` registry. A state whose declared shape names a set the
    registry does not hold, and which no equation indexes, has no extent from
    either source: the declaration cannot size it and usage inference gives it
    none. Building it anyway lays a field the document says is arrayed out as a
    single scalar slot. §9.7.10 allows such a name only until a grid is
    injected, and "a name still unresolved after injection remains an error at
    the build", so the build refuses it with the same code the ``ranges``
    ``from`` resolver uses. Julia's tree-walk refuses these states
    (``E_TREEWALK_UNDECLARED_INDEX_SET``) and Rust's array build does too.

    Two cases are deliberately left alone. A name the registry holds but cannot
    size yet (a ``derived`` set value invention materializes) is a declared set,
    not an undeclared one. A state its equations index over literal ranges gets
    its extent from them, which is how Julia builds it as well.
    """
    registry = flat.index_sets or {}
    inferred: dict[str, tuple[int, ...]] | None = None
    for name, var in flat.state_variables.items():
        declared = getattr(var, "shape", None)
        if not declared:
            continue
        undeclared = [axis for axis in declared if axis not in registry]
        if not undeclared:
            continue
        if inferred is None:
            inferred = infer_variable_shapes(flat)
            inferred.update(flat.lifted_shapes or {})
        if inferred.get(name):
            continue
        raise SimulationError(
            f"{E_REF_UNDECLARED_INDEX_SET}: state {name!r} declares shape "
            f"{list(declared)}, but index set(s) {undeclared} are not declared in "
            f"the document `index_sets` registry and no equation indexes the "
            f"state, so it has no extent; declare them, or inject the grid that "
            f"does (esm-spec §6.3, §9.7.10: a name still unresolved after "
            f"injection is an error at the build)"
        )


def _assert_no_doubly_defined_state(flat: FlattenedSystem) -> None:
    """Refuse an unknown that carries BOTH a derivative equation and a bare-LHS one.

    esm-spec §4.9.4 counts unknowns against equations "whichever form the LHS
    takes", so ``D(x) ~ f`` alongside ``x ~ g`` is two equations binding one
    unknown: the document is unbalanced, and :func:`earthsci_ast.validate`
    reports exactly that, ``equation_count_mismatch`` at ``/models/<M>``. The
    build is the other place the same document arrives. Tie-breaking it — keeping
    the derivative and dropping the bare equation — integrates a system free of a
    constraint the file declares and reports the trajectory as the answer, so
    esm-libraries-spec §2.5.2 puts the conflict here, at construction, named.

    The check is over EQUATION SHAPES, not over the ``state``/``observed``
    split: the four derivative spellings :func:`_differentiated_lhs_target`
    recognizes all name the same differentiated unknown, and a bare-string LHS on
    that name is the competing definition whichever bucket flatten filed it in.
    """
    diff_targets: dict[str, Any] = {}
    bare_targets: dict[str, Any] = {}
    for eq in flat.equations:
        target = _differentiated_lhs_target(eq.lhs)
        if target is not None:
            diff_targets.setdefault(target, eq)
        elif isinstance(eq.lhs, str):
            bare_targets.setdefault(eq.lhs, eq)
    clash = sorted(set(diff_targets) & set(bare_targets))
    if not clash:
        _assert_no_redundant_definition(flat)
        return
    name = clash[0]
    diff_eq = diff_targets[name]
    bare_eq = bare_targets[name]
    raise _unbalanced(
        f"unknown {name!r} is defined twice — by "
        f"`{_expr_to_string(diff_eq.lhs)} ~ {_expr_to_string(diff_eq.rhs)}` and by "
        f"`{_expr_to_string(bare_eq.lhs)} ~ {_expr_to_string(bare_eq.rhs)}`. "
        f"esm-spec §4.9.4 counts an equation whichever form its LHS takes, so this "
        f"system has one more equation than it has unknowns to bind; keeping the "
        f"derivative and dropping the constraint would run a model the document does "
        f"not describe. Remove one of the two definitions."
    )


def _assert_no_redundant_definition(flat: FlattenedSystem) -> None:
    """Refuse a second WHOLE definition of an unknown that binds nothing new.

    The sibling above catches one shape of it — a derivative equation beside a
    bare-LHS one. This catches the rest: two bare-LHS definitions of one unknown,
    or two derivative equations on it. ``M.K ~ M.p`` beside ``M.K ~ 2·M.p`` is
    two equations for one unknown, which esm-spec §4.9.4 counts as unbalanced
    and :func:`earthsci_ast.validate` reports the same way.

    Only the case that binds NOTHING NEW is refused here. A second definition
    whose right-hand side names an unknown nothing else defines is a
    differential-algebraic constraint determining that unknown, not a redundant
    equation — a legitimate system, which the SymPy compiler solves and the NumPy
    interpreter refuses on its own grounds
    (``simulation_array._assert_no_unsolved_algebraic_constraint``). Refusing it
    here would take a document away from the compiler that can run it.
    """
    found = classify_second_whole_definition(flat)
    if found is None or found[0] != "unbalanced":
        return
    _kind, first, second, name, _undetermined = found
    raise _unbalanced(
        f"unknown {name!r} is defined twice — by "
        f"`{_expr_to_string(first.lhs)} ~ {_expr_to_string(first.rhs)}` and by "
        f"`{_expr_to_string(second.lhs)} ~ {_expr_to_string(second.rhs)}`. "
        f"esm-spec §4.9.4 counts an equation whichever form its LHS takes, and the "
        f"second binds no unknown the first did not, so this system has one more "
        f"equation than it has unknowns to bind. Remove one of the two definitions."
    )


def _refuse_unsupported_constructs(flat: FlattenedSystem, file: EsmFile | None) -> None:
    """esm-spec §9.6.6 ``unsupported_construct`` — refuse an event (continuous or
    discrete), an implicit equation or a Wiener-noise parameter before any
    pathway is built.

    Neither the SymPy scalar pathway nor the NumPy array interpreter runs an
    event, and neither solves an equation whose LHS is an expression. Both used
    to build anyway and report a number the document does not describe (issues
    #264 and #356). The SymPy pathway's continuous-event root functions only
    stop the integration at the first crossing; no affect is ever applied. The
    evaluator named in the message is the one the document's array-ness
    selects; an event is refused on every route, including the data-refresh
    ones.
    """
    evaluator = (
        "Python array interpreter"
        if _declares_resolvable_shape(flat)
        or any(_has_array_op(eq.lhs) or _has_array_op(eq.rhs) for eq in flat.equations)
        else "Python scalar interpreter"
    )
    # `flatten` lifts only the TOP-LEVEL components' events, so an event owned by
    # an inline subsystem is not in `flat` at all; look for it in the document.
    found = next(
        (
            (construct, events[0])
            for construct, events in (
                ("continuous event", flat.continuous_events),
                ("discrete event", flat.discrete_events),
            )
            if events
        ),
        None,
    )
    if found is None and file is not None:
        found = _first_subsystem_event(file)
    if found is not None:
        construct, event = found
        name = getattr(event, "name", None)
        raise UnsupportedConstructError(construct, f"'{name}'" if name else "(unnamed)", evaluator)
    for eq in flat.equations:
        if is_implicit_lhs(eq.lhs):
            raise UnsupportedConstructError(
                "implicit equation",
                f"`{_expr_to_string(eq.lhs)} ~ {_expr_to_string(eq.rhs)}`",
                evaluator,
            )
    # A Wiener-noise parameter (``update.kind = "wiener"``) makes the document an
    # SDE. Neither pathway integrates one: both read the noise as a constant and
    # report the trajectory of a different, deterministic model.
    if flat.brownian_parameters:
        name = next(iter(flat.brownian_parameters))
        raise UnsupportedConstructError("Wiener noise", f"parameter '{name}'", evaluator)


def _first_subsystem_event(file: EsmFile) -> tuple[str, Any] | None:
    """The first event an inline subsystem declares, at any depth under any model
    or reaction system of ``file``, a continuous one before a discrete one, as
    ``(construct, event)``; ``None`` when there is none."""

    def in_subsystems(component: Any) -> tuple[str, Any] | None:
        for sub in (getattr(component, "subsystems", None) or {}).values():
            for construct, attr in (
                ("continuous event", "continuous_events"),
                ("discrete event", "discrete_events"),
            ):
                events = getattr(sub, attr, None)
                if events:
                    return construct, events[0]
            found = in_subsystems(sub)
            if found is not None:
                return found
        return None

    for component in [*file.models.values(), *file.reaction_systems.values()]:
        found = in_subsystems(component)
        if found is not None:
            return found
    return None


def _assert_no_unlowered_operator(flat: FlattenedSystem) -> None:
    """esm-spec §9.6.3 constraint 6 / §9.6.8 — the pre-evaluation rewrite-target gate.

    The spec makes this a WALK, not a reachability test: "before a component is
    EVALUATED or COMPILED for simulation, its expression trees are walked; any
    node whose ``op`` is not in the evaluable-core set (§4.2) — including a
    spatial ``D``, or any ``D`` in a right-hand-side / evaluation position — is
    rejected with diagnostic ``unlowered_operator``". §9.6.8 calls it "the sole
    guarantee that a rewrite-target op cannot reach evaluation", and §9.6.3
    constraint 6 is what a constrained rule that never fires falls through to.

    Python used to have no such walk. Both pathways raised ``unlowered_operator``
    REACTIVELY, when the evaluator happened to reach the node — which made the
    gate an artifact of the engine rather than of the document. The scalar-SymPy
    pathway lambdifies every observed eagerly and so tripped over a surviving
    op in a DEAD observed; the NumPy pathway evaluates observeds lazily and
    never reached one. The same document therefore passed or failed on which
    engine the router picked. Walking here, at the one front door every build
    routes through, makes the answer a property of the document — and it stays
    one now that the engine is the caller's to name, since a gate that fires
    before any compiler is consulted cannot depend on which one was.

    Scope. Equations (which is where flatten puts every observed body) and the
    ``ic`` right-hand sides — the trees that are compiled for simulation. A
    ``D`` is evaluable-core ONLY in its structural equation-LHS role, where it
    names the differentiated state and is never evaluated; ``args`` of an LHS
    ``faq`` are still LHS, so the array-level spelling
    ``aggregate{k}(D(theta[k]))`` stays legal. Anywhere on a right-hand side,
    any ``D`` at all is a rewrite target — exactly the rule
    :mod:`earthsci_ast.numpy_interpreter` already applies at evaluation.

    This does NOT narrow CONFORMANCE_SPEC §5.27.3 ("a dead observed is still an
    observed"): §5.27.3 is about a dead observed's field staying READABLE
    however the build chose to treat it, and a dead observed whose body is fully
    lowered is untouched here. What the walk refuses is a rewrite-target op that
    no rule eliminated — dead or live, which is §9.6.3's point.

    The same walk refuses an evaluable-core op no pathway evaluates
    (``unevaluable_operator``, esm-spec §9.6.6) — before any pathway is chosen,
    so an op in an untaken ``ifelse`` branch is refused rather than skipped.

    Runs AFTER the §4.7.6.12 surviving-spatial-dimension check above, so a
    document that trips both keeps the diagnostic it has always reported. Both
    carry ``code = "unlowered_operator"``.
    """
    for eq in flat.equations:
        _walk_for_unlowered(eq.lhs, structural_derivative_ok=True)
        _walk_for_unlowered(eq.rhs, structural_derivative_ok=False)
    for _target, rhs in flat.field_ics:
        _walk_for_unlowered(rhs, structural_derivative_ok=False)


#: Evaluable-core ops no Python pathway evaluates, refused at the front door with
#: ``unevaluable_operator`` (esm-spec §9.6.6) when they stand OUTSIDE a ``faq``.
#: Inside one they may be a value-invention producer (``value_invention``'s
#: ``_VI_BODY_OPS`` / ``_VI_ARGWITNESS_OPS``), which the build materializes before
#: anything is evaluated, so the walk leaves those to that stage.
_FRONT_DOOR_UNEVALUABLE_OPS: frozenset[str] = frozenset(
    {"rank", "distinct", "argmin", "argmax", "enum", "apply_expression_template"}
)


def _walk_for_unlowered(
    expr: Any, *, structural_derivative_ok: bool, inside_faq: bool = False
) -> None:
    """Raise on the first non-evaluable-core node in ``expr`` (pre-order).

    ``structural_derivative_ok`` marks an equation-LHS tree, the one position
    where a time ``D`` is core (§4.2). It propagates to children so a ``D``
    nested under an LHS ``faq`` is still structural.
    """
    if not isinstance(expr, ExprNode):
        return
    op = expr.op
    if op == "D":
        if not structural_derivative_ok or op_registry.is_rewrite_target_derivative(
            op, getattr(expr, "wrt", None)
        ):
            raise UnreachableSpatialOperatorError(op)
    elif op not in _EVALUABLE_CORE_OPS:
        raise UnreachableSpatialOperatorError(op)
    elif op in _FRONT_DOOR_UNEVALUABLE_OPS and not inside_faq and not structural_derivative_ok:
        raise UnevaluableOperatorError(op)
    for child in iter_children(expr):
        _walk_for_unlowered(
            child,
            structural_derivative_ok=structural_derivative_ok,
            inside_faq=inside_faq or op == "faq",
        )


def policy_for(prob: EsmProblem) -> CompilerPolicy:
    """The compiler policy this problem was BUILT with, for re-installing.

    Construction exercises every evaluation it can reach, but two kinds of
    evaluation happen later and must stay under the same compiler: a
    cadence-segmented engine builds its right-hand side per SEGMENT during
    ``solve``, and :func:`remake` rebuilds on a substituted parameter. Without
    the policy re-installed those would walk per cell in silence under
    ``native`` — a fallback, which esm-libraries-spec §2.5.10 forbids outright —
    and under ``interpreter`` they would quietly run the fast tiers instead of
    the reference.

    The report is the SAME object, so a segment build's landings append to the
    record the caller reads off the problem rather than starting a new one.
    """
    return CompilerPolicy(
        compiler=prob.compiler,
        strict=prob.compiler == "native",
        every_tier_off=prob.compiler == "interpreter",
        report=prob.compiler_report,
    )


# --------------------------------------------------------------------------- #
# solve (esm-libraries-spec §2.5.3)
# --------------------------------------------------------------------------- #


def solve(
    prob: EsmProblem | EnsembleProblem,
    *,
    alg: str = DEFAULT_ALG,
    abstol: float | None = None,
    reltol: float | None = None,
    saveat: Any = None,
    callback: Any = None,
    maxiters: int | None = None,
    trajectories: int | None = None,
) -> Solution | list[Solution]:
    """Run ``prob`` to completion and return its :class:`Solution`.

    The vocabulary is SciML's, not SciPy's (API_SPEC §4): ``alg`` (not
    ``method``), ``abstol`` (not ``atol``), ``reltol`` (not ``rtol``), ``saveat``
    (not ``t_eval``). The defaults — ``reltol=1e-4``, ``abstol=1e-6`` — are the
    canonical cross-binding ones, so Julia, Python and Rust solving the same
    document with default options produce comparable trajectories. They are
    looser than this binding's historical ``1e-10`` / ``1e-14``; pass an explicit
    tolerance when accuracy matters.

    Parameters
    ----------
    prob:
        The :class:`EsmProblem` to run, or an :class:`EnsembleProblem` (in which
        case ``trajectories`` is required and a ``list`` of solutions comes
        back).
    alg:
        The solver algorithm. This binding's ecosystem has no first-class
        algorithm object, so a SciPy method name is accepted (§2.5.3).
    abstol, reltol:
        Absolute and relative INTEGRATION tolerances. ``None`` (the default)
        means "not given" and resolves per esm-spec §2.2.2, most-specific
        first: an explicit argument here, then the document's
        ``solver.abstol`` / ``solver.reltol`` (§2.2), then the binding default
        (``abstol`` 1e-6, ``reltol`` 1e-4). The two resolve independently, so a
        document declaring only ``reltol`` leaves ``abstol`` on the default.

        These are a different quantity from the ``tolerance`` object an
        assertion is COMPARED at (§6.6.4), which resolves on its own chain.
    saveat:
        Output times: an explicit sequence, or a scalar output STEP measured
        from ``tspan[0]``. ``None`` keeps the dense uniform default grid.
    callback:
        REPLACES the EsmProblem's callback set entirely — it does not append or
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
        # `abstol` / `reltol` are forwarded UNRESOLVED — still `None` when the
        # caller named nothing. Resolving here would turn "caller said nothing"
        # into an explicit binding default at level 1 of the §2.2.2 chain, and
        # each trajectory's own document could then never win. The recursive
        # `solve()` on each member problem runs the chain against that member's
        # document.
        return prob.solve(
            trajectories=trajectories,
            alg=alg,
            abstol=abstol,
            reltol=reltol,
            saveat=saveat,
            callback=callback,
            maxiters=maxiters,
        )

    # esm-spec §2.2.2: caller > document `solver` block > binding default. Read
    # from the typed block the EsmProblem captured at construction, so the order
    # holds however the problem was built (`prob.doc` is populated only on the
    # pushdown-rewrite path).
    abstol, reltol = resolve_tolerances(prob.solver, abstol=abstol, reltol=reltol)
    if not SCIPY_AVAILABLE:
        return _failure_result(_scipy_missing_message("solve"))

    # §2.5.4: an explicit `callback` REPLACES the EsmProblem's set. `None` means
    # "not given", which is what leaves the EsmProblem's own set in force.
    cbs = prob.callbacks if callback is None else CallbackSet(callback)
    cb = cbs if cbs else None

    with use_policy(policy_for(prob)), phase_scope("solve"):
        return _solve_engine(prob, alg, reltol, abstol, saveat, cb, maxiters)


def _solve_engine(
    prob: EsmProblem,
    alg: str,
    reltol: float,
    abstol: float,
    saveat: Any,
    cb: Any,
    maxiters: int | None,
) -> Solution:
    """Dispatch a resolved run onto its segmenting engine, under the problem's
    own compiler policy (installed by :func:`solve`)."""
    if prob.engine == "discrete_providers":
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
            static_cache=prob.static_cache,
            seed=prob.segment_seed,
        )
        return _with_merged_renames(prob, _finish_segmented(sol, saveat, cb))
    if prob.engine == "loaders":
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
            static_cache=prob.static_cache,
            seed=prob.segment_seed,
        )
        return _with_merged_renames(prob, _finish_segmented(sol, saveat, cb))
    if prob.engine == "array":
        return _with_merged_renames(
            prob,
            _simulate_with_numpy(
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
            ),
        )
    return _with_merged_renames(
        prob,
        _simulate_scalar(
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
        ),
    )


def _with_merged_renames(prob: EsmProblem, sol: Solution) -> Solution:
    """Stamp the flatten-time merge map onto a finished solution (issue #230).

    A caller reading ``sol["Sink.O3"]`` after an ``operator_compose`` renaming
    match folded it into ``Chem.O3`` is naming a state that MOVED. The solution
    is the one object such a caller holds and the flattened system is not in its
    hand, so the map travels with the result; :meth:`Solution.resolve_name`
    consults it only for a name the solution does not already carry.

    Mutates in place rather than rebuilding: the pathways return solutions built
    at four different sites, and a rebuild would have to keep every optional
    field of each in step.
    """
    renames = prob.flat.metadata.merged_variable_renames
    if renames:
        sol.merged_renames = dict(renames)
    return sol


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


def callbacks(prob: EsmProblem) -> CallbackSet:
    """The EsmProblem's callback set (esm-libraries-spec §2.5.4).

    Stable API in every simulation-capable binding for one reason: a ``callback``
    argument to :func:`solve` REPLACES this set, so without a way to read it back
    a EsmProblem-level callback would be impossible to extend. Compose explicitly::

        solve(prob, callback=callbacks(prob) + my_extra_callback)
    """
    return prob.callbacks


# --------------------------------------------------------------------------- #
# remake (esm-libraries-spec §2.5.5)
# --------------------------------------------------------------------------- #


def remake(
    prob: EsmProblem,
    *,
    p: dict[str, float] | None = None,
    u0: dict[str, float] | None = None,
    tspan: tuple[float, float] | None = None,
) -> EsmProblem:
    """A NEW EsmProblem with the named substitutions applied, everything else shared.

    It never mutates ``prob``, and it never redoes the parts of construction the
    substitution cannot have invalidated: the flattened system is shared (so the
    SymPy lambdify cache carries over), the materialized provider arrays are
    shared (a changed parameter never re-fetches a provider), and the
    loader-invariant build products — the value-invention join buffers and the
    conservative-regrid geometry — are shared through the parent's static cache.

    ``tspan``-only substitution rebinds nothing at all: the compiled right-hand
    side does not depend on the interval, so the new EsmProblem reuses it verbatim.

    A substitution the EsmProblem cannot honour without a rebuild RAISES, naming
    the parameter and the class that makes it un-substitutable, rather than
    silently rebuilding or silently ignoring it.
    """
    # Resolve merged-away spellings before anything reads the keys, exactly as
    # `esm_problem` does at the build front door (issue #230): `prob.p` /
    # `prob.u0` are already resolved, so only the caller's new keys need it.
    renames = dict(prob.flat.metadata.merged_variable_renames)
    p = None if p is None else resolve_merged_renames(renames, p)
    u0 = None if u0 is None else resolve_merged_renames(renames, u0)

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
        # in it. There is nothing to substitute into — build a new EsmProblem.
        clash = sorted(set(p) & set(prob.metaparameters))
        if clash:
            raise SimulationError(
                f"remake: '{clash[0]}' is a METAPARAMETER of this document, not a "
                f"substitutable parameter — it is closed at load and sizes the "
                f"system's index sets, so changing it changes the shape of the "
                f"state vector. Build a new EsmProblem with "
                f"esm_problem(..., metaparameters={{'{clash[0]}': ...}})."
            )
        check_parameter_override_keys(prob.flat.parameters, p, flat_namespace_scope(prob.flat))
        # A gated provider's fetch was SLICED to the support set value-invention
        # derived from the parameters at construction. Substituting a parameter
        # can move that set, and re-fetching is exactly what remake must not do.
        if prob.gated_provider_keys:
            raise SimulationError(
                f"remake: this EsmProblem carries GATED providers "
                f"({', '.join(prob.gated_provider_keys)}), whose fetch was pre-sliced "
                f"to the support set derived from the build-time parameters; "
                f"substituting '{sorted(p)[0]}' could move that set, and remake must "
                f"not re-fetch provider data. Build a new EsmProblem with esm_problem()."
            )

    rebind = p is not None or u0 is not None
    build = prob.build
    scalar_build = prob.scalar_build
    # The rebuild is the SAME compiler's: a remake that quietly changed strategy
    # would make `prob.compiler` describe the original build only.
    with use_policy(policy_for(prob)), phase_scope("construction"):
        if rebind and prob.engine == "array":
            build = _build_numpy_rhs(
                prob.flat,
                new_p,
                new_u0,
                loader_arrays=prob.const_arrays,
                static_cache=prob.static_cache,
                sample_time=prob.sample_time,
                build_only=True,
            )
            exercise_every_evaluation(
                prob.flat, build, prob.sample_time, loader_arrays=prob.const_arrays
            )
        elif rebind and prob.engine == "scalar":
            scalar_build = _build_scalar_rhs(prob.flat, new_p, new_u0, cse=prob.cse)

    return EsmProblem(
        flat=prob.flat,
        tspan=new_tspan,
        p=new_p,
        u0=new_u0,
        compiler=prob.compiler,
        compiler_report=prob.compiler_report,
        engine=prob.engine,
        # The seed was built for the ORIGINAL p / u0 / tspan, so a remake that
        # rebinds any of them must not start from it. Dropping it costs the new
        # problem one segment-0 build at its first run, which is what an
        # unseeded segmented problem has always paid.
        segment_seed=None if rebind or tspan is not None else prob.segment_seed,
        build=build,
        scalar_build=scalar_build,
        scalar_build_error=None if scalar_build is not None else prob.scalar_build_error,
        const_arrays=prob.const_arrays,
        providers=prob.providers,
        gated_provider_keys=list(prob.gated_provider_keys),
        doc=prob.doc,
        solver=prob.solver,
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
#: takes. Imported lazily by :func:`init` so constructing a EsmProblem never needs
#: SciPy (§2.5.9).
_STEPPABLE_ALGS = ("RK45", "RK23", "DOP853", "Radau", "BDF", "LSODA")


def _stepped_under_policy(rhs: Callable, policy: CompilerPolicy) -> Callable:
    """Wrap a right-hand side so each evaluation runs under ``policy``.

    Without this an ``interpreter`` integrator would quietly step on the fast
    tiers — the one thing the reference must not do — and a ``native`` one would
    walk per cell in silence if a step reached a node construction did not.
    """

    def stepped(t: float, y: np.ndarray) -> np.ndarray:
        with use_policy(policy), phase_scope("rhs"):
            return rhs(t, y)

    return stepped


class Integrator:
    """A stepping integrator over a :class:`EsmProblem` (esm-libraries-spec §2.5.6).

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

    ``abstol`` / ``reltol`` resolve on the esm-spec §2.2.2 chain — call site,
    then the document's ``solver`` block, then the binding default — the same
    chain :func:`solve` runs, because it belongs to a document being integrated
    rather than to one entry point. The resolved values are readable back as
    :attr:`abstol` / :attr:`reltol`.
    """

    def __init__(
        self,
        prob: EsmProblem,
        *,
        alg: str = DEFAULT_ALG,
        abstol: float | None = None,
        reltol: float | None = None,
        callback: Any = None,
        maxiters: int | None = None,
    ) -> None:
        if not SCIPY_AVAILABLE:
            raise SimulationError(_scipy_missing_message("step"))
        if prob.engine in ("loaders", "discrete_providers"):
            raise SimulationError(
                f"init: the {prob.engine!r} pathway rebuilds its right-hand side at "
                f"every cadence boundary, so it has no single steppable integrator. "
                f"Run it with solve()."
            )
        import scipy.integrate as _si

        if alg not in _STEPPABLE_ALGS:
            raise SimulationError(
                f"init: alg={alg!r} is not a steppable SciPy solver "
                f"(have: {', '.join(_STEPPABLE_ALGS)})"
            )
        # esm-spec §2.2.2: caller > the document's `solver` block > binding
        # default, per field. The chain belongs to "a document is being
        # integrated", not to the `solve()` call site, so it runs at THIS door
        # too — otherwise ``solve(prob)`` honoured a declared ``abstol`` and
        # ``init(prob)`` + ``step`` silently did not, on the same document.
        #
        # ``None`` (not ``DEFAULT_ABSTOL``) is what makes level 1 expressible: a
        # concrete default here would be indistinguishable from a caller who
        # passed that value, and the document could never win. The chain tests
        # ``is not None`` rather than truthiness, so a declared ``0.0`` — a
        # value the author SET — is not swallowed.
        abstol, reltol = resolve_tolerances(prob.solver, abstol=abstol, reltol=reltol)
        rhs, y0, names = _rhs_of(prob)
        # Every step runs under the problem's own compiler. `solve` installs the
        # policy once around the whole run; a stepping integrator has no such
        # scope — the caller drives it — so the right-hand side carries it. Two
        # ContextVar sets per evaluation, against a whole right-hand side.
        rhs = _stepped_under_policy(rhs, policy_for(prob))
        self.prob = prob
        self.vars: list[str] = names
        #: The effective INTEGRATION tolerances this integrator holds, after the
        #: §2.2.2 chain. A different quantity from the assertion-comparison
        #: ``tolerance`` object of §6.6.4.
        self.abstol: float = abstol
        self.reltol: float = reltol
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


def _rhs_of(prob: EsmProblem) -> tuple[Callable, np.ndarray, list[str]]:
    """The compiled ``(rhs, u0, element names)`` a EsmProblem steps."""
    if prob.engine == "array" and prob.build is not None:
        build = prob.build
        return build.rhs_function, build.y0, _element_names(build.state_names, build.shapes)
    build_s = prob.scalar_build
    if build_s is None:
        # `bare assert` would vanish under -O; this is a real reachable state
        # (a state-free document whose SymPy lowering the interpreter-only body
        # defeated), so it gets a real error — carrying the construction-time
        # cause, which is the thing that actually explains it.
        cause = prob.scalar_build_error
        reason = (
            f"its SymPy compile did not finish ({type(cause).__name__}: {cause})"
            if cause is not None
            else "it has no compiled right-hand side"
        )
        raise SimulationError(
            f"init: this EsmProblem cannot be stepped (pathway {prob.engine!r}) "
            f"because {reason}. Run it with solve()."
        ) from cause
    if build_s.rhs_function is None:
        raise SimulationError(
            "init: this system has no ODE states to step (it is observed-only); "
            "sample its observed bodies with solve()."
        )
    return build_s.rhs_function, build_s.y0, list(build_s.state_names)


def init(
    prob: EsmProblem,
    *,
    alg: str = DEFAULT_ALG,
    abstol: float | None = None,
    reltol: float | None = None,
    callback: Any = None,
    maxiters: int | None = None,
) -> Integrator:
    """Build a stepping :class:`Integrator` over ``prob`` (esm-libraries-spec §2.5.6).

    ``abstol`` / ``reltol`` resolve on the esm-spec §2.2.2 chain, exactly as
    :func:`solve`'s do: ``None`` (the default) means "not given", so the
    document's ``solver.abstol`` / ``solver.reltol`` are used, falling through
    per field to the binding defaults (``abstol`` 1e-6, ``reltol`` 1e-4). An
    explicit argument here wins outright. The chain runs wherever a document is
    integrated, so stepping honours the document as solving does.
    """
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
    argument type and :func:`solve` already names the EsmProblem-to-Solution verb.
    """
    return integrator.solve()


# --------------------------------------------------------------------------- #
# Ensembles (esm-libraries-spec §2.5.8)
# --------------------------------------------------------------------------- #


@dataclass
class EnsembleProblem:
    """A :class:`EsmProblem` plus a per-trajectory rewrite (esm-libraries-spec §2.5.8).

    This is the canonical form for a parameter sweep, Monte Carlo over declared
    distributions, and perturbed initial conditions::

        ens = EnsembleProblem(prob, lambda p, i: remake(p, p={"k1": ks[i]}))
        sols = solve(ens, trajectories=len(ks))

    ``rewrite(prob, i)`` returns the EsmProblem for trajectory ``i`` (0-based) —
    ordinarily via :func:`remake`, so the family shares one build. A rewrite
    that returns ``None`` runs the base EsmProblem unchanged.
    """

    prob: EsmProblem
    rewrite: Callable[[EsmProblem, int], EsmProblem | None] | None = None

    def problem_for(self, i: int) -> EsmProblem:
        """The EsmProblem for trajectory ``i``."""
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


def _field_components(arrays: dict, scalars: dict) -> set[str]:
    """The distinct components owning a problem's build-time fields.

    A component is everything before a flattened name's final segment
    (``Sites.North`` for ``Sites.North.u``), and ``""`` for an unqualified one.
    :func:`observed_field` resolves a bare name only when this holds exactly
    one — see API_SPEC §5.8.
    """
    return {k.rsplit(".", 1)[0] if "." in k else "" for k in set(arrays) | set(scalars)}


def observed_field(prob: EsmProblem, name: str):
    """Evaluate/read the state-free observed ``name`` at BUILD time through the
    EsmProblem's own graph — the const-geometry hoist already materialized it; this
    resolves the name against those products. Raises :class:`SimulationError`
    when ``name`` is not a build-time-evaluable observed of the EsmProblem.

    Resolution is the cross-binding rule of API_SPEC §5.8, in precedence order:

    1. **Exact hit** — ``name`` is a flattened field name (``Sites.North.u``).
    2. **Bare name** — ``name`` carries no ``.``, and the problem has exactly
       ONE component; it then resolves to the unique field with that tail.

    A bare name against a MULTI-component problem is refused, with every
    qualified candidate named, rather than bound to an arbitrary one.

    Two arguments in every binding (API_SPEC §5.8): build observability moved to
    a construction-time seam, so no caller has to thread a BuildInspection
    through to read a field back.
    """
    v = str(name)
    build = prob.build
    if build is None:
        raise SimulationError(
            f"observed_field: this EsmProblem took the {prob.engine!r} pathway, which "
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
        # Bare spelling. It resolves only when the problem has exactly ONE
        # component (API_SPEC §5.8): with two mounted components a bare ``u``
        # designates ``Sites.North.u`` and ``Sites.South.u`` equally, and this
        # used to answer with whichever sorted first — a wrong value rather
        # than a refusal, which is the failure mode esm-spec §6.6.2 names as
        # specifically non-conforming for the same shape of lookup.
        matches = sorted(
            k for k in set(arrays) | set(scalars) if k.rsplit(".", 1)[-1] == v and "." in k
        )
        components = _field_components(arrays, scalars)
        if len(components) == 1:
            for k in matches:
                got = _lookup(k)
                if got is not None:
                    break
        elif matches:
            raise SimulationError(
                f"observed_field: '{name}' is a bare name and this EsmProblem has "
                f"{len(components)} components ({', '.join(sorted(components))}); "
                f"qualify it as one of: {', '.join(matches)}"
            )
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
            f"the EsmProblem (state-dependent, unresolved, or not an "
            f"observed at all){detail}"
        )
    return got
