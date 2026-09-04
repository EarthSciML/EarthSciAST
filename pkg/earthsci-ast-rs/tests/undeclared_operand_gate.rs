//! An operand bound by NOTHING is an error on EVERY route — CONFORMANCE_SPEC §5.23.
//!
//! A name declared nowhere in the document is a structural error. `esm validate`
//! says so, and so does the compile path, by name. The BUILD PIPELINE did not.
//! It evaluates a document's whole observed graph wholesale through the shared
//! expression evaluator, upstream of the compile-path gate and on expressions
//! the compile path never sees again (each observed leaves the pipeline as a
//! materialized field). An undeclared operand therefore fell through
//! `simulate_array::eval::lookup_variable` to an unbound-name `NaN`, and
//! `max(known, undeclaredFloor)` evaluated as `max(known)` — IEEE-754 `max`
//! returns the non-NaN operand, so the operand simply DISAPPEARED and the answer
//! came back finite, plausible, and short one floor the author wrote.
//!
//! That route is not an edge case: it is taken by ANY document that ingests so
//! much as one column the equation never reads, and by EVERY document under
//! `esm simulate`, whose static branch rebuilds with `build_pipeline = true` in
//! order to materialize an array observed at all.
//!
//! Downstream this looked like 120 of 120 assertions passing — twelve end-to-end
//! emission rows agreeing with a reference snapshot to 4e-06 — on bytes that
//! `esm validate` rejected. The lost operand was a population floor that could
//! not bind on that data. It would have changed the answer on other data.
//!
//! These tests hold BOTH routes to the same verdict on the same fixture, which
//! is the check that was missing when the same sentence was true of a causal
//! self-read (finding F24, §5.19.3b) and then again of an undeclared name.

use earthsci_ast::simulate_array::{Value as EvalValue, eval_expression};
use earthsci_ast::{SolveOptions, load_path, run_pde_tests};
use serde_json::json;

fn fixture() -> std::path::PathBuf {
    std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures/undeclared_operand/undeclared_operand_in_max.esm")
}

/// The one sentence both routes must produce. Pinned as a substring rather than
/// a whole message so the two are held to naming the SAME variable in the SAME
/// words — an error that says only "build failed" would let the routes drift
/// apart again while both looked red.
const NAMED: &str = "Unknown variable 'undeclaredFloor' referenced in expression";

/// The number the defect produced: `max(known)` with `known = 2.0`. Asserted
/// against explicitly, because "the run failed" is a weaker claim than "the run
/// did not quietly answer 2.0", and 2.0 is what a reader would have believed.
const LAUNDERED: f64 = 2.0;

// ---------------------------------------------------------------------------
// Route 1 — the per-step observed materialization (`esm test`)
// ---------------------------------------------------------------------------

/// The route that was already right, pinned so it stays right and so the
/// cross-route comparison below has a fixed side to compare against.
#[test]
fn per_step_route_refuses_and_names_the_operand() {
    let file = load_path(fixture()).expect("fixture parses");
    let results = run_pde_tests(&file, None, &SolveOptions::default());
    assert_eq!(results.len(), 1, "the fixture asserts exactly once");
    let r = &results[0];
    assert!(
        !r.passed,
        "an undeclared operand must not produce a passing assertion"
    );
    assert!(
        r.actual.is_none_or(|a| a != LAUNDERED),
        "the per-step route answered the laundered {LAUNDERED} — the operand was dropped"
    );
    assert!(
        r.message.contains(NAMED),
        "the failure must NAME the undeclared operand; got: {}",
        r.message
    );
}

// ---------------------------------------------------------------------------
// Route 2 — the build pipeline (any ingesting document; every `esm simulate`
// of a document with nothing to integrate)
// ---------------------------------------------------------------------------

/// THE REGRESSION. Before the fix this returned `Ok`, materialized `clamped`,
/// and reported `2.0`.
///
/// `build_pipeline: true` is set directly rather than through a `data_sources`
/// ingest so the test needs no data reader linked and runs in any environment;
/// ingestion reaches the identical `prepare::eval_observed`, which is what
/// `esm simulate`'s static rebuild and every provider-fed build both go through.
#[test]
fn build_pipeline_route_refuses_and_names_the_operand() {
    let file = load_path(fixture()).expect("fixture parses");
    let opts = earthsci_ast::ProblemOptions {
        build_pipeline: true,
        compile: earthsci_ast::Compile::Auto,
        ..Default::default()
    };
    match earthsci_ast::esm_problem(&file, (0.0, 0.0), opts) {
        Ok(prob) => {
            let fields = prob.observed_fields().clone();
            panic!(
                "the build pipeline BUILT a document whose operand is declared nowhere. \
                 It materialized {:?} — this is the defect: `max(known, undeclaredFloor)` \
                 evaluated as `max(known)` and the missing operand left no trace.",
                fields
                    .iter()
                    .map(|(k, v)| (k.clone(), v.iter().copied().collect::<Vec<f64>>()))
                    .collect::<Vec<_>>()
            );
        }
        Err(e) => {
            let msg = e.to_string();
            assert!(
                msg.contains(NAMED),
                "the build pipeline must fail NAMING the operand, the same way the \
                 per-step route does; got: {msg}"
            );
        }
    }
}

