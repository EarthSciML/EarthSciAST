//! esm 2.4.0 "one operator type" (esm-spec §4.2, §4.8.3, §9.6.1–9.6.3,
//! §9.6.6, §9.6.12; CONFORMANCE_SPEC §5.61): calls of defined operators
//! resolve to definitions and become references, old spellings are read at
//! the wire boundary, core names are reserved, arity is checked at load, unit
//! expressions type a call. Mirrors the Julia reference suite
//! `EarthSciAST.jl/test/one_operator_type_test.jl` over the same fixtures
//! under `tests/conformance/expression_templates/`.

use earthsci_ast::extension::lower_expression_templates as oob;
use earthsci_ast::resolve_template_machinery;
use serde_json::Value;
use std::collections::BTreeMap;
use std::path::PathBuf;

use crate::common;

fn oot(dir: &str) -> PathBuf {
    common::repo_fixture("conformance/expression_templates").join(dir)
}

fn read_json(p: &std::path::Path) -> Value {
    serde_json::from_str(&std::fs::read_to_string(p).expect("read")).expect("parse")
}

/// `emit_esm_string(emit_document(raw, dir))` of a document at `path`.
fn emit_path(path: &std::path::Path) -> String {
    let raw = read_json(path);
    let doc = oob::emit_document(&raw, path.parent().expect("a directory"))
        .unwrap_or_else(|e| panic!("emit {}: {e}", path.display()));
    oob::emit_esm_string(&doc)
}

/// The Option-B load: template machinery, then lowering (references kept).
fn load_b(path: &std::path::Path) -> Value {
    let raw = read_json(path);
    let resolved = resolve_template_machinery(&raw, path.parent().unwrap(), &BTreeMap::new())
        .expect("machinery");
    let mut loaded = resolved.unwrap_or(raw);
    oob::lower_expression_templates(&mut loaded).expect("lowering");
    loaded
}

/// Integral floats as integers, recursively (JSON3 reads `1.0` as `1`).
fn normj(v: &Value) -> Value {
    match v {
        Value::Number(n) => match n.as_f64() {
            Some(f) if !n.is_i64() && !n.is_u64() && f.is_finite() && f.fract() == 0.0 => {
                Value::from(f as i64)
            }
            _ => v.clone(),
        },
        Value::Array(a) => Value::Array(a.iter().map(normj).collect()),
        Value::Object(o) => Value::Object(o.iter().map(|(k, x)| (k.clone(), normj(x))).collect()),
        _ => v.clone(),
    }
}

/// The parts of a document an expansion is compared on.
fn core(d: &Value) -> Value {
    let mut out = serde_json::Map::new();
    for k in ["models", "reaction_systems", "coupling", "index_sets"] {
        if let Some(v) = d.get(k) {
            out.insert(k.to_string(), normj(v));
        }
    }
    Value::Object(out)
}

#[test]
fn emitted_goldens_byte_for_byte_and_emit_of_load_is_a_fixed_point() {
    for dir in [
        "operator_call_by_name",
        "placeholder_call",
        "partial_wrt_param_instance",
        "old_names",
        "reference_only_round_trip",
        "independent_variable_wrt",
        "vector_calculus_import",
    ] {
        let out = emit_path(&oot(dir).join("fixture.esm"));
        let want = std::fs::read_to_string(oot(dir).join("emitted.esm")).expect("golden");
        assert_eq!(out, want, "{dir}: emitted.esm");
        let tmp = tempfile::tempdir().expect("tempdir");
        let p = tmp.path().join("e.esm");
        std::fs::write(&p, &out).expect("write");
        assert_eq!(
            emit_path(&p),
            out,
            "{dir}: emit ∘ load is not a fixed point"
        );
    }
}

/// esm-spec §9.6.1, §9.6.4 rule 5: emitted rules are reference-only, so a
/// reloaded emitted document calls nothing it did not call before, and emit →
/// load → emit is exact (also for `constrained_match_scope`).
#[test]
fn emitted_rules_are_reference_only() {
    let out = std::fs::read_to_string(oot("reference_only_round_trip").join("emitted.esm"))
        .expect("golden");
    let doc: Value = serde_json::from_str(&out).expect("JSON");
    let reg = &doc["models"]["m"]["operators"];
    assert_eq!(reg["fv_div_edges"]["reference_only"], true);
    assert_eq!(reg["exp"]["reference_only"], true);
    assert!(reg["fv_div_edges"].get("where").is_none());
    // div(G) stayed a call; reloading does not turn it into a reference.
    assert!(out.contains("\"op\": \"div\""));
    for dir in ["reference_only_round_trip", "constrained_match_scope"] {
        let once = emit_path(&oot(dir).join("fixture.esm"));
        let tmp = tempfile::tempdir().expect("tempdir");
        let p = tmp.path().join("e.esm");
        std::fs::write(&p, &once).expect("write");
        let twice = emit_path(&p);
        assert_eq!(twice, once, "{dir}: emit ∘ load is not exact");
        std::fs::write(&p, &twice).expect("write");
        assert_eq!(emit_path(&p), once, "{dir}: third emit");
    }
}

