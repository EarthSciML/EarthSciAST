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
    display_cases: Vec<ManifestDisplayCase>,
    substitution_cases: Vec<ManifestSubstitutionCase>,
}

#[derive(serde::Deserialize)]
pub(crate) struct ManifestValidationEntry {
    id: String,
    path: String,
}

#[derive(serde::Deserialize)]
pub(crate) struct ManifestDisplayCase {
    id: String,
    // The manifest's `kind` ("formula" | "expression") is deliberately not read
    // here: `Expr` deserializes a bare string as `Expr::Variable`, and the
    // renderers chemical-subscript a variable name exactly as they do a formula,
    // so both kinds take the same path. Bindings whose renderer dispatches on a
    // static type (Julia, Go) do need the tag. Serde ignores the extra key.
    input: serde_json::Value,
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

/// Recover a failed top-level `models.<k>` / `reaction_systems.<k>` `{ref}`
/// mount (esm-spec §4.7 "Two mount forms, one mechanism") as a structured
/// `(code, path)` finding at the entry, `/<block>/<k>`, when the load aborted.
///
/// The library's load error carries the diagnostic code but not the entry it
/// failed at, so the producer re-reads each mount edge against the file's own
/// directory. An edge is an entry whose `ref` is a string and which carries no
/// inline body (`variables` for a model, `species` for a reaction system) —
/// the edge test `ref_loading::inline_toplevel_refs` applies. It is a finding
/// when the referenced file is remote, missing, unreadable or not JSON, has no
/// component of the form's kind, has several and no selector, or has none
/// under the name the selector (`model` / `reaction_system`) gives. Each is
/// `unresolved_subsystem_ref`, the code the library raises at both forms. An
/// edge that resolves contributes nothing; the load failed for another reason.
pub(crate) fn collect_toplevel_mount_errors(
    content: &str,
    file_path: &std::path::Path,
) -> Vec<earthsci_ast::StructuralError> {
    use earthsci_ast::{StructuralError, StructuralErrorCode};
    let mut out = Vec::new();
    let Ok(json) = serde_json::from_str::<serde_json::Value>(content) else {
        return out;
    };
    let base = file_path
        .parent()
        .unwrap_or_else(|| std::path::Path::new("."));

    let forms = [
        ("models", "variables", "model", "model"),
        (
            "reaction_systems",
            "species",
            "reaction_system",
            "reaction system",
        ),
    ];
    for (block, inline_key, selector, noun) in forms {
        let Some(entries) = json.get(block).and_then(|v| v.as_object()) else {
            continue;
        };
        for (name, entry) in entries {
            let Some(ref_str) = entry.get("ref").and_then(|v| v.as_str()) else {
                continue;
            };
            if entry.get(inline_key).is_some() {
                continue;
            }
            let sel = entry.get(selector).and_then(|v| v.as_str());
            let Some(reason) = toplevel_mount_failure(ref_str, base, block, sel, noun) else {
                continue;
            };
            let mut details = serde_json::json!({ "ref": ref_str });
            if let Some(sel) = sel {
                details[selector] = serde_json::json!(sel);
            }
            out.push(StructuralError {
                path: format!("/{block}/{name}"),
                code: StructuralErrorCode::UnresolvedSubsystemRef,
                message: format!("top-level {noun} ref '{ref_str}' at {block}.{name} {reason}"),
                details,
            });
        }
    }
    out
}

/// Why a top-level `{ref}` mount edge of `block`'s form does not resolve, or
/// `None` when it does (see [`collect_toplevel_mount_errors`]).
pub(crate) fn toplevel_mount_failure(
    ref_str: &str,
    base: &std::path::Path,
    block: &str,
    sel: Option<&str>,
    noun: &str,
) -> Option<String> {
    // esm-spec §4.7: an `esm:` ref names the crate's bundled standard library.
    let text = match earthsci_ast::extension::stdlib::resolve(ref_str, base) {
        Some(Ok((_, text))) => Some(text.to_string()),
        Some(Err(why)) => return Some(format!("could not be resolved: {why}")),
        None => {
            if ref_str.starts_with("http://") || ref_str.starts_with("https://") {
                return Some("is a remote URL and could not be resolved".to_string());
            }
            let Ok(canonical) = base.join(ref_str).canonicalize() else {
                return Some("could not be resolved: the file does not exist".to_string());
            };
            fs::read_to_string(&canonical).ok()
        }
    };
    let Some(leaf) = text.and_then(|s| serde_json::from_str::<serde_json::Value>(&s).ok()) else {
        return Some("could not be read or parsed".to_string());
    };
    let systems = leaf.get(block).and_then(|v| v.as_object());
    let mut available: Vec<&str> = systems
        .map(|m| m.keys().map(String::as_str).collect())
        .unwrap_or_default();
    available.sort_unstable();
    let available = available.join(", ");
    match (systems, sel) {
        (None, _) => Some(format!("resolves to a file with no {block} block")),
        (Some(systems), Some(name)) if !systems.contains_key(name) => {
            Some(format!("has no {noun} '{name}' (available: {available})"))
        }
        (Some(_), Some(_)) => None,
        (Some(systems), None) if systems.len() != 1 => Some(format!(
            "resolves to {} {noun}s and has no selector to choose one (available: {available})",
            systems.len()
        )),
        (Some(_), None) => None,
    }
}

/// Recover subsystem-`ref` resolution errors (esm-spec §4.7) as structured
/// `(code, path)` findings when the load aborted before the typed validator
/// could run.
///
/// The §4.7 ref mechanism resolves against the referencing FILE'S OWN directory,
/// and a bad ref fails inside `load` (`ref_loading`) as an opaque string error —
/// so the producer, which owns the file path, reconstructs the finding here.
/// Scans every `models.<M>.subsystems.<N>` and
/// `reaction_systems.<R>.subsystems.<N>` edge for a `{ "ref": <str> }` and
/// classifies it: a ref whose file cannot be found (or is remote) is
/// `unresolved_subsystem_ref`; a ref resolving to a file that does NOT hold
/// exactly one top-level system is `ambiguous_subsystem_ref` (matching
/// `ref_loading::extract_single_system`). A ref that resolves cleanly
/// contributes nothing — the load failed for some other reason. The pointer is
/// the offending subsystem slot, `/<container>/<system>/subsystems/<name>`.
pub(crate) fn collect_subsystem_ref_errors(
    content: &str,
    file_path: &std::path::Path,
) -> Vec<earthsci_ast::StructuralError> {
    use earthsci_ast::{StructuralError, StructuralErrorCode};
    let mut out = Vec::new();
    let Ok(json) = serde_json::from_str::<serde_json::Value>(content) else {
        return out;
    };
    let base = file_path
        .parent()
        .unwrap_or_else(|| std::path::Path::new("."));

    for container in ["models", "reaction_systems"] {
        let Some(systems) = json.get(container).and_then(|v| v.as_object()) else {
            continue;
        };
        for (sys_name, sys_val) in systems {
            let Some(subs) = sys_val.get("subsystems").and_then(|v| v.as_object()) else {
                continue;
            };
            for (sub_name, sub_val) in subs {
                let Some(ref_str) = sub_val.get("ref").and_then(|v| v.as_str()) else {
                    continue;
                };
                let path = format!("/{container}/{sys_name}/subsystems/{sub_name}");
                let details = serde_json::json!({
                    "ref": ref_str,
                    "subsystem": sub_name,
                    "parent_model": sys_name,
                });

                // esm-spec §4.7: an `esm:` ref names the crate's bundled
                // standard library, never a path.
                let bundled = earthsci_ast::extension::stdlib::resolve(ref_str, base);
                if let Some(Err(why)) = &bundled {
                    out.push(StructuralError {
                        path,
                        code: StructuralErrorCode::UnresolvedSubsystemRef,
                        message: format!(
                            "Subsystem reference '{ref_str}' could not be resolved — {why}"
                        ),
                        details,
                    });
                    continue;
                }
                let bundled_text = bundled.and_then(Result::ok).map(|(_, text)| text);

                // Remote refs are not resolvable by the local loader.
                if bundled_text.is_none()
                    && (ref_str.starts_with("http://") || ref_str.starts_with("https://"))
                {
                    out.push(StructuralError {
                        path,
                        code: StructuralErrorCode::UnresolvedSubsystemRef,
                        message: format!(
                            "Subsystem reference '{ref_str}' is a remote URL and could not be resolved"
                        ),
                        details,
                    });
                    continue;
                }

                let text = match bundled_text {
                    Some(text) => Some(text.to_string()),
                    None => {
                        let Ok(canonical) = base.join(ref_str).canonicalize() else {
                            out.push(StructuralError {
                                path,
                                code: StructuralErrorCode::UnresolvedSubsystemRef,
                                message: format!(
                                    "Subsystem reference '{ref_str}' could not be resolved — file does not exist"
                                ),
                                details,
                            });
                            continue;
                        };
                        fs::read_to_string(&canonical).ok()
                    }
                };
                let doc = text.and_then(|s| serde_json::from_str::<serde_json::Value>(&s).ok());
                let Some(doc) = doc else {
                    out.push(StructuralError {
                        path,
                        code: StructuralErrorCode::UnresolvedSubsystemRef,
                        message: format!(
                            "Subsystem reference '{ref_str}' could not be read or parsed"
                        ),
                        details,
                    });
                    continue;
                };

                // "Exactly one top-level system" counts models, reaction systems
                // and data loaders TOGETHER (mirrors `extract_single_system`).
                let count = ["models", "reaction_systems", "data_sources"]
                    .iter()
                    .filter_map(|k| doc.get(*k).and_then(|v| v.as_object()))
                    .map(|m| m.len())
                    .sum::<usize>();
                if count != 1 {
                    out.push(StructuralError {
                        path,
                        code: StructuralErrorCode::AmbiguousSubsystemRef,
                        message: format!(
                            "Subsystem reference '{ref_str}' resolves to a file containing \
                             multiple top-level systems; exactly one is required"
                        ),
                        details,
                    });
                }
            }
        }
    }
    out
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
    let display = conformance_display_results(&manifest);
    let substitution = conformance_substitution_results(&manifest)?;

    let results = json!({
        "language": "rust",
        "validation_results": validation,
        "display_results": display,
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
        "✓ Validation sweep completed ({} files); display {} cases; substitution {} cases",
        manifest.validation_files.len(),
        manifest.display_cases.len(),
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
            // spliced in). `validate_text` is the only exported entry
            // that reports schema errors, so its structural half is
            // discarded — it saw the unresolved document.
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
            // Raw document: the load-phase rejection still yields whatever
            // structured findings the binding is able to enumerate.
            // `validate_text` now itself recovers the typed structural
            // `(code, path)` records on a load rejection (best-effort raw parse
            // + typed `validate()`), so a document rejected at load no longer
            // records `is_valid:false` with an EMPTY `structural_errors`
            // (CONFORMANCE_SPEC §7.1.2). We must therefore NOT re-run
            // `validate()` here, or every such record would be duplicated.
            let raw = validate_text(&content, path.parent());
            let mut structural_errors: Vec<earthsci_ast::StructuralError> =
                raw.structural_errors.clone();
            // A subsystem `ref` that could not be resolved (missing file) or is
            // ambiguous (resolves to a file with != 1 top-level system) aborts
            // the load before any typed pass AND before `validate_text` can
            // deserialize the document, so those findings are recovered here
            // directly from the raw document against the file's own directory.
            structural_errors.extend(collect_subsystem_ref_errors(&content, path));
            // Likewise a top-level `models.<k>` / `reaction_systems.<k>`
            // `{ref}` mount that does not resolve, at the entry's pointer.
            structural_errors.extend(collect_toplevel_mount_errors(&content, path));

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

/// Display phase: render every manifest case in all three formats.
///
/// The producer used to emit a literal `"display_results": {}` here, which the
/// comparator scored as a category with zero divergences — a permanent,
/// structurally unfailable 1.00 that diluted the one real category (audit C2).
pub(crate) fn conformance_display_results(
    manifest: &ConformanceManifest,
) -> std::collections::BTreeMap<String, serde_json::Value> {
    use serde_json::{Value, json};

    let mut display: std::collections::BTreeMap<String, Value> = std::collections::BTreeMap::new();
    for case in &manifest.display_cases {
        let parsed: Result<earthsci_ast::Expr, _> = serde_json::from_value(case.input.clone());
        match parsed {
            Ok(expr) => {
                display.insert(
                    case.id.clone(),
                    json!({
                        "unicode": earthsci_ast::to_unicode(&expr),
                        "latex": earthsci_ast::to_latex(&expr),
                        "ascii": earthsci_ast::to_ascii(&expr),
                    }),
                );
            }
            Err(e) => {
                display.insert(
                    case.id.clone(),
                    json!({
                        "unicode": Value::Null,
                        "latex": Value::Null,
                        "ascii": Value::Null,
                        "errors": { "parse": e.to_string() },
                    }),
                );
            }
        }
    }
    display
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
