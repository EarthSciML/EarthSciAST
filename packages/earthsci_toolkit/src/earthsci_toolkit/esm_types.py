"""
Type definitions for ESM Format using dataclasses.
"""

from dataclasses import dataclass, field
from typing import Union, List, Dict, Any, Optional, Literal, Tuple
from enum import Enum


# ========================================
# 1. Expression Types
# ========================================

@dataclass
class ExprNode:
    """A node in an expression tree."""
    op: str
    args: List['Expr'] = field(default_factory=list)
    wrt: Optional[str] = None  # with respect to (for derivatives)
    dim: Optional[str] = None  # dimension information
    var: Optional[str] = None  # integration variable name (for integral operator, JSON key "var")
    lower: Optional['Expr'] = None  # lower integration bound (for integral operator)
    upper: Optional['Expr'] = None  # upper integration bound (for integral operator)

    # Aggregate extensions (schema §ExpressionNode). None unless the op uses them.
    # The canonical Functional Aggregate Query op tag is "aggregate".
    output_idx: Optional[List[Union[str, int]]] = None
    expr: Optional['Expr'] = None
    reduce: Optional[str] = None  # default "+"; names only the semiring ⊕ operator
    # Named semiring (⊕, ⊗) parameterizing the reduction (RFC §5.1). When present
    # it supersedes ``reduce``; absent ⇒ "sum_product" (today's semantics).
    semiring: Optional[str] = None
    # Each range value is EITHER a dense integer tuple ([start, stop] or
    # [start, step, stop]) OR an index-set reference {"from": <name>, "of": [...]}
    # resolved against the document ``index_sets`` registry (RFC §5.2).
    ranges: Optional[Dict[str, Union[List[int], Dict[str, Any]]]] = None
    # Value-equality joins (RFC §5.3): an array of join clauses, each
    # ``{"on": [[left, right], ...]}`` naming key-column pairs. An inner
    # equi-join — a ⊗-product term is contributed only for index combinations
    # whose key columns are equal on every listed pair; an unmatched
    # combination contributes the additive identity 0̄. None ⇒ positional
    # einsum (factors combine by shared index name), exactly as today.
    join: Optional[List[Dict[str, Any]]] = None
    # Boolean predicate restricting which index combinations contribute a
    # ⊗-product term (RFC §5.3 / §7.2). Combinations for which it is false
    # contribute 0̄. None ⇒ no filter.
    filter: Optional['Expr'] = None
    # Set semantics for an index-set-producing aggregate (RFC §5.5). Parsed for
    # schema completeness; data-derived index-set materialization is not part of
    # the M2 join work.
    distinct: Optional[bool] = None
    # Skolem-term expression for an index-set-producing aggregate (RFC §5.5).
    key: Optional['Expr'] = None
    # makearray:
    regions: Optional[List[List[List[int]]]] = None
    values: Optional[List['Expr']] = None
    # reshape:
    shape: Optional[List[Union[int, str]]] = None
    # transpose:
    perm: Optional[List[int]] = None
    # concat:
    axis: Optional[int] = None
    # broadcast:
    fn: Optional[str] = None
    # Node addressing (RFC §6.1): a node-local id by which a `kind:"derived"`
    # index set names its producer via `from_faq`. Carried on an
    # `intersect_polygon` leaf so its data-dependent clip ring is exposed as a
    # derived index set the `polygon_area` FAQ ranges over (RFC §8.1).
    id: Optional[str] = None
    # Geometry interpretation for the `intersect_polygon` leaf — "planar" |
    # "spherical" | "geodesic" (RFC §8.1 / Appendix B; CONFORMANCE_SPEC.md
    # §5.8.4). REQUIRED on every intersect_polygon node, no default; matched
    # EXACTLY across bindings (two bindings compare only same-manifold).
    # Meaningful only for intersect_polygon; ignored on any other op.
    manifold: Optional[str] = None
    # call (registered function invocation, see esm-spec §4.4 / §9.2):
    handler_id: Optional[str] = None
    # fn (closed function registry — esm-spec §9.2): the dotted module path of
    # a function in the spec-defined closed set (e.g. "datetime.year",
    # "interp.searchsorted").
    name: Optional[str] = None
    # const (inline literal): the carried value. Any JSON number or nested
    # array thereof. Used to thread const-array tables through the AST without
    # premature numeric collapse (notably as `xs` for `interp.searchsorted`).
    value: Optional[Any] = None
    # table_lookup (esm-spec §9.5, v0.4.0): the function_tables entry id this
    # node references. ``args`` MUST be empty for a table_lookup node — the
    # per-axis input expressions live in ``table_axes``.
    table: Optional[str] = None
    # table_lookup: per-axis input-coordinate expression map. Keys MUST match
    # the axis names declared on the referenced FunctionTable; values are
    # arbitrary scalar Expressions (number, variable reference, or AST node).
    # Stored under the JSON key ``axes`` on the wire.
    table_axes: Optional[Dict[str, 'Expr']] = None
    # table_lookup: which output of a multi-output table to return. Either a
    # non-negative integer (0-based index into the leading data dimension) or
    # a string (an entry of the table's outputs list). Single-output tables
    # MAY omit this (defaults to 0 at lowering time).
    output: Optional[Union[int, str]] = None


