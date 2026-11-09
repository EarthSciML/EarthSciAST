//! `ProblemOptions::observed_cone` — and `esm simulate --observed`, which sets
//! it — evaluates only the dependency cone of the requested observeds on a
//! document with nothing to integrate.
//!
//! Before it, a run that asked for one column of a large relational document
//! paid for every observed in it: `--observed` chose which columns were
//! WRITTEN, after the whole graph had been evaluated. The pins:
//!
//!   * an observed outside the cone is never evaluated — not reported to the
//!     progress observer, and one that would FAIL does not fail the run;
//!   * every field inside the cone is bit-identical to the unpruned build's,
//!     on the build pipeline and on the state-free evaluation, under the
//!     native compiler and the interpreter;
//!   * a name the document does not declare is refused by `esm simulate`
//!     before anything is evaluated.

#![cfg(not(target_arch = "wasm32"))]

use std::sync::{Arc, Mutex};

use earthsci_ast::{
    Compiler, EsmProblem, Flow, PreparePhase, PrepareProgress, ProblemOptions, esm_problem,
    observed_field,
};
use serde_json::{Value, json};

fn faq_over(set: &str, idx: &[&str], output: &[&str], args: Value, expr: Value) -> Value {
    let ranges: serde_json::Map<String, Value> = idx
        .iter()
        .map(|i| (i.to_string(), json!({"from": set})))
        .collect();
    json!({"op": "faq", "args": args, "output_idx": output, "ranges": ranges, "expr": expr})
}

/// `left[i] = 10 i` over three rows, `dep = Σ left = 60`, `good = 3 dep =
/// 180`; `expensive` is a million-cell product nothing requested reads, and
/// `bad` a `table_lookup` past an `out_of_bounds: "error"` axis, which fails
/// any evaluation of it.
fn cone_document(with_bad: bool) -> Value {
    let mut variables = json!({
        "q": {"type": "parameter", "units": "1", "default": 9.0},
        "left": {"type": "unknown", "units": "1", "shape": ["rows"]},
        "dep": {"type": "unknown", "units": "1"},
        "good": {"type": "unknown", "units": "1"},
        "expensive": {"type": "unknown", "units": "1"},
    });
    let mut equations = vec![
        json!({"lhs": "left", "rhs": faq_over("rows", &["i"], &["i"], json!([]),
            json!({"op": "*", "args": [10.0, "i"]}))}),
        json!({"lhs": "dep", "rhs": faq_over("rows", &["i"], &[], json!(["left"]),
            json!({"op": "index", "args": ["left", "i"]}))}),
        json!({"lhs": "good", "rhs": {"op": "*", "args": [3.0, "dep"]}}),
        json!({"lhs": "expensive", "rhs": faq_over("big", &["a", "b", "c"], &[], json!([]),
            json!({"op": "*", "args": ["a", "b", "c"]}))}),
    ];
    if with_bad {
        variables["bad"] = json!({"type": "unknown", "units": "1"});
        equations.push(json!({"lhs": "bad", "rhs": {
            "op": "table_lookup", "table": "tab", "axes": {"q": "q"}, "args": []}}));
    }
    json!({
        "esm": "1.1.0",
        "metadata": {"name": "Cone"},
        "index_sets": {
            "rows": {"kind": "interval", "size": 3},
            "big": {"kind": "interval", "size": 100},
        },
        "function_tables": {"tab": {
            "axes": [{"name": "q", "values": [0.0, 1.0, 2.0, 3.0]}],
            "interpolation": "linear",
            "out_of_bounds": "error",
            "data": [1.0, 3.0, 2.0, 5.0],
        }},
        "models": {"Rel": {"variables": variables, "equations": equations}},
    })
}

