//! Issue #438: a run that never advances must not build a solver.
//!
//! The document under test is the issue's minimal reproducer — a §4.3.1.1
//! causal self-reference (`rad[g,l]` reading `rad[g,l-1]`, the shape every
//! two-stream radiative sweep has) over a column `x` — in two arms that differ
//! in ONE equation:
//!
//! * `x` is an algebraic observed, so the document has no ODE state at all;
//! * `x` is a FROZEN ODE state (`D(x) = 0`, `ic(x) =` the same `faq`), so the
//!   document has one state per level and the recurrence sits downstream of it.
//!
//! The two compute the same number, bit for bit, and the recurrence sweeps once
//! either way — so any difference in cost between the arms belongs to the state.
//!
//! BOTH arms are asked for an EMPTY time span (esm-spec §6.6.2's
//! instantaneous-derivative shape, `{start: 0, end: 0}`), which integrates
//! nothing. Building a diffsol solver for such a run is what these tests forbid:
//! an implicit method materializes a dense Jacobian on construction, this
//! crate's Jacobian is matrix-free finite differences, and so diffsol pays one
//! closure call per state column with each call evaluating the whole right-hand
//! side twice — `2·n_states + 1` full RHS evaluations, every observed
//! re-materialized in each, to produce a trajectory that is the untouched
//! initial state. With the state count and the per-evaluation cost both growing
//! with the column, that is quadratic in the column length.
//!
//! These tests pin the shape of the cost, not only the answer.

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::{
    EsmProblem, Flow, ProblemOptions, Rhs, SimulateError, SolveOptions, esm_problem,
    load_string, solve,
};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Instant;

/// The issue's reproducer at `nl` levels and `ng` independent columns.
///
/// `state_leaf` picks the arm: `false` writes `x` as an algebraic observed,
/// `true` writes the identical values as a frozen ODE state. Nothing else
/// differs, so any difference in cost between the two belongs to the state.
fn doc(nl: usize, ng: usize, state_leaf: bool) -> String {
    // `x` — one equation, or the two that make the same column a state.
    let x_equations = if state_leaf {
        r#"{"lhs": {"op": "D", "args": ["x"], "wrt": "t"}, "rhs": 0.0},
           {"lhs": {"op": "ic", "args": ["x"]}, "rhs": {"op": "faq", "output_idx": ["k"], "args": [],
             "ranges": {"k": {"from": "lev"}},
             "expr": {"op": "+", "args": [200.0, {"op": "/", "args": ["k", 100.0]}]}}},"#
    } else {
        r#"{"lhs": "x", "rhs": {"op": "faq", "output_idx": ["k"], "args": [],
             "ranges": {"k": {"from": "lev"}},
             "expr": {"op": "+", "args": [200.0, {"op": "/", "args": ["k", 100.0]}]}}},"#
    };
    format!(
        r#"{{
 "esm": "1.1.0",
 "metadata": {{"name": "StateLeaf", "license": "MIT",
  "description": "Self-referential faq recurrence over a column that is either an observed or a state."}},
 "metaparameters": {{
  "NL": {{"type": "integer", "default": {nl}, "description": "Recurrence length."}},
  "NG": {{"type": "integer", "default": {ng}, "description": "Independent columns (g-points)."}}
 }},
 "index_sets": {{
  "lev": {{"kind": "interval", "size": "NL"}},
  "gpt": {{"kind": "interval", "size": "NG"}}
 }},
 "models": {{
  "M": {{
   "variables": {{
    "x":     {{"type": "unknown", "units": "1", "shape": ["lev"], "description": "The column the recurrence depends on."}},
    "tau":   {{"type": "unknown", "units": "1", "shape": ["gpt", "lev"], "description": "Per-column optical depth built from x."}},
    "rad":   {{"type": "unknown", "units": "1", "shape": ["gpt", "lev"], "description": "The sweep: rad[g,l] depends on rad[g,l-1]."}},
    "out":   {{"type": "unknown", "units": "1", "shape": ["lev"], "description": "Sum of the sweep over g."}},
    "total": {{"type": "unknown", "units": "1", "description": "The single asserted number."}}
   }},
   "equations": [
    {x_equations}
    {{"lhs": "tau", "rhs": {{"op": "faq", "output_idx": ["g", "l"], "args": [], "ranges": {{"g": {{"from": "gpt"}}, "l": {{"from": "lev"}}}},
      "expr": {{"op": "*", "args": [{{"op": "/", "args": [{{"op": "index", "args": ["x", "l"]}}, 20000.0]}},
                                   {{"op": "+", "args": [1.0, {{"op": "/", "args": ["g", 1000.0]}}]}}]}}}}}},
    {{"lhs": "rad", "rhs": {{"op": "faq", "output_idx": ["g", "l"], "args": [], "ranges": {{"g": {{"from": "gpt"}}, "l": {{"from": "lev"}}}},
      "expr": {{"op": "ifelse", "args": [
        {{"op": "==", "args": ["l", 1]}},
        1.0,
        {{"op": "+", "args": [
          {{"op": "*", "args": [{{"op": "index", "args": ["rad", "g", {{"op": "-", "args": ["l", 1]}}]}},
                               {{"op": "exp", "args": [{{"op": "*", "args": [-1.0, {{"op": "index", "args": ["tau", "g", "l"]}}]}}]}}]}},
          {{"op": "index", "args": ["tau", "g", "l"]}}]}}]}}}}}},
    {{"lhs": "out", "rhs": {{"op": "faq", "output_idx": ["l"], "args": [], "ranges": {{"l": {{"from": "lev"}}, "g": {{"from": "gpt"}}}},
      "reduce": "+", "expr": {{"op": "index", "args": ["rad", "g", "l"]}}}}}},
    {{"lhs": "total", "rhs": {{"op": "faq", "output_idx": [], "args": [], "ranges": {{"l": {{"from": "lev"}}}},
      "reduce": "+", "expr": {{"op": "index", "args": ["out", "l"]}}}}}}
   ]
  }}
 }}
}}"#
    )
}

