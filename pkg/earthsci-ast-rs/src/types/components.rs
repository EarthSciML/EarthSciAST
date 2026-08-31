use super::*;
use indexmap::IndexMap;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// Reaction network component
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ReactionSystem {
    /// Academic citation or data source reference
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reference: Option<Reference>,

    /// Chemical species, keyed by species name
    pub species: IndexMap<String, Species>,

    /// Named parameters (rate constants, temperature, photolysis rates, etc.)
    pub parameters: IndexMap<String, Parameter>,

    /// Chemical reactions
    pub reactions: Vec<Reaction>,

    /// Additional algebraic or ODE constraints
    #[serde(skip_serializing_if = "Option::is_none")]
    pub constraint_equations: Option<Vec<Equation>>,

    /// Discrete events
    #[serde(skip_serializing_if = "Option::is_none")]
    pub discrete_events: Option<Vec<DiscreteEvent>>,

    /// Continuous events
    #[serde(skip_serializing_if = "Option::is_none")]
    pub continuous_events: Option<Vec<ContinuousEvent>>,

    /// Named child reaction systems (subsystems), keyed by unique identifier
    #[serde(skip_serializing_if = "Option::is_none")]
    pub subsystems: Option<IndexMap<String, serde_json::Value>>,

    /// System-level default numerical tolerance for inline tests (schema
    /// `ReactionSystem.tolerance`, the [`Model::tolerance`] counterpart);
    /// previously unmodelled here and so dropped on round trip — as were
    /// `tests` and `analyses` below.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tolerance: Option<Tolerance>,

    /// Inline validation tests that exercise this reaction system in
    /// isolation (schema `ReactionSystem.tests`, same `Test` entries as
    /// [`Model::tests`]).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tests: Option<Vec<ModelTest>>,

    /// Inline illustrative analyses of how to run this reaction system
    /// (schema `ReactionSystem.analyses`, same `Analysis` entries as
    /// [`Model::analyses`]).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub analyses: Option<Vec<ModelAnalysis>>,
}

/// Chemical species in a reaction system. Keyed by name in the parent map.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Species {
    /// Physical units
    #[serde(skip_serializing_if = "Option::is_none")]
    pub units: Option<String>,

    /// Default/initial concentration
    #[serde(skip_serializing_if = "Option::is_none")]
    pub default: Option<f64>,

    /// The unit the `default` VALUE is expressed in, when it is not the
    /// species' declared `units` (schema `Species.default_units`); previously
    /// unmodelled here and so dropped on round trip. See
    /// [`ModelVariable::default_units`].
    #[serde(skip_serializing_if = "Option::is_none")]
    pub default_units: Option<String>,

    /// Brief description
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,

    /// Reservoir species: participates in reactions but held fixed (no ODE).
    /// Maps to Catalyst's `isconstantspecies=true`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub constant: Option<bool>,
}

/// Parameter in a reaction system.
///
/// Carries the same value machinery as a model parameter (schema
/// `Parameter`): a fixed `default` or a `distribution`, with an optional
/// `update` saying when it refreshes — so the field set mirrors the
/// parameter-side of [`ModelVariable`]. This struct previously modelled only
/// `units`/`default`/`description`, silently DROPPING the rest on a
/// `parse → emit` round trip (a `{kind: "data", …}` update block among them).
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Parameter {
    /// Physical units
    #[serde(skip_serializing_if = "Option::is_none")]
    pub units: Option<String>,

    /// Default/initial value
    #[serde(skip_serializing_if = "Option::is_none")]
    pub default: Option<f64>,

    /// The unit the `default` VALUE is expressed in, when it is not the
    /// parameter's declared `units`. See [`ModelVariable::default_units`].
    #[serde(skip_serializing_if = "Option::is_none")]
    pub default_units: Option<String>,

    /// Brief description
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,

    /// Arrayed-parameter shape: ordered index-set names from the
    /// document-scoped `index_sets` registry. `None` means scalar. See
    /// [`ModelVariable::shape`].
    #[serde(skip_serializing_if = "Option::is_none")]
    pub shape: Option<Vec<String>>,

    /// Draw the value from a distribution instead of fixing it at `default`
    /// (mutually exclusive with `default`). See [`ModelVariable::distribution`].
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub distribution: Option<Distribution>,

    /// When this parameter refreshes and what it refreshes from
    /// (esm-spec §5.4). See [`ModelVariable::update`].
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub update: Option<ParameterUpdateSpec>,
}

