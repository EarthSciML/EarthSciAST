use super::*;
use indexmap::IndexMap;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// Top-level ESM file structure
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EsmFile {
    /// Format version string (semver)
    pub esm: String,

    /// Authorship, provenance, description
    pub metadata: Metadata,

    /// Document-scoped index-set registry (RFC semiring-faq-unified-ir §5.2,
    /// v0.8.0). A single registry shared by every model in the document; it
    /// unifies grid dims and categorical index sets and is referenced from
    /// `aggregate`/`arrayop` `ranges` via `{ "from": <name> }` and from
    /// variable `shape`s. Declared once at the document top level (a sibling of
    /// `models`/`domain`), no longer per-`Model`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub index_sets: Option<IndexMap<String, IndexSet>>,

    /// Document-scoped, OPTIONAL registry of coordinate variables
    /// (RFC streaming-output-sinks §8.3), keyed by name.
    ///
    /// Purely additive: a document without it validates and emits exactly as
    /// before (bare integer axes). Each entry marks an existing data array —
    /// referenced by name, exactly as a `ragged` [`IndexSet`] references its
    /// `offsets`/`values` factors — or an inline literal `values` vector as a
    /// physical coordinate, and attaches CF metadata. It is read by
    /// [`crate::data_output::derive_output_meta`] so a streaming writer can
    /// emit CF dimension/auxiliary coordinates.
    ///
    /// The key is already in `esm-schema.json` and in the Julia `EsmFile`, but
    /// the Rust binding did not model it at all — so a `parse → emit` round
    /// trip silently DROPPED the whole registry (the same class of defect as
    /// the `IndexSet::member_factor` omission below).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub coordinates: Option<IndexMap<String, Coordinate>>,

    /// Top-level rewrite-rule registry — the payload of a template-library file
    /// (esm-spec §9.7.1).
    ///
    /// A DECLARATION, and a peer of `index_sets` — not an
    /// `apply_expression_template` call site. Option A expands call sites; it
    /// does not delete declarations (§9.6.4 rule 5), so this survives
    /// `parse → emit` VERBATIM and a template-library file round-trips to
    /// itself. Held as raw JSON precisely so that "verbatim" is achievable: a
    /// typed re-serialization could not promise byte-identity.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expression_templates: Option<serde_json::Value>,

    /// Top-level metaparameter block (esm-spec §9.7.1) — likewise a DECLARATION
    /// that survives `parse → emit` verbatim (§9.6.4 rule 5).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub metaparameters: Option<serde_json::Value>,

    /// ODE-based model components, keyed by unique identifier
    #[serde(skip_serializing_if = "Option::is_none")]
    pub models: Option<IndexMap<String, Model>>,

    /// Reaction network components, keyed by unique identifier
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reaction_systems: Option<IndexMap<String, ReactionSystem>>,

    /// Document-scoped ingest registry (esm-spec §8): named external data
    /// sources, keyed by id. NOT components — a source is not a coupling
    /// endpoint, a subsystem, or a scoped-reference path root; a model consumes
    /// one through a parameter `update` naming it.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data_sources: Option<IndexMap<String, DataSource>>,

    /// Registered runtime operators (by reference)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub operators: Option<IndexMap<String, Operator>>,

    /// File-local enum declarations (esm-spec §9.3): each entry maps a
    /// symbolic name to a positive integer. The `enum` AST op resolves to a
    /// `const` integer at load time using these mappings.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub enums: Option<IndexMap<String, IndexMap<String, i64>>>,

    /// Composition and coupling rules
    #[serde(skip_serializing_if = "Option::is_none")]
    pub coupling: Option<Vec<CouplingEntry>>,

    /// Coupling-library formal component roles (esm-spec §10.9). Present only
    /// in a coupling-library file, which pairs it with a role-scoped `coupling`
    /// array and declares no models/reaction_systems/data_sources/domain/
    /// index_sets/metaparameters/expression_templates. Presence of this key is
    /// the sole positive identifier of the coupling-library file kind.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub coupling_roles: Option<IndexMap<String, CouplingRole>>,

    /// The single temporal domain shared by every component in the document
    /// (v0.8.0). A document has at most one domain; all spatial models live on
    /// it, and 0-D models simply have scalar-shaped variables. Spatiality is
    /// determined by variable shape, not by a per-component domain reference.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub domain: Option<Domain>,

    /// Component-scoped sampled function tables (esm-spec §9.5, v0.4.0).
    /// Keys are table ids; values are `FunctionTable` entries referenced by
    /// `table_lookup` AST nodes.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub function_tables: Option<IndexMap<String, FunctionTable>>,

    /// The per-component `expression_templates` registries, captured at LOAD
    /// before the Expand-at-build pass strips them from the document
    /// (esm-spec §9.6.4 Option B, RFC out-of-line-expression-templates §7.7).
    /// Keyed `"models.<name>"` / `"reaction_systems.<name>"`, in document
    /// order, each value the component's registry object VERBATIM (post
    /// `expression_template_imports` resolution).
    ///
    /// NOT a wire field: `#[serde(skip)]` keeps it out of both directions, so a
    /// `parse -> emit` round trip is byte-identical and a document is never
    /// asked to carry it. It exists because
    /// [`crate::flatten::merged_template_registry`] must reconstruct the
    /// step-4 merged registry, and the typed structs — by design — never see an
    /// `expression_templates` block. Mirrors the Python oracle's
    /// `EsmFile.component_templates`.
    #[serde(default, skip)]
    pub component_templates: Option<IndexMap<String, serde_json::Value>>,
}

