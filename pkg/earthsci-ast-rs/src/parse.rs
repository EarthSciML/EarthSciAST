//! JSON parsing and schema validation for ESM files

use crate::{EsmFile, error::EsmError};
use jsonschema::{Draft, JSONSchema};
use serde_json::Value;
use std::sync::OnceLock;

/// Library version supported by this implementation (major, minor, patch),
/// derived from [`crate::SCHEMA_VERSION`] so the two can never drift. Files
/// with a major version mismatch are rejected per the version compatibility
/// rules in esm-libraries-spec §8.
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
fn get_schema() -> &'static JSONSchema {
    static SCHEMA: OnceLock<JSONSchema> = OnceLock::new();
    SCHEMA.get_or_init(|| {
        let schema_value: Value =
            serde_json::from_str(ESM_SCHEMA_JSON).expect("Bundled schema should be valid JSON");
        JSONSchema::options()
            .with_draft(Draft::Draft202012)
            .should_validate_formats(true)
            .compile(&schema_value)
            .expect("Bundled schema should compile successfully")
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
/// use earthsci_ast::load;
///
/// let json = r#"
/// {
///   "esm": "0.1.0",
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
/// let esm_file = load(json).expect("Failed to load ESM file");
/// assert_eq!(esm_file.esm, "0.1.0");
/// ```
pub fn load(json_str: &str) -> Result<EsmFile, EsmError> {
    load_with_options(json_str, &LoadOptions::default())
}

/// Options controlling how [`load_with_options`] /
/// [`load_path_with_options`] parse an ESM file (esm-spec §9.7).
#[derive(Debug, Clone, Default)]
pub struct LoadOptions {
    /// Directory anchoring relative subsystem refs and
    /// `expression_template_imports` refs (esm-spec §9.7.2). Defaults to the
    /// current working directory for string input; `load_path` uses the
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
pub fn load_with_options(json_str: &str, options: &LoadOptions) -> Result<EsmFile, EsmError> {
    // First, parse the JSON
    let mut json_value: Value = serde_json::from_str(json_str).map_err(EsmError::JsonParse)?;

    let base = options.base_path.clone().unwrap_or_else(|| {
        std::env::current_dir().unwrap_or_else(|_| std::path::PathBuf::from("."))
    });

    // Resolve any subsystem refs before schema validation, per spec section
    // 2.1b. Callers that load from a known file path should use `load_path`,
    // which uses the file's own directory as the base.
    crate::ref_loading::resolve_subsystem_refs(&mut json_value, &base)
        .map_err(EsmError::SchemaValidation)?;

    // v0.4.0 expression_templates / apply_expression_template are rejected
    // when the file declares esm < 0.4.0 (RFC §5.4 spec-version gate).
    crate::lower_expression_templates::reject_expression_templates_pre_v04(&json_value)
        .map_err(|e| EsmError::SchemaValidation(e.to_string()))?;

    // v0.8.0 §9.7 constructs (expression_template_imports, top-level
    // expression_templates, metaparameters) are rejected when the file
    // declares esm < 0.8.0 (esm-spec §9.6.5).
    crate::template_imports::reject_template_imports_pre_v08(&json_value)
        .map_err(|e| EsmError::SchemaValidation(e.to_string()))?;

    // Validate against schema
    validate_schema(&json_value)?;

    // esm-spec §9.7.10 form B: fold any coupling-entry injection map into its
    // target components' own `expression_template_imports` BEFORE resolution,
    // so the ordinary import resolver + §9.6.3 fixpoint lower the named
    // target under the assembler-chosen discretization. The injection map is
    // consumed here (does not survive parse → emit); target diagnostics
    // (`template_inject_target_*`) surface as load errors. (Form A is threaded
    // through the subsystem-ref pass in `ref_loading::resolve_value` above.)
    crate::template_imports::apply_scope_injections(&mut json_value, &[])
        .map_err(|e| EsmError::SchemaValidation(e.to_string()))?;

    // Resolve esm-spec §9.7 machinery — template-library imports
    // (depth-first post-order, per-edge metaparameter instantiation),
    // index_sets merge, metaparameter close+fold — before structural
    // validation and the §9.6.3 fixpoint, so validators run on the folded,
    // expanded form (esm-spec §9.6.4 / §9.7.6).
    if let Some(resolved) = crate::template_imports::resolve_template_machinery(
        &json_value,
        &base,
        &options.metaparameters,
    )
    .map_err(|e| EsmError::SchemaValidation(e.to_string()))?
    {
        json_value = resolved;
    }

    // Post-schema structural + semantic checks (version compatibility,
    // cross-field format rules, reference integrity, cyclic coupling) — the
    // things JSON Schema cannot express. Mirrors Python / Julia so that
    // cross-language conformance agrees.
    validate_structural_json(&json_value)?;

    // Expand `apply_expression_template` ops at load time (esm-spec §9.6 /
    // docs/rfcs/ast-expression-templates.md). After this pass the JSON tree
    // has no apply_expression_template nodes and no expression_templates
    // blocks — typed structs see only normal Expression ASTs.
    crate::lower_expression_templates::lower_expression_templates(&mut json_value)
        .map_err(|e| EsmError::SchemaValidation(e.to_string()))?;

    // Lower `enum`-op nodes to `const` integers using the file's `enums`
    // block (esm-spec §4.5 / §9.3). Mirrors the Julia / Python load-time
    // pass so that downstream consumers never see enum strings.
    crate::lower_enums::lower_enums(&mut json_value)
        .map_err(|e| EsmError::SchemaValidation(e.to_string()))?;

    // Emit deprecation warnings for any domain-level boundary_conditions
    // (v0.2.0 transitional shim per RFC §10.1 + gt-2fvs mayor decision).
    warn_deprecated_domain_bc(&json_value);

    // Deserialize into our types
    let esm_file: EsmFile = serde_json::from_value(json_value).map_err(EsmError::JsonParse)?;

    Ok(esm_file)
}

/// Check for v0.1.0 domain-level boundary_conditions and emit
/// E_DEPRECATED_DOMAIN_BC via `log::warn!` (or `eprintln!` if the `log`
/// feature is not configured). A follow-up bead will flip this to a hard
/// error once the migration tool (gt-fmrq) lands and in-tree fixtures are
/// migrated.
fn warn_deprecated_domain_bc(json_value: &Value) {
    let Some(domains) = json_value.get("domains").and_then(|v| v.as_object()) else {
        return;
    };
    for (domain_name, domain) in domains {
        if domain.get("boundary_conditions").is_some() {
            eprintln!(
                "[E_DEPRECATED_DOMAIN_BC] domains.{domain_name}.boundary_conditions is \
                 deprecated; migrate to models.<M>.boundary_conditions \
                 (docs/rfcs/discretization.md §9)."
            );
        }
    }
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
    load_with_options(&json_str, &options)
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
    let validation_result = schema.validate(json_value);

    match validation_result {
        Ok(_) => Ok(()),
        Err(errors) => {
            let error_messages: Vec<String> = errors.map(|error| error.to_string()).collect();
            Err(EsmError::SchemaValidation(error_messages.join("; ")))
        }
    }
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
// LOAD-TIME stack — it runs on raw JSON inside `load()`, gates whether a file
// parses at all, and its String messages are pinned cross-binding. The typed
// stack (`validate()` → structural.rs/coupling.rs) runs on demand over the
// deserialized `EsmFile` and reports structured `StructuralError`s. Several
// rules intentionally exist in BOTH layers (event variable references,
// discrete-parameter declarations, circular model dependencies): this layer
// rejects files that must not load; the typed layer re-checks documents that
// were constructed or edited in memory and never passed through `load()`.
// If you change a shared rule, change it in both layers (and the sibling
// bindings).

/// Run every post-schema structural check, collecting errors and returning
/// `EsmError::SchemaValidation` if any check fires.
fn validate_structural_json(json_value: &Value) -> Result<(), EsmError> {
    let mut errors: Vec<String> = Vec::new();

    if let Some(obj) = json_value.as_object() {
        check_version_compatibility(obj, &mut errors);
        check_metadata_formats(obj, &mut errors);
        check_data_loader_temporal_durations(obj, &mut errors);
        check_model_state_has_derivatives(obj, &mut errors);
        check_coupling_references(obj, &mut errors);
        check_circular_model_dependencies(obj, &mut errors);
        check_event_variable_references(obj, &mut errors);
        check_event_discrete_parameters(obj, &mut errors);
        check_reaction_stoichiometries(obj, &mut errors);
    }

    if errors.is_empty() {
        Ok(())
    } else {
        Err(EsmError::SchemaValidation(format!(
            "Structural validation failed: {}",
            errors.join("; ")
        )))
    }
}

/// Reject files whose major version does not match this library.
///
/// The schema already enforces the `\d+\.\d+\.\d+` pattern; this check runs
/// after that and rejects mismatched major versions with the standardized
/// message string the Julia / Python libraries use.
fn check_version_compatibility(obj: &serde_json::Map<String, Value>, errors: &mut Vec<String>) {
    let Some(ver) = obj.get("esm").and_then(|v| v.as_str()) else {
        return;
    };
    let Some((major, _, _)) = crate::diagnostic::parse_semver(ver) else {
        return;
    };
    let supported_major = library_version().0;
    if major != supported_major {
        errors.push(format!(
            "Unsupported major version {major}. This library supports major version {supported_major} only."
        ));
    }
}

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
    let Some(loaders) = obj.get("data_loaders").and_then(|v| v.as_object()) else {
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
                    "data_loaders/{dname}/temporal/{field}: '{res}' is not a valid ISO 8601 duration"
                ));
            }
        }
    }
}

