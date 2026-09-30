//! Cross-language conformance: a SHAPED parameter with no data supplied at
//! the front door (esm-spec §10.10, CONFORMANCE_SPEC §5.32.5).
//!
//! The manifest and its cases live under `tests/conformance/missing_data/`
//! (repo root); the Julia runner (`conformance_missing_data_test.jl`) and the
//! Python runner (`test_missing_data_conformance.py`) read the same file.
//! Without data every compiler refuses the construction with
//! `E_TREEWALK_MISSING_DATA`, naming a parameter that has no value. With the
//! case's `const_arrays` every compiler builds, and the right-hand side at the
//! manifest's probe state is bit-for-bit the same under `native` and
//! `interpreter`.

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::{Compiler, ProblemOptions, esm_problem};
use ndarray::{ArrayD, IxDyn};
use serde_json::Value;
use std::collections::HashMap;
use std::fs;

mod common;

fn manifest() -> (std::path::PathBuf, Value) {
    let dir = common::repo_fixture("conformance/missing_data");
    let text = fs::read_to_string(dir.join("manifest.json")).expect("read manifest");
    let manifest: Value = serde_json::from_str(&text).expect("parse manifest");
    assert_eq!(manifest["category"].as_str(), Some("missing_data"));
    (dir, manifest)
}

fn compilers(manifest: &Value) -> Vec<Compiler> {
    manifest["compilers"]
        .as_array()
        .expect("compilers")
        .iter()
        .map(|c| match c.as_str().expect("compiler") {
            "native" => Compiler::Native,
            "interpreter" => Compiler::Interpreter,
            other => panic!("unknown compiler {other}"),
        })
        .collect()
}

/// A row-major nested JSON array (or a number) as a dense array.
fn dense(v: &Value) -> ArrayD<f64> {
    fn walk(v: &Value, depth: usize, shape: &mut Vec<usize>, out: &mut Vec<f64>) {
        match v {
            Value::Array(items) => {
                if shape.len() == depth {
                    shape.push(items.len());
                }
                assert_eq!(shape[depth], items.len(), "ragged array in the manifest");
                for item in items {
                    walk(item, depth + 1, shape, out);
                }
            }
            other => out.push(other.as_f64().expect("number")),
        }
    }
    let (mut shape, mut values) = (Vec::new(), Vec::new());
    walk(v, 0, &mut shape, &mut values);
    ArrayD::from_shape_vec(IxDyn(&shape), values).expect("shape")
}

fn local(name: &str) -> &str {
    name.rsplit('.').next().unwrap_or(name)
}

fn numbers(v: &Value) -> Vec<f64> {
    v.as_array()
        .expect("numbers")
        .iter()
        .map(|x| x.as_f64().expect("number"))
        .collect()
}

/// The right-hand side of `prob` at the manifest's probe state, under the
/// compiler that built it: the interpreter's per-cell walk, or native's taped
/// program (which must keep every rule on the tape).
fn rhs_at_probe(prob: &earthsci_ast::EsmProblem, compiler: Compiler, id: &str) -> Vec<f64> {
    let compiled = prob
        .debug_array_compiled()
        .unwrap_or_else(|| panic!("{id} [{compiler}]: no right-hand side"));
    let n = compiled.state_variable_names().len();
    let state: Vec<f64> = (0..n)
        .map(|k| 1.0 + 0.1 * (0.37 * k as f64).sin())
        .collect();
    let dy = if compiler == Compiler::Interpreter {
        compiled.debug_eval_rhs(&state, 0.0, prob.p(), true).0
    } else {
        let params = compiled.debug_resolve_params(prob.p());
        let mut dy = vec![0.0; n];
        let mut scratch = compiled.debug_new_scratch_taped();
        let mut stats = earthsci_ast::simulate_array::RhsStats::default();
        compiled.debug_eval_rhs_into(&state, 0.0, &params, &mut dy, &mut scratch, &mut stats);
        assert_eq!(
            stats.fallback_rules, 0,
            "{id}: a rule left the tape at run time under native"
        );
        dy
    };
    assert!(
        dy.iter().all(|v| v.is_finite()),
        "{id} [{compiler}]: non-finite right-hand side {dy:?}"
    );
    dy
}

fn build(
    path: &std::path::Path,
    compiler: Compiler,
    const_arrays: HashMap<String, ArrayD<f64>>,
) -> Result<earthsci_ast::EsmProblem, earthsci_ast::SimulateError> {
    esm_problem(
        path,
        (0.0, 1.0),
        ProblemOptions {
            compiler: Some(compiler),
            const_arrays,
            rhs: earthsci_ast::Rhs::Always,
            ..Default::default()
        },
    )
}

#[test]
fn a_shaped_parameter_with_no_data_is_refused_by_name() {
    let (dir, manifest) = manifest();
    let code = manifest["error_code"].as_str().expect("error_code");
    for case in manifest["cases"].as_array().expect("cases") {
        let id = case["id"].as_str().expect("id");
        let path = dir.join(case["fixture"].as_str().expect("fixture"));
        for compiler in compilers(&manifest) {
            let built = build(path.as_path(), compiler, HashMap::new());
            let Some(missing) = case["missing"].as_array() else {
                // Not a missing-data case: it builds, and reads what it declares.
                let prob = built.unwrap_or_else(|e| {
                    panic!("{id} [{compiler}]: build failed without data: {e}")
                });
                if let Some(want) = case.get("expected_rhs_without_data") {
                    assert_eq!(
                        rhs_at_probe(&prob, compiler, id),
                        numbers(want),
                        "{id} [{compiler}]"
                    );
                }
                continue;
            };
            let missing: Vec<&str> = missing.iter().map(|m| m.as_str().expect("name")).collect();
            let err = match built {
                Ok(_) => panic!("{id} [{compiler}]: built with no data for {missing:?}"),
                Err(e) => e.to_string(),
            };
            assert!(err.contains(code), "{id} [{compiler}]: {err}");
            assert!(
                missing
                    .iter()
                    .any(|m| err.contains(&format!("'{}'", local(m))) || err.contains(m)),
                "{id} [{compiler}]: the refusal names none of {missing:?}: {err}"
            );
        }
    }
}

#[test]
fn with_its_data_every_compiler_builds_and_agrees_bit_for_bit() {
    let (dir, manifest) = manifest();
    for case in manifest["cases"].as_array().expect("cases") {
        let id = case["id"].as_str().expect("id");
        let Some(arrays) = case["const_arrays"].as_object() else {
            continue;
        };
        let path = dir.join(case["fixture"].as_str().expect("fixture"));
        let mut answers: Vec<Vec<f64>> = Vec::new();
        for compiler in compilers(&manifest) {
            let const_arrays: HashMap<String, ArrayD<f64>> =
                arrays.iter().map(|(k, v)| (k.clone(), dense(v))).collect();
            let prob = build(path.as_path(), compiler, const_arrays)
                .unwrap_or_else(|e| panic!("{id} [{compiler}]: build failed with data: {e}"));
            if !case["rhs"].as_bool().unwrap_or(false) {
                continue;
            }
            let dy = rhs_at_probe(&prob, compiler, id);
            if let Some(want) = case.get("expected_rhs") {
                assert_eq!(dy, numbers(want), "{id} [{compiler}]");
            }
            answers.push(dy);
        }
        if let [a, b] = answers.as_slice() {
            let same =
                a.len() == b.len() && a.iter().zip(b).all(|(x, y)| x.to_bits() == y.to_bits());
            assert!(same, "{id}: native {a:?} != interpreter {b:?}");
        }
    }
}
