//! The cross-binding canonical-form fixtures, `tests/conformance/canonical/`
//! (discretization RFC §5.4): for each manifest entry, `canonical_json(input)`
//! must equal the fixture's `expected` bytes, or fail with its `expect_error`
//! code. Every binding runs the same set.

use crate::common::repo_fixture;
use serde_json::Value;

fn read_json(rel: &str) -> Value {
    let path = repo_fixture(rel);
    let text = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("cannot read {}: {e}", path.display()));
    serde_json::from_str(&text).unwrap_or_else(|e| panic!("{}: {e}", path.display()))
}

#[test]
fn canonical_fixtures_match() {
    let manifest = read_json("conformance/canonical/manifest.json");
    let entries = manifest["fixtures"].as_array().expect("manifest fixtures");
    assert!(!entries.is_empty(), "manifest has no fixtures");
    let mut failures = Vec::new();
    for entry in entries {
        let id = entry["id"].as_str().expect("fixture id");
        let rel = format!(
            "conformance/canonical/{}",
            entry["path"].as_str().expect("fixture path")
        );
        let fixture = read_json(&rel);
        let expr: earthsci_ast::Expr = match serde_json::from_value(fixture["input"].clone()) {
            Ok(e) => e,
            Err(e) => {
                failures.push(format!("{id}: input does not parse as an expression: {e}"));
                continue;
            }
        };
        let got = earthsci_ast::canonical_json(&expr);
        match (fixture.get("expect_error").and_then(Value::as_str), got) {
            (Some(code), Err(e)) if e.to_string() == code => {}
            (Some(code), other) => failures.push(format!("{id}: want error {code}, got {other:?}")),
            (None, Ok(s)) if Some(s.as_str()) == fixture["expected"].as_str() => {}
            (None, other) => failures.push(format!(
                "{id}:\n   got: {other:?}\n  want: {}",
                fixture["expected"]
            )),
        }
    }
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}
