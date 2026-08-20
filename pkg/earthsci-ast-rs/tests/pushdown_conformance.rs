//! Pushdown-rewrite golden conformance (tests/conformance/pushdown).
//!
//! The adapter contract from the corpus README, exercised against the Rust
//! `desugar_pushdown` port: for each manifest fixture,
//!
//! 1. parse the input document (plain JSON parse — raw doc→doc transform);
//! 2. run `desugar_pushdown` (with the manifest's `model_name`);
//! 3. assert the output DEEP-EQUALS the parsed golden (numbers by value —
//!    `0 == 0.0` — key order free, lists element-wise in order);
//! 4. assert IDEMPOTENCY: desugaring the golden returns it unchanged (the
//!    provenance-record guard);
//! 5. assert INPUT PURITY: the input document is not mutated.

use std::borrow::Cow;
use std::path::{Path, PathBuf};

use serde_json::Value;

use earthsci_ast::pushdown_rewrite::{desugar_pushdown, pushdown_diagnostics};

fn corpus_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/conformance/pushdown")
        .canonicalize()
        .expect("conformance corpus tests/conformance/pushdown exists at the repo root")
}

fn read_json(path: &Path) -> Value {
    let text = std::fs::read_to_string(path)
        .unwrap_or_else(|e| panic!("read {}: {e}", path.display()));
    serde_json::from_str(&text).unwrap_or_else(|e| panic!("parse {}: {e}", path.display()))
}

/// Deep equality with numbers compared BY VALUE (`0 == 0.0`), per the corpus
/// comparison contract. On mismatch, returns the JSON-pointer-ish path of the
/// first difference for the assertion message.
fn deep_equal(a: &Value, b: &Value, path: &str) -> Result<(), String> {
    match (a, b) {
        (Value::Number(x), Value::Number(y)) => {
            let (xf, yf) = (x.as_f64(), y.as_f64());
            if xf == yf && xf.is_some() {
                Ok(())
            } else {
                Err(format!("{path}: number {x} != {y}"))
            }
        }
        (Value::Object(x), Value::Object(y)) => {
            if x.len() != y.len() {
                let xk: Vec<_> = x.keys().collect();
                let yk: Vec<_> = y.keys().collect();
                return Err(format!("{path}: object keys differ: {xk:?} vs {yk:?}"));
            }
            for (k, xv) in x {
                let Some(yv) = y.get(k) else {
                    return Err(format!("{path}: key '{k}' missing on the right"));
                };
                deep_equal(xv, yv, &format!("{path}/{k}"))?;
            }
            Ok(())
        }
        (Value::Array(x), Value::Array(y)) => {
            if x.len() != y.len() {
                return Err(format!("{path}: array length {} != {}", x.len(), y.len()));
            }
            for (i, (xv, yv)) in x.iter().zip(y).enumerate() {
                deep_equal(xv, yv, &format!("{path}/{i}"))?;
            }
            Ok(())
        }
        (x, y) => {
            if x == y {
                Ok(())
            } else {
                Err(format!("{path}: {x} != {y}"))
            }
        }
    }
}

