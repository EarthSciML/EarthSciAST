//! `esm test` must EVALUATE a `table_lookup` — esm-spec §9.5.3, issue #188.
//!
//! `esm validate` accepted a document whose observed was defined by a
//! `table_lookup`, and then every inline-test assertion depending on it failed:
//! the §9.5.3 lowering to `fn interp.linear(const data, const axis, x)` lived
//! only in the conformance harness (`function_tables_lowering.rs`), never on
//! the path an evaluation takes, so the op reached the array runtime's
//! evaluable-core gate. Spelling the same lookup by hand passed.
//!
//! These tests drive the SHARED corpus fixtures
//! (`tests/conformance/function_tables/`, esm-spec §9.5.6) rather than
//! Rust-local copies, because the property is cross-binding: all five bindings
//! had the same gap, and the same two files pin all five.
//!
//! * `inline_test/` — the end-to-end case, through `run_inline_tests`. Its three
//!   assertions are the differential: `y` (a `table_lookup`) and `w` (a
//!   `table_lookup` past the last knot, exercising the default clamp) fail
//!   while `z` (the hand-lowered twin) passes, for exactly as long as the
//!   lowering is missing from the evaluation path.
//! * `out_of_bounds_error/` — §9.5.1: this binding implements
//!   `out_of_bounds: "error"`, so an in-range query answers what `clamp`
//!   answers and an out-of-range one raises `table_lookup_out_of_bounds` —
//!   never the clamped value.
//!
//! The last test is the other half of the contract: §9.5.4 makes the authored
//! form first-class, so the lowering must NOT follow the document back out
//! through the serializer.

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::{SolveOptions, load_path};

mod common;

/// Both `table_lookup` assertions pass, and the interpolating one agrees with
/// its hand-lowered twin bit for bit — the §9.5 bit-equivalence promise, which
/// holds because both arms drive the same closed-registry `interp.linear`.
#[test]
fn a_table_lookup_observed_evaluates_like_its_hand_lowered_twin() {
    let path = common::repo_fixture("conformance/function_tables/inline_test/fixture.esm");
    let file = load_path(&path).expect("fixture loads");
    let results = earthsci_ast::run_inline_tests_with_options(
        &file,
        // `table_lookup` lowers to `interp.linear` / `interp.bilinear`, which
        // the tape lowers too (`tape_interp_lowering.rs` pins it bit for bit
        // against the oracle), so `native` tapes this document. What is
        // pinned here is that the two carriers AGREE, which is the reference
        // evaluator's answer to give.
        &earthsci_ast::InlineTestOptions {
            solve: SolveOptions::default(),
            base_dir: path.parent().map(std::path::Path::to_path_buf),
            compiler: Some(earthsci_ast::Compiler::Interpreter),
            ..Default::default()
        },
        None,
    );

    assert_eq!(results.len(), 3, "three inline assertions: {results:?}");
    for r in &results {
        assert!(
            r.passed,
            "{}: actual={:?} expected={} {}",
            r.variable, r.actual, r.expected, r.message
        );
    }
    assert_eq!(results[0].variable, "y", "the `table_lookup` arm is first");
    assert_eq!(results[1].variable, "z", "the hand-lowered arm is second");
    assert_eq!(results[2].variable, "w", "the clamped arm is third");
    assert_eq!(
        results[0].actual,
        Some(25.0),
        "p=2.5 blends the 20.0 and 30.0 knots"
    );
    assert_eq!(
        results[0].actual, results[1].actual,
        "`table_lookup` and the equivalent inline-const lookup must agree bit for bit \
         (esm-spec §9.5.3)"
    );
    assert_eq!(
        results[2].actual,
        Some(40.0),
        "an input past the last knot clamps to the last table value"
    );
}

/// esm-spec §9.5.1 `out_of_bounds: "error"`. This binding implements the mode,
/// so the fixture BUILDS under both compilers, and an in-range query answers
/// exactly what the clamp lowering answers: `p = 2.5` blends the 20.0 and 30.0
/// knots to 25.0, the same bits under `interpreter` and `native`.
#[cfg(feature = "solve")]
#[test]
fn an_error_out_of_bounds_table_answers_an_in_range_query_under_both_compilers() {
    let path = common::repo_fixture("conformance/function_tables/out_of_bounds_error/fixture.esm");
    // The document is schema-valid and §9.5.5 lists no LOAD-time diagnostic
    // for it: the check belongs to the evaluation path, not the loader.
    let file = load_path(&path).expect("fixture loads");
    let mut answers = Vec::new();
    for compiler in [
        earthsci_ast::Compiler::Interpreter,
        earthsci_ast::Compiler::Native,
    ] {
        let prob = earthsci_ast::esm_problem(
            &file,
            (0.0, 1.0),
            earthsci_ast::ProblemOptions {
                compiler: Some(compiler),
                ..Default::default()
            },
        )
        .unwrap_or_else(|e| panic!("[{compiler:?}] esm_problem: {e}"));
        // A state-free document: `y` is a build-time field, not a trajectory.
        let y = observed_scalar(&prob, "M.y")
            .unwrap_or_else(|e| panic!("[{compiler:?}] observed_field: {e}"));
        assert_eq!(
            y, 25.0,
            "[{compiler:?}] p=2.5 blends the 20.0 and 30.0 knots"
        );
        answers.push(y.to_bits());
    }
    assert_eq!(
        answers[0], answers[1],
        "interpreter and native agree bit for bit"
    );
}