/// Cross-route agreement is the assertion, not "each route did something".
/// §5.19.3b learned this from the recurrence: two routes each producing a
/// plausible outcome is exactly the state that persisted for as long as the
/// defect existed.
#[test]
fn both_routes_give_the_same_verdict_in_the_same_words() {
    let file = load_path(fixture()).expect("fixture parses");

    let per_step = run_pde_tests(&file, None, &SolveOptions::default())
        .into_iter()
        .next()
        .expect("one assertion")
        .message;

    let pipeline = earthsci_ast::esm_problem(
        &file,
        (0.0, 0.0),
        earthsci_ast::ProblemOptions {
            build_pipeline: true,
            compile: earthsci_ast::Compile::Auto,
            ..Default::default()
        },
    )
    .err()
    .map(|e| e.to_string())
    .expect("the build pipeline must refuse it");

    assert!(
        per_step.contains(NAMED) && pipeline.contains(NAMED),
        "the two routes disagree about an undeclared operand.\n  per-step: {per_step}\n  pipeline: {pipeline}"
    );
}

// ---------------------------------------------------------------------------
// The backstop — any route that MISSES the gate must still fail loudly
// ---------------------------------------------------------------------------

/// The gate above is a build-time check over the model. This is the runtime
/// half: the evaluator itself, reached with a name nothing binds, must raise
/// rather than hand back the `NaN` sentinel.
///
/// It matters independently of the gate. The gate is deliberately conservative —
/// it credits dotted names and `index` heads as possibly-runtime-bound rather
/// than risk rejecting a valid model — so a name can legitimately pass it and
/// still bind to nothing at evaluation. Before this change that combination was
/// silent, which is how a future route could reacquire the same defect without
/// anyone touching `prepare` or `compile`.
#[test]
fn the_evaluator_itself_refuses_an_unbound_name() {
    let expr: earthsci_ast::Expr =
        serde_json::from_value(json!({"op": "max", "args": ["known", "nothingBindsThis"]}))
            .expect("expression parses");
    let err = eval_expression(&expr, &Default::default(), &[2.0], &["known".into()], 0.0)
        .expect_err(
            "an expression naming an unbound operand must not evaluate. Returning the \
             non-NaN operand is exactly the laundering this fails closed to prevent.",
        );
    let msg = err.to_string();
    assert!(
        msg.contains("E_TREEWALK_UNBOUND_NAME") && msg.contains("nothingBindsThis"),
        "the fault must carry its code and name the unbound operand; got: {msg}"
    );
}

/// Non-vacuity for the test above: the SAME call with the operand bound
/// evaluates, and to the floor rather than to `known`. Without this, a fault
/// raised for an unrelated reason would look like a pass.
#[test]
fn the_same_expression_evaluates_once_the_operand_is_bound() {
    let expr: earthsci_ast::Expr =
        serde_json::from_value(json!({"op": "max", "args": ["known", "nothingBindsThis"]}))
            .expect("expression parses");
    let v = eval_expression(
        &expr,
        &Default::default(),
        &[2.0, 10.0],
        &["known".into(), "nothingBindsThis".into()],
        0.0,
    )
    .expect("with both operands bound the expression evaluates");
    assert!(
        matches!(v, EvalValue::Scalar(x) if x == 10.0),
        "max(2, 10) must be 10, not {v:?} — otherwise the fault above proves nothing"
    );
}

// ---------------------------------------------------------------------------
// The CLI, which is where a person meets this
// ---------------------------------------------------------------------------

/// `esm simulate` on the fixture must EXIT NON-ZERO and name the operand.
///
/// This is the route a person actually takes, and it is the one that was
/// silent: `simulate`'s static branch rebuilds with the pipeline on in order to
/// materialize an array observed at all, so a document with nothing to
/// integrate — every MOVES-shaped calculator — reached the defect without
/// anyone opting into anything. It wrote `clamped = 2` and exited 0.
///
/// Asserted at the process boundary rather than through the library because
/// that is where "the run succeeded" is decided: a previous verification here
/// reported an exit code that belonged to `tail`, not to the command.
#[test]
fn esm_simulate_exits_non_zero_and_names_the_operand() {
    let out = std::process::Command::new(env!("CARGO_BIN_EXE_esm"))
        .current_dir(env!("CARGO_MANIFEST_DIR"))
        .args([
            "simulate",
            "../../tests/fixtures/undeclared_operand/undeclared_operand_in_max.esm",
            "--time",
            "0",
        ])
        .output()
        .unwrap_or_else(|e| panic!("could not run the esm binary: {e}"));
    let mut text = String::from_utf8_lossy(&out.stdout).into_owned();
    text.push_str(&String::from_utf8_lossy(&out.stderr));
    assert!(
        !out.status.success(),
        "`esm simulate` SUCCEEDED on a document whose operand is declared nowhere. \
         Output was:\n{text}"
    );
    assert!(
        text.contains(NAMED),
        "`esm simulate` must name the undeclared operand; got:\n{text}"
    );
    assert!(
        !text.contains("clamped[1] = 2"),
        "`esm simulate` reported the laundered value; got:\n{text}"
    );
}