# Recursive type definition for expressions
Expr = Union[int, float, str, ExprNode]


# The canonical Functional Aggregate Query op tag.
AGGREGATE_OPS: Tuple[str, ...] = ("aggregate",)


def is_aggregate_op(op: Any) -> bool:
    """True if ``op`` is the ``aggregate`` node tag."""
    return op in AGGREGATE_OPS


@dataclass
class Equation:
    """Mathematical equation with left and right hand sides."""
    lhs: Expr
    rhs: Expr
    _comment: Optional[str] = None


@dataclass
class AffectEquation:
    """Equation that affects a variable (assignment-like)."""
    lhs: str  # variable name being affected
    rhs: Expr  # expression to compute


# ========================================
# 2. Model Components
# ========================================

@dataclass
class ModelVariable:
    """A variable in a mathematical model.

    The "brownian" type denotes a stochastic noise source (Wiener process); the
    presence of any brownian variable promotes the enclosing model from an ODE
    system to an SDE system. The optional ``noise_kind`` and
    ``correlation_group`` fields apply only to brownian variables.
    """
    type: Literal['state', 'parameter', 'observed', 'brownian']
    units: Optional[str] = None
    default: Optional[Any] = None
    default_units: Optional[str] = None
    description: Optional[str] = None
    expression: Optional[Expr] = None
    # Arrayed-variable shape: ordered index-set names drawn from the
    # document-scoped ``index_sets`` registry (RFC semiring-faq-unified-ir §5.2).
    # None means scalar.
    shape: Optional[List[str]] = None
    # Staggered-grid location tag (e.g. "cell_center", "edge_normal",
    # "vertex"). None means no explicit staggering. See RFC §10.2.
    location: Optional[str] = None
    # Brownian-only: kind of stochastic process. Currently only "wiener".
    noise_kind: Optional[str] = None
    # Brownian-only: opaque tag grouping correlated noise sources.
    correlation_group: Optional[str] = None


@dataclass
class Model:
    """A mathematical model containing variables and equations."""
    name: str
    variables: Dict[str, ModelVariable] = field(default_factory=dict)
    equations: List[Equation] = field(default_factory=list)
    metadata: Dict[str, Any] = field(default_factory=dict)
    # A subsystem is a child Model or a pure-I/O DataLoader (RFC
    # pure-io-data-loaders §4.3); ref subsystems are raw {"ref": ...} dicts
    # until resolve_subsystem_refs replaces them in place.
    subsystems: Dict[str, Union['Model', 'DataLoader']] = field(default_factory=dict)
    # Boundary conditions are not a declared model concern: there is no `bc` op
    # and no `boundary_conditions` field. BCs are baked into the discretization
    # rewrite rules' `makearray` bodies (esm-spec §9.6.8); nothing to store here.
    # Model-level default numerical tolerance for inline tests (esm-spec §6.6).
    tolerance: Optional['Tolerance'] = None
    # Inline validation tests (esm-spec §6.6).
    tests: List['Test'] = field(default_factory=list)
    # Inline illustrative examples (esm-spec §6.7).
    examples: List['Example'] = field(default_factory=list)
    # Initialization-only equations (hold at t=0) and solver guesses (gt-ebuq).
    initialization_equations: List[Equation] = field(default_factory=list)
    guesses: Dict[str, Union[float, 'Expr']] = field(default_factory=dict)
    # MTK system-kind discriminator: "ode" (default), "nonlinear", "sde", "pde".
    system_kind: Optional[str] = None


