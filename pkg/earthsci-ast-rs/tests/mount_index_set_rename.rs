//! Mount-edge index-set renaming (esm-spec §4.7 "Mount-edge index-set
//! renaming") — the fix for EarthSciML/EarthSciAST#198 item 4.
//!
//! `index_sets` is a DOCUMENT-scoped registry, so a document that mounts a
//! 59-layer atmospheric column and a 4-layer soil column — both of which spell
//! their axis `lev`, because both come from the same one-dimensional column
//! family at different lengths — hits the §4.7 deep-equal-or-error merge and
//! fails with
//! `subsystem_index_set_conflict`. That scoping is load-bearing (`shape`,
//! `{"from"}`, `from_faq`, §11.2 dimensionality, §9.6.1 `where` constraints and
//! §2.1 `coordinates` all resolve against the one registry), so the fix is not
//! to re-scope it but to let the ASSEMBLER say "this mount's `lev` is not that
//! mount's `lev`" at the edge.
//!
//! These pin the three things that matter: the collision still fires without
//! the field, the rename rewrites the mounted component transitively (registry
//! key, variable `shape`, aggregate `{"from"}` range), and a key that names no
//! axis of the RESOLVED mounted document is a loud
//! `subsystem_index_set_rename_unknown_name` rather than a silent no-op.

#![cfg(not(target_arch = "wasm32"))]

use std::path::PathBuf;

use earthsci_ast::load_path;

fn fixture(rel: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests")
        .join(rel)
}

/// The shared fixture: `Host` mounts both columns, renaming the soil axis.
/// Both axes must reach the merged registry at their own sizes.
#[test]
fn mount_rename_lets_two_columns_with_one_axis_name_coexist() {
    let path = fixture("valid/mount_rename_two_columns.esm");
    let file = load_path(&path).unwrap_or_else(|e| panic!("{} does not load: {e}", path.display()));
    let value = serde_json::to_value(&file).expect("document renders as JSON");
    let sets = value
        .get("index_sets")
        .and_then(|v| v.as_object())
        .expect("the merged registry survives the mount");

    assert_eq!(
        sets.get("lev")
            .and_then(|s| s.get("size"))
            .and_then(|s| s.as_i64()),
        Some(59),
        "the un-renamed atmospheric mount keeps `lev` at its own size: {sets:?}"
    );
    assert_eq!(
        sets.get("soil_lev")
            .and_then(|s| s.get("size"))
            .and_then(|s| s.as_i64()),
        Some(4),
        "the renamed soil mount lands as `soil_lev`: {sets:?}"
    );
}

/// Every `shape` list in a rendered document, paired with the variable name it
/// hangs off, so the assertion below does not depend on where this binding
/// stores a mounted component (Rust namespaces the mount into the parent model
/// rather than keeping a `subsystems` map on the typed `EsmFile`).
fn shapes_by_variable(value: &serde_json::Value, out: &mut Vec<(String, Vec<String>)>) {
    match value {
        serde_json::Value::Object(obj) => {
            for (name, decl) in obj {
                if let Some(shape) = decl.get("shape").and_then(|s| s.as_array()) {
                    let axes: Vec<String> = shape
                        .iter()
                        .filter_map(|e| e.as_str().map(String::from))
                        .collect();
                    if !axes.is_empty() {
                        out.push((name.clone(), axes));
                    }
                }
                shapes_by_variable(decl, out);
            }
        }
        serde_json::Value::Array(arr) => {
            for v in arr {
                shapes_by_variable(v, out);
            }
        }
        _ => {}
    }
}

/// Transitivity (esm-spec §4.7): the rename rewrites the mounted component's
/// own references, not just the registry key — a `shape` list that still said
/// `lev` would resolve against the 59-layer axis and allocate 59 soil layers.
#[test]
fn mount_rename_rewrites_shape_and_range_inside_the_mounted_component() {
    let path = fixture("valid/mount_rename_two_columns.esm");
    let file = load_path(&path).unwrap_or_else(|e| panic!("{} does not load: {e}", path.display()));
    let value = serde_json::to_value(&file).expect("document renders as JSON");

    let mut shapes = Vec::new();
    shapes_by_variable(&value, &mut shapes);

    let soil = shapes
        .iter()
        .find(|(name, _)| name.ends_with("Tsoil"))
        .unwrap_or_else(|| panic!("the soil unknown survives the mount: {shapes:?}"));
    assert_eq!(
        soil.1,
        vec!["soil_lev".to_string()],
        "the renamed soil axis reaches the mounted component's shape: {shapes:?}"
    );

    let atm = shapes
        .iter()
        .find(|(name, _)| name.ends_with('T') && !name.ends_with("Tsoil"))
        .unwrap_or_else(|| panic!("the atmospheric unknown survives the mount: {shapes:?}"));
    assert_eq!(
        atm.1,
        vec!["lev".to_string()],
        "the un-renamed atmospheric mount is untouched: {shapes:?}"
    );

    // The soil aggregate's `{"from"}` range follows the axis too, so the
    // renamed axis appears at least twice outside the registry.
    let rendered = value.to_string();
    assert!(
        rendered.matches("soil_lev").count() >= 3,
        "registry key + shape + range all spell the renamed axis: {rendered}"
    );
}

/// A rename key that names nothing the RESOLVED mounted document declares is a
/// typo, and renames never invent names (the §9.7.7 rule at a mount edge).
#[test]
fn mount_rename_unknown_index_set_is_a_loud_load_error() {
    let path = fixture("invalid/template_imports/mount_rename_unknown_index_set.esm");
    let err = load_path(&path).expect_err("a misspelled rename key must not load");
    let text = format!("{err}");
    assert!(
        text.contains("subsystem_index_set_rename_unknown_name") || text.contains("celsl"),
        "the diagnostic names the offending key: {text}"
    );
}
