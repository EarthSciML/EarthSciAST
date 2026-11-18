//! JSON parsing and schema validation for ESM files

use crate::{EsmFile, error::EsmError};
// The §6.4 operator-model placeholder, taken from the scoping walker that
// treats it as a global sentinel rather than re-spelled here, so the scoping
// rule and the load-time rejection of a binder that shadows it cannot drift.
use crate::flatten::VAR_PLACEHOLDER;
use jsonschema::error::ValidationErrorKind;
use jsonschema::{Draft, Validator};
use serde_json::Value;
use std::sync::OnceLock;

/// Library version supported by this implementation (major, minor, patch),
/// derived from [`crate::SCHEMA_VERSION`] so the two can never drift.
fn library_version() -> (u32, u32, u32) {
    crate::diagnostic::parse_semver(crate::SCHEMA_VERSION)
        .expect("SCHEMA_VERSION is a valid major.minor.patch string")
}

/// Bundled ESM JSON Schema
const ESM_SCHEMA_JSON: &str = include_str!("esm-schema.json");

/// Get the compiled JSON schema (cached for performance).
///
/// The bundled schema declares Draft 2020-12, for which `jsonschema` disables
/// format validation by default. We explicitly opt in so that `format:
/// "date-time"` (and other `format` keywords in the schema) actually reject
/// malformed strings — this is required for cross-language parity with Julia
/// and Python, which both enforce format validation.
fn get_schema() -> &'static Validator {
    static SCHEMA: OnceLock<Validator> = OnceLock::new();
    SCHEMA.get_or_init(|| {
        jsonschema::options()
            .with_draft(Draft::Draft202012)
            .should_validate_formats(true)
            .build(get_schema_value())
            .expect("Bundled schema should compile successfully")
    })
}

/// The parsed (but uncompiled) schema `Value`, cached. Needed by
/// [`collect_schema_errors`] to navigate `oneOf`/`anyOf` branch sub-schemas and
/// resolve `$ref`s when descending past the shallow composition error the
/// `jsonschema` crate reports (it does not surface a failed branch's own
/// sub-errors).
fn get_schema_value() -> &'static Value {
    static SCHEMA_VALUE: OnceLock<Value> = OnceLock::new();
    SCHEMA_VALUE.get_or_init(|| {
        serde_json::from_str(ESM_SCHEMA_JSON).expect("Bundled schema should be valid JSON")
    })
}

/// Load and parse an ESM file from JSON string
///
/// This function performs both JSON parsing and schema validation.
/// It will throw an error for malformed JSON or schema violations.
///
/// # Arguments
///
/// * `json_str` - The JSON string to parse
///
/// # Returns
///
/// * `Ok(EsmFile)` - Successfully parsed and validated ESM file
/// * `Err(EsmError)` - Parse error or schema validation error
///
/// # Examples
///
/// ```rust
/// use earthsci_ast::load_string;
///
/// let json = r#"
/// {
///   "esm": "2.0.0",
///   "metadata": {
///     "name": "test_model"
///   },
///   "models": {
///     "simple": {
///       "variables": {},
///       "equations": []
///     }
///   }
/// }
/// "#;
///
/// let esm_file = load_string(json).expect("Failed to load ESM file");
/// assert_eq!(esm_file.esm, "2.0.0");
/// ```
pub fn load_string(json_str: &str) -> Result<EsmFile, EsmError> {
    load_string_with_options(json_str, &LoadOptions::default())
}

/// Load and parse an ESM document that is ALREADY parsed as a
/// [`serde_json::Value`] — the same document a `.esm` file holds, just
/// already decoded. Runs the identical pipeline [`load_string`] runs
/// (subsystem-ref resolution, version gates, schema validation, §9.7
/// template machinery, typed deserialization).
pub fn load_document(document: &Value) -> Result<EsmFile, EsmError> {
    load_document_with_options(document, &LoadOptions::default())
}

/// [`load_document`] with explicit [`LoadOptions`] (base path for relative
/// refs, loader-API metaparameter bindings; esm-spec §9.7.6).
pub fn load_document_with_options(
    document: &Value,
    options: &LoadOptions,
) -> Result<EsmFile, EsmError> {
    load_value(document.clone(), options)
}

/// [`load_document_with_options`], consuming the document.
pub(crate) fn load_document_owned(
    document: Value,
    options: &LoadOptions,
) -> Result<EsmFile, EsmError> {
    load_value(document, options)
}

/// Options controlling how [`load_string_with_options`] /
/// [`load_document_with_options`] / [`load_path_with_options`] parse an ESM
/// file (esm-spec §9.7).
#[derive(Debug, Clone, Default)]
pub struct LoadOptions {
    /// Directory anchoring relative subsystem refs and
    /// `expression_template_imports` refs (esm-spec §9.7.2). Defaults to the
    /// current working directory for string / document input; `load_path` uses the
    /// file's own directory.
    pub base_path: Option<std::path::PathBuf>,

    /// Loader-API metaparameter bindings for the ROOT document (esm-spec
    /// §9.7.6 binding site 4): name → integer. Already-closed edge bindings
    /// win; API bindings beat `default`s. Binding a name the document does
    /// not declare raises `template_import_unknown_name`.
    pub metaparameters: std::collections::BTreeMap<String, i64>,
}

/// Load and parse an ESM file from a JSON string with explicit
/// [`LoadOptions`] (base path for relative refs, loader-API metaparameter
/// bindings; esm-spec §9.7.6).
pub fn load_string_with_options(
    json_str: &str,
    options: &LoadOptions,
) -> Result<EsmFile, EsmError> {
    let json_value: Value = serde_json::from_str(json_str).map_err(EsmError::JsonParse)?;
    load_value(json_value, options)
}

/// The pipeline shared by every `load_*` entry point, over an
/// already-decoded document: the passes of [`LOAD_PASSES`] a root document
/// takes, then typing and the checks that read the typed document.
fn load_value(json_value: Value, options: &LoadOptions) -> Result<EsmFile, EsmError> {
    // Every document this load reaches by reference is read and parsed once
    // (`crate::ref_reader`): the mount-tree scan and the mount pipeline read
    // the same files.
    let _parse_cache = crate::ref_reader::ParseCacheScope::on();

    let mut doc = Doc::new(json_value, DocRole::Root, options);
    doc.run_passes()?;
    let Doc {
        value: mut json_value,
        base,
        facts,
        ..
    } = doc;

    // Deserialize into our types. The interning scope makes every
    // structurally repeated operator subtree share ONE allocation as it is
    // built (see `crate::intern`): the §9.7-expanded document deserializes
    // bottom-up, so duplicates are collapsed before they can accumulate.
    unpark_const_data(&mut json_value, facts.parked)?;
    let mut esm_file: EsmFile = {
        let _intern = crate::intern::InternScope::new();
        serde_json::from_value(json_value).map_err(EsmError::JsonParse)?
    };
    esm_file.component_templates = facts.component_templates;

    // The reference rules a load refuses on that read the typed document: a
    // coupling `from` that does not resolve, a cross-scope dependency cycle,
    // an undeclared event variable. The refusal carries the findings.
    let findings = crate::structural::load_reference_errors(&esm_file);
    if let Some(first) = findings.first() {
        let message = findings
            .iter()
            .map(|f| format!("[{}] {}: {}", f.code, f.path, f.message))
            .collect::<Vec<_>>()
            .join("; ");
        return Err(EsmError::StructuralDiagnostic {
            code: first.code.as_str(),
            message: format!("Structural validation failed: {message}"),
            findings,
        });
    }

    // esm-spec §2.2: an EMPTY `solver` block normalizes to absence at load.
    esm_file.solver = crate::solver::normalize_empty(esm_file.solver.take());
    // esm-spec §10.10 / §4.7: relative `coupling_import` refs resolve against
    // THIS document's directory, which flatten would otherwise never learn. Only
    // an explicit base is recorded; a string load without one leaves flatten's
    // own `base_path` in charge.
    if options.base_path.is_some() {
        esm_file.coupling_import_base = Some(base.to_string_lossy().into_owned());
    }
    // esm-spec §2.2.6: the anchor `solver_external_location` resolves a relative
    // `solver.external` against — the file's directory, the explicit base, or
    // the working directory of a string load. Recorded on EVERY load and made
    // absolute now, so a later change of working directory cannot move it.
    esm_file.document_base = crate::solver::absolute_directory(&base);

    // esm-spec §8.5.1: the deprecated `records_per_sample` still loads, with
    // ONE warning per load naming every place it is written. Here, after refs
    // are mounted, so a mounted component's sites are named by this load and
    // no nested load warns again.
    if let Some(warning) = crate::structural::deprecated_records_per_sample_warning(&esm_file) {
        eprintln!("warning: {warning}");
    }

    Ok(esm_file)
}

/// The kinds of document the load pass table ([`LOAD_PASSES`]) serves.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum DocRole {
    /// A document handed to a `load_*` entry point.
    Root,
    /// The source document of
    /// [`crate::lower_expression_templates::emit_document`].
    EmitSource,
}

const ROOT: &[DocRole] = &[DocRole::Root];
const ROOT_AND_EMIT: &[DocRole] = &[DocRole::Root, DocRole::EmitSource];

/// One load pass: its name, the kinds of document it runs on, and its body.
struct Pass {
    #[cfg_attr(not(test), expect(dead_code, reason = "read by the order test"))]
    name: &'static str,
    roles: &'static [DocRole],
    run: fn(&mut Doc<'_>) -> Result<(), PassError>,
}

/// Every pass over a document's JSON, in the order it runs, with the kinds of
/// document it runs on. A document with several defects is refused by the
/// first pass that finds one, and which refusal that is is visible across
/// bindings, so the order is part of the contract. The mounted-leaf,
/// template-library and coupling-library documents open through
/// [`crate::ref_reader::open`] instead, whose documentation lists their passes.
const LOAD_PASSES: &[Pass] = &[
    Pass {
        name: "wire boundary ops",
        roles: ROOT_AND_EMIT,
        run: pass_wire_ops,
    },
    Pass {
        name: "mount-declared metaparameters",
        roles: ROOT,
        run: pass_mount_declared,
    },
    Pass {
        name: "data source extents",
        roles: ROOT,
        run: pass_data_source_extents,
    },
    Pass {
        name: "mount resolution",
        roles: ROOT,
        run: pass_resolve_mounts,
    },
    Pass {
        name: "data source urls",
        roles: ROOT,
        run: pass_data_source_urls,
    },
    Pass {
        name: "template version gates",
        roles: ROOT,
        run: pass_template_gates,
    },
    Pass {
        name: "impure template library",
        roles: ROOT,
        run: pass_impure_template_library,
    },
    Pass {
        name: "solver gates",
        roles: ROOT,
        run: pass_solver_gates,
    },
    Pass {
        name: "content version gates",
        roles: ROOT,
        run: pass_content_gates,
    },
    Pass {
        name: "schema",
        roles: ROOT,
        run: pass_schema,
    },
    Pass {
        name: "template scope injections",
        roles: ROOT,
        run: pass_scope_injections,
    },
    Pass {
        name: "template machinery",
        roles: ROOT_AND_EMIT,
        run: pass_template_machinery,
    },
    Pass {
        name: "staged index sets",
        roles: ROOT,
        run: pass_staged_index_sets,
    },
    Pass {
        name: "park const data",
        roles: ROOT,
        run: pass_park_const_data,
    },
    Pass {
        name: "structural json checks",
        roles: ROOT,
        run: pass_structural_json,
    },
    Pass {
        name: "template lowering",
        roles: ROOT_AND_EMIT,
        run: pass_lower_templates,
    },
    Pass {
        name: "template expansion",
        roles: ROOT,
        run: pass_expand_templates,
    },
    Pass {
        name: "enum lowering",
        roles: ROOT,
        run: pass_lower_enums,
    },
    Pass {
        name: "reserved index symbols",
        roles: ROOT,
        run: pass_reserved_index_symbols,
    },
];

/// A document moving through [`LOAD_PASSES`]: its JSON, the directory its
/// relative refs resolve against, and what earlier passes noted for later
/// ones.
pub(crate) struct Doc<'o> {
    pub(crate) value: Value,
    role: DocRole,
    base: std::path::PathBuf,
    options: &'o LoadOptions,
    facts: LoadFacts,
}