@dataclass
class Species:
    """A chemical species in a reaction system."""
    name: str
    units: Optional[str] = None
    default: Optional[float] = None
    default_units: Optional[str] = None
    description: Optional[str] = None
    formula: Optional[str] = None  # Chemical formula
    constant: Optional[bool] = None  # Reservoir species (held-fixed, no ODE)


@dataclass
class Parameter:
    """A parameter for reaction systems."""
    name: str
    value: Union[float, Expr]
    units: Optional[str] = None
    default_units: Optional[str] = None
    description: Optional[str] = None
    uncertainty: Optional[float] = None


@dataclass
class Reaction:
    """A chemical reaction."""
    name: str
    id: Optional[str] = None
    # species -> coefficient. Values may be `int` or `float`: v0.2.x permits
    # fractional stoichiometries (e.g. `0.87 CH2O`). Parser preserves the
    # original JSON numeric type; serializer emits `int` for integer-valued
    # coefficients to keep integer fixtures byte-identical across round-trips.
    reactants: Dict[str, Union[int, float]] = field(default_factory=dict)
    products: Dict[str, Union[int, float]] = field(default_factory=dict)
    rate_constant: Optional[Union[float, Expr]] = None
    conditions: Dict[str, Any] = field(default_factory=dict)


@dataclass
class ReactionSystem:
    """A system of chemical reactions."""
    name: str
    species: List[Species] = field(default_factory=list)
    parameters: List[Parameter] = field(default_factory=list)
    reactions: List[Reaction] = field(default_factory=list)
    constraint_equations: List[Equation] = field(default_factory=list)
    subsystems: Dict[str, 'ReactionSystem'] = field(default_factory=dict)
    # Component-level default numerical tolerance for inline tests (esm-spec §6.6).
    tolerance: Optional['Tolerance'] = None
    # Inline validation tests (esm-spec §6.6).
    tests: List['Test'] = field(default_factory=list)
    # Inline illustrative examples (esm-spec §6.7).
    examples: List['Example'] = field(default_factory=list)


# ========================================
# 2b. Inline Tests, Examples, and Plots (esm-spec §6.6 / §6.7)
# ========================================


@dataclass
class Tolerance:
    """Numerical comparison tolerance. abs and/or rel may be set; an assertion
    passes when any set bound is satisfied."""
    abs: Optional[float] = None
    rel: Optional[float] = None


@dataclass
class TimeSpan:
    """Simulation time interval expressed in the component's time units."""
    start: float
    end: float


@dataclass
class Assertion:
    """A (variable, time, expected) check used inside a Test (esm-spec §6.6).

    The default form samples a scalar state. The §6.6.5 PDE forms add:

    - ``coords`` — point-sample an array state at physical coordinates.
    - ``reduce`` — collapse the variable's spatial field to a scalar
      (``L2_error`` / ``Linf_error`` against ``reference``, or the pure
      collapsers ``mean`` / ``max`` / ``min``).
    - ``reference`` — the analytic reference for the error reductions:
      an inline Expression AST, or a ``{"type": "from_file", …}`` dict
      carried verbatim.

    Mirrors the Julia binding's ``Assertion`` (types.jl); ``coords`` and
    ``reduce`` are mutually exclusive per the schema.
    """
    variable: str
    time: float
    expected: float
    tolerance: Optional[Tolerance] = None
    coords: Optional[Dict[str, float]] = None
    reduce: Optional[str] = None
    reference: Optional[Any] = None


@dataclass
class Test:
    """Inline validation test for a Model or ReactionSystem."""
    id: str
    time_span: TimeSpan
    assertions: List[Assertion] = field(default_factory=list)
    description: Optional[str] = None
    initial_conditions: Dict[str, float] = field(default_factory=dict)
    parameter_overrides: Dict[str, float] = field(default_factory=dict)
    tolerance: Optional[Tolerance] = None


