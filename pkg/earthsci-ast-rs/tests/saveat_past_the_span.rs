//! Issue #478: an output time past the end of the span.
//!
//! A solve integrates the span its problem was built over, and diffsol cannot
//! interpolate past its stop time: BDF refuses with "Interpolation time is after
//! current time", and SDIRK and the explicit Runge-Kutta method with
//! "Interpolation time is not within the current step". A driver that asks it
//! to for a `saveat` time past `t_end` fails a run that has integrated its
//! whole span. Such a time is not on the trajectory, and is left out of it, as
//! the segmented path leaves it out.

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::{
    Alg, Compiler, ProblemOptions, Rhs, Solution, SolveOptions, esm_problem, load_string, solve,
};

/// One-dimensional diffusion over `n` cells with zero-valued ghosts, the
/// shape the issue was reported on.
fn diffusion_doc(n: usize) -> String {
    let at = |shift: i64| {
        let i = match shift {
            0 => r#""i""#.to_string(),
            s if s > 0 => format!(r#"{{"op": "+", "args": ["i", {s}]}}"#),
            s => format!(r#"{{"op": "-", "args": ["i", {}]}}"#, -s),
        };
        format!(r#"{{"op": "index", "args": ["u", {i}]}}"#)
    };
    format!(
        r#"{{
 "esm": "1.1.0",
 "metadata": {{"name": "diffusion_1d", "description": "1-D diffusion"}},
 "index_sets": {{"x": {{"kind": "interval", "size": {n}}}}},
 "models": {{"Diffusion": {{
  "variables": {{
   "u": {{"type": "unknown", "units": "1", "default": 1.0, "shape": ["x"]}},
   "kappa": {{"type": "parameter", "units": "1", "default": 0.1}}
  }},
  "equations": [{{
   "lhs": {{"op": "faq", "args": [], "output_idx": ["i"], "ranges": {{"i": [1, {n}]}},
           "expr": {{"op": "D", "args": [{center}], "wrt": "t"}}}},
   "rhs": {{"op": "faq", "args": [], "output_idx": ["i"], "ranges": {{"i": [1, {n}]}},
           "expr": {{"op": "*", "args": ["kappa", {{"op": "-", "args": [
             {{"op": "+", "args": [{left}, {right}]}},
             {{"op": "*", "args": [2, {center}]}}]}}]}}}}
  }}]
 }}}}
}}"#,
        center = at(0),
        left = at(-1),
        right = at(1),
    )
}

fn run(alg: Alg, saveat: Vec<f64>) -> Solution {
    let file = load_string(&diffusion_doc(64)).expect("fixture loads");
    let prob = esm_problem(
        &file,
        (0.0, 1.0),
        ProblemOptions {
            compiler: Some(Compiler::Native),
            rhs: Rhs::Always,
            ..Default::default()
        },
    )
    .expect("fixture builds");
    solve(
        &prob,
        &SolveOptions {
            alg,
            saveat: Some(saveat),
            ..Default::default()
        },
    )
    .unwrap_or_else(|e| panic!("{alg:?}: {e}"))
}

/// A grid that runs past `t_end` is answered up to `t_end`, and the answered
/// part is bit-for-bit the answer to the same grid without the extra time.
#[test]
fn a_time_past_the_span_is_left_out_under_every_method() {
    for alg in [Alg::Bdf, Alg::Sdirk, Alg::Erk] {
        let past = run(alg, vec![0.0, 0.5, 1.0, 10.0]);
        let inside = run(alg, vec![0.0, 0.5, 1.0]);
        assert!(past.retcode.is_success(), "{alg:?}: {:?}", past.retcode);
        assert_eq!(past.time, vec![0.0, 0.5, 1.0], "{alg:?}");
        assert_eq!(past.state_variable_names, inside.state_variable_names);
        for (name, (a, b)) in past
            .state_variable_names
            .iter()
            .zip(past.state.iter().zip(&inside.state))
        {
            let bits = |r: &[f64]| r.iter().map(|v| v.to_bits()).collect::<Vec<_>>();
            assert_eq!(bits(a), bits(b), "{alg:?}: row `{name}` differs");
        }
    }
}

/// The issue's own shape: a problem over `(0, 1)` asked for `[0, 10]`. The run
/// integrates its span and reports the one requested time on it.
#[test]
fn the_reported_grid_solves_under_bdf() {
    let sol = run(Alg::Bdf, vec![0.0, 10.0]);
    assert!(sol.retcode.is_success(), "{:?}", sol.retcode);
    assert_eq!(sol.time, vec![0.0]);
    assert!(
        sol.metadata.n_accepted_steps > 0,
        "the span must be integrated"
    );
}
