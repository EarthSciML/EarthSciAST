//! Top-level validation surface for ESM files.
//!
//! This module owns the public [`ValidationResult`] / [`SchemaError`] /
//! [`StructuralError`] types and the orchestrator entry points
//! ([`validate`], [`validate_complete`], [`validate_with_schema`]). The
//! actual checks are delegated to:
//!
//! - [`crate::structural`] — equation balance, model references, reactions,
//!   discrete events, and inter-model dependency cycles.
//! - [`crate::coupling`] — coupling-entry well-formedness and scoped
//!   references between systems.
//!
//! The [`SystemInfo`] map produced by [`build_system_reference_map`] is the
//! shared input both submodules consume.

use crate::EsmFile;
use crate::parse::{LoadOptions, load, load_with_options};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{HashMap, HashSet};

/// Result of structural validation
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ValidationResult {
    /// Schema validation errors
    pub schema_errors: Vec<SchemaError>,
    /// Structural validation errors
    pub structural_errors: Vec<StructuralError>,
    /// Dimensional-analysis findings that did not invalidate the document
    /// (see [`UnitWarning`]).
    pub unit_warnings: Vec<UnitWarning>,
    /// Whether validation passed (no schema or structural errors)
    pub is_valid: bool,
}

impl ValidationResult {
    /// Check if there are any errors (schema or structural)
    pub fn has_errors(&self) -> bool {
        !self.schema_errors.is_empty() || !self.structural_errors.is_empty()
    }

    /// Structural errors, cloned (legacy shim: prefer reading
    /// `structural_errors` — and `schema_errors`, which this does NOT
    /// include — directly).
    #[deprecated(note = "read the structural_errors / schema_errors fields directly")]
    pub fn errors(&self) -> Vec<StructuralError> {
        self.structural_errors.clone()
    }
}

/// A dimensional-analysis finding surfaced by validation.
///
/// Despite the name — kept for wire compatibility, it is the `unit_warnings`
/// field of the spec's `ValidationResult` (CONFORMANCE_SPEC §3.1) — a
/// `UnitWarning` is not necessarily advisory. [`code`](Self::code) says whether
/// the finding states a defect in the FILE or a limit of the ANALYSIS:
///
/// * `dimensional_mismatch` — a PROVABLE inconsistency (metres plus kilograms,
///   an equation whose sides cannot agree).
/// * `unparseable_unit` — a declared unit string that denotes no real unit.
/// * `analysis` — the checker could not DETERMINE a dimension (an unknown
///   variable, a symbolic exponent, an op with no dimensional rule). This
///   reports what the checker could not conclude, not a defect in the file.
///
/// The classification is decided AT THE POINT the finding is raised (never
/// recovered later from the prose, so rewording a message can never silently
/// change its severity) — see [`crate::units::UnitSeverity`]. In this binding
/// the defect-bearing kinds are promoted at that same decision point:
/// `dimensional_mismatch` becomes a `unit_inconsistency`
/// [`StructuralError`] and `unparseable_unit` a `unit_parse_error` one, so what
/// remains here is the non-blocking `analysis` residue. Mirrors Go's
/// `UnitWarning` (`pkg/earthsci-ast-go/pkg/esm/validate.go`) field for field, so
/// the two serialize identically.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct UnitWarning {
    /// RFC 6901 JSON Pointer to the equation/expression (see
    /// [`StructuralError::path`]). `""` when the raise site has no pointer.
    pub path: String,
    /// Finding kind, and the whole of the severity policy:
    /// `dimensional_mismatch` | `unparseable_unit` | `analysis`. See the
    /// `UNIT_FINDING_*` constants in [`crate::units`].
    pub code: String,
    /// Human-readable description of the finding.
    pub message: String,
    /// Inferred units of the LHS; `""` when the checker did not determine them
    /// (which is the norm for an `analysis` finding — not determining a
    /// dimension is what makes it one).
    pub lhs_units: String,
    /// Inferred units of the RHS; `""` when not determined.
    pub rhs_units: String,
}

/// A schema validation error
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SchemaError {
    /// Path to the problematic element
    pub path: String,
    /// Error message
    pub message: String,
    /// Keyword that failed (e.g., "required", "type", "enum")
    pub keyword: String,
}

/// A structural validation error
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StructuralError {
    /// Path to the problematic element
    pub path: String,
    /// Error code (matching spec codes)
    pub code: StructuralErrorCode,
    /// Error message
    pub message: String,
    /// Additional error details
    pub details: serde_json::Value,
}

/// Error codes for structural validation
///
/// Serialized in `snake_case` so the wasm-boundary JSON matches this type's
/// [`std::fmt::Display`] output and the cross-binding contract in
/// `tests/invalid/expected_errors.json` (e.g. `undefined_variable`, not the
/// default PascalCase `UndefinedVariable`).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum StructuralErrorCode {
    /// Undefined variable reference
    UndefinedVariable,
    /// Number of equations doesn't match state variables
    EquationCountMismatch,
    /// Undefined species in reactions
    UndefinedSpecies,
    /// Undefined parameter in expressions
    UndefinedParameter,
    /// Reaction with both substrates and products null
    NullReaction,
    /// An event `affects` LHS names a PARAMETER (esm-spec §5.4/§5.5): esm
    /// 1.0.0 events may affect UNKNOWNS only, and a parameter that changes
    /// during a run declares its own `update` block instead.
    EventAffectsParameter,
    /// Scoped reference cannot be resolved
    UnresolvedScopedRef,
    /// Variable in event is not declared
    EventVarUndeclared,
    /// Operator referenced but not declared
    UndefinedOperator,
    /// A parameter `update` of kind `data` names a `data_sources` entry the
    /// document does not declare (esm-spec §8.5).
    DataSourceUndefined,
    /// System referenced but not declared
    UndefinedSystem,

    /// Operator variable not available
    OperatorVariableMissing,
    /// Circular dependency detected
    CircularDependency,
    /// Reaction rate expression has incompatible units for reaction stoichiometry
    UnitInconsistency,
    /// A declared `units` string denotes no real unit (esm-spec §4.8.4)
    UnitParseError,
    /// An `ic`-op equation placed inside a reaction system's `constraint_equations`
    IcInReactionSystem,
    /// A `variable_map` expression transform carries a `factor` (esm-spec
    /// §10.4: the expression spells its own arithmetic — fold scaling into it)
    FactorWithExpressionTransform,
    /// A subsystem `ref` (esm-spec §4.7) that could not be resolved — a missing
    /// file, a remote URL, a cycle, or an otherwise unreadable document.
    UnresolvedSubsystemRef,
    /// A subsystem `ref` that resolved to a file NOT containing exactly one
    /// top-level system (zero or several), so which system to mount is ambiguous.
    AmbiguousSubsystemRef,
    /// A `variable_map` `identity` coupling whose `from`/`to` variables carry
    /// declared, non-empty, and DIFFERING units (esm-spec §4.7.6). Static mirror
    /// of the flatten-time [`crate::flatten::FlattenError::DomainUnitMismatch`].
    DomainUnitMismatch,
    /// An `aggregate` value-equality `join` whose key column ranges over a
    /// categorical index set carrying a FLOAT or NULL member (RFC
    /// semiring-faq-unified-ir §5.3 / §5.7 rule 1): floats are not portably
    /// equality-comparable and a null key is unmatchable.
    JoinKeyInvalidType,
    /// A value-invention `aggregate` (`distinct: true`) whose `key`/`expr` reads
    /// a model STATE variable, so the cadence partition classes it CONTINUOUS —
    /// relational work is forbidden on the per-step hot path (RFC
    /// semiring-faq-unified-ir §6.1; CONFORMANCE_SPEC.md §5.7.6 guard 2).
    RelationalNodeInContinuous,
    /// An `aggregate` `ranges` entry `{ "from": NAME }` whose NAME is not a key
    /// of the document `index_sets` registry (RFC semiring-faq-unified-ir §5.2):
    /// no implicit interval is inferred for an undeclared name.
    UndefinedIndexSet,
    /// A `broadcast` node whose `fn` field is absent, does not name a scalar
    /// operator in the registry, or is applied to an argument count that
    /// operator does not accept (esm-spec §4.3.4: "the `fn` value MUST name a
    /// scalar operator … loading MUST fail").
    ///
    /// `broadcast` is the one op whose OPERATOR is data — the node says
    /// `broadcast` and the arithmetic is named by a sibling string field — so
    /// no amount of `op`-keyed checking reaches it. Until this code existed,
    /// `{"op":"broadcast","fn":"not_a_real_op","args":[x]}` validated clean and
    /// then evaluated to `x` (issue #101).
    InvalidBroadcastFn,
    /// A BARE array-level expression whose operand is declared over an index set
    /// the result does not have (esm-spec §4.3.4). Operands of an array-level
    /// expression align by index-set NAME, so an operand declared over a SUBSET
    /// of the result's index sets broadcasts along the missing ones; one
    /// carrying an index set the result does not carry has no axis to align to.
    /// Both shapes are declared, so this is decidable here — and it must be
    /// decided here, because the alternative is a positional flatten that
    /// produces plausible, non-`NaN`, zero-padded garbage.
    ArrayShapeMismatch,
}

