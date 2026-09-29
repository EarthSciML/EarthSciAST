//! A causal self-reference (esm-spec §4.3.1.1) under `native`, against the
//! interpreter, bit for bit.
//!
//! The tape lowers a recurrence as one `Sweep` whose body is the cell body
//! lowered once and run cell by cell in the normative order: the recurrence
//! axis outermost and ascending, every cell published — rounded to the
//! variable's working precision — before the next one runs (CONFORMANCE_SPEC
//! §5.19). A value is therefore a fully determined function of the document,
//! and native must reproduce the interpreter's to the bit on every document in
//! the corpus that uses the construct, on every route: the build-time
//! materialization of a state-free document (`Rhs::Auto`), and, with a state
//! added so that a right-hand side is built, the right-hand side itself and
//! the observed values reported along a trajectory (§5.19.3b).
//!
//! It must also fail where the interpreter fails, and on the same fault: a
//! self-read of a cell the sweep has not published is
//! `E_TREEWALK_RECUR_UNAVAILABLE`, never a number (§5.19.4).

#![cfg(all(feature = "solve", not(target_arch = "wasm32")))]

use std::path::{Path, PathBuf};

use earthsci_ast::simulate_array::RhsStats;
use earthsci_ast::{
    Alg, Compiler, EsmProblem, InlineTestOptions, ProblemOptions, Rhs, SolveOptions, esm_problem,
    load_path, load_string, run_inline_tests_with_options, solve,
};
use serde_json::{Value, json};

/// Every corpus document that uses the construct: `(path under tests/,
/// model, the variable the recurrence defines, its rank)`.
const DOCS: &[(&str, &str, &str, usize)] = &[
    (
        "fixtures/recurrence/01_recurrence_doubling.esm",
        "RecurrenceDoubling",
        "s",
        1,
    ),
    (
        "fixtures/recurrence/02_recurrence_cancellation_ladder.esm",
        "RecurrenceCancellationLadder",
        "s",
        1,
    ),
    (
        "fixtures/recurrence/03_recurrence_multi_lag.esm",
        "RecurrenceMultiLag",
        "s",
        1,
    ),
    (
        "fixtures/recurrence/04_recurrence_banded_lag_fold.esm",
        "RecurrenceBandedLagFold",
        "r",
        1,
    ),
    (
        "fixtures/recurrence/05_recurrence_two_axes.esm",
        "RecurrenceOnOneOfTwoAxes",
        "m",
        2,
    ),
    (
        "fixtures/recurrence/06_recurrence_float32_state.esm",
        "RecurrenceFloat32State",
        "s",
        1,
    ),
    (
        "fixtures/recurrence/07_recurrence_thirty_eight_lags.esm",
        "RecurrenceThirtyEightLags",
        "r",
        1,
    ),
    (
        "fixtures/recurrence/08_recurrence_parameter_valued_lag.esm",
        "RecurrenceParameterValuedLag",
        "s",
        1,
    ),
    (
        "fixtures/recurrence/09_recurrence_through_expression_template.esm",
        "RecurrenceThroughExpressionTemplate",
        "s",
        1,
    ),
    (
        "valid/recurrence_causal_self_reference.esm",
        "RecurrenceCausalSelfReference",
        "r",
        1,
    ),
];

fn tests_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests")
}

fn read_doc(rel: &str) -> Value {
    let text = std::fs::read_to_string(tests_dir().join(rel)).expect("the document reads");
    serde_json::from_str(&text).expect("the document parses")
}

/// The one model a document defines (its name, for the qualified spelling).
fn model_of(doc: &Value) -> String {
    let models = doc["models"].as_object().expect("the document has models");
    assert_eq!(models.len(), 1, "one model per recurrence fixture");
    models.keys().next().expect("one model").clone()
}

fn opts(compiler: Compiler, rhs: Rhs) -> ProblemOptions {
    ProblemOptions {
        compiler: Some(compiler),
        rhs,
        ..Default::default()
    }
}

fn bits(v: impl IntoIterator<Item = f64>) -> Vec<u64> {
    v.into_iter().map(f64::to_bits).collect()
}

/// Native built every rule of `prob` on the tape.
fn assert_all_taped(label: &str, prob: &EsmProblem) {
    let report = prob.compiler_report();
    assert_eq!(report.n_oracle(), 0, "{label}: {report}");
    assert!(report.n_taped() > 0, "{label}: {report}");
}

