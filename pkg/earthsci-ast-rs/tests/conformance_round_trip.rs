//! Conformance harness adapter — round-trip category (Rust binding).
//!
//! The oracle is the AUTHORED FIXTURE. The shared harness used to compare emit
//! pass 2 against emit pass 3, with `F` itself never a participant — the
//! self-comparing shape described in `tests/conformance/README.md`, blind to any
//! field lost on the FIRST load because the second emit forgets exactly what the
//! first forgot. esm-spec §9.6.4 rule 5 now states BOTH halves normatively
//! ("Load preservation" and "Idempotence") and neither implies the other, so
//! both are asserted here.
//!
//! This is the CROSS-BINDING adapter, driven by the shared manifest at
//! `tests/conformance/round_trip/manifest.json`. It is distinct from
//! `round_trip.rs`, which pins a hardcoded `include_str!` subset with
//! crate-local typed assertions; this one covers the whole shared list and is
//! read by the same manifest as the other four bindings.
//!
//! See `tests/conformance/README.md` for the contract: the five normalizations,
//! the two exemption ledgers (`load_transforms` for spec-mandated rewrites,
//! `known_divergences` for the defect ratchet), and the `preserved_keys`
//! field-loss check that runs on EVERY fixture, excused or not.

use earthsci_ast::*;
use serde_json::{Map, Value};
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

const BINDING: &str = "rust";

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .expect("repo root")
}

/// Applied to BOTH sides, so no relaxation can hide a drop. Implements the five
/// normalizations in `tests/conformance/README.md` (admissions 1 and 2 of
/// esm-spec §9.6.4 rule 5).
fn normalize(v: &Value, parent: &str) -> Value {
    match v {
        Value::Object(m) => {
            let mut out = Map::new();
            for (k, x) in m {
                let y = normalize(x, k);
                let empty = match &y {
                    Value::Object(o) => o.is_empty(),
                    Value::Array(a) => a.is_empty(),
                    _ => false,
                };
                if empty || k == "expect_cadence" {
                    continue;
                }
                if k == "independent_variable" && parent == "domain" && y.as_str() == Some("t") {
                    continue;
                }
                if k == "initial_offset" && y.as_f64() == Some(0.0) {
                    continue;
                }
                out.insert(k.clone(), y);
            }
            Value::Object(out)
        }
        Value::Array(a) => Value::Array(a.iter().map(|x| normalize(x, parent)).collect()),
        _ => v.clone(),
    }
}

fn brief(v: &Value) -> String {
    let s = v.to_string();
    if s.len() > 120 {
        format!("{}…", &s[..120])
    } else {
        s
    }
}

/// Every JSON-pointer path at which the two documents differ. Numbers compare by
/// MATHEMATICAL VALUE, not spelling — a tolerance for where the bindings stand
/// today (see the manifest's `normalizations` and the header of `round_trip.rs`),
/// not a rule the format grants.
fn value_diff(path: &str, a: &Value, b: &Value, out: &mut Vec<String>) {
    if out.len() > 25 {
        return;
    }
    match (a, b) {
        (Value::Object(ma), Value::Object(mb)) => {
            for (k, va) in ma {
                match mb.get(k) {
                    Some(vb) => value_diff(&format!("{path}/{k}"), va, vb, out),
                    None => out.push(format!("{path}/{k}  DROPPED (was {})", brief(va))),
                }
            }
            for (k, vb) in mb {
                if !ma.contains_key(k) {
                    out.push(format!("{path}/{k}  ADDED ({})", brief(vb)));
                }
            }
        }
        (Value::Array(aa), Value::Array(ab)) => {
            if aa.len() != ab.len() {
                out.push(format!("{path}  LENGTH {} -> {}", aa.len(), ab.len()));
                return;
            }
            for (i, (va, vb)) in aa.iter().zip(ab.iter()).enumerate() {
                value_diff(&format!("{path}[{i}]"), va, vb, out);
            }
        }
        (Value::Number(na), Value::Number(nb)) => {
            if na.as_f64() != nb.as_f64() {
                out.push(format!("{path}  {a} -> {b}"));
            }
        }
        _ => {
            if a != b {
                out.push(format!("{path}  {} -> {}", brief(a), brief(b)));
            }
        }
    }
}

/// `(wire_key, json_path)` for every mapping key in `orig` absent from `emitted`.
fn dropped_keys(orig: &Value, emitted: &Value, path: &str, out: &mut Vec<(String, String)>) {
    match (orig, emitted) {
        (Value::Object(mo), Value::Object(me)) => {
            for (k, v) in mo {
                let here = format!("{path}.{k}");
                match me.get(k) {
                    Some(e) => dropped_keys(v, e, &here, out),
                    None => out.push((k.clone(), here)),
                }
            }
        }
        (Value::Array(ao), Value::Array(ae)) => {
            for (i, (v, e)) in ao.iter().zip(ae.iter()).enumerate() {
                dropped_keys(v, e, &format!("{path}[{i}]"), out);
            }
        }
        _ => {}
    }
}

fn strings(v: &Value) -> Vec<String> {
    v.as_array()
        .map(|a| {
            a.iter()
                .filter_map(|x| x.as_str().map(String::from))
                .collect()
        })
        .unwrap_or_default()
}