impl std::fmt::Display for StructuralErrorCode {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let s = match self {
            Self::UndefinedVariable => "undefined_variable",
            Self::EquationCountMismatch => "equation_count_mismatch",
            Self::UndefinedSpecies => "undefined_species",
            Self::UndefinedParameter => "undefined_parameter",
            Self::NullReaction => "null_reaction",
            Self::EventAffectsParameter => "event_affects_parameter",
            Self::UnresolvedScopedRef => "unresolved_scoped_ref",
            Self::EventVarUndeclared => "event_var_undeclared",
            Self::UndefinedOperator => "undefined_operator",
            Self::DataSourceUndefined => "data_source_undefined",
            Self::UndefinedSystem => "undefined_system",
            Self::OperatorVariableMissing => "operator_variable_missing",
            Self::CircularDependency => "circular_dependency",
            Self::UnitInconsistency => "unit_inconsistency",
            Self::UnitParseError => "unit_parse_error",
            Self::IcInReactionSystem => "ic_in_reaction_system",
            Self::FactorWithExpressionTransform => "factor_with_expression_transform",
            Self::UnresolvedSubsystemRef => "unresolved_subsystem_ref",
            Self::AmbiguousSubsystemRef => "ambiguous_subsystem_ref",
            Self::DomainUnitMismatch => "domain_unit_mismatch",
            Self::JoinKeyInvalidType => "join_key_invalid_type",
            Self::RelationalNodeInContinuous => "relational_node_in_continuous",
            Self::UndefinedIndexSet => "undefined_index_set",
            Self::InvalidBroadcastFn => "invalid_broadcast_fn",
            Self::ArrayShapeMismatch => "array_shape_mismatch",
        };
        write!(f, "{s}")
    }
}

/// Perform structural validation on an ESM file
///
/// **Note**: This function performs ONLY structural validation, not schema validation.
/// For comprehensive validation (both schema and structural), use `validate_complete()` instead.
///
/// This function runs the structural checks (delegating to
/// [`crate::structural`] and [`crate::coupling`]):
/// - All variable references are defined (including scoped refs resolved via
///   the subsystem hierarchy)
/// - Equation-unknown balance (ODE count vs. state variables)
/// - Observed variables carry expressions
/// - Discrete/continuous event references
/// - Reaction species/stoichiometry consistency
/// - Coupling-entry well-formedness
/// - Dimensional consistency of equations — reported as `unit_warnings`,
///   never as errors
///
/// # Arguments
///
/// * `esm_file` - The ESM file to validate (already parsed and schema-validated)
///
/// # Returns
///
/// * `ValidationResult` - Structural validation results (schema_errors will always be empty)
///
/// # Examples
///
/// ```rust
/// use earthsci_ast::{validate, load, EsmFile, Metadata};
///
/// let json_str = r#"
/// {
///   "esm": "1.0.0",
///   "metadata": {"name": "test"},
///   "models": {"simple": {"variables": {}, "equations": []}}
/// }
/// "#;
///
/// // First load and parse (includes schema validation)
/// let esm_file = load(json_str).unwrap();
///
/// // Then do structural validation
/// let result = validate(&esm_file);
/// assert!(result.is_valid);
/// assert!(result.schema_errors.is_empty()); // Always empty for this function
/// ```
pub fn validate(esm_file: &EsmFile) -> ValidationResult {
    let schema_errors = Vec::new();
    let mut structural_errors = Vec::new();
    let mut unit_warnings = Vec::new();

    // First validate schema if we have access to JSON
    // Note: In practice, this would be called with the original JSON string
    // For now, we focus on structural validation

    // Build system reference map for scoped reference validation
    let system_refs = build_system_reference_map(esm_file);

    // Validate models
    if let Some(ref models) = esm_file.models {
        for (model_name, model) in models {
            crate::structural::validate_model(
                esm_file,
                model_name,
                model,
                &system_refs,
                &mut structural_errors,
                &mut unit_warnings,
            );
        }

        // Check for circular dependencies between models
        crate::structural::check_circular_dependencies_in_models(models, &mut structural_errors);
    }

    // Validate reaction systems
    if let Some(ref reaction_systems) = esm_file.reaction_systems {
        for (rs_name, rs) in reaction_systems {
            crate::structural::validate_reaction_system(
                esm_file,
                rs_name,
                rs,
                &system_refs,
                &mut structural_errors,
            );
        }
    }

    // A parameter `update` of kind `data` names a `data_sources` entry, which
    // MUST resolve (esm-spec §8.5, `data_source_undefined`). From esm 1.0.0 a
    // source is not a component, so an `update.source` is the only place a
    // source name can appear — and the only place it can be wrong.
    crate::structural::validate_data_source_references(esm_file, &mut structural_errors);

    // Validate coupling
    if let Some(ref coupling) = esm_file.coupling {
        crate::coupling::validate_coupling(
            coupling,
            &system_refs,
            esm_file,
            &mut structural_errors,
        );
    }

    let is_valid = schema_errors.is_empty() && structural_errors.is_empty();

    ValidationResult {
        schema_errors,
        structural_errors,
        unit_warnings,
        is_valid,
    }
}

