//! `native` and `interpreter` on one stencil document, bit for bit.
//!
//! What stood here was `ESS_TAPE_CHECK=N`: an environment variable that made
//! the first N calls of every taped scratch run BOTH the tape and the legacy
//! interpreter and assert bitwise-equal `dy` from inside the RHS itself. The
//! claim was worth keeping and the mechanism was not — a dual-run verifier is
//! a second way of selecting an evaluation strategy, which
//! `esm-libraries-spec.md` §2.5.10 retires in favour of naming the compiler.
//!
//! So the comparison is the same one, from the outside: the same document
//! built twice, once per compiler, integrated over the same save times, and
//! compared bit for bit. It runs on every `cargo test` rather than only when
//! someone remembers to set a variable, and it compares whole trajectories
//! rather than the first N right-hand sides.
//!
//! The document is a wrap + ghost stencil with a CONST-tier observed — enough
//! structure that a genuine divergence between the two paths would show.

#![cfg(all(feature = "solve", not(target_arch = "wasm32")))]

use std::collections::HashMap;

use earthsci_ast::{
    Alg, Compiler, EsmProblem, ProblemOptions, Rhs, SolveOptions, esm_problem, load_string, solve,
};

/// A wrap + ghost stencil with a CONST-tier observed — enough structure that
/// a genuine divergence between the two paths would be caught.
const MODEL: &str = r#"
    {
      "esm": "1.1.0",
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
                "op": "faq",
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
                "op": "faq",
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
                "op": "faq",
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

/// The stencil is 8 cells wide and every one of them is seeded at 1.0.
const N: usize = 8;

fn build(compiler: Compiler) -> EsmProblem {
    let file = load_string(MODEL).expect("load model");
    let u0: HashMap<String, f64> = (1..=N).map(|k| (format!("u[{k}]"), 1.0)).collect();
    esm_problem(
        &file,
        (0.0, 1.0),
        ProblemOptions {
            u0,
            rhs: Rhs::Always,
            compiler: Some(compiler),
            ..Default::default()
        },
    )
    .unwrap_or_else(|e| panic!("{} must build this document: {e}", compiler.as_str()))
}

#[test]
fn the_two_compilers_agree_on_the_whole_trajectory() {
    let opts = SolveOptions {
        alg: Alg::Erk,
        reltol: Some(1e-8),
        abstol: Some(1e-10),
        // Nine save times, where the switch checked nine calls.
        saveat: Some((0..9).map(|k| 0.125 * k as f64).collect()),
        ..Default::default()
    };

    let taped = build(Compiler::Native);
    assert_eq!(taped.compiler(), Compiler::Native);
    // The comparison is only worth making if the tape actually ran: under
    // `native` nothing may sit on the oracle, so the two arms are genuinely
    // different evaluators.
    assert!(taped.compiler_report().n_taped() > 0);
    assert_eq!(taped.compiler_report().n_oracle(), 0);

    let reference = build(Compiler::Interpreter);
    assert_eq!(reference.compiler_report().n_taped(), 0);

    let a = solve(&taped, &opts).expect("native solve");
    let b = solve(&reference, &opts).expect("interpreter solve");

    assert_eq!(a.state_variable_names, b.state_variable_names);
    assert_eq!(a.time.len(), b.time.len());
    assert!(a.time.len() > 1, "the document must have integrated");
    for (k, (x, y)) in a.time.iter().zip(b.time.iter()).enumerate() {
        assert_eq!(x.to_bits(), y.to_bits(), "time[{k}]");
    }
    for (r, (row_a, row_b)) in a.state.iter().zip(b.state.iter()).enumerate() {
        assert_eq!(row_a.len(), row_b.len(), "row {r}");
        for (k, (x, y)) in row_a.iter().zip(row_b.iter()).enumerate() {
            assert_eq!(
                x.to_bits(),
                y.to_bits(),
                "{} at t index {k}: native {x:e} vs interpreter {y:e}",
                a.state_variable_names[r]
            );
        }
        assert!(
            row_a.iter().all(|v| v.is_finite()),
            "{} left the reals",
            a.state_variable_names[r]
        );
    }
}
