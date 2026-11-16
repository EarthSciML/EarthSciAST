//! `esm conformance-test`: the Rust producer of the cross-language
//! conformance results.

use earthsci_ast::{validate, validate_text};
use std::collections::HashMap;
use std::fs;

// === Cross-language conformance PRODUCER ====================================
//
// Reads the shared CORPUS MANIFEST (`scripts/conformance_corpus.py`) and emits a
// record for every entry in it. The producer does NOT enumerate the corpus
// itself: each producer used to walk `tests/valid` / `tests/invalid`
// NON-recursively and all four skipped the same 69 fixtures — the entire
// `faq` and `template_imports` corpora — plus `lib/**`, which nothing swept
// at all (audit 2026-07-14, F5; CONFORMANCE_SPEC §2.2.1).
//
// Every validation entry runs the full **load → resolve → validate** pipeline.
// `load_path` resolves §4.7 subsystem refs against the file's own directory; the
// producer used to call `validate_text(&content)` on the file's TEXT, which
// takes no base path, so no `{ref}` could ever resolve here.
//
// See `scripts/run-python-conformance.py` for the emitted wire shape; every
// producer emits the same one.

#[derive(serde::Deserialize)]
pub(crate) struct ConformanceManifest {
    validation_files: Vec<ManifestValidationEntry>,
    substitution_cases: Vec<ManifestSubstitutionCase>,
}

#[derive(serde::Deserialize)]
pub(crate) struct ManifestValidationEntry {
    id: String,
    path: String,
}

#[derive(serde::Deserialize)]
pub(crate) struct ManifestSubstitutionCase {
    id: String,
    input: serde_json::Value,
    bindings: std::collections::BTreeMap<String, serde_json::Value>,
}

/// Walk up from the current directory to the repo root, so the manifest's
/// repo-relative paths resolve no matter where the binary is invoked from.
pub(crate) fn find_repo_root() -> Option<std::path::PathBuf> {
    let mut dir = std::env::current_dir().ok()?;
    loop {
        if dir.join("tests").join("valid").is_dir() {
            return Some(dir);
        }
        if !dir.pop() {
            return None;
        }
    }
}

/// The manifest path is passed by the harness; there is no fallback sweep. A
/// producer that invents its own corpus when the manifest is missing is a
/// producer that can silently under-report coverage. Fail instead.
pub(crate) fn locate_manifest(
    out_dir: &std::path::Path,
    explicit: Option<&std::path::Path>,
) -> Result<std::path::PathBuf, Box<dyn std::error::Error>> {
    let candidate = match explicit {
        Some(p) => p.to_path_buf(),
        None => match std::env::var("ESM_CONFORMANCE_MANIFEST") {
            Ok(v) if !v.is_empty() => std::path::PathBuf::from(v),
            _ => out_dir
                .parent()
                .unwrap_or(std::path::Path::new("."))
                .join("corpus_manifest.json"),
        },
    };
    if !candidate.is_file() {
        return Err(format!(
            "Corpus manifest not found: {}\nGenerate it with: python3 scripts/conformance_corpus.py --output <path>",
            candidate.display()
        )
        .into());
    }
    Ok(candidate)
}

pub(crate) fn schema_error_json(e: &earthsci_ast::SchemaError) -> serde_json::Value {
    serde_json::json!({
        "path": e.path,
        "message": e.message,
        "keyword": e.keyword,
        "code": e.keyword,
        "details": {},
    })
}

pub(crate) fn structural_error_json(e: &earthsci_ast::StructuralError) -> serde_json::Value {
    // `code` is an enum whose Display is the snake_case spec spelling
    // (`undefined_variable`, …) — the same spelling `expected_errors.json` pins.
    let code = e.code.to_string();
    serde_json::json!({
        "path": e.path,
        "message": e.message,
        "code": code,
        "keyword": code,
        "details": e.details,
    })
}

pub(crate) fn run_conformance_test(
    out_dir: &std::path::Path,
    manifest_path: Option<&std::path::Path>,
) -> Result<(), Box<dyn std::error::Error>> {
    use serde_json::json;

    fs::create_dir_all(out_dir)?;

    let manifest_file = locate_manifest(out_dir, manifest_path)?;
    let manifest: ConformanceManifest = serde_json::from_str(&fs::read_to_string(&manifest_file)?)?;
    let repo_root = find_repo_root()
        .ok_or("Could not locate repo root by walking up from the current directory")?;

    let validation = conformance_validation_sweep(&manifest, &repo_root);
    let substitution = conformance_substitution_results(&manifest)?;

    let results = json!({
        "language": "rust",
        "validation_results": validation,
        "substitution_results": substitution,
        "errors": Vec::<String>::new(),
    });

    let results_file = out_dir.join("results.json");
    fs::write(&results_file, serde_json::to_string_pretty(&results)?)?;
    println!(
        "Rust conformance results written to: {}",
        results_file.display()
    );
    println!(
        "✓ Validation sweep completed ({} files); substitution {} cases",
        manifest.validation_files.len(),
        manifest.substitution_cases.len()
    );

    Ok(())
}

