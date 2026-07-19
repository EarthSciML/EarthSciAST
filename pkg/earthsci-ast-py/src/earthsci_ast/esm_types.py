"""
Type definitions for ESM Format using dataclasses.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from dataclasses import fields as _dataclass_fields
from enum import Enum
from typing import Any, Literal, Union

from .op_registry import by_category as _by_category

# ========================================
# 1. Expression Types
# ========================================


@dataclass
class ExprNode:
    """A node in an expression tree."""

    op: str = field(metadata={"kind": "scalar"})
    args: list[Expr] = field(default_factory=list, metadata={"kind": "expr_list"})
    wrt: str | None = field(default=None, metadata={"kind": "scalar"})  # with respect to (for derivatives)
    dim: str | None = field(default=None, metadata={"kind": "scalar"})  # dimension information
    var: str | None = field(default=None, metadata={"kind": "scalar"})  # integration variable name (for integral operator, JSON key "var")
    lower: Expr | None = field(default=None, metadata={"kind": "expr"})  # lower integration bound (for integral operator)
    upper: Expr | None = field(default=None, metadata={"kind": "expr"})  # upper integration bound (for integral operator)

    # Aggregate extensions (schema §ExpressionNode). None unless the op uses them.
    # The canonical Functional Aggregate Query op tag is "aggregate".
    output_idx: list[str | int] | None = field(default=None, metadata={"kind": "scalar"})
    expr: Expr | None = field(default=None, metadata={"kind": "expr"})
    reduce: str | None = field(default=None, metadata={"kind": "scalar"})  # default "+"; names only the semiring ⊕ operator
    # Named semiring (⊕, ⊗) parameterizing the reduction (RFC §5.1). When present
    # it supersedes ``reduce``; absent ⇒ "sum_product" (today's semantics).
    semiring: str | None = field(default=None, metadata={"kind": "scalar"})
    # Each range value is EITHER a dense integer tuple ([start, stop] or
    # [start, step, stop]) OR an index-set reference {"from": <name>, "of": [...]}
    # resolved against the document ``index_sets`` registry (RFC §5.2).
    ranges: dict[str, list[int] | dict[str, Any]] | None = field(default=None, metadata={"kind": "canonical_nested"})
    # Value-equality joins (RFC §5.3): an array of join clauses, each
    # ``{"on": [[left, right], ...]}`` naming key-column pairs. An inner
    # equi-join — a ⊗-product term is contributed only for index combinations
    # whose key columns are equal on every listed pair; an unmatched
    # combination contributes the additive identity 0̄. None ⇒ positional
    # einsum (factors combine by shared index name), exactly as today.
    join: list[dict[str, Any]] | None = field(default=None, metadata={"kind": "scalar"})
    # Boolean predicate restricting which index combinations contribute a
    # ⊗-product term (RFC §5.3 / §7.2). Combinations for which it is false
    # contribute 0̄. None ⇒ no filter.
    filter: Expr | None = field(default=None, metadata={"kind": "expr"})
    # Set semantics for an index-set-producing aggregate (RFC §5.5). Parsed for
    # schema completeness; data-derived index-set materialization is not part of
    # the M2 join work.
    distinct: bool | None = field(default=None, metadata={"kind": "scalar"})
    # Skolem-term expression for an index-set-producing aggregate (RFC §5.5).
    key: Expr | None = field(default=None, metadata={"kind": "expr"})
    # Documentary relation tag for a `skolem` node (e.g. "edge"/"bin"/"pair").
    # Purely descriptive: it names the relation the emitted key belongs to and is
    # NEVER part of the key itself. ``args`` are PURE key components (exact integer
    # IDs, §5.5.1 rule 4) — a leading string in ``args`` is no longer overloaded as
    # the tag (which silently masked a real component on a typo). JSON wire key
    # "label". Mirrors the Julia reference `label` field.
    label: str | None = field(default=None, metadata={"kind": "scalar"})
    # makearray:
    regions: list[list[list[int]]] | None = field(default=None, metadata={"kind": "canonical_nested"})
    values: list[Expr] | None = field(default=None, metadata={"kind": "expr_list"})
    # reshape:
    shape: list[int | str] | None = field(default=None, metadata={"kind": "canonical_nested"})
    # transpose:
    perm: list[int] | None = field(default=None, metadata={"kind": "canonical_nested"})
    # concat:
    axis: int | None = field(default=None, metadata={"kind": "scalar"})
    # broadcast:
    fn: str | None = field(default=None, metadata={"kind": "scalar"})
    # Node addressing (RFC §6.1): a node-local id by which a `kind:"derived"`
    # index set names its producer via `from_faq`. Carried on an
    # `intersect_polygon` leaf so its data-dependent clip ring is exposed as a
    # derived index set the `polygon_area` FAQ ranges over (RFC §8.1).
    id: str | None = field(default=None, metadata={"kind": "scalar"})
    # Geometry interpretation for the `intersect_polygon` leaf — "planar" |
    # "spherical" | "geodesic" (RFC §8.1 / Appendix B; CONFORMANCE_SPEC.md
    # §5.8.4). REQUIRED on every intersect_polygon node, no default; matched
    # EXACTLY across bindings (two bindings compare only same-manifold).
    # Meaningful only for intersect_polygon; ignored on any other op.
    manifold: str | None = field(default=None, metadata={"kind": "scalar"})
    # call (registered function invocation, see esm-spec §4.4 / §9.2):
    handler_id: str | None = field(default=None, metadata={"kind": "scalar"})
    # fn (closed function registry — esm-spec §9.2): the dotted module path of
    # a function in the spec-defined closed set (e.g. "datetime.year",
    # "interp.searchsorted").
    name: str | None = field(default=None, metadata={"kind": "scalar"})
    # const (inline literal): the carried value. Any JSON number or nested
    # array thereof. Used to thread const-array tables through the AST without
    # premature numeric collapse (notably as `xs` for `interp.searchsorted`).
    value: Any | None = field(default=None, metadata={"kind": "scalar"})
    # table_lookup (esm-spec §9.5, v0.4.0): the function_tables entry id this
    # node references. ``args`` MUST be empty for a table_lookup node — the
    # per-axis input expressions live in ``table_axes``.
    table: str | None = field(default=None, metadata={"kind": "scalar"})
    # table_lookup: per-axis input-coordinate expression map. Keys MUST match
    # the axis names declared on the referenced FunctionTable; values are
    # arbitrary scalar Expressions (number, variable reference, or AST node).
    # Stored under the JSON key ``axes`` on the wire.
    table_axes: dict[str, Expr] | None = field(default=None, metadata={"wire": "axes", "kind": "expr_dict"})
    # table_lookup: which output of a multi-output table to return. Either a
    # non-negative integer (0-based index into the leading data dimension) or
    # a string (an entry of the table's outputs list). Single-output tables
    # MAY omit this (defaults to 0 at lowering time).
    output: int | str | None = field(default=None, metadata={"kind": "scalar"})


# Recursive type definition for expressions
Expr = Union[int, float, str, ExprNode]


# ---------------------------------------------------------------------------
# ExprNode wire codec — the SINGLE declaration site for how each ExprNode field
# maps to/from JSON. ``parse._parse_expression``, ``serialize._serialize_expression``
# and ``expr_walk`` all read this, and ``canonicalize`` derives its non-emissible
# set from the same ``dataclasses.fields(ExprNode)``. Adding a field therefore
# means editing ONLY the dataclass above (its ``field(metadata=...)`` plus a slot
# in the authored wire order below); the import-time check fails closed if the
# two drift.
#
# Per-field metadata (attached on the dataclass fields above):
#   "wire": JSON key on the wire (defaults to the Python field name; only
#           ``table_axes`` differs — wire key ``axes``).
#   "kind": codec class —
#       "scalar"           plain JSON passthrough (str/num/bool/list/dict data)
#       "expr"             one nested Expression, (de)serialized recursively
#       "expr_list"        a list of nested Expressions
#       "expr_dict"        a {name: Expression} map (table_lookup axes)
#       "canonical_nested" integer descriptor array canonicalized on emit
# ---------------------------------------------------------------------------

# Authored WIRE ORDER of ExprNode fields — the exact key order emitted by
# ``_serialize_expression`` and pinned BYTE-FOR-BYTE by the cross-language golden
# fixtures. It equals the dataclass field order EXCEPT ``label``, which the wire
# emits between ``name`` and ``value`` (verified against the goldens). This tuple
# pins ORDER only; each field's wire key and codec kind live in its metadata.
_EXPR_WIRE_ORDER: tuple[str, ...] = (
    "op", "args", "wrt", "dim", "var", "lower", "upper", "output_idx", "expr",
    "reduce", "semiring", "ranges", "join", "filter", "distinct", "key",
    "regions", "values", "shape", "perm", "axis", "fn", "id", "manifold",
    "handler_id", "name", "label", "value", "table", "table_axes", "output",
)

#: ExprNode fields ALWAYS emitted (never omitted when None/empty); every other
#: field omits when its value is None.
_EXPR_REQUIRED_FIELDS = frozenset({"op", "args"})

#: Codec kinds whose value is (or contains) nested child Expressions.
_EXPR_CHILD_KINDS = frozenset({"expr", "expr_list", "expr_dict"})


def _build_expr_wire_spec() -> tuple[tuple[str, str, str, bool], ...]:
    """Return ``(field_name, wire_key, kind, required)`` for every ExprNode
    field in wire-emit order, derived from the field metadata.

    Fail-closed: every dataclass field must appear exactly once in
    ``_EXPR_WIRE_ORDER`` and carry a ``kind`` — so adding a field without giving
    it a wire slot / codec raises here at import rather than silently dropping it
    from the wire (the keystone this codec exists to protect).
    """
    by_name = {f.name: f for f in _dataclass_fields(ExprNode)}
    if set(_EXPR_WIRE_ORDER) != set(by_name):
        missing = sorted(set(by_name) - set(_EXPR_WIRE_ORDER))
        extra = sorted(set(_EXPR_WIRE_ORDER) - set(by_name))
        raise RuntimeError(
            f"ExprNode wire spec drift: fields missing a wire slot={missing}; "
            f"wire slots with no field={extra}"
        )
    spec: list[tuple[str, str, str, bool]] = []
    for name in _EXPR_WIRE_ORDER:
        meta = by_name[name].metadata
        kind = meta["kind"]  # KeyError => a field lacks a codec kind (fail closed)
        wire = meta.get("wire", name)
        spec.append((name, wire, kind, name in _EXPR_REQUIRED_FIELDS))
    return tuple(spec)


#: ``(field_name, wire_key, kind, required)`` in wire-emit order — driven by
#: parse/serialize.
EXPR_WIRE_SPEC: tuple[tuple[str, str, str, bool], ...] = _build_expr_wire_spec()

#: ``(field_name, kind)`` for the child-bearing fields only, in canonical visit
#: order (args, then the single-expr slots, then values, then table_axes) — the
#: ONE child-field declaration ``expr_walk`` reads.
EXPR_CHILD_SPEC: tuple[tuple[str, str], ...] = tuple(
    (name, kind) for name, _wire, kind, _req in EXPR_WIRE_SPEC if kind in _EXPR_CHILD_KINDS
)


# The canonical Functional Aggregate Query op tag.
AGGREGATE_OPS: tuple[str, ...] = ("aggregate",)


def is_aggregate_op(op: Any) -> bool:
    """True if ``op`` is the ``aggregate`` node tag."""
    return op in AGGREGATE_OPS


# Ops whose presence anywhere in an expression routes the model to the NumPy
# array simulation path (the SymPy/lambdify path is scalar-only). Shared by
# flatten's equation classification and numpy_interpreter's containment check
# so the set is defined exactly once.
#
# DERIVED from the canonical op registry so it cannot drift: the ``array``
# category (aggregate/makearray/index/broadcast/reshape/transpose/concat) PLUS the
# ``geometry`` category. The two geometry leaves are array-routed too:
# ``intersect_polygon`` (RFC §8.1) yields an array-valued clipped overlap ring,
# and ``polygon_intersection_area`` (esm-spec §8.6.1) is scalar-valued but reads
# array-valued polygon-ring operands the SymPy path cannot clip/area — so a model
# carrying only one of those observeds must still take the NumPy simulate path.
ARRAY_OPS = _by_category("array") | _by_category("geometry")


@dataclass
class Equation:
    """Mathematical equation with left and right hand sides."""

    lhs: Expr
    rhs: Expr
    _comment: str | None = None


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

    type: Literal["state", "parameter", "observed", "brownian"]
    units: str | None = None
    default: Any | None = None
    default_units: str | None = None
    description: str | None = None
    expression: Expr | None = None
    # Arrayed-variable shape: ordered index-set names drawn from the
    # document-scoped ``index_sets`` registry (RFC semiring-faq-unified-ir §5.2).
    # None means scalar.
    shape: list[str] | None = None
    # Staggered-grid location tag (e.g. "cell_center", "edge_normal",
    # "vertex"). None means no explicit staggering. See RFC §10.2.
    location: str | None = None
    # Brownian-only: kind of stochastic process. Currently only "wiener".
    noise_kind: str | None = None
    # Brownian-only: opaque tag grouping correlated noise sources.
    correlation_group: str | None = None


@dataclass
class Model:
    """A mathematical model containing variables and equations."""

    name: str
    variables: dict[str, ModelVariable] = field(default_factory=dict)
    equations: list[Equation] = field(default_factory=list)
    metadata: dict[str, Any] = field(default_factory=dict)
    # A subsystem is a child Model or a pure-I/O DataLoader (RFC
    # pure-io-data-loaders §4.3); ref subsystems are raw {"ref": ...} dicts
    # until resolve_subsystem_refs replaces them in place.
    subsystems: dict[str, Model | DataLoader] = field(default_factory=dict)
    # Boundary conditions are not a declared model concern: there is no `bc` op
    # and no `boundary_conditions` field. BCs are baked into the discretization
    # rewrite rules' `makearray` bodies (esm-spec §9.6.8); nothing to store here.
    # Model-level default numerical tolerance for inline tests (esm-spec §6.6).
    tolerance: Tolerance | None = None
    # Inline validation tests (esm-spec §6.6).
    tests: list[Test] = field(default_factory=list)
    # Inline illustrative examples (esm-spec §6.7).
    examples: list[Example] = field(default_factory=list)
    # Initialization-only equations (hold at t=0) and solver guesses (gt-ebuq).
    initialization_equations: list[Equation] = field(default_factory=list)
    guesses: dict[str, float | Expr] = field(default_factory=dict)
    # MTK system-kind discriminator: "ode" (default), "nonlinear", "sde", "pde".
    system_kind: str | None = None
    # Events owned by this model (schema nests events inside components; the
    # flat EsmFile.events view aggregates these same objects for consumers).
    continuous_events: list[ContinuousEvent] = field(default_factory=list)
    discrete_events: list[DiscreteEvent] = field(default_factory=list)


@dataclass
class Species:
    """A chemical species in a reaction system."""

    name: str
    units: str | None = None
    default: float | None = None
    default_units: str | None = None
    description: str | None = None
    formula: str | None = None  # Chemical formula
    constant: bool | None = None  # Reservoir species (held-fixed, no ODE)


@dataclass
class Parameter:
    """A parameter for reaction systems."""

    name: str
    value: float | Expr
    units: str | None = None
    default_units: str | None = None
    description: str | None = None
    uncertainty: float | None = None


@dataclass
class Reaction:
    """A chemical reaction."""

    name: str
    id: str | None = None
    # species -> coefficient. Values may be `int` or `float`: v0.2.x permits
    # fractional stoichiometries (e.g. `0.87 CH2O`). Parser preserves the
    # original JSON numeric type; serializer emits `int` for integer-valued
    # coefficients to keep integer fixtures byte-identical across round-trips.
    reactants: dict[str, int | float] = field(default_factory=dict)
    products: dict[str, int | float] = field(default_factory=dict)
    rate_constant: float | Expr | None = None
    conditions: dict[str, Any] = field(default_factory=dict)


@dataclass
class ReactionSystem:
    """A system of chemical reactions."""

    name: str
    species: list[Species] = field(default_factory=list)
    parameters: list[Parameter] = field(default_factory=list)
    reactions: list[Reaction] = field(default_factory=list)
    constraint_equations: list[Equation] = field(default_factory=list)
    subsystems: dict[str, ReactionSystem] = field(default_factory=dict)
    # Component-level default numerical tolerance for inline tests (esm-spec §6.6).
    tolerance: Tolerance | None = None
    # Inline validation tests (esm-spec §6.6).
    tests: list[Test] = field(default_factory=list)
    # Inline illustrative examples (esm-spec §6.7).
    examples: list[Example] = field(default_factory=list)
    # Events owned by this reaction system (schema nests events inside
    # components; the flat EsmFile.events view aggregates these same objects).
    continuous_events: list[ContinuousEvent] = field(default_factory=list)
    discrete_events: list[DiscreteEvent] = field(default_factory=list)


# ========================================
# 2b. Inline Tests, Examples, and Plots (esm-spec §6.6 / §6.7)
# ========================================


@dataclass
class Tolerance:
    """Numerical comparison tolerance. abs and/or rel may be set; an assertion
    passes when any set bound is satisfied."""

    abs: float | None = None
    rel: float | None = None


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
    tolerance: Tolerance | None = None
    coords: dict[str, float] | None = None
    reduce: str | None = None
    reference: Any | None = None


@dataclass
class Test:
    """Inline validation test for a Model or ReactionSystem."""

    id: str
    time_span: TimeSpan
    assertions: list[Assertion] = field(default_factory=list)
    description: str | None = None
    initial_conditions: dict[str, float] = field(default_factory=dict)
    parameter_overrides: dict[str, float] = field(default_factory=dict)
    tolerance: Tolerance | None = None
    # Raw §9.7.2 import entries injected into the ENCLOSING component's scope
    # for THIS test's run only (esm-spec §9.7.10 form C / §6.6.6): the
    # discretization a discretization-agnostic PDE leaf is lowered under in the
    # per-test ephemeral build. Authored per-run config — a peer of
    # `parameter_overrides` — so unlike a component's own imports it DOES
    # survive `parse → emit`. Empty for a non-PDE / agnostic-free test.
    expression_template_imports: list[Any] = field(default_factory=list)


@dataclass
class PlotAxis:
    """Axis specification for a plot."""

    variable: str
    label: str | None = None


@dataclass
class PlotValue:
    """Scalar value derived from a trajectory (e.g., for heatmap color)."""

    variable: str
    at_time: float | None = None
    reduce: str | None = None  # "max" | "min" | "mean" | "integral" | "final"


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
    description: str | None = None
    value: PlotValue | None = None
    series: list[PlotSeries] = field(default_factory=list)


@dataclass
class SweepRange:
    """Generated range of parameter values."""

    start: float
    stop: float
    count: int
    scale: str | None = None  # "linear" | "log"


@dataclass
class SweepDimension:
    """One axis of a parameter sweep; exactly one of values or range is set."""

    parameter: str
    values: list[float] | None = None
    range: SweepRange | None = None


@dataclass
class ParameterSweep:
    """Parameter sweep specification (currently only Cartesian)."""

    type: str  # "cartesian"
    dimensions: list[SweepDimension] = field(default_factory=list)


@dataclass
class Example:
    """Inline illustrative example of how to run a component."""

    id: str
    time_span: TimeSpan
    description: str | None = None
    # Scalar initial-value overrides for this example run, keyed by state-variable
    # name. A component's initial fields are declared with `ic` op equations in the
    # model (esm-spec §11.4); this map overrides their scalar values for this run.
    initial_state: dict[str, float] | None = None
    parameters: dict[str, float] = field(default_factory=dict)
    parameter_sweep: ParameterSweep | None = None
    plots: list[Plot] = field(default_factory=list)
    # esm-spec §9.7.10 form C: raw §9.7.2 import entries naming the
    # discretization this example runs under. Retained (not consumed at load)
    # so the field survives round-trip, mirroring Test.expression_template_imports.
    expression_template_imports: list[Any] = field(default_factory=list)


# ========================================
# 3. Event System
# ========================================


@dataclass
class FunctionalAffect:
    """A functional effect applied during an event."""

    handler_id: str
    read_vars: list[str] = field(default_factory=list)
    read_params: list[str] = field(default_factory=list)
    modified_params: list[str] = field(default_factory=list)
    config: dict[str, Any] = field(default_factory=dict)


@dataclass
class ContinuousEvent:
    """An event that occurs when a condition becomes true during continuous evolution."""

    name: str
    conditions: list[Expr] = field(default_factory=list)  # Changed from single condition to array
    affects: list[AffectEquation | FunctionalAffect] = field(default_factory=list)
    affect_neg: list[AffectEquation | FunctionalAffect] | None = (
        None  # Added: affects for negative-going zero crossings
    )
    root_find: Literal["left", "right", "all"] | None = (
        "left"  # Added: root-finding direction with default
    )
    reinitialize: bool = False  # Added: whether to reinitialize after event
    priority: int = 0
    description: str | None = None  # Added: optional description


@dataclass
class DiscreteEventTrigger:
    """Trigger condition for a discrete event."""

    type: Literal["condition", "periodic", "preset_times"]
    value: float | Expr | str  # time value, condition expression, or external identifier


@dataclass
class DiscreteEvent:
    """An event that occurs at discrete time points."""

    name: str
    trigger: DiscreteEventTrigger
    affects: list[AffectEquation | FunctionalAffect] = field(default_factory=list)
    priority: int = 0
    # Parameters this event may modify (implicitly discrete parameters).
    discrete_parameters: list[str] = field(default_factory=list)
    reinitialize: bool = False
    description: str | None = None


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

    endian: str | None = None  # "little" | "big"
    float_format: str | None = None  # "ieee754_single" | "ieee754_double"
    integer_width: int | None = None  # 32 | 64


@dataclass
class DataLoaderSource:
    """File discovery configuration for a data loader."""

    url_template: str
    mirrors: list[str] = field(default_factory=list)


@dataclass
class DataLoaderTemporal:
    """Temporal coverage and record layout for a data source."""

    start: str | None = None
    end: str | None = None
    file_period: str | None = None
    frequency: str | None = None
    records_per_file: int | str | None = None
    time_variable: str | None = None


@dataclass
class DataLoaderVariable:
    """A variable exposed by a data loader, mapped from a source-file variable."""

    file_variable: str
    units: str
    unit_conversion: float | int | Expr | None = None
    description: str | None = None
    reference: Reference | None = None


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
    variables: dict[str, DataLoaderVariable] = field(default_factory=dict)
    temporal: DataLoaderTemporal | None = None
    determinism: DataLoaderDeterminism | None = None
    reference: Reference | None = None
    metadata: dict[str, Any] = field(default_factory=dict)


@dataclass
class Operator:
    """A registered runtime operator (e.g., dry deposition, wet scavenging)."""

    operator_id: str
    needed_vars: list[str]
    # The operators-map key this entry was declared under (like Model /
    # ReactionSystem / DataLoader carry). Set at parse time; the serializer
    # re-emits the operator under it.
    name: str = ""
    modifies: list[str] | None = None
    reference: Reference | None = None
    config: dict[str, Any] = field(default_factory=dict)
    description: str | None = None


@dataclass
class RegisteredFunctionSignature:
    """Calling convention for a RegisteredFunction (see esm-spec §9.2)."""

    arg_count: int
    arg_types: list[str] | None = None
    return_type: str | None = None


@dataclass
class RegisteredFunction:
    """A named pure function invoked inside expressions via the 'call' op."""

    id: str
    signature: RegisteredFunctionSignature
    units: str | None = None
    arg_units: list[str | None] | None = None
    description: str | None = None
    references: list[Reference] = field(default_factory=list)
    config: dict[str, Any] = field(default_factory=dict)


class CouplingType(Enum):
    """Types of coupling between model components matching ESM schema."""

    OPERATOR_COMPOSE = "operator_compose"
    COUPLE = "couple"
    VARIABLE_MAP = "variable_map"
    OPERATOR_APPLY = "operator_apply"
    CALLBACK = "callback"
    EVENT = "event"
    # A `coupling_import` entry references a coupling-library file and binds its
    # declared roles to assembly components (esm-spec §10.10). It carries no
    # wiring of its own; at flatten it expands into concrete edges.
    COUPLING_IMPORT = "coupling_import"


@dataclass
class ConnectorEquation:
    """Single equation in a connector system."""

    from_var: str
    to_var: str
    transform: str
    expression: Expr | None = None


@dataclass
class Connector:
    """Connector system with equations."""

    equations: list[ConnectorEquation] = field(default_factory=list)


# Base class for all coupling entries
@dataclass
class BaseCouplingEntry:
    """Base class for all coupling entry types."""

    coupling_type: CouplingType
    description: str | None = None


@dataclass
class OperatorComposeCoupling(BaseCouplingEntry):
    """Coupling entry for operator_compose type."""

    coupling_type: CouplingType = field(default=CouplingType.OPERATOR_COMPOSE, init=False)
    systems: list[str] = field(default_factory=list)
    translate: dict[str, Any] = field(default_factory=dict)
    # Spatial-lift strategy (esm-spec §10.5). ``"pointwise"`` requests the
    # flattener array-ify each merged reaction+operator state ODE onto the grid
    # (per-cell reaction evaluation). None ⇒ no lift (0-D / already-array system).
    lifting: str | None = None


@dataclass
class CouplingCouple(BaseCouplingEntry):
    """Coupling entry for couple type."""

    coupling_type: CouplingType = field(default=CouplingType.COUPLE, init=False)
    systems: list[str] = field(default_factory=list)
    connector: Connector | None = None


@dataclass
class VariableMapCoupling(BaseCouplingEntry):
    """Coupling entry for variable_map type."""

    coupling_type: CouplingType = field(default=CouplingType.VARIABLE_MAP, init=False)
    from_var: str | None = None
    to_var: str | None = None
    # EITHER one of the legacy enum strings ("param_to_var", "identity",
    # "additive", "multiplicative", "conversion_factor") OR an ExpressionNode
    # (in-progress-0.8.0 widening; operator-node object only on the wire).
    # An expression transform must reference the entry's `from` variable and
    # takes no `factor`; every variable reference inside it is already a
    # fully-scoped reference into the flattened coupled system.
    transform: str | Expr | None = None
    factor: float | None = None


@dataclass
class OperatorApplyCoupling(BaseCouplingEntry):
    """Coupling entry for operator_apply type."""

    coupling_type: CouplingType = field(default=CouplingType.OPERATOR_APPLY, init=False)
    operator: str | None = None


@dataclass
class CallbackCoupling(BaseCouplingEntry):
    """Coupling entry for callback type."""

    coupling_type: CouplingType = field(default=CouplingType.CALLBACK, init=False)
    callback_id: str | None = None
    config: dict[str, Any] = field(default_factory=dict)


@dataclass
class EventCoupling(BaseCouplingEntry):
    """Coupling entry for event type."""

    coupling_type: CouplingType = field(default=CouplingType.EVENT, init=False)
    event_type: str | None = None
    conditions: list[Expr] = field(default_factory=list)
    trigger: DiscreteEventTrigger | None = None
    affects: list[AffectEquation] = field(default_factory=list)
    affect_neg: list[AffectEquation] = field(default_factory=list)
    discrete_parameters: list[str] = field(default_factory=list)
    root_find: str | None = None
    reinitialize: bool | None = None


@dataclass
class CouplingImport(BaseCouplingEntry):
    """Coupling entry that imports a coupling-library file (esm-spec §10.10).

    ``ref`` is a §4.7 reference to a coupling-library file (a document with a
    top-level ``coupling_roles`` map); ``bind`` maps every declared role name to
    an assembly component (a top-level models/reaction_systems/data_loaders key
    or a dotted ``Parent.Child`` subsystem path). The entry declares no wiring of
    its own — at flatten (:mod:`earthsci_ast.coupling_imports`) it expands into
    concrete edges spliced in its position, while the source entry is preserved
    for round-trip.
    """

    coupling_type: CouplingType = field(default=CouplingType.COUPLING_IMPORT, init=False)
    ref: str | None = None
    bind: dict[str, str] = field(default_factory=dict)


# Discriminated union of all coupling entry types
CouplingEntry = Union[
    OperatorComposeCoupling,
    CouplingCouple,
    VariableMapCoupling,
    OperatorApplyCoupling,
    CallbackCoupling,
    EventCoupling,
    CouplingImport,
]


# ========================================
# 5. Computational Domain and Solving
# ========================================


@dataclass
class TemporalDomain:
    """Temporal domain specification."""

    start: str | None = None  # ISO datetime string
    end: str | None = None  # ISO datetime string
    reference_time: str | None = None  # ISO datetime string


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

    name: str | None = None
    independent_variable: str | None = None
    temporal: TemporalDomain | None = None

    # Legacy support for backwards compatibility
    dimensions: dict[str, Any] | None = None
    coordinates: dict[str, list[float]] = field(default_factory=dict)
    boundaries: dict[str, Any] = field(default_factory=dict)


# ========================================
# 6. Metadata and File Structure
# ========================================


@dataclass
class Reference:
    """Bibliographic reference."""

    title: str
    authors: list[str] = field(default_factory=list)
    journal: str | None = None
    year: int | None = None
    doi: str | None = None
    url: str | None = None


@dataclass
class Metadata:
    """Metadata about the model or dataset."""

    title: str
    description: str | None = None
    authors: list[str] = field(default_factory=list)
    created: str | None = None  # ISO datetime string
    modified: str | None = None  # ISO datetime string
    version: str = "1.0"
    references: list[Reference] = field(default_factory=list)
    keywords: list[str] = field(default_factory=list)
    custom: dict[str, Any] = field(default_factory=dict)

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
    values: list[float]
    units: str | None = None


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

    axes: list[FunctionTableAxis]
    data: Any  # Nested-array literal of finite numbers
    description: str | None = None
    interpolation: str | None = None  # 'linear' | 'bilinear' | 'nearest'
    out_of_bounds: str | None = None  # 'clamp' | 'error'
    outputs: list[str] | None = None
    shape: list[int] | None = None
    schema_version: str | None = None


@dataclass
class EsmFile:
    """Root container for an ESM format file."""

    version: str
    metadata: Metadata
    models: dict[str, Model] = field(default_factory=dict)
    reaction_systems: dict[str, ReactionSystem] = field(default_factory=dict)
    events: list[ContinuousEvent | DiscreteEvent] = field(default_factory=list)
    data_loaders: dict[str, DataLoader] = field(default_factory=dict)
    operators: list[Operator] = field(default_factory=list)
    registered_functions: dict[str, RegisteredFunction] = field(default_factory=dict)
    coupling: list[CouplingEntry] = field(default_factory=list)
    # File-local enum mappings for the `enum` AST op (esm-spec §9.3). Keyed by
    # enum name; each value maps symbolic names to positive integers. Resolved
    # at load time by `lower_enums` before expression evaluation.
    enums: dict[str, dict[str, int]] = field(default_factory=dict)
    # Component-scoped sampled function tables (esm-spec §9.5, v0.4.0). Keyed
    # by table id; each value is a FunctionTable referenced by table_lookup
    # AST nodes.
    function_tables: dict[str, FunctionTable] = field(default_factory=dict)
    # A single shared spatiotemporal domain (v0.8.0). Spatiality of individual
    # variables is expressed via their ``shape``; there is one domain per file,
    # not a map of named domains.
    domain: Domain | None = None
    # Document-scoped registry of named index sets (RFC semiring-faq-unified-ir
    # §5.2), keyed by name — the single, document-level declaration site for
    # every iteration domain shared by all models in the file. Each entry is an
    # IndexSet dict: interval / categorical / derived / ragged. Referenced from
    # aggregate range specs of the form {"from": <name>} and from variable
    # ``shape`` lists. Moved here from ``Model`` in v0.8.0.
    index_sets: dict[str, Any] = field(default_factory=dict)
    # Top-level DECLARATIONS (esm-spec §9.7.1), peers of `index_sets`. Option A
    # expands `apply_expression_template` CALL SITES; it does NOT delete these
    # declarations (§9.6.4 rule 5). They survive `parse -> emit` verbatim, which
    # is what makes a pure TEMPLATE-LIBRARY file — one carrying only these — a
    # representable document kind: dropping them emitted `{esm, metadata,
    # index_sets}`, which carries none of the five top-level payload keys and so
    # fails the schema's top-level `anyOf`. The file was legal on disk and
    # illegal the moment it was loaded and re-emitted.
    expression_templates: dict[str, Any] = field(default_factory=dict)
    metaparameters: dict[str, Any] = field(default_factory=dict)

    @property
    def esm(self) -> str:
        """Alias for version field (matches JSON 'esm' key)."""
        return self.version
