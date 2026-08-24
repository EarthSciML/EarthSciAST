"""
Coupled system flattening for ESM Format (spec §4.7.5 + §4.7.6).

The flattened representation is the canonical intermediate form between an
EsmFile and any downstream consumer (simulation, graph construction, validation,
solver export). All variables are dot-namespaced by their owning system, and
coupling rules have been resolved into the equation set itself.

This module is the Python equivalent of EarthSciAST.jl/src/flatten.jl.
"""

from __future__ import annotations

from collections import OrderedDict
from dataclasses import dataclass, field, replace
from typing import Any

from .classification import inlined_unknowns
from .errors import EarthSciAstError
from .esm_types import (
    ARRAY_OPS,
    AffectEquation,
    CallbackCoupling,
    ContinuousEvent,
    CouplingCouple,
    CouplingEntry,
    DataSource,
    DiscreteEvent,
    Domain,
    EsmFile,
    Expr,
    ExprNode,
    Model,
    OperatorApplyCoupling,
    OperatorComposeCoupling,
    ReactionSystem,
    VariableMapCoupling,
)
from .expr_walk import any_child, iter_children, map_children, walk

# ``_expand_range`` moved to the dependency-free leaf :mod:`.index_ranges` (so
# :mod:`.numpy_interpreter` can import it at module load instead of via three
# function-local imports that dodged an import cycle). Re-exported here under its
# original name for backward compatibility — ``simulation_array`` and callers in
# this module still import ``_expand_range`` from :mod:`.flatten`.
from .index_ranges import expand_range as _expand_range
from .reactions import derive_odes
from .substitute import has_var_placeholder, substitute

#: The operator-model placeholder (esm-spec §6.4). A GLOBAL sentinel: it is
#: never namespaced, and it is exempt from ``translate``-endpoint qualification.
PLACEHOLDER_VAR = "_var"

# ============================================================================
# Errors (spec §4.7.5 + §4.7.6 — names mirror Rust's FlattenError enum
# variants for cross-language error-name parity)
# ============================================================================


class FlattenError(EarthSciAstError):
    """Base class for errors raised during flatten()."""


class ConflictingDerivativeError(FlattenError):
    """Two systems define non-additive equations for the same dependent variable."""


class CoupleMultiplicativeNoTendencyError(FlattenError):
    """A ``multiplicative`` connector transform targets something with no tendency.

    esm-spec §10.3 and esm-libraries-spec §4.7.2 define ``multiplicative``
    against the target's EXISTING ODE right-hand side. When ``to`` names a
    parameter, an observed, an algebraic unknown, or an undefined name, there is
    no ``D(to)`` to multiply and the operation has no meaning.

    Silently dropping the connector equation -- what this binding did before --
    is the one outcome a coupling mis-specification must not have: the document
    declares a coupling and the flattened system carries no trace of it.

    ``additive`` has no counterpart error because zero is the additive identity,
    so an additive term against an absent tendency simply becomes the tendency.
    """

    code = "couple_multiplicative_no_tendency"


class DimensionPromotionError(FlattenError):
    """A variable or equation cannot be promoted given the available Interfaces.

    Raised when dimension promotion is ambiguous, when required dimension
    metadata is missing, or when the promotion request would otherwise fail
    independent of mapping-tier support — see spec §4.7.6.
    """


# The following five errors are declared for cross-binding parity; they are not
# raised by the Python Core tier (§4.7.6 dimension-promotion is not implemented
# in this tier). They exist so callers catching them by name behave uniformly
# across language bindings. (DomainUnitMismatchError, below, IS raised — by the
# identity-transform variable_map unit check, mirroring Julia.)
class UnmappedDomainError(FlattenError):
    """A coupling references a variable whose domain has no mapping rule."""


class UnsupportedMappingError(FlattenError):
    """A dimension-promotion mapping is not supported by this implementation tier.

    Core-tier libraries (the Python tier) only implement ``broadcast`` and
    ``identity`` mappings; ``slice``, ``project``, and ``regrid`` raise this
    error, as do spatial operators (``grad``, ``div``, ``laplacian``) when
    encountered during a Core-tier flatten — see spec §4.7.6.
    """


class DomainUnitMismatchError(FlattenError):
    """An Interface coupling requires a unit conversion that was not declared.

    Raised by the flatten preflight when a ``variable_map`` coupling with an
    ``identity`` transform binds two variables whose declared, non-empty units
    differ (§4.7.6). Mirrors Julia's ``DomainUnitMismatchError``.
    """


class DomainExtentMismatchError(FlattenError):
    """Two domains coupled via ``identity`` have incompatible spatial extents."""


class SliceOutOfDomainError(FlattenError):
    """A ``slice`` mapping reaches outside the source variable's domain."""


class CyclicPromotionError(FlattenError):
    """Promotion rules form a cycle (A→B→…→A)."""


class UnsupportedDimensionalityError(FlattenError):
    """The flattened system has a dimensionality the simulator cannot handle.

    Raised by esm_problem() when the flattened system still contains a spatial
    independent variable. Such a system carries an *undiscretized* spatial
    operator (a spatial ``D`` or ``grad``/``div``/``laplacian`` sugar) that no
    discretization rule reduced to a stencil, so it surfaces the uniform
    cross-binding ``code = "unlowered_operator"`` diagnostic (esm-spec §4.2 /
    §9.6.8, RFC open-op-namespace-fixpoint-rewrite Change B/C) — superseding the
    old per-binding UnsupportedDimensionality / UnreachableSpatialOperator codes.
    """

    #: Stable cross-binding diagnostic code (esm-spec §9.6.6).
    code = "unlowered_operator"


# ============================================================================
# Data classes
# ============================================================================


@dataclass
class FlattenedVariable:
    """A single variable in the flattened system."""

    name: str  # dot-namespaced
    # The DERIVED role (esm-spec §6.3.1), not a declared type: "state" (an ODE
    # state or an algebraic unknown -- both are solved for), "observed" (an
    # unknown a bare-variable-LHS equation defines, eliminable), "parameter", or
    # "species" (a reaction-system state).
    type: str  # "state" | "parameter" | "observed" | "species"
    units: str | None = None
    default: Any = None
    description: str | None = None
    source_system: str | None = None
    # Array-variable shape: the ordered index-set names (esm-spec §10.5 / RFC
    # §5.2) the variable is shaped over, e.g. ``["lon", "lat"]``. None / empty
    # means scalar. Carried so the pointwise lift can recognize a grid-shaped
    # operand (a loaded wind / BC field bound by ``variable_map``) that must be
    # indexed per grid cell.
    shape: list[str] | None = None
    # The DECLARED cadence machinery, carried verbatim so the flattened form is
    # self-describing (esm-libraries-spec §4.7.5 step 4, "Full metadata, not
    # names"): a consumer must be able to build a solver problem — and to re-run
    # the §6.3.1 parameter classification — from the FlattenedSystem alone,
    # without re-reading the source document. ``update`` is one
    # :class:`~.esm_types.ParameterUpdate` or an ordered list of >= 2;
    # ``distribution`` is the sampling law. Both are None for an unknown.
    update: Any = None
    distribution: Any = None


@dataclass
class LoaderField:
    """A data-fed PARAMETER lowered to a flattened array input (esm-spec §8.5).

    From 1.0.0 a data source is not a component: there is no loader subsystem
    and no coupling edge. A model consumes a source by declaring a PARAMETER
    whose ``update`` is ``{kind: "data", source: <key>, from: {file_variable}}``
    — the parameter IS the loaded field, and it owns the units. Flatten records
    this descriptor per such parameter so the simulator can execute the source at
    its cadence and bind the resulting array into the RHS as a read-only input,
    keyed by the parameter's namespaced name. A data-fed parameter carries no
    defining equation: its value is injected, not computed.

    ``cadence`` follows the source-seeded refinement (CONFORMANCE_SPEC §5.7.2,
    cadence.py): a source WITH a ``temporal`` block is time-varying →
    ``"discrete"`` (refreshed in a discrete solver callback at its cadence); a
    source WITHOUT ``temporal`` is non-time-varying → ``"const"`` (read once
    before integration).
    """

    name: str  # "Plume.wind" — the namespaced parameter symbol
    owner: str  # "Plume" — the owning model's namespaced prefix
    subkey: str  # "pl" — the `data_sources` key the parameter's update names
    var: str  # "U" — the source-file variable the binding names
    data_source: DataSource  # the source entry (carries kind/source/temporal)
    cadence: str  # "const" | "discrete"
    # The binding's declared `unit_conversion` (§8.5), applied by the provider
    # path when producing values in the parameter's declared units. None when the
    # document declares none, which must cost nothing.
    unit_conversion: Expr | None = None


@dataclass
class FlattenedEquation:
    """An equation in the flattened system, with namespaced Expr trees.

    Backwards-compatibility note: ``lhs`` and ``rhs`` are stored as Expr trees
    (the canonical form), and ``lhs_str`` / ``rhs_str`` provide pretty-printed
    versions for tests and display.
    """

    lhs: Expr
    rhs: Expr
    source_system: str
    lhs_str: str = ""
    rhs_str: str = ""

    def __post_init__(self) -> None:
        if not self.lhs_str:
            self.lhs_str = _expr_to_string(self.lhs)
        if not self.rhs_str:
            self.rhs_str = _expr_to_string(self.rhs)


@dataclass
class FlattenMetadata:
    """Provenance metadata for a FlattenedSystem."""

    source_systems: list[str] = field(default_factory=list)
    coupling_rules: list[str] = field(default_factory=list)
    operator_applies: list[str] = field(default_factory=list)
    callbacks: list[str] = field(default_factory=list)


@dataclass
class FlattenedSystem:
    """The result of flattening an EsmFile per spec §4.7.5.

    Fields
    ------
    independent_variables:
        Independent variables of the flattened system. Always contains ``"t"``
        for temporal evolution; spatial independent variables (``"x"``, ``"y"``,
        ``"z"``) appear only when the equations contain spatial derivative
        operators (``grad``, ``div``, ``laplacian``).
    state_variables:
        Dot-namespaced state variables, keyed by their namespaced name.
    parameters:
        Dot-namespaced parameters, keyed by their namespaced name.
        Parameters promoted to variables by ``variable_map`` are removed.
    observed_variables:
        Dot-namespaced observed (algebraic / dependent) variables.
    equations:
        Flattened equations as Expr trees.
    continuous_events:
        Continuous events, with variable references rewritten to dot-namespaced
        form.
    discrete_events:
        Discrete events, similarly namespaced.
    domain:
        The file's ``domain`` section, if any (passed through unchanged).
    metadata:
        Provenance about which systems were flattened and which rules applied.

    Backwards-compatibility helpers (``variables`` dict and string-keyed
    helpers) are exposed via properties so existing call sites continue to work.
    """

    independent_variables: list[str] = field(default_factory=lambda: ["t"])
    state_variables: OrderedDict[str, FlattenedVariable] = field(default_factory=OrderedDict)
    parameters: OrderedDict[str, FlattenedVariable] = field(default_factory=OrderedDict)
    observed_variables: OrderedDict[str, FlattenedVariable] = field(default_factory=OrderedDict)
    equations: list[FlattenedEquation] = field(default_factory=list)
    continuous_events: list[ContinuousEvent] = field(default_factory=list)
    discrete_events: list[DiscreteEvent] = field(default_factory=list)
    domain: Domain | None = None
    metadata: FlattenMetadata = field(default_factory=FlattenMetadata)
    # Document-scoped index-set registry (RFC semiring-faq-unified-ir §5.2),
    # copied from the top-level document registry. Threaded to the evaluator so
    # it can resolve aggregate range references of the form {"from": <name>}.
    index_sets: dict[str, Any] = field(default_factory=dict)
    # Data-loader variables lowered to observed arrays (RFC pure-io-data-loaders
    # §4.3). Each is an external input the simulator executes at the loader's
    # cadence and binds into the RHS as a read-only array (see LoaderField).
    # Empty ⇒ the system has no data-loader subsystems, so solve() behaves
    # exactly as before (no injection path).
    loader_fields: list[LoaderField] = field(default_factory=list)
    # Concrete integer grid shapes assigned by the pointwise spatial lift
    # (esm-spec §10.5) to each lifted state variable, e.g.
    # ``{"Chemistry.O3": (4, 2)}``. The simulator's shape resolution prefers
    # these over index-use inference (a lifted species' own operator makearray
    # reads offset cells like ``index(sp, i+1, j)`` that would otherwise widen
    # the inferred extent). Empty ⇒ no lift ran.
    lifted_shapes: dict[str, tuple[int, ...]] = field(default_factory=dict)
    # Memoized result of :func:`infer_variable_shapes` (a pure function of the
    # state variables + equations, both fixed for a run). Declared here so the
    # cache is a real field rather than a monkey-patched attribute. Excluded from
    # equality/repr so it never affects comparisons or debugging output.
    _infer_shapes_cache: dict[str, tuple[int, ...]] | None = field(
        default=None, compare=False, repr=False
    )
    # ---- The remaining canonical fields of esm-libraries-spec §4.7.5 step 4 ----
    #
    # `algebraic_variables`, `brownian_parameters` and `discrete_parameters` are
    # the §6.3.1 classification of the FLATTENED system, re-derived through
    # :mod:`.classification` (never re-implemented here) and re-ordered into
    # document order. Each is a SUBSET of the map it classifies, not a sibling
    # bucket: §6.3.1 says the four parameter sets "partition the parameters", so
    # a wiener-updated entry appears in BOTH `parameters` and
    # `brownian_parameters`. Dropping it from `parameters` would make the
    # parameter vector's LENGTH depend on whether the model is stochastic, and
    # leave the four sets partitioning nothing.
    #
    # Unknowns constrained only by an expression-LHS equation (`H*H*SO4 ~ Ksp`).
    # A SUBSET of `state_variables`: an algebraic unknown is solved for, so it
    # rides in the unknown vector the simulator assembles, and this map says
    # which members of that vector carry no defining equation.
    algebraic_variables: OrderedDict[str, FlattenedVariable] = field(default_factory=OrderedDict)
    # Parameters whose `update.kind` is "wiener" — the SDE noise sources. A
    # SUBSET of `parameters` (see above). Non-empty is exactly the condition
    # `system_kind` tests FIRST, so carrying it is what keeps the flattened form
    # able to report "sde".
    brownian_parameters: OrderedDict[str, FlattenedVariable] = field(default_factory=OrderedDict)
    # Parameters carrying any OTHER update — piecewise-constant between
    # refreshes. A SUBSET of `parameters`.
    discrete_parameters: OrderedDict[str, FlattenedVariable] = field(default_factory=OrderedDict)
    # The document-scoped `function_tables` registry (esm-spec §9.5), copied
    # from the source document. Required to resolve a surviving `table_lookup`
    # node without re-reading the file.
    function_tables: dict[str, Any] = field(default_factory=dict)
    # The MERGED expression-template registry (esm-spec §9.6.4 rule 7, §10.7;
    # esm-libraries-spec §4.7.5 step 4): the union of the component registries
    # with their bodies component-scoped first, deep-equal same-name entries
    # deduplicated at first occurrence, and non-deep-equal collisions renamed to
    # `<ComponentPath>.<name>` along the reference DAG. See
    # :func:`_merged_template_registry`.
    template_registry: dict[str, Any] = field(default_factory=dict)
    # Deferred scoped-reference / array `ic` equations (esm-spec §11.4.1) as
    # ordered `(target_state, rhs)` pairs. These are INITIAL CONDITIONS, not
    # dynamics: a consumer folds them into `u0` rather than integrating them.
    #
    # They are classified OUT of `equations` and appear ONLY here, matching Rust.
    # `equations` is then directly usable as a right-hand side without filtering,
    # and its length is comparable across bindings.
    field_ics: list[tuple[str, Expr]] = field(default_factory=list)

    @property
    def system_kind(self) -> str:
        """The flattened system's derived MTK system kind (esm-spec §6.3.1),
        computed by :func:`classification.system_kind` over the flattened
        variables and equations — "sde" / "pde" / "nonlinear" / "ode", tested in
        that order.

        Available on the flattened form precisely because `brownian_parameters`
        survives flattening: the derivation's first row is "any parameter in
        `brownian_parameters`", so a FlattenedSystem that dropped the bucket
        could not report `"sde"` and a consumer would integrate a stochastic
        system as a deterministic one.
        """
        from .classification import system_kind as _system_kind

        return _system_kind(_classification_view(self))

    @property
    def variables(self) -> dict[str, str]:
        """Type label by namespaced name (compat with the old FlattenedSystem)."""
        out: dict[str, str] = {}
        for name, var in self.state_variables.items():
            out[name] = var.type
        for name, var in self.parameters.items():
            out[name] = var.type
        for name, var in self.observed_variables.items():
            out[name] = var.type
        return out