@dataclass
class PlotAxis:
    """Axis specification for a plot."""
    variable: str
    label: Optional[str] = None


@dataclass
class PlotValue:
    """Scalar value derived from a trajectory (e.g., for heatmap color)."""
    variable: str
    at_time: Optional[float] = None
    reduce: Optional[str] = None  # "max" | "min" | "mean" | "integral" | "final"


@dataclass
class PlotSeries:
    """Single named series for multi-series line or scatter plots."""
    name: str
    variable: str


@dataclass
class Plot:
    """A plot specification associated with an example."""
    id: str
    type: str  # "line" | "scatter" | "heatmap"
    x: PlotAxis
    y: PlotAxis
    description: Optional[str] = None
    value: Optional[PlotValue] = None
    series: List[PlotSeries] = field(default_factory=list)


@dataclass
class SweepRange:
    """Generated range of parameter values."""
    start: float
    stop: float
    count: int
    scale: Optional[str] = None  # "linear" | "log"


@dataclass
class SweepDimension:
    """One axis of a parameter sweep; exactly one of values or range is set."""
    parameter: str
    values: Optional[List[float]] = None
    range: Optional[SweepRange] = None


@dataclass
class ParameterSweep:
    """Parameter sweep specification (currently only Cartesian)."""
    type: str  # "cartesian"
    dimensions: List[SweepDimension] = field(default_factory=list)


@dataclass
class Example:
    """Inline illustrative example of how to run a component."""
    id: str
    time_span: TimeSpan
    description: Optional[str] = None
    # Scalar initial-value overrides for this example run, keyed by state-variable
    # name. A component's initial fields are declared with `ic` op equations in the
    # model (esm-spec §11.4); this map overrides their scalar values for this run.
    initial_state: Optional[Dict[str, float]] = None
    parameters: Dict[str, float] = field(default_factory=dict)
    parameter_sweep: Optional[ParameterSweep] = None
    plots: List[Plot] = field(default_factory=list)


# ========================================
# 3. Event System
# ========================================

@dataclass
class FunctionalAffect:
    """A functional effect applied during an event."""
    handler_id: str
    read_vars: List[str] = field(default_factory=list)
    read_params: List[str] = field(default_factory=list)
    modified_params: List[str] = field(default_factory=list)
    config: Dict[str, Any] = field(default_factory=dict)


@dataclass
class ContinuousEvent:
    """An event that occurs when a condition becomes true during continuous evolution."""
    name: str
    conditions: List[Expr] = field(default_factory=list)  # Changed from single condition to array
    affects: List[Union[AffectEquation, FunctionalAffect]] = field(default_factory=list)
    affect_neg: Optional[List[Union[AffectEquation, FunctionalAffect]]] = None  # Added: affects for negative-going zero crossings
    root_find: Optional[Literal['left', 'right', 'all']] = 'left'  # Added: root-finding direction with default
    reinitialize: bool = False  # Added: whether to reinitialize after event
    priority: int = 0
    description: Optional[str] = None  # Added: optional description


@dataclass
class DiscreteEventTrigger:
    """Trigger condition for a discrete event."""
    type: Literal['condition', 'periodic', 'preset_times']
    value: Union[float, Expr, str]  # time value, condition expression, or external identifier


@dataclass
class DiscreteEvent:
    """An event that occurs at discrete time points."""
    name: str
    trigger: DiscreteEventTrigger
    affects: List[Union[AffectEquation, FunctionalAffect]] = field(default_factory=list)
    priority: int = 0


# ========================================
# 4. Data Loading and Operations
# ========================================

class DataLoaderKind(Enum):
    """Structural kind of an external data source."""
    GRID = "grid"
    POINTS = "points"
    STATIC = "static"


@dataclass
class DataLoaderDeterminism:
    """Reproducibility contract a loader advertises to bindings (esm-spec §8.9.2)."""
    endian: Optional[str] = None           # "little" | "big"
    float_format: Optional[str] = None     # "ieee754_single" | "ieee754_double"
    integer_width: Optional[int] = None    # 32 | 64


