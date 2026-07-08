//! Rust expression round-trip driver for property-corpus conformance (gt-3fbf).
//!
//! Reads expression JSON fixtures, deserializes each into the `Expr` enum,
//! re-serializes it, and emits a JSON object
//! `{fixture_name: {"ok": bool, "value"|"error": ...}}` to stdout.
//!
//! Usage: `cargo run --example roundtrip_expression -- <fixture.json> ...`

use std::collections::BTreeMap;
use std::env;
use std::fs;
use std::path::Path;

use earthsci_ast::types::Expr;
use serde_json::{Value, json};

fn roundtrip_one(path: &Path) -> Value {
    let raw = match fs::read_to_string(path) {
        Ok(s) => s,
        Err(e) => return json!({"ok": false, "error": format!("read error: {e}")}),
    };
    let parsed: Expr = match serde_json::from_str(&raw) {
        Ok(v) => v,
        Err(e) => return json!({"ok": false, "error": format!("parse error: {e}")}),
    };
    match serde_json::to_value(&parsed) {
        Ok(v) => json!({"ok": true, "value": v}),
        Err(e) => json!({"ok": false, "error": format!("serialize error: {e}")}),
    }
}

fn main() {
    let mut results: BTreeMap<String, Value> = BTreeMap::new();
    for arg in env::args().skip(1) {
        let path = Path::new(&arg);
        let name = path
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or(&arg)
            .to_string();
        results.insert(name, roundtrip_one(path));
    }
    // BTreeMap gives sort_keys-equivalent output.
    println!("{}", serde_json::to_string(&results).unwrap());
}
