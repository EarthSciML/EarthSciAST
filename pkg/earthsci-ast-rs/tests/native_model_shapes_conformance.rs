//! The native-model shapes on the BUILD-TIME path
//! (`tests/conformance/native_model_shapes/`).
//!
//! The tier's own manifest is gated by the inline-test runner, which builds
//! each document the way `esm_problem` does by default. A document that
//! ingests data — every moves fixture, every isrm document — takes another
//! route: its rules are evaluated by the build pipeline. These tests run the
//! same shapes on that route, under `interpreter` and `native`, and hold
//! native to the interpreter bit for bit:
//!
//!   * every document of `ingest/manifest.json`, with its committed parquet
//!     tables ingested through the document's own `data_sources`;
//!   * every document of the tier's manifest, with the pipeline switched on by
//!     a provider factory that serves nothing.

#![cfg(not(target_arch = "wasm32"))]

use std::fs;
use std::path::{Path, PathBuf};

use earthsci_ast::{
    AssertionResult, BuildProviderFactory, Compiler, InlineTestOptions, SolveOptions,
    run_inline_tests_with_options,
};
use serde_json::Value;

mod common;

fn tier_dir() -> PathBuf {
    common::repo_fixture("conformance/native_model_shapes")
}

fn read_json(path: &Path) -> Value {
    serde_json::from_str(
        &fs::read_to_string(path).unwrap_or_else(|e| panic!("read {}: {e}", path.display())),
    )
    .unwrap_or_else(|e| panic!("parse {}: {e}", path.display()))
}

fn run(
    file: &earthsci_ast::EsmFile,
    model: &str,
    base_dir: &Path,
    compiler: Compiler,
    providers: &BuildProviderFactory<'_>,
) -> Vec<AssertionResult> {
    let opts = InlineTestOptions {
        model_name: Some(model.to_string()),
        solve: SolveOptions {
            alg: earthsci_ast::Alg::Erk,
            reltol: Some(1e-12),
            abstol: Some(1e-14),
            ..Default::default()
        },
        base_dir: Some(base_dir.to_path_buf()),
        compiler: Some(compiler),
        ..Default::default()
    };
    run_inline_tests_with_options(file, &opts, Some(providers))
}

/// Both compilers pass every assertion, and native's value is the
/// interpreter's to the bit. Returns the failures, one line each.
fn check(id: &str, interp: &[AssertionResult], native: &[AssertionResult]) -> Vec<String> {
    let mut bad = Vec::new();
    if interp.is_empty() {
        bad.push(format!("{id}: the document produced no assertions"));
    }
    if interp.len() != native.len() {
        bad.push(format!(
            "{id}: interpreter answered {} assertions, native {}",
            interp.len(),
            native.len()
        ));
        return bad;
    }
    for (i, n) in interp.iter().zip(native) {
        let at = format!("{id} {}#{} ({})", i.test_id, i.assertion_idx, i.variable);
        if !i.passed {
            bad.push(format!("{at}: interpreter failed: {}", i.message));
        }
        if !n.passed {
            bad.push(format!("{at}: native failed: {}", n.message));
        }
        if i.passed && n.passed && i.actual.map(f64::to_bits) != n.actual.map(f64::to_bits) {
            bad.push(format!(
                "{at}: native {:?} differs from the interpreter {:?}",
                n.actual, i.actual
            ));
        }
    }
    bad
}

/// Every tier document, with the build pipeline on.
#[test]
fn tier_shapes_agree_on_the_build_pipeline() {
    let dir = tier_dir();
    let manifest = read_json(&dir.join("manifest.json"));
    let fixtures = manifest["fixtures"].as_array().expect("fixtures");
    assert!(!fixtures.is_empty());
    // No data sources: an empty provider set still routes the build through
    // the pipeline, which is the route an ingesting document's rules take.
    let none: &BuildProviderFactory<'_> = &|| Ok(Vec::new());
    let mut bad = Vec::new();
    for fx in fixtures {
        let id = fx["id"].as_str().expect("id");
        let path = dir.join(fx["path"].as_str().expect("path"));
        let file = common::load_repo_fixture(&format!(
            "conformance/native_model_shapes/{}",
            fx["path"].as_str().expect("path")
        ));
        let model = fx["model"].as_str().expect("model");
        let base = path.parent().expect("parent");
        let interp = run(&file, model, base, Compiler::Interpreter, none);
        let native = run(&file, model, base, Compiler::Native, none);
        bad.extend(check(id, &interp, &native));
    }
    assert!(bad.is_empty(), "{}", bad.join("\n"));
}

/// Every ingest document, with its tables read through its `data_sources`.
#[cfg(feature = "esio")]
#[test]
fn ingested_shapes_agree() {
    use std::collections::HashMap;

    use earthsci_ast::PrepareProvider;
    use earthsci_ast::esio_provider::providers_from_document;

    let dir = tier_dir().join("ingest");
    let manifest = read_json(&dir.join("manifest.json"));
    let fixtures = manifest["fixtures"].as_array().expect("fixtures");
    assert!(!fixtures.is_empty());
    let mut bad = Vec::new();
    for fx in fixtures {
        let id = fx["id"].as_str().expect("id");
        let mut doc = read_json(&dir.join(fx["path"].as_str().expect("path")));
        let mut overrides: HashMap<String, String> = HashMap::new();
        for (src, rel) in fx["url_overrides"].as_object().expect("url_overrides") {
            let p = dir
                .join(rel.as_str().expect("override path"))
                .canonicalize()
                .expect("the table is committed");
            overrides.insert(src.clone(), format!("file://{}", p.display()));
        }
        let cache = tempfile::tempdir().expect("tmpdir");
        // esm-spec §8.9.4: a source measures its own row count and closes the
        // metaparameter its `extent` names BEFORE the document is loaded.
        let provs = providers_from_document(&doc, &cache.path().join("cache"), None, &overrides)
            .unwrap_or_else(|e| panic!("{id}: providers: {e}"));
        for (key, mut p) in provs {
            if let Some(mp) = p.extent_metaparameter() {
                let n = p
                    .sample()
                    .unwrap_or_else(|e| panic!("{id}: sample {key}: {e}"))
                    .shape()[0];
                doc["metaparameters"][&mp]["default"] = Value::from(n as i64);
            }
        }
        let file = earthsci_ast::load_string(&doc.to_string())
            .unwrap_or_else(|e| panic!("{id}: load: {e}"));
        let factory = |doc: Value, cache: PathBuf, overrides: HashMap<String, String>| {
            move || {
                providers_from_document(&doc, &cache, None, &overrides)
                    .map(|v| {
                        v.into_iter()
                            .map(|(k, p)| (k, Box::new(p) as Box<dyn PrepareProvider>))
                            .collect()
                    })
                    .map_err(|e| e.to_string())
            }
        };
        let make = factory(doc.clone(), cache.path().join("cache"), overrides);
        let model = fx["model"].as_str().expect("model");
        let interp = run(&file, model, &dir, Compiler::Interpreter, &make);
        let native = run(&file, model, &dir, Compiler::Native, &make);
        bad.extend(check(id, &interp, &native));
    }
    assert!(bad.is_empty(), "{}", bad.join("\n"));
}
