"""
ESM Format - Earth System Model Serialization Format

A Python package for handling Earth System Model serialization and mathematical expressions.
This is the core implementation following the ESM Library Specification v0.1.0.
"""

# Core data types
from .esm_types import (
    Expr,
    ExprNode,
    Equation,
    AffectEquation,
    ModelVariable,
    Model,
    Species,
    Parameter,
    Reaction,
    ReactionSystem,
    ContinuousEvent,
    DiscreteEvent,
    FunctionalAffect,
    DiscreteEventTrigger,
    DataLoader,
    DataLoaderKind,
    DataLoaderSource,
    DataLoaderTemporal,
    DataLoaderSpatial,
    DataLoaderVariable,
    DataLoaderRegridding,
    DataLoaderMesh,
    DataLoaderMeshTopology,
    DataLoaderDeterminism,
    Operator,
    CouplingEntry,
    Domain,
    TemporalDomain,
    SpatialDimension,
    CoordinateTransform,
    InitialCondition,
    InitialConditionType,
    BoundaryCondition,
    BoundaryConditionKind,
    BCContributedBy,
    Reference,
    Metadata,
    EsmFile,
    StaggeringRule,
    FunctionTable,
    FunctionTableAxis,
)

# Core parsing and serialization
from .parse import (
    load,
    SchemaValidationError,
    UnsupportedVersionError,
    CircularReferenceError,
    SubsystemRefError,
    resolve_subsystem_refs,
)
from .serialize import save

# Coupled system flattening (spec §4.7.5 + §4.7.6)
from .flatten import (
    flatten,
    FlattenedSystem,
    FlattenedEquation,
    FlattenedVariable,
    FlattenMetadata,
    FlattenError,
    ConflictingDerivativeError,
    DimensionPromotionError,
    UnmappedDomainError,
    UnsupportedMappingError,
    DomainUnitMismatchError,
    DomainExtentMismatchError,
    SliceOutOfDomainError,
    CyclicPromotionError,
    UnsupportedDimensionalityError,
)

# Validation (Core tier requirement)
from .validation import validate, ValidationResult, ValidationError

# Discretization pipeline / RFC §12 DAE binding contract
from .discretize import discretize, DiscretizationError

# Grid accessor ABC + registry (ESD registers concrete family impls)
from .grid_accessor import (
    GridAccessor,
    GridAccessorError,
    UnknownGridFamilyError,
    GridAccessorRegistrationError,
    GridAccessorFactory,
    register_grid_accessor,
    unregister_grid_accessor,
    has_grid_accessor,
    registered_grid_families,
    get_grid_accessor,
)

# Expression engine (Core tier requirement)
from .expression import (
    free_variables,
    free_parameters,
    contains,
    simplify,
    to_sympy,
    from_sympy,
    symbolic_jacobian as jacobian
)

# Scalar expression evaluator — the official ESS Python runner entry point
from .numpy_interpreter import evaluate

# Substitution (Core tier requirement)
from .substitute import (
    substitute,
    substitute_in_model,
    substitute_in_reaction_system,
    expand_var_placeholders,
    expand_equation_placeholders,
    has_var_placeholder,
    get_state_variables,
    expand_model_placeholders,
    process_operator_compose_placeholders,
)

# Analysis tier - reaction system analysis
from .reactions import (
    derive_odes,
    stoichiometric_matrix,
    substrate_matrix,
    product_matrix,
)

# Analysis tier - graph representations
from .graph import (
    component_graph,
    expression_graph,
    to_dot,
    to_mermaid,
    to_json_graph,
    Graph,
    GraphNode,
    GraphEdge,
    ComponentNode,
    VariableNode,
    CouplingEdge,
    DependencyEdge,
)

# Analysis tier - reference resolution (semiring-FAQ node addressing, RFC §6.1)
from .reference_resolution import (
    build_reference_graph,
    resolve_references,
    ReferenceGraph,
    ReferenceVertex,
    ReferenceEdge,
    ReferenceResolutionError,
    VertexKind,
    EdgeKind,
)
# Build-time relational engine — value-invention primitives (RFC
# semiring-faq-unified-ir §5.5; CONFORMANCE_SPEC.md §5.5)
from .relational import (
    FloatKeyError,
    skolem,
    skolem_edge,
    distinct,
    rank,
    Ranking,
    equijoin,
    group_aggregate,
    canonical_index_set_json,
    serialize_canonical,
)

# Build-time cadence-partition pass — the structural_simplify analogue (RFC
# semiring-faq-unified-ir §6.1; CONFORMANCE_SPEC.md §5.7)
from .cadence import (
    CadenceError,
    Partition,
    partition,
)

# Analysis tier - unit validation
from .units import (
    validate_units,
    convert_units,
    UnitValidator,
    UnitValidationResult,
    UnitConversionResult,
)

