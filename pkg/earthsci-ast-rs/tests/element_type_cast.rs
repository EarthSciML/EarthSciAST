//! The `cast` op (esm-spec §4.2, §11.3.1; CONFORMANCE_SPEC §5.18.2a): the one
//! conversion between binary64 and binary32 (EarthSciAST#536).
//!
//! The defect this closes: §11.3.1 told an author to compute a mixed step
//! "into a variable whose own `element_type` says which precision it lands
//! in", and refused exactly that equation as `mixed_element_type`, so a
//! binary64 sum could not be continued in binary32 at all.
//!
//! The fixtures are shared with the other four bindings
//! (`tests/conformance/element_type_cast/`). Every binding asserts `casts`;
//! this one evaluates per-variable precision, so it also asserts `values` bit
//! for bit on both compilers and `build_errors`.

#![cfg(not(target_arch = "wasm32"))]

use std::path::PathBuf;

use earthsci_ast::{load_path, to_json};
use serde_json::Value;

use crate::common;

fn dir() -> PathBuf {
    common::repo_fixture("conformance/element_type_cast")
}

fn expected() -> Value {
    let text = std::fs::read_to_string(dir().join("expected.json")).expect("expected.json");
    serde_json::from_str(&text).expect("expected.json parses")
}

/// The `element_type` of every `cast` node, in document order (models,
/// equations, a node before its operands).
fn casts(doc: &Value) -> Vec<Value> {
    fn walk(v: &Value, out: &mut Vec<Value>) {
        match v {
            Value::Object(o) => {
                if o.get("op").and_then(Value::as_str) == Some("cast") {
                    out.push(o.get("element_type").cloned().unwrap_or(Value::Null));
                }
                for k in ["args", "expr", "filter", "values"] {
                    if let Some(c) = o.get(k) {
                        walk(c, out);
                    }
                }
            }
            Value::Array(a) => a.iter().for_each(|c| walk(c, out)),
            _ => {}
        }
    }
    let mut out = Vec::new();
    for (_, model) in doc["models"].as_object().expect("models") {
        for eq in model["equations"].as_array().into_iter().flatten() {
            walk(&eq["lhs"], &mut out);
            walk(&eq["rhs"], &mut out);
        }
    }
    out
}

fn loaded_json(fixture: &str) -> Value {
    let file = load_path(dir().join(fixture)).unwrap_or_else(|e| panic!("{fixture}: {e}"));
    serde_json::from_str(&to_json(&file).expect("serializes")).expect("emits JSON")
}

#[test]
fn every_cast_loads_and_round_trips_with_its_element_type() {
    let exp = expected();
    for (fixture, want) in exp["casts"].as_object().expect("casts") {
        let once = loaded_json(fixture);
        assert_eq!(
            &Value::Array(casts(&once)),
            want,
            "{fixture}: cast element_types after load"
        );
        let file = earthsci_ast::load_string(&serde_json::to_string(&once).unwrap())
            .unwrap_or_else(|e| panic!("{fixture}: emitted form does not reload: {e}"));
        let twice: Value = serde_json::from_str(&to_json(&file).unwrap()).unwrap();
        assert_eq!(casts(&once), casts(&twice), "{fixture}: load → emit → load");
    }
}

/// Build `model` of `fixture` under `compiler` and read `var`.
fn evaluate(
    fixture: &str,
    model: &str,
    var: &str,
    compiler: earthsci_ast::Compiler,
) -> Result<f64, String> {
    let file = load_path(dir().join(fixture)).map_err(|e| e.to_string())?;
    let prob = earthsci_ast::esm_problem(
        &file,
        (0.0, 0.0),
        earthsci_ast::ProblemOptions {
            rhs: earthsci_ast::Rhs::Auto,
            compiler: Some(compiler),
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
fn a_cast_rounds_once_to_its_element_type_on_both_compilers() {
    let exp = expected();
    for compiler in [
        earthsci_ast::Compiler::Interpreter,
        earthsci_ast::Compiler::Native,
    ] {
        for (fixture, values) in exp["values"].as_object().expect("values") {
            for (path, want) in values.as_object().expect("per-fixture values") {
                let (model, var) = path.split_once('.').expect("Model.var");
                let want = want.as_f64().expect("number");
                let got = evaluate(fixture, model, var, compiler).unwrap_or_else(|e| {
                    panic!("{fixture}: {path} did not evaluate under {compiler:?}: {e}")
                });
                assert_eq!(
                    got.to_bits(),
                    want.to_bits(),
                    "{fixture}: {path} = {got:?} under {compiler:?}, expected {want:?} \
                     (compared bit for bit)"
                );
            }
        }
    }
}

#[test]
fn a_mix_without_a_cast_is_still_refused() {
    let exp = expected();
    for (fixture, code) in exp["build_errors"].as_object().expect("build_errors") {
        let code = code.as_str().expect("code");
        let (model, var) = {
            let doc = loaded_json(fixture);
            let (m, body) = doc["models"]
                .as_object()
                .and_then(|m| m.iter().next())
                .map(|(k, v)| (k.clone(), v.clone()))
                .expect("a model");
            let var = body["variables"]
                .as_object()
                .and_then(|v| {
                    v.iter()
                        .find(|(_, d)| d["type"] == "unknown")
                        .map(|(k, _)| k.clone())
                })
                .expect("an unknown");
            (m, var)
        };
        let err = evaluate(fixture, &model, &var, earthsci_ast::Compiler::Interpreter)
            .expect_err("a mixed precision must not build");
        assert!(err.contains(code), "{fixture}: expected `{code}`, got {err}");
    }
}

/// The fixtures' own inline `tests` agree with `expected.json`'s values: what
/// `esm test` runs is what this file asserts.
#[test]
fn the_fixtures_inline_tests_pass() {
    let exp = expected();
    for fixture in exp["values"].as_object().expect("values").keys() {
        let file = load_path(dir().join(fixture)).unwrap_or_else(|e| panic!("{fixture}: {e}"));
        let results = earthsci_ast::run_inline_tests_with_options(
            &file,
            &earthsci_ast::InlineTestOptions::default(),
            None,
        );
        assert!(!results.is_empty(), "{fixture}: no inline test ran");
        for r in &results {
            assert!(r.passed, "{fixture}: {}", r.message);
        }
    }
}