/// What a pass notes about the document for a later pass.
#[derive(Default)]
struct LoadFacts {
    /// What the wire-boundary walk noted about the authored document.
    authored: AuthoredFacts,
    /// The metaparameter names every document this one mounts declares.
    mount_declared: std::collections::BTreeSet<String>,
    /// The mounts' `index_sets`, merged once the root has closed.
    staged_index_sets: serde_json::Map<String, Value>,
    /// Whether mount resolution marked template expansions.
    mounts_marked: bool,
    /// The const equation payloads set aside until deserialization.
    parked: Vec<ParkedConst>,
    /// The reserved-binder scan template lowering's walk carried, when that
    /// walk covered the whole document and found no `enum` node.
    reserved: Option<ReservedIndexScan>,
    /// Whether enum lowering must walk the document: template lowering's walk
    /// found an `enum` node or did not cover the whole document.
    enum_walk_needed: bool,
    /// Whether the document has template machinery.
    has_templates: bool,
    /// Each component's `expression_templates` registry, captured before
    /// expansion removes the blocks.
    component_templates: Option<indexmap::IndexMap<String, Value>>,
}

/// A pass's refusal: a coded diagnostic of the schema or structural stage, or
/// an [`EsmError`] the pass built itself.
pub(crate) enum PassError {
    Schema(crate::diagnostic::DiagnosticError),
    Structural(crate::diagnostic::DiagnosticError),
    Esm(EsmError),
}

impl From<PassError> for EsmError {
    fn from(e: PassError) -> Self {
        match e {
            PassError::Schema(d) => EsmError::schema(d),
            PassError::Structural(d) => EsmError::structural(d),
            PassError::Esm(e) => e,
        }
    }
}

impl From<EsmError> for PassError {
    fn from(e: EsmError) -> Self {
        PassError::Esm(e)
    }
}

impl<'o> Doc<'o> {
    /// A document of `role`; relative refs resolve against
    /// `options.base_path`, or the working directory when it has none.
    pub(crate) fn new(value: Value, role: DocRole, options: &'o LoadOptions) -> Self {
        let base = options.base_path.clone().unwrap_or_else(|| {
            std::env::current_dir().unwrap_or_else(|_| std::path::PathBuf::from("."))
        });
        Doc {
            value,
            role,
            base,
            options,
            facts: LoadFacts::default(),
        }
    }

    /// Run, in table order, every pass of [`LOAD_PASSES`] this document's role
    /// takes.
    pub(crate) fn run_passes(&mut self) -> Result<(), PassError> {
        for pass in LOAD_PASSES {
            if pass.roles.contains(&self.role) {
                (pass.run)(self)?;
            }
        }
        Ok(())
    }
}

/// Removed ops (and `function_tables`) are refused by name at the wire
/// boundary, ahead of every other pass (esm-spec §4.2).
fn pass_wire_ops(doc: &mut Doc<'_>) -> Result<(), PassError> {
    doc.facts.authored = prepare_document_ops_scanned(&mut doc.value)?;
    Ok(())
}

/// The metaparameter names every document this one MOUNTS declares (§4.7,
/// either mount form, transitively). It widens the §9.7.6 site-4 check of the
/// template machinery: a loader-API binding — which is how a discovered §8.9.4
/// `extent` arrives — may name a metaparameter the LEAF declares and this
/// document has no reason to restate. The edge forwards it into the leaf's own
/// close, so the name is meaningful; only a name NO document in the assembly
/// declares is the typo the check exists to catch.
///
/// Collected before mount resolution, not at the site-4 check itself: this
/// binding resolves refs BEFORE the root's template machinery (Python is the
/// other way round), so by the time `resolve_template_machinery` runs, the
/// `{ref}` mount entries this walk reads have already been consumed and
/// inlined.
///
/// Guarded: the widening can only matter when the load carries loader-API
/// bindings or the document declares an `extent`. A document with neither pays
/// no extra ref reads — which also keeps a mounted file from being read twice
/// on the ordinary path.
fn pass_mount_declared(doc: &mut Doc<'_>) -> Result<(), PassError> {
    if !doc.options.metaparameters.is_empty()
        || crate::template_imports::document_declares_an_extent(&doc.value)
    {
        doc.facts.mount_declared =
            crate::template_imports::collect_mount_declared_metaparameters(&doc.value, &doc.base);
    }
    Ok(())
}

/// esm-spec §8.9.4, statically: an `extent` naming a metaparameter nobody
/// declares is refused HERE rather than when the source is finally sampled at
/// build, so `esm validate` catches the typo. It runs BEFORE ref resolution, on
/// the AUTHORED tree: a mount CONSUMES the leaf's `metaparameters` (§9.7.6 site
/// 3), so after inlining neither the declaration nor the `{ref}` stub that
/// leads to it is still there to judge by.
fn pass_data_source_extents(doc: &mut Doc<'_>) -> Result<(), PassError> {
    crate::template_imports::check_data_source_extents(
        &doc.value,
        &doc.base,
        &doc.facts.mount_declared,
    )
    .map_err(PassError::Schema)
}

/// Resolve any subsystem refs before schema validation, per spec section 2.1b.
/// Callers that load from a known file path should use `load_path`, which uses
/// the file's own directory as the base. The loader-API metaparameters are
/// threaded so a §4.7 subsystem-edge binding EXPRESSION (`NTGT = NX*NY`,
/// esm-spec §9.7.6 site 3) folds against the root document's closed
/// metaparameter environment (defaults overlaid with the API bindings) at the
/// mount.
///
/// The §4.7 contributions are STAGED here, not merged: the content is spliced
/// in now (the root's own §9.7 machinery has to lower through it), but its
/// `index_sets` do not join the registry until the root has CLOSED — §9.7.6
/// site 3, "subsystem refs resolve post-close" ([`pass_staged_index_sets`]).
///
/// A mounted leaf is expanded here, so its template expansions are marked here
/// too (esm-spec §9.6.11; `MarkTemplateOrigins`), and the schema check reads
/// the document with those marks taken off.
///
/// A refusal here carries, as its findings, the document's own mount edges
/// that do not resolve, each at its pointer
/// ([`crate::ref_loading::mount_edge_errors`]), read off the edges as authored:
/// resolution consumes them in place.
fn pass_resolve_mounts(doc: &mut Doc<'_>) -> Result<(), PassError> {
    let mount_edges = crate::ref_loading::mount_edge_skeleton(&doc.value);
    let marks_before = crate::lower_expression_templates::template_origins_placed();
    doc.facts.staged_index_sets = {
        let _mark = crate::lower_expression_templates::MarkTemplateOrigins::on();
        crate::ref_loading::resolve_subsystem_refs_with_metaparameters(
            &mut doc.value,
            &doc.base,
            &doc.options.metaparameters,
        )
    }
    .map_err(|e| EsmError::SchemaDiagnostic {
        code: e.code,
        message: e.to_string(),
        findings: crate::ref_loading::mount_edge_errors(&mount_edges, &doc.base),
    })?;
    doc.facts.mounts_marked =
        crate::lower_expression_templates::template_origins_placed() != marks_before;
    Ok(())
}

/// esm-spec §8.2.1: resolve every `data_sources[*].source` location against
/// this document's own directory. AFTER ref resolution, because a referenced
/// component file's `data_sources` block is hoisted into this document by mount
/// resolution — those entries were already anchored on THEIR file's directory
/// there, and this pass is idempotent, so both anchors land correctly.
/// Rewriting the raw document means the typed `DataSourceLocation`, the ingest
/// providers and `emit` all see one resolved form and none of them needs a
/// base directory.
fn pass_data_source_urls(doc: &mut Doc<'_>) -> Result<(), PassError> {
    crate::data_source_urls::resolve_data_source_urls(&mut doc.value, &doc.base)
        .map_err(PassError::Schema)
}

/// The version gates (`crate::version_gates::VERSIONED`) run in three groups
/// at the root, each at its own place among the other passes. First the
/// template-machinery constructs: v0.4.0 expression_templates /
/// apply_expression_template, and the v0.8.0 §9.7 constructs
/// (expression_template_imports, top-level expression_templates,
/// metaparameters; esm-spec §9.6.5).
fn pass_template_gates(doc: &mut Doc<'_>) -> Result<(), PassError> {
    use crate::version_gates::{DocKind, Group, check_file_gates};
    check_file_gates(
        &doc.value,
        DocKind::Root,
        Some(Group::Templates),
        &doc.facts.authored,
    )
    .map_err(PassError::Schema)
}

/// Top-level `expression_templates` beside a component payload is a
/// template-library payload no component can see (esm-spec §9.7.1).
fn pass_impure_template_library(doc: &mut Doc<'_>) -> Result<(), PassError> {
    crate::template_imports::reject_impure_template_library(&doc.value).map_err(PassError::Schema)
}

/// The `solver` group: the top-level block arrives at esm 1.1.0 (esm-spec
/// §2.2.4), `solver.external` and `solver.time_span` at 1.3.0. Only the ROOT's
/// block is read for the two fields: a mounted leaf's `solver` block does not
/// cross the mount edge (§4.7). Then a `${` in `external` is refused (it is
/// never expanded, §2.2.6) and `time_span` must describe an interval (§2.2.7).
fn pass_solver_gates(doc: &mut Doc<'_>) -> Result<(), PassError> {
    use crate::version_gates::{DocKind, Group, check_file_gates};
    check_file_gates(
        &doc.value,
        DocKind::Root,
        Some(Group::Solver),
        &doc.facts.authored,
    )
    .and_then(|()| crate::solver::reject_solver_external_unresolved(&doc.value))
    .and_then(|()| crate::solver::reject_solver_time_span_invalid(&doc.value))
    .map_err(PassError::Schema)
}

/// Declared `units` on a `const` node arrive at esm 1.2.0 (esm-spec §4.8.5).
/// The gate reads THIS file's own nodes — the authored walk, taken before ref
/// resolution spliced anything in. A mounted file is held to its OWN declared
/// version, when it is loaded (esm-spec §4.7 "Each file is held to its own
/// declared `esm` version"), so a 1.0.0 document may mount a 1.2.0 leaf that
/// carries unit-bearing `const` nodes. Variable `lb` / `ub` arrive at esm
/// 2.1.0 (esm-spec §6.3.2), judged the same way: this file's own variables,
/// before a mount spliced any in.
fn pass_content_gates(doc: &mut Doc<'_>) -> Result<(), PassError> {
    use crate::version_gates::{DocKind, Group, check_file_gates};
    check_file_gates(
        &doc.value,
        DocKind::Root,
        Some(Group::Content),
        &doc.facts.authored,
    )
    .map_err(PassError::Schema)
}

