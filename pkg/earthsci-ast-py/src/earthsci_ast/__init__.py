"""
ESM Format - Earth System Model Serialization Format

A Python package for handling Earth System Model serialization and mathematical expressions.
This is the core implementation of the ESM Library Specification (see ``esm-spec.md``);
the supported format version is tracked by ``earthsci_ast.parse._CURRENT_VERSION``.
"""
from __future__ import annotations

from importlib.metadata import PackageNotFoundError, version as _pkg_version

# Base exception
from .errors import EarthSciAstError

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
    DataLoaderVariable,
    DataLoaderDeterminism,
    Operator,
    CouplingEntry,
    CouplingImport,
    Domain,
    TemporalDomain,
    Reference,
    Metadata,
    EsmFile,
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
    resolve_model_refs,
)
from .serialize import save

# Expression-template expansion (esm-spec §9.6) and template-library imports
# + load-time metaparameters (esm-spec §9.7 /
# docs/content/rfcs/template-library-imports.md).
from .lower_expression_templates import (
    ExpressionTemplateError,
    lower_expression_templates,
    reject_expression_templates_pre_v04,
)
from .template_imports import (
    MAX_TEMPLATE_EXPANSION_DEPTH,
    reject_template_imports_pre_v08,
    resolve_template_machinery,
)

# Coupling-library files + `coupling_import` role binding (esm-spec §10.9–§10.11;
# docs/content/rfcs/coupling-libraries-role-binding.md).
from .coupling_imports import (
    expand_coupling_imports,
    is_coupling_library_doc,
)

