//! `esm simulate --observed` evaluates only the dependency cone of the
//! requested observeds on a document with nothing to integrate, and refuses a
//! name no declared variable could answer before anything is evaluated, while
//! every name CONFORMANCE_SPEC §5.17.4 resolves is not. The library half
//! (`ProblemOptions::observed_cone`) is pinned by `earthsci-ast`'s
//! `tests/observed_cone.rs`.
//!
//! Gated on this crate's `diffsol` feature: a build with no time integrator
//! refuses `esm simulate`.

#![cfg(feature = "diffsol")]

use serde_json::{Value, json};
use std::process::Command;

fn faq_over(set: &str, idx: &[&str], output: &[&str], args: Value, expr: Value) -> Value {
    let ranges: serde_json::Map<String, Value> = idx
        .iter()
        .map(|i| (i.to_string(), json!({"from": set})))
        .collect();
    json!({"op": "faq", "args": args, "output_idx": output, "ranges": ranges, "expr": expr})
}

/// `left[i] = 10 i` over three rows, `dep = Σ left = 60`, `good = 3 dep =
/// 180`; `expensive` is a million-cell product nothing requested reads, and
/// `bad` a gather of the parameter array `tab` past its end (no boundary policy),
/// which fails any evaluation of it.
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
        variables["tab"] = json!({"type": "parameter", "units": "1", "shape": ["knots"],
            "default": [1.0, 3.0, 2.0, 5.0]});
        variables["bad"] = json!({"type": "unknown", "units": "1"});
        equations.push(json!({"lhs": "bad", "rhs": {"op": "index", "args": ["tab", "q"]}}));
    }
    json!({
        "esm": "2.0.0",
        "metadata": {"name": "Cone"},
        "index_sets": {
            "rows": {"kind": "interval", "size": 3},
            "big": {"kind": "interval", "size": 100},
            "knots": {"kind": "interval", "size": 4},
        },
        "models": {"Rel": {"variables": variables, "equations": equations}},
    })
}

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
    assert!(text.contains("E_TREEWALK_CONSTARRAY_OOB"), "{text}");
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
    assert!(!text.contains("E_TREEWALK_CONSTARRAY_OOB"), "{text}");
    assert!(!text.contains("Running simulation"), "{text}");
    // Every declared spelling is accepted.
    for name in ["good", "Rel.good"] {
        let (ok, text) = esm(tmp.path(), &[name]);
        assert!(ok, "'{name}':\n{text}");
    }
}

/// `Chem.O3` and `Emis.NO` integrate; with `with_sink`, `Sink.O3` too.
fn two_component_document(with_sink: bool) -> Value {
    let decay = |v: &str| {
        json!({"lhs": {"op": "D", "args": [v], "wrt": "t"},
               "rhs": {"op": "*", "args": [-1.0, "k", v]}})
    };
    let component = |v: &str| {
        json!({
            "variables": {
                v: {"type": "unknown", "units": "1", "default": 1.0},
                "k": {"type": "parameter", "units": "1/s", "default": 0.1},
            },
            "equations": [decay(v)],
        })
    };
    let mut models = json!({"Chem": component("O3"), "Emis": component("NO")});
    if with_sink {
        models["Sink"] = component("O3");
    }
    json!({"esm": "2.0.0", "metadata": {"name": "Two"}, "models": models})
}

fn esm_grid(dir: &std::path::Path, doc: &Value, observed: &str) -> (bool, String) {
    let path = dir.join("two.esm");
    std::fs::write(&path, doc.to_string()).expect("write");
    let out = Command::new(env!("CARGO_BIN_EXE_esm"))
        .args([
            "simulate",
            path.to_str().unwrap(),
            "--time",
            "1",
            "--format",
            "grid",
        ])
        .args(["--observed", observed, "--output"])
        .arg(dir.join("out.json"))
        .output()
        .expect("runs");
    let mut text = String::from_utf8_lossy(&out.stdout).into_owned();
    text.push_str(&String::from_utf8_lossy(&out.stderr));
    (out.status.success(), text)
}

#[test]
fn a_name_the_output_rule_resolves_by_its_last_segment_is_not_refused() {
    // CONFORMANCE_SPEC §5.17.4 rule 2: `Emis.O3` names no variable
    // exactly, and `Chem.O3` is the one variable whose last segment is
    // `O3`.
    let tmp = tempfile::tempdir().expect("tmpdir");
    let (ok, text) = esm_grid(tmp.path(), &two_component_document(false), "Emis.O3");
    assert!(ok, "{text}");
}

#[test]
fn an_ambiguous_name_is_refused_as_ambiguous_not_as_undeclared() {
    let tmp = tempfile::tempdir().expect("tmpdir");
    let (ok, text) = esm_grid(tmp.path(), &two_component_document(true), "Emis.O3");
    assert!(!ok, "{text}");
    assert!(!text.contains("declares no variable"), "{text}");
    assert!(text.contains("last segment is shared by"), "{text}");
    assert!(
        text.contains("Chem.O3") && text.contains("Sink.O3"),
        "{text}"
    );
}
