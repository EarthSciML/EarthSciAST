//! `observed_trajectory` — reading an observed of a model that INTEGRATES.
//!
//! A `Solution` carries state rows only, in every binding. So before this there
//! was no way to read back an observed of a dynamic model at all:
//! `observed_field` reports what the BUILD materialized, which is a constant,
//! and an observed that depends on the state is not one. A host asserting on
//! such a variable — a model author's own `tests` block naming `NOx` where the
//! states are `NO` and `NO2` — got "variable not found in results" on a model
//! that was perfectly fine.
//!
//! Every value here is checked against an oracle computed from the SOLUTION'S
//! OWN state rows, not against a recorded number: `total_rate = k1*x + k2*y` is
//! a function of two states and two parameters, so a bug in the evaluator, in
//! the parameter binding, or in the output-grid alignment all show up as a
//! mismatch. A golden array would hide all three behind one number.

use std::collections::HashMap;
use std::path::Path;

use earthsci_ast::{
    ProblemInput, ProblemOptions, Remake, SimulateError, SolveOptions, esm_problem,
    observed_trajectories, observed_trajectory, remake, solve,
};

/// A one-component ODE model with `total_rate = k1*x + k2*y` observed.
const DYNAMIC: &str = "../../tests/valid/full_model_specification.esm";
/// A state-free document: nothing to integrate, so no trajectory to report.
const STATIC: &str = "../../tests/valid/nonlinear_mogi_shape.esm";

fn problem(path: &str, p: HashMap<String, f64>) -> earthsci_ast::EsmProblem {
    esm_problem(
        ProblemInput::Path(Path::new(path)),
        (0.0, 10.0),
        ProblemOptions {
            p,
            ..Default::default()
        },
    )
    .unwrap_or_else(|e| panic!("esm_problem({path}): {e}"))
}

fn opts(points: usize) -> SolveOptions {
    let mut o = SolveOptions {
        reltol: 1e-10,
        abstol: 1e-14,
        ..Default::default()
    };
    o.sample_evenly(0.0, 10.0, points);
    o
}

/// `k1 * x + k2 * y` at every output time, from the solution's own state rows.
fn oracle(sol: &earthsci_ast::Solution, k1: f64, k2: f64) -> Vec<f64> {
    let x = sol.get("CompleteModel.x").expect("x is a state");
    let y = sol.get("CompleteModel.y").expect("y is a state");
    x.iter().zip(y).map(|(a, b)| k1 * a + k2 * b).collect()
}

#[test]
fn it_reports_the_observed_at_every_output_time() {
    let prob = problem(DYNAMIC, HashMap::new());
    let sol = solve(&prob, &opts(9)).expect("the model solves");

    let got = observed_trajectory(&prob, &sol, "total_rate").expect("total_rate resolves");

    assert_eq!(
        got.len(),
        sol.time.len(),
        "one value per output time, not per solver step",
    );
    // The document's declared defaults.
    for (k, (g, w)) in got.iter().zip(oracle(&sol, 1e-3, 2e-3)).enumerate() {
        assert!(
            (g - w).abs() <= 1e-15 + 1e-12 * w.abs(),
            "at output index {k}: got {g}, the states say {w}",
        );
    }
}

/// The observed must be evaluated against the state AT EACH TIME, not against
/// the initial condition. A trajectory that is constant when the states decay
/// is the failure this rules out — and it is what a naive implementation that
/// reused the IC vector would produce.
#[test]
fn it_varies_along_the_trajectory() {
    let prob = problem(DYNAMIC, HashMap::new());
    let sol = solve(&prob, &opts(9)).expect("the model solves");
    let got = observed_trajectory(&prob, &sol, "total_rate").expect("total_rate");

    let first = got.first().copied().expect("a first value");
    let last = got.last().copied().expect("a last value");
    assert!(
        (first - last).abs() > 1e-12 * first.abs(),
        "total_rate is identical at t=0 and t=10 ({first} vs {last}); the observed is \
         not being evaluated against the state at each time",
    );
}