# ============================================================================
# Expression helpers
# ============================================================================


# The canonical array-op set lives in esm_types (shared with
# numpy_interpreter.expr_contains_array_op); keep the module-local alias for
# existing references.
_ARRAY_OPS = ARRAY_OPS


def _is_number(x: Any) -> bool:
    return isinstance(x, (int, float)) and not isinstance(x, bool)


def _expr_to_string(expr: Expr) -> str:
    """Pretty-print an Expr tree to a single-line human-readable string."""
    if expr is None:
        return ""
    if _is_number(expr):
        return str(expr)
    if isinstance(expr, str):
        return expr
    if isinstance(expr, ExprNode):
        op = expr.op
        args = [_expr_to_string(a) for a in expr.args]

        if op == "D" and expr.wrt:
            inner = args[0] if args else ""
            return f"D({inner}, {expr.wrt})"

        # An op carrying a `dim` axis field (the open-tier differential sugar
        # grad/div/laplacian/curl, or any custom rewrite-target op with a `dim`)
        # renders as `op(inner, dim)`. Keyed STRUCTURALLY on the `dim` field, not
        # on an op-name list — the sugar ops carry no rendering privilege.
        if expr.dim is not None:
            inner = args[0] if args else ""
            return f"{op}({inner}, {expr.dim})"

        if op == "aggregate":
            body = _expr_to_string(expr.expr) if expr.expr is not None else ""
            idxs = ",".join(str(i) for i in (expr.output_idx or []))
            ranges = expr.ranges or {}
            ranges_str = ",".join(f"{k}={v}" for k, v in ranges.items())
            return f"{op}[{idxs}]({body}; {ranges_str})"

        if op == "makearray":
            vals = ",".join(_expr_to_string(v) for v in (expr.values or []))
            return f"makearray(regions={expr.regions}, values=[{vals}])"

        if op == "index":
            return f"index({', '.join(args)})"

        if op == "reshape":
            return f"reshape({', '.join(args)}, shape={expr.shape})"

        if op == "transpose":
            return f"transpose({', '.join(args)})"

        if op == "concat":
            return f"concat({', '.join(args)}, axis={expr.axis})"

        if op == "broadcast":
            return f"broadcast[{expr.fn}]({', '.join(args)})"

        if op in ("+", "-", "*", "/", "^", "**"):
            if op == "-" and len(args) == 1:
                return f"(-{args[0]})"
            return "(" + f" {op} ".join(args) + ")"

        return f"{op}({', '.join(args)})"
    return str(expr)


def _namespace_join(
    join: list[dict[str, Any]],
    binders: set[str],
    prefix: str,
    locals_: set[str],
) -> list[dict[str, Any]]:
    """Prefix the plain-string references a ``join`` clause carries.

    CONFORMANCE_SPEC §5.5.6. A ``join`` names its references as STRINGS rather
    than as child expressions — an ``on`` key column, and an ``overlap``
    clause's ``src_env`` / ``tgt_env`` envelope factors — so ``map_children``
    never sees them. That is an encoding choice, not a scoping one: the
    value-invention materializer resolves each against the variable registry
    (``value_invention._vi_join_index_sym`` -> ``ctx.variables``,
    ``broad_phase.envelope_vectors`` -> ``ctx.const_arrays``), which after
    flattening is the NAMESPACED registry.

    The gate is ``locals_`` — the component's own declared variable names plus
    its subsystem keys — applying exactly the rule a bare ``Expr`` string gets.
    This is what lets the pass tell a model-local buffer (``rg_src_bin``) from a
    document-scoped index set (``sourceType``) or a loop symbol (``src``)
    without an index-set registry: neither of the latter is a declared local
    variable, so both pass through untouched. Mirrors Julia
    ``namespacing.jl::_namespace_join`` and Rust
    ``flatten.rs::namespace_join_names``.

    ``binders`` are the loop symbols THIS node binds (``output_idx`` entries and
    ``ranges`` keys) and they win over ``locals_``: an index symbol is local to
    the enclosing ``aggregate`` and shadows any coincident variable name
    (esm-spec §4.3.1), and an ``on`` key column is resolved against this node's
    own ranges (``value_invention._vi_join_index_sym``,
    ``numpy_interpreter._join_sym_for_key``) — so prefixing a shadowed symbol
    makes it resolve to nothing. Without this the gate mis-fires on the legal
    case of a model that declares a variable named like one of its loop symbols.
    """

    def ns(name: Any) -> Any:
        if not isinstance(name, str):
            return name
        if name in binders:
            return name
        if "." in name:
            return f"{prefix}.{name}" if name.split(".", 1)[0] in locals_ else name
        return f"{prefix}.{name}" if name in locals_ else name

    out: list[dict[str, Any]] = []
    for clause in join:
        if not isinstance(clause, dict):
            out.append(clause)
            continue
        new = dict(clause)
        if isinstance(clause.get("on"), list):
            new["on"] = [
                [ns(c) for c in pair] if isinstance(pair, list) else pair for pair in clause["on"]
            ]
        ov = clause.get("overlap")
        if isinstance(ov, dict):
            new_ov = dict(ov)
            for side in ("src_env", "tgt_env"):
                if isinstance(ov.get(side), list):
                    new_ov[side] = [ns(f) for f in ov[side]]
            new["overlap"] = new_ov
        out.append(new)
    return out


def _namespace_expr(
    expr: Expr,
    prefix: str,
    leave_alone: set[str] | None = None,
    subsystem_keys: set[str] | None = None,
    locals_: set[str] | None = None,
) -> Expr:
    """Recursively prefix every variable reference in ``expr`` with ``prefix.``.

    A bare reference (no dot) is prefixed. A dotted reference is normally left
    alone (already fully namespaced), or skipped if it appears in ``leave_alone``
    (independent vars like ``t``, ``x``) — EXCEPT when its head segment is a key
    in ``subsystem_keys`` (a subsystem mounted on the model being namespaced,
    e.g. a data loader mounted under ``raw``). Such a reference is subsystem-
    LOCAL (``raw.fuel_model``) and must be qualified with the owner
    (``LANDFIRE.raw.fuel_model``) so it matches the lowered LoaderField /
    subsystem variable name; the bare "contains a dot ⇒ leave alone" rule cannot
    tell a subsystem-local reference from an already-absolute one.
    """
    leave_alone = leave_alone or set()
    if expr is None or _is_number(expr):
        return expr
    if isinstance(expr, str):
        if expr in leave_alone:
            return expr
        if "." in expr:
            head = expr.split(".", 1)[0]
            if head not in leave_alone and subsystem_keys and head in subsystem_keys:
                return f"{prefix}.{expr}"  # subsystem-local reference -> qualify
            return expr  # already fully namespaced -> leave alone
        return f"{prefix}.{expr}"
    if isinstance(expr, ExprNode):
        # For aggregate / arrayop, index symbols (output_idx and ranges keys) are
        # local to the expression body and must not be namespaced. They are
        # binder NAMES, not child expressions — expr_walk never visits them —
        # so the only special handling needed is adding them to ``leave_alone``
        # for the children that may reference them.
        local_leave = set(leave_alone)
        if expr.op == "aggregate":
            if expr.output_idx:
                for sym in expr.output_idx:
                    if isinstance(sym, str):
                        local_leave.add(sym)
            if expr.ranges:
                for sym in expr.ranges.keys():
                    local_leave.add(sym)
        # Aggregate filter / key sub-nodes reference the SAME model-local
        # variables the body does (a sliver ``filter rg_A[a,o] > rg_atol``, a
        # ``key`` skolem), so they must be namespaced identically — otherwise the
        # area matrix / bin key a downstream aggregate reads stays bare and
        # cannot be resolved after flatten (RFC §5.3). Range symbols stay local
        # via ``local_leave``.
        #
        # ``join`` carries its references as plain STRINGS (``on`` key columns,
        # an ``overlap``'s ``src_env`` / ``tgt_env``), so ``map_children`` never
        # visits them — but they resolve against the same registry every other
        # reference does, and after flattening that registry is namespaced
        # (§5.5.6). ``_namespace_join`` applies the same rule under the
        # declared-local gate, which is what distinguishes a model-local
        # value-invention buffer (``rg_src_bin``) from a document-scoped index
        # set (``sourceType``) or a loop symbol without needing an index-set
        # registry. This pass used to leave ``join`` alone for exactly that
        # reason; the gate removes the need to.
        #
        # ``map_children`` rebuilds via ``replace`` so closed-function metadata
        # (``name``, ``value``, ``handler_id``, ``table``, ``output``) is
        # preserved automatically. Hand-listing fields silently drops any new
        # ExprNode attribute and cost the SymPy bridge ``fn``-op support
        # before this fix (esm-6ka).
        out = map_children(
            expr,
            lambda c: _namespace_expr(c, prefix, local_leave, subsystem_keys, locals_),
        )
        if locals_ and getattr(expr, "join", None):
            # THIS node's own loop symbols, not ``local_leave`` (which also holds
            # enclosing nodes'). A join column resolves against this node's
            # ``ranges``, so its own binders are the exact shadowing set — and a
            # node-local set is what lets every binding implement one rule.
            binders = set(expr.output_idx or ()) | set((expr.ranges or {}).keys())
            out = replace(out, join=_namespace_join(expr.join, binders, prefix, locals_))
        return out
    return expr


