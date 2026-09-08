//! A 0-D parameter whose `default` is inline ARRAY data must not enter the
//! build pipeline's scalar scope bound to a fabricated `0.0`.
//!
//! `prepare::scalar_params` selected on `default.is_some()` but read the value
//! with `default_scalar()`, which is `None` for array data — and the
//! `.unwrap_or(0.0)` underneath supplied a zero the document never states. Every
//! expression reading such a parameter then evaluated against that zero and
//! returned a plausible wrong number.
//!
//! Found while diagnosing issue #207. It is the mirror image of issue #219 (a
//! SCALAR default on a SHAPED parameter, which must broadcast rather than be
//! dropped) — same silent-zero class, opposite direction.

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::{ProblemOptions, esm_problem, observed_field};
use serde_json::{Value, json};

/// `k` declares no `shape`, so its array `default` has no shape to fill; `y`
/// reads it. A scope that binds `k` to 0.0 answers `y = 0`.
fn doc() -> Value {
    json!({
        "esm": "1.0.0",
        "metadata": {"name": "scalar_param_array_default"},
        "models": {"M": {
            "variables": {
                "k": {"type": "parameter", "default": [2.0, 3.0]},
                "y": {"type": "unknown"}
            },
            "equations": [
                {"lhs": "y", "rhs": {"op": "*", "args": ["k", 10.0]}}
            ]
        }}
    })
}

#[test]
fn an_array_default_on_a_scalar_parameter_is_not_a_zero() {
    let built = esm_problem(
        &doc(),
        (0.0, 0.0),
        ProblemOptions {
            model_name: Some("M".into()),
            build_pipeline: true,
            ..Default::default()
        },
    );
    let Ok(prob) = built else {
        // A named build failure is a perfectly good outcome: the point is that
        // the document does not come back with a fabricated answer.
        return;
    };
    let y: Vec<f64> = match observed_field(&prob, "y") {
        Some(a) => a.iter().copied().collect(),
        // No field at all is also fail-closed.
        None => return,
    };
    assert!(
        !y.iter().any(|v| *v == 0.0),
        "`k` has no scalar default, so nothing may bind it to 0.0 — got y = {y:?}"
    );
}