#[test]
fn old_spellings_emit_exactly_as_the_new_ones() {
    let strip = |t: String| {
        let mut d: Value = serde_json::from_str(&t).expect("emitted JSON");
        d.as_object_mut().unwrap().remove("metadata");
        d
    };
    assert_eq!(
        strip(emit_path(&oot("old_names").join("fixture.esm"))),
        strip(emit_path(&oot("old_names").join("new_names.esm")))
    );
}

#[test]
fn expanded_goldens_structurally() {
    for dir in ["operator_call_by_name", "partial_wrt_param_instance"] {
        let mut got = load_b(&oot(dir).join("fixture.esm"));
        oob::expand(&mut got).expect("expand");
        let want = read_json(&oot(dir).join("expanded.esm"));
        assert_eq!(core(&got), core(&want), "{dir}: expanded.esm");
    }
}

#[test]
fn load_errors_by_code() {
    for (dir, fix, errf) in [
        ("operator_arity_mismatch", "fixture.esm", "error.json"),
        ("operator_defines_core_op", "fixture.esm", "error.json"),
        (
            "operator_defines_core_op",
            "explicit_defines.esm",
            "error_explicit_defines.json",
        ),
    ] {
        let want = read_json(&oot(dir).join(errf));
        let err = earthsci_ast::load_path(oot(dir).join(fix))
            .expect_err(&format!("{dir}/{fix} must be refused"));
        assert_eq!(err.code(), want["code"].as_str(), "{dir}/{fix}: {err}");
    }
    earthsci_ast::load_path(oot("operator_defines_core_op").join("compound_rule_exempt.esm"))
        .expect("a compound rule rooted at a core op defines no callable name");
}

/// The reservation message names the definition and the core operator.
#[test]
fn the_reservation_names_the_definition_and_the_core_operator() {
    let err = earthsci_ast::load_path(oot("operator_defines_core_op").join("fixture.esm"))
        .expect_err("refused");
    let msg = err.to_string();
    assert!(
        msg.contains("operators.exp") && msg.contains("'exp'"),
        "{msg}"
    );
}

#[test]
fn old_and_new_spellings_load_alike() {
    let old = earthsci_ast::load_path(oot("old_names").join("fixture.esm")).expect("old names");
    let new = earthsci_ast::load_path(oot("old_names").join("new_names.esm")).expect("new names");
    assert_eq!(
        serde_json::to_value(&old.models).unwrap(),
        serde_json::to_value(&new.models).unwrap()
    );
}

#[test]
fn a_placeholder_loads_and_is_refused_only_if_evaluated() {
    let file = earthsci_ast::load_path(oot("placeholder_call").join("fixture.esm"))
        .expect("a placeholder loads");
    let err = earthsci_ast::esm_problem(&file, (0.0, 1.0), Default::default())
        .expect_err("a placeholder is refused when evaluated");
    assert_eq!(err.code(), Some("unlowered_operator"), "{err}");
    assert!(err.to_string().contains("placeholder"), "{err}");
}

#[test]
fn unit_expressions_type_a_call() {
    let expected = read_json(&oot("definition_units").join("expected.json"));
    for f in [
        "fixture.esm",
        "body_mismatch.esm",
        "call_unit_from_expression.esm",
    ] {
        let file = earthsci_ast::load_path(oot("definition_units").join(f)).expect("loads");
        let r = earthsci_ast::validate(&file);
        let mut got_e: Vec<String> = r
            .structural_errors
            .iter()
            .map(|e| e.code.to_string())
            .collect();
        got_e.sort();
        got_e.dedup();
        let mut got_w: Vec<String> = r
            .unit_warnings
            .iter()
            .filter(|w| w.code == "definition_unit_mismatch")
            .map(|w| w.code.clone())
            .collect();
        got_w.sort();
        got_w.dedup();
        let list = |k: &str| -> Vec<String> {
            let mut v: Vec<String> = expected[f][k]
                .as_array()
                .unwrap()
                .iter()
                .map(|x| x.as_str().unwrap().to_string())
                .collect();
            v.sort();
            v
        };
        assert_eq!(
            got_e,
            list("errors"),
            "{f}: errors {:?}",
            r.structural_errors
        );
        assert_eq!(
            got_w,
            list("warnings"),
            "{f}: warnings {:?}",
            r.unit_warnings
        );
    }
}

