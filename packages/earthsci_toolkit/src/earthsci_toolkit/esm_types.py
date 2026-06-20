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

    # Array-op extensions (schema §ExpressionNode). None unless the op uses them.
    # arrayop / aggregate ("aggregate" is the canonical op tag; "arrayop" is a
    # deprecated alias — RFC semiring-faq-unified-ir §5.6):
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


# The canonical aggregate op tag and its deprecated alias (RFC
# semiring-faq-unified-ir §5.6). Every dispatch site MUST treat the two
# identically. ``aggregate`` is canonical; ``arrayop`` continues to parse and
# evaluate as an exact synonym so existing files are unaffected.
AGGREGATE_OPS: Tuple[str, str] = ("aggregate", "arrayop")


def is_aggregate_op(op: Any) -> bool:
    """True if ``op`` is the aggregate node tag or its deprecated ``arrayop`` alias."""
    return op in AGGREGATE_OPS


RuleRegion = Union[str, Dict[str, Any]]
"""
Spatial scope of a rule or equation (discretization RFC §7.2).
A string is a legacy advisory tag with no runtime effect.
A dict with 'kind' is a normative scoping predicate: boundary,
mask_field, or index_range.
"""


@dataclass
class Equation:
    """Mathematical equation with left and right hand sides."""
    lhs: Expr
    rhs: Expr
    _comment: Optional[str] = None
    region: Optional[RuleRegion] = None


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
    # Arrayed-variable shape: ordered dimension names from the enclosing
    # model's domain.spatial. None means scalar. See discretization RFC §10.2.
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
    subsystems: Dict[str, 'Model'] = field(default_factory=dict)
    # v0.2.0: model-level boundary conditions keyed by user-supplied id (RFC §9).
    boundary_conditions: Dict[str, 'BoundaryCondition'] = field(default_factory=dict)
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
    # Document-scoped registry of named index sets (RFC semiring-faq-unified-ir
    # §5.2), keyed by name. Each entry is an IndexSet dict: interval / categorical
    # / derived / ragged. Referenced from arrayop / aggregate range specs of the
    # form {"from": <name>}. Empty ⇒ resolution falls back to domain.spatial.
    index_sets: Dict[str, Any] = field(default_factory=dict)


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
    """A scalar (variable, time, expected) check used inside a Test."""
    variable: str
    time: float
    expected: float
    tolerance: Optional[Tolerance] = None


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
    initial_state: Optional['InitialCondition'] = None
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
    MESH = "mesh"


class DataLoaderMeshTopology(Enum):
    """Closed topology enum for mesh loaders (esm-spec §8.9, discretization RFC §8.A)."""
    MPAS_VORONOI = "mpas_voronoi"
    FESOM_TRIANGULAR = "fesom_triangular"
    ICON_TRIANGULAR = "icon_triangular"


@dataclass
class DataLoaderMesh:
    """Mesh descriptor for a DataLoader with kind='mesh' (esm-spec §8.9)."""
    topology: DataLoaderMeshTopology
    connectivity_fields: List[str]
    metric_fields: List[str]
    dimension_sizes: Dict[str, Union[int, str]] = field(default_factory=dict)


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
class DataLoaderSpatial:
    """Spatial grid description for a data source."""
    crs: str
    grid_type: str
    staggering: Dict[str, str] = field(default_factory=dict)
    resolution: Dict[str, float] = field(default_factory=dict)
    extent: Dict[str, List[float]] = field(default_factory=dict)


@dataclass
class DataLoaderVariable:
    """A variable exposed by a data loader, mapped from a source-file variable."""
    file_variable: str
    units: str
    unit_conversion: Optional[Union[float, int, 'Expr']] = None
    description: Optional[str] = None
    reference: Optional['Reference'] = None


@dataclass
class DataLoaderRegridding:
    """Structural regridding configuration for a data loader."""
    fill_value: Optional[float] = None
    extrapolation: Optional[str] = None  # "clamp", "nan", "periodic"


@dataclass
class DataLoader:
    """
    Generic, runtime-agnostic description of an external data source.

    Carries enough structural information to locate files, map timestamps
    to files, describe spatial/variable semantics, and regrid — rather than
    pointing at a runtime handler.
    """
    name: str
    kind: DataLoaderKind
    source: DataLoaderSource
    variables: Dict[str, DataLoaderVariable] = field(default_factory=dict)
    temporal: Optional[DataLoaderTemporal] = None
    spatial: Optional[DataLoaderSpatial] = None
    mesh: Optional[DataLoaderMesh] = None
    determinism: Optional[DataLoaderDeterminism] = None
    regridding: Optional[DataLoaderRegridding] = None
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
    transform: Optional[str] = None
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


@dataclass
class SpatialDimension:
    """Spatial dimension specification."""
    min: float
    max: float
    units: str
    grid_spacing: Optional[float] = None


@dataclass
class CoordinateTransform:
    """Coordinate transformation specification."""
    id: str
    description: str
    dimensions: List[str]


class InitialConditionType(Enum):
    """Types of initial conditions."""
    CONSTANT = "constant"
    PER_VARIABLE = "per_variable"
    FUNCTION = "function"
    DATA = "data"


@dataclass
class InitialCondition:
    """Initial condition specification."""
    type: InitialConditionType
    value: Optional[Union[float, Expr]] = None
    values: Optional[Dict[str, float]] = None  # For per_variable type
    function: Optional[str] = None
    data_source: Optional[str] = None


