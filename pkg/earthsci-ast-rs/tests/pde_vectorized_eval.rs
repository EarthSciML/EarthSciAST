//! Array right-hand sides end to end: an upwind advection stencil integrated
//! by a solve, an array-valued `filter` acting as a per-cell mask, and the
//! shared unary-broadcast conformance fixture.

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::simulate_array::ArrayCompiled;
use earthsci_ast::{Alg, SolveOptions, load_string};
use std::collections::HashMap;
use std::path::PathBuf;

use crate::common;

fn fixture(name: &str) -> PathBuf {
    common::repo_fixture("fixtures/faq").join(name)
}

fn compile_json(json: &str) -> ArrayCompiled {
    let file = load_string(json).expect("load json model");
    ArrayCompiled::from_file(&file).expect("compile json model")
}

/// A 1-D linear upwind advection `∂u/∂t = -v ∂u/∂x` discretized first-order
/// upwind (v>0): `D(u[i]) = -(v/dx)*(u[i] - u[i-1])`, `i ∈ [1, n]`, with a zero
/// inflow at the left edge (the `u[i-1]` read at `i=1` falls on the ghost cell
/// → 0). A bare-arithmetic pure-map faq (no makearray) — the second stencil
/// shape the vectorized evaluator must handle.
fn advection1d_json(n: usize, c: f64) -> String {
    const TEMPLATE: &str = r#"{
 "esm": "2.0.0",
 "metadata": {"name": "advection1d"},
 "models": {
  "Adv1D": {
   "variables": {"u": {"type": "unknown", "shape": ["i"]}},
   "equations": [
    {
     "lhs": {"op": "faq", "args": [], "output_idx": ["i"],
             "expr": {"op": "D", "args": [{"op": "index", "args": ["u", "i"]}], "wrt": "t"},
             "ranges": {"i": [1, __N__]}},
     "rhs": {"op": "faq", "args": [], "output_idx": ["i"],
             "ranges": {"i": [1, __N__]},
             "expr": {"op": "*", "args": [__NEGC__, {"op": "-", "args": [
                {"op": "index", "args": ["u", "i"]},
                {"op": "index", "args": ["u", {"op": "-", "args": ["i", 1]}]}
             ]}]}}
    }
   ]
  }
 }
}"#;
    TEMPLATE
        .replace("__N__", &n.to_string())
        .replace("__NEGC__", &format!("{}", -c))
}

#[test]
fn advection_1d_integrates_end_to_end() {
    // v = 1, dx = 0.05 -> c = v/dx = 20. Grid of 40 cells; a smooth pulse
    // initially centred at cell 8 advects downstream (toward higher i).
    let n = 40usize;
    let c = 20.0f64;
    let json = advection1d_json(n, c);
    let file = load_string(&json).expect("load advection model");

    // Gaussian-ish pulse centred at cell 8, well clear of the i=n outflow so
    // negligible mass leaves the domain over the integration window.
    let center0 = 8.0f64;
    let ic: HashMap<String, f64> = (1..=n)
        .map(|k| {
            let x = (k as f64 - center0) / 2.0;
            (format!("u[{k}]"), (-x * x).exp())
        })
        .collect();

    let state0: Vec<f64> = (1..=n)
        .map(|k| {
            let x = (k as f64 - center0) / 2.0;
            (-x * x).exp()
        })
        .collect();

    // Integrate end-to-end. t=0.1 advects the pulse by v*t/dx = 2 cells.
    let t_end = 0.1f64;
    let opts = SolveOptions {
        alg: Alg::Bdf,
        abstol: Some(1e-10),
        reltol: Some(1e-8),
        maxiters: Some(100_000),
        saveat: Some(vec![t_end]),
        ..Default::default()
    };
    let sol = earthsci_ast::esm_problem(
        &file,
        (0.0, t_end),
        earthsci_ast::ProblemOptions {
            p: HashMap::new().clone(),
            u0: ic.clone(),
            rhs: earthsci_ast::Rhs::Always,
            ..Default::default()
        },
    )
    .and_then(|prob| earthsci_ast::solve(&prob, &opts))
    .expect("advection simulate failed");

    // Pull the final state in grid order and check the centre of mass moved
    // downstream — the unambiguous signature of advection. `sol.state` is
    // indexed `[variable_index][time_index]`; there is a single output time.
    let last_tix = sol.time.len() - 1;
    let mut num0 = 0.0;
    let mut den0 = 0.0;
    let mut numf = 0.0;
    let mut denf = 0.0;
    for k in 1..=n {
        // See `Solution::index_of`: either spelling resolves.
        let j = sol
            .index_of(&format!("u[{k}]"))
            .unwrap_or_else(|| panic!("no state u[{k}] in {:?}", sol.state_variable_names));
        let u0 = state0[k - 1];
        let uf = sol.state[j][last_tix];
        assert!(uf.is_finite(), "non-finite u[{k}] = {uf}");
        num0 += k as f64 * u0;
        den0 += u0;
        numf += k as f64 * uf;
        denf += uf;
    }
    let centroid0 = num0 / den0;
    let centroidf = numf / denf;
    assert!(
        centroidf > centroid0 + 1.0,
        "advection must move the pulse downstream: centroid {centroid0:.3} -> {centroidf:.3}"
    );
}

