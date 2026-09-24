//! The evaluations construction performs OUTSIDE the compiled model's rule set
//! are under the compiler the caller named (issue #484, esm-libraries-spec
//! §2.5.10): a state-free document's observed graph, the build pipeline, and a
//! field initial condition. Each reports a row in the compiler report, and one
//! a strict compiler could only walk per cell is refused, naming it.

use std::path::{Path, PathBuf};

use earthsci_ast::{
    CompileError, Compiler, EsmProblem, ProblemOptions, SimulateError, SolveOptions, esm_problem,
    load_string, observed_field, solve,
};
use serde_json::{Value, json};

fn fixture(rel: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .join(rel)
}

fn opts(compiler: Compiler) -> ProblemOptions {
    ProblemOptions {
        compiler: Some(compiler),
        ..Default::default()
    }
}

fn with_pipeline(compiler: Compiler) -> ProblemOptions {
    ProblemOptions {
        compiler: Some(compiler),
        build_pipeline: true,
        ..Default::default()
    }
}

/// `left[i] = 10 i` over three rows and, when `with_total`, the rank-0
/// `total = Σ_i left[i]` — which the tape folds with its `Reduce`
/// instruction and the reference evaluator folds term by term.
fn relational(with_total: bool) -> Value {
    let mut variables = json!({
        "left": {"type": "unknown", "units": "1", "shape": ["rows"]},
    });
    let mut equations = vec![json!({
        "lhs": "left",
        "rhs": {"op": "faq", "args": [], "output_idx": ["i"],
                "ranges": {"i": {"from": "rows"}},
                "expr": {"op": "*", "args": [10, "i"]}}
    })];
    if with_total {
        variables["total"] = json!({"type": "unknown", "units": "1"});
        equations.push(json!({
            "lhs": "total",
            "rhs": {"op": "faq", "args": [], "output_idx": [],
                    "ranges": {"i": {"from": "rows"}},
                    "expr": {"op": "index", "args": ["left", "i"]}}
        }));
    }
    json!({
        "esm": "1.1.0",
        "metadata": {"name": "GateRelational"},
        "index_sets": {"rows": {"kind": "interval", "size": 3}},
        "models": {"Rel": {"variables": variables, "equations": equations}},
    })
}

fn build_json(doc: &Value, o: ProblemOptions) -> Result<EsmProblem, SimulateError> {
    esm_problem(doc, (0.0, 1.0), o)
}

fn refusal(err: SimulateError) -> (String, &'static str, String, String) {
    match err {
        SimulateError::Compile(CompileError::CompilerRefusedRule {
            compiler,
            kind,
            rule,
            reason,
            ..
        }) => (compiler.to_string(), kind, rule, reason),
        other => panic!("expected compiler_refused_rule, got {other:?}"),
    }
}

fn values(prob: &EsmProblem, name: &str) -> Vec<f64> {
    observed_field(prob, name)
        .unwrap_or_else(|e| panic!("observed_field({name}): {e}"))
        .iter()
        .copied()
        .collect()
}

// ---------------------------------------------------------------------------
// (a) State-free documents
// ---------------------------------------------------------------------------

/// A SHAPED state-free document is evaluated on the named compiler, not
/// skipped: under `native` every observed comes off the tape, under
/// `interpreter` off the per-cell oracle, and the two agree bit for bit.
#[test]
fn a_shaped_state_free_document_is_evaluated_on_the_named_compiler() {
    let doc = relational(true);
    let native = build_json(&doc, opts(Compiler::Native)).expect("native builds");
    let interp = build_json(&doc, opts(Compiler::Interpreter)).expect("interpreter builds");
    for (prob, tier) in [(&native, "taped"), (&interp, "oracle")] {
        assert_eq!(prob.backend_kind(), "static");
        let rows = prob.compiler_report().rules();
        for name in ["Rel.left", "Rel.total"] {
            let row = rows
                .iter()
                .find(|r| r.rule == name)
                .unwrap_or_else(|| panic!("no row for {name}: {}", prob.compiler_report()));
            assert_eq!(row.kind, "observed");
            assert_eq!(row.tier, tier, "{name}");
        }
    }
    assert_eq!(values(&native, "Rel.left"), vec![10.0, 20.0, 30.0]);
    assert_eq!(observed_field(&native, "Rel.total").unwrap().ndim(), 0);
    for name in ["Rel.left", "Rel.total"] {
        let a: Vec<u64> = values(&native, name).iter().map(|x| x.to_bits()).collect();
        let b: Vec<u64> = values(&interp, name).iter().map(|x| x.to_bits()).collect();
        assert_eq!(
            a, b,
            "{name}: native and the interpreter must agree bit for bit"
        );
    }
    assert_eq!(values(&native, "Rel.total"), vec![60.0]);
    assert!(matches!(
        solve(&native, &SolveOptions::default()),
        Err(SimulateError::NotDynamic { .. })
    ));
}