/// The empty document: every optional section absent, `esm` set to
/// [`crate::SCHEMA_VERSION`]. A manual impl rather than a derive because the
/// derived `esm: String::new()` is not a version at all — the schema requires
/// a semver string — whereas the current-spec empty document is a coherent
/// value to spread from (`EsmFile { models: Some(..), ..Default::default() }`).
impl Default for EsmFile {
    fn default() -> Self {
        EsmFile {
            esm: crate::SCHEMA_VERSION.to_string(),
            metadata: Metadata::default(),
            index_sets: None,
            coordinates: None,
            expression_templates: None,
            metaparameters: None,
            models: None,
            reaction_systems: None,
            data_sources: None,
            operators: None,
            enums: None,
            coupling: None,
            coupling_roles: None,
            domain: None,
            function_tables: None,
            component_templates: None,
        }
    }
}

/// A single named axis inside a [`FunctionTable`] (esm-spec §9.5).
///
/// `values` MUST be strictly-increasing finite floats with at least 2 entries
/// (mirrors the §9.2 interp.linear / interp.bilinear axis contract). `units`
/// is advisory only in v0.4.0 — recorded for documentation, not used for
/// load-time unit-checking.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FunctionTableAxis {
    /// Axis identifier; used as the key in `table_lookup.axes`.
    pub name: String,

    /// Strictly-increasing finite floats, ≥ 2 entries.
    pub values: Vec<f64>,

    /// Optional advisory units string.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub units: Option<String>,
}

/// A sampled function table referenced by `table_lookup` AST op nodes
/// (esm-spec §9.5, v0.4.0).
///
/// Tables are syntactic sugar over §9.2's `interp.linear` / `interp.bilinear`
/// / `index` — a `table_lookup` query MUST be bit-equivalent to the
/// equivalent inline-`const` lookup. Shape of `data` is
/// `[len(outputs), len(axes[0].values), len(axes[1].values), ...]` when
/// `outputs` is `Some`; `[len(axes[0].values), ...]` otherwise.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FunctionTable {
    /// Ordered list of named axes (1 or 2 in v0.4.0, matching the
    /// `interp.linear` / `interp.bilinear` arity).
    pub axes: Vec<FunctionTableAxis>,

    /// Nested-array literal of finite numbers.
    pub data: serde_json::Value,

    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,

    /// `"linear"` | `"bilinear"` | `"nearest"`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub interpolation: Option<String>,

    /// `"clamp"` | `"error"`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub out_of_bounds: Option<String>,

    /// Optional ordered output names.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub outputs: Option<Vec<String>>,

    /// Optional redundant shape assertion.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub shape: Option<Vec<u64>>,

    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub schema_version: Option<String>,
}

