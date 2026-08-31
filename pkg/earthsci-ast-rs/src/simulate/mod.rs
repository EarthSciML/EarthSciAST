//! Native ODE simulation via [`diffsol`] (gt-5ws, v1).
//!
//! This module provides a *correctness-first* simulation API for the Rust
//! Core tier. It consumes a [`FlattenedSystem`] (the canonical output of
//! [`crate::flatten`]) and runs it through diffsol's BDF / SDIRK / explicit
//! Runge-Kutta solvers.
//!
//! ## Scope
//!
//! - **ODE only.** [`FlattenedSystem::independent_variables`] must equal `["t"]`.
//!   Hybrid PDE / spatial systems return [`CompileError::UnsupportedDimensionalityError`].
//! - **No event handling.** Models with non-empty `continuous_events` /
//!   `discrete_events` return [`CompileError::UnsupportedFeatureError`].
//! - **Both targets.** diffsol's Faer backend is pure Rust and cross-compiles to
//!   wasm32 (spike S1), so this module is compiled for the browser too. The one
//!   native-only seam is the dispatch into [`crate::simulate_array`] for
//!   array-op / spatial files, which is `cfg`-gated off wasm.
//!
//! ## Usage
//!
//! This module is the compiled right-hand side and the solver plumbing around
//! it. The public entry point is the EsmProblem/`solve` surface in
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
//! The module is split along the stages a solve passes through: `errors`
//! (the [`SimulateError`] surface), `api` (the public option and result
//! vocabulary — [`Alg`], [`SolveOptions`], [`Solution`]), `compiled` (the
//! [`Compiled`] interpreter and its solve entry points), `build_phases` (the
//! named phases [`Compiled::from_flattened`] runs), `driver` (the solver step
//! loop and the array/spatial routing), `override_keys` (esm-spec §6.6.2
//! caller-key canonicalization), `resolve` ([`ResolvedExpr`] and the pass that
//! builds it), `interpret` (the hot evaluation loop), and `lhs` (equation
//! left-hand-side classification). Every item is re-exported here, so all
//! existing `crate::simulate::*` paths resolve unchanged.

use crate::flatten::{FlattenedSystem, flatten, flatten_model};
use crate::simulate_array::{apply_binary, apply_unary, fold_scalar};
use crate::types::{EsmFile, Expr, Model};
use std::collections::{HashMap, HashSet};
use thiserror::Error;

// The solver is OPTIONAL (esm-libraries-spec §2.5.9): building a `EsmProblem`
// never needs it, so `diffsol` sits behind the `solve` Cargo feature and every
// item that touches it is gated the same way.
#[cfg(feature = "solve")]
use diffsol::{
    Bdf, FaerLU, FaerMat, NewtonNonlinearSolver, OdeBuilder, OdeSolverMethod, Op, Sdirk, VectorHost,
};

mod api;
mod build_phases;
mod compiled;
mod driver;
mod errors;
mod interpret;
mod lhs;
mod override_keys;
mod resolve;

pub use api::*;
use build_phases::*;
pub use compiled::*;
pub use driver::*;
pub use errors::*;
pub use interpret::*;
pub use lhs::*;
pub(crate) use override_keys::*;
pub use resolve::*;

