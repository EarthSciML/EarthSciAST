//! esm-spec §4.3.4: the shape of a variable declared with no `shape` whose
//! value is an array on one `ifelse` arm and a scalar on the other is decided
//! at build, before anything is evaluated, and both compilers agree on it.
//!
//! * `tests/conformance/native_model_shapes/fixtures/ifelse_gathered_scalar_*`
//!   — the reseact form, `X = ifelse(lev < 2, F / D, 0.0)` with `D` a gather
//!   from a `const` table — on the default route (the build-pipeline route is
//!   `native_model_shapes_conformance`).
//! * `tests/conformance/native_model_shapes/fixtures/ifelse_calendar_scalar_*`
//!   — the same form with the scalar a calendar field (`hour`, `month` of
//!   `esm:std/calendar.esm`) or a scalar `const` node (issue #664).
//! * `tests/conformance/native_model_shapes/runtime_data/ifelse_data_fed_unshaped.esm`
//!   — a data-fed `F` declared with no `shape` whose provider delivers a
//!   three-element array: `X` takes the data's shape on both arms, read by a
//!   state's right-hand side.
//!
//! Julia mirrors both with the same documents and values.

#![cfg(not(target_arch = "wasm32"))]

use std::collections::HashMap;

use earthsci_ast::provider::{DataProvider, ProviderError};
use earthsci_ast::{
    Compiler, InlineTestOptions, ProblemOptions, SolveOptions, esm_problem,
    run_inline_tests_with_options,
};
use ndarray::{ArrayD, IxDyn};
use serde_json::{Value, json};

use crate::common;

const COMPILERS: [Compiler; 2] = [Compiler::Interpreter, Compiler::Native];

#[test]
fn gathered_scalar_arm_takes_the_array_shape_on_the_default_route() {
    scalar_arm_fixtures_agree("ifelse_gathered_scalar", "IfelseGatheredScalar");
}

/// The scalar is a calendar field of `esm:std/calendar.esm` (`hour`, `month`,
/// whose bodies compare against unit-bearing `const` nodes), or a scalar
/// `const` node itself: issue #664 as reseact's NEI2016 observeds hit it.
#[test]
fn calendar_scalar_arm_takes_the_array_shape_on_the_default_route() {
    scalar_arm_fixtures_agree("ifelse_calendar_scalar", "IfelseCalendarScalar");
}

/// Both variants of a `native_model_shapes` fixture pair pass under both
/// compilers, native equal to the interpreter bit for bit.
fn scalar_arm_fixtures_agree(stem: &str, model: &str) {
    for kind in ["static", "dynamic"] {
        let rel = format!("conformance/native_model_shapes/fixtures/{stem}_{kind}.esm");
        let file = common::load_repo_fixture(&rel);
        let run = |compiler| {
            let opts = InlineTestOptions {
                model_name: Some(model.to_string()),
                solve: SolveOptions {
                    alg: earthsci_ast::Alg::Erk,
                    reltol: Some(1e-12),
                    abstol: Some(1e-14),
                    ..Default::default()
                },
                compiler: Some(compiler),
                ..Default::default()
            };
            run_inline_tests_with_options(&file, &opts)
        };
        let [interp, native] = COMPILERS.map(run);
        assert!(!interp.is_empty(), "{kind}: no assertions");
        assert_eq!(interp.len(), native.len(), "{kind}");
        for (i, n) in interp.iter().zip(&native) {
            let at = format!("{kind} #{} ({})", i.assertion_idx, i.variable);
            assert!(i.passed, "{at}: interpreter: {}", i.message);
            assert!(n.passed, "{at}: native: {}", n.message);
            assert_eq!(
                i.actual.map(f64::to_bits),
                n.actual.map(f64::to_bits),
                "{at}: native {:?}, interpreter {:?}",
                n.actual,
                i.actual
            );
        }
    }
}

/// A const provider delivering `F`.
struct FixedF;

const F_DATA: [f64; 3] = [1.5, -2.0, 0.75];

