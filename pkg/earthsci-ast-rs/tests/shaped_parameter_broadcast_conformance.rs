//! Cross-language conformance: a SCALAR on a shaped PARAMETER broadcasts over
//! its declared grid (esm-spec §6.3 "Inline array data", §6.6.2 "Shaped
//! values").
//!
//! Shared fixture + Julia-minted golden live under
//! `tests/conformance/shaped_parameter_broadcast/` (repo root); the Julia runner
//! (`conformance_shaped_parameter_broadcast_test.jl`) and the Python runner
//! (`test_shaped_parameter_broadcast_conformance.py`) gate the same golden.
//!
//! Rust left such a parameter in its positional scalar `params` vector, which
//! holds one f64 per parameter and so cannot carry "the one value applies to
//! every element". Every per-cell read then indexed a scalar — the `index(p, k)`
//! the document writes, and the gather `index_array_leaves_by_loops` inserts for
//! a bare whole-array `D(state)` right-hand side — which `eval_index` resolves
//! to `NaN`. The right-hand side went non-finite on its first evaluation and the
//! solve died at `t = 0` with `Exceeded maximum number of nonlinear solver
//! failures`, naming no parameter at all (EarthSciML/EarthSciAST#219).
//! `lower_inline_array_parameters` now broadcasts the scalar onto the grid and
//! lowers it into the same `const` observed the array spelling already took.

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::{Alg, SolveOptions, load_string};
use earthsci_ast::{InlineTestOptions, run_inline_tests_with_options};

use crate::common::tier::{GoldenCheck, Tier};

#[test]
fn shaped_parameter_broadcast_matches_golden() {
    Tier::open("shaped_parameter_broadcast").check_all(&GoldenCheck {
        by_test_id: true,
        ..Default::default()
    });
}

/// The reduced form of the issue's own reproducer: a bare whole-array
/// `D(theta) ~ ramp` over a shaped parameter with a scalar `default`. It is
/// NOT in the shared fixture because that spelling does not reach every
/// binding's array runtime, but it is the document #219 was filed with and it
/// exercises the OTHER Rust gather — the one the whole-array lowering inserts
/// rather than one the author wrote.
#[test]
fn bare_whole_array_derivative_over_a_broadcast_parameter() {
    let text = r#"{
      "esm": "2.0.0",
      "metadata": { "name": "MinimalShapedColumn", "authors": ["conformance"] },
      "index_sets": { "lev": { "kind": "interval", "size": 4 } },
      "models": {
        "Column": {
          "variables": {
            "ramp":  { "type": "parameter", "units": "K/s", "default": 1.0, "shape": ["lev"] },
            "theta": { "type": "unknown",   "units": "K",   "default": 1.0, "shape": ["lev"] }
          },
          "equations": [
            { "lhs": { "op": "D", "args": ["theta"], "wrt": "t" }, "rhs": "ramp" }
          ],
          "tests": [
            {
              "id": "theta_ramps",
              "time_span": { "start": 0.0, "end": 1.0 },
              "tolerance": { "abs": 1e-5, "rel": 1e-6 },
              "assertions": [
                { "variable": "theta", "time": 1.0, "coords": { "lev": 2 }, "expected": 2.0 }
              ]
            }
          ]
        }
      }
    }"#;
    let file = load_string(text).expect("document loads");
    let opts = SolveOptions {
        alg: Alg::Erk,
        reltol: Some(1e-12),
        abstol: Some(1e-14),
        ..Default::default()
    };
    let results = run_inline_tests_with_options(
        &file,
        &InlineTestOptions {
            model_name: Some("Column".to_string()),
            solve: opts.clone(),
            ..Default::default()
        },
        None,
    );
    assert_eq!(results.len(), 1);
    let r = &results[0];
    assert!(r.passed, "{}", r.message);
    let actual = r.actual.expect("actual");
    assert!(
        (actual - 2.0).abs() < 1e-9,
        "theta[2](1) = {actual}, want 2.0"
    );
}
