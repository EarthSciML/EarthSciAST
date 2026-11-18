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

// --- every fixture under tests/invalid/removed_ops/ ------------------------

/// Every `tests/invalid/removed_ops/*.esm` fixture is refused at load with
/// `removed_op`, naming its op. The three ops esm 3.0.0 removed (`grad`, `div`,
/// `laplacian`) are refused even though their fixtures declare esm 2.3.0, and
/// their message points at spatial `D` and MIGRATION.md, never at the 2.0.0
/// codemod.
#[test]
fn every_removed_ops_fixture_is_refused_with_removed_op() {
    let dir = common::repo_fixture("invalid/removed_ops");
    let mut seen_v3 = Vec::new();
    let mut count = 0usize;
    for entry in std::fs::read_dir(&dir).expect("read removed_ops dir") {
        let path = entry.expect("dir entry").path();
        if path.extension().and_then(|e| e.to_str()) != Some("esm") {
            continue;
        }
        let stem = path.file_stem().unwrap().to_str().unwrap().to_string();
        let op = stem
            .strip_prefix("removed_op_")
            .unwrap_or(&stem)
            .to_string();
        let src = std::fs::read_to_string(&path).expect("read fixture");
        let e = load_string(&src)
            .expect_err(&format!("{stem} must be refused"))
            .to_string();
        assert!(e.contains("removed_op"), "{stem}: {e}");
        if op != "function_tables" {
            assert!(
                e.contains(&format!("\"{op}\"")),
                "{stem} must name `{op}`: {e}"
            );
        }
        if ["grad", "div", "laplacian"].contains(&op.as_str()) {
            let doc: serde_json::Value = serde_json::from_str(&src).expect("fixture is JSON");
            assert_eq!(doc["esm"], "2.3.0", "{stem} declares 2.3.0");
            assert!(e.contains("esm 3.0.0"), "{stem}: {e}");
            assert!(e.contains("MIGRATION.md"), "{stem}: {e}");
            assert!(!e.contains("earthsci_ast.migrate"), "{stem}: {e}");
            seen_v3.push(op);
        }
        count += 1;
    }
    seen_v3.sort();
    assert_eq!(seen_v3, ["div", "grad", "laplacian"]);
    assert!(
        count >= 13,
        "expected the full removed_ops corpus, saw {count}"
    );
}