# Coupled system flattening (spec §4.7.5 + §4.7.6)
from .flatten import (
    flatten,
    FlattenedSystem,
    FlattenedEquation,
    FlattenedVariable,
    LoaderField,
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

# Expression engine (Core tier requirement)
from .expression import (
    free_variables,
    free_parameters,
    contains,
    simplify,
    to_sympy,
    from_sympy,
    symbolic_jacobian as jacobian,
)

# Scalar expression evaluator — the official ESS Python runner entry point
from .numpy_interpreter import evaluate

# Substitution (Core tier requirement)
from .substitute import (
    substitute,
    substitute_in_model,
    substitute_in_reaction_system,
    expand_equation_placeholders,
    has_var_placeholder,
)

# Analysis tier - reaction system analysis
from .reactions import (
    derive_odes,
    stoichiometric_matrix,
    substrate_matrix,
    product_matrix,
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

# Conservative-regridding geometry kernel — the intersect_polygon clip leaf +
# the polygon_area reference (RFC semiring-faq-unified-ir §8.1 / Appendix B;
# CONFORMANCE_SPEC.md §5.8). polygon_area itself is an ordinary sum_product FAQ;
# the helper here is the reference the FAQ is cross-checked against.
from .geometry import (
    GeometryError,
    GeometryBackendUnavailable,
    intersect_polygon,
    polygon_area,
    densify_parallel_edges,
    area_tolerance_ok,
    MANIFOLDS,
)

# polygon_area as a sum_product FAQ over the clipped ring — the executable form of
# the area FAQ, evaluated through the same interpreter the array simulator uses
# (RFC semiring-faq-unified-ir §8.1; bead ess-d4g.1). The imperative polygon_area
# above is its cross-check oracle. The end-to-end conservative-regridding pipeline
# now lives as a single evaluable document
# (tests/valid/geometry/conservative_regrid_overlap_join.esm) driven through the
# evaluator, not an imperative Python assembly (bead ess-3lj.3).
from .area_faq import polygon_area_via_faq

# Build-time cadence-partition pass — the structural_simplify analogue (RFC
# semiring-faq-unified-ir §6.1; CONFORMANCE_SPEC.md §5.7)
from .cadence import (
    CadenceError,
    Partition,
    partition,
)

# Build-time value-invention front-door — derived index-sets (skolem/distinct/
# rank) resolved via the relational engine, ONCE at setup (RFC §6.1 / §5.5).
from .value_invention import (
    ValueInventionError,
    ValueInventionResult,
    materialize_value_invention,
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
    merge_esm_files,
    extract_component_from_file,
)

# Simulation tier - box-model ODE and discretized-PDE simulation.
# scipy is a HARD dependency (declared unconditionally in pyproject.toml), so this
# import normally succeeds; the try/except is belt-and-suspenders that degrades
# gracefully in a broken/partial install rather than a real optionality knob.
_has_simulation = False
try:
    from .simulation import (  # noqa: F401 — re-exported via __all__ below
        simulate,
        simulate_with_discrete_events,
        evaluate_rhs,
        BuildInspection,
        SimulationResult,
        SimulationError,
    )

    _has_simulation = True
except ImportError:
    # scipy (a hard dep) missing only in a broken install; skip the sim tier.
    pass

# Display and pretty-printing (Core tier requirement)
from .display import (
    to_unicode,
    to_latex,
    to_ascii,
)

# Code generation (for interoperability)
from .codegen import (
    to_julia_code,
    to_python_code,
)

# Migration functionality (v0.1 → v0.2 dict-level transform behind esm-migrate)
from .migration import (
    migrate_file_0_1_to_0_2,
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
    CacheMiss,
    cache_path_for_url,
    cached_fetcher,
    cached_opener,
    resolve_data_dir,
    UnitConversionError,
    apply_variable_mapping,
    apply_unit_conversion,
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

# Single source of truth: the installed distribution metadata (pyproject.toml).
# Falls back gracefully when the package is imported from a source tree that
# was never installed (e.g. `PYTHONPATH=src`).
try:
    __version__ = _pkg_version("earthsci-ast")
except PackageNotFoundError:  # pragma: no cover - source-tree import
    __version__ = "0.0.0+unknown"

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
    "DataLoaderVariable",
    "DataLoaderDeterminism",
    "Operator",
    "CouplingEntry",
    "CouplingImport",
    "Domain",
    "TemporalDomain",
    "Reference",
    "Metadata",
    "EsmFile",
    "FunctionTable",
    "FunctionTableAxis",
    # Core parsing and serialization
    "load",
    "save",
    "resolve_subsystem_refs",
    "resolve_model_refs",
    # Expression templates (esm-spec §9.6) + template-library imports and
    # load-time metaparameters (esm-spec §9.7)
    "ExpressionTemplateError",
    "lower_expression_templates",
    "reject_expression_templates_pre_v04",
    "MAX_TEMPLATE_EXPANSION_DEPTH",
    "reject_template_imports_pre_v08",
    "resolve_template_machinery",
    "EarthSciAstError",
    # Coupling-library files + `coupling_import` role binding (esm-spec §10.9–§10.11)
    "expand_coupling_imports",
    "is_coupling_library_doc",
    # Validation
    "validate",
    "ValidationResult",
    "ValidationError",
    "SchemaValidationError",
    "UnsupportedVersionError",
    "CircularReferenceError",
    "SubsystemRefError",
    # Coupled system flattening (spec §4.7.5 + §4.7.6)
    "flatten",
    "FlattenedSystem",
    "FlattenedEquation",
    "FlattenedVariable",
    "LoaderField",
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
    "expand_equation_placeholders",
    "has_var_placeholder",
    # Reaction system analysis
    "derive_odes",
    "stoichiometric_matrix",
    "substrate_matrix",
    "product_matrix",
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
    # Conservative-regridding geometry kernel (intersect_polygon + polygon_area)
    "GeometryError",
    "GeometryBackendUnavailable",
    "intersect_polygon",
    "polygon_area",
    "densify_parallel_edges",
    "area_tolerance_ok",
    "MANIFOLDS",
    # polygon_area as a sum_product FAQ over the clipped ring (ess-d4g.1)
    "polygon_area_via_faq",
    # Build-time cadence-partition pass (structural_simplify analogue)
    "CadenceError",
    "Partition",
    "partition",
    # Build-time value-invention front-door (derived index-sets via relational engine)
    "ValueInventionError",
    "ValueInventionResult",
    "materialize_value_invention",
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
    "merge_esm_files",
    "extract_component_from_file",
    # Display and pretty-printing
    "to_unicode",
    "to_latex",
    "to_ascii",
    # Code generation
    "to_julia_code",
    "to_python_code",
    # Migration functionality
    "migrate_file_0_1_to_0_2",
    "MigrationError",
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
    "CacheMiss",
    "cache_path_for_url",
    "cached_fetcher",
    "cached_opener",
    "resolve_data_dir",
    "UnitConversionError",
    "apply_variable_mapping",
    "apply_unit_conversion",
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

# Add simulation components (scipy is a hard dep, so this normally runs; guarded
# only for a broken/partial install — see the import block above).
if _has_simulation:
    __all__.extend(
        [
            "simulate",
            "simulate_with_discrete_events",
            "evaluate_rhs",
            "BuildInspection",
            "SimulationResult",
            "SimulationError",
        ]
    )