/// Solve one arm over the EMPTY span `[0, 0]`, asking for `total`.
fn run_empty_span(json: &str) -> earthsci_ast::Solution {
    run_span(json, (0.0, 0.0), None)
}

/// Build one arm over `tspan`. Separate from the solve so a test that measures
/// the solve can leave the build outside its timer.
fn problem_for(json: &str, tspan: (f64, f64)) -> EsmProblem {
    let file = load_string(json).expect("the reproducer loads");
    esm_problem(
        &file,
        tspan,
        ProblemOptions {
            rhs: Rhs::Always,
            ..Default::default()
        },
    )
    .expect("the reproducer builds")
}

/// Ask for `total` at `saveat` (the runner's own grid when `None`).
fn solve_opts(saveat: Option<Vec<f64>>) -> SolveOptions {
    SolveOptions {
        output_observed: vec!["total".to_string()],
        saveat,
        ..Default::default()
    }
}

/// Solve one arm over `tspan`, asking for `total` at `saveat` (the runner's own
/// grid when `None`).
fn run_span(json: &str, tspan: (f64, f64), saveat: Option<Vec<f64>>) -> earthsci_ast::Solution {
    let prob = problem_for(json, tspan);
    solve(&prob, &solve_opts(saveat)).expect("the reproducer solves")
}

/// The one value the document computes, read off whichever row carries it (a
/// single-model document may or may not qualify the name).
fn total(sol: &earthsci_ast::Solution) -> f64 {
    let i = sol
        .state_variable_names
        .iter()
        .position(|n| n == "total" || n.ends_with(".total"))
        .unwrap_or_else(|| panic!("no `total` row; rows are {:?}", sol.state_variable_names));
    *sol.state[i].last().expect("the row has a value")
}

/// Semantics first: skipping the solver must not move the answer. Both arms
/// produce the issue's number, and produce it BIT-IDENTICALLY to each other —
/// the recurrence is evaluated by the same sweep whether or not its leaf is a
/// state, and an empty span integrates nothing in either arm.
#[test]
fn both_arms_agree_bit_for_bit_on_an_empty_span() {
    let observed = total(&run_empty_span(&doc(103, 140, false)));
    let state = total(&run_empty_span(&doc(103, 140, true)));
    assert_eq!(
        observed.to_bits(),
        state.to_bits(),
        "the observed arm gave {observed:?} and the state arm {state:?}"
    );
    assert_eq!(
        observed, 14450.338994229463,
        "the reproducer's documented value moved"
    );
}

/// The mechanism, asserted directly and machine-independently: over an empty
/// span the state arm must reach diffsol not at all, so the solver's own
/// right-hand-side and Jacobian counters stay at zero however many states the
/// document has. A run that builds a solver for this span instead reports the
/// Jacobian build and the RHS evaluations that constructing one costs.
#[test]
fn an_empty_span_evaluates_no_right_hand_side_at_all() {
    let sol = run_empty_span(&doc(103, 140, true));
    assert!(
        sol.retcode.is_success(),
        "an empty span is a successful run, got {:?}",
        sol.retcode
    );
    assert_eq!(
        (sol.metadata.n_rhs_calls, sol.metadata.n_jacobian_calls),
        (0, 0),
        "an empty span built a solver: {} RHS and {} Jacobian evaluations",
        sol.metadata.n_rhs_calls,
        sol.metadata.n_jacobian_calls
    );
    // Same document, same span, no states: the baseline the state arm has to
    // match. It never built a solver either, and that is the whole point.
    let free = run_empty_span(&doc(103, 140, false));
    assert_eq!(
        (free.metadata.n_rhs_calls, free.metadata.n_jacobian_calls),
        (0, 0)
    );
}