/// Academic citation or data source reference
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Reference {
    /// DOI identifier
    #[serde(skip_serializing_if = "Option::is_none")]
    pub doi: Option<String>,

    /// Full citation text
    #[serde(skip_serializing_if = "Option::is_none")]
    pub citation: Option<String>,

    /// URL reference
    #[serde(skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,

    /// Additional notes
    #[serde(skip_serializing_if = "Option::is_none")]
    pub notes: Option<String>,
}

/// Metadata section
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Metadata {
    /// Human-readable model name
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,

    /// Brief description
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,

    /// Authors/contributors
    #[serde(skip_serializing_if = "Option::is_none")]
    pub authors: Option<Vec<String>>,

    /// License information
    #[serde(skip_serializing_if = "Option::is_none")]
    pub license: Option<String>,

    /// Creation timestamp (ISO 8601)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub created: Option<String>,

    /// Last modification timestamp (ISO 8601)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub modified: Option<String>,

    /// Tags for categorization
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tags: Option<Vec<String>>,

    /// Academic citations and references
    #[serde(skip_serializing_if = "Option::is_none")]
    pub references: Option<Vec<Reference>>,

    /// System classification stamped by `discretize()` per RFC §12:
    /// `"ode"` if no algebraic equations remain after discretization,
    /// `"dae"` if any algebraic equations remain. Absent on undiscretized
    /// inputs.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub system_class: Option<String>,

    /// DAE classification details stamped by `discretize()` per RFC §12.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub dae_info: Option<DaeInfo>,

    /// Provenance stamp identifying the source document `discretize()` was
    /// called on. Absent on undiscretized inputs.
    ///
    /// The schema types this an OBJECT (`{"name": …}`), not a bare string. It
    /// was declared `Option<String>` here until 2026-08-31, which made a
    /// schema-valid discretized document a hard serde DESERIALIZATION ERROR on
    /// load, and made this binding's own `discretize()` emit a schema-INVALID
    /// bare string. No corpus fixture stamped it, so nothing caught either
    /// half; `tests/valid/metadata_discretized_stamps.esm` now does.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub discretized_from: Option<DiscretizedFrom>,

    /// Reserved extension point for downstream-catalog machine-readable
    /// metadata (e.g. the EarthSciDiscretizations rule-library catalog).
    ///
    /// Free-form JSON: the schema validates only that this is an object, and
    /// its description is normative that core tooling "MUST NOT assign meaning
    /// to them and MUST preserve them across parse → emit like any other
    /// metadata field" (esm-spec §3). So it is held as an opaque
    /// [`serde_json::Value`] and never inspected — round-tripping the author's
    /// content verbatim is the whole contract.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub x_esd: Option<serde_json::Value>,
}

/// Provenance stamp written to `metadata.discretized_from` by `discretize()`
/// per RFC §12: identifies the source document the discretized one came from.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct DiscretizedFrom {
    /// The `metadata.name` of the source document.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
}

/// Summary of DAE classification stamped onto `metadata.dae_info` by
/// `discretize()` per RFC §12.
///
/// `algebraic_equation_count` is the post-`discretize()` total across all
/// models; `per_model` breaks it down by model name. `factored_equation_count`
/// is rust-binding-specific — it reports the number of trivially
/// substitutable algebraic equations the preprocessor eliminated before
/// classification (see `docs/rfcs/dae-binding-strategies.md`). `0` on
/// bindings that do not perform trivial factoring.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct DaeInfo {
    /// Total algebraic equations remaining after `discretize()` completes.
    pub algebraic_equation_count: usize,

    /// Per-model count, keyed by model name.
    pub per_model: HashMap<String, usize>,

    /// rust-binding-specific: number of trivially substitutable algebraic
    /// equations factored into the ODE system by the preprocessor. `None`
    /// on bindings that do not factor.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub factored_equation_count: Option<usize>,
}