/// A `filter: [1, 0, 1] > 0.5` / `body = 10` document. The mask is an
/// anonymous array: a declared shaped variable read bare in a filter is
/// `faq_bare_array_operand` (esm-spec §4.3.1) and never reaches evaluation.
fn array_filter_json() -> String {
    r#"
        {
          "esm": "2.0.0",
          "metadata": {
            "name": "array_filter"
          },
          "models": {
            "ArrayFilter": {
              "variables": {
                "u": {
                  "type": "unknown",
                  "shape": [
                    "i"
                  ]
                },
                "mask": {
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
                        3
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
                        3
                      ]
                    },
                    "filter": {
                      "op": ">",
                      "args": [
                        {
                          "op": "const",
                          "args": [],
                          "value": [1.0, 0.0, 1.0]
                        },
                        0.5
                      ]
                    },
                    "expr": 10
                  }
                },
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
                            "mask",
                            "i"
                          ]
                        }
                      ],
                      "wrt": "t"
                    },
                    "ranges": {
                      "i": [
                        1,
                        3
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
                        3
                      ]
                    },
                    "expr": 0
                  }
                }
              ]
            }
          }
        }
        "#
    .to_string()
}

/// R4: an ARRAY-valued `filter` is a per-cell mask on BOTH paths.
///
/// This test pins the *value*, not merely the agreement — `[0, 0, 0]` on both
/// paths would satisfy an equality-only assertion while still being the wrong
/// answer (it is precisely the bug: the oracle coerced the non-scalar filter to
/// `0.0` and excluded every cell). The intended reading, the one the vectorized
/// path's `vec_select` already implemented and its doc-comments advertise, is a
/// genuine per-cell gate.
#[test]
fn array_valued_filter_is_a_per_cell_mask() {
    let compiled = compile_json(&array_filter_json());
    let names = compiled.state_variable_names();
    assert_eq!(names.len(), 6, "expected u[3] + mask[3], got {names:?}");

    // Slot order follows `state_variable_names`; build the state from it so the
    // test does not hard-code a layout.
    let state: Vec<f64> = names
        .iter()
        .map(|n| {
            if !n.contains("mask") {
                return 0.0;
            }
            // mask = [1, 0, 1] — the middle cell is gated OFF.
            if n.contains("[2]") { 0.0 } else { 1.0 }
        })
        .collect();

    let (dy, _) = compiled.debug_eval_rhs(&state, 0.0, &HashMap::new());

    let u_of = |dy: &[f64]| -> Vec<f64> {
        names
            .iter()
            .zip(dy.iter())
            .filter(|(n, _)| !n.contains("mask"))
            .map(|(_, v)| *v)
            .collect()
    };
    assert_eq!(
        u_of(&dy),
        vec![10.0, 0.0, 10.0],
        "an array filter must gate PER CELL (mask=[1,0,1] => [10,0,10]); \
         [0,0,0] means the filter was coerced to a false scalar and every cell \
         was dropped"
    );
}

