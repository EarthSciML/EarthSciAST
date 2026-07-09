//! Metaparameter-EXPRESSION binding values at import / subsystem edges
//! (esm-spec §9.7.6).
//!
//! Mirrors the Python reference suite
//! (`pkg/earthsci-ast-py/tests/test_metaparam_expr_bindings.py`). Before this
//! feature both an `expression_template_imports[k].bindings` value and a §4.7
//! subsystem-ref `bindings` value accepted only integer literals, so a child
//! metaparameter could be unified with a parent one by *rename* (name→name)
//! but never *derived* as an arithmetic combination (`NTGT = NX*NY`). This
//! relaxes the binding VALUE to a metaparameter expression (integer literal,
//! name, or `{op: +|-|*|/, args}`) whose free names resolve in the importing
//! document's metaparameter scope:
//!
//! * **import edge** — the value is carried symbolically into the child and
//!   folds when the importing document closes (the importer's names are not yet
//!   closed at edge time, innermost-first);
//! * **subsystem edge** — the referenced document is resolved to concrete
//!   integers at the mount, so the value folds immediately against the mounting
//!   document's already-closed metaparameter environment.
//!
//! The helper-unit level (`eval_meta_expr` / `require_meta_expr` folding +
//! diagnostics) is covered by in-crate unit tests in `src/template_imports.rs`;
//! this file drives the two edge-folding regimes end to end.
//!
//! Rust/Python parity note: the Python §3 tests author the mount as a
//! TOP-LEVEL model-ref (`models.Regrid = {ref, bindings}`). The Rust loader
//! resolves a top-level model-ref via a distinct MOUNT-EDGE inliner that
//! defers grid resolution to the loader API and does not close the leaf's
//! metaparameters at the mount, so the faithful mirror of Python's
//! `_subsystem_ref_bindings` / `_load_ref_data` is the §4.7 SUBSYSTEM form
//! (`models.<M>.subsystems.<k> = {ref, bindings}`), exercised below.

use earthsci_ast::load_path_with_options;
use earthsci_ast::template_imports::resolve_template_machinery;
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::path::Path;

fn write(dir: &Path, name: &str, doc: &Value) {
    std::fs::write(dir.join(name), serde_json::to_string(doc).unwrap()).unwrap();
}

fn meta(pairs: &[(&str, i64)]) -> BTreeMap<String, i64> {
    pairs.iter().map(|(k, v)| (k.to_string(), *v)).collect()
}

// --------------------------------------------------------------------------
// Import edge: GX = NX*NY carried symbolically, folds at the doc close
// --------------------------------------------------------------------------

fn lib_grid() -> Value {
    json!({
        "esm": "0.8.0",
        "metadata": {"name": "lib_grid"},
        "metaparameters": {"GX": {"type": "integer", "default": 2}},
        "index_sets": {"cells": {"kind": "interval", "size": "GX"}},
        "expression_templates": {
            "one": {"params": [], "body": {"op": "const", "value": 1, "args": []}}
        }
    })
}

fn model_importing(binding: Value) -> Value {
    json!({
        "esm": "0.8.0",
        "metadata": {"name": "model_import"},
        "metaparameters": {
            "NX": {"type": "integer", "default": 3},
            "NY": {"type": "integer", "default": 4}
        },
        "models": {
            "M": {
                "expression_template_imports": [
                    {"ref": "./lib_grid.esm", "bindings": {"GX": binding}}
                ],
                "variables": {"a": {"type": "parameter", "shape": ["cells"], "default": 0.0}},
                "equations": []
            }
        }
    })
}

#[test]
fn import_edge_product_binding_folds_at_close() {
    let tmp = tempfile::TempDir::new().unwrap();
    let d = tmp.path();
    write(d, "lib_grid.esm", &lib_grid());

    // Explicit loader-API bindings (NX=3, NY=4): GX = NX*NY folds to 12 at the
    // importing document's close.
    let root = model_importing(json!({"op": "*", "args": ["NX", "NY"]}));
    let out = resolve_template_machinery(&root, d, &meta(&[("NX", 3), ("NY", 4)]))
        .expect("resolve")
        .expect("has machinery");
    assert_eq!(out["index_sets"]["cells"]["size"], json!(12));

    // Via metaparameter defaults (3 * 4).
    let root2 = model_importing(json!({"op": "*", "args": ["NX", "NY"]}));
    let out2 = resolve_template_machinery(&root2, d, &BTreeMap::new())
        .expect("resolve")
        .expect("has machinery");
    assert_eq!(out2["index_sets"]["cells"]["size"], json!(12));
}

// --------------------------------------------------------------------------
// Subsystem edge: NTGT = NX*NY folds at the mount
// --------------------------------------------------------------------------