/// Chemical reaction
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Reaction {
    /// Unique reaction identifier
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,

    /// Human-readable reaction name
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,

    /// Reactant species and stoichiometry. May be null for source reactions (∅ → X).
    /// Schema requires this field to be present (possibly null).
    #[serde(default)]
    pub substrates: Option<Vec<StoichiometricEntry>>,

    /// Product species and stoichiometry. May be null for sink reactions (X → ∅).
    /// Schema requires this field to be present (possibly null).
    #[serde(default)]
    pub products: Option<Vec<StoichiometricEntry>>,

    /// Rate law expression
    pub rate: Expr,

    /// Academic citation or data source reference
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reference: Option<Reference>,
}

/// Species with stoichiometric coefficient.
///
/// v0.2.x permits fractional coefficients (e.g. `0.87 CH2O` in atmospheric
/// chemistry) in addition to the historical integer case. The coefficient
/// MUST be positive and finite — NaN / ±∞ are rejected at parse time by
/// [`validate_stoichiometries`](crate::parse::validate_stoichiometries).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StoichiometricEntry {
    /// Species name
    pub species: String,

    /// Stoichiometric coefficient (positive finite number; serialized as `stoichiometry`)
    #[serde(
        rename = "stoichiometry",
        default = "default_stoichiometry",
        serialize_with = "serialize_stoichiometry"
    )]
    pub coefficient: f64,
}

fn default_stoichiometry() -> f64 {
    1.0
}

/// Emit a stoichiometric coefficient in ESM canonical-number form
/// (CONFORMANCE_SPEC.md §5.5.3.1 rule 1): an integral, `i64`-representable
/// value becomes an INTEGER literal, so the overwhelmingly common `1` stays
/// `1` across a parse / re-emit cycle instead of becoming `1.0`. Derived serde
/// would emit the trailing `.0` and diverge from all four sibling bindings,
/// each of which normalizes this field (Julia and Python `_emit_stoich`, Go
/// `canonicalFloat64String`, TypeScript implicitly via `JSON.stringify`).
///
/// A by-reference adapter and nothing more: `serialize_with` hands the field
/// by reference, while the shared [`serialize_canonical_f64`] takes a value.
fn serialize_stoichiometry<S: serde::Serializer>(
    n: &f64,
    serializer: S,
) -> Result<S::Ok, S::Error> {
    serialize_canonical_f64(*n, serializer)
}

/// Generic, runtime-agnostic description of an external data source
/// (esm-spec §8).
///
/// A `DataSource` is pure I/O (RFC pure-io-data-loaders §4.1): it locates,
/// reads, decodes, slices and filters bytes and nothing else. From esm 1.0.0 it
/// **exposes no variables and is not a component** — not a coupling endpoint,
/// not a subsystem, not a scoped-name path root. A model consumes it by
/// declaring a PARAMETER whose [`ParameterUpdate::Data`] names this entry and
/// binds one of its file variables ([`DataSourceBinding`]); the parameter owns
/// the units. Grid geometry a source reads arrives the same way, as ordinary
/// parameters, and is transformed downstream by `aggregate` FAQs.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DataSource {
    /// Structural kind of the dataset. Scientific role (emissions,
    /// meteorology, elevation, ...) is not schema-validated and belongs in
    /// `metadata.tags`.
    pub kind: DataSourceKind,

    /// File discovery configuration.
    pub source: DataSourceLocation,

    /// Temporal coverage and record layout. ABSENT means non-time-varying,
    /// which is what refines a `data`-updated parameter's cadence seed from
    /// DISCRETE down to CONST (CONFORMANCE_SPEC.md §5.7.2).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub temporal: Option<DataSourceTemporal>,

    /// Reproducibility contract — endian / float_format / integer_width
    /// (esm-spec §8.9.2). A binding that cannot honor the declared
    /// contract MUST reject the file at load.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub determinism: Option<DataSourceDeterminism>,

    /// Format-specific DECODE options, passed through to the format reader
    /// verbatim (esm-spec §8.9.1). Held as raw JSON — the set of keys is the
    /// bound reader's, not the schema's.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reader_options: Option<serde_json::Value>,

    /// Source-level default slicing (esm-spec §8.9.2), overridable per
    /// parameter by [`DataSourceBinding::select`]. Raw JSON passthrough.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub select: Option<serde_json::Value>,

    /// Which records are real (esm-spec §8.9.3). Raw JSON passthrough.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub record_filter: Option<serde_json::Value>,

    /// A source that discovers its own size (esm-spec §8.9.4). Raw JSON
    /// passthrough.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub extent: Option<serde_json::Value>,

    /// Academic citation or data source reference.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reference: Option<Reference>,

    /// Free-form metadata about the data source. Tags convey scientific role.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub metadata: Option<DataSourceMetadata>,
}

