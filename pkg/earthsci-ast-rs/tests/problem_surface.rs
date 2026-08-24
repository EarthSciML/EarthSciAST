//! The Problem / `solve` surface (`esm-libraries-spec.md` §2.5, `API_SPEC.md`
//! §5.8).
//!
//! One noun and one verb: `esm_problem` builds, `solve` runs. `simulate` does
//! not exist. What this file pins is the behaviour the section argues for
//! rather than the spellings — the spellings are pinned by `api_surface.rs`:
//!
//! * §2.5.3 — a `retcode` from the SciML vocabulary, not step counters read as
//!   a proxy for "did it finish";
//! * §2.5.4 — a `callback` argument to `solve` REPLACES the Problem's set;
//! * §2.5.5 — `remake` shares the compiled RHS, never mutates, and REFUSES a
//!   substitution it cannot honour;
//! * §2.5.6 — the `init` / `step` / `solve_to_completion` lifecycle;
//! * §2.5.7 — a solution indexed by variable name;
//! * §2.5.8 — `EnsembleProblem`.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use earthsci_ast::{
    Alg, CallbackFn, CallbackSet, Compile, EnsembleProblem, Flow, Problem, ProblemOptions,
    Progress, Remake, ReturnCode, SimulateError, SolveOptions, callbacks, compose, esm_problem,
    init, load_string, observed_field, remake, solve, solve_ensemble, step,
};

/// `D(y)/Dt = k*y`, `k = -1`, `y(0) = 1` — so `y(t) = exp(-t)`.
const DECAY: &str = r#"
    {
      "esm": "1.0.0",
      "metadata": { "name": "problem_surface_decay" },
      "models": {
        "M": {
          "variables": {
            "y": { "type": "unknown", "default": 1.0 },
            "k": { "type": "parameter", "default": -1.0 }
          },
          "equations": [
            {
              "lhs": { "op": "D", "args": ["y"], "wrt": "t" },
              "rhs": { "op": "*", "args": ["k", "y"] }
            }
          ]
        }
      }
    }
    "#;

/// A document with no differential equations at all: nothing to integrate.
const STATIC_DOC: &str = r#"
    {
      "esm": "1.0.0",
      "metadata": { "name": "problem_surface_static" },
      "models": {
        "M": {
          "variables": {
            "a": { "type": "parameter", "default": 2.0 },
            "b": { "type": "unknown" }
          },
          "equations": [
            { "lhs": "b", "rhs": { "op": "*", "args": ["a", "a"] } }
          ]
        }
      }
    }
    "#;

fn decay_problem(tspan: (f64, f64)) -> Problem {
    let file = load_string(DECAY).expect("load");
    esm_problem(
        &file,
        tspan,
        ProblemOptions {
            compile: Compile::Always,
            ..Default::default()
        },
    )
    .expect("build")
}

/// Per-run knobs for a test that ASSERTS A TRAJECTORY.
///
/// Explicit, deliberately. [`SolveOptions`]'s defaults are Julia's production
/// pair (`reltol = 1e-4`, `abstol = 1e-6`), which leave ~5e-6 of truncation
/// error on the decay problem over `[0, 1]` and ~1e-2 relative over `[0, 10]`.
/// A test that pins a value to a threshold sets the tolerance it needs rather
/// than leaning on a default that is not chosen for it — and rather than
/// widening its own comparison epsilon, which would measure nothing.
fn tight(saveat: Option<Vec<f64>>) -> SolveOptions {
    SolveOptions {
        abstol: 1e-12,
        reltol: 1e-10,
        saveat,
        ..Default::default()
    }
}

fn grid(t_end: f64, n: usize) -> Option<Vec<f64>> {
    Some(
        (0..=n)
            .map(|i| t_end * (i as f64) / (n as f64))
            .collect::<Vec<_>>(),
    )
}

// ===========================================================================
// §2.5.1 / §2.5.2 — build once, run per knob-set
// ===========================================================================

