//! esm-spec §4.7 "Binding a data source's location at the mount"
//! (`url_substitutions`), through the `esm` binary's own ingest path: ONE
//! shared catalogue, mounted by two documents that bind it to two data
//! directories, must read two different tables, not just rewrite a string. The
//! load-level pins against `tests/conformance/url_substitutions/manifest.json`
//! are in `earthsci-ast`'s `tests/url_substitutions_conformance.rs`.
//!
//! Gated on this crate's `diffsol` feature (a build with no time integrator
//! refuses `esm simulate` and `esm test`) and on `esio`, the reader the
//! parquet snapshots need.

#![cfg(all(feature = "diffsol", feature = "esio"))]

use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::process::Command;

/// The shared suite, three levels above this crate (`pkg/earthsci-ast-rs/cli`).
fn suite_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../tests/conformance/url_substitutions")
}

fn write(path: &Path, v: &Value) {
    std::fs::create_dir_all(path.parent().expect("parent")).expect("mkdir");
    std::fs::write(path, serde_json::to_string_pretty(v).expect("json")).expect("write");
}

/// `tmp/lib/catalogue.esm` reads `{snapshot}` as a SEGMENT of a location
/// it wrote (`../snapshots/{snapshot}`) and `{data}` as a LEADING
/// location the mounting document supplies.
fn layout(tmp: &Path) {
    for snap in ["a", "b"] {
        let dst = tmp.join("snapshots").join(snap);
        std::fs::create_dir_all(&dst).expect("mkdir");
        std::fs::copy(
            suite_dir().join("snapshots").join(snap).join("t.parquet"),
            dst.join("t.parquet"),
        )
        .expect("copy the committed table");
    }
    let param = |source: &str| {
        json!({"type": "parameter", "units": "1", "shape": ["rows"],
               "update": {"kind": "data", "source": source, "from": {"file_variable": "val"}}})
    };
    // `v[r] = val[r]`: a build-time row set the CLI can write as CSV.
    let copy = |lhs: &str, rhs: &str| {
        json!({"lhs": lhs, "rhs": {"op": "faq", "args": [], "semiring": "sum_product",
            "output_idx": ["r"], "ranges": {"r": {"from": "rows"}},
            "expr": {"op": "index", "args": [rhs, "r"]}}})
    };
    write(
        &tmp.join("lib/catalogue.esm"),
        &json!({
            "esm": "2.0.0",
            "metadata": {"name": "catalogue"},
            "data_sources": {
                "segment": {"kind": "static",
                    "source": {"url_template": "../snapshots/{snapshot}/t.parquet"},
                    "metadata": {"esio_format": "parquet"}},
                "lead": {"kind": "static",
                    "source": {"url_template": "{data}/t.parquet"},
                    "metadata": {"esio_format": "parquet"}}
            },
            "index_sets": {"rows": {"kind": "interval", "size": 4}},
            "models": {"Catalogue": {
                "variables": {
                    "val": param("segment"), "lead_val": param("lead"),
                    "v": {"type": "unknown", "units": "1", "shape": ["rows"]},
                    "lead_v": {"type": "unknown", "units": "1", "shape": ["rows"]}
                },
                "equations": [copy("v", "val"), copy("lead_v", "lead_val")]
            }}
        }),
    );
}

fn mount(tmp: &Path, name: &str, subs: Value) -> PathBuf {
    let p = tmp.join(name);
    write(
        &p,
        &json!({
            "esm": "2.0.0",
            "metadata": {"name": name},
            "models": {"Snap": {"ref": "lib/catalogue.esm", "url_substitutions": subs}}
        }),
    );
    p
}

fn emit(doc: &Path, out: &Path) -> String {
    let o = Command::new(env!("CARGO_BIN_EXE_esm"))
        .args([
            "simulate",
            doc.to_str().expect("utf-8"),
            "--time",
            "0",
            "--format",
            "csv",
            "--observed",
            "Snap.v",
            "--observed",
            "Snap.lead_v",
            "--output",
            out.to_str().expect("utf-8"),
        ])
        .output()
        .expect("run esm");
    assert!(
        o.status.success(),
        "simulate {}:\n{}{}",
        doc.display(),
        String::from_utf8_lossy(&o.stdout),
        String::from_utf8_lossy(&o.stderr)
    );
    std::fs::read_to_string(out).expect("read csv")
}