# Core editing operations
from .edit import (
    ESMEditor,
    EditOperation,
    EditResult,
    add_model_to_file,
    add_variable_to_model,
    rename_variable_in_model,
    remove_variable_from_model,
    add_equation_to_model,
    remove_equation_from_model,
    add_reaction_to_system,
    remove_reaction_from_system,
    add_species_to_system,
    remove_species_from_system,
    add_continuous_event_to_model,
    add_discrete_event_to_model,
    remove_event_from_model,
    add_coupling_to_file,
    remove_coupling_from_file,
    compose_systems,
    map_variable_in_file,
    merge_esm_files,
    extract_component_from_file,
)

# Simulation tier - box model simulation (optional - requires scipy)
_has_simulation = False
try:
    from .simulation import (
        simulate,
        simulate_with_discrete_events,
        SimulationResult,
        SimulationError,
    )
    _has_simulation = True
except (ImportError, ValueError, Exception):
    # scipy not available or compatibility issues, skip simulation functionality
    pass

# Display and pretty-printing (Core tier requirement)
from .display import (
    explore,
    ESMExplorer,
    to_unicode,
    to_latex,
    to_ascii,
)

# Code generation (for interoperability)
from .codegen import (
    to_julia_code,
    to_python_code,
)

# Migration functionality
from .migration import (
    migrate,
    migrate_file_0_1_to_0_2,
    can_migrate,
    get_supported_migration_targets,
    MigrationError,
)

# Runtime data loaders (dispatch on DataLoader.kind)
from .data_loaders import (
    UrlTemplateError,
    expand_url_template,
    expand_with_mirrors,
    template_placeholders,
    TimeResolutionError,
    parse_iso_duration,
    file_anchor_for_time,
    file_anchors_in_range,
    records_for_file,
    MirrorFallbackError,
    open_with_fallback,
    UnitConversionError,
    apply_variable_mapping,
    apply_unit_conversion,
    RegriddingError,
    regrid_latlon_to_target,
    GridLoaderError,
    GridLoader,
    load_grid,
    PointsLoaderError,
    PointsLoader,
    load_points,
    StaticLoaderError,
    StaticLoader,
    load_static,
    DataLoaderDispatchError,
    load_data,
    resolve_files,
)

# Operator registry functionality (Core tier requirement)
from .operator_registry import (
    register_operator,
    has_operator,
    get_operator_registry,
    create_operator,
    create_operator_by_name,
    list_all_operators,
    get_operator_info,
    unregister_operator,
    OperatorRegistry,
    OperatorSignature,
    RegisteredOperator,
    OperatorRegistryError,
    OperatorValidationError,
)

__version__ = "0.1.0"

# Optional analytics — no-op when the `monitoring` companion package is absent
# or ESM_ANALYTICS_ENABLED is disabled. See src/earthsci_toolkit/_monitoring.py.
from ._monitoring import initialize_if_enabled as _init_analytics

_init_analytics("earthsci-toolkit", __version__)
del _init_analytics