/// The split is the point: one Problem, many solves, and the solves do not
/// re-do the build.
#[test]
fn one_problem_serves_many_solves() {
    let prob = decay_problem((0.0, 1.0));
    for (alg, reltol) in [(Alg::Bdf, 1e-10), (Alg::Sdirk, 1e-9), (Alg::Erk, 1e-8)] {
        let sol = solve(
            &prob,
            &SolveOptions {
                alg,
                reltol,
                abstol: 1e-12,
                saveat: grid(1.0, 4),
                ..Default::default()
            },
        )
        .expect("solve");
        assert_eq!(sol.retcode, ReturnCode::Success);
        let want = (-1.0f64).exp();
        let got = sol.final_value("M.y").expect("y");
        assert!(
            (got - want).abs() < 1e-5,
            "{alg:?}: y(1) = {got}, want {want}"
        );
    }
}

/// The default tolerances are Julia's, in every binding. Rust's own pair was
/// `1e-6`/`1e-8` — two orders TIGHTER — so aligning loosens it.
#[test]
fn the_default_tolerances_are_julias() {
    assert_eq!(earthsci_ast::DEFAULT_RELTOL, 1e-4);
    assert_eq!(earthsci_ast::DEFAULT_ABSTOL, 1e-6);
    let d = SolveOptions::default();
    assert_eq!(d.reltol, earthsci_ast::DEFAULT_RELTOL);
    assert_eq!(d.abstol, earthsci_ast::DEFAULT_ABSTOL);
}

/// What the defaults cost, measured rather than assumed — and the reason every
/// trajectory assertion in this file sets its own tolerance.
///
/// The default pair is a *production* setting: it is meant to integrate a model
/// at a sensible cost, not to certify a number. On plain exponential decay over
/// `[0, 10]` it lands ~1e-2 relative from the analytic answer, while an
/// explicit `1e-10`/`1e-12` lands ~4e-8. Both are correct behaviour for the
/// tolerance asked for; only one of them can carry a conformance assertion.
#[test]
fn the_default_tolerances_are_a_production_setting_not_a_test_setting() {
    let prob = decay_problem((0.0, 10.0));
    let want = (-10.0f64).exp();
    let rel = |sol: earthsci_ast::Solution| (sol.final_value("M.y").unwrap() - want).abs() / want;

    let loose = rel(solve(
        &prob,
        &SolveOptions {
            saveat: Some(vec![10.0]),
            ..Default::default()
        },
    )
    .expect("solve"));
    let pinned = rel(solve(&prob, &tight(Some(vec![10.0]))).expect("solve"));

    assert!(
        loose < 1e-1,
        "the default must still be a usable answer: {loose:e}"
    );
    assert!(
        pinned < 1e-6,
        "an explicitly-pinned solve must be accurate: {pinned:e}"
    );
    assert!(
        pinned < loose,
        "asking for a tighter tolerance must buy accuracy: {pinned:e} vs {loose:e}"
    );
}

/// Construction does not require the solver (§2.5.9). This asserts the shape of
/// that claim that a test CAN assert — a Problem builds and reports its
/// structure with no solve — while the Cargo feature itself is what makes
/// `diffsol` absent from the dependency graph.
#[test]
fn a_problem_is_useful_without_solving_it() {
    let prob = decay_problem((0.0, 1.0));
    assert!(prob.is_dynamic());
    assert_eq!(prob.tspan(), (0.0, 1.0));
    assert_eq!(prob.state_variable_names(), vec!["M.y".to_string()]);
    assert_eq!(prob.parameter_names(), vec!["M.k".to_string()]);
}

/// A document with nothing to integrate still gets a Problem — its build-time
/// products are the result — and `solve` says so in a distinguishable way
/// rather than handing back an empty trajectory.
#[test]
fn a_static_document_builds_but_does_not_solve() {
    let file = load_string(STATIC_DOC).expect("load");
    let prob = esm_problem(&file, (0.0, 1.0), ProblemOptions::default()).expect("build");
    assert!(!prob.is_dynamic());
    assert_eq!(prob.backend_kind(), "static");
    match solve(&prob, &SolveOptions::default()) {
        Err(SimulateError::NotDynamic { details }) => {
            assert!(
                details.contains("differential"),
                "unhelpful reason: {details}"
            );
        }
        other => panic!("expected NotDynamic, got {other:?}"),
    }
}

