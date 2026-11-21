//! esm-spec §9.6.4 rule 1 at a §4.7 mount edge: a mounted leaf keeps its
//! template references, and its components' template definitions join the
//! mounting component's registry by flatten's registry-merge rule (deep-equal
//! entries kept once; a name two non-equal entries share renamed in every owner
//! to `<owner path>.<name>`, references following). Drives
//! `tests/conformance/expression_templates/mount_registry_merge/` against the
//! Julia-generated goldens (`flattened_registry.esm`,
//! `inline_flattened_registry.esm`, `inline_emitted.esm`), byte for byte.

use earthsci_ast::extension::lower_expression_templates::{emit_document, emit_esm_string};
use earthsci_ast::{flatten, load_path};
use serde_json::{Map, Value};
use std::path::PathBuf;

use crate::common;

fn dir() -> PathBuf {
    common::repo_fixture("conformance/expression_templates/mount_registry_merge")
}

fn read(name: &str) -> String {
    std::fs::read_to_string(dir().join(name)).expect("read fixture file")
}

/// The flattened system's merged template registry, written as the goldens
/// write it: one `expression_templates` block, so its entry order is kept.
fn flattened_registry(name: &str) -> String {
    let file = load_path(dir().join(name)).expect("load");
    let flat = flatten(&file).expect("flatten");
    let block: Map<String, Value> = flat.template_registry.into_iter().collect();
    let mut doc = Map::new();
    doc.insert("expression_templates".to_string(), Value::Object(block));
    emit_esm_string(&Value::Object(doc))
}

#[test]
fn a_mounted_leafs_registry_merges_into_the_mounting_component() {
    assert_eq!(
        flattened_registry("fixture.esm"),
        read("flattened_registry.esm")
    );
}

#[test]
fn an_inline_subsystems_registry_merges_by_the_same_rule() {
    assert_eq!(
        flattened_registry("inline_form.esm"),
        read("inline_flattened_registry.esm")
    );
}

#[test]
fn the_inline_form_emits_the_merged_registry() {
    let raw: Value = serde_json::from_str(&read("inline_form.esm")).expect("parse");
    let emitted = emit_document(&raw, &dir()).expect("emit");
    assert_eq!(emit_esm_string(&emitted), read("inline_emitted.esm"));
}

/// The mounted and inline forms denote the same system: the leaf's `match`
/// rule `dbl(a) -> a + a` fired in the leaf, and the inline form spells that
/// sum out; every renamed reference reaches its own owner's body.
#[test]
fn the_mounted_and_inline_forms_flatten_to_the_same_equations() {
    let eqs = |name: &str| {
        let flat = flatten(&load_path(dir().join(name)).expect("load")).expect("flatten");
        flat.equations
            .iter()
            .map(|e| serde_json::to_string(e).expect("serialize"))
            .collect::<Vec<_>>()
    };
    let mounted = eqs("fixture.esm");
    assert_eq!(mounted, eqs("inline_form.esm"));
    let all = mounted.join("\n");
    // Host's own `scale` (2x), the leaf's (3x, read through `rate` with the
    // leaf's own `k`, which the hoisted body spells `Sub.k`), and Inner's
    // reference to Host's. Julia's reference-preserving flatten reads the
    // registry body in Host's scope, so `k` is `Host.Sub.k` there too.
    let want = [
        r#"{"lhs":{"op":"D","args":["Host.y"],"wrt":"t"},"rhs":{"op":"-","args":[{"op":"*","args":[2,"Host.y"]}]}}"#,
        r#"{"lhs":{"op":"D","args":["Host.z"],"wrt":"t"},"rhs":{"op":"-","args":[{"op":"/","args":["Host.z",2]}]}}"#,
        r#"{"lhs":{"op":"D","args":["Host.Sub.c"],"wrt":"t"},"rhs":{"op":"-","args":[{"op":"*","args":["Host.Sub.k",{"op":"*","args":[3,"Host.Sub.c"]}]}]}}"#,
        r#"{"lhs":{"op":"D","args":["Host.Sub.d"],"wrt":"t"},"rhs":{"op":"-","args":[{"op":"+","args":[{"op":"/","args":["Host.Sub.d",2]},{"op":"/","args":["Host.Sub.d",2]}]}]}}"#,
        r#"{"lhs":{"op":"D","args":["Host.Inner.w"],"wrt":"t"},"rhs":{"op":"-","args":[{"op":"*","args":[2,"Host.Inner.w"]}]}}"#,
    ];
    assert_eq!(mounted, want, "{all}");
}
