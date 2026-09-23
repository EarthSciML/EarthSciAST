//! The solver plumbing and the run vocabulary around the array runtime.
//!
//! The one Rust interpreter is [`crate::simulate_array`] — its tape under
//! `native` / `xla` and its per-cell oracle under `interpreter` (API_SPEC
//! §5.8). This module holds what every solve of it shares: the public option
//! and result vocabulary ([`Alg`], [`SolveOptions`], [`Solution`]), the
//! [`SimulateError`] surface, the diffsol step loop, esm-spec §6.6.2
//! caller-key canonicalization, and the routing that builds the runtime from a
//! document.
//!
//! ## Scope
//!
//! - **ODE only.** A system still carrying a spatial independent variable
//!   holds an undiscretized operator and is refused with
//!   [`CompileError::UnsupportedDimensionalityError`].
//! - **No event handling.** Models with non-empty `continuous_events` /
//!   `discrete_events` return [`CompileError::UnsupportedConstruct`]
//!   (esm-spec §9.6.6 `unsupported_construct`).
//! - **Both targets.** diffsol's Faer backend is pure Rust and cross-compiles to
//!   wasm32 (spike S1), so this module is compiled for the browser too.
//!
//! ## Usage
//!
//! The public entry point is the EsmProblem/`solve` surface in
//! [`crate::problem`] (`esm-libraries-spec.md` §2.5):
//!
//! ```no_run
//! use earthsci_ast::{ProblemOptions, SolveOptions, esm_problem, load_string, solve};
//!
//! let file = load_string(r#"{"esm":"1.0.0","metadata":{},"models":{}}"#).unwrap();
//! let prob = esm_problem(&file, (0.0, 1.0), ProblemOptions::default()).unwrap();
//! let _ = solve(&prob, &SolveOptions::default());
//! ```
//!
//! ## Module layout
//!
//! `errors` (the [`SimulateError`] surface), `api` (the public option and
//! result vocabulary), `driver` (the solver step loop and the routing into
//! [`crate::simulate_array`]), `override_keys` (esm-spec §6.6.2 caller-key
//! canonicalization), and `lhs` (the observed-unknown report hosts build a run
//! UI from). Every item is re-exported here, so `crate::simulate::*` paths
//! resolve unchanged.

use crate::flatten::{FlattenedSystem, flatten};
use crate::types::EsmFile;
use std::collections::{HashMap, HashSet};
use thiserror::Error;

// The solver is OPTIONAL (esm-libraries-spec §2.5.9): building a `EsmProblem`
// never needs it, so `diffsol` sits behind the `solve` Cargo feature and every
// item that touches it is gated the same way.
#[cfg(feature = "solve")]
use diffsol::{OdeSolverMethod, Op, VectorHost};

mod api;
mod driver;
mod errors;
mod lhs;
pub(crate) mod override_keys;

pub use api::*;
pub use driver::*;
pub use errors::*;
pub use lhs::*;
pub(crate) use override_keys::*;