/// Validate an ESM file completely (schema + structural validation)
///
/// This is the main validation function that performs both schema and structural validation.
/// Most users should use this function instead of the lower-level `validate()`.
///
/// # Arguments
///
/// * `json_str` - The original JSON string to validate
/// * `base_path` - Directory anchoring relative §4.7 subsystem refs and §9.7
///   template-import refs (esm-spec §9.7.2). `None` anchors them at the process
///   current directory (the historical behaviour); a caller that loaded the
///   document from a known file MUST pass the file's own directory so relative
///   refs resolve the same way `load_path` resolves them — otherwise a valid
///   document with relative refs is wrongly rejected.
///
/// # Returns
///
/// * `ValidationResult` - Comprehensive validation results with both schema and structural errors
pub fn validate_complete(json_str: &str, base_path: Option<&std::path::Path>) -> ValidationResult {
    // First try to parse the JSON and ESM file, anchoring relative refs at the
    // caller-provided base directory (mirrors Python's `validate(base_path=…)`).
    let loaded = match base_path {
        Some(base) => load_with_options(
            json_str,
            &LoadOptions {
                base_path: Some(base.to_path_buf()),
                ..Default::default()
            },
        ),
        None => load(json_str),
    };
    match loaded {
        Ok(esm_file) => {
            // If parsing/schema validation succeeded, do structural validation
            validate_with_schema(json_str, &esm_file)
        }
        Err(e) => {
            // Load failed — but a load failure is usually a SCHEMA violation, and
            // the wire contract (CONFORMANCE_SPEC.md §7.1.2) wants ONE record per
            // violation, not a single collapsed blob. Re-parse the raw JSON and
            // enumerate the individual schema errors so each pinned `(keyword,
            // path)` surfaces. Only if the JSON itself is unparseable, or the
            // document is schema-valid but failed a LATER load stage (structural /
            // ref resolution), do we fall back to a single diagnostic record.
            let schema_errors = match serde_json::from_str::<Value>(json_str) {
                Ok(json_value) => {
                    let mut errs = crate::parse::collect_schema_errors(&json_value);
                    if errs.is_empty() {
                        errs.push(SchemaError {
                            path: "".to_string(),
                            message: format!("Failed to load ESM file: {e}"),
                            keyword: "parse".to_string(),
                        });
                    }
                    errs
                }
                Err(je) => vec![SchemaError {
                    path: "".to_string(),
                    message: format!("Invalid JSON: {je}"),
                    keyword: "format".to_string(),
                }],
            };
            // A load rejection must STILL surface its structured `(code, path)`
            // structural findings (CONFORMANCE_SPEC §7.1.2) rather than collapsing
            // to an EMPTY `structural_errors` — otherwise a document rejected at
            // load records `is_valid:false` with no structural records and every
            // pin on it silently misses. Some structural defects (an undeclared
            // event target, an invalid discrete parameter, a coupling cycle, an
            // unresolvable coupling scoped ref) reject the load BEFORE the typed
            // `validate()` pass runs, yet the document is otherwise deserializable
            // — so run the typed structural pass on a best-effort raw parse and
            // populate `structural_errors` from it. This never flips the verdict:
            // `is_valid` stays false; it only recovers the `(code, path)` records.
            // (Mirrors the conformance runner's recovery in `bin/esm.rs`.)
            let structural_errors = match serde_json::from_str::<EsmFile>(json_str) {
                Ok(esm_file) => validate(&esm_file).structural_errors,
                Err(_) => vec![],
            };
            ValidationResult {
                schema_errors,
                structural_errors,
                unit_warnings: vec![],
                is_valid: false,
            }
        }
    }
}

/// Validate an ESM file including schema validation
///
/// This function combines schema and structural validation.
/// Note: Consider using `validate_complete()` instead for a simpler API.
pub fn validate_with_schema(json_str: &str, esm_file: &EsmFile) -> ValidationResult {
    let mut schema_errors = Vec::new();
    let mut structural_errors = Vec::new();
    let mut unit_warnings = Vec::new();

    // Schema validation
    match serde_json::from_str::<Value>(json_str) {
        Err(e) => {
            schema_errors.push(SchemaError {
                path: "".to_string(),
                message: format!("Invalid JSON: {e}"),
                keyword: "format".to_string(),
            });
        }
        Ok(json_value) => {
            // One record PER schema violation (RFC-6901 pointer + standard
            // keyword), not a single collapsed blob (CONFORMANCE_SPEC.md §7.1.2).
            schema_errors.extend(crate::parse::collect_schema_errors(&json_value));
        }
    }

    // Continue with structural validation even if schema fails
    let result = validate(esm_file);
    structural_errors.extend(result.structural_errors);
    unit_warnings.extend(result.unit_warnings);

    let is_valid = schema_errors.is_empty() && structural_errors.is_empty();

    ValidationResult {
        schema_errors,
        structural_errors,
        unit_warnings,
        is_valid,
    }
}

/// Build a map of all system references for scoped reference resolution.
///
/// Shared between [`crate::structural`] and [`crate::coupling`]; not part of
/// the public API.
pub(crate) fn build_system_reference_map(esm_file: &EsmFile) -> HashMap<String, SystemInfo> {
    let mut systems = HashMap::new();

    // Add models
    if let Some(ref models) = esm_file.models {
        for (name, model) in models {
            let variables: HashSet<String> = model.variables.keys().cloned().collect();
            // Parameter-typed variables also resolve as scoped `Model.param`
            // refs; expose them in `parameters` too so the reference map
            // classifies them correctly (structural.rs / coupling.rs read
            // `system.parameters`).
            let parameters: HashSet<String> = model
                .variables
                .iter()
                .filter(|(_, v)| v.var_type == crate::VariableType::Parameter)
                .map(|(k, _)| k.clone())
                .collect();
            systems.insert(
                name.clone(),
                SystemInfo {
                    variables,
                    species: HashSet::new(),
                    parameters,
                },
            );

            // A scoped reference is a dot path of ARBITRARY DEPTH (esm-spec
            // §4.9.2): `EarthSystem.Atmosphere.Chemistry.O3` walks the
            // `subsystems` maps down and takes `O3` from the system it lands on.
            // Registering every nested subsystem under its FULL DOTTED PATH
            // turns that walk into a single prefix lookup for both the variable
            // resolver (structural.rs) and the coupling system position
            // (coupling.rs) — without it, any reference more than two segments
            // deep is a spurious `unresolved_scoped_ref`/`undefined_system`.
            register_subsystems(name, model.subsystems.as_ref(), &mut systems);
        }
    }

    // Add reaction systems
    if let Some(ref reaction_systems) = esm_file.reaction_systems {
        for (name, rs) in reaction_systems {
            let species: HashSet<String> = rs.species.keys().cloned().collect();
            // Reaction-system parameters (rate constants, etc.) resolve as
            // scoped `RS.k1` refs; structural.rs reads `system.parameters`.
            let parameters: HashSet<String> = rs.parameters.keys().cloned().collect();
            systems.insert(
                name.clone(),
                SystemInfo {
                    variables: HashSet::new(),
                    species,
                    parameters,
                },
            );

            // Reaction systems nest too (esm-spec §4.9.2).
            register_subsystems(name, rs.subsystems.as_ref(), &mut systems);
        }
    }

    // Data sources are DELIBERATELY not registered as systems. From esm 1.0.0
    // (RFC unified-variable-model D2) a source is not a component: it cannot be
    // a coupling endpoint, a subsystem, or the root of a scoped reference, and
    // it exposes no variables at all — the consuming PARAMETER names the source
    // in its `update` and owns the units. Registering one here would make
    // `<source>.<something>` resolve as a scoped reference, which is exactly
    // the shape 1.0.0 removes.

    // Add operators
    if let Some(ref operators) = esm_file.operators {
        for name in operators.keys() {
            systems.insert(
                name.clone(),
                SystemInfo {
                    variables: HashSet::new(),
                    species: HashSet::new(),
                    parameters: HashSet::new(),
                },
            );
        }
    }

    systems
}

/// Register a model's `subsystems` — recursively, at arbitrary depth — under
/// their full dotted paths (`Parent.Child`, `Parent.Child.Grandchild`, …).
///
/// `Model::subsystems` is raw `serde_json::Value` (a subsystem may be an inline
/// system object or an unresolved `{"ref": …}` edge), so this reads the nested
/// shape structurally rather than through the typed `Model`. A `{"ref": …}` edge
/// that has not been resolved contributes no variables — it is registered as an
/// empty system so that the PATH resolves (the file may legitimately be inlined
/// later) without claiming to know its contents.
fn register_subsystems(
    prefix: &str,
    subsystems: Option<&HashMap<String, serde_json::Value>>,
    systems: &mut HashMap<String, SystemInfo>,
) {
    let Some(subsystems) = subsystems else {
        return;
    };
    for (child_name, child) in subsystems {
        let path = format!("{prefix}.{child_name}");

        let variables: HashSet<String> = child
            .get("variables")
            .and_then(|v| v.as_object())
            .map(|m| m.keys().cloned().collect())
            .unwrap_or_default();
        let species: HashSet<String> = child
            .get("species")
            .and_then(|v| v.as_object())
            .map(|m| m.keys().cloned().collect())
            .unwrap_or_default();
        // Parameter-typed variables also resolve as scoped `<path>.<param>`
        // refs, mirroring the top-level model case above.
        let mut parameters: HashSet<String> = child
            .get("variables")
            .and_then(|v| v.as_object())
            .map(|m| {
                m.iter()
                    .filter(|(_, v)| v.get("type").and_then(|t| t.as_str()) == Some("parameter"))
                    .map(|(k, _)| k.clone())
                    .collect()
            })
            .unwrap_or_default();
        if let Some(params) = child.get("parameters").and_then(|v| v.as_object()) {
            parameters.extend(params.keys().cloned());
        }

        systems.insert(
            path.clone(),
            SystemInfo {
                variables,
                species,
                parameters,
            },
        );

        // Recurse into this subsystem's own `subsystems` map.
        if let Some(nested) = child.get("subsystems").and_then(|v| v.as_object()) {
            let nested: HashMap<String, serde_json::Value> =
                nested.iter().map(|(k, v)| (k.clone(), v.clone())).collect();
            register_subsystems(&path, Some(&nested), systems);
        }
    }
}

