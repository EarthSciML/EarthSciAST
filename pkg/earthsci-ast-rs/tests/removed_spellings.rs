//! The `aggregate` spelling of `faq` (deprecated at esm 1.1.0, removed at
//! 2.0.0) and `arrayop` (removed at 0.8.0) are rejected by name with
//! `removed_op`, in the root and in a referenced child.
//!
//! Gates `tests/conformance/removed_spellings/`. See CONFORMANCE_SPEC §7 and
//! `docs/content/rfcs/faq-node-rename.md`.

use crate::common;

use earthsci_ast::load_string;

fn conf(name: &str) -> String {
    let path = common::repo_fixture("conformance/removed_spellings").join(name);
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()))
}

#[test]
fn the_canonical_spelling_loads() {
    load_string(&conf("canonical.esm")).expect("the `faq` spelling loads");
}

#[test]
fn the_removed_alias_is_rejected_by_name() {
    let path = common::repo_fixture("invalid/removed_ops/removed_op_aggregate.esm");
    let src = std::fs::read_to_string(&path).expect("read fixture");
    let e = load_string(&src)
        .expect_err("`aggregate` is removed at 2.0.0")
        .to_string();
    assert!(
        e.contains("removed_op") && e.contains("aggregate"),
        "got: {e}"
    );
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
// Ref resolution parses each child file through the same wire boundary as the
// root.

fn conf_path(name: &str) -> std::path::PathBuf {
    common::repo_fixture("conformance/removed_spellings").join(name)
}

#[test]
fn the_removed_alias_inside_a_referenced_child_is_rejected() {
    let err = earthsci_ast::load_path(conf_path("ref_parent_aliased.esm").to_str().unwrap())
        .expect_err("a child's `aggregate` must be rejected");
    assert!(
        err.to_string().contains("removed_op"),
        "rejection must carry `removed_op`, got: {err}"
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