/// A state-free rule the tape cannot lower is a refusal naming it — it used
/// to be evaluated off the gate — while the interpreter evaluates it.
#[test]
fn native_refuses_a_state_free_rule_the_tape_cannot_lower() {
    let path = fixture("tests/fixtures/recurrence/01_recurrence_doubling.esm");
    let err = esm_problem(path.as_path(), (0.0, 1.0), opts(Compiler::Native))
        .expect_err("a recurrence has no taped form");
    let (compiler, kind, rule, reason) = refusal(err);
    assert_eq!(compiler, "native");
    assert_eq!(kind, "observed");
    assert!(!rule.is_empty());
    assert!(reason.contains("recurrence"), "{reason}");

    let prob = esm_problem(path.as_path(), (0.0, 1.0), opts(Compiler::Interpreter))
        .expect("the interpreter evaluates it");
    assert!(!prob.observed_field_names().is_empty());
}

// ---------------------------------------------------------------------------
// (b) The build pipeline
// ---------------------------------------------------------------------------

/// The pipeline evaluates the observed graph through the reference evaluator
/// whatever the compiler. Its rows say so, and a strict compiler refuses the
/// first observed it would have to walk per cell — here the term-by-term fold
/// of `total`.
#[test]
fn the_build_pipeline_refuses_a_per_cell_observed_under_native() {
    let doc = relational(true);
    let err = build_json(&doc, with_pipeline(Compiler::Native)).expect_err("per cell");
    let (compiler, kind, rule, reason) = refusal(err);
    assert_eq!(compiler, "native");
    assert_eq!(kind, "build-time observed");
    assert_eq!(rule, "Rel.total");
    assert!(reason.contains("per cell"), "{reason}");

    // The interpreter takes it, and its rows say which evaluator served each
    // observed: the pipeline keeps the overlay under every compiler.
    let prob = build_json(&doc, with_pipeline(Compiler::Interpreter)).expect("interpreter");
    let tier_of = |name: &str| {
        let r = prob
            .compiler_report()
            .rules()
            .iter()
            .find(|r| r.rule == name)
            .unwrap_or_else(|| panic!("no row for {name}: {}", prob.compiler_report()))
            .clone();
        assert_eq!(r.kind, "build-time observed", "{name}");
        assert_eq!(r.cadence, "const", "{name}");
        assert!(
            r.reason.is_none(),
            "{name}: the interpreter declines nothing"
        );
        r.tier
    };
    assert_eq!(tier_of("Rel.left"), "vectorized");
    assert_eq!(tier_of("Rel.total"), "oracle");
    assert_eq!(values(&prob, "Rel.total"), vec![60.0]);
}

/// An observed the whole-array overlay serves is not a per-cell walk: it is
/// reported as `"vectorized"`, and native builds.
#[test]
fn a_pipeline_observed_the_overlay_takes_is_reported_vectorized() {
    let doc = relational(false);
    let prob = build_json(&doc, with_pipeline(Compiler::Native)).expect("native builds");
    let report = prob.compiler_report();
    let row = report
        .rules()
        .iter()
        .find(|r| r.rule == "Rel.left")
        .unwrap_or_else(|| panic!("no pipeline row: {report}"));
    assert_eq!(row.kind, "build-time observed");
    assert_eq!(row.tier, "vectorized");
    assert!(row.reason.is_none());
    assert_eq!(report.n_vectorized(), 1);
    assert!(
        report.to_string().contains("whole-array overlay"),
        "{report}"
    );
    assert_eq!(values(&prob, "Rel.left"), vec![10.0, 20.0, 30.0]);
}