#[test]
fn conformance_round_trip_manifest() {
    let root = repo_root();
    let tests_dir = root.join("tests");
    let manifest_path = tests_dir.join("conformance/round_trip/manifest.json");
    let manifest: Value = serde_json::from_str(
        &std::fs::read_to_string(&manifest_path)
            .unwrap_or_else(|e| panic!("conformance manifest not found at {manifest_path:?}: {e}")),
    )
    .expect("manifest is not JSON");

    assert_eq!(manifest["category"], "round_trip");
    let fixtures = manifest["fixtures"].as_array().expect("fixtures array");
    assert!(!fixtures.is_empty());

    let preserved: BTreeSet<String> = strings(&manifest["preserved_keys"]).into_iter().collect();

    // Fixture id => the divergence entry naming THIS binding non-conformant. A
    // binding listed `conformant`, or in neither column, stays held to full
    // equality: that is what makes the ledger a ratchet rather than a licence.
    let mut excused: std::collections::BTreeMap<String, String> = Default::default();
    if let Some(entries) = manifest["known_divergences"].as_array() {
        for e in entries {
            if !strings(&e["nonconformant"]).iter().any(|b| b == BINDING) {
                continue;
            }
            let id = e["id"].as_str().unwrap_or("?").to_string();
            for f in strings(&e["fixtures"]) {
                excused.insert(f, id.clone());
            }
        }
    }

    let mut failures: Vec<String> = Vec::new();
    let mut stale: Vec<String> = Vec::new();
    let mut known: Vec<String> = Vec::new();

    for fixture in fixtures {
        let id = fixture["id"].as_str().expect("fixture id");
        let path = tests_dir.join(fixture["path"].as_str().expect("fixture path"));
        if !path.is_file() {
            failures.push(format!("{id}: fixture not on disk at {path:?}"));
            continue;
        }

        let authored_text = std::fs::read_to_string(&path).expect("read fixture");
        let parsed = match load_path(&path) {
            Ok(v) => v,
            Err(e) => {
                failures.push(format!("{id}: load failed: {e}"));
                continue;
            }
        };
        let first_json = match to_json(&parsed) {
            Ok(s) => s,
            Err(e) => {
                failures.push(format!("{id}: save failed: {e}"));
                continue;
            }
        };

        let authored = normalize(
            &serde_json::from_str(&authored_text).expect("fixture JSON"),
            "",
        );
        let emitted = normalize(
            &serde_json::from_str(&first_json).expect("emitted JSON"),
            "",
        );

        let has_transform = fixture
            .get("load_transforms")
            .and_then(|t| t.as_array())
            .is_some_and(|a| !a.is_empty());
        let divergence = excused.get(id);
        let is_excused = has_transform || divergence.is_some();

        let mut diff = Vec::new();
        value_diff("", &authored, &emitted, &mut diff);

        // 1. LOAD PRESERVATION (esm-spec §9.6.4 rule 5).
        if !is_excused {
            if !diff.is_empty() {
                failures.push(format!(
                    "{id}: save(load(F)) differs from F — either a field is being \
                     dropped/invented, or a spec-REQUIRED load-time transform needs a \
                     `load_transforms` entry citing its clause. Do NOT add one to silence \
                     a drop.\n    {}",
                    diff.join("\n    ")
                ));
            }
        } else if diff.is_empty() {
            // Improving, not failing: README adapter contract item 8.
            stale.push(id.to_string());
        }

        // 2. FIELD LOSS — runs on EVERY fixture, excused or not. A load-time
        //    transform rewrites a CONSTRUCT; it does not licence dropping the
        //    document around it.
        let mut dropped = Vec::new();
        dropped_keys(&authored, &emitted, "", &mut dropped);
        let lost: Vec<String> = dropped
            .into_iter()
            .filter(|(k, _)| preserved.contains(k))
            .map(|(_, where_)| where_)
            .collect();
        if !lost.is_empty() {
            failures.push(format!("{id}: dropped preserved field(s) at {lost:?}"));
        }

        // 3. IDEMPOTENCE (esm-spec §9.6.4 rule 5) — still required, no longer
        //    alone. A ledger-excused fixture whose emit is not RE-LOADABLE (a
        //    drop that removed a schema-required field) is recorded as a known
        //    failure naming the ledger entry — never a silent pass.
        match load_string(&first_json).and_then(|f| to_json(&f)) {
            Ok(second_json) => {
                let a: Value = serde_json::from_str(&first_json).unwrap();
                let b: Value = serde_json::from_str(&second_json).unwrap();
                if a != b {
                    failures.push(format!("{id}: emit is not a fixed point"));
                }
            }
            Err(e) => match divergence {
                Some(entry) => known.push(format!(
                    "{id}: emit is not re-loadable ({e}); known_divergence '{entry}'"
                )),
                None => failures.push(format!("{id}: emit is not re-loadable: {e}")),
            },
        }
    }

    if !stale.is_empty() {
        println!(
            "note: excused fixtures that now round-trip cleanly in {BINDING} \
             (ledger entry may be stale — trim by hand; NOT a failure): {stale:?}"
        );
    }
    for k in &known {
        println!("known failure: {k}");
    }
    assert!(
        failures.is_empty(),
        "round-trip conformance failed on {} fixture(s):\n  {}",
        failures.len(),
        failures.join("\n  ")
    );
}
