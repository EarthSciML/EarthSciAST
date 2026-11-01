//! esm-spec §4.7 "Binding a data source's location at the mount"
//! (`url_substitutions`), through a real load, against the SHARED pin
//! `tests/conformance/url_substitutions/manifest.json` (`fixtures`). The edge
//! rule itself (`cases`) is pinned by the unit test in `src/data_source_urls.rs`.
//!
//! The ingestion tests at the bottom are the reason the field exists: ONE
//! shared catalogue, mounted by two documents that bind it to two data
//! directories, must read two different tables — through the `esm` binary's
//! own ingest path, not just a rewritten string.

use serde_json::Value;
use std::path::{Path, PathBuf};

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(Path::parent)
        .expect("the crate sits two levels under the repository root")
        .to_path_buf()
}

fn suite_dir() -> PathBuf {
    repo_root().join("tests/conformance/url_substitutions")
}

fn manifest() -> Value {
    let p = suite_dir().join("manifest.json");
    serde_json::from_str(&std::fs::read_to_string(&p).expect("read the shared manifest"))
        .expect("manifest.json is JSON")
}

/// Lexical dot-segment removal, so a `repo_path` pin compares with the
/// resolved (lexically normalized) URL.
fn normalize(p: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for c in p.components() {
        match c {
            std::path::Component::ParentDir => {
                out.pop();
            }
            std::path::Component::CurDir => {}
            other => out.push(other.as_os_str()),
        }
    }
    out
}

fn expected(pin: &Value) -> String {
    if let Some(v) = pin.get("verbatim").and_then(Value::as_str) {
        return v.to_string();
    }
    let rel = pin["repo_path"].as_str().expect("repo_path or verbatim");
    format!("file://{}", normalize(&repo_root().join(rel)).display())
}

#[test]
fn every_fixture_loads_or_is_refused_as_the_shared_manifest_says() {
    let m = manifest();
    let fixtures = m["fixtures"].as_array().expect("fixtures");
    assert!(!fixtures.is_empty());
    for f in fixtures {
        let id = f["id"].as_str().expect("id");
        let path = suite_dir().join(f["path"].as_str().expect("path"));
        let loaded = earthsci_ast::load_path(&path);
        match f["expect"].as_str().expect("expect") {
            "accepted" => {
                let doc = loaded.unwrap_or_else(|e| panic!("{id} must load: {e}"));
                let doc = serde_json::to_value(&doc).expect("serializable");
                for (axis, size) in f
                    .get("index_set_sizes")
                    .and_then(Value::as_object)
                    .into_iter()
                    .flatten()
                {
                    assert_eq!(
                        doc["index_sets"][axis]["size"], *size,
                        "{id}: index_sets.{axis}.size"
                    );
                }
                // A mounted document's `data_sources` merge into the mounting
                // document at either form, so the substituted locations are
                // observable here.
                let Some(pins) = f.get("hoisted_sources").and_then(Value::as_object) else {
                    continue;
                };
                for (name, pin) in pins {
                    let src = &doc["data_sources"][name]["source"];
                    assert_eq!(
                        src["url_template"],
                        Value::String(expected(&pin["url_template"])),
                        "{id}: data_sources.{name}.source.url_template"
                    );
                    if let Some(ms) = pin.get("mirrors").and_then(Value::as_array) {
                        let want: Vec<Value> =
                            ms.iter().map(|p| Value::String(expected(p))).collect();
                        assert_eq!(src["mirrors"], Value::Array(want), "{id}: mirrors");
                    }
                }
            }
            "refused" => {
                let e = loaded
                    .err()
                    .unwrap_or_else(|| panic!("{id} must be REFUSED at load"))
                    .to_string();
                let code = f["error_code"].as_str().expect("error_code");
                assert!(
                    earthsci_ast::ERROR_CODES.iter().any(|(_, v)| *v == code),
                    "{code} must be a registered code"
                );
                assert!(e.contains(code), "{id}: must carry [{code}]: {e}");
                for n in f["message_contains"].as_array().into_iter().flatten() {
                    let n = n.as_str().expect("str");
                    assert!(e.contains(n), "{id}: must name {n:?}: {e}");
                }
            }
            other => panic!("{id}: unknown expectation {other:?}"),
        }
    }
}

#[test]
fn the_edge_does_not_survive_parse_emit_and_the_emitted_form_is_a_fixed_point() {
    let path = suite_dir().join("mount_toplevel.esm");
    let first = earthsci_ast::load_path(&path).expect("loads");
    let emitted = earthsci_ast::to_json(&first).expect("emits");
    assert!(
        !emitted.contains("\"url_substitutions\":"),
        "the edge is consumed at load"
    );
    let tmp = tempfile::tempdir().expect("tempdir");
    let out = tmp.path().join("emitted.esm");
    std::fs::write(&out, &emitted).expect("write");
    let second = earthsci_ast::load_path(&out).expect("the emitted document loads");
    assert_eq!(
        serde_json::to_value(&first).expect("v")["data_sources"],
        serde_json::to_value(&second).expect("v")["data_sources"],
    );
}

/// One shared catalogue (with a parameter that consumes its source), two
/// mounting documents binding it to the two committed snapshots.
#[cfg(all(
    not(target_arch = "wasm32"),
    feature = "cli",
    feature = "solve",
    feature = "esio"
))]
mod ingest {
    use super::*;
    use serde_json::json;
    use std::process::Command;

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
                "esm": "1.2.0",
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
                "esm": "1.2.0",
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
                "esm": "1.2.0",
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
        let mut cat: Value = serde_json::from_str(
            &std::fs::read_to_string(t.join("lib/catalogue.esm")).expect("read"),
        )
        .expect("json");
        let logic = cat["models"]["Catalogue"].take();
        cat["models"] = json!({"Sources": {"variables": {}, "equations": []}});
        write(&t.join("lib/sources.esm"), &cat);
        write(
            &t.join("lib/logic.esm"),
            &json!({"esm": "1.2.0", "metadata": {"name": "logic"},
                    "index_sets": {"rows": {"kind": "interval", "size": 4}},
                    "models": {"Logic": logic}}),
        );
        for (snap, last) in [("a", 8.0), ("b", 80.0)] {
            let doc = t.join(format!("run_{snap}.esm"));
            write(
                &doc,
                &json!({
                    "esm": "1.2.0",
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
}
