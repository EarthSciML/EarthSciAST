//! Manifest-driven adapter for `tests/conformance/loader_unit_conversion`.
//!
//! The Rust side of the cross-binding contract in that directory's README:
//! esm-spec §8.5 says the runtime applies a loader variable's `unit_conversion`
//! when producing values in the declared `units`, and the ESIO provider path is
//! where a loader-fed model actually gets its numbers.
//!
//! Driven entirely by `manifest.json` + each fixture's golden: adding a fixture
//! needs no change here.

#![cfg(feature = "esio")]

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

use earthsci_ast::esio_provider::providers_from_document;
use earthsci_ast::prepare::PrepareProvider;
use serde_json::Value;

fn tests_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests")
}

fn read_json(path: &Path) -> Value {
    serde_json::from_str(
        &fs::read_to_string(path).unwrap_or_else(|e| panic!("read {}: {e}", path.display())),
    )
    .unwrap_or_else(|e| panic!("parse {}: {e}", path.display()))
}

/// f64 bit patterns — the comparison the manifest asks for, so `0.0`/`-0.0` and
/// any last-ulp disagreement are visible rather than rounded away.
fn bits(values: &[f64]) -> Vec<u64> {
    values.iter().map(|v| v.to_bits()).collect()
}

fn f64s(v: &Value, what: &str) -> Vec<f64> {
    v.as_array()
        .unwrap_or_else(|| panic!("{what} is not an array"))
        .iter()
        .map(|x| x.as_f64().unwrap_or_else(|| panic!("{what} holds a non-number")))
        .collect()
}

/// One manifest entry, resolved: the golden and the providers the document
/// declares (its placeholder URLs pointed at the committed data files).
struct Case {
    id: String,
    golden: Value,
    providers: Vec<(String, earthsci_ast::esio_provider::EsioProvider)>,
    _tmp: tempfile::TempDir,
}

fn cases() -> Vec<Case> {
    let tests = tests_dir();
    let manifest = read_json(&tests.join("conformance/loader_unit_conversion/manifest.json"));
    let fixtures = manifest["fixtures"]
        .as_array()
        .expect("manifest has a fixtures array");
    assert!(!fixtures.is_empty(), "the manifest lists no fixtures");
    fixtures
        .iter()
        .map(|f| {
            let id = f["id"].as_str().expect("fixture id").to_string();
            let doc = read_json(&tests.join(f["document"].as_str().expect("document path")));
            let golden = read_json(&tests.join(f["golden"].as_str().expect("golden path")));
            let mut overrides: HashMap<String, String> = HashMap::new();
            if let Some(map) = f.get("url_overrides").and_then(Value::as_object) {
                for (loader, rel) in map {
                    let p = tests
                        .join(rel.as_str().expect("url_override path"))
                        .canonicalize()
                        .expect("fixture data file exists");
                    overrides.insert(loader.clone(), format!("file://{}", p.display()));
                }
            }
            let loaders: Option<Vec<&str>> = f
                .get("loaders")
                .and_then(Value::as_array)
                .map(|a| a.iter().filter_map(Value::as_str).collect());
            let tmp = tempfile::tempdir().expect("tmpdir");
            let providers = providers_from_document(
                &doc,
                &tmp.path().join("cache"),
                loaders.as_deref(),
                &overrides,
            )
            .unwrap_or_else(|e| panic!("{id}: providers build from the document: {e}"));
            Case {
                id,
                golden,
                providers,
                _tmp: tmp,
            }
        })
        .collect()
}

fn delivered(case: &mut Case, key: &str) -> Vec<f64> {
    let id = case.id.clone();
    let (_, p) = case
        .providers
        .iter_mut()
        .find(|(k, _)| k == key)
        .unwrap_or_else(|| panic!("{id}: the document declares no provider {key}"));
    p.sample()
        .unwrap_or_else(|e| panic!("{id}: sample {key}: {e}"))
        .iter()
        .copied()
        .collect()
}

/// §8.5: the delivered array is the golden's, on the f64 bits.
#[test]
fn the_declared_conversion_is_applied_bit_for_bit() {
    for mut case in cases() {
        let want_map = case.golden["delivered"]
            .as_object()
            .expect("golden.delivered")
            .clone();
        let records = case.golden["records"].as_u64().expect("golden.records") as usize;
        for (key, want) in &want_map {
            let got = delivered(&mut case, key);
            assert_eq!(got.len(), records, "{}: {key}: wrong record count", case.id);
            let want = f64s(want, key);
            assert_eq!(
                bits(&got),
                bits(&want),
                "{}: {key}: delivered {got:?}, want {want:?}",
                case.id
            );
        }
    }
}

/// The NO-OP property: adding §8.5 support must change nothing for a document
/// that declares no conversion.
#[test]
fn a_variable_declaring_no_conversion_delivers_the_raw_column() {
    for mut case in cases() {
        let keys: Vec<String> = case.golden["no_conversion_declared"]
            .as_array()
            .expect("golden.no_conversion_declared")
            .iter()
            .map(|k| k.as_str().expect("a key").to_string())
            .collect();
        for key in keys {
            let raw = f64s(&case.golden["raw_columns"][&key], &key);
            let got = delivered(&mut case, &key);
            assert_eq!(
                bits(&got),
                bits(&raw),
                "{}: {key} declares no unit_conversion, so it must deliver the raw column",
                case.id
            );
        }
    }
}

/// The fixture is load-bearing: an implementation that applies nothing cannot
/// pass it.
#[test]
fn every_converted_variable_actually_moved() {
    for mut case in cases() {
        let skip: Vec<String> = case.golden["no_conversion_declared"]
            .as_array()
            .expect("golden.no_conversion_declared")
            .iter()
            .map(|k| k.as_str().expect("a key").to_string())
            .collect();
        let keys: Vec<String> = case.golden["delivered"]
            .as_object()
            .expect("golden.delivered")
            .keys()
            .cloned()
            .collect();
        for key in keys {
            if skip.contains(&key) {
                continue;
            }
            let raw = f64s(&case.golden["raw_columns"][&key], &key);
            let got = delivered(&mut case, &key);
            assert_ne!(
                bits(&got),
                bits(&raw),
                "{}: {key} declares a unit_conversion, so it must NOT deliver the raw column",
                case.id
            );
        }
    }
}