/// A model that declares state variables must provide at least one equation.
/// An empty `equations: []` array paired with declared state variables is a
/// structural contradiction — there is nothing to integrate.
///
/// We deliberately do NOT require *every* state variable to appear on the
/// LHS of a D(_, t) equation: state variables may be governed by coupled
/// equations in other models, reaction systems, or operators elsewhere in
/// the file. Python and Julia take the same lenient-per-variable stance.
fn check_model_state_has_derivatives(
    obj: &serde_json::Map<String, Value>,
    errors: &mut Vec<String>,
) {
    let Some(models) = obj.get("models").and_then(|v| v.as_object()) else {
        return;
    };
    for (mname, mv) in models {
        let Some(m) = mv.as_object() else { continue };
        let Some(vars) = m.get("variables").and_then(|v| v.as_object()) else {
            continue;
        };
        let has_state = vars.values().any(|v| {
            v.as_object()
                .and_then(|o| o.get("type"))
                .and_then(|t| t.as_str())
                == Some("state")
        });
        if !has_state {
            continue;
        }
        let equations = m.get("equations").and_then(|v| v.as_array());
        match equations {
            Some(eqs) if eqs.is_empty() => {
                errors.push(format!(
                    "models/{mname}: declares state variables but has an empty 'equations' array"
                ));
            }
            None => {
                errors.push(format!(
                    "models/{mname}: declares state variables but no 'equations' field"
                ));
            }
            _ => {}
        }
    }
}