/// Structural kind of a data loader dataset.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DataSourceKind {
    /// Gridded dataset.
    Grid,
    /// Point / observational dataset.
    Points,
    /// Static dataset (no time dimension).
    Static,
}

/// Reproducibility contract a loader advertises to bindings
/// (esm-spec §8.9.2).
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct DataSourceDeterminism {
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub endian: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub float_format: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub integer_width: Option<u32>,
}

/// File discovery configuration. Describes how to locate data files at
/// runtime via URL templates with date/variable substitutions.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DataSourceLocation {
    /// Jinja-style URL template with substitutions. Supported:
    /// `{date:<strftime>}` (e.g. `{date:%Y%m%d}`), `{var}`, `{sector}`,
    /// `{species}`. Custom substitutions are allowed and must be passed
    /// through by the runtime.
    pub url_template: String,

    /// Ordered fallback URL templates. Runtime tries each in order.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mirrors: Option<Vec<String>>,
}

/// Temporal coverage and record layout for a data source.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct DataSourceTemporal {
    /// ISO 8601 datetime — first timestamp available from this source.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub start: Option<String>,

    /// ISO 8601 datetime — last timestamp available from this source.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub end: Option<String>,

    /// ISO 8601 duration describing how much time one file covers.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub file_period: Option<String>,

    /// ISO 8601 duration describing spacing between samples within a file.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub frequency: Option<String>,

    /// Number of time records per file. `"auto"` means read from file at
    /// runtime.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub records_per_file: Option<RecordsPerFile>,

    /// Name of the time coordinate variable in the file. Used when
    /// `records_per_file` is absent or `"auto"`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub time_variable: Option<String>,
}

/// Number of records per file — an integer, or the literal `"auto"`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum RecordsPerFile {
    /// Fixed count (`>= 1`).
    Count(u32),
    /// `"auto"` — read from file at runtime.
    Auto(AutoRecords),
}

/// Carrier for the `"auto"` literal in [`RecordsPerFile`].
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AutoRecords {
    /// Runtime discovers the record count from file metadata.
    Auto,
}

/// Multiplicative factor (number) or Expression AST used to convert source-
/// file values to the declared units.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
// Boxing the large variant would change the wire-facing construction/match
// ergonomics on one of the crate's most-touched types for a size win that
// profiling has not justified; when a variant IS boxed the field carries its
// own rationale (see AssertionReference::Expression).
#[allow(clippy::large_enum_variant)]
pub enum UnitConversion {
    /// Simple multiplicative factor.
    Factor(f64),
    /// Expression AST applied to the source value.
    Expression(Expr),
}

/// Free-form metadata about a data loader.
///
/// The `tags` field is conventional for expressing scientific role
/// (e.g. `"emissions"`, `"reanalysis"`) and is not schema-validated.
/// Additional fields are preserved as raw JSON via `extra`.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct DataSourceMetadata {
    /// Scientific role tags (freeform).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tags: Option<Vec<String>>,

    /// Additional, loader-specific metadata fields.
    #[serde(flatten)]
    pub extra: HashMap<String, serde_json::Value>,
}