#[test]
fn old_codes_are_aliases_of_the_new_ones() {
    assert_eq!(
        earthsci_ast::extension::diagnostic::canonical_error_code("template_import_cycle"),
        "operator_import_cycle"
    );
    assert_eq!(
        earthsci_ast::extension::diagnostic::canonical_error_code(
            "apply_expression_template_unknown_template"
        ),
        "operator_unknown_definition"
    );
    assert_eq!(
        earthsci_ast::extension::diagnostic::canonical_error_code("operator_import_cycle"),
        "operator_import_cycle"
    );
    for (old, new) in earthsci_ast::extension::diagnostic::ERROR_CODE_ALIASES {
        assert!(
            earthsci_ast::error_code_names().contains(new),
            "{old} -> {new}: not a registered code"
        );
    }
}

/// esm-spec §9.6.12: an object spelling both `expression_templates` and
/// `operators` is `operator_invalid_definition`, whether the library is
/// loaded itself or imported.
#[test]
fn a_library_with_both_spellings_is_refused_alike_at_the_root_and_imported() {
    let mut lib = read_json(&oot("old_names").join("lib_new.esm"));
    lib["expression_templates"] = lib["operators"].clone();
    let host = serde_json::json!({
        "esm": "2.4.0",
        "metadata": {"name": "importer"},
        "models": {"m": {
            "operator_imports": [{"ref": "lib.esm"}],
            "variables": {"u": {"type": "unknown", "units": "1", "default": 1.0}},
            "equations": [{"lhs": {"op": "D", "args": ["u"], "wrt": "t"}, "rhs": "u"}]
        }}
    });
    let d = tempfile::tempdir().expect("tempdir");
    std::fs::write(d.path().join("lib.esm"), lib.to_string()).expect("write lib");
    std::fs::write(d.path().join("host.esm"), host.to_string()).expect("write host");
    for f in ["lib.esm", "host.esm"] {
        let err = earthsci_ast::load_path(d.path().join(f)).expect_err("refused");
        assert_eq!(
            err.code(),
            Some("operator_invalid_definition"),
            "{f}: {err}"
        );
    }
}

/// esm-spec §4.2, §9.6.12: a `partial` call has the fixed unit
/// `[f]/[wrt]` whichever rule lowers it. A fired `match` rule whose body
/// disagrees is `definition_unit_mismatch`, and the equation is typed by the
/// fixed unit, so it is consistent.
#[test]
fn a_fired_partial_rule_is_checked_against_the_fixed_unit() {
    let doc = serde_json::json!({
        "esm": "2.4.0",
        "metadata": {"name": "partial_rule_fixed_unit"},
        "models": {"m": {
            "variables": {
                "u": {"type": "parameter", "units": "kg", "default": 1.0},
                "x": {"type": "parameter", "units": "m", "default": 1.0},
                "k": {"type": "parameter", "units": "1", "default": 0.5},
                "y": {"type": "unknown", "units": "kg/m"}
            },
            "equations": [{
                "lhs": "y",
                "rhs": {"op": "partial", "args": ["u"], "wrt": "x"}
            }],
            "operators": {
                "scaled": {
                    "params": ["f", "d"],
                    "match": {"op": "partial", "args": ["f"], "wrt": "d"},
                    "body": {"op": "*", "args": ["f", "k"]}
                }
            }
        }}
    });
    let file = earthsci_ast::load_string(&doc.to_string()).expect("loads");
    let r = earthsci_ast::validate(&file);
    let codes: Vec<&str> = r
        .structural_errors
        .iter()
        .map(|e| e.code.as_str())
        .collect();
    assert!(
        codes.contains(&"definition_unit_mismatch"),
        "{:?}",
        r.structural_errors
    );
    assert!(
        !codes.contains(&"unit_inconsistency"),
        "{:?}",
        r.structural_errors
    );
}