def _lhs_dependent_var(lhs: Expr) -> str | None:
    """Return the dependent variable name from an LHS expression.

    For ``D(var, t)`` returns ``var``. For a bare variable name returns it.
    For ``D(index(var, ...), t)`` returns ``var`` — the array state whose
    element is being differentiated. For ``arrayop(expr=D(index(var, ...), t))``
    likewise returns ``var``. Returns None if the LHS cannot be identified
    (e.g. an algebraic constraint with a complex LHS).
    """
    if isinstance(lhs, str):
        return lhs
    if isinstance(lhs, ExprNode):
        if lhs.op == "D" and lhs.args:
            inner = lhs.args[0]
            if isinstance(inner, str):
                return inner
            if isinstance(inner, ExprNode):
                if inner.op == "D" and inner.args:
                    return _lhs_dependent_var(inner)
                if inner.op == "index" and inner.args:
                    head = inner.args[0]
                    if isinstance(head, str):
                        return head
            return None
        if lhs.op == "aggregate" and lhs.expr is not None:
            return _lhs_dependent_var(lhs.expr)
        # Algebraic equation: LHS is a complex expression — not a single var.
        return None
    return None


def _has_array_op(expr: Expr) -> bool:
    """Return True if ``expr`` contains any array op node."""
    if isinstance(expr, ExprNode):
        if expr.op in _ARRAY_OPS:
            return True
        return any_child(expr, _has_array_op)
    return False


def _spatial_dims_in_expr(expr: Expr) -> list[str]:
    """Return the set of spatial dimension labels named by an unlowered spatial
    differential in ``expr``.

    Harvested STRUCTURALLY from every node's ``dim`` axis field (esm-spec §4.9.1),
    NOT from a list of op names: the open-tier sugar ops grad/div/laplacian/curl
    carry no spatial-detection privilege, so the signal is the ordinary
    axis-naming ``dim`` scalar field (which only an undiscretized differential
    node carries — no evaluable-core op uses it). A discretized system has already
    folded its spatial axes into array dimensions and carries no ``dim`` node, so
    it yields the empty set and stays a pure ODE (``independent_variables ==
    ["t"]``), exactly as before.
    """
    # ORDER-PRESERVING, deduplicated by first encounter. This used to be a
    # `set`, which destroyed the order the document declares its axes in and was
    # then re-imposed as `sorted()` by the caller -- so `full_coupled.esm`, whose
    # equations name lon, lat, lev in that order, came out lat, lev, lon.
    # esm-libraries-spec §4.7.5 step 4 makes ordering document order, and §4.7.6
    # says to add "each referenced spatial dimension" as the scan encounters it.
    # For a PDE the axis order is not cosmetic: it is the order a downstream
    # array layout follows.
    out: list[str] = []
    for node in walk(expr):
        if isinstance(node, ExprNode) and node.dim:
            if node.dim not in out:
                out.append(node.dim)
    return out


# ============================================================================
# Coupling rule descriptions (kept compatible with the previous module)
# ============================================================================


def _describe_coupling(entry: CouplingEntry) -> str:
    if isinstance(entry, OperatorComposeCoupling):
        systems = " + ".join(entry.systems)
        rule = f"operator_compose({systems})"
        if entry.translate:
            def _tr(v: object) -> str:
                # Same leak as the transform above, latent: an object-valued
                # translate entry would otherwise render as a Python dict repr.
                if isinstance(v, dict):
                    target = v.get("to") or v.get("target") or v.get("var") or "?"
                    factor = v.get("factor")
                    return f"{target}" if factor is None else f"{target}*{factor}"
                return str(v)

            rule += (
                " [translate: "
                + ", ".join(f"{k}->{_tr(v)}" for k, v in entry.translate.items())
                + "]"
            )
        return rule
    if isinstance(entry, CouplingCouple):
        systems = " <-> ".join(entry.systems)
        return f"couple({systems})"
    if isinstance(entry, VariableMapCoupling):
        # A §10.4 Expression transform is an ExprNode, and interpolating it here
        # emits the DATACLASS REPR -- ~900 characters naming forty None-valued
        # optional fields of a Python implementation detail. That string then got
        # pinned in the shared corpus as normative cross-language text, which no
        # other binding can reproduce and which changes whenever the dataclass
        # gains a field. Julia, TypeScript and Go all render the word
        # `expression` here; match them.
        transform = entry.transform if isinstance(entry.transform, str) else "expression"
        rule = f"variable_map({entry.from_var} -> {entry.to_var}, transform={transform})"
        if entry.factor is not None:
            rule += f" [factor={entry.factor}]"
        return rule
    if isinstance(entry, OperatorApplyCoupling):
        return f"operator_apply({entry.operator})"
    if isinstance(entry, CallbackCoupling):
        return f"callback({entry.callback_id})"
    return f"unknown({type(entry).__name__})"


# ============================================================================
# Coupling preflight checks (spec §4.7.6)
# ============================================================================
#
# Port of EarthSciAST.jl/src/coupling_apply.jl ``_check_variable_map_units`` +
# ``_lookup_variable_units`` (called from flatten.jl Step 0b). The check is the
# only §4.7.6 preflight the Core tier implements.


def _lookup_model_units(model: Model, name: str) -> str | None:
    """Resolve a (possibly dotted, subsystem-nested) variable's declared units
    within ``model``. Returns None when the variable is missing or carries no
    declared units. Only Model subsystems are recursed into (mirrors Julia's
    Model-only method dispatch)."""
    var = model.variables.get(name)
    if var is not None:
        return var.units
    # Recurse into subsystems for nested names like "Inner.T".
    dot = name.find(".")
    if dot != -1:
        head, rest = name[:dot], name[dot + 1 :]
        sub = model.subsystems.get(head)
        if isinstance(sub, Model):
            return _lookup_model_units(sub, rest)
    return None


def _lookup_rsys_units(rs: ReactionSystem, name: str) -> str | None:
    """Resolve a species' or parameter's declared units within ``rs`` (recursing
    into subsystems for dotted names). Returns None when missing / unit-less."""
    for sp in rs.species:
        if sp.name == name:
            return sp.units
    for p in rs.parameters:
        if p.name == name:
            return p.units
    dot = name.find(".")
    if dot != -1:
        head, rest = name[:dot], name[dot + 1 :]
        sub = rs.subsystems.get(head)
        if sub is not None:
            return _lookup_rsys_units(sub, rest)
    return None


def _lookup_variable_units(esm_file: EsmFile, qualified: str) -> str | None:
    """Look up a dot-qualified variable's declared units across models,
    subsystems, and reaction systems (species + parameters). Returns None when
    the variable is missing or carries no declared units."""
    parts = qualified.split(".")
    if len(parts) < 2:
        return None
    root = parts[0]
    tail = ".".join(parts[1:])
    model = esm_file.models.get(root)
    if model is not None:
        return _lookup_model_units(model, tail)
    rs = esm_file.reaction_systems.get(root)
    if rs is not None:
        return _lookup_rsys_units(rs, tail)
    return None


def _check_variable_map_units(esm_file: EsmFile, coupling_entries: list[CouplingEntry]) -> None:
    """Raise :class:`DomainUnitMismatchError` for any ``identity``-transform
    ``variable_map`` whose ``from``/``to`` variables carry declared, non-empty,
    and DIFFERENT units (spec §4.7.6).

    Port of EarthSciAST.jl's ``_check_variable_map_units``. ``param_to_var`` and
    ``conversion_factor`` transforms are exempt: ``conversion_factor`` declares
    the conversion explicitly; ``param_to_var`` does not imply unit equivalence
    at the mapping site. An expression transform (ExprNode) is likewise not
    ``"identity"`` and is skipped. No error is raised when either unit is
    absent/empty or when the two units match.
    """
    for entry in coupling_entries:
        if not isinstance(entry, VariableMapCoupling):
            continue
        if entry.transform != "identity":
            continue
        src_units = _lookup_variable_units(esm_file, entry.from_var or "")
        tgt_units = _lookup_variable_units(esm_file, entry.to_var or "")
        if not src_units or not tgt_units:
            continue
        if src_units != tgt_units:
            raise DomainUnitMismatchError(
                f"variable {entry.from_var!r} has units {src_units!r} on source "
                f"and {tgt_units!r} on target"
            )


# ============================================================================
# Per-system collection (model + reaction systems lowered to ODEs)
# ============================================================================


@dataclass
class _ComponentSystem:
    """Internal representation of one system before merging."""

    name: str
    state_vars: OrderedDict[str, FlattenedVariable] = field(default_factory=OrderedDict)
    parameters: OrderedDict[str, FlattenedVariable] = field(default_factory=OrderedDict)
    observed: OrderedDict[str, FlattenedVariable] = field(default_factory=OrderedDict)
    equations: list[FlattenedEquation] = field(default_factory=list)
    loader_fields: list[LoaderField] = field(default_factory=list)

    def merge(self, other: _ComponentSystem) -> None:
        """Fold ``other``'s tables into this component (last-writer-wins for the
        variable dicts, order-preserving append for equations/loader fields).

        The single place the five per-system tables are combined — used to pull
        a subsystem into its parent and, in ``_assemble_system``, to fold every
        component into one bag. Centralizing it removes the "add a sixth field,
        forget a merge site" hazard the hand-enumerated versions carried.
        """
        self.state_vars.update(other.state_vars)
        self.parameters.update(other.parameters)
        self.observed.update(other.observed)
        self.equations.extend(other.equations)
        self.loader_fields.extend(other.loader_fields)


def _namespace_equations(
    equations: list,
    component: _ComponentSystem,
    prefix: str,
    leave_alone: set[str],
    subsystem_keys: set[str] | None = None,
    locals_: set[str] | None = None,
) -> None:
    """Namespace both sides of each equation and append it to ``component``.

    Factored out of the model / reaction-system collectors, which otherwise each
    repeat the "namespace lhs, namespace rhs, append a FlattenedEquation tagged
    with the system prefix" wire verbatim.
    """
    for eq in equations:
        component.equations.append(
            FlattenedEquation(
                lhs=_namespace_expr(
                    eq.lhs,
                    prefix,
                    leave_alone=leave_alone,
                    subsystem_keys=subsystem_keys,
                    locals_=locals_,
                ),
                rhs=_namespace_expr(
                    eq.rhs,
                    prefix,
                    leave_alone=leave_alone,
                    subsystem_keys=subsystem_keys,
                    locals_=locals_,
                ),
                source_system=prefix,
            )
        )


def _data_source_fields(
    model: Model, full_prefix: str, data_sources: dict[str, DataSource] | None
) -> list[LoaderField]:
    """Every data-fed parameter of ``model``, as a :class:`LoaderField`.

    A parameter whose ``update`` is ``kind: "data"`` reads one ``file_variable``
    of the named document-scoped source (esm-spec §8.5). Its cadence follows the
    SOURCE, not its own declaration (CONFORMANCE_SPEC §5.7.2): a source WITH a
    ``temporal`` block refreshes per record (``discrete``); one without is read
    once (``const``). An unresolvable source keeps the ``discrete`` seed —
    `data_source_undefined` is the validator's finding, not flatten's.
    """
    sources = data_sources or {}
    fields: list[LoaderField] = []
    for var_name, var in model.variables.items():
        if var.type != "parameter" or var.update is None:
            continue
        rules = var.update if isinstance(var.update, list) else [var.update]
        for rule in rules:
            if rule.kind != "data" or rule.from_source is None:
                continue
            source = sources.get(rule.source)
            if source is None:
                continue
            fields.append(
                LoaderField(
                    name=f"{full_prefix}.{var_name}",
                    owner=full_prefix,
                    subkey=rule.source,
                    var=rule.from_source.file_variable,
                    data_source=source,
                    cadence="discrete" if source.temporal is not None else "const",
                    unit_conversion=rule.from_source.unit_conversion,
                )
            )
    return fields