/// Runtime operator reference
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Operator {
    /// Registered identifier the runtime uses to find the implementation
    pub operator_id: String,

    /// Variables required by the operator
    pub needed_vars: Vec<String>,

    /// Variables the operator modifies
    #[serde(skip_serializing_if = "Option::is_none")]
    pub modifies: Option<Vec<String>>,

    /// Academic citation or data source reference
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reference: Option<Reference>,

    /// Implementation-specific configuration
    #[serde(skip_serializing_if = "Option::is_none")]
    pub config: Option<serde_json::Value>,

    /// Brief description
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
}

/// A `variable_map` coupling `transform` (esm-spec §10.4): either one of the
/// legacy NAMED transform strings (`"param_to_var"`, `"identity"`,
/// `"additive"`, `"multiplicative"`, `"conversion_factor"`) or an Expression
/// evaluated on the source value(s) in the flattened coupled system's scope
/// (the v0.8.0 additive widening — the regridding form).
///
/// On the wire an Expression transform is always an operator-node OBJECT: the
/// degenerate bare-reference and literal Expression spellings are not
/// admissible (the named string transforms already cover bare replacement,
/// and the string space is reserved for them), so a JSON string deserializes
/// to [`VariableMapTransform::Named`], an object to
/// [`VariableMapTransform::Expression`], and a bare number is rejected.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
// Boxing the large variant would change the wire-facing construction/match
// ergonomics on one of the crate's most-touched types for a size win that
// profiling has not justified; when a variant IS boxed the field carries its
// own rationale (see AssertionReference::Expression).
#[allow(clippy::large_enum_variant)]
pub enum VariableMapTransform {
    /// Legacy named transform string.
    Named(String),
    /// Expression transform: an operator node whose variable references are
    /// fully scoped and which MUST reference the entry's `from` variable
    /// (esm-spec §10.4). Template invocations inside it are expanded at load.
    Expression(ExpressionNode),
}

impl VariableMapTransform {
    /// The named transform string, if this is the legacy string form.
    pub fn as_named(&self) -> Option<&str> {
        match self {
            VariableMapTransform::Named(s) => Some(s.as_str()),
            VariableMapTransform::Expression(_) => None,
        }
    }

    /// The Expression operator node, if this is the expression form.
    pub fn as_expression(&self) -> Option<&ExpressionNode> {
        match self {
            VariableMapTransform::Named(_) => None,
            VariableMapTransform::Expression(node) => Some(node),
        }
    }

    /// Whether this is the expression form.
    pub fn is_expression(&self) -> bool {
        matches!(self, VariableMapTransform::Expression(_))
    }
}

impl std::fmt::Display for VariableMapTransform {
    /// Named transforms display as their string; expression transforms as the
    /// fixed token `expression` (matching the Julia / Python provenance
    /// descriptions in `coupling_rules_applied`).
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            VariableMapTransform::Named(s) => write!(f, "{s}"),
            VariableMapTransform::Expression(_) => write!(f, "expression"),
        }
    }
}