/// Validate against the schema, with mount resolution's template-origin marks
/// taken off.
fn pass_schema(doc: &mut Doc<'_>) -> Result<(), PassError> {
    if doc.facts.mounts_marked {
        let mut authored = doc.value.clone();
        crate::lower_expression_templates::strip_template_origins(&mut authored);
        validate_schema(&authored)?;
    } else {
        validate_schema(&doc.value)?;
    }
    Ok(())
}

/// esm-spec §9.7.10 form B: fold any coupling-entry injection map into its
/// target components' own `expression_template_imports` BEFORE resolution, so
/// the ordinary import resolver + §9.6.3 fixpoint lower the named target under
/// the assembler-chosen discretization. The injection map is consumed here
/// (does not survive parse → emit); target diagnostics
/// (`template_inject_target_*`) surface as load errors. (Form A is threaded
/// through mount resolution, `ref_loading::resolve_value`.)
fn pass_scope_injections(doc: &mut Doc<'_>) -> Result<(), PassError> {
    crate::template_imports::apply_scope_injections(&mut doc.value, &[]).map_err(PassError::Schema)
}

/// Resolve esm-spec §9.7 machinery — template-library imports (depth-first
/// post-order, per-edge metaparameter instantiation), index_sets merge,
/// metaparameter close+fold — before structural validation and the §9.6.3
/// fixpoint, so validators run on the folded, expanded form (esm-spec §9.6.4 /
/// §9.7.6). An emit source carries no loader-API bindings and mounts nothing
/// declared.
fn pass_template_machinery(doc: &mut Doc<'_>) -> Result<(), PassError> {
    crate::template_imports::resolve_template_machinery_scoped_owned(
        &mut doc.value,
        &doc.base,
        &doc.options.metaparameters,
        &doc.facts.mount_declared,
        false,
    )
    .map_err(PassError::Schema)
}

/// esm-spec §4.7 "Index-set merge", the deferred half: the root has now closed
/// and folded its own `index_sets`, so the staged mount contributions merge
/// against a registry of concrete sizes, each folded against the same closed
/// environment first. Before structural validation, which needs the complete
/// registry.
fn pass_staged_index_sets(doc: &mut Doc<'_>) -> Result<(), PassError> {
    let closed_env =
        crate::ref_loading::root_metaparameter_env(&doc.value, &doc.options.metaparameters);
    let staged = std::mem::take(&mut doc.facts.staged_index_sets);
    crate::ref_loading::apply_staged_index_sets(&mut doc.value, staged, &closed_env)
        .map_err(PassError::Schema)
}

/// The template passes below walk the whole document several times; an
/// equation whose right-hand side is a `const` of numbers (a document's data)
/// holds nothing any of them acts on, so its payload waits outside the
/// document until it is deserialized.
fn pass_park_const_data(doc: &mut Doc<'_>) -> Result<(), PassError> {
    doc.facts.parked = park_const_data(&mut doc.value);
    Ok(())
}

/// Post-schema checks of the JSON (version compatibility, cross-field format
/// rules, a coupling library's role references) — the things JSON Schema
/// cannot express and that need no typed document. Mirrors Python / Julia so
/// that cross-language conformance agrees.
fn pass_structural_json(doc: &mut Doc<'_>) -> Result<(), PassError> {
    Ok(validate_structural_json(&doc.value)?)
}

/// Lower `apply_expression_template` ops at load time (esm-spec §9.6.4 Option
/// B, RFC out-of-line-expression-templates). This pass PRESERVES surviving
/// (non-eager) references and each component's `expression_templates` block
/// (they travel into emit, §9.6.4 rule 5). A document with no template
/// machinery is left unchanged by this pass and the two after it (enum
/// lowering finds nothing to lower without an `enum` node), so the template
/// scan's walk also looks for `enum` nodes and reserved binders, which are then
/// not walked for again.
fn pass_lower_templates(doc: &mut Doc<'_>) -> Result<(), PassError> {
    let mut reserved = ReservedIndexScan::new(&doc.value);
    let mut has_enum_ops = false;
    let (has_templates, scanned_whole) =
        crate::lower_expression_templates::lower_expression_templates_visiting(
            &mut doc.value,
            &mut |path, value| {
                has_enum_ops |= crate::lower_enums::is_enum_node(value);
                reserved.visit(path, value);
            },
        )
        .map_err(PassError::Schema)?;
    doc.facts.has_templates = has_templates;
    doc.facts.enum_walk_needed = has_enum_ops || !scanned_whole;
    doc.facts.reserved = (scanned_whole && !has_enum_ops).then_some(reserved);
    Ok(())
}

/// The typed IR / build path (simulate, flatten, graph, …) is Expand-at-build
/// (RFC out-of-line-expression-templates §7.7): expand every surviving
/// reference here so downstream consumers see the fully expanded Option-A
/// image — numeric results stay bit-identical, and the typed structs never see
/// an `apply_expression_template` node or an `expression_templates` block.
/// Capture the per-component registries first: `expand` removes the blocks,
/// and `flatten` needs them to build the step-4 merged `template_registry`. A
/// document with no template machinery has nothing to expand; `expand` would
/// walk it only to find that out.
fn pass_expand_templates(doc: &mut Doc<'_>) -> Result<(), PassError> {
    doc.facts.component_templates =
        crate::lower_expression_templates::capture_component_templates(&doc.value);
    if doc.facts.has_templates {
        let _mark = crate::lower_expression_templates::MarkTemplateOrigins::on();
        crate::lower_expression_templates::expand(&mut doc.value).map_err(PassError::Schema)?;
    } else {
        crate::lower_expression_templates::strip_component_template_blocks(&mut doc.value);
    }
    Ok(())
}

/// Lower `enum`-op nodes to `const` integers using the file's `enums` block
/// (esm-spec §4.5 / §9.3). Mirrors the Julia / Python load-time pass so that
/// downstream consumers never see enum strings.
fn pass_lower_enums(doc: &mut Doc<'_>) -> Result<(), PassError> {
    crate::lower_enums::lower_enums_raw_scanned(&mut doc.value, doc.facts.enum_walk_needed)
        .map_err(PassError::Schema)
}

/// Reject a `faq` binder that shadows a globally-scoped name (the independent
/// variable, `_var`). Runs HERE, on the fully lowered form, so a binder a
/// §9.6/§9.7 template body introduced is caught with the authored ones. See
/// [`reject_reserved_index_symbols`] for why this is a rejection rather than a
/// shadowing rule.
fn pass_reserved_index_symbols(doc: &mut Doc<'_>) -> Result<(), PassError> {
    match doc.facts.reserved.take() {
        Some(scan) => scan.finish(),
        None => reject_reserved_index_symbols(&doc.value),
    }
    .map_err(PassError::Structural)
}

/// Load an ESM file from a filesystem path.
///
/// Reads the file, resolves any subsystem references relative to the file's
/// directory, validates against the schema, and deserializes into an
/// [`EsmFile`].
pub fn load_path<P: AsRef<std::path::Path>>(path: P) -> Result<EsmFile, EsmError> {
    load_path_with_options(path, &std::collections::BTreeMap::new())
}

/// Load an ESM file from a filesystem path, binding the root document's open
/// metaparameters at the loader API (esm-spec §9.7.6 binding site 4). The
/// file's own directory anchors relative subsystem and template-import refs.
pub fn load_path_with_options<P: AsRef<std::path::Path>>(
    path: P,
    metaparameters: &std::collections::BTreeMap<String, i64>,
) -> Result<EsmFile, EsmError> {
    let path = path.as_ref();
    let json_str = std::fs::read_to_string(path).map_err(|e| EsmError::FileRead {
        path: path.display().to_string(),
        source: e,
    })?;

    let base = path
        .parent()
        .map(|p| p.to_path_buf())
        .unwrap_or_else(|| std::path::PathBuf::from("."));
    let options = LoadOptions {
        base_path: Some(base),
        metaparameters: metaparameters.clone(),
    };
    load_string_with_options(&json_str, &options)
}

/// Validate a JSON value against the ESM schema
///
/// This performs schema validation only. The JSON is assumed to be valid.
///
/// # Arguments
///
/// * `json_value` - The JSON value to validate
///
/// # Returns
///
/// * `Ok(())` - JSON passes schema validation
/// * `Err(EsmError::SchemaValidation)` - Schema validation errors
pub fn validate_schema(json_value: &Value) -> Result<(), EsmError> {
    let schema = get_schema();
    // A valid document is the common case, and answering only whether it is
    // valid skips assembling an error for every failed `oneOf` / `anyOf`
    // branch on the way; the errors are collected only for a document that
    // fails.
    if schema.is_valid(json_value) {
        return Ok(());
    }
    let error_messages: Vec<String> = schema
        .iter_errors(json_value)
        .map(|error| error.to_string())
        .collect();
    Err(EsmError::SchemaValidation(error_messages.join("; ")))
}

/// Map a `jsonschema` [`ValidationErrorKind`] to the STANDARD JSON-Schema
/// keyword that failed, so the cross-language conformance wire format uses the
/// same vocabulary as AJV / Python `jsonschema` (CONFORMANCE_SPEC.md §7.1.2)
/// rather than a library-specific spelling.
fn schema_keyword_for_kind(kind: &ValidationErrorKind) -> &'static str {
    use ValidationErrorKind as K;
    match kind {
        K::AdditionalItems { .. } => "additionalItems",
        K::AdditionalProperties { .. } => "additionalProperties",
        K::AnyOf { .. } => "anyOf",
        // A regex that blew its backtrack budget, or whose engine failed
        // outright, failed the `pattern` keyword.
        K::BacktrackLimitExceeded { .. } | K::RegexEngineFailure { .. } => "pattern",
        K::Constant { .. } => "const",
        K::Contains => "contains",
        K::ContentEncoding { .. } => "contentEncoding",
        K::ContentMediaType { .. } => "contentMediaType",
        K::Custom { .. } => "custom",
        K::Enum { .. } => "enum",
        K::ExclusiveMaximum { .. } => "exclusiveMaximum",
        K::ExclusiveMinimum { .. } => "exclusiveMinimum",
        K::FalseSchema => "false",
        K::Format { .. } => "format",
        K::FromUtf8 { .. } => "contentEncoding",
        K::MaxItems { .. } => "maxItems",
        K::Maximum { .. } => "maximum",
        K::MaxLength { .. } => "maxLength",
        K::MaxProperties { .. } => "maxProperties",
        K::MinItems { .. } => "minItems",
        K::Minimum { .. } => "minimum",
        K::MinLength { .. } => "minLength",
        K::MinProperties { .. } => "minProperties",
        K::MultipleOf { .. } => "multipleOf",
        K::Not { .. } => "not",
        K::OneOfMultipleValid { .. } | K::OneOfNotValid { .. } => "oneOf",
        K::Pattern { .. } => "pattern",
        K::PropertyNames { .. } => "propertyNames",
        K::Required { .. } => "required",
        K::Type { .. } => "type",
        K::UnevaluatedItems { .. } => "unevaluatedItems",
        K::UnevaluatedProperties { .. } => "unevaluatedProperties",
        K::UniqueItems => "uniqueItems",
        // An unresolvable or unretrievable `$ref`.
        K::Referencing(_) => "$ref",
    }
}

/// Maximum `oneOf`/`anyOf` branch-descent depth. Deep enough for the ESM
/// schema's real nesting (document → model → variable/equation → expression),
/// bounded so a self-referential `$ref` (e.g. `Expression`) cannot recurse
/// without end.
const SCHEMA_DESCENT_CAP: usize = 16;