/// Validation phase: load -> resolve -> validate, one record per manifest file.
pub(crate) fn conformance_validation_sweep(
    manifest: &ConformanceManifest,
    repo_root: &std::path::Path,
) -> std::collections::BTreeMap<String, serde_json::Value> {
    let mut validation: std::collections::BTreeMap<String, serde_json::Value> =
        std::collections::BTreeMap::new();
    for entry in &manifest.validation_files {
        let path = repo_root.join(&entry.path);
        validation.insert(
            entry.id.clone(),
            serde_json::Value::Object(conformance_validation_record(&path)),
        );
    }
    validation
}

/// One validation file's conformance record: schema/structural findings, the
/// answering phase, and the accept/reject verdict.
pub(crate) fn conformance_validation_record(
    path: &std::path::Path,
) -> serde_json::Map<String, serde_json::Value> {
    use serde_json::json;

    let mut record = serde_json::Map::new();
    record.insert("schema_errors".into(), json!([]));
    record.insert("structural_errors".into(), json!([]));

    let content = fs::read_to_string(path).unwrap_or_default();

    // load_path anchors §4.7 subsystem refs and §9.7 template imports at the
    // file's own directory: this IS the resolve phase.
    let loaded = earthsci_ast::load_path(path);
    let resolve_ok = loaded.is_ok();
    record.insert("resolve_ok".into(), json!(resolve_ok));

    match &loaded {
        Ok(esm_file) => {
            // Schema validation judges the document AS WRITTEN, so it runs
            // on the raw text; structural validation judges the RESOLVED
            // form, so it runs on the loaded file (which has its §4.7 refs
            // spliced in). Only the schema half of `validate_text` is read.
            let schema = validate_text(&content, path.parent());
            let structural = validate(esm_file);
            record.insert(
                "schema_errors".into(),
                json!(
                    schema
                        .schema_errors
                        .iter()
                        .map(schema_error_json)
                        .collect::<Vec<_>>()
                ),
            );
            record.insert(
                "structural_errors".into(),
                json!(
                    structural
                        .structural_errors
                        .iter()
                        .map(structural_error_json)
                        .collect::<Vec<_>>()
                ),
            );
            record.insert(
                "is_valid".into(),
                json!(schema.schema_errors.is_empty() && structural.structural_errors.is_empty()),
            );
            record.insert("phase".into(), json!("validate"));
        }
        Err(e) => {
            record.insert("error".into(), json!(e.to_string()));
            record.insert("error_type".into(), json!("LoadError"));
            record.insert("phase".into(), json!("load"));
            record.insert("is_valid".into(), json!(false));
            // The load-phase rejection still yields its structured findings:
            // `validate_text` reports the refusal's own findings (the mount
            // edges that do not resolve, `earthsci_ast::mount_edge_errors`)
            // with the schema errors of the document as written — what
            // `esm validate` prints for the same file.
            let raw = validate_text(&content, path.parent());
            let structural_errors = raw.structural_errors;

            record.insert(
                "schema_errors".into(),
                json!(
                    raw.schema_errors
                        .iter()
                        .map(schema_error_json)
                        .collect::<Vec<_>>()
                ),
            );
            record.insert(
                "structural_errors".into(),
                json!(
                    structural_errors
                        .iter()
                        .map(structural_error_json)
                        .collect::<Vec<_>>()
                ),
            );
        }
    }

    // The verdict is "did this binding accept the document", regardless of
    // WHICH phase answered. A rejection at resolve is still a rejection.
    let is_valid = record
        .get("is_valid")
        .and_then(|v| v.as_bool())
        .unwrap_or(false)
        && resolve_ok;
    record.insert("is_valid".into(), json!(is_valid));
    record.insert(
        "outcome".into(),
        json!(if is_valid { "valid" } else { "invalid" }),
    );
    record
}