/// `coupling[].from` and `coupling[].to` must point to variables declared
/// somewhere in the file. We only enforce `from`, matching Python's lenient
/// handling of `to` (variable_map can introduce target vars).
fn check_coupling_references(obj: &serde_json::Map<String, Value>, errors: &mut Vec<String>) {
    let Some(coupling) = obj.get("coupling").and_then(|v| v.as_array()) else {
        return;
    };
    let tables = build_symbol_tables(obj);

    for (i, c) in coupling.iter().enumerate() {
        let Some(cobj) = c.as_object() else { continue };
        let Some(from_ref) = cobj.get("from").and_then(|v| v.as_str()) else {
            continue;
        };
        if !from_ref.contains('.') {
            continue;
        }
        let dot_count = from_ref.chars().filter(|ch| *ch == '.').count();
        if dot_count > 1 {
            // Subsystem-nested ref — only verify top-level system exists.
            let top = from_ref.split('.').next().unwrap_or("");
            if !tables.all_systems.contains(top) {
                errors.push(format!(
                    "coupling[{i}]/from: reference '{from_ref}' to undefined system '{top}'"
                ));
            }
            continue;
        }
        let (system, var) = from_ref.split_once('.').unwrap();
        if !tables.all_systems.contains(system) {
            errors.push(format!(
                "coupling[{i}]/from: reference '{from_ref}' to undefined system '{system}'"
            ));
            continue;
        }
        if !tables.has_variable(system, var) {
            errors.push(format!(
                "coupling[{i}]/from: reference '{from_ref}' — variable '{var}' not provided by '{system}'"
            ));
        }
    }
}

