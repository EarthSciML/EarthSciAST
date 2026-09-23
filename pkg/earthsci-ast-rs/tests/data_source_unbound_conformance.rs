//! Cross-language conformance for a data-fed parameter nothing bound
//! (esm-spec §9.6.6 `data_source_unbound`, CONFORMANCE_SPEC §5.46).
//!
//! Drives the shared manifest at `tests/conformance/data_source_unbound/`.
//!
//! Before the ruling this binding gave two different wrong answers for one
//! question. Under `native` the tape refused — but as `compiler_refused_rule`
//! ("wholesale: unresolved symbol (forcing/NaN sentinel?)"), which reports the
//! tape's limits in place of the document's defect and which no `providers`
//! argument would have cleared. Under `interpreter` the build SUCCEEDED and the
//! run failed with an uncoded `E_TREEWALK_UNBOUND_NAME`. A caller who pinned
//! the parameter with `p` got neither the build nor the pin: the parameter was
//! routed to the external forcing channel, where a `p` binding never lands.
//!
//! What is asserted here is that both compilers now answer with the SAME
//! registered code at construction, that the message names the parameter, and
//! that the two controls run.

use earthsci_ast::{
    Compiler, ProblemInput, ProblemOptions, SolveOptions, esm_problem, load_path,
    run_inline_tests_with_base_dir,
};
use serde_json::Value;
use std::path::{Path, PathBuf};

fn category_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/conformance/data_source_unbound")
}

/// A missing manifest is a hard failure, not a skip.
fn manifest() -> Value {
    let raw = std::fs::read_to_string(category_dir().join("manifest.json"))
        .expect("the data_source_unbound manifest is readable");
    serde_json::from_str(&raw).expect("the data_source_unbound manifest parses")
}

/// The codes a case may be refused with. Every case names `data_source_unbound`;
/// `unresolvable_source` additionally admits `data_source_undefined`, because a
/// front door that validates structurally reports that one and never reaches
/// the build (README, "`unresolvable_source` accepts two codes").
fn accepted(case: &Value) -> Vec<String> {
    case["accepts"]
        .as_array()
        .expect("a refusal case lists `accepts`")
        .iter()
        .map(|c| {
            c.as_str()
                .expect("`accepts` entries are strings")
                .to_string()
        })
        .collect()
}

#[test]
fn the_manifest_names_the_registered_code() {
    let m = manifest();
    let code = m["code"].as_str().expect("`code` is a string");
    assert_eq!(code, "data_source_unbound");
    assert!(
        earthsci_ast::error_code_names().contains(&code),
        "`{code}` is not in the crate's diagnostic-code registry"
    );
    let cases = m["cases"].as_array().expect("`cases` is an array");
    assert!(
        cases.iter().any(|c| c["expect"] == "run"),
        "no control case"
    );
    assert!(
        cases.iter().any(|c| c["expect"] == "refuse"),
        "no refusal case"
    );
}

/// The heart of the category: the SAME refusal under both compilers.
///
/// A binding whose two compilers disagree here is reporting a compiler property
/// where the question is about the document, which is exactly the state this
/// tier was written to end.
#[test]
fn both_compilers_refuse_an_unbound_data_feed_with_the_same_code() {
    let m = manifest();
    for case in m["cases"].as_array().unwrap() {
        if case["expect"] != "refuse" {
            continue;
        }
        let id = case["id"].as_str().unwrap();
        let path = category_dir().join(case["path"].as_str().unwrap());
        let parameter = case["parameter"].as_str().unwrap();
        let source = case["source"].as_str().unwrap();
        let codes = accepted(case);
        for compiler in [Compiler::Native, Compiler::Interpreter] {
            let err = esm_problem(
                ProblemInput::Path(&path),
                (0.0, 1.0),
                ProblemOptions {
                    compiler: Some(compiler),
                    ..Default::default()
                },
            )
            .err()
            .unwrap_or_else(|| {
                panic!("{id} under {compiler:?}: built, with nothing bound to {parameter}")
            });
            let text = err.to_string();
            assert!(
                codes.iter().any(|c| text.contains(c.as_str())),
                "{id} under {compiler:?}: refused with none of {codes:?}: {text}"
            );
            assert!(
                text.contains(parameter),
                "{id} under {compiler:?}: the refusal must name the parameter {parameter}: {text}"
            );
            assert!(
                text.contains(source),
                "{id} under {compiler:?}: the refusal must name the source {source}: {text}"
            );
        }
    }
}