// ===========================================================================
// §2.5.3 — the return code
// ===========================================================================

/// Hitting the iteration cap is a RETURN CODE with a partial trajectory, not an
/// error. The counters are statistics; `retcode` is the answer.
#[test]
fn maxiters_is_a_retcode_not_an_error() {
    let prob = decay_problem((0.0, 20.0));
    let sol = solve(
        &prob,
        &SolveOptions {
            maxiters: 3,
            ..Default::default()
        },
    )
    .expect("a capped run returns, it does not raise");
    assert_eq!(sol.retcode, ReturnCode::MaxIters);
    assert!(!sol.retcode.is_success());
    let t_last = *sol.time.last().expect("partial trajectory");
    assert!(t_last < 20.0, "a capped run cannot have reached t_end");
    // The trajectory is real, not a stub.
    assert!(sol.final_value("M.y").unwrap() > 0.0);
}

/// A run that covers the interval says `Success`, and says it without the
/// caller inspecting a step count.
#[test]
fn a_completed_run_reports_success() {
    let sol = solve(&decay_problem((0.0, 2.0)), &SolveOptions::default()).expect("solve");
    assert_eq!(sol.retcode, ReturnCode::Success);
    assert_eq!(sol.retcode.name(), "Success");
    assert!((sol.time.last().unwrap() - 2.0).abs() < 1e-9);
}

// ===========================================================================
// §2.5.4 — callbacks live on the Problem; `solve`'s argument REPLACES them
// ===========================================================================

fn counting_callback() -> (CallbackFn, Arc<Mutex<usize>>) {
    let n = Arc::new(Mutex::new(0usize));
    let sink = n.clone();
    let f: CallbackFn = Arc::new(move |_: &Progress<'_>| {
        *sink.lock().unwrap() += 1;
        Flow::Continue
    });
    (f, n)
}

fn problem_with_callbacks(set: CallbackSet) -> Problem {
    let file = load_string(DECAY).expect("load");
    esm_problem(
        &file,
        (0.0, 2.0),
        ProblemOptions {
            compile: Compile::Always,
            callbacks: set,
            ..Default::default()
        },
    )
    .expect("build")
}

#[test]
fn a_problem_level_callback_runs_and_is_readable_back() {
    let (cb, n) = counting_callback();
    let prob = problem_with_callbacks(CallbackSet::of("count", cb));
    assert_eq!(callbacks(&prob).names(), vec!["count"]);

    solve(&prob, &SolveOptions::default()).expect("solve");
    assert!(*n.lock().unwrap() > 1, "the Problem's callback never ran");
}

/// The one genuinely ambiguous point in the design, settled deliberately:
/// `solve`'s `callback` REPLACES. It does not append, merge or wrap.
#[test]
fn solves_callback_argument_replaces_the_problems_set() {
    let (on_problem, problem_hits) = counting_callback();
    let (on_run, run_hits) = counting_callback();

    let prob = problem_with_callbacks(CallbackSet::of("on_problem", on_problem));
    solve(
        &prob,
        &SolveOptions {
            callback: Some(CallbackSet::of("on_run", on_run)),
            ..Default::default()
        },
    )
    .expect("solve");

    assert_eq!(
        *problem_hits.lock().unwrap(),
        0,
        "the Problem's callback ran anyway — the run's set must REPLACE it"
    );
    assert!(
        *run_hits.lock().unwrap() > 1,
        "the run's callback never ran"
    );
}