impl DataProvider for FixedF {
    fn sample(&mut self) -> Result<ArrayD<f64>, ProviderError> {
        let a = ArrayD::from_shape_vec(IxDyn(&[3]), F_DATA.to_vec()).expect("shape");
        Ok(a)
    }
    fn refresh(&mut self, _t: f64) -> Result<Option<ArrayD<f64>>, ProviderError> {
        Ok(None)
    }
    fn refresh_times(&self) -> Vec<f64> {
        Vec::new()
    }
}

fn data_fed_doc() -> Value {
    let path = common::repo_fixture(
        "conformance/native_model_shapes/runtime_data/ifelse_data_fed_unshaped.esm",
    );
    serde_json::from_str(&std::fs::read_to_string(&path).expect("read")).expect("parse")
}

fn problem(doc: &Value, compiler: Compiler) -> earthsci_ast::EsmProblem {
    esm_problem(
        doc,
        (0.0, 1.0),
        ProblemOptions {
            compiler: Some(compiler),
            providers: HashMap::from([(
                "F".to_string(),
                Box::new(FixedF) as Box<dyn DataProvider>,
            )]),
            ..Default::default()
        },
    )
    .unwrap_or_else(|e| panic!("{compiler:?}: builds: {e}"))
}

/// The rules read by a state's right-hand side,
/// `D(acc[i]) = X_on[i] + 10 X_off[i] + 100 X_rev_on[i] + 1000 X_rev_off[i]`
/// from 0, so `acc(1)` is `101 (2 F) + 1010 (0.25)` only when every `X` is a
/// three-element array holding its own arm, on both compilers to the bit. (A
/// state-free document is built by the static backend, which takes no
/// providers.)
#[cfg(feature = "solve")]
#[test]
fn unshaped_data_fed_parameter_gives_its_data_shape_to_a_state_reader() {
    use earthsci_ast::solve;
    let mut doc = data_fed_doc();
    let m = &mut doc["models"]["IfelseDataFed"];
    m["variables"]["acc"] =
        json!({"type": "unknown", "units": "1", "shape": ["cell"], "default": 0.0});
    let at = |x: &str| json!({"op": "index", "args": [x, "i"]});
    let over = |e: Value| json!({"op": "faq", "args": [], "output_idx": ["i"], "ranges": {"i": {"from": "cell"}}, "expr": e});
    m["equations"]
        .as_array_mut()
        .expect("equations")
        .push(json!({
            "lhs": over(json!({"op": "D", "args": [at("acc")], "wrt": "t"})),
            "rhs": over(json!({"op": "+", "args": [at("X_on"),
                {"op": "*", "args": [10.0, at("X_off")]},
                {"op": "*", "args": [100.0, at("X_rev_on")]},
                {"op": "*", "args": [1000.0, at("X_rev_off")]}]}))
        }));
    let opts = SolveOptions {
        alg: earthsci_ast::Alg::Erk,
        reltol: Some(1e-12),
        abstol: Some(1e-14),
        saveat: Some(vec![1.0]),
        ..Default::default()
    };
    let mut got = Vec::new();
    for compiler in COMPILERS {
        let sol = solve(&problem(&doc, compiler), &opts)
            .unwrap_or_else(|e| panic!("{compiler:?}: solves: {e}"));
        let k = sol
            .state_variable_names
            .iter()
            .position(|n| n.ends_with("acc[1]") || n.ends_with("acc"))
            .unwrap_or_else(|| panic!("{compiler:?}: {:?}", sol.state_variable_names));
        let acc: Vec<f64> = (k..k + 3)
            .map(|j| *sol.state[j].last().expect("t = 1"))
            .collect();
        for (c, (a, f)) in acc.iter().zip(F_DATA).enumerate() {
            let w = 101.0 * (2.0 * f) + 1010.0 * 0.25;
            assert!(
                (a - w).abs() < 1e-9,
                "{compiler:?} acc[{}] = {a}, want {w}",
                c + 1
            );
        }
        got.push(acc.iter().map(|v| v.to_bits()).collect::<Vec<_>>());
    }
    assert_eq!(got[0], got[1], "native differs from the interpreter");
}