/// A `p` value for the parameter BINDS it, under both compilers, and the pinned
/// value reaches the right-hand side.
///
/// The second assertion is the one that matters: a build that merely stopped
/// refusing and then integrated the `default` would satisfy the first and
/// defeat the purpose. 0.5 is the pin and 0.1 is the document's `default`, so
/// `exp(-0.5)` and `exp(-0.1)` tell them apart at the third digit.
#[test]
fn a_pinned_parameter_builds_and_its_value_is_the_one_that_runs() {
    let path = category_dir().join("fixtures/unbound_scalar_forcing.esm");
    for compiler in [Compiler::Native, Compiler::Interpreter] {
        let mut opts = ProblemOptions {
            compiler: Some(compiler),
            ..Default::default()
        };
        opts.p.insert("Forcing.k".to_string(), 0.5);
        let prob = esm_problem(ProblemInput::Path(&path), (0.0, 1.0), opts)
            .unwrap_or_else(|e| panic!("a pinned forcing must build under {compiler:?}: {e}"));
        let mut solve_opts = SolveOptions::default();
        solve_opts.sample_evenly(0.0, 1.0, 2);
        let sol = earthsci_ast::solve(&prob, &solve_opts)
            .unwrap_or_else(|e| panic!("a pinned forcing must run under {compiler:?}: {e}"));
        // `state` is one row per state variable, each row over the save
        // times, so the value at the end of the span is the last column of the
        // one row this document has.
        let row = sol.state.last().expect("one state variable");
        let last = *row.last().expect("two save points");
        assert!(
            (last - 0.6065306597126334_f64).abs() < 1e-6,
            "{compiler:?}: the pinned rate 0.5 must be the one integrated (exp(-0.5)), not the \
             document's default 0.1 (exp(-0.1) = 0.9048…): got {last}"
        );
    }
}

/// Both controls, through the inline-test runner — which is where the pin
/// control's `parameter_overrides` lives, and which is the surface a document
/// author actually uses.
#[test]
fn the_controls_still_run() {
    let m = manifest();
    for case in m["cases"].as_array().unwrap() {
        if case["expect"] != "run" {
            continue;
        }
        let id = case["id"].as_str().unwrap();
        let path = category_dir().join(case["path"].as_str().unwrap());
        let file = load_path(&path).unwrap_or_else(|e| panic!("{id}: does not load: {e}"));
        let results = run_inline_tests_with_base_dir(
            &file,
            None,
            &SolveOptions::default(),
            Some(category_dir().as_path()),
        );
        assert!(!results.is_empty(), "{id}: ran no assertions");
        for r in &results {
            assert!(r.passed, "{id}: {}", r.message);
        }
    }
}

/// The refusal reaches the inline-test runner too, as a refusal and not as a
/// number: `run_inline_tests` is the surface that used to report the
/// default-valued trajectory as a passing assertion.
#[test]
fn the_inline_test_runner_reports_the_refusal_rather_than_a_number() {
    let m = manifest();
    for case in m["cases"].as_array().unwrap() {
        if case["expect"] != "refuse" {
            continue;
        }
        let id = case["id"].as_str().unwrap();
        let path = category_dir().join(case["path"].as_str().unwrap());
        let codes = accepted(case);
        let Ok(file) = load_path(&path) else {
            // A binding whose LOAD runs structural validation refuses there —
            // `unresolvable_source` is that case for the bindings that do.
            // Rust's load does not, so reaching here would be the surprise.
            continue;
        };
        let results = run_inline_tests_with_base_dir(
            &file,
            None,
            &SolveOptions::default(),
            Some(category_dir().as_path()),
        );
        assert!(!results.is_empty(), "{id}: ran no assertions");
        for r in &results {
            assert!(!r.passed, "{id}: an assertion passed: {}", r.message);
            assert!(
                r.actual.is_none(),
                "{id}: produced a number ({:?}) instead of refusing: {}",
                r.actual,
                r.message
            );
            assert!(
                codes.iter().any(|c| r.message.contains(c.as_str())),
                "{id}: the message carries none of {codes:?}: {}",
                r.message
            );
        }
    }
}
