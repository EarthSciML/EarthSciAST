//! [`SimulateOptions::progress`]: per-step progress reporting and caller cancel.
//!
//! The observer is installed in one place — [`earthsci_ast::simulate`]'s shared
//! `run_solver` — which both the scalar ODE path and the array/spatial path
//! funnel through, and which has two structurally different stepping loops (a
//! natural step grid, and one that interpolates onto a requested output grid).
//! These tests pin all three combinations, since a hook added to only one loop
//! would still look correct on a casual read.

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::{
    Flow, Progress, ProgressFn, SimulateError, SimulateOptions, SolverChoice, load_string, simulate,
};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};

mod common;

/// `D(y)/dt = k*y` with `k = -1`: exponential decay, a real (non-polynomial)
/// trajectory so the solver takes a useful number of adaptive steps. `k` is
/// negative by default rather than negated in the expression, which keeps the
/// document free of any unary-minus encoding.
const DECAY: &str = r#"
    {
      "esm": "1.0.0",
      "metadata": {
        "name": "progress_decay"
      },
      "models": {
        "M": {
          "variables": {
            "y": {
              "type": "unknown",
              "default": 1.0
            },
            "k": {
              "type": "parameter",
              "default": -1.0
            }
          },
          "equations": [
            {
              "lhs": {
                "op": "D",
                "args": [
                  "y"
                ],
                "wrt": "t"
              },
              "rhs": {
                "op": "*",
                "args": [
                  "k",
                  "y"
                ]
              }
            }
          ]
        }
      }
    }
    "#;

/// `D(y[i])/dt = Σ_{j∈1..3} i*j` over `i ∈ 1..2` — a constant-RHS contraction
/// that routes through the array runtime rather than the scalar interpreter.
const ARRAY: &str = r#"
    {
      "esm": "1.0.0",
      "metadata": {
        "name": "progress_array"
      },
      "models": {
        "M": {
          "variables": {
            "y": {
              "type": "unknown",
              "shape": [
                "i"
              ],
              "default": 0.0
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
                "ranges": {
                  "i": [
                    1,
                    2
                  ]
                },
                "expr": {
                  "op": "D",
                  "args": [
                    {
                      "op": "index",
                      "args": [
                        "y",
                        "i"
                      ]
                    }
                  ],
                  "wrt": "t"
                }
              },
              "rhs": {
                "op": "aggregate",
                "args": [],
                "output_idx": [
                  "i"
                ],
                "reduce": "+",
                "ranges": {
                  "i": [
                    1,
                    2
                  ],
                  "j": [
                    1,
                    3
                  ]
                },
                "expr": {
                  "op": "*",
                  "args": [
                    "i",
                    "j"
                  ]
                }
              }
            }
          ]
        }
      }
    }
    "#;

/// A recording observer plus the log it writes to.
fn recorder() -> (ProgressFn, Arc<Mutex<Vec<Progress>>>) {
    let log = Arc::new(Mutex::new(Vec::new()));
    let sink = log.clone();
    let obs: ProgressFn = Arc::new(move |p: &Progress| {
        sink.lock().unwrap().push(*p);
        Flow::Continue
    });
    (obs, log)
}

fn opts(progress: Option<ProgressFn>, output_times: Option<Vec<f64>>) -> SimulateOptions {
    SimulateOptions {
        solver: SolverChoice::Bdf,
        abstol: 1e-10,
        reltol: 1e-8,
        max_steps: 100_000,
        output_times,
        progress,
    }
}

/// Every invariant a progress bar actually depends on: a determinate 0% before
/// the first step, monotonically advancing `t`, and a final report that reaches
/// the end of the interval (so the bar lands on 100% rather than stopping at
/// whatever the last step happened to be).
fn assert_well_formed(log: &[Progress], t0: f64, t_end: f64) {
    assert!(
        log.len() >= 2,
        "expected a pre-loop report plus at least one step, got {}",
        log.len()
    );

    let first = &log[0];
    assert_eq!(first.step, 0, "the pre-loop report is step 0");
    assert_eq!(first.t, t0, "the pre-loop report sits at t0");
    assert_eq!(first.fraction(), 0.0);

    for pair in log.windows(2) {
        let (a, b) = (&pair[0], &pair[1]);
        assert!(b.t >= a.t, "t went backwards: {} then {}", a.t, b.t);
        assert_eq!(
            b.step,
            a.step + 1,
            "step numbers skip: {:?}",
            (a.step, b.step)
        );
        assert!(
            b.fraction() >= a.fraction(),
            "fraction went backwards: {} then {}",
            a.fraction(),
            b.fraction()
        );
    }

    let last = log.last().unwrap();
    assert!(
        (last.t - t_end).abs() < 1e-9,
        "last report should reach t_end, got t = {}",
        last.t
    );
    assert_eq!(last.fraction(), 1.0, "the bar must land on 100%");
    assert!(log.iter().all(|p| p.t0 == t0 && p.t_end == t_end));
    assert!(log.iter().all(|p| p.max_steps == 100_000));
}

#[test]
fn reports_progress_on_the_natural_step_grid() {
    let file = load_string(DECAY).expect("load");
    let (obs, log) = recorder();

    let sol = simulate(
        &file,
        (0.0, 20.0),
        &HashMap::new(),
        &HashMap::new(),
        &opts(Some(obs), None),
    )
    .expect("simulate");

    let log = log.lock().unwrap();
    assert_well_formed(&log, 0.0, 20.0);

    // One report per accepted step, plus the pre-loop one. This is what lets a
    // host reason about cost: the observer fires exactly as often as the solver
    // advances, no more.
    assert_eq!(
        log.len(),
        sol.metadata.n_accepted_steps + 1,
        "expected one report per accepted step plus the t0 report"
    );
}

