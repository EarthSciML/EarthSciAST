//! The equality-scatter fixtures (`tests/conformance/faq_equality_scatter/`,
//! esm-spec §4.3.1 "One-pass scatter for an equality filter").
//!
//! Every fixture is built under `interpreter` and `native`; the right-hand
//! side at the document's initial state, default parameters and `t = 0` must
//! equal the committed golden BIT FOR BIT under both. The goldens come from the
//! tier's `generate.py`, a plain Python loop outside every binding, so this is
//! the interpreter against an independent oracle and native against both.
//! Native evaluates through the tape, as a solve does.

#![cfg(all(not(target_arch = "wasm32"), feature = "solve"))]

use std::fs;

use earthsci_ast::simulate_array::RhsStats;
use earthsci_ast::{Compiler, EsmProblem, ProblemOptions, Rhs, esm_problem, initial_state};
use serde_json::Value;

mod common;

const TIER: &str = "conformance/faq_equality_scatter";

fn read_json(rel: &str) -> Value {
    let path = common::repo_fixture(&format!("{TIER}/{rel}"));
    serde_json::from_str(
        &fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {}: {e}", path.display())),
    )
    .unwrap_or_else(|e| panic!("parse {}: {e}", path.display()))
}

fn golden_value(v: &Value) -> f64 {
    match v {
        Value::String(s) => match s.as_str() {
            "NaN" => f64::NAN,
            "Infinity" => f64::INFINITY,
            "-Infinity" => f64::NEG_INFINITY,
            other => panic!("unknown golden string {other:?}"),
        },
        _ => v.as_f64().expect("a number"),
    }
}

fn build(doc: &Value, compiler: Compiler) -> Result<EsmProblem, String> {
    let opts = ProblemOptions {
        compiler: Some(compiler),
        rhs: Rhs::Always,
        ..Default::default()
    };
    esm_problem(doc, (0.0, 1.0), opts).map_err(|e| e.to_string())
}

/// The right-hand side at the initial state, keyed by unqualified element
/// name (`w[2]`, `v[1,3]`, `g`).
fn rhs(prob: &EsmProblem, compiler: Compiler) -> Vec<(String, f64)> {
    let ac = prob
        .debug_array_compiled()
        .expect("the problem has a right-hand side");
    let _precision = ac.debug_precision_env().enter();
    let u = initial_state(prob).expect("the initial state builds");
    let names = ac.state_variable_names().to_vec();
    assert_eq!(names.len(), u.len());
    let dy = match compiler {
        Compiler::Native => {
            let params = ac.debug_resolve_params(prob.p());
            let mut dy = vec![f64::NAN; u.len()];
            let mut scratch = ac
                .debug_new_scratch_taped()
                .expect("the tape lowers every rule");
            let mut stats = RhsStats::default();
            ac.debug_eval_rhs_into(&u, 0.0, &params, &mut dy, &mut scratch, &mut stats);
            assert!(scratch.has_tape(), "the tape declined a rule");
            dy
        }
        _ => ac.debug_eval_rhs(&u, 0.0, prob.p(), true).0,
    };
    names.into_iter().zip(dy).collect()
}

#[test]
fn native_and_the_interpreter_equal_the_naive_golden_bit_for_bit() {
    let manifest = read_json("manifest.json");
    let fixtures = manifest["fixtures"].as_array().expect("fixtures");
    assert!(!fixtures.is_empty());
    let mut bad = Vec::new();
    for fx in fixtures {
        let id = fx["id"].as_str().expect("id");
        let doc = read_json(fx["path"].as_str().expect("path"));
        let golden = read_json(fx["golden"].as_str().expect("golden"));
        let want = golden["du"].as_object().expect("du");
        let excluded = fx["excluded"].get("rust").and_then(Value::as_str);
        for compiler in [Compiler::Interpreter, Compiler::Native] {
            let label = format!("{id} ({})", compiler.as_str());
            let mut fails = Vec::new();
            match build(&doc, compiler) {
                Err(e) => fails.push(format!("{label}: does not build: {e}")),
                Ok(prob) => {
                    let got = rhs(&prob, compiler);
                    if got.len() != want.len() {
                        fails.push(format!(
                            "{label}: {} state elements, the golden has {}",
                            got.len(),
                            want.len()
                        ));
                    }
                    for (name, value) in &got {
                        let Some(w) = want.get(name) else {
                            fails.push(format!("{label}: {name} is not in the golden"));
                            continue;
                        };
                        let w = golden_value(w);
                        let same = if w.is_nan() {
                            value.is_nan()
                        } else {
                            value.to_bits() == w.to_bits()
                        };
                        if !same {
                            fails.push(format!("{label}: {name} = {value:?}, golden {w:?}"));
                        }
                    }
                }
            }
            match excluded {
                // The manifest says Rust fails this fixture; a pass means the
                // exclusion is stale and must be removed from generate.py.
                Some(why) if fails.is_empty() => bad.push(format!(
                    "{label}: now passes; remove its rust exclusion ({why})"
                )),
                Some(_) => {}
                None => bad.extend(fails),
            }
        }
    }
    assert!(bad.is_empty(), "{}", bad.join("\n"));
}