@dataclass
class DataLoaderSource:
    """File discovery configuration for a data loader."""
    url_template: str
    mirrors: List[str] = field(default_factory=list)


@dataclass
class DataLoaderTemporal:
    """Temporal coverage and record layout for a data source."""
    start: Optional[str] = None
    end: Optional[str] = None
    file_period: Optional[str] = None
    frequency: Optional[str] = None
    records_per_file: Optional[Union[int, str]] = None
    time_variable: Optional[str] = None


@dataclass
class DataLoaderVariable:
    """A variable exposed by a data loader, mapped from a source-file variable."""
    file_variable: str
    units: str
    unit_conversion: Optional[Union[float, int, 'Expr']] = None
    description: Optional[str] = None
    reference: Optional['Reference'] = None


@dataclass
class DataLoader:
    """
    Generic, runtime-agnostic description of an external data source.

    Pure I/O (RFC pure-io-data-loaders §4.1): carries enough structural
    information to locate files, map timestamps to files, and describe the
    native grid / variable semantics of the source — rather than pointing at
    a runtime handler. Reprojection and regridding onto a model grid are a
    downstream model concern, not a loader field.
    """
    name: str
    kind: DataLoaderKind
    source: DataLoaderSource
    variables: Dict[str, DataLoaderVariable] = field(default_factory=dict)
    temporal: Optional[DataLoaderTemporal] = None
    determinism: Optional[DataLoaderDeterminism] = None
    reference: Optional['Reference'] = None
    metadata: Dict[str, Any] = field(default_factory=dict)


@dataclass
class Operator:
    """A registered runtime operator (e.g., dry deposition, wet scavenging)."""
    operator_id: str
    needed_vars: List[str]
    modifies: Optional[List[str]] = None
    reference: Optional['Reference'] = None
    config: Dict[str, Any] = field(default_factory=dict)
    description: Optional[str] = None


@dataclass
class RegisteredFunctionSignature:
    """Calling convention for a RegisteredFunction (see esm-spec §9.2)."""
    arg_count: int
    arg_types: Optional[List[str]] = None
    return_type: Optional[str] = None


@dataclass
class RegisteredFunction:
    """A named pure function invoked inside expressions via the 'call' op."""
    id: str
    signature: RegisteredFunctionSignature
    units: Optional[str] = None
    arg_units: Optional[List[Optional[str]]] = None
    description: Optional[str] = None
    references: List['Reference'] = field(default_factory=list)
    config: Dict[str, Any] = field(default_factory=dict)


class CouplingType(Enum):
    """Types of coupling between model components matching ESM schema."""
    OPERATOR_COMPOSE = "operator_compose"
    COUPLE = "couple"
    VARIABLE_MAP = "variable_map"
    OPERATOR_APPLY = "operator_apply"
    CALLBACK = "callback"
    EVENT = "event"


@dataclass
class ConnectorEquation:
    """Single equation in a connector system."""
    from_var: str
    to_var: str
    transform: str
    expression: Optional[Expr] = None


@dataclass
class Connector:
    """Connector system with equations."""
    equations: List[ConnectorEquation] = field(default_factory=list)


# Base class for all coupling entries
@dataclass
class BaseCouplingEntry:
    """Base class for all coupling entry types."""
    coupling_type: CouplingType
    description: Optional[str] = None


@dataclass
class OperatorComposeCoupling(BaseCouplingEntry):
    """Coupling entry for operator_compose type."""
    coupling_type: CouplingType = field(default=CouplingType.OPERATOR_COMPOSE, init=False)
    systems: List[str] = field(default_factory=list)
    translate: Dict[str, Any] = field(default_factory=dict)
    # Spatial-lift strategy (esm-spec §10.5). ``"pointwise"`` requests the
    # flattener array-ify each merged reaction+operator state ODE onto the grid
    # (per-cell reaction evaluation). None ⇒ no lift (0-D / already-array system).
    lifting: Optional[str] = None