/// §5.8's name resolution, on a single-component problem: the qualified
/// spelling always resolves and the bare one does too.
#[test]
fn both_spellings_resolve_on_a_single_component_problem() {
    let prob = problem(DYNAMIC, HashMap::new());
    let sol = solve(&prob, &opts(5)).expect("the model solves");

    let bare = observed_trajectory(&prob, &sol, "total_rate").expect("bare");
    let qualified =
        observed_trajectory(&prob, &sol, "CompleteModel.total_rate").expect("qualified");
    assert_eq!(bare, qualified);
}

/// A caller's `p` binding reaches the evaluation, so the trajectory describes
/// the problem that was solved rather than the document's declared defaults.
#[test]
fn parameter_bindings_reach_the_trajectory() {
    let prob = problem(DYNAMIC, HashMap::from([("CompleteModel.k2".into(), 4e-3)]));
    let sol = solve(&prob, &opts(5)).expect("the model solves");
    let got = observed_trajectory(&prob, &sol, "total_rate").expect("total_rate");

    for (k, (g, w)) in got.iter().zip(oracle(&sol, 1e-3, 4e-3)).enumerate() {
        assert!(
            (g - w).abs() <= 1e-15 + 1e-12 * w.abs(),
            "at output index {k}: got {g}, expected {w} for the OVERRIDDEN k2",
        );
    }
}

/// The same, through `remake`: a re-parameterized problem's solution must be
/// read against the re-parameterized problem. This is the trap the handle API
/// closes by holding the problem inside the solution — pass the wrong one and
/// the numbers are plausible and wrong.
#[test]
fn a_remade_problem_reports_its_own_bindings() {
    let base = problem(DYNAMIC, HashMap::new());
    let bumped = remake(
        &base,
        &Remake {
            p: HashMap::from([("CompleteModel.k2".into(), 4e-3)]),
            ..Default::default()
        },
    )
    .expect("remake");

    let sol = solve(&bumped, &opts(5)).expect("the remade model solves");
    let got = observed_trajectory(&bumped, &sol, "total_rate").expect("total_rate");
    for (g, w) in got.iter().zip(oracle(&sol, 1e-3, 4e-3)) {
        assert!((g - w).abs() <= 1e-15 + 1e-12 * w.abs());
    }

    // And the original problem is untouched — `remake` shares, it does not
    // mutate (§2.5.5).
    let base_sol = solve(&base, &opts(5)).expect("the base model still solves");
    let base_got = observed_trajectory(&base, &base_sol, "total_rate").expect("total_rate");
    for (g, w) in base_got.iter().zip(oracle(&base_sol, 1e-3, 2e-3)) {
        assert!((g - w).abs() <= 1e-15 + 1e-12 * w.abs());
    }
}

/// Several names cost ONE pass over the output grid, and agree value-for-value
/// with asking for them one at a time.
#[test]
fn asking_for_many_agrees_with_asking_one_at_a_time() {
    let prob = problem(DYNAMIC, HashMap::new());
    let sol = solve(&prob, &opts(7)).expect("the model solves");

    let names = vec![
        "total_rate".to_string(),
        "CompleteModel.total_rate".to_string(),
    ];
    let many = observed_trajectories(&prob, &sol, &names).expect("both resolve");
    assert_eq!(many.len(), 2);
    // Keyed by the spelling that was ASKED FOR, so a caller can key its own
    // lookup by the same string it passed in.
    assert_eq!(many[0].0, "total_rate");
    assert_eq!(many[1].0, "CompleteModel.total_rate");
    assert_eq!(many[0].1, many[1].1);
    assert_eq!(
        many[0].1,
        observed_trajectory(&prob, &sol, "total_rate").unwrap()
    );
}