#[derive(Debug, Clone)]
pub(crate) struct SystemInfo {
    pub(crate) variables: HashSet<String>,
    pub(crate) species: HashSet<String>,
    pub(crate) parameters: HashSet<String>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::{Equation, ExpressionNode, Metadata, ModelVariable, VariableType};
    use crate::{Expr, Model};
    use std::collections::HashMap;

    #[test]
    fn test_validate_empty_file() {
        let esm_file = EsmFile {
            coordinates: None,
            expression_templates: None,
            metaparameters: None,
            coupling_roles: None,
            domain: None,
            index_sets: None,
            esm: "0.1.0".to_string(),
            metadata: Metadata {
                name: Some("test".to_string()),
                description: None,
                authors: None,
                created: None,
                modified: None,
                license: None,
                tags: None,
                references: None,
                system_class: None,
                dae_info: None,
                discretized_from: None,
            },
            models: None,
            reaction_systems: None,
            data_sources: None,
            operators: None,
            enums: None,

            coupling: None,
            function_tables: None,
        };

        let result = validate(&esm_file);
        assert!(result.is_valid);
        assert!(result.structural_errors.is_empty());
        assert!(result.schema_errors.is_empty());
    }

    #[test]
    fn test_validate_model_with_undefined_variable() {
        let mut models = HashMap::new();
        let mut variables = HashMap::new();
        variables.insert(
            "x".to_string(),
            ModelVariable {
                default_units: None,
                var_type: VariableType::Unknown,
                units: None,
                default: None,
                description: None,
                shape: None,
                location: None,
                distribution: None,
                update: None,
            },
        );

        models.insert(
            "test".to_string(),
            Model {
                reference: None,
                subsystems: None,
                name: Some("Test Model".to_string()),
                variables,
                equations: vec![Equation {
                    lhs: Expr::operator(ExpressionNode {
                        op: "D".to_string(),
                        args: vec![Expr::Variable("x".to_string())],
                        wrt: Some("t".to_string()),
                        dim: None,
                        ..Default::default()
                    }),
                    rhs: Expr::Variable("undefined_var".to_string()), // This should cause an error
                }],
                discrete_events: None,
                continuous_events: None,
                description: None,
                tolerance: None,
                tests: None,
                initialization_equations: None,
                guesses: None,
                system_kind: None,
            },
        );

        let esm_file = EsmFile {
            coordinates: None,
            expression_templates: None,
            metaparameters: None,
            coupling_roles: None,
            domain: None,
            index_sets: None,
            esm: "0.1.0".to_string(),
            metadata: Metadata {
                name: Some("test".to_string()),
                description: None,
                authors: None,
                created: None,
                modified: None,
                license: None,
                tags: None,
                references: None,
                system_class: None,
                dae_info: None,
                discretized_from: None,
            },
            models: Some(models),
            reaction_systems: None,
            data_sources: None,
            operators: None,
            enums: None,

            coupling: None,
            function_tables: None,
        };

        let result = validate(&esm_file);
        assert!(!result.is_valid);
        assert!(!result.structural_errors.is_empty());
        assert!(
            result.structural_errors[0]
                .message
                .contains("Variable 'undefined_var' referenced in equation is not declared")
        );
        assert!(matches!(
            result.structural_errors[0].code,
            StructuralErrorCode::UndefinedVariable
        ));
    }

    #[test]
    fn test_equation_count_mismatch() {
        let mut models = HashMap::new();
        let mut variables = HashMap::new();

        // Define two state variables
        variables.insert(
            "x".to_string(),
            ModelVariable {
                default_units: None,
                var_type: VariableType::Unknown,
                units: None,
                default: None,
                description: None,
                shape: None,
                location: None,
                distribution: None,
                update: None,
            },
        );
        variables.insert(
            "y".to_string(),
            ModelVariable {
                default_units: None,
                var_type: VariableType::Unknown,
                units: None,
                default: None,
                description: None,
                shape: None,
                location: None,
                distribution: None,
                update: None,
            },
        );

        models.insert(
            "test".to_string(),
            Model {
                reference: None,
                subsystems: None,
                name: Some("Test Model".to_string()),
                variables,
                equations: vec![
                    // Only one equation for two state variables
                    Equation {
                        lhs: Expr::operator(ExpressionNode {
                            op: "D".to_string(),
                            args: vec![Expr::Variable("x".to_string())],
                            wrt: Some("t".to_string()),
                            dim: None,
                            ..Default::default()
                        }),
                        rhs: Expr::Variable("x".to_string()),
                    },
                ],
                discrete_events: None,
                continuous_events: None,
                description: None,
                tolerance: None,
                tests: None,
                initialization_equations: None,
                guesses: None,
                system_kind: None,
            },
        );

        let esm_file = EsmFile {
            coordinates: None,
            expression_templates: None,
            metaparameters: None,
            coupling_roles: None,
            domain: None,
            index_sets: None,
            esm: "0.1.0".to_string(),
            metadata: Metadata {
                name: Some("test".to_string()),
                description: None,
                authors: None,
                created: None,
                modified: None,
                license: None,
                tags: None,
                references: None,
                system_class: None,
                dae_info: None,
                discretized_from: None,
            },
            models: Some(models),
            reaction_systems: None,
            data_sources: None,
            operators: None,
            enums: None,

            coupling: None,
            function_tables: None,
        };

        let result = validate(&esm_file);
        assert!(!result.is_valid);
        assert!(!result.structural_errors.is_empty());

        let error = &result.structural_errors[0];
        assert!(matches!(
            error.code,
            StructuralErrorCode::EquationCountMismatch
        ));
        // esm-spec §4.9.4: the balance is UNKNOWNS vs EQUATIONS. This model
        // declares two states and carries one equation, so it is genuinely
        // under-determined.
        assert!(
            error
                .message
                .contains("Number of equations (1) does not match number of unknowns (2)"),
            "unexpected message: {}",
            error.message
        );
    }

    #[test]
    fn test_validation_result_structure() {
        // Test that the new ValidationResult structure works as expected
        let esm_file = EsmFile {
            coordinates: None,
            expression_templates: None,
            metaparameters: None,
            coupling_roles: None,
            domain: None,
            index_sets: None,
            esm: "0.1.0".to_string(),
            metadata: Metadata {
                name: Some("test".to_string()),
                description: None,
                authors: None,
                created: None,
                modified: None,
                license: None,
                tags: None,
                references: None,
                system_class: None,
                dae_info: None,
                discretized_from: None,
            },
            models: None,
            reaction_systems: None,
            data_sources: None,
            operators: None,
            enums: None,

            coupling: None,
            function_tables: None,
        };

        let result = validate(&esm_file);

        // Check the new structure
        assert!(result.is_valid);
        assert!(result.schema_errors.is_empty());
        assert!(result.structural_errors.is_empty());
        assert!(result.unit_warnings.is_empty());
    }

