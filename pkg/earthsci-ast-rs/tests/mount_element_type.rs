//! esm-spec §4.7 "Working precision crosses a mount" (CONFORMANCE_SPEC
//! §5.18.2b): a mounted document's `domain.element_type` does not merge, so the
//! mount edge writes it onto the variables of the component it splices in,
//! whenever it differs from the mounting document's effective precision.
//!
//! The defect this pins: a `"Float32"` leaf mounted by a document that
//! declares no domain evaluated in binary64. `100*((100-a)/100)/(100-a)` with
//! `a = 73.5` came out `1` through the mount and `0.99999994` standalone.
//!
//! The fixtures are shared with the other four bindings
//! (`tests/conformance/mount_element_type/`). They assert the LOADER contract
//! (`loads`, `load_errors`); this binding also evaluates per-variable
//! precision, so it asserts `values` bit for bit and `build_errors` as well.

#![cfg(not(target_arch = "wasm32"))]

use std::path::PathBuf;

use earthsci_ast::{load_path, to_json};
use serde_json::Value;

mod common;

fn dir() -> PathBuf {
    common::repo_fixture("conformance/mount_element_type")
}

fn expected() -> Value {
    let text = std::fs::read_to_string(dir().join("expected.json")).expect("expected.json");
    serde_json::from_str(&text).expect("expected.json parses")
}

/// Every variable of every model (subsystems as `Model.Sub.var`) with the
/// `element_type` it carries — `Value::Null` for none.
fn carried(doc: &Value) -> serde_json::Map<String, Value> {
    fn walk(prefix: &str, system: &Value, out: &mut serde_json::Map<String, Value>) {
        if let Some(vars) = system.get("variables").and_then(Value::as_object) {
            for (v, decl) in vars {
                out.insert(
                    format!("{prefix}.{v}"),
                    decl.get("element_type").cloned().unwrap_or(Value::Null),
                );
            }
        }
        if let Some(subs) = system.get("subsystems").and_then(Value::as_object) {
            for (k, sub) in subs {
                walk(&format!("{prefix}.{k}"), sub, out);
            }
        }
    }
    let mut out = serde_json::Map::new();
    if let Some(models) = doc.get("models").and_then(Value::as_object) {
        for (m, model) in models {
            walk(m, model, &mut out);
        }
    }
    out
}

fn loaded_json(fixture: &str) -> Value {
    let file = load_path(dir().join(fixture)).unwrap_or_else(|e| panic!("{fixture}: {e}"));
    serde_json::from_str(&to_json(&file).expect("serializes")).expect("emits JSON")
}

#[test]
fn a_mount_writes_exactly_the_leafs_differing_precision() {
    let exp = expected();
    for (fixture, want) in exp["loads"].as_object().expect("loads") {
        let doc = loaded_json(fixture);
        let domain = doc
            .get("domain")
            .and_then(|d| d.get("element_type"))
            .cloned()
            .unwrap_or(Value::Null);
        assert_eq!(
            domain, want["domain_element_type"],
            "{fixture}: domain.element_type"
        );
        let got = carried(&doc);
        let want = want["element_types"].as_object().expect("element_types");
        assert_eq!(
            &got, want,
            "{fixture}: the element_type every variable carries after load"
        );
    }
}

/// The code `binding` must refuse `fixture` with, or `None` when it must only
/// refuse (`load_errors` maps a fixture to `{code: [bindings]}`).
pub(crate) fn expected_load_error(want: &Value, binding: &str) -> Option<String> {
    want.as_object()?.iter().find_map(|(code, bindings)| {
        bindings
            .as_array()?
            .iter()
            .any(|b| b == binding)
            .then(|| code.clone())
    })
}

#[test]
fn a_reaction_system_cannot_carry_a_mounted_precision() {
    let exp = expected();
    for (fixture, want) in exp["load_errors"].as_object().expect("load_errors") {
        let code = expected_load_error(want, "rust");
        match load_path(dir().join(fixture)) {
            Ok(_) => panic!("{fixture} loaded; expected a refusal ({code:?})"),
            Err(e) => {
                if let Some(code) = code {
                    assert!(
                        e.to_string().contains(&code),
                        "{fixture}: expected `{code}`, got {e}"
                    );
                }
            }
        }
    }
}