/// A caller who wants to EXTEND reads the set back and composes explicitly.
/// This is why `callbacks(prob)` is stable API: without it, replacement
/// semantics would make a Problem-level callback impossible to extend.
#[test]
fn compose_is_how_a_caller_extends_rather_than_replaces() {
    let (on_problem, problem_hits) = counting_callback();
    let (extra, extra_hits) = counting_callback();

    let prob = problem_with_callbacks(CallbackSet::of("on_problem", on_problem));
    let both = compose(callbacks(&prob), &CallbackSet::of("extra", extra));
    assert_eq!(both.names(), vec!["on_problem", "extra"]);

    solve(
        &prob,
        &SolveOptions {
            callback: Some(both),
            ..Default::default()
        },
    )
    .expect("solve");

    assert!(*problem_hits.lock().unwrap() > 1);
    assert!(*extra_hits.lock().unwrap() > 1);
}

/// A callback that asks to stop ends the run with `Terminated` and the
/// trajectory computed so far — the caller's own decision, not a failure.
#[test]
fn a_callback_can_terminate_the_run() {
    let stop: CallbackFn = Arc::new(|p: &Progress<'_>| {
        if p.step >= 2 {
            Flow::Cancel
        } else {
            Flow::Continue
        }
    });
    let prob = problem_with_callbacks(CallbackSet::of("stop", stop));
    let sol = solve(&prob, &SolveOptions::default()).expect("a cancel is a retcode");
    assert_eq!(sol.retcode, ReturnCode::Terminated);
    assert!(*sol.time.last().unwrap() < 2.0);
}

// ===========================================================================
// §2.5.5 — remake
// ===========================================================================

#[test]
fn remake_substitutes_without_mutating_the_original() {
    let prob = decay_problem((0.0, 1.0));
    let faster = remake(
        &prob,
        &Remake {
            p: HashMap::from([("k".to_string(), -2.0)]),
            ..Default::default()
        },
    )
    .expect("remake");

    // The original is untouched.
    assert!(prob.p().is_empty(), "remake mutated the original's p");
    assert_eq!(faster.p().get("k"), Some(&-2.0));

    let base = solve(&prob, &tight(Some(vec![1.0]))).expect("solve base");
    let quick = solve(&faster, &tight(Some(vec![1.0]))).expect("solve remade");

    assert!((base.final_value("M.y").unwrap() - (-1.0f64).exp()).abs() < 1e-6);
    assert!((quick.final_value("M.y").unwrap() - (-2.0f64).exp()).abs() < 1e-6);
}

#[test]
fn remake_can_move_the_interval_and_the_initial_state() {
    let prob = decay_problem((0.0, 1.0));
    let moved = remake(
        &prob,
        &Remake {
            u0: HashMap::from([("y".to_string(), 2.0)]),
            tspan: Some((0.0, 3.0)),
            ..Default::default()
        },
    )
    .expect("remake");
    assert_eq!(moved.tspan(), (0.0, 3.0));
    let sol = solve(&moved, &tight(Some(vec![3.0]))).expect("solve");
    let want = 2.0 * (-3.0f64).exp();
    assert!((sol.final_value("M.y").unwrap() - want).abs() < 1e-6);
}

/// A substitution the Problem cannot honour RAISES, naming the binding and the
/// class — it does not silently rebuild and does not silently ignore.
#[test]
fn remake_refuses_a_substitution_it_cannot_honour() {
    let prob = decay_problem((0.0, 1.0));
    match remake(
        &prob,
        &Remake {
            p: HashMap::from([("not_a_parameter".to_string(), 1.0)]),
            ..Default::default()
        },
    ) {
        Err(SimulateError::UnsubstitutableBinding { name, class }) => {
            assert_eq!(name, "not_a_parameter");
            assert!(
                class.contains("not a parameter"),
                "unhelpful class: {class}"
            );
        }
        other => panic!("expected a refusal, got {other:?}"),
    }
}

// ===========================================================================
// §2.5.6 — stepping
// ===========================================================================