/// Detect cycles in model-to-model dependency edges derived from equation
/// RHS cross-system references. Mirrors Python's `_check_circular_references`.
fn check_circular_model_dependencies(
    obj: &serde_json::Map<String, Value>,
    errors: &mut Vec<String>,
) {
    let Some(models) = obj.get("models").and_then(|v| v.as_object()) else {
        return;
    };
    let model_names: std::collections::HashSet<&str> = models.keys().map(String::as_str).collect();
    if model_names.len() < 2 {
        return;
    }

    // Build system -> set of system names it references.
    let mut deps: std::collections::HashMap<&str, std::collections::HashSet<&str>> =
        std::collections::HashMap::new();
    for mname in &model_names {
        deps.insert(mname, std::collections::HashSet::new());
    }

    for (mname, mv) in models {
        let Some(m) = mv.as_object() else { continue };
        let Some(eqs) = m.get("equations").and_then(|v| v.as_array()) else {
            continue;
        };
        for eq in eqs {
            let mut refs: Vec<String> = Vec::new();
            if let Some(lhs) = eq.get("lhs") {
                collect_variable_refs(lhs, &mut refs);
            }
            if let Some(rhs) = eq.get("rhs") {
                collect_variable_refs(rhs, &mut refs);
            }
            for r in refs {
                if let Some((system, _var)) = r.split_once('.')
                    && system != mname.as_str()
                    && let Some(target) = model_names.get(system)
                    && let Some(set) = deps.get_mut(mname.as_str())
                {
                    set.insert(*target);
                }
            }
        }
    }

    // DFS with gray-coloring for cycle detection.
    #[derive(Clone, Copy, PartialEq)]
    enum Color {
        White,
        Gray,
        Black,
    }
    let mut color: std::collections::HashMap<&str, Color> =
        deps.keys().map(|k| (*k, Color::White)).collect();
    let mut cycle: Option<Vec<String>> = None;

    fn dfs<'a>(
        node: &'a str,
        deps: &std::collections::HashMap<&'a str, std::collections::HashSet<&'a str>>,
        color: &mut std::collections::HashMap<&'a str, Color>,
        path: &mut Vec<&'a str>,
        cycle: &mut Option<Vec<String>>,
    ) -> bool {
        color.insert(node, Color::Gray);
        path.push(node);
        if let Some(children) = deps.get(node) {
            for &child in children {
                match color.get(child).copied().unwrap_or(Color::White) {
                    Color::Gray => {
                        let start_idx = path.iter().position(|&n| n == child).unwrap_or(0);
                        let mut c: Vec<String> =
                            path[start_idx..].iter().map(|s| s.to_string()).collect();
                        c.push(child.to_string());
                        *cycle = Some(c);
                        return true;
                    }
                    Color::White => {
                        if dfs(child, deps, color, path, cycle) {
                            return true;
                        }
                    }
                    Color::Black => {}
                }
            }
        }
        color.insert(node, Color::Black);
        path.pop();
        false
    }

    for node in deps.keys().copied().collect::<Vec<_>>() {
        if color.get(node).copied().unwrap_or(Color::White) == Color::White {
            let mut path: Vec<&str> = Vec::new();
            if dfs(node, &deps, &mut color, &mut path, &mut cycle) {
                break;
            }
        }
    }

    if let Some(c) = cycle {
        errors.push(format!(
            "circular reference (cycle) detected: {}",
            c.join(" -> ")
        ));
    }
}

