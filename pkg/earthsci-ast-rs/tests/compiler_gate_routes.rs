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
/// instruction and the reference evaluator folds over one whole-array map of
/// its terms.
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
    relational_doc(variables, equations)
}

/// [`relational`] with the running sum `cum[i] = Σ_{j ≤ i} left[j]` beside
/// `left`: a prefix scan, which the reference evaluator sweeps cell by cell.
fn relational_cumulative() -> Value {
    relational_doc(
        json!({
            "left": {"type": "unknown", "units": "1", "shape": ["rows"]},
            "cum": {"type": "unknown", "units": "1", "shape": ["rows"]},
        }),
        vec![
            json!({
                "lhs": "left",
                "rhs": {"op": "faq", "args": [], "output_idx": ["i"],
                        "ranges": {"i": {"from": "rows"}},
                        "expr": {"op": "*", "args": [10, "i"]}}
            }),
            json!({
                "lhs": "cum",
                "rhs": {"op": "faq", "args": [], "output_idx": ["i"],
                        "ranges": {"i": {"from": "rows"}, "j": {"from": "rows"}},
                        "filter": {"op": "<=", "args": ["j", "i"]},
                        "expr": {"op": "index", "args": ["left", "j"]}}
            }),
        ],
    )
}

fn relational_doc(variables: Value, equations: Vec<Value>) -> Value {
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
/// first observed it would have to walk per cell — here the prefix-scan sweep
/// of `cum`.
#[test]
fn the_build_pipeline_refuses_a_per_cell_observed_under_native() {
    let doc = relational_cumulative();
    let err = build_json(&doc, with_pipeline(Compiler::Native)).expect_err("per cell");
    let (compiler, kind, rule, reason) = refusal(err);
    assert_eq!(compiler, "native");
    assert_eq!(kind, "build-time observed");
    assert_eq!(rule, "Rel.cum");
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
    assert_eq!(tier_of("Rel.cum"), "oracle");
    assert_eq!(values(&prob, "Rel.cum"), vec![10.0, 30.0, 60.0]);
}

/// A rank-0 reduction — the shape of every total over ingested rows — is not a
/// per-cell walk: its terms are one whole-array map folded once, so native
/// builds it through the pipeline, reports it vectorized, and agrees bit for
/// bit with the interpreter's pipeline and with the tape.
#[test]
fn a_rank0_reduction_in_the_pipeline_is_vectorized() {
    let doc = relational(true);
    let native = build_json(&doc, with_pipeline(Compiler::Native)).expect("native builds");
    let row = native
        .compiler_report()
        .rules()
        .iter()
        .find(|r| r.rule == "Rel.total")
        .unwrap_or_else(|| panic!("no row: {}", native.compiler_report()))
        .clone();
    assert_eq!(row.kind, "build-time observed");
    assert_eq!(row.tier, "vectorized");
    let interp = build_json(&doc, with_pipeline(Compiler::Interpreter)).expect("interpreter");
    let taped = build_json(&doc, opts(Compiler::Native)).expect("the tape");
    let bits = |p: &EsmProblem| -> Vec<u64> {
        values(p, "Rel.total").iter().map(|x| x.to_bits()).collect()
    };
    assert_eq!(values(&native, "Rel.total"), vec![60.0]);
    assert_eq!(bits(&native), bits(&interp));
    assert_eq!(bits(&native), bits(&taped));
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

// ---------------------------------------------------------------------------
// (d) Value invention
// ---------------------------------------------------------------------------

/// `value_invention_materialize/composite_key_axis.esm` with a one-column key,
/// the form the build pipeline's member ids take: four rows carrying the
/// process ids `[101, 201, 101, 101]`, a `distinct` producer over them, and a
/// count over the derived axis it sizes.
fn one_key_value_invention() -> Value {
    json!({
        "esm": "1.1.0",
        "metadata": {"name": "OneKeyValueInvention"},
        "index_sets": {
            "rows": {"kind": "interval", "size": 4},
            "processes": {"kind": "derived", "from_faq": "process_set"}
        },
        "models": {"Vi": {
            "variables": {
                "polProcessID": {"type": "unknown", "shape": ["rows"]},
                "present": {"type": "unknown", "shape": ["processes"]},
                "nProcesses": {"type": "unknown"}
            },
            "equations": [
                {"lhs": "polProcessID",
                 "rhs": {"op": "const", "args": [], "value": [101, 201, 101, 101]}},
                {"lhs": {"op": "index", "args": ["present", "e"]},
                 "rhs": {"op": "faq", "id": "process_set", "args": [],
                         "semiring": "bool_and_or", "distinct": true,
                         "output_idx": ["e"], "ranges": {"n": {"from": "rows"}},
                         "key": {"op": "skolem", "label": "process",
                                 "args": [{"op": "index", "args": ["polProcessID", "n"]}]},
                         "filter": {"op": "true", "args": []},
                         "expr": {"op": "true", "args": []}}},
                {"lhs": "nProcesses",
                 "rhs": {"op": "faq", "args": [], "output_idx": [],
                         "ranges": {"e": {"from": "processes"}}, "expr": 1.0}}
            ]
        }}
    })
}

/// A value-invention producer's member set is computed once at setup by the
/// relational engine, under every compiler. It is neither the per-cell oracle
/// nor a fallback, so its row is `"relational"`, and a native build of the
/// document has nothing on the oracle.
#[test]
fn value_invention_is_reported_relational_under_every_compiler() {
    let doc = one_key_value_invention();
    let mut members = Vec::new();
    for compiler in [Compiler::Native, Compiler::Interpreter] {
        let prob = build_json(&doc, with_pipeline(compiler))
            .unwrap_or_else(|e| panic!("[{compiler}] {e}"));
        let report = prob.compiler_report();
        let row = report
            .rules()
            .iter()
            .find(|r| r.kind == "value invention")
            .unwrap_or_else(|| panic!("[{compiler}] no value-invention row: {report}"));
        assert_eq!(row.rule, "Vi.process_set", "[{compiler}]");
        assert_eq!(row.tier, "relational", "[{compiler}]");
        assert_eq!(row.cadence, "const", "[{compiler}]");
        assert!(row.reason.is_none(), "[{compiler}]");
        let line = report.to_string();
        assert!(
            line.contains("1 by the relational engine at setup"),
            "[{compiler}] {line}"
        );
        if compiler == Compiler::Native {
            assert_eq!(report.n_oracle(), 0, "{report}");
            assert!(line.contains(" 0 on the per-cell oracle"), "{line}");
        }
        assert_eq!(values(&prob, "Vi.nProcesses"), vec![2.0], "[{compiler}]");
        members.push(prob.members().clone());
    }
    assert_eq!(members[0]["process_set"], vec![101, 201]);
    assert_eq!(members[0], members[1]);
}

/// Every `.esm` under the repository's `tests/` that carries a `distinct`
/// producer, invalid fixtures excepted.
fn distinct_producer_fixtures() -> Vec<PathBuf> {
    fn walk(dir: &Path, out: &mut Vec<PathBuf>) {
        let Ok(entries) = std::fs::read_dir(dir) else {
            return;
        };
        for e in entries.flatten() {
            let p = e.path();
            if p.is_dir() {
                if p.file_name().is_some_and(|n| n == "invalid") {
                    continue;
                }
                walk(&p, out);
            } else if p.extension().is_some_and(|x| x == "esm")
                && std::fs::read_to_string(&p).is_ok_and(|t| t.contains("\"distinct\""))
            {
                out.push(p);
            }
        }
    }
    let mut out = Vec::new();
    walk(&fixture("tests"), &mut out);
    out.sort();
    out
}

/// The invariant over every fixture with a `distinct` producer, with the build
/// pipeline on and off: a native build that succeeds has nothing on the
/// oracle, and value invention is never what a native build refuses.
#[test]
fn a_native_build_of_a_distinct_producer_fixture_has_nothing_on_the_oracle() {
    let fixtures = distinct_producer_fixtures();
    assert!(
        fixtures.iter().any(|p| p
            .ends_with("conformance/value_invention_materialize/fixtures/composite_key_axis.esm")),
        "the value_invention_materialize fixtures must be among {fixtures:?}"
    );
    let mut built = 0;
    for path in &fixtures {
        for pipeline in [true, false] {
            let o = ProblemOptions {
                build_pipeline: pipeline,
                ..opts(Compiler::Native)
            };
            match esm_problem(path.as_path(), (0.0, 1.0), o) {
                Ok(prob) => {
                    let report = prob.compiler_report();
                    assert_eq!(report.n_oracle(), 0, "{}: {report}", path.display());
                    built += 1;
                }
                Err(SimulateError::Compile(CompileError::CompilerRefusedRule {
                    kind,
                    rule,
                    ..
                })) => assert_ne!(
                    kind,
                    "value invention",
                    "{}: {rule} is reported, never refused",
                    path.display()
                ),
                // A document this build cannot take for a reason of its own.
                Err(_) => {}
            }
        }
    }
    assert!(built > 0, "no fixture built, so this proves nothing");
}