    #[test]
    /// esm 1.0.0 removed the variable `expression` field and with it the
    /// `missing_observed_expr` diagnostic: an unknown with nothing defining it
    /// is not a malformed declaration but an UNBALANCED SYSTEM, reported by
    /// `equation_count_mismatch` (esm-spec §4.9.4).
    fn test_unknown_without_equation() {
        let mut models = HashMap::new();
        let mut variables = HashMap::new();

        // An unknown that NO equation defines - the defect.
        variables.insert(
            "total".to_string(),
            ModelVariable {
                default_units: None,
                var_type: VariableType::Unknown,
                units: None,
                default: None,
                description: None,
                shape: None,
                location: None,
                distribution: None,
                update: None,
            },
        );

        models.insert(
            "test".to_string(),
            Model {
                reference: None,
                subsystems: None,
                name: Some("Test Model".to_string()),
                variables,
                equations: vec![], // No equations needed for this test
                discrete_events: None,
                continuous_events: None,
                description: None,
                tolerance: None,
                tests: None,
                initialization_equations: None,
                guesses: None,
                system_kind: None,
            },
        );

        let esm_file = EsmFile {
            coordinates: None,
            expression_templates: None,
            metaparameters: None,
            coupling_roles: None,
            domain: None,
            index_sets: None,
            esm: "0.1.0".to_string(),
            metadata: Metadata {
                name: Some("test".to_string()),
                description: None,
                authors: None,
                created: None,
                modified: None,
                license: None,
                tags: None,
                references: None,
                system_class: None,
                dae_info: None,
                discretized_from: None,
            },
            models: Some(models),
            reaction_systems: None,
            data_sources: None,
            operators: None,
            enums: None,

            coupling: None,
            function_tables: None,
        };

        let result = validate(&esm_file);
        assert!(!result.is_valid);
        assert_eq!(result.structural_errors.len(), 1);
        let finding = &result.structural_errors[0];
        assert!(matches!(
            finding.code,
            StructuralErrorCode::EquationCountMismatch
        ));
        assert_eq!(
            finding.message,
            "Number of equations (0) does not match number of unknowns (1)"
        );
        // `missing_equations_for` is what preserves the retired diagnostic's
        // discriminating power: it names the very unknown that has nothing
        // defining it.
        assert_eq!(
            finding.details["missing_equations_for"],
            serde_json::json!(["total"])
        );
        assert_eq!(finding.details["unknowns"], serde_json::json!(["total"]));
    }

    #[test]
    fn test_observed_variable_with_expression() {
        let mut models = HashMap::new();
        let mut variables = HashMap::new();

        // State variable
        variables.insert(
            "x".to_string(),
            ModelVariable {
                default_units: None,
                var_type: VariableType::Unknown,
                units: Some("m".to_string()),
                default: Some(1.0),
                description: None,
                shape: None,
                location: None,
                distribution: None,
                update: None,
            },
        );

        // Parameter
        variables.insert(
            "k".to_string(),
            ModelVariable {
                default_units: None,
                var_type: VariableType::Parameter,
                units: Some("1/s".to_string()),
                default: Some(0.1),
                description: None,
                shape: None,
                location: None,
                distribution: None,
                update: None,
            },
        );

        // An OBSERVED unknown: declared `unknown`, and made observed by the
        // bare-variable-LHS equation added below.
        variables.insert(
            "rate".to_string(),
            ModelVariable {
                default_units: None,
                var_type: VariableType::Unknown,
                units: Some("m/s".to_string()),
                default: None,
                description: Some("Rate of change".to_string()),
                shape: None,
                location: None,
                distribution: None,
                update: None,
            },
        );

        models.insert(
            "test".to_string(),
            Model {
                reference: None,
                subsystems: None,
                name: Some("Test Model".to_string()),
                variables,
                equations: vec![
                    Equation {
                        lhs: Expr::operator(ExpressionNode {
                            op: "D".to_string(),
                            args: vec![Expr::Variable("x".to_string())],
                            wrt: Some("t".to_string()),
                            dim: None,
                            ..Default::default()
                        }),
                        rhs: Expr::Variable("rate".to_string()),
                    },
                    Equation {
                        lhs: Expr::Variable("rate".to_string()),
                        rhs: Expr::operator(ExpressionNode {
                            op: "*".to_string(),
                            args: vec![
                                Expr::Variable("k".to_string()),
                                Expr::Variable("x".to_string()),
                            ],
                            ..Default::default()
                        }),
                    },
                ],
                discrete_events: None,
                continuous_events: None,
                description: None,
                tolerance: None,
                tests: None,
                initialization_equations: None,
                guesses: None,
                system_kind: None,
            },
        );

        let esm_file = EsmFile {
            coordinates: None,
            expression_templates: None,
            metaparameters: None,
            coupling_roles: None,
            domain: None,
            index_sets: None,
            esm: "0.1.0".to_string(),
            metadata: Metadata {
                name: Some("test".to_string()),
                description: None,
                authors: None,
                created: None,
                modified: None,
                license: None,
                tags: None,
                references: None,
                system_class: None,
                dae_info: None,
                discretized_from: None,
            },
            models: Some(models),
            reaction_systems: None,
            data_sources: None,
            operators: None,
            enums: None,

            coupling: None,
            function_tables: None,
        };

        let result = validate(&esm_file);
        // Should pass validation - observed variable has expression
        assert!(
            result.is_valid,
            "Validation failed: {:?}",
            result.structural_errors
        );
        assert!(result.structural_errors.is_empty());
    }

    #[test]
    fn test_json_serialization_with_observed_expression() {
        // Test that we can serialize and deserialize observed variables with expressions
        let json_str = r#"{
            "esm": "1.0.0",
            "metadata": {
                "name": "TestModel",
                "description": "Test observed variables with expressions"
            },
            "models": {
                "TestModel": {
                    "variables": {
                        "x": { "type": "unknown", "units": "m", "default": 1.0 },
                        "k": { "type": "parameter", "units": "1/s", "default": 0.1 },
                        "rate": {
                            "type": "unknown",
                            "units": "m/s",
                            "description": "Rate of change"
                        }
                    },
                    "equations": [
                        {
                            "lhs": { "op": "D", "args": ["x"], "wrt": "t" },
                            "rhs": "rate"
                        },
                        {
                            "lhs": "rate",
                            "rhs": { "op": "*", "args": ["k", "x"] }
                        }
                    ]
                }
            }
        }"#;

        // Parse JSON
        let esm_file: EsmFile = serde_json::from_str(json_str).expect("Failed to parse JSON");

        // Validate the model
        let result = validate(&esm_file);
        assert!(
            result.is_valid,
            "Validation should pass: {:?}",
            result.structural_errors
        );

        // `rate` is DECLARED an unknown and DERIVED observed, by the
        // bare-variable-LHS equation that defines it (esm-spec §6.3.1).
        let model = esm_file.models.as_ref().unwrap().get("TestModel").unwrap();
        let rate_var = model.variables.get("rate").unwrap();
        assert_eq!(rate_var.var_type, VariableType::Unknown);
        assert_eq!(crate::classification::observed_unknowns(model), ["rate"]);
        assert!(
            crate::classification::observed_definitions(model).contains_key("rate"),
            "the observed unknown's definition is its equation's RHS"
        );

        // Test serialization back to JSON
        let serialized =
            serde_json::to_string_pretty(&esm_file).expect("Failed to serialize to JSON");