/// Under the default `Rhs::Auto` every recurrence document is state-free: the
/// build materializes its observed graph, and under `native` that graph comes
/// off the tape. The field the recurrence defines is the interpreter's, bit
/// for bit, and so is every other build-time field.
#[test]
fn every_recurrence_document_builds_on_the_tape_and_agrees_bit_for_bit() {
    for &(rel, model, var, _) in DOCS {
        let path = tests_dir().join(rel);
        let native = esm_problem(
            path.as_path(),
            (0.0, 1.0),
            opts(Compiler::Native, Rhs::Auto),
        )
        .unwrap_or_else(|e| panic!("{rel}: native must build it: {e}"));
        let interp = esm_problem(
            path.as_path(),
            (0.0, 1.0),
            opts(Compiler::Interpreter, Rhs::Auto),
        )
        .unwrap_or_else(|e| panic!("{rel}: the interpreter must build it: {e}"));
        assert_all_taped(rel, &native);
        let qualified = format!("{model}.{var}");
        let row = native
            .compiler_report()
            .rules()
            .iter()
            .find(|r| r.rule == qualified)
            .unwrap_or_else(|| panic!("{rel}: no row for {qualified}"));
        assert_eq!(row.tier, "taped", "{rel}: {qualified}");

        let mut names: Vec<&String> = interp.observed_fields().keys().collect();
        names.sort();
        let mut native_names: Vec<&String> = native.observed_fields().keys().collect();
        native_names.sort();
        assert_eq!(names, native_names, "{rel}: build-time field names");
        assert!(
            names.iter().any(|n| n.ends_with(var)),
            "{rel}: `{var}` is not among the build-time fields {names:?}"
        );
        for name in names {
            let a = &interp.observed_fields()[name];
            let b = &native.observed_fields()[name];
            assert_eq!(a.shape(), b.shape(), "{rel}: {name} shape");
            assert_eq!(
                bits(a.iter().copied()),
                bits(b.iter().copied()),
                "{rel}: {name}: interpreter {a:?}, native {b:?}"
            );
        }
    }
}

/// The documents' own zero-tolerance assertions pass under `native` too.
#[test]
fn every_recurrence_fixture_passes_its_own_assertions_under_native() {
    for &(rel, _, _, _) in DOCS {
        let file = load_path(tests_dir().join(rel)).expect("the fixture parses");
        let options = InlineTestOptions {
            compiler: Some(Compiler::Native),
            base_dir: Some(tests_dir().join(rel).parent().unwrap().to_path_buf()),
            ..Default::default()
        };
        let results = run_inline_tests_with_options(&file, &options, None);
        assert!(!results.is_empty(), "{rel}: asserts nothing");
        for r in results {
            assert!(
                r.passed,
                "{rel}: {}[{}] on '{}' expected {:?}, got {:?}: {}",
                r.test_id, r.assertion_idx, r.variable, r.expected, r.actual, r.message
            );
        }
    }
}

/// `doc` with a scalar state `u` added, `D(u) = -u/2 + 0·var[1, …]`, so that a
/// right-hand side is built and reads the recurrence — a `NaN` there (an
/// unpublished read laundered into the value) would reach `du` through the
/// `0·` term.
fn with_a_state(doc: &Value, var: &str, rank: usize) -> Value {
    let mut doc = doc.clone();
    let model = model_of(&doc);
    let m = &mut doc["models"][&model];
    m["variables"]["u"] = json!({"type": "unknown", "units": "1", "default": 1.0});
    // One operator may not mix element types (esm-spec §11.3.1): the state
    // carries the recurrence's.
    if let Some(et) = m["variables"][var].get("element_type").cloned() {
        m["variables"]["u"]["element_type"] = et;
    }
    let mut at = vec![json!(var)];
    at.extend(std::iter::repeat_n(json!(1), rank));
    m["equations"]
        .as_array_mut()
        .expect("equations")
        .push(json!({
            "lhs": {"op": "D", "args": ["u"], "wrt": "t"},
            "rhs": {"op": "+", "args": [
                {"op": "*", "args": [-0.5, "u"]},
                {"op": "*", "args": [0.0, {"op": "index", "args": at}]}
            ]}
        }));
    // The fixtures' own assertions are about the state-free document.
    m.as_object_mut().expect("model").remove("tests");
    doc
}