/// Substitution phase.
pub(crate) fn conformance_substitution_results(
    manifest: &ConformanceManifest,
) -> Result<std::collections::BTreeMap<String, serde_json::Value>, Box<dyn std::error::Error>> {
    use serde_json::{Value, json};

    let mut substitution: std::collections::BTreeMap<String, Value> =
        std::collections::BTreeMap::new();
    for case in &manifest.substitution_cases {
        let expr: Result<earthsci_ast::Expr, _> = serde_json::from_value(case.input.clone());
        let mut bindings: HashMap<String, earthsci_ast::Expr> = HashMap::new();
        let mut binding_err: Option<String> = None;
        for (name, value) in &case.bindings {
            match serde_json::from_value::<earthsci_ast::Expr>(value.clone()) {
                Ok(e) => {
                    bindings.insert(name.clone(), e);
                }
                Err(e) => binding_err = Some(e.to_string()),
            }
        }
        match (expr, binding_err) {
            (Ok(e), None) => {
                let result = earthsci_ast::substitute(&e, &bindings);
                substitution.insert(
                    case.id.clone(),
                    json!({ "result": serde_json::to_value(&result)? }),
                );
            }
            (Err(e), _) => {
                substitution.insert(
                    case.id.clone(),
                    json!({ "result": Value::Null, "error": e.to_string() }),
                );
            }
            (_, Some(e)) => {
                substitution.insert(
                    case.id.clone(),
                    json!({ "result": Value::Null, "error": e }),
                );
            }
        }
    }
    Ok(substitution)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `(code, path)` of every structural finding in a validation record.
    fn structural_findings(
        record: &serde_json::Map<String, serde_json::Value>,
    ) -> Vec<(String, String)> {
        record["structural_errors"]
            .as_array()
            .expect("structural_errors")
            .iter()
            .map(|e| {
                (
                    e["code"].as_str().unwrap_or_default().to_string(),
                    e["path"].as_str().unwrap_or_default().to_string(),
                )
            })
            .collect()
    }

    /// A top-level `reaction_systems.<k>` `{ref}` mount that fails at load is
    /// reported as `unresolved_subsystem_ref` at `/reaction_systems/<k>`
    /// (esm-spec §4.7), not only as a load-error string.
    #[test]
    fn a_failed_toplevel_reaction_system_mount_is_a_structural_finding() {
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../../tests/conformance/toplevel_reaction_system_ref");
        for fixture in ["ambiguous.esm", "unknown_selector.esm", "missing_file.esm"] {
            let record = conformance_validation_record(&dir.join(fixture));
            assert_eq!(record["is_valid"], serde_json::json!(false), "{fixture}");
            assert_eq!(
                structural_findings(&record),
                vec![(
                    "unresolved_subsystem_ref".to_string(),
                    "/reaction_systems/Chem".to_string()
                )],
                "{fixture}"
            );
        }
        // A mount that resolves contributes no finding.
        let record = conformance_validation_record(&dir.join("basic.esm"));
        assert_eq!(record["is_valid"], serde_json::json!(true));
        assert!(structural_findings(&record).is_empty());
    }

    /// The `models.<k>` form is treated the same way, with the same code, and
    /// a leaf with no component of the form's kind is a finding at either form.
    #[test]
    fn a_failed_toplevel_model_mount_is_a_structural_finding() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let leaf = serde_json::json!({
            "esm": "2.0.0",
            "metadata": {"name": "leaf"},
            "models": {
                "A": {"variables": {}, "equations": []},
                "B": {"variables": {}, "equations": []},
            },
        });
        std::fs::write(tmp.path().join("leaf.esm"), leaf.to_string()).expect("write leaf");
        let cases = [
            ("models", serde_json::json!({"ref": "./missing.esm"})),
            ("models", serde_json::json!({"ref": "./leaf.esm"})),
            (
                "models",
                serde_json::json!({"ref": "./leaf.esm", "model": "C"}),
            ),
            ("reaction_systems", serde_json::json!({"ref": "./leaf.esm"})),
        ];
        for (block, entry) in cases {
            let doc = serde_json::json!({
                "esm": "2.0.0",
                "metadata": {"name": "mounter"},
                block: {"K": entry},
            });
            let path = tmp.path().join("mounter.esm");
            std::fs::write(&path, doc.to_string()).expect("write mounter");
            let record = conformance_validation_record(&path);
            assert_eq!(
                structural_findings(&record),
                vec![(
                    "unresolved_subsystem_ref".to_string(),
                    format!("/{block}/K")
                )],
                "{block}: {entry}"
            );
        }
    }
}