        // Should be able to parse it again
        let _reparsed: EsmFile =
            serde_json::from_str(&serialized).expect("Failed to reparse serialized JSON");
    }

    #[test]
    fn test_unit_validation() {
        let mut models = HashMap::new();
        let mut variables = HashMap::new();

        // State variable with units
        variables.insert(
            "x".to_string(),
            ModelVariable {
                default_units: None,
                var_type: VariableType::Unknown,
                units: Some("m".to_string()), // meters
                default: Some(1.0),
                description: None,
                shape: None,
                location: None,
                distribution: None,
                update: None,
            },
        );

        // Parameter with units
        variables.insert(
            "k".to_string(),
            ModelVariable {
                default_units: None,
                var_type: VariableType::Parameter,
                units: Some("1/s".to_string()), // per second
                default: Some(0.1),
                description: None,
                shape: None,
                location: None,
                distribution: None,
                update: None,
            },
        );

        models.insert(
            "test".to_string(),
            Model {
                reference: None,
                subsystems: None,
                name: Some("Test Model".to_string()),
                variables,
                equations: vec![Equation {
                    lhs: Expr::operator(ExpressionNode {
                        op: "D".to_string(),
                        args: vec![Expr::Variable("x".to_string())],
                        wrt: Some("t".to_string()),
                        dim: None,
                        ..Default::default()
                    }),
                    rhs: Expr::operator(ExpressionNode {
                        op: "*".to_string(),
                        args: vec![
                            Expr::Variable("k".to_string()),
                            Expr::Variable("x".to_string()),
                        ],
                        wrt: None,
                        dim: None,
                        ..Default::default()
                    }),
                }],
                discrete_events: None,
                continuous_events: None,
                description: None,
                tolerance: None,
                tests: None,
                initialization_equations: None,
                guesses: None,
                system_kind: None,
            },
        );

        let esm_file = EsmFile {
            coordinates: None,
            expression_templates: None,
            metaparameters: None,
            coupling_roles: None,
            domain: None,
            index_sets: None,
            esm: "0.1.0".to_string(),
            metadata: Metadata {
                name: Some("test".to_string()),
                description: None,
                authors: None,
                created: None,
                modified: None,
                license: None,
                tags: None,
                references: None,
                system_class: None,
                dae_info: None,
                discretized_from: None,
            },
            models: Some(models),
            reaction_systems: None,
            data_sources: None,
            operators: None,
            enums: None,

            coupling: None,
            function_tables: None,
        };

        let result = validate(&esm_file);
        // Should pass validation - units are dimensionally consistent
        // LHS: d(m)/dt = m/s, RHS: (1/s) * m = m/s
        assert!(
            result.is_valid,
            "Validation should pass: {:?}",
            result.structural_errors
        );
        assert!(result.structural_errors.is_empty());
        // Unit warnings should be empty since dimensions are consistent
        assert!(
            result.unit_warnings.is_empty(),
            "Unit warnings: {:?}",
            result.unit_warnings
        );
    }

    #[test]
    fn test_unit_validation_mismatch() {
        let mut models = HashMap::new();
        let mut variables = HashMap::new();

        // State variable with units
        variables.insert(
            "x".to_string(),
            ModelVariable {
                default_units: None,
                var_type: VariableType::Unknown,
                units: Some("m".to_string()), // meters
                default: Some(1.0),
                description: None,
                shape: None,
                location: None,
                distribution: None,
                update: None,
            },
        );

        // Parameter with incompatible units
        variables.insert(
            "k".to_string(),
            ModelVariable {
                default_units: None,
                var_type: VariableType::Parameter,
                units: Some("kg".to_string()), // mass units (incompatible)
                default: Some(0.1),
                description: None,
                shape: None,
                location: None,
                distribution: None,
                update: None,
            },
        );

        models.insert(
            "test".to_string(),
            Model {
                reference: None,
                subsystems: None,
                name: Some("Test Model".to_string()),
                variables,
                equations: vec![Equation {
                    lhs: Expr::operator(ExpressionNode {
                        op: "D".to_string(),
                        args: vec![Expr::Variable("x".to_string())],
                        wrt: Some("t".to_string()),
                        dim: None,
                        ..Default::default()
                    }),
                    rhs: Expr::Variable("k".to_string()), // Just k, not k*x
                }],
                discrete_events: None,
                continuous_events: None,
                description: None,
                tolerance: None,
                tests: None,
                initialization_equations: None,
                guesses: None,
                system_kind: None,
            },
        );

        let esm_file = EsmFile {
            coordinates: None,
            expression_templates: None,
            metaparameters: None,
            coupling_roles: None,
            domain: None,
            index_sets: None,
            esm: "0.1.0".to_string(),
            metadata: Metadata {
                name: Some("test".to_string()),
                description: None,
                authors: None,
                created: None,
                modified: None,
                license: None,
                tags: None,
                references: None,
                system_class: None,
                dae_info: None,
                discretized_from: None,
            },
            models: Some(models),
            reaction_systems: None,
            data_sources: None,
            operators: None,
            enums: None,

            coupling: None,
            function_tables: None,
        };

        let result = validate(&esm_file);
        // D(x)/dt = k with x in metres and k in kilograms: no time unit can
        // reconcile the two sides, so this is a PROVABLE mismatch and therefore
        // a hard error rather than a warning.
        assert!(
            !result.is_valid,
            "An unreconcilable derivative equation must fail validation: {result:?}"
        );
        let unit_errors: Vec<_> = result
            .structural_errors
            .iter()
            .filter(|e| matches!(e.code, StructuralErrorCode::UnitInconsistency))
            .collect();
        assert_eq!(unit_errors.len(), 1, "{:?}", result.structural_errors);
        assert_eq!(unit_errors[0].path, "/models/test/equations/0");
    }

    #[test]
    fn test_unit_validation_integration() {
        // Test that unit validation warnings are properly returned from the main validate function
        let mut models = HashMap::new();
        let mut variables = HashMap::new();

        // State variable with position units
        variables.insert(
            "position".to_string(),
            ModelVariable {
                default_units: None,
                var_type: VariableType::Unknown,
                units: Some("m".to_string()),
                default: Some(0.0),
                description: None,
                shape: None,
                location: None,
                distribution: None,
                update: None,
            },
        );

        // Parameter with velocity units - should be compatible
        variables.insert(
            "velocity".to_string(),
            ModelVariable {
                default_units: None,
                var_type: VariableType::Parameter,
                units: Some("m/s".to_string()),
                default: Some(1.0),
                description: None,
                shape: None,
                location: None,
                distribution: None,
                update: None,
            },
        );

        models.insert(
            "test_model".to_string(),
            Model {
                reference: None,
                subsystems: None,
                name: Some("Test Model".to_string()),
                variables,
                equations: vec![Equation {
                    lhs: Expr::operator(ExpressionNode {
                        op: "D".to_string(),
                        args: vec![Expr::Variable("position".to_string())],
                        wrt: Some("t".to_string()),
                        dim: None,
                        ..Default::default()
                    }),
                    rhs: Expr::Variable("velocity".to_string()),
                }],
                discrete_events: None,
                continuous_events: None,
                description: None,
                tolerance: None,
                tests: None,
                initialization_equations: None,
                guesses: None,
                system_kind: None,
            },
        );

        let esm_file = EsmFile {
            coordinates: None,
            expression_templates: None,
            metaparameters: None,
            coupling_roles: None,
            domain: None,
            index_sets: None,
            esm: "0.1.0".to_string(),
            metadata: Metadata {
                name: Some("Unit Test".to_string()),
                description: None,
                authors: None,
                created: None,
                modified: None,
                license: None,
                tags: None,
                references: None,
                system_class: None,
                dae_info: None,
                discretized_from: None,
            },
            models: Some(models),
            reaction_systems: None,
            data_sources: None,
            operators: None,
            enums: None,

            coupling: None,
            function_tables: None,
        };

        let result = validate(&esm_file);
        // Should pass validation - LHS: d(position)/dt = m/s, RHS: velocity = m/s
        assert!(
            result.is_valid,
            "Validation should pass: {:?}",
            result.structural_errors
        );
        assert!(result.structural_errors.is_empty());
        assert!(
            result.unit_warnings.is_empty(),
            "No unit warnings expected: {:?}",
            result.unit_warnings
        );
    }

    #[test]
    fn test_transcendental_function_units() {
        let mut models = HashMap::new();
        let mut variables = HashMap::new();

        // State variable with units (should cause warning when used in exp)
        variables.insert(
            "x".to_string(),
            ModelVariable {
                default_units: None,
                var_type: VariableType::Unknown,
                units: Some("m".to_string()), // meters
                default: Some(1.0),
                description: None,
                shape: None,
                location: None,
                distribution: None,
                update: None,
            },
        );

        models.insert(
            "test".to_string(),
            Model {
                reference: None,
                subsystems: None,
                name: Some("Test Model".to_string()),
                variables,
                equations: vec![Equation {
                    lhs: Expr::operator(ExpressionNode {
                        op: "D".to_string(),
                        args: vec![Expr::Variable("x".to_string())],
                        wrt: Some("t".to_string()),
                        dim: None,
                        ..Default::default()
                    }),
                    rhs: Expr::operator(ExpressionNode {
                        op: "exp".to_string(),
                        args: vec![Expr::Variable("x".to_string())], // exp(x) where x has units - should warn
                        wrt: None,
                        dim: None,
                        ..Default::default()
                    }),
                }],
                discrete_events: None,
                continuous_events: None,
                description: None,
                tolerance: None,
                tests: None,
                initialization_equations: None,
                guesses: None,
                system_kind: None,
            },
        );

        let esm_file = EsmFile {
            coordinates: None,
            expression_templates: None,
            metaparameters: None,
            coupling_roles: None,
            domain: None,
            index_sets: None,
            esm: "0.1.0".to_string(),
            metadata: Metadata {
                name: Some("test".to_string()),
                description: None,
                authors: None,
                created: None,
                modified: None,
                license: None,
                tags: None,
                references: None,
                system_class: None,
                dae_info: None,
                discretized_from: None,
            },
            models: Some(models),
            reaction_systems: None,
            data_sources: None,
            operators: None,
            enums: None,

            coupling: None,
            function_tables: None,
        };

        let result = validate(&esm_file);
        // `exp(x)` with x in metres is a PROVABLE dimensional inconsistency, so
        // it is a hard `unit_inconsistency` error, not a warning — the shared
        // corpus pins `units_*.esm` fixtures as `is_valid: false`.
        assert!(
            !result.is_valid,
            "A dimensional argument to exp must fail validation: {result:?}"
        );
        let unit_errors: Vec<_> = result
            .structural_errors
            .iter()
            .filter(|e| matches!(e.code, StructuralErrorCode::UnitInconsistency))
            .collect();
        // `D(x)/dt = exp(x)` has TWO independent provable defects: the
        // dimensional argument to `exp`, and the resulting equation (which no
        // time unit can reconcile). BOTH are reported — propagation no longer
        // abandons the equation at the first finding, which is what used to let
        // one defect hide another.
        assert_eq!(unit_errors.len(), 2, "{:?}", result.structural_errors);
        assert!(
            unit_errors.iter().any(|e| e
                .message
                .contains("Argument to 'exp' must be dimensionless")),
            "{unit_errors:?}"
        );
        assert!(
            unit_errors
                .iter()
                .any(|e| e.message.contains("No time unit can reconcile")),
            "{unit_errors:?}"
        );
        assert!(
            unit_errors
                .iter()
                .all(|e| e.path == "/models/test/equations/0")
        );
    }

    #[test]
    fn test_validate_vs_validate_complete() {
        // Test to demonstrate the difference between validate() and validate_complete()
        // validate() only does structural validation, validate_complete() does both

        // Create a valid EsmFile structure
        let esm_file = EsmFile {
            coordinates: None,
            expression_templates: None,
            metaparameters: None,
            coupling_roles: None,
            domain: None,
            index_sets: None,
            esm: "0.1.0".to_string(),
            metadata: Metadata {
                name: Some("test".to_string()),
                description: None,
                authors: None,
                created: None,
                modified: None,
                license: None,
                tags: None,
                references: None,
                system_class: None,
                dae_info: None,
                discretized_from: None,
            },
            models: None,
            reaction_systems: None,
            data_sources: None,
            operators: None,
            enums: None,

            coupling: None,
            function_tables: None,
        };

        // JSON that should fail schema validation (has invalid variable type)
        let invalid_json = r#"
        {
            "esm": "1.0.0",
            "metadata": {
                "name": "test"
            },
            "models": {
                "test_model": {
                    "variables": {
                        "x": {
                            "type": "invalid_type_that_should_fail_schema"
                        }
                    },
                    "equations": []
                }
            }
        }
        "#;

        // The validate() function - only does structural validation
        let result1 = validate(&esm_file);

        // The validate_complete() function - does both schema and structural validation
        let result2 = validate_complete(invalid_json, None);

        // Correct behavior: validate() should have empty schema_errors (it doesn't check schema)
        assert!(
            result1.schema_errors.is_empty(),
            "validate() should have empty schema_errors because it only does structural validation"
        );
        assert!(
            result1.is_valid,
            "validate() should pass structural validation on valid ESM structure"
        );

        // validate_complete() should find schema errors
        assert!(
            !result2.schema_errors.is_empty(),
            "validate_complete() should find schema errors"
        );
        assert!(
            !result2.is_valid,
            "validate_complete() should fail due to schema errors"
        );

        println!(
            "CORRECT BEHAVIOR: validate() found {} schema errors, validate_complete() found {} schema errors",
            result1.schema_errors.len(),
            result2.schema_errors.len()
        );
    }

    #[test]
    fn test_validate_complete_with_schema_errors() {
        // Test the new validate_complete function that should detect schema errors
        let invalid_json = r#"
        {
            "esm": "1.0.0",
            "metadata": {
                "name": "test"
            },
            "models": {
                "test_model": {
                    "variables": {
                        "x": {
                            "type": "invalid_type_that_should_fail_schema"
                        }
                    },
                    "equations": []
                }
            }
        }
        "#;

        let result = validate_complete(invalid_json, None);

        // Should detect schema errors
        assert!(
            !result.is_valid,
            "validate_complete should detect schema validation failures"
        );
        assert!(
            !result.schema_errors.is_empty(),
            "validate_complete should find schema errors"
        );

        // Per CONFORMANCE_SPEC.md §7.1.2 the wire format is one record PER schema
        // violation — a standard JSON-Schema keyword plus the RFC-6901 pointer of
        // the offending node — not a single collapsed "Failed to load" blob. The
        // invalid `type` enum value must surface as an `enum` error at the
        // variable's `type` pointer.
        assert!(
            result
                .schema_errors
                .iter()
                .any(|e| e.keyword == "enum" && e.path == "/models/test_model/variables/x/type"),
            "expected a per-error `enum` schema violation at the variable's type pointer; got {:?}",
            result.schema_errors
        );
        // No record should be the old collapsed placeholder.
        assert!(
            result.schema_errors.iter().all(|e| e.keyword != "parse"),
            "schema errors must be enumerated per-violation, not a single `parse` blob: {:?}",
            result.schema_errors
        );
    }

    #[test]
    fn test_validate_complete_with_valid_json() {
        // Test validate_complete with valid JSON
        let valid_json = r#"
            {
              "esm": "1.0.0",
              "metadata": {
                "name": "test"
              },
              "models": {
                "test_model": {
                  "variables": {
                    "x": {
                      "type": "unknown",
                      "units": "m",
                      "default": 1.0
                    }
                  },
                  "equations": [
                    {
                      "lhs": {
                        "op": "D",
                        "args": [
                          "x"
                        ],
                        "wrt": "t"
                      },
                      "rhs": {
                        "op": "*",
                        "args": [
                          0.1,
                          "x"
                        ]
                      }
                    }
                  ]
                }
              }
            }
            "#;

        let result = validate_complete(valid_json, None);

        // Should pass validation
        assert!(
            result.is_valid,
            "validate_complete should pass with valid JSON: {result:?}"
        );
        assert!(
            result.schema_errors.is_empty(),
            "Should have no schema errors"
        );
        assert!(
            result.structural_errors.is_empty(),
            "Should have no structural errors"
        );
    }

    #[test]
    fn test_validate_complete_recovers_structural_on_load_reject() {
        // A document that is schema-valid but rejected at LOAD by a structural
        // rule (here: an event `affects` targeting an undeclared variable) must
        // still surface its structured `(code, path)` structural findings from
        // `validate_complete`, NOT collapse to an empty `structural_errors`
        // (CONFORMANCE_SPEC §7.1.2). Fixture + pinned shape:
        // tests/invalid/event_var_undeclared.esm + expected_errors.json.
        let fixture = include_str!("../../../tests/invalid/event_var_undeclared.esm");
        let result = validate_complete(fixture, None);

        assert!(!result.is_valid, "load-rejected fixture must be invalid");
        assert!(
            !result.structural_errors.is_empty(),
            "validate_complete must recover typed structural errors on load-reject, got none"
        );
        // The pinned `(code, path)` record must be present. Per §7.1.2 the pin is
        // a REQUIRED SUBSET of what the binding emits, so a load-Err document may
        // additionally carry a `keyword:"parse"` load diagnostic in
        // `schema_errors` — that is existing behavior and is not asserted here;
        // what matters is that the structural pin is recovered rather than lost.
        assert!(
            result.structural_errors.iter().any(|e| matches!(
                e.code,
                StructuralErrorCode::EventVarUndeclared
            ) && e.path
                == "/models/TestModel/continuous_events/0/affects/0/lhs"),
            "expected pinned event_var_undeclared @ /models/TestModel/continuous_events/0/affects/0/lhs, got: {:?}",
            result.structural_errors
        );
    }

    // -----------------------------------------------------------------------
    // Issue #101 — `broadcast.fn` must be validated, not silently discarded.
    // -----------------------------------------------------------------------

    /// A one-model document whose observed `y` is defined by `expr`.
    fn doc_with_observed_expr(expr: &str) -> String {
        format!(
            r#"{{
              "esm": "1.0.0",
              "metadata": {{"name": "bcast"}},
              "models": {{"M": {{
                "variables": {{
                  "x": {{"type": "unknown", "units": "1", "default": 1.0}},
                  "y": {{"type": "unknown", "units": "1"}}
                }},
                "equations": [
                  {{"lhs": "y", "rhs": {expr}}},
                  {{"lhs": {{"op": "D", "args": ["x"], "wrt": "t"}}, "rhs": "y"}}
                ]
              }}}}
            }}"#
        )
    }

    /// Deserialize DIRECTLY, bypassing `load()`'s schema pass, and return the
    /// `invalid_broadcast_fn` findings `validate()` reports.
    ///
    /// The bypass is deliberate. The schema already requires `fn` to be PRESENT
    /// on a `broadcast` node (`$defs/ExpressionNode/allOf`), so a missing-`fn`
    /// document cannot reach `validate()` through `load()` — but a document
    /// built programmatically, or parsed by a caller that skipped schema
    /// validation, can, and `validate()` must not wave it through. What the
    /// schema CANNOT express is the value constraint (§4.3.4: `fn` must name a
    /// scalar operator, applied at a legal arity); that is what these tests pin.
    fn broadcast_findings(expr: &str) -> Vec<StructuralError> {
        let file: EsmFile =
            serde_json::from_str(&doc_with_observed_expr(expr)).expect("fixture deserializes");
        let result = validate(&file);
        result
            .structural_errors
            .into_iter()
            .filter(|e| matches!(e.code, StructuralErrorCode::InvalidBroadcastFn))
            .collect()
    }

    /// The headline case from the issue: `fn` names an operator that is not in
    /// the registry at all, and `validate()` returned `is_valid: true`.
    #[test]
    fn unregistered_broadcast_fn_is_a_structural_error() {
        let expr = r#"{"op": "broadcast", "fn": "not_a_real_op", "args": ["x"]}"#;
        // Through the real `load()` — the schema accepts any `fn` STRING, so
        // this is exactly the document the issue reported as `is_valid: true`.
        let file = crate::parse::load(&doc_with_observed_expr(expr)).expect("fixture loads");
        let result = validate(&file);
        assert!(
            !result.is_valid,
            "an unregistered `broadcast.fn` must fail validation"
        );
        let found = broadcast_findings(expr);
        assert_eq!(found.len(), 1, "expected one finding, got {found:?}");
        assert_eq!(found[0].path, "/models/M/equations/0/rhs");
        assert!(
            found[0].message.contains("not_a_real_op"),
            "the message must name the offending fn: {}",
            found[0].message
        );
    }

    /// A MISSING `fn` silently became `+` in all three evaluators. It is
    /// rejected at BOTH layers: the schema requires the field to be present, and
    /// `validate()` reports it for a document that never went through the schema.
    #[test]
    fn missing_broadcast_fn_is_rejected_at_both_layers() {
        let expr = r#"{"op": "broadcast", "args": ["x", "x"]}"#;
        assert!(
            crate::parse::load(&doc_with_observed_expr(expr)).is_err(),
            "the schema requires `fn` on a `broadcast` node"
        );
        let found = broadcast_findings(expr);
        assert_eq!(found.len(), 1, "expected one finding, got {found:?}");
        assert_eq!(found[0].details["broadcast_fn"], serde_json::Value::Null);
    }

    /// §4.3.4 requires a SCALAR operator; the array/tensor ops are not.
    #[test]
    fn non_scalar_broadcast_fn_is_a_structural_error() {
        for f in ["aggregate", "index", "broadcast", "makearray"] {
            let expr = format!(r#"{{"op": "broadcast", "fn": "{f}", "args": ["x"]}}"#);
            let found = broadcast_findings(&expr);
            assert_eq!(
                found.len(),
                1,
                "fn `{f}`: expected one finding, got {found:?}"
            );
        }
    }

    /// An `fn`/`args` arity mismatch is reported too — `min` of one operand and
    /// `sin` of two are exactly as wrong as their bare spellings.
    #[test]
    fn broadcast_fn_arity_mismatch_is_a_structural_error() {
        for (f, args) in [
            ("min", r#"["x"]"#),
            ("sin", r#"["x", "x"]"#),
            ("/", r#"["x"]"#),
        ] {
            let expr = format!(r#"{{"op": "broadcast", "fn": "{f}", "args": {args}}}"#);
            let found = broadcast_findings(&expr);
            assert_eq!(
                found.len(),
                1,
                "fn `{f}`: expected one finding, got {found:?}"
            );
            assert_eq!(found[0].details["broadcast_fn"], f);
        }
    }

    /// The legal spellings must stay legal — including the ONE-operand unary
    /// form, which is an authored in-tree idiom (`tests/display/
    /// structural_ops.json`, `canonicalize.rs`), and the one-operand n-ary
    /// form (`tests/property_corpus/expressions/expr_039.json`).
    #[test]
    fn well_formed_broadcasts_produce_no_finding() {
        for expr in [
            r#"{"op": "broadcast", "fn": "exp", "args": ["x"]}"#,
            r#"{"op": "broadcast", "fn": "-", "args": ["x"]}"#,
            r#"{"op": "broadcast", "fn": "neg", "args": ["x"]}"#,
            r#"{"op": "broadcast", "fn": "+", "args": ["x"]}"#,
            r#"{"op": "broadcast", "fn": "+", "args": ["x", "x"]}"#,
            r#"{"op": "broadcast", "fn": "min", "args": ["x", "x"]}"#,
            r#"{"op": "broadcast", "fn": "*", "args": ["x", "x", "x"]}"#,
            r#"{"op": "broadcast", "fn": "ifelse", "args": ["x", "x", "x"]}"#,
        ] {
            assert!(
                broadcast_findings(expr).is_empty(),
                "`{expr}` must remain valid"
            );
        }
    }

    /// The check rides the shared expression walker, so it reaches every
    /// expression-bearing block — not just equation sides. A `broadcast` buried
    /// in an `aggregate.expr` sidecar is found, at the enclosing field's pointer.
    #[test]
    fn broadcast_fn_is_checked_inside_sidecar_fields() {
        let expr = r#"{"op": "aggregate", "output_idx": ["i"], "args": [],
                       "ranges": {"i": [1, 3]},
                       "expr": {"op": "broadcast", "fn": "nope", "args": ["x"]}}"#;
        let found = broadcast_findings(expr);
        assert_eq!(found.len(), 1, "expected one finding, got {found:?}");
        assert_eq!(found[0].path, "/models/M/equations/0/rhs");
    }
}
