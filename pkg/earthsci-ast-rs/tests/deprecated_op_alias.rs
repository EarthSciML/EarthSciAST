//! The `aggregate` -> `faq` deprecated-op-alias contract (esm 1.1.0).
//!
//! Gates `tests/conformance/deprecated_op_alias/` and the `removed_op`
//! rejection of `arrayop`. See CONFORMANCE_SPEC §7 and
//! `docs/content/rfcs/faq-node-rename.md`.

mod common;

use earthsci_ast::{load_string, to_json};

fn conf(name: &str) -> String {
    let path = common::repo_fixture("conformance/deprecated_op_alias").join(name);
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()))
}

/// Every `op` string in a decoded document, depth-first.
fn all_ops(v: &serde_json::Value, out: &mut Vec<String>) {
    match v {
        serde_json::Value::Object(map) => {
            if let Some(op) = map.get("op").and_then(|o| o.as_str()) {
                out.push(op.to_string());
            }
            for child in map.values() {
                all_ops(child, out);
            }
        }
        serde_json::Value::Array(items) => {
            for child in items {
                all_ops(child, out);
            }
        }
        _ => {}
    }
}

#[test]
fn the_alias_never_survives_the_loader() {
    let f = load_string(&conf("aliased.esm")).expect("the deprecated alias must still load");
    let emitted = to_json(&f).expect("emit");
    let doc: serde_json::Value = serde_json::from_str(&emitted).expect("decode emit");
    let mut ops = Vec::new();
    all_ops(&doc, &mut ops);
    assert!(
        !ops.iter().any(|o| o == "aggregate"),
        "the deprecated alias reached emit"
    );
    assert!(ops.iter().any(|o| o == "faq"), "no `faq` node in emit");
}

#[test]
fn emitting_the_alias_document_reproduces_the_canonical_one() {
    // The two fixtures differ ONLY in the op tag, so normalization at the wire
    // boundary must make their emitted forms byte-identical.
    let aliased = to_json(&load_string(&conf("aliased.esm")).expect("load aliased")).expect("emit");
    let canonical =
        to_json(&load_string(&conf("canonical.esm")).expect("load canonical")).expect("emit");
    assert_eq!(aliased, canonical);
}

#[test]
fn arrayop_is_rejected_by_name_not_left_to_the_open_tier() {
    // `arrayop` matches the `op` pattern, so without a by-name rejection it
    // would load as an OPEN rewrite-target op (esm-spec §4.2) and fail only
    // much later as `unlowered_operator`.
    let path = common::repo_fixture("invalid/faq/arrayop_op_removed.esm");
    let src = std::fs::read_to_string(&path).expect("read fixture");
    let err = load_string(&src).expect_err("`arrayop` must be rejected at load");
    assert!(
        err.to_string().contains("removed_op"),
        "rejection must carry the `removed_op` diagnostic, got: {err}"
    );
}

// --- the wire boundary covers REFERENCED documents, not just the root -------
//
// Every other fixture here is a single self-contained document, which is
// exactly why five green binding suites missed the leak: the normalizer ran on
// the root's bytes and ref resolution then parsed child files raw.

fn conf_path(name: &str) -> std::path::PathBuf {
    common::repo_fixture("conformance/deprecated_op_alias").join(name)
}

#[test]
fn the_alias_is_normalized_inside_a_referenced_child() {
    let f = earthsci_ast::load_path(conf_path("ref_parent_aliased.esm").to_str().unwrap())
        .expect("a parent mounting an aliased child must load");
    let emitted = to_json(&f).expect("emit");
    let doc: serde_json::Value = serde_json::from_str(&emitted).expect("decode emit");
    let mut ops = Vec::new();
    all_ops(&doc, &mut ops);
    assert!(
        !ops.iter().any(|o| o == "aggregate"),
        "the alias survived a {{ref}} into emit"
    );
}

#[test]
fn arrayop_inside_a_referenced_child_is_rejected() {
    let err = earthsci_ast::load_path(conf_path("ref_parent_arrayop.esm").to_str().unwrap())
        .expect_err("a child's `arrayop` must be rejected");
    assert!(
        err.to_string().contains("removed_op"),
        "rejection must carry `removed_op`, got: {err}"
    );
}

// --- the esm 1.1.0 version gate --------------------------------------------

fn at_version(name: &str, version: &str) -> std::path::PathBuf {
    let src = std::fs::read_to_string(conf_path(name)).expect("read fixture");
    let mut doc: serde_json::Value = serde_json::from_str(&src).expect("decode fixture");
    doc["esm"] = serde_json::Value::String(version.to_string());
    let dir = std::env::temp_dir().join(format!("faqver-{name}-{version}"));
    std::fs::create_dir_all(&dir).expect("mkdir");
    let out = dir.join("v.esm");
    std::fs::write(&out, serde_json::to_string(&doc).unwrap()).expect("write");
    out
}

#[test]
fn faq_below_v11_is_rejected() {
    // `faq` arrives at esm 1.1.0 — the gate the top-level `solver` block uses.
    let err = earthsci_ast::load_path(at_version("canonical.esm", "1.0.0").to_str().unwrap())
        .expect_err("`faq` below 1.1.0 must be rejected");
    assert!(
        err.to_string().contains("faq_version_too_old"),
        "got: {err}"
    );
}

#[test]
fn the_alias_below_v11_is_legal_and_raises_the_floor() {
    // `aggregate` IS the pre-1.1.0 spelling, so the gate reads the AUTHORED
    // form and must not catch it; normalization raises the version with it.
    let f = earthsci_ast::load_path(at_version("aliased.esm", "1.0.0").to_str().unwrap())
        .expect("the alias below 1.1.0 is legal");
    assert_eq!(f.esm, "1.1.0");
}