/// The complexity, pinned the way `cumulative_prefix_scan.rs` pins the prefix
/// scan's: counting evaluations is not observable from outside, so assert that
/// multiplying the column length by 8 does not multiply the work by anything
/// like 64. A wall-clock ceiling is deliberately loose — it must fail only on a
/// genuine return to the per-state Jacobian, never on a contended machine.
///
/// The document build is OUTSIDE the timer — [`problem_for`] runs once per
/// column length and the timer wraps only [`solve`] — so what is timed is the
/// solve: the recurrence sweep, whose cost is `NG · NL`, plus whatever the run
/// does around it. Linear in `NL` is ~8x; the `2·n_states + 1` Jacobian arm is
/// ~64x.
#[test]
fn state_leaf_recurrence_stays_linear_in_the_column_length() {
    const NG: usize = 40;

    let timed = |nl: usize| -> f64 {
        let prob = problem_for(&doc(nl, NG, true), (0.0, 0.0));
        let opts = solve_opts(None);
        let _ = solve(&prob, &opts).expect("the reproducer solves"); // warm caches
        (0..3)
            .map(|_| {
                let t0 = Instant::now();
                let _ = solve(&prob, &opts).expect("the reproducer solves");
                t0.elapsed().as_secs_f64()
            })
            .fold(f64::INFINITY, f64::min)
    };

    let small = timed(100);
    let large = timed(800);
    let ratio = large / small.max(1e-9);
    assert!(
        ratio < 24.0,
        "the state-leaf recurrence looks quadratic: NL=100 took {small:.6}s, \
         NL=800 took {large:.6}s (ratio {ratio:.1}x for an 8x increase in NL). \
         A single sweep should be near 8x; a Jacobian built one column per \
         state would be near 64x."
    );
}

/// The second shape the same check covers: a NON-empty span whose whole output
/// grid sits at `t0`. That is what an inline test asks for when the document
/// declares `{start: 0, end: 1}` and every assertion is at the initial instant
/// — the runner's `saveat` is then `[0.0]` — and the solver loop answers it by
/// draining that grid point from the initial state and breaking before its
/// first step. It never has to be built to do that.
#[test]
fn an_output_grid_that_never_leaves_the_start_builds_no_solver_either() {
    let sol = run_span(&doc(103, 140, true), (0.0, 1.0), Some(vec![0.0]));
    assert_eq!(sol.time, vec![0.0], "the grid the caller asked for");
    assert_eq!(
        (sol.metadata.n_rhs_calls, sol.metadata.n_jacobian_calls),
        (0, 0),
        "a grid that asks for nothing past t0 built a solver: {} RHS and {} \
         Jacobian evaluations",
        sol.metadata.n_rhs_calls,
        sol.metadata.n_jacobian_calls
    );
    assert_eq!(
        total(&sol),
        14450.338994229463,
        "the answer at t0 is the answer at t0 whatever the span says"
    );
}

/// The complementary guard: a span the run really does have to cross must
/// still be integrated. The same document over `[0, 1]` with no grid steps,
/// evaluates its right-hand side, and returns more than the initial point —
/// so the check above can only be reached by a run that never advances.
#[test]
fn a_span_that_must_be_crossed_is_still_integrated() {
    let sol = run_span(&doc(8, 4, true), (0.0, 1.0), None);
    assert!(
        sol.time.len() > 1 && sol.time.last() == Some(&1.0),
        "the run must reach t = 1, got {:?}",
        sol.time
    );
    assert!(
        sol.metadata.n_rhs_calls > 0,
        "an integrated span must evaluate the right-hand side"
    );
}

/// The output SHAPE the shortcut owns: under an empty span the caller's whole
/// requested grid is answered, verbatim and in order, from the initial state —
/// including a time beyond the span, which is the courtesy extrapolation the
/// solver loop's `saveat` tail performs for a run that does step. Every row is
/// constant across the grid, because nothing moved.
#[test]
fn an_empty_span_answers_the_whole_requested_grid() {
    let sol = run_span(&doc(8, 4, true), (0.0, 0.0), Some(vec![0.0, 0.5, 1.0]));
    assert_eq!(
        sol.time,
        vec![0.0, 0.5, 1.0],
        "the grid the caller asked for"
    );
    for (row, name) in sol.state.iter().zip(&sol.state_variable_names) {
        assert_eq!(row.len(), 3, "row `{name}` is short: {row:?}");
        assert!(
            row.iter().all(|v| v.to_bits() == row[0].to_bits()),
            "row `{name}` moved over a span that integrates nothing: {row:?}"
        );
    }
}