# Streamlined public API - only Core + Analysis + Simulation tier functionality
__all__ = [
    # Core data types
    "Expr",
    "ExprNode",
    "Equation",
    "AffectEquation",
    "ModelVariable",
    "Model",
    "Species",
    "Parameter",
    "Reaction",
    "ReactionSystem",
    "ContinuousEvent",
    "DiscreteEvent",
    "FunctionalAffect",
    "DiscreteEventTrigger",
    "DataLoader",
    "DataLoaderKind",
    "DataLoaderSource",
    "DataLoaderTemporal",
    "DataLoaderSpatial",
    "DataLoaderVariable",
    "DataLoaderRegridding",
    "DataLoaderMesh",
    "DataLoaderMeshTopology",
    "DataLoaderDeterminism",
    "Operator",
    "CouplingEntry",
    "Domain",
    "TemporalDomain",
    "SpatialDimension",
    "CoordinateTransform",
    "InitialCondition",
    "InitialConditionType",
    "BoundaryCondition",
    "BoundaryConditionKind",
    "BCContributedBy",
    "Reference",
    "Metadata",
    "EsmFile",
    "FunctionTable",
    "FunctionTableAxis",

    # Core parsing and serialization
    "load",
    "save",
    "resolve_subsystem_refs",

    # Validation
    "validate",
    "ValidationResult",
    "ValidationError",
    "SchemaValidationError",
    "UnsupportedVersionError",
    "CircularReferenceError",
    "SubsystemRefError",

    # Discretization / DAE binding contract (RFC §12)
    "discretize",
    "DiscretizationError",

    # Grid accessor ABC + registry (gt-6trd)
    "GridAccessor",
    "GridAccessorError",
    "UnknownGridFamilyError",
    "GridAccessorRegistrationError",
    "GridAccessorFactory",
    "register_grid_accessor",
    "unregister_grid_accessor",
    "has_grid_accessor",
    "registered_grid_families",
    "get_grid_accessor",

    # Coupled system flattening (spec §4.7.5 + §4.7.6)
    "flatten",
    "FlattenedSystem",
    "FlattenedEquation",
    "FlattenedVariable",
    "FlattenMetadata",
    "FlattenError",
    "ConflictingDerivativeError",
    "DimensionPromotionError",
    "UnmappedDomainError",
    "UnsupportedMappingError",
    "DomainUnitMismatchError",
    "DomainExtentMismatchError",
    "SliceOutOfDomainError",
    "CyclicPromotionError",
    "UnsupportedDimensionalityError",

    # Expression engine
    "free_variables",
    "free_parameters",
    "contains",
    "simplify",
    "to_sympy",
    "from_sympy",
    "jacobian",
    "evaluate",

    # Substitution
    "substitute",
    "substitute_in_model",
    "substitute_in_reaction_system",
    "expand_var_placeholders",
    "expand_equation_placeholders",
    "has_var_placeholder",
    "get_state_variables",
    "expand_model_placeholders",
    "process_operator_compose_placeholders",

    # Reaction system analysis
    "derive_odes",
    "stoichiometric_matrix",
    "substrate_matrix",
    "product_matrix",

    # Graph representations
    "component_graph",
    "expression_graph",
    "to_dot",
    "to_mermaid",
    "to_json_graph",
    "Graph",
    "GraphNode",
    "GraphEdge",
    "ComponentNode",
    "VariableNode",
    "CouplingEdge",
    "DependencyEdge",

    # Reference resolution (semiring-FAQ node addressing, RFC §6.1)
    "build_reference_graph",
    "resolve_references",
    "ReferenceGraph",
    "ReferenceVertex",
    "ReferenceEdge",
    "ReferenceResolutionError",
    "VertexKind",
    "EdgeKind",
    # Build-time relational engine (value-invention primitives)
    "FloatKeyError",
    "skolem",
    "skolem_edge",
    "distinct",
    "rank",
    "Ranking",
    "equijoin",
    "group_aggregate",
    "canonical_index_set_json",
    "serialize_canonical",
    # Build-time cadence-partition pass (structural_simplify analogue)
    "CadenceError",
    "Partition",
    "partition",

    # Unit validation
    "validate_units",
    "convert_units",
    "UnitValidator",
    "UnitValidationResult",
    "UnitConversionResult",

    # Editing operations
    "ESMEditor",
    "EditOperation",
    "EditResult",
    "add_model_to_file",
    "add_variable_to_model",
    "rename_variable_in_model",
    "remove_variable_from_model",
    "add_equation_to_model",
    "remove_equation_from_model",
    "add_reaction_to_system",
    "remove_reaction_from_system",
    "add_species_to_system",
    "remove_species_from_system",
    "add_continuous_event_to_model",
    "add_discrete_event_to_model",
    "remove_event_from_model",
    "add_coupling_to_file",
    "remove_coupling_from_file",
    "compose_systems",
    "map_variable_in_file",
    "merge_esm_files",
    "extract_component_from_file",


    # Display and pretty-printing
    "explore",
    "ESMExplorer",
    "to_unicode",
    "to_latex",
    "to_ascii",

    # Code generation
    "to_julia_code",
    "to_python_code",

    # Migration functionality
    "migrate",
    "can_migrate",
    "get_supported_migration_targets",
    "MigrationError",

    # Operator registry functionality
    "register_operator",
    "has_operator",
    "get_operator_registry",
    "create_operator",
    "create_operator_by_name",
    "list_all_operators",
    "get_operator_info",
    "unregister_operator",
    "OperatorRegistry",
    "OperatorSignature",
    "RegisteredOperator",
    "OperatorRegistryError",
    "OperatorValidationError",

    # Runtime data loaders
    "UrlTemplateError",
    "expand_url_template",
    "expand_with_mirrors",
    "template_placeholders",
    "TimeResolutionError",
    "parse_iso_duration",
    "file_anchor_for_time",
    "file_anchors_in_range",
    "records_for_file",
    "MirrorFallbackError",
    "open_with_fallback",
    "UnitConversionError",
    "apply_variable_mapping",
    "apply_unit_conversion",
    "RegriddingError",
    "regrid_latlon_to_target",
    "GridLoaderError",
    "GridLoader",
    "load_grid",
    "PointsLoaderError",
    "PointsLoader",
    "load_points",
    "StaticLoaderError",
    "StaticLoader",
    "load_static",
    "DataLoaderDispatchError",
    "load_data",
    "resolve_files",
]

# Add simulation components if scipy is available
if _has_simulation:
    __all__.extend([
        "simulate",
        "simulate_with_discrete_events",
        "SimulationResult",
        "SimulationError",
    ])