fn child_regrid() -> Value {
    json!({
        "esm": "0.8.0",
        "metadata": {"name": "child_regrid"},
        "metaparameters": {
            "NX": {"type": "integer", "default": 2},
            "NY": {"type": "integer", "default": 2},
            "NTGT": {"type": "integer", "default": 4}
        },
        "index_sets": {
            "tgt_cells": {"kind": "interval", "size": "NTGT"},
            "gx": {"kind": "interval", "size": "NX"},
            "gy": {"kind": "interval", "size": "NY"}
        },
        "models": {
            "Regrid": {
                "variables": {
                    "field": {"type": "parameter", "shape": ["tgt_cells"], "default": 0.0},
                    "grid": {"type": "parameter", "shape": ["gx", "gy"], "default": 0.0}
                },
                "equations": []
            }
        }
    })
}

/// A §4.7 subsystem-ref mount of `child_regrid.esm` under `models.Sweep`,
/// closing the child's metaparameters with this edge's `bindings`.
fn parent_mount(bindings: Value) -> Value {
    json!({
        "esm": "0.8.0",
        "metadata": {"name": "parent_mount"},
        "metaparameters": {
            "NX": {"type": "integer", "default": 18},
            "NY": {"type": "integer", "default": 20}
        },
        "models": {
            "Sweep": {
                "variables": {},
                "equations": [],
                "subsystems": {
                    "Regrid": {"ref": "./child_regrid.esm", "bindings": bindings}
                }
            }
        }
    })
}

fn sizes(esm: &earthsci_ast::EsmFile) -> BTreeMap<String, i64> {
    esm.index_sets
        .as_ref()
        .expect("index_sets")
        .iter()
        .filter_map(|(n, s)| s.size.map(|v| (n.clone(), v)))
        .collect()
}

#[test]
fn mount_edge_product_binding_folds_to_concrete() {
    let tmp = tempfile::TempDir::new().unwrap();
    let d = tmp.path();
    write(d, "child_regrid.esm", &child_regrid());
    write(
        d,
        "parent_mount.esm",
        &parent_mount(json!({"NX": "NX", "NY": "NY", "NTGT": {"op": "*", "args": ["NX", "NY"]}})),
    );

    let esm = load_path_with_options(d.join("parent_mount.esm"), &meta(&[("NX", 18), ("NY", 20)]))
        .expect("load");
    let s = sizes(&esm);
    assert_eq!(s["tgt_cells"], 360); // NX*NY, derived — not a hand-supplied literal
    assert_eq!(s["gx"], 18);
    assert_eq!(s["gy"], 20);
}

#[test]
fn mount_edge_folds_against_parent_defaults() {
    let tmp = tempfile::TempDir::new().unwrap();
    let d = tmp.path();
    write(d, "child_regrid.esm", &child_regrid());
    write(
        d,
        "parent_mount.esm",
        &parent_mount(json!({"NX": "NX", "NY": "NY", "NTGT": {"op": "*", "args": ["NX", "NY"]}})),
    );

    // No API bindings -> parent defaults NX=18, NY=20.
    let esm = load_path_with_options(d.join("parent_mount.esm"), &BTreeMap::new()).expect("load");
    assert_eq!(sizes(&esm)["tgt_cells"], 360);
}

#[test]
fn mount_edge_plain_integer_bindings_regression() {
    let tmp = tempfile::TempDir::new().unwrap();
    let d = tmp.path();
    write(d, "child_regrid.esm", &child_regrid());
    write(
        d,
        "parent_plain.esm",
        &parent_mount(json!({"NX": 5, "NY": 6, "NTGT": 30})),
    );

    let esm = load_path_with_options(d.join("parent_plain.esm"), &BTreeMap::new()).expect("load");
    let s = sizes(&esm);
    assert_eq!(s["tgt_cells"], 30);
    assert_eq!(s["gx"], 5);
    assert_eq!(s["gy"], 6);
}

#[test]
fn mount_edge_unknown_parent_name_is_loud() {
    let tmp = tempfile::TempDir::new().unwrap();
    let d = tmp.path();
    write(d, "child_regrid.esm", &child_regrid());
    write(
        d,
        "parent_bad.esm",
        &parent_mount(json!({"NX": "NX", "NY": "NX", "NTGT": {"op": "*", "args": ["NX", "NZZ"]}})),
    );

    let e = load_path_with_options(d.join("parent_bad.esm"), &meta(&[("NX", 18)]))
        .expect_err("unknown parent name in a mount-edge binding must fail loudly");
    assert!(
        e.to_string().contains("[template_import_unknown_name]"),
        "got: {e}"
    );
}
