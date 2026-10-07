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
///
/// The rule is a recurrence whose self-read sits inside an array-valued part
/// of its cell body (a nested `faq`), which the tape's sweep does not lower.
#[test]
fn native_refuses_a_state_free_rule_the_tape_cannot_lower() {
    // `j ↦ s[k-1]·j`: an array-valued value holding the self-read.
    let inner = json!({"op": "faq", "args": [], "output_idx": ["j"],
        "ranges": {"j": [1, 2]},
        "expr": {"op": "*", "args": [
            {"op": "index", "args": ["s", {"op": "-", "args": ["k", 1]}]}, "j"]}});
    let doc = json!({
        "esm": "1.1.0",
        "metadata": {"name": "GateRefused"},
        "index_sets": {"steps": {"kind": "interval", "size": 4}},
        "models": {"R": {
            "variables": {"s": {"type": "unknown", "units": "1", "shape": ["steps"]}},
            "equations": [{"lhs": "s", "rhs": {
                "op": "faq", "args": [], "output_idx": ["k"],
                "ranges": {"k": {"from": "steps"}},
                "expr": {"op": "ifelse", "args": [
                    {"op": "<=", "args": ["k", 1]},
                    1.0,
                    {"op": "index", "args": [inner, 2]}
                ]}}}]
        }}
    });
    let err = build_json(&doc, opts(Compiler::Native)).expect_err("the tape cannot lower it");
    let (compiler, kind, rule, reason) = refusal(err);
    assert_eq!(compiler, "native");
    assert_eq!(kind, "observed");
    assert!(!rule.is_empty());
    assert!(reason.contains("recurrence"), "{reason}");

    let prob = build_json(&doc, opts(Compiler::Interpreter)).expect("the interpreter evaluates it");
    assert_eq!(values(&prob, "R.s"), vec![1.0, 2.0, 4.0, 8.0]);
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

/// The build-time scope an `ic` reads holds only the TRANSITIVELY state-free
/// observeds, each evaluated after the ones it reads. `Acum` is a running sum
/// over `flux`, which reads the state `u`: it is not state-free, so it is no
/// part of the scope (it was, since it names no state itself, and native
/// refused its per-cell prefix scan). `a_dep` reads `zbase`, which sorts
/// after it: evaluated first, `zbase` was absent and the overlay fell to a
/// per-cell walk that native refused.
#[test]
fn native_builds_an_ic_scope_with_state_reading_and_out_of_order_observeds() {
    let mut doc = with_ic(json!("a_dep"));
    let m = &mut doc["models"]["M"];
    for name in ["a_dep", "zbase", "flux", "Acum"] {
        m["variables"][name] = json!({"type": "unknown", "units": "1", "shape": ["x"]});
    }
    let map = |expr: Value| {
        json!({"op": "faq", "args": [], "output_idx": ["i"],
               "ranges": {"i": {"from": "x"}}, "expr": expr})
    };
    let eqs = m["equations"].as_array_mut().expect("equations");
    eqs.push(json!({"lhs": "zbase", "rhs": map(json!("i"))}));
    eqs.push(json!({"lhs": "a_dep",
                    "rhs": map(json!({"op": "*", "args": [2, {"op": "index", "args": ["zbase", "i"]}]}))}));
    eqs.push(json!({"lhs": "flux",
                    "rhs": map(json!({"op": "*", "args": [3, {"op": "index", "args": ["u", "i"]}]}))}));
    eqs.push(json!({"lhs": "Acum",
                    "rhs": {"op": "faq", "args": [], "output_idx": ["i"],
                            "ranges": {"i": {"from": "x"}, "j": {"from": "x"}},
                            "filter": {"op": "<=", "args": ["j", "i"]},
                            "expr": {"op": "index", "args": ["flux", "j"]}}}));
    let file = load_string(&doc.to_string()).expect("loads");
    for compiler in [Compiler::Native, Compiler::Interpreter] {
        let prob = esm_problem(&file, (0.0, 1.0), opts(compiler))
            .unwrap_or_else(|e| panic!("[{compiler}] {e}"));
        let report = prob.compiler_report();
        assert!(
            !report
                .rules()
                .iter()
                .any(|r| r.rule.ends_with("Acum") && r.kind == "initial-condition scope"),
            "[{compiler}] a state-reading observed is in the ic scope: {report}"
        );
        let sol = solve(&prob, &SolveOptions::default()).expect("solves");
        assert_eq!(
            sol.state.iter().map(|r| r[0]).collect::<Vec<_>>(),
            [2.0, 4.0, 6.0],
            "[{compiler}]"
        );
    }
}

/// `with_ic(ic)` plus array observeds over `x`, each `(name, body)`.
fn with_ic_scope(rhs_ic: Value, observeds: &[(&str, Value)]) -> Value {
    let mut doc = with_ic(rhs_ic);
    let m = &mut doc["models"]["M"];
    for (name, body) in observeds {
        let shape = if body.get("op").and_then(Value::as_str) == Some("faq") {
            json!({"type": "unknown", "units": "1", "shape": ["x"]})
        } else {
            json!({"type": "unknown", "units": "1"})
        };
        m["variables"][*name] = shape;
        m["equations"]
            .as_array_mut()
            .expect("equations")
            .push(json!({"lhs": name, "rhs": body}));
    }
    doc
}

fn over_x(idx: &str, expr: Value) -> Value {
    json!({"op": "faq", "args": [], "output_idx": [idx],
           "ranges": {idx: {"from": "x"}}, "expr": expr})
}

fn ic_values(file: &earthsci_ast::EsmFile, compiler: Compiler) -> Vec<f64> {
    let prob = esm_problem(file, (0.0, 1.0), opts(compiler))
        .unwrap_or_else(|e| panic!("[{compiler}] {e}"));
    let sol = solve(&prob, &SolveOptions::default()).expect("solves");
    sol.state.iter().map(|r| r[0]).collect()
}

/// A `faq` index is no read: `zc`'s loop index `k` shares its name with the
/// state-reading observed `k`, and `zc` is still state-free.
#[test]
fn an_ic_scope_loop_index_is_not_a_read_of_the_observed_it_shadows() {
    let doc = with_ic_scope(
        json!("zc"),
        &[
            (
                "k",
                over_x(
                    "i",
                    json!({"op": "*", "args": [2, {"op": "index", "args": ["u", "i"]}]}),
                ),
            ),
            ("zc", over_x("k", json!({"op": "*", "args": [3, "k"]}))),
        ],
    );
    let file = load_string(&doc.to_string()).expect("loads");
    for compiler in [Compiler::Native, Compiler::Interpreter] {
        assert_eq!(ic_values(&file, compiler), [3.0, 6.0, 9.0], "[{compiler}]");
    }
}

/// Only the observeds an `ic` reads are evaluated: `unread` is a running sum
/// the reference evaluator walks per cell, which native would refuse, but no
/// `ic` reads it.
#[test]
fn native_does_not_evaluate_a_state_free_observed_no_ic_reads() {
    let doc = with_ic_scope(
        json!("zbase"),
        &[
            ("zbase", over_x("i", json!("i"))),
            (
                "unread",
                json!({"op": "faq", "args": [], "output_idx": ["i"],
                              "ranges": {"i": {"from": "x"}, "j": {"from": "x"}},
                              "filter": {"op": "<=", "args": ["j", "i"]},
                              "expr": {"op": "index", "args": ["zbase", "j"]}}),
            ),
        ],
    );
    let file = load_string(&doc.to_string()).expect("loads");
    for compiler in [Compiler::Native, Compiler::Interpreter] {
        let prob = esm_problem(&file, (0.0, 1.0), opts(compiler))
            .unwrap_or_else(|e| panic!("[{compiler}] {e}"));
        let report = prob.compiler_report();
        assert!(
            !report
                .rules()
                .iter()
                .any(|r| r.rule.ends_with("unread") && r.kind == "initial-condition scope"),
            "[{compiler}] an observed no ic reads was evaluated: {report}"
        );
        assert_eq!(ic_values(&file, compiler), [1.0, 2.0, 3.0], "[{compiler}]");
    }
}

/// A scalar scope observed binds like a parameter for what reads it.
#[test]
fn an_ic_scope_observed_reads_a_scalar_one() {
    let doc = with_ic_scope(
        json!("zc"),
        &[
            ("dz", json!({"op": "/", "args": [1, 2]})),
            ("zc", over_x("i", json!({"op": "*", "args": ["i", "dz"]}))),
        ],
    );
    let file = load_string(&doc.to_string()).expect("loads");
    for compiler in [Compiler::Native, Compiler::Interpreter] {
        // `u`'s three cells; `dz` follows them in the state vector.
        assert_eq!(
            ic_values(&file, compiler)[..3],
            [0.5, 1.0, 1.5],
            "[{compiler}]"
        );
    }
}

/// An `ic` reading an observed that is not state-free says so, naming the
/// chain to the state.
#[test]
fn an_ic_reading_a_state_dependent_observed_says_why() {
    let doc = with_ic_scope(
        json!("b"),
        &[
            ("a", over_x("i", json!({"op": "index", "args": ["u", "i"]}))),
            (
                "b",
                over_x(
                    "i",
                    json!({"op": "*", "args": [2, {"op": "index", "args": ["a", "i"]}]}),
                ),
            ),
        ],
    );
    let file = load_string(&doc.to_string()).expect("loads");
    let prob = esm_problem(&file, (0.0, 1.0), opts(Compiler::Interpreter)).expect("builds");
    let err = solve(&prob, &SolveOptions::default()).expect_err("ic reads state");
    let msg = err.to_string();
    assert!(
        msg.contains("'b' is not in the build-time scope")
            && msg.contains("reads 'a', which reads 'u'"),
        "{msg}"
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

// ---------------------------------------------------------------------------
// (e) Field names
// ---------------------------------------------------------------------------

/// A variable named like its model is `M.M`, the flattened, component-qualified
/// spelling (API_SPEC §5.8) Julia and Python report, on the build pipeline as
/// on the state-free evaluation — and the bare name still resolves.
#[test]
fn a_variable_named_like_its_model_is_qualified_on_every_route() {
    let doc = json!({
        "esm": "1.1.0",
        "metadata": {"name": "SameName"},
        "models": {"fuel": {
            "variables": {
                "code": {"type": "parameter", "units": "1", "default": 3.0},
                "fuel": {"type": "unknown", "units": "1"}
            },
            "equations": [{"lhs": "fuel", "rhs": {"op": "*", "args": ["code", 2.0]}}]
        }}
    });
    for o in [
        opts(Compiler::Native),
        with_pipeline(Compiler::Native),
        with_pipeline(Compiler::Interpreter),
    ] {
        let pipeline = o.build_pipeline;
        let prob = build_json(&doc, o).unwrap_or_else(|e| panic!("pipeline={pipeline}: {e}"));
        assert_eq!(
            prob.observed_field_names(),
            vec!["fuel.fuel".to_string()],
            "pipeline={pipeline}"
        );
        for name in ["fuel.fuel", "fuel"] {
            assert_eq!(values(&prob, name), vec![6.0], "pipeline={pipeline} {name}");
        }
    }
}