/// Every variable referenced by an event — either on the LHS of an
/// `affects` equation or inside a condition / trigger expression — must be
/// declared in the host model's `variables` map. Applies to both continuous
/// and discrete events. Mirrors Python's `_check_event_references` and
/// Julia's equivalent to keep cross-language error codes aligned per spec
/// §2.1a (error code: `EventVarUndeclared`).
fn check_event_variable_references(obj: &serde_json::Map<String, Value>, errors: &mut Vec<String>) {
    let Some(models) = obj.get("models").and_then(|v| v.as_object()) else {
        return;
    };

    for (mname, mv) in models {
        let Some(m) = mv.as_object() else { continue };
        let Some(vars) = m.get("variables").and_then(|v| v.as_object()) else {
            continue;
        };
        let declared: std::collections::HashSet<&str> = vars.keys().map(String::as_str).collect();

        // Continuous events: affects[].lhs must be declared; conditions[] expr
        // bare variable refs must be declared.
        if let Some(events) = m.get("continuous_events").and_then(|v| v.as_array()) {
            for (ei, event) in events.iter().enumerate() {
                let Some(event_obj) = event.as_object() else {
                    continue;
                };
                if let Some(affects) = event_obj.get("affects").and_then(|v| v.as_array()) {
                    for (ai, affect) in affects.iter().enumerate() {
                        if let Some(lhs) = affect.get("lhs").and_then(|v| v.as_str())
                            && !lhs.contains('.')
                            && !declared.contains(lhs)
                        {
                            errors.push(format!(
                                "models/{mname}/continuous_events[{ei}]/affects[{ai}]/lhs: \
                                 undeclared variable '{lhs}'"
                            ));
                        }
                    }
                }
                if let Some(conditions) = event_obj.get("conditions").and_then(|v| v.as_array()) {
                    for (ci, cond) in conditions.iter().enumerate() {
                        let mut refs: Vec<String> = Vec::new();
                        collect_variable_refs(cond, &mut refs);
                        for r in refs {
                            if r.contains('.') {
                                continue;
                            }
                            if !declared.contains(r.as_str()) {
                                errors.push(format!(
                                    "models/{mname}/continuous_events[{ei}]/conditions[{ci}]: \
                                     undeclared variable '{r}'"
                                ));
                            }
                        }
                    }
                }
            }
        }

        // Discrete events: affects[].lhs, plus trigger.expression if of type `condition`.
        if let Some(events) = m.get("discrete_events").and_then(|v| v.as_array()) {
            for (ei, event) in events.iter().enumerate() {
                let Some(event_obj) = event.as_object() else {
                    continue;
                };
                if let Some(affects) = event_obj.get("affects").and_then(|v| v.as_array()) {
                    for (ai, affect) in affects.iter().enumerate() {
                        if let Some(lhs) = affect.get("lhs").and_then(|v| v.as_str())
                            && !lhs.contains('.')
                            && !declared.contains(lhs)
                        {
                            errors.push(format!(
                                "models/{mname}/discrete_events[{ei}]/affects[{ai}]/lhs: \
                                 undeclared variable '{lhs}'"
                            ));
                        }
                    }
                }
                if let Some(trigger) = event_obj.get("trigger").and_then(|v| v.as_object())
                    && trigger.get("type").and_then(|v| v.as_str()) == Some("condition")
                    && let Some(expression) = trigger.get("expression")
                {
                    let mut refs: Vec<String> = Vec::new();
                    collect_variable_refs(expression, &mut refs);
                    for r in refs {
                        if r.contains('.') {
                            continue;
                        }
                        if !declared.contains(r.as_str()) {
                            errors.push(format!(
                                "models/{mname}/discrete_events[{ei}]/trigger/expression: \
                                 undeclared variable '{r}'"
                            ));
                        }
                    }
                }
            }
        }
    }
}