def _collect_model(
    name: str,
    model: Model,
    prefix: str | None = None,
    data_sources: dict[str, DataSource] | None = None,
) -> _ComponentSystem:
    """Collect a Model (recursively, including subsystems) into a _ComponentSystem."""
    full_prefix = prefix or name
    component = _ComponentSystem(name=full_prefix)

    # The variable's role comes from the §6.3.1 classification, NOT from a
    # declared type. `observed` is the INLINED form specifically -- an unknown a
    # bare-variable LHS defines, which is substituted into its consumers. Every
    # other unknown is SOLVED FOR and lands in `state_vars`: an ODE state, an
    # algebraic unknown, and an ARRAYED definition (`y[i] ~ f(i)`) alike. The
    # arrayed one is observed by §6.3.1 and its cadence resolves through its RHS,
    # but it materializes into a buffer its consumers index rather than being
    # inlined -- exactly the 0.x `state` + index-LHS shape.
    observed = set(inlined_unknowns(model))

    for var_name, var in model.variables.items():
        namespaced = f"{full_prefix}.{var_name}"
        if var.type == "parameter":
            role = "parameter"
        elif var.type != "unknown":
            # Fail closed on a retired 0.x type rather than silently filing it
            # with the unknowns: `state` / `observed` / `brownian` / `discrete`
            # are gone (esm-spec §6.3), and a document still carrying one is a
            # document this binding must not pretend to understand.
            raise FlattenError(
                f"variable '{full_prefix}.{var_name}' declares type "
                f"'{var.type}', which esm 1.0.0 removed; the declared types are "
                f"'unknown' and 'parameter' (esm-spec §6.3)"
            )
        elif var_name in observed:
            role = "observed"
        else:
            role = "state"
        flat_var = FlattenedVariable(
            name=namespaced,
            type=role,
            units=var.units,
            default=var.default,
            description=var.description,
            source_system=full_prefix,
            shape=list(var.shape) if var.shape else None,
            update=var.update,
            distribution=var.distribution,
        )
        if role == "state":
            component.state_vars[namespaced] = flat_var
        elif role == "parameter":
            component.parameters[namespaced] = flat_var
        else:
            component.observed[namespaced] = flat_var

    # _var is a placeholder used by operator_compose; never namespace it.
    leave_alone = {"t", PLACEHOLDER_VAR}
    # Subsystem keys mounted on this model (nested models): references rooted at
    # one of these are subsystem-LOCAL and must be qualified with the model
    # prefix to match the lowered subsystem name (see _namespace_expr).
    sub_keys = set(model.subsystems.keys())
    # The component's own declared names — the gate for namespacing the
    # plain-string references a ``join`` clause carries (§5.5.6). Mirrors Julia
    # ``_collect_model!``'s ``local_names`` and Rust ``build_model_block``'s
    # ``locals``.
    locals_ = set(model.variables.keys()) | sub_keys
    # An observed unknown's defining relation is now an ORDINARY equation with a
    # bare-variable LHS, so the separate `variables[v].expression` lowering that
    # used to run here is gone: `_namespace_equations` below carries it.
    _namespace_equations(
        model.equations,
        component,
        full_prefix,
        leave_alone,
        subsystem_keys=sub_keys,
        locals_=locals_,
    )

    # Data-fed parameters (esm-spec §8.5): the simulator executes each source at
    # its cadence and binds the array under the parameter's namespaced name.
    component.loader_fields.extend(_data_source_fields(model, full_prefix, data_sources))

    for sub_name, sub_model in model.subsystems.items():
        sub_prefix = f"{full_prefix}.{sub_name}"
        sub_component = _collect_model(sub_name, sub_model, sub_prefix, data_sources)
        component.merge(sub_component)

    return component


def _collect_reaction_system(
    name: str, rs: ReactionSystem, prefix: str | None = None
) -> _ComponentSystem:
    """Collect a ReactionSystem (lowered through derive_odes) into a _ComponentSystem.

    Species become state variables; reaction parameters become parameters;
    rate laws are converted to dN_i/dt equations via mass-action kinetics.
    Constraint equations are passed through.

    EXCEPT a reservoir species (``constant: true``, §7.4), which becomes a
    PARAMETER: the spec holds its concentration fixed and emits no ODE for it
    (``derive_odes``/``lower_reactions_to_equations`` already skip its
    equation), so it is not a state. Its ``default`` carries over as the
    parameter's fixed value, so it still reads as a concentration in every rate
    law. Mirrors the Julia reference (namespacing.jl
    ``_collect_reaction_system!``, ``target = sp.constant === true ? params :
    states``).
    """
    full_prefix = prefix or name
    component = _ComponentSystem(name=full_prefix)

    has_reactions = bool(rs.reactions)
    derived: Model | None = None
    if has_reactions:
        derived = derive_odes(rs)

    leave_alone = {"t", PLACEHOLDER_VAR}

    for species in rs.species:
        namespaced = f"{full_prefix}.{species.name}"
        if species.constant is True:
            # Reservoir species: held fixed, no ODE — lower to a parameter whose
            # value is the species' default (see docstring). It still resolves
            # as a concentration factor wherever a rate law references it.
            component.parameters[namespaced] = FlattenedVariable(
                name=namespaced,
                type="parameter",
                units=species.units,
                default=species.default,
                description=species.description,
                source_system=full_prefix,
            )
        else:
            component.state_vars[namespaced] = FlattenedVariable(
                name=namespaced,
                type="species",
                units=species.units,
                default=species.default,
                description=species.description,
                source_system=full_prefix,
            )

    for param in rs.parameters:
        namespaced = f"{full_prefix}.{param.name}"
        default_value: Any = None
        if isinstance(param.value, (int, float)):
            default_value = param.value
        component.parameters[namespaced] = FlattenedVariable(
            name=namespaced,
            type="parameter",
            units=param.units,
            default=default_value,
            description=param.description,
            source_system=full_prefix,
        )

    # Declared local names for the §5.5.6 `join` gate: a reaction system's
    # species and parameters (mirrors Julia `_collect_reaction_system!`).
    rs_locals = {sp.name for sp in rs.species} | {p.name for p in rs.parameters}

    if derived is not None:
        _namespace_equations(
            derived.equations, component, full_prefix, leave_alone, locals_=rs_locals
        )

    _namespace_equations(
        rs.constraint_equations, component, full_prefix, leave_alone, locals_=rs_locals
    )

    for sub_name, sub_rs in rs.subsystems.items():
        sub_prefix = f"{full_prefix}.{sub_name}"
        sub_component = _collect_reaction_system(sub_name, sub_rs, sub_prefix)
        component.merge(sub_component)

    return component


# ============================================================================
# Coupling resolution
# ============================================================================


def _qualify_translate_endpoint(name: str, system: str) -> str:
    """Put one ``translate`` endpoint into the namespaced form the matcher uses.

    ``translate`` endpoints are authored in either form -- bare (``"O3"``) or
    fully namespaced (``"ChemistrySystem.O3"``) -- but matching runs against the
    NAMESPACED dependent variable of a flattened equation. An endpoint left bare
    can therefore never match, which is why a correctly spelled bare map was a
    silent no-op: the lookup missed, and the bare-name fallback then searched A
    for the wrong short name (B's spelling, not A's) and missed too.

    A bare endpoint is qualified with the system it belongs to, per §10.2's
    direction rule: a KEY belongs to ``systems[0]``, a VALUE to ``systems[1]``.
    An endpoint that already carries a dot is left ALONE -- it is either already
    namespaced or names a subsystem path, and re-prefixing it would break it.

    ``_var`` is exempt in both forms. It is a GLOBAL sentinel (esm-spec §6.4),
    never namespaced; a value of ``"B._var"`` is the redundant spelling §10.2
    requires to stay harmless, and it stays harmless here because placeholder
    expansion has already turned that equation into a DIRECT match, which takes
    precedence over this map.
    """
    if not name or name == PLACEHOLDER_VAR or name.endswith("." + PLACEHOLDER_VAR):
        return name
    if "." in name or not system:
        return name
    return f"{system}.{name}"


def _build_translate_map(
    entry: OperatorComposeCoupling,
) -> dict[str, tuple[str, float]]:
    """Normalize the operator_compose ``translate`` dict, INVERTED for matching.

    The authored direction is normative and is not symmetric (esm-spec §10.2,
    esm-libraries-spec §4.7.1 step 2): for ``"systems": [A, B]`` every KEY names
    a variable of ``A`` and every VALUE names a variable of ``B``.

    The matching loop in :func:`_apply_operator_compose` walks *B's* equations,
    so it needs the map the other way round. This returns the INVERSE:
    ``{b_name: (a_name, factor)}``. Indexing the authored (A-keyed) map by B's
    dependent variable is the bug this function exists to prevent -- it makes a
    correctly spelled ``translate`` map match nothing at all.

    Both endpoints are put into namespaced form first; see
    :func:`_qualify_translate_endpoint`.
    """
    out: dict[str, tuple[str, float]] = {}
    if not entry.translate:
        return out
    systems = list(entry.systems or [])
    a_sys = systems[0] if len(systems) > 0 else ""
    b_sys = systems[1] if len(systems) > 1 else ""
    for a_name, v in entry.translate.items():
        a_q = _qualify_translate_endpoint(a_name, a_sys)
        if isinstance(v, dict):
            b_name = v.get("to") or v.get("target") or v.get("var")
            factor = float(v.get("factor", 1.0))
            if b_name:
                out[_qualify_translate_endpoint(b_name, b_sys)] = (a_q, factor)
        elif isinstance(v, str):
            out[_qualify_translate_endpoint(v, b_sys)] = (a_q, 1.0)
    return out


def _apply_operator_compose(
    components: OrderedDict[str, _ComponentSystem],
    entry: OperatorComposeCoupling,
) -> None:
    """Merge B's equations into A by matching dependent variables.

    Per spec §4.7.1: for each B equation with LHS ``D(x, t)``, find A's
    equation with LHS ``D(x, t)`` (translation-aware) and sum their RHS into
    a single equation. Unmatched B equations are appended unchanged.
    """
    if not entry.systems or len(entry.systems) < 2:
        return
    a_name, b_name = entry.systems[0], entry.systems[1]
    if a_name not in components or b_name not in components:
        return
    a = components[a_name]
    b = components[b_name]

    translate = _build_translate_map(entry)

    # Index A's equations by namespaced dependent variable.
    a_index: dict[str, int] = {}
    for i, eq in enumerate(a.equations):
        dep = _lhs_dependent_var(eq.lhs)
        if dep is not None:
            a_index[dep] = i

    surviving_b: list[FlattenedEquation] = []
    # b_dep -> target_dep for every match that RENAMED the dependent variable.
    merged_away: dict[str, str] = {}

    for b_eq in b.equations:
        b_dep = _lhs_dependent_var(b_eq.lhs)
        if b_dep is None:
            surviving_b.append(b_eq)
            continue

        # Determine the A target for this dependent variable. Spec §4.7.1 step 3
        # lists the match kinds in precedence order: DIRECT first, then
        # TRANSLATION, then the bare-name fallback. Direct-first is load-bearing,
        # not cosmetic: placeholder expansion has already rewritten `_var` to A's
        # own variable name, so an expanded equation IS a direct match. Consulting
        # `translate` first would let a map keyed by A's names hit spuriously on
        # that rewritten name and redirect the match to a target that does not
        # exist -- turning a working composition into an over-determination error
        # (the `translate: {"A.x": "B._var"}` redundancy invariant, §10.2).
        target_dep = b_dep
        factor = 1.0
        if b_dep in a_index:
            pass  # direct match; `target_dep` is already right
        elif b_dep in translate:
            target_dep, factor = translate[b_dep]
        else:
            # Try mapping bare names from B back to A's equivalent.
            short = b_dep.split(".", 1)[1] if "." in b_dep else b_dep
            for ad in a_index:
                if ad.endswith("." + short):
                    target_dep = ad
                    break

        if target_dep in a_index:
            i = a_index[target_dep]
            a_eq = a.equations[i]
            substituted_rhs = substitute(b_eq.rhs, {b_dep: target_dep})
            if factor != 1.0:
                substituted_rhs = ExprNode(op="*", args=[factor, substituted_rhs])
            new_rhs = _add_exprs(a_eq.rhs, substituted_rhs)
            a.equations[i] = FlattenedEquation(
                lhs=a_eq.lhs,
                rhs=new_rhs,
                source_system=a_eq.source_system,
            )
            if target_dep != b_dep:
                merged_away[b_dep] = target_dep
        else:
            surviving_b.append(b_eq)

    b.equations = surviving_b

    # A renaming match CONSUMES B's defining equation, so B's declaration of that
    # name is left with nothing to constrain it -- an algebraic unknown with no
    # equation, which is exactly the structurally singular system step 4 exists
    # to prevent. §10.2 says the pair names ONE quantity, so the name does not
    # survive the merge: every remaining reference to it is retargeted at A's
    # spelling and the stranded declaration is dropped.
    #
    # The retarget is document-wide, not B-local: a third system is free to
    # reference `B.x` by its scoped name, and pruning the declaration while
    # leaving that reference dangling would trade one broken system for another.
    if merged_away:
        _retarget_merged_names(components, merged_away)
        for gone in merged_away:
            b.state_vars.pop(gone, None)
            b.observed.pop(gone, None)


def _retarget_merged_names(
    components: OrderedDict[str, _ComponentSystem],
    renames: dict[str, str],
) -> None:
    """Rewrite every reference to a merged-away dependent variable, everywhere.

    Applied after an ``operator_compose`` translation match folds ``B.x`` into
    ``A.y``: the two spellings named one quantity, only ``A.y`` still exists, so
    every equation side in the whole document is rewritten off the dead name.
    An observed variable's defining expression is one of those equations (it is
    not carried on :class:`FlattenedVariable`), so this covers it too.
    """
    for comp in components.values():
        for i, eq in enumerate(comp.equations):
            comp.equations[i] = FlattenedEquation(
                lhs=substitute(eq.lhs, renames),
                rhs=substitute(eq.rhs, renames),
                source_system=eq.source_system,
            )


def _add_exprs(left: Expr, right: Expr) -> Expr:
    """Sum two expressions, normalizing trivial cases."""
    if _is_number(left) and left == 0:
        return right
    if _is_number(right) and right == 0:
        return left
    return ExprNode(op="+", args=[left, right])


def _multiply_exprs(left: Expr, right: Expr) -> Expr:
    if _is_number(left) and left == 1:
        return right
    if _is_number(right) and right == 1:
        return left
    if (_is_number(left) and left == 0) or (_is_number(right) and right == 0):
        return 0
    return ExprNode(op="*", args=[left, right])