/// Observeds whose values exercise rounding (`sqrt`, `exp`, sums of
/// irrational terms), so a field that moved by one ulp is caught.
fn rounding_document() -> Value {
    json!({
        "esm": "1.1.0",
        "metadata": {"name": "Rounding"},
        "index_sets": {"rows": {"kind": "interval", "size": 7}},
        "models": {"Rel": {
            "variables": {
                "left": {"type": "unknown", "units": "1", "shape": ["rows"]},
                "w": {"type": "unknown", "units": "1", "shape": ["rows"]},
                "s": {"type": "unknown", "units": "1"},
                "u": {"type": "unknown", "units": "1", "shape": ["rows"]},
                "s2": {"type": "unknown", "units": "1"},
                "both": {"type": "unknown", "units": "1"},
            },
            "equations": [
                {"lhs": "left", "rhs": faq_over("rows", &["i"], &["i"], json!([]),
                    json!({"op": "/", "args": [{"op": "sqrt", "args": ["i"]}, 7.0]}))},
                {"lhs": "w", "rhs": faq_over("rows", &["i"], &["i"], json!(["left"]),
                    json!({"op": "*", "args": [{"op": "index", "args": ["left", "i"]},
                        {"op": "exp", "args": [{"op": "/", "args": ["i", -3.0]}]}]}))},
                {"lhs": "s", "rhs": faq_over("rows", &["i"], &[], json!(["w"]),
                    json!({"op": "index", "args": ["w", "i"]}))},
                {"lhs": "u", "rhs": faq_over("rows", &["i"], &["i"], json!(["left"]),
                    json!({"op": "/", "args": [1.0, {"op": "+", "args": [
                        {"op": "index", "args": ["left", "i"]}, 0.1]}]}))},
                {"lhs": "s2", "rhs": faq_over("rows", &["i"], &[], json!(["u"]),
                    json!({"op": "index", "args": ["u", "i"]}))},
                {"lhs": "both", "rhs": {"op": "/", "args": ["s", "s2"]}},
            ],
        }},
    })
}

/// Build `doc`, recording every observed the build pipeline reports.
fn build(
    doc: &Value,
    cone: Option<&[&str]>,
    pipeline: bool,
    compiler: Compiler,
) -> (Result<EsmProblem, String>, Vec<String>) {
    let seen = Arc::new(Mutex::new(Vec::new()));
    let sink = Arc::clone(&seen);
    let prob = esm_problem(
        doc,
        (0.0, 1.0),
        ProblemOptions {
            compiler: Some(compiler),
            build_pipeline: pipeline,
            observed_cone: cone.map(|c| c.iter().map(|s| s.to_string()).collect()),
            progress: Some(Arc::new(move |p: &PrepareProgress<'_>| {
                if p.phase == PreparePhase::Observeds && !p.item.is_empty() {
                    sink.lock().unwrap().push(p.item.to_string());
                }
                Flow::Continue
            })),
            ..Default::default()
        },
    )
    .map_err(|e| e.to_string());
    let seen = seen.lock().unwrap().clone();
    (prob, seen)
}

fn bits(prob: &EsmProblem, name: &str) -> Vec<u64> {
    observed_field(prob, name)
        .unwrap_or_else(|e| panic!("{name}: {e}"))
        .iter()
        .map(|v| v.to_bits())
        .collect()
}

// --------------------------------------------------------------------------- //
// What is outside the cone is not evaluated
// --------------------------------------------------------------------------- //

#[test]
fn the_build_pipeline_evaluates_only_the_cone() {
    // Control: the whole graph includes `bad`, and its evaluation fails.
    let (full, _) = build(&cone_document(true), None, true, Compiler::Native);
    let e = full
        .err()
        .expect("evaluating `bad` must fail the unpruned build");
    assert!(e.contains("table_lookup_out_of_bounds"), "{e}");

    let (prob, seen) = build(
        &cone_document(true),
        Some(&["good"]),
        true,
        Compiler::Native,
    );
    let prob = prob.expect("`bad` is outside the cone of `good`, so it is never evaluated");
    let mut seen = seen;
    seen.sort();
    assert_eq!(seen, ["dep", "good", "left"], "the observeds evaluated");
    assert_eq!(observed_field(&prob, "good").unwrap().sum(), 180.0);
    assert_eq!(observed_field(&prob, "dep").unwrap().sum(), 60.0);
    for outside in ["expensive", "bad"] {
        assert!(
            observed_field(&prob, outside).is_err(),
            "'{outside}' is outside the cone and must not be answered"
        );
    }
}

#[test]
fn the_state_free_evaluation_compiles_only_the_cone() {
    // Control: the state-free pass is all or nothing, and `bad` makes it
    // nothing.
    let (full, _) = build(&cone_document(true), None, false, Compiler::Native);
    let full = full.expect("a fault in the static pass is not a build error");
    assert!(observed_field(&full, "good").is_err());

    for compiler in [Compiler::Native, Compiler::Interpreter] {
        let (prob, _) = build(&cone_document(true), Some(&["Rel.good"]), false, compiler);
        let prob = prob.unwrap_or_else(|e| panic!("[{compiler:?}] {e}"));
        assert_eq!(observed_field(&prob, "good").unwrap().sum(), 180.0);
        for outside in ["expensive", "bad"] {
            assert!(
                observed_field(&prob, outside).is_err(),
                "[{compiler:?}] '{outside}' is outside the cone"
            );
        }
    }
}

