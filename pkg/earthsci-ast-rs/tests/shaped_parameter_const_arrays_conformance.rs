//! Cross-language conformance: a caller's `const_arrays` entry for a SHAPED
//! parameter is keyed like a `parameter_overrides` entry (esm-spec §6.6.2,
//! CONFORMANCE_SPEC §5.32.5).
//!
//! Shared fixtures and the expected values live under
//! `tests/conformance/shaped_parameter_const_arrays/` (repo root); the Julia
//! runner (`conformance_shaped_parameter_const_arrays_test.jl`) and the Python
//! runner (`test_shaped_parameter_const_arrays_conformance.py`) read the same
//! manifest. The build pipeline evaluates the model under its local names and
//! aliases a dotted key onto its bare tail, so both spellings bind here.

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::{Compiler, ProblemOptions, esm_problem, observed_field};
use ndarray::ArrayD;
use std::collections::HashMap;
use std::fs;

mod common;

#[test]
fn const_array_key_binds_the_shaped_parameter() {
    let dir = common::repo_fixture("conformance/shaped_parameter_const_arrays");
    let text = fs::read_to_string(dir.join("manifest.json")).expect("read manifest");
    let manifest: serde_json::Value = serde_json::from_str(&text).expect("parse manifest");
    assert_eq!(
        manifest["category"].as_str(),
        Some("shaped_parameter_const_arrays")
    );
    let cases = manifest["cases"].as_array().expect("cases");
    assert!(!cases.is_empty());
    for case in cases {
        let id = case["id"].as_str().expect("id");
        for compiler in manifest["compilers"].as_array().expect("compilers") {
            let compiler = match compiler.as_str().expect("compiler") {
                "native" => Compiler::Native,
                "interpreter" => Compiler::Interpreter,
                other => panic!("unknown compiler {other}"),
            };
            let mut arrays = HashMap::new();
            for (k, v) in case["const_arrays"].as_object().expect("const_arrays") {
                let vals: Vec<f64> = v
                    .as_array()
                    .expect("values")
                    .iter()
                    .map(|x| x.as_f64().expect("number"))
                    .collect();
                let n = vals.len();
                arrays.insert(
                    k.clone(),
                    ArrayD::from_shape_vec(vec![n], vals).expect("shape"),
                );
            }
            let opts = ProblemOptions {
                compiler: Some(compiler),
                const_arrays: arrays,
                ..Default::default()
            };
            let path = dir.join(case["fixture"].as_str().expect("fixture"));
            let prob = esm_problem(path.as_path(), (0.0, 1.0), opts)
                .unwrap_or_else(|e| panic!("{id} [{compiler:?}]: build failed: {e}"));
            let got: Vec<f64> = observed_field(&prob, case["observed"].as_str().expect("observed"))
                .unwrap_or_else(|e| panic!("{id} [{compiler:?}]: observed_field failed: {e}"))
                .iter()
                .copied()
                .collect();
            let want: Vec<f64> = case["expected"]
                .as_array()
                .expect("expected")
                .iter()
                .map(|x| x.as_f64().expect("number"))
                .collect();
            assert_eq!(got, want, "{id} [{compiler:?}]");
        }
    }
}