def _apply_couple(
    components: OrderedDict[str, _ComponentSystem],
    entry: CouplingCouple,
) -> None:
    """Resolve a ``couple`` connector by injecting source/sink terms.

    Each connector equation maps ``from_var`` (already a scoped reference like
    ``A.x``) to ``to_var`` with one of three transforms (``additive``,
    ``multiplicative``, ``replacement``). The expression is appended to (or
    multiplied with, or replaces) the target variable's equation.
    """
    if not entry.connector or not entry.connector.equations:
        return

    # Build a global index of equations for fast LHS lookup.
    eq_index: dict[str, tuple[str, int]] = {}
    for sys_name, comp in components.items():
        for i, eq in enumerate(comp.equations):
            dep = _lhs_dependent_var(eq.lhs)
            if dep is not None:
                eq_index[dep] = (sys_name, i)

    # Which targets carry a TENDENCY (`D(x)`), as opposed to merely some defining
    # equation: `multiplicative` is defined against an ODE RHS (§10.3, §4.7.2).
    tendencies: set[str] = set()
    for comp in components.values():
        for eq in comp.equations:
            if isinstance(eq.lhs, ExprNode) and eq.lhs.op == "D":
                dep = _lhs_dependent_var(eq.lhs)
                if dep is not None:
                    tendencies.add(dep)

    for ceq in entry.connector.equations:
        target = ceq.to_var
        if not target:
            continue
        if ceq.transform == "multiplicative" and target not in tendencies:
            raise CoupleMultiplicativeNoTendencyError(
                f"couple connector 'multiplicative' transform targets {target!r}, "
                f"which has no tendency (D({target})) to multiply (esm-spec §10.3). "
                f"To scale a constant parameter by a factor, use a variable_map "
                f"entry with an Expression transform (esm-spec §10.4) instead."
            )
        if target not in eq_index:
            continue
        sys_name, i = eq_index[target]
        comp = components[sys_name]
        existing = comp.equations[i]
        expression: Expr = ceq.expression if ceq.expression is not None else ceq.from_var

        if ceq.transform == "additive":
            new_rhs = _add_exprs(existing.rhs, expression)
        elif ceq.transform == "multiplicative":
            new_rhs = _multiply_exprs(existing.rhs, expression)
        elif ceq.transform == "replacement":
            new_rhs = expression
        else:
            new_rhs = _add_exprs(existing.rhs, expression)

        comp.equations[i] = FlattenedEquation(
            lhs=existing.lhs,
            rhs=new_rhs,
            source_system=existing.source_system,
        )


def _contains_join(expr: Expr) -> bool:
    """True iff any node in ``expr`` carries a non-empty ``join``."""
    if not isinstance(expr, ExprNode):
        return False
    if getattr(expr, "join", None):
        return True
    return any_child(expr, _contains_join)


def _rename_join_names(expr: Expr, to_var: str, from_var: str) -> Expr:
    """Rename ``to_var`` -> ``from_var`` in every plain-string ``join`` name.

    The join-side companion of the ``variable_map`` substitution
    (CONFORMANCE_SPEC §5.5.6). ``substitute`` walks expression CHILDREN, so it
    cannot see an ``on`` key column or an ``overlap``'s ``src_env`` /
    ``tgt_env`` — but those are references in the same namespaced scope as
    everything else. A ``param_to_var`` / ``conversion_factor`` map REMOVES
    ``to_var`` from the flattened parameter list, so a join still naming it
    points at a variable the system no longer declares and materialisation dies
    with ``join references unknown variable``. Mirrors Julia
    ``coupling_apply.jl::_rename_join_names`` and Rust
    ``flatten.rs::rename_join_names``.
    """
    # Scan BEFORE the rebuild: ``map_children`` copies, and this runs over every
    # equation of every component for every ``variable_map`` entry. Almost no
    # model carries a join, and those must not pay a whole-tree copy on top of
    # the substitution's. The scan is once per tree, not per node — the
    # recursion below is the unguarded ``_rename_join_names_in``.
    if not isinstance(expr, ExprNode) or not _contains_join(expr):
        return expr
    return _rename_join_names_in(expr, to_var, from_var)


def _rename_join_names_in(expr: Expr, to_var: str, from_var: str) -> Expr:
    """The unguarded recursion behind :func:`_rename_join_names`."""
    if not isinstance(expr, ExprNode):
        return expr

    def ren(name: Any) -> Any:
        return from_var if name == to_var else name

    out = map_children(expr, lambda c: _rename_join_names_in(c, to_var, from_var))
    if not getattr(expr, "join", None):
        return out
    clauses: list[dict[str, Any]] = []
    for clause in expr.join:
        if not isinstance(clause, dict):
            clauses.append(clause)
            continue
        new = dict(clause)
        if isinstance(clause.get("on"), list):
            new["on"] = [
                [ren(c) for c in pair] if isinstance(pair, list) else pair for pair in clause["on"]
            ]
        ov = clause.get("overlap")
        if isinstance(ov, dict):
            new_ov = dict(ov)
            for side in ("src_env", "tgt_env"):
                if isinstance(ov.get(side), list):
                    new_ov[side] = [ren(f) for f in ov[side]]
            new["overlap"] = new_ov
        clauses.append(new)
    return replace(out, join=clauses)


def _apply_variable_map(
    components: OrderedDict[str, _ComponentSystem],
    entry: VariableMapCoupling,
    loader_names: set[str] | None = None,
) -> None:
    """Substitute the target parameter with the source variable.

    For ``param_to_var``, ``conversion_factor``, and the empty/absent transform,
    the target parameter is *promoted* — removed from the parameter list (it
    becomes a shared variable). For the remaining transforms (``identity``,
    ``additive``, ``multiplicative``) the target is left in the parameter list;
    we still substitute so the equation set references the canonical name.

    ``loader_names`` is the set of top-level ``data_sources`` keys. When a
    ``param_to_var`` binds a LOADED field (``from_var``'s owning system is a data
    loader) onto a GRID-SHAPED consumer parameter (``to_var`` carries a non-scalar
    ``shape``), the shape is transferred to the loader-qualified ``from_var`` name
    (added as a shaped parameter) so the downstream pointwise lift (esm-spec §10.5)
    recognizes it as an array operand to index per grid cell. Without this,
    deleting the shaped ``to_var`` would strip the field's grid shape and the lift
    would leave a bare (scalar) loader reference — e.g. ``-Meteorology.u_wind *
    grad(...)`` would not lift to ``-index(Meteorology.u_wind, i, j) * …``.
    (esm-spec §11.5 "BCs from data" + §10.4 ``param_to_var``.)
    """
    if not entry.from_var or not entry.to_var:
        return
    if isinstance(entry.transform, ExprNode):
        _apply_variable_map_expression(components, entry)
        return
    loader_names = loader_names or set()
    factor = entry.factor or 1.0
    src: Expr = entry.from_var
    if factor != 1.0:
        src = ExprNode(op="*", args=[factor, entry.from_var])

    bindings = {entry.to_var: src}
    for comp in components.values():
        new_eqs: list[FlattenedEquation] = []
        for eq in comp.equations:
            new_eqs.append(
                FlattenedEquation(
                    lhs=substitute(eq.lhs, bindings),
                    rhs=_rename_join_names(
                        substitute(eq.rhs, bindings), entry.to_var, entry.from_var
                    ),
                    source_system=eq.source_system,
                )
            )
        comp.equations = new_eqs

    # Guard the string comparison: an ExprNode transform never reaches here
    # (handled by _apply_variable_map_expression above), but keep the promotion
    # logic crash-safe against non-string transforms regardless.
    transform = entry.transform.lower() if isinstance(entry.transform, str) else ""
    promoted = transform in ("param_to_var", "conversion_factor", "")
    if promoted:
        for comp in components.values():
            to_var = comp.parameters.pop(entry.to_var, None)
            if to_var is None:
                continue
            # Carry a grid shape from the (deleted) consumer parameter onto the
            # loader-qualified producer name so the pointwise lift indexes the
            # loaded field per cell. Only when ``from_var`` is a data-loader
            # variable (guards against binding a model STATE) and the producer is
            # not already a known variable.
            from_owner = entry.from_var.split(".", 1)[0]
            if (
                to_var.shape
                and from_owner in loader_names
                and entry.from_var not in comp.parameters
            ):
                comp.parameters[entry.from_var] = FlattenedVariable(
                    name=entry.from_var,
                    type="parameter",
                    units=to_var.units,
                    description=to_var.description,
                    source_system=from_owner,
                    shape=list(to_var.shape),
                )


def _expr_references_var(expr: Expr, name: str) -> bool:
    """True iff ``name`` occurs as a string leaf in any variable-reference
    position of ``expr``.

    Recursively walks every Expression-valued slot of the AST — ``args``,
    integral bounds (``lower``/``upper``), aggregate body/``filter``/``key``,
    ``makearray`` values, and ``table_lookup`` per-axis inputs (the canonical
    :mod:`.expr_walk` child set). ``ranges`` (integer index-range / index-set
    specs) are NOT variable references and are excluded, as are scalar
    metadata fields (``wrt``, ``dim``, ``fn``, …).
    """
    if isinstance(expr, str):
        return expr == name
    if isinstance(expr, ExprNode):
        return any_child(expr, lambda c: _expr_references_var(c, name))
    return False


def _apply_variable_map_expression(
    components: OrderedDict[str, _ComponentSystem],
    entry: VariableMapCoupling,
) -> None:
    """Resolve a ``variable_map`` whose ``transform`` is an Expression
    (in-progress-0.8.0 widening, esm-spec §10.4/§10.5).

    The expression transform behaves like ``param_to_var`` for promotion — the
    target parameter ``to_var`` is removed from the flattened parameters — but
    references to ``to_var`` in consumer equations are NOT substituted. Instead
    the target becomes an OBSERVED variable named exactly ``to_var`` whose
    defining equation is the transform expression VERBATIM: by contract every
    variable reference inside an expression transform is already a fully-scoped
    reference, so no namespacing is applied. The net effect is structurally
    identical to the author declaring the target as an observed with that
    expression. ``factor`` never combines with an expression transform (parse
    rejects the pairing).
    """
    if not _expr_references_var(entry.transform, entry.from_var):
        raise FlattenError(
            f"variable_map expression transform mapping '{entry.from_var}' -> "
            f"'{entry.to_var}' does not reference its source variable "
            f"'{entry.from_var}'"
        )

    # Same removal/promotion mechanics as param_to_var: pop the target
    # parameter wherever it is declared; the (first) owning component receives
    # the observed. If no component declared it (variable_map may introduce a
    # new target var), fall back to the receiving component named by the
    # target's scope prefix.
    target_comp: _ComponentSystem | None = None
    removed: FlattenedVariable | None = None
    for comp in components.values():
        popped = comp.parameters.pop(entry.to_var, None)
        if popped is not None and removed is None:
            removed = popped
            target_comp = comp
    if target_comp is None:
        target_comp = components.get(entry.to_var.split(".", 1)[0])
    if target_comp is None:
        return

    # Carry the removed parameter's units/shape/description metadata onto the
    # observed; its value is computed, so no default is carried.
    target_comp.observed[entry.to_var] = FlattenedVariable(
        name=entry.to_var,
        type="observed",
        units=removed.units if removed else None,
        description=removed.description if removed else None,
        source_system=removed.source_system if removed else target_comp.name,
        shape=list(removed.shape) if removed and removed.shape else None,
    )
    target_comp.equations.append(
        FlattenedEquation(
            lhs=entry.to_var,
            rhs=entry.transform,
            source_system=target_comp.name,
        )
    )


# ============================================================================
# Event namespacing
# ============================================================================


def _namespace_event_affects(affects: list, system_var_names: dict[str, str]) -> list:
    """Rewrite AffectEquation.lhs/rhs to dot-namespaced form when possible."""
    out = []
    for affect in affects:
        if isinstance(affect, AffectEquation):
            ns_lhs = system_var_names.get(affect.lhs, affect.lhs)
            ns_rhs = affect.rhs
            if isinstance(ns_rhs, str):
                ns_rhs = system_var_names.get(ns_rhs, ns_rhs)
            elif isinstance(ns_rhs, ExprNode):
                ns_rhs = substitute(ns_rhs, system_var_names)
            out.append(AffectEquation(lhs=ns_lhs, rhs=ns_rhs))
        else:
            out.append(affect)
    return out


# ============================================================================
# Public API
# ============================================================================


def _collect_components(
    esm_file: EsmFile,
) -> tuple[OrderedDict[str, _ComponentSystem], list[str]]:
    """Collect every component system into a per-system bag of variables and
    (already-namespaced) equations.

    Returns the components map (keyed by source-system name, insertion-ordered)
    and the parallel list of source-system names.
    """
    components: OrderedDict[str, _ComponentSystem] = OrderedDict()
    source_systems: list[str] = []
    # The document-scoped ingest registry (esm-spec §8), threaded down so a
    # data-fed parameter's `update.source` resolves and its cadence follows the
    # SOURCE's `temporal` block.
    doc_data_sources = getattr(esm_file, "data_sources", None) or {}
    for name, model in esm_file.models.items():
        components[name] = _collect_model(name, model, data_sources=doc_data_sources)
        source_systems.append(name)
    for name, rs in esm_file.reaction_systems.items():
        components[name] = _collect_reaction_system(name, rs)
        source_systems.append(name)
    return components, source_systems


