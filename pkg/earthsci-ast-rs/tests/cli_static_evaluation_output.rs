//! `esm simulate` must write the values of a document that has nothing to
//! integrate.
//!
//! A *relational* document computes rows from rows and carries no `D(x)/dt` —
//! the shape of every MOVES-style calculator. Such a document evaluates
//! correctly (`esm test` asserts on it), but `simulate` was the only subcommand
//! that writes computed values to a file and it compiled a right-hand side for
//! a system with nothing to integrate, then died inside the solver:
//!
//! ```text
//! Error: "solve failed: diffsol error: ODE solver error:
//!         Exceeded maximum number of nonlinear solver failures (51) at time = 0"
//! ```
//!
//! So there was no route at all from a computed row set to a file, and a
//! row-by-row comparison could not run. These tests pin the route:
//!
//!   * the values written are the REAL ones — each fixture field has a known
//!     non-zero value no `default` could produce, because "writes a file" and
//!     "writes the answer" are different claims and only the second is worth
//!     anything here;
//!   * `--format csv` is the row set itself, byte-for-byte;
//!   * a request that cannot be one row set is REFUSED with the shapes named,
//!     never truncated or padded into a table that looks right;
//!   * and a document that does integrate is untouched — the change that
//!     enables all of this is `Compile::Always` becoming `Compile::Auto`, which
//!     only a dynamic-document test can prove was safe.

#![cfg(all(not(target_arch = "wasm32"), feature = "cli", feature = "solve"))]

use std::fs;
use std::path::Path;
use std::process::Command;

use serde_json::{Value, json};

/// `left[i] = 10 i` and `right[i] = i² + 1` over three rows, plus a scalar
/// `total = Σ left[i]`. Every number is unreachable from a `default`.
const LEFT: [f64; 3] = [10.0, 20.0, 30.0];
const RIGHT: [f64; 3] = [2.0, 5.0, 10.0];
const TOTAL: f64 = 60.0;

/// A purely relational document: three observeds, an aggregate over a range,
/// and zero differential equations.
fn relational_document() -> Value {
    let over = |name: &str, expr: Value| {
        json!({
            "lhs": name,
            "rhs": {
                "op": "aggregate", "args": [], "output_idx": ["i"],
                "ranges": {"i": {"from": "rows"}}, "expr": expr
            }
        })
    };
    json!({
        "esm": "1.0.0",
        "metadata": {"name": "RelationalEmit", "description": "Rows from rows; nothing to integrate."},
        "index_sets": {"rows": {"kind": "interval", "size": 3}},
        "models": {
            "Rel": {
                "variables": {
                    "left":  {"type": "unknown", "units": "1", "shape": ["rows"]},
                    "right": {"type": "unknown", "units": "1", "shape": ["rows"]},
                    "total": {"type": "unknown", "units": "1"}
                },
                "equations": [
                    over("left", json!({"op": "*", "args": [10.0, "i"]})),
                    over("right", json!({"op": "+", "args": [{"op": "*", "args": ["i", "i"]}, 1.0]})),
                    {
                        "lhs": "total",
                        "rhs": {
                            "op": "aggregate", "args": ["left"], "output_idx": [],
                            "ranges": {"i": {"from": "rows"}},
                            "expr": {"op": "index", "args": ["left", "i"]}
                        }
                    }
                ]
            }
        }
    })
}

/// A document that DOES integrate, so the `Compile::Auto` change can be shown
/// not to have moved it.
const DYNAMIC: &str = "tests/fixtures/inline_tests/passing_decay.esm";

fn write_doc(dir: &Path, doc: &Value) -> std::path::PathBuf {
    let path = dir.join("relational.esm");
    fs::write(&path, serde_json::to_string_pretty(doc).expect("renders")).expect("write");
    path
}

fn esm(args: &[&str]) -> (bool, String) {
    let out = Command::new(env!("CARGO_BIN_EXE_esm"))
        .current_dir(env!("CARGO_MANIFEST_DIR"))
        .args(args)
        .output()
        .unwrap_or_else(|e| panic!("could not run the esm binary: {e}"));
    let mut text = String::from_utf8_lossy(&out.stdout).into_owned();
    text.push_str(&String::from_utf8_lossy(&out.stderr));
    (out.status.success(), text)
}

/// The flat writer's `name -> value at the last output time` map.
fn flat_values(path: &Path) -> std::collections::BTreeMap<String, f64> {
    let doc: Value = serde_json::from_str(&fs::read_to_string(path).expect("read output"))
        .expect("output parses");
    doc["state_variable_names"]
        .as_array()
        .expect("names")
        .iter()
        .zip(doc["state"].as_array().expect("state"))
        .map(|(n, row)| {
            (
                n.as_str().expect("name is a string").to_string(),
                row.as_array()
                    .and_then(|r| r.last())
                    .and_then(Value::as_f64)
                    .expect("a value at the last output time"),
            )
        })
        .collect()
}

// --------------------------------------------------------------------------- //
// The route from a computed row set to a file
// --------------------------------------------------------------------------- //

