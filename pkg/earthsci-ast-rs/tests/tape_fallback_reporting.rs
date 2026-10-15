//! A rule the tape could not compile must be NAMED on the way out — as a
//! refusal, not as a slower solve.
//!
//! A model with such a rule has no tape. Running it anyway would mean running
//! the WHOLE model on the interpreter, whose cost grows far faster with the
//! cell count than the tape's, with nothing about the result to betray it;
//! from a caller's seat (especially a browser one, with no native
//! `tape_report` to run) a model that would not finish would be
//! indistinguishable from a model that was merely big. So the historical
//! routing (`compile_array` and the `ArrayCompiled::solve` beneath it)
//! refuses, as the strict compilers do at construction.
//!
//! Pinned here:
//!
//!   1. a declined rule is a `compiler_refused_rule` error naming the rule
//!      and the reason;
//!   2. a fully taped model solves, and its `SolutionMetadata::tape_fallbacks`
//!      (kept for the metadata shape) is empty.

#![cfg(not(target_arch = "wasm32"))]

use std::collections::HashMap;

use earthsci_ast::{CompileError, SimulateError, SolveOptions, load_string};

/// `k` is a CAUSAL SELF-REFERENCE (esm-spec §4.3.1.1) whose self-read sits
/// inside an ARRAY-VALUED part of its cell body: `k[i] = (j ↦ k[i-1]·j)[2]`,
/// a nested `faq` over `j`. The tape lowers a recurrence as a sweep that
/// evaluates each self-read one scalar cell at a time, so this one declines.
///
/// It used to be an array-valued `const`, and then a plain recurrence; the
/// tape lowers both now, so neither exercises this path any more.
const FALLBACK_MODEL: &str = r#"
    {
      "esm": "1.1.0",
      "metadata": {
        "name": "fallback_reporting"
      },
      "index_sets": {
        "c": {
          "kind": "interval",
          "size": 3
        }
      },
      "models": {
        "M": {
          "variables": {
            "psi": {
              "type": "unknown",
              "shape": [
                "c"
              ],
              "default": 1.0
            },
            "k": {
              "type": "unknown",
              "shape": [
                "c"
              ]
            },
            "a": {
              "type": "unknown",
              "shape": [
                "c"
              ]
            }
          },
          "equations": [
            {
              "lhs": {
                "op": "D",
                "args": [
                  "psi"
                ],
                "wrt": "t"
              },
              "rhs": {
                "op": "-",
                "args": [
                  "a"
                ]
              }
            },
            {
              "lhs": "k",
              "rhs": {
                "op": "faq",
                "args": [],
                "output_idx": [
                  "i"
                ],
                "ranges": {
                  "i": [
                    1,
                    3
                  ]
                },
                "expr": {
                  "op": "ifelse",
                  "args": [
                    {
                      "op": "<=",
                      "args": [
                        "i",
                        1
                      ]
                    },
                    1.0,
                    {
                      "op": "index",
                      "args": [
                        {
                          "op": "faq",
                          "args": [],
                          "output_idx": ["j"],
                          "ranges": {"j": [1, 2]},
                          "expr": {
                            "op": "*",
                            "args": [
                              {
                                "op": "index",
                                "args": [
                                  "k",
                                  {
                                    "op": "-",
                                    "args": [
                                      "i",
                                      1
                                    ]
                                  }
                                ]
                              },
                              "j"
                            ]
                          }
                        },
                        2
                      ]
                    }
                  ]
                }
              }
            },
            {
              "lhs": "a",
              "rhs": {
                "op": "+",
                "args": [
                  "psi",
                  "k"
                ]
              }
            }
          ]
        }
      }
    }
    "#;

/// The same physics with the constant table written as an arithmetic ramp over
/// the output index instead of an array literal: fully vectorizable, hence
/// fully taped.
const TAPED_MODEL: &str = r#"
    {
      "esm": "1.1.0",
      "metadata": {
        "name": "taped_reporting"
      },
      "index_sets": {
        "c": {
          "kind": "interval",
          "size": 3
        }
      },
      "models": {
        "M": {
          "variables": {
            "psi": {
              "type": "unknown",
              "shape": [
                "c"
              ],
              "default": 1.0
            },
            "k": {
              "type": "unknown",
              "shape": [
                "c"
              ]
            },
            "a": {
              "type": "unknown",
              "shape": [
                "c"
              ]
            }
          },
          "equations": [
            {
              "lhs": {
                "op": "D",
                "args": [
                  "psi"
                ],
                "wrt": "t"
              },
              "rhs": {
                "op": "-",
                "args": [
                  "a"
                ]
              }
            },
            {
              "lhs": "k",
              "rhs": {
                "op": "faq",
                "args": [],
                "output_idx": [
                  "i"
                ],
                "ranges": {
                  "i": [
                    1,
                    3
                  ]
                },
                "expr": "i"
              }
            },
            {
              "lhs": "a",
              "rhs": {
                "op": "+",
                "args": [
                  "psi",
                  "k"
                ]
              }
            }
          ]
        }
      }
    }
    "#;

/// Through `compile_array`, NOT through `esm_problem`: `esm_problem`'s
/// compilers refuse a declined rule at construction, which
/// `tests/compiler_selection.rs` pins; this file pins the historical routing.
fn run(json: &str) -> Result<earthsci_ast::Solution, SimulateError> {
    let file = load_string(json).expect("fixture loads");
    let opts = SolveOptions::default();
    let compiled = earthsci_ast::compile_array(file).expect("fixture compiles");
    compiled.solve((0.0, 0.1), &HashMap::new(), &HashMap::new(), &opts)
}

#[test]
fn a_declined_rule_is_a_named_refusal() {
    let err = match run(FALLBACK_MODEL) {
        Ok(_) => panic!(
            "the causal-recurrence rule does not lower, so the solve must refuse. \
             If this fixture became tapeable, that is good news — replace it with \
             a construct that is still on the frontier (see \
             tests/vec_coverage_frontier.rs) rather than deleting the test."
        ),
        Err(e) => e,
    };
    let SimulateError::Compile(CompileError::CompilerRefusedRule { rule, reason, .. }) = &err
    else {
        panic!("expected compiler_refused_rule, got {err:?}");
    };
    assert!(!rule.is_empty(), "the refusal must name its rule");
    assert!(
        reason.contains("recurrence"),
        "the reason must identify the unsupported construct: {reason}"
    );
}

#[test]
fn a_fully_taped_model_reports_no_fallbacks() {
    let sol = run(TAPED_MODEL).expect("fixture simulates");
    assert!(
        sol.metadata.tape_fallbacks.is_empty(),
        "nothing in this model is unvectorizable, so the list must be empty: {:?}",
        sol.metadata.tape_fallbacks
    );
    // The negative control is only worth anything if the model actually ran.
    assert!(sol.time.len() > 1, "the fixture must have integrated");
}