/// Coupling entry with discriminated union based on type field
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
// Boxing the large variant would change the wire-facing construction/match
// ergonomics on one of the crate's most-touched types for a size win that
// profiling has not justified; when a variant IS boxed the field carries its
// own rationale (see AssertionReference::Expression).
#[allow(clippy::large_enum_variant)]
pub enum CouplingEntry {
    /// Operator composition coupling
    OperatorCompose {
        /// The two systems to compose
        systems: Vec<String>,
        /// Variable mappings when LHS variables don't have matching names
        #[serde(skip_serializing_if = "Option::is_none")]
        translate: Option<serde_json::Value>,
        /// Spatial-lift strategy for the merged state ODEs (esm-spec §10.5).
        /// `"pointwise"` array-ifies each merged reaction+operator state ODE onto
        /// the operator's grid (the flattener's pointwise lift); `None` leaves the
        /// merged 0-D equations as-is.
        #[serde(skip_serializing_if = "Option::is_none")]
        lifting: Option<String>,
        /// Optional description
        #[serde(skip_serializing_if = "Option::is_none")]
        description: Option<String>,
    },
    /// Bi-directional coupling via explicit ConnectorSystem equations
    Couple {
        /// The two systems involved in coupling
        systems: Vec<String>,
        /// Connector definition with equations
        connector: serde_json::Value,
        /// Strategy for mapping between 0-D and spatial systems — one of
        /// `pointwise`, `broadcast`, `mean`, `integral`. Schema-declared on
        /// `CouplingCouple` exactly as on `CouplingOperatorCompose`; carried
        /// so an authored value survives parse → emit.
        #[serde(skip_serializing_if = "Option::is_none")]
        lifting: Option<String>,
        /// Optional description
        #[serde(skip_serializing_if = "Option::is_none")]
        description: Option<String>,
    },
    /// Variable mapping between systems
    VariableMap {
        /// Source variable (scoped reference)
        from: String,
        /// Target parameter (scoped reference)
        to: String,
        /// How the mapping is applied: a named transform string or an
        /// Expression operator node (esm-spec §10.4).
        transform: VariableMapTransform,
        /// Conversion factor (for the scaling transforms only — not
        /// permitted with an Expression transform)
        #[serde(skip_serializing_if = "Option::is_none")]
        factor: Option<f64>,
        /// Strategy for mapping between 0-D and spatial systems — one of
        /// `pointwise`, `broadcast`, `mean`, `integral`. Schema-declared on
        /// `CouplingVariableMap` exactly as on `CouplingOperatorCompose`;
        /// carried so an authored value survives parse → emit.
        #[serde(skip_serializing_if = "Option::is_none")]
        lifting: Option<String>,
        /// Optional description
        #[serde(skip_serializing_if = "Option::is_none")]
        description: Option<String>,
    },
    /// Apply operator to system
    OperatorApply {
        /// Operator reference
        operator: String,
        /// Optional description
        #[serde(skip_serializing_if = "Option::is_none")]
        description: Option<String>,
    },
    /// Callback coupling
    Callback {
        /// Registered identifier for the callback
        callback_id: String,
        /// Configuration parameters
        #[serde(skip_serializing_if = "Option::is_none")]
        config: Option<serde_json::Value>,
        /// Optional description
        #[serde(skip_serializing_if = "Option::is_none")]
        description: Option<String>,
    },
    /// Event-based coupling
    Event {
        /// Whether this is a continuous or discrete event
        event_type: String,
        /// Human-readable identifier
        #[serde(skip_serializing_if = "Option::is_none")]
        name: Option<String>,
        /// Condition expressions (zero-crossing for continuous, boolean for discrete)
        #[serde(skip_serializing_if = "Option::is_none")]
        conditions: Option<Vec<Expr>>,
        /// Trigger specification (for discrete events)
        #[serde(skip_serializing_if = "Option::is_none")]
        trigger: Option<DiscreteEventTrigger>,
        /// Affect equations. esm 1.0.0: `affects` is the ONLY affect channel.
        /// The 0.x `functional_affect` handler descriptor and the
        /// `discrete_parameters` list are gone (RFC unified-variable-model D5)
        /// — a parameter that changes during a run carries its own `update`
        /// block, so every affect LHS names an unknown. The schema's
        /// `CouplingEvent` def is `additionalProperties: false`, so either key
        /// is a schema-layer rejection rather than a silently dropped field.
        #[serde(skip_serializing_if = "Option::is_none")]
        affects: Option<Vec<AffectEquation>>,
        /// Separate affects for negative-going zero crossings
        #[serde(skip_serializing_if = "Option::is_none")]
        affect_neg: Option<Vec<AffectEquation>>,
        /// Root finding direction
        #[serde(skip_serializing_if = "Option::is_none")]
        root_find: Option<RootFindDirection>,
        /// Whether to reinitialize the system after the event
        #[serde(skip_serializing_if = "Option::is_none")]
        reinitialize: Option<bool>,
        /// Brief description
        #[serde(skip_serializing_if = "Option::is_none")]
        description: Option<String>,
    },
    /// Reuse of a coupling-library file (esm-spec §10.9, §10.10): imports the
    /// library named by `ref` and binds each of its declared roles to an
    /// assembly component. Expands at flatten into concrete
    /// `variable_map`/`couple`/`operator_compose`/`event` edges by substituting
    /// bound actuals for role names; the entry itself round-trips intact.
    CouplingImport {
        /// §4.7 reference to a coupling-library file (a document with a
        /// top-level `coupling_roles` map). `ref` is a Rust keyword, so the
        /// field is spelled `reference` and renamed on the wire.
        #[serde(rename = "ref")]
        reference: String,
        /// Total map from every library role name to a scoped component
        /// reference in the assembly (esm-spec §10.10.1).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        bind: Option<HashMap<String, String>>,
        /// Optional description
        #[serde(skip_serializing_if = "Option::is_none")]
        description: Option<String>,
    },
}