/// The one thing the shortcut still owes a host: the single step-0 progress
/// report `run_solver` makes before it steps, so a caller that renders a
/// determinate 0% gets it whether or not the run turns out to advance. A run
/// that never advances reports once, at `t0`, and never again.
#[test]
fn a_run_that_never_advances_still_makes_its_step_zero_report() {
    let prob = problem_for(&doc(8, 4, true), (0.0, 0.0));
    let seen = Arc::new(AtomicUsize::new(0));
    let at_t0 = Arc::new(AtomicUsize::new(0));
    let (seen_cb, at_t0_cb) = (Arc::clone(&seen), Arc::clone(&at_t0));
    let opts = SolveOptions {
        progress: Some(Arc::new(move |p: &earthsci_ast::Progress<'_>| {
            seen_cb.fetch_add(1, Ordering::SeqCst);
            if p.step == 0 && p.t == 0.0 {
                at_t0_cb.fetch_add(1, Ordering::SeqCst);
            }
            Flow::Continue
        })),
        ..solve_opts(None)
    };
    let sol = solve(&prob, &opts).expect("the reproducer solves");
    assert!(sol.retcode.is_success());
    assert_eq!(
        (seen.load(Ordering::SeqCst), at_t0.load(Ordering::SeqCst)),
        (1, 1),
        "expected exactly one report, made at step 0 and `t0`"
    );
}

/// A scalar document — no arrays, no index sets — so it compiles to the OTHER
/// backend. The span check has to hold on both, and nothing else in this file
/// reaches the scalar one.
fn scalar_doc() -> String {
    r#"{
 "esm": "1.1.0",
 "metadata": {"name": "Decay", "license": "MIT",
  "description": "One scalar state, so this document compiles to the scalar backend."},
 "models": {
  "M": {
   "variables": {
    "y": {"type": "unknown", "units": "1", "description": "The single state."}
   },
   "equations": [
    {"lhs": {"op": "D", "args": ["y"], "wrt": "t"}, "rhs": {"op": "*", "args": [-1.0, "y"]}},
    {"lhs": {"op": "ic", "args": ["y"]}, "rhs": 1.0}
   ]
  }
 }
}"#
    .to_string()
}

/// The boundary of the shortcut on the other side: a span that is not a span at
/// all. `NaN` makes every ordering test false, which would fall through to the
/// non-advancing answer and hand back the initial state as a trajectory; an
/// infinite end is a stop time no solver loop reaches. Both are refused, on both
/// backends, ahead of the branch — while the two spans that ARE answered from
/// the initial state, the empty one and the backwards one, keep being answered.
#[test]
fn a_non_finite_span_is_refused_while_empty_and_backwards_ones_are_answered() {
    for (backend, json) in [("array", doc(8, 4, true)), ("scalar", scalar_doc())] {
        for (start, end) in [
            (f64::NAN, 1.0),
            (0.0, f64::NAN),
            (f64::NEG_INFINITY, 0.0),
            (0.0, f64::INFINITY),
        ] {
            let prob = problem_for(&json, (start, end));
            match solve(&prob, &solve_opts(None)) {
                Err(SimulateError::InvalidTimeSpan { start: s, end: e }) => {
                    assert_eq!(
                        (s.to_bits(), e.to_bits()),
                        (start.to_bits(), end.to_bits()),
                        "{backend} backend: the error must carry the span it refused"
                    );
                }
                other => {
                    panic!("{backend} backend: span ({start}, {end}) was not refused: {other:?}")
                }
            }
        }

        // The empty span is still answered from the initial state, at `t0`.
        let empty = run_span(&json, (0.0, 0.0), None);
        assert!(empty.retcode.is_success(), "{backend} backend");
        assert_eq!(empty.time, vec![0.0], "{backend} backend");

        // So is a BACKWARDS span, unchanged: an interval the run cannot advance
        // over, not a malformed one.
        let backwards = run_span(&json, (1.0, 0.0), None);
        assert!(backwards.retcode.is_success(), "{backend} backend");
        assert_eq!(backwards.time, vec![1.0], "{backend} backend");
        assert_eq!(
            backwards.state, empty.state,
            "{backend} backend: both answer from the same untouched initial state"
        );
    }
}