#[test]
fn a_bare_name_seeds_every_observed_it_is_the_tail_of() {
    let (prob, seen) = build(&cone_document(true), Some(&["dep"]), true, Compiler::Native);
    prob.expect("builds");
    let mut seen = seen;
    seen.sort();
    assert_eq!(seen, ["dep", "left"]);
}

// --------------------------------------------------------------------------- //
// What is inside the cone is bit-identical
// --------------------------------------------------------------------------- //

#[test]
fn every_field_in_the_cone_is_bit_identical_to_the_unpruned_build() {
    let doc = rounding_document();
    let cones: [(&[&str], &[&str]); 4] = [
        (&["s"], &["left", "w", "s"]),
        (&["s2"], &["left", "u", "s2"]),
        (&["both"], &["left", "w", "s", "u", "s2", "both"]),
        (&["w", "u"], &["left", "w", "u"]),
    ];
    for pipeline in [true, false] {
        for compiler in [Compiler::Native, Compiler::Interpreter] {
            let (full, _) = build(&doc, None, pipeline, compiler);
            let full = full.unwrap_or_else(|e| panic!("{e}"));
            for (request, inside) in cones {
                let (pruned, _) = build(&doc, Some(request), pipeline, compiler);
                let pruned = pruned.unwrap_or_else(|e| panic!("{e}"));
                for name in inside {
                    assert_eq!(
                        bits(&pruned, name),
                        bits(&full, name),
                        "[pipeline={pipeline}, {compiler:?}, cone of {request:?}] '{name}'"
                    );
                }
            }
        }
    }
}

// --------------------------------------------------------------------------- //
// The CLI
// --------------------------------------------------------------------------- //

#[cfg(all(feature = "cli", feature = "solve"))]
mod cli {
    use super::cone_document;
    use std::process::Command;

    fn esm(dir: &std::path::Path, observed: &[&str]) -> (bool, String) {
        let doc = dir.join("cone.esm");
        std::fs::write(&doc, cone_document(true).to_string()).expect("write");
        let mut cmd = Command::new(env!("CARGO_BIN_EXE_esm"));
        cmd.args(["simulate", doc.to_str().unwrap(), "--time", "0", "--output"])
            .arg(dir.join("out.json"));
        for o in observed {
            cmd.args(["--observed", o]);
        }
        let out = cmd.output().expect("runs");
        let mut text = String::from_utf8_lossy(&out.stdout).into_owned();
        text.push_str(&String::from_utf8_lossy(&out.stderr));
        (out.status.success(), text)
    }

    #[test]
    fn simulate_observed_writes_its_cone_and_skips_the_rest() {
        let tmp = tempfile::tempdir().expect("tmpdir");
        let (ok, text) = esm(tmp.path(), &["good"]);
        assert!(ok, "`bad` is outside the cone of `good`:\n{text}");
        assert!(text.contains("good = 180"), "{text}");
        // Without a request every observed is evaluated, `bad` among them.
        let (ok, text) = esm(tmp.path(), &[]);
        assert!(!ok, "{text}");
        assert!(text.contains("table_lookup_out_of_bounds"), "{text}");
    }

    #[test]
    fn an_undeclared_observed_is_refused_before_anything_is_evaluated() {
        let tmp = tempfile::tempdir().expect("tmpdir");
        let (ok, text) = esm(tmp.path(), &["good", "nope", "Rel.nada"]);
        assert!(!ok, "{text}");
        assert!(
            text.contains("'nope', 'Rel.nada'") && text.contains("declares no variable"),
            "{text}"
        );
        // Refused before the build: not after an evaluation that would have
        // failed on `bad` first.
        assert!(!text.contains("table_lookup_out_of_bounds"), "{text}");
        assert!(!text.contains("Running simulation"), "{text}");
        // Every declared spelling is accepted.
        for name in ["good", "Rel.good"] {
            let (ok, text) = esm(tmp.path(), &[name]);
            assert!(ok, "'{name}':\n{text}");
        }
    }
}