class BoundaryConditionKind(Enum):
    """BC kind enum (RFC §9.2)."""
    CONSTANT = "constant"
    DIRICHLET = "dirichlet"
    NEUMANN = "neumann"
    ROBIN = "robin"
    ZERO_GRADIENT = "zero_gradient"
    PERIODIC = "periodic"
    FLUX_CONTRIB = "flux_contrib"
    INTERFACE = "interface"


@dataclass
class BCContributedBy:
    """Component-contribution marker for flux_contrib BC entries (RFC §9.3)."""
    component: str
    flux_sign: str = "+"  # "+" or "-"


@dataclass
class BoundaryCondition:
    """Model-level boundary condition entry (v0.2.0). See docs/rfcs/discretization.md §9.2.

    This replaces the v0.1.0 domain-level BoundaryCondition; files that declare
    ``domains.<d>.boundary_conditions`` must be migrated via
    ``spec.migrate_0_1_to_0_2`` (RFC §16.1) before loading.
    """
    variable: str
    side: str
    kind: BoundaryConditionKind
    value: Optional[Union[float, Expr]] = None
    robin_alpha: Optional[Union[float, Expr]] = None
    robin_beta: Optional[Union[float, Expr]] = None
    robin_gamma: Optional[Union[float, Expr]] = None
    coupled_variable: Optional[str] = None
    flux_match: bool = False
    face_coords: Optional[List[str]] = None
    contributed_by: Optional[BCContributedBy] = None
    description: Optional[str] = None


@dataclass
class Domain:
    """Comprehensive computational domain specification.

    v0.2.0 breaking change: ``boundary_conditions`` is no longer a Domain field;
    it moved to ``Model.boundary_conditions`` per docs/rfcs/discretization.md §9.
    """
    name: Optional[str] = None
    independent_variable: Optional[str] = None
    temporal: Optional[TemporalDomain] = None
    spatial: Optional[Dict[str, SpatialDimension]] = None
    coordinate_transforms: List[CoordinateTransform] = field(default_factory=list)
    spatial_ref: Optional[str] = None
    initial_conditions: Optional[InitialCondition] = None

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
class GridMetricGenerator:
    """Generator for a grid metric array or connectivity table (RFC §6.5).

    ``kind`` discriminates how values are produced:
    - ``"expression"``: field ``expr`` holds an Expr tree / literal.
    - ``"loader"``: fields ``loader`` (data_loader name) and ``field`` (variable).
    - ``"builtin"``: field ``name`` names a builtin generator. The set of
      recognized builtin names is currently empty.
    """
    kind: str
    expr: Optional[Any] = None  # Expr for kind == "expression"
    loader: Optional[str] = None  # data_loader name for kind == "loader"
    field: Optional[str] = None  # field variable for kind == "loader"
    name: Optional[str] = None  # builtin name for kind == "builtin"


@dataclass
class GridMetricArray:
    """A grid metric array (e.g. dx, areaCell), RFC §6.5."""
    rank: int
    generator: GridMetricGenerator
    dim: Optional[str] = None
    dims: Optional[List[str]] = None
    shape: Optional[List[Union[int, str]]] = None


@dataclass
class GridConnectivity:
    """Grid connectivity table (RFC §6.3–§6.4)."""
    shape: List[Union[int, str]]
    rank: int
    loader: Optional[str] = None
    field: Optional[str] = None
    generator: Optional[GridMetricGenerator] = None


@dataclass
class GridExtent:
    """Cartesian grid extent per dimension (RFC §6.2)."""
    n: Union[int, str]
    spacing: Optional[str] = None


@dataclass
class Grid:
    """Top-level grid declaration (RFC §6).

    ``family`` discriminates structure: ``cartesian`` uses ``extents``;
    ``unstructured`` uses ``connectivity``.
    """
    family: str
    dimensions: List[str]
    name: str = ""
    description: Optional[str] = None
    locations: Optional[List[str]] = None
    metric_arrays: Dict[str, GridMetricArray] = field(default_factory=dict)
    parameters: Dict[str, Parameter] = field(default_factory=dict)
    domain: Optional[str] = None
    extents: Dict[str, GridExtent] = field(default_factory=dict)
    connectivity: Dict[str, GridConnectivity] = field(default_factory=dict)


@dataclass
class StaggeringRule:
    """Top-level staggering-rule declaration (RFC §7.4).

    ``kind`` discriminates the staggering family; v0.2.0 ships
    ``unstructured_c_grid`` (MPAS Voronoi C-grid). The referenced ``grid``
    must be a ``grids.<g>`` entry of family ``unstructured``.
    """
    kind: str
    grid: str
    name: str = ""
    description: Optional[str] = None
    cell_quantity_locations: Dict[str, str] = field(default_factory=dict)
    edge_normal_convention: Optional[str] = None
    dual_mesh_ref: Optional[str] = None
    reference: Optional[Any] = None


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
    domains: Dict[str, Domain] = field(default_factory=dict)
    grids: Dict[str, Grid] = field(default_factory=dict)
    staggering_rules: Dict[str, StaggeringRule] = field(default_factory=dict)
    # Named discretization schemes (RFC §7). Held as opaque dicts because
    # stencil coefficients and applies_to patterns carry pattern-variable
    # strings ($u, $x, $target, ...) that don't map onto the Expression
    # coercion pipeline. This preserves round-trip fidelity for both standard
    # Discretization (§7.1) and CrossMetricStencilRule (§7.5) entries.
    discretizations: Dict[str, Any] = field(default_factory=dict)

    @property
    def esm(self) -> str:
        """Alias for version field (matches JSON 'esm' key)."""
        return self.version