/// `init` / `step` / `solve_to_completion` — the same lifetime `solve` performs
/// internally, exposed so a caller can interleave its own work.
#[test]
fn the_stepping_lifecycle_reaches_the_same_place_as_solve() {
    let prob = decay_problem((0.0, 2.0));
    let opts = tight(grid(2.0, 8));

    let mut integ = init(&prob, &opts).expect("init");
    let mut interleaved = 0usize;
    while matches!(
        step(&mut integ).expect("step"),
        earthsci_ast::StepStatus::Advanced
    ) {
        interleaved += 1;
        // The whole point: the caller gets control between advances, and can
        // see where the integration has reached.
        assert!(integ.t() > 0.0 && integ.t() <= 2.0);
    }
    assert!(interleaved >= 1, "the integrator never yielded control");
    assert_eq!(integ.retcode(), ReturnCode::Success);

    let stepped = integ.solve_to_completion().expect("finish");
    let want = (-2.0f64).exp();
    let got = stepped.final_value("M.y").expect("y");
    assert!(
        (got - want).abs() < 1e-5,
        "stepped y(2) = {got}, want {want}"
    );
}

#[test]
fn solve_to_completion_runs_the_whole_interval_in_one_call() {
    let prob = decay_problem((0.0, 2.0));
    let mut integ = init(&prob, &tight(grid(2.0, 4))).expect("init");
    let sol = earthsci_ast::solve_to_completion(&mut integ).expect("run");
    assert_eq!(sol.retcode, ReturnCode::Success);
    assert!((sol.final_value("M.y").unwrap() - (-2.0f64).exp()).abs() < 1e-5);
}

// ===========================================================================
// §2.5.7 — indexed by variable name
// ===========================================================================

#[test]
fn a_solution_is_indexed_by_variable_name() {
    let sol = solve(&decay_problem((0.0, 1.0)), &tight(grid(1.0, 4))).expect("solve");

    // Exact (flattened, qualified) name.
    let qualified = sol.get("M.y").expect("qualified name");
    // The unique dotted-name tail — a caller may write the local name.
    let bare = sol.get("y").expect("bare name");
    assert_eq!(qualified, bare);
    // Panicking sugar for the case where absence is a bug.
    assert_eq!(&sol["M.y"], qualified);

    assert_eq!(sol.variable_names(), &["M.y".to_string()]);
    assert!(sol.get("nope").is_none());
    assert!(sol.variable("nope").is_err());
    assert_eq!(sol.at("M.y", 0).unwrap(), 1.0);
}

// ===========================================================================
// §2.5.8 — ensembles
// ===========================================================================

/// The canonical form for a parameter sweep: one Problem, one per-trajectory
/// rewrite, and every trajectory sharing the compiled right-hand side.
#[test]
fn an_ensemble_sweeps_a_parameter() {
    let prob = decay_problem((0.0, 1.0));
    let ks = [-0.5f64, -1.0, -2.0];
    let ens = EnsembleProblem::new(&prob, ks.len(), |_, i| {
        Ok(Remake {
            p: HashMap::from([("k".to_string(), ks[i])]),
            ..Default::default()
        })
    });
    assert_eq!(ens.trajectories(), 3);

    let sols = solve_ensemble(&ens, &tight(Some(vec![1.0]))).expect("ensemble");

    assert_eq!(sols.len(), 3);
    for (i, sol) in sols.iter().enumerate() {
        assert_eq!(sol.retcode, ReturnCode::Success);
        let want = ks[i].exp();
        let got = sol.final_value("M.y").unwrap();
        assert!((got - want).abs() < 1e-6, "trajectory {i}: {got} != {want}");
    }
    // The base Problem is untouched by the sweep.
    assert!(prob.p().is_empty());
}

// ===========================================================================
// §5.8 — observed_field(prob, name), one arity
// ===========================================================================

#[test]
fn observed_field_reports_a_name_it_does_not_have() {
    let prob = decay_problem((0.0, 1.0));
    assert!(prob.observed_field_names().is_empty());
    let e = observed_field(&prob, "nothing_like_this").expect_err("must not invent a field");
    assert!(
        e.to_string().contains("nothing_like_this"),
        "the error must name the field: {e}"
    );
}