/// The fixture with its query moved outside the axis `[1, 4]` — below, and
/// above — raises `table_lookup_out_of_bounds` under both compilers instead
/// of answering the clamped 10.0 / 40.0. An end knot is in range.
#[cfg(feature = "solve")]
#[test]
fn an_out_of_range_query_raises_table_lookup_out_of_bounds_under_both_compilers() {
    let path = common::repo_fixture("conformance/function_tables/out_of_bounds_error/fixture.esm");
    let source = std::fs::read_to_string(&path).expect("fixture reads");
    assert!(
        source.contains("\"default\": 2.5"),
        "the fixture's query default moved"
    );
    for compiler in [
        earthsci_ast::Compiler::Interpreter,
        earthsci_ast::Compiler::Native,
    ] {
        for (p, expected) in [
            ("0.5", None),
            ("4.5", None),
            ("1.0", Some(10.0)),
            ("4.0", Some(40.0)),
        ] {
            let file = earthsci_ast::load_string(
                &source.replace("\"default\": 2.5", &format!("\"default\": {p}")),
            )
            .expect("variant loads");
            let run = earthsci_ast::esm_problem(
                &file,
                (0.0, 1.0),
                earthsci_ast::ProblemOptions {
                    compiler: Some(compiler),
                    ..Default::default()
                },
            )
            .and_then(|prob| observed_scalar(&prob, "M.y"));
            match (expected, run) {
                (Some(want), Ok(y)) => assert_eq!(y, want, "[{compiler:?}] p={p}"),
                (None, Err(e)) => {
                    let text = e.to_string();
                    assert!(
                        text.contains("table_lookup_out_of_bounds") && text.contains("strict_tab"),
                        "[{compiler:?}] p={p}: expected the §9.5.1 error by name, got: {text}"
                    );
                }
                (Some(_), Err(e)) => panic!("[{compiler:?}] p={p} is in range, got: {e}"),
                (None, Ok(y)) => {
                    panic!("[{compiler:?}] p={p} is out of range, but the run answered y={y}")
                }
            }
        }
    }
}

/// The query read at every right-hand-side call: `q` ramps at unit rate from
/// 0 across the axis `[0, 3]` of an `out_of_bounds: "error"` table. Over
/// `(0, 2)` the run answers, and matches the clamp table's run bit for bit
/// under both compilers; over `(0, 5)` `q` leaves the axis at `t = 3` and the
/// solve fails with the table's error rather than integrating the clamp.
#[cfg(feature = "solve")]
#[test]
fn a_state_driven_query_leaving_the_axis_fails_the_solve_by_name() {
    let doc = |mode: &str| {
        format!(
            r#"{{
  "esm": "1.0.0",
  "metadata": {{ "name": "StrictTableRamp", "authors": ["test"] }},
  "function_tables": {{
    "ramp_tab": {{
      "axes": [{{ "name": "q", "values": [0.0, 1.0, 2.0, 3.0] }}],
      "interpolation": "linear",
      "out_of_bounds": "{mode}",
      "data": [1.0, 3.0, 2.0, 5.0]
    }}
  }},
  "models": {{ "M": {{
    "variables": {{
      "q": {{ "type": "unknown", "default": 0.0 }},
      "y": {{ "type": "unknown", "default": 0.0 }}
    }},
    "equations": [
      {{ "lhs": {{ "op": "D", "args": ["q"], "wrt": "t" }}, "rhs": 1.0 }},
      {{ "lhs": {{ "op": "D", "args": ["y"], "wrt": "t" }},
         "rhs": {{ "op": "table_lookup", "table": "ramp_tab", "axes": {{ "q": "q" }}, "args": [] }} }}
    ]
  }} }}
}}"#
        )
    };
    let run = |mode: &str, compiler, tspan| {
        let file = earthsci_ast::load_string(&doc(mode)).expect("loads");
        earthsci_ast::esm_problem(
            &file,
            tspan,
            earthsci_ast::ProblemOptions {
                compiler: Some(compiler),
                ..Default::default()
            },
        )
        .and_then(|prob| earthsci_ast::solve(&prob, &SolveOptions::default()))
    };
    for compiler in [
        earthsci_ast::Compiler::Interpreter,
        earthsci_ast::Compiler::Native,
    ] {
        let strict = run("error", compiler, (0.0, 2.0))
            .unwrap_or_else(|e| panic!("[{compiler:?}] in range: {e}"));
        let clamp = run("clamp", compiler, (0.0, 2.0)).expect("clamp run");
        let (a, b) = (strict.get("M.y").unwrap(), clamp.get("M.y").unwrap());
        assert_eq!(a.len(), b.len());
        for (x, y) in a.iter().zip(b) {
            assert_eq!(
                x.to_bits(),
                y.to_bits(),
                "[{compiler:?}] strict vs clamp in range"
            );
        }

        let err =
            run("error", compiler, (0.0, 5.0)).expect_err("the query leaves the axis at t = 3");
        let text = err.to_string();
        assert!(
            text.contains("table_lookup_out_of_bounds") && text.contains("ramp_tab"),
            "[{compiler:?}] expected the §9.5.1 error by name, got: {text}"
        );
    }
}