/// Validate `json_value` against the ESM schema and return **one
/// [`SchemaError`](crate::validate::SchemaError) per violation** (CONFORMANCE_SPEC.md §7.1.2), instead of the
/// single `"; "`-joined blob [`validate_schema`] produces for the load path.
///
/// Each record carries the RFC-6901 JSON Pointer of the offending node (the
/// document root is the empty string `""`) and the standard JSON-Schema
/// keyword that failed, so the cross-language comparator can match pinned
/// `(keyword, path)` tuples. An empty vec means the document is schema-valid.
///
/// The `jsonschema` crate reports a failed `oneOf`/`anyOf`/`$ref` only as a
/// SHALLOW composition error at the branch point — it does not surface the
/// sub-schema errors that explain WHY the branch failed (AJV, the reference,
/// does). Since the ESM schema wraps every component in
/// `additionalProperties: { oneOf: [{$ref: …}, {$ref: SubsystemRef}] }` and
/// nests further `oneOf`s inside, that would hide almost every pinned error
/// behind a `oneOf` at `/models/X`. To recover them, each composition error is
/// descended: every branch sub-schema is compiled standalone and re-validated
/// against the offending instance subtree, and its (recursively descended)
/// errors are emitted with absolute instance paths. Extra errors are harmless
/// (the comparator is a required-subset), so all branches are explored.
pub fn collect_schema_errors(json_value: &Value) -> Vec<crate::validate::SchemaError> {
    let root = get_schema_value();
    let defs = root.get("$defs");
    let mut out = Vec::new();
    let mut cache: std::collections::HashMap<String, Option<Validator>> =
        std::collections::HashMap::new();
    // The top level reuses the pre-compiled full schema; branches below compile
    // on demand.
    let summaries = summarize_errors(get_schema().iter_errors(json_value));
    handle_schema_errors(
        root, defs, &mut cache, root, json_value, "", &summaries, 0, &mut out,
    );
    // Dedup identical (path, keyword, message) records the branch sweep can
    // produce when several branches fail the same way.
    let mut seen = std::collections::HashSet::new();
    out.retain(|e| seen.insert((e.path.clone(), e.keyword.clone(), e.message.clone())));
    out
}

/// Owned summary of a single `jsonschema` error, so the compiled sub-schema (and
/// its `cache` borrow) can be dropped before the branch descent recurses.
struct ErrSummary {
    instance_path: String,
    schema_path: String,
    keyword: String,
    message: String,
    is_composition: bool,
}

/// Project a validation-error iterator to owned [`ErrSummary`]s.
fn summarize_errors<'a>(
    errors: impl Iterator<Item = jsonschema::ValidationError<'a>>,
) -> Vec<ErrSummary> {
    errors
        .map(|error| ErrSummary {
            instance_path: error.instance_path().to_string(),
            schema_path: error.schema_path().to_string(),
            keyword: schema_keyword_for_kind(error.kind()).to_string(),
            message: error.to_string(),
            is_composition: matches!(
                error.kind(),
                ValidationErrorKind::OneOfNotValid { .. }
                    | ValidationErrorKind::OneOfMultipleValid { .. }
                    | ValidationErrorKind::AnyOf { .. }
            ),
        })
        .collect()
}

/// Emit each summarized error, or — for a `oneOf`/`anyOf` composition failure —
/// descend every branch sub-schema and emit its own (recursively descended)
/// errors instead. `nav_schema` is the concrete schema fragment the errors'
/// `schema_path`s are relative to; `instance` is the value validated against it
/// and `base` the absolute instance-pointer prefix of that value.
#[allow(clippy::too_many_arguments)]
fn handle_schema_errors(
    root: &Value,
    defs: Option<&Value>,
    cache: &mut std::collections::HashMap<String, Option<Validator>>,
    nav_schema: &Value,
    instance: &Value,
    base: &str,
    summaries: &[ErrSummary],
    depth: usize,
    out: &mut Vec<crate::validate::SchemaError>,
) {
    for s in summaries {
        let abs_path = format!("{base}{}", s.instance_path);

        // Always emit the error itself. For a composition failure this is the
        // shallow `oneOf`/`anyOf` record — some pins want exactly that (e.g. the
        // root `anyOf` when a document declares no systems), and the comparator
        // is a required-subset so the deeper branch errors added below only help.
        out.push(crate::validate::SchemaError {
            path: abs_path.clone(),
            message: s.message.clone(),
            keyword: s.keyword.clone(),
        });

        // Then descend a composition failure so the sub-schema errors that
        // explain WHY every branch failed surface too (the crate reports only
        // the shallow composition error; AJV — the reference — reports these).
        if s.is_composition && depth < SCHEMA_DESCENT_CAP {
            let segments = schema_path_segments(&s.schema_path);
            if let Some(branches) =
                resolve_schema_at(root, nav_schema, &segments).and_then(|c| c.as_array())
            {
                let sub_instance = if s.instance_path.is_empty() {
                    instance
                } else {
                    instance.pointer(&s.instance_path).unwrap_or(instance)
                };
                for branch in branches {
                    let branch_schema = follow_refs(root, branch);
                    // Validate the offending subtree against this branch and
                    // summarize its errors; the `cache` borrow ends here so the
                    // recursion below is free to re-borrow it.
                    let sub_summaries =
                        validate_and_summarize(cache, defs, branch_schema, sub_instance);
                    handle_schema_errors(
                        root,
                        defs,
                        cache,
                        branch_schema,
                        sub_instance,
                        &abs_path,
                        &sub_summaries,
                        depth + 1,
                        out,
                    );
                }
            }
        }
    }
}

/// Compile `branch_schema` standalone (via [`compile_branch`]) and summarize its
/// errors against `instance`. The compiled schema — and thus the `cache` borrow
/// — is released on return, freeing the caller to recurse.
fn validate_and_summarize(
    cache: &mut std::collections::HashMap<String, Option<Validator>>,
    defs: Option<&Value>,
    branch_schema: &Value,
    instance: &Value,
) -> Vec<ErrSummary> {
    match compile_branch(cache, defs, branch_schema) {
        Some(compiled) => summarize_errors(compiled.iter_errors(instance)),
        None => Vec::new(),
    }
}

/// Split a schema-path JSON Pointer (`/properties/models/.../oneOf`) into its
/// unescaped chunks for [`resolve_schema_at`].
fn schema_path_segments(pointer: &str) -> Vec<String> {
    pointer
        .split('/')
        .skip(1) // leading empty chunk before the first '/'
        .map(|c| c.replace("~1", "/").replace("~0", "~"))
        .collect()
}

/// Resolve `$ref`s until `value` is a concrete (non-`$ref`) schema node.
fn follow_refs<'a>(root: &'a Value, mut value: &'a Value) -> &'a Value {
    let mut guard = 0;
    while let Some(reference) = value.get("$ref").and_then(|r| r.as_str()) {
        guard += 1;
        if guard > SCHEMA_DESCENT_CAP {
            break;
        }
        match resolve_local_ref(root, reference) {
            Some(target) => value = target,
            None => break,
        }
    }
    value
}

/// Resolve a local `#/…` JSON-Pointer `$ref` against the schema document.
fn resolve_local_ref<'a>(root: &'a Value, reference: &str) -> Option<&'a Value> {
    let pointer = reference.strip_prefix('#')?;
    if pointer.is_empty() {
        Some(root)
    } else {
        root.pointer(pointer)
    }
}

/// Navigate `schema_path` segments into `start`, transparently resolving any
/// `$ref` crossed along the way (mirroring how the crate's resolved
/// `schema_path` traverses `$ref` boundaries), returning the node the pointer
/// addresses (e.g. the `oneOf` array).
fn resolve_schema_at<'a>(
    root: &'a Value,
    start: &'a Value,
    segments: &[String],
) -> Option<&'a Value> {
    // Past a `$ref` the crate reports the schema path from the document root
    // (`/$defs/<Name>/…`) rather than from `start`. A branch is compiled with
    // the root's own `$defs` injected, so such a path resolves against `root`.
    let start = if segments.first().is_some_and(|s| s == "$defs") {
        root
    } else {
        start
    };
    let mut cur = follow_refs(root, start);
    for seg in segments {
        // The crate's `schema_path` names each `$ref` it crosses as a segment
        // of its own; `follow_refs` has already stepped through it.
        if seg == "$ref" {
            continue;
        }
        cur = follow_refs(root, cur);
        cur = match cur {
            Value::Object(_) => cur.get(seg)?,
            Value::Array(arr) => arr.get(seg.parse::<usize>().ok()?)?,
            _ => return None,
        };
    }
    Some(follow_refs(root, cur))
}

/// Compile a branch sub-schema standalone (with the document `$defs` injected so
/// its internal `$ref`s resolve), memoized by the branch's JSON text. `None` if
/// the fragment cannot be compiled.
fn compile_branch<'c>(
    cache: &'c mut std::collections::HashMap<String, Option<Validator>>,
    defs: Option<&Value>,
    branch_schema: &Value,
) -> Option<&'c Validator> {
    let key = branch_schema.to_string();
    cache
        .entry(key)
        .or_insert_with(|| {
            let mut wrapper = branch_schema.clone();
            if let (Some(obj), Some(defs)) = (wrapper.as_object_mut(), defs) {
                obj.entry("$defs").or_insert_with(|| defs.clone());
            }
            jsonschema::options()
                .with_draft(Draft::Draft202012)
                .should_validate_formats(true)
                .build(&wrapper)
                .ok()
        })
        .as_ref()
}

// ============================================================================
// Post-schema structural / semantic validation
// ============================================================================
//
// JSON Schema can enforce shape, type, and pattern rules, but a handful of
// semantic rules in esm-libraries-spec §3.2 fall outside what Draft 2020-12
// can express. The checks in this section mirror Python's `_validate_structural`
// and Julia's validator so that a fixture that fails in one language fails
// in all three, per §2.1a cross-language parity.
//
// RELATIONSHIP TO `crate::validate` / `crate::structural`: this is the
// LOAD-TIME stack — it runs on raw JSON inside `load_string()`, gates whether a file
// parses at all, and its String messages are pinned cross-binding. The typed
// stack (`validate()` → structural.rs/coupling.rs) runs on demand over the
// deserialized `EsmFile` and reports structured `StructuralError`s. Several
// rules intentionally exist in BOTH layers (event variable references,
// discrete-parameter declarations, circular model dependencies): this layer
// rejects files that must not load; the typed layer re-checks documents that
// were constructed or edited in memory and never passed through `load_string()`.
// If you change a shared rule, change it in both layers (and the sibling
// bindings).