// ---------------------------------------------------------------------------
// (c) Field initial conditions
// ---------------------------------------------------------------------------

/// `u` over three cells with `D(u) = -u` and `ic(u) = rhs_ic`.
fn with_ic(rhs_ic: Value) -> Value {
    json!({
        "esm": "1.1.0",
        "metadata": {"name": "GateFieldIc"},
        "index_sets": {"x": {"kind": "interval", "size": 3}},
        "models": {"M": {
            "variables": {"u": {"type": "unknown", "units": "1", "shape": ["x"]}},
            "equations": [
                {"lhs": {"op": "ic", "args": ["u"]}, "rhs": rhs_ic},
                {"lhs": {"op": "faq", "args": [], "output_idx": ["i"], "ranges": {"i": [1, 3]},
                         "expr": {"op": "D", "args": [{"op": "index", "args": ["u", "i"]}],
                                  "wrt": "t"}},
                 "rhs": {"op": "faq", "args": [], "output_idx": ["i"], "ranges": {"i": [1, 3]},
                         "expr": {"op": "-", "args": [{"op": "index", "args": ["u", "i"]}]}}},
            ],
        }},
    })
}

/// A coordinate-expression `ic` is exercised at construction and reported.
#[test]
fn a_field_initial_condition_is_reported() {
    let doc = with_ic(json!({"op": "faq", "args": [], "output_idx": ["i"],
                             "ranges": {"i": {"from": "x"}},
                             "expr": {"op": "*", "args": [0.5, "i"]}}));
    let file = load_string(&doc.to_string()).expect("loads");
    for (compiler, tier) in [
        (Compiler::Native, "vectorized"),
        (Compiler::Interpreter, "oracle"),
    ] {
        let prob = esm_problem(&file, (0.0, 1.0), opts(compiler))
            .unwrap_or_else(|e| panic!("[{compiler}] {e}"));
        let row = prob
            .compiler_report()
            .rules()
            .iter()
            .find(|r| r.kind == "initial condition")
            .unwrap_or_else(|| panic!("[{compiler}] no ic row: {}", prob.compiler_report()));
        // Named as the model's own rules are on this route.
        assert_eq!(row.rule.rsplit('.').next(), Some("u"), "[{compiler}]");
        assert_eq!(row.tier, tier, "[{compiler}]");
        let sol = solve(&prob, &SolveOptions::default()).expect("solves");
        assert_eq!(
            sol.state.iter().map(|r| r[0]).collect::<Vec<_>>(),
            [0.5, 1.0, 1.5]
        );
    }
}

/// An `ic` the reference evaluator can only walk per cell — a cumulative sum,
/// which it sweeps as a prefix scan — is refused by native at CONSTRUCTION,
/// naming the target, and built by the interpreter.
#[test]
fn native_refuses_a_per_cell_initial_condition() {
    let doc = with_ic(json!({"op": "faq", "args": [], "output_idx": ["i"],
                             "ranges": {"i": {"from": "x"}, "j": [1, 3]},
                             "filter": {"op": "<=", "args": ["j", "i"]},
                             "expr": 1.0}));
    let file = load_string(&doc.to_string()).expect("loads");
    let err = esm_problem(&file, (0.0, 1.0), opts(Compiler::Native)).expect_err("per cell");
    let (_, kind, rule, _) = refusal(err);
    assert_eq!(kind, "initial condition");
    assert_eq!(rule.rsplit('.').next(), Some("u"));

    let prob = esm_problem(&file, (0.0, 1.0), opts(Compiler::Interpreter)).expect("builds");
    let sol = solve(&prob, &SolveOptions::default()).expect("solves");
    assert_eq!(
        sol.state.iter().map(|r| r[0]).collect::<Vec<_>>(),
        [1.0, 2.0, 3.0]
    );
}