/// `esm_problem` takes a caller-flattened system as well as a document, and
/// `flatten` carries `function_tables` precisely so that carrier stays
/// runnable. Both carriers must lower, and agree: `linear/` integrates the
/// constant tendency `table_lookup(sigma_O3_298, lambda_idx = 4.5)`, the
/// midpoint of the 8.70e-18 and 7.90e-18 knots, so `k_O3(1)` is that value.
#[cfg(feature = "solve")]
#[test]
fn both_problem_carriers_lower_a_table_lookup() {
    use earthsci_ast::{ProblemInput, esm_problem, flatten, solve};

    let expected = 8.70e-18 + 0.5 * (7.90e-18 - 8.70e-18);
    let file = load_path(common::repo_fixture(
        "conformance/function_tables/linear/fixture.esm",
    ))
    .expect("fixture loads");
    let flat = flatten(&file).expect("fixture flattens");

    for (label, input) in [
        ("File", ProblemInput::File(&file)),
        ("Flattened", ProblemInput::Flattened(&flat)),
    ] {
        let prob = esm_problem(
            input,
            (0.0, 1.0),
            earthsci_ast::ProblemOptions {
                // `table_lookup` lowers to `interp.linear`, which the tape
                // lowers too, so `native` tapes both carriers. What is pinned
                // here is that the two carriers AGREE, which is the reference
                // evaluator's answer to give.
                compiler: Some(earthsci_ast::Compiler::Interpreter),
                ..Default::default()
            },
        )
        .unwrap_or_else(|e| panic!("[{label}] esm_problem: {e}"));
        let sol = solve(&prob, &SolveOptions::default())
            .unwrap_or_else(|e| panic!("[{label}] solve: {e}"));
        let got = sol
            .final_value("M.k_O3")
            .unwrap_or_else(|| panic!("[{label}] no M.k_O3 in {:?}", sol.state_variable_names));
        assert!(
            ((got - expected) / expected).abs() < 1e-9,
            "[{label}] k_O3(1) = {got:e}, expected {expected:e}"
        );
    }

    // Lowering the flattened carrier works on a copy: the caller's system
    // still holds the authored node.
    let rhs = serde_json::to_value(&flat.equations[0].rhs).expect("serialize");
    assert_eq!(
        rhs["op"], "table_lookup",
        "caller's system untouched: {rhs}"
    );
}

/// The flattened carrier lowers the strict table too, rather than skipping
/// the pass and building an unevaluable tree.
#[cfg(feature = "solve")]
#[test]
fn an_error_out_of_bounds_table_answers_on_the_flattened_carrier() {
    let path = common::repo_fixture("conformance/function_tables/out_of_bounds_error/fixture.esm");
    let file = load_path(&path).expect("fixture loads");
    let flat = earthsci_ast::flatten(&file).expect("fixture flattens");

    let prob = earthsci_ast::esm_problem(&flat, (0.0, 1.0), Default::default())
        .unwrap_or_else(|e| panic!("esm_problem: {e}"));
    assert_eq!(observed_scalar(&prob, "M.y").expect("observed_field"), 25.0);
}

/// A 0-d build-time field as a number.
fn observed_scalar(
    prob: &earthsci_ast::EsmProblem,
    name: &str,
) -> Result<f64, earthsci_ast::SimulateError> {
    let field = earthsci_ast::observed_field(prob, name)?;
    assert_eq!(field.len(), 1, "{name} is a scalar: {field:?}");
    Ok(*field.iter().next().unwrap())
}

/// Lowering is a transformation on the way into an evaluation: the loaded
/// document — the one `emit` serializes — still carries the authored
/// `table_lookup` node and its `function_tables` block (esm-spec §9.5.4).
#[test]
fn the_loaded_document_still_serializes_the_authored_form() {
    let file = load_path(common::repo_fixture(
        "conformance/function_tables/inline_test/fixture.esm",
    ))
    .expect("fixture loads");
    let out = serde_json::to_value(&file).expect("serialize");
    let rhs = &out["models"]["TableLookupObserved"]["equations"][1]["rhs"];
    assert_eq!(rhs["op"], "table_lookup", "authored form preserved: {rhs}");
    assert_eq!(rhs["table"], "t_prof");
    assert!(
        out["function_tables"]["t_prof"].is_object(),
        "the `function_tables` block survives too"
    );
}