/// Reject any `faq` binder that SHADOWS the document's independent
/// variable (esm-spec §11.3: `domain.independent_variable`, default `"t"`) or
/// the §6.4 operator placeholder `_var` — diagnostic `reserved_index_symbol`.
///
/// Both names are IMPLICITLY DECLARED in every model's expression scope
/// (§4.9.1), and every consumer in this crate resolves them by name BEFORE it
/// consults the loop bindings: `simulate_array/eval.rs::lookup_variable` and
/// `lookup_array_ref`, the two `tape/lower.rs` sites, `units.rs`, `simulate/resolve.rs`, and the scoping walkers
/// `flatten.rs::namespace_expr_scoped` / `scope_template_body`
/// (`if name == "t" || name == VAR_PLACEHOLDER || bound.contains(name)`). A
/// `ranges` key or `output_idx` entry spelled with one of those names therefore
/// declares a loop the body can never address: every read of the symbol inside
/// the node evaluates to the simulation TIME (or to the operand placeholder)
/// instead of the loop index.
///
/// **Why this is a rejection and not a shadowing rule.** Making the binder win
/// would mean inverting that precedence at all nine sites here and in every
/// peer binding, and it would still leave the node unable to mention the
/// independent variable at all — a `faq` body that reads `t` for a
/// forcing term is ordinary, and inside such a node `t` would silently become
/// an index. Rejecting costs nothing an author wants: an index symbol is the
/// author's free choice (§4.3.1), so the fix is to spell it anything else.
///
/// What the shadowing did before this check existed is exactly what
/// CONFORMANCE_SPEC §5.5.8 forbids for the same reason it forbids an
/// unresolvable key column — a SILENT no-op. A `join.on` key column resolves
/// against the node's own `ranges` (`join.rs::resolve_side`), so the shadowed
/// symbol resolved fine at BUILD time and then addressed the wrong thing at
/// EVAL time: with a data-column key the gate admitted nothing and the
/// `sum_product` reduction returned 0 with no error and no warning, and with a
/// `const`-array key the lowered `code_lookup` indexed the constant key table
/// with the time value and raised the misleading
/// `E_TREEWALK_CONSTARRAY_OOB: const array 'left_key' index 0 out of range 1..3`.
/// Regression fixtures: `tests/fixtures/reserved_index_symbol/`.
///
/// An `integral`'s `var` (`int_var`) is deliberately NOT checked: `∫f dt` binds
/// the independent variable because it IS integrating over it, which is the
/// authored form §4.2 documents, not a shadow of it.
///
/// Runs on the fully-lowered raw JSON (after §9.7 import resolution, the §9.6.3
/// fixpoint and template expansion), so a binder introduced by a template BODY
/// is caught alongside an authored one.
pub(crate) fn reject_reserved_index_symbols(
    json_value: &Value,
) -> Result<(), crate::diagnostic::DiagnosticError> {
    let mut scan = ReservedIndexScan::new(json_value);
    crate::json_visit::visit_values(json_value, &mut |path, value| scan.visit(path, value));
    scan.finish()
}

/// [`reject_reserved_index_symbols`] as a visitor, so the walk can be shared:
/// [`ReservedIndexScan::visit`] every value of the document in pre-order, then
/// [`ReservedIndexScan::finish`].
pub(crate) struct ReservedIndexScan {
    independent: String,
    /// `(path, field, symbol, role)` for every offending binder, in document
    /// order, as the message lists them.
    offenders: Vec<String>,
}

impl ReservedIndexScan {
    pub(crate) fn new(json_value: &Value) -> Self {
        let independent = json_value
            .get("domain")
            .and_then(|d| d.get("independent_variable"))
            .and_then(Value::as_str)
            .unwrap_or("t")
            .to_string();
        ReservedIndexScan {
            independent,
            offenders: Vec::new(),
        }
    }

    pub(crate) fn visit(&mut self, path: &crate::json_visit::JsonPath<'_>, value: &Value) {
        let Some(obj) = value.as_object() else {
            return;
        };
        // An Expression NODE: the only place these two fields carry meaning.
        let Some(op) = crate::json_visit::small_get(obj, "op").and_then(Value::as_str) else {
            return;
        };
        let independent = self.independent.as_str();
        let reserved = |name: &str| -> Option<&'static str> {
            if name == independent {
                Some("the document's independent variable")
            } else if name == VAR_PLACEHOLDER {
                Some("the §6.4 operator placeholder")
            } else {
                None
            }
        };
        // A symbol that is BOTH an `output_idx` entry and a `ranges` key of the
        // same node is one mistake, so it is reported once, under `ranges`.
        let offenders = &mut self.offenders;
        let mut seen: Vec<&str> = Vec::new();
        let mut record = |field: &str, sym: &str, role: &str| {
            offenders.push(format!(
                "`{op}` node at {path} binds '{sym}' as an index symbol ({field}), \
                 but '{sym}' is {role}"
            ));
        };
        crate::binders::for_each_json_loop_binder(value, |kind, sym| {
            let Some(role) = reserved(sym) else { return };
            if kind == crate::binders::Binders::RANGES {
                seen.push(sym);
                record("a `ranges` key", sym, role);
            } else if !seen.contains(&sym) {
                record("an `output_idx` entry", sym, role);
            }
        });
    }

    pub(crate) fn finish(self) -> Result<(), crate::diagnostic::DiagnosticError> {
        if self.offenders.is_empty() {
            return Ok(());
        }
        let independent = self.independent;
        Err(crate::diagnostic::err(
            crate::diagnostic::codes::RESERVED_INDEX_SYMBOL,
            format!(
                "{}. Both '{independent}' (esm-spec §11.3) and '{VAR_PLACEHOLDER}' (§6.4) are \
                 implicitly declared in every model's expression scope (§4.9.1) and are resolved \
                 by name before the loop bindings, so a binder spelled with one of them declares \
                 a loop its body can never address — the reads inside the node see the \
                 independent variable's value instead of the index, silently (CONFORMANCE_SPEC \
                 §5.5.8 forbids the same silence for an unresolvable `join.on` key column). \
                 Rename the index symbol: an index symbol is the author's free choice \
                 (esm-spec §4.3.1)",
                self.offenders.join("; ")
            ),
        ))
    }
}