/// Build `model` of `fixture` on the reference evaluator and read `var`.
fn evaluate(fixture: &str, model: &str, var: &str) -> Result<f64, String> {
    let file = load_path(dir().join(fixture)).map_err(|e| e.to_string())?;
    let prob = earthsci_ast::esm_problem(
        &file,
        (0.0, 0.0),
        earthsci_ast::ProblemOptions {
            rhs: earthsci_ast::Rhs::Auto,
            // A per-variable element type is the one condition under which the
            // array runtime installs no tape, so strict `native` refuses these
            // documents by name (API_SPEC §5.8).
            compiler: Some(earthsci_ast::Compiler::Interpreter),
            model_name: Some(model.to_string()),
            build_pipeline: true,
            ..Default::default()
        },
    )
    .map_err(|e| e.to_string())?;
    let arr = earthsci_ast::observed_field(&prob, var).map_err(|e| e.to_string())?;
    arr.iter()
        .next()
        .copied()
        .ok_or_else(|| format!("{fixture}: {model}.{var} evaluated to an empty field"))
}

#[test]
fn a_mounted_leaf_evaluates_in_its_own_precision() {
    let exp = expected();
    for (fixture, values) in exp["values"].as_object().expect("values") {
        for (path, want) in values.as_object().expect("per-fixture values") {
            let (model, var) = path.split_once('.').expect("Model.var");
            let want = want.as_f64().expect("number");
            let got = evaluate(fixture, model, var)
                .unwrap_or_else(|e| panic!("{fixture}: {path} did not evaluate: {e}"));
            assert_eq!(
                got.to_bits(),
                want.to_bits(),
                "{fixture}: {path} = {got:?}, expected {want:?} (compared bit for bit)"
            );
        }
    }
}

/// The two build-time refusals, reached through the inline-test runner so the
/// coupled document is flattened exactly as `esm test` would flatten it.
#[test]
fn a_mixed_or_uncarried_precision_is_refused_at_build() {
    let exp = expected();
    for (fixture, code) in exp["build_errors"].as_object().expect("build_errors") {
        let code = code.as_str().expect("code");
        let mut doc = loaded_json(fixture);
        // Give every model one assertion so the runner builds it; inline tests
        // do not cross a mount edge, so the fixtures cannot carry these.
        for (_, model) in doc["models"].as_object_mut().expect("models").iter_mut() {
            let var = model["variables"]
                .as_object()
                .and_then(|v| {
                    v.iter()
                        .find(|(_, d)| d["type"] == "unknown")
                        .map(|(k, _)| k.clone())
                })
                .expect("every fixture model has an unknown");
            model["tests"] = serde_json::json!([{
                "id": "build", "time_span": {"start": 0.0, "end": 0.0},
                "assertions": [{"variable": var, "time": 0.0, "expected": 0.0}]
            }]);
        }
        let text = serde_json::to_string(&doc).expect("serializes");
        let file = earthsci_ast::load_string(&text).expect("reloads");
        let results = earthsci_ast::run_inline_tests_with_options(
            &file,
            &earthsci_ast::InlineTestOptions {
                compiler: Some(earthsci_ast::Compiler::Interpreter),
                ..Default::default()
            },
            None,
        );
        assert!(
            results.iter().any(|r| r.message.contains(code)),
            "{fixture}: expected a `{code}` refusal from the build; got {:#?}",
            results.iter().map(|r| &r.message).collect::<Vec<_>>()
        );
    }
}

/// `emit ∘ load` is a fixed point: the written fields load back as themselves.
#[test]
fn the_written_fields_round_trip() {
    let exp = expected();
    for fixture in exp["loads"].as_object().expect("loads").keys() {
        let once = loaded_json(fixture);
        let file = earthsci_ast::load_string(&serde_json::to_string(&once).unwrap())
            .unwrap_or_else(|e| panic!("{fixture}: emitted form does not reload: {e}"));
        let twice: Value = serde_json::from_str(&to_json(&file).unwrap()).unwrap();
        assert_eq!(
            carried(&once),
            carried(&twice),
            "{fixture}: load → emit → load"
        );
    }
}