@dataclass
class CouplingCouple(BaseCouplingEntry):
    """Coupling entry for couple type."""
    coupling_type: CouplingType = field(default=CouplingType.COUPLE, init=False)
    systems: List[str] = field(default_factory=list)
    connector: Optional[Connector] = None


@dataclass
class VariableMapCoupling(BaseCouplingEntry):
    """Coupling entry for variable_map type."""
    coupling_type: CouplingType = field(default=CouplingType.VARIABLE_MAP, init=False)
    from_var: Optional[str] = None
    to_var: Optional[str] = None
    # EITHER one of the legacy enum strings ("param_to_var", "identity",
    # "additive", "multiplicative", "conversion_factor") OR an ExpressionNode
    # (in-progress-0.8.0 widening; operator-node object only on the wire).
    # An expression transform must reference the entry's `from` variable and
    # takes no `factor`; every variable reference inside it is already a
    # fully-scoped reference into the flattened coupled system.
    transform: Optional[Union[str, Expr]] = None
    factor: Optional[float] = None


@dataclass
class OperatorApplyCoupling(BaseCouplingEntry):
    """Coupling entry for operator_apply type."""
    coupling_type: CouplingType = field(default=CouplingType.OPERATOR_APPLY, init=False)
    operator: Optional[str] = None


@dataclass
class CallbackCoupling(BaseCouplingEntry):
    """Coupling entry for callback type."""
    coupling_type: CouplingType = field(default=CouplingType.CALLBACK, init=False)
    callback_id: Optional[str] = None
    config: Dict[str, Any] = field(default_factory=dict)


@dataclass
class EventCoupling(BaseCouplingEntry):
    """Coupling entry for event type."""
    coupling_type: CouplingType = field(default=CouplingType.EVENT, init=False)
    event_type: Optional[str] = None
    conditions: List[Expr] = field(default_factory=list)
    trigger: Optional["DiscreteEventTrigger"] = None
    affects: List["AffectEquation"] = field(default_factory=list)
    affect_neg: List["AffectEquation"] = field(default_factory=list)
    discrete_parameters: List[str] = field(default_factory=list)
    root_find: Optional[str] = None
    reinitialize: Optional[bool] = None


# Discriminated union of all coupling entry types
CouplingEntry = Union[
    OperatorComposeCoupling,
    CouplingCouple,
    VariableMapCoupling,
    OperatorApplyCoupling,
    CallbackCoupling,
    EventCoupling
]


# ========================================
# 5. Computational Domain and Solving
# ========================================

@dataclass
class TemporalDomain:
    """Temporal domain specification."""
    start: Optional[str] = None  # ISO datetime string
    end: Optional[str] = None    # ISO datetime string
    reference_time: Optional[str] = None  # ISO datetime string


# Initial conditions are no longer a domain-level concept. As of v0.8.0 a
# component's initial fields are declared with `ic` op equations in the model
# (LHS ``{op: "ic", args: [<var>]}``, RHS = the initial field; esm-spec §11.4).
# The former ``InitialConditionType`` enum and ``InitialCondition`` dataclass,
# along with ``Domain.initial_conditions``, have been removed.


# Boundary conditions are not a declared concept in the format: there is no
# `bc` op and no `boundary_conditions` field. BCs are baked into the
# discretization rewrite rules' `makearray` bodies (esm-spec §9.6.8). The former
# ``BoundaryCondition`` / ``BoundaryConditionKind`` / ``BCContributedBy`` types
# and the ``Model.boundary_conditions`` field have been removed.


@dataclass
class Domain:
    """Comprehensive computational domain specification.

    A domain carries no boundary-condition data: BCs are not a declared concept
    in the format (they are baked into discretization rewrite rules, §9.6.8).
    """
    name: Optional[str] = None
    independent_variable: Optional[str] = None
    temporal: Optional[TemporalDomain] = None

    # Legacy support for backwards compatibility
    dimensions: Optional[Dict[str, Any]] = None
    coordinates: Dict[str, List[float]] = field(default_factory=dict)
    boundaries: Dict[str, Any] = field(default_factory=dict)


# ========================================
# 6. Metadata and File Structure
# ========================================