/// A `const` equation payload [`park_const_data`] set aside: component kind,
/// component name, equation position, and the payload.
type ParkedConst = (&'static str, String, usize, Value);

/// Take the `value` of every component equation whose right-hand side is a
/// `const` node holding an array of numbers ([`crate::json_visit::is_number_data`])
/// out of a document with expression templates and no `match` rule, leaving
/// the number `0` in its place. Such an equation is not inside any template
/// application, so expansion neither reads nor copies it, and with no rule to
/// fire nothing rewrites it; the passes in between act on objects and
/// strings, which the payload holds none of. Nothing is taken from a document
/// without templates, whose passes walk it once.
fn park_const_data(doc: &mut Value) -> Vec<ParkedConst> {
    let mut out = Vec::new();
    let Some(root) = doc.as_object_mut() else {
        return out;
    };
    let has_match = |t: Option<&Value>| {
        t.and_then(Value::as_object)
            .is_some_and(|t| t.values().any(|d| d.get("match").is_some()))
    };
    let has_templates =
        |t: Option<&Value>| t.and_then(Value::as_object).is_some_and(|t| !t.is_empty());
    if has_match(root.get("expression_templates")) {
        return out;
    }
    let mut any = has_templates(root.get("expression_templates"));
    for kind in ["models", "reaction_systems"] {
        for (_, comp) in root
            .get(kind)
            .and_then(Value::as_object)
            .into_iter()
            .flatten()
        {
            if has_match(comp.get("expression_templates")) {
                return out;
            }
            any |= has_templates(comp.get("expression_templates"));
        }
    }
    if !any {
        return out;
    }
    for kind in ["models", "reaction_systems"] {
        let Some(Value::Object(comps)) = root.get_mut(kind) else {
            continue;
        };
        for (name, comp) in comps.iter_mut() {
            let Some(Value::Array(eqs)) = comp.get_mut("equations") else {
                continue;
            };
            for (k, eq) in eqs.iter_mut().enumerate() {
                let Some(Value::Object(rhs)) = eq.get_mut("rhs") else {
                    continue;
                };
                if rhs.get("op").and_then(Value::as_str) != Some("const") {
                    continue;
                }
                if let Some(v) = rhs.get_mut("value")
                    && v.as_array()
                        .is_some_and(|a| crate::json_visit::is_number_data(a))
                {
                    let payload = std::mem::replace(v, Value::from(0));
                    out.push((kind, name.clone(), k, payload));
                }
            }
        }
    }
    out
}

/// Put back what [`park_const_data`] took, each payload where it found the
/// placeholder it left.
fn unpark_const_data(doc: &mut Value, parked: Vec<ParkedConst>) -> Result<(), EsmError> {
    for (kind, name, k, payload) in parked {
        let slot = doc
            .get_mut(kind)
            .and_then(|c| c.get_mut(&name))
            .and_then(|c| c.get_mut("equations"))
            .and_then(|e| e.get_mut(k))
            .and_then(|e| e.get_mut("rhs"))
            .filter(|r| r.get("op").and_then(Value::as_str) == Some("const"))
            .and_then(|r| r.get_mut("value"))
            .filter(|v| v.as_i64() == Some(0));
        let Some(slot) = slot else {
            return Err(EsmError::StructuralValidation(format!(
                "internal: the const data of {kind}.{name} equation {k} moved during load"
            )));
        };
        *slot = payload;
    }
    Ok(())
}

/// Run the post-schema checks of the untyped document, collecting errors and
/// returning `EsmError::StructuralValidation` if any check fires.
fn validate_structural_json(json_value: &Value) -> Result<(), EsmError> {
    let mut errors: Vec<String> = Vec::new();

    if let Some(obj) = json_value.as_object() {
        check_version_compatibility(obj, &mut errors);
        check_metadata_formats(obj, &mut errors);
        check_data_loader_temporal_durations(obj, &mut errors);
        check_coupling_role_references(obj, &mut errors);
        check_reaction_stoichiometries(obj, &mut errors);
    }

    if errors.is_empty() {
        Ok(())
    } else {
        Err(EsmError::StructuralValidation(format!(
            "Structural validation failed: {}",
            errors.join("; ")
        )))
    }
}

/// Reject files whose major version this library cannot read.
///
/// A 1.x document loads at 2.0.0: the removed ops are refused by name at the
/// wire boundary (`removed_op`) and the 1.x version gates stay live, so the
/// major version alone never refuses a 1.x document. A pre-1.0.0 document and
/// one from a major newer than this library's are refused here, with the
/// standardized message string the Julia / Python libraries use.
fn check_version_compatibility(obj: &serde_json::Map<String, Value>, errors: &mut Vec<String>) {
    let Some(ver) = obj.get("esm").and_then(|v| v.as_str()) else {
        return;
    };
    let Some((major, _, _)) = crate::diagnostic::parse_semver(ver) else {
        return;
    };
    let supported_major = library_version().0;
    if !(OLDEST_LOADABLE_MAJOR..=supported_major).contains(&major) {
        errors.push(format!(
            "Unsupported major version {major}. This library supports major versions \
             {}.",
            (OLDEST_LOADABLE_MAJOR..=supported_major)
                .map(|m| m.to_string())
                .collect::<Vec<_>>()
                .join(", ")
        ));
    }
}

/// The oldest major version a document may declare and still load.
const OLDEST_LOADABLE_MAJOR: u32 = 1;

/// Reject reaction stoichiometries that are not positive finite numbers.
///
/// JSON Schema already enforces `"type": "number", "exclusiveMinimum": 0`, but
/// JSON cannot encode NaN / ±Infinity — if upstream tooling produces such a
/// value, or a numeric encoding overflows to Infinity, we surface the error
/// here rather than silently accepting it downstream.
fn check_reaction_stoichiometries(obj: &serde_json::Map<String, Value>, errors: &mut Vec<String>) {
    let Some(reaction_systems) = obj.get("reaction_systems").and_then(|v| v.as_object()) else {
        return;
    };
    for (rs_name, rs_val) in reaction_systems {
        let Some(rs_obj) = rs_val.as_object() else {
            continue;
        };
        let Some(reactions) = rs_obj.get("reactions").and_then(|v| v.as_array()) else {
            continue;
        };
        for (r_idx, r_val) in reactions.iter().enumerate() {
            let Some(r_obj) = r_val.as_object() else {
                continue;
            };
            for side in ["substrates", "products"] {
                let Some(entries) = r_obj.get(side).and_then(|v| v.as_array()) else {
                    continue;
                };
                for (e_idx, e_val) in entries.iter().enumerate() {
                    let Some(e_obj) = e_val.as_object() else {
                        continue;
                    };
                    let Some(stoich) = e_obj.get("stoichiometry") else {
                        continue;
                    };
                    let path = format!(
                        "reaction_systems/{rs_name}/reactions[{r_idx}]/{side}[{e_idx}]/stoichiometry"
                    );
                    match stoich.as_f64() {
                        Some(v) if v.is_finite() && v > 0.0 => {}
                        Some(v) if !v.is_finite() => {
                            errors.push(format!("{path}: stoichiometry must be finite, got {v}"));
                        }
                        Some(v) => {
                            errors.push(format!("{path}: stoichiometry must be positive, got {v}"));
                        }
                        None => {
                            errors.push(format!("{path}: stoichiometry must be a number"));
                        }
                    }
                }
            }
        }
    }
}

/// Validate ISO 8601 dates, URLs, and DOIs in the metadata block, and reject
/// empty strings for those fields.
fn check_metadata_formats(obj: &serde_json::Map<String, Value>, errors: &mut Vec<String>) {
    let Some(md) = obj.get("metadata").and_then(|v| v.as_object()) else {
        return;
    };

    for field in ["created", "modified"] {
        if let Some(val) = md.get(field).and_then(|v| v.as_str())
            && !is_iso8601_datetime(val)
        {
            errors.push(format!(
                "metadata/{field}: '{val}' is not a valid ISO 8601 date"
            ));
        }
    }

    if let Some(refs) = md.get("references").and_then(|v| v.as_array()) {
        for (i, r) in refs.iter().enumerate() {
            let Some(r_obj) = r.as_object() else { continue };

            if let Some(url) = r_obj.get("url").and_then(|v| v.as_str()) {
                if url.is_empty() {
                    errors.push(format!(
                        "metadata/references[{i}]/url: empty string is not a valid URL"
                    ));
                } else if !is_valid_url(url) {
                    errors.push(format!(
                        "metadata/references[{i}]/url: '{url}' is not a valid URL"
                    ));
                }
            }

            if let Some(doi) = r_obj.get("doi").and_then(|v| v.as_str()) {
                if doi.is_empty() {
                    errors.push(format!(
                        "metadata/references[{i}]/doi: empty string is not a valid DOI"
                    ));
                } else if !is_valid_doi(doi) {
                    errors.push(format!(
                        "metadata/references[{i}]/doi: '{doi}' is not a valid DOI format"
                    ));
                }
            }

            if let Some(citation) = r_obj.get("citation").and_then(|v| v.as_str())
                && citation.is_empty()
            {
                errors.push(format!(
                    "metadata/references[{i}]/citation: empty citation string is not allowed"
                ));
            }
        }
    }
}

/// Any duration string inside `data_loader.temporal` (`file_period` or
/// `frequency`), if present, must be a valid ISO 8601 duration. The schema
/// types these as `string` but does not enforce the grammar.
fn check_data_loader_temporal_durations(
    obj: &serde_json::Map<String, Value>,
    errors: &mut Vec<String>,
) {
    let Some(loaders) = obj.get("data_sources").and_then(|v| v.as_object()) else {
        return;
    };
    for (dname, dv) in loaders {
        let Some(d) = dv.as_object() else { continue };
        let Some(temporal) = d.get("temporal").and_then(|v| v.as_object()) else {
            continue;
        };
        for field in ["file_period", "frequency"] {
            if let Some(res) = temporal.get(field).and_then(|v| v.as_str())
                && !res.is_empty()
                && !is_iso8601_duration(res)
            {
                errors.push(format!(
                    "data_sources/{dname}/temporal/{field}: '{res}' is not a valid ISO 8601 duration"
                ));
            }
        }
    }
}

/// In a coupling-library file (esm-spec §10.9) a coupling edge's system-naming
/// segments name declared ROLES, not systems: the library holds no models, so
/// resolving them against a symbol table would reject every well-formed library.
/// §10.9 suspends that resolution and requires the top-level segment at every
/// §10.10.2 occurrence site to name a declared role instead
/// (`coupling_edge_unknown_role`), which is the same check `coupling_imports`
/// runs when the library is imported — the shared `collect_role_segments` walk
/// is what keeps the two sites from drifting apart. A document that is not a
/// coupling library (`coupling_roles` is the sole positive identifier) has its
/// coupling references judged after typing
/// ([`crate::structural::load_reference_errors`]).
fn check_coupling_role_references(obj: &serde_json::Map<String, Value>, errors: &mut Vec<String>) {
    if !crate::coupling_imports::is_coupling_library_obj(obj) {
        return;
    }
    let Some(coupling) = obj.get("coupling").and_then(|v| v.as_array()) else {
        return;
    };
    let roles: std::collections::HashSet<&str> = obj
        .get("coupling_roles")
        .and_then(|v| v.as_object())
        .map(|o| o.keys().map(String::as_str).collect())
        .unwrap_or_default();
    for (i, c) in coupling.iter().enumerate() {
        if !c.is_object() {
            continue;
        }
        let mut unknown: Vec<String> = crate::coupling_imports::collect_role_segments(c)
            .into_iter()
            .filter(|seg| !roles.contains(seg.as_str()))
            .collect();
        unknown.sort();
        for seg in unknown {
            errors.push(format!(
                "coupling[{i}]: edge references '{seg}', which is not a declared role \
                 (esm-spec §10.9: a coupling library's refs name a role in `coupling_roles`)"
            ));
        }
    }
}

// ---- lightweight format validators ---------------------------------------

/// Accept `YYYY-MM-DD` or `YYYY-MM-DDTHH:MM:SS[.fff][Z|±HH:MM]`.
fn is_iso8601_datetime(s: &str) -> bool {
    let bytes = s.as_bytes();
    if bytes.len() < 10 {
        return false;
    }
    // Date portion
    if !(bytes[0].is_ascii_digit()
        && bytes[1].is_ascii_digit()
        && bytes[2].is_ascii_digit()
        && bytes[3].is_ascii_digit()
        && bytes[4] == b'-'
        && bytes[5].is_ascii_digit()
        && bytes[6].is_ascii_digit()
        && bytes[7] == b'-'
        && bytes[8].is_ascii_digit()
        && bytes[9].is_ascii_digit())
    {
        return false;
    }
    if bytes.len() == 10 {
        return true;
    }
    // Must have T separator next
    if bytes[10] != b'T' {
        return false;
    }
    // Time portion HH:MM:SS
    if bytes.len() < 19
        || !(bytes[11].is_ascii_digit()
            && bytes[12].is_ascii_digit()
            && bytes[13] == b':'
            && bytes[14].is_ascii_digit()
            && bytes[15].is_ascii_digit()
            && bytes[16] == b':'
            && bytes[17].is_ascii_digit()
            && bytes[18].is_ascii_digit())
    {
        return false;
    }
    let mut idx = 19;
    // Optional fractional seconds
    if idx < bytes.len() && bytes[idx] == b'.' {
        idx += 1;
        let start = idx;
        while idx < bytes.len() && bytes[idx].is_ascii_digit() {
            idx += 1;
        }
        if idx == start {
            return false;
        }
    }
    // Timezone (optional)
    if idx == bytes.len() {
        return true;
    }
    if bytes[idx] == b'Z' {
        return idx + 1 == bytes.len();
    }
    if bytes[idx] == b'+' || bytes[idx] == b'-' {
        // ±HH:MM or ±HHMM
        let rest = &bytes[idx + 1..];
        return (rest.len() == 5
            && rest[0].is_ascii_digit()
            && rest[1].is_ascii_digit()
            && rest[2] == b':'
            && rest[3].is_ascii_digit()
            && rest[4].is_ascii_digit())
            || (rest.len() == 4 && rest.iter().all(|b| b.is_ascii_digit()));
    }
    false
}

/// Accept `^https?://[^\s/$.?#].[^\s]*$` — the loose URL shape Python uses.
fn is_valid_url(s: &str) -> bool {
    let lowered = s.to_ascii_lowercase();
    if !(lowered.starts_with("http://") || lowered.starts_with("https://")) {
        return false;
    }
    let scheme_len = if lowered.starts_with("https://") {
        8
    } else {
        7
    };
    let after = &s[scheme_len..];
    if after.is_empty() {
        return false;
    }
    // Must have at least one dot in the host section before any path separator.
    let host_end = after.find('/').unwrap_or(after.len());
    let host = &after[..host_end];
    if host.is_empty() || !host.contains('.') {
        return false;
    }
    !s.chars().any(|c| c.is_whitespace())
}

/// Accept `^10\.\d{4,9}/[^\s]+$` — the DOI shape defined by CrossRef.
fn is_valid_doi(s: &str) -> bool {
    let Some(rest) = s.strip_prefix("10.") else {
        return false;
    };
    let Some(slash) = rest.find('/') else {
        return false;
    };
    let registrant = &rest[..slash];
    let suffix = &rest[slash + 1..];
    if !(4..=9).contains(&registrant.len()) || !registrant.bytes().all(|b| b.is_ascii_digit()) {
        return false;
    }
    !suffix.is_empty() && !suffix.chars().any(|c| c.is_whitespace())
}

/// Accept the ISO 8601 duration shape Python enforces: `P` followed by an
/// optional date part (`\d+Y`, `\d+M`, `\d+W`, `\d+D`) and an optional time
/// part introduced by `T` (`\d+H`, `\d+M`, `\d+(\.\d+)?S`). Must have at
/// least one component.
fn is_iso8601_duration(s: &str) -> bool {
    let mut chars = s.chars().peekable();
    if chars.next() != Some('P') {
        return false;
    }
    let mut any_component = false;

    // Date components before T
    while let Some(&c) = chars.peek() {
        if c == 'T' {
            break;
        }
        if !c.is_ascii_digit() {
            return false;
        }
        // consume digits
        while let Some(&d) = chars.peek() {
            if d.is_ascii_digit() {
                chars.next();
            } else {
                break;
            }
        }
        match chars.next() {
            Some('Y') | Some('M') | Some('W') | Some('D') => {
                any_component = true;
            }
            _ => return false,
        }
    }

    if chars.peek() == Some(&'T') {
        chars.next();
        while let Some(&c) = chars.peek() {
            if !c.is_ascii_digit() {
                return false;
            }
            while let Some(&d) = chars.peek() {
                if d.is_ascii_digit() {
                    chars.next();
                } else {
                    break;
                }
            }
            // Optional fractional seconds — only valid before the final `S`
            if chars.peek() == Some(&'.') {
                chars.next();
                let mut had_digit = false;
                while let Some(&d) = chars.peek() {
                    if d.is_ascii_digit() {
                        chars.next();
                        had_digit = true;
                    } else {
                        break;
                    }
                }
                if !had_digit {
                    return false;
                }
                if chars.next() != Some('S') {
                    return false;
                }
                any_component = true;
                break;
            }
            match chars.next() {
                Some('H') | Some('M') | Some('S') => {
                    any_component = true;
                }
                _ => return false,
            }
        }
    }

    any_component && chars.next().is_none()
}

/// The wire-boundary op checks: a removed op (`arrayop`, removed at esm 0.8.0,
/// the ops and the `function_tables` block esm 2.0.0 removed,
/// [`REMOVED_AT_V2`], `aggregate` among them, and the `grad` / `div` /
/// `laplacian` ops esm 2.4.0 removed, [`REMOVED_AT_V2_4`]) is rejected by name with
/// `removed_op`, `faq` is refused in a document declaring esm below 1.1.0, and
/// the deprecated spellings `neg` and `pow`
/// ([`crate::op_registry::deprecated_op`]) are rewritten
/// to unary `-` and `^` with one `deprecated_op` warning (esm-spec §4.2).
pub(crate) fn prepare_document_ops(value: &mut serde_json::Value) -> Result<(), EsmError> {
    prepare_document_ops_scanned(value).map(|_| ())
}

/// What [`prepare_document_ops_scanned`]'s walk also noted about the authored
/// document, for a later pass that would otherwise walk it again.
#[derive(Default)]
pub(crate) struct AuthoredFacts {
    /// The path of the first object, in pre-order, with both an `op` and a
    /// `units` key (what the const-units version gate looks for).
    pub(crate) op_with_units: Option<String>,
    /// The pointer of the first model variable carrying `lb` or `ub` (what
    /// the variable-bounds version gate looks for).
    /// Looked for only when the document declares esm below 2.1.0, the one
    /// case the gate can fire; `None` otherwise.
    pub(crate) variable_bound: Option<String>,
}

/// [`prepare_document_ops`], returning the [`AuthoredFacts`] its walk noted.
pub(crate) fn prepare_document_ops_scanned(
    value: &mut serde_json::Value,
) -> Result<AuthoredFacts, EsmError> {
    // The two steps below read `op` tags, so they share ONE walk over the
    // document: it finds the first removed op node and the first `faq` node
    // (looked for only when the declared version is below 1.1.0, the one case
    // the gate can fire), in pre-order.
    use crate::version_gates::{FAQ, VARIABLE_BOUNDS, VERSIONED};
    let faq_too_old = VERSIONED[FAQ].predates(value);
    let esm_declared = value
        .get("esm")
        .and_then(|v| v.as_str())
        .map(str::to_string);
    let mut scan = OpScan {
        want_faq: faq_too_old,
        ..OpScan::default()
    };
    scan_document_ops(value, &crate::json_visit::JsonPath::Root(""), &mut scan);
    if scan.removed.is_none()
        && let Some(path) = function_tables_path(value)
    {
        scan.removed = Some(Removed::FunctionTables { path });
    }
    // The bounds gate fires only below esm 2.1.0, so the variables are walked
    // for a bound only then. It is read here, on the authored tree, because
    // the gate runs after ref resolution may have spliced a mounted file's
    // variables in (esm-spec §4.7 "Each file is held to its own declared
    // `esm` version").
    let bounds_too_old = VERSIONED[VARIABLE_BOUNDS].predates(value);
    let facts = AuthoredFacts {
        op_with_units: scan.op_with_units.take(),
        variable_bound: if bounds_too_old {
            crate::variable_bounds::first_bound_pointer(value)
        } else {
            None
        },
    };
    // 1. A removed op or block — rejected by name, before anything else.
    if let Some(removed) = scan.removed {
        return Err(EsmError::SchemaDiagnostic {
            code: crate::diagnostic::codes::REMOVED_OP,
            message: removed.message(),
            findings: Vec::new(),
        });
    }
    // 2. Version gate. `faq` arrives at esm 1.1.0, so a document that spells
    //    it while declaring less is rejected — the same rule the top-level
    //    `solver` block follows (esm-spec §2.2.4).
    if let Some(path) = scan.faq
        && let Some(esm) = esm_declared
    {
        return Err(EsmError::SchemaDiagnostic {
            code: VERSIONED[FAQ].code,
            message: VERSIONED[FAQ].message(&esm, &path),
            findings: Vec::new(),
        });
    }
    // 3. Deprecated spellings (esm-spec §4.2 "Deprecated ops"): the walk
    //    already rewrote them; the document loads with ONE warning naming
    //    every rewritten node. Every document a load touches passes here, so
    //    each warns for its own nodes.
    if let Some(warning) = deprecated_op_warning(&scan.deprecated) {
        eprintln!("warning: {warning}");
    }
    Ok(facts)
}

/// The expression ops esm 2.0.0 removed (esm-spec, "2.0.0 is a break"):
/// `aggregate`, the pre-1.1.0 spelling of `faq`, and the external functions,
/// each of which has a pure-AST replacement in the `esm:std/*.esm` template
/// library. The
/// offline codemod (`earthsci_ast.migration`, Python) rewrites a 1.x document
/// to it. Loaders carry no rewrite of their own.
pub(crate) const REMOVED_AT_V2: [&str; 9] = [
    "aggregate",
    "fn",
    "table_lookup",
    "skolem",
    "rank",
    "intersect_polygon",
    "polygon_intersection_area",
    "argmin",
    "argmax",
];

/// The spatial-calculus ops esm 2.4.0 removed (esm-spec §4.2 "Removed ops"):
/// each is written with spatial `D`, one `D` per axis, or with a user op
/// lowered by a rewrite rule. There is no codemod for these.
pub(crate) const REMOVED_AT_V2_4: [&str; 3] = ["grad", "div", "laplacian"];

/// The first removed construct a document uses, and where.
pub(crate) enum Removed {
    /// An `"op"` naming a removed op (`arrayop`, or one of [`REMOVED_AT_V2`] or
    /// [`REMOVED_AT_V2_4`]).
    Op { path: String, op: String },
    /// The `function_tables` block, removed at esm 2.0.0.
    FunctionTables { path: String },
}

impl Removed {
    /// The `removed_op` diagnostic for this construct.
    pub(crate) fn message(&self) -> String {
        match self {
            Removed::Op { path, op } if op == "arrayop" => format!(
                "removed_op at {path}: `\"op\": \"arrayop\"` was removed at esm 0.8.0 and is \
                 not a deprecated alias; use `\"op\": \"faq\"` (the Functional Aggregate Query \
                 node). See docs/content/rfcs/faq-node-rename.md."
            ),
            Removed::Op { path, op } if op == "aggregate" => format!(
                "removed_op at {path}: `\"op\": \"aggregate\"`, the pre-1.1.0 spelling of \
                 `\"op\": \"faq\"`, was removed at esm 2.0.0; write `faq` (the codemod, \
                 `python -m earthsci_ast.migrate`, renames it)."
            ),
            Removed::Op { path, op } if REMOVED_AT_V2_4.contains(&op.as_str()) => format!(
                "removed_op at {path}: `\"op\": \"{op}\"` was removed at esm 2.4.0; write the \
                 derivative with spatial `D`, one `D` per axis (`grad(f, dim: x)` is \
                 `D(f, wrt: x)`), or with a user op lowered by a rewrite rule (MIGRATION.md, \
                 \"esm 2.4.0\")."
            ),
            Removed::Op { path, op } => format!(
                "removed_op at {path}: `\"op\": \"{op}\"` was removed at esm 2.0.0; its \
                 replacement is an `esm:std/*.esm` expression template. Convert the document \
                 with the codemod (`python -m earthsci_ast.migrate`, see MIGRATION.md)."
            ),
            Removed::FunctionTables { path } => format!(
                "removed_op at {path}: the `function_tables` block was removed at esm 2.0.0 \
                 together with `table_lookup`; its replacement is the `linear` / `bilinear` \
                 templates of `esm:std/interp.esm` over the table's data. Convert the document \
                 with the codemod (`python -m earthsci_ast.migrate`, see MIGRATION.md)."
            ),
        }
    }
}

/// Is `op` an op name a loader rejects by name with `removed_op`?
pub(crate) fn is_removed_op(op: &str) -> bool {
    op == "arrayop" || REMOVED_AT_V2.contains(&op) || REMOVED_AT_V2_4.contains(&op)
}

/// The path of a `function_tables` block in a raw document: at the top level,
/// or on a component under `models` / `reaction_systems`.
fn function_tables_path(value: &serde_json::Value) -> Option<String> {
    let obj = value.as_object()?;
    if obj.contains_key("function_tables") {
        return Some("/function_tables".to_string());
    }
    for block in ["models", "reaction_systems"] {
        for (name, comp) in obj
            .get(block)
            .and_then(|v| v.as_object())
            .into_iter()
            .flatten()
        {
            if comp.get("function_tables").is_some() {
                return Some(format!("/{block}/{name}/function_tables"));
            }
        }
    }
    None
}

/// What [`scan_document_ops`] found.
#[derive(Default)]
struct OpScan {
    /// Look for authored `faq` nodes at all.
    want_faq: bool,
    /// The first removed op node. A removed op is not deprecated: without this
    /// check it is a perfectly well-formed identifier and would fall into the
    /// OPEN rewrite-target tier (esm-spec §4.2), loading silently and failing
    /// only much later as an `unlowered_operator`.
    removed: Option<Removed>,
    /// The path of the first `"op": "faq"` node.
    faq: Option<String>,
    /// See [`AuthoredFacts`].
    op_with_units: Option<String>,
    /// Every node the walk rewrote from a deprecated spelling, as its RFC 6901
    /// JSON pointer and the spelling it had (`neg`, `pow` or `broadcast fn
    /// neg`), in pre-order: the warning names each as `<pointer> (<spelling>)`,
    /// the format every binding uses.
    deprecated: Vec<(String, &'static str)>,
}

/// Rewrite one node spelled with a deprecated op (esm-spec §4.2 "Deprecated
/// ops") to its replacement in place, recording its path: `neg` with one
/// operand becomes unary `-`, `pow` with two becomes `^`, and a `broadcast`
/// whose `fn` is `neg` gets `fn: "-"`. Only the tag changes; every other field
/// is kept. A node with the wrong operand count is left as written, so the
/// arity check refuses it as it always did.
fn rewrite_deprecated_op(
    map: &mut serde_json::Map<String, serde_json::Value>,
    at: &crate::json_visit::JsonPath<'_>,
    out: &mut Vec<(String, &'static str)>,
) {
    let Some(op) = map.get("op").and_then(|v| v.as_str()) else {
        return;
    };
    if op == "broadcast" {
        // `neg` is strictly unary, so a broadcast of it with any other operand
        // count keeps its arity error (`invalid_broadcast_fn`).
        let unary = map
            .get("args")
            .and_then(|v| v.as_array())
            .is_some_and(|args| args.len() == 1);
        if unary && map.get("fn").and_then(|v| v.as_str()) == Some("neg") {
            map.insert("fn".to_string(), serde_json::Value::from("-"));
            out.push((at.pointer(), "broadcast fn neg"));
        }
        return;
    }
    let Some((name, replacement)) = crate::op_registry::deprecated_op(op) else {
        return;
    };
    let well_formed = map
        .get("args")
        .and_then(|v| v.as_array())
        .is_some_and(|args| {
            crate::op_registry::arity_of(name).is_some_and(|a| a.admits(args.len()))
        });
    if well_formed {
        map.insert("op".to_string(), serde_json::Value::from(replacement));
        out.push((at.pointer(), name));
    }
}

/// The `deprecated_op` load warning for the rewrites one document's walk made,
/// or `None` when it spelled no deprecated op.
fn deprecated_op_warning(rewritten: &[(String, &'static str)]) -> Option<String> {
    (!rewritten.is_empty()).then(|| {
        let sites: Vec<String> = rewritten
            .iter()
            .map(|(pointer, spelling)| format!("{pointer} ({spelling})"))
            .collect();
        format!(
            "deprecated_op: the deprecated op spellings `neg` (unary `-`) and `pow` (`^`) \
             were rewritten to their replacements on load, with no change of value; write \
             `-` and `^` instead (esm-spec §4.2 \"Deprecated ops\"). Rewritten at: {}.",
            sites.join(", ")
        )
    })
}

/// Pre-order walk (the root included, a container before its elements, array
/// elements in index order, object entries in map order): record the first
/// removed op node's path and, when asked, the first `faq` node's. A removed
/// op ends the walk, since the document is then rejected.
fn scan_document_ops(
    value: &mut serde_json::Value,
    at: &crate::json_visit::JsonPath<'_>,
    scan: &mut OpScan,
) {
    use crate::json_visit::JsonPath;
    match value {
        serde_json::Value::Object(map) => {
            let op = crate::json_visit::small_get(map, "op");
            if scan.op_with_units.is_none()
                && op.is_some()
                && crate::json_visit::small_get(map, "units").is_some()
            {
                scan.op_with_units = Some(at.to_string());
            }
            match op.and_then(|v| v.as_str()) {
                Some(op) if is_removed_op(op) => {
                    scan.removed = Some(Removed::Op {
                        path: at.to_string(),
                        op: op.to_string(),
                    });
                    return;
                }
                Some("faq") if scan.want_faq && scan.faq.is_none() => {
                    scan.faq = Some(at.to_string());
                }
                _ => {}
            }
            rewrite_deprecated_op(map, at, &mut scan.deprecated);
            for (k, v) in map.iter_mut() {
                scan_document_ops(v, &JsonPath::Key(at, k), scan);
                if scan.removed.is_some() {
                    return;
                }
            }
        }
        serde_json::Value::Array(items) => {
            for (i, v) in items.iter_mut().enumerate() {
                scan_document_ops(v, &JsonPath::Index(at, i), scan);
                if scan.removed.is_some() {
                    return;
                }
            }
        }
        _ => {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The pass table answers what runs for each kind of document: an emit
    /// source takes the wire boundary, the template machinery and template
    /// lowering, in that order, and a root every pass.
    #[test]
    fn each_kind_of_document_takes_its_passes_in_table_order() {
        let names = |role| {
            LOAD_PASSES
                .iter()
                .filter(|p| p.roles.contains(&role))
                .map(|p| p.name)
                .collect::<Vec<_>>()
        };
        assert_eq!(
            names(DocRole::EmitSource),
            [
                "wire boundary ops",
                "template machinery",
                "template lowering"
            ]
        );
        assert_eq!(names(DocRole::Root).len(), LOAD_PASSES.len());
    }

    /// The deprecated spellings (esm-spec §4.2 "Deprecated ops") are
    /// rewritten in place by the wire-boundary walk — `neg` to unary `-`, `pow`
    /// to `^`, a `broadcast` `fn` of `neg` to `-` — keeping every other field,
    /// and each rewritten node is recorded, in pre-order, for the ONE
    /// `deprecated_op` warning. A node with the wrong operand count is left
    /// alone so the arity check refuses it as before.
    #[test]
    fn deprecated_ops_are_rewritten_and_recorded() {
        use serde_json::json;
        let mut v = json!({
            "a": {"op": "neg", "args": ["x"], "id": "keep"},
            "b": {"op": "pow", "args": [{"op": "neg", "args": [2.5]}, 2]},
            "c": {"op": "broadcast", "fn": "neg", "args": ["y"]},
            "d": {"op": "neg", "args": ["x", "y"]},
            "e": {"op": "pow", "args": ["x"]},
            "f": {"op": "broadcast", "fn": "pow", "args": ["x", 2]},
            "g": {"op": "broadcast", "fn": "neg", "args": ["x", "y"]},
            "h/i~": {"op": "neg", "args": ["x"]}
        });
        let mut scan = OpScan::default();
        scan_document_ops(&mut v, &crate::json_visit::JsonPath::Root(""), &mut scan);
        assert_eq!(v["a"], json!({"op": "-", "args": ["x"], "id": "keep"}));
        assert_eq!(
            v["b"],
            json!({"op": "^", "args": [{"op": "-", "args": [2.5]}, 2]})
        );
        assert_eq!(v["c"], json!({"op": "broadcast", "fn": "-", "args": ["y"]}));
        assert_eq!(v["d"]["op"], "neg", "wrong arity is left as written");
        assert_eq!(v["e"]["op"], "pow", "wrong arity is left as written");
        assert_eq!(
            v["f"]["fn"], "pow",
            "only `fn: neg` is a deprecated broadcast fn"
        );
        assert_eq!(
            v["g"]["fn"], "neg",
            "a two-operand broadcast of neg keeps its arity error"
        );
        let mut sites = scan.deprecated.clone();
        sites.sort();
        assert_eq!(
            sites,
            vec![
                ("/a".to_string(), "neg"),
                ("/b".to_string(), "pow"),
                ("/b/args/0".to_string(), "neg"),
                ("/c".to_string(), "broadcast fn neg"),
                ("/h~1i~0".to_string(), "neg"),
            ]
        );
        let warning = deprecated_op_warning(&scan.deprecated).expect("one warning");
        assert!(warning.starts_with("deprecated_op: "), "{warning}");
        for site in [
            "/a (neg)",
            "/b (pow)",
            "/b/args/0 (neg)",
            "/c (broadcast fn neg)",
            "/h~1i~0 (neg)",
        ] {
            assert!(warning.contains(site), "{warning} lacks {site}");
        }
        assert!(deprecated_op_warning(&[]).is_none());
        // The public pass keeps the rewrite: a document that spells one loads.
        let mut doc = json!({"esm": "2.0.0", "x": {"op": "neg", "args": ["z"]}});
        prepare_document_ops(&mut doc).expect("a deprecated op is not an error");
        assert_eq!(doc["x"]["op"], "-");
    }

    /// The one walk of `prepare_document_ops` reports what its two steps did
    /// taken one at a time: the first removed op anywhere wins over an earlier
    /// `faq`, and the version gate names the first `faq`. `aggregate`, the
    /// pre-1.1.0 spelling of `faq`, is a removed op at 2.0.0.
    #[test]
    fn prepare_document_ops_reports_as_its_steps_did() {
        use serde_json::json;
        let run = |mut v: Value| {
            prepare_document_ops(&mut v)
                .map(|()| v)
                .map_err(|e| e.to_string())
        };
        let e =
            run(json!({"esm": "1.0.0", "a": {"op": "faq"}, "b": [{"op": "x"}, {"op": "arrayop"}]}))
                .unwrap_err();
        assert!(e.contains("removed_op at /b/1:"), "{e}");
        let e = run(json!({"esm": "2.0.0", "a": {"op": "faq", "args": [{"op": "aggregate"}]}}))
            .unwrap_err();
        assert!(e.contains("removed_op at /a/args/0:"), "{e}");
        assert!(e.contains("\"aggregate\""), "{e}");
        let e = run(
            json!({"esm": "1.0.0", "a": {"op": "+", "args": [{"op": "faq"}]}, "b": {"op": "faq"}}),
        )
        .unwrap_err();
        assert!(e.contains("faq_version_too_old at /a/args/0:"), "{e}");
        assert!(e.contains("file declares 1.0.0"), "{e}");
        let v = run(json!({"esm": "2.0.0", "a": {"op": "faq"}})).unwrap();
        assert_eq!(v, json!({"esm": "2.0.0", "a": {"op": "faq"}}));
    }

    /// `grad`, `div` and `laplacian` are refused by name whatever `esm` the
    /// document declares, with a message pointing at spatial `D` and
    /// MIGRATION.md, never at the 2.0.0 codemod.
    #[test]
    fn the_ops_removed_at_v2_4_are_refused_without_a_codemod_pointer() {
        use serde_json::json;
        for op in REMOVED_AT_V2_4 {
            for esm in ["1.3.0", "2.3.0", crate::SCHEMA_VERSION] {
                let mut v =
                    json!({"esm": esm, "m": {"rhs": {"op": op, "args": ["u"], "dim": "x"}}});
                let e = prepare_document_ops(&mut v).unwrap_err().to_string();
                assert!(e.contains("removed_op at /m/rhs:"), "{e}");
                assert!(e.contains(&format!("\"{op}\"")), "{e}");
                assert!(e.contains("removed at esm 2.4.0"), "{e}");
                assert!(e.contains("spatial `D`"), "{e}");
                assert!(e.contains("MIGRATION.md"), "{e}");
                assert!(!e.contains("earthsci_ast.migrate"), "{e}");
            }
        }
    }

    #[test]
    fn test_load_minimal_model() {
        let json = r#"
        {
          "esm": "2.0.0",
          "metadata": {
            "name": "test_model"
          },
          "models": {
            "simple": {
              "variables": {},
              "equations": []
            }
          }
        }
        "#;

        let result = load_string(json);
        assert!(result.is_ok());

        let esm_file = result.unwrap();
        assert_eq!(esm_file.esm, "2.0.0");
        assert!(esm_file.models.is_some());
    }

    #[test]
    fn test_load_invalid_json() {
        let json = r#"{ invalid json }"#;
        let result = load_string(json);
        assert!(result.is_err());
        match result.unwrap_err() {
            EsmError::JsonParse(_) => {} // Expected
            _ => panic!("Expected JsonParse error"),
        }
    }

    #[test]
    fn test_load_missing_esm_version() {
        let json = r#"
        {
          "metadata": {
            "name": "test_model"
          },
          "models": {}
        }
        "#;

        let result = load_string(json);
        assert!(result.is_err());
        match result.unwrap_err() {
            EsmError::SchemaValidation(_) => {} // Expected
            _ => panic!("Expected SchemaValidation error"),
        }
    }

    #[test]
    fn test_load_malformed_esm_version() {
        let json = r#"
        {
          "esm": "not-a-version",
          "metadata": {
            "name": "test_model"
          },
          "models": {}
        }
        "#;

        let result = load_string(json);
        assert!(result.is_err());
        match result.unwrap_err() {
            EsmError::SchemaValidation(_) => {} // Expected
            _ => panic!("Expected SchemaValidation error"),
        }
    }

    #[test]
    fn test_load_missing_content() {
        let json = r#"
        {
          "esm": "2.0.0",
          "metadata": {
            "name": "test_model"
          }
        }
        "#;

        let result = load_string(json);
        assert!(result.is_err());
        match result.unwrap_err() {
            EsmError::SchemaValidation(_) => {} // Expected
            _ => panic!("Expected SchemaValidation error"),
        }
    }

    #[test]
    fn test_round_trip() {
        use crate::to_json;

        let json = r#"
        {
          "esm": "2.0.0",
          "metadata": {
            "name": "test_model"
          },
          "models": {
            "simple": {
              "variables": {},
              "equations": []
            }
          }
        }
        "#;

        // Load the JSON
        let esm_file = load_string(json).expect("Failed to load ESM file");

        // Save it back to JSON
        let serialized_json = to_json(&esm_file).expect("Failed to save ESM file");

        // Load it again
        let round_trip_file =
            load_string(&serialized_json).expect("Failed to load round-trip ESM file");

        // Verify the structure is preserved
        assert_eq!(esm_file.esm, round_trip_file.esm);
        assert_eq!(esm_file.metadata.name, round_trip_file.metadata.name);
        assert!(esm_file.models.is_some());
        assert!(round_trip_file.models.is_some());

        let models1 = esm_file.models.as_ref().unwrap();
        let models2 = round_trip_file.models.as_ref().unwrap();
        assert_eq!(models1.len(), models2.len());
        assert!(models1.contains_key("simple"));
        assert!(models2.contains_key("simple"));
    }
}