def _apply_couplings(
    esm_file: EsmFile,
    components: OrderedDict[str, _ComponentSystem],
    metadata: FlattenMetadata,
    coupling_entries: list[CouplingEntry],
) -> None:
    """Apply the file's coupling entries to ``components`` in place.

    ``coupling_entries`` is the effective coupling list AFTER ``coupling_import``
    expansion (esm-spec §10.10.3) — walked in array order. ``operator_compose``
    runs first so its placeholder-expansion / merge happens before any
    ``variable_map`` substitution rewrites the dependent variable names out from
    under us. Provenance (operator applies, callbacks, coupling-rule
    descriptions) is recorded into ``metadata``.
    """
    operator_compose_entries: list[OperatorComposeCoupling] = []
    couple_entries: list[CouplingCouple] = []
    var_map_entries: list[VariableMapCoupling] = []
    for entry in coupling_entries:
        if isinstance(entry, OperatorComposeCoupling):
            operator_compose_entries.append(entry)
        elif isinstance(entry, CouplingCouple):
            couple_entries.append(entry)
        elif isinstance(entry, VariableMapCoupling):
            var_map_entries.append(entry)
        elif isinstance(entry, OperatorApplyCoupling):
            metadata.operator_applies.append(entry.operator or "?")
        elif isinstance(entry, CallbackCoupling):
            metadata.callbacks.append(entry.callback_id or "?")
        metadata.coupling_rules.append(_describe_coupling(entry))

    for oc in operator_compose_entries:
        _expand_operator_compose_placeholders(components, oc)
        _apply_operator_compose(components, oc)

    for cp in couple_entries:
        _apply_couple(components, cp)

    # Top-level data-source names — used to recognize a ``param_to_var`` whose
    # producer is a source-fed field, so a grid-shaped binding keeps its shape.
    loader_names: set[str] = set(getattr(esm_file, "data_sources", None) or {})
    for vm in var_map_entries:
        _apply_variable_map(components, vm, loader_names)


def _assemble_system(
    esm_file: EsmFile,
    components: OrderedDict[str, _ComponentSystem],
    metadata: FlattenMetadata,
) -> FlattenedSystem:
    """Assemble the final FlattenedSystem from the per-component pieces."""
    flat = FlattenedSystem(metadata=metadata)
    # Thread the document-scoped index-set registry (RFC §5.2) so the evaluator
    # can resolve {"from": <name>} range references at simulation time. As of
    # v0.8.0 the registry is a single top-level field on the document, shared by
    # every model, rather than a per-Model field.
    doc_index_sets = getattr(esm_file, "index_sets", None)
    if doc_index_sets:
        flat.index_sets.update(doc_index_sets)
    # The document-scoped `function_tables` registry (esm-spec §9.5) travels with
    # the flattened form for the same reason `index_sets` does: a surviving
    # `table_lookup` node names a table id, and a consumer handed only the
    # FlattenedSystem has nowhere else to resolve it (§4.7.5 step 4).
    doc_function_tables = getattr(esm_file, "function_tables", None)
    if doc_function_tables:
        flat.function_tables.update(doc_function_tables)
    # Fold every component into one bag via the shared merge (same last-writer /
    # order-preserving semantics as the previous per-field loops), then copy its
    # variable tables into the FlattenedSystem's (differently named) fields.
    combined = _ComponentSystem(name="")
    for comp in components.values():
        combined.merge(comp)
    for name, var in combined.state_vars.items():
        flat.state_variables[name] = var
    for name, var in combined.parameters.items():
        flat.parameters[name] = var
    for name, var in combined.observed.items():
        flat.observed_variables[name] = var
    flat.loader_fields.extend(combined.loader_fields)

    seen_lhs: dict[str, FlattenedEquation] = {}
    for eq in combined.equations:
        dep = _lhs_dependent_var(eq.lhs)
        # Equations that use array ops may legitimately define different
        # index subsets of the same state variable (stencil interior + BCs,
        # block-assembled makearray, etc.). Skip the scalar-only dedup check
        # in that case — the array simulation path resolves per-element.
        is_array_eq = _has_array_op(eq.lhs) or _has_array_op(eq.rhs)
        if dep is not None and not is_array_eq:
            if dep in seen_lhs:
                existing = seen_lhs[dep]
                if _expr_to_string(existing.rhs) != _expr_to_string(eq.rhs):
                    # A single source system that authored two equations
                    # with the same scalar LHS expressed an algebraic
                    # constraint on purpose — e.g. an equilibrium model
                    # where K = f(T) AND K = [H+][OH-]. The second equation
                    # constrains a different unknown on its RHS. Pass it
                    # through; structural simplification in the simulation
                    # tier resolves which variable each equation defines.
                    # Cross-system conflicts (typically introduced by
                    # variable_map coupling that unifies two state vars
                    # without operator_compose merging) remain errors.
                    if existing.source_system != eq.source_system and not (
                        _has_array_op(existing.lhs) or _has_array_op(existing.rhs)
                    ):
                        raise ConflictingDerivativeError(
                            f"Two systems define non-additive equations for "
                            f"variable {dep!r}: "
                            f"{existing.source_system} vs {eq.source_system}"
                        )
                else:
                    continue
            seen_lhs[dep] = eq
        flat.equations.append(eq)
    return flat


def _namespace_events(esm_file: EsmFile, flat: FlattenedSystem) -> None:
    """Collect the file's events into ``flat``, dot-namespacing variable
    references where they unambiguously match a known state variable/parameter.

    We just collect them — namespacing per-system is hard because the file's
    events list isn't tagged with a source system. We rewrite affect-equation
    LHS names where they unambiguously match a known state variable.
    """
    var_to_namespaced: dict[str, str] = {}
    for name in list(flat.state_variables) + list(flat.parameters):
        bare = name.rsplit(".", 1)[-1]
        var_to_namespaced.setdefault(bare, name)

    for event in esm_file.events:
        if isinstance(event, ContinuousEvent):
            new_conditions = [substitute(c, var_to_namespaced) for c in event.conditions]
            new_affects = _namespace_event_affects(event.affects, var_to_namespaced)
            new_affect_neg = (
                _namespace_event_affects(event.affect_neg, var_to_namespaced)
                if event.affect_neg is not None
                else None
            )
            flat.continuous_events.append(
                ContinuousEvent(
                    name=event.name,
                    conditions=new_conditions,
                    affects=new_affects,
                    affect_neg=new_affect_neg,
                    root_find=event.root_find,
                    reinitialize=event.reinitialize,
                    priority=event.priority,
                    description=event.description,
                )
            )
        elif isinstance(event, DiscreteEvent):
            new_affects = _namespace_event_affects(event.affects, var_to_namespaced)
            flat.discrete_events.append(
                DiscreteEvent(
                    name=event.name,
                    trigger=event.trigger,
                    affects=new_affects,
                    priority=event.priority,
                )
            )


def _apply_domain(esm_file: EsmFile, flat: FlattenedSystem) -> None:
    """Pass the file's ``domain`` section through unchanged.

    The Python tier does not currently apply dimension-promotion rules from
    §4.7.6 — only the spatial-rejection check in esm_problem() distinguishes
    discretized systems (time-only) from an undiscretized spatial operator that
    survived into the flattened system.
    """
    if esm_file.domain is not None:
        # Single shared domain (v0.8.0): pass it through unchanged.
        flat.domain = esm_file.domain


def _derive_independent_vars(flat: FlattenedSystem) -> None:
    """Derive independent variables from the equation set.

    Time is always present; a spatial dimension is added when an UNDISCRETIZED
    spatial differential still names it. That signal is derived STRUCTURALLY from
    the ``dim`` axis field carried by such a node (esm-spec §4.9.1) — never from a
    hardcoded op-name list — so no sugar op is privileged over a custom
    rewrite-target op. A discretized (array) system carries no such ``dim`` node
    and correctly stays a pure ODE (``independent_variables == ["t"]``).
    """
    independent: list[str] = ["t"]
    for eq in flat.equations:
        for dim in (*_spatial_dims_in_expr(eq.lhs), *_spatial_dims_in_expr(eq.rhs)):
            if dim not in independent:
                independent.append(dim)
    flat.independent_variables = independent


# ============================================================================
# The canonical §4.7.5-step-4 fields derived from the assembled system
# ============================================================================


def _classification_var(var: FlattenedVariable, declared: str) -> dict[str, Any]:
    """One flattened variable as the two-type DECLARED view esm-spec §6.3.1's
    classification functions read.

    ``FlattenedVariable.type`` is already a DERIVED role ("state" / "observed" /
    "species" / "parameter"), and §6.3.1 is explicit that reading a derived role
    to answer a derived question is exactly what 1.0.0 removes. So the view hands
    the classifier the two declared types and the raw ``update`` /
    ``distribution`` metadata, and lets it derive everything else from the
    flattened equations — the same code path, and therefore the same answers, as
    the per-model accessors.
    """
    return {
        "type": declared,
        "units": var.units,
        "default": var.default,
        "shape": var.shape,
        "update": var.update,
        "distribution": var.distribution,
    }


def _classification_view(flat: FlattenedSystem) -> dict[str, Any]:
    """A model-shaped view of ``flat`` that :mod:`.classification` accepts.

    Classification is re-run over the FLATTENED system rather than per component
    because flattening moves the ground under it: ``operator_compose`` merges two
    RHSs into one equation, ``variable_map`` deletes a parameter and promotes a
    variable in its place, and the pointwise lift rewrites a scalar state ODE
    into an ``aggregate``. A per-component answer namespaced after the fact would
    describe the document, not the system that was produced from it.
    """
    variables: dict[str, Any] = {}
    for name, var in flat.state_variables.items():
        variables[name] = _classification_var(var, "unknown")
    for name, var in flat.observed_variables.items():
        variables.setdefault(name, _classification_var(var, "unknown"))
    for name, var in flat.parameters.items():
        variables.setdefault(name, _classification_var(var, "parameter"))
    return {"variables": variables, "equations": flat.equations}


def _in_document_order(
    names: set[str], *maps: OrderedDict[str, FlattenedVariable]
) -> OrderedDict[str, FlattenedVariable]:
    """Select ``names`` out of ``maps``, keeping each map's insertion order.

    The classification accessors return SORTED name lists — a set-valued answer
    spelled as a list. esm-libraries-spec §4.7.5 step 4 requires DOCUMENT order
    of every map on the FlattenedSystem, so membership comes from the accessor
    and position comes from the already-document-ordered map being filtered.
    Sorting here instead would be observable: a parameter vector is positional.
    """
    out: OrderedDict[str, FlattenedVariable] = OrderedDict()
    for m in maps:
        for name, var in m.items():
            if name in names and name not in out:
                out[name] = var
    return out


def _classify_flattened(flat: FlattenedSystem) -> None:
    """Fill the §6.3.1 SUBSET maps — `algebraic_variables`,
    `brownian_parameters`, `discrete_parameters` — on ``flat``.

    Delegates every membership decision to :mod:`.classification`, the binding's
    only sanctioned answer to these questions (esm-spec §6.3.1), and does nothing
    here but re-impose document order. In particular there is no local
    ``update.kind == "wiener"`` test: one derivation serving flatten, validation
    and the conformance corpus is the whole point of that module.

    Each map is a SUBSET of the map it classifies and the classified map keeps
    every member: `brownian_parameters` ⊆ `parameters`, `discrete_parameters` ⊆
    `parameters`, `algebraic_variables` ⊆ `state_variables`.
    """
    from .classification import algebraic_unknowns, brownian_parameters, discrete_parameters

    view = _classification_view(flat)
    flat.algebraic_variables = _in_document_order(
        set(algebraic_unknowns(view)), flat.state_variables, flat.observed_variables
    )
    flat.brownian_parameters = _in_document_order(set(brownian_parameters(view)), flat.parameters)
    flat.discrete_parameters = _in_document_order(set(discrete_parameters(view)), flat.parameters)


def _collect_field_ics(flat: FlattenedSystem) -> None:
    """Record the deferred ``ic`` equations (esm-spec §11.4.1) as ordered
    ``(target_state, rhs)`` pairs on ``flat.field_ics``.

    An ``ic`` equation pins a state's value at t=0 — a loaded initial field, or a
    broadcast constant — rather than defining its dynamics, so a consumer folds
    it into ``u0`` instead of the RHS. Mirrors Rust's ``extract_ic_target``: the
    LHS must be ``ic(<bare variable>)`` with exactly one argument.

    The matched equations are CLASSIFIED OUT of ``flat.equations`` and reported
    only here (esm-libraries-spec §4.7.5 step 4). An initial condition is a
    datum, not an equation of motion: leaving it in ``equations`` makes that list
    unusable for building a right-hand side without first filtering it, and makes
    equation counts incomparable across bindings. Consumers that need the initial
    values — the array and scalar simulators' ``u0`` folding — read ``field_ics``.

    Runs LAST, after the pointwise lift and the independent-variable derivation,
    so every intermediate pass still sees the same equation list it always did
    and only the FINAL, observable ``equations`` differs.
    """
    ics: list[tuple[str, Expr]] = []
    remaining: list[FlattenedEquation] = []
    for eq in flat.equations:
        lhs = eq.lhs
        target = (
            lhs.args[0]
            if isinstance(lhs, ExprNode) and lhs.op == "ic" and len(lhs.args) == 1
            else None
        )
        if isinstance(target, str):
            ics.append((target, eq.rhs))
        else:
            remaining.append(eq)
    flat.field_ics = ics
    flat.equations = remaining


