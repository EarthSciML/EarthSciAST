//! `ESS_TAPE_DISABLE=1` kill-switch test (Step 3b). Lives in its own test
//! binary with a single test: the switch is read once per process through a
//! `OnceLock`, so it must be set before anything queries it and no other test
//! may expect the opposite value in the same process.

#![cfg(not(target_arch = "wasm32"))]

use std::collections::HashMap;

use earthsci_ast::simulate_array::{ArrayCompiled, RhsStats};
use earthsci_ast::{SimulateOptions, SolverChoice, load, simulate};

const MODEL: &str = r#"{
 "esm": "0.1.0",
 "metadata": {"name": "tape_kill_switch"},
 "models": {
  "Decay": {
   "variables": {"u": {"type": "state", "shape": ["i"]}},
   "equations": [
    {
     "lhs": {"op": "aggregate", "args": [], "output_idx": ["i"],
             "expr": {"op": "D", "args": [{"op": "index", "args": ["u", "i"]}], "wrt": "t"},
             "ranges": {"i": [1, 6]}},
     "rhs": {"op": "aggregate", "args": [], "output_idx": ["i"],
             "ranges": {"i": [1, 6]},
             "expr": {"op": "*", "args": [-0.5, {"op": "index", "args": ["u", "i"]}]}}
    }
   ]
  }
 }
}"#;

#[test]
fn ess_tape_disable_reverts_wholesale_to_the_legacy_path() {
    // Set BEFORE anything can initialize the OnceLock (this is the only test
    // in this binary, so nothing has queried it yet).
    unsafe { std::env::set_var("ESS_TAPE_DISABLE", "1") };

    let file = load(MODEL).expect("load model");
    let compiled = ArrayCompiled::from_file(&file).expect("compile model");

    // The taped debug scratch honors the switch: no tape is installed…
    let mut scratch = compiled.debug_new_scratch_taped();
    assert!(
        !scratch.has_tape(),
        "ESS_TAPE_DISABLE=1 must prevent tape installation"
    );

    // …and evaluation runs the legacy interpreter (taped_rules stays 0, the
    // vectorized overlay still runs), producing the oracle's exact bits.
    let n = compiled.state_variable_names().len();
    let params = compiled.debug_resolve_params(&HashMap::new());
    let state: Vec<f64> = (0..n).map(|k| 1.0 + 0.25 * k as f64).collect();
    let mut dy = vec![0.0f64; n];
    let mut stats = RhsStats::default();
    compiled.debug_eval_rhs_into(&state, 0.0, &params, &mut dy, &mut scratch, &mut stats);
    assert_eq!(stats.taped_rules, 0, "no rule may run through the tape");
    assert_eq!(stats.fallback_rules, 0);
    assert!(stats.vectorized_rules > 0, "legacy vectorized path must run");
    let (oracle, _) = compiled.debug_eval_rhs(&state, 0.0, &HashMap::new(), false);
    for (a, b) in dy.iter().zip(oracle.iter()) {
        assert_eq!(a.to_bits(), b.to_bits());
    }

    // The full `simulate` path also completes on the legacy closure: u decays
    // exponentially, u(1) = u0 · e^(−0.5).
    let opts = SimulateOptions {
        solver: SolverChoice::Erk,
        reltol: 1e-10,
        abstol: 1e-12,
        output_times: Some(vec![1.0]),
        ..Default::default()
    };
    let ics: HashMap<String, f64> = (1..=n)
        .map(|k| (format!("u[{k}]"), 2.0))
        .collect();
    let sol = simulate(&file, (0.0, 1.0), &HashMap::new(), &ics, &opts)
        .expect("legacy simulate must run");
    let ti = sol.time.len() - 1;
    let want = 2.0 * (-0.5f64).exp();
    for k in 0..n {
        assert!(
            (sol.state[k][ti] - want).abs() < 1e-6,
            "u[{k}](1) = {} != {want}",
            sol.state[k][ti]
        );
    }
}