/// The two right-hand sides at one state, bit for bit, with native's on the
/// tape alone.
fn assert_rhs_agrees(label: &str, native: &EsmProblem, interp: &EsmProblem) {
    let nc = native
        .debug_array_compiled()
        .expect("native has a right-hand side");
    let ic = interp
        .debug_array_compiled()
        .expect("the interpreter has a right-hand side");
    let _precision = nc.debug_precision_env().enter();
    let state: Vec<f64> = (0..nc.state_variable_names().len())
        .map(|p| 1.0 + 0.1 * (0.37 * p as f64).sin())
        .collect();
    let params = nc.debug_resolve_params(native.p());
    let mut dy = vec![0.0f64; state.len()];
    let mut scratch = nc.debug_new_scratch_taped();
    let mut stats = RhsStats::default();
    nc.debug_eval_rhs_into(&state, 0.0, &params, &mut dy, &mut scratch, &mut stats);
    assert_eq!(stats.fallback_rules, 0, "{label}: a rule left the tape");
    let (idy, _) = ic.debug_eval_rhs(&state, 0.0, interp.p(), true);
    assert_eq!(
        bits(dy.clone()),
        bits(idy.clone()),
        "{label}: native {dy:?}, interpreter {idy:?}"
    );
    assert!(dy.iter().all(|v| v.is_finite()), "{label}: {dy:?}");
}

/// A short trajectory under each compiler: the states and the recurrence's
/// observed values at every save time, bit for bit.
fn assert_trajectory_agrees(label: &str, native: &EsmProblem, interp: &EsmProblem, var: &str) {
    let o = SolveOptions {
        alg: Alg::Erk,
        reltol: Some(1e-8),
        abstol: Some(1e-10),
        saveat: Some(vec![0.0, 0.25, 0.5]),
        output_observed: vec![var.to_string()],
        ..Default::default()
    };
    let a = solve(native, &o).unwrap_or_else(|e| panic!("{label}: native solve: {e}"));
    let b = solve(interp, &o).unwrap_or_else(|e| panic!("{label}: interpreter solve: {e}"));
    assert_eq!(bits(a.time.clone()), bits(b.time.clone()), "{label}: times");
    assert_eq!(
        a.state_variable_names, b.state_variable_names,
        "{label}: rows"
    );
    // The recurrence's cells are appended as rows of their own.
    let cells = a
        .state_variable_names
        .iter()
        .filter(|n| {
            n.rsplit('.')
                .next()
                .is_some_and(|b| b.starts_with(&format!("{var}[")))
        })
        .count();
    assert!(
        cells > 0,
        "{label}: no rows for `{var}` in {:?}",
        a.state_variable_names
    );
    for (k, (ra, rb)) in a.state.iter().zip(&b.state).enumerate() {
        assert_eq!(
            bits(ra.clone()),
            bits(rb.clone()),
            "{label}: {}: native {ra:?}, interpreter {rb:?}",
            a.state_variable_names[k]
        );
        assert!(
            ra.iter().all(|v| v.is_finite()),
            "{label}: {}",
            a.state_variable_names[k]
        );
    }
}

/// With the right-hand side forced on (a state added), native builds every
/// rule on the tape, and its right-hand side, its trajectory and the
/// recurrence's observed values along it are the interpreter's, bit for bit.
#[test]
fn with_the_right_hand_side_forced_on_native_agrees_bit_for_bit() {
    for &(rel, _, var, rank) in DOCS {
        let doc = with_a_state(&read_doc(rel), var, rank);
        let native = esm_problem(&doc, (0.0, 0.5), opts(Compiler::Native, Rhs::Always))
            .unwrap_or_else(|e| panic!("{rel}: native must build it: {e}"));
        let interp = esm_problem(&doc, (0.0, 0.5), opts(Compiler::Interpreter, Rhs::Always))
            .unwrap_or_else(|e| panic!("{rel}: the interpreter must build it: {e}"));
        assert_all_taped(rel, &native);
        assert_rhs_agrees(rel, &native, &interp);
        assert_trajectory_agrees(rel, &native, &interp, var);
    }
}

/// A recurrence that reads the STATE runs on every right-hand-side call (the
/// continuous section), and a derivative that reads it back couples the two:
/// `s[1] = u`, `s[k] = s[k-1]/2 + u·k`, `D(u) = -s[N]/100`.
fn state_driven(n: usize) -> Value {
    json!({
        "esm": "1.1.0",
        "metadata": {"name": "StateDriven"},
        "index_sets": {"steps": {"kind": "interval", "size": n}},
        "models": {"M": {
            "variables": {
                "u": {"type": "unknown", "units": "1", "default": 1.0},
                "s": {"type": "unknown", "units": "1", "shape": ["steps"]}
            },
            "equations": [
                {"lhs": "s", "rhs": {"op": "faq", "args": [], "output_idx": ["k"],
                    "ranges": {"k": {"from": "steps"}},
                    "expr": {"op": "ifelse", "args": [
                        {"op": "<=", "args": ["k", 1]},
                        "u",
                        {"op": "+", "args": [
                            {"op": "/", "args": [
                                {"op": "index", "args": ["s", {"op": "-", "args": ["k", 1]}]},
                                2.0]},
                            {"op": "*", "args": ["u", "k"]}
                        ]}
                    ]}}},
                {"lhs": {"op": "D", "args": ["u"], "wrt": "t"},
                 "rhs": {"op": "/", "args": [
                     {"op": "-", "args": [{"op": "index", "args": ["s", n]}]}, 100.0]}}
            ]
        }}
    })
}