// ============================================================================
// Inline unit tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn interpret_arithmetic() {
        // 2 * (3 + 4) = 14
        let e = ResolvedExpr::Op {
            op: "*".to_string(),
            args: vec![
                ResolvedExpr::Number(2.0),
                ResolvedExpr::Op {
                    op: "+".to_string(),
                    args: vec![ResolvedExpr::Number(3.0), ResolvedExpr::Number(4.0)],
                },
            ],
        };
        assert!((interpret(&e, &[], &[], &[], 0.0) - 14.0).abs() < 1e-12);
    }

    #[test]
    fn interpret_state_param_time() {
        // state[0] * param[0] + t  with state=[2], params=[3], t=10 -> 16
        let e = ResolvedExpr::Op {
            op: "+".to_string(),
            args: vec![
                ResolvedExpr::Op {
                    op: "*".to_string(),
                    args: vec![ResolvedExpr::State(0), ResolvedExpr::Param(0)],
                },
                ResolvedExpr::Time,
            ],
        };
        assert!((interpret(&e, &[2.0], &[3.0], &[], 10.0) - 16.0).abs() < 1e-12);
    }

    #[test]
    fn interpret_unary_minus_and_pow() {
        // (-x)^2 with x=4 -> 16
        let e = ResolvedExpr::Op {
            op: "^".to_string(),
            args: vec![
                ResolvedExpr::Op {
                    op: "-".to_string(),
                    args: vec![ResolvedExpr::State(0)],
                },
                ResolvedExpr::Number(2.0),
            ],
        };
        assert!((interpret(&e, &[4.0], &[], &[], 0.0) - 16.0).abs() < 1e-12);
    }

    #[test]
    fn interpret_transcendentals_and_relational() {
        // ifelse(x > 0, log(x), 0)
        let e = ResolvedExpr::Op {
            op: "ifelse".to_string(),
            args: vec![
                ResolvedExpr::Op {
                    op: ">".to_string(),
                    args: vec![ResolvedExpr::State(0), ResolvedExpr::Number(0.0)],
                },
                ResolvedExpr::Op {
                    op: "log".to_string(),
                    args: vec![ResolvedExpr::State(0)],
                },
                ResolvedExpr::Number(0.0),
            ],
        };
        let x_pos = std::f64::consts::E;
        // ifelse(true, log(e^1), 0) = 1
        assert!((interpret(&e, &[x_pos], &[], &[], 0.0) - 1.0).abs() < 1e-12);
        assert_eq!(interpret(&e, &[-1.0], &[], &[], 0.0), 0.0);
    }

    #[test]
    fn topo_sort_empty_and_simple() {
        // No deps -> any order is fine, but length matches.
        let deps = vec![HashSet::new(), HashSet::new(), HashSet::new()];
        let order = topo_sort(&deps).unwrap();
        assert_eq!(order.len(), 3);

        // 0 -> 1 -> 2 (2 depends on 1, 1 depends on 0)
        let mut s1 = HashSet::new();
        s1.insert(0);
        let mut s2 = HashSet::new();
        s2.insert(1);
        let deps = vec![HashSet::new(), s1, s2];
        let order = topo_sort(&deps).unwrap();
        assert_eq!(order, vec![0, 1, 2]);
    }

    #[test]
    fn topo_sort_cycle_detected() {
        // 0 -> 1 -> 0
        let mut s0 = HashSet::new();
        s0.insert(1);
        let mut s1 = HashSet::new();
        s1.insert(0);
        let deps = vec![s0, s1];
        assert!(topo_sort(&deps).is_err());
    }

    /// Cyclic algebraic-state systems must be rejected at compile time
    /// (esm-0kt). `from_flattened` should return an `InterpreterBuildError`
    /// whose message names the offending variables.
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
        let file = crate::parse::load_string(json).expect("parse fixture");
        let err = Compiled::from_file(&file).expect_err("cycle must be rejected");
        let msg = err.to_string();
        assert!(msg.contains("Cyclic"), "expected cycle error, got: {msg}");
        assert!(
            msg.contains("a") && msg.contains("b"),
            "cycle error should name both vars: {msg}"
        );
    }

    /// A `fn`-op observed (`interp.linear` fuel-table lookup) must evaluate
    /// through the closed-function registry on the scalar path — not NaN out.
    /// Regression for the coupled-fire blocker: `resolve_expr` used to drop the
    /// `fn` op's `name` and its inline array args, so `interp.linear` fell
    /// through `eval_op`'s `_ => NaN` arm and poisoned every downstream state.
    #[test]
    fn fn_op_interp_linear_scalar_path() {
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
        let file = crate::parse::load_string(json).expect("parse fixture");
        let compiled = Compiled::from_file(&file).expect("compile succeeds");
        // Explicit tolerances, not the defaults. The assertion below pins
        // D(1) to exp(-1) within 1e-6, which is a statement about the RHS
        // seeing the right G — not about how tightly the production default
        // integrates. `DEFAULT_RELTOL`/`DEFAULT_ABSTOL` are Julia's `1e-4`/
        // `1e-6` and leave ~4.6e-6 of truncation error over this interval,
        // which is larger than the thing being measured.
        let opts = SolveOptions {
            abstol: 1e-12,
            reltol: 1e-10,
            saveat: Some(vec![0.0, 1.0]),
            ..Default::default()
        };
        let sol = compiled
            .solve((0.0, 1.0), &HashMap::new(), &HashMap::new(), &opts)
            .expect("simulate succeeds");
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
        let sol2 = compiled
            .solve((0.0, 1.0), &params, &HashMap::new(), &opts)
            .expect("simulate succeeds");
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
        let file = crate::parse::load_string(json).expect("parse fixture");
        let compiled = Compiled::from_file(&file).expect("compile succeeds");
        // Explicit tolerances, not the defaults. The assertion below pins
        // D(1) to exp(-1) within 1e-6, which is a statement about the RHS
        // seeing the right G — not about how tightly the production default
        // integrates. `DEFAULT_RELTOL`/`DEFAULT_ABSTOL` are Julia's `1e-4`/
        // `1e-6` and leave ~4.6e-6 of truncation error over this interval,
        // which is larger than the thing being measured.
        let opts = SolveOptions {
            abstol: 1e-12,
            reltol: 1e-10,
            saveat: Some(vec![0.0, 1.0]),
            ..Default::default()
        };
        let sol = compiled
            .solve((0.0, 1.0), &HashMap::new(), &HashMap::new(), &opts)
            .expect("simulate succeeds");
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
        // The same shape as `algebraic_ic_reconciled_to_constraint`, except G
        // declares NO default at all — as `NOx = NO + NO2` does in real
        // chemistry, where the sum is defined by its parts and there is nothing
        // sensible to seed it with.
        //
        // This used to fail with `Invalid initial condition 'M.G'`, which was
        // wrong twice over: the value is overwritten by `apply_algebraic_ics`
        // before the solve starts, and the model is perfectly well posed. It
        // also split the ecosystem — the TypeScript binding injected a
        // placeholder before calling simulate, so a model that ran in a browser
        // failed on a server calling this function directly.
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
        let file = crate::parse::load_string(json).expect("parse fixture");
        let compiled = Compiled::from_file(&file).expect("compile succeeds");
        let opts = SolveOptions {
            saveat: Some(vec![0.0, 1.0]),
            ..Default::default()
        };
        let sol = compiled
            .solve((0.0, 1.0), &HashMap::new(), &HashMap::new(), &opts)
            .expect("a defaultless OBSERVED unknown must not block a simulation");

        // `G` is DEFINED by `G = D`, so esm 1.0.0 makes it an observed unknown:
        // it is eliminated rather than integrated, and has no state row and no
        // initial condition to supply. `D` is the only thing solved for.
        assert!(
            !sol.state_variable_names.iter().any(|n| n.ends_with("G")),
            "an observed unknown is eliminated, not integrated: {:?}",
            sol.state_variable_names
        );
        assert!(
            compiled
                .observed_variable_names()
                .iter()
                .any(|n| n.ends_with("G")),
            "G must be reported as an observed: {:?}",
            compiled.observed_variable_names()
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
        let file = crate::parse::load_string(json).expect("parse fixture");
        let compiled = Compiled::from_file(&file).expect("compile succeeds");
        let err = compiled
            .solve(
                (0.0, 1.0),
                &HashMap::new(),
                &HashMap::new(),
                &SolveOptions::default(),
            )
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
        let file = crate::parse::load_string(json).expect("parse fixture");
        let compiled = Compiled::from_file(&file).expect("compile succeeds");
        // Explicit tolerances, not the defaults. The assertion below pins
        // D(1) to exp(-1) within 1e-6, which is a statement about the RHS
        // seeing the right G — not about how tightly the production default
        // integrates. `DEFAULT_RELTOL`/`DEFAULT_ABSTOL` are Julia's `1e-4`/
        // `1e-6` and leave ~4.6e-6 of truncation error over this interval,
        // which is larger than the thing being measured.
        let opts = SolveOptions {
            abstol: 1e-12,
            reltol: 1e-10,
            saveat: Some(vec![0.0, 1.0]),
            ..Default::default()
        };
        let sol = compiled
            .solve((0.0, 1.0), &HashMap::new(), &HashMap::new(), &opts)
            .expect("simulate succeeds");

        let d_idx = sol
            .state_variable_names
            .iter()
            .position(|n| n.ends_with("D"))
            .expect("D in solution");
        assert!(
            !sol.state_variable_names.iter().any(|n| n.ends_with("G")),
            "G is observed, so it is eliminated rather than integrated: {:?}",
            sol.state_variable_names
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