@dataclass
class Reference:
    """Bibliographic reference."""
    title: str
    authors: List[str] = field(default_factory=list)
    journal: Optional[str] = None
    year: Optional[int] = None
    doi: Optional[str] = None
    url: Optional[str] = None


@dataclass
class Metadata:
    """Metadata about the model or dataset."""
    title: str
    description: Optional[str] = None
    authors: List[str] = field(default_factory=list)
    created: Optional[str] = None  # ISO datetime string
    modified: Optional[str] = None  # ISO datetime string
    version: str = "1.0"
    references: List[Reference] = field(default_factory=list)
    keywords: List[str] = field(default_factory=list)
    custom: Dict[str, Any] = field(default_factory=dict)

    @property
    def name(self) -> str:
        """Alias for title field (matches JSON 'name' key)."""
        return self.title


@dataclass
class FunctionTableAxis:
    """A single named axis inside a FunctionTable (esm-spec §9.5).

    ``values`` MUST be strictly-increasing finite floats with at least 2
    entries (mirrors the §9.2 interp.linear / interp.bilinear axis contract).
    ``units`` is advisory only in v0.4.0 — recorded for documentation, not
    used for load-time unit-checking.
    """
    name: str
    values: List[float]
    units: Optional[str] = None


@dataclass
class FunctionTable:
    """A sampled function table referenced by table_lookup AST ops
    (esm-spec §9.5, v0.4.0).

    Tables are syntactic sugar over §9.2's interp.linear / interp.bilinear /
    index — a table_lookup query MUST be bit-equivalent to the equivalent
    inline-const lookup. The shape of ``data`` is
    ``[len(outputs), len(axes[0].values), len(axes[1].values), ...]`` when
    ``outputs`` is non-empty; ``[len(axes[0].values), ...]`` otherwise.
    """
    axes: List[FunctionTableAxis]
    data: Any  # Nested-array literal of finite numbers
    description: Optional[str] = None
    interpolation: Optional[str] = None  # 'linear' | 'bilinear' | 'nearest'
    out_of_bounds: Optional[str] = None  # 'clamp' | 'error'
    outputs: Optional[List[str]] = None
    shape: Optional[List[int]] = None
    schema_version: Optional[str] = None


@dataclass
class EsmFile:
    """Root container for an ESM format file."""
    version: str
    metadata: Metadata
    models: Dict[str, Model] = field(default_factory=dict)
    reaction_systems: Dict[str, ReactionSystem] = field(default_factory=dict)
    events: List[Union[ContinuousEvent, DiscreteEvent]] = field(default_factory=list)
    data_loaders: Dict[str, DataLoader] = field(default_factory=dict)
    operators: List[Operator] = field(default_factory=list)
    registered_functions: Dict[str, RegisteredFunction] = field(default_factory=dict)
    coupling: List[CouplingEntry] = field(default_factory=list)
    # File-local enum mappings for the `enum` AST op (esm-spec §9.3). Keyed by
    # enum name; each value maps symbolic names to positive integers. Resolved
    # at load time by `lower_enums` before expression evaluation.
    enums: Dict[str, Dict[str, int]] = field(default_factory=dict)
    # Component-scoped sampled function tables (esm-spec §9.5, v0.4.0). Keyed
    # by table id; each value is a FunctionTable referenced by table_lookup
    # AST nodes.
    function_tables: Dict[str, FunctionTable] = field(default_factory=dict)
    # A single shared spatiotemporal domain (v0.8.0). Spatiality of individual
    # variables is expressed via their ``shape``; there is one domain per file,
    # not a map of named domains.
    domain: Optional[Domain] = None
    # Document-scoped registry of named index sets (RFC semiring-faq-unified-ir
    # §5.2), keyed by name — the single, document-level declaration site for
    # every iteration domain shared by all models in the file. Each entry is an
    # IndexSet dict: interval / categorical / derived / ragged. Referenced from
    # aggregate range specs of the form {"from": <name>} and from variable
    # ``shape`` lists. Moved here from ``Model`` in v0.8.0.
    index_sets: Dict[str, Any] = field(default_factory=dict)

    @property
    def esm(self) -> str:
        """Alias for version field (matches JSON 'esm' key)."""
        return self.version