def _scope_template_body(
    expr: Expr, prefix: str, local_names: set[str], bound: frozenset[str] = frozenset()
) -> Expr:
    """Component-scope one carried template body: prefix exactly the references
    that name one of the OWNING component's locals.

    This is the "post-step-2 scoping" esm-libraries-spec §4.7.5 step 4 calls an
    ordering requirement rather than a parenthetical. A body's FREE variables are
    resolved in its owner's scope, so two components importing one library carry
    byte-identical bodies whose free ``inv_dx`` denotes a DIFFERENT variable in
    each; deduplicating them pre-scoping keeps one body that is correct for
    neither. Scoping also makes them non-deep-equal, which is what routes them
    into the collision rename and keeps an entry per component.

    Unlike :func:`_namespace_expr` (which prefixes every bare reference except an
    explicit leave-alone set) this is a WHITELIST, matching Julia's
    ``namespace_expr(body, cname, local_names)``: a body legitimately references
    its own formal ``params``, loop symbols, and document-scoped index sets, none
    of which are component locals and none of which may be prefixed. The caller
    removes the template's ``params`` from ``local_names`` before calling.
    """
    if expr is None or _is_number(expr):
        return expr
    if isinstance(expr, str):
        if expr in bound:
            return expr
        if "." in expr:
            head = expr.split(".", 1)[0]
            return f"{prefix}.{expr}" if head in local_names else expr
        return f"{prefix}.{expr}" if expr in local_names else expr
    if isinstance(expr, ExprNode):
        local_bound = set(bound)
        if expr.op == "aggregate":
            for sym in expr.output_idx or ():
                if isinstance(sym, str):
                    local_bound.add(sym)
            for sym in (expr.ranges or {}).keys():
                local_bound.add(sym)
        frozen = frozenset(local_bound)
        out = map_children(expr, lambda c: _scope_template_body(c, prefix, local_names, frozen))
        if getattr(expr, "join", None):
            binders = set(expr.output_idx or ()) | set((expr.ranges or {}).keys())
            out = replace(out, join=_namespace_join(expr.join, binders, prefix, local_names))
        return out
    return expr


def _merged_template_registry(esm_file: EsmFile) -> dict[str, Any]:
    """The MERGED expression-template registry of the flattened representation
    (esm-spec §9.6.4 rule 7, §10.7; esm-libraries-spec §4.7.5 step 4).

    Union of the per-component registries, in this order:

    1. **Scope, then union.** Each MODEL block's bodies are component-scoped
       first (:func:`_scope_template_body`), because the dedup below compares
       post-scoping bodies. Reaction-system blocks pass through unscoped BY
       POLICY, mirroring the Julia reference: a rate-law reference is expanded
       eagerly at collect, so a reaction-system entry is never resolved against
       the post-flatten scope — it rides along so the reconstituted document
       round-trips.
    2. **Deep-equal dedup at first occurrence** — two components importing one
       stencil keep one entry under the bare name.
    3. **Collision rename** — a same-name entry whose occurrences are not all
       deep-equal renames to ``<ComponentPath>.<name>`` in EVERY owning
       component, and the rename propagates along the reference DAG
       (:func:`~.lower_expression_templates._registry_collision_names`) so no
       surviving body holds a reference the merged registry cannot resolve.

    ``match`` rules are excluded: only match-less templates are referenceable
    (§9.6.2), so only they can be merged.

    Components are walked in DOCUMENT order (models in file order, then reaction
    systems), which is what step 4's ordering rule requires and what makes
    "first occurrence" mean the first occurrence in the file. The Julia reference
    sorts the component keys instead; the two agree whenever component names sort
    in declaration order, and where they disagree the spec's rule governs.

    Python's typed path expands every reference at load (esm-spec §9.6.4 rule 2),
    so no equation reaching here carries an ``apply_expression_template`` node
    and the rename has no component reference sites left to rewrite — step 4's
    "Applicability" paragraph says exactly this. The registry is still carried,
    because the field is normative and a consumer must be able to reconstitute
    the reference-preserving document from the flattened form.
    """
    from .lower_expression_templates import _registry_collision_names, _rename_apply_refs
    from .parse import _parse_expression
    from .serialize import _serialize_expression

    component_templates = getattr(esm_file, "component_templates", None) or {}
    if not component_templates:
        return {}

    # Document order: models as the file declares them, then reaction systems.
    ordered_keys = [f"models.{n}" for n in esm_file.models] + [
        f"reaction_systems.{n}" for n in esm_file.reaction_systems
    ]
    for key in component_templates:  # a component the typed file no longer holds
        if key not in ordered_keys:
            ordered_keys.append(key)

    # name -> [(component_path, declaration), ...] in document order.
    byname: dict[str, list[tuple[str, Any]]] = {}
    for compkey in ordered_keys:
        block = component_templates.get(compkey)
        if not isinstance(block, dict):
            continue
        section, _, cname = compkey.partition(".")
        model = esm_file.models.get(cname) if section == "models" else None
        local_names = set(model.variables) | set(model.subsystems) if model is not None else set()
        for tname, decl in block.items():
            if isinstance(decl, dict) and decl.get("match") is not None:
                continue  # match rules are not referenceable, so not merged
            scoped = decl
            body = decl.get("body") if isinstance(decl, dict) else None
            if model is not None and body is not None:
                params = {p for p in (decl.get("params") or []) if isinstance(p, str)}
                scoped = dict(decl)
                scoped["body"] = _serialize_expression(
                    _scope_template_body(_parse_expression(body), cname, local_names - params)
                )
            byname.setdefault(str(tname), []).append((cname, scoped))

    collide = _registry_collision_names(byname)
    merged: dict[str, Any] = {}
    rename: dict[str, dict[str, str]] = {}
    for name, occurrences in byname.items():
        if name in collide:
            for path, decl in occurrences:
                newname = f"{path}.{name}"
                merged[newname] = decl
                rename.setdefault(path, {})[name] = newname
        else:
            merged[name] = occurrences[0][1]
    # A renamed body's own nested references follow its owner's map, so a
    # per-owner wrapper reaches its owner's leaf and never the other owner's.
    for _path, per_owner in rename.items():
        for _old, new in per_owner.items():
            if new in merged:
                merged[new] = _rename_apply_refs(merged[new], per_owner)
    return merged


def flatten(esm_file: EsmFile, base_path: str = ".", load_ref=None) -> FlattenedSystem:
    """Flatten a coupled multi-system EsmFile per spec §4.7.5.

    The result is the canonical intermediate representation: dot-namespaced
    variables, equations as Expr trees, coupling rules resolved into the
    equation set, and metadata recording what happened.

    ``base_path`` / ``load_ref`` are only consulted when the file carries a
    ``coupling_import`` coupling entry (esm-spec §10.10): each such entry loads
    the referenced coupling-library file (via ``load_ref(ref, base_path)``,
    defaulting to a disk reader relative to ``base_path``) and expands into
    concrete edges spliced in its position, before the coupling-rule step.

    Raises
    ------
    ValueError
        If the file has no models, no reaction systems, and nothing to flatten.
    ConflictingDerivativeError
        If two source systems define non-additive equations for the same
        dependent variable.
    DomainUnitMismatchError
        If an ``identity``-transform ``variable_map`` bridges two variables whose
        declared, non-empty units differ (spec §4.7.6).
    ExpressionTemplateError
        For any esm-spec §10.11 coupling-import / coupling-library diagnostic.
    """
    if not esm_file.models and not esm_file.reaction_systems:
        raise ValueError("Cannot flatten an EsmFile with no models or reaction systems")

    # Expand `coupling_import` entries (esm-spec §10.10.3) into concrete edges
    # BEFORE any coupling processing. A file with no coupling_import entries
    # yields its `coupling` list verbatim and needs no options.
    from .coupling_imports import expand_coupling_imports

    coupling_entries = expand_coupling_imports(esm_file, base_path=base_path, load_ref=load_ref)

    # Step 0b: coupling preflight — reject an `identity` variable_map that bridges
    # two variables with declared, non-empty, different units (spec §4.7.6). Runs
    # over the expanded coupling list so imported edges are checked too.
    _check_variable_map_units(esm_file, coupling_entries)

    # Step 1: collect every component system into a per-system bag of variables.
    components, source_systems = _collect_components(esm_file)
    metadata = FlattenMetadata(source_systems=list(source_systems))

    # Step 2: resolve coupling entries into the per-component equation sets. The
    # expanded coupling list (post coupling_import) drives the coupling walk.
    _apply_couplings(esm_file, components, metadata, coupling_entries)

    # Step 3: assemble the final FlattenedSystem from the per-component pieces.
    flat = _assemble_system(esm_file, components, metadata)

    # Step 4: collect and namespace events.
    _namespace_events(esm_file, flat)

    # Step 4b: pointwise spatial lift (esm-spec §10.5) over the expanded couplings.
    _apply_pointwise_lift(flat, coupling_entries)

    # Step 5: domain pass-through.
    _apply_domain(esm_file, flat)

    # Step 6: derive independent variables from the equation set.
    _derive_independent_vars(flat)

    # Step 7: the remaining canonical §4.7.5-step-4 fields. All three run LAST,
    # over the finished system, so they see the equations coupling and the
    # pointwise lift actually produced rather than the ones the document
    # declared.
    #
    # The §6.3.1 subsets (`algebraic_variables`, `brownian_parameters`,
    # `discrete_parameters`), re-derived through `classification`.
    _classify_flattened(flat)
    # The deferred `ic` equations (esm-spec §11.4.1) as (state, expr) pairs.
    _collect_field_ics(flat)
    # The merged expression-template registry (esm-spec §9.6.4 rule 7, §10.7).
    flat.template_registry = _merged_template_registry(esm_file)

    return flat


def _expand_operator_compose_placeholders(
    components: OrderedDict[str, _ComponentSystem],
    entry: OperatorComposeCoupling,
) -> None:
    """Expand ``_var`` placeholders in B's equations against A's state variables.

    Spec §4.7.1 placeholder expansion: an equation like ``D(_var, t) =
    -u·grad(_var, x)`` in system B is cloned once per state variable in system
    A, with ``_var`` substituted for the actual (namespaced) variable name.
    """
    if not entry.systems or len(entry.systems) < 2:
        return
    a_name, b_name = entry.systems[0], entry.systems[1]
    if a_name not in components or b_name not in components:
        return
    a = components[a_name]
    b = components[b_name]

    a_state_names = list(a.state_vars.keys())
    if not a_state_names:
        return

    new_equations: list[FlattenedEquation] = []
    for eq in b.equations:
        if has_var_placeholder(eq.lhs) or has_var_placeholder(eq.rhs):
            for var_name in a_state_names:
                bindings = {"_var": var_name}
                new_equations.append(
                    FlattenedEquation(
                        lhs=substitute(eq.lhs, bindings),
                        rhs=substitute(eq.rhs, bindings),
                        source_system=eq.source_system,
                    )
                )
        else:
            new_equations.append(eq)
    b.equations = new_equations


# ============================================================================
# Pointwise spatial lift (esm-spec §10.5)
# ============================================================================
#
# Reaction ODE-gen and coupling both run at the AST level and IN THAT ORDER
# (reactions -> generic ``D(sp)=Σ terms``; then ``operator_compose`` merges each
# species' reaction ODE with the spatial operator's advection makearray). What
# operator_compose does NOT do is array-ify the result: the merged
# ``D(sp) = <reaction> + <-u·makearray(grad(sp))>`` still has a SCALAR ``sp``
# while its advection makearray indexes ``sp`` per grid cell. This pass performs
# the ``lifting:"pointwise"`` promotion — wrapping each merged state ODE in an
# ``aggregate`` over the grid, indexing the bare reaction species per cell and
# each operator makearray per cell, and recording the species' concrete grid
# shape. The reaction network then runs pointwise on the grid through the
# existing NumPy arrayop evaluator. Julia counterpart: flatten.jl
# ``_apply_pointwise_lift!``.


def _collect_makearrays(expr: Expr, acc: list[ExprNode]) -> list[ExprNode]:
    """Collect every ``makearray`` node reachable from ``expr`` (pre-order)."""
    acc.extend(node for node in walk(expr) if isinstance(node, ExprNode) and node.op == "makearray")
    return acc


def _index_arg_loop(expr: Expr) -> str | None:
    """First bare-name leaf in an index-position expression (its loop variable),
    or ``None`` for a constant position."""
    if isinstance(expr, str):
        return expr
    if isinstance(expr, ExprNode):
        for a in expr.args:
            v = _index_arg_loop(a)
            if v is not None:
                return v
    return None


def _detect_lift_loops(ma: ExprNode, lifted: set[str], rank: int) -> list[str] | None:
    """Ordered spatial loop variables of a lowered operator makearray, read from
    an ``index(<lifted species>, a1, …, aRank)`` gather whose every position
    carries a loop variable (the interior stencil). Returns the loop names in
    index-position order, or ``None`` if none is found."""
    for e in walk(ma):
        if (
            isinstance(e, ExprNode)
            and e.op == "index"
            and e.args
            and isinstance(e.args[0], str)
            and e.args[0] in lifted
            and len(e.args) - 1 == rank
        ):
            loops: list[str] = []
            ok = True
            for k in range(1, len(e.args)):
                lv = _index_arg_loop(e.args[k])
                if lv is None:
                    ok = False
                    break
                loops.append(lv)
            if ok:
                return loops
    return None