#[test]
fn one_catalogue_mounted_twice_reads_two_snapshots() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let t = tmp.path();
    layout(t);
    // `data` is relative to the MOUNTING document (tmp/), so
    // `snapshots/b` is tmp/snapshots/b, not tmp/lib/snapshots/b.
    let a = mount(t, "a.esm", json!({"snapshot": "a", "data": "snapshots/b"}));
    let b = mount(
        t,
        "b.esm",
        json!({"snapshot": "b", "data": "./snapshots/a"}),
    );
    assert_eq!(
        emit(&a, &t.join("a.csv")),
        "i1,Snap.v,Snap.lead_v\n1,1,10\n2,2,20\n3,4,40\n4,8,80\n"
    );
    assert_eq!(
        emit(&b, &t.join("b.csv")),
        "i1,Snap.v,Snap.lead_v\n1,10,1\n2,20,2\n3,40,4\n4,80,8\n"
    );
}

#[test]
fn a_leading_value_anchors_on_the_document_that_wrote_the_edge() {
    // The same edge written one directory deeper must reach the same
    // table through `../`, because the value is ITS author's location.
    let tmp = tempfile::tempdir().expect("tempdir");
    let t = tmp.path();
    layout(t);
    let deep = t.join("runs/deep.esm");
    write(
        &deep,
        &json!({
            "esm": "2.0.0",
            "metadata": {"name": "deep"},
            "models": {"Snap": {"ref": "../lib/catalogue.esm",
                "url_substitutions": {"snapshot": "b", "data": "../snapshots/a"}}}
        }),
    );
    assert_eq!(
        emit(&deep, &t.join("deep.csv")),
        "i1,Snap.v,Snap.lead_v\n1,10,1\n2,20,2\n3,40,4\n4,80,8\n"
    );
}

/// The shape a set of run fixtures takes: a SOURCES-ONLY catalogue mounted
/// as one top-level model (so its `data_sources` hoist), and a second model
/// that mounts the logic as a subsystem and carries the run's inline tests.
/// `esm test` must build the model the test belongs to rather than refuse
/// the two-model document.
#[test]
fn a_catalogue_beside_a_tested_model_runs_its_tests() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let t = tmp.path();
    layout(t);
    let mut cat: Value =
        serde_json::from_str(&std::fs::read_to_string(t.join("lib/catalogue.esm")).expect("read"))
            .expect("json");
    let logic = cat["models"]["Catalogue"].take();
    cat["models"] = json!({"Sources": {"variables": {}, "equations": []}});
    write(&t.join("lib/sources.esm"), &cat);
    write(
        &t.join("lib/logic.esm"),
        &json!({"esm": "2.0.0", "metadata": {"name": "logic"},
                "index_sets": {"rows": {"kind": "interval", "size": 4}},
                "models": {"Logic": logic}}),
    );
    for (snap, last) in [("a", 8.0), ("b", 80.0)] {
        let doc = t.join(format!("run_{snap}.esm"));
        write(
            &doc,
            &json!({
                "esm": "2.0.0",
                "metadata": {"name": "run"},
                "models": {
                    "Sources": {"ref": "lib/sources.esm",
                        "url_substitutions": {"snapshot": snap, "data": "snapshots/a"}},
                    "Run": {
                        "variables": {}, "equations": [],
                        "subsystems": {"L": {"ref": "lib/logic.esm"}},
                        "tests": [{"id": "reads_its_snapshot",
                            "time_span": {"start": 0.0, "end": 0.0},
                            "assertions": [{"variable": "L.v", "time": 0.0,
                                "expected": last, "coords": {"rows": 4}}]}]
                    }
                }
            }),
        );
        let o = Command::new(env!("CARGO_BIN_EXE_esm"))
            .args(["test", doc.to_str().expect("utf-8")])
            .output()
            .expect("run esm");
        let text = format!(
            "{}{}",
            String::from_utf8_lossy(&o.stdout),
            String::from_utf8_lossy(&o.stderr)
        );
        assert!(o.status.success(), "esm test run_{snap}.esm:\n{text}");
    }
}