// ============================================================================
// Issue #101 — the shared unary-broadcast conformance fixture.
// ============================================================================

/// Run `fixtures/faq/27_broadcast_unary.esm` end-to-end and check its inline
/// assertions, and the oracle's tendencies against the expected values.
///
/// The fixture is the cross-binding pin (Julia and Python glob this directory
/// and execute the same `tests` block); this test is the Rust arm of it.
#[test]
fn unary_broadcast_conformance_fixture_matches_its_inline_assertions() {
    let path = fixture("27_broadcast_unary.esm");
    let text = std::fs::read_to_string(&path).expect("read fixture");
    let file = load_string(&text).expect("load fixture");

    // The fixture's own initial conditions and expectations, kept in one place
    // so a drift in the fixture shows up as a mismatch here rather than being
    // silently unchecked.
    let ic: HashMap<String, f64> = [
        ("a[1]", 1.0),
        ("a[2]", 4.0),
        ("a[3]", 9.0),
        ("negated", 0.0),
        ("minused", 0.0),
        ("rooted", 0.0),
        ("logged", 0.0),
        ("identity", 0.0),
    ]
    .into_iter()
    .map(|(k, v)| (k.to_string(), v))
    .collect();
    let expected: Vec<(&str, f64)> = vec![
        ("negated", -4.0),
        ("minused", -9.0),
        ("rooted", 3.0),
        ("logged", std::f64::consts::LN_2 * 2.0),
        ("identity", 4.0),
    ];

    let opts = SolveOptions {
        alg: Alg::Bdf,
        abstol: Some(1e-12),
        reltol: Some(1e-10),
        maxiters: Some(100_000),
        saveat: Some(vec![1.0]),
        ..Default::default()
    };
    let sol = earthsci_ast::esm_problem(
        &file,
        (0.0, 1.0),
        earthsci_ast::ProblemOptions {
            p: HashMap::new().clone(),
            u0: ic.clone(),
            rhs: earthsci_ast::Rhs::Always,
            // The unary `broadcast` this fixture is about has no wholesale
            // tape lowering, so `native` refuses it by NAME (API_SPEC §5.8).
            // The fixture is about the broadcast's VALUES, which is the
            // reference evaluator's answer to give.
            compiler: Some(earthsci_ast::Compiler::Interpreter),
            ..Default::default()
        },
    )
    .and_then(|prob| earthsci_ast::solve(&prob, &opts))
    .expect("simulate fixture");
    let last = sol.time.len() - 1;
    for (name, want) in &expected {
        let j = sol
            .state_variable_names
            .iter()
            .position(|nm| nm == name || nm.ends_with(&format!(".{name}")))
            .unwrap_or_else(|| panic!("`{name}` not in {:?}", sol.state_variable_names));
        let got = sol.state[j][last];
        assert!(
            (got - want).abs() <= 1e-6 * want.abs().max(1.0),
            "`{name}`: expected {want}, got {got} — a discarded `broadcast.fn` \
             returns the operand instead"
        );
    }

    // The tendencies are constants, so `dy` at t = 0 IS the assertion vector.
    let compiled = ArrayCompiled::from_file(&file).expect("compile fixture");
    let names = compiled.state_variable_names();
    let state: Vec<f64> = names
        .iter()
        .map(|n| ic.get(n).copied().unwrap_or(0.0))
        .collect();
    let (dy_vec, _) = compiled.debug_eval_rhs(&state, 0.0, &HashMap::new());
    for (name, want) in &expected {
        let k = names.iter().position(|n| n == name).expect("probe slot");
        assert_eq!(
            dy_vec[k].to_bits(),
            want.to_bits(),
            "tendency of `{name}` must be exactly {want}, got {}",
            dy_vec[k]
        );
    }
}