/// A discrete event's `discrete_parameters` list must name variables of type
/// `parameter` — not state variables, not observed, not undeclared. Mirrors
/// Python's `_check_discrete_parameters` (error code: `InvalidDiscreteParam`).
fn check_event_discrete_parameters(obj: &serde_json::Map<String, Value>, errors: &mut Vec<String>) {
    let Some(models) = obj.get("models").and_then(|v| v.as_object()) else {
        return;
    };

    for (mname, mv) in models {
        let Some(m) = mv.as_object() else { continue };
        let Some(vars) = m.get("variables").and_then(|v| v.as_object()) else {
            continue;
        };
        // name -> declared type
        let var_types: std::collections::HashMap<&str, &str> = vars
            .iter()
            .filter_map(|(name, def)| {
                def.as_object()
                    .and_then(|o| o.get("type"))
                    .and_then(|t| t.as_str())
                    .map(|t| (name.as_str(), t))
            })
            .collect();

        let Some(events) = m.get("discrete_events").and_then(|v| v.as_array()) else {
            continue;
        };
        for (ei, event) in events.iter().enumerate() {
            let Some(event_obj) = event.as_object() else {
                continue;
            };
            let Some(dps) = event_obj
                .get("discrete_parameters")
                .and_then(|v| v.as_array())
            else {
                continue;
            };
            for dp_val in dps {
                let Some(dp) = dp_val.as_str() else { continue };
                match var_types.get(dp) {
                    None => errors.push(format!(
                        "models/{mname}/discrete_events[{ei}]: discrete_parameter '{dp}' \
                         not declared in model"
                    )),
                    Some(&ty) if ty != "parameter" => errors.push(format!(
                        "models/{mname}/discrete_events[{ei}]: discrete_parameter '{dp}' \
                         references variable of type '{ty}', expected 'parameter'"
                    )),
                    _ => {}
                }
            }
        }
    }
}

// ---- structural helpers ---------------------------------------------------

/// Collect every bare `Expr::Variable`-style string out of an expression tree.
///
/// Descends the same expression-bearing operator-node fields as the typed
/// walker [`crate::types::ExpressionNode::for_each_child`]: `args`, `lower`,
/// `upper`, `expr`, `filter`, `values`, and `axes` — so references hidden in
/// aggregate bodies, filter predicates, integral bounds, and table-lookup
/// axes are not missed. Non-expression metadata keys (`ranges`, `output_idx`,
/// `regions`, …) are deliberately not descended: their strings are index
/// symbols and set names, not variable references.
fn collect_variable_refs(expr: &Value, out: &mut Vec<String>) {
    match expr {
        Value::String(s) => out.push(s.clone()),
        Value::Object(obj) => {
            for key in ["args", "values"] {
                if let Some(items) = obj.get(key).and_then(|v| v.as_array()) {
                    for a in items {
                        collect_variable_refs(a, out);
                    }
                }
            }
            for key in ["lower", "upper", "expr", "filter"] {
                if let Some(child) = obj.get(key) {
                    collect_variable_refs(child, out);
                }
            }
            if let Some(axes) = obj.get("axes").and_then(|v| v.as_object()) {
                for axis_expr in axes.values() {
                    collect_variable_refs(axis_expr, out);
                }
            }
        }
        Value::Array(arr) => {
            for a in arr {
                collect_variable_refs(a, out);
            }
        }
        _ => {}
    }
}

