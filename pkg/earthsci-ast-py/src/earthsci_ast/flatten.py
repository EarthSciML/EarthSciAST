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

from .errors import EarthSciAstError
from .esm_types import (
    ARRAY_OPS,
    AffectEquation,
    CallbackCoupling,
    ContinuousEvent,
    CouplingCouple,
    CouplingEntry,
    DataLoader,
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

# ============================================================================
# Errors (spec §4.7.5 + §4.7.6 — names mirror Rust's FlattenError enum
# variants for cross-language error-name parity)
# ============================================================================


class FlattenError(EarthSciAstError):
    """Base class for errors raised during flatten()."""


class ConflictingDerivativeError(FlattenError):
    """Two systems define non-additive equations for the same dependent variable."""


class DimensionPromotionError(FlattenError):
    """A variable or equation cannot be promoted given the available Interfaces.

    Raised when dimension promotion is ambiguous, when required dimension
    metadata is missing, or when the promotion request would otherwise fail
    independent of mapping-tier support — see spec §4.7.6.
    """


# The following six errors are declared for cross-binding parity; they are not
# raised by the Python Core tier (§4.7.6 dimension-promotion is not implemented
# in this tier). They exist so callers catching them by name behave uniformly
# across language bindings.
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
    """An Interface coupling requires a unit conversion that was not declared."""


class DomainExtentMismatchError(FlattenError):
    """Two domains coupled via ``identity`` have incompatible spatial extents."""


class SliceOutOfDomainError(FlattenError):
    """A ``slice`` mapping reaches outside the source variable's domain."""


class CyclicPromotionError(FlattenError):
    """Promotion rules form a cycle (A→B→…→A)."""


class UnsupportedDimensionalityError(FlattenError):
    """The flattened system has a dimensionality the simulator cannot handle.

    Raised by simulate() when the flattened system still contains a spatial
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


@dataclass
class LoaderField:
    """A data-loader variable lowered to a flattened observed array.

    A ``DataLoader`` mounted as a model subsystem (RFC pure-io-data-loaders §4.3)
    exposes its variables to the owning model under the dot-path
    ``<owner>.<subkey>.<var>`` (e.g. ``ERA5.pl.u`` — owner model ``ERA5``,
    subsystem key ``pl``, loader variable ``u``). Flatten lowers each such
    variable to an ``observed`` :class:`FlattenedVariable` of that name AND
    records this descriptor so the simulator can execute the loader at its
    cadence and bind the resulting array into the RHS as a read-only input —
    the loader symbol then resolves wherever a coupling edge substituted it
    into a consumer's equation. Loader fields carry no defining equation
    (their value is injected, not computed).

    ``cadence`` follows the loader-seeded refinement (§5.7.2, cadence.py): a
    loader WITH a ``temporal`` block is time-varying → ``"discrete"`` (updated
    in a discrete solver callback at its cadence); a loader WITHOUT ``temporal``
    is static → ``"const"`` (loaded once before integration).
    """

    name: str  # "ERA5.pl.u" — the observed-array symbol
    owner: str  # "ERA5" — the owning model's namespaced prefix
    subkey: str  # "pl" — the subsystem key the loader mounts under
    var: str  # "u" — the loader variable name
    loader: DataLoader  # the source loader (carries source/temporal)
    cadence: str  # "const" | "discrete"


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
    # Empty ⇒ the system has no data-loader subsystems, so simulate() behaves
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


_SPATIAL_OPS = {"grad", "div", "laplacian", "curl"}
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

        if op in _SPATIAL_OPS:
            inner = args[0] if args else ""
            dim = expr.dim or ""
            return f"{op}({inner}, {dim})" if dim else f"{op}({inner})"

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


def _namespace_expr(
    expr: Expr,
    prefix: str,
    leave_alone: set[str] | None = None,
    subsystem_keys: set[str] | None = None,
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
        # ``join.on`` key columns are LEFT UNCHANGED here: a key may name a
        # DOCUMENT-scoped index set (e.g. a categorical equi-join on
        # ``sourceType``) that must NOT be model-prefixed, and this namespacing
        # pass has no index-set registry to tell the two apart. A key that names
        # a model-local value-invention buffer (``rg_src_bin``) is instead
        # reconciled bare-vs-namespaced at join-resolution time
        # (numpy_interpreter._resolve_join_key_column), which has the buffer set.
        #
        # ``map_children`` rebuilds via ``replace`` so closed-function metadata
        # (``name``, ``value``, ``handler_id``, ``table``, ``output``) is
        # preserved automatically. Hand-listing fields silently drops any new
        # ExprNode attribute and cost the SymPy bridge ``fn``-op support
        # before this fix (esm-6ka).
        return map_children(
            expr,
            lambda c: _namespace_expr(c, prefix, local_leave, subsystem_keys),
        )
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


def _has_spatial_operator(expr: Expr) -> bool:
    """Return True if ``expr`` contains a spatial derivative operator."""
    if isinstance(expr, ExprNode):
        if expr.op in _SPATIAL_OPS:
            return True
        return any_child(expr, _has_spatial_operator)
    return False


def _spatial_dims_in_expr(expr: Expr) -> set[str]:
    """Return the set of spatial dimension labels referenced by spatial ops."""
    out: set[str] = set()
    for node in walk(expr):
        if isinstance(node, ExprNode) and node.op in _SPATIAL_OPS and node.dim:
            out.add(node.dim)
    return out


# ============================================================================
# Coupling rule descriptions (kept compatible with the previous module)
# ============================================================================


def _describe_coupling(entry: CouplingEntry) -> str:
    if isinstance(entry, OperatorComposeCoupling):
        systems = " + ".join(entry.systems)
        rule = f"operator_compose({systems})"
        if entry.translate:
            rule += (
                " [translate: " + ", ".join(f"{k}->{v}" for k, v in entry.translate.items()) + "]"
            )
        return rule
    if isinstance(entry, CouplingCouple):
        systems = " <-> ".join(entry.systems)
        return f"couple({systems})"
    if isinstance(entry, VariableMapCoupling):
        rule = f"variable_map({entry.from_var} -> {entry.to_var}, transform={entry.transform})"
        if entry.factor is not None:
            rule += f" [factor={entry.factor}]"
        return rule
    if isinstance(entry, OperatorApplyCoupling):
        return f"operator_apply({entry.operator})"
    if isinstance(entry, CallbackCoupling):
        return f"callback({entry.callback_id})"
    return f"unknown({type(entry).__name__})"


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


def _collect_model(name: str, model: Model, prefix: str | None = None) -> _ComponentSystem:
    """Collect a Model (recursively, including subsystems) into a _ComponentSystem."""
    full_prefix = prefix or name
    component = _ComponentSystem(name=full_prefix)

    for var_name, var in model.variables.items():
        namespaced = f"{full_prefix}.{var_name}"
        flat_var = FlattenedVariable(
            name=namespaced,
            type=var.type,
            units=var.units,
            default=var.default,
            description=var.description,
            source_system=full_prefix,
            shape=list(var.shape) if var.shape else None,
        )
        if var.type == "state":
            component.state_vars[namespaced] = flat_var
        elif var.type == "parameter":
            component.parameters[namespaced] = flat_var
        elif var.type == "observed":
            component.observed[namespaced] = flat_var

    # _var is a placeholder used by operator_compose; never namespace it.
    leave_alone = {"t", "_var"}
    # Subsystem keys mounted on this model (data loaders like `raw`, or nested
    # models): references rooted at one of these (`raw.fuel_model`) are
    # subsystem-LOCAL and must be qualified with the model prefix to match the
    # lowered LoaderField / subsystem name (see _namespace_expr).
    sub_keys = set(model.subsystems.keys())
    # Observed variables that carry an explicit `expression` define an
    # algebraic relation `name = expression`. Emit them as namespaced
    # equations so simulate() and codegen can inline them. Without this
    # step the body is dropped at flatten time, leaving any reference to
    # the observed name as an unbound free symbol downstream.
    for var_name, var in model.variables.items():
        if var.type != "observed" or var.expression is None:
            continue
        namespaced = f"{full_prefix}.{var_name}"
        ns_rhs = _namespace_expr(
            var.expression, full_prefix, leave_alone=leave_alone, subsystem_keys=sub_keys
        )
        component.equations.append(
            FlattenedEquation(
                lhs=namespaced,
                rhs=ns_rhs,
                source_system=full_prefix,
            )
        )
    for eq in model.equations:
        ns_lhs = _namespace_expr(
            eq.lhs, full_prefix, leave_alone=leave_alone, subsystem_keys=sub_keys
        )
        ns_rhs = _namespace_expr(
            eq.rhs, full_prefix, leave_alone=leave_alone, subsystem_keys=sub_keys
        )
        component.equations.append(
            FlattenedEquation(
                lhs=ns_lhs,
                rhs=ns_rhs,
                source_system=full_prefix,
            )
        )

    for sub_name, sub_model in model.subsystems.items():
        # A data-loader subsystem (RFC pure-io-data-loaders §4.3) exposes its
        # variables to the owning model under the dot-path
        # ``<owner>.<subkey>.<var>``. Lower each loader variable to an observed
        # ARRAY of that name and record a LoaderField descriptor; the loader has
        # no defining equation (its array value is injected at the RHS boundary
        # by the simulator, executed at the loader's cadence), so the observed
        # placeholder resolves wherever a coupling edge substituted the producer
        # symbol into a consumer equation. ESS has no array-valued parameter
        # path, so the observed-as-array vehicle is how loader outputs reach a
        # consumer (LANDFIRE / USGS3DEP close the same way via re-exposure).
        if isinstance(sub_model, DataLoader):
            cadence = "discrete" if sub_model.temporal is not None else "const"
            for var_name, loader_var in sub_model.variables.items():
                namespaced = f"{full_prefix}.{sub_name}.{var_name}"
                component.observed[namespaced] = FlattenedVariable(
                    name=namespaced,
                    type="observed",
                    units=loader_var.units,
                    description=loader_var.description,
                    source_system=f"{full_prefix}.{sub_name}",
                )
                component.loader_fields.append(
                    LoaderField(
                        name=namespaced,
                        owner=full_prefix,
                        subkey=sub_name,
                        var=var_name,
                        loader=sub_model,
                        cadence=cadence,
                    )
                )
            continue
        sub_prefix = f"{full_prefix}.{sub_name}"
        sub_component = _collect_model(sub_name, sub_model, sub_prefix)
        component.state_vars.update(sub_component.state_vars)
        component.parameters.update(sub_component.parameters)
        component.observed.update(sub_component.observed)
        component.equations.extend(sub_component.equations)
        component.loader_fields.extend(sub_component.loader_fields)

    return component


def _collect_reaction_system(
    name: str, rs: ReactionSystem, prefix: str | None = None
) -> _ComponentSystem:
    """Collect a ReactionSystem (lowered through derive_odes) into a _ComponentSystem.

    Species become state variables; reaction parameters become parameters;
    rate laws are converted to dN_i/dt equations via mass-action kinetics.
    Constraint equations are passed through.
    """
    full_prefix = prefix or name
    component = _ComponentSystem(name=full_prefix)

    has_reactions = bool(rs.reactions)
    derived: Model | None = None
    if has_reactions:
        derived = derive_odes(rs)

    leave_alone = {"t", "_var"}

    for species in rs.species:
        namespaced = f"{full_prefix}.{species.name}"
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

    if derived is not None:
        for eq in derived.equations:
            ns_lhs = _namespace_expr(eq.lhs, full_prefix, leave_alone=leave_alone)
            ns_rhs = _namespace_expr(eq.rhs, full_prefix, leave_alone=leave_alone)
            component.equations.append(
                FlattenedEquation(
                    lhs=ns_lhs,
                    rhs=ns_rhs,
                    source_system=full_prefix,
                )
            )

    for eq in rs.constraint_equations:
        ns_lhs = _namespace_expr(eq.lhs, full_prefix, leave_alone=leave_alone)
        ns_rhs = _namespace_expr(eq.rhs, full_prefix, leave_alone=leave_alone)
        component.equations.append(
            FlattenedEquation(
                lhs=ns_lhs,
                rhs=ns_rhs,
                source_system=full_prefix,
            )
        )

    for sub_name, sub_rs in rs.subsystems.items():
        sub_prefix = f"{full_prefix}.{sub_name}"
        sub_component = _collect_reaction_system(sub_name, sub_rs, sub_prefix)
        component.state_vars.update(sub_component.state_vars)
        component.parameters.update(sub_component.parameters)
        component.observed.update(sub_component.observed)
        component.equations.extend(sub_component.equations)

    return component


# ============================================================================
# Coupling resolution
# ============================================================================


def _build_translate_map(entry: OperatorComposeCoupling) -> dict[str, tuple[str, float]]:
    """Normalize the operator_compose ``translate`` dict.

    Each entry maps a scoped reference in system A to a scoped reference in
    system B (or vice versa), optionally with a conversion factor.
    """
    out: dict[str, tuple[str, float]] = {}
    if not entry.translate:
        return out
    for k, v in entry.translate.items():
        if isinstance(v, dict):
            target = v.get("to") or v.get("target") or v.get("var")
            factor = float(v.get("factor", 1.0))
            if target:
                out[k] = (target, factor)
        elif isinstance(v, str):
            out[k] = (v, 1.0)
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

    for b_eq in b.equations:
        b_dep = _lhs_dependent_var(b_eq.lhs)
        if b_dep is None:
            surviving_b.append(b_eq)
            continue

        # Determine the A target for this dependent variable.
        target_dep = b_dep
        factor = 1.0
        if b_dep in translate:
            t, factor = translate[b_dep]
            target_dep = t
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
        else:
            surviving_b.append(b_eq)

    b.equations = surviving_b


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

    for ceq in entry.connector.equations:
        target = ceq.to_var
        if not target:
            continue
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

    ``loader_names`` is the set of top-level ``data_loaders`` keys. When a
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
                    rhs=substitute(eq.rhs, bindings),
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
    for name, model in esm_file.models.items():
        components[name] = _collect_model(name, model)
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

    # Top-level data-loader names — used to recognize a ``param_to_var`` whose
    # producer is a LOADED field, so a grid-shaped binding keeps its shape.
    loader_names: set[str] = set(getattr(esm_file, "data_loaders", None) or {})
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
    seen_lhs: dict[str, FlattenedEquation] = {}
    for comp in components.values():
        for name, var in comp.state_vars.items():
            flat.state_variables[name] = var
        for name, var in comp.parameters.items():
            flat.parameters[name] = var
        for name, var in comp.observed.items():
            flat.observed_variables[name] = var
        flat.loader_fields.extend(comp.loader_fields)
        for eq in comp.equations:
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
    §4.7.6 — only the spatial-rejection check in simulate() distinguishes
    discretized systems (time-only) from an undiscretized spatial operator that
    survived into the flattened system.
    """
    if esm_file.domain is not None:
        # Single shared domain (v0.8.0): pass it through unchanged.
        flat.domain = esm_file.domain


def _derive_independent_vars(flat: FlattenedSystem) -> None:
    """Derive independent variables from the equation set.

    Time is always present; spatial dimensions are added when grad/div/laplacian
    operators reference them.
    """
    independent: list[str] = ["t"]
    spatial_dims: set[str] = set()
    for eq in flat.equations:
        spatial_dims.update(_spatial_dims_in_expr(eq.lhs))
        spatial_dims.update(_spatial_dims_in_expr(eq.rhs))
    for dim in sorted(spatial_dims):
        independent.append(dim)
    flat.independent_variables = independent


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
            # range under this convention — the max is kept as-is and simulate()
            # errors later if the variable is ever flat-indexed.
            length = max(per_dim_max[d], 1)
            shape.append(length)
        shapes[name] = tuple(shape)
    flat._infer_shapes_cache = dict(shapes)
    return shapes
