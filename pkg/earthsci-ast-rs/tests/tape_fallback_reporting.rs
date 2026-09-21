//! A rule the tape could not compile must be NAMED on the way out.
//!
//! A fallback rule is evaluated by the per-cell oracle, which re-walks the rule
//! body once per grid cell per RHS call. The numbers are bit-identical to the
//! vectorized path — that is the whole point of the fallback — so nothing about
//! the *result* betrays it, while the runtime can differ by three to four
//! orders of magnitude and, unlike the taped path, grows with the cell count.
//! Before this, the tape build knew exactly which rule and why, and threw it
//! away at both production build sites; from a caller's seat (especially a
//! browser one, with no native `tape_report` to run) a model that would not
//! finish was indistinguishable from a model that was merely big.
//!
//! Pinned here:
//!
//!   1. a surviving fallback reaches [`SolutionMetadata::tape_fallbacks`] with
//!      its rule name and its reason;
//!   2. a fully taped model reports an EMPTY list — the negative control,
//!      without which (1) would pass on a field that is always populated.

#![cfg(not(target_arch = "wasm32"))]

use std::collections::HashMap;

use earthsci_ast::{SolveOptions, load_string};

/// `k` is a CAUSAL SELF-REFERENCE (esm-spec §4.3.1.1): `k[i]` reads `k[i-1]`,
/// with the required `ifelse` base-case guard. Its cells are not independent,
/// so CONFORMANCE_SPEC §5.19.2 forbids the tape (whose scheduler reorders and
/// batches) from ever lowering it — which is what makes it a durable fixture
/// here: this file must keep falling back for the assertion to mean anything.
///
/// It used to be an array-valued `const`, which the tape lowered as of the
/// phase-2 `Instr::ConstArray` work; the overlay still declines that one
/// (`vec_coverage_frontier::frontier_array_valued_const_falls_back`), but the
/// tape no longer does, so it stopped exercising this path.
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
                        2.0
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

/// Through `compile_array`, NOT through `esm_problem`.
///
/// `esm_problem`'s default compiler is `Compiler::Native`, which is strict: a
/// rule the tape cannot lower is a construction error naming the rule
/// (`compiler_refused_rule`, API_SPEC §5.8), so a Problem with a SURVIVING
/// fallback cannot exist. `SolutionMetadata::tape_fallbacks` is kept for
/// compatibility and is still populated on the extension-seam entry points —
/// `compile_array` and the `ArrayCompiled::solve` beneath it — which keep the
/// historical routing: the tape where it lowers, the per-cell oracle where it
/// does not. That is the path this file gates, and the assertions below are
/// unchanged.
fn run(json: &str) -> earthsci_ast::Solution {
    let file = load_string(json).expect("fixture loads");
    let opts = SolveOptions::default();
    let compiled = earthsci_ast::compile_array(file).expect("fixture compiles");
    compiled
        .solve((0.0, 0.1), &HashMap::new(), &HashMap::new(), &opts)
        .expect("fixture simulates")
}

#[test]
fn a_surviving_fallback_is_named_in_the_solution_metadata() {
    let sol = run(FALLBACK_MODEL);
    let fb = &sol.metadata.tape_fallbacks;
    assert!(
        !fb.is_empty(),
        "the causal-recurrence rule falls back, so the solve must report it; \
         got an empty list. If this fixture became tapeable, that is good \
         news — replace it with a construct that is still on the frontier \
         (see tests/vec_coverage_frontier.rs) rather than deleting the test."
    );
    for (rule, reason) in fb {
        assert!(!rule.is_empty(), "every fallback must name its rule");
        assert!(
            !reason.is_empty(),
            "fallback on `{rule}` reached the caller with no reason"
        );
    }
    assert!(
        fb.iter().any(|(_, reason)| reason.contains("recurrence")),
        "the reason must identify the unsupported construct: {fb:?}"
    );
}

#[test]
fn a_fully_taped_model_reports_no_fallbacks() {
    let sol = run(TAPED_MODEL);
    assert!(
        sol.metadata.tape_fallbacks.is_empty(),
        "nothing in this model is unvectorizable, so the list must be empty: {:?}",
        sol.metadata.tape_fallbacks
    );
    // The negative control is only worth anything if the model actually ran.
    assert!(sol.time.len() > 1, "the fixture must have integrated");
}