// ============================================================================
// Inline unit tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use crate::problem::{EsmProblem, ProblemOptions, esm_problem, solve};

    /// Build `json` into an [`EsmProblem`] over `[0, 1]` with the parameter
    /// overrides `p` — the one route every document takes.
    fn problem_of(json: &str, p: HashMap<String, f64>) -> Result<EsmProblem, SimulateError> {
        let file = crate::parse::load_string(json).expect("parse fixture");
        esm_problem(
            &file,
            (0.0, 1.0),
            ProblemOptions {
                p,
                ..Default::default()
            },
        )
    }

    fn solution_with_rows(names: &[&str], namespace: Option<&str>) -> Solution {
        Solution {
            time: vec![0.0],
            state: names.iter().map(|_| vec![0.0]).collect(),
            state_variable_names: names.iter().map(|n| n.to_string()).collect(),
            retcode: ReturnCode::Success,
            metadata: SolutionMetadata {
                namespace: namespace.map(str::to_string),
                ..Default::default()
            },
        }
    }

    #[test]
    fn a_qualified_name_reaches_a_bare_row_only_through_its_own_namespace() {
        let sol = solution_with_rows(&["x", "North.u"], Some("M"));
        assert_eq!(sol.index_of("x"), Some(0));
        assert_eq!(sol.index_of("M.x"), Some(0));
        assert_eq!(sol.index_of("M.North.u"), Some(1));
        // Another model's `x`, a typo, or a bare row with no recorded
        // namespace is not this row.
        assert_eq!(sol.index_of("Other.x"), None);
        assert_eq!(sol.index_of("Typo.x"), None);
        let unnamed = solution_with_rows(&["x"], None);
        assert_eq!(unnamed.index_of("M.x"), None);
    }

    /// A cycle among the unknowns bare-LHS equations define must be rejected at
    /// construction (esm-0kt, esm-spec §4.9.6), with a diagnostic naming the
    /// variables on it.
    #[test]
    fn algebraic_cycle_rejected() {
        // Two algebraic states a, b form a cycle: a = b + 1, b = a * 2.
        // dx/dt = a is a non-cyclic ODE that anchors the system.
        let json = r#"
            {
              "esm": "1.0.0",
              "metadata": {
                "name": "TestFixture"
              },
              "models": {
                "M": {
                  "variables": {
                    "x": {
                      "type": "unknown",
                      "default": 0.0
                    },
                    "a": {
                      "type": "unknown",
                      "default": 1.0
                    },
                    "b": {
                      "type": "unknown",
                      "default": 1.0
                    }
                  },
                  "equations": [
                    {
                      "lhs": {
                        "op": "D",
                        "args": [
                          "x"
                        ],
                        "wrt": "t"
                      },
                      "rhs": "a"
                    },
                    {
                      "lhs": "a",
                      "rhs": {
                        "op": "+",
                        "args": [
                          "b",
                          1.0
                        ]
                      }
                    },
                    {
                      "lhs": "b",
                      "rhs": {
                        "op": "*",
                        "args": [
                          "a",
                          2.0
                        ]
                      }
                    }
                  ]
                }
              }
            }
            "#;
        let err = problem_of(json, HashMap::new()).expect_err("cycle must be rejected");
        let SimulateError::Compile(CompileError::ObservedCycle { cycle }) = &err else {
            panic!("expected an observed cycle, got: {err:?}");
        };
        assert!(
            cycle.iter().any(|v| v.ends_with('a')) && cycle.iter().any(|v| v.ends_with('b')),
            "the cycle should name both vars: {cycle:?}"
        );
    }

    /// A `fn`-op observed (`interp.linear` fuel-table lookup) of a 0-D model
    /// must evaluate through the closed-function registry — not NaN out.
    /// Regression for the coupled-fire blocker, where the callee `name` and the
    /// inline array arguments were dropped on the way to evaluation, so
    /// `interp.linear` poisoned every downstream state.
    #[test]
    fn fn_op_interp_linear_in_a_scalar_model() {
        // looked_up = interp.linear([10,20,40,80,160], [0,1,2,3,4], code);
        // dx/dt = looked_up, x(0) = 0. At code = 2.0 the lookup is the exact
        // knot 40.0, so x(1) = 40.0.
        let json = r#"
            {
              "esm": "1.0.0",
              "metadata": {
                "name": "FnFixture"
              },
              "models": {
                "M": {
                  "variables": {
                    "x": {
                      "type": "unknown",
                      "default": 0.0
                    },
                    "code": {
                      "type": "parameter",
                      "default": 2.0
                    },
                    "looked_up": {
                      "type": "unknown"
                    }
                  },
                  "equations": [
                    {
                      "lhs": {
                        "op": "D",
                        "args": [
                          "x"
                        ],
                        "wrt": "t"
                      },
                      "rhs": "looked_up"
                    },
                    {
                      "lhs": "looked_up",
                      "rhs": {
                        "op": "fn",
                        "name": "interp.linear",
                        "args": [
                          {
                            "op": "const",
                            "value": [
                              10.0,
                              20.0,
                              40.0,
                              80.0,
                              160.0
                            ],
                            "args": []
                          },
                          {
                            "op": "const",
                            "value": [
                              0.0,
                              1.0,
                              2.0,
                              3.0,
                              4.0
                            ],
                            "args": []
                          },
                          "code"
                        ]
                      }
                    }
                  ]
                }
              }
            }
            "#;
        let prob = problem_of(json, HashMap::new()).expect("build succeeds");
        // Explicit tolerances, not the defaults. The assertion below pins
        // D(1) to exp(-1) within 1e-6, which is a statement about the RHS
        // seeing the right G — not about how tightly the production default
        // integrates. `DEFAULT_RELTOL`/`DEFAULT_ABSTOL` are Julia's `1e-4`/
        // `1e-6` and leave ~4.6e-6 of truncation error over this interval,
        // which is larger than the thing being measured.
        let opts = SolveOptions {
            abstol: Some(1e-12),
            reltol: Some(1e-10),
            saveat: Some(vec![0.0, 1.0]),
            ..Default::default()
        };
        let sol = solve(&prob, &opts).expect("simulate succeeds");
        let x_idx = sol
            .state_variable_names
            .iter()
            .position(|n| n.ends_with("x"))
            .expect("x in solution");
        assert!(
            (sol.state[x_idx][1] - 40.0).abs() < 1e-6,
            "x(1) should be 40.0 (dx/dt = interp.linear(...,2.0) = 40), got {}",
            sol.state[x_idx][1]
        );

        // A different query point exercises the blend, not just a knot: at
        // code = 0.5 the lookup is 0.5*(10+20)... = 15.0.
        let mut params = HashMap::new();
        params.insert("M.code".to_string(), 0.5);
        let prob2 = problem_of(json, params).expect("build succeeds");
        let sol2 = solve(&prob2, &opts).expect("simulate succeeds");
        assert!(
            (sol2.state[x_idx][1] - 15.0).abs() < 1e-6,
            "x(1) should be 15.0 at code=0.5, got {}",
            sol2.state[x_idx][1]
        );
    }

    /// A `fn`-op with a *scalar* argument (`datetime.year`) exercises the
    /// `name`-threading fix independent of the array-arg materialization path.
    #[test]
    fn fn_op_datetime_scalar_arg() {
        // yr = datetime.year(946684800) = 2000 (2000-01-01T00:00:00Z).
        // dx/dt = yr, x(0) = 0, so x(1) = 2000.
        let json = r#"
            {
              "esm": "1.0.0",
              "metadata": {
                "name": "DatetimeFixture"
              },
              "models": {
                "M": {
                  "variables": {
                    "x": {
                      "type": "unknown",
                      "default": 0.0
                    },
                    "yr": {
                      "type": "unknown"
                    }
                  },
                  "equations": [
                    {
                      "lhs": {
                        "op": "D",
                        "args": [
                          "x"
                        ],
                        "wrt": "t"
                      },
                      "rhs": "yr"
                    },
                    {
                      "lhs": "yr",
                      "rhs": {
                        "op": "fn",
                        "name": "datetime.year",
                        "args": [
                          946684800.0
                        ]
                      }
                    }
                  ]
                }
              }
            }
            "#;
        let prob = problem_of(json, HashMap::new()).expect("build succeeds");
        // Explicit tolerances, not the defaults. The assertion below pins
        // D(1) to exp(-1) within 1e-6, which is a statement about the RHS
        // seeing the right G — not about how tightly the production default
        // integrates. `DEFAULT_RELTOL`/`DEFAULT_ABSTOL` are Julia's `1e-4`/
        // `1e-6` and leave ~4.6e-6 of truncation error over this interval,
        // which is larger than the thing being measured.
        let opts = SolveOptions {
            abstol: Some(1e-12),
            reltol: Some(1e-10),
            saveat: Some(vec![0.0, 1.0]),
            ..Default::default()
        };
        let sol = solve(&prob, &opts).expect("simulate succeeds");
        let x_idx = sol
            .state_variable_names
            .iter()
            .position(|n| n.ends_with("x"))
            .expect("x in solution");
        assert!(
            (sol.state[x_idx][1] - 2000.0).abs() < 1e-9,
            "x(1) should be 2000.0 (dx/dt = datetime.year = 2000), got {}",
            sol.state[x_idx][1]
        );
    }

    /// Algebraic states whose `default` does not satisfy the constraint at
    /// t=0 must be reconciled before integration starts (esm-0kt).
    /// Flatten a fixture and report its algebraic states, sorted for comparison.
    fn algebraic_names_of(json: &str) -> Vec<String> {
        let file = crate::parse::load_string(json).expect("parse fixture");
        let flat = crate::flatten(&file).expect("flatten fixture");
        let mut names = algebraic_state_names(&flat);
        names.sort();
        names
    }

    #[test]
    fn a_bare_lhs_state_is_algebraic_and_a_derivative_one_is_not() {
        let names = algebraic_names_of(
            r#"
                {
                  "esm": "1.0.0",
                  "metadata": {
                    "name": "TestFixture"
                  },
                  "models": {
                    "M": {
                      "variables": {
                        "D": {
                          "type": "unknown",
                          "default": 1.0
                        },
                        "G": {
                          "type": "unknown"
                        },
                        "k": {
                          "type": "parameter",
                          "default": 1.0
                        }
                      },
                      "equations": [
                        {
                          "lhs": {
                            "op": "D",
                            "args": [
                              "D"
                            ],
                            "wrt": "t"
                          },
                          "rhs": {
                            "op": "*",
                            "args": [
                              {
                                "op": "-",
                                "args": [
                                  "k"
                                ]
                              },
                              "G"
                            ]
                          }
                        },
                        {
                          "lhs": "G",
                          "rhs": "D"
                        }
                      ]
                    }
                  }
                }
                "#,
        );
        // Namespaced, as every caller needs it — the name that indexes `ic`.
        assert_eq!(names, vec!["M.G".to_string()]);
    }

    #[test]
    fn a_state_with_both_equations_is_differential() {
        // esm-y3n: the derivative wins. A host that missed this rule would hide
        // a genuinely settable initial condition from its Run UI.
        let names = algebraic_names_of(
            r#"
                {
                  "esm": "1.0.0",
                  "metadata": {
                    "name": "TestFixture"
                  },
                  "models": {
                    "M": {
                      "variables": {
                        "x": {
                          "type": "unknown",
                          "default": 1.0
                        },
                        "k": {
                          "type": "parameter",
                          "default": 1.0
                        }
                      },
                      "equations": [
                        {
                          "lhs": {
                            "op": "D",
                            "args": [
                              "x"
                            ],
                            "wrt": "t"
                          },
                          "rhs": "k"
                        },
                        {
                          "lhs": "x",
                          "rhs": "k"
                        }
                      ]
                    }
                  }
                }
                "#,
        );
        assert!(names.is_empty(), "derivative must win, got {names:?}");
    }

    #[test]
    fn a_bare_lhs_observed_unknown_is_reported() {
        // esm 1.0.0 unified the two declarations this test used to tell apart.
        // `obs` is defined by a bare-variable-LHS equation, which IS what makes
        // an unknown observed (esm-spec §6.3.1) — the same property that made
        // `G` an "algebraic state" before. Both are eliminable and neither may
        // be offered an IC field, so both are reported.
        let names = algebraic_names_of(
            r#"
                {
                  "esm": "1.0.0",
                  "metadata": {
                    "name": "TestFixture"
                  },
                  "models": {
                    "M": {
                      "variables": {
                        "x": {
                          "type": "unknown",
                          "default": 1.0
                        },
                        "obs": {
                          "type": "unknown"
                        },
                        "k": {
                          "type": "parameter",
                          "default": 1.0
                        }
                      },
                      "equations": [
                        {
                          "lhs": {
                            "op": "D",
                            "args": [
                              "x"
                            ],
                            "wrt": "t"
                          },
                          "rhs": "k"
                        },
                        {
                          "lhs": "obs",
                          "rhs": "x"
                        }
                      ]
                    }
                  }
                }
                "#,
        );
        assert_eq!(names, vec!["M.obs".to_string()]);
    }

    #[test]
    fn an_observed_unknown_needs_no_default() {
        // The same shape as `an_observed_unknowns_default_is_ignored`, except G
        // declares NO default at all — as `NOx = NO + NO2` does in real
        // chemistry, where the sum is defined by its parts and there is nothing
        // sensible to seed it with. The model is perfectly well posed, and a
        // demand for G's initial condition would say otherwise.
        let json = r#"
            {
              "esm": "1.0.0",
              "metadata": {
                "name": "TestFixture"
              },
              "models": {
                "M": {
                  "variables": {
                    "D": {
                      "type": "unknown",
                      "default": 1.0
                    },
                    "G": {
                      "type": "unknown"
                    },
                    "k": {
                      "type": "parameter",
                      "default": 1.0
                    }
                  },
                  "equations": [
                    {
                      "lhs": {
                        "op": "D",
                        "args": [
                          "D"
                        ],
                        "wrt": "t"
                      },
                      "rhs": {
                        "op": "*",
                        "args": [
                          {
                            "op": "-",
                            "args": [
                              "k"
                            ]
                          },
                          "G"
                        ]
                      }
                    },
                    {
                      "lhs": "G",
                      "rhs": "D"
                    }
                  ]
                }
              }
            }
            "#;
        let prob = problem_of(json, HashMap::new()).expect("build succeeds");
        let opts = SolveOptions {
            saveat: Some(vec![0.0, 1.0]),
            ..Default::default()
        };
        let sol = solve(&prob, &opts)
            .expect("a defaultless OBSERVED unknown must not block a simulation");

        // `G` is DEFINED by `G = D`, so esm 1.0.0 makes it an observed unknown:
        // it is eliminated rather than integrated, and has no state slot and no
        // initial condition to supply. `D` is the only thing solved for. (The
        // solution still reports `G`, as an observed row after the states.)
        assert!(
            !prob.state_variable_names().iter().any(|n| n.ends_with("G")),
            "an observed unknown is eliminated, not integrated: {:?}",
            prob.state_variable_names()
        );
        assert!(
            sol.state_variable_names.iter().any(|n| n.ends_with("D")),
            "{:?}",
            sol.state_variable_names
        );
        assert!(
            prob.observed_variable_names()
                .iter()
                .any(|n| n.ends_with("G")),
            "G must be reported as an observed: {:?}",
            prob.observed_variable_names()
        );
    }

    /// The other half of the rule: a DIFFERENTIAL state with no way to start
    /// still has to be refused. Relaxing that would silently begin every such
    /// model at zero.
    #[test]
    fn a_defaultless_differential_state_is_still_refused() {
        let json = r#"
            {
              "esm": "1.0.0",
              "metadata": {
                "name": "TestFixture"
              },
              "models": {
                "M": {
                  "variables": {
                    "D": {
                      "type": "unknown"
                    },
                    "k": {
                      "type": "parameter",
                      "default": 1.0
                    }
                  },
                  "equations": [
                    {
                      "lhs": {
                        "op": "D",
                        "args": [
                          "D"
                        ],
                        "wrt": "t"
                      },
                      "rhs": {
                        "op": "*",
                        "args": [
                          {
                            "op": "-",
                            "args": [
                              "k"
                            ]
                          },
                          "D"
                        ]
                      }
                    }
                  ]
                }
              }
            }
            "#;
        let err = problem_of(json, HashMap::new())
            .and_then(|prob| solve(&prob, &SolveOptions::default()))
            .expect_err("a differential state with no initial value must be refused");
        assert!(
            matches!(err, SimulateError::InvalidInitialCondition { .. }),
            "expected InvalidInitialCondition, got {err:?}"
        );
    }

    #[test]
    fn an_observed_unknowns_default_is_ignored() {
        // dD/dt = -k*G,  G = D  (so D evolves as exp(-k*t), G tracks D).
        // G's default is deliberately wrong (99.0). Under esm 1.0.0 the
        // bare-LHS equation makes G an OBSERVED unknown: it is eliminated
        // rather than integrated, so the wrong default cannot reach the
        // trajectory at all — a stronger guarantee than the 0.x reconciliation
        // pass, which wrote the default into a state slot and then overwrote
        // it before the first step.
        let json = r#"
            {
              "esm": "1.0.0",
              "metadata": {
                "name": "TestFixture"
              },
              "models": {
                "M": {
                  "variables": {
                    "D": {
                      "type": "unknown",
                      "default": 1.0
                    },
                    "G": {
                      "type": "unknown",
                      "default": 99.0
                    },
                    "k": {
                      "type": "parameter",
                      "default": 1.0
                    }
                  },
                  "equations": [
                    {
                      "lhs": {
                        "op": "D",
                        "args": [
                          "D"
                        ],
                        "wrt": "t"
                      },
                      "rhs": {
                        "op": "*",
                        "args": [
                          {
                            "op": "-",
                            "args": [
                              "k"
                            ]
                          },
                          "G"
                        ]
                      }
                    },
                    {
                      "lhs": "G",
                      "rhs": "D"
                    }
                  ]
                }
              }
            }
            "#;
        let prob = problem_of(json, HashMap::new()).expect("build succeeds");
        // Explicit tolerances, not the defaults. The assertion below pins
        // D(1) to exp(-1) within 1e-6, which is a statement about the RHS
        // seeing the right G — not about how tightly the production default
        // integrates. `DEFAULT_RELTOL`/`DEFAULT_ABSTOL` are Julia's `1e-4`/
        // `1e-6` and leave ~4.6e-6 of truncation error over this interval,
        // which is larger than the thing being measured.
        let opts = SolveOptions {
            abstol: Some(1e-12),
            reltol: Some(1e-10),
            saveat: Some(vec![0.0, 1.0]),
            ..Default::default()
        };
        let sol = solve(&prob, &opts).expect("simulate succeeds");

        let d_idx = sol
            .state_variable_names
            .iter()
            .position(|n| n.ends_with("D"))
            .expect("D in solution");
        assert!(
            !prob.state_variable_names().iter().any(|n| n.ends_with("G")),
            "G is observed, so it is eliminated rather than integrated: {:?}",
            prob.state_variable_names()
        );

        assert!(
            (sol.state[d_idx][0] - 1.0).abs() < 1e-12,
            "D(0) should be 1.0, got {}",
            sol.state[d_idx][0]
        );
        // The bogus G default (99.0) never reaches the RHS: had it done so,
        // dD/dt would have started at -99 and D(1) would be nowhere near
        // exp(-1).
        let expected = (-1.0_f64).exp();
        assert!(
            (sol.state[d_idx][1] - expected).abs() < 1e-6,
            "D(1) ≈ exp(-1), got {}",
            sol.state[d_idx][1]
        );
    }
}