struct SymbolTables {
    /// Names of all top-level systems (models + reaction_systems + data_loaders).
    all_systems: std::collections::HashSet<String>,
    /// Per-system: the set of variable names declared in that system.
    per_system: std::collections::HashMap<String, std::collections::HashSet<String>>,
}

impl SymbolTables {
    fn has_variable(&self, system: &str, var: &str) -> bool {
        self.per_system
            .get(system)
            .map(|s| s.contains(var))
            .unwrap_or(false)
    }
}

/// Collect the keys of a component's `variables` object as a set of names,
/// yielding an empty set when the field is absent or not an object.
fn variable_keys(node: &Value) -> std::collections::HashSet<String> {
    node.as_object()
        .and_then(|o| o.get("variables"))
        .and_then(|v| v.as_object())
        .map(|vs| vs.keys().cloned().collect())
        .unwrap_or_default()
}

fn build_symbol_tables(obj: &serde_json::Map<String, Value>) -> SymbolTables {
    let mut all_systems: std::collections::HashSet<String> = std::collections::HashSet::new();
    let mut per_system: std::collections::HashMap<String, std::collections::HashSet<String>> =
        std::collections::HashMap::new();

    if let Some(models) = obj.get("models").and_then(|v| v.as_object()) {
        for (name, m) in models {
            all_systems.insert(name.clone());
            per_system.insert(name.clone(), variable_keys(m));
        }
    }

    if let Some(rsystems) = obj.get("reaction_systems").and_then(|v| v.as_object()) {
        for (name, rs) in rsystems {
            all_systems.insert(name.clone());
            let mut set: std::collections::HashSet<String> = std::collections::HashSet::new();
            if let Some(rso) = rs.as_object() {
                if let Some(sp) = rso.get("species").and_then(|v| v.as_object()) {
                    set.extend(sp.keys().cloned());
                }
                if let Some(params) = rso.get("parameters").and_then(|v| v.as_object()) {
                    set.extend(params.keys().cloned());
                }
            }
            per_system.insert(name.clone(), set);
        }
    }

    if let Some(loaders) = obj.get("data_loaders").and_then(|v| v.as_object()) {
        for (name, d) in loaders {
            all_systems.insert(name.clone());
            per_system.insert(name.clone(), variable_keys(d));
        }
    }

    // Operators are also addressable by name (scoped refs may point into
    // their config.subsystems) so they count as top-level systems for
    // reference-existence checks, matching Python / Julia.
    if let Some(operators) = obj.get("operators").and_then(|v| v.as_object()) {
        for name in operators.keys() {
            all_systems.insert(name.clone());
            per_system.entry(name.clone()).or_default();
        }
    }

    SymbolTables {
        all_systems,
        per_system,
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_load_minimal_model() {
        let json = r#"
        {
          "esm": "0.1.0",
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

        let result = load(json);
        assert!(result.is_ok());

        let esm_file = result.unwrap();
        assert_eq!(esm_file.esm, "0.1.0");
        assert!(esm_file.models.is_some());
    }

    #[test]
    fn test_load_invalid_json() {
        let json = r#"{ invalid json }"#;
        let result = load(json);
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

        let result = load(json);
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

        let result = load(json);
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
          "esm": "0.1.0",
          "metadata": {
            "name": "test_model"
          }
        }
        "#;

        let result = load(json);
        assert!(result.is_err());
        match result.unwrap_err() {
            EsmError::SchemaValidation(_) => {} // Expected
            _ => panic!("Expected SchemaValidation error"),
        }
    }

    #[test]
    fn test_round_trip() {
        use crate::save;

        let json = r#"
        {
          "esm": "0.1.0",
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
        let esm_file = load(json).expect("Failed to load ESM file");

        // Save it back to JSON
        let serialized_json = save(&esm_file).expect("Failed to save ESM file");

        // Load it again
        let round_trip_file = load(&serialized_json).expect("Failed to load round-trip ESM file");

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