/// The bulk form OMITS a name that is not an observed; the singular form
/// refuses it. The split is what lets a host hand over a list of variable names
/// without first knowing which kind each one is — a test harness reading a
/// model's authored assertions knows the names and not their kinds, and one
/// state in the list must not cost it the other answers.
#[test]
fn the_bulk_form_skips_what_it_cannot_resolve() {
    let prob = problem(DYNAMIC, HashMap::new());
    let sol = solve(&prob, &opts(5)).expect("the model solves");

    let names = vec![
        "x".to_string(),          // a STATE
        "total_rate".to_string(), // an observed
        "nope".to_string(),       // nothing at all
    ];
    let many = observed_trajectories(&prob, &sol, &names).expect("the call succeeds");
    assert_eq!(
        many.iter().map(|(n, _)| n.as_str()).collect::<Vec<_>>(),
        vec!["total_rate"],
        "only the observed comes back, and it is named so the caller can tell",
    );
    for absent in ["x", "nope"] {
        let e = observed_trajectory(&prob, &sol, absent).expect_err("refused");
        assert!(format!("{e}").contains(absent), "{e}");
    }
}

/// A name that is not an observed is an ERROR, not a row of zeros. A silent
/// empty answer is the failure mode a host cannot distinguish from a real one.
#[test]
fn a_name_it_does_not_have_is_refused() {
    let prob = problem(DYNAMIC, HashMap::new());
    let sol = solve(&prob, &opts(3)).expect("the model solves");

    let e = observed_trajectory(&prob, &sol, "nope").expect_err("no such observed");
    assert!(
        format!("{e}").contains("nope"),
        "the message must name the variable: {e}",
    );
    // A STATE is not an observed: it is already in the solution, and answering
    // here would give a host two ways to read one thing.
    assert!(observed_trajectory(&prob, &sol, "x").is_err());
}

/// A static document has no trajectory, and the error says where to go instead.
#[test]
fn a_state_free_document_is_sent_to_observed_field() {
    let prob = esm_problem(
        ProblemInput::Path(Path::new(STATIC)),
        (0.0, 1.0),
        ProblemOptions::default(),
    )
    .expect("esm_problem");
    // There is no solution to read, so fabricate the empty one a host would
    // have if it ignored `solve`'s refusal.
    let sol = earthsci_ast::Solution {
        time: vec![],
        state: vec![],
        state_variable_names: vec![],
        retcode: earthsci_ast::ReturnCode::Failure,
        metadata: Default::default(),
    };
    match observed_trajectory(&prob, &sol, "ur") {
        Err(SimulateError::NotDynamic { details }) => assert!(
            details.contains("observed_field"),
            "the refusal must point at the entry point that DOES answer: {details}",
        ),
        other => panic!("expected NotDynamic, got {other:?}"),
    }
}

/// A pure `reaction_systems` document is DIFFERENTIAL, and `Compile::Auto` has
/// to know it before flattening has lowered anything.
///
/// The regression: `has_differential_equations` read `file.models` alone, and a
/// chemistry document has no models at all until its reactions are lowered. So
/// `Auto` chose the static backend and `solve` refused twenty-five differential
/// equations with "the document declares no differential equations". Every pure
/// chemistry document in the wild is this shape.
#[test]
fn a_reaction_system_is_not_mistaken_for_a_static_document() {
    const POLLU: &str = "../../tests/valid/reaction_system_only.esm";
    if !Path::new(POLLU).exists() {
        eprintln!("· skipping: no {POLLU}");
        return;
    }
    let prob = esm_problem(
        ProblemInput::Path(Path::new(POLLU)),
        (0.0, 1.0),
        ProblemOptions::default(),
    )
    .expect("esm_problem");
    assert!(
        prob.is_dynamic(),
        "a document of 25 reactions was classified static",
    );
    let mut o = SolveOptions::default();
    o.sample_evenly(0.0, 1.0, 3);
    let sol = solve(&prob, &o).expect("a reaction system integrates");
    assert_eq!(sol.time.len(), 3);
    assert!(!sol.state_variable_names.is_empty());
}