def _makearray_extents(ma: ExprNode) -> list[int]:
    """Per-dimension grid extent of a lowered operator makearray: the largest
    cell index addressed in each ``regions`` dimension."""
    regions = ma.regions or []
    if not regions:
        return []
    rank = len(regions[0])
    ext = [0] * rank
    for region in regions:
        if len(region) != rank:
            continue
        for d in range(rank):
            ext[d] = max(ext[d], int(region[d][1]))
    return ext


def _lift_rhs_to_cell(expr: Expr, arrayvars: set[str], loops: list[str]) -> Expr:
    """Rewrite a scalar (merged reaction + operator) RHS into its per-cell form
    over the spatial ``loops``: a bare reference to an array variable becomes
    ``index(var, loops…)``, and each spatial-operator ``makearray`` becomes
    ``index(makearray, loops…)`` (its region values already index per cell).
    Self-contained nodes (index / aggregate) are left untouched; elementwise ops
    recurse."""
    if isinstance(expr, str):
        if expr in arrayvars:
            return ExprNode(op="index", args=[expr, *loops])
        return expr
    if isinstance(expr, ExprNode):
        if expr.op == "makearray":
            # Tag the makearray with its loop symbols so the evaluator binds each
            # region's own arange when materializing the field (esm-spec §10.5);
            # otherwise a per-cell gather would read the stencil out of bounds.
            ma = replace(expr, output_idx=list(loops))
            return ExprNode(op="index", args=[ma, *loops])
        if expr.op in ("index", "aggregate", "arrayop"):
            return expr
        new_args = [_lift_rhs_to_cell(a, arrayvars, loops) for a in expr.args]
        return replace(expr, args=new_args)
    return expr


def _apply_pointwise_lift(flat: FlattenedSystem, coupling: list[CouplingEntry]) -> None:
    """Pointwise spatial lift (esm-spec §10.5) for ``operator_compose`` couplings
    that declare ``lifting: "pointwise"``. Promotes every state ODE that
    operator_compose merged with a spatial operator (its merged RHS carries an
    operator ``makearray``) from a 0-D scalar to the operator's grid shape, and
    rewrites the equation into an ``aggregate`` over the grid. No-op when no
    coupling requests pointwise lifting, or no merged equation carries a
    spatial-operator makearray."""
    if not any(
        isinstance(c, OperatorComposeCoupling) and c.lifting == "pointwise" for c in coupling
    ):
        return

    def _d_target(lhs: Expr) -> str | None:
        if (
            isinstance(lhs, ExprNode)
            and lhs.op == "D"
            and lhs.args
            and isinstance(lhs.args[0], str)
        ):
            return lhs.args[0]
        return None

    # A species is lifted iff its state ODE's merged RHS carries a spatial-operator
    # makearray (the advection contribution operator_compose added).
    lifted: set[str] = set()
    for eq in flat.equations:
        target = _d_target(eq.lhs)
        if target is None:
            continue
        if _collect_makearrays(eq.rhs, []):
            lifted.add(target)
    if not lifted:
        return

    # Operands to index per cell: the lifted species plus any already array-shaped
    # parameter/observed/state (e.g. a grid-shaped wind field bound from a loader).
    arrayvars: set[str] = set(lifted)
    for table in (flat.parameters, flat.observed_variables, flat.state_variables):
        for name, var in table.items():
            if getattr(var, "shape", None):
                arrayvars.add(name)

    new_equations: list[FlattenedEquation] = []
    for eq in flat.equations:
        target = _d_target(eq.lhs)
        if target is None or target not in lifted:
            new_equations.append(eq)
            continue

        mas = _collect_makearrays(eq.rhs, [])
        if not mas or not mas[0].regions:
            new_equations.append(eq)
            continue
        rank = len(mas[0].regions[0])
        loops: list[str] | None = None
        for ma in mas:
            loops = _detect_lift_loops(ma, lifted, rank)
            if loops is not None:
                break
        if loops is None:
            raise DimensionPromotionError(
                f"pointwise lift: could not determine the spatial loop variables "
                f"for species {target!r} from its operator makearray"
            )

        extents = _makearray_extents(mas[0])
        ranges: dict[str, Any] = {loops[d]: [1, extents[d]] for d in range(rank)}
        output_idx: list[Any] = list(loops)

        flat.lifted_shapes[target] = tuple(extents)

        idx_species = ExprNode(op="index", args=[target, *loops])
        new_lhs = ExprNode(
            op="aggregate",
            output_idx=output_idx,
            ranges=ranges,
            expr=ExprNode(op="D", args=[idx_species], wrt="t"),
        )
        new_rhs = ExprNode(
            op="aggregate",
            output_idx=output_idx,
            ranges=ranges,
            expr=_lift_rhs_to_cell(eq.rhs, arrayvars, loops),
        )
        new_equations.append(
            FlattenedEquation(
                lhs=new_lhs,
                rhs=new_rhs,
                source_system=eq.source_system,
            )
        )

    flat.equations = new_equations


# ============================================================================
# Array-op variable shape inference
# ============================================================================


def _eval_index_expr(expr: Expr, index_vals: dict[str, int]) -> int | None:
    """Evaluate a small integer expression used as an array index.

    Supports literals, index symbols (bound via ``index_vals``), and the
    minimal set of arithmetic ops (+, -, *) on integers. Returns ``None`` if
    the expression is not a resolvable integer (e.g. contains a non-bound
    variable) — in that case the caller should skip this index for shape
    inference.
    """
    if isinstance(expr, (int, float)):
        if isinstance(expr, bool):
            return None
        try:
            return int(expr)
        except Exception:
            return None
    if isinstance(expr, str):
        if expr in index_vals:
            return index_vals[expr]
        return None
    if isinstance(expr, ExprNode):
        if expr.op == "+" and expr.args:
            acc = 0
            for a in expr.args:
                v = _eval_index_expr(a, index_vals)
                if v is None:
                    return None
                acc += v
            return acc
        if expr.op == "-" and expr.args:
            if len(expr.args) == 1:
                v = _eval_index_expr(expr.args[0], index_vals)
                return None if v is None else -v
            acc = _eval_index_expr(expr.args[0], index_vals)
            if acc is None:
                return None
            for a in expr.args[1:]:
                v = _eval_index_expr(a, index_vals)
                if v is None:
                    return None
                acc -= v
            return acc
        if expr.op == "*" and expr.args:
            acc = 1
            for a in expr.args:
                v = _eval_index_expr(a, index_vals)
                if v is None:
                    return None
                acc *= v
            return acc
    return None


def _collect_index_uses(
    expr: Expr,
    state_vars: set[str],
    out: dict[str, list[list[int]]],
    bound_indices: dict[str, int] | None = None,
) -> None:
    """Walk ``expr`` collecting concrete index tuples used against state vars.

    For every ``index(var, i0, i1, ...)`` sub-expression where ``var`` is a
    known state variable (post-namespacing), append the resolved integer
    index tuple to ``out[var]``. ``bound_indices`` carries the current
    arrayop index-symbol bindings (one entry per iterated point in the
    output box) so offset indices like ``u[i-1]`` resolve to concrete ints.
    """
    bound_indices = bound_indices or {}
    if _is_number(expr) or isinstance(expr, str) or expr is None:
        return
    if isinstance(expr, ExprNode):
        if expr.op == "index" and expr.args:
            head = expr.args[0]
            # Only resolve direct state variable references. Nested array ops
            # (reshape/transpose/... wrapping a state variable) still contribute
            # via their inner operand — but the outer index doesn't constrain
            # the state variable's shape directly. Keep it simple.
            if isinstance(head, str) and head in state_vars:
                # We need to enumerate index tuples across the current
                # bound_indices iteration context. Caller sets bound_indices
                # per sample point, so this walker just reads the current
                # values. If any index_expr is non-literal and no binding is
                # available, we skip.
                tup: list[int] = []
                ok = True
                for idx_expr in expr.args[1:]:
                    v = _eval_index_expr(idx_expr, bound_indices)
                    if v is None:
                        ok = False
                        break
                    tup.append(v)
                if ok and tup:
                    out.setdefault(head, []).append(tup)
            # Regardless, recurse into children (e.g. indices may themselves
            # have sub-expressions — shouldn't contain further `index` ops for
            # state vars in practice, but be safe).
            for child in iter_children(expr):
                _collect_index_uses(child, state_vars, out, bound_indices)
            return

        if expr.op == "aggregate":
            # Iterate the output box (via `ranges` if provided, else via the
            # output_idx symbols we cannot resolve). For each concrete point
            # inherit bound_indices and walk the body.
            ranges = expr.ranges or {}
            idx_syms = [s for s in (expr.output_idx or []) if isinstance(s, str)]
            # Also include any ranges-only symbols (reduction indices).
            for k in ranges.keys():
                if k not in idx_syms:
                    idx_syms.append(k)
            # Only enumerate concretely when every index has a dense [lo, hi]
            # range. Index-set references ({"from": ...}, RFC §5.2) are resolved
            # by the evaluator against the registry, not here; fall back to a
            # plain child walk so this collector never chokes on them.
            dense_ranges = all(isinstance(ranges.get(s), (list, tuple)) for s in idx_syms)
            if idx_syms and all(s in ranges for s in idx_syms) and dense_ranges:
                # Enumerate Cartesian product of index ranges.
                value_lists = [_expand_range(ranges[s]) for s in idx_syms]

                def rec(pos: int, current: dict[str, int]) -> None:
                    if pos == len(idx_syms):
                        for child in iter_children(expr):
                            _collect_index_uses(child, state_vars, out, current)
                        return
                    sym = idx_syms[pos]
                    for v in value_lists[pos]:
                        current[sym] = v
                        rec(pos + 1, current)
                        del current[sym]

                rec(0, dict(bound_indices))
            else:
                # Fall back: just walk children without bound indices.
                for child in iter_children(expr):
                    _collect_index_uses(child, state_vars, out, bound_indices)
            return

        # Default recursion: walk all children.
        for child in iter_children(expr):
            _collect_index_uses(child, state_vars, out, bound_indices)


def infer_variable_shapes(flat: FlattenedSystem) -> dict[str, tuple[int, ...]]:
    """Infer per-state-variable array shapes from the equation set.

    Walks every equation (LHS and RHS), collecting concrete integer indices
    used against state variables, and returns a ``{name: shape}`` dict where
    shape is a tuple of positive integers (one per dimension). Scalar
    variables — those that appear only as bare names, never inside an
    ``index`` op — get shape ``()``.

    Indices are assumed to be 1-based and contiguous starting at 1; the
    inferred length for each dimension is the maximum observed index along
    that dimension (clamped to at least 1). An index below 1 is out of range
    under the 1-based convention — the max is kept as-is and :func:`simulate`
    raises later if such a variable is ever flat-indexed.

    The result is a pure function of ``flat`` (state variables + equations), both
    fixed for a run, yet the deep ``_collect_index_uses`` tree walk is re-run on
    every RHS build — and the cadence-segmented loader driver rebuilds the RHS
    once per segment (:func:`simulation_loaders._run_cadence_segmented_solve`), so
    a 16-hour ERA5 run walks the whole AST ~16×. Memoize the walk on the ``flat``
    instance (built once, reused every segment) and hand back a COPY so the caller
    can freely ``update`` the dict without corrupting the cache. A fresh ``flat``
    (every test / model load) starts with an empty cache, so nothing is shared
    across systems.
    """
    _cached = flat._infer_shapes_cache
    if _cached is not None:
        return dict(_cached)

    state_names: set[str] = set(flat.state_variables.keys())
    uses: dict[str, list[list[int]]] = {}
    for eq in flat.equations:
        _collect_index_uses(eq.lhs, state_names, uses)
        _collect_index_uses(eq.rhs, state_names, uses)

    shapes: dict[str, tuple[int, ...]] = {}
    for name in state_names:
        if name not in uses or not uses[name]:
            shapes[name] = ()
            continue
        tups = uses[name]
        ndim_set = {len(t) for t in tups}
        if len(ndim_set) != 1:
            raise FlattenError(
                f"Variable {name!r} is indexed with conflicting dimensionality: {sorted(ndim_set)}"
            )
        ndim = next(iter(ndim_set))
        per_dim_max: list[int] = [0] * ndim
        for tup in tups:
            for d, v in enumerate(tup):
                if v > per_dim_max[d]:
                    per_dim_max[d] = v
        shape: list[int] = []
        for d in range(ndim):
            # 1-based: length = max index (under the convention that index 1
            # is the first slot). Offset indices like u[i-1] where i starts at
            # 2 still max out at the highest element. An index below 1 is out of
            # range under this convention — the max is kept as-is and solve()
            # errors later if the variable is ever flat-indexed.
            length = max(per_dim_max[d], 1)
            shape.append(length)
        shapes[name] = tuple(shape)
    flat._infer_shapes_cache = dict(shapes)
    return shapes