#[test]
fn a_state_driven_recurrence_agrees_on_every_call() {
    let doc = state_driven(7);
    let native = esm_problem(&doc, (0.0, 0.5), opts(Compiler::Native, Rhs::Always))
        .expect("native builds it");
    let interp = esm_problem(&doc, (0.0, 0.5), opts(Compiler::Interpreter, Rhs::Always))
        .expect("the interpreter builds it");
    assert_all_taped("state_driven", &native);
    let row = native
        .compiler_report()
        .rules()
        .iter()
        .find(|r| r.rule.rsplit('.').next() == Some("s"))
        .expect("a row for M.s");
    assert_eq!(row.cadence, "continuous");
    assert_rhs_agrees("state_driven", &native, &interp);
    assert_trajectory_agrees("state_driven", &native, &interp, "s");
}

/// The program does not grow with the frame: the sweep's body is lowered once.
#[test]
fn the_program_is_the_same_length_at_every_frame_size() {
    let lens: Vec<(usize, usize)> = [10usize, 1_000, 100_000]
        .iter()
        .map(|&n| {
            let prob = esm_problem(
                &state_driven(n),
                (0.0, 0.5),
                opts(Compiler::Native, Rhs::Always),
            )
            .expect("native builds it");
            let r = prob
                .debug_array_compiled()
                .expect("a right-hand side")
                .debug_build_tape_report();
            let instrs = r.n_instr_const + r.n_instr_segment + r.n_instr_continuous;
            (instrs, r.n_slots)
        })
        .collect();
    assert!(lens.windows(2).all(|w| w[0] == w[1]), "{lens:?}");
}

/// The fail-closed fault, under both compilers: with no base-case guard the
/// first cell reads position 0, which is never a value.
#[test]
fn an_unguarded_self_read_faults_under_native_as_under_the_interpreter() {
    let doc = json!({
      "esm": "1.1.0",
      "metadata": { "name": "R", "description": "probe", "authors": ["t"] },
      "index_sets": { "steps": { "kind": "interval", "size": 4 } },
      "models": { "R": {
        "tolerance": { "rel": 0.0, "abs": 0.0 },
        "variables": { "s": { "type": "unknown", "shape": ["steps"], "units": "1" } },
        "equations": [ { "lhs": "s", "rhs": {
          "op": "faq", "args": [], "output_idx": ["k"],
          "ranges": { "k": { "from": "steps" } },
          "expr": {"op": "max", "args": [
            { "op": "index", "args": ["s", { "op": "-", "args": ["k", 1] }] }, 0.0]} } } ],
        "tests": [ { "id": "probe", "description": "probe",
          "time_span": { "start": 0.0, "end": 0.0 },
          "assertions": [ { "variable": "s", "time": 0.0, "expected": 0.0,
                            "coords": { "steps": 2 } } ] } ]
      } }
    })
    .to_string();
    let file = load_string(&doc).expect("probe parses");
    let mut messages = Vec::new();
    for compiler in [Compiler::Interpreter, Compiler::Native] {
        let options = InlineTestOptions {
            compiler: Some(compiler),
            ..Default::default()
        };
        let results = run_inline_tests_with_options(&file, &options, None);
        assert_eq!(results.len(), 1, "{results:?}");
        let r = &results[0];
        assert!(
            r.actual.is_none() && !r.passed,
            "{}: the probe must produce NO value (the `max(x, 0)` would launder a NaN \
             into 0), got {:?}",
            compiler.as_str(),
            r.actual
        );
        assert!(
            r.message.contains("E_TREEWALK_RECUR_UNAVAILABLE"),
            "{}: {}",
            compiler.as_str(),
            r.message
        );
        messages.push(r.message.clone());
    }
    assert!(
        messages[1].contains("at cell [0]"),
        "native names the cell the interpreter names: {messages:?}"
    );
}
