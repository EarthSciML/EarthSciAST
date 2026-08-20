//! Cross-binding conformance for the esm-spec §6.3.1 classification API.
//!
//! esm 1.0.0 declares two variable types and DERIVES everything finer. Five
//! bindings deriving it independently is five chances to disagree, so
//! `tests/conformance/classification/` pins one answer: per model node, the
//! three unknown sets (which partition the unknowns), the four parameter sets
//! (which partition the parameters), and the derived `system_kind`.
//!
//! This driver asserts the Rust derivation reproduces that golden — the same
//! golden the Julia / TypeScript / Python / Go siblings assert against, so
//! golden agreement *is* cross-binding agreement.
//!
//! Two properties beyond equality are checked here because a golden cannot
//! state them: that each pair of sets really PARTITIONS (disjoint and total,
//! [`Classification::assert_partitions`]), and that classification is per MODEL
//! NODE — a subsystem's equations classify the subsystem's variables, which is
//! what `subsystem_scope` discriminates.

use earthsci_ast::classification::Classification;
use earthsci_ast::{Model, SystemKind};
use serde_json::Value;
use std::path::PathBuf;

/// Repo root = the crate dir's grandparent (`pkg/earthsci-ast-rs/../..`).
fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .expect("repo root resolves")
}

fn load_json(rel: &str) -> Value {
    let path = repo_root().join(rel);
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {path:?}: {e}"));
    serde_json::from_str(&text).unwrap_or_else(|e| panic!("parse {path:?}: {e}"))
}

/// Every model node of a document, keyed by its DOT-PATH from the root, so a
/// subsystem is `Parent.Child` — the golden's own key convention.
///
/// A subsystem is stored as raw JSON on [`Model`], so each is deserialized in
/// turn and recursed into. Classification never crosses one of these
/// boundaries: that is the point of keying by node.
fn model_nodes(doc: &Value) -> Vec<(String, Model)> {
    fn walk(prefix: &str, raw: &Value, out: &mut Vec<(String, Model)>) {
        let Ok(model) = serde_json::from_value::<Model>(raw.clone()) else {
            return;
        };
        if let Some(subs) = &model.subsystems {
            let mut names: Vec<&String> = subs.keys().collect();
            names.sort();
            for name in names {
                walk(&format!("{prefix}.{name}"), &subs[name], out);
            }
        }
        out.push((prefix.to_string(), model));
    }

    let mut out = Vec::new();
    let Some(models) = doc.get("models").and_then(Value::as_object) else {
        return out;
    };
    let mut names: Vec<&String> = models.keys().collect();
    names.sort();
    for name in names {
        walk(name, &models[name], &mut out);
    }
    out
}

fn want_list(golden: &Value, key: &str) -> Vec<String> {
    golden[key]
        .as_array()
        .unwrap_or_else(|| panic!("golden has no `{key}` array"))
        .iter()
        .map(|v| v.as_str().expect("golden name is a string").to_string())
        .collect()
}

#[test]
fn rust_classification_matches_golden() {
    let manifest = load_json("tests/conformance/classification/manifest.json");
    let fixtures = manifest["fixtures"].as_array().expect("fixtures array");
    assert!(!fixtures.is_empty());

    for fx in fixtures {
        let id = fx["id"].as_str().expect("fixture id");
        let doc = load_json(&format!(
            "tests/conformance/classification/{}",
            fx["fixture"].as_str().expect("fixture path")
        ));
        let golden = load_json(&format!(
            "tests/conformance/classification/{}",
            fx["golden"].as_str().expect("golden path")
        ));
        let golden_models = golden["models"].as_object().expect("golden models");

        let nodes = model_nodes(&doc);
        let got_keys: Vec<&str> = nodes.iter().map(|(k, _)| k.as_str()).collect();
        let mut want_keys: Vec<&str> = golden_models.keys().map(String::as_str).collect();
        want_keys.sort();
        let mut got_sorted = got_keys.clone();
        got_sorted.sort();
        assert_eq!(got_sorted, want_keys, "[{id}] model node set");

        for (key, model) in &nodes {
            let want = &golden_models[key];
            let class = Classification::of(model);

            // The seven sets, exactly.
            for (name, got) in [
                ("ode_states", &class.ode_states),
                ("observed_unknowns", &class.observed_unknowns),
                ("algebraic_unknowns", &class.algebraic_unknowns),
                ("brownian_parameters", &class.brownian_parameters),
                ("discrete_parameters", &class.discrete_parameters),
                ("sampled_parameters", &class.sampled_parameters),
                ("constant_parameters", &class.constant_parameters),
            ] {
                assert_eq!(*got, want_list(want, name), "[{id}] {key}.{name}");
            }

            // `is_ode_state` is the membership test for the first set, so it
            // must agree with it on EVERY declared variable — not just on the
            // ones that happen to be states.
            for var in model.variables.keys() {
                assert_eq!(
                    class.is_ode_state(var),
                    class.ode_states.iter().any(|s| s == var),
                    "[{id}] {key}: is_ode_state disagrees with ode_states on {var}"
                );
            }

            // The derived system kind, and the mismatch rule: a PRESENT
            // `system_kind` field never overrides the derivation, it only has
            // to agree with it.
            let want_kind = want["system_kind"].as_str().expect("golden system_kind");
            assert_eq!(class.system_kind.as_str(), want_kind, "[{id}] {key}.system_kind");
            assert_eq!(
                want["declared_system_kind"],
                model
                    .system_kind
                    .as_ref()
                    .map_or(Value::Null, |k| Value::String(k.clone())),
                "[{id}] {key}.declared_system_kind"
            );
            if let Some(declared) = model.system_kind.as_deref() {
                assert_eq!(
                    declared, want_kind,
                    "[{id}] {key}: a declared system_kind that disagrees with the \
                     derivation is `system_kind_mismatch`, and no golden carries one"
                );
            }

            // Both partition laws, which no golden can state.
            class
                .assert_partitions(model)
                .unwrap_or_else(|e| panic!("[{id}] {key}: {e}"));
        }
    }
}

/// The `system_kind` table is ORDERED and first-match-wins, and two of its rows
/// only differ by that order. `system_kind_pde` pins all four rows; this test
/// says out loud which row each of its models is there to catch, so a binding
/// that reorders the table fails with the reason rather than with a diff.
#[test]
fn system_kind_order_is_first_match_wins() {
    let doc = load_json("tests/conformance/classification/fixtures/system_kind_pde.esm");
    let nodes: std::collections::HashMap<String, Model> = model_nodes(&doc).into_iter().collect();

    let kind = |name: &str| Classification::of(&nodes[name]).system_kind;

    // Row 2 beats row 3: a steady-state PDE has no time-derivative equation and
    // would otherwise fall through to `nonlinear`.
    assert_eq!(kind("SteadyState"), SystemKind::Pde);
    // Row 1 beats row 2: there is no SPDESystem constructor to select.
    assert_eq!(kind("StochasticSpatial"), SystemKind::Sde);
    // A spatial `D` (wrt present and not "t") and the sugar ops are the same
    // signal.
    assert_eq!(kind("Transient"), SystemKind::Pde);
    assert_eq!(kind("SugarOps"), SystemKind::Pde);
}