#[test]
fn reports_progress_on_an_interpolated_output_grid() {
    let file = load_string(DECAY).expect("load");
    let (obs, log) = recorder();

    // The requested output grid is much coarser than the solver's own steps;
    // progress must still track the SOLVER, not the output samples.
    let grid: Vec<f64> = (0..=4).map(|i| i as f64 * 5.0).collect();
    let sol = simulate(
        &file,
        (0.0, 20.0),
        &HashMap::new(),
        &HashMap::new(),
        &opts(Some(obs), Some(grid.clone())),
    )
    .expect("simulate");

    assert_eq!(
        sol.time, grid,
        "the output grid is unchanged by observing it"
    );

    let log = log.lock().unwrap();
    assert_well_formed(&log, 0.0, 20.0);
    assert!(
        log.len() > grid.len(),
        "progress should follow solver steps ({} reports) not output samples ({})",
        log.len(),
        grid.len()
    );
}

#[test]
fn reports_progress_from_the_array_runtime() {
    let file = load_string(ARRAY).expect("load");
    let (obs, log) = recorder();

    let sol = simulate(
        &file,
        (0.0, 1.0),
        &HashMap::new(),
        &HashMap::new(),
        &opts(Some(obs), Some(vec![0.0, 1.0])),
    )
    .expect("simulate");

    // Sanity that this really is the array path and it still computes:
    // D(y[1])/dt = 1*1 + 1*2 + 1*3 = 6, from y[1](0) = 0.
    let i = sol
        .state_variable_names
        .iter()
        .position(|n| n == "y[1]")
        .unwrap_or_else(|| panic!("y[1] not in {:?}", sol.state_variable_names));
    assert!((sol.state[i][sol.time.len() - 1] - 6.0).abs() < 1e-6);

    let log = log.lock().unwrap();
    assert_well_formed(&log, 0.0, 1.0);
}

#[test]
fn returning_cancel_stops_the_run() {
    let file = load_string(DECAY).expect("load");

    // Cancel on the 3rd accepted step. The pre-loop report is step 0, so this
    // also pins that the cancel is checked on the step reports and not only on
    // the initial one.
    let obs: ProgressFn = Arc::new(|p: &Progress| {
        if p.step >= 3 {
            Flow::Cancel
        } else {
            Flow::Continue
        }
    });

    let err = simulate(
        &file,
        (0.0, 20.0),
        &HashMap::new(),
        &HashMap::new(),
        &opts(Some(obs), None),
    )
    .expect_err("cancel should abort the run");

    match err {
        SimulateError::Cancelled { step, t } => {
            assert_eq!(step, 3);
            assert!(t > 0.0 && t < 20.0, "cancelled mid-interval, got t = {t}");
        }
        other => panic!("expected Cancelled, got {other:?}"),
    }
}

#[test]
fn cancelling_at_step_zero_stops_before_any_work() {
    let file = load_string(DECAY).expect("load");
    let obs: ProgressFn = Arc::new(|_: &Progress| Flow::Cancel);

    let err = simulate(
        &file,
        (0.0, 20.0),
        &HashMap::new(),
        &HashMap::new(),
        &opts(Some(obs), None),
    )
    .expect_err("cancel should abort the run");

    match err {
        SimulateError::Cancelled { step, t } => {
            assert_eq!(step, 0);
            assert_eq!(t, 0.0);
        }
        other => panic!("expected Cancelled, got {other:?}"),
    }
}

/// Observing a run must not change its answer. The observer sits between
/// `solver.step()` calls and touches nothing the integrator reads, but that is
/// exactly the kind of claim worth pinning rather than asserting in a comment.
#[test]
fn observing_does_not_perturb_the_trajectory() {
    let file = load_string(DECAY).expect("load");
    let grid = Some(vec![0.0, 1.0, 5.0, 20.0]);

    let plain = simulate(
        &file,
        (0.0, 20.0),
        &HashMap::new(),
        &HashMap::new(),
        &opts(None, grid.clone()),
    )
    .expect("simulate");

    let (obs, _log) = recorder();
    let observed = simulate(
        &file,
        (0.0, 20.0),
        &HashMap::new(),
        &HashMap::new(),
        &opts(Some(obs), grid),
    )
    .expect("simulate");

    assert_eq!(plain.time, observed.time);
    assert_eq!(plain.state, observed.state);
    assert_eq!(
        plain.metadata.n_accepted_steps,
        observed.metadata.n_accepted_steps
    );
}

/// `fraction()` is fed straight into a progress bar and an ETA divisor, so its
/// degenerate cases must be values, not NaNs.
#[test]
fn fraction_is_clamped_and_never_nan() {
    let p = |t0: f64, t: f64, t_end: f64| Progress {
        t0,
        t,
        t_end,
        step: 0,
        max_steps: 0,
    };
    assert_eq!(p(0.0, 5.0, 10.0).fraction(), 0.5);
    assert_eq!(p(0.0, -1.0, 10.0).fraction(), 0.0, "clamped below");
    assert_eq!(p(0.0, 11.0, 10.0).fraction(), 1.0, "clamped above");
    assert_eq!(p(3.0, 3.0, 3.0).fraction(), 0.0, "zero-length interval");
    assert_eq!(p(0.0, 1.0, f64::INFINITY).fraction(), 0.0, "infinite span");
}
