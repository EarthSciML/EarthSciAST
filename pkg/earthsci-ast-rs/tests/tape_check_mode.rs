//! `ESS_TAPE_CHECK=N` dual-path verification mode (Step 3b). Own test binary,
//! single test: the count is read once per process through a `OnceLock`.
//!
//! With the variable set, the first N calls of every taped scratch run BOTH
//! the legacy interpreter and the tape and assert bitwise-equal `dy` inside
//! `evaluate_rhs_with_scratch` itself. The test drives more calls than N so
//! both the checking and the post-check (tape-only) phases execute — and a
//! full `simulate` runs under the same regime.

#![cfg(not(target_arch = "wasm32"))]

use std::collections::HashMap;

use earthsci_ast::simulate_array::{ArrayCompiled, RhsStats};
use earthsci_ast::{SimulateOptions, SolverChoice, load, simulate};

/// A wrap + ghost stencil with a CONST-tier observed — enough structure that
/// a genuine divergence between the two paths would be caught.
const MODEL: &str = r#"
    {
      "esm": "1.0.0",
      "metadata": {
        "name": "tape_check_mode"
      },
      "models": {
        "M": {
          "variables": {
            "u": {
              "type": "unknown",
              "shape": [
                "i"
              ]
            },
            "g": {
              "type": "unknown",
              "shape": [
                "i"
              ]
            }
          },
          "equations": [
            {
              "lhs": {
                "op": "aggregate",
                "args": [],
                "output_idx": [
                  "i"
                ],
                "expr": {
                  "op": "D",
                  "args": [
                    {
                      "op": "index",
                      "args": [
                        "u",
                        "i"
                      ]
                    }
                  ],
                  "wrt": "t"
                },
                "ranges": {
                  "i": [
                    1,
                    8
                  ]
                }
              },
              "rhs": {
                "op": "aggregate",
                "args": [],
                "output_idx": [
                  "i"
                ],
                "ranges": {
                  "i": [
                    1,
                    8
                  ]
                },
                "expr": {
                  "op": "+",
                  "args": [
                    {
                      "op": "index",
                      "args": [
                        "u",
                        {
                          "op": "-",
                          "args": [
                            "i",
                            1
                          ]
                        }
                      ]
                    },
                    {
                      "op": "*",
                      "args": [
                        -2.0,
                        {
                          "op": "index",
                          "args": [
                            "u",
                            "i"
                          ]
                        }
                      ]
                    },
                    {
                      "op": "index",
                      "args": [
                        "u",
                        {
                          "op": "+",
                          "args": [
                            "i",
                            1
                          ]
                        }
                      ]
                    },
                    {
                      "op": "index",
                      "args": [
                        "g",
                        "i"
                      ]
                    }
                  ]
                }
              }
            },
            {
              "lhs": "g",
              "rhs": {
                "op": "aggregate",
                "args": [],
                "output_idx": [
                  "i"
                ],
                "ranges": {
                  "i": [
                    1,
                    8
                  ]
                },
                "expr": {
                  "op": "sin",
                  "args": [
                    {
                      "op": "*",
                      "args": [
                        0.5,
                        "i"
                      ]
                    }
                  ]
                }
              }
            }
          ]
        }
      }
    }
    "#;

#[test]
fn ess_tape_check_runs_both_paths_without_panicking() {
    unsafe { std::env::set_var("ESS_TAPE_CHECK", "5") };

    let file = load(MODEL).expect("load model");
    let compiled = ArrayCompiled::from_file(&file).expect("compile model");
    let n = compiled.state_variable_names().len();
    let params = compiled.debug_resolve_params(&HashMap::new());
    let mut scratch = compiled.debug_new_scratch_taped();
    assert!(scratch.has_tape());
    let mut dy = vec![0.0f64; n];
    let mut stats = RhsStats::default();
    // 9 calls: 5 checked (both paths, asserted bitwise inside), 4 tape-only.
    for step in 0..9 {
        let state: Vec<f64> = (0..n)
            .map(|k| (0.4 * k as f64 + 0.1 * step as f64).cos())
            .collect();
        compiled.debug_eval_rhs_into(
            &state,
            0.1 * step as f64,
            &params,
            &mut dy,
            &mut scratch,
            &mut stats,
        );
    }
    assert!(stats.taped_rules > 0);

    // And a real solve under check mode must complete (its first 5 RHS calls
    // are dual-path verified inside the closure).
    let opts = SimulateOptions {
        solver: SolverChoice::Erk,
        reltol: 1e-8,
        abstol: 1e-10,
        output_times: Some(vec![0.5, 1.0]),
        ..Default::default()
    };
    let ics: HashMap<String, f64> = (1..=n).map(|k| (format!("u[{k}]"), 1.0)).collect();
    let sol = simulate(&file, (0.0, 1.0), &HashMap::new(), &ics, &opts)
        .expect("checked simulate must run");
    assert!(
        sol.state
            .iter()
            .all(|row| row.iter().all(|v| v.is_finite()))
    );
}