#[test]
fn a_relational_document_writes_its_computed_values() {
    let tmp = tempfile::tempdir().expect("tmpdir");
    let doc = write_doc(tmp.path(), &relational_document());
    let out = tmp.path().join("rows.json");
    let (ok, text) = esm(&[
        "simulate",
        doc.to_str().expect("utf-8"),
        "--time",
        "0",
        "--output",
        out.to_str().expect("utf-8"),
    ]);
    assert!(ok, "a relational document must not fail to emit:\n{text}");
    assert!(
        text.contains("Static evaluation complete"),
        "it must say it evaluated rather than integrated:\n{text}"
    );

    let values = flat_values(&out);
    // The VALUES, not merely a file: a run that wrote defaults would pass a
    // "the file exists" assertion and fail every one of these.
    for (i, want) in LEFT.iter().enumerate() {
        assert_eq!(
            values[&format!("Rel.left[{}]", i + 1)],
            *want,
            "in {values:?}"
        );
    }
    for (i, want) in RIGHT.iter().enumerate() {
        assert_eq!(
            values[&format!("Rel.right[{}]", i + 1)],
            *want,
            "in {values:?}"
        );
    }
    assert_eq!(values["Rel.total[1]"], TOTAL, "in {values:?}");
}

#[test]
fn format_csv_writes_the_row_set_itself() {
    let tmp = tempfile::tempdir().expect("tmpdir");
    let doc = write_doc(tmp.path(), &relational_document());
    let out = tmp.path().join("rows.csv");
    let (ok, text) = esm(&[
        "simulate",
        doc.to_str().expect("utf-8"),
        "--time",
        "0",
        "--format",
        "csv",
        "--observed",
        "left",
        "--observed",
        "right",
        "--output",
        out.to_str().expect("utf-8"),
    ]);
    assert!(ok, "csv emit must succeed:\n{text}");
    assert_eq!(
        fs::read_to_string(&out).expect("read csv"),
        "i1,left,right\n1,10,2\n2,20,5\n3,30,10\n",
        "one row per index tuple, the index column first"
    );
}

#[test]
fn a_csv_request_that_is_not_one_row_set_is_refused_with_the_shapes_named() {
    let tmp = tempfile::tempdir().expect("tmpdir");
    let doc = write_doc(tmp.path(), &relational_document());
    let out = tmp.path().join("rows.csv");
    // `total` is a scalar; it cannot be a column of a 3-row table. Padding or
    // truncating it would produce a table that looks right and is not.
    let (ok, text) = esm(&[
        "simulate",
        doc.to_str().expect("utf-8"),
        "--time",
        "0",
        "--format",
        "csv",
        "--observed",
        "left",
        "--observed",
        "total",
        "--output",
        out.to_str().expect("utf-8"),
    ]);
    assert!(!ok, "mismatched shapes must not exit 0:\n{text}");
    assert!(text.contains("[3]") && text.contains("[1]"), "in:\n{text}");
    assert!(text.contains("total"), "must name the offender:\n{text}");
    assert!(!out.exists(), "nothing may be written on refusal");
}

#[test]
fn a_named_field_the_build_did_not_produce_is_an_error() {
    let tmp = tempfile::tempdir().expect("tmpdir");
    let doc = write_doc(tmp.path(), &relational_document());
    let out = tmp.path().join("rows.json");
    let (ok, text) = esm(&[
        "simulate",
        doc.to_str().expect("utf-8"),
        "--time",
        "0",
        "--observed",
        "not_a_field",
        "--output",
        out.to_str().expect("utf-8"),
    ]);
    assert!(
        !ok,
        "a missing field must not silently drop a column:\n{text}"
    );
    assert!(text.contains("not_a_field"), "in:\n{text}");
}

// --------------------------------------------------------------------------- //
// ...and a document that does integrate is untouched
// --------------------------------------------------------------------------- //

#[test]
fn a_dynamic_document_still_integrates_and_writes_its_trajectory() {
    let tmp = tempfile::tempdir().expect("tmpdir");
    let out = tmp.path().join("traj.json");
    let (ok, text) = esm(&[
        "simulate",
        DYNAMIC,
        "--time",
        "100",
        "--output",
        out.to_str().expect("utf-8"),
    ]);
    assert!(ok, "the dynamic fixture must still solve:\n{text}");
    assert!(
        text.contains("Simulation complete"),
        "it must still report a simulation, not a static evaluation:\n{text}"
    );
    let doc: Value = serde_json::from_str(&fs::read_to_string(&out).expect("read")).expect("json");
    assert!(
        doc["time"].as_array().expect("time").len() > 1,
        "a trajectory has more than one output point"
    );
    // x(100) = exp(-1) for the fixture's x0 = 1, k = 0.01 — to the CLI's default
    // solver tolerance (reltol 1e-4), which is what this run used.
    let x = flat_values(&out)["PassingDecay.x"];
    let want = (-1.0f64).exp();
    assert!(
        (x - want).abs() <= 1e-4 * want,
        "x(100) = {x}, want exp(-1) = {want}"
    );
}

#[test]
fn format_csv_on_a_trajectory_is_refused() {
    let tmp = tempfile::tempdir().expect("tmpdir");
    let out = tmp.path().join("traj.csv");
    let (ok, text) = esm(&[
        "simulate",
        DYNAMIC,
        "--time",
        "100",
        "--format",
        "csv",
        "--output",
        out.to_str().expect("utf-8"),
    ]);
    assert!(!ok, "csv on a trajectory must not exit 0:\n{text}");
    assert!(text.contains("row set"), "in:\n{text}");
}