/// A coupling-library formal component role (esm-spec §10.9). Present only in
/// a coupling-library file's top-level `coupling_roles` map; each entry carries
/// an optional human-readable description. Roles are formal parameters (names,
/// not types), bound to actual components at a `coupling_import`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CouplingRole {
    /// Human-readable description of the role.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
}

/// Spatial/temporal domain specification
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Domain {
    /// Name of the independent (time) variable
    #[serde(skip_serializing_if = "Option::is_none")]
    pub independent_variable: Option<String>,

    /// Temporal domain
    #[serde(skip_serializing_if = "Option::is_none")]
    pub temporal: Option<serde_json::Value>,

    /// Floating point precision
    #[serde(skip_serializing_if = "Option::is_none")]
    pub element_type: Option<String>,

    /// Array backend identifier
    #[serde(skip_serializing_if = "Option::is_none")]
    pub array_type: Option<String>,
}

#[cfg(test)]
mod coupling_field_tests {
    use super::*;

    #[test]
    fn test_operator_compose_new_fields() {
        // Test OperatorCompose with new systems field
        let json = r#"{
            "type": "operator_compose",
            "systems": ["system1", "system2"]
        }"#;

        let entry: CouplingEntry = serde_json::from_str(json).unwrap();
        match entry {
            CouplingEntry::OperatorCompose { systems, .. } => {
                assert_eq!(systems, vec!["system1", "system2"]);
            }
            _ => panic!("Expected OperatorCompose variant"),
        }
    }

    #[test]
    fn test_couple_new_fields() {
        // Test Couple with new systems field
        let json = r#"{
            "type": "couple",
            "systems": ["system1", "system2"],
            "connector": {
                "equations": []
            }
        }"#;

        let entry: CouplingEntry = serde_json::from_str(json).unwrap();
        match entry {
            CouplingEntry::Couple { systems, .. } => {
                assert_eq!(systems, vec!["system1", "system2"]);
            }
            _ => panic!("Expected Couple variant"),
        }
    }

    #[test]
    fn test_variable_map_new_fields() {
        // Test VariableMap with new from/to fields
        let json = r#"{
            "type": "variable_map",
            "from": "source.var",
            "to": "target.param",
            "transform": "identity"
        }"#;

        let entry: CouplingEntry = serde_json::from_str(json).unwrap();
        match entry {
            CouplingEntry::VariableMap {
                from,
                to,
                transform,
                ..
            } => {
                assert_eq!(from, "source.var");
                assert_eq!(to, "target.param");
                assert_eq!(
                    transform,
                    crate::types::VariableMapTransform::Named("identity".to_string())
                );
            }
            _ => panic!("Expected VariableMap variant"),
        }
    }

    #[test]
    fn test_coupling_serialization_round_trip() {
        // Test serialization round-trip
        let coupling = CouplingEntry::OperatorCompose {
            lifting: None,
            systems: vec!["sys1".to_string(), "sys2".to_string()],
            translate: None,
            description: None,
        };

        let serialized = serde_json::to_string(&coupling).unwrap();
        let deserialized: CouplingEntry = serde_json::from_str(&serialized).unwrap();

        match deserialized {
            CouplingEntry::OperatorCompose { systems, .. } => {
                assert_eq!(systems, vec!["sys1", "sys2"]);
            }
            _ => panic!("Round-trip failed"),
        }
    }
}
