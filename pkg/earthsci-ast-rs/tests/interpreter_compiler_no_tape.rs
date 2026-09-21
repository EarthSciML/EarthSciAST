//! `interpreter` reaches the per-cell oracle BY NAME (API_SPEC §5.8).
//!
//! What stood here was an `ESS_TAPE_DISABLE=1` kill switch: an environment
//! variable that turned the tape off wholesale, so that the oracle could be
//! reached and compared against. `esm-libraries-spec.md` §2.5.10 retires every
//! switch whose effect is to select an evaluation strategy — two ways to say
//! the same thing is how an environment and an argument come to disagree — so
//! the arms are now the two compilers, on the same document, and the
//! assertions are the ones the switch carried: nothing runs through the tape
//! under `interpreter`, the solve completes and lands on the closed form, and
//! `native` answers bit for bit the same.

#![cfg(all(feature = "solve", not(target_arch = "wasm32")))]

use std::collections::HashMap;

use earthsci_ast::{
    Alg, Compiler, EsmProblem, ProblemOptions, Rhs, SolveOptions, esm_problem, load_string, solve,
};

const MODEL: &str = r#"
    {
      "esm": "1.1.0",
      "metadata": {
        "name": "tape_kill_switch"
      },
      "models": {
        "Decay": {
          "variables": {
            "u": {
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
                    6
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
                    6
                  ]
                },
                "expr": {
                  "op": "*",
                  "args": [
                    -0.5,
                    {
                      "op": "index",
                      "args": [
                        "u",
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

/// The document's own decay constant: `u(t) = u0 · e^(−t/2)`.
const HALF_RATE: f64 = -0.5;
/// Every state element is seeded here, so the closed form below is one number.
const U0: f64 = 2.0;

fn build(compiler: Compiler) -> EsmProblem {
    let file = load_string(MODEL).expect("load model");
    let n = 6;
    let u0: HashMap<String, f64> = (1..=n).map(|k| (format!("u[{k}]"), U0)).collect();
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

fn opts() -> SolveOptions {
    SolveOptions {
        alg: Alg::Erk,
        reltol: Some(1e-10),
        abstol: Some(1e-12),
        saveat: Some(vec![0.25, 0.5, 1.0]),
        ..Default::default()
    }
}

#[test]
fn the_interpreter_puts_every_rule_on_the_per_cell_oracle() {
    let prob = build(Compiler::Interpreter);
    assert_eq!(prob.compiler(), Compiler::Interpreter);
    let report = prob.compiler_report();
    assert!(!report.rules().is_empty(), "the document has rules");
    assert_eq!(report.n_taped(), 0, "the interpreter compiles no program");
    assert_eq!(report.n_oracle(), report.rules().len());
    assert_eq!(report.fused_groups(), 0);
    for r in report.rules() {
        assert_eq!(r.tier, "oracle", "{}", r.rule);
        // By design, not by decline: nothing was attempted and refused.
        assert!(r.reason.is_none(), "{}", r.rule);
    }
}

/// The negative control the switch could not state: with the tape ON, the same
/// document has nothing on the oracle. Without it, the assertion above would
/// pass on a build that never taped anything to begin with.
#[test]
fn native_tapes_the_same_document_whole() {
    let prob = build(Compiler::Native);
    assert_eq!(prob.compiler(), Compiler::Native);
    let report = prob.compiler_report();
    assert!(report.n_taped() > 0, "native IS the tape");
    assert_eq!(report.n_oracle(), 0, "a native build has no rule off the tape");
}

#[test]
fn the_two_compilers_integrate_the_document_to_the_same_bits() {
    let reference = solve(&build(Compiler::Interpreter), &opts()).expect("interpreter solve");
    let taped = solve(&build(Compiler::Native), &opts()).expect("native solve");

    assert_eq!(reference.state_variable_names, taped.state_variable_names);
    assert_eq!(reference.time.len(), taped.time.len());
    for (k, (a, b)) in reference.time.iter().zip(taped.time.iter()).enumerate() {
        assert_eq!(a.to_bits(), b.to_bits(), "time[{k}]");
    }
    for (r, (row_a, row_b)) in reference.state.iter().zip(taped.state.iter()).enumerate() {
        for (k, (a, b)) in row_a.iter().zip(row_b.iter()).enumerate() {
            assert_eq!(
                a.to_bits(),
                b.to_bits(),
                "{} at t index {k}: interpreter {a:e} vs native {b:e}",
                reference.state_variable_names[r]
            );
        }
    }

    // And the numbers are the document's own closed form, so an agreement on
    // two wrong trajectories cannot read as a pass.
    let ti = reference.time.len() - 1;
    let want = U0 * HALF_RATE.exp();
    for (r, row) in reference.state.iter().enumerate() {
        assert!(
            (row[ti] - want).abs() < 1e-6,
            "{}(1) = {} != {want}",
            reference.state_variable_names[r],
            row[ti]
        );
    }
}