#[test]
fn pushdown_goldens_match_and_rewrite_is_idempotent_and_pure() {
    let dir = corpus_dir();
    let manifest = read_json(&dir.join("manifest.json"));
    let fixtures = manifest["fixtures"]
        .as_array()
        .expect("manifest lists fixtures");
    assert!(!fixtures.is_empty(), "manifest has no fixtures");

    for fx in fixtures {
        let id = fx["id"].as_str().unwrap();
        // Manifest paths are repo-root-tests-relative ("conformance/pushdown/…").
        let input_path = dir.join("../..").join(fx["input"].as_str().unwrap());
        let model_name = fx["model_name"].as_str();
        // A fixture either carries a rewrite `golden` (the pattern fires) or
        // declares `fires: false` and pins the residual `diagnostics` instead.
        let fires = fx.get("fires").and_then(Value::as_bool).unwrap_or(true);

        let input = read_json(&input_path);
        let input_snapshot = input.clone();

        let out = desugar_pushdown(&input, model_name).unwrap_or_else(|e| panic!("{id}: {e}"));
        if fires {
            let golden = read_json(&dir.join("../..").join(fx["golden"].as_str().unwrap()));
            // 2–3: rewrite fires and matches the golden by value.
            assert!(
                matches!(out, Cow::Owned(_)),
                "{id}: desugar_pushdown did not fire on the input document"
            );
            if let Err(diff) = deep_equal(&out, &golden, "") {
                panic!("{id}: rewritten document differs from the golden at {diff}");
            }

            // 4: idempotency — the golden (record-carrying) document is returned
            // unchanged, borrowed.
            let again =
                desugar_pushdown(&golden, model_name).unwrap_or_else(|e| panic!("{id}: {e}"));
            assert!(
                matches!(again, Cow::Borrowed(_)),
                "{id}: desugaring the golden re-fired (idempotency guard broken)"
            );
        } else {
            // A `fires: false` fixture is NOT rewritten — and says why.
            assert!(
                matches!(out, Cow::Borrowed(_)),
                "{id}: desugar_pushdown fired on a fixture that must not be rewritten"
            );
        }

        // 4b: the residual diagnostics, when the fixture pins them.
        if let Some(dg) = fx.get("diagnostics").and_then(Value::as_str) {
            let golden_dg = read_json(&dir.join("../..").join(dg));
            let got = Value::Array(pushdown_diagnostics(&input, model_name));
            if let Err(diff) = deep_equal(&got, &golden_dg, "") {
                panic!("{id}: diagnostics differ from the golden at {diff}");
            }
        }

        // 5: input purity — byte-level: the rewrite never mutates its input.
        assert_eq!(input, input_snapshot, "{id}: input document was mutated");
    }
}

/// The §5.5.7 canonical equation order is INDEPENDENT of the input's order.
///
/// The ordered golden comparison above would also pass if the rewrite merely
/// appended in a lucky order, because the corpus fixtures happen to list their
/// definitions sorted already. This drives the same fixture with its equations
/// REVERSED: the output must be identical either way, which is the property the
/// rule exists for — the rewrite generates member buffers and cell gathers
/// while walking a hash map, so an un-canonicalized emission varies with the
/// hash seed and could not be compared as an ordered array at all.
#[test]
fn equation_order_is_canonical_not_input_order() {
    let dir = corpus_dir();
    let path = dir.join("fixtures/pushdown_l1.esm");
    let input = read_json(&path);

    let mut reversed = input.clone();
    reversed["models"]["ISRM"]["equations"]
        .as_array_mut()
        .expect("equations array")
        .reverse();

    let from_input = desugar_pushdown(&input, Some("ISRM")).expect("rewrite fires");
    let from_reversed = desugar_pushdown(&reversed, Some("ISRM")).expect("rewrite fires");
    assert_eq!(
        from_input["models"]["ISRM"]["equations"],
        from_reversed["models"]["ISRM"]["equations"],
        "reversing the input's equations changed the rewritten order"
    );

    // ...and that order is the two-part rule, not just *some* stable order.
    let eqs = from_input["models"]["ISRM"]["equations"]
        .as_array()
        .expect("equations array");
    let first_definition = eqs
        .iter()
        .position(|e| e["lhs"].is_string())
        .expect("the rewrite emits definitions");
    assert!(
        eqs[..first_definition].iter().all(|e| !e["lhs"].is_string()),
        "every non-bare-LHS equation must precede every definition"
    );
    let names: Vec<&str> = eqs[first_definition..]
        .iter()
        .map(|e| e["lhs"].as_str().expect("definitions are contiguous"))
        .collect();
    let mut sorted = names.clone();
    sorted.sort_unstable();
    assert_eq!(names, sorted, "definitions must be sorted by the defined name");